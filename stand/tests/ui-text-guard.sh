#!/bin/sh
# Host wrapper for the UI text guard (the guard is ucode; it runs in the vpnpool-stand image).
#   stand/tests/ui-text-guard.sh                    # check: fails on a violation NOT in the baseline
#   stand/tests/ui-text-guard.sh --update-baseline  # rewrite the baseline after FIXING strings;
#                                                   # refuses if it would ADD a line (baseline only shrinks)
# Inside the stand (ucode available) it runs directly. The same check is the `uitext` suite
# of stand/tests/run.sh, with a positive control on stand/tests/fixtures/uitext/bad.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand}
MODE=${1:-check}

if command -v ucode >/dev/null 2>&1; then
	G() { ucode "$HERE/ui-text-guard.uc" "$REPO_DIR/package/luci-app-vpnpool" "$HERE/ui-text-stoplist.txt" "$@"; }
	T=$HERE
else
	hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
	R=$(hostpath "$REPO_DIR")
	G() { MSYS_NO_PATHCONV=1 docker run --rm --network none -v "$R:/repo" --entrypoint ucode "$IMAGE" \
		/repo/stand/tests/ui-text-guard.uc /repo/package/luci-app-vpnpool /repo/stand/tests/ui-text-stoplist.txt "$@"; }
	T=/repo/stand/tests
fi

case "$MODE" in
	check) G "$T/ui-text-baseline.txt" ;;
	--update-baseline)   # only drops GONE lines; exit 3 of the guard = "no NEW, some GONE"
		set +e
		G "$T/ui-text-baseline.txt" > /dev/null; rc=$?
		set -e
		[ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { echo "refusing: there are NEW violations (fix the strings; the baseline may only shrink)" >&2; G "$T/ui-text-baseline.txt" | grep '^NEW ' >&2; exit 1; }
		G - --write-baseline "$T/ui-text-baseline.txt" | grep -E '^(STRINGS|VIOLATIONS|WROTE)' ;;
	--init-baseline)   # one-time bootstrap ONLY: refuses once a baseline exists (no back door)
		[ -e "$HERE/ui-text-baseline.txt" ] && { echo "refusing: $HERE/ui-text-baseline.txt exists — the baseline may only shrink (use --update-baseline)" >&2; exit 1; }
		G - --write-baseline "$T/ui-text-baseline.txt" | grep -E '^(STRINGS|VIOLATIONS|WROTE)' || true ;;
	*) echo "usage: $0 [check|--update-baseline]" >&2; exit 2 ;;
esac
