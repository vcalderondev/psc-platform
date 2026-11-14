# Changelog

Every release lists the upstream version of each component in `versions.txt`.
Format: [Keep a Changelog](https://keepachangelog.com/); versions: [SemVer](https://semver.org/).

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
