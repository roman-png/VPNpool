#!/bin/sh
# vpnpool common library: load uci settings into shell vars + logging helper.
# Sourced by vpnpoold, fetch.sh, build.sh, route.sh.

NAME=vpnpool
CONF_DIR=/etc/vpnpool
SB_CONF="$CONF_DIR/sing-box.json"
SB_DATA=/tmp/vpnpool

log() { logger -t "$NAME" "$1"; }

# Telegram API base + transport. In RU, api.telegram.org is blocked, so by default
# we tunnel Telegram traffic through OUR sing-box mixed inbound on 127.0.0.1:<test_port>
# (which egresses via the "proxy" outbound). Falls back to a DIRECT request if the
# proxy path fails (e.g. VPN down). Set telegram_via_proxy=0 to always go direct.
TG_API=https://api.telegram.org
TG_VIA_PROXY=$(uci -q get vpnpool.main.telegram_via_proxy); [ -n "$TG_VIA_PROXY" ] || TG_VIA_PROXY=1
TG_TEST_PORT=$(uci -q get vpnpool.main.test_port); [ -n "$TG_TEST_PORT" ] || TG_TEST_PORT=1605

# curl wrapper for Telegram: try via the tunnel proxy first (RU-block workaround),
# then fall back to a direct request. Extra args are passed to curl verbatim.
# Captures the proxy attempt and only emits it on success, so a failed proxy run
# (which still prints -w output) can't get concatenated with the direct fallback.
tg_curl() {
	local out rc
	if [ "$TG_VIA_PROXY" = "1" ]; then
		out=$(curl -s --proxy "socks5h://127.0.0.1:$TG_TEST_PORT" "$@"); rc=$?
		if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
	fi
	curl -s "$@"
}

# Low-level Telegram send (ignores the enable toggle). Needs token+chat.
# Echoes the HTTP status code (200 = delivered).
tg_send() {
	local tok chat code
	tok=$(uci -q get vpnpool.main.telegram_token)
	chat=$(uci -q get vpnpool.main.telegram_chat)
	[ -n "$tok" ] && [ -n "$chat" ] || { echo "000"; return 1; }
	code=$(tg_curl -m 12 -o /dev/null -w '%{http_code}' \
		--data-urlencode "chat_id=$chat" \
		--data-urlencode "text=$1" \
		"$TG_API/bot$tok/sendMessage" 2>/dev/null)
	echo "${code:-000}"
	[ "$code" = "200" ]
}

# Send a Telegram alert ONLY if notifications are enabled (used by the daemon).
tg_notify() {
	[ "$(uci -q get vpnpool.main.telegram_enabled)" = "1" ] || return 0
	tg_send "$1" >/dev/null 2>&1
	return 0
}

# ---- saved-node store ----
# Two persistent maps feed the single uci `saved_node` list:
#   saved.map.json    — manual ⭐ picks (rpcd save_node/unsave_node)
#   snapshot.map.json — auto-snapshot of currently-reachable nodes (snapshot.sh)
# Keeping them separate means auto-snapshot can be bounded/replaced wholesale
# without ever evicting a node the user saved by hand.
SAVED_MAP=/etc/vpnpool/saved.map.json
SNAP_MAP=/etc/vpnpool/snapshot.map.json

# Regenerate uci saved_node = unique union of both maps' link values, then commit.
rebuild_saved_list() {
	mkdir -p "$CONF_DIR"
	[ -f "$SAVED_MAP" ] || echo '{}' > "$SAVED_MAP"
	[ -f "$SNAP_MAP" ]  || echo '{}' > "$SNAP_MAP"
	uci -q delete vpnpool.main.saved_node
	jq -rn --slurpfile a "$SAVED_MAP" --slurpfile b "$SNAP_MAP" \
		'[ (($a[0]//{})|.[]), (($b[0]//{})|.[]) ] | unique | .[]' 2>/dev/null \
	| while IFS= read -r l; do [ -n "$l" ] && uci add_list vpnpool.main.saved_node="$l"; done
	uci commit vpnpool
}

# JSON array of all saved tags (manual + snapshot), for the dashboard ⭐ flag.
saved_tags_json() {
	[ -f "$SAVED_MAP" ] || echo '{}' > "$SAVED_MAP"
	[ -f "$SNAP_MAP" ]  || echo '{}' > "$SNAP_MAP"
	jq -n --slurpfile a "$SAVED_MAP" --slurpfile b "$SNAP_MAP" \
		'[ (($a[0]//{})|keys[]), (($b[0]//{})|keys[]) ] | unique' 2>/dev/null
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
# Kill-switch (fail-closed for IPv4): when on, in full-tunnel ("exclude") mode mark
# ALL LAN ports for tproxy so nothing can leak past the VPN if sing-box is down
# (marked traffic routes to the lo blackhole table when no listener answers).
# Default off — opt-in so existing selective setups are unchanged.
KILLSWITCH=$(uci -q get vpnpool.main.killswitch); [ -n "$KILLSWITCH" ] || KILLSWITCH=0
# DNS-leak guard: route LAN DNS aimed at PUBLIC resolvers (dport 53, non-local dst)
# through the tunnel instead of letting it egress directly. Default off (opt-in).
DNS_PROTECT=$(uci -q get vpnpool.main.dns_protect); [ -n "$DNS_PROTECT" ] || DNS_PROTECT=0
MODE=$(uci -q get vpnpool.main.mode); [ -n "$MODE" ] || MODE=selective
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
