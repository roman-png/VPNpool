#!/bin/sh
# Generate a reality keypair + uuid + short_id, write /etc/vpnpool/.stand.env.
# Idempotent: regenerates only with --force.
set -e
ENV=/etc/vpnpool/.stand.env
[ "$1" = "--force" ] && rm -f "$ENV"
if [ -f "$ENV" ]; then echo "[gen-reality] $ENV exists (use --force to regen):"; cat "$ENV"; exit 0; fi

kp=$(sing-box generate reality-keypair)
priv=$(printf '%s\n' "$kp" | sed -n 's/.*PrivateKey:[[:space:]]*//p')
pub=$(printf  '%s\n' "$kp" | sed -n 's/.*PublicKey:[[:space:]]*//p')
uuid=$(sing-box generate uuid)
sid=$(sing-box generate rand 8 --hex)
sni=${STAND_SNI:-www.microsoft.com}

[ -n "$priv" ] && [ -n "$pub" ] || { echo "[gen-reality] keypair parse failed; raw:"; echo "$kp"; exit 1; }

{
  echo "REALITY_PRIVKEY=$priv"
  echo "REALITY_PUBKEY=$pub"
  echo "REALITY_UUID=$uuid"
  echo "REALITY_SHORTID=$sid"
  echo "REALITY_SNI=$sni"
} > "$ENV"
echo "[gen-reality] wrote $ENV:"; cat "$ENV"
