#!/bin/sh
# vpnpool two-way Telegram control bot.
#
# Long-polls getUpdates and handles a small command set so the router can be
# managed remotely without LuCI/VPN access. Telegram traffic goes through OUR
# tunnel (tg_curl -> socks5 127.0.0.1:<test_port>) because api.telegram.org is
# blocked in RU; that's why /off only tears down ROUTING and keeps sing-box (and
# thus the Telegram path) alive — otherwise /on could never arrive.
#
# Access control: only messages from the configured telegram_chat id are obeyed.
# Started/stopped by vpnpoold as a background child when telegram_control=1.
. /usr/libexec/vpnpool/lib.sh

LIBEXEC=/usr/libexec/vpnpool
OFFSET_FILE="$SB_DATA/.tg_offset"

bot_tok() { uci -q get vpnpool.main.telegram_token; }
allowed_chat() { uci -q get vpnpool.main.telegram_chat; }

# ---- single-poller invariant ----
# The ROOT fix for the "bot answers every other message" bug is supervision: tgbot runs as
# its own procd instance (see /etc/init.d/vpnpool), so procd guarantees exactly one is
# alive and kills it cleanly on stop/restart. Telegram allows only ONE getUpdates long-poll
# per bot token, and two racing pollers each get 409 Conflict on alternating calls.
#
# This startup sweep is belt-and-suspenders for the one case procd can't cover: an UPGRADE
# from the old build, where the previous bot was a background child forked by vpnpoold (not
# a procd instance) and may still be orphaned and polling after the package update. Kill any
# OTHER tgbot poller + any leftover getUpdates curl so the procd-supervised instance is the
# sole poller. busybox pkill -f is unreliable — iterate pgrep -f PIDs and kill explicitly
# (see CLAUDE.md). On a steady-state procd restart this normally finds nothing.
self="$$"
for p in $(pgrep -f "$LIBEXEC/tgbot.sh" 2>/dev/null); do
	[ "$p" = "$self" ] && continue
	kill "$p" 2>/dev/null
done
for p in $(pgrep -f "getUpdates" 2>/dev/null); do kill "$p" 2>/dev/null; done

# On TERM/INT (procd stop/restart), kill our in-flight getUpdates curl immediately so it
# doesn't linger up to 60s holding the Telegram long-poll open — otherwise the freshly
# respawned instance would 409 against our own dying connection. The poll runs in the
# background (below) so `wait` returns the moment the signal arrives and this trap fires.
POLL_PID=""
cleanup() {
	[ -n "$POLL_PID" ] && kill "$POLL_PID" 2>/dev/null
	for c in $(pgrep -f "getUpdates" 2>/dev/null); do kill "$c" 2>/dev/null; done
	exit 0
}
trap cleanup TERM INT

human_bytes() {   # $1 = bytes -> e.g. "12.3 GB"
	awk -v b="${1:-0}" 'BEGIN{
		split("B KB MB GB TB PB", u, " "); i=1;
		while (b>=1024 && i<6){ b/=1024; i++ }
		printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
	}'
}

# Build the /status reply from the live status snapshot.
cmd_status() {
	local j
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	[ -n "$j" ] || { echo "status unavailable"; return; }
	echo "$j" | jq -r '
		def gb(x): (x/1073741824);
		"vpnpool " + (if .running then "🟢 running" else "🔴 stopped" end)
		+ "\nrouting: " + (if .routing then "on" else "off" end)
		+ "\nmode: " + (.mode // "-")
		+ "\nactive: " + (if (.active|length)>0 then .active else (.auto_now // "-") end)
		+ "\nnodes: " + ((.nodes|length)|tostring)
		+ (if (.subscription.total // 0) > 0 then
			"\nquota: " + (gb(.subscription.used)|.*10|round/10|tostring) + " / "
			+ (gb(.subscription.total)|.*10|round/10|tostring) + " GB" else "" end)
		+ (if (.subscription.expire // null) != null then
			"\nexpires: " + (((.subscription.expire - now)/86400)|floor|tostring) + "d" else "" end)
		+ "\ntraffic: ↑" + ((.traffic.up_total//0)|tostring) + " ↓" + ((.traffic.down_total//0)|tostring) + " B"
	' 2>/dev/null
}

# Numbered node list (tag + last delay).
cmd_nodes() {
	local j
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	[ -n "$j" ] || { echo "no nodes"; return; }
	echo "$j" | jq -r '
		.active as $a |
		(.nodes // []) | to_entries | .[:30] | map(
			((.key+1)|tostring) + ". "
			+ (if .value.tag==$a then "✅ " else "" end)
			+ .value.tag
			+ (if (.value.delay//null)!=null then " ("+(.value.delay|tostring)+"ms)" else "" end)
		) | join("\n")
	' 2>/dev/null
}

# /switch <n|tag>: point the "proxy" selector at a node (live + persisted).
cmd_switch() {
	local arg tag j
	arg="$1"
	[ -n "$arg" ] || { echo "usage: /switch <number|tag>"; return; }
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	case "$arg" in
		''|*[!0-9]*) tag="$arg" ;;                              # treat as a tag
		*) tag=$(echo "$j" | jq -r --argjson i "$arg" '(.nodes // [])[$i-1].tag // ""' 2>/dev/null) ;;
	esac
	[ -n "$tag" ] || { echo "node not found"; return; }
	# verify the tag exists
	echo "$j" | jq -e --arg t "$tag" '(.nodes // []) | map(.tag) | index($t)' >/dev/null 2>&1 || {
		echo "unknown node: $tag"; return; }
	curl -s -m 5 -X PUT "http://$CLASH_API/proxies/proxy" \
		--data "{\"name\":\"$tag\"}" >/dev/null 2>&1
	uci set vpnpool.main.selected_node="$tag" 2>/dev/null
	uci commit vpnpool 2>/dev/null
	echo "switched to: $tag"
}

# /quota: subscription data usage + expiry.
cmd_quota() {
	local j
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	[ -n "$j" ] || { echo "status unavailable"; return; }
	echo "$j" | jq -r '
		def gb(x): ((x/1073741824)*10|round/10);
		(.subscription // {}) as $s |
		if ($s.total // 0) > 0 then
			"quota: " + (gb($s.used)|tostring) + " / " + (gb($s.total)|tostring) + " GB"
			+ " (left " + (gb(($s.total - ($s.used//0)))|tostring) + " GB)"
		else "quota: n/a" end
		+ (if ($s.expire // null) != null then
			"\nexpires in " + (((($s.expire) - now)/86400)|floor|tostring) + "d" else "" end)
	' 2>/dev/null
}

# /saved: list saved (persistent) nodes.
cmd_saved() {
	local j
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	[ -n "$j" ] || { echo "no data"; return; }
	echo "$j" | jq -r '
		[ (.nodes // [])[] | select(.saved==true) ] as $sv |
		if ($sv|length)==0 then "no saved nodes"
		else "saved nodes (" + ($sv|length|tostring) + "):\n"
			+ ($sv | .[:40] | map("⭐ " + .tag) | join("\n")) end
	' 2>/dev/null
}

# /clients: top LAN devices by live traffic.
cmd_clients() {
	local j
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	[ -n "$j" ] || { echo "no data"; return; }
	echo "$j" | jq -r '
		def hb(x): (if x>=1073741824 then ((x/1073741824)*10|round/10|tostring)+"G"
			elif x>=1048576 then ((x/1048576)*10|round/10|tostring)+"M"
			elif x>=1024 then ((x/1024)|floor|tostring)+"K" else (x|tostring)+"B" end);
		(.client_traffic // []) as $c |
		if ($c|length)==0 then "no active client connections"
		else "top clients:\n" + ($c | .[:15] | map(
			((.host // "") | if .=="" then .ip else . end)
			+ " ↓" + hb(.down) + " ↑" + hb(.up)) | join("\n")) end
	' 2>/dev/null
}

# /speedtest <n|tag>: real throughput test (blocks ~seconds; respects the low-mem guard).
cmd_speedtest() {
	local arg tag j
	arg="$1"
	[ -n "$arg" ] || { echo "usage: /speedtest <number|tag>"; return; }
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	case "$arg" in
		''|*[!0-9]*) tag="$arg" ;;
		*) tag=$(echo "$j" | jq -r --argjson i "$arg" '(.nodes // [])[$i-1].tag // ""' 2>/dev/null) ;;
	esac
	[ -n "$tag" ] || { echo "node not found"; return; }
	echo "$j" | jq -e --arg t "$tag" '(.nodes // []) | map(.tag) | index($t)' >/dev/null 2>&1 || { echo "unknown node: $tag"; return; }
	"$LIBEXEC/speedtest.sh" "$tag" >/dev/null 2>&1
	jq -r --arg t "$tag" '
		if (.lowmem==true) then "speed test skipped: low memory"
		elif (.ok==true) then $t + ": " + (.mbps|tostring) + " Mbit/s"
		else "speed test failed for " + $t end
	' /tmp/vpnpool/.speedtest-result.json 2>/dev/null || echo "speed test failed"
}

# /on /off toggle ROUTING only (keep sing-box + Telegram path alive).
cmd_on() {
	uci set vpnpool.main.enabled=1 2>/dev/null; uci commit vpnpool 2>/dev/null
	"$LIBEXEC/route.sh" up >/dev/null 2>&1
	echo "routing ON"
}
cmd_off() {
	uci set vpnpool.main.enabled=0 2>/dev/null; uci commit vpnpool 2>/dev/null
	"$LIBEXEC/route.sh" down >/dev/null 2>&1
	echo "routing OFF (tunnel kept alive for control)"
}

# /refresh: re-fetch subscription + rebuild (USR2 to the daemon).
cmd_refresh() {
	local pid
	pid=$(pgrep -f "$LIBEXEC/vpnpoold" 2>/dev/null | head -1)
	[ -n "$pid" ] && kill -USR2 "$pid" 2>/dev/null
	echo "refreshing subscription…"
}

cmd_help() {
	printf '%s\n' "vpnpool bot commands:" \
		"/menu — кнопочное меню (рекомендуется)" \
		"/status — service + node + quota" \
		"/nodes — list nodes with ping" \
		"/switch <n|tag> — select a node" \
		"/speedtest <n|tag> — real speed test" \
		"/quota — subscription usage + expiry" \
		"/saved — list saved nodes" \
		"/clients — top LAN devices by traffic" \
		"/on — enable routing" \
		"/off — disable routing (tunnel stays up)" \
		"/refresh — re-fetch subscription" \
		"/help — this message"
}

# ---- inline-keyboard (button) interface ----

# Main menu header: live running state + active node, so the menu doubles as a glance.
menu_text() {
	local j run act
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	run=$(echo "$j" | jq -r 'if .running then "🟢 вкл" else "🔴 выкл" end' 2>/dev/null)
	act=$(echo "$j" | jq -r 'if (.active|length)>0 then .active else (.auto_now // "-") end' 2>/dev/null)
	printf '🛰 vpnpool — управление\nСлужба: %s\nУзел: %s\n\nВыберите действие:' "${run:-?}" "${act:-?}"
}

# Static main menu keyboard (compact JSON, one line — valid for reply_markup).
main_menu_kb() {
	printf '%s' '{"inline_keyboard":[[{"text":"📊 Статус","callback_data":"status"},{"text":"📋 Узлы","callback_data":"nodes:0"}],[{"text":"🔄 Обновить","callback_data":"refresh"},{"text":"⚡ Спидтест","callback_data":"spd:0"}],[{"text":"🟢 Вкл","callback_data":"on"},{"text":"🔴 Выкл","callback_data":"off"}],[{"text":"📈 Квота","callback_data":"quota"},{"text":"⭐ Сохранённые","callback_data":"saved"}],[{"text":"👥 Клиенты","callback_data":"clients"},{"text":"❓ Помощь","callback_data":"help"}]]}'
}

# A lone "back to menu" keyboard for leaf screens.
back_kb() { printf '%s' '{"inline_keyboard":[[{"text":"🔙 Меню","callback_data":"menu"}]]}'; }

# Paged node keyboard. $1=page (0-based), $2=callback prefix (sw = switch, st = speedtest).
# Each node is its own row (tags are long); a nav row adds ⬅️/➡️ + 🔙 Меню. Built with jq
# so long/unicode tags are always valid JSON.
nodes_kb() {   # $1=page  $2=prefix
	local page="${1:-0}" pref="${2:-sw}" j
	j="$($LIBEXEC/status.sh 2>/dev/null)"
	echo "$j" | jq -c --argjson p "$page" --argjson per 8 --arg pref "$pref" '
		.active as $a |
		(.nodes // []) as $all |
		($all|length) as $n |
		[ $all | to_entries | .[($p*$per):($p*$per+$per)][] |
			[ { text: (((.key+1)|tostring) + ". "
				+ (if .value.tag==$a then "✅ " else "" end) + .value.tag
				+ (if (.value.delay//null)!=null then " ("+(.value.delay|tostring)+"ms)" else "" end)),
			    callback_data: ($pref + ":sel:" + (.key|tostring)) } ] ]
		+ [ ( [ (if $p>0 then {text:"⬅️",callback_data:($pref+":"+(($p-1)|tostring))} else empty end),
			(if ($p*$per+$per) < $n then {text:"➡️",callback_data:($pref+":"+(($p+1)|tostring))} else empty end),
			{text:"🔙 Меню",callback_data:"menu"} ] ) ]
		| {inline_keyboard: .}
	' 2>/dev/null
}

# Route a button press. $1=callback_data $2=callback_query_id $3=message_id
handle_cb() {
	local data="$1" cbq="$2" mid="$3" txt
	case "$data" in
		menu)     tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "$(menu_text)" "$(main_menu_kb)" ;;
		status)   tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "$(cmd_status)" "$(back_kb)" ;;
		quota)    tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "$(cmd_quota)" "$(back_kb)" ;;
		saved)    tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "$(cmd_saved)" "$(back_kb)" ;;
		clients)  tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "$(cmd_clients)" "$(back_kb)" ;;
		help)     tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "$(cmd_help)" "$(back_kb)" ;;
		on)       txt=$(cmd_on);  tg_answer_cbq "$cbq" "$txt"; tg_edit_kb "$mid" "$(menu_text)" "$(main_menu_kb)" ;;
		off)      txt=$(cmd_off); tg_answer_cbq "$cbq" "$txt"; tg_edit_kb "$mid" "$(menu_text)" "$(main_menu_kb)" ;;
		refresh)  cmd_refresh >/dev/null; tg_answer_cbq "$cbq" "Обновляю подписку…" ;;
		nodes:*)  tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "Выберите узел для переключения:" "$(nodes_kb "${data#nodes:}" sw)" ;;
		spd:sel:*) tg_answer_cbq "$cbq" "Тестирую…"
			tg_edit_kb "$mid" "⏳ Замеряю скорость…" "$(back_kb)"
			txt=$(cmd_speedtest "$(( ${data##*:} + 1 ))")
			tg_edit_kb "$mid" "$txt" "$(back_kb)" ;;
		spd:*)    tg_answer_cbq "$cbq"; tg_edit_kb "$mid" "Выберите узел для спидтеста:" "$(nodes_kb "${data#spd:}" spd)" ;;
		sw:sel:*) txt=$(cmd_switch "$(( ${data##*:} + 1 ))"); tg_answer_cbq "$cbq" "$txt"
			tg_edit_kb "$mid" "Выберите узел для переключения:" "$(nodes_kb 0 sw)" ;;
		*)        tg_answer_cbq "$cbq" ;;   # always ack so the spinner stops
	esac
}

handle() {   # $1 = raw text
	local cmd arg
	cmd=$(echo "$1" | awk '{print $1}' | sed 's/@.*//')   # strip /cmd@botname
	arg=$(echo "$1" | sed 's/^[^ ]* *//')
	case "$cmd" in
		/status)  cmd_status ;;
		/nodes)   cmd_nodes ;;
		/switch)  cmd_switch "$arg" ;;
		/speedtest) cmd_speedtest "$arg" ;;
		/quota)   cmd_quota ;;
		/saved)   cmd_saved ;;
		/clients) cmd_clients ;;
		/on)      cmd_on ;;
		/off)     cmd_off ;;
		/refresh) cmd_refresh ;;
		/help)    cmd_help ;;
		/start|/menu) return 0 ;;   # handled by the caller (sends the button menu)
		*) return 0 ;;   # ignore non-commands silently
	esac
}

log "tgbot starting (control via Telegram)"
OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null); [ -n "$OFFSET" ] || OFFSET=0

UPD_FILE="$SB_DATA/.tg_upd"
while : ; do
	tok=$(bot_tok); chat=$(allowed_chat)
	if [ -z "$tok" ] || [ -z "$chat" ]; then sleep 10 & wait $!; continue; fi

	# long poll (timeout 50s) via tg_poll = PROXY-ONLY (no slow direct fallback — see
	# lib.sh). We want both plain messages (slash commands) and callback_query (button
	# presses). Run it in the BACKGROUND and `wait`, so a procd TERM during the 50s poll
	# returns immediately and the cleanup trap kills the curl (no lingering long-poll).
	: > "$UPD_FILE"
	tg_poll -m 60 "$TG_API/bot$tok/getUpdates?timeout=50&offset=$OFFSET&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D" > "$UPD_FILE" 2>/dev/null &
	POLL_PID=$!
	wait "$POLL_PID"
	POLL_PID=""
	UPD=$(cat "$UPD_FILE" 2>/dev/null)
	if [ -z "$UPD" ]; then sleep 3 & wait $!; continue; fi
	echo "$UPD" | jq -e '.ok==true' >/dev/null 2>&1 || { sleep 3 & wait $!; continue; }

	N=$(echo "$UPD" | jq '(.result // []) | length' 2>/dev/null); [ -n "$N" ] || N=0
	i=0
	while [ "$i" -lt "$N" ]; do
		UID=$(echo "$UPD" | jq -r ".result[$i].update_id" 2>/dev/null)
		CBID=$(echo "$UPD" | jq -r ".result[$i].callback_query.id // empty" 2>/dev/null)
		idx=$i
		i=$((i + 1))
		[ -n "$UID" ] && OFFSET=$((UID + 1))

		if [ -n "$CBID" ]; then
			# ---- button press (callback_query) ----
			FROM=$(echo "$UPD" | jq -r ".result[$idx].callback_query.message.chat.id // empty" 2>/dev/null)
			DATA=$(echo "$UPD" | jq -r ".result[$idx].callback_query.data // empty" 2>/dev/null)
			MID=$(echo "$UPD"  | jq -r ".result[$idx].callback_query.message.message_id // empty" 2>/dev/null)
			[ "$FROM" = "$chat" ] || { [ -n "$FROM" ] && log "tgbot: ignored cbq from $FROM"; continue; }
			[ -n "$DATA" ] && [ -n "$MID" ] && handle_cb "$DATA" "$CBID" "$MID"
			continue
		fi

		# ---- plain message ----
		FROM=$(echo "$UPD" | jq -r ".result[$idx].message.chat.id // empty" 2>/dev/null)
		TEXT=$(echo "$UPD" | jq -r ".result[$idx].message.text // empty" 2>/dev/null)
		# access control: only the configured chat id may command the bot
		[ "$FROM" = "$chat" ] || { [ -n "$FROM" ] && log "tgbot: ignored msg from $FROM"; continue; }
		[ -n "$TEXT" ] || continue
		# /start and /menu open the button interface; everything else replies as text.
		case "$(echo "$TEXT" | awk '{print $1}' | sed 's/@.*//')" in
			/start|/menu) tg_send_kb "$(menu_text)" "$(main_menu_kb)" >/dev/null 2>&1 ;;
			*) REPLY=$(handle "$TEXT"); [ -n "$REPLY" ] && tg_send "$REPLY" >/dev/null 2>&1 ;;
		esac
	done
	echo "$OFFSET" > "$OFFSET_FILE" 2>/dev/null
done
