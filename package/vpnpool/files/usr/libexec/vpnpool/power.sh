#!/bin/sh
# vpnpool: the user's explicit VPN on / off — ONE implementation for the LuCI switch (rpcd
# set_enabled), the schedule (sched.sh cron jobs) and Telegram /on.
#   off: enabled=0 + init.d reload -> procd stops ONLY the daemon instance (its TERM handler
#        removes the routes and stops sing-box); the Telegram bot instance keeps running, so a
#        later /on still arrives (it polls direct while our sing-box is down). The service
#        stays enabled at boot: start_service itself honours enabled=0.
#   on:  enabled=1, the Telegram pause ends; a running daemon only re-decides its routing
#        (HUP), otherwise the service is started.
# The kill-switch does NOT keep routes up after an explicit "off" (integrator's assumption,
# see route_policy in lib.sh). Exit 0 = done.
. /usr/libexec/vpnpool/lib.sh

case "$1" in
on)
	uci set vpnpool.main.enabled=1; uci commit vpnpool
	rm -f "$PAUSE_FLAG"
	/etc/init.d/vpnpool enable >/dev/null 2>&1
	if signal_daemon HUP; then
		log "power: on (daemon already running — routing re-checked)"
	else
		/etc/init.d/vpnpool start >/dev/null 2>&1
		log "power: on (service started)"
	fi
	;;
off)
	uci set vpnpool.main.enabled=0; uci commit vpnpool
	/etc/init.d/vpnpool enable >/dev/null 2>&1   # keep the boot hook: the bot must start at boot
	/etc/init.d/vpnpool reload >/dev/null 2>&1
	log "power: off (daemon stopped, routing removed; Telegram bot kept)"
	;;
*)
	echo "usage: $0 on|off" >&2; exit 2 ;;
esac
exit 0
