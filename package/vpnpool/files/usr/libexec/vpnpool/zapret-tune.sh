#!/bin/sh
# Auto-tune zapret's desync STRATEGY for THIS ISP via blockcheck, then write it into
# zapret's NFQWS_OPT so the direct DPI bypass actually defeats the blocks. Without a
# working strategy smart_bypass only self-learns hostnames but can't beat the DPI.
# Background job (blockcheck takes minutes); the UI polls tune_zapret_result.
. /usr/libexec/vpnpool/lib.sh 2>/dev/null
OUT=/tmp/vpnpool/.zapret-tune.json
BC=/opt/zapret/blockcheck.sh
LOG=/tmp/vpnpool/.bc.log
QUIC=/opt/zapret/files/fake/quic_initial_www_google_com.bin
mkdir -p /tmp/vpnpool
fail() { jq -n --arg s "$1" --arg e "$2" '{ok:false, step:$s, error:$e}' > "$OUT"; exit 0; }

{ [ -x /etc/init.d/zapret ] && uci -q get zapret.config >/dev/null 2>&1; } || fail nozapret "zapret is not installed"
[ -f "$BC" ] || fail noblockcheck "blockcheck.sh not found"

# Probe domain(s) — a known DPI-blocked site is enough to find a working TCP strategy.
DOMS=$(uci -q get vpnpool.main.tune_domains); [ -n "$DOMS" ] || DOMS="rutracker.org"
CSV=$(echo "$DOMS" | tr ' ' ',')

# Run blockcheck (busybox has no `timeout`, so use a manual sleep-kill watchdog).
( BATCH=1 SCANLEVEL=quick IPVS=4 ENABLE_HTTP=0 ENABLE_HTTPS=1 ENABLE_HTTP3=0 PARALLEL=1 \
    DOMAINS="$CSV" sh "$BC" </dev/null >"$LOG" 2>&1 ) &
BCPID=$!
( sleep 300; kill "$BCPID" 2>/dev/null; pkill -f blockcheck 2>/dev/null ) &
WD=$!
wait "$BCPID" 2>/dev/null
kill "$WD" 2>/dev/null

# Parse the first working https strategy from the SUMMARY ("... : nfqws <args>").
STRAT=$(awk '/[*] SUMMARY/{s=1} s && /nfqws /{sub(/.*: nfqws /,""); print; exit}' "$LOG" 2>/dev/null)
# Fallback: any "working strategy found" line earlier in the output.
[ -n "$STRAT" ] || STRAT=$(awk '/working strategy found/{sub(/.*: nfqws /,""); sub(/ ![!]*$/,""); print; exit}' "$LOG" 2>/dev/null)
[ -n "$STRAT" ] || fail nostrategy "blockcheck found no working strategy (site not blocked here, or none worked)"

# Build NFQWS_OPT: apply the winning TCP strategy to our hostlist (user+auto via
# <HOSTLIST>), keep a QUIC fake for UDP/443 so HTTP/3 sites aren't left behind. The
# init prepends --user/--qnum/--dpi-desync-fwmark, so we only supply the strategy.
NFQWS="--filter-tcp=80,443 <HOSTLIST> $STRAT --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=6"
[ -f "$QUIC" ] && NFQWS="$NFQWS --dpi-desync-fake-quic=$QUIC"
# The FILE /opt/zapret/config is what the running nfqws actually reads (uci is NOT
# rendered into it on restart), so rewrite the single-line NFQWS_OPT there; mirror it
# into uci too so remittor's own LuCI app stays consistent.
ZCONF=/opt/zapret/config
if [ -f "$ZCONF" ]; then
	grep -v '^NFQWS_OPT=' "$ZCONF" > "$ZCONF.tmp" 2>/dev/null
	printf 'NFQWS_OPT=" %s "\n' "$NFQWS" >> "$ZCONF.tmp"
	mv "$ZCONF.tmp" "$ZCONF"; chmod 600 "$ZCONF"
fi
uci set zapret.config.NFQWS_OPT="$NFQWS" 2>/dev/null; uci commit zapret 2>/dev/null
/etc/init.d/zapret restart >/dev/null 2>&1
sleep 4

# Light self-check: with the new strategy, is the (now hostlisted) probe domain
# reachable DIRECT? Add it to the user hostlist for the test, then clean up.
PD=$(echo "$DOMS" | awk '{print $1}')
UH=/opt/zapret/ipset/zapret-hosts-user.txt
verified=false
if [ -n "$PD" ]; then
	echo "$PD" >> "$UH"          # nfqws auto-reloads the hostlist by mtime (no signal)
	sleep 5
	c=$(curl -s -o /dev/null -m 10 -A 'Mozilla/5.0' -w '%{http_code}' "https://$PD/" 2>/dev/null)
	grep -vxF "$PD" "$UH" > "$UH.t" 2>/dev/null && mv "$UH.t" "$UH"
	case "$c" in 2*|3*) verified=true ;; esac
fi
rm -f "$LOG"
jq -n --arg s "$STRAT" --argjson v "$verified" '{ok:true, strategy:$s, verified:$v}' > "$OUT"
