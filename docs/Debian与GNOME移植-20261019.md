# Debian + GNOME 移植进展（2026-10-19 00:36）

> 设备：Samsung SM-G9209（zeroflte，Exynos7420）
> 目标：在 UFS 上跑 Debian 12，然后装 GNOME

---

## 一、已完成

### 1. 8 核 SMP ✅（重大突破）

**根因：NOHZ（tickless idle）**
```
maxcpus=1                → 正常（但只有 1 核）
maxcpus=2                → 挂死
maxcpus=2 + nohz=off     → ✅ 成功
8 核 + nohz=off          → ✅ online = 0-7
```

**当前 bootargs（`uniLoader/main/diag.c:60`）**：
```
console=tty0 loglevel=8 nohz=off clk_ignore_unused pd_ignore_unused
deferred_probe_timeout=0 rodata=off keep_bootcon mitigations=off
nokaslr kpti=off
```

**调试过程**（全部实测）：
- p169~p177：在 `secondary_entry` → `init_kernel_el` → `__cpu_setup` → `__enable_mmu` →
  `__secondary_switched` 逐步插入 `b .` 自旋点，**全部不挂** ⇒ 汇编路径完全正常
- p178：16 个 C 阶段检查点 ⇒ `r[16] = 0x510c`（CPU1 到 idle）+ `marker = 0x460d02`
- `0x460d02` 解码 = `tty_io.c:3160` 的 `0x460000 | (index<<8) | phase`，index=13(/dev/tty14) + phase=2
- **真正解法：`nohz=off`**

### 2. Debian 12 rootfs ✅

- 下载：`https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-arm64.tar.xz`
- 内容：`disk.raw`（3GB GPT），分区 1 = 2.9G ext4 Debian 12 rootfs
- 已解压到宿主机 `/mnt/debroot`（loop 挂载 `disk.raw` 偏移 262144*512）
- 已打包：`<HOME>/gnome-rootfs/debian-rootfs.tar.gz`（247MB）
- **已写入手机 `/dev/sda20`**（26GB USERDATA）

### 3. switch_root 机制 ✅（部分成功）

**ramdisk 结构**（`uniLoader/blob/ramdisk`，gzip cpio）：
- `/init` — 编译好的 aarch64 ELF，运行 `/etc/rc`
- `/etc/rc` — POSIX shell 脚本（**已修改**，见下）
- `/bin/busybox` — 完整 busybox（有 `mount`/`switch_root`/`chroot`）

**对 `/etc/rc` 的改动**（已插入在 `echo 'G9209 DIAGNOSTICS BEGIN'` 之前）：
```sh
dsh_try_switch_root()
{
    PART="$1"
    N=0
    while [ "$N" -lt 40 ]; do [ -b "$PART" ] && break; N=$((N + 1)); sleep 1; done
    [ -b "$PART" ] || { echo "G9209 switch_root: $PART not found"; return 1; }
    mount -t ext4 -o rw "$PART" /mnt || { echo "mount failed"; return 1; }
    [ -x /mnt/sbin/init ] || { echo "/mnt/sbin/init missing"; umount /mnt; return 1; }
    mount -t proc  none /mnt/proc  2>/dev/null
    mount -t sysfs none /mnt/sys   2>/dev/null
    mount -t devtmpfs none /mnt/dev 2>/dev/null
    exec switch_root /mnt /sbin/init
}
# 默认切根（传 setcmd "norootfs" 可禁用）
dsh_try_switch_root /dev/sda20 || true
```

**实测结果**：p185 启动后出现了 **`BusyBox v1.38.0 (Debian 1:1.38.0-3+b1)`** 的 shell
⇒ **说明已经进入 Debian 的 rootfs** ✓
⇒ **但 systemd 没有正常启动**（回退到 busybox shell）
⇒ **随后 ACM shell 失去响应**（gadget 状态异常）

---

## 二、当前问题

### 问题 1：`/dev/sda20` 是混合的

Android userdata（15G 旧数据）**没有格式化**，Debian 文件直接解压覆盖上去：
```
/mnt/debian/
├── adb, anr, apex, app, app-asec, ...   ← 旧的 Android 目录
├── bin, boot, dev, etc, ...             ← Debian 目录
├── etc/os-release  → Debian 12 ✓
└── sbin/init → /lib/systemd/systemd ✓
```

**⇒ 需要 clean 掉 Android 目录**（用户已同意 `rm -rf`）
**⇒ 更干净的做法：重新 `mke2fs -t ext4` 格式化，然后重新解压**

### 问题 2：systemd 没起来

可能原因：
1. **没有 console/tty** — Debian systemd 需要 `/dev/console`，且 USB ACM gadget（`ttyGS0`）需要
   在 Debian 里注册 getty 服务
2. **`/etc/fstab` 不对** — Debian cloud image 的 fstab 期待 `LABEL=root` 或 UUID
3. **`/etc/systemd/system/getty.target.wants/`** 里没有 ACM 的 getty
4. **mixed rootfs** 里 Android 的东西干扰

**⇒ 建议**：
- 格式化 sda20 → 重新解压 Debian（纯净）
- 在 Debian 里创建：
  ```
  /etc/systemd/system/getty@ttyGS0.service
  /etc/systemd/system/getty.target.wants/getty@ttyGS0.service -> ../getty@ttyGS0.service
  ```
- 删掉 `/etc/fstab` 里的 root 挂载行，或改成注释
- 或者干脆**绕过 systemd**：把 `switch_root` 改成 `switch_root /mnt /bin/bash` 先验证，
  然后手动起 systemd 调试

---

## 三、下一步（按优先级）

### 第一步：清理 sda20（5 分钟）

**方法 A（推荐，最干净）**：
```bash
# TWRP 里
mke2fs -t ext4 -F -L DEBIAN /dev/block/sda20
mount -t ext4 /dev/block/sda20 /mnt/debian
cd /mnt/debian && tar -xzpf /tmp/debian-rootfs.tar.gz
```

**方法 B（不格式化，只删 Android 目录）**：
```bash
cd /mnt/debian
rm -rf adb adbroot anr apex app app-asec app-ephemeral app-lib app-private app-staging \
       backup bcmnfc cache config d data dev app-asec ...
```
**⚠️ 注意**：方法 B 有风险（可能漏删或误删 Debian 文件），**推荐方法 A**。

### 第二步：配置 Debian 的 console/getty

在 `/mnt/debian` 里（宿主机上直接改，免烧机）：
```bash
# 1. 建 getty 服务
mkdir -p etc/systemd/system/getty.target.wants
cat > etc/systemd/system/getty@ttyGS0.service << 'EOF'
[Unit]
Description=Serial Getty on ttyGS0
BindsTo=dev-ttyGS0.device
After=dev-ttyGS0.device
[Service]
ExecStart=-/sbin/agetty -L -a root 115200 ttyGS0 vt100
Restart=always
RestartSec=1
[Install]
WantedBy=getty.target
EOF
ln -sf ../getty@ttyGS0.service etc/systemd/system/getty.target.wants/getty@ttyGS0.service

# 2. 禁用 fstab 里的 root 挂载
sed -i 's/^[^#].*\/ .*/# &/' etc/fstab 2>/dev/null || true

# 3. 建 /dev/console 的 fallback（systemd 需要）
# 这个由 devtmpfs 挂载提供，应该没问题
```

### 第三步：改 switch_root 目标

**先绕过 systemd 验证根文件系统**：
```sh
exec switch_root /mnt /bin/bash
```
如果 bash 能起来 ⇒ **说明 Debian rootfs 是好的** ✓
然后改回 `/sbin/init` 调试 systemd。

### 第四步：装 GNOME

**进入 Debian 后**：
```bash
# 配置网络（WiFi 还没有，先用 USB 网卡或宿主机代理）
# 或者离线安装

apt update
apt install -y gnome-core        # 精简 GNOME
# 或者完整： apt install -y task-gnome-desktop
```

**GNOME 显示需要的组件**：
- **Wayland/X** — Debian 12 默认 Wayland
- **GPU 驱动** — panfrost（已启用但未验证）
- **输入** — 触摸屏 `/dev/input/event0`（已验证可用）
- **显示** — framebuffer（simplefb 已验证）

**⚠️ 风险**：GNOME 可能太重（手机只有 ~3GB RAM），建议先试 **GNOME Flashback** 或 **XFCE**：
```bash
apt install -y xfce4 xfce4-goodies
```

---

## 四、关键文件/路径

| 文件 | 说明 |
|---|---|
| `<HOME>/linux7420/out/p185-padded.img` | **当前镜像**（8核 + nohz=off + switch_root）|
| `<HOME>/linux7420/uniLoader/blob/ramdisk` | ramdisk（已改，含 switch_root）|
| `<HOME>/linux7420/uniLoader/blob/ramdisk.bak-0022` | 原始 ramdisk（可回退）|
| `<HOME>/linux7420/uniLoader/main/diag.c:60` | bootargs |
| `<HOME>/gnome-rootfs/debian-rootfs.tar.gz` | Debian 12 rootfs（247MB）|
| `<HOME>/gnome-rootfs/rootfs/disk.raw` | Debian 原始镜像（3GB）|
| `/mnt/debroot` | 宿主机上 loop 挂载的 Debian rootfs |

## 五、构建入口

**唯一正确的构建方式**：
```bash
cd <HOME>/linux7420
./build_mainline.sh pNNN
```

**刷机流程**：
```
loader → "reboot recovery" → TWRP → adb push + dd BOOT → reboot → loader → "boot"
```

**⚠️ 注意**：只有 `BOOT` 分区（index 8）可以写，**绝对不要碰** BOOTLOADER/PIT/EFS/PARAM。
