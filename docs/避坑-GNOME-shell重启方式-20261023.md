# 避坑：GNOME Shell 重启的正确方式

日期：2026-10-23
影响：所有需要让 gnome-shell / libinput 重新读取配置的操作

---

## 问题

想重启 GNOME Shell（比如让 libinput 重读 udev hwdb 的按键重映射），
用了这个：

```sh
kill -TERM $(pgrep -f 'gnome-shell$' | head -1)
```

**结果：用户会话直接挂掉。**

现象链：
1. `kill -TERM gnome-shell` → 用户会话的 shell 进程退出
2. gnome-session 无法恢复 → 会话终止
3. **GDM 把 VT 切到 tty1（greeter）**
4. `loginctl list-sessions` 里**只剩 `Debian-gdm` 的 greeter 会话**，
   没有 `root/wayland` 的会话
5. `org.gnome.Shell` 的 D-Bus 接口消失
   ```
   GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown:
     The name org.gnome.Shell was not provided by any .service files
   ```
6. `org.gnome.Shell.Extensions` 服务启动失败（exit 1）
   → **所有扩展（Dash to Dock、apps-menu、ubuntu-appindicators）加载失败**
   → `gnome-extensions list --enabled` 返回空
   → 左侧任务栏消失
7. 屏幕停在 GDM 登录界面（要输密码，或者 autologin 没触发）

## 正确做法

### 方案 A（推荐）：重启 GDM

```sh
systemctl restart gdm
```

`/etc/gdm3/daemon.conf` 里配了 `AutomaticLoginEnable=true` +
`AutomaticLogin=root`，所以 35 秒左右会**自动登回 root 会话**，
VT 回到 tty2，`org.gnome.Shell` 恢复，扩展正常加载。

### 方案 B：如果只是想重读某类配置

| 想重读什么 | 正确命令 |
|---|---|
| udev hwdb 按键映射 | `systemd-hwdb update && udevadm trigger --subsystem-match=input --action=change`，然后**重启 GDM**（libinput 在 shell 启动时读） |
| dconf / gsettings | `dconf update`（用户级）/ `gsettings set ...`（立即生效，无需重启 shell） |
| GNOME 扩展 | `gnome-extensions enable <id>`（立即生效） |
| 系统 dconf 默认 | `dconf update` 后**重启 GDM**（新会话才读） |

## 验证清单

重启 GDM 后确认：

```sh
cat /sys/class/tty/tty0/active          # 应该是 tty2
loginctl list-sessions --no-legend      # 应该有 root + wayland + seat0
gdbus introspect --session --dest org.gnome.Shell --object-path /org/gnome/Shell | head -1
gnome-extensions list --enabled         # 应该有 4 个扩展
cat /sys/devices/system/cpu/online      # 0-7
```

## 已做的持久化

`g9209-session-fix.service` 会在每次开机时：
- 修 `/tmp` 和 `/tmp/.X11-unix` 权限（否则 shell 起不来 Wayland 会话）
- 把所有用户会话的 `disable-user-extensions` 强制设为 `false`

但**它管不了运行中 kill shell 的情况** —— 那种情况只能重启 GDM。
