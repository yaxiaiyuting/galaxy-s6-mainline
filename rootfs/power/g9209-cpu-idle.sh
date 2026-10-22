#!/bin/bash
# G9209: 灭屏时下线大核，只留小核跑后台（网络/蓝牙等）
#
# 背景：Exynos 7420 = 4×Cortex-A57(大) + 4×Cortex-A53(小)
#   cpu0     = A53（boot CPU，不能下线）
#   cpu1-4   = A57 大核
#   cpu5-7   = A53 小核
#
# 本板没有 cpuidle（S-Boot 的 PSCI v0.1 没有 CPU_SUSPEND），
# CPU 空闲时无法真正掉电。但 PSCI v0.1 **支持 CPU_OFF**，
# 所以可以用 CPU hotplug 在灭屏时把大核真正关掉。
#
# 策略：
#   亮屏        → 全部 8 核在线
#   灭屏 5 秒后 → 下线 cpu1-4（大核）+ cpu6,7（多余的2个小核）
#                 只留 cpu0 + cpu5（2 个 A53）跑网络/蓝牙/后台
#   亮屏        → 立刻恢复全部核心
#
# 安全性：
#   - 灭屏后延迟 5 秒才下线，避免刚灭屏时的收尾工作被拖慢
#   - 服务退出时（ExecStopPost）强制恢复所有核心
#   - 只下线 cpu1-4/6-7，绝不动 cpu0（boot CPU）

set -u
TAG="g9209-cpu-idle"
log() { echo "$TAG: $*"; }

# 动态检测哪些是小核（A53, CPU part 0xd03）、哪些是大核（A57, 0xd07）
#
# 注意：Exynos 7420 的**运行时逻辑编号**和 DTS 的 reg 值不一致。
# /proc/cpuinfo 实测（part 0xd07=A57, 0xd03=A53）：
#   cpu0=A53, cpu1-4=A57, cpu5-7=A53
# 而 DTS 里写的是 cpu@0-3=A57（reg 0x0-0x3）、cpu@100-103=A53（reg 0x100-0x103）。
# 所以**绝不能**用 DTS 的假设来写死核编号 —— 必须运行时检测。
detect_cores() {
    BIG=""
    LITTLE=""
    local cpu="" part=""
    while IFS= read -r line; do
        case "$line" in
            processor*) cpu=$(echo "$line" | cut -d: -f2 | tr -d ' ') ;;
            *"CPU part"*)
                part=$(echo "$line" | cut -d: -f2 | tr -d ' ')
                if [ "$part" = "0xd07" ]; then
                    BIG="$BIG $cpu"
                elif [ "$part" = "0xd03" ]; then
                    LITTLE="$LITTLE $cpu"
                fi
                ;;
        esac
    done < /proc/cpuinfo
}

detect_cores

# 保留第一个小核（通常是 boot CPU，不能下线）+ 第二个小核，
# 其余小核和大核全部可下线
KEEP_LITTLE=$(echo $LITTLE | awk '{print $1, $2}')
ALL_LITTLE_ONLINE=""
for c in $LITTLE; do
    case " $KEEP_LITTLE " in
        *" $c "*) : ;;
        *) ALL_LITTLE_ONLINE="$ALL_LITTLE_ONLINE $c" ;;
    esac
done

ALL_OFF="$BIG$ALL_LITTLE_ONLINE"
DPMS_FILE=/sys/class/drm/card0-VGA-1/dpms
DELAY=5

cpu_online() { [ "$(cat /sys/devices/system/cpu/cpu$1/online 2>/dev/null)" = "1" ]; }

offline_all() {
    local changed=0
    for c in $ALL_OFF; do
        if cpu_online "$c"; then
            echo 0 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null && changed=1
        fi
    done
    [ "$changed" = 1 ] && log "灭屏 → 下线大核，当前在线: $(cat /sys/devices/system/cpu/online)"
    return 0
}

online_all() {
    local changed=0
    for c in $ALL_OFF; do
        if ! cpu_online "$c"; then
            echo 1 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null && changed=1
        fi
    done
    [ "$changed" = 1 ] && log "亮屏 → 恢复全部核心: $(cat /sys/devices/system/cpu/online)"
    return 0
}

# 退出时兜底恢复
trap 'online_all; log "退出，已恢复所有核心"; exit 0' TERM INT EXIT

log "启动，初始在线: $(cat /sys/devices/system/cpu/online)"
log "检测到 大核(A57): [$BIG ]  小核(A53): [$LITTLE ]"
log "灭屏时将下线: [$ALL_OFF ]  保留: $KEEP_LITTLE"

# 等 DPMS 文件出现
for i in $(seq 1 60); do
    [ -r "$DPMS_FILE" ] && break
    sleep 1
done
[ -r "$DPMS_FILE" ] || { log "找不到 $DPMS_FILE"; exit 1; }

LAST=""
while :; do
    CUR=$(cat "$DPMS_FILE" 2>/dev/null || echo "On")
    if [ "$CUR" != "$LAST" ]; then
        if [ "$CUR" = "Off" ]; then
            sleep "$DELAY"
            # 再确认一次（可能已经亮了）
            [ "$(cat "$DPMS_FILE" 2>/dev/null)" = "Off" ] && offline_all
        else
            online_all
        fi
        LAST=$(cat "$DPMS_FILE" 2>/dev/null || echo "On")
    fi
    sleep 1
done
