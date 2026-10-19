#!/bin/bash
# G9209 mainline rootfs 一键配置
# 在手机上以 root 运行
set -e
# 1. SSH host keys
ssh-keygen -A
systemctl enable ssh && systemctl start ssh
# 2. 自动充电
cp max77843-charge-on.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now max77843-charge-on.service
# 3. BT_EN
cp g9209-bt-en.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now g9209-bt-en.service
echo "rootfs setup done"
