#!/bin/sh
# vpnpool: parse all fetched source files + manual nodes into one node list,
# generate the sing-box config, and validate it. Keeps the previous config if
# the new one fails sing-box check.
. /usr/libexec/vpnpool/lib.sh

mkdir -p "$SB_DATA"
SRCDIR="$SB_DATA/sources"
NODES="$SB_DATA/nodes.json"

# manual nodes (uci: list manual_node 'vless://...') and imported nodes (uci: list
# imported_node — links the user hand-picked from a probed source) each as their own
# file. vless:// links never contain spaces, so a uci LIST read is safe here.
. /lib/functions.sh 2>/dev/null
write_links() {   # $1=uci option  $2=outfile
	: > "$2"
	__wl_out="$2"
	__wl_add() { printf '%s\n' "$1" >> "$__wl_out"; }
	config_load vpnpool 2>/dev/null
	config_list_foreach main "$1" __wl_add 2>/dev/null
}
write_links manual_node   "$SB_DATA/manual.links"
write_links imported_node "$SB_DATA/imported.links"
# Saved nodes are an INACTIVE archive (kept so they survive subscription expiry) and
# do NOT auto-join the live config. Only the ones the user explicitly promoted to the
# active pool (uci list active_saved) are merged as real outbounds.
write_links active_saved  "$SB_DATA/active_saved.links"

# gather input files: every source file + manual + imported links (parser
# auto-detects format per file and merges with global dedup + unique tags)
FILES=""
for f in "$SRCDIR"/*.raw; do
	[ -f "$f" ] && FILES="$FILES $f"
done
[ -s "$SB_DATA/manual.links" ]       && FILES="$FILES $SB_DATA/manual.links"
[ -s "$SB_DATA/imported.links" ]     && FILES="$FILES $SB_DATA/imported.links"
[ -s "$SB_DATA/active_saved.links" ] && FILES="$FILES $SB_DATA/active_saved.links"
# AmneziaWG / WireGuard nodes: each .conf is its own file (multi-line INI), so the
# parser sees one [Interface] block per file -> one wireguard endpoint each.
for f in /etc/vpnpool/awg/*.conf; do
	[ -f "$f" ] && FILES="$FILES $f"
done

# shellcheck disable=SC2086
ucode /usr/libexec/vpnpool/parser.uc $FILES > "$NODES" 2>"$SB_DATA/build.err"
CNT=$(jq 'length' "$NODES" 2>/dev/null || echo 0)
if [ "${CNT:-0}" -lt 1 ]; then
	log "build: 0 nodes parsed (see $SB_DATA/build.err)"
	exit 1
fi

# Persistent tag->link map for the "Save node" feature: re-parse the SAME inputs
# with --keep-link so every displayed node's original vless:// link is recorded.
# Kept in /etc/vpnpool (survives reboot) so a node can be saved even right before
# the subscription expires. nodes.json itself stays link-free (links must never
# leak into the sing-box outbounds).
# shellcheck disable=SC2086
ucode /usr/libexec/vpnpool/parser.uc --keep-link $FILES 2>/dev/null \
	| jq -c 'map({tag, link:._link}) | map(select(.link != null and .link != ""))' \
	> /etc/vpnpool/links.json 2>/dev/null || echo '[]' > /etc/vpnpool/links.json

# User-excluded nodes (dashboard ✕ on a subscription node -> uci list excluded_node,
# holding the node's link). Drop them from nodes.json by identity so they never reach
# the config and can't return on a refetch. Matched via links.json (tag->link). Cleared
# wholesale on del_subscription.
EXCJSON=$(uci -q get vpnpool.main.excluded_node 2>/dev/null | tr ' ' '\n' | grep '://' | jq -R . | jq -cs . 2>/dev/null)
if [ -n "$EXCJSON" ] && [ "$EXCJSON" != "[]" ]; then
	jq -c --argjson exc "$EXCJSON" 'map(select(.link as $l | ($exc|index($l))!=null)) | map(.tag)' \
		/etc/vpnpool/links.json > "$SB_DATA/.exctags.json" 2>/dev/null
	if [ -s "$SB_DATA/.exctags.json" ] && [ "$(cat "$SB_DATA/.exctags.json")" != "[]" ]; then
		jq --slurpfile et "$SB_DATA/.exctags.json" 'map(select(.tag as $t | ($et[0]|index($t))==null))' \
			"$NODES" > "$NODES.x" 2>/dev/null && mv "$NODES.x" "$NODES"
		log "build: excluded $(jq 'length' "$SB_DATA/.exctags.json") user-deleted node(s)"
	fi
	rm -f "$SB_DATA/.exctags.json"
fi
CNT=$(jq 'length' "$NODES" 2>/dev/null || echo 0)
if [ "${CNT:-0}" -lt 1 ]; then
	log "build: 0 nodes after exclude filter"; exit 1
fi

# ---- auto-pool health prefilter ----
# The urltest "auto" group probes EVERY member each interval. A node whose server is
# TCP-dead leaves a hung SYN_SENT socket on every cycle; with ~10 dead nodes (a common
# state for a churning public subscription — several "country" tags share one dead IP)
# 100+ stuck sockets pile up within minutes until the urltest probe machinery is so
# backed up that even LIVE nodes stop pinging ("0 pings" on the dashboard) and real
# traffic through 'auto' stalls (context deadline exceeded) — recoverable only by a
# restart, then it degrades again. Root-caused on 2026-06-11.
#
# So TCP-probe each node's server:port here (in parallel) and record the REACHABLE
# tags; the generator keeps ONLY those in the auto/urltest pool. Dead nodes stay in
# the selector for manual choice. If NOTHING is reachable (e.g. a WAN blip during the
# build) we remove the file so the generator falls back to ALL nodes — urltest is
# never left empty. Reality CDN-front nodes answer TLS (time_connect>0) so they pass;
# a dead/blocked server never connects (time_connect==0) so it is excluded.
ALIVE="$SB_DATA/.alive_tags.json"
health_prefilter() {
	local tmpd TAB ct idx srv port batch n
	TAB=$(printf '\t')
	tmpd="$SB_DATA/.hp"; rm -rf "$tmpd"; mkdir -p "$tmpd"
	jq -r 'to_entries[] | "\(.key)\t\(.value.server)\t\(.value.server_port)"' "$NODES" 2>/dev/null > "$tmpd/list"
	# BATCHED backgrounded TCP probes. Spawning one curl per node with NO cap meant a
	# subscription of hundreds of nodes forked hundreds of curls at once — a process/socket/
	# memory burst that can OOM-kill sing-box on a 16 MB router (same hazard that made
	# nodecheck.sh sequential). Drain every $batch spawns so at most $batch run concurrently.
	batch=$(uci -q get vpnpool.main.prefilter_concurrency); case "$batch" in (''|*[!0-9]*) batch=16 ;; esac
	[ "$batch" -ge 1 ] || batch=16
	n=0
	while IFS="$TAB" read -r idx srv port; do
		[ -n "$srv" ] && [ -n "$port" ] || continue
		(
			ct=$(curl -s -o /dev/null --connect-timeout 3 -m 4 -w '%{time_connect}' "https://$srv:$port/" 2>/dev/null)
			[ "$(awk -v t="$ct" 'BEGIN{print (t+0>0)?1:0}')" = 1 ] && : > "$tmpd/a_$idx"
		) &
		n=$((n + 1))
		[ $(( n % batch )) -eq 0 ] && wait
	done < "$tmpd/list"
	wait
	# collect reachable indexes -> their tags
	local idxs
	idxs=$(cd "$tmpd" 2>/dev/null && ls a_* 2>/dev/null | sed 's/^a_//')
	if [ -z "$idxs" ]; then
		rm -f "$ALIVE"; rm -rf "$tmpd"
		log "build: health prefilter found 0 reachable nodes (WAN issue?) — auto-pool unfiltered"
		return 0
	fi
	local idxjson
	idxjson=$(printf '%s\n' $idxs | jq -R 'tonumber' 2>/dev/null | jq -cs . 2>/dev/null)
	[ -n "$idxjson" ] || idxjson='[]'
	jq -c --argjson ai "$idxjson" 'to_entries | map(select(.key as $k | ($ai | index($k)) != null)) | map(.value.tag)' \
		"$NODES" > "$ALIVE" 2>/dev/null
	rm -rf "$tmpd"
	local alive_n total_n
	alive_n=$(jq 'length' "$ALIVE" 2>/dev/null || echo 0)
	total_n=$(jq 'length' "$NODES" 2>/dev/null || echo 0)
	log "build: health prefilter — $alive_n/$total_n nodes reachable, auto-pool limited to them"
}
health_prefilter

# WireGuard/AmneziaWG endpoints are UDP and have no server:port the HTTPS prefilter can
# probe, so they're absent from .alive_tags.json. Always keep them in the auto-pool (their
# real health comes from nodecheck's clash-delay). Only acts when AWG nodes exist; no
# change to the pure-VLESS path.
# Only when the prefilter actually produced a filtered set (ALIVE present): add the AWG
# tags back. If ALIVE is absent (unfiltered fallback) the generator already uses ALL nodes
# incl. AWG, so nothing to do.
if [ -s "$ALIVE" ]; then
	WGTAGS=$(jq -c '[.[] | select(.type=="wireguard" or .type=="awg") | .tag]' "$NODES" 2>/dev/null)
	if [ -n "$WGTAGS" ] && [ "$WGTAGS" != "[]" ]; then
		jq -c --argjson wg "$WGTAGS" '. + $wg | unique' "$ALIVE" > "$ALIVE.x" 2>/dev/null && mv "$ALIVE.x" "$ALIVE"
	fi
fi

ucode /usr/libexec/vpnpool/generator.uc "$NODES" > "$SB_CONF.new" 2>>"$SB_DATA/build.err"

# Resilient validation. A SINGLE malformed node (unsupported flow, reality without
# uTLS, bad cipher, …) makes `sing-box check` reject the ENTIRE config — so one bad
# entry in a big public list would otherwise take the whole VPN down. Instead, when
# check fails on a specific outbound[N], drop just that node outbound (and its tag
# from the urltest/selector groups) and re-check, up to a bounded number of times.
dropped=0; tries=0
while ! sing-box check -c "$SB_CONF.new" 2>"$SB_DATA/check.err"; do
	tries=$((tries + 1))
	if [ "$tries" -gt 50 ]; then
		log "build: >50 bad outbounds (dropped $dropped so far), giving up; keeping previous config — check subscription source quality"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; rm -f "$SB_CONF.new"; exit 1
	fi
	# sing-box >=1.13 reports a bad WireGuard/AmneziaWG node as endpoint[N] (it lives in
	# .endpoints), everything else as outbound[N]. Drop from whichever array it came from;
	# the urltest/selector groups (which reference the tag) always live in .outbounds.
	arr=outbounds
	idx=$(grep -oE 'outbound\[[0-9]+\]' "$SB_DATA/check.err" | head -1 | grep -oE '[0-9]+')
	if [ -z "$idx" ]; then
		idx=$(grep -oE 'endpoint\[[0-9]+\]' "$SB_DATA/check.err" | head -1 | grep -oE '[0-9]+')
		[ -n "$idx" ] && arr=endpoints
	fi
	if [ -z "$idx" ]; then
		log "build: sing-box check failed (non-node error), keeping previous config"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; rm -f "$SB_CONF.new"; exit 1
	fi
	badtype=$(jq -r ".${arr}[$idx].type // \"\"" "$SB_CONF.new" 2>/dev/null)
	case "$badtype" in
		vless|vmess|trojan|shadowsocks|shadowtls|hysteria|hysteria2|tuic|wireguard|awg|socks|http) ;;
		*)  # structural outbound (auto/proxy/direct/block) failed — don't gut the config
			log "build: check failed on non-node ${arr}[$idx] ($badtype), keeping previous config"
			cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; rm -f "$SB_CONF.new"; exit 1 ;;
	esac
	badtag=$(jq -r ".${arr}[$idx].tag // \"\"" "$SB_CONF.new" 2>/dev/null)
	jq --arg arr "$arr" --argjson i "$idx" --arg t "$badtag" '
		del(.[$arr][$i])
		| .outbounds |= map(
			if (.type=="urltest" or .type=="selector") and (.outbounds|type=="array")
			then .outbounds -= [$t] else . end)
	' "$SB_CONF.new" > "$SB_CONF.tmp" 2>/dev/null && mv "$SB_CONF.tmp" "$SB_CONF.new" || {
		log "build: failed to prune bad node, keeping previous config"; rm -f "$SB_CONF.new" "$SB_CONF.tmp"; exit 1; }
	dropped=$((dropped + 1))
done

mv "$SB_CONF.new" "$SB_CONF"

# Reconcile nodes.json with what actually survived into the live config, so the
# dashboard never lists phantom nodes that sing-box check rejected and we pruned
# (they would show up but be un-pingable / un-selectable — they aren't in sing-box).
if [ "$dropped" -gt 0 ]; then
	CFGTAGS=$(jq -c '[.outbounds[].tag] + [(.endpoints//[])[].tag]' "$SB_CONF" 2>/dev/null)
	if [ -n "$CFGTAGS" ]; then
		jq --argjson ct "$CFGTAGS" 'map(select(.tag as $x | $ct | index($x)))' "$NODES" > "$NODES.f" 2>/dev/null \
			&& mv "$NODES.f" "$NODES"
	fi
fi

if [ "$dropped" -gt 0 ]; then
	log "build: ok ($((CNT - dropped)) nodes; dropped $dropped unsupported)"
else
	log "build: ok ($CNT nodes)"
fi
exit 0
