#!/bin/bash
# G9209 图形性能优化 —— 让 GTK4 应用真正走 GPU
set -e

echo "=== 1. /etc/environment ==="
cp -n /etc/environment /etc/environment.bak 2>/dev/null || true
cat > /etc/environment << 'ENV'
# G9209 图形性能配置
#
# 背景：早期为绕开 panfrost 的 js fault / SError，全局强制 GSK_RENDERER=cairo，
# 结果所有 GTK4 应用（GNOME 设置、文件管理器、文本编辑器…）退化成纯软件渲染。
# 实测 glmark2（720x1280）：
#     cairo 软件渲染          Score  59   (FPS 60,  16.8 ms)
#     panfrost GL 硬件渲染    Score 532   (FPS 533,  1.9 ms)   → 8.9 倍
#
# 注意：GTK 4.8（Debian 12）只认 gl / vulkan / cairo 三个值，
#       ngl 是 GTK 4.14+ 才有的，写 ngl 会报
#       "Gsk-WARNING: Unrecognized renderer \"ngl\"" 并退回 cairo。
GSK_RENDERER=gl

# PAN_MESA_DEBUG 取舍（2026-10-20 实测，详见
# 文档/05-专项/panfrost-AFBC深度研究-20261020.md）：
#   * AFBC 在本机（Mali-T760 r0p1 + Mesa 22.3.6）没有可测收益：
#     glmark2 12 个场景 × 3 配置 × 720x1280，开/关 AFBC 的 FPS 差异在噪声内
#     （多数场景 AFBC 关闭反而更快），且 mainline 内核没有实现 T760 r0p1 的
#     AFBC errata（HW_ISSUE_T76X_3542）。→ 用 noafbc。
#   * nocrc 关掉 transaction elimination。去掉了在部分场景快 0~9%，但需要长
#     时间验证（历史上出现过花屏/毛刺），暂保留。想 A/B 时把下面这行改成
#     PAN_MESA_DEBUG=noafbc  即可，出问题改回来不用重启（重登会话生效）。
PAN_MESA_DEBUG=noafbc,nocrc
ENV
cat /etc/environment

echo "=== 2. GDM 会话环境 ==="
mkdir -p /etc/systemd/system/gdm.service.d
cat > /etc/systemd/system/gdm.service.d/50-g9209-render.conf << 'DROP'
[Service]
# 必须与 /etc/environment 保持一致：两处都写 noafbc,nocrc。
# （pam_env 会覆盖 systemd 的 Environment=，两处不一致时排查会非常迷惑）
Environment=GSK_RENDERER=gl
Environment=PAN_MESA_DEBUG=noafbc,nocrc
DROP

echo "=== 3. usb0 不再抢默认路由 ==="
# 原配置给 usb0 配了 Gateway=192.168.42.1，生成 proto static 的默认路由
# (metric 0)，优先级高于 WiFi 的 DHCP 默认路由 (metric 600)，
# 所有出网流量走 USB（宿主没做 NAT），手机完全没网。
cat > /etc/systemd/network/20-usb0-static.network << 'NET'
[Match]
Name=usb0

[Network]
Address=192.168.42.2/24
LinkLocalAddressing=no
NET

systemctl daemon-reload
systemctl restart systemd-networkd 2>/dev/null || true

echo "=== 4. 保持之前的防挂起设置 ==="
# 见 g9209-no-suspend.sh

echo "完成。重启 GDM 或整机生效："
echo "  systemctl restart gdm"
