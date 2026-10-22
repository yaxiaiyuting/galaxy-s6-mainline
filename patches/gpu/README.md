# GPU DVFS patch 集（Exynos 7420 / Mali-T760 MP8，SM-G9209）

配文档：`文档/05-专项/GPU-DVFS实现方案-20261023.md`

## 应用顺序

```sh
cd <linux-6.6 tree>
git apply patches/gpu/0001-panfrost-exynos-g3d-safe-ramp.patch
git apply patches/gpu/0002-clk-exynos7-real-pll1452x-and-hpm-div.patch
git apply patches/gpu/0003-dts-zeroflte-g3d-opp-devfreq.patch
```

| patch | 改什么 | 基线 |
|---|---|---|
| 0001 | panfrost devfreq：`target()` 走 "mux→fin_pll → 改 PLL → 等 50µs → mux→PLL"，加 `/sys/kernel/debug/panfrost-g3d/{state,rate,strategy}` | 原生 linux-6.6 `panfrost_devfreq.{c,h}` |
| 0002 | CMU_G3D：`fout_g3d_pll` 从 `FRATE(700MHz)` 改成真 `pll_1452x` + vendor `table_g3d[]` 全档；补 `sclk_hpm_g3d`(DIV_G3D[9:8]) 注册 | 原生 linux-6.6 `clk-exynos7.c` |
| 0003 | 板级 DTS：`&gpu` 加 OPP 表 / `mali-supply`(fixed 900mV) / `g3d-mux`,`g3d-pll`,`g3d-safe` 三个时钟 / 可选 `samsung,g3d-fixed-rate-hz` | 本项目 `patches/arch-arm64-boot-dts-exynos.patch` 之后的 `exynos7420-zeroflte.dts` |

## 一句话原理

CMU_G3D 的 GPU 时钟路径没有分频器（`g3d_pll`/`fin_pll` → mux → `aclk_g3d` gate → GPU），
变频 = 改 PLL；而在线改 PLL 会让 GPU 吃 PLL 重锁窗口里最长 37.5µs 的坏时钟（实测 266→700 一渲染就 SError）。
vendor 的解法是把 mux 先切到 24MHz 的 fin_pll、改完 PLL 再切回（`gpu_exynos7420.c:gpu_set_clock()`），本 patch 照做。

## 回滚

```sh
git apply -R patches/gpu/0001-panfrost-exynos-g3d-safe-ramp.patch
git apply -R patches/gpu/0002-clk-exynos7-real-pll1452x-and-hpm-div.patch
git apply -R patches/gpu/0003-dts-zeroflte-g3d-opp-devfreq.patch
```

注意：单独退 0002 会退回 `FRATE(700000000)`，那时 CCF 又开始谎报频率（硬件仍是 266MHz），不建议单独退。

## 注意：同目录的重复 patch

如果本目录里还出现 `clk-exynos7-gpu-pll.patch` / `gpu-opp-table.patch`，
那是同一次改动导出的**整文件 diff**（里面混着无关的 top0/topc/peric1 CMU 改动、
触摸/触摸键/UFS 的 DTS 改动），与本目录 `0002` / `0003` 重复。
**二选一，不要同时 apply。** 本 README 上面的 0001~0003 是裁剪过的 g3d-only 版本。
