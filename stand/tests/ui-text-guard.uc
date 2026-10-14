#!/usr/bin/ucode
// UI text guard: extract every string a human sees in luci-app-vpnpool and flag technical
// words from a stop-list. Current violations live in a baseline that may only SHRINK.
//
// usage: ucode ui-text-guard.uc <luci-app-root> <stoplist> <baseline|-> [--write-baseline <file>]
//   <luci-app-root> = package/luci-app-vpnpool (or a fixture tree with the same layout)
// Sources of human-visible text:
//   - _('…') / _("…") / _(`…`) literals in files/www/luci-static/resources/view/**/*.js
//   - every literal inside `var DICT = {…};` in files/www/luci-static/resources/vpnpool/i18n.js
//   - "title" of files/usr/share/luci/menu.d/*.json
//   - msgid/msgstr of po/**/*.po (when the app moves to LuCI po, ROADMAP 10.8)
// Output: "STRINGS n", "VIOLATIONS n", "NEW <line>", "GONE <line>", "VERDICT ok|fail".
// Exit: 0 = exactly the baseline; 1 = new violation(s); 3 = no new, but baseline lines that no
//       longer occur (shrink the baseline); 2 = usage/scan error.
'use strict';

import { readfile, writefile, lsdir, stat } from 'fs';

if (length(ARGV) < 3) { warn('usage: ui-text-guard.uc <app-root> <stoplist> <baseline|-> [--write-baseline <file>]\n'); exit(2); }
let ROOT = ARGV[0], STOP = ARGV[1], BASE = ARGV[2];
let WRITE = (length(ARGV) >= 5 && ARGV[3] == '--write-baseline') ? ARGV[4] : null;

function walk(dir, suffix, out) {
	let ents = lsdir(dir);
	if (!ents) return out;
	for (let e in sort(ents)) {
		let p = dir + '/' + e, st = stat(p);
		if (!st) continue;
		if (st.type == 'directory') walk(p, suffix, out);
		else if (substr(e, -length(suffix)) == suffix) push(out, p);
	}
	return out;
}

// read one JS string literal starting at s[i] (a quote). Returns [text, next_index] or null.
function read_lit(s, i) {
	let q = substr(s, i, 1), out = '', n = length(s);
	i++;
	while (i < n) {
		let c = substr(s, i, 1);
		if (c == '\\') {
			let d = substr(s, i + 1, 1);
			out += (d == 'n') ? ' ' : (d == 't') ? ' ' : d;
			i += 2; continue;
		}
		if (c == q) return [out, i + 1];
		if (c == '\n' && q != '`') return null;
		out += c; i++;
	}
	return null;
}

let strings = [];   // [{file, text}]
function add(file, text) {
	text = trim(replace(text, /[\r\n\t]+/g, ' '));
	if (length(text)) push(strings, { file, text });
}
function rel(p) { return substr(p, 0, length(ROOT)) == ROOT ? 'luci-app-vpnpool' + substr(p, length(ROOT)) : p; }

// 1) _('…') in views
let views = walk(ROOT + '/files/www/luci-static/resources/view', '.js', []);
for (let f in views) {
	let s = readfile(f) ?? '';
	let i = 0;
	while (true) {
		let k = index(substr(s, i), '_(');
		if (k < 0) break;
		let j = i + k + 2;
		// only the gettext call, not identifiers ending in "_" (e.g. foo_(x))
		let prev = (i + k > 0) ? substr(s, i + k - 1, 1) : ' ';
		i = j;
		if (match(prev, /[A-Za-z0-9_$.]/)) continue;
		while (match(substr(s, j, 1), /[ \t\r\n]/)) j++;
		let q = substr(s, j, 1);
		if (q != "'" && q != '"' && q != '`') continue;
		let r = read_lit(s, j);
		if (r) { add(rel(f), r[0]); i = r[1]; }
	}
}

// 2) the in-app dictionary (keys = English UI text, values = Russian UI text)
for (let f in walk(ROOT + '/files/www/luci-static/resources/vpnpool', 'i18n.js', [])) {
	let s = readfile(f) ?? '';
	let a = index(s, 'var DICT');
	if (a < 0) continue;
	let b = index(substr(s, a), '\n};');
	let reg = (b < 0) ? substr(s, a) : substr(s, a, b);
	let i = 0, n = length(reg);
	while (i < n) {
		let c = substr(reg, i, 1);
		if (c == '/' && substr(reg, i + 1, 1) == '/') { let e = index(substr(reg, i), '\n'); i = (e < 0) ? n : i + e; continue; }
		if (c == "'" || c == '"') {
			let r = read_lit(reg, i);
			if (r) { add(rel(f), r[0]); i = r[1]; continue; }
		}
		i++;
	}
}

// 3) menu titles
for (let f in walk(ROOT + '/files/usr/share/luci/menu.d', '.json', [])) {
	let m = json(readfile(f) ?? '{}');
	if (type(m) == 'object') for (let k, v in m) if (type(v) == 'object' && type(v.title) == 'string') add(rel(f), v.title);
}

// 4) po files (future)
for (let f in walk(ROOT + '/po', '.po', [])) {
	let cur = null, buf = '';
	for (let line in split(readfile(f) ?? '', '\n')) {
		let m = match(line, /^(msgid|msgstr) "(.*)"$/);
		if (m) { if (cur) add(rel(f), buf); cur = m[1]; buf = m[2]; continue; }
		let c = match(line, /^"(.*)"$/);
		if (c && cur) { buf += c[1]; continue; }
		if (cur) { add(rel(f), buf); cur = null; buf = ''; }
	}
	if (cur) add(rel(f), buf);
}

// stop-list
let pats = [];
for (let line in split(readfile(STOP) ?? '', '\n')) {
	line = trim(line);
	if (!length(line) || substr(line, 0, 1) == '#') continue;
	let t = index(line, '\t');
	if (t < 0) continue;
	let name = substr(line, 0, t), re = trim(substr(line, t + 1));
	re = replace(re, /<([^>]+)>/g, (m, w) => '(^|[^a-z0-9])(' + w + ')([^a-z0-9_]|$)');
	let rx = regexp(re, 'i');
	push(pats, { name, rx });
}
if (!length(pats)) { warn('ui-text-guard: empty stop-list\n'); exit(2); }

let viol = {};
for (let s in strings)
	for (let p in pats)
		if (match(s.text, p.rx)) viol[s.file + '\t' + p.name + '\t' + s.text] = true;

let cur = sort(keys(viol));
printf("STRINGS %d\nPATTERNS %d\nVIOLATIONS %d\n", length(strings), length(pats), length(cur));

if (WRITE) {
	writefile(WRITE, '# UI text guard baseline — known violations; may only SHRINK (see stand/tests/ui-text-guard.sh)\n' + join('\n', cur) + (length(cur) ? '\n' : ''));
	printf("WROTE %s\n", WRITE);
}

let base = {};
if (BASE != '-') {
	let raw = readfile(BASE);
	if (raw == null) { warn('ui-text-guard: cannot read baseline ' + BASE + '\n'); exit(2); }
	for (let l in split(raw, '\n')) if (length(l) && substr(l, 0, 1) != '#') base[l] = true;
}
let nnew = 0;
for (let v in cur) if (!base[v]) { nnew++; printf("NEW %s\n", v); }
// A baseline line whose violation is gone must be deleted in the same change: a stale line
// would silently re-allow that very violation later. So GONE fails too (exit 3).
let ngone = 0;
for (let v in sort(keys(base))) if (!viol[v]) { ngone++; printf("GONE %s   <- fixed: delete this line from the baseline (ui-text-guard.sh --update-baseline)\n", v); }
printf("NEW_COUNT %d\nGONE_COUNT %d\nVERDICT %s\n", nnew, ngone, (nnew || ngone) ? 'fail' : 'ok');
exit(nnew ? 1 : (ngone ? 3 : 0));
