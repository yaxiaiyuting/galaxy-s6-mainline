# p310: 背光 + GPU DVFS（已验证可用）

## 关键修复点

### 1. decon.c 缺前向声明（原 patch 的 bug）
`dsh_dsim_display()` / `dsh_dsim_set_level()` 定义在文件后半部分（~1087/1120 行），
但 `decon_atomic_enable()`（~820 行）就调用了它们 → 编译报
`implicit declaration of function` + `conflicting types`。

修复：在 `struct decon_context` 定义之后（~180 行）加：
```c
static int dsh_dsim_display(struct decon_context *ctx, bool on);
static int dsh_dsim_set_level(struct decon_context *ctx, unsigned int level);
```

### 2. 模块必须单独编译！
`build_mainline.sh` **只编内核镜像，不编模块**。
`CONFIG_DRM_EXYNOS=m` → 背光代码在 `exynosdrm.ko` 里，
不跑 `make modules` 的话刷了镜像也没有背光。

```sh
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) modules
```

### 3. 模块有三份副本，必须全部更新！
```
/usr/lib/modules/<ver>/drivers/gpu/drm/exynos/exynosdrm.ko   ← modinfo 指向这份
/usr/lib/modules/<ver>/extra/exynosdrm.ko                    ← 还有一份
/usr/lib/modules/<ver>/kernel/drivers/gpu/drm/exynos/exynosdrm.ko
```
只更新 `kernel/` 下那份不会生效。三份都 `cp` + `depmod -a`。

## 验证结果（p310, 内核 #301）

```
模块参数: aperture backlight bl_dump bl_level clear clockdiv commit fbdev sysmmu timing
背光设备: /sys/class/backlight/s6e3hf2  (brightness=160/255)
DSIM STATUS = 0x80100400（活着，不是 0xffffffff）
日志: "panel display OFF" / "panel display ON"（DCS 0x28/0x29）

功耗（中位数，PC USB 500mA 输入下）:
  brightness=160:  -608 mA
  brightness=255:  -597 mA
  brightness=1:    -392 mA   ← 省 216mA
  DPMS Off:        -356 mA   ← 省 250mA（之前 484-604mA）
```

## GPU DVFS（同一镜像）

```
/sys/class/devfreq/14ac0000.gpu  ← devfreq 设备
/sys/kernel/debug/panfrost-g3d/{rate,state,strategy}
  state: ramp=on strategy=0 pll=266000000 core=266000000
         mux_parent_rate=266000000 safe=24000000

⇒ 真实频率 266MHz（之前 DTS 里 FRATE(700000000) 是假的）
```

## 手动操作

```sh
# 亮度
echo 40  > /sys/class/backlight/s6e3hf2/brightness    # 暗
echo 255 > /sys/class/backlight/s6e3hf2/brightness    # 亮

# GPU 频率（安全 ramp：mux→fin_pll→改PLL→udelay(50us)→mux 切回）
echo 700000000 > /sys/kernel/debug/panfrost-g3d/rate  # 升到 700MHz
echo 266000000 > /sys/kernel/debug/panfrost-g3d/rate  # 回 266MHz

# 回滚背光（重启后生效）
# 在 cmdline 加 exynosdrm.backlight=0
```
