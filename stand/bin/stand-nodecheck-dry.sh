#!/bin/sh
# Run the REAL nodecheck.sh in dry-run (compute dead set, don't signal a rebuild) and dump
# the verdict. Shows whether the shipped dead-filter marks our Vision node dead.
echo "=== check_services = $(uci -q get vpnpool.main.check_services) ==="
echo "=== dead_filter_strikes = $(uci -q get vpnpool.main.dead_filter_strikes) ==="
NODECHECK_DRYRUN=1 sh /usr/libexec/vpnpool/nodecheck.sh
echo "=== .deadstrikes ==="; cat /tmp/vpnpool/.deadstrikes 2>/dev/null; echo
echo "=== .dead_tags.json ==="; cat /tmp/vpnpool/.dead_tags.json 2>/dev/null; echo
