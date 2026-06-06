#!/bin/sh
# vpnpool: fetch every source trying MULTIPLE client User-Agents, detect the
# format of each response (base64 / sing-box JSON / plain link list), parse it,
# and keep the response that yields the MOST nodes. This makes the fetcher
# robust to subscription panels that serve different formats to different
# clients (and to the provider changing over time).
#
# Output: one decoded file per source in $SB_DATA/sources/NNN.raw, cached to
#         $CONF_DIR/sources_cache for offline fallback.
. /usr/libexec/vpnpool/lib.sh

mkdir -p "$SB_DATA"
SRCDIR="$SB_DATA/sources"
CACHEDIR="$CONF_DIR/sources_cache"

# Client User-Agents to probe (space separated, no spaces inside a UA).
UAS=$(uci -q get vpnpool.main.probe_ua)
[ -n "$UAS" ] || UAS="v2rayNG/1.9.5 v2rayN/6.45 Happ/1.0 sing-box/1.12 clash-meta/1.18 Streisand Hiddify/2.0 Shadowrocket/2.2 Mozilla/5.0"

normalize() {   # $1 = raw body file -> decoded text on stdout
	c=$(head -c 1 "$1" 2>/dev/null)
	case "$c" in
		'{'|'[') cat "$1" ;;                                   # JSON
		*)
			if head -c 8 "$1" 2>/dev/null | grep -q '://'; then
				cat "$1"                                       # plain link list
			else
				tr -d '\r\n' < "$1" | base64 -d 2>/dev/null || cat "$1"   # base64 blob
			fi ;;
	esac
}

fetch_best() {   # $1=url $2=primary(0/1) $3=outfile
	url="$1"; primary="$2"; outfile="$3"
	best=-1; bestua=""
	for ua in $UAS; do
		curl -sfL -m 20 -A "$ua" -D "$SB_DATA/h.tmp" -o "$SB_DATA/b.tmp" "$url" 2>/dev/null || continue
		sz=$(wc -c < "$SB_DATA/b.tmp" 2>/dev/null); [ "${sz:-0}" -lt 20 ] && continue
		normalize "$SB_DATA/b.tmp" > "$SB_DATA/n.tmp"
		cnt=$(ucode /usr/libexec/vpnpool/parser.uc "$SB_DATA/n.tmp" 2>/dev/null | jq 'length' 2>/dev/null)
		[ -n "$cnt" ] || cnt=0
		if [ "$cnt" -gt "$best" ]; then
			best="$cnt"; bestua="$ua"; cp "$SB_DATA/n.tmp" "$outfile"
			if [ "$primary" = "1" ]; then
				EXP=$(grep -i '^subscription-userinfo:' "$SB_DATA/h.tmp" 2>/dev/null | grep -o 'expire=[0-9]*' | head -1 | cut -d= -f2)
				[ -n "$EXP" ] && echo "$EXP" > "$CONF_DIR/sub.expire"
			fi
		fi
	done
	if [ "$best" -ge 1 ]; then
		log "fetch: $url -> $best nodes (best UA: $bestua)"
		return 0
	fi
	log "fetch: $url -> no usable nodes from any client"
	return 1
}

rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
n=0; ok=0
if [ -n "$SUB_URL" ]; then
	fetch_best "$SUB_URL" 1 "$SRCDIR/$(printf '%03d' "$n").raw" && ok=1
	n=$((n + 1))
fi
for s in $(uci -q get vpnpool.main.source 2>/dev/null); do
	fetch_best "$s" 0 "$SRCDIR/$(printf '%03d' "$n").raw" && ok=1
	n=$((n + 1))
done

if [ "$ok" = "1" ]; then
	rm -rf "$CACHEDIR"; cp -a "$SRCDIR" "$CACHEDIR" 2>/dev/null
	exit 0
fi

log "fetch: all sources failed, trying cache"
if [ -d "$CACHEDIR" ]; then
	rm -rf "$SRCDIR"; cp -a "$CACHEDIR" "$SRCDIR"
	exit 0
fi
exit 1
