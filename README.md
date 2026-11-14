# psc-platform

The system layer for software running on a PlayStation Classic (PSC), built from
source: the cross toolchain and the platform components that frontends and emulators
run on. Frontends such as [Lumen PSX](https://github.com/vcalderondev/lumen-psx) consume its
build artefacts; it has no frontend logic of its own.

| Part | What | Output |
|---|---|---|
| `toolchain/` | Docker image with GCC 12.3 targeting the PSC (armhf, glibc 2.24 sysroot), linking against the console's own libraries; `toolchain/psc <cmd>` runs a command in it, `psc-check` verifies a binary loads on the console | image `psc-toolchain:gcc12-glibc2.24` |
| `compositor/` | Wayland 1.26.0 + Weston 16.0.2 with the PSC patches (`compositor/patches/`), libdrm 2.4.124, libseat 0.9.1 and a gbm compat shim, replacing Sony's Weston 1.11 at run time from RAM (overlay on `/usr`, nothing written to the eMMC) | `out/compositor/psc-weston-16.tar.gz` |
| `retroarch/` | RetroArch 1.22.2 with PSC patches (`retroarch/patches/`: ALSA S16, HDMI without EDID for KMS): Wayland xdg-shell + EGL/GLES 3.2 (KMS/GBM as a fallback context), ALSA, udev; links libwayland-client 1.26 (from the compositor overlay) and the console's libwayland-egl; plus the libretro joypad profiles | `out/retroarch/psc-retroarch.tar.gz` |
| `tools/debug/` | `psc-crash.so`, an LD_PRELOAD crash reporter (registers, stack scan, library map; resolve with `retroarch.debug`) | `out/debug/psc-crash.so` |
| `cores/pcsx_rearmed/` | PCSX-ReARMed libretro core, upstream `libretro/pcsx_rearmed` (pinned commit), upstream's PSC target `classic_armv8_a35` (NEON GPU, ari64 dynarec) | `out/cores/pcsx_rearmed_libretro.so` |

## Use

```sh
toolchain/psc build                              # build the toolchain image (once, ~40 min)
toolchain/psc sh psc-platform/compositor/build.sh     # Wayland 1.26 + Weston 16.0.2, from a workspace that holds device-dump/
toolchain/psc sh psc-platform/retroarch/build.sh      # RetroArch 1.22.2 (after a compositor build)
toolchain/psc sh psc-platform/cores/pcsx_rearmed/build.sh
```

RetroArch's gate checks it against the console with the compositor package overlaid
(`out/retroarch/psc-check.txt`): it needs that overlay (libwayland-client 1.26:
`wl_proxy_marshal_flags`; Sony's Weston 1.11 also lacks xdg-shell), so a frontend must
use it over Wayland only while the PSC compositor runs; without it, run it with the KMS
context (`video_context_driver = "kms"`, Sony's Weston stopped) and the overlay's Wayland
client libraries on `LD_LIBRARY_PATH`. It uses no xdg-output (only wl_compositor,
wl_shm and xdg_wm_base are required; viewporter, fractional-scale, idle-inhibit,
decorations and the rest are optional). Cores must load on the bare console.

The compositor recipe (`compositor/build.sh`, helpers in `compositor/common.sh`: console
headers, pkg-config wrapper, native wayland-scanner, Wayland, packaging) ends with a gate:
every binary in the package must load against the console's root filesystem with the
package overlaid on `/usr` (`out/compositor/psc-check.txt`).

`toolchain/psc` mounts the workspace at `/work`: `PSC_WORKSPACE` if set, else the
folder that holds `device-dump/` (the console's extracted root filesystem, needed to
link against the real libraries; not distributed here), else this repository.

## Why a newer Weston

Sony's Weston 1.11 only speaks wl_shell (SDL ≥ 2.0.15, SDL3 and current RetroArch need
xdg-shell) and its recomposition of a fullscreen 1080p client costs most of a frame on
the PowerVR GE8300: measured on the console, a 1080p dashboard went from 24 fps to ~58
fps with a newer Weston that puts the fullscreen client straight on the display plane.
This repository rebuilds it from upstream sources with our own PSC patches instead of
shipping third-party binaries. Weston 6.0.1 was the first step (psc-platform 1.x); 2.0
keeps only Weston 16.

## Weston 16

`compositor/build.sh` builds Weston 16.0.2 (DRM backend, GL renderer, desktop and
kiosk shells, no Xwayland) for the console's kernel 4.4 / glibc 2.24 / Mesa 17 PowerVR
stack. Besides Weston and Wayland the overlay ships `libdrm.so.2` (2.4.124, replacing
the console's 2.4.66-2.4.70 era copy) and `libseat.so.1`; libdisplay-info is linked in
statically. The console's libgbm cannot be replaced (its libEGL reads libgbm's
internals), so `compositor/gbm-compat/` provides the 9 newer gbm calls Weston makes
(single plane, no modifiers) inside the DRM backend and GL renderer. Patches:

- `0001` atomic KMS on the MediaTek driver, which lacks `DRM_CAP_CRTC_IN_VBLANK_EVENT`
  and reports `crtc_id` 0 in flip events (accepted when there is a single CRTC).
  `WESTON_DISABLE_ATOMIC=1` falls back to legacy KMS (built with
  `allow-deprecated-modeset`), which never scans out client buffers.
- `0002` builds `weston-screenshooter` without udmabuf / `memfd_create`.
- `0003` restores `wl_shell` (removed upstream after Weston 10) behind
  `-Ddeprecated-wl-shell=true`: the console's SDL 2.0.4 speaks nothing else.

Starting it as root: there is no `--tty` (libseat's builtin backend takes the active VT,
so switch to it first) and the session comes from libseat:

```sh
chvt 1
export XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=builtin
mkdir -p "$XDG_RUNTIME_DIR" && chmod 0700 "$XDG_RUNTIME_DIR"
weston --backend=drm --shell=desktop --idle-time=0 --socket=wayland-0 --config=/tmp/lumen-weston.ini
```

`weston.ini` for the EDID-less HDMI: `[output] force-on=true` and `mode=<full
modeline>` (720p or 1080p), `[core] pageflip-timeout=1500`. `WESTON_FORCE_RENDERER=1`
composes everything with GL (no client buffer on a KMS plane), a debugging switch.

Tested on the console (2026-11-14): atomic KMS at 1920x1080, Lumen at ~59 fps, RetroArch
1.22 + PCSX-ReARMed starting and exiting back to the frontend, with this libdrm and the
gbm shim loaded by the PowerVR driver.

## Networks that intercept TLS

`toolchain/host-ca.pem` (git-ignored) is the CA bundle the image uses for HTTPS
downloads; put yours there before `toolchain/psc build`.

## What this replaces on the console

Nothing is written to the console's internal memory: the new graphics stack is unpacked
to RAM at every boot and mounted over `/usr` (overlayfs), and RetroArch and the cores run
from the USB stick. Lumen PSX installs these packages.

| Component | Stock console (Sony) | With Project Eris | Lumen PSX | How |
|---|---|---|---|---|
| Wayland (`libwayland-client`, `-server`, `-cursor`) | 1.12 | 1.12 | **1.26.0** | overlay on `/usr` (RAM) |
| wayland-protocols | — | — | **1.45** (1.46 for Weston 16) | build only |
| Compositor | Weston 1.11.0 | Weston 1.11.0 | **Weston 16.0.2** | overlay on `/usr` (RAM) |
| libdrm | 2.4.6x | 2.4.6x | **2.4.124** (with Weston 16 only) | overlay on `/usr` (RAM) |
| libseat | — | — | **0.9.1** (with Weston 16 only) | overlay on `/usr` (RAM) |
| libdisplay-info | — | — | **0.2.0** (static, in Weston 16) | overlay on `/usr` (RAM) |
| RetroArch | — (Sony's own `pcsx`) | 1.8.8 | **1.22.2** | USB (`lumen/retroarch`) |
| PCSX-ReARMed | — | PSC fork (2019) | **upstream** `libretro/pcsx_rearmed` (2026-10) | USB (`lumen/cores`) |
| Joypad profiles | — | RetroArch 1.8.8 set | **v1.22.0** | USB |

Kept from the console, unchanged: Linux 4.4.22, glibc 2.24, the PowerVR GE8300 driver
(DDK 1.9) with its Mesa 17 EGL / GLES / `libgbm` (closed, it cannot be replaced; a gbm
compat shim covers what Weston 16 needs), `libwayland-egl` (the old layout that EGL
expects), SDL 2.0.4, ALSA, udev and libxkbcommon.

## Releases and license

Tagged releases (`vX.Y.Z`, see `CHANGELOG.md`) are built by `.github/workflows/release.yml`:
every component from its pinned upstream version, gated with `psc-check`, published with
`versions.txt` and `SHA256SUMS`. The console's root filesystem the builds link against is
not part of this repository; CI fetches it from a private store (`PSC_SYSROOT_TOKEN`).
Lumen PSX uses `.github/actions/toolchain` and the release assets.

psc-platform is free software under the GNU GPL v3.0 or later (`LICENSE`); the upstream
components keep their own licenses (Wayland/Weston: MIT, RetroArch and PCSX-ReARMed: GPL).
