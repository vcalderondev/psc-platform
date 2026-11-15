#!/bin/sh
# Build the PPSSPP libretro core (PSP) for the PlayStation Classic from upstream
# hrydgard/ppsspp (pinned release tag), hardware rendered: OpenGL ES 3 through
# RetroArch's gl driver (the console's PowerVR GE8300, GLES 3.2), ARM32 JIT, no Vulkan
# (the console has no Vulkan driver), bundled FFmpeg (PSP video / audio).
#
#   toolchain/psc sh psc-platform/cores/ppsspp/build.sh   (from the workspace folder)
#
# Output (out/cores/):
#   ppsspp_libretro.so, ppsspp.build-info.txt, ppsspp.psc-check.txt (the gate)
#   ppsspp-assets.tar.gz   PPSSPP/ (fonts, atlas, compat.ini, shaders...): the core reads
#                          them from <RetroArch system_directory>/PPSSPP/
#
# Upstream's own source tarball has no submodules, so the source is a shallow git checkout
# of the tag with the submodules the libretro build uses (and theirs, e.g. armips'
# ext/filesystem), cached as one tarball.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/out/cores"
CACHE="$OUT/cache"
B=/tmp/ppsspp-build
JOBS="${JOBS:-4}"
mkdir -p "$CACHE" "$B"
. /opt/psc/bin/psc-env

TAG=v1.20.4
COMMIT=fa50bb1976065c4f8b1b47af227d367fe9771555   # hrydgard/ppsspp v1.20.4, 2026-05-16
# submodules the libretro core builds from (not: tests, debugger UI, MoltenVK,
# adrenotools, discord-rpc, SDL/macOS; OpenXR-SDK only for its headers, which
# Common/VR/OpenXRLoader.cpp includes on every platform)
SUBMODULES="ffmpeg libretro/libretro-common ext/armips ext/glslang ext/SPIRV-Cross
  ext/rapidjson ext/miniupnp ext/zstd ext/cpu_features ext/rcheevos ext/naett
  ext/libchdr ext/lua ext/freetype ext/nanosvg ext/aemu_postoffice ext/OpenXR-SDK"
TAR="ppsspp-$TAG-$COMMIT-src.tar.gz"

if [ ! -s "$CACHE/$TAR" ]; then
  G="$B/git"; rm -rf "$G" && mkdir -p "$G"
  ( cd "$G" && git init -q && git remote add origin https://github.com/hrydgard/ppsspp.git &&
    git fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" && git checkout -q "$TAG" &&
    [ "$(git rev-parse HEAD)" = "$COMMIT" ] &&
    git -c protocol.file.allow=never submodule update -q --init --recursive --depth 1 --recommend-shallow -- $SUBMODULES ) ||
    { echo "checkout failed: ppsspp $TAG ($COMMIT)"; exit 1; }
  tar czf "$CACHE/$TAR.part" --exclude=.git -C "$G" . && mv -f "$CACHE/$TAR.part" "$CACHE/$TAR"
  rm -rf "$G"
fi
rm -rf "$B/src" "$B/build" && mkdir -p "$B/src" "$B/build" && tar xzf "$CACHE/$TAR" -C "$B/src"
for p in "$HERE"/patches/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -d "$B/src" -p1 < "$p" >/dev/null; }; done

# CMAKE_SYSTEM_PROCESSOR armv7l (toolchain file): ARMV7 -> ARM32 JIT, NEON, FFmpeg's
# linux/armv7 prebuilt libraries. ARM_NO_VULKAN: no Vulkan backend. Bundled libpng /
# zstd / freetype / libchdr (the console has libpng16 and zlib only; zlib is used).
# No libatomic (patches/0001: the console has none, ARMv7 does 64-bit atomics inline).
# CMAKE_SHARED_LINKER_FLAGS replaces the toolchain file's: keep the static C++ runtime.
# psc-compat.o: fcntl64 for the prebuilt FFmpeg (glibc 2.28), see psc-compat.c
arm-linux-gnueabihf-gcc $PSC_FLAGS -O2 -fPIC -c "$HERE/psc-compat.c" -o "$B/psc-compat.o"
cd "$B/build"
if ! env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake "$B/src" -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=/opt/psc/psc-toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,--as-needed $B/psc-compat.o" -DNO_LIBATOMIC=ON \
      -DLIBRETRO=ON -DUSING_GLES2=ON -DUSING_EGL=ON -DARM_NO_VULKAN=ON -DUSING_X11_VULKAN=OFF \
      -DUSE_FFMPEG=ON -DUSE_SYSTEM_FFMPEG=OFF -DUSE_DISCORD=OFF -DUSE_MINIUPNPC=OFF \
      -DUSE_SYSTEM_LIBPNG=OFF -DUSE_SYSTEM_ZSTD=OFF -DUSE_SYSTEM_FREETYPE=OFF -DUSE_SYSTEM_LIBCHDR=OFF \
      -DUSE_CCACHE=OFF -DHEADLESS=OFF -DUNITTEST=OFF -DATLAS_TOOL=OFF \
      > "$B/cmake.log" 2>&1; then
  tail -40 "$B/cmake.log"; echo "FAILED: ppsspp (cmake)"; exit 1
fi
grep -E "Generating for|ARM_DEVICE|Vulkan|FFMPEG" "$B/cmake.log" || true
if ! ninja -j"$JOBS" ppsspp_libretro > "$B/make.log" 2>&1; then
  grep -E "error|Error" "$B/make.log" | head -20; tail -30 "$B/make.log"; echo "FAILED: ppsspp"; exit 1
fi
so=$(find "$B/build" -name ppsspp_libretro.so | head -1)
[ -n "$so" ] || { echo "no ppsspp_libretro.so"; exit 1; }
mkdir -p "$OUT"
cp "$so" "$OUT/ppsspp_libretro.so"
$STRIP "$OUT/ppsspp_libretro.so"
{ echo "hrydgard/ppsspp $TAG $COMMIT LIBRETRO=ON USING_GLES2 ARMV7 ARM_NO_VULKAN FFMPEG(bundled linux/armv7)"
  arm-linux-gnueabihf-readelf -d "$OUT/ppsspp_libretro.so" | grep NEEDED; } > "$OUT/ppsspp.build-info.txt"

# gate: loads on the bare console; no Vulkan loader linked; still the GLES build
psc-check "$OUT/ppsspp_libretro.so" > "$OUT/ppsspp.psc-check.txt" 2>&1 || { cat "$OUT/ppsspp.psc-check.txt"; echo "FAILED gate: ppsspp"; exit 1; }
! arm-linux-gnueabihf-readelf -d "$OUT/ppsspp_libretro.so" | grep -q 'libvulkan' || { echo "links libvulkan"; exit 1; }
grep -q 'USING_GLES2' "$B/build/build.ninja" || { echo "not a GLES build"; exit 1; }
grep -q 'library_name *= "PPSSPP"' "$B/src/libretro/libretro.cpp" || { echo "library name changed (core options folder)"; exit 1; }

# assets: <system_directory>/PPSSPP/ on the console
rm -rf "$B/assets" && mkdir -p "$B/assets/PPSSPP"
cp -a "$B/src/assets/." "$B/assets/PPSSPP/"
rm -rf "$B/assets/PPSSPP/debugger"   # the web debugger UI (submodule, not fetched)
tar czf "$OUT/ppsspp-assets.tar.gz" -C "$B/assets" PPSSPP
echo "assets: $(du -sh "$B/assets/PPSSPP" | cut -f1) -> ppsspp-assets.tar.gz" >> "$OUT/ppsspp.build-info.txt"
cat "$OUT/ppsspp.psc-check.txt" "$OUT/ppsspp.build-info.txt"
ls -la "$OUT/ppsspp_libretro.so" "$OUT/ppsspp-assets.tar.gz"
