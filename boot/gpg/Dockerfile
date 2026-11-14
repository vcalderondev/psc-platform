# Small image with GnuPG 1.x (the console runs gpg 1.4.7) and GNU tar, for packing and
# signing Lumen's boot payload. Nothing secret is baked in: the console keyring is
# mounted read-only at run time and copied to the container's /tmp.
FROM debian:bookworm-slim
# optional corporate/host CA (git-ignored toolchain/host-ca.pem, copied by build-payload.sh)
COPY ca/ /tmp/ca/
RUN if [ -s /tmp/ca/host-ca.pem ]; then mkdir -p /etc/ssl/certs && cp /tmp/ca/host-ca.pem /etc/ssl/certs/ca-certificates.crt; \
      sed -i "s|http://deb.debian.org|https://deb.debian.org|g" /etc/apt/sources.list.d/debian.sources; fi \
 && apt-get update && apt-get install -y --no-install-recommends gnupg1 tar gzip ca-certificates \
 && rm -rf /var/lib/apt/lists/* /tmp/ca
