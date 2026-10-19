// SPDX-License-Identifier: GPL-2.0+
/*
 * Fuel gauge driver for the Maxim MAX77843 companion PMIC
 *
 * The MAX77843 fuel gauge block is register compatible with the MAX17050
 * (ModelGauge m3) family, but it sits behind a *separate* I2C slave
 * address (0x36) of the MAX77843.  The vendor 3.10 kernel created that
 * I2C client from the MAX77843 MFD core; mainline never did, so this
 * driver can bind either way:
 *
 *  a) as a platform driver on the MAX77843 MFD cell
 *     ("max77843-fuelgauge", compatible "maxim,max77843-fuelgauge") and
 *     create the 0x36 I2C client itself, or
 *  b) directly as an I2C driver for a "fuelgauge@36" device node.
 *
 * All values are read on demand; no register is written, so this driver
 * cannot disturb the charging configuration left by the bootloader.
 *
 * Register layout / data formats are taken from the Samsung universal7420
 * 3.10 driver (drivers/battery/max77843_fuelgauge.c).
 */

#include <linux/i2c.h>
#include <linux/mfd/core.h>
#include <linux/mfd/max77693-common.h>
#include <linux/mfd/max77843-private.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/slab.h>

#define MAX77843_FG_DRIVER_NAME	"max77843-fuelgauge"

/* Voltage LSB: 78.125 uV */
#define MAX77843_FG_VCELL_LSB_NV	78125
/* Current LSB: 1.5625 uV / 0.01 Ohm = 156.25 uA */
#define MAX77843_FG_CURRENT_LSB_NA	15625
/* Full capacity LSB: 0.5 mAh = 500 uAh */
#define MAX77843_FG_FULLCAP_LSB_UAH	500

/**
 * struct max77843_fg - fuel gauge device state
 * @dev: device owning this instance (platform or i2c device)
 * @client: I2C client of the fuel gauge block (address 0x36)
 * @battery: registered power supply
 * @lock: serializes register accesses
 */
struct max77843_fg {
	struct device *dev;
	struct i2c_client *client;
	struct power_supply *battery;
	struct mutex lock;
};

static int max77843_fg_read_word(struct max77843_fg *fg, u8 reg)
{
	int ret;

	mutex_lock(&fg->lock);
	ret = i2c_smbus_read_word_data(fg->client, reg);
	mutex_unlock(&fg->lock);

	if (ret < 0)
		dev_err_ratelimited(fg->dev,
				    "failed to read register 0x%02x: %d\n",
				    reg, ret);
	return ret;
}

/*
 * The gauge returns 16-bit values in SMBus word order (LSB first), which is
 * exactly what i2c_smbus_read_word_data() gives us.
 */
static int max77843_fg_read_vcell(struct max77843_fg *fg, int *val)
{
	int raw = max77843_fg_read_word(fg, MAX77843_FG_REG_VCELL);

	if (raw < 0)
		return raw;

	*val = DIV_ROUND_CLOSEST((u64)raw * MAX77843_FG_VCELL_LSB_NV, 1000);
	return 0;
}

static int max77843_fg_read_current(struct max77843_fg *fg, int *val)
{
	int raw = max77843_fg_read_word(fg, MAX77843_FG_REG_CURRENT);
	s16 ichg;

	if (raw < 0)
		return raw;

	ichg = (s16)raw;
	*val = DIV_ROUND_CLOSEST((s64)ichg * MAX77843_FG_CURRENT_LSB_NA, 100);
	return 0;
}

static int max77843_fg_read_avg_current(struct max77843_fg *fg, int *val)
{
	int raw = max77843_fg_read_word(fg, MAX77843_FG_REG_AVG_CURRENT);
	s16 ichg;

	if (raw < 0)
		return raw;

	ichg = (s16)raw;
	*val = DIV_ROUND_CLOSEST((s64)ichg * MAX77843_FG_CURRENT_LSB_NA, 100);
	return 0;
}

static int max77843_fg_read_temp(struct max77843_fg *fg, int *val)
{
	int raw = max77843_fg_read_word(fg, MAX77843_FG_REG_TEMP);
	s16 temp;

	if (raw < 0)
		return raw;

	/* 16-bit two's complement, LSB = 1/256 degC, result in 0.1 degC */
	temp = (s16)raw;
	*val = DIV_ROUND_CLOSEST((s64)temp * 10, 256);
	return 0;
}

static int max77843_fg_read_soc(struct max77843_fg *fg, int *val)
{
	int raw = max77843_fg_read_word(fg, MAX77843_FG_REG_SOCREP);
	int soc;

	if (raw < 0)
		return raw;

	/* high byte = integer percent, low byte = 1/256 percent */
	soc = DIV_ROUND_CLOSEST(raw, 256);
	*val = clamp(soc, 0, 100);
	return 0;
}

static int max77843_fg_read_fullcap(struct max77843_fg *fg, u8 reg, int *val)
{
	int raw = max77843_fg_read_word(fg, reg);

	if (raw < 0)
		return raw;

	*val = raw * MAX77843_FG_FULLCAP_LSB_UAH;
	return 0;
}

static int max77843_fg_get_status(struct max77843_fg *fg, int *val)
{
	struct power_supply *chg;
	union power_supply_propval prop;
	int ret, ichg;

	/* Prefer the charger driver's view when it is available */
	chg = power_supply_get_by_name("max77843-charger");
	if (chg) {
		ret = power_supply_get_property(chg,
						POWER_SUPPLY_PROP_STATUS,
						&prop);
		power_supply_put(chg);
		if (!ret) {
			*val = prop.intval;
			return 0;
		}
	}

	/* Fallback: derive it from the measured current */
	ret = max77843_fg_read_current(fg, &ichg);
	if (ret)
		return ret;

	if (ichg > 100000)
		*val = POWER_SUPPLY_STATUS_CHARGING;
	else if (ichg < -100000)
		*val = POWER_SUPPLY_STATUS_DISCHARGING;
	else
		*val = POWER_SUPPLY_STATUS_FULL;

	return 0;
}

static int max77843_fg_get_property(struct power_supply *psy,
				    enum power_supply_property psp,
				    union power_supply_propval *val)
{
	struct max77843_fg *fg = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		return max77843_fg_get_status(fg, &val->intval);
	case POWER_SUPPLY_PROP_PRESENT:
		/*
		 * The gauge only powers up with a battery attached (this
		 * driver is running from that battery), so report present.
		 */
		val->intval = 1;
		return 0;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		return 0;
	case POWER_SUPPLY_PROP_CAPACITY:
		return max77843_fg_read_soc(fg, &val->intval);
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		return max77843_fg_read_vcell(fg, &val->intval);
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		return max77843_fg_read_current(fg, &val->intval);
	case POWER_SUPPLY_PROP_CURRENT_AVG:
		return max77843_fg_read_avg_current(fg, &val->intval);
	case POWER_SUPPLY_PROP_TEMP:
		return max77843_fg_read_temp(fg, &val->intval);
	case POWER_SUPPLY_PROP_CHARGE_FULL:
		return max77843_fg_read_fullcap(fg, MAX77843_FG_REG_FULLCAP,
						&val->intval);
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
		return max77843_fg_read_fullcap(fg,
						MAX77843_FG_REG_FULLCAP_NOM,
						&val->intval);
	default:
		return -EINVAL;
	}
}

static enum power_supply_property max77843_fg_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CURRENT_AVG,
	POWER_SUPPLY_PROP_TEMP,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
};

static int max77843_fg_probe_common(struct device *dev,
				    struct i2c_client *client)
{
	struct power_supply_desc *desc;
	struct max77843_fg *fg;
	int ret, raw;

	fg = devm_kzalloc(dev, sizeof(*fg), GFP_KERNEL);
	if (!fg)
		return -ENOMEM;

	fg->dev = dev;
	fg->client = client;
	mutex_init(&fg->lock);

	/* Sanity check: the gauge must answer at all */
	raw = max77843_fg_read_word(fg, MAX77843_FG_REG_STATUS);
	if (raw < 0) {
		dev_err(dev, "fuel gauge does not respond: %d\n", raw);
		return -ENODEV;
	}
	dev_info(dev, "fuel gauge status=0x%04x\n", raw);

	desc = devm_kzalloc(dev, sizeof(*desc), GFP_KERNEL);
	if (!desc)
		return -ENOMEM;

	desc->name = MAX77843_FG_DRIVER_NAME;
	desc->type = POWER_SUPPLY_TYPE_BATTERY;
	desc->properties = max77843_fg_props;
	desc->num_properties = ARRAY_SIZE(max77843_fg_props);
	desc->get_property = max77843_fg_get_property;

	/*
	 * DSH 2026-10-20 关键修复：必须传 drv_data（同 charger 驱动）。
	 * 传 NULL 会让 psy->drv_data 为 NULL，get_property 里 fg->... 
	 * 立即 NULL 解引用（power_supply_changed_work → get_property 路径）。
	 */
	{
		struct power_supply_config cfg = {
			.drv_data = fg,
		};

		fg->battery = devm_power_supply_register(dev, desc, &cfg);
	}
	if (IS_ERR(fg->battery)) {
		ret = PTR_ERR(fg->battery);
		dev_err(dev, "failed to register power supply: %d\n", ret);
		return ret;
	}

	dev_info(dev, "MAX77843 fuel gauge registered\n");
	return 0;
}

/* ---------------------------------------------------------------------- */
/* Binding (a): MAX77843 MFD cell / platform device                       */
/* ---------------------------------------------------------------------- */

static int max77843_fg_platform_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct max77693_dev *max77843;
	struct i2c_client *client;

	if (!dev->parent)
		return -ENODEV;

	max77843 = dev_get_drvdata(dev->parent);
	if (!max77843 || !max77843->i2c)
		return -EPROBE_DEFER;

	/* The gauge block lives at its own I2C address on the same bus */
	client = devm_i2c_new_dummy_device(dev, max77843->i2c->adapter,
					   I2C_ADDR_FG);
	if (IS_ERR(client))
		return dev_err_probe(dev, PTR_ERR(client),
				     "cannot create I2C client for FG block\n");

	return max77843_fg_probe_common(dev, client);
}

static int max77843_fg_platform_remove(struct platform_device *pdev)
{
	return 0;
}

static const struct of_device_id max77843_fg_of_match[] = {
	{ .compatible = "maxim,max77843-fuelgauge" },
	{ }
};
MODULE_DEVICE_TABLE(of, max77843_fg_of_match);

static struct platform_driver max77843_fg_platform_driver = {
	.probe = max77843_fg_platform_probe,
	.remove = max77843_fg_platform_remove,
	.driver = {
		.name = MAX77843_FG_DRIVER_NAME,
		.of_match_table = max77843_fg_of_match,
	},
};

/* ---------------------------------------------------------------------- */
/* Binding (b): direct I2C device ("fuelgauge@36")                        */
/* ---------------------------------------------------------------------- */

static int max77843_fg_i2c_probe(struct i2c_client *client)
{
	return max77843_fg_probe_common(&client->dev, client);
}

static const struct i2c_device_id max77843_fg_i2c_id[] = {
	{ MAX77843_FG_DRIVER_NAME, 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, max77843_fg_i2c_id);

static struct i2c_driver max77843_fg_i2c_driver = {
	.driver = {
		.name = MAX77843_FG_DRIVER_NAME,
		.of_match_table = max77843_fg_of_match,
	},
	.probe = max77843_fg_i2c_probe,
	.id_table = max77843_fg_i2c_id,
};

static int __init max77843_fg_init(void)
{
	int ret;

	ret = platform_driver_register(&max77843_fg_platform_driver);
	if (ret)
		return ret;

	ret = i2c_add_driver(&max77843_fg_i2c_driver);
	if (ret)
		platform_driver_unregister(&max77843_fg_platform_driver);

	return ret;
}
module_init(max77843_fg_init);

static void __exit max77843_fg_exit(void)
{
	i2c_del_driver(&max77843_fg_i2c_driver);
	platform_driver_unregister(&max77843_fg_platform_driver);
}
module_exit(max77843_fg_exit);

MODULE_AUTHOR("Samsung Electronics");
MODULE_DESCRIPTION("MAX77843 fuel gauge driver");
MODULE_LICENSE("GPL v2");
