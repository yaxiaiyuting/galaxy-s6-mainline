#!/bin/bash
# G9209 面板供电开关（方案 C：兜底）
#
# 背景：
#   亮度固定 / 熄屏只省 6mA 的根因在**面板侧**（S6E3HF2 一直在按最后一帧发光），
#   DPMS off 只停了 DECON 的扫描。真正的解法是往 DSIM 发 DCS 0x28/0x51
#   （见 文档/05-专项/背光控制实现方案-20261023.md 方案 A）。
#   本脚本是那条路走不通时的兜底：直接把面板的两路电源拉掉。
#
# 硬件（vendor exynos7420-zero_common.dtsi:692-731）：
#   MAX77838 @ i2c 0x60（vendor 挂 hsi2c@13670000，实际落在 gpg3-2/3 的 i2c-gpio 上）
#     reg 0x03 REG_REG_EN   bit0 = LDO1_EN (VCC_DISPLAY_1.8V)
#                           bit1 = LDO2_EN (tsp_io 1.85V)      ← 触摸屏，别动
#                           bit2 = LDO3_EN (VCC_3.0V_LCD)
#                           bit3 = LDO4_EN (tsp_avdd 3.3V)     ← 触摸屏，别动
#     reg 0x02 REG_REG_STAT bit0 = LDO1_POK，bit2 = LDO3_POK（回读校验）
#     reg 0x00 REG_DEVICE_ID
#   两路 LDO 在 vendor DTS 里是 regulator-boot-on：S-Boot 打开后没人关过，
#   mainline 也没有 max77838 驱动，所以只能用户态 i2cset 写。
#
# ★ 严重限制（务必先读）：
#   拉掉 VCC_3.0V_LCD 会让面板 DDI 掉电复位（POR）。S-Boot 做的初始化序列
#   （0xF0 0x5A5A / 0xF2 0x67 / 0xC8 MTP / gamma 表 ...）**没有任何人重放**，
#   所以 `on` 只保证供电回来，**画面不会恢复**，必须重启（S-Boot 重新初始化）。
#   ⇒ 本脚本只适合：①测量面板真实功耗 ②屏幕长期不用时省电 ③方案 A 失败时的应急。
#     不适合日常熄屏/唤醒。
#
# 用法：
#   g9209-panel-power.sh probe      只读：看 MAX77838 在不在、LDO1/LDO3 状态
#   g9209-panel-power.sh off        关 LDO1+LDO3（面板全断电，画面不会回来）
#   g9209-panel-power.sh on         恢复 LDO1+LDO3（供电回来，画面仍需重启）
#   g9209-panel-power.sh idetect    对每条 i2c 总线扫 0x59/0x60
#
# 参考实现：rootfs/touch-power/g9209-touch-power.sh（已验证可用）

set -u
TAG="g9209-panel-power"
STATE=/run/g9209-panel-power.state
ADDR=0x60

# REG_REG_EN 里属于"面板"的两位：LDO1(bit0) + LDO3(bit2) = 0x05
PANEL_MASK=0x05

log() { echo "$TAG: $*"; }
die() { echo "$TAG: $*" >&2; exit 1; }

command -v i2cget >/dev/null 2>&1 || die "i2cget 不存在（apt-get install -y i2c-tools）"
command -v i2cset >/dev/null 2>&1 || die "i2cset 不存在（apt-get install -y i2c-tools）"

# --- 找 MAX77838 所在总线：读 reg0x00，0xff = 没人应答 ---
find_bus() {
    local bus n v
    for bus in /dev/i2c-*; do
        n=${bus#/dev/i2c-}
        v=$(i2cget -y -f "$n" "$ADDR" 0x00 2>/dev/null) || continue
        [ -n "$v" ] && [ "$v" != "0xff" ] && { echo "$n"; return 0; }
    done
    return 1
}

get_reg() { i2cget -y -f "$1" "$ADDR" "$2" 2>/dev/null; }

probe_bus() {
    local bus=$1 id stat en
    id=$(get_reg "$bus" 0x00); stat=$(get_reg "$bus" 0x02); en=$(get_reg "$bus" 0x03)
    log "总线 i2c-$bus  MAX77838@$ADDR"
    log "  ID(0x00)      = $id"
    log "  STAT(0x02)    = $stat   (bit0=LDO1_POK bit2=LDO3_POK)"
    log "  EN(0x03)      = $en     (bit0=LDO1 bit1=tsp_io bit2=LDO3 bit3=tsp_avdd)"
    case "$en" in
        0x*)
            local v=$((en))
            if [ $((v & 0x05)) -eq 0x05 ]; then
                log "  ⇒ VCC_DISPLAY_1.8V + VCC_3.0V_LCD 都是 ON（面板有电，符合「屏幕亮着」）"
            else
                log "  ⇒ 面板两路 LDO 至少一路是 OFF（屏幕此时应该是黑的）"
            fi
            ;;
    esac
}

case "${1:-probe}" in
probe)
    bus=$(find_bus) || die "所有 i2c 总线上 0x60 都不 ACK —— MAX77838 摸不到，方案 C 不可用"
    probe_bus "$bus"
    log "只读模式，没有写任何寄存器。"
    ;;
idetect)
    for bus in /dev/i2c-*; do
        n=${bus#/dev/i2c-}
        a=$(i2cget -y -f "$n" 0x59 0x2e 2>/dev/null)
        b=$(i2cget -y -f "$n" "$ADDR" 0x00 2>/dev/null)
        [ -n "$a$b" ] && log "i2c-$n: S2MPB02(0x59,0x2e)=${a:-none}  MAX77838(0x60,0x00)=${b:-none}"
    done
    ;;
off)
    bus=$(find_bus) || die "0x60 不 ACK，拒绝写（先跑 probe）"
    en=$(get_reg "$bus" 0x03) || die "读 REG_EN 失败"
    val=$((en))
    echo "$val" > "$STATE"
    log "保存原始 REG_EN=$en → $STATE"
    # 只清 bit0/bit2，保留 tsp_io/tsp_avdd（否则触摸屏也断，唤醒后要重跑 touch-power）
    new=$((val & ~PANEL_MASK))
    printf -v hex '0x%02x' "$new"
    i2cset -y -f "$bus" "$ADDR" 0x03 "$hex" || die "写 REG_EN 失败"
    sleep 0.2
    log "写 REG_EN=$hex（LDO1/LDO3 关）"
    probe_bus "$bus"
    log "★ 面板已断电。注意：画面不会自己回来；要恢复必须重启（S-Boot 重新初始化面板）。"
    ;;
on)
    bus=$(find_bus) || die "0x60 不 ACK，拒绝写"
    cur=$(get_reg "$bus" 0x03) || die "读 REG_EN 失败"
    if [ -f "$STATE" ]; then
        want=$(cat "$STATE")
    else
        want=$(( $(printf '%d' "$cur") | PANEL_MASK ))
    fi
    printf -v hex '0x%02x' "$(( want | PANEL_MASK ))"
    i2cset -y -f "$bus" "$ADDR" 0x03 "$hex" || die "写 REG_EN 失败"
    sleep 0.2
    log "写 REG_EN=$hex（LDO1/LDO3 开）"
    probe_bus "$bus"
    log "★ 供电已恢复，但面板 DDI 已经掉电复位过：屏幕大概率仍然黑，请重启。"
    ;;
*)
    die "用法: $0 {probe|off|on|idetect}"
    ;;
esac
exit 0
