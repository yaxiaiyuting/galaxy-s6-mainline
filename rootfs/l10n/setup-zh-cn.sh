#!/bin/bash
# G9209 中文本地化 + GNOME 插件 + 输入法
# 在手机上以 root 运行
set -e
export DEBIAN_FRONTEND=noninteractive

echo "=== 1. 换国内 apt 源（默认镜像在国内只有 8KB/s） ==="
cp /etc/apt/sources.list /etc/apt/sources.list.bak-$(date +%s) 2>/dev/null || true
cat > /etc/apt/sources.list << 'SRC'
deb http://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware
SRC
apt-get update

echo "=== 2. 中文字体 ==="
# fonts-noto-cjk 有 100MB+，国内网慢时可以从宿主机拷：
#   scp /usr/share/fonts/noto-cjk/NotoSansCJK-{Regular,Bold}.ttc root@<phone>:/usr/share/fonts/truetype/noto-cjk/
mkdir -p /usr/share/fonts/truetype/noto-cjk
if ! fc-list | grep -q "Noto Sans CJK"; then
  apt-get install -y --no-install-recommends fonts-noto-cjk
fi
fc-cache -f

echo "=== 3. fontconfig：zh 优先简体字形 ==="
# NotoSansCJK-*.ttc 是集合字体，含 JP/SC/TC/HK/KR 五种字形。
# fontconfig 默认按 family 排序会命中 JP，导致简体中文用日文字形
# （"直""骨""门" 等写法不对）。必须显式给 zh-* 语言绑定 SC。
cat > /etc/fonts/conf.d/99-g9209-zh-cn.conf << 'FC'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="pattern">
    <test name="lang" compare="contains"><string>zh</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Noto Sans CJK SC</string>
    </edit>
  </match>
  <alias binding="strong">
    <family>sans-serif</family>
    <prefer><family>Noto Sans CJK SC</family></prefer>
  </alias>
</fontconfig>
FC
fc-cache -f

echo "=== 4. 中文 locale ==="
sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
localectl set-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

echo "=== 5. 中文输入法（ibus + libpinyin） ==="
apt-get install -y --no-install-recommends ibus ibus-libpinyin
# ⚠️ 不要自己加 ibus 的 autostart！GNOME Shell 自己会启动
#    `/usr/bin/ibus-daemon --panel disable`（见 gnome-shell 的
#    org.gnome.Shell 启动逻辑）。如果再加一个 `ibus-daemon -drx`，
#    就会有两个 daemon 抢同一套 D-Bus 输入法通道 —— 表现就是
#    **屏幕键盘按键被吞、拼音组合丢字**。
#    实测：出现两个 daemon 时 GNOME OSK + 拼音完全不可用；
#    杀掉重复的那个后立刻正常。
#    （曾经加过 /root/.config/autostart/ibus.desktop，已删除）
rm -f /root/.config/autostart/ibus.desktop 2>/dev/null || true
pkill -f "ibus-daemon -drx" 2>/dev/null || true
# 需要登录后 GNOME 会话内执行：
#   gsettings set org.gnome.desktop.input-sources sources "[('ibus','libpinyin'),('xkb','us')]"

echo "=== 6. 屏幕键盘 ==="
# 不要用 onboard！实测在 Wayland + IBus 下会**吞字**（按键注入与输入法抢事件）。
# GNOME 43 自带屏幕键盘（gnome-shell 的 js/ui/keyboard.js），
# Wayland 原生、与 IBus 集成，按下面的 gsettings 打开即可。
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
# 如果之前装过 onboard，卸掉避免两个键盘打架：
apt-get remove -y onboard onboard-common 2>/dev/null || true
rm -f /etc/xdg/autostart/onboard-autostart.desktop 2>/dev/null || true

echo "=== 7. GNOME 插件（GNOME 不装插件基本没法用） ==="
apt-get install -y --no-install-recommends \
  gnome-shell-extension-dashtodock \
  gnome-shell-extension-appindicator \
  gnome-shell-extension-autohidetopbar \
  gnome-shell-extension-impatience \
  gnome-shell-extension-panel-osd \
  gnome-shell-extension-manager

echo "=== 8. 会话内配置（需要在图形会话中跑） ==="
cat << 'NOTE'
登录 GNOME 后执行：

  export XDG_RUNTIME_DIR=/run/user/0
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

  # 输入法
  gsettings set org.gnome.desktop.input-sources sources "[('ibus','libpinyin'),('xkb','us')]"

  # 启用插件（gsettings 方式，CLI 在重启 GDM 前不认识新装的扩展开）
  gsettings set org.gnome.shell enabled-extensions "['dash-to-dock@micxgx.gmail.com','ubuntu-appindicators@ubuntu.com','hidetopbar@mathieu.bidon.ca','impatience@gfxmonk.net','panel-osd@berend.de.schouwer.gmail.com']"

  # Dash to Dock 手机布局
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
  gsettings set org.gnome.shell.extensions.dash-to-dock autohide true
  gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 40

  # 字体
  gsettings set org.gnome.desktop.interface font-name 'Noto Sans CJK SC 11'
  gsettings set org.gnome.desktop.interface document-font-name 'Noto Sans CJK SC 11'
  gsettings set org.gnome.desktop.interface monospace-font-name 'Noto Sans Mono CJK SC 10'

然后 systemctl restart gdm
NOTE
echo "完成"
