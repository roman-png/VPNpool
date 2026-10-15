"""Deterministic vpn:// vectors for stand/tests/suites/awgdecode.sh -> fixtures/awg/dec/*.txt

    python -I stand/tests/fixtures/awg/gen-dec.py stand/tests/fixtures/awg/dec

All keys are made up, all addresses are documentation ranges (198.51.100.0/24, 203.0.113.0/24,
example.com). Shapes follow real exports: AmneziaVPN 5.x has container "amnezia-awg2" with the
protocol key "awg", format_version, dns1/dns2 and an AWG 3.1 .conf.
"""
import base64, json, os, random, struct, sys, zlib

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

AWG31 = """[Interface]
Address = 10.8.1.17/32
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = cBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=
Jc = 3
Jmin = 10
Jmax = 50
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = <r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>
HeaderProtectionKey = HPKFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE=
RandomTrailers = 1
DisableCookies = 1
RekeyAfterTime = 110-130
KeepaliveTimeout = 9-11

[Peer]
PublicKey = SrvPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE7=
PresharedKey = PSKFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAK7=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 198.51.100.7:46139
PersistentKeepalive = 25-35
"""

WG = """[Interface]
Address = 10.9.0.5/32
PrivateKey = WGc0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=

[Peer]
PublicKey = WGsPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAK0=
AllowedIPs = 0.0.0.0/0
Endpoint = 198.51.100.8:51820
"""

UUID = "11111111-2222-4333-8444-555555555555"
PBK = "KHu_Zt1CNMIJyAETBVA5LJWiSOiipcxPP2uSw89kkVc"


def qc(b, level=-1):
    return struct.pack(">I", len(b)) + zlib.compress(b, level)


def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def raw_link(b):
    return "vpn://" + b64u(b)


def link(obj, comp=True):
    raw = json.dumps(obj, ensure_ascii=False).encode()
    return raw_link(qc(raw) if comp else raw)


def top(containers, default, **kw):
    o = {"containers": containers, "defaultContainer": default, "description": "Мой сервер",
         "dns1": "1.1.1.1", "dns2": "1.0.0.1", "hostName": "198.51.100.7"}
    o.update(kw)
    return o


awg2 = {"container": "amnezia-awg2", "awg": {
    "last_config": json.dumps({"config": AWG31, "hostName": "198.51.100.7", "port": 46139,
                               "client_ip": "10.8.1.17", "mtu": "1376",
                               "H1": "1", "H2": "2", "H3": "3", "H4": "4"}),
    "port": "46139", "transport_proto": "udp", "protocol_version": "2"}}
wgc = {"container": "amnezia-wireguard", "wireguard": {
    "last_config": json.dumps({"config": WG, "hostName": "198.51.100.8", "port": 51820}), "port": "51820"}}


def xray_cfg(stream):
    return {"inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks"}],
            "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "198.51.100.9", "port": 443,
                           "users": [{"id": UUID, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
                           "streamSettings": stream}]}


reality = {"network": "tcp", "security": "reality", "realitySettings": {
    "publicKey": PBK, "shortId": "a1b2c3d4", "serverName": "www.example.com", "fingerprint": "chrome", "spiderX": ""}}
xrayc = {"container": "amnezia-xray", "xray": {"last_config": json.dumps(xray_cfg(reality)), "port": "443"}}
ws_cfg = xray_cfg({"network": "ws", "security": "tls",
                   "tlsSettings": {"serverName": "cdn.example.com", "fingerprint": "firefox", "alpn": ["http/1.1"]},
                   "wsSettings": {"path": "/ws path", "headers": {"Host": "cdn.example.com"}}})
ws_cfg["outbounds"][0]["settings"]["vnext"][0]["users"][0].pop("flow")
xray_ws = {"container": "amnezia-xray", "xray": {"last_config": ws_cfg}}          # object, not string
grpc_cfg = xray_cfg({"network": "grpc", "security": "reality",
                     "realitySettings": {"publicKey": PBK, "shortId": "", "serverName": "www.example.com"},
                     "grpcSettings": {"serviceName": "svc"}})
grpc_cfg["outbounds"][0]["settings"]["vnext"][0]["users"][0].pop("flow")
xray_grpc = {"container": "amnezia-xray", "xray": {"last_config": json.dumps(grpc_cfg)}}
ssc = {"container": "amnezia-ssxray", "ssxray": {"last_config": json.dumps({"outbounds": [
    {"protocol": "shadowsocks", "settings": {"servers": [
        {"address": "198.51.100.10", "port": 8388, "method": "chacha20-ietf-poly1305", "password": "p@ss:w0rd"}]}}]})}}

V = {}
V["awg2_amnezia5"] = link(top([awg2], "amnezia-awg2", format_version=2))
s = V["awg2_amnezia5"]
V["awg2_caption_wrapped"] = "Ваш ключ для подключения:\n" + "\n".join(s[i:i + 64] for i in range(0, len(s), 64)) + "\n\nСпасибо!\n"
V["awg2_trailing_word"] = s + "\nthanks\n"
V["awg2_uncompressed_wrapped"] = "\r\n".join(link(top([awg2], "amnezia-awg2"), comp=False)[i:i + 70]
                                             for i in range(0, len(link(top([awg2], "amnezia-awg2"), comp=False)), 70))
V["wireguard"] = link(top([wgc], "amnezia-wireguard", hostName="198.51.100.8", description=""))
V["xray_reality"] = link(top([xrayc], "amnezia-xray", hostName="198.51.100.9"))
V["xray_ws_tls_object"] = link(top([xray_ws], "amnezia-xray", description="WS"))
V["xray_grpc"] = link(top([xray_grpc], "amnezia-xray", description="GRPC"))
V["ssxray"] = link(top([ssc], "amnezia-ssxray", description="SS"))
V["default_xray_wins"] = link(top([awg2, xrayc], "amnezia-xray"))
V["no_default_awg_first"] = link(top([xrayc, wgc, awg2], None))
V["default_unsupported_falls_back"] = link(top([{"container": "amnezia-openvpn", "openvpn": {"last_config": "{}"}}, xrayc], "amnezia-openvpn"))
V["two_links"] = "AWG:\n" + s + "\n\nXRAY: " + V["xray_reality"] + " — конец"
V["api_key"] = link({"api_config": {"service_type": "amnezia-premium", "user_country_code": "XX"},
                     "auth_data": {"api_key": "FAKE-API-KEY-0000"}, "config_version": 2, "description": "Premium"})
# same without config_version: the api_key/auth_data/api_config rule alone must refuse it
V["api_key_no_version"] = link({"api_config": {"service_type": "amnezia-premium"},
                                "auth_data": {"api_key": "FAKE-API-KEY-0001"}, "description": "Premium"})
V["api_config_version_only"] = link({"config_version": 1, "name": "Amnezia Free", "api_endpoint": "https://api.example.com/"})
V["full_access"] = link(top([awg2], "amnezia-awg2", userName="root", password="FAKE-PASSWORD", port=22))
V["unsupported_only"] = link(top([{"container": "amnezia-openvpn", "openvpn": {"last_config": "{}"}},
                                  {"container": "amnezia-cloak", "cloak": {"port": "443"}}], "amnezia-openvpn"))
V["no_conf"] = link(top([{"container": "amnezia-awg", "awg": {"port": "443", "transport_proto": "udp"}}], "amnezia-awg"))
V["not_json"] = raw_link(qc(b"this is not json at all"))
V["json_array"] = raw_link(b"[1,2,3]")
V["json_broken"] = raw_link(b'{"containers": [')
rnd = random.Random(20261015)
V["garbage_random"] = raw_link(bytes(rnd.randrange(256) for _ in range(300)))
# a valid zlib header followed by zero bytes: the old decoder looped forever on it
V["garbage_zlib_zeros"] = raw_link(struct.pack(">I", 4096) + b"\x78\x9c" + b"\x00" * 64)
# valid header + random deflate body
V["garbage_zlib_random"] = raw_link(struct.pack(">I", 4096) + b"\x78\x9c" + bytes(rnd.randrange(256) for _ in range(400)))
full = qc(json.dumps(top([awg2], "amnezia-awg2")).encode())
V["truncated"] = raw_link(full[:len(full) // 2])
V["bad_adler"] = raw_link(full[:-1] + bytes([full[-1] ^ 0xFF]))
V["bad_length_prefix"] = raw_link(struct.pack(">I", 7) + full[4:])
# ---- limits (the decoder must refuse these fast, with a code) ----
# declared 4 MB of output (a zip bomb: 5 KB of input)
V["bomb_declared_4mb"] = raw_link(qc(b"\0" * (4 * 1024 * 1024), 9))


class Bits:
    def __init__(self):
        self.out, self.acc, self.n = bytearray(), 0, 0

    def put(self, v, n):            # LSB-first, like DEFLATE
        for i in range(n):
            self.acc |= ((v >> i) & 1) << self.n
            self.n += 1
            if self.n == 8:
                self.out.append(self.acc); self.acc = 0; self.n = 0

    def align(self):
        if self.n:
            self.out.append(self.acc); self.acc = 0; self.n = 0


def deflate_many_empty_blocks(payload, nblocks):
    bw = Bits()
    for _ in range(nblocks):        # BFINAL=0, BTYPE=01 (fixed), end-of-block (code 256 = 7 zero bits)
        bw.put(0, 1); bw.put(1, 2); bw.put(0, 7)
    bw.put(1, 1); bw.put(0, 2); bw.align()   # final stored block with the payload
    bw.out += struct.pack("<HH", len(payload), len(payload) ^ 0xFFFF) + payload
    z = b"\x78\x01" + bytes(bw.out) + struct.pack(">I", zlib.adler32(payload))
    return struct.pack(">I", len(payload)) + z


small = json.dumps(top([awg2], "amnezia-awg2")).encode()
# a VALID stream: 5000 empty blocks, then the real JSON (the block budget refuses it)
V["blocks_5000_valid"] = raw_link(deflate_many_empty_blocks(small, 5000))
# the same with 100 empty blocks: within budget, must decode
V["blocks_100_valid"] = raw_link(deflate_many_empty_blocks(small, 100))
# near the output limit (~200 KB of JSON): still decodes
bigconf = AWG31.replace("I1 = ", "I2 = <b 0x" + "ab" * 98000 + ">\nI1 = ")
V["near_limit_200k_ok"] = link(top([{"container": "amnezia-awg2", "awg": {
    "last_config": json.dumps({"config": bigconf, "hostName": "198.51.100.7"})}}], "amnezia-awg2"))

# ---- hostile types inside an xray container: always a JSON answer ----
def xr(stream=None, settings=None, desc="T"):
    ob = xray_cfg(stream if stream is not None else reality)["outbounds"][0]
    if settings is not None:
        ob["settings"] = settings
    return link(top([{"container": "amnezia-xray", "xray": {"last_config": json.dumps({"outbounds": [ob]})}}],
                    "amnezia-xray", description=desc))


V["xray_stream_str"] = xr(stream="x")
V["xray_reality_num"] = xr(stream={"network": "tcp", "security": "reality", "realitySettings": 5})
V["xray_ws_headers_str"] = xr(stream={"network": "ws", "security": "tls", "tlsSettings": "x",
                                     "wsSettings": {"path": ["/a"], "headers": "x"}})
V["xray_vnext_str"] = xr(settings={"vnext": "x"})
V["xray_settings_arr"] = xr(settings=[1, 2])
V["xray_nonscalar"] = xr(stream={"network": 5, "security": ["x"]})
V["xray_tcp_http_insecure"] = xr(stream={"network": "tcp", "security": "tls",
                                        "tlsSettings": {"serverName": "h.example.com", "allowInsecure": True},
                                        "tcpSettings": {"header": {"type": "http", "request": {
                                            "path": ["/p"], "headers": {"Host": ["h.example.com"]}}}}})
V["ss_sip002"] = link(top([{"container": "amnezia-ssxray", "ssxray": {"last_config": json.dumps({"outbounds": [
    {"protocol": "shadowsocks", "settings": {"servers": [
        {"address": "198.51.100.10", "port": 8388, "method": "aes-256-gcm", "password": "???>>>???"}]}}]})}}],
    "amnezia-ssxray", description="SIP"))
V["awg_endpoint_colon"] = link(top([{"container": "amnezia-awg2", "awg": {"last_config": json.dumps(
    {"config": AWG31.replace("Endpoint = 198.51.100.7:46139", "Endpoint = :")})}}], "amnezia-awg2"))
V["not_base64"] = "vpn://%%%%"
V["no_link"] = "Привет! Ссылку пришлю позже.\n"

for k, v in V.items():
    with open(os.path.join(out, k + ".txt"), "w", encoding="utf-8", newline="") as f:
        f.write(v)
    print(k, len(v))
