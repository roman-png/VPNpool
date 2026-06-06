#!/usr/bin/env bash
# Deploy vpnpool package files to the OpenWrt router through the Mac (Tailscale) SSH bridge.
#
#   Windows/bash --ssh--> Mac (roman@100.78.108.47) --ssh--> router (root@192.168.10.1)
#
# Tars the package "files/" tree and extracts it at / on the router, then fixes
# exec bits and (optionally) restarts the service.
#
# Usage:
#   scripts/deploy.sh            # deploy files only
#   scripts/deploy.sh restart    # deploy + enable + restart service
set -euo pipefail

KEY="${MAC_SSH_KEY:-$HOME/.ssh/mac-mcp-key}"
MAC="${MAC_HOST:-roman@100.78.108.47}"
ROUTER="${ROUTER_HOST:-root@192.168.10.1}"
SRC="$(cd "$(dirname "$0")/../package/vpnpool/files" && pwd)"
ACTION="${1:-}"

ssh_router() {
	# Run a command on the router via the Mac hop.
	ssh -i "$KEY" -o BatchMode=yes -T "$MAC" "ssh -o BatchMode=yes -T $ROUTER '$1'"
}

echo ">> Deploying $SRC  ->  $ROUTER:/  (via $MAC)"
( cd "$SRC" && tar czf - . ) | \
	ssh -i "$KEY" -o BatchMode=yes -T "$MAC" \
		"ssh -o BatchMode=yes -T $ROUTER 'tar xzf - -C / && chmod +x /etc/init.d/vpnpool /usr/libexec/vpnpool/* 2>/dev/null; echo extracted'"

if [ "$ACTION" = "restart" ]; then
	echo ">> Enable + restart vpnpool"
	ssh_router '/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart; sleep 1; logread -e vpnpool | tail -5'
fi

echo ">> Done."
