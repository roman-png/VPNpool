#!/usr/bin/env bash
# Deploy vpnpool package files to an OpenWrt router over SSH (dev helper).
#
# Optionally hops through a jump host (set JUMP_HOST):
#   workstation --ssh--> [jump host] --ssh--> router
#
# Tars the package "files/" tree and extracts it at / on the router, then fixes
# exec bits and (optionally) restarts the service.
#
# Configure entirely via environment variables (no hosts are hard-coded):
#   ROUTER_HOST   router SSH target           (default: root@192.168.1.1)
#   JUMP_HOST     optional jump host          (e.g. user@host); empty = direct
#   SSH_KEY       SSH private key for the hop  (default: ~/.ssh/id_ed25519)
#
# Usage:
#   ROUTER_HOST=root@192.168.1.1 scripts/deploy.sh            # deploy files only
#   ROUTER_HOST=root@192.168.1.1 scripts/deploy.sh restart    # deploy + restart
set -euo pipefail

KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
JUMP="${JUMP_HOST:-}"
ROUTER="${ROUTER_HOST:-root@192.168.1.1}"
SRC="$(cd "$(dirname "$0")/../package/vpnpool/files" && pwd)"
ACTION="${1:-}"

# Build the SSH command, optionally via a jump host.
router_ssh() {
	if [ -n "$JUMP" ]; then
		ssh -i "$KEY" -o BatchMode=yes -T "$JUMP" "ssh -o BatchMode=yes -T $ROUTER $1"
	else
		ssh -o BatchMode=yes -T "$ROUTER" "$1"
	fi
}

ssh_router() { router_ssh "'$1'"; }

echo ">> Deploying $SRC  ->  $ROUTER:/  ${JUMP:+(via $JUMP)}"
( cd "$SRC" && tar czf - . ) | \
	router_ssh "'tar xzf - -C / && chmod +x /etc/init.d/vpnpool /usr/libexec/vpnpool/* 2>/dev/null; echo extracted'"

if [ "$ACTION" = "restart" ]; then
	echo ">> Enable + restart vpnpool"
	ssh_router '/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart; sleep 1; logread -e vpnpool | tail -5'
fi

echo ">> Done."
