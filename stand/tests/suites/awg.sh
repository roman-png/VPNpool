# suite: awg — AmneziaWG inside vpnpool (ROADMAP §7, stage 4b) (sourced by run.sh)
#   engine choice (enginecap.uc): measured capability, cache, the reasons;
#   build: deferred nodes (no engine / start_failed), stock WireGuard, the engine's binary;
#   generator per engine version: `check` AND a real `run` of both engines (stock 1.12.25 from
#     the image, the real vpnpool-engine x86_64 asset from /engine-assets);
#   the vpn:// -> awgdecode --json -> parser -> generator -> sing-box-awg chain, field by field;
#   the start guard (vpnpoold) with the real sing-box: a node that dies at start, rollback, limit;
#   rpcd/api: analyze / add / import_nodes / delete by id for AWG.
# Offline stand: rule-sets come from a local uhttpd (VPNPOOL_SRS_BASE), and a dummy default route
# lets an AWG endpoint bind its UDP socket ("no route to internet" otherwise).

ASSET=/engine-assets/vpnpool-engine_1.14.3-awg.1_x86_64
AWGBIN=/usr/bin/sing-box-awg
STOCK=/usr/bin/sing-box
LX=/usr/libexec/vpnpool
PARSER=$LX/parser.uc
AFX="$T_DIR/fixtures/awg"
AW="$T_STATE/awg"; mkdir -p "$AW"
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
PBK=KHu_Zt1CNMIJyAETBVA5LJWiSOiipcxPP2uSw89kkVc
VLESS="vless://$U@203.0.113.41:443?type=tcp&security=reality&pbk=$PBK&sid=ab12&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#Good1"
jarg() { jq -nc "$@"; }

engine_on()  { cp "$ASSET" "$AWGBIN" && chmod 0755 "$AWGBIN"; }
engine_off() { rm -f "$AWGBIN"; }
net_on() {   # a dummy default route: sing-box finds a "default interface", AWG can bind UDP
	ip link show vpawg0 >/dev/null 2>&1 || ip link add vpawg0 type dummy 2>/dev/null
	ip addr add 10.99.0.2/24 dev vpawg0 2>/dev/null; ip link set vpawg0 up 2>/dev/null
	ip route add default via 10.99.0.1 dev vpawg0 2>/dev/null
	return 0
}
net_off() { ip link del vpawg0 2>/dev/null; return 0; }
SRS_PORT=18080
srs_on() {   # local rule-set server: SRS compiled by the STOCK binary (readable by 1.12 and 1.14)
	mkdir -p "$AW/srs"
	echo '{"version":1,"rules":[{"domain_suffix":["example.com"]}]}' > "$AW/srs/src.json"
	for c in telegram russia_inside youtube; do "$STOCK" rule-set compile -o "$AW/srs/$c.srs" "$AW/srs/src.json" 2>/dev/null; done
	pgrep -f "uhttpd -p 127.0.0.1:$SRS_PORT" >/dev/null 2>&1 || uhttpd -p "127.0.0.1:$SRS_PORT" -h "$AW/srs"
	VPNPOOL_SRS_BASE="http://127.0.0.1:$SRS_PORT"; export VPNPOOL_SRS_BASE
}
srs_off() { for p in $(pgrep -f "uhttpd -p 127.0.0.1:$SRS_PORT"); do kill "$p"; done; unset VPNPOOL_SRS_BASE; }
build() {   # the REAL build.sh, bounded -> BRC
	mock_on
	run_with_timeout 120 sh $LX/build.sh > "$AW/build.out" 2>&1; BRC=$?
}
sb_kill_all() { for p in $(pgrep -f "sing-box[^ ]* run -c"); do kill -9 "$p" 2>/dev/null; done; rm -f /var/run/vpnpool-singbox.pid; }
# run_for <bin> <config> <secs> -> RUN_ALIVE (1/0), RUN_CLASH (http code of /proxies), RUN_LOG
run_for() {
	rm -f /tmp/vpnpool/cache.db; RUN_LOG="$AW/run.log"
	"$1" run -c "$2" -D /tmp/vpnpool > "$RUN_LOG" 2>&1 & _rp=$!
	_i=0; while [ $_i -lt "$3" ]; do sleep 1; _i=$((_i + 1)); done
	RUN_CLASH=$(/usr/bin/curl -s -m2 -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/proxies 2>/dev/null)
	if kill -0 "$_rp" 2>/dev/null; then RUN_ALIVE=1; kill "$_rp"; wait "$_rp" 2>/dev/null; else RUN_ALIVE=0; fi
	sed -i 's/\x1b\[[0-9;]*m//g' "$RUN_LOG"
}

# jq here has no regex (OpenWrt builds it without oniguruma): no test() / gsub() in the checks
srs_on   # every config below carries the default rule-sets: a local server for the whole suite
begin "awg/real-engine-asset-mounted"
expect_true "real asset at $ASSET (set ENGINE_ASSET_DIR for run-in-docker.sh)" [ -f "$ASSET" ]
expect_true "stock sing-box present" [ -x "$STOCK" ]
end
engine_off; net_off

# ======================= engine choice (enginecap.uc) =======================
sel() { ucode $LX/enginecap.uc select "$1" 2>/dev/null; }
reset_state
begin "awg/select-no-engine-awg-nodes"
_s=$(sel 1)
expect_jq "stock, engine_missing, no AWG" "$_s" ".bin==\"$STOCK\" and .reason==\"engine_missing\" and .awg==false and .present==true"
expect_jq "the stock version measured" "$_s" '.version=="1.12.25" and .major==1 and .minor==12'
end
engine_on
begin "awg/select-engine-awg-nodes"
_s=$(sel 1)
expect_jq "the engine, AWG, no reason" "$_s" ".bin==\"$AWGBIN\" and .awg==true and .reason==null and .version==\"1.14.3-awg.1\" and .minor==14"
end
begin "awg/select-engine-no-awg-nodes-stays-stock"
expect_jq "stock for a pool without AWG" "$(sel 0)" ".bin==\"$STOCK\" and .reason==null"
end
uci set vpnpool.main.singbox_bin="$STOCK"; uci commit vpnpool
begin "awg/select-stock-path-configured-is-automatic"
expect_jq "the engine still chosen for AWG" "$(sel 1)" ".bin==\"$AWGBIN\" and .reason==null"
end
cp "$STOCK" "$AW/my-sing-box"; chmod +x "$AW/my-sing-box"
uci set vpnpool.main.singbox_bin="$AW/my-sing-box"; uci commit vpnpool
begin "awg/select-pinned-binary-without-awg"
expect_jq "the pinned one, engine_no_awg" "$(sel 1)" ".bin==\"$AW/my-sing-box\" and .reason==\"engine_no_awg\" and .awg==false"
end
uci delete vpnpool.main.singbox_bin; uci commit vpnpool
# a build that answers `version` but can't run AWG (a broken / foreign binary in the engine's place)
printf '#!/bin/sh\n[ "$1 $2" = "version -n" ] && { echo 1.14.3-awg.9; exit 0; }\nexit 1\n' > "$AWGBIN"; chmod +x "$AWGBIN"
begin "awg/select-engine-file-that-cannot-awg"
expect_jq "engine_no_awg, stays stock" "$(sel 1)" ".bin==\"$STOCK\" and .reason==\"engine_no_awg\""
end
# cache: by mtime:size — a poll does not run the binary again; a changed binary is re-measured
rm -f /tmp/vpnpool/engine-cap.json
printf '#!/bin/sh\necho x >> %s\n[ "$1 $2" = "version -n" ] && { echo 1.14.9; exit 0; }\nexit 1\n' "$AW/calls" > "$AWGBIN"; chmod +x "$AWGBIN"
: > "$AW/calls"
ucode $LX/enginecap.uc cap "$AWGBIN" >/dev/null; _c1=$(wc -l < "$AW/calls")
ucode $LX/enginecap.uc cap "$AWGBIN" >/dev/null; _c2=$(wc -l < "$AW/calls")
touch -d '2001-01-01 00:00:00' "$AWGBIN"
ucode $LX/enginecap.uc cap "$AWGBIN" >/dev/null; _c3=$(wc -l < "$AW/calls")
begin "awg/engine-cap-cached-by-mtime-size"
expect_eq "first measure: version + check" "$_c1" 2
expect_eq "second: from the cache" "$_c2" 2
expect_eq "changed binary: measured again" "$_c3" 4
end
engine_off

# ======================= build: deferred nodes, stock WireGuard, the engine =======================
reset_state
mkdir -p /tmp/vpnpool/sources /etc/vpnpool/awg
printf '%s\n' "$VLESS" > /tmp/vpnpool/sources/000.raw
cp "$AFX/awg3.conf" /etc/vpnpool/awg/a3.conf
build
_cfg=$(cat /tmp/vpnpool/sing-box.json 2>/dev/null); _bs=$(cat /tmp/vpnpool/build_status.json 2>/dev/null)
begin "awg/build-no-engine-awg-deferred"
expect_eq "build.sh exit 0" "$BRC" 0
expect_true "stock check accepts the config" "$STOCK" check -c /tmp/vpnpool/sing-box.json
expect_jq "the vless node in, no endpoint" "$_cfg" '([.outbounds[].tag] | index("Good1") != null) and ((.endpoints // []) | length == 0)'
expect_jq "deferred: the AWG node, engine_missing, with its id / server / hint" "$(cat /tmp/vpnpool/deferred.json 2>/dev/null)" \
	'length==1 and .[0].type=="awg" and .[0].reason=="engine_missing" and (.[0].id|length)==12 and .[0].server=="198.51.100.61" and .[0].port==443 and .[0].hints==["awg_random_trailers"]'
expect_jq "build_status: ok, 1 node, 1 deferred, the stock engine" "$_bs" ".ok==true and .nodes==1 and .deferred==1 and .engine.bin==\"$STOCK\" and .engine.awg==false"
expect_eq "the binary recorded for the daemon" "$(cat /tmp/vpnpool/.sb_bin 2>/dev/null)" "$STOCK"
end
_st=$(sh $LX/status.sh 2>/dev/null)
begin "awg/status-lists-deferred-node"
expect_jq "live node + the deferred one" "$_st" '(.nodes|length)==2 and ([.nodes[] | select(.deferred==true)] | length)==1'
expect_jq "deferred node: reason, AWG group, hint" "$_st" '.nodes[] | select(.deferred==true) | .reason=="engine_missing" and .group=="amneziawg" and .proto=="awg" and .hints==["awg_random_trailers"]'
expect_jq "engine block: stock, no AWG build" "$_st" ".engine.bin==\"$STOCK\" and .engine.version==\"1.12.25\" and .engine.awg==false and .engine.awg_engine.installed==false and .awg==false"
end
# only AWG and no engine: a clear state, not a failure loop
rm -f /tmp/vpnpool/sources/000.raw
cp /tmp/vpnpool/sing-box.json "$AW/prev.json"
build
begin "awg/build-only-deferred-clear-state"
expect_eq "exit 3 (nothing to run on this engine)" "$BRC" 3
expect_jq "build_status: only_deferred, 1 deferred" "$(cat /tmp/vpnpool/build_status.json)" '.ok==false and .error=="only_deferred" and .deferred==1'
expect_true "previous config kept" cmp -s /tmp/vpnpool/sing-box.json "$AW/prev.json"
end
# plain WireGuard runs on the STOCK binary: never deferred
reset_state
mkdir -p /tmp/vpnpool/sources /etc/vpnpool/awg
printf '%s\n' "$VLESS" > /tmp/vpnpool/sources/000.raw
cp "$AFX/wg-plain.conf" /etc/vpnpool/awg/wg.conf
build
begin "awg/build-wireguard-on-stock"
expect_eq "build.sh exit 0" "$BRC" 0
expect_jq "a wireguard endpoint in the config" "$(cat /tmp/vpnpool/sing-box.json)" '[.endpoints[]? | select(.type=="wireguard")] | length==1'
expect_jq "nothing deferred" "$(cat /tmp/vpnpool/deferred.json)" 'length==0'
expect_true "stock check accepts it" "$STOCK" check -c /tmp/vpnpool/sing-box.json
end
net_on
run_for "$STOCK" /tmp/vpnpool/sing-box.json 4
begin "awg/wireguard-runs-on-stock"
expect_eq "stock sing-box alive after 4 s" "$RUN_ALIVE" 1
expect_eq "clash API answers" "$RUN_CLASH" 200
expect_eq "no FATAL" "$(gcount FATAL "$RUN_LOG")" 0
end
net_off
# with the engine: AWG goes into the config, checked and run by sing-box-awg
reset_state; engine_on
mkdir -p /tmp/vpnpool/sources /etc/vpnpool/awg
printf '%s\n' "$VLESS" > /tmp/vpnpool/sources/000.raw
cp "$AFX/awg3.conf" /etc/vpnpool/awg/a3.conf
build
begin "awg/build-engine-awg-in-config"
expect_eq "build.sh exit 0" "$BRC" 0
expect_jq "awg endpoint in the config, without id/_link" "$(cat /tmp/vpnpool/sing-box.json)" \
	'([.endpoints[]? | select(.type=="awg")] | length==1) and ([.endpoints[] | has("id") or has("_link")] | any | not)'
expect_eq "the engine recorded for the daemon" "$(cat /tmp/vpnpool/.sb_bin)" "$AWGBIN"
expect_true "the engine checks it" "$AWGBIN" check -c /tmp/vpnpool/sing-box.json
expect_jq "nothing deferred" "$(cat /tmp/vpnpool/deferred.json)" 'length==0'
expect_jq "build_status names the engine" "$(cat /tmp/vpnpool/build_status.json)" ".engine.bin==\"$AWGBIN\" and .engine.version==\"1.14.3-awg.1\" and .engine.awg==true and .deferred==0"
end
_st=$(sh $LX/status.sh 2>/dev/null)
begin "awg/status-engine-block"
expect_jq "engine in use + the AWG build" "$_st" ".engine.bin==\"$AWGBIN\" and .engine.version==\"1.14.3-awg.1\" and .engine.awg==true and .engine.awg_engine.installed==true and .awg==true"
expect_jq "the AWG node is live with its id" "$_st" '[.nodes[] | select(.proto=="awg" and (.deferred|not))] | length==1 and (.[0].id|length)==12'
end
engine_off

# ======================= generator per engine version: check + RUN =======================
reset_state
uci add_list vpnpool.routing.community=youtube; uci commit vpnpool
printf '%s\n' "$VLESS" > "$AW/l.txt"
ucode $PARSER --with-id "$AW/l.txt" "$AFX/awg3.conf" > "$AW/n_awg.json" 2>/dev/null
ucode $PARSER --with-id "$AW/l.txt" > "$AW/n_plain.json" 2>/dev/null
net_on; engine_on
VPNPOOL_SB_VERSION=1.12.25 ucode $LX/generator.uc "$AW/n_plain.json" > "$AW/g112.json"
VPNPOOL_SB_VERSION=1.14.3-awg.1 ucode $LX/generator.uc "$AW/n_awg.json" > "$AW/g114.json"
begin "awg/generator-1.12-form"
expect_jq "download_detour on every rule-set, no http client" "$(cat "$AW/g112.json")" \
	'(.route.rule_set|length)>=1 and all(.route.rule_set[]; .download_detour=="direct") and (has("http_clients")|not) and (.route|has("default_http_client")|not)'
expect_true "stock check" "$STOCK" check -c "$AW/g112.json"
end
run_for "$STOCK" "$AW/g112.json" 5
begin "awg/generator-1.12-runs-on-stock"
expect_eq "alive after 5 s" "$RUN_ALIVE" 1
expect_eq "clash API answers (start completed: rule-sets downloaded)" "$RUN_CLASH" 200
expect_eq "no FATAL" "$(gcount FATAL "$RUN_LOG")" 0
expect_eq "no deprecation warning" "$(gcount -i deprecated "$RUN_LOG")" 0
end
begin "awg/generator-1.14-form"
expect_jq "http client without detour + route default, no download_detour" "$(cat "$AW/g114.json")" \
	'.http_clients==[{tag:"vpnpool-direct"}] and .route.default_http_client=="vpnpool-direct" and all(.route.rule_set[]; has("download_detour")|not)'
expect_true "engine check" "$AWGBIN" check -c "$AW/g114.json"
end
run_for "$AWGBIN" "$AW/g114.json" 5
begin "awg/generator-1.14-runs-on-engine"
expect_eq "alive after 5 s" "$RUN_ALIVE" 1
expect_eq "clash API answers (start completed)" "$RUN_CLASH" 200
expect_eq "no FATAL" "$(gcount FATAL "$RUN_LOG")" 0
expect_eq "no deprecation warning" "$(gcount -i deprecated "$RUN_LOG")" 0
end
# control: the run check CAN say no — the 1.14 client with detour "direct" passes check and dies
# (built here from the 1.12 form, independent of the generator's own choice)
jq '.http_clients=[{tag:"vpnpool-direct",detour:"direct"}] | .route.default_http_client="vpnpool-direct"
	| .route.rule_set |= map(del(.download_detour))' "$AW/g112.json" > "$AW/g114det.json"
run_for "$AWGBIN" "$AW/g114det.json" 4
begin "awg/generator-run-check-says-no"
expect_true "control config passes check" "$AWGBIN" check -c "$AW/g114det.json"
expect_eq "but it does not run" "$RUN_ALIVE" 0
expect_true "FATAL: detour to an empty direct" grep -q 'FATAL.*empty direct' "$RUN_LOG"
end
# and the stock 1.12 refuses the 1.14 form: the version gate is needed
begin "awg/generator-1.14-form-refused-by-1.12"
VPNPOOL_SB_VERSION=1.14.3-awg.1 ucode $LX/generator.uc "$AW/n_plain.json" > "$AW/g114p.json"
expect_jq "control: no AWG endpoint in this config" "$(cat "$AW/g114p.json")" '(.endpoints // []) | length == 0'
expect_true "stock check refuses the 1.14 form" sh -c '! "$1" check -c "$2" >/dev/null 2>&1' _ "$STOCK" "$AW/g114p.json"
end

# ======================= vpn:// -> awgdecode -> parser -> generator -> engine, field by field ===========
# The expectation is computed HERE from the .conf text (an independent table: .conf key -> the
# engine's field, patches/sing-box/0001-option-add-awg-endpoint-type-and-options.patch), not
# taken from the parser.
reset_state; engine_on
mkdir -p /etc/vpnpool/awg
ucode $LX/awgdecode.uc --json < "$AFX/dec/awg2_amnezia5.txt" > "$AW/dec.json" 2>/dev/null
jq -r '.items[0].conf' "$AW/dec.json" > /etc/vpnpool/awg/a5.conf
build
jq -c '[.endpoints[]? | select(.type=="awg")][0]' /tmp/vpnpool/sing-box.json > "$AW/ep.json" 2>/dev/null
# .conf -> {i:{key:value}, p:{key:value}} (keys lower case, values trimmed)
awk 'BEGIN{s=""} /^[ \t]*\[/{l=tolower($0); gsub(/[ \t]/,"",l); s=(l=="[interface]")?"i":((l=="[peer]")?"p":"x"); next}
	/=/{ k=substr($0,1,index($0,"=")-1); v=substr($0,index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v);
	     if (s!="" && k!="" && v!="") printf "%s\t%s\t%s\n", s, tolower(k), v }' /etc/vpnpool/awg/a5.conf \
	| jq -Rs 'split("\n") | map(select(length>0) | split("\t")) | reduce .[] as $r ({i:{}, p:{}}; .[$r[0]][$r[1]] = $r[2])' > "$AW/conf.json"
cat > "$AW/cmp.jq" <<'EOF'
# $c = the .conf, . = the endpoint -> {checked, bad:[...], unknown:[...]}
def rng: split(" ") | join("") | split("\t") | join("");
def prefixes: split(",") | map(rng) | map(if contains("/") then . else (if contains(":") then . + "/128" else . + "/32" end) end);
def boolv: ascii_downcase | (. == "1" or . == "true" or . == "on" or . == "yes");
{ privatekey: ["private_key", "str"], address: ["address", "list"], mtu: ["mtu", "int"],
  jc: ["jc", "int"], jmin: ["jmin", "int"], jmax: ["jmax", "int"],
  s1: ["s1", "int"], s2: ["s2", "int"], s3: ["s3", "int"], s4: ["s4", "int"],
  h1: ["h1", "rng"], h2: ["h2", "rng"], h3: ["h3", "rng"], h4: ["h4", "rng"],
  i1: ["i1", "str"], i2: ["i2", "str"], i3: ["i3", "str"], i4: ["i4", "str"], i5: ["i5", "str"],
  headerprotectionkey: ["header_protection_key", "str"], contentpaddingaddition: ["content_padding_addition", "rng"],
  rekeyaftertime: ["rekey_after_time", "rng"], rekeytimeout: ["rekey_timeout", "rng"],
  rejectaftertime: ["reject_after_time", "rng"], keepalivetimeout: ["keepalive_timeout", "rng"],
  maxhandshakeattempts: ["max_handshake_attempts", "rng"],
  randomtrailers: ["random_trailers", "bool"], disablecookies: ["disable_cookies", "bool"] } as $IF
| { publickey: ["public_key", "str"], presharedkey: ["preshared_key", "str"], allowedips: ["allowed_ips", "list"],
    persistentkeepalive: ["persistent_keepalive_interval", "ka"] } as $PF
| . as $ep
| def want($kind; $v): if $kind == "int" then ($v | tonumber) elif $kind == "rng" then ($v | rng)
      elif $kind == "list" then ($v | prefixes) elif $kind == "bool" then ($v | boolv)
      elif $kind == "ka" then ($v | rng | if contains("-") then . else tonumber end) else $v end;
  [ ($c.i | to_entries[] | select(.key != "dns") | {k: .key, v: .value, m: $IF[.key], got: (if $IF[.key] then $ep[$IF[.key][0]] else null end)}),
    ($c.p | to_entries[] | select(.key != "endpoint") | {k: .key, v: .value, m: $PF[.key], got: (if $PF[.key] then $ep.peers[0][$PF[.key][0]] else null end)}) ] as $rows
  | { checked: ($rows | map(select(.m != null)) | length) + 1,
      unknown: ($rows | map(select(.m == null) | .k)),
      bad: ([ $rows[] | select(.m != null) | select(.got != want(.m[1]; .v)) | "\(.k): conf [\(.v)] -> \(.got | tojson)" ]
            + (if ($c.p.endpoint | split(":")) as $e | ($ep.peers[0].address == $e[0] and $ep.peers[0].port == ($e[1] | tonumber)) then [] else ["endpoint"] end)) }
EOF
_cmp=$(jq -c --slurpfile c "$AW/conf.json" '$c[0] as $c | '"$(cat "$AW/cmp.jq")" "$AW/ep.json" 2>&1)
begin "awg/chain-amnezia5-every-field"
expect_eq "build.sh exit 0" "$BRC" 0
expect_jq "decoded from vpn://: one AWG item" "$(cat "$AW/dec.json")" '.ok==true and (.items|length)==1 and .items[0].kind=="awg"'
expect_jq "the conf carries the AWG 3.1 keys (fixture charged)" "$(cat "$AW/conf.json")" \
	'.i.headerprotectionkey and .i.randomtrailers and .i.disablecookies and .i.rekeyaftertime and .i.keepalivetimeout and .i.i1 and (.p.persistentkeepalive|contains("-"))'
expect_jq "fields compared: at least 23 (every key of the conf except DNS)" "$_cmp" '.checked >= 23'
expect_jq "no key of the conf without a field" "$_cmp" '.unknown == []'
expect_jq "every field equal to the conf" "$_cmp" '.bad == []'
expect_true "sing-box-awg check" "$AWGBIN" check -c /tmp/vpnpool/sing-box.json
end
net_on
run_for "$AWGBIN" /tmp/vpnpool/sing-box.json 4
begin "awg/chain-amnezia5-runs"
expect_eq "engine alive after 4 s" "$RUN_ALIVE" 1
expect_eq "no FATAL" "$(gcount FATAL "$RUN_LOG")" 0
end
net_off

# ======================= start guard (vpnpoold, real sing-box) =======================
# in_vpnpoold <fn>: the real daemon functions (VPNPOOLD_NO_MAIN), log + notifications to a file
GL="$AW/guard.log"
in_vpnpoold() {
	(
		VPNPOOLD_NO_MAIN=1 VPNPOOLD_GUARD_SECS=3; export VPNPOOLD_NO_MAIN VPNPOOLD_GUARD_SECS
		. $LX/vpnpoold
		log() { echo "log $1" >> "$GL"; }
		tg_notify() { echo "notify $1" >> "$GL"; }
		"$@"
		echo "rc=$?" >> "$GL"
	) >/dev/null 2>&1
}
awg_json() {   # <tag> <h2> — an AWG endpoint as a JSON-source outbound (taken verbatim by the parser)
	printf '{"type":"awg","tag":"%s","private_key":"%s","address":["10.8.1.%s/32"],"jc":3,"jmin":10,"jmax":30,"s1":15,"s2":18,"h1":"5-10","h2":"%s","h3":"30","h4":"40","peers":[{"address":"198.51.100.61","port":443,"public_key":"SrvPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0=","allowed_ips":["0.0.0.0/0"]}]}' \
		"$1" "$3" "$4" "$2"
}
G_VL="{\"type\":\"vless\",\"tag\":\"GoodV\",\"server\":\"203.0.113.41\",\"server_port\":443,\"uuid\":\"$U\",\"tls\":{\"enabled\":true,\"server_name\":\"a.example\"}}"
sc_start() { start_singbox; start_guard; }
# 1) one AWG node dies at start (overlapping headers: check passes) -> set aside, rebuilt, runs
reset_state; engine_on; sb_kill_all; : > "$GL"
mkdir -p /tmp/vpnpool/sources
printf '{"outbounds":[%s,%s]}\n' "$G_VL" "$(awg_json BadAWG 8-20 YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk= 9)" > /tmp/vpnpool/sources/000.raw
build
_b1=$BRC; _c1=$(jq -c '[.endpoints[]?.tag]' /tmp/vpnpool/sing-box.json 2>/dev/null)
in_vpnpoold sc_start
begin "awg/guard-node-dies-at-start-set-aside"
expect_eq "first build ok" "$_b1" 0
expect_eq "the bad node was in the first config (check let it through)" "$_c1" '["BadAWG"]'
expect_eq "guard returned 0" "$(grep -c '^rc=0' "$GL")" 1
expect_true "sing-box alive" sh -c 'kill -0 "$(cat /var/run/vpnpool-singbox.pid)"'
expect_jq "config without the node" "$(cat /tmp/vpnpool/sing-box.json)" '([.endpoints[]?.tag] | index("BadAWG") == null) and ([.outbounds[].tag] | index("GoodV") != null)'
expect_jq "deferred: start_failed with the engine's message" "$(cat /tmp/vpnpool/deferred.json)" \
	'length==1 and .[0].tag=="BadAWG" and .[0].reason=="start_failed" and (.[0].detail|contains("headers must not overlap"))'
expect_jq "guard_status: node_excluded" "$(cat /tmp/vpnpool/guard_status.json)" '.action=="node_excluded" and .tag=="BadAWG" and (.id|length)==12'
expect_jq "status lists it as deferred" "$(sh $LX/status.sh 2>/dev/null)" '[.nodes[] | select(.tag=="BadAWG" and .deferred==true and .reason=="start_failed")] | length==1'
expect_eq "the user is told" "$(gcount '^notify .*BadAWG' "$GL")" 1
end
# the daemon finds and stops OUR sing-box whichever binary runs it (sing-box-awg here)
sc_pids() { our_singbox_pids > "$AW/pids"; kill_singbox; our_singbox_pids > "$AW/pids.after"; }
_pre=$(pgrep -f 'sing-box-awg run -c /tmp/vpnpool/sing-box.json' | wc -l)
in_vpnpoold sc_pids
begin "awg/daemon-finds-the-engine-process"
expect_eq "control: sing-box-awg ran our config" "$_pre" 1
expect_eq "our_singbox_pids found it" "$(wc -l < "$AW/pids")" 1
expect_eq "kill_singbox stopped it" "$(wc -l < "$AW/pids.after")" 0
expect_eq "nothing left running" "$(pgrep -f 'sing-box-awg run -c' | wc -l)" 0
end
sb_kill_all
# the mark holds only for the SAME node config + engine: a fixed node is tried again
sed -i 's/"h2":"8-20"/"h2":"20"/' /tmp/vpnpool/sources/000.raw
build
begin "awg/guard-mark-ends-when-the-node-changes"
expect_eq "build ok" "$BRC" 0
expect_jq "the fixed node is back in the config" "$(cat /tmp/vpnpool/sing-box.json)" '[.endpoints[]?.tag] | index("BadAWG") != null'
expect_jq "nothing deferred" "$(cat /tmp/vpnpool/deferred.json)" 'length==0'
end
# 2) a FATAL that names no node (a port taken) -> back to the previous config
reset_state; sb_kill_all; : > "$GL"
mkdir -p /tmp/vpnpool/sources
printf '{"outbounds":[%s]}\n' "$G_VL" > /tmp/vpnpool/sources/000.raw
build; _b1=$BRC
sc_prev() { start_singbox; start_guard && save_prev; kill_singbox; }
in_vpnpoold sc_prev
uci set vpnpool.main.test_port=17777; uci commit vpnpool
uhttpd -p 127.0.0.1:17777 -h "$AW"     # holds the port the new config wants
build; _b2=$BRC
in_vpnpoold sc_start
begin "awg/guard-rolls-back-to-previous-config"
expect_eq "both builds ok" "$_b1:$_b2" "0:0"
expect_eq "guard returned 0" "$(grep -c '^rc=0' "$GL")" 2
expect_true "sing-box alive" sh -c 'kill -0 "$(cat /var/run/vpnpool-singbox.pid)"'
expect_true "the previous config runs" cmp -s /tmp/vpnpool/sing-box.json /tmp/vpnpool/sing-box.json.prev
expect_jq "guard_status: rolled_back, the reason kept" "$(cat /tmp/vpnpool/guard_status.json)" '.action=="rolled_back" and (.detail|contains("17777"))'
end
sb_kill_all
# 3) nothing to go back to -> stops, says why
rm -f /tmp/vpnpool/sing-box.json.prev; : > "$GL"
build   # the config that wants the taken port again
in_vpnpoold sc_start
begin "awg/guard-no-previous-config-stops"
expect_eq "guard returned 1" "$(grep -c '^rc=1' "$GL")" 1
expect_jq "guard_status: failed" "$(cat /tmp/vpnpool/guard_status.json)" '.action=="failed"'
end
for p in $(pgrep -f "uhttpd -p 127.0.0.1:17777"); do kill "$p"; done
sb_kill_all
# 4) my limit: three nodes that each die at start -> two repairs, then the supervisor's turn
reset_state; sb_kill_all; : > "$GL"
mkdir -p /tmp/vpnpool/sources
printf '{"outbounds":[%s,%s,%s,%s]}\n' "$G_VL" \
	"$(awg_json Bad1 8-20 YBk1FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk= 11)" \
	"$(awg_json Bad2 8-20 YBk2FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk= 12)" \
	"$(awg_json Bad3 8-20 YBk3FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk= 13)" > /tmp/vpnpool/sources/000.raw
build
_t0=$(date +%s)
in_vpnpoold sc_start
_t1=$(date +%s)
begin "awg/guard-limit-two-repairs"
expect_eq "guard returned 1" "$(grep -c '^rc=1' "$GL")" 1
expect_eq "two nodes set aside" "$(jq 'length' /tmp/vpnpool/.bad_nodes.json 2>/dev/null)" 2
expect_jq "guard_status: gave_up" "$(cat /tmp/vpnpool/guard_status.json)" '.action=="gave_up"'
expect_eq "sing-box started 3 times (1 + 2 repairs)" "$(gcount '^log sing-box started' "$GL")" 3
expect_le "finished in bounded time (s)" "$((_t1 - _t0))" 60
end
sb_kill_all; engine_off

# ======================= rpcd / api: analyze, add, import_nodes, delete by id =======================
reset_state; daemon_start
rcall analyze "$(jarg --rawfile t "$AFX/awg3.conf" '{text:$t}')"
begin "awg/analyze-conf-no-engine"
expect_jq "one AWG item to add, deferred, with id/name/server/hint" "$R" \
	'.ok==true and (.items|length)==1 and (.items[0] | .kind=="awg" and .type=="awg" and .status=="add" and (.id|length)==12
	 and .name=="198.51.100.61:443" and .server=="198.51.100.61" and .port==443 and .deferred=="engine_missing" and .hints==["awg_random_trailers"])'
expect_jq "summary: 1 add, 1 pending" "$R" '.summary.add==1 and .summary.pending==1'
expect_true "nothing written" sh -c '! ls /etc/vpnpool/awg/*.conf >/dev/null 2>&1'
end
rcall analyze "$(jarg --rawfile t "$AFX/dec/awg2_caption_wrapped.txt" '{text:$t}')"
begin "awg/analyze-vpn-link-wrapped-with-caption"
expect_jq "the AWG item named from the link + the client address" "$R" \
	'[.items[] | select(.kind=="awg" and .status=="add")] | length==1 and .[0].name=="Мой сервер (10.8.1.17)" and .[0].server=="198.51.100.7" and .[0].port==46139'
end
rcall analyze "$(jarg --rawfile t "$AFX/dec/api_key.txt" '{text:$t}')"
begin "awg/analyze-vpn-api-key-refused"
expect_jq "skip api_key" "$R" '[.items[] | select(.kind=="awg")][0] | .status=="skip" and .reason=="api_key"'
end
rcall analyze "$(jarg --rawfile t "$AFX/awg-multipeer.conf" '{text:$t}')"
begin "awg/analyze-multi-peer-reason"
expect_jq "skip awg_multi_peer" "$R" '.items[0] | .status=="skip" and .reason=="awg_multi_peer"'
end
sed 's/^S4 = .*/S4 = 11/' "$AFX/awg3.conf" > "$AW/bad-s4.conf"
rcall analyze "$(jarg --rawfile t "$AW/bad-s4.conf" '{text:$t}')"
begin "awg/analyze-bad-value-field"
expect_jq "skip awg_bad_value, field s4" "$R" '.items[0] | .status=="skip" and .reason=="awg_bad_value" and .field=="s4"'
end
# add: stored as awg/<id>.conf with the name on top, ONE signal, ok + warning without the engine
: > "$FAKED_LOG"
rcall add "$(jarg --rawfile t "$AFX/dec/awg2_amnezia5.txt" '{text:$t}')"
_id=$(printf '%s' "$R" | jq -r '.awg_ids[0] // ""')
begin "awg/add-vpn-link-no-engine-deferred"
expect_jq "ok, added 1, warning engine_missing" "$R" '.ok==true and .code=="added" and .added==1 and .warning=="engine_missing" and .daemon=="signalled"'
expect_true "the file is awg/<id>.conf" [ -f "/etc/vpnpool/awg/$_id.conf" ]
expect_eq "first line: the name" "$(head -1 "/etc/vpnpool/awg/$_id.conf" 2>/dev/null)" "# Name = Мой сервер (10.8.1.17)"
expect_eq "one USR1" "$(signals_seen USR1)" 1
expect_jq "the parser reads the name back as the tag" "$(ucode $PARSER --with-id "/etc/vpnpool/awg/$_id.conf" 2>/dev/null)" \
	".[0].tag==\"Мой сервер (10.8.1.17)\" and .[0].id==\"$_id\""
end
rcall add "$(jarg --rawfile t "$AFX/dec/awg2_amnezia5.txt" '{text:$t}')"
begin "awg/add-same-node-again-dup"
expect_jq "nothing_added, 1 dup" "$R" '.ok==false and .code=="nothing_added" and .dup==1'
expect_eq "still one file" "$(ls /etc/vpnpool/awg/*.conf | wc -l)" 1
end
# a name with line breaks (the link's description is untrusted) must not inject lines
jq -n --rawfile c "$AFX/awg2.conf" '{containers:[{container:"amnezia-awg2", awg:{last_config:({config:$c}|tojson)}}],
	defaultContainer:"amnezia-awg2", hostName:"198.51.100.61", description:"Evil\n[Peer]\nEndpoint = 203.0.113.66:1"}' \
	| base64 | tr -d '\n=' | tr '+/' '-_' | sed 's/^/vpn:\/\//' > "$AW/evil.txt"
rcall add "$(jarg --rawfile t "$AW/evil.txt" '{text:$t}')"
_ide=$(printf '%s' "$R" | jq -r '.awg_ids[0] // ""')
begin "awg/add-name-cannot-inject-lines"
expect_jq "added" "$R" '.ok==true and .added==1'
expect_eq "one [Peer] section in the stored file" "$(gcount '^\[Peer\]' "/etc/vpnpool/awg/$_ide.conf")" 1
expect_eq "the name on ONE comment line" "$(head -1 "/etc/vpnpool/awg/$_ide.conf")" "# Name = Evil [Peer] Endpoint = 203.0.113.66:1 (10.8.1.9)"
expect_jq "still one node, the real endpoint" "$(ucode $PARSER "/etc/vpnpool/awg/$_ide.conf" 2>/dev/null)" 'length==1 and .[0].peers[0].address=="198.51.100.61"'
end
rm -f "/etc/vpnpool/awg/$_ide.conf"
# old method import_nodes: the same path (awgdecode --json), id-named file
rcall import_nodes "$(jarg --rawfile t "$AFX/vec/A_modern.txt" '{text:$t}')"
_id2=$(printf '%s' "$R" | jq -r '.id // ""')
begin "awg/import-nodes-vpn-link"
expect_jq "ok, awg, id, warning" "$R" '.ok==true and .awg==true and (.id|length)==12 and .warning=="engine_missing"'
expect_true "awg/<id>.conf" [ -f "/etc/vpnpool/awg/$_id2.conf" ]
end
rcall import_nodes '{"text":"vpn://AAAA"}'
begin "awg/import-nodes-bad-link"
expect_jq "decode_failed" "$R" '.ok==false and .code=="decode_failed"'
end
# delete by id (the node waits for the engine, it is not in nodes.json)
sh $LX/build.sh >/dev/null 2>&1
rcall delete_node "$(jarg --arg i "$_id2" '{id:$i}')"
begin "awg/delete-by-id"
expect_jq "deleted" "$R" '.ok==true and .code=="deleted"'
expect_true "file gone" [ ! -f "/etc/vpnpool/awg/$_id2.conf" ]
expect_true "the other one kept" [ -f "/etc/vpnpool/awg/$_id.conf" ]
end
rcall delete_node '{"id":"0123456789ab"}'
begin "awg/delete-unknown-id"
expect_jq "not_found" "$R" '.ok==false and .code=="not_found"'
end
# delete by tag of a deferred node (listed from deferred.json)
_tag=$(jq -r '.[0].tag // ""' /tmp/vpnpool/deferred.json 2>/dev/null)
rcall delete_node "$(jarg --arg t "$_tag" '{tag:$t}')"
begin "awg/delete-deferred-by-tag"
expect_true "control: a deferred tag ($_tag)" [ -n "$_tag" ]
expect_jq "deleted" "$R" '.ok==true and .code=="deleted"'
expect_eq "no AWG file left" "$(ls /etc/vpnpool/awg/*.conf 2>/dev/null | wc -l)" 0
end
# with the engine: no warning; an xray container from vpn:// becomes a link node
rm -f /etc/vpnpool/awg/*.conf   # independent of the delete cases above
engine_on
rcall add "$(jarg --rawfile t "$AFX/awg3.conf" '{text:$t}')"
begin "awg/add-with-engine-no-warning"
expect_jq "ok without a warning" "$R" '.ok==true and .added==1 and (has("warning")|not)'
end
rcall add "$(jarg --rawfile t "$AFX/dec/xray_reality.txt" '{text:$t}')"
begin "awg/add-vpn-xray-becomes-link"
expect_jq "added as a link" "$R" '.ok==true and .added==1'
expect_true "a vless link stored" sh -c 'uci -q get vpnpool.main.manual_node | grep -q "^vless://"'
end
engine_off; daemon_stop; net_off
srs_off
