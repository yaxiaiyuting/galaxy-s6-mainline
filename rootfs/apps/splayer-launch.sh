#!/bin/bash
# G9209: SPlayer 启动包装脚本
#
# 关键参数（务必保留）：
#   --ozone-platform=wayland    必须走 Wayland（X11 路径下窗口是 Withdrawn 状态，显示不出来）
#   --render-node-override=/dev/dri/card0
#       默认 Electron 用 renderD129，而 DRM_IOCTL_MODE_CREATE_DUMB 在
#       mainline 里 flags=0（无 DRM_RENDER_ALLOW），render client 调它会被
#       drm_ioctl_permit() 拒绝 → EACCES 反复重试 → mutter 崩溃 → 桌面掉
#       改用 card0 后不触发 render client 检查，dumb buffer 正常创建
#   --disable-gpu-sandbox        root 下沙箱会和 --no-sandbox 冲突
set -u
APP=/opt/SPlayer/SPlayer
LOG=/tmp/splayer-launch.log

if pgrep -f "$APP" >/dev/null 2>&1; then
    logger -t splayer-launch "already running, bringing to front"
    exit 0
fi

nohup "$APP" \
    --no-sandbox \
    --ozone-platform=wayland \
    --render-node-override=/dev/dri/card0 \
    --disable-gpu-sandbox \
    --disable-dev-shm-usage \
    "$@" > "$LOG" 2>&1 &

logger -t splayer-launch "started pid $!"
