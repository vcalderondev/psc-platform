#!/bin/sh
# Build the PlayStation Classic compositor from upstream sources:
# Wayland 1.26.0 + wayland-protocols 1.45 + Weston 6.0.1, with the PSC patches in
# compositor/patches/. Output: out/compositor/psc-weston.tar.gz, laid out as /usr
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
REPO="$(dirname "$HERE")"
OUT="$REPO/out/compositor"
CACHE="$OUT/cache"
B=/tmp/lw-build
STAGE=/tmp/lw-stage            # what ends up under /usr on the console
SYSROOT=/opt/psc/sysroot
mkdir -p "$CACHE" "$B" "$STAGE"
. /opt/psc/bin/psc-env

WAYLAND=1.26.0; PROTOCOLS=1.45; WESTON=6.0.1
GL=https://gitlab.freedesktop.org/wayland
# run a build step quietly; on failure show the end of its log
step() { name=$1; shift; echo "== $name"; if ! "$@" > "$B/$name.log" 2>&1; then echo "FAILED: $name"; tail -40 "$B/$name.log"; exit 1; fi; }
fetch() { [ -s "$CACHE/$2" ] || wget -q -T 30 -t 3 -O "$CACHE/$2.part" "$1" && mv -f "$CACHE/$2.part" "$CACHE/$2" 2>/dev/null || true; [ -s "$CACHE/$2" ] || { echo "download failed: $1"; exit 1; }; }
fetch $GL/wayland/-/releases/$WAYLAND/downloads/wayland-$WAYLAND.tar.xz wayland-$WAYLAND.tar.xz
fetch $GL/wayland-protocols/-/releases/$PROTOCOLS/downloads/wayland-protocols-$PROTOCOLS.tar.xz wayland-protocols-$PROTOCOLS.tar.xz
fetch https://wayland.freedesktop.org/releases/weston-$WESTON.tar.xz weston-$WESTON.tar.xz

# ---- headers of the console's libraries (Debian stretch armhf -dev packages)
DEB=https://archive.debian.org/debian/pool/main
for p in libi/libinput/libinput-dev_1.6.3-1_armhf.deb \
         libe/libevdev/libevdev-dev_1.5.6+dfsg-1_armhf.deb \
         p/pixman/libpixman-1-dev_0.34.0-1_armhf.deb \
         c/cairo/libcairo2-dev_1.14.8-1_armhf.deb \
         e/expat/libexpat1-dev_2.2.0-2+deb9u3_armhf.deb \
         libf/libffi/libffi-dev_3.2.1-6_armhf.deb \
         libx/libxkbcommon/libxkbcommon-dev_0.7.1-2~deb9u1_armhf.deb \
         libd/libdrm/libdrm-dev_2.4.74-1_armhf.deb \
         libp/libpng1.6/libpng-dev_1.6.28-1+deb9u1_armhf.deb; do
  f="$(basename "$p")"; fetch "$DEB/$p" "$f"; dpkg -x "$CACHE/$f" "$SYSROOT"
done
# link-time only: the console's .so files carry their own dependencies, so the private
# requirements in these .pc files (fontconfig, xcb, ...) need not be resolvable here
for pc in "$SYSROOT"/usr/lib/arm-linux-gnueabihf/pkgconfig/cairo*.pc; do sed -i '/^Requires.private:/d' "$pc"; done
# the -dev packages bring static archives and .so links to runtime packages we do not
# unpack: drop both, so -lfoo resolves to the console's own library (devlink)
for l in cairo cairo-script-interpreter input evdev pixman-1 expat ffi xkbcommon drm png16 png; do
  rm -f "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.a"
  [ -L "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so" ] && [ ! -e "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so" ] &&
    rm -f "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so"
done
# pkg-config for the console (cross) lookups only: our own builds install into the
# sysroot's /usr/lib/pkgconfig, searched first, so they win over stretch's versions.
# Build-machine lookups (wayland-scanner) use the container's own pkg-config untouched.
cat > /opt/psc/bin/cw-pkg-config <<PC
#!/bin/sh
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig:$SYSROOT/usr/lib/arm-linux-gnueabihf/pkgconfig
exec pkg-config "\$@"
PC
chmod +x /opt/psc/bin/cw-pkg-config
unset PKG_CONFIG PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR

# ---- native wayland-scanner (runs on the build machine)
if ! command -v wayland-scanner >/dev/null; then
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gcc g++ libc6-dev libexpat1-dev libffi-dev libxml2-dev >/dev/null 2>&1
  rm -rf "$B/wl-native" && mkdir -p "$B/wl-native" && tar xf "$CACHE/wayland-$WAYLAND.tar.xz" -C "$B/wl-native" --strip-components=1
  (cd "$B/wl-native" && env -u PKG_CONFIG -u PKG_CONFIG_LIBDIR -u CC -u CFLAGS -u LDFLAGS \
     -u CXX -u CXXFLAGS -u AR -u STRIP -u RANLIB -u PKG_CONFIG_SYSROOT_DIR \
     meson setup build --prefix=/usr/local -Dlibraries=false -Dtests=false -Ddocumentation=false -Ddtd_validation=false >"$B/native.log" 2>&1 &&
     ninja -C build install >>"$B/native.log" 2>&1) || { tail -20 "$B/native.log"; exit 1; }
fi
wayland-scanner --version

MCROSS="/opt/psc/meson-cross.ini"
sed "s#^pkg-config = .*#pkgconfig = '/opt/psc/bin/cw-pkg-config'#" /opt/psc/psc-cross.ini > "$MCROSS"
unset CC CXX AR STRIP_ RANLIB CFLAGS CXXFLAGS LDFLAGS   # meson takes them from the cross file

# ---- wayland (libraries for the console)
rm -rf "$B/wayland" && mkdir -p "$B/wayland" && tar xf "$CACHE/wayland-$WAYLAND.tar.xz" -C "$B/wayland" --strip-components=1
cd "$B/wayland"
step wayland-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Dscanner=false -Ddocumentation=false -Ddtd_validation=false -Dtests=false
step wayland-build ninja -C build
step wayland-install env DESTDIR="$STAGE" ninja -C build install
step wayland-sysroot env DESTDIR="$SYSROOT" ninja -C build install
# wayland-protocols (XML only)
rm -rf "$B/wp" && mkdir -p "$B/wp" && tar xf "$CACHE/wayland-protocols-$PROTOCOLS.tar.xz" -C "$B/wp" --strip-components=1
cd "$B/wp"
step protocols-setup meson setup build --prefix=/usr -Dtests=false
step protocols-install env DESTDIR="$SYSROOT" ninja -C build install

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
step weston-build ninja -C build
step weston-install env DESTDIR="$STAGE" ninja -C build install

# ---- package: the overlay holds only what the console needs at run time
rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/pkgconfig" "$STAGE/usr/share/wayland" \
       "$STAGE/usr/share/wayland-protocols" "$STAGE/usr/share/man" "$STAGE/usr/share/aclocal"
find "$STAGE" -name '*.a' -delete
find "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/usr/libexec" -type f -exec sh -c 'file "$1" | grep -q ELF && $STRIP "$1"' _ {} \; 2>/dev/null
mkdir -p "$OUT"
tar czf "$OUT/psc-weston.tar.gz" -C "$STAGE/usr" .
( cd "$STAGE/usr" && find . -type f | sort ) > "$OUT/psc-weston.files"
psc-check $(find "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/usr/libexec" -type f -name '*' | xargs file | grep ELF | cut -d: -f1) || true
ls -la "$OUT/psc-weston.tar.gz"
