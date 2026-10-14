#!/bin/sh
# Render + start a local VLESS-Reality + Vision sing-box SERVER on 127.0.0.1:8443.
# Default: reality steering -> SNI:443 (needs egress to that ONE host; may traverse WireGuard).
# --airgap: run a local TLS1.3 responder (openssl s_server) and steer to it => fully offline,
#           WireGuard-independent. Reality clients don't validate the steering cert (key auth),
#           so a self-signed responder is fine.
set -e
. /etc/vpnpool/.stand.env
OUT=/etc/vpnpool/reality-server.json
HS_HOST="$REALITY_SNI"; HS_PORT=443

if [ "$1" = "--airgap" ]; then
	CRT=/etc/vpnpool/airgap.crt; KEY=/etc/vpnpool/airgap.key
	[ -f "$CRT" ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CRT" \
		-days 3650 -subj "/CN=$REALITY_SNI" >/dev/null 2>&1
	for p in $(pgrep -f 'openssl s_server -quiet -accept 8444'); do kill "$p" 2>/dev/null; done
	openssl s_server -quiet -accept 8444 -cert "$CRT" -key "$KEY" -tls1_3 -www \
		>/tmp/vpnpool/airgap-tls.log 2>&1 &
	HS_HOST=127.0.0.1; HS_PORT=8444
	sleep 1
	echo "[reality-up] airgap TLS1.3 responder on 127.0.0.1:8444 (pid $(pgrep -f 'openssl s_server -quiet -accept 8444' | tr '\n' ' '))"
fi

sed -e "s|__UUID__|$REALITY_UUID|g" \
    -e "s|__SNI__|$REALITY_SNI|g" \
    -e "s|__PRIVKEY__|$REALITY_PRIVKEY|g" \
    -e "s|__SHORTID__|$REALITY_SHORTID|g" \
    -e "s|__HSHAKE_HOST__|$HS_HOST|g" \
    -e "s|__HSHAKE_PORT__|$HS_PORT|g" \
    /work/reality-server/server.json.tmpl > "$OUT"

sing-box check -c "$OUT" || { echo "[reality-up] server config invalid:"; cat "$OUT"; exit 1; }
for p in $(pgrep -f "sing-box run -c $OUT"); do kill "$p" 2>/dev/null; done
sing-box run -c "$OUT" >/tmp/vpnpool/reality-server.log 2>&1 &
sleep 2
if pgrep -f "sing-box run -c $OUT" >/dev/null 2>&1; then
	echo "[reality-up] server up on 127.0.0.1:8443 (pid $(pgrep -f "sing-box run -c $OUT" | tr '\n' ' '))"
else
	echo "[reality-up] server FAILED to start:"; tail -n 20 /tmp/vpnpool/reality-server.log; exit 1
fi
