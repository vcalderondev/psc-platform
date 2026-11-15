# psc-platform

The system layer for software running on a PlayStation Classic (PSC), built from
source: the cross toolchain and the platform components that frontends and emulators
run on. Frontends such as [Lumen PSX](https://github.com/vcalderondev/lumen-psx) consume its
build artefacts; it has no frontend logic of its own.

| Part | What | Output |
|---|---|---|
| `toolchain/` | Docker image with GCC 12.3 targeting the PSC (armhf, glibc 2.24 sysroot), linking against the console's own libraries; `toolchain/psc <cmd>` runs a command in it, `psc-check` verifies a binary loads on the console | image `psc-toolchain:gcc12-glibc2.24` |
| `compositor/` | Wayland 1.26.0 + Weston 16.0.2 with the PSC patches (`compositor/patches/`), libdrm 2.4.124, libseat 0.9.1 and a gbm compat shim, replacing Sony's Weston 1.11 at run time from RAM (overlay on `/usr`, nothing written to the eMMC) | `out/compositor/psc-weston-16.tar.gz` |
| `retroarch/` | RetroArch 1.22.2 with PSC patches (`retroarch/patches/`: ALSA S16, HDMI without EDID for KMS, GLES 2 attributes on Wayland, `GET_STATUS` for a core without an `.info` file): Wayland xdg-shell + EGL/GLES 3.2 (KMS/GBM as a fallback context), ALSA, udev; links libwayland-client 1.26 (from the compositor overlay) and the console's libwayland-egl; plus the libretro joypad profiles | `out/retroarch/psc-retroarch.tar.gz` |
| `tools/debug/` | `psc-crash.so`, an LD_PRELOAD crash reporter (registers, stack scan, library map; resolve with `retroarch.debug`) | `out/debug/psc-crash.so` |
| `cores/pcsx_rearmed/` | PCSX-ReARMed libretro core, upstream `libretro/pcsx_rearmed` (pinned commit), upstream's PSC target `classic_armv8_a35` (NEON GPU, ari64 dynarec) | `out/cores/pcsx_rearmed_libretro.so` |
| `cores/build.sh` | more libretro cores from pinned upstream commits (`cores/cores.list`): FCEUmm (NES), Snes9x (SNES), Genesis Plus GX (Mega Drive), Gambatte (Game Boy / Color), gpSP (GBA), Mupen64Plus-Next (N64, hardware rendered: GLideN64 on GLES 3); each with its PSC make target or Cortex-A35 tuning, static libstdc++, psc-check gate | `out/cores/<name>_libretro.so` |
| `cores/ppsspp/` | PPSSPP libretro core (PSP), upstream `hrydgard/ppsspp` (pinned release), hardware rendered on GLES 3, ARM32 JIT, no Vulkan, bundled FFmpeg; plus the assets it reads from RetroArch's system folder | `out/cores/ppsspp_libretro.so`, `out/cores/ppsspp-assets.tar.gz` |
| `boot/` | Lumen's own USB boot payload: the signed `LDIAG.BIN` that Sony's `usb_watch` runs from the stick (mounts it, stops Sony's UI, splash, runs the frontend's `boot.sh`; nothing written to the eMMC). Built unsigned here (`build-payload.sh --pack-only`); signed by the frontend's release from a private input (`.github/actions/boot-payload`), verified with the console's own gpg/busybox under ARMv7 emulation | `out/boot/payload.tar.gz` (unsigned) |
| `kernel/` | `overlay.ko` and `xpad.ko` for Sony's stock kernel (Linux 4.4.22, built from Sony's GPL source + Sony's defconfig with GCC 6.3), so a never-modded console runs the PSC compositor without a kernel flash; checked against the stock image (vermagic, symbols, provenance) | `out/kernel/modules/*.ko` |

## Use

```sh
toolchain/psc build                              # build the toolchain image (once, ~40 min)
toolchain/psc sh psc-platform/compositor/build.sh     # Wayland 1.26 + Weston 16.0.2, from a workspace that holds device-dump/
toolchain/psc sh psc-platform/retroarch/build.sh      # RetroArch 1.22.2 (after a compositor build)
toolchain/psc sh psc-platform/cores/pcsx_rearmed/build.sh
toolchain/psc sh psc-platform/cores/build.sh all          # or one core: cores/build.sh snes9x
toolchain/psc sh psc-platform/cores/ppsspp/build.sh       # PPSSPP (git checkout with submodules)
sh psc-platform/kernel/build-modules.sh                   # overlay.ko + xpad.ko (docker, GCC 6.3)
sh psc-platform/boot/build-payload.sh --pack-only         # unsigned boot payload (+ modules)
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

## Hardware-rendered cores (N64, PSP)

Two cores draw with the GPU instead of handing RetroArch a software framebuffer: they ask
for a libretro hardware context (`RETRO_HW_CONTEXT_OPENGLES3`) and RetroArch's `gl` driver
creates it on its Wayland EGL context, on the console's PowerVR GE8300 (GLES 3.2, DDK 1.9).
They link the console's own `libEGL.so.1` / `libGLESv2.so.2`, so they still load on the bare
console (`psc-check`), but they only *run* inside RetroArch with a GL context.

- **N64: Mupen64Plus-Next** (`libretro/mupen64plus-libretro-nx`, GLideN64 renderer, HLE
  RSP, the 32-bit ARM `new_dynarec`). Chosen over Flycast (Dreamcast) because it is the
  one that fits the hardware: the console is a 4x Cortex-A35 running 32-bit userland, the
  class of the ODROID Go Advance (same CPU, GLES 3.2 GPU, 1 GB), on which Mupen64Plus-Next
  runs much of the N64 library at or near full speed, while Flycast's 32-bit ARM dynarec is
  barely maintained (upstream targets arm64), Dreamcast needs a BIOS and its games are
  far heavier on CPU, GPU and the 1 GB of RAM. Lumen already declares N64
  (`systems/n64.ini` -> `mupen64plus_next_libretro.so`). Upstream has no PSC make target:
  `platform=unix ARCH=arm WITH_DYNAREC=arm HAVE_NEON=1 FORCE_GLES3=1` with Cortex-A35 / NEON
  in ARM mode (`TUNE=psc-arm` in `cores/cores.list`). Angrylion and ParaLLEl-RDP (CPU /
  Vulkan renderers) are not built.
- **PSP: PPSSPP** (`hrydgard/ppsspp`, release tag): CMake `LIBRETRO=ON`, `USING_GLES2`
  (GLES 2/3 path; it creates a GLES 3 context), ARMv7 JIT, `ARM_NO_VULKAN` (the console
  has no Vulkan driver), FFmpeg from upstream's prebuilt `linux/armv7` libraries (PSP
  videos and audio), bundled libpng / zstd / freetype / libchdr; no libatomic
  (`patches/0001`) and a hidden `fcntl64` shim for that FFmpeg, which was built on glibc
  2.28 (`psc-compat.c`). Expect 2D and lighter 3D games at full speed at 1x (480x272);
  heavy 3D titles will not keep 60 fps on this CPU.
  PPSSPP needs its assets (fonts, `ppge_atlas.zim`, `compat.ini`, shaders...) in
  `<system_directory>/PPSSPP/`: unpack `ppsspp-assets.tar.gz` (it holds `PPSSPP/`) into
  RetroArch's system folder (Lumen: `/media/lumen/retroarch/system/`). A PSP BIOS is
  not needed.

RetroArch configuration they need (Lumen's `retroarch.cfg` already has it):

```ini
video_driver = "gl"                 # the only driver of this build with hw render (no Vulkan, no glcore)
video_context_driver = "wayland"    # EGL on the PSC compositor; "kms" also works without Weston
video_threaded = "false"            # RetroArch turns threaded video off for hw render cores anyway
video_shared_context = "false"      # neither core needs it
```

Core options worth knowing (per-core `.opt`, `<rgui_config_directory>/<core name>/`):

| core (`.opt` folder) | option | default | notes |
|---|---|---|---|
| Mupen64Plus-Next | `mupen64plus-rdp-plugin` | `gliden64` | the only renderer built |
| | `mupen64plus-cpucore` | `dynamic_recompiler` | `cached_interpreter` if a game misbehaves |
| | `mupen64plus-43screensize` | `640x480` | `320x240` for speed, `960x720` to try |
| | `mupen64plus-EnableFBEmulation` | `True` | `False` is faster, breaks some effects |
| PPSSPP | `ppsspp_internal_resolution` | `480x272` | `960x544` (2x) is Lumen's Enhanced preset |
| | `ppsspp_cpu_core` | `JIT` | |
| | `ppsspp_frameskip` / `ppsspp_auto_frameskip` | `disabled` / `disabled` | for heavy 3D games |

Not verified on the console yet: the builds pass `psc-check` only (see `CHANGELOG.md`).

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
| Boot hook (`LDIAG.BIN`) | — | Eris' loader (installs to the eMMC unless `USB_ONLY=1`) | **Lumen's payload** (RAM only) | USB (`d8781dae-…/`) |
| overlayfs, xpad | not in the kernel | flashed Eris kernel (BOOTIMG1) | **modules from RAM** on the stock kernel; built in on Eris' | USB (in the payload) |

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
components keep their own licenses (Wayland/Weston: MIT, RetroArch, PCSX-ReARMed,
Mupen64Plus-Next and PPSSPP: GPL).
The kernel modules are built from Sony's GPL-2.0 Linux source, imported in
[lscorcia/linux-sony-psclassic](https://github.com/lscorcia/linux-sony-psclassic) (commit
`d716d7e`, sha256-pinned in `kernel/build-modules.sh`), with `kernel/` as the build recipe.
The boot payload is published unsigned; the signing key is not part of this repository.
