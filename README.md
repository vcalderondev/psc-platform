# psc-platform

The system layer for software running on a PlayStation Classic (PSC), built from
source: the cross toolchain and the platform components that frontends and emulators
run on. Frontends such as [Lumen](https://github.com/vcalderondev/lumen) consume its
build artefacts; it has no frontend logic of its own.

| Part | What | Output |
|---|---|---|
| `toolchain/` | Docker image with GCC 12.3 targeting the PSC (armhf, glibc 2.24 sysroot), linking against the console's own libraries; `toolchain/psc <cmd>` runs a command in it, `psc-check` verifies a binary loads on the console | image `psc-toolchain:gcc12-glibc2.24` |
| `compositor/` | Wayland 1.26.0 + wayland-protocols 1.45 + Weston 6.0.1 with the PSC patches (`compositor/patches/`), replacing Sony's Weston 1.11 at run time from RAM (overlay on `/usr`, nothing written to the eMMC) | `out/compositor/psc-weston.tar.gz` |

Planned: RetroArch and libretro cores built for the PSC, so nothing depends on
third-party binary bundles.

## Use

```sh
toolchain/psc build                              # build the toolchain image (once, ~40 min)
toolchain/psc sh psc-platform/compositor/build.sh  # from a workspace that holds device-dump/
```

`toolchain/psc` mounts the workspace at `/work`: `PSC_WORKSPACE` if set, else the
folder that holds `device-dump/` (the console's extracted root filesystem, needed to
link against the real libraries; not distributed here), else this repository.

## Why a newer Weston

Sony's Weston 1.11 only speaks wl_shell (SDL ≥ 2.0.15, SDL3 and current RetroArch need
xdg-shell) and its recomposition of a fullscreen 1080p client costs most of a frame on
the PowerVR GE8300: measured on the console, a 1080p dashboard went from 24 to 45 fps
with a Weston 6 build. This repository rebuilds that from upstream sources with our own
PSC patches instead of shipping third-party binaries.

## Networks that intercept TLS

`toolchain/host-ca.pem` (git-ignored) is the CA bundle the image uses for HTTPS
downloads; put yours there before `toolchain/psc build`.
