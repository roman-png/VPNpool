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
	if (length(p.flow)) ob.flow = p.flow;

	if (p.security == 'reality' || p.security == 'tls') {
		let tls = { enabled: true };
		if (length(p.sni)) tls.server_name = p.sni;
		if (length(p.fp)) tls.utls = { enabled: true, fingerprint: p.fp };
		if (p.security == 'reality') {
			tls.reality = { enabled: true };
			if (length(p.pbk)) tls.reality.public_key = p.pbk;
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

function looks_base64(s) {
	if (index(s, '://') >= 0) return false;
	let c = substr(s, 0, 1);
	if (c == '{' || c == '[') return false;
	return match(s, /^[A-Za-z0-9+\/=\s]+$/) ? true : false;
}

let PROXY_TYPES = {
	vless: 1, vmess: 1, trojan: 1, shadowsocks: 1, shadowtls: 1,
	hysteria: 1, hysteria2: 1, tuic: 1, wireguard: 1, ssh: 1
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
		// TODO: vmess://, ss:// (rare for this provider)
		if (ob) add_node(ob, line);
	}
}

// ---- inputs: every ARGV entry is a file; if none, read stdin ----
if (length(ARGV)) {
	for (let f in ARGV) {
		let raw = readfile(f);
		if (raw != null) process_text(raw);
	}
} else {
	process_text(stdin.read('all'));
}

printf("%.J\n", nodes);
