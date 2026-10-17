# suite: awgdecode — vpn:// (AmneziaVPN) decoder awgdecode.uc (sourced by run.sh)
# Vectors: fixtures/awg/vec (gen.py) + fixtures/awg/dec (gen-dec.py; made-up keys, doc IPs).
# Every decoder run is under a watchdog: junk after vpn:// used to spin the inflate forever.
# Contract (--json): {ok, items:[{kind, conf|link, name, host, ...}], code?, found?}.

AWGDEC=/usr/libexec/vpnpool/awgdecode.uc
PARSER=/usr/libexec/vpnpool/parser.uc
AFX="$T_DIR/fixtures/awg"
AD="$T_STATE/awgdecode"
mkdir -p "$AD"

# dj <file> [extra args] — decoder --json on stdin; sets DJ (stdout) and DRC (exit; 124 = hung)
dj() {
	_f=$1; shift
	rm -f "$AD/out"
	rm -f "$AD/cpu"
	run_with_timeout 20 sh -c 'busybox time -o "$4" -f "%U %S" ucode "$1" --json < "$2" > "$3" 2>/dev/null' _ "$AWGDEC" "$_f" "$AD/out" "$AD/cpu"
	DRC=$?
	# CPU seconds of the decoder (user + sys, rounded up): unlike wall clock, it does not grow
	# when other stand runs share the machine
	# (a non-zero exit adds a "Command exited ..." line first: take the LAST line; no number = 99)
	DCPU=$(awk 'END { if ($1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9.]+$/) { s = $1 + $2; c = int(s); if (c < s) c++; print c } }' "$AD/cpu" 2>/dev/null)
	DCPU=${DCPU:-99}
	DJ=$(cat "$AD/out" 2>/dev/null)
}
# dl <file> — legacy mode (what rpcd calls today): raw .conf on stdout
dl() {
	_lf=$1
	rm -f "$AD/legacy"
	run_with_timeout 20 sh -c 'ucode "$1" < "$2" > "$3" 2>/dev/null' _ "$AWGDEC" "$_lf" "$AD/legacy"
	DRC=$?
}
item_conf() { printf '%s' "$DJ" | jq -r '[.items[]? | select(.kind=="awg" or .kind=="wireguard")][0].conf // empty'; }
item_link() { printf '%s' "$DJ" | jq -r '[.items[]? | select(.kind=="link")][0].link // empty'; }

# ---- 1. every vector of fixtures/awg/vec: JSON item -> parser.uc -> one AWG node; legacy too ----
nvec=0
for _vf in "$AFX"/vec/*.txt; do
	[ -f "$_vf" ] || continue
	v=$(basename "$_vf" .txt); nvec=$((nvec + 1))
	host=198.51.100.61; port=443
	[ "$v" = K_hostname_endpoint ] && { host=vpn.example.com; port=51820; }
	begin "awgdecode/vec-$v"
	dj "$_vf"
	expect_true "finished (rc=$DRC)" [ "$DRC" -eq 0 ]
	expect_jq "ok + one item" "$DJ" '.ok==true and (.items|length)==1'
	expect_jq "item shape" "$DJ" '.items[0] | (.kind=="awg") and (.conf|type=="string") and (.name|type=="string" and length>0) and (.host|type=="string")'
	expect_jq "host from Endpoint" "$DJ" ".items[0].host==\"$host\""
	item_conf > "$AD/$v.conf"
	_p=$(ucode "$PARSER" "$AD/$v.conf" 2>/dev/null)
	expect_jq "conf parses to one awg node" "$_p" "length==1 and .[0].type==\"awg\" and .[0].peers[0].address==\"$host\" and .[0].peers[0].port==$port"
	expect_jq "private key kept" "$_p" '.[0].private_key=="YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk="'
	dl "$_vf"
	expect_true "legacy mode: same .conf on stdout" cmp -s "$AD/legacy" "$AD/$v.conf"
	end
done
begin "awgdecode/vec-all-vectors-ran"
expect_true "vec vectors processed: $nvec (expected 16)" [ "$nvec" -eq 16 ]
end

# ---- 2. Amnezia 5.x shape: amnezia-awg2 / key awg / format_version / AWG 3.1 conf ----
begin "awgdecode/amnezia5-awg2"
dj "$AFX/dec/awg2_amnezia5.txt"
expect_jq "one awg item" "$DJ" '.ok and (.items|length)==1 and .items[0].kind=="awg" and .items[0].container=="amnezia-awg2"'
expect_jq "name = description + client address" "$DJ" '.items[0].name=="Мой сервер (10.8.1.17)" and .items[0].client=="10.8.1.17"'
expect_jq "host" "$DJ" '.items[0].host=="198.51.100.7"'
expect_jq "AWG 3.1 fields kept verbatim" "$DJ" '.items[0].conf | contains("HeaderProtectionKey = HPK") and contains("PersistentKeepalive = 25-35") and contains("RandomTrailers = 1")'
expect_jq "no CR in conf" "$DJ" '.items[0].conf | contains("\r") | not'
end

# caption before the link, line wraps, text after it
P_ok() {   # <case> <vector> <kind> <jq-pred>
	begin "awgdecode/$1"
	dj "$AFX/dec/$2.txt"
	expect_true "finished, rc 0 (rc=$DRC)" [ "$DRC" -eq 0 ]
	expect_jq "ok, kind $3" "$DJ" ".ok==true and .items[0].kind==\"$3\""
	expect_jq "$1" "$DJ" "$4"
	end
}
P_ok caption-wrapped-trailing-text awg2_caption_wrapped awg '.items[0].host=="198.51.100.7" and (.items|length)==1'
P_ok trailing-word-after-newline   awg2_trailing_word   awg '.items[0].host=="198.51.100.7"'
P_ok uncompressed-json-crlf-wrapped awg2_uncompressed_wrapped awg '.items[0].client=="10.8.1.17"'
P_ok wireguard-container           wireguard           wireguard '.items[0].container=="amnezia-wireguard" and .items[0].host=="198.51.100.8" and .items[0].name=="198.51.100.8 (10.9.0.5)"'
P_ok default-container-wins        default_xray_wins    link '(.items|length)==1 and .items[0].container=="amnezia-xray"'
P_ok no-default-awg-before-xray    no_default_awg_first awg '.items[0].container=="amnezia-awg2"'
P_ok unsupported-default-falls-back default_unsupported_falls_back link '.items[0].container=="amnezia-xray"'
P_ok two-links-two-items           two_links            awg '(.items|length)==2 and .items[1].kind=="link"'
P_ok same-link-twice-one-item      ../vec/J_two_links   awg '(.items|length)==1'

# wireguard conf -> parser (stock-compatible WireGuard node)
begin "awgdecode/wireguard-conf-parses"
dj "$AFX/dec/wireguard.txt"
item_conf > "$AD/wg.conf"
_p=$(ucode "$PARSER" "$AD/wg.conf" 2>/dev/null)
expect_jq "one node at 198.51.100.8:51820" "$_p" 'length==1 and .[0].peers[0].address=="198.51.100.8" and .[0].peers[0].port==51820'
end

# ---- 3. xray / ssxray -> share links that parser.uc turns into nodes ----
X_link() {   # <case> <vector> <jq-pred on the parsed node list>
	begin "awgdecode/$1"
	dj "$AFX/dec/$2.txt"
	_l=$(item_link)
	expect_true "a link item" [ -n "$_l" ]
	_p=$(parse_link "$_l")
	expect_jq "$1: parser node" "$_p" "$3"
	end
}
parse_link() { printf '%s\n' "$1" | ucode "$PARSER" 2>/dev/null; }
X_link xray-reality-vision xray_reality \
	'length==1 and .[0].type=="vless" and .[0].server=="198.51.100.9" and .[0].server_port==443 and .[0].uuid=="11111111-2222-4333-8444-555555555555" and .[0].flow=="xtls-rprx-vision" and .[0].tls.reality.public_key=="KHu_Zt1CNMIJyAETBVA5LJWiSOiipcxPP2uSw89kkVc" and .[0].tls.reality.short_id=="a1b2c3d4" and .[0].tls.server_name=="www.example.com" and .[0].tls.utls.fingerprint=="chrome" and .[0].tag=="Мой сервер"'
X_link xray-ws-tls-lastconfig-object xray_ws_tls_object \
	'length==1 and .[0].transport.type=="ws" and .[0].transport.path=="/ws path" and .[0].transport.headers.Host=="cdn.example.com" and .[0].tls.server_name=="cdn.example.com" and (.[0].flow // "")==""'
X_link xray-grpc xray_grpc \
	'length==1 and .[0].transport.type=="grpc" and .[0].transport.service_name=="svc"'
# ss:// is SIP002 base64url without padding — today's parser.uc can't read that yet (its
# item 5, xfail there): here the link itself; the parser round trip is ss-sip002-parses [5]
begin "awgdecode/ssxray-ss-link"
dj "$AFX/dec/ssxray.txt"
expect_jq "ss link to 198.51.100.10:8388, name SS" "$DJ" '.ok and .items[0].kind=="link" and (.items[0].link|startswith("ss://")) and (.items[0].link|endswith("@198.51.100.10:8388#SS")) and .items[0].host=="198.51.100.10"'
end

# ---- 4. refusals: a code, no item, never hangs ----
E_code() {   # <case> <vector> <code> [jq-pred]
	begin "awgdecode/$1"
	dj "$AFX/dec/$2.txt"
	expect_true "finished within 20s (rc=$DRC)" [ "$DRC" -ne 124 ]
	expect_true "exit 1" [ "$DRC" -eq 1 ]
	expect_jq "ok:false code $3, no items" "$DJ" ".ok==false and .code==\"$3\" and (.items==null)"
	[ -n "${4:-}" ] && expect_jq "$1" "$DJ" "$4"
	dl "$AFX/dec/$2.txt"
	expect_true "legacy: exit 1 + empty stdout" sh -c '[ "$1" -eq 1 ] && [ ! -s "$2" ]' _ "$DRC" "$AD/legacy"
	end
}
E_code api-key                 api_key                 E_API_KEY
E_code api-key-no-version      api_key_no_version      E_API_KEY
E_code api-config-version-only api_config_version_only E_API_KEY
E_code full-access             full_access             E_FULL_ACCESS
E_code unsupported-containers  unsupported_only        E_NO_SUPPORTED_CONTAINER '.found==["amnezia-openvpn","amnezia-cloak"]'
E_code container-without-conf  no_conf                 E_NO_CONF '.found==["amnezia-awg"]'
E_code not-json                not_json                E_JSON
E_code json-array              json_array              E_FORMAT
E_code json-broken             json_broken             E_JSON
E_code garbage-random          garbage_random          E_FORMAT
E_code garbage-zlib-zeros      garbage_zlib_zeros      E_INFLATE
E_code garbage-zlib-random     garbage_zlib_random     E_INFLATE
E_code truncated-link          truncated               E_INFLATE
E_code bad-adler32             bad_adler               E_INFLATE
E_code bad-length-prefix       bad_length_prefix       E_INFLATE
E_code not-base64              not_base64              E_BASE64
E_code no-link                 no_link                 E_NO_LINK

# the vector the parser suite tracks (old decoder: 100% CPU forever)
begin "awgdecode/garbage-after-scheme-fast"
printf 'vpn://AAAAbm90LWEtcmVhbC1saW5r\n' > "$AD/g1.txt"
_t0=$(date +%s); dj "$AD/g1.txt"; _dt=$(( $(date +%s) - _t0 ))
expect_true "not hung (rc=$DRC)" [ "$DRC" -ne 124 ]
expect_jq "refused with a code" "$DJ" '.ok==false and (.code|startswith("E_"))'
expect_le "seconds" "$_dt" 5
end

# one good + one broken link: the good one is imported, the broken one reported
begin "awgdecode/good-plus-broken"
{ cat "$AFX/dec/awg2_amnezia5.txt"; printf '\n'; cat "$AFX/dec/truncated.txt"; printf '\n'; } > "$AD/mix.txt"
dj "$AD/mix.txt"
expect_jq "ok with one item + one error" "$DJ" '.ok==true and (.items|length)==1 and (.errors|length)==1 and .errors[0].code=="E_INFLATE"'
end

# text as an argument (not stdin) works the same
begin "awgdecode/argv-input"
_o=$(ucode "$AWGDEC" --json "Ключ: $(cat "$AFX/dec/xray_reality.txt")" 2>/dev/null)
expect_jq "link item" "$_o" '.ok and .items[0].kind=="link"'
end

# ---- 5. limits: untrusted input is refused fast and with a code (each <= 3 CPU s on x86) ----
# L <case> <input file> <jq-pred>  — watchdog 20 s + CPU-time bound + exactly one JSON line
L() {
	begin "awgdecode/$1"
	dj "$2"
	expect_true "not hung (rc=$DRC)" [ "$DRC" -ne 124 ]
	expect_le "CPU seconds" "$DCPU" 3
	expect_eq "stdout is one line" "$(printf '%s\n' "$DJ" | grep -c .)" 1
	expect_jq "$1" "$DJ" "$3"
	end
}
awk 'BEGIN { printf "vpn://"; for (i = 0; i < 20000; i++) printf "A "; print "" }' > "$AD/words.txt"
L many-words-40k "$AD/words.txt" '.ok==false and (.code|startswith("E_"))'
L declared-4mb-refused "$AFX/dec/bomb_declared_4mb.txt" '.ok==false and .code=="E_TOO_BIG"'
awk 'BEGIN { s = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; for (i = 0; i < 5000; i++) print s }' > "$AD/big.txt"
cat "$AFX/dec/awg2_amnezia5.txt" >> "$AD/big.txt"
L input-over-256k-refused "$AD/big.txt" '.ok==false and .code=="E_TOO_BIG"'
awk 'BEGIN { for (i = 0; i < 100000; i++) printf "vpn://" }' > "$AD/links100k.txt"
L links-100k-refused "$AD/links100k.txt" '.ok==false and .code=="E_TOO_BIG"'
awk 'BEGIN { for (i = 0; i < 40000; i++) printf "vpn://" }' > "$AD/links40k.txt"
L links-40k-capped "$AD/links40k.txt" '.ok==false and (.errors|length)==33 and .errors[32].code=="E_TOO_MANY"'
L blocks-5000-refused "$AFX/dec/blocks_5000_valid.txt" '.ok==false and .code=="E_INFLATE"'
L blocks-100-decodes "$AFX/dec/blocks_100_valid.txt" '.ok==true and .items[0].kind=="awg"'
begin "awgdecode/near-limit-200k-decodes"
_t0=$(date +%s); dj "$AFX/dec/near_limit_200k_ok.txt"; _dt=$(( $(date +%s) - _t0 ))
expect_jq "ok, awg" "$DJ" '.ok==true and .items[0].kind=="awg" and (.items[0].conf|length) > 190000'
expect_le "seconds (x86)" "$_dt" 15
metric awgdecode_200k_seconds "$_dt"
end
# 32 good links + one more: 32 items, the rest reported once
{ i=0; while [ $i -lt 33 ]; do cat "$AFX/dec/awg2_amnezia5.txt"; printf '\n'; i=$((i + 1)); done; } > "$AD/links33.txt"
L links-33-good "$AD/links33.txt" '.ok==true and (.items|length)==1 and (.errors|length)==1 and .errors[0].code=="E_TOO_MANY"'

# ---- 6. hostile types inside a container: always ONE JSON answer, never a crash ----
H() {   # <case> <vector> <jq-pred>
	begin "awgdecode/$1"
	dj "$AFX/dec/$2.txt"
	expect_true "rc 0 or 1, not a crash (rc=$DRC)" [ "$DRC" -le 1 ]
	expect_eq "stdout is one line" "$(printf '%s\n' "$DJ" | grep -c .)" 1
	expect_jq "$1" "$DJ" "$3"
	end
}
H types-stream-str      xray_stream_str     '.ok==true and (.items[0].link|contains("type=tcp&security=none"))'
H types-reality-num     xray_reality_num    '.ok==true and (.items[0].link|contains("security=reality")) and (.items[0].link|contains("pbk=")|not)'
H types-ws-headers-str  xray_ws_headers_str '.ok==true and (.items[0].link|contains("type=ws")) and (.items[0].link|contains("host=")|not) and (.items[0].link|contains("path=")|not)'
H types-vnext-str       xray_vnext_str      '.ok==false and .code=="E_NO_CONF"'
H types-settings-array  xray_settings_arr   '.ok==false and .code=="E_NO_CONF"'
H types-nonscalar-dropped xray_nonscalar    '.ok==true and (.items[0].link|contains("type=tcp&security=none")) and (.items[0].link|contains("%5B")|not)'
H tcp-http-header-insecure xray_tcp_http_insecure '.ok==true and (.items[0].link|contains("headerType=http&path=%2Fp&host=h.example.com")) and (.items[0].link|contains("allowInsecure=1"))'
H awg-endpoint-colon-refused awg_endpoint_colon '.ok==false and .code=="E_NO_CONF"'

# ss:// per SIP002: base64url userinfo without padding, decodes back to method:password
begin "awgdecode/ss-sip002-base64url"
dj "$AFX/dec/ss_sip002.txt"
_l=$(item_link)
_ui=$(printf '%s' "$_l" | sed -n 's|^ss://\([^@]*\)@.*|\1|p')
expect_true "userinfo present" [ -n "$_ui" ]
expect_true "url-safe, no padding" sh -c 'case "$1" in *[+/=]*) exit 1;; esac' _ "$_ui"
printf '%s\n' "let s = replace(replace(ARGV[0], /-/g, '+'), /_/g, '/'); while (length(s) % 4) s += '='; print(b64dec(s));" > "$AD/b64.uc"
_dec=$(ucode "$AD/b64.uc" "$_ui" 2>/dev/null)
expect_eq "decodes to method:password" "$_dec" 'aes-256-gcm:???>>>???'
end
# the ssxray link through parser.uc (base64url without padding — parser item 5, done)
begin "awgdecode/ss-sip002-parses"
_p=$(parse_link "$_l")
expect_jq "shadowsocks node, password intact" "$_p" 'length==1 and .[0].type=="shadowsocks" and .[0].password=="???>>>???"'
end

# ---- 7. legacy mode looks through ALL containers for a .conf (default xray + awg) ----
begin "awgdecode/legacy-default-xray-still-gives-conf"
dl "$AFX/dec/default_xray_wins.txt"
expect_true "exit 0 (rc=$DRC)" [ "$DRC" -eq 0 ]
expect_true "the awg .conf" grep -q '^Endpoint = 198.51.100.7:46139' "$AD/legacy"
end
begin "awgdecode/legacy-xray-only-no-output"
dl "$AFX/dec/xray_reality.txt"
expect_true "exit 1 + empty stdout" sh -c '[ "$1" -eq 1 ] && [ ! -s "$2" ]' _ "$DRC" "$AD/legacy"
end

# no human text in the machine output (texts live in po)
begin "awgdecode/no-human-text-in-errors"
_bad=0; _n=0
for _vf in "$AFX"/dec/*.txt; do
	dj "$_vf"; _n=$((_n + 1))
	printf '%s' "$DJ" | jq -e 'has("ok") and (if .ok then true else (keys - ["ok","code","found","errors"] | length)==0 end)' >/dev/null 2>&1 || _bad=$((_bad + 1))
done
expect_true "checked $_n dec vectors (expected 43)" [ "$_n" -eq 43 ]
expect_eq "outputs with keys outside the contract" "$_bad" 0
end
