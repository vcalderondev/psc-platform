# psc-platform

The system layer for software running on a PlayStation Classic (PSC), built from
source: the cross toolchain and the platform components that frontends and emulators
run on. Frontends such as [Lumen](https://github.com/vcalderondev/lumen) consume its
build artefacts; it has no frontend logic of its own.

| Part | What | Output |
|---|---|---|
| `toolchain/` | Docker image with GCC 12.3 targeting the PSC (armhf, glibc 2.24 sysroot), linking against the console's own libraries; `toolchain/psc <cmd>` runs a command in it, `psc-check` verifies a binary loads on the console | image `psc-toolchain:gcc12-glibc2.24` |
| `compositor/` | Wayland 1.26.0 + wayland-protocols 1.45 + Weston 6.0.1 with the PSC patches (`compositor/patches/`), replacing Sony's Weston 1.11 at run time from RAM (overlay on `/usr`, nothing written to the eMMC) | `out/compositor/psc-weston-6.tar.gz` |
| `compositor/` (16) | Weston 16.0.2 with its own patches (`compositor/patches-16/`), libdrm 2.4.124, libseat 0.9.1 and a gbm compat shim; same overlay model (see below) | `out/compositor/psc-weston-16.tar.gz` |

Planned: RetroArch and libretro cores built for the PSC, so nothing depends on
third-party binary bundles.

## Use

```sh
toolchain/psc build                              # build the toolchain image (once, ~40 min)
toolchain/psc sh psc-platform/compositor/build.sh     # Weston 6.0.1, from a workspace that holds device-dump/
toolchain/psc sh psc-platform/compositor/build-16.sh  # Weston 16.0.2
```

Both recipes share `compositor/common.sh` (console headers, pkg-config wrapper,
native wayland-scanner, Wayland, packaging) and end with the same gate: every binary in
the package must load against the console's root filesystem with the package overlaid
on `/usr` (`out/compositor/psc-check.txt`, `psc-check-16.txt`).

`toolchain/psc` mounts the workspace at `/work`: `PSC_WORKSPACE` if set, else the
folder that holds `device-dump/` (the console's extracted root filesystem, needed to
link against the real libraries; not distributed here), else this repository.

## Why a newer Weston

Sony's Weston 1.11 only speaks wl_shell (SDL ≥ 2.0.15, SDL3 and current RetroArch need
xdg-shell) and its recomposition of a fullscreen 1080p client costs most of a frame on
the PowerVR GE8300: measured on the console, a 1080p dashboard went from 24 to 45 fps
with a Weston 6 build. This repository rebuilds that from upstream sources with our own
PSC patches instead of shipping third-party binaries.

## Weston 16

`compositor/build-16.sh` builds Weston 16.0.2 (DRM backend, GL renderer, desktop and
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

Starting it as root differs from Weston 6: there is no `--tty` (libseat's builtin
backend takes the active VT, so switch to it first) and the session comes from libseat:

```sh
chvt 1
export XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=builtin
mkdir -p "$XDG_RUNTIME_DIR" && chmod 0700 "$XDG_RUNTIME_DIR"
weston --backend=drm --shell=desktop --idle-time=0 --config=/tmp/lumen-weston.ini
```

The `weston.ini` keys Lumen sets for Weston 6 still apply: `[output] force-on=true` and
`mode=<full modeline>` for the EDID-less HDMI, `[core] pageflip-timeout=1500`.

Untested on the console so far: the PowerVR driver's device discovery with the new
libdrm (`drmGetDevices` succeeds for the platform device for the first time; while the
overlay is mounted every process on the console loads this libdrm, not only Weston),
atomic commits on the 2018 vendor driver, and the gbm shim at run time. The build gate
checks the PowerVR libraries against the overlay's libdrm at symbol level only.

## Networks that intercept TLS

`toolchain/host-ca.pem` (git-ignored) is the CA bundle the image uses for HTTPS
downloads; put yours there before `toolchain/psc build`.
