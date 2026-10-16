#!/usr/bin/ucode
// vpnpool 1.x -> 2.0 data-model migration (ROADMAP 9.7). Run by migrate.sh (lock, backup, journal)
// — never on its own. ARGV[0] = the backup archive migrate.sh made BEFORE this runs.
//
// 1.x kept every node store by TAG ("Name #2" — a tag can move to another server when the
// subscription reorders) and the subscriptions as options of main. 2.0 (common.uc):
//   subscription_url / extra_sub      -> config subscription (mode all), in that order
//   source + imported.map.json        -> config subscription (mode pick, pick = the ids of the
//                                        links imported from it); a source nothing was imported
//                                        from stays, switched off
//   imported_node                     -> favourites with their link, in the pool (active)
//   saved.map / snapshot.map          -> favorites.map.json (snapshot = automatic favourites)
//   active_saved                      -> favourites that join the pool from the archive
//   excluded_node                     -> hidden (ids)
//   selected_node (hard pin) / preferred_node -> preferred_node (id; the hard pin wins)
//   auto_member, keep_auto, unlock.map.json   -> by id
//   sub.expire / sub.usage            -> subs.meta.json of the first subscription
//   /etc/vpnpool/awg/<md5>.conf       -> awg/<id>.conf with "# Name = <its 1.x name>"
//   saved_node (a link in no map)     -> a favourite;  subscription_ua -> first in probe_ua
//   (migrate.sh copies the 1.x cache sources_cache/NNN.raw to the subscriptions' own s-<key>.raw)
// Tags are mapped to ids through what this router last knew of them: links.json (tag -> link),
// the 1.x node list and live config (/tmp/vpnpool/nodes.json, sing-box.json in RAM and flash),
// the saved maps and the AWG files. A value that can not be mapped is NOT dropped silently: it is
// listed in migration.json "unmatched" (status shows it) and stays in the backup.
// Idempotent: the uci commit with schema '2' is the LAST step (files written before it are
// recomputed identically on a re-run); the 1.x files are removed only after it.
// Output: the report JSON (also /etc/vpnpool/migration.json); exit 0, or 1 when the commit failed.
'use strict';

import { readfile, writefile, unlink, lsdir, rename, stat, mkdir, popen, chmod } from 'fs';
import { cursor } from 'uci';
import { read_json, write_atomic, as_list, is_id, sub_name_for, uniq, SCHEMA } from './common.uc';

const PARSER = '/usr/libexec/vpnpool/parser.uc';
const CONF = '/etc/vpnpool';
const RUN = '/tmp/vpnpool';
const AWG = CONF + '/awg';
const NODE_TYPES = { vless: 1, vmess: 1, trojan: 1, shadowsocks: 1, shadowtls: 1, hysteria: 1, hysteria2: 1,
	tuic: 1, wireguard: 1, awg: 1, ssh: 1, socks: 1, http: 1, anytls: 1 };

function sq(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function run(cmd) {
	let f = popen(cmd, 'r');
	if (!f) return '';
	let r = f.read('all') ?? '';
	f.close();
	return r;
}
function jrun(cmd) { let v = null; try { v = json(run(cmd)); } catch (e) { v = null; } return (type(v) == 'array') ? v : []; }

let u = cursor();
let M = u.get_all('vpnpool', 'main') ?? {};
let now = time();
let report = { at: now, from: '1.x', to: SCHEMA, backup: ARGV[0] ?? null, moved: {}, unmatched: [] };
function moved(k, n) { report.moved[k] = (report.moved[k] ?? 0) + (n ?? 1); }
function unmatched(store, value) { push(report.unmatched, { store: store, value: value }); }

mkdir(RUN);
let TMP = RUN + '/.migrate.' + uniq();
mkdir(TMP);
chmod(TMP, 0700);

// ---- links -> ids (one parser run over every link of every store) ----
let all_links = [], seen_link = {};
function want_link(l) { if (type(l) == 'string' && length(l) && !seen_link[l]) { seen_link[l] = true; push(all_links, l); } }
let links_json = read_json(CONF + '/links.json', []);
if (type(links_json) != 'array') links_json = [];
for (let x in links_json) want_link(x?.link);
let saved_map = read_json(CONF + '/saved.map.json', {}), snap_map = read_json(CONF + '/snapshot.map.json', {});
if (type(saved_map) != 'object') saved_map = {};
if (type(snap_map) != 'object') snap_map = {};
let imported_map = read_json(CONF + '/imported.map.json', {});
if (type(imported_map) != 'object') imported_map = {};
for (let m in [ saved_map, snap_map ]) for (let k, l in m) want_link(l);
for (let k, ls in imported_map) for (let l in ((type(ls) == 'array') ? ls : [])) want_link(l);
for (let o in [ 'manual_node', 'imported_node', 'active_saved', 'excluded_node', 'saved_node' ])
	for (let l in as_list(M[o], true)) want_link(l);

let LINK = {};   // link -> {id, tag, type, server, port}
if (length(all_links)) {
	let f = TMP + '/links';
	writefile(f, join('\n', all_links) + '\n');
	let byid = {};
	for (let n in jrun(sprintf('ucode %s --with-id %s 2>/dev/null', PARSER, sq(f)))) if (n?.id) byid[n.id] = n;
	for (let r in jrun(sprintf('ucode %s --report --with-id %s 2>/dev/null', PARSER, sq(f)))) {
		if (r?.line == null || !r.id) continue;
		let l = all_links[r.line - 1];
		if (l == null) continue;
		let n = byid[r.id] ?? {};
		LINK[l] = { id: r.id, tag: r.tag ?? n.tag, type: r.type ?? n.type, server: n.server, port: n.server_port };
	}
}
function id_of_link(l) { return LINK[l]?.id ?? null; }

// ---- tags -> ids, from everything this router last knew (the first source wins) ----
let TAG = {};
function know(tag, id) { if (type(tag) == 'string' && length(tag) && is_id(id) && TAG[tag] == null) TAG[tag] = id; }
for (let x in links_json) know(x?.tag, x?.id ?? id_of_link(x?.link));
for (let m in [ saved_map, snap_map ]) for (let t, l in m) know(t, id_of_link(l));
// a node list / config of the running 1.x (outbounds without ids): the parser gives each item its id
function know_outbounds(obs) {
	let items = filter(obs ?? [], (o) => type(o) == 'object' && NODE_TYPES[o.type] && length(o.tag));
	if (!length(items)) return;
	let f = TMP + '/obs.json';
	writefile(f, sprintf('%J', items));
	for (let r in jrun(sprintf('ucode %s --report --with-id %s 2>/dev/null', PARSER, sq(f))))
		if (r?.item != null && r.id) know(items[r.item - 1]?.tag, r.id);
}
know_outbounds(read_json(RUN + '/nodes.json', []));
for (let p in [ RUN + '/sing-box.json', CONF + '/sing-box.json' ]) {
	let c = read_json(p, null);
	if (type(c) == 'object') know_outbounds([ ...((type(c.outbounds) == 'array') ? c.outbounds : []), ...((type(c.endpoints) == 'array') ? c.endpoints : []) ]);
}

// ---- AmneziaWG / WireGuard files: <md5>.conf (1.x) -> <id>.conf with "# Name = <name>" ----
let awg_plan = [];   // {from, to, body}
for (let f in sort(lsdir(AWG) ?? [])) {
	if (!match(f, /\.conf$/)) continue;
	let path = AWG + '/' + f;
	let r = jrun(sprintf('ucode %s --report --with-id %s 2>/dev/null', PARSER, sq(path)))[0];
	if (r?.status != 'ok' || !r.id) { unmatched('awg_file', f); continue; }   // unreadable: left as it is
	know(r.tag, r.id);
	if (f == r.id + '.conf') continue;
	let raw = readfile(path) ?? '';
	let named = !!match(raw, /(^|\n)[ \t]*[#;][ \t]*[Nn][Aa][Mm][Ee][ \t]*=/);
	push(awg_plan, { from: path, to: AWG + '/' + r.id + '.conf', body: named ? raw : ('# Name = ' + r.tag + '\n' + raw) });
}

function id_of_tag(store, tag) {
	if (!length(tag)) return null;
	if (TAG[tag]) return TAG[tag];
	unmatched(store, tag);
	return null;
}

// ---- subscriptions ----
let subs = [];   // {url, mode, pick, enabled}
let have_url = {};
function add_sub(url, mode, pick, enabled) {
	if (type(url) != 'string' || !length(url) || have_url[url]) return;
	have_url[url] = true;
	push(subs, { url: url, mode: mode, pick: pick, enabled: enabled });
}
add_sub(M.subscription_url, 'all', [], true);
for (let x in as_list(M.extra_sub, true)) add_sub(x, 'all', [], true);
for (let src in as_list(M.source, true)) {
	let ids = [], seen = {};
	for (let l in ((type(imported_map[src]) == 'array') ? imported_map[src] : [])) {
		let id = id_of_link(l);
		if (!id) { unmatched('imported_node', l); continue; }
		if (!seen[id]) { seen[id] = true; push(ids, id); }
	}
	add_sub(src, 'pick', ids, length(ids) > 0);
}
let manual = as_list(M.manual_node, true);

// ---- favourites ----
let fav = read_json(CONF + '/favorites.map.json', {});
if (type(fav) != 'object') fav = {};
function fav_put(store, tag, link, auto, active) {
	let id = id_of_link(link);
	if (!id) { unmatched(store, link); return; }
	let li = LINK[link] ?? {};
	let e = fav[id] ?? { tag: tag ?? li.tag, link: link, active: false, auto: auto, at: now,
		type: li.type, server: li.server, port: li.port };
	if (!auto) e.auto = false;          // a manual star wins over the snapshot
	if (active) e.active = true;
	fav[id] = e;
}
for (let t in sort(keys(snap_map))) fav_put('snapshot', t, snap_map[t], true, false);
for (let t in sort(keys(saved_map))) fav_put('saved_node', t, saved_map[t], false, false);
for (let l in as_list(M.active_saved, true)) fav_put('active_saved', null, l, false, true);
// 1.x imported nodes were STORED LINKS: they lived on when their list died or dropped them. They
// stay so — favourites with their link, in the pool (active) — whether or not a source is
// configured; the source's "pick" section takes their ids in addition (review B1)
for (let l in as_list(M.imported_node, true)) { fav_put('imported_node', null, l, false, true); moved('imported_to_favorites'); }
// saved_node is the union of the two maps on a router; a link only there (a 1.x export imported,
// lost maps) is a favourite too — never dropped silently (review V3)
for (let l in as_list(M.saved_node, true)) if (!fav[id_of_link(l) ?? '']) fav_put('saved_node', null, l, false, false);
report.moved.favorites = length(fav);

// ---- hidden, preferred, auto-pool members, force-kept, unlock results ----
let hidden = [], hseen = {};
for (let l in as_list(M.excluded_node, true)) {
	let id = id_of_link(l);
	if (!id) { unmatched('excluded_node', l); continue; }
	if (!hseen[id]) { hseen[id] = true; push(hidden, id); }
}
for (let id in as_list(M.hidden, true)) if (is_id(id) && !hseen[id]) { hseen[id] = true; push(hidden, id); }
let pref = null;
if (length(M.selected_node ?? '')) pref = id_of_tag('selected_node', M.selected_node);
if (!pref && length(M.preferred_node ?? '')) pref = is_id(M.preferred_node) ? M.preferred_node : id_of_tag('preferred_node', M.preferred_node);
function ids_of_tags(store, v) {
	let r = [], seen = {};
	for (let t in as_list(v, false)) {
		let id = is_id(t) ? t : id_of_tag(store, t);
		if (id && !seen[id]) { seen[id] = true; push(r, id); }
	}
	return r;
}
let auto_member = ids_of_tags('auto_member', M.auto_member);
let keep_auto = ids_of_tags('keep_auto', M.keep_auto);
let unlock = read_json(CONF + '/unlock.map.json', null), unlock2 = null;
if (type(unlock) == 'object') {
	unlock2 = {};
	for (let t, v in unlock) { let id = is_id(t) ? t : id_of_tag('unlock', t); if (id) unlock2[id] = v; }
}

// ---- files first (recomputed identically on a re-run), the uci commit last ----
mkdir(CONF);
write_atomic(CONF + '/favorites.map.json', sprintf('%J', fav), 0600);
if (unlock2 != null) write_atomic(CONF + '/unlock.map.json', sprintf('%J', unlock2));
for (let a in awg_plan) {
	if (stat(a.to)) {   // the same key twice: the same node only when the files say the same
		let body_of = (t) => join('\n', filter(split(t ?? '', /\r?\n/), (l) => length(trim(l)) && !match(l, /^[ \t]*[#;]/)));
		if (body_of(readfile(a.to)) == body_of(a.body)) { unlink(a.from); moved('awg_duplicate_removed'); }
		else unmatched('awg_file', substr(a.from, length(AWG) + 1));   // left as it is (review M5)
		continue;
	}
	let t = a.to + '.tmp';
	writefile(t, '');
	chmod(t, 0600);
	if (writefile(t, a.body) != null && rename(t, a.to)) { unlink(a.from); moved('awg_renamed'); }
	else { unlink(t); unmatched('awg_file', a.from); }
}

let sids = [];
for (let s in subs) {
	let sid = sub_name_for(u, s.url);
	u.set('vpnpool', sid, 'subscription');
	u.set('vpnpool', sid, 'url', s.url);
	u.set('vpnpool', sid, 'enabled', s.enabled ? '1' : '0');
	u.set('vpnpool', sid, 'mode', s.mode);
	if (length(s.pick)) u.set('vpnpool', sid, 'pick', s.pick);
	push(sids, sid);
	moved(s.mode == 'pick' ? 'sources' : 'subscriptions');
}
// the quota / expiry of the 1.x primary subscription -> its meta
if (length(M.subscription_url ?? '') && length(sids)) {
	let exp = trim(readfile(CONF + '/sub.expire') ?? '');
	let us = split(trim(readfile(CONF + '/sub.usage') ?? ''), /[ \t]+/);
	let meta = read_json(CONF + '/subs.meta.json', {});
	if (type(meta) != 'object') meta = {};
	if (meta[sids[0]] == null && (match(exp, /^[0-9]+$/) || length(us) == 3)) {
		meta[sids[0]] = { expire: match(exp, /^[0-9]+$/) ? +exp : null,
			upload: (length(us) == 3) ? +us[0] : null, download: (length(us) == 3) ? +us[1] : null,
			total: (length(us) == 3) ? +us[2] : null, update_interval: null, title: null, web_page: null, support: null };
		write_atomic(CONF + '/subs.meta.json', sprintf('%J', meta));
	}
}

// subscription_ua (1.x: one client name; 1.4.1 kept it in uci but its fetch did not send it):
// a value of the user's own goes first in the list of client names the fetch tries (probe_ua)
let ua = trim('' + (M.subscription_ua ?? ''));
if (length(ua) && ua != 'v2rayNG/1.8.5' && !length(M.probe_ua ?? '')) {
	if (match(ua, /^[!-~]+$/)) { u.set('vpnpool', 'main', 'probe_ua', ua + ' ' + (getenv('VPNPOOL_DEFAULT_UAS') ?? '')); moved('subscription_ua'); }
	else unmatched('subscription_ua', ua);   // a name with spaces can't go into the space-separated list
}
for (let o in [ 'subscription_url', 'extra_sub', 'source', 'imported_node', 'saved_node', 'active_saved',
                'excluded_node', 'selected_node', 'subscription_ua', 'singbox_config', 'preferred_node',
                'auto_member', 'keep_auto', 'hidden', 'manual_node' ])
	u.delete('vpnpool', 'main', o);
if (length(manual)) u.set('vpnpool', 'main', 'manual_node', manual);
if (pref) u.set('vpnpool', 'main', 'preferred_node', pref);
if (length(auto_member)) u.set('vpnpool', 'main', 'auto_member', auto_member);
if (length(keep_auto)) u.set('vpnpool', 'main', 'keep_auto', keep_auto);
if (length(hidden)) u.set('vpnpool', 'main', 'hidden', hidden);
u.set('vpnpool', 'main', 'schema', SCHEMA);
report.moved.hidden = length(hidden);
report.moved.preferred = pref ? 1 : 0;
report.moved.auto_member = length(auto_member);
report.moved.keep_auto = length(keep_auto);
if (!u.commit('vpnpool')) {
	report.error = 'commit_failed';
	printf('%J\n', report);
	exit(1);
}

// committed: the report first (a power loss after this keeps the list of what did not match),
// then the 1.x files and the RAM state keyed by tag go
write_atomic(CONF + '/migration.json', sprintf('%J', report), 0600);   // unmatched links: credentials
for (let f in [ 'saved.map.json', 'snapshot.map.json', 'imported.map.json', 'sub.expire', 'sub.usage' ]) unlink(CONF + '/' + f);
for (let f in [ '.dead_tags.json', '.deadstrikes', '.nodedelay.json', '.status-cache.json', 'imported.links', 'active_saved.links' ]) unlink(RUN + '/' + f);
for (let f in (lsdir(TMP) ?? [])) unlink(TMP + '/' + f);
system('rmdir ' + sq(TMP) + ' 2>/dev/null');
printf('%J\n', report);
