#!/bin/sh
# Package shell scripts are run by path ([ -x ... ] && /usr/libexec/vpnpool/x.sh), so their git
# mode must be 100755. The Windows stand mount shows every file executable and can't see a lost
# bit; a Linux checkout (CI, a router hot-patch) silently skips the script.
#   stand/tests/exec-bits.sh          # the index (what the next commit holds)
#   stand/tests/exec-bits.sh REV      # a commit (negative control: one with a lost bit)
# Prints EXEC-BITS: checked=N failed=M; exit 1 if any failed or nothing was checked.
set -eu
cd "$(dirname "$0")/../.."
if [ $# -gt 0 ]; then
	list() { git ls-tree -r "$1" -- package | awk -F'\t' '{split($1, a, " "); print a[1] "\t" $2}'; }
	read_head() { git cat-file -p "$1:$2" 2>/dev/null | head -c 32; }
else
	list() { git ls-files -s -- package | awk -F'\t' '{split($1, a, " "); print a[1] "\t" $2}'; }
	read_head() { git cat-file -p ":$2" 2>/dev/null | head -c 32; }
fi
REV=${1:-}
checked=0; failed=0
TMP=$(mktemp)
list "$REV" > "$TMP"
while IFS="$(printf '\t')" read -r mode path; do
	case "$path" in package/*/files/*) ;; *) continue ;; esac
	first=$(read_head "$REV" "$path" | head -n 1)
	case "$first" in '#!/bin/sh'*|'#!/bin/ash'*|'#!/bin/bash'*) ;; *) continue ;; esac
	checked=$((checked + 1))
	if [ "$mode" != 100755 ]; then
		failed=$((failed + 1)); echo "FAIL  $path: mode $mode, a shell script must be 100755 (git update-index --chmod=+x)"
	fi
done < "$TMP"
rm -f "$TMP"
echo "EXEC-BITS: checked=$checked failed=$failed"
[ "$failed" -eq 0 ] && [ "$checked" -gt 0 ]
