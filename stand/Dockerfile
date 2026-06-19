# vpnpool local debug stand.
# OpenWrt rootfs base => real uci / ubus / ubusd / rpcd / ucode / opkg, the same
# userland the package runs on in production. sing-box from the feed is 1.11.x (< the
# 1.12 the package targets), so we overlay the official static linux-amd64 binary.
FROM openwrt/rootfs:x86-64-23.05.5

ARG SINGBOX_VER=1.12.25

# Base image ships without /var/lock, which opkg needs for its lockfile.
RUN mkdir -p /var/lock /var/run/ubus /tmp /etc/vpnpool /tmp/vpnpool /opt/stand/bin \
 && opkg update \
 && opkg install jq curl ucode ucode-mod-fs ucode-mod-uci ip-full nftables openssl-util coreutils-base64 \
 && (opkg install kmod-nft-tproxy || true)

# Overlay sing-box >= 1.12 (feed is 1.11.x). Upstream linux-amd64 is a static Go binary,
# so it runs on the musl rootfs without extra libs.
RUN curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-amd64.tar.gz" -o /tmp/sb.tgz \
 && tar -xzf /tmp/sb.tgz -C /tmp \
 && cp "/tmp/sing-box-${SINGBOX_VER}-linux-amd64/sing-box" /usr/bin/sing-box \
 && chmod +x /usr/bin/sing-box \
 && rm -rf /tmp/sb.tgz "/tmp/sing-box-${SINGBOX_VER}-linux-amd64" \
 && sing-box version

# logger shim: tee vpnpool log lines to stderr so the scripts' log() is visible off-router.
COPY stand/bin/logger /opt/stand/bin/logger
RUN chmod +x /opt/stand/bin/logger
ENV PATH=/opt/stand/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY stand/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
