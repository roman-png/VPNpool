#!/bin/sh
# vpnpool: per-node "what does this node unblock" test. Like speedtest, it briefly
# points the proxy selector at the node, probes a set of services THROUGH the tunnel,
# records which return OK, then restores the previous selection. On-demand only
# (it flips the router's egress to this node for a few seconds) + low-mem guarded.
. /usr/libexec/vpnpool/lib.sh

TAG="$1"
OUT=/tmp/vpnpool/.unlock-result.json
MAP=/etc/vpnpool/unlock.map.json
mkdir -p /tmp/vpnpool /etc/vpnpool
[ -f "$MAP" ] || echo '{}' > "$MAP"
TP=$(uci -q get vpnpool.main.test_port); [ -n "$TP" ] || TP=1605
[ -n "$TAG" ] || { echo '{"ok":false,"error":"no tag"}' > "$OUT"; exit 0; }

# low-memory guard (same threshold as speedtest)
MINKB=$(uci -q get vpnpool.main.speedtest_min_mem_kb); [ -n "$MINKB" ] || MINKB=8192
AVAIL=$(awk '/^MemAvailable:/{print $2; found=1} END{if(!found) exit 1}' /proc/meminfo 2>/dev/null)
[ -n "$AVAIL" ] || AVAIL=$(awk '/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print f+b+c}' /proc/meminfo 2>/dev/null)
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$MINKB" ]; then
	echo "{\"ok\":false,\"lowmem\":true,\"avail_kb\":${AVAIL:-0},\"need_kb\":$MINKB}" > "$OUT"; exit 0
fi

PREV=$(curl -s -m3 "http://$CLASH_API/proxies/proxy" 2>/dev/null | jq -r '.now // ""' 2>/dev/null)
curl -s -m5 -X PUT "http://$CLASH_API/proxies/proxy" --data "{\"name\":\"$TAG\"}" >/dev/null 2>&1
sleep 1

probe() {   # $1=url -> 1 if reachable (2xx/3xx and not 4xx/5xx), else 0
	code=$(curl -s -o /dev/null -m 8 -A 'Mozilla/5.0' --proxy "socks5h://127.0.0.1:$TP" -w '%{http_code}' "$1" 2>/dev/null)
	case "$code" in 2*|3*) echo 1 ;; *) echo 0 ;; esac
}

YT=$(probe https://www.youtube.com/)
OAI=$(probe https://chat.openai.com/)                 # 403 in blocked regions
NFX=$(probe https://www.netflix.com/title/80018499)
IG=$(probe https://www.instagram.com/)
TG=$(probe https://web.telegram.org/)
GG=$(probe https://www.google.com/)

[ -n "$PREV" ] && curl -s -m5 -X PUT "http://$CLASH_API/proxies/proxy" --data "{\"name\":\"$PREV\"}" >/dev/null 2>&1

RES=$(jq -n --argjson yt "${YT:-0}" --argjson oai "${OAI:-0}" --argjson nfx "${NFX:-0}" \
	--argjson ig "${IG:-0}" --argjson tg "${TG:-0}" --argjson gg "${GG:-0}" \
	'{youtube:($yt==1),openai:($oai==1),netflix:($nfx==1),instagram:($ig==1),telegram:($tg==1),google:($gg==1)}')
jq -n --arg t "$TAG" --argjson r "$RES" '{ok:true,tag:$t,results:$r}' > "$OUT"
# persist for dashboard badges
jq --arg t "$TAG" --argjson r "$RES" '.[$t]=$r' "$MAP" > "$MAP.tmp" 2>/dev/null && mv "$MAP.tmp" "$MAP"
exit 0
