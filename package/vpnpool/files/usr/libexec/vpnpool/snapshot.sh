#!/bin/sh
# vpnpool auto-snapshot: periodically persist the currently-REACHABLE nodes into
# a bounded "snapshot" store so there is always a working fallback set available
# even after the subscription expires (or a source disappears).
#
# Snapshot links live in their own map (SNAP_MAP) capped to auto_snapshot_max, so
# this never evicts the user's manual ⭐ saves (SAVED_MAP). Both maps are merged
# into the uci saved_node list. No sing-box reload: snapshotted nodes are already
# in the pool (they're reachable now); persisting them only matters for later.
. /usr/libexec/vpnpool/lib.sh

[ "$(uci -q get vpnpool.main.auto_snapshot)" = "1" ] || exit 0

MAX=$(uci -q get vpnpool.main.auto_snapshot_max); [ -n "$MAX" ] || MAX=20
LINKS=/etc/vpnpool/links.json
[ -f "$LINKS" ] || exit 0

# reachable nodes from clash, sorted by latency, top MAX tags
P=$(curl -s -m4 "http://$CLASH_API/proxies" 2>/dev/null)
[ -n "$P" ] || exit 0
TAGS=$(echo "$P" | jq -r --argjson max "$MAX" '
	(.proxies // {}) | to_entries
	| map(select((.value.history // []) | length > 0 and (last | .delay // 0) > 0))
	| map({ tag: .key, delay: ((.value.history|last|.delay)) })
	| sort_by(.delay) | .[:$max] | .[].tag
' 2>/dev/null)
[ -n "$TAGS" ] || exit 0

# rebuild the snapshot map fresh from the current reachable set (bounded, wholesale
# replace), keeping only tags whose original link we actually know.
TMP="$SNAP_MAP.new"
echo '{}' > "$TMP"
echo "$TAGS" | while IFS= read -r tag; do
	[ -n "$tag" ] || continue
	link=$(jq -r --arg t "$tag" 'map(select(.tag==$t)) | .[0].link // ""' "$LINKS" 2>/dev/null)
	[ -n "$link" ] || continue
	jq --arg t "$tag" --arg l "$link" '.[$t]=$l' "$TMP" > "$TMP.2" 2>/dev/null && mv "$TMP.2" "$TMP"
done
mv "$TMP" "$SNAP_MAP" 2>/dev/null

CNT=$(jq 'length' "$SNAP_MAP" 2>/dev/null || echo 0)
rebuild_saved_list
log "snapshot: persisted $CNT reachable node(s) to the saved store"
exit 0
