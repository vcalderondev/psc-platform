#!/bin/sh
# Build lumen-splash (the boot splash viewer of Lumen's payload) for the console.
#
#   toolchain/psc sh psc-platform/boot/splash/build.sh   (from the workspace folder)
#
# Output: out/boot/lumen-splash (ARM, links only libSDL2-2.0.so.0 + libc/libdl of the
# console), out/boot/lumen-splash.check.txt (psc-check against the console's rootfs).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$HERE")")"
OUT="$REPO/out/boot"
mkdir -p "$OUT"
. /opt/psc/bin/psc-env
SYSROOT=/opt/psc/sysroot
# -Wl,--as-needed: no libSDL2 deps beyond what the console has; SDL2_image is dlopen'ed
$CC $CFLAGS -O2 -Wall -Wextra -std=gnu99 -I"$SYSROOT/usr/include" \
  -o "$OUT/lumen-splash" "$HERE/lumen-splash.c" \
  -Wl,--as-needed -lSDL2 -ldl
$STRIP "$OUT/lumen-splash"
arm-linux-gnueabihf-readelf -d "$OUT/lumen-splash" | grep NEEDED
if command -v psc-check >/dev/null 2>&1 && [ -d /device ]; then
  psc-check "$OUT/lumen-splash" > "$OUT/lumen-splash.check.txt" 2>&1 && echo "psc-check: OK" ||
    { cat "$OUT/lumen-splash.check.txt"; echo "psc-check: FAILED"; exit 1; }
fi
