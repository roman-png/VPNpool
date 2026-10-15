#!/bin/sh
# vpnpool: on-demand REAL throughput test for one node (ping != speed).
# Points the dedicated 'vpnpool-test' selector (generator.uc) at the node and downloads a
# sized file through the node-test-in inbound, which egresses ONLY via that selector. The
# shared 'proxy' selector — the LAN's traffic — is never touched, so a test can't move the
# LAN onto the node under test or leave it there if the test is killed. Writes a JSON result.
. /usr/libexec/vpnpool/lib.sh

TAG="$1"
OUT=/tmp/vpnpool/.speedtest-result.json
mkdir -p /tmp/vpnpool
NTP=$(uci -q get vpnpool.main.node_test_port); [ -n "$NTP" ] || NTP=1606
URL=$(uci -q get vpnpool.main.speedtest_url)
[ -n "$URL" ] || URL="https://speed.cloudflare.com/__down?bytes=10000000"

[ -n "$TAG" ] || { echo '{"ok":false,"code":"invalid","error":"invalid"}' > "$OUT"; exit 0; }

# Low-memory guard (also enforced by rpcd, repeated here for direct invocation):
# bail out rather than risk OOM-killing sing-box on a tiny router.
MINKB=$(uci -q get vpnpool.main.speedtest_min_mem_kb); [ -n "$MINKB" ] || MINKB=8192
AVAIL=$(awk '/^MemAvailable:/{print $2; found=1} END{if(!found) exit 1}' /proc/meminfo 2>/dev/null)
[ -n "$AVAIL" ] || AVAIL=$(awk '/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print f+b+c}' /proc/meminfo 2>/dev/null)
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$MINKB" ]; then
	echo "{\"ok\":false,\"code\":\"low_memory\",\"error\":\"low_memory\",\"lowmem\":true,\"avail_kb\":${AVAIL:-0},\"need_kb\":$MINKB}" > "$OUT"; exit 0
fi

# The test selector is shared by speedtest and unlock: one test at a time.
node_test_lock || { jq -nc --arg t "$TAG" '{ok:false, tag:$t, code:"busy", error:"busy"}' > "$OUT"; exit 0; }
trap node_test_unlock EXIT
trap 'exit 1' INT TERM   # a killed test must stop, not carry on after releasing the lock

if ! node_test_select "$TAG"; then
	jq -nc --arg t "$TAG" '{ok:false, tag:$t, code:"not_found", error:"not_found"}' > "$OUT"; exit 0
fi

RES=$(curl -s -m 25 --proxy "socks5h://127.0.0.1:$NTP" -o /dev/null \
	-w '%{speed_download} %{size_download}' "$URL" 2>/dev/null)

BPS=$(echo "$RES" | awk '{print $1+0}')
SZ=$(echo "$RES"  | awk '{print $2+0}')
MBPS=$(awk -v b="${BPS:-0}" 'BEGIN{printf "%.2f", b*8/1000000}')

if [ "${SZ:-0}" -gt 0 ]; then
	jq -n --arg t "$TAG" --argjson mbps "$MBPS" --argjson bytes "${SZ:-0}" \
		'{ok:true, tag:$t, mbps:$mbps, bytes:$bytes}' > "$OUT"
else
	jq -n --arg t "$TAG" '{ok:false, tag:$t, code:"no_data", error:"no_data"}' > "$OUT"
fi
exit 0
