#!/bin/sh
# vpnpool installer / updater for OpenWrt.
#
# Works on BOTH package managers and picks the right one by itself:
#   - OpenWrt 25.12+  -> apk  (packages are .apk, index packages.adb)
#   - OpenWrt <= 24.10 -> opkg (packages are .ipk)
#
# One-liner (install or update to the latest release):
#   sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
# or, if your wget lacks process substitution support:
#   wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh && sh /tmp/vpnpool-install.sh
#
# What it does:
#   1. refreshes the package lists (apk update / opkg update),
#   2. makes sure HTTPS downloads work (ca-bundle),
#   3. downloads the latest vpnpool + luci-app-vpnpool from GitHub Releases in the
#      format your router uses (.apk or .ipk; our packages are arch-independent -
#      one file fits every router),
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
# AmneziaWG nodes: set VPNPOOL_AWG=1 to replace the stock sing-box with the AmneziaWG
# fork (hoaxisr/amnezia-box, sing-box 1.13.13 + AWG2). Stock sing-box cannot do AmneziaWG.
# Prebuilt per-arch (aarch64 / mipsel); flash routers get it in /usr/bin/sing-box (held so a
# feed upgrade can't revert it), RAM routers fetch it into /tmp via the WAN-up hook. NOTE:
# podkop (if installed) shares /usr/bin/sing-box and will also run on the fork. One-liner:
#   VPNPOOL_AWG=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
#
# Env overrides:
#   VPNPOOL_VERSION=v1.5.0   install a specific release tag instead of latest
#                            (.apk packages exist from v1.5.0 on)
#   VPNPOOL_PKG_DIR=/tmp/x   install the vpnpool + luci-app-vpnpool files already
#                            copied to this directory (no GitHub download at all)
#   VPNPOOL_RAM_SINGBOX=1    16 MB flash mode: sing-box lives in RAM (see above)
#   VPNPOOL_AWG=1            replace sing-box with the AmneziaWG fork (see above)
set -eu

REPO="roman-png/VPNpool"
TAG="${VPNPOOL_VERSION:-latest}"
PKG_DIR="${VPNPOOL_PKG_DIR:-}"
RAM_SINGBOX="${VPNPOOL_RAM_SINGBOX:-0}"
AWG="${VPNPOOL_AWG:-0}"
# AmneziaWG sing-box fork (prebuilt). Pinned; verified by sha256 from the release.
AWG_REPO="hoaxisr/amnezia-box"
AWG_TAG="v1.13.13-awg2.1"
AWG_URL=""; AWG_SHA=""        # resolved per-arch by awg_resolve()
TMP="/tmp/vpnpool-install"

HOOK="/etc/hotplug.d/iface/99-vpnpool-singbox-ram"

say()  { echo "[vpnpool] $*"; }
die()  { echo "[vpnpool] ERROR: $*" >&2; exit 1; }

[ "$(id -u 2>/dev/null || echo 0)" = "0" ] || die "run as root"

# --- package manager: apk (OpenWrt 25.12+) or opkg (OpenWrt <= 24.10) --------
# Everything below goes through the pm_* helpers, so the rest of the installer
# does not care which generation of OpenWrt it runs on.
if command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; then
	PM=apk; EXT=apk
elif command -v opkg >/dev/null 2>&1; then
	PM=opkg; EXT=ipk
else
	die "neither apk nor opkg found - is this OpenWrt?"
fi

# lightweight deps of vpnpool (everything it needs EXCEPT sing-box) — used by the
# small-flash flow, which installs sing-box into RAM separately. On apk the RAM copy
# is a bare extracted binary, so sing-box's own small deps (kmod-tun, kmod-inet-diag)
# go to flash here; opkg -d ram pulls them in by itself.
LIGHT_DEPS="jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full luci-base ca-bundle"
[ "$PM" = apk ] && LIGHT_DEPS="$LIGHT_DEPS kmod-tun kmod-inet-diag"

pm_update() {
	if [ "$PM" = apk ]; then apk update; else opkg update; fi
}
# install packages from the feeds
pm_add() {
	if [ "$PM" = apk ]; then apk add "$@"; else opkg install "$@"; fi
}
# install/upgrade our downloaded package files (dependencies from the feeds).
# apk: a local file isn't covered by the feed signature -> --allow-untrusted; apk
# pins a file install to its checksum, so `apk upgrade` never swaps it behind our back.
pm_add_files() {
	if [ "$PM" = apk ]; then apk add --allow-untrusted "$@"; else opkg install --force-reinstall "$@"; fi
}
# architectures this router accepts (one per line)
pm_arches() {
	if [ "$PM" = apk ]; then apk --print-arch 2>/dev/null; else opkg print-architecture 2>/dev/null | awk '{print $2}'; fi
}
# installed version of a package ("" if not installed)
pm_installed_ver() {
	if [ "$PM" = apk ]; then
		apk list -I "$1" 2>/dev/null | sed -n "s/^$1-\([0-9][^ ]*\) .*/\1/p" | head -n1
	else
		opkg list-installed "$1" 2>/dev/null | awk -v p="$1" '$1==p{print $3}' | head -n1
	fi
}
# keep a package at its installed version so an upgrade can't replace it.
# opkg: a hold flag in its status DB (NOT a line in opkg.conf, which opkg rejects).
# apk:  no hold flag - pin the exact installed version in /etc/apk/world instead.
pm_hold() {
	if [ "$PM" = apk ]; then
		v="$(pm_installed_ver "$1")"
		[ -n "$v" ] && apk add "$1=$v" >/dev/null 2>&1
	else
		opkg flag hold "$1" >/dev/null 2>&1
	fi
}

# sing-box -> RAM (/tmp/usr/bin/sing-box). Shared verbatim by the "install now" step
# and the WAN-up boot hook, so both do exactly the same thing; sets sb_ok=1/0.
# opkg: OpenWrt predefines `dest ram /tmp` in /etc/opkg.conf.
# apk:  has no install destinations - fetch the feed package and extract only the binary.
#       OpenWrt signs the feed INDEX, not single packages: `apk fetch` verifies the file
#       against the signed index (a tampered file fails with "file integrity error"), but
#       `apk extract` of that standalone file then needs --allow-untrusted.
if [ "$PM" = apk ]; then
	SB_RAM='sb_ok=0; d=/tmp/vpnpool-sb; rm -rf "$d"; mkdir -p "$d/x" /tmp/usr/bin
if apk fetch -o "$d" sing-box >/dev/null && apk extract --allow-untrusted --destination "$d/x" "$d"/sing-box-[0-9]*.apk >/dev/null; then
    rm -f "$d"/*.apk
    [ -s "$d/x/usr/bin/sing-box" ] && mv -f "$d/x/usr/bin/sing-box" /tmp/usr/bin/sing-box && sb_ok=1
fi
rm -rf "$d"'
else
	SB_RAM='sb_ok=0; opkg install -d ram --force-reinstall --force-overwrite sing-box && sb_ok=1'
fi

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

# --- AmneziaWG fork: resolve the prebuilt binary URL + sha256 for this router's arch ---
# Sets AWG_URL/AWG_SHA on success; returns 1 (and warns) if no prebuilt fits the arch.
awg_resolve() {
	local a asset base sums
	asset=""
	for a in $(pm_arches); do
		case "$a" in
			aarch64*) asset="sing-box-1.13.13-awg2.1-entware-aarch64"; break ;;
			mipsel*)  asset="sing-box-1.13.13-awg2.1-entware-mipsel";  break ;;
		esac
	done
	if [ -z "$asset" ]; then
		say "AWG: no prebuilt fork for this arch ($(pm_arches | tr '\n' ' '))- keeping stock sing-box (no AmneziaWG)"
		return 1
	fi
	base="https://github.com/$AWG_REPO/releases/download/$AWG_TAG"
	AWG_URL="$base/$asset"
	AWG_SHA=""
	sums="$TMP/awg.sums"
	if download "$base/checksums.txt" "$sums" 2>/dev/null; then
		AWG_SHA="$(grep -F "$asset" "$sums" 2>/dev/null | awk '{print $1}' | head -n1)"
	fi
	[ -n "$AWG_SHA" ] || say "AWG: warning - could not fetch checksum (will install without sha256 verification)"
	return 0
}

# Download the AWG fork binary to $1 and verify sha256 (if known). Returns 1 on failure.
awg_fetch_to() {
	local dest="$1" got
	download "$AWG_URL" "$dest" || { say "AWG: download failed"; return 1; }
	if [ -n "$AWG_SHA" ]; then
		got="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
		if [ "$got" != "$AWG_SHA" ]; then
			say "AWG: sha256 mismatch (want $AWG_SHA got $got) - aborting"; rm -f "$dest"; return 1
		fi
	fi
	chmod +x "$dest"
	return 0
}

say "package manager: $PM (.$EXT packages)"
say "refreshing package lists..."
pm_update >/dev/null 2>&1 || say "warning: $PM update had errors (continuing)"

# HTTPS to api.github.com needs CA certificates; install if missing.
if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/certs/ca-bundle.crt ]; then
	say "installing ca-bundle for HTTPS..."
	pm_add ca-bundle >/dev/null 2>&1 || pm_add ca-certificates >/dev/null 2>&1 || \
		say "warning: could not install CA bundle (HTTPS download may fail)"
fi

# Our package files, per format:
#   .apk: vpnpool-1.5.0-r1.apk        luci-app-vpnpool-1.5.0-r1.apk
#   .ipk: vpnpool_1.5.0-r1_all.ipk    luci-app-vpnpool_1.5.0-r1_all.ipk
if [ "$PM" = apk ]; then
	BASE_GLOB="vpnpool-[0-9]*.apk"; LUCI_GLOB="luci-app-vpnpool-[0-9]*.apk"
	ASSET_RE='/(vpnpool|luci-app-vpnpool)-[0-9][^/]*\.apk$'
else
	BASE_GLOB="vpnpool_*.ipk"; LUCI_GLOB="luci-app-vpnpool_*.ipk"
	ASSET_RE='/(vpnpool|luci-app-vpnpool)_[^/]*\.ipk$'
fi

if [ -n "$PKG_DIR" ]; then
	# --- offline: files already copied to the router ---------------------------
	[ -d "$PKG_DIR" ] || die "VPNPOOL_PKG_DIR=$PKG_DIR is not a directory"
	say "using local package files from $PKG_DIR"
	for f in "$PKG_DIR"/$BASE_GLOB "$PKG_DIR"/$LUCI_GLOB; do
		[ -f "$f" ] && cp "$f" "$TMP/"
	done
else
	# --- resolve release asset URLs ------------------------------------------
	if [ "$TAG" = "latest" ]; then
		API="https://api.github.com/repos/$REPO/releases/latest"
	else
		API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
	fi

	say "looking up release ($TAG)..."
	URLS="$(download "$API" - | tr ',' '\n' | grep 'browser_download_url' \
		| sed -e 's/.*"browser_download_url": *"//' -e 's/".*//' | grep -E "$ASSET_RE" || true)"
	if [ -z "$URLS" ]; then
		[ "$PM" = apk ] && die "no .apk assets in release '$TAG' (apk packages for OpenWrt 25.12+ exist from v1.5.0 on; check your internet / the release page)"
		die "no .ipk assets found in release '$TAG' (check your internet / the release page)"
	fi

	# GitHub release downloads (github.com -> objects.githubusercontent.com) are the
	# flakiest hop on the target networks. Our GitHub Pages feed (github.io, served
	# by a CDN) mirrors the same files by filename (.ipk at the root, .apk under /apk/)
	# and is usually far more reachable — use it as a fallback for the "latest" build.
	PAGES="https://roman-png.github.io/$(echo "$REPO" | cut -d/ -f2)"
	[ "$PM" = apk ] && PAGES="$PAGES/apk"
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
fi

# --- install / upgrade ------------------------------------------------------
# Install base package first (luci-app depends on it); a re-run upgrades in place.
# The conffile /etc/config/vpnpool is kept by both opkg and apk.
PKG_BASE="$(ls "$TMP"/$BASE_GLOB 2>/dev/null | head -n1)"
PKG_LUCI="$(ls "$TMP"/$LUCI_GLOB 2>/dev/null | head -n1)"
[ -n "$PKG_BASE" ] || die "vpnpool .$EXT package not found"

write_ram_hook() {
	# Boot hook: (re)install sing-box into RAM and start vpnpool when WAN comes up.
	# Runs on every reboot, so the router needs working internet at startup.
	mkdir -p /etc/hotplug.d/iface
	# Remove any OTHER vpnpool iface hooks first. Two hooks both installing sing-box
	# into RAM in parallel on a low-RAM router race each other, OOM mid-extraction
	# and leave a corrupt/non-executable binary.
	for f in /etc/hotplug.d/iface/*vpnpool* /etc/hotplug.d/iface/*singbox-ram*; do
		[ -e "$f" ] && [ "$f" != "$HOOK" ] && rm -f "$f"
	done
	{
		echo '#!/bin/sh'
		echo "# vpnpool small-flash boot hook ($PM): sing-box lives in RAM, reinstalled on WAN up."
		echo '[ "$ACTION" = "ifup" -a "$INTERFACE" = "wan" ] && {'
		if [ -n "$AWG_URL" ]; then
			# AWG variant: fetch the fork binary (not a package) into RAM. Falls back to the
			# stock feed sing-box if the fork download/sha fails, so the tunnel still comes up.
			cat <<EOF
    logger -t vpnpool "WAN up: fetching AmneziaWG sing-box fork into RAM"
    mkdir -p /tmp/usr/bin
    if uclient-fetch -T 30 -qO /tmp/usr/bin/sing-box "$AWG_URL" \\
       && { [ -z "$AWG_SHA" ] || echo "$AWG_SHA  /tmp/usr/bin/sing-box" | sha256sum -c >/dev/null 2>&1; }; then
        logger -t vpnpool "AWG sing-box fork in RAM"
    else
        logger -t vpnpool "AWG fork fetch failed - falling back to stock sing-box"
        $PM update
EOF
			printf '%s\n' "$SB_RAM" | sed 's/^/        /'
			echo '    fi'
		else
			echo '    logger -t vpnpool "WAN up: installing sing-box into RAM"'
			echo "    $PM update"
			printf '%s\n' "$SB_RAM" | sed 's/^/    /'
		fi
		cat <<'EOF'
    chmod +x /tmp/usr/bin/sing-box 2>/dev/null
    ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
    /etc/init.d/vpnpool start
    logger -t vpnpool "sing-box in RAM, vpnpool started"
}
EOF
	} > "$HOOK"
	chmod +x "$HOOK"
}

if [ "$RAM_SINGBOX" = 1 ]; then
	# === 16 MB flash flow: sing-box lives in RAM, vpnpool stays in flash ========
	say "small-flash mode: sing-box will live in RAM (/tmp), reinstalled on every boot"
	# AmneziaWG fork: resolve the per-arch prebuilt up front so the WAN-up hook fetches it.
	[ "$AWG" = 1 ] && { awg_resolve || AWG=0; }

	say "installing zram-swap (more usable memory for the package manager)..."
	if pm_add zram-swap >/dev/null 2>&1; then
		/etc/init.d/zram enable >/dev/null 2>&1 || true
		/etc/init.d/zram start  >/dev/null 2>&1 || true
	else
		say "warning: zram-swap not installed (continuing)"
	fi

	say "installing lightweight dependencies (no sing-box)..."
	# shellcheck disable=SC2086
	pm_add $LIGHT_DEPS >/dev/null 2>&1 || say "warning: some dependencies failed (continuing)"

	# Keep the ~38 MB sing-box OUT of flash while vpnpool still depends on it.
	if [ "$PM" = apk ]; then
		# apk has no --nodeps: register an empty placeholder package named sing-box
		# (its version is a timestamp, so `apk upgrade` never swaps it for the real one).
		# The real binary lives in /tmp/usr/bin/sing-box (see SB_RAM).
		if [ -z "$(pm_installed_ver sing-box)" ]; then
			say "registering a placeholder sing-box package (the real binary lives in RAM)..."
			apk add --virtual sing-box >/dev/null 2>&1 || die "could not create the sing-box placeholder"
		fi
		say "installing vpnpool packages (flash-only)..."
		# shellcheck disable=SC2086
		pm_add_files "$PKG_BASE" ${PKG_LUCI:+"$PKG_LUCI"} || die "failed to install vpnpool"
	else
		# --nodeps so opkg won't try to drag sing-box into flash
		say "installing vpnpool packages (--nodeps, flash-only)..."
		opkg install --nodeps --force-reinstall "$PKG_BASE" || die "failed to install vpnpool"
		[ -n "$PKG_LUCI" ] && { opkg install --nodeps --force-reinstall "$PKG_LUCI" || say "warning: luci-app-vpnpool install failed (CLI still works)"; }
	fi

	# Don't autostart at boot — sing-box isn't present until the WAN-up hook runs.
	/etc/init.d/vpnpool disable >/dev/null 2>&1 || true

	say "installing boot hook ($HOOK)..."
	write_ram_hook

	say "installing sing-box into RAM now (so it works without a reboot)..."
	sb_ok=0
	if [ -n "$AWG_URL" ]; then
		mkdir -p /tmp/usr/bin
		if awg_fetch_to /tmp/usr/bin/sing-box; then
			sb_ok=1
			say "AmneziaWG sing-box fork installed in RAM."
		else
			say "warning: AWG fork fetch failed; falling back to stock sing-box in RAM"
			eval "$SB_RAM" || sb_ok=0
		fi
	else
		eval "$SB_RAM" || sb_ok=0
	fi
	if [ "$sb_ok" = 1 ]; then
		chmod +x /tmp/usr/bin/sing-box 2>/dev/null
		ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
		say "sing-box in RAM: $(/usr/bin/sing-box version 2>/dev/null | head -1)"
	else
		say "warning: could not install sing-box into RAM now; it will be installed on the next WAN-up / reboot"
	fi
else
	# === normal flow: sing-box installed into flash from the standard feeds =====
	say "installing packages (dependencies come from the standard feeds)..."
	if [ "$PM" = apk ]; then
		# one transaction: the luci package's dependency on vpnpool resolves to the file
		# shellcheck disable=SC2086
		pm_add_files "$PKG_BASE" ${PKG_LUCI:+"$PKG_LUCI"} || die "failed to install vpnpool (dependencies missing? run 'apk update')"
	else
		pm_add_files "$PKG_BASE" || die "failed to install vpnpool (dependencies missing? run 'opkg update')"
		[ -n "$PKG_LUCI" ] && { pm_add_files "$PKG_LUCI" || say "warning: luci-app-vpnpool install failed (CLI still works)"; }
	fi

	# AmneziaWG fork: replace the just-installed stock sing-box in flash and hold it so a
	# feed upgrade can't revert it. podkop (if present) shares this binary and rides along.
	if [ "$AWG" = 1 ]; then
		if awg_resolve && awg_fetch_to /usr/bin/sing-box; then
			pm_hold sing-box || true
			say "AmneziaWG sing-box fork installed (held): $(/usr/bin/sing-box version 2>/dev/null | head -1)"
		else
			say "AWG: keeping stock sing-box (no AmneziaWG support)"
		fi
	fi
fi

# refresh LuCI caches so the menu appears immediately
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
/etc/init.d/rpcd reload >/dev/null 2>&1 || true

rm -rf "$TMP"
[ "$AWG" = 1 ] && [ -n "$AWG_URL" ] && say "AmneziaWG: enabled (fork sing-box). Import an .conf or vpn:// link on the Sources tab."
say "installed: vpnpool $(pm_installed_ver vpnpool)${PKG_LUCI:+, luci-app-vpnpool $(pm_installed_ver luci-app-vpnpool)}"
if [ "$RAM_SINGBOX" = 1 ]; then
	say "done (small-flash mode). Open LuCI -> Services -> VPN Pool, set your subscription URL."
	say "sing-box is in RAM now; after setting the subscription, start it: /etc/init.d/vpnpool start"
	say "On every reboot the WAN-up hook reinstalls sing-box into RAM and starts vpnpool automatically."
	say "If your WAN interface is not named 'wan' (e.g. wan6/wwan), edit INTERFACE in $HOOK."
else
	say "done. Open LuCI -> Services -> VPN Pool, set your subscription URL and turn it ON."
	say "(CLI: edit /etc/config/vpnpool, then /etc/init.d/vpnpool enable && /etc/init.d/vpnpool start)"
fi
