#!/bin/sh
# vpnpool: parse all fetched source files + manual nodes into one node list,
# generate the sing-box config, and validate it. Keeps the previous config if
# the new one fails sing-box check.
. /usr/libexec/vpnpool/lib.sh

mkdir -p "$SB_DATA"
SRCDIR="$SB_DATA/sources"
NODES="$SB_DATA/nodes.json"

# manual nodes (uci: list manual_node 'vless://...') as their own file
: > "$SB_DATA/manual.links"
uci -q get vpnpool.main.manual_node 2>/dev/null | tr ' ' '\n' >> "$SB_DATA/manual.links"

# gather input files: every source file + manual links (parser auto-detects format
# per file and merges with global dedup + unique tags)
FILES=""
for f in "$SRCDIR"/*.raw; do
	[ -f "$f" ] && FILES="$FILES $f"
done
[ -s "$SB_DATA/manual.links" ] && FILES="$FILES $SB_DATA/manual.links"

# shellcheck disable=SC2086
ucode /usr/libexec/vpnpool/parser.uc $FILES > "$NODES" 2>"$SB_DATA/build.err"
CNT=$(jq 'length' "$NODES" 2>/dev/null || echo 0)
if [ "${CNT:-0}" -lt 1 ]; then
	log "build: 0 nodes parsed (see $SB_DATA/build.err)"
	exit 1
fi

ucode /usr/libexec/vpnpool/generator.uc "$NODES" > "$SB_CONF.new" 2>>"$SB_DATA/build.err"

# Resilient validation. A SINGLE malformed node (unsupported flow, reality without
# uTLS, bad cipher, …) makes `sing-box check` reject the ENTIRE config — so one bad
# entry in a big public list would otherwise take the whole VPN down. Instead, when
# check fails on a specific outbound[N], drop just that node outbound (and its tag
# from the urltest/selector groups) and re-check, up to a bounded number of times.
dropped=0; tries=0
while ! sing-box check -c "$SB_CONF.new" 2>"$SB_DATA/check.err"; do
	tries=$((tries + 1))
	if [ "$tries" -gt 50 ]; then
		log "build: >50 bad outbounds, giving up; keeping previous config"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; rm -f "$SB_CONF.new"; exit 1
	fi
	idx=$(grep -oE 'outbound\[[0-9]+\]' "$SB_DATA/check.err" | head -1 | grep -oE '[0-9]+')
	if [ -z "$idx" ]; then
		log "build: sing-box check failed (non-outbound error), keeping previous config"
		cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; rm -f "$SB_CONF.new"; exit 1
	fi
	badtype=$(jq -r ".outbounds[$idx].type // \"\"" "$SB_CONF.new" 2>/dev/null)
	case "$badtype" in
		vless|vmess|trojan|shadowsocks|shadowtls|hysteria|hysteria2|tuic|wireguard|socks|http) ;;
		*)  # structural outbound (auto/proxy/direct/block) failed — don't gut the config
			log "build: check failed on non-node outbound[$idx] ($badtype), keeping previous config"
			cat "$SB_DATA/check.err" >> "$SB_DATA/build.err"; rm -f "$SB_CONF.new"; exit 1 ;;
	esac
	badtag=$(jq -r ".outbounds[$idx].tag // \"\"" "$SB_CONF.new" 2>/dev/null)
	jq --argjson i "$idx" --arg t "$badtag" '
		del(.outbounds[$i])
		| .outbounds |= map(
			if (.type=="urltest" or .type=="selector") and (.outbounds|type=="array")
			then .outbounds -= [$t] else . end)
	' "$SB_CONF.new" > "$SB_CONF.tmp" 2>/dev/null && mv "$SB_CONF.tmp" "$SB_CONF.new" || {
		log "build: failed to prune bad outbound, keeping previous config"; rm -f "$SB_CONF.new" "$SB_CONF.tmp"; exit 1; }
	dropped=$((dropped + 1))
done

mv "$SB_CONF.new" "$SB_CONF"
if [ "$dropped" -gt 0 ]; then
	log "build: ok ($((CNT - dropped)) nodes; dropped $dropped unsupported)"
else
	log "build: ok ($CNT nodes)"
fi
exit 0
