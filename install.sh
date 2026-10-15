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
# AmneziaWG nodes: set VPNPOOL_AWG=1 to ALSO install the AmneziaWG-capable sing-box build
# (vpnpool-engine) as a separate file /usr/bin/sing-box-awg. Stock sing-box cannot do
# AmneziaWG; it stays the standard package (podkop and the package manager keep using it).
# If an older vpnpool (1.4.x) replaced /usr/bin/sing-box with its AmneziaWG fork build, the
# standard package is put back once the new build is in place (podkop is restarted).
# Builds: aarch64, armv7 with FPU, mips/mipsel 24kc/34kc/74kc/1004kc, x86_64 - other routers
# are told so and keep working without AmneziaWG. The download is checked (sha256, version, a
# test config) before it replaces anything. Small-flash routers (VPNPOOL_RAM_SINGBOX=1) keep
# it in RAM next to sing-box, only on routers with 256 MB of RAM or more (MemTotal >= 200 MB,
# VPNPOOL_ENGINE_RAM_MIN_MB). One-liner:
#   VPNPOOL_AWG=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
# Update it later: VPNPOOL_AWG=update (same one-liner), or /usr/libexec/vpnpool/engine.sh update
#
# Env overrides:
#   VPNPOOL_VERSION=v1.5.0   install a specific release tag instead of latest
#                            (.apk packages exist from v1.5.0 on)
#   VPNPOOL_PKG_DIR=/tmp/x   install the vpnpool + luci-app-vpnpool files already
#                            copied to this directory (no GitHub download at all)
#   VPNPOOL_RAM_SINGBOX=1    16 MB flash mode: sing-box lives in RAM (see above)
#   VPNPOOL_AWG=1            add the AmneziaWG sing-box build (see above); =update updates it
#   VPNPOOL_ENGINE_VERSION=x that AmneziaWG build version instead of the pinned one
set -eu

REPO="roman-png/VPNpool"
TAG="${VPNPOOL_VERSION:-latest}"
PKG_DIR="${VPNPOOL_PKG_DIR:-}"
RAM_SINGBOX="${VPNPOOL_RAM_SINGBOX:-0}"
AWG="${VPNPOOL_AWG:-0}"
case "$AWG" in 0|1|update) ;; *) AWG=1 ;; esac
# AmneziaWG sing-box build: installed and checked by the package's own helper (pinned
# version, sha256, version + AWG check, atomic replace) - /usr/libexec/vpnpool/engine.sh
ENGINE=/usr/libexec/vpnpool/engine.sh
AWG_DONE=0
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

# --- AmneziaWG build (engine.sh from the just-installed package) -------------
# engine.sh prints one JSON line {ok, code, ...}; its code becomes a plain message here.
awg_explain() {
	case "$1" in
		E_ARCH)          echo "there is no AmneziaWG build for this router's processor${2:+ ($2)}" ;;
		E_RAM_TOTAL)     echo "this router has too little memory to keep the AmneziaWG build in RAM" ;;
		E_SPACE)         echo "not enough free space for the AmneziaWG build (about 50 MB is needed)" ;;
		E_MEM)           echo "not enough free memory right now to check the AmneziaWG build" ;;
		E_DOWNLOAD|E_SHA_UNKNOWN) echo "could not download the AmneziaWG build (check the internet connection and retry)" ;;
		E_SHA)           echo "the downloaded AmneziaWG build is damaged; nothing was changed, retry later" ;;
		E_VERSION|E_CHECK) echo "the downloaded AmneziaWG build does not work on this router; nothing was changed" ;;
		E_NOT_INSTALLED) echo "the AmneziaWG build is not installed yet (use VPNPOOL_AWG=1)" ;;
		E_BUSY)          echo "the AmneziaWG build is being installed by another run; retry in a minute" ;;
		E_NO_DOWNLOADER) echo "this router has no download tool (uclient-fetch or wget)" ;;
		*)               echo "could not install the AmneziaWG build" ;;
	esac
}
# awg_engine <install|update> [--ram] -> 0 if the build is in place and working
awg_engine() {
	[ -f "$ENGINE" ] || { say "AmneziaWG: this vpnpool version cannot install the AmneziaWG build"; return 1; }
	say "AmneziaWG: installing the AmneziaWG sing-box build (about 45 MB download)..."
	res="$(sh "$ENGINE" "$@" 2>/dev/null | tail -n1)"
	if printf '%s' "$res" | grep -q '"ok":true'; then
		v="$(printf '%s' "$res" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
		if printf '%s' "$res" | grep -q '"changed":false'; then
			say "AmneziaWG: build $v is already installed and up to date"
		else
			say "AmneziaWG: build $v installed"
		fi
		# an older vpnpool had put the old AmneziaWG build in place of the standard sing-box
		if printf '%s' "$res" | grep -q '"stock_restored":true'; then
			say "the standard sing-box is back in place of the old AmneziaWG build"
			printf '%s' "$res" | grep -q '"podkop_restarted":true' && say "podkop was restarted on the standard sing-box"
		elif printf '%s' "$res" | grep -q '"stock_restored":false'; then
			say "warning: the old AmneziaWG build still stands in place of the standard sing-box and could not be replaced now."
			say "         The new AmneziaWG build works anyway. To put the standard sing-box back later, run:"
			say "         /usr/libexec/vpnpool/engine.sh restore-stock"
		fi
		AWG_DONE=1
		return 0
	fi
	code="$(printf '%s' "$res" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')"
	pa="$(printf '%s' "$res" | sed -n 's/.*"pm_arch":"\([^"]*\)".*/\1/p')"
	say "AmneziaWG: $(awg_explain "$code" "$pa"). vpnpool works without it; AmneziaWG servers wait until it is installed."
	return 1
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

# Our package files, per format (+ the Russian translation of the web UI, built by LuCI's
# luci.mk; its version is the date of the translation, not the app's):
#   .apk: vpnpool-1.5.0-r1.apk        luci-app-vpnpool-1.5.0-r1.apk      luci-i18n-vpnpool-ru-<v>.apk
#   .ipk: vpnpool_1.5.0-r1_all.ipk    luci-app-vpnpool_1.5.0-r1_all.ipk  luci-i18n-vpnpool-ru_<v>_all.ipk
# The translation is always installed with the web UI (it is small): LuCI shows it when its
# language is Russian, or "auto" with a Russian browser (as the UI's own dictionary did).
if [ "$PM" = apk ]; then
	BASE_GLOB="vpnpool-[0-9]*.apk"; LUCI_GLOB="luci-app-vpnpool-[0-9]*.apk"; I18N_GLOB="luci-i18n-vpnpool-ru-[0-9]*.apk"
	ASSET_RE='/(vpnpool|luci-app-vpnpool|luci-i18n-vpnpool-ru)-[0-9][^/]*\.apk$'
else
	BASE_GLOB="vpnpool_*.ipk"; LUCI_GLOB="luci-app-vpnpool_*.ipk"; I18N_GLOB="luci-i18n-vpnpool-ru_*.ipk"
	ASSET_RE='/(vpnpool|luci-app-vpnpool|luci-i18n-vpnpool-ru)_[^/]*\.ipk$'
fi

if [ -n "$PKG_DIR" ]; then
	# --- offline: files already copied to the router ---------------------------
	[ -d "$PKG_DIR" ] || die "VPNPOOL_PKG_DIR=$PKG_DIR is not a directory"
	say "using local package files from $PKG_DIR"
	for f in "$PKG_DIR"/$BASE_GLOB "$PKG_DIR"/$LUCI_GLOB "$PKG_DIR"/$I18N_GLOB; do
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
PKG_I18N="$(ls "$TMP"/$I18N_GLOB 2>/dev/null | head -n1)"
[ -n "$PKG_LUCI" ] || PKG_I18N=""   # the translation needs the web UI
# the Russian translation of the web UI; a failure only leaves the UI in English
install_i18n() {   # $1 = extra opkg flag (--nodeps in the small-flash flow)
	[ -n "$PKG_I18N" ] || return 0
	if [ "$PM" = apk ]; then pm_add_files "$PKG_I18N" >/dev/null 2>&1
	else opkg install $1 --force-reinstall "$PKG_I18N" >/dev/null 2>&1; fi \
		|| say "warning: the Russian translation of the web interface was not installed (the interface stays in English)"
}
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
		echo '    logger -t vpnpool "WAN up: installing sing-box into RAM"'
		echo "    $PM update"
		printf '%s\n' "$SB_RAM" | sed 's/^/    /'
		cat <<'EOF'
    chmod +x /tmp/usr/bin/sing-box 2>/dev/null
    ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
EOF
		if [ "$AWG" != 0 ]; then
			# AmneziaWG build into RAM as well, through the same checked pipeline as the
			# "install now" step below (engine.sh: memory threshold, sha256, version, AWG check,
			# atomic). The stock sing-box above stays: if this fails, vpnpool simply runs
			# without its AmneziaWG servers.
			cat <<EOF
    ${VPNPOOL_ENGINE_VERSION:+VPNPOOL_ENGINE_VERSION=$VPNPOOL_ENGINE_VERSION }sh $ENGINE install --ram >/tmp/vpnpool-engine.log 2>&1 \\
        && logger -t vpnpool "AmneziaWG build in RAM" \\
        || logger -t vpnpool "AmneziaWG build not installed: \$(tail -n1 /tmp/vpnpool-engine.log)"
EOF
		fi
		cat <<'EOF'
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
	install_i18n --nodeps

	# Don't autostart at boot — sing-box isn't present until the WAN-up hook runs.
	/etc/init.d/vpnpool disable >/dev/null 2>&1 || true

	say "installing boot hook ($HOOK)..."
	write_ram_hook

	say "installing sing-box into RAM now (so it works without a reboot)..."
	sb_ok=0
	eval "$SB_RAM" || sb_ok=0
	if [ "$sb_ok" = 1 ]; then
		chmod +x /tmp/usr/bin/sing-box 2>/dev/null
		ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
		say "sing-box in RAM: $(/usr/bin/sing-box version 2>/dev/null | head -1)"
	else
		say "warning: could not install sing-box into RAM now; it will be installed on the next WAN-up / reboot"
	fi
	# AmneziaWG build next to it in RAM; the stock sing-box stays as the fallback
	if [ "$AWG" != 0 ]; then
		awg_mode=install; [ "$AWG" = update ] && awg_mode=update
		awg_engine "$awg_mode" --ram || true
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
	install_i18n

	# AmneziaWG build: a separate file /usr/bin/sing-box-awg; the stock sing-box is untouched.
	if [ "$AWG" != 0 ]; then
		awg_mode=install; [ "$AWG" = update ] && awg_mode=update
		awg_engine "$awg_mode" || true
	fi
fi

# refresh LuCI caches so the menu appears immediately
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
/etc/init.d/rpcd reload >/dev/null 2>&1 || true

rm -rf "$TMP"
[ "$AWG_DONE" = 1 ] && say "AmneziaWG: ready. Add an AmneziaWG .conf or a vpn:// link in vpnpool."
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
