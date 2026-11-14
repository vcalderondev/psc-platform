# Shared by the compositor recipes (build.sh: Weston 6.0.1, build-16.sh: Weston 16):
# paths, download cache, the console's -dev headers, the cross pkg-config wrapper,
# the native wayland-scanner, the meson cross file, Wayland itself, and the packaging
# step with its psc-check gate. Sourced, not run; the caller sets HERE (compositor/).
REPO="$(dirname "$HERE")"
OUT="$REPO/out/compositor"
CACHE="$OUT/cache"
B=/tmp/lw-build
STAGE=/tmp/lw-stage            # what ends up under /usr on the console
SYSROOT=/opt/psc/sysroot
mkdir -p "$CACHE" "$B" "$STAGE"
. /opt/psc/bin/psc-env
GL=https://gitlab.freedesktop.org/wayland
NINJA="ninja -j4"   # memory-friendly: the build host runs other work too

# run a build step quietly; on failure show the end of its log
step() { name=$1; shift; echo "== $name"; if ! "$@" > "$B/$name.log" 2>&1; then echo "FAILED: $name"; tail -40 "$B/$name.log"; exit 1; fi; }
fetch() { [ -s "$CACHE/$2" ] || wget -q -T 30 -t 3 -O "$CACHE/$2.part" "$1" && mv -f "$CACHE/$2.part" "$CACHE/$2" 2>/dev/null || true; [ -s "$CACHE/$2" ] || { echo "download failed: $1"; exit 1; }; }
# fetch, then check the file against a pinned sha256
fetch_sha() { fetch "$1" "$2"; echo "$3  $CACHE/$2" | sha256sum -c --quiet - || { echo "checksum mismatch: $2"; exit 1; }; }
# unpack a cached tarball into a fresh $B/<dir>
unpack() { rm -rf "$B/$2" && mkdir -p "$B/$2" && tar xf "$CACHE/$1" -C "$B/$2" --strip-components=1; }

# ---- headers of the console's libraries (Debian stretch armhf -dev packages)
console_headers() {
  DEB=https://archive.debian.org/debian/pool/main
  for p in libi/libinput/libinput-dev_1.6.3-1_armhf.deb \
           libe/libevdev/libevdev-dev_1.5.6+dfsg-1_armhf.deb \
           p/pixman/libpixman-1-dev_0.34.0-1_armhf.deb \
           c/cairo/libcairo2-dev_1.14.8-1_armhf.deb \
           e/expat/libexpat1-dev_2.2.0-2+deb9u3_armhf.deb \
           libf/libffi/libffi-dev_3.2.1-6_armhf.deb \
           libx/libxkbcommon/libxkbcommon-dev_0.7.1-2~deb9u1_armhf.deb \
           libd/libdrm/libdrm-dev_2.4.74-1_armhf.deb \
           libp/libpng1.6/libpng-dev_1.6.28-1+deb9u1_armhf.deb; do
    f="$(basename "$p")"; fetch "$DEB/$p" "$f"; dpkg -x "$CACHE/$f" "$SYSROOT"
  done
  # link-time only: the console's .so files carry their own dependencies, so the private
  # requirements in these .pc files (fontconfig, xcb, ...) need not be resolvable here
  for pc in "$SYSROOT"/usr/lib/arm-linux-gnueabihf/pkgconfig/cairo*.pc; do sed -i '/^Requires.private:/d' "$pc"; done
  # the -dev packages bring static archives and .so links to runtime packages we do not
  # unpack: drop both, so -lfoo resolves to the console's own library (devlink)
  for l in cairo cairo-script-interpreter input evdev pixman-1 expat ffi xkbcommon drm png16 png; do
    rm -f "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.a"
    [ -L "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so" ] && [ ! -e "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so" ] &&
      rm -f "$SYSROOT/usr/lib/arm-linux-gnueabihf/lib$l.so"
  done
  # pkg-config for the console (cross) lookups only: our own builds install into the
  # sysroot's /usr/lib/pkgconfig, searched first, so they win over stretch's versions.
  # Build-machine lookups (wayland-scanner) use the container's own pkg-config untouched.
  cat > /opt/psc/bin/cw-pkg-config <<PC
#!/bin/sh
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig:$SYSROOT/usr/lib/arm-linux-gnueabihf/pkgconfig
exec pkg-config "\$@"
PC
  chmod +x /opt/psc/bin/cw-pkg-config
  unset PKG_CONFIG PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
}

# ---- native wayland-scanner (runs on the build machine); $1 = wayland tarball,
# further arguments = extra Debian packages the build machine needs
native_scanner() {
  tarball=$1; shift
  if ! command -v wayland-scanner >/dev/null; then
    apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gcc g++ libc6-dev libexpat1-dev libffi-dev libxml2-dev "$@" >/dev/null 2>&1
    rm -rf "$B/wl-native" && mkdir -p "$B/wl-native" && tar xf "$CACHE/$tarball" -C "$B/wl-native" --strip-components=1
    (cd "$B/wl-native" && env -u PKG_CONFIG -u PKG_CONFIG_LIBDIR -u CC -u CFLAGS -u LDFLAGS \
       -u CXX -u CXXFLAGS -u AR -u STRIP -u RANLIB -u PKG_CONFIG_SYSROOT_DIR \
       meson setup build --prefix=/usr/local -Dlibraries=false -Dtests=false -Ddocumentation=false -Ddtd_validation=false >"$B/native.log" 2>&1 &&
       $NINJA -C build install >>"$B/native.log" 2>&1) || { tail -20 "$B/native.log"; exit 1; }
  fi
  wayland-scanner --version
}

cross_file() {
  MCROSS="/opt/psc/meson-cross.ini"
  sed "s#^pkg-config = .*#pkgconfig = '/opt/psc/bin/cw-pkg-config'#" /opt/psc/psc-cross.ini > "$MCROSS"
  unset CC CXX AR STRIP_ RANLIB CFLAGS CXXFLAGS LDFLAGS   # meson takes them from the cross file
}

# ---- wayland (libraries for the console) and wayland-protocols (XML only); $1 $2 = versions
build_wayland() {
  unpack "wayland-$1.tar.xz" wayland
  cd "$B/wayland"
  step wayland-setup meson setup build --cross-file "$MCROSS" --prefix=/usr --libdir=lib --buildtype=release \
     -Dscanner=false -Ddocumentation=false -Ddtd_validation=false -Dtests=false
  step wayland-build $NINJA -C build
  step wayland-install env DESTDIR="$STAGE" $NINJA -C build install
  step wayland-sysroot env DESTDIR="$SYSROOT" $NINJA -C build install
  unpack "wayland-protocols-$2.tar.xz" wp
  cd "$B/wp"
  step protocols-setup meson setup build --prefix=/usr -Dtests=false
  step protocols-install env DESTDIR="$SYSROOT" $NINJA -C build install
}

# ---- package: the overlay holds only what the console needs at run time.
# $1 = package name (out/compositor/<name>.tar.gz and <name>.files), $2 = psc-check
# report file name, further arguments = console binaries (paths under /device) to check
# against the overlay as well, e.g. the PowerVR libraries that load a shipped libdrm.
package_and_check() {
  pkg=$1 report=$2; shift 2
  # libwayland-egl stays the console's: its Mesa 17 EGL reads the old unversioned
  # wl_egl_window layout (wl_surface at offset 0); 1.15+ puts a version field there
  rm -f "$STAGE"/usr/lib/libwayland-egl.so*
  rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/pkgconfig" "$STAGE/usr/share/wayland" \
         "$STAGE/usr/share/wayland-protocols" "$STAGE/usr/share/man" "$STAGE/usr/share/aclocal"
  find "$STAGE" -name '*.a' -delete
  find "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/usr/libexec" -type f -exec sh -c 'file "$1" | grep -q ELF && $STRIP "$1"' _ {} \; 2>/dev/null
  mkdir -p "$OUT"
  if ls "$STAGE"/usr/lib/libwayland-egl* >/dev/null 2>&1; then echo "libwayland-egl must not be packaged"; exit 1; fi
  tar czf "$OUT/$pkg.tar.gz" -C "$STAGE/usr" .
  ( cd "$STAGE/usr" && find . -type f | sort ) > "$OUT/$pkg.files"
  # Check every binary against what the console will have at run time: its root
  # filesystem with this package overlaid on /usr. Any unresolved symbol (Weston loads
  # its modules with RTLD_NOW) or missing library fails the build.
  COMBO=/tmp/cw-console; rm -rf "$COMBO"; mkdir -p "$COMBO/usr"
  ln -s /device/lib "$COMBO/lib"
  ln -s /device/usr/local "$COMBO/usr/local"
  cp -a /device/usr/lib "$COMBO/usr/lib" 2>/dev/null || { mkdir -p "$COMBO/usr/lib"; cp -a /device/usr/lib/. "$COMBO/usr/lib/"; }
  cp -a "$STAGE/usr/lib/." "$COMBO/usr/lib/"
  ELFS=$(find "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/usr/libexec" -type f | xargs file | grep ELF | cut -d: -f1)
  # private library dirs the package's binaries reach through their RPATH
  # (Weston 16: /usr/lib/weston/libexec_weston.so.0)
  BUNDLES=$(find "$STAGE/usr/lib" -mindepth 2 -name 'lib*.so.*' -exec dirname {} \; | sort -u | sed "s#^$STAGE#--bundle $COMBO#")
  psc-check --device-root "$COMBO" $BUNDLES $ELFS "$@" > "$OUT/$report" 2>&1 || true
  # console binaries given as arguments: only problems the overlay introduces count, so
  # check them against the bare console too (e.g. pvr_dri.so takes _glapi_* from the
  # libglapi its loader brought in, which no NEEDED entry names)
  : > "$B/baseline.txt"
  [ $# -eq 0 ] || psc-check --device-root /device "$@" > "$B/baseline.txt" 2>&1 || true
  # shell and screen-share modules are loaded into the weston executable and resolve
  # wet_* / text_backend_* against it: those symbols are not failures
  arm-linux-gnueabihf-nm -D --defined-only "$STAGE/usr/bin/weston" | awk '{print $3}' > "$B/weston-exports.txt"
  python3 - "$OUT/$report" "$B/weston-exports.txt" "$B/baseline.txt" <<'PY' || { echo "psc-check failed (see $OUT/$report)"; exit 1; }
import re, sys
exports = set(open(sys.argv[2]).read().split())
def blocks(text):
    return [b for b in re.split(r'\n(?=\[(?:OK |FAIL)\])', text) if b.startswith('[FAIL]')]
def reasons(block):
    return [l.strip()[2:] for l in block.splitlines() if l.strip().startswith('- ')]
baseline = {(b.splitlines()[0], r) for b in blocks(open(sys.argv[3]).read()) for r in reasons(b)}
bad = []
for block in blocks(open(sys.argv[1]).read()):
    real = [r for r in reasons(block) if (block.splitlines()[0], r) not in baseline and
            not (r.startswith('unresolved symbol: ') and r.split(': ', 1)[1] in exports)]
    if real or not reasons(block):
        bad.append(block.splitlines()[0] + '\n   ' + '\n   '.join(real))
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
  echo "psc-check: $(grep -c '^\[OK' "$OUT/$report") binaries load on the console with this overlay"
  ls -la "$OUT/$pkg.tar.gz"
}
