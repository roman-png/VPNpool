#!/bin/sh
# An opkg upgrade 1.4.1 -> 2.0 on the 24.10 stand (opkg; the 25.12 image has apk): which package
# scripts run, in which order, and is the running 1.x daemon stopped BEFORE the 1.x -> 2.0
# migration (uci-defaults, run by the new postinst's default_postinst) rewrites the config?
#   stand/tests/upgrade-opkg-test.sh          (IMAGE=vpnpool-stand, the 24.10 one)
# Two ipk named vpnpool are built inside the container: 1.4.1 with the scripts of the v1.4.1
# Makefile, 2.0 with the scripts of package/vpnpool/Makefile (preinst / postinst / prerm, the
# headers package-pack.mk puts in front of them). Their data: a stub /etc/init.d/vpnpool that logs
# every call (and stops a stand-in daemon on "stop") + the real uci-defaults file; the real
# migrate.sh runs from the mounted package scripts on the 1.4.1 fixture config.
# Prints "UPGRADE: passed=N failed=M"; exit non-zero on any failure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand}
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
R=$(hostpath "$REPO_DIR")
OUT=$(MSYS_NO_PATHCONV=1 docker run --rm --network none --name "vpnpool-upgrade-$$" \
	-v "$R/package/vpnpool/files/usr/libexec/vpnpool:/usr/libexec/vpnpool:ro" -v "$R:/repo:ro" \
	--entrypoint /bin/sh "$IMAGE" /repo/stand/tests/upgrade-opkg-inner.sh 2>&1)
printf '%s\n' "$OUT"
printf '%s\n' "$OUT" | grep -q '^UPGRADE: passed=[1-9][0-9]* failed=0$'
