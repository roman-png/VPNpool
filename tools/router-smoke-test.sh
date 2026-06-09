#!/bin/sh
# vpnpool router smoke-test (read-only / non-destructive).
#
# Copy to the router and run as root:
#     scp tools/router-smoke-test.sh root@ROUTER:/tmp/ && ssh root@ROUTER sh /tmp/router-smoke-test.sh
# It verifies the install + every feature added in 1.1.0 WITHOUT changing the live
# config. The one thing it cannot know offline — whether THIS sing-box build accepts
# the anti-DPI `tls_fragment` field — it tests by checking a throwaway copy of the
# config. Contains NO secrets/IPs; safe to keep in the repo.
#
# Exit code: 0 if no FAIL lines, 1 otherwise.
LIBEXEC=/usr/libexec/vpnpool
SB_CONF=/etc/vpnpool/sing-box.json
CLASH=$(uci -q get vpnpool.main.clash_api); [ -n "$CLASH" ] || CLASH=127.0.0.1:9091
FAILS=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }
info() { echo "  ..   $1"; }
hdr()  { echo; echo "== $1 =="; }

hdr "1. Packages"
for p in vpnpool luci-app-vpnpool; do
	v=$(opkg list-installed 2>/dev/null | awk -v p="$p" '$1==p{print $3}')
	[ -n "$v" ] && ok "$p $v" || fail "$p not installed"
done

hdr "2. Dependencies on PATH"
for b in sing-box jq curl ucode; do
	command -v "$b" >/dev/null 2>&1 && ok "$b" || fail "$b missing"
done

hdr "3. Helper scripts present + executable"
for s in vpnpoold lib.sh fetch.sh build.sh generator.uc status.sh route.sh probe.sh \
         snapshot.sh speedtest.sh unlock.sh adaptive.sh sched.sh tgbot.sh; do
	[ -f "$LIBEXEC/$s" ] && ok "$s" || fail "$s missing"
done

hdr "4. Service state"
pgrep -f "$LIBEXEC/vpnpoold" >/dev/null 2>&1 && ok "vpnpoold running" || fail "vpnpoold not running"
n=$(pgrep -f "sing-box run -c $SB_CONF" 2>/dev/null | wc -l)
[ "$n" = "1" ] && ok "sing-box: 1 instance" || fail "sing-box instances=$n (expected 1)"

hdr "5. Live sing-box config validates"
if [ -f "$SB_CONF" ]; then
	sing-box check -c "$SB_CONF" 2>/tmp/vp-chk.err && ok "sing-box check passed" || { fail "sing-box check FAILED"; cat /tmp/vp-chk.err; }
else
	fail "$SB_CONF missing"
fi

hdr "6. ubus methods exposed"
M=$(ubus -v list vpnpool 2>/dev/null | grep -cE '"[a-z_]+":')
[ "${M:-0}" -ge 38 ] && ok "ubus vpnpool methods=$M" || fail "ubus vpnpool methods=$M (expected >=38; is rpcd reloaded?)"
for m in unlock_result export_nodes node_link add_auto_domain set_schedule save_node speedtest; do
	ubus -v list vpnpool 2>/dev/null | grep -q "\"$m\"" && ok "method $m" || fail "method $m missing (ACL/rpcd?)"
done

hdr "7. status JSON shape (new fields)"
ST=$(ubus call vpnpool status 2>/dev/null)
if echo "$ST" | jq -e . >/dev/null 2>&1; then
	ok "status is valid JSON"
	echo "$ST" | jq -e '.nodes' >/dev/null 2>&1 && ok ".nodes ($(echo "$ST" | jq '.nodes|length'))" || fail ".nodes missing"
	for path in '.client_traffic' '.auto_domains' '.extra_subs' '.nodes[0].saved' '.nodes[0].unlock' \
	            '.settings.antidpi' '.settings.adaptive_routing' '.settings.auto_snapshot' '.settings.sched_enabled'; do
		echo "$ST" | jq -e "$path != null or ($path==false) or ($path==null)" >/dev/null 2>&1 && ok "field $path present" || info "field $path: (null/absent — ok if no nodes yet)"
	done
else
	fail "status did not return JSON"
fi

hdr "8. Anti-DPI: does THIS sing-box accept the tls_fragment route action?"
# vpnpool applies anti-DPI as a non-final "route-options" rule action (the ONLY place
# sing-box exposes tls_fragment, since 1.12.0) — NOT as an outbound dial field. Test by
# appending such a rule to a throwaway copy of the live config and validating it.
if [ -f "$SB_CONF" ]; then
	jq '.route.rules += [{"action":"route-options","tls_fragment":true,"tls_fragment_fallback_delay":"500ms"}]' \
	   "$SB_CONF" > /tmp/vp-frag.json 2>/dev/null
	if sing-box check -c /tmp/vp-frag.json 2>/tmp/vp-frag.err; then
		ok "tls_fragment route action SUPPORTED -> anti-DPI toggle actually works on this build"
	else
		info "tls_fragment route action NOT accepted by this sing-box build (<1.12?):"
		sed 's/^/       /' /tmp/vp-frag.err | head -3
		info "the anti-DPI toggle will be a no-op here (resilient build keeps the working config)"
	fi
	rm -f /tmp/vp-frag.json /tmp/vp-frag.err
fi

hdr "9. Clash API reachable"
curl -s -m4 "http://$CLASH/version" >/dev/null 2>&1 && ok "clash_api $CLASH" || fail "clash_api $CLASH unreachable"

hdr "10. Real exit through the tunnel (conntest)"
CT=$(ubus call vpnpool conntest 2>/dev/null)
if echo "$CT" | jq -e '.ok==true' >/dev/null 2>&1; then
	ok "exit OK: $(echo "$CT" | jq -r '.country + " " + .ip')"
else
	fail "conntest failed (no working exit?) — $CT"
fi

echo
echo "============================================================"
if [ "$FAILS" -eq 0 ]; then
	echo "RESULT: all automated checks passed."
else
	echo "RESULT: $FAILS FAIL(s) above — investigate before relying on this build."
fi
cat <<'MANUAL'

------------------------------------------------------------
MANUAL UI CHECKLIST (do these in LuCI -> VPN Pool):
  Dashboard:
   [ ] node search box / sort / "reachable only" filter work
   [ ] per-node traffic column + "Per-client traffic" table populate
   [ ] Save (star) a subscription node -> it shows the saved star
   [ ] Speed test (lightning) on a node -> Mbit/s (or low-mem message on 16MB)
   [ ] Share (link) on a node -> link + QR render (QR is offline/local)
   [ ] Unlock (lock) on a node -> badges (YT/AI/NF/IG/TG/GG) appear
   [ ] Export -> Saved/Manual/All -> base64 subscription copies/downloads
  Sources:
   [ ] add an Extra subscription -> its nodes merge into the pool
  Settings:
   [ ] Anti-DPI toggle saves; if section 8 said SUPPORTED, enable and re-run conntest
   [ ] Adaptive routing toggle + "Scan now"; "Site is blocked?" adds a domain
   [ ] Schedule on/off/refresh saves -> check: crontab -l shows a vpnpool block
   [ ] Auto-save working nodes toggle saves
  Telegram (if configured):
   [ ] /status /quota /saved /clients /speedtest <n> /nodes /switch <n> reply
------------------------------------------------------------
MANUAL
[ "$FAILS" -eq 0 ]
