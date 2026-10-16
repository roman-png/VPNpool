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
# A body that merely LOOKS like JSON (starts with "[" or "{") made json() throw: parser.uc
# died with no output at all, so in build.sh ONE such source file emptied the whole pool
# (NEW-1 / ROADMAP 2.1a, fixed: try around json(), fall back to the line parser).
P json-looking-junk-no-crash - "[not json at all" 'length==0'
P json-looking-then-links - "$(printf '[broken header\nvless://%s@203.0.113.24:443?security=tls#AfterJunk\n' "$U")" \
	'length==1' '.[0].tag=="AfterJunk"'
P duplicate-line-dedup - \
	"$(printf 'vless://%s@203.0.113.23:443?security=tls#Same\nvless://%s@203.0.113.23:443?security=tls#Same\n' "$U" "$U")" 'length==1'

# ---- stage 5 (ROADMAP §8): protocols, transports, addresses, ss ----
P ss-base64url-nopad - "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpUcT5-P2I@ss.example.com:8388#U" \
	'length==1' '.[0].method=="chacha20-ietf-poly1305"' '.[0].password=="Tq>~?b"'
P ss-2022-urlencoded-userinfo - "ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@ss.example.com:8388#S22" \
	'.[0].method=="2022-blake3-aes-128-gcm"' '.[0].password=="AAECAwQFBgcICQoLDA0ODw=="'
P ss-plugin - "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#P" \
	'.[0].server_port==8388' '.[0].plugin=="obfs-local"' '.[0].plugin_opts=="obfs=http;obfs-host=cdn.example.com"'
P vless-ipv6-brackets - "vless://$U@[2001:db8::1]:443?security=tls&sni=v6.example.com&type=tcp#V6" \
	'length==1' '.[0].server=="2001:db8::1"' '.[0].server_port==443'
P trojan-ipv6-brackets - "trojan://pw@[2001:db8::2]:443?sni=v6.example.com#T6" \
	'length==1' '.[0].server=="2001:db8::2"'
P vless-host-port-slash-query - "vless://$U@slash.example.com:443/?type=tcp&security=tls&sni=slash.example.com#S" \
	'length==1' '.[0].server=="slash.example.com"' '.[0].tls.server_name=="slash.example.com"'
P hysteria2 - "hysteria2://hypw@hy.example.com:8443?sni=hy.example.com&obfs=salamander&obfs-password=obpw&insecure=1#HY" \
	'length==1' '.[0].type=="hysteria2"' '.[0].password=="hypw"' '.[0].server_port==8443' \
	'.[0].obfs.type=="salamander" and .[0].obfs.password=="obpw"' '.[0].tls.server_name=="hy.example.com"' '.[0].tls.insecure==true'
P hy2-alias - "hy2://hypw@hy.example.com:443?sni=hy.example.com#HY2" '.[0].type=="hysteria2"'
P tuic - "tuic://$U:tupw@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com&udp_relay_mode=native#TU" \
	'.[0].type=="tuic"' ".[0].uuid==\"$U\"" '.[0].password=="tupw"' '.[0].congestion_control=="bbr"' \
	'.[0].udp_relay_mode=="native"' '.[0].tls.alpn==["h3"]'
P vless-xhttp-refused - "vless://$U@x.example.com:443?type=xhttp&security=tls&path=%2Fx#XH" 'length==0'
P vless-splithttp-refused - "vless://$U@x.example.com:443?type=splithttp&security=tls#SH" 'length==0'
P vless-httpupgrade - "vless://$U@u.example.com:443?type=httpupgrade&security=tls&path=%2Fup&host=u.example.com#HU" \
	'.[0].transport.type=="httpupgrade" and .[0].transport.path=="/up"'
P vless-h2 - "vless://$U@h.example.com:443?type=http&security=tls&path=%2Fh2&host=h.example.com#H2" \
	'.[0].transport.type=="http"'
P vless-quic - "vless://$U@q.example.com:443?type=quic&security=tls#Q" '.[0].transport.type=="quic"'
P vless-ws-early-data - "vless://$U@ws.example.com:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048#ED" \
	'.[0].transport.path=="/ws"' '.[0].transport.max_early_data==2048'
P vless-tcp-http-header - "vless://$U@t.example.com:80?type=tcp&headerType=http&host=t.example.com&path=%2F#TH" \
	'.[0].transport.type=="http"'
P vless-alpn - "vless://$U@a.example.com:443?security=tls&alpn=h2%2Chttp%2F1.1#AL" '.[0].tls.alpn==["h2","http/1.1"]'
P vless-allow-insecure - "vless://$U@a.example.com:443?security=tls&allowInsecure=1#AI" '.[0].tls.insecure==true'
P trojan-security-none - "trojan://pw@tn.example.com:80?security=none#TN" '(.[0].tls.enabled // false)==false'
P trojan-reality - "trojan://pw@tr.example.com:443?security=reality&pbk=$PBK&sid=01&sni=www.microsoft.com#TRR" \
	".[0].tls.reality.public_key==\"$PBK\""
# tag suffixes must be unique (ROADMAP 2.1): "A", "A", "A #2" -> two nodes tagged "A #2" before the fix
P tag-suffix-unique - \
	"$(printf 'vless://%s@203.0.113.31:443?security=tls#A\nvless://%s@203.0.113.32:443?security=tls#A\nvless://%s@203.0.113.33:443?security=tls#A%%20%%232\n' "$U" "$U" "$U")" \
	'length==3' '(map(.tag)|unique|length)==3'

# ---- more stage-5 coverage ----
P vless-ipv6-default-tag - "vless://$U@[2001:db8::7]:8443?security=tls" '.[0].tag=="[2001:db8::7]:8443"'
P vless-port-out-of-range-dropped - "$(printf 'vless://%s@203.0.113.40:70000?security=tls#P1\nvless://%s@203.0.113.40:0?security=tls#P2\nvless://%s@203.0.113.40?security=tls#P3\n' "$U" "$U" "$U")" 'length==0'
P vless-bad-host-dropped - "vless://$U@bad<host>:443?security=tls#BH" 'length==0'
P vless-empty-uuid-dropped - "vless://@203.0.113.41:443?security=tls#EU" 'length==0'
P vless-reality-long-sid-dropped - "vless://$U@203.0.113.42:443?security=reality&pbk=$PBK&sid=0123456789abcdef01#LS" 'length==0'
P vless-reality-nonhex-sid-dropped - "vless://$U@203.0.113.42:443?security=reality&pbk=$PBK&sid=zz#ZS" 'length==0'
P vless-encryption-dropped - "vless://$U@203.0.113.43:443?security=tls&encryption=mlkem768x25519plus.native.0rtt.abc#EN" 'length==0'
P vless-encryption-none-kept - "vless://$U@203.0.113.43:443?security=tls&encryption=none#EN0" 'length==1'
P vless-unknown-security-dropped - "vless://$U@203.0.113.44:443?security=foo#SF" 'length==0'
P vless-kcp-refused - "vless://$U@203.0.113.45:443?type=kcp#KCP" 'length==0'
P vless-quic-needs-tls - "vless://$U@q.example.com:443?type=quic#QN" 'length==0'
P vless-quic-no-utls - "vless://$U@q.example.com:443?type=quic&security=tls&fp=chrome#QU" \
	'.[0].transport.type=="quic"' '.[0].tls.utls==null'
P vless-quic-reality-refused - "vless://$U@q.example.com:443?type=quic&security=reality&pbk=$PBK#QR" 'length==0'
P vless-unknown-fp-chrome - "vless://$U@203.0.113.46:443?security=tls&fp=chrome_120#FP" '.[0].tls.utls.fingerprint=="chrome"'
P vless-fp-none-no-utls - "vless://$U@203.0.113.49:443?security=tls&fp=none#FN" '.[0].tls.enabled==true and .[0].tls.utls==null'
P vless-reality-fp-none-chrome - "vless://$U@203.0.113.49:443?security=reality&pbk=$PBK&fp=none#FNR" '.[0].tls.utls.fingerprint=="chrome"'
P vless-fp-lowercased - "vless://$U@203.0.113.47:443?security=tls&fp=Firefox#FF" '.[0].tls.utls.fingerprint=="firefox"'
P vless-ws-ed-params - "vless://$U@ws.example.com:443?type=ws&security=tls&path=%2Fws2&ed=1024&eh=X-ED#ED2" \
	'.[0].transport.path=="/ws2"' '.[0].transport.max_early_data==1024' '.[0].transport.early_data_header_name=="X-ED"'
P vless-ws-ed-keeps-other-query - "vless://$U@ws.example.com:443?type=ws&security=tls&path=%2Fws%3Fa%3D1%26ed%3D512#ED3" \
	'.[0].transport.path=="/ws?a=1"' '.[0].transport.max_early_data==512'
P vless-httpupgrade-host - "vless://$U@u.example.com:443?type=httpupgrade&security=tls&path=%2Fup&host=u.example.com#HU2" \
	'.[0].transport.host=="u.example.com"'
P vless-h2-host-list - "vless://$U@h.example.com:443?type=h2&security=tls&path=%2Fh2&host=a.example%2Cb.example#H2L" \
	'.[0].transport.type=="http"' '.[0].transport.host==["a.example","b.example"]' '.[0].transport.path=="/h2"'
P vless-tcp-http-header-fields - "vless://$U@t.example.com:80?type=tcp&headerType=http&host=t.example.com&path=%2Fa%2C%2Fb#TH2" \
	'.[0].transport.host==["t.example.com"]' '.[0].transport.path=="/a"' '.[0].transport.method=="GET"' '.[0].tls==null'
P vless-scheme-uppercase - "VLESS://$U@203.0.113.48:443?security=tls#UP" 'length==1'
P trojan-default-tls - "trojan://pw@tr.example.com:443#TD" '.[0].tls.enabled==true'
P trojan-ws - "trojan://pw@tr.example.com:443?type=ws&path=%2Ft&host=cdn.example.com#TW" \
	'.[0].transport.type=="ws" and .[0].transport.headers.Host=="cdn.example.com"'
P trojan-xhttp-refused - "trojan://pw@tr.example.com:443?type=xhttp#TX" 'length==0'
P trojan-password-urldecoded - "trojan://p%40ss%3Aw@tr.example.com:443#TP" '.[0].password=="p@ss:w"'
VMH2=$(printf '%s' "{\"v\":\"2\",\"ps\":\"VMH2\",\"add\":\"vm.example.com\",\"port\":443,\"id\":\"$U\",\"aid\":\"x\",\"scy\":\"weird\",\"net\":\"h2\",\"host\":\"vm.example.com\",\"path\":\"/vm\",\"tls\":\"tls\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
P vmess-base64url-h2-normalised - "vmess://$VMH2" \
	'.[0].transport.type=="http"' '.[0].security=="auto"' '.[0].alter_id==0' '.[0].server_port==443'
VMX=$(printf '%s' "{\"v\":\"2\",\"ps\":\"VMX\",\"add\":\"vm.example.com\",\"port\":\"443\",\"id\":\"$U\",\"net\":\"xhttp\"}" | base64 -w0)
P vmess-xhttp-refused - "vmess://$VMX" 'length==0'
VMHU=$(printf '%s' "{\"v\":\"2\",\"ps\":\"VMHU\",\"add\":\"vm.example.com\",\"port\":\"80\",\"id\":\"$U\",\"net\":\"httpupgrade\",\"host\":\"h.example\",\"path\":\"/u\"}" | base64 -w0)
P vmess-httpupgrade - "vmess://$VMHU" '.[0].transport.type=="httpupgrade" and .[0].transport.host=="h.example"'
VMP=$(printf '%s' "{\"v\":\"2\",\"ps\":\"VMP\",\"add\":\"vm.example.com\",\"port\":\"99999\",\"id\":\"$U\"}" | base64 -w0)
P vmess-bad-port-dropped - "vmess://$VMP" 'length==0'
P vmess-garbage-dropped - "vmess://%%%notbase64" 'length==0'
P hy2-port-hopping - "hy2://hypw@hy.example.com:443,5000-6000/?sni=hy.example.com&mport=7000-7100&hop_interval=30#HOP" \
	'.[0].server_port==443' '.[0].server_ports==["443:443","5000:6000","7000:7100"]' '.[0].hop_interval=="30s"'
P hy2-only-range - "hysteria2://pw@hy.example.com:20000-30000#RNG" '.[0].server_ports==["20000:30000"]' '.[0].server_port==null'
P hy2-default-port - "hy2://pw@hy.example.com/?sni=hy.example.com#DP" '.[0].server_port==443'
P hy2-bandwidth - "hysteria2://pw@hy.example.com:443?up=50%20mbps&down=1gbps#BW" '.[0].up_mbps==50 and .[0].down_mbps==1000'
P hy2-no-auth - "hysteria2://hy.example.com:443?sni=hy.example.com#NA" 'length==1' '.[0].password==null'
P hy2-bad-obfs-dropped - "hy2://pw@hy.example.com:443?obfs=foo#BO" 'length==0'
P hy2-bad-range-dropped - "hy2://pw@hy.example.com:6000-5000#BR" 'length==0'
P hy2-no-utls - "hy2://pw@hy.example.com:443?fp=chrome#NU" '.[0].tls.utls==null and .[0].tls.enabled==true'
P tuic-bad-uuid-dropped - "tuic://notauuid:pw@tu.example.com:443#TB" 'length==0'
P tuic-unknown-cc-omitted - "tuic://$U:pw@tu.example.com:443?congestion_control=foo&udp_relay_mode=bar&allow_insecure=1#TC" \
	'length==1' '.[0].congestion_control==null' '.[0].udp_relay_mode==null' '.[0].tls.insecure==true'
P tuic-newreno-alias - "tuic://$U:pw@tu.example.com:443?congestion-control=newreno#TN" '.[0].congestion_control=="new_reno"'
P ss-unknown-method-dropped - "ss://$(printf 'rc4:pp' | base64 -w0)@ss.example.com:8388#RC" 'length==0'
P ss-2022-bad-key-dropped - "ss://2022-blake3-aes-128-gcm:short@ss.example.com:8388#BK" 'length==0'
P ss-2022-multiuser-key - "ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D%3AAAECAwQFBgcICQoLDA0ODw%3D%3D@ss.example.com:8388#MU" 'length==1'
P ss-unsupported-plugin-dropped - "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=kcptun#KC" 'length==0'
P ss-v2ray-plugin - "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=v2ray-plugin%3Btls%3Bhost%3Dcdn.example.com#V2" \
	'.[0].plugin=="v2ray-plugin"' '.[0].plugin_opts=="tls;host=cdn.example.com"'
P ss-simple-obfs-alias - "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388?plugin=simple-obfs%3Bobfs%3Dtls#SO" \
	'.[0].plugin=="obfs-local"' '.[0].plugin_opts=="obfs=tls"'
P ss-legacy-ipv6 - "ss://$(printf 'aes-128-gcm:pw2@[2001:db8::5]:8389' | base64 -w0 | tr -d =)#L6" \
	'.[0].server=="2001:db8::5" and .[0].server_port==8389'
P base64url-subscription-blob - \
	"$(printf 'vless://%s@203.0.113.25:443?security=tls#BU1\nss://%s@203.0.113.26:8388#BU2\n' "$U" "$(printf 'aes-256-gcm:p??' | base64 -w0)" | base64 -w0 | tr '+/' '-_' | tr -d '=')" \
	'map(.tag)==["BU1","BU2"]'
P utf8-bom-and-comments - "$(printf '\357\273\277#profile-title: x\n// note\nvless://%s@203.0.113.27:443?security=tls#BOM\n' "$U")" \
	'length==1 and .[0].tag=="BOM"'
P unknown-schemes-dropped - "$(printf 'socks://abc\nssr://abc\nwireguard://abc\nhysteria://abc\n')" 'length==0'
# dedup key = name + config: the same config under another name is a separate node (a user's
# imported copy of a subscription node must not vanish; merging is ROADMAP 2.2)
P dedup-keeps-differently-named-node - \
	"$(printf 'vless://%s@203.0.113.28:443?security=tls#First\nvless://%s@203.0.113.28:443?security=tls#Second\nvless://%s@203.0.113.28:443?security=tls&type=tcp#First\n' "$U" "$U" "$U")" \
	'length==2' 'map(.tag)==["First","Second"]'
begin "parser/dedup-subscription-vs-imported-file"
mkdir -p "$T_STATE/parser"
printf 'vless://%s@203.0.113.29:443?security=tls#ProviderName\n' "$U" > "$T_STATE/parser/sub.raw"
printf 'vless://%s@203.0.113.29:443?security=tls#MyImported\n' "$U" > "$T_STATE/parser/imported.links"
_o=$(ucode "$PARSER" "$T_STATE/parser/sub.raw" "$T_STATE/parser/imported.links" 2>/dev/null)
expect_jq "both nodes, each under its own name" "$_o" 'map(.tag)==["ProviderName","MyImported"]'
end
P json-key-order-dedup - \
	"[{\"type\":\"vless\",\"tag\":\"K\",\"server\":\"203.0.113.30\",\"server_port\":443,\"uuid\":\"$U\"},{\"uuid\":\"$U\",\"server_port\":443,\"server\":\"203.0.113.30\",\"tag\":\"K\",\"type\":\"vless\"}]" \
	'length==1'
# reserved tags (ROADMAP 2.1): a node may never take a tag the generator defines
P reserved-tags-renamed - \
	"$(i=60; for t in auto proxy direct block dns-out vpnpool-test; do i=$((i+1)); printf 'vless://%s@203.0.113.%s:443?security=tls#%s\n' "$U" "$i" "$t"; done)" \
	'length==6' '[.[].tag] | map(select(.=="auto" or .=="proxy" or .=="direct" or .=="block" or .=="dns-out" or .=="vpnpool-test")) | length==0' \
	'(map(.tag)|unique|length)==6' '.[0].tag=="auto #2"' '.[5].tag=="vpnpool-test #2"'
P tag-suffix-unique-loop - \
	"$(printf 'vless://%s@203.0.113.71:443?security=tls#A\nvless://%s@203.0.113.72:443?security=tls#A%%20%%232\nvless://%s@203.0.113.73:443?security=tls#A\nvless://%s@203.0.113.74:443?security=tls#A%%20%%232\nvless://%s@203.0.113.75:443?security=tls#A\n' "$U" "$U" "$U" "$U" "$U")" \
	'length==5' '(map(.tag)|unique|length)==5'
P json-outbound-reserved-tag - \
	"{\"outbounds\":[{\"type\":\"vless\",\"tag\":\"proxy\",\"server\":\"203.0.113.76\",\"server_port\":443,\"uuid\":\"$U\"}]}" \
	'length==1 and .[0].tag=="proxy #2"'
# a sing-box JSON source gets the same guards as links: a long reality short_id there PANICS
# sing-box (no outbounds[N] in the message -> build.sh cannot prune it)
RL="\"tls\":{\"enabled\":true,\"server_name\":\"a.example\",\"reality\":{\"enabled\":true,\"public_key\":\"$PBK\""
JSON_GUARD="{\"outbounds\":[
{\"type\":\"vless\",\"tag\":\"JG-ok-reality\",\"server\":\"203.0.113.100\",\"server_port\":443,\"uuid\":\"$U\",$RL,\"short_id\":\"ab12\"}}},
{\"type\":\"vless\",\"tag\":\"JG-long-sid\",\"server\":\"203.0.113.101\",\"server_port\":443,\"uuid\":\"$U\",$RL,\"short_id\":\"0123456789abcdef0123\"}}},
{\"type\":\"vless\",\"tag\":\"JG-port\",\"server\":\"203.0.113.102\",\"server_port\":70000,\"uuid\":\"$U\"},
{\"type\":\"vless\",\"tag\":\"JG-xhttp\",\"server\":\"203.0.113.103\",\"server_port\":443,\"uuid\":\"$U\",\"transport\":{\"type\":\"xhttp\"}},
{\"type\":\"shadowsocks\",\"tag\":\"JG-rc4\",\"server\":\"203.0.113.104\",\"server_port\":8388,\"method\":\"rc4\",\"password\":\"p\"},
{\"type\":\"vless\",\"tag\":\"JG-ok-fp\",\"server\":\"203.0.113.105\",\"server_port\":443,\"uuid\":\"$U\",\"tls\":{\"enabled\":true,\"utls\":{\"enabled\":true,\"fingerprint\":\"Chrome_120\"}}},
{\"type\":\"hysteria2\",\"tag\":\"JG-hy2-notls\",\"server\":\"203.0.113.106\",\"server_port\":443,\"password\":\"p\"},
{\"type\":\"vless\",\"tag\":\"JG-flow\",\"server\":\"203.0.113.107\",\"server_port\":443,\"uuid\":\"$U\",\"flow\":\"xtls-rprx-direct\"},
{\"type\":\"tuic\",\"tag\":\"JG-tuic\",\"server\":\"203.0.113.108\",\"server_port\":443,\"uuid\":\"nope\",\"password\":\"p\",\"tls\":{\"enabled\":true}},
{\"type\":\"selector\",\"tag\":\"sel\",\"outbounds\":[\"JG-ok-fp\"]}
]}"
begin "parser/json-source-guards"
_r=$(printf '%s\n' "$JSON_GUARD" | ucode "$PARSER" --report 2>/dev/null)
expect_jq "one record per outbound" "$_r" 'length==10'
expect_jq "reasons per item" "$_r" '[.[] | .reason // "ok"] == ["ok","bad_short_id","bad_port","unsupported_transport","unsupported_method","ok","tls_required","unsupported_flow","bad_uuid","not_a_node"]'
_o=$(printf '%s\n' "$JSON_GUARD" | ucode "$PARSER" 2>/dev/null)
expect_jq "two nodes survive" "$_o" 'map(.tag)==["JG-ok-reality","JG-ok-fp"]'
expect_jq "reality without uTLS gets chrome, unknown fp -> chrome" "$_o" '.[0].tls.utls.fingerprint=="chrome" and .[1].tls.utls.fingerprint=="chrome"'
printf '%s' "$_o" | jq '{log:{level:"error"}, outbounds:(. + [{type:"direct",tag:"direct"}])}' > "$T_STATE/parser/jg.json"
expect_true "sing-box check accepts the surviving nodes" sing-box check -c "$T_STATE/parser/jg.json"
end

# ---- node id (ROADMAP 2.2 groundwork): opt-in field, stable, name/order independent ----
ID_LINKS="vless://$U@203.0.113.80:443?type=tcp&security=reality&pbk=$PBK&sid=ab12&sni=www.microsoft.com&fp=chrome#I1
trojan://pw@tr.example.com:443?sni=tr.example.com#I2
ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388#I3
hy2://hypw@hy.example.com:443?sni=hy.example.com#I4
tuic://$U:tupw@tu.example.com:443?sni=tu.example.com#I5
vmess://$VM"
ID_SWAPPED=$(printf '%s\n' "$ID_LINKS" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' | sed 's/#I\([0-9]\)$/#Renamed\1/; s/#VM$/#VMrenamed/')
idmap() { printf '%s\n' "$1" | ucode "$PARSER" --with-id 2>/dev/null | jq -c 'map({k:(.type+"|"+.server), id}) | sort_by(.k)'; }
begin "parser/id-stable-across-order-and-name"
_a=$(idmap "$ID_LINKS"); _b=$(idmap "$ID_SWAPPED")
expect_jq "6 ids, 12 hex chars each" "$_a" 'length==6 and all(.[]; (.id|type)=="string" and (.id|length)==12 and (.id|explode|all(. >= 48 and . <= 57 or . >= 97 and . <= 102)))'
expect_jq "ids unique" "$_a" '(map(.id)|unique|length)==6'
expect_jq "names of the swapped corpus really differ" "$(printf '%s\n' "$ID_SWAPPED" | ucode "$PARSER" 2>/dev/null)" 'map(.tag)|index("I1")==null'
expect_eq "same id per node after reordering + renaming" "$_b" "$_a"
end
begin "parser/id-changes-with-port-and-credential"
_p1=$(printf '%s\n' "vless://$U@203.0.113.81:443?security=tls#X" | ucode "$PARSER" --with-id 2>/dev/null | jq -r '.[0].id')
_p2=$(printf '%s\n' "vless://$U@203.0.113.81:444?security=tls#X" | ucode "$PARSER" --with-id 2>/dev/null | jq -r '.[0].id')
_p3=$(printf '%s\n' "vless://11111111-2222-3333-4444-555555555555@203.0.113.81:443?security=tls#X" | ucode "$PARSER" --with-id 2>/dev/null | jq -r '.[0].id')
_p4=$(printf '%s\n' "VLESS://$(echo $U | tr a-f A-F)@203.0.113.81:443?security=tls#Y" | ucode "$PARSER" --with-id 2>/dev/null | jq -r '.[0].id')
expect_true "id present ($_p1)" [ ${#_p1} -eq 12 ]
expect_true "port change -> other id ($_p1 vs $_p2)" [ "$_p1" != "$_p2" ]
expect_true "uuid change -> other id ($_p1 vs $_p3)" [ "$_p1" != "$_p3" ]
expect_eq "uuid case / scheme case / name do not change the id" "$_p4" "$_p1"
end
# id = hash of the canonical outbound without tag: every config field counts, key order does not
idof() { printf '%s\n' "$1" | ucode "$PARSER" --with-id 2>/dev/null | jq -r '.[0].id // "none"'; }
begin "parser/id-covers-every-config-field"
_f1=$(idof "vless://$U@203.0.113.82:443?security=tls&fp=chrome#F")
_f2=$(idof "vless://$U@203.0.113.82:443?security=tls&fp=firefox#F")
_o1=$(idof "hy2://pw@hy.example.com:443?obfs=salamander&obfs-password=one#O")
_o2=$(idof "hy2://pw@hy.example.com:443?obfs=salamander&obfs-password=two#O")
_s1=$(idof "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp#S")
_s2=$(idof "ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dtls#S")
expect_true "ids computed ($_f1 $_o1 $_s1)" sh -c '[ ${#1} -eq 12 ] && [ ${#2} -eq 12 ] && [ ${#3} -eq 12 ]' _ "$_f1" "$_o1" "$_s1"
expect_true "fp chrome vs firefox -> other id" [ "$_f1" != "$_f2" ]
expect_true "obfs password one vs two -> other id" [ "$_o1" != "$_o2" ]
expect_true "ss plugin_opts http vs tls -> other id" [ "$_s1" != "$_s2" ]
end
begin "parser/id-json-key-order-and-link-agree"
_j1=$(idof "[{\"type\":\"vless\",\"tag\":\"J1\",\"server\":\"203.0.113.83\",\"server_port\":443,\"uuid\":\"$U\",\"tls\":{\"enabled\":true,\"server_name\":\"a.example\"}}]")
_j2=$(idof "[{\"tls\":{\"server_name\":\"a.example\",\"enabled\":true},\"uuid\":\"$U\",\"server_port\":443,\"server\":\"203.0.113.83\",\"tag\":\"J2\",\"type\":\"vless\"}]")
_j3=$(idof "vless://$U@203.0.113.83:443?security=tls&sni=a.example#J3")
expect_true "id computed ($_j1)" [ ${#_j1} -eq 12 ]
expect_eq "permuted JSON keys (and another name) -> same id" "$_j2" "$_j1"
expect_eq "the equivalent link -> same id" "$_j3" "$_j1"
end
# in nodes.json the id must be unique: same config under two names -> today two nodes with one
# id; merging them (user's source wins) is ROADMAP 2.2
begin "parser/id-unique-in-output"
_u=$(printf 'vless://%s@203.0.113.84:443?security=tls#Sub\nvless://%s@203.0.113.84:443?security=tls#Mine\n' "$U" "$U" | ucode "$PARSER" --with-id 2>/dev/null)
expect_jq "nodes parsed, all with an id" "$_u" 'length>=1 and all(.[]; (.id|length)==12)'
expect_jq "no two nodes share an id" "$_u" '(map(.id)|unique|length)==length'
end 2.2
begin "parser/id-not-in-default-output"
_o=$(printf '%s\n' "$ID_LINKS" | ucode "$PARSER" 2>/dev/null)
expect_jq "6 nodes parsed" "$_o" 'length==6'
expect_jq "no id field without --with-id (sing-box rejects unknown fields)" "$_o" 'all(.[]; has("id")|not)'
end
# AWG id (ROADMAP 4.4) = first 12 hex of sha256 over the private key (canonical base64): checked
# against coreutils sha256sum — the pure-ucode SHA-256 must agree with a real one
begin "parser/awg-id-is-sha256-of-private-key"
_aw=$(ucode "$PARSER" --with-id "$FX/awg/awg2.conf" 2>/dev/null)
_want=$(printf '%s' 'YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=' | sha256sum | cut -c1-12)
expect_true "control: sha256sum gave 12 hex ($_want)" sh -c 'printf %s "$1" | grep -qE "^[0-9a-f]{12}$"' _ "$_want"
expect_jq "id = sha256(PrivateKey)[:12]" "$_aw" "length==1 and .[0].id==\"$_want\""
# a second, independent key (the stock WireGuard fixture)
_wg=$(ucode "$PARSER" --with-id "$FX/awg/wg-plain.conf" 2>/dev/null)
_want2=$(printf '%s' 'WGcliFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEA0=' | sha256sum | cut -c1-12)
expect_jq "wireguard id = sha256(PrivateKey)[:12]" "$_wg" "length==1 and .[0].id==\"$_want2\""
expect_jq "no id without --with-id" "$(ucode "$PARSER" "$FX/awg/awg2.conf" 2>/dev/null)" '.[0]|has("id")|not'
end

# ---- --report: one record per input line, machine reason codes ----
RPT_IN="#comment
vless://$U@203.0.113.90:443?security=tls#R-ok
vless://$U@203.0.113.90:443?security=tls#R-ok
vless://$U@x.example.com:443?type=xhttp&security=tls#R-xhttp
vless://$U@203.0.113.91:70000?security=tls#R-port
tuic://bad:pw@tu.example.com:443#R-uuid
socks://abc
hello there

vless://$U@203.0.113.92:443?security=reality&pbk=short#R-pbk
vless://$U@203.0.113.93:443?security=reality&pbk=$PBK&sid=xyz1#R-sid
vless://$U@203.0.113.94:443?security=tls&flow=xtls-rprx-direct#R-flow
ss://$(printf 'rc4:pp' | base64 -w0)@ss.example.com:8388#R-method
ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=kcptun#R-plugin
hy2://pw@hy.example.com:443?obfs=foo#R-obfs
vless://$U@q.example.com:443?type=quic#R-quic
vless://$U@203.0.113.95:443?security=tls#direct
vless://$U@bad^host:443#R-server
ss://%%%#R-parse
vless://$U@203.0.113.96:443?security=tls&encryption=mlkem#R-enc"
begin "parser/report-reasons"
_r=$(printf '%s\n' "$RPT_IN" | ucode "$PARSER" --report 2>/dev/null)
expect_jq "array of 18 records (blank and # lines are not reported)" "$_r" 'type=="array" and length==18'
expect_jq "line 2 ok with tag/type/id" "$_r" '.[0] | .line==2 and .status=="ok" and .tag=="R-ok" and .type=="vless" and (.id|length)==12'
expect_jq "duplicate points at its twin" "$_r" '.[1] | .line==3 and .status=="skip" and .reason=="duplicate" and .dup_of=="R-ok"'
expect_jq "reason codes in order" "$_r" '[.[2:][] | .reason // "ok"] == ["unsupported_transport","bad_port","bad_uuid","unknown_scheme","not_a_link","bad_reality_key","bad_short_id","unsupported_flow","unsupported_method","unsupported_plugin","unsupported_obfs","tls_required","ok","bad_server","parse_error","unsupported_encryption"]'
expect_jq "line numbers follow the input (comment line 1, blank line 9 not reported)" "$_r" '[.[].line] == [2,3,4,5,6,7,8,10,11,12,13,14,15,16,17,18,19,20]'
expect_jq "reserved tag reported as renamed" "$_r" '.[14] | .line==17 and .status=="ok" and .tag=="direct #2" and .tag_changed==true'
expect_jq "every record has src 0" "$_r" 'all(.[]; .src==0)'
expect_jq "reasons are machine codes (no spaces)" "$_r" 'all(.[]; (.reason // "x") | contains(" ") | not)'
end
begin "parser/report-matches-normal-mode"
_n=$(printf '%s\n' "$RPT_IN" | ucode "$PARSER" 2>/dev/null)
expect_jq "normal mode: exactly the ok records become nodes" "$_n" "length == $(printf '%s' "$_r" | jq '[.[]|select(.status=="ok")]|length')"
expect_jq "normal mode tags == report ok tags" "$_n" "map(.tag) == $(printf '%s' "$_r" | jq -c '[.[]|select(.status=="ok")|.tag]')"
end
begin "parser/report-multi-file-and-json"
mkdir -p "$T_STATE/parser"
printf '%s\n' "vless://$U@203.0.113.97:443?security=tls#F0" > "$T_STATE/parser/r0.txt"
printf '{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"F1","server":"203.0.113.98","server_port":443,"uuid":"%s"}]}' "$U" > "$T_STATE/parser/r1.json"
printf '[{"broken": \n' > "$T_STATE/parser/r2.raw"
_r=$(ucode "$PARSER" --report "$T_STATE/parser/r0.txt" "$T_STATE/parser/r1.json" "$T_STATE/parser/r2.raw" 2>/dev/null)
expect_jq "file 0 line 1 ok" "$_r" 'any(.[]; .src==0 and .line==1 and .status=="ok" and .tag=="F0")'
expect_jq "json item 1 is not a node, item 2 ok" "$_r" 'any(.[]; .src==1 and .item==1 and .reason=="not_a_node") and any(.[]; .src==1 and .item==2 and .status=="ok" and .tag=="F1")'
expect_jq "broken json source reported, not crashed" "$_r" 'any(.[]; .src==2 and .status=="skip")'
end

# ---- every node the corpus produces must be accepted by sing-box (the engine on PATH:
# stock 1.12 in the stand image; run with our 1.14 AWG engine via SINGBOX_BIN — see HANDOFF) ----
CHECK_LINKS="$ID_LINKS
vless://$U@[2001:db8::1]:443?security=tls&sni=v6.example.com&type=tcp#C-v6
vless://$U@u.example.com:443?type=httpupgrade&security=tls&path=%2Fup&host=u.example.com#C-hu
vless://$U@h.example.com:443?type=http&security=tls&path=%2Fh2&host=h.example.com#C-h2
vless://$U@q.example.com:443?type=quic&security=tls&fp=chrome#C-quic
vless://$U@ws.example.com:443?type=ws&security=tls&path=%2Fws%3Fed%3D2048#C-ed
vless://$U@g.example.com:443?type=grpc&security=reality&pbk=$PBK&sid=01&fp=qq#C-grpc-reality
vless://$U@t.example.com:80?type=tcp&headerType=http&host=t.example.com&path=%2F#C-tcphttp
vless://$U@a.example.com:443?security=tls&alpn=h2%2Chttp%2F1.1&allowInsecure=1&fp=chrome_120#C-alpn
trojan://pw@tn.example.com:80?security=none#C-tr-none
trojan://pw@tr.example.com:443?security=reality&pbk=$PBK&sid=01&sni=www.microsoft.com#C-tr-reality
trojan://pw@tr.example.com:443?type=ws&path=%2Ft#C-tr-ws
vmess://$VMH2
vmess://$VMHU
hysteria2://hypw@hy.example.com:8443?sni=hy.example.com&obfs=salamander&obfs-password=obpw&insecure=1&up=50&down=100#C-hy
hy2://hypw@hy.example.com:443,5000-6000/?mport=7000-7100&hop_interval=30#C-hop
hysteria2://pw@hy.example.com:20000-30000#C-range
tuic://$U:tupw@tu.example.com:443?congestion_control=bbr&alpn=h3&sni=tu.example.com&udp_relay_mode=native&allow_insecure=1#C-tuic
ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpUcT5-P2I@ss.example.com:8388#C-ss-url
ss://2022-blake3-aes-128-gcm:AAECAwQFBgcICQoLDA0ODw%3D%3D@ss.example.com:8388#C-ss22
ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#C-obfs
ss://$(printf 'aes-256-gcm:pp' | base64 -w0)@ss.example.com:8389/?plugin=v2ray-plugin%3Btls%3Bhost%3Dcdn.example.com#C-v2p
vless://$U@203.0.113.99:443?security=tls#auto"
begin "parser/corpus-accepted-by-sing-box-check"
printf '%s\n' "$CHECK_LINKS" | ucode "$PARSER" 2>/dev/null > "$T_STATE/parser/check-nodes.json"
_cn=$(jq 'length' "$T_STATE/parser/check-nodes.json" 2>/dev/null)
expect_eq "all $(printf '%s\n' "$CHECK_LINKS" | grep -c '://') corpus links parsed" "$_cn" "$(printf '%s\n' "$CHECK_LINKS" | grep -c '://')"
jq '{log:{level:"error"}, outbounds:(. + [{type:"direct",tag:"direct"}])}' "$T_STATE/parser/check-nodes.json" > "$T_STATE/parser/check.json"
expect_true "sing-box $(sing-box version 2>/dev/null | head -1 | awk '{print $NF}') check accepts all $_cn nodes in one config" \
	sing-box check -c "$T_STATE/parser/check.json"
# positive control: the same check MUST reject a config with an unknown outbound field —
# that is exactly why `id` is opt-in (--with-id) and never in nodes.json
printf '%s\n' "$CHECK_LINKS" | ucode "$PARSER" --with-id 2>/dev/null \
	| jq '{log:{level:"error"}, outbounds:(. + [{type:"direct",tag:"direct"}])}' > "$T_STATE/parser/check-id.json"
expect_true "control: check rejects the --with-id output" sh -c '! sing-box check -c "$1"' _ "$T_STATE/parser/check-id.json"
end

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
# AWG 3.1 (ROADMAP 4.3): every key of the .conf -> the engine's field (patches/sing-box/0001)
PF awg3-conf-fields - "$FX/awg/awg3.conf" \
	'length==1' '.[0].type=="awg"' '.[0].header_protection_key=="c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI="' \
	'.[0].random_trailers==true' '.[0].disable_cookies==true' \
	'.[0].content_padding_addition=="10-100"' '.[0].rekey_after_time=="100-120"' '.[0].rekey_timeout=="3-7"' \
	'.[0].reject_after_time=="150-180"' '.[0].keepalive_timeout=="5-15"' '.[0].max_handshake_attempts=="15-20"' \
	'.[0].jc==3 and .[0].jmin==10 and .[0].jmax==30 and .[0].s1==15 and .[0].s2==18 and .[0].s3==20 and .[0].s4==12' \
	'.[0].h4=="425489310-425489900"' '(.[0].i1|startswith("<r 2><b 0x8580"))' \
	'.[0].peers[0].persistent_keepalive_interval=="25-35"' \
	'.[0].peers[0].preshared_key=="PSKFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE="' \
	'(.[0]|has("dns") or has("i2"))|not'
# no AWG parameter -> the STOCK wireguard endpoint (pre_shared_key, numeric keepalive)
PF wireguard-plain-conf - "$FX/awg/wg-plain.conf" \
	'length==1' '.[0].type=="wireguard"' '.[0].peers[0].pre_shared_key=="WGpskFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEA0="' \
	'.[0].peers[0].persistent_keepalive_interval==25' '(.[0].peers[0]|has("preshared_key"))|not' \
	'(.[0]|has("jc") or has("mtu"))|not' '.[0].address==["10.66.66.2/32"]'
PF awg-multi-peer-refused - "$FX/awg/awg-multipeer.conf" 'length==0'
mkdir -p "$T_STATE/parser"
begin "parser/awg-multi-peer-reason"
expect_jq "a clear reason" "$(ucode "$PARSER" --report "$FX/awg/awg-multipeer.conf" 2>/dev/null)" \
	'length==1 and .[0].status=="skip" and .[0].reason=="awg_multi_peer"'
end

# Own checks of AWG values (ROADMAP 4.3): each one passes `sing-box check` and stops the engine
# only when it STARTS (measured on vpnpool-engine 1.14.3-awg.1) — so the parser must refuse it.
# AV <id> <sed on awg3.conf> <reason> [field]
AWG3_N=0
AV() {
	_id=$1; _sed=$2; _why=$3; _fld=${4:-}
	begin "parser/awg-check-$_id"
	sed "$_sed" "$FX/awg/awg3.conf" > "$T_STATE/parser/av.conf"
	expect_true "fixture changed by [$_sed]" sh -c '! cmp -s "$1" "$2"' _ "$FX/awg/awg3.conf" "$T_STATE/parser/av.conf"
	_r=$(ucode "$PARSER" --report "$T_STATE/parser/av.conf" 2>/dev/null)
	if [ -n "$_fld" ]; then
		expect_jq "refused: $_why/$_fld" "$_r" ".[0].status==\"skip\" and .[0].reason==\"$_why\" and .[0].field==\"$_fld\""
	else
		expect_jq "refused: $_why" "$_r" ".[0].status==\"skip\" and .[0].reason==\"$_why\""
	fi
	expect_jq "no node" "$(ucode "$PARSER" "$T_STATE/parser/av.conf" 2>/dev/null)" 'length==0'
	end
	AWG3_N=$((AWG3_N + 1))
}
begin "parser/awg-check-positive-control"
expect_jq "awg3.conf itself is accepted" "$(ucode "$PARSER" --report "$FX/awg/awg3.conf" 2>/dev/null)" '.[0].status=="ok" and .[0].type=="awg"'
end
AV h-overlap        's/^H2 = .*/H2 = 1047436600-1047436700/'    awg_bad_value h2
AV h-not-a-number   's/^H1 = .*/H1 = abc/'                       awg_bad_value h1
AV i-unknown-tag    's/^I1 = .*/I1 = <zz 2>/'                    awg_bad_value i1
AV i-unclosed       's/^I1 = .*/I1 = <b 0x12/'                   awg_bad_value i1
AV i-odd-hex        's/^I1 = .*/I1 = <b 0x123>/'                 awg_bad_value i1
AV cpa-reversed     's/^ContentPaddingAddition = .*/ContentPaddingAddition = 100-10/' awg_bad_value contentpaddingaddition
AV s1-too-big       's/^S1 = .*/S1 = 70000/'                     awg_bad_value s1
AV hpk-s4-below-12  's/^S4 = .*/S4 = 11/'                        awg_bad_value s4
AV hpk-not-32-bytes 's/^HeaderProtectionKey = .*/HeaderProtectionKey = c2VjcmV0/' bad_key headerprotectionkey
AV jmin-over-jmax   's/^Jmin = .*/Jmin = 40/'                    awg_bad_value jmin
AV bool-unknown     's/^RandomTrailers = .*/RandomTrailers = maybe/' awg_bad_value randomtrailers
AV keepalive-rev    's/^PersistentKeepalive = .*/PersistentKeepalive = 35-25/' awg_bad_value persistentkeepalive
AV private-key-bad  's/^PrivateKey = .*/PrivateKey = c2hvcnQ=/'  bad_key privatekey
AV unknown-param    's/^Jc = 3$/Jc = 3\nItime = 5/'              awg_unsupported_param itime
AV endpoint-port    's/^Endpoint = .*/Endpoint = 198.51.100.61:70000/' bad_port
AV no-peer          '/^\[Peer\]/,$d'                             awg_no_peer
begin "parser/awg-checks-counted"
expect_true "AWG value checks run: $AWG3_N (want 16)" [ "$AWG3_N" -eq 16 ]
end
# accepted after normalising: "100 - 120" (the engine does not trim), a key without padding /
# url-safe (one node = one id), a placeholder value, an empty I2
begin "parser/awg-normalised-values"
sed 's/^RekeyAfterTime = .*/RekeyAfterTime = 100 - 120/; s/^PrivateKey = .*/PrivateKey = YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk/; s/^MTU = .*//; s/^Jc = 3$/Jc = 3\nI2 =\nTable = $TABLE/' \
	"$FX/awg/awg3.conf" > "$T_STATE/parser/norm.conf"
_n=$(ucode "$PARSER" --with-id "$T_STATE/parser/norm.conf" 2>/dev/null)
_o=$(ucode "$PARSER" --with-id "$FX/awg/awg3.conf" 2>/dev/null)
expect_jq "accepted" "$_n" 'length==1 and .[0].type=="awg"'
expect_jq "range without spaces" "$_n" '.[0].rekey_after_time=="100-120"'
expect_jq "key padded back" "$_n" '.[0].private_key=="YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk="'
expect_eq "same id as the padded key" "$(printf '%s' "$_n" | jq -r '.[0].id')" "$(printf '%s' "$_o" | jq -r '.[0].id')"
end
# a keepalive RANGE is AWG 3.x -> awg, never the stock wireguard (that takes a number only)
begin "parser/awg-keepalive-range-is-awg"
sed 's/^PersistentKeepalive = .*/PersistentKeepalive = 25-35/' "$FX/awg/wg-plain.conf" > "$T_STATE/parser/ka.conf"
expect_jq "type awg, range kept, preshared_key" "$(ucode "$PARSER" "$T_STATE/parser/ka.conf" 2>/dev/null)" \
	'.[0].type=="awg" and .[0].peers[0].persistent_keepalive_interval=="25-35" and (.[0].peers[0].preshared_key|length)==44'
end
# identity (ROADMAP 4.4): the name comes from "# Name ="; two clients of one server = two nodes;
# the same .conf twice = one node
begin "parser/awg-name-comment-and-identity"
{ printf '# Name = Мой сервер (10.8.1.9)\n'; cat "$FX/awg/awg3.conf"; } > "$T_STATE/parser/named.conf"
sed 's/^PrivateKey = .*/PrivateKey = ZZk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=/' "$FX/awg/awg3.conf" > "$T_STATE/parser/client2.conf"
_m=$(ucode "$PARSER" --with-id "$T_STATE/parser/named.conf" "$T_STATE/parser/client2.conf" "$FX/awg/awg3.conf" 2>/dev/null)
expect_jq "two nodes (named + client2; the third file repeats the first key)" "$_m" 'length==2'
expect_jq "name from the comment" "$_m" '.[0].tag=="Мой сервер (10.8.1.9)"'
expect_jq "two ids" "$_m" '(map(.id)|unique|length)==2'
_rp=$(ucode "$PARSER" --report "$T_STATE/parser/named.conf" "$T_STATE/parser/client2.conf" "$FX/awg/awg3.conf" 2>/dev/null)
expect_jq "the repeat is a duplicate of the named node" "$_rp" '.[2].status=="skip" and .[2].reason=="duplicate" and .[2].dup_of=="Мой сервер (10.8.1.9)"'
expect_jq "hint: random trailers need 3.1 on the server" "$_rp" '.[0].hints==["awg_random_trailers"]'
end

# ---- ucode regex: \s inside [...] is the LETTER s (POSIX ERE), not whitespace ----
# a base64 subscription wrapped over lines (pasted by hand) must still be recognised as base64
begin "parser/base64-blob-with-line-breaks"
_b64=$(printf 'vless://%s@203.0.113.71:443?security=tls#W1\nvless://%s@203.0.113.72:443?security=tls#W2\n' "$U" "$U" | base64 | tr -d '\n' | awk '{ for (i = 1; i <= length($0); i += 20) print substr($0, i, 20) }')
expect_true "control: the blob really has line breaks" sh -c '[ "$(printf "%s\n" "$1" | wc -l)" -gt 3 ]' _ "$_b64"
expect_jq "both nodes decoded" "$(parse_text "$_b64")" 'length==2 and .[0].tag=="W1" and .[1].tag=="W2"'
end
# a vless id that is not a UUID but has an "s" in it (was refused as bad_uuid)
P vless-id-with-letter-s - "vless://mysecret-pass@203.0.113.73:443?security=tls#S1" \
	'length==1' '.[0].uuid=="mysecret-pass"'
P vless-id-with-space-refused - "vless://my%20secret@203.0.113.74:443?security=tls#S2" 'length==0'
sed 's/^\[Interface\]/[INTERFACE]/; s/^\[Peer\]/[PEER]/' "$FX/awg/awg2.conf" > "$T_STATE/parser/upper.conf"
# [INTERFACE] / [PEER] in capitals: the .conf must still be recognised (ROADMAP 2.1a)
PF awg-section-case-insensitive - "$T_STATE/parser/upper.conf" 'length==1 and .[0].type=="awg"'

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
V B_wrapped76            -   198.51.100.61 443
V B2_wrapped_crlf        -   198.51.100.61 443
V B3_space_inside        -   198.51.100.61 443
V C_label_prefix         -   198.51.100.61 443
V D_old_plainjson        -   198.51.100.61 443
V E_xray_first           -   198.51.100.61 443
V F_stored_level0        -   198.51.100.61 443
V G_lastconfig_object    -   198.51.100.61 443
V H_crlf_conf            -   198.51.100.61 443
V I_padded_std_b64       -   198.51.100.61 443
V J_two_links            -   198.51.100.61 443
V K_hostname_endpoint    -   vpn.example.com 51820
V L_big_I2               -   198.51.100.61 443
V M_no_psk_noKA          -   198.51.100.61 443
V N_awg_key_variant_amnezia_awg2 -   198.51.100.61 443

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
end
