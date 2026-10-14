# suite: rpcd — every ubus method of the ACL, called through the REAL ubus -> rpcd -> plugin
# (sourced by run.sh). Per method, up to three cases:
#   ok        valid input, fake vpnpoold running: reply is an object, side effect landed,
#             and the expected signal (USR1 rebuild / USR2 refetch) reached the daemon;
#   bad       invalid input: the reply must say so (.ok==false). Today ~25 methods answer
#             ok:true having done nothing -> xfail 3.1 (honest API) / 3.3 (validation);
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
	printf '#!/bin/sh\necho "%s $*" >> %s\nexit 0\n' "$svc" "$INITD_LOG" > /etc/init.d/$svc
	chmod +x /etc/init.d/$svc
done

ulist() { uci -q get "$1" | tr ' ' '\n' | grep -v '^$'; }
jarg() { jq -nc "$@"; }   # build JSON args safely: jarg --arg l "$L1" '{link:$l}'

fx_nodes() {   # nodes.json + links.json for Node1/Node2
	printf '%s\n%s\n' "$L1" "$L2" > "$FXR/links.txt"
	ucode /usr/libexec/vpnpool/parser.uc "$FXR/links.txt" > /tmp/vpnpool/nodes.json
	jq -nc --arg a "$L1" --arg b "$L2" '[{tag:"Node1",link:$a},{tag:"Node2",link:$b}]' > /etc/vpnpool/links.json
}
fx_saved() { jq -nc --arg a "$L1" '{Node1:$a}' > /etc/vpnpool/saved.map.json; }

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
		end "$_badx"
	fi
	# nodaemon
	reset_state; command -v "s_$_m" >/dev/null 2>&1 && "s_$_m"; daemon_stop
	rcall "$_m" "$_ok"
	reply_case "rpcd/$_m/no-daemon"
	if [ "$_sig" != - ]; then
		begin "rpcd/$_m/no-daemon-reported"
		expect_jq "reply reports the daemon is not running" "$R" '.daemon=="not_running"'
		end 3.1
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
M export_nodes '{"scope":"manual"}' - - c_export_nodes '{"scope":"zzz"}' 3.1

c_idle() { expect_jq "idle" "$R" '.running==false'; }
M unlock_result '{}' - - c_idle - -
M probe_result '{}' - - c_idle - -
M speedtest_result '{}' - - c_idle - -

# ---------------- write methods ----------------
c_set_enabled() {
	expect_eq "uci enabled" "$(uci -q get vpnpool.main.enabled)" 0
	expect_true "service stopped" grep -q '^vpnpool stop' "$INITD_LOG"
}
s_set_enabled() { : > "$INITD_LOG"; uci set vpnpool.main.enabled=1; uci commit vpnpool; }
M set_enabled '{"enabled":false}' - - c_set_enabled '{"enabled":"maybe"}' 3.3

s_select() { fx_nodes; mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204; }
b_select() { mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 404; }
c_select() { expect_eq "selected_node" "$(uci -q get vpnpool.main.selected_node)" Node1; }
M select '{"tag":"Node1"}' - - c_select '{"tag":"Nope"}' 2.8

s_refresh() { : > "$INITD_LOG"; uci set vpnpool.main.enabled=1; uci commit vpnpool; }
c_refresh() { expect_eq "no full service restart" "$(gcount restart "$INITD_LOG")" 0; }
M refresh '{}' USR2 2.5 c_refresh - -

s_ping() {
	fx_nodes; uci set vpnpool.main.dead_filter=0; uci commit vpnpool
	mock_on; echo '{"delay":123}' > "$FXR/delay.json"
	mock_rule 'GET http://127.0.0.1:9091/proxies/*/delay*' 200 "$FXR/delay.json"
}
c_ping() { expect_eq "one delay probe per node" "$(mock_calls '/delay?')" 2; }
M ping '{}' - - c_ping - -

c_set_url() { expect_eq "subscription_url" "$(uci -q get vpnpool.main.subscription_url)" 'https://sub.example.com/s'; }
M set_url '{"url":"https://sub.example.com/s"}' USR2 - c_set_url '{"url":"ftp://bad url"}' 3.3

s_del_subscription() { uci set vpnpool.main.subscription_url='https://sub.example.com/s'; uci commit vpnpool; }
c_del_subscription() { expect_eq "subscription_url cleared" "$(uci -q get vpnpool.main.subscription_url)" ''; expect_jq "promoted" "$R" '.promoted==0'; }
M del_subscription '{}' USR2 - c_del_subscription - -

c_add_source() { expect_eq "source listed" "$(ulist vpnpool.main.source)" 'https://src.example.com/l'; }
M add_source '{"url":"https://src.example.com/l"}' - - c_add_source '{"url":""}' 3.1

s_del_source() { uci add_list vpnpool.main.source='https://src.example.com/l'; uci commit vpnpool; }
c_del_source() { expect_eq "source removed" "$(ulist vpnpool.main.source)" ''; }
M del_source '{"url":"https://src.example.com/l"}' USR1 - c_del_source '{"url":"https://unknown.example.com/"}' 3.1

s_probe_source() { mock_on; printf '%s\n%s\n' "$L1" "$L2" > "$FXR/src.txt"; mock_rule 'GET https://src.example.com/l' 200 "$FXR/src.txt"; }
c_probe_source() {
	expect_jq "started" "$R" '.started==true'
	_i=0; while [ $_i -lt 30 ]; do rcall probe_result; printf '%s' "$R" | jq -e '.running==false' >/dev/null 2>&1 && break; sleep 1; _i=$((_i+1)); done
	expect_jq "probe_result lists both nodes" "$R" '.running==false and .total==2 and (.nodes|length)==2'
}
M probe_source '{"url":"https://src.example.com/l"}' - - c_probe_source '{"url":""}' 3.1

s_import_select() { jq -nc --arg a "$L1" --arg b "$L2" '{url:"https://src.example.com/l",nodes:[{i:0,link:$a,tag:"Node1"},{i:1,link:$b,tag:"Node2"}]}' > /tmp/vpnpool/.probe-cache.json; }
c_import_select() { expect_eq "imported_node" "$(ulist vpnpool.main.imported_node)" "$L1"; expect_jq "count" "$R" '.count==1'; }
M import_select '{"url":"https://src.example.com/l","idx":[0]}' USR1 - c_import_select '{"url":"https://other.example.com/","idx":[0]}' 3.1

c_add_node() { expect_eq "manual_node" "$(ulist vpnpool.main.manual_node)" "$L1"; }
M add_node "$(jarg --arg l "$L1" '{link:$l}')" USR1 - c_add_node '{"link":"this is not a node"}' 3.1

s_del_node() { uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; }
c_del_node() { expect_eq "manual_node empty" "$(ulist vpnpool.main.manual_node)" ''; }
M del_node "$(jarg --arg l "$L1" '{link:$l}')" USR1 - c_del_node '{"link":"vless://nope@1.1.1.1:1#x"}' 3.1

c_import_nodes() { expect_jq "added 2" "$R" '.added==2'; expect_eq "manual_node count" "$(ulist vpnpool.main.manual_node | wc -l)" 2; }
M import_nodes "$(jarg --arg t "$L1
$L2" '{text:$t}')" USR1 - c_import_nodes '{"text":"hello world"}' -

s_delete_node() { fx_nodes; uci add_list vpnpool.main.manual_node="$L1"; uci commit vpnpool; }
c_delete_node() { expect_eq "manual_node empty" "$(ulist vpnpool.main.manual_node)" ''; expect_jq "pruned from nodes.json" "$(cat /tmp/vpnpool/nodes.json)" 'map(.tag)==["Node2"]'; }
M delete_node '{"tag":"Node1"}' USR1 - c_delete_node '{"tag":"Nope"}' -

s_delete_nodes() { fx_nodes; uci add_list vpnpool.main.manual_node="$L1"; uci add_list vpnpool.main.manual_node="$L2"; uci commit vpnpool; }
c_delete_nodes() { expect_eq "manual_node empty" "$(ulist vpnpool.main.manual_node)" ''; }
M delete_nodes '{"tags":["Node1","Node2"]}' USR1 - c_delete_nodes '{"tags":["Nope"]}' 3.1

s_restore_node() { fx_nodes; echo '["Node1"]' > /tmp/vpnpool/.dead_tags.json; }
c_restore_node() { expect_eq "keep_auto" "$(ulist vpnpool.main.keep_auto)" Node1; expect_jq "dead set pruned" "$(cat /tmp/vpnpool/.dead_tags.json)" '.==[]'; }
M restore_node '{"tag":"Node1"}' USR1 - c_restore_node '{"tag":"Nope"}' 3.1

s_refilter_node() { fx_nodes; uci add_list vpnpool.main.keep_auto=Node1; uci commit vpnpool; }
c_refilter_node() { expect_eq "keep_auto empty" "$(ulist vpnpool.main.keep_auto)" ''; }
M refilter_node '{"tag":"Node1"}' USR1 - c_refilter_node '{"tag":"Nope"}' 3.1

s_save_node() { fx_nodes; }
c_save_node() { expect_true "saved.map has Node1" jq -e '.Node1|startswith("vless://")' /etc/vpnpool/saved.map.json; expect_eq "uci saved_node" "$(ulist vpnpool.main.saved_node)" "$L1"; }
M save_node '{"tag":"Node1"}' - - c_save_node '{"tag":"Nope"}' -

s_unsave_node() { fx_nodes; fx_saved; }
c_unsave_node() { expect_true "saved.map empty" jq -e '.==({})' /etc/vpnpool/saved.map.json; }
M unsave_node '{"tag":"Node1"}' - - c_unsave_node '{"tag":"Nope"}' 3.1

s_activate_saved() { fx_saved; }
c_activate_saved() { expect_eq "active_saved" "$(ulist vpnpool.main.active_saved)" "$L1"; }
M activate_saved '{"tag":"Node1"}' USR1 - c_activate_saved '{"tag":"Nope"}' -

s_deactivate_saved() { fx_saved; uci add_list vpnpool.main.active_saved="$L1"; uci commit vpnpool; }
c_deactivate_saved() { expect_eq "active_saved empty" "$(ulist vpnpool.main.active_saved)" ''; }
M deactivate_saved '{"tag":"Node1"}' USR1 - c_deactivate_saved '{"tag":"Nope"}' 3.1

s_add_sub() { mock_on; printf '%s\n%s\n' "$L1" "$L2" > "$FXR/sub.txt"; mock_rule 'GET https://extra.example.com/x' 200 "$FXR/sub.txt"; }
b_add_sub() { mock_on; mock_rule 'GET https://extra.example.com/x' 500; }
c_add_sub() { expect_jq "fetched 2" "$R" '.fetched==2'; expect_eq "extra_sub" "$(ulist vpnpool.main.extra_sub)" 'https://extra.example.com/x'; }
M add_sub '{"url":"https://extra.example.com/x"}' USR2 - c_add_sub '{"url":"https://extra.example.com/x"}' 3.1

s_del_sub() { uci add_list vpnpool.main.extra_sub='https://extra.example.com/x'; uci commit vpnpool; }
c_del_sub() { expect_eq "extra_sub empty" "$(ulist vpnpool.main.extra_sub)" ''; }
M del_sub '{"url":"https://extra.example.com/x"}' USR2 - c_del_sub '{"url":"https://unknown.example.com/"}' 3.1

s_set_schedule() { mkdir -p /etc/crontabs; : > /etc/crontabs/root; }
c_set_schedule() {
	expect_eq "sched_on" "$(uci -q get vpnpool.main.sched_on)" '07:00'
	expect_eq "crontab start job" "$(gcount '^0 7 \* \* \* /etc/init.d/vpnpool start$' /etc/crontabs/root)" 1
}
M set_schedule '{"enabled":true,"on":"07:00","off":"23:30","refresh":""}' - 2.6 c_set_schedule '{"enabled":true,"on":"25:99","off":"","refresh":""}' 2.6

s_unlock() { fx_nodes; }
c_started() { expect_jq "started in background" "$R" '.started==true'; }
M unlock '{"tag":"Node1"}' - - c_started '{"tag":""}' 3.1

c_add_auto_domain() { expect_eq "auto_domain" "$(ulist vpnpool.routing.auto_domain)" example.com; }
M add_auto_domain '{"domain":"https://Example.COM/path"}' USR1 - c_add_auto_domain '{"domain":"not a domain!"}' 3.3

s_del_auto_domain() { uci add_list vpnpool.routing.auto_domain=example.com; uci commit vpnpool; }
c_del_auto_domain() { expect_eq "auto_domain empty" "$(ulist vpnpool.routing.auto_domain)" ''; }
M del_auto_domain '{"domain":"example.com"}' USR1 - c_del_auto_domain '{"domain":"unknown.example"}' 3.1

s_run_adaptive() { uci set vpnpool.main.adaptive_routing=1; uci commit vpnpool; }
b_run_adaptive() { uci set vpnpool.main.adaptive_routing=0; uci commit vpnpool; }
M run_adaptive '{}' - - c_started '{}' 3.1

c_set_domains() { expect_eq "domains" "$(ulist vpnpool.routing.domain | tr '\n' ' ')" 'a.example b.example '; }
M set_domains '{"domains":["a.example","b.example"]}' USR1 - c_set_domains '{"domains":["bad domain!"]}' 3.3

c_set_communities() { expect_eq "communities" "$(ulist vpnpool.routing.community)" telegram; }
M set_communities '{"communities":["telegram"]}' USR1 - c_set_communities '{"communities":["no_such_list"]}' 3.3

c_set_option() { expect_eq "failover_interval" "$(uci -q get vpnpool.main.failover_interval)" 120; }
M set_option '{"name":"failover_interval","value":"120"}' USR1 - c_set_option '{"name":"no_such_option","value":"1"}' 3.1

c_set_clients() {
	expect_eq "client_mode" "$(uci -q get vpnpool.main.client_mode)" include
	expect_eq "client" "$(ulist vpnpool.main.client)" 192.168.1.10
	expect_eq "client_dev" "$(ulist vpnpool.main.client_dev)" 'aa:bb:cc:dd:ee:ff'
}
M set_clients '{"mode":"include","clients":["192.168.1.10"],"devices":["aa:bb:cc:dd:ee:ff"]}' USR1 - c_set_clients '{"mode":"zzz","clients":["999.1.1.1"],"devices":[]}' 3.3

c_set_auto_members() { expect_eq "auto_member" "$(ulist vpnpool.main.auto_member)" Node1; }
M set_auto_members '{"members":["Node1"]}' USR1 - c_set_auto_members '{"members":"Node1"}' 3.3

s_set_preferred() { fx_nodes; }
c_set_preferred() { expect_eq "preferred_node" "$(uci -q get vpnpool.main.preferred_node)" Node1; }
M set_preferred '{"tag":"Node1"}' - - c_set_preferred '{"tag":"Nope"}' 3.1

s_speedtest() { fx_nodes; uci set vpnpool.main.speedtest_min_mem_kb=1; uci commit vpnpool; }
M speedtest '{"tag":"Node1"}' - - c_started '{"tag":""}' 3.1

s_tg_test() {
	uci set vpnpool.main.telegram_token='123:abc'; uci set vpnpool.main.telegram_chat='42'; uci commit vpnpool
	mock_on; echo '{"ok":true}' > "$FXR/tg.json"; mock_rule 'P POST https://api.telegram.org/bot*/sendMessage' 200 "$FXR/tg.json"
}
b_tg_test() { uci -q delete vpnpool.main.telegram_token; uci commit vpnpool; }
M tg_test '{}' - - - '{}' -

reset_state
uci export vpnpool | sed "s/option failover_interval '60'/option failover_interval '77'/" > "$FXR/import.cfg"
IMPORT_ARGS=$(jq -nc --rawfile c "$FXR/import.cfg" '{config:$c}')
c_import() { expect_eq "imported value" "$(uci -q get vpnpool.main.failover_interval)" 77; }
M import "$IMPORT_ARGS" USR2 - c_import '{"config":"this is not a uci file {"}' 3.6

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
end 3.5

reset_state
# start from 77, NOT the default 60: today's clamp rewrites junk to 60, so an unchanged-60
# check could not tell "rejected" from "silently clamped to the default"
uci set vpnpool.main.failover_interval=77; uci commit vpnpool
rcall set_option '{"name":"failover_interval","value":"abc"}'
begin "rpcd/set_option/non-numeric-rejected"
expect_jq "ok:false" "$R" '.ok==false'
expect_eq "uci keeps the old value" "$(uci -q get vpnpool.main.failover_interval)" 77
end 3.3

reset_state
rcall import '{"config":"this is not a uci file {"}'
begin "rpcd/import/garbage-keeps-config"
expect_eq "uci config still has main" "$(uci -q get vpnpool.main.failover_interval)" 60
end
begin "rpcd/import/garbage-rejected"
expect_jq "ok:false" "$R" '.ok==false'
end 3.6

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
