#!/bin/sh
# Check scripts/deploy.sh's archive against a real busybox tar (the stand image, as root):
# extracting it the way the router does must NOT change mode/owner of the target root or of
# existing directories, and must not touch an existing etc/config/vpnpool.
# Negative control: an archive built the OLD way (a "./" member from a 0700 dir, foreign uid,
# extracted without -o) MUST change them — otherwise this test could not see the bug.
#   stand/tests/deploy-tar-test.sh     -> "DEPLOY-TAR: passed=N failed=M", exit != 0 on failure
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand}
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
bash "$REPO_DIR/scripts/deploy.sh" --print-tar > "$W/new.tgz" || { echo "FAIL - deploy.sh refused to build the archive"; echo "DEPLOY-TAR: passed=0 failed=1"; exit 1; }
# the exact extract command deploy.sh runs on the router, retargeted from / to /fr
sed -n "s/^REMOTE_EXTRACT='\(.*\)'$/\1/p" "$REPO_DIR/scripts/deploy.sh" > "$W/extract.cmd"
[ -s "$W/extract.cmd" ] || { echo "FAIL - REMOTE_EXTRACT not found in deploy.sh"; echo "DEPLOY-TAR: passed=0 failed=1"; exit 1; }
cat > "$W/check.sh" <<'EOF'
P=0; F=0
ok()  { P=$((P+1)); echo "ok   - $1"; }
bad() { F=$((F+1)); echo "FAIL - $1"; }
mkroot() {   # $1 = dir: a router-like root with existing dirs and a LIVE config
	mkdir -p "$1/etc/config" "$1/usr/libexec" "$1/www" "$1/lib"
	chmod 755 "$1" "$1/etc" "$1/etc/config" "$1/usr" "$1/usr/libexec" "$1/www" "$1/lib"
	chown -R 0:0 "$1"; echo LIVE > "$1/etc/config/vpnpool"
}
modes() { for d in "" /etc /usr /www /lib; do ls -ldn "$1$d" | awk '{printf "%s:%s ", $1, $3}'; done; }   # busybox: no stat
WANT="drwxr-xr-x:0 drwxr-xr-x:0 drwxr-xr-x:0 drwxr-xr-x:0 drwxr-xr-x:0 "
EXTRACT=$(sed 's#-C /$#-C /fr#' /w/extract.cmd)

mkroot /fr
echo "router extract command (retargeted): $EXTRACT"
sh -c "$EXTRACT" < /w/new.tgz && ok "archive extracts" || bad "archive extracts"
m=$(modes /fr)
[ "$m" = "$WANT" ] && ok "root + existing dirs keep 755 root ($m)" || bad "root/dirs changed: $m"
[ "$(cat /fr/etc/config/vpnpool)" = LIVE ] && ok "live etc/config/vpnpool untouched" || bad "etc/config/vpnpool overwritten"
[ -f /fr/usr/libexec/vpnpool/status.sh ] && [ -f /fr/usr/libexec/rpcd/vpnpool ] && [ -f /fr/www/luci-static/resources/view/vpnpool/dashboard.js ] \
	&& ok "backend + rpcd plugin + luci views delivered" || bad "payload incomplete"

# negative control: the OLD way (tar of "." from a 0700 temp dir with a foreign uid, no -o)
mkdir -p /old && tar xzf /w/new.tgz -C /old && chmod 700 /old && chown -R 1234:1234 /old
tar czf /w/old.tgz -C /old .
mkroot /fr2
tar xzf - -C /fr2 < /w/old.tgz
m2=$(modes /fr2)
[ -n "$m2" ] && [ "$m2" != "$WANT" ] && ok "control: old-style archive DOES change root/dirs ($m2)" || bad "control void: old archive changed nothing ($m2)"
echo "DEPLOY-TAR: passed=$P failed=$F"
[ "$F" -eq 0 ] && [ "$P" -gt 0 ]
EOF
MSYS_NO_PATHCONV=1 docker run --rm --network none -v "$(hostpath "$W"):/w" --entrypoint /bin/sh "$IMAGE" /w/check.sh
