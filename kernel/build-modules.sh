#!/bin/sh
# Build loadable modules for the PlayStation Classic's STOCK Sony kernel (Linux 4.4.22,
# "4.4.22 SMP preempt ARMv7 p2v8"), so features the stock kernel lacks can be loaded from
# RAM at boot without flashing anything:
#   overlay.ko  overlayfs (Lumen's PSC compositor overlays /usr)
#   xpad.ko     Xbox / Xbox 360 pads
#
#   sh psc-platform/kernel/build-modules.sh     (from the workspace folder, docker needed)
#
# Source: Sony's GPL kernel tarball, as imported in lscorcia/linux-sony-psclassic (private
# mirror: vcalderondev/psc-kernel), pinned by commit + sha256 below. Config: Sony's own
# arch/arm/configs/aiv8167_rockman_emmc_defconfig with ONLY those two options set to =m.
# The whole kernel is built too (vmlinux/Image), for two checks:
#   - provenance: the built Image must match the console's stock kernel (banner fields,
#     exported symbols) -> the source + defconfig really are what Sony shipped
#   - modpost: every symbol the modules need is exported by that kernel
# Compiler: GCC 6.3 (Debian stretch cross), Sony built with 6.2.
#
# Output: out/kernel/modules/{overlay.ko,xpad.ko,SHA256SUMS,check.txt}, out/kernel/build.log
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WS="${PSC_WORKSPACE:-$(dirname "$REPO")}"
OUT="$REPO/out/kernel"
CACHE="$OUT/cache"
IMAGE=psc-kernel-build:stretch
SRC_COMMIT=d716d7e29e0bf25569e20093d5260c13f618aaf1
SRC_SHA256=a20710da22c04bb25af344be2e3c8849b4a38c67de6bba75c910027dcd22b84d
SRC_TGZ="$CACHE/linux-sony-psclassic-$SRC_COMMIT.tar.gz"
JOBS="${JOBS:-4}"
mkdir -p "$CACHE" "$OUT/modules"

if [ ! -s "$SRC_TGZ" ]; then
  echo "== download source $SRC_COMMIT"
  curl -fsSL --max-time 1800 -o "$SRC_TGZ.part" \
    "https://codeload.github.com/lscorcia/linux-sony-psclassic/tar.gz/$SRC_COMMIT" && mv "$SRC_TGZ.part" "$SRC_TGZ"
fi
echo "$SRC_SHA256  $SRC_TGZ" | shasum -a 256 -c - >/dev/null || { echo "source sha256 mismatch"; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== build image $IMAGE"
  CTX="$OUT/ctx"; rm -rf "$CTX"; mkdir -p "$CTX/ca"
  cp "$HERE/docker/Dockerfile" "$CTX/"
  [ -s "$REPO/toolchain/host-ca.pem" ] && cp "$REPO/toolchain/host-ca.pem" "$CTX/ca/"
  docker build -q -t "$IMAGE" "$CTX" >/dev/null; rm -rf "$CTX"
fi

echo "== build (make -j$JOBS, a few minutes)"
docker run --rm --network none -v "$OUT":/out -e JOBS="$JOBS" "$IMAGE" sh -ec '
  mkdir -p /b && cd /b && tar xzf /out/cache/linux-sony-psclassic-*.tar.gz --strip-components=1
  # O=: Sony/Yocto build out of tree, and some MediaTek includes only resolve that way
  # (kbuild then adds -I$(src)). -fcommon: the 4.4 host tools (dtc) under host GCC 12.
  mkdir -p /o
  # -fno-PIE: Debian GCC 6 produces PIE by default and Linux 4.4 predates the kbuild fix
  # (4.9 "kbuild: add -fno-PIE"); without it modules reference _GLOBAL_OFFSET_TABLE_ and
  # the kernel refuses them ("Unknown symbol"). Sony and Eris builds have no GOT refs.
  M="make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- HOSTCFLAGS=-fcommon O=/o KCFLAGS=-fno-PIE KAFLAGS=-fno-PIE"
  $M aiv8167_rockman_emmc_defconfig > /out/build.log 2>&1
  cp /o/.config /out/config.stock
  scripts/config --file /o/.config --module OVERLAY_FS --module JOYSTICK_XPAD
  $M olddefconfig >> /out/build.log 2>&1
  cp /o/.config /out/config.modules
  # only the two module lines may differ from the stock config
  diff /out/config.stock /out/config.modules > /out/config.diff || true
  $M -j"$JOBS" Image modules >> /out/build.log 2>&1 || { tail -60 /out/build.log; exit 1; }
  rm -f /out/modules/*.ko
  cp /o/fs/overlayfs/overlay.ko /o/drivers/input/joystick/xpad.ko /out/modules/
  arm-linux-gnueabihf-strip --strip-debug /out/modules/*.ko
  cp /o/arch/arm/boot/Image /out/Image.built
  cp /o/Module.symvers /o/System.map /out/
  include_rel=$(cat /o/include/config/kernel.release); echo "$include_rel" > /out/kernel.release
  for k in /out/modules/*.ko; do
    echo "## $(basename $k)"; modinfo $k | grep -E "^(vermagic|depends|intree|name|license)"
    echo "undefined:"; arm-linux-gnueabihf-nm -u $k | awk "{print \$2}" | sort -u > $k.undef; wc -l < $k.undef
  done > /out/modules/modinfo.txt
'
echo "== check against the console's stock kernel"
sh "$HERE/check-modules.sh"
