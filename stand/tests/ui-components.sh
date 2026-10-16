#!/bin/sh
# UI foundation check (ROADMAP-2.0 §10.1/§10.8): the shared module vpnpool/common.js, the
# temporary component page view/vpnpool/_demo.js and the LuCI translation catalog, on the
# LuCI stand. From the host:
#   stand/tests/ui-components.sh                        (image vpnpool-stand-ui, OpenWrt 24.10)
#   IMAGE=vpnpool-stand-ui:25.12 stand/tests/ui-components.sh
#   PORT=18081 KEEP=1 stand/tests/ui-components.sh      leave the container running for a
#                                                       browser: http://localhost:18081/cgi-bin/luci/admin/services/vpnpool/_demo
#                                                       (root / vpnpool; stop: docker rm -f vpnpool-ui-components)
#   NAME=vpnpool-ui3-keep PORT=18084 KEEP=1 …          the same under an own name (parallel sessions)
# Needs: docker, curl; node (syntax + unit tests of common.js); python3 (po -> lmo).
# There is no headless browser on the stand: DOM behaviour (menu keys, dialog, 375 px layout,
# dark theme) is checked by hand in a browser — what to look at: see the handoff of pack ui0.
# Prints "UI-COMPONENTS: passed=N failed=M"; exit non-zero on any failure or if nothing ran.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand-ui}
PORT=${PORT:-18083}
KEEP=${KEEP:-0}
# KEEP=1: a fixed name (vpnpool-ui-components) unless NAME is given — two sessions keep their own
# stands with NAME=<own name> PORT=<own port>
NAME_GIVEN=${NAME:-}
NAME=${NAME:-vpnpool-ui-components-$$}
[ "$KEEP" = 1 ] && [ -z "$NAME_GIVEN" ] && NAME=vpnpool-ui-components
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
R=$(hostpath "$REPO_DIR")
A=$R/package/luci-app-vpnpool/files
RES=$REPO_DIR/package/luci-app-vpnpool/files/www/luci-static/resources
P=0; F=0
ok()  { P=$((P+1)); echo "ok   - $1"; }
bad() { F=$((F+1)); echo "FAIL - $1"; }
TMPD=$(mktemp -d)
cleanup() { [ "$KEEP" = 1 ] || docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$TMPD"; }
trap cleanup EXIT

# --- host: syntax + unit tests of the module (no browser needed)
if command -v node >/dev/null 2>&1; then
	for f in vpnpool/common.js view/vpnpool/_demo.js view/vpnpool/nodes.js view/vpnpool/dashboard.js; do
		node --check "$(hostpath "$RES/$f")" 2>"$TMPD/err" && ok "syntax $f" || bad "syntax $f: $(head -c 300 "$TMPD/err")"
	done
	node "$(hostpath "$HERE/ui-common.test.js")" > "$TMPD/unit" 2>&1
	U=$(grep -E '^UNIT: passed=[0-9]+ failed=[0-9]+$' "$TMPD/unit")
	case "$U" in "UNIT: passed="[1-9]*" failed=0") ok "unit tests of common.js ($U)" ;; *) bad "unit tests of common.js: ${U:-no summary line}"; grep '^FAIL' "$TMPD/unit" ;; esac
	node "$(hostpath "$HERE/ui-common.test.js")" --negative > "$TMPD/neg" 2>&1
	N=$(grep -E '^NEG: passed=[0-9]+ failed=[0-9]+( skipped=[0-9]+)?$' "$TMPD/neg")
	case "$N" in "NEG: passed="[1-9]*" failed=0"|"NEG: passed="[1-9]*" failed=0 skipped="*) ok "negative controls of the unit tests ($N)" ;; *) bad "negative controls: ${N:-no summary line}"; grep '^FAIL' "$TMPD/neg" ;; esac
	# the Nodes tab: behaviour of the real view on the fakes (+ its own mutations)
	node "$(hostpath "$HERE/ui-nodes.test.js")" > "$TMPD/nodes" 2>&1
	U=$(grep -E '^NODES: passed=[0-9]+ failed=[0-9]+ checked=[0-9]+$' "$TMPD/nodes")
	case "$U" in "NODES: passed="[1-9]*" failed=0 checked="[1-9]*) ok "tests of the Nodes tab ($U)" ;; *) bad "tests of the Nodes tab: ${U:-no summary line}"; grep '^FAIL' "$TMPD/nodes" ;; esac
	node "$(hostpath "$HERE/ui-nodes.test.js")" --negative > "$TMPD/nneg" 2>&1
	N=$(grep -E '^NODES-NEG: passed=[0-9]+ failed=[0-9]+$' "$TMPD/nneg")
	case "$N" in "NODES-NEG: passed="[1-9]*" failed=0") ok "negative controls of the Nodes tab tests ($N)" ;; *) bad "negative controls of the Nodes tab: ${N:-no summary line}"; grep '^FAIL' "$TMPD/nneg" ;; esac
else
	bad "node not found: syntax and unit tests of common.js did not run"
fi

# --- po: the catalog is complete and compiles
sh "$HERE/ui-i18n.sh" check > "$TMPD/i18n" 2>&1
I=$(grep -E '^I18N: ' "$TMPD/i18n")
grep -q '^VERDICT ok$' "$TMPD/i18n" && ok "po check (${I#I18N: })" || { bad "po check: ${I:-no summary}"; grep '^FAIL' "$TMPD/i18n" | head -20; }
LMO=$TMPD/vpnpool.ru.lmo
[ "$KEEP" = 1 ] && LMO=${TMPDIR:-/tmp}/$NAME.ru.lmo   # must outlive this script (one per kept stand)
sh "$HERE/ui-i18n.sh" lmo "$(hostpath "$LMO")" > "$TMPD/lmo" 2>&1
[ -s "$LMO" ] && ok "po -> lmo ($(cat "$TMPD/lmo"))" || bad "po -> lmo: $(cat "$TMPD/lmo")"
PY=$(command -v python3 || command -v python || true)
hash_of() { "$PY" -I "$(hostpath "$HERE/po2lmo.py")" --hash "$1"; }

# --- stand: LuCI serves the module and the page, the catalog is loaded
docker rm -f "$NAME" >/dev/null 2>&1
MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" -p "127.0.0.1:$PORT:80" \
	-v "$R/package/vpnpool/files/usr/libexec/vpnpool:/usr/libexec/vpnpool:ro" \
	-v "$A/usr/libexec/rpcd:/stage/rpcd:ro" \
	-v "$A/www/luci-static/resources/view/vpnpool:/www/luci-static/resources/view/vpnpool:ro" \
	-v "$A/www/luci-static/resources/vpnpool:/www/luci-static/resources/vpnpool:ro" \
	-v "$A/usr/share/luci/menu.d/luci-app-vpnpool.json:/usr/share/luci/menu.d/luci-app-vpnpool.json:ro" \
	-v "$R/stand/tests/fixtures/ui/menu-demo.json:/usr/share/luci/menu.d/luci-app-vpnpool-demo.json:ro" \
	-v "$A/usr/share/rpcd/acl.d/luci-app-vpnpool.json:/usr/share/rpcd/acl.d/luci-app-vpnpool.json:ro" \
	-v "$(hostpath "$LMO"):/usr/lib/lua/luci/i18n/vpnpool.ru.lmo:ro" \
	-v "$R/stand:/work:ro" \
	"$IMAGE" >/dev/null || { echo "UI-COMPONENTS: passed=$P failed=$((F+1)) (container did not start)"; exit 1; }
docker exec "$NAME" sh -c 'uci set luci.main.lang=ru && uci commit luci' && ok "LuCI language set to ru" || bad "LuCI language set to ru"
B="http://127.0.0.1:$PORT"
i=0; while ! curl -s -o /dev/null "$B/" && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
REL=$(docker exec "$NAME" sh -c '. /etc/openwrt_release; echo $DISTRIB_RELEASE')
LB=$(docker exec "$NAME" sh -c 'opkg list-installed 2>/dev/null | grep "^luci-base " ; apk list -I 2>/dev/null | grep -o "^luci-base-[^ ]*"' | head -1)
echo "# OpenWrt $REL, $LB"

curl -s -o /dev/null -D "$TMPD/h" -d 'luci_username=root&luci_password=vpnpool' "$B/cgi-bin/luci/"
SID=$(sed -n 's/^[Ss]et-[Cc]ookie: sysauth[^=]*=\([0-9a-f]*\).*/\1/p' "$TMPD/h" | head -1)
[ -n "$SID" ] && ok "login" || bad "login (no sysauth cookie)"
CK="sysauth_http=$SID; sysauth=$SID"

CODE=$(curl -s -o "$TMPD/page" -w '%{http_code}' -b "$CK" "$B/cgi-bin/luci/admin/services/vpnpool/_demo")
[ "$CODE" = 200 ] && grep -q 'vpnpool/_demo' "$TMPD/page" && ok "component page -> 200, loads view vpnpool/_demo" || bad "component page -> HTTP $CODE"
# negative control of the check above: without a session LuCI must not render it
CODE=$(curl -s -o "$TMPD/page0" -w '%{http_code}' "$B/cgi-bin/luci/admin/services/vpnpool/_demo")
grep -q 'vpnpool/_demo' "$TMPD/page0" && bad "component page without login is refused (HTTP $CODE)" || ok "component page without login is refused (HTTP $CODE)"

for f in vpnpool/common.js view/vpnpool/_demo.js view/vpnpool/nodes.js vpnpool/jsqr.min.js; do
	curl -s -o "$TMPD/served" "$B/luci-static/resources/$f"
	cmp -s "$TMPD/served" "$RES/$f" && ok "LuCI serves $f (byte-identical)" || bad "LuCI serves $f"
done

# translation catalog: LuCI's _() looks up sfh(msgid) in window.TR from admin/translations/<lang>
TRURL=$(grep -o '/cgi-bin/luci/admin/translations/[a-z_-]*' "$TMPD/page" | head -1)
curl -s -o "$TMPD/tr" -b "$CK" "$B${TRURL:-/cgi-bin/luci/admin/translations/ru}"
check_tr() {   # $1 msgid  $2 expected translation (empty = must be absent)
	h=$(hash_of "$1")
	got=$(grep -o "\"$h\":\"[^\"]*\"" "$TMPD/tr" | head -1 | sed 's/^"[0-9a-f]*":"//; s/"$//')
	if [ -n "$2" ]; then
		[ "$got" = "$2" ] && ok "translated: \"$1\" -> \"$got\"" || bad "translated: \"$1\" -> \"$got\" (want \"$2\")"
	else
		[ -z "$got" ] && ok "not in the catalog (negative control): \"$1\"" || bad "unexpected translation of \"$1\": \"$got\""
	fi
}
[ -n "$TRURL" ] && ok "page loads the catalog $TRURL" || bad "page loads a translations catalog"
check_tr 'Grant access to vpnpool dashboard' 'Доступ к панели VPN Pool'
check_tr 'Overview' 'Обзор'
check_tr 'Nodes' 'Узлы'
check_tr 'Routes' 'Маршруты'
# a plural msgid: the key is msgid + \002 + the form index (po2lmo; LuCI's N_)
check_tr "$(printf '%%d node\002%s' 1)" '%d узла'
check_tr 'Connected to %s: chosen by you. If it stops working, the automatic choice takes over until it is back.' 'Подключён к %s — выбран вами. Если он перестанет работать, автовыбор подменит его, пока он не вернётся.'
check_tr 'More actions' 'Ещё действия'
check_tr 'The service is off. Turn it on and try again.' 'Служба выключена. Включите её и попробуйте ещё раз.'
check_tr 'VPN exit: %s (IP %s)' 'Выход через VPN: %s  (IP %s)'
check_tr 'vpnpool stand: this msgid is not in the catalog' ''

curl -s -o "$TMPD/menu" -b "$CK" "$B/cgi-bin/luci/admin/menu"
grep -q '"_demo"' "$TMPD/menu" && grep -q '"Overview"' "$TMPD/menu" && grep -q '"Nodes"' "$TMPD/menu" && ok "menu has the stand-only route and English msgid titles" || bad "menu JSON: $(head -c 200 "$TMPD/menu")"

# the module's transport paths: a real method answers, a method outside the ACL is refused
# (call() turns -32002 into "no permission"), a method rpcd does not know answers ubus 3
ubus() { curl -s -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$SID\",\"vpnpool\",\"$1\",{}]}" "$B/ubus"; }
ubus status > "$TMPD/st"
grep -q '"result":\[0,{' "$TMPD/st" && ok "vpnpool.status answers an object" || bad "vpnpool.status: $(head -c 200 "$TMPD/st")"
ubus no_such_method > "$TMPD/nm"
grep -q '"code":-32002' "$TMPD/nm" && ok "method outside the ACL -> -32002 (common: access_denied)" || bad "method outside the ACL: $(head -c 200 "$TMPD/nm")"
ubus select > "$TMPD/sel"
grep -q '"ok":false' "$TMPD/sel" && grep -q '"code":"invalid"' "$TMPD/sel" && grep -q '"errors":{"tag":"bad_tag"}' "$TMPD/sel" && ok "select without a node -> ok:false invalid, errors.tag (common: field text)" || bad "select {}: $(head -c 200 "$TMPD/sel")"

# --- ui3: the settings pages "Routes" and "Settings" (form.JSONMap + one set_config)
# host: syntax, the page unit tests (+ their negative controls); they also write the set_config
# payloads of their "every field changed" cases, which the REAL backend must accept below
PAY=$TMPD/payload; mkdir -p "$PAY"
if command -v node >/dev/null 2>&1; then
	for f in view/vpnpool/routing.js view/vpnpool/settings.js; do
		node --check "$(hostpath "$RES/$f")" 2>"$TMPD/err" && ok "syntax $f" || bad "syntax $f: $(head -c 300 "$TMPD/err")"
	done
	UI_PAGES_PAYLOAD_DIR=$(hostpath "$PAY") node "$(hostpath "$HERE/ui-pages.test.js")" > "$TMPD/pages" 2>&1
	U=$(grep -E '^PAGES: passed=[0-9]+ failed=[0-9]+ checked=[0-9]+$' "$TMPD/pages")
	case "$U" in "PAGES: passed="[1-9]*" failed=0 checked="[1-9]*) ok "unit tests of the settings pages ($U)" ;; *) bad "unit tests of the settings pages: ${U:-no summary line}"; grep '^FAIL' "$TMPD/pages" ;; esac
	node "$(hostpath "$HERE/ui-pages.test.js")" --negative > "$TMPD/pneg" 2>&1
	N=$(grep -E '^PAGES-NEG: passed=[0-9]+ failed=[0-9]+$' "$TMPD/pneg")
	case "$N" in "PAGES-NEG: passed="[1-9]*" failed=0") ok "negative controls of the page tests ($N)" ;; *) bad "negative controls of the page tests: ${N:-no summary line}"; grep '^FAIL' "$TMPD/pneg" ;; esac
fi
for pg in routing settings; do
	CODE=$(curl -s -o "$TMPD/pg" -w '%{http_code}' -b "$CK" "$B/cgi-bin/luci/admin/services/vpnpool/$pg")
	[ "$CODE" = 200 ] && grep -q "vpnpool/$pg" "$TMPD/pg" && ok "page $pg -> 200, loads view vpnpool/$pg" || bad "page $pg -> HTTP $CODE"
	curl -s -o "$TMPD/served" "$B/luci-static/resources/view/vpnpool/$pg.js"
	cmp -s "$TMPD/served" "$RES/view/vpnpool/$pg.js" && ok "LuCI serves view/vpnpool/$pg.js (byte-identical)" || bad "LuCI serves view/vpnpool/$pg.js"
done
check_tr 'Routes' 'Маршруты'
check_tr 'Revert' 'Отменить'
check_tr 'There are unsaved changes.' 'Есть несохранённые изменения.'
ubusj() { curl -s -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$SID\",\"vpnpool\",\"$1\",$2]}" "$B/ubus"; }
for pg in routing settings; do
	if [ -s "$PAY/$pg.json" ]; then
		ubusj set_config "$(cat "$PAY/$pg.json")" > "$TMPD/sc"
		grep -q '"ok":true' "$TMPD/sc" && grep -Eq '"code":"(saved|applied)"' "$TMPD/sc" \
			&& ok "the real set_config accepts what the $pg page sends ($(grep -o '"changed":\[[^]]*\]' "$TMPD/sc" | tr -cd ',' | wc -c | awk '{print $1+1}') fields)" \
			|| bad "the real set_config refused the $pg page's payload: $(head -c 400 "$TMPD/sc")"
	else bad "no $pg payload from the page tests"; fi
done
ubus status > "$TMPD/st2"
grep -q '"mode":"exclude"' "$TMPD/st2" && grep -q '"log_level":"info"' "$TMPD/st2" && ok "status shows the saved values (mode, log detail)" || bad "status after the saves: $(head -c 300 "$TMPD/st2")"
# negative control of the acceptance check: a payload with a wrong type is refused, field named
ubusj set_config '{"settings":{"killswitch":"maybe","domains":["ok.example","bad domain!"]}}' > "$TMPD/sc0"
grep -q '"ok":false' "$TMPD/sc0" && grep -q '"killswitch":"bad_value"' "$TMPD/sc0" && grep -q '"domains\[1\]":"bad_domain"' "$TMPD/sc0" \
	&& ok "a wrong payload is refused with the field codes (negative control)" || bad "wrong payload: $(head -c 300 "$TMPD/sc0")"

echo "UI-COMPONENTS: passed=$P failed=$F"
[ "$KEEP" = 1 ] && echo "# kept: $B/cgi-bin/luci/admin/services/vpnpool/_demo  (docker rm -f $NAME)"
[ "$F" -eq 0 ] && [ "$P" -gt 0 ]
