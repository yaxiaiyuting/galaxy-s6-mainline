# ⚠️ cpuidle 移植 —— 未完成，p300 会导致 panic

## 状态
**p300（加了 idle-states）刷机后手机 panic**，需要长按电源键断电重启，
且因为 `CONFIG_PANIC_TIMEOUT=0` 不会自动重启，只能物理重启。

## 已确认的事实
1. S-Boot 的 PSCI **支持** CPU_SUSPEND（vendor DTS 有 `cpu_suspend = <0xC4000001>`）
2. PMU `0x105C0000` 不是死区，mainline 有 `samsung,exynos7-pmu` 节点
3. `arm,psci-suspend-param` 必须是 `0x10000`（POWERDOWN），
   用 vendor 的 `0x0` 会被 mainline 判成 STANDBY → entry_point=0 → 跑飞

## 但 p300 仍然 panic

**待查的疑点（cpuidle 子代理正在分析）**：
- mainline 的 `compatible = "arm,psci"`（v0.1 绑定）**根本不会解析 `cpu_suspend` 属性**
  → `psci_ops.cpu_suspend == NULL` → `cpuidle-psci` probe 应该安全失败，而不是 panic
- 那 panic 从哪来？需要看 p300 的完整 diff 和 panic 日志

## 文件
- `DO-NOT-USE-p300-idle-states-causes-panic.patch` —— p300 的完整 DTS 改动（**仅供分析，不要 apply**）

## 当前安全状态
源码树已回退到 p261 的 DTS（只保留 capacity-dmips-mhz + cpu-map），
`exynos7.dtsi` 里没有任何 cpuidle 相关改动。构建出来的镜像等同于 p261。

## 替代方案（如果 cpuidle 走不通）
用 CPU hotplug：`rootfs/power/g9209-cpu-idle.sh`
灭屏时下线大核（cpu1-4）+ 多余小核（cpu6-7），保留 cpu0/cpu5。
已实测有效（灭屏后在线 CPU = 0,5）。
