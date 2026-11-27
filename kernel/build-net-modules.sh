#!/bin/sh
# Wi-Fi, Bluetooth and USB Ethernet as loadable modules for the PlayStation Classic's STOCK
# Sony kernel (4.4.22), loaded from RAM like overlay.ko / xpad.ko (psc-netmod-stock.tar.gz).
#
# Three sources, one tree, the same checks:
#   - the kernel's own drivers (the options below);
#   - backport/: newer driver sources copied over the tree first (Linux 5.10's btrtl: the
#     Realtek Bluetooth chips 4.4 does not tell apart, see backport/README.md);
#   - ext-drivers.txt: out-of-tree USB Wi-Fi drivers (Realtek 8821CU, 88x2BU, 8812AU, 8821AU),
#     8192EU), pinned by commit + sha256, built with M= against the same configured tree.
#
#   sh psc-platform/kernel/build-net-modules.sh    (after build-modules.sh: same image + source)
#   CHECK_ONLY=1 ... re-runs only the checks
#
# Same pinned source, toolchain and flags as build-modules.sh. Sony's defconfig plus the
# options below as =m (bool sub-options as =y, they only end up inside those modules).
# Left out: r8188eu (staging: it selects WIRELESS_EXT, which adds two fields to struct
# net_device, before netdev_ops. The stock kernel is built without it, so EVERY network module
# of a build with it writes netdev_ops 8 bytes off and the console freezes when a network
# device registers: that was the 8821cu freeze); ath9k_htc (its common part needs relay,
# built-in only and off in the stock kernel); rtl8192cu (rtl8xxxu drives the same chips); zd1211rw (no firmware in
# linux-firmware). Not possible from RAM: backports (it needs cfg80211 as a module; the stock
# kernel has it built in, so its cfg80211.ko would clash with the kernel's).
# Checks, against the stock kernel in LRECOVERY.EPB / PSC_STOCK_BOOTIMG:
#   - config: no option outside these modules changes the built-in kernel
#   - vermagic "4.4.22 SMP preempt ARMv7 p2v8", no GOT references
#   - every undefined symbol of a module is exported by the stock kernel or by another
#     module of this set (then it must be loaded first: the load order is printed)
# Output: out/kernel-net/{modules/*.ko,config.diff,check.txt,load-order.txt,psc-netmod-stock.tar.gz}
# The package also carries depends.txt ("module: dep,dep") and aliases.txt ("module usb:v...p..."
# modalias globs): a frontend loads only the driver of the adapter that is plugged in.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WS="${PSC_WORKSPACE:-$(dirname "$REPO")}"
SRC_DIR="$REPO/out/kernel"
OUT="$REPO/out/kernel-net"
IMAGE=psc-kernel-build:stretch
JOBS="${JOBS:-4}"
TGZ=$(ls "$SRC_DIR"/cache/linux-sony-psclassic-*.tar.gz 2>/dev/null | head -1)
[ -s "$TGZ" ] && docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "run build-modules.sh first (source + image)"; exit 2; }
mkdir -p "$OUT/modules" "$OUT/cache"

# out-of-tree drivers: fetched here (the build container has no network), checked by sha256
EXT_LIST="$HERE/ext-drivers.txt"
grep -v '^#' "$EXT_LIST" | while read -r name mod repo commit sha; do
  [ -n "$name" ] || continue
  f="$OUT/cache/$name-$(echo "$commit" | cut -c1-12).tar.gz"
  [ -s "$f" ] || curl -fsSL --max-time 600 -o "$f.part" "https://github.com/$repo/archive/$commit.tar.gz" && [ -s "$f.part" ] && mv -f "$f.part" "$f"
  echo "$sha  $f" | sha256sum -c --quiet - 2>/dev/null || echo "$sha  $f" | shasum -a 256 -c --quiet - || { echo "checksum mismatch: $f"; exit 1; }
done

# --module NAME (tristate) / --enable NAME (bool inside one of those modules)
OPTS="
--module MAC80211 --enable MAC80211_RC_MINSTREL --enable MAC80211_RC_MINSTREL_HT
--enable WL_MEDIATEK --module MT7601U
--module RTL8XXXU --enable RTL8XXXU_UNTESTED
--module RT2X00 --module RT2800USB --enable RT2800USB_RT33XX --enable RT2800USB_RT35XX
  --enable RT2800USB_RT3573 --enable RT2800USB_RT53XX --enable RT2800USB_RT55XX
  --enable RT2800USB_UNKNOWN --module RT2500USB --module RT73USB
--enable ATH_CARDS --module CARL9170 --module AR5523
--module BT --enable BT_BREDR --enable BT_LE --module BT_HIDP
--module BT_HCIBTUSB --enable BT_HCIBTUSB_BCM --enable BT_HCIBTUSB_RTL --module BT_ATH3K
--module USB_USBNET --module USB_NET_CDCETHER --module USB_NET_CDC_NCM
--module USB_NET_AX8817X --module USB_NET_AX88179_178A --module USB_RTL8152
--module USB_NET_SMSC95XX
"

if [ -z "$CHECK_ONLY" ]; then
echo "== build (make -j$JOBS, about 10 minutes)"
docker run --rm --network none -v "$TGZ":/src.tgz:ro -v "$OUT":/out -v "$HERE/backport":/backport:ro \
  -v "$EXT_LIST":/ext-drivers.txt:ro -e JOBS="$JOBS" -e OPTS="$OPTS" "$IMAGE" sh -ec '
  mkdir -p /b /o && cd /b && tar xzf /src.tgz --strip-components=1
  cp /backport/bluetooth/* drivers/bluetooth/   # newer driver sources (backport/README.md)
  # the DualSense with the standard gamepad layout (backport/hid/hid-dualsense.c)
  cp /backport/hid/*.c drivers/hid/ && echo "obj-m += hid-dualsense.o" >> drivers/hid/Makefile
  M="make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- HOSTCFLAGS=-fcommon O=/o KCFLAGS=-fno-PIE KAFLAGS=-fno-PIE"
  $M aiv8167_rockman_emmc_defconfig > /out/build.log 2>&1
  cp /o/.config /out/config.stock
  scripts/config --file /o/.config $OPTS
  $M olddefconfig >> /out/build.log 2>&1
  cp /o/.config /out/config.net
  diff /out/config.stock /out/config.net > /out/config.diff || true
  # any option that is =y now and was not before, and is not one we asked for, would
  # change the built-in kernel: list it (it must be a bool that lives inside a module)
  asked=$(echo $OPTS | tr " " "\n" | grep -v "^--" | sort -u)
  grep "^> CONFIG_.*=y$" /out/config.diff | sed "s/^> CONFIG_//; s/=y$//" | sort -u \
    | grep -vxF "$asked" > /out/config.new-y || true
  # ... and none of them may be read by a header the built-in kernel shares with the
  # modules: such an option changes a struct both sides use (WIRELESS_EXT -> struct
  # net_device). Headers that only this set of modules includes are left out.
  : > /out/config.abi
  for o in $(cat /out/config.new-y); do
    grep -rlw "CONFIG_$o" include/ arch/arm/include/ 2>/dev/null \
      | grep -vE "^include/net/(bluetooth/|mac80211\.h|ieee80211_radiotap\.h)|^include/linux/(usb/usbnet\.h|rtnetlink\.h$)" \
      | sed "s|^|$o: |" >> /out/config.abi || true
  done
  if [ -s /out/config.abi ]; then
    echo "FAIL: options that change headers shared with the stock kernel:"; cat /out/config.abi; exit 1
  fi
  $M -j"$JOBS" Image modules >> /out/build.log 2>&1 || { tail -60 /out/build.log; exit 1; }
  rm -f /out/modules/*.ko /out/modules/*.undef
  find /o -name "*.ko" -exec cp {} /out/modules/ \;
  # out-of-tree Wi-Fi drivers, against the same configured tree (M=), same flags
  grep -v "^#" /ext-drivers.txt | while read -r name mod repo commit sha; do
    [ -n "$name" ] || continue
    rm -rf /ext/$name && mkdir -p /ext/$name
    tar xzf /out/cache/$name-$(echo $commit | cut -c1-12).tar.gz -C /ext/$name --strip-components=1
    echo "== $name" >> /out/build.log
    $M -j"$JOBS" M=/ext/$name CONFIG_RTL8821CU=m CONFIG_RTL8822BU=m CONFIG_RTL8812AU=m CONFIG_RTL8821AU=m modules >> /out/build.log 2>&1 \
      || { echo "== $name failed"; tail -40 /out/build.log; exit 1; }
    cp /ext/$name/$mod.ko /out/modules/
  done
  arm-linux-gnueabihf-strip --strip-debug /out/modules/*.ko
  cp /o/Module.symvers /out/
  cp /o/arch/arm/boot/Image /out/Image.built
  for k in /out/modules/*.ko; do arm-linux-gnueabihf-nm -u $k | awk "{print \$2}" | sort -u > $k.undef; done
  for k in /out/modules/*.ko; do echo "$(basename $k .ko): $(modinfo -F depends $k)"; done | sort > /out/depends.txt
  # which USB devices each driver takes: "<module> <modalias glob>" (a frontend loads only the
  # driver of the adapter that is plugged in, matching /sys/bus/usb/devices/*/modalias)
  for k in /out/modules/*.ko; do modinfo -F alias $k | grep "^usb:" | sed "s/^/$(basename $k .ko) /"; done > /out/aliases.txt
'
fi   # CHECK_ONLY=1: re-run the checks on the last build

echo "== check against the console's stock kernel"
if [ -n "$PSC_STOCK_BOOTIMG" ]; then STOCK="$PSC_STOCK_BOOTIMG"; KIND=img
else STOCK="${PSC_STOCK_EPB:-$(ls "$WS"/usb-backup/*/project_eris/backup/LRECOVERY.EPB 2>/dev/null | tail -1)}"; KIND=epb; fi
[ -f "$STOCK" ] || { echo "no stock kernel: set PSC_STOCK_BOOTIMG or PSC_STOCK_EPB"; exit 2; }
docker run --rm --network none -v "$OUT":/out -v "$STOCK":/stock-src:ro -e KIND="$KIND" "$IMAGE" sh -c '
set -e; cd /tmp
if [ "$KIND" = epb ]; then
  python3 -c "import zipfile; open(\"boot.img\",\"wb\").write(zipfile.ZipFile(\"/stock-src\").read(\"boot.img\"))"
else cp /stock-src boot.img; fi
[ "$(md5sum < boot.img | cut -d" " -f1)" = 28ce5f6de4981764411393310311b517 ] || { echo "FAIL not the stock Sony kernel"; exit 1; }
dumpimage -T flat_dt -p 0 -o k.lz4 boot.img >/dev/null 2>&1 || true
{ lz4 -dcf k.lz4 > stock.Image 2>/dev/null || [ -s stock.Image ]; }
strings -n 2 stock.Image > stock.all
fail=0
echo "built-in options turned on besides the requested ones (each must live in a module):"
if [ -s /out/config.new-y ]; then sed "s/^/  /" /out/config.new-y; else echo "  none"; fi
# the built-in kernel must export nothing the stock one lacks (else a select changed it)
awk "\$3 == \"vmlinux\" {print \$2}" /out/Module.symvers | sort -u > built.exports
n_miss=$(grep -vxFf stock.all built.exports | wc -l)
echo "built-in kernel: $(wc -l < built.exports) exports, $n_miss missing in stock"
grep -vxFf stock.all built.exports | head -20 | sed "s/^/  missing-in-stock| /"
[ "$n_miss" = 0 ] || fail=1
# exports of the modules of this set (name module)
awk "\$3 != \"vmlinux\" {n=\$3; sub(\".*/\",\"\",n); print \$2, n}" /out/Module.symvers | sort -u > mod.exports
SV="4.4.22 SMP preempt ARMv7 p2v8"
for k in /out/modules/*.ko; do
  n=$(basename $k .ko); bad=0
  vm=$(modinfo -F vermagic $k | sed "s/ *$//"); [ "$vm" = "$SV" ] || { echo "FAIL $n vermagic \"$vm\""; bad=1; }
  arm-linux-gnueabihf-nm -u $k | grep -q _GLOBAL_OFFSET_TABLE_ && { echo "FAIL $n GOT references"; bad=1; }
  from_mods=0
  for s in $(cat $k.undef); do
    if grep -qx "$s" stock.all; then :
    elif grep -q "^$s " mod.exports; then from_mods=$((from_mods+1))
    else echo "  FAIL $n needs $s: neither the stock kernel nor this set exports it"; bad=1; fi
  done
  [ $bad = 0 ] && echo "ok   $n ($(wc -l < $k.undef) symbols, $from_mods from other modules; $(wc -c < $k) bytes)" || fail=1
done
(cd /out/modules && sha256sum *.ko > SHA256SUMS)
[ $fail = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
' 2>&1 | tee "$OUT/check.txt"

# load order: a module after everything it depends on (modinfo depends)
python3 - "$OUT/depends.txt" > "$OUT/load-order.txt" <<'EOF'
import sys
deps = {}
for line in open(sys.argv[1]):
    name, _, d = line.strip().partition(":")
    deps[name] = [x.strip() for x in d.split(",") if x.strip()]
done, order = set(), []
def visit(n):
    if n in done: return
    done.add(n)
    for d in deps.get(n, []): visit(d)
    order.append(n)
for n in sorted(deps): visit(n)
print("\n".join(order))
EOF
echo "== load order: $OUT/load-order.txt"
grep -q "^ALL OK" "$OUT/check.txt"
# package for the frontend: modules + load order + checksums, for this kernel build only
# (the frontend loads them only when uname -v is the stock build and the feature is missing)
P="$(mktemp -d)"; mkdir -p "$P/netmod"
cp "$OUT"/modules/*.ko "$OUT/modules/SHA256SUMS" "$OUT/load-order.txt" "$OUT/depends.txt" "$OUT/aliases.txt" "$P/netmod/"
echo "#1 SMP PREEMPT Sun Sep 9 15:21:14 UTC 2018" > "$P/netmod/KERNEL"   # uname -v of the stock build
tar czf "$OUT/psc-netmod-stock.tar.gz" -C "$P" netmod; rm -rf "$P"
ls -la "$OUT/psc-netmod-stock.tar.gz"
