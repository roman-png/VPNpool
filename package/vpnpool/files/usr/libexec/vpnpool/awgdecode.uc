#!/usr/bin/ucode
// AmneziaVPN vpn:// decoder.
//
//   ucode awgdecode.uc [--json] [TEXT]     (TEXT, or stdin when absent)
//
// Input: arbitrary text holding one or more vpn:// links (a caption before the link, line
// wraps / spaces / CRLF inside the token, several links).
//
// --json  ONE JSON object on stdout, exit 0 if at least one link gave an item, else 1:
//   {ok:true,  items:[{kind:"awg"|"wireguard", conf, name, host, client?, container}
//                    |{kind:"link", link, name, host, container}], errors:[{code,found?}]?}
//   {ok:false, code:"E_*", found?:[container names]}
//   codes: E_NO_LINK E_BASE64 E_FORMAT E_INFLATE E_JSON E_API_KEY E_FULL_ACCESS
//          E_NO_SUPPORTED_CONTAINER (found = what the link has) E_NO_CONF
//   No human texts here — the UI maps the codes (po).
// default (legacy, what rpcd uses until the integration step): the first AWG/WireGuard .conf
//   on stdout, exit 1 (code on stderr) when there is none.
//
// Link format: vpn://<base64 or base64url, padded or not>( 4-byte BE length + zlib(JSON) )
// (Qt qCompress) — or the bare JSON (old exports: first byte '{'). The router has no zlib
// CLI (no openssl/python/gzip applet/ucode-mod-zlib), so DEFLATE (RFC1951) is inflated in
// pure ucode. Every loop in it consumes input and reading past the end is an error, so junk
// can't spin it; output is capped by the length prefix and checked against the adler32.
'use strict';

import { stdin } from 'fs';

const MAX_OUT = 4 * 1024 * 1024;

// ---- raw DEFLATE inflate. data = byte string, start offset; -> {out: byte ints, pos} | null
function inflate(data, start, maxout) {
	let dlen = length(data);
	let pos = start, bitbuf = 0, bitcnt = 0, overrun = false;
	let out = [];

	function getbit() {
		if (bitcnt == 0) {
			if (pos >= dlen) { overrun = true; return 0; }
			bitbuf = ord(data, pos++); bitcnt = 8;
		}
		let b = bitbuf & 1; bitbuf = bitbuf >> 1; bitcnt--; return b;
	}
	function getbits(n) {
		let v = 0;
		for (let i = 0; i < n; i++) v |= getbit() << i;
		return v;
	}
	// canonical Huffman: code lengths -> {len*100000+code -> symbol}
	function buildHuff(lengths) {
		let maxlen = 0;
		for (let i = 0; i < length(lengths); i++) if (lengths[i] > maxlen) maxlen = lengths[i];
		let blcount = []; for (let i = 0; i <= maxlen; i++) blcount[i] = 0;
		for (let i = 0; i < length(lengths); i++) if (lengths[i] > 0) blcount[lengths[i]]++;
		let nextcode = [], code = 0;
		for (let bits = 1; bits <= maxlen; bits++) { code = (code + blcount[bits - 1]) << 1; nextcode[bits] = code; }
		let map = {};
		for (let n = 0; n < length(lengths); n++) {
			let len = lengths[n];
			if (len > 0) { map[len * 100000 + nextcode[len]] = n; nextcode[len]++; }
		}
		return { map: map, maxlen: maxlen };
	}
	function decodeSym(h) {
		let code = 0, len = 0, sym;
		while (len < h.maxlen) {
			code = (code << 1) | getbit();
			len++;
			if (overrun) return -1;
			sym = h.map[len * 100000 + code];
			if (sym != null) return sym;
		}
		return -1;
	}

	let lenBase  = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
	let lenExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
	let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
	let distExtra= [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
	let clcOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];

	let bfinal = 0;
	while (!bfinal) {
		bfinal = getbit();
		let btype = getbits(2);
		if (overrun) return null;
		if (btype == 0) {
			bitcnt = 0;                                   // stored: align to the byte boundary
			if (pos + 4 > dlen) return null;
			let len = ord(data, pos) | (ord(data, pos + 1) << 8);
			let nlen = ord(data, pos + 2) | (ord(data, pos + 3) << 8);
			if ((len ^ 0xffff) != nlen) return null;
			pos += 4;
			if (pos + len > dlen || length(out) + len > maxout) return null;
			for (let i = 0; i < len; i++) push(out, ord(data, pos++));
			continue;
		}
		let litH, distH;
		if (btype == 1) {
			let ll = [];
			for (let i = 0; i <= 287; i++) ll[i] = (i < 144) ? 8 : (i < 256) ? 9 : (i < 280) ? 7 : 8;
			litH = buildHuff(ll);
			let dl = []; for (let i = 0; i < 30; i++) dl[i] = 5;
			distH = buildHuff(dl);
		} else if (btype == 2) {
			let hlit = getbits(5) + 257, hdist = getbits(5) + 1, hclen = getbits(4) + 4;
			if (hlit > 286 || hdist > 30) return null;
			let cl = []; for (let i = 0; i < 19; i++) cl[i] = 0;
			for (let i = 0; i < hclen; i++) cl[clcOrder[i]] = getbits(3);
			if (overrun) return null;
			let clH = buildHuff(cl);
			if (clH.maxlen == 0) return null;
			let lens = [], n = 0, total = hlit + hdist;
			while (n < total) {
				let sym = decodeSym(clH);
				if (sym < 0) return null;
				let r = 0, v = 0;
				if (sym < 16) { lens[n++] = sym; continue; }
				else if (sym == 16) { if (n == 0) return null; r = getbits(2) + 3; v = lens[n - 1]; }
				else if (sym == 17) { r = getbits(3) + 3; }
				else { r = getbits(7) + 11; }
				if (overrun || n + r > total) return null;
				for (let i = 0; i < r; i++) lens[n++] = v;
			}
			let litLens = [], distLens = [];
			for (let i = 0; i < hlit; i++) litLens[i] = lens[i] ?? 0;
			for (let i = 0; i < hdist; i++) distLens[i] = lens[hlit + i] ?? 0;
			if (!litLens[256]) return null;              // no end-of-block code: not a real stream
			litH = buildHuff(litLens);
			distH = buildHuff(distLens);
		} else {
			return null;                                 // reserved block type
		}
		while (true) {
			let sym = decodeSym(litH);
			if (sym < 0) return null;
			if (sym == 256) break;
			if (sym < 256) {
				if (length(out) >= maxout) return null;
				push(out, sym); continue;
			}
			let li = sym - 257;
			if (li >= length(lenBase)) return null;
			let len = lenBase[li] + getbits(lenExtra[li]);
			let dsym = decodeSym(distH);
			if (dsym < 0 || dsym >= length(distBase)) return null;
			let dist = distBase[dsym] + getbits(distExtra[dsym]);
			if (overrun) return null;
			let st = length(out) - dist;
			if (st < 0 || length(out) + len > maxout) return null;
			for (let i = 0; i < len; i++) push(out, out[st + i]);
		}
	}
	return { out: out, pos: pos };
}

function bytes_to_str(arr) {
	let parts = [], buf = [];
	for (let i = 0; i < length(arr); i++) {
		push(buf, arr[i]);
		if (length(buf) >= 1024) { push(parts, chr(...buf)); buf = []; }
	}
	if (length(buf)) push(parts, chr(...buf));
	return join('', parts);
}

function adler32(arr) {
	let a = 1, b = 0;
	for (let i = 0; i < length(arr); i++) { a = (a + arr[i]) % 65521; b = (b + a) % 65521; }
	return (b << 16) | a;
}

// ---- token -> JSON text | {code}
function b64_to_raw(tok) {
	tok = replace(tok, /=+$/, '');
	if (!length(tok) || match(tok, /[^A-Za-z0-9+\/_-]/)) return null;
	tok = replace(replace(tok, /-/g, '+'), /_/g, '/');
	if (length(tok) % 4 == 1) return null;
	while (length(tok) % 4) tok += '=';
	return b64dec(tok);
}

function payload_text(tok) {
	let raw = b64_to_raw(tok);
	if (raw == null || !length(raw)) return { code: 'E_BASE64' };
	if (substr(raw, 0, 1) == '{') return { text: raw };       // uncompressed JSON export
	let n = length(raw);
	if (n < 4 + 2 + 4) return { code: 'E_FORMAT' };
	let cmf = ord(raw, 4), flg = ord(raw, 5);
	// zlib header: CM=8 (deflate), window <= 32K (0x78 for the default), FCHECK, no FDICT
	if ((cmf & 0x0f) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0 || (flg & 0x20))
		return { code: 'E_FORMAT' };
	let want = (ord(raw, 0) << 24) | (ord(raw, 1) << 16) | (ord(raw, 2) << 8) | ord(raw, 3);
	if (want <= 0 || want > MAX_OUT) return { code: 'E_FORMAT' };
	let r = inflate(raw, 6, want);
	if (!r || length(r.out) != want || r.pos + 4 > n) return { code: 'E_INFLATE' };
	let p = r.pos;
	let ad = (ord(raw, p) << 24) | (ord(raw, p + 1) << 16) | (ord(raw, p + 2) << 8) | ord(raw, p + 3);
	if (ad != adler32(r.out)) return { code: 'E_INFLATE' };
	return { text: bytes_to_str(r.out) };
}

function parse_json(s) {
	let v = null;
	try { v = json(s); } catch (e) { v = null; }
	return v;
}

// ---- links in the text: every vpn://, token = base64 chars with whitespace in between,
// up to the next vpn:// . Returns a list of candidate token lists: [full, minus last word, ...]
// so a word glued on after a line break ("…AAAA\nthanks") still decodes.
function find_links(text) {
	let res = [];
	let starts = [];
	let i = 0;
	while (true) {
		let j = index(substr(text, i), 'vpn://');
		if (j < 0) break;
		push(starts, i + j);
		i = i + j + 6;
	}
	for (let k = 0; k < length(starts); k++) {
		let s = starts[k] + 6;
		let e = (k + 1 < length(starts)) ? starts[k + 1] : length(text);
		let seg = substr(text, s, e - s);
		let m = match(seg, /^[A-Za-z0-9+\/=_[:space:]-]*/);
		let body = m ? m[0] : '';
		let words = filter(split(body, /[[:space:]]+/), (w) => length(w) > 0);
		let cands = [];
		for (let n = length(words); n >= 1; n--)
			push(cands, join('', slice(words, 0, n)));
		push(res, cands);
	}
	return res;
}

// ---- containers
function proto_of(name) {
	if (type(name) != 'string') return null;
	let p = lc(name);
	if (substr(p, 0, 8) == 'amnezia-') p = substr(p, 8);
	p = replace(p, /[0-9]+$/, '');
	return (p == 'awg' || p == 'wireguard' || p == 'xray' || p == 'ssxray') ? p : null;
}

// protocol blocks of one container: [{proto, block}] — matched by the key INSIDE the
// container (awg / wireguard / xray / ssxray, or a named variant like amnezia-awg2)
function proto_blocks(c) {
	let out = [];
	if (type(c) != 'object') return out;
	for (let k in sort(keys(c))) {
		if (k == 'container' || type(c[k]) != 'object') continue;
		let p = proto_of(k);
		if (!p && c[k].last_config != null) p = proto_of(c.container);
		if (p) push(out, { proto: p, block: c[k] });
	}
	return out;
}

function last_config(block) {
	let lc0 = block.last_config;
	if (type(lc0) == 'string') return parse_json(lc0);
	return (type(lc0) == 'object') ? lc0 : null;
}

function conf_field(conf, key) {
	for (let line in split(conf, '\n')) {
		let m = match(line, regexp('^[ \t]*' + key + '[ \t]*=[ \t]*(.*)$', 'i'));
		if (m) return trim(m[1]);
	}
	return null;
}

function url_enc(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);
		if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126)
			out += chr(c);
		else
			out += sprintf('%%%02X', c);
	}
	return out;
}

function host_port(h, p) {
	return ((index(h, ':') >= 0) ? '[' + h + ']' : h) + ':' + p;
}

function first_outbound(cfg, proto) {
	if (type(cfg) != 'object' || type(cfg.outbounds) != 'array') return null;
	for (let ob in cfg.outbounds)
		if (type(ob) == 'object' && ob.protocol == proto) return ob;
	return null;
}

function vless_link(cfg, name) {
	let ob = first_outbound(cfg, 'vless');
	if (!ob) return null;
	let vn = ob.settings?.vnext?.[0];
	let u = vn?.users?.[0];
	if (!vn || !u || !length(vn.address) || !vn.port || !length(u.id)) return null;
	let ss = ob.streamSettings ?? {};
	let q = [];
	function add(k, v) { if (v != null && length('' + v)) push(q, k + '=' + url_enc('' + v)); }
	add('encryption', u.encryption ?? 'none');
	add('flow', u.flow);
	let net = ss.network ?? 'tcp';
	if (net == 'raw') net = 'tcp';
	add('type', net);
	let sec = ss.security ?? 'none';
	add('security', sec);
	if (sec == 'reality') {
		let r = ss.realitySettings ?? {};
		add('pbk', r.publicKey); add('sid', r.shortId); add('sni', r.serverName);
		add('fp', r.fingerprint); add('spx', r.spiderX);
	} else if (sec == 'tls') {
		let t = ss.tlsSettings ?? {};
		add('sni', t.serverName); add('fp', t.fingerprint);
		if (type(t.alpn) == 'array' && length(t.alpn)) add('alpn', join(',', t.alpn));
	}
	if (net == 'ws') {
		let w = ss.wsSettings ?? {};
		add('path', w.path); add('host', w.host ?? w.headers?.Host);
	} else if (net == 'grpc') {
		let g = ss.grpcSettings ?? {};
		add('serviceName', g.serviceName);
		if (g.multiMode) add('mode', 'multi');
	} else if (net == 'xhttp' || net == 'splithttp') {
		let x = ss.xhttpSettings ?? ss.splithttpSettings ?? {};
		add('path', x.path); add('host', x.host); add('mode', x.mode);
	} else if (net == 'httpupgrade') {
		let h = ss.httpupgradeSettings ?? {};
		add('path', h.path); add('host', h.host);
	}
	return {
		link: 'vless://' + url_enc(u.id) + '@' + host_port(vn.address, vn.port) + '?' + join('&', q) + '#' + url_enc(name),
		host: vn.address
	};
}

function ss_link(cfg, name) {
	let ob = first_outbound(cfg, 'shadowsocks');
	if (!ob) return null;
	let s = ob.settings?.servers?.[0];
	if (!s || !length(s.address) || !s.port || !length(s.method) || s.password == null) return null;
	return {
		link: 'ss://' + b64enc(s.method + ':' + s.password) + '@' + host_port(s.address, s.port) + '#' + url_enc(name),
		host: s.address
	};
}

function first_str(...a) {
	for (let v in a) if (type(v) == 'string' && length(v)) return v;
	return null;
}

// one protocol block -> item | null
function make_item(obj, cname, pb) {
	let lcfg = last_config(pb.block);
	if (type(lcfg) != 'object') return null;
	let base = first_str(obj.description, obj.name, obj.hostName, lcfg.hostName) ?? 'vpn';
	if (pb.proto == 'awg' || pb.proto == 'wireguard') {
		let conf = lcfg.config;
		if (type(conf) != 'string' || index(conf, '[Interface]') < 0 && !match(conf, /\[interface\]/i)) return null;
		conf = replace(conf, /\r\n/g, '\n');
		let host = null;
		let ep = conf_field(conf, 'Endpoint');
		if (ep) {
			let c = rindex(ep, ':');
			host = (c > 0) ? substr(ep, 0, c) : ep;
			host = replace(host, /^\[|\]$/g, '');
		}
		host = host ?? first_str(lcfg.hostName, obj.hostName);
		let addr = conf_field(conf, 'Address');
		let client = null;
		if (addr) client = replace(trim(split(addr, ',')[0]), /\/(32|128)$/, '');
		let item = {
			kind: pb.proto, conf: conf,
			name: client ? (base + ' (' + client + ')') : base,
			host: host, container: cname
		};
		if (client) item.client = client;
		return item;
	}
	let r = (pb.proto == 'xray') ? vless_link(lcfg, base) : ss_link(lcfg, base);
	if (!r) return null;
	return { kind: 'link', link: r.link, name: base, host: r.host, container: cname };
}

const PRIO = { awg: 0, wireguard: 1, xray: 2, ssxray: 3 };

// JSON object -> {items:[item]} | {code, found?}
function decode_object(obj) {
	if (type(obj) != 'object') return { code: 'E_JSON' };
	// Amnezia "premium"/API key: the client fetches a config from the API — nothing to import
	if (obj.api_key != null || obj.auth_data != null || obj.api_config != null)
		return { code: 'E_API_KEY' };
	// "full access" share: SSH credentials of the server itself — never stored
	if (obj.hostName != null && obj.userName != null && obj.password != null)
		return { code: 'E_FULL_ACCESS' };
	let cs = obj.containers;
	if (type(cs) == 'object') cs = values(cs);
	if (type(cs) != 'array') cs = [];
	if (!length(cs) && obj.config_version != null) return { code: 'E_API_KEY' };

	let found = [], cands = [];
	for (let idx = 0; idx < length(cs); idx++) {
		let c = cs[idx];
		if (type(c) != 'object') continue;
		let cname = (type(c.container) == 'string') ? c.container : ('#' + idx);
		push(found, cname);
		let isdef = (obj.defaultContainer != null && c.container == obj.defaultContainer);
		for (let pb in proto_blocks(c))
			push(cands, { rank: (isdef ? 0 : 10) + PRIO[pb.proto], idx: idx, cname: cname, pb: pb });
	}
	if (!length(cands)) return { code: 'E_NO_SUPPORTED_CONTAINER', found: found };
	cands = sort(cands, (a, b) => (a.rank - b.rank) || (a.idx - b.idx));
	for (let cd in cands) {
		let it = make_item(obj, cd.cname, cd.pb);
		if (it) return { items: [ it ] };
	}
	return { code: 'E_NO_CONF', found: found };
}

function decode_token_list(cands) {
	let first = null;
	for (let tok in cands) {
		let p = payload_text(tok);
		let r;
		if (p.code) r = p;
		else {
			let obj = parse_json(p.text);
			r = (type(obj) == 'object') ? decode_object(obj) : { code: 'E_JSON' };
		}
		// a decoded JSON object is final (its verdict stands); only a token that did not get
		// that far may be retried without the trailing word
		if (r.items || (r.code != 'E_BASE64' && r.code != 'E_FORMAT' && r.code != 'E_INFLATE' && r.code != 'E_JSON')) return r;
		first = first ?? r;
	}
	return first ?? { code: 'E_BASE64' };
}

// ---- main
let as_json = false, text = null;
for (let a in ARGV) {
	if (a == '--json') as_json = true;
	else if (text == null) text = a;
}
if (text == null) text = stdin.read('all') ?? '';

let links = find_links(text);
let items = [], errors = [], seen_item = {};
for (let cands in links) {
	let r = length(cands) ? decode_token_list(cands) : { code: 'E_BASE64' };
	if (r.items) {
		for (let it in r.items) {
			let key = it.conf ?? it.link;            // the same link pasted twice = one item
			if (seen_item[key]) continue;
			seen_item[key] = true;
			push(items, it);
		}
	}
	else push(errors, r);
}

if (as_json) {
	let res;
	if (length(items)) {
		res = { ok: true, items: items };
		if (length(errors)) res.errors = errors;
	} else if (!length(links)) {
		res = { ok: false, code: 'E_NO_LINK' };
	} else {
		res = { ok: false, code: errors[0].code };
		if (errors[0].found) res.found = errors[0].found;
		if (length(errors) > 1) res.errors = errors;
	}
	printf('%J\n', res);
	exit(res.ok ? 0 : 1);
}

// legacy: the first AWG/WireGuard .conf
for (let it in items) {
	// byte-for-byte what the old decoder printed: the conf, then '\n'
	if (it.conf) { print(it.conf); print('\n'); exit(0); }
}
warn('awgdecode: ' + (length(errors) ? errors[0].code : (length(links) ? 'E_NO_CONF' : 'E_NO_LINK')) + '\n');
exit(1);
