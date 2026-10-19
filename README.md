# Samsung Galaxy S6 (SM-G9209 / zeroflte) — Mainline Linux 6.6 Port

把 **Samsung Galaxy S6（Exynos7420）** 从 Android 移植到 **mainline Linux 6.6 + Debian 12 + GNOME**。

**当前状态：能开机、能进 GNOME 桌面、能显示电池电量、WiFi 可连 5GHz。**

---

## ✨ 已实现的功能

| 功能 | 状态 | 说明 |
|---|---|---|
| **启动链** | ✅ | S-Boot → uniLoader（裸机）→ mainline Image |
| **8 核 SMP** | ✅ | 4×Cortex-A57 + 4×Cortex-A53，需 `nohz=off` |
| **定时器** | ✅ | CNTVOFF_EL2 workaround（用 CNTPCT） |
| **UFS** | ✅ | 32GB，20 个分区，`/dev/sda20` 挂 Debian |
| **USB 控制台** | ✅ | ACM gadget，`/dev/ttyACM0` |
| **USB 网络** | ✅ | ECM gadget，手机 `usb0` ↔ 宿主机 |
| **Debian 12** | ✅ | systemd `running`，root 自动登录 |
| **GNOME 43** | ✅ | gnome-shell + mutter + simpledrm KMS |
| **GPU（Mali-T760）** | ✅ | panfrost 驱动，700MHz |
| **触摸屏** | ✅ | STMFTS（`/dev/input/event0`） |
| **WiFi（BCM4358）** | ✅ | 5GHz，802.11ac，可连 AP |
| **电池/电量计** | ✅ | MAX77843 fuel gauge（SOC/电压/电流/温度）|
| **充电控制** | ✅ | MAX77843 charger：可开/关充电、调电流/电压（默认只读）|
| **GNOME 交互** | ⚠️ | 能用，但 2K 屏 + 软件合成偏卡 |

---

## 🔧 核心技术要点（踩过的坑）

### 1. CNTVOFF_EL2 未初始化 —— 定时器全崩

**症状**：printk 时间戳乱跳（启动 6 秒显示 4954 秒）、`nohz` 模式挂死、`clock_settime` 卡死、RCU 8 核全 stall。

**根因**：本板内核在 **EL1** 启动，arm64 启动协议要求固件初始化 `CNTVOFF_EL2`（每核虚拟计数器偏移），但 S-Boot 没做。
主线 6.6 在 EL1 下强制用 CNTVCT（虚拟计数器）→ 每核读到不同时间。

**修复**：`drivers/clocksource/arm_arch_timer.c` 的 `ool_workarounds[]` 加一条：
```c
{
    .match_type = ate_match_dt,
    .id = "arm,cpu-registers-not-fw-configured",
    .read_cntvct_el0 = arch_counter_get_cntpct,   /* 改用物理计数器 */
},
```
配合 DT 属性 `arm,cpu-registers-not-fw-configured;`（uniLoader 也会注入）。

### 2. PID 1 handover —— systemd 无法启动

**症状**：busybox `switch_root` 报 usage 退出；systemd 拒绝以非 PID1 运行。

**根因**：initramfs 的 `/init` 是 PID 1，它 fork 出 `/bin/sh /etc/rc`（PID 2+），
rc 里调 `switch_root` 会因 `getpid() != 1` 被 busybox 拒绝。

**修复**（`bringup/`）：
1. rc 检测到要切根时，把目标写进 `/tmp/dsh-handover`（第 1 行 root，第 2 行 init），然后 `exit 88`
2. `/init`（pmsg-init）收到 `WIFEXITED(status) && WEXITSTATUS(status) == 88` 后，
   自己 `execv("/bin/switch_root", {"switch_root", hroot, hinit, NULL})` —— 此时它还是 PID 1 ✓

### 3. 显示：不需要移植 exynos_drm

**关键洞察**：S-Boot 已经把 DECON/DSIM/panel 初始化好，并持续扫描 `0xe2a00000` 的 1440×2560 帧缓冲。
Linux **根本不需要碰** DECON/DSIM/CMU_DISP 寄存器 —— 绕开了本板所有"未上电 IP 访问即 AXI 挂死"的雷区。

**做法**：用 mainline 的 `simpledrm`（DT 节点 `simple-framebuffer`），它提供完整 atomic KMS，
mutter 可以直接用它（软件渲染 llvmpipe）。

**性能优化**：`drivers/gpu/drm/tiny/simpledrm-g9209-copy.h` 提供 AArch64 汇编优化的
XRGB8888→ARGB8888 融合转换+拷贝（LDP/STP 128-bit），比通用 `drm_fb_blit` 快数倍。

### 4. WiFi（BCM4358 over PCIe）

- 写了 **701 行的 Exynos7420 PCIe host 驱动**（`drivers/pci/controller/dwc/pci-exynos7420.c`）
- BCM4358 固件内建（`CONFIG_EXTRA_FIRMWARE`），版本 7.112.53.12
- 关键坑：中断上下文里访问未上电 IP 会 panic；PCIe PHY 的部分地址需谨慎

### 5. GPU（panfrost）—— 电源域不能断电

**症状**：gnome-shell 起来后关 panfrost 的 perfcnt fd → runtime resume → 读 `0x14AC0000` → **SError panic**。

**根因**：panfrost 的 autosuspend 只有 50ms；genpd 用通用 `samsung,exynos5433-pd` 断电，
但 resume 时缺 vendor 的 G3D 上电序列（TOPC1 门控 / 7×PMU SYS_PWR / pd-option=0x1101 / save_list）
⇒ GPU 实际没上电 ⇒ 访问寄存器 SError。

**修复**：DTS 里给 `&gpu` **不挂 `power-domains`**：
```dts
&gpu {
    status = "okay";
    /delete-property/ power-domains;   /* genpd 永不断电，靠 pd_ignore_unused 保持上电 */
};
```

### 6. 电池驱动 —— `power_supply` 的 `drv_data` 陷阱（最隐蔽的 bug）

**症状**：系统启动 0.6 秒后 oops，然后用户态各种诡异挂死（最像 USB gadget 崩溃，误导排查很久）。

**根因**：`devm_power_supply_register(dev, desc, NULL)` 第三个参数传 `NULL`
⇒ `psy->drv_data = NULL` ⇒ `power_supply_get_drvdata(psy)` 返回 NULL
⇒ `get_property` 里 `chg->xxx` 立即 NULL 解引用。

**修复**：
```c
struct power_supply_config cfg = {
    .drv_data = chg,     /* ★ 必须传！ */
};
chg->psy = devm_power_supply_register(dev, desc, &cfg);
```

**教训**：`power_supply_register` 家族**必须**传 `cfg`，不能传 NULL。

### 7. 硬件 I2C 门控不可控 → 改用 i2c-gpio

MAX77843 在 `hsi2c_1`（`0x13650000`），但 CMU_PERIC0 的门控被 S-Boot 关着，
一访问就 **AXI 静默挂死**（只能靠 loader 看门狗复位）。

**修复**：改用 `i2c-gpio` 位翻转（`gpd2-2`=SDA、`gpd2-3`=SCL，100kHz），
完全不碰 `0x13650000`。pinctrl_bus0（`0x13470000`）已实测可访问。

### 8. 主线上电后充电根本没开（CHG_EN=0）

**症状**：插着 USB 线，电量只掉不涨。

**根因**：S-Boot 给 Android 启动时 vendor charger 驱动会把 `CHG_CNFG_00` 写成 `0x05`
（CHG_EN=1 | BUCK=1 开启充电）。但 uniLoader 和主线**都不碰 charger**，
所以 Linux 拿到的还是 `0x04`（**CHG_EN=0**，充电关闭）。

实测寄存器（p227 驱动 probe 打印）：
```
CHG_CNFG_00 = 0x04   → CHG_EN=0  ← 充电没开
CHG_CNFG_02 = 0x89   → fast_chg = 450 mA
CHG_CNFG_04 = 0x9c   → float = 4350 mV
CHG_CNFG_06 = 0x0c   → 写保护解锁（bits[3:2]=0b11）
CHG_CNFG_09 = 0x0e   → input_limit = 467 mA
CHG_DTLS_01 = 0x38   → charger off
CHG_INT_OK  = 0x5d   → CHGIN_OK=1（VBUS 有电）
```

**修复**：`max77843-charger.c` 实现可控写：
- 解锁写保护（`CHG_CNFG_06` bits[3:2]=11）+ 每次写 readback 校验
- 写序：输入限流 → 快充电流 → 浮充电压 → **最后** CHG_EN
- `sysfs` 一次性命令：`echo safe|full|disable|dump|unlock|kick > /sys/class/power_supply/max77843-charger/charge_ctrl`
- 默认**只读**（`charge_enable=0`），零风险

**验证结果**（p227）：
```
W CHG_CNFG_09 input-limit = 0x0f (readback OK)
W CHG_CNFG_02 fast-charge = 0x0a (readback OK)
W CHG_CNFG_04 float-voltage = 0x1c (readback OK)
W CHG_CNFG_00 enable = 0x05 (readback OK)     ← ★ CHG_EN=1
after-enable: charge_state=fast-charge CC      ← ★ 进入恒流充电
```

**⚠️ 重要限制**：PC USB 口是 **SDP（500mA 上限）**。
2K 屏 + WiFi + GPU 负载 > 500mA ⇒ 即使充电开启，仍可能净放电。
**必须用墙充（DCP，可达 1800mA）**才能真充进去。

### 9. 启动时串口终端卡住几十秒（rc 日志阻塞）

**症状**：手机启动时串口终端输出卡住几十秒，时好时坏。

**根因**：`rc` 的 `dsh_log()` 每行写两次 —— `$DSH_TTY=/dev/ttyGS0` 和 `/dev/console`，
而 bootargs 是 `console=tty0 console=ttyGS0`（**后一个才是主 console**），
所以 `/dev/console` **就是** ttyGS0 → 同一行写两遍。

ttyGS0 是 USB gadget 串口：宿主机没在读（比如脚本断开重连的间隙）时，
USB 流控让手机侧 `write()` 一直阻塞 → `/etc/rc` 卡在一条日志上 → 启动"卡死"。

**修复**：
1. `DSH_TTY=/dev/console`（单目标）
2. `dsh_log` 改**后台写** `{ echo ...; } &` —— 启动绝不等串口
3. UFS dmesg 转储 40 行 → 15 行 + 后台化
4. chroot precheck 加 `timeout 15`

### 10. 其他

- **8 核必须 `nohz=off`**：tickless idle 会让 CPU 睡死（根因也是 CNTVOFF）
- **bootargs 里的 `systemd.log_level=debug` 会把启动拖慢 10 倍**（USB 串口 115200 是瓶颈）
- **别给宿主机 USB 开 autosuspend**：2 秒挂起会触发设备侧 gadget 异常

---

## 📦 目录结构

```
patches/          内核补丁（完整 + 按子系统拆分）
  ├── 0001-linux-6.6-g9209-full.patch   完整补丁（7571 行 / 55 文件）
  ├── arch-arm64-boot-dts-exynos.patch
  ├── drivers-power-supply.patch
  ├── drivers-pci-controller-dwc.patch
  └── ...
loader/           uniLoader 补丁（裸机 loader + USB 控制台 + 看门狗）
bringup/          initramfs 相关
  ├── rc                           initramfs 主脚本（切根逻辑）
  ├── pmsg-init.c                  PID 1（handover 实现）
  ├── build_pmsg_ramdisk.py        ramdisk 构建
  └── build_mainline.sh            一键构建
firmware/         BCM4358 WiFi 固件
docs/             12 篇技术文档（根因分析 / 踩坑记录 / 实测数据）
tools/            主机侧调试工具
images/           可直接刷的 boot 镜像
```

---

## 🛠️ 构建

**依赖**：`aarch64-linux-gnu-` 工具链、Python 3、`dtc`、`device-tree-compiler`

```bash
# 1. 拉取 Linux 6.6
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz
tar xf linux-6.6.tar.xz && cd linux-6.6

# 2. 应用补丁
patch -p1 < ../patches/0001-linux-6.6-g9209-full.patch

# 3. 准备 uniLoader（克隆后应用 loader 补丁）
#    uniLoader: https://github.com/ivoszbg/uniLoader
patch -p1 < ../loader/0001-uniloader-g9209-full.patch

# 4. 构建（需要 build_mainline.sh 里的路径结构）
./build_mainline.sh mybuild
# 输出: out/mybuild-padded.img
```

---

## 📱 刷机

**⚠️ 只刷 BOOT 分区，绝不要碰 BOOTLOADER / PIT / EFS / PARAM**

```bash
# 1. 手机进 TWRP（recovery）
# 2. 推送并刷入
adb push out/mybuild-padded.img /tmp/
adb shell 'dd if=/tmp/mybuild-padded.img of=/dev/block/by-name/BOOT bs=1048576'
adb shell 'sync'

# 3. 重启到 loader
adb reboot

# 4. loader 里（USB ACM 控制台）：
#    setcmd            # 清空残留命令
#    watchdog arm      # 武装看门狗（挂死会自动复位）
#    boot              # 启动
```

---

## 🐛 已知问题

1. **GNOME 交互偏卡** —— 2K 屏（1440×2560）+ simpledrm 固定帧缓冲，无法零拷贝呈现。
   根治需要移植 `exynos_drm`（DEcon + DSI），让 GPU 渲染结果直接扫描输出。
   **进展（WIP）**：`DSH_ENABLE_DISP_IOMMU=1` 已开启，`exynosdrm.ko` 可作为模块加载，
   IOMMU 成功 attach 到 DECON（`13930000.decon` → `13a00000/13a10000.sysmmu`）。
   待解决：modprobe 后黑屏（疑似 fbcon console_lock 下第一轮 modeset 挂死，
   或 SYSMMU identity-map 时机）。详见 `docs/exynos_drm移植-20261020.md`。
2. **GPU 电源域** —— 目前禁用 `power-domains` 让 GPU 常开；完整方案需要移植 vendor G3D 上电序列。
3. **充电管理** —— charger 驱动是只读的，充电参数仍由 S-Boot 决定。
4. **触摸坐标** —— DT 里 `touchscreen-size-x/y = <4096>`，可能需按实际面板校准。
5. **多摄/指纹/传感器等** —— 未移植。

---

## 📚 文档索引

| 文档 | 内容 |
|---|---|
| `docs/定时器异常分析-20261019.md` | CNTVOFF_EL2 根因完整推导（988 行）|
| `docs/显示bring-up-20261019.md` | simpledrm 分析 + GNOME 上屏（536 行）|
| `docs/WiFi联网-20261019.md` | PCIe + BCM4358 全链路（668 行）|
| `docs/电池驱动移植-20261020.md` | MAX77843 fuel gauge + charger 移植 |
| `docs/电池与启动问题-20261020.md` | NULL drv_data 排查过程 |
| `docs/GPU加速-20261020.md` | panfrost 电源域方案（462 行）|
| `docs/systemd根因与PID1修复-20261019.md` | PID1 handover（449 行）|
| `docs/充电控制-20261020.md` | 充电寄存器全量诊断 + 可控写（新）|
| `docs/exynos_drm移植-20261020.md` | exynos_drm 攻关记录（WIP）|
| `docs/今晚总战报-20261019.md` | 总览 + 快速上手 |

---

## 🙏 致谢

- **uniLoader** — 裸机 loader 框架（https://github.com/ivoszbg/uniLoader）
- **postmarketOS / exynos7420 社区** — 早期 Exynos7420 移植经验
- **Linux mainline** — arm_arch_timer / panfrost / simpledrm / max77843 MFD

---

## ⚖️ 许可

- 内核补丁：**GPL-2.0**（Linux 内核要求）
- 文档：**CC BY-SA 4.0**
- uniLoader 补丁：遵循 uniLoader 原许可

---

**⚠️ 免责声明**：刷机有风险，操作需谨慎。本项目仅供学习和研究使用。
