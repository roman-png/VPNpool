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
//   --with-id    attach the stable node identity `id` (key_id of the canonical config without the
//                name; AWG/WireGuard: awg_id). One id = one node in the output (the first input wins).
//                generator.uc strips it (sing-box rejects unknown outbound fields).
//   --with-src   attach `_src` = the index of the input file the node came from (build.sh: which
//                source a node belongs to; generator.uc strips every `_` field).
//   --hide FILE  ids (one per line) the user hid: such nodes are skipped (reason "hidden") in
//                every input, before the dedup.
//   --pick FILE  (before an input file) only the ids listed in FILE are taken from THAT file
//                (reason "not_picked" for the rest): a subscription in "pick" mode.
//   --report     instead of the node array print one record per input line / JSON item:
//                {src, line|item, status:"ok"|"skip", reason?, field?, tag?, type?, id?,
//                 dup_of?, tag_changed?, hints?, server?, port?}. reason is a machine code (no
//                human text — that lives in po):
//                not_a_link unknown_scheme parse_error bad_port bad_server bad_uuid
//                bad_reality_key bad_short_id unsupported_transport unsupported_security
//                unsupported_encryption unsupported_flow unsupported_method unsupported_plugin
//                unsupported_obfs bad_key tls_required duplicate not_a_node no_nodes
//                hidden not_picked (+ id, tag, server, port of the skipped node; duplicate + id)
//                AWG .conf (field = the .conf key): awg_no_peer awg_multi_peer awg_bad_value
//                awg_unsupported_param bad_key; hints: awg_random_trailers (the server must
//                run AmneziaWG 3.1 too). server/port: of an accepted AWG/WireGuard node;
//                ignored: wg-quick / amneziawg-tools keys skipped (Table, PostUp, AdvancedSecurity…);
//                awg31: the node uses AWG 3.1 fields (needs an engine that has them).
'use strict';

import { readfile, stdin } from 'fs';

let nodes = [];
let seen = {};       // node id (or, without one, the canonical config) -> tag of the node that owns it
let used_tags = {};
// Tags the generator itself defines (urltest "auto", selector "proxy", "direct"; "block" and
// "dns-out" are the conventional names of the other built-ins). A node may never take one:
// two outbounds with one tag make `sing-box check` reject the whole config.
// "vpnpool-test" is the selector of the test route (speedtest/unlock, ROADMAP 2.8).
let RESERVED_TAGS = { auto: 1, proxy: 1, direct: 1, block: 1, 'dns-out': 1, 'vpnpool-test': 1 };
let KEEP_LINK = false;
let WITH_ID = false;
let WITH_SRC = false;
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
	// [[:space:]] — \s inside [...] is the letter "s" in ucode: every id with an "s" was refused
	if (!length(uuid) || match(uuid, /[[:space:]:]/)) return 'bad_uuid';
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

// ---- AmneziaWG / WireGuard .conf (INI) -> sing-box endpoint (ROADMAP 4.3) ----
// The endpoint field names are those of OUR engine (vpnpool-engine: patches/sing-box/0001
// option/awg.go, 0003 protocol/awg genIpcConfig). .conf key (case-insensitive) -> field:
//   [Interface] PrivateKey -> private_key   Address -> address[]   MTU -> mtu
//               ListenPort -> listen_port   Jc/Jmin/Jmax -> jc/jmin/jmax (int)
//               S1..S4 -> s1..s4 (int)      H1..H4 -> h1..h4 ("n" or "lo-hi" string)
//               I1..I5 -> i1..i5 (tag chain string)
//               HeaderProtectionKey -> header_protection_key (base64, 32 bytes)
//               ContentPaddingAddition / RekeyAfterTime / RekeyTimeout / RejectAfterTime /
//               KeepaliveTimeout / MaxHandshakeAttempts -> content_padding_addition /
//               rekey_after_time / rekey_timeout / reject_after_time / keepalive_timeout /
//               max_handshake_attempts ("n" or "lo-hi" string)
//               RandomTrailers / DisableCookies -> random_trailers / disable_cookies (bool)
//               DNS, Table, FwMark, SaveConfig, Pre/PostUp/Down -> ignored (wg-quick only)
//   [Peer]      PublicKey -> public_key  PresharedKey -> preshared_key (awg) | pre_shared_key
//               (stock wireguard)  AllowedIPs -> allowed_ips[]  Endpoint -> address + port
//               PersistentKeepalive -> persistent_keepalive_interval (int; "lo-hi" string = AWG)
// A .conf without any AWG parameter becomes a STOCK "wireguard" endpoint (runs on the stock
// sing-box); with one it is an "awg" endpoint (needs the engine). Every value is checked HERE:
// `sing-box check` passes most bad AWG values and the engine only fails when it STARTS
// (measured on vpnpool-engine 1.14.3-awg.1: overlapping H ranges, unknown/unclosed I tags, an
// odd hex in <b>, a header key that is not 32 bytes, "100 - 120" with spaces, S1=70000, a
// reversed range) — one such node would take the whole tunnel down at start-up.
// Placeholders ($PRIMARY_DNS, ...) and empty values count as unset. A key the engine does not
// know is refused (awg_unsupported_param): dropping it silently gave a node that never
// handshakes (ROADMAP §1 — the 3.x keys were dropped exactly like that).
// Jc/Jmin/Jmax: Go `int` in the engine's options — 32 bits on mipsel/arm routers
const AWG_INT = { jc: [ 'jc', 2147483647 ], jmin: [ 'jmin', 2147483647 ], jmax: [ 'jmax', 2147483647 ],
	s1: [ 's1', 65535 ], s2: [ 's2', 65535 ], s3: [ 's3', 65535 ], s4: [ 's4', 65535 ] };
const AWG_RANGE = { h1: 'h1', h2: 'h2', h3: 'h3', h4: 'h4',
	contentpaddingaddition: 'content_padding_addition', rekeyaftertime: 'rekey_after_time',
	rekeytimeout: 'rekey_timeout', rejectaftertime: 'reject_after_time',
	keepalivetimeout: 'keepalive_timeout', maxhandshakeattempts: 'max_handshake_attempts' };
const AWG_CHAIN = { i1: 'i1', i2: 'i2', i3: 'i3', i4: 'i4', i5: 'i5' };
const AWG_BOOL = { randomtrailers: 'random_trailers', disablecookies: 'disable_cookies' };
const WG_IFACE = { privatekey: 1, address: 1, dns: 1, mtu: 1, listenport: 1, headerprotectionkey: 1 };
const WG_PEER = { publickey: 1, presharedkey: 1, allowedips: 1, endpoint: 1, persistentkeepalive: 1 };
// Known keys of wg-quick / awg-quick and amneziawg-tools (src/config.c) that mean nothing for a
// userspace client in sing-box (interface table, fwmark, hooks) or that the engine has no knob
// for (AdvancedSecurity: a kernel-module peer flag, absent from the amneziawg-go v3.1 uapi): the
// node is kept, the keys are named in the report (ignored:[...]). DNS is ignored silently.
const WG_IGNORED_I = { table: 1, fwmark: 1, saveconfig: 1, preup: 1, postup: 1, predown: 1, postdown: 1 };
const WG_IGNORED_P = { advancedsecurity: 1 };
// AWG 3.1-only fields: a build without them (the old awg2.1 fork) can't run such a node
const AWG31_FIELDS = [ 'header_protection_key', 'content_padding_addition', 'rekey_after_time', 'rekey_timeout',
	'reject_after_time', 'keepalive_timeout', 'max_handshake_attempts', 'random_trailers', 'disable_cookies' ];
// I-chain tags of amneziawg-go (device/obf.go obfBuilders) and whether they take a number /
// hex value / nothing
const OBF_TAGS = { b: 'hex', t: 'none', r: 'num', rc: 'num', rd: 'num', d: 'none', ds: 'none', dz: 'num' };
const AWG_TRAILERS_HINT = 'awg_random_trailers';   // RandomTrailers needs AWG 3.1 on the SERVER too

function awg_split_csv(s) {
	let out = [];
	for (let p in split(s, ',')) {
		p = trim(p);
		if (length(p)) push(out, p);
	}
	return out;
}

// base64 key (std or url-safe, padded or not) of exactly 32 bytes -> canonical padded std
// base64 (what the engine's base64.StdEncoding accepts), or null. Checked by FORM, not by
// b64dec: ucode's decoder refuses non-zero padding bits (".../AKE7=") that Go and coreutils
// accept, i.e. a key the engine takes. 32 bytes = 43 symbols + "=".
function wg_key(s) {
	if (type(s) != 'string') return null;
	s = replace(replace(trim(s), /-/g, '+'), /_/g, '/');
	if (length(s) == 43) s += '=';
	return match(s, /^[A-Za-z0-9+\/]{43}=$/) ? s : null;
}

// "n" / "lo-hi" (spaces around the dash allowed) -> canonical "n" / "lo-hi", or null.
// Mirrors UintRange.FromString (uint32, hi >= lo) — which itself does NOT trim spaces.
function urange(v, max) {
	let m = match(v, /^([0-9]{1,10})[ \t]*(-[ \t]*([0-9]{1,10}))?$/);
	if (!m) return null;
	let lo = int(m[1]), hi = (m[3] != null) ? int(m[3]) : lo;
	if (max == null) max = 4294967295;
	if (lo > max || hi > max || hi < lo) return null;
	return (hi == lo && m[3] == null) ? ('' + lo) : (lo + '-' + hi);
}
function urange_bounds(r) {
	let p = split(r, '-');
	return [ int(p[0]), int(p[length(p) - 1]) ];
}

// I1..I5 tag chain ("<b 0x...><r 2>..."), checked like newObfChain -> null if ok, else false
function obf_chain_ok(spec) {
	let rest = spec, ntags = 0;
	while (true) {
		let st = index(rest, '<');
		if (st < 0) break;
		let en = index(substr(rest, st), '>');
		if (en < 0) return false;                          // missing enclosing >
		let tag = trim(substr(rest, st + 1, en - 1));
		rest = substr(rest, st + en + 1);
		let f = split(tag, /[ \t]+/);
		if (!length(tag) || !length(f)) return false;      // empty tag
		let kind = OBF_TAGS[f[0]];
		if (!kind) return false;                           // unknown tag
		let val = (length(f) > 1) ? f[1] : '';
		if (kind == 'hex') {
			if (substr(val, 0, 2) == '0x') val = substr(val, 2);
			if (!length(val) || length(val) % 2 || !match(val, /^[0-9a-fA-F]+$/)) return false;
		} else if (kind == 'num') {
			if (!match(val, /^[0-9]{1,5}$/) || int(val) > 65535) return false;
		}
		ntags++;
	}
	return true;
}

// a CIDR (or a bare address: /32 or /128 added) -> canonical "addr/len", or null
function wg_prefix(s) {
	let m = match(s, /^([^\/]+)(\/([0-9]{1,3}))?$/);
	if (!m) return null;
	let a = m[1], v6 = index(a, ':') >= 0;
	if (v6) {
		if (!match(a, /^[0-9a-fA-F:.]+$/)) return null;
	} else {
		let o = match(a, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
		if (!o || int(o[1]) > 255 || int(o[2]) > 255 || int(o[3]) > 255 || int(o[4]) > 255) return null;
	}
	let len = (m[3] != null) ? int(m[3]) : (v6 ? 128 : 32);
	if (len > (v6 ? 128 : 32)) return null;
	return a + '/' + len;
}

function awg_bool(v) {
	let l = lc(v);
	if (l == '1' || l == 'true' || l == 'on' || l == 'yes' || l == 't') return true;
	if (l == '0' || l == 'false' || l == 'off' || l == 'no' || l == 'f') return false;
	return null;
}

// ---- SHA-256 (FIPS 180-4) in pure ucode: the AWG node id (no digest module on the router) ----
const SHA_K = [
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];
function sha256_hex(msg) {
	const M = 0xffffffff;
	let h = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ];
	let b = [];
	for (let i = 0; i < length(msg); i++) push(b, ord(msg, i));
	let bits = length(b) * 8;
	push(b, 0x80);
	while (length(b) % 64 != 56) push(b, 0);
	for (let i = 7; i >= 0; i--) push(b, (bits >> (i * 8)) & 0xff);
	let rotr = (x, n) => ((x >> n) | (x << (32 - n))) & M;
	let w = [];
	for (let off = 0; off < length(b); off += 64) {
		for (let t = 0; t < 16; t++)
			w[t] = (b[off + 4 * t] << 24) | (b[off + 4 * t + 1] << 16) | (b[off + 4 * t + 2] << 8) | b[off + 4 * t + 3];
		for (let t = 16; t < 64; t++) {
			let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
			let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
			w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & M;
		}
		let a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
		for (let t = 0; t < 64; t++) {
			let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
			let ch = (e & f) ^ ((~e) & g & M);
			let t1 = (hh + S1 + ch + SHA_K[t] + w[t]) & M;
			let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
			let mj = (a & bb) ^ (a & c) ^ (bb & c);
			let t2 = (S0 + mj) & M;
			hh = g; g = f; f = e; e = (d + t1) & M; d = c; c = bb; bb = a; a = (t1 + t2) & M;
		}
		h[0] = (h[0] + a) & M; h[1] = (h[1] + bb) & M; h[2] = (h[2] + c) & M; h[3] = (h[3] + d) & M;
		h[4] = (h[4] + e) & M; h[5] = (h[5] + f) & M; h[6] = (h[6] + g) & M; h[7] = (h[7] + hh) & M;
	}
	return join('', map(h, (x) => sprintf('%08x', x)));
}

// AWG / WireGuard node id (ROADMAP 2.2/4.4): first 12 hex of sha256 over the private key in its
// canonical base64 form — one key = one node (two clients of one server = two nodes; the same
// .conf pasted twice = one). The file is stored as /etc/vpnpool/awg/<id>.conf.
function awg_id(private_key) {
	let k = wg_key(private_key) ?? ('' + private_key);
	return substr(sha256_hex(k), 0, 12);
}

// parse_awg_conf(raw) -> { ob } | { err: reason, field? }
//   reasons: awg_no_peer awg_multi_peer bad_key bad_server bad_port awg_bad_value
//            awg_unsupported_param (field = the .conf key, lower case)
function parse_awg_conf(raw) {
	let iface = {}, peer = {}, sect = '', npeer = 0, name = null, unknown = null, ignored = [];
	for (let line in split(raw, /\r?\n/)) {
		line = trim(line);
		if (!length(line)) continue;
		let c0 = substr(line, 0, 1);
		if (c0 == '#' || c0 == ';') {
			// "# Name = <display name>" (written by vpnpool when it stores the node)
			let nm = match(line, /^[#;][ \t]*[Nn][Aa][Mm][Ee][ \t]*=[ \t]*(.*)$/);
			if (nm && name == null && length(trim(nm[1]))) name = trim(nm[1]);
			continue;
		}
		let low = lc(line);
		if (low == '[interface]') { sect = 'i'; continue; }
		if (low == '[peer]')      { sect = 'p'; npeer++; continue; }
		if (substr(line, 0, 1) == '[') { sect = 'x'; continue; }   // an unknown section
		let eq = index(line, '=');
		if (eq < 0) continue;
		let k = lc(trim(substr(line, 0, eq)));
		let v = trim(substr(line, eq + 1));
		// a comment at the end of the line ("Jc = 4 # note"), cut as amneziawg-tools does; no
		// value we read can hold '#' or ';' (keys are base64, I1-I5 tags are hex / numbers)
		let cm = -1;
		for (let ch in [ '#', ';' ]) { let ci = index(v, ch); if (ci >= 0 && (cm < 0 || ci < cm)) cm = ci; }
		if (cm >= 0) v = trim(substr(v, 0, cm));
		if (!length(v) || substr(v, 0, 1) == '$') continue;          // empty / placeholder
		if (sect == 'i') {
			if (WG_IGNORED_I[k]) { if (!(k in ignored)) push(ignored, k); continue; }
			if (!WG_IFACE[k] && !AWG_INT[k] && !AWG_RANGE[k] && !AWG_CHAIN[k] && !AWG_BOOL[k]) { if (unknown == null) unknown = k; }
			iface[k] = v;
		} else if (sect == 'p' && npeer == 1) {
			if (WG_IGNORED_P[k]) { if (!(k in ignored)) push(ignored, k); continue; }
			if (!WG_PEER[k]) { if (unknown == null) unknown = k; }
			peer[k] = v;
		}
	}
	if (npeer > 1) return { err: 'awg_multi_peer' };
	if (unknown) return { err: 'awg_unsupported_param', field: unknown };
	if (!npeer || !length(peer.publickey) || !length(peer.endpoint)) return { err: 'awg_no_peer' };

	let ep = {}, is_awg = false;
	let pk = wg_key(iface.privatekey);
	if (!pk) return { err: 'bad_key', field: 'privatekey' };
	ep.private_key = pk;
	if (length(iface.address)) {
		ep.address = [];
		for (let a in awg_split_csv(iface.address)) {
			let p = wg_prefix(a);
			if (!p) return { err: 'awg_bad_value', field: 'address' };
			push(ep.address, p);
		}
	}
	if (!length(ep.address)) return { err: 'awg_bad_value', field: 'address' };
	if (length(iface.mtu)) {
		if (!match(iface.mtu, /^[0-9]{1,5}$/) || int(iface.mtu) < 576 || int(iface.mtu) > 65535)
			return { err: 'awg_bad_value', field: 'mtu' };
		ep.mtu = int(iface.mtu);
	}
	if (length(iface.listenport)) {
		if (vport(iface.listenport) == null) return { err: 'awg_bad_value', field: 'listenport' };
		ep.listen_port = vport(iface.listenport);
	}
	for (let k, d in AWG_INT) {
		if (!length(iface[k])) continue;
		if (!match(iface[k], /^[0-9]{1,10}$/) || int(iface[k]) > d[1]) return { err: 'awg_bad_value', field: k };
		ep[d[0]] = int(iface[k]);
		is_awg = true;
	}
	if ((ep.jmin ?? 0) > (ep.jmax ?? 0)) return { err: 'awg_bad_value', field: 'jmin' };   // junk size underflows
	for (let k, f in AWG_RANGE) {
		if (!length(iface[k])) continue;
		let r = urange(iface[k]);
		if (r == null) return { err: 'awg_bad_value', field: k };
		ep[f] = r;
		is_awg = true;
	}
	// H1..H4 must not overlap (the unset ones keep the WireGuard types 1..4)
	let hs = [];
	for (let i = 1; i <= 4; i++) push(hs, urange_bounds(ep['h' + i] ?? ('' + i)));
	for (let i = 0; i < 4; i++)
		for (let j = i + 1; j < 4; j++)
			if (hs[i][0] <= hs[j][1] && hs[j][0] <= hs[i][1]) return { err: 'awg_bad_value', field: 'h' + (j + 1) };
	for (let k, f in AWG_CHAIN) {
		if (!length(iface[k])) continue;
		if (!obf_chain_ok(iface[k])) return { err: 'awg_bad_value', field: k };
		if (index(iface[k], '<') >= 0) ep[f] = iface[k];   // no tag at all = no chain (engine: nil)
		is_awg = true;
	}
	for (let k, f in AWG_BOOL) {
		if (!length(iface[k])) continue;
		let bv = awg_bool(iface[k]);
		if (bv == null) return { err: 'awg_bad_value', field: k };
		if (bv) ep[f] = true;
		is_awg = true;
	}
	if (length(iface.headerprotectionkey)) {
		let hk = wg_key(iface.headerprotectionkey);
		if (!hk) return { err: 'bad_key', field: 'headerprotectionkey' };
		// the engine (and amneziawg-go) need S1..S4 >= 12 (the header nonce) with a header key
		for (let i = 1; i <= 4; i++)
			if ((ep['s' + i] ?? 0) < 12) return { err: 'awg_bad_value', field: 's' + i };
		ep.header_protection_key = hk;
		is_awg = true;
	}

	let hp = split_hostport(peer.endpoint);
	if (!hp || bad_host(hp.host)) return { err: 'bad_server' };
	let port = vport(hp.port);
	if (port == null) return { err: 'bad_port' };
	let pub = wg_key(peer.publickey);
	if (!pub) return { err: 'bad_key', field: 'publickey' };
	let pr = { address: hp.host, port: port, public_key: pub };
	let psk = null;
	if (length(peer.presharedkey)) {
		psk = wg_key(peer.presharedkey);
		if (!psk) return { err: 'bad_key', field: 'presharedkey' };
	}
	pr.allowed_ips = [];
	for (let a in awg_split_csv(peer.allowedips ?? '0.0.0.0/0, ::/0')) {
		let p = wg_prefix(a);
		if (!p) return { err: 'awg_bad_value', field: 'allowedips' };
		push(pr.allowed_ips, p);
	}
	let ka = null;
	if (length(peer.persistentkeepalive) && lc(peer.persistentkeepalive) != 'off') {
		ka = urange(peer.persistentkeepalive, 65535);
		if (ka == null) return { err: 'awg_bad_value', field: 'persistentkeepalive' };
		if (index(ka, '-') >= 0) is_awg = true;            // a keepalive range is AWG 3.x
	}

	ep.type = is_awg ? 'awg' : 'wireguard';
	if (psk) pr[is_awg ? 'preshared_key' : 'pre_shared_key'] = psk;
	if (ka != null && ka != '0')
		pr.persistent_keepalive_interval = (index(ka, '-') >= 0) ? ka : int(ka);
	// MTU: explicit wins; else 1280 for AWG with S3/S4 (they pad every packet, so a too-high MTU
	// lets the handshake pass but stalls data with "message too long")
	if (ep.mtu == null && (ep.s3 != null || ep.s4 != null)) ep.mtu = 1280;
	ep.peers = [ pr ];
	ep.tag = name ?? hp_label(hp.host, port);
	let res = { ob: ep };
	if (ep.random_trailers) res.hints = [ AWG_TRAILERS_HINT ];
	if (length(ignored)) res.ignored = ignored;
	if (ep.type == 'awg') {
		let n31 = (type(pr.persistent_keepalive_interval) == 'string');
		for (let f in AWG31_FIELDS) if (ep[f] != null) n31 = true;
		if (n31) res.awg31 = true;
	}
	return res;
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
// differently gets one id. AWG/WireGuard nodes: awg_id (sha256 of the private key).
// The id is THE key of every store (preferred, favourites, hidden, dead marks, auto-pool members,
// test results; ROADMAP 2.2) and it is unique in the output: one config = one node (add_node).
function fnv1a(s, h) {
	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 16777619) & 0xffffffff;
	return h;
}

function key_id(key) {
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

// the node's whole config WITHOUT its name (key order irrelevant): the input of its id. The same
// config under another name is ONE node (ROADMAP 2.2): the first input wins, and build.sh passes
// the user's own nodes first (manual links, AWG files, favourites), so a user's copy of a
// subscription node keeps the user's name.
function config_key(ob) {
	return canon(bare(ob));
}

// Per-input filters (build.sh): HIDE = ids the user hid (every input); PICK = for ONE input file,
// the ids taken from it (a subscription in "pick" mode). Both act BEFORE the dedup, so a hidden /
// not-picked node never shadows the same node of another input.
let HIDE = null, PICK = null;

// -> report fields { status, tag?, type?, id?, reason?, dup_of?, tag_changed? }
function add_node(ob, link) {
	if (!ob || type(ob) != 'object') return { status: 'skip', reason: 'parse_error' };
	let is_awg = (ob.type == 'awg' || ob.type == 'wireguard');
	let base = length(ob.tag) ? trim('' + ob.tag) : ((ob.server ?? 'node') + ':' + (ob.server_port ?? 0));
	if (!length(base)) base = 'node';
	// the id: AWG/WireGuard = its private key, any other node = its canonical config without the name
	let id = null;
	if (is_awg) { if (length(ob.private_key)) id = awg_id(ob.private_key); }
	else id = key_id(config_key(ob));
	// a node without an id (an AWG endpoint of a JSON source without a key) can't be picked
	let hidden = !!(id && HIDE && HIDE[id]);
	if (hidden || (PICK && (!id || !PICK[id]))) {
		let p0 = (type(ob.peers) == 'array') ? ob.peers[0] : null;
		return { status: 'skip', reason: hidden ? 'hidden' : 'not_picked', type: ob.type,
			id: id, tag: base, server: ob.server ?? p0?.address, port: ob.server_port ?? p0?.port };
	}
	// one id = one node: the dedup is by the id (the output never repeats one); an AWG endpoint
	// of a JSON source without a private key has no id and dedups by its canonical config
	let dk = id ?? ('noid:' + config_key(ob));
	if (seen[dk] != null) {
		let r = { status: 'skip', reason: 'duplicate', type: ob.type, dup_of: seen[dk] };
		if (id) r.id = id;
		return r;
	}
	ob.tag = unique_tag(base);
	seen[dk] = ob.tag;
	if (WITH_ID && id) ob.id = id;
	if (WITH_SRC) ob._src = cur_src;
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
	// [[:space:]], not \s: inside [...] ucode (POSIX ERE) reads \s as the letter "s", so a
	// base64 blob wrapped over several lines was not recognised as base64 at all
	return match(s, /^[A-Za-z0-9+\/=_[:space:]-]+$/) ? true : false;
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
	// AWG/WG endpoints of a JSON source are taken verbatim (they carry no .conf to check);
	// `sing-box check` prunes what it rejects and the start guard (vpnpoold) what fails at start
	if (t == 'wireguard' || t == 'awg') return null;
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
		let r = add_node(o, null);
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
		let pa = parse_awg_conf(raw);
		if (pa.ob) {
			// one private key = one node: the same .conf twice is a duplicate, two clients of
			// one server are two nodes
			let r = add_node(pa.ob, null);
			r.line = 1;
			if (pa.hints) r.hints = pa.hints;
			if (pa.ignored) r.ignored = pa.ignored;
			if (pa.awg31) r.awg31 = true;
			if (r.status == 'ok') { r.server = pa.ob.peers[0].address; r.port = pa.ob.peers[0].port; }
			rec(r);
		} else {
			let r = { line: 1, status: 'skip', reason: pa.err };
			if (pa.field) r.field = pa.field;
			rec(r);
		}
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
		let r = add_node(ob, line);
		r.line = ln;
		rec(r);
	}
}

// ---- inputs: every ARGV entry is a file; if none, read stdin ----
// an id list file -> { id: true } (one id per line; blank lines ignored)
function id_set(path) {
	let set = {};
	for (let l in split(readfile(path) ?? '', /\r?\n/)) { l = trim(l); if (length(l)) set[l] = true; }
	return set;
}
let files = [], next_pick = null;
for (let i = 0; i < length(ARGV); i++) {
	let a = ARGV[i];
	if (a == '--keep-link') KEEP_LINK = true;
	else if (a == '--with-id') WITH_ID = true;
	else if (a == '--with-src') WITH_SRC = true;
	else if (a == '--report') REPORT = true;
	else if (a == '--hide') HIDE = id_set(ARGV[++i]);
	else if (a == '--pick') next_pick = id_set(ARGV[++i]);
	else { push(files, { path: a, pick: next_pick }); next_pick = null; }
}
if (length(files)) {
	for (let f in files) {
		PICK = f.pick;
		let raw = readfile(f.path);
		if (raw != null) process_text(raw);
		cur_src++;
	}
	PICK = null;
} else {
	process_text(stdin.read('all'));
}

printf("%.J\n", REPORT ? report : nodes);
