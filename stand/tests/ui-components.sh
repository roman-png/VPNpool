#!/bin/sh
# UI foundation check (ROADMAP-2.0 §10.1/§10.8): the shared module vpnpool/common.js, the
# temporary component page view/vpnpool/_demo.js and the LuCI translation catalog, on the
# LuCI stand. From the host:
#   stand/tests/ui-components.sh                        (image vpnpool-stand-ui, OpenWrt 24.10)
#   IMAGE=vpnpool-stand-ui:25.12 stand/tests/ui-components.sh
#   PORT=18081 KEEP=1 stand/tests/ui-components.sh      leave the container running for a
#                                                       browser: http://localhost:18081/cgi-bin/luci/admin/services/vpnpool/_demo
#                                                       (root / vpnpool; stop: docker rm -f vpnpool-ui-components)
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
NAME=${NAME:-vpnpool-ui-components-$$}
[ "$KEEP" = 1 ] && NAME=vpnpool-ui-components
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
	for f in vpnpool/common.js view/vpnpool/_demo.js; do
		node --check "$(hostpath "$RES/$f")" 2>"$TMPD/err" && ok "syntax $f" || bad "syntax $f: $(head -c 300 "$TMPD/err")"
	done
	node "$(hostpath "$HERE/ui-common.test.js")" > "$TMPD/unit" 2>&1
	U=$(grep -E '^UNIT: passed=[0-9]+ failed=[0-9]+$' "$TMPD/unit")
	case "$U" in "UNIT: passed="[1-9]*" failed=0") ok "unit tests of common.js ($U)" ;; *) bad "unit tests of common.js: ${U:-no summary line}"; grep '^FAIL' "$TMPD/unit" ;; esac
	node "$(hostpath "$HERE/ui-common.test.js")" --negative > "$TMPD/neg" 2>&1
	N=$(grep -E '^NEG: passed=[0-9]+ failed=[0-9]+( skipped=[0-9]+)?$' "$TMPD/neg")
	case "$N" in "NEG: passed="[1-9]*" failed=0"|"NEG: passed="[1-9]*" failed=0 skipped="*) ok "negative controls of the unit tests ($N)" ;; *) bad "negative controls: ${N:-no summary line}"; grep '^FAIL' "$TMPD/neg" ;; esac
else
	bad "node not found: syntax and unit tests of common.js did not run"
fi

# --- po: the catalog is complete and compiles
sh "$HERE/ui-i18n.sh" check > "$TMPD/i18n" 2>&1
I=$(grep -E '^I18N: ' "$TMPD/i18n")
grep -q '^VERDICT ok$' "$TMPD/i18n" && ok "po check (${I#I18N: })" || { bad "po check: ${I:-no summary}"; grep '^FAIL' "$TMPD/i18n" | head -20; }
LMO=$TMPD/vpnpool.ru.lmo
[ "$KEEP" = 1 ] && LMO=${TMPDIR:-/tmp}/vpnpool-ui-components.ru.lmo   # must outlive this script
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

for f in vpnpool/common.js view/vpnpool/_demo.js; do
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
check_tr 'Dashboard' 'Дашборд'
check_tr 'More actions' 'Ещё действия'
check_tr 'The service is off. Turn it on and try again.' 'Служба выключена. Включите её и попробуйте ещё раз.'
check_tr 'VPN exit: %s (IP %s)' 'Выход через VPN: %s  (IP %s)'
check_tr 'vpnpool stand: this msgid is not in the catalog' ''

curl -s -o "$TMPD/menu" -b "$CK" "$B/cgi-bin/luci/admin/menu"
grep -q '"_demo"' "$TMPD/menu" && grep -q '"Dashboard"' "$TMPD/menu" && ok "menu has the stand-only route and English msgid titles" || bad "menu JSON: $(head -c 200 "$TMPD/menu")"

# the module's transport paths: a real method answers, a method outside the ACL is refused
# (call() turns -32002 into "no permission"), a method rpcd does not know answers ubus 3
ubus() { curl -s -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$SID\",\"vpnpool\",\"$1\",{}]}" "$B/ubus"; }
ubus status > "$TMPD/st"
grep -q '"result":\[0,{' "$TMPD/st" && ok "vpnpool.status answers an object" || bad "vpnpool.status: $(head -c 200 "$TMPD/st")"
ubus no_such_method > "$TMPD/nm"
grep -q '"code":-32002' "$TMPD/nm" && ok "method outside the ACL -> -32002 (common: access_denied)" || bad "method outside the ACL: $(head -c 200 "$TMPD/nm")"
ubus select > "$TMPD/sel"
grep -q '"ok":false' "$TMPD/sel" && grep -q '"code":"invalid"' "$TMPD/sel" && grep -q '"errors":{"tag":"bad_tag"}' "$TMPD/sel" && ok "select without a node -> ok:false invalid, errors.tag (common: field text)" || bad "select {}: $(head -c 200 "$TMPD/sel")"

echo "UI-COMPONENTS: passed=$P failed=$F"
[ "$KEEP" = 1 ] && echo "# kept: $B/cgi-bin/luci/admin/services/vpnpool/_demo  (docker rm -f $NAME)"
[ "$F" -eq 0 ] && [ "$P" -gt 0 ]
