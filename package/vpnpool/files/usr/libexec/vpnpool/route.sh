#!/bin/sh
# vpnpool: whole-LAN selective tproxy routing that coexists with podkop.
#   up   - install nft table + ip rule + policy route
#   down - remove everything we added
#
# Coexistence: podkop marks at 'priority mangle' (-150) and tproxy at 'dstnat'
# (-100). Our chain runs LATER at priority -90 and YIELDS to podkop (its mark
# 0x100000 -> return). We also never touch private ranges or podkop's fakeip
# range (198.18.0.0/15). Selective decision itself is done by sing-box via SNI
# sniffing: only our listed domains go to "proxy", the rest go "direct".
. /usr/libexec/vpnpool/lib.sh

case "$1" in
up)
	ip route replace local 0.0.0.0/0 dev lo table "$RT_TABLE"
	ip rule add fwmark "${FWMARK}/${FWMARK}" lookup "$RT_TABLE" priority "$RT_PRIO" 2>/dev/null
	nft -f - <<NFT
table inet vpnpool {
	set localv4 {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/3 }
	}
	chain prerouting {
		type filter hook prerouting priority -90; policy accept;
		meta mark & 0x100000 == 0x100000 return
		ip daddr @localv4 return
		iifname "$LAN_IF" meta l4proto tcp th dport { 80, 443 } meta mark set $FWMARK
		iifname "$LAN_IF" meta l4proto udp th dport 443 meta mark set $FWMARK
		meta mark & $FWMARK == $FWMARK meta l4proto tcp tproxy ip to 127.0.0.1:$TPROXY_PORT
		meta mark & $FWMARK == $FWMARK meta l4proto udp tproxy ip to 127.0.0.1:$TPROXY_PORT
	}
}
NFT
	;;
down)
	nft delete table inet vpnpool 2>/dev/null
	ip rule del fwmark "${FWMARK}/${FWMARK}" lookup "$RT_TABLE" priority "$RT_PRIO" 2>/dev/null
	ip route flush table "$RT_TABLE" 2>/dev/null
	;;
*)
	echo "usage: $0 up|down" >&2; exit 1 ;;
esac
