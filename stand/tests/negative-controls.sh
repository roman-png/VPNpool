#!/bin/sh
# Negative (and "fix") controls for the stand test suites — proves each suite can say "no".
# For every control: copy package/ + stand/ + scripts/ to a temp dir, apply deliberate change(s)
# to the copy (the working tree is never touched), run the affected suite against the copy and
# check the verdict from the runner's summary line AND which cases flipped:
#   expect=fail  -> the break must turn exactly the expected passing case(s) red
#   expect=xpass -> a minimal FIX of a known defect must flip exactly its xfail case(s) to XPASS
#                   (failed=0): shows the xfail case is not failing for an unrelated reason.
#   stand/tests/negative-controls.sh            # all controls
#   stand/tests/negative-controls.sh sched-fix  # selected
# Output: one line per control + "CONTROLS: ok=N bad=M".
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TMPBASE=${TMPDIR:-/tmp}/vpnpool-nc.$$
mkdir -p "$TMPBASE"
LIBX=package/vpnpool/files/usr/libexec/vpnpool
RPCD=package/luci-app-vpnpool/files/usr/libexec/rpcd/vpnpool
VIEW=package/luci-app-vpnpool/files/www/luci-static/resources/view/vpnpool
OK=0; BAD=0
# NC_JOBS: controls run in parallel (each in its own container); output stays in list order.
NC_JOBS=${NC_JOBS:-3}
NC_ORDER=""
NC_PIDS=""
_nc_throttle() {   # wait for a free slot (`jobs` inside $( ) sees no jobs in ash: track PIDs)
	while :; do
		_live=""; _nl=0
		for _p in $NC_PIDS; do kill -0 "$_p" 2>/dev/null && { _live="$_live $_p"; _nl=$((_nl+1)); }; done
		NC_PIDS=$_live
		[ "$_nl" -lt "$NC_JOBS" ] && return 0
		sleep 1
	done
}

replace_once() {   # file needle replacement — fixed strings, first occurrence; 1 if absent
	N="$2" R="$3" awk 'BEGIN{n=ENVIRON["N"]; r=ENVIRON["R"]; done=0}
		{ if (!done) { i=index($0, n); if (i>0) { $0=substr($0,1,i-1) r substr($0,i+length(n)); done=1 } } print }
		END{ exit(done?0:1) }' "$1" > "$1.nc" && mv "$1.nc" "$1"
}

# ctl <name> <suite> <fail|xpass> <expected cases> <file> <needle> <repl> [<file> <needle> <repl>]...
#   expected cases: ';'-separated substrings of the FAIL/XPASS lines that MUST appear — and
#   nothing else may go red: the control is OK only if exactly those cases flipped.
ctl() {
	name=$1 suite=$2 expect=$3 want=$4; shift 4
	if [ -n "$SELECT" ]; then case " $SELECT " in *" $name "*) ;; *) return 0 ;; esac; fi
	d="$TMPBASE/$name"; mkdir -p "$d"
	cp -r "$REPO/package" "$REPO/stand" "$REPO/scripts" "$REPO/install.sh" "$d/"
	while [ $# -ge 3 ]; do
		if ! replace_once "$d/$1" "$2" "$3" || cmp -s "$REPO/$1" "$d/$1"; then
			echo "BAD   $name: needle not found / copy unchanged in $1 (control is void)"; BAD=$((BAD+1)); rm -rf "$d"; return 0
		fi
		shift 3
	done
	NC_ORDER="$NC_ORDER $name"
	_nc_throttle
	(
	case "$suite" in
		ui-smoke)   REPO_DIR="$d" sh "$HERE/ui-smoke.sh" > "$d.log" 2>&1
		            line=$(grep '^UI-SMOKE: ' "$d.log" | tail -1) ;;
		deploy-tar) REPO_DIR="$d" sh "$HERE/deploy-tar-test.sh" > "$d.log" 2>&1
		            line=$(grep '^DEPLOY-TAR: ' "$d.log" | tail -1) ;;
		ui-i18n)    REPO_DIR="$d" sh "$HERE/ui-i18n.sh" check > "$d.log" 2>&1
		            line=$(grep '^I18N: ' "$d.log" | tail -1) ;;
		*)          REPO_DIR="$d" sh "$HERE/run-in-docker.sh" "$suite" > "$d.log" 2>&1
		            line=$(grep '^TESTS: ' "$d.log" | tail -1) ;;
	esac
	f=$(echo "$line" | sed -n 's/.* failed=\([0-9]*\).*/\1/p'); xp=$(echo "$line" | sed -n 's/.* xpass=\([0-9]*\).*/\1/p')
	xp=${xp:-0}
	grep -E '^(FAIL|XPASS) ' "$d.log" > "$d.red"
	verdict=OK; why=""
	case "$expect" in
		fail)  [ "${f:-0}" -gt 0 ] || { verdict=BAD; why="nothing failed"; } ;;
		xpass) { [ "$xp" -gt 0 ] && [ "${f:-1}" -eq 0 ]; } || { verdict=BAD; why="no clean XPASS"; } ;;
	esac
	nwant=0
	OLDIFS=$IFS; IFS=';'
	for w in $want; do
		nwant=$((nwant+1))
		grep -qF -- "$w" "$d.red" || { verdict=BAD; why="$why; expected case not red: $w"; }
	done
	IFS=$OLDIFS
	nred=$(wc -l < "$d.red" | tr -d ' ')
	[ "$nred" -eq "$nwant" ] || { verdict=BAD; why="$why; $nred red cases, expected exactly $nwant"; }
	printf '%-5s %-30s suite=%-10s expect=%-5s | %s | %s%s\n' "$verdict" "$name" "$suite" "$expect" "${line:-no summary line}" \
		"$(cut -c1-90 "$d.red" | tr '\n' ';')" "${why:+ | WHY:$why}"
	rm -rf "$d" "$d.log" "$d.red"
	) > "$TMPBASE/$name.out" 2>&1 &
	NC_PIDS="$NC_PIDS $!"
}

SELECT="$*"
ctl parser-flow-broken parser fail 'parser/vless-reality-vision ;parser/vless-flow-variant-normalised ' \
	"$LIBX/parser.uc" "ob.flow = 'xtls-rprx-vision';" "ob.flow = 'broken-flow';"
# 2.1a: json() without try -> text that only looks like JSON aborts the parser again
ctl parser-json-no-try parser fail 'parser/json-looking-junk-no-crash ;parser/json-looking-then-links ;parser/report-multi-file-and-json ' \
	"$LIBX/parser.uc" 'try { data = json(raw); } catch (e) { data = null; }' 'data = json(raw);'
# 2.1: one suffix attempt instead of a loop -> "A", "A #2", "A" collide
ctl parser-tag-one-attempt parser fail 'parser/tag-suffix-unique-loop ' \
	"$LIBX/parser.uc" 'while (used_tags[cand] || RESERVED_TAGS[cand]) {' 'if (used_tags[cand] || RESERVED_TAGS[cand]) {'
# 2.1: reserved tags not reserved
ctl parser-reserved-off parser fail 'parser/reserved-tags-renamed ;parser/json-outbound-reserved-tag ;parser/report-reasons ' \
	"$LIBX/parser.uc" "let RESERVED_TAGS = { auto: 1, proxy: 1, direct: 1, block: 1, 'dns-out': 1, 'vpnpool-test': 1 };" 'let RESERVED_TAGS = {};'
# id: TLS left out of the canonical config -> fp chrome/firefox share an id
ctl parser-id-skips-tls parser fail 'parser/id-covers-every-config-field ' \
	"$LIBX/parser.uc" "k != '_link') c[k] = ob[k];" "k != '_link' && k != 'tls') c[k] = ob[k];"
# id depends on the display name -> renaming changes it
ctl parser-id-uses-name parser fail 'parser/id-stable-across-order-and-name ;parser/id-changes-with-port-and-credential ;parser/id-json-key-order-and-link-agree ;XPASS parser/id-unique-in-output ' \
	"$LIBX/parser.uc" "if (k != 'tag' && k != 'id' && k != '_link')" "if (k != 'id' && k != '_link')"
# id leaks into the default output -> sing-box check rejects the config
ctl parser-id-always parser fail 'parser/id-not-in-default-output ;parser/corpus-accepted-by-sing-box-check ;parser/json-source-guards ' \
	"$LIBX/parser.uc" 'let id = (is_awg || !(WITH_ID || REPORT)) ? null : node_id(ob);' 'let id = is_awg ? null : node_id(ob);' \
	"$LIBX/parser.uc" 'if (WITH_ID && id) ob.id = id;' 'if (id) ob.id = id;'
# dedup without the name -> a user's copy of a subscription node vanishes
ctl parser-dedup-without-name parser fail 'parser/dedup-keeps-differently-named-node ;parser/dedup-subscription-vs-imported-file ;XPASS parser/id-unique-in-output ' \
	"$LIBX/parser.uc" "return base + '\x1f' + canon(bare(ob));" 'return canon(bare(ob));'
# canonical form keeps the JSON key order -> permuted JSON = another node / id
ctl parser-canon-unsorted parser fail 'parser/json-key-order-dedup ;parser/id-json-key-order-and-link-agree ' \
	"$LIBX/parser.uc" 'let ks = sort(keys(v), (a, b) => (a < b) ? -1 : ((a > b) ? 1 : 0));' 'let ks = keys(v);'
# JSON-source outbounds taken unchecked
ctl parser-json-unguarded parser fail 'parser/json-source-guards ' \
	"$LIBX/parser.uc" 'let bad = check_json_node(o);' 'let bad = null;'
ctl build-json-unguarded build fail 'build/json-source-long-short-id-no-panic ' \
	"$LIBX/parser.uc" 'let bad = check_json_node(o);' 'let bad = null;'
# fp=none treated as an unknown fingerprint -> chrome uTLS where the link asked for none
ctl parser-fp-none-ignored parser fail 'parser/vless-fp-none-no-utls ' \
	"$LIBX/parser.uc" "if (fp == 'none') fp = '';" "if (fp == 'none-x') fp = '';"
# hysteria2: the single port is not part of the hop set
ctl parser-hy2-port-not-hopped parser fail 'parser/hy2-port-hopping ' \
	"$LIBX/parser.uc" "if (port != null) unshift(ranges, port + ':' + port);" 'if (port != null) ;'
# stage 5: unknown transports accepted -> dead/poison nodes
ctl parser-unknown-transport-kept parser fail 'parser/vless-xhttp-refused ;parser/vless-splithttp-refused ;parser/vless-kcp-refused ;parser/trojan-xhttp-refused ;parser/vmess-xhttp-refused ;parser/report-reasons ' \
	"$LIBX/parser.uc" "	return 'unsupported_transport';" "	return { type: t };"
# every case that inspects the installed config goes red
ctl build-config-not-installed build fail 'build/clean-subscription ;build/poison-port-70000 ;build/poison-reserved-tag-direct ;build/poison-reserved-tag-auto ;build/poison-reserved-tag-proxy ;build/poison-duplicate-tags ;build/not-frozen-new-node-arrives-despite-poison ;build/xhttp-builds ;build/xhttp-not-in-config ;build/junk-json-source-does-not-empty-pool ;build/json-source-long-short-id-no-panic ;build/awg-node-on-stock-engine-deferred ;build/unchanged-pool-no-flash-write ;build/changed-pool-flash-updated ;build/after-reboot-failed-build-keeps-flash-config ;build/node-test-selector-separate-from-proxy ;build/poison-json-source-unknown-field ;build/generator-tags-reserved-in-parser ' \
	"$LIBX/build.sh" 'mv "$SB_CONF.new" "$SB_CONF"' 'rm -f "$SB_CONF.new"'
ctl rpcd-add_node-no-signal rpcd fail 'rpcd/add_node/ok ' \
	"$RPCD" 'uci add_list vpnpool.main.manual_node="$l"; uci commit vpnpool; signal_reload' \
	'uci add_list vpnpool.main.manual_node="$l"; uci commit vpnpool'
ctl sched-old-block-kept sched fail 'sched/disabled-removes-block-keeps-user-jobs ' \
	"$LIBX/sched.sh" 'inblk && $0 == e { inblk = 0; n = 0; next }' 'inblk && $0 == e { inblk = 0; for (i = 1; i <= n; i++) print buf[i]; print; n = 0; next }'
# stage 2 (2.6): the old busybox-invalid 10# arithmetic back -> no job is ever written
ctl sched-octal-regression sched fail 'sched/enabled-writes-jobs ;sched/lone-begin-keeps-following-user-jobs ;sched/leading-zeros ' \
	"$LIBX/sched.sh" 'echo "$m $h"' 'echo "$((10#$m)) $((10#$h))"'
ctl adaptive-ignores-toggle adaptive fail 'adaptive/disabled-does-nothing ' \
	"$LIBX/adaptive.sh" '= "1" ] || exit 0' '= "1" ] || :'
# stage 2 (2.7): jq regex back -> the host filter dies on OpenWrt's jq, nothing is tested
ctl adaptive-regex-regression adaptive fail 'adaptive/blocked-direct-routed-via-proxy ;adaptive/public-suffix-base-domain ;adaptive/verdict-cache-ttl ' \
	"$LIBX/adaptive.sh" '((explode | map(select((. < 48 or . > 57) and . != 46)) | length) > 0)' '(test("^[0-9.]+$") | not)'
ctl adaptive-ttl-ignored adaptive fail 'adaptive/verdict-cache-ttl ' \
	"$LIBX/adaptive.sh" 'if type=="object" and ((.t // 0) + $ttl) > $now then "y"' 'if type=="object" then "y"'
ctl fetch-userinfo-lost fetch fail 'fetch/all-sources-ok ' \
	"$LIBX/fetch.sh" "grep -o 'expire=[0-9]*'" "grep -o 'expireX=[0-9]*'"
# stage 2 (2.5 / 2.11): fetch
ctl fetch-no-per-source-cache fetch fail 'fetch/primary-fails-extra-ok-keeps-primary-nodes ;fetch/all-fail-serves-cache ;fetch/removed-source-dropped-from-cache ;fetch/fetch-due-throttle ' \
	"$LIBX/fetch.sh" 'if [ -s "$cached" ]; then' 'if false; then'
ctl fetch-url-in-clear fetch fail 'fetch/token-masked-in-log ' \
	"$LIBX/fetch.sh" 'log "fetch: $(mask_url "$url") -> $best nodes' 'log "fetch: $url -> $best nodes'
ctl fetch-cache-always-rewritten fetch fail 'fetch/unchanged-source-cache-not-rewritten ;fetch/changed-source-cache-rewritten ' \
	"$LIBX/fetch.sh" 'mkdir -p "$CACHEDIR"; persist_if_changed "$out" "$cached"' 'mkdir -p "$CACHEDIR"; cp "$out" "$cached"'
ctl fetch-no-throttle fetch fail 'fetch/fetch-due-throttle ' \
	"$LIBX/lib.sh" '[ $(( now - t )) -ge "$INTERVAL_MIN" ]' 'true'
# stage 2 (2.1 / 2.11): build
ctl build-singular-regex-only build fail 'build/poison-json-source-unknown-field ;build/awg-node-on-stock-engine-deferred ' \
	"$LIBX/build.sh" "grep -oE '(outbound|endpoint)s?\[[0-9]+\]'" "grep -oE '(outbound|endpoint)\[[0-9]+\]'"
# one owner of the reserved names: a generator tag missing from parser.uc's list is caught
ctl parser-reserved-misses-generator-tag build fail 'build/generator-tags-reserved-in-parser ' \
	"$LIBX/parser.uc" "'dns-out': 1, 'vpnpool-test': 1 };" "'dns-out': 1 };"
ctl build-flash-always-written build fail 'build/unchanged-pool-no-flash-write ' \
	"$LIBX/build.sh" 'persist_if_changed "$SB_CONF" "$SB_CONF_FLASH"' 'cp "$SB_CONF" "$SB_CONF_FLASH"'
# stage 2 (2.3 / 2.4 / 2.8 / 2.10): daemon
ctl daemon-killswitch-ignored daemon fail 'daemon/route-policy-table ;daemon/reload-killswitch-dead-tunnel-keeps-routes ;daemon/startup-killswitch-routes-at-once ;daemon/startup-guard-killswitch-blocks-before-first-build ;daemon/pause-flag-down-then-up ' \
	"$LIBX/lib.sh" '[ "$1" = 1 ] && { echo up; return 0; }' '[ "$1" = 1 ] && { echo down; return 0; }'
ctl daemon-reload-drops-routes-first daemon fail 'daemon/reload-killswitch-dead-tunnel-keeps-routes ;daemon/reload-healthy-keeps-routes ;daemon/reload-dead-tunnel-failsafe-down ;daemon/periodic-refresh-through-failsafe ;daemon/signal-during-route-up-no-desync ' \
	"$LIBX/vpnpoold" '		start_singbox   # routes stay as they are while it restarts' '		"$LIBEXEC/route.sh" down; start_singbox'
ctl daemon-startup-keeps-stale-table daemon fail 'daemon/startup-dead-tunnel-clears-stale-routes ;daemon/startup-guard-clears-stale-table-before-first-build ' \
	"$LIBX/vpnpoold" 'if [ "$ROUTED" != 0 ] || [ -n "${2:-}" ]; then' 'if [ "$ROUTED" != 0 ] || [ "${2:-}" = reapply ]; then'
ctl daemon-watchdog-no-failsafe daemon fail 'daemon/watchdog-dead-tunnel-takes-routes-down ' \
	"$LIBX/vpnpoold" '			apply_routing 0' '			:'
# review E: work done INSIDE the trap again -> ROUTED out of step with the table
ctl daemon-work-in-trap daemon fail 'daemon/signal-during-route-up-no-desync ;daemon/reload-queued-not-nested ' \
	"$LIBX/vpnpoold" 'on_usr1() { [ "$PENDING" = refetch ] || PENDING=reload; }' 'on_usr1() { PENDING=reload; serve_pending; }'
ctl daemon-no-startup-guard daemon fail 'daemon/startup-guard-clears-stale-table-before-first-build ;daemon/startup-guard-killswitch-blocks-before-first-build ' \
	"$LIBX/vpnpoold" '	apply_routing 0 guard' '	:'
ctl daemon-stop-waits-for-telegram daemon fail 'daemon/stop-routes-down-first-notify-in-background ' \
	"$LIBX/vpnpoold" '	( tg_notify "🔴 vpnpool: stopped" ) </dev/null >/dev/null 2>&1 &' '	tg_notify "🔴 vpnpool: stopped"'
ctl daemon-dead-set-erases-pin daemon fail 'daemon/preferred-in-dead-set-hands-to-auto-keeps-pin ;daemon/preferred-recovered-switches-back ' \
	"$LIBX/vpnpoold" 'PREF_DEAD_LOGGED=$pref' 'PREF_DEAD_LOGGED=$pref; uci -q delete vpnpool.main.preferred_node; uci commit vpnpool'
ctl nodecheck-judges-without-wan daemon fail 'daemon/nodecheck-wan-down-judges-nothing ' \
	"$LIBX/nodecheck.sh" 'if ! wan_alive; then' 'if false; then'
ctl route-delete-then-add daemon fail 'daemon/route-up-atomic-idempotent ;daemon/route-refused-reapply-keeps-old-table ' \
	"$LIBX/route.sh" '		nft -f - <<NFT' '		nft delete table inet vpnpool 2>/dev/null; nft -f - <<NFT'
# review A: a refused re-apply "rolls back" by deleting the working table
ctl route-failure-deletes-table daemon fail 'daemon/route-refused-reapply-keeps-old-table ' \
	"$LIBX/route.sh" '	if nft list table inet vpnpool >/dev/null 2>&1; then' '	nft delete table inet vpnpool 2>/dev/null; if nft list table inet vpnpool >/dev/null 2>&1; then'
ctl route-no-killswitch-fallback daemon fail 'daemon/route-refused-no-table-killswitch-blocks ' \
	"$LIBX/route.sh" '		if apply_table "" "" "$V6" || apply_table "" "" ""; then' '		if false; then'
# review B: IPv6 guard left out of the transaction
ctl ipv6-guard-dropped daemon fail 'daemon/route-up-atomic-idempotent ' \
	"$LIBX/route.sh" 'if apply_table "$CLIENT_SET" "$CLIENT_RULE" "$V6"; then' 'if apply_table "$CLIENT_SET" "$CLIENT_RULE" ""; then'
ctl clash-delay-criterion-broken daemon fail 'daemon/alive-criterion ;daemon/nodecheck-wan-up-strikes-dead-node ' \
	"$LIBX/lib.sh" 'clash_delay_alive() { case "$1" in *' 'clash_delay_alive() { return 0; case "$1" in *'
ctl power-off-stops-everything tgbot fail 'tgbot/power-off-keeps-bot ' \
	"$LIBX/power.sh" '	/etc/init.d/vpnpool reload >/dev/null 2>&1' '	/etc/init.d/vpnpool stop >/dev/null 2>&1'
ctl initd-reload-noop-again tgbot fail 'tgbot/initd-reload-really-reaches-procd ' \
	package/vpnpool/files/etc/init.d/vpnpool 'service_triggers() {' 'reload_service() { start_service; }; service_triggers() {'
# REVIEW_wave2 1: a long step back in the foreground -> TERM waits for it
ctl daemon-fetch-in-foreground daemon fail 'daemon/term-during-long-fetch-cleans-up-at-once ' \
	"$LIBX/vpnpoold" 'run_child "$LIBEXEC/fetch.sh" || log "fetch failed (cached' '"$LIBEXEC/fetch.sh" || log "fetch failed (cached'
# every failure seen through run_child (failed build, dead tunnel probe) turns into success
ctl daemon-run-child-loses-rc daemon fail 'daemon/reload-dead-tunnel-failsafe-down ;daemon/reload-build-fails-keeps-config-and-routes ;daemon/periodic-refresh-through-failsafe ;daemon/startup-dead-tunnel-clears-stale-routes ;daemon/startup-guard-clears-stale-table-before-first-build ;daemon/usr1-during-build-keeps-failure ;daemon/signal-during-route-up-no-desync ;daemon/watchdog-dead-tunnel-takes-routes-down ' \
	"$LIBX/vpnpoold" 'wait "$CHILD"; rc=$?' 'wait "$CHILD"; rc=0'
ctl daemon-cleanup-leaves-child daemon fail 'daemon/term-during-long-fetch-cleans-up-at-once ' \
	"$LIBX/vpnpoold" '	stop_child' '	:'
# integrator's assumption: restart keeps the kill-switch block, stop / the user's off remove it
ctl daemon-restart-drops-block daemon fail 'daemon/restart-with-killswitch-keeps-block ' \
	"$LIBX/vpnpoold" 'if restart_keeps_block; then' 'if false; then'
ctl daemon-restart-ignores-user-off daemon fail 'daemon/user-off-with-killswitch-removes-block-even-in-a-restart ' \
	"$LIBX/vpnpoold" '[ "$(uci -q get vpnpool.main.enabled)" = 1 ] || return 1   # the user' ':   # the user'
ctl initd-restart-no-marker tgbot fail 'tgbot/initd-restart-marks-a-restart ' \
	package/vpnpool/files/etc/init.d/vpnpool 'mkdir -p /var/run && : > /var/run/vpnpool.restarting' ':'
# REVIEW_wave2 2: power.sh around the daemon's state change
ctl power-on-hups-dying-daemon tgbot fail 'tgbot/power-quick-off-on-waits-and-starts ' \
	"$LIBX/power.sh" 'if [ "$was" = 1 ] && signal_daemon HUP; then' 'if signal_daemon HUP; then'
ctl power-off-no-leftover-cleanup tgbot fail 'tgbot/power-off-removes-leftovers-of-a-killed-daemon ' \
	"$LIBX/power.sh" '		leftovers_down' '		:'
# REVIEW_wave2 5: RAM mode must not get the boot hook
ctl power-ram-mode-enables tgbot fail 'tgbot/power-ram-mode-no-enable ' \
	"$LIBX/power.sh" 'boot_hook() { [ -f "$RAM_HOOK" ] || /etc/init.d/vpnpool enable' 'boot_hook() { /etc/init.d/vpnpool enable'
# REVIEW_wave2 3: the tag safety net keeps repeated nodes
ctl tag-guard-keeps-repeats build fail 'build/tag-guard-drops-repeated-nodes ' \
	"$LIBX/lib.sh" 'then .dropped += [$e.v.tag]' 'then .[$e.a] += [$e.v]'
ctl alive-criterion-000-alive daemon fail 'daemon/alive-criterion ;daemon/probe-services-any-vs-all ' \
	"$LIBX/lib.sh" 'svc_code_alive() { case "$1" in [1-5][0-9][0-9])' 'svc_code_alive() { case "$1" in [0-9][0-9][0-9])'
ctl node-test-uses-lan-selector daemon fail 'daemon/node-tests-use-test-selector-only ' \
	"$LIBX/lib.sh" 'proxies/vpnpool-test" \' 'proxies/proxy" \'
# stage 2 (2.9): Telegram bot
ctl tgbot-off-runs-route-sh tgbot fail 'tgbot/off-sets-pause-and-signals-daemon ' \
	"$LIBX/tgbot.sh" '	: > "$PAUSE_FLAG"' '	"$LIBEXEC/route.sh" down >/dev/null 2>&1'
ctl tgbot-kills-foreign-pollers tgbot fail 'tgbot/sweep-only-own-token ' \
	"$LIBX/tgbot.sh" 'pgrep -f "bot$tok/getUpdates"' 'pgrep -f "getUpdates"'
ctl tgbot-no-direct-fallback tgbot fail 'tgbot/poll-direct-when-proxy-refused ' \
	"$LIBX/lib.sh" 'if [ "$rc" -ne 7 ]; then' 'if true; then'
ctl initd-no-bot-signature tgbot fail 'tgbot/initd-bot-instance ' \
	package/vpnpool/files/etc/init.d/vpnpool 'procd_set_param env VPNPOOL_TG_SIG="$sig"' ':'
# stage 2: rpcd methods touched here
ctl rpcd-refresh-wrong-signal rpcd fail 'rpcd/refresh/ok ' \
	"$RPCD" 'd=$(signal_word USR2)' 'd=$(signal_word USR1)'
ctl rpcd-interval-unchecked rpcd fail 'rpcd/set_option/interval-below-10m-rejected ;rpcd/set_option/interval-malformed-rejected ' \
	"$RPCD" '[ "$s" -ge "$INTERVAL_MIN" ] || {' 'true || {'
ctl rpcd-telegram-no-reload rpcd fail 'rpcd/set_option/telegram-token-change-reloads-bot ;rpcd/set_option/telegram_chat-change-reloads-bot ;rpcd/set_option/telegram_via_proxy-change-reloads-bot ' \
	"$RPCD" '[ "$old" = "$v" ] || /etc/init.d/vpnpool reload' '[ "$old" = "$v" ] || :'
ctl status-delay-lost status fail 'status/300-nodes-daemon-up-valid ' \
	"$LIBX/status.sh" 'map(select(. != null and . > 0))' 'map(select(. != null and . > 100000))'
ctl uitext-new-technical-string uitext fail 'uitext/real-app-no-new-violations ;uitext/baseline-gates-new-violations ;uitext/stale-baseline-line-fails ' \
	"$VIEW/dashboard.js" "_('Cancel')" "_('Cancel via rpcd')"
# ui0: the guard reads the shared modules (vpnpool/common.js) and po, counts a po msgid once
ctl uitext-views-only uitext fail 'uitext/positive-control-bad-fixture-caught ' \
	stand/tests/ui-text-guard.uc "walk(ROOT + '/files/www/luci-static/resources', '.js', [])" "walk(ROOT + '/files/www/luci-static/resources/view', '.js', [])"
ctl uitext-po-counted-twice uitext fail 'uitext/positive-control-bad-fixture-caught ;uitext/real-app-no-new-violations ;uitext/baseline-gates-new-violations ;uitext/stale-baseline-line-fails ' \
	stand/tests/ui-text-guard.uc '(catalog && seen_text[text])' '(false)'
ctl uitext-po-header-scanned uitext fail 'uitext/positive-control-bad-fixture-caught ' \
	stand/tests/ui-text-guard.uc "if (!(substr(cur, 0, 6) == 'msgstr' && id == ''))" 'if (true)'
ctl uitext-common-js-technical uitext fail 'uitext/real-app-no-new-violations ;uitext/baseline-gates-new-violations ;uitext/stale-baseline-line-fails ' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "_('More actions')" "_('More actions (watchdog)')"
# ui0: po completeness (ui-i18n.sh check)
ctl i18n-untranslated ui-i18n fail 'FAIL untranslated ru: More actions' \
	package/luci-app-vpnpool/po/ru/vpnpool.po 'msgstr "Ещё действия"' 'msgstr ""'
ctl i18n-new-string-not-in-po ui-i18n fail 'FAIL pot-missing-msgid A new string;FAIL po-missing-msgid ru: A new string;FAIL pot-stale More actions;FAIL po-obsolete ru: More actions' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "_('More actions')" "_('A new string')"
ctl i18n-placeholder-mismatch ui-i18n fail 'FAIL placeholders ru: "Switched to %s"' \
	package/luci-app-vpnpool/po/ru/vpnpool.po 'msgstr "Переключено на %s"' 'msgstr "Переключено на %d"'
ctl i18n-nonbmp-msgid ui-i18n fail 'FAIL nonbmp More actions 📌;FAIL pot-missing-msgid More actions 📌;FAIL po-missing-msgid ru: More actions 📌;FAIL pot-stale More actions;FAIL po-obsolete ru: More actions' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "_('More actions')" "_('More actions 📌')"
ctl ui-smoke-status-broken ui-smoke fail 'ubus vpnpool.status via /ubus' \
	"$RPCD" '		/usr/libexec/vpnpool/status.sh' '		echo not-json'
# runner: a suite that silently stops early must fail the run (min-cases.txt), not shrink total
ctl suite-stops-early sched fail 'runner/sched-ran-at-least-6-cases' \
	stand/tests/suites/sched.sh '# ---- garbage times are rejected' 'return 0   # ---- garbage times are rejected'
# deploy.sh: a "./" member is refused before anything is sent
ctl deploy-dot-member-refused deploy-tar fail 'deploy.sh refused' \
	scripts/deploy.sh '$(cd "$tmp" && ls -A)' '.'
# deploy.sh: members not owned 0:0 are refused (Git Bash/macOS write the user's uid)
ctl deploy-foreign-owner-refused deploy-tar fail 'deploy.sh refused' \
	scripts/deploy.sh 'own="--owner=0 --group=0 --numeric-owner"' 'own="--numeric-owner"'
# full revert to the old behaviour ("./" member, user's uid, no check, extract without -o):
# the target / and existing dirs get re-owned -> the busybox-tar check must see it
ctl deploy-old-behaviour deploy-tar fail 'root/dirs changed' \
	scripts/deploy.sh '$(cd "$tmp" && ls -A)' '.' \
	scripts/deploy.sh 'own="--owner=0 --group=0 --numeric-owner"' 'own="--numeric-owner"' \
	scripts/deploy.sh 'check_tar "$ARCHIVE"' ': check_tar' \
	scripts/deploy.sh "REMOTE_EXTRACT='tar xzof - -C /'" "REMOTE_EXTRACT='tar xzf - -C /'"
# awgdecode.uc (vpn:// decoder)
# the old unbounded inflate: no end-of-input / stored-header / NLEN / stored-length guard and
# no block budget (five layers; any one alone stops the zero-filled stream, hence all five)
ctl awgdecode-inflate-unbounded awgdecode fail 'awgdecode/garbage-zlib-zeros ;awgdecode/blocks-5000-refused ;awgdecode/no-human-text-in-errors ' \
	"$LIBX/awgdecode.uc" 'if (pos >= dlen) { overrun = true; return 0; }' 'if (false) { overrun = true; return 0; }' \
	"$LIBX/awgdecode.uc" 'if (pos + 4 > dlen) return null;' 'if (false) return null;' \
	"$LIBX/awgdecode.uc" 'if ((len ^ 0xffff) != nlen) return null;' 'if (false) return null;' \
	"$LIBX/awgdecode.uc" 'if (pos + len > dlen || length(out) + len > maxout) return null;' 'if (length(out) + len > maxout) return null;' \
	"$LIBX/awgdecode.uc" 'if (++nblocks > MAX_BLOCKS) return null;' 'if (++nblocks < 0) return null;'
ctl awgdecode-whitespace-kept awgdecode fail 'awgdecode/vec-B2_wrapped_crlf ;awgdecode/vec-B3_space_inside ;awgdecode/vec-B_wrapped76 ;awgdecode/caption-wrapped-trailing-text ;awgdecode/uncompressed-json-crlf-wrapped ' \
	"$LIBX/awgdecode.uc" "return (n >= 1) ? join('', slice(words, 0, n)) : null;" "return (n >= 1) ? join(' ', slice(words, 0, n)) : null;"
# limits on untrusted input (each control lifts ONE limit; the case with that vector goes red)
ctl awgdecode-cands-unbounded awgdecode fail 'awgdecode/many-words-40k ' \
	"$LIBX/awgdecode.uc" 'const MAX_CANDS = 3;' 'const MAX_CANDS = 100000;'
ctl awgdecode-input-unbounded awgdecode fail 'awgdecode/input-over-256k-refused ;awgdecode/links-100k-refused ' \
	"$LIBX/awgdecode.uc" 'const MAX_IN = 256 * 1024;' 'const MAX_IN = 64 * 1024 * 1024;'
ctl awgdecode-declared-unbounded awgdecode fail 'awgdecode/declared-4mb-refused ;awgdecode/no-human-text-in-errors ' \
	"$LIBX/awgdecode.uc" "if (want > MAX_OUT) return { code: 'E_TOO_BIG' };" "if (false) return { code: 'E_TOO_BIG' };"
ctl awgdecode-blocks-unbounded awgdecode fail 'awgdecode/blocks-5000-refused ' \
	"$LIBX/awgdecode.uc" 'if (++nblocks > MAX_BLOCKS) return null;' 'if (++nblocks < 0) return null;'
ctl awgdecode-links-unbounded awgdecode fail 'awgdecode/links-40k-capped ;awgdecode/links-33-good ' \
	"$LIBX/awgdecode.uc" 'if (length(res) >= MAX_LINKS) { more++; continue; }' 'if (false) { more++; continue; }'
ctl awgdecode-types-unguarded awgdecode fail 'awgdecode/types-stream-str ;awgdecode/types-reality-num ;awgdecode/types-ws-headers-str ' \
	"$LIBX/awgdecode.uc" "function objv(x) { return (type(x) == 'object') ? x : {}; }" 'function objv(x) { return x ?? {}; }'
ctl awgdecode-legacy-default-only awgdecode fail 'awgdecode/legacy-default-xray-still-gives-conf ' \
	"$LIBX/awgdecode.uc" "if (want_conf && pb.proto != 'awg' && pb.proto != 'wireguard') continue;" 'if (false) continue;'
ctl awgdecode-default-ignored awgdecode fail 'awgdecode/default-container-wins ' \
	"$LIBX/awgdecode.uc" 'rank: (isdef ? 0 : 10)' 'rank: (isdef ? 10 : 10)'
# (the api-key vector also carries config_version, which a second rule refuses: the
#  no-version vector is the one only this rule protects)
ctl awgdecode-api-key-imported awgdecode fail 'awgdecode/api-key-no-version ' \
	"$LIBX/awgdecode.uc" 'if (obj.api_key != null || obj.auth_data != null || obj.api_config != null)' 'if (false)'
ctl awgdecode-full-access-imported awgdecode fail 'awgdecode/full-access ' \
	"$LIBX/awgdecode.uc" 'if (obj.hostName != null && obj.userName != null && obj.password != null)' 'if (false)'
ctl awgdecode-adler-unchecked awgdecode fail 'awgdecode/bad-adler32 ' \
	"$LIBX/awgdecode.uc" 'if (ad != adler32(r.out))' 'if (false)'
# engine.sh (AWG engine installer) — engine controls need ENGINE_ASSET_DIR (real asset)
# a real asset with one byte changed still RUNS (version + check pass): sha256 is the only guard
ctl engine-sha-unchecked engine fail 'engine/corrupt-asset-sha-refused ;engine/override-sha-mismatch-refused ;engine/real-corrupt-over-working ' \
	"$LIBX/engine.sh" '|| out_fail E_SHA "want=$_sha"' '|| true "want=$_sha"'
ctl engine-version-unchecked engine fail 'engine/wrong-version-refused ' \
	"$LIBX/engine.sh" '[ "$_v" = "$ENGINE_VERSION" ] || out_fail' 'true || out_fail'
ctl engine-awg-check-skipped engine fail 'engine/no-awg-check-refused ' \
	"$LIBX/engine.sh" 'awg_check "$TMPF" || out_fail E_CHECK' 'true || out_fail E_CHECK'
ctl engine-space-unchecked engine fail 'engine/no-space-refused ' \
	"$LIBX/engine.sh" '[ "$_avail" -ge $((_need + ENGINE_SPACE_MARGIN_KB)) ]' 'true || [ "$_avail" -ge 0 ]'
ctl engine-download-over-working engine fail 'engine/corrupt-asset-sha-refused ;engine/override-sha-mismatch-refused ;engine/override-no-sha256-refused ;engine/override-garbage-sha256-refused ;engine/wrong-version-refused ;engine/no-awg-check-refused ;engine/download-404-refused ;engine/real-corrupt-over-working ' \
	"$LIBX/engine.sh" 'TMPF="$_dir/.$(basename "$DEST").new.$$"' 'TMPF="$DEST"'
ctl engine-arch-too-wide engine fail 'engine/arch-mips64_octeonplus ;engine/unknown-arch-refused ;engine/install-sh-awg1-unsupported-arch ' \
	"$LIBX/engine.sh" 'mips_24kc|mips_24kc_*|mips_34kc|mips_34kc_*|mips_74kc|mips_74kc_*) echo mips_24kc ;;' 'mips*) echo mips_24kc ;;'
ctl engine-orphan-kept engine fail 'engine/orphan-temp-file-removed ' \
	"$LIBX/engine.sh" 'rm -f "$_dir/.$(basename "$DEST").new."* 2>/dev/null' ': "$_dir"'
ctl engine-ram-threshold-256 engine fail 'engine/ram-mode-small-memtotal-refused ;engine/ram-mode-256mb-class-ok ;engine/update-keeps-ram-mode ' \
	"$LIBX/engine.sh" 'ENGINE_RAM_MIN_MB="${VPNPOOL_ENGINE_RAM_MIN_MB:-200}"' 'ENGINE_RAM_MIN_MB="${VPNPOOL_ENGINE_RAM_MIN_MB:-256}"'
ctl engine-update-ignores-record engine fail 'engine/update-keeps-ram-mode ' \
	"$LIBX/engine.sh" "&& [ \"\$(jq -r '.ram // false' \"\$ENGINE_STATE\" 2>/dev/null)\" = true ]; then" '&& false; then'
ctl engine-fetch-no-fallback engine fail 'engine/downloader-fallback-to-wget ;engine/override-no-sha256-refused ;engine/download-404-refused ' \
	"$LIBX/engine.sh" 'fetch_once "$_t" "$1" "$2" && return 0   # fallback downloader' 'false && return 0   # fallback downloader'
ctl engine-stock-not-restored engine fail 'engine/install-restores-stock-opkg ;engine/stock-restore-fails-engine-stays ;engine/install-restores-stock-apk ;engine/install-sh-restores-stock ;engine/install-sh-stock-restore-fails ' \
	"$LIBX/engine.sh" 'if [ "$S_REPLACED" = true ] && [ "$S_REASON" != ram ]; then' 'if false; then'
ctl engine-fork-not-recognised engine fail 'engine/stock-fork-detected-opkg ;engine/install-restores-stock-opkg ;engine/stock-restore-fails-engine-stays ' \
	"$LIBX/engine.sh" 'case "$S_VER" in *awg*|*AWG*) S_REPLACED=true; S_REASON=awg_build; return ;; esac' ':'
ctl engine-installer-leaks-codes engine fail 'engine/install-sh-awg1-unsupported-arch ;engine/install-sh-update-without-engine ;engine/install-sh-ram-small-memory ' \
	install.sh 'say "AmneziaWG: $(awg_explain "$code" "$pa").' 'say "AmneziaWG: $res $(awg_explain "$code" "$pa").'

wait
for n in $NC_ORDER; do
	o="$TMPBASE/$n.out"
	if [ -s "$o" ]; then cat "$o"; else echo "BAD   $n: no verdict (control run died)"; fi
	case "$(head -c 5 "$o" 2>/dev/null)" in "OK   ") OK=$((OK+1)) ;; *) BAD=$((BAD+1)) ;; esac
done
rm -rf "$TMPBASE"
echo "CONTROLS: ok=$OK bad=$BAD"
[ "$BAD" -eq 0 ] && [ "$OK" -gt 0 ]
