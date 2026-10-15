#!/bin/sh
# i18n of luci-app-vpnpool (standard LuCI po): check or sync po/ against the sources.
#   stand/tests/ui-i18n.sh            check  -> "I18N: msgids=… failed=0" + "VERDICT ok", exit 0
#   stand/tests/ui-i18n.sh sync       rewrite po/templates/vpnpool.pot, merge into po/<lang>/
#                                     vpnpool.po (then translate the new empty msgstr and re-check)
#   stand/tests/ui-i18n.sh lmo <out>  also compile po/ru/vpnpool.po into <out> (stand/tests/
#                                     po2lmo.py, a port of LuCI's po2lmo) — used by ui-components.sh
# The check itself is stand/tests/ui-i18n.uc (ucode; runs in the vpnpool-stand image if the
# host has no ucode). What it checks: see the header of ui-i18n.uc.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand}
MODE=${1:-check}
APP=$REPO_DIR/package/luci-app-vpnpool

if command -v ucode >/dev/null 2>&1; then
	U() { ucode "$HERE/ui-i18n.uc" "$APP" "$@"; }
else
	hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
	R=$(hostpath "$REPO_DIR")
	U() { MSYS_NO_PATHCONV=1 docker run --rm --network none -v "$R:/repo" --entrypoint ucode "$IMAGE" \
		/repo/stand/tests/ui-i18n.uc /repo/package/luci-app-vpnpool "$@"; }
fi
PY=$(command -v python3 || command -v python || true)

case "$MODE" in
	check) U check ;;
	sync)  U sync ;;
	lmo)
		[ -n "${2:-}" ] || { echo "usage: $0 lmo <out.lmo>" >&2; exit 2; }
		[ -n "$PY" ] || { echo "ui-i18n: python3 is needed for lmo" >&2; exit 2; }
		"$PY" -I "$HERE/po2lmo.py" "$APP/po/ru/vpnpool.po" "$2" ;;
	*) echo "usage: $0 [check|sync|lmo <out>]" >&2; exit 2 ;;
esac
