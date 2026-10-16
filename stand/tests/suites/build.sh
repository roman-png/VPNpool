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
# stage 3: the node sing-box rejected is reported in build_status.json (tag + machine reason)
begin "build/status-file-lists-engine-drop"
expect_jq "dropped by the engine, with its tag" "$(cat /tmp/vpnpool/build_status.json 2>/dev/null)" \
	'.ok==true and .nodes==3 and ([.dropped[] | select(.tag=="JsonUnknownField" and .reason=="rejected_by_engine")] | length)==1'
end
begin "build/log-counts-the-final-pool"   # the log line once subtracted the dropped node twice
expect_true "log: 3 nodes, 1 dropped" grep -q 'build: ok (3 nodes; dropped 1 unsupported)' "$T_STATE/build.out"
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
# ROADMAP 4.7: deferred BEFORE the generator (not pruned by check), listed with its reason
expect_jq "the AWG node is deferred: engine_missing" "$(cat /tmp/vpnpool/deferred.json 2>/dev/null)" 'length==1 and .[0].type=="awg" and .[0].reason=="engine_missing"'
expect_eq "nothing pruned by the engine's check" "$(jq '[.dropped[] | select(.reason=="rejected_by_engine")] | length' /tmp/vpnpool/build_status.json 2>/dev/null)" 0
end

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
printf '%s\n' "$GOOD" > "$SUB"
run_build "$SUB"
_cfg=$(cat /etc/vpnpool/sing-box.json 2>/dev/null)
sed -n "s/^let RESERVED_TAGS = {\(.*\)};.*/\1/p" /usr/libexec/vpnpool/parser.uc | tr ',' '\n' \
	| sed "s/:.*//; s/[' ]//g" | grep -v '^$' | sort -u > "$T_STATE/build/reserved"
# by PROPERTY, not by type: every outbound/endpoint tag of the config that is not a node tag
printf '%s' "$_cfg" | jq -r --slurpfile n /tmp/vpnpool/nodes.json \
	'([.outbounds[].tag] + [(.endpoints // [])[].tag]) - [$n[0][].tag] | .[]' | sort -u > "$T_STATE/build/gen-tags"
begin "build/generator-tags-reserved-in-parser"
expect_true "parser list read (positive control: has auto)" grep -qx auto "$T_STATE/build/reserved"
expect_true "generator tags read (positive control: has proxy)" grep -qx proxy "$T_STATE/build/gen-tags"
expect_eq "generator tags missing from parser RESERVED_TAGS" "$(grep -vxF -f "$T_STATE/build/reserved" "$T_STATE/build/gen-tags" | tr '\n' ' ')" ''
end

# ---- the tag safety net (lib.sh config_tag_guard) on a config that bypasses the parser ----
cat > "$T_STATE/build/dups.json" <<'JSON'
{"outbounds":[
 {"type":"urltest","tag":"auto","outbounds":["A","A","B","direct"]},
 {"type":"selector","tag":"proxy","outbounds":["auto","A","A","B"]},
 {"type":"vless","tag":"A","server":"203.0.113.1","server_port":443,"uuid":"x"},
 {"type":"vless","tag":"A","server":"203.0.113.2","server_port":443,"uuid":"y"},
 {"type":"vless","tag":"B","server":"203.0.113.3","server_port":443,"uuid":"z"},
 {"type":"vless","tag":"direct","server":"203.0.113.4","server_port":443,"uuid":"w"},
 {"type":"direct","tag":"direct"}],
 "endpoints":[{"type":"wireguard","tag":"B"},{"type":"wireguard","tag":"C"}]}
JSON
cp "$T_STATE/build/dups.json" "$T_STATE/build/g.json"
printf '. /usr/libexec/vpnpool/lib.sh\n"$@"\nrc=$?\necho "rc=$rc dropped=$TAG_GUARD_DROPPED"\n' > "$T_STATE/build/guard.sh"
sh "$T_STATE/build/guard.sh" config_tag_guard "$T_STATE/build/g.json" > "$T_STATE/build/g.out" 2>&1
_g=$(cat "$T_STATE/build/g.json")
begin "build/tag-guard-drops-repeated-nodes"
expect_eq "result" "$(tail -1 "$T_STATE/build/g.out")" "rc=0 dropped=3"
expect_jq "all tags unique now" "$_g" '([.outbounds[].tag] + [.endpoints[].tag]) | length == (unique | length)'
expect_jq "first A kept, the structural direct kept" "$_g" '([.outbounds[] | select(.tag=="A")][0].server=="203.0.113.1") and ([.outbounds[] | select(.tag=="direct")][0].type=="direct")'
expect_jq "endpoint C kept, repeated B dropped" "$_g" '[.endpoints[].tag] == ["C"]'
expect_jq "group lists de-duplicated" "$_g" '(.outbounds[0].outbounds == ["A","B","direct"]) and (.outbounds[1].outbounds == ["auto","A","B"])'
end
printf '{"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"direct"}]}\n' > "$T_STATE/build/own.json"
printf '{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"A"}]}\n' > "$T_STATE/build/clean.json"
cp "$T_STATE/build/clean.json" "$T_STATE/build/clean.orig"
begin "build/tag-guard-own-repeat-refused-clean-untouched"
expect_eq "two own outbounds share a tag -> rc 1" "$(sh "$T_STATE/build/guard.sh" config_tag_guard "$T_STATE/build/own.json" 2>&1 | tail -1)" "rc=1 dropped=0"
expect_eq "clean config -> rc 0, nothing dropped" "$(sh "$T_STATE/build/guard.sh" config_tag_guard "$T_STATE/build/clean.json" 2>&1 | tail -1)" "rc=0 dropped=0"
expect_true "clean config left byte-identical" cmp -s "$T_STATE/build/clean.json" "$T_STATE/build/clean.orig"
end

# ---- stage 3: build_status.json (the UI polls it instead of blind timers) + node id ----
printf '%s\n%s\n' "$GOOD" "vless://$U@203.0.113.50:70000?type=tcp&security=tls&sni=p.example#Port70000" > "$SUB"
run_build "$SUB"
_bs=$(cat /tmp/vpnpool/build_status.json 2>/dev/null)
begin "build/status-file-success"
expect_jq "ok, 3 nodes, a time, no error" "$_bs" '.ok==true and .nodes==3 and (.at|type=="number") and .error==null'
expect_jq "the parser-rejected line is listed: source, line, reason" "$_bs" \
	'.skipped==1 and (.dropped|length)==1 and .dropped[0].reason=="bad_port" and .dropped[0].line==4 and .dropped[0].source=="000.raw"'
end
begin "build/nodes-carry-id-config-does-not"
expect_jq "every node in nodes.json has a 12-char id" "$(cat /tmp/vpnpool/nodes.json 2>/dev/null)" \
	'length==3 and all(.[]; (.id|type)=="string" and (.id|length)==12)'
expect_jq "links.json carries tag, id and link" "$(cat /tmp/vpnpool/links.json 2>/dev/null)" \
	'length==3 and all(.[]; (.id|type)=="string" and (.link|startswith("vless://")))'
expect_jq "no id / _link field reaches the sing-box config" "$(cat /etc/vpnpool/sing-box.json 2>/dev/null)" \
	'[(.outbounds[]), ((.endpoints // [])[]) | select(has("id") or has("_link"))] | length == 0'
expect_true "sing-box check accepts it" sing-box check -c /etc/vpnpool/sing-box.json
end
printf '%s\n' "vless://$U@203.0.113.50:70000?type=tcp&security=tls&sni=p.example#OnlyBad" > "$SUB"
run_build "$SUB"
begin "build/status-file-failure"
expect_eq "build.sh failed" "$BRC" 1
expect_jq "ok:false with a machine error code, the reason of the line kept" "$(cat /tmp/vpnpool/build_status.json 2>/dev/null)" \
	'.ok==false and .error=="no_nodes" and .skipped==1 and .dropped[0].reason=="bad_port"'
end

# ---- review V5: a killed build says "interrupted", never the previous build's ok ----
printf '%s\n' "$GOOD" > "$SUB"
run_build "$SUB"                                   # a successful build first (ok:true on file)
begin "build/before-kill-status-ok"                 # positive control for the case below
expect_jq "ok" "$(cat /tmp/vpnpool/build_status.json 2>/dev/null)" '.ok==true'
end
mkdir -p /tmp/vpnpool/sources; cp "$SUB" /tmp/vpnpool/sources/000.raw
mock_on; mock_rule 'GET https://203.0.113.4*' 000 - - 0 8   # the health prefilter hangs 8 s
rm -f /tmp/curlmock/calls.log   # count only THIS run's requests
sh /usr/libexec/vpnpool/build.sh > "$T_STATE/build.kill" 2>&1 & BP=$!
_i=0; while [ $_i -lt 10 ] && [ "$(mock_calls 'GET https://203.0.113.4')" -lt 1 ]; do sleep 1; _i=$((_i + 1)); done
kill -TERM "$BP"; wait "$BP"; KRC=$?
begin "build/term-writes-interrupted"
expect_eq "exit code 143" "$KRC" 143
expect_jq "status: interrupted" "$(cat /tmp/vpnpool/build_status.json 2>/dev/null)" '.ok==false and .error=="interrupted"'
expect_true "the live config of the earlier build kept" sing-box check -c /tmp/vpnpool/sing-box.json
end
