# systemd 启动失败根因与修复（2026-10-19）

> 设备：Samsung SM-G9209（zeroflte，Exynos7420）
> 结论：**根因不是 systemd、不是 rootfs、不是内核配置，而是 PID 1 归属错误**

---

## 一、根因（决定性发现）

### 1.1 `/etc/rc` 不是 PID 1

ramdisk 的 `/init` 是 `bringup/pmsg-init.c` 编译出来的，它的逻辑：

```c
// bringup/pmsg-init.c
L81:  if (argc != 1 || getpid() != 1) return 2;      /* 只有 PID1 才继续 */
L82-86: mount /proc /sys /dev /dev/pts /tmp
L87-91: open("/dev/console"), dup2 到 0/1/2          /* 注意：此时 ttyGS0 console 还没注册 */
L94-95: open("/dev/pmsg0"), open("/dev/kmsg")
L96-101: 读 DT chosen/g9209,command
L107:  pipe2(pipefd)
L108:  child = fork();
L109:  if (child == 0) {
L110:      char *args[] = {"sh", "/etc/rc", NULL};
L112:      setsid();
L113:      dup2(pipefd[1], 1); dup2(pipefd[1], 2);   /* rc 的 stdout 进 pipe */
L115:      execve("/bin/sh", args, env);            /* ★ rc 是 PID 2+ */
L118:  }
L122-136: poll 读 pipe，report() 输出
L139-147: waitpid
L148-151: report "REPORT END"
L152-159: 若自动模式 → reboot
L160-165: idle: for(;;) { waitpid(-1,...,WNOHANG); pause(); }   /* 永久空闲 */
```

**⇒ `/etc/rc` 是 PID 2+，不是 PID 1。**

### 1.2 busybox `switch_root` 拒绝非 PID 1

ramdisk 里的 busybox 1.38.0，`util-linux/switch_root.c`：

```c
if (!dry_run && getpid() != 1) {
    // Show usage, it says we must be PID 1
    bb_show_usage();          /* 打印 usage → exit(1) */
}
```

**这一行在 `delete_contents("/")` 和 `mount(".", "/", MS_MOVE)` 之前。**
⇒ **`exec switch_root` 从来没有切过根，只是打印 usage 就退出了。**

### 1.3 systemd 也要求 PID 1

`systemd 252` `src/core/main.c:2537-2541`：
```
"Can't run system mode unless PID 1."
```

⇒ 所以**必须由 PID1 进程本人 exec systemd**。

---

## 二、这解释了之前所有的"诡异现象"

| 现象 | 真实原因 |
|---|---|
| switch_root 后**无任何输出** | rc 子进程的 stdout/stderr 被 `dup2` 进 pipe；`pmsg-init` 的 `report()` 写的是它启动时打开的 `/dev/console`，那时 ttyGS0 的内核 console 还没注册（`u_serial.c:1019 gs_console_init()` 要等 rc 配好 ACM 才 register_console）⇒ fd 全生命周期是 **tty0** ⇒ 屏幕可见、USB 不可见 |
| **没有 panic / 没有重启** | PID1（pmsg-init）从头到尾没退出，只在 `pause()` 循环；子进程退出 ≠ PID1 退出，`panic=10` 永远不触发 |
| **journal 空、`/dsh-diag.txt` 不存在** | **systemd 一秒都没跑** |
| p185 "看到 BusyBox shell ⇒ 已进 Debian" | **错**。那是 rc 尾部 `usb_console` 在 **ramdisk** 里起的 getty（它打开 /dev/ttyGS0，所以可见） |
| chroot 报 `ENOENT on /bin/sh` | Lead 的 precheck bug（在挂载 `/mnt` 之前就 chroot 了），已修 |
| 为什么内核 printk 在 USB 上可见 | `gs_console_init()` 的 `register_console()` 带 `CON_PRINTBUFFER`，注册时把整段 dmesg 回放到 USB |

---

## 三、修复：PID 1 handover

### 3.1 `bringup/pmsg-init.c` —— 在 waitpid 之后插入

```c
/*
 * DSH: PID1 handover.
 *
 * /etc/rc runs as a child of this process, so busybox switch_root's
 * "getpid() != 1" guard makes it print usage and exit without ever
 * switching root.  rc therefore writes the handover parameters and
 * exits with status 88; this process -- which really is PID 1 -- then
 * execs switch_root itself.
 */
if (WIFEXITED(status) && WEXITSTATUS(status) == 88) {
    char hbuf[512] = {0}, hroot[256] = "/mnt", hinit[256] = "/sbin/init";
    int hfd = open("/tmp/dsh-handover", O_RDONLY | O_CLOEXEC);
    if (hfd >= 0) { /* 第一行=root，第二行=init */ }
    /* 显式写 ttyGS0，因为 report() 的 fd1 是 tty0，USB 看不见 */
    int tty = open("/dev/ttyGS0", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    if (tty >= 0) {
        dprintf(tty, "G9209 PID1 HANDOVER root=%s init=%s pid=%d\n", ...);
        tty_sync(tty); close(tty);
    }
    char *hargs[] = {"switch_root", hroot, hinit, NULL};
    execv("/bin/switch_root", hargs);      /* 此时 getpid()==1 ✓ */
    /* 失败必须 loud，否则又变成"静默挂死" */
    _exit(127);                            /* PID1 退出 → panic → panic=10 重启 */
}
```

**注意**：`tty_sync()` 用固定 `usleep(120ms)`，**不用 `tcdrain()`**
（gadget ACM 在没有主机 attach 时 `tcdrain` 可能永久阻塞，而 handover 绝不能卡死）。

### 3.2 `rc` 的 `dsh_try_switch_root()` 末尾

```sh
# ---- PID1 handover ----
# 本脚本是 pmsg-init 的子进程（PID>=2），busybox switch_root 会因
# getpid()!=1 直接打印 usage 退出。所以把参数写给 PID1，然后 exit 88；
# pmsg-init 收到 88 后由它自己 exec /bin/switch_root（那时它才是 PID1）。
printf '%s\n%s\n' "/mnt" "$TARGET" > /tmp/dsh-handover
dsh_log "switch: HANDOVER to PID1 (exit 88), target=$TARGET"
sync
sleep 2
exit 88
```

### 3.3 切根策略（避免破坏诊断流程）

之前只要 `g9209,command` 不含 `norootfs` 就切根 —— 但以前 switch_root 因 PID 检查
失败而静默继续，所以 `setcmd` 诊断流程还能工作。**修好 handover 之后，任何 setcmd
都会切进 Debian，`overnight.py` / `test_ufs_usb_acm.py` 等全部失效。**

所以改成：

```sh
DSH_SWITCH=0
DSH_CMD=""
[ -r /sys/firmware/devicetree/base/chosen/g9209,command ] && \
    DSH_CMD=$(tr -d '\000' < /sys/firmware/devicetree/base/chosen/g9209,command)
case "$DSH_CMD" in
    *norootfs*)   DSH_SWITCH=0 ;;   # 显式禁用
    "")           DSH_SWITCH=1 ;;   # 无命令 → 默认启动 Debian
    *bootdebian*) DSH_SWITCH=1 ;;   # 显式启动 Debian
    *)            DSH_SWITCH=0 ;;   # 其它 setcmd → 走诊断流程
esac
dsh_log "boot: cmd_len=${#DSH_CMD} switch=$DSH_SWITCH"
```

### 3.4 precheck 失败要拒绝 handover

```sh
if chroot /mnt /bin/sh -c 'echo PRECHECK-SH-OK; /sbin/init --version 2>&1 | head -3; uname -r' > /dev/ttyGS0 2>&1; then
    dsh_log "precheck: chroot + /sbin/init OK"
else
    dsh_log "precheck: chroot FAILED -- refuse to handover"
    umount /mnt/dev /mnt/sys /mnt/proc /mnt/run /mnt 2>/dev/null
    return 1
fi
```

**注意**：precheck 必须在 `mount /dev/sda20 /mnt` **之后**执行（早期版本放错了位置，
导致 chroot 进 ramdisk 的空 `/mnt`，报 ENOENT 假警报）。

---

## 四、完整启动链路（修复后）

```
S-Boot
  → uniLoader（TEXT_BASE=0x47000000）
  → 内核 Image @ 0x90000000
  → /init = pmsg-init (PID 1)
       ├─ mount /proc /sys /dev /dev/pts /tmp
       ├─ fork → /bin/sh /etc/rc (PID 2)
       │    ├─ 配 USB ACM gadget（configfs → ttyGS0）
       │    ├─ 等 /dev/sda20（UFS）
       │    ├─ mount -t ext4 /dev/sda20 /mnt
       │    ├─ mount /mnt/{proc,sys,dev,run}
       │    ├─ precheck: chroot /mnt /bin/sh -c '... /sbin/init --version'
       │    ├─ 写 /tmp/dsh-handover（root + init）
       │    └─ exit 88
       ├─ waitpid → status 88
       └─ ★ execv("/bin/switch_root", {"/mnt", "/sbin/init"})   ← PID 1 ✓
            └─ switch_root: MS_MOVE + chroot + exec /sbin/init
                 └─ ★ systemd (PID 1) ✓
```

---

## 五、bootargs

```
console=tty0 console=ttyGS0 loglevel=8 nohz=off panic=10
systemd.log_level=debug systemd.log_target=kmsg
clk_ignore_unused pd_ignore_unused deferred_probe_timeout=0
rodata=off keep_bootcon mitigations=off nokaslr kpti=off
```

**要点**：
- `console=ttyGS0` 让内核 printk（含 systemd PID1 的 kmsg 日志）出现在 USB ACM 上
- `systemd.log_target=kmsg`：PID1 默认就是 kmsg，显式写更保险
  （`/etc/systemd/system.conf.d/dsh.conf` 里的 `LogTarget=journal` 会被 cmdline 覆盖，
  但建议删掉那文件）
- `panic=10`：systemd 早期失败会 exit → panic → 10 秒后自动重启，便于恢复
- `nohz=off`：**8 核必需**（否则 tickless idle 会冻结 SoC）

---

## 六、构建与验证

```bash
cd <HOME>/linux7420/bringup
# 1. 编译 pmsg-init 并重建 ramdisk（替换 init + etc/rc）
python3 build_pmsg_ramdisk.py /tmp/base-ramdisk.gz /tmp/ramdisk-new.gz
# 2. 安装
cp /tmp/ramdisk-new.gz ../uniLoader/blob/ramdisk
# 3. 构建镜像
cd .. && ./build_mainline.sh pNNN
```

`build_pmsg_ramdisk.py` 会：
- 用 `aarch64-linux-gnu-gcc -std=c11 -O2 -Wall -Wextra -Werror -static -s` 编译 `pmsg-init.c`
- 用 `qemu-aarch64` 跑 `--self-test`
- 替换 cpio 里的 `init` 和 `etc/rc`（其余 297 个成员字节级不变）
- 用 qemu + 真 busybox 做 `sh -n` 语法检查

---

## 七、待验证（手机充电中）

镜像 **p195** 已构建：`f303aecd19a50063e732f75c9ac8d26a97f1bd90`

**预期 USB 输出**：
```
G9209 boot: cmd_len=0 switch=1
...
G9209 switch: start, part=/dev/sda20 target=/sbin/init
G9209 switch: mounted OK
G9209 precheck: chroot + /sbin/init OK
G9209 switch: HANDOVER to PID1 (exit 88), target=/sbin/init
G9209 PID1 HANDOVER root=/mnt init=/sbin/init pid=1
[systemd 的 debug 日志...]
```

**如果 systemd 失败** → `G9209 HANDOVER FAILED` + panic → 10 秒重启 → ramoops 可取尸体。

---

## 八、尚未处理

1. `/etc/systemd/system/system.conf.d/dsh.conf` 里的 `LogTarget=journal` —— 建议删掉（cmdline 会覆盖，但干净些）
2. systemd 起来后还需要：
   - 确认 `getty@ttyGS0` 能给出登录 shell
   - 配置网络（WiFi 或 USB 网卡）
   - 装 GNOME

---

## 九、✅ 端到端模拟验证（2026-10-19 01:51，QEMU virt）

**方法**：QEMU `-M virt -cpu cortex-a72` + 我们自己的 linux-6.6 Image
+ 用 `bringup/pmsg-init.c` 编译的 patched init
+ 与真 rc 逻辑一致的 stub rc
+ 真实 Debian 12 rootfs（disk.raw 副本）

**串口证据**（`<HOME>/vmtest/serial2.log`，267KB）：

```
[0.650] Run /init as init process
[0.684] G9209 REPORT BEGIN version=1 ... machine=aarch64
        G9209 stub-rc: waited 0s, vda1: FOUND
        G9209 stub-rc: mounted OK, /sbin/init -> /lib/systemd/systemd
        CHROOT-OK
        G9209 stub-rc: requesting PID1 handover (exit 88)
[1.125] G9209 PID1 HANDOVER root=/mnt init=/sbin/init
[1.366] systemd[1]: systemd 252.39-1~deb12u2 running in system mode
[6.49]  systemd[1]: systemd-timesyncd.service ... READY=1
[7.39]  systemd[1]: systemd-resolved.service ... READY=1
[7.45]  systemd[1]: Reached target sysinit.target
[7.54]  systemd[1]: Reached target basic.target
        g9209 login:
[92.9]  Reached target multi-user.target / graphical.target
[93.1]  Startup finished in 1.222s (kernel) + 1min 31.862s (userspace)
```

**⇒ 三个未知量全部验证通过：**
1. `pmsg-init` PID1 handover 代码 ✓
2. busybox `switch_root`（PID 校验通过后正常切根）✓
3. Debian rootfs + systemd 252 作为 PID1 完整启动 ✓

**复跑命令**：
```bash
cd <HOME>/vmtest
qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 4 -m 3072 -nographic -no-reboot \
  -kernel <HOME>/linux7420/linux-6.6/arch/arm64/boot/Image \
  -initrd test-initramfs.gz \
  -append "console=ttyAMA0 loglevel=8 panic=10" \
  -drive id=dsk,file=disk.raw,format=raw,if=none -device virtio-blk-device,drive=dsk
```
**注意**：复跑前**不要**在宿主机 loop mount 同一个 disk.raw（会双写损坏 journal）。

---

## 十、手机侧优化配置（VM 观察到的问题）

### 10.1 multi-user 延迟 ~90 秒

VM 里 `ssh.service` 连败 6 次（cloud 镜像没 host key），把 multi-user 拖到 92s。
**但 `sysinit`/`basic` 在 7s 就到了，journald/udevd 早已在跑** —— 看到 systemd 日志就是成功。

**优化**：mask 掉无关服务
```sh
for s in ssh.service cloud-init.service cloud-init-local.service \
         cloud-config.service cloud-final.service \
         systemd-networkd-wait-online.service unattended-upgrades.service \
         e2scrub_reap.service; do
    ln -sf /dev/null /mnt/deb/etc/systemd/system/$s
done
rm -rf /mnt/deb/etc/systemd/system/cloud-init.target.wants
rm -rf /mnt/deb/etc/systemd/system/network-online.target.wants
```

### 10.2 root 密码是锁的

cloud 镜像的 `/etc/shadow` 里 `root:*`，**登录不了**。

**修复**：设一个真实 SHA-512 哈希，或用 autologin
```
root:$6$g9209salt$th9.fJ5hN6GDMh.Bwkv36bNkk3dKM7Kzaegkpppoyygh1rPq18zI9QUiQDCJIexHVhfOGkQQBWcbj5Hj/.25//
```
（密码是 `root`）

### 10.3 ttyGS0 自动登录

systemd-getty-generator 会自动生成 `serial-getty@ttyGS0`，但需要 autologin drop-in：
`/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf`
```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a root -L 115200 ttyGS0 vt100
```

### 10.4 一键配置脚本

`/tmp/fix_debian_config.sh`（在 TWRP 里 `sh /tmp/fix_debian_config.sh` 运行）
+ `/tmp/root_hash.txt`

---

## 十一、烧录前检查清单

1. ✅ 镜像 `p196` 已构建（`60f7f9489058e9d5335020ce4a55f2dc75b778dc`）
2. ⚠️ **必须在 loader 里 `setcmd`（不带参数）清空残留命令**
   - 否则 rc 走诊断模式，不切 Debian
3. ⚠️ 建议 TWRP 里先跑 `/tmp/fix_debian_config.sh`（root 密码 + autologin + mask 服务）
4. ✅ 用 `/tmp/test_debian_boot.py` 一键测试（自动清 setcmd + 武装看门狗 + 抓日志）

**预期 USB 序列**：
```
G9209 boot: cmd_len=0 switch=1
G9209 switch: start, part=/dev/sda20 target=/sbin/init
G9209 switch: mounted OK
G9209 precheck: chroot + /sbin/init OK
G9209 switch: HANDOVER to PID1 (exit 88), target=/sbin/init
G9209 PID1 HANDOVER root=/mnt init=/sbin/init pid=1
systemd[1]: systemd 252.39-1~deb12u2 running in system mode ...
Reached target sysinit.target
Reached target basic.target
g9209 login:
```

---

## 十二、2026-10-19 02:00~02:44 硬件实测记录（p196~p203）

### ★ 已确认工作（重大里程碑）

```
[6.726214] EXT4-fs (sda20): mounted filesystem cf2241b6-... r/w
[6.737568] G9209 switch: waited 0s, /dev/sda20: FOUND
[6.753064] G9209 PID1 HANDOVER root=/mnt init=/sbin/init          ← ★ PID1 handover 成功
[7.033831] systemd[1]: System time before build time, advancing clock.
[7.475395] systemd[1]: Detected architecture arm64.
[7.493349] systemd[1]: systemd 252.39-1~deb12u2 running in system mode (...)  ← ★ systemd 以 PID1 运行
```

**⇒ PID1 handover、switch_root、Debian rootfs、systemd 启动全部验证通过** ✓

### 新发现的阻塞：定时器异常

**症状 1：sched_clock 时间戳乱跳且非单调**
```
[    0.003341] rcu: Max phase no-delay instances is 1000.
[ 4954.820514] EXT4-fs (sda20): mounted ...        ← 启动 6 秒，时间戳 4954 秒
[ 2030.025320] systemd[1]: ...
[ 2024.393637] rcu: INFO: rcu_preempt self-detected stall on CPU   ← 变小
```

**症状 2：`clock_settime` 挂死**
- systemd 在 `System time before build time, advancing clock.` 之后永久无输出
- 从 rc 执行 `date -s "2026-10-19 03:00:00"`：date 本身成功，但**之后的 `sleep 2` / `sync` 永久挂住**

**症状 3：RCU stall（8 CPU 全停）**
```
[7.801922] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
[7.803279] rcu:   0-...!: (1 GPs behind) idle=5334/1/0x4000000000000000 softirq=120/128 fqs=0
...
[9.475890] Call trace:
[9.479751] __switch_to+0xc0/0x124
[9.492228] schedule+0x25c/0x30c
```
加 `rcu_cpu_stall_suppress=1` 可抑制刷屏，但系统仍挂。

### 实验记录

| 镜像 | 改动 | 结果 |
|---|---|---|
| p196 | 基线 | handover ✓，systemd 启动到 "advancing clock" 后挂 |
| p197 | `+ idle=poll + cpuidle.off=1` | 更早挂 |
| p199 | `+ clocksource=arch_sys_counter + rcu_cpu_stall_suppress=1` | 抑制 RCU spam，仍挂在 "advancing clock" |
| p200 | rc 里 `date -s` + sync + sleep 2 | **sleep 2 挂死**（date 成功）|
| p201 | `date -s` 移到 exit 88 前（无 sleep）| **handover ✓，但 systemd 无任何输出** |
| p202 | 移除 date -s | 未测 |
| p203 | **MCT 驱动 `mct_init_dt` 提前 `return -ENODEV`** + 无 date -s | **未测（手机没电）** |

### 根因假设（交给 timer-fixer 子代理深入）

**「时间戳乱跳 + 变小 + 8 核必须 nohz=off + clock_settime 挂」** 四条合在一起，
最像 **per-CPU clocksource 基址不同步**：
- arm64 上通常是 **CNTVOFF_EL2** 被 EL3/EL2 设置了不同的值
- 或 **arch timer 的 per-CPU 初始化顺序**问题
- 或 **MCT（32-bit FRC，会回绕）与 arch timer 混用**

### 当前 bootargs

```
console=tty0 console=ttyGS0 loglevel=8 nohz=off panic=10
clocksource=arch_sys_counter rcu_cpu_stall_suppress=1 rcupdate.rcu_cpu_stall_suppress=1
systemd.log_level=debug systemd.log_target=kmsg systemd.log_color=0 systemd.show_status=1
clk_ignore_unused pd_ignore_unused deferred_probe_timeout=0 rodata=off keep_bootcon
mitigations=off nokaslr kpti=off
```

### 关键洞察

**这四条症状同源**：
1. 8 核必须 `nohz=off`（tickless 会让 CPU 进 idle 后再也醒不过来）
2. RCU 认为所有 CPU 都 stall
3. `clock_settime` 挂死（需要 IPI 通知所有 CPU 更新 clock base）
4. 时间戳乱跳

⇒ **定时器修好后，systemd + GNOME 应该都能跑** ✓
