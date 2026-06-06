#!/bin/sh
# vpnpool common library: load uci settings into shell vars + logging helper.
# Sourced by vpnpoold, fetch.sh, build.sh, route.sh.

NAME=vpnpool
CONF_DIR=/etc/vpnpool
SB_CONF="$CONF_DIR/sing-box.json"
SB_DATA=/tmp/vpnpool

log() { logger -t "$NAME" "$1"; }

SUB_URL=$(uci -q get vpnpool.main.subscription_url)
SUB_UA=$(uci -q get vpnpool.main.subscription_ua); [ -n "$SUB_UA" ] || SUB_UA="v2rayNG/1.8.5"
TPROXY_PORT=$(uci -q get vpnpool.main.tproxy_port); [ -n "$TPROXY_PORT" ] || TPROXY_PORT=1603
FWMARK=$(uci -q get vpnpool.main.fwmark); [ -n "$FWMARK" ] || FWMARK=0x400000
RT_TABLE=$(uci -q get vpnpool.main.route_table); [ -n "$RT_TABLE" ] || RT_TABLE=142
RT_PRIO=$(uci -q get vpnpool.main.route_priority); [ -n "$RT_PRIO" ] || RT_PRIO=106
# Clash API bound to loopback (the rpcd backend / scripts query it locally) — NOT
# exposed on the LAN. Portable: no hardcoded router IP.
CLASH_API=$(uci -q get vpnpool.main.clash_api); [ -n "$CLASH_API" ] || CLASH_API=127.0.0.1:9091
COEXIST=$(uci -q get vpnpool.main.coexist); [ -n "$COEXIST" ] || COEXIST=auto

# LAN interface: auto-detect (portable) unless pinned via uci. Falls back across
# ubus l3_device -> network.lan.device -> br-lan.
LAN_IF=$(uci -q get vpnpool.main.lan_if)
if [ -z "$LAN_IF" ]; then
	LAN_IF=$(ubus call network.interface.lan status 2>/dev/null | jq -r '.l3_device // empty' 2>/dev/null)
	[ -n "$LAN_IF" ] || LAN_IF=$(uci -q get network.lan.device 2>/dev/null)
	[ -n "$LAN_IF" ] || LAN_IF=br-lan
fi

# subscription_interval like "6h" / "30m" / "900s" -> seconds
interval_seconds() {
	local v
	v=$(uci -q get vpnpool.main.subscription_interval); [ -n "$v" ] || v=6h
	case "$v" in
		*h) echo $(( ${v%h} * 3600 )) ;;
		*m) echo $(( ${v%m} * 60 )) ;;
		*s) echo "${v%s}" ;;
		*)  echo "$v" ;;
	esac
}
