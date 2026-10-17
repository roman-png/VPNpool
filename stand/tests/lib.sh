#!/bin/sh
# vpnpool stand test harness — assertion + accounting helpers (busybox ash).
#
# A test CASE is: begin <id>; one or more expect_* checks; end [<xfail-id>].
#   - a case with 0 checks is a FAILURE ("checked nothing" never counts as green);
#   - `end <plan-id>` marks a KNOWN defect from ROADMAP-2.0 (e.g. 2.1, 5): a failing case
#     is counted as XFAIL, a passing one as XPASS (the fix landed — drop the mark in the
#     same change). XPASS fails the run, so a stale mark can't hide.
# Counters live in a file (subshells / pipelines can't lose them).

T_STATE=${T_STATE:-/tmp/vpnpool-tests}
mkdir -p "$T_STATE"
T_COUNTS="$T_STATE/counts"
[ -f "$T_COUNTS" ] || echo "0 0 0 0 0" > "$T_COUNTS"   # passed failed xfail xpass checks
T_VERBOSE=${T_VERBOSE:-0}

_cnt_add() {   # $1=field index (1..5)  $2=increment
	set -- "$1" "$2" $(cat "$T_COUNTS")
	f=$1; inc=$2; shift 2
	p=$1 fl=$2 x=$3 xp=$4 c=$5
	case "$f" in 1) p=$((p+inc));; 2) fl=$((fl+inc));; 3) x=$((x+inc));; 4) xp=$((xp+inc));; 5) c=$((c+inc));; esac
	echo "$p $fl $x $xp $c" > "$T_COUNTS"
}

begin() {
	if [ -n "${T_CASE:-}" ]; then   # previous case never reached `end`: count it as a failure
		_cnt_add 2 1; echo "FAIL  $T_CASE (case not closed with end before \"$1\")"
	fi
	T_CASE="$1"; T_NCHK=0; T_NFAIL=0; T_WHY=""
}

_ok()   { T_NCHK=$((T_NCHK+1)); _cnt_add 5 1; }
_bad()  {
	T_NCHK=$((T_NCHK+1)); T_NFAIL=$((T_NFAIL+1)); _cnt_add 5 1
	T_WHY="${T_WHY}
      - $1"
}

# expect_true <description> <shell-command...>   (command's exit status decides)
expect_true() {
	d="$1"; shift
	if "$@" >/dev/null 2>&1; then _ok; else _bad "$d"; fi
}

# expect_eq <description> <actual> <expected>
expect_eq() {
	if [ "$2" = "$3" ]; then _ok; else _bad "$1: got [$(printf '%s' "$2" | head -c 300)] want [$3]"; fi
}

# expect_jq <description> <json> <jq-filter that must yield true>
expect_jq() {
	if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then _ok
	else _bad "$1: jq [$3] not true on: $(printf '%s' "$2" | tr '\n' ' ' | head -c 400)"; fi
}

# expect_le <description> <actual-int> <max>
expect_le() {
	case "$2" in (''|*[!0-9]*) _bad "$1: not a number [$2]"; return;; esac
	if [ "$2" -le "$3" ]; then _ok; else _bad "$1: $2 > $3"; fi
}

end() {
	xf="${1:-}"
	if [ "$T_NCHK" -eq 0 ]; then
		T_NFAIL=1; T_WHY="${T_WHY}
      - case checked NOTHING (0 checks) — not a pass"
	fi
	if [ -n "$xf" ]; then
		if [ "$T_NFAIL" -gt 0 ]; then
			_cnt_add 3 1; echo "XFAIL $T_CASE [$xf] ($T_NCHK checks, $T_NFAIL failed)"
			[ "$T_VERBOSE" = 1 ] && printf '%s\n' "$T_WHY" | sed '1d'
		else
			_cnt_add 4 1; echo "XPASS $T_CASE [$xf] ($T_NCHK checks) — known defect no longer reproduces: remove the xfail mark"
		fi
	else
		if [ "$T_NFAIL" -gt 0 ]; then
			_cnt_add 2 1; echo "FAIL  $T_CASE ($T_NCHK checks, $T_NFAIL failed)$T_WHY"
		else
			_cnt_add 1 1; [ "$T_VERBOSE" = 1 ] && echo "PASS  $T_CASE ($T_NCHK checks)"; :
		fi
	fi
	T_CASE=""
}

# metric <name> <value>  — printed and kept for the summary
metric() { echo "METRIC $1=$2"; echo "$1=$2" >> "$T_STATE/metrics"; }

# run_with_timeout <seconds> <cmd...>  — busybox here has no `timeout` applet.
# Exit 124 if the command had to be killed (same convention as coreutils timeout).
# A background watchdog kills the command on timeout; the caller just waits for the command, so a
# 10 ms command costs 10 ms (polling with `sleep 1` — busybox here takes integers only — made every
# call cost at least a second).
run_with_timeout() {
	secs=$1; shift
	"$@" &
	_rwt_pid=$!
	_rwt_flag="$T_STATE/.rwt.$_rwt_pid"; rm -f "$_rwt_flag"
	(
		_s=""
		trap '[ -n "$_s" ] && kill "$_s"; exit 0' TERM
		_i=0
		while [ "$_i" -lt "$secs" ]; do sleep 1 & _s=$!; wait "$_s"; _i=$((_i + 1)); done
		: > "$_rwt_flag"
		pkill_tree "$_rwt_pid"
		kill -TERM "$_rwt_pid" 2>/dev/null; sleep 1; kill -KILL "$_rwt_pid" 2>/dev/null
	) 2>/dev/null &
	_rwt_wd=$!
	wait "$_rwt_pid"; _rwt_rc=$?
	kill -TERM "$_rwt_wd" 2>/dev/null; wait "$_rwt_wd" 2>/dev/null
	if [ -f "$_rwt_flag" ]; then rm -f "$_rwt_flag"; return 124; fi
	return "$_rwt_rc"
}

# msleep <ms> — sub-second sleep (busybox sleep here takes integers only; ucode spawns in ~1 ms)
msleep() { ucode -e "sleep($1)"; }

pkill_tree() {   # best-effort: kill children of $1 (busybox has no pkill -P)
	for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
		[ "$(awk '/^PPid:/{print $2}' /proc/$p/status 2>/dev/null)" = "$1" ] && kill -KILL "$p" 2>/dev/null
	done
}

# gcount <grep-args...> — match count as ONE number (grep -c prints 0 AND exits 1, so the
# usual `grep -c ... || echo 0` yields "0\n0"; a missing file gives 0 too)
gcount() { _gc=$(grep -c "$@" 2>/dev/null); echo "${_gc:-0}"; }

# processes created in this PID namespace (the stand container) — kernel counter
last_pid() { cat /proc/sys/kernel/ns_last_pid; }
