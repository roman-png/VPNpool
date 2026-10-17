#!/usr/bin/env bash
# Deploy vpnpool package files to an OpenWrt router over SSH (dev helper).
#
# Optionally hops through a jump host (set JUMP_HOST):
#   workstation --ssh--> [jump host] --ssh--> router
#
# Tars the "files/" trees of BOTH packages (vpnpool + luci-app-vpnpool) and extracts them at
# / on the router, then fixes exec bits, refreshes rpcd/LuCI caches and (optionally) restarts
# the service.
#
# The live uci config is NEVER overwritten: ./etc/config is excluded from the tarball
# (package/vpnpool/files/etc/config/vpnpool is only the first-install default — copying it
# over a configured router wipes the user's subscription, nodes and settings).
#
# Configure entirely via environment variables (no hosts are hard-coded):
#   ROUTER_HOST   router SSH target           (default: root@192.168.1.1)
#   JUMP_HOST     optional jump host          (e.g. user@host); empty = direct
#   SSH_KEY       SSH private key for the hop  (default: ~/.ssh/id_ed25519)
#   DEPLOY_LUCI   1 = also deploy luci-app-vpnpool (default), 0 = backend only
#
# Usage:
#   ROUTER_HOST=root@192.168.1.1 scripts/deploy.sh            # deploy files only
#   ROUTER_HOST=root@192.168.1.1 scripts/deploy.sh restart    # deploy + restart
#   scripts/deploy.sh --dry-run                               # list what would be sent, no SSH
#   scripts/deploy.sh --print-tar > x.tgz                     # the checked archive, no SSH
set -euo pipefail

KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
JUMP="${JUMP_HOST:-}"
ROUTER="${ROUTER_HOST:-root@192.168.1.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/package/vpnpool/files"
LUCI_SRC="$ROOT/package/luci-app-vpnpool/files"
DEPLOY_LUCI="${DEPLOY_LUCI:-1}"
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

# The archive is extracted as root into / on the router, and busybox tar applies a member's
# mode AND owner to an EXISTING directory. So the archive must never carry a "./" member (it
# would re-mode/re-own the router's /: mktemp -d is 0700, Git Bash writes uid 1050552), its
# directories are 0755 and owned 0:0, and the router extracts with -o (don't restore owner).
REMOTE_EXTRACT='tar xzof - -C /'

# a path for a native tool (Git Bash on Windows: C:/... for python)
hp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# One tarball with both trees; ./etc/config excluded (never clobber the live uci config).
make_tar() {   # $1 = output file
	local tmp own
	tmp=$(mktemp -d)
	( cd "$SRC" && tar cf - --exclude=./etc/config . ) | ( cd "$tmp" && tar xf - )
	if [ "$DEPLOY_LUCI" = "1" ]; then
		# view/vpnpool/_*.js = stand-only pages (component showcase), never on a router
		( cd "$LUCI_SRC" && tar cf - --exclude=./etc/config --exclude='./www/luci-static/resources/view/vpnpool/_*' . ) | ( cd "$tmp" && tar xf - )
		# the Russian translation, as the luci-i18n-vpnpool-ru package installs it (po2lmo port;
		# the router's LuCI shows it when its language is Russian or "auto" with a Russian browser)
		local py; py=$(command -v python3 || command -v python || true)
		if [ -n "$py" ] && mkdir -p "$tmp/usr/lib/lua/luci/i18n" \
			&& "$py" -I "$(hp "$ROOT/stand/tests/po2lmo.py")" "$(hp "$ROOT/package/luci-app-vpnpool/po/ru/vpnpool.po")" "$(hp "$tmp/usr/lib/lua/luci/i18n/vpnpool.ru.lmo")" >/dev/null; then :
		else echo "warning: no python3 — the Russian translation is not deployed" >&2; fi
	fi
	chmod 755 "$tmp"
	find "$tmp" -type d -exec chmod 755 {} +
	if tar --version 2>/dev/null | grep -q 'GNU tar'; then own="--owner=0 --group=0 --numeric-owner"
	else own="--uid 0 --gid 0"; fi   # bsdtar (macOS)
	# members are the top-level entries (etc lib usr www), NOT "." -> no "./" member
	# shellcheck disable=SC2046,SC2086
	tar -C "$tmp" $own -czf "$1" $(cd "$tmp" && ls -A)
	rm -rf "$tmp"
}

# Refuse to send an archive that could hurt the router (checked on EVERY deploy, not just --dry-run).
check_tar() {   # $1 = archive
	local names
	names=$(tar tzf "$1")
	if printf '%s\n' "$names" | grep -qxE '\./?|\.'; then echo "ERROR: archive has a './' member (would re-mode/re-own /)" >&2; return 1; fi
	if printf '%s\n' "$names" | grep -qE '^(\./)?etc/config(/|$)'; then echo "ERROR: etc/config would be deployed" >&2; return 1; fi
	if tar --version 2>/dev/null | grep -q 'GNU tar'; then
		if tar --numeric-owner -tvzf "$1" | awk '{print $2}' | grep -qv '^0/0$'; then echo "ERROR: archive members not owned by 0:0" >&2; return 1; fi
	fi
	return 0
}

ARCHIVE=$(mktemp)
trap 'rm -f "$ARCHIVE"' EXIT
make_tar "$ARCHIVE"
check_tar "$ARCHIVE"

case "$ACTION" in
	--dry-run)   tar tvzf "$ARCHIVE" --numeric-owner 2>/dev/null || tar tvzf "$ARCHIVE"; exit 0 ;;
	--print-tar) cat "$ARCHIVE"; exit 0 ;;   # for stand/tests/deploy-tar-test.sh
esac

WHAT=vpnpool; [ "$DEPLOY_LUCI" = "1" ] && WHAT="vpnpool + luci-app-vpnpool"
echo ">> Deploying $WHAT  ->  $ROUTER:/  ${JUMP:+(via $JUMP)}  (etc/config excluded)"
# rpcd restart: pick up a changed rpcd plugin / ACL (also logs out open LuCI sessions); drop
# LuCI's index/module caches so a changed menu.d or view is served at once.
router_ssh "'$REMOTE_EXTRACT && chmod +x /etc/init.d/vpnpool /usr/libexec/vpnpool/* /usr/libexec/rpcd/vpnpool 2>/dev/null; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null; /etc/init.d/rpcd restart 2>/dev/null; echo extracted'" < "$ARCHIVE"

if [ "$ACTION" = "restart" ]; then
	echo ">> Enable + restart vpnpool"
	ssh_router '/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart; sleep 1; logread -e vpnpool | tail -5'
fi

echo ">> Done."
