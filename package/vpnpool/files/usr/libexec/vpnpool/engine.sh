#!/bin/sh
# engine.sh — install / update / remove / status of the AmneziaWG-capable sing-box build
# ("engine", https://github.com/roman-png/vpnpool-engine). It lives in its OWN file
# (/usr/bin/sing-box-awg): the stock /usr/bin/sing-box (opkg/apk, podkop) is never touched.
#
#   engine.sh install [--ram] [--force]   install the pinned (or VPNPOOL_ENGINE_VERSION) build
#   engine.sh update  [--ram]             same, only if an engine is installed; no-op if current
#   engine.sh remove                      delete the engine + its record
#   engine.sh status                      what is installed (JSON)
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
#   atomic mv -> /etc/vpnpool/awg-engine.json.
#
# Env (operator):
#   VPNPOOL_ENGINE_VERSION    release to install instead of the pinned one (e.g. 1.14.3-awg.2)
#   VPNPOOL_ENGINE_RAM_MIN_MB RAM mode (16 MB flash routers): minimum MemTotal (default 256)
# Env (tests / unusual layouts): VPNPOOL_ENGINE_BASE_URL, VPNPOOL_ENGINE_BIN,
#   VPNPOOL_ENGINE_RAM_DIR, VPNPOOL_ENGINE_STATE, VPNPOOL_ENGINE_FETCH (uclient-fetch|wget|curl),
#   ENGINE_MEMINFO, ENGINE_CPUINFO, ENGINE_LOCK.

ENGINE_PINNED="1.14.3-awg.1"
ENGINE_VERSION="${VPNPOOL_ENGINE_VERSION:-$ENGINE_PINNED}"
ENGINE_VERSION="${ENGINE_VERSION#v}"
ENGINE_REPO="roman-png/vpnpool-engine"
ENGINE_BASE_URL="${VPNPOOL_ENGINE_BASE_URL:-https://github.com/$ENGINE_REPO/releases/download}"
ENGINE_BIN="${VPNPOOL_ENGINE_BIN:-/usr/bin/sing-box-awg}"
ENGINE_RAM_DIR="${VPNPOOL_ENGINE_RAM_DIR:-/tmp/usr/bin}"
ENGINE_STATE="${VPNPOOL_ENGINE_STATE:-/etc/vpnpool/awg-engine.json}"
ENGINE_RAM_MIN_MB="${VPNPOOL_ENGINE_RAM_MIN_MB:-256}"
ENGINE_MEMINFO="${ENGINE_MEMINFO:-/proc/meminfo}"
ENGINE_CPUINFO="${ENGINE_CPUINFO:-/proc/cpuinfo}"
ENGINE_LOCK="${ENGINE_LOCK:-/tmp/vpnpool-engine.lock}"
# unknown asset size (override version): assume this much (KiB) for the space/RAM checks
ENGINE_SIZE_DEFAULT_KB=65536
# free space kept on top of the asset (KiB) so a full overlay can't brick other writes
ENGINE_SPACE_MARGIN_KB=1024
# RAM mode: the binary sits in tmpfs AND has to run — extra MemAvailable on top of its size
ENGINE_RAM_RUN_MARGIN_KB=16384

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
pm_arches() {   # one per line, router's own order (opkg: by priority, highest last)
	if command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; then
		apk --print-arch 2>/dev/null
	elif command -v opkg >/dev/null 2>&1; then
		opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $3" "$2}' \
			| sort -rn | awk '{print $2}'
	fi
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
		mipsel_24kc|mipsel_24kc_*) echo mipsel_24kc ;;
		mips_24kc|mips_24kc_*) echo mips_24kc ;;
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

fetcher() {
	if [ -n "${VPNPOOL_ENGINE_FETCH:-}" ]; then
		command -v "$VPNPOOL_ENGINE_FETCH" >/dev/null 2>&1 && echo "$VPNPOOL_ENGINE_FETCH"; return
	fi
	for f in uclient-fetch wget curl; do command -v "$f" >/dev/null 2>&1 && { echo "$f"; return; }; done
}
fetch() {   # <url> <outfile> — a few retries (GitHub downloads are flaky on target networks)
	_n=0
	while [ $_n -lt 3 ]; do
		_n=$((_n + 1))
		rm -f "$2"
		case "$FETCH" in
			uclient-fetch) uclient-fetch -T 30 -qO "$2" "$1" >/dev/null 2>&1 && return 0 ;;
			wget) wget -T 30 -qO "$2" "$1" >/dev/null 2>&1 && return 0 ;;
			curl) curl -fsSL --connect-timeout 30 -o "$2" "$1" >/dev/null 2>&1 && return 0 ;;
		esac
		[ $_n -lt 3 ] && sleep "${ENGINE_RETRY_SLEEP:-2}"
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
lock_take() {
	if ! mkdir "$ENGINE_LOCK" 2>/dev/null; then
		_p=$(cat "$ENGINE_LOCK/pid" 2>/dev/null)
		if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then return 1; fi
		rm -rf "$ENGINE_LOCK"
		mkdir "$ENGINE_LOCK" 2>/dev/null || return 1
	fi
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
	jq -nc --argjson inst "$_inst" --arg ver "$_ver" --argjson awg "$_awg" --arg path "$ENGINE_BIN" \
		--arg real "$_real" --arg sha "$_sha" --argjson rec "${_rec:-null}" --arg want "$ENGINE_VERSION" \
		--arg arch "$ARCH" \
		'{ok:true, action:"status", installed:$inst, version:(if $ver=="" then null else $ver end),
		  awg:$awg, path:$path, real_path:(if $inst then $real else null end),
		  sha256:(if $sha=="" then null else $sha end), target_version:$want,
		  current:($inst and $ver==$want and $awg), arch:(if $arch=="" then null else $arch end),
		  record:$rec}'
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

do_install() {   # $1 = 1 for update semantics
	_update=$1
	resolve_arch || out_fail E_ARCH "pm_arch=$PM_ARCHES"

	if [ "$RAM" = 1 ]; then DEST="$ENGINE_RAM_DIR/$(basename "$ENGINE_BIN")"; else DEST="$ENGINE_BIN"; fi
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
			jq -nc --arg v "$ENGINE_VERSION" --arg path "$ENGINE_BIN" --arg a "$ARCH" --arg act "$ACTION" \
				'{ok:true, action:$act, changed:false, version:$v, path:$path, arch:$a}'
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

	_dir=$(dirname "$DEST")
	mkdir -p "$_dir" 2>/dev/null
	_avail=$(df_avail_kb "$_dir")
	case "$_avail" in ''|*[!0-9]*) out_fail E_SPACE "dir=$_dir" "avail_kb=?" ;; esac
	[ "$_avail" -ge $((_need + ENGINE_SPACE_MARGIN_KB)) ] \
		|| out_fail E_SPACE "dir=$_dir" "avail_kb=$_avail" "need_kb=$((_need + ENGINE_SPACE_MARGIN_KB))"

	_ma=$(meminfo_kb MemAvailable)
	_mneed=$_need; [ "$RAM" = 1 ] && _mneed=$((_need + ENGINE_RAM_RUN_MARGIN_KB))
	case "$_ma" in ''|*[!0-9]*) out_fail E_MEM "mem_available_kb=?" ;; esac
	[ "$_ma" -ge "$_mneed" ] || out_fail E_MEM "mem_available_kb=$_ma" "need_kb=$_mneed"

	FETCH=$(fetcher)
	[ -n "$FETCH" ] || out_fail E_NO_DOWNLOADER

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
	jq -nc --arg v "$ENGINE_VERSION" --arg path "$ENGINE_BIN" --arg real "$DEST" --arg a "$ARCH" \
		--arg sha "$_sha" --arg act "$ACTION" \
		'{ok:true, action:$act, changed:true, version:$v, path:$path, real_path:$real, arch:$a, sha256:$sha}'
}

# ---------------------------------------------------------------- main
ACTION="${1:-}"; [ $# -gt 0 ] && shift
RAM=0; FORCE=0
for o in "$@"; do
	case "$o" in
		--ram) RAM=1 ;;
		--force) FORCE=1 ;;
		*) echo '{"ok":false,"code":"E_USAGE"}'; exit 2 ;;
	esac
done
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"code":"E_NO_JQ"}'; exit 1; }

case "$ACTION" in
	status) do_status ;;
	arch)   do_arch ;;
	install|update|remove)
		lock_take || out_fail E_BUSY
		LOCKED=1
		case "$ACTION" in
			install) do_install 0 ;;
			update)  do_install 1 ;;
			remove)  do_remove ;;
		esac ;;
	*) echo '{"ok":false,"code":"E_USAGE"}'; exit 2 ;;
esac
