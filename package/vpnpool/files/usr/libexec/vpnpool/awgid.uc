#!/usr/bin/ucode
// vpnpool 2.2.0: move the AmneziaWG / WireGuard node ids to the new identity (issue #7). Run by
// migrate.sh (lock, journal) — never on its own.
//
// Before 2.2.0 an AWG / WireGuard node id was sha256 of the client's private key alone, so a
// second server of the same client (one key for every server: 3x-ui, VPN providers) was refused
// as a duplicate. Now it is sha256 of the key + the server's public key + address + port
// (parser.uc awg_id). Every store keyed by id is moved from the old id to the new one:
//   /etc/vpnpool/awg/<id>.conf                 the file is renamed to its new id
//   uci main preferred_node, list auto_member / auto_exclude / keep_auto / hidden
//   uci subscription list pick                 (an AWG endpoint of a sing-box JSON subscription)
//   favorites.map.json, unlock.map.json        the keys
// Old id -> new id comes from the parser itself (--report --id-v1: both ids of every AWG record)
// over what this router stores: the AWG files, the favourites' outbounds and the cached
// subscriptions. A favourite with its own outbound gets the id of THAT outbound.
// Done: uci main awg_id_v '2' — the uci commit is the LAST step, so a run cut short is simply
// repeated (files already renamed and keys already moved are not matched again).
// Output: one JSON object {ok, moved:{files, ids, favorites, unlock}} on stdout; exit 0, 1 on failure.
'use strict';

import { readfile, writefile, lsdir, rename, stat, unlink, mkdir, chmod, popen } from 'fs';
import { cursor } from 'uci';
import { read_json, write_atomic, as_list, is_id, uniq, CONF_DIR, RUN_DIR, FAV_MAP } from './common.uc';

const PARSER = '/usr/libexec/vpnpool/parser.uc';
const AWG = CONF_DIR + '/awg';
const CACHE = CONF_DIR + '/sources_cache';
const UNLOCK = CONF_DIR + '/unlock.map.json';
const VER = '2';
const LISTS = [ 'auto_member', 'auto_exclude', 'keep_auto', 'hidden' ];

function sq(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function out(o) { printf('%J\n', o); }

let u = cursor();
if (u.get('vpnpool', 'main') == null) { out({ ok: true, nothing: true }); exit(0); }
if (u.get('vpnpool', 'main', 'awg_id_v') == VER) { out({ ok: true, done_before: true }); exit(0); }

// ---- the inputs, in priority order: the user's AWG files, the favourites, the subscriptions ----
let inputs = [];
for (let f in sort(lsdir(AWG) ?? []))
	if (match(f, /\.conf$/)) push(inputs, { path: AWG + '/' + f, kind: 'awg', file: f });
let fav = read_json(FAV_MAP, {});
if (type(fav) != 'object') fav = {};
let favkeys = [], favobs = [];
for (let k, e in fav)
	if (type(e?.ob) == 'object' && (e.ob.type == 'awg' || e.ob.type == 'wireguard')) { push(favkeys, k); push(favobs, e.ob); }
let tmp = null;
if (length(favobs)) {
	mkdir(RUN_DIR);
	tmp = sprintf('%s/.awgid.%s.json', RUN_DIR, uniq());
	if (writefile(tmp, '') == null) { out({ ok: false, error: 'tmp_write' }); exit(1); }
	chmod(tmp, 0600);   // the outbounds carry private keys
	writefile(tmp, sprintf('%J', favobs));
	push(inputs, { path: tmp, kind: 'fav' });
}
for (let f in sort(lsdir(CACHE) ?? []))
	if (match(f, /^s-.*\.raw$/)) push(inputs, { path: CACHE + '/' + f, kind: 'sub' });

let rep = [];
if (length(inputs)) {
	let p = popen(sprintf('ucode %s --report --id-v1 %s 2>/dev/null', PARSER, join(' ', map(inputs, (i) => sq(i.path)))), 'r');
	let raw = p ? p.read('all') : null;
	if (p) p.close();
	try { rep = json(raw ?? ''); } catch (e) { rep = null; }
}
if (tmp) unlink(tmp);
if (type(rep) != 'array') { out({ ok: false, error: 'parser_failed' }); exit(1); }

let idmap = {}, files = [], favnew = {};
for (let r in rep) {
	if (type(r) != 'object' || !is_id(r.id) || !is_id(r.id_v1)) continue;
	let inp = inputs[r.src];
	if (!inp) continue;
	if (r.id_v1 != r.id && idmap[r.id_v1] == null) idmap[r.id_v1] = r.id;   // the first input wins
	if (inp.kind == 'awg' && r.status == 'ok' && inp.file != r.id + '.conf') push(files, { from: inp.file, to: r.id + '.conf' });
	if (inp.kind == 'fav' && r.item != null && favkeys[r.item - 1] != null) favnew[favkeys[r.item - 1]] = r.id;
}
function mapped(id) { return idmap[id] ?? id; }

let moved = { files: 0, ids: 0, favorites: 0, unlock: 0 };

// ---- files first (a re-run finds them under the new name and moves nothing) ----
for (let f in files) {
	if (stat(AWG + '/' + f.to)) continue;   // a node with this id is stored already
	if (rename(AWG + '/' + f.from, AWG + '/' + f.to)) moved.files++;
}

// ---- the maps: keys (an entry under the new key already there wins) ----
if (length(favkeys) || length(idmap)) {
	let nf = {}, ch = false;
	for (let k, e in fav) {
		let nk = favnew[k] ?? mapped(k);
		if (nk != k) ch = true;
		if (nf[nk] == null || nk == k) nf[nk] = e;
	}
	if (ch) {
		if (!write_atomic(FAV_MAP, sprintf('%J', nf), 0600)) { out({ ok: false, error: 'favorites_write' }); exit(1); }
		moved.favorites = length(filter(keys(fav), (k) => (favnew[k] ?? mapped(k)) != k));
	}
}
let ul = read_json(UNLOCK, null);
if (type(ul) == 'object' && length(idmap)) {
	let nu = {}, n = 0;
	for (let k, v in ul) { let nk = mapped(k); if (nk != k) n++; if (nu[nk] == null || nk == k) nu[nk] = v; }
	if (n) {
		if (!write_atomic(UNLOCK, sprintf('%J', nu))) { out({ ok: false, error: 'unlock_write' }); exit(1); }
		moved.unlock = n;
	}
}

// ---- uci: the id options and lists, then the mark — ONE commit, the last step ----
function map_list(sect, opt) {
	let l = as_list(u.get('vpnpool', sect, opt), true);
	if (!length(l)) return;
	let r = [], seen = {}, n = 0;
	for (let x in l) {
		let y = mapped(x);
		if (y != x) n++;
		if (!seen[y]) { seen[y] = true; push(r, y); }
	}
	if (n) { u.set('vpnpool', sect, opt, r); moved.ids += n; }
}
let pn = u.get('vpnpool', 'main', 'preferred_node');
if (type(pn) == 'string' && mapped(pn) != pn) { u.set('vpnpool', 'main', 'preferred_node', mapped(pn)); moved.ids++; }
for (let o in LISTS) map_list('main', o);
u.foreach('vpnpool', 'subscription', function(s) { map_list(s['.name'], 'pick'); });
u.set('vpnpool', 'main', 'awg_id_v', VER);
if (!u.commit('vpnpool')) { out({ ok: false, error: 'uci_commit' }); exit(1); }

out({ ok: true, moved: moved });
exit(0);
