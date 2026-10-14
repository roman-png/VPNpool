#!/bin/sh
# vpnpool common library: load uci settings into shell vars + logging helper.
# Sourced by vpnpoold, fetch.sh, build.sh, route.sh.

NAME=vpnpool
CONF_DIR=/etc/vpnpool
SB_CONF="$CONF_DIR/sing-box.json"
SB_DATA=/tmp/vpnpool

log() { logger -t "$NAME" "$1"; }

# Remove a single-flight lock file if it is older than MAXAGE seconds. Call BEFORE honoring
# a lock so a run killed by SIGKILL (e.g. OOM on a 16 MB router) — whose EXIT trap never
# fired — can't block every future run forever. No-op if the lock is fresh or absent.
clear_stale_lock() {   # $1=lockfile  $2=maxage_seconds (default 600)
	[ -f "$1" ] || return 0
	local now lk pid
	# PID-aware (preferred): if the lock records its owner's PID, trust liveness over age —
	# a live owner keeps the lock no matter how long it runs (a slow fetch/build on a weak
	# router must NOT lose its lock mid-run), and a dead owner releases it IMMEDIATELY
	# (don't wait out maxage). Falls back to the age check only when the lock has no PID.
	pid=$(cat "$1" 2>/dev/null)
	case "$pid" in
		''|*[!0-9]*) ;;   # no / non-numeric PID -> age-based check below
		*) if kill -0 "$pid" 2>/dev/null; then return 0; else rm -f "$1"; return 0; fi ;;
	esac
	now=$(date +%s); lk=$(date -r "$1" +%s 2>/dev/null || echo 0)
	[ $(( now - lk )) -ge "${2:-600}" ] && rm -f "$1"
	return 0
}

# Send a signal to the vpnpool daemon, but ONLY if the PID in the pidfile is really our
# daemon — a stale pidfile (daemon crashed/restarted) could otherwise point at an unrelated
# process and we'd signal the wrong one.
signal_daemon() {   # $1=signal name, e.g. USR1
	local p
	p=$(cat /var/run/vpnpool.pid 2>/dev/null); [ -n "$p" ] || return 1
	pgrep -f /usr/libexec/vpnpool/vpnpoold 2>/dev/null | grep -qx "$p" || return 1
	kill -"$1" "$p" 2>/dev/null
}

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
	local out rc i
	if [ "$TG_VIA_PROXY" = "1" ]; then
		# The socks proxy path through the node is intermittently flaky (observed: ~1/3 of
		# requests fail TLS with curl rc=35) — so RETRY the proxy a few times before giving
		# up. A failed TLS connect returns fast and sends nothing, so a retry can't double-
		# send; this turns ~66% per-try success into ~96%+ and stops button replies from
		# being lost or punted to the (RU-blocked, slow) direct fallback.
		i=0
		while [ "$i" -lt 3 ]; do
			out=$(curl -s --proxy "socks5h://127.0.0.1:$TG_TEST_PORT" "$@"); rc=$?
			if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
			i=$((i + 1))
		done
	fi
	curl -s "$@"
}

# getUpdates long-poll transport. UNLIKE tg_curl, a failed PROXY attempt does NOT fall
# back to a DIRECT request: api.telegram.org is blocked in RU, so a direct long-poll would
# block for the FULL -m timeout (~60s) on every proxy hiccup — delaying every queued button
# press / command until it expires (the bot "answers after a long time"). Proxy-only keeps
# polling responsive: a transient proxy failure returns empty fast and the caller retries
# the proxy after a short sleep. Honors telegram_via_proxy=0 (then it polls direct).
tg_poll() {
	if [ "$TG_VIA_PROXY" = "1" ]; then
		curl -s --proxy "socks5h://127.0.0.1:$TG_TEST_PORT" "$@"
	else
		curl -s "$@"
	fi
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

# Send a message WITH an inline keyboard. $1=text, $2=reply_markup JSON (compact).
# Echoes the HTTP status code (200 = delivered).
tg_send_kb() {
	local tok chat code
	tok=$(uci -q get vpnpool.main.telegram_token)
	chat=$(uci -q get vpnpool.main.telegram_chat)
	[ -n "$tok" ] && [ -n "$chat" ] || { echo "000"; return 1; }
	code=$(tg_curl -m 12 -o /dev/null -w '%{http_code}' \
		--data-urlencode "chat_id=$chat" \
		--data-urlencode "text=$1" \
		--data-urlencode "reply_markup=$2" \
		"$TG_API/bot$tok/sendMessage" 2>/dev/null)
	echo "${code:-000}"
	[ "$code" = "200" ]
}

# Edit an existing bot message's text + keyboard in place (clean nav, no chat spam).
# $1=message_id $2=text $3=reply_markup JSON. "message is not modified" is harmless.
tg_edit_kb() {
	local tok chat
	tok=$(uci -q get vpnpool.main.telegram_token)
	chat=$(uci -q get vpnpool.main.telegram_chat)
	[ -n "$tok" ] && [ -n "$chat" ] || return 1
	tg_curl -m 12 -o /dev/null \
		--data-urlencode "chat_id=$chat" \
		--data-urlencode "message_id=$1" \
		--data-urlencode "text=$2" \
		--data-urlencode "reply_markup=$3" \
		"$TG_API/bot$tok/editMessageText" >/dev/null 2>&1
}

# Acknowledge a callback query (stops the button's spinner). MUST be called once per
# callback. $1=callback_query_id $2=optional toast text (<=200 chars).
tg_answer_cbq() {
	local tok
	tok=$(uci -q get vpnpool.main.telegram_token); [ -n "$tok" ] || return 1
	tg_curl -m 8 -o /dev/null \
		--data-urlencode "callback_query_id=$1" \
		--data-urlencode "text=${2:-}" \
		"$TG_API/bot$tok/answerCallbackQuery" >/dev/null 2>&1
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

# Resolve a saved tag -> its archived vless:// link (manual map first, then snapshot).
# Used to (de)activate a saved node even when it's no longer in the live subscription.
saved_link_for_tag() {   # $1=tag
	[ -f "$SAVED_MAP" ] || echo '{}' > "$SAVED_MAP"
	[ -f "$SNAP_MAP" ]  || echo '{}' > "$SNAP_MAP"
	jq -rn --slurpfile a "$SAVED_MAP" --slurpfile b "$SNAP_MAP" --arg t "$1" \
		'(($a[0]//{})[$t]) // (($b[0]//{})[$t]) // ""' 2>/dev/null
}

# JSON array [{tag,link}] of the whole saved archive (manual UNION snapshot), the
# source for the dashboard's inactive "saved" list.
saved_archive_json() {
	[ -f "$SAVED_MAP" ] || echo '{}' > "$SAVED_MAP"
	[ -f "$SNAP_MAP" ]  || echo '{}' > "$SNAP_MAP"
	jq -n --slurpfile a "$SAVED_MAP" --slurpfile b "$SNAP_MAP" \
		'[ (($a[0]//{})|to_entries[]), (($b[0]//{})|to_entries[]) ] | unique_by(.key) | map({tag:.key, link:.value})' 2>/dev/null
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
# v4 VPN) or off (don't touch v6). (A 'proxy' mode for real v6 tproxy transit was
# never implemented — it silently behaved exactly like 'off' — so it's removed; any
# leftover ipv6=proxy now validates to the safe 'block' below.)
# Validate, don't just default: an unknown/typo value (e.g. ipv6=blok) must not silently
# disable the leak guard — fall back to the safe 'block'.
IPV6=$(uci -q get vpnpool.main.ipv6); case "$IPV6" in block|off) ;; *) IPV6=block ;; esac
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

# ---- service-accuracy probe set ----
# THE single source of truth for "is a node good": the user-configured services the VPN
# must actually make work THROUGH a node (often the blocked ones). Emits one normalised
# probe URL per line — a bare host becomes http://<host>/generate_204 (tiny response, just
# measures whether the host is reachable through the node), a full URL is used verbatim.
# Every node-quality check reads this: the nodecheck.sh dead-filter, the generator's
# urltest "url" (active-node pick + failover) and the daemon's self-heal watchdog. Falls
# back to health_url then YouTube so the list is never empty (existing routers without the
# new option keep their old health_url behaviour until the user sets services in the UI).
check_probe_urls() {
	local svc s
	svc=$(uci -q get vpnpool.main.check_services)
	if [ -z "$svc" ]; then
		svc=$(uci -q get vpnpool.main.health_url)
		[ -n "$svc" ] || svc="www.youtube.com"
	fi
	for s in $svc; do
		[ -n "$s" ] || continue
		case "$s" in
			*://*) printf '%s\n' "$s" ;;
			*)     printf 'http://%s/generate_204\n' "$s" ;;
		esac
	done
}

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
