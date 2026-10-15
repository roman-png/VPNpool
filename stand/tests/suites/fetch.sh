# suite: fetch — fetch.sh with partially failing sources (sourced by run.sh)
# Known defect (ROADMAP 2.5): the cache fallback is all-or-nothing. If the PRIMARY
# subscription fails but an extra one answers, ok=1 -> the cache is REPLACED by the extra's
# file only -> the primary's nodes vanish from the pool until it answers again.

FETCH=/usr/libexec/vpnpool/fetch.sh
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
FXF="$T_STATE/fetch"; mkdir -p "$FXF"
PRI='https://sub.example.com/sub/SECRETTOKEN123'
EXT='https://extra.example.com/list'
printf 'vless://%s@203.0.113.61:443?security=tls&sni=a.example#Pri1\nvless://%s@203.0.113.62:443?security=tls&sni=a.example#Pri2\n' "$U" "$U" | base64 -w0 > "$FXF/primary.b64"
printf 'vless://%s@203.0.113.63:443?security=tls&sni=a.example#Ext1\n' "$U" > "$FXF/extra.txt"
printf 'HTTP/1.1 200 OK\r\nsubscription-userinfo: upload=1; download=2; total=1000; expire=1893456000\r\n\r\n' > "$FXF/primary.hdr"

fetch_setup() {   # <primary code> <extra code>
	mock_on
	mock_rule "GET $PRI" "$1" "$FXF/primary.b64" "$FXF/primary.hdr"
	mock_rule "GET $EXT" "$2" "$FXF/extra.txt"
}
pool_tags() {   # tags the build would see from the fetched sources
	cat /tmp/vpnpool/sources/*.raw 2>/dev/null > "$FXF/all.txt"
	for f in /tmp/vpnpool/sources/*.raw; do [ -f "$f" ] && ucode /usr/libexec/vpnpool/parser.uc "$f"; done 2>/dev/null \
		| jq -sc 'add // [] | map(.tag) | sort' 2>/dev/null
}

reset_state
uci set vpnpool.main.subscription_url="$PRI"
uci add_list vpnpool.main.extra_sub="$EXT"
uci commit vpnpool

# ---- positive control: both sources answer ----
fetch_setup 200 200
sh "$FETCH" > "$FXF/log1" 2>&1; FRC=$?
begin "fetch/all-sources-ok"
expect_eq "exit code" "$FRC" 0
expect_eq "pool = primary + extra" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
expect_eq "expiry from subscription-userinfo" "$(cat /etc/vpnpool/sub.expire 2>/dev/null)" 1893456000
expect_eq "quota from subscription-userinfo" "$(cat /etc/vpnpool/sub.usage 2>/dev/null)" "1 2 1000"
expect_true "cache written" [ -d /etc/vpnpool/sources_cache ]
end

# ---- primary 500, extra 200: the primary's nodes must stay (from cache) ----
fetch_setup 500 200
sh "$FETCH" > "$FXF/log2" 2>&1; FRC=$?
begin "fetch/primary-fails-extra-ok-keeps-primary-nodes"
expect_eq "exit code" "$FRC" 0
expect_eq "pool still has Pri1/Pri2 + Ext1" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
end
# stage 3: per-source result for status (last_fetch_at / last_ok_at / result per source)
_fs=$(cat /tmp/vpnpool/fetch_status.json 2>/dev/null)
begin "fetch/status-per-source"
expect_jq "primary: served from cache, its last success kept from the first run" "$_fs" \
	".[\"$PRI\"] | .result==\"cached\" and (.last_ok_at|type)==\"number\" and .primary==true and .at >= .last_ok_at"
expect_jq "extra: fetched now, 1 node" "$_fs" \
	".[\"$EXT\"] | .result==\"ok\" and .nodes==1 and .last_ok_at==.at and .primary==false"
end

# ---- everything down: whole cache served ----
fetch_setup 200 200; sh "$FETCH" >/dev/null 2>&1          # repopulate the cache
fetch_setup 500 500
sh "$FETCH" > "$FXF/log3" 2>&1; FRC=$?
begin "fetch/all-fail-serves-cache"
expect_eq "exit code" "$FRC" 0
expect_eq "pool from cache" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
end

# ---- the subscription token must not reach the log in clear text ----
begin "fetch/log-written"   # positive control for the next case, outside its xfail
expect_true "log mentions the fetch at all" grep -q 'fetch:' "$FXF/log1"
end
begin "fetch/token-masked-in-log"
expect_eq "SECRETTOKEN123 occurrences in log" "$(cat "$FXF/log1" "$FXF/log2" "$FXF/log3" | gcount SECRETTOKEN123)" 0
end

# ---- flash wear (2.11): an unchanged subscription does not rewrite its cached copy ----
reset_state
uci set vpnpool.main.subscription_url="$PRI"; uci add_list vpnpool.main.extra_sub="$EXT"; uci commit vpnpool
fetch_setup 200 200; sh "$FETCH" >/dev/null 2>&1
touch -d '2000-01-01 00:00:00' /etc/vpnpool/sources_cache/s-*.raw
sh "$FETCH" >/dev/null 2>&1
begin "fetch/unchanged-source-cache-not-rewritten"
expect_eq "cached copies" "$(ls /etc/vpnpool/sources_cache/s-*.raw 2>/dev/null | wc -l)" 2
expect_eq "cached copies still dated 2000" "$(for f in /etc/vpnpool/sources_cache/s-*.raw; do date -r "$f" +%Y; done | sort -u)" 2000
end
cp "$FXF/extra.txt" "$FXF/extra.orig"
printf 'vless://%s@203.0.113.64:443?security=tls&sni=a.example#Ext2\n' "$U" >> "$FXF/extra.txt"
sh "$FETCH" >/dev/null 2>&1
begin "fetch/changed-source-cache-rewritten"   # positive control for the case above
expect_eq "exactly one cached copy rewritten" "$(for f in /etc/vpnpool/sources_cache/s-*.raw; do date -r "$f" +%Y; done | grep -vc 2000)" 1
end
cp "$FXF/extra.orig" "$FXF/extra.txt"

# ---- a removed subscription leaves the cache (its nodes must not come back from it) ----
uci -q delete vpnpool.main.extra_sub; uci commit vpnpool
fetch_setup 500 500
sh "$FETCH" >/dev/null 2>&1
begin "fetch/removed-source-dropped-from-cache"
expect_eq "pool = primary from cache only" "$(pool_tags)" '["Pri1","Pri2"]'
expect_eq "one cached copy left" "$(ls /etc/vpnpool/sources_cache/s-*.raw 2>/dev/null | wc -l)" 1
end

# ---- start-up throttle (2.1): no re-download within 10 min unless the source set changed ----
due() { sh -c '. /usr/libexec/vpnpool/lib.sh; fetch_due'; }
sig() { sh -c '. /usr/libexec/vpnpool/lib.sh; sources_sig'; }
begin "fetch/fetch-due-throttle"
expect_true "stamp written" [ -s /tmp/vpnpool/.last_fetch ]
expect_true "not due right after a fetch" sh -c '! sh -c ". /usr/libexec/vpnpool/lib.sh; fetch_due"'
echo "$(( $(date +%s) - 700 )) $(sig)" > /tmp/vpnpool/.last_fetch
expect_true "due after 700 s" due
echo "$(date +%s) $(sig)" > /tmp/vpnpool/.last_fetch
expect_true "not due again (control for the next check)" sh -c '! sh -c ". /usr/libexec/vpnpool/lib.sh; fetch_due"'
uci add_list vpnpool.main.extra_sub="$EXT"; uci commit vpnpool
expect_true "due at once when a subscription was added" due
end

# ---- review V5: a killed fetch records "interrupted" for what it did not finish ----
reset_state
uci set vpnpool.main.subscription_url="$PRI"; uci add_list vpnpool.main.extra_sub="$EXT"; uci commit vpnpool
fetch_setup 200 200; sh "$FETCH" >/dev/null 2>&1                     # one good run first
mock_on; mock_rule "GET $PRI" 200 "$FXF/primary.b64" "$FXF/primary.hdr" 0.010 8; mock_rule "GET $EXT" 200 "$FXF/extra.txt"
rm -f /tmp/curlmock/calls.log   # count only THIS run's requests
sh "$FETCH" > "$FXF/logk" 2>&1 & FP=$!
_i=0; while [ $_i -lt 10 ] && [ "$(mock_calls "GET $PRI")" -lt 1 ]; do sleep 1; _i=$((_i + 1)); done
kill -TERM "$FP"; wait "$FP"; KRC=$?
_fs=$(cat /tmp/vpnpool/fetch_status.json 2>/dev/null)
begin "fetch/term-records-interrupted"
expect_eq "exit code 143" "$KRC" 143
expect_jq "both sources interrupted, the last success kept" "$_fs" \
	".[\"$PRI\"].result==\"interrupted\" and .[\"$EXT\"].result==\"interrupted\" and (.[\"$PRI\"].last_ok_at|type)==\"number\""
end
