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
	cp -r "$REPO/package" "$REPO/stand" "$REPO/scripts" "$d/"
	while [ $# -ge 3 ]; do
		if ! replace_once "$d/$1" "$2" "$3" || cmp -s "$REPO/$1" "$d/$1"; then
			echo "BAD   $name: needle not found / copy unchanged in $1 (control is void)"; BAD=$((BAD+1)); rm -rf "$d"; return 0
		fi
		shift 3
	done
	case "$suite" in
		ui-smoke)   REPO_DIR="$d" sh "$HERE/ui-smoke.sh" > "$d.log" 2>&1
		            line=$(grep '^UI-SMOKE: ' "$d.log" | tail -1) ;;
		deploy-tar) REPO_DIR="$d" sh "$HERE/deploy-tar-test.sh" > "$d.log" 2>&1
		            line=$(grep '^DEPLOY-TAR: ' "$d.log" | tail -1) ;;
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
	if [ "$verdict" = OK ]; then OK=$((OK+1)); else BAD=$((BAD+1)); fi
	rm -rf "$d" "$d.log" "$d.red"
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
ctl build-config-not-installed build fail 'build/clean-subscription ;build/poison-port-70000 ;build/poison-reserved-tag-direct ;build/poison-reserved-tag-auto ;build/poison-reserved-tag-proxy ;build/poison-duplicate-tags ;build/not-frozen-new-node-arrives-despite-poison ;build/xhttp-builds ;build/xhttp-not-in-config ;build/junk-json-source-does-not-empty-pool ;build/json-source-long-short-id-no-panic ;build/awg-node-on-stock-engine-deferred ;build/unchanged-pool-no-flash-write ;build/changed-pool-flash-updated ;build/after-reboot-failed-build-keeps-flash-config ;build/node-test-selector-separate-from-proxy ;build/poison-json-source-unknown-field ' \
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
ctl build-singular-regex-only build fail 'build/poison-port-70000 ;build/not-frozen-new-node-arrives-despite-poison ;build/awg-node-on-stock-engine-deferred ' \
	"$LIBX/build.sh" "grep -oE '(outbound|endpoint)s?\[[0-9]+\]'" "grep -oE '(outbound|endpoint)\[[0-9]+\]'"
# name hygiene off AND the duplicate-tag fallback off -> reserved / repeated names freeze the build
ctl build-names-unguarded build fail 'build/poison-reserved-tag-direct ;build/poison-reserved-tag-auto ;build/poison-reserved-tag-proxy ;build/poison-duplicate-tags ' \
	"$LIBX/build.sh" '((.tag) as $t | ($r|index($t))==null)' 'true' \
	"$LIBX/build.sh" 'if .s[$n.tag] then . else' 'if false then . else' \
	"$LIBX/build.sh" "s/.*duplicate [a-z/]* *tag: *//p" "s/.*duplicateX [a-z/]* *tag: *//p"
ctl build-flash-always-written build fail 'build/unchanged-pool-no-flash-write ' \
	"$LIBX/build.sh" 'persist_if_changed "$SB_CONF" "$SB_CONF_FLASH"' 'cp "$SB_CONF" "$SB_CONF_FLASH"'
# stage 2 (2.3 / 2.4 / 2.8 / 2.10): daemon
ctl daemon-killswitch-ignored daemon fail 'daemon/route-policy-table ;daemon/reload-killswitch-dead-tunnel-keeps-routes ;daemon/startup-killswitch-routes-at-once ;daemon/pause-flag-down-then-up ' \
	"$LIBX/lib.sh" '[ "$1" = 1 ] && { echo up; return 0; }' '[ "$1" = 1 ] && { echo down; return 0; }'
ctl daemon-reload-drops-routes-first daemon fail 'daemon/reload-killswitch-dead-tunnel-keeps-routes ;daemon/reload-healthy-keeps-routes ;daemon/reload-dead-tunnel-failsafe-down ;daemon/periodic-refresh-through-failsafe ' \
	"$LIBX/vpnpoold" '		start_singbox   # routes stay as they are while it restarts' '		"$LIBEXEC/route.sh" down; start_singbox'
ctl daemon-startup-keeps-stale-table daemon fail 'daemon/startup-dead-tunnel-clears-stale-routes ' \
	"$LIBX/vpnpoold" 'if [ "$ROUTED" != 0 ] || [ -n "${2:-}" ]; then' 'if [ "$ROUTED" != 0 ] || [ "${2:-}" = reapply ]; then'
ctl daemon-watchdog-no-failsafe daemon fail 'daemon/watchdog-dead-tunnel-takes-routes-down ' \
	"$LIBX/vpnpoold" '			apply_routing 0' '			:'
ctl daemon-reload-nested daemon fail 'daemon/reload-queued-not-nested ' \
	"$LIBX/vpnpoold" 'if [ "$RELOADING" = 1 ]; then' 'if false; then'
ctl daemon-dead-set-erases-pin daemon fail 'daemon/preferred-in-dead-set-hands-to-auto-keeps-pin ;daemon/preferred-recovered-switches-back ' \
	"$LIBX/vpnpoold" 'PREF_DEAD_LOGGED=$pref' 'PREF_DEAD_LOGGED=$pref; uci -q delete vpnpool.main.preferred_node; uci commit vpnpool'
ctl nodecheck-judges-without-wan daemon fail 'daemon/nodecheck-wan-down-judges-nothing ' \
	"$LIBX/nodecheck.sh" 'if ! wan_alive; then' 'if false; then'
ctl route-delete-then-add daemon fail 'daemon/route-up-atomic-idempotent ' \
	"$LIBX/route.sh" '	if ! nft -f - <<NFT' '	nft delete table inet vpnpool 2>/dev/null; if ! nft -f - <<NFT'
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

rm -rf "$TMPBASE"
echo "CONTROLS: ok=$OK bad=$BAD"
[ "$BAD" -eq 0 ] && [ "$OK" -gt 0 ]
