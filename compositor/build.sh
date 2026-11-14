#!/bin/sh
# Build the PSC compositor, Weston 16.0.2, for the PlayStation Classic from upstream
# sources: Wayland 1.26.0 + wayland-protocols 1.46, libdrm
# 2.4.124, seatd/libseat 0.9.1 (builtin backend), libdisplay-info 0.2.0 (static), a
# static gbm compat shim (compositor/gbm-compat/) and the PSC patches in
# compositor/patches/. Output: out/compositor/psc-weston-16.tar.gz, laid out as
# /usr for a frontend's boot script to overlay from RAM (nothing on the eMMC changes).
#
#   toolchain/psc sh psc-platform/compositor/build.sh   (from the workspace folder)
#
# Shipped in the overlay besides Weston and Wayland: libdrm.so.2 (replaces the
# console's 2.4.66-2.4.70 era copy; Weston 16 needs >= 2.4.108) and libseat.so.1.
# The console's libgbm stays (its Mesa 17 libEGL reads libgbm's internals): Weston 16
# calls 9 gbm functions it lacks, which the shim provides inside drm-backend.so and
# gl-renderer.so. libwayland-egl stays the console's (its Mesa 17 EGL needs the old wl_egl_window layout).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

WAYLAND=1.26.0; PROTOCOLS=1.46; WESTON=16.0.2
LIBDRM=2.4.124          # >= 2.4.108 for Weston 16; < 2.4.130 keeps the KMS color-pipeline code out
SEATD=0.9.1; DISPLAYINFO=0.2.0; MESA_GBM_H=22.3.7   # Mesa headers only
fetch_sha $GL/wayland/-/releases/$WAYLAND/downloads/wayland-$WAYLAND.tar.xz wayland-$WAYLAND.tar.xz \
  64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3
fetch_sha $GL/wayland-protocols/-/releases/$PROTOCOLS/downloads/wayland-protocols-$PROTOCOLS.tar.xz wayland-protocols-$PROTOCOLS.tar.xz \
  fd0de056a895fa48bd1aa5f0b8dfeed454101b88bc7e1c61a953422eb71db167
fetch_sha $GL/weston/-/releases/$WESTON/downloads/weston-$WESTON.tar.xz weston-$WESTON.tar.xz \
  49dd87d18cb229384264d2f69cb5a51f14f61a111e9227bfedb91b3ca8c39643
fetch_sha https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM.tar.xz libdrm-$LIBDRM.tar.xz \
  ac36293f61ca4aafaf4b16a2a7afff312aa4f5c37c9fbd797de9e3c0863ca379
fetch_sha https://git.sr.ht/~kennylevinsen/seatd/archive/$SEATD.tar.gz seatd-$SEATD.tar.gz \
  819979c922a0be258aed133d93920bce6a3d3565a60588d6d372ce9db2712cd3
fetch_sha https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/$DISPLAYINFO/downloads/libdisplay-info-$DISPLAYINFO.tar.xz libdisplay-info-$DISPLAYINFO.tar.xz \
  5a2f002a16f42dd3540c8846f80a90b8f4bdcd067a94b9d2087bc2feae974176
# gbm.h of a Mesa new enough for every gbm call Weston 16 makes (21.3+); prototypes only
fetch_sha https://gitlab.freedesktop.org/mesa/mesa/-/raw/mesa-$MESA_GBM_H/src/gbm/main/gbm.h gbm-mesa-$MESA_GBM_H.h \
  f80dcf33c961c8d31a9b03e3c807f4c22b4851f2950393e3245a2a19ea7ea513
# GLES2/gl2ext.h of the same Mesa: stretch's (Mesa 13) lacks typedefs the GL renderer uses
fetch_sha https://gitlab.freedesktop.org/mesa/mesa/-/raw/mesa-$MESA_GBM_H/include/GLES2/gl2ext.h gl2ext-mesa-$MESA_GBM_H.h \
  b60bedf57ba52be7e14af410b30ec9c122b6b1c413e901a1a1eb7b7d058c1bc3

console_headers
# hwdata: libdisplay-info builds its PNP ID table from /usr/share/hwdata/pnp.ids
native_scanner wayland-$WAYLAND.tar.xz hwdata
[ -f /usr/share/hwdata/pnp.ids ] || { apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends hwdata >/dev/null 2>&1; }
cross_file
cp "$CACHE/gl2ext-mesa-$MESA_GBM_H.h" "$SYSROOT/usr/include/GLES2/gl2ext.h"   # headers only

# ---- libdrm (shipped: libdrm.so.2 replaces the console's in the overlay)
unpack libdrm-$LIBDRM.tar.xz libdrm
cd "$B/libdrm"
step libdrm-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
   -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled \
   -Detnaviv=disabled -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
   -Dfreedreno-kgsl=false -Dinstall-test-programs=false -Dudev=false -Dtests=false
step libdrm-build $NINJA -C build
step libdrm-install env DESTDIR="$STAGE" $NINJA -C build install
step libdrm-sysroot env DESTDIR="$SYSROOT" $NINJA -C build install
# the overlay replaces the console's libdrm.so.2, so link against this one: the
# toolchain's devlink (the console's own libraries, searched first) must point here too
for l in libdrm.so libdrm.so.2; do ln -sfn "$SYSROOT/usr/lib/libdrm.so.2" "/opt/psc/devlink/$l"; done

# ---- gbm: the console's libgbm + a static shim for what it lacks (build-time only).
# gbm.pc reports 21.1.1 (Weston's minimum) and links the shim ahead of -lgbm, which
# resolves to the console's libgbm.so.1 (devlink).
GBMC=$SYSROOT/usr/lib/psc-gbm-compat
mkdir -p "$GBMC" "$SYSROOT/usr/include/psc-gbm-compat"
cp "$CACHE/gbm-mesa-$MESA_GBM_H.h" "$SYSROOT/usr/include/psc-gbm-compat/gbm.h"
step gbm-compat sh -c "arm-linux-gnueabihf-gcc $PSC_FLAGS -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Werror \
   -I$SYSROOT/usr/include/psc-gbm-compat -c '$HERE/gbm-compat/gbm-psc-compat.c' -o '$B/gbm-psc-compat.o' &&
   rm -f '$GBMC/libgbm-psc-compat.a' && arm-linux-gnueabihf-ar rcs '$GBMC/libgbm-psc-compat.a' '$B/gbm-psc-compat.o'"
cat > "$SYSROOT/usr/lib/pkgconfig/gbm.pc" <<'PC'
prefix=/usr
libdir=${prefix}/lib/psc-gbm-compat
includedir=${prefix}/include/psc-gbm-compat

Name: gbm
Description: PSC console libgbm (Mesa 17.0, PowerVR) + static compat shim for newer gbm calls
Version: 21.1.1
Libs: -L${libdir} -lgbm-psc-compat -lgbm
Cflags: -I${includedir}
PC

# ---- seatd: libseat only (shipped), builtin backend (in-process seatd for root);
# logind needs systemd >= 237 and the console has 229
unpack seatd-$SEATD.tar.gz seatd
cd "$B/seatd"
step seatd-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Dlibseat-logind=disabled -Dlibseat-builtin=enabled -Dlibseat-seatd=enabled \
   -Dserver=disabled -Dexamples=disabled -Dman-pages=disabled
step seatd-build $NINJA -C build
step seatd-install env DESTDIR="$STAGE" $NINJA -C build install
step seatd-sysroot env DESTDIR="$SYSROOT" $NINJA -C build install

# ---- libdisplay-info, static (linked into drm-backend.so; nothing shipped)
unpack libdisplay-info-$DISPLAYINFO.tar.xz libdisplay-info
cd "$B/libdisplay-info"
step displayinfo-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Ddefault_library=static
step displayinfo-build $NINJA -C build
step displayinfo-sysroot env DESTDIR="$SYSROOT" $NINJA -C build install

build_wayland $WAYLAND $PROTOCOLS

# ---- weston
unpack weston-$WESTON.tar.xz weston
for p in "$HERE"/patches/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -d "$B/weston" -p1 < "$p"; }; done
cd "$B/weston"
# allow-deprecated-modeset: legacy KMS stays available (WESTON_DISABLE_ATOMIC=1) in
# case atomic commits misbehave; deprecated-wl-shell: patch 0003, SDL 2.0.4 needs it
step weston-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Dbackend-drm=true -Dbackend-headless=false -Dbackend-pipewire=false -Dbackend-rdp=false \
   -Dbackend-vnc=false -Dbackend-wayland=false -Dbackend-x11=false -Dbackend-default=drm \
   -Drenderer-gl=true -Drenderer-vulkan=false -Dxwayland=false -Dsystemd=false \
   -Ddeprecated-remoting=false -Ddeprecated-pipewire=false -Dcolor-management-lcms=false \
   -Dimage-jpeg=false -Dimage-webp=false -Dshell-desktop=true -Dshell-kiosk=true -Dshell-ivi=false \
   -Dshell-lua=false -Ddemo-clients=false -Dsimple-clients=[] -Dtests=false -Ddoc=false \
   -Dperfetto=false -Dallow-deprecated-modeset=true -Ddeprecated-wl-shell=true \
   "-Dtools=['debug','info']"
step weston-build $NINJA -C build
step weston-install env DESTDIR="$STAGE" $NINJA -C build install

# ---- package and gate: also check the console's PowerVR stack (the libdrm users)
# against the overlay, since libdrm.so.2 is replaced under it
rm -rf "$STAGE/usr/share/libdrm"
PVR=""
for f in lib/libEGL.so.1 lib/libgbm.so.1 lib/libGLESv2.so.2 lib/libGLESv2_PVR_MESA.so \
         lib/libGLESv1_CM.so.1 lib/libGLESv1_CM_PVR_MESA.so lib/libsrv_um.so lib/libpvr_dri_support.so \
         local/lib/dri/pvr_dri.so; do
  [ -e "/device/usr/$f" ] && PVR="$PVR /device/usr/$f"
done
package_and_check psc-weston-16 psc-check.txt $PVR
