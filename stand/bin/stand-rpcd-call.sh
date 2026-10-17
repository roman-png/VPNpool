#!/bin/sh
# Invoke an rpcd backend method two ways: directly (authoritative) and via real ubus.
# Usage: stand-rpcd-call.sh <method> '<json-args>'   e.g. set_option '{"name":"check_services","value":"https://www.youtube.com/generate_204"}'
M="$1"; ARGS="${2:-{}}"
echo "=== direct: vpnpool call $M $ARGS ==="
printf '%s' "$ARGS" | /usr/libexec/rpcd/vpnpool call "$M" | jq . 2>/dev/null || true
echo "=== via ubus: ubus call vpnpool $M $ARGS ==="
ubus call vpnpool "$M" "$ARGS" 2>/dev/null | jq . 2>/dev/null || echo "(ubus path unavailable; direct path above is authoritative)"
