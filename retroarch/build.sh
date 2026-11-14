#!/bin/sh
# Build RetroArch for the PlayStation Classic from upstream sources, for the PSC
# compositor (compositor/: Wayland 1.26 + Weston 6.0.1, and Weston 16 when built).
#
#   toolchain/psc sh psc-platform/retroarch/build.sh   (from the workspace folder)
#
# Output (out/retroarch/):
#   psc-retroarch.tar.gz   bin/retroarch + share/retroarch/autoconfig/udev (joypad profiles)
#   psc-check.txt          the gate: every binary loads on the console WITH the compositor
#                          overlay applied (libwayland-client 1.26 comes from that overlay)
#   configure.log, build-info.txt
#
# Video: Wayland context (xdg-shell, the only protocol it needs besides wl_compositor /
# wl_shm; it does not use xdg-output) + EGL + GLES 3.2 of the console's PowerVR stack.
# KMS/GBM is built in too as a fallback context (video_context_driver = "kms" runs
# without a compositor). Audio: ALSA (S16, see patches/0001). Input: udev.
#
# It links libwayland-client/-cursor 1.26 (built here, the same release the compositor
# ships) and the CONSOLE's libwayland-egl (its Mesa 17 EGL needs the old wl_egl_window
# layout), exactly like the compositor. So it does not run on Sony's Weston 1.11 /
# libwayland 1.12 alone: a frontend must only use it while the PSC compositor runs.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
OUT="$REPO/out/retroarch"
CACHE="$OUT/cache"
B=/tmp/ra-build
STAGE=/tmp/ra-stage
SYSROOT=/opt/psc/sysroot
JOBS="${JOBS:-4}"
mkdir -p "$CACHE" "$B" "$STAGE"
. /opt/psc/bin/psc-env

RA=1.22.2; WAYLAND=1.26.0; PROTOCOLS=1.45; AUTOCONFIG=v1.22.0
GL=https://gitlab.freedesktop.org/wayland
step() { name=$1; shift; echo "== $name"; if ! "$@" > "$B/$name.log" 2>&1; then echo "FAILED: $name"; tail -40 "$B/$name.log"; exit 1; fi; }
fetch() {  # url file: download once into the cache (HTTPS only); reuse the compositor's cache
  [ -s "$CACHE/$2" ] || { [ -s "$REPO/out/compositor/cache/$2" ] && cp "$REPO/out/compositor/cache/$2" "$CACHE/$2"; } || true
  case "$1" in https://*) ;; *) echo "refusing non-HTTPS download: $1"; exit 1 ;; esac
  [ -s "$CACHE/$2" ] || { wget -q -T 30 -t 3 -O "$CACHE/$2.part" "$1" && mv -f "$CACHE/$2.part" "$CACHE/$2"; } || true
  [ -s "$CACHE/$2" ] || { echo "download failed: $1"; exit 1; }
}
fetch https://github.com/libretro/RetroArch/archive/refs/tags/v$RA.tar.gz retroarch-$RA.tar.gz
fetch https://github.com/libretro/retroarch-joypad-autoconfig/archive/refs/tags/$AUTOCONFIG.tar.gz joypad-autoconfig-$AUTOCONFIG.tar.gz
fetch $GL/wayland/-/releases/$WAYLAND/downloads/wayland-$WAYLAND.tar.xz wayland-$WAYLAND.tar.xz
fetch $GL/wayland-protocols/-/releases/$PROTOCOLS/downloads/wayland-protocols-$PROTOCOLS.tar.xz wayland-protocols-$PROTOCOLS.tar.xz

# ---- headers of console libraries missing from the stretch sysroot
DEB=https://archive.debian.org/debian/pool/main
for p in libx/libxkbcommon/libxkbcommon-dev_0.7.1-2~deb9u1_armhf.deb \
         libd/libdrm/libdrm-dev_2.4.74-1_armhf.deb \
         libf/libffi/libffi-dev_3.2.1-6_armhf.deb \
         e/expat/libexpat1-dev_2.2.0-2+deb9u3_armhf.deb; do
  f="$(basename "$p")"; fetch "$DEB/$p" "$f"; dpkg -x "$CACHE/$f" "$SYSROOT"
done
for l in xkbcommon drm ffi expat; do
  rm -f "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.a"
  [ -L "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so" ] && [ ! -e "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so" ] &&
    rm -f "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so"
done

# ---- native wayland-scanner 1.26 (runs on the build machine)
if ! wayland-scanner --version 2>&1 | grep -q "$WAYLAND"; then
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gcc g++ libc6-dev libexpat1-dev libffi-dev libxml2-dev >/dev/null 2>&1
  rm -rf "$B/wl-native" && mkdir -p "$B/wl-native" && tar xf "$CACHE/wayland-$WAYLAND.tar.xz" -C "$B/wl-native" --strip-components=1
  (cd "$B/wl-native" && env -u PKG_CONFIG -u PKG_CONFIG_LIBDIR -u CC -u CFLAGS -u LDFLAGS \
     -u CXX -u CXXFLAGS -u AR -u STRIP -u RANLIB -u PKG_CONFIG_SYSROOT_DIR \
     meson setup build --prefix=/usr/local -Dlibraries=false -Dtests=false -Ddocumentation=false -Ddtd_validation=false >"$B/native.log" 2>&1 &&
     ninja -C build install >>"$B/native.log" 2>&1) || { tail -20 "$B/native.log"; exit 1; }
fi
echo "wayland-scanner $(wayland-scanner --version 2>&1)"

# ---- wayland 1.26 client libraries + wayland-protocols into the sysroot (link time)
MCROSS=/opt/psc/meson-cross-ra.ini
sed "s#^pkg-config = .*#pkgconfig = '/opt/psc/bin/psc-pkg-config'#" /opt/psc/psc-cross.ini > "$MCROSS"   # meson 1.0 key
unset PKG_CONFIG PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR   # meson: cross lookups via the cross file
rm -rf "$B/wayland" && mkdir -p "$B/wayland" && tar xf "$CACHE/wayland-$WAYLAND.tar.xz" -C "$B/wayland" --strip-components=1
cd "$B/wayland"
step wayland-setup env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS meson setup build --cross-file "$MCROSS" \
   --prefix=/usr --libdir=lib --buildtype=release -Dscanner=false -Ddocumentation=false -Ddtd_validation=false -Dtests=false
step wayland-build ninja -C build -j"$JOBS"
step wayland-sysroot env DESTDIR="$SYSROOT" ninja -C build install
rm -rf "$B/wp" && mkdir -p "$B/wp" && tar xf "$CACHE/wayland-protocols-$PROTOCOLS.tar.xz" -C "$B/wp" --strip-components=1
cd "$B/wp"
step protocols-setup env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS meson setup build --prefix=/usr -Dtests=false
step protocols-install env DESTDIR="$SYSROOT" ninja -C build install
# libwayland-egl stays the console's (see the compositor): drop 1.26's from the sysroot
rm -f "$SYSROOT"/usr/lib/libwayland-egl.so* "$SYSROOT"/usr/lib/pkgconfig/wayland-egl*.pc
# the toolchain links the console's libraries first (/opt/psc/devlink, libwayland 1.12):
# point libwayland-client/-cursor/-server at the 1.26 build, the version the compositor
# overlay puts on the console (this container is throw-away)
for l in client cursor server; do
  for n in /opt/psc/devlink/libwayland-$l.so /opt/psc/devlink/libwayland-$l.so.0; do
    ln -sfn "$SYSROOT/usr/lib/libwayland-$l.so.0" "$n"
  done
done
# pkg-config: our builds (sysroot /usr/lib/pkgconfig) first, then the console's stretch
# headers; the console has no wayland-egl.pc of its own version, so provide one for the
# devlink library (Mesa's libwayland-egl.so.1)
mkdir -p "$SYSROOT/usr/lib/pkgconfig"
cat > "$SYSROOT/usr/lib/pkgconfig/wayland-egl.pc" <<PC
prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: wayland-egl
Description: the console's libwayland-egl (Mesa 17)
Version: 17.0.0
Requires: wayland-client
Libs: -lwayland-egl
Cflags:
PC
cat > /opt/psc/bin/ra-pkg-config <<PC
#!/bin/sh
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig:$SYSROOT/usr/lib/arm-linux-gnueabihf/pkgconfig
exec /usr/bin/pkg-config "\$@"
PC
chmod +x /opt/psc/bin/ra-pkg-config
# RetroArch's protocol generator calls plain "pkg-config" for wayland-protocols' data
# dir and picks the scanner codegen from wayland-scanner.pc: both must be ours (1.26)
mkdir -p /tmp/ra-bin && ln -sfn /opt/psc/bin/ra-pkg-config /tmp/ra-bin/pkg-config
cat > "$SYSROOT/usr/lib/pkgconfig/wayland-scanner.pc" <<PC
prefix=/usr/local
bindir=\${prefix}/bin
wayland_scanner=/usr/local/bin/wayland-scanner
Name: Wayland Scanner
Description: Wayland scanner (build machine)
Version: $WAYLAND
PC
# headers: wayland-egl-core.h / wayland-egl.h come from wayland 1.26 (installed above,
# API-compatible: wl_egl_window_create/resize/destroy are all RetroArch calls)

# ---- RetroArch
rm -rf "$B/ra" && mkdir -p "$B/ra" && tar xzf "$CACHE/retroarch-$RA.tar.gz" -C "$B/ra" --strip-components=1
for p in "$HERE"/patches/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -d "$B/ra" -p1 < "$p" >/dev/null; }; done
cd "$B/ra"
PATH=/tmp/ra-bin:$PATH CROSS_COMPILE=arm-linux-gnueabihf- PKG_CONF_PATH=/opt/psc/bin/ra-pkg-config \
CFLAGS="$PSC_FLAGS -O2 -DPSC_ALSA_S16" CXXFLAGS="$PSC_FLAGS -O2 -DPSC_ALSA_S16" \
LDFLAGS="-static-libstdc++ -static-libgcc" \
./configure --prefix=/usr \
  --enable-wayland --enable-egl --enable-kms \
  --enable-opengles --enable-opengles3 --enable-opengles3_1 --enable-opengles3_2 \
  --enable-neon --enable-floathard \
  --enable-alsa --enable-udev --enable-threads --enable-zlib \
  --disable-sdl --disable-sdl2 --disable-x11 --disable-vulkan --disable-pulse --disable-qt \
  --disable-ffmpeg --disable-discord --disable-v4l2 --disable-libdecor --disable-systemd \
  --disable-dbus --disable-tinyalsa --disable-opengl1 --disable-crtswitchres --disable-jack \
  --disable-oss --disable-pipewire --disable-libusb --disable-builtinmbedtls \
  --disable-ssl --disable-cheevos --disable-update_cores --disable-update_assets \
  > "$OUT/configure.log" 2>&1 || { tail -30 "$OUT/configure.log"; exit 1; }
grep -E "wayland|egl|gles|alsa|udev|kms|gbm" "$OUT/configure.log" | grep -iE "presence|notice" || true
for k in HAVE_WAYLAND HAVE_EGL HAVE_OPENGLES3 HAVE_ALSA HAVE_UDEV HAVE_KMS; do
  grep -q "^$k = 1" config.mk || { echo "configure: $k missing"; grep -E "^HAVE_(WAYLAND|EGL|KMS|ALSA|UDEV|OPENGLES)" config.mk; exit 1; }
done
step retroarch-build make -j"$JOBS"

# ---- package
rm -rf "$STAGE" && mkdir -p "$STAGE/bin" "$STAGE/share/retroarch/autoconfig"
cp retroarch "$STAGE/bin/retroarch"; $STRIP "$STAGE/bin/retroarch"
rm -rf "$B/ac" && mkdir -p "$B/ac" && tar xzf "$CACHE/joypad-autoconfig-$AUTOCONFIG.tar.gz" -C "$B/ac" --strip-components=1
cp -r "$B/ac/udev" "$STAGE/share/retroarch/autoconfig/udev"
mkdir -p "$OUT"
tar czf "$OUT/psc-retroarch.tar.gz" -C "$STAGE" .
{ echo "RetroArch $RA (+ $(ls "$HERE"/patches | tr '\n' ' '))"; echo "wayland $WAYLAND, wayland-protocols $PROTOCOLS, joypad-autoconfig $AUTOCONFIG";
  grep -E "^HAVE_(WAYLAND|EGL|KMS|ALSA|UDEV|OPENGLES[0-9_]*|THREADS|NEON|ZLIB|NETWORKING|SDL2) = " config.mk; } > "$OUT/build-info.txt"

# ---- gate: the binary must load on the console with the compositor overlay on /usr
# (what boot.sh mounts) for each compositor package that exists. Against the bare console
# (Sony's libwayland 1.12) it is expected NOT to load: recorded for information only.
: > "$OUT/psc-check.txt"
gate=0; n=0
for pkg in "$REPO"/out/compositor/psc-weston-6.tar.gz "$REPO"/out/compositor/psc-weston.tar.gz "$REPO"/out/compositor/psc-weston-16.tar.gz; do
  [ -f "$pkg" ] || continue
  case "$pkg" in *psc-weston.tar.gz) [ -f "$REPO/out/compositor/psc-weston-6.tar.gz" ] && continue ;; esac
  COMBO=/tmp/ra-console; rm -rf "$COMBO"; mkdir -p "$COMBO/usr"
  ln -s /device/lib "$COMBO/lib"
  cp -a /device/usr/lib "$COMBO/usr/lib"
  mkdir -p /tmp/ra-overlay && rm -rf /tmp/ra-overlay/* && tar xzf "$pkg" -C /tmp/ra-overlay
  cp -a /tmp/ra-overlay/lib/. "$COMBO/usr/lib/"
  echo "### console + $(basename "$pkg")" >> "$OUT/psc-check.txt"
  if psc-check --device-root "$COMBO" "$STAGE/bin/retroarch" >> "$OUT/psc-check.txt" 2>&1; then n=$((n + 1))
  else gate=1; echo "psc-check FAILED with $(basename "$pkg")"; fi
done
[ $n -gt 0 ] || { echo "no compositor package in $REPO/out/compositor: build compositor/ first"; exit 1; }
echo "### bare console (Sony Weston 1.11 / libwayland 1.12): expected to fail" >> "$OUT/psc-check.txt"
psc-check --device-root /device "$STAGE/bin/retroarch" >> "$OUT/psc-check.txt" 2>&1 || true
[ $gate = 0 ] || { cat "$OUT/psc-check.txt"; exit 1; }
echo "psc-check: retroarch loads on the console with $n compositor package(s)"
cat "$OUT/build-info.txt"
ls -la "$OUT/psc-retroarch.tar.gz"
