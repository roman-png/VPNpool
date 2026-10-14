#!/bin/sh
# Run the stand test suite in a throw-away container, from the host (Linux, macOS, Git Bash).
#   stand/tests/run-in-docker.sh                 # all suites
#   stand/tests/run-in-docker.sh parser build    # selected suites
# Env:
#   REPO_DIR   repo checkout to test (default: this script's repo). Point it at a COPY of the
#              tree to run a negative control on deliberately broken code.
#   IMAGE      stand image (default vpnpool-stand; build: docker build -f stand/Dockerfile -t vpnpool-stand .)
#   T_VERBOSE  1 = print PASS lines and XFAIL reasons
# The container has NO network (--network none): every HTTP call goes to the curl test double.
# NET_ADMIN: the daemon suite applies the real nft/ip routing inside the container's own netns.
# Exit code = the runner's (non-zero if any test failed or an xfail unexpectedly passed).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-vpnpool-stand}

hostpath() {   # Git Bash on Windows: docker needs C:/... paths
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
R=$(hostpath "$REPO_DIR")

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
	echo "image $IMAGE not found — build it: docker build -f stand/Dockerfile -t $IMAGE ." >&2; exit 2; }

NAME="vpnpool-tests-$$"
# MSYS_NO_PATHCONV: stop Git Bash from rewriting the in-container paths below.
MSYS_NO_PATHCONV=1 exec docker run --rm --name "$NAME" --network none --cap-add NET_ADMIN \
	-e T_VERBOSE="${T_VERBOSE:-0}" \
	-v "$R/package/vpnpool/files/usr/libexec/vpnpool:/usr/libexec/vpnpool:ro" \
	-v "$R/package/luci-app-vpnpool/files/usr/libexec/rpcd:/stage/rpcd:ro" \
	-v "$R/stand:/work:ro" \
	-v "$R:/repo:ro" \
	--entrypoint /bin/sh "$IMAGE" /repo/stand/tests/run.sh "$@"
