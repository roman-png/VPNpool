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
if sing-box check -c "$SB_CONF.new" 2>>"$SB_DATA/build.err"; then
	mv "$SB_CONF.new" "$SB_CONF"
	log "build: ok ($CNT nodes)"
	exit 0
fi

log "build: sing-box check FAILED, keeping previous config"
rm -f "$SB_CONF.new"
exit 1
