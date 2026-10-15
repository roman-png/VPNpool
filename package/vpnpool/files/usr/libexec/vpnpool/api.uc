#!/usr/bin/ucode
// vpnpool rpcd helpers (luci-app-vpnpool's rpcd plugin calls these; they never signal the daemon
// themselves — they print what the plugin has to do).
//
//   api.uc set_config [--single]   stdin {field: value, ...}
//       THE settings validator + writer. Every value is checked first; on ANY error nothing is
//       written and the reply is {ok:false, code:"invalid", errors:{field: code}} (--single: the
//       code is the one field's own code, the legacy set_option shape). On success ONE uci
//       commit and {ok:true, code:"saved"|"unchanged", changed:[...], actions:[...]}; actions =
//       what the caller must do: "USR1" (rebuild) | "USR2" (refetch + rebuild) — at most one of
//       the two — and/or "bot" (init.d reload: Telegram bot) / "sched" (rewrite the crontab).
//   api.uc analyze                 stdin {text}  -> {ok, code, items:[{line, kind, status, ...}]}
//   api.uc add                     stdin {text?, items?, lines?, options?} -> writes manual_node /
//                                  extra_sub, {ok, code, added, dup, failed:[{line, reason}], actions}
//   api.uc resolve_url <opt[,opt]> <value>   the configured URL equal to <value>, or the one
//                                  whose key (status subscriptions[].key) equals it, or the ONE
//                                  whose masked form (scheme://host/***) equals it; rc 1 if none
//   api.uc check_domain <value>    the normalised domain (lower case, no scheme/path); rc 1 if bad
//   api.uc export                  `uci export vpnpool` with the token and subscription URLs masked
//   api.uc has_masked <file>       rc 0 if a uci export text carries masked secrets
//   api.uc b64enc <file>           base64 of a file on stdout (busybox may lack base64)
//   api.uc b64dec_field <field> <out>   stdin JSON; base64-decode .<field> into <out>
//   api.uc backup_reply <file> <name> <report-json>   the backup() reply (data inline)
//
// Field error codes (machine codes; the human texts live in the UI translations):
//   bad_type bad_value too_small too_large bad_time bad_url bad_domain bad_community bad_ipv4
//   bad_mac bad_ifname bad_mark bad_token bad_chat bad_tag unknown_field
// analyze item: kind link|subscription_url|awg|unknown; status add|dup|skip|pending_stage4;
//   reason (skip: the parser.uc --report code; dup: exists|repeated; awg: needs_stage4).
'use strict';

import { readfile, writefile, stdin, popen, unlink, mkdir, stat } from 'fs';
import { cursor } from 'uci';
import { VALID_COMMUNITY, read_json, mask_url, mask_token, str_key, as_list } from './common.uc';

const SB = '/tmp/vpnpool';
const PARSER = '/usr/libexec/vpnpool/parser.uc';
const INTERVAL_MIN = 600;

function out(o) { printf('%J\n', o); }
function read_input() {
	let raw = stdin.read('all') ?? '';
	let v = null;
	try { v = json(raw); } catch (e) { v = null; }
	return v;
}
function run(cmd) {
	let f = popen(cmd, 'r');
	if (!f) return '';
	let r = f.read('all') ?? '';
	f.close();
	return r;
}
function sq(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }

// ---------------------------------------------------------------- value checks
function as_str(v) {
	let t = type(v);
	if (t == 'string') return trim(v);
	if (t == 'int' || t == 'double') return '' + v;
	if (t == 'bool') return v ? '1' : '0';
	return null;
}
function chk_int(v, min, max) {
	let s = as_str(v);
	if (s == null || type(v) == 'bool' || !match(s, /^[0-9]+$/) || length(s) > 10) return [ null, 'bad_value' ];
	let n = int(s);
	if (min != null && n < min) return [ null, 'too_small' ];
	if (max != null && n > max) return [ null, 'too_large' ];
	return [ '' + n, null ];
}
function chk_bool(v) {
	if (v === true || v === 1 || v === '1' || v === 'true') return [ '1', null ];
	if (v === false || v === 0 || v === '0' || v === 'false') return [ '0', null ];
	return [ null, 'bad_value' ];
}
function chk_enum(v, vals, legacy) {
	let s = as_str(v);
	if (s == null) return [ null, 'bad_value' ];
	if (legacy && legacy[s] != null) s = legacy[s];
	return (s in vals) ? [ s, null ] : [ null, 'bad_value' ];
}
// "6h" / "30m" / "900s" / "900" -> seconds (same grammar as lib.sh parse_interval)
function interval_secs(s) {
	let m = match(s, /^([0-9]{1,9})([hms]?)$/);
	if (!m) return null;
	return int(m[1]) * ((m[2] == 'h') ? 3600 : ((m[2] == 'm') ? 60 : 1));
}
function chk_interval(v) {
	let s = as_str(v);
	if (s == null || type(v) != 'string') return [ null, 'bad_value' ];
	let n = interval_secs(s);
	if (n == null) return [ null, 'bad_value' ];
	if (n < INTERVAL_MIN) return [ null, 'too_small' ];
	return [ s, null ];
}
function chk_time(v) {
	let s = as_str(v);
	if (s == null || type(v) != 'string') return [ null, 'bad_time' ];
	if (s == '') return [ '', null ];
	let m = match(s, /^([0-9]{1,2}):([0-9]{2})$/);
	if (!m || int(m[1]) > 23 || int(m[2]) > 59) return [ null, 'bad_time' ];
	return [ s, null ];
}
function is_domain(d) {
	if (!length(d) || length(d) > 253) return false;
	for (let l in split(d, '.'))
		if (!match(l, /^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?$/)) return false;
	return true;
}
// a domain as typed: case, scheme, path, a leading "*." / "." are normalised away
function norm_domain(v) {
	let s = as_str(v);
	if (s == null || type(v) != 'string') return null;
	s = lc(s);
	s = replace(s, /^[a-z][a-z0-9+.-]*:\/\//, '');
	s = replace(s, /[\/?#].*$/, '');
	s = replace(s, /^\*?\./, '');
	s = replace(s, /\.$/, '');
	return is_domain(s) ? s : null;
}
function is_url(s) {
	if (type(s) != 'string' || length(s) > 2048 || match(s, /[[:space:]'"<>]/)) return false;
	let m = match(s, /^https?:\/\/([^\/?#@]*@)?([^\/?#:]+|\[[0-9a-fA-F:.]+\])(:[0-9]{1,5})?([\/?#].*)?$/i);
	return !!m;
}
function chk_url(v, allow_empty) {
	let s = as_str(v);
	if (s == null || type(v) != 'string') return [ null, 'bad_url' ];
	if (s == '' && allow_empty) return [ '', null ];
	return is_url(s) ? [ s, null ] : [ null, 'bad_url' ];
}
function chk_services(v) {
	let s = as_str(v);
	if (s == null || type(v) != 'string') return [ null, 'bad_value' ];
	let toks = filter(split(s, /[[:space:],]+/), (x) => length(x));
	let outv = [];
	for (let t in toks) {
		if (index(t, '://') >= 0) { if (!is_url(t)) return [ null, 'bad_value' ]; push(outv, t); }
		else { let d = norm_domain(t); if (!d) return [ null, 'bad_value' ]; push(outv, d); }
	}
	return [ join(' ', outv), null ];
}
function is_ipv4(s) {
	let m = match(s, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\/([0-9]{1,2}))?$/);
	if (!m) return false;
	for (let i = 1; i <= 4; i++) if (int(m[i]) > 255) return false;
	if (m[6] != null && int(m[6]) > 32) return false;
	return true;
}
function chk_re(v, re, code, allow_empty) {
	let s = as_str(v);
	if (s == null || type(v) != 'string') return [ null, code ];
	if (s == '' && allow_empty) return [ '', null ];
	return match(s, re) ? [ s, null ] : [ null, code ];
}
function chk_tag(v) {
	if (type(v) != 'string' || length(v) > 256 || match(v, /[[:cntrl:]]/)) return [ null, 'bad_tag' ];
	return [ v, null ];
}
function chk_mark(v) {
	let s = as_str(v);
	if (s == null) return [ null, 'bad_mark' ];
	if (match(s, /^0x[0-9a-fA-F]{1,8}$/) && hex(substr(s, 2)) > 0) return [ lc(s), null ];
	if (match(s, /^[0-9]{1,10}$/) && int(s) > 0 && int(s) <= 4294967295) return [ s, null ];
	return [ null, 'bad_mark' ];
}

// list fields: -> [ values, { "field[i]": code } ]
function chk_list(field, v, item) {
	if (type(v) != 'array') { let e = {}; e[field] = 'bad_type'; return [ null, e ]; }
	let res = [], errs = {}, seen = {}, i = 0, bad = false;
	for (let x in v) {
		let r = item(x);
		if (r[1]) { errs[field + '[' + i + ']'] = r[1]; bad = true; }
		else if (!seen[r[0]]) { seen[r[0]] = true; push(res, r[0]); }
		i++;
	}
	return bad ? [ null, errs ] : [ res, null ];
}
let L_DOMAIN = (x) => { let d = norm_domain(x); return d ? [ d, null ] : [ null, 'bad_domain' ]; };
let L_COMM = (x) => (type(x) == 'string' && VALID_COMMUNITY[x]) ? [ x, null ] : [ null, 'bad_community' ];
let L_IPV4 = (x) => (type(x) == 'string' && is_ipv4(trim(x))) ? [ trim(x), null ] : [ null, 'bad_ipv4' ];
let L_MAC = (x) => (type(x) == 'string' && match(trim(x), /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/))
	? [ lc(trim(x)), null ] : [ null, 'bad_mac' ];
let L_TAG = (x) => (type(x) == 'string' && length(x)) ? chk_tag(x) : [ null, 'bad_tag' ];

// ---------------------------------------------------------------- the settings schema
// field -> { s: uci section, o: uci option (default = field), c: check, list: bool, a: action,
//            secret: masked in status (the masked value sent back means "unchanged") }
// a: USR1 = rebuild the sing-box config, USR2 = refetch + rebuild, bot = init.d reload (the
//    Telegram bot instance), sched = rewrite the crontab, none = read live by the daemon.
let I = (min, max) => (v) => chk_int(v, min, max);
let E = (...vals) => (v) => chk_enum(v, vals);
const SCHEMA = {
	failover_interval:     { s: 'main', c: I(10, 86400), a: 'USR1' },
	failover_tolerance:    { s: 'main', c: I(0, 5000), a: 'USR1' },
	auto_switch:           { s: 'main', c: chk_bool, a: 'USR1' },
	mode:                  { s: 'main', c: E('selective', 'exclude'), a: 'USR1' },
	health_url:            { s: 'main', c: (v) => chk_url(v, true), a: 'USR1' },
	check_services:        { s: 'main', c: chk_services, a: 'USR1' },
	ipv6:                  { s: 'main', c: E('block', 'off'), a: 'USR1' },
	killswitch:            { s: 'main', c: chk_bool, a: 'USR1' },
	dns_protect:           { s: 'main', c: chk_bool, a: 'USR1' },
	antidpi:               { s: 'main', c: (v) => chk_enum(v, [ 'off', 'on', 'aggressive' ], { '0': 'off', '1': 'on' }), a: 'USR1' },
	adaptive_routing:      { s: 'main', c: chk_bool, a: 'USR1' },
	log_level:             { s: 'main', c: E('trace', 'debug', 'info', 'warn', 'error', 'fatal', 'panic'), a: 'USR1' },
	dns_strategy:          { s: 'main', c: E('prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'), a: 'USR1' },
	client_mode:           { s: 'main', c: E('all', 'include', 'exclude'), a: 'USR1' },
	coexist:               { s: 'main', c: E('auto', 'on', 'off'), a: 'USR1' },
	lan_if:                { s: 'main', c: (v) => chk_re(v, /^[A-Za-z0-9._-]{1,15}$/, 'bad_ifname', true), a: 'USR1' },
	fwmark:                { s: 'main', c: chk_mark, a: 'USR1' },
	tproxy_port:           { s: 'main', c: I(1, 65535), a: 'USR1' },
	test_port:             { s: 'main', c: I(1, 65535), a: 'USR1' },
	node_test_port:        { s: 'main', c: I(1, 65535), a: 'USR1' },
	subscription_interval: { s: 'main', c: chk_interval, a: 'none' },
	subscription_url:      { s: 'main', c: (v) => chk_url(v, false), a: 'USR2', secret: 'url' },
	telegram_enabled:      { s: 'main', c: chk_bool, a: 'none' },
	telegram_token:        { s: 'main', c: (v) => chk_re(v, /^[0-9]+:[A-Za-z0-9_-]+$/, 'bad_token', true), a: 'bot', secret: 'token' },
	telegram_chat:         { s: 'main', c: (v) => chk_re(v, /^(-?[0-9]{1,20}|@[A-Za-z0-9_]{4,64})$/, 'bad_chat', true), a: 'bot' },
	telegram_control:      { s: 'main', c: chk_bool, a: 'bot' },
	telegram_via_proxy:    { s: 'main', c: chk_bool, a: 'bot' },
	preferred_node:        { s: 'main', c: chk_tag, a: 'none' },
	auto_snapshot:         { s: 'main', c: chk_bool, a: 'none' },
	auto_snapshot_max:     { s: 'main', c: I(1, 1000), a: 'none' },
	adaptive_max_per_run:  { s: 'main', c: I(1, 50), a: 'none' },
	dead_filter:           { s: 'main', c: chk_bool, a: 'none' },
	dead_filter_strikes:   { s: 'main', c: I(1, 100), a: 'none' },
	dead_filter_tries:     { s: 'main', c: I(1, 10), a: 'none' },
	prefilter_concurrency: { s: 'main', c: I(1, 64), a: 'none' },
	speedtest_min_mem_kb:  { s: 'main', c: I(0, 1048576), a: 'none' },
	sched_enabled:         { s: 'main', c: chk_bool, a: 'sched' },
	sched_on:              { s: 'main', c: chk_time, a: 'sched' },
	sched_off:             { s: 'main', c: chk_time, a: 'sched' },
	sched_refresh:         { s: 'main', c: chk_time, a: 'sched' },
	domains:               { s: 'routing', o: 'domain', list: L_DOMAIN, a: 'USR1' },
	auto_domains:          { s: 'routing', o: 'auto_domain', list: L_DOMAIN, a: 'USR1' },
	communities:           { s: 'routing', o: 'community', list: L_COMM, a: 'USR1' },
	clients:               { s: 'main', o: 'client', list: L_IPV4, a: 'USR1' },
	client_devices:        { s: 'main', o: 'client_dev', list: L_MAC, a: 'USR1' },
	auto_members:          { s: 'main', o: 'auto_member', list: L_TAG, a: 'USR1' }
};

function cur_value(u, f) {
	let d = SCHEMA[f];
	let v = u.get('vpnpool', d.s, d.o ?? f);
	if (d.list) return as_list(v, f != 'auto_members');
	return (v == null) ? '' : ('' + v);
}
function masked_of(d, cur) {
	if (!length(cur)) return null;
	return (d.secret == 'url') ? mask_url(cur) : ((d.secret == 'token') ? mask_token(cur) : null);
}

function set_config(input, single) {
	if (type(input) != 'object')
		return { ok: false, code: 'invalid', errors: { '': 'bad_type' } };
	let u = cursor();
	let errors = {}, plan = [];
	for (let f, v in input) {
		let d = SCHEMA[f];
		if (!d) { errors[f] = 'unknown_field'; continue; }
		let cur = cur_value(u, f);
		if (d.list) {
			let r = chk_list(f, v, d.list);
			if (r[1]) { for (let k, c in r[1]) errors[k] = c; continue; }
			if (join('\n', r[0]) != join('\n', cur)) push(plan, { f: f, d: d, v: r[0] });
			continue;
		}
		if (single && type(v) == 'array') { errors[f] = 'bad_type'; continue; }
		// a secret the status reply showed masked comes back unchanged -> keep the real value
		if (d.secret && type(v) == 'string' && v == masked_of(d, cur)) continue;
		let r = d.c(v);
		if (r[1]) { errors[f] = r[1]; continue; }
		if (r[0] != cur) push(plan, { f: f, d: d, v: r[0] });
	}
	if (length(errors)) {
		let code = 'invalid';
		if (single) {
			let ks = keys(errors);
			code = (errors[ks[0]] == 'unknown_field') ? 'unknown_option' : errors[ks[0]];
		}
		return { ok: false, code: code, errors: errors };
	}
	if (!length(plan)) return { ok: true, code: 'unchanged', changed: [], actions: [] };
	for (let sec in [ 'main', 'routing' ])
		if (u.get('vpnpool', sec) == null) u.set('vpnpool', sec, sec);
	let acts = {}, changed = [];
	for (let p in plan) {
		let opt = p.d.o ?? p.f, okw;
		if (p.d.list && !length(p.v)) { u.delete('vpnpool', p.d.s, opt); okw = true; }
		else okw = u.set('vpnpool', p.d.s, opt, p.v);
		if (!okw) { let e = {}; e[p.f] = 'write_failed'; return { ok: false, code: 'write_failed', errors: e }; }
		acts[p.d.a] = true;
		push(changed, p.f);
	}
	if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
	let actions = [];
	if (acts.USR2) push(actions, 'USR2'); else if (acts.USR1) push(actions, 'USR1');
	if (acts.bot) push(actions, 'bot');
	if (acts.sched) push(actions, 'sched');
	return { ok: true, code: 'saved', changed: changed, actions: actions };
}

// ---------------------------------------------------------------- analyze / add
function b64_any(s) {
	s = replace(s, /[[:space:]]/g, '');
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	while (length(s) % 4) s += '=';
	return b64dec(s);
}
function looks_base64(s) {
	if (index(s, '://') >= 0) return false;
	let c = substr(s, 0, 1);
	if (c == '{' || c == '[') return false;
	return !!match(s, /^[A-Za-z0-9+\/=_[:space:]-]+$/);
}
function parse_json_file(cmd) {
	let v = null;
	try { v = json(run(cmd)); } catch (e) { v = null; }
	return (type(v) == 'array') ? v : [];
}

const MAX_LINES = 1000;

// -> { items: [...], lines: { lineno: text } }  (text = the line as it will be stored)
function analyze(text) {
	let items = [], texts = {};
	if (type(text) != 'string') return null;
	let t = trim(text);
	if (substr(t, 0, 3) == '\xef\xbb\xbf') t = trim(substr(t, 3));
	if (!length(t)) return { items: items, lines: texts };
	if (looks_base64(t)) {
		let dec = b64_any(t);
		if (dec && (index(dec, '://') >= 0 || index(lc(dec), '[interface]') >= 0)) t = trim(dec);
	}
	// AmneziaWG / WireGuard .conf: one config per paste — the import path of stage 4
	if (index(lc(t), '[interface]') >= 0) {
		push(items, { line: 1, kind: 'awg', status: 'pending_stage4', reason: 'needs_stage4' });
		return { items: items, lines: texts };
	}
	let c0 = substr(t, 0, 1);
	if (c0 == '{' || c0 == '[') {
		let j = null;
		try { j = json(t); } catch (e) { j = null; }
		if (j != null) {   // a sing-box JSON config is a subscription body, not something to paste
			push(items, { line: 1, kind: 'unknown', status: 'skip', reason: 'json_config' });
			return { items: items, lines: texts };
		}
	}
	let u = cursor();
	let subs = {};
	let su = u.get('vpnpool', 'main', 'subscription_url');
	if (su) subs[su] = true;
	for (let x in as_list(u.get('vpnpool', 'main', 'extra_sub'), true)) subs[x] = true;

	let cand = [], cand_line = [], ln = 0, seen_url = {};
	for (let line in split(t, /\r?\n/)) {
		ln++;
		if (ln > MAX_LINES) { push(items, { line: ln, kind: 'unknown', status: 'skip', reason: 'too_many_lines' }); break; }
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#' || substr(line, 0, 2) == '//') continue;
		texts[ln] = line;
		if (match(line, /^https?:\/\//i)) {
			let it = { line: ln, kind: 'subscription_url', name: mask_url(line) };
			if (!is_url(line)) { it.status = 'skip'; it.reason = 'bad_url'; }
			else if (subs[line]) { it.status = 'dup'; it.reason = 'exists'; }
			else if (seen_url[line]) { it.status = 'dup'; it.reason = 'repeated'; }
			else { it.status = 'add'; seen_url[line] = true; }
			push(items, it);
			continue;
		}
		if (match(line, /^vpn:\/\//i)) {
			push(items, { line: ln, kind: 'awg', status: 'pending_stage4', reason: 'needs_stage4' });
			continue;
		}
		push(cand, line); push(cand_line, ln);
	}
	if (length(cand)) {
		mkdir(SB);
		let NEWF = SB + '/.an.new', EXF = SB + '/.an.exist';
		writefile(NEWF, join('\n', cand) + '\n');
		let exist_links = as_list(u.get('vpnpool', 'main', 'manual_node'), true);
		writefile(EXF, join('\n', exist_links) + '\n');
		// one --report pass over [existing manual nodes, the paste] (src 0 / 1) + one node pass
		// over the paste alone for the server / name of each accepted line
		let rep = parse_json_file(sprintf('ucode %s --report --with-id %s %s 2>/dev/null', PARSER, EXF, NEWF));
		let nodes = parse_json_file(sprintf('ucode %s --with-id %s 2>/dev/null', PARSER, NEWF));
		unlink(NEWF); unlink(EXF);
		let exist_ids = {}, exist_tags = {};
		for (let r in rep) if (r.src == 0 && r.status == 'ok') { if (r.id) exist_ids[r.id] = true; exist_tags[r.tag] = true; }
		for (let n in read_json(SB + '/nodes.json', [])) if (type(n) == 'object' && n.id) exist_ids[n.id] = true;
		let by_id = {};
		for (let n in nodes) if (n.id && !by_id[n.id]) by_id[n.id] = n;
		let seen = {};
		for (let r in rep) {
			if (r.src != 1 || r.line == null) continue;
			let it = { line: cand_line[r.line - 1] ?? r.line };
			if (r.status == 'ok') {
				let n = by_id[r.id] ?? {};
				it.kind = 'link'; it.type = r.type; it.id = r.id;
				it.name = n.tag ?? r.tag;
				it.server = n.server ?? ((type(n.peers) == 'array') ? n.peers[0]?.address : null);
				if (exist_ids[r.id]) { it.status = 'dup'; it.reason = 'exists'; }
				else if (seen[r.id]) { it.status = 'dup'; it.reason = 'repeated'; }
				else { it.status = 'add'; seen[r.id] = true; }
			} else if (r.reason == 'duplicate') {
				it.kind = 'link'; it.type = r.type; it.status = 'dup';
				it.reason = exist_tags[r.dup_of] ? 'exists' : 'repeated';
			} else {
				it.kind = (r.reason == 'not_a_link' || r.reason == 'unknown_scheme') ? 'unknown' : 'link';
				it.status = 'skip'; it.reason = r.reason ?? 'parse_error';
				if (r.type) it.type = r.type;
			}
			push(items, it);
		}
	}
	items = sort(items, (a, b) => a.line - b.line);
	return { items: items, lines: texts };
}

function add(input) {
	if (type(input) != 'object') return { ok: false, code: 'invalid', errors: { '': 'bad_type' } };
	let text = input.text;
	if (type(input.items) == 'array') {
		if (!length(input.items) || length(filter(input.items, (x) => type(x) != 'string')))
			return { ok: false, code: 'invalid', errors: { items: 'bad_type' } };
		text = join('\n', input.items);
	}
	if (type(text) != 'string' || !length(trim(text)))
		return { ok: false, code: 'invalid', errors: { text: 'bad_value' } };
	let pick = null;
	if (input.lines != null) {
		if (type(input.lines) != 'array') return { ok: false, code: 'invalid', errors: { lines: 'bad_type' } };
		pick = {};
		for (let l in input.lines) pick['' + l] = true;
	}
	let a = analyze(text);
	let u = cursor();
	let added = 0, dup = 0, failed = [], acts = {}, addlinks = [], addurls = [];
	for (let it in a.items) {
		if (pick && !pick['' + it.line]) continue;
		if (it.status == 'dup') { dup++; continue; }
		if (it.status != 'add') { push(failed, { line: it.line, reason: it.reason ?? it.status }); continue; }
		let line = a.lines[it.line];
		if (it.kind == 'link') { push(addlinks, line); acts.USR1 = true; }
		else if (it.kind == 'subscription_url') { push(addurls, line); acts.USR2 = true; }
		added++;
	}
	if (added) {
		let ml = as_list(u.get('vpnpool', 'main', 'manual_node'), true);
		let es = as_list(u.get('vpnpool', 'main', 'extra_sub'), true);
		for (let x in addlinks) push(ml, x);
		for (let x in addurls) push(es, x);
		if (length(addlinks) && !u.set('vpnpool', 'main', 'manual_node', ml))
			return { ok: false, code: 'write_failed' };
		if (length(addurls) && !u.set('vpnpool', 'main', 'extra_sub', es))
			return { ok: false, code: 'write_failed' };
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
	}
	let actions = acts.USR2 ? [ 'USR2' ] : (acts.USR1 ? [ 'USR1' ] : []);
	return { ok: added > 0, code: added > 0 ? 'added' : 'nothing_added', added: added, dup: dup,
		failed: failed, actions: actions };
}

// ---------------------------------------------------------------- misc
function resolve_url(opts, val) {
	let u = cursor(), all = [];
	for (let o in split(opts, ',')) {
		let v = u.get('vpnpool', 'main', o);
		for (let x in as_list(v, true)) push(all, x);
	}
	for (let x in all) if (x == val) return x;
	for (let x in all) if (str_key(x) == val) return x;
	// two URLs on one host share the masked form: ambiguous -> nothing (use the key)
	let hit = filter(all, (x) => mask_url(x) == val);
	return (length(hit) == 1) ? hit[0] : null;
}

const SECRET_URL_OPTS = { subscription_url: 1, extra_sub: 1, source: 1 };
function export_masked() {
	let txt = run('uci export vpnpool 2>/dev/null');
	if (!length(txt)) return null;
	let res = [];
	for (let line in split(txt, '\n')) {
		let m = match(line, /^(\s*(option|list)\s+)([A-Za-z0-9_]+)(\s+)'(.*)'\s*$/);
		if (m) {
			if (m[3] == 'telegram_token' && length(m[5])) line = m[1] + m[3] + m[4] + "'" + mask_token(m[5]) + "'";
			else if (SECRET_URL_OPTS[m[3]] && length(m[5])) line = m[1] + m[3] + m[4] + "'" + mask_url(m[5]) + "'";
		}
		push(res, line);
	}
	return join('\n', res);
}
function has_masked(path) {
	for (let line in split(readfile(path) ?? '', '\n')) {
		let m = match(line, /^\s*(option|list)\s+([A-Za-z0-9_]+)\s+'(.*)'\s*$/);
		if (!m) continue;
		if (m[2] == 'telegram_token' && match(m[3], /:\*\*\*$|^\*\*\*$/)) return true;
		if (SECRET_URL_OPTS[m[2]] && match(m[3], /\/\*\*\*$|^\*\*\*$/)) return true;
	}
	return false;
}

// ---------------------------------------------------------------- dispatch
let cmd = ARGV[0];
if (cmd == 'set_config') {
	let r = set_config(read_input(), ARGV[1] == '--single');
	out(r);
} else if (cmd == 'analyze') {
	let inp = read_input();
	let a = (type(inp) == 'object') ? analyze(inp.text) : null;
	if (a == null) out({ ok: false, code: 'invalid', errors: { text: 'bad_type' } });
	else out({ ok: true, code: 'ok', items: a.items,
		summary: { add: length(filter(a.items, (i) => i.status == 'add')),
		           dup: length(filter(a.items, (i) => i.status == 'dup')),
		           skip: length(filter(a.items, (i) => i.status == 'skip')),
		           pending: length(filter(a.items, (i) => i.status == 'pending_stage4')) } });
} else if (cmd == 'add') {
	out(add(read_input()));
} else if (cmd == 'resolve_url') {
	let r = resolve_url(ARGV[1] ?? '', ARGV[2] ?? '');
	if (r == null) exit(1);
	print(r, '\n');
} else if (cmd == 'check_domain') {
	let dd = norm_domain(ARGV[1] ?? '');
	if (!dd) exit(1);
	print(dd, '\n');
} else if (cmd == 'export') {
	let t = export_masked();
	if (t == null) exit(1);
	print(t);
} else if (cmd == 'has_masked') {
	exit(has_masked(ARGV[1]) ? 0 : 1);
} else if (cmd == 'b64enc') {
	let d = readfile(ARGV[1]);
	if (d == null) exit(1);
	print(b64enc(d));
} else if (cmd == 'b64dec_field') {
	let inp = read_input();
	let v = (type(inp) == 'object') ? inp[ARGV[1]] : null;
	let d = (type(v) == 'string' && length(v)) ? b64dec(replace(v, /\s/g, '')) : null;
	if (d == null || !length(d)) exit(1);
	exit(writefile(ARGV[2], d) ? 0 : 1);
} else if (cmd == 'backup_reply') {
	let d = readfile(ARGV[1]);
	if (d == null) { out({ ok: false, code: 'script_failed', error: 'script_failed', daemon: 'n/a' }); exit(0); }
	let rep = null;
	try { rep = json(ARGV[3] ?? 'null'); } catch (e) { rep = null; }
	out({ ok: true, code: 'ok', daemon: 'n/a', name: ARGV[2], size: length(d), format: 'tar.gz+base64',
		report: rep, data: b64enc(d) });
} else {
	warn('usage: api.uc set_config|analyze|add|resolve_url|export|has_masked|b64enc|b64dec_field|backup_reply\n');
	exit(2);
}
