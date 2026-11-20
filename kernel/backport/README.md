# backport: newer driver sources for the stock 4.4.22 kernel

Copied over the kernel tree by `build-net-modules.sh` before it builds the modules.

| File | From | Why |
|---|---|---|
| `bluetooth/btrtl.c`, `btrtl.h` | Linux v5.10 `drivers/bluetooth/` (GPL-2.0) | 4.4 tells Realtek Bluetooth chips apart by `lmp_subver` only, so RTL8821C, 8822B/C, 8723D and 8761B get the wrong firmware (or none) and never come up. 5.10 matches `lmp_subver` + `hci_rev` and loads each chip's config. Changed: `kvmalloc` / `kvzalloc` fallbacks (4.12) at the top of `btrtl.c`. |
