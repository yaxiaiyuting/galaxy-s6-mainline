#!/bin/bash
# SM-G9209 (zeroflte) 蓝牙 rootfs 准备脚本 —— 在**手机上**以 root 执行
#
# 用途：装 bluez、把 BCM4358A3 的 HCI 补丁放到 /lib/firmware/brcm/ 下,
#       并给出正确的文件名。
#
# 为什么要放三个名字：
#   drivers/bluetooth/btbcm.c:btbcm_initialize() 会按下面的顺序找固件
#   （board_name 取自 DTS 根节点 compatible[0] = "samsung,zeroflte"）：
#       1) brcm/<hw_name>.samsung,zeroflte.hcd   —— hw_name 由芯片回报的
#                                                  lmp_subver 查表得出，
#                                                  而 bcm_uart_subver_table
#                                                  里**没有** BCM4358 的表项
#       2) brcm/<hw_name>.hcd                    —— 同上，实际不会命中
#       3) brcm/BCM.samsung,zeroflte.hcd         <- 真正会用到的
#       4) brcm/BCM.hcd                          <- 兜底
#   所以第 3、4 个名字必须存在；第 1/2 个（BCM4358A3.hcd）先放着，
#   等 dmesg 打印出真实 subver、给 bcm_uart_subver_table 加上表项后才生效。
#
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FW="$HERE/bcm4358A3_V0083.0138.hcd"
[[ -f $FW ]] || { echo "找不到 $FW" >&2; exit 1; }

echo '[1/4] 安装 bluez（提供 btattach / bluetoothctl / hciconfig）'
apt-get update -qq
apt-get install -y bluez

echo '[2/4] 安装 BCM4358A3 HCI 补丁固件'
install -Dm644 "$FW" /lib/firmware/brcm/BCM.samsung,zeroflte.hcd
install -Dm644 "$FW" /lib/firmware/brcm/BCM.hcd
install -Dm644 "$FW" /lib/firmware/brcm/BCM4358A3.hcd

echo '[3/4] 确认串口设备存在（需要 p233 内核 + 已探测过 0x114C0000）'
if [[ -c /dev/ttySAC0 ]]; then
    echo '  /dev/ttySAC0 存在 ✓'
else
    echo '  !! /dev/ttySAC0 不存在 —— 内核里 serial@11460000 没起来' >&2
    echo '     检查 dmesg | grep -i "11460000\|samsung-uart\|ttySAC"' >&2
    exit 2
fi

echo '[4/4] 启动 bluetoothd'
systemctl enable --now bluetooth || true

cat <<'EOF'

准备完成。接着手动挂 HCI（btattach 是 bluez 提供的，等价于老的 hciattach）：

    # -B = BR/EDR 控制器, -P bcm = 走 hci_bcm 协议(含固件下载),
    # -S 115200 = 初始波特率（bcm_proto.oper_speed=0，所以不会切到高速）
    btattach -B /dev/ttySAC0 -P bcm -S 115200 &

    sleep 3
    dmesg | tail -40          # 应能看到 "Bluetooth: hci0" 和
                              # "BCM: ... Patch" 或 "firmware Patch file not found"
    hciconfig -a              # 应看到 hci0 的 BD Address / Features
    bluetoothctl list
EOF
