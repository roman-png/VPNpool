#!/usr/bin/ucode
// vpnpool subscription/link parser.
// Input : one or more files (ARGV) and/or stdin. Each input may be:
//           - base64 / base64url blob of a link list,
//           - a plaintext list of links: vless:// vmess:// trojan:// ss:// hysteria2:// hy2://
//             tuic://  (one per line; blank and '#' comment lines are ignored),
//           - a sing-box JSON config ({outbounds:[...]}) or a bare outbounds array,
//           - an AmneziaWG / WireGuard .conf (INI, one per input).
//         Text that merely LOOKS like JSON (starts with '[' / '{') but is not, falls back to
//         the line-by-line parser instead of aborting the whole run.
// Output: JSON array of sing-box outbound objects (proxy nodes), on stdout.
//         Global dedup + unique tags across ALL inputs (so multi-source/multi-UA
//         results merge cleanly).
// Flags (leading, any order):
//   --keep-link  attach the original link as `_link` (probe.sh / rpcd import / links.json)
//   --with-id    attach the stable node identity `id` (see node_id). NOT for the live build:
//                sing-box rejects unknown outbound fields, so nodes.json must stay id-free.
//   --report     instead of the node array print one record per input line / JSON item:
//                {src, line|item, status:"ok"|"skip", reason?, tag?, type?, id?, dup_of?,
//                 tag_changed?}. reason is a machine code (no human text — that lives in po):
//                not_a_link unknown_scheme parse_error bad_port bad_server bad_uuid
//                bad_reality_key bad_short_id unsupported_transport unsupported_security
//                unsupported_encryption unsupported_flow unsupported_method unsupported_plugin
//                unsupported_obfs bad_key tls_required duplicate not_a_node no_nodes
'use strict';

import { readfile, stdin } from 'fs';

let nodes = [];
let seen = {};       // dedup key -> final tag of the node that owns it
let used_tags = {};
// Tags the generator itself defines (urltest "auto", selector "proxy", "direct"; "block" and
// "dns-out" are the conventional names of the other built-ins). A node may never take one:
// two outbounds with one tag make `sing-box check` reject the whole config.
// "vpnpool-test" is the selector of the test route (speedtest/unlock, ROADMAP 2.8).
let RESERVED_TAGS = { auto: 1, proxy: 1, direct: 1, block: 1, 'dns-out': 1, 'vpnpool-test': 1 };
let KEEP_LINK = false;
let WITH_ID = false;
let REPORT = false;
let report = [];
let cur_src = 0;

function url_decode(s) {
	return replace(s, /%[0-9A-Fa-f][0-9A-Fa-f]/g, function (m) {
		return chr(hex(substr(m, 1, 2)));
	});
}

function parse_query(q) {
	let out = {};
	for (let pair in split(q, '&')) {
		if (!length(pair)) continue;
		let eq = index(pair, '=');
		if (eq < 0) { out[pair] = ''; continue; }
		out[substr(pair, 0, eq)] = url_decode(substr(pair, eq + 1));
	}
	return out;
}

// first non-empty query value among several spellings of one parameter
function qv(p, ...names) {
	for (let n in names)
		if (length(p[n])) return p[n];
	return null;
}

function csv(s) {
	let out = [];
	for (let x in split(s ?? '', ',')) {
		x = trim(x);
		if (length(x)) push(out, x);
	}
	return out;
}

function truthy(v) {
	v = lc(v ?? '');
	return v == '1' || v == 'true' || v == 'yes';
}

// base64 or base64url, with or without '=' padding (ucode's b64dec wants padded std base64)
function b64_any(s) {
	if (type(s) != 'string') return null;
	s = replace(s, /\s/g, '');
	s = replace(s, /-/g, '+');
	s = replace(s, /_/g, '/');
	s = replace(s, /=+$/, '');
	if (!length(s) || !match(s, /^[A-Za-z0-9+\/]+$/)) return null;
	let r = length(s) % 4;
	if (r == 1) return null;
	if (r) s += substr('==', 0, 4 - r);
	return b64dec(s);
}

// a real UUID is case-insensitive -> lower-case it (one node, one id); any other string is
// kept verbatim (vless/vmess map it to a UUIDv5, where case matters)
function norm_uuid(s) {
	return match(s, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) ? lc(s) : s;
}

function vport(s) {
	if (type(s) == 'int') s = '' + s;
	if (type(s) != 'string' || !match(s, /^[0-9]{1,5}$/)) return null;
	let n = int(s);
	return (n >= 1 && n <= 65535) ? n : null;
}

let HOST_BAD_CHARS = ' \t/\\@?#<>"\'[]{}|^`';
function bad_host(h) {
	if (type(h) != 'string' || !length(h)) return true;
	for (let i = 0; i < length(HOST_BAD_CHARS); i++)
		if (index(h, substr(HOST_BAD_CHARS, i, 1)) >= 0) return true;
	return false;
}

// "host:port" / "[v6]:port" / "host" -> { host, port } (port: raw string or null); null if malformed
function split_hostport(s) {
	if (substr(s, 0, 1) == '[') {
		let rb = index(s, ']');
		if (rb < 0) return null;
		let tail = substr(s, rb + 1);
		if (length(tail) && substr(tail, 0, 1) != ':') return null;
		return { host: substr(s, 1, rb - 1), port: length(tail) ? substr(tail, 1) : null };
	}
	let c = rindex(s, ':');
	if (c < 0) return { host: s, port: null };
	return { host: substr(s, 0, c), port: substr(s, c + 1) };
}

// scheme://[userinfo@]host[:port][/path][?query][#name]
function split_url(line, skip) {
	let rest = substr(line, skip);
	let name = '';
	let h = index(rest, '#');
	if (h >= 0) { name = trim(url_decode(substr(rest, h + 1))); rest = substr(rest, 0, h); }
	let query = '';
	let q = index(rest, '?');
	if (q >= 0) { query = substr(rest, q + 1); rest = substr(rest, 0, q); }
	let user = null;
	let at = rindex(rest, '@');
	if (at >= 0) { user = substr(rest, 0, at); rest = substr(rest, at + 1); }
	let path = '';
	let sl = index(rest, '/');
	if (sl >= 0) { path = substr(rest, sl); rest = substr(rest, 0, sl); }
	let hp = split_hostport(rest);
	if (!hp) return null;
	return { user: user, host: hp.host, port: hp.port, path: path, query: parse_query(query), name: name };
}

function hp_label(host, port) {
	return ((index(host, ':') >= 0) ? ('[' + host + ']') : host) + ':' + port;
}

// sing-box 1.12..1.14 uTLS fingerprints (verified with `sing-box check`); anything else would
// make check reject the WHOLE config, so an unknown one falls back to chrome.
let UTLS_FP = {
	chrome: 1, firefox: 1, edge: 1, safari: 1, '360': 1, qq: 1, ios: 1, android: 1,
	random: 1, randomized: 1, chrome_psk: 1, chrome_psk_shuffle: 1,
	chrome_padding_psk_shuffle: 1, chrome_pq: 1, chrome_pq_psk: 1
};

// TLS object from link params. mode: 'tls' | 'reality' | 'quic' (QUIC-based protocols: no uTLS)
// -> object, or a reason string
function build_tls(p, mode) {
	let tls = { enabled: true };
	let sni = qv(p, 'sni', 'peer', 'serverName');
	if (length(sni)) tls.server_name = sni;
	let alpn = csv(qv(p, 'alpn'));
	if (length(alpn)) tls.alpn = alpn;
	if (truthy(qv(p, 'allowInsecure', 'insecure', 'allow_insecure', 'skip-cert-verify')))
		tls.insecure = true;
	if (mode != 'quic') {
		let fp = lc(qv(p, 'fp', 'fingerprint') ?? '');
		if (fp == 'none') fp = '';          // "no uTLS" (reality still gets chrome below)
		if (length(fp))
			tls.utls = { enabled: true, fingerprint: UTLS_FP[fp] ? fp : 'chrome' };
		else if (mode == 'reality')
			tls.utls = { enabled: true, fingerprint: 'chrome' };   // reality REQUIRES uTLS in sing-box
	}
	if (mode == 'reality') {
		// reality needs a valid x25519 pubkey (32 bytes -> 43/44 base64 chars);
		// junk lists carry malformed keys that stall probe pruning — drop here.
		let pbk = p.pbk;
		if (!length(pbk) || !match(pbk, /^[A-Za-z0-9_\/+-]{43,44}={0,1}$/))
			return 'bad_reality_key';
		// short_id: hex, even length, at most 8 bytes — a longer one PANICS sing-box 1.12/1.14
		if (length(p.sid) && !match(p.sid, /^([0-9a-fA-F][0-9a-fA-F]){1,8}$/))
			return 'bad_short_id';
		tls.reality = { enabled: true, public_key: pbk };
		if (p.sid != null) tls.reality.short_id = p.sid;
	}
	return tls;
}

// transport from xray-style params (type/host/path/serviceName/headerType/ed/eh)
// -> null (plain TCP), an object, or a reason string. Anything sing-box has no transport for
// (xhttp, splithttp, kcp, ...) is refused: such a node would be dead (or poison the config).
function build_transport(p, tls) {
	let t = lc(p.type ?? '');
	let host = p.host ?? '';
	let path = p.path ?? '';
	if (t == '' || t == 'tcp' || t == 'raw') {
		if (lc(p.headerType ?? '') != 'http')
			return null;
		// TCP with an HTTP/1.1 header obfuscation = sing-box http transport without TLS
		let tr = { type: 'http', method: 'GET' };
		let hosts = csv(host);
		if (length(hosts)) tr.host = hosts;
		let paths = csv(path);
		if (length(paths)) tr.path = paths[0];
		return tr;
	}
	if (t == 'ws' || t == 'websocket') {
		let tr = { type: 'ws' };
		let ed = qv(p, 'ed');
		// xray carries early data inside the path: "/ws?ed=2048"
		let qi = index(path, '?');
		if (qi >= 0) {
			let keep = [];
			for (let kv in split(substr(path, qi + 1), '&')) {
				if (substr(kv, 0, 3) == 'ed=') ed = substr(kv, 3);
				else if (length(kv)) push(keep, kv);
			}
			path = substr(path, 0, qi) + (length(keep) ? ('?' + join('&', keep)) : '');
		}
		if (length(path)) tr.path = path;
		if (length(host)) tr.headers = { Host: host };
		if (length(ed) && match(ed, /^[0-9]+$/) && int(ed) > 0) {
			tr.max_early_data = int(ed);
			tr.early_data_header_name = qv(p, 'eh') ?? 'Sec-WebSocket-Protocol';
		}
		return tr;
	}
	if (t == 'grpc' || t == 'gun') {
		let tr = { type: 'grpc' };
		let sn = qv(p, 'serviceName', 'service_name');
		if (length(sn)) tr.service_name = sn;
		return tr;
	}
	if (t == 'httpupgrade') {
		let tr = { type: 'httpupgrade' };
		let hosts = csv(host);
		if (length(hosts)) tr.host = hosts[0];
		if (length(path)) tr.path = path;
		return tr;
	}
	if (t == 'http' || t == 'h2') {
		let tr = { type: 'http' };
		let hosts = csv(host);
		if (length(hosts)) tr.host = hosts;
		if (length(path)) tr.path = path;
		return tr;
	}
	if (t == 'quic') {
		if (!tls) return 'tls_required';
		if (tls.reality) return 'unsupported_transport';         // QUIC cannot carry reality
		let qs = lc(p.quicSecurity ?? '');
		if (length(qs) && qs != 'none') return 'unsupported_transport';
		delete tls.utls;                                         // no uTLS over QUIC
		return { type: 'quic' };
	}
	return 'unsupported_transport';
}

// common server/port checks for URL-style links -> reason string or null
function check_endpoint(u) {
	if (bad_host(u.host)) return 'bad_server';
	if (vport(u.port) == null) return 'bad_port';
	return null;
}

function parse_vless(line) {
	let u = split_url(line, 8);
	if (!u) return 'parse_error';
	let e = check_endpoint(u);
	if (e) return e;
	let uuid = norm_uuid(url_decode(u.user ?? ''));
	if (!length(uuid) || match(uuid, /[\s:]/)) return 'bad_uuid';
	let p = u.query;
	// newer xray "encryption" (ML-KEM etc.) has no sing-box counterpart
	let enc = lc(p.encryption ?? '');
	if (length(enc) && enc != 'none') return 'unsupported_encryption';
	let port = vport(u.port);
	let ob = {
		type: 'vless',
		tag: length(u.name) ? u.name : hp_label(u.host, port),
		server: u.host,
		server_port: port,
		uuid: uuid
	};
	// sing-box only accepts an empty flow or exactly 'xtls-rprx-vision'. Public
	// subscription lists often carry variants like 'xtls-rprx-vision-udp443' that
	// sing-box rejects — and ONE such node makes `sing-box check` reject the WHOLE
	// config. Normalise any vision variant to 'xtls-rprx-vision'; drop nodes whose
	// flow we don't understand rather than poisoning the entire config.
	if (length(p.flow)) {
		if (substr(p.flow, 0, 16) == 'xtls-rprx-vision')
			ob.flow = 'xtls-rprx-vision';
		else
			return 'unsupported_flow';
	}
	let sec = lc(p.security ?? '');
	if (sec == 'tls' || sec == 'xtls' || sec == 'reality') {
		let tls = build_tls(p, sec == 'reality' ? 'reality' : 'tls');
		if (type(tls) == 'string') return tls;
		ob.tls = tls;
	} else if (length(sec) && sec != 'none')
		return 'unsupported_security';
	let tr = build_transport(p, ob.tls);
	if (type(tr) == 'string') return tr;
	if (tr) ob.transport = tr;
	return ob;
}

function parse_trojan(line) {
	let u = split_url(line, 9);
	if (!u) return 'parse_error';
	let e = check_endpoint(u);
	if (e) return e;
	let pw = url_decode(u.user ?? '');
	if (!length(pw)) return 'bad_uuid';
	let p = u.query;
	let port = vport(u.port);
	let ob = {
		type: 'trojan', tag: length(u.name) ? u.name : hp_label(u.host, port),
		server: u.host, server_port: port, password: pw
	};
	let sec = lc(p.security ?? 'tls');       // trojan is TLS unless told otherwise
	if (sec == '' || sec == 'tls' || sec == 'xtls' || sec == 'reality') {
		let tls = build_tls(p, sec == 'reality' ? 'reality' : 'tls');
		if (type(tls) == 'string') return tls;
		ob.tls = tls;
	} else if (sec != 'none')
		return 'unsupported_security';
	let tr = build_transport(p, ob.tls);
	if (type(tr) == 'string') return tr;
	if (tr) ob.transport = tr;
	return ob;
}

let VMESS_SECURITY = { auto: 1, none: 1, zero: 1, 'aes-128-gcm': 1, 'chacha20-poly1305': 1 };

function parse_vmess(line) {
	let dec = b64_any(substr(line, 8));
	if (!dec) return 'parse_error';
	let v;
	try { v = json(dec); } catch (e) { v = null; }
	if (type(v) != 'object') return 'parse_error';
	let server = (v.add != null) ? trim('' + v.add) : '';
	if (substr(server, 0, 1) == '[' && substr(server, -1) == ']')
		server = substr(server, 1, length(server) - 2);
	if (bad_host(server)) return 'bad_server';
	let port = vport((v.port != null) ? trim('' + v.port) : null);
	if (port == null) return 'bad_port';
	let uuid = (v.id != null) ? norm_uuid(trim('' + v.id)) : '';
	if (!length(uuid)) return 'bad_uuid';
	// the vmess server accepts whatever cipher the client picks: an unknown one -> auto
	let scy = lc(v.scy ?? '');
	let ps = (v.ps != null) ? trim('' + v.ps) : '';
	let ob = {
		type: 'vmess',
		tag: length(ps) ? ps : hp_label(server, port),
		server: server, server_port: port,
		uuid: uuid, alter_id: int(v.aid ?? 0) || 0,
		security: VMESS_SECURITY[scy] ? scy : 'auto'
	};
	if (lc(v.tls ?? '') == 'tls') {
		let sni = length(v.sni) ? v.sni : v.host;
		let tls = build_tls({ sni: sni, alpn: v.alpn, fp: v.fp,
			allowInsecure: (v.allowInsecure != null) ? ('' + v.allowInsecure) : null }, 'tls');
		if (type(tls) == 'string') return tls;
		ob.tls = tls;
	}
	let net = lc(v.net ?? '');
	let pp = { type: net, host: v.host, path: v.path, headerType: v.type, serviceName: v.path };
	if (net == 'quic') { pp.quicSecurity = v.host; pp.host = null; }
	let tr = build_transport(pp, ob.tls);
	if (type(tr) == 'string') return tr;
	if (tr) ob.transport = tr;
	return ob;
}

// sing-box 1.12..1.14 shadowsocks methods (verified with `sing-box check`)
let SS_METHODS = {
	none: 1, '2022-blake3-aes-128-gcm': 1, '2022-blake3-aes-256-gcm': 1,
	'2022-blake3-chacha20-poly1305': 1, 'aes-128-gcm': 1, 'aes-192-gcm': 1, 'aes-256-gcm': 1,
	'chacha20-ietf-poly1305': 1, 'xchacha20-ietf-poly1305': 1, 'aes-128-ctr': 1,
	'aes-192-ctr': 1, 'aes-256-ctr': 1, 'aes-128-cfb': 1, 'aes-192-cfb': 1, 'aes-256-cfb': 1,
	'rc4-md5': 1, 'chacha20-ietf': 1, xchacha20: 1
};

function parse_ss(line) {
	// SIP002: ss://base64url(method:password)@host:port[/][?plugin=...]#name
	//         ss://method:password@host:port...  (2022: userinfo is URL-encoded, not base64)
	// legacy: ss://base64(method:password@host:port)#name
	let rest = substr(line, 5);
	let name = '';
	let h = index(rest, '#');
	if (h >= 0) { name = trim(url_decode(substr(rest, h + 1))); rest = substr(rest, 0, h); }
	let p = {};
	let q = index(rest, '?');
	if (q >= 0) { p = parse_query(substr(rest, q + 1)); rest = substr(rest, 0, q); }

	let cred, hostport;
	let at = rindex(rest, '@');
	if (at >= 0) {
		let ui = url_decode(substr(rest, 0, at));
		hostport = substr(rest, at + 1);
		cred = (index(ui, ':') >= 0) ? ui : b64_any(ui);
	} else {
		let dec = b64_any(url_decode(replace(rest, /\/+$/, '')));
		if (!dec) return 'parse_error';
		let at2 = rindex(dec, '@');
		if (at2 < 0) return 'parse_error';
		cred = substr(dec, 0, at2);
		hostport = substr(dec, at2 + 1);
	}
	hostport = replace(hostport, /\/+$/, '');
	if (!cred) return 'parse_error';
	let c = index(cred, ':');
	if (c < 0) return 'parse_error';
	let method = lc(trim(substr(cred, 0, c)));
	let password = substr(cred, c + 1);
	let hp = split_hostport(hostport);
	if (!hp) return 'parse_error';
	if (bad_host(hp.host)) return 'bad_server';
	let port = vport(hp.port);
	if (port == null) return 'bad_port';
	if (!SS_METHODS[method]) return 'unsupported_method';
	// ss-2022: the key (or each "server:user" key) must decode to 16 / 32 bytes
	if (substr(method, 0, 5) == '2022-') {
		let need = (index(method, 'aes-128') >= 0) ? 16 : 32;
		for (let part in split(password, ':')) {
			let k = b64_any(part);
			if (!k || length(k) != need) return 'bad_key';
		}
	}
	let ob = {
		type: 'shadowsocks', tag: length(name) ? name : hp_label(hp.host, port),
		server: hp.host, server_port: port, method: method, password: password
	};
	// plugin=<name>;<opts> -> sing-box plugin + plugin_opts (it knows obfs-local and v2ray-plugin)
	if (length(p.plugin)) {
		let semi = index(p.plugin, ';');
		let pname = lc(trim((semi >= 0) ? substr(p.plugin, 0, semi) : p.plugin));
		let popts = (semi >= 0) ? substr(p.plugin, semi + 1) : '';
		if (pname == 'simple-obfs') pname = 'obfs-local';
		if (pname == 'obfs-local' || pname == 'v2ray-plugin') {
			ob.plugin = pname;
			if (length(popts)) ob.plugin_opts = popts;
		} else if (length(pname) && pname != 'none')
			return 'unsupported_plugin';
	}
	return ob;
}

// "100", "100 mbps", "1gbps" -> integer Mbps (null if unparseable / below 1 Mbps)
function mbps(s) {
	let m = match(lc(s ?? ''), /^\s*([0-9]+)\s*([kmgt]?)/);
	if (!m) return null;
	let n = int(m[1]);
	if (m[2] == 'k') n = int(n / 1000);
	else if (m[2] == 'g') n = n * 1000;
	else if (m[2] == 't') n = n * 1000000;
	return (n > 0) ? n : null;
}

// hysteria2://[auth@]host[:port[,port|lo-hi...]][/]?obfs=salamander&obfs-password=..&sni=..
//   &insecure=1&mport=lo-hi&up=..&down=..#name   (also hy2://)
function parse_hy2(line, skip) {
	let u = split_url(line, skip);
	if (!u) return 'parse_error';
	if (bad_host(u.host)) return 'bad_server';
	let p = u.query;
	let port = null;
	let ranges = [];
	let specs = csv(u.port);
	for (let r in csv(qv(p, 'mport', 'ports'))) push(specs, r);
	for (let s in specs) {
		let d = index(s, '-');
		if (d < 0) {
			let n = vport(s);
			if (n == null) return 'bad_port';
			if (port == null) port = n;
			else push(ranges, n + ':' + n);
		} else {
			let lo = vport(substr(s, 0, d)), hi = vport(substr(s, d + 1));
			if (lo == null || hi == null || lo > hi) return 'bad_port';
			push(ranges, lo + ':' + hi);
		}
	}
	if (port == null && !length(ranges)) port = 443;
	let ob = {
		type: 'hysteria2',
		tag: length(u.name) ? u.name : hp_label(u.host, port ?? split(ranges[0], ':')[0]),
		server: u.host
	};
	if (port != null) ob.server_port = port;
	if (length(ranges)) {
		// sing-box ignores server_port once server_ports is set: keep the single port in the
		// hop set too, as hysteria2 clients do
		if (port != null) unshift(ranges, port + ':' + port);
		ob.server_ports = ranges;
		let hi = qv(p, 'hop_interval', 'hopInterval', 'hop-interval');
		if (length(hi) && match(hi, /^[0-9]+$/)) ob.hop_interval = hi + 's';
	}
	let pw = url_decode(u.user ?? '');
	if (length(pw)) ob.password = pw;
	let up = mbps(qv(p, 'up', 'upmbps', 'up_mbps')), down = mbps(qv(p, 'down', 'downmbps', 'down_mbps'));
	if (up) ob.up_mbps = up;
	if (down) ob.down_mbps = down;
	let obfs = lc(p.obfs ?? '');
	if (obfs == 'salamander')
		ob.obfs = { type: 'salamander', password: qv(p, 'obfs-password', 'obfs_password', 'obfsParam') ?? '' };
	else if (length(obfs) && obfs != 'none')
		return 'unsupported_obfs';
	ob.tls = build_tls(p, 'quic');
	return ob;
}

let TUIC_CC = { cubic: 1, new_reno: 1, bbr: 1 };

// tuic://uuid:password@host:port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=..#name
function parse_tuic(line) {
	let u = split_url(line, 7);
	if (!u) return 'parse_error';
	let e = check_endpoint(u);
	if (e) return e;
	let cred = url_decode(u.user ?? '');
	let c = index(cred, ':');
	let uuid = norm_uuid((c >= 0) ? substr(cred, 0, c) : cred);
	// TUIC v5 needs a real UUID (sing-box refuses anything else at start-up)
	if (!match(uuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/))
		return 'bad_uuid';
	let p = u.query;
	let port = vport(u.port);
	let ob = {
		type: 'tuic', tag: length(u.name) ? u.name : hp_label(u.host, port),
		server: u.host, server_port: port, uuid: uuid
	};
	if (c >= 0 && length(substr(cred, c + 1))) ob.password = substr(cred, c + 1);
	let cc = lc(qv(p, 'congestion_control', 'congestion-control', 'congestion') ?? '');
	if (cc == 'newreno') cc = 'new_reno';
	if (TUIC_CC[cc]) ob.congestion_control = cc;
	let mode = lc(qv(p, 'udp_relay_mode', 'udp-relay-mode') ?? '');
	if (mode == 'native' || mode == 'quic') ob.udp_relay_mode = mode;
	ob.tls = build_tls(p, 'quic');
	return ob;
}

function awg_split_csv(s) {
	let out = [];
	for (let p in split(s, ',')) {
		p = trim(p);
		if (length(p)) push(out, p);
	}
	return out;
}

// AmneziaWG / WireGuard .conf (INI) -> sing-box >=1.13 "wireguard" endpoint object.
// (The generator routes type=='wireguard' into the top-level "endpoints" array, not
// "outbounds".) AWG2 junk/obfuscation params (jc/jmin/jmax, s1..s4, h1..h4, i1..i5) are
// endpoint-root fields; h1..h4 may be a single int OR an AWG2 "lo-hi" range (kept as a
// string). Endpoint host:port -> peers[0].address + .port.
function parse_awg_conf(raw) {
	let iface = {}, peer = {}, sect = '';
	for (let line in split(raw, /\r?\n/)) {
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#' || substr(line, 0, 1) == ';') continue;
		let low = lc(line);
		if (low == '[interface]') { sect = 'i'; continue; }
		if (low == '[peer]')      { sect = 'p'; continue; }
		let eq = index(line, '=');
		if (eq < 0) continue;
		let k = lc(trim(substr(line, 0, eq)));
		let v = trim(substr(line, eq + 1));
		if (sect == 'i') iface[k] = v;
		else if (sect == 'p') peer[k] = v;
	}
	if (!length(iface.privatekey) || !length(peer.publickey) || !length(peer.endpoint))
		return null;

	// type 'awg' = AmneziaWG endpoint (amnezia-box fork, constant.TypeAwg). jc/jmin/jmax
	// and s1..s4 are ints; h1..h4 and i1..i5 are STRINGS (h may be a single value or an
	// AWG2 "lo-hi" range — kept verbatim either way).
	let ep = { type: 'awg', private_key: iface.privatekey };
	if (length(iface.address)) ep.address = awg_split_csv(iface.address);
	for (let f in ['jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4'])
		if (length(iface[f])) ep[f] = int(iface[f]);
	for (let f in ['h1', 'h2', 'h3', 'h4'])
		if (length(iface[f])) ep[f] = iface[f];
	for (let f in ['i1', 'i2', 'i3', 'i4', 'i5'])
		if (length(iface[f])) ep[f] = iface[f];

	// MTU: honor explicit; else default 1280 for AWG2 (s3/s4 add junk to every packet,
	// so a too-high MTU lets the handshake pass but stalls data with "message too long").
	if (length(iface.mtu)) ep.mtu = int(iface.mtu);
	else if (length(iface.s3) || length(iface.s4)) ep.mtu = 1280;

	let endp = peer.endpoint;
	let cc = rindex(endp, ':');
	if (cc < 0) return null;
	let host = substr(endp, 0, cc), port = int(substr(endp, cc + 1));
	if (substr(host, 0, 1) == '[' && substr(host, length(host) - 1) == ']')
		host = substr(host, 1, length(host) - 2);     // strip IPv6 brackets
	if (!length(host) || !port) return null;

	let pr = {
		address: host, port: port, public_key: peer.publickey,
		allowed_ips: length(peer.allowedips) ? awg_split_csv(peer.allowedips) : ['0.0.0.0/0', '::/0']
	};
	if (length(peer.presharedkey)) pr.preshared_key = peer.presharedkey;
	if (length(peer.persistentkeepalive)) pr.persistent_keepalive_interval = int(peer.persistentkeepalive);
	ep.peers = [ pr ];
	ep.tag = host + ':' + port;
	return ep;
}

// ---- canonical form, node identity (ROADMAP 2.2) ----
// canon(v): JSON text with object keys sorted (recursively), so the same config written with
// another key order (a sing-box JSON source) is the same string.
function canon(v) {
	if (type(v) == 'object') {
		let ks = sort(keys(v), (a, b) => (a < b) ? -1 : ((a > b) ? 1 : 0));
		let parts = [];
		for (let k in ks)
			push(parts, sprintf('%J', k) + ':' + canon(v[k]));
		return '{' + join(',', parts) + '}';
	}
	if (type(v) == 'array') {
		let parts = [];
		for (let x in v) push(parts, canon(x));
		return '[' + join(',', parts) + ']';
	}
	return sprintf('%J', v);
}

// the node's sing-box config without the display/bookkeeping fields
function bare(ob) {
	let c = {};
	for (let k in ob)
		if (k != 'tag' && k != 'id' && k != '_link') c[k] = ob[k];
	return c;
}

// id = first 12 hex of two independent 32-bit FNV-1a passes over canon(outbound WITHOUT tag).
// So every field that ends up in the sing-box outbound (server, port, credential, TLS incl.
// fingerprint, reality, transport, obfs password, ss plugin, ...) is part of the identity; the
// display name, the input order and the JSON key order are not. The parser normalises what is
// case-insensitive (UUIDs, fingerprint, ss method) before this, so the same node written
// differently gets one id. Two nodes with the same config and different names share an id
// (merging them is ROADMAP 2.2). AWG/WireGuard nodes get no id here (stage 4).
function fnv1a(s, h) {
	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 16777619) & 0xffffffff;
	return h;
}

function node_id(ob) {
	let key = canon(bare(ob));
	let a = fnv1a(key, 0x811c9dc5), b = fnv1a(key, 0x9747b28c);
	return substr(sprintf('%08x%08x', a, b), 0, 12);
}

function unique_tag(base) {
	let cand = base, n = 1;
	// a loop, not one attempt: "A","A","A #2" must not end up with two "A #2"
	while (used_tags[cand] || RESERVED_TAGS[cand]) {
		n++;
		cand = base + ' #' + n;
	}
	used_tags[cand] = true;
	return cand;
}

// dedup key: display name + the node's whole config (key order irrelevant). The same config
// under ANOTHER name stays a separate node (a user's own copy of a subscription node must not
// vanish); merging those is ROADMAP 2.2 together with the id-keyed stores.
function config_key(base, ob) {
	return base + '\x1f' + canon(bare(ob));
}

// -> report fields { status, tag?, type?, id?, reason?, dup_of?, tag_changed? }
function add_node(ob, dedupkey, link) {
	if (!ob || type(ob) != 'object') return { status: 'skip', reason: 'parse_error' };
	let is_awg = (ob.type == 'awg' || ob.type == 'wireguard');
	let base = length(ob.tag) ? trim('' + ob.tag) : ((ob.server ?? 'node') + ':' + (ob.server_port ?? 0));
	if (!length(base)) base = 'node';
	if (dedupkey == null) dedupkey = config_key(base, ob);
	if (seen[dedupkey] != null)
		return { status: 'skip', reason: 'duplicate', type: ob.type, dup_of: seen[dedupkey] };
	ob.tag = unique_tag(base);
	seen[dedupkey] = ob.tag;
	let id = (is_awg || !(WITH_ID || REPORT)) ? null : node_id(ob);
	if (WITH_ID && id) ob.id = id;
	if (KEEP_LINK && type(link) == 'string')
		ob._link = link;
	push(nodes, ob);
	let r = { status: 'ok', tag: ob.tag, type: ob.type };
	if (id) r.id = id;
	if (ob.tag != base) r.tag_changed = true;
	return r;
}

function rec(r) {
	if (!REPORT) return;
	r.src = cur_src;
	push(report, r);
}

function looks_base64(s) {
	if (index(s, '://') >= 0) return false;
	let c = substr(s, 0, 1);
	if (c == '{' || c == '[') return false;
	return match(s, /^[A-Za-z0-9+\/=_\s-]+$/) ? true : false;
}

let PROXY_TYPES = {
	vless: 1, vmess: 1, trojan: 1, shadowsocks: 1, shadowtls: 1,
	hysteria: 1, hysteria2: 1, tuic: 1, wireguard: 1, awg: 1, ssh: 1
};

let JSON_TRANSPORTS = { ws: 1, grpc: 1, http: 1, httpupgrade: 1, quic: 1 };

// The same guards the link parsers apply, for an outbound taken verbatim from a sing-box JSON
// source: ONE bad outbound there would make `sing-box check` reject the whole config (or, with
// a long reality short_id, PANIC — no "outbounds[N]" for build.sh to prune). Normalises what the
// link parsers normalise (fingerprint, vision flow variants, vmess cipher, tuic knobs).
// -> reason string, or null if the outbound may go into the config
function check_json_node(o) {
	let t = o.type;
	if (t == 'wireguard' || t == 'awg') return null;          // AWG/WG: stage 4
	if (o.server != null && (type(o.server) != 'string' || bad_host(o.server))) return 'bad_server';
	if (o.server_port != null && (type(o.server_port) != 'int' || vport(o.server_port) == null))
		return 'bad_port';
	if (o.server_ports != null) {
		if (type(o.server_ports) != 'array') return 'bad_port';
		for (let r in o.server_ports) {
			let m = (type(r) == 'string') ? match(r, /^([0-9]+):([0-9]+)$/) : null;
			if (!m || vport(m[1]) == null || vport(m[2]) == null || int(m[1]) > int(m[2])) return 'bad_port';
		}
	}
	if ((t == 'vless' || t == 'vmess') && (type(o.uuid) != 'string' || !length(o.uuid))) return 'bad_uuid';
	if (t == 'tuic' && (type(o.uuid) != 'string' ||
	    !match(o.uuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/)))
		return 'bad_uuid';
	let tls = o.tls;
	if (tls != null && type(tls) != 'object') return 'parse_error';
	if (tls?.utls != null) {
		if (type(tls.utls) != 'object') return 'parse_error';
		let fp = lc('' + (tls.utls.fingerprint ?? ''));
		if (length(fp)) tls.utls.fingerprint = UTLS_FP[fp] ? fp : 'chrome';
	}
	if (tls?.reality != null && tls.reality.enabled !== false) {
		let rl = tls.reality;
		if (type(rl) != 'object' || type(rl.public_key) != 'string' ||
		    !match(rl.public_key, /^[A-Za-z0-9_\/+-]{43,44}={0,1}$/))
			return 'bad_reality_key';
		if (rl.short_id != null && (type(rl.short_id) != 'string' ||
		    (length(rl.short_id) && !match(rl.short_id, /^([0-9a-fA-F][0-9a-fA-F]){1,8}$/))))
			return 'bad_short_id';
		if (type(tls.utls) != 'object' || tls.utls.enabled !== true)   // reality REQUIRES uTLS
			tls.utls = { enabled: true, fingerprint: 'chrome' };
	}
	let tls_on = (type(tls) == 'object' && tls.enabled === true);
	if ((t == 'hysteria2' || t == 'tuic' || t == 'hysteria') && !tls_on) return 'tls_required';
	if (o.transport != null) {
		if (type(o.transport) != 'object' || !JSON_TRANSPORTS[o.transport.type]) return 'unsupported_transport';
		if (o.transport.type == 'quic' && !tls_on) return 'tls_required';
	}
	if (t == 'vless' && length(o.flow)) {
		if (substr(o.flow, 0, 16) == 'xtls-rprx-vision') o.flow = 'xtls-rprx-vision';
		else return 'unsupported_flow';
	}
	if (t == 'vmess' && o.security != null && !VMESS_SECURITY[lc('' + o.security)]) o.security = 'auto';
	if (t == 'shadowsocks') {
		let method = lc('' + (o.method ?? ''));
		if (!SS_METHODS[method]) return 'unsupported_method';
		o.method = method;
		if (substr(method, 0, 5) == '2022-') {
			let need = (index(method, 'aes-128') >= 0) ? 16 : 32;
			for (let part in split('' + (o.password ?? ''), ':')) {
				let k = b64_any(part);
				if (!k || length(k) != need) return 'bad_key';
			}
		}
		if (length(o.plugin) && o.plugin != 'obfs-local' && o.plugin != 'v2ray-plugin') return 'unsupported_plugin';
	}
	if (t == 'hysteria2' && o.obfs != null &&
	    (type(o.obfs) != 'object' || (length(o.obfs.type) && o.obfs.type != 'salamander')))
		return 'unsupported_obfs';
	if (t == 'tuic') {
		if (o.congestion_control != null && !TUIC_CC[o.congestion_control]) delete o.congestion_control;
		if (o.udp_relay_mode != null && o.udp_relay_mode != 'native' && o.udp_relay_mode != 'quic') delete o.udp_relay_mode;
	}
	return null;
}

function process_json(data) {
	let obs = null;
	if (type(data) == 'array')
		obs = data;
	else if (type(data) == 'object') {
		if (type(data.outbounds) == 'array') obs = data.outbounds;
		else if (type(data.proxies) == 'array') obs = data.proxies;
	}
	if (obs == null) { rec({ line: 1, status: 'skip', reason: 'no_nodes' }); return; }
	let i = 0;
	for (let o in obs) {
		i++;
		if (type(o) != 'object' || !PROXY_TYPES[o.type]) {   // skip selector/urltest/direct/block/dns
			rec({ item: i, status: 'skip', reason: 'not_a_node' });
			continue;
		}
		let bad = check_json_node(o);
		if (bad) {
			rec({ item: i, status: 'skip', reason: bad, type: o.type });
			continue;
		}
		let r = add_node(o, null, null);
		r.item = i;
		rec(r);
	}
}

function parse_line(line) {
	let low = lc(substr(line, 0, 12));
	if (substr(low, 0, 8) == 'vless://')     return parse_vless(line);
	if (substr(low, 0, 9) == 'trojan://')    return parse_trojan(line);
	if (substr(low, 0, 8) == 'vmess://')     return parse_vmess(line);
	if (substr(low, 0, 5) == 'ss://')        return parse_ss(line);
	if (substr(low, 0, 12) == 'hysteria2://') return parse_hy2(line, 12);
	if (substr(low, 0, 6) == 'hy2://')       return parse_hy2(line, 6);
	if (substr(low, 0, 7) == 'tuic://')      return parse_tuic(line);
	if (match(line, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//)) return 'unknown_scheme';
	return 'not_a_link';
}

function process_text(raw) {
	raw = trim(raw ?? '');
	if (substr(raw, 0, 3) == '\xef\xbb\xbf') raw = trim(substr(raw, 3));   // UTF-8 BOM
	if (!length(raw)) return;

	if (looks_base64(raw)) {
		let dec = b64_any(raw);
		if (dec && (index(dec, '://') >= 0 || index(lc(dec), '[interface]') >= 0))
			raw = trim(dec);
	}

	// AmneziaWG / WireGuard .conf (one config per input text block; build.sh writes
	// each awg_node entry to its own file). Section names are case-insensitive.
	if (index(lc(raw), '[interface]') >= 0) {
		let ob = parse_awg_conf(raw);
		if (ob) {
			let r = add_node(ob, 'awg:' + ob.peers[0].public_key + '@' + ob.tag, null);
			r.line = 1;
			rec(r);
		} else
			rec({ line: 1, status: 'skip', reason: 'parse_error' });
		return;
	}

	// JSON — but text that only starts like JSON must not abort the run (json() throws):
	// fall back to the line parser, which skips what it does not understand.
	let c0 = substr(raw, 0, 1);
	if (c0 == '{' || c0 == '[') {
		let data = null;
		try { data = json(raw); } catch (e) { data = null; }
		if (data != null) {
			process_json(data);
			return;
		}
	}

	let ln = 0;
	for (let line in split(raw, /\r?\n/)) {
		ln++;
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#' || substr(line, 0, 2) == '//') continue;
		let ob = parse_line(line);
		if (type(ob) == 'string') {
			rec({ line: ln, status: 'skip', reason: ob });
			continue;
		}
		let r = add_node(ob, null, line);
		r.line = ln;
		rec(r);
	}
}

// ---- inputs: every ARGV entry is a file; if none, read stdin ----
let files = [];
for (let a in ARGV) {
	if (a == '--keep-link') KEEP_LINK = true;
	else if (a == '--with-id') WITH_ID = true;
	else if (a == '--report') REPORT = true;
	else push(files, a);
}
if (length(files)) {
	for (let f in files) {
		let raw = readfile(f);
		if (raw != null) process_text(raw);
		cur_src++;
	}
} else {
	process_text(stdin.read('all'));
}

printf("%.J\n", REPORT ? report : nodes);
