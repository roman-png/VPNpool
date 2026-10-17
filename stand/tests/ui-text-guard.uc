#!/usr/bin/ucode
// UI text guard: extract every string a human sees in luci-app-vpnpool and flag technical
// words from a stop-list. Current violations live in a baseline that may only SHRINK.
//
// usage: ucode ui-text-guard.uc <luci-app-root> <stoplist> <baseline|-> [--write-baseline <file>]
//   <luci-app-root> = package/luci-app-vpnpool (or a fixture tree with the same layout)
// Sources of human-visible text, in this order:
//   - _('…') / _("…") / _(`…`) literals in files/www/luci-static/resources/**/*.js (views AND
//     the shared modules such as vpnpool/common.js; not *.min.js)
//   - every literal inside `var DICT = {…};` in files/www/luci-static/resources/vpnpool/i18n.js
//   - "title" of files/usr/share/luci/menu.d/*.json, "description" of files/usr/share/rpcd/acl.d/*.json
//   - msgid/msgid_plural/msgstr of po/**/*.po (LuCI po, ROADMAP 10.8; the header is not UI text)
// A po string that already occurs in an earlier source is not counted again: a po msgid is
// the very string of its _() call site (and a msgstr carried over from the DICT is the DICT
// value), so moving the dictionary into po neither hides nor duplicates a violation; the
// other sources are counted per file as before. Whitespace is collapsed like LuCI's _() does
// (trim + runs of space/tab/newline -> one space).
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
let seen_text = {};
function add(file, text, catalog) {
	text = trim(replace(text, /[\r\n\t ]+/g, ' '));
	if (!length(text) || (catalog && seen_text[text])) return;
	seen_text[text] = true;
	push(strings, { file, text });
}
function rel(p) { return substr(p, 0, length(ROOT)) == ROOT ? 'luci-app-vpnpool' + substr(p, length(ROOT)) : p; }

// 1) _('…') in views and shared modules
let views = filter(walk(ROOT + '/files/www/luci-static/resources', '.js', []), (f) => substr(f, -7) != '.min.js');
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

// 3) menu titles, ACL descriptions
for (let f in walk(ROOT + '/files/usr/share/luci/menu.d', '.json', [])) {
	let m = json(readfile(f) ?? '{}');
	if (type(m) == 'object') for (let k, v in m) if (type(v) == 'object' && type(v.title) == 'string') add(rel(f), v.title);
}
for (let f in walk(ROOT + '/files/usr/share/rpcd/acl.d', '.json', [])) {
	let m = json(readfile(f) ?? '{}');
	if (type(m) == 'object') for (let k, v in m) if (type(v) == 'object' && type(v.description) == 'string') add(rel(f), v.description);
}

// 4) po files: msgid, msgid_plural, msgstr, msgstr[N]; po escapes undone; the header (the
//    msgstr of msgid "") is metadata, not UI text
function po_unq(s) {
	return replace(s, /\\(.)/g, (m, c) => (c == 'n' || c == 't') ? ' ' : c);
}
for (let f in walk(ROOT + '/po', '.po', [])) {
	let cur = null, buf = '', id = null;
	let flush = () => {
		if (cur == null) return;
		if (cur == 'msgid') id = buf;
		if (!(substr(cur, 0, 6) == 'msgstr' && id == '')) add(rel(f), po_unq(buf), true);
		cur = null; buf = '';
	};
	for (let line in split(readfile(f) ?? '', '\n')) {
		line = rtrim(line, '\r');
		let m = match(line, /^(msgid|msgid_plural|msgstr|msgstr\[[0-9]+\]) "(.*)"$/);
		if (m) { flush(); cur = m[1]; buf = m[2]; continue; }
		let c = match(line, /^"(.*)"$/);
		if (c && cur != null) { buf += c[1]; continue; }
		flush();
	}
	flush();
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
