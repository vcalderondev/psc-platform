#!/bin/sh
# Check the modules from build-modules.sh against the console's STOCK kernel image
# (Sony's boot.img, taken from the recovery backup LRECOVERY.EPB = BOOTIMG2), offline.
#
#   sh psc-platform/kernel/check-modules.sh
#
# 1. provenance: the kernel built from the pinned source + Sony defconfig is compared
#    with the stock Image (unique strings: kernel messages, symbol names, ...). They
#    should only differ in build-specific strings (banner, compile paths).
# 2. vermagic of every .ko == the stock kernel's "4.4.22 SMP preempt ARMv7 p2v8".
# 3. every undefined symbol of every .ko is an exported symbol of the stock kernel
#    (its name is in the stock Image's __ksymtab_strings).
# Output: out/kernel/modules/check.txt (exit 1 on any failure)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WS="${PSC_WORKSPACE:-$(dirname "$REPO")}"
OUT="$REPO/out/kernel"
EPB="${PSC_STOCK_EPB:-$(ls "$WS"/usb-backup/*/project_eris/backup/LRECOVERY.EPB 2>/dev/null | tail -1)}"
[ -f "$EPB" ] || { echo "no LRECOVERY.EPB (set PSC_STOCK_EPB)"; exit 2; }
[ -f "$OUT/Image.built" ] || { echo "run build-modules.sh first"; exit 2; }
docker run --rm --network none -v "$OUT":/out -v "$(dirname "$EPB")":/epb:ro psc-kernel-build:stretch sh -c '
set -e
cd /tmp
python3 -c "import zipfile; open(\"boot.img\",\"wb\").write(zipfile.ZipFile(\"/epb/LRECOVERY.EPB\").read(\"boot.img\"))"
echo "stock boot.img md5: $(md5sum < boot.img | cut -d" " -f1) (expect 28ce5f6de4981764411393310311b517)"
dumpimage -T flat_dt -p 0 -o k.lz4 boot.img >/dev/null 2>&1 || true; [ -s k.lz4 ] || { echo "FAIL cannot extract the stock kernel"; exit 1; }; { lz4 -dcf k.lz4 > stock.Image 2>/dev/null || [ -s stock.Image ]; }  # legacy lz4 frame: exit 1 at the end, output complete
strings -n 8 stock.Image | sort -u > stock.u; strings -n 8 /out/Image.built | sort -u > built.u
echo "stock: $(strings stock.Image | grep -m1 "^Linux version")"
echo "built: $(strings /out/Image.built | grep -m1 "^Linux version")"
only_stock=$(comm -23 stock.u built.u | wc -l); only_built=$(comm -13 stock.u built.u | wc -l); both=$(comm -12 stock.u built.u | wc -l)
echo "provenance: unique strings shared=$both only-stock=$only_stock only-built=$only_built"
# exported symbols: every EXPORT_SYMBOL of the built kernel must be in the stock image
# (__ksymtab_strings keeps the names as plain strings); a different source or config
# shows up as missing exports
strings -n 2 stock.Image > stock.all
awk "\$3 == \"vmlinux\" {print \$2}" /out/Module.symvers | sort -u > built.exports
n_exp=$(wc -l < built.exports); n_miss=$(grep -vxFf stock.all built.exports | wc -l)
echo "provenance: built kernel exports $n_exp symbols, $n_miss of them missing in the stock image"
grep -vxFf stock.all built.exports | head -20 | sed "s/^/  missing-in-stock| /"
for m in "kernel messages" ; do :; done
msg_b=$(grep -cE "^[0-7][A-Za-z\[]" built.u); msg_s=$(grep -cE "^[0-7][A-Za-z\[]" stock.u); msg_c=$(comm -12 stock.u built.u | grep -cE "^[0-7][A-Za-z\[]")
echo "provenance: printk messages stock=$msg_s built=$msg_b shared=$msg_c"
fail=0
SV="4.4.22 SMP preempt ARMv7 p2v8"
grep -aq "$SV" stock.Image && echo "stock vermagic: $SV" || { echo "FAIL stock vermagic not found"; fail=1; }
for k in /out/modules/*.ko; do
  n=$(basename $k)
  vm=$(modinfo -F vermagic $k | sed "s/ *$//")
  [ "$vm" = "$SV" ] && echo "ok $n vermagic \"$vm\"" || { echo "FAIL $n vermagic \"$vm\""; fail=1; }
  miss=0
  for s in $(cat $k.undef); do
    grep -qx "$s" stock.all || { echo "  FAIL $n needs $s, not exported by stock"; miss=$((miss+1)); }
  done
  if arm-linux-gnueabihf-nm -u $k | grep -q _GLOBAL_OFFSET_TABLE_; then echo "FAIL $n has GOT references (PIE code)"; fail=1; fi
  [ $miss = 0 ] && echo "ok $n: all $(wc -l < $k.undef) undefined symbols are in the stock kernel" || fail=1
  echo "   sha256 $(sha256sum $k | cut -d" " -f1) size $(wc -c < $k)"
done
(cd /out/modules && sha256sum *.ko > SHA256SUMS)
[ "$n_miss" -le 0 ] || { echo "FAIL provenance: exports missing in the stock kernel"; fail=1; }
[ $fail = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
' 2>&1 | tee "$OUT/modules/check.txt"
grep -q "^ALL OK" "$OUT/modules/check.txt"
