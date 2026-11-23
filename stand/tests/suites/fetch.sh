# suite: fetch — fetch.sh over the subscription sections with partially failing sources (sourced
# by run.sh). Every subscription is its own uci section (ROADMAP 9.1) with its own cache, its own
# expiry / quota / provider interval (the panel's headers -> subs.meta.json) and its own "updated".
# 2.5: the cache fallback is PER subscription — one that fails is served from its own copy while
# another one answers.

FETCH=/usr/libexec/vpnpool/fetch.sh
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
FXF="$T_STATE/fetch"; mkdir -p "$FXF"
PRI='https://sub.example.com/sub/SECRETTOKEN123'
EXT='https://extra.example.com/list'
printf 'vless://%s@203.0.113.61:443?security=tls&sni=a.example#Pri1\nvless://%s@203.0.113.62:443?security=tls&sni=a.example#Pri2\n' "$U" "$U" | base64 -w0 > "$FXF/primary.b64"
printf 'vless://%s@203.0.113.63:443?security=tls&sni=a.example#Ext1\n' "$U" > "$FXF/extra.txt"
# the panel's headers: quota/expiry, the provider's update interval (hours), a base64 title
printf 'HTTP/1.1 200 OK\r\nSubscription-Userinfo: upload=1; download=2; total=1000; expire=1893456000\r\nprofile-update-interval: 12\r\nprofile-title: base64:%s\r\nprofile-web-page-url: https://sub.example.com/panel/SECRETTOKEN123\r\n\r\n' \
	"$(printf 'My Provider' | base64 -w0)" > "$FXF/primary.hdr"
printf 'HTTP/1.1 200 OK\r\nsubscription-userinfo: upload=5; download=6; total=2000; expire=1900000000\r\n\r\n' > "$FXF/extra.hdr"

fetch_setup() {   # <primary code> <extra code>
	mock_on
	mock_rule "GET $PRI" "$1" "$FXF/primary.b64" "$FXF/primary.hdr"
	mock_rule "GET $EXT" "$2" "$FXF/extra.txt" "$FXF/extra.hdr"
}
pool_tags() {   # tags the build would see from the fetched sources
	for f in /tmp/vpnpool/sources/*.raw; do [ -f "$f" ] && ucode /usr/libexec/vpnpool/parser.uc "$f"; done 2>/dev/null \
		| jq -sc 'add // [] | map(.tag) | sort' 2>/dev/null
}
two_subs() { sub_section sp "$PRI"; sub_section se "$EXT"; }

reset_state; two_subs

# ---- positive control: both sources answer ----
fetch_setup 200 200
sh "$FETCH" > "$FXF/log1" 2>&1; FRC=$?
_m=$(cat /etc/vpnpool/subs.meta.json 2>/dev/null)
begin "fetch/all-sources-ok"
expect_eq "exit code" "$FRC" 0
expect_eq "pool = both subscriptions" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
expect_jq "expiry + quota of EACH subscription from its own headers" "$_m" \
	'.sp.expire==1893456000 and .sp.upload==1 and .sp.download==2 and .sp.total==1000 and .se.expire==1900000000 and .se.total==2000'
expect_jq "provider update interval (12 h -> s), title, web page" "$_m" \
	'.sp.update_interval==43200 and (.sp.title|startswith("base64:")) and (.sp.web_page|length)>0 and .se.update_interval==null'
expect_true "cache written" [ -d /etc/vpnpool/sources_cache ]
expect_true "'updated' marker per subscription" sh -c '[ -f /etc/vpnpool/sources_cache/.ok-sp ] && [ -f /etc/vpnpool/sources_cache/.ok-se ]'
end

# ---- primary 500, extra 200: the primary's nodes must stay (from cache) ----
fetch_setup 500 200
sh "$FETCH" > "$FXF/log2" 2>&1; FRC=$?
begin "fetch/primary-fails-extra-ok-keeps-primary-nodes"
expect_eq "exit code" "$FRC" 0
expect_eq "pool still has Pri1/Pri2 + Ext1" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
expect_jq "the failed subscription keeps its last expiry / quota" "$(cat /etc/vpnpool/subs.meta.json)" '.sp.expire==1893456000 and .sp.total==1000'
end
# stage 3: per-source result for status (last_fetch_at / last_ok_at / result per source)
_fs=$(cat /tmp/vpnpool/fetch_status.json 2>/dev/null)
begin "fetch/status-per-source"
expect_jq "primary: served from cache, its last success kept from the first run" "$_fs" \
	".[\"$PRI\"] | .result==\"cached\" and (.last_ok_at|type)==\"number\" and .id==\"sp\" and .at >= .last_ok_at"
expect_jq "extra: fetched now, 1 node" "$_fs" \
	".[\"$EXT\"] | .result==\"ok\" and .nodes==1 and .last_ok_at==.at and .id==\"se\""
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
begin "fetch/log-written"   # positive control for the next case
expect_true "log mentions the fetch at all" grep -q 'fetch:' "$FXF/log1"
end
begin "fetch/token-masked-in-log"
expect_eq "SECRETTOKEN123 occurrences in log" "$(cat "$FXF/log1" "$FXF/log2" "$FXF/log3" | gcount SECRETTOKEN123)" 0
end

# ---- flash wear (2.11): an unchanged subscription does not rewrite its cached copy / meta ----
reset_state; two_subs
fetch_setup 200 200; sh "$FETCH" >/dev/null 2>&1
touch -d '2000-01-01 00:00:00' /etc/vpnpool/sources_cache/s-*.raw /etc/vpnpool/subs.meta.json
sh "$FETCH" >/dev/null 2>&1
begin "fetch/unchanged-source-cache-not-rewritten"
expect_eq "cached copies" "$(ls /etc/vpnpool/sources_cache/s-*.raw 2>/dev/null | wc -l)" 2
expect_eq "cached copies still dated 2000" "$(for f in /etc/vpnpool/sources_cache/s-*.raw; do date -r "$f" +%Y; done | sort -u)" 2000
expect_eq "meta still dated 2000 (same headers)" "$(date -r /etc/vpnpool/subs.meta.json +%Y)" 2000
end
cp "$FXF/extra.txt" "$FXF/extra.orig"
printf 'vless://%s@203.0.113.64:443?security=tls&sni=a.example#Ext2\n' "$U" >> "$FXF/extra.txt"
sh "$FETCH" >/dev/null 2>&1
begin "fetch/changed-source-cache-rewritten"   # positive control for the case above
expect_eq "exactly one cached copy rewritten" "$(for f in /etc/vpnpool/sources_cache/s-*.raw; do date -r "$f" +%Y; done | grep -vc 2000)" 1
end
cp "$FXF/extra.orig" "$FXF/extra.txt"

# ---- a switched-off subscription is not fetched, and keeps its cached copy ----
uci set vpnpool.se.enabled=0; uci commit vpnpool
fetch_setup 200 200; rm -f /tmp/curlmock/calls.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/disabled-subscription-not-fetched"
expect_eq "no request to it" "$(mock_calls "GET $EXT")" 0
expect_true "the enabled one was fetched (positive control)" [ "$(mock_calls "GET $PRI")" -ge 1 ]
expect_eq "its cached copy kept" "$(ls /etc/vpnpool/sources_cache/s-*.raw 2>/dev/null | wc -l)" 2
expect_eq "pool = the enabled subscription only" "$(pool_tags)" '["Pri1","Pri2"]'
end
uci set vpnpool.se.enabled=1; uci commit vpnpool

# ---- a removed subscription leaves the cache, the meta and its marker ----
uci delete vpnpool.se; uci commit vpnpool
fetch_setup 500 500
sh "$FETCH" >/dev/null 2>&1
begin "fetch/removed-source-dropped-from-cache"
expect_eq "pool = primary from cache only" "$(pool_tags)" '["Pri1","Pri2"]'
expect_eq "one cached copy left" "$(ls /etc/vpnpool/sources_cache/s-*.raw 2>/dev/null | wc -l)" 1
expect_jq "its meta gone, the other one kept" "$(cat /etc/vpnpool/subs.meta.json)" '(has("se")|not) and has("sp")'
expect_true "its marker gone" [ ! -f /etc/vpnpool/sources_cache/.ok-se ]
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
sub_section se "$EXT"
expect_true "due at once when a subscription was added" due
echo "$(date +%s) $(sig)" > /tmp/vpnpool/.last_fetch
uci set vpnpool.se.name='Renamed'; uci commit vpnpool
expect_true "a new name alone does not make a fetch due" sh -c '! sh -c ". /usr/libexec/vpnpool/lib.sh; fetch_due"'
end

# ---- review V5: a killed fetch records "interrupted" for what it did not finish ----
reset_state; two_subs
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

# ---- review V8: an answer above the size limit is not parsed (a public list on a 16 MB router) ----
reset_state; two_subs; uci set vpnpool.main.fetch_max_kb=16; uci commit vpnpool
fetch_setup 200 200; sh "$FETCH" >/dev/null 2>&1                      # cached copies first (small)
i=0; : > "$FXF/big.txt"
while [ $i -lt 400 ]; do printf 'vless://%s@203.0.113.%d:443?security=tls&sni=a.example#Big%d\n' "$U" $((i % 250)) "$i" >> "$FXF/big.txt"; i=$((i + 1)); done
mock_on; mock_rule "GET $PRI" 200 "$FXF/primary.b64" "$FXF/primary.hdr"; mock_rule "GET $EXT" 200 "$FXF/big.txt"
sh "$FETCH" > "$FXF/logbig" 2>&1
begin "fetch/oversized-answer-not-used"
expect_true "control: the answer is above 16 KiB" [ "$(wc -c < "$FXF/big.txt")" -gt 16384 ]
expect_eq "the extra subscription served from its cached copy (1 node), not the big answer" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
expect_true "the log says why" grep -q 'more than the limit' "$FXF/logbig"
end

# ---- ui4: "Update" of ONE subscription (fetch.sh --only <id>): the others are not downloaded ----
reset_state; two_subs
fetch_setup 200 200; sh "$FETCH" >/dev/null 2>&1                     # a full run first
echo "1000 $(sig)" > /tmp/vpnpool/.last_fetch   # an old stamp: a rewrite within the same second would not show
_st0=$(cat /tmp/vpnpool/.last_fetch 2>/dev/null)
_pat0=$(jq -c --arg u "$PRI" '.[$u].at' /tmp/vpnpool/fetch_status.json 2>/dev/null)
cp "$FXF/extra.txt" "$FXF/extra.orig"
printf 'vless://%s@203.0.113.65:443?security=tls&sni=a.example#Ext3\n' "$U" >> "$FXF/extra.txt"   # changed at the panel
rm -f /tmp/curlmock/calls.log
sh "$FETCH" --only se > "$FXF/logo" 2>&1; FRC=$?
_fs=$(cat /tmp/vpnpool/fetch_status.json 2>/dev/null)
begin "fetch/only-one-subscription"
expect_eq "exit code" "$FRC" 0
expect_true "the asked subscription was downloaded (positive control)" [ "$(mock_calls "GET $EXT")" -ge 1 ]
expect_eq "no request to the other one" "$(mock_calls "GET $PRI")" 0
expect_eq "pool: the other's nodes stay, the asked one's are new" "$(pool_tags)" '["Ext1","Ext3","Pri1","Pri2"]'
expect_jq "status: the asked one fetched now (2 nodes), the other's entry of the last run kept" "$_fs" \
	".[\"$EXT\"].result==\"ok\" and .[\"$EXT\"].nodes==2 and .[\"$PRI\"].result==\"ok\" and (.[\"$PRI\"].at|tostring)==\"$_pat0\""
expect_eq "the throttle stamp of the full run is not rewritten" "$(cat /tmp/vpnpool/.last_fetch 2>/dev/null)" "$_st0"
end
# the other subscription's copy of the last run is gone (never fetched since boot): from its cache
rm -f /tmp/vpnpool/sources/*.raw
sh "$FETCH" --only se >/dev/null 2>&1
begin "fetch/only-the-others-from-their-own-cache"
expect_eq "pool: the other one from its cached copy" "$(pool_tags)" '["Ext1","Ext3","Pri1","Pri2"]'
expect_eq "still no request to it" "$(mock_calls "GET $PRI")" 0
end
cp "$FXF/extra.orig" "$FXF/extra.txt"

# ---- issue #5: the device ID (x-hwid & co) with every subscription download ----
# panels with a device limit (Remnawave) give no nodes without x-hwid. The package default config
# has sub_hwid '1' and an empty hwid: the first download makes it from the kernel's random UUID
# and keeps it; the board name goes out cleaned (no quote / backslash can break the curl -K line).
reset_state; two_subs
mkdir -p /tmp/sysinfo; _mdl0=$(cat /tmp/sysinfo/model 2>/dev/null)
printf 'Test "Board" \ AX-3000\n' > /tmp/sysinfo/model
fetch_setup 200 200; rm -f /tmp/curlmock/headers.log
sh "$FETCH" >/dev/null 2>&1
_hw=$(uci -q get vpnpool.main.hwid)
begin "fetch/hwid-sent-with-every-subscription"
expect_eq "control: the default config sends it, with no ID yet" "$(uci -q get "vpnpool.main.sub_hwid")/$(sed -n "s/^[[:space:]]*option hwid '\(.*\)'$/\1/p" "$BASE_CONFIG")" "1/"
expect_true "an ID was made and kept ($_hw)" sh -c 'printf %s "$1" | grep -qE "^[A-Za-z0-9=-]{10,64}$"' _ "$_hw"
expect_eq "x-hwid to the first subscription" "$(gcount "^GET $PRI	x-hwid: $_hw\$" /tmp/curlmock/headers.log)" 1
expect_eq "x-hwid to the second subscription" "$(gcount "^GET $EXT	x-hwid: $_hw\$" /tmp/curlmock/headers.log)" 1
expect_eq "x-device-os" "$(gcount "^GET $PRI	x-device-os: OpenWrt\$" /tmp/curlmock/headers.log)" 1
expect_eq "x-device-model cleaned" "$(gcount "^GET $PRI	x-device-model: Test Board AX-3000\$" /tmp/curlmock/headers.log)" 1
expect_eq "x-ver-os = the release" "$(gcount "^GET $PRI	x-ver-os: $(. /etc/openwrt_release; echo "$DISTRIB_RELEASE")\$" /tmp/curlmock/headers.log)" 1
expect_eq "pool unchanged by the headers (positive control)" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
end
# the same ID next time (the provider must see one device, not a new one per download)
rm -f /tmp/curlmock/headers.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/hwid-stable"
expect_eq "the kept ID again" "$(gcount "^GET $PRI	x-hwid: $_hw\$" /tmp/curlmock/headers.log)" 1
expect_eq "uci unchanged" "$(uci -q get vpnpool.main.hwid)" "$_hw"
end
# switched off: no device header at all
uci set vpnpool.main.sub_hwid=0; uci commit vpnpool
rm -f /tmp/curlmock/headers.log /tmp/curlmock/calls.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/hwid-off-sends-nothing"
expect_true "downloaded (positive control)" [ "$(mock_calls "GET $PRI")" -ge 1 ]
expect_eq "no device header" "$(gcount 'x-hwid\|x-device' /tmp/curlmock/headers.log)" 0
end
# an ID typed by hand is sent as it is
uci set vpnpool.main.sub_hwid=1; uci set vpnpool.main.hwid=MyPhone-0123456789; uci commit vpnpool
rm -f /tmp/curlmock/headers.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/hwid-typed-by-hand"
expect_eq "sent as typed" "$(gcount "^GET $PRI	x-hwid: MyPhone-0123456789\$" /tmp/curlmock/headers.log)" 1
end

# ---- the system, its version and the model typed by hand (Settings: sub_os / sub_os_ver / sub_model) ----
uci set vpnpool.main.sub_os=Android; uci set vpnpool.main.sub_os_ver=14; uci set 'vpnpool.main.sub_model=Pixel 8 (Pro)'; uci commit vpnpool
rm -f /tmp/curlmock/headers.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/device-typed-by-hand"
expect_eq "x-device-os as typed" "$(gcount "^GET $PRI	x-device-os: Android\$" /tmp/curlmock/headers.log)" 1
expect_eq "x-ver-os as typed" "$(gcount "^GET $PRI	x-ver-os: 14\$" /tmp/curlmock/headers.log)" 1
expect_eq "x-device-model as typed" "$(gcount "^GET $PRI	x-device-model: Pixel 8 (Pro)\$" /tmp/curlmock/headers.log)" 1
expect_eq "not the router's own model as well" "$(gcount "^GET $PRI	x-device-model: Test Board" /tmp/curlmock/headers.log)" 0
expect_eq "the ID still goes with them" "$(gcount "^GET $PRI	x-hwid: MyPhone-0123456789\$" /tmp/curlmock/headers.log)" 1
end
# a value edited past set_config (a quote would end the curl -K line): the router's own goes
uci set 'vpnpool.main.sub_model=Bad "model'; uci set vpnpool.main.sub_os=''; uci commit vpnpool
rm -f /tmp/curlmock/headers.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/device-bad-or-empty-falls-back-to-router"
expect_eq "bad model: the router's own" "$(gcount "^GET $PRI	x-device-model: Test Board AX-3000\$" /tmp/curlmock/headers.log)" 1
expect_eq "nothing with the quote" "$(gcount 'Bad' /tmp/curlmock/headers.log)" 0
expect_eq "empty system: OpenWrt" "$(gcount "^GET $PRI	x-device-os: OpenWrt\$" /tmp/curlmock/headers.log)" 1
expect_eq "the version typed stays" "$(gcount "^GET $PRI	x-ver-os: 14\$" /tmp/curlmock/headers.log)" 1
end
uci -q delete vpnpool.main.sub_os; uci -q delete vpnpool.main.sub_os_ver; uci -q delete vpnpool.main.sub_model; uci commit vpnpool

# ---- one client name typed in Settings (sub_ua): the router calls itself only that ----
# the panel gives nodes only to that name (with spaces, ";" and brackets, as real client names)
UA1='Happ/3.5.0 (Linux; arm64)'
_NUAS=$(sh -c '. /usr/libexec/vpnpool/lib.sh; printf "%s\n" $DEFAULT_UAS' | grep -c .)
fetch_ua_rules() {
	mock_on
	mock_rule "GET $PRI @$UA1" 200 "$FXF/primary.b64" "$FXF/primary.hdr"
	mock_rule "GET $PRI" 404
	mock_rule "GET $EXT" 200 "$FXF/extra.txt" "$FXF/extra.hdr"
}
fetch_ua_rules; rm -f /tmp/curlmock/calls.log /tmp/curlmock/ua.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/ua-empty-tries-the-list"   # control: without it the list is tried, that name is not in it
expect_true "control: the list holds several names ($_NUAS)" [ "$_NUAS" -gt 1 ]
expect_eq "every name of the standard list" "$(mock_calls "GET $PRI")" "$_NUAS"
expect_eq "never that name" "$(gcount "^GET $PRI	$UA1\$" /tmp/curlmock/ua.log)" 0
expect_jq "so the primary is not fresh" "$(cat /tmp/vpnpool/fetch_status.json)" ".[\"$PRI\"].result != \"ok\""
end
uci set "vpnpool.main.sub_ua=$UA1"; uci commit vpnpool
fetch_ua_rules; rm -f /tmp/curlmock/calls.log /tmp/curlmock/ua.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/ua-typed-only-that-name"
expect_eq "one call per subscription" "$(mock_calls "GET $PRI")/$(mock_calls "GET $EXT")" "1/1"
expect_eq "the whole name, spaces kept" "$(gcount "^GET $PRI	$UA1\$" /tmp/curlmock/ua.log)" 1
expect_eq "to the other subscription too" "$(gcount "^GET $EXT	$UA1\$" /tmp/curlmock/ua.log)" 1
expect_jq "the primary fetched now" "$(cat /tmp/vpnpool/fetch_status.json)" ".[\"$PRI\"].result == \"ok\" and .[\"$PRI\"].nodes == 2"
end
# the panel refuses that name: no other name is tried (the provider sees only the chosen app)
mock_on; mock_rule "GET $PRI" 404; mock_rule "GET $EXT" 200 "$FXF/extra.txt" "$FXF/extra.hdr"
rm -f /tmp/curlmock/calls.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/ua-typed-no-fallback-to-list"
expect_eq "one try only" "$(mock_calls "GET $PRI")" 1
expect_eq "pool from the cached copy" "$(pool_tags)" '["Ext1","Pri1","Pri2"]'
end
# a name edited past set_config (a quote): not used, the list is tried
uci set 'vpnpool.main.sub_ua=Bad"UA'; uci commit vpnpool
fetch_ua_rules; rm -f /tmp/curlmock/calls.log /tmp/curlmock/ua.log
sh "$FETCH" >/dev/null 2>&1
begin "fetch/ua-bad-falls-back-to-list"
expect_eq "the list again" "$(mock_calls "GET $PRI")" "$_NUAS"
expect_eq "not the bad name" "$(gcount 'Bad' /tmp/curlmock/ua.log)" 0
end
uci -q delete vpnpool.main.sub_ua; uci commit vpnpool
if [ -n "$_mdl0" ]; then printf '%s\n' "$_mdl0" > /tmp/sysinfo/model; else rm -f /tmp/sysinfo/model; fi
