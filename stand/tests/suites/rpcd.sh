# suite: rpcd — every ubus method of the ACL, called through the REAL ubus -> rpcd -> plugin
# (sourced by run.sh). Per method, up to three cases:
#   ok        valid input, fake vpnpoold running: reply is an object, side effect landed,
#             and the expected signal (USR1 rebuild / USR2 refetch) reached the daemon;
#   bad       invalid input: the reply must say so (.ok==false) — stage 3 made every method
#             answer the truth (not_found / invalid / disabled / ..., ROADMAP 3.1, 3.3);
#   nodaemon  valid input, NO daemon: still an object; a method whose effect needs the
#             daemon must report it (.daemon=="not_running", ROADMAP 3.1).
# A final coverage case fails if an ACL method has no case here or isn't served by rpcd.

ACL="$REPO/package/luci-app-vpnpool/files/usr/share/rpcd/acl.d/luci-app-vpnpool.json"
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
L1="vless://$U@203.0.113.71:443?security=tls&sni=a.example#Node1"
L2="vless://$U@203.0.113.72:443?security=tls&sni=a.example#Node2"
FXR="$T_STATE/rpcd"; mkdir -p "$FXR"
TESTED="$FXR/tested"; : > "$TESTED"

# /etc/init.d stubs: procd isn't running in the stand; record what the plugin asked for.
INITD_LOG="$FXR/initd.calls"
for svc in vpnpool cron; do
	printf '#!/bin/sh\necho "%s $*" >> %s\n' "$svc" "$INITD_LOG" > /etc/init.d/$svc
	# like procd: a reload with enabled=0 stops the daemon instance (TERM)
	[ "$svc" = vpnpool ] && cat >> /etc/init.d/$svc <<'EOF'
[ "$1" = reload ] && [ "$(uci -q get vpnpool.main.enabled)" = 0 ] && kill "$(cat /var/run/vpnpool.pid 2>/dev/null)" 2>/dev/null
EOF
	echo 'exit 0' >> /etc/init.d/$svc
	chmod +x /etc/init.d/$svc
done

ulist() { uci -q get "$1" | tr ' ' '\n' | grep -v '^$'; }
jarg() { jq -nc "$@"; }   # build JSON args safely: jarg --arg l "$L1" '{link:$l}'

fx_nodes() {   # the last build: Node1 (a manual link) + Node2 (from subscription sp), ids, links.json
	printf '%s\n%s\n' "$L1" "$L2" > "$FXR/links.txt"
	ucode /usr/libexec/vpnpool/parser.uc --with-id "$FXR/links.txt" \
		| jq -c 'map(._src = (if .tag == "Node1" then "manual" else "sub:sp" end))' > /tmp/vpnpool/nodes.json
	ID1=$(jq -r '.[0].id' /tmp/vpnpool/nodes.json); ID2=$(jq -r '.[1].id' /tmp/vpnpool/nodes.json)
	jq -nc --arg a "$L1" --arg b "$L2" --arg i "$ID1" --arg j "$ID2" \
		'[{tag:"Node1",id:$i,link:$a,src:"manual"},{tag:"Node2",id:$j,link:$b,src:"sub:sp"}]' > /tmp/vpnpool/links.json
	cp /tmp/vpnpool/links.json /etc/vpnpool/links.json
}
# Node1 as a favourite (archived; <active> true = it joins the pool from the archive)
fx_fav() { fx_nodes; jq -nc --arg a "$L1" --arg i "$ID1" --argjson act "${1:-false}" '{($i): {tag:"Node1", link:$a, active:$act, auto:false}}' > /etc/vpnpool/favorites.map.json; }
subs_tsv() { ucode /usr/libexec/vpnpool/model.uc subs 2>/dev/null; }   # id \t enabled \t mode \t url

# M <method> <ok-args> <signal|-> <ok-xfail|-> <ok-check-fn|-> <bad-args|-> <bad-xfail|->
# Optional per-method hooks: s_<method> (setup, both cases), b_<method> (extra setup for bad).
# Invariants ("ubus rc 0", "reply is an object") never sit inside an xfail case: when the
# semantic case is xfail they get their own plain case "<kind>-reply", so a regression there
# is a FAIL, not hidden as XFAIL.
base_checks() { expect_eq "ubus rc" "$RC" 0; expect_jq "reply is an object" "$R" 'type=="object"'; }
reply_case() {   # <case-id> — invariants as a separate non-xfail case
	begin "$1"; base_checks; end
}
M() {
	_m=$1; _ok=$2; _sig=$3; _okx=$4; _chk=$5; _bad=$6; _badx=$7
	[ "$_okx" = - ] && _okx=""; [ "$_badx" = - ] && _badx=""
	echo "$_m" >> "$TESTED"
	# ok
	reset_state; command -v "s_$_m" >/dev/null 2>&1 && "s_$_m"; daemon_start
	rcall "$_m" "$_ok"
	[ -n "$_okx" ] && reply_case "rpcd/$_m/ok-reply"
	begin "rpcd/$_m/ok"
	[ -z "$_okx" ] && base_checks
	expect_jq "reply does not report an error" "$R" '(.ok != false) and (has("error")|not)'
	expect_jq "reply shape {ok, code, daemon} (ROADMAP 3.1)" "$R" '(.ok|type)=="boolean" and (.code|type)=="string" and (.daemon=="signalled" or .daemon=="not_running" or .daemon=="n/a")'
	[ "$_sig" != - ] && expect_true "daemon got $_sig" [ "$(signals_seen "$_sig")" -ge 1 ]
	[ "$_chk" != - ] && "$_chk"
	end "$_okx"
	# bad
	if [ "$_bad" != - ]; then
		reset_state; command -v "s_$_m" >/dev/null 2>&1 && "s_$_m"
		command -v "b_$_m" >/dev/null 2>&1 && "b_$_m"
		daemon_start
		rcall "$_m" "$_bad"
		[ -n "$_badx" ] && reply_case "rpcd/$_m/bad-input-reply"
		begin "rpcd/$_m/bad-input"
		[ -z "$_badx" ] && base_checks
		expect_jq "reply says ok:false" "$R" '.ok==false'
	expect_jq "with a machine code (and .error = code)" "$R" '(.code|type)=="string" and (.code|length)>0 and .error==.code'
		end "$_badx"
	fi
	# nodaemon
	reset_state; command -v "s_$_m" >/dev/null 2>&1 && "s_$_m"; daemon_stop
	rcall "$_m" "$_ok"
	reply_case "rpcd/$_m/no-daemon"
	if [ "$_sig" != - ]; then
		begin "rpcd/$_m/no-daemon-reported"
		expect_jq "reply reports the daemon is not running" "$R" '.daemon=="not_running"'
		end
	fi
}

# ---------------- read methods ----------------
c_status() { expect_jq "status shape" "$R" '(.enabled|type=="boolean") and (.nodes|type=="array") and (.settings|type=="object")'; }
M status '{}' - - c_status - -

c_diag() { expect_jq "diag shape" "$R" '(.service|type=="object") and (.resources.singbox_version|length>0)'; }
M diag '{}' - - c_diag - -

s_conntest() { mock_on; echo '{"ip":"203.0.113.5","country_iso":"DE"}' > "$FXR/ip.json"; mock_rule 'P GET https://ifconfig.co/json' 200 "$FXR/ip.json"; }
b_conntest() { mock_on; }   # every IP-echo endpoint unreachable
c_conntest() { expect_jq "exit ip" "$R" '.ok==true and .ip=="203.0.113.5" and .country=="DE"'; }
M conntest '{}' - - c_conntest '{}' -

s_leases() { printf '1700000000 aa:bb:cc:dd:ee:01 192.168.1.10 phone *\n1700000000 aa:bb:cc:dd:ee:02 192.168.1.11 * *\n' > /tmp/dhcp.leases; }
c_leases() { expect_jq "two leases" "$R" '(.leases|length)==2 and .leases[0].host=="phone" and .leases[1].host==""'; }
M leases '{}' - - c_leases - -

c_export() { expect_jq "uci export" "$R" '.config|contains("config vpnpool")'; }
M export '{}' - - c_export - -

s_node_link() { fx_nodes; }
c_node_link() { expect_jq "link" "$R" ".ok==true and .link==$(jarg --arg l "$L1" '$l')"; }
M node_link '{"tag":"Node1"}' - - c_node_link '{"tag":"Nope"}' -

s_export_nodes() { fx_nodes; uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; }
c_export_nodes() { expect_jq "manual links" "$R" ".links==[$(jarg --arg l "$L1" '$l')]"; }
M export_nodes '{"scope":"manual"}' - - c_export_nodes '{"scope":"zzz"}' -

c_idle() { expect_jq "idle" "$R" '.running==false'; }
M unlock_result '{}' - - c_idle - -
M probe_result '{}' - - c_idle - -
M speedtest_result '{}' - - c_idle - -

# ---------------- write methods ----------------
c_set_enabled() {
	expect_eq "uci enabled" "$(uci -q get vpnpool.main.enabled)" 0
	# "off" = enabled=0 + reload (procd stops only the daemon; the Telegram bot stays) — never
	# stop/disable, which would also kill the bot (and keep it off after a reboot)
	expect_true "daemon stopped via reload" grep -q '^vpnpool reload' "$INITD_LOG"
	expect_eq "no stop / disable (the bot must survive)" "$(gcount -e '^vpnpool stop' -e '^vpnpool disable' "$INITD_LOG")" 0
}
s_set_enabled() { : > "$INITD_LOG"; uci set vpnpool.main.enabled=1; uci commit vpnpool; }
M set_enabled '{"enabled":false}' - - c_set_enabled '{"enabled":"maybe"}' -

# "Connect" (ROADMAP 9.5): the soft preferred node by id + the live selector; no hard pin
s_select() { fx_nodes; mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204; }
c_select() {
	expect_eq "preferred_node = Node1's id" "$(uci -q get vpnpool.main.preferred_node)" "$ID1"
	expect_jq "applied live" "$R" '.code=="applied"'
	expect_eq "no hard pin stored" "$(uci -q get vpnpool.main.selected_node)" ''
}
M select '{"tag":"Node1"}' - - c_select '{"tag":"Nope"}' -

s_refresh() { : > "$INITD_LOG"; uci set vpnpool.main.enabled=1; uci commit vpnpool; }
c_refresh() { expect_eq "no full service restart" "$(gcount restart "$INITD_LOG")" 0; }
M refresh '{}' USR2 - c_refresh - -

s_ping() {
	fx_nodes; uci set vpnpool.main.dead_filter=0; uci commit vpnpool
	mock_on; echo '{"delay":123}' > "$FXR/delay.json"
	mock_rule 'GET http://127.0.0.1:9091/proxies/*/delay*' 200 "$FXR/delay.json"
}
c_ping() {
	expect_jq "started" "$R" '.ok==true and .code=="started"'
	_i=0; while [ $_i -lt 200 ]; do jq -e '.running==false' /tmp/vpnpool/.ping-progress.json >/dev/null 2>&1 && break; msleep 100; _i=$((_i+1)); done
	expect_jq "progress file: finished, 2 of 2, both answered" "$(cat /tmp/vpnpool/.ping-progress.json 2>/dev/null)" '.running==false and .done==2 and .total==2 and .alive==2'
	expect_eq "one delay probe per node" "$(mock_calls '/delay?')" 2
}
M ping '{}' - - c_ping - -

# legacy: the first subscription that takes every node ("primary") — a section of its own
c_set_url() { expect_eq "a subscription section" "$(subs_tsv | cut -f3,4)" "all	https://sub.example.com/s"; }
M set_url '{"url":"https://sub.example.com/s"}' USR2 - c_set_url '{"url":"ftp://bad url"}' -

s_del_subscription() { sub_section sp 'https://sub.example.com/s'; }
c_del_subscription() { expect_eq "no subscription left" "$(subs_tsv)" ''; }
M del_subscription '{}' USR1 - c_del_subscription - -


s_del_source() { sub_section ss 'https://src.example.com/l' pick; }
c_del_source() { expect_eq "the pick subscription removed" "$(subs_tsv)" ''; }
M del_source '{"url":"https://src.example.com/l"}' USR1 - c_del_source '{"url":"https://unknown.example.com/"}' -

s_probe_source() { mock_on; printf '%s\n%s\n' "$L1" "$L2" > "$FXR/src.txt"; mock_rule 'GET https://src.example.com/l' 200 "$FXR/src.txt"; }
c_probe_source() {
	expect_jq "started" "$R" '.started==true'
	_i=0; while [ $_i -lt 300 ]; do rcall probe_result; printf '%s' "$R" | jq -e '.running==false' >/dev/null 2>&1 && break; msleep 100; _i=$((_i+1)); done
	expect_jq "probe_result lists both nodes" "$R" '.running==false and .total==2 and (.nodes|length)==2'
}
M probe_source '{"url":"https://src.example.com/l"}' - - c_probe_source '{"url":""}' -

# the picks of the probe dialog -> a subscription in "pick" mode taking exactly those ids
s_import_select() { fx_nodes; jq -nc --arg a "$L1" --arg b "$L2" --arg i "$ID1" --arg j "$ID2" '{url:"https://src.example.com/l",nodes:[{i:0,id:$i,link:$a,tag:"Node1"},{i:1,id:$j,link:$b,tag:"Node2"}]}' > /tmp/vpnpool/.probe-cache.json; }
c_import_select() {
	expect_eq "a pick subscription for the URL" "$(subs_tsv | cut -f2-4)" "1	pick	https://src.example.com/l"
	_sid=$(subs_tsv | cut -f1)
	expect_eq "picks = Node1's id" "$(ulist "vpnpool.$_sid.pick")" "$ID1"
	expect_jq "count" "$R" '.count==1'
}
M import_select '{"url":"https://src.example.com/l","idx":[0]}' USR2 - c_import_select '{"url":"https://other.example.com/","idx":[0]}' -

c_add_node() { expect_eq "manual_node" "$(ulist vpnpool.main.manual_node)" "$L1"; }
M add_node "$(jarg --arg l "$L1" '{link:$l}')" USR1 - c_add_node '{"link":"this is not a node"}' -

s_del_node() { uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; }
c_del_node() { expect_eq "manual_node empty" "$(ulist vpnpool.main.manual_node)" ''; }
M del_node "$(jarg --arg l "$L1" '{link:$l}')" USR1 - c_del_node '{"link":"vless://nope@1.1.1.1:1#x"}' -

c_import_nodes() { expect_jq "added 2" "$R" '.added==2'; expect_eq "manual_node count" "$(ulist vpnpool.main.manual_node | wc -l)" 2; }
M import_nodes "$(jarg --arg t "$L1
$L2" '{text:$t}')" USR1 - c_import_nodes '{"text":"hello world"}' -

s_delete_node() { fx_nodes; uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; }
c_delete_node() { expect_eq "manual_node empty" "$(ulist vpnpool.main.manual_node)" ''; expect_jq "pruned from nodes.json" "$(cat /tmp/vpnpool/nodes.json)" 'map(.tag)==["Node2"]'; }
M delete_node '{"tag":"Node1"}' USR1 - c_delete_node '{"tag":"Nope"}' -

s_delete_nodes() { fx_nodes; uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; }
c_delete_nodes() {
	expect_eq "the manual link removed" "$(ulist vpnpool.main.manual_node)" ''
	expect_eq "the subscription node hidden (its source would bring it back)" "$(ulist vpnpool.main.hidden)" "$ID2"
	expect_jq "two deleted" "$R" '.deleted==2 and .missing==[]'
}
M delete_nodes '{"tags":["Node1","Node2"]}' USR1 - c_delete_nodes '{"tags":["Nope"]}' -

s_restore_node() { fx_nodes; jq -nc --arg i "$ID1" '[$i]' > /tmp/vpnpool/.dead_ids.json; }
c_restore_node() { expect_eq "keep_auto = the id" "$(ulist vpnpool.main.keep_auto)" "$ID1"; expect_jq "dead set pruned" "$(cat /tmp/vpnpool/.dead_ids.json)" '.==[]'; }
M restore_node '{"tag":"Node1"}' USR1 - c_restore_node '{"tag":"Nope"}' -

s_refilter_node() { fx_nodes; uci add_list vpnpool.main.keep_auto="$ID1"; uci commit vpnpool; }
c_refilter_node() { expect_eq "keep_auto empty" "$(ulist vpnpool.main.keep_auto)" ''; }
M refilter_node '{"tag":"Node1"}' USR1 - c_refilter_node '{"tag":"Nope"}' -

# favourites (ROADMAP 9.3; the legacy names save_node / unsave_node / activate_saved /
# deactivate_saved act on them): by id, with the node's link
s_save_node() { fx_nodes; }
c_save_node() { expect_true "a favourite with the link" jq -e --arg i "$ID1" --arg l "$L1" '.[$i].link==$l and .[$i].active==false and .[$i].auto==false and .[$i].tag=="Node1"' /etc/vpnpool/favorites.map.json; }
M save_node '{"tag":"Node1"}' - - c_save_node '{"tag":"Nope"}' -

s_unsave_node() { fx_fav; }
c_unsave_node() { expect_true "no favourite left" jq -e '.==({})' /etc/vpnpool/favorites.map.json; }
M unsave_node '{"tag":"Node1"}' - - c_unsave_node '{"tag":"Nope"}' -

s_activate_saved() { fx_fav; }
c_activate_saved() { expect_true "the favourite joins the pool from the archive" jq -e --arg i "$ID1" '.[$i].active==true' /etc/vpnpool/favorites.map.json; }
M activate_saved '{"tag":"Node1"}' USR1 - c_activate_saved '{"tag":"Nope"}' -

s_deactivate_saved() { fx_fav true; }
c_deactivate_saved() { expect_true "back to the archive only" jq -e --arg i "$ID1" '.[$i].active==false' /etc/vpnpool/favorites.map.json; }
M deactivate_saved '{"tag":"Node1"}' USR1 - c_deactivate_saved '{"tag":"Nope"}' -

s_add_sub() { mock_on; printf '%s\n%s\n' "$L1" "$L2" > "$FXR/sub.txt"; mock_rule 'GET https://extra.example.com/x' 200 "$FXR/sub.txt"; }
b_add_sub() { mock_on; mock_rule 'GET https://extra.example.com/x' 500; }
c_add_sub() { expect_jq "fetched 2" "$R" '.fetched==2'; expect_eq "a subscription section" "$(subs_tsv | cut -f2-4)" "1	all	https://extra.example.com/x"; }
M add_sub '{"url":"https://extra.example.com/x"}' USR2 - c_add_sub '{"url":"https://extra.example.com/x"}' -

s_del_sub() { sub_section se 'https://extra.example.com/x'; }
c_del_sub() { expect_eq "no subscription left" "$(subs_tsv)" ''; }
M del_sub '{"url":"https://extra.example.com/x"}' USR1 - c_del_sub '{"url":"https://unknown.example.com/"}' -

s_set_schedule() { mkdir -p /etc/crontabs; : > /etc/crontabs/root; }
c_set_schedule() {
	expect_eq "sched_on" "$(uci -q get vpnpool.main.sched_on)" '07:00'
	expect_eq "crontab start job" "$(gcount '^0 7 \* \* \* /usr/libexec/vpnpool/power.sh on$' /etc/crontabs/root)" 1
}
M set_schedule '{"enabled":true,"on":"07:00","off":"23:30","refresh":""}' - - c_set_schedule '{"enabled":true,"on":"25:99","off":"","refresh":""}' -

s_unlock() { fx_nodes; }
c_started() { expect_jq "started in background" "$R" '.started==true'; }
M unlock '{"tag":"Node1"}' - - c_started '{"tag":""}' -

c_add_auto_domain() { expect_eq "auto_domain" "$(ulist vpnpool.routing.auto_domain)" example.com; }
M add_auto_domain '{"domain":"https://Example.COM/path"}' USR1 - c_add_auto_domain '{"domain":"not a domain!"}' -

s_del_auto_domain() { uci add_list vpnpool.routing.auto_domain=example.com; uci commit vpnpool; }
c_del_auto_domain() { expect_eq "auto_domain empty" "$(ulist vpnpool.routing.auto_domain)" ''; }
M del_auto_domain '{"domain":"example.com"}' USR1 - c_del_auto_domain '{"domain":"unknown.example"}' -

s_run_adaptive() { uci set vpnpool.main.adaptive_routing=1; uci commit vpnpool; }
b_run_adaptive() { uci set vpnpool.main.adaptive_routing=0; uci commit vpnpool; }
M run_adaptive '{}' - - c_started '{}' -

c_set_domains() { expect_eq "domains" "$(ulist vpnpool.routing.domain | tr '\n' ' ')" 'a.example b.example '; }
M set_domains '{"domains":["a.example","b.example"]}' USR1 - c_set_domains '{"domains":["bad domain!"]}' -

c_set_communities() { expect_eq "communities" "$(ulist vpnpool.routing.community)" telegram; }
M set_communities '{"communities":["telegram"]}' USR1 - c_set_communities '{"communities":["no_such_list"]}' -

c_set_option() { expect_eq "failover_interval" "$(uci -q get vpnpool.main.failover_interval)" 120; }
M set_option '{"name":"failover_interval","value":"120"}' USR1 - c_set_option '{"name":"no_such_option","value":"1"}' -

c_set_clients() {
	expect_eq "client_mode" "$(uci -q get vpnpool.main.client_mode)" include
	expect_eq "client" "$(ulist vpnpool.main.client)" 192.168.1.10
	expect_eq "client_dev" "$(ulist vpnpool.main.client_dev)" 'aa:bb:cc:dd:ee:ff'
}
M set_clients '{"mode":"include","clients":["192.168.1.10"],"devices":["aa:bb:cc:dd:ee:ff"]}' USR1 - c_set_clients '{"mode":"zzz","clients":["999.1.1.1"],"devices":[]}' -

# the auto-pool members by id; a tag of the last build is mapped to its id (older screens)
s_set_auto_members() { fx_nodes; }
c_set_auto_members() { expect_eq "auto_member = Node1's id" "$(ulist vpnpool.main.auto_member)" "$ID1"; }
M set_auto_members '{"members":["Node1"]}' USR1 - c_set_auto_members '{"members":"Node1"}' -

s_set_preferred() { fx_nodes; }
c_set_preferred() { expect_eq "preferred_node = Node1's id" "$(uci -q get vpnpool.main.preferred_node)" "$ID1"; }
M set_preferred '{"tag":"Node1"}' - - c_set_preferred '{"tag":"Nope"}' -

s_speedtest() { fx_nodes; uci set vpnpool.main.speedtest_min_mem_kb=1; uci commit vpnpool; }
M speedtest '{"tag":"Node1"}' - - c_started '{"tag":""}' -

s_tg_test() {
	uci set vpnpool.main.telegram_token='123:abc'; uci set vpnpool.main.telegram_chat='42'; uci commit vpnpool
	mock_on; echo '{"ok":true}' > "$FXR/tg.json"; mock_rule 'P POST https://api.telegram.org/bot*/sendMessage' 200 "$FXR/tg.json"
}
b_tg_test() { uci -q delete vpnpool.main.telegram_token; uci commit vpnpool; }
M tg_test '{}' - - - '{}' -

# ---------------- stage 3: set_config / analyze / add / backup / restore ----------------
s_set_config() { : > "$INITD_LOG"; }
c_set_config() {
	expect_eq "failover_interval" "$(uci -q get vpnpool.main.failover_interval)" 90
	expect_eq "domains" "$(ulist vpnpool.routing.domain)" a.example
	expect_eq "telegram_chat" "$(uci -q get vpnpool.main.telegram_chat)" 42
	expect_eq "bot reloaded once (chat changed)" "$(gcount '^vpnpool reload' "$INITD_LOG")" 1
	expect_jq "saved, changed fields listed" "$R" '.code=="saved" and (.changed|sort)==["domains","failover_interval","telegram_chat"]'
}
M set_config '{"settings":{"failover_interval":"90","domains":["A.example"],"telegram_chat":"42"}}' USR1 - c_set_config '{"settings":{"failover_interval":"90","domains":["bad domain!"]}}' -

c_analyze() {
	expect_jq "two lines: a new link + a new subscription URL" "$R" \
		'(.items|length)==2 and .items[0].status=="add" and .items[0].kind=="link" and .items[0].name=="Node1" and .items[1].kind=="subscription_url" and .items[1].status=="add"'
	expect_eq "nothing written (manual_node)" "$(ulist vpnpool.main.manual_node)" ''
}
M analyze "$(jarg --arg t "$L1
https://new.example.com/s" '{text:$t}')" - - c_analyze '{"text":5}' -

# the new subscription URL answers the trial download with two nodes (add takes a URL only then)
s_add() { mock_on; printf '%s\n%s\n' "$L1" "$L2" > "$FXR/newsub.txt"; mock_rule 'GET https://new.example.com/s' 200 "$FXR/newsub.txt"; }
c_add() {
	expect_jq "added 2" "$R" '.added==2 and .dup==0 and .failed==[]'
	expect_eq "manual_node" "$(ulist vpnpool.main.manual_node)" "$L1"
	expect_eq "the URL: a subscription section of its own" "$(subs_tsv | cut -f2-4)" "1	all	https://new.example.com/s"
	expect_jq "its id in the reply" "$R" "(.sub_ids|length)==1 and .sub_ids[0]==\"$(subs_tsv | cut -f1)\""
	expect_eq "ONE signal: the refetch (it rebuilds too), no extra rebuild" "$(gcount '^USR1$' "$FAKED_LOG")" 0
}
M add "$(jarg --arg t "$L1
https://new.example.com/s" '{text:$t}')" USR2 - c_add '{"text":"only garbage here"}' -

c_backup() {
	printf '%s' "$R" | jq -r '.data' | base64 -d > "$FXR/bk.tgz" 2>/dev/null
	expect_true "data is a tar.gz" tar -tzf "$FXR/bk.tgz"
	expect_true "it holds the config" sh -c "tar -tzf '$FXR/bk.tgz' | grep -qx etc/config/vpnpool"
	expect_jq "name, size, report" "$R" '(.name|endswith(".tar.gz")) and .size>0 and (.report.settings>0)'
}
M backup '{}' - - c_backup - -

# a real backup of a config with a marker (failover 77) -> restored over the default (60)
reset_state; uci set vpnpool.main.failover_interval=77; uci set vpnpool.main.enabled=1; uci commit vpnpool   # enabled: a reload keeps the daemon
rcall backup
RESTORE_OK=$(printf '%s' "$R" | jq -c '{data, replace_all:true}')
c_restore() {
	expect_eq "marker restored" "$(uci -q get vpnpool.main.failover_interval)" 77
	expect_jq "restored + report" "$R" '.code=="restored" and (.report|type)=="object"'
	expect_true "the state before kept in RAM" [ -s /tmp/vpnpool/pre-restore.tar.gz ]
}
M restore "$RESTORE_OK" USR2 - c_restore '{"data":"bm90IGFuIGFyY2hpdmU=","replace_all":true}' -

reset_state
uci export vpnpool | sed "s/option failover_interval '60'/option failover_interval '77'/" > "$FXR/import.cfg"
IMPORT_ARGS=$(jq -nc --rawfile c "$FXR/import.cfg" '{config:$c}')
c_import() { expect_eq "imported value" "$(uci -q get vpnpool.main.failover_interval)" 77; }
M import "$IMPORT_ARGS" USR2 - c_import '{"config":"this is not a uci file {"}' -

# ---------------- extra cases beyond the ok/bad/no-daemon grid ----------------
reset_state; daemon_start
rcall import_nodes "$(jq -nc --rawfile t "$T_DIR/fixtures/awg/vec/A_modern.txt" '{text:$t}')"
begin "rpcd/import_nodes/vpn-link-awg"
expect_jq "AWG node stored" "$R" '.ok==true and .awg==true'
expect_eq "one .conf in /etc/vpnpool/awg" "$(ls /etc/vpnpool/awg/*.conf 2>/dev/null | wc -l)" 1
end

reset_state; uci set vpnpool.main.telegram_token='123456:SECRET-BOT-TOKEN'; uci commit vpnpool
rcall export
begin "rpcd/export/with-token-works"   # positive control, outside the xfail below
expect_jq "export works" "$R" '.config|contains("config vpnpool")'
end
begin "rpcd/export/telegram-token-masked"
expect_eq "token in export" "$(printf '%s' "$R" | gcount SECRET-BOT-TOKEN)" 0
end

reset_state
# start from 77, NOT the default 60: today's clamp rewrites junk to 60, so an unchanged-60
# check could not tell "rejected" from "silently clamped to the default"
uci set vpnpool.main.failover_interval=77; uci commit vpnpool
rcall set_option '{"name":"failover_interval","value":"abc"}'
begin "rpcd/set_option/non-numeric-rejected"
expect_jq "ok:false" "$R" '.ok==false'
expect_eq "uci keeps the old value" "$(uci -q get vpnpool.main.failover_interval)" 77
end

reset_state
rcall import '{"config":"this is not a uci file {"}'
begin "rpcd/import/garbage-keeps-config"
expect_eq "uci config still has main" "$(uci -q get vpnpool.main.failover_interval)" 60
end
begin "rpcd/import/garbage-rejected"
expect_jq "ok:false" "$R" '.ok==false'
end

# ---------------- stage 2: set_option subscription_interval / telegram reload / refresh ----------------
reset_state; daemon_start
rcall set_option '{"name":"subscription_interval","value":"30m"}'
begin "rpcd/set_option/interval-30m-accepted"   # positive control for the two cases below
expect_jq "ok" "$R" '.ok==true and .code=="saved"'
expect_eq "stored" "$(uci -q get vpnpool.main.subscription_interval)" 30m
end
rcall set_option '{"name":"subscription_interval","value":"5m"}'
begin "rpcd/set_option/interval-below-10m-rejected"
expect_jq "ok:false too_small" "$R" '.ok==false and .code=="too_small"'
expect_eq "uci keeps 30m" "$(uci -q get vpnpool.main.subscription_interval)" 30m
end
rcall set_option '{"name":"subscription_interval","value":"6x"}'
begin "rpcd/set_option/interval-malformed-rejected"
expect_jq "ok:false bad_value" "$R" '.ok==false and .code=="bad_value"'
expect_eq "uci keeps 30m" "$(uci -q get vpnpool.main.subscription_interval)" 30m
end
rcall set_option '{"name":"subscription_ua","value":"x"}'
begin "rpcd/set_option/subscription_ua-removed"
expect_jq "unknown option" "$R" '.ok==false and .code=="unknown_option"'
end

reset_state; daemon_start; : > "$INITD_LOG"
rcall set_option '{"name":"telegram_token","value":"111:NEW"}'
begin "rpcd/set_option/telegram-token-change-reloads-bot"
expect_jq "ok" "$R" '.ok==true'
expect_eq "init.d reload asked once" "$(gcount '^vpnpool reload' "$INITD_LOG")" 1
expect_eq "no restart" "$(gcount restart "$INITD_LOG")" 0
end
: > "$INITD_LOG"
rcall set_option '{"name":"telegram_token","value":"111:NEW"}'
begin "rpcd/set_option/telegram-token-same-value-no-reload"
expect_jq "ok" "$R" '.ok==true'
expect_eq "no reload for an unchanged value" "$(gcount '^vpnpool reload' "$INITD_LOG")" 0
end
for k in telegram_chat telegram_via_proxy; do
	: > "$INITD_LOG"
	rcall set_option "$(jq -nc --arg k "$k" '{name:$k,value:"0"}')"
	begin "rpcd/set_option/$k-change-reloads-bot"
	expect_eq "init.d reload asked" "$(gcount '^vpnpool reload' "$INITD_LOG")" 1
	end
done

reset_state
rcall set_schedule '{"enabled":true,"on":"7:61","off":"","refresh":""}'
begin "rpcd/set_schedule/bad-minute-not-stored"
expect_jq "ok:false bad_time" "$R" '.ok==false and .code=="bad_time"'
expect_eq "uci sched_on untouched" "$(uci -q get vpnpool.main.sched_on)" ''
end

reset_state; daemon_start; : > "$INITD_LOG"; : > /tmp/vpnpool/.routing_paused; uci set vpnpool.main.enabled=1; uci commit vpnpool
rcall set_enabled '{"enabled":true}'
begin "rpcd/set_enabled/on-with-daemon-running-no-restart"
expect_jq "ok" "$R" '.ok==true'
expect_true "daemon re-checks routing (HUP)" [ "$(signals_seen HUP)" -ge 1 ]
expect_eq "no restart / start of a running service" "$(gcount -e restart -e '^vpnpool start' "$INITD_LOG")" 0
expect_true "Telegram pause ended" [ ! -f /tmp/vpnpool/.routing_paused ]
end

# ---------------- stage 3: validation, one signal, secrets, analyze/add, backup/restore ----------------
reset_state; daemon_start; : > "$INITD_LOG"
rcall set_config '{"settings":{"failover_interval":"90","domains":["a.example"]}}'
begin "rpcd/set_config/valid-subset-writes"   # positive control for the all-or-nothing case
expect_jq "saved" "$R" '.ok==true and .code=="saved"'
expect_eq "written" "$(uci -q get vpnpool.main.failover_interval)" 90
end
reset_state; daemon_start
rcall set_config '{"settings":{"failover_interval":"90","domains":["a.example"],"clients":["999.1.1.1"]}}'
begin "rpcd/set_config/all-or-nothing"
expect_jq "invalid + the one bad field named" "$R" '.ok==false and .code=="invalid" and .errors=={"clients[0]":"bad_ipv4"}'
expect_eq "valid failover_interval NOT written" "$(uci -q get vpnpool.main.failover_interval)" 60
expect_eq "valid domains NOT written" "$(ulist vpnpool.routing.domain)" ''
expect_eq "no signal for a refused save" "$(signals_seen USR1)" 0
end

reset_state; daemon_start
rcall set_config "$(jq -nc '{settings:{subscription_interval:"5m", failover_interval:"abc", failover_tolerance:"99999",
	sched_on:"24:00", clients:["10.0.0.300"], client_devices:["aa:bb:cc:dd:ee"], lan_if:"bad if name",
	fwmark:"0xZZ", domains:["ok.example","bad domain"], communities:["telegram","nope"], mode:"zzz",
	auto_switch:"maybe", telegram_token:"no-colon", health_url:"ftp://x", no_such_field:1}}')"
begin "rpcd/set_config/every-check-names-its-code"
expect_jq "field codes" "$R" '.errors == {subscription_interval:"too_small", failover_interval:"bad_value",
	failover_tolerance:"too_large", sched_on:"bad_time", "clients[0]":"bad_ipv4", "client_devices[0]":"bad_mac",
	lan_if:"bad_ifname", fwmark:"bad_mark", "domains[1]":"bad_domain", "communities[1]":"bad_community",
	mode:"bad_value", auto_switch:"bad_value", telegram_token:"bad_token", health_url:"bad_url",
	no_such_field:"unknown_field"}'
expect_eq "nothing written" "$(uci -q get vpnpool.main.subscription_interval)" 6h
end
rcall set_config "$(jq -nc '{settings:{subscription_interval:"10m", failover_tolerance:"5000", sched_on:"23:59",
	clients:["10.0.0.0/24"], client_devices:["AA:BB:CC:DD:EE:FF"], lan_if:"br-lan.10", fwmark:"0x400000",
	communities:["telegram","youtube"], mode:"exclude", log_level:"info", dns_strategy:"ipv4_only", ipv6:"off"}}')"
begin "rpcd/set_config/boundary-values-accepted"   # positive control: the edges of every check pass
expect_jq "saved" "$R" '.ok==true and .code=="saved"'
expect_eq "MAC normalised" "$(ulist vpnpool.main.client_dev)" 'aa:bb:cc:dd:ee:ff'
expect_eq "interval stored" "$(uci -q get vpnpool.main.subscription_interval)" 10m
expect_true "crontab rewritten (sched_on changed)" [ -f /etc/crontabs/root ]
end

reset_state; daemon_start; : > "$INITD_LOG"
rcall set_config '{"settings":{"failover_interval":"90","mode":"exclude","favorites_only":true}}'
begin "rpcd/set_config/one-signal-only"
expect_jq "saved, signalled" "$R" '.ok==true and .daemon=="signalled"'
expect_eq "USR1 (rebuild) once for three rebuild fields" "$(signals_seen USR1)" 1
expect_eq "no refetch" "$(gcount '^USR2$' "$FAKED_LOG")" 0
expect_eq "bot untouched" "$(gcount '^vpnpool reload' "$INITD_LOG")" 0
expect_eq "favourites only stored" "$(uci -q get vpnpool.main.favorites_only)" 1
end
: > "$FAKED_LOG"
rcall set_config '{"settings":{"failover_interval":"90"}}'
begin "rpcd/set_config/unchanged-no-signal"
expect_jq "unchanged" "$R" '.ok==true and .code=="unchanged" and .daemon=="n/a"'
expect_eq "no signal" "$(gcount -e '^USR1$' -e '^USR2$' "$FAKED_LOG")" 0
end

reset_state; daemon_start
uci set vpnpool.main.telegram_token='123456:SECRET-BOT-TOKEN'; uci commit vpnpool; sub_section sp 'https://sub.example.com/s/TOKEN'
rcall status
MTOK=$(printf '%s' "$R" | jq -r '.settings.telegram_token'); MURL=$(printf '%s' "$R" | jq -r '.subscription.url')
rcall set_config "$(jq -nc --arg t "$MTOK" '{settings:{telegram_token:$t, failover_interval:"91"}}')"
begin "rpcd/set_config/masked-token-sent-back-keeps-the-real-one"
expect_eq "status showed it masked" "$MTOK" '123456:***'
expect_jq "saved (the other field)" "$R" '.ok==true and .changed==["failover_interval"]'
expect_eq "real token kept" "$(uci -q get vpnpool.main.telegram_token)" '123456:SECRET-BOT-TOKEN'
end
rcall set_url "$(jq -nc --arg u "$MURL" '{url:$u}')"
begin "rpcd/set_url/masked-url-sent-back-unchanged"
expect_jq "unchanged, no signal" "$R" '.ok==true and .code=="unchanged" and .daemon=="n/a"'
expect_eq "real URL kept" "$(uci -q get vpnpool.sp.url)" 'https://sub.example.com/s/TOKEN'
end
rcall export
begin "rpcd/export/subscription-url-masked"
expect_eq "token path in export" "$(printf '%s' "$R" | gcount 's/TOKEN')" 0
expect_jq "masked line present" "$R" '.config | contains("option url '"'"'https://sub.example.com/***'"'"'")'
end
rcall import "$(printf '%s' "$R" | jq -c '{config}')"
begin "rpcd/import/masked-export-refused"
expect_jq "masked_values" "$R" '.ok==false and .code=="masked_values"'
expect_eq "real token kept" "$(uci -q get vpnpool.main.telegram_token)" '123456:SECRET-BOT-TOKEN'
end

reset_state; daemon_start
sub_section e0 'https://e1.example.com/a/SECRET'
rcall del_sub '{"url":"https://e1.example.com/***"}'
begin "rpcd/del_sub/masked-url-resolved"
expect_jq "deleted" "$R" '.ok==true and .code=="deleted"'
expect_eq "no subscription left" "$(subs_tsv)" ''
end
# two subscriptions on ONE host: the masked form is ambiguous -> refused; the status key picks one
sub_section e1 'https://e1.example.com/a/ONE'; sub_section e2 'https://e1.example.com/b/TWO'
rcall del_sub '{"url":"https://e1.example.com/***"}'
begin "rpcd/del_sub/ambiguous-mask-refused"
expect_jq "ambiguous (not a silent pick of one)" "$R" '.ok==false and .code=="ambiguous"'
expect_eq "both kept" "$(subs_tsv | wc -l)" 2
end
rcall status
K2=$(printf '%s' "$R" | jq -r '.subscriptions[1].key')
rcall del_sub "$(jq -nc --arg k "$K2" '{url:$k}')"
begin "rpcd/del_sub/by-status-key"
expect_jq "deleted" "$R" '.ok==true and .code=="deleted"'
expect_eq "the second one removed" "$(subs_tsv | cut -f4)" 'https://e1.example.com/a/ONE'
end

reset_state
printf "config vpnpool 'main'\n\toption failover_interval '55'\n" > "$FXR/partial.cfg"
rcall import "$(jq -nc --rawfile c "$FXR/partial.cfg" '{config:$c}')"
begin "rpcd/import/partial-config-refused"
expect_jq "incomplete_config" "$R" '.ok==false and .code=="incomplete_config"'
expect_eq "routing section survives" "$(ulist vpnpool.routing.community | head -1)" telegram
expect_eq "main untouched" "$(uci -q get vpnpool.main.failover_interval)" 60
end

# ---- analyze: every status, nothing written ----
reset_state; uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; sub_section sp 'https://sub.example.com/s'
cp /etc/config/vpnpool "$FXR/before.cfg"
L3="vless://$U@203.0.113.73:443?security=tls&sni=a.example#Node3"
L1R="vless://$U@203.0.113.71:443?security=tls&sni=a.example#Renamed"
rcall analyze "$(jarg --arg t "$L1
$L3
$L3
$L1R
https://sub.example.com/s
https://extra.example.com/x
vpn://AAAA
hello world
vless://$U@203.0.113.74:70000?security=tls#BadPort" '{text:$t}')"
begin "rpcd/analyze/statuses"
expect_jq "line 1: same link as a manual node -> dup exists" "$R" '.items[0] | .line==1 and .status=="dup" and .reason=="exists"'
expect_jq "line 2: new -> add, with name/type/server/id" "$R" '.items[1] | .status=="add" and .name=="Node3" and .type=="vless" and .server=="203.0.113.73" and (.id|length)==12'
expect_jq "line 3: repeated in the paste -> dup repeated" "$R" '.items[2] | .status=="dup" and .reason=="repeated"'
expect_jq "line 4: same config under another name -> dup exists" "$R" '.items[3] | .status=="dup" and .reason=="exists"'
expect_jq "line 5: the configured subscription -> dup" "$R" '.items[4] | .kind=="subscription_url" and .status=="dup"'
expect_jq "line 6: new URL -> add, shown masked" "$R" '.items[5] | .kind=="subscription_url" and .status=="add" and .name=="https://extra.example.com/***"'
expect_jq "line 7: unreadable vpn:// -> awg skip decode_failed" "$R" '.items[6] | .line==7 and .kind=="awg" and .status=="skip" and .reason=="decode_failed"'
expect_jq "line 8: junk -> unknown skip" "$R" '.items[7] | .kind=="unknown" and .status=="skip" and .reason=="not_a_link"'
expect_jq "line 9: bad port -> skip with the parser reason" "$R" '.items[8] | .line==9 and .status=="skip" and .reason=="bad_port"'
expect_jq "summary" "$R" '.summary=={add:2, dup:4, skip:3, pending:0}'
expect_true "config byte-identical (nothing written)" cmp -s /etc/config/vpnpool "$FXR/before.cfg"
end

# ---- add: only the picked lines; duplicates are not added twice ----
reset_state; daemon_start
rcall add "$(jarg --arg t "$L1
$L2" '{text:$t, lines:[2]}')"
begin "rpcd/add/picked-lines-only"
expect_jq "added 1" "$R" '.ok==true and .added==1'
expect_eq "only line 2 stored" "$(ulist vpnpool.main.manual_node)" "$L2"
end
rcall add "$(jarg --arg t "$L2" '{text:$t}')"
begin "rpcd/add/duplicate-not-added"
expect_jq "nothing_added, 1 dup" "$R" '.ok==false and .code=="nothing_added" and .dup==1 and .added==0'
expect_eq "still one manual node" "$(ulist vpnpool.main.manual_node | wc -l)" 1
end
rcall add '{"items":["vpn://AAAA","hello"]}'
begin "rpcd/add/failed-lines-reported"
expect_jq "unreadable vpn:// + junk, each with its line and reason" "$R" '.ok==false and .failed==[{line:1,reason:"decode_failed"},{line:2,reason:"not_a_link"}]'
end

# ---- backup holds the secrets; restore checks before it replaces ----
reset_state
uci set vpnpool.main.telegram_token='123456:SECRET-BOT-TOKEN'; uci add_list vpnpool.main.manual_node="$L1"; uci set vpnpool.main.enabled=1; uci commit vpnpool
mkdir -p /etc/vpnpool/awg; cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/a1.conf; cp "$T_DIR/fixtures/awg/wg-plain.conf" /etc/vpnpool/awg/a2.conf
NAWG=$(ls /etc/vpnpool/awg/*.conf | wc -l)
echo '{"0123456789ab":{"tag":"Node1","link":"'"$L1"'","active":false,"auto":false}}' > /etc/vpnpool/favorites.map.json
rcall backup
printf '%s' "$R" | jq -r '.data' | base64 -d > "$FXR/full.tgz" 2>/dev/null
mkdir -p "$FXR/full"; tar -xzf "$FXR/full.tgz" -C "$FXR/full" 2>/dev/null
begin "rpcd/backup/full-copy-with-secrets"
expect_true "real token inside (it is THE backup)" grep -q 'SECRET-BOT-TOKEN' "$FXR/full/etc/config/vpnpool"
expect_eq "AWG confs inside" "$(ls "$FXR/full/etc/vpnpool/awg/"*.conf 2>/dev/null | wc -l)" "$NAWG"
expect_true "favourites map inside" [ -s "$FXR/full/etc/vpnpool/favorites.map.json" ]
expect_jq "report counts (the favourite counted)" "$R" ".report.nodes==1 and .report.awg==$NAWG and .report.saved==1"
end
BK=$(printf '%s' "$R" | jq -r '.data')
reset_state
rcall restore "$(jq -nc --arg d "$BK" '{data:$d}')"
begin "rpcd/restore/without-confirm-changes-nothing"
expect_jq "confirm_required + the report" "$R" ".ok==false and .code==\"confirm_required\" and .report.nodes==1 and .report.awg==$NAWG"
expect_eq "config not replaced" "$(uci -q get vpnpool.main.telegram_token)" ''
expect_eq "no AWG file restored" "$(ls /etc/vpnpool/awg/*.conf 2>/dev/null | wc -l)" 0
end
reset_state; daemon_start
rcall restore "$(jq -nc --arg d "$BK" '{data:$d, replace_all:true}')"
begin "rpcd/restore/replace-all"
expect_jq "restored" "$R" '.ok==true and .code=="restored" and .daemon=="signalled"'
expect_eq "token back" "$(uci -q get vpnpool.main.telegram_token)" '123456:SECRET-BOT-TOKEN'
expect_eq "AWG confs back" "$(ls /etc/vpnpool/awg/*.conf 2>/dev/null | wc -l)" "$NAWG"
expect_true "favourites map back" [ -s /etc/vpnpool/favorites.map.json ]
end
# foreign member (anything outside the backup's own paths) -> refused, nothing touched
reset_state
mkdir -p "$FXR/evil/etc/config" "$FXR/evil/etc/init.d"
cp /etc/config/vpnpool "$FXR/evil/etc/config/vpnpool"; sed -i "s/option failover_interval '60'/option failover_interval '33'/" "$FXR/evil/etc/config/vpnpool"
echo 'echo pwned' > "$FXR/evil/etc/init.d/evil"
tar -czf "$FXR/evil.tgz" -C "$FXR/evil" etc/config/vpnpool etc/init.d/evil
rcall restore "$(jq -nc --arg d "$(base64 -w0 "$FXR/evil.tgz")" '{data:$d, replace_all:true}')"
begin "rpcd/restore/foreign-member-refused"
expect_jq "invalid_archive" "$R" '.ok==false and .code=="invalid_archive"'
expect_eq "config untouched" "$(uci -q get vpnpool.main.failover_interval)" 60
end
# an archive whose config lacks a section -> refused
reset_state
mkdir -p "$FXR/half/etc/config"
printf "config vpnpool 'main'\n\toption failover_interval '44'\n" > "$FXR/half/etc/config/vpnpool"
tar -czf "$FXR/half.tgz" -C "$FXR/half" etc/config/vpnpool
rcall restore "$(jq -nc --arg d "$(base64 -w0 "$FXR/half.tgz")" '{data:$d, replace_all:true}')"
begin "rpcd/restore/incomplete-config-refused"
expect_jq "incomplete_config" "$R" '.ok==false and .code=="incomplete_config"'
expect_eq "config untouched" "$(uci -q get vpnpool.main.failover_interval)" 60
end
# the archive as a file LuCI uploaded to /tmp (too big for one request): same checks, same result
reset_state
printf '%s' "$BK" | base64 -d > /tmp/vpnpool-upload.tgz
rcall restore '{"path":"/tmp/vpnpool-upload.tgz","replace_all":true}'
begin "rpcd/restore/from-uploaded-file"
expect_jq "restored" "$R" '.ok==true and .code=="restored"'
expect_eq "token back" "$(uci -q get vpnpool.main.telegram_token)" '123456:SECRET-BOT-TOKEN'
end
reset_state
cp /tmp/vpnpool-upload.tgz /etc/vpnpool/x.tgz
rcall restore '{"path":"/etc/vpnpool/x.tgz","replace_all":true}'
begin "rpcd/restore/path-outside-tmp-refused"
expect_jq "invalid path" "$R" '.ok==false and .code=="invalid" and .errors.path=="bad_value"'
expect_eq "config untouched" "$(uci -q get vpnpool.main.telegram_token)" ''
end
rm -f /tmp/vpnpool-upload.tgz

# ---------------- review fixes (REVIEW_stage3 V1..V7, M1..M9) ----------------
# helper: a backup of the CURRENT config as a directory tree in $1 (to change and repack)
bk_tree() {   # $1=dir
	rcall backup; rm -rf "$1"; mkdir -p "$1"
	printf '%s' "$R" | jq -r '.data' | base64 -d > "$1.tgz" 2>/dev/null
	tar -xzf "$1.tgz" -C "$1"; mkdir -p "$1/etc/vpnpool/awg"
}
restore_tgz() {   # $1=tar.gz file [replace_all true|false]
	rcall restore "$(jq -nc --arg d "$(base64 -w0 "$1")" --argjson r "${2:-true}" '{data:$d, replace_all:$r}')"
}

# V1: our own backup is always accepted back — files outside the rule are left out (and listed)
reset_state; daemon_start
mkdir -p /etc/vpnpool/awg
cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/good.conf
cp "$T_DIR/fixtures/awg/awg2.conf" "/etc/vpnpool/awg/my node.conf"
cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/good.conf.bak
rcall backup
BKV1=$(printf '%s' "$R" | jq -r '.data')
begin "rpcd/backup/members-by-the-restore-rule"
expect_jq "the two odd files listed as skipped" "$R" '(.report.skipped|sort)==["etc/vpnpool/awg/good.conf.bak","etc/vpnpool/awg/my node.conf"] and .report.awg==1'
end
rm -f /etc/vpnpool/awg/good.conf
rcall restore "$(jq -nc --arg d "$BKV1" '{data:$d, replace_all:true}')"
begin "rpcd/restore/own-backup-round-trip"
expect_jq "restored" "$R" '.ok==true and .code=="restored"'
expect_true "good.conf back" [ -f /etc/vpnpool/awg/good.conf ]
expect_true "the user's other files untouched" [ -f "/etc/vpnpool/awg/my node.conf" ]
expect_true "... both" [ -f /etc/vpnpool/awg/good.conf.bak ]
end

# V2: values go through the set_config schema (restore and import)
reset_state
bk_tree "$FXR/v2"
sed -i "s/option failover_interval '60'/option failover_interval 'abc; reboot'/; s/option fwmark '0x400000'/option fwmark 'x'/" "$FXR/v2/etc/config/vpnpool"
tar -czf "$FXR/v2bad.tgz" -C "$FXR/v2" etc
restore_tgz "$FXR/v2bad.tgz"
begin "rpcd/restore/bad-values-refused"
expect_jq "invalid, both fields named" "$R" '.ok==false and .code=="invalid" and .errors.failover_interval=="bad_value" and .errors.fwmark=="bad_mark"'
expect_eq "config untouched" "$(uci -q get vpnpool.main.failover_interval)" 60
end
rcall import "$(jq -nc --rawfile c "$FXR/v2/etc/config/vpnpool" '{config:$c}')"
begin "rpcd/import/bad-values-refused"
expect_jq "invalid, field named" "$R" '.ok==false and .code=="invalid" and .errors.failover_interval=="bad_value"'
expect_eq "config untouched" "$(uci -q get vpnpool.main.failover_interval)" 60
end

# V3: limits checked on the listing, before anything is unpacked
reset_state
bk_tree "$FXR/v3"
dd if=/dev/zero bs=1024 count=5000 2>/dev/null | tr '\0' ' ' > "$FXR/v3/etc/vpnpool/z.map.json"
tar -czf "$FXR/v3big.tgz" -C "$FXR/v3" etc
# observer: every tar run by the rpcd children that UNPACKS is logged (the refusal must come first)
printf '#!/bin/sh\ncase "$1" in -x*) echo "$*" >> /tmp/vpnpool-tar-x.log ;; esac\nexec /bin/tar "$@"\n' > /opt/stand/tests-bin/tar
chmod +x /opt/stand/tests-bin/tar; rm -f /tmp/vpnpool-tar-x.log
restore_tgz "$FXR/v3big.tgz"
begin "rpcd/restore/oversized-content-refused"
expect_true "positive control: the archive is small, its content is not" [ "$(wc -c < "$FXR/v3big.tgz")" -lt 100000 ]
expect_jq "too_large" "$R" '.ok==false and .code=="too_large"'
expect_eq "refused BEFORE unpacking (no tar -x ran)" "$(gcount . /tmp/vpnpool-tar-x.log)" 0
end
restore_tgz "$FXR/v3.tgz"
begin "rpcd/restore/observer-sees-an-unpack"   # positive control for the observer above
expect_jq "a normal archive restores" "$R" '.ok==true'
expect_true "and its tar -x was logged" [ "$(gcount . /tmp/vpnpool-tar-x.log)" -ge 1 ]
end
rm -f /opt/stand/tests-bin/tar /tmp/vpnpool-tar-x.log
rm -f "$FXR/v3/etc/vpnpool/z.map.json"
i=0; while [ $i -lt 501 ]; do echo '{}' > "$FXR/v3/etc/vpnpool/m$i.map.json"; i=$((i + 1)); done
tar -czf "$FXR/v3many.tgz" -C "$FXR/v3" etc
restore_tgz "$FXR/v3many.tgz"
begin "rpcd/restore/too-many-files-refused"
expect_jq "too_large" "$R" '.ok==false and .code=="too_large"'
end

# M1: only regular files and directories — symlink, hardlink, device, fifo refused
reset_state
for kind in symlink hardlink device fifo; do
	bk_tree "$FXR/m1"
	case $kind in
		symlink)  ln -s /tmp "$FXR/m1/etc/vpnpool/s.map.json" ;;
		hardlink) echo '{}' > "$FXR/m1/etc/vpnpool/a.map.json"; ln "$FXR/m1/etc/vpnpool/a.map.json" "$FXR/m1/etc/vpnpool/b.map.json" ;;
		device)   mknod "$FXR/m1/etc/vpnpool/d.map.json" c 1 3 ;;
		fifo)     mkfifo "$FXR/m1/etc/vpnpool/f.map.json" ;;
	esac
	tar -czf "$FXR/m1.tgz" -C "$FXR/m1" etc
	restore_tgz "$FXR/m1.tgz"
	begin "rpcd/restore/member-type-$kind-refused"
	expect_true "positive control: the archive has the $kind" sh -c "tar -tvzf '$FXR/m1.tgz' | grep -Eq '^[lcp]|-> '"
	expect_jq "invalid_archive" "$R" '.ok==false and .code=="invalid_archive"'
	end
done

# M2: the uploaded file must be in /tmp after resolving symlinks and ".."
reset_state
bk_tree "$FXR/m2"; cp "$FXR/m2.tgz" /etc/vpnpool/up.tgz
rm -rf /tmp/vpnpool-lnk; ln -s /etc/vpnpool /tmp/vpnpool-lnk
for pth in /tmp/vpnpool-lnk/up.tgz /tmp/../etc/vpnpool/up.tgz; do
	rcall restore "$(jq -nc --arg p "$pth" '{path:$p, replace_all:true}')"
	begin "rpcd/restore/path-escaping-tmp-refused-$(echo "$pth" | tr -c 'a-z0-9' '_')"
	expect_jq "invalid path" "$R" '.ok==false and .code=="invalid" and .errors.path=="bad_value"'
	end
done
rm -f /tmp/vpnpool-lnk

# V4: the swap is atomic — a failure of the LAST step rolls everything back
reset_state; daemon_start
mkdir -p /etc/vpnpool/awg; cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/old.conf
echo '{"Old":"x"}' > /etc/vpnpool/saved.map.json
uci set vpnpool.main.failover_interval=61; uci commit vpnpool
bk_tree "$FXR/v4"
rm -f "$FXR/v4/etc/vpnpool/awg/old.conf"; cp "$T_DIR/fixtures/awg/wg-plain.conf" "$FXR/v4/etc/vpnpool/awg/new.conf"
echo '{"New":"y"}' > "$FXR/v4/etc/vpnpool/saved.map.json"
sed -i "s/option failover_interval '61'/option failover_interval '62'/" "$FXR/v4/etc/config/vpnpool"
tar -czf "$FXR/v4.tgz" -C "$FXR/v4" etc
# fault injection: the rpcd children see the tests-bin PATH; this mv refuses the config's rename
printf '#!/bin/sh\nfor a; do l=$a; done\n[ -f /tmp/vpnpool-fail-mv ] && [ "$l" = "$(cat /tmp/vpnpool-fail-mv)" ] && exit 1\nexec /bin/mv "$@"\n' > /opt/stand/tests-bin/mv
chmod +x /opt/stand/tests-bin/mv; echo /etc/config/vpnpool > /tmp/vpnpool-fail-mv
restore_tgz "$FXR/v4.tgz"
rm -f /tmp/vpnpool-fail-mv /opt/stand/tests-bin/mv
begin "rpcd/restore/failed-step-rolls-back"
expect_jq "restore_failed, rolled back" "$R" '.ok==false and .code=="restore_failed" and .rolled_back==true'
expect_eq "config as before" "$(uci -q get vpnpool.main.failover_interval)" 61
expect_true "old AWG file back" [ -f /etc/vpnpool/awg/old.conf ]
expect_true "new AWG file not left" [ ! -f /etc/vpnpool/awg/new.conf ]
expect_jq "saved map as before" "$(cat /etc/vpnpool/saved.map.json)" '.==({"Old":"x"})'
end
restore_tgz "$FXR/v4.tgz"
begin "rpcd/restore/same-archive-without-the-fault"   # positive control for the case above
expect_jq "restored" "$R" '.ok==true and .code=="restored"'
expect_eq "config replaced" "$(uci -q get vpnpool.main.failover_interval)" 62
expect_true "new AWG file in place, old one gone" sh -c '[ -f /etc/vpnpool/awg/new.conf ] && [ ! -f /etc/vpnpool/awg/old.conf ]'
end
# the copy "before" cannot be made -> nothing is replaced
reset_state; uci set vpnpool.main.failover_interval=61; uci commit vpnpool
printf '#!/bin/sh\ncase "$*" in *pre-restore*) [ -f /tmp/vpnpool-fail-tar ] && exit 1 ;; esac\nexec /bin/tar "$@"\n' > /opt/stand/tests-bin/tar
chmod +x /opt/stand/tests-bin/tar; : > /tmp/vpnpool-fail-tar
restore_tgz "$FXR/v4.tgz"
rm -f /tmp/vpnpool-fail-tar /opt/stand/tests-bin/tar
begin "rpcd/restore/no-copy-before-no-replace"
expect_jq "write_failed at the copy step" "$R" '.ok==false and .code=="write_failed" and .step=="pre_copy"'
expect_eq "config untouched" "$(uci -q get vpnpool.main.failover_interval)" 61
end

# V6: a mask never travels on as an address; looked up in the method's own kind of subscription
reset_state; daemon_start; mock_on
sub_section s1 'https://h.example/AAA' pick; sub_section s2 'https://h.example/BBB' pick
rcall probe_source '{"url":"https://h.example/***"}'
begin "rpcd/probe_source/ambiguous-mask-refused"
expect_jq "ambiguous" "$R" '.ok==false and .code=="ambiguous"'
expect_eq "no request to the mask" "$(mock_calls 'h.example/\*\*\*')" 0
end
rcall probe_source '{"url":"https://other.example/***"}'
begin "rpcd/probe_source/unknown-mask-refused"
expect_jq "not_found" "$R" '.ok==false and .code=="not_found"'
end
reset_state; daemon_start; mock_on
sub_section s1 'https://h.example/AAA' pick; sub_section s2 'https://h.example/BBB' all
printf '%s\n' "$L1" > "$FXR/src1.txt"; mock_rule 'GET https://h.example/AAA' 200 "$FXR/src1.txt"
rcall probe_source '{"url":"s1"}'
begin "rpcd/probe_source/by-subscription-id"
expect_jq "started" "$R" '.ok==true and .code=="started"'
_i=0; while [ $_i -lt 20 ] && [ -f /tmp/vpnpool/.probe-running ]; do sleep 1; _i=$((_i+1)); done
expect_true "the real source was fetched" [ "$(mock_calls 'GET https://h.example/AAA')" -ge 1 ]
end
rcall del_source '{"url":"https://h.example/***"}'
begin "rpcd/del_source/mask-resolved-in-pick-subscriptions-only"
expect_jq "deleted (the all-mode subscription on the same host does not make it ambiguous)" "$R" '.ok==true and .code=="deleted"'
expect_eq "the other one kept" "$(subs_tsv | cut -f1)" s2
end
rcall add_sub '{"url":"https://h.example/***"}'
begin "rpcd/add_sub/mask-literal-refused"
expect_jq "invalid url, nothing stored" "$R" '.ok==false and .code=="invalid"'
expect_eq "subscriptions unchanged" "$(subs_tsv | cut -f4)" 'https://h.example/BBB'
end

# V7: add with a URL = the add_sub rule (trial download, 0 nodes -> not stored)
reset_state; daemon_start; mock_on; mock_rule 'GET https://dead.example.com/s' 500
rcall add "$(jarg --arg t "$L1
https://dead.example.com/s" '{text:$t}')"
begin "rpcd/add/url-without-nodes-not-stored"
expect_jq "the link added, the URL failed with fetch_failed" "$R" '.ok==true and .added==1 and .failed==[{line:2,reason:"fetch_failed",http:"500"}]'
expect_eq "no subscription" "$(subs_tsv)" ''
expect_eq "the trial download happened" "$(mock_calls 'GET https://dead.example.com/s')" 1
end
# the URL even serves nodes: only add_node's own refusal keeps it from becoming a subscription
printf '%s\n' "$L2" > "$FXR/evil.txt"; mock_rule 'GET https://evil.example/sub' 200 "$FXR/evil.txt"
rcall add_node '{"link":"https://evil.example/sub"}'
begin "rpcd/add_node/url-refused"
expect_jq "invalid" "$R" '.ok==false and .code=="invalid"'
expect_eq "no subscription created" "$(subs_tsv)" ''
end

# M6: set_url "" clears the subscription again
reset_state; sub_section sp 'https://sub.example.com/s'
rcall set_url '{"url":""}'
begin "rpcd/set_url/empty-clears"
expect_jq "saved" "$R" '.ok==true and .code=="saved"'
expect_eq "cleared" "$(subs_tsv)" ''
end

# M7: a missing section is created with the type the package expects
reset_state; uci delete vpnpool.main; uci commit vpnpool
rcall set_config '{"settings":{"failover_interval":"90"}}'
begin "rpcd/set_config/creates-main-of-type-vpnpool"
expect_jq "saved" "$R" '.ok==true'
expect_eq "section type" "$(uci -q get vpnpool.main)" vpnpool
end

# M9: settings stored but the crontab rewrite failed -> ok:true + a warning, not "nothing saved"
reset_state; daemon_start; rm -rf /etc/crontabs; : > /etc/crontabs
rcall set_schedule '{"enabled":true,"on":"07:00","off":"","refresh":""}'
rm -f /etc/crontabs
begin "rpcd/set_schedule/cron-failure-is-a-warning"
expect_jq "ok + warning" "$R" '.ok==true and .warning=="schedule_failed"'
expect_eq "stored" "$(uci -q get vpnpool.main.sched_on)" '07:00'
end

# ---------------- stage 6: the data model (ROADMAP 9) ----------------
# favourites / hidden / "Connect" / "Back to automatic choice" / one subscription — by node id
# the ids of Node1 / Node2 (the same parser as fx_nodes) for the method arguments
printf '%s\n%s\n' "$L1" "$L2" > "$FXR/l2.txt"
FA1=$(ucode /usr/libexec/vpnpool/parser.uc --with-id "$FXR/l2.txt" | jq -c '{id: .[0].id}')
FA=$(ucode /usr/libexec/vpnpool/parser.uc --with-id "$FXR/l2.txt" | jq -c '{id: .[1].id}')
s_fav() { fx_nodes; }
c_fav() { expect_true "a favourite with the link, type and server" jq -e --arg i "$ID2" --arg l "$L2" '.[$i] | .link==$l and .tag=="Node2" and .server=="203.0.113.72" and .type=="vless" and .active==false' /etc/vpnpool/favorites.map.json; }
M fav "$FA" - - c_fav '{"id":"aaaaaaaaaaaa"}' -

s_unfav() { fx_fav; }
c_unfav() { expect_true "no favourite left" jq -e '.==({})' /etc/vpnpool/favorites.map.json; }
M unfav "$FA1" - - c_unfav '{"id":"aaaaaaaaaaaa"}' -

s_hide() { fx_nodes; }
c_hide() {
	expect_eq "hidden = the id" "$(ulist vpnpool.main.hidden)" "$ID2"
	expect_jq "it left the node list at once" "$(cat /tmp/vpnpool/nodes.json)" 'map(.tag)==["Node1"]'
	expect_jq "code hidden" "$R" '.code=="hidden"'
}
M hide "$FA" USR1 - c_hide '{"id":"aaaaaaaaaaaa"}' -

s_unhide() { fx_nodes; uci add_list vpnpool.main.hidden="$ID2"; uci commit vpnpool; }
c_unhide() { expect_eq "hidden list empty" "$(ulist vpnpool.main.hidden)" ''; }
M unhide "$FA" USR1 - c_unhide '{"id":"aaaaaaaaaaaa"}' -

s_connect() { fx_nodes; mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204; }
c_connect() {
	expect_eq "preferred = Node2's id" "$(uci -q get vpnpool.main.preferred_node)" "$ID2"
	expect_jq "applied live" "$R" '.code=="applied"'
	expect_eq "the live selector switched once" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/proxy')" 1
}
M connect "$FA" - - c_connect '{"id":"aaaaaaaaaaaa"}' -

s_auto_select() { fx_nodes; uci set vpnpool.main.preferred_node="$ID1"; uci commit vpnpool; mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204; }
c_auto_select() {
	expect_eq "no preferred node" "$(uci -q get vpnpool.main.preferred_node)" ''
	expect_jq "applied: the selector on the automatic choice" "$R" '.code=="applied"'
}
M auto_select '{}' - - c_auto_select - -

s_sub_set() { fx_nodes; sub_section sp 'https://sub.example.com/s'; }
c_sub_set() {
	expect_eq "name" "$(uci -q get vpnpool.sp.name)" 'My provider'
	expect_eq "mode" "$(uci -q get vpnpool.sp.mode)" pick
	expect_eq "picks" "$(ulist vpnpool.sp.pick)" "$ID2"
	expect_jq "saved" "$R" '.code=="saved"'
}
M sub_set "$(jq -nc --argjson f "$FA" '{id:"sp", name:"My provider", mode:"pick", pick:[$f.id]}')" USR1 - c_sub_set '{"id":"nope","name":"x"}' -

s_sub_del() { sub_section sp 'https://sub.example.com/s'; sub_section se 'https://extra.example.com/x'; }
c_sub_del() { expect_eq "only the other one left" "$(subs_tsv | cut -f1)" se; }
M sub_del '{"id":"sp"}' USR1 - c_sub_del '{"id":"nope"}' -

# ---- semantics beyond the grid ----
reset_state; daemon_start; fx_nodes
rcall delete_node '{"tag":"Node2"}'
begin "rpcd/delete_node/subscription-node-is-hidden"
expect_jq "deleted" "$R" '.ok==true and .code=="deleted" and .ids==["'"$ID2"'"]'
expect_eq "hidden by id (the subscription can't bring it back)" "$(ulist vpnpool.main.hidden)" "$ID2"
expect_eq "the manual list untouched" "$(ulist vpnpool.main.manual_node)" ''
end
rcall unhide "$(jq -nc --arg i "$ID2" '{id:$i}')"
begin "rpcd/unhide/returns-it"
expect_jq "restored" "$R" '.ok==true and .code=="restored"'
expect_eq "no hidden id left" "$(ulist vpnpool.main.hidden)" ''
end

reset_state; daemon_start; fx_nodes; mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204
uci set vpnpool.main.preferred_node="$ID2"; uci commit vpnpool
rcall hide "$(jq -nc --arg i "$ID2" '{id:$i}')"
begin "rpcd/hide/clears-the-preferred-node"
expect_jq "hidden" "$R" '.code=="hidden"'
expect_eq "it is not the preferred node any more" "$(uci -q get vpnpool.main.preferred_node)" ''
end

# an AWG file node in no list of the last build (the build failed, or has not run yet): deleted
# by its id all the same (stage 4b: "delete by id")
reset_state; daemon_start
mkdir -p /etc/vpnpool/awg; cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/old-name.conf
_aid=$(ucode /usr/libexec/vpnpool/parser.uc --with-id /etc/vpnpool/awg/old-name.conf | jq -r '.[0].id')
rcall delete_node "$(jq -nc --arg i "$_aid" '{id:$i}')"
begin "rpcd/delete_node/awg-file-not-in-the-pool"
expect_true "control: an id ($_aid), no node list" sh -c '[ ${#1} -eq 12 ] && [ ! -s /tmp/vpnpool/nodes.json ]' _ "$_aid"
expect_jq "deleted" "$R" '.ok==true and .code=="deleted"'
expect_true "the file is gone" [ ! -f /etc/vpnpool/awg/old-name.conf ]
end

# a favourite no source has: "Connect" brings it into the pool (archive -> active) and prefers it
reset_state; daemon_start
echo '{"aaaaaaaaaaaa":{"tag":"Gone-Fav","link":"vless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.99:443?security=tls#Gone-Fav","active":false,"auto":false}}' > /etc/vpnpool/favorites.map.json
rcall connect '{"id":"aaaaaaaaaaaa"}'
begin "rpcd/connect/favourite-not-in-a-source-joins-the-pool"
expect_jq "connect_pending, rebuild signalled" "$R" '.ok==true and .code=="connect_pending" and .daemon=="signalled"'
expect_true "the favourite is active now" jq -e '.aaaaaaaaaaaa.active==true' /etc/vpnpool/favorites.map.json
expect_eq "preferred" "$(uci -q get vpnpool.main.preferred_node)" aaaaaaaaaaaa
end

# probe dialog picked again: the picks of that URL's subscription are replaced, not added
reset_state; daemon_start; fx_nodes
jq -nc --arg a "$L1" --arg b "$L2" --arg i "$ID1" --arg j "$ID2" '{url:"https://src.example.com/l",nodes:[{i:0,id:$i,link:$a,tag:"Node1"},{i:1,id:$j,link:$b,tag:"Node2"}]}' > /tmp/vpnpool/.probe-cache.json
rcall import_select '{"url":"https://src.example.com/l","idx":[0,1],"name":"Free list"}'
_c1=$(subs_tsv | wc -l)
rcall import_select '{"url":"https://src.example.com/l","idx":[1]}'
_sid=$(subs_tsv | cut -f1)
begin "rpcd/import_select/re-pick-replaces"
expect_eq "one subscription for the URL" "$(subs_tsv | wc -l)" 1
expect_eq "control: it existed after the first pick" "$_c1" 1
expect_eq "its picks = the second choice only" "$(ulist "vpnpool.$_sid.pick")" "$ID2"
expect_eq "named by the first pick" "$(uci -q get "vpnpool.$_sid.name")" 'Free list'
end

# add: a URL in "pick" mode with the chosen ids; a bad mode is refused (nothing written)
reset_state; daemon_start; mock_on; printf '%s\n%s\n' "$L1" "$L2" > "$FXR/newsub.txt"; mock_rule 'GET https://new.example.com/s' 200 "$FXR/newsub.txt"
rcall add '{"items":["https://new.example.com/s"],"options":{"mode":"pick","pick":["0123456789ab"],"name":"Picked"}}'
_sid=$(subs_tsv | cut -f1)
begin "rpcd/add/url-in-pick-mode"
expect_jq "added" "$R" '.ok==true and .added==1'
expect_eq "pick mode" "$(subs_tsv | cut -f2-3)" "1	pick"
expect_eq "its picks" "$(ulist "vpnpool.$_sid.pick")" 0123456789ab
expect_eq "its name" "$(uci -q get "vpnpool.$_sid.name")" Picked
end
reset_state; daemon_start
rcall add '{"items":["https://new.example.com/s"],"options":{"mode":"some"}}'
begin "rpcd/add/bad-mode-refused"
expect_jq "invalid, the field named" "$R" '.ok==false and .code=="invalid" and .errors["options.mode"]=="bad_mode"'
expect_eq "nothing written" "$(subs_tsv)" ''
end

# singbox_bin in the set_config schema (stage 4b leftover): a path that is no program is refused
reset_state; daemon_start
rcall set_config '{"settings":{"singbox_bin":"/usr/bin/no-such-sing-box"}}'
begin "rpcd/set_config/singbox-bin-missing-refused"
expect_jq "bad_path" "$R" '.ok==false and .errors.singbox_bin=="bad_path"'
expect_eq "not stored" "$(uci -q get vpnpool.main.singbox_bin)" ''
end
rcall set_config '{"settings":{"singbox_bin":"../relative"}}'
begin "rpcd/set_config/singbox-bin-relative-refused"
expect_jq "bad_path" "$R" '.ok==false and .errors.singbox_bin=="bad_path"'
end
rcall set_config '{"settings":{"singbox_bin":"/bin/sh"}}'
begin "rpcd/set_config/singbox-bin-existing-accepted"   # positive control
expect_jq "saved, rebuild" "$R" '.ok==true and .code=="saved" and .daemon=="signalled"'
expect_eq "stored" "$(uci -q get vpnpool.main.singbox_bin)" /bin/sh
end
rcall set_config '{"settings":{"singbox_bin":""}}'
begin "rpcd/set_config/singbox-bin-empty-is-automatic"
expect_jq "saved" "$R" '.ok==true'
expect_eq "cleared" "$(uci -q get vpnpool.main.singbox_bin)" ''
end

# a 1.x backup restored on 2.0: migrated to the 2.0 data model right after the restore
reset_state; daemon_start
FXM="$T_DIR/fixtures/migrate/141"
mkdir -p "$FXR/old/etc/config" "$FXR/old/etc/vpnpool/awg"
cp "$FXM/etc-config-vpnpool" "$FXR/old/etc/config/vpnpool"
cp "$FXM/saved.map.json" "$FXM/snapshot.map.json" "$FXM/imported.map.json" "$FXR/old/etc/vpnpool/"
tar -czf "$FXR/old.tgz" -C "$FXR/old" etc/config/vpnpool etc/vpnpool/saved.map.json etc/vpnpool/snapshot.map.json etc/vpnpool/imported.map.json
cp "$FXM/links.json" /etc/vpnpool/links.json
rcall restore "$(jq -nc --arg d "$(base64 -w0 "$FXR/old.tgz")" '{data:$d, replace_all:true}')"
begin "rpcd/restore/1x-backup-migrated"
expect_jq "restored" "$R" '.ok==true and .code=="restored"'
expect_eq "schema 2" "$(uci -q get vpnpool.main.schema)" 2
expect_eq "4 subscription sections" "$(subs_tsv | wc -l)" 4
expect_eq "no 1.x option left" "$(uci -q show vpnpool.main | gcount -e subscription_url -e extra_sub -e '\.source=' -e selected_node -e saved_node)" 0
expect_true "favourites from the saved maps" jq -e 'length==3' /etc/vpnpool/favorites.map.json
end

# ---------------- coverage: ACL <-> rpcd list <-> this suite ----------------
begin "rpcd/coverage-acl-methods"
jq -r '.["luci-app-vpnpool"] | (.read.ubus.vpnpool + .write.ubus.vpnpool)[]' "$ACL" | sort -u > "$FXR/acl"
ubus -v list vpnpool 2>/dev/null | sed -n 's/^[[:space:]]*"\([a-z_]*\)":.*/\1/p' | sort -u > "$FXR/served"
sort -u "$TESTED" > "$FXR/tested.s"
expect_true "ACL lists methods (positive control)" [ "$(wc -l < "$FXR/acl")" -ge 40 ]
expect_eq "ACL methods without a test case" "$(grep -vxF -f "$FXR/tested.s" "$FXR/acl" | tr '\n' ' ')" ''
expect_eq "ACL methods not served by rpcd" "$(grep -vxF -f "$FXR/served" "$FXR/acl" | tr '\n' ' ')" ''
expect_eq "served methods missing from the ACL" "$(grep -vxF -f "$FXR/acl" "$FXR/served" | tr '\n' ' ')" ''
end
metric rpcd_methods_in_acl "$(wc -l < "$FXR/acl")"
daemon_stop
