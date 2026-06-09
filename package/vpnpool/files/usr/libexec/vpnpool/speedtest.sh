#!/bin/sh
# vpnpool: on-demand REAL throughput test for one node (ping != speed).
# Temporarily points the 'proxy' selector at the node, downloads a sized file
# through the local mixed proxy (which egresses via 'proxy'), measures the
# download speed, then restores the previous selection. Writes a JSON result.
#
# NOTE: while the test runs (~seconds) the router's proxied traffic flows through
# the node under test — that's why this is on-demand only, never in the background.
. /usr/libexec/vpnpool/lib.sh

TAG="$1"
OUT=/tmp/vpnpool/.speedtest-result.json
mkdir -p /tmp/vpnpool
TP=$(uci -q get vpnpool.main.test_port); [ -n "$TP" ] || TP=1605
URL=$(uci -q get vpnpool.main.speedtest_url)
[ -n "$URL" ] || URL="https://speed.cloudflare.com/__down?bytes=10000000"

[ -n "$TAG" ] || { echo '{"ok":false,"error":"no tag"}' > "$OUT"; exit 0; }

# Low-memory guard (also enforced by rpcd, repeated here for direct invocation):
# bail out rather than risk OOM-killing sing-box on a tiny router.
MINKB=$(uci -q get vpnpool.main.speedtest_min_mem_kb); [ -n "$MINKB" ] || MINKB=8192
AVAIL=$(awk '/^MemAvailable:/{print $2; found=1} END{if(!found) exit 1}' /proc/meminfo 2>/dev/null)
[ -n "$AVAIL" ] || AVAIL=$(awk '/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print f+b+c}' /proc/meminfo 2>/dev/null)
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$MINKB" ]; then
	echo "{\"ok\":false,\"lowmem\":true,\"avail_kb\":${AVAIL:-0},\"need_kb\":$MINKB}" > "$OUT"; exit 0
fi

# remember the current live selection so we can put it back
PREV=$(curl -s -m3 "http://$CLASH_API/proxies/proxy" 2>/dev/null | jq -r '.now // ""' 2>/dev/null)

curl -s -m5 -X PUT "http://$CLASH_API/proxies/proxy" --data "{\"name\":\"$TAG\"}" >/dev/null 2>&1
sleep 1

RES=$(curl -s -m 25 --proxy "socks5h://127.0.0.1:$TP" -o /dev/null \
	-w '%{speed_download} %{size_download}' "$URL" 2>/dev/null)

# restore the previous selection
[ -n "$PREV" ] && curl -s -m5 -X PUT "http://$CLASH_API/proxies/proxy" --data "{\"name\":\"$PREV\"}" >/dev/null 2>&1

BPS=$(echo "$RES" | awk '{print $1+0}')
SZ=$(echo "$RES"  | awk '{print $2+0}')
MBPS=$(awk -v b="${BPS:-0}" 'BEGIN{printf "%.2f", b*8/1000000}')

if [ "${SZ:-0}" -gt 0 ]; then
	jq -n --arg t "$TAG" --argjson mbps "$MBPS" --argjson bytes "${SZ:-0}" \
		'{ok:true, tag:$t, mbps:$mbps, bytes:$bytes}' > "$OUT"
else
	jq -n --arg t "$TAG" '{ok:false, tag:$t, error:"no data (node unreachable?)"}' > "$OUT"
fi
exit 0
