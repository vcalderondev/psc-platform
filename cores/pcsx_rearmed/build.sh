#!/bin/sh
# Build the PCSX-ReARMed libretro core for the PlayStation Classic from upstream
# libretro/pcsx_rearmed (pinned commit), with upstream's own PSC target
# platform=classic_armv8_a35: Cortex-A35 tuning, ARM NEON GPU plugin (gpu_neon, the
# one with the 2x "enhanced resolution" mode), ari64 dynarec, NEON SPU/GTE assembly.
#
#   toolchain/psc sh psc-platform/cores/pcsx_rearmed/build.sh   (from the workspace folder)
#
# Output: out/cores/pcsx_rearmed_libretro.so (+ psc-check.txt, build-info.txt).
# The core options keep the names Lumen's graphics presets use
# (pcsx_rearmed_neon_enhancement_enable / _no_main); its RetroArch name is "PCSX-ReARMed".
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/out/cores"
CACHE="$OUT/cache"
B=/tmp/pcsx-build
JOBS="${JOBS:-4}"
mkdir -p "$CACHE" "$B"
. /opt/psc/bin/psc-env

COMMIT=7b0e8f8fadfbce3d170d195b9d9eecaabfa08c8e   # libretro/pcsx_rearmed master, 2026-10-29
TAR="pcsx_rearmed-$COMMIT.tar.gz"
[ -s "$CACHE/$TAR" ] || { wget -q -T 30 -t 3 -O "$CACHE/$TAR.part" "https://github.com/libretro/pcsx_rearmed/archive/$COMMIT.tar.gz" &&
  mv -f "$CACHE/$TAR.part" "$CACHE/$TAR"; } || { echo "download failed"; exit 1; }
rm -rf "$B/src" && mkdir -p "$B/src" && tar xzf "$CACHE/$TAR" -C "$B/src" --strip-components=1
for p in "$HERE"/patches/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -d "$B/src" -p1 < "$p" >/dev/null; }; done
cd "$B/src"
# CFLAGS/LDFLAGS from psc-env would replace the platform's own: let the Makefile set them.
# The classic_armv8_a35 target sets USE_LIBRETRO_VFS=0 but the physical-CD code still
# calls libretro-common's file streams (unresolved symbols, caught by psc-check):
# build with the frontend VFS (as the generic unix target does) and no physical CD.
if ! env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -f Makefile.libretro platform=classic_armv8_a35 USE_LIBRETRO_VFS=1 HAVE_PHYSICAL_CDROM=0 \
      CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ AR=arm-linux-gnueabihf-ar \
      -j"$JOBS" > "$B/make.log" 2>&1; then
  tail -40 "$B/make.log"; exit 1
fi
mkdir -p "$OUT"
cp pcsx_rearmed_libretro.so "$OUT/pcsx_rearmed_libretro.so"
$STRIP "$OUT/pcsx_rearmed_libretro.so"
{ echo "libretro/pcsx_rearmed $COMMIT platform=classic_armv8_a35 USE_LIBRETRO_VFS=1 HAVE_PHYSICAL_CDROM=0"
  grep -aoE 'gpu_neon|new_dynarec|ari64' "$OUT/pcsx_rearmed_libretro.so" | sort -u | tr '\n' ' '; echo
  arm-linux-gnueabihf-readelf -d "$OUT/pcsx_rearmed_libretro.so" | grep NEEDED; } > "$OUT/build-info.txt"
# gate: the core must load on the bare console (it needs nothing from the compositor)
psc-check "$OUT/pcsx_rearmed_libretro.so" > "$OUT/psc-check.txt" 2>&1 || { cat "$OUT/psc-check.txt"; exit 1; }
# the presets' option names must still exist in this version
for k in pcsx_rearmed_neon_enhancement_enable pcsx_rearmed_neon_enhancement_no_main; do
  grep -q "\"$k\"" frontend/libretro_core_options.h || { echo "core option $k no longer exists"; exit 1; }
done
grep -q 'library_name *= "PCSX-ReARMed"' frontend/libretro.c || { echo "library name changed (Lumen's core_options_name)"; exit 1; }
cat "$OUT/psc-check.txt" "$OUT/build-info.txt"
ls -la "$OUT/pcsx_rearmed_libretro.so"
