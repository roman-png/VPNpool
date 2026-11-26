// vpnpool shared ucode helpers (imported by status.uc and api.uc: `import ... from './common.uc'`).
// Pure functions + small file helpers; the only processes spawned here are the engine probes of
// engine_cap (and only when a sing-box binary changed).
'use strict';

import { readfile, writefile, stat, open, rename, unlink, popen, access, mkdir, chmod } from 'fs';
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
function write_atomic(path, data, perm) {
	let t = sprintf('%s.tmp.%s', path, uniq());   // own name: writers may overlap
	let f = open(t, 'w');
	if (!f) return false;
	if (perm != null) chmod(t, perm);             // before the data goes in
	f.write(data);
	f.close();
	if (rename(t, path)) return true;
	unlink(t);
	return false;
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

// ---- the data model (ROADMAP 9, schema 2) ----
// A node is known by its ID (parser.uc: 12 hex of the canonical config without the name; AWG:
// sha256 of the key, server key and endpoint) in EVERY store; the tag is only its display name in one build.
//   uci  config subscription 'sub_<key>'  name, url, enabled, mode all|pick, list pick <id>
//   uci  main: preferred_node <id>, list auto_member / auto_exclude / keep_auto / hidden <id>, favorites_only,
//        list manual_node <link> ("my nodes"; AmneziaWG ones are /etc/vpnpool/awg/<id>.conf)
//   /etc/vpnpool/favorites.map.json  { <id>: {tag, link|ob|null, active, auto, at} }
//        link: the node's link (ob: its outbound, for a node of a sing-box JSON source; null: an
//        AWG file node) — so a favourite outlives its subscription; active = it joins the pool
//        from here although no source has it; auto = added by "add working nodes automatically"
const CONF_DIR = '/etc/vpnpool';
const RUN_DIR = '/tmp/vpnpool';
const FAV_MAP = CONF_DIR + '/favorites.map.json';
const SUBS_META = CONF_DIR + '/subs.meta.json';
const SCHEMA = '2';

function is_id(s) { return type(s) == 'string' && !!match(s, /^[0-9a-f]{12}$/); }

// the subscription sections in config order -> [{id, name, url, enabled, mode, pick}]
function subs_of(u) {
	let out = [];
	u.foreach('vpnpool', 'subscription', function(s) {
		push(out, { id: s['.name'], name: s.name ?? '', url: s.url ?? '',
			enabled: (s.enabled ?? '1') != '0', mode: (s.mode == 'pick') ? 'pick' : 'all',
			pick: filter(as_list(s.pick, true), is_id) });
	});
	return out;
}
// a new section name for a URL: sub_<key of the URL>, unique among the existing sections
function sub_name_for(u, url) {
	let base = 'sub_' + str_key(url), n = base, i = 1;
	while (u.get('vpnpool', n) != null) n = base + '_' + (++i);
	return n;
}

function fav_read() {
	let m = read_json(FAV_MAP, {});
	return (type(m) == 'object') ? m : {};
}
// the favourites hold node links (credentials): owner-only, like the AWG files
function fav_write(m) {
	mkdir(CONF_DIR);
	return write_atomic(FAV_MAP, sprintf('%J', m), 0600);
}

// the last build's nodes: in the config (nodes.json) and waiting for the engine (deferred.json)
function live_nodes() {
	let a = read_json(RUN_DIR + '/nodes.json', []), d = read_json(RUN_DIR + '/deferred.json', []);
	let out = [];
	for (let n in ((type(a) == 'array') ? a : [])) if (type(n) == 'object') push(out, n);
	for (let n in ((type(d) == 'array') ? d : [])) if (type(n) == 'object') { n._deferred = true; push(out, n); }
	return out;
}
// A node by its id, or (legacy screens / the bot still send names) by its tag in the last build.
// -> {id, tag, node} | null. An id that is not live resolves through the favourites archive.
function node_lookup(key, nodes) {
	if (type(key) != 'string' || !length(key)) return null;
	nodes ??= live_nodes();
	for (let n in nodes) if (n.id == key) return { id: n.id, tag: n.tag, node: n };
	for (let n in nodes) if (n.tag == key && n.id) return { id: n.id, tag: n.tag, node: n };
	let fav = fav_read();
	if (is_id(key) && type(fav[key]) == 'object') return { id: key, tag: fav[key].tag, node: null, fav: fav[key] };
	// the older screens name a favourite outside the pool by its tag (status saved_inactive)
	for (let id in sort(keys(fav)))
		if (type(fav[id]) == 'object' && fav[id].tag == key) return { id: id, tag: key, node: null, fav: fav[id] };
	return null;
}
// link of a node by id: links.json of the last build, else the favourites archive
function link_of(id) {
	for (let p in [ RUN_DIR + '/links.json', CONF_DIR + '/links.json' ]) {
		let l = read_json(p, []);
		if (type(l) == 'array') for (let x in l) if (type(x) == 'object' && x.id == id && length(x.link)) return x.link;
	}
	let f = fav_read()[id];
	return (type(f) == 'object' && type(f.link) == 'string') ? f.link : null;
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

// the client names (User-Agents) a subscription download tries, in order (uci probe_ua replaces
// the list) — the same list as lib.sh DEFAULT_UAS (fetch.sh); a stand test keeps the two equal.
// Panels answer per client: one gets xray JSON, another a plain link list.
const DEFAULT_UAS = 'v2rayNG/1.9.5 v2rayN/6.45 Happ/1.0 sing-box/1.12 clash-meta/1.18 Streisand Hiddify/2.0 Shadowrocket/2.2 Mozilla/5.0';

// ---- the device headers of a subscription download (issue #5) ----
// Panels with a device limit (Remnawave: extractHwidHeaders) give no nodes to a client that sends
// no x-hwid; with it the router takes one place of the limit, like a phone app. The same headers
// as the apps: x-hwid (^[A-Za-z0-9=-]{10,64}$), x-device-os, x-ver-os, x-device-model.
// sub_device(u) -> {hwid, os, ver, model} or null (uci main.sub_hwid '0', or a hwid typed by hand
// that is not valid). An empty hwid is made once from the kernel's random UUID and kept in uci
// (the package's uci-defaults normally does it first). u = a uci cursor (common.uc imports no uci).
const HWID_RE = /^[A-Za-z0-9=-]{10,64}$/;
function hdr_clean(s, n) {
	// letters, digits and a few signs only: the value goes into a quoted curl -K line, where a
	// backslash or a quote would end it (no '/': inside [...] ucode would keep the backslash too)
	s = trim(replace(replace('' + (s ?? ''), /[^A-Za-z0-9 ._+(),:-]+/g, ' '), / +/g, ' '));
	return length(s) ? substr(s, 0, n) : null;
}
// The system, its version and the model can be typed by hand in Settings (uci main.sub_os /
// sub_os_ver / sub_model; empty = the router's own, sub_device_auto): a provider that expects a
// certain device. A typed value holds only the signs hdr_clean keeps (DEV_RE, checked by
// set_config); one that does not (edited past set_config) is not sent, the router's own goes.
const DEV_RE = /^[A-Za-z0-9 ._+(),:-]{1,64}$/;
function sub_device_auto() {
	let rel = null;
	for (let l in split(readfile('/etc/openwrt_release') ?? '', '\n'))
		if (substr(l, 0, 16) == 'DISTRIB_RELEASE=') rel = replace(substr(l, 16), /['"]/g, '');
	return { os: 'OpenWrt', ver: hdr_clean(rel, 32), model: hdr_clean(readfile('/tmp/sysinfo/model'), 64) };
}
function sub_device(u) {
	if (('' + (u.get('vpnpool', 'main', 'sub_hwid') ?? '1')) == '0') return null;
	let id = trim('' + (u.get('vpnpool', 'main', 'hwid') ?? ''));
	if (!length(id)) {
		id = trim(readfile('/proc/sys/kernel/random/uuid') ?? '');
		if (!match(id, HWID_RE)) return null;
		u.set('vpnpool', 'main', 'hwid', id);
		u.commit('vpnpool');
	}
	if (!match(id, HWID_RE)) return null;
	let a = sub_device_auto();
	let own = (k, auto) => { let v = trim('' + (u.get('vpnpool', 'main', k) ?? '')); return (length(v) && match(v, DEV_RE)) ? v : auto; };
	return { hwid: id, os: own('sub_os', a.os), ver: own('sub_os_ver', a.ver), model: own('sub_model', a.model) };
}

// ---- the client name (User-Agent) of a subscription download ----
// uci main.sub_ua (Settings): the router calls itself only that (a provider that lets in one app
// only); empty = the list (uci probe_ua, else DEFAULT_UAS), tried in order up to the first that
// gives nodes. UA_RE: letters, digits, spaces inside and the signs of real client names
// ("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"), no quote / backslash / glob sign. Built from a
// string: a '/' inside [...] of a regex literal would let a backslash in too (see hdr_clean).
const UA_RE = regexp('^[A-Za-z0-9._+()/,:;=-]([A-Za-z0-9 ._+()/,:;=-]{0,198}[A-Za-z0-9._+()/,:;=-])?$');
function sub_uas(u) {
	let one = trim('' + (u.get('vpnpool', 'main', 'sub_ua') ?? ''));
	if (length(one) && match(one, UA_RE)) return [ one ];
	return filter(split(trim('' + (u.get('vpnpool', 'main', 'probe_ua') ?? '')) || DEFAULT_UAS, /[ \t]+/), length);
}
// ---- why a subscription download gave no nodes (issue #11) ----
// The trial download of add (api.uc sub_probe) and the probe of the import dialog (probe.sh,
// model.uc why) say WHY, not only "failed": the panel was not reached (and how), it answered an
// HTTP error, an empty answer, something that is not a node list (a web page, a format the
// router does not read), or nodes the router cannot run (with the parser's reasons, counted).
// sub_report(file) -> the parser's --report records (array) or null; sub_why(http, rc, rep) ->
// { why, http, total?, skipped? }. rc = curl's exit code (the kind of a network failure).
const CURL_WHY = { '6': 'dns', '7': 'connect', '28': 'timeout', '35': 'tls', '51': 'tls', '53': 'tls',
	'54': 'tls', '58': 'tls', '59': 'tls', '60': 'tls', '66': 'tls', '77': 'tls', '80': 'tls', '82': 'tls',
	'83': 'tls', '90': 'tls', '91': 'tls', '63': 'too_large' };
// records that are not a node at all: the answer is not a node list
const NOT_NODE = { not_a_link: 1, not_a_node: 1 };
// the most telling of several tries (client names) is the one shown
const WHY_RANK = { all_skipped: 9, not_subscription: 8, too_large: 8, empty: 7, http_error: 6, tls: 5, timeout: 4,
	connect: 3, dns: 2, no_answer: 1 };
function sub_report(file) {
	if (!((stat(file)?.size ?? 0) > 0)) return null;
	let p = popen("ucode /usr/libexec/vpnpool/parser.uc --report '" + replace('' + file, "'", "'\\''") + "' 2>/dev/null", 'r');
	if (!p) return null;
	let out = p.read('all') ?? '';
	p.close();
	let r = null;
	try { r = json(out); } catch (e) { r = null; }
	return type(r) == 'array' ? r : null;
}
function sub_why(http, rc, rep) {
	http = trim('' + (http ?? ''));
	rc = trim('' + (rc ?? ''));
	if (!length(http) || http == '000') return { why: CURL_WHY[rc] ?? 'no_answer', http: '000' };
	if (+http >= 400) return { why: 'http_error', http: http };
	// an answer that began and broke off (time, size): the failure, not the half of a body
	if (length(rc) && rc != '0') return { why: CURL_WHY[rc] ?? 'no_answer', http: http };
	if (type(rep) != 'array' || !length(rep)) return { why: 'empty', http: http };
	let sk = {}, n = 0;
	for (let r in rep)
		if (r?.status == 'skip' && !NOT_NODE[r.reason]) { sk[r.reason ?? 'parse_error'] = (sk[r.reason ?? 'parse_error'] ?? 0) + 1; n++; }
	if (!n) return { why: 'not_subscription', http: http };
	return { why: 'all_skipped', http: http, total: n, skipped: sk };
}
function sub_why_better(a, b) {
	if (!a) return b;
	if (!b) return a;
	return (WHY_RANK[b.why] ?? 0) > (WHY_RANK[a.why] ?? 0) ? b : a;
}

// the same as "Name: value" lines (curl -H arguments / a curl -K config)
function sub_headers(u) {
	let d = sub_device(u);
	if (!d) return [];
	let h = [ 'x-hwid: ' + d.hwid, 'x-device-os: ' + d.os ];
	if (d.ver) push(h, 'x-ver-os: ' + d.ver);
	if (d.model) push(h, 'x-device-model: ' + d.model);
	return h;
}

export { DEFAULT_UAS, HWID_RE, DEV_RE, UA_RE, sub_device, sub_device_auto, sub_headers, sub_uas, sub_report, sub_why, sub_why_better, VALID_COMMUNITY, uniq, read_json, write_atomic, mask_url, mask_token, str_key, as_list,
	CONF_DIR, RUN_DIR, FAV_MAP, SUBS_META, SCHEMA, is_id, subs_of, sub_name_for, fav_read, fav_write, live_nodes, node_lookup, link_of,
	SB_STOCK, SB_AWG, ENGINE_CAP, sb_version_mm, engine_cap, engine_select };
