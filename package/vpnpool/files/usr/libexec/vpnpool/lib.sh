#!/bin/sh
# vpnpool common library: load uci settings into shell vars + logging helper.
# Sourced by vpnpoold, fetch.sh, build.sh, route.sh.

NAME=vpnpool
CONF_DIR=/etc/vpnpool
SB_CONF="$CONF_DIR/sing-box.json"
SB_DATA=/tmp/vpnpool

log() { logger -t "$NAME" "$1"; }

# Send a Telegram message if configured (no-op otherwise). Used for failover /
# subscription / lifecycle alerts.
tg_notify() {
	[ "$(uci -q get vpnpool.main.telegram_enabled)" = "1" ] || return 0
	local tok chat
	tok=$(uci -q get vpnpool.main.telegram_token)
	chat=$(uci -q get vpnpool.main.telegram_chat)
	[ -n "$tok" ] && [ -n "$chat" ] || return 0
	curl -s -m 8 -o /dev/null \
		--data-urlencode "chat_id=$chat" \
		--data-urlencode "text=$1" \
		"https://api.telegram.org/bot$tok/sendMessage" 2>/dev/null
	return 0
}

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
# IPv6 policy: block (fail-closed: drop LAN v6 to internet so it can't bypass the
# v4 VPN), off (don't touch v6), proxy (reserved for future v6 tproxy).
IPV6=$(uci -q get vpnpool.main.ipv6); [ -n "$IPV6" ] || IPV6=block
# Per-client routing: all (every LAN client) | exclude (listed bypass VPN) |
# include (only listed go through VPN). Clients are IPv4 addresses (uci list 'client').
CLIENT_MODE=$(uci -q get vpnpool.main.client_mode); [ -n "$CLIENT_MODE" ] || CLIENT_MODE=all

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
