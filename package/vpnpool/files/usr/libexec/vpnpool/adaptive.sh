#!/bin/sh
# vpnpool adaptive routing: detect domains that are blocked for a DIRECT connection
# and auto-route them through the proxy. Candidates are the hosts of connections that
# currently egress DIRECT (clash /connections). Each NEW host is tested direct-vs-proxy;
# if the DIRECT request fails while the PROXY request works, its base domain is added to
# routing.auto_domain and a reload applies it (generator emits auto_domain -> proxy).
#
# NOTE: assumes the router's own traffic is NOT tproxied (standard — tproxy is on LAN
# PREROUTING), so the direct test is genuinely direct.
. /usr/libexec/vpnpool/lib.sh

[ "$(uci -q get vpnpool.main.adaptive_routing)" = "1" ] || exit 0
TP=$(uci -q get vpnpool.main.test_port); [ -n "$TP" ] || TP=1605
CACHE=/etc/vpnpool/adaptive.cache.json
mkdir -p /etc/vpnpool; [ -f "$CACHE" ] || echo '{}' > "$CACHE"
MAXNEW=$(uci -q get vpnpool.main.adaptive_max_per_run); case "$MAXNEW" in (*[!0-9]*|"") MAXNEW=8 ;; esac

CONN=$(curl -s -m4 "http://$CLASH_API/connections" 2>/dev/null)
[ -n "$CONN" ] || exit 0
HOSTS=$(echo "$CONN" | jq -r '
	(.connections // [])
	| map(select((.chains // []) | (index("proxy") | not)))
	| map(.metadata.host // "")
	| map(select(. != "" and (test("^[0-9.]+$") | not)))
	| unique | .[]' 2>/dev/null)
[ -n "$HOSTS" ] || exit 0

base_domain() {   # naive registrable domain: last two labels
	echo "$1" | awk -F. '{ if (NF>=2) printf "%s.%s", $(NF-1), $NF; else printf "%s", $0 }'
}

added=0
for host in $HOSTS; do
	[ "$added" -ge "$MAXNEW" ] && break
	[ -n "$host" ] || continue
	seen=$(jq -r --arg h "$host" '.[$h] // ""' "$CACHE" 2>/dev/null)
	[ -n "$seen" ] && continue

	dcode=$(curl -s -o /dev/null -m4 -A 'Mozilla/5.0' -w '%{http_code}' "https://$host/" 2>/dev/null)
	verdict=ok
	case "$dcode" in
		2*|3*) verdict=ok ;;
		*)
			pcode=$(curl -s -o /dev/null -m6 -A 'Mozilla/5.0' --proxy "socks5h://127.0.0.1:$TP" -w '%{http_code}' "https://$host/" 2>/dev/null)
			case "$pcode" in 2*|3*) verdict=blocked ;; *) verdict=ok ;; esac ;;
	esac

	jq --arg h "$host" --arg v "$verdict" '.[$h]=$v' "$CACHE" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE"

	if [ "$verdict" = blocked ]; then
		bd=$(base_domain "$host")
		if [ -n "$bd" ] && ! uci -q get vpnpool.routing.auto_domain | tr ' ' '\n' | grep -Fxq "$bd"; then
			uci add_list vpnpool.routing.auto_domain="$bd"
			added=$((added + 1))
			log "adaptive: $host blocked-direct -> route $bd via proxy"
		fi
	fi
done

if [ "$added" -gt 0 ]; then
	uci commit vpnpool
	kill -USR1 "$(cat /var/run/vpnpool.pid 2>/dev/null)" 2>/dev/null
	log "adaptive: added $added domain(s), reloading"
fi
exit 0
