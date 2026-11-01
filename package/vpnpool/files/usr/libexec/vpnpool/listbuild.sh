#!/bin/sh
# vpnpool: rebuild the node lists while the service is OFF (no vpnpoold to signal).
# The Nodes page reads the last build (/tmp/vpnpool/nodes.json); only the daemon used to build,
# so a node added / deleted / renamed / hidden with the VPN off stayed invisible (or visible)
# until the VPN was turned on. Here the same build.sh runs on its own: it writes the lists and
# the config file only — it starts no sing-box and touches no routing.
#   listbuild.sh <USR1|USR2> [--if-missing]
#     USR1 = rebuild from what is stored; USR2 = re-fetch the subscriptions first (as the daemon's
#     USR2); --if-missing = only when there is no list yet (init.d at boot with the service off).
# One run at a time (pidfile with the owner's PID, lib.sh clear_stale_lock); a request that comes
# while a run is going is not lost: the run repeats once more (AGAIN flag). The daemon, when it
# starts, stops this run (vpnpoold stop_listbuild) and builds itself; every round re-checks that
# no daemon is running.
. /usr/libexec/vpnpool/lib.sh

LOCK="$SB_DATA/.listbuild.pid"
AGAIN="$SB_DATA/.listbuild.again"
WHAT=${1:-USR1}

daemon_alive() {
	local p
	p=$(cat /var/run/vpnpool.pid 2>/dev/null); [ -n "$p" ] || return 1
	pgrep -f /usr/libexec/vpnpool/vpnpoold 2>/dev/null | grep -qx "$p"
}

mkdir -p "$SB_DATA"
[ "${2:-}" = --if-missing ] && [ -s "$SB_DATA/nodes.json" ] && exit 0
daemon_alive && exit 0
[ "$WHAT" = USR2 ] && : > "$AGAIN.fetch"
clear_stale_lock "$LOCK"
if [ -f "$LOCK" ]; then : > "$AGAIN"; exit 0; fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
trap 'exit 143' INT TERM HUP

while : ; do
	rm -f "$AGAIN"
	daemon_alive && break
	if [ -f "$AGAIN.fetch" ]; then
		rm -f "$AGAIN.fetch"
		/usr/libexec/vpnpool/fetch.sh >/dev/null 2>&1
	fi
	daemon_alive && break
	/usr/libexec/vpnpool/build.sh >/dev/null 2>&1
	[ -f "$AGAIN" ] || [ -f "$AGAIN.fetch" ] || break
done
exit 0
