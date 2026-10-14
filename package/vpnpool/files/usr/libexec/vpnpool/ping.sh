#!/bin/sh
# vpnpool: ping every node through the clash delay API (per outbound — the active selector
# is NOT touched) against the PRIMARY check service, so a node's delay means "it reaches
# the wanted service" (lib.sh: one "is it alive" criterion). sing-box keeps each result in
# the node's delay history, which the dashboard shows.
#
# BATCHED: at most prefilter_concurrency probes run at once (the old code forked one curl per
# node with no cap — 300 nodes = 300 curls at once on a router). Progress for the UI:
#   /tmp/vpnpool/.ping-progress.json  {"running":true|false,"done":N,"total":T,"alive":A}
# Afterwards the dead-node filter sweep (nodecheck.sh, sequential, self-locked) is started
# when the filter is on.
. /usr/libexec/vpnpool/lib.sh

N="$SB_DATA/nodes.json"
PROG="$SB_DATA/.ping-progress.json"
tmpd="$SB_DATA/.ping"; rm -rf "$tmpd"; mkdir -p "$tmpd"

progress() {   # $1=running(true|false) $2=done $3=total $4=alive
	printf '{"running":%s,"done":%s,"total":%s,"alive":%s}\n' "$1" "$2" "$3" "$4" | write_atomic "$PROG"
}

HU=$(primary_probe_url); [ -n "$HU" ] || HU=http://cp.cloudflare.com/generate_204
ENCU=$(jq -rn --arg s "$HU" '$s|@uri')
jq -r '.[].tag' "$N" 2>/dev/null > "$tmpd/tags"
total=$(grep -c . "$tmpd/tags" 2>/dev/null); total=${total:-0}
batch=$(uci -q get vpnpool.main.prefilter_concurrency); case "$batch" in (''|*[!0-9]*) batch=16 ;; esac
[ "$batch" -ge 1 ] || batch=16

done_n=0; i=0
progress true 0 "$total" 0
while IFS= read -r tag; do
	[ -n "$tag" ] || continue
	i=$((i + 1))
	enc=$(jq -rn --arg s "$tag" '$s|@uri')
	(
		r=$(curl -s -m 7 "http://$CLASH_API/proxies/$enc/delay?url=$ENCU&timeout=5000" 2>/dev/null)
		clash_delay_alive "$r" && : > "$tmpd/ok_$i"
	) &
	if [ $(( i % batch )) -eq 0 ]; then
		wait
		done_n=$i
		progress true "$done_n" "$total" "$(ls "$tmpd" | grep -c '^ok_')"
	fi
done < "$tmpd/tags"
wait
alive=$(ls "$tmpd" | grep -c '^ok_')
progress false "$total" "$total" "$alive"
rm -rf "$tmpd"
log "ping: $alive/$total nodes answered"

# Fold the dead-node e2e filter into the ping: a SEQUENTIAL quality sweep (self-guarded
# against concurrent runs). It signals the daemon (USR1) to rebuild ONLY if the dead set
# changed — so no rebuild/bounce unless a node actually went dead/recovered.
if [ "$(uci -q get vpnpool.main.dead_filter)" != "0" ]; then
	setsid sh -c '/usr/libexec/vpnpool/nodecheck.sh' >/dev/null 2>&1 &
fi
exit 0
