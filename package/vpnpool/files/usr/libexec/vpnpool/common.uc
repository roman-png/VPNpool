// vpnpool shared ucode helpers (imported by status.uc and api.uc: `import ... from './common.uc'`).
// Pure functions + small file helpers; no process is spawned here.
'use strict';

import { readfile, stat, open, rename, unlink } from 'fs';

// Community rule-set names (itdoginfo/allow-domains SRS assets). The ONE list: generator.uc
// builds the rule-sets from it, the settings validator (api.uc) refuses anything else.
const VALID_COMMUNITY = {
	russia_inside: 1, russia_outside: 1, geoblock: 1, block: 1,
	porn: 1, news: 1, anime: 1, youtube: 1, hdrezka: 1, tiktok: 1, google_ai: 1,
	google_play: 1, google_meet: 1, hodca: 1, discord: 1, meta: 1, twitter: 1,
	cloudflare: 1, cloudfront: 1, digitalocean: 1, hetzner: 1, ovh: 1, telegram: 1, roblox: 1
};

// JSON file -> value, or `def` when missing / unparsable.
function read_json(path, def) {
	let raw = readfile(path);
	if (raw == null || !length(trim(raw))) return def;
	let v = null;
	try { v = json(raw); } catch (e) { v = null; }
	return (v == null) ? def : v;
}

// Atomic write (temp file in the same directory + rename) — readers never see half a file.
function write_atomic(path, data) {
	let t = path + '.tmp.' + time();
	let f = open(t, 'w');
	if (!f) return false;
	f.write(data);
	f.close();
	if (rename(t, path)) return true;
	unlink(t);
	return false;
}

// "mtime:size" of a file ('-' when absent): cache key of a derived value.
function file_sig(path) {
	let s = stat(path);
	return s ? (s.mtime + ':' + s.size) : '-';
}

// Subscription URLs carry the access token: show scheme://host/*** only (same rule as
// lib.sh mask_url). Anything that is not a URL is hidden completely.
function mask_url(u) {
	if (type(u) != 'string' || !length(u)) return '';
	let m = match(u, /^([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^@\/?#]*@)?([^\/?#]*)/);
	return m ? (m[1] + m[3] + '/***') : '***';
}

// Telegram bot token "<bot id>:<secret>" -> "<bot id>:***" (the id is public, the secret is not).
function mask_token(t) {
	if (type(t) != 'string' || !length(t)) return '';
	let i = index(t, ':');
	return (i > 0) ? (substr(t, 0, i) + ':***') : '***';
}

// Stable short key of a string (two FNV-1a passes, like parser.uc node_id): lets the UI name a
// subscription without the secret URL.
function fnv1a(s, h) {
	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 16777619) & 0xffffffff;
	return h;
}
function str_key(s) {
	s = '' + s;
	return substr(sprintf('%08x%08x', fnv1a(s, 0x811c9dc5), fnv1a(s, 0x9747b28c)), 0, 12);
}

// uci value -> array. Lists come back as arrays; a scalar (set with `uci set`) is split on
// whitespace when `split_ws` (URLs, domains, MACs, IPs never contain spaces), else kept whole
// (node tags may contain spaces).
function as_list(v, split_ws) {
	if (v == null) return [];
	if (type(v) == 'array') return filter(v, (x) => length(x));
	v = '' + v;
	if (!length(v)) return [];
	if (!split_ws) return [ v ];
	return filter(split(v, /[ \t\r\n]+/), (x) => length(x));
}

// jq-compatible tostring (null -> "null").
function jstr(v) {
	return (v == null) ? 'null' : ('' + v);
}

// The legacy node identity server:port:uuid:sni:short_id (saved-archive matching, 1.x stores).
function nid(n) {
	let p0 = (type(n.peers) == 'array') ? n.peers[0] : null;
	return jstr(n.server ?? p0?.address) + ':' + jstr(n.server_port ?? p0?.port) + ':' +
		(n.uuid ?? p0?.public_key ?? '') + ':' + (n.tls?.server_name ?? '') + ':' +
		(n.tls?.reality?.short_id ?? '');
}

export { VALID_COMMUNITY, read_json, write_atomic, file_sig, mask_url, mask_token, str_key, as_list, jstr, nid };
