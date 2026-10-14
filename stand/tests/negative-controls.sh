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
	"$LIBX/parser.uc" "let RESERVED_TAGS = { auto: 1, proxy: 1, direct: 1, block: 1, 'dns-out': 1 };" 'let RESERVED_TAGS = {};'
# id: port left out of the identity
ctl parser-id-without-port parser fail 'parser/id-changes-with-port-and-credential ' \
	"$LIBX/parser.uc" 'port, cred,' 'cred,'
# id depends on the display name -> renaming changes it
ctl parser-id-uses-name parser fail 'parser/id-stable-across-order-and-name ;parser/id-changes-with-port-and-credential ' \
	"$LIBX/parser.uc" 'port, cred,' 'port, cred, ob.tag,'
# id leaks into the default output -> sing-box check rejects the config
ctl parser-id-always parser fail 'parser/id-not-in-default-output ;parser/corpus-accepted-by-sing-box-check ' \
	"$LIBX/parser.uc" 'if (WITH_ID && id) ob.id = id;' 'if (id) ob.id = id;'
# stage 5: unknown transports accepted -> dead/poison nodes
ctl parser-unknown-transport-kept parser fail 'parser/vless-xhttp-refused ;parser/vless-splithttp-refused ;parser/vless-kcp-refused ;parser/trojan-xhttp-refused ;parser/vmess-xhttp-refused ;parser/report-reasons ' \
	"$LIBX/parser.uc" "	return 'unsupported_transport';" "	return { type: t };"
ctl build-config-not-installed build fail 'build/clean-subscription ;build/poison-port-70000 ;build/poison-reserved-tag-direct ;build/poison-reserved-tag-auto ;build/poison-reserved-tag-proxy ;build/poison-duplicate-tags ;build/not-frozen-new-node-arrives-despite-poison ;build/xhttp-builds ;build/xhttp-not-in-config ;build/junk-json-source-does-not-empty-pool ' \
	"$LIBX/build.sh" 'mv "$SB_CONF.new" "$SB_CONF"' 'rm -f "$SB_CONF.new"'
ctl rpcd-add_node-no-signal rpcd fail 'rpcd/add_node/ok ' \
	"$RPCD" 'uci add_list vpnpool.main.manual_node="$l"; uci commit vpnpool; signal_reload' \
	'uci add_list vpnpool.main.manual_node="$l"; uci commit vpnpool'
ctl sched-old-block-kept sched fail 'sched/disabled-removes-block-keeps-user-jobs ' \
	"$LIBX/sched.sh" '/vpnpool-sched BEGIN/,/vpnpool-sched END/d' '/vpnpool-schedX BEGIN/,/vpnpool-schedX END/d'
ctl sched-fix sched xpass 'sched/enabled-writes-jobs ;sched/user-job-added-between-runs-survives ' \
	"$LIBX/sched.sh" 'echo "$((10#$m)) $((10#$h)) * * * $2"' 'echo "${m#0} ${h#0} * * * $2"'
ctl adaptive-ignores-toggle adaptive fail 'adaptive/disabled-does-nothing ' \
	"$LIBX/adaptive.sh" '= "1" ] || exit 0' '= "1" ] || :'
ctl adaptive-fix adaptive xpass 'adaptive/blocked-direct-routed-via-proxy ' \
	"$LIBX/adaptive.sh" '(test("^[0-9.]+$") | not)' '((explode | map(select((. < 48 or . > 57) and . != 46)) | length) > 0)'
ctl fetch-userinfo-lost fetch fail 'fetch/all-sources-ok ' \
	"$LIBX/fetch.sh" "grep -o 'expire=[0-9]*'" "grep -o 'expireX=[0-9]*'"
ctl status-delay-lost status fail 'status/300-nodes-daemon-up-valid ' \
	"$LIBX/status.sh" 'map(select(. != null and . > 0))' 'map(select(. != null and . > 100000))'
ctl uitext-new-technical-string uitext fail 'uitext/real-app-no-new-violations ;uitext/baseline-gates-new-violations ;uitext/stale-baseline-line-fails ' \
	"$VIEW/dashboard.js" "_('Cancel')" "_('Cancel via rpcd')"
ctl ui-smoke-status-broken ui-smoke fail 'ubus vpnpool.status via /ubus' \
	"$RPCD" '		/usr/libexec/vpnpool/status.sh' '		echo not-json'
# runner: a suite that silently stops early must fail the run (min-cases.txt), not shrink total
ctl suite-stops-early sched fail 'runner/sched-ran-at-least-4-cases' \
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
