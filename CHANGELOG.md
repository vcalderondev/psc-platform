# Changelog

Every release lists the upstream version of each component in `versions.txt`.
Format: [Keep a Changelog](https://keepachangelog.com/); versions: [SemVer](https://semver.org/).

## [2.5.0] - 2026-11-17

Wi-Fi, Bluetooth controllers, USB Ethernet and SDL3 for Lumen PSX, all from RAM: new
packages a frontend unpacks to /tmp or overlays on /usr; nothing on the eMMC changes.
Verified on the console: SDL3 runs Lumen on Weston 16; on Sony's stock kernel the USB
Ethernet modules load. Not yet tried with real Wi-Fi / Bluetooth / Ethernet adapters.

### Added
- `psc-sdl3.tar.gz` (`sdl/build.sh`): SDL3 3.4.20 and sdl2-compat 2.32.74 (the SDL2 API
  on SDL3) for /usr: Wayland with xdg-shell, GLES, ALSA, udev and HIDAPI over hidraw
  (DualShock 4, DualSense, Switch Pro, Xbox pads). Every system library is loaded at run
  time; psc-check covers the console's own SDL2_image/ttf/mixer and Lumen against it.
- `psc-net.tar.gz` (`net/build.sh`): OpenSSL 4.1.0, wpa_supplicant 2.12 (+ wpa_cli,
  wpa_passphrase), iw 6.17, libnl 3.12.0 (genl), curl 8.23.0, zlib 1.4, BusyBox 1.38.0
  ntpd, Mozilla's CA bundle (2026-11-05) and the linux-firmware 20261019 files the stock
  kernel's Wi-Fi and Bluetooth drivers ask for. Smoke-tested on the console's ROOTFS1
  under ARMv7 emulation: HTTPS with the bundled CAs, NTP.
- `psc-bt.tar.gz` (`bt/build.sh`): BlueZ 5.88 (`bluetoothd` with input and HID over GATT,
  `bluetoothctl` with readline 8.3 linked in) on GLib 2.90.1, libffi 3.8.1, PCRE2 10.49;
  the console's libdbus 1.10 and system bus.
- `psc-netmod-stock.tar.gz` (`kernel/build-net-modules.sh`): 33 modules for Sony's stock
  4.4.22 kernel: mac80211 with mt7601u, rt2800usb and rtl8xxxu; Bluetooth with btusb and
  hidp; usbnet with r8152, ax88179_178a, asix, cdc_ether/ncm and smsc95xx. Checked
  offline against the stock image (vermagic, every symbol exported, no built-in change).
  ath9k and backports are not possible from RAM (relay; a built-in cfg80211).

### Notes
- This release was assembled on a workstation while the CI was unavailable: the
  components that did not change are the 2.4.1 release's files (checked against its
  SHA256SUMS); the four new packages were built with the recipes at this tag.

## [2.4.1] - 2026-11-15

### Fixed
- RetroArch crashed a few seconds into every game (`retroarch exit=139`, any core) with
  Lumen 0.12.0: a segfault at address 0 in `command_get_status`, on the first `GET_STATUS`
  network command after the content was up. Lumen's `retroarch.cfg` sets
  `libretro_directory`, RetroArch makes a core info entry for every core library in that
  folder, and without a matching `.info` file (Lumen ships none) the entry's `system_id` is
  NULL; `GET_STATUS` printed it unchecked. `lumen-buttons`' watchdog asks `GET_STATUS`
  every 2 s. `retroarch/patches/0004`: the system id falls back to the core's own name
  (`GET_STATUS PLAYING PCSX-ReARMed,<content>,crc32=...`), as it already did without a
  core info entry, and no field of the answer can be NULL. No `.info` files are added: the
  answer must not depend on them, since a core dropped into `cores/` has none either.
  Verified on the console: games start, play and exit again.

### Added
- `retroarch/test/get-status.sh`, run by `retroarch/build.sh` on the binary it just built
  (`out/retroarch/get-status.txt`, also in the release): it starts a game with the console
  binary under ARM emulation (the console's own loader and libraries, null video / audio
  drivers, a 60-line test core, `libretro_directory` as Lumen sets it) and asks
  `GET_STATUS`, without and with an `.info` file. The 2.4.0 binary fails it (exit 139 on
  the question); a failure stops the build. Without ARM emulation on the build machine it
  reports SKIPPED; the release workflow installs qemu-user for it.

## [2.4.0] - 2026-11-15

### Added
- Boot payload: the splash shows "Loading" with three animated dots at the bottom right,
  in the language Lumen is set to (`<stick>/lumen/settings.ini`, English as fallback; the
  text is a picture per language from Lumen's `assets/boot/`, also packed in the payload).
  It starts the moment Sony's boot animation ends, before the rest of the teardown, and
  `/tmp/lumen-splash.sh` lets Lumen's `boot.sh` show it again on the new compositor
  (`payload/splash.sh`, `lumen-splash --text`). Verified on the console (1080p, Weston 16):
  the splash is up 0.3 s after Sony's animation ends.

## [2.3.1] - 2026-11-15

### Fixed
- Mupen64Plus-Next (N64) froze RetroArch for good with a ROM that never programs the VI
  (seen on the console with a truncated dump, 128 KB of an 8 MB game: IPL3's checksum
  fails and the game spins). The core only returns from `retro_run` on a vertical
  interrupt, and the VI event is only scheduled after the game's first `VI_V_SYNC` write,
  so RetroArch's loop never ran again: no menu, no quit, no network commands, with any CPU
  core (dynarec or interpreters). `cores/patches/mupen64plus_next/0001`: a fallback VI
  event from power on that only hands control back, about a frame apart, until the game
  sets its own VI timing. Reproduced and checked under ARMv7 emulation (the console's
  binary, RetroArch 1.14, llvmpipe): the truncated ROM now leaves a black screen with
  RetroArch responsive, and three homebrew test ROMs run as before. Verified on the
  console with the patched core: Super Mario 64 starts, plays and exits cleanly.

### Added
- `cores/build.sh`: `KEEP_SYMBOLS=1` also keeps `<name>_libretro.unstripped.so`, to
  resolve the addresses of a crash report or a debugger session.

## [2.3.0] - 2026-11-14

### Added
- Hardware-rendered cores: they draw with GLES 3 on the PowerVR GE8300 through RetroArch's
  `gl` driver (libretro hardware context), linking the console's own libEGL / libGLESv2.
  - Mupen64Plus-Next (N64) in `cores/cores.list`: GLideN64, HLE RSP, the 32-bit ARM
    dynarec, Cortex-A35 / NEON in ARM mode (`TUNE=psc-arm`, new in `cores/build.sh`).
    Chosen over Flycast (Dreamcast) for this CPU: see README, "Hardware-rendered cores".
  - PPSSPP (PSP), its own recipe `cores/ppsspp/build.sh`: v1.20.4 from a shallow git
    checkout with the submodules it needs (cached as one tarball), CMake `LIBRETRO=ON`,
    GLES, ARMv7 JIT, no Vulkan, bundled FFmpeg. Release asset `ppsspp-assets.tar.gz`
    holds `PPSSPP/` for RetroArch's system folder (the core reads its fonts and data there).
    Links no libatomic (`patches/0001`; the console has none) and carries a hidden
    `fcntl64` shim (`psc-compat.c`) for upstream's prebuilt FFmpeg, built on glibc 2.28.
  - Both pass the `psc-check` gate (mupen64plus_next 4.3 MB, ppsspp 18 MB + 11 MB of
    assets); not yet verified on the console.
- `versions.txt`: `mupen64plus_next`, `ppsspp`.

## [2.2.1] - 2026-11-14

### Fixed
- `boot/`: the payload lets Sony's boot animation (`showLogo`) play to the end instead of
  cutting it. Sony's UI stays frozen, so its menu never follows. A finished `showLogo`
  stays a zombie under the frozen `sonyapp`, which busybox `pidof` still lists, so only
  live ones are waited for (15 s cap). Verified on the console.

## [2.2.0] - 2026-11-14

### Added
- `boot/`: Lumen's own USB boot payload, replacing Project Eris' loader.
  - It mounts the stick rw, stops Sony's UI, shows the splash (`lumen-splash`, the
    console's SDL 2.0.4) and runs `/media/lumen/boot.sh`.
  - It never writes the eMMC. With no Lumen on the stick, or `lumen/disable-boot`, it
    hands the console back to Sony's menu.
  - Release asset `psc-boot-payload.tar.gz` is **unsigned**. Consumers sign it with
    `.github/actions/boot-payload`, from a private input, and verify it with the
    console's own gpg 1.4.7 / busybox / bash (`verify-payload.sh`, ARMv7 emulation, plus
    a tamper test).
  - Verified on the console: exFAT and FAT32 sticks, hot-plug, the `disable-boot`
    hand-back, a stick made from scratch from a release zip.
- `kernel/`: `overlay.ko` + `xpad.ko` for Sony's stock kernel, so a never-modded console
  gets overlayfs for the PSC compositor without a kernel flash. The payload loads them
  from RAM only on the exact stock build, and only when the feature is missing.
  - Built from Sony's GPL source (pinned) with Sony's defconfig and GCC 6.3.
  - `check-modules.sh` checks them against the stock image: vermagic, no GOT
    references, symbol coverage, and provenance (every export of the built kernel is in
    the stock image).
  - Release asset `psc-kernel-modules.tar.gz`.
- `boot/release-layout.sh`: turns a frontend release zip into the ready-to-use stick
  layout (`d8781dae-…/`, `lumen/`, `games/`), with no Eris.
- `versions.txt`: `kernel` (the Sony source the modules are built from).

## [2.1.0] - 2026-11-14

### Added
- Cores for more systems, from pinned upstream commits with a generic recipe
  (`cores/build.sh` + `cores/cores.list`: each core's PSC make target, static libstdc++,
  psc-check gate): FCEUmm (NES), Snes9x (SNES), Genesis Plus GX (Mega Drive / Genesis),
  Gambatte (Game Boy / Color), gpSP with the ARM dynarec (GBA). NES and SNES verified on
  the console.

## [2.0.0] - 2026-11-14

### Removed
- Weston 6.0.1 (`psc-weston-6.tar.gz`) and its patches. Weston 16 is the only PSC
  compositor: on the console it runs Lumen at ~59 fps at 1080p and RetroArch 1.22 starts
  and exits back to the frontend cleanly. Without it a frontend falls back to Sony's
  Weston 1.11 and RetroArch's KMS context.

### Changed
- `compositor/build.sh` builds Weston 16.0.2 (was `build-16.sh`), patches in
  `compositor/patches/` (was `patches-16/`); its gate report is `psc-check.txt`.
- `versions.txt`: `weston`, `libdrm`, `libseat`, `libdisplay-info` (no `weston6`/`weston16`).

## [1.0.1] - 2026-11-14

### Fixed
- RetroArch: segfault right after EGL initialisation under Weston on the console. With
  GLES 3 enabled the build defines no `HAVE_OPENGLES2`, so the Wayland context had no
  attribute list for the GLES 2 context the `gl` driver asks for (patch 0003). Verified
  on the console: PCSX-ReARMed at 1920x1080, GLES 3.2 on the PowerVR GE8300, clean exit.
- CI: the native `wayland-scanner` is found on GitHub's x86-64 runners.

### Added
- `tools/debug`: `psc-crash.so`, an LD_PRELOAD crash reporter (registers, stack scan,
  library map, fsync'ed for the exFAT stick); RetroArch builds keep an unstripped
  `retroarch.debug` for symbolication, published with each release.

## [1.0.0] - 2026-11-14

First public release: the PlayStation Classic system layer, built from upstream sources.

### Added
- PSC cross toolchain: GCC 12.3 against a glibc 2.24 sysroot, linking the console's own
  libraries; `psc-check` gate that every binary loads on the console.
- Wayland 1.26.0 + wayland-protocols 1.45 + Weston 6.0.1 with PSC patches (skip the
  writeback connector, legacy fullscreen scanout, no AddFB2WithModifiers), run from RAM
  over `/usr` (nothing written to the eMMC). 1080p dashboard: 24 fps (Sony's Weston 1.11)
  to 58 fps with scanout.
- Weston 16.0.2 (libdrm 2.4.124, libseat 0.9.1, gbm compat shim; atomic KMS on the
  MediaTek driver, wl_shell restored). Experimental: the console crashed once when a
  game exited under atomic KMS; Weston 6 stays the default.
- RetroArch 1.22.2: Wayland xdg-shell + EGL/GLES 3.2, KMS/GBM context for running
  without a compositor, ALSA S16, udev input, HDMI without EDID; joypad profiles v1.22.0.
- PCSX-ReARMed libretro core from upstream (pinned commit), target `classic_armv8_a35`.
- CI release workflow: builds every component, gates it against the console, publishes
  the packages with this changelog and `versions.txt`.
