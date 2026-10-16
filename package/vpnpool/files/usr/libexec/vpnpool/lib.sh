#!/bin/sh
# vpnpool common library: load uci settings into shell vars + logging helper.
# Sourced by vpnpoold, fetch.sh, build.sh, route.sh.

NAME=vpnpool
CONF_DIR=/etc/vpnpool
SB_DATA=/tmp/vpnpool
# The LIVE sing-box config is in RAM (/tmp): it is regenerated on every build, and rewriting
# it in flash on every rebuild wore the flash for nothing. A copy is kept in flash
# (SB_CONF_FLASH) and rewritten ONLY when the content changed (persist_if_changed).
SB_CONF="$SB_DATA/sing-box.json"
SB_CONF_FLASH="$CONF_DIR/sing-box.json"

log() { logger -t "$NAME" "$1"; }

# ---- the sing-box engine (ROADMAP 4.1): EVERY run of sing-box goes through sb_bin ----
# build.sh picks the binary for the pool (enginecap.uc select: uci singbox_bin, default the
# stock /usr/bin/sing-box; /usr/bin/sing-box-awg when there are AmneziaWG nodes and the stock one
# can't run them), checks the config WITH it and records it in SB_BIN_FILE — so the daemon runs
# exactly the binary the live config was validated against.
SB_BIN_DEFAULT=/usr/bin/sing-box
SB_BIN_FILE="$SB_DATA/.sb_bin"
ENGINECAP=/usr/libexec/vpnpool/enginecap.uc
sb_bin() {
	local b
	b=$(cat "$SB_BIN_FILE" 2>/dev/null)
	if [ -n "$b" ] && [ -x "$b" ]; then echo "$b"; return 0; fi
	# no record (after a reboot /tmp is empty, the flash copy is what runs; or a rollback to a
	# config of another build): choose by what the config holds — AmneziaWG endpoints need the
	# engine (enginecap.uc select 1), anything else the configured / stock binary
	if [ -s "$SB_CONF" ] && jq -e '[(.endpoints // [])[] | select(.type == "awg")] | length > 0' "$SB_CONF" >/dev/null 2>&1; then
		b=$(ucode "$ENGINECAP" select 1 2>/dev/null | jq -r '.bin // empty' 2>/dev/null)
		if [ -n "$b" ] && [ -x "$b" ]; then echo "$b"; return 0; fi
	fi
	b=$(uci -q get vpnpool.main.singbox_bin)
	if [ -n "$b" ] && [ -x "$b" ]; then echo "$b"; return 0; fi
	echo "$SB_BIN_DEFAULT"
}
# OUR sing-box processes (by our own -c config path — the RAM one, and the flash one a 1.x
# instance still runs with right after an upgrade), whichever binary runs them (sing-box,
# sing-box-awg): podkop's instance (-c /etc/sing-box/config.json) never matches.
our_singbox_pids() {
	{ pgrep -f "sing-box[^ ]* run -c $SB_CONF" 2>/dev/null; pgrep -f "sing-box[^ ]* run -c $SB_CONF_FLASH" 2>/dev/null; } | sort -u
}

# Atomic write: stdin -> "$1" via a temp file in the same directory + mv, so a reader
# (status.sh, the generator, rpcd) never sees a half-written file.
write_atomic() {   # $1=destination
	local t="$1.tmp.$$"
	cat > "$t" && mv -f "$t" "$1" || { rm -f "$t"; return 1; }
}

# Copy $1 over $2 ONLY when the content differs (flash wear: identical rewrites are skipped).
# Atomic (temp file + mv). Returns 0 when $2 is up to date afterwards.
persist_if_changed() {   # $1=source $2=destination
	[ -f "$1" ] || return 1
	cmp -s "$1" "$2" 2>/dev/null && return 0
	mkdir -p "$(dirname "$2")"
	cp "$1" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2" || { rm -f "$2.tmp.$$"; return 1; }
}

# Subscription URLs carry the access token in the path/query. Never log them in clear:
# keep scheme + host, drop userinfo, path and query.
mask_url() {   # $1=url -> e.g. https://sub.example.com/***
	printf '%s' "$1" | sed -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)\([^@/?#]*@\)\{0,1\}\([^/?#]*\).*#\1\3/***#'
}

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
# Exception: when the proxy port itself refuses the connection (curl rc 7 — our sing-box is
# not running, e.g. the service is switched off), poll DIRECT: that is the only way a /on can
# still arrive. A proxy that is up but slow/failing upstream keeps the proxy-only rule.
tg_poll() {
	local out rc
	if [ "$TG_VIA_PROXY" = "1" ]; then
		out=$(curl -s --proxy "socks5h://127.0.0.1:$TG_TEST_PORT" "$@"); rc=$?
		if [ "$rc" -ne 7 ]; then printf '%s' "$out"; return "$rc"; fi
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

# ---- the data model (ROADMAP 9): node ids everywhere, subscriptions as uci sections ----
# model.uc is the shell scripts' door to it (subscriptions, picks, hidden ids, favourites,
# id <-> tag of the last build); the stores are described in common.uc.
MODEL=/usr/libexec/vpnpool/model.uc
# the client names (User-Agents) fetch.sh tries by default (uci probe_ua replaces the list)
DEFAULT_UAS="v2rayNG/1.9.5 v2rayN/6.45 Happ/1.0 sing-box/1.12 clash-meta/1.18 Streisand Hiddify/2.0 Shadowrocket/2.2 Mozilla/5.0"
# the cache / output file key of a subscription URL (fetch.sh writes $SB_DATA/sources/s-<key>.raw)
src_key() { printf '%s' "$1" | md5sum | cut -c1-12; }
# node_resolve <id|tag> -> "<id>\t<tag>" of a node of the last build; rc 1 if there is none
node_resolve() { ucode "$MODEL" resolve "$1" 2>/dev/null; }

# ---- what a backup holds (ONE rule: rpcd backup/restore and the 1.x -> 2.0 migration copy) ----
# backup packs only files that match it, restore accepts only members that match it (our own
# backup can never be refused). Regular files only.
MEMBER_RE='^(etc/?|etc/config/?|etc/config/vpnpool|etc/vpnpool/?|etc/vpnpool/awg/?|etc/vpnpool/awg/[A-Za-z0-9._-]+\.conf|etc/vpnpool/[A-Za-z0-9._-]+\.map\.json)$'
BACKUP_MAPS='*.map.json'
backup_scan() {   # "ok <rel>" / "skip <rel>" for every candidate file of the live config
	local f rel
	echo "ok etc/config/vpnpool"
	for f in /etc/vpnpool/awg/* /etc/vpnpool/$BACKUP_MAPS; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		rel=${f#/}
		if [ -f "$f" ] && [ ! -L "$f" ] && printf '%s\n' "$rel" | grep -Eq "$MEMBER_RE"; then
			echo "ok $rel"
		else
			echo "skip $rel"
		fi
	done
}
backup_members() { backup_scan | sed -n 's/^ok //p'; }   # names never contain spaces (MEMBER_RE)

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

# ---- THE "is it alive" criterion (one definition for every check) ----
# A probe of a service counts as REACHABLE iff an HTTP response arrived at all: any status
# code (200/204/301/404/5xx) proves the request went through the node and back; "000"/empty
# = no connection (blocked / over-quota / dead exit). This is exactly what sing-box itself
# measures for the urltest group and for the clash delay API (both record a delay for ANY
# response), so the curl-based probes judge a node the same way the tunnel does.
# Users: generator.uc (urltest url = first service, same normalisation), nodecheck.sh
# (clash delay per node, ALL services), the daemon's watchdog / tunnel_healthy
# (probe_services ... any) and rpcd ping (clash delay, first service).
svc_code_alive() { case "$1" in [1-5][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
clash_delay_alive() { case "$1" in *'"delay"'*) return 0 ;; *) return 1 ;; esac; }

# The URL the urltest group (active pick + failover) probes: the FIRST configured service.
primary_probe_url() { check_probe_urls | head -n1; }

# probe_services <curl --proxy URL> <all|any> — probe every check_probe_urls entry through
# the proxy with the criterion above. all: every service must answer; any: one is enough.
probe_services() {
	local px="$1" mode="${2:-any}" u code n=0 okn=0
	for u in $(check_probe_urls); do
		n=$((n + 1))
		code=$(curl -s -o /dev/null -m6 --proxy "$px" -w '%{http_code}' "$u" 2>/dev/null)
		if svc_code_alive "$code"; then
			okn=$((okn + 1)); [ "$mode" = any ] && return 0
		else
			[ "$mode" = all ] && return 1
		fi
	done
	[ "$n" -gt 0 ] && [ "$okn" -eq "$n" ]
}

# Is the router's own uplink alive (DIRECT, not through the tunnel)? A dead node can only be
# told from a dead WAN by this: every node/tunnel verdict is void while WAN is down.
wan_alive() {
	local c u
	for u in http://cp.cloudflare.com/generate_204 http://connectivitycheck.gstatic.com/generate_204; do
		c=$(curl -s -o /dev/null -m6 -w '%{http_code}' "$u" 2>/dev/null)
		[ "$c" = 204 ] && return 0
	done
	return 1
}

# ---- tag safety net for the generated config ----
# parser.uc owns the names (RESERVED_TAGS + unique suffixes), so a repeat should never reach
# here. If one does anyway (a new generator outbound, a source bypassing the parser), sing-box
# check says "duplicate outbound/endpoint tag: X" WITHOUT an index and the pool would freeze on
# the previous config forever. config_tag_guard <config.json> rewrites the file in place:
#   - a NODE whose tag belongs to one of the generator's own outbounds -> dropped;
#   - a NODE repeating an earlier node's tag -> dropped (the first one stays);
#   - group member lists de-duplicated;
#   - two of the generator's OWN outbounds with one tag -> rc 1 (nothing a node drop can fix).
# Sets TAG_GUARD_DROPPED (count), logs the dropped names. The file is untouched when clean.
NODE_TYPES='["vless","vmess","trojan","shadowsocks","shadowtls","hysteria","hysteria2","tuic","wireguard","awg","socks","http","anytls"]'
TAG_GUARD_DROPPED=0
TAG_GUARD_JSON=""
config_tag_guard() {
	local out names
	TAG_GUARD_DROPPED=0; TAG_GUARD_JSON=""
	out=$(jq -c --argjson nt "$NODE_TYPES" '
		def isnode: ((.type) as $y | $nt | index($y)) != null;
		([.outbounds[]? | select(isnode | not) | .tag]) as $own
		| if ($own | length) != ($own | unique | length) then error("own outbounds repeat a tag") else . end
		| reduce (((.outbounds // [])[] | {a:"outbounds", v:.}),
		          ((.endpoints // [])[] | {a:"endpoints", v:.})) as $e
		    ({seen:{}, outbounds:[], endpoints:[], dropped:[]};
		     if ($e.v | isnode) and ((($own | index($e.v.tag)) != null) or .seen[$e.v.tag])
		     then .dropped += [$e.v.tag]
		     else .seen[$e.v.tag] = true | .[$e.a] += [$e.v] end) as $r
		| {dropped: $r.dropped,
		   cfg: (.outbounds = ($r.outbounds | map(
		           if (.type=="urltest" or .type=="selector") and (.outbounds|type=="array")
		           then .outbounds |= reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
		           else . end))
		        | if has("endpoints") then .endpoints = $r.endpoints else . end)}' "$1" 2>/dev/null) || return 1
	TAG_GUARD_DROPPED=$(printf '%s' "$out" | jq '.dropped | length')
	[ "${TAG_GUARD_DROPPED:-0}" -gt 0 ] || { TAG_GUARD_DROPPED=0; return 0; }
	TAG_GUARD_JSON=$(printf '%s' "$out" | jq -c '.dropped')   # for build_status.json
	names=$(printf '%s' "$out" | jq -r '.dropped | join(", ")')
	printf '%s' "$out" | jq '.cfg' > "$1.tg" && mv -f "$1.tg" "$1" || { rm -f "$1.tg"; return 1; }
	log "build: dropped node(s) with a repeated name before check: $names"
	return 0
}

# ---- per-node tests (speedtest.sh, unlock.sh) ----
# They point the dedicated 'vpnpool-test' selector (generator.uc) at the node under test
# and send their requests through the node-test-in inbound (uci node_test_port, 1606) —
# never through the LAN's 'proxy' selector. One test at a time (shared selector): a mkdir
# lock, freed at once if its owner died.
NODE_TEST_LOCK="$SB_DATA/.nodetest.lock"
node_test_lock() {   # waits up to ~60 s
	local i=0 p now mt
	mkdir -p "$SB_DATA"
	while ! mkdir "$NODE_TEST_LOCK" 2>/dev/null; do
		p=$(cat "$NODE_TEST_LOCK/pid" 2>/dev/null)
		if [ -n "$p" ]; then
			kill -0 "$p" 2>/dev/null || { rm -rf "$NODE_TEST_LOCK"; continue; }
		else
			now=$(date +%s); mt=$(date -r "$NODE_TEST_LOCK" +%s 2>/dev/null || echo "$now")
			[ $(( now - mt )) -ge 120 ] && { rm -rf "$NODE_TEST_LOCK"; continue; }
		fi
		i=$((i + 1)); [ "$i" -ge 60 ] && return 1
		sleep 1
	done
	echo $$ > "$NODE_TEST_LOCK/pid"
}
node_test_unlock() { rm -rf "$NODE_TEST_LOCK"; }
node_test_select() {   # $1=tag -> 0 only if sing-box switched the test selector (HTTP 204)
	local c
	c=$(curl -s -m5 -o /dev/null -w '%{http_code}' -X PUT "http://$CLASH_API/proxies/vpnpool-test" \
		--data "$(jq -nc --arg n "$1" '{name:$n}')" 2>/dev/null)
	[ "$c" = 204 ]
}

# ---- routing fail-safe / kill-switch policy (pure: decides, never acts) ----
# route_policy <killswitch 0|1> <tunnel healthy 0|1> <paused by the user 0|1> -> up|down
#   paused (Telegram /off)  -> down: the user explicitly switched routing off. The kill-switch
#                              protects against FAILURES, not against the user's own explicit
#                              "turn the VPN off" — the same holds for LuCI "off" and the
#                              schedule's "off" (enabled=0, the daemon stops and removes the
#                              routes). INTEGRATOR'S ASSUMPTION (14.10.2026), not an owner's
#                              decision — to be confirmed by the owner.
#   killswitch=1            -> up on every failure (fail-closed: a dead tunnel / failed build /
#                              restart blocks the LAN, never leaks)
#   killswitch=0            -> up only while the tunnel works; a dead tunnel -> down, so the
#                              LAN falls back to DIRECT instead of a black hole (fail-safe)
route_policy() {
	[ "$3" = 1 ] && { echo down; return 0; }
	[ "$1" = 1 ] && { echo up; return 0; }
	if [ "$2" = 1 ]; then echo up; else echo down; fi
}
# Telegram /off sets this flag (RAM: a reboot resumes routing); the daemon applies it.
PAUSE_FLAG="$SB_DATA/.routing_paused"

# ---- subscription refresh interval ----
INTERVAL_MIN=600   # never re-download a subscription more often than every 10 min
# parse_interval "6h" / "30m" / "900s" / "900" -> seconds on stdout; rc 1 if malformed
parse_interval() {
	local n u
	case "$1" in ''|*[!0-9hms]*) return 1 ;; esac
	case "$1" in
		*h) n=${1%h}; u=3600 ;;
		*m) n=${1%m}; u=60 ;;
		*s) n=${1%s}; u=1 ;;
		*)  n=$1; u=1 ;;
	esac
	case "$n" in ''|*[!0-9]*) return 1 ;; esac
	n=$(printf '%s' "$n" | sed 's/^0*//'); [ -n "$n" ] || n=0   # "08" is not octal here
	echo $(( n * u ))
}
# Signature of the configured subscription set (the enabled URLs): a change (a subscription
# added, edited or switched on) makes a fetch due at once regardless of the time throttle.
sources_sig() {
	ucode "$MODEL" subs 2>/dev/null | awk -F'\t' '$2 == 1 {print $4}' | md5sum | cut -c1-12
}
FETCH_STAMP="$SB_DATA/.last_fetch"   # "<epoch> <sources_sig>", written by fetch.sh
# fetch_due -> 0 when the subscriptions should be downloaded now: never fetched since boot,
# the subscription set changed, no fetched files, or the last attempt is >= INTERVAL_MIN old.
fetch_due() {
	local t s now
	[ -f "$FETCH_STAMP" ] || return 0
	read -r t s < "$FETCH_STAMP" 2>/dev/null
	case "$t" in ''|*[!0-9]*) return 0 ;; esac
	[ "$s" = "$(sources_sig)" ] || return 0
	ls "$SB_DATA/sources/"*.raw >/dev/null 2>&1 || return 0
	now=$(date +%s)
	[ $(( now - t )) -ge "$INTERVAL_MIN" ]
}
# subscription_interval -> seconds; malformed -> 6h, below INTERVAL_MIN -> INTERVAL_MIN
interval_seconds() {
	local v s
	v=$(uci -q get vpnpool.main.subscription_interval); [ -n "$v" ] || v=6h
	s=$(parse_interval "$v") || s=21600
	[ "$s" -ge "$INTERVAL_MIN" ] || s=$INTERVAL_MIN
	echo "$s"
}
