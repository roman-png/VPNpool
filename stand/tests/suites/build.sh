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
end 2.1
metric build_port70000_seconds "$BSECS"

# ---- poison: subscription node tagged with a reserved name ----
for rt in direct auto proxy; do
	printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.51:443?type=tcp&security=tls&sni=r.example#$rt" > "$SUB"
	run_build "$SUB"
	begin "build/poison-reserved-tag-$rt"
	expect_good_config
	end 2.1
done

# ---- poison: duplicate tags produced by the " #N" suffix scheme ----
printf '%s\n%s\n%s\n%s\n' "$GOOD" \
	"vless://$U@203.0.113.52:443?security=tls#Dup" \
	"vless://$U@203.0.113.53:443?security=tls#Dup" \
	"vless://$U@203.0.113.54:443?security=tls#Dup%20%232" > "$SUB"
run_build "$SUB"
begin "build/poison-duplicate-tags"
expect_good_config
end 2.1

# ---- the pool must not stay frozen: the SAME poison on the next rebuild still builds ----
printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.50:70000?type=tcp&security=tls#Port70000" > "$SUB"
run_build "$SUB"
printf '%s\n%s\n%s\n' "$GOOD" "$(good 44 Good4)" "vless://$U@203.0.113.50:70000?type=tcp&security=tls#Port70000" > "$SUB"
cp "$SUB" /tmp/vpnpool/sources/000.raw
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?
begin "build/not-frozen-new-node-arrives-despite-poison"
expect_eq "second build exit code" "$BRC" 0
expect_jq "new node Good4 reached the config" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("Good4") != null'
end 2.1

# ---- xhttp: unsupported transport must not become a (dead) node in the config ----
printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.55:443?type=xhttp&security=tls&sni=x.example&path=%2Fx#XHTTP" > "$SUB"
run_build "$SUB"
begin "build/xhttp-builds"
expect_good_config
end
begin "build/xhttp-not-in-config"
expect_jq "xhttp node absent" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" '[.outbounds[].tag] | index("XHTTP") == null'
end 5

# ---- a second source whose body looks like JSON but isn't: parser.uc dies => 0 nodes ----
printf '%s\n' "$GOOD" > "$SUB"
printf '[{"broken": \n' > "$T_STATE/build/junk.raw"
run_build "$SUB" "$T_STATE/build/junk.raw"
begin "build/junk-json-source-does-not-empty-pool"
expect_good_config
end NEW-1

# ---- an AWG node without an AWG-capable engine must not break the build (stock sing-box) ----
reset_state
mock_on
mkdir -p /tmp/vpnpool/sources /etc/vpnpool/awg
printf '%s\n' "$GOOD" > /tmp/vpnpool/sources/000.raw
cp "$T_DIR/fixtures/awg/awg2.conf" /etc/vpnpool/awg/test.conf
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.out" 2>&1; BRC=$?; BSECS=0
begin "build/awg-node-on-stock-engine-deferred"
expect_good_config
end 4.7
