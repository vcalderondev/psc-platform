# boot: Lumen's own USB boot payload (no Project Eris)

The PlayStation Classic runs a signed "diag" payload from a USB stick at every boot
(Sony's `/usr/bin/usb_watch`). Until now that payload was Project Eris' loader. This
folder builds Lumen's own: a `start` script that mounts the stick, stops Sony's UI,
shows Lumen's splash and runs `/media/lumen/boot.sh`. Nothing of Eris runs, and it never
writes the console's eMMC.

```
sh psc-platform/boot/build-payload.sh          # from the workspace folder (the one with device-dump/)
sh psc-platform/boot/test/run-start-tests.sh   # scenario tests of start (console bash, stubs)
sh psc-platform/boot/verify-payload.sh <LDIAG.BIN>
```

| File | What |
|---|---|
| `payload/start` | the payload's entry point (runs as root from `/tmp/diag/<id>/payload/`) |
| `splash/lumen-splash.c`, `splash/build.sh` | splash viewer: console SDL 2.0.4 + SDL2_image (dlopen), Wayland, until SIGTERM |
| `build-payload.sh` | builds the splash, stages `payload/`, tar.gz, signs + encrypts, verifies |
| `verify-payload.sh` | runs usb_watch's own checks with the console's gpg 1.4.7/busybox/bash under ARMv7 emulation, plus a tamper test |
| `test/run-start-tests.sh` | patched/virgin console, exFAT/FAT32/ext4, no Lumen, mount failure, ... |
| `gpg/Dockerfile` | gpg1 + GNU tar image used for packing and signing |

Output: `out/boot/LDIAG.BIN` (+ `.md5`, `verify.txt`) → `<stick>/d8781dae-c45c-4fc1-b961-e03eedebbffb/LDIAG.BIN`
(next to the empty `diag` file; keep Eris' file as `LDIAG.BIN.eris` for rollback).

## Keys: private, never in this repo

The payload is signed with the `siescph1000` key and encrypted to `siecs2` (plus a
symmetric layer with the keyring passphrase, which is how the console decrypts it: it
only holds `siecs2`'s public key). Those keys come from the console's own keyring
(`/home/root/.gnupg`, read from your device dump: `PSC_KEYRING`, default
`<workspace>/device-dump/sysroot/home/root/.gnupg`). The scripts refuse a keyring inside
this repo, only copy it into a throwaway container's `/tmp`, and `out/` plus every
`*.gpg`, `pass` and `LDIAG.BIN*` are git-ignored. Do not publish the keyring or a built
`LDIAG.BIN`.

## Console compatibility

| Console | Stick | Result |
|---|---|---|
| patched by Eris/BleemSync (`/sbin/mount.exfat` on the rootfs) | exFAT | Lumen boots |
| any | FAT32 or ext4 (kernel filesystems) | Lumen boots |
| never modded ("virgin") | exFAT | Sony's usb_watch cannot mount the stick: payload never runs, stock menu (no change, no risk) |
| any | no `lumen/boot.sh`, or `lumen/disable-boot` present, or mount fails | Sony's menu comes back, payload parks |

Design, verification log, console test plan and rollback:
`research-notes/no-eris-boot.md` in the workspace.
