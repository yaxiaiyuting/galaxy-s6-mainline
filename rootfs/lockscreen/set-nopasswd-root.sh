#!/bin/bash
# G9209: root 免密码登录（锁屏按回车即解锁）
#
# 背景：
#  - Debian 的 /etc/pam.d/gdm-password 有
#      auth required pam_succeed_if.so user != root quiet_success
#    直接拒绝 root 认证 → 锁屏/GDM 输对密码也报"密码错误"
#  - 本机只有 root 一个用户，不需要这个限制
#
# 做法：
#  1) 注释掉 gdm-password 里的 root 限制
#  2) 清空 root 密码（passwd -d root）
#  3) 确认 common-auth 里有 nullok（Debian 默认就有，允许空密码）
#
# 效果：锁屏界面直接按回车即可解锁，不需要输入密码。
set -e

PAM=/etc/pam.d/gdm-password
if [ -f "$PAM" ]; then
    cp -n "$PAM" "$PAM.orig" 2>/dev/null || true
    sed -i 's|^\(auth[[:space:]]*required[[:space:]]*pam_succeed_if\.so user != root.*\)|# \1|' "$PAM"
    echo "已注释 gdm-password 的 root 限制"
fi

# 清空 root 密码
passwd -d root
passwd -S root

# 确认 nullok（若没有则加上）
if ! grep -q "pam_unix.so.*nullok" /etc/pam.d/common-auth; then
    sed -i 's|^\(auth.*pam_unix\.so\)\(.*\)$|\1\2 nullok|' /etc/pam.d/common-auth
    echo "已给 common-auth 的 pam_unix.so 加 nullok"
fi
grep -n "pam_unix.so" /etc/pam.d/common-auth | tail -2

echo "完成：锁屏按回车即可解锁"
