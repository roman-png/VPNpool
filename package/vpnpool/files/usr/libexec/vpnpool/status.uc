#!/usr/bin/ucode
// vpnpool: JSON status snapshot for the LuCI dashboard / rpcd / the Telegram bot.
// One process does it all (ROADMAP 3.7): uci is read ONCE through the ucode uci module, files
// are read directly, the daemon is its pidfile PID (checked in /proc). Processes per poll:
//   nft (is routing installed) + one curl for the clash API (proxies + connections in one call,
//   to stdout — no shared temp files, polls may overlap — only while the daemon runs). The node
//   list carries its source (build.sh `_src`), so no link file is parsed here.
// Output: ok/code/daemon (the rpcd reply shape); nodes with their id, source, favourite /
// preferred / dead / kept marks; subscriptions (each with its expiry, quota, update interval,
// "updated", mode and picks), favorites, hidden, preferred, dead_ids / kept_ids /
// auto_member_ids / auto_exclude_ids (ROADMAP 9: node ids everywhere); build, busy, paused, ping_progress, engine,
// migration (what the 1.x -> 2.0 migration could not match). The older screens' fields
// (subscription, extra_subs, sources, saved_inactive, dead_nodes / kept_nodes / auto_members as
// tags, settings.preferred_node as a tag, settings.selected_node "") are still there until
// stage 7. Secrets are masked: telegram_token -> "<bot id>:***", URLs -> scheme://host/***.
'use strict';

import { readfile, stat, lsdir, popen, access, open } from 'fs';
import { cursor } from 'uci';
import { read_json, mask_url, mask_token, str_key, as_list, SB_AWG, engine_cap,
	is_id, subs_of, fav_read } from './common.uc';

const SB = '/tmp/vpnpool';
const CONF = '/etc/vpnpool';

let U = cursor();
let all = U.get_all('vpnpool') ?? {};
let M = all.main ?? {};
let RT = all.routing ?? {};
function o(name, def) { let v = M[name]; return (v != null && v != '') ? v : def; }
function num(v, def) { let n = +v; return (v != null && v != '' && n == n) ? n : def; }

// ---- processes ----
// argv of a PID (procfs files report size 0: readfile() / read('all') return "" — read a chunk)
function argv_of(pid) {
	let f = open('/proc/' + pid + '/cmdline', 'r');
	if (!f) return null;
	let c = f.read(4096);
	f.close();
	return c ? split(c, '\0') : null;
}
// Is this process RUNNING the script (its interpreter's first argument / argv[0] is the
// script path)? Not a substring of the whole command line: a `pgrep -f <path>` or any command
// that merely mentions the path must not count.
function runs_script(argv, path) {
	if (!argv) return false;
	for (let i = 0; i < 2 && i < length(argv); i++) {
		let a = '' + argv[i];   // path is given without the leading '/'
		if (a == path || (length(a) > length(path) && substr(a, -length(path) - 1) == '/' + path))
			return true;
	}
	return false;
}
// the daemon = the PID in its pidfile, alive and running vpnpoold
let dpid = trim(readfile('/var/run/vpnpool.pid') ?? '');
let running = match(dpid, /^[0-9]+$/) ? runs_script(argv_of(dpid), 'usr/libexec/vpnpool/vpnpoold') : false;
let procs = [];
for (let p in (lsdir('/proc') ?? [])) {
	if (!match(p, /^[0-9]+$/)) continue;
	let a = argv_of(p);
	if (a) push(procs, a);
}
function proc_running(script) {
	for (let a in procs) if (runs_script(a, script)) return true;
	return false;
}

// lock file with a live owner PID (clear_stale_lock rule); a PID-less lock counts if fresh
function lock_busy(path, maxage) {
	let s = stat(path);
	if (!s) return false;
	let pid = trim(readfile(path) ?? '');
	if (match(pid, /^[0-9]+$/)) return !!access('/proc/' + pid);
	return (time() - s.mtime) < maxage;
}

// ---- one popen per external fact ----
function run(cmd) {
	let f = popen(cmd, 'r');
	if (!f) return '';
	let out = f.read('all') ?? '';
	f.close();
	return out;
}
let routing = length(run('nft list table inet vpnpool 2>/dev/null')) > 0;

let clash = o('clash_api', '127.0.0.1:9091');
let prox = {}, conns = {};
function jparse(s) { let v = null; try { v = json(s); } catch (e) { v = null; } return (type(v) == 'object') ? v : {}; }
if (running) {
	// both answers in ONE curl call, to stdout, each followed by a separator line
	let SEP = '@@vpnpool-status@@';
	let outp = run(sprintf("curl -s -m3 -w '\\n%s\\n' 'http://%s/proxies' 'http://%s/connections' 2>/dev/null", SEP, clash, clash));
	let parts = split(outp, '\n' + SEP + '\n');
	prox = jparse(parts[0] ?? '');
	conns = jparse(parts[1] ?? '');
}
let px = prox.proxies ?? {};

// ---- the data model (ROADMAP 9; the stores are described in common.uc) ----
let SUBS = subs_of(U);
let fav = fav_read();
let pref_id = o('preferred_node', '');
let hidden_ids = filter(as_list(M.hidden, true), is_id);
let auto_ids = filter(as_list(M.auto_member, true), is_id);
let excl_ids = filter(as_list(M.auto_exclude, true), is_id);
let keep_ids = filter(as_list(M.keep_auto, true), is_id);
let dead_ids = read_json(SB + '/.dead_ids.json', []);
if (type(dead_ids) != 'array') dead_ids = [];
function set_of(a) { let s = {}; for (let x in a) s[x] = true; return s; }
let dead_set = set_of(dead_ids), keep_set = set_of(keep_ids), hidden_set = set_of(hidden_ids);

// ---- nodes ----
let nodes_in = read_json(SB + '/nodes.json', []);
if (type(nodes_in) != 'array') nodes_in = [];
let node_tag_set = {}, tag_of = {};
for (let n in nodes_in) if (type(n) == 'object') { node_tag_set[n.tag] = true; if (n.id) tag_of[n.id] = n.tag; }
// the ids of a list -> the tags of this build (the legacy fields of the older screens)
function tags_of(ids) { let r = []; for (let i in ids) if (tag_of[i] != null) push(r, tag_of[i]); return r; }

// per-node / per-client live traffic from the clash connections
let ntraf = {}, ctraf = {}, clist = [];
let conn_arr = (type(conns.connections) == 'array') ? conns.connections : [];
let leases = {};
for (let l in split(readfile('/tmp/dhcp.leases') ?? '', '\n')) {
	let f = split(trim(l), /[ \t]+/);
	if (length(f) >= 4) leases[f[2]] = f[3];
}
for (let c in conn_arr) {
	let up = +(c.upload ?? 0), dn = +(c.download ?? 0);
	for (let ch in (c.chains ?? [])) {
		if (node_tag_set[ch]) {
			ntraf[ch] ??= { up: 0, down: 0 };
			ntraf[ch].up += up; ntraf[ch].down += dn;
			break;
		}
	}
	let ip = c.metadata?.sourceIP ?? '?';
	if (!ctraf[ip]) { ctraf[ip] = { ip: ip, host: leases[ip] ?? '', up: 0, down: 0, conns: 0 }; push(clist, ctraf[ip]); }
	ctraf[ip].up += up; ctraf[ip].down += dn; ctraf[ip].conns++;
}
clist = sort(clist, (a, b) => (b.up + b.down) - (a.up + a.down));
if (length(clist) > 30) clist = slice(clist, 0, 30);

let sub_mode = {};
for (let s in SUBS) sub_mode[s.id] = s.mode;
// where a node comes from (build.sh `_src`): manual | awg | favorite | subscription | legacy
function source_of(src) {
	src = '' + (src ?? 'legacy');
	if (substr(src, 0, 4) == 'sub:') return [ 'subscription', substr(src, 4) ];
	if (src == 'fav') return [ 'favorite', null ];
	return [ (src in [ 'manual', 'awg' ]) ? src : 'legacy', null ];
}
// the group of the older screens: amneziawg | manual | imported (a "pick" subscription) | subscription
function legacy_group(n, kind, sid) {
	if (n.type == 'awg' || n.type == 'wireguard') return 'amneziawg';
	if (kind == 'manual') return 'manual';
	if (kind == 'subscription' && sub_mode[sid] == 'pick') return 'imported';
	return 'subscription';
}

let unlock = read_json(CONF + '/unlock.map.json', {});
if (type(unlock) != 'object') unlock = {};
let ndelay = read_json(SB + '/.nodedelay.json', {});
if (type(ndelay) != 'object') ndelay = {};
let nodes = [], pool_ids = {}, by_sub = {};
for (let n in nodes_in) {
	if (type(n) != 'object') continue;
	let id = n.id ?? null;
	if (id) pool_ids[id] = true;
	let delay = null;
	for (let h in (px[n.tag]?.history ?? []))
		if (h?.delay != null && h.delay > 0) delay = h.delay;
	if (delay == null && id) delay = ndelay[id] ?? null;
	let p0 = (type(n.peers) == 'array') ? n.peers[0] : null;
	let sk = source_of(n._src);
	if (sk[1]) by_sub[sk[1]] = (by_sub[sk[1]] ?? 0) + 1;
	let f = id ? fav[id] : null;
	push(nodes, {
		tag: n.tag,
		id: id,
		server: n.server ?? p0?.address,
		port: n.server_port ?? p0?.port,
		proto: n.type,
		delay: delay,
		up: ntraf[n.tag]?.up ?? 0,
		down: ntraf[n.tag]?.down ?? 0,
		source: sk[0],
		sub: sk[1],
		favorite: type(f) == 'object',
		preferred: id != null && id == pref_id,
		dead: !!dead_set[id],
		kept: !!keep_set[id],
		// legacy fields of the older screens: saved = favourite; active_saved = a favourite that is
		// in the pool only from the archive (no source has it)
		saved: type(f) == 'object',
		active_saved: sk[0] == 'favorite',
		unlock: id ? (unlock[id] ?? null) : null,
		group: legacy_group(n, sk[0], sk[1]),
		hints: n.random_trailers ? [ 'awg_random_trailers' ] : null
	});
}
// deferred nodes (build.sh -> deferred.json): kept, NOT in the config (ROADMAP 4.7) — the UI shows
// them greyed out with the reason: engine_missing / engine_no_awg (AWG without the engine),
// start_failed (the start guard set the node aside; detail = the engine's message)
let deferred = read_json(SB + '/deferred.json', []);
if (type(deferred) != 'array') deferred = [];
for (let d in deferred) {
	if (type(d) != 'object') continue;
	let sk = source_of(d._src);
	let f = d.id ? fav[d.id] : null;
	if (d.id) pool_ids[d.id] = true;
	push(nodes, {
		tag: d.tag, id: d.id ?? null, server: d.server, port: d.port, proto: d.type,
		delay: null, up: 0, down: 0, source: sk[0], sub: sk[1], favorite: type(f) == 'object',
		preferred: d.id != null && d.id == pref_id, dead: false, kept: false,
		saved: type(f) == 'object', active_saved: false, unlock: null,
		group: (d.type == 'awg' || d.type == 'wireguard') ? 'amneziawg' : legacy_group(d, sk[0], sk[1]),
		hints: d.hints ?? null,
		deferred: true, reason: d.reason, detail: d.detail ?? null
	});
}

// ---- favourites (ROADMAP 9.3): every one, in the pool or kept from a source that lost it ----
let favorites = [], saved_inactive = [];
for (let id in sort(keys(fav))) {
	let f = fav[id];
	if (type(f) != 'object') continue;
	let in_pool = !!pool_ids[id];
	push(favorites, { id: id, tag: tag_of[id] ?? f.tag ?? null, in_pool: in_pool, active: f.active === true,
		auto: f.auto === true, type: f.type ?? null, server: f.server ?? null, port: f.port ?? null, at: f.at ?? null });
	if (!in_pool) push(saved_inactive, { id: id, tag: f.tag ?? id, server: f.server ?? null, port: f.port ?? null });
}

// ---- hidden (ROADMAP 9.4): the nodes a source still has (build.sh -> hidden.json) + ids no
// source has any more (they can still be returned or forgotten) ----
let hidden = [], hseen = {};
let hj = read_json(SB + '/hidden.json', []);
for (let h in ((type(hj) == 'array') ? hj : [])) {
	if (type(h) != 'object' || !hidden_set[h.id] || hseen[h.id]) continue;
	hseen[h.id] = true;
	let sk = source_of(h.src);
	push(hidden, { id: h.id, tag: h.tag, type: h.type, server: h.server, port: h.port, source: sk[0], sub: sk[1], in_source: true });
}
for (let id in hidden_ids) if (!hseen[id]) push(hidden, { id: id, tag: null, in_source: false });

// ---- subscriptions (ROADMAP 9.1): each with its own expiry, quota, update interval, "updated" ----
let meta = read_json(CONF + '/subs.meta.json', {});
if (type(meta) != 'object') meta = {};
let fst = read_json(SB + '/fetch_status.json', {});
if (type(fst) != 'object') fst = {};
function clean_text(s, max) {
	if (type(s) != 'string') return null;
	if (substr(s, 0, 7) == 'base64:') s = b64dec(trim(substr(s, 7))) ?? '';
	s = trim(replace(s, /[[:cntrl:]]+/g, ' '));
	if (length(s) > max) s = substr(s, 0, max);
	return length(s) ? s : null;
}
function host_of(u) { let m = match(u ?? '', /^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^@\/?#]*@)?([^\/?#:]+)/); return m ? m[2] : ''; }
let subscriptions = [], primary = null, extra_masked = [], source_masked = [];
for (let s in SUBS) {
	let m = (type(meta[s.id]) == 'object') ? meta[s.id] : {};
	let f = fst[s.url] ?? {};
	let okm = stat(CONF + '/sources_cache/.ok-' + s.id);
	let used = (m.upload != null || m.download != null) ? ((m.upload ?? 0) + (m.download ?? 0)) : null;
	let missing = 0;
	if (s.mode == 'pick') for (let i in s.pick) if (!pool_ids[i] && !hidden_set[i]) missing++;
	let e = {
		id: s.id, key: str_key(s.url), name: length(s.name) ? s.name : (clean_text(m.title, 64) ?? host_of(s.url)),
		title: clean_text(m.title, 64), url: mask_url(s.url), enabled: s.enabled, mode: s.mode,
		picked: length(s.pick), pick_missing: missing, in_pool: by_sub[s.id] ?? 0,
		expire: m.expire ?? null, used: used, total: m.total ?? null, upload: m.upload ?? null, download: m.download ?? null,
		update_interval: m.update_interval ?? null, web_page: (type(m.web_page) == 'string') ? mask_url(m.web_page) : null,
		updated_at: f.last_ok_at ?? (okm ? okm.mtime : null), last_fetch_at: f.at ?? null,
		result: f.result ?? null, nodes: f.nodes ?? null,
		kind: null
	};
	if (primary == null && s.mode == 'all') { primary = e; e.kind = 'primary'; }
	else if (s.mode == 'all') { e.kind = 'extra'; push(extra_masked, e.url); }
	else { e.kind = 'pick'; push(source_masked, e.url); }
	push(subscriptions, e);
}

// ---- busy workers / progress ----
let busy = {
	fetch: proc_running('usr/libexec/vpnpool/fetch.sh'),
	build: proc_running('usr/libexec/vpnpool/build.sh'),
	ping: lock_busy(SB + '/.ping-running', 600),
	nodecheck: lock_busy(SB + '/.nodecheck-running', 600),
	probe: lock_busy(SB + '/.probe-running', 180),
	speedtest: lock_busy(SB + '/.speedtest-running', 180),
	unlock: lock_busy(SB + '/.unlock-running', 180)
};
let ping_progress = read_json(SB + '/.ping-progress.json', null);

// ---- the engine (ROADMAP 4.1): the binary the live config was checked with (build.sh -> .sb_bin),
// its version and AWG support, measured by engine_cap (cached by mtime:size: a poll spawns nothing
// unless a binary changed) + the AWG build if it is installed. awg = AmneziaWG nodes can run.
let sb_bin = trim(readfile(SB + '/.sb_bin') ?? '');
if (!length(sb_bin)) sb_bin = o('singbox_bin', '/usr/bin/sing-box');
let ecap = engine_cap(sb_bin);
let acap = (sb_bin == SB_AWG) ? ecap : engine_cap(SB_AWG);
let engine = { bin: sb_bin, present: ecap.present, version: ecap.version, awg: ecap.awg,
	awg_engine: { path: SB_AWG, installed: acap.present, version: acap.version, awg: acap.awg } };
let awgcap = ecap.awg || (acap.present && acap.awg);
let antidpi = o('antidpi', 'off');
if (antidpi == '1') antidpi = 'on';
else if (!(antidpi in [ 'on', 'off', 'aggressive' ])) antidpi = 'off';
function intopt(name, def) { let v = '' + o(name, ''); return match(v, /^[0-9]+$/) ? +v : def; }
let token = o('telegram_token', '');
// the 1.x -> 2.0 migration (migrate.sh): what it could not match stays listed here
let mig = read_json(CONF + '/migration.json', null);
// state: done | failed (the config is still 1.x: the daemon is not started, migrate.sh ->
// migration_failed.json {at, reason}) | null (a 2.0 install, nothing was migrated)
let migfail = read_json(SB + '/migration_failed.json', null);
let migration = (o('schema', '') != '2' && type(migfail) == 'object')
	? { state: 'failed', reason: migfail.reason ?? null, at: migfail.at ?? null, unmatched: [] }
	: (type(mig) == 'object') ? { state: 'done', at: mig.at ?? null, from: mig.from ?? null, backup: mig.backup ?? null,
	// a link-valued item is shown as scheme://host/*** (it carries the node's credential)
	unmatched: (type(mig.unmatched) == 'array') ? map(mig.unmatched, (x) => ({ store: x?.store,
		value: (type(x?.value) == 'string' && index(x.value, '://') >= 0) ? mask_url(x.value) : (x?.value ?? null) })) : [] } : null;

printf('%J\n', {
	ok: true, code: 'ok', daemon: 'n/a',
	enabled: o('enabled', '0') == '1',
	running: running,
	routing: routing,
	paused: access(SB + '/.routing_paused') ? true : false,
	awg: awgcap,
	engine: engine,
	guard: read_json(SB + '/guard_status.json', null),
	// AWG files the parser refuses (build.sh): [{file, reason, field?}] — removable by file name
	unreadable: read_json(SB + '/awg_unreadable.json', []),
	mode: o('mode', 'selective'),
	active: px.proxy?.now ?? '',
	auto_now: px.auto?.now ?? '',
	preferred: length(pref_id) ? { id: pref_id, tag: tag_of[pref_id] ?? fav[pref_id]?.tag ?? null, in_pool: !!pool_ids[pref_id] } : null,
	subscriptions: subscriptions,
	favorites: favorites,
	hidden: hidden,
	build: read_json(SB + '/build_status.json', null),
	busy: busy,
	ping_progress: ping_progress,
	nodes: nodes,
	dead_ids: dead_ids,
	kept_ids: keep_ids,
	auto_member_ids: auto_ids,
	auto_exclude_ids: excl_ids,
	migration: migration,
	traffic: { up_total: conns.uploadTotal ?? 0, down_total: conns.downloadTotal ?? 0, connections: length(conn_arr) },
	client_traffic: clist,
	domains: as_list(RT.domain, true),
	manual_nodes: as_list(M.manual_node, true),
	auto_domains: as_list(RT.auto_domain, true),
	communities: as_list(RT.community, true),
	// ---- legacy fields of the older screens (stage 7 drops them): tags instead of ids, one
	// "primary" subscription (the first one that takes every node), extra ones, pick sources
	subscription: primary ? { url: primary.url, expire: primary.expire, used: primary.used ?? 0, total: primary.total ?? 0 }
	                      : { url: '', expire: null, used: 0, total: 0 },
	extra_subs: extra_masked,
	sources: source_masked,
	saved_inactive: saved_inactive,
	dead_nodes: tags_of(dead_ids),
	kept_nodes: tags_of(keep_ids),
	auto_members: tags_of(auto_ids),
	settings: {
		failover_interval: num(o('failover_interval', '60'), 60),
		subscription_interval: o('subscription_interval', '6h'),
		failover_tolerance: num(o('failover_tolerance', '50'), 50),
		auto_switch: o('auto_switch', '1') == '1',
		ipv6: o('ipv6', 'block'),
		killswitch: o('killswitch', '0') == '1',
		dns_protect: o('dns_protect', '0') == '1',
		preferred_id: pref_id,
		favorites_only: o('favorites_only', '0') == '1',
		preferred_node: tag_of[pref_id] ?? '',   // legacy: the tag
		selected_node: '',                       // legacy: there is no hard pin any more
		telegram_enabled: o('telegram_enabled', '0') == '1',
		telegram_token: mask_token(token),
		telegram_token_set: length(token) > 0,
		telegram_chat: o('telegram_chat', ''),
		telegram_control: o('telegram_control', '0') == '1',
		telegram_via_proxy: o('telegram_via_proxy', '1') == '1',
		client_mode: o('client_mode', 'all'),
		auto_snapshot: o('auto_snapshot', '0') == '1',
		auto_snapshot_max: intopt('auto_snapshot_max', 20),
		antidpi: antidpi,
		adaptive_routing: o('adaptive_routing', '0') == '1',
		dead_filter: o('dead_filter', '1') == '1',
		dead_filter_strikes: intopt('dead_filter_strikes', 3),
		dead_filter_tries: intopt('dead_filter_tries', 3),
		check_services: o('check_services', ''),
		sched_enabled: o('sched_enabled', '0') == '1',
		sched_on: o('sched_on', ''),
		sched_off: o('sched_off', ''),
		sched_refresh: o('sched_refresh', ''),
		log_level: o('log_level', 'warn'),
		dns_strategy: o('dns_strategy', 'prefer_ipv4'),
		adaptive_max_per_run: intopt('adaptive_max_per_run', 8),
		prefilter_concurrency: intopt('prefilter_concurrency', 16),
		singbox_bin: o('singbox_bin', '')
	},
	clients: as_list(M.client, true),
	client_devices: as_list(M.client_dev, true)
});
