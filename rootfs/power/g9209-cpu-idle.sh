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

BIG="1 2 3 4"     # A57
EXTRA="6 7"       # 额外 A53（留 cpu0 和 cpu5）
ALL_OFF="$BIG $EXTRA"
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
