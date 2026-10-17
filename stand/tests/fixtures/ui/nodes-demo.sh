#!/bin/sh
# Stand-only: fill the inputs that status.uc reads so the Nodes tab shows every kind of card
# (two subscriptions — one taking every node, with expiry and quota; one with picked nodes and a
# failed update — my nodes, an AmneziaWG node waiting for the engine, a node that fails the
# service check, a node excluded from the automatic choice, a favourite no subscription has, a
# hidden node, a long name) and a stand-in daemon, for a look in a browser:
#   KEEP=1 PORT=18081 sh stand/tests/ui-components.sh
#   docker exec vpnpool-ui-components sh /work/tests/fixtures/ui/nodes-demo.sh
#   http://localhost:18081/cgi-bin/luci/admin/services/vpnpool/nodes   (root / vpnpool)
# Writes only inside the container (uci vpnpool, /etc/vpnpool, /tmp/vpnpool). No real nodes:
# every address is under example.com, the keys are made up.
set -e
SB=/tmp/vpnpool
C=/etc/vpnpool
mkdir -p "$SB" "$C/sources_cache" "$C/awg"
NOW=$(date +%s)
A=a1a1a1a1a1a1 B=b2b2b2b2b2b2 X=c3c3c3c3c3c3 D=d4d4d4d4d4d4 M=e5e5e5e5e5e5 W=f6f6f6f6f6f6
L=a7a7a7a7a7a7 F=0f0f0f0f0f0f H=0a0a0a0a0a0a
U1=https://sub.example.com/main/abc123
U2=https://list.example.com/picked

uci -q delete vpnpool.sub_main || true
uci -q delete vpnpool.sub_pick || true
uci -q delete vpnpool.main.auto_member || true
uci -q delete vpnpool.main.hidden || true
uci -q delete vpnpool.main.preferred_node || true
uci set vpnpool.sub_main=subscription
uci set vpnpool.sub_main.name='Main provider'
uci set vpnpool.sub_main.url="$U1"
uci set vpnpool.sub_main.enabled=1
uci set vpnpool.sub_main.mode=all
uci set vpnpool.sub_pick=subscription
uci set vpnpool.sub_pick.name='Picked list'
uci set vpnpool.sub_pick.url="$U2"
uci set vpnpool.sub_pick.enabled=1
uci set vpnpool.sub_pick.mode=pick
uci add_list vpnpool.sub_pick.pick="$D"
uci -q delete vpnpool.main.auto_exclude || true
uci add_list vpnpool.main.auto_exclude="$X"   # X is excluded from the automatic choice by the user
uci add_list vpnpool.main.hidden="$H"
uci commit vpnpool

cat > "$SB/nodes.json" <<J
[
 {"tag":"🇳🇱 Amsterdam","id":"$A","type":"vless","server":"nl.example.com","server_port":443,"_src":"sub:sub_main"},
 {"tag":"🇩🇪 Frankfurt","id":"$B","type":"trojan","server":"de.example.com","server_port":443,"_src":"sub:sub_main"},
 {"tag":"🇫🇮 Helsinki","id":"$X","type":"hysteria2","server":"fi.example.com","server_port":8443,"_src":"sub:sub_main"},
 {"tag":"A node with a very long name that has to wrap on a narrow phone screen without scrolling sideways","id":"$L","type":"vless","server":"long.example.com","server_port":443,"_src":"sub:sub_main"},
 {"tag":"Picked node","id":"$D","type":"vless","server":"pick.example.com","server_port":443,"_src":"sub:sub_pick"},
 {"tag":"My own link","id":"$M","type":"vmess","server":"me.example.com","server_port":443,"_src":"manual"}
]
J
cat > "$SB/deferred.json" <<J
[ {"tag":"Home AmneziaWG","id":"$W","type":"awg","server":"home.example.com","port":51820,"reason":"engine_missing","_src":"awg"} ]
J
cat > "$SB/hidden.json" <<J
[ {"id":"$H","tag":"🇺🇸 Hidden one","type":"vless","server":"us.example.com","port":443,"src":"sub:sub_main"} ]
J
cat > "$SB/links.json" <<J
[ {"id":"$A","link":"vless://00000000-0000-4000-8000-000000000000@nl.example.com:443?security=tls&sni=nl.example.com#Amsterdam","src":"sub:sub_main"},
  {"id":"$M","link":"vmess://eyJ2IjoiMiIsInBzIjoiTXkgb3duIGxpbmsiLCJhZGQiOiJtZS5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwMCJ9","src":"manual"} ]
J
echo "[\"$B\"]" > "$SB/.dead_ids.json"
echo "{\"$A\":81,\"$X\":140,\"$L\":230,\"$D\":95,\"$M\":60}" > "$SB/.nodedelay.json"
cat > "$C/unlock.map.json" <<J
{"$A":{"youtube":true,"openai":true,"netflix":false,"instagram":true,"telegram":true,"google":true}}
J
cat > "$C/favorites.map.json" <<J
{"$M":{"tag":"My own link","link":"vmess://x","active":false,"type":"vmess","server":"me.example.com","port":443},
 "$F":{"tag":"🇬🇧 London (gone from the subscription)","link":"vless://00000000-0000-4000-8000-000000000000@uk.example.com:443#London","active":false,"type":"vless","server":"uk.example.com","port":443}}
J
chmod 600 "$C/favorites.map.json"
cat > "$C/subs.meta.json" <<J
{"sub_main":{"expire":$((NOW + 5 * 86400 + 3600)),"upload":1073741824,"download":9663676416,"total":10737418240,"title":"Main provider"}}
J
cat > "$SB/fetch_status.json" <<J
{"$U1":{"at":$((NOW - 600)),"result":"ok","nodes":5,"last_ok_at":$((NOW - 600))},
 "$U2":{"at":$((NOW - 7200)),"result":"failed","nodes":0,"last_ok_at":$((NOW - 86400))}}
J
echo '[]' > "$SB/awg_unreadable.json"

# a stand-in daemon (status: "running"; the rpcd methods find a daemon to signal)
mkdir -p /tmp/stand-daemon/usr/libexec/vpnpool
cp /work/tests/fakedaemon.sh /tmp/stand-daemon/usr/libexec/vpnpool/vpnpoold
if ! pgrep -f /tmp/stand-daemon/usr/libexec/vpnpool/vpnpoold >/dev/null 2>&1; then
	FAKED_LOG=/tmp/stand-daemon.signals setsid sh /tmp/stand-daemon/usr/libexec/vpnpool/vpnpoold >/dev/null 2>&1 < /dev/null &
fi
sleep 1
ubus call vpnpool status 2>/dev/null | jq -c '{running, subscriptions: (.subscriptions | length), nodes: (.nodes | length), favorites: (.favorites | length), hidden: (.hidden | length)}'
