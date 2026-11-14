# PSC cross toolchain
#   target : PlayStation Classic (Cortex-A35, armhf, glibc 2.24, Yocto Krogoth)
#   compiler: GCC 12 built against a glibc 2.24 sysroot (Debian 9 "stretch" armhf)
#
# Stage 1 builds the sysroot, stage 2 builds binutils+GCC against it,
# stage 3 is the slim image we actually use.

ARG BINUTILS_VER=2.40
ARG GCC_VER=12.3.0
ARG JOBS=4

###############################################################################
FROM debian:bookworm-slim AS sysroot
COPY host-ca.pem /etc/ssl/certs/ca-certificates.crt
RUN sed -i "s|http://deb.debian.org|https://deb.debian.org|g" /etc/apt/sources.list.d/debian.sources
RUN apt-get update && apt-get install -y --no-install-recommends \
      debootstrap ca-certificates wget symlinks && rm -rf /var/lib/apt/lists/*

# Download (not configure) stretch armhf + the -dev packages we compile against.
ARG PKGS="libc6-dev,linux-libc-dev,libstdc++6,libgles2-mesa-dev,libegl1-mesa-dev,libgbm-dev,libdrm-dev,libwayland-dev,libxkbcommon-dev,libasound2-dev,libudev-dev,libsdl2-dev,zlib1g-dev,libpng-dev,libfreetype6-dev"
RUN debootstrap --foreign --arch=armhf --variant=minbase --no-check-gpg \
      --include="${PKGS}" stretch /sysroot https://archive.debian.org/debian \
 && for d in /sysroot/var/cache/apt/archives/*.deb; do dpkg -x "$d" /sysroot; done \
 && rm -rf /sysroot/var/cache/apt/archives/*.deb /sysroot/debootstrap /sysroot/dev
# Absolute symlinks (e.g. libz.so -> /lib/...) -> relative, so they resolve inside the sysroot
RUN find /sysroot -type l -lname '/*' | while read -r l; do \
      t="$(readlink "$l")"; \
      ln -sfn "$(realpath -m --relative-to="$(dirname "$l")" "/sysroot$t")" "$l"; \
    done \
 && test -z "$(find /sysroot -type l -lname '/*')" \
 && test -e /sysroot/usr/lib/arm-linux-gnueabihf/libz.so \
 && test -f /sysroot/usr/include/GLES3/gl32.h \
 && test -f /sysroot/lib/arm-linux-gnueabihf/libc-2.24.so

###############################################################################
FROM debian:bookworm-slim AS gcc
COPY host-ca.pem /etc/ssl/certs/ca-certificates.crt
RUN sed -i "s|http://deb.debian.org|https://deb.debian.org|g" /etc/apt/sources.list.d/debian.sources
ARG BINUTILS_VER
ARG GCC_VER
ARG JOBS
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates wget xz-utils texinfo bison flex \
      libgmp-dev libmpfr-dev libmpc-dev file && rm -rf /var/lib/apt/lists/*
COPY --from=sysroot /sysroot /opt/psc/sysroot
ENV TARGET=arm-linux-gnueabihf PREFIX=/opt/psc/toolchain SYSROOT=/opt/psc/sysroot
WORKDIR /build
RUN wget -q https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz \
 && wget -q https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz \
 && tar xf binutils-${BINUTILS_VER}.tar.xz && tar xf gcc-${GCC_VER}.tar.xz \
 && rm -f *.tar.xz

RUN mkdir b-binutils && cd b-binutils \
 && ../binutils-${BINUTILS_VER}/configure --target=$TARGET --prefix=$PREFIX \
      --with-sysroot=$SYSROOT --disable-nls --disable-werror --disable-multilib \
      --enable-gold --enable-plugins \
 && make -j${JOBS} && make install-strip && cd .. && rm -rf b-binutils binutils-${BINUTILS_VER}

ENV PATH=$PREFIX/bin:$PATH
# Defaults tuned for the PSC: ARMv8 AArch32, NEON, hard-float, ARM mode.
RUN mkdir b-gcc && cd b-gcc \
 && ../gcc-${GCC_VER}/configure --target=$TARGET --prefix=$PREFIX \
      --with-sysroot=$SYSROOT --enable-multiarch \
      --enable-languages=c,c++ --disable-nls --disable-multilib \
      --disable-libsanitizer --disable-libquadmath --disable-bootstrap \
      --enable-threads=posix --enable-shared --enable-__cxa_atexit \
      --enable-clocale=gnu --enable-linker-build-id \
      --with-arch=armv8-a --with-fpu=neon-fp-armv8 --with-float=hard --with-mode=arm \
 && make -j${JOBS} all-gcc all-target-libgcc all-target-libstdc++-v3 \
 && make install-strip-gcc install-strip-target-libgcc install-strip-target-libstdc++-v3 \
 && cd .. && rm -rf b-gcc gcc-${GCC_VER}

###############################################################################
FROM debian:bookworm-slim
COPY host-ca.pem /etc/ssl/certs/ca-certificates.crt
RUN sed -i "s|http://deb.debian.org|https://deb.debian.org|g" /etc/apt/sources.list.d/debian.sources
RUN apt-get update && apt-get install -y --no-install-recommends \
      make cmake ninja-build meson pkg-config python3 git file ca-certificates \
      wget xz-utils patch libmpc3 libmpfr6 libgmp10 zlib1g libzstd1 \
      && rm -rf /var/lib/apt/lists/*
COPY --from=gcc /opt/psc /opt/psc
COPY cmake/psc-toolchain.cmake meson/psc-cross.ini /opt/psc/
COPY bin/ /opt/psc/bin/
COPY scripts/psc-check.py /opt/psc/bin/psc-check
RUN chmod +x /opt/psc/bin/*
# Linker defaults baked into GCC's specs:
#  1. the console's real libraries first (/opt/psc/devlink, built by psc-entry),
#  2. then the stretch sysroot; rpath-link so transitive deps of shared libs resolve.
RUN SPECS="$(dirname "$(/opt/psc/toolchain/bin/arm-linux-gnueabihf-gcc -print-libgcc-file-name)")/specs" \
 && /opt/psc/toolchain/bin/arm-linux-gnueabihf-gcc -dumpspecs > "$SPECS" \
 && python3 - "$SPECS" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
extra = (" -L/opt/psc/devlink -rpath-link /opt/psc/devlink"
         " -rpath-link %R/lib/arm-linux-gnueabihf -rpath-link %R/usr/lib/arm-linux-gnueabihf")
key = "*link:\n"
i = s.index(key) + len(key); j = s.index("\n", i)
s = s[:j] + extra + s[j:]
open(p, "w").write(s)
EOF
ENTRYPOINT ["/opt/psc/bin/psc-entry"]
ENV PATH=/opt/psc/bin:/opt/psc/toolchain/bin:$PATH \
    PSC_SYSROOT=/opt/psc/sysroot \
    PSC_DEVICE_ROOT=/device \
    PKG_CONFIG=/opt/psc/bin/psc-pkg-config \
    CROSS=arm-linux-gnueabihf-
WORKDIR /work
