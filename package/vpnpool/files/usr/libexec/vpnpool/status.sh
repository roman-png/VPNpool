#!/bin/sh
# vpnpool: emit a JSON status snapshot for the LuCI dashboard / rpcd.
# Combines uci state + service/routing state + live node delays from Clash API.
. /usr/libexec/vpnpool/lib.sh
. /lib/functions.sh 2>/dev/null

# Read a uci LIST option into a JSON array, preserving values that contain spaces
# or emoji (node tags often do!). `uci get` space-joins list items, so the old
# `uci get | tr ' ' '\n'` split multi-word tags into garbage — config_list_foreach
# hands us each item whole.
__ULJ=""
__ulj_add() { __ULJ="${__ULJ}${1}
"; }
uci_list_json() {   # $1=section $2=option -> JSON array on stdout
	__ULJ=""
	config_load vpnpool 2>/dev/null
	config_list_foreach "$1" "$2" __ulj_add 2>/dev/null
	printf '%s' "$__ULJ" | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null
}

ENABLED=$(uci -q get vpnpool.main.enabled); [ -n "$ENABLED" ] || ENABLED=0
RUNNING=false; pgrep -f '/usr/libexec/vpnpool/vpnpoold' >/dev/null 2>&1 && RUNNING=true
ROUTING=false; nft list table inet vpnpool >/dev/null 2>&1 && ROUTING=true
CLASH=$(uci -q get vpnpool.main.clash_api); [ -n "$CLASH" ] || CLASH=127.0.0.1:9091
MODE=$(uci -q get vpnpool.main.mode); [ -n "$MODE" ] || MODE=selective

ACTIVE=""
AUTONOW=""
PROX='{}'
TUP=0; TDOWN=0; TCONN=0
if [ "$RUNNING" = true ]; then
	PROX=$(curl -s -m3 "http://$CLASH/proxies" 2>/dev/null)
	[ -n "$PROX" ] || PROX='{}'
	ACTIVE=$(echo "$PROX" | jq -r '.proxies.proxy.now // ""' 2>/dev/null)
	AUTONOW=$(echo "$PROX" | jq -r '.proxies.auto.now // ""' 2>/dev/null)
	CONN=$(curl -s -m3 "http://$CLASH/connections" 2>/dev/null)
	TUP=$(echo "$CONN" | jq -r '(.uploadTotal // 0)' 2>/dev/null); [ -n "$TUP" ] || TUP=0
	TDOWN=$(echo "$CONN" | jq -r '(.downloadTotal // 0)' 2>/dev/null); [ -n "$TDOWN" ] || TDOWN=0
	TCONN=$(echo "$CONN" | jq -r '((.connections // []) | length)' 2>/dev/null); [ -n "$TCONN" ] || TCONN=0
fi

NODES_FILE=/tmp/vpnpool/nodes.json
[ -f "$NODES_FILE" ] || NODES_FILE=/dev/null

# Pass large JSON to jq via FILES, never via --argjson on argv: a big subscription
# (hundreds/thousands of nodes) makes $PROX and $NODES exceed ARG_MAX and jq dies
# with "Argument list too long", which empties the dashboard. printf is a shell
# builtin so writing the files is not subject to the arg limit.
PROXF="$SB_DATA/.prox.json"; printf '%s' "$PROX" > "$PROXF" 2>/dev/null
NODESF="$SB_DATA/.nodesout.json"

# Tag origin for dashboard grouping: parse the (small, user-curated) imported/manual
# link files to learn their tags; everything else came from the subscription.
IMPTAGS=$(ucode /usr/libexec/vpnpool/parser.uc "$SB_DATA/imported.links" 2>/dev/null | jq -c '[.[].tag]' 2>/dev/null); [ -n "$IMPTAGS" ] || IMPTAGS='[]'
MANTAGS=$(ucode /usr/libexec/vpnpool/parser.uc "$SB_DATA/manual.links" 2>/dev/null | jq -c '[.[].tag]' 2>/dev/null); [ -n "$MANTAGS" ] || MANTAGS='[]'

jq -n \
	--slurpfile p "$PROXF" \
	--slurpfile n <(cat "$NODES_FILE" 2>/dev/null || echo '[]') \
	--argjson imp "$IMPTAGS" \
	--argjson man "$MANTAGS" \
	'(($p[0] // {}) | .proxies // {}) as $px | ($n[0] // []) | map({
		tag: .tag,
		server: .server,
		port: .server_port,
		delay: (($px[.tag].history // []) | last | .delay // null),
		group: (.tag as $t | if ($imp | index($t)) then "imported" elif ($man | index($t)) then "manual" else "subscription" end)
	})' > "$NODESF" 2>/dev/null
[ -s "$NODESF" ] || echo '[]' > "$NODESF"

EXPIRE=$(cat "$CONF_DIR/sub.expire" 2>/dev/null)
case "$EXPIRE" in (*[!0-9]*|"") EXPIRE=null ;; esac
URL=$(uci -q get vpnpool.main.subscription_url)
DOMAINS=$(uci -q get vpnpool.routing.domain | tr ' ' '\n' | jq -R . | jq -s . 2>/dev/null)
[ -n "$DOMAINS" ] || DOMAINS='[]'
MANUAL=$(uci -q get vpnpool.main.manual_node | tr ' ' '\n' | jq -R . | jq -s . 2>/dev/null)
[ -n "$MANUAL" ] || MANUAL='[]'
SOURCES=$(uci -q get vpnpool.main.source | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$SOURCES" ] || SOURCES='[]'
COMMUNITIES=$(uci -q get vpnpool.routing.community | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$COMMUNITIES" ] || COMMUNITIES='[]'
FI=$(uci -q get vpnpool.main.failover_interval); [ -n "$FI" ] || FI=60
SI=$(uci -q get vpnpool.main.subscription_interval); [ -n "$SI" ] || SI=6h
TOL=$(uci -q get vpnpool.main.failover_tolerance); [ -n "$TOL" ] || TOL=50
ASW=$(uci -q get vpnpool.main.auto_switch); [ -n "$ASW" ] || ASW=1
TGE=$(uci -q get vpnpool.main.telegram_enabled); [ -n "$TGE" ] || TGE=0
TGT=$(uci -q get vpnpool.main.telegram_token)
TGC=$(uci -q get vpnpool.main.telegram_chat)
CLM=$(uci -q get vpnpool.main.client_mode); [ -n "$CLM" ] || CLM=all
CLIENTS=$(uci -q get vpnpool.main.client | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$CLIENTS" ] || CLIENTS='[]'
AUTOMEM=$(uci_list_json main auto_member)
[ -n "$AUTOMEM" ] || AUTOMEM='[]'

jq -n \
	--argjson enabled "${ENABLED:-0}" \
	--argjson running "$RUNNING" \
	--argjson routing "$ROUTING" \
	--arg active "$ACTIVE" \
	--arg auto_now "$AUTONOW" \
	--arg mode "$MODE" \
	--arg url "$URL" \
	--argjson expire "$EXPIRE" \
	--slurpfile nodes "$NODESF" \
	--argjson domains "$DOMAINS" \
	--argjson manual "$MANUAL" \
	--argjson sources "$SOURCES" \
	--argjson communities "$COMMUNITIES" \
	--arg fi "$FI" \
	--arg si "$SI" \
	--arg tol "$TOL" \
	--argjson asw "${ASW:-1}" \
	--argjson tge "${TGE:-0}" \
	--arg tgt "$TGT" \
	--arg tgc "$TGC" \
	--arg ipv6 "$IPV6" \
	--arg clm "$CLM" \
	--argjson clients "$CLIENTS" \
	--argjson automem "$AUTOMEM" \
	--argjson tup "${TUP:-0}" \
	--argjson tdown "${TDOWN:-0}" \
	--argjson tconn "${TCONN:-0}" \
	'{
		enabled: ($enabled==1),
		running: $running,
		routing: $routing,
		mode: $mode,
		active: $active,
		auto_now: $auto_now,
		subscription: { url: $url, expire: $expire },
		nodes: ($nodes[0] // []),
		auto_members: $automem,
		traffic: { up_total: $tup, down_total: $tdown, connections: $tconn },
		domains: $domains,
		manual_nodes: $manual,
		sources: $sources,
		communities: $communities,
		settings: {
			failover_interval: ($fi|tonumber? // 60),
			subscription_interval: $si,
			failover_tolerance: ($tol|tonumber? // 50),
			auto_switch: ($asw==1),
			ipv6: $ipv6,
			telegram_enabled: ($tge==1),
			telegram_token: $tgt,
			telegram_chat: $tgc,
			client_mode: $clm
		},
		clients: $clients
	}'
