/*
 * hid-dualsense - Sony DualSense on Linux 4.4 with the standard gamepad layout.
 *
 * Linux 4.4 has no driver for the DualSense (hid-playstation is 5.12): hid-generic takes it
 * and numbers its buttons and axes in the order of the HID report (Square first, the right
 * stick on ABS_Z / ABS_RZ), which no controller database expects. This driver maps the
 * pad's simple report (the one it sends until a host asks for its extended report) to the
 * codes hid-playstation uses, so RetroArch's stock profile, SDL's evdev mappings and
 * anything else written for a current kernel work as they are.
 *
 * It does not speak the extended report: no rumble, lights, touchpad or motion.
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

#define DS_VENDOR_SONY   0x054c
#define DS_PRODUCT       0x0ce6
#define DS_PRODUCT_EDGE  0x0df2

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
MODULE_DESCRIPTION("Sony DualSense with the standard gamepad layout on Linux 4.4");
MODULE_LICENSE("GPL");
