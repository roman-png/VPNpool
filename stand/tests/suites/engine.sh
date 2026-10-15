# suite: engine — engine.sh (install/update/remove/status of the AWG sing-box build) (sourced by run.sh)
# Offline: uclient-fetch / wget are test doubles that serve files from a local "release" tree;
# df / opkg / apk / meminfo / cpuinfo are faked per case. The REAL x86_64 release asset is
# expected at /engine-assets (run-in-docker.sh mounts ENGINE_ASSET_DIR there):
#   gh release download v1.14.3-awg.1 -R roman-png/vpnpool-engine -p 'vpnpool-engine_1.14.3-awg.1_x86_64' -D <dir>
#   ENGINE_ASSET_DIR=<dir> stand/tests/run-in-docker.sh engine
# Without it the real-binary cases are not run and engine/real-asset-mounted FAILS (never a
# silent pass). Invariant after EVERY refusal: the working engine and the stock sing-box are
# byte-identical to before, and no temp file is left next to them.

ENG=/usr/libexec/vpnpool/engine.sh
PIN=1.14.3-awg.1
REL="https://github.com/roman-png/vpnpool-engine/releases/download"
ESH="$T_STATE/engine-shim"       # test doubles (first on PATH for engine.sh only)
ESRV="$T_STATE/engine-srv"       # fake release tree: v<ver>/<asset>
EW="$T_STATE/engine-work"
REAL_ASSET=/engine-assets/vpnpool-engine_${PIN}_x86_64
BIN=/usr/bin/sing-box-awg
STOCK=/usr/bin/sing-box
mkdir -p "$ESH" "$ESRV" "$EW"

# ---- test doubles ----
cat > "$ESH/uclient-fetch" <<'EOF'
#!/bin/sh
# serve <base>/v<ver>/<asset> from $ESRV; log every call; missing file = HTTP 404 (exit 1)
# $ESH/uclient.broken: uclient-fetch fails every call (no CA / TLS support)
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-T) shift ;;
		-qO|-O) shift; out=$1 ;;
		-q) ;;
		*) url=$1 ;;
	esac
	shift
done
echo "$(basename "$0") $url" >> "$ESH/calls"
[ "$(basename "$0")" = uclient-fetch ] && [ -f "$ESH/uclient.broken" ] && exit 1
rel=${url#https://github.com/roman-png/vpnpool-engine/releases/download/}
[ "$rel" != "$url" ] && [ -f "$ESRV/$rel" ] || exit 1
cat "$ESRV/$rel" > "$out"
EOF
cp "$ESH/uclient-fetch" "$ESH/wget"
cat > "$ESH/df" <<'EOF'
#!/bin/sh
if [ -f "$ESH/df.avail" ]; then
	echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
	echo "fakefs 100000000 0 $(cat "$ESH/df.avail") 0% /"
else exec /bin/df "$@"; fi
EOF
# package-manager doubles (never the real ones): every call is logged to $ESH/pm.log.
#   $ESH/opkg.status  what `opkg status sing-box` prints (absent = package not installed)
#   $ESH/apk.list / $ESH/apk.audit  what `apk list -I sing-box` / `apk audit` print
#   $ESH/stock.new    the "package" binary a reinstall puts at $VPNPOOL_STOCK_BIN
#   $ESH/pm.fail      the reinstall fails (no package download)
cat > "$ESH/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$ESH/pm.log"
case "$1" in
	print-architecture) [ -f "$ESH/arch" ] && { echo "arch all 1"; echo "arch noarch 1"; echo "arch $(cat "$ESH/arch") 10"; } ;;
	status) [ -f "$ESH/opkg.status" ] && cat "$ESH/opkg.status" ;;
	flag) [ "$2" = user ] && [ -f "$ESH/opkg.status" ] && sed -i 's/^Status: install hold installed/Status: install user installed/' "$ESH/opkg.status" ;;
	download) [ -f "$ESH/pm.fail" ] && exit 1; : > "./sing-box_1.12.25-r1_x86_64.ipk" ;;
	install) [ -f "$ESH/pm.fail" ] && exit 1; cp "$ESH/stock.new" "$VPNPOOL_STOCK_BIN" ;;
esac
exit 0
EOF
cat > "$ESH/apk" <<'EOF'
#!/bin/sh
echo "apk $*" >> "$ESH/pm.log"
case "$1" in
	--print-arch) cat "$ESH/arch" ;;
	list) [ -f "$ESH/apk.list" ] && cat "$ESH/apk.list" ;;
	audit) [ -f "$ESH/apk.audit" ] && cat "$ESH/apk.audit" ;;
	add) [ "$2" = sing-box ] && [ -f "$ENGINE_APK_WORLD" ] && sed -i 's/^sing-box=.*/sing-box/' "$ENGINE_APK_WORLD" ;;
	fix) [ -f "$ESH/pm.fail" ] && exit 1; cp "$ESH/stock.new" "$VPNPOOL_STOCK_BIN"; rm -f "$ESH/apk.audit" ;;
	update) ;;
	*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$ESH"/*
export ESH ESRV

fake_engine() {   # <path> <printed version> <check rc> [marker]
	printf '#!/bin/sh\n# %s\n[ "$1" = version ] && [ "$2" = -n ] && { echo %s; exit 0; }\n[ "$1" = version ] && { echo "vpnpool-engine version %s"; exit 0; }\n[ "$1" = check ] && { [ %s -eq 0 ] && grep -q "\\"type\\":\\"awg\\"" "$3" && exit 0; echo FATAL; exit 1; }\nexit 1\n' \
		"${4:-fake}" "$2" "$2" "$3" > "$1"
	chmod +x "$1"
}
publish() {   # <version> <file> [sha-file-content|-]  — put an asset (+ .sha256) in the fake release
	_d="$ESRV/v$1"; mkdir -p "$_d"; _a="$_d/vpnpool-engine_$1_x86_64"
	cp "$2" "$_a"
	if [ "${3:-auto}" = auto ]; then echo "$(sha256sum "$_a" | cut -d' ' -f1)  vpnpool-engine_$1_x86_64" > "$_a.sha256"
	elif [ "$3" != - ]; then printf '%s\n' "$3" > "$_a.sha256"; fi
}
meminfo() { printf 'MemTotal:       %s kB\nMemFree:        1000 kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$ESH/meminfo"; }

# E <args> — run engine.sh with the doubles; sets EJ (stdout JSON) and ERC
E() {
	rm -f "$EW/out"
	run_with_timeout 120 env PATH="$ESH:$PATH" ENGINE_MEMINFO="$ESH/meminfo" ENGINE_CPUINFO="$ESH/cpuinfo" \
		ENGINE_LOCK="$EW/lock" ENGINE_RETRY_SLEEP=0 ESH="$ESH" ESRV="$ESRV" 		ENGINE_RAM_HOOK="${ENGINE_RAM_HOOK:-$EW/no-hook}" ENGINE_PODKOP_INIT="${ENGINE_PODKOP_INIT:-$EW/no-podkop}" \
		sh -c 'sh "$@" > "$0" 2>/dev/null' "$EW/out" "$ENG" "$@"
	ERC=$?
	EJ=$(cat "$EW/out" 2>/dev/null)
}
calls_to() { gcount -F "$1" "$ESH/calls"; }
sha_of() { [ -e "$1" ] && sha256sum "$1" | cut -d' ' -f1 || echo none; }
reset_engine() {
	rm -f "$BIN" "$ESH/calls" "$ESH/df.avail" "$ESH/arch" "$ESH/cpuinfo" /etc/vpnpool/awg-engine.json
	rm -f "$ESH/pm.log" "$ESH/opkg.status" "$ESH/apk.list" "$ESH/apk.audit" "$ESH/stock.new" "$ESH/pm.fail" "$ESH/uclient.broken"
	rm -rf "$EW/lock" "$EW/ram" /usr/bin/.sing-box-awg.new.*
	echo x86_64 > "$ESH/arch"
	meminfo 2000000 1500000
	: > "$ESH/calls"
	unset VPNPOOL_ENGINE_VERSION VPNPOOL_ENGINE_FETCH VPNPOOL_ENGINE_RAM_DIR VPNPOOL_ENGINE_RAM_MIN_MB
	unset VPNPOOL_STOCK_BIN ENGINE_PM ENGINE_APK_WORLD ENGINE_RAM_HOOK ENGINE_PODKOP_INIT
}
STOCK_SHA=$(sha_of "$STOCK")

# working engine already in place: every refusal below must leave it byte-identical
put_working() { fake_engine "$BIN" 1.14.3-awg.0 0 WORKING-ENGINE; WORK_SHA=$(sha_of "$BIN"); }
untouched() {   # checks after a refusal
	expect_eq "working engine untouched" "$(sha_of "$BIN")" "$WORK_SHA"
	expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
	expect_eq "no temp file left" "$(ls -a /usr/bin | grep -c '^\.sing-box-awg\.new')" 0
	expect_true "no engine record written" [ ! -e /etc/vpnpool/awg-engine.json ]
}
refuse() {   # <case> <code> <args...>  — engine.sh must exit 1 with that code
	_c=$1; _code=$2; shift 2
	begin "engine/$_c"
	E "$@"
	expect_true "exit 1 (rc=$ERC)" [ "$ERC" -eq 1 ]
	expect_jq "ok:false code $_code" "$EJ" ".ok==false and .code==\"$_code\""
	untouched
}

# ---- 1. arch map (opkg print-architecture / apk --print-arch) ----
A() {   # <pm arch> <expected asset arch | E_ARCH> [cpuinfo: vfp|novfp]
	reset_engine
	echo "$1" > "$ESH/arch"
	case "${3:-}" in
		vfp)   printf 'Processor\t: ARMv7\nFeatures\t: half thumb fastmult vfp edsp neon vfpv3 tls vfpv4\nCPU architecture: 7\n' > "$ESH/cpuinfo" ;;
		novfp) printf 'Processor\t: ARMv7\nFeatures\t: half thumb fastmult edsp tls\nCPU architecture: 7\n' > "$ESH/cpuinfo" ;;
	esac
	begin "engine/arch-$1${3:+-$3}"
	E arch
	if [ "$2" = E_ARCH ]; then
		expect_jq "refused" "$EJ" ".ok==false and .code==\"E_ARCH\" and (.pm_arch|contains(\"$1\"))"
	else
		expect_jq "-> $2" "$EJ" ".ok==true and .arch==\"$2\""
	fi
	end
}
A aarch64_cortex-a53        aarch64
A aarch64_generic           aarch64
A arm_cortex-a7_neon-vfpv4  arm_cortex-a7
A arm_cortex-a7_vfpv4       arm_cortex-a7
A arm_cortex-a9_vfpv3-d16   arm_cortex-a7
A arm_cortex-a15_neon-vfpv4 arm_cortex-a7
A arm_cortex-a53_neon-vfpv4 arm_cortex-a7
A arm_cortex-a9             E_ARCH novfp
A arm_cortex-a9             arm_cortex-a7 vfp
A arm_cortex-a7             arm_cortex-a7 vfp
A arm_arm926ej-s            E_ARCH
A arm_arm1176jzf-s_vfp      E_ARCH
A arm_mpcore                E_ARCH
A arm_xscale                E_ARCH
A mipsel_24kc               mipsel_24kc
A mips_24kc                 mips_24kc
A mipsel_74kc               mipsel_24kc
A mipsel_1004kc             mipsel_24kc
A mips_34kc                 mips_24kc
A mips_74kc                 mips_24kc
A mips64_octeonplus         E_ARCH
A i386_pentium4             E_ARCH
A x86_64                    x86_64

# apk (OpenWrt 25.12+): --print-arch
reset_engine
_had_apk=0; [ -d /etc/apk ] && _had_apk=1
mkdir -p /etc/apk
echo aarch64_cortex-a53 > "$ESH/arch"
begin "engine/arch-apk-print-arch"
E arch
expect_jq "apk arch -> aarch64" "$EJ" '.ok==true and .arch=="aarch64" and .pm_arch=="aarch64_cortex-a53"'
end
[ "$_had_apk" = 1 ] || rmdir /etc/apk 2>/dev/null

# ---- 2. refusals before any download (no download call at all) ----
reset_engine; put_working
echo mips64_octeonplus > "$ESH/arch"
refuse unknown-arch-refused E_ARCH install
expect_eq "no download attempted" "$(calls_to http)" 0
end

reset_engine; put_working
echo 1000 > "$ESH/df.avail"
refuse no-space-refused E_SPACE install
expect_eq "no download attempted" "$(calls_to http)" 0
expect_jq "says how much is free / needed" "$EJ" '.avail_kb=="1000" and (.need_kb|tonumber) > 44000'
end

reset_engine; put_working
meminfo 2000000 20000
refuse low-memavailable-refused E_MEM install
expect_eq "no download attempted" "$(calls_to http)" 0
end

reset_engine; put_working
meminfo 120000 100000
refuse ram-mode-small-memtotal-refused E_RAM_TOTAL install --ram
expect_eq "no download attempted" "$(calls_to http)" 0
expect_jq "threshold: MemTotal 200 MB by default (the 256 MB RAM class)" "$EJ" '.need_kb=="204800"'
end

reset_engine; WORK_SHA=none        # nothing installed: update must not install either
refuse update-without-engine-refused E_NOT_INSTALLED update
end

# ---- 3. refusals in the pipeline: sha / version / check / download ----
# corrupted asset under the PINNED version: the pinned hash rejects it
reset_engine; put_working
mkdir -p "$ESRV/v$PIN"
if [ -f "$REAL_ASSET" ]; then cp "$REAL_ASSET" "$EW/corrupt"; printf 'X' | dd of="$EW/corrupt" bs=1 seek=1000 conv=notrunc 2>/dev/null
else fake_engine "$EW/corrupt" "$PIN" 0; fi
cp "$EW/corrupt" "$ESRV/v$PIN/vpnpool-engine_${PIN}_x86_64"
refuse corrupt-asset-sha-refused E_SHA install
expect_eq "downloaded once (pinned hash, no .sha256 fetch)" "$(calls_to "$REL/v$PIN/vpnpool-engine_${PIN}_x86_64")" 1
expect_eq "no .sha256 fetched for the pinned version" "$(calls_to .sha256)" 0
end
rm -f "$ESRV/v$PIN/vpnpool-engine_${PIN}_x86_64"

# override version with a .sha256 that does not match the file
reset_engine; put_working
fake_engine "$EW/f80" 1.14.3-awg.80 0
publish 1.14.3-awg.80 "$EW/f80" "0000000000000000000000000000000000000000000000000000000000000000  vpnpool-engine_1.14.3-awg.80_x86_64"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.80
refuse override-sha-mismatch-refused E_SHA install
end

reset_engine; put_working
fake_engine "$EW/f81" 1.14.3-awg.81 0
publish 1.14.3-awg.81 "$EW/f81" -
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.81
refuse override-no-sha256-refused E_SHA_UNKNOWN install
expect_eq "binary never downloaded without a hash" "$(gcount 'awg.81_x86_64$' "$ESH/calls")" 0
expect_eq ".sha256 tried: 3x uclient-fetch, 1x wget" "$(gcount '^uclient-fetch .*awg.81_x86_64.sha256$' "$ESH/calls") $(gcount '^wget .*awg.81_x86_64.sha256$' "$ESH/calls")" "3 1"
end

reset_engine; put_working
fake_engine "$EW/f82" 1.14.3-awg.82 0
publish 1.14.3-awg.82 "$EW/f82" "not-a-hash"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.82
refuse override-garbage-sha256-refused E_SHA_UNKNOWN install
end

reset_engine; put_working
fake_engine "$EW/f83" 9.9.9 0
publish 1.14.3-awg.83 "$EW/f83"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.83
refuse wrong-version-refused E_VERSION install
expect_jq "reports both versions" "$EJ" '.want=="1.14.3-awg.83" and .got=="9.9.9"'
end

reset_engine; put_working
fake_engine "$EW/f84" 1.14.3-awg.84 1
publish 1.14.3-awg.84 "$EW/f84"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.84
refuse no-awg-check-refused E_CHECK install
end

reset_engine; put_working
mkdir -p "$ESRV/v1.14.3-awg.85"
echo "1111111111111111111111111111111111111111111111111111111111111111  x" > "$ESRV/v1.14.3-awg.85/vpnpool-engine_1.14.3-awg.85_x86_64.sha256"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.85
refuse download-404-refused E_DOWNLOAD install
expect_eq "3 tries with uclient-fetch, then 1 with wget" "$(grep -c '^uclient-fetch .*awg.85_x86_64$' "$ESH/calls") $(grep -c '^wget .*awg.85_x86_64$' "$ESH/calls")" "3 1"
end

# lock: a LIVE holder refuses; a dead holder (SIGKILL/OOM) is stale and is taken over
reset_engine; put_working
mkdir -p "$EW/lock"; sleep 300 & _lp=$!; echo "$_lp" > "$EW/lock/pid"
refuse busy-lock-refused E_BUSY install
end
kill "$_lp" 2>/dev/null; wait "$_lp" 2>/dev/null

# ---- 4. successful installs (fake engine under an override version) ----
reset_engine; put_working
fake_engine "$EW/f90" 1.14.3-awg.90 0 NEW-ENGINE
publish 1.14.3-awg.90 "$EW/f90"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.90
mkdir -p "$EW/lock"; echo 999999 > "$EW/lock/pid"     # stale lock from a killed run
begin "engine/override-install-ok-stale-lock"
E install
expect_true "exit 0 (rc=$ERC)" [ "$ERC" -eq 0 ]
expect_jq "ok, changed, version" "$EJ" '.ok and .changed==true and .version=="1.14.3-awg.90" and .path=="/usr/bin/sing-box-awg" and .arch=="x86_64"'
expect_eq "new engine in place" "$(sha_of "$BIN")" "$(sha_of "$EW/f90")"
expect_true "executable" [ -x "$BIN" ]
expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
_st=$(cat /etc/vpnpool/awg-engine.json 2>/dev/null)
expect_jq "record: version, sha, date, path" "$_st" ".version==\"1.14.3-awg.90\" and .sha256==\"$(sha_of "$EW/f90")\" and .path==\"/usr/bin/sing-box-awg\" and .ram==false and (.installed_at|length==20 and startswith(\"20\") and endswith(\"Z\"))"
expect_true "lock released" [ ! -e "$EW/lock" ]
end

begin "engine/status-json"
E status
expect_jq "installed, version, awg ok, current" "$EJ" '.ok and .installed==true and .version=="1.14.3-awg.90" and .awg==true and .current==true and .record.version=="1.14.3-awg.90"'
end

begin "engine/install-again-no-download"
: > "$ESH/calls"
E install
expect_jq "unchanged" "$EJ" '.ok and .changed==false'
expect_eq "no download" "$(calls_to http)" 0
end

begin "engine/update-current-is-noop"
E update
expect_jq "unchanged" "$EJ" '.ok and .changed==false and .action=="update"'
end

fake_engine "$EW/f91" 1.14.3-awg.91 0
publish 1.14.3-awg.91 "$EW/f91"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.91 VPNPOOL_ENGINE_FETCH=wget
begin "engine/update-to-newer-via-wget"
: > "$ESH/calls"
E update
expect_jq "updated" "$EJ" '.ok and .changed==true and .version=="1.14.3-awg.91"'
expect_eq "fetched with wget" "$(grep -c '^wget ' "$ESH/calls")" 2
expect_eq "new binary" "$(sha_of "$BIN")" "$(sha_of "$EW/f91")"
end

begin "engine/remove"
E remove
expect_jq "removed" "$EJ" '.ok and .removed==true'
expect_true "binary gone" [ ! -e "$BIN" ]
expect_true "record gone" [ ! -e /etc/vpnpool/awg-engine.json ]
expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
E status
expect_jq "status: not installed" "$EJ" '.ok and .installed==false and .version==null and .awg==false'
end

# RAM mode (16 MB flash): binary in tmpfs, /usr/bin/sing-box-awg is a symlink to it
reset_engine
fake_engine "$EW/f92" 1.14.3-awg.92 0
publish 1.14.3-awg.92 "$EW/f92"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.92 VPNPOOL_ENGINE_RAM_DIR="$EW/ram/usr/bin"
meminfo 524288 400000
begin "engine/ram-mode-install"
E install --ram
expect_jq "ok" "$EJ" ".ok and .changed==true and .real_path==\"$EW/ram/usr/bin/sing-box-awg\""
expect_true "symlink" [ -L "$BIN" ]
expect_eq "points to the RAM copy" "$(readlink "$BIN")" "$EW/ram/usr/bin/sing-box-awg"
expect_jq "record ram:true" "$(cat /etc/vpnpool/awg-engine.json)" '.ram==true'
E remove
expect_true "RAM copy + link removed" sh -c '[ ! -e "$1" ] && [ ! -L "$2" ]' _ "$EW/ram/usr/bin/sing-box-awg" "$BIN"
end
reset_engine

# RAM mode on a "256 MB RAM" router: MemTotal is below the physical size (kernel, reserved)
fake_engine "$EW/f93" 1.14.3-awg.93 0
publish 1.14.3-awg.93 "$EW/f93"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.93 VPNPOOL_ENGINE_RAM_DIR="$EW/ram/usr/bin"
meminfo 245000 200000
begin "engine/ram-mode-256mb-class-ok"
E install --ram
expect_jq "installed in RAM" "$EJ" ".ok and .changed==true and .real_path==\"$EW/ram/usr/bin/sing-box-awg\""
end

# update without --ram keeps the RAM mode of the record (no download onto a 16 MB flash)
fake_engine "$EW/f94" 1.14.3-awg.94 0
publish 1.14.3-awg.94 "$EW/f94"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.94
begin "engine/update-keeps-ram-mode"
E update
expect_jq "updated, still in RAM" "$EJ" ".ok and .changed==true and .version==\"1.14.3-awg.94\" and .real_path==\"$EW/ram/usr/bin/sing-box-awg\""
expect_jq "record ram:true" "$(cat /etc/vpnpool/awg-engine.json)" '.ram==true and .version=="1.14.3-awg.94"'
expect_true "nothing written to the flash path" [ -L "$BIN" ]
end
E remove
reset_engine

# a temp file left by a run that died without its trap (power cut): removed, install proceeds
fake_engine "$EW/f96" 1.14.3-awg.96 0
publish 1.14.3-awg.96 "$EW/f96"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.96
head -c 4096 /dev/zero > /usr/bin/.sing-box-awg.new.123
begin "engine/orphan-temp-file-removed"
E install
expect_jq "ok" "$EJ" '.ok and .changed==true'
expect_true "orphan gone" [ ! -e /usr/bin/.sing-box-awg.new.123 ]
expect_eq "no temp file left" "$(ls -a /usr/bin | grep -c '^\.sing-box-awg\.new')" 0
end
reset_engine

# uclient-fetch that can't do HTTPS at all: wget takes over
fake_engine "$EW/f97" 1.14.3-awg.97 0
publish 1.14.3-awg.97 "$EW/f97"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.97
: > "$ESH/uclient.broken"
begin "engine/downloader-fallback-to-wget"
E install
expect_jq "ok" "$EJ" '.ok and .changed==true'
expect_eq "uclient-fetch tried 3 times for the .sha256, then wget" "$(grep -c '^uclient-fetch .*awg.97_x86_64.sha256$' "$ESH/calls") $(grep -c '^wget .*awg.97_x86_64.sha256$' "$ESH/calls")" "3 1"
expect_eq "binary fetched by wget" "$(grep -c '^wget .*awg.97_x86_64$' "$ESH/calls")" 1
expect_eq "engine in place" "$(sha_of "$BIN")" "$(sha_of "$EW/f97")"
end
reset_engine

# ---- 4c. the stock sing-box: detection + automatic restore (old vpnpool 1.4.x fork) ----
# Stock binary at a path outside /tmp (a path under /tmp reads as the RAM copy).
SB_DIR=/opt/stand/stocktest; mkdir -p "$SB_DIR"
SB="$SB_DIR/sing-box"
fake_sb() { printf '#!/bin/sh\n[ "$1" = version ] && { echo "sing-box version %s"; echo; echo "Environment: go"; exit 0; }\nexit 1\n' "$2" > "$1"; chmod +x "$1"; }
opkg_status() {   # <version> <hold|user>
	printf 'Package: sing-box\nVersion: %s\nDepends: libc, ca-bundle, kmod-inet-diag, kmod-tun\nStatus: install %s installed\nArchitecture: x86_64\n' "$1" "$2" > "$ESH/opkg.status"
}
fake_sb "$EW/stock-1.12.25" 1.12.25
fake_sb "$EW/fork" 1.13.13-awg2.1
fake_sb "$EW/stock-1.11.0" 1.11.0
printf '#!/bin/sh\necho "podkop $*" >> "%s/podkop.log"\n[ "$1" = enabled ] && exit 0\nexit 0\n' "$EW" > "$EW/podkop"; chmod +x "$EW/podkop"
printf '#!/bin/sh\n# vpnpool small-flash boot hook (opkg)\nuclient-fetch -qO /tmp/usr/bin/sing-box "https://github.com/hoaxisr/amnezia-box/releases/download/v1.13.13-awg2.1/sing-box-1.13.13-awg2.1-entware-mipsel"\n' > "$EW/old-hook"
stock_env() { export VPNPOOL_STOCK_BIN="$SB" ENGINE_PM="$1" ENGINE_PODKOP_INIT="$EW/podkop" ENGINE_APK_WORLD="$EW/world"; cp "$EW/stock-1.12.25" "$ESH/stock.new"; rm -f "$EW/podkop.log"; }

reset_engine; stock_env opkg
cp "$EW/stock-1.12.25" "$SB"; opkg_status 1.12.25-r1 user
begin "engine/stock-clean-not-replaced"
E status
expect_jq "replaced:false" "$EJ" '.stock.replaced==false and .stock.version=="1.12.25" and .stock.pkg_version=="1.12.25-r1" and .stock.held==false and .stock.hook_fork==false'
end

reset_engine; stock_env opkg
cp "$EW/fork" "$SB"; opkg_status 1.12.25-r1 hold
begin "engine/stock-fork-detected-opkg"
export ENGINE_RAM_HOOK="$EW/old-hook"; E status; unset ENGINE_RAM_HOOK
expect_jq "replaced by an awg build, held, old hook seen" "$EJ" '.stock.replaced==true and .stock.reason=="awg_build" and .stock.held==true and .stock.version=="1.13.13-awg2.1" and .stock.hook_fork==true'
end

reset_engine; stock_env opkg
cp "$EW/stock-1.11.0" "$SB"; opkg_status 1.12.25-r1 user
begin "engine/stock-version-mismatch-detected"
E status
expect_jq "replaced: version_mismatch" "$EJ" '.stock.replaced==true and .stock.reason=="version_mismatch"'
end

reset_engine; stock_env opkg
rm -f "$SB"; cp "$EW/stock-1.12.25" "$EW/ramcopy"; ln -s "$EW/ramcopy" "$SB"; opkg_status 1.12.25-r1 user
begin "engine/stock-ram-copy-unknown"
E status
expect_jq "RAM copy: can't tell" "$EJ" '.stock.replaced==null and .stock.reason=="ram"'
end
rm -f "$SB"

# install with the fork in place: engine first, then the stock package comes back
reset_engine; stock_env opkg
cp "$EW/fork" "$SB"; opkg_status 1.12.25-r1 hold
fake_engine "$EW/f98" 1.14.3-awg.98 0
publish 1.14.3-awg.98 "$EW/f98"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.98
begin "engine/install-restores-stock-opkg"
E install
expect_jq "engine installed, stock restored, podkop restarted" "$EJ" '.ok and .changed==true and .stock_replaced==true and .stock_reason=="awg_build" and .stock_restored==true and .podkop_restarted==true'
expect_eq "engine in place" "$(sha_of "$BIN")" "$(sha_of "$EW/f98")"
expect_eq "stock binary back" "$(sha_of "$SB")" "$(sha_of "$EW/stock-1.12.25")"
expect_true "hold removed" grep -q '^opkg flag user sing-box' "$ESH/pm.log"
expect_true "package downloaded before the reinstall" sh -c 'a=$(grep -n "^opkg download sing-box" "$1" | head -1 | cut -d: -f1); b=$(grep -n "^opkg install --force-reinstall" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$ESH/pm.log"
expect_true "podkop restarted" grep -q '^podkop restart' "$EW/podkop.log"
E status
expect_jq "status: stock clean now" "$EJ" '.stock.replaced==false and .stock.held==false'
end

# the stock package can't be fetched: the engine install stands, the fork is left as it was
reset_engine; stock_env opkg
cp "$EW/fork" "$SB"; opkg_status 1.12.25-r1 hold
: > "$ESH/pm.fail"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.98
begin "engine/stock-restore-fails-engine-stays"
E install
expect_true "exit 0 (rc=$ERC)" [ "$ERC" -eq 0 ]
expect_jq "ok, restore failed with a code" "$EJ" '.ok and .changed==true and .stock_restored==false and .stock_code=="E_STOCK_DOWNLOAD"'
expect_eq "engine in place" "$(sha_of "$BIN")" "$(sha_of "$EW/f98")"
expect_eq "old binary untouched (never left without one)" "$(sha_of "$SB")" "$(sha_of "$EW/fork")"
expect_true "podkop not touched" [ ! -e "$EW/podkop.log" ]
E restore-stock
expect_jq "restore-stock alone: same code" "$EJ" '.ok==false and .code=="E_STOCK_DOWNLOAD"'
rm -f "$ESH/pm.fail"
E restore-stock
expect_jq "restore-stock once the package is reachable" "$EJ" '.ok and .changed==true and .stock_reason=="awg_build"'
expect_eq "stock binary back" "$(sha_of "$SB")" "$(sha_of "$EW/stock-1.12.25")"
end

# apk (25.12): apk keeps a checksum per file -> `apk audit` is the evidence; version pin in world
reset_engine; stock_env apk
cp "$EW/stock-1.11.0" "$SB"
echo "sing-box-1.12.25-r1 x86_64 {sing-box} (GPL-3.0-or-later) [installed]" > "$ESH/apk.list"
echo "U ${SB#/}" > "$ESH/apk.audit"
printf 'luci\nsing-box=1.12.25-r1\nvpnpool\n' > "$EW/world"
export VPNPOOL_ENGINE_VERSION=1.14.3-awg.98
begin "engine/install-restores-stock-apk"
E status
expect_jq "status: replaced (checksum), pinned" "$EJ" '.stock.replaced==true and .stock.reason=="checksum" and .stock.held==true'
E install
expect_jq "restored" "$EJ" '.ok and .stock_replaced==true and .stock_reason=="checksum" and .stock_restored==true'
expect_true "pin dropped" sh -c '! grep -q "^sing-box=" "$1" && grep -q "^sing-box$" "$1"' _ "$EW/world"
expect_true "apk fix --reinstall" grep -q '^apk fix --reinstall sing-box' "$ESH/pm.log"
expect_eq "stock binary back" "$(sha_of "$SB")" "$(sha_of "$EW/stock-1.12.25")"
end

reset_engine; stock_env opkg
cp "$EW/stock-1.12.25" "$SB"; opkg_status 1.12.25-r1 user
begin "engine/restore-stock-noop-when-clean"
E restore-stock
expect_jq "nothing to do" "$EJ" '.ok and .changed==false and .stock_replaced==false'
expect_eq "no package-manager writes" "$(gcount -E '^opkg (flag|download|install)' "$ESH/pm.log")" 0
end
reset_engine

# ---- 5. the REAL release asset (x86_64) ----
begin "engine/real-asset-mounted"
expect_true "real asset at $REAL_ASSET (set ENGINE_ASSET_DIR for run-in-docker.sh)" [ -f "$REAL_ASSET" ]
end
if [ -f "$REAL_ASSET" ]; then
	mkdir -p "$ESRV/v$PIN"
	cp "$REAL_ASSET" "$ESRV/v$PIN/vpnpool-engine_${PIN}_x86_64"
	reset_engine
	begin "engine/real-install-pinned"
	E install
	expect_true "exit 0 (rc=$ERC)" [ "$ERC" -eq 0 ]
	expect_jq "ok" "$EJ" ".ok and .changed==true and .version==\"$PIN\" and .sha256==\"1a145e0ceffb7d8dc0936657d0364e7a112ae1b4ec8bbbcc6e82a379eecdbc19\""
	expect_eq "exact release URL" "$(calls_to "$REL/v$PIN/vpnpool-engine_${PIN}_x86_64")" 1
	expect_eq "version -n" "$("$BIN" version -n 2>/dev/null)" "$PIN"
	expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
	end

	begin "engine/real-status-awg"
	E status
	expect_jq "installed + awg + current" "$EJ" ".installed and .awg==true and .current==true and .version==\"$PIN\""
	end

	# positive control for the AWG probe: stock sing-box must FAIL it
	begin "engine/stock-has-no-awg"
	run_with_timeout 60 env VPNPOOL_ENGINE_BIN="$STOCK" sh -c 'sh "$1" status > "$2" 2>/dev/null' _ "$ENG" "$EW/stock.json"
	expect_jq "stock: installed, awg false" "$(cat "$EW/stock.json")" '.installed==true and .awg==false and .current==false'
	end

	begin "engine/real-install-again-noop"
	: > "$ESH/calls"
	E install
	expect_jq "unchanged" "$EJ" '.ok and .changed==false'
	expect_eq "no download" "$(calls_to http)" 0
	end

	# corrupt real asset over a working real engine: refused, working one kept
	WORK_SHA=$(sha_of "$BIN")
	cp "$EW/corrupt" "$ESRV/v$PIN/vpnpool-engine_${PIN}_x86_64"
	rm -f /etc/vpnpool/awg-engine.json
	refuse real-corrupt-over-working E_SHA install --force
	expect_eq "still the real engine" "$("$BIN" version -n 2>/dev/null)" "$PIN"
	end
	reset_engine
fi

# ---- 6. install.sh drives engine.sh (VPNPOOL_AWG=1), offline ----
# Package-manager double: every opkg call "succeeds"; `install -d ram … sing-box` puts a copy of
# the stock binary into /tmp/usr/bin (what the real RAM flow does). The engine is a fake under
# an override version, so this part needs no real asset.
ISH="$T_STATE/install-shim"; mkdir -p "$ISH" "$EW/pkg"
cp "$ESH/uclient-fetch" "$ESH/wget" "$ISH/"
STOCK_REAL=$(readlink -f "$STOCK"); cp "$STOCK_REAL" "$EW/stock.bak"
cat > "$ISH/opkg" <<EOF
#!/bin/sh
case "\$1" in
	print-architecture) echo "arch all 1"; echo "arch \$(cat "\$ESH/arch") 10" ;;
	status|flag|download) exec "\$ESH/opkg" "\$@" ;;
	install) echo "\$*" >> "$EW/pm.log"
		case " \$* " in
		*" -d ram "*) mkdir -p /tmp/usr/bin; cp "$EW/stock.bak" /tmp/usr/bin/sing-box ;;
		*sing-box_*.ipk*) exec "\$ESH/opkg" "\$@" ;;    # engine.sh putting the stock package back
	esac ;;
esac
exit 0
EOF
# apk double (OpenWrt 25.12 stand): same idea; RAM flow = `apk fetch` + `apk extract`
cat > "$ISH/apk" <<EOF
#!/bin/sh
case "\$1" in
	--print-arch) cat "\$ESH/arch" ;;
	fetch) while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { shift; : > "\$1/sing-box-1.0-r1.apk"; }; shift; done ;;
	extract) while [ \$# -gt 0 ]; do [ "\$1" = --destination ] && { shift; mkdir -p "\$1/usr/bin"; cp "$EW/stock.bak" "\$1/usr/bin/sing-box"; }; shift; done ;;
	list|audit|fix) exec "\$ESH/apk" "\$@" ;;
	add) [ "\$2" = sing-box ] && exec "\$ESH/apk" "\$@" ;;
esac
exit 0
EOF
chmod +x "$ISH/opkg" "$ISH/apk"
: > "$EW/pkg/vpnpool_2.0.0-r1_all.ipk"; : > "$EW/pkg/luci-app-vpnpool_2.0.0-r1_all.ipk"
: > "$EW/pkg/vpnpool-2.0.0-r1.apk"; : > "$EW/pkg/luci-app-vpnpool-2.0.0-r1.apk"
: > "$EW/pkg/luci-i18n-vpnpool-ru_26.288.12345~abcdef0_all.ipk"; : > "$EW/pkg/luci-i18n-vpnpool-ru-26.288.12345~abcdef0.apk"
# the order the package files were handed to opkg: base, web UI, then its translation
inst_order() { grep -oE '(vpnpool|luci-app-vpnpool|luci-i18n-vpnpool-ru)_[^ ]*\.ipk' "$EW/pm.log" | sed 's/_.*//' | tr '\n' ' '; }
HOOKF=/etc/hotplug.d/iface/99-vpnpool-singbox-ram
INST() {   # <VPNPOOL_AWG> <VPNPOOL_RAM_SINGBOX> — runs install.sh; IOUT / IRC
	run_with_timeout 180 env PATH="$ISH:$PATH" ESH="$ESH" ESRV="$ESRV" ENGINE_MEMINFO="$ESH/meminfo" \
		ENGINE_LOCK="$EW/lock" ENGINE_RETRY_SLEEP=0 VPNPOOL_PKG_DIR="$EW/pkg" VPNPOOL_AWG="$1" \
		VPNPOOL_RAM_SINGBOX="$2" VPNPOOL_ENGINE_VERSION=1.14.3-awg.95 \
		sh -c 'sh "$1" > "$2" 2>&1' _ "$REPO/install.sh" "$EW/inst.log"
	IRC=$?; IOUT=$(cat "$EW/inst.log" 2>/dev/null)
}
inst_no_internals() {   # what the installer prints is for people: no engine codes / JSON
	expect_true "no E_* code or JSON in the installer output" sh -c '! grep -qE "E_[A-Z_]+|\{\"ok\"" "$1"' _ "$EW/inst.log"
}
fake_engine "$EW/f95" 1.14.3-awg.95 0
publish 1.14.3-awg.95 "$EW/f95"

begin "engine/install-sh-no-hoaxisr-fork"
expect_eq "no pinned remote fork left" "$(gcount -iE 'hoaxisr|amnezia-box|1\.13\.13-awg' "$REPO/install.sh")" 0
expect_true "calls engine.sh" grep -q '/usr/libexec/vpnpool/engine.sh' "$REPO/install.sh"
end

reset_engine
rm -f "$EW/pm.log"
begin "engine/install-sh-awg1-flash"
INST 1 0
expect_eq "packages installed: base, web UI, its Russian translation" "$(inst_order)" "vpnpool luci-app-vpnpool luci-i18n-vpnpool-ru "
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "says the build is installed" grep -q 'AmneziaWG: build 1.14.3-awg.95 installed' "$EW/inst.log"
expect_eq "engine in place" "$(sha_of "$BIN")" "$(sha_of "$EW/f95")"
expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
inst_no_internals
end

# flash router of a 1.4.x user: the fork stands in place of the stock sing-box (held)
reset_engine; stock_env opkg
cp "$EW/fork" "$SB"; opkg_status 1.12.25-r1 hold
begin "engine/install-sh-restores-stock"
INST 1 0
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "says the build is installed" grep -q 'AmneziaWG: build 1.14.3-awg.95 installed' "$EW/inst.log"
expect_true "says the standard sing-box is back" grep -q 'the standard sing-box is back in place of the old AmneziaWG build' "$EW/inst.log"
expect_true "says podkop was restarted" grep -q 'podkop was restarted' "$EW/inst.log"
expect_eq "stock binary back" "$(sha_of "$SB")" "$(sha_of "$EW/stock-1.12.25")"
inst_no_internals
end

reset_engine; stock_env opkg
cp "$EW/fork" "$SB"; opkg_status 1.12.25-r1 hold; : > "$ESH/pm.fail"
begin "engine/install-sh-stock-restore-fails"
INST 1 0
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "engine installed anyway" grep -q 'AmneziaWG: build 1.14.3-awg.95 installed' "$EW/inst.log"
expect_true "plain warning + the command to retry" sh -c 'grep -q "could not be replaced now" "$1" && grep -q "engine.sh restore-stock" "$1"' _ "$EW/inst.log"
expect_eq "old binary untouched" "$(sha_of "$SB")" "$(sha_of "$EW/fork")"
inst_no_internals
end
reset_engine
echo mips64_octeonplus > "$ESH/arch"
begin "engine/install-sh-awg1-unsupported-arch"
INST 1 0
expect_true "exit 0: vpnpool still installed (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "plain message about the processor" grep -q "no AmneziaWG build for this router's processor" "$EW/inst.log"
expect_true "no engine" [ ! -e "$BIN" ]
expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
inst_no_internals
end

reset_engine
begin "engine/install-sh-update-without-engine"
INST update 0
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "tells to use VPNPOOL_AWG=1" grep -q 'not installed yet (use VPNPOOL_AWG=1)' "$EW/inst.log"
inst_no_internals
end

# RAM flow (16 MB flash) on a small-RAM router: stock sing-box in RAM, AWG refused, hook renders
reset_engine
meminfo 131072 90000
# a 1.4.x RAM router: its hook fetches the hoaxisr fork, plus a stray second vpnpool hook
cp "$EW/old-hook" "$HOOKF"; printf '#!/bin/sh\n# old\n' > /etc/hotplug.d/iface/50-vpnpool-old
rm -f "$EW/pm.log"
begin "engine/install-sh-ram-small-memory"
INST 1 1
expect_eq "small flash: packages incl. the translation" "$(inst_order)" "vpnpool luci-app-vpnpool luci-i18n-vpnpool-ru "
expect_true "small flash: the translation without dependencies (--nodeps)" grep -q -- '--nodeps --force-reinstall .*luci-i18n-vpnpool-ru_' "$EW/pm.log"
expect_true "the fork-era hook is replaced" sh -c '! grep -qiE "hoaxisr|amnezia-box" "$1"' _ "$HOOKF"
expect_true "other vpnpool hooks removed" [ ! -e /etc/hotplug.d/iface/50-vpnpool-old ]
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "plain message about memory" grep -q 'too little memory to keep the AmneziaWG build in RAM' "$EW/inst.log"
expect_true "no engine" [ ! -e "$BIN" ]
expect_true "boot hook written" [ -s "$HOOKF" ]
expect_true "boot hook is valid sh" sh -n "$HOOKF"
expect_true "boot hook: same engine pipeline, RAM mode, same version" grep -q 'VPNPOOL_ENGINE_VERSION=1.14.3-awg.95 sh /usr/libexec/vpnpool/engine.sh install --ram' "$HOOKF"
expect_true "boot hook: stock sing-box before the engine" sh -c 'a=$(grep -n "ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box" "$1" | cut -d: -f1); b=$(grep -n "engine.sh install --ram" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$HOOKF"
inst_no_internals
end

reset_engine
meminfo 524288 400000
VPNPOOL_ENGINE_RAM_DIR="$EW/ram/usr/bin"; export VPNPOOL_ENGINE_RAM_DIR
begin "engine/install-sh-ram-enough-memory"
INST 1 1
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "says the build is installed" grep -q 'AmneziaWG: build 1.14.3-awg.95 installed' "$EW/inst.log"
expect_true "engine is a link into RAM" [ -L "$BIN" ]
expect_eq "RAM copy is the build" "$(sha_of "$EW/ram/usr/bin/sing-box-awg")" "$(sha_of "$EW/f95")"
inst_no_internals
end
# the RAM flow repoints /usr/bin/sing-box to /tmp: put the stock binary back for later suites
rm -f "$STOCK" "$HOOKF"; cp "$EW/stock.bak" "$STOCK_REAL"; [ "$STOCK_REAL" = "$STOCK" ] || ln -sf "$STOCK_REAL" "$STOCK"
chmod +x "$STOCK_REAL"
begin "engine/stock-restored-after-install-tests"
expect_eq "stock sing-box back" "$(sha_of "$STOCK")" "$STOCK_SHA"
expect_true "rpcd still serves vpnpool" ubus list vpnpool
end
reset_engine
rm -rf "$ESRV" "$EW" "$ISH" /tmp/usr/bin/sing-box /tmp/vpnpool-install /opt/stand/stocktest
