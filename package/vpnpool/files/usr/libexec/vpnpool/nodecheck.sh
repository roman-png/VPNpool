#!/bin/sh
# vpnpool node-quality e2e filter ("dead but pingable" auto-removal).
#
# The TCP-connect prefilter (build.sh) and the single cp.cloudflare urltest probe
# both pass on nodes that DON'T actually carry traffic: expired-subscription
# placeholder nodes, over-quota exits, exits blocked from the services the user
# needs. Empirically (2026-06-12) a node can also fail ONE provider (Cloudflare)
# yet serve Google/YouTube perfectly — so a single-URL probe wrongly condemns a
# good node. This filter probes every node through the clash delay API (per
# outbound — it does NOT switch the active selector) against a DIVERSE set of
# generate_204 endpoints and flags a node only when it reaches NONE of them for a
# sustained run of checks. Flagged tags go to .dead_tags.json, which generator.uc
# drops from the auto/urltest pool (they stay MANUALLY selectable). A node recovers
# the moment it passes again. On a change of the dead set we signal the daemon
# (USR1) to rebuild so the pool updates.
#
# Safety mirrors the watchdog's hard-won tuning: a node must fail STRIKES cycles in
# a row (not one flap) before it is dropped, and the pool is never emptied.
#
# Env: NODECHECK_DRYRUN=1 -> compute + write .dead_tags.json but DON'T signal a
# rebuild (used to validate the discriminator on a live router without bouncing it).
. /usr/libexec/vpnpool/lib.sh 2>/dev/null
CL=$(uci -q get vpnpool.main.clash_api); [ -n "$CL" ] || CL=127.0.0.1:9091
N=/tmp/vpnpool/nodes.json
DEAD=/tmp/vpnpool/.dead_tags.json
STRK=/tmp/vpnpool/.deadstrikes
[ -f "$N" ] || exit 0
mkdir -p /tmp/vpnpool

# Single-flight guard: this sweep is triggered BOTH from the dashboard ping and from
# the daemon's periodic hook — never run two concurrently (double clash-API load).
LOCK=/tmp/vpnpool/.nodecheck-running
[ -f "$LOCK" ] && exit 0
: > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

# Diverse probe set: one provider's block must not condemn a node (the USA node
# fails Cloudflare but serves Google/YouTube). Configurable via uci.
URLS=$(uci -q get vpnpool.main.dead_filter_urls)
[ -n "$URLS" ] || URLS="http://cp.cloudflare.com/generate_204 http://www.google.com/generate_204 http://www.youtube.com/generate_204 http://connectivitycheck.gstatic.com/generate_204"
STRIKES=$(uci -q get vpnpool.main.dead_filter_strikes); case "$STRIKES" in (''|*[!0-9]*) STRIKES=3 ;; esac
MINPASS=$(uci -q get vpnpool.main.dead_filter_minpass); case "$MINPASS" in (''|*[!0-9]*) MINPASS=1 ;; esac

TAB=$(printf '\t')
[ -f "$STRK" ] || : > "$STRK"
tmpd=/tmp/vpnpool/.nc; rm -rf "$tmpd"; mkdir -p "$tmpd"
newstrk="$tmpd/strikes.new"; : > "$newstrk"
deadlist="$tmpd/dead.txt"; : > "$deadlist"

# Pre-encode the probe URLs ONCE into positional params (no jq per probe).
set --
for u in $URLS; do set -- "$@" "$(jq -rn --arg s "$u" '$s|@uri')"; done

# Probe SEQUENTIALLY. Running 7 nodes x 4 URLs in PARALLEL spawned ~100 procs and
# saturated the clash API on a 16 MB router so EVERY probe timed out and every node
# was falsely flagged dead (2026-06-12). One-at-a-time is plenty fast (each delay is
# ~0.5 s) and leaves the tiny router responsive. Substring-match the success JSON
# ({"delay":N}) instead of spawning jq per probe.
jq -r '.[].tag' "$N" 2>/dev/null | while IFS= read -r t; do
	[ -n "$t" ] || continue
	enc=$(jq -rn --arg s "$t" '$s|@uri')
	pass=0
	for eu in "$@"; do
		r=$(curl -s -m 8 "http://$CL/proxies/$enc/delay?url=$eu&timeout=5000" 2>/dev/null)
		case "$r" in *'"delay"'*) pass=$((pass + 1)) ;; esac
	done
	prev=$(awk -F"$TAB" -v k="$t" '$1==k{print $2; exit}' "$STRK" 2>/dev/null); case "$prev" in (''|*[!0-9]*) prev=0 ;; esac
	if [ "$pass" -ge "$MINPASS" ]; then cur=0; else cur=$((prev + 1)); fi
	printf '%s%s%s\n' "$t" "$TAB" "$cur" >> "$newstrk"
	[ "$cur" -ge "$STRIKES" ] && printf '%s\n' "$t" >> "$deadlist"
done
mv "$newstrk" "$STRK"

new=$(jq -R . "$deadlist" 2>/dev/null | jq -cs 'map(select(length>0))' 2>/dev/null); [ -n "$new" ] || new='[]'
old=$(cat "$DEAD" 2>/dev/null); [ -n "$old" ] || old='[]'
printf '%s\n' "$new" > "$DEAD"
rm -rf "$tmpd"

if [ "$old" != "$new" ]; then
	log "nodecheck: dead set changed -> $new"
	if [ "${NODECHECK_DRYRUN:-0}" != "1" ]; then
		kill -USR1 "$(cat /var/run/vpnpool.pid 2>/dev/null)" 2>/dev/null
	fi
fi
exit 0
