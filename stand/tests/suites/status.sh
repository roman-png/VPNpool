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
# traffic per device: LAN sources only (a lease named "*" has no name); the router's own
# connections are one entry; a public source address is no device of this network
c() { printf '{"metadata":{"sourceIP":"%s"},"chains":["Node001"],"upload":%s,"download":%s}' "$1" "$2" "$3"; }
printf '{"connections":[%s,%s,%s,%s,%s,%s,%s]}' "$(c 192.168.1.5 1 100)" "$(c 127.0.0.1 2 50)" "$(c ::1 3 40)" 	"$(c 57.144.244.196 0 53)" "$(c 100.70.0.9 4 30)" "$(c fd00::5 5 20)" "$(c 192.168.1.6 6 10)" > "$FXS/conns-dev.json"
printf '1 aa:bb:cc:00:00:05 192.168.1.5 * 01:aa
1 aa:bb:cc:00:00:06 192.168.1.6 laptop 01:bb
' > /tmp/dhcp.leases
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXS/proxies.json"   # the first matching rule wins
mock_rule 'GET http://127.0.0.1:9091/connections' 200 "$FXS/conns-dev.json"
measure_status
begin "status/devices-are-lan-sources"
expect_jq "positive control: devices listed" "$SOUT" '(.client_traffic|length) >= 1'
expect_jq "the router: one entry for 127.0.0.1 and ::1" "$SOUT" '[.client_traffic[]|select(.self==true)] | length==1 and .[0].conns==2 and .[0].down==90'
expect_jq "no public source" "$SOUT" '[.client_traffic[]|select(.ip=="57.144.244.196")]|length==0'
expect_jq "a lease named * has no name" "$SOUT" '(.client_traffic[]|select(.ip=="192.168.1.5")|.host)==""'
expect_jq "a named lease" "$SOUT" '(.client_traffic[]|select(.ip=="192.168.1.6")|.host)=="laptop"'
expect_jq "CGNAT and ULA sources are devices" "$SOUT" '([.client_traffic[]|select(.ip=="100.70.0.9" or .ip=="fd00::5")]|length)==2'
expect_jq "exactly five entries" "$SOUT" '(.client_traffic|length)==5'
end
rm -f /tmp/dhcp.leases
daemon_stop

# ---- stage 3 + 6: subscriptions (sections, ROADMAP 9.1) masked, each with its own fetch result,
# expiry / quota / provider interval / "updated"; build result, busy, pause ----
PRI='https://sub.example.com/sub/SECRETTOKEN123?x=1'
EXT='https://extra.example.com/list/SECRET2'
SRC='https://lists.example.com/src/SECRET3'
ID1=$(jq -r '.[0].id' "$FXS/nodes.json"); ID2=$(jq -r '.[1].id' "$FXS/nodes.json")
sub_section sp "$PRI"; sub_section se "$EXT"; sub_section ss "$SRC" pick 1 "$ID2" 0123456789ab
uci set vpnpool.sp.name='My provider'; uci commit vpnpool
jq -nc --arg p "$PRI" '{($p): {id: "sp", at: 1700000100, result: "cached", nodes: 0, last_ok_at: 1700000000}}' > /tmp/vpnpool/fetch_status.json
jq -nc --arg w "https://sub.example.com/panel/SECRETTOKEN123" '{sp: {expire: 1893456000, upload: 100, download: 200, total: 1000, update_interval: 43200, title: null, web_page: $w},
	se: {expire: null, upload: null, download: null, total: null, update_interval: null, title: "base64:VGl0bGUgRQ==", web_page: null}}' > /etc/vpnpool/subs.meta.json
echo '{"at":1700000200,"ok":true,"nodes":300,"skipped":1,"dropped":[{"source":"000.raw","line":4,"reason":"bad_port"}],"error":null}' > /tmp/vpnpool/build_status.json
echo '{"running":true,"done":5,"total":300,"alive":4}' > /tmp/vpnpool/.ping-progress.json
sleep 300 & LIVE=$!
echo "$LIVE" > /tmp/vpnpool/.ping-running          # a live owner -> busy
echo 999999 > /tmp/vpnpool/.speedtest-running     # a dead owner -> not busy
: > /tmp/vpnpool/.routing_paused
# the build labels where each node comes from: 2 from sp, 1 from the pick subscription ss
jq --arg a "$ID1" --arg b "$ID2" 'map(if .id == $b then ._src = "sub:ss" elif .tag == "Node003" then ._src = "manual" else ._src = "sub:sp" end)' \
	"$FXS/nodes.json" > "$FXS/nodes.src.json"
cp "$FXS/nodes.json" "$FXS/nodes.plain.json"; cp "$FXS/nodes.src.json" "$FXS/nodes.json"
measure_status
cp "$FXS/nodes.plain.json" "$FXS/nodes.json"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
rm -f /tmp/vpnpool/.ping-running /tmp/vpnpool/.speedtest-running /tmp/vpnpool/.routing_paused
begin "status/subscription-urls-masked"
expect_eq "secret paths in status" "$(printf '%s' "$SOUT" | gcount -e 'SECRETTOKEN123' -e 'list/SECRET2' -e 'src/SECRET3')" 0
expect_jq "legacy fields: masked primary + extra" "$SOUT" '.subscription.url=="https://sub.example.com/***" and .extra_subs==["https://extra.example.com/***"]'
end
begin "status/source-urls-masked"
expect_jq "legacy: the pick subscription is the probe source" "$SOUT" '.sources==["https://lists.example.com/***"]'
end
begin "status/subscriptions-last-fetch"
expect_jq "sp: id, name, last fetch, last success, result, its own expiry/quota/interval" "$SOUT" \
	'.subscriptions[0] | .id=="sp" and .name=="My provider" and .kind=="primary" and .url=="https://sub.example.com/***" and .last_fetch_at==1700000100 and .updated_at==1700000000 and .result=="cached" and (.key|length)==12 and .expire==1893456000 and .used==300 and .total==1000 and .update_interval==43200 and .web_page=="https://sub.example.com/***" and .mode=="all" and .enabled==true'
expect_jq "se never fetched -> null, not invented; name from its base64 title" "$SOUT" '.subscriptions[1] | .kind=="extra" and .last_fetch_at==null and .result==null and .updated_at==null and .name=="Title E" and .expire==null and .used==null'
expect_jq "ss: pick mode, 2 picked, 1 of them not in the pool, 1 node in the pool" "$SOUT" '.subscriptions[2] | .kind=="pick" and .mode=="pick" and .picked==2 and .pick_missing==1 and .in_pool==1'
expect_jq "legacy quota of the primary" "$SOUT" '.subscription.expire==1893456000 and .subscription.used==300 and .subscription.total==1000'
end
begin "status/build-busy-pause-progress"
expect_jq "build result passed through" "$SOUT" '.build.ok==true and .build.nodes==300 and .build.dropped[0].reason=="bad_port"'
expect_jq "busy: ping (live owner) yes, speedtest (dead owner) no" "$SOUT" '.busy.ping==true and .busy.speedtest==false and .busy.fetch==false and (.busy|keys)==["build","fetch","nodecheck","ping","probe","speedtest","unlock"]'
expect_jq "ping progress" "$SOUT" '.ping_progress.done==5 and .ping_progress.total==300'
expect_jq "Telegram pause" "$SOUT" '.paused==true'
end
begin "status/node-source-from-the-build"
expect_jq "Node003 manual, Node002 from the pick subscription (legacy group imported), Node001 subscription" "$SOUT" \
	'(.nodes[] | select(.tag=="Node003") | .source=="manual" and .group=="manual" and .sub==null) and (.nodes[] | select(.tag=="Node002") | .source=="subscription" and .sub=="ss" and .group=="imported") and (.nodes[] | select(.tag=="Node001") | .source=="subscription" and .sub=="sp" and .group=="subscription")'
end
measure_status
begin "status/flags-clear-after"   # the same fields answer "no" once the files are gone
expect_jq "not busy, not paused" "$SOUT" '.busy.ping==false and .paused==false'
end

# ---- stage 6: favourites, hidden, preferred, the stores by id + the older screens' tag fields ----
ID3=$(jq -r '.[2].id' "$FXS/nodes.json")
jq -nc --arg a "$ID1" '{($a): {tag: "Node001", link: "vless://x", active: false, auto: false, type: "vless", server: "10.0.1.7", port: 443},
	"aaaaaaaaaaaa": {tag: "Gone-Fav", link: "vless://y", active: false, auto: true, type: "vless", server: "203.0.113.200", port: 443}}' > /etc/vpnpool/favorites.map.json
uci set vpnpool.main.preferred_node="$ID2"
uci add_list vpnpool.main.hidden="$ID3"; uci add_list vpnpool.main.hidden=bbbbbbbbbbbb
uci add_list vpnpool.main.auto_member="$ID1"; uci add_list vpnpool.main.keep_auto="$ID2"
# ui1 review 2: excluded ids — a real id and junk; only the id may come out
uci add_list vpnpool.main.auto_exclude="$ID2"; uci add_list vpnpool.main.auto_exclude=not-an-id; uci commit vpnpool
jq -nc --arg c "$ID3" '[{id: $c, tag: "Node003-hidden", type: "vless", server: "10.0.3.7", port: 443, src: "sub:sp"}]' > /tmp/vpnpool/hidden.json
jq -nc --arg a "$ID1" '[$a]' > /tmp/vpnpool/.dead_ids.json
jq -nc --arg a "$ID1" '{($a): {youtube: true}}' > /etc/vpnpool/unlock.map.json
measure_status
begin "status/favorites-hidden-preferred"
expect_jq "node marks by id: favourite, preferred, dead, kept, unlock" "$SOUT" \
	'(.nodes[0] | .favorite==true and .saved==true and .dead==true and .preferred==false and .unlock.youtube==true) and (.nodes[1] | .preferred==true and .kept==true and .favorite==false)'
expect_jq "favorites: the one in the pool and the one no source has" "$SOUT" \
	"(.favorites|length)==2 and (.favorites[] | select(.id==\"$ID1\") | .in_pool==true and .auto==false) and (.favorites[] | select(.id==\"aaaaaaaaaaaa\") | .in_pool==false and .auto==true and .tag==\"Gone-Fav\")"
expect_jq "legacy saved_inactive = the favourite no source has" "$SOUT" '.saved_inactive==[{id:"aaaaaaaaaaaa", tag:"Gone-Fav", server:"203.0.113.200", port:443}]'
expect_jq "hidden: the one a source still has (name) + the one none has" "$SOUT" \
	"(.hidden|length)==2 and .hidden[0].id==\"$ID3\" and .hidden[0].tag==\"Node003-hidden\" and .hidden[0].in_source==true and .hidden[0].sub==\"sp\" and .hidden[1]=={id:\"bbbbbbbbbbbb\", tag:null, in_source:false}"
expect_jq "preferred: id + its tag in this build" "$SOUT" ".preferred=={id:\"$ID2\", tag:\"Node002\", in_pool:true} and .settings.preferred_id==\"$ID2\""
expect_jq "the stores by id" "$SOUT" ".dead_ids==[\"$ID1\"] and .kept_ids==[\"$ID2\"] and .auto_member_ids==[\"$ID1\"]"
expect_jq "excluded ids: the id only (junk dropped), not the member list" "$SOUT" ".auto_exclude_ids==[\"$ID2\"]"
expect_jq "the older screens' fields in tags (they compare tags)" "$SOUT" \
	'.dead_nodes==["Node001"] and .kept_nodes==["Node002"] and .auto_members==["Node001"] and .settings.preferred_node=="Node002" and .settings.selected_node==""'
end
rm -f /etc/vpnpool/favorites.map.json /tmp/vpnpool/hidden.json /tmp/vpnpool/.dead_ids.json /etc/vpnpool/unlock.map.json
uci -q delete vpnpool.main.preferred_node; uci -q delete vpnpool.main.hidden; uci -q delete vpnpool.main.auto_member; uci -q delete vpnpool.main.keep_auto; uci -q delete vpnpool.main.auto_exclude; uci commit vpnpool

# a node waiting for the engine (deferred.json) carries the same marks (by id) and its source
jq -nc '[{id: "cccccccccccc", tag: "AWG-wait", type: "awg", server: "198.51.100.9", port: 51820, _src: "awg", reason: "engine_missing"}]' > /tmp/vpnpool/deferred.json
jq -nc '{cccccccccccc: {tag: "AWG-wait", link: null, active: false, auto: false}}' > /etc/vpnpool/favorites.map.json
uci set vpnpool.main.preferred_node=cccccccccccc; uci commit vpnpool
measure_status
begin "status/deferred-node-marks-and-source"
expect_jq "listed deferred, AWG group, favourite + preferred by id" "$SOUT" \
	'(.nodes[] | select(.id=="cccccccccccc") | .deferred==true and .reason=="engine_missing" and .source=="awg" and .group=="amneziawg" and .favorite==true and .preferred==true)'
expect_jq "the favourite counts as in the pool (it is listed), preferred resolves its tag" "$SOUT" \
	'(.favorites[0] | .id=="cccccccccccc" and .in_pool==true) and .preferred.tag=="AWG-wait" and .saved_inactive==[]'
end
rm -f /tmp/vpnpool/deferred.json /etc/vpnpool/favorites.map.json; uci -q delete vpnpool.main.preferred_node; uci commit vpnpool

# the migration report: what it could not match is listed, a link only masked
jq -nc '{at: 1, from: "1.x", to: "2", backup: "/etc/vpnpool/backup-1.x/x.tar.gz", moved: {}, unmatched: [{store: "auto_member", value: "Ghost-Node"},
	{store: "excluded_node", value: "vless://SECRET-UUID@203.0.113.5:443#X"}]}' > /etc/vpnpool/migration.json
measure_status
begin "status/migration-unmatched-listed-masked"
expect_jq "listed" "$SOUT" '.migration.from=="1.x" and .migration.unmatched==[{store:"auto_member", value:"Ghost-Node"},{store:"excluded_node", value:"vless://203.0.113.5:443/***"}]'
expect_eq "the credential not in status" "$(printf '%s' "$SOUT" | gcount SECRET-UUID)" 0
end
rm -f /etc/vpnpool/migration.json

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
jq -nc --arg a "$(jq -r '.[0].id' "$FXS/nodes.json")" '{($a): {tag: "Node001", link: "vless://x", active: false, auto: false}}' > /etc/vpnpool/favorites.map.json
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
expect_jq "the favourites were read (positive control)" "$(cat "$FXS/p1.json")" '(.nodes[] | select(.tag=="Node001") | .favorite)==true'
end
rm -f /etc/vpnpool/favorites.map.json
# temp-file names of processes that start together must differ (common.uc uniq): ucode's rand()
# gave two of eight parallel processes the same number, and two overlapping polls of 1.x-stage-3
# shared one archive temp file (one poll deleted it under the other -> "saved" lost, ~1 in 6);
# write_atomic and the API's temp files still rely on it
printf "import { uniq } from '/usr/libexec/vpnpool/common.uc';\nprint(uniq(), '\\\\n');\n" > "$FXS/uniq.uc"
: > "$FXS/uniq.out"
_up=""
for i in $(seq 1 40); do ucode "$FXS/uniq.uc" >> "$FXS/uniq.out" 2>/dev/null & _up="$_up $!"; done
for p in $_up; do wait "$p"; done   # these PIDs only (a bare wait would wait for the fake daemon)
begin "status/temp-names-unique-across-processes"
expect_eq "40 names written" "$(grep -c . "$FXS/uniq.out")" 40
expect_eq "40 different" "$(sort -u "$FXS/uniq.out" | grep -c .)" 40
end
daemon_stop

# ---- ui2: the tunnel state, its exit and the last check of each node (Overview / Nodes) ----
# tunnel <- /tmp/vpnpool/.tunnel (vpnpoold watchdog), exit <- exit.json (exitip.sh) only while its
# node is the active one, node.check <- .deadstrikes (nodecheck.sh: id, fails in a row, at, hosts)
ID1=$(jq -r '.[0].id' "$FXS/nodes.json"); ID2=$(jq -r '.[1].id' "$FXS/nodes.json"); ID3=$(jq -r '.[2].id' "$FXS/nodes.json")
ui2_files() {   # <exit node>
	echo 'up 1700000000' > /tmp/vpnpool/.tunnel
	jq -nc --arg n "$1" '{ok: true, ip: "198.51.100.7", country: "DE", node: $n, at: 1700000100}' > /tmp/vpnpool/exit.json
	printf '%s\t3\t1700000200\twww.youtube.com,chat.example\n%s\t0\t1700000200\t\n%s\t2\nnot-an-id\t5\t1\tx\n' "$ID1" "$ID2" "$ID3" > /tmp/vpnpool/.deadstrikes
}
daemon_start; mock_on
mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXS/proxies.json"
mock_rule 'GET http://127.0.0.1:9091/connections' 200 "$FXS/conns.json"
ui2_files Node001
measure_status
begin "status/tunnel-exit-and-node-checks"
expect_jq "positive control: daemon up, auto on Node001" "$SOUT" '.running==true and .auto_now=="Node001"'
expect_jq "tunnel state + since" "$SOUT" '.tunnel=={"state":"up","since":1700000000}'
expect_jq "exit of the active node" "$SOUT" '.exit.ok==true and .exit.ip=="198.51.100.7" and .exit.country=="DE" and .exit.node=="Node001" and .exit.at==1700000100'
expect_jq "a failing node: fails in a row, when, which hosts" "$SOUT" "(.nodes[] | select(.id==\"$ID1\") | .check)=={\"fails\":3,\"at\":1700000200,\"failed\":[\"www.youtube.com\",\"chat.example\"]}"
expect_jq "a passing node" "$SOUT" "(.nodes[] | select(.id==\"$ID2\") | .check)=={\"fails\":0,\"at\":1700000200,\"failed\":[]}"
expect_jq "a line of the older two-column form" "$SOUT" "(.nodes[] | select(.id==\"$ID3\") | .check)=={\"fails\":2,\"at\":null,\"failed\":[]}"
expect_jq "a node never checked: null" "$SOUT" '(.nodes[3].check)==null'
end
begin "status/tunnel-exit-checks-at-most-15-processes"
expect_le "processes per poll" "$SPROCS" 15
end
# the exit belongs to another node (the active one changed since): not shown
ui2_files Node002
measure_status
begin "status/exit-of-another-node-not-shown"
expect_jq "tunnel still shown (positive control)" "$SOUT" '.tunnel.state=="up"'
expect_jq "no exit" "$SOUT" '.exit==null'
end
# a failed lookup / a broken tunnel file
ui2_files Node001
jq -nc '{ok: false, ip: "", country: "", node: "Node001", at: 1}' > /tmp/vpnpool/exit.json
echo 'sideways 12' > /tmp/vpnpool/.tunnel
measure_status
begin "status/failed-exit-lookup-and-unknown-tunnel-state"
expect_jq "node checks still read (positive control)" "$SOUT" "(.nodes[] | select(.id==\"$ID1\") | .check.fails)==3"
expect_jq "the failure of this node's lookup is said (not 'not looked up yet')" "$SOUT" '.exit.ok==false and .exit.ip==null and .exit.node=="Node001"'
expect_jq "unknown state -> null" "$SOUT" '.tunnel==null'
end
# the daemon is down: the files of a killed run say nothing
daemon_stop
ui2_files Node001
measure_status
begin "status/daemon-down-no-tunnel-no-exit"
expect_jq "not running (positive control)" "$SOUT" '.running==false and (.nodes|length)==300'
expect_jq "no tunnel, no exit" "$SOUT" '.tunnel==null and .exit==null'
end
rm -f /tmp/vpnpool/.tunnel /tmp/vpnpool/exit.json /tmp/vpnpool/.deadstrikes
