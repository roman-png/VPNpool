#!/bin/sh
# engine.sh — install / update / remove / status of the AmneziaWG-capable sing-box build
# ("engine", https://github.com/roman-png/vpnpool-engine). It lives in its OWN file
# (/usr/bin/sing-box-awg). The stock /usr/bin/sing-box (opkg/apk, podkop) is not replaced —
# on the contrary: if an old vpnpool (1.4.x, VPNPOOL_AWG=1) put the hoaxisr AmneziaWG fork
# there, install/update put the stock package back once the engine is in place.
#
#   engine.sh install [--ram] [--force]   install the pinned (or VPNPOOL_ENGINE_VERSION) build
#   engine.sh update  [--ram]             same, only if an engine is installed; no-op if current
#                                         (RAM / flash mode: as recorded, unless --ram is given)
#   engine.sh remove                      delete the engine + its record
#   engine.sh restore-stock               put the stock sing-box package back (flash mode)
#   engine.sh status                      what is installed, incl. the stock binary (JSON)
#   engine.sh arch                        which asset fits this router (JSON)
#
# Output: ONE JSON object on stdout ({ok:true,...} or {ok:false,code:"E_*",...}); exit 0/1
# (2 = usage). No human texts here — callers (install.sh, later rpcd/LuCI) map the codes.
#
# Install pipeline (every step must pass; on ANY failure the working binary is untouched):
#   arch map -> RAM mode: MemTotal >= threshold -> free space (df on the target dir) ->
#   MemAvailable vs asset size -> download to a temp file IN the target dir -> sha256
#   (mandatory: pinned table, or <asset>.sha256 of the release for an override version) ->
#   chmod +x -> `version -n` == expected -> `check` of a tiny config with an awg endpoint ->
#   atomic mv -> /etc/vpnpool/awg-engine.json -> stock check / restore (flash mode).
#
# Env (operator):
#   VPNPOOL_ENGINE_VERSION    release to install instead of the pinned one (e.g. 1.14.3-awg.2)
#   VPNPOOL_ENGINE_RAM_MIN_MB RAM mode (16 MB flash routers): minimum MemTotal in MB (default
#                             200 = the "256 MB RAM" class: MemTotal is always below the
#                             physical size — kernel and reserved memory are not counted)
# Env (tests / unusual layouts): VPNPOOL_ENGINE_BASE_URL, VPNPOOL_ENGINE_BIN,
#   VPNPOOL_ENGINE_RAM_DIR, VPNPOOL_ENGINE_STATE, VPNPOOL_ENGINE_FETCH (only that downloader),
#   VPNPOOL_STOCK_BIN, ENGINE_PM (opkg|apk), ENGINE_MEMINFO, ENGINE_CPUINFO, ENGINE_LOCK,
#   ENGINE_PODKOP_INIT, ENGINE_RAM_HOOK, ENGINE_APK_WORLD.

ENGINE_PINNED="1.14.3-awg.1"
ENGINE_VERSION="${VPNPOOL_ENGINE_VERSION:-$ENGINE_PINNED}"
ENGINE_VERSION="${ENGINE_VERSION#v}"
ENGINE_REPO="roman-png/vpnpool-engine"
ENGINE_BASE_URL="${VPNPOOL_ENGINE_BASE_URL:-https://github.com/$ENGINE_REPO/releases/download}"
ENGINE_BIN="${VPNPOOL_ENGINE_BIN:-/usr/bin/sing-box-awg}"
ENGINE_RAM_DIR="${VPNPOOL_ENGINE_RAM_DIR:-/tmp/usr/bin}"
ENGINE_STATE="${VPNPOOL_ENGINE_STATE:-/etc/vpnpool/awg-engine.json}"
ENGINE_RAM_MIN_MB="${VPNPOOL_ENGINE_RAM_MIN_MB:-200}"
ENGINE_MEMINFO="${ENGINE_MEMINFO:-/proc/meminfo}"
ENGINE_CPUINFO="${ENGINE_CPUINFO:-/proc/cpuinfo}"
ENGINE_LOCK="${ENGINE_LOCK:-/tmp/vpnpool-engine.lock}"
STOCK_BIN="${VPNPOOL_STOCK_BIN:-/usr/bin/sing-box}"
PODKOP_INIT="${ENGINE_PODKOP_INIT:-/etc/init.d/podkop}"
RAM_HOOK="${ENGINE_RAM_HOOK:-/etc/hotplug.d/iface/99-vpnpool-singbox-ram}"
APK_WORLD="${ENGINE_APK_WORLD:-/etc/apk/world}"
# unknown asset size (override version): assume this much (KiB) for the space/RAM checks
ENGINE_SIZE_DEFAULT_KB=65536
# free space kept on top of the asset (KiB) so a full overlay can't brick other writes
ENGINE_SPACE_MARGIN_KB=1024
# RAM mode: the binary sits in tmpfs AND has to run (a Go sing-box with rule sets takes tens
# of MB) — extra MemAvailable on top of its size
ENGINE_RAM_RUN_MARGIN_KB=49152

# Pinned release: sha256 + size per asset (from SHA256SUMS of the immutable release). Pinning
# the hash here means a swapped file on the download side can't pass, even with its .sha256.
pinned_sha() {
	case "$1" in
		aarch64)        echo c1e2841d293d4e497cf8adcdc67e24b0d41f276e7393793a9df41caa1df5d17c ;;
		arm_cortex-a7)  echo 95279f958b7b13b764e8efb2c3c4e2efa1932710fc26c94d157d9a558c4af351 ;;
		mips_24kc)      echo 7f26ef38a5857ae67410ebee09583bd2d58186437b3a12ca72fdc31d3e9babef ;;
		mipsel_24kc)    echo f6378eeb52263e1b9d120ad4b63dc5f3d924dd1a6431433a49ec325b7b58d8ed ;;
		x86_64)         echo 1a145e0ceffb7d8dc0936657d0364e7a112ae1b4ec8bbbcc6e82a379eecdbc19 ;;
	esac
}
pinned_size() {   # bytes
	case "$1" in
		aarch64)        echo 42991742 ;;
		arm_cortex-a7)  echo 42336382 ;;
		mips_24kc)      echo 48431261 ;;
		mipsel_24kc)    echo 48431261 ;;
		x86_64)         echo 45944958 ;;
	esac
}

# ---------------------------------------------------------------- output helpers
out_fail() {   # <code> ["key=value"...] — prints {ok:false,code,action,...} and exits 1
	_c=$1; shift
	_j=$(jq -nc --arg code "$_c" --arg action "${ACTION:-}" '{ok:false, code:$code, action:$action}')
	for _kv in "$@"; do
		_j=$(printf '%s' "$_j" | jq -c --arg k "${_kv%%=*}" --arg v "${_kv#*=}" '. + {($k): $v}')
	done
	printf '%s\n' "$_j"
	exit 1
}

# ---------------------------------------------------------------- package manager / arch
pm_kind() {
	if [ -n "${ENGINE_PM:-}" ]; then echo "$ENGINE_PM"
	elif command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; then echo apk
	elif command -v opkg >/dev/null 2>&1; then echo opkg
	else echo none; fi
}
pm_arches() {   # one per line, highest priority first
	case "$(pm_kind)" in
		apk)  apk --print-arch 2>/dev/null ;;
		opkg) opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $3" "$2}' \
			| sort -rn | awk '{print $2}' ;;
	esac
}

cpu_has_vfp() {   # ARMv7 with a hardware FPU (vfpv3/vfpv4): what a GOARM=7 build needs
	grep -iE '^(Features|flags)[[:space:]]*:' "$ENGINE_CPUINFO" 2>/dev/null | grep -qiE '(^|[[:space:]])vfpv(3|4)' \
		&& grep -qE '^CPU architecture[[:space:]]*:[[:space:]]*(7|8)' "$ENGINE_CPUINFO" 2>/dev/null
}

# map ONE OpenWrt package arch to an engine asset arch ("" = not supported)
map_arch() {
	case "$1" in
		aarch64*) echo aarch64 ;;
		x86_64) echo x86_64 ;;
		# MIPS32r2 cores: the assets are GOMIPS=softfloat (no FPU needed), plain MIPS32 code
		mipsel_24kc|mipsel_24kc_*|mipsel_74kc|mipsel_74kc_*|mipsel_1004kc|mipsel_1004kc_*) echo mipsel_24kc ;;
		mips_24kc|mips_24kc_*|mips_34kc|mips_34kc_*|mips_74kc|mips_74kc_*) echo mips_24kc ;;
		# ARMv7-A cores; the asset is GOARM=7 (needs a hardware VFP). Names that carry the FPU
		# (…_vfpv3*, …_vfpv4, …_neon*) are safe; a bare name (arm_cortex-a9, arm_cortex-a7) may be
		# a core without VFP -> only if /proc/cpuinfo shows vfpv3/vfpv4.
		arm_cortex-a5_*|arm_cortex-a7_*|arm_cortex-a8_*|arm_cortex-a9_*|arm_cortex-a12_*|arm_cortex-a15_*|arm_cortex-a17_*|arm_cortex-a53_*|arm_cortex-a72_*)
			case "$1" in
				*vfpv3*|*vfpv4*|*neon*) echo arm_cortex-a7 ;;
				*) cpu_has_vfp && echo arm_cortex-a7 ;;
			esac ;;
		arm_cortex-a5|arm_cortex-a7|arm_cortex-a8|arm_cortex-a9|arm_cortex-a12|arm_cortex-a15|arm_cortex-a17|arm_cortex-a53|arm_cortex-a72)
			cpu_has_vfp && echo arm_cortex-a7 ;;
		# armv5/armv6 (arm926ej-s, xscale, mpcore, arm1176jzf-s…), mips64, i386, powerpc, …: no build
	esac
}

ARCH=""; PM_ARCHES=""
resolve_arch() {
	PM_ARCHES=$(pm_arches | tr '\n' ' ' | sed 's/ *$//')
	for a in $PM_ARCHES; do
		ARCH=$(map_arch "$a")
		[ -n "$ARCH" ] && return 0
	done
	return 1
}

asset_name() { echo "vpnpool-engine_${ENGINE_VERSION}_$1"; }
asset_url()  { echo "$ENGINE_BASE_URL/v$ENGINE_VERSION/$(asset_name "$1")"; }

# ---------------------------------------------------------------- system probes
meminfo_kb() { awk -v k="$1:" '$1==k {print $2; exit}' "$ENGINE_MEMINFO" 2>/dev/null; }
df_avail_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

fetchers() {   # downloaders to try, in order (VPNPOOL_ENGINE_FETCH = only that one)
	if [ -n "${VPNPOOL_ENGINE_FETCH:-}" ]; then
		command -v "$VPNPOOL_ENGINE_FETCH" >/dev/null 2>&1 && echo "$VPNPOOL_ENGINE_FETCH"; return
	fi
	for f in uclient-fetch wget curl; do command -v "$f" >/dev/null 2>&1 && echo "$f"; done
}
fetch_once() {   # <tool> <url> <outfile>
	rm -f "$3"
	case "$1" in
		uclient-fetch) uclient-fetch -T 30 -qO "$3" "$2" >/dev/null 2>&1 ;;
		wget) wget -T 30 -qO "$3" "$2" >/dev/null 2>&1 ;;
		curl) curl -fsSL --connect-timeout 30 -o "$3" "$2" >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}
# <url> <outfile>: 3 tries with the first downloader (GitHub is flaky on target networks), then
# one try with each other one (uclient-fetch without CA / TLS support fails every time)
fetch() {
	_first=""; _n=0
	for _t in $FETCHERS; do
		if [ -z "$_first" ]; then
			_first=$_t
			while [ $_n -lt 3 ]; do
				_n=$((_n + 1))
				fetch_once "$_t" "$1" "$2" && return 0
				[ $_n -lt 3 ] && sleep "${ENGINE_RETRY_SLEEP:-2}"
			done
		else
			fetch_once "$_t" "$1" "$2" && return 0   # fallback downloader
		fi
	done
	rm -f "$2"; return 1
}

file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
bin_version() { "$1" version -n 2>/dev/null | head -n1 | tr -d '\r'; }

# `check` of a minimal config with an AmneziaWG endpoint (made-up keys, documentation IP):
# the only reliable "this build can do AWG" test — stock sing-box rejects the endpoint type.
awg_check() {   # <binary>
	_cfg="${TMPDIR:-/tmp}/vpnpool-engine-check.$$.json"
	cat > "$_cfg" <<'EOF'
{"log":{"level":"error"},"endpoints":[{"type":"awg","tag":"engine-check","private_key":"YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=","address":["10.8.1.9/32"],"jc":4,"jmin":10,"jmax":50,"s1":89,"s2":112,"h1":"1","h2":"2","h3":"3","h4":"4","peers":[{"address":"198.51.100.61","port":443,"public_key":"SrvPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0=","allowed_ips":["0.0.0.0/0"]}]}]}
EOF
	"$1" check -c "$_cfg" >/dev/null 2>&1; _rc=$?
	rm -f "$_cfg"
	return $_rc
}

# ---------------------------------------------------------------- single-flight lock
# mkdir lock + PID; a lock whose PID is gone (SIGKILL / OOM on a small router) is stale.
# Taking over a stale lock: move it to a private name first (atomic), then check that what we
# moved is still the dead holder's — if another run took the lock in between, give it back.
lock_take() {
	mkdir "$ENGINE_LOCK" 2>/dev/null && { echo $$ > "$ENGINE_LOCK/pid"; return 0; }
	_p=$(cat "$ENGINE_LOCK/pid" 2>/dev/null)
	if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then return 1; fi
	_stale="$ENGINE_LOCK.stale.$$"
	mv "$ENGINE_LOCK" "$_stale" 2>/dev/null || return 1
	_q=$(cat "$_stale/pid" 2>/dev/null)
	if [ "$_q" != "$_p" ] && [ -n "$_q" ] && kill -0 "$_q" 2>/dev/null; then
		mv "$_stale" "$ENGINE_LOCK" 2>/dev/null || rm -rf "$_stale"
		return 1
	fi
	rm -rf "$_stale"
	mkdir "$ENGINE_LOCK" 2>/dev/null || return 1
	echo $$ > "$ENGINE_LOCK/pid"
	return 0
}

TMPF=""
cleanup() { [ -n "$TMPF" ] && rm -f "$TMPF" "$TMPF.sha"; [ "${LOCKED:-0}" = 1 ] && rm -rf "$ENGINE_LOCK"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# ---------------------------------------------------------------- state
installed_path() {   # where the engine binary really is (follows the RAM-mode symlink)
	if [ -L "$ENGINE_BIN" ]; then readlink -f "$ENGINE_BIN" 2>/dev/null || readlink "$ENGINE_BIN"
	else echo "$ENGINE_BIN"; fi
}

write_state() {   # <real path> <sha> <ram 0|1>
	mkdir -p "$(dirname "$ENGINE_STATE")"
	jq -nc --arg v "$ENGINE_VERSION" --arg sha "$2" --arg path "$ENGINE_BIN" --arg real "$1" \
		--arg arch "$ARCH" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ram "$3" \
		'{version:$v, sha256:$sha, path:$path, real_path:$real, arch:$arch, ram:($ram==1), installed_at:$date}' \
		> "$ENGINE_STATE.new" && mv -f "$ENGINE_STATE.new" "$ENGINE_STATE"
}

# ---------------------------------------------------------------- stock sing-box
# stock_probe sets:
#   S_REPLACED true|false|null  (null = can't tell: no binary / no package / RAM copy)
#   S_REASON   awg_build | checksum | version_mismatch | ram | missing | no_package | ""
#   S_VER (binary), S_PKG (package version), S_HELD true|false, S_HOOK_FORK true|false
# opkg keeps no file checksums (only the path list), so there the version is the evidence;
# apk keeps one per file -> `apk audit`. A binary that calls itself an awg build is the
# hoaxisr fork whatever the package says.
stock_probe() {
	S_REPLACED=null; S_REASON=""; S_VER=""; S_PKG=""; S_HELD=false; S_HOOK_FORK=false
	_pm=$(pm_kind)
	if [ "$_pm" = opkg ]; then
		_st=$(opkg status sing-box 2>/dev/null)
		S_PKG=$(printf '%s\n' "$_st" | awk '/^Version:/ {print $2; exit}')
		printf '%s\n' "$_st" | grep -q '^Status:.*hold' && S_HELD=true
	elif [ "$_pm" = apk ]; then
		S_PKG=$(apk list -I sing-box 2>/dev/null | sed -n 's/^sing-box-\([0-9][^ ]*\) .*/\1/p' | head -n1)
		grep -q '^sing-box=' "$APK_WORLD" 2>/dev/null && S_HELD=true
	fi
	grep -qiE 'hoaxisr|amnezia-box' "$RAM_HOOK" 2>/dev/null && S_HOOK_FORK=true
	if [ ! -e "$STOCK_BIN" ]; then S_REASON=missing; return; fi
	S_VER=$("$STOCK_BIN" version 2>/dev/null | awk 'NR==1 {print $3}')
	case "$S_VER" in *awg*|*AWG*) S_REPLACED=true; S_REASON=awg_build; return ;; esac
	case "$(readlink -f "$STOCK_BIN" 2>/dev/null)" in /tmp/*) S_REASON=ram; return ;; esac
	if [ "$_pm" = apk ] && apk audit --system "$(dirname "$STOCK_BIN")" 2>/dev/null | grep -q " ${STOCK_BIN#/}\$"; then
		S_REPLACED=true; S_REASON=checksum; return
	fi
	if [ -z "$S_PKG" ]; then S_REASON=no_package; return; fi
	_base=$(printf '%s' "$S_PKG" | sed 's/-r[0-9]*$//; s/-[0-9]*$//')
	if [ "$S_VER" != "$_base" ]; then S_REPLACED=true; S_REASON=version_mismatch; return; fi
	S_REPLACED=false
}

# put the stock package back (flash mode). Sets R_CODE ("" = done), R_PODKOP true|false.
stock_restore() {
	R_CODE=""; R_PODKOP=false
	_pm=$(pm_kind)
	if [ "$_pm" = opkg ]; then
		# download first, so the flash is never left without a binary
		_d="${TMPDIR:-/tmp}/vpnpool-stock.$$"; rm -rf "$_d"; mkdir -p "$_d"
		( cd "$_d" && opkg download sing-box ) >/dev/null 2>&1 \
			|| { opkg update >/dev/null 2>&1; ( cd "$_d" && opkg download sing-box ) >/dev/null 2>&1; }
		_ipk=$(ls "$_d"/sing-box_*.ipk 2>/dev/null | head -n1)
		if [ -z "$_ipk" ]; then rm -rf "$_d"; R_CODE=E_STOCK_DOWNLOAD; return; fi
		opkg flag user sing-box >/dev/null 2>&1
		opkg install --force-reinstall "$_ipk" >/dev/null 2>&1 || { rm -rf "$_d"; R_CODE=E_STOCK_INSTALL; return; }
		rm -rf "$_d"
	elif [ "$_pm" = apk ]; then
		grep -q '^sing-box=' "$APK_WORLD" 2>/dev/null && apk add sing-box >/dev/null 2>&1   # drop the version pin
		apk fix --reinstall sing-box >/dev/null 2>&1 \
			|| { apk update >/dev/null 2>&1; apk fix --reinstall sing-box >/dev/null 2>&1; } \
			|| { R_CODE=E_STOCK_INSTALL; return; }
	else
		R_CODE=E_STOCK_NO_PM; return
	fi
	stock_probe
	if [ "$S_REPLACED" = true ] || [ -z "$S_VER" ]; then R_CODE=E_STOCK_VERIFY; return; fi
	# podkop runs on the same binary (and serves DNS): restart it on the stock build
	if [ -x "$PODKOP_INIT" ] && "$PODKOP_INIT" enabled >/dev/null 2>&1; then
		"$PODKOP_INIT" restart >/dev/null 2>&1; R_PODKOP=true
	fi
}

# after a successful engine install: stock check + restore. Sets STOCK_JSON (jq fragment args)
stock_after_install() {
	stock_probe
	ST_REPLACED=$S_REPLACED; ST_REASON=$S_REASON; ST_RESTORED=null; ST_CODE=""; ST_PODKOP=false
	if [ "$S_REPLACED" = true ] && [ "$S_REASON" != ram ]; then
		stock_restore
		if [ -z "$R_CODE" ]; then ST_RESTORED=true; else ST_RESTORED=false; ST_CODE=$R_CODE; fi
		ST_PODKOP=$R_PODKOP
	fi
}
stock_fields() {   # jq filter args for the install/update reply
	printf '%s' "$1" | jq -c --argjson rep "$ST_REPLACED" --arg reason "$ST_REASON" --argjson res "$ST_RESTORED" \
		--arg code "$ST_CODE" --argjson pk "$ST_PODKOP" \
		'. + {stock_replaced:$rep, stock_reason:(if $reason=="" then null else $reason end), stock_restored:$res,
		      stock_code:(if $code=="" then null else $code end), podkop_restarted:$pk}'
}

# ---------------------------------------------------------------- actions
do_arch() {
	if resolve_arch; then
		jq -nc --arg a "$ARCH" --arg pm "$PM_ARCHES" '{ok:true, action:"arch", arch:$a, pm_arch:$pm}'
	else
		out_fail E_ARCH "pm_arch=$PM_ARCHES"
	fi
}

do_status() {
	_inst=false; _ver=""; _awg=false; _real=""; _sha=""
	_real=$(installed_path)
	if [ -x "$_real" ] && [ -f "$_real" ]; then
		_inst=true
		_ver=$(bin_version "$_real")
		awg_check "$_real" && _awg=true
		_sha=$(file_sha "$_real")
	fi
	_rec='null'
	[ -s "$ENGINE_STATE" ] && _rec=$(jq -c . "$ENGINE_STATE" 2>/dev/null || echo null)
	resolve_arch || ARCH=""
	stock_probe
	jq -nc --argjson inst "$_inst" --arg ver "$_ver" --argjson awg "$_awg" --arg path "$ENGINE_BIN" \
		--arg real "$_real" --arg sha "$_sha" --argjson rec "${_rec:-null}" --arg want "$ENGINE_VERSION" \
		--arg arch "$ARCH" --argjson srep "$S_REPLACED" --arg sreason "$S_REASON" --arg sver "$S_VER" \
		--arg spkg "$S_PKG" --argjson sheld "$S_HELD" --argjson shook "$S_HOOK_FORK" --arg spath "$STOCK_BIN" \
		'{ok:true, action:"status", installed:$inst, version:(if $ver=="" then null else $ver end),
		  awg:$awg, path:$path, real_path:(if $inst then $real else null end),
		  sha256:(if $sha=="" then null else $sha end), target_version:$want,
		  current:($inst and $ver==$want and $awg), arch:(if $arch=="" then null else $arch end),
		  record:$rec,
		  stock:{path:$spath, replaced:$srep, reason:(if $sreason=="" then null else $sreason end),
		         version:(if $sver=="" then null else $sver end), pkg_version:(if $spkg=="" then null else $spkg end),
		         held:$sheld, hook_fork:$shook}}'
}

do_remove() {
	_real=$(installed_path)
	_had=false
	[ -e "$_real" ] && _had=true
	[ -e "$ENGINE_BIN" ] || [ -L "$ENGINE_BIN" ] && _had=true
	[ "$_real" != "$ENGINE_BIN" ] && rm -f "$_real"
	rm -f "$ENGINE_BIN" "$ENGINE_STATE"
	if [ -e "$ENGINE_BIN" ]; then out_fail E_REMOVE "path=$ENGINE_BIN"; fi
	jq -nc --argjson had "$_had" --arg path "$ENGINE_BIN" '{ok:true, action:"remove", removed:$had, path:$path}'
}

do_restore_stock() {
	stock_probe
	if [ "$S_REPLACED" != true ]; then
		jq -nc --argjson rep "$S_REPLACED" --arg reason "$S_REASON" \
			'{ok:true, action:"restore-stock", changed:false, stock_replaced:$rep, stock_reason:(if $reason=="" then null else $reason end)}'
		return 0
	fi
	[ "$S_REASON" = ram ] && out_fail E_STOCK_RAM
	_why=$S_REASON
	stock_restore
	[ -n "$R_CODE" ] && out_fail "$R_CODE" "stock_reason=$_why"
	jq -nc --arg reason "$_why" --argjson pk "$R_PODKOP" --arg v "$S_VER" \
		'{ok:true, action:"restore-stock", changed:true, stock_reason:$reason, stock_version:$v, podkop_restarted:$pk}'
}

do_install() {   # $1 = 1 for update semantics
	_update=$1
	resolve_arch || out_fail E_ARCH "pm_arch=$PM_ARCHES"

	if [ "$RAM" = 1 ]; then DEST="$ENGINE_RAM_DIR/$(basename "$ENGINE_BIN")"; else DEST="$ENGINE_BIN"; fi
	_dir=$(dirname "$DEST")
	# temp files of a run that died without its trap (power cut, OOM SIGKILL): we hold the
	# lock, so nobody else is downloading — they are garbage and they eat the space we need
	rm -f "$_dir/.$(basename "$DEST").new."* 2>/dev/null
	_cur=$(installed_path)

	if [ "$_update" = 1 ] && ! { [ -f "$_cur" ] && [ -x "$_cur" ]; } && [ ! -s "$ENGINE_STATE" ]; then
		out_fail E_NOT_INSTALLED
	fi
	# already current: same version, AWG works, same bytes as recorded -> nothing to do
	if [ "$FORCE" != 1 ] && [ -f "$DEST" ] && [ -x "$DEST" ] && [ "$(bin_version "$DEST")" = "$ENGINE_VERSION" ] \
		&& awg_check "$DEST"; then
		_s=$(file_sha "$DEST")
		_want=$(pinned_sha "$ARCH"); [ "$ENGINE_VERSION" = "$ENGINE_PINNED" ] || _want=""
		if [ -z "$_want" ] || [ "$_s" = "$_want" ]; then
			[ "$RAM" = 1 ] && [ "$DEST" != "$ENGINE_BIN" ] && ln -sf "$DEST" "$ENGINE_BIN"
			[ -s "$ENGINE_STATE" ] || write_state "$DEST" "$_s" "$RAM"
			stock_after_install
			stock_fields "$(jq -nc --arg v "$ENGINE_VERSION" --arg path "$ENGINE_BIN" --arg a "$ARCH" --arg act "$ACTION" \
				'{ok:true, action:$act, changed:false, version:$v, path:$path, arch:$a}')"
			return 0
		fi
	fi

	if [ "$RAM" = 1 ]; then
		_mt=$(meminfo_kb MemTotal)
		[ -n "$_mt" ] && [ "$_mt" -ge $((ENGINE_RAM_MIN_MB * 1024)) ] \
			|| out_fail E_RAM_TOTAL "mem_total_kb=${_mt:-?}" "need_kb=$((ENGINE_RAM_MIN_MB * 1024))"
	fi

	_size=""; _sha=""
	if [ "$ENGINE_VERSION" = "$ENGINE_PINNED" ]; then
		_size=$(pinned_size "$ARCH"); _sha=$(pinned_sha "$ARCH")
	fi
	if [ -n "$_size" ]; then _need=$(( (_size + 1023) / 1024 )); else _need=$ENGINE_SIZE_DEFAULT_KB; fi

	mkdir -p "$_dir" 2>/dev/null
	_avail=$(df_avail_kb "$_dir")
	case "$_avail" in ''|*[!0-9]*) out_fail E_SPACE "dir=$_dir" "avail_kb=?" ;; esac
	[ "$_avail" -ge $((_need + ENGINE_SPACE_MARGIN_KB)) ] \
		|| out_fail E_SPACE "dir=$_dir" "avail_kb=$_avail" "need_kb=$((_need + ENGINE_SPACE_MARGIN_KB))"

	_ma=$(meminfo_kb MemAvailable)
	_mneed=$_need; [ "$RAM" = 1 ] && _mneed=$((_need + ENGINE_RAM_RUN_MARGIN_KB))
	case "$_ma" in ''|*[!0-9]*) out_fail E_MEM "mem_available_kb=?" ;; esac
	[ "$_ma" -ge "$_mneed" ] || out_fail E_MEM "mem_available_kb=$_ma" "need_kb=$_mneed"

	FETCHERS=$(fetchers | tr '\n' ' ')
	[ -n "$FETCHERS" ] || out_fail E_NO_DOWNLOADER

	_url=$(asset_url "$ARCH")
	TMPF="$_dir/.$(basename "$DEST").new.$$"
	if [ -z "$_sha" ]; then
		# override version: the release's own .sha256 (mandatory — no hash, no install)
		fetch "$_url.sha256" "$TMPF.sha" || out_fail E_SHA_UNKNOWN "url=$_url.sha256"
		_sha=$(awk 'NR==1 {print tolower($1)}' "$TMPF.sha" | tr -d '\r')
		rm -f "$TMPF.sha"
		case "$_sha" in *[!0-9a-f]*|'') out_fail E_SHA_UNKNOWN "url=$_url.sha256" ;; esac
		[ ${#_sha} -eq 64 ] || out_fail E_SHA_UNKNOWN "url=$_url.sha256"
	fi

	fetch "$_url" "$TMPF" || out_fail E_DOWNLOAD "url=$_url"
	( cd "$_dir" && echo "$_sha  $(basename "$TMPF")" | sha256sum -c >/dev/null 2>&1 ) \
		|| out_fail E_SHA "want=$_sha" "got=$(file_sha "$TMPF")"
	chmod 0755 "$TMPF" || out_fail E_INSTALL "dir=$_dir"
	_v=$(bin_version "$TMPF")
	[ "$_v" = "$ENGINE_VERSION" ] || out_fail E_VERSION "want=$ENGINE_VERSION" "got=$_v"
	awg_check "$TMPF" || out_fail E_CHECK
	mv -f "$TMPF" "$DEST" || out_fail E_INSTALL "dir=$_dir"
	TMPF=""
	if [ "$RAM" = 1 ] && [ "$DEST" != "$ENGINE_BIN" ]; then
		mkdir -p "$(dirname "$ENGINE_BIN")"
		ln -sf "$DEST" "$ENGINE_BIN" || out_fail E_INSTALL "path=$ENGINE_BIN"
	fi
	write_state "$DEST" "$_sha" "$RAM" || out_fail E_STATE "path=$ENGINE_STATE"
	# the engine is in place: now (and only now) put the stock sing-box back if an old
	# vpnpool replaced it — a failure there is reported, the engine install stands
	stock_after_install
	stock_fields "$(jq -nc --arg v "$ENGINE_VERSION" --arg path "$ENGINE_BIN" --arg real "$DEST" --arg a "$ARCH" \
		--arg sha "$_sha" --arg act "$ACTION" \
		'{ok:true, action:$act, changed:true, version:$v, path:$path, real_path:$real, arch:$a, sha256:$sha}')"
}

# ---------------------------------------------------------------- main
ACTION="${1:-}"; [ $# -gt 0 ] && shift
RAM=0; FORCE=0; RAM_GIVEN=0
for o in "$@"; do
	case "$o" in
		--ram) RAM=1; RAM_GIVEN=1 ;;
		--force) FORCE=1 ;;
		*) echo '{"ok":false,"code":"E_USAGE"}'; exit 2 ;;
	esac
done
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"code":"E_NO_JQ"}'; exit 1; }
# update keeps the mode it was installed in (a RAM install must not land on a 16 MB flash)
if [ "$ACTION" = update ] && [ "$RAM_GIVEN" = 0 ] && [ -s "$ENGINE_STATE" ] \
	&& [ "$(jq -r '.ram // false' "$ENGINE_STATE" 2>/dev/null)" = true ]; then
	RAM=1
fi

case "$ACTION" in
	status) do_status ;;
	arch)   do_arch ;;
	install|update|remove|restore-stock)
		lock_take || out_fail E_BUSY
		LOCKED=1
		case "$ACTION" in
			install) do_install 0 ;;
			update)  do_install 1 ;;
			remove)  do_remove ;;
			restore-stock) do_restore_stock ;;
		esac ;;
	*) echo '{"ok":false,"code":"E_USAGE"}'; exit 2 ;;
esac
