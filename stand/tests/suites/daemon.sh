# suite: daemon — routing fail-safe / kill-switch, reload order, watchdog, pause flag, reload
# queue, preferred pin vs the dead set, nodecheck WAN guard, route.sh on real nft
# (sourced by run.sh). ROADMAP 2.3, 2.4, 2.9 (daemon side), 2.10.
#
# The decisions are exercised on the REAL vpnpoold functions: it is sourced with
# VPNPOOLD_NO_MAIN=1 (functions only) and VPNPOOL_LIBEXEC pointing at stub fetch/build/route
# scripts that record every call; sing-box start, the tunnel/WAN probes and notifications
# are replaced by stubs AFTER sourcing (each scenario runs in its own subshell).

DS="$T_STATE/daemon"; FL="$DS/libexec"; RLOG="$DS/rlog"
mkdir -p "$FL"
cat > "$FL/route.sh" <<EOF
#!/bin/sh
echo "route \$1" >> "$RLOG"
# a signal arriving WHILE the routes are being applied (USR1 from nodecheck / adaptive / UI)
if [ "\$1" = up ] && [ -f "$DS/sig_on_up" ]; then rm -f "$DS/sig_on_up"; kill -USR1 "\$(cat "$DS/pid")"; fi
exit \${ROUTE_RC:-0}
EOF
cat > "$FL/build.sh" <<EOF
#!/bin/sh
echo build >> "$RLOG"
[ -f "$DS/build_slow" ] && /bin/sleep 3
[ -f "$DS/build_fail" ] && exit 1
[ -f "$DS/build_fail_once" ] && { rm -f "$DS/build_fail_once"; exit 1; }
mkdir -p /tmp/vpnpool; echo "{\"gen\":\$\$}" > /tmp/vpnpool/sing-box.json
exit 0
EOF
cat > "$FL/fetch.sh" <<EOF
#!/bin/sh
echo fetch >> "$RLOG"
[ -f "$DS/fetch_slow" ] && /bin/sleep 20
exit 0
EOF
chmod +x "$FL"/*.sh

dstub() {
	start_singbox() { echo start >> "$RLOG"; SB_STARTED=$(date +%s); }
	kill_singbox() { echo kill >> "$RLOG"; }
	singbox_alive() { return 0; }
	probe_services() { [ "$(cat "$DS/tunnel" 2>/dev/null)" = up ]; }
	wan_alive() { [ "$(cat "$DS/wan" 2>/dev/null)" != down ]; }
	tg_notify() { echo "notify $1" >> "$RLOG"; }
	log() { echo "log $1" >> "$RLOG"; }
	sleep() { :; }
}
ds_reset() {   # <killswitch 0|1> <tunnel up|down>
	reset_state
	mkdir -p "$DS"; : > "$RLOG"; rm -f "$DS/build_fail" "$DS/routed" "$DS/fetch_slow" "$DS/build_slow" /var/run/vpnpool.restarting
	echo "$2" > "$DS/tunnel"; echo up > "$DS/wan"
	uci set vpnpool.main.killswitch="$1"; uci commit vpnpool
}
# in_daemon <fn> — run fn inside a subshell with the real vpnpoold functions + stubs
in_daemon() {
	(
		VPNPOOLD_NO_MAIN=1; VPNPOOL_LIBEXEC="$FL"; export VPNPOOLD_NO_MAIN VPNPOOL_LIBEXEC
		. /usr/libexec/vpnpool/vpnpoold
		dstub
		"$@"
		echo "$ROUTED" > "$DS/routed"
	) >/dev/null 2>&1
}
calls() { grep -E '^(build|fetch|start|route|do) ?' "$RLOG" | tr '\n' ';'; }
routed() { cat "$DS/routed" 2>/dev/null; }

# ---- the policy itself (pure function) ----
begin "daemon/route-policy-table"
pol() { sh -c '. /usr/libexec/vpnpool/lib.sh; route_policy "$1" "$2" "$3"' _ "$@"; }
expect_eq "ks=0 healthy"         "$(pol 0 1 0)" up
expect_eq "ks=0 dead -> direct"  "$(pol 0 0 0)" down
expect_eq "ks=1 healthy"         "$(pol 1 1 0)" up
expect_eq "ks=1 dead -> blocked" "$(pol 1 0 0)" up
expect_eq "paused, ks=0"         "$(pol 0 1 1)" down
expect_eq "paused, ks=1"         "$(pol 1 0 1)" down
end

# ---- reload order: routes are held while sing-box restarts, then the policy decides ----
sc_reload() { ROUTED=1; do_reload reload; }
ds_reset 1 down; in_daemon sc_reload
begin "daemon/reload-killswitch-dead-tunnel-keeps-routes"
expect_eq "call sequence" "$(calls)" "build;start;route up;"
expect_eq "routes never taken down" "$(gcount '^route down' "$RLOG")" 0
expect_eq "ROUTED" "$(routed)" 1
end

ds_reset 0 up; in_daemon sc_reload
begin "daemon/reload-healthy-keeps-routes"
expect_eq "call sequence (no down before/after the restart)" "$(calls)" "build;start;route up;"
expect_eq "ROUTED" "$(routed)" 1
end

ds_reset 0 down; in_daemon sc_reload
begin "daemon/reload-dead-tunnel-failsafe-down"
expect_eq "call sequence" "$(calls)" "build;start;route down;"
expect_eq "ROUTED" "$(routed)" 0
expect_eq "user told the LAN is on direct" "$(gcount '^notify .*no working node' "$RLOG")" 1
end

ds_reset 0 up; : > "$DS/build_fail"; in_daemon sc_reload
begin "daemon/reload-build-fails-keeps-config-and-routes"
expect_eq "call sequence" "$(calls)" "build;"
expect_eq "ROUTED" "$(routed)" 1
end

# periodic refresh goes through the SAME pipeline (fetch first)
sc_periodic() { ROUTED=1; periodic_refresh; }
ds_reset 0 down; in_daemon sc_periodic
begin "daemon/periodic-refresh-through-failsafe"
expect_eq "call sequence" "$(calls)" "fetch;build;start;route down;"
expect_eq "ROUTED" "$(routed)" 0
end

# start-up with no working node: a table left by a crashed run must be cleared (fail-safe)
sc_startup() { ROUTED=0; RE_ROUNDS=1 routing_eval startup; }
ds_reset 0 down; in_daemon sc_startup
begin "daemon/startup-dead-tunnel-clears-stale-routes"
expect_eq "call sequence" "$(calls)" "route down;"
expect_eq "ROUTED" "$(routed)" 0
end
ds_reset 1 down; in_daemon sc_startup
begin "daemon/startup-killswitch-routes-at-once"
expect_eq "call sequence" "$(calls)" "route up;"
expect_eq "ROUTED" "$(routed)" 1
end

# before the FIRST build (a crash restart, a build that keeps failing): kill-switch blocks at
# once, otherwise a table left by the crashed run is removed — before any build runs
sc_guard() { ROUTED=0; startup_guard; initial_build; }
ds_reset 0 down; : > "$DS/build_fail_once"; in_daemon sc_guard
begin "daemon/startup-guard-clears-stale-table-before-first-build"
expect_eq "first action" "$(calls | cut -d';' -f1)" "route down"
expect_eq "builds retried until one works" "$(gcount '^build' "$RLOG")" 2
expect_eq "silent (no notification)" "$(gcount '^notify' "$RLOG")" 0
end
ds_reset 1 down; : > "$DS/build_fail_once"; in_daemon sc_guard
begin "daemon/startup-guard-killswitch-blocks-before-first-build"
expect_eq "first action" "$(calls | cut -d';' -f1)" "route up"
expect_eq "ROUTED" "$(routed)" 1
end

# stop (TERM): routes down FIRST; a hanging Telegram send must not hold the stop
sc_cleanup() {
	tg_notify() { echo "notify $1" >> "$RLOG"; /bin/sleep 30; }
	ROUTED=1; cleanup
}
ds_reset 1 down
_t0=$(date +%s); in_daemon sc_cleanup; _dt=$(( $(date +%s) - _t0 ))
sleep 1
begin "daemon/stop-routes-down-first-notify-in-background"
expect_eq "first action" "$(grep -E '^(route|kill|notify)' "$RLOG" | head -1)" "route down"
expect_le "stop took seconds, not the 30 s of the hanging send" "$_dt" 5
expect_eq "sing-box stopped after the routes" "$(grep -E '^(route|kill)' "$RLOG" | tr '\n' ';')" "route down;kill;"
end
for p in $(pgrep -f '/bin/sleep 30'); do kill "$p" 2>/dev/null; done

# TERM during a LONG step (a 20-second fetch): ash defers a trap until a FOREGROUND child exits,
# procd SIGKILLs at term_timeout — so the step must run through run_child and cleanup at once
sc_term() { install_traps; sh -c 'echo $PPID' > "$DS/pid"; ROUTED=1; PENDING=refetch; serve_pending; }
ds_reset 0 up; : > "$DS/fetch_slow"; rm -f "$DS/pid"
in_daemon sc_term & _dp=$!
_i=0; while [ ! -s "$DS/pid" ] && [ $_i -lt 10 ]; do sleep 1; _i=$((_i+1)); done
sleep 1; _t0=$(date +%s); kill -TERM "$(cat "$DS/pid")"
wait "$_dp"; _dt=$(( $(date +%s) - _t0 ))
begin "daemon/term-during-long-fetch-cleans-up-at-once"
expect_le "cleanup within 3 s of TERM (the fetch would take 20 s)" "$_dt" 3
expect_eq "fetch started, then routes down + sing-box stopped, no build" "$(grep -E '^(fetch|build|start|route|kill)' "$RLOG" | tr '\n' ';')" "fetch;route down;kill;"
expect_eq "the fetch's own child was stopped too" "$(pgrep -f '/bin/sleep 20' | wc -l)" 0
end
for p in $(pgrep -f '/bin/sleep 20'); do kill "$p" 2>/dev/null; done

# a queued signal (USR1) during build does not lose build's exit code
sc_usr1_build() {
	install_traps; sh -c 'echo $PPID' > "$DS/pid"
	( sleep 1; kill -USR1 "$(cat "$DS/pid")" ) &
	ROUTED=1; do_reload reload; echo "rc=$?" > "$DS/rc"
}
ds_reset 0 up; : > "$DS/build_slow"; : > "$DS/build_fail"; in_daemon sc_usr1_build
begin "daemon/usr1-during-build-keeps-failure"
expect_eq "do_reload reports the failed build" "$(cat "$DS/rc")" "rc=1"
expect_eq "sing-box not restarted on a failed build" "$(gcount '^start' "$RLOG")" 0
end
ds_reset 0 up; : > "$DS/build_slow"; in_daemon sc_usr1_build
begin "daemon/usr1-during-build-keeps-success"   # positive control
expect_eq "build ok -> sing-box restarted" "$(gcount '^start' "$RLOG")" 1
end

# restart vs stop with the kill-switch on (integrator's assumption): a service restart keeps
# the block, a plain stop and the user's off remove it
sc_stop() { ROUTED=1; cleanup; }
ds_reset 1 down; uci set vpnpool.main.enabled=1; uci commit vpnpool; : > /var/run/vpnpool.restarting
in_daemon sc_stop
begin "daemon/restart-with-killswitch-keeps-block"
expect_eq "no route down" "$(gcount '^route down' "$RLOG")" 0
expect_eq "sing-box stopped" "$(gcount '^kill' "$RLOG")" 1
end
ds_reset 1 down; uci set vpnpool.main.enabled=1; uci commit vpnpool
in_daemon sc_stop
begin "daemon/stop-with-killswitch-removes-block"
expect_eq "route down" "$(gcount '^route down' "$RLOG")" 1
end
ds_reset 1 down; uci set vpnpool.main.enabled=0; uci commit vpnpool; : > /var/run/vpnpool.restarting
in_daemon sc_stop
begin "daemon/user-off-with-killswitch-removes-block-even-in-a-restart"
expect_eq "route down" "$(gcount '^route down' "$RLOG")" 1
end
rm -f /var/run/vpnpool.restarting

# a USR1 that arrives while the main loop applies the routes is QUEUED, not run inside the
# trap: the reload runs afterwards and its verdict is the last word (ROUTED == the table)
sc_sig() {
	install_traps
	sh -c 'echo $PPID' > "$DS/pid"
	: > "$DS/sig_on_up"
	ROUTED=0
	apply_routing 1          # the loop saw the tunnel alive; meanwhile it died (tunnel=down)
	echo "$ROUTED" > "$DS/r_after_up"
	serve_pending            # the main loop serves the queued reload
}
ds_reset 0 down; in_daemon sc_sig
begin "daemon/signal-during-route-up-no-desync"
expect_eq "routes were up before the queued reload ran" "$(cat "$DS/r_after_up")" 1
expect_eq "call sequence: up, then the reload, which takes them down" "$(calls)" "route up;build;start;route down;"
expect_eq "ROUTED matches the last action (down)" "$(routed)" 0
end

# ---- watchdog ----
sc_wd() {   # three supervise ticks with an old start time
	ROUTED=1; SB_STARTED=0
	watchdog_check; gcount '^route down' "$RLOG" > "$DS/after1"
	watchdog_check; watchdog_check
}
# a preferred node ("Connect") does not switch the watchdog off: a dead preferred node is exactly
# the case where the LAN must not stay in a black hole
ds_reset 0 down; uci set vpnpool.main.preferred_node=0123456789ab; uci commit vpnpool; in_daemon sc_wd
begin "daemon/watchdog-dead-tunnel-takes-routes-down"
expect_eq "one failed check is tolerated" "$(cat "$DS/after1")" 0
expect_eq "routes taken down once" "$(gcount '^route down' "$RLOG")" 1
expect_eq "ROUTED" "$(routed)" 0
expect_eq "notified" "$(gcount '^notify .*no working node' "$RLOG")" 1
end

ds_reset 1 down; in_daemon sc_wd
begin "daemon/watchdog-killswitch-keeps-routes"
expect_eq "no route down" "$(gcount '^route down' "$RLOG")" 0
expect_eq "ROUTED" "$(routed)" 1
end

ds_reset 0 down; echo down > "$DS/wan"; in_daemon sc_wd
begin "daemon/watchdog-wan-down-no-action"
expect_eq "no route down while WAN itself is down" "$(gcount '^route down' "$RLOG")" 0
expect_eq "ROUTED" "$(routed)" 1
end

ds_reset 0 up; in_daemon sc_wd
begin "daemon/watchdog-healthy-no-action"
expect_eq "no route call" "$(gcount '^route' "$RLOG")" 0
expect_eq "ROUTED" "$(routed)" 1
end

# ---- pause flag (Telegram /off /on): wins over the kill-switch, sing-box stays ----
sc_pause() {
	ROUTED=1
	: > "$PAUSE_FLAG"; on_hup; serve_pending; echo "$ROUTED" > "$DS/r_paused"
	rm -f "$PAUSE_FLAG"; on_hup; serve_pending
}
ds_reset 1 down; in_daemon sc_pause
begin "daemon/pause-flag-down-then-up"
expect_eq "paused -> down" "$(cat "$DS/r_paused")" 0
expect_eq "resumed (kill-switch) -> up" "$(routed)" 1
expect_eq "call sequence" "$(calls)" "route down;route up;"
expect_eq "sing-box not touched" "$(gcount -e '^start' -e '^kill' "$RLOG")" 0
end

# ---- reload requests are queued, never nested ----
sc_queue() {
	do_reload() {
		echo "do $1" >> "$RLOG"
		[ -f "$DS/reload_running_seen" ] || { [ -f "$SB_DATA/.reload_running" ] && : > "$DS/reload_running_seen"; }
		# two signals arrive while this reload runs (the handlers only queue)
		if [ ! -f "$DS/injected" ]; then : > "$DS/injected"; on_usr2; on_usr1; fi
	}
	request_reload reload
}
ds_reset 0 up; rm -f "$DS/injected" "$DS/reload_running_seen"; in_daemon sc_queue
begin "daemon/reload-queued-not-nested"
expect_eq "two sequential runs, the refetch wins the queue" "$(grep '^do' "$RLOG" | tr '\n' ';')" "do reload;do refetch;"
expect_true "busy flag visible during the reload" [ -f "$DS/reload_running_seen" ]
expect_true "busy flag removed afterwards" [ ! -f /tmp/vpnpool/.reload_running ]
end

# ---- preferred pin vs the dead set (2.10): auto takes over, the preference stays ----
FXD="$DS/clash"; mkdir -p "$FXD"
cat > "$FXD/proxies.json" <<'EOF'
{"proxies":{"proxy":{"now":"Node1"},"auto":{"now":"Node2"},"Node1":{"history":[{"delay":120}]},"Node2":{"history":[{"delay":90}]}}}
EOF
sc_pref() { preferred_check; }
# the stores key on the node ID (ROADMAP 2.2/9.5): the pin is Node1's id, the clash API knows the
# node by its tag of this build
pref_nodes() {
	printf 'vless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.81:443?security=tls#Node1\nvless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.82:443?security=tls#Node2\n' > "$DS/pref.links"
	ucode /usr/libexec/vpnpool/parser.uc --with-id "$DS/pref.links" > /tmp/vpnpool/nodes.json
	PID1=$(jq -r '.[0].id' /tmp/vpnpool/nodes.json)
}
ds_reset 0 up; pref_nodes
uci set vpnpool.main.preferred_node="$PID1"; uci commit vpnpool
jq -nc --arg i "$PID1" '[$i]' > /tmp/vpnpool/.dead_ids.json
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXD/proxies.json"; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204
in_daemon sc_pref
begin "daemon/preferred-in-dead-set-hands-to-auto-keeps-pin"
expect_true "control: an id ($PID1)" [ ${#PID1} -eq 12 ]
expect_eq "selector switched to auto" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/proxy')" 1
expect_eq "preference kept" "$(uci -q get vpnpool.main.preferred_node)" "$PID1"
end
sed 's/"now":"Node1"/"now":"auto"/' "$FXD/proxies.json" > "$FXD/p2.json"
echo '[]' > /tmp/vpnpool/.dead_ids.json
rm -f /tmp/curlmock/calls.log; mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXD/p2.json"; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204
in_daemon sc_pref
begin "daemon/preferred-recovered-switches-back"   # positive control: the pin still acts
expect_eq "selector switched back to the preferred node (by its tag)" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/proxy')" 1
expect_eq "preference kept" "$(uci -q get vpnpool.main.preferred_node)" "$PID1"
end
# a preferred node that left the pool: cleared after 4 ticks — never while a rebuild runs, never
# for a favourite (it comes back with the node)
sc_pref4() { preferred_check; preferred_check; preferred_check; preferred_check; }
ds_reset 0 up; pref_nodes
uci set vpnpool.main.preferred_node=0123456789ab; uci commit vpnpool
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXD/p2.json"
: > /tmp/vpnpool/.reload_running; in_daemon sc_pref4; rm -f /tmp/vpnpool/.reload_running
_during=$(uci -q get vpnpool.main.preferred_node)
echo '{"0123456789ab":{"tag":"Fav","link":"vless://x","active":true,"auto":false}}' > /etc/vpnpool/favorites.map.json
in_daemon sc_pref4
_fav=$(uci -q get vpnpool.main.preferred_node)
rm -f /etc/vpnpool/favorites.map.json
in_daemon sc_pref4
begin "daemon/preferred-gone-cleared-except-rebuild-or-favourite"
expect_eq "kept while a rebuild runs" "$_during" 0123456789ab
expect_eq "kept for a favourite" "$_fav" 0123456789ab
expect_eq "cleared after 4 ticks otherwise" "$(uci -q get vpnpool.main.preferred_node)" ''
end

# ---- nodecheck: no verdicts while WAN is down (2.10) ----
nc_setup() {   # <wan code>
	reset_state
	U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
	printf 'vless://%s@203.0.113.71:443?security=tls&sni=a.example#Node1\n' "$U" > "$DS/l.txt"
	ucode /usr/libexec/vpnpool/parser.uc --with-id "$DS/l.txt" > /tmp/vpnpool/nodes.json
	mock_on   # every clash delay probe fails (no rule -> 000)
	mock_rule 'GET http://cp.cloudflare.com/generate_204' "$1"
	mock_rule 'GET http://connectivitycheck.gstatic.com/generate_204' "$1"
	NODECHECK_DRYRUN=1 sh /usr/libexec/vpnpool/nodecheck.sh >/dev/null 2>&1
}
nc_setup 000
begin "daemon/nodecheck-wan-down-judges-nothing"
expect_eq "no delay probe sent" "$(mock_calls '/delay?')" 0
expect_eq "no strike recorded" "$(cat /tmp/vpnpool/.deadstrikes 2>/dev/null | wc -l)" 0
end
nc_setup 204
begin "daemon/nodecheck-wan-up-strikes-dead-node"   # positive control
expect_true "delay probes sent" [ "$(mock_calls '/delay?')" -ge 1 ]
_nid=$(jq -r '.[0].id' /tmp/vpnpool/nodes.json)
expect_eq "strike recorded by the node id ($_nid)" "$(awk -F'\t' -v k="$_nid" '$1==k{print $2}' /tmp/vpnpool/.deadstrikes 2>/dev/null)" 1
expect_true "dead set is valid JSON" jq -e 'type=="array"' /tmp/vpnpool/.dead_ids.json
end

# ---- the single "is it alive" criterion (2.4) ----
printf '. /usr/libexec/vpnpool/lib.sh\n"$@"\n' > "$DS/libcall.sh"
lc() { sh "$DS/libcall.sh" "$@"; }
not() { ! "$@"; }
begin "daemon/alive-criterion"
expect_true "204 alive" lc svc_code_alive 204
expect_true "301 alive" lc svc_code_alive 301
expect_true "404 alive (the host answered)" lc svc_code_alive 404
expect_true "000 dead" not lc svc_code_alive 000
expect_true "empty dead" not lc svc_code_alive ""
expect_true "clash delay reply alive" lc clash_delay_alive '{"delay":12}'
expect_true "clash error reply dead" not lc clash_delay_alive '{"message":"timeout"}'
end
reset_state
uci set vpnpool.main.check_services='www.youtube.com https://chat.example/x'; uci commit vpnpool
mock_on; mock_rule 'P GET http://www.youtube.com/generate_204' 204
begin "daemon/probe-services-any-vs-all"
expect_true "any: one service answers" lc probe_services http://127.0.0.1:1605 any
expect_true "all: the second does not" not lc probe_services http://127.0.0.1:1605 all
expect_eq "urltest url == first service" "$(lc primary_probe_url)" 'http://www.youtube.com/generate_204'
end

# ---- route.sh on real nft (container netns, NET_ADMIN) ----
reset_state
ip link add br-lan type bridge 2>/dev/null; ip link set br-lan up 2>/dev/null
uci set vpnpool.main.lan_if=br-lan; uci commit vpnpool
mkdir -p "$DS/nftshim"
printf '#!/bin/sh\necho "nft $*" >> %s/nft.calls\nexec /usr/sbin/nft "$@"\n' "$DS" > "$DS/nftshim/nft"; chmod +x "$DS/nftshim/nft"
: > "$DS/nft.calls"
PATH="$DS/nftshim:$PATH" sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1; r1=$?
PATH="$DS/nftshim:$PATH" sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1; r2=$?
begin "daemon/route-up-atomic-idempotent"
expect_true "nft usable here (positive control)" nft list tables
expect_eq "first up rc" "$r1" 0
expect_eq "second up rc" "$r2" 0
expect_true "table present" nft list table inet vpnpool
expect_eq "exactly one ip rule" "$(ip rule show | gcount 'fwmark 0x400000/0x400000 lookup 142')" 1
expect_eq "no separate 'delete table' before re-applying" "$(gcount 'nft delete table' "$DS/nft.calls")" 0
expect_eq "IPv6 guard in the same transaction: one 'nft -f' per up" "$(gcount '^nft -f' "$DS/nft.calls")" 2
expect_true "v6filter chain present (ipv6=block)" nft list chain inet vpnpool v6filter
end
uci set vpnpool.main.killswitch=1; uci set vpnpool.main.mode=exclude; uci commit vpnpool
sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1
begin "daemon/route-killswitch-marks-all-lan-traffic"
expect_true "tcp mark on every port" sh -c 'nft list chain inet vpnpool prerouting | grep -q "iifname \"br-lan\" meta l4proto tcp meta mark set"'
end
sh /usr/libexec/vpnpool/route.sh down >/dev/null 2>&1
begin "daemon/route-down-removes-everything"
expect_true "table gone" sh -c '! nft list table inet vpnpool'
expect_eq "rule gone" "$(ip rule show | gcount 'fwmark 0x400000/0x400000')" 0
end

# ---- per-node tests never touch the LAN selector (2.8); by node id, results keyed by it ----
reset_state
uci set vpnpool.main.speedtest_min_mem_kb=1; uci commit vpnpool
printf 'vless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.71:443?security=tls#Node1\n' > "$DS/nt.links"
ucode /usr/libexec/vpnpool/parser.uc --with-id "$DS/nt.links" > /tmp/vpnpool/nodes.json
NID=$(jq -r '.[0].id' /tmp/vpnpool/nodes.json)
head -c 5000 /dev/zero > "$DS/blob"
mock_on
mock_rule 'PUT http://127.0.0.1:9091/proxies/vpnpool-test' 204
mock_rule 'P GET https://speed.cloudflare.com/*' 200 "$DS/blob"
mock_rule 'P GET https://www.youtube.com/' 200 "$DS/blob"
sh /usr/libexec/vpnpool/speedtest.sh "$NID" >/dev/null 2>&1
sh /usr/libexec/vpnpool/unlock.sh Node1 >/dev/null 2>&1   # the tag still works (older screens, the bot)
begin "daemon/node-tests-use-test-selector-only"
expect_eq "test selector switched (speedtest + unlock)" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/vpnpool-test')" 2
expect_eq "LAN selector never touched" "$(mock_calls 'proxies/proxy')" 0
expect_true "speedtest measured through the test path, result names the id" jq -e --arg i "$NID" '.ok==true and .bytes>0 and .id==$i and .tag=="Node1"' /tmp/vpnpool/.speedtest-result.json
expect_true "unlock result" jq -e '.ok==true and .results.youtube==true and .results.google==false' /tmp/vpnpool/.unlock-result.json
expect_true "unlock badges kept by the node id" jq -e --arg i "$NID" '.[$i].youtube==true and (has("Node1")|not)' /etc/vpnpool/unlock.map.json
expect_true "lock released" [ ! -d /tmp/vpnpool/.nodetest.lock ]
end
rm -f /tmp/curlmock/calls.log; mock_on
mock_rule 'PUT http://127.0.0.1:9091/proxies/vpnpool-test' 404
mock_rule 'P GET https://speed.cloudflare.com/*' 200 "$DS/blob"
sh /usr/libexec/vpnpool/speedtest.sh "$NID" >/dev/null 2>&1
begin "daemon/node-test-refused-selector-no-download"
expect_true "honest failure" jq -e '.ok==false and .code=="not_found"' /tmp/vpnpool/.speedtest-result.json
expect_eq "no download through a selector that did not switch" "$(mock_calls 'speed.cloudflare.com')" 0
end
rm -f /tmp/curlmock/calls.log; mock_on
mock_rule 'PUT http://127.0.0.1:9091/proxies/vpnpool-test' 204
sh /usr/libexec/vpnpool/speedtest.sh Gone >/dev/null 2>&1
begin "daemon/node-test-unknown-node-touches-nothing"
expect_true "not_found" jq -e '.ok==false and .code=="not_found"' /tmp/vpnpool/.speedtest-result.json
expect_eq "the test selector not even switched" "$(mock_calls 'vpnpool-test')" 0
end

# ---- route.sh: refused new rules never remove the working ones (fail-closed) ----
uci set vpnpool.main.killswitch=1; uci set vpnpool.main.mode=exclude; uci -q delete vpnpool.main.client; uci add_list vpnpool.main.client='192.168.1.50'; uci commit vpnpool
sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1
uci add_list vpnpool.main.client='999.1.1.1'; uci commit vpnpool   # nft refuses this address
sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1; rf=$?
begin "daemon/route-refused-reapply-keeps-old-table"
expect_eq "route.sh reports the failure" "$rf" 1
expect_true "the working table is still there" nft list chain inet vpnpool prerouting
expect_true "it is the OLD table (its client set), not a fallback" sh -c 'nft list set inet vpnpool clients | grep -q 192.168.1.50'
expect_true "with its kill-switch marking" sh -c 'nft list chain inet vpnpool prerouting | grep -q "iifname \"br-lan\" meta l4proto tcp meta mark set"'
expect_eq "ip rule kept" "$(ip rule show | gcount 'fwmark 0x400000/0x400000 lookup 142')" 1
end
sh /usr/libexec/vpnpool/route.sh down >/dev/null 2>&1
sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1; rf=$?
begin "daemon/route-refused-no-table-killswitch-blocks"
expect_eq "route.sh reports the failure" "$rf" 1
expect_true "blocking table installed anyway" sh -c 'nft list chain inet vpnpool prerouting | grep -q "tproxy"'
expect_true "without the refused client set" sh -c '! nft list set inet vpnpool clients'
expect_true "IPv6 guard there too" nft list chain inet vpnpool v6filter
end
sh /usr/libexec/vpnpool/route.sh down >/dev/null 2>&1
uci set vpnpool.main.killswitch=0; uci commit vpnpool
sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1; rf=$?
begin "daemon/route-refused-no-table-no-killswitch-direct"   # control: no block without the kill-switch
expect_eq "route.sh reports the failure" "$rf" 1
expect_true "no table (LAN direct, honest failure)" sh -c '! nft list table inet vpnpool'
end

# ---- "add working nodes to the favourites automatically" (snapshot.sh, review V1/V2) ----
reset_state
uci set vpnpool.main.auto_snapshot=1; uci set vpnpool.main.auto_snapshot_max=5; uci commit vpnpool
printf 'vless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.81:443?security=tls#Node1\nvless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.82:443?security=tls#Node2\n' > "$DS/snap.links"
ucode /usr/libexec/vpnpool/parser.uc --with-id "$DS/snap.links" > /tmp/vpnpool/nodes.json
SN1=$(jq -r '.[0].id' /tmp/vpnpool/nodes.json); SN2=$(jq -r '.[1].id' /tmp/vpnpool/nodes.json)
echo '{"proxies":{"Node1":{"history":[{"delay":100}]},"Node2":{"history":[{"delay":0}]}}}' > "$DS/snap1.json"
echo '{"proxies":{"Node1":{"history":[]},"Node2":{"history":[]}}}' > "$DS/snap0.json"
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$DS/snap1.json"
sh /usr/libexec/vpnpool/snapshot.sh >/dev/null 2>&1
begin "daemon/snapshot-keeps-the-working-nodes"
expect_true "Node1 (working) an automatic favourite, Node2 (dead) not" jq -e --arg a "$SN1" --arg b "$SN2" '.[$a].auto==true and .[$a].tag=="Node1" and (has($b)|not)' /etc/vpnpool/favorites.map.json
end
cp /etc/vpnpool/favorites.map.json "$DS/fav.before"
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$DS/snap0.json"
sh /usr/libexec/vpnpool/snapshot.sh >/dev/null 2>&1
begin "daemon/snapshot-nothing-answers-keeps-the-set"
expect_true "the automatic favourites unchanged when no node answers" cmp -s /etc/vpnpool/favorites.map.json "$DS/fav.before"
end
# an automatic favourite the user put into the pool (active) survives a snapshot that drops it
jq --arg a "$SN1" '.[$a].active = true' "$DS/fav.before" > /etc/vpnpool/favorites.map.json
echo '{"proxies":{"Node1":{"history":[{"delay":0}]},"Node2":{"history":[{"delay":90}]}}}' > "$DS/snap2.json"
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$DS/snap2.json"
sh /usr/libexec/vpnpool/snapshot.sh >/dev/null 2>&1
begin "daemon/snapshot-keeps-an-active-automatic-favourite"
expect_true "Node1 kept (active), Node2 added" jq -e --arg a "$SN1" --arg b "$SN2" '.[$a].active==true and .[$b].auto==true' /etc/vpnpool/favorites.map.json
end

# ---- ui2: what the Overview / Nodes read from the daemon's background checks ----
# (1) the tunnel state the watchdog saw (.tunnel "<state> <since>", rewritten only on a change)
sc_tstate() {
	SB_STARTED=$(date +%s); watchdog_check; cp "$TUNNEL_FILE" "$DS/t0"   # warm-up: not judged
	SB_STARTED=0; watchdog_check; cp "$TUNNEL_FILE" "$DS/t1"
	/bin/sleep 1; watchdog_check; cp "$TUNNEL_FILE" "$DS/t2"            # still up: unchanged
	echo down > "$DS/tunnel"; watchdog_check; cp "$TUNNEL_FILE" "$DS/t3"
	echo down > "$DS/wan"; watchdog_check; cp "$TUNNEL_FILE" "$DS/t4"
}
ds_reset 0 up; rm -f "$DS"/t[0-4]; in_daemon sc_tstate
begin "daemon/tunnel-state-for-the-overview"
expect_true "positive control: all five states written" test -s "$DS/t4"
expect_eq "warm-up" "$(cut -d' ' -f1 "$DS/t0")" starting
expect_eq "healthy" "$(cut -d' ' -f1 "$DS/t1")" up
expect_true "since = a time" grep -qE '^up [0-9]{9,}$' "$DS/t1"
expect_true "still healthy a second later: since unchanged" cmp -s "$DS/t1" "$DS/t2"
expect_eq "dead while WAN works" "$(cut -d' ' -f1 "$DS/t3")" down
expect_eq "the router has no internet" "$(cut -d' ' -f1 "$DS/t4")" wan_down
end
# (2) the exit lookup: only with a working tunnel, on a node change, again after 30 min (5 min
# after a lookup that found nothing) — never per tick
printf '#!/bin/sh\necho "exitip $1" >> %s\n' "$RLOG" > "$FL/exitip.sh"; chmod +x "$FL/exitip.sh"
sc_exit() {
	WD_HEALTHY=1
	exit_info_check A 1000; exit_info_check A 1100           # the same node 100 s later: no second lookup
	exit_info_check B 1150                                    # the node changed: a lookup
	echo '{"ok":false,"ip":""}' > "$SB_DATA/exit.json"
	exit_info_check B 1460                                    # found nothing, 5 min later: again
	echo '{"ok":true,"ip":"198.51.100.7"}' > "$SB_DATA/exit.json"
	exit_info_check B 1770                                    # found, 5 min later: not again
	exit_info_check B 3300                                    # found, 30 min later: again
	WD_HEALTHY=0; exit_info_check C 4000                      # the tunnel does not work: never
	WD_HEALTHY=""; exit_info_check C 4001                     # not judged (warm-up): never
	exit_info_check "" 4002
	wait
}
ds_reset 0 up; in_daemon sc_exit
begin "daemon/exit-lookup-only-when-needed"
expect_eq "node A looked up once" "$(gcount '^exitip A$' "$RLOG")" 1
expect_eq "node B: change, retry after nothing, 30 min" "$(gcount '^exitip B$' "$RLOG")" 3
expect_eq "never without a working tunnel" "$(gcount '^exitip C' "$RLOG")" 0
expect_eq "nothing else" "$(gcount '^exitip' "$RLOG")" 4
end
# (3) exitip.sh: through the tunnel only, the first service with an address, country upper case
reset_state; mock_on
echo '{"ip":"<b>blocked</b>"}' > "$DS/ex_junk"
echo '{"ip":"198.51.100.7","country":"de"}' > "$DS/ex_ok"
mock_rule 'P GET https://ifconfig.co/json' 200 "$DS/ex_junk"
mock_rule 'P GET https://ipinfo.io/json' 200 "$DS/ex_ok"
sh /usr/libexec/vpnpool/exitip.sh NodeA >/dev/null 2>&1
begin "daemon/exitip-first-address-through-the-tunnel"
expect_true "ip, country, node, time" jq -e '.ok==true and .ip=="198.51.100.7" and .country=="DE" and .node=="NodeA" and (.at|type)=="number"' /tmp/vpnpool/exit.json
expect_eq "no direct request" "$(gcount '^GET ' /tmp/curlmock/calls.log)" 0
expect_eq "stops at the first address" "$(mock_calls 'api.ip.sb')" 0
expect_true "no lock left" test ! -e /tmp/vpnpool/.exitip-running
end
mock_on; : > /tmp/curlmock/calls.log   # nothing answers
sh /usr/libexec/vpnpool/exitip.sh NodeA >/dev/null 2>&1
begin "daemon/exitip-nothing-answers-says-so"
expect_true "ok false, no address" jq -e '.ok==false and .ip=="" and .node=="NodeA"' /tmp/vpnpool/exit.json
expect_eq "every service tried" "$(mock_calls '^P GET https://')" 4
end
# (4) nodecheck: the strike file says when and which checked host a node did not reach
reset_state
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
printf 'vless://%s@203.0.113.71:443?security=tls&sni=a.example#Node1\nvless://%s@203.0.113.72:443?security=tls&sni=b.example#Node2\n' "$U" "$U" > "$DS/l2.txt"
ucode /usr/libexec/vpnpool/parser.uc --with-id "$DS/l2.txt" > /tmp/vpnpool/nodes.json
uci set vpnpool.main.check_services='www.youtube.com https://chat.example/x'; uci set vpnpool.main.dead_filter_tries=1; uci commit vpnpool
echo '{"delay":42}' > "$DS/d42"
mock_on
mock_rule 'GET http://cp.cloudflare.com/generate_204' 204
mock_rule 'GET http://connectivitycheck.gstatic.com/generate_204' 204
mock_rule 'GET http://127.0.0.1:9091/proxies/Node1/delay?url=http%3A%2F%2Fwww.youtube.com*' 200 "$DS/d42"
mock_rule 'GET http://127.0.0.1:9091/proxies/Node2/delay?url=*' 200 "$DS/d42"
NODECHECK_DRYRUN=1 sh /usr/libexec/vpnpool/nodecheck.sh >/dev/null 2>&1
N1=$(jq -r '.[0].id' /tmp/vpnpool/nodes.json); N2=$(jq -r '.[1].id' /tmp/vpnpool/nodes.json)
sline() { awk -F'\t' -v k="$1" '$1==k{print $2 "|" (($3 ~ /^[0-9]+$/ && length($3) >= 9) ? "time" : "no-time:" $3) "|" $4}' /tmp/vpnpool/.deadstrikes; }
begin "daemon/nodecheck-strikes-say-when-and-which-host"
expect_eq "positive control: the passing node, no failed host" "$(sline "$N2")" '0|time|'
expect_eq "the failing node: one strike, when, the host it did not reach" "$(sline "$N1")" '1|time|chat.example'
expect_eq "one line per node" "$(grep -c . /tmp/vpnpool/.deadstrikes)" 2
end
