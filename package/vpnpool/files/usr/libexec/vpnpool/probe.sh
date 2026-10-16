#!/bin/sh
# vpnpool: probe ONE source URL for the LuCI import dialog.
#   1. fetch the URL trying several client User-Agents (keep the best yield),
#   2. parse it KEEPING each node's original link (--keep-link),
#   3. cap the list and ICMP-ping each node's server for a latency hint,
#   4. mark nodes already in the pool (by node id: the last build's nodes.json),
#   5. emit JSON: { total, capped, shown, nodes:[{i,id,tag,server,port,delay,in_pool}] }
# The picks of the dialog become a subscription in "pick" mode (rpcd import_select: ids).
# Read-only: changes NO config. Usage: probe.sh <url>
#
# NOTE on the latency hint: busybox `nc` here has no -z/-w and curl has no telnet,
# so a real TCP-connect probe isn't available — we use ICMP ping. Servers that block
# ICMP show delay=null; they can still be selected (the dashboard shows the real
# proxy latency through sing-box once a node is added).
. /usr/libexec/vpnpool/lib.sh

URL="$1"
[ -n "$URL" ] || { echo '{"ok":false,"code":"invalid","error":"invalid","total":0,"capped":false,"shown":0,"nodes":[]}'; exit 0; }

P="/tmp/vpnpool/probe.$$"; mkdir -p "$P"; trap 'rm -rf "$P"' EXIT
CAP=300; PARALLEL=64

# Keep the probe well under the ubus/LuCI call timeout: try only a few UAs and stop
# at the first that yields nodes (most panels serve every client the same list).
UAS="v2rayNG/1.9.5 clash-meta/1.18 Hiddify/2.0"

normalize() {
	c=$(head -c 1 "$1" 2>/dev/null)
	case "$c" in
		'{'|'[') cat "$1" ;;
		*) if head -c 8 "$1" 2>/dev/null | grep -q '://'; then cat "$1"
		   else tr -d '\r\n' < "$1" 2>/dev/null | base64 -d 2>/dev/null || cat "$1"; fi ;;
	esac
}

# fetch with each UA, keep the decoded text that yields the most nodes
best=-1
for ua in $UAS; do
	curl -sfL --connect-timeout 4 -m 10 -A "$ua" -o "$P/raw" "$URL" 2>/dev/null || continue
	[ "$(wc -c < "$P/raw" 2>/dev/null || echo 0)" -ge 20 ] || continue
	normalize "$P/raw" > "$P/txt"
	cnt=$(ucode /usr/libexec/vpnpool/parser.uc --keep-link "$P/txt" 2>/dev/null | jq 'length' 2>/dev/null)
	[ -n "$cnt" ] || cnt=0
	if [ "$cnt" -gt "$best" ]; then best="$cnt"; cp "$P/txt" "$P/best"; fi
	[ "$best" -ge 1 ] && break   # first UA that yields nodes is good enough — keep it fast
done
[ "$best" -ge 1 ] || { echo '{"ok":false,"code":"no_nodes","error":"no_nodes","total":0,"capped":false,"shown":0,"nodes":[]}'; exit 0; }

ucode /usr/libexec/vpnpool/parser.uc --keep-link --with-id "$P/best" 2>/dev/null > "$P/nodes.json"
TOTAL=$(jq 'length' "$P/nodes.json" 2>/dev/null); [ -n "$TOTAL" ] || TOTAL=0
CAPPED=false
if [ "$TOTAL" -gt "$CAP" ]; then jq ".[0:$CAP]" "$P/nodes.json" > "$P/n2" && mv "$P/n2" "$P/nodes.json"; CAPPED=true; fi

# ids already in the pool (to pre-check them in the UI)
jq -c '[.[].id // empty]' /tmp/vpnpool/nodes.json > "$P/pool.ids" 2>/dev/null || echo '[]' > "$P/pool.ids"
jq -e 'type == "array"' "$P/pool.ids" >/dev/null 2>&1 || echo '[]' > "$P/pool.ids"

# ICMP-ping each server in parallel batches; record "tag<TAB>ms"
jq -r '.[] | [.tag, (.server // "")] | @tsv' "$P/nodes.json" > "$P/list.tsv"
: > "$P/ping.tsv"
i=0
while IFS='	' read -r tag srv; do
	if [ -z "$srv" ]; then printf '%s\t\n' "$tag" >> "$P/ping.tsv"; continue; fi
	( ms=$(ping -c 1 -W 1 "$srv" 2>/dev/null | grep -o 'time=[0-9.]*' | head -1 | cut -d= -f2)
	  printf '%s\t%s\n' "$tag" "$ms" ) >> "$P/ping.tsv" &
	i=$((i + 1)); [ $((i % PARALLEL)) -eq 0 ] && wait
done < "$P/list.tsv"
wait

# delay map { tag: ms|null }
jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
	| map({ (.[0]): ((.[1] // "") | if . == "" then null else (tonumber? // null) end) }) | add // {}' \
	"$P/ping.tsv" > "$P/delay.json"

# Enrich each node with a stable index, its ping and whether it's already in the pool.
ENRICHED=$(jq -c --slurpfile d "$P/delay.json" --slurpfile pool "$P/pool.ids" '
	($d[0] // {}) as $dm
	| ($pool[0] // []) as $ids
	| to_entries | map(.value + {
		_i: .key,
		_delay: ($dm[.value.tag] // null),
		_in: ((.value.id // "") as $x | $ids | index($x) != null)
	})' "$P/nodes.json")

# Cache the FULL list (with links) on the router, keyed by URL. import_select reads
# it and resolves the user-picked INDICES to links — so the browser only ever sends
# a tiny array of integers, never hundreds of links (which overflowed the rpc path).
printf '%s' "$ENRICHED" | jq -c --arg url "$URL" '{ url: $url, nodes: map({ i: ._i, id: .id, link: (._link // ""), tag: .tag }) }' > /tmp/vpnpool/.probe-cache.json

# Response to the UI: NO links (keeps it small), just the index `i` to send back.
printf '%s' "$ENRICHED" | jq --argjson total "$TOTAL" --argjson capped "$CAPPED" '
	{ total: $total, capped: $capped, shown: (. | length),
	  nodes: map({ i: ._i, id: .id, tag: .tag, server: .server, port: .server_port, delay: ._delay, in_pool: ._in }) }'
