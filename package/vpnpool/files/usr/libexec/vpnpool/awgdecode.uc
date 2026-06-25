#!/usr/bin/ucode
// AmneziaVPN vpn:// decoder. Input: a vpn:// link (ARGV[0] or stdin). Output: the embedded
// AmneziaWG .conf text on stdout (empty + exit 1 on failure).
//
// vpn://<base64url( 4-byte BE length + zlib(JSON) )>. The router has no zlib tool (no
// openssl/python/gzip-applet/ucode-mod-zlib — only libz.so without a CLI), so we inflate
// the raw DEFLATE stream in pure ucode (RFC1951). Payload is ~1 KB, so the naive decoder
// is plenty fast. ponytail: hand-rolled inflate, the ONLY dependency-free option here.
'use strict';

import { stdin } from 'fs';

// ---- raw DEFLATE inflate (RFC1951). data = array of byte ints -> array of byte ints ----
function inflate(data) {
	let pos = 0, bitbuf = 0, bitcnt = 0;
	let out = [];

	function getbit() {
		if (bitcnt == 0) { bitbuf = data[pos++] ?? 0; bitcnt = 8; }
		let b = bitbuf & 1; bitbuf = bitbuf >> 1; bitcnt--; return b;
	}
	function getbits(n) {
		let v = 0;
		for (let i = 0; i < n; i++) v |= getbit() << i;
		return v;
	}
	// canonical Huffman: from code lengths build a {len*100000+code -> symbol} map.
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
		while (len <= h.maxlen) {
			code = (code << 1) | getbit();
			len++;
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
		if (btype == 0) {
			// stored: align to byte boundary
			bitcnt = 0;
			let len = (data[pos] ?? 0) | ((data[pos + 1] ?? 0) << 8); pos += 4; // skip LEN + NLEN
			for (let i = 0; i < len; i++) push(out, data[pos++] ?? 0);
			continue;
		}
		let litH, distH;
		if (btype == 1) {
			// fixed Huffman
			let ll = [];
			for (let i = 0; i <= 287; i++) ll[i] = (i < 144) ? 8 : (i < 256) ? 9 : (i < 280) ? 7 : 8;
			litH = buildHuff(ll);
			let dl = []; for (let i = 0; i < 30; i++) dl[i] = 5;
			distH = buildHuff(dl);
		} else if (btype == 2) {
			// dynamic Huffman
			let hlit = getbits(5) + 257, hdist = getbits(5) + 1, hclen = getbits(4) + 4;
			let cl = []; for (let i = 0; i < 19; i++) cl[i] = 0;
			for (let i = 0; i < hclen; i++) cl[clcOrder[i]] = getbits(3);
			let clH = buildHuff(cl);
			let lens = [], n = 0, total = hlit + hdist;
			while (n < total) {
				let sym = decodeSym(clH);
				if (sym < 0) return null;
				if (sym < 16) { lens[n++] = sym; }
				else if (sym == 16) { let r = getbits(2) + 3, prev = lens[n - 1]; for (let i = 0; i < r; i++) lens[n++] = prev; }
				else if (sym == 17) { let r = getbits(3) + 3;  for (let i = 0; i < r; i++) lens[n++] = 0; }
				else { let r = getbits(7) + 11; for (let i = 0; i < r; i++) lens[n++] = 0; }
			}
			let litLens = [], distLens = [];
			for (let i = 0; i < hlit; i++) litLens[i] = lens[i] ?? 0;
			for (let i = 0; i < hdist; i++) distLens[i] = lens[hlit + i] ?? 0;
			litH = buildHuff(litLens);
			distH = buildHuff(distLens);
		} else {
			return null; // reserved
		}
		// decode the block
		while (true) {
			let sym = decodeSym(litH);
			if (sym < 0) return null;
			if (sym == 256) break;
			if (sym < 256) { push(out, sym); continue; }
			let li = sym - 257;
			if (li >= length(lenBase)) return null;
			let len = lenBase[li] + getbits(lenExtra[li]);
			let dsym = decodeSym(distH);
			if (dsym < 0 || dsym >= length(distBase)) return null;
			let dist = distBase[dsym] + getbits(distExtra[dsym]);
			let start = length(out) - dist;
			if (start < 0) return null;
			for (let i = 0; i < len; i++) push(out, out[start + i]);
		}
	}
	return out;
}

function bytes_to_str(arr) {
	// build in chunks to avoid a huge chr() arg list
	let parts = [], buf = [];
	for (let i = 0; i < length(arr); i++) {
		push(buf, arr[i]);
		if (length(buf) >= 1024) { push(parts, chr(...buf)); buf = []; }
	}
	if (length(buf)) push(parts, chr(...buf));
	return join('', parts);
}

// ---- vpn:// -> .conf ----
let link = length(ARGV) ? ARGV[0] : stdin.read('all');
link = trim(link ?? '');
let tok = link;
if (substr(tok, 0, 6) == 'vpn://') tok = substr(tok, 6);
tok = replace(tok, /-/g, '+');
tok = replace(tok, /_/g, '/');
while (length(tok) % 4) tok += '=';

let raw = b64dec(tok);
if (!raw || length(raw) < 8) { warn('awgdecode: bad base64\n'); exit(1); }

// qCompress: 4-byte BE length prefix, then a zlib stream (2-byte header + raw DEFLATE +
// adler32). Skip the 4 length bytes + 2 zlib header bytes -> raw DEFLATE at offset 6.
let data = [];
for (let i = 6; i < length(raw); i++) push(data, ord(substr(raw, i, 1)));

let outbytes = inflate(data);
if (!outbytes) { warn('awgdecode: inflate failed\n'); exit(1); }

let txt = bytes_to_str(outbytes);
let obj = json(txt);
let conf = null;
if (type(obj) == 'object' && type(obj.containers) == 'array' && length(obj.containers)) {
	let awg = obj.containers[0].awg;
	if (type(awg) == 'object') {
		let lc = (type(awg.last_config) == 'string') ? json(awg.last_config) : awg.last_config;
		if (type(lc) == 'object' && length(lc.config)) conf = lc.config;
	}
}
if (!conf) { warn('awgdecode: no AmneziaWG config in link\n'); exit(1); }
print(conf);
print('\n');
