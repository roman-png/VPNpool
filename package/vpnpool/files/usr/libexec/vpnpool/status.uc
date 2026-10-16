#!/usr/bin/ucode
// vpnpool: JSON status snapshot for the LuCI dashboard / rpcd / the Telegram bot.
// One process does it all (ROADMAP 3.7): uci is read ONCE through the ucode uci module, files
// are read directly, the daemon is its pidfile PID (checked in /proc). Processes per poll:
//   nft (is routing installed) + one curl for the clash API (proxies + connections in one call,
//   to stdout — no shared temp files, polls may overlap — only while the daemon runs) +
//   parser.uc only when the imported/manual/saved link files CHANGED (cached by
//   inode:mtime:size + the parser's own signature in /tmp/vpnpool/.status-cache.json).
// Output: the same fields the UI has always read, plus ok/code/daemon (the rpcd reply shape),
// node `id`, build (build_status.json), busy, paused, ping_progress, subscriptions. Secrets are
// masked: telegram_token -> "<bot id>:***", subscription URLs -> scheme://host/***.
'use strict';

import { readfile, stat, lsdir, popen, access, writefile, unlink, open } from 'fs';
import { cursor } from 'uci';
import { rand } from 'math';
import { read_json, write_atomic, file_sig, mask_url, mask_token, str_key, as_list, nid, SB_AWG, engine_cap } from './common.uc';

const SB = '/tmp/vpnpool';
const CONF = '/etc/vpnpool';
const PARSER = '/usr/libexec/vpnpool/parser.uc';

let all = cursor().get_all('vpnpool') ?? {};
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

// ---- parser results of the small link files, cached by file signature ----
let CACHEF = SB + '/.status-cache.json';
let PARSER_SIG = file_sig(PARSER);   // a new parser.uc (package update) invalidates the cache
let cache = read_json(CACHEF, {});
if (type(cache) != 'object') cache = {};
let cache_dirty = false;
function parsed(key, sig, path_fn) {
	let c = cache[key];
	sig = sig + '|' + PARSER_SIG;
	if (c && c.sig == sig) return c.v;
	let v = [];
	let path = path_fn();
	if (path && (stat(path)?.size ?? 0) > 0) {
		let out = run(sprintf("ucode %s '%s' 2>/dev/null", PARSER, path));
		try { v = json(out); } catch (e) { v = []; }
		if (type(v) != 'array') v = [];
	}
	if (path && index(path, '/.archive.links.') >= 0) unlink(path);
	cache[key] = { sig: sig, v: v };
	cache_dirty = true;
	return v;
}
function tags_of(arr) { return map(arr, (n) => n.tag); }
let imp_tags = tags_of(parsed('imported', file_sig(SB + '/imported.links'), () => SB + '/imported.links'));
let man_tags = tags_of(parsed('manual', file_sig(SB + '/manual.links'), () => SB + '/manual.links'));

// saved archive = manual stars (saved.map) UNION auto-snapshot (snapshot.map), one entry per tag
let SAVED_MAP = CONF + '/saved.map.json', SNAP_MAP = CONF + '/snapshot.map.json';
let archive_nodes = parsed('archive', file_sig(SAVED_MAP) + '|' + file_sig(SNAP_MAP), function() {
	let a = read_json(SAVED_MAP, {}), b = read_json(SNAP_MAP, {});
	let by = {};
	for (let m in [ b, a ])                      // a (manual) wins over the snapshot
		if (type(m) == 'object') for (let k in m) by[k] = m[k];
	let links = [];
	for (let k in sort(keys(by))) if (type(by[k]) == 'string' && length(by[k])) push(links, by[k]);
	if (!length(links)) return null;
	let p = sprintf('%s/.archive.links.%d.%d', SB, time(), rand());   // own name: polls may overlap
	writefile(p, join('\n', links) + '\n');
	return p;
});
let archive_ids = {};
for (let n in archive_nodes) archive_ids[nid(n)] = true;
let actsaved_ids = {};
for (let n in parsed('active_saved', file_sig(SB + '/active_saved.links'), () => SB + '/active_saved.links'))
	actsaved_ids[nid(n)] = true;
if (cache_dirty) write_atomic(CACHEF, sprintf('%J', cache));

// ---- nodes ----
let nodes_in = read_json(SB + '/nodes.json', []);
if (type(nodes_in) != 'array') nodes_in = [];
let node_tag_set = {};
for (let n in nodes_in) node_tag_set[n.tag] = true;

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

let unlock = read_json(CONF + '/unlock.map.json', {});
let ndelay = read_json(SB + '/.nodedelay.json', {});
let active_ids = {};
let nodes = [];
for (let n in nodes_in) {
	if (type(n) != 'object') continue;
	let id_legacy = nid(n);
	active_ids[id_legacy] = true;
	let delay = null;
	for (let h in (px[n.tag]?.history ?? []))
		if (h?.delay != null && h.delay > 0) delay = h.delay;
	if (delay == null && type(ndelay) == 'object') delay = ndelay[n.tag] ?? null;
	let p0 = (type(n.peers) == 'array') ? n.peers[0] : null;
	let group = (n.type == 'awg' || n.type == 'wireguard') ? 'amneziawg'
		: ((n.tag in imp_tags) ? 'imported' : ((n.tag in man_tags) ? 'manual' : 'subscription'));
	push(nodes, {
		tag: n.tag,
		id: n.id ?? null,
		server: n.server ?? p0?.address,
		port: n.server_port ?? p0?.port,
		proto: n.type,
		delay: delay,
		up: ntraf[n.tag]?.up ?? 0,
		down: ntraf[n.tag]?.down ?? 0,
		saved: !!archive_ids[id_legacy],
		active_saved: !!actsaved_ids[id_legacy],
		unlock: (type(unlock) == 'object') ? (unlock[n.tag] ?? null) : null,
		group: group,
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
	push(nodes, {
		tag: d.tag, id: d.id ?? null, server: d.server, port: d.port, proto: d.type,
		delay: null, up: 0, down: 0, saved: false, active_saved: false, unlock: null,
		group: (d.type == 'awg' || d.type == 'wireguard') ? 'amneziawg' : null,   // others: source not tracked here
		hints: d.hints ?? null,
		deferred: true, reason: d.reason, detail: d.detail ?? null
	});
}

// archived nodes whose identity is NOT live (one per identity, ordered by it)
let inact = {};
for (let n in archive_nodes) {
	let k = nid(n);
	if (!active_ids[k] && !inact[k]) inact[k] = { tag: n.tag, server: n.server, port: n.server_port };
}
let saved_inactive = map(sort(keys(inact)), (k) => inact[k]);

// ---- subscription quota / expiry (primary) ----
let expire = trim(readfile(CONF + '/sub.expire') ?? '');
expire = match(expire, /^[0-9]+$/) ? +expire : null;
let usage = split(trim(readfile(CONF + '/sub.usage') ?? ''), /[ \t]+/);
let sup = num(usage[0], 0), sdn = num(usage[1], 0), stot = num(usage[2], 0);

// ---- per-source fetch results (fetch.sh -> fetch_status.json, full URLs; masked here) ----
let fst = read_json(SB + '/fetch_status.json', {});
if (type(fst) != 'object') fst = {};
let sub_url = o('subscription_url', '');
let extra = as_list(M.extra_sub, true);
let subscriptions = [];
function sub_entry(u, kind) {
	let f = fst[u] ?? {};
	push(subscriptions, { key: str_key(u), kind: kind, url: mask_url(u),
		last_fetch_at: f.at ?? null, last_ok_at: f.last_ok_at ?? null,
		result: f.result ?? null, nodes: f.nodes ?? null });
}
if (length(sub_url)) sub_entry(sub_url, 'primary');
for (let u in extra) sub_entry(u, 'extra');

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

let dead = read_json(SB + '/.dead_tags.json', []);
if (type(dead) != 'array') dead = [];
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

printf('%J\n', {
	ok: true, code: 'ok', daemon: 'n/a',
	enabled: o('enabled', '0') == '1',
	running: running,
	routing: routing,
	paused: access(SB + '/.routing_paused') ? true : false,
	awg: awgcap,
	engine: engine,
	guard: read_json(SB + '/guard_status.json', null),
	mode: o('mode', 'selective'),
	active: px.proxy?.now ?? '',
	auto_now: px.auto?.now ?? '',
	subscription: { url: mask_url(sub_url), expire: expire, used: sup + sdn, total: stot },
	subscriptions: subscriptions,
	build: read_json(SB + '/build_status.json', null),
	busy: busy,
	ping_progress: ping_progress,
	nodes: nodes,
	saved_inactive: saved_inactive,
	dead_nodes: dead,
	kept_nodes: as_list(M.keep_auto, false),
	auto_members: as_list(M.auto_member, false),
	traffic: { up_total: conns.uploadTotal ?? 0, down_total: conns.downloadTotal ?? 0, connections: length(conn_arr) },
	client_traffic: clist,
	domains: as_list(RT.domain, true),
	manual_nodes: as_list(M.manual_node, true),
	sources: map(as_list(M.source, true), mask_url),
	extra_subs: map(extra, mask_url),
	auto_domains: as_list(RT.auto_domain, true),
	communities: as_list(RT.community, true),
	settings: {
		failover_interval: num(o('failover_interval', '60'), 60),
		subscription_interval: o('subscription_interval', '6h'),
		failover_tolerance: num(o('failover_tolerance', '50'), 50),
		auto_switch: o('auto_switch', '1') == '1',
		ipv6: o('ipv6', 'block'),
		killswitch: o('killswitch', '0') == '1',
		dns_protect: o('dns_protect', '0') == '1',
		preferred_node: o('preferred_node', ''),
		selected_node: o('selected_node', ''),
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
		prefilter_concurrency: intopt('prefilter_concurrency', 16)
	},
	clients: as_list(M.client, true),
	client_devices: as_list(M.client_dev, true)
});
