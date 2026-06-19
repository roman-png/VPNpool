#!/bin/sh
# Drive the REAL build.sh (parser.uc + generator.uc + sing-box check + prune + reconcile)
# and show what it produced. No package script is modified.
mkdir -p /tmp/vpnpool/sources
sh /usr/libexec/vpnpool/build.sh
rc=$?
echo "=== build.sh rc=$rc ==="
echo "=== build.err ==="; cat /tmp/vpnpool/build.err 2>/dev/null
echo "=== check.err ==="; cat /tmp/vpnpool/check.err 2>/dev/null
echo "=== nodes.json tags ==="; jq -r '.[].tag' /tmp/vpnpool/nodes.json 2>/dev/null
echo "=== urltest.url (the probe scheme) ==="; jq -r '.outbounds[]|select(.type=="urltest").url' /etc/vpnpool/sing-box.json 2>/dev/null
printf "=== reality+vision outbound present? "; jq -e '.outbounds[]|select(.tag=="stand-reality-vision")' /etc/vpnpool/sing-box.json >/dev/null 2>&1 && echo "YES ===" || echo "NO ==="
exit $rc
