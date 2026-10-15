#!/bin/sh
# vpnpool: fetch every source trying MULTIPLE client User-Agents, detect the
# format of each response (base64 / sing-box JSON / plain link list), parse it,
# and keep the response that yields the MOST nodes. This makes the fetcher
# robust to subscription panels that serve different formats to different
# clients (and to the provider changing over time).
#
# Output: one decoded file per source in $SB_DATA/sources/s-<key>.raw (key = hash of the
# source URL). Cache: $CONF_DIR/sources_cache/s-<key>.raw, PER SOURCE — a source that fails
# this time is served from ITS OWN cached copy, so one dead subscription never drops its
# nodes while another one answers. A cached copy is rewritten only when its content
# changed (flash wear). URLs are logged masked (they carry the access token).
# Exit: 0 if every source has data (fresh or cached), 1 if no source produced anything.
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
				# base64 blob: if it isn't valid base64, base64 -d exits early and
				# tr would SIGPIPE — silence tr's stderr too, then fall back to raw.
				tr -d '\r\n' < "$1" 2>/dev/null | base64 -d 2>/dev/null || cat "$1"
			fi ;;
	esac
}

src_key() { printf '%s' "$1" | md5sum | cut -c1-12; }

fetch_best() {   # $1=url $2=primary(0/1) $3=outfile
	url="$1"; primary="$2"; outfile="$3"
	best=-1; bestua=""
	for ua in $UAS; do
		curl -sfL --connect-timeout 5 -m 12 -A "$ua" -D "$SB_DATA/h.tmp" -o "$SB_DATA/b.tmp" "$url" 2>/dev/null || continue
		sz=$(wc -c < "$SB_DATA/b.tmp" 2>/dev/null); [ "${sz:-0}" -lt 20 ] && continue
		normalize "$SB_DATA/b.tmp" > "$SB_DATA/n.tmp"
		cnt=$(ucode /usr/libexec/vpnpool/parser.uc "$SB_DATA/n.tmp" 2>/dev/null | jq 'length' 2>/dev/null)
		[ -n "$cnt" ] || cnt=0
		if [ "$cnt" -gt "$best" ]; then
			best="$cnt"; bestua="$ua"; cp "$SB_DATA/n.tmp" "$outfile"
			if [ "$primary" = "1" ]; then
				UINFO=$(grep -i '^subscription-userinfo:' "$SB_DATA/h.tmp" 2>/dev/null | head -1); EXP=$(echo "$UINFO" | grep -o 'expire=[0-9]*' | head -1 | cut -d= -f2)
				UP=$(echo "$UINFO" | grep -o 'upload=[0-9]*' | head -1 | cut -d= -f2); DN=$(echo "$UINFO" | grep -o 'download=[0-9]*' | head -1 | cut -d= -f2); TOT=$(echo "$UINFO" | grep -o 'total=[0-9]*' | head -1 | cut -d= -f2)
				if [ -n "$TOT" ] && [ "$TOT" -gt 0 ] 2>/dev/null; then
					echo "${UP:-0} ${DN:-0} ${TOT}" > "$SB_DATA/usage.tmp"; persist_if_changed "$SB_DATA/usage.tmp" "$CONF_DIR/sub.usage"
				fi
				if [ -n "$EXP" ]; then
					echo "$EXP" > "$SB_DATA/expire.tmp"; persist_if_changed "$SB_DATA/expire.tmp" "$CONF_DIR/sub.expire"
				fi
			fi
		fi
		# Stop at the FIRST User-Agent that yields usable nodes — no point hammering the
		# panel with every remaining UA once we already have a working response (it just
		# adds load on the provider and slows the fetch). The multi-UA sweep only matters
		# when the earlier UAs returned nothing; we keep trying until one works, then break.
		[ "$cnt" -ge 1 ] && break
	done
	rm -f "$SB_DATA/h.tmp" "$SB_DATA/b.tmp" "$SB_DATA/n.tmp" "$SB_DATA/usage.tmp" "$SB_DATA/expire.tmp"
	if [ "$best" -ge 1 ]; then
		log "fetch: $(mask_url "$url") -> $best nodes (best UA: $bestua)"
		return 0
	fi
	rm -f "$outfile"
	log "fetch: $(mask_url "$url") -> no usable nodes from any client"
	return 1
}

# One source: fresh copy on success (cached only if it changed), else its own cached copy.
# Sets GOT (1 = this source has data now) and FRESH (1 = fetched now).
fetch_source() {   # $1=url $2=primary(0/1)
	local key out cached age_days mt now
	key=$(src_key "$1"); out="$SRCDIR/s-$key.raw"; cached="$CACHEDIR/s-$key.raw"
	GOT=0; FRESH=0
	echo "$key" >> "$SRCDIR/.keys"
	if fetch_best "$1" "$2" "$out"; then
		GOT=1; FRESH=1
		printf '%s\t%s\tok\t%s\n' "$1" "$2" "$best" >> "$FSTAT_TSV"
		mkdir -p "$CACHEDIR"; persist_if_changed "$out" "$cached"
		# age marker for the stale-cache warning; refreshed at most once a day (flash wear)
		mt=$(date -r "$CACHEDIR/.ok-$key" +%s 2>/dev/null || echo 0); now=$(date +%s)
		[ $(( now - mt )) -ge 86400 ] && touch "$CACHEDIR/.ok-$key" 2>/dev/null
		return 0
	fi
	if [ -s "$cached" ]; then
		cp "$cached" "$out"; GOT=1
		# Warn (log + Telegram) when serving a STALE cache: nodes may be long dead and the
		# subscription likely expired, but we keep the tunnel up on the last-known set.
		age_days=0; now=$(date +%s)
		mt=$(date -r "$CACHEDIR/.ok-$key" +%s 2>/dev/null || date -r "$cached" +%s 2>/dev/null)
		[ -n "$mt" ] && age_days=$(( (now - mt) / 86400 ))
		log "fetch: $(mask_url "$1") unreachable — using its cached copy (~${age_days}d old)"
		if [ "$age_days" -ge 3 ]; then
			tg_notify "⚠️ vpnpool: подписка $(mask_url "$1") недоступна, работаю на сохранённой копии (~${age_days} дн.) — узлы могут не работать"
		fi
		printf '%s\t%s\tcached\t0\n' "$1" "$2" >> "$FSTAT_TSV"
		return 1
	fi
	printf '%s\t%s\tfailed\t0\n' "$1" "$2" >> "$FSTAT_TSV"
	return 1
}

# Per-source result of this run for the UI (status.sh -> "subscriptions"), in RAM:
#   $SB_DATA/fetch_status.json  {"<url>": {at, result: ok|cached|failed, nodes, primary,
#                                last_ok_at}}   (last_ok_at survives a failed run)
# Holds the full URLs (like the uci config); status.sh masks them before they leave the router.
FSTAT="$SB_DATA/fetch_status.json"
FSTAT_TSV="$SB_DATA/.fetch_status.tsv"
write_fetch_status() {
	[ -f "$FSTAT" ] || echo '{}' > "$FSTAT"
	jq -Rn --argjson at "$(date +%s)" --slurpfile prev "$FSTAT" '
		($prev[0] // {}) as $p
		| reduce (inputs | split("\t") | select(length >= 4)) as $r ({};
			.[$r[0]] = {at: $at, result: $r[2], nodes: ($r[3] | tonumber? // 0), primary: ($r[1] == "1"),
			            last_ok_at: (if $r[2] == "ok" then $at else ($p[$r[0]].last_ok_at // null) end)})' \
		"$FSTAT_TSV" 2>/dev/null | write_atomic "$FSTAT"
	rm -f "$FSTAT_TSV"
}

rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"; : > "$SRCDIR/.keys"; : > "$FSTAT_TSV"
nsrc=0; ngot=0; nfresh=0
if [ -n "$SUB_URL" ]; then
	fetch_source "$SUB_URL" 1
	nsrc=$((nsrc + 1)); ngot=$((ngot + GOT)); nfresh=$((nfresh + FRESH))
fi

# Extra FULL subscriptions (uci list extra_sub): bulk-merged into the pool like the
# primary, each into its own file (build.sh merges every *.raw). Quota/expiry are
# only taken from the PRIMARY subscription (primary=0 here). URLs have no spaces, so a
# plain `uci get` list read is safe.
for esub in $(uci -q get vpnpool.main.extra_sub); do
	[ -n "$esub" ] || continue
	fetch_source "$esub" 0
	nsrc=$((nsrc + 1)); ngot=$((ngot + GOT)); nfresh=$((nfresh + FRESH))
done
# NOTE: extra `source` URLs are NOT bulk-merged — a public list can carry hundreds of
# nodes and flood the pool. They are "probe-only": the UI fetches a source, the user picks
# specific nodes, and those are stored as `imported_node` links (merged in build.sh).

# Forget cached copies of sources that are no longer configured.
if [ -d "$CACHEDIR" ]; then
	for f in "$CACHEDIR"/s-*.raw; do
		[ -f "$f" ] || continue
		k=${f##*/s-}; k=${k%.raw}
		grep -qx "$k" "$SRCDIR/.keys" || rm -f "$f" "$CACHEDIR/.ok-$k"
	done
	# 1.x cache layout (NNN.raw, all-or-nothing): use it only when nothing else is available
	# (first fetch after an upgrade while every source is down), drop it once we have data.
	if [ "$ngot" -eq 0 ] && [ "$nsrc" -gt 0 ]; then
		for f in "$CACHEDIR"/[0-9][0-9][0-9].raw; do
			[ -f "$f" ] && cp "$f" "$SRCDIR/" && ngot=1
		done
		[ "$ngot" -gt 0 ] && log "fetch: every source unreachable — using the cached copy from the previous version"
	else
		rm -f "$CACHEDIR"/[0-9][0-9][0-9].raw
	fi
fi
rm -f "$SRCDIR/.keys"
# Record the attempt (any outcome): the daemon's start-up retry loop and restarts use it to
# avoid re-downloading the subscriptions more often than INTERVAL_MIN (panels rate-limit).
echo "$(date +%s) $(sources_sig)" | write_atomic "$FETCH_STAMP"
write_fetch_status

log "fetch: $nfresh/$nsrc source(s) fetched, $ngot with data"
[ "$nsrc" -eq 0 ] && exit 0      # no subscriptions configured: manual/imported nodes only
[ "$ngot" -gt 0 ] && exit 0
exit 1
