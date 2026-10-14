#!/bin/sh
# vpnpool scheduler: render the uci schedule into a marked block in the root
# crontab. Times are "HH:MM" (24h, router local time).
#   sched_off     -> stop the service at that time
#   sched_on      -> start the service at that time
#   sched_refresh -> re-fetch the subscription (USR2 to the daemon)
# The crontab is rewritten through a temp file + mv (never left half-written). Only a
# COMPLETE "BEGIN … END" pair is removed: a lone BEGIN (e.g. left by an older version)
# and everything after it stay untouched, so user jobs are never swallowed.
# Exit: 0 = applied; 2 = a configured time is not a valid HH:MM (that job is not written).
. /usr/libexec/vpnpool/lib.sh

CRON=/etc/crontabs/root
BEGIN="# vpnpool-sched BEGIN"
END="# vpnpool-sched END"
rc=0

# valid_time HH:MM -> "M H" (no leading zeros) on stdout; rc 1 if not a real time of day
valid_time() {
	local h m
	case "$1" in [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;; *) return 1 ;; esac
	h=${1%%:*}; m=${1#*:}
	h=${h#0}; m=${m#0}; [ -n "$h" ] || h=0; [ -n "$m" ] || m=0
	[ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
	echo "$m $h"
}

mkdir -p /etc/crontabs
TMP="$CRON.vpnpool.$$"
# 1) the crontab without our (complete) block
if [ -f "$CRON" ]; then
	awk -v b="$BEGIN" -v e="$END" '
		$0 == b { if (inblk) { for (i = 1; i <= n; i++) print buf[i] } inblk = 1; n = 0; buf[++n] = $0; next }
		inblk && $0 == e { inblk = 0; n = 0; next }
		inblk { buf[++n] = $0; next }
		{ print }
		END { if (inblk) for (i = 1; i <= n; i++) print buf[i] }' "$CRON" > "$TMP" || { rm -f "$TMP"; exit 1; }
else
	: > "$TMP"
fi

# 2) our block, if enabled
if [ "$(uci -q get vpnpool.main.sched_enabled)" = "1" ]; then
	ON=$(uci -q get vpnpool.main.sched_on)
	OFF=$(uci -q get vpnpool.main.sched_off)
	REF=$(uci -q get vpnpool.main.sched_refresh)
	JOBS=""
	add_job() {   # $1=HH:MM (may be empty) $2=command
		local t
		[ -n "$1" ] || return 0
		if t=$(valid_time "$1"); then
			JOBS="${JOBS}$t * * * $2
"
		else
			log "sched: ignoring invalid time '$1' (expected HH:MM)"; rc=2
		fi
	}
	add_job "$OFF" "/etc/init.d/vpnpool stop"
	add_job "$ON"  "/etc/init.d/vpnpool start"
	add_job "$REF" "kill -USR2 \$(cat /var/run/vpnpool.pid 2>/dev/null) 2>/dev/null"
	if [ -n "$JOBS" ]; then
		{ echo "$BEGIN"; printf '%s' "$JOBS"; echo "$END"; } >> "$TMP"
	fi
fi

if cmp -s "$TMP" "$CRON" 2>/dev/null; then
	rm -f "$TMP"
else
	mv -f "$TMP" "$CRON" || { rm -f "$TMP"; exit 1; }
	/etc/init.d/cron enable >/dev/null 2>&1
	/etc/init.d/cron restart >/dev/null 2>&1
fi
exit "$rc"
