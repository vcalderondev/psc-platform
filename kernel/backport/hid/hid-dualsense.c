/*
 * hid-dualsense - Sony DualSense on Linux 4.4 with the standard gamepad layout.
 *
 * Linux 4.4 has no driver for the DualSense (hid-playstation is 5.12): hid-generic takes it
 * and numbers its buttons and axes in the order of the HID report (Square first, the right
 * stick on ABS_Z / ABS_RZ), which no controller database expects. This driver maps the
 * pad's simple report to the codes hid-playstation uses, so RetroArch's stock profile,
 * SDL's evdev mappings and anything else written for a current kernel work as they are.
 *
 * Battery: a power_supply (scope Device: capacity, charging), as hid-playstation has. Over
 * USB the pad's report 0x01 is the full one and carries it. Over Bluetooth only the full
 * report 0x31 does, which the pad sends once a host reads its calibration (feature 0x05);
 * the generic HID layer cannot read 0x31 (its descriptor calls it vendor data), so each one
 * is repacked here, before the core parses it, into the simple 0x01 the descriptor describes:
 * the input stays exactly as it was, with the battery on top.
 *
 * Not spoken: rumble, lights, touchpad, motion.
 *
 * On 4.4 hid-generic matches every device of group HID_GROUP_GENERIC and, being built in,
 * is asked first. A bus notifier takes a DualSense out of that group as it is added, so
 * this driver gets it; pads already there when the module loads are probed again.
 *
 * GPL-2.0
 */
#include <linux/device.h>
#include <linux/hid.h>
#include <linux/input.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/power_supply.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define DS_VENDOR_SONY   0x054c
#define DS_PRODUCT       0x0ce6
#define DS_PRODUCT_EDGE  0x0df2

#define DS_REPORT_USB			0x01	/* over USB: the full report */
#define DS_REPORT_BT_SIMPLE		0x01	/* over Bluetooth, until the full one is asked for */
#define DS_REPORT_BT_FULL		0x31
#define DS_BT_SIMPLE_SIZE		10
#define DS_FEATURE_CALIBRATION		0x05	/* reading it turns the full report on (Bluetooth) */
#define DS_FEATURE_CALIBRATION_SIZE	41
/* the full report's common part starts after the id (USB) or after the id and a tag
 * byte (Bluetooth): sticks LX LY RX RY, triggers L2 R2, a counter, buttons[4], ... and at
 * 52 the status byte: low nibble the charge in tenths, high nibble the charging state */
#define DS_COMMON_STATUS		52

struct ds_dev {
	struct hid_device *hdev;
	struct power_supply *battery;
	struct power_supply_desc desc;
	char name[64];
	spinlock_t lock;
	int capacity, status;	/* percent, POWER_SUPPLY_STATUS_* */
};

/* HID buttons 1..13 in report order; the touchpad click (14) and mute (15) have no
 * place on the gamepad (hid-playstation puts them elsewhere) */
static const u16 ds_keys[] = {
	BTN_WEST, BTN_SOUTH, BTN_EAST, BTN_NORTH,	/* Square, Cross, Circle, Triangle */
	BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,		/* L1, R1, L2, R2 */
	BTN_SELECT, BTN_START,				/* Create, Options */
	BTN_THUMBL, BTN_THUMBR,				/* L3, R3 */
	BTN_MODE,					/* PS */
};

/* 4.4 has no to_hid_device() */
static struct hid_device *ds_hdev(struct device *dev)
{
	return container_of(dev, struct hid_device, dev);
}

static bool ds_is(const struct hid_device *hdev)
{
	return hdev->vendor == DS_VENDOR_SONY &&
	       (hdev->product == DS_PRODUCT || hdev->product == DS_PRODUCT_EDGE);
}

static int ds_input_mapping(struct hid_device *hdev, struct hid_input *hi,
			    struct hid_field *field, struct hid_usage *usage,
			    unsigned long **bit, int *max)
{
	unsigned int id = usage->hid & HID_USAGE;
	int code;

	if ((usage->hid & HID_USAGE_PAGE) == HID_UP_BUTTON) {
		if (id < 1 || id > ARRAY_SIZE(ds_keys))
			return -1;
		hid_map_usage_clear(hi, usage, bit, max, EV_KEY, ds_keys[id - 1]);
		return 1;
	}
	switch (usage->hid) {
	case HID_GD_Z:  code = ABS_RX; break;	/* right stick X */
	case HID_GD_RZ: code = ABS_RY; break;	/* right stick Y */
	case HID_GD_RX: code = ABS_Z;  break;	/* L2 */
	case HID_GD_RY: code = ABS_RZ; break;	/* R2 */
	default:
		return 0;	/* left stick, D-pad hat: as they are; the rest: hid-input decides */
	}
	hid_map_usage_clear(hi, usage, bit, max, EV_ABS, code);
	return 1;
}

static enum power_supply_property ds_battery_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_SCOPE,
};

static int ds_battery_get(struct power_supply *psy, enum power_supply_property psp,
			  union power_supply_propval *val)
{
	struct ds_dev *ds = power_supply_get_drvdata(psy);
	unsigned long flags;

	spin_lock_irqsave(&ds->lock, flags);
	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:   val->intval = ds->status; break;
	case POWER_SUPPLY_PROP_PRESENT:  val->intval = 1; break;
	case POWER_SUPPLY_PROP_CAPACITY: val->intval = ds->capacity; break;
	case POWER_SUPPLY_PROP_SCOPE:    val->intval = POWER_SUPPLY_SCOPE_DEVICE; break;
	default: spin_unlock_irqrestore(&ds->lock, flags); return -EINVAL;
	}
	spin_unlock_irqrestore(&ds->lock, flags);
	return 0;
}

/* the status byte, as hid-playstation reads it */
static void ds_battery_update(struct ds_dev *ds, u8 st)
{
	const int charge = st & 0x0f, state = st >> 4;
	int capacity, status;
	unsigned long flags;
	bool changed;

	switch (state) {
	case 0x0: capacity = min(charge * 10 + 5, 100); status = POWER_SUPPLY_STATUS_DISCHARGING; break;
	case 0x1: capacity = min(charge * 10 + 5, 100); status = POWER_SUPPLY_STATUS_CHARGING; break;
	case 0x2: capacity = 100; status = POWER_SUPPLY_STATUS_FULL; break;
	default:  capacity = 0; status = POWER_SUPPLY_STATUS_NOT_CHARGING; break;	/* out of range, error */
	}
	spin_lock_irqsave(&ds->lock, flags);
	changed = capacity != ds->capacity || status != ds->status;
	ds->capacity = capacity; ds->status = status;
	spin_unlock_irqrestore(&ds->lock, flags);
	if (changed && ds->battery)
		power_supply_changed(ds->battery);
}

static int ds_raw_event(struct hid_device *hdev, struct hid_report *report, u8 *data, int size)
{
	struct ds_dev *ds = hid_get_drvdata(hdev);
	const u8 *c;

	if (!ds || size < 1)
		return 0;
	if (hdev->bus == BUS_USB && data[0] == DS_REPORT_USB && size > 1 + DS_COMMON_STATUS) {
		ds_battery_update(ds, data[1 + DS_COMMON_STATUS]);
		return 0;
	}
	if (data[0] == DS_REPORT_BT_FULL && size > 2 + DS_COMMON_STATUS) {
		u8 s[DS_BT_SIMPLE_SIZE];

		c = data + 2;
		ds_battery_update(ds, c[DS_COMMON_STATUS]);
		/* the simple report: sticks, buttons (hat and faces; shoulders, Create, Options,
		 * L3, R3; PS and the touchpad click), then the triggers. hid_report_raw_event()
		 * looks the report up again by data[0], so it parses this as 0x01 */
		s[0] = DS_REPORT_BT_SIMPLE;
		s[1] = c[0]; s[2] = c[1]; s[3] = c[2]; s[4] = c[3];
		s[5] = c[7]; s[6] = c[8]; s[7] = c[9] & 0x03;
		s[8] = c[4]; s[9] = c[5];
		memcpy(data, s, sizeof(s));
	}
	return 0;
}

static int ds_probe(struct hid_device *hdev, const struct hid_device_id *id)
{
	struct power_supply_config cfg = { };
	struct ds_dev *ds;
	int ret;

	ds = devm_kzalloc(&hdev->dev, sizeof(*ds), GFP_KERNEL);
	if (!ds)
		return -ENOMEM;
	ds->hdev = hdev;
	spin_lock_init(&ds->lock);
	ds->capacity = 100;
	ds->status = POWER_SUPPLY_STATUS_UNKNOWN;
	hid_set_drvdata(hdev, ds);

	ret = hid_parse(hdev);
	if (ret)
		return ret;
	ret = hid_hw_start(hdev, HID_CONNECT_DEFAULT);
	if (ret)
		return ret;

	snprintf(ds->name, sizeof(ds->name), "ps-controller-battery-%s",
		 hdev->uniq[0] ? hdev->uniq : dev_name(&hdev->dev));
	ds->desc.name = ds->name;
	ds->desc.type = POWER_SUPPLY_TYPE_BATTERY;
	ds->desc.properties = ds_battery_props;
	ds->desc.num_properties = ARRAY_SIZE(ds_battery_props);
	ds->desc.get_property = ds_battery_get;
	cfg.drv_data = ds;
	ds->battery = devm_power_supply_register(&hdev->dev, &ds->desc, &cfg);
	if (IS_ERR(ds->battery)) {	/* the pad works without it */
		hid_warn(hdev, "dualsense: no battery (%ld)\n", PTR_ERR(ds->battery));
		ds->battery = NULL;
	} else {
		power_supply_powers(ds->battery, &hdev->dev);
	}

	if (hdev->bus == BUS_BLUETOOTH) {	/* the full report, for the battery */
		u8 *buf = kzalloc(DS_FEATURE_CALIBRATION_SIZE, GFP_KERNEL);

		if (buf) {
			ret = hid_hw_raw_request(hdev, DS_FEATURE_CALIBRATION, buf, DS_FEATURE_CALIBRATION_SIZE,
						 HID_FEATURE_REPORT, HID_REQ_GET_REPORT);
			if (ret < 0)
				hid_warn(hdev, "dualsense: full report not enabled (%d), no battery\n", ret);
			kfree(buf);
		}
	}
	return 0;
}

static void ds_remove(struct hid_device *hdev)
{
	hid_hw_stop(hdev);
}

static const struct hid_device_id ds_devices[] = {
	{ HID_BLUETOOTH_DEVICE(DS_VENDOR_SONY, DS_PRODUCT) },
	{ HID_USB_DEVICE(DS_VENDOR_SONY, DS_PRODUCT) },
	{ HID_BLUETOOTH_DEVICE(DS_VENDOR_SONY, DS_PRODUCT_EDGE) },
	{ HID_USB_DEVICE(DS_VENDOR_SONY, DS_PRODUCT_EDGE) },
	{ }
};
MODULE_DEVICE_TABLE(hid, ds_devices);

static struct hid_driver ds_driver = {
	.name = "dualsense",
	.id_table = ds_devices,
	.input_mapping = ds_input_mapping,
	.raw_event = ds_raw_event,
	.probe = ds_probe,
	.remove = ds_remove,
};

static int ds_bus_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	if (action == BUS_NOTIFY_ADD_DEVICE) {
		struct hid_device *hdev = ds_hdev(data);

		if (ds_is(hdev))
			hdev->group = HID_GROUP_ANY;	/* not hid-generic's */
	}
	return NOTIFY_DONE;
}

static struct notifier_block ds_nb = { .notifier_call = ds_bus_notify };

/* a pad that was connected before the module loaded: hid-generic has it */
static int ds_take(struct device *dev, void *unused)
{
	struct hid_device *hdev = ds_hdev(dev);

	if (ds_is(hdev) && hdev->group != HID_GROUP_ANY) {
		hdev->group = HID_GROUP_ANY;
		if (device_reprobe(dev))
			hid_warn(hdev, "dualsense: reprobe failed\n");
	}
	return 0;
}

static int __init ds_init(void)
{
	int ret = hid_register_driver(&ds_driver);

	if (ret)
		return ret;
	bus_register_notifier(ds_driver.driver.bus, &ds_nb);
	bus_for_each_dev(ds_driver.driver.bus, NULL, NULL, ds_take);
	return 0;
}

static void __exit ds_exit(void)
{
	bus_unregister_notifier(ds_driver.driver.bus, &ds_nb);
	hid_unregister_driver(&ds_driver);
}

module_init(ds_init);
module_exit(ds_exit);
MODULE_DESCRIPTION("Sony DualSense with the standard gamepad layout and its battery on Linux 4.4");
MODULE_LICENSE("GPL");
