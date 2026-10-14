#!/bin/sh
# vpnpool: per-node "what does this node unblock" test. Like speedtest, it points the
# dedicated 'vpnpool-test' selector at the node and probes a set of services through the
# node-test-in inbound — the LAN's 'proxy' selector is never touched. On-demand only +
# low-mem guarded. Result: /tmp/vpnpool/.unlock-result.json; badges: unlock.map.json.
. /usr/libexec/vpnpool/lib.sh

TAG="$1"
OUT=/tmp/vpnpool/.unlock-result.json
MAP=/etc/vpnpool/unlock.map.json
mkdir -p /tmp/vpnpool /etc/vpnpool
[ -f "$MAP" ] || echo '{}' > "$MAP"
NTP=$(uci -q get vpnpool.main.node_test_port); [ -n "$NTP" ] || NTP=1606
[ -n "$TAG" ] || { echo '{"ok":false,"error":"no tag"}' > "$OUT"; exit 0; }

# low-memory guard (same threshold as speedtest)
MINKB=$(uci -q get vpnpool.main.speedtest_min_mem_kb); [ -n "$MINKB" ] || MINKB=8192
AVAIL=$(awk '/^MemAvailable:/{print $2; found=1} END{if(!found) exit 1}' /proc/meminfo 2>/dev/null)
[ -n "$AVAIL" ] || AVAIL=$(awk '/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print f+b+c}' /proc/meminfo 2>/dev/null)
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$MINKB" ]; then
	echo "{\"ok\":false,\"lowmem\":true,\"avail_kb\":${AVAIL:-0},\"need_kb\":$MINKB}" > "$OUT"; exit 0
fi

node_test_lock || { jq -nc --arg t "$TAG" '{ok:false, tag:$t, error:"another node test is running"}' > "$OUT"; exit 0; }
trap node_test_unlock EXIT INT TERM

if ! node_test_select "$TAG"; then
	jq -nc --arg t "$TAG" '{ok:false, tag:$t, error:"node not available in the running config"}' > "$OUT"; exit 0
fi

probe() {   # $1=url -> 1 if reachable (2xx/3xx and not 4xx/5xx), else 0
	code=$(curl -s -o /dev/null -m 8 -A 'Mozilla/5.0' --proxy "socks5h://127.0.0.1:$NTP" -w '%{http_code}' "$1" 2>/dev/null)
	case "$code" in 2*|3*) echo 1 ;; *) echo 0 ;; esac
}

YT=$(probe https://www.youtube.com/)
OAI=$(probe https://chat.openai.com/)                 # 403 in blocked regions
NFX=$(probe https://www.netflix.com/title/80018499)
IG=$(probe https://www.instagram.com/)
TG=$(probe https://web.telegram.org/)
GG=$(probe https://www.google.com/)

RES=$(jq -n --argjson yt "${YT:-0}" --argjson oai "${OAI:-0}" --argjson nfx "${NFX:-0}" \
	--argjson ig "${IG:-0}" --argjson tg "${TG:-0}" --argjson gg "${GG:-0}" \
	'{youtube:($yt==1),openai:($oai==1),netflix:($nfx==1),instagram:($ig==1),telegram:($tg==1),google:($gg==1)}')
jq -n --arg t "$TAG" --argjson r "$RES" '{ok:true,tag:$t,results:$r}' > "$OUT"
# persist for dashboard badges — only when the badges changed (flash wear)
jq --arg t "$TAG" --argjson r "$RES" '.[$t]=$r' "$MAP" > "$SB_DATA/.unlock.map.new" 2>/dev/null \
	&& persist_if_changed "$SB_DATA/.unlock.map.new" "$MAP"
rm -f "$SB_DATA/.unlock.map.new"
exit 0
