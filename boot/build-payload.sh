#!/bin/sh
# Build Lumen's own boot payload: <stick>/d8781dae-c45c-4fc1-b961-e03eedebbffb/LDIAG.BIN
#
#   sh psc-platform/boot/build-payload.sh          (from the workspace folder, on the Mac)
#
# Steps:
#   1. lumen-splash for the console (toolchain container, boot/splash/build.sh)
#   2. stage payload/ = start, splash.sh, VERSION, bin/lumen-splash, assets/splash[-1080].png,
#      assets/boot/loading-<lang>[-1080].png (the splash's "Loading" text), and
#      modules/{overlay,xpad}.ko when kernel/build-modules.sh built and checked them
#   3. tar.gz it (GNU tar, reproducible: sorted, uid/gid 0, fixed mtime, gzip -n)
#   4. sign with the console's siescph1000 key, encrypt to siecs2 + symmetric with the
#      keyring passphrase (gpg1 container),
#      exactly the format Sony's usb_watch accepts for the CSSOFT2 id
#   5. verify-payload.sh: decrypt it with the CONSOLE's own gpg 1.4.7 + keyring copy and
#      run usb_watch's own checks (see that script)
#
# The keyring is the console's (/home/root/.gnupg from the user's own device dump). It
# is PRIVATE: it is read from PSC_KEYRING (default <workspace>/device-dump/sysroot/
# home/root/.gnupg), never copied into this repo, and only into a container's /tmp.
# The output (out/boot/) is git-ignored and must never be published either: it is
# signed with that key.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WS="${PSC_WORKSPACE:-$(dirname "$REPO")}"
KEYRING="${PSC_KEYRING:-$WS/device-dump/sysroot/home/root/.gnupg}"
OUT="$REPO/out/boot"
STAGE="$OUT/stage"
ID=d8781dae-c45c-4fc1-b961-e03eedebbffb
RCPT=siecs2@siecs2.sony.com
SIGNER=siescph1000@siescph1000.sony.com
SPLASH_PNG="${LUMEN_SPLASH:-$WS/lumen/assets/splash.png}"
GPG_IMAGE=psc-boot-gpg1:local

die() { echo "build-payload: $*" >&2; exit 1; }
# modes:  (none)            pack + sign + verify        (needs the keyring)
#         --pack-only       only out/boot/payload.tar.gz (no keyring: what a public CI can build)
#         --sign <tar.gz>   sign + verify an existing payload.tar.gz (e.g. from a release)
MODE=all; IN_TGZ=""
case "$1" in
  --pack-only) MODE=pack ;;
  --sign) MODE=sign; IN_TGZ="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; [ -f "$IN_TGZ" ] || die "no $2" ;;
  "") ;;
  *) die "usage: $0 [--pack-only | --sign <payload.tar.gz>]" ;;
esac
need_keyring() {
  [ -f "$KEYRING/secring.gpg" ] && [ -f "$KEYRING/pubring.gpg" ] && [ -f "$KEYRING/pass" ] ||
    die "console keyring not found at $KEYRING (set PSC_KEYRING)"
  case "$(cd "$KEYRING" && pwd -P)/" in
    "$(cd "$REPO" && pwd -P)/"*) die "the keyring must not live inside psc-platform (public repo)" ;;
  esac
}
command -v docker >/dev/null || die "docker is needed"
[ "$MODE" = pack ] || need_keyring
mkdir -p "$OUT"
CTX="$OUT/gpg-context"; rm -rf "$CTX"; mkdir -p "$CTX/ca"
cp "$HERE/gpg/Dockerfile" "$CTX/"
[ -s "$REPO/toolchain/host-ca.pem" ] && cp "$REPO/toolchain/host-ca.pem" "$CTX/ca/host-ca.pem"
docker image inspect "$GPG_IMAGE" >/dev/null 2>&1 || docker build -q -t "$GPG_IMAGE" "$CTX" >/dev/null
rm -rf "$CTX"

if [ "$MODE" != sign ]; then
  # version: psc-platform commit (+dirty) and date
  VER="$(git -C "$REPO" describe --always --dirty 2>/dev/null || echo unknown)"
  EPOCH="$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)"

  echo "== 1. lumen-splash"
  # this checkout's own folder under the workspace (a worktree is not named psc-platform)
  PSC_WORKSPACE="$WS" "$REPO/toolchain/psc" sh "$(basename "$REPO")/boot/splash/build.sh"

  echo "== 2. stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE/payload/bin" "$STAGE/payload/assets"
  cp "$HERE/payload/start" "$HERE/payload/splash.sh" "$STAGE/payload/"
  cp "$OUT/lumen-splash" "$STAGE/payload/bin/lumen-splash"
  [ -f "$SPLASH_PNG" ] && cp "$SPLASH_PNG" "$STAGE/payload/assets/splash.png" ||
    echo "   (no $SPLASH_PNG: the payload only uses <stick>/lumen/assets/splash.png)"
  # the 1080p splash and the "Loading" text pictures live next to it in Lumen's assets
  SPLASH_DIR="$(dirname "$SPLASH_PNG")"
  [ -f "$SPLASH_DIR/splash-1080.png" ] && cp "$SPLASH_DIR/splash-1080.png" "$STAGE/payload/assets/"
  if ls "$SPLASH_DIR/boot/"loading-*.png >/dev/null 2>&1; then
    mkdir -p "$STAGE/payload/assets/boot"; cp "$SPLASH_DIR/boot/"loading-*.png "$STAGE/payload/assets/boot/"
    echo "   loading text: $(ls "$STAGE/payload/assets/boot" | wc -l | tr -d ' ') pictures"
  else
    echo "   (no $SPLASH_DIR/boot/loading-*.png: the payload only uses the stick's)"
  fi
  # kernel modules for the stock kernel (psc-platform/kernel/build-modules.sh), if built
  if ls "$REPO/out/kernel/modules/"*.ko >/dev/null 2>&1 && grep -q "^ALL OK" "$REPO/out/kernel/modules/check.txt" 2>/dev/null; then
    mkdir -p "$STAGE/payload/modules"; cp "$REPO/out/kernel/modules/"*.ko "$STAGE/payload/modules/"
    chmod 644 "$STAGE/payload/modules/"*.ko; echo "   modules: $(cd "$STAGE/payload/modules" && ls | tr "\n" " ")"
  else
    echo "   (no checked modules in out/kernel/modules: payload without overlay.ko/xpad.ko)"
  fi
  printf 'lumen-payload %s %s\n' "$VER" "$(date -u -d "@$EPOCH" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$EPOCH" +%Y-%m-%dT%H:%MZ)" > "$STAGE/payload/VERSION"
  chmod 755 "$STAGE/payload/start" "$STAGE/payload/splash.sh" "$STAGE/payload/bin/lumen-splash"
  chmod 644 "$STAGE/payload/VERSION" "$STAGE/payload/assets/"*.png "$STAGE/payload/assets/boot/"*.png 2>/dev/null || true
  sh -n "$STAGE/payload/start" || die "start: shell syntax error"
  sh -n "$STAGE/payload/splash.sh" || die "splash.sh: shell syntax error"

echo "== 3. pack"
rm -f "$OUT/payload.tar.gz"
docker run --rm --network none -v "$STAGE":/stage:ro -v "$OUT":/out -e EPOCH="$EPOCH" "$GPG_IMAGE" sh -ec '
  cp -a /stage /tmp/stage && cd /tmp/stage
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@"$EPOCH" \
      --format=gnu -cf - payload | gzip -9n > /out/payload.tar.gz'
echo "   $OUT/payload.tar.gz ($(wc -c < "$OUT/payload.tar.gz" | tr -d ' ') bytes)"
IN_TGZ="$OUT/payload.tar.gz"
[ "$MODE" = pack ] && exit 0
fi

echo "== 4. sign (gpg1 container, keyring copied to its /tmp only)"
rm -f "$OUT/LDIAG.BIN"
docker run --rm --network none \
  -v "$KEYRING":/keyring:ro -v "$IN_TGZ":/in/payload.tar.gz:ro -v "$OUT":/out \
  -e RCPT="$RCPT" -e SIGNER="$SIGNER" "$GPG_IMAGE" sh -ec '
    cp -r /keyring /tmp/.gnupg && chmod 700 /tmp/.gnupg
    # sign (siescph1000 signing subkey) + encrypt to siecs2 AND symmetrically with the
    # keyring passphrase (pass). The console holds only the siecs2 PUBLIC key: it decrypts
    # through the symmetric layer (gpg --passphrase-file pass), and the usb_watch recipient
    # check only greps "siecs2@" in the gpg "encrypted with ... key" line. The Eris LDIAG.BIN
    # is built the same way (pubkey enc packet + symkey enc packet). --trust-model always:
    # no ownertrust for siecs2 in the console keyring, and usb_watch does not check it.
    gpg1 --batch --yes --homedir /tmp/.gnupg --passphrase-file /tmp/.gnupg/pass \
         --trust-model always --local-user "$SIGNER" --recipient "$RCPT" \
         --digest-algo SHA256 --cipher-algo AES256 --s2k-cipher-algo AES256 --compress-algo zlib \
         --set-filename payload.tar.gz --sign --encrypt --symmetric \
         --output /out/LDIAG.BIN /in/payload.tar.gz
    rm -rf /tmp/.gnupg'
(cd "$OUT" && md5 -r LDIAG.BIN 2>/dev/null || md5sum LDIAG.BIN) | awk '{print $1"  LDIAG.BIN"}' > "$OUT/LDIAG.BIN.md5"
echo "   $OUT/LDIAG.BIN ($(wc -c < "$OUT/LDIAG.BIN" | tr -d ' ') bytes, md5 $(cut -d' ' -f1 "$OUT/LDIAG.BIN.md5"))"
# the two files usb_watch looks for, laid out as on the stick (for package.sh / installers)
rm -rf "$OUT/stick"; mkdir -p "$OUT/stick/$ID"
cp "$OUT/LDIAG.BIN" "$OUT/stick/$ID/LDIAG.BIN"; : > "$OUT/stick/$ID/diag"

echo "== 5. verify like the console"
sh "$HERE/verify-payload.sh" "$OUT/LDIAG.BIN" | tee "$OUT/verify.txt"
echo "Stick files: $OUT/stick/ ($ID/diag + LDIAG.BIN; keep an Eris LDIAG.BIN as LDIAG.BIN.eris)."
echo "See research-notes/no-eris-boot.md in the workspace for the console test + rollback."
