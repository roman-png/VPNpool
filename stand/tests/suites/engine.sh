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
REAL_OPKG=$(command -v opkg)

# ---- test doubles ----
cat > "$ESH/uclient-fetch" <<'EOF'
#!/bin/sh
# serve <base>/v<ver>/<asset> from $ESRV; log every call; missing file = HTTP 404 (exit 1)
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
cat > "$ESH/opkg" <<EOF
#!/bin/sh
if [ "\$1" = print-architecture ] && [ -f "\$ESH/arch" ]; then
	echo "arch all 1"; echo "arch noarch 1"; echo "arch \$(cat "\$ESH/arch") 10"
else exec $REAL_OPKG "\$@"; fi
EOF
cat > "$ESH/apk" <<'EOF'
#!/bin/sh
[ "$1" = --print-arch ] && { cat "$ESH/arch"; exit 0; }
exit 1
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
		ENGINE_LOCK="$EW/lock" ENGINE_RETRY_SLEEP=0 ESH="$ESH" ESRV="$ESRV" \
		sh -c 'sh "$@" > "$0" 2>/dev/null' "$EW/out" "$ENG" "$@"
	ERC=$?
	EJ=$(cat "$EW/out" 2>/dev/null)
}
calls_to() { gcount -F "$1" "$ESH/calls"; }
sha_of() { [ -e "$1" ] && sha256sum "$1" | cut -d' ' -f1 || echo none; }
reset_engine() {
	rm -f "$BIN" "$ESH/calls" "$ESH/df.avail" "$ESH/arch" "$ESH/cpuinfo" /etc/vpnpool/awg-engine.json
	rm -rf "$EW/lock" "$EW/ram" /usr/bin/.sing-box-awg.new.*
	echo x86_64 > "$ESH/arch"
	meminfo 2000000 1500000
	: > "$ESH/calls"
	unset VPNPOOL_ENGINE_VERSION VPNPOOL_ENGINE_FETCH VPNPOOL_ENGINE_RAM_DIR VPNPOOL_ENGINE_RAM_MIN_MB
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
A mipsel_74kc               E_ARCH
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
meminfo 131072 100000
refuse ram-mode-small-memtotal-refused E_RAM_TOTAL install --ram
expect_eq "no download attempted" "$(calls_to http)" 0
expect_jq "threshold 256 MB by default" "$EJ" '.need_kb=="262144"'
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
expect_eq ".sha256 tried (with retries)" "$(gcount 'awg.81_x86_64.sha256$' "$ESH/calls")" 3
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
expect_eq "retried 3 times" "$(grep -c 'awg.85_x86_64$' "$ESH/calls")" 3
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
	install) case " \$* " in *" -d ram "*) mkdir -p /tmp/usr/bin; cp "$EW/stock.bak" /tmp/usr/bin/sing-box ;; esac ;;
esac
exit 0
EOF
chmod +x "$ISH/opkg"
: > "$EW/pkg/vpnpool_2.0.0-r1_all.ipk"; : > "$EW/pkg/luci-app-vpnpool_2.0.0-r1_all.ipk"
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
begin "engine/install-sh-awg1-flash"
INST 1 0
expect_true "exit 0 (rc=$IRC)" [ "$IRC" -eq 0 ]
expect_true "says the build is installed" grep -q 'AmneziaWG: build 1.14.3-awg.95 installed' "$EW/inst.log"
expect_eq "engine in place" "$(sha_of "$BIN")" "$(sha_of "$EW/f95")"
expect_eq "stock sing-box untouched" "$(sha_of "$STOCK")" "$STOCK_SHA"
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
rm -f "$HOOKF"
begin "engine/install-sh-ram-small-memory"
INST 1 1
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
rm -rf "$ESRV" "$EW" "$ISH" /tmp/usr/bin/sing-box /tmp/vpnpool-install
