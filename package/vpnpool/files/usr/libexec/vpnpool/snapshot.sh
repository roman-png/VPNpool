#!/bin/sh
# vpnpool "add working nodes to favourites automatically" (uci auto_snapshot, ROADMAP 9.3):
# periodically keep the currently-REACHABLE nodes (the fastest auto_snapshot_max of them) as
# AUTOMATIC favourites, so there is always a working fallback set even after a subscription
# expires (or a source disappears). Automatic entries are replaced wholesale each run; the user's
# own favourites are never touched or evicted (model.uc snapshot). Favourites are keyed by the
# node id and keep the node's link, so they outlive their source. No sing-box reload: the nodes
# are in the pool already (they are reachable now); keeping them only matters for later.
. /usr/libexec/vpnpool/lib.sh

[ "$(uci -q get vpnpool.main.auto_snapshot)" = "1" ] || exit 0

MAX=$(uci -q get vpnpool.main.auto_snapshot_max); case "$MAX" in ''|*[!0-9]*) MAX=20 ;; esac

P=$(curl -s -m4 "http://$CLASH_API/proxies" 2>/dev/null)
[ -n "$P" ] || exit 0
CNT=$(printf '%s' "$P" | ucode "$MODEL" snapshot "$MAX" 2>/dev/null) || { log "snapshot: could not update the favourites"; exit 1; }
log "snapshot: kept ${CNT:-0} working node(s) as automatic favourites"
exit 0
