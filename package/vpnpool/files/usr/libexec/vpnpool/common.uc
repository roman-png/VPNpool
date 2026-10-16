// vpnpool shared ucode helpers (imported by status.uc and api.uc: `import ... from './common.uc'`).
// Pure functions + small file helpers; the only processes spawned here are the engine probes of
// engine_cap (and only when a sing-box binary changed).
'use strict';

import { readfile, writefile, stat, open, rename, unlink, popen, access, mkdir } from 'fs';
import { rand } from 'math';

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

// A name part no other process gets: the kernel's random uuid. NOT time()+rand(): ucode seeds
// rand() so coarsely that two processes started together draw the same number (measured: 2 of 8
// parallel runs) — two overlapping status polls then shared one temp file and one deleted it under
// the other.
function uniq() {
	let u = trim(readfile('/proc/sys/kernel/random/uuid') ?? '');
	return length(u) ? u : sprintf('%d.%d', time(), rand());
}

// Atomic write (temp file in the same directory + rename) — readers never see half a file.
function write_atomic(path, data) {
	let t = sprintf('%s.tmp.%s', path, uniq());   // own name: writers may overlap
	let f = open(t, 'w');
	if (!f) return false;
	f.write(data);
	f.close();
	if (rename(t, path)) return true;
	unlink(t);
	return false;
}

// "inode:mtime:size" of a file ('-' when absent): cache key of a derived value (a rewrite of the
// same size in the same second still gets a new inode: write_atomic / mv replace the file).
function file_sig(path) {
	let s = stat(path);
	return s ? (s.inode + ':' + s.mtime + ':' + s.size) : '-';
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

// ---- the sing-box engine (ROADMAP 4.1) ----
// Which sing-box runs our config, and can it do AmneziaWG. The stock binary (opkg/apk, shared
// with podkop) stays /usr/bin/sing-box; our AWG build is a separate file /usr/bin/sing-box-awg
// (engine.sh). uci singbox_bin pins another binary (empty / the stock path = automatic).
// The capability is MEASURED, never guessed from a version string: `version -n` + `check` of a
// tiny config with an awg endpoint (AWG_PROBE: the probe engine.sh uses before it installs a build)
// and of one with the AWG 3.1 fields (AWG_PROBE31: header key, I1, range timers, random trailers,
// keepalive range — the old hoaxisr awg2.1 fork that vpnpool 1.4 put in place of the stock binary
// passes the first and fails this one).
// Cached per binary by mtime:size in /tmp/vpnpool/engine-cap.json — the only place here that
// spawns processes, and only when a binary changed (status polls cost nothing).
// Env overrides (stand tests): VPNPOOL_SB_STOCK, VPNPOOL_SB_AWG, VPNPOOL_ENGINE_CAP.
const SB_STOCK = getenv('VPNPOOL_SB_STOCK') ?? '/usr/bin/sing-box';
const SB_AWG = getenv('VPNPOOL_SB_AWG') ?? '/usr/bin/sing-box-awg';
const ENGINE_CAP = getenv('VPNPOOL_ENGINE_CAP') ?? '/tmp/vpnpool/engine-cap.json';
const AWG_PROBE = '{"log":{"level":"error"},"endpoints":[{"type":"awg","tag":"engine-check",' +
	'"private_key":"YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=","address":["10.8.1.9/32"],' +
	'"jc":4,"jmin":10,"jmax":50,"s1":89,"s2":112,"h1":"1","h2":"2","h3":"3","h4":"4","peers":[' +
	'{"address":"198.51.100.61","port":443,"public_key":"SrvPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0=",' +
	'"allowed_ips":["0.0.0.0/0"]}]}],"outbounds":[{"type":"direct","tag":"direct"}]}\n';
const AWG_PROBE31 = '{"log":{"level":"error"},"endpoints":[{"type":"awg","tag":"engine-check31",' +
	'"private_key":"YBk0FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAk=","address":["10.8.1.9/32"],' +
	'"jc":4,"jmin":10,"jmax":50,"s1":16,"s2":16,"s3":16,"s4":16,"h1":"1","h2":"2","h3":"3","h4":"4",' +
	'"i1":"<r 2>","header_protection_key":"c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI=",' +
	'"rekey_after_time":"100-120","random_trailers":true,"disable_cookies":true,"peers":[' +
	'{"address":"198.51.100.61","port":443,"public_key":"SrvPUBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0=",' +
	'"persistent_keepalive_interval":"25-35","allowed_ips":["0.0.0.0/0"]}]}],"outbounds":[{"type":"direct","tag":"direct"}]}\n';

function shq(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }

// "1.14.3-awg.1" -> [1, 14]; null when unknown
function sb_version_mm(v) {
	let m = match('' + (v ?? ''), /^([0-9]+)\.([0-9]+)/);
	return m ? [ int(m[1]), int(m[2]) ] : null;
}

// engine_cap(bin, force) -> {bin, present, sig, version, major, minor, awg, awg31}
function engine_cap(bin, force) {
	let st = stat(bin);
	if (!st || st.type != 'file' || !access(bin, 'x'))
		return { bin: bin, present: false, sig: null, version: null, major: null, minor: null, awg: false, awg31: false };
	let sig = st.mtime + ':' + st.size;
	let cache = read_json(ENGINE_CAP, {});
	if (type(cache) != 'object') cache = {};
	let c = cache[bin];
	if (!force && type(c) == 'object' && c.sig == sig && c.awg31 != null) return c;
	mkdir(substr(ENGINE_CAP, 0, rindex(ENGINE_CAP, '/')));
	let f = popen(shq(bin) + ' version -n 2>/dev/null', 'r');
	let v = f ? trim(split(f.read('all') ?? '', '\n')[0] ?? '') : '';
	if (f) f.close();
	let probe = sprintf('%s.probe.%s.json', ENGINE_CAP, uniq());
	let awg = false, awg31 = false;
	if (writefile(probe, AWG_PROBE) != null) {
		awg = system(shq(bin) + ' check -c ' + shq(probe) + ' >/dev/null 2>&1') == 0;
		if (awg && writefile(probe, AWG_PROBE31) != null)
			awg31 = system(shq(bin) + ' check -c ' + shq(probe) + ' >/dev/null 2>&1') == 0;
		unlink(probe);
	}
	let mm = sb_version_mm(v);
	c = { bin: bin, present: true, sig: sig, version: length(v) ? v : null,
	      major: mm ? mm[0] : null, minor: mm ? mm[1] : null, awg: awg, awg31: awg31 };
	cache[bin] = c;
	write_atomic(ENGINE_CAP, sprintf('%J', cache));
	return c;
}

// engine_select(cfg_bin, has_awg) -> the cap of the binary to build/run with + reason:
//   reason null | "engine_missing" (AWG nodes, no AWG-capable build installed) |
//   "engine_no_awg" (the configured / installed build cannot run AWG)
// Rules: uci singbox_bin set to another binary -> that one (if it exists); otherwise the stock
// one — except when there are AWG nodes: then /usr/bin/sing-box-awg whenever it can run AWG
// (our engine wins over a stock binary that happens to be an AWG fork); the stock binary only
// when there is no engine. Pure WireGuard runs on the stock binary. Nodes with AWG 3.1 fields on
// a build without them (awg31:false) are deferred by build.sh (engine_no_awg31).
function engine_select(cfg_bin, has_awg) {
	let explicit = (type(cfg_bin) == 'string' && length(cfg_bin) && cfg_bin != SB_STOCK) ? cfg_bin : null;
	let cap = explicit ? engine_cap(explicit) : null;
	if (!cap?.present) cap = engine_cap(SB_STOCK);
	let reason = null;
	if (!cap.present) {                       // no stock binary: the AWG build is all there is
		let ac = engine_cap(SB_AWG);
		if (ac.present) cap = ac;
	}
	let pinned = explicit && cap.bin == explicit;
	if (has_awg && !pinned) {
		let ac = engine_cap(SB_AWG);
		if (ac.present && ac.awg) cap = ac;
		else if (!cap.awg) reason = ac.present ? 'engine_no_awg' : 'engine_missing';
	} else if (has_awg && !cap.awg) reason = 'engine_no_awg';
	let r = {};
	for (let k, v in cap) r[k] = v;
	r.reason = reason;
	r.explicit = explicit;
	return r;
}

export { VALID_COMMUNITY, uniq, read_json, write_atomic, file_sig, mask_url, mask_token, str_key, as_list, jstr, nid,
	SB_STOCK, SB_AWG, ENGINE_CAP, sb_version_mm, engine_cap, engine_select };
