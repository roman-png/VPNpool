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
	# Build yield rules: skip traffic already marked by coexisting proxies so we
	# don't double-intercept it. auto = detect podkop; plus any uci yield_mark.
	YIELD=""
	if [ "$COEXIST" != "off" ]; then
		if nft list table inet PodkopTable >/dev/null 2>&1; then
			YIELD="${YIELD}		meta mark & 0x100000 == 0x100000 return
"
		fi
		for m in $(uci -q get vpnpool.main.yield_mark 2>/dev/null); do
			YIELD="${YIELD}		meta mark & $m == $m return
"
		done
	fi

	# Per-client policy: build client sets + a rule that bypasses (exclude) or
	# restricts to (include) the listed clients. Two match keys:
	#   client     (IPv4)  -> @clients      (typed manually)
	#   client_dev (MAC)   -> @clients_mac  (picked by DHCP name; stable across renew)
	# A host is "listed" if its IP OR its MAC matches. MAC matching needs the L2 header,
	# present in prerouting on the (bridged) LAN.
	CL=$(uci -q get vpnpool.main.client 2>/dev/null | tr ' ' ',')
	CLD=$(uci -q get vpnpool.main.client_dev 2>/dev/null | tr ' ' ',')
	CLIENT_SET=""
	CLIENT_RULE=""
	if [ -n "$CL" ]; then
		CLIENT_SET="${CLIENT_SET}	set clients {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $CL }
	}
"
	fi
	if [ -n "$CLD" ]; then
		CLIENT_SET="${CLIENT_SET}	set clients_mac {
		type ether_addr
		elements = { $CLD }
	}
"
	fi
	if [ -n "$CL" ] || [ -n "$CLD" ]; then
		case "$CLIENT_MODE" in
			exclude)
				# bypass VPN for any listed client — return on either match.
				[ -n "$CL" ]  && CLIENT_RULE="${CLIENT_RULE}		ip saddr @clients return
"
				[ -n "$CLD" ] && CLIENT_RULE="${CLIENT_RULE}		ether saddr @clients_mac return
"
				;;
			include)
				# only listed clients use VPN — return (bypass) everyone NOT listed.
				# With both keys, a single rule ANDs the negations so we return only
				# when neither the IP nor the MAC is in its set.
				if [ -n "$CL" ] && [ -n "$CLD" ]; then
					CLIENT_RULE="		ip saddr != @clients ether saddr != @clients_mac return
"
				elif [ -n "$CL" ]; then
					CLIENT_RULE="		ip saddr != @clients return
"
				else
					CLIENT_RULE="		ether saddr != @clients_mac return
"
				fi
				;;
		esac
	fi

	# Extra marking rules (run after the default 80/443 marking, before tproxy):
	#  - DNS-leak guard: send LAN DNS to the tunnel (local dst already returned above)
	#  - kill-switch: in full-tunnel (exclude) mode mark EVERY port so nothing leaks
	#    past the VPN; if sing-box is down, marked traffic dead-ends at the lo table.
	EXTRA_MARK=""
	if [ "$DNS_PROTECT" = "1" ]; then
		EXTRA_MARK="${EXTRA_MARK}		iifname \"$LAN_IF\" meta l4proto { tcp, udp } th dport 53 meta mark set $FWMARK
"
	fi
	if [ "$KILLSWITCH" = "1" ] && [ "$MODE" = "exclude" ]; then
		EXTRA_MARK="${EXTRA_MARK}		iifname \"$LAN_IF\" meta l4proto tcp meta mark set $FWMARK
		iifname \"$LAN_IF\" meta l4proto udp meta mark set $FWMARK
"
	fi

	# Clean slate so `up` is idempotent: a table left by a crashed daemon would otherwise
	# make the re-declaration fail ("chain already exists") and leave routing half-applied.
	nft delete table inet vpnpool 2>/dev/null
	if ! nft -f - <<NFT
table inet vpnpool {
	set localv4 {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/3 }
	}
${CLIENT_SET}	chain prerouting {
		type filter hook prerouting priority -90; policy accept;
${YIELD}		ip daddr @localv4 return
${CLIENT_RULE}
		iifname "$LAN_IF" meta l4proto tcp th dport { 80, 443 } meta mark set $FWMARK
		iifname "$LAN_IF" meta l4proto udp th dport 443 meta mark set $FWMARK
${EXTRA_MARK}		meta mark & $FWMARK == $FWMARK meta l4proto tcp tproxy ip to 127.0.0.1:$TPROXY_PORT
		meta mark & $FWMARK == $FWMARK meta l4proto udp tproxy ip to 127.0.0.1:$TPROXY_PORT
	}
}
NFT
	then
		log "route.sh: nft failed to apply routing table — VPN routing is NOT active"
		nft delete table inet vpnpool 2>/dev/null
		exit 1
	fi
	ip route replace local 0.0.0.0/0 dev lo table "$RT_TABLE"
	ip rule add fwmark "${FWMARK}/${FWMARK}" lookup "$RT_TABLE" priority "$RT_PRIO" 2>/dev/null

	# IPv6 leak guard (fail-closed): drop LAN IPv6 to the internet so v6 traffic
	# can't bypass the v4 VPN. Local/ULA/link-local v6 stays allowed.
	if [ "$IPV6" = "block" ]; then
		nft -f - <<NFT6
table inet vpnpool {
	set localv6 {
		type ipv6_addr
		flags interval
		auto-merge
		elements = { ::1/128, ::/128, fc00::/7, fe80::/10, ff00::/8, 64:ff9b::/96 }
	}
	chain v6filter {
		type filter hook forward priority -90; policy accept;
		meta nfproto ipv6 iifname "$LAN_IF" ip6 daddr != @localv6 reject
	}
}
NFT6
		[ $? -eq 0 ] || log "route.sh: nft failed to apply IPv6 leak guard"
	fi
	;;
down)
	nft delete table inet vpnpool 2>/dev/null
	ip rule del fwmark "${FWMARK}/${FWMARK}" lookup "$RT_TABLE" priority "$RT_PRIO" 2>/dev/null
	ip route flush table "$RT_TABLE" 2>/dev/null
	;;
*)
	echo "usage: $0 up|down" >&2; exit 1 ;;
esac
