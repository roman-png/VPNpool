#!/usr/bin/ucode
// vpnpool data model for the shell scripts (ROADMAP 9; the stores are described in common.uc).
//   ucode model.uc subs                    every subscription: "<id>\t<1|0 enabled>\t<all|pick>\t<url>"
//   ucode model.uc subhdr                  the device headers of a subscription download (issue #5) as a
//                                          curl -K config (common.uc sub_headers; empty = none)
//   ucode model.uc uas                     the client names (User-Agents) of a subscription download, one
//                                          per line, in order (common.uc sub_uas)
//   ucode model.uc ua                      the client name set in Settings (uci sub_ua), or nothing
//   ucode model.uc why <http> <rc> <body> [<prev>]  why a download gave no nodes (issue #11; common.uc
//                                          sub_why) as JSON; with <prev> (a file of an earlier
//                                          answer of this command) the more telling of the two
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

import { writefile, stdin, readfile } from 'fs';
import { cursor } from 'uci';
import { as_list, is_id, subs_of, fav_read, fav_write, live_nodes, node_lookup, link_of, sub_headers, sub_uas, UA_RE,
	sub_report, sub_why, sub_why_better } from './common.uc';

let cmd = ARGV[0];
let u = cursor();

if (cmd == 'subhdr') {
	// a curl -K config: one `header = "..."` line per device header (empty: send none)
	for (let h in sub_headers(u)) print('header = "', h, '"
');
} else if (cmd == 'uas') {
	for (let a in sub_uas(u)) print(a, '\n');
} else if (cmd == 'ua') {
	let a = trim('' + (u.get('vpnpool', 'main', 'sub_ua') ?? ''));
	if (length(a) && match(a, UA_RE)) print(a, '\n');
} else if (cmd == 'why') {
	// the parser runs only on an answer that came whole (no network failure, no HTTP error)
	let whole = ARGV[1] != '000' && +ARGV[1] < 400 && ('' + (ARGV[2] ?? '0')) == '0';
	let w = sub_why(ARGV[1], ARGV[2], whole ? sub_report(ARGV[3]) : null);
	let prev = null;
	if (length(ARGV[4] ?? '')) try { prev = json(readfile(ARGV[4]) ?? ''); } catch (e) { prev = null; }
	printf('%J\n', sub_why_better(type(prev) == 'object' ? prev : null, w));
} else if (cmd == 'subs') {
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
