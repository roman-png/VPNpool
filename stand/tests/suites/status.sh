# suite: status — status.sh cost on a 300-node pool (sourced by run.sh)
# Metrics: wall time and processes spawned per dashboard poll (kernel PID counter of the
# container's PID namespace). ROADMAP 3.7: target < 10 per poll (1.x: ~143-164); the cases
# fail above 15 (the curl test double is itself a shell script and adds a few).

ST=/usr/libexec/vpnpool/status.sh
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
FXS="$T_STATE/status"; mkdir -p "$FXS"

reset_state
i=1; : > "$FXS/links.txt"
while [ $i -le 300 ]; do
	printf 'vless://%s@10.%d.%d.%d:443?security=tls&sni=n%d.example#Node%03d\n' "$U" $((i / 250)) $((i % 250)) 7 "$i" "$i" >> "$FXS/links.txt"
	i=$((i + 1))
done
ucode /usr/libexec/vpnpool/parser.uc --with-id "$FXS/links.txt" > "$FXS/nodes.json"
jq '{proxies: ((map({key: .tag, value: {type: "VLESS", history: [{delay: 120}]}}) | from_entries)
	+ {proxy: {type: "Selector", now: "auto"}, auto: {type: "URLTest", now: "Node001"}})}' "$FXS/nodes.json" > "$FXS/proxies.json"
echo '{"uploadTotal":100,"downloadTotal":2000,"connections":[{"metadata":{"sourceIP":"192.168.1.10","host":"a.example"},"chains":["Node001","auto","proxy"],"upload":10,"download":20}]}' > "$FXS/conns.json"

# calibrate: what does reading the counter itself cost?
b=$(last_pid); a=$(last_pid); CAL=$((a - b))

measure_status() {   # -> SOUT, SSECS, SPROCS
	cp "$FXS/nodes.json" /tmp/vpnpool/nodes.json
	_b=$(last_pid); read _u0 _ < /proc/uptime        # `read` is a builtin: no extra process
	SOUT=$(sh "$ST" 2>/dev/null)
	read _u1 _ < /proc/uptime; _a=$(last_pid)
	_c0=$(echo "$_u0" | tr -d .); _c1=$(echo "$_u1" | tr -d .)   # centiseconds (outside the window)
	SSECS="$(( (_c1 - _c0) / 100 )).$(printf '%02d' $(( (_c1 - _c0) % 100 )))"; SPROCS=$((_a - _b - CAL))
}

# ---- daemon down ----
measure_status
begin "status/300-nodes-daemon-down-valid"
expect_jq "valid status object" "$SOUT" 'type=="object" and (.nodes|length)==300 and .running==false'
end
metric status_300_down_seconds "$SSECS"
metric status_300_down_processes "$SPROCS"
begin "status/300-nodes-daemon-down-at-most-15-processes"
expect_le "processes per poll" "$SPROCS" 15
end

# ---- daemon up (fake vpnpoold + mocked clash API) ----
daemon_start
mock_on
mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXS/proxies.json"
mock_rule 'GET http://127.0.0.1:9091/connections' 200 "$FXS/conns.json"
measure_status
begin "status/300-nodes-daemon-up-valid"
expect_jq "running + 300 nodes" "$SOUT" '.running==true and (.nodes|length)==300'
expect_jq "delay from clash history" "$SOUT" '(.nodes[0].delay)==120'
expect_jq "per-node traffic" "$SOUT" '(.nodes[] | select(.tag=="Node001") | .down)==20'
expect_jq "active node" "$SOUT" '.auto_now=="Node001"'
expect_jq "node id from nodes.json" "$SOUT" '(.nodes[0].id|type)=="string" and (.nodes[0].id|length)==12'
expect_jq "rpcd reply shape" "$SOUT" '.ok==true and .code=="ok" and .daemon=="n/a"'
end
metric status_300_up_seconds "$SSECS"
metric status_300_up_processes "$SPROCS"
begin "status/300-nodes-daemon-up-at-most-15-processes"
expect_le "processes per poll" "$SPROCS" 15
end
# secrets: status must not hand the Telegram token to the browser (ROADMAP 3.5)
uci set vpnpool.main.telegram_token='123456:SECRET-BOT-TOKEN'; uci commit vpnpool
measure_status
begin "status/with-token-valid"   # positive control, outside the xfail below
expect_jq "status still valid" "$SOUT" '.settings|type=="object"'
end
begin "status/telegram-token-masked"
expect_eq "token occurrences in status" "$(printf '%s' "$SOUT" | gcount 'SECRET-BOT-TOKEN')" 0
expect_jq "masked form + a set flag" "$SOUT" '.settings.telegram_token=="123456:***" and .settings.telegram_token_set==true'
end
daemon_stop

# ---- stage 3: subscription URLs masked, per-source fetch result, build result, busy, pause ----
PRI='https://sub.example.com/sub/SECRETTOKEN123?x=1'
EXT='https://extra.example.com/list/SECRET2'
SRC='https://lists.example.com/src/SECRET3'
uci set vpnpool.main.subscription_url="$PRI"; uci add_list vpnpool.main.extra_sub="$EXT"; uci add_list vpnpool.main.source="$SRC"; uci commit vpnpool
jq -nc --arg p "$PRI" '{($p): {at: 1700000100, result: "cached", nodes: 0, primary: true, last_ok_at: 1700000000}}' > /tmp/vpnpool/fetch_status.json
echo '{"at":1700000200,"ok":true,"nodes":300,"skipped":1,"dropped":[{"source":"000.raw","line":4,"reason":"bad_port"}],"error":null}' > /tmp/vpnpool/build_status.json
echo '{"running":true,"done":5,"total":300,"alive":4}' > /tmp/vpnpool/.ping-progress.json
sleep 300 & LIVE=$!
echo "$LIVE" > /tmp/vpnpool/.ping-running          # a live owner -> busy
echo 999999 > /tmp/vpnpool/.speedtest-running     # a dead owner -> not busy
: > /tmp/vpnpool/.routing_paused
measure_status
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
rm -f /tmp/vpnpool/.ping-running /tmp/vpnpool/.speedtest-running /tmp/vpnpool/.routing_paused
begin "status/subscription-urls-masked"
expect_eq "secret paths in status" "$(printf '%s' "$SOUT" | gcount -e 'SECRETTOKEN123' -e 'list/SECRET2' -e 'src/SECRET3')" 0
expect_jq "masked primary + extra" "$SOUT" '.subscription.url=="https://sub.example.com/***" and .extra_subs==["https://extra.example.com/***"]'
end
begin "status/source-urls-masked"
expect_jq "masked probe source" "$SOUT" '.sources==["https://lists.example.com/***"]'
end
begin "status/subscriptions-last-fetch"
expect_jq "primary: last fetch, last success, result" "$SOUT" \
	'.subscriptions[0] | .kind=="primary" and .url=="https://sub.example.com/***" and .last_fetch_at==1700000100 and .last_ok_at==1700000000 and .result=="cached" and (.key|length)==12'
expect_jq "extra never fetched -> null, not invented" "$SOUT" '.subscriptions[1] | .kind=="extra" and .last_fetch_at==null and .result==null'
end
begin "status/build-busy-pause-progress"
expect_jq "build result passed through" "$SOUT" '.build.ok==true and .build.nodes==300 and .build.dropped[0].reason=="bad_port"'
expect_jq "busy: ping (live owner) yes, speedtest (dead owner) no" "$SOUT" '.busy.ping==true and .busy.speedtest==false and .busy.fetch==false and (.busy|keys)==["build","fetch","nodecheck","ping","probe","speedtest","unlock"]'
expect_jq "ping progress" "$SOUT" '.ping_progress.done==5 and .ping_progress.total==300'
expect_jq "Telegram pause" "$SOUT" '.paused==true'
end
measure_status
begin "status/flags-clear-after"   # the same fields answer "no" once the files are gone
expect_jq "not busy, not paused" "$SOUT" '.busy.ping==false and .paused==false'
end

# ---- the small link files are parsed once and cached by mtime (manual node grouping) ----
printf 'vless://%s@203.0.113.9:443?security=tls&sni=m.example#Node001\n' "$U" > /tmp/vpnpool/manual.links
rm -f /tmp/vpnpool/.status-cache.json
measure_status; P1=$SPROCS
begin "status/manual-group-from-parsed-links"
expect_jq "Node001 grouped as manual, others subscription" "$SOUT" \
	'(.nodes[] | select(.tag=="Node001") | .group)=="manual" and (.nodes[] | select(.tag=="Node002") | .group)=="subscription"'
end
measure_status; P2=$SPROCS
begin "status/link-parse-cached-by-mtime"
expect_true "second poll spawns fewer processes ($P2) than the first ($P1)" [ "$P2" -lt "$P1" ]
expect_jq "still grouped as manual" "$SOUT" '(.nodes[] | select(.tag=="Node001") | .group)=="manual"'
end
metric status_manual_first_poll_processes "$P1"
metric status_manual_cached_poll_processes "$P2"

# ---- review fixes ----
# M5: the cache key has the inode (a same-size rewrite in the same second is still seen) ...
fsig() { ucode -e "import { stat } from 'fs'; let s = stat('$1'); print(s.inode, ':', s.mtime, ':', s.size);"; }
ms() { fsig "$1" | cut -d: -f2-; }   # mtime:size only
OLDMS=$(ms /tmp/vpnpool/manual.links)
printf 'vless://%s@203.0.113.9:443?security=tls&sni=m.example#Node002\n' "$U" > /tmp/vpnpool/manual.links.new
touch -r /tmp/vpnpool/manual.links /tmp/vpnpool/manual.links.new
mv -f /tmp/vpnpool/manual.links.new /tmp/vpnpool/manual.links
measure_status
begin "status/cache-sees-same-size-same-second-rewrite"
expect_eq "positive control: same mtime and size as before" "$(ms /tmp/vpnpool/manual.links)" "$OLDMS"
expect_jq "Node002 is manual now, Node001 is not" "$SOUT" \
	'(.nodes[] | select(.tag=="Node002") | .group)=="manual" and (.nodes[] | select(.tag=="Node001") | .group)=="subscription"'
end
# ... and the parser's own signature (a package update invalidates the cache)
jq -nc --arg s "$(fsig /tmp/vpnpool/manual.links)|OLD-PARSER" '{manual:{sig:$s, v:[]}}' > /tmp/vpnpool/.status-cache.json
measure_status
begin "status/cache-invalidated-by-another-parser"
expect_jq "re-parsed: Node002 still manual" "$SOUT" '(.nodes[] | select(.tag=="Node002") | .group)=="manual"'
end
rm -f /tmp/vpnpool/manual.links

# M3: running = the pidfile's PID runs vpnpoold, not "some command line mentions the path"
daemon_stop
sh -c 'sleep 6; : /usr/libexec/vpnpool/vpnpoold' & MENTION=$!
sleep 30 & OTHER=$!; echo "$OTHER" > /var/run/vpnpool.pid    # a stale pidfile -> a live unrelated PID
measure_status
kill "$MENTION" "$OTHER" 2>/dev/null; wait "$MENTION" "$OTHER" 2>/dev/null; rm -f /var/run/vpnpool.pid
begin "status/running-not-fooled-by-a-mention"
expect_jq "not running" "$SOUT" '.running==false'
end

# M4: no shared temp files — overlapping polls (LuCI + the bot) must not clobber each other
daemon_start; mock_on
mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXS/proxies.json"
mock_rule 'GET http://127.0.0.1:9091/connections' 200 "$FXS/conns.json"
echo "{\"Node001\":\"vless://$U@10.0.1.7:443?security=tls&sni=n1.example#Node001\"}" > /etc/vpnpool/saved.map.json
rm -f /tmp/vpnpool/.status-cache.json /tmp/vpnpool/.prox.json /tmp/vpnpool/.conn.json
cp "$FXS/nodes.json" /tmp/vpnpool/nodes.json
OKN=0
for r in 1 2 3; do
	sh "$ST" > "$FXS/p1.json" 2>/dev/null & A=$!
	sh "$ST" > "$FXS/p2.json" 2>/dev/null & B=$!
	wait "$A" "$B"
	for f in p1 p2; do jq -e '.auto_now=="Node001" and (.nodes[0].delay)==120' "$FXS/$f.json" >/dev/null 2>&1 && OKN=$((OKN + 1)); done
done
begin "status/overlapping-polls-no-shared-temp-files"
expect_eq "6 of 6 overlapping polls complete" "$OKN" 6
expect_eq "no shared temp file left in /tmp/vpnpool" "$(ls -a /tmp/vpnpool | grep -c -e '^\.prox\.json' -e '^\.conn\.json' -e '^\.archive\.links')" 0
expect_jq "the archive was parsed (positive control)" "$(cat "$FXS/p1.json")" '(.nodes[] | select(.tag=="Node001") | .saved)==true'
end
rm -f /etc/vpnpool/saved.map.json
daemon_stop
