# suite: tgbot — Telegram bot: /on /off via the pause flag + SIGHUP, direct poll when the
# proxy port is down, sweep kills only OUR pollers, init.d bot instance (sourced by run.sh).
# ROADMAP 2.9. tgbot.sh is sourced with TGBOT_NO_MAIN=1 (functions only) in a subshell.

TB="$T_STATE/tgbot"; mkdir -p "$TB"
TINIT="$TB/initd.calls"
in_bot() {   # <fn...> — run inside a subshell with the real tgbot.sh functions loaded
	( TGBOT_NO_MAIN=1; export TGBOT_NO_MAIN; . /usr/libexec/vpnpool/tgbot.sh; "$@" )
}
stub_initd() {
	printf '#!/bin/sh\necho "vpnpool $*" >> %s\nexit 0\n' "$TINIT" > /etc/init.d/vpnpool
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

# ---- power.sh: the user's off keeps the bot, on starts / re-checks ----
reset_state; stub_initd; daemon_stop; uci set vpnpool.main.enabled=1; uci commit vpnpool
sh /usr/libexec/vpnpool/power.sh off >/dev/null 2>&1
begin "tgbot/power-off-keeps-bot"
expect_eq "enabled=0" "$(uci -q get vpnpool.main.enabled)" 0
expect_eq "init.d: boot hook kept + reload (procd stops only the daemon)" "$(tr '\n' ';' < "$TINIT")" "vpnpool enable;vpnpool reload;"
end
reset_state; stub_initd; daemon_start; : > "$PAUSE"
sh /usr/libexec/vpnpool/power.sh on >/dev/null 2>&1
begin "tgbot/power-on-running-daemon-hup-only"
expect_eq "enabled=1" "$(uci -q get vpnpool.main.enabled)" 1
expect_true "daemon got HUP" [ "$(signals_seen HUP)" -ge 1 ]
expect_eq "no start of a running service" "$(gcount '^vpnpool start' "$TINIT")" 0
expect_true "pause ended" [ ! -f "$PAUSE" ]
end
