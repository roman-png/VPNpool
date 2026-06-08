#!/bin/sh
# vpnpool installer / updater for OpenWrt.
#
# One-liner (install or update to the latest release):
#   sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
# or, if your wget lacks process substitution support:
#   wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh && sh /tmp/vpnpool-install.sh
#
# What it does:
#   1. refreshes opkg feeds (so dependencies like sing-box can be resolved),
#   2. makes sure HTTPS downloads work (ca-bundle),
#   3. downloads the latest vpnpool + luci-app-vpnpool .ipk from GitHub Releases
#      (our packages are arch-independent "_all" - one file fits every router),
#   4. installs/upgrades them, pulling dependencies from the standard feeds.
#
# Your settings in /etc/config/vpnpool (subscription, Telegram, routing) are a
# conffile and are preserved across upgrades.
#
# Small-flash routers (16 MB): set VPNPOOL_RAM_SINGBOX=1 to install sing-box into
# RAM instead of flash. vpnpool stays in flash (~128 KB); sing-box is (re)installed
# into /tmp on every boot via a WAN-up hotplug hook. One-liner:
#   VPNPOOL_RAM_SINGBOX=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
#
# Env overrides:
#   VPNPOOL_VERSION=v1.0.0   install a specific release tag instead of latest
#   VPNPOOL_RAM_SINGBOX=1    16 MB flash mode: sing-box lives in RAM (see above)
set -eu

REPO="roman-png/VPNpool"
TAG="${VPNPOOL_VERSION:-latest}"
RAM_SINGBOX="${VPNPOOL_RAM_SINGBOX:-0}"
TMP="/tmp/vpnpool-install"
PKGS="vpnpool luci-app-vpnpool"

# lightweight deps of vpnpool (everything it needs EXCEPT sing-box) — used by the
# small-flash flow, which installs sing-box into RAM separately.
LIGHT_DEPS="jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full luci-base ca-bundle"
HOOK="/etc/hotplug.d/iface/99-vpnpool-singbox-ram"

say()  { echo "[vpnpool] $*"; }
die()  { echo "[vpnpool] ERROR: $*" >&2; exit 1; }

[ "$(id -u 2>/dev/null || echo 0)" = "0" ] || die "run as root"
command -v opkg >/dev/null 2>&1 || die "opkg not found - is this OpenWrt?"

rm -rf "$TMP"; mkdir -p "$TMP"

# --- pick a downloader (uclient-fetch / wget / curl), all HTTPS-capable ------
# Retries a few times: GitHub (api.github.com / release downloads) is frequently
# flaky or throttled on the networks this tool targets — a single 504/timeout
# must not abort the whole install. Always fetches to a file (stdout requests
# stream the file out afterwards) so a failed attempt can be retried cleanly.
DL_RETRIES=4
download() {
	# download <url> <outfile|->
	url="$1"; out="$2"
	dst="$out"; [ "$out" = "-" ] && dst="$TMP/.dl.$$"
	n=0; ok=0
	while [ "$n" -lt "$DL_RETRIES" ]; do
		n=$((n + 1))
		if command -v uclient-fetch >/dev/null 2>&1; then
			uclient-fetch -T 30 -qO "$dst" "$url" && { ok=1; break; }
		elif command -v curl >/dev/null 2>&1; then
			curl -fsSL --connect-timeout 30 -o "$dst" "$url" && { ok=1; break; }
		elif command -v wget >/dev/null 2>&1; then
			wget -T 30 -qO "$dst" "$url" && { ok=1; break; }
		else
			die "no downloader (uclient-fetch/curl/wget) available"
		fi
		[ "$n" -lt "$DL_RETRIES" ] && { say "download attempt $n failed (GitHub can be flaky), retrying in 3s..."; sleep 3; }
	done
	[ "$ok" = 1 ] || return 1
	if [ "$out" = "-" ]; then cat "$dst"; rm -f "$dst"; fi
	return 0
}

say "refreshing package lists..."
opkg update >/dev/null 2>&1 || say "warning: opkg update had errors (continuing)"

# HTTPS to api.github.com needs CA certificates; install if missing.
if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/certs/ca-bundle.crt ]; then
	say "installing ca-bundle for HTTPS..."
	opkg install ca-bundle >/dev/null 2>&1 || opkg install ca-certificates >/dev/null 2>&1 || \
		say "warning: could not install CA bundle (HTTPS download may fail)"
fi

# --- resolve release asset URLs --------------------------------------------
if [ "$TAG" = "latest" ]; then
	API="https://api.github.com/repos/$REPO/releases/latest"
else
	API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

say "looking up release ($TAG)..."
URLS="$(download "$API" - | tr ',' '\n' | grep 'browser_download_url' | grep '\.ipk' \
	| sed -e 's/.*"browser_download_url": *"//' -e 's/".*//' | grep -E '/(vpnpool|luci-app-vpnpool)_')"
[ -n "$URLS" ] || die "no .ipk assets found in release '$TAG' (check your internet / the release page)"

# GitHub release downloads (github.com -> objects.githubusercontent.com) are the
# flakiest hop on the target networks. Our GitHub Pages feed (github.io, served
# by a CDN) mirrors the same _all .ipk by filename and is usually far more
# reachable — use it as a fallback for the "latest" build.
PAGES="https://roman-png.github.io/$(echo "$REPO" | cut -d/ -f2)"
for u in $URLS; do
	bn="$(basename "$u")"
	f="$TMP/$bn"
	say "downloading $bn..."
	if ! download "$u" "$f"; then
		if [ "$TAG" = "latest" ]; then
			say "release download failed; trying Pages mirror ($PAGES)..."
			download "$PAGES/$bn" "$f" || die "download failed (GitHub and Pages both unreachable): $bn"
		else
			die "download failed: $u"
		fi
	fi
done

# --- install / upgrade ------------------------------------------------------
# Install base package first (luci-app depends on it), force-reinstall so a
# re-run upgrades in place. The conffile /etc/config/vpnpool is kept by opkg.
IPK_BASE="$(ls "$TMP"/vpnpool_*.ipk 2>/dev/null | head -n1)"
IPK_LUCI="$(ls "$TMP"/luci-app-vpnpool_*.ipk 2>/dev/null | head -n1)"
[ -n "$IPK_BASE" ] || die "vpnpool .ipk not downloaded"

write_ram_hook() {
	# Boot hook: (re)install sing-box into RAM and start vpnpool when WAN comes up.
	# Runs on every reboot, so the router needs working internet at startup.
	mkdir -p /etc/hotplug.d/iface
	cat > "$HOOK" <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" -a "$INTERFACE" = "wan" ] && {
    logger -t vpnpool "WAN up: installing sing-box into RAM"
    opkg update
    opkg install -d ram --force-reinstall --force-overwrite sing-box
    ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
    /etc/init.d/vpnpool start
    logger -t vpnpool "sing-box installed in RAM, vpnpool started"
}
EOF
	chmod +x "$HOOK"
}

if [ "$RAM_SINGBOX" = 1 ]; then
	# === 16 MB flash flow: sing-box lives in RAM, vpnpool stays in flash ========
	say "small-flash mode: sing-box will live in RAM (/tmp), reinstalled on every boot"

	say "installing zram-swap (more usable memory for opkg)..."
	if opkg install zram-swap >/dev/null 2>&1; then
		/etc/init.d/zram enable >/dev/null 2>&1 || true
		/etc/init.d/zram start  >/dev/null 2>&1 || true
	else
		say "warning: zram-swap not installed (continuing)"
	fi

	say "installing lightweight dependencies (no sing-box)..."
	# shellcheck disable=SC2086
	opkg install $LIGHT_DEPS >/dev/null 2>&1 || say "warning: some dependencies failed (continuing)"

	# --nodeps so opkg won't try to drag sing-box (~38 MB) into flash
	say "installing vpnpool packages (--nodeps, flash-only)..."
	opkg install --nodeps --force-reinstall "$IPK_BASE" || die "failed to install vpnpool"
	[ -n "$IPK_LUCI" ] && { opkg install --nodeps --force-reinstall "$IPK_LUCI" || say "warning: luci-app-vpnpool install failed (CLI still works)"; }

	# Don't autostart at boot — sing-box isn't present until the WAN-up hook runs.
	/etc/init.d/vpnpool disable >/dev/null 2>&1 || true

	say "installing boot hook ($HOOK)..."
	write_ram_hook

	say "installing sing-box into RAM now (so it works without a reboot)..."
	if opkg install -d ram --force-reinstall --force-overwrite sing-box; then
		ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
		say "sing-box installed in RAM."
	else
		say "warning: could not install sing-box into RAM now; it will be installed on the next WAN-up / reboot"
	fi
else
	# === normal flow: sing-box installed into flash from the standard feeds =====
	say "installing packages (dependencies come from the standard feeds)..."
	opkg install --force-reinstall "$IPK_BASE" || die "failed to install vpnpool (dependencies missing? run 'opkg update')"
	[ -n "$IPK_LUCI" ] && { opkg install --force-reinstall "$IPK_LUCI" || say "warning: luci-app-vpnpool install failed (CLI still works)"; }
fi

# refresh LuCI caches so the menu appears immediately
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
/etc/init.d/rpcd reload >/dev/null 2>&1 || true

rm -rf "$TMP"
if [ "$RAM_SINGBOX" = 1 ]; then
	say "done (small-flash mode). Open LuCI -> Services -> VPN Pool, set your subscription URL."
	say "sing-box is in RAM now; after setting the subscription, start it: /etc/init.d/vpnpool start"
	say "On every reboot the WAN-up hook reinstalls sing-box into RAM and starts vpnpool automatically."
	say "If your WAN interface is not named 'wan' (e.g. wan6/wwan), edit INTERFACE in $HOOK."
else
	say "done. Open LuCI -> Services -> VPN Pool, set your subscription URL and turn it ON."
	say "(CLI: edit /etc/config/vpnpool, then /etc/init.d/vpnpool enable && /etc/init.d/vpnpool start)"
fi
