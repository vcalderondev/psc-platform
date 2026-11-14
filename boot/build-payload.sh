#!/bin/sh
# Build Lumen's own boot payload: <stick>/d8781dae-c45c-4fc1-b961-e03eedebbffb/LDIAG.BIN
#
#   sh psc-platform/boot/build-payload.sh          (from the workspace folder, on the Mac)
#
# Steps:
#   1. lumen-splash for the console (toolchain container, boot/splash/build.sh)
#   2. stage payload/ = start, VERSION, bin/lumen-splash, assets/splash.png
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
[ -f "$KEYRING/secring.gpg" ] && [ -f "$KEYRING/pubring.gpg" ] && [ -f "$KEYRING/pass" ] ||
  die "console keyring not found at $KEYRING (set PSC_KEYRING)"
case "$(cd "$KEYRING" && pwd -P)/" in
  "$(cd "$REPO" && pwd -P)/"*) die "the keyring must not live inside psc-platform (public repo)" ;;
esac
command -v docker >/dev/null || die "docker is needed"

# version: psc-platform commit (+dirty) and date
VER="$(git -C "$REPO" describe --always --dirty 2>/dev/null || echo unknown)"
EPOCH="$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)"

echo "== 1. lumen-splash"
"$REPO/toolchain/psc" sh psc-platform/boot/splash/build.sh

echo "== 2. stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/payload/bin" "$STAGE/payload/assets"
cp "$HERE/payload/start" "$STAGE/payload/start"
cp "$OUT/lumen-splash" "$STAGE/payload/bin/lumen-splash"
[ -f "$SPLASH_PNG" ] && cp "$SPLASH_PNG" "$STAGE/payload/assets/splash.png" ||
  echo "   (no $SPLASH_PNG: the payload only uses <stick>/lumen/assets/splash.png)"
printf 'lumen-payload %s %s\n' "$VER" "$(date -u -r "$EPOCH" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u +%Y-%m-%dT%H:%MZ)" > "$STAGE/payload/VERSION"
chmod 755 "$STAGE/payload/start" "$STAGE/payload/bin/lumen-splash"
chmod 644 "$STAGE/payload/VERSION" "$STAGE/payload/assets/"* 2>/dev/null || true
sh -n "$STAGE/payload/start" || die "start: shell syntax error"

echo "== 3+4. pack and sign (gpg1 container)"
CTX="$OUT/gpg-context"; rm -rf "$CTX"; mkdir -p "$CTX/ca"
cp "$HERE/gpg/Dockerfile" "$CTX/"
[ -s "$REPO/toolchain/host-ca.pem" ] && cp "$REPO/toolchain/host-ca.pem" "$CTX/ca/host-ca.pem"
docker image inspect "$GPG_IMAGE" >/dev/null 2>&1 || docker build -q -t "$GPG_IMAGE" "$CTX" >/dev/null
rm -rf "$CTX"
rm -f "$OUT/LDIAG.BIN" "$OUT/payload.tar.gz"
docker run --rm --network none \
  -v "$KEYRING":/keyring:ro -v "$STAGE":/stage:ro -v "$OUT":/out \
  -e EPOCH="$EPOCH" -e RCPT="$RCPT" -e SIGNER="$SIGNER" "$GPG_IMAGE" sh -ec '
    cp -r /keyring /tmp/.gnupg && chmod 700 /tmp/.gnupg
    cp -a /stage /tmp/stage && cd /tmp/stage
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@"$EPOCH" \
        --format=gnu -cf - payload | gzip -9n > /out/payload.tar.gz
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
         --output /out/LDIAG.BIN /out/payload.tar.gz
    rm -rf /tmp/.gnupg'
(cd "$OUT" && md5 -r LDIAG.BIN 2>/dev/null || md5sum LDIAG.BIN) | awk '{print $1"  LDIAG.BIN"}' > "$OUT/LDIAG.BIN.md5"
echo "   $OUT/LDIAG.BIN ($(wc -c < "$OUT/LDIAG.BIN" | tr -d ' ') bytes, md5 $(cut -d' ' -f1 "$OUT/LDIAG.BIN.md5"))"

echo "== 5. verify like the console"
sh "$HERE/verify-payload.sh" "$OUT/LDIAG.BIN" | tee "$OUT/verify.txt"
echo "Install: copy $OUT/LDIAG.BIN to <stick>/$ID/LDIAG.BIN (keep Eris' as LDIAG.BIN.eris);"
echo "see research-notes/no-eris-boot.md in the workspace for the console test + rollback."
