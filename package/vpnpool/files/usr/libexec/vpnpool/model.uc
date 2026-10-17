#!/usr/bin/ucode
// vpnpool data model for the shell scripts (ROADMAP 9; the stores are described in common.uc).
//   ucode model.uc subs                    every subscription: "<id>\t<1|0 enabled>\t<all|pick>\t<url>"
//   ucode model.uc pick <sub id>           the ids a "pick" subscription takes, one per line
//   ucode model.uc hidden                  the ids the user hid, one per line
//   ucode model.uc fav-active <links> <json>  the favourites that join the pool from the archive
//                                          (active): their links -> <links>, outbounds -> <json>
//   ucode model.uc resolve <id|tag>        "<id>\t<tag>" of a node of the last build (exit 1: none)
//   ucode model.uc resolve-any <id|tag>    the same, a favourite outside the pool included
//   ucode model.uc snapshot <max>          stdin = the clash /proxies answer: the <max> fastest
//                                          working nodes become automatic favourites (the user's
//                                          own favourites are never touched)
'use strict';

import { writefile, stdin } from 'fs';
import { cursor } from 'uci';
import { as_list, is_id, subs_of, fav_read, fav_write, live_nodes, node_lookup, link_of } from './common.uc';

let cmd = ARGV[0];
let u = cursor();

if (cmd == 'subs') {
	for (let s in subs_of(u))
		if (length(s.url)) printf('%s\t%s\t%s\t%s\n', s.id, s.enabled ? '1' : '0', s.mode, s.url);
} else if (cmd == 'pick') {
	for (let s in subs_of(u)) if (s.id == ARGV[1]) for (let i in s.pick) print(i, '\n');
} else if (cmd == 'hidden') {
	for (let i in as_list(u.get('vpnpool', 'main', 'hidden'), true)) if (is_id(i)) print(i, '\n');
} else if (cmd == 'fav-active') {
	let links = [], obs = [];
	for (let id, f in fav_read()) {
		if (type(f) != 'object' || f.active !== true) continue;
		if (type(f.link) == 'string' && length(f.link)) push(links, f.link);
		else if (type(f.ob) == 'object') { let o = { ...f.ob }; o.tag = f.tag ?? o.tag; push(obs, o); }
	}
	writefile(ARGV[1], length(links) ? join('\n', links) + '\n' : '');
	writefile(ARGV[2], length(obs) ? sprintf('%J\n', obs) : '');
} else if (cmd == 'resolve' || cmd == 'resolve-any') {
	// resolve: a node of the last build; resolve-any: a favourite outside the pool too
	let r = node_lookup(ARGV[1]);
	if (!r || (!r.node && cmd == 'resolve')) exit(1);
	printf('%s\t%s\n', r.id, r.tag ?? '');
} else if (cmd == 'snapshot') {
	let max = int(ARGV[1] ?? 20) || 20;
	let p = null;
	try { p = json(stdin.read('all') ?? ''); } catch (e) { p = null; }
	let px = (type(p) == 'object' && type(p.proxies) == 'object') ? p.proxies : {};
	let alive = [];
	for (let n in live_nodes()) {
		if (n._deferred || !n.id) continue;
		let h = px[n.tag]?.history ?? [];
		let d = length(h) ? (h[length(h) - 1]?.delay ?? 0) : 0;
		if (d > 0) push(alive, { n: n, d: d });
	}
	alive = sort(alive, (a, b) => a.d - b.d);
	// nothing answers (the provider is down, sing-box just restarted, the subscription expired):
	// the fallback set is kept as it is — that is the moment it exists for (1.x did the same)
	if (!length(alive)) { print('0\n'); exit(0); }
	let fav = fav_read(), now = time(), kept = 0;
	// the automatic entries are replaced wholesale; the user's own ones stay as they are, and so
	// does an automatic one the user connected / put into the pool (active)
	for (let id in keys(fav)) if (fav[id]?.auto === true && fav[id]?.active !== true) delete fav[id];
	for (let x in alive) {
		if (kept >= max) break;
		let id = x.n.id;
		if (fav[id] != null) continue;
		let p0 = (type(x.n.peers) == 'array') ? x.n.peers[0] : null;
		let e = { tag: x.n.tag, link: link_of(id), active: false, auto: true, at: now,
			type: x.n.type, server: x.n.server ?? p0?.address, port: x.n.server_port ?? p0?.port };
		if (e.link == null && x.n.type != 'awg' && x.n.type != 'wireguard') {
			let o = { ...x.n };
			delete o.id; for (let k in keys(o)) if (substr(k, 0, 1) == '_') delete o[k];
			e.ob = o;
		}
		fav[id] = e; kept++;
	}
	if (!fav_write(fav)) exit(1);
	print(kept, '\n');
} else {
	warn('usage: model.uc subs | pick <id> | hidden | fav-active <links> <json> | resolve <id|tag> | snapshot <max>\n');
	exit(2);
}
