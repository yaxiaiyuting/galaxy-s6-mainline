#!/bin/bash
# G9209 桌面体验调优（需在图形会话内运行）
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

# 1. 关热角 —— 手机上左/上边缘的触摸很容易误触热角，抢走正常输入
gsettings set org.gnome.desktop.interface enable-hot-corners false

# 2. 关动画 —— Mali-T760 上动画帧率不足，关掉后操作反馈更快
gsettings set org.gnome.desktop.interface enable-animations false

# 3. 去掉 scale-monitor-framebuffer
#    这是**小数缩放**的实验特性。本机用 200%（整数 2x），不需要它。
#    实测开关前后合成器帧率无差异（31→32fps），但关掉能少一次离屏 pass 的潜在开销。
gsettings set org.gnome.mutter experimental-features "[]"

# 4. Dash to Dock 边缘优化 —— 降低压力阈值，避免底部边缘手势迟钝
gsettings set org.gnome.shell.extensions.dash-to-dock pressure-threshold 0.0 2>/dev/null || true
gsettings set org.gnome.shell.extensions.dash-to-dock require-pressure-to-show false 2>/dev/null || true
gsettings set org.gnome.shell.extensions.dash-to-dock autohide true 2>/dev/null || true
gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM' 2>/dev/null || true
gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 40 2>/dev/null || true

echo "desktop tuning applied"
