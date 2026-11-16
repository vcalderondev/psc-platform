#!/bin/sh
# Build SDL for the PlayStation Classic from upstream sources: SDL3 3.4.20 and
# sdl2-compat 2.32.74 (the SDL2 API on top of SDL3, as current distributions ship SDL2).
# Output: out/sdl/psc-sdl3.tar.gz, laid out as /usr for a frontend's boot script to
# overlay from RAM next to the PSC compositor (nothing on the eMMC changes):
#   lib/libSDL3.so.0            SDL3
#   lib/libSDL2-2.0.so.0        sdl2-compat: replaces the console's SDL 2.0.4 for every
#                               SDL2 program, including the console's SDL2_image/ttf/mixer
#
#   toolchain/psc sh psc-platform/sdl/build.sh   (from the workspace folder)
#
# What it brings over SDL 2.0.4: HIDAPI drivers over hidraw (DualShock 4, DualSense,
# Switch Pro / Joy-Con, Xbox, 8BitDo, Steam: rumble, LEDs, sensors), the current
# controller database, xdg-shell on Weston 16, and ten years of fixes.
# Configured for the console: Wayland + EGL/GLES (no X11, no desktop GL, no Vulkan or SDL
# GPU, the driver has no Vulkan), ALSA, udev, evdev. Every system library is loaded at
# run time (dlopen), so SDL itself only needs glibc; KMSDRM is off (Lumen runs on Weston,
# and the console's Mesa 17 libgbm lacks calls SDL's KMSDRM makes).
# Gate: psc-check of both libraries and of the console's SDL2 users against the console
# with the PSC compositor overlay and this package on /usr, plus every library SDL3
# loads at run time present there.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$HERE")/compositor/common.sh"     # cache, headers, scanner, cross file
OUT="$REPO/out/sdl"; mkdir -p "$OUT"

SDL3=3.4.20; SDL2COMPAT=2.32.74
WAYLAND=1.26.0; PROTOCOLS=1.46       # the compositor's: headers and the scanner only
fetch_sha https://github.com/libsdl-org/SDL/releases/download/release-$SDL3/SDL3-$SDL3.tar.gz SDL3-$SDL3.tar.gz \
  f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f
fetch_sha https://github.com/libsdl-org/sdl2-compat/releases/download/release-$SDL2COMPAT/sdl2-compat-$SDL2COMPAT.tar.gz sdl2-compat-$SDL2COMPAT.tar.gz \
  ec68abde77e2e459c8abc4f9587b8976b5d2a657b2bfda2fb3a079b0f8924588
fetch_sha $GL/wayland/-/releases/$WAYLAND/downloads/wayland-$WAYLAND.tar.xz wayland-$WAYLAND.tar.xz \
  64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3
fetch_sha $GL/wayland-protocols/-/releases/$PROTOCOLS/downloads/wayland-protocols-$PROTOCOLS.tar.xz wayland-protocols-$PROTOCOLS.tar.xz \
  fd0de056a895fa48bd1aa5f0b8dfeed454101b88bc7e1c61a953422eb71db167

console_headers
# ALSA and udev headers of the console's era (SDL loads both at run time)
DEB=https://archive.debian.org/debian/pool/main
for p in a/alsa-lib/libasound2-dev_1.1.3-5_armhf.deb s/systemd/libudev-dev_232-25+deb9u12_armhf.deb; do
  f="$(basename "$p")"; fetch "$DEB/$p" "$f"; dpkg -x "$CACHE/$f" "$SYSROOT"
done
rm -f "$SYSROOT"/usr/lib/arm-linux-gnueabihf/libasound.a
native_scanner wayland-$WAYLAND.tar.xz
cross_file
# Wayland 1.26 headers/pkg-config in the sysroot (the compositor overlay ships the
# libraries; nothing of it goes into this package)
build_wayland $WAYLAND $PROTOCOLS
rm -rf "$STAGE" && mkdir -p "$STAGE"

TC=/opt/psc/psc-toolchain.cmake
CM="cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=$TC -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib"
export PKG_CONFIG=/opt/psc/bin/cw-pkg-config

# ---- SDL3
unpack SDL3-$SDL3.tar.gz sdl3
cd "$B/sdl3"
step sdl3-setup $CM -S . -B build \
   -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_DOCS=OFF \
   -DSDL_X11=OFF -DSDL_WAYLAND=ON -DSDL_WAYLAND_SHARED=ON -DSDL_WAYLAND_LIBDECOR=OFF \
   -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=ON -DSDL_DUMMYVIDEO=ON \
   -DSDL_OPENGL=OFF -DSDL_OPENGLES=ON -DSDL_VULKAN=OFF -DSDL_RENDER_VULKAN=OFF -DSDL_GPU=OFF \
   -DSDL_ALSA=ON -DSDL_ALSA_SHARED=ON -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF \
   -DSDL_DBUS=OFF -DSDL_IBUS=OFF -DSDL_FCITX=OFF -DSDL_LIBURING=OFF -DSDL_CAMERA=OFF \
   -DSDL_LIBUDEV=ON -DSDL_HIDAPI=ON -DSDL_HIDAPI_LIBUSB=OFF -DSDL_HIDAPI_JOYSTICK=ON -DSDL_VIRTUAL_JOYSTICK=ON
step sdl3-build ninja -j4 -C build
step sdl3-install env DESTDIR="$STAGE" ninja -C build install
step sdl3-sysroot env DESTDIR="$SYSROOT" ninja -C build install
grep -E "^ *(Wayland|ALSA|udev|HIDAPI|OpenGL ES|KMSDRM|X11|Vulkan)|SDL_(WAYLAND|ALSA|HIDAPI|LIBUDEV|OPENGLES):" "$B/sdl3-setup.log" > "$OUT/sdl3-config.txt" || true

# ---- sdl2-compat (finds libSDL3.so.0 at run time in /usr/lib)
unpack sdl2-compat-$SDL2COMPAT.tar.gz sdl2compat
cd "$B/sdl2compat"
step sdl2compat-setup $CM -S . -B build -DSDL2COMPAT_TESTS=OFF -DSDL2COMPAT_X11=OFF -DSDL2COMPAT_STATIC=OFF
step sdl2compat-build ninja -j4 -C build
step sdl2compat-install env DESTDIR="$STAGE" ninja -C build install

# ---- package: run-time files only
rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/lib/cmake" "$STAGE/usr/share" "$STAGE/usr/bin"
find "$STAGE" -name '*.a' -delete
find "$STAGE/usr/lib" -type f -exec sh -c 'file "$1" | grep -q ELF && arm-linux-gnueabihf-strip --strip-unneeded "$1"' _ {} \;
tar czf "$OUT/psc-sdl3.tar.gz" -C "$STAGE/usr" .
( cd "$STAGE/usr" && find . | sort ) > "$OUT/psc-sdl3.files"

# ---- gate: the console's root with the compositor overlay and this package on /usr
COMBO=/tmp/sdl-console; rm -rf "$COMBO"; mkdir -p "$COMBO/usr"
ln -s /device/lib "$COMBO/lib"; ln -s /device/usr/local "$COMBO/usr/local"
cp -a /device/usr/lib "$COMBO/usr/lib"
PW="$REPO/out/compositor/psc-weston-16.tar.gz"
[ -f "$PW" ] || { echo "out/compositor/psc-weston-16.tar.gz missing: build the compositor first"; exit 1; }
tar xzf "$PW" -C "$COMBO/usr" ./lib 2>/dev/null || tar xzf "$PW" -C "$COMBO/usr"
cp -a "$STAGE/usr/lib/." "$COMBO/usr/lib/"
CHECK="$STAGE/usr/lib/libSDL3.so.0 $STAGE/usr/lib/libSDL2-2.0.so.0"
for f in libSDL2_image-2.0.so.0 libSDL2_ttf-2.0.so.0 libSDL2_mixer-2.0.so.0; do CHECK="$CHECK /device/usr/lib/$f"; done
[ -f /work/lumen/out/lumen ] && CHECK="$CHECK /work/lumen/out/lumen"
psc-check --device-root "$COMBO" $CHECK > "$OUT/psc-check.txt" 2>&1 || { cat "$OUT/psc-check.txt"; echo "psc-check failed"; exit 1; }
# what SDL3 opens with dlopen (no NEEDED entry, so psc-check cannot see it). SDL3 also
# names optional libraries it only tries (GTK / appindicator for a tray, desktop GL,
# GLES 1): those may be absent. These are the ones the console must have.
missing=""
for l in libEGL.so.1 libGLESv2.so.2 libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1 \
         libxkbcommon.so.0 libasound.so.2 libudev.so.1 libSDL3.so.0; do
  if [ -e "$COMBO/usr/lib/$l" ] || [ -e "$COMBO/lib/$l" ] || [ -e "$COMBO/usr/local/lib/$l" ]; then echo "dlopen ok      $l"
  else echo "dlopen missing $l"; missing="$missing $l"; fi
  # every one of them listed by SDL3 / sdl2-compat really is a name they open
  strings "$STAGE/usr/lib/libSDL3.so.0" "$STAGE/usr/lib/libSDL2-2.0.so.0" | grep -qx "$l" || echo "  (note: $l not named in the libraries)"
done >> "$OUT/psc-check.txt"
grep "^dlopen\|note:" "$OUT/psc-check.txt"
[ -z "$missing" ] || { echo "SDL3 dlopens libraries the console lacks:$missing"; exit 1; }
echo "psc-check: $(grep -c '^\[OK' "$OUT/psc-check.txt") binaries load on the console with the compositor + SDL overlay"
ls -la "$OUT/psc-sdl3.tar.gz"
