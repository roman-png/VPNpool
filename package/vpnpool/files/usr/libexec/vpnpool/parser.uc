#!/usr/bin/ucode
// vpnpool subscription/link parser.
// Input : one or more files (ARGV) and/or stdin. Each input may be:
//           - base64 blob of a link list,
//           - a plaintext list of vless:// (vmess/ss best-effort) links,
//           - a sing-box JSON config ({outbounds:[...]}) or a bare outbounds array.
// Output: JSON array of sing-box outbound objects (proxy nodes), on stdout.
//         Global dedup + unique tags across ALL inputs (so multi-source/multi-UA
//         results merge cleanly).
'use strict';

import { readfile, stdin } from 'fs';

let nodes = [];
let seen = {};
let tagcount = {};
// When true (CLI flag --keep-link), attach the original link as `_link` to each
// node parsed from a link line. Used by probe.sh so the UI can store the exact
// links the user picks. The live build does NOT pass the flag, so the config-bound
// nodes.json never carries `_link` (it would leak into sing-box outbounds).
let KEEP_LINK = false;

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

function add_node(ob, dedupkey) {
	if (!ob || type(ob) != 'object') return;
	if (dedupkey != null) {
		if (seen[dedupkey]) return;
		seen[dedupkey] = true;
	}
	let base = length(ob.tag) ? ob.tag : ((ob.server ?? 'node') + ':' + (ob.server_port ?? 0));
	if (tagcount[base]) {
		tagcount[base] += 1;
		ob.tag = base + ' #' + tagcount[base];
	} else {
		tagcount[base] = 1;
		ob.tag = base;
	}
	if (KEEP_LINK && type(dedupkey) == 'string' && index(dedupkey, '://') >= 0)
		ob._link = dedupkey;
	push(nodes, ob);
}

function parse_vless(line) {
	let m = match(line, /^vless:\/\/([^@]+)@([^:\/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
	if (!m) return null;

	let p = parse_query(m[4] ? substr(m[4], 1) : '');
	let name = m[5] ? url_decode(substr(m[5], 1)) : '';
	let ob = {
		type: 'vless',
		tag: length(name) ? name : (m[2] + ':' + m[3]),
		server: m[2],
		server_port: int(m[3]),
		uuid: m[1]
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
			return null;
	}

	if (p.security == 'reality' || p.security == 'tls') {
		let tls = { enabled: true };
		if (length(p.sni)) tls.server_name = p.sni;
		if (length(p.fp))
			tls.utls = { enabled: true, fingerprint: p.fp };
		else if (p.security == 'reality')
			tls.utls = { enabled: true, fingerprint: 'chrome' };   // reality REQUIRES uTLS in sing-box
		if (p.security == 'reality') {
			tls.reality = { enabled: true };
			// reality needs a valid x25519 pubkey (32 bytes -> 43/44 base64 chars);
			// junk lists carry malformed keys that stall probe pruning — drop here.
			if (!length(p.pbk) || !match(p.pbk, /^[A-Za-z0-9_\/+-]{43,44}={0,1}$/))
				return null;
			tls.reality.public_key = p.pbk;
			if (p.sid != null) tls.reality.short_id = p.sid;
		}
		ob.tls = tls;
	}
	let t = p.type;
	if (t == 'ws') {
		ob.transport = { type: 'ws' };
		if (length(p.path)) ob.transport.path = p.path;
		if (length(p.host)) ob.transport.headers = { Host: p.host };
	} else if (t == 'grpc') {
		ob.transport = { type: 'grpc' };
		if (length(p.serviceName)) ob.transport.service_name = p.serviceName;
	}
	return ob;
}

function parse_trojan(line) {
	let m = match(line, /^trojan:\/\/([^@]+)@([^:\/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let p = parse_query(m[4] ? substr(m[4], 1) : '');
	let name = m[5] ? url_decode(substr(m[5], 1)) : '';
	let ob = {
		type: 'trojan', tag: length(name) ? name : (m[2] + ':' + m[3]),
		server: m[2], server_port: int(m[3]), password: m[1]
	};
	let tls = { enabled: true };
	if (length(p.sni)) tls.server_name = p.sni;
	if (length(p.fp)) tls.utls = { enabled: true, fingerprint: p.fp };
	ob.tls = tls;
	if (p.type == 'ws') {
		ob.transport = { type: 'ws' };
		if (length(p.path)) ob.transport.path = p.path;
		if (length(p.host)) ob.transport.headers = { Host: p.host };
	} else if (p.type == 'grpc') {
		ob.transport = { type: 'grpc' };
		if (length(p.serviceName)) ob.transport.service_name = p.serviceName;
	}
	return ob;
}

function parse_vmess(line) {
	let dec = b64dec(substr(line, 8));
	if (!dec) return null;
	let v = json(dec);
	if (type(v) != 'object') return null;
	let ob = {
		type: 'vmess',
		tag: length(v.ps) ? v.ps : ((v.add ?? '') + ':' + (v.port ?? '')),
		server: v.add, server_port: int(v.port),
		uuid: v.id, alter_id: int(v.aid ?? 0),
		security: length(v.scy) ? v.scy : 'auto'
	};
	if (v.tls == 'tls') {
		ob.tls = { enabled: true };
		let sni = length(v.sni) ? v.sni : v.host;
		if (length(sni)) ob.tls.server_name = sni;
	}
	if (v.net == 'ws') {
		ob.transport = { type: 'ws' };
		if (length(v.path)) ob.transport.path = v.path;
		if (length(v.host)) ob.transport.headers = { Host: v.host };
	} else if (v.net == 'grpc') {
		ob.transport = { type: 'grpc' };
		if (length(v.path)) ob.transport.service_name = v.path;
	}
	return ob;
}

function parse_ss(line) {
	// ss://base64(method:password)@host:port#name  OR  ss://base64(method:password@host:port)#name
	let rest = substr(line, 5);
	let name = '';
	let h = index(rest, '#');
	if (h >= 0) { name = url_decode(substr(rest, h + 1)); rest = substr(rest, 0, h); }
	let q = index(rest, '?');
	if (q >= 0) rest = substr(rest, 0, q);

	let method, password, server, port;
	let at = index(rest, '@');
	if (at >= 0) {
		let dec = b64dec(substr(rest, 0, at)) || substr(rest, 0, at);
		let hp = substr(rest, at + 1);
		let c = index(dec, ':'); if (c < 0) return null;
		method = substr(dec, 0, c); password = substr(dec, c + 1);
		let cc = rindex(hp, ':'); if (cc < 0) return null;
		server = substr(hp, 0, cc); port = int(substr(hp, cc + 1));
	} else {
		let dec = b64dec(rest);
		if (!dec) return null;
		let at2 = index(dec, '@'); if (at2 < 0) return null;
		let mp = substr(dec, 0, at2), hp = substr(dec, at2 + 1);
		let c = index(mp, ':'); method = substr(mp, 0, c); password = substr(mp, c + 1);
		let cc = rindex(hp, ':'); server = substr(hp, 0, cc); port = int(substr(hp, cc + 1));
	}
	if (!length(server) || !port) return null;
	return {
		type: 'shadowsocks', tag: length(name) ? name : (server + ':' + port),
		server: server, server_port: port, method: method, password: password
	};
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

function looks_base64(s) {
	if (index(s, '://') >= 0) return false;
	let c = substr(s, 0, 1);
	if (c == '{' || c == '[') return false;
	return match(s, /^[A-Za-z0-9+\/=\s]+$/) ? true : false;
}

let PROXY_TYPES = {
	vless: 1, vmess: 1, trojan: 1, shadowsocks: 1, shadowtls: 1,
	hysteria: 1, hysteria2: 1, tuic: 1, wireguard: 1, awg: 1, ssh: 1
};

function process_json(raw) {
	let data = json(raw);
	if (data == null) return;
	let obs = [];
	if (type(data) == 'array')
		obs = data;
	else if (type(data) == 'object') {
		if (type(data.outbounds) == 'array') obs = data.outbounds;
		else if (type(data.proxies) == 'array') obs = data.proxies;
	}
	for (let o in obs) {
		if (type(o) != 'object') continue;
		if (!PROXY_TYPES[o.type]) continue;   // skip selector/urltest/direct/block/dns
		add_node(o, (o.server ?? '') + ':' + (o.server_port ?? '') + ':' + (o.uuid ?? o.password ?? o.tag ?? ''));
	}
}

function process_text(raw) {
	raw = trim(raw ?? '');
	if (!length(raw)) return;

	if (looks_base64(raw)) {
		let dec = b64dec(replace(raw, /\s/g, ''));
		if (dec) raw = trim(dec);
	}

	// AmneziaWG / WireGuard .conf (one config per input text block; build.sh writes
	// each awg_node entry to its own file).
	if (index(raw, '[Interface]') >= 0 || index(raw, '[interface]') >= 0) {
		let ob = parse_awg_conf(raw);
		if (ob) add_node(ob, 'awg:' + ob.peers[0].public_key + '@' + ob.tag);
		return;
	}

	let c0 = substr(raw, 0, 1);
	if (c0 == '{' || c0 == '[') {
		process_json(raw);
		return;
	}

	for (let line in split(raw, /\r?\n/)) {
		line = trim(line);
		if (!length(line)) continue;
		let ob = null;
		if (substr(line, 0, 8) == 'vless://')
			ob = parse_vless(line);
		else if (substr(line, 0, 9) == 'trojan://')
			ob = parse_trojan(line);
		else if (substr(line, 0, 8) == 'vmess://')
			ob = parse_vmess(line);
		else if (substr(line, 0, 5) == 'ss://')
			ob = parse_ss(line);
		if (ob) add_node(ob, line);
	}
}

// ---- inputs: every ARGV entry is a file; if none, read stdin ----
// Optional leading flag `--keep-link` makes link nodes carry their original link.
let files = ARGV;
if (length(files) && files[0] == '--keep-link') {
	KEEP_LINK = true;
	files = slice(files, 1);
}
if (length(files)) {
	for (let f in files) {
		let raw = readfile(f);
		if (raw != null) process_text(raw);
	}
} else {
	process_text(stdin.read('all'));
}

printf("%.J\n", nodes);
