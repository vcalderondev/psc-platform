#!/bin/sh
# Build libretro cores for the PlayStation Classic from pinned upstream commits
# (cores/cores.list), with each core's own PSC make target (classic_armv8_a35:
# Cortex-A35 tuning, NEON) where it has one.
#
#   toolchain/psc sh psc-platform/cores/build.sh fceumm      (from the workspace folder)
#   toolchain/psc sh psc-platform/cores/build.sh all
#
# Output: out/cores/<name>_libretro.so, out/cores/<name>.build-info.txt, and the gate
# out/cores/<name>.psc-check.txt: every core must load on the bare console (cores need
# nothing from the compositor; hardware-rendered ones link the console's own libEGL /
# libGLESv2 and get their GLES context from RetroArch).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/out/cores"
CACHE="$OUT/cache"
JOBS="${JOBS:-4}"
mkdir -p "$CACHE"
. /opt/psc/bin/psc-env

build_one() {  # name repo commit dir makefile args...
  name=$1 repo=$2 commit=$3 dir=$4 mk=$5; shift 5
  B=/tmp/core-$name
  tar="$name-$commit.tar.gz"
  echo "== $name ($repo @ ${commit%${commit#???????}})"
  [ -s "$CACHE/$tar" ] || { wget -q -T 30 -t 3 -O "$CACHE/$tar.part" "https://github.com/$repo/archive/$commit.tar.gz" &&
    mv -f "$CACHE/$tar.part" "$CACHE/$tar"; } || { echo "download failed: $repo"; return 1; }
  rm -rf "$B" && mkdir -p "$B" && tar xzf "$CACHE/$tar" -C "$B" --strip-components=1
  for p in "$HERE/patches/$name"/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -d "$B" -p1 < "$p" >/dev/null; }; done
  # the core's Makefile sets its own CFLAGS/LDFLAGS for the target: keep psc-env's out
  # C++ cores: libstdc++ / libgcc linked in statically (the console's libstdc++ is GCC
  # 6's, ours GCC 12's: GLIBCXX_3.4.29 would not resolve). TUNE=psc in the list adds the
  # Cortex-A35 / NEON flags to the compilers, for cores without a PSC make target
# (TUNE=psc-arm: the same in ARM mode, for dynarecs whose assembly is not Thumb-2).
  cc="arm-linux-gnueabihf-gcc"; cxx="arm-linux-gnueabihf-g++ -static-libstdc++ -static-libgcc"
  rest=""; for a in "$@"; do case "$a" in
    TUNE=psc) t="-mcpu=cortex-a35 -mfpu=neon-fp-armv8 -mfloat-abi=hard"; cc="$cc $t"; cxx="$cxx $t" ;;
    TUNE=psc-arm) t="-mcpu=cortex-a35 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm"; cc="$cc $t"; cxx="$cxx $t" ;;
    *) rest="$rest $a" ;; esac; done
  if ! (cd "$B/$dir" && env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -f "$mk" $rest \
        CC="$cc" CXX="$cxx" AR=arm-linux-gnueabihf-ar \
        -j"$JOBS" > "$B/make.log" 2>&1); then
    tail -40 "$B/make.log"; echo "FAILED: $name"; return 1
  fi
  so=$(ls "$B/$dir"/*_libretro.so 2>/dev/null | head -1)
  [ -n "$so" ] || { echo "no *_libretro.so in $B/$dir"; return 1; }
  cp "$so" "$OUT/${name}_libretro.so"
  # KEEP_SYMBOLS=1: the unstripped core next to it (<name>_libretro.unstripped.so), to
  # resolve the addresses of a crash report (tools/debug) or of a debugger; never shipped
  [ -z "$KEEP_SYMBOLS" ] || cp "$so" "$OUT/${name}_libretro.unstripped.so"
  $STRIP "$OUT/${name}_libretro.so"
  { echo "$repo $commit $mk $*"; arm-linux-gnueabihf-readelf -d "$OUT/${name}_libretro.so" | grep NEEDED; } > "$OUT/$name.build-info.txt"
  psc-check "$OUT/${name}_libretro.so" > "$OUT/$name.psc-check.txt" 2>&1 || { cat "$OUT/$name.psc-check.txt"; echo "FAILED gate: $name"; return 1; }
  echo "ok $name: $(ls -la "$OUT/${name}_libretro.so" | awk '{print $5}') bytes"
}

want=${1:-all}; found=0; failed=""
while read -r name repo commit dir mk args; do
  case "$name" in ''|'#'*) continue ;; esac
  [ "$want" = all ] || [ "$want" = "$name" ] || continue
  found=1
  build_one "$name" "$repo" "$commit" "$dir" "$mk" $args || failed="$failed $name"
done < "$HERE/cores.list"
[ $found = 1 ] || { echo "unknown core: $want (see cores/cores.list)"; exit 2; }
[ -z "$failed" ] || { echo "failed:$failed"; exit 1; }
