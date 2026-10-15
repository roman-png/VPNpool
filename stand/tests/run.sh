#!/bin/sh
# vpnpool stand test runner (busybox ash). Runs INSIDE the stand container:
#   stand/tests/run-in-docker.sh            (from the host — builds nothing, needs vpnpool-stand)
#   sh /repo/stand/tests/run.sh [suite...]  (inside a container started by run-in-docker.sh)
# Suites: parser build rpcd sched adaptive fetch status daemon tgbot uitext awgdecode engine   (default: all)
# Env: T_VERBOSE=1 prints PASS lines and the reasons behind XFAIL.
#
# Output contract (CI and the integrator read ONLY this line, never the absence of "FAIL"):
#   TESTS: passed=N failed=M xfail=K total=T xpass=X
# Exit code: 0 only if failed=0, xpass=0 and total>0.

T_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-/repo}
export T_DIR REPO
T_STATE=/tmp/vpnpool-tests
rm -rf "$T_STATE"; mkdir -p "$T_STATE"
export T_STATE
. "$T_DIR/lib.sh"

die() { echo "run.sh: $*" >&2; echo "TESTS: passed=0 failed=1 xfail=0 total=1 xpass=0"; exit 2; }

# ---- environment guard: we must be in the stand (real uci/ubus/rpcd + the package) ----
command -v uci >/dev/null && command -v ubus >/dev/null && command -v ucode >/dev/null \
	|| die "not inside the vpnpool stand (uci/ubus/ucode missing)"
[ -f /usr/libexec/vpnpool/lib.sh ] || die "package scripts not mounted at /usr/libexec/vpnpool"
[ -f "$REPO/package/vpnpool/files/etc/config/vpnpool" ] || die "repo not mounted at $REPO"
# rpcd execs the plugin and the plugin execs status.sh/diag.sh directly: on a Linux checkout
# that only works if git carries the exec bit (Docker Desktop on Windows shows 0755 anyway).
[ -x /usr/libexec/vpnpool/status.sh ] && [ -x "$REPO/package/luci-app-vpnpool/files/usr/libexec/rpcd/vpnpool" ] \
	|| die "package scripts are not executable (git file mode 100644?)"

# ---- curl test double for us AND for rpcd's children ----
mkdir -p /opt/stand/tests-bin /tmp/curlmock
cp "$T_DIR/shim/curl" /opt/stand/tests-bin/curl && chmod +x /opt/stand/tests-bin/curl
export MOCK_DIR=/tmp/curlmock
export PATH="/opt/stand/tests-bin:$PATH"

# ---- fake daemon (signal observer) at a path pgrep recognises as vpnpoold ----
FAKED=/opt/stand/fake/usr/libexec/vpnpool/vpnpoold
mkdir -p "$(dirname "$FAKED")"
cp "$T_DIR/fakedaemon.sh" "$FAKED" && chmod +x "$FAKED"
export FAKED_LOG="$T_STATE/daemon.signals"

# rpcd must inherit the shim PATH, so (re)start ubusd/rpcd from here (run-in-docker.sh
# bypasses the image entrypoint; if one did start rpcd, replace it).
mkdir -p /var/lock /var/run/ubus /etc/config /etc/vpnpool /tmp/vpnpool
[ -f /etc/config/network ] || printf "config interface 'lan'\n\toption device 'br-lan'\n" > /etc/config/network
for p in $(pgrep -x rpcd); do kill "$p" 2>/dev/null; done
i=0; while pgrep -x rpcd >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
pgrep -x ubusd >/dev/null 2>&1 || { ubusd & }
i=0; while [ ! -S /var/run/ubus/ubus.sock ] && [ ! -S /var/run/ubus.sock ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
mkdir -p /usr/libexec/rpcd
[ -e /usr/libexec/rpcd/vpnpool ] || ln -sf "$REPO/package/luci-app-vpnpool/files/usr/libexec/rpcd/vpnpool" /usr/libexec/rpcd/vpnpool
sleep 1
rpcd >/dev/null 2>&1 &
i=0; while ! ubus list vpnpool >/dev/null 2>&1 && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
ubus list vpnpool >/dev/null 2>&1 || die "rpcd did not expose the vpnpool ubus object"

# ---- shared helpers for suites ----
BASE_CONFIG="$REPO/package/vpnpool/files/etc/config/vpnpool"

reset_state() {   # fresh config + empty runtime/persistent dirs + no mocks + no daemon
	daemon_stop
	cp "$BASE_CONFIG" /etc/config/vpnpool
	rm -rf /tmp/vpnpool /etc/vpnpool /tmp/curlmock
	mkdir -p /tmp/vpnpool /etc/vpnpool /tmp/curlmock
	: > "$FAKED_LOG"
	rm -f /etc/crontabs/root /tmp/dhcp.leases
}

mock_on()   { mkdir -p /tmp/curlmock; : > /tmp/curlmock/enabled; : > /tmp/curlmock/rules; }
mock_rule() {   # <key-glob> <code> [body-file] [headers-file] [time_connect]
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:--}" "${5:-0.010}" >> /tmp/curlmock/rules
}
mock_calls() { gcount "$1" /tmp/curlmock/calls.log; }

daemon_start() {
	daemon_stop
	sh "$FAKED" >/dev/null 2>&1 &
	i=0; while [ ! -s /var/run/vpnpool.pid ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
	: > "$FAKED_LOG"
}
daemon_stop() {
	for p in $(pgrep -f "$FAKED" 2>/dev/null); do kill "$p" 2>/dev/null; done
	rm -f /var/run/vpnpool.pid
	i=0; while pgrep -f "$FAKED" >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
}
# signals_seen <USR1|USR2> — count after a short settle (trap runs after `sleep 1` wakes)
signals_seen() {
	_si=0
	while [ $_si -lt 3 ]; do sleep 1; [ "$(gcount "^$1\$" "$FAKED_LOG")" -ge 1 ] && break; _si=$((_si+1)); done
	gcount "^$1\$" "$FAKED_LOG"
}

# ubus call wrapper: sets R (stdout) and RC (ubus exit code)
rcall() {
	_ra="${2:-}"; [ -n "$_ra" ] || _ra='{}'
	R=$(ubus -t 60 call vpnpool "$1" "$_ra" 2>&1); RC=$?
}

at_least() { [ -n "$1" ] && [ "$2" -ge "$1" ]; }   # <min> <actual>

# ---- suites ----
ALL_SUITES="parser build rpcd sched adaptive fetch status daemon tgbot uitext awgdecode engine"
SUITES=${*:-$ALL_SUITES}
START=$(date +%s)
for s in $SUITES; do
	f="$T_DIR/suites/$s.sh"
	[ -f "$f" ] || die "unknown suite: $s"
	echo "=== suite: $s"
	reset_state
	s0=$(date +%s)
	set -- $(cat "$T_COUNTS"); c0=$(($1 + $2 + $3 + $4))
	. "$f"
	set -- $(cat "$T_COUNTS"); n=$(($1 + $2 + $3 + $4 - c0))
	# a suite that silently stopped early (or lost cases) must fail the run, not shrink total
	want=$(awk -v s="$s" '$1==s {print $2}' "$T_DIR/min-cases.txt" 2>/dev/null)
	begin "runner/$s-ran-at-least-${want:-?}-cases"
	expect_true "suite $s ran $n cases, minimum ${want:-<missing in min-cases.txt>}" at_least "$want" "$n"
	end
	echo "=== suite: $s done in $(( $(date +%s) - s0 ))s, $n cases"
done
daemon_stop

set -- $(cat "$T_COUNTS")
P=$1 F=$2 X=$3 XP=$4 C=$5
TOTAL=$((P + F + X + XP))
echo "checks executed: $C; wall time: $(( $(date +%s) - START ))s"
[ -f "$T_STATE/metrics" ] && { echo "metrics:"; sed 's/^/  /' "$T_STATE/metrics"; }
echo "TESTS: passed=$P failed=$F xfail=$X total=$TOTAL xpass=$XP"
[ "$F" -eq 0 ] && [ "$XP" -eq 0 ] && [ "$TOTAL" -gt 0 ] && [ "$C" -gt 0 ]
