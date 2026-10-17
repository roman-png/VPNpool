#!/bin/sh
# Build the client's vless reality+vision link from the stand env and put it in uci manual_node,
# so the REAL build.sh (parser.uc -> generator.uc -> sing-box check) produces the client config.
# Usage: make-client-link.sh [SERVER] [PORT]  (default 127.0.0.1 8443 = local reality server)
set -e
. /etc/vpnpool/.stand.env
SERVER="${1:-127.0.0.1}"; PORT="${2:-8443}"
LINK="vless://${REALITY_UUID}@${SERVER}:${PORT}?type=tcp&security=reality&pbk=${REALITY_PUBKEY}&sid=${REALITY_SHORTID}&sni=${REALITY_SNI}&fp=chrome&flow=xtls-rprx-vision&spx=%2F#stand-reality-vision"
uci -q delete vpnpool.main.manual_node 2>/dev/null || true
uci add_list vpnpool.main.manual_node="$LINK"
uci commit vpnpool
echo "[make-client-link] manual_node = $LINK"
