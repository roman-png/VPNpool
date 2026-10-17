# vpnpool local debug stand.
# OpenWrt rootfs base => real uci / ubus / ubusd / rpcd / ucode / opkg|apk, the same
# userland the package runs on in production.
#
# Build args:
#   OPENWRT_VER  rootfs release. Default 24.10.4 (opkg). 25.12.4 (apk) also works:
#                  docker build --build-arg OPENWRT_VER=25.12.4 -f stand/Dockerfile -t vpnpool-stand:25.12 .
#   SINGBOX_VER  upstream sing-box release overlaid on /usr/bin/sing-box (the feed version
#                lags behind what the package targets). Stock 1.12.x by default.
#   SINGBOX_URL  full download URL of a linux-amd64 tarball, to use a different build
#                (e.g. our AWG engine). Empty = upstream SagerNet release of SINGBOX_VER.
# A local binary can also be swapped in at RUN time without rebuilding: mount it and set
# SINGBOX_BIN (see entrypoint.sh), e.g. -v /path/sing-box:/opt/engine/sing-box:ro
#   -e SINGBOX_BIN=/opt/engine/sing-box
ARG OPENWRT_VER=24.10.4
FROM openwrt/rootfs:x86-64-${OPENWRT_VER}

ARG SINGBOX_VER=1.12.25
ARG SINGBOX_URL=

# Base image ships without /var/lock, which opkg needs for its lockfile.
# 24.10 and older: opkg. 25.12+: apk (pkg names are the same for what we need).
RUN mkdir -p /var/lock /var/run/ubus /tmp /etc/vpnpool /tmp/vpnpool /opt/stand/bin \
 && PKGS="jq curl ucode ucode-mod-fs ucode-mod-uci ip-full nftables openssl-util coreutils-base64" \
 && if command -v apk >/dev/null 2>&1; then \
      apk update && apk add $PKGS && (apk add kmod-nft-tproxy || true); \
    else \
      opkg update && opkg install $PKGS && (opkg install kmod-nft-tproxy || true); \
    fi \
 && jq --version && ucode -e 'print("ucode ok\n")'

# Overlay sing-box >= 1.12. Upstream linux-amd64 is a static Go binary, so it runs on the
# musl rootfs without extra libs.
RUN url="${SINGBOX_URL:-https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-amd64.tar.gz}" \
 && curl -fsSL "$url" -o /tmp/sb.tgz \
 && mkdir -p /tmp/sbx && tar -xzf /tmp/sb.tgz -C /tmp/sbx \
 && cp "$(find /tmp/sbx -type f -name sing-box | head -1)" /usr/bin/sing-box \
 && chmod +x /usr/bin/sing-box \
 && rm -rf /tmp/sb.tgz /tmp/sbx \
 && sing-box version

# logger shim: tee vpnpool log lines to stderr so the scripts' log() is visible off-router.
COPY stand/bin/logger /opt/stand/bin/logger
RUN chmod +x /opt/stand/bin/logger
ENV PATH=/opt/stand/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY stand/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
