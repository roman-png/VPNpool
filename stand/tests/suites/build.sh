# suite: build — a subscription with "poison" lines must not freeze the pool (sourced by run.sh)
# Today: one bad line => `sing-box check` error that build.sh's pruning does not recognise
# => "keeping previous config" on EVERY rebuild, forever (ROADMAP §1, 2.1).
# Each case: fresh state, sources/000.raw = 3 good nodes + poison, run the REAL build.sh
# (parser.uc -> generator.uc -> sing-box check -> prune) with a 120 s bound, then demand:
# rc 0, a config that `sing-box check` accepts, and all 3 good nodes in it.

U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
PBK=KHu_Zt1CNMIJyAETBVA5LJWiSOiipcxPP2uSw89kkVc
good() { printf 'vless://%s@203.0.113.%s:443?type=tcp&security=reality&pbk=%s&sid=ab12&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#%s\n' "$U" "$1" "$PBK" "$2"; }
GOOD="$(good 41 Good1)
$(good 42 Good2)
$(good 43 Good3)"

BN=0
# run_build <file with subscription text> [second source file]
run_build() {
	reset_state
	mock_on   # health prefilter curls every server: offline stand => all "unreachable" (unfiltered pool)
	mkdir -p /tmp/vpnpool/sources
	cp "$1" /tmp/vpnpool/sources/000.raw
	[ -n "${2:-}" ] && cp "$2" /tmp/vpnpool/sources/001.raw
	_t0=$(date +%s)
	run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1
	BRC=$?
	BSECS=$(( $(date +%s) - _t0 ))
	# invariant as its own plain case (never hidden inside an xfail): the build must END
	BN=$((BN + 1))
	begin "build/run-$BN-finishes-within-120s"
	expect_true "build.sh finished within 120s (rc=$BRC, ${BSECS}s)" [ "$BRC" -ne 124 ]
	end
	[ "$T_VERBOSE" = 1 ] && [ -s /tmp/vpnpool/check.err ] && echo "      note: check.err: $(grep -m1 -i 'fatal\|error' /tmp/vpnpool/check.err | cut -c1-200)"
	return 0
}

expect_good_config() {   # $1 = how many good nodes must be present (default 3)
	expect_eq "build.sh exit code" "$BRC" 0
	expect_true "config exists" [ -s /etc/vpnpool/sing-box.json ]
	expect_true "sing-box check accepts the config" sing-box check -c /etc/vpnpool/sing-box.json
	_cfg=$(cat /etc/vpnpool/sing-box.json 2>/dev/null)
	expect_jq "good nodes present" "$_cfg" '[.outbounds[].tag] | (index("Good1") != null) and (index("Good2") != null) and (index("Good3") != null)'
	expect_jq "tags unique across outbounds+endpoints" "$_cfg" '([.outbounds[].tag] + [(.endpoints // [])[].tag]) | (length == (unique|length))'
}

mkdir -p "$T_STATE/build"
SUB="$T_STATE/build/sub.txt"

# ---- positive control: a clean subscription builds ----
printf '%s\n' "$GOOD" > "$SUB"
run_build "$SUB"
begin "build/clean-subscription"
expect_good_config
expect_jq "nodes.json lists 3 nodes" "$(cat /tmp/vpnpool/nodes.json 2>/dev/null)" 'length==3'
end
metric build_clean_seconds "$BSECS"

# ---- poison: port out of range ----
printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.50:70000?type=tcp&security=tls&sni=p.example#Port70000" > "$SUB"
run_build "$SUB"
begin "build/poison-port-70000"
expect_good_config
expect_jq "bad node not in config" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("Port70000") == null'
end
metric build_port70000_seconds "$BSECS"

# ---- poison: subscription node tagged with a reserved name ----
for rt in direct auto proxy; do
	printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.51:443?type=tcp&security=tls&sni=r.example#$rt" > "$SUB"
	run_build "$SUB"
	begin "build/poison-reserved-tag-$rt"
	expect_good_config
	end
done

# ---- poison: duplicate tags produced by the " #N" suffix scheme ----
printf '%s\n%s\n%s\n%s\n' "$GOOD" \
	"vless://$U@203.0.113.52:443?security=tls#Dup" \
	"vless://$U@203.0.113.53:443?security=tls#Dup" \
	"vless://$U@203.0.113.54:443?security=tls#Dup%20%232" > "$SUB"
run_build "$SUB"
begin "build/poison-duplicate-tags"
expect_good_config
end

# ---- the pool must not stay frozen: the SAME poison on the next rebuild still builds ----
printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.50:70000?type=tcp&security=tls#Port70000" > "$SUB"
run_build "$SUB"
printf '%s\n%s\n%s\n' "$GOOD" "$(good 44 Good4)" "vless://$U@203.0.113.50:70000?type=tcp&security=tls#Port70000" > "$SUB"
cp "$SUB" /tmp/vpnpool/sources/000.raw
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?
begin "build/not-frozen-new-node-arrives-despite-poison"
expect_eq "second build exit code" "$BRC" 0
expect_jq "new node Good4 reached the config" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("Good4") != null'
end

# The link poisons above are now dropped / renamed by parser.uc itself (stage 5 + 2.1 parser
# part; JSON-source outbounds get the same guards). build.sh's OWN pruning of a `sing-box check`
# error (2.1: outbounds[N] / endpoints[N] / duplicate tag) is still needed for what no parser
# guard can foresee — e.g. a JSON outbound with a field this sing-box does not know.
printf '%s\n' "$GOOD" > "$SUB"
printf '{"outbounds":[{"type":"vless","tag":"JsonUnknownField","server":"203.0.113.56","server_port":443,"uuid":"%s","bogus_field":1}]}\n' "$U" > "$T_STATE/build/poison.json"
run_build "$SUB" "$T_STATE/build/poison.json"
begin "build/poison-json-source-unknown-field"
expect_good_config
expect_jq "bad node not in config" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("JsonUnknownField") == null'
end

# a reality short_id longer than 8 bytes makes sing-box PANIC (no outbounds[N] in the message,
# nothing for build.sh to prune) -> the parser must drop it from a JSON source too
printf '{"outbounds":[{"type":"vless","tag":"JsonLongSid","server":"203.0.113.57","server_port":443,"uuid":"%s","tls":{"enabled":true,"server_name":"a.example","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"%s","short_id":"0123456789abcdef0123"}}}]}\n' "$U" "$PBK" > "$T_STATE/build/longsid.json"
run_build "$SUB" "$T_STATE/build/longsid.json"
begin "build/json-source-long-short-id-no-panic"
expect_good_config
expect_jq "bad node not in config" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("JsonLongSid") == null'
expect_true "no panic in check.err" sh -c '! grep -q panic /tmp/vpnpool/check.err'
end

# ---- xhttp: unsupported transport must not become a (dead) node in the config ----
printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.55:443?type=xhttp&security=tls&sni=x.example&path=%2Fx#XHTTP" > "$SUB"
run_build "$SUB"
begin "build/xhttp-builds"
expect_good_config
end
begin "build/xhttp-not-in-config"
expect_jq "xhttp node absent" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("XHTTP") == null'
end

# ---- a second source whose body looks like JSON but isn't: parser.uc dies => 0 nodes ----
printf '%s\n' "$GOOD" > "$SUB"
printf '[{"broken": \n' > "$T_STATE/build/junk.raw"
run_build "$SUB" "$T_STATE/build/junk.raw"
begin "build/junk-json-source-does-not-empty-pool"
expect_good_config
end

# ---- an AWG node without an AWG-capable engine must not break the build (stock sing-box) ----
reset_state
mock_on
mkdir -p /tmp/vpnpool/sources /etc/vpnpool/awg
printf '%s\n' "$GOOD" > /tmp/vpnpool/sources/000.raw
cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/test.conf
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?; BSECS=0
begin "build/awg-node-on-stock-engine-deferred"
expect_good_config
end   # was xfail 4.7: the build no longer breaks (the 2.1 endpoints[N] prune drops the node); showing it as deferred is still stage 4

# ---- flash wear (2.11): the live config is in RAM; flash copies are rewritten only on change ----
printf '%s\n' "$GOOD" > "$SUB"
run_build "$SUB"
touch -d '2000-01-01 00:00:00' /etc/vpnpool/sing-box.json /etc/vpnpool/links.json
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?
begin "build/unchanged-pool-no-flash-write"
expect_eq "second build exit code" "$BRC" 0
expect_true "live config in RAM" [ -s /tmp/vpnpool/sing-box.json ]
expect_true "live config == flash copy" cmp -s /tmp/vpnpool/sing-box.json /etc/vpnpool/sing-box.json
expect_eq "flash sing-box.json untouched (year)" "$(date -r /etc/vpnpool/sing-box.json +%Y)" 2000
expect_eq "flash links.json untouched (year)" "$(date -r /etc/vpnpool/links.json +%Y)" 2000
end
printf '%s\n%s\n' "$GOOD" "$(good 44 Good4)" > /tmp/vpnpool/sources/000.raw
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?
begin "build/changed-pool-flash-updated"   # positive control for the case above
expect_eq "third build exit code" "$BRC" 0
expect_true "flash sing-box.json rewritten (year)" [ "$(date -r /etc/vpnpool/sing-box.json +%Y)" != 2000 ]
expect_true "flash links.json rewritten (year)" [ "$(date -r /etc/vpnpool/links.json +%Y)" != 2000 ]
expect_jq "flash copy has Good4" "$(cat /etc/vpnpool/sing-box.json)" '[.outbounds[].tag] | index("Good4") != null'
end

# ---- a reboot empties /tmp: a failing build still keeps the last good config (seeded from flash) ----
rm -f /tmp/vpnpool/sing-box.json /tmp/vpnpool/nodes.json
printf 'garbage only\n' > /tmp/vpnpool/sources/000.raw
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?
begin "build/after-reboot-failed-build-keeps-flash-config"
expect_true "build reports failure" [ "$BRC" -ne 0 ]
expect_true "live config seeded from flash" cmp -s /tmp/vpnpool/sing-box.json /etc/vpnpool/sing-box.json
end

# ---- node-test selector (2.8): speedtest/unlock have their own selector + inbound ----
begin "build/node-test-selector-separate-from-proxy"
_cfg=$(cat /etc/vpnpool/sing-box.json 2>/dev/null)
expect_jq "vpnpool-test selector lists the nodes" "$_cfg" '.outbounds[] | select(.tag=="vpnpool-test") | .type=="selector" and (.outbounds|index("Good1"))!=null'
expect_jq "node-test-in routes to vpnpool-test only" "$_cfg" '[.route.rules[] | select(.inbound==["node-test-in"])] | length==1 and .[0].outbound=="vpnpool-test"'
expect_jq "proxy selector does not contain the test selector" "$_cfg" '.outbounds[] | select(.tag=="proxy") | (.outbounds|index("vpnpool-test"))==null'
end

# ---- ONE list of reserved names: parser.uc's RESERVED_TAGS must cover every outbound tag the
# generator adds itself (build.sh keeps no copy of the rule) ----
sed -n "s/^let RESERVED_TAGS = {\(.*\)};.*/\1/p" /usr/libexec/vpnpool/parser.uc | tr ',' '\n' \
	| sed "s/:.*//; s/[' ]//g" | grep -v '^$' | sort -u > "$T_STATE/build/reserved"
printf '%s' "$_cfg" | jq -r '.outbounds[] | select(.type=="urltest" or .type=="selector" or .type=="direct" or .type=="block") | .tag' \
	| sort -u > "$T_STATE/build/gen-tags"
begin "build/generator-tags-reserved-in-parser"
expect_true "parser list read (positive control: has auto)" grep -qx auto "$T_STATE/build/reserved"
expect_true "generator tags read (positive control: has proxy)" grep -qx proxy "$T_STATE/build/gen-tags"
expect_eq "generator tags missing from parser RESERVED_TAGS" "$(grep -vxF -f "$T_STATE/build/reserved" "$T_STATE/build/gen-tags" | tr '\n' ' ')" ''
end
