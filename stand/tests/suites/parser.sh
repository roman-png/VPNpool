# suite: parser — link corpus / AWG .conf / vpn:// vectors -> parser.uc output (sourced by run.sh)
# Each case: input text -> parser.uc JSON -> jq predicates that must all be true.
# Known defects carry the ROADMAP-2.0 item as the xfail id (5 = stage 5 parser, 4.3/4.5 = AWG).

PARSER=/usr/libexec/vpnpool/parser.uc
AWGDEC=/usr/libexec/vpnpool/awgdecode.uc
FX="$T_DIR/fixtures"
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
PBK=KHu_Zt1CNMIJyAETBVA5LJWiSOiipcxPP2uSw89kkVc

parse_text() { printf '%s\n' "$1" | ucode "$PARSER" 2>/dev/null; }

# P <id> <xfail-id|-> <input-text> <jq-pred>...
P() {
	_id=$1; _xf=$2; _in=$3; shift 3
	[ "$_xf" = - ] && _xf=""
	begin "parser/$_id"
	_out=$(parse_text "$_in")
	expect_jq "valid JSON array" "$_out" 'type=="array"'
	for _p in "$@"; do expect_jq "$_id" "$_out" "$_p"; done
	end "$_xf"
}

# ---- positive control: the corpus machinery itself (a node we KNOW parses) ----
P vless-reality-vision - \
	"vless://$U@203.0.113.10:443?type=tcp&security=reality&pbk=$PBK&sid=ab12&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#R1" \
	'length==1' '.[0].type=="vless"' '.[0].server=="203.0.113.10"' '.[0].server_port==443' \
	".[0].uuid==\"$U\"" '.[0].flow=="xtls-rprx-vision"' ".[0].tls.reality.public_key==\"$PBK\"" \
	'.[0].tls.reality.short_id=="ab12"' '.[0].tls.server_name=="www.microsoft.com"' \
	'.[0].tls.utls.fingerprint=="chrome"' '.[0].tag=="R1"'
P vless-reality-default-utls - \
	"vless://$U@203.0.113.10:443?security=reality&pbk=$PBK&sni=a.example#R2" \
	'.[0].tls.utls.enabled==true and .[0].tls.utls.fingerprint=="chrome"'
P vless-tls-ws - \
	"vless://$U@ws.example.com:443?type=ws&security=tls&sni=ws.example.com&path=%2Fws&host=cdn.example.com#WS" \
	'.[0].transport.type=="ws"' '.[0].transport.path=="/ws"' '.[0].transport.headers.Host=="cdn.example.com"' \
	'.[0].tls.enabled==true and .[0].tls.server_name=="ws.example.com"'
P vless-grpc - \
	"vless://$U@g.example.com:443?type=grpc&security=tls&serviceName=gsvc#G" \
	'.[0].transport.type=="grpc" and .[0].transport.service_name=="gsvc"'
P vless-flow-variant-normalised - \
	"vless://$U@203.0.113.11:443?security=reality&pbk=$PBK&flow=xtls-rprx-vision-udp443#F" \
	'.[0].flow=="xtls-rprx-vision"'
P vless-unknown-flow-dropped - \
	"vless://$U@203.0.113.12:443?security=tls&flow=xtls-rprx-direct#D" 'length==0'
P vless-bad-reality-key-dropped - \
	"vless://$U@203.0.113.13:443?security=reality&pbk=short#K" 'length==0'

VM=$(printf '%s' "{\"v\":\"2\",\"ps\":\"VM\",\"add\":\"vm.example.com\",\"port\":\"443\",\"id\":\"$U\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"vm.example.com\",\"path\":\"/vm\",\"tls\":\"tls\",\"sni\":\"vm.example.com\"}" | base64 -w0)
P vmess-ws-tls - "vmess://$VM" \
	'.[0].type=="vmess"' '.[0].server_port==443' ".[0].uuid==\"$U\"" '.[0].transport.path=="/vm"' \
	'.[0].tls.server_name=="vm.example.com"' '.[0].tag=="VM"'
P trojan-tls - "trojan://secretpw@tr.example.com:443?security=tls&sni=tr.example.com&type=tcp#TR" \
	'.[0].type=="trojan"' '.[0].password=="secretpw"' '.[0].tls.server_name=="tr.example.com"'
P trojan-grpc - "trojan://pw@tr.example.com:443?type=grpc&serviceName=tg&sni=tr.example.com#TG" \
	'.[0].transport.type=="grpc" and .[0].transport.service_name=="tg"'
P ss-sip002 - "ss://$(printf 'aes-256-gcm:pass1' | base64 -w0)@ss.example.com:8388#SS" \
	'.[0].type=="shadowsocks"' '.[0].method=="aes-256-gcm"' '.[0].password=="pass1"' '.[0].server_port==8388'
P ss-legacy - "ss://$(printf 'aes-128-gcm:pw2@198.51.100.20:8389' | base64 -w0)#L" \
	'.[0].server=="198.51.100.20" and .[0].server_port==8389 and .[0].password=="pw2"'
P base64-subscription-blob - \
	"$(printf 'vless://%s@203.0.113.20:443?security=reality&pbk=%s#B1\ntrojan://p@203.0.113.21:443?sni=x.example#B2\n' "$U" "$PBK" | base64 -w0)" \
	'length==2' 'map(.tag)==["B1","B2"]'
P singbox-json-outbounds - \
	"{\"outbounds\":[{\"type\":\"selector\",\"tag\":\"sel\",\"outbounds\":[\"j1\"]},{\"type\":\"vless\",\"tag\":\"j1\",\"server\":\"203.0.113.22\",\"server_port\":443,\"uuid\":\"$U\"},{\"type\":\"direct\",\"tag\":\"direct\"}]}" \
	'length==1 and .[0].tag=="j1"'
P junk-and-unknown-schemes - "$(printf 'hello\nhttp://x.example/\nsocks://abc\nvless://broken\n')" 'length==0'
# A body that merely LOOKS like JSON (starts with "[" or "{") makes json() throw: parser.uc
# dies with no output at all, so in build.sh ONE such source file empties the whole pool.
# Not an item of ROADMAP-2.0 -> new defect, id NEW-1 (see HANDOFF_stage0.md).
P json-looking-junk-no-crash NEW-1 "[not json at all" 'length==0'
P duplicate-line-dedup - \
	"$(printf 'vless://%s@203.0.113.23:443?security=tls#Same\nvless://%s@203.0.113.23:443?security=tls#Same\n' "$U" "$U")" 'length==1'

# ---- known parser gaps (ROADMAP §8, stage 5) ----
P ss-base64url-nopad 5 "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpUcT5-P2I@ss.example.com:8388#U" \
	'length==1' '.[0].method=="chacha20-ietf-poly1305"' '.[0].password=="Tq>~?b"'
P ss-2022-urlencoded-userinfo 5 "ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@ss.example.com:8388#S22" \
	'.[0].method=="2022-blake3-aes-128-gcm"' '.[0].password=="AAECAwQFBgcICQoLDA0ODw=="'
P ss-plugin 5 "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#P" \
	'.[0].server_port==8388' '.[0].plugin=="obfs-local"' '.[0].plugin_opts=="obfs=http;obfs-host=cdn.example.com"'
P vless-ipv6-brackets 5 "vless://$U@[2001:db8::1]:443?security=tls&sni=v6.example.com&type=tcp#V6" \
	'length==1' '.[0].server=="2001:db8::1"' '.[0].server_port==443'
P trojan-ipv6-brackets 5 "trojan://pw@[2001:db8::2]:443?sni=v6.example.com#T6" \
	'length==1' '.[0].server=="2001:db8::2"'
P vless-host-port-slash-query 5 "vless://$U@slash.example.com:443/?type=tcp&security=tls&sni=slash.example.com#S" \
	'length==1' '.[0].server=="slash.example.com"' '.[0].tls.server_name=="slash.example.com"'
P hysteria2 5 "hysteria2://hypw@hy.example.com:8443?sni=hy.example.com&obfs=salamander&obfs-password=obpw&insecure=1#HY" \
	'length==1' '.[0].type=="hysteria2"' '.[0].password=="hypw"' '.[0].server_port==8443' \
	'.[0].obfs.type=="salamander" and .[0].obfs.password=="obpw"' '.[0].tls.server_name=="hy.example.com"' '.[0].tls.insecure==true'
P hy2-alias 5 "hy2://hypw@hy.example.com:443?sni=hy.example.com#HY2" '.[0].type=="hysteria2"'
P tuic 5 "tuic://$U:tupw@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com&udp_relay_mode=native#TU" \
	'.[0].type=="tuic"' ".[0].uuid==\"$U\"" '.[0].password=="tupw"' '.[0].congestion_control=="bbr"' \
	'.[0].udp_relay_mode=="native"' '.[0].tls.alpn==["h3"]'
P vless-xhttp-refused 5 "vless://$U@x.example.com:443?type=xhttp&security=tls&path=%2Fx#XH" 'length==0'
P vless-splithttp-refused 5 "vless://$U@x.example.com:443?type=splithttp&security=tls#SH" 'length==0'
P vless-httpupgrade 5 "vless://$U@u.example.com:443?type=httpupgrade&security=tls&path=%2Fup&host=u.example.com#HU" \
	'.[0].transport.type=="httpupgrade" and .[0].transport.path=="/up"'
P vless-h2 5 "vless://$U@h.example.com:443?type=http&security=tls&path=%2Fh2&host=h.example.com#H2" \
	'.[0].transport.type=="http"'
P vless-quic 5 "vless://$U@q.example.com:443?type=quic&security=tls#Q" '.[0].transport.type=="quic"'
P vless-ws-early-data 5 "vless://$U@ws.example.com:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048#ED" \
	'.[0].transport.path=="/ws"' '.[0].transport.max_early_data==2048'
P vless-tcp-http-header 5 "vless://$U@t.example.com:80?type=tcp&headerType=http&host=t.example.com&path=%2F#TH" \
	'.[0].transport.type=="http"'
P vless-alpn 5 "vless://$U@a.example.com:443?security=tls&alpn=h2%2Chttp%2F1.1#AL" '.[0].tls.alpn==["h2","http/1.1"]'
P vless-allow-insecure 5 "vless://$U@a.example.com:443?security=tls&allowInsecure=1#AI" '.[0].tls.insecure==true'
P trojan-security-none 5 "trojan://pw@tn.example.com:80?security=none#TN" '(.[0].tls.enabled // false)==false'
P trojan-reality 5 "trojan://pw@tr.example.com:443?security=reality&pbk=$PBK&sid=01&sni=www.microsoft.com#TRR" \
	".[0].tls.reality.public_key==\"$PBK\""
# tag suffixes must be unique (ROADMAP 2.1): "A", "A", "A #2" -> today two nodes end up tagged "A #2"
P tag-suffix-unique 2.1 \
	"$(printf 'vless://%s@203.0.113.31:443?security=tls#A\nvless://%s@203.0.113.32:443?security=tls#A\nvless://%s@203.0.113.33:443?security=tls#A%%20%%232\n' "$U" "$U" "$U")" \
	'length==3' '(map(.tag)|unique|length)==3'

# ---- AmneziaWG / WireGuard .conf ----
PF() {   # like P, but input is a fixture file
	_id=$1; _xf=$2; _f=$3; shift 3
	[ "$_xf" = - ] && _xf=""
	begin "parser/$_id"
	_out=$(ucode "$PARSER" "$_f" 2>/dev/null)
	expect_jq "valid JSON array" "$_out" 'type=="array"'
	for _p in "$@"; do expect_jq "$_id" "$_out" "$_p"; done
	end "$_xf"
}
PF awg2-conf - "$FX/awg/awg2.conf" \
	'length==1' '.[0].type=="awg"' '.[0].private_key=="YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk="' \
	'.[0].jc==4 and .[0].jmin==10 and .[0].jmax==50 and .[0].s1==89 and .[0].s2==112 and .[0].s3==21 and .[0].s4==9' \
	'.[0].h1=="1047436521-1047436999"' '(.[0].i1|startswith("<r 2>"))' '.[0].mtu==1280' \
	'.[0].address==["10.8.1.9/32","fd00::9/128"]' '.[0].peers[0].address=="198.51.100.61" and .[0].peers[0].port==443' \
	'.[0].peers[0].preshared_key=="PSKFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE="' '.[0].peers[0].persistent_keepalive_interval==25'
PF awg3-conf-fields 4.3 "$FX/awg/awg3.conf" \
	'length==1' '.[0].header_protection_key=="c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI="' \
	'.[0].random_trailers==true' '.[0].disable_cookies==true' '.[0].rekey_after_time!=null' \
	'.[0].content_padding_addition!=null'
PF wireguard-plain-conf 4.3 "$FX/awg/wg-plain.conf" \
	'length==1' '.[0].type=="wireguard"' '.[0].peers[0].pre_shared_key=="WGpskFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0="'
PF awg-multi-peer-refused 4.3 "$FX/awg/awg-multipeer.conf" 'length==0'
mkdir -p "$T_STATE/parser"
sed 's/^\[Interface\]/[INTERFACE]/; s/^\[Peer\]/[PEER]/' "$FX/awg/awg2.conf" > "$T_STATE/parser/upper.conf"
PF awg-section-case-insensitive 4.3 "$T_STATE/parser/upper.conf" 'length==1 and .[0].type=="awg"'

# ---- vpn:// (AmneziaVPN) vectors: awgdecode.uc -> .conf -> parser.uc ----
# Accepts today's output (raw .conf on stdout) and the planned one (ROADMAP 4.5: JSON
# {ok,items:[{kind,conf|link,...}]}): picks the item of kind awg/wireguard, NOT items[0] — a
# vector may carry an xray container first (E_xray_first).
decode_vpn() {   # bounded: a decoder stuck in a loop must fail the case, not hang the run
	rm -f "$T_STATE/parser/dec.out"
	run_with_timeout 20 sh -c 'ucode "$1" < "$2" > "$3" 2>/dev/null' _ "$AWGDEC" "$1" "$T_STATE/parser/dec.out"
	_d=$(cat "$T_STATE/parser/dec.out" 2>/dev/null)
	case "$_d" in
		\{*) printf '%s' "$_d" | jq -r '([.items[]? | select((.conf|type)=="string" and (.kind=="awg" or .kind=="wireguard" or (.conf|contains("[Interface]"))))][0].conf) // empty' 2>/dev/null ;;
		*) printf '%s\n' "$_d" ;;
	esac
}
V() {   # V <vector> <xfail|-> <expected host> <expected port>
	_v=$1; _xf=$2; [ "$_xf" = - ] && _xf=""
	begin "parser/vpn-$_v"
	_conf=$(decode_vpn "$FX/awg/vec/$_v.txt")
	printf '%s\n' "$_conf" > "$T_STATE/parser/$_v.conf"
	expect_true "decoded to an [Interface] conf" grep -q '^\[Interface\]' "$T_STATE/parser/$_v.conf"
	_out=$(ucode "$PARSER" "$T_STATE/parser/$_v.conf" 2>/dev/null)
	expect_jq "parses to one AWG node" "$_out" 'length==1 and (.[0].type=="awg" or .[0].type=="wireguard")'
	expect_jq "endpoint" "$_out" ".[0].peers[0].address==\"$3\" and .[0].peers[0].port==$4"
	expect_jq "private key" "$_out" '.[0].private_key=="YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk="'
	end "$_xf"
}
V A_modern               -   198.51.100.61 443
V B_wrapped76            4.5 198.51.100.61 443
V B2_wrapped_crlf        -   198.51.100.61 443
V B3_space_inside        4.5 198.51.100.61 443
V C_label_prefix         4.5 198.51.100.61 443
V D_old_plainjson        4.5 198.51.100.61 443
V E_xray_first           4.5 198.51.100.61 443
V F_stored_level0        -   198.51.100.61 443
V G_lastconfig_object    -   198.51.100.61 443
V H_crlf_conf            -   198.51.100.61 443
V I_padded_std_b64       -   198.51.100.61 443
V J_two_links            4.5 198.51.100.61 443
V K_hostname_endpoint    -   vpn.example.com 51820
V L_big_I2               -   198.51.100.61 443
V M_no_psk_noKA          -   198.51.100.61 443
V N_awg_key_variant_amnezia_awg2 4.5 198.51.100.61 443

# garbage after vpn:// must be rejected QUICKLY: today the pure-ucode inflate spins forever
# on it (100% CPU; via rpcd import_nodes that is a hung call) -> ROADMAP 4.5 "awgdecode robust".
begin "parser/vpn-garbage-rejected"
printf 'vpn://AAAAbm90LWEtcmVhbC1saW5r
' > "$T_STATE/parser/garbage.txt"
run_with_timeout 20 sh -c 'ucode "$1" < "$2" > "$3" 2>/dev/null' _ "$AWGDEC" "$T_STATE/parser/garbage.txt" "$T_STATE/parser/garbage.out"
_grc=$?
expect_true "decoder finishes within 20s (rc=$_grc)" [ "$_grc" -ne 124 ]
expect_true "non-zero exit or ok:false" sh -c '[ "$1" -ne 0 ] && [ "$1" -ne 124 ] || jq -e ".ok==false" "$2"' _ "$_grc" "$T_STATE/parser/garbage.out"
expect_true "no [Interface] produced" sh -c '! grep -q Interface "$1"' _ "$T_STATE/parser/garbage.out"
end 4.5
