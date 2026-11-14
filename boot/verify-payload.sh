#!/bin/sh
# Verify a boot payload (LDIAG.BIN) the way the console does, with the console's own
# binaries: Sony's usb_watch logic, run under ARMv7 emulation (docker --platform
# linux/arm/v7) with gpg 1.4.7, busybox (tar/awk) and bash taken from the console's
# rootfs dump. Nothing is executed from the payload itself.
#
#   sh psc-platform/boot/verify-payload.sh <LDIAG.BIN> [<more LDIAG.BIN>...]
#
# Checks, in usb_watch order (exec_diag in /usr/bin/usb_watch):
#   1. gpg --decrypt with a copy of /home/root/.gnupg + its pass file      (same command line)
#   2. gpg's output has "Good signature" AND the CSSOFT2 recipient siecs2@  (RCPT_CHECK)
#   3. usb_watch's check_tar (copied verbatim from the dump): no absolute or ".." paths,
#      total size <= 100 MiB
#   4. the tar extracts with the console's busybox tar, its first folder has ./start,
#      and start parses with the console's /bin/sh (bash)
# Then a negative test: the same file with one byte flipped must be REJECTED.
# Exit status 0 only if every given file passes and every tampered copy is rejected.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WS="${PSC_WORKSPACE:-$(dirname "$REPO")}"
SYSROOT="${PSC_SYSROOT:-$WS/device-dump/sysroot}"
KEYRING="${PSC_KEYRING:-$SYSROOT/home/root/.gnupg}"
[ $# -ge 1 ] || { echo "usage: $0 <LDIAG.BIN>..." >&2; exit 2; }
[ -x "$SYSROOT/usr/bin/gpg" ] && [ -f "$SYSROOT/usr/bin/usb_watch" ] || { echo "no console rootfs at $SYSROOT" >&2; exit 2; }

rc=0
for f in "$@"; do
  d="$(cd "$(dirname "$f")" && pwd)"; b="$(basename "$f")"
  echo "### $f"
  docker run --rm --network none --platform linux/arm/v7 \
    -v "$SYSROOT":/sr:ro -v "$KEYRING":/keyring:ro -v "$d":/in:ro \
    -e B="$b" arm32v7/busybox:1.36 sh -c '
set -u
LD="/sr/lib/ld-linux-armhf.so.3 --library-path /sr/lib:/sr/usr/lib"
gpg() { $LD /sr/usr/bin/gpg "$@"; }
BB="$LD /sr/bin/busybox.nosuid"
mkdir -p /tmp/bin
for t in tar awk cut; do printf "#!/bin/sh\nexec %s %s \"\$@\"\n" "$BB" "$t" > /tmp/bin/$t; chmod +x /tmp/bin/$t; done
export PATH=/tmp/bin:$PATH
# usb_watch check_tar, verbatim
eval "$(sed -n "/^check_tar () {/,/^}/p" /sr/usr/bin/usb_watch)"
one() {  # file -> 0 accepted / 1 rejected, printing why
  rm -rf /tmp/.gnupg /tmp/diag; mkdir -p /tmp/diag/.tmp /tmp/diag/d8781dae-c45c-4fc1-b961-e03eedebbffb
  cp -r /keyring /tmp/.gnupg; chmod 700 /tmp/.gnupg
  DIGOUT=/tmp/diag/.tmp/LDIAG.BIN.tar.gz.gpg; DIGGZ=/tmp/diag/.tmp/LDIAG.BIN.tar.gz
  cp "$1" $DIGOUT
  sign=$(gpg --batch --yes --homedir /tmp/.gnupg --passphrase-file /tmp/.gnupg/pass --decrypt --ignore-time-conflict --out $DIGGZ $DIGOUT 2>&1 1>/dev/null)
  echo "$sign" | sed "s/^/  gpg| /"
  echo "$sign" | grep -q "Good signature" || { echo "  REJECT: no Good signature"; return 1; }
  echo "$sign" | grep -q "siecs2@siecs2.sony.com" || { echo "  REJECT: RCPT CHECK ERROR"; return 1; }
  echo "  ok: Good signature + recipient siecs2 (RCPT_CHECK=1)"
  r=$(check_tar "$DIGGZ")
  [ "$r" = OK ] || { echo "  REJECT: check_tar=$r"; return 1; }
  echo "  ok: check_tar OK ($(tar tvf $DIGGZ | awk "{s+=\$3} END {print s}") bytes, $(tar tf $DIGGZ | wc -l) entries)"
  tar xf "$DIGGZ" -C /tmp/diag/d8781dae-c45c-4fc1-b961-e03eedebbffb
  DIR="$(cd /tmp/diag/d8781dae-c45c-4fc1-b961-e03eedebbffb; ls -d */ | head -1)"
  [ -f "/tmp/diag/d8781dae-c45c-4fc1-b961-e03eedebbffb/$DIR/start" ] || { echo "  REJECT: no start in $DIR"; return 1; }
  $LD /sr/bin/bash -n "/tmp/diag/d8781dae-c45c-4fc1-b961-e03eedebbffb/$DIR/start" || { echo "  REJECT: start syntax (console bash)"; return 1; }
  echo "  ok: extracts with console busybox tar, ${DIR}start present, parses with console bash"
  ( cd /tmp/diag/d8781dae-c45c-4fc1-b961-e03eedebbffb && $LD /sr/bin/ls.coreutils -lR . ) | sed "s/^/  tar| /"
  return 0
}
echo "gpg: $(gpg --version | head -1) (console binary)"
if one "/in/$B"; then echo "RESULT: ACCEPTED by usb_watch logic"; else echo "RESULT: REJECTED"; exit 1; fi
# tamper test: flip one byte in the middle
cp "/in/$B" /tmp/tampered; sz=$(wc -c < /tmp/tampered); off=$((sz / 2))
printf "\\x$(printf %02x $(( ($(od -An -tu1 -j$off -N1 /tmp/tampered) + 1) % 256 )))" | dd of=/tmp/tampered bs=1 seek=$off conv=notrunc 2>/dev/null
echo "--- tamper test (byte $off flipped)"
if one /tmp/tampered >/tmp/t.log 2>&1; then cat /tmp/t.log; echo "TAMPER: ACCEPTED (BAD)"; exit 1; else grep -E "REJECT|BAD|failed|error" /tmp/t.log | head -3; echo "TAMPER: rejected (good)"; fi
' || rc=1
done
exit $rc
