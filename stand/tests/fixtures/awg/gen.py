import json, zlib, base64, struct, os, sys
out = sys.argv[1]
conf = """[Interface]
Address = 10.8.1.9/32, fd00::9/128
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=
Jc = 4
Jmin = 10
Jmax = 50
S1 = 89
S2 = 112
S3 = 21
S4 = 9
H1 = 1047436521-1047436999
H2 = 1960393213-1960393900
H3 = 2111066283-2111066900
H4 = 425489310-425489900
I1 = <r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>
I2 =
I3 =
I4 =
I5 =

[Peer]
PublicKey = SrvPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0=
PresharedKey = PSKFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 198.51.100.61:443
PersistentKeepalive = 25
"""
lc = {"H1":"1047436521-1047436999","I1":"<r 2>","client_priv_key":"x","client_ip":"10.8.1.9","config":conf,"hostName":"198.51.100.61","port":443,"mtu":"1376"}
def mk(containers, default="amnezia-awg2"):
    return {"containers":containers,"defaultContainer":default,"description":"Мой сервер","dns1":"1.1.1.1","dns2":"1.0.0.1","hostName":"198.51.100.61"}
awgc = {"container":"amnezia-awg2","awg":{"H1":"1047436521-1047436999","last_config":json.dumps(lc),"port":"443","transport_proto":"udp"}}
xray = {"container":"amnezia-xray","xray":{"last_config":json.dumps({"outbounds":[]}),"port":"443"}}
def qc(b, level=-1):
    return struct.pack(">I", len(b)) + zlib.compress(b, level)
def b64u(b): return base64.urlsafe_b64encode(b).decode().rstrip("=")
def link(obj, level=-1, comp=True):
    raw = json.dumps(obj, ensure_ascii=False).encode()
    return "vpn://" + b64u(qc(raw, level) if comp else raw)
V = {}
V["A_modern"] = link(mk([awgc]))
s = V["A_modern"]; V["B_wrapped76"] = "\n".join(s[i:i+76] for i in range(0,len(s),76))
V["B2_wrapped_crlf"] = "\r\n".join(s[i:i+76] for i in range(0,len(s),76))
V["B3_space_inside"] = s[:100] + " " + s[100:]
V["C_label_prefix"] = "Ключ: " + s
V["D_old_plainjson"] = link(mk([awgc]), comp=False)
V["E_xray_first"] = link(mk([xray, awgc]))
V["F_stored_level0"] = link(mk([awgc]), level=0)
V["G_lastconfig_object"] = link(mk([{"container":"amnezia-awg2","awg":{"last_config":lc}}]))
V["H_crlf_conf"] = link(mk([{"container":"amnezia-awg2","awg":{"last_config":json.dumps(dict(lc, config=conf.replace("\n","\r\n")))}}]))
V["I_padded_std_b64"] = "vpn://" + base64.b64encode(qc(json.dumps(mk([awgc])).encode())).decode()
V["J_two_links"] = s + "\n" + s
V["K_hostname_endpoint"] = link(mk([{"container":"amnezia-awg2","awg":{"last_config":json.dumps(dict(lc, config=conf.replace("198.51.100.61:443","vpn.example.com:51820")))}}]))
big = conf.replace("I2 =", "I2 = <b 0x" + os.urandom(600).hex() + ">")
V["L_big_I2"] = link(mk([{"container":"amnezia-awg2","awg":{"last_config":json.dumps(dict(lc, config=big))}}]))
V["M_no_psk_noKA"] = link(mk([{"container":"amnezia-awg","awg":{"last_config":json.dumps(dict(lc, config="\n".join(l for l in conf.splitlines() if not l.startswith(("PresharedKey","PersistentKeepalive")))))}}]))
V["N_awg_key_variant_amnezia_awg2"] = link(mk([{"container":"amnezia-awg2","amnezia-awg2":{"last_config":json.dumps(lc)}}]))
for k,v in V.items():
    open(os.path.join(out,k+".txt"),"w",encoding="utf-8",newline="").write(v)
    print(k, len(v))
