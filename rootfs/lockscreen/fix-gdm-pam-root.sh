#!/bin/bash
# G9209: 允许 root 从锁屏/GDM 登录
#
# Debian 的 /etc/pam.d/gdm-password 第 3 行硬编码了：
#   auth required pam_succeed_if.so user != root quiet_success
# 这一行会**直接拒绝 root 认证** —— 无论密码对不对，root 都登不进
# 锁屏和 GDM 登录界面（报"密码错误"）。
#
# 因为本机整个系统就是 root 一个用户，必须去掉这个限制。
set -e
PAM=/etc/pam.d/gdm-password
[ -f "$PAM" ] || exit 0
cp -n "$PAM" "$PAM.orig" 2>/dev/null || true
# 把 "user != root" 那行注释掉
sed -i 's|^\(auth[[:space:]]*required[[:space:]]*pam_succeed_if\.so user != root.*\)|# \1|' "$PAM"
grep -n "pam_succeed_if" "$PAM" || true
echo "gdm-password PAM root restriction removed"
