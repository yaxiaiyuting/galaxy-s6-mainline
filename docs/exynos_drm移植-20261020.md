# exynos_drm（DECON）移植阶段报告（2026-10-20）

> 设备：Samsung SM-G9209（zeroflte / Exynos7420）
> 内核：`/home/duanjb666/linux7420/linux-6.6`（6.6.0-dirty）
> 目标：从 simpledrm（固定帧缓冲、CPU 拷贝）切到 exynos_drm DECON（DMA-BUF 零拷贝扫描输出）
> 负责人：display-fixer
> 状态：**代码/工具/诊断镜像已就绪，等待手机硬件回来做 T0-T6 测试矩阵**（手机被用户取走，不在 USB 上）

---

## 0. TL;DR

| 项 | 状态 |
|---|---|
| 地址探测（Lead 已做） | ✅ CMU_DISP 0x13AD0000 / DECON 0x13930000 / SYSMMU 0x13A00000/0x13A10000 都可读 |
| zenlte 参考补丁 | ✅ 已逐文件与当前树对比：**zenlte 的显示相关改动没有缺失**，当前树是其超集 |
| 已知失败（p221） | ❌ `modprobe exynosdrm` 成功（RET=0，IOMMU attach OK）后 **黑屏 + 串口无响应**，需物理复位 |
| 本次新增 | ✅ 诊断版模块（7 个 module 参数 + `DSH-DISP` 阶段标记）、aarch64 DRM 测试工具、p222 镜像、手机控制脚本、本测试矩阵 |
| 关键判断 | p221 的 wedge 大概率不是"DECON 寄存器写错"导致，而是以下之一：**(a) fbcon/console 在运行中移除 simpledrm 的交互死锁/挂死；(b) SYSMMU enable 时机/页表；(c) decon_clear_channels 关掉 S-Boot 正在用的 window**。p222 的 T0-T6 用"参数隔离 + 阶段标记"逐个排除 |
| 待办 | 手机回来后：刷 p222 → 装新 `exynosdrm.ko` → 按 §3 矩阵逐组测试 → 用 loader `prevlog` 取证 |

---

## 1. 已完成（无需硬件）

### 1.1 诊断版 exynosdrm 模块（`drivers/gpu/drm/exynos/`）

7 个 module 参数（`modprobe exynosdrm <param>=<0|1>`，默认值 = zenlte 行为）：

| 参数 | 默认 | 作用 | 用途 |
|---|---|---|---|
| `aperture` | 1 | `drm_aperture_remove_framebuffers()`：移除 simpledrm | 0 = 保留 simpledrm（不抢显示） |
| `fbdev` | 1 | `exynos_drm_fbdev_setup()`：注册 fbdev（会触发初次 modeset + fbcon 接管）| 0 = 不做初始 modeset，用用户态工具手动触发 |
| `sysmmu` | 1 | `atomic_enable` 里 identity-map + `exynos_iommu_master_ready()`（enable DISP SYSMMU）| 0 = 不使能 SYSMMU |
| `clear` | 1 | bind 时 `decon_clear_channels()`（会关掉 S-Boot 正在扫描的 WINCONx_ENWIN）| 0 = 保留 S-Boot window |
| `timing` | 1 | `decon_commit()` 写 VIDTCON0..4/尺寸寄存器 | 0 = 不碰时序 |
| `clockdiv` | 1 | `decon_commit()` 写 VCLKCON1/2 分频（**由 fixed-clock 假速率算得，值为 0xff，很可能是错的**）| 0 = 完全不碰 pixel-clock 分频 |
| `commit` | 1 | 整个 `decon_commit()`（=0 时 timing/clockdiv 都不写）| 0 = 最保守 |

阶段标记（`pr_err`，loglevel=4 下会进串口 + ramoops，wedge 后用 loader `prevlog` 可看到最后一句话）：
`bind: enter / aperture / component_bind_all / drm_dev_register / fbdev`、
`decon: probe / bind / ctx_initialize / clear_channels(WINCONx) / atomic_enable(pm_resume clocks) /
VIDW_BUF_START0/1 / identity fb / sysmmu enabled / decon_init / commit(mode, clkdiv, 写后回读) /
update_plane(dma_addr) / flush(TRIGCON in/out) / irq#n`、
`dma: dma_dev / mapping / attach`。
**wedge 后 loader `prevlog` 里最后一条 `DSH-DISP` 就是崩溃点。**

### 1.2 aarch64 用户态测试工具 `bringup/drm_dumb_test`

静态编译（884KB），不依赖 libdrm：
- `--list`：列出 `/dev/dri/card*` 的驱动名（确认 card 上跑的是 `exynos`）
- `drm_dumb_test [card] [sleep_s]`：找 exynos 卡 → 读 connector/mode → create dumb buffer + 画彩色渐变 → ADDFB → **SETCRTC**（触发 atomic modeset：`decon_atomic_enable → SYSMMU/identity/commit → update_plane → flush/TRIGCON`）→ sleep 保持 DRM master。
- **不需要 fbdev/console 参与**，可单独验证 DECON 接管路径；屏幕应显示渐变图（若 DECON 扫描成功）。
- 源码：`bringup/drm_dumb_test.c`（只 include 内核 uapi drm.h/drm_mode.h，`__user` 宏已处理）。

### 1.3 手机控制脚本（`bringup/`）

- `df_phone_exec.py "cmd" [timeout]`：串口（ttyGS0，阻塞写）发命令 + USB 网络回传输出，免 sudo。
- `df_send_file.py <local> <phone_path>`：经 USB 网络把文件推到手机（`cat </dev/tcp/192.168.42.1/PORT`）。
- `df_flash.py <out/pNNN-padded.img> [--boot]`：**只刷 BOOT 分区**的安全刷机脚本
  （校验 Samsung SHA-1 @576、刷后读回比对、自动在 system→loader→TWRP 间等待；绝不碰 BOOTLOADER/PIT/EFS/PARAM）。
- loader 侧沿用 `/home/duanjb666/linux7420/g9209-console.py`（`status` / `prevlog` / `--boot` / `--recover`）。

### 1.4 测试镜像：p226（推荐，p222 的超集）

- **p226**（2026-10-20 00:58 构建）：`out/p226-padded.img`
  - sha256 `1ddfd930d3a2d72bf2ac08538a400bc1f9313883e658e0e515cf492788ac33cb`
  - Samsung SHA1 `bb91441df2a6c32fb7aa84a985c93738f5e196cd`
  - kernel sha256 `21c9545c...`；DTB sha256 `83102ad1...`（与 p224/p225 相同）；ramdisk sha256 `1893909f...`（= Lead 的 rc 修复版）
  - 内容 = **p225（启动卡顿修复）** + 本次 max77843 充电读回/控制诊断（默认只读，见 §1.6）
  - **不加载 exynosdrm 模块时行为与 p225 相同**，可安全用于日常 + 启动卡顿验证
- p222（早 5 分钟构建）是 p226 的子集（仅缺充电诊断代码），保留备用；SHA 见 Lead 记录。

### 1.6 附带的充电诊断（max77843-charger，默认只读）

> 背景：用户报告"充不进去电"；原只读驱动不打印充电配置寄存器，无法判断是"没使能"还是"电流不够"。

- probe 时（`dev_info` → 只进 dmesg/journal，不刷串口）打印全部关键寄存器：
  `CHG_INT / CHG_INT_MASK / CHG_INT_OK / CHG_DTLS_00..02 / CHG_CNFG_00..09`，
  再打印一条解码摘要：`CHG_EN / BUCK / OTG / BOOST / fast_chg mA / float mV / input_limit mA / INT_OK 位`。
- 运行时：
  ```sh
  dmesg | grep DSH-CHG                 # 看开机时的真实充电配置
  echo 1 > /sys/module/max77843_charger/parameters/dump            # 再打印一次
  echo 2100000 > /sys/module/max77843_charger/parameters/fast_charge_ua
  echo 1800000 > /sys/module/max77843_charger/parameters/input_limit_ua
  echo 4350000 > /sys/module/max77843_charger/parameters/float_voltage_uv
  echo 1 > /sys/module/max77843_charger/parameters/write_enable    # 写 CNFG_00/02/04/09
  dmesg | grep DSH-CHG | tail -5      # 验证写入后的配置
  ```
- **默认 `write_enable=0`（只读）**；只有显式写 1 才会碰充电寄存器。写入内容 = vendor 推荐：
  `CNFG_00 |= CHG|BUCK`、`CNFG_02=2100mA(0x2A)`、`CNFG_04=4350mV(0x1C)`、`CNFG_09=1800mA(0x36)`；
  读改写，保留各寄存器其它位。

### 1.4（历史）p222 镜像

- 构建：`./build_mainline.sh p222`（ramdisk 已确认含 Lead 修的 `bringup/rc`：ramdisk 内 `etc/rc` sha256 = 当前 `bringup/rc` sha256）
- 内容 = 当前树（DTS：`DSH_ENABLE_DISP_IOMMU 1` + `&decon okay` + `i80-if-timings` + display-timings；`CONFIG_DRM_EXYNOS=m`，模块不自动加载）
- **启动后默认行为 = p219（simpledrm/GNOME 可用）**，只有手动 `modprobe exynosdrm` 才会走 DECON 路径。
- 新 `exynosdrm.ko`（含诊断）构建于 `linux-6.6/drivers/gpu/drm/exynos/exynosdrm.ko`
  - sha256 `0fb688a352b84a90039d81858d746c80cd5290ae0e6cb776ffc9a2ec0acd9048`，687200 B
  - vermagic `6.6.0-dirty SMP preempt mod_unload aarch64`（与 p222/p226 Image 匹配）
  - 已核对二进制内含全部 `DSH-DISP` 标记与 `/chosen` framebuffer 解析（`dsh_decon_find_boot_fb`）

### 1.5 zenlte 补丁 vs 当前树对比结论

把 zenlte patch 的 11 个显示相关文件 apply 到 vanilla 6.6 后与当前树逐文件 diff：

| 文件 | 结论 |
|---|---|
| `exynos-iommu.c` | 当前树是超集：把 zenlte 的 `IS_ENABLED(CONFIG_ARM64) && of_device_is_compatible()` 黑魔法换成了 `of_device_get_match_data()`（`samsung,exynos7420-sysmmu`）；多了 aclk/pclk 空指针保护和调试打印。**功能无缺失** |
| `exynos7.dtsi` | 当前树超集：sysmmu 加了 7420 专用 compatible；`pd_g3d` 地址修正为 0x105C4100 + `exynos7420-g3d-pd`（ALWAYS_ON）；**decon/i80/display-timings/sysmmu 节点与 zenlte 一致** |
| `exynos7_drm_decon.c` | 当前树 = zenlte 补丁 + Lead 补的 TRIGCON 宏 + 本次诊断代码。**zenlte 的 i80/identity-map/triple-buffer/vblank 改动全部在** |
| `exynos_drm_drv.c / dma.c / drv.h` | 当前树 = zenlte + 参数开关（本次）+ 调试；EPROBE_DEFER 逻辑在 |
| `clk-exynos7.c / exynos7-clk.h` | 当前树 = zenlte（除 peric1 一个无关 MUX） |
| `pmdomain/exynos-pm-domains.c` | 当前树是超集（DISP 序列 + G3D ALWAYS_ON） |
| `iommu/Kconfig` | 一致 |

**⇒ 结论：代码移植层面没有"少搬了什么"；p221 的 wedge 是运行时/环境/状态问题，必须靠 p222 的分阶段测试定位，而不是继续对着 zenlte 补丁找漏。**

---

## 2. p221 wedge 的候选原因（按可能性排序）

### H1（最高，已有内核源码直接证据）：fbcon 接管时的 console_lock 下 modeset

`drivers/gpu/drm/drm_fb_helper.c` 里 `drm_fb_helper_initial_config()` 的内核源码注释原文：

> HANG DEBUGGING: When you have fbcon support built-in or already loaded, this function
> will do a full modeset to setup the fbdev console. Due to locking misdesign in the
> VT/fbdev subsystem that entire modeset sequence has to be done while holding console_lock.
> **Until console_unlock is called no dmesg lines will be sent out to consoles, not even
> serial console.** This means when your driver crashes, you will see absolutely nothing
> else but a system stuck in this function, with no further output. Any kind of printk()
> you place within your own driver or in the drm core modeset code will also never show up.

调用链（6.6 已核对）：
`exynos_drm_fbdev_setup() → drm_fb_helper_initial_config() → register_framebuffer()
→ fbcon_fb_registered() → console_lock() → do_fb_registered → fbcon takeover
→ fb_set_par → drm_fb_helper_set_par() → 全量 atomic modeset（decon_atomic_enable + commit）`
⇒ 如果这一轮 modeset 卡死/AXI 挂死，**串口也完全无输出**，与 p221 的"黑屏+串口无响应"完全吻合。
⇒ 这也解释了为什么 `modprobe` 打印 RET=0 后系统才静默（fbcon 接管可能由后续 console 路径触发）。

**无需重新构建的调试开关（fbcon is built-in）**：
```sh
echo 1 > /sys/module/fbcon/parameters/lockless_register_fb   # 注册 fb 时不拿 console_lock
# 或解绑 fbcon：
echo 0 > /sys/class/vtconsole/vtcon1/bind
```
在 fbdev=1 的测试（T3-T7）前先打开 lockless，就能在挂死时从串口看到最后一条 `DSH-DISP`。

zenlte 是**开机早期** modprobe（initramfs/rc 阶段，fbcon 还没在 simpledrm 上建立用户会话）；
我们是在 **GNOME 已运行 385 秒后** modprobe：
1. `drm_aperture_remove_framebuffers()` 在 `exynos_drm_bind()` 最开头**同步移除** simpledrm 平台设备
   → simpledrm `drm_dev_unplug` → fbdev/fbcon 注销（console_lock）；
2. 随后 `component_bind_all()` 里 `decon_clear_channels()` 关掉 S-Boot 的 WINCON；
3. `exynos_drm_fbdev_setup()` 在 bind 内注册新 fbdev → **fbcon 可能在 console_lock 上下文里对新 fb 调 `fb_set_par`
   → drm_fb_helper 走 atomic modeset**（DECON enable + SYSMMU）——在 console 上下文里做带 vblank 等待的 commit，
   一旦和 fbcon/console_lock/printk 互锁，表现就是"**黑屏 + 串口无响应**"（printk 也进不去）。
   - 判别：`aperture=0 fbdev=0`（T0）时不应 wedge；只加 `aperture=1`（T2）若 wedge 而 `fbdev=0` 不 wedge ⇒ H1 中 fbcon 部分成立。
### H2：SYSMMU enable 时机/页表
identity map 用 `VIDW_BUF_START` 回读值（可能为 0/旧值）或 `/chosen` framebuffer（本次已加：从 `/chosen` DT 解析
`simple-framebuffer` 的 phys/size 并优先映射）。若映射范围没盖住 DECON 正在访问的 buffer，enable 瞬间 fault→wedge。
   - 判别：T4（sysmmu=1，其它最保守）若 wedge 而 T3（sysmmu=0）不 wedge ⇒ H2 成立。
### H3：`decon_clear_channels()` 破坏 S-Boot 显示状态机
i80 命令模式下 WINCON 关闭可能不会立即生效（没有 vsync），后续 trigger 序列可能让 DECON/DSI 进坏状态。
   - 判别：T1（clear=1）vs T0（clear=0）；i80 模式没有 vsync，`decon_wait_for_vblank` 在 bound 阶段其实会早退（suspended=true），风险主要在 HW。
### H4：`decon_commit()` 的时序/分频写坏
- `decon_calc_clkdiv()` 单位不匹配：`mode->clock`(kHz) vs `clk_get_rate(vclk)`(Hz, 但本板是 fixed-clock 假值 148.5MHz)
  → 算出 668 → clamp 0xff，VCLKCON1/2 被写成 0xFE；
- 但 zenlte 同样代码也可能有相同结果，且 i80 模式 VCLK 主要用于 RGB 接口——**优先级低于 H1/H2/H3**。
   - 判别：T5（timing=1 clockdiv=0）vs T6（clockdiv=1）。
### H5：irq/vblank 路径
i80 模式 IRQ 用 `lcd_sys`（不是 vsync）。若 S-Boot 没把 frame-done 中断挂到 GIC/或 handler 读 VIDINTCON1 时
DECON 已停时钟 → 不响应。目前 irq 有前 8 次打印，可看是否收到。
### H6：`exynos_iommu_map_identity()` 本身（映射范围/页表/锁定）
`iommu_map(owner->domain, 0xe2a00000, 0xe2a00000, 64M, ...)`：若在 DMA domain 的 iova_domain 之外/冲突，
返回错误被忽略，随后 enable 后 DECON 访问未映射地址 → fault → wedge。本次加了 `ret` 打印，可直接看到。

---

## 3. p222 测试矩阵（手机回来后按顺序做）

> 每次测试前先确认手机在 loader（`lsusb | grep 1209:316d`），`g9209-console.py --boot` 启动，
> 等 Debian 起来（`lsusb` 变 `1209:9210`、USB 网络 carrier=1）。**每轮结束记录 DSH-DISP 最后一条。**

**一键安全批次（推荐第一步）**：`python3 bringup/df_exynos_stage1.py`
会把 gdm/WiFi 停掉、charging 设 safe，然后在一轮串口里依次跑 **T0 → T1 → T2**（全都不进 modeset/不使能 SYSMMU），
并把每步的 `DSH-DISP` 日志带回来。T2 会移除 simpledrm，跑完需要重启恢复显示；重启后拍照/记录再进下一步。

公共准备（每轮 boot 后）：
```sh
# 0. 确认现状（应看到 p222 内核、simpledrm 的 card0、GNOME 在跑）
uname -a; cat /proc/cmdline; ls /dev/dri/; cat /sys/class/drm/card0/device/uevent | head -3
pgrep -a gnome-shell | head -2; cat /sys/class/graphics/fb0/name

# 1. 装入诊断模块（先不加载）
#    host: python3 bringup/df_send_file.py <本地>/lib/modules/.../exynosdrm.ko /tmp/exynosdrm.ko
#    或先 depmod 安装到 /lib/modules/6.6.0-dirty/extra/（rootfs 持久）
```

### T0 — 最小侵入：只 probe/bind，不碰显示
```sh
systemctl stop gdm                      # 可选：先停 GNOME，减少变量（屏幕会停在最后画面）
insmod /tmp/exynosdrm.ko aperture=0 fbdev=0 clear=0 sysmmu=0
sleep 3; dmesg | grep DSH-DISP | tail -40; ls /dev/dri/; lsmod | grep exynosdrm
rmmod exynosdrm; echo "RMMOD=$?"
```
- 期望：`bind: done`、`decon: bind done`、新 card 出现、**无 wedge**、rmmod 成功。
- 若 wedge：最后一条 DSH-DISP 指向 probe/bind 具体位置（时钟/寄存器/IRQ/DPI），基本可排除 SYSMMU/fbcon。

### T1 — 只测 clear_channels
```sh
insmod /tmp/exynosdrm.ko aperture=0 fbdev=0 clear=1 sysmmu=0
sleep 3; dmesg | grep DSH-DISP | tail -40
```
- 期望：`WINCONx` 打印（S-Boot 的 ENWIN 状态）+ `clear_channels done`，无 wedge。
- 屏幕可能静止/黑（DECON window 被关，但 fbcon 仍认为 simpledrm 在显示）。
- wedge ⇒ H3。

### T2 — 只测移除 simpledrm（不 modeset）
```sh
insmod /tmp/exynosdrm.ko aperture=1 fbdev=0 clear=0 sysmmu=0
sleep 3; dmesg | grep DSH-DISP | tail -40; ls /dev/dri/
```
- 期望：`simpledrm removed` + `bind done`，无 wedge（GNOME 可能崩但要看到串口/网络还活着）。
- wedge ⇒ H1 的 removal/fbcon 部分（此时还没 modeset/SYSMMU）。
- 若 wedge：先只看能否用 `g9209-console.py` / 网络 ping 判活。

### T3 — fbdev 初始 modeset（无 SYSMMU、无 commit 写时序）
```sh
# 关键：先让 fbcon 注册不拿 console_lock，否则挂死时串口也看不到东西
echo 1 > /sys/module/fbcon/parameters/lockless_register_fb
insmod /tmp/exynosdrm.ko aperture=0 fbdev=1 clear=0 sysmmu=0 timing=0 clockdiv=0 commit=1
sleep 5; dmesg | grep DSH-DISP | tail -60; pgrep -a gnome-shell
# 结束后恢复
# echo 0 > /sys/module/fbcon/parameters/lockless_register_fb
```
- 期望：`atomic_enable` 走完（sysmmu SKIPPED、commit 里 timing 跳过）、无 wedge。
- 若 wedge ⇒ DECON 寄存器写/IRQ/TRIGCON 路径本身有问题（H5/H3）。

### T4 — 加 SYSMMU（其它仍最保守）
```sh
insmod /tmp/exynosdrm.ko aperture=0 fbdev=1 clear=0 sysmmu=1 timing=0 clockdiv=0 commit=1
sleep 5; dmesg | grep DSH-DISP | tail -80
```
- 期望：`VIDW_BUF_START0/1`、`boot_fb base/size`、`identity ... ret=0`、`sysmmu enabled`、无 wedge。
- **wedge ⇒ H2 确认**，下一步改成"从 /chosen DT 取 fb 地址 + 只 map 16MB"后再试（本次代码已优先用 DT 地址，如果仍 wedge 则 map 本身/时机有问题，可改 T4b：`clear=1` 让 DECON 无活动 window 时 enable SYSMMU，先 enable 后写 window）。
- T4b（若 T4 wedge）：`aperture=0 fbdev=1 clear=1 sysmmu=1 timing=0 clockdiv=0 commit=1`。

### T5 — 打开时序写（不写 pixel clock 分频）
```sh
insmod /tmp/exynosdrm.ko aperture=0 fbdev=1 clear=0 sysmmu=1 timing=1 clockdiv=0 commit=1
sleep 5; dmesg | grep DSH-DISP | tail -80
```
- 期望：`commit ... VIDCON0/VIDTCON4 回读` 打印；屏幕出现 exynos 的新 fb（渐变/console 内容）。
- 若无画面但无 wedge：看 `update_plane`/`flush`/`irq` 打印，判断 TRIGCON 是否正确。

### T6 — 打开 clockdiv（验证 H4）
```sh
insmod /tmp/exynosdrm.ko aperture=0 fbdev=1 clear=0 sysmmu=1 timing=1 clockdiv=1 commit=1
```
- 若出现花屏/黑屏/wedge ⇒ H4 成立，生产中永久 `clockdiv=0`（S-Boot 配好的分频最适合 i80/DSI）。

### T7 — 完整接管（去掉 simpledrm，最终目标形态）
```sh
insmod /tmp/exynosdrm.ko aperture=1 fbdev=1 clear=0 sysmmu=1 timing=1 clockdiv=0 commit=1
```
- 成功标准：屏幕显示 exynos fb（GDM 或面），`/sys/kernel/debug/dri/0/name` = `exynos`，无 wedge。
- 之后再把参数默认值改成这套（或开机 systemd-modules-load 自动加载）。

### 手动触发工具（不经过 fbdev/console 的对照组）
```sh
insmod /tmp/exynosdrm.ko aperture=0 fbdev=0 clear=0 sysmmu=<0|1> commit=0
/tmp/drm_dumb_test --list                 # 期望：card0 simple-framebuffer, card1 exynos
/tmp/drm_dumb_test /dev/dri/card1 30      # SETCRTC → 触发 atomic_enable
```
- 若这个路径不 wedge 而 T3/T4（fbdev）wedge ⇒ 明确是 fbcon/console 交互（H1 的 fbcon 部分），
  最终方案可改为"开机早期加载 exynosdrm（modules-load.d，在 gdm 之前）"，或把 `exynos_drm_fbdev_setup()` 的
  initial config 延后。

---

## 4. 取证与恢复流程

1. **wedge 判定**：串口无响应 ≥ 5s + `lsusb` 无/仍 9210 但 ping 不通 + 屏幕黑。
2. **复位**：长按电源 10s（本板内核 wedge 时看门狗不生效，物理复位是唯一手段）。
3. **复位后**：S-Boot → uniLoader（`lsusb` = `1209:316d`）→ 先用
   `sudo ./g9209-console.py prevlog --timeout 30` 抓 ramoops 最后 ±16KB，找最后的 `DSH-DISP` 行。
   > 注意：bootargs 是 loglevel=4，`pr_err`(=KERN_ERR) 会记录；若需要更多信息可临时把 `uniLoader/main/diag.c` 改 loglevel=8 重新构建。
4. **回收**：`sudo ./g9209-console.py --boot` 重新启动 p222；或 `--recover "reboot recovery"` 进 TWRP 刷回 p219/p225。
5. 每轮记录：镜像号 + 参数 + 最后 DSH-DISP 行 + 屏幕现象。

**刷机（只刷 BOOT）**：
```bash
# Debian 里：serial -> reboot recovery（或 g9209-console.py --recover "reboot recovery"）
adb devices | grep recovery
adb push out/p222-padded.img /tmp/
adb shell 'dd if=/tmp/p222-padded.img of=/dev/block/by-name/BOOT bs=1048576; sync'
adb reboot      # → loader → g9209-console.py --boot
```

**安全红线**：不碰 `0x14C00000-0x14CE0000`、`0x10570000`、`0x105D0000`、`0x13650000`；
只写 BOOT 分区；未实测地址先用 loader `mrd` + `watchdog arm`。

---

## 5. 风险与回滚

- 每次 wedge 需要物理复位（可能打断用户使用）→ 测试按 T0→T7 由安全到危险排序，**绝不跳级**。
- 回滚：重新刷 p219（`out/p219-padded.img`，sha1 98af4f3a…）或 Lead 的 p225；rootfs 不受影响。
- 模块全部是 =m，不加载时系统行为与 p219 相同（p222 可安全用于日常，只要不 modprobe）。

---

## 6. 下一步（等硬件）

1. 手机回来后**先刷 p222**（它自带 Lead 的 rc 修复 + decon DTS，不加载模块时 = 可用系统）。
2. 按 §3 跑 T0 → T2（安全组），把 `dmesg | grep DSH-DISP` 全量发我。
3. 根据最后一条标记决定 T3-T7 的取舍。
4. 定位后改默认参数（或代码），再出一版"生产镜像"：`aperture=1 fbdev=1 sysmmu=1 timing=1 clockdiv=0 commit=1` 作为模块默认值，
   并在 rootfs 加 `/etc/modules-load.d/exynosdrm.conf`（若确认 fbcon 路径安全）或保留手动加载。
5. 最终目标：GNOME 跑在 exynos card 上，panfrost DMA-BUF 直扫（零拷贝），主观流畅度提升。
