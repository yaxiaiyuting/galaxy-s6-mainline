#!/bin/sh
# G9209: 每次开机后给面板发 SET_TEAR_ON(0x35)，让它在帧边界锁存 GRAM。
#
# i80 命令模式的面板如果不��� tear-on，会实时显示 GRAM 的写入过程 ——
# 写一半就被扫描，表现为撕裂。S-Boot 初始化面板后内核从未发过 0x35。
#
# 参数 0x00 = TE on VBLANK（默认）；0x01 = TE on VBLANK+HBLANK。
P=/sys/module/exynosdrm/parameters/dcs_send
for i in $(seq 1 60); do
    [ -e "$P" ] && break
    sleep 0.5
done
[ -e "$P" ] || exit 0
sleep 3
echo "35,00" > "$P" 2>/dev/null && echo "panel-tear-on: sent 0x35 0x00"
