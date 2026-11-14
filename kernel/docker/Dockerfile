# Kernel module build environment for the PlayStation Classic's Sony 4.4.22 kernel.
#
# Cross compiler: GCC 6.3.0 for arm-linux-gnueabihf from Debian 9 "stretch" (archived),
# the same compiler family as Sony's own build (gcc 6.2.0) and Eris' (Debian 6.3.0). A 4.4
# kernel does not build with modern GCC. Stretch's own apt cannot reach the archive over
# https (no apt-transport-https), so the image is bookworm (host tools) and the stretch
# cross packages are fetched over https, sha256-checked, and unpacked with dpkg -x.
# Pinned for both host architectures: arm64 (Apple silicon) and amd64 (GitHub runners).
FROM debian:bookworm-slim
COPY ca/ /tmp/ca/
RUN if [ -s /tmp/ca/host-ca.pem ]; then mkdir -p /etc/ssl/certs && cp /tmp/ca/host-ca.pem /etc/ssl/certs/ca-certificates.crt; \
      sed -i "s|http://deb.debian.org|https://deb.debian.org|g" /etc/apt/sources.list.d/debian.sources; fi \
 && apt-get update && apt-get install -y --no-install-recommends \
      make bc bison flex perl python3 xz-utils lz4 u-boot-tools kmod file gcc libc6-dev libmpc3 libgmp10 \
      wget ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG A=https://archive.debian.org/debian
ARG TARGETARCH
RUN set -e; arch="${TARGETARCH:-$(dpkg --print-architecture)}"; mkdir -p /tmp/debs; cd /tmp/debs; \
    grep " $arch " > list <<'EOF' || { echo "no pinned stretch packages for $arch"; exit 1; }
4214e30871db76cd40593c0ea58619eecf0301960f98898d373cb32507da794c arm64 pool/main/g/gcc-6-cross/gcc-6-arm-linux-gnueabihf_6.3.0-18cross1_arm64.deb
2ac21185f315a8c444d0b0265a11c1d4eba7ecbea09d690acb946a152be7364b arm64 pool/main/g/gcc-6-cross/cpp-6-arm-linux-gnueabihf_6.3.0-18cross1_arm64.deb
814bb7f07bbed57cc09ea8469024cefd0e78dd64339417a4dc79780d923adeb2 arm64 pool/main/b/binutils/binutils-arm-linux-gnueabihf_2.28-5_arm64.deb
c18642a6a7b3c00bf63bd0013b3e9450e51e4c038d9f672e58c3560ba053e1ca arm64 pool/main/g/gcc-6-cross/libgcc-6-dev-armhf-cross_6.3.0-18cross1_all.deb
310a03ae4cb33443d7e6d8c0cc62dd980c20546d28beed01a1e7171fb4820ec8 arm64 pool/main/i/isl/libisl15_0.18-1_arm64.deb
4223cbf0e4d3ed17765834cbca6a5133a6ee1f067e19d6113f90c716697ccf07 arm64 pool/main/m/mpfr4/libmpfr4_3.1.5-1_arm64.deb
364f4868baded819ee825ecabc49323863d6cad0b691dd4daa65338a304f3200 amd64 pool/main/g/gcc-6-cross/gcc-6-arm-linux-gnueabihf_6.3.0-18cross1_amd64.deb
f4fe74043ae22047bebb4644232c0e3a19cda1465ed4bc87bfc98d4f379530db amd64 pool/main/g/gcc-6-cross/cpp-6-arm-linux-gnueabihf_6.3.0-18cross1_amd64.deb
5c3d94b88160ae79eeaf4775700f1b7b88c4a7d380efe1709ddcc2942d77b891 amd64 pool/main/b/binutils/binutils-arm-linux-gnueabihf_2.28-5_amd64.deb
c18642a6a7b3c00bf63bd0013b3e9450e51e4c038d9f672e58c3560ba053e1ca amd64 pool/main/g/gcc-6-cross/libgcc-6-dev-armhf-cross_6.3.0-18cross1_all.deb
7f0a81e458df5e9648252bf3a76ffd57f366a0ddcab5290a9c3bb5bc0c79e513 amd64 pool/main/i/isl/libisl15_0.18-1_amd64.deb
95730a4709b898ffaf677f9b3ab6f6ebef5a96866589a8cf5f775448b3413a98 amd64 pool/main/m/mpfr4/libmpfr4_3.1.5-1_amd64.deb
EOF
RUN set -e; cd /tmp/debs; while read sha arch path; do \
      f=$(basename "$path"); wget -q -T 60 -t 3 -O "$f" "$A/$path"; \
      echo "$sha  $f" | sha256sum -c - >/dev/null; dpkg -x "$f" /; \
    done < list
RUN ln -sf arm-linux-gnueabihf-gcc-6 /usr/bin/arm-linux-gnueabihf-gcc \
 && ln -sf arm-linux-gnueabihf-cpp-6 /usr/bin/arm-linux-gnueabihf-cpp \
 && rm -rf /tmp/debs /tmp/ca && ldconfig \
 && arm-linux-gnueabihf-gcc --version | head -1 && arm-linux-gnueabihf-ld --version | head -1
