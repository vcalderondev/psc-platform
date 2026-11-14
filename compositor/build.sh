#!/bin/sh
# Build the PlayStation Classic compositor from upstream sources:
# Wayland 1.26.0 + wayland-protocols 1.45 + Weston 6.0.1, with the PSC patches in
# compositor/patches/. Output: out/compositor/psc-weston-6.tar.gz, laid out as /usr
# (bin/ lib/ libexec/ share/) for a frontend's boot script to overlay from RAM
# (nothing on the eMMC changes). Lumen's scripts/boot.sh does that.
#
#   toolchain/psc sh psc-platform/compositor/build.sh   (from the workspace folder)
#
# Dependencies the console already has (libinput, libevdev, pixman, cairo, xkbcommon,
# libdrm, gbm, EGL/GLES of the PowerVR stack, udev, expat, ffi) are linked against the
# console's own .so files (toolchain devlink); only their headers come from Debian
# stretch -dev packages, unpacked into this throw-away container's sysroot.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

WAYLAND=1.26.0; PROTOCOLS=1.45; WESTON=6.0.1
fetch $GL/wayland/-/releases/$WAYLAND/downloads/wayland-$WAYLAND.tar.xz wayland-$WAYLAND.tar.xz
fetch $GL/wayland-protocols/-/releases/$PROTOCOLS/downloads/wayland-protocols-$PROTOCOLS.tar.xz wayland-protocols-$PROTOCOLS.tar.xz
fetch https://wayland.freedesktop.org/releases/weston-$WESTON.tar.xz weston-$WESTON.tar.xz

console_headers
native_scanner wayland-$WAYLAND.tar.xz
cross_file
build_wayland $WAYLAND $PROTOCOLS

# ---- weston
rm -rf "$B/weston" && mkdir -p "$B/weston" && tar xf "$CACHE/weston-$WESTON.tar.xz" -C "$B/weston" --strip-components=1
for p in "$HERE"/patches/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -d "$B/weston" -p1 < "$p"; }; done
cd "$B/weston"
step weston-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Dbackend-drm=true -Dbackend-headless=false -Dbackend-fbdev=false -Dbackend-rdp=false \
   -Dbackend-wayland=false -Dbackend-x11=false -Dbackend-drm-screencast-vaapi=false \
   -Drenderer-gl=true -Dweston-launch=false -Dxwayland=false -Dsystemd=false -Dremoting=false \
   -Dlauncher-logind=false -Dcolor-management-lcms=false -Dcolor-management-colord=false \
   -Dimage-jpeg=false -Dimage-webp=false -Dshell-desktop=true -Dshell-fullscreen=true -Dshell-ivi=false \
   -Ddemo-clients=false -Dsimple-clients=[] -Dsimple-dmabuf-drm=[] -Dwcap-decode=false -Dtest-junit-xml=false \
   "-Dtools=['debug','info']"
step weston-build $NINJA -C build
step weston-install env DESTDIR="$STAGE" $NINJA -C build install

package_and_check psc-weston-6 psc-check.txt
