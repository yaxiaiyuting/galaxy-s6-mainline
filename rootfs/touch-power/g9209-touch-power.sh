#!/bin/bash
# G9209 触摸屏 / 触摸键 / audio codec 供电
#
# ============================================================
# 供电链路（从 TWRP vendor 3.10 内核读到的**已知正确状态**）
# ============================================================
# S2MPS15 @ i2c-gpio gpg3-0/1, addr 0x66, ID(reg0x00)=0x12
#   reg0x41 = 0xe8   VCC_1.8V_CODEC_PMIC  (audio, 1.8V, enabled)
#   reg0x42 = 0xee   tsp_io 1.85V         ← ★触摸屏 IO
#   reg0x48 = 0x3c   vtouch_3.3v disabled ← 触摸键电源（要开就写 0xfc）
#   reg0x4d = 0x3c   VDD_1.2V_CODEC       ← audio codec 1.2V
#
# S2MPB02 @ i2c-gpio gpg3-2/3, addr 0x59
#   reg0x2e = 0xec   tsp_avdd 3.3V        ← ★触摸屏 AVDD
#
# 编码（s2mps15.h）：
#   VSEL=bit[5:0]，0.7V..2.275V，25mV/step：VSEL=(V-700000)/25000
#   EN  =bit[7:6]，0b11=开
#   1.85V -> 46=0x2e -> 0xee
#   1.20V -> 20=0x14 -> 0xd4
#   1.80V -> 44=0x2c -> 0xec
#   LDO21 宽压档 3.3V -> 0xfc（实测有效）
# ============================================================

set -u
TAG="g9209-touch-power"
log() { echo "$TAG: $*"; }

for i in $(seq 1 20); do
    command -v i2cset >/dev/null 2>&1 && break
    sleep 0.5
done
command -v i2cset >/dev/null 2>&1 || { log "i2cset 不存在"; exit 1; }

# --- 找总线：读 reg0x00，S2MPS15 的 ID 是 0x12 ---
find_s2mps15() {
    for bus in /dev/i2c-*; do
        n=${bus#/dev/i2c-}
        v=$(i2cget -y -f "$n" 0x66 0x00 2>/dev/null) || continue
        [ "$v" = "0x12" ] && { echo "$n"; return 0; }
    done
    return 1
}
find_s2mpb02() {
    for bus in /dev/i2c-*; do
        n=${bus#/dev/i2c-}
        # S2MPB02 的 ID(0x00) 读出来是 0x00，且 LDO17 寄存器可读
        v=$(i2cget -y -f "$n" 0x59 0x2e 2>/dev/null) || continue
        [ -n "$v" ] && { echo "$n"; return 0; }
    done
    return 1
}

BUS15=""
for attempt in $(seq 1 30); do
    BUS15=$(find_s2mps15) && break
    sleep 0.4
done

if [ -n "$BUS15" ]; then
    log "S2MPS15 在 i2c-$BUS15 (ID=0x$(i2cget -y -f "$BUS15" 0x66 0x00 2>/dev/null | sed 's/0x//'))"
    # tsp_io = LDO15 = 1.85V + enable
    i2cset -y -f "$BUS15" 0x66 0x42 0xee && log "  LDO15(tsp_io)=0xee (1.85V on)"
    # vtouch_3.3v = LDO21 = 3.3V + enable（触摸键 BACK/RECENT）
    i2cset -y -f "$BUS15" 0x66 0x48 0xfc && log "  LDO21(vtouch)=0xfc (3.3V on)"
    # VDD_1.2V_CODEC = LDO26 = 1.2V + enable（音频）
    i2cset -y -f "$BUS15" 0x66 0x4d 0xd4 && log "  LDO26(codec 1.2V)=0xd4"
    # VCC_1.8V_CODEC_PMIC = LDO? = 0xe8（TWRP 里就是开的，保持）
    i2cset -y -f "$BUS15" 0x66 0x41 0xe8 && log "  reg0x41(codec 1.8V)=0xe8"
else
    log "警告：找不到 S2MPS15（0x66 ID=0x12）"
fi

BUS02=""
for attempt in $(seq 1 20); do
    BUS02=$(find_s2mpb02) && break
    sleep 0.4
done
if [ -n "$BUS02" ]; then
    log "S2MPB02 在 i2c-$BUS02"
    i2cset -y -f "$BUS02" 0x59 0x2e 0xec && log "  LDO17(tsp_avdd)=0xec (3.3V on)"
else
    log "警告：找不到 S2MPB02（0x59）"
fi

# --- 触摸屏硬件复位（关键！）---
# stmfts 驱动的 SYSTEM_RESET 命令在冷启动后会超时（-110），
# 必须用 LDO15 断电再上电做一次真正的硬件复位，芯片才会正常响应。
# 实测：不做这一步，probe 一直 -110；做完立刻 input 设备出现。
if [ -n "$BUS15" ]; then
    log "触摸屏硬件复位（LDO15 断电/上电）..."
    i2cset -y -f "$BUS15" 0x66 0x42 0x3c || true   # LDO15 关
    sleep 0.3
    i2cset -y -f "$BUS15" 0x66 0x42 0xee || true   # LDO15 开
    sleep 0.3
    log "  LDO15 回读 = $(i2cget -y -f "$BUS15" 0x66 0x42 2>/dev/null)"
fi

# --- 触发触摸屏 / 触摸键重新 probe ---
sleep 0.3
for dev in 2-0049 3-0049 4-0049 5-0049; do
    d=${dev#*-}
    bus=${dev%-*}
    if [ -d /sys/bus/i2c/devices/$dev ]; then
        echo "$dev" > /sys/bus/i2c/drivers/stmfts/unbind 2>/dev/null || true
        sleep 0.2
        echo "$dev" > /sys/bus/i2c/drivers/stmfts/bind 2>/dev/null || true
    fi
done
for dev in 0-0020; do
    if [ -d /sys/bus/i2c/devices/$dev ]; then
        echo "$dev" > /sys/bus/i2c/drivers/mbr-touchkey/unbind 2>/dev/null || true
        sleep 0.2
        echo "$dev" > /sys/bus/i2c/drivers/mbr-touchkey/bind 2>/dev/null || true
    fi
done

# --- 结果检查 ---
sleep 0.5
INPUTS=$(cat /sys/class/input/input*/name 2>/dev/null | tr '\n' ' ')
log "输入设备: $INPUTS"
case "$INPUTS" in
    *stmfts*) log "✓ 触摸屏已上线" ;;
    *) log "✗ 触摸屏未出现" ;;
esac
exit 0
