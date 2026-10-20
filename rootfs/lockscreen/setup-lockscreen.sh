#!/bin/bash
# G9209 安卓式锁屏配置
#
# 目标行为（对齐 Android）：
#   1. 按电源键      → 锁屏 + 灭屏
#   2. 再按电源键    → 亮屏，显示锁屏界面
#   3. 上滑/按回车   → 解锁进桌面（无密码）
#   4. 闲置超时      → 自动锁屏灭屏
#
# 关键前提（缺一不可，都是踩过坑的）：
#   * ibus-daemon 只能有一个（重复会导致输入法/键盘异常）
#   * root 密码必须为空（passwd -d root），否则锁屏要输密码
#   * /etc/systemd/logind.conf 的 HandlePowerKey=lock 必须写在主文件里
#     （logind.conf.d 的 drop-in 实测不生效！）
#   * 锁屏/登录界面要有触摸权限：/etc/udev/rules.d/99-g9209-input-uaccess.rules
#   * GDM 的 monitors.xml 要包含实际 connector（VGA-1），否则缩放错乱

set -e

echo "=== 1. root 密码清空（锁屏回车即可解锁）==="
passwd -d root
passwd -S root

echo "=== 2. logind：电源键锁屏（必须写主配置）==="
cat > /etc/systemd/logind.conf << 'CONF'
# G9209 电源键策略（安卓式锁屏）
# 注意：/etc/systemd/logind.conf.d/*.conf 的 drop-in 实测没有被合并
# （systemd-analyze cat-config 仍显示默认注释值），所以直接改主配置。
[Login]
HandlePowerKey=lock
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
CONF
systemctl restart systemd-logind
sleep 2
systemd-analyze cat-config systemd/logind.conf | grep -E "^Handle"

echo "=== 3. GNOME 锁屏策略 ==="
cat > /etc/dconf/db/local.d/00-g9209-lockscreen << 'DC'
# G9209 安卓式锁屏
# 不要写 lock-enabled=false！那会让 GNOME 报
# "Screen lock is locked down, not locking"，电源键完全失效。
[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=0
idle-activation-enabled=true

[org/gnome/desktop/session]
# 闲置多久自动锁屏（秒）。300 = 5 分钟，类似 Android 默认。
idle-delay=uint32 300

[org/gnome/desktop/lockdown]
disable-lock-screen=false

[org/gnome/settings-daemon/plugins/power]
# 不要挂起！这块板子的 suspend/resume 没实现，一挂就死。
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
# 电源键交给 logind 处理，GNOME 不要抢
power-button-action='nothing'

[org/gnome/desktop/interface]
# 锁屏/登录界面也要能触摸键盘
toolkit-accessibility=true
DC
dconf update

echo "=== 4. 触摸设备 uaccess（锁屏/GDM 界面要能触屏）==="
cat > /etc/udev/rules.d/99-g9209-input-uaccess.rules << 'RULE'
# Debian 默认只给游戏手柄 uaccess 标签，触摸屏/按键没有，
# 导致 GDM greeter（用户 Debian-gdm）拿不到 /dev/input/event1 的 ACL，
# 锁屏和登录界面完全没有触摸输入。
SUBSYSTEM=="input", TAG+="uaccess"
RULE
udevadm control --reload-rules
udevadm trigger --subsystem-match=input --action=change

echo "=== 5. GDM 缩放配置（避免锁屏缩放错乱）==="
if [ -f /root/.config/monitors.xml ]; then
    mkdir -p /var/lib/gdm3/.config
    cp /root/.config/monitors.xml /var/lib/gdm3/.config/monitors.xml
    chown Debian-gdm:Debian-gdm /var/lib/gdm3/.config/monitors.xml
    chmod 644 /var/lib/gdm3/.config/monitors.xml
    echo "  已同步 monitors.xml 到 GDM"
fi
usermod -aG input,video,render Debian-gdm 2>/dev/null || true

echo "=== 6. 应用用户级设置（在 GNOME 会话内执行才有效）==="
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus
gsettings set org.gnome.desktop.screensaver lock-enabled true        2>/dev/null || true
gsettings set org.gnome.desktop.screensaver lock-delay 0             2>/dev/null || true
gsettings set org.gnome.desktop.screensaver idle-activation-enabled true 2>/dev/null || true
gsettings set org.gnome.desktop.lockdown disable-lock-screen false   2>/dev/null || true
gsettings set org.gnome.desktop.session idle-delay 300               2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'nothing' 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true

echo "=== 完成 ==="
echo "现在按电源键应该：锁屏 + 灭屏；再按一次：亮屏 + 锁屏界面；按回车/上滑解锁"
