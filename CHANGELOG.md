# Changelog

Every release lists the upstream version of each component in `versions.txt`.
Format: [Keep a Changelog](https://keepachangelog.com/); versions: [SemVer](https://semver.org/).

## [Unreleased]

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
  RetroArch responsive, and three homebrew test ROMs run as before. Not yet verified on
  the console, and no commercial game has been run with it.

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
