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
	cp -r "$REPO/package" "$REPO/stand" "$REPO/scripts" "$REPO/install.sh" "$REPO/.github" "$d/"
	while [ $# -ge 3 ]; do
		if ! replace_once "$d/$1" "$2" "$3" || cmp -s "$REPO/$1" "$d/$1"; then
			echo "BAD   $name: needle not found / copy unchanged in $1 (control is void)"; BAD=$((BAD+1)); rm -rf "$d"; return 0
		fi
		shift 3
	done
	# NC_DRY=1: only check that every needle is still found (no suite runs) — after a change to
	# the code under the controls, before the long run
	if [ "${NC_DRY:-0}" = 1 ]; then echo "DRY   $name"; OK=$((OK+1)); rm -rf "$d"; return 0; fi
	NC_ORDER="$NC_ORDER $name"
	_nc_throttle
	(
	case "$suite" in
		ui-smoke)   REPO_DIR="$d" sh "$HERE/ui-smoke.sh" > "$d.log" 2>&1
		            line=$(grep '^UI-SMOKE: ' "$d.log" | tail -1) ;;
		deploy-tar) REPO_DIR="$d" sh "$HERE/deploy-tar-test.sh" > "$d.log" 2>&1
		            line=$(grep '^DEPLOY-TAR: ' "$d.log" | tail -1) ;;
		upgrade)    REPO_DIR="$d" sh "$HERE/upgrade-opkg-test.sh" > "$d.log" 2>&1
		            line=$(grep '^UPGRADE: ' "$d.log" | tail -1) ;;
		ui-i18n)    REPO_DIR="$d" sh "$HERE/ui-i18n.sh" check > "$d.log" 2>&1
		            line=$(grep '^I18N: ' "$d.log" | tail -1) ;;
		ui-unit)    REPO_DIR="$d" node "$HERE/ui-common.test.js" > "$d.log" 2>&1
		            line=$(grep '^UNIT: ' "$d.log" | tail -1) ;;
		ui-pages)   REPO_DIR="$d" node "$HERE/ui-pages.test.js" > "$d.log" 2>&1
		            line=$(grep '^PAGES: ' "$d.log" | tail -1) ;;
		ui-diag)    REPO_DIR="$d" node "$HERE/ui-diag.test.js" > "$d.log" 2>&1
		            line=$(grep '^DIAG: ' "$d.log" | tail -1) ;;
		ui-nodes)   REPO_DIR="$d" node "$HERE/ui-nodes.test.js" > "$d.log" 2>&1
		            line=$(grep '^NODES: ' "$d.log" | tail -1) ;;
		ui-overview) REPO_DIR="$d" node "$HERE/ui-overview.test.js" > "$d.log" 2>&1
		            line=$(grep '^OVERVIEW: ' "$d.log" | tail -1) ;;
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
ctl parser-id-skips-tls parser fail 'parser/id-covers-every-config-field ;parser/corpus-accepted-by-sing-box-check ' \
	"$LIBX/parser.uc" "k != '_link') c[k] = ob[k];" "k != '_link' && k != 'tls') c[k] = ob[k];"
# id depends on the display name -> renaming changes it
ctl parser-id-uses-name parser fail 'parser/id-stable-across-order-and-name ;parser/id-changes-with-port-and-credential ;parser/id-json-key-order-and-link-agree ;parser/dedup-same-config-other-name-is-one-node ;parser/dedup-users-file-first-keeps-users-name ;parser/id-unique-in-output ' \
	"$LIBX/parser.uc" "if (k != 'tag' && k != 'id' && k != '_link')" "if (k != 'id' && k != '_link')"
# id leaks into the default output -> sing-box check rejects the config
ctl parser-id-always parser fail 'parser/id-not-in-default-output ;parser/corpus-accepted-by-sing-box-check ;parser/json-source-guards ;parser/awg-id-is-sha256-of-private-key ;parser/src-and-filters-off-by-default ' \
	"$LIBX/parser.uc" 'if (WITH_ID && id) ob.id = id;' 'if (id) ob.id = id;'
# dedup without the name -> a user's copy of a subscription node vanishes
# (stage 6) control parser-dedup-without-name retired: the dedup IS by the id now (no name in it); the opposite break is s6-parser-dedup-by-name
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
ctl parser-unknown-transport-kept parser fail 'parser/vless-kcp-refused ;parser/report-reasons ' \
	"$LIBX/parser.uc" "	return 'unsupported_transport';" "	return { type: t };"
# XHTTP nodes are not handed to the xray sidecar: sing-box refuses them, nothing reaches xray
ctl build-xhttp-not-to-sidecar build fail 'build/xhttp-with-xray-socks-to-sidecar ;build/xhttp-node-xray-refuses-is-dropped-alone ' \
	"$LIBX/generator.uc" "if (type(n) != 'object' || n.transport?.type != 'xhttp') continue;" "if (true) continue;"
# the xray config is not checked: the node xray refuses stays in both configs
ctl build-xray-not-checked build fail 'build/xhttp-node-xray-refuses-is-dropped-alone ' \
	"$LIBX/build.sh" 'if [ -s "$XRAY_NEW" ] && ! "$XRAY_BIN" run -test' 'if false && ! "$XRAY_BIN" run -test'
# the add-time trial download tries one client name only (a panel giving xray JSON to it is refused)
ctl api-sub-probe-one-client rpcd fail 'rpcd/add/url-first-client-gets-xray-json-next-gets-links ' \
	"$LIBX/api.uc" "	for (let ua in uas) {" "	for (let ua in [ uas[0] ]) {"
# every case that inspects the installed config goes red
ctl build-config-not-installed build fail 'build/clean-subscription ;build/poison-port-70000 ;build/poison-reserved-tag-direct ;build/poison-reserved-tag-auto ;build/poison-reserved-tag-proxy ;build/poison-duplicate-tags ;build/not-frozen-new-node-arrives-despite-poison ;build/xhttp-builds ;build/xhttp-without-xray-deferred ;build/xhttp-with-xray-socks-to-sidecar ;build/xhttp-node-xray-refuses-is-dropped-alone ;build/xhttp-gone-xray-config-removed ;build/junk-json-source-does-not-empty-pool ;build/json-source-long-short-id-no-panic ;build/awg-node-on-stock-engine-deferred ;build/unchanged-pool-no-flash-write ;build/changed-pool-flash-updated ;build/after-reboot-failed-build-keeps-flash-config ;build/node-test-selector-separate-from-proxy ;build/poison-json-source-unknown-field ;build/poison-json-endpoint-unknown-field ;build/generator-tags-reserved-in-parser ;build/status-file-lists-engine-drop ;build/nodes-carry-id-config-does-not ;build/log-counts-the-final-pool ;build/term-writes-interrupted ;build/model-inputs-sources-and-filters ;build/model-auto-members-and-dead-by-id ;build/model-favourites-only-and-preferred-default ;build/model-favourites-only-never-empties-the-pool ;build/model-active-favourites-join-the-pool ;build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluding-every-node-is-ignored ;build/model-excluded-only-favourite-then-the-others ;build/model-excluded-member-leaves-the-member-list ' \
	"$LIBX/build.sh" 'mv "$SB_CONF.new" "$SB_CONF"' 'rm -f "$SB_CONF.new"'
# add / add_node write but never signal (and say n/a instead of not_running)
ctl rpcd-add_node-no-signal rpcd fail 'rpcd/add_node/ok ;rpcd/add_node/no-daemon-reported ;rpcd/add_sub/ok ;rpcd/add_sub/no-daemon-reported ;rpcd/add/ok ;rpcd/add/no-daemon-reported ' \
	"$RPCD" '		case "$a" in USR1|USR2) d=$(signal_word "$a") ;; esac' '		case "$a" in USR1|USR2)  d=$(signal_word "$a") ;; esac' \
	"$RPCD" '		case "$a" in USR1|USR2) d=$(signal_word "$a") ;; esac' '		case "$a" in USR1|USR2) d=n/a ;; esac'
# (the first pair re-spaces apply_api's same line, so the mutation lands in apply_add) and the
# node / sub / favourite methods through apply_api: every one reports the daemon it signalled
ctl rpcd-api-no-signal rpcd fail 'rpcd/set_url/ok ;rpcd/set_url/no-daemon-reported ;rpcd/del_subscription/ok ;rpcd/del_subscription/no-daemon-reported ;rpcd/del_source/ok ;rpcd/del_source/no-daemon-reported ;rpcd/import_select/ok ;rpcd/import_select/no-daemon-reported ;rpcd/delete_node/ok ;rpcd/delete_node/no-daemon-reported ;rpcd/delete_nodes/ok ;rpcd/delete_nodes/no-daemon-reported ;rpcd/restore_node/ok ;rpcd/restore_node/no-daemon-reported ;rpcd/refilter_node/ok ;rpcd/refilter_node/no-daemon-reported ;rpcd/activate_saved/ok ;rpcd/activate_saved/no-daemon-reported ;rpcd/deactivate_saved/ok ;rpcd/deactivate_saved/no-daemon-reported ;rpcd/del_sub/ok ;rpcd/del_sub/no-daemon-reported ;rpcd/hide/ok ;rpcd/hide/no-daemon-reported ;rpcd/unhide/ok ;rpcd/unhide/no-daemon-reported ;rpcd/auto_exclude/ok ;rpcd/auto_exclude/no-daemon-reported ;rpcd/auto_include/ok ;rpcd/auto_include/no-daemon-reported ;rpcd/sub_set/ok ;rpcd/sub_set/no-daemon-reported ;rpcd/sub_del/ok ;rpcd/sub_del/no-daemon-reported ;rpcd/connect/favourite-not-in-a-source-joins-the-pool ' \
	"$RPCD" '		case "$a" in USR1|USR2) d=$(signal_word "$a") ;; esac' '		case "$a" in USR1|USR2) d=n/a ;; esac'
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
ctl fetch-userinfo-lost fetch fail 'fetch/all-sources-ok ;fetch/primary-fails-extra-ok-keeps-primary-nodes ' \
	"$LIBX/fetch.sh" '		| {expire: ($u.expire // null),' '		| {expire: null,'
# stage 2 (2.5 / 2.11): fetch
ctl fetch-no-per-source-cache fetch fail 'fetch/primary-fails-extra-ok-keeps-primary-nodes ;fetch/status-per-source ;fetch/all-fail-serves-cache ;fetch/removed-source-dropped-from-cache ;fetch/fetch-due-throttle ;fetch/oversized-answer-not-used ' \
	"$LIBX/fetch.sh" 'if [ -s "$cached" ]; then' 'if false; then'
ctl fetch-url-in-clear fetch fail 'fetch/token-masked-in-log ' \
	"$LIBX/fetch.sh" 'log "fetch: $(mask_url "$url") -> $best nodes' 'log "fetch: $url -> $best nodes'
ctl fetch-cache-always-rewritten fetch fail 'fetch/unchanged-source-cache-not-rewritten ;fetch/changed-source-cache-rewritten ' \
	"$LIBX/fetch.sh" 'mkdir -p "$CACHEDIR"; persist_if_changed "$out" "$cached"' 'mkdir -p "$CACHEDIR"; cp "$out" "$cached"'
ctl fetch-no-throttle fetch fail 'fetch/fetch-due-throttle ' \
	"$LIBX/lib.sh" '[ $(( now - t )) -ge "$INTERVAL_MIN" ]' 'true'
# stage 2 (2.1 / 2.11): build
ctl build-singular-regex-only build fail 'build/poison-json-source-unknown-field ;build/poison-json-endpoint-unknown-field ;build/status-file-lists-engine-drop ;build/log-counts-the-final-pool ' \
	"$LIBX/build.sh" "grep -oE '(outbound|endpoint)s?\[[0-9]+\]'" "grep -oE '(outbound|endpoint)\[[0-9]+\]'"
# one owner of the reserved names: a generator tag missing from parser.uc's list is caught
ctl parser-reserved-misses-generator-tag build fail 'build/generator-tags-reserved-in-parser ' \
	"$LIBX/parser.uc" "'dns-out': 1, 'vpnpool-test': 1 };" "'dns-out': 1 };"
ctl build-flash-always-written build fail 'build/unchanged-pool-no-flash-write ' \
	"$LIBX/build.sh" 'persist_if_changed "$SB_CONF" "$SB_CONF_FLASH"' 'cp "$SB_CONF" "$SB_CONF_FLASH"'
# stage 2 (2.3 / 2.4 / 2.8 / 2.10): daemon
ctl daemon-killswitch-ignored daemon fail 'daemon/route-policy-table ;daemon/reload-killswitch-dead-tunnel-keeps-routes ;daemon/startup-killswitch-routes-at-once ;daemon/startup-guard-killswitch-blocks-before-first-build ;daemon/pause-flag-down-then-up ' \
	"$LIBX/lib.sh" '[ "$1" = 1 ] && { echo up; return 0; }' '[ "$1" = 1 ] && { echo down; return 0; }'
ctl daemon-reload-drops-routes-first daemon fail 'daemon/reload-killswitch-dead-tunnel-keeps-routes ;daemon/reload-healthy-keeps-routes ;daemon/reload-dead-tunnel-failsafe-down ;daemon/periodic-refresh-through-failsafe ;daemon/signal-during-route-up-no-desync ;daemon/reload-fetches-only-the-queued-subscriptions ;daemon/full-refetch-takes-the-queue-along ' \
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
ctl clash-delay-criterion-broken daemon fail 'daemon/alive-criterion ;daemon/nodecheck-wan-up-strikes-dead-node ;daemon/nodecheck-strikes-say-when-and-which-host ' \
	"$LIBX/lib.sh" 'clash_delay_alive() { case "$1" in *' 'clash_delay_alive() { return 0; case "$1" in *'
ctl power-off-stops-everything tgbot fail 'tgbot/power-off-keeps-bot ' \
	"$LIBX/power.sh" '	/etc/init.d/vpnpool reload >/dev/null 2>&1' '	/etc/init.d/vpnpool stop >/dev/null 2>&1'
ctl initd-reload-noop-again tgbot fail 'tgbot/initd-reload-really-reaches-procd ' \
	package/vpnpool/files/etc/init.d/vpnpool 'service_triggers() {' 'reload_service() { start_service; }; service_triggers() {'
# REVIEW_wave2 1: a long step back in the foreground -> TERM waits for it
ctl daemon-fetch-in-foreground daemon fail 'daemon/term-during-long-fetch-cleans-up-at-once ' \
	"$LIBX/vpnpoold" 'run_child "$LIBEXEC/fetch.sh" || log "fetch failed (cached' '"$LIBEXEC/fetch.sh" || log "fetch failed (cached'
# every failure seen through run_child (failed build, dead tunnel probe) turns into success
ctl daemon-run-child-loses-rc daemon fail 'daemon/reload-dead-tunnel-failsafe-down ;daemon/reload-build-fails-keeps-config-and-routes ;daemon/periodic-refresh-through-failsafe ;daemon/startup-dead-tunnel-clears-stale-routes ;daemon/startup-guard-clears-stale-table-before-first-build ;daemon/usr1-during-build-keeps-failure ;daemon/signal-during-route-up-no-desync ;daemon/watchdog-dead-tunnel-takes-routes-down ;daemon/tunnel-state-for-the-overview ' \
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
ctl rpcd-interval-unchecked rpcd fail 'rpcd/set_option/interval-below-10m-rejected ;rpcd/set_option/interval-malformed-rejected ;rpcd/set_config/every-check-names-its-code ' \
	"$LIBX/api.uc" "if (n < INTERVAL_MIN) return [ null, 'too_small' ];" "if (false) return [ null, 'too_small' ];"
ctl rpcd-telegram-no-reload rpcd fail 'rpcd/set_option/telegram-token-change-reloads-bot ;rpcd/set_option/telegram_chat-change-reloads-bot ;rpcd/set_option/telegram_via_proxy-change-reloads-bot ;rpcd/set_config/ok ' \
	"$RPCD" '			bot) /etc/init.d/vpnpool reload >/dev/null 2>&1 ;;' '			bot) : ;;'
ctl status-delay-lost status fail 'status/300-nodes-daemon-up-valid ;status/overlapping-polls-no-shared-temp-files ' \
	"$LIBX/status.uc" 'if (h?.delay != null && h.delay > 0) delay = h.delay;' 'if (h?.delay != null && h.delay > 100000) delay = h.delay;'
# ---- stage 3 (ROADMAP §6): honest API, one validator, secrets, analyze/add, backup/restore, status ----
# set_config writes the valid part of a refused save
ctl api-config-partial-write rpcd fail 'rpcd/set_config/bad-input ;rpcd/set_config/all-or-nothing ;rpcd/set_schedule/bad-input ;rpcd/set_schedule/bad-minute-not-stored ' \
	"$LIBX/api.uc" '	if (length(errors)) {' '	if (length(errors) && !length(plan)) {'
# both daemon signals for one save (USR2 already rebuilds)
ctl api-config-two-signals rpcd fail 'rpcd/add/ok ' \
	"$LIBX/api.uc" "	let actions = acts.USR2 ? [ 'USR2' ] : (acts.USR1 ? [ 'USR1' ] : []);" "	let actions = []; if (acts.USR2) push(actions, 'USR2'); if (acts.USR1) push(actions, 'USR1');"
# the masked value the status reply shows is stored as the new secret
ctl api-masked-secret-overwrites rpcd fail 'rpcd/set_config/masked-token-sent-back-keeps-the-real-one ;' \
	"$LIBX/api.uc" "		if (d.secret && type(v) == 'string' && v == masked_of(d, cur)) continue;" "		if (false) continue;"
# analyze: no duplicate detection against the existing pool
ctl api-analyze-no-dup-check rpcd fail 'rpcd/analyze/statuses ' \
	"$LIBX/api.uc" "				if (exist_ids[r.id]) { it.status = 'dup'; it.reason = 'exists'; }" "				if (false) { it.status = 'dup'; it.reason = 'exists'; }" \
	"$LIBX/api.uc" "				it.reason = exist_tags[r.dup_of] ? 'exists' : 'repeated';" "				it.reason = 'repeated';"
# a "not found" answered as success again
# (stage 6) control rpcd-del_sub-not-found-ok retired: del_sub of an unknown URL is refused by api.uc sub del as well (s6-api-sub-del-wrong-one breaks that layer)
# export hands out the token / subscription URL in clear
ctl rpcd-export-unmasked rpcd fail 'rpcd/export/telegram-token-masked ;rpcd/export/subscription-url-masked ;rpcd/import/masked-export-refused ' \
	"$RPCD" '		if ucode "$API" export > /tmp/vpnpool/.export.txt 2>/dev/null; then' '		if uci export vpnpool > /tmp/vpnpool/.export.txt 2>/dev/null; then'
# import without the completeness check: a partial text wipes the rest of the config
ctl rpcd-import-unchecked rpcd fail 'rpcd/import/partial-config-refused ' \
	"$RPCD" '		if ! check_uci_dir "$D" "$D/save"; then rm -rf "$D"; rep false incomplete_config; exit 0; fi' '		:'
# restore replaces without the explicit "replace everything"
ctl rpcd-restore-no-confirm rpcd fail 'rpcd/restore/without-confirm-changes-nothing ' \
	"$RPCD" "		if [ \"\$(printf '%s' \"\$input\" | jq -r '.replace_all == true' 2>/dev/null)\" != true ]; then" '		if false; then'
# restore takes any member of the archive
ctl rpcd-restore-members-unchecked rpcd fail 'rpcd/restore/foreign-member-refused ' \
	"$RPCD" '			  if (NF != 6 || (t != "-" && t != "d") || $6 !~ re) { bad = "invalid_archive"; exit }' '			  if (NF != 6 || (t != "-" && t != "d")) { bad = "invalid_archive"; exit }'
# restore takes an uploaded file from anywhere
ctl rpcd-restore-any-path rpcd fail 'rpcd/restore/path-outside-tmp-refused ;rpcd/restore/path-escaping-tmp-refused-_tmp_vpnpool_lnk_up_tgz_;rpcd/restore/path-escaping-tmp-refused-_tmp____etc_vpnpool_up_tgz_' \
	"$RPCD" "			case \"\$real\" in /tmp/?*) ;; *) bad invalid '{\"errors\":{\"path\":\"bad_value\"}}' ;; esac" '			:'
# a subscription named by its status key is not found
ctl api-resolve-no-key rpcd fail 'rpcd/del_sub/by-status-key ' \
	"$LIBX/api.uc" '	for (let x in all) if (str_key(x) == val) return x;' '	;'
# backup without the AWG files
ctl rpcd-backup-no-awg rpcd fail 'rpcd/backup/full-copy-with-secrets ;rpcd/restore/without-confirm-changes-nothing ;rpcd/restore/replace-all ;rpcd/backup/members-by-the-restore-rule ;rpcd/restore/own-backup-round-trip ;rpcd/restore/same-archive-without-the-fault ' \
	"$LIBX/lib.sh" '	for f in /etc/vpnpool/awg/* /etc/vpnpool/$BACKUP_MAPS; do' '	for f in /etc/vpnpool/$BACKUP_MAPS; do'
# status: the token / the subscription URL in clear
ctl status-token-unmasked status fail 'status/telegram-token-masked ' \
	"$LIBX/status.uc" '		telegram_token: mask_token(token),' '		telegram_token: token,'
ctl status-url-unmasked status fail 'status/subscription-urls-masked ;status/subscriptions-last-fetch ;status/source-urls-masked ' \
	"$LIBX/status.uc" '		title: clean_text(m.title, 64), url: mask_url(s.url),' '		title: clean_text(m.title, 64), url: s.url,'
# status: 20 extra processes per poll -> the process threshold must catch it
ctl status-process-burst status fail 'status/300-nodes-daemon-down-at-most-15-processes ;status/300-nodes-daemon-up-at-most-15-processes ;status/tunnel-exit-checks-at-most-15-processes ' \
	"$LIBX/status.uc" "let routing = length(run('nft list table inet vpnpool 2>/dev/null')) > 0;" "for (let i = 0; i < 20; i++) run('true'); let routing = length(run('nft list table inet vpnpool 2>/dev/null')) > 0;"
# status: no mtime cache -> the small link files are re-parsed on every poll
# (stage 6) control status-no-cache retired: status no longer parses link files (the node list carries its source): s6-status-source-ignored
# status: a dead lock owner counted as busy
ctl status-busy-ignores-owner status fail 'status/build-busy-pause-progress ' \
	"$LIBX/status.uc" "	if (match(pid, /^[0-9]+\$/)) return !!access('/proc/' + pid);" "	if (match(pid, /^[0-9]+\$/)) return true;"
# generator: the node id (nodes.json carries it since stage 3) reaches the sing-box config
# (sing-box refuses the unknown field: EVERY build that installs a config goes red)
ctl generator-keeps-id build fail 'build/clean-subscription ;build/poison-port-70000 ;build/poison-reserved-tag-direct ;build/poison-reserved-tag-auto ;build/poison-reserved-tag-proxy ;build/poison-duplicate-tags ;build/not-frozen-new-node-arrives-despite-poison ;build/poison-json-source-unknown-field ;build/poison-json-endpoint-unknown-field ;build/status-file-lists-engine-drop ;build/log-counts-the-final-pool ;build/json-source-long-short-id-no-panic ;build/xhttp-builds ;build/xhttp-without-xray-deferred ;build/xhttp-with-xray-socks-to-sidecar ;build/xhttp-node-xray-refuses-is-dropped-alone ;build/xhttp-gone-xray-config-removed ;build/junk-json-source-does-not-empty-pool ;build/awg-node-on-stock-engine-deferred ;build/unchanged-pool-no-flash-write ;build/changed-pool-flash-updated ;build/after-reboot-failed-build-keeps-flash-config ;build/node-test-selector-separate-from-proxy ;build/generator-tags-reserved-in-parser ;build/status-file-success ;build/nodes-carry-id-config-does-not ;build/before-kill-status-ok ;build/term-writes-interrupted ;build/model-inputs-sources-and-filters ;build/model-hidden-listed-with-name ;build/model-auto-members-and-dead-by-id ;build/model-favourites-only-and-preferred-default ;build/model-favourites-only-never-empties-the-pool ;build/model-active-favourites-join-the-pool ;build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluding-every-node-is-ignored ;build/model-excluded-only-favourite-then-the-others ;build/model-excluded-member-leaves-the-member-list ' \
	"$LIBX/generator.uc" '	delete n.id;' '	n.id = n.id;'
# build: no build_status.json on success
ctl build-status-not-written build fail 'build/status-file-success ;build/status-file-lists-engine-drop ;build/before-kill-status-ok ;build/awg-node-on-stock-engine-deferred ;build/poison-json-endpoint-unknown-field ;build/model-hidden-listed-with-name ' \
	"$LIBX/build.sh" 'build_status true ""' ':'
# fetch: a failed run forgets the last successful fetch time
ctl fetch-status-forgets-last-ok fetch fail 'fetch/status-per-source ;fetch/term-records-interrupted ' \
	"$LIBX/fetch.sh" 'else ($p[$r[0]].last_ok_at // null) end' 'else null end'
ctl uitext-new-technical-string uitext fail 'uitext/real-app-no-new-violations ;uitext/stale-baseline-line-fails ' \
	"$VIEW/nodes.js" "_('Cancel')" "_('Cancel via rpcd')"
# ui0: the guard reads the shared modules (vpnpool/common.js) and po, counts a po msgid once
ctl uitext-views-only uitext fail 'uitext/positive-control-bad-fixture-caught ' \
	stand/tests/ui-text-guard.uc "walk(ROOT + '/files/www/luci-static/resources', '.js', [])" "walk(ROOT + '/files/www/luci-static/resources/view', '.js', [])"
# (ui4: the app's po has no technical word any more — the old Diagnostics labels are gone — so
#  counting a po msgid twice now shows only on the fixture)
ctl uitext-po-counted-twice uitext fail 'uitext/positive-control-bad-fixture-caught ' \
	stand/tests/ui-text-guard.uc '(catalog && seen_text[text])' '(false)'
# any baseline at all covers every violation (the gate test now runs on the fixture's baseline)
ctl uitext-baseline-covers-all uitext fail 'uitext/baseline-gates-new-violations ' 	stand/tests/ui-text-guard.uc 'for (let v in cur) if (!base[v]) {' 'for (let v in cur) if (!base[v] && !length(keys(base))) {'
ctl uitext-po-header-scanned uitext fail 'uitext/positive-control-bad-fixture-caught ' \
	stand/tests/ui-text-guard.uc "if (!(substr(cur, 0, 6) == 'msgstr' && id == ''))" 'if (true)'
ctl uitext-common-js-technical uitext fail 'uitext/real-app-no-new-violations ;uitext/stale-baseline-line-fails ' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "_('More actions')" "_('More actions (watchdog)')"
# ui0: po completeness (ui-i18n.sh check)
ctl i18n-untranslated ui-i18n fail 'FAIL untranslated ru: More actions' \
	package/luci-app-vpnpool/po/ru/vpnpool.po 'msgstr "Ещё действия"' 'msgstr ""'
# (ui1: "More actions" is in nodes.js too now, so its msgid stays; the needle is a msgid only common.js has)
ctl i18n-new-string-not-in-po ui-i18n fail 'FAIL pot-missing-msgid A new string;FAIL po-missing-msgid ru: A new string;FAIL pot-stale Are you sure?;FAIL po-obsolete ru: Are you sure?' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "_('Are you sure?')" "_('A new string')"
ctl i18n-placeholder-mismatch ui-i18n fail 'FAIL placeholders ru: "Connected to %s."' \
	package/luci-app-vpnpool/po/ru/vpnpool.po 'msgstr "Подключено к %s."' 'msgstr "Подключено к %d."'
ctl i18n-nonbmp-msgid ui-i18n fail 'FAIL nonbmp Are you sure? 📌;FAIL pot-missing-msgid Are you sure? 📌;FAIL po-missing-msgid ru: Are you sure? 📌;FAIL pot-stale Are you sure?;FAIL po-obsolete ru: Are you sure?' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "_('Are you sure?')" "_('Are you sure? 📌')"
# ui0 review: old views keep strings as text; backend codes all have a text; the translation is shipped
ctl ui-view-raw-E ui-unit fail 'FAIL - old views: E is common.E' \
	"$VIEW/dashboard.js" 'var E = common.E;' ''
ctl ui-view-modal-title-html ui-unit fail 'FAIL - old views: E is common.E' \
	"$VIEW/nodes.js" "ui.showModal(common.txt(_('Node link: %s').format(name)), [" "ui.showModal(_('Node link: %s').format(name), ["
ctl ui-backend-code-without-text ui-unit fail 'FAIL - every code the backend answers with has a human text' \
	"$RPCD" '|| { rep false no_nodes; exit 0; }' '|| { rep false brand_new_code; exit 0; }'
# ui3: the settings pages send only the changed fields (one set_config); the Telegram test uses
# what is typed (rpcd tg_test {token, chat, via_proxy}), the masked token = the saved one
ctl ui3-pages-every-field-sent ui-pages fail 'FAIL - routing: every field of the page;FAIL - settings: every field of the page;FAIL - routing: one Save;FAIL - settings: one Save;FAIL - routing: leaving the page;FAIL - settings: leaving the page;FAIL - settings: after a save;FAIL - routing and settings: Revert;FAIL - routing: Save with nothing changed;FAIL - settings: Save with nothing changed;FAIL - routing: after a refused save;FAIL - routing: a site found automatically while the page was open' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js 'if (has(cur, f) && cur[f] !== undefined && !same(cur[f], this.base[f])) out[f] = cur[f];' 'if (has(cur, f) && cur[f] !== undefined) out[f] = cur[f];'
ctl ui3-tg-test-ignores-typed rpcd fail 'rpcd/tg_test/typed-values-used ;rpcd/tg_test/empty-typed-token-is-none ;rpcd/tg_test/bad-typed-values-refused ;rpcd/tg_test/token-with-a-line-break-refused ;rpcd/tg_test/overlong-token-refused ;rpcd/tg_test/longest-token-accepted ;rpcd/tg_test/21-digit-bot-number-refused ' \
	"$RPCD" "*) tok=\$v ;; esac; fi" '*) : ;; esac; fi'
ctl ui3-tg-test-mask-as-token rpcd fail 'rpcd/tg_test/masked-token-means-the-saved-one ' \
	"$RPCD" "case \"\$v\" in *'***'*) ;; *) tok=\$v ;; esac" 'tok=$v'
ctl ui3-tg-test-multiline-token rpcd fail 'rpcd/tg_test/token-with-a-line-break-refused ' \
	"$RPCD" "{ [ \"\$(printf '%s' \"\$tok\" | wc -l)\" -eq 0 ] && printf" '{ printf'
ctl ui3-tg-send-ignores-override rpcd fail 'rpcd/tg_test/typed-values-used ;rpcd/tg_test/longest-token-accepted ' \
	"$LIBX/lib.sh" 'tok=${2:-$(uci -q get vpnpool.main.telegram_token)}' 'tok=$(uci -q get vpnpool.main.telegram_token)'
# review ui3: Revert puts the loaded data back (LuCI's parse rewrites it); a token is bounded
ctl ui3-pages-revert-from-rewritten-data ui-pages fail 'FAIL - routing: Save with nothing changed;FAIL - settings: Save with nothing changed;FAIL - routing: after a refused save;FAIL - routing and settings: Revert' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js '			restoreSnap(m, self.snaps[i]);' ''
ctl ui3-token-unbounded-api rpcd fail 'rpcd/set_config/overlong-token-refused ;rpcd/set_config/21-digit-bot-number-refused ' \
	"$LIBX/api.uc" 'chk_re(v, /^[0-9]{1,20}:[A-Za-z0-9_-]{1,100}$/, ' 'chk_re(v, /^[0-9]+:[A-Za-z0-9_-]+$/, '
ctl ui3-token-unbounded-tg-test rpcd fail 'rpcd/tg_test/overlong-token-refused ;rpcd/tg_test/21-digit-bot-number-refused ' \
	"$RPCD" "grep -Eqx '[0-9]{1,20}:[A-Za-z0-9_-]{1,100}'" "grep -Eqx '[0-9]+:[A-Za-z0-9_-]+'"
ctl ui-pages-feed-no-i18n ui-unit fail 'FAIL - packaging' \
	.github/workflows/pages.yml 'expected 3 .ipk' 'expected 2 .ipk'
ctl deploy-no-translation deploy-tar fail 'Russian translation missing' \
	scripts/deploy.sh '"$(hp "$tmp/usr/lib/lua/luci/i18n/vpnpool.ru.lmo")" >/dev/null; then :' '"$(hp "$tmp/x.lmo")" >/dev/null; then :'
ctl deploy-ships-demo-page deploy-tar fail 'stand-only page delivered' \
	scripts/deploy.sh "--exclude='./www/luci-static/resources/view/vpnpool/_*'" ''
ctl install-no-translation-small-flash engine fail 'engine/install-sh-ram-small-memory ' \
	install.sh '	install_i18n --nodeps' '	:'
# apk (25.12 image only: on opkg images this branch never runs): translation not added
case "${IMAGE:-}" in *25.12*)
ctl install-no-translation-apk engine fail 'engine/install-sh-awg1-flash ;engine/install-sh-ram-small-memory ' \
	install.sh '	if [ "$PM" = apk ]; then pm_add_files "$PKG_I18N" >/dev/null 2>&1' '	if [ "$PM" = apk ]; then true'
;; esac
ctl ui-smoke-status-broken ui-smoke fail 'ubus vpnpool.status via /ubus' \
	"$RPCD" '		/usr/libexec/vpnpool/status.sh' '		echo not-json'
# ui1 review: the excluded-ids list (auto_exclude), the probe job token
ctl ui1-gen-exclude-ignored build fail 'build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluded-only-favourite-then-the-others ;build/model-excluded-member-leaves-the-member-list ' \
	"$LIBX/generator.uc" 'if (length(excl_set)) {' 'if (false) {'
ctl ui1-gen-exclude-empties build fail 'build/model-excluding-every-node-is-ignored ' \
	"$LIBX/generator.uc" '	if (length(kept)) auto_tags = kept;' '	auto_tags = kept;'
ctl ui1-api-include-no-member rpcd fail 'rpcd/auto_include/ok ' \
	"$LIBX/api.uc" 'if (r && r.node && length(filter(mem, (x) => live[x]))' 'if (false && length(filter(mem, (x) => live[x]))'
ctl ui1-api-include-stale-member rpcd fail 'rpcd/auto_include/stale-member-list-left-alone ;rpcd/auto_include/deferred-only-member-list-left-alone ' \
	"$LIBX/api.uc" 'if (r && r.node && length(filter(mem, (x) => live[x]))' 'if (r && r.node && length(mem)'
ctl ui1-api-exclude-keeps-kept rpcd fail 'rpcd/auto_exclude/ok ' \
	"$LIBX/api.uc" "		ch = list_del(u, 'keep_auto', [ r.id ]) || ch;" ''
ctl ui1-probe-no-job rpcd fail 'rpcd/probe_source/ok ' \
	"$RPCD" '". + {job:\$j}"' '"."'
ctl ui1-status-no-excluded rpcd fail 'rpcd/status/ok ' \
	"$LIBX/status.uc" '	auto_exclude_ids: excl_ids,' ''
# ui1 review 2: deferred nodes do not make a member list count; status filters the excluded ids;
# exclusions come before "favourites only" in the generator
ctl ui1-api-include-deferred rpcd fail 'rpcd/auto_include/deferred-only-member-list-left-alone ' \
	"$LIBX/api.uc" 'if (n.id && !n._deferred) live[n.id] = true;' 'if (n.id) live[n.id] = true;'
ctl ui1-status-excl-unfiltered status fail 'status/favorites-hidden-preferred ' \
	"$LIBX/status.uc" 'let excl_ids = filter(as_list(M.auto_exclude, true), is_id);' 'let excl_ids = as_list(M.auto_exclude, true);'
ctl ui1-status-excl-from-members status fail 'status/favorites-hidden-preferred ' \
	"$LIBX/status.uc" 'let excl_ids = filter(as_list(M.auto_exclude, true), is_id);' 'let excl_ids = filter(as_list(M.auto_member, true), is_id);'
ctl ui1-gen-exclude-after-favourites build fail 'build/model-excluded-only-favourite-then-the-others ' \
	"$LIBX/generator.uc" 'if (length(excl_set)) {' 'if (false) {' \
	"$LIBX/generator.uc" '	if (length(only)) auto_tags = only;' '	if (length(only)) auto_tags = only; } if (true) { let kept2 = filter(auto_tags, (t) => !excl_set[t]); if (length(kept2)) auto_tags = kept2;'
# ui1: the Nodes tab — 2.0 methods only, reasons of a pasted line, the tabs of 2.0
ctl ui1-nodes-connect-legacy ui-nodes fail 'FAIL - "Connect" is the soft choice;FAIL - only the 2.0 methods' \
	"$VIEW/nodes.js" "common.call('connect', { id: id }" "common.call('select', { id: id }"
ctl ui1-nodes-raw-E ui-nodes fail 'FAIL - groups by source, state words of every kind of card, no innerHTML' \
	"$VIEW/nodes.js" 'var E = common.E;' 'var E0 = common.E;'
ctl ui1-reason-without-text ui-unit fail 'FAIL - every reason the backend gives for a pasted line has a human text' \
	"$LIBX/parser.uc" "return 'bad_uuid';" "return 'bad_brand_new_reason';"
ctl ui1-sources-tab-back ui-smoke fail 'menu: Nodes tab / no Sources tab' \
	package/luci-app-vpnpool/files/usr/share/luci/menu.d/luci-app-vpnpool.json '"admin/services/vpnpool/nodes": {' '"admin/services/vpnpool/sources": { "title": "Sources", "order": 9, "action": { "type": "view", "path": "vpnpool/dashboard" } }, "admin/services/vpnpool/nodes": {'
# ui2: what the Overview / Nodes read from the daemon's background checks
ctl ui2-nodecheck-no-host daemon fail 'daemon/nodecheck-strikes-say-when-and-which-host ' \
	"$LIBX/nodecheck.sh" '[ "$ok" = 1 ] || failed="${failed:+$failed,}${p#*|}"' ':'
ctl ui2-tunnel-not-written daemon fail 'daemon/tunnel-state-for-the-overview ' \
	"$LIBX/vpnpoold" '	[ "$1" = "$TUNNEL_STATE" ] && return 0' '	return 0'
ctl ui2-tunnel-every-tick daemon fail 'daemon/tunnel-state-for-the-overview ' \
	"$LIBX/vpnpoold" '	[ "$1" = "$TUNNEL_STATE" ] && return 0' '	:'
ctl ui2-exit-every-tick daemon fail 'daemon/exit-lookup-only-when-needed ' \
	"$LIBX/vpnpoold" '		[ "$age" -lt "$EXIT_RETRY" ] && return 0' '		:'
ctl ui2-exit-no-min-interval daemon fail 'daemon/exit-lookup-only-when-needed ' \
	"$LIBX/vpnpoold" '	[ "$age" -lt "$EXIT_MIN" ] && return 0' '	:'
ctl ui2-exit-reread-every-tick daemon fail 'daemon/exit-lookup-only-when-needed ' \
	"$LIBX/vpnpoold" '		if [ -z "$EXIT_SEEN" ]; then' '		if true; then'
ctl ui2-exit-without-tunnel daemon fail 'daemon/exit-lookup-only-when-needed ' \
	"$LIBX/vpnpoold" '	[ -n "$1" ] && [ "$WD_HEALTHY" = 1 ] || return 0' '	[ -n "$1" ] || return 0'
ctl ui2-exitip-direct daemon fail 'daemon/exitip-first-address-through-the-tunnel ;daemon/exitip-nothing-answers-says-so ' \
	"$LIBX/lib.sh" 'j=$(curl -s -m 7 --proxy "socks5h://127.0.0.1:$1" "$url" 2>/dev/null)' 'j=$(curl -s -m 7 "$url" 2>/dev/null)'
ctl ui2-exitip-junk-address daemon fail 'daemon/exitip-first-address-through-the-tunnel ' \
	"$LIBX/lib.sh" '		case "$ip" in (*[!0-9a-fA-F:.]*|'"''"') continue ;; esac' '		:' \
	"$LIBX/lib.sh" '		case "$ip" in (*[.:]*) ;; (*) continue ;; esac' '		:'
ctl ui2-exitip-word-address daemon fail 'daemon/exitip-first-address-through-the-tunnel ' \
	"$LIBX/lib.sh" '		case "$ip" in (*[.:]*) ;; (*) continue ;; esac' '		:'
ctl ui2-exit-answer-of-another-node daemon fail 'daemon/exit-lookup-only-when-needed ' \
	"$LIBX/vpnpoold" ' && grep -qF "\"node\":\"$1\"" "$SB_DATA/exit.json" 2>/dev/null' ''
ctl ui2-status-exit-other-node status fail 'status/exit-of-another-node-not-shown ' \
	"$LIBX/status.uc" "if (type(exj) == 'object' && length(now_tag) && exj.node == now_tag)" "if (type(exj) == 'object' && length(now_tag))"
ctl ui2-status-exit-failure-hidden status fail 'status/failed-exit-lookup-and-unknown-tunnel-state ' \
	"$LIBX/status.uc" '		: { ok: false, ip: null, country: null, node: exj.node, at: exj.at ?? null };' '		: null;'
# one list of the IP-echo services (lib.sh): a change there reaches rpcd conntest too
ctl ui2-exit-services-two-lists rpcd fail 'rpcd/conntest/ok ' \
	"$LIBX/lib.sh" '"https://ifconfig.co/json" "https://ipinfo.io/json" "https://api.ip.sb/geoip"' '"https://ifconfig.invalid/json" "https://ipinfo.io/json" "https://api.ip.sb/geoip"'
ctl ui2-status-tunnel-stale status fail 'status/daemon-down-no-tunnel-no-exit ' \
	"$LIBX/status.uc" "let tf = running ? split(" "let tf = true ? split("
ctl ui2-overview-legacy-call ui-overview fail 'FAIL - "Connected to X" and "Back to automatic choice";FAIL - only the 2.0 methods' \
	"$VIEW/dashboard.js" "common.call('auto_select'" "common.call('set_preferred'"
ctl ui2-overview-tunnel-ignored ui-overview fail 'FAIL - state in words for every state the daemon reports' \
	"$VIEW/dashboard.js" "if (tn === 'down') return" "if (false) return"
ctl ui2-overview-exit-dead-tunnel ui-overview fail 'FAIL - exit: only while the tunnel works' \
	"$VIEW/dashboard.js" 'exit: !(live && tunnelUp && tag) ? null' 'exit: !(live && tag) ? null'
ctl ui2-overview-pause-on ui-overview fail 'FAIL - a pause from Telegram;FAIL - state in words for every state the daemon reports' \
	"$VIEW/dashboard.js" 'function vpnOn(st) { return !!(st && st.enabled && !st.paused); }' 'function vpnOn(st) { return !!(st && st.enabled); }'
ctl ui2-failed-sites-mixed ui-overview fail 'FAIL - alerts in words' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js 'else { exact = false; (conf = conf || checkSites(st)).forEach(add); }' 'else exact = false;'
ctl ui2-overview-pause-stopped ui-overview fail 'FAIL - state in words for every state the daemon reports' \
	"$VIEW/dashboard.js" "d: st.paused ? _('Press" "d: false ? _('Press"
ctl ui2-nodes-check-words-dropped ui-nodes fail 'FAIL - a node that fails the check: which site' \
	"$VIEW/nodes.js" 'state = deadText(st, n);' 'state = deadText(st);'
ctl ui2-ci-overview-dropped ui-unit fail 'FAIL - packaging: translation in installer, feeds and CI' \
	.github/workflows/build.yml '          node stand/tests/ui-overview.test.js --negative 2>&1 | tee ui-overview-neg.log' '          true'
ctl ui2-status-check-dropped status fail 'status/tunnel-exit-and-node-checks ;status/failed-exit-lookup-and-unknown-tunnel-state ' \
	"$LIBX/status.uc" 'check: id ? (ncheck[id] ?? null) : null,' 'check: null,'
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
# the limit cases' CPU bound: a decoder that burns ~6 CPU s on big input must go red
ctl awgdecode-slow-on-big-input awgdecode fail 'awgdecode/input-over-256k-refused ;awgdecode/links-100k-refused ;awgdecode/links-40k-capped ' 	"$LIBX/awgdecode.uc" "	if (text == null) text = stdin.read(MAX_IN + 1) ?? '';" "	if (text == null) text = stdin.read(MAX_IN + 1) ?? ''; if (length(text) > 200000) { let t0 = time(); while (time() - t0 < 7); }"
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

# ---- review fixes (REVIEW_stage3) ----
# V1: backup packs every file of awg/ -> its own archive is refused by restore
ctl review-v1-backup-ignores-rule rpcd fail 'rpcd/backup/members-by-the-restore-rule ;rpcd/restore/own-backup-round-trip ' \
	"$LIBX/lib.sh" 'printf '"'"'%s\n'"'"' "$rel" | grep -Eq "$MEMBER_RE"; then' 'true; then'
# V2: restore / import without the value check
ctl review-v2-restore-values-unchecked rpcd fail 'rpcd/restore/bad-values-refused ;rpcd/import/bad-values-refused ' \
	"$RPCD" '		CC=$(ucode "$API" check_config "$D/root/etc/config" "$D/save" 2>/dev/null)' "		CC='{\"ok\":true}'"
ctl review-v2-import-values-unchecked rpcd fail 'rpcd/import/bad-values-refused ' \
	"$RPCD" '		CC=$(ucode "$API" check_config "$D" "$D/save" 2>/dev/null)' "		CC='{\"ok\":true}'"
# V3: no size/count check on the listing -> the archive is unpacked first
ctl review-v3-no-precheck rpcd fail 'rpcd/restore/oversized-content-refused ' \
	"$RPCD" '			      else if (n > maxn || sum > maxb) print "too_large"; else print "ok" }' '			      else print "ok" }'
# M1: member types not checked (listing and disk) -> symlink, hardlink, device, fifo get in
ctl review-m1-types-unchecked rpcd fail 'rpcd/restore/member-type-symlink-refused ;rpcd/restore/member-type-hardlink-refused ;rpcd/restore/member-type-device-refused ;rpcd/restore/member-type-fifo-refused ' \
	"$RPCD" '			  if (NF != 6 || (t != "-" && t != "d") || $6 !~ re) { bad = "invalid_archive"; exit }' '			  if ($6 !~ re) { bad = "invalid_archive"; exit }' \
	"$RPCD" '		[ -z "$(find "$D/root" ! -type f ! -type d 2>/dev/null)" ] || bad invalid_archive' '		:'
# M2: the path checked as written, not after resolving symlinks / ".."
ctl review-m2-path-not-resolved rpcd fail 'rpcd/restore/path-escaping-tmp-refused-_tmp_vpnpool_lnk_up_tgz_;rpcd/restore/path-escaping-tmp-refused-_tmp____etc_vpnpool_up_tgz_' \
	"$RPCD" '			real=$(readlink -f "$src" 2>/dev/null)' '			real=$src'
# V4: no rollback of the moved files / no verified copy before
ctl review-v4-no-rollback rpcd fail 'rpcd/restore/failed-step-rolls-back ' \
	"$RPCD" '			while IFS= read -r rel; do mv -f "$OLD/$rel" "/etc/vpnpool/$rel" || rb=0; done < "$OLD/.moved"' '			:'
ctl review-v4-copy-before-unchecked rpcd fail 'rpcd/restore/no-copy-before-no-replace ' \
	"$RPCD" "			|| { rm -f \"\$PRE\"; bad write_failed '{\"step\":\"pre_copy\"}'; }" '			|| :'
# V5: no trap -> a killed build / fetch leaves the previous result
ctl review-v5-build-no-trap build fail 'build/term-writes-interrupted ' \
	"$LIBX/build.sh" 'trap on_signal INT TERM HUP' ':'
ctl review-v5-fetch-no-trap fetch fail 'fetch/term-records-interrupted ' \
	"$LIBX/fetch.sh" 'trap on_signal INT TERM HUP' ':'
# V6: a mask that does not resolve is used as the address; masks looked up in every list
ctl review-v6-mask-used-as-url rpcd fail 'rpcd/probe_source/unknown-mask-refused ' \
	"$RPCD" "	case \"\$2\" in *'***'*) rep false not_found; exit 0 ;; esac" '	:'
ctl review-v6-mask-any-list rpcd fail 'rpcd/del_source/mask-resolved-in-pick-subscriptions-only ;rpcd/add_sub/mask-literal-refused ' \
	"$RPCD" '		need_url pick "$(printf' "		need_url '*' \"\$(printf"
ctl review-v6-is-url-takes-mask rpcd fail 'rpcd/add_sub/mask-literal-refused ' \
	"$LIBX/api.uc" "	if (index(s, '***') >= 0) return false;" '	;'
# V7: add stores a URL without the trial download; add_node takes a URL
ctl review-v7-add-no-trial rpcd fail 'rpcd/add/url-without-nodes-not-stored ;rpcd/add_sub/bad-input ;rpcd/add_node/url-refused ' \
	"$LIBX/api.uc" '			if (pr.n < 1) {' '			if (false) {'
ctl review-v7-add_node-takes-url rpcd fail 'rpcd/add_node/url-refused ' \
	"$RPCD" "			http://*|https://*) rep false invalid n/a '{\"errors\":{\"link\":\"bad_value\"}}'; exit 0 ;;" '			NEVER-MATCHES) ;;'
# M3: running = "some command line mentions vpnpoold"
ctl review-m3-running-by-mention status fail 'status/running-not-fooled-by-a-mention ' \
	"$LIBX/status.uc" "let running = match(dpid, /^[0-9]+\$/) ? runs_script(argv_of(dpid), 'usr/libexec/vpnpool/vpnpoold') : false;" \
	"let running = false; for (let c in (lsdir('/proc') ?? [])) { let a = argv_of(c); if (a && index(join(' ', a), '/usr/libexec/vpnpool/vpnpoold') >= 0) running = true; }"
# M4: a fixed temp file name, left behind (overlapping polls share it)
# (stage 6) control review-m4-shared-temp retired: status writes no temp file any more (the archive parse is gone); uniq() keeps its own case (awgb2-temp-names-time-rand)
# M5: cache key without the inode / without the parser's signature
# (stage 6) control review-m5-no-inode retired: the parse cache and file_sig are gone
# (stage 6) control review-m5-no-parser-sig retired: the parse cache is gone
# M6: set_url "" refused again
ctl review-m6-empty-url-refused rpcd fail 'rpcd/set_url/empty-clears ' \
	"$LIBX/api.uc" "		if (url == '') {" '		if (false) {'
# M7: the missing section created with the wrong type
ctl review-m7-section-type rpcd fail 'rpcd/set_config/creates-main-of-type-vpnpool ' \
	"$LIBX/api.uc" "[ 'main', 'vpnpool' ]" "[ 'main', 'main' ]"
# M8: the build log subtracts the dropped nodes twice
ctl review-m8-log-double-subtract build fail 'build/log-counts-the-final-pool ' \
	"$LIBX/build.sh" 'log "build: ok ($CNT nodes; dropped $dropped unsupported)"' 'log "build: ok ($((CNT - dropped)) nodes; dropped $dropped unsupported)"'
# M9: a crontab failure after the write answers "nothing saved"
ctl review-m9-sched-false-failure rpcd fail 'rpcd/set_schedule/cron-failure-is-a-warning ' \
	"$RPCD" "			res=\$(printf '%s' \"\$res\" | jq -c --arg m \"sched.sh exit \$rc\" '. + {warning:\"schedule_failed\", message:\$m}')" '			rep false script_failed; return'
# test gap: probe sources in status not masked
ctl review-status-sources-unmasked status fail 'status/subscription-urls-masked ;status/source-urls-masked ' \
	"$LIBX/status.uc" "	else { e.kind = 'pick'; push(source_masked, e.url); }" "	else { e.kind = 'pick'; push(source_masked, s.url); }"
# ================= stage 4b: AmneziaWG inside vpnpool (pack awg-b) =================
# parser: the AWG 3.1 table and the own value checks
ctl awgb-hpk-dropped parser fail 'parser/awg3-conf-fields ' \
	"$LIBX/parser.uc" '		ep.header_protection_key = hk;' '		;'
ctl awgb-range-not-normalised parser fail 'parser/awg-normalised-values ' \
	"$LIBX/parser.uc" "	return (hi == lo && m[3] == null) ? ('' + lo) : (lo + '-' + hi);" '	return v;'
ctl awgb-no-h-overlap-check parser fail 'parser/awg-check-h-overlap ' \
	"$LIBX/parser.uc" 'if (hs[i][0] <= hs[j][1] && hs[j][0] <= hs[i][1]) return' 'if (false) return'
ctl awgb-no-i-chain-check parser fail 'parser/awg-check-i-unknown-tag ;parser/awg-check-i-unclosed ;parser/awg-check-i-odd-hex ' \
	"$LIBX/parser.uc" "		if (!obf_chain_ok(iface[k])) return { err: 'awg_bad_value', field: k };" '		;'
ctl awgb-no-hpk-s12-check parser fail 'parser/awg-check-hpk-s4-below-12 ' \
	"$LIBX/parser.uc" "if ((ep['s' + i] ?? 0) < 12) return" 'if (false) return'
ctl awgb-key-any-length parser fail 'parser/awg-check-hpk-not-32-bytes ;parser/awg-check-private-key-bad ' \
	"$LIBX/parser.uc" 'return match(s, /^[A-Za-z0-9+\/]{43}=$/) ? s : null;' 'return length(s) ? s : null;'
ctl awgb-unknown-param-dropped parser fail 'parser/awg-check-unknown-param ' \
	"$LIBX/parser.uc" '!AWG_BOOL[k]) { if (unknown == null) unknown = k; }' '!AWG_BOOL[k]) { ; }'
ctl awgb-multi-peer-kept parser fail 'parser/awg-multi-peer-refused ;parser/awg-multi-peer-reason ' \
	"$LIBX/parser.uc" "	if (npeer > 1) return { err: 'awg_multi_peer' };" '	;'
ctl awgb-wireguard-as-awg parser fail 'parser/wireguard-plain-conf ' \
	"$LIBX/parser.uc" "	ep.type = is_awg ? 'awg' : 'wireguard';" "	ep.type = 'awg';"
ctl awgb-keepalive-range-not-awg parser fail 'parser/awg-keepalive-range-is-awg ' \
	"$LIBX/parser.uc" "		if (index(ka, '-') >= 0) is_awg = true;            // a keepalive range is AWG 3.x" '		;'
ctl awgb-id-not-of-the-key parser fail 'parser/awg-id-is-sha256-of-private-key ' \
	"$LIBX/parser.uc" '	return substr(sha256_hex(k), 0, 12);' "	return substr(sha256_hex(k + 'x'), 0, 12);"
ctl awgb-sha256-constant parser fail 'parser/awg-id-is-sha256-of-private-key ' \
	"$LIBX/parser.uc" '	0x428a2f98, 0x71374491,' '	0x428a2f99, 0x71374491,'
ctl awgb-dedup-by-name parser fail 'parser/awg-name-comment-and-identity ;parser/awg-id-is-sha256-of-private-key ' \
	"$LIBX/parser.uc" '	if (is_awg) { if (length(ob.private_key)) id = awg_id(ob.private_key); }' '	if (is_awg) { if (length(ob.private_key)) id = awg_id(ob.private_key + base); }'
ctl awgb-name-comment-ignored parser fail 'parser/awg-name-comment-and-identity ' \
	"$LIBX/parser.uc" '	ep.tag = name ?? hp_label(hp.host, port);' '	ep.tag = hp_label(hp.host, port);'
# ucode regex: \s inside [...] is the letter s
ctl awgb-looks-base64-bs-s parser fail 'parser/base64-blob-with-line-breaks ' \
	"$LIBX/parser.uc" 'return match(s, /^[A-Za-z0-9+\/=_[:space:]-]+$/) ? true : false;' 'return match(s, /^[A-Za-z0-9+\/=_\s-]+$/) ? true : false;'
ctl awgb-uuid-bs-s parser fail 'parser/vless-id-with-letter-s ' \
	"$LIBX/parser.uc" 'if (!length(uuid) || match(uuid, /[[:space:]:]/)) return' 'if (!length(uuid) || match(uuid, /[\s:]/)) return'
# engine choice + cache
ctl awgb-engine-never-chosen awg fail 'awg/select-engine-awg-nodes ;awg/select-stock-path-configured-is-automatic ;awg/build-engine-awg-in-config ;awg/status-engine-block ;awg/fork-stock-our-engine-wins ;awg/no-private-key-in-the-engine-log ;awg/chain-amnezia5-every-field ;awg/chain-amnezia5-runs ;awg/guard-no-default-route-is-not-the-node ;awg/guard-node-works-once-the-route-is-back ;awg/guard-node-dies-at-start-set-aside ;awg/daemon-finds-the-engine-process ;awg/guard-mark-expires ;awg/guard-mark-ends-when-the-node-changes ;awg/guard-rolls-back-with-the-binary-of-the-config ;awg/guard-rollback-without-a-binary-record ;awg/guard-limit-two-repairs ;awg/add-with-engine-no-warning ' \
	"$LIBX/common.uc" '		if (ac.present && ac.awg) cap = ac;' '		if (false) cap = ac;'
ctl awgb-cap-not-cached awg fail 'awg/engine-cap-cached-by-mtime-size ' \
	"$LIBX/common.uc" "	if (!force && type(c) == 'object' && c.sig == sig && c.awg31 != null) return c;" '	;'
# build: deferred nodes, the binary of the check
ctl awgb-no-deferral awg fail 'awg/build-no-engine-awg-deferred ;awg/status-lists-deferred-node ' \
	"$LIBX/build.sh" '(if ($eng.reason // null) != null and $n.type == "awg" then {reason: $eng.reason}' '(if false then {reason: $eng.reason}'
ctl awgb-check-with-stock awg fail 'awg/build-engine-awg-in-config ;awg/status-engine-block ;awg/fork-stock-31-nodes-deferred-not-cut ;awg/fork-stock-our-engine-wins ;awg/no-private-key-in-the-engine-log ;awg/chain-amnezia5-every-field ;awg/chain-amnezia5-runs ;awg/guard-no-default-route-is-not-the-node ;awg/guard-node-works-once-the-route-is-back ;awg/guard-port-in-use-keeps-the-change ;awg/guard-node-dies-at-start-set-aside ;awg/daemon-finds-the-engine-process ;awg/guard-mark-expires ;awg/guard-mark-ends-when-the-node-changes ;awg/guard-rolls-back-with-the-binary-of-the-config ;awg/guard-rollback-without-a-binary-record ;awg/guard-limit-two-repairs ' \
	"$LIBX/build.sh" 'while ! "$SB_BIN" check -c "$SB_CONF.new"' 'while ! sing-box check -c "$SB_CONF.new"'
ctl awgb-status-no-deferred awg fail 'awg/status-lists-deferred-node ;awg/fork-stock-31-nodes-deferred-not-cut ;awg/guard-node-dies-at-start-set-aside ' \
	"$LIBX/status.uc" 'for (let d in deferred) {' 'for (let d in []) {'
# generator by version (checked by RUNNING both engines)
ctl awgb-generator-no-version-gate awg fail 'awg/generator-1.14-form ;awg/generator-1.14-runs-on-engine ;awg/generator-1.14-form-refused-by-1.12 ' \
	"$LIBX/generator.uc" 'let SB_GE_114 = sbv ? (int(sbv[1]) > 1 || (int(sbv[1]) == 1 && int(sbv[2]) >= 14)) : false;' 'let SB_GE_114 = false;'
# (every config with rule-sets then dies at start: the chain and the guard cases go red too)
ctl awgb-http-client-detour-direct awg fail 'awg/generator-1.14-form ;awg/generator-1.14-runs-on-engine ;awg/chain-amnezia5-runs ;awg/guard-node-works-once-the-route-is-back ;awg/guard-port-in-use-keeps-the-change ;awg/guard-node-dies-at-start-set-aside ;awg/daemon-finds-the-engine-process ;awg/guard-rolls-back-with-the-binary-of-the-config ;awg/guard-rollback-without-a-binary-record ' \
	"$LIBX/generator.uc" '	config.http_clients = [ { tag: HTTP_CLIENT_TAG } ];' "	config.http_clients = [ { tag: HTTP_CLIENT_TAG, detour: 'direct' } ];"
# the daemon: the binary it runs, the process it finds, the start guard
ctl awgb-daemon-runs-stock awg fail 'awg/guard-no-default-route-is-not-the-node ;awg/guard-node-works-once-the-route-is-back ;awg/guard-port-in-use-keeps-the-change ;awg/guard-node-dies-at-start-set-aside ;awg/daemon-finds-the-engine-process ;awg/guard-mark-expires ;awg/guard-rolls-back-with-the-binary-of-the-config ;awg/guard-rollback-without-a-binary-record ;awg/guard-limit-two-repairs ' \
	"$LIBX/vpnpoold" '	"$(sb_bin)" run -c "$SB_CONF"' '	sing-box run -c "$SB_CONF"'
ctl awgb-pids-stock-name-only awg fail 'awg/daemon-finds-the-engine-process ;awg/guard-rolls-back-with-the-binary-of-the-config ' \
	"$LIBX/lib.sh" '{ pgrep -f "sing-box[^ ]* run -c $SB_CONF" 2>/dev/null;' '{ pgrep -f "sing-box run -c $SB_CONF" 2>/dev/null;'
ctl awgb-guard-no-node-exclusion awg fail 'awg/guard-node-dies-at-start-set-aside ;awg/daemon-finds-the-engine-process ;awg/guard-mark-expires ;awg/guard-limit-two-repairs ' \
	"$LIBX/vpnpoold" '		if [ -n "$node" ] && mark_bad "$node" "$fatal"; then' '		if false; then'
ctl awgb-guard-no-rollback awg fail 'awg/guard-rolls-back-with-the-binary-of-the-config ;awg/guard-rollback-without-a-binary-record ' \
	"$LIBX/vpnpoold" '		if [ -s "$SB_CONF.prev" ] && ! cmp -s "$SB_CONF" "$SB_CONF.prev"; then' '		if false; then'
ctl awgb-guard-no-limit awg fail 'awg/guard-limit-two-repairs ' \
	"$LIBX/vpnpoold" '		if [ "$n" -gt "$GUARD_MAX" ]; then' '		if [ "$n" -gt 99 ]; then'
ctl awgb-mark-ignores-node-config awg fail 'awg/guard-mark-ends-when-the-node-changes ' \
	"$LIBX/build.sh" '$m.cfg == ($n | del(.tag, .id, ._src) | tojson)' 'true'
# api / rpcd
ctl awgb-analyze-no-dup awg fail 'awg/add-same-node-again-dup ' \
	"$LIBX/api.uc" "	if (awg_known_ids()[r.id] || stat(AWG_DIR + '/' + r.id + '.conf')) {" '	if (false) {'
ctl awgb-name-not-cleaned awg fail 'awg/add-name-cannot-inject-lines ' \
	"$LIBX/api.uc" "	s = trim(replace(s, /[[:cntrl:]]+/g, ' '));" '	s = trim(s);'
ctl awgb-add-no-warning awg fail 'awg/add-vpn-link-no-engine-deferred ;awg/import-nodes-vpn-link ' \
	"$LIBX/api.uc" '	if (added > 0 && ADD_WARN[warning]) res.warning = ADD_WARN[warning].warning;' '	;'
ctl awgb-no-wrapped-link awg fail 'awg/analyze-vpn-link-wrapped-with-caption ' \
	"$LIBX/api.uc" '		if (tok && !nowrap && prev_len >= WRAP_MIN' '		if (false && tok && !nowrap && prev_len >= WRAP_MIN'
ctl awgb-delete-by-id-off awg fail 'awg/delete-by-id ;awg/delete-deferred-by-tag ' \
	"$LIBX/api.uc" "	if ((n && (n.type == 'awg' || n.type == 'wireguard') && src == 'awg') || (!n && r.awg_file)) {" '	if (false) {'
# ui: every new reply code needs its text
ctl awgb-ui-no-engine-text ui-unit fail 'every code the backend answers with has a human text' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "	engine_missing:     _('Saved." "	engine_missing_x:   _('Saved."

# --- review of awg-b: the guard tells the router from the node, marks expire, rollback keeps the
#     binary, our engine over a stock AWG fork, 3.1 probe, tools keys, keys out of logs / 0600
ctl awgb2-env-treated-as-node awg fail 'awg/guard-no-default-route-is-not-the-node ;awg/guard-port-in-use-keeps-the-change ' \
	"$LIBX/vpnpoold" '		if [ "$cls" = env ]; then' '		if false; then'
ctl awgb2-mark-never-expires awg fail 'awg/guard-mark-expires ' \
	"$LIBX/build.sh" '		        and (($m.at // 0) + $ttl) > $now' '		        and true'
ctl awgb2-rollback-without-binary awg fail 'awg/guard-rolls-back-with-the-binary-of-the-config ;awg/guard-rollback-without-a-binary-record ' \
	"$LIBX/vpnpoold" 'PREV_FILES="$SB_BIN_FILE $SB_DATA/nodes.json $SB_CONF"' 'PREV_FILES="$SB_DATA/nodes.json $SB_CONF"'
ctl awgb2-sb-bin-ignores-config awg fail 'awg/guard-rollback-without-a-binary-record ' \
	"$LIBX/lib.sh" '	if [ -s "$SB_CONF" ] && jq -e' '	if false && jq -e'
ctl awgb2-tag-cut-at-bracket awg fail 'awg/guard-node-dies-at-start-set-aside ;awg/daemon-finds-the-engine-process ;awg/guard-mark-expires ' \
	"$LIBX/vpnpoold" '| . as $n | select($f | contains("[" + $n.tag + "]:"))]' '| . as $n | select($f | contains("[" + ($n.tag | split(" ")[0]) + "]:"))]'
ctl awgb2-fork-wins-over-engine awg fail 'awg/fork-stock-our-engine-wins ' \
	"$LIBX/common.uc" '		if (ac.present && ac.awg) cap = ac;' '		if (ac.present && ac.awg && !cap.awg) cap = ac;'
ctl awgb2-probe31-is-probe20 awg fail 'awg/fork-stock-probe ;awg/fork-stock-31-nodes-deferred-not-cut ;awg/fork-stock-analyze-says-31 ' \
	"$LIBX/common.uc" '		if (awg && writefile(probe, AWG_PROBE31) != null)' '		if (awg && writefile(probe, AWG_PROBE) != null)'
ctl awgb2-no-31-deferral awg fail 'awg/fork-stock-31-nodes-deferred-not-cut ' \
	"$LIBX/build.sh" '		   elif $n31 and ($eng.awg31 // false) != true then {reason: "engine_no_awg31"}' '		   elif false then {reason: "engine_no_awg31"}'
ctl awgb2-tools-key-refused parser fail 'parser/awg-ignored-keys-and-line-comments ' \
	"$LIBX/parser.uc" '			if (WG_IGNORED_P[k]) { if (!(k in ignored)) push(ignored, k); continue; }' '			;'
ctl awgb2-line-comment-kept parser fail 'parser/awg-ignored-keys-and-line-comments ' \
	"$LIBX/parser.uc" '		if (cm >= 0) v = trim(substr(v, 0, cm));' '		;'
ctl awgb2-jc-uint32 parser fail 'parser/awg-check-jc-over-int32 ' \
	"$LIBX/parser.uc" "const AWG_INT = { jc: [ 'jc', 2147483647 ]," "const AWG_INT = { jc: [ 'jc', 4294967295 ],"
ctl awgb2-debug-log-with-keys awg fail 'awg/no-private-key-in-the-engine-log ' \
	"$LIBX/generator.uc" "if (length(endpoints) && (log_level == 'trace' || log_level == 'debug'))" 'if (false)'
ctl awgb2-no-umask awg fail 'awg/files-with-keys-are-0600 ' \
	"$LIBX/build.sh" 'umask 077' ':'
ctl awgb2-conf-not-0600 awg fail 'awg/add-file-is-0600 ' \
	"$LIBX/api.uc" '	chmod(path, 0600);' '	;'
ctl awgb2-unreadable-not-listed awg fail 'awg/unreadable-file-listed ' \
	"$LIBX/status.uc" "	unreadable: read_json(SB + '/awg_unreadable.json', [])," '	unreadable: [],'
ctl awgb2-no-delete-by-file awg fail 'awg/unreadable-file-deleted-by-name ' \
	"$RPCD" '		if [ -n "$afile" ] && [ -z "$tag" ] && [ -z "$aid" ]; then' '		if false; then'
ctl awgb2-temp-names-time-rand status fail 'status/temp-names-unique-across-processes ' \
	"$LIBX/common.uc" "	return length(u) ? u : sprintf('%d.%d', time(), rand());" "	return sprintf('%d.%d', time(), rand());"
ctl awgb2-ui-no-awg31-text ui-unit fail 'every code the backend answers with has a human text' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "	engine_no_awg31:    _('Saved." "	engine_no_awg31_x:  _('Saved."
# ================= stage 6: the data model (pack stage6, ROADMAP 9) =================
# parser: hidden ids, picks, the source index, one id = one node
ctl s6-parser-hide-ignored parser fail 'parser/hide-skips-the-id-in-every-input ' \
	"$LIBX/parser.uc" '	let hidden = !!(id && HIDE && HIDE[id]);' '	let hidden = false;'
ctl s6-parser-pick-ignored parser fail 'parser/pick-only-for-the-next-file-before-dedup ;parser/pick-skips-a-node-without-id ' \
	"$LIBX/parser.uc" '		PICK = f.pick;' '		PICK = null;'
ctl s6-parser-src-wrong parser fail 'parser/pick-only-for-the-next-file-before-dedup ' \
	"$LIBX/parser.uc" '	if (WITH_SRC) ob._src = cur_src;' '	if (WITH_SRC) ob._src = 0;'
ctl s6-parser-dedup-by-name parser fail 'parser/dedup-same-config-other-name-is-one-node ;parser/dedup-users-file-first-keeps-users-name ;parser/id-unique-in-output ;parser/awg-name-comment-and-identity ' \
	"$LIBX/parser.uc" "	let dk = id ?? ('noid:' + config_key(ob));" "	let dk = base + '\x1f' + (id ?? config_key(ob));"
# build: the inputs of the pool
ctl s6-build-hide-not-passed build fail 'build/model-inputs-sources-and-filters ;build/model-hidden-listed-with-name ;build/model-favourites-only-never-empties-the-pool ;build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluding-every-node-is-ignored ;build/model-excluded-only-favourite-then-the-others ' \
	"$LIBX/build.sh" 'FILES=""; PARGS="--hide $SB_DATA/hidden.ids";' 'FILES=""; PARGS="";'
ctl s6-build-pick-not-passed build fail 'build/model-inputs-sources-and-filters ;build/model-favourites-only-never-empties-the-pool ;build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluding-every-node-is-ignored ;build/model-excluded-only-favourite-then-the-others ' \
	"$LIBX/build.sh" '	if [ -n "${3:-}" ]; then PARGS="$PARGS --pick $3 $1"; else PARGS="$PARGS $1"; fi' '	PARGS="$PARGS $1"'
ctl s6-build-disabled-sub-used build fail 'build/model-inputs-sources-and-filters ;build/model-favourites-only-never-empties-the-pool ;build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluding-every-node-is-ignored ;build/model-excluded-only-favourite-then-the-others ' \
	"$LIBX/build.sh" '	[ "$en" = 1 ] || continue' '	:'
ctl s6-build-manual-after-subs build fail 'build/model-inputs-sources-and-filters ;build/model-auto-members-and-dead-by-id ;build/model-excluded-ids-leave-the-automatic-choice ;build/model-excluded-only-favourite-then-the-others ' \
	"$LIBX/build.sh" '[ -s "$SB_DATA/manual.links" ] && add_input "$SB_DATA/manual.links" manual' ':' \
	"$LIBX/build.sh" 'for f in "$SRCDIR"/[0-9][0-9][0-9].raw; do' '[ -s "$SB_DATA/manual.links" ] && add_input "$SB_DATA/manual.links" manual; for f in "$SRCDIR"/[0-9][0-9][0-9].raw; do'
ctl s6-build-fav-active-off build fail 'build/model-active-favourites-join-the-pool ' \
	"$LIBX/build.sh" '[ -s "$SB_DATA/fav.links" ] && add_input "$SB_DATA/fav.links" fav' ':'
# generator: the stores by id -> the tags of this build
ctl s6-gen-auto-member-as-tags build fail 'build/model-auto-members-and-dead-by-id ;build/model-excluded-member-leaves-the-member-list ' \
	"$LIBX/generator.uc" "for (let t in tags_of(as_array(uci.get('vpnpool', 'main', 'auto_member'))))" "for (let t in as_array(uci.get('vpnpool', 'main', 'auto_member')))"
ctl s6-gen-dead-as-tags build fail 'build/model-auto-members-and-dead-by-id ' \
	"$LIBX/generator.uc" '		for (let t in tags_of(dead))' '		for (let t in dead)'
ctl s6-gen-favorites-only-off build fail 'build/model-favourites-only-and-preferred-default ' \
	"$LIBX/generator.uc" "if (opt('main', 'favorites_only', '0') == '1') {" 'if (false) {'
ctl s6-gen-favorites-only-empties build fail 'build/model-favourites-only-never-empties-the-pool ;build/model-excluded-only-favourite-then-the-others ' \
	"$LIBX/generator.uc" '	if (length(only)) auto_tags = only;' '	auto_tags = only;'
ctl s6-gen-preferred-default-off build fail 'build/model-favourites-only-and-preferred-default ' \
	"$LIBX/generator.uc" "	def = preferred_tag ?? (length(node_tags) ? node_tags[0] : 'auto');" "	def = (length(node_tags) ? node_tags[0] : 'auto');"
# fetch: every subscription its own meta
ctl s6-fetch-meta-one-key fetch fail 'fetch/all-sources-ok ;fetch/primary-fails-extra-ok-keeps-primary-nodes ;fetch/removed-source-dropped-from-cache ' \
	"$LIBX/fetch.sh" "--argjson m \"\$m\" '.[\$s] = \$m')" "--argjson m \"\$m\" '.x = \$m')"
ctl s6-fetch-meta-always-written fetch fail 'fetch/unchanged-source-cache-not-rewritten ' \
	"$LIBX/fetch.sh" '	persist_if_changed "$SB_DATA/.meta.new" "$META"' '	cp "$SB_DATA/.meta.new" "$META"'
ctl s6-fetch-disabled-fetched fetch fail 'fetch/disabled-subscription-not-fetched ' \
	"$LIBX/fetch.sh" '	[ "$en" = 1 ] && [ -n "$url" ] || continue' '	[ -n "$url" ] || continue'
ctl s6-fetch-removed-meta-kept fetch fail 'fetch/removed-source-dropped-from-cache ' \
	"$LIBX/fetch.sh" "'with_entries(select(.key as \$k | \$ids | index(\$k) != null))')" "'.')"
# status: the stores by id, the older screens' tags, masked values
ctl s6-status-source-ignored status fail 'status/node-source-from-the-build ;status/subscriptions-last-fetch ;status/favorites-hidden-preferred ' \
	"$LIBX/status.uc" "	if (substr(src, 0, 4) == 'sub:') return [ 'subscription', substr(src, 4) ];" '	;'
ctl s6-status-legacy-ids status fail 'status/favorites-hidden-preferred ' \
	"$LIBX/status.uc" '	dead_nodes: tags_of(dead_ids),' '	dead_nodes: dead_ids,'
ctl s6-status-hidden-unlisted status fail 'status/favorites-hidden-preferred ' \
	"$LIBX/status.uc" "for (let id in hidden_ids) if (!hseen[id]) push(hidden, { id: id, tag: null, in_source: false });" ';'
ctl s6-status-migration-unmasked status fail 'status/migration-unmatched-listed-masked ' \
	"$LIBX/status.uc" "index(x.value, '://') >= 0) ? mask_url(x.value) :" "index(x.value, '://') >= 0) ? x.value :"
ctl s6-status-pick-missing-wrong status fail 'status/subscriptions-last-fetch ' \
	"$LIBX/status.uc" "	if (s.mode == 'pick') for (let i in s.pick) if (!pool_ids[i] && !hidden_set[i]) missing++;" "	if (s.mode == 'pick') for (let i in s.pick) if (!hidden_set[i]) missing++;"
# daemon: the preferred node by id, the node checker's stores by id, the node tests
ctl s6-daemon-preferred-as-tag daemon fail 'daemon/preferred-in-dead-set-hands-to-auto-keeps-pin ;daemon/preferred-recovered-switches-back ' \
	"$LIBX/vpnpoold" "	ptag=\$(jq -r --arg i \"\$pref\" 'map(select(.id == \$i)) | .[0].tag // \"\"' \"\$SB_DATA/nodes.json\" 2>/dev/null)" '	ptag=$pref'
ctl s6-daemon-pin-cleared-during-rebuild daemon fail 'daemon/preferred-gone-cleared-except-rebuild-or-favourite ' \
	"$LIBX/vpnpoold" '		[ -f "$SB_DATA/.reload_running" ] && return 0' '		:'
ctl s6-daemon-pin-cleared-for-favourite daemon fail 'daemon/preferred-gone-cleared-except-rebuild-or-favourite ' \
	"$LIBX/vpnpoold" "		jq -e --arg i \"\$pref\" 'has(\$i)' \"\$CONF_DIR/favorites.map.json\" >/dev/null 2>&1 && return 0" '		:'
ctl s6-nodecheck-strikes-by-tag daemon fail 'daemon/nodecheck-wan-up-strikes-dead-node ;daemon/nodecheck-strikes-say-when-and-which-host ' \
	"$LIBX/nodecheck.sh" '	printf '"'"'%s%s%s%s%s%s%s\n'"'"' "$id" "$TAB" "$cur"' '	printf '"'"'%s%s%s%s%s%s%s\n'"'"' "$t" "$TAB" "$cur"'
ctl s6-speedtest-unresolved daemon fail 'daemon/node-tests-use-test-selector-only ;daemon/node-test-unknown-node-touches-nothing ' \
	"$LIBX/speedtest.sh" 'R=$(node_resolve "$ARG") || {' 'R=$(printf '"'"'%s\t%s'"'"' "$ARG" "$ARG") || {'
ctl s6-unlock-map-by-tag daemon fail 'daemon/node-tests-use-test-selector-only ' \
	"$LIBX/unlock.sh" 'jq --arg i "$ID" --argjson r "$RES" '"'"'.[$i]=$r'"'"' "$MAP"' 'jq --arg i "$TAG" --argjson r "$RES" '"'"'.[$i]=$r'"'"' "$MAP"'
# tgbot: /switch = Connect (no hard pin), /saved = favourites
ctl s6-tgbot-hard-pin tgbot fail 'tgbot/switch-stores-the-preferred-id ' \
	"$LIBX/tgbot.sh" '	uci set vpnpool.main.preferred_node="$id" 2>/dev/null' '	uci set vpnpool.main.selected_node="$tag" 2>/dev/null'
ctl s6-tgbot-saved-from-nodes tgbot fail 'tgbot/saved-lists-the-favourites ' \
	"$LIBX/tgbot.sh" '		(.favorites // []) as $sv |' '		[ (.nodes // [])[] | select(.saved==true) ] as $sv |'
# rpcd / api: node operations by id, subscriptions, the schema
ctl s6-api-sub-del-wrong-one rpcd fail 'rpcd/sub_del/bad-input ' \
	"$LIBX/api.uc" '		let s = sub_find(u, inp.id ?? inp.url);' '		let s = sub_find(u, inp.id ?? inp.url) ?? subs_of(u)[0];'
ctl s6-api-fav-without-link rpcd fail 'rpcd/fav/ok ;rpcd/save_node/ok ' \
	"$LIBX/api.uc" '	let e = { tag: n.tag, link: link_of(n.id), active: old?.active === true, auto: false, at: time(),' '	let e = { tag: n.tag, link: null, active: old?.active === true, auto: false, at: time(),'
ctl s6-api-hide-not-pruned rpcd fail 'rpcd/hide/ok ' \
	"$LIBX/api.uc" '		prune_live([ r.id ]); drop_marks([ r.id ]);' '		;'
ctl s6-api-hide-keeps-preferred rpcd fail 'rpcd/hide/clears-the-preferred-node ' \
	"$LIBX/api.uc" "		if (u.get('vpnpool', 'main', 'preferred_node') == r.id) u.delete('vpnpool', 'main', 'preferred_node');" '		;'
ctl s6-api-delete-sub-node-not-hidden rpcd fail 'rpcd/delete_nodes/ok ;rpcd/delete_node/subscription-node-is-hidden ;rpcd/unhide/returns-it ' \
	"$LIBX/api.uc" "		changed = list_add(u, 'hidden', r.id);" '		changed = true;'
ctl s6-api-connect-not-live rpcd fail 'rpcd/connect/ok ;rpcd/select/ok ;rpcd/connect/automatic-favourite-becomes-the-users ' \
	"$LIBX/api.uc" "		let c = clash_put('proxy', r.tag);" "		let c = '000';"
ctl s6-api-connect-archive-inactive rpcd fail 'rpcd/connect/favourite-not-in-a-source-joins-the-pool ' \
	"$LIBX/api.uc" '			fav[r.id].active = true;' '			;'
ctl s6-api-auto-keeps-preferred rpcd fail 'rpcd/auto_select/ok ' \
	"$LIBX/api.uc" "		if (had) { u.delete('vpnpool', 'main', 'preferred_node'); if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' }; }" '		;'
ctl s6-api-auto-members-tags rpcd fail 'rpcd/set_auto_members/ok ' \
	"$LIBX/api.uc" "	auto_members:          { s: 'main', o: 'auto_member', list: L_NODE, a: 'USR1' }" "	auto_members:          { s: 'main', o: 'auto_member', list: L_TAG, a: 'USR1' }"
ctl s6-api-singbox-bin-no-live rpcd fail 'rpcd/set_config/singbox-bin-missing-refused ' \
	"$LIBX/api.uc" '		if (!r[1] && d.live) r[1] = d.live(r[0]);' '		;'
ctl s6-api-add-url-not-a-section rpcd fail 'rpcd/add_sub/ok ;rpcd/add/ok ;rpcd/add/url-in-pick-mode ' \
	"$LIBX/api.uc" '			let sid = sub_name_for(u, x);' "			let sid = 'main';"
ctl s6-api-add-mode-ignored rpcd fail 'rpcd/add/url-in-pick-mode ' \
	"$LIBX/api.uc" '			                         enabled: sub_on, mode: sub_mode, pick: sub_pick }))' "			                         enabled: sub_on, mode: 'all', pick: [] }))"
ctl s6-api-repick-appends rpcd fail 'rpcd/import_select/re-pick-replaces ' \
	"$LIBX/api.uc" '		ids = uniq_list(ids);' '		ids = uniq_list([ ...(sub_find(u, inp.url)?.pick ?? []), ...ids ]);'
ctl s6-api-1x-tags-refused rpcd fail 'rpcd/restore/1x-backup-migrated ;rpcd/restore/1x-migration-failure-rolled-back ;rpcd/import/1x-migration-failure-rolled-back ' \
	"$LIBX/api.uc" "		if (f == 'preferred_node') chk = v2 ? ((x) => is_id(x) ? [ x, null ] : [ null, 'bad_tag' ]) : chk_tag;" "		if (f == 'preferred_node') chk = (x) => is_id(x) ? [ x, null ] : [ null, 'bad_tag' ];"
ctl s6-rpcd-restore-not-migrated rpcd fail 'rpcd/restore/1x-backup-migrated ;rpcd/restore/1x-migration-failure-rolled-back ' \
	"$RPCD" '		if ! /usr/libexec/vpnpool/migrate.sh >/dev/null 2>&1   # a 1.x backup' '		if false   # a 1.x backup'
# migrate: the backup, the mapping, the report, idempotence, who runs it
ctl s6-migrate-backup-config-only migrate fail 'migrate/backup-before-changes ' \
	"$LIBX/migrate.sh" 'tar -czf "$BK.tmp" -C / $(backup_members)' 'tar -czf "$BK.tmp" -C / etc/config/vpnpool'
ctl s6-migrate-not-idempotent migrate fail 'migrate/idempotent ;migrate/2x-config-untouched ' \
	"$LIBX/migrate.sh" 'schema)" = 2 ]; then rm -f "$FAILF"; exit 0; fi' 'schema)" = 2 ] && false; then rm -f "$FAILF"; exit 0; fi' \
	"$LIBX/migrate.sh" 'schema)" = 2 ]; then rm -f "$FAILF"; exit 0; fi' 'schema)" = 2 ] && false; then rm -f "$FAILF"; exit 0; fi'
ctl s6-migrate-hard-pin-lost migrate fail 'migrate/hard-pin-becomes-the-preferred-node ;migrate/the-migrated-config-builds ' \
	"$LIBX/migrate.uc" "if (length(M.selected_node ?? '')) pref = id_of_tag('selected_node', M.selected_node);" ';'
ctl s6-migrate-no-running-node-list migrate fail 'migrate/tag-stores-become-ids ;migrate/unmatched-kept-and-reported ' \
	"$LIBX/migrate.uc" "know_outbounds(read_json(RUN + '/nodes.json', []));" ';'
ctl s6-migrate-unmatched-silent migrate fail 'migrate/unmatched-kept-and-reported ;migrate/awg-same-key-other-settings-kept ' \
	"$LIBX/migrate.uc" 'function unmatched(store, value) { push(report.unmatched, { store: store, value: value }); }' 'function unmatched(store, value) { }'
ctl s6-migrate-awg-not-renamed migrate fail 'migrate/awg-files-renamed-with-their-name ;migrate/rerun-after-an-interruption ;migrate/awg-same-key-other-settings-kept ' \
	"$LIBX/migrate.uc" "	push(awg_plan, { from: path, to: AWG + '/' + r.id + '.conf', body: named ? raw : ('# Name = ' + r.tag + '\n' + raw) });" '	;'
ctl s6-migrate-awg-no-name migrate fail 'migrate/awg-files-renamed-with-their-name ' \
	"$LIBX/migrate.uc" "body: named ? raw : ('# Name = ' + r.tag + '\n' + raw) });" 'body: raw });'
# (review) s6-migrate-orphan-import-lost retired: the imports are favourites now (s6-migrate-imports-not-favourites)
ctl s6-migrate-1x-files-kept migrate fail 'migrate/1x-leftovers-gone ' \
	"$LIBX/migrate.uc" "for (let f in [ 'saved.map.json', 'snapshot.map.json', 'imported.map.json', 'sub.expire', 'sub.usage' ]) unlink(CONF + '/' + f);" ';'
ctl s6-initd-no-migration migrate fail 'migrate/init-d-start-migrates ' \
	package/vpnpool/files/etc/init.d/vpnpool '	[ -x /usr/libexec/vpnpool/migrate.sh ] && /usr/libexec/vpnpool/migrate.sh >/dev/null 2>&1' '	:'
ctl s6-uci-defaults-hides-failure migrate fail 'migrate/uci-defaults-runs-it-and-reports ' \
	package/vpnpool/files/etc/uci-defaults/90-vpnpool-2.0 '/usr/libexec/vpnpool/migrate.sh' '/usr/libexec/vpnpool/migrate.sh; exit 0'
# ui: the new reply / field codes need their texts
ctl s6-api-set-url-mask-stored rpcd fail 'rpcd/set_url/masked-url-sent-back-unchanged ' \
	"$LIBX/api.uc" "		if (prim && url == mask_url(prim.url)) return { ok: true, code: 'unchanged', actions: [] };" '		;'
ctl s6-api-delete-awg-file-needs-live rpcd fail 'rpcd/delete_node/awg-file-not-in-the-pool ' \
	"$LIBX/api.uc" "			if ((!r || !r.node) && is_id(k)) r = { id: k, tag: null, node: null, awg_file: true };" '			;'
ctl s6-ui-no-hidden-text ui-unit fail 'every code the backend answers with has a human text' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "	hidden:             _('Hidden." "	hidden_x:           _('Hidden."
ctl s6-ui-no-bad-path-text ui-unit fail 'every code the backend answers with has a human text' \
	package/luci-app-vpnpool/files/www/luci-static/resources/vpnpool/common.js "	bad_path:      _('There is no such program" "	bad_path_x:    _('There is no such program"
# ---- review stage6 (REVIEW_stage6.md B1, B2, V1-V9, M4) ----
ctl s6-parser-pick-no-id parser fail 'parser/pick-skips-a-node-without-id ' \
	"$LIBX/parser.uc" '	if (hidden || (PICK && (!id || !PICK[id]))) {' '	if (hidden || (PICK && id && !PICK[id])) {'
ctl s6-rpcd-restore-ignores-migration-failure rpcd fail 'rpcd/restore/1x-migration-failure-rolled-back ' \
	"$RPCD" '		if ! /usr/libexec/vpnpool/migrate.sh >/dev/null 2>&1   # a 1.x backup' '		if ! { /usr/libexec/vpnpool/migrate.sh >/dev/null 2>&1; true; }   # a 1.x backup'
ctl s6-rpcd-import-ignores-migration-failure rpcd fail 'rpcd/import/1x-migration-failure-rolled-back ' \
	"$RPCD" '		if ! /usr/libexec/vpnpool/migrate.sh >/dev/null 2>&1; then' '		if false; then'
ctl s6-api-connect-auto-stays rpcd fail 'rpcd/connect/automatic-favourite-becomes-the-users ' \
	"$LIBX/api.uc" "			if (type(fav[r.id]) == 'object' && fav[r.id].auto === true) {" '			if (false) {'
ctl s6-api-sub-del-favs-not-kept rpcd fail 'rpcd/sub_del/its-favourites-stay-in-the-pool ' \
	"$LIBX/api.uc" "			if (n._src == 'sub:' + s.id && type(fav[n.id]) == 'object' && fav[n.id].active !== true) {" '			if (false) {'
ctl s6-api-delete-keeps-preferred rpcd fail 'rpcd/delete_node/subscription-node-clears-the-preferred-node ' \
	"$LIBX/api.uc" "		if (changed && u.get('vpnpool', 'main', 'preferred_node') == r.id) u.delete('vpnpool', 'main', 'preferred_node');" '		;'
ctl s6-lookup-no-favourite-tag rpcd fail 'rpcd/node_link/favourite-outside-the-pool-by-tag ;rpcd/activate_saved/favourite-outside-the-pool-by-tag ;rpcd/unsave_node/favourite-outside-the-pool-by-tag ' \
	"$LIBX/common.uc" "		if (type(fav[id]) == 'object' && fav[id].tag == key) return { id: id, tag: key, node: null, fav: fav[id] };" '		;'
ctl s6-fetch-no-size-limit fetch fail 'fetch/oversized-answer-not-used ' \
	"$LIBX/fetch.sh" '		if [ "${sz:-0}" -gt "$MAXB" ]; then' '		if false; then'
ctl s6-snapshot-empty-wipes daemon fail 'daemon/snapshot-nothing-answers-keeps-the-set ' \
	"$LIBX/model.uc" '	if (!length(alive)) {' '	if (false) {'
ctl s6-snapshot-drops-active daemon fail 'daemon/snapshot-keeps-an-active-automatic-favourite ' \
	"$LIBX/model.uc" '	for (let id in keys(fav)) if (fav[id]?.auto === true && fav[id]?.active !== true) delete fav[id];' '	for (let id in keys(fav)) if (fav[id]?.auto === true) delete fav[id];'
ctl s6-migrate-imports-not-favourites migrate fail 'migrate/imported-nodes-become-favourites-in-the-pool ;migrate/saved-nodes-become-favourites ;migrate/the-migrated-config-builds ' \
	"$LIBX/migrate.uc" "for (let l in as_list(M.imported_node, true)) { fav_put('imported_node', null, l, false, true); moved('imported_to_favorites'); }" ';'
ctl s6-migrate-saved-node-only-dropped migrate fail 'migrate/saved-nodes-become-favourites ;migrate/the-migrated-config-builds ' \
	"$LIBX/migrate.uc" "for (let l in as_list(M.saved_node, true)) if (!fav[id_of_link(l) ?? '']) fav_put('saved_node', null, l, false, false);" ';'
ctl s6-migrate-snapshot-map-ignored migrate fail 'migrate/saved-nodes-become-favourites ' \
	"$LIBX/migrate.uc" "for (let t in sort(keys(snap_map))) fav_put('snapshot', t, snap_map[t], true, false);" ';'
ctl s6-migrate-excluded-dropped migrate fail 'migrate/excluded-becomes-hidden ;migrate/the-migrated-config-builds ' \
	"$LIBX/migrate.uc" '	if (!hseen[id]) { hseen[id] = true; push(hidden, id); }' '	;'
ctl s6-migrate-extra-sub-lost migrate fail 'migrate/subscriptions-become-sections ;migrate/first-fetch-primary-down-keeps-its-nodes ;migrate/the-migrated-config-builds ' \
	"$LIBX/migrate.uc" "for (let x in as_list(M.extra_sub, true)) add_sub(x, 'all', [], true);" ';'
ctl s6-migrate-quota-lost migrate fail 'migrate/subscriptions-become-sections ;migrate/the-migrated-config-builds ' \
	"$LIBX/migrate.uc" '	if (meta[sids[0]] == null && (match(exp, /^[0-9]+$/) || length(us) == 3)) {' '	if (false) {'
ctl s6-migrate-cache-not-moved migrate fail 'migrate/1x-cache-moves-to-the-subscriptions ;migrate/first-fetch-primary-down-keeps-its-nodes ' \
	"$LIBX/migrate.sh" '	[ -s "$t" ] || { cp "$f" "$t.tmp" && mv -f "$t.tmp" "$t" && journal "cache: $(basename "$f") -> $(mask_url "$url")"; }' '	:'
ctl s6-migrate-ua-not-moved migrate fail 'migrate/subscription-ua-first-in-the-client-list ;migrate/unmatched-kept-and-reported ' \
	"$LIBX/migrate.uc" '	if (match(ua, /^[!-~]+$/)) {' '	if (false) {'
ctl s6-migrate-routing-touched migrate fail 'migrate/everything-else-byte-for-byte ' \
	"$LIBX/migrate.uc" "                'auto_member', 'keep_auto', 'hidden', 'manual_node' ])" "                'auto_member', 'keep_auto', 'hidden', 'manual_node', 'client' ])"
ctl s6-migrate-lock-not-waited migrate fail 'migrate/waits-for-the-other-run ' \
	"$LIBX/migrate.sh" '	[ "$i" -ge 60 ] && failed busy "another migration still runs after 60 s"' '	failed busy "no wait"'
ctl s6-migrate-awg-dup-deleted migrate fail 'migrate/awg-same-key-other-settings-kept ' \
	"$LIBX/migrate.uc" '		if (body_of(readfile(a.to)) == body_of(a.body)) { unlink(a.from); moved('"'"'awg_duplicate_removed'"'"'); }' '		if (true) { unlink(a.from); moved('"'"'awg_duplicate_removed'"'"'); }'
ctl s6-migrate-old-backup-reused migrate fail 'migrate/second-1x-config-gets-its-own-backup ' \
	"$LIBX/migrate.sh" '[ -f "$BKDIR/.in-progress" ] && BK=$(cat "$BKDIR/.in-progress" 2>/dev/null)' 'BK=$(ls "$BKDIR"/vpnpool-1.x-*.tar.gz 2>/dev/null | head -n1)'
ctl s6-migrate-commit-before-files migrate fail 'migrate/runs-and-journals ;migrate/subscriptions-become-sections ;migrate/imported-nodes-become-favourites-in-the-pool ;migrate/saved-nodes-become-favourites ;migrate/subscription-ua-first-in-the-client-list ;migrate/excluded-becomes-hidden ;migrate/hard-pin-becomes-the-preferred-node ;migrate/tag-stores-become-ids ;migrate/awg-files-renamed-with-their-name ;migrate/unmatched-kept-and-reported ;migrate/1x-leftovers-gone ;migrate/idempotent ;migrate/the-migrated-config-builds ;migrate/first-fetch-primary-down-keeps-its-nodes ;migrate/rerun-after-an-interruption ;migrate/second-1x-config-gets-its-own-backup ;migrate/awg-same-key-other-settings-kept ;migrate/waits-for-the-other-run ;migrate/uci-defaults-runs-it-and-reports ' \
	"$LIBX/migrate.uc" "write_atomic(CONF + '/favorites.map.json', sprintf('%J', fav), 0600);" "u.set('vpnpool', 'main', 'schema', SCHEMA); u.commit('vpnpool'); exit(1);"
ctl s6-initd-starts-on-1x migrate fail 'migrate/failed-migration-daemon-not-started ' \
	package/vpnpool/files/etc/init.d/vpnpool '	if [ "$enabled" = "1" ] && [ "$schema" != 2 ]; then' '	if false; then'
ctl s6-status-migration-failure-hidden migrate fail 'migrate/failure-visible-in-status ' \
	"$LIBX/status.uc" "let migration = (o('schema', '') != '2' && type(migfail) == 'object')" 'let migration = (false)'
ctl s6-upgrade-never-migrates upgrade fail 'FAIL - migrated (schema 2);FAIL - the service is started again after the migration;FAIL - the call right before the first one on the migrated config' \
	package/vpnpool/files/etc/uci-defaults/90-vpnpool-2.0 '[ -x /usr/libexec/vpnpool/migrate.sh ] || exit 0' 'exit 0'
# the Diagnostics log: the path / query of an address and the user part of a node link are masked
ctl lib-log-path-shown rpcd fail 'rpcd/logs/ok ' \
	"$LIBX/lib.sh" "; s#([A-Za-z][A-Za-z0-9+.-]*://[^/?\# ]+)[/?\#][^ ]*#\1/***#g'" "'"
ctl lib-log-link-user-shown rpcd fail 'rpcd/logs/ok ' \
	"$LIBX/lib.sh" '; s#([A-Za-z][A-Za-z0-9+.-]*://)[^@/ ]+@#\1***@#g' ''
# traffic per device: a public source is no device; the router's own connections are one entry
ctl status-public-source-a-device status fail 'status/devices-are-lan-sources ' \
	"$LIBX/status.uc" '	if (!kind) continue;' '	if (!kind) kind = "lan";'
ctl status-router-per-address status fail 'status/devices-are-lan-sources ' \
	"$LIBX/status.uc" "let key = (kind == 'self') ? 'self' : ip;" 'let key = ip;'
# the tunnel proved by the probe before the routes is "up" at once (not "starting" for the warm-up)
ctl daemon-proven-tunnel-starting daemon fail 'daemon/tunnel-proven-at-start-is-up ' \
	"$LIBX/vpnpoold" '[ "$h" = 1 ] && { TUNNEL_PROVEN=$SB_STARTED; tunnel_state up "$(date +%s)"; }' '[ "$h" = 1 ] && { TUNNEL_PROVEN=$SB_STARTED; }'
ctl daemon-warmup-hides-proven daemon fail 'daemon/tunnel-proven-at-start-is-up ' \
	"$LIBX/vpnpoold" '[ "$TUNNEL_PROVEN" = "$SB_STARTED" ] || tunnel_state starting "$now"' 'tunnel_state starting "$now"'
# ---- ui4: "Update" of one subscription (fetch.sh --only, the daemon's queue, rpcd sub_refresh)
ctl ui4-fetch-only-ignored fetch fail 'fetch/only-one-subscription ;fetch/only-the-others-from-their-own-cache ' \
	"$LIBX/fetch.sh" 'if [ "${1:-}" = --only ]; then' 'if false; then'
ctl ui4-fetch-only-others-not-from-cache fetch fail 'fetch/only-the-others-from-their-own-cache ' \
	"$LIBX/fetch.sh" '[ -f "$SRCDIR/s-$k.raw" ] || { [ -s "$CACHEDIR/s-$k.raw" ] && cp "$CACHEDIR/s-$k.raw" "$SRCDIR/s-$k.raw"; }' ':'
ctl ui4-fetch-only-status-replaced fetch fail 'fetch/only-one-subscription ' \
	"$LIBX/fetch.sh" '(if $keep then $p else {} end;' '({};'
ctl ui4-fetch-only-stamp-written fetch fail 'fetch/only-one-subscription ' \
	"$LIBX/fetch.sh" '[ -z "$ONLY" ] && echo "$(date +%s) $(sources_sig)" | write_atomic "$FETCH_STAMP"' 'echo "$(date +%s) $(sources_sig)" | write_atomic "$FETCH_STAMP"'
ctl ui4-daemon-queue-ignored daemon fail 'daemon/reload-fetches-only-the-queued-subscriptions ' \
	"$LIBX/vpnpoold" 'elif [ -s "$FETCH_ONLY" ]; then' 'elif false; then'
ctl ui4-daemon-refetch-keeps-queue daemon fail 'daemon/full-refetch-takes-the-queue-along ' \
	"$LIBX/vpnpoold" 'rm -f "$FETCH_ONLY"   # every subscription is fetched now' ':'
ctl ui4-rpcd-sub-refresh-not-queued rpcd fail 'rpcd/sub_refresh/ok ' \
	"$RPCD" 'echo "$sid" >> "$FETCH_ONLY"' ':'
ctl ui4-rpcd-sub-refresh-turned-off rpcd fail 'rpcd/sub_refresh/turned-off-subscription-refused ' \
	"$RPCD" '[ "$en" = 1 ] || { rep false disabled; exit 0; }' ':'
ctl ui4-rpcd-sub-refresh-unknown rpcd fail 'rpcd/sub_refresh/unknown-is-not-found-nothing-queued ' \
	"$RPCD" '[ -n "$en" ] || { rep false not_found; exit 0; }' ':'
# ---- ui4: the log and the parameters of the Diagnostics page
ctl ui4-logs-token-unmasked rpcd fail 'rpcd/logs/ok ' \
	"$LIBX/lib.sh" "sed -E 's#(bot[0-9]{1,20}):[A-Za-z0-9_-]+#\\1:***#g'" 'cat'
ctl ui4-logs-other-programs rpcd fail 'rpcd/logs/ok ;rpcd/logs/default-200-lines-at-most ' \
	"$LIBX/lib.sh" 'grep -E "$NAME(\[[0-9]+\])?: "' 'grep -E "."'
ctl ui4-logs-unbounded rpcd fail 'rpcd/logs/long-lines-cut-and-bounded ' \
	"$LIBX/lib.sh" 'if (t > 160000) break;' 'if (t > 1600000) break;'
ctl ui4-diag-no-params rpcd fail 'rpcd/diag/technical-parameters-and-engine ' \
	"$LIBX/diag.sh" '		params: $params,' ''
# ---- ui4 (review ui3 Ж2): the bot number of a token is bounded too; the longest token passes tg_test
ctl ui4-tg-test-bot-number-unbounded rpcd fail 'rpcd/tg_test/21-digit-bot-number-refused ' \
	"$RPCD" "grep -Eqx '[0-9]{1,20}:[A-Za-z0-9_-]{1,100}'" "grep -Eqx '[0-9]{1,21}:[A-Za-z0-9_-]{1,100}'"
ctl ui4-api-bot-number-unbounded rpcd fail 'rpcd/set_config/21-digit-bot-number-refused ' \
	"$LIBX/api.uc" 'chk_re(v, /^[0-9]{1,20}:[A-Za-z0-9_-]{1,100}$/, ' 'chk_re(v, /^[0-9]{1,21}:[A-Za-z0-9_-]{1,100}$/, '
ctl ui4-tg-test-longest-refused rpcd fail 'rpcd/tg_test/longest-token-accepted ' \
	"$RPCD" "grep -Eqx '[0-9]{1,20}:[A-Za-z0-9_-]{1,100}'" "grep -Eqx '[0-9]{1,20}:[A-Za-z0-9_-]{1,99}'"
# ---- ui4: the screens
ctl ui4-diag-param-dropped ui-diag fail 'FAIL - checks, the engine and every technical parameter from diag' \
	"$VIEW/diagnostics.js" "row(_('Mark of the routed traffic'), p.fwmark, 'fwmark')," ''
ctl ui4-diag-polls-diag ui-diag fail 'FAIL - log: more than 40 lines' \
	"$VIEW/diagnostics.js" 'poll.add(L.bind(self.loadLog, self), 10);' "poll.add(L.bind(function() { self.loadLog(); return common.call('diag', {}); }, self), 10);"
ctl ui4-nodes-group-update-all ui-nodes fail 'FAIL - subscription "Update": only that subscription' \
	"$VIEW/nodes.js" 'return this.handleSubRefresh(G.g.sub);' 'return this.handleRefresh();'
ctl ui4-pages-found-not-merged ui-pages fail 'FAIL - routing: a site found automatically while the page was open' \
	"$VIEW/routing.js" 'prepare: function(ch) { return self.mergeFound(ch); } });' 'prepare: null });'
ctl ui4-pages-text-as-archive ui-pages fail 'FAIL - settings: a text copy of an older version' \
	"$VIEW/settings.js" 'if (!isGzip(bytes)) return self.importText(textOf(bytes), tooBig);' ''
# the guard has no exception for the Diagnostics page: a technical word in its text is caught
ctl ui4-diag-technical-label uitext fail 'uitext/real-app-no-new-violations ;uitext/stale-baseline-line-fails ' \
	"$VIEW/diagnostics.js" "_('Port that receives the routed traffic')" "_('tproxy port that receives the routed traffic')"
wait
for n in $NC_ORDER; do
	o="$TMPBASE/$n.out"
	if [ -s "$o" ]; then cat "$o"; else echo "BAD   $n: no verdict (control run died)"; fi
	case "$(head -c 5 "$o" 2>/dev/null)" in "OK   ") OK=$((OK+1)) ;; *) BAD=$((BAD+1)) ;; esac
done
rm -rf "$TMPBASE"
echo "CONTROLS: ok=$OK bad=$BAD"
[ "$BAD" -eq 0 ] && [ "$OK" -gt 0 ]
