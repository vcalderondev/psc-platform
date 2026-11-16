#!/bin/sh
# Build the PSC Bluetooth package from upstream sources: BlueZ 5.88 (bluetoothd) on GLib
# 2.90.1 (+ libffi 3.8.1, PCRE2 10.49). Output: out/bt/psc-bt.tar.gz, laid out as /usr for
# a frontend to overlay from RAM (nothing on the eMMC changes). The console has no GLib;
# its own libdbus 1.10 and system bus (dbus.service) are used as they are.
#
#   toolchain/psc sh psc-platform/bt/build.sh   (from the workspace folder)
#
# Layout under /usr:
#   libexec/bluetooth/bluetoothd                 the daemon (HID, HOGP, A2DP sink off)
#   lib/libglib-2.0.so.0 libpcre2-8.so.0 libffi.so.8
#   lib/psc-bt/main.conf                         passed with -f (/etc is read-only)
#   share/dbus-1/system.d/bluetooth.conf         D-Bus policy (the console's system.conf
#                                                includes this directory; reload the bus)
# Pairing keys live in /run/lumen-bt/lib/bluetooth (compile-time STORAGEDIR, tmpfs): a
# frontend restores and saves them on the stick (their file names hold ':', which FAT
# and exFAT refuse, so as an archive).
# Gate: psc-check of every binary against the console with the compositor overlay and
# this package on /usr.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$HERE")/compositor/common.sh"     # cache, headers, cross file
OUT="$REPO/out/bt"; mkdir -p "$OUT"

BLUEZ=5.88; GLIB=2.90.1; LIBFFI=3.8.1; PCRE2=10.49
fetch_sha https://www.kernel.org/pub/linux/bluetooth/bluez-$BLUEZ.tar.xz bluez-$BLUEZ.tar.xz \
  6952c39eb5f8b0ee712cc50ab3bcff03be17c410dd97ca640f4849d9a1653ba3
fetch_sha https://download.gnome.org/sources/glib/${GLIB%.*}/glib-$GLIB.tar.xz glib-$GLIB.tar.xz \
  93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396
fetch_sha https://github.com/libffi/libffi/releases/download/v$LIBFFI/libffi-$LIBFFI.tar.gz libffi-$LIBFFI.tar.gz \
  81e879c094cc5ec3186c48510c6385ac6b3e866192e8bc71a35245703757ee40
fetch_sha https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2/pcre2-$PCRE2.tar.bz2 pcre2-$PCRE2.tar.bz2 \
  53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384

console_headers
# libdbus headers of the console's version (1.10); linking resolves to its own library
DEB=https://archive.debian.org/debian/pool/main
f=libdbus-1-dev_1.10.32-0+deb9u1_armhf.deb; fetch "$DEB/d/dbus/$f" "$f"; dpkg -x "$CACHE/$f" "$SYSROOT"
rm -f "$SYSROOT"/usr/lib/arm-linux-gnueabihf/libdbus-1.a
# build-machine tools: GLib 2.90 needs meson >= 1.4 (the toolchain has 1.0); bzip2 for PCRE2
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends python3-pip bzip2 lbzip2 >/dev/null 2>&1
pip3 install -q --break-system-packages 'meson>=1.4' packaging >/dev/null 2>&1
hash -r; echo "meson $(meson --version)"
cross_file
. /opt/psc/bin/psc-env
H=arm-linux-gnueabihf
export PKG_CONFIG=/opt/psc/bin/cw-pkg-config
inst() { step "$1-install" make -C "$2" install DESTDIR="$STAGE" && step "$1-sysroot" make -C "$2" install DESTDIR="$SYSROOT"; }

# ---- libffi (GLib's GObject side is not built, but GLib's build still asks for it)
unpack libffi-$LIBFFI.tar.gz libffi; cd "$B/libffi"
step ffi-configure ./configure --host=$H --prefix=/usr --libdir=/usr/lib --disable-static --disable-docs \
   --disable-multi-os-directory CFLAGS="$PSC_FLAGS -O2"
step ffi-build make -j4
inst ffi .
ln -sfn "$SYSROOT/usr/lib/libffi.so" /opt/psc/devlink/libffi.so   # ours, not the console's 3.2

# ---- PCRE2 (8-bit only)
unpack pcre2-$PCRE2.tar.bz2 pcre2; cd "$B/pcre2"
step pcre2-configure ./configure --host=$H --prefix=/usr --libdir=/usr/lib --disable-static \
   --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --disable-pcre2grep-libz --disable-pcre2grep-libbz2 \
   CFLAGS="$PSC_FLAGS -O2"
step pcre2-build make -j4
inst pcre2 .
ln -sfn "$SYSROOT/usr/lib/libpcre2-8.so" /opt/psc/devlink/libpcre2-8.so

# ---- GLib (no introspection, no NLS, no tests; gio for BlueZ's needs only)
unpack glib-$GLIB.tar.xz glib; cd "$B/glib"
step glib-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
   -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dselinux=disabled -Dxattr=false \
   -Dlibmount=disabled -Dman-pages=disabled -Ddtrace=disabled -Dsystemtap=disabled -Dsysprof=disabled \
   -Dlibelf=disabled -Ddocumentation=false -Dglib_debug=disabled -Dinstalled_tests=false
step glib-build $NINJA -C build
step glib-install env DESTDIR="$STAGE" $NINJA -C build install
step glib-sysroot env DESTDIR="$SYSROOT" $NINJA -C build install
for l in glib-2.0 gio-2.0 gobject-2.0 gmodule-2.0; do
  [ -e "$SYSROOT/usr/lib/lib$l.so" ] && ln -sfn "$SYSROOT/usr/lib/lib$l.so" "/opt/psc/devlink/lib$l.so"
done

# ---- BlueZ: bluetoothd only (Lumen drives it over D-Bus; no readline client/tools)
unpack bluez-$BLUEZ.tar.xz bluez; cd "$B/bluez"
for p in "$HERE"/patches/*.patch; do [ -f "$p" ] && { echo "patch $(basename "$p")"; patch -p1 < "$p"; }; done
step bluez-configure ./configure --host=$H --prefix=/usr --sysconfdir=/etc --localstatedir=/run/lumen-bt \
   --libexecdir=/usr/libexec --with-dbusconfdir=/usr/share --disable-systemd --disable-cups --disable-obex \
   --disable-mesh --disable-manpages --disable-client --disable-monitor --disable-udev --disable-tools \
   --disable-hid2hci --disable-midi --disable-a2dp --disable-avrcp --disable-bap --disable-bass \
   --disable-mcp --disable-vcp --disable-micp --disable-ccp --disable-csip --disable-asha \
   --disable-test --disable-library --enable-hid --enable-hog \
   CFLAGS="$PSC_FLAGS -O2" PKG_CONFIG=/opt/psc/bin/cw-pkg-config
step bluez-build make -j4
step bluez-install make install DESTDIR="$STAGE"
grep -E "^ *(HID|HOG|A2DP|Input)" "$B/bluez-configure.log" > "$OUT/bluez-config.txt" || true

# ---- configuration (read with -f; /etc is read-only)
mkdir -p "$STAGE/usr/lib/psc-bt"
cat > "$STAGE/usr/lib/psc-bt/main.conf" <<'CONF'
# bluetoothd configuration for the PlayStation Classic (Lumen): game controllers first
[General]
Name = PlayStation Classic
Class = 0x000108
DiscoverableTimeout = 0
PairableTimeout = 0
ControllerMode = dual
FastConnectable = true
JustWorksRepairing = always
Privacy = off
[Policy]
AutoEnable = true
ReconnectAttempts = 7
ReconnectIntervals = 1,2,4,8,16,32,64
CONF
echo "bluez=$BLUEZ glib=$GLIB libffi=$LIBFFI pcre2=$PCRE2" > "$STAGE/usr/lib/psc-bt/VERSIONS"

# ---- package: run-time files only
rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/man" "$STAGE/usr/share/doc" \
       "$STAGE/usr/share/gettext" "$STAGE/usr/share/glib-2.0" "$STAGE/usr/share/aclocal" "$STAGE/usr/share/bash-completion" \
       "$STAGE/usr/share/zsh" "$STAGE/usr/share/info" "$STAGE/usr/share/gdb" "$STAGE/usr/bin" "$STAGE/usr/lib/glib-2.0" \
       "$STAGE/etc" "$STAGE/usr/share/locale" "$STAGE/usr/libexec/installed-tests"
# what bluetoothd does not use
rm -f "$STAGE"/usr/lib/libgirepository-2.0.so* "$STAGE"/usr/lib/libpcre2-posix.so* "$STAGE/usr/libexec/gio-launch-desktop"
find "$STAGE" -name '*.a' -delete; find "$STAGE" -name '*.la' -delete
find "$STAGE/usr" -type f -exec sh -c 'file "$1" | grep -q ELF && arm-linux-gnueabihf-strip --strip-unneeded "$1"' _ {} \; 2>/dev/null
[ -f "$STAGE/usr/share/dbus-1/system.d/bluetooth.conf" ] || { echo "bluetooth.conf (D-Bus policy) missing"; find "$STAGE" -name 'bluetooth.conf'; exit 1; }
tar czf "$OUT/psc-bt.tar.gz" -C "$STAGE/usr" .
( cd "$STAGE/usr" && find . -type f -o -type l | sort ) > "$OUT/psc-bt.files"

# ---- gate
COMBO=/tmp/bt-console; rm -rf "$COMBO"; mkdir -p "$COMBO/usr"
ln -s /device/lib "$COMBO/lib"; ln -s /device/usr/local "$COMBO/usr/local"
cp -a /device/usr/lib "$COMBO/usr/lib"
tar xzf "$REPO/out/compositor/psc-weston-16.tar.gz" -C "$COMBO/usr"
cp -a "$STAGE/usr/lib/." "$COMBO/usr/lib/"
ELFS=$(find "$STAGE/usr" -type f | xargs file | grep ELF | cut -d: -f1)
psc-check --device-root "$COMBO" $ELFS > "$OUT/psc-check.txt" 2>&1 || { cat "$OUT/psc-check.txt"; echo "psc-check failed"; exit 1; }
echo "psc-check: $(grep -c '^\[OK' "$OUT/psc-check.txt") binaries load on the console with this overlay"
cat "$STAGE/usr/lib/psc-bt/VERSIONS"; cat "$OUT/bluez-config.txt"
ls -la "$OUT/psc-bt.tar.gz"
