#!/bin/sh
# vpnpool scheduler: render the uci schedule into a marked block in the root
# crontab. Times are "HH:MM" (24h, router local time).
#   sched_off     -> stop the service at that time
#   sched_on      -> start the service at that time
#   sched_refresh -> re-fetch the subscription (USR2 to the daemon)
. /usr/libexec/vpnpool/lib.sh

CRON=/etc/crontabs/root
BEGIN="# vpnpool-sched BEGIN"
END="# vpnpool-sched END"

# drop any previous vpnpool block
[ -f "$CRON" ] && sed -i "/vpnpool-sched BEGIN/,/vpnpool-sched END/d" "$CRON" 2>/dev/null

if [ "$(uci -q get vpnpool.main.sched_enabled)" = "1" ]; then
	ON=$(uci -q get vpnpool.main.sched_on)
	OFF=$(uci -q get vpnpool.main.sched_off)
	REF=$(uci -q get vpnpool.main.sched_refresh)
	mkdir -p /etc/crontabs

	emit_job() {   # $1=HH:MM  $2=command
		case "$1" in *:*) ;; *) return ;; esac
		h=${1%%:*}; m=${1#*:}
		# strip leading zeros so cron doesn't choke, keep numeric only
		case "$h$m" in (*[!0-9]*|"") return ;; esac
		echo "$((10#$m)) $((10#$h)) * * * $2"
	}

	{
		echo "$BEGIN"
		[ -n "$OFF" ] && emit_job "$OFF" "/etc/init.d/vpnpool stop"
		[ -n "$ON" ]  && emit_job "$ON"  "/etc/init.d/vpnpool start"
		[ -n "$REF" ] && emit_job "$REF" "kill -USR2 \$(cat /var/run/vpnpool.pid 2>/dev/null) 2>/dev/null"
		echo "$END"
	} >> "$CRON"
fi

/etc/init.d/cron enable >/dev/null 2>&1
/etc/init.d/cron restart >/dev/null 2>&1
exit 0
