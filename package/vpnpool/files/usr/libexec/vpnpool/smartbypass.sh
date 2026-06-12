#!/bin/sh
# vpnpool smart-bypass orchestration: drive a SEPARATE zapret install (remittor
# zapret-openwrt) into autohostlist mode so nfqws self-learns DPI-blocked domains
# and defeats them on a DIRECT connection (no proxy, survives proxy throttling).
#
# We never bundle nfqws — we only orchestrate an installed zapret (detected via its
# uci config + init script). Coexistence with our tproxy is by design: zapret uses
# its own nft table + fwmark 0x40000000 (ours is 0x400000), NFQUEUE on post/prerouting.
#
#   smartbypass.sh detect   -> "1" if a manageable zapret is present, else "0"
#   smartbypass.sh apply     -> reconcile zapret MODE_FILTER with vpnpool.main.smart_bypass
#   smartbypass.sh status     -> JSON { present, enabled, mode, auto_count }
. /usr/libexec/vpnpool/lib.sh 2>/dev/null

ZAPRET_INIT=/etc/init.d/zapret
PREVMODE_FILE=/etc/vpnpool/zapret.prevmode
AUTO_LIST=/opt/zapret/ipset/zapret-hosts-auto.txt

# A zapret we can manage = its init script + its uci config section both exist.
zapret_present() {
	[ -x "$ZAPRET_INIT" ] && uci -q get zapret.config >/dev/null 2>&1
}

auto_count() {
	# self-learned domains so far (comments/blank lines excluded). NOTE: `grep -c`
	# prints 0 AND exits 1 on no-match, so `grep -c || echo 0` would emit "0\n0" and
	# break --argjson — capture via command substitution (ignores the exit code).
	[ -f "$AUTO_LIST" ] || { echo 0; return; }
	c=$(grep -cE '^[a-z0-9]' "$AUTO_LIST" 2>/dev/null)
	echo "${c:-0}"
}

case "$1" in
detect)
	zapret_present && echo 1 || echo 0
	;;
apply)
	# Reconcile the running zapret mode with our opt-in flag. Idempotent and
	# reversible: we remember the user's original MODE_FILTER the first time we
	# switch it on, and restore exactly that on switch-off — never clobbering a
	# mode the user set themselves.
	zapret_present || { echo '{"ok":false,"reason":"zapret not present"}'; exit 0; }
	want=$(uci -q get vpnpool.main.smart_bypass); [ -n "$want" ] || want=0
	cur=$(uci -q get zapret.config.MODE_FILTER); [ -n "$cur" ] || cur=hostlist
	mkdir -p /etc/vpnpool
	if [ "$want" = 1 ]; then
		if [ "$cur" != autohostlist ]; then
			# stash the prior mode once (don't overwrite a stash we already own)
			[ -f "$PREVMODE_FILE" ] || printf '%s' "$cur" > "$PREVMODE_FILE"
			uci set zapret.config.MODE_FILTER='autohostlist'
			uci commit zapret
			"$ZAPRET_INIT" restart >/dev/null 2>&1
		fi
		echo '{"ok":true,"mode":"autohostlist"}'
	else
		# restore the user's original mode (default hostlist) and forget the stash
		prev=hostlist
		[ -f "$PREVMODE_FILE" ] && prev=$(cat "$PREVMODE_FILE" 2>/dev/null)
		[ -n "$prev" ] || prev=hostlist
		if [ "$cur" = autohostlist ] && [ -f "$PREVMODE_FILE" ]; then
			uci set zapret.config.MODE_FILTER="$prev"
			uci commit zapret
			"$ZAPRET_INIT" restart >/dev/null 2>&1
		fi
		rm -f "$PREVMODE_FILE"
		echo "{\"ok\":true,\"mode\":\"$prev\"}"
	fi
	;;
status)
	if zapret_present; then
		mode=$(uci -q get zapret.config.MODE_FILTER); [ -n "$mode" ] || mode=hostlist
		en=$(uci -q get vpnpool.main.smart_bypass); [ -n "$en" ] || en=0
		jq -n --argjson present true \
			--argjson enabled "$([ "$en" = 1 ] && echo true || echo false)" \
			--arg mode "$mode" \
			--argjson auto "$(auto_count)" \
			'{present:$present, enabled:$enabled, mode:$mode, auto_count:$auto}'
	else
		echo '{"present":false,"enabled":false,"mode":"","auto_count":0}'
	fi
	;;
*)
	echo "usage: $0 detect|apply|status" >&2; exit 1 ;;
esac
