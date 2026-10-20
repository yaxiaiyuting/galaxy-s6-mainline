#!/bin/bash
# G9209: 禁止一切自动挂起/休眠/熄屏
# 问题：手机放一天不动后显示不亮 —— GNOME 空闲 suspend，
#       而本项目 suspend/resume 没移植好，唤不醒。
set -e
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

# 1. GNOME 电源设置
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0
gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action 'nothing'

# 2. dconf 系统默认
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-g9209-power << 'DC'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
power-button-action='nothing'

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
DC
dconf update 2>/dev/null || true

# 3. 系统级 mask
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true

# 4. logind
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-g9209-powerkey.conf << 'LD'
[Login]
HandlePowerKey=lock
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
LD
systemctl restart systemd-logind || true
echo "G9209 no-suspend configured"
