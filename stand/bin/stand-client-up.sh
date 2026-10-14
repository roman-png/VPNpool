#!/bin/sh
# Run the generated client sing-box config (the one build.sh produced) and wait for the
# clash API to come up on :9091. This is the real /etc/vpnpool/sing-box.json under test.
set -e
CFG=/etc/vpnpool/sing-box.json
sing-box check -c "$CFG" || { echo "[client-up] client config invalid"; exit 1; }
for p in $(pgrep -f "sing-box run -c $CFG"); do kill "$p" 2>/dev/null; done
sing-box run -c "$CFG" >/tmp/vpnpool/client.log 2>&1 &
i=0
while ! curl -fsS "http://127.0.0.1:9091/version" >/dev/null 2>&1; do
	sleep 1; i=$((i+1))
	[ $i -gt 30 ] && { echo "[client-up] clash API not ready"; tail -n 20 /tmp/vpnpool/client.log; exit 1; }
done
echo "[client-up] clash API: $(curl -s http://127.0.0.1:9091/version)"
echo "[client-up] proxies: $(curl -s http://127.0.0.1:9091/proxies | jq -c '.proxies|keys')"
