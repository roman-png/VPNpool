#!/bin/sh
# Inspect the live clash API (the same endpoint nodecheck/vpnpoold use).
CL=${CLASH:-127.0.0.1:9091}
echo "=== /version ==="; curl -s "http://$CL/version"; echo
echo "=== /proxies keys ==="; curl -s "http://$CL/proxies" | jq -r '.proxies|keys[]' 2>/dev/null
echo "=== proxy.now ==="; curl -s "http://$CL/proxies/proxy" | jq -r '.now' 2>/dev/null
echo "=== auto.now ==="; curl -s "http://$CL/proxies/auto" | jq -r '.now' 2>/dev/null
if [ -n "$1" ]; then
	echo "=== history for $1 ==="; curl -s "http://$CL/proxies" | jq -c --arg t "$1" '.proxies[$t].history' 2>/dev/null
fi
