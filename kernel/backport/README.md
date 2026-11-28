# backport: newer driver sources for the stock 4.4.22 kernel

Copied over the kernel tree by `build-net-modules.sh` before it builds the modules.

| File | From | Why |
|---|---|---|
| `bluetooth/btrtl.c`, `btrtl.h` | Linux v5.10 `drivers/bluetooth/` (GPL-2.0) | 4.4 tells Realtek Bluetooth chips apart by `lmp_subver` only, so RTL8821C, 8822B/C, 8723D and 8761B get the wrong firmware (or none) and never come up. 5.10 matches `lmp_subver` + `hci_rev` and loads each chip's config. Changed: `kvmalloc` / `kvzalloc` fallbacks (4.12) at the top of `btrtl.c`. |
| `hid/hid-dualsense.c` | written for this kernel (GPL-2.0) | 4.4 has no DualSense driver (`hid-playstation` is 5.12): `hid-generic` numbers the pad in the order of its HID report, which no controller profile expects. This small driver maps the pad's simple report to the codes `hid-playstation` uses and takes the pad from `hid-generic` with a bus notifier. It also gives the pad's battery as a `power_supply` (scope Device: capacity, charging), like `hid-playstation`: over USB from the full report 0x01; over Bluetooth it turns the full report 0x31 on (it reads the calibration, feature 0x05) and repacks each one into the simple 0x01 before the HID core parses it, so the input is what it was. No rumble, lights, touchpad or motion. Built as `hid-dualsense.ko`. |
