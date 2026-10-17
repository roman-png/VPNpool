#!/bin/sh
# Stand stand-in for vpnpoold, used by the rpcd suite to observe signals.
# Launched by path .../usr/libexec/vpnpool/vpnpoold so `pgrep -f /usr/libexec/vpnpool/vpnpoold`
# (lib.sh signal_daemon, status.sh) recognises it; writes its PID to /var/run/vpnpool.pid
# and appends every USR1/USR2/HUP it receives to $FAKED_LOG.
FAKED_LOG=${FAKED_LOG:-/tmp/vpnpool-tests/daemon.signals}
echo $$ > /var/run/vpnpool.pid
trap 'echo USR1 >> "$FAKED_LOG"' USR1
trap 'echo USR2 >> "$FAKED_LOG"' USR2
trap 'echo HUP >> "$FAKED_LOG"' HUP
trap 'exit 0' TERM INT
while :; do sleep 1 & wait $!; done
