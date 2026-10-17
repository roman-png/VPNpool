#!/usr/bin/ucode
// i18n check / sync for luci-app-vpnpool (standard LuCI po, ROADMAP-2.0 §10.8).
//
// usage: ucode ui-i18n.uc <luci-app-root> check   -> verdict, exit 0 ok / 1 fail / 2 usage
//        ucode ui-i18n.uc <luci-app-root> sync    -> rewrite po/templates/vpnpool.pot from the
//                                                    sources and merge it into every po/<lang>/
//                                                    vpnpool.po (keeps translations, adds new
//                                                    msgids untranslated, drops obsolete ones)
// msgid sources (what LuCI translates for this app):
//   - _('…') and N_(n, '…', '…') literals in files/www/luci-static/resources/**/*.js
//     (not *.min.js, not view/**/_*.js = temporary stand pages)
//   - "title" of files/usr/share/luci/menu.d/*.json (the dispatcher translates menu titles)
//   - "description" of files/usr/share/rpcd/acl.d/*.json
// A msgid is normalized exactly like LuCI's _() does before hashing (cbi.js trimws: trim,
// runs of space/tab/newline -> one space); otherwise the lookup hash never matches.
// check fails on: pot out of date (missing/stale msgid), a po without some msgid, an obsolete
// or duplicate msgid in a po, an untranslated msgid, a msgstr whose %-placeholders differ
// from the msgid, a msgid with a character outside the BMP (cbi.js sfh() hashes UTF-16
// surrogates as two 3-byte sequences, po2lmo hashes 4-byte UTF-8: such a msgid is never
// translated), a po header without UTF-8 charset or Plural-Forms.
'use strict';

import { readfile, writefile, lsdir, stat, mkdir } from 'fs';

if (length(ARGV) < 2) { warn('usage: ui-i18n.uc <app-root> check|sync\n'); exit(2); }
let ROOT = ARGV[0], MODE = ARGV[1];
if (MODE != 'check' && MODE != 'sync') { warn('usage: ui-i18n.uc <app-root> check|sync\n'); exit(2); }
let DOMAIN = 'vpnpool';
let POT = ROOT + '/po/templates/' + DOMAIN + '.pot';

// Known msgids with a non-BMP character, already in a view before this check existed. The
// screen packs rewrite these strings; the list may only shrink.
let NONBMP_KNOWN = {
};

function walk(dir, out) {
	let ents = lsdir(dir);
	if (!ents) return out;
	for (let e in sort(ents)) {
		let p = dir + '/' + e, st = stat(p);
		if (!st) continue;
		if (st.type == 'directory') walk(p, out);
		else push(out, p);
	}
	return out;
}
function rel(p) { return substr(p, 0, length(ROOT) + 1) == ROOT + '/' ? substr(p, length(ROOT) + 1) : p; }
function norm(s) { return trim(replace(s, /[ \t\n]+/g, ' ')); }
function line_of(s, i) { let n = 1; for (let k = 0; k < i; k++) if (substr(s, k, 1) == '\n') n++; return n; }

function utf8(cp) {
	if (cp < 0x80) return chr(cp);
	if (cp < 0x800) return chr(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
	return chr(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
}

// JS string literal at s[i] (quote char) -> [text, next] or null
function read_lit(s, i) {
	let q = substr(s, i, 1), out = '', n = length(s);
	i++;
	while (i < n) {
		let c = substr(s, i, 1);
		if (c == '\\') {
			let d = substr(s, i + 1, 1);
			if (d == 'n') out += '\n';
			else if (d == 't') out += '\t';
			else if (d == 'r') out += '\r';
			else if (d == 'u' && match(substr(s, i + 2, 4), /^[0-9a-fA-F]{4}$/)) { out += utf8(hex(substr(s, i + 2, 4))); i += 6; continue; }
			else if (d == '\n') out += '';
			else out += d;
			i += 2; continue;
		}
		if (c == q) return [ out, i + 1 ];
		if (c == '\n' && q != '`') return null;
		if (c == '$' && q == '`' && substr(s, i + 1, 1) == '{') return null;   // template with ${} is not a msgid
		out += c; i++;
	}
	return null;
}
function skip_ws(s, j) { while (match(substr(s, j, 1), /^[ \t\r\n]$/)) j++; return j; }

let order = [], ids = {};   // msgid -> { id, plural, refs[] }
let errors = [];
function add_id(id, plural, ref) {
	id = norm(id);
	if (!length(id)) return;
	if (plural != null) plural = norm(plural);
	if (!ids[id]) { ids[id] = { id, plural, refs: [] }; push(order, id); }
	else if (plural != null && ids[id].plural == null) ids[id].plural = plural;
	push(ids[id].refs, ref);
}

// 1) JS
let jsroot = ROOT + '/files/www/luci-static/resources';
for (let f in walk(jsroot, [])) {
	if (substr(f, -3) != '.js' || substr(f, -7) == '.min.js') continue;
	let base = split(f, '/'); base = base[length(base) - 1];
	if (match(rel(f), /\/view\//) && substr(base, 0, 1) == '_') continue;
	let s = readfile(f) ?? '';
	let i = 0;
	while (true) {
		let k = index(substr(s, i), '_(');
		if (k < 0) break;
		let at = i + k, j = at + 2;
		i = j;
		let isN = (at > 0 && substr(s, at - 1, 1) == 'N');
		let prev = isN ? ((at > 1) ? substr(s, at - 2, 1) : ' ') : ((at > 0) ? substr(s, at - 1, 1) : ' ');
		if (match(prev, /[A-Za-z0-9_$.]/)) continue;
		if (isN) {   // N_(n, 'singular', 'plural')
			let d = 0, p = j;
			while (p < length(s)) { let c = substr(s, p, 1); if (c == '(') d++; else if (c == ')') { if (!d) break; d--; } else if (c == ',' && !d) break; p++; }
			if (substr(s, p, 1) != ',') continue;
			j = skip_ws(s, p + 1);
			let q = substr(s, j, 1);
			if (q != "'" && q != '"' && q != '`') continue;
			let r1 = read_lit(s, j); if (!r1) continue;
			let p2 = skip_ws(s, r1[1]);
			if (substr(s, p2, 1) != ',') continue;
			p2 = skip_ws(s, p2 + 1);
			let r2 = read_lit(s, p2); if (!r2) continue;
			add_id(r1[0], r2[0], rel(f) + ':' + line_of(s, at));
			i = r2[1];
			continue;
		}
		j = skip_ws(s, j);
		let q = substr(s, j, 1);
		if (q != "'" && q != '"' && q != '`') continue;
		let r = read_lit(s, j);
		if (r) { add_id(r[0], null, rel(f) + ':' + line_of(s, at)); i = r[1]; }
	}
}
// 2) menu titles, 3) ACL descriptions
for (let f in walk(ROOT + '/files/usr/share/luci/menu.d', [])) {
	let m = json(readfile(f) ?? '{}');
	if (type(m) == 'object') for (let k in sort(keys(m))) if (type(m[k]) == 'object' && type(m[k].title) == 'string') add_id(m[k].title, null, rel(f));
}
for (let f in walk(ROOT + '/files/usr/share/rpcd/acl.d', [])) {
	let m = json(readfile(f) ?? '{}');
	if (type(m) == 'object') for (let k in sort(keys(m))) if (type(m[k]) == 'object' && type(m[k].description) == 'string') add_id(m[k].description, null, rel(f));
}

// ---- po reading / writing
function po_unq(s) {   // body of a "…" po string -> text
	let out = '', i = 0, n = length(s);
	while (i < n) {
		let c = substr(s, i, 1);
		if (c == '\\' && i + 1 < n) {
			let d = substr(s, i + 1, 1);
			out += (d == 'n') ? '\n' : (d == 't') ? '\t' : d;
			i += 2; continue;
		}
		out += c; i++;
	}
	return out;
}
function po_q(s) {
	s = replace(s, /\\/g, '\\\\');
	s = replace(s, /"/g, '\\"');
	s = replace(s, /\n/g, '\\n');
	s = replace(s, /\t/g, '\\t');
	return '"' + s + '"';
}
// -> { header, entries: [{id, plural, str: [..], ctxt}], errs: [] }
function po_read(path) {
	let raw = readfile(path);
	if (raw == null) return null;
	let res = { header: null, entries: [], errs: [] };
	let cur = null, field = null;
	function flush() {
		if (!cur) return;
		if (cur.id == null) push(res.errs, 'entry without msgid near "' + (cur.str[0] ?? '') + '"');
		else if (cur.id == '') res.header = cur.str[0] ?? '';
		else push(res.entries, cur);
		cur = null; field = null;
	}
	let ln = 0;
	for (let line in split(raw, '\n')) {
		ln++;
		line = rtrim(line, '\r');
		if (!length(trim(line))) { flush(); continue; }
		if (substr(line, 0, 1) == '#') { if (cur && length(cur.str)) flush(); continue; }
		let m;
		if ((m = match(line, /^msgctxt "(.*)"$/))) { flush(); cur = { ctxt: po_unq(m[1]), id: null, plural: null, str: [] }; field = 'ctxt'; continue; }
		if ((m = match(line, /^msgid "(.*)"$/))) {
			if (cur && cur.id != null) flush();
			if (!cur) cur = { ctxt: null, id: null, plural: null, str: [] };
			cur.id = po_unq(m[1]); field = 'id'; continue;
		}
		if ((m = match(line, /^msgid_plural "(.*)"$/)) && cur) { cur.plural = po_unq(m[1]); field = 'plural'; continue; }
		if ((m = match(line, /^msgstr "(.*)"$/)) && cur) { cur.str[0] = po_unq(m[1]); field = 0; continue; }
		if ((m = match(line, /^msgstr\[([0-9])\] "(.*)"$/)) && cur) { cur.str[+m[1]] = po_unq(m[2]); field = +m[1]; continue; }
		if ((m = match(line, /^"(.*)"$/)) && cur && field != null) {
			let t = po_unq(m[1]);
			if (field == 'id') cur.id += t; else if (field == 'plural') cur.plural += t; else if (field == 'ctxt') cur.ctxt += t; else cur.str[field] += t;
			continue;
		}
		push(res.errs, sprintf('%s:%d: cannot parse: %s', rel(path), ln, line));
	}
	flush();
	return res;
}
function entry_text(e) {
	let s = '';
	for (let r in e.refs ?? []) s += '#: ' + r + '\n';
	s += 'msgid ' + po_q(e.id) + '\n';
	if (e.plural != null) {
		s += 'msgid_plural ' + po_q(e.plural) + '\n';
		let n = max(2, length(e.str ?? []));
		for (let k = 0; k < n; k++) s += sprintf('msgstr[%d] %s\n', k, po_q((e.str ?? [])[k] ?? ''));
	}
	else s += 'msgstr ' + po_q((e.str ?? [])[0] ?? '') + '\n';
	return s;
}
function header_text(h) { return 'msgid ""\nmsgstr ""\n' + join('', map(split(h, '\n'), (l, i) => length(l) ? po_q(l + '\n') + '\n' : '')); }

let POT_HEADER = 'Content-Type: text/plain; charset=UTF-8';

// ---- placeholders: printf-style specifiers as LuCI's String.format knows them
function specs(s) {
	let out = [];
	let t = replace(s, /%%/g, '');
	let m = match(t, /%[-+ #0]*[0-9]*(\.[0-9]+)?[sdifxXoqhtmb]/g);
	for (let x in (m ?? [])) push(out, replace(x[0], /[^a-zA-Z]/g, ''));
	return join(',', out);
}
function has_nonbmp(s) {
	for (let i = 0; i < length(s); i++) if (ord(s, i) >= 0xF0) return true;   // 4-byte UTF-8 lead byte
	return false;
}

let langs = [];
for (let e in sort(lsdir(ROOT + '/po') ?? [])) if (e != 'templates' && stat(ROOT + '/po/' + e)?.type == 'directory') push(langs, e);

if (MODE == 'sync') {
	mkdir(ROOT + '/po'); mkdir(ROOT + '/po/templates');
	let txt = header_text(POT_HEADER) + '\n';
	for (let id in order) txt += entry_text(ids[id]) + '\n';
	writefile(POT, rtrim(txt, '\n') + '\n');
	printf("WROTE %s (%d msgids)\n", rel(POT), length(order));
	for (let l in langs) {
		let path = ROOT + '/po/' + l + '/' + DOMAIN + '.po';
		let po = po_read(path) ?? { header: 'Content-Type: text/plain; charset=UTF-8\nLanguage: ' + l + '\n', entries: [], errs: [] };
		let have = {};
		for (let e in po.entries) if (e.ctxt == null) have[e.id] = e;
		let out = header_text(po.header) + '\n', kept = 0, added = 0, dropped = 0;
		for (let id in order) {
			let e = ids[id], old = have[id];
			if (old) kept++; else added++;
			out += entry_text({ id, plural: e.plural, refs: e.refs, str: old ? old.str : [] }) + '\n';
		}
		for (let e in po.entries) if (!ids[e.id]) dropped++;
		writefile(path, rtrim(out, '\n') + '\n');
		printf("WROTE %s kept=%d added=%d dropped=%d\n", rel(path), kept, added, dropped);
	}
	exit(0);
}

// ---- check
let fails = 0;
function bad(kind, msg) { fails++; printf("FAIL %s %s\n", kind, msg); }
let nonbmp = 0, known = 0;
for (let id in order) {
	if (has_nonbmp(id)) {
		if (NONBMP_KNOWN[id]) { known++; printf("KNOWN nonbmp %s\n", id); }
		else { nonbmp++; bad('nonbmp', id + '   (' + join(' ', ids[id].refs) + ')'); }
	}
}
for (let k in keys(NONBMP_KNOWN)) if (!ids[k]) bad('nonbmp-known-gone', k + '   <- delete it from NONBMP_KNOWN in ui-i18n.uc');

let pot = po_read(POT);
let potn = 0;
if (!pot) bad('pot-missing', rel(POT));
else {
	for (let e in pot.errs) bad('pot-syntax', e);
	let pid = {};
	for (let e in pot.entries) { potn++; if (pid[e.id]) bad('pot-duplicate', e.id); pid[e.id] = true; if (!ids[e.id]) bad('pot-stale', e.id + '   <- not in the sources any more (run: ui-i18n.sh sync)'); }
	for (let id in order) if (!pid[id]) bad('pot-missing-msgid', id + '   (' + join(' ', ids[id].refs) + ')   <- run: ui-i18n.sh sync');
}
let checked = 0, translated = 0;
if (!length(langs)) bad('no-language', 'no po/<lang>/ directory');
for (let l in langs) {
	let path = ROOT + '/po/' + l + '/' + DOMAIN + '.po';
	let po = po_read(path);
	if (!po) { bad('po-missing', rel(path)); continue; }
	for (let e in po.errs) bad('po-syntax', e);
	let h = po.header ?? '';
	if (!match(h, /Content-Type: text\/plain; charset=UTF-8/)) bad('po-header', rel(path) + ': no "Content-Type: text/plain; charset=UTF-8"');
	if (!match(h, /Plural-Forms: nplurals=[0-9]+; plural=/)) bad('po-header', rel(path) + ': no Plural-Forms');
	let seen = {};
	for (let e in po.entries) {
		checked++;
		let id = e.id;
		if (e.ctxt != null) { bad('po-context', l + ': ' + id + ' (msgctxt is not used by this app)'); continue; }
		if (seen[id]) bad('po-duplicate', l + ': ' + id);
		seen[id] = true;
		if (!ids[id]) { bad('po-obsolete', l + ': ' + id + '   <- run: ui-i18n.sh sync'); continue; }
		if (norm(id) != id) bad('po-not-normalized', l + ': "' + id + '"');
		let strs = e.str ?? [];
		let empty = !length(strs) || length(filter(strs, s => !length(s ?? '')));
		if (empty) { bad('untranslated', l + ': ' + id); continue; }
		translated++;
		let want = specs(id);
		for (let k = 0; k < length(strs); k++) {
			let src = (e.plural != null && k > 0) ? e.plural : id;
			if (specs(strs[k]) != specs(src) && !(e.plural != null && specs(strs[k]) == specs(id)))
				bad('placeholders', sprintf('%s: "%s" [%s] -> "%s" [%s]', l, src, specs(src), strs[k], specs(strs[k])));
		}
	}
	for (let id in order) if (!seen[id]) bad('po-missing-msgid', l + ': ' + id + '   <- run: ui-i18n.sh sync, then translate');
}

printf("I18N: msgids=%d pot=%d languages=%d checked=%d translated=%d nonbmp_known=%d failed=%d\n",
	length(order), potn, length(langs), checked, translated, known, fails);
// zero checked is a failure, never a pass (a scan that found nothing proves nothing)
if (!length(order) || !checked) { printf("FAIL nothing-checked msgids=%d checked=%d\n", length(order), checked); fails++; }
printf("VERDICT %s\n", fails ? 'fail' : 'ok');
exit(fails ? 1 : 0);
