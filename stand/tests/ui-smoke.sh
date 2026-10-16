#!/bin/sh
# Smoke check of the LuCI UI stand from the host: start vpnpool-stand-ui on a spare port,
# log in to LuCI, open admin/services/vpnpool, call `vpnpool status` through rpcd over the
# HTTP ubus bridge (the exact path the dashboard uses), then stop the container.
#   stand/tests/ui-smoke.sh            (needs: docker build -f stand/Dockerfile.ui -t vpnpool-stand-ui .)
# Prints "UI-SMOKE: passed=N failed=M" and exits non-zero on any failure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand-ui}
PORT=${PORT:-18080}
NAME="vpnpool-ui-smoke-$$"
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
R=$(hostpath "$REPO_DIR")
A=$R/package/luci-app-vpnpool/files
P=0; F=0
ok()  { P=$((P+1)); echo "ok   - $1"; }
bad() { F=$((F+1)); echo "FAIL - $1"; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -f "$TMPD"/* 2>/dev/null; rmdir "$TMPD" 2>/dev/null; }
TMPD=$(mktemp -d)
trap cleanup EXIT

MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" -p "127.0.0.1:$PORT:80" \
	-v "$R/package/vpnpool/files/usr/libexec/vpnpool:/usr/libexec/vpnpool:ro" \
	-v "$A/usr/libexec/rpcd:/stage/rpcd:ro" \
	-v "$A/www/luci-static/resources/view/vpnpool:/www/luci-static/resources/view/vpnpool:ro" \
	-v "$A/www/luci-static/resources/vpnpool:/www/luci-static/resources/vpnpool:ro" \
	-v "$A/usr/share/luci/menu.d/luci-app-vpnpool.json:/usr/share/luci/menu.d/luci-app-vpnpool.json:ro" \
	-v "$A/usr/share/rpcd/acl.d/luci-app-vpnpool.json:/usr/share/rpcd/acl.d/luci-app-vpnpool.json:ro" \
	-v "$R/stand:/work:ro" \
	"$IMAGE" >/dev/null || { echo "UI-SMOKE: passed=0 failed=1 (container did not start)"; exit 1; }

B="http://127.0.0.1:$PORT"
i=0; while ! curl -s -o /dev/null "$B/" && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
curl -s -o /dev/null "$B/" && ok "uhttpd answers on :$PORT" || bad "uhttpd answers on :$PORT"

# login: LuCI sets the sysauth cookie on a successful POST
curl -s -o /dev/null -D "$TMPD/h" -d 'luci_username=root&luci_password=vpnpool' "$B/cgi-bin/luci/"
SID=$(sed -n 's/^[Ss]et-[Cc]ookie: sysauth[^=]*=\([0-9a-f]*\).*/\1/p' "$TMPD/h" | head -1)
[ -n "$SID" ] && ok "login as root (session ${SID%"${SID#????????}"}…)" || bad "login as root (no sysauth cookie)"

# wrong password must NOT log in (negative control for the check above)
curl -s -o /dev/null -D "$TMPD/h2" -d 'luci_username=root&luci_password=wrong' "$B/cgi-bin/luci/"
grep -qi '^set-cookie: sysauth' "$TMPD/h2" && bad "wrong password rejected" || ok "wrong password rejected"

# the vpnpool page: firstchild -> dashboard view, rendered by the LuCI dispatcher
CODE=$(curl -s -L -o "$TMPD/page" -w '%{http_code}' -b "sysauth_http=$SID; sysauth=$SID" "$B/cgi-bin/luci/admin/services/vpnpool")
[ "$CODE" = 200 ] && ok "admin/services/vpnpool -> HTTP 200" || bad "admin/services/vpnpool -> HTTP $CODE"
grep -q 'vpnpool/dashboard' "$TMPD/page" && ok "page loads view vpnpool/dashboard" || bad "page loads view vpnpool/dashboard"
# the menu tree is fetched by the page as JSON (LuCI renders it client-side)
curl -s -o "$TMPD/menu" -b "sysauth_http=$SID; sysauth=$SID" "$B/cgi-bin/luci/admin/menu"
if grep -q '"vpnpool"' "$TMPD/menu" && grep -q '"VPN Pool"' "$TMPD/menu" && grep -q '"dashboard"' "$TMPD/menu"; then
	ok "menu JSON has Services > VPN Pool > dashboard"
else bad "menu JSON has Services > VPN Pool > dashboard: $(head -c 200 "$TMPD/menu")"; fi

# the tabs of 2.0 (ROADMAP §0): Overview / Nodes / Routes / Settings / Diagnostics; no "Sources"
if grep -q '"nodes"' "$TMPD/menu" && grep -q '"Nodes"' "$TMPD/menu" && ! grep -q '"sources"' "$TMPD/menu"; then
	ok "menu has the Nodes tab and no Sources tab"
else bad "menu: Nodes tab / no Sources tab: $(head -c 300 "$TMPD/menu")"; fi
CODE=$(curl -s -o "$TMPD/npage" -w '%{http_code}' -b "sysauth_http=$SID; sysauth=$SID" "$B/cgi-bin/luci/admin/services/vpnpool/nodes")
[ "$CODE" = 200 ] && grep -q 'vpnpool/nodes' "$TMPD/npage" && ok "Nodes page -> HTTP 200, loads view vpnpool/nodes" || bad "Nodes page -> HTTP $CODE"

# the view JS itself is served
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$B/luci-static/resources/view/vpnpool/dashboard.js")
[ "$CODE" = 200 ] && ok "dashboard.js served" || bad "dashboard.js served (HTTP $CODE)"
for f in view/vpnpool/nodes.js vpnpool/jsqr.min.js vpnpool/qrcode.min.js; do
	CODE=$(curl -s -o /dev/null -w '%{http_code}' "$B/luci-static/resources/$f")
	[ "$CODE" = 200 ] && ok "$f served" || bad "$f served (HTTP $CODE)"
done

# vpnpool status through rpcd over the HTTP ubus bridge, with the session's ACL
curl -s -o "$TMPD/st" -H 'Content-Type: application/json' \
	-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$SID\",\"vpnpool\",\"status\",{}]}" "$B/ubus"
if grep -q '"result":\[0,{' "$TMPD/st" && grep -q '"nodes"' "$TMPD/st"; then ok "ubus vpnpool.status via /ubus (rc 0, has nodes)"; else bad "ubus vpnpool.status via /ubus: $(head -c 200 "$TMPD/st")"; fi
# ... and NOT without a session (ACL negative control)
curl -s -o "$TMPD/st0" -H 'Content-Type: application/json' \
	-d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","vpnpool","status",{}]}' "$B/ubus"
grep -q '"result":\[0,{' "$TMPD/st0" && bad "anonymous ubus call refused" || ok "anonymous ubus call refused"

echo "UI-SMOKE: passed=$P failed=$F"
[ "$F" -eq 0 ] && [ "$P" -gt 0 ]
