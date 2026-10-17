#!/bin/sh
# vpnpool: the exit of the tunnel for the Overview — the public IP and country the active node
# shows to the internet. Run by the daemon in the background (vpnpoold exit_info_check) when the
# active node changes and then at most every 30 min while the tunnel works (5 min after a failed
# lookup), never per dashboard poll: ONE request through the local test port (it egresses via the
# active node) to the first IP-echo service that answers — the same services, in the same order,
# as the "test exit" of the Diagnostics (rpcd conntest).
#   exitip.sh <tag of the active node>
# Writes /tmp/vpnpool/exit.json atomically: {ok, ip, country, node, at}; ok=false (ip "") when no
# service answered. status.uc shows it only while <node> is still the active node.
. /usr/libexec/vpnpool/lib.sh 2>/dev/null
NODE=$1
[ -n "$NODE" ] || exit 0
mkdir -p "$SB_DATA"
LOCK="$SB_DATA/.exitip-running"
clear_stale_lock "$LOCK" 120
[ -f "$LOCK" ] && exit 0
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

TP=$(uci -q get vpnpool.main.test_port); [ -n "$TP" ] || TP=1605
IP=""; CO=""
for url in $(exit_ip_services); do
	J=$(curl -s -m 7 --proxy "socks5h://127.0.0.1:$TP" "$url" 2>/dev/null)
	[ -n "$J" ] || continue
	IP=$(printf '%s' "$J" | jq -r '(.ip // .ip_addr // .query // "") | tostring' 2>/dev/null)
	# an IPv4 / IPv6 address only (an error page or a word like "cafe" is not an address)
	case "$IP" in (*[!0-9a-fA-F:.]*|'') IP=""; continue ;; esac
	case "$IP" in (*[.:]*) ;; (*) IP=""; continue ;; esac
	CO=$(printf '%s' "$J" | jq -r '(.country_iso // .country_code // .country // "") | tostring' 2>/dev/null)
	case "$CO" in ([A-Za-z][A-Za-z]) ;; (*) CO="" ;; esac
	break
done
jq -nc --arg ip "$IP" --arg co "$CO" --arg node "$NODE" --argjson at "$(date +%s)" \
	'{ok: ($ip != ""), ip: $ip, country: ($co | ascii_upcase), node: $node, at: $at}' | write_atomic "$SB_DATA/exit.json"
exit 0
