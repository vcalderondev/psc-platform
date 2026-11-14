#!/bin/sh
# Build the PSC debug helpers:   toolchain/psc sh psc-platform/tools/debug/build.sh
#   out/debug/psc-crash.so   LD_PRELOAD crash reporter (psc-crash.c)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/../.." && pwd)/out/debug"
mkdir -p "$OUT"
. /opt/psc/bin/psc-env
$CC $PSC_FLAGS -O1 -fPIC -shared -Wall -o "$OUT/psc-crash.so" "$HERE/psc-crash.c"
$STRIP "$OUT/psc-crash.so"
psc-check "$OUT/psc-crash.so"
