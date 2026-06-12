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
# Smart bypass: if zapret is installed AND smart_bypass is on, the classifier becomes
# 3-way — for a blocked-direct host it first tries whether a DIRECT zapret desync fixes
# it (cheap, survives throttling); only if desync can't (i.e. a geo-block) does it fall
# back to routing the domain through the proxy. Off => classic 2-way (direct vs proxy).
ZAPRET=0
[ "$(uci -q get vpnpool.main.smart_bypass)" = 1 ] && [ -x /etc/init.d/zapret ] \
	&& uci -q get zapret.config >/dev/null 2>&1 && ZAPRET=1

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

# Probe whether a DIRECT zapret desync makes a host reachable: temporarily add it to
# zapret's user hostlist, reload nfqws's lists via SIGHUP (cheap, no nft rebuild),
# retest the DIRECT request, then remove the temp line. Returns 0 if desync fixed it.
probe_desync() {
	UH=/opt/zapret/ipset/zapret-hosts-user.txt
	[ -f "$UH" ] || : > "$UH"
	echo "$1" >> "$UH"
	# nfqws auto-reloads its hostlists on file mtime change (no signal — it has no
	# SIGHUP handler, so kill -HUP would KILL it). Give it a few seconds to pick up.
	sleep 5
	c=$(curl -s -o /dev/null -m6 -A 'Mozilla/5.0' -w '%{http_code}' "https://$1/" 2>/dev/null)
	grep -vxF "$1" "$UH" > "$UH.t" 2>/dev/null && mv "$UH.t" "$UH"
	case "$c" in 2*|3*) return 0 ;; *) return 1 ;; esac
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
			# 3-way: if zapret is available, try DIRECT desync first (cheap, survives
			# throttling); only escalate to the proxy when desync can't fix it (geo-block).
			if [ "$ZAPRET" = 1 ] && probe_desync "$host"; then
				verdict=desync
			else
				pcode=$(curl -s -o /dev/null -m6 -A 'Mozilla/5.0' --proxy "socks5h://127.0.0.1:$TP" -w '%{http_code}' "https://$host/" 2>/dev/null)
				case "$pcode" in 2*|3*) verdict=proxy ;; *) verdict=ok ;; esac
			fi ;;
	esac

	jq --arg h "$host" --arg v "$verdict" '.[$h]=$v' "$CACHE" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE"

	bd=$(base_domain "$host")
	[ -n "$bd" ] || continue
	case "$verdict" in
		desync)
			if ! uci -q get vpnpool.routing.desync_domain | tr ' ' '\n' | grep -Fxq "$bd"; then
				uci add_list vpnpool.routing.desync_domain="$bd"
				added=$((added + 1)); desync_added=1
				log "adaptive: $host fixed by desync -> $bd direct (zapret)"
			fi
			;;
		proxy)
			if ! uci -q get vpnpool.routing.auto_domain | tr ' ' '\n' | grep -Fxq "$bd"; then
				uci add_list vpnpool.routing.auto_domain="$bd"
				added=$((added + 1))
				log "adaptive: $host blocked-direct -> route $bd via proxy"
			fi
			;;
	esac
done

if [ "$added" -gt 0 ]; then
	uci commit vpnpool
	# render the new desync set into zapret's hostlist (SIGHUP reload, no nft bounce)
	[ "${desync_added:-0}" = 1 ] && /usr/libexec/vpnpool/smartbypass.sh synclist >/dev/null 2>&1
	# rebuild sing-box config so desync_domain go DIRECT and auto_domain via proxy
	kill -USR1 "$(cat /var/run/vpnpool.pid 2>/dev/null)" 2>/dev/null
	log "adaptive: added $added domain(s), reloading"
fi
exit 0
