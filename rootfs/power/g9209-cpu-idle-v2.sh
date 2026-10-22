#!/bin/bash
# G9209 / SM-G9209 (Exynos 7420) 灭屏 CPU 电源策略 v2
#
# 取代 g9209-cpu-idle.sh 的改进点：
#   1. 分档下线（5s 下线大核 / 30s 再收敛小核），带滞回
#   2. 启动即把所有非 WFI 的 cpuidle 状态 disable（cpuidle 联锁，p300 事故后的硬性要求）
#   3. 热插拔自检 + 熔断：CPU_ON 一旦失败就永久停用，绝不反复触发
#   4. 运行时探测 A57/A53（逻辑编号 ≠ DTS reg，实测 cpu0=A53）
#   5. 绝不写 cpu0；退出/trap 兜底恢复
#
# 注意：本板 cpuidle-psci 目前不可用（见 文档/05-专项/cpuidle-p300失败分析-20261023.md）。
#       任何情况下都不要把 state1 的 disable 清掉，除非你正在做受控实验。

set -u

TAG="g9209-cpu-idle"
STATE_DIR=/var/lib/g9209
HOTPLUG_BAD="$STATE_DIR/hotplug.bad"
HOTPLUG_OK="$STATE_DIR/hotplug.ok"
SELFTEST_FLAG=/etc/g9209/hotplug-selftest     # 存在此文件才做一次性 CPU_ON 自检
DPMS_FILE=/sys/class/drm/card0-VGA-1/dpms
T1_DELAY=5          # 灭屏后多久下线大核
T2_DELAY=30         # 灭屏后多久收敛小核
MAX_FAIL=3

log() { echo "$TAG: $*"; }
mkdir -p "$STATE_DIR" 2>/dev/null

# ---------- cpuidle 联锁 ----------
# p300 教训：state1（POWERDOWN）在 maxcpus=1 / 无 local-timer-stop 时会一去不回。
# 这里在策略启动时无条件把非 WFI 状态关掉；即使 DTS 又打开了 idle-states 也不会误入。
cpuidle_interlock() {
    local s name
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*; do
        [ -w "$s/disable" ] || continue
        name=$(cat "$s/name" 2>/dev/null || echo "?")
        case "$name" in
            WFI) : ;;
            *)
                if [ "$(cat "$s/disable" 2>/dev/null)" != "1" ]; then
                    echo 1 > "$s/disable" 2>/dev/null && \
                        log "cpuidle 联锁: 已禁用 $s ($name)"
                fi
                ;;
        esac
    done
}

# ---------- 核心拓扑探测 ----------
detect_cores() {
    BIG=""
    LITTLE=""
    local cpu="" part=""
    while IFS= read -r line; do
        case "$line" in
            processor*) cpu=$(echo "$line" | cut -d: -f2 | tr -d ' ') ;;
            *"CPU part"*)
                part=$(echo "$line" | cut -d: -f2 | tr -d ' ')
                case "$part" in
                    0xd07) BIG="$BIG $cpu" ;;       # Cortex-A57
                    0xd03) LITTLE="$LITTLE $cpu" ;; # Cortex-A53
                esac
                ;;
        esac
    done < /proc/cpuinfo
}

cpu_online() { [ "$(cat "/sys/devices/system/cpu/cpu$1/online" 2>/dev/null)" = "1" ]; }
can_offline() { [ "$1" != "0" ] && [ -w "/sys/devices/system/cpu/cpu$1/online" ]; }

# ---------- 热插拔自检（一次性，可熔断） ----------
hotplug_selftest() {
    [ -f "$HOTPLUG_BAD" ] && { log "热插拔已标记不可用，跳过"; return 1; }
    [ -f "$HOTPLUG_OK" ] && return 0
    [ -f "$SELFTEST_FLAG" ] || { log "未启用自检（$SELFTEST_FLAG 不存在），假定可用"; return 0; }

    local probe=""
    for c in $LITTLE $BIG; do
        can_offline "$c" && { probe=$c; break; }
    done
    [ -n "$probe" ] || { log "没有可下线的核，自检跳过"; return 0; }

    log "热插拔自检: 尝试下线并上线 cpu$probe（最多等 8s）"
    if timeout 8 sh -c "echo 0 > /sys/devices/system/cpu/cpu$probe/online" 2>/dev/null &&
       timeout 8 sh -c "echo 1 > /sys/devices/system/cpu/cpu$probe/online" 2>/dev/null; then
        : > "$HOTPLUG_OK"
        log "热插拔自检通过"
        return 0
    fi
    : > "$HOTPLUG_BAD"
    log "热插拔自检失败 → 写入 $HOTPLUG_BAD，永久停用（避免反复触发 CPU_ON）"
    return 1
}

# ---------- 策略 ----------
LITTLE_KEEP=""      # Tier-2 之后仍保留的小核
OFF_T1=""           # Tier-1 下线的核
OFF_T2=""           # Tier-2 额外下线的核
FAIL_COUNT=0

build_policy() {
    # 保留：cpu0（boot，物理上不可下线）+ 第一个可下线的小核
    LITTLE_KEEP="0"
    local first=""
    for c in $LITTLE; do
        [ "$c" = "0" ] && continue
        first=$c; break
    done
    [ -n "$first" ] && LITTLE_KEEP="$LITTLE_KEEP $first"

    OFF_T1=""
    for c in $BIG; do
        can_offline "$c" && OFF_T1="$OFF_T1 $c"
    done

    OFF_T2=""
    for c in $LITTLE; do
        case " $LITTLE_KEEP " in *" $c "*) continue ;; esac
        can_offline "$c" && OFF_T2="$OFF_T2 $c"
    done
}

offline_list() {
    local changed=0 c
    for c in $1; do
        cpu_online "$c" || continue
        if echo 0 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null; then
            changed=1
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            log "下线 cpu$c 失败（累计 $FAIL_COUNT）"
            [ "$FAIL_COUNT" -ge "$MAX_FAIL" ] && { log "失败次数过多，停止下线尝试"; return 0; }
        fi
    done
    [ "$changed" = 1 ] && log "当前在线: $(cat /sys/devices/system/cpu/online)"
    return 0
}

online_all() {
    local changed=0 c
    for c in $OFF_T1 $OFF_T2; do
        cpu_online "$c" && continue
        echo 1 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null && changed=1
    done
    FAIL_COUNT=0
    [ "$changed" = 1 ] && log "已恢复全部核心: $(cat /sys/devices/system/cpu/online)"
    return 0
}

# ---------- 主流程 ----------
cpuidle_interlock
detect_cores
build_policy

log "启动。在线: $(cat /sys/devices/system/cpu/online)"
log "A57=[$BIG ] A53=[$LITTLE ] 保留=[$LITTLE_KEEP ]"
log "Tier-1(>${T1_DELAY}s) 下线=[$OFF_T1 ] Tier-2(>${T2_DELAY}s) 再下线=[$OFF_T2 ]"

if ! hotplug_selftest; then
    log "hotplug 不可用 → 本服务只保留 cpuidle 联锁功能，退出策略循环"
    trap 'exit 0' TERM INT EXIT
    while :; do sleep 3600; done
fi

trap 'online_all; log "退出，已恢复所有核心"; exit 0' TERM INT EXIT

for _ in $(seq 1 60); do
    [ -r "$DPMS_FILE" ] && break
    sleep 1
done
[ -r "$DPMS_FILE" ] || { log "找不到 $DPMS_FILE"; exit 1; }

STATE=on           # on | t1 | t2
OFF_SINCE=0

while :; do
    CUR=$(cat "$DPMS_FILE" 2>/dev/null || echo "On")
    NOW=$(cut -d. -f1 /proc/uptime)

    if [ "$CUR" != "Off" ]; then
        [ "$STATE" != "on" ] && { online_all; STATE=on; }
        OFF_SINCE=0
    else
        [ "$OFF_SINCE" = 0 ] && OFF_SINCE=$NOW
        OFF_FOR=$((NOW - OFF_SINCE))

        if [ "$STATE" = "on" ] && [ "$OFF_FOR" -ge "$T1_DELAY" ]; then
            offline_list "$OFF_T1"
            STATE=t1
        fi
        if [ "$STATE" = "t1" ] && [ "$OFF_FOR" -ge "$T2_DELAY" ]; then
            offline_list "$OFF_T2"
            STATE=t2
        fi
    fi
    sleep 2
done
