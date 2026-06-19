#!/bin/sh
# vpnpool node-quality e2e filter — THE single node-quality check ("dead but pingable"
# auto-removal, now service-accurate).
#
# The TCP-connect prefilter (build.sh) only proves a node answers on its port; the old
# generic generate_204 probes only proved it reaches some CDN. Neither proves the node
# opens the service the USER actually wants — so over-quota / geo-blocked exits (TCP-alive,
# Cloudflare-reachable, YouTube-dead) stayed in the pool and the tunnel kept settling on
# them ("pings but the service is dead"). This filter is now the authoritative quality
# gate: it probes every node through the clash delay API (per outbound — it does NOT switch
# the active selector) against the user-configured services (check_probe_urls in lib.sh)
# and keeps a node only if it reaches EVERY one of them. The SAME service set drives the
# generator's urltest "url" (active pick + failover) and the watchdog, so the whole stack
# agrees on what "working" means. Failing tags go to .dead_tags.json, which generator.uc
# drops from the auto/urltest pool (they stay MANUALLY selectable). A node recovers the
# moment it passes again. On a change of the dead set we signal the daemon (USR1) to
# rebuild so the pool updates.
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
clear_stale_lock "$LOCK" 600   # drop a lock left by a SIGKILLed run (else we'd never run again)
[ -f "$LOCK" ] && exit 0
echo $$ > "$LOCK"              # record our PID so clear_stale_lock frees it the instant we die
trap 'rm -f "$LOCK"' EXIT INT TERM

# Service-accuracy probe set (the SINGLE node-quality criterion): the user-configured
# services the VPN must actually open through a node — see check_probe_urls in lib.sh. A
# node is healthy ONLY if it reaches EVERY one of them (strict). This is the whole fix for
# "the node pings but the service is dead": a node that opens Cloudflare but NOT the wanted
# service (over-quota / geo-blocked exit) used to survive the old MINPASS=1 (reach ANY one)
# logic and stay active. Now it's demoted from the auto/urltest pool.
URLS=$(check_probe_urls)
NURLS=$(printf '%s\n' "$URLS" | grep -c .)
[ "${NURLS:-0}" -ge 1 ] || exit 0
STRIKES=$(uci -q get vpnpool.main.dead_filter_strikes); case "$STRIKES" in (''|*[!0-9]*) STRIKES=3 ;; esac
# Per-service probe RETRIES within a single cycle: a node counts as reaching a service if
# ANY of TRIES back-to-back clash-delay attempts succeeds. A Reality/Vision node's COLD
# handshake to a distant server is intermittently flaky (DPI/MTU/path jitter — observed
# ~50% one minute, 3/3 the next on the SAME real node), yet the node is perfectly usable
# once connected (manual selection works). A single-shot probe then flaps a working node
# into the dead set; retrying within the cycle distinguishes "flaky but alive" (passes on a
# retry) from "genuinely dead" (fails every attempt: over-quota / geo-blocked / offline,
# which return 0/N). Proven on the stand against a live 27-node pool: flaky-but-usable nodes
# (1-3/3) are kept, truly-dead nodes (0/3) are still demoted. A reachable node costs ONE
# attempt (break on first success); only flaky/dead nodes pay the extra attempts.
TRIES=$(uci -q get vpnpool.main.dead_filter_tries); case "$TRIES" in (''|*[!0-9]*) TRIES=3 ;; esac
[ "${TRIES:-0}" -ge 1 ] || TRIES=3

TAB=$(printf '\t')
[ -f "$STRK" ] || : > "$STRK"
tmpd=/tmp/vpnpool/.nc; rm -rf "$tmpd"; mkdir -p "$tmpd"
newstrk="$tmpd/strikes.new"; : > "$newstrk"
deadlist="$tmpd/dead.txt"; : > "$deadlist"
# tag<TAB>delay for every node that answered at least one probe this cycle. Published to
# .nodedelay.json so the dashboard can show a ping for a reachable node even when sing-box's
# own urltest (single-shot, every interval) happened to miss it — see status.sh delay fallback.
ndelayf="$tmpd/ndelay"; : > "$ndelayf"
DELAYMAP=/tmp/vpnpool/.nodedelay.json

# Force-kept nodes (dashboard "Вернуть в авто" -> uci list keep_auto): the user's manual
# override of this filter. Skip them entirely — never probe, strike or flag — so a node the
# user pulled back can't re-enter the dead set. Tags can contain spaces, so read the list
# with config_list_foreach (a uci-get + tr split would shred them).
KEEP="$tmpd/keep"; : > "$KEEP"
# Read keep_auto in a SUBSHELL. /lib/functions.sh defines N as a newline char, which
# would clobber OUR $N (the nodes.json path) — sourcing it inline once broke the probe
# loop entirely (`jq -r '.[].tag' "$N"` got a newline as its filename → 0 nodes → every
# sweep was a no-op). The subshell isolates that (and any other) side effect; KEEP is a
# file, so the writes survive the subshell.
(
	. /lib/functions.sh 2>/dev/null
	__kp_add() { printf '%s\n' "$1" >> "$KEEP"; }
	config_load vpnpool 2>/dev/null
	config_list_foreach main keep_auto __kp_add 2>/dev/null
)

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
	grep -Fxq "$t" "$KEEP" 2>/dev/null && continue   # user force-kept -> exempt from filter
	enc=$(jq -rn --arg s "$t" '$s|@uri')
	pass=0
	lastdelay=
	for eu in "$@"; do
		# retry up to TRIES times; a single success = service reachable (break early)
		a=0
		while [ "$a" -lt "$TRIES" ]; do
			r=$(curl -s -m 8 "http://$CL/proxies/$enc/delay?url=$eu&timeout=5000" 2>/dev/null)
			case "$r" in *'"delay"'*)
				pass=$((pass + 1))
				# extract the numeric delay from {"delay":N...} (no jq per probe)
				d=${r#*\"delay\":}; d=${d%%[!0-9]*}; [ -n "$d" ] && lastdelay=$d
				break ;;
			esac
			a=$((a + 1))
		done
	done
	# record the measured delay for ANY node that answered (even if it didn't pass every
	# service) so the dashboard has a real ping to show for a reachable-but-flaky node
	[ -n "$lastdelay" ] && printf '%s%s%s\n' "$t" "$TAB" "$lastdelay" >> "$ndelayf"
	prev=$(awk -F"$TAB" -v k="$t" '$1==k{print $2; exit}' "$STRK" 2>/dev/null); case "$prev" in (''|*[!0-9]*) prev=0 ;; esac
	# strict: a node must reach EVERY configured service to count as healthy this cycle
	if [ "$pass" -ge "$NURLS" ]; then cur=0; else cur=$((prev + 1)); fi
	printf '%s%s%s\n' "$t" "$TAB" "$cur" >> "$newstrk"
	[ "$cur" -ge "$STRIKES" ] && printf '%s\n' "$t" >> "$deadlist"
done
mv "$newstrk" "$STRK"

new=$(jq -R . "$deadlist" 2>/dev/null | jq -cs 'map(select(length>0))' 2>/dev/null); [ -n "$new" ] || new='[]'
old=$(cat "$DEAD" 2>/dev/null); [ -n "$old" ] || old='[]'
printf '%s\n' "$new" > "$DEAD"

# Publish tag->delay map for the dashboard ping fallback (built once from the accumulated
# tab-separated file; tags can contain spaces/emoji so split on the literal TAB only).
if [ -s "$ndelayf" ]; then
	jq -Rn --arg tab "$TAB" '[inputs | split($tab) | select(length==2) | {(.[0]): (.[1]|tonumber?)}] | add // {}' \
		< "$ndelayf" > "$DELAYMAP" 2>/dev/null || echo '{}' > "$DELAYMAP"
else
	echo '{}' > "$DELAYMAP"
fi
rm -rf "$tmpd"

if [ "$old" != "$new" ]; then
	log "nodecheck: dead set changed -> $new"
	if [ "${NODECHECK_DRYRUN:-0}" != "1" ]; then
		signal_daemon USR1
	fi
fi
exit 0
