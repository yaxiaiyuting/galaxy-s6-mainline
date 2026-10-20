#!/bin/bash
# G9209 桌面体验调优（需在图形会话内运行）
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus
S=org.gnome.shell.extensions.dash-to-dock

# ── 1. 关热角 ────────────────────────────────────────────────
# 手机屏幕上 GNOME 左上角热角极易被边缘触摸误触，抢走正常输入
gsettings set org.gnome.desktop.interface enable-hot-corners false

# ── 2. 关动画 ────────────────────────────────────────────────
# Mali-T760 上动画帧率不足，关掉后操作反馈更直接
gsettings set org.gnome.desktop.interface enable-animations false

# ── 3. 去掉 scale-monitor-framebuffer ────────────────────────
# 这是**小数缩放**的实验特性。本机用 200%（整数 2x），不需要它。
gsettings set org.gnome.mutter experimental-features "[]"

# ── 4. Dash to Dock = 左侧常驻任务栏（核心改动）──────────────
# 手机触摸屏**边缘灵敏度天然较差**（见 docs/触摸边缘问题调研-20261021.md）：
# 电容屏边缘电极面积小、与边框耦合弱，边缘触摸需要更大接触面积才稳定。
# 所以底部自动隐藏的 Dock（要碰底边唤醒）体验很差。
# 改成**左侧常驻显示**：不依赖边缘手势，图标 52px 好点，
# 顶部有"显示应用"按钮，相当于 Windows 任务栏。
gsettings set $S dock-position 'LEFT'
gsettings set $S dock-fixed true          # 常驻，不隐藏
gsettings set $S autohide false
gsettings set $S extend-height true       # 全高
gsettings set $S dash-max-icon-size 52    # 触屏友好
gsettings set $S show-apps-at-top true    # 顶部"显示应用"按钮
gsettings set $S background-opacity 0.75
gsettings set $S transparency-mode 'FIXED'
gsettings set $S click-action 'launch'    # 点一下直接启动（触屏最直观）
gsettings set $S scroll-action 'do-nothing'   # 触屏上滚动切换易误触
gsettings set $S show-mounts false
gsettings set $S show-trash false

# ── 5. 顶栏加"Applications"菜单 ─────────────────────────────
# 左上角 Activities 按钮太小，边缘又难按；Applications 下拉菜单
# 是大号按钮，配合顶栏常显（禁用 hidetopbar）后好用很多。
gnome-extensions enable apps-menu@gnome-shell-extensions.gcampax.github.com

# ── 6. 顶栏常显（禁用 hidetopbar）───────────────────────────
gnome-extensions disable hidetopbar@mathieu.bidon.ca 2>/dev/null || true

echo "desktop tuning applied (left sidebar taskbar)"
