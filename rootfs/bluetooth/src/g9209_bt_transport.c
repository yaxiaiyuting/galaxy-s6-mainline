// SPDX-License-Identifier: GPL-2.0-only
/* G9209 bring-up: use the known 24 MHz oscillator and route the LPASS UART IRQ.
 * This reversible module tests the transport without replacing a working BOOT.
 * UART clients must be stopped before loading or unloading it.
 */
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>

#define LPASS_VERSION 0x00
#define LPASS_INTR_CPU_MASK 0x58
#define LPASS_INTR_UART BIT(1)

static struct clk *baud, *oscillator, *mux, *saved_parent;
static void __iomem *lpass;
static u32 saved_uart_irq;

static void release_resources(void)
{
	if (lpass)
		iounmap(lpass);
	if (!IS_ERR_OR_NULL(oscillator))
		clk_put(oscillator);
	if (!IS_ERR_OR_NULL(baud))
		clk_put(baud);
}

static int __init g9209_bt_transport_init(void)
{
	struct device_node *node;
	struct of_phandle_args spec = {};
	u32 mask;
	int i, ret = -ENODEV;

	if (!of_machine_is_compatible("samsung,zeroflte"))
		return -ENODEV;
	node = of_find_node_by_path("/soc@0/serial@11460000");
	if (!node)
		return -ENODEV;
	baud = of_clk_get_by_name(node, "clk_uart_baud0");
	of_node_put(node);
	if (IS_ERR(baud))
		return PTR_ERR(baud);
	mux = baud;
	for (i = 0; i < 3 && mux; ++i)
		mux = clk_get_parent(mux);
	if (!mux || strcmp(__clk_get_name(mux), "mout_aud_pll_user"))
		goto fail;
	saved_parent = clk_get_parent(mux);
	if (!saved_parent)
		goto fail;
	spec.np = of_find_node_by_path("/clock");
	if (!spec.np)
		goto fail;
	oscillator = of_clk_get_from_provider(&spec);
	of_node_put(spec.np);
	if (IS_ERR(oscillator)) {
		ret = PTR_ERR(oscillator);
		goto fail;
	}
	if (clk_get_rate(oscillator) != 24000000)
		goto fail;
	lpass = ioremap(0x11400000, 0x100);
	if (!lpass) {
		ret = -ENOMEM;
		goto fail;
	}
	if (readl(lpass + LPASS_VERSION) != 0x00370100)
		goto fail;
	pr_info("g9209-bt: AUD parent %s, UART reported rate %lu before oscillator selection\n",
		__clk_get_name(saved_parent), clk_get_rate(baud));
	ret = clk_set_parent(mux, oscillator);
	if (ret)
		goto fail;
	/* The inherited /2 /2 divisors give a real and declared 6 MHz clock. */
	if (clk_get_rate(baud) != 6000000) {
		ret = -EINVAL;
		clk_set_parent(mux, saved_parent);
		goto fail;
	}
	mask = readl(lpass + LPASS_INTR_CPU_MASK);
	saved_uart_irq = mask & LPASS_INTR_UART;
	writel(mask | LPASS_INTR_UART, lpass + LPASS_INTR_CPU_MASK);
	if (!(readl(lpass + LPASS_INTR_CPU_MASK) & LPASS_INTR_UART)) {
		ret = -EIO;
		clk_set_parent(mux, saved_parent);
		goto fail;
	}
	pr_info("g9209-bt: UART clock 6000000 Hz from fin_pll; LPASS UART CPU IRQ enabled\n");
	return 0;
fail:
	release_resources();
	return ret;
}

static void __exit g9209_bt_transport_exit(void)
{
	u32 mask = readl(lpass + LPASS_INTR_CPU_MASK);

	writel((mask & ~LPASS_INTR_UART) | saved_uart_irq,
	       lpass + LPASS_INTR_CPU_MASK);
	if (clk_set_parent(mux, saved_parent))
		pr_err("g9209-bt: failed to restore AUD clock parent\n");
	release_resources();
}

module_init(g9209_bt_transport_init);
module_exit(g9209_bt_transport_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Reversible G9209 LPASS UART transport bring-up workaround");
