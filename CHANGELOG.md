# Changelog

Every release lists the upstream version of each component in `versions.txt`.
Format: [Keep a Changelog](https://keepachangelog.com/); versions: [SemVer](https://semver.org/).

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
