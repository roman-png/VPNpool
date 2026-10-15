#!/bin/sh
# vpnpool: the user's explicit VPN on / off — ONE implementation for the LuCI switch (rpcd
# set_enabled), the schedule (sched.sh cron jobs) and Telegram /on.
#   off: enabled=0 + init.d reload -> procd stops ONLY the daemon instance (its TERM handler
#        removes the routes and stops sing-box); the Telegram bot instance keeps running, so a
#        later /on still arrives (it polls direct while our sing-box is down). We then WAIT for
#        the daemon to be gone; if it was killed before its cleanup ran, the routes and our
#        sing-box are removed here (the same steps, idempotent).
#   on:  enabled=1, the Telegram pause ends. A daemon that was running at enabled=1 only
#        re-decides its routing (HUP). After a recent off the old daemon may still be in its
#        cleanup: we wait for it to be gone and then start — a HUP to a dying daemon would
#        leave the VPN off with enabled=1.
# Boot hook: `init.d enable` keeps the service starting at boot (the bot must run at boot) —
# EXCEPT in the RAM mode of 16 MB routers, where install.sh disables autostart and a WAN-up
# hotplug hook starts the service once sing-box is in RAM; enabling it there would start the
# daemon before its engine exists.
# The kill-switch does NOT keep routes up after an explicit "off" (integrator's assumption,
# see route_policy in lib.sh). Exit 0 = done.
. /usr/libexec/vpnpool/lib.sh

RAM_HOOK=/etc/hotplug.d/iface/99-vpnpool-singbox-ram
WAIT_MAX=${POWER_WAIT_MAX:-20}   # seconds to wait for the old daemon to leave

daemon_pid() {   # the pidfile PID, only if it really is our daemon
	local p
	p=$(cat /var/run/vpnpool.pid 2>/dev/null); [ -n "$p" ] || return 1
	pgrep -f /usr/libexec/vpnpool/vpnpoold 2>/dev/null | grep -qx "$p" || return 1
	echo "$p"
}
wait_daemon_gone() {   # -> 0 when no daemon is left within WAIT_MAX seconds
	local i=0
	while daemon_pid >/dev/null; do
		[ "$i" -ge "$WAIT_MAX" ] && return 1
		i=$((i + 1)); sleep 1
	done
	return 0
}
boot_hook() { [ -f "$RAM_HOOK" ] || /etc/init.d/vpnpool enable >/dev/null 2>&1; }
# what the daemon's cleanup does, for a daemon that died before running it
leftovers_down() {
	local p
	/usr/libexec/vpnpool/route.sh down >/dev/null 2>&1
	for p in $( { pgrep -f "sing-box run -c $SB_CONF"; pgrep -f "sing-box run -c $SB_CONF_FLASH"; } 2>/dev/null | sort -u); do
		kill "$p" 2>/dev/null
	done
	rm -f /var/run/vpnpool-singbox.pid
}

case "$1" in
on)
	was=$(uci -q get vpnpool.main.enabled)
	uci set vpnpool.main.enabled=1; uci commit vpnpool
	rm -f "$PAUSE_FLAG"
	boot_hook
	if [ "$was" = 1 ] && signal_daemon HUP; then
		log "power: on (daemon already running — routing re-checked)"
		exit 0
	fi
	wait_daemon_gone || log "power: on — the previous daemon did not leave in ${WAIT_MAX}s"
	/etc/init.d/vpnpool start >/dev/null 2>&1
	log "power: on (service started)"
	;;
off)
	uci set vpnpool.main.enabled=0; uci commit vpnpool
	boot_hook
	/etc/init.d/vpnpool reload >/dev/null 2>&1
	if wait_daemon_gone; then
		leftovers_down
		log "power: off (daemon stopped, routing removed; Telegram bot kept)"
	else
		log "power: off — the daemon did not leave in ${WAIT_MAX}s"
	fi
	;;
*)
	echo "usage: $0 on|off" >&2; exit 2 ;;
esac
exit 0
