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
exit \${ROUTE_RC:-0}
EOF
cat > "$FL/build.sh" <<EOF
#!/bin/sh
echo build >> "$RLOG"
[ -f "$DS/build_fail" ] && exit 1
mkdir -p /tmp/vpnpool; echo "{\"gen\":\$\$}" > /tmp/vpnpool/sing-box.json
exit 0
EOF
cat > "$FL/fetch.sh" <<EOF
#!/bin/sh
echo fetch >> "$RLOG"
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
	mkdir -p "$DS"; : > "$RLOG"; rm -f "$DS/build_fail" "$DS/routed"
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

# ---- watchdog ----
sc_wd() {   # three supervise ticks with an old start time
	ROUTED=1; SB_STARTED=0
	watchdog_check; gcount '^route down' "$RLOG" > "$DS/after1"
	watchdog_check; watchdog_check
}
ds_reset 0 down; uci set vpnpool.main.selected_node=Node1; uci commit vpnpool; in_daemon sc_wd
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
	: > "$PAUSE_FLAG"; on_hup; echo "$ROUTED" > "$DS/r_paused"
	rm -f "$PAUSE_FLAG"; on_hup
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
		echo "do $1 depth=$RELOADING" >> "$RLOG"
		[ -f "$DS/reload_running_seen" ] || { [ -f "$SB_DATA/.reload_running" ] && : > "$DS/reload_running_seen"; }
		if [ ! -f "$DS/injected" ]; then : > "$DS/injected"; request_reload refetch; request_reload reload; fi
	}
	request_reload reload
}
ds_reset 0 up; rm -f "$DS/injected" "$DS/reload_running_seen"; in_daemon sc_queue
begin "daemon/reload-queued-not-nested"
expect_eq "two sequential runs, the refetch wins the queue" "$(grep '^do' "$RLOG" | tr '\n' ';')" "do reload depth=1;do refetch depth=1;"
expect_true "busy flag visible during the reload" [ -f "$DS/reload_running_seen" ]
expect_true "busy flag removed afterwards" [ ! -f /tmp/vpnpool/.reload_running ]
end

# ---- preferred pin vs the dead set (2.10): auto takes over, the preference stays ----
FXD="$DS/clash"; mkdir -p "$FXD"
cat > "$FXD/proxies.json" <<'EOF'
{"proxies":{"proxy":{"now":"Node1"},"auto":{"now":"Node2"},"Node1":{"history":[{"delay":120}]},"Node2":{"history":[{"delay":90}]}}}
EOF
sc_pref() { preferred_check; }
ds_reset 0 up
uci set vpnpool.main.preferred_node=Node1; uci commit vpnpool
echo '["Node1"]' > /tmp/vpnpool/.dead_tags.json
mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXD/proxies.json"; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204
in_daemon sc_pref
begin "daemon/preferred-in-dead-set-hands-to-auto-keeps-pin"
expect_eq "selector switched to auto" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/proxy')" 1
expect_eq "preference kept" "$(uci -q get vpnpool.main.preferred_node)" Node1
end
sed 's/"now":"Node1"/"now":"auto"/' "$FXD/proxies.json" > "$FXD/p2.json"
echo '[]' > /tmp/vpnpool/.dead_tags.json
rm -f /tmp/curlmock/calls.log; mock_on; mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXD/p2.json"; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204
in_daemon sc_pref
begin "daemon/preferred-recovered-switches-back"   # positive control: the pin still acts
expect_eq "selector switched back to the preferred node" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/proxy')" 1
expect_eq "preference kept" "$(uci -q get vpnpool.main.preferred_node)" Node1
end

# ---- nodecheck: no verdicts while WAN is down (2.10) ----
nc_setup() {   # <wan code>
	reset_state
	U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
	printf 'vless://%s@203.0.113.71:443?security=tls&sni=a.example#Node1\n' "$U" > "$DS/l.txt"
	ucode /usr/libexec/vpnpool/parser.uc "$DS/l.txt" > /tmp/vpnpool/nodes.json
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
expect_eq "strike recorded" "$(awk -F'\t' '$1=="Node1"{print $2}' /tmp/vpnpool/.deadstrikes 2>/dev/null)" 1
expect_true "dead set is valid JSON" jq -e 'type=="array"' /tmp/vpnpool/.dead_tags.json
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
