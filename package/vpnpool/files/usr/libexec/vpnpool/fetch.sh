#!/bin/sh
# vpnpool: fetch every ENABLED subscription (uci sections "subscription", ROADMAP 9.1) trying
# MULTIPLE client User-Agents, detect the format of each response (base64 / sing-box JSON /
# plain link list), parse it, and keep the response that yields the MOST nodes. This makes the
# fetcher robust to subscription panels that serve different formats to different clients (and
# to the provider changing over time). All subscriptions are equal: each one has its own cache,
# its own expiry / quota / provider update interval (the panel's response headers) and its own
# "updated".
#
# Output: one decoded file per subscription in $SB_DATA/sources/s-<key>.raw (key = hash of the
# URL, lib.sh src_key). Cache: $CONF_DIR/sources_cache/s-<key>.raw, PER SUBSCRIPTION — one that
# fails this time is served from ITS OWN cached copy, so one dead subscription never drops its
# nodes while another one answers. A cached copy is rewritten only when its content changed
# (flash wear). URLs are logged masked (they carry the access token).
# Headers of the best response -> $CONF_DIR/subs.meta.json {<sub id>: {expire, upload, download,
# total, update_interval, title, web_page, support}} (rewritten only when it changed; a failed
# subscription keeps its last values). "Updated": $CONF_DIR/sources_cache/.ok-<sub id> (mtime,
# refreshed at most once a day) + fetch_status.json in RAM.
# Exit: 0 if every subscription has data (fresh or cached), 1 if none produced anything.
. /usr/libexec/vpnpool/lib.sh

mkdir -p "$SB_DATA"
SRCDIR="$SB_DATA/sources"
CACHEDIR="$CONF_DIR/sources_cache"
META="$CONF_DIR/subs.meta.json"
TAB=$(printf '\t')

# Client User-Agents to probe (space separated, no spaces inside a UA).
UAS=$(uci -q get vpnpool.main.probe_ua)
[ -n "$UAS" ] || UAS="$DEFAULT_UAS"

# Upper bound of one subscription's answer (uci fetch_max_kb, default 2048 KiB). curl stops a
# download whose announced size is above it; the size is checked again on what arrived.
MAXKB=$(uci -q get vpnpool.main.fetch_max_kb); case "$MAXKB" in ''|*[!0-9]*) MAXKB=2048 ;; esac
[ "$MAXKB" -ge 16 ] || MAXKB=2048
MAXB=$((MAXKB * 1024))

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

# The panel's headers of one response -> the subscription's meta JSON (jq here has no regex).
#   subscription-userinfo: upload=N; download=N; total=N; expire=EPOCH
#   profile-update-interval: <hours>      profile-title: <text> | base64:<b64>
#   profile-web-page-url / support-url: <url>
hdr_meta() {   # $1 = curl -D header dump
	jq -Rn '
		[inputs | rtrimstr("\r") | (index(":")) as $i | select($i != null and $i > 0)
			| {k: (.[:$i] | ascii_downcase), v: (.[$i + 1:] | ltrimstr(" ") | rtrimstr(" "))}]
		| (map({(.k): .v}) | add // {}) as $h
		| (($h["subscription-userinfo"] // "") | split(";") | map(ltrimstr(" ") | split("="))
			| map(select(length == 2) | {(.[0]): (.[1] | tonumber? // null)}) | add // {}) as $u
		| {expire: ($u.expire // null), upload: ($u.upload // null), download: ($u.download // null),
		   total: ($u.total // null),
		   update_interval: (($h["profile-update-interval"] // "") | tonumber? // null
		                     | if . == null then null else (. * 3600 | floor) end),
		   title: ($h["profile-title"] // null), web_page: ($h["profile-web-page-url"] // null),
		   support: ($h["support-url"] // null)}' "$1" 2>/dev/null
}

fetch_best() {   # $1=url $2=sub id $3=outfile
	url="$1"; sid="$2"; outfile="$3"
	best=-1; bestua=""
	rm -f "$SB_DATA/.hdr.$sid"
	for ua in $UAS; do
		curl -sfL --connect-timeout 5 -m 12 --max-filesize "$MAXB" -A "$ua" -D "$SB_DATA/h.tmp" -o "$SB_DATA/b.tmp" "$url" 2>/dev/null || continue
		sz=$(wc -c < "$SB_DATA/b.tmp" 2>/dev/null); [ "${sz:-0}" -lt 20 ] && continue
		# too big to parse safely in RAM (a public list of thousands of nodes on a 16 MB router):
		# refused like a dead answer — the subscription is served from its own cached copy
		if [ "${sz:-0}" -gt "$MAXB" ]; then
			log "fetch: $(mask_url "$url") answered ${sz} bytes, more than the limit ${MAXB} — not used"
			break
		fi
		normalize "$SB_DATA/b.tmp" > "$SB_DATA/n.tmp"
		cnt=$(ucode /usr/libexec/vpnpool/parser.uc "$SB_DATA/n.tmp" 2>/dev/null | jq 'length' 2>/dev/null)
		[ -n "$cnt" ] || cnt=0
		if [ "$cnt" -gt "$best" ]; then
			best="$cnt"; bestua="$ua"; cp "$SB_DATA/n.tmp" "$outfile"
			cp "$SB_DATA/h.tmp" "$SB_DATA/.hdr.$sid" 2>/dev/null
		fi
		# Stop at the FIRST User-Agent that yields usable nodes — no point hammering the
		# panel with every remaining UA once we already have a working response (it just
		# adds load on the provider and slows the fetch). The multi-UA sweep only matters
		# when the earlier UAs returned nothing; we keep trying until one works, then break.
		[ "$cnt" -ge 1 ] && break
	done
	rm -f "$SB_DATA/h.tmp" "$SB_DATA/b.tmp" "$SB_DATA/n.tmp"
	if [ "$best" -ge 1 ]; then
		log "fetch: $(mask_url "$url") -> $best nodes (best UA: $bestua)"
		return 0
	fi
	rm -f "$outfile" "$SB_DATA/.hdr.$sid"
	log "fetch: $(mask_url "$url") -> no usable nodes from any client"
	return 1
}

# One subscription: fresh copy on success (cached only if it changed), else its own cached copy.
# Sets GOT (1 = it has data now) and FRESH (1 = fetched now).
fetch_source() {   # $1=url $2=sub id
	local key out cached age_days mt now
	key=$(src_key "$1"); out="$SRCDIR/s-$key.raw"; cached="$CACHEDIR/s-$key.raw"
	GOT=0; FRESH=0
	if fetch_best "$1" "$2" "$out"; then
		GOT=1; FRESH=1
		printf '%s\t%s\tok\t%s\n' "$1" "$2" "$best" >> "$FSTAT_TSV"
		mkdir -p "$CACHEDIR"; persist_if_changed "$out" "$cached"
		# "updated" marker (holds the URL key: an edited URL gets a fresh one at once); its mtime
		# is refreshed at most once a day (flash wear)
		mt=$(date -r "$CACHEDIR/.ok-$2" +%s 2>/dev/null || echo 0); now=$(date +%s)
		if [ $(( now - mt )) -ge 86400 ] || [ "$(cat "$CACHEDIR/.ok-$2" 2>/dev/null)" != "$key" ]; then
			echo "$key" > "$CACHEDIR/.ok-$2" 2>/dev/null
		fi
		return 0
	fi
	if [ -s "$cached" ]; then
		cp "$cached" "$out"; GOT=1
		# Warn (log + Telegram) when serving a STALE cache: nodes may be long dead and the
		# subscription likely expired, but we keep the tunnel up on the last-known set.
		age_days=0; now=$(date +%s)
		mt=$(date -r "$CACHEDIR/.ok-$2" +%s 2>/dev/null || date -r "$cached" +%s 2>/dev/null)
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

# Per-subscription result of this run for the UI (status.uc -> "subscriptions"), in RAM:
#   $SB_DATA/fetch_status.json  {"<url>": {id, at, result: ok|cached|failed|interrupted, nodes,
#                                last_ok_at}}   (last_ok_at survives a failed run)
# Holds the full URLs (like the uci config); status.uc masks them before they leave the router.
FSTAT="$SB_DATA/fetch_status.json"
FSTAT_TSV="$SB_DATA/.fetch_status.tsv"
write_fetch_status() {
	[ -f "$FSTAT" ] || echo '{}' > "$FSTAT"
	jq -Rn --argjson at "$(date +%s)" --slurpfile prev "$FSTAT" '
		($prev[0] // {}) as $p
		| reduce (inputs | split("\t") | select(length >= 4)) as $r ({};
			.[$r[0]] = {id: $r[1], at: $at, result: $r[2], nodes: ($r[3] | tonumber? // 0),
			            last_ok_at: (if $r[2] == "ok" then $at else ($p[$r[0]].last_ok_at // null) end)})' \
		"$FSTAT_TSV" 2>/dev/null | write_atomic "$FSTAT"
	rm -f "$FSTAT_TSV"
}

# The meta of every configured subscription: this run's headers for the ones fetched now, the
# previous values for the rest; subscriptions no longer configured are dropped.
write_meta() {
	local sid en mode url m all
	[ -f "$META" ] || echo '{}' > "$META"
	all=$(jq -c '.' "$META" 2>/dev/null); [ -n "$all" ] || all='{}'
	all=$(printf '%s' "$all" | jq -c --argjson ids "$(cut -f1 "$SB_DATA/.subs" | jq -R . | jq -sc .)" 'with_entries(select(.key as $k | $ids | index($k) != null))')
	while IFS="$TAB" read -r sid en mode url; do
		[ -f "$SB_DATA/.hdr.$sid" ] || continue
		m=$(hdr_meta "$SB_DATA/.hdr.$sid"); rm -f "$SB_DATA/.hdr.$sid"
		[ -n "$m" ] && all=$(printf '%s' "$all" | jq -c --arg s "$sid" --argjson m "$m" '.[$s] = $m')
	done < "$SB_DATA/.subs"
	printf '%s\n' "$all" > "$SB_DATA/.meta.new"
	persist_if_changed "$SB_DATA/.meta.new" "$META"
	rm -f "$SB_DATA/.meta.new"
}

rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"; : > "$FSTAT_TSV"
ucode "$MODEL" subs > "$SB_DATA/.subs" 2>/dev/null || : > "$SB_DATA/.subs"
# Killed mid-run (the daemon stops / restarts): every subscription not answered yet is recorded as
# "interrupted" (written atomically), so status never shows an old "ok" for this run.
# fetch.sh holds no lock of its own.
on_signal() {
	local sid en mode url
	trap - INT TERM HUP
	while IFS="$TAB" read -r sid en mode url; do
		[ "$en" = 1 ] || continue
		cut -f1 "$FSTAT_TSV" 2>/dev/null | grep -Fxq -- "$url" && continue
		printf '%s\t%s\tinterrupted\t0\n' "$url" "$sid" >> "$FSTAT_TSV"
	done < "$SB_DATA/.subs"
	write_fetch_status
	rm -f "$SB_DATA/h.tmp" "$SB_DATA/b.tmp" "$SB_DATA/n.tmp" "$SB_DATA"/.hdr.*
	exit 143
}
trap on_signal INT TERM HUP
nsrc=0; ngot=0; nfresh=0
# a file, not a pipe: the loop must run in THIS shell to count (and to be interruptible)
while IFS="$TAB" read -r sid en mode url; do
	[ "$en" = 1 ] && [ -n "$url" ] || continue
	fetch_source "$url" "$sid"
	nsrc=$((nsrc + 1)); ngot=$((ngot + GOT)); nfresh=$((nfresh + FRESH))
done < "$SB_DATA/.subs"

# Forget cached copies (and "updated" markers) of subscriptions that are no longer configured;
# a switched-off subscription keeps its copy (switching it on again starts from it).
if [ -d "$CACHEDIR" ]; then
	while IFS="$TAB" read -r sid en mode url; do src_key "$url"; echo; done < "$SB_DATA/.subs" | grep . > "$SB_DATA/.keys"
	for f in "$CACHEDIR"/s-*.raw; do
		[ -f "$f" ] || continue
		k=${f##*/s-}; k=${k%.raw}
		grep -qx "$k" "$SB_DATA/.keys" || rm -f "$f"
	done
	for f in "$CACHEDIR"/.ok-*; do
		[ -f "$f" ] || continue
		k=${f##*/.ok-}
		cut -f1 "$SB_DATA/.subs" | grep -qx -- "$k" || rm -f "$f"
	done
	rm -f "$SB_DATA/.keys"
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
# Record the attempt (any outcome): the daemon's start-up retry loop and restarts use it to
# avoid re-downloading the subscriptions more often than INTERVAL_MIN (panels rate-limit).
echo "$(date +%s) $(sources_sig)" | write_atomic "$FETCH_STAMP"
trap - INT TERM HUP
write_fetch_status
write_meta
rm -f "$SB_DATA/.subs"

log "fetch: $nfresh/$nsrc subscription(s) fetched, $ngot with data"
[ "$nsrc" -eq 0 ] && exit 0      # no subscriptions configured: manual nodes only
[ "$ngot" -gt 0 ] && exit 0
exit 1
