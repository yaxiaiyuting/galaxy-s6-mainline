# 避坑：Electron/Chromium 在 exynos-drm 上崩溃桌面（render node EPERM）

日期：2026-10-23
设备：SM-G9209，Exynos 7420，mainline 6.6，exynos-drm

---

## 现象

从 dock 点击 Electron 应用（SPlayer）→ **整个 GNOME 会话崩溃**，
VT 跳 tty1，严重时整机重启。

journalctl：

```
gnome-shell: meta_later_add: assertion 'display' failed
gnome-shell: meta_later_remove: assertion 'display' failed
gnome-shell: Could not release device '/dev/input/event0':
             The name :1.8 was not provided by any .service files
```

应用侧日志：

```
Failed to create scanout resource
DRM_IOCTL_MODE_CREATE_DUMB failed: 权限不够
Cannot create bo with format=RGBA_8888 and usage=Scanout|Rendering|Texturing
```

## 根因（一行内核代码）

`drivers/gpu/drm/drm_ioctl.c:680`：

```c
DRM_IOCTL_DEF(DRM_IOCTL_MODE_CREATE_DUMB, drm_mode_create_dumb_ioctl, 0),
                                                                    ↑
                                                            flags = 0
```

`drm_ioctl_permit()`（同文件 :547）：

```c
/* Render clients must be explicitly allowed */
if (unlikely(!(flags & DRM_RENDER_ALLOW) && drm_is_render_client(file_priv)))
        return -EACCES;
```

**`CREATE_DUMB` 的 flags 是 0，没有 `DRM_RENDER_ALLOW`，
所以在 render node（`/dev/dri/renderD129`）上调用必然被拒。**

Electron/Chromium 的 GPU 进程默认就用 render node，
于是反复重试创建 scanout buffer → 这个异常路径把 mutter 的
`MetaDisplay` 状态搞坏 → `meta_later_add: assertion 'display' failed`
→ 会话崩溃。

## 修复（两个方案，都不用改内核）

### 方案 A：让 GPU 进程改用 primary node（推荐）

```bash
--render-node-override=/dev/dri/card0
```

用 card0 时 `drm_is_render_client()` 返回假，权限检查不触发，
dumb buffer 可以正常创建。

完整启动参数：

```bash
/opt/SPlayer/SPlayer --no-sandbox \
    --ozone-platform=wayland \
    --render-node-override=/dev/dri/card0 \
    --disable-gpu-sandbox \
    --disable-dev-shm-usage
```

**注意：不要用 X11（`DISPLAY=:0`）路径。**
本机 Xwayland 下 Electron 的窗口会停在 `WM_STATE: Withdrawn`
（`BrowserWindow({show:false})` + `ready-to-show` 在软件渲染下不触发），
`xwininfo` 说 `IsViewable` 但用户看不到任何东西。

### 方案 B：内核 patch（如果方案 A 在某些应用上无效）

```c
/* drivers/gpu/drm/drm_ioctl.c */
DRM_IOCTL_DEF(DRM_IOCTL_MODE_CREATE_DUMB, drm_mode_create_dumb_ioctl,
              DRM_RENDER_ALLOW),
```

副作用：允许 render client 创建 KMS dumb buffer。
对只有我们自己用的设备无害，但 upstream 不会接受。

## 适用面

**所有 Electron/Chromium 应用**：SPlayer、VS Code、Discord、Obsidian、
Chromium、Chrome、Edge…

在这台设备上**统一加 `--render-node-override=/dev/dri/card0`**。

## 验证

```sh
# 启动后检查
grep -c "DUMB\|EPERM\|scanout" /tmp/app.log   # 应该 0
pgrep -c gnome-shell                          # 应该没变化
cat /sys/class/tty/tty0/active                # 应该还是 tty2
```
