#!/bin/sh
# vpnpool: parse all fetched source files + manual nodes into one node list,
# generate the sing-box config, and validate it. Keeps the previous config if
# the new one fails sing-box check.
#
# Files: the live config ($SB_CONF) and the node list live in RAM (/tmp/vpnpool). The
# flash copies (/etc/vpnpool/sing-box.json, links.json) are rewritten ONLY when their
# content changed (persist_if_changed) — a periodic rebuild of an unchanged pool costs no
# flash write. nodes.json is replaced atomically and only when the build succeeded, so a
# reader never sees a half-written list and the list always matches the running config.
. /usr/libexec/vpnpool/lib.sh

# the config, the node list and the AWG files carry private keys: files written here are 0600
umask 077
mkdir -p "$SB_DATA"
SRCDIR="$SB_DATA/sources"
NODES="$SB_DATA/nodes.json"
NB="$SB_DATA/nodes.build.json"      # working copy; becomes $NODES only on success
LINKS_RAM="$SB_DATA/links.json"
LINKS_FLASH="$CONF_DIR/links.json"
mkdir -p "$CONF_DIR"

# After a reboot /tmp is empty: seed the live config from the flash copy so "keep the
# previous config" still has something to keep when this build fails.
[ -s "$SB_CONF" ] || { [ -s "$SB_CONF_FLASH" ] && cp "$SB_CONF_FLASH" "$SB_CONF"; }

rm -f "$SB_DATA/.awgcap"   # 1.x guessed AWG support from `version`; now measured (enginecap.uc)

# manual nodes (uci: list manual_node 'vless://...') and imported nodes (uci: list
# imported_node — links the user hand-picked from a probed source) each as their own
# file. vless:// links never contain spaces, so a uci LIST read is safe here.
. /lib/functions.sh 2>/dev/null
write_links() {   # $1=uci option  $2=outfile (replaced by mv: a new inode for status.uc's cache)
	__wl_out="$2.tmp.$$"
	: > "$__wl_out"
	__wl_add() { printf '%s\n' "$1" >> "$__wl_out"; }
	config_load vpnpool 2>/dev/null
	config_list_foreach main "$1" __wl_add 2>/dev/null
	mv -f "$__wl_out" "$2"
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

# Result of this build for the UI (status.sh -> "build"): written on EVERY exit, atomically.
#   {at, ok, nodes, skipped, deferred, engine:{bin,version,awg}|null,
#    dropped:[{source,line|item,reason,field?} | {tag,reason,detail?}], error}
# error / reason are machine codes (the human text lives in the UI's translations).
BUILD_STATUS="$SB_DATA/build_status.json"
DROPS="$SB_DATA/.build_drops.tsv"; : > "$DROPS"   # tag \t <tag> \t \t <reason> \t <detail>
echo '[]' > "$SB_DATA/.build_report.json"
NDEF=0; ENG_JSON=null
build_status() {   # $1=true|false $2=error code ("" on success)
	jq -Rn --argjson ok "$1" --arg err "$2" --argjson n "${CNT:-0}" --argjson at "$(date +%s)" \
		--argjson ndef "${NDEF:-0}" --argjson engine "${ENG_JSON:-null}" \
		--slurpfile rep "$SB_DATA/.build_report.json" '
		[inputs | split("\t") | select(.[0] == "tag")
			| {tag:.[1], reason:.[3]} + (if (.[4] // "") != "" then {detail:.[4]} else {} end)] as $eng
		| (($rep[0] // []) | map(select(.status == "skip" and .reason != "duplicate" and .reason != "not_a_node"))) as $sk
		| {at:$at, ok:$ok, nodes:$n, skipped:($sk | length), deferred:$ndef,
		   engine: (if $engine == null then null else ($engine | {bin, version, awg}) end),
		   dropped: (($sk[:100] | map({source, reason} + (if .line != null then {line} else {item} end)
		                                + (if .field != null then {field} else {} end))) + $eng),
		   error: (if $err == "" then null else $err end)}' "$DROPS" 2>/dev/null | write_atomic "$BUILD_STATUS"
	rm -f "$DROPS" "$SB_DATA/.build_report.json"
}
fail() {   # $1=error code [$2=exit code, default 1]
	trap - INT TERM HUP
	rm -f "$NB" "$NB.x" "$NB.full" "$SB_CONF.new" "$SB_CONF.tmp"
	build_status false "${1:-build_failed}"; exit "${2:-1}"
}
# Killed (the daemon stops / restarts: TERM to its child): the result is "interrupted", never
# the previous build's ok. The live config and nodes.json are untouched (replaced only at the
# end). build.sh holds no lock of its own.
on_signal() {
	trap - INT TERM HUP
	rm -f "$NB" "$NB.x" "$NB.full" "$SB_CONF.new" "$SB_CONF.tmp"
	build_status false interrupted; exit 143
}
trap on_signal INT TERM HUP

# ONE parse for the node list AND the tag->link map (--keep-link), with the node identity
# (--with-id; generator.uc strips id/_link before they could reach sing-box).
# shellcheck disable=SC2086
ucode /usr/libexec/vpnpool/parser.uc --keep-link --with-id $FILES > "$NB.full" 2>"$SB_DATA/build.err"
jq -c 'map(del(._link))' "$NB.full" > "$NB" 2>/dev/null || echo '[]' > "$NB"
# Per-line report (skipped lines and their reasons) for build_status.json; source = file name.
# shellcheck disable=SC2086
ucode /usr/libexec/vpnpool/parser.uc --report $FILES 2>/dev/null \
	| jq -c --arg f "$FILES" '($f | split(" ") | map(select(length > 0) | split("/") | last)) as $names
		| map(. + {source: ($names[.src] // "")})' > "$SB_DATA/.build_report.json" 2>/dev/null
jq -e 'type=="array"' "$SB_DATA/.build_report.json" >/dev/null 2>&1 || echo '[]' > "$SB_DATA/.build_report.json"
# AWG files the parser refuses (e.g. a 1.x file with values that are now checked): not a node,
# but the user must see them and be able to remove them -> awg_unreadable.json [{file, reason, field?}]
# (status "unreadable"; rpcd delete_node {file}). One parser run over the AWG files only.
set --   # the file names as arguments: a name may hold a space (build.sh takes no arguments)
for f in /etc/vpnpool/awg/*.conf; do [ -f "$f" ] && set -- "$@" "$f"; done
if [ $# -gt 0 ]; then
	ucode /usr/libexec/vpnpool/parser.uc --report "$@" 2>/dev/null \
		| jq -c '($ARGS.positional | map(split("/") | last)) as $names
			| map(select(.status == "skip" and .reason != "duplicate") | {file: $names[.src], reason}
			      + (if .field != null then {field} else {} end))' --args "$@" 2>/dev/null | write_atomic "$SB_DATA/awg_unreadable.json"
	jq -e 'type == "array"' "$SB_DATA/awg_unreadable.json" >/dev/null 2>&1 || echo '[]' | write_atomic "$SB_DATA/awg_unreadable.json"
else
	echo '[]' | write_atomic "$SB_DATA/awg_unreadable.json"
fi
CNT=$(jq 'length' "$NB" 2>/dev/null || echo 0)
if [ "${CNT:-0}" -lt 1 ]; then
	log "build: 0 nodes parsed (see $SB_DATA/build.err)"
	fail no_nodes
fi

# Tag names: parser.uc is the ONLY owner — it renames a node named like one of the
# generator's own outbounds (its RESERVED_TAGS: auto, proxy, direct, block, dns-out,
# vpnpool-test) and gives repeated names unique suffixes. The stand test
# build/generator-tags-reserved-in-parser checks that every tag the generator adds is in that
# list, so no second copy of the rule lives here.

# Persistent tag->link map for the "Save node" feature: re-parse the SAME inputs
# with --keep-link so every displayed node's original vless:// link is recorded.
# The flash copy (/etc/vpnpool/links.json, read by rpcd/snapshot) survives a reboot so a
# node can be saved even right before the subscription expires — and it is rewritten only
# when the map changed. nodes.json itself stays link-free (links must never leak into the
# sing-box outbounds).
jq -c 'map({tag, id, link:._link}) | map(select(.link != null and .link != ""))' "$NB.full" 2>/dev/null \
	| write_atomic "$LINKS_RAM"
rm -f "$NB.full"
jq -e 'type=="array"' "$LINKS_RAM" >/dev/null 2>&1 || echo '[]' | write_atomic "$LINKS_RAM"
persist_if_changed "$LINKS_RAM" "$LINKS_FLASH"

# User-excluded nodes (dashboard ✕ on a subscription node -> uci list excluded_node,
# holding the node's link). Drop them from the node list by identity so they never reach
# the config and can't return on a refetch. Matched via links.json (tag->link). Cleared
# wholesale on del_subscription.
EXCJSON=$(uci -q get vpnpool.main.excluded_node 2>/dev/null | tr ' ' '\n' | grep '://' | jq -R . | jq -cs . 2>/dev/null)
if [ -n "$EXCJSON" ] && [ "$EXCJSON" != "[]" ]; then
	jq -c --argjson exc "$EXCJSON" 'map(select(.link as $l | ($exc|index($l))!=null)) | map(.tag)' \
		"$LINKS_RAM" > "$SB_DATA/.exctags.json" 2>/dev/null
	if [ -s "$SB_DATA/.exctags.json" ] && [ "$(cat "$SB_DATA/.exctags.json")" != "[]" ]; then
		jq --slurpfile et "$SB_DATA/.exctags.json" 'map(select(.tag as $t | ($et[0]|index($t))==null))' \
			"$NB" > "$NB.x" 2>/dev/null && mv "$NB.x" "$NB"
		log "build: excluded $(jq 'length' "$SB_DATA/.exctags.json") user-deleted node(s)"
	fi
	rm -f "$SB_DATA/.exctags.json"
fi
CNT=$(jq 'length' "$NB" 2>/dev/null || echo 0)
if [ "${CNT:-0}" -lt 1 ]; then
	log "build: 0 nodes after exclude filter"; fail no_nodes_after_exclude
fi

# ---- the engine and the deferred nodes (ROADMAP 4.1, 4.7) ----
# The binary that will run this config (enginecap.uc select): measured, cached by mtime:size.
# Nodes it can't run are DEFERRED (owner's decision 14.10.2026: an AWG node without the engine is
# kept, shown greyed out, does not go into the config and does not break the build):
#   engine_missing / engine_no_awg — an AmneziaWG node, no AWG-capable engine;
#   engine_no_awg31 — a node with AWG 3.1 fields, the engine has only AWG 2.0 (the old fork);
#   start_failed — the start guard (vpnpoold) saw THIS node's CONFIG stop sing-box at start, with
#                  this very node config and engine, less than BAD_TTL ago (a changed node, another
#                  engine or an expired mark gets a new try).
# Plain WireGuard runs on the stock binary: never deferred for the engine.
DEFERRED="$SB_DATA/deferred.json"
BAD_NODES="$SB_DATA/.bad_nodes.json"
# a start_failed mark ends after BAD_TTL s (my safety limit: the node gets a new try), or when
# the node's config or the engine changed
BAD_TTL=${VPNPOOL_BAD_TTL:-1800}
HAS_AWG=0; jq -e 'any(.[]; .type == "awg")' "$NB" >/dev/null 2>&1 && HAS_AWG=1
ENG_JSON=$(ucode "$ENGINECAP" select "$HAS_AWG" 2>/dev/null)
printf '%s' "$ENG_JSON" | jq -e 'type == "object" and (.bin | type == "string")' >/dev/null 2>&1 \
	|| ENG_JSON=$(jq -nc --arg b "$SB_BIN_DEFAULT" '{bin:$b, version:null, awg:false, sig:null, reason:null}')
SB_BIN=$(printf '%s' "$ENG_JSON" | jq -r '.bin')
SB_VER=$(printf '%s' "$ENG_JSON" | jq -r '.version // ""')
[ -s "$BAD_NODES" ] || echo '{}' > "$BAD_NODES"
jq -c --argjson eng "$ENG_JSON" --slurpfile bad "$BAD_NODES" --argjson now "$(date +%s)" --argjson ttl "$BAD_TTL" '
	(($bad[0] // {}) | if type == "object" then . else {} end) as $b
	| ["header_protection_key", "content_padding_addition", "rekey_after_time", "rekey_timeout",
	   "reject_after_time", "keepalive_timeout", "max_handshake_attempts", "random_trailers", "disable_cookies"] as $f31
	| map(. as $n
		| ($b[$n.id // ""] // null) as $m
		| ($n.type == "awg" and ((any($f31[]; . as $k | $n[$k] != null))
			or (($n.peers // [])[0].persistent_keepalive_interval | type) == "string")) as $n31
		| (if ($eng.reason // null) != null and $n.type == "awg" then {reason: $eng.reason}
		   elif $n31 and ($eng.awg31 // false) != true then {reason: "engine_no_awg31"}
		   elif $m != null and $m.engine == $eng.sig and $m.cfg == ($n | del(.tag, .id) | tojson)
		        and (($m.at // 0) + $ttl) > $now
		   then {reason: "start_failed", detail: $m.detail}
		   else null end) as $d
		| {n: $n, d: $d})
	| {keep: map(select(.d == null) | .n),
	   deferred: map(select(.d != null) | (.n | {id, tag, type,
	                 server: (.server // .peers[0].address), port: (.server_port // .peers[0].port)}
	                 + (if .random_trailers == true then {hints: ["awg_random_trailers"]} else {} end)) + .d)}' \
	"$NB" > "$NB.x" 2>/dev/null || { log "build: deferring nodes failed"; fail build_failed; }
jq -c '.keep' "$NB.x" > "$NB" && jq -c '.deferred' "$NB.x" | write_atomic "$DEFERRED"
rm -f "$NB.x"
NDEF=$(jq 'length' "$DEFERRED" 2>/dev/null || echo 0)
[ "${NDEF:-0}" -gt 0 ] && log "build: $NDEF node(s) deferred: $(jq -r 'map("\(.tag) (\(.reason))") | join(", ")' "$DEFERRED" 2>/dev/null)"
CNT=$(jq 'length' "$NB" 2>/dev/null || echo 0)
if [ "${CNT:-0}" -lt 1 ]; then
	# Nothing the engine can run, but the deferred nodes are there: a clear state for the UI
	# (build_status error only_deferred + deferred.json), not a failure loop — exit 3 tells
	# the daemon to wait for a change (an engine install or new nodes signal it).
	log "build: no node can run on this engine (all $NDEF deferred) — keeping the previous config"
	fail only_deferred 3
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
	jq -r 'to_entries[] | "\(.key)\t\(.value.server)\t\(.value.server_port)"' "$NB" 2>/dev/null > "$tmpd/list"
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
		"$NB" 2>/dev/null | write_atomic "$ALIVE"
	rm -rf "$tmpd"
	local alive_n total_n
	alive_n=$(jq 'length' "$ALIVE" 2>/dev/null || echo 0)
	total_n=$(jq 'length' "$NB" 2>/dev/null || echo 0)
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
	WGTAGS=$(jq -c '[.[] | select(.type=="wireguard" or .type=="awg") | .tag]' "$NB" 2>/dev/null)
	if [ -n "$WGTAGS" ] && [ "$WGTAGS" != "[]" ]; then
		jq -c --argjson wg "$WGTAGS" '. + $wg | unique' "$ALIVE" > "$ALIVE.x" 2>/dev/null && mv "$ALIVE.x" "$ALIVE"
	fi
fi

# The urltest group probes the SAME URL every other "is it alive" check uses (lib.sh).
# ... generated for the engine that runs it (VPNPOOL_SB_VERSION: http_clients on >= 1.14).
VPNPOOL_PROBE_URL=$(primary_probe_url) VPNPOOL_SB_VERSION="$SB_VER" ucode /usr/libexec/vpnpool/generator.uc "$NB" > "$SB_CONF.new" 2>>"$SB_DATA/build.err"

# Resilient validation. A SINGLE malformed node (unsupported flow, reality without
# uTLS, bad cipher, port out of range, a repeated name, …) makes `sing-box check` reject the
# ENTIRE config — so one bad entry in a big public list would otherwise take the whole VPN
# down. Instead, when check names a specific node, drop just that node (and its tag from
# the urltest/selector groups) and re-check, up to a bounded number of times.
#   "outbounds[3].server_port: …" / "outbound[3]" / "endpoints[0]…" -> that array element
# (Repeated / reserved names never get here: parser.uc makes every tag unique.)
# Safety net before check (lib.sh config_tag_guard): a repeated name must not freeze the pool.
if ! config_tag_guard "$SB_CONF.new"; then
	log "build: the generated config repeats a name of its own outbounds — keeping previous config"
	fail own_tag_repeated
fi
[ -n "$TAG_GUARD_JSON" ] && printf '%s' "$TAG_GUARD_JSON" | jq -r '.[] | "tag\t\(.)\t\trepeated_name\t"' >> "$DROPS" 2>/dev/null
dropped=$TAG_GUARD_DROPPED; tries=0
while ! "$SB_BIN" check -c "$SB_CONF.new" 2>"$SB_DATA/check.err"; do
	tries=$((tries + 1))
	if [ "$tries" -gt 50 ]; then
		log "build: >50 bad outbounds (dropped $dropped so far), giving up; keeping previous config — check subscription source quality"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; fail too_many_bad_nodes
	fi
	arr=""; idx=""
	# sing-box names the offending element by its ARRAY (plural, "outbounds[3]" — decode
	# errors) or singular ("outbound[3]" — init errors); WireGuard/AmneziaWG live in
	# .endpoints on >=1.13. The array to prune comes from the match itself.
	m=$(grep -oE '(outbound|endpoint)s?\[[0-9]+\]' "$SB_DATA/check.err" | head -1)
	if [ -n "$m" ]; then
		idx=${m##*[}; idx=${idx%]}
		case "$m" in endpoint*) arr=endpoints ;; *) arr=outbounds ;; esac
	fi
	if [ -z "$idx" ]; then
		log "build: sing-box check failed (non-node error), keeping previous config"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; fail check_failed
	fi
	badtype=$(jq -r --arg a "$arr" --argjson i "$idx" '.[$a][$i].type // ""' "$SB_CONF.new" 2>/dev/null)
	if ! printf '%s' "$NODE_TYPES" | jq -e --arg y "$badtype" 'index($y) != null' >/dev/null 2>&1; then
		# structural outbound (auto/proxy/direct/block) failed — don't gut the config
		log "build: check failed on non-node ${arr}[$idx] ($badtype), keeping previous config"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; fail check_failed
	fi
	badtag=$(jq -r --arg a "$arr" --argjson i "$idx" '.[$a][$i].tag // ""' "$SB_CONF.new" 2>/dev/null)
	jq --arg arr "$arr" --argjson i "$idx" --arg t "$badtag" '
		del(.[$arr][$i])
		| .outbounds |= map(
			if (.type=="urltest" or .type=="selector") and (.outbounds|type=="array")
			then .outbounds -= [$t] else . end)
	' "$SB_CONF.new" > "$SB_CONF.tmp" 2>/dev/null && mv "$SB_CONF.tmp" "$SB_CONF.new" || {
		log "build: failed to prune bad node, keeping previous config"; fail prune_failed; }
	why=$(grep -m1 -oE '(FATAL|ERROR).*' "$SB_DATA/check.err" | sed 's/\x1b\[[0-9;]*m//g' | tr '\t' ' ' | cut -c1-160)
	log "build: dropped node \"$badtag\" rejected by sing-box: $why"
	printf 'tag\t%s\t\trejected_by_engine\t%s\n' "$badtag" "$why" >> "$DROPS"
	dropped=$((dropped + 1))
done

mv "$SB_CONF.new" "$SB_CONF"
# the daemon runs exactly the binary this config was checked with (lib.sh sb_bin)
printf '%s
' "$SB_BIN" | write_atomic "$SB_BIN_FILE"
persist_if_changed "$SB_CONF" "$SB_CONF_FLASH"

# Reconcile the node list with what actually survived into the live config, so the
# dashboard never lists phantom nodes that sing-box check rejected and we pruned
# (they would show up but be un-pingable / un-selectable — they aren't in sing-box).
if [ "$dropped" -gt 0 ]; then
	CFGTAGS=$(jq -c '[.outbounds[].tag] + [(.endpoints//[])[].tag]' "$SB_CONF" 2>/dev/null)
	if [ -n "$CFGTAGS" ]; then
		jq --argjson ct "$CFGTAGS" --argjson own "$(jq -c --argjson nt "$NODE_TYPES" '[.outbounds[] | select(((.type) as $y | $nt | index($y)) == null) | .tag]' "$SB_CONF")" '
			map(select(.tag as $x | ($ct | index($x)) and (($own | index($x)) == null)))
			| reduce .[] as $n ({s:{}, o:[]}; if .s[$n.tag] then . else (.s[$n.tag] = true | .o += [$n]) end) | .o' \
			"$NB" > "$NB.x" 2>/dev/null \
			&& mv "$NB.x" "$NB"
	fi
fi
mv -f "$NB" "$NODES"
CNT=$(jq 'length' "$NODES" 2>/dev/null || echo 0)
trap - INT TERM HUP
build_status true ""

if [ "$dropped" -gt 0 ]; then
	log "build: ok ($CNT nodes; dropped $dropped unsupported)"   # CNT is already the final count
else
	log "build: ok ($CNT nodes)"
fi
exit 0
