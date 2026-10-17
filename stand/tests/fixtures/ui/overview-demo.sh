#!/bin/sh
# Stand-only: the Overview tab with something to show — everything of nodes-demo.sh (two
# subscriptions, failing / waiting / excluded nodes, a stand-in daemon) plus what the daemon's
# background checks would write: the tunnel state, the exit of the active node, the last node
# check, and a stand-in for the VPN engine's control API (proxies + connections, served by uhttpd
# on 127.0.0.1:9091) so the active node, the speed and the traffic per device show up:
#   KEEP=1 NAME=vpnpool-ui2-keep PORT=18085 sh stand/tests/ui-components.sh
#   MSYS_NO_PATHCONV=1 docker exec vpnpool-ui2-keep sh /work/tests/fixtures/ui/overview-demo.sh [state]
#   http://localhost:18085/cgi-bin/luci/admin/services/vpnpool/dashboard   (root / vpnpool)
# state (optional): up (default) | down | wan_down | starting | empty (nothing added: the wizard)
# Writes only inside the container. No real nodes or addresses (example.com, 198.51.100.0/24).
set -e
STATE=${1:-up}
SB=/tmp/vpnpool
sh /work/tests/fixtures/ui/nodes-demo.sh >/dev/null
NOW=$(date +%s)
A=a1a1a1a1a1a1 B=b2b2b2b2b2b2

if [ "$STATE" = empty ]; then
	uci -q delete vpnpool.sub_main || true
	uci -q delete vpnpool.sub_pick || true
	uci -q delete vpnpool.main.hidden || true
	uci commit vpnpool
	echo '[]' > "$SB/nodes.json"; echo '[]' > "$SB/deferred.json"; echo '[]' > "$SB/hidden.json"
	echo '{}' > /etc/vpnpool/favorites.map.json
	echo "{\"at\":$NOW,\"ok\":false,\"error\":\"no_nodes\",\"nodes\":0}" > "$SB/build_status.json"
	echo "starting $NOW" > "$SB/.tunnel"
	rm -f "$SB/exit.json"
else
	echo "$STATE $((NOW - 300))" > "$SB/.tunnel"
	echo "{\"ok\":true,\"ip\":\"198.51.100.7\",\"country\":\"NL\",\"node\":\"🇳🇱 Amsterdam\",\"at\":$((NOW - 60))}" > "$SB/exit.json"
	printf '%s\t3\t%s\twww.youtube.com\n%s\t0\t%s\t\n' "$B" "$((NOW - 600))" "$A" "$((NOW - 600))" > "$SB/.deadstrikes"
	echo "{\"at\":$((NOW - 700)),\"ok\":true,\"nodes\":6,\"skipped\":0,\"deferred\":1,\"dropped\":[],\"error\":null}" > "$SB/build_status.json"
fi

# the engine's control API stand-in: the active node + connections (totals grow on every poll:
# a CGI-free trick — the files are rewritten by a background loop)
D=/tmp/clash-demo; mkdir -p "$D"
cat > "$D/proxies" <<J
{"proxies":{"proxy":{"type":"Selector","now":"auto"},"auto":{"type":"URLTest","now":"🇳🇱 Amsterdam"},
 "🇳🇱 Amsterdam":{"type":"VLESS","history":[{"delay":81}]}}}
J
cat > /tmp/clash-demo.sh <<'L'
#!/bin/sh
n=0
while :; do
	n=$((n + 1))
	cat > /tmp/clash-demo/connections.tmp <<J
{"uploadTotal":$((n * 52000)),"downloadTotal":$((n * 1300000)),"connections":[
 {"metadata":{"sourceIP":"192.168.1.10","host":"a.example"},"chains":["🇳🇱 Amsterdam","auto","proxy"],"upload":$((n * 40000)),"download":$((n * 1000000))},
 {"metadata":{"sourceIP":"192.168.1.10","host":"b.example"},"chains":["🇳🇱 Amsterdam","auto","proxy"],"upload":2000,"download":90000},
 {"metadata":{"sourceIP":"192.168.1.23","host":"c.example"},"chains":["direct"],"upload":$((n * 12000)),"download":$((n * 300000))}]}
J
	mv -f /tmp/clash-demo/connections.tmp /tmp/clash-demo/connections
	sleep 5
done
L
pgrep -f /tmp/clash-demo.sh >/dev/null 2>&1 || setsid sh /tmp/clash-demo.sh >/dev/null 2>&1 < /dev/null &
pgrep -f 'uhttpd.*9091' >/dev/null 2>&1 || uhttpd -p 127.0.0.1:9091 -h "$D" >/dev/null 2>&1 || true
printf '%s 1a:2b:3c:4d:5e:6f 192.168.1.10 laptop *\n' "$((NOW + 3600))" > /tmp/dhcp.leases
# our routes: an empty table of ours (needs NET_ADMIN; without it the Overview says the routes are not up)
nft add table inet vpnpool 2>/dev/null || true
# no NET_ADMIN (the usual kept stand): a stand-in nft that answers only "list table inet vpnpool",
# so the Overview can show the "VPN works" state in screenshots (this container only)
if [ "$STATE" = up ] && ! nft list table inet vpnpool >/dev/null 2>&1; then
	N=$(command -v nft)
	[ -e "$N.real" ] || mv "$N" "$N.real"
	printf '#!/bin/sh
[ "$*" = "list table inet vpnpool" ] && { echo "table inet vpnpool {"; echo "}"; exit 0; }
exec %s.real "$@"
' "$N" > "$N"
	chmod +x "$N"
fi
sleep 6
ubus call vpnpool status 2>/dev/null | jq -c '{running, routing, tunnel, exit, auto_now, clients: (.client_traffic | length), nodes: (.nodes | length)}'
