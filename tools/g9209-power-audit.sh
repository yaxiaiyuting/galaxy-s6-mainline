#!/bin/bash
# G9209 完整功耗审计
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

FG=/sys/class/power_supply/max77843-fuelgauge
CHG=/sys/class/power_supply/max77843-charger

cur()  { cat $FG/current_now 2>/dev/null; }
volt() { cat $FG/voltage_now 2>/dev/null; }
cap()  { cat $FG/capacity 2>/dev/null; }

# 统计采样：n 次，输出 平均/中位/最小/最大 (mA)
stat_sample() {
    local n=${1:-40}
    local vals=()
    local i
    for ((i=0; i<n; i++)); do
        vals+=($(( $(cur) / 1000 )))
        sleep 0.25
    done
    printf '%s\n' "${vals[@]}" | sort -n | awk '
        {a[NR]=$1; s+=$1}
        END {
            m=s/NR
            med=a[int(NR/2)+1]
            printf "avg=%.0f med=%.0f min=%d max=%d n=%d", m, med, a[1], a[NR], NR
        }'
}

label() { echo ""; echo "### $1"; }

echo "=============================================="
echo " G9209 功耗审计  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

label "0. 环境"
echo "  电量: $(cap)%   电压: $(( $(volt)/1000 )) mV"
echo "  充电: $(cat $CHG/status 2>/dev/null) / limit=$(cat $CHG/input_current_limit 2>/dev/null)uA"
echo "  MUIC: $(dmesg | grep -oE 'MUIC_chg_type=[0-9]+\([A-Z-]+\)' | tail -1)"
echo "  CPU : $(cat /sys/devices/system/cpu/online)"
echo "  DPMS: $(cat /sys/class/drm/card0-VGA-1/dpms)"
echo "  WiFi: $(iw dev wlp1s0 link 2>/dev/null | grep -oE 'signal: -[0-9]+ dBm' | head -1)"
echo "  shell: $(pgrep -c 'gnome-shell$' 2>/dev/null || echo 0)"

label "1. 当前状态（全开）"
echo "  $(stat_sample 40)"

label "2. 灭屏（DPMS Off）"
gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.Lock >/dev/null 2>&1
sleep 6
echo "  DPMS=$(cat /sys/class/drm/card0-VGA-1/dpms)"
echo "  $(stat_sample 40)"

label "3. 灭屏 + 只留 1 小核"
for c in 1 2 3 4 5 6 7; do echo 0 > /sys/devices/system/cpu/cpu$c/online 2>/dev/null; done
sleep 3
echo "  CPU=$(cat /sys/devices/system/cpu/online)"
echo "  $(stat_sample 40)"

label "4. 灭屏 + 1核 + WiFi down"
ip link set wlp1s0 down 2>/dev/null
sleep 4
echo "  $(stat_sample 40)"

label "5. 灭屏 + 1核 + WiFi down + 停 GDM"
systemctl stop gdm 2>/dev/null
sleep 10
echo "  shell=$(pgrep -c 'gnome-shell$' 2>/dev/null || echo 0)"
echo "  $(stat_sample 40)"

label "6. 恢复"
for c in 1 2 3 4 5 6 7; do echo 1 > /sys/devices/system/cpu/cpu$c/online 2>/dev/null; done
ip link set wlp1s0 up 2>/dev/null
systemctl start gdm 2>/dev/null
sleep 20
echo "  shell=$(pgrep -c 'gnome-shell$' 2>/dev/null || echo 0) DPMS=$(cat /sys/class/drm/card0-VGA-1/dpms)"
echo "  $(stat_sample 20)"

echo ""
echo "=============================================="
echo " 电量: $(cap)%   电压: $(( $(volt)/1000 )) mV"
echo "=============================================="
