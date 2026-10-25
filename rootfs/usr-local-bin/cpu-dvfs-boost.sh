#!/bin/sh
# G9209 CPU DVFS 升压 + 升频
#
# 默认 governor = powersave（内核配置 CONFIG_CPU_FREQ_DEFAULT_GOV_POWERSAVE），
# 开机只跑最低频：
#   A57 1200MHz @ S2MPS15 BUCK2 925mV
#   A53 1000MHz @ BUCK3 1200mV
# 本服务负责：先把 BUCK2 (vdd_atlas/A57) 抬到 1050mV，校验成功后，
# 才把 governor 切成 performance 让频率冲到 1800/1500MHz。
#
# 为什么必须这个顺序：OPP 表里没有 opp-microvolt，cpufreq 不会动电压；
# 如果开机就是 performance，内核会在 925mV 下直接冲到 1800MHz → 死机。
#
# 失败熔断：如果上次升压后系统挂了（标记文件残留），这次直接跳过，
# 保证不会变成崩溃循环。
set -u
BUS=2; ADDR=0x66
MARK=/var/lib/g9209/dvfs-boost.tried
mkdir -p /var/lib/g9209

if [ -e "$MARK" ]; then
    logger -t cpu-dvfs-boost "上次升压后系统未成功启动，跳过本次升压（安全模式）"
    exit 0
fi

: > "$MARK"

CUR=$(i2cget -y $BUS $ADDR 0x1c 2>/dev/null || echo "")
if [ -z "$CUR" ]; then
    logger -t cpu-dvfs-boost "PMIC 读失败，保持 powersave"
    exit 1
fi
logger -t cpu-dvfs-boost "BUCK2 当前 $CUR (925mV)，准备抬到 0x68 (1050mV)"

# S2MPS15 buck 电压编码：V = 400000 + 6250 * VSEL
i2cset -y $BUS $ADDR 0x1c 0x68 2>/dev/null
sleep 0.2
NEW=$(i2cget -y $BUS $ADDR 0x1c 2>/dev/null || echo "")
if [ "$NEW" != "0x68" ]; then
    logger -t cpu-dvfs-boost "升压校验失败 (读回 $NEW)，保持 powersave"
    exit 1
fi
logger -t cpu-dvfs-boost "BUCK2 已到 1050mV，切 performance"

for c in 0 1 2 3 4 5 6 7; do
    D=/sys/devices/system/cpu/cpu$c/cpufreq
    [ -d "$D" ] || continue
    echo performance > $D/scaling_governor 2>/dev/null
done

sleep 3
rm -f "$MARK"
logger -t cpu-dvfs-boost "完成: A57=$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq 2>/dev/null) A53=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"
