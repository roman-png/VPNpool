# suite: tgbot — Telegram bot: /on /off via the pause flag + SIGHUP, direct poll when the
# proxy port is down, sweep kills only OUR pollers, init.d bot instance (sourced by run.sh).
# ROADMAP 2.9. tgbot.sh is sourced with TGBOT_NO_MAIN=1 (functions only) in a subshell.

TB="$T_STATE/tgbot"; mkdir -p "$TB"
TINIT="$TB/initd.calls"
in_bot() {   # <fn...> — run inside a subshell with the real tgbot.sh functions loaded
	( TGBOT_NO_MAIN=1; export TGBOT_NO_MAIN; . /usr/libexec/vpnpool/tgbot.sh; "$@" )
}
stub_initd() {
	printf '#!/bin/sh\necho "vpnpool $*" >> %s\n' "$TINIT" > /etc/init.d/vpnpool
	# like procd: a reload with enabled=0 stops the daemon instance (TERM)
	cat >> /etc/init.d/vpnpool <<'EOF'
[ "$1" = reload ] && [ "$(uci -q get vpnpool.main.enabled)" = 0 ] && kill "$(cat /var/run/vpnpool.pid 2>/dev/null)" 2>/dev/null
exit 0
EOF
	chmod +x /etc/init.d/vpnpool; : > "$TINIT"
}
PAUSE=/tmp/vpnpool/.routing_paused

# ---- /off with the daemon running: pause flag + HUP, service stays enabled ----
reset_state; stub_initd; uci set vpnpool.main.enabled=1; uci commit vpnpool; daemon_start
OUT=$(in_bot cmd_off)
begin "tgbot/off-sets-pause-and-signals-daemon"
expect_true "pause flag set" [ -f "$PAUSE" ]
expect_true "daemon got HUP" [ "$(signals_seen HUP)" -ge 1 ]
expect_eq "service stays enabled (the bot path needs the tunnel)" "$(uci -q get vpnpool.main.enabled)" 1
expect_eq "no init.d call" "$(cat "$TINIT" | wc -l)" 0
expect_eq "reply" "$OUT" "routing OFF (tunnel kept alive for control)"
end
: > "$FAKED_LOG"
OUT=$(in_bot cmd_on)
begin "tgbot/on-clears-pause-and-signals-daemon"
expect_true "pause flag cleared" [ ! -f "$PAUSE" ]
expect_true "daemon got HUP" [ "$(signals_seen HUP)" -ge 1 ]
expect_eq "reply" "$OUT" "routing ON"
end

# ---- /on with the service off: it is switched on through init.d (no route.sh from the bot) ----
reset_state; stub_initd; uci set vpnpool.main.enabled=0; uci commit vpnpool; daemon_stop
: > "$PAUSE"
OUT=$(in_bot cmd_on)
begin "tgbot/on-with-service-off-starts-it"
expect_eq "enabled=1" "$(uci -q get vpnpool.main.enabled)" 1
expect_eq "init.d enable + start" "$(tr '\n' ';' < "$TINIT")" "vpnpool enable;vpnpool start;"
expect_true "pause flag cleared" [ ! -f "$PAUSE" ]
expect_true "no routing table touched by the bot" sh -c '! nft list table inet vpnpool'
end
OUT=$(in_bot cmd_off)
begin "tgbot/off-with-service-off-is-honest"
expect_true "no stale pause flag left" [ ! -f "$PAUSE" ]
expect_eq "reply" "$OUT" "routing is already off (service not running)"
end

# ---- /refresh is honest about a stopped service ----
reset_state; daemon_stop
begin "tgbot/refresh-no-daemon"
expect_eq "reply" "$(in_bot cmd_refresh)" "service not running — nothing to refresh"
end
reset_state; daemon_start
begin "tgbot/refresh-signals-usr2"
expect_eq "reply" "$(in_bot cmd_refresh)" "refreshing subscription…"
expect_true "daemon got USR2" [ "$(signals_seen USR2)" -ge 1 ]
end

# ---- poll transport: proxy port refused (sing-box down) -> DIRECT; proxy up -> proxy only ----
reset_state
uci set vpnpool.main.telegram_via_proxy=1; uci commit vpnpool
echo '{"ok":true,"result":[]}' > "$TB/upd.json"
mock_on; mock_rule 'GET https://api.telegram.org/bot1:T/getUpdates*' 200 "$TB/upd.json"
OUT=$(in_bot tg_poll -m 5 'https://api.telegram.org/bot1:T/getUpdates?timeout=1')
begin "tgbot/poll-direct-when-proxy-refused"
expect_eq "body via the direct path" "$OUT" '{"ok":true,"result":[]}'
expect_eq "proxy tried first" "$(mock_calls '^P GET https://api.telegram.org/bot1:T/getUpdates')" 1
expect_eq "then direct" "$(mock_calls '^GET https://api.telegram.org/bot1:T/getUpdates')" 1
end
rm -f /tmp/curlmock/calls.log
mock_on; mock_rule 'P GET https://api.telegram.org/bot1:T/getUpdates*' 200 "$TB/upd.json"
OUT=$(in_bot tg_poll -m 5 'https://api.telegram.org/bot1:T/getUpdates?timeout=1')
begin "tgbot/poll-proxy-only-when-proxy-up"   # positive control: no direct when the proxy works
expect_eq "body via the proxy" "$OUT" '{"ok":true,"result":[]}'
expect_eq "no direct request" "$(mock_calls '^GET https://api.telegram.org/bot1:T/getUpdates')" 0
end

# ---- sweep: kills another tgbot poller of OUR token, never a foreign bot's getUpdates ----
reset_state
uci set vpnpool.main.telegram_token='111:OURS'; uci commit vpnpool
sh -c 'while :; do sleep 1; done' x 'https://api.telegram.org/bot111:OURS/getUpdates' >/dev/null 2>&1 &
OURS=$!
sh -c 'while :; do sleep 1; done' x 'https://api.telegram.org/bot222:OTHER/getUpdates' >/dev/null 2>&1 &
OTHER=$!
sleep 1
in_bot sweep_other_pollers >/dev/null 2>&1
sleep 1
p_alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null; }
p_dead() { ! p_alive "$1"; }
begin "tgbot/sweep-only-own-token"
expect_true "foreign getUpdates poller still running (positive control)" p_alive "$OTHER"
expect_true "our stale getUpdates poller killed" p_dead "$OURS"
end
kill "$OURS" "$OTHER" 2>/dev/null; wait "$OURS" "$OTHER" 2>/dev/null

# ---- init.d: the bot runs with the service disabled; token change = new instance signature ----
initd_probe() {   # prints the procd calls start_service makes (procd stubbed)
	(
		. /lib/functions.sh
		procd_open_instance() { echo "open $1"; }
		procd_set_param() { echo "param $*"; }
		procd_close_instance() { :; }
		logger() { :; }
		. "$REPO/package/vpnpool/files/etc/init.d/vpnpool"
		start_service
	) 2>/dev/null
}
reset_state
uci set vpnpool.main.enabled=0; uci set vpnpool.main.telegram_control=1
uci set vpnpool.main.telegram_token='111:A'; uci set vpnpool.main.telegram_chat=42; uci commit vpnpool
P1=$(initd_probe)
uci set vpnpool.main.telegram_token='111:B'; uci commit vpnpool
P2=$(initd_probe)
uci set vpnpool.main.telegram_control=0; uci commit vpnpool
P3=$(initd_probe)
begin "tgbot/initd-bot-instance"
expect_eq "bot instance with the service disabled" "$(printf '%s\n' "$P1" | gcount '^open tgbot$')" 1
expect_eq "no daemon instance when disabled" "$(printf '%s\n' "$P1" | gcount '^open vpnpoold$')" 0
expect_eq "signature param present" "$(printf '%s\n' "$P1" | gcount '^param env VPNPOOL_TG_SIG=')" 1
expect_true "token change changes the instance params" [ "$(printf '%s\n' "$P1" | grep VPNPOOL_TG_SIG)" != "$(printf '%s\n' "$P2" | grep VPNPOOL_TG_SIG)" ]
expect_eq "token never in the instance params" "$(printf '%s\n%s\n' "$P1" "$P2" | gcount '111:')" 0
expect_eq "no bot when telegram_control=0" "$(printf '%s\n' "$P3" | gcount '^open tgbot$')" 0
end

# ---- init.d through the REAL rc.common: what procd is actually sent (ubus stubbed) ----
mkdir -p "$TB/ubusshim"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/ubus.calls\nexit 0\n' "$TB" > "$TB/ubusshim/ubus"; chmod +x "$TB/ubusshim/ubus"
initd_real() {   # <rc.common command> -> the JSON of the "ubus call service set|add" request
	: > "$TB/ubus.calls"
	PATH="$TB/ubusshim:$PATH" sh /etc/rc.common "$REPO/package/vpnpool/files/etc/init.d/vpnpool" "$1" >/dev/null 2>&1
	grep '^call service \(set\|add\) ' "$TB/ubus.calls" | head -1 | sed 's/^call service [a-z]* //'
}
reset_state
uci set vpnpool.main.enabled=0; uci set vpnpool.main.telegram_control=1
uci set vpnpool.main.telegram_token='111:A'; uci set vpnpool.main.telegram_chat=42; uci commit vpnpool
J0=$(initd_real reload)
uci set vpnpool.main.enabled=1; uci commit vpnpool
J1=$(initd_real reload)
begin "tgbot/initd-reload-really-reaches-procd"
expect_jq "reload sends the instance set (enabled=0)" "$J0" '.instances|type=="object"'
expect_jq "enabled=0: bot instance only" "$J0" '(.instances|has("tgbot")) and ((.instances|has("vpnpoold"))|not)'
expect_jq "enabled=1: daemon + bot" "$J1" '(.instances|has("tgbot")) and (.instances|has("vpnpoold"))'
expect_jq "daemon TERM window > 5 s" "$J1" '.instances.vpnpoold.term_timeout >= 15'
end
rm -f /var/run/vpnpool.restarting
J2=$(initd_real restart)
begin "tgbot/initd-restart-marks-a-restart"
expect_true "restart leaves the marker the daemon's cleanup reads" [ -f /var/run/vpnpool.restarting ]
expect_jq "and still starts the service" "$J2" '.instances|has("vpnpoold")'
end
rm -f /var/run/vpnpool.restarting
initd_real stop >/dev/null
begin "tgbot/initd-stop-no-marker"   # control: a plain stop is not a restart
expect_true "no marker after stop" [ ! -f /var/run/vpnpool.restarting ]
end

# ---- power.sh: the user's off keeps the bot, on starts / re-checks ----
reset_state; stub_initd; daemon_stop; uci set vpnpool.main.enabled=1; uci commit vpnpool
sh /usr/libexec/vpnpool/power.sh off >/dev/null 2>&1
begin "tgbot/power-off-keeps-bot"
expect_eq "enabled=0" "$(uci -q get vpnpool.main.enabled)" 0
expect_eq "init.d: boot hook kept + reload (procd stops only the daemon)" "$(tr '\n' ';' < "$TINIT")" "vpnpool enable;vpnpool reload;"
end
reset_state; stub_initd; daemon_start; : > "$PAUSE"; uci set vpnpool.main.enabled=1; uci commit vpnpool
sh /usr/libexec/vpnpool/power.sh on >/dev/null 2>&1
begin "tgbot/power-on-running-daemon-hup-only"
expect_eq "enabled=1" "$(uci -q get vpnpool.main.enabled)" 1
expect_true "daemon got HUP" [ "$(signals_seen HUP)" -ge 1 ]
expect_eq "no start of a running service" "$(gcount '^vpnpool start' "$TINIT")" 0
expect_true "pause ended" [ ! -f "$PAUSE" ]
end

# quick off -> on: the old daemon is still in its cleanup (lives 3 more s) when "on" comes
reset_state; stub_initd; daemon_start; uci set vpnpool.main.enabled=0; uci commit vpnpool
( sleep 3; for p in $(pgrep -f "$FAKED"); do kill "$p"; done ) & _killer=$!
_t0=$(date +%s); POWER_WAIT_MAX=10 sh /usr/libexec/vpnpool/power.sh on >/dev/null 2>&1; _dt=$(( $(date +%s) - _t0 ))
begin "tgbot/power-quick-off-on-waits-and-starts"
expect_eq "enabled=1" "$(uci -q get vpnpool.main.enabled)" 1
expect_eq "no HUP to the dying daemon" "$(gcount '^HUP$' "$FAKED_LOG")" 0
expect_eq "service started after the old daemon left" "$(gcount '^vpnpool start' "$TINIT")" 1
expect_true "it waited for the old daemon (${_dt}s)" [ "$_dt" -ge 2 ]
end
wait "$_killer" 2>/dev/null

# off when the daemon died before its cleanup (SIGKILL): power.sh removes the leftovers
reset_state; stub_initd; daemon_stop
ip link add br-lan type bridge 2>/dev/null; ip link set br-lan up 2>/dev/null
uci set vpnpool.main.lan_if=br-lan; uci set vpnpool.main.enabled=1; uci commit vpnpool
sh /usr/libexec/vpnpool/route.sh up >/dev/null 2>&1
begin "tgbot/power-off-removes-leftovers-of-a-killed-daemon"
expect_true "table there before (positive control)" nft list table inet vpnpool
sh /usr/libexec/vpnpool/power.sh off >/dev/null 2>&1
expect_true "table removed" sh -c '! nft list table inet vpnpool'
expect_eq "enabled=0" "$(uci -q get vpnpool.main.enabled)" 0
end

# RAM mode (16 MB): no boot hook from power.sh (install.sh's WAN hotplug hook starts us)
reset_state; stub_initd; daemon_stop
mkdir -p /etc/hotplug.d/iface; : > /etc/hotplug.d/iface/99-vpnpool-singbox-ram
sh /usr/libexec/vpnpool/power.sh on >/dev/null 2>&1
sh /usr/libexec/vpnpool/power.sh off >/dev/null 2>&1
begin "tgbot/power-ram-mode-no-enable"
expect_eq "no init.d enable in RAM mode" "$(gcount '^vpnpool enable' "$TINIT")" 0
expect_eq "on still starts" "$(gcount '^vpnpool start' "$TINIT")" 1
end
rm -f /etc/hotplug.d/iface/99-vpnpool-singbox-ram

# ---- /switch = "Connect" (ROADMAP 9.5): the soft preferred node by id + the live selector ----
reset_state
printf 'vless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.81:443?security=tls#Node1\nvless://9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce@203.0.113.82:443?security=tls#Node2\n' > "$TB/n.links"
ucode /usr/libexec/vpnpool/parser.uc --with-id "$TB/n.links" > /tmp/vpnpool/nodes.json
TID2=$(jq -r '.[1].id' /tmp/vpnpool/nodes.json)
mock_on; mock_rule 'PUT http://127.0.0.1:9091/proxies/proxy' 204
OUT=$(in_bot cmd_switch 2)
begin "tgbot/switch-stores-the-preferred-id"
expect_eq "reply" "$OUT" "switched to: Node2"
expect_eq "preferred = Node2's id" "$(uci -q get vpnpool.main.preferred_node)" "$TID2"
expect_eq "no hard pin" "$(uci -q get vpnpool.main.selected_node)" ''
expect_eq "live selector switched" "$(mock_calls 'PUT http://127.0.0.1:9091/proxies/proxy')" 1
end
OUT=$(in_bot cmd_switch auto)
begin "tgbot/switch-auto-clears-it"
expect_eq "reply" "$OUT" "automatic choice"
expect_eq "no preferred node" "$(uci -q get vpnpool.main.preferred_node)" ''
end
OUT=$(in_bot cmd_switch Nope)
begin "tgbot/switch-unknown-node-refused"
expect_eq "reply" "$OUT" "unknown node: Nope"
expect_eq "nothing stored" "$(uci -q get vpnpool.main.preferred_node)" ''
end
jq -nc --arg i "$TID2" '{($i): {tag:"Node2", link:"vless://x", active:false, auto:false}, "aaaaaaaaaaaa": {tag:"Gone", link:"vless://y", active:false, auto:true}}' > /etc/vpnpool/favorites.map.json
OUT=$(in_bot cmd_saved)
begin "tgbot/saved-lists-the-favourites"
expect_true "two favourites" sh -c 'printf "%s" "$1" | grep -q "favourite nodes (2)"' _ "$OUT"
expect_true "the one no source has is marked" sh -c 'printf "%s" "$1" | grep -q "Gone (not in a source)"' _ "$OUT"
expect_true "the one in the pool is plain" sh -c 'printf "%s" "$1" | grep -qx "⭐ Node2"' _ "$OUT"
end
