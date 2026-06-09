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
	# write the (possibly large) connections payload to a file and aggregate with
	# jq from the file — never via echo (a busy router can have thousands of conns
	# and blow ARG_MAX, which would empty the dashboard).
	CONNF="$SB_DATA/.conn.json"
	curl -s -m3 "http://$CLASH/connections" 2>/dev/null > "$CONNF"
	[ -s "$CONNF" ] || echo '{}' > "$CONNF"
	TUP=$(jq -r '(.uploadTotal // 0)' "$CONNF" 2>/dev/null); [ -n "$TUP" ] || TUP=0
	TDOWN=$(jq -r '(.downloadTotal // 0)' "$CONNF" 2>/dev/null); [ -n "$TDOWN" ] || TDOWN=0
	TCONN=$(jq -r '((.connections // []) | length)' "$CONNF" 2>/dev/null); [ -n "$TCONN" ] || TCONN=0
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
# saved node tags (persistent favourites that survive subscription expiry)
SAVEDTAGS=$(saved_tags_json 2>/dev/null | jq -c . 2>/dev/null); [ -n "$SAVEDTAGS" ] || SAVEDTAGS='[]'

# Per-node + per-client LIVE traffic, aggregated from clash connections (bytes,
# cumulative per connection). Read-only; written to small files for the final jq.
NTF="$SB_DATA/.nodetraf.json"; echo '{}' > "$NTF"
CTF="$SB_DATA/.clienttraf.json"; echo '[]' > "$CTF"
if [ "$RUNNING" = true ] && [ -s "${CONNF:-/dev/null}" ]; then
	# per-node: pick the chain element that matches a known node tag
	jq -c --slurpfile nn <(cat "$NODES_FILE" 2>/dev/null || echo '[]') '
		($nn[0] // [] | map(.tag)) as $tags
		| (.connections // [])
		| map({ tag: ((.chains // []) | map(select(. as $c | $tags | index($c))) | .[0]),
		        up: (.upload // 0), down: (.download // 0) })
		| map(select(.tag != null))
		| group_by(.tag)
		| map({ key: .[0].tag, value: { up: (map(.up)|add), down: (map(.down)|add) } })
		| from_entries
	' "$CONNF" > "$NTF" 2>/dev/null || echo '{}' > "$NTF"
	# per-client: aggregate by source IP, attach DHCP hostname, top 30 by volume
	LEASEF="$SB_DATA/.leases.json"
	awk '{print $3" "$4}' /tmp/dhcp.leases 2>/dev/null \
		| jq -R -s 'split("\n")|map(select(length>0)|split(" ")|{(.[0]):(.[1] // "")})|add // {}' > "$LEASEF" 2>/dev/null
	[ -s "$LEASEF" ] || echo '{}' > "$LEASEF"
	jq -c --slurpfile lz "$LEASEF" '
		($lz[0] // {}) as $L
		| (.connections // [])
		| map({ ip: (.metadata.sourceIP // "?"), up: (.upload // 0), down: (.download // 0) })
		| group_by(.ip)
		| map({ ip: .[0].ip, host: ($L[.[0].ip] // ""), up: (map(.up)|add), down: (map(.down)|add), conns: length })
		| sort_by(.up + .down) | reverse | .[:30]
	' "$CONNF" > "$CTF" 2>/dev/null || echo '[]' > "$CTF"
fi

UNLOCKF=/etc/vpnpool/unlock.map.json; [ -f "$UNLOCKF" ] || echo '{}' > "$UNLOCKF"
jq -n \
	--slurpfile p "$PROXF" \
	--slurpfile n <(cat "$NODES_FILE" 2>/dev/null || echo '[]') \
	--slurpfile nt "$NTF" \
	--slurpfile ul "$UNLOCKF" \
	--argjson imp "$IMPTAGS" \
	--argjson man "$MANTAGS" \
	--argjson savd "$SAVEDTAGS" \
	'(($p[0] // {}) | .proxies // {}) as $px | ($nt[0] // {}) as $tr | ($ul[0] // {}) as $un | ($n[0] // []) | map({
		tag: .tag,
		server: .server,
		port: .server_port,
		delay: (($px[.tag].history // []) | last | .delay // null),
		up: ($tr[.tag].up // 0),
		down: ($tr[.tag].down // 0),
		saved: (.tag as $t | ($savd | index($t)) != null),
		unlock: ($un[.tag] // null),
		group: (.tag as $t | if ($imp | index($t)) then "imported" elif ($man | index($t)) then "manual" else "subscription" end)
	})' > "$NODESF" 2>/dev/null
[ -s "$NODESF" ] || echo '[]' > "$NODESF"

EXPIRE=$(cat "$CONF_DIR/sub.expire" 2>/dev/null)
case "$EXPIRE" in (*[!0-9]*|"") EXPIRE=null ;; esac
# subscription quota (bytes): "upload download total" from subscription-userinfo
USAGE=$(cat "$CONF_DIR/sub.usage" 2>/dev/null)
SUP=$(echo "$USAGE" | awk '{print $1+0}'); [ -n "$SUP" ] || SUP=0
SDN=$(echo "$USAGE" | awk '{print $2+0}'); [ -n "$SDN" ] || SDN=0
STOT=$(echo "$USAGE" | awk '{print $3+0}'); [ -n "$STOT" ] || STOT=0
URL=$(uci -q get vpnpool.main.subscription_url)
DOMAINS=$(uci -q get vpnpool.routing.domain | tr ' ' '\n' | jq -R . | jq -s . 2>/dev/null)
[ -n "$DOMAINS" ] || DOMAINS='[]'
MANUAL=$(uci -q get vpnpool.main.manual_node | tr ' ' '\n' | jq -R . | jq -s . 2>/dev/null)
[ -n "$MANUAL" ] || MANUAL='[]'
SOURCES=$(uci -q get vpnpool.main.source | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$SOURCES" ] || SOURCES='[]'
EXTRASUBS=$(uci -q get vpnpool.main.extra_sub | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$EXTRASUBS" ] || EXTRASUBS='[]'
AUTODOM=$(uci -q get vpnpool.routing.auto_domain | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$AUTODOM" ] || AUTODOM='[]'
COMMUNITIES=$(uci -q get vpnpool.routing.community | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$COMMUNITIES" ] || COMMUNITIES='[]'
FI=$(uci -q get vpnpool.main.failover_interval); [ -n "$FI" ] || FI=60
SI=$(uci -q get vpnpool.main.subscription_interval); [ -n "$SI" ] || SI=6h
TOL=$(uci -q get vpnpool.main.failover_tolerance); [ -n "$TOL" ] || TOL=50
ASW=$(uci -q get vpnpool.main.auto_switch); [ -n "$ASW" ] || ASW=1
TGE=$(uci -q get vpnpool.main.telegram_enabled); [ -n "$TGE" ] || TGE=0
TGT=$(uci -q get vpnpool.main.telegram_token)
TGC=$(uci -q get vpnpool.main.telegram_chat)
TGCTL=$(uci -q get vpnpool.main.telegram_control); [ -n "$TGCTL" ] || TGCTL=0
TGVP=$(uci -q get vpnpool.main.telegram_via_proxy); [ -n "$TGVP" ] || TGVP=1
KSW=$(uci -q get vpnpool.main.killswitch); [ -n "$KSW" ] || KSW=0
DNSP=$(uci -q get vpnpool.main.dns_protect); [ -n "$DNSP" ] || DNSP=0
PREF=$(uci -q get vpnpool.main.preferred_node)
IPV6=$(uci -q get vpnpool.main.ipv6); [ -n "$IPV6" ] || IPV6=block
CLM=$(uci -q get vpnpool.main.client_mode); [ -n "$CLM" ] || CLM=all
CLIENTS=$(uci -q get vpnpool.main.client | tr ' ' '\n' | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null)
[ -n "$CLIENTS" ] || CLIENTS='[]'
ANTIDPI=$(uci -q get vpnpool.main.antidpi); [ -n "$ANTIDPI" ] || ANTIDPI=0
ADAPT=$(uci -q get vpnpool.main.adaptive_routing); [ -n "$ADAPT" ] || ADAPT=0
ASNAP=$(uci -q get vpnpool.main.auto_snapshot); [ -n "$ASNAP" ] || ASNAP=0
ASNAPMAX=$(uci -q get vpnpool.main.auto_snapshot_max); case "$ASNAPMAX" in (*[!0-9]*|"") ASNAPMAX=20 ;; esac
SCHED_EN=$(uci -q get vpnpool.main.sched_enabled); [ -n "$SCHED_EN" ] || SCHED_EN=0
SCHED_ON=$(uci -q get vpnpool.main.sched_on)
SCHED_OFF=$(uci -q get vpnpool.main.sched_off)
SCHED_REF=$(uci -q get vpnpool.main.sched_refresh)
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
	--argjson extrasubs "$EXTRASUBS" \
	--argjson autodom "$AUTODOM" \
	--argjson antidpi "${ANTIDPI:-0}" \
	--argjson adapt "${ADAPT:-0}" \
	--argjson communities "$COMMUNITIES" \
	--arg fi "$FI" \
	--arg si "$SI" \
	--arg tol "$TOL" \
	--argjson asw "${ASW:-1}" \
	--argjson tge "${TGE:-0}" \
	--arg tgt "$TGT" \
	--arg tgc "$TGC" \
	--argjson tgctl "${TGCTL:-0}" \
	--argjson tgvp "${TGVP:-1}" \
	--argjson ksw "${KSW:-0}" \
	--argjson dnsp "${DNSP:-0}" \
	--arg pref "$PREF" \
	--argjson sup "${SUP:-0}" \
	--argjson sdn "${SDN:-0}" \
	--argjson stot "${STOT:-0}" \
	--arg ipv6 "$IPV6" \
	--arg clm "$CLM" \
	--argjson clients "$CLIENTS" \
	--argjson automem "$AUTOMEM" \
	--argjson tup "${TUP:-0}" \
	--argjson tdown "${TDOWN:-0}" \
	--argjson tconn "${TCONN:-0}" \
	--slurpfile ct "$CTF" \
	--argjson asnap "${ASNAP:-0}" \
	--argjson asnapmax "${ASNAPMAX:-20}" \
	--argjson schen "${SCHED_EN:-0}" \
	--arg schon "$SCHED_ON" \
	--arg schoff "$SCHED_OFF" \
	--arg schref "$SCHED_REF" \
	'{
		enabled: ($enabled==1),
		running: $running,
		routing: $routing,
		mode: $mode,
		active: $active,
		auto_now: $auto_now,
		subscription: { url: $url, expire: $expire, used: ($sup+$sdn), total: $stot },
		nodes: ($nodes[0] // []),
		auto_members: $automem,
		traffic: { up_total: $tup, down_total: $tdown, connections: $tconn },
		client_traffic: ($ct[0] // []),
		domains: $domains,
		manual_nodes: $manual,
		sources: $sources,
		extra_subs: $extrasubs,
		auto_domains: $autodom,
		communities: $communities,
		settings: {
			failover_interval: ($fi|tonumber? // 60),
			subscription_interval: $si,
			failover_tolerance: ($tol|tonumber? // 50),
			auto_switch: ($asw==1),
			ipv6: $ipv6,
			killswitch: ($ksw==1),
			dns_protect: ($dnsp==1),
			preferred_node: $pref,
			telegram_enabled: ($tge==1),
			telegram_token: $tgt,
			telegram_chat: $tgc,
			telegram_control: ($tgctl==1),
			telegram_via_proxy: ($tgvp==1),
			client_mode: $clm,
			auto_snapshot: ($asnap==1),
			auto_snapshot_max: $asnapmax,
			antidpi: ($antidpi==1),
			adaptive_routing: ($adapt==1),
			sched_enabled: ($schen==1),
			sched_on: $schon,
			sched_off: $schoff,
			sched_refresh: $schref
		},
		clients: $clients
	}'
