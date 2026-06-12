#!/bin/sh
# One-click installer for a SEPARATE zapret (remittor/zapret-openwrt), invoked from
# the vpnpool settings UI ("Install zapret"). Installs the NFQUEUE kmods + the
# arch-matched zapret core ipk so smart_bypass can then orchestrate it. Writes a
# JSON result to a temp file for the UI to poll. We never bundle nfqws — this just
# fetches the upstream package for the router's own architecture.
. /usr/libexec/vpnpool/lib.sh 2>/dev/null
REPO=remittor/zapret-openwrt
OUT=/tmp/vpnpool/.zapret-install.json
WORK=/tmp/vpnpool/zi
mkdir -p /tmp/vpnpool

# Emit a JSON result (jq-built so log text with quotes can't corrupt it) and stop.
done_ok()  { jq -n --argjson a "${2:-false}" --arg arch "$3" --arg ver "$4" \
		'{ok:true, already:$a, arch:$arch, version:$ver}' > "$OUT"; exit 0; }
fail()     { jq -n --arg s "$1" --arg e "$2" '{ok:false, step:$s, error:$e}' > "$OUT"; exit 0; }

# Already installed?
if [ -x /etc/init.d/zapret ] && uci -q get zapret.config >/dev/null 2>&1; then
	done_ok "" true "" ""
fi

. /etc/openwrt_release 2>/dev/null
ARCH="$DISTRIB_ARCH"
[ -n "$ARCH" ] || fail arch "cannot detect router architecture"

# Flash space guard: a full zapret install (unzip + kmods + libs + core) needs a
# few MB. Warn-and-stop on a tiny overlay rather than filling the rootfs.
FREEKB=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')
case "$FREEKB" in (''|*[!0-9]*) FREEKB=0 ;; esac
[ "$FREEKB" -gt 0 ] && [ "$FREEKB" -lt 3000 ] && \
	fail space "only ${FREEKB}kB free on /overlay (need ~3MB) — too little flash for zapret"

# Dependencies from the official feed (NFQUEUE kmods + unzip + userspace lib).
opkg update >/tmp/vpnpool/.zi-upd.log 2>&1 || fail feed "opkg update failed — package feeds unreachable (check WAN)"
opkg install unzip kmod-nft-queue kmod-nfnetlink-queue libnetfilter-queue >/tmp/vpnpool/.zi-deps.log 2>&1 \
	|| fail deps "$(tail -2 /tmp/vpnpool/.zi-deps.log 2>/dev/null | tr '\n' ' ')"

# Resolve the arch-matched release asset (arch tokens may contain '-', e.g.
# aarch64_cortex-a53, so match the literal "_<arch>.zip" suffix).
API="https://api.github.com/repos/$REPO/releases/latest"
URL=$(curl -sL -m 25 "$API" 2>/dev/null | grep -oE "https://[^\"]+_${ARCH}\.zip" | head -1)
[ -n "$URL" ] || fail asset "no upstream zapret build for arch '$ARCH'"

# Download + unzip + install the core ipk (skip the optional luci-app-zapret).
rm -rf "$WORK"; mkdir -p "$WORK"
curl -sL -m 120 "$URL" -o "$WORK/z.zip" 2>/dev/null || fail download "download failed"
[ -s "$WORK/z.zip" ] || fail download "downloaded archive is empty"
unzip -o "$WORK/z.zip" -d "$WORK" >/dev/null 2>&1 || fail unzip "could not unpack the archive"
IPK=$(ls "$WORK"/zapret_*.ipk 2>/dev/null | grep -v luci-app | head -1)
[ -n "$IPK" ] || fail extract "core zapret ipk not found in the archive"
opkg install "$IPK" >/tmp/vpnpool/.zi-core.log 2>&1

if [ -x /etc/init.d/zapret ] && uci -q get zapret.config >/dev/null 2>&1; then
	ver=$(opkg list-installed 2>/dev/null | awk '/^zapret /{print $3; exit}')
	rm -rf "$WORK"
	done_ok "" false "$ARCH" "$ver"
else
	fail install "$(tail -3 /tmp/vpnpool/.zi-core.log 2>/dev/null | tr '\n' ' ')"
fi
