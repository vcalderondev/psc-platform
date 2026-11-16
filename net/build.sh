#!/bin/sh
# Build the PSC network package from upstream sources: Wi-Fi (wpa_supplicant 2.12, iw
# 6.17, libnl 3.12.0), TLS (OpenSSL 4.1.0 + Mozilla's CA bundle), curl 8.23.0 (zlib 1.4),
# an NTP client (BusyBox 1.38.0 ntpd: the console has no RTC battery and certificates
# need the date) and the firmware the stock kernel's Wi-Fi / Bluetooth drivers ask for
# (linux-firmware 20261019). Output: out/net/psc-net.tar.gz, laid out as /usr for a
# frontend to overlay from RAM next to the PSC compositor (nothing on the eMMC changes).
#
#   toolchain/psc sh psc-platform/net/build.sh   (from the workspace folder)
#
# Layout under /usr:
#   lib/libssl.so.4 libcrypto.so.4 libnl-3.so.200 libnl-genl-3.so.200 libcurl.so.4 libz.so.1
#   sbin/wpa_supplicant wpa_cli wpa_passphrase iw          bin/curl
#   lib/psc-net/busybox  (ntpd)             lib/psc-net/ssl/cert.pem (CA bundle)
#   lib/firmware/...     (firmware_class.path points here when the network starts)
# The console's own OpenSSL 1.0.0 stays (other sonames); its libz.so.1 is replaced by a
# newer one with the same ABI.
# Gate: psc-check of every binary against the console with the compositor overlay and
# this package on /usr.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$HERE")/compositor/common.sh"     # cache, headers, cross env
OUT="$REPO/out/net"; mkdir -p "$OUT"

OPENSSL=4.1.0; WPA=2.12; IW=6.17; LIBNL=3.12.0; CURL=8.23.0; ZLIB=1.4; BUSYBOX=1.38.0
FW=20261019; CACERT=2026-11-05
fetch_sha https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz openssl-$OPENSSL.tar.gz \
  50c17baf54cb008f6ce42d50deb4b28050a1aad711636cabd4b241c7e90cc2fd
fetch_sha https://w1.fi/releases/wpa_supplicant-$WPA.tar.gz wpa_supplicant-$WPA.tar.gz \
  08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6
fetch_sha https://mirrors.edge.kernel.org/pub/software/network/iw/iw-$IW.tar.xz iw-$IW.tar.xz \
  7d182e498289ab39b257da6780d562e415377107f50358ee5b55b8cfe40b1e33
fetch_sha https://github.com/thom311/libnl/releases/download/libnl3_$(echo $LIBNL | tr . _)/libnl-$LIBNL.tar.gz libnl-$LIBNL.tar.gz \
  fc51ca7196f1a3f5fdf6ffd3864b50f4f9c02333be28be4eeca057e103c0dd18
fetch_sha https://curl.se/download/curl-$CURL.tar.xz curl-$CURL.tar.xz \
  8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
fetch_sha https://github.com/madler/zlib/releases/download/v$ZLIB/zlib-$ZLIB.tar.xz zlib-$ZLIB.tar.xz \
  4f11c512053d7bab8d9e9b89bde3575add3e4c50a383b42ef6cb837035fc5a7c
fetch_sha https://busybox.net/downloads/busybox-$BUSYBOX.tar.bz2 busybox-$BUSYBOX.tar.bz2 \
  34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2
fetch_sha https://curl.se/ca/cacert-$CACERT.pem cacert-$CACERT.pem \
  427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285
# firmware: single files of linux-firmware at tag $FW (the stock 4.4 drivers' names)
FWB="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
mkdir -p "$CACHE/fw-$FW"
while read -r sha path; do
  path=${path#./}; src=$path; [ "$path" = mt7601u.bin ] && src=mediatek/mt7601u.bin   # moved upstream
  f="$CACHE/fw-$FW/$path"; mkdir -p "$(dirname "$f")"
  [ -s "$f" ] || wget -q -T 30 -t 3 -O "$f" "$FWB/$src?h=$FW" || { echo "firmware download failed: $src"; exit 1; }
  echo "$sha  $f" | sha256sum -c --quiet - || { echo "firmware checksum mismatch: $path"; exit 1; }
done < "$HERE/firmware-$FW.sha256"

. /opt/psc/bin/psc-env
H=arm-linux-gnueabihf
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig
inst() { step "$1-install" make -C "$2" install DESTDIR="$STAGE" && step "$1-sysroot" make -C "$2" install DESTDIR="$SYSROOT"; }

# ---- zlib
unpack zlib-$ZLIB.tar.xz zlib; cd "$B/zlib"
step zlib-configure env CHOST=$H CFLAGS="$PSC_FLAGS -O2" ./configure --prefix=/usr --libdir=/usr/lib --shared
step zlib-build make -j4
inst zlib .
ln -sfn "$SYSROOT/usr/lib/libz.so" /opt/psc/devlink/libz.so   # ships in the overlay, same ABI

# ---- OpenSSL (no apps, no docs; its default certificate file is the bundled CA list)
# OpenSSL links -latomic on ARM; the toolchain has none and ARMv7 needs none (GCC inlines
# 32/64-bit atomics with ldrex/strexd): an empty archive satisfies the flag, and any call
# that really needed the library would fail the link.
mkdir -p "$B/atomic" && $H-ar rcs "$B/atomic/libatomic.a"
unpack openssl-$OPENSSL.tar.gz openssl; cd "$B/openssl"
rm -f /opt/psc/devlink/libssl.so /opt/psc/devlink/libcrypto.so   # libssl must link the libcrypto built here
step openssl-configure env -u CC -u CXX -u AR -u RANLIB -u CFLAGS -u CXXFLAGS -u LDFLAGS ./Configure linux-armv4 --prefix=/usr --libdir=lib --openssldir=/usr/lib/psc-net/ssl \
   --cross-compile-prefix=$H- shared zlib no-tests no-docs no-apps no-afalgeng no-async \
   $PSC_FLAGS -O2 -I$SYSROOT/usr/include -L$SYSROOT/usr/lib -L$B/atomic
step openssl-build env -u CC -u CXX -u AR -u RANLIB -u CFLAGS -u LDFLAGS make -j4 build_libs
step openssl-install make install_dev DESTDIR="$STAGE"
step openssl-sysroot make install_dev DESTDIR="$SYSROOT"
# link against these, not the console's OpenSSL 1.0.0: the toolchain's devlink (the
# console's own libraries, searched first) must point here (as the compositor does for libdrm)
for l in libssl.so libcrypto.so; do ln -sfn "$SYSROOT/usr/lib/$l" "/opt/psc/devlink/$l"; done

# ---- libnl (genl for wpa_supplicant's nl80211 driver and iw)
# build-machine tools: bison/flex (libnl), bzip2 (BusyBox tarball), a native gcc (BusyBox's kconfig)
command -v bison >/dev/null && command -v flex >/dev/null && command -v lbzip2 >/dev/null && command -v gcc >/dev/null ||
  { apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends bison flex bzip2 lbzip2 gcc libc6-dev >/dev/null 2>&1; }
unpack libnl-$LIBNL.tar.gz libnl; cd "$B/libnl"
step libnl-configure ./configure --host=$H --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc \
   --disable-static --disable-cli --disable-debug CFLAGS="$PSC_FLAGS -O2"
# only libnl-3 and libnl-genl-3: libnl-route needs kernel headers newer than the console's
step libnl-build make -j4 lib/libnl-3.la lib/libnl-genl-3.la
mkdir -p "$SYSROOT/usr/include/libnl3" "$STAGE/usr/lib" "$SYSROOT/usr/lib/pkgconfig"
cp -R include/netlink "$SYSROOT/usr/include/libnl3/"
for l in libnl-3 libnl-genl-3; do
  find . -path "*/.libs/$l.so*" -exec cp -a {} "$STAGE/usr/lib/" \; -exec cp -a {} "$SYSROOT/usr/lib/" \;
  cp "$l.0.pc" "$SYSROOT/usr/lib/pkgconfig/" 2>/dev/null || find . -name "$l.0.pc" -exec cp {} "$SYSROOT/usr/lib/pkgconfig/" \;
done
ls "$STAGE"/usr/lib/libnl-3.so.200 "$STAGE"/usr/lib/libnl-genl-3.so.200 >/dev/null

# ---- wpa_supplicant + wpa_cli
unpack wpa_supplicant-$WPA.tar.gz wpa; cd "$B/wpa/wpa_supplicant"
cat > .config <<'CFG'
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=y
CONFIG_LIBNL32=y
CONFIG_TLS=openssl
CONFIG_IEEE8021X_EAPOL=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TTLS=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_SAE=y
CONFIG_OWE=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_NO_RANDOM_POOL=y
CONFIG_GETRANDOM=n
CONFIG_ELOOP_EPOLL=y
CFG
step wpa-build make -j4 CC=$H-gcc \
   EXTRA_CFLAGS="$PSC_FLAGS -O2 -I$SYSROOT/usr/include -I$SYSROOT/usr/include/libnl3" \
   LDFLAGS="-L$SYSROOT/usr/lib" PKG_CONFIG="pkg-config" BINDIR=/usr/sbin
step wpa-passphrase make wpa_passphrase CC=$H-gcc EXTRA_CFLAGS="$PSC_FLAGS -O2 -I$SYSROOT/usr/include -I$SYSROOT/usr/include/libnl3" LDFLAGS="-L$SYSROOT/usr/lib"
mkdir -p "$STAGE/usr/sbin"; cp wpa_supplicant wpa_cli wpa_passphrase "$STAGE/usr/sbin/"   # wpa_passphrase: the stick keeps a PSK hash, not the password

# ---- iw
unpack iw-$IW.tar.xz iw; cd "$B/iw"
step iw-build make -j4 CC=$H-gcc CFLAGS="$PSC_FLAGS -O2" PKG_CONFIG=pkg-config
cp iw "$STAGE/usr/sbin/"

# ---- curl (OpenSSL, zlib; the same CA bundle)
unpack curl-$CURL.tar.xz curl; cd "$B/curl"
step curl-configure ./configure --host=$H --prefix=/usr --libdir=/usr/lib --disable-static \
   --with-openssl="$SYSROOT/usr" --with-zlib="$SYSROOT/usr" --without-libpsl --without-brotli \
   --without-zstd --without-nghttp2 --without-libidn2 --without-libssh2 --disable-ldap \
   --disable-manual --disable-docs --with-ca-bundle=/usr/lib/psc-net/ssl/cert.pem \
   CFLAGS="$PSC_FLAGS -O2" CPPFLAGS="-I$SYSROOT/usr/include" LDFLAGS="-L$SYSROOT/usr/lib"
step curl-build make -j4
inst curl .

# ---- BusyBox: ntpd only (the console's busybox has udhcpc but no ntpd)
unpack busybox-$BUSYBOX.tar.bz2 busybox; cd "$B/busybox"
BB="env -u CC -u CXX -u AR -u RANLIB -u CFLAGS -u CXXFLAGS -u LDFLAGS"
step bb-config $BB make allnoconfig
for o in NTPD FEATURE_NTPD_CONF; do sed -i "s/^# CONFIG_$o is not set/CONFIG_$o=y/" .config; done
step bb-oldconfig sh -c "yes '' | $BB make oldconfig"
step bb-build $BB make -j4 CROSS_COMPILE=$H- CFLAGS_EXTRA="$PSC_FLAGS"
mkdir -p "$STAGE/usr/lib/psc-net"; cp busybox "$STAGE/usr/lib/psc-net/busybox"

# ---- CA bundle and firmware
mkdir -p "$STAGE/usr/lib/psc-net/ssl"
cp "$CACHE/cacert-$CACERT.pem" "$STAGE/usr/lib/psc-net/ssl/cert.pem"
mkdir -p "$STAGE/usr/lib/firmware"; cp -R "$CACHE/fw-$FW/." "$STAGE/usr/lib/firmware/"
cat > "$STAGE/usr/lib/psc-net/VERSIONS" <<V
openssl=$OPENSSL wpa_supplicant=$WPA iw=$IW libnl=$LIBNL curl=$CURL zlib=$ZLIB busybox=$BUSYBOX
linux-firmware=$FW ca-bundle=$CACERT
V

# ---- package: run-time files only
rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share" "$STAGE/usr/lib/cmake" \
       "$STAGE/usr/bin/curl-config" "$STAGE/etc" "$STAGE/usr/lib/engines-"* "$STAGE/usr/lib/ossl-modules"
find "$STAGE" -name '*.a' -delete; find "$STAGE" -name '*.la' -delete
find "$STAGE/usr" -type f -exec sh -c 'file "$1" | grep -q ELF && $H-strip --strip-unneeded "$1"' _ {} \; 2>/dev/null
tar czf "$OUT/psc-net.tar.gz" -C "$STAGE/usr" .
( cd "$STAGE/usr" && find . -type f -o -type l | sort ) > "$OUT/psc-net.files"

# ---- gate: the console with the compositor overlay and this package on /usr
COMBO=/tmp/net-console; rm -rf "$COMBO"; mkdir -p "$COMBO/usr"
ln -s /device/lib "$COMBO/lib"; ln -s /device/usr/local "$COMBO/usr/local"
cp -a /device/usr/lib "$COMBO/usr/lib"
tar xzf "$REPO/out/compositor/psc-weston-16.tar.gz" -C "$COMBO/usr"
cp -a "$STAGE/usr/lib/." "$COMBO/usr/lib/"
ELFS=$(find "$STAGE/usr/bin" "$STAGE/usr/sbin" "$STAGE/usr/lib" -type f | xargs file | grep ELF | cut -d: -f1)
psc-check --device-root "$COMBO" $ELFS > "$OUT/psc-check.txt" 2>&1 || { cat "$OUT/psc-check.txt"; echo "psc-check failed"; exit 1; }
echo "psc-check: $(grep -c '^\[OK' "$OUT/psc-check.txt") binaries load on the console with this overlay"
# libz.so.1 is replaced under the console's own programs: each of them must load as before
U=$(for f in /device/usr/lib/*.so* /device/lib/*.so* /device/usr/bin/* /device/usr/sbin/*; do
      [ -f "$f" ] && [ ! -L "$f" ] && $H-readelf -d "$f" 2>/dev/null | grep -q 'libz.so.1' && echo "$f"; done; true)
psc-check --device-root /device $U > "$B/zbase.txt" 2>&1 || true
psc-check --device-root "$COMBO" $U > "$OUT/psc-check-libz-users.txt" 2>&1 || true
nb=$(grep -c '^\[FAIL' "$B/zbase.txt" || true); nn=$(grep -c '^\[FAIL' "$OUT/psc-check-libz-users.txt" || true)
[ "$nn" -le "$nb" ] || { echo "the new libz breaks console programs:"; grep -A4 '^\[FAIL' "$OUT/psc-check-libz-users.txt"; exit 1; }
echo "libz: $(echo $U | wc -w) console programs use it, failures before $nb / with the overlay $nn"
cat "$STAGE/usr/lib/psc-net/VERSIONS"
ls -la "$OUT/psc-net.tar.gz"
