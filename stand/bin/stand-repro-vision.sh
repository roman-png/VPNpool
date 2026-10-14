#!/bin/sh
# HEADLINE TEST. Issue the byte-identical clash delay request that nodecheck.sh:89 makes,
# varying ONLY the probe URL scheme (http:// vs https://). A working Vision outbound that
# FAILS on http but PASSES on https isolates the bug to the probe scheme, not a dead node.
CL=${CLASH:-127.0.0.1:9091}
TAG=${1:-stand-reality-vision}
enc=$(jq -rn --arg s "$TAG" '$s|@uri')

probe() {  # $1 = service URL exactly as check_probe_urls would emit it
	eu=$(jq -rn --arg s "$1" '$s|@uri')
	curl -s -m 8 "http://$CL/proxies/$enc/delay?url=$eu&timeout=5000"
}

# Warm-up: first delay through a fresh Reality+Vision outbound can be slow.
probe "https://www.gstatic.com/generate_204" >/dev/null 2>&1

echo "== HTTP probe (current default: bare host -> http://host/generate_204, port 80, no TLS) =="
R_HTTP=$(probe "http://www.youtube.com/generate_204");  echo "  $R_HTTP"
echo "== HTTPS probe (candidate fix: https://host/generate_204, port 443, TLS) =="
R_HTTPS=$(probe "https://www.youtube.com/generate_204"); echo "  $R_HTTPS"

case "$R_HTTP"  in *'"delay"'*) H=PASS;; *) H=FAIL;; esac
case "$R_HTTPS" in *'"delay"'*) S=PASS;; *) S=FAIL;; esac
echo "RESULT: http=$H https=$S  (nodecheck criterion: reply must contain \"delay\")"
if [ "$H" = FAIL ] && [ "$S" = PASS ]; then echo "BUG REPRODUCED (http fails, https works through Vision)"; exit 0; fi
if [ "$H" = PASS ] && [ "$S" = PASS ]; then echo "NOT reproduced: both schemes pass (cause is elsewhere)"; exit 1; fi
echo "INCONCLUSIVE: http=$H https=$S (check the outbound is actually up — see stand-clash.sh)"; exit 2
