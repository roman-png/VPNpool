#!/bin/sh
# vpnpool adaptive routing: detect domains that are blocked for a DIRECT connection
# and auto-route them through the proxy. Candidates are the hosts of connections that
# currently egress DIRECT (clash /connections). Each host without a fresh verdict is tested
# direct-vs-proxy; if the DIRECT request fails while the PROXY request works, its base
# domain is added to routing.auto_domain and a reload applies it (generator emits
# auto_domain -> proxy).
#
# Verdict cache (/etc/vpnpool/adaptive.cache.json): {host: {"v":"ok"|"proxy","t":epoch}}.
# A verdict expires after adaptive_cache_ttl seconds (default 7 days) so a site that got
# blocked (or unblocked) later is re-tested; 1.x entries (bare strings) count as expired.
# Written once per run, only when it changed (flash wear).
#
# NOTE: assumes the router's own traffic is NOT tproxied (standard — tproxy is on LAN
# PREROUTING), so the direct test is genuinely direct.
. /usr/libexec/vpnpool/lib.sh

[ "$(uci -q get vpnpool.main.adaptive_routing)" = "1" ] || exit 0
TP=$(uci -q get vpnpool.main.test_port); [ -n "$TP" ] || TP=1605
CACHE=/etc/vpnpool/adaptive.cache.json
WORK="$SB_DATA/.adaptive.cache.json"
mkdir -p /etc/vpnpool "$SB_DATA"
jq -e 'type=="object"' "$CACHE" >/dev/null 2>&1 || echo '{}' > "$CACHE"
cp "$CACHE" "$WORK"
MAXNEW=$(uci -q get vpnpool.main.adaptive_max_per_run); case "$MAXNEW" in (*[!0-9]*|"") MAXNEW=8 ;; esac
TTL=$(uci -q get vpnpool.main.adaptive_cache_ttl); case "$TTL" in (*[!0-9]*|"") TTL=604800 ;; esac
NOW=$(date +%s)

CONN=$(curl -s -m4 "http://$CLASH_API/connections" 2>/dev/null)
[ -n "$CONN" ] || exit 0
# Hosts of DIRECT connections, without bare IPv4 addresses. No regex: OpenWrt's jq is built
# without oniguruma, so test()/match() abort the whole filter (the old filter made this
# feature a silent no-op). "only digits and dots" is checked on the code points instead.
HOSTS=$(echo "$CONN" | jq -r '
	(.connections // [])
	| map(select((.chains // []) | (index("proxy") | not)))
	| map(.metadata.host // "")
	| map(select(. != "" and ((explode | map(select((. < 48 or . > 57) and . != 46)) | length) > 0)))
	| unique | .[]' 2>/dev/null)
[ -n "$HOSTS" ] || exit 0

# Registrable ("base") domain: last two labels, or last THREE when the last two form a
# public suffix from this minimal list (multi-label suffixes common for our users; a full
# Public Suffix List does not fit a 16 MB router). Hosts on a suffix not listed here
# degrade to the old two-label rule.
PSL2=$(tr '\n' ' ' <<'EOF'
 co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk net.uk sch.uk nhs.uk
 com.au net.au org.au edu.au gov.au co.nz org.nz net.nz co.jp ne.jp or.jp ac.jp go.jp
 co.kr or.kr ne.kr com.cn net.cn org.cn gov.cn edu.cn com.hk com.tw com.sg com.my
 co.in net.in org.in co.id com.br net.br org.br com.ar com.mx com.tr org.tr net.tr
 co.za com.ua net.ua org.ua in.ua kiev.ua com.ru net.ru org.ru pp.ru msk.ru spb.ru
 com.kz org.kz com.by co.il org.il com.pl net.pl org.pl com.ng com.eg com.sa com.vn
 github.io blogspot.com appspot.com herokuapp.com cloudfront.net
EOF
)
base_domain() {   # $1=host
	local h l2 n
	h=$(printf '%s' "$1" | tr 'A-Z' 'a-z'); h=${h%.}
	n=$(printf '%s' "$h" | awk -F. '{print NF}')
	[ "$n" -ge 2 ] || { printf '%s' "$h"; return; }
	l2=$(printf '%s' "$h" | awk -F. '{printf "%s.%s", $(NF-1), $NF}')
	case "$PSL2" in
		*" $l2 "*)
			if [ "$n" -ge 3 ]; then printf '%s' "$h" | awk -F. '{printf "%s.%s.%s", $(NF-2), $(NF-1), $NF}'
			else printf '%s' "$h"; fi ;;
		*) printf '%s' "$l2" ;;
	esac
}

added=0
for host in $HOSTS; do
	[ "$added" -ge "$MAXNEW" ] && break
	[ -n "$host" ] || continue
	# a fresh verdict (object with t within TTL) -> skip
	fresh=$(jq -r --arg h "$host" --argjson now "$NOW" --argjson ttl "$TTL" \
		'(.[$h] // null) | if type=="object" and ((.t // 0) + $ttl) > $now then "y" else "" end' "$WORK" 2>/dev/null)
	[ -n "$fresh" ] && continue

	dcode=$(curl -s -o /dev/null -m4 -A 'Mozilla/5.0' -w '%{http_code}' "https://$host/" 2>/dev/null)
	verdict=ok
	case "$dcode" in
		2*|3*) verdict=ok ;;
		*)
			# blocked DIRECT — does it work through the proxy? If so, route it via proxy.
			pcode=$(curl -s -o /dev/null -m6 -A 'Mozilla/5.0' --proxy "socks5h://127.0.0.1:$TP" -w '%{http_code}' "https://$host/" 2>/dev/null)
			case "$pcode" in 2*|3*) verdict=proxy ;; *) verdict=ok ;; esac ;;
	esac

	jq --arg h "$host" --arg v "$verdict" --argjson t "$NOW" '.[$h]={v:$v, t:$t}' "$WORK" > "$WORK.tmp" 2>/dev/null \
		&& mv "$WORK.tmp" "$WORK"

	bd=$(base_domain "$host")
	[ -n "$bd" ] || continue
	case "$verdict" in
		proxy)
			if ! uci -q get vpnpool.routing.auto_domain | tr ' ' '\n' | grep -Fxq "$bd"; then
				uci add_list vpnpool.routing.auto_domain="$bd"
				added=$((added + 1))
				log "adaptive: $host blocked-direct -> route $bd via proxy"
			fi
			;;
	esac
done

# drop expired verdicts, then persist only if something changed
jq --argjson now "$NOW" --argjson ttl "$TTL" \
	'with_entries(select((.value|type)=="object" and ((.value.t // 0) + $ttl) > $now))' "$WORK" > "$WORK.tmp" 2>/dev/null \
	&& mv "$WORK.tmp" "$WORK"
persist_if_changed "$WORK" "$CACHE"
rm -f "$WORK" "$WORK.tmp"

if [ "$added" -gt 0 ]; then
	uci commit vpnpool
	# rebuild sing-box config so the new auto_domain go via the proxy
	signal_daemon USR1
	log "adaptive: added $added domain(s), reloading"
fi
exit 0
