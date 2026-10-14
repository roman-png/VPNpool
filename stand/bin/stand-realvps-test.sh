#!/bin/sh
# Self-contained clean test of the REAL VPS Reality+Vision node, meant to run when the path
# to the VPS is DIRECT (WG off, or the VPS IP split-tunnelled out of WG) — i.e. the same
# direct-ISP path the router uses. Answers: does the http:// service probe fail more than the
# https:// one through the real Xray-Vision node, on a clean path?
#
# The real vless link is read from /etc/vpnpool/.env.real (REAL_LINK=...), or passed as $1.
# It is NOT hard-coded here (secret hygiene). Writes a clear verdict to stdout.
set -u
CL=127.0.0.1:9091
TAG=stand-real-node
PAIRS=${PAIRS:-12}      # interleaved http/https probe pairs
GAP=${GAP:-3}          # seconds between pairs (mimic nodecheck's spaced, cold probes)

LINK="${1:-}"
[ -n "$LINK" ] || { [ -f /etc/vpnpool/.env.real ] && . /etc/vpnpool/.env.real && LINK="${REAL_LINK:-}"; }
[ -n "$LINK" ] || { echo "ERROR: no real link. Pass as arg or set REAL_LINK in /etc/vpnpool/.env.real"; exit 2; }
# derive tag + host from the link (no hard-coded VPS address — secret hygiene)
case "$LINK" in *\#*) TAG=$(printf '%s' "$LINK" | sed 's/.*#//');; esac
HOST=$(printf '%s' "$LINK" | sed -n 's#.*@\([^:?/#]*\).*#\1#p')

echo "===== 0) path check (should be DIRECT / RU when WG is off or split-tunnelled) ====="
echo -n "container direct egress IP : "; curl -s -m 8 https://api.ipify.org 2>/dev/null; echo
echo -n "container direct egress geo: "; curl -s -m 8 https://ipinfo.io/country 2>/dev/null
[ -n "$HOST" ] && { echo -n "raw TCP to VPS:443         : "; curl -s -o /dev/null -w 'connect=%{time_connect} total=%{time_total}\n' -m 8 -k "https://$HOST:443/" 2>/dev/null; }

echo "===== 1) build client config from the real link ====="
uci -q delete vpnpool.main.manual_node 2>/dev/null
uci add_list vpnpool.main.manual_node="$LINK"
uci commit vpnpool
sh /usr/libexec/vpnpool/build.sh >/tmp/vpnpool/realvps-build.log 2>&1
jq -r '.[].tag' /tmp/vpnpool/nodes.json 2>/dev/null | grep -q "$TAG" \
	&& echo "node '$TAG' in nodes.json: YES" || { echo "node not built; see /tmp/vpnpool/realvps-build.log"; cat /tmp/vpnpool/build.err 2>/dev/null; exit 1; }
sh /work/bin/stand-client-up.sh >/dev/null 2>&1 || { echo "client failed"; tail /tmp/vpnpool/client.log; exit 1; }

echo "===== 2) exit IP THROUGH the node (should be the VPS / DE) ====="
echo -n "via node (socks 1605): "; curl -s -m 10 --proxy socks5h://127.0.0.1:1605 https://api.ipify.org 2>/dev/null; echo

echo "===== 3) interleaved http vs https clash-delay probes ($PAIRS pairs, ${GAP}s gap) ====="
enc=$(jq -rn --arg s "$TAG" '$s|@uri')
hu=$(jq -rn --arg s "http://cp.cloudflare.com/generate_204"  '$s|@uri')
su=$(jq -rn --arg s "https://cp.cloudflare.com/generate_204" '$s|@uri')
hok=0; hf=0; sok=0; sf=0; i=0
while [ $i -lt "$PAIRS" ]; do
	r=$(curl -s -m 9 "http://$CL/proxies/$enc/delay?url=$hu&timeout=5000"); case "$r" in *'"delay"'*) hok=$((hok+1));; *) hf=$((hf+1));; esac
	r=$(curl -s -m 9 "http://$CL/proxies/$enc/delay?url=$su&timeout=5000"); case "$r" in *'"delay"'*) sok=$((sok+1));; *) sf=$((sf+1));; esac
	i=$((i+1)); [ $i -lt "$PAIRS" ] && sleep "$GAP"
done

echo "===== VERDICT ====="
echo "HTTP  (port 80, plain): ok=$hok fail=$hf  of $PAIRS"
echo "HTTPS (port 443, TLS) : ok=$sok fail=$sf  of $PAIRS"
if [ "$hf" -gt $((sf + sf + 1)) ]; then
	echo ">> http fails much more than https => the http probe is the bug; fix = probe over https"
elif [ "$hf" -eq "$sf" ] || { [ "$hf" -le $((sf+1)) ] && [ "$sf" -le $((hf+1)) ]; }; then
	echo ">> http ~= https => scheme is NOT the cause (look elsewhere: timeout, MTU, sing-box ver, DNS)"
else
	echo ">> mixed/noisy result — if direct egress geo above is NOT RU, the path still isn't clean (WG in the way)"
fi
