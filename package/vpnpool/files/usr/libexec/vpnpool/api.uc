#!/usr/bin/ucode
// vpnpool rpcd helpers (luci-app-vpnpool's rpcd plugin calls these; they never signal the daemon
// themselves — they print what the plugin has to do).
//
//   api.uc set_config [--single]   stdin {field: value, ...}
//       THE settings validator + writer. Every value is checked first; on ANY error nothing is
//       written and the reply is {ok:false, code:"invalid", errors:{field: code}} (--single: the
//       code is the one field's own code, the legacy set_option shape). On success ONE uci
//       commit and {ok:true, code:"saved"|"unchanged", changed:[...], actions:[...]}; actions =
//       what the caller must do: "USR1" (rebuild; a refetch is asked only by the subscription
//       operations, sub / add) and/or "bot" (init.d reload: Telegram bot) / "sched" (crontab).
//   api.uc analyze                 stdin {text}  -> {ok, code, items:[{line, kind, status, ...}]}
//   api.uc add                     stdin {text?, items?, lines?, options?} -> writes manual_node /
//                                  a subscription section per URL (options {mode all|pick, pick,
//                                  name, enabled}) / /etc/vpnpool/awg/<id>.conf, {ok, code, added, dup,
//                                  failed:[{line, reason}], actions, probes:[{line, fetched, http}],
//                                  awg_ids?, warning? (engine_missing|engine_no_awg: an AWG node
//                                  is stored deferred until the engine is installed)}. A subscription URL is taken only
//                                  after a trial download that yields nodes (else fetch_failed) —
//                                  the same rule as add_sub (add_sub goes through here).
//   api.uc node <op>               stdin {id?|tag?, ids?|tags?}: fav unfav activate deactivate hide
//                                  unhide keep unkeep connect auto delete prefer_toggle (ROADMAP 9:
//                                  every store keyed by the node id; a tag of the last build is
//                                  accepted for the older screens / the bot)
//   api.uc sub <op>                stdin: set {id, name?, url?, enabled?, mode?, pick?} | del {id|url}
//                                  | probe_pick {url, idx?|ids?, name?} | set_primary {url} (legacy)
//   api.uc resolve_url <kinds> <value>   the URL of a subscription (kinds: all,pick or *) equal to
//                                  <value>, or whose key (status subscriptions[].key) or id equals
//                                  it, or the ONE whose masked form (scheme://host/***) equals it;
//                                  rc 1 if none, rc 3 if the masked form fits several (ambiguous)
//   api.uc check_config <dir> <savedir>   check every VALUE of a uci config dir (import/restore)
//                                  with the same schema as set_config: {ok} | {ok:false,
//                                  code:"invalid", errors:{option: code}}
//   api.uc check_domain <value>    the normalised domain (lower case, no scheme/path); rc 1 if bad
//   api.uc export                  `uci export vpnpool` with the token and subscription URLs masked
//   api.uc has_masked <file>       rc 0 if a uci export text carries masked secrets
//   api.uc b64enc <file>           base64 of a file on stdout (busybox may lack base64)
//   api.uc b64dec_field <field> <out>   stdin JSON; base64-decode .<field> into <out>
//   api.uc backup_reply <file> <name> <report-json>   the backup() reply (data inline)
//
// Field error codes (machine codes; the human texts live in the UI translations):
//   bad_type bad_value too_small too_large bad_time bad_url bad_domain bad_community bad_ipv4
//   bad_mac bad_ifname bad_mark bad_token bad_chat bad_tag bad_path bad_mode unknown_field
// analyze item: kind link|subscription_url|awg|unknown; status add|dup|skip;
//   reason (skip: the parser.uc --report code, + field for an AWG .conf value; a vpn:// link:
//   api_key full_access unsupported_container (+found) no_conf decode_failed (+detail);
//   dup: exists|repeated). awg items: type awg|wireguard, id, name, server, port, hints?
//   (awg_random_trailers), ignored? (keys skipped), deferred? (engine_missing|engine_no_awg|engine_no_awg31: stored, waits for the
//   engine). summary.pending = items that will be stored deferred.
'use strict';

import { readfile, writefile, stdin, popen, unlink, mkdir, stat, lsdir, rename, chmod, access } from 'fs';
import { cursor } from 'uci';
import { rand } from 'math';
import { VALID_COMMUNITY, uniq, read_json, write_atomic, mask_url, mask_token, str_key, as_list, engine_select,
	SCHEMA as DATA_SCHEMA, is_id, subs_of, sub_name_for, fav_read, fav_write, live_nodes, node_lookup, link_of } from './common.uc';

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
	if (index(s, '***') >= 0) return false;   // a masked value (scheme://host/***) is never an address
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
// A node of the stores (ROADMAP 9: node ids everywhere): an id, or the tag of a node of the last
// build (older screens send names) -> its id. '' = none (preferred_node: the automatic choice).
let NODES_CACHE = null;
function chk_node(v, allow_empty) {
	if (type(v) != 'string') return [ null, 'bad_tag' ];
	if (v == '' && allow_empty) return [ '', null ];
	if (is_id(v)) return [ v, null ];
	NODES_CACHE ??= live_nodes();
	let r = node_lookup(v, NODES_CACHE);
	return (r && r.node) ? [ r.id, null ] : [ null, 'bad_tag' ];
}
let L_NODE = (x) => chk_node(x, false);
function chk_path(v) {
	let r = chk_re(v, /^\/[A-Za-z0-9._\/-]{1,255}$/, 'bad_path', true);
	return (r[1] == 'bad_value') ? [ null, 'bad_path' ] : r;
}

// ---------------------------------------------------------------- the settings schema
// field -> { s: uci section, o: uci option (default = field), c: check, list: bool, a: action,
//            secret: masked in status (the masked value sent back means "unchanged") }
// a: USR1 = rebuild the sing-box config, bot = init.d reload (the
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
	telegram_enabled:      { s: 'main', c: chk_bool, a: 'none' },
	telegram_token:        { s: 'main', c: (v) => chk_re(v, /^[0-9]+:[A-Za-z0-9_-]+$/, 'bad_token', true), a: 'bot', secret: 'token' },
	telegram_chat:         { s: 'main', c: (v) => chk_re(v, /^(-?[0-9]{1,20}|@[A-Za-z0-9_]{4,64})$/, 'bad_chat', true), a: 'bot' },
	telegram_control:      { s: 'main', c: chk_bool, a: 'bot' },
	telegram_via_proxy:    { s: 'main', c: chk_bool, a: 'bot' },
	preferred_node:        { s: 'main', c: (v) => chk_node(v, true), a: 'none' },   // read live by the daemon
	favorites_only:        { s: 'main', c: chk_bool, a: 'USR1' },
	// the sing-box binary: '' / the stock path = automatic (ROADMAP 4.1); another path pins it. On
	// save (not on import / restore) it must be an executable file on this router.
	singbox_bin:           { s: 'main', c: chk_path, live: (v) => (v == '' || (stat(v)?.type == 'file' && access(v, 'x'))) ? null : 'bad_path', a: 'USR1' },
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
	auto_members:          { s: 'main', o: 'auto_member', list: L_NODE, a: 'USR1' }
};

function cur_value(u, f) {
	let d = SCHEMA[f];
	let v = u.get('vpnpool', d.s, d.o ?? f);
	if (d.list) return as_list(v, true);
	return (v == null) ? '' : ('' + v);
}
function masked_of(d, cur) {
	if (!length(cur)) return null;
	return (d.secret == 'token') ? mask_token(cur) : null;
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
		if (!r[1] && d.live) r[1] = d.live(r[0]);
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
	// a missing section is created with the type the whole package expects (main: vpnpool)
	for (let sec in [ [ 'main', 'vpnpool' ], [ 'routing', 'routing' ] ])
		if (u.get('vpnpool', sec[0]) == null) u.set('vpnpool', sec[0], sec[1]);
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
	if (acts.USR1) push(actions, 'USR1');
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

// ---- AmneziaWG / WireGuard (ROADMAP 4.3-4.5, 4.7) ----
// A .conf (pasted, or decoded from a vpn:// link by awgdecode.uc --json) is checked by the SAME
// parser the build uses (--report: id = sha256 of the private key, type awg|wireguard, the
// reason of a refusal); add() stores it as /etc/vpnpool/awg/<id>.conf with "# Name = …" on top.
// An AWG node the engine can't run is still stored — DEFERRED (owner's decision 14.10.2026):
// the item carries deferred:"engine_missing"|"engine_no_awg" and add() answers ok + warning.
const AWGDEC = '/usr/libexec/vpnpool/awgdecode.uc';
const AWG_DIR = '/etc/vpnpool/awg';
const BAD_NODES = SB + '/.bad_nodes.json';
// awgdecode E_* -> analyze reason
const DEC_REASON = { E_API_KEY: 'api_key', E_FULL_ACCESS: 'full_access',
	E_NO_SUPPORTED_CONTAINER: 'unsupported_container', E_NO_CONF: 'no_conf' };
// add(): the node is stored but waits for the engine (ok:true + this warning)
const ADD_WARN = { engine_missing: { warning: 'engine_missing' }, engine_no_awg: { warning: 'engine_no_awg' },
	engine_no_awg31: { warning: 'engine_no_awg31' } };
// a file that holds a private key: created empty, made 0600, then filled (never readable by others)
function write_secret(path, data) {
	if (writefile(path, '') == null) return false;
	chmod(path, 0600);
	return writefile(path, data) != null;
}

let AN = null;   // per-call state: known AWG ids, engine
function awg_known_ids() {
	if (AN.ids) return AN.ids;
	let ids = {};
	let files = [];
	for (let f in (lsdir(AWG_DIR) ?? [])) if (match(f, /\.conf$/)) push(files, sq(AWG_DIR + '/' + f));
	if (length(files))
		for (let r in parse_json_file(sprintf('ucode %s --report --with-id %s 2>/dev/null', PARSER, join(' ', files))))
			if (r.status == 'ok' && r.id) ids[r.id] = true;
	// only the stored files: the build's lists (nodes.json, deferred.json) can be older than them
	AN.ids = ids;
	return ids;
}
function awg_engine() {
	if (AN.eng == null) AN.eng = engine_select(cursor().get('vpnpool', 'main', 'singbox_bin'), true);
	return AN.eng;
}
// a display name for a "# Name =" comment: one line, no control characters, bounded
function clean_name(s) {
	if (type(s) != 'string') return null;
	s = trim(replace(s, /[[:cntrl:]]+/g, ' '));
	if (length(s) > 64) s = substr(s, 0, 64);
	return length(s) ? s : null;
}
// one .conf -> analyze item (nothing written); AN.confs[line] keeps what add() stores
function awg_item(conf, ln, name, host) {
	mkdir(SB);
	let f = sprintf('%s/.an.awg.%s', SB, uniq());
	write_secret(f, conf);
	let rep = parse_json_file(sprintf('ucode %s --report --with-id %s 2>/dev/null', PARSER, sq(f)));
	unlink(f);
	let r = rep[0] ?? { status: 'skip', reason: 'parse_error' };
	let it = { line: ln, kind: 'awg' };
	if (r.status != 'ok') {
		it.status = 'skip'; it.reason = r.reason ?? 'parse_error';
		if (r.field) it.field = r.field;
		return it;
	}
	it.type = r.type; it.id = r.id;
	it.name = clean_name(name) ?? r.tag;
	it.server = r.server ?? host; it.port = r.port;
	if (r.hints) it.hints = r.hints;
	if (r.ignored) it.ignored = r.ignored;   // wg-quick / amneziawg-tools keys that do nothing here
	if (awg_known_ids()[r.id] || stat(AWG_DIR + '/' + r.id + '.conf')) { it.status = 'dup'; it.reason = 'exists'; }
	else if (AN.seen[r.id]) { it.status = 'dup'; it.reason = 'repeated'; }
	else {
		it.status = 'add'; AN.seen[r.id] = true;
		AN.confs['' + ln] = { conf: conf, name: it.name, id: r.id };
		if (r.type == 'awg' && awg_engine().reason) it.deferred = awg_engine().reason;
		else if (r.type == 'awg' && r.awg31 && !awg_engine().awg31) it.deferred = 'engine_no_awg31';
	}
	return it;
}
// one vpn:// token (the link, its wrapped continuation lines joined) -> items
function vpn_items(token, ln) {
	mkdir(SB);
	let f = sprintf('%s/.an.vpn.%s', SB, uniq());
	write_secret(f, token + '\n');
	let d = null;
	try { d = json(run(sprintf('ucode %s --json < %s 2>/dev/null', AWGDEC, sq(f)))); } catch (e) { d = null; }
	unlink(f);
	if (type(d) != 'object') return [ { line: ln, kind: 'awg', status: 'skip', reason: 'decode_failed' } ];
	if (d.ok !== true || type(d.items) != 'array' || !length(d.items)) {
		let it = { line: ln, kind: 'awg', status: 'skip', reason: DEC_REASON[d.code] ?? 'decode_failed' };
		if (!DEC_REASON[d.code] && type(d.code) == 'string') it.detail = d.code;
		if (type(d.found) == 'array') it.found = d.found;
		return [ it ];
	}
	let out = [];
	for (let x in d.items) {
		if (x?.kind == 'awg' || x?.kind == 'wireguard') push(out, awg_item(x.conf, ln, x.name, x.host));
		else if (x?.kind == 'link' && type(x.link) == 'string') push(out, { line: ln, link: x.link });
	}
	return out;
}

// -> { items: [...], lines: { lineno: text } }  (text = the line as it will be stored)
function analyze(text, nowrap) {
	let items = [], texts = {};
	AN = { ids: null, eng: null, seen: {}, confs: {} };
	if (type(text) != 'string') return null;
	let t = trim(text);
	if (substr(t, 0, 3) == '\xef\xbb\xbf') t = trim(substr(t, 3));
	if (!length(t)) return { items: items, lines: texts };
	if (looks_base64(t)) {
		let dec = b64_any(t);
		if (dec && (index(dec, '://') >= 0 || index(lc(dec), '[interface]') >= 0)) t = trim(dec);
	}
	// AmneziaWG / WireGuard .conf: one config per paste
	if (index(lc(t), '[interface]') >= 0) {
		push(items, awg_item(t, 1, null, null));
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
	for (let s in subs_of(u)) subs[s.url] = true;

	let cand = [], cand_line = [], ln = 0, seen_url = {};
	// vpn:// (AmneziaVPN): a messenger wraps the long link over several lines — the lines right
	// after it that only continue the base64 belong to it (a line is continued only while the
	// line before is long, >= WRAP_MIN: a wrap cuts a long line; the last, short piece ends it).
	// nowrap (add with items[]): every item is a line of its own. Each link is decoded alone.
	const WRAP_MIN = 32;
	let toks = [], tok = null, prev_len = 0;
	for (let line in split(t, /\r?\n/)) {
		ln++;
		if (ln > MAX_LINES) { push(items, { line: ln, kind: 'unknown', status: 'skip', reason: 'too_many_lines' }); break; }
		line = trim(line);
		if (tok && !nowrap && prev_len >= WRAP_MIN && length(line) && match(line, /^[A-Za-z0-9+\/=_-]+$/)) {
			tok.text += '\n' + line; prev_len = length(line);
			continue;
		}
		tok = null;
		let vp = index(lc(line), 'vpn://');
		if (vp >= 0) {
			tok = { line: ln, text: substr(line, vp) };
			prev_len = length(tok.text);
			push(toks, tok);
			continue;
		}
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
		push(cand, line); push(cand_line, ln);
	}
	for (let tk in toks)
		for (let it in vpn_items(tk.text, tk.line)) {
			if (it.link) { texts[it.line] = it.link; push(cand, it.link); push(cand_line, it.line); }   // xray / ss
			else push(items, it);
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

// ---------------------------------------------------------------- the data model (ROADMAP 9)
function uniq_list(a) { let seen = {}, r = []; for (let x in a) if (!seen[x]) { seen[x] = true; push(r, x); } return r; }

// write a subscription section: {url, name?, enabled?, mode?, pick?} (null fields untouched)
function sub_write(u, sid, f) {
	if (u.get('vpnpool', sid) == null && !u.set('vpnpool', sid, 'subscription')) return false;
	if (f.url != null && !u.set('vpnpool', sid, 'url', f.url)) return false;
	if (f.name != null) { if (length(f.name)) u.set('vpnpool', sid, 'name', f.name); else u.delete('vpnpool', sid, 'name'); }
	if (f.enabled != null) u.set('vpnpool', sid, 'enabled', f.enabled ? '1' : '0');
	if (f.mode != null) u.set('vpnpool', sid, 'mode', f.mode);
	if (f.pick != null) { if (length(f.pick)) u.set('vpnpool', sid, 'pick', f.pick); else u.delete('vpnpool', sid, 'pick'); }
	return true;
}
function sub_find(u, key) {
	if (type(key) != 'string' || !length(key)) return null;
	for (let s in subs_of(u)) if (s.id == key || s.url == key || str_key(s.url) == key) return s;
	return null;
}

// The clash API of the running sing-box (the live selector). -> HTTP code ('000' = no answer)
function clash_put(selector, name) {
	let api = cursor().get('vpnpool', 'main', 'clash_api') ?? '127.0.0.1:9091';
	let code = trim(run(sprintf("curl -s -m5 -o /dev/null -w '%%{http_code}' -X PUT %s --data %s 2>/dev/null",
		sq('http://' + api + '/proxies/' + selector), sq(sprintf('%J', { name: name })))));
	return length(code) ? code : '000';
}

// A favourite entry for a live node: the link (or, for a node of a sing-box JSON source, its
// outbound; AWG nodes live in their own files) so the favourite outlives its source.
function fav_entry(n, old) {
	let p0 = (type(n.peers) == 'array') ? n.peers[0] : null;
	let e = { tag: n.tag, link: link_of(n.id), active: old?.active === true, auto: false, at: time(),
		type: n.type, server: n.server ?? p0?.address, port: n.server_port ?? p0?.port };
	if (e.link == null && n.type != 'awg' && n.type != 'wireguard') {
		let o = {};
		for (let k, v in n) if (k != 'id' && k != 'tag' && substr(k, 0, 1) != '_') o[k] = v;
		e.ob = o;
	}
	return e;
}

// drop ids from the RAM marks of the node checker (dead set, strikes, delays) — a node the user
// returned / removed leaves them at once
function drop_marks(ids) {
	let set = {};
	for (let i in ids) set[i] = true;
	let d = read_json(SB + '/.dead_ids.json', null);
	if (type(d) == 'array') write_atomic(SB + '/.dead_ids.json', sprintf('%J', filter(d, (x) => !set[x])));
	let st = readfile(SB + '/.deadstrikes');
	if (st != null) {
		let keep = filter(split(st, '\n'), (l) => length(l) && !set[split(l, '\t')[0]]);
		write_atomic(SB + '/.deadstrikes', length(keep) ? join('\n', keep) + '\n' : '');
	}
}
// remove ids from the last build's lists right now (the next status poll shows the change; the
// rebuild signalled after it writes the authoritative ones)
function prune_live(ids) {
	let set = {};
	for (let i in ids) set[i] = true;
	for (let f in [ SB + '/nodes.json', SB + '/deferred.json' ]) {
		let a = read_json(f, null);
		if (type(a) == 'array') write_atomic(f, sprintf('%J', filter(a, (n) => !(type(n) == 'object' && set[n.id]))));
	}
}
function list_add(u, opt, id) {
	let l = as_list(u.get('vpnpool', 'main', opt), true);
	if (id in l) return false;
	push(l, id);
	u.set('vpnpool', 'main', opt, l);
	return true;
}
function list_del(u, opt, ids) {
	let set = {};
	for (let i in ids) set[i] = true;
	let l = as_list(u.get('vpnpool', 'main', opt), true);
	let r = filter(l, (x) => !set[x]);
	if (length(r) == length(l)) return false;
	if (length(r)) u.set('vpnpool', 'main', opt, r); else u.delete('vpnpool', 'main', opt);
	return true;
}

// Remove one node from the user's stores: a manual link leaves manual_node, an AWG / WireGuard node
// its file, a subscription node is HIDDEN (its source would bring it back otherwise), a favourite
// in the pool only from the archive goes back to the archive (the favourite itself stays: delete
// never touches favourites). -> true if something changed.
function delete_one(u, r) {
	let n = r.node, src = '' + (n?._src ?? '');
	let changed = false;
	// an AWG / WireGuard file node — also one in no list of the last build (a failed build, a file
	// the build has not seen yet): it is found by its id among the files
	if ((n && (n.type == 'awg' || n.type == 'wireguard') && src == 'awg') || (!n && r.awg_file)) {
		if (stat(AWG_DIR + '/' + r.id + '.conf')) { unlink(AWG_DIR + '/' + r.id + '.conf'); changed = true; }
		else for (let f in (lsdir(AWG_DIR) ?? [])) {
			if (!match(f, /\.conf$/)) continue;
			let rep = parse_json_file(sprintf('ucode %s --report --with-id %s 2>/dev/null', PARSER, sq(AWG_DIR + '/' + f)));
			if (rep[0]?.id == r.id) { unlink(AWG_DIR + '/' + f); changed = true; break; }
		}
	} else if (src == 'manual') {
		let link = link_of(r.id);
		let ml = as_list(u.get('vpnpool', 'main', 'manual_node'), true);
		let keep = filter(ml, (x) => x != link);
		if (length(keep) != length(ml)) {
			if (length(keep)) u.set('vpnpool', 'main', 'manual_node', keep); else u.delete('vpnpool', 'main', 'manual_node');
			changed = true;
		}
	} else if (src == 'fav') {
		let fav = fav_read();
		if (type(fav[r.id]) == 'object' && fav[r.id].active) { fav[r.id].active = false; fav_write(fav); changed = true; }
	} else if (n) {
		changed = list_add(u, 'hidden', r.id);
	}
	if (changed) list_del(u, 'keep_auto', [ r.id ]);
	return changed;
}

// api.uc node <op>  stdin {id?|tag?, ids?|tags?} -> {ok, code, actions, ...}. A node is named by
// its id (or, for the older screens and the bot, by its tag in the last build).
function node_op(op, inp) {
	if (type(inp) != 'object') return { ok: false, code: 'invalid', errors: { '': 'bad_type' } };
	let u = cursor();
	let key = inp.id ?? inp.tag;
	if (op == 'auto') {
		let had = length(u.get('vpnpool', 'main', 'preferred_node') ?? '') > 0;
		if (had) { u.delete('vpnpool', 'main', 'preferred_node'); if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' }; }
		let c = clash_put('proxy', 'auto');
		if (c == '204') return { ok: true, code: 'applied', actions: [] };
		if (c == '000') return { ok: true, code: had ? 'saved_not_applied' : 'unchanged', actions: [] };
		return { ok: false, code: 'clash_failed', http: c };
	}
	if (op == 'delete') {
		let keys_ = (type(inp.ids) == 'array') ? inp.ids : ((type(inp.tags) == 'array') ? inp.tags : [ key ]);
		let nodes = live_nodes(), done = [], missing = [];
		for (let k in keys_) {
			let r = (type(k) == 'string') ? node_lookup(k, nodes) : null;
			if ((!r || !r.node) && is_id(k)) r = { id: k, tag: null, node: null, awg_file: true };
			if (r && (r.node || r.awg_file) && delete_one(u, r)) push(done, r.id); else push(missing, k);
		}
		if (!length(done)) return { ok: false, code: 'not_found', deleted: 0, missing: missing };
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		prune_live(done); drop_marks(done);
		return { ok: true, code: 'deleted', deleted: length(done), missing: missing, ids: done, actions: [ 'USR1' ] };
	}
	if (op == 'prefer_toggle') {
		// legacy set_preferred: the preferred node again (or an empty name) = back to automatic
		let cur = u.get('vpnpool', 'main', 'preferred_node') ?? '';
		let rr = (type(key) == 'string' && length(key)) ? node_lookup(key) : null;
		if (key == null || key == '' || (rr && rr.id == cur)) {
			u.delete('vpnpool', 'main', 'preferred_node');
			if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
			return { ok: true, code: 'cleared', actions: [] };
		}
		if (!rr || !rr.node || rr.node._deferred) return { ok: false, code: 'not_found' };
		u.set('vpnpool', 'main', 'preferred_node', rr.id);
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		return { ok: true, code: 'set', id: rr.id, actions: [] };
	}
	if (type(key) != 'string' || !length(key) || length(key) > 256) return { ok: false, code: 'invalid', errors: { id: 'bad_tag' } };
	let r = node_lookup(key);
	if (op == 'unhide') {
		let id = r?.id ?? key;
		if (!list_del(u, 'hidden', [ id ])) return { ok: false, code: 'not_found' };
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		return { ok: true, code: 'restored', id: id, actions: [ 'USR1' ] };
	}
	if (op == 'hide') {
		if (!r || !r.node) return { ok: false, code: 'not_found' };
		if (!list_add(u, 'hidden', r.id)) return { ok: true, code: 'unchanged', id: r.id, actions: [] };
		// a hidden node can't be the preferred one
		if (u.get('vpnpool', 'main', 'preferred_node') == r.id) u.delete('vpnpool', 'main', 'preferred_node');
		list_del(u, 'keep_auto', [ r.id ]);
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		prune_live([ r.id ]); drop_marks([ r.id ]);
		return { ok: true, code: 'hidden', id: r.id, actions: [ 'USR1' ] };
	}
	if (op == 'fav') {
		if (!r) return { ok: false, code: 'not_found' };
		let fav = fav_read();
		let old = fav[r.id];
		if (type(old) == 'object' && old.auto !== true) return { ok: true, code: 'unchanged', id: r.id, actions: [] };
		if (r.node) fav[r.id] = fav_entry(r.node, old);
		else { old.auto = false; fav[r.id] = old; }
		if (!fav_write(fav)) return { ok: false, code: 'write_failed' };
		// a favourite changes the pool only with "favourites only" on
		return { ok: true, code: 'saved', id: r.id, actions: (u.get('vpnpool', 'main', 'favorites_only') == '1') ? [ 'USR1' ] : [] };
	}
	if (op == 'unfav') {
		let id = r?.id ?? key;
		let fav = fav_read();
		if (type(fav[id]) != 'object') return { ok: false, code: 'not_found' };
		let was_active = fav[id].active === true;
		delete fav[id];
		if (!fav_write(fav)) return { ok: false, code: 'write_failed' };
		let reload = was_active || u.get('vpnpool', 'main', 'favorites_only') == '1';
		return { ok: true, code: 'deleted', id: id, actions: reload ? [ 'USR1' ] : [] };
	}
	if (op == 'activate' || op == 'deactivate') {
		let id = r?.id ?? key;
		let fav = fav_read();
		if (type(fav[id]) != 'object') return { ok: false, code: 'not_found' };
		let want = (op == 'activate');
		if ((fav[id].active === true) == want) return { ok: true, code: 'unchanged', id: id, actions: [] };
		fav[id].active = want;
		if (!fav_write(fav)) return { ok: false, code: 'write_failed' };
		if (want) list_del(u, 'hidden', [ id ]) && u.commit('vpnpool');
		return { ok: true, code: 'saved', id: id, actions: [ 'USR1' ] };
	}
	if (op == 'keep' || op == 'unkeep') {
		if (!r || !r.node) return { ok: false, code: 'not_found' };
		let ch = (op == 'keep') ? list_add(u, 'keep_auto', r.id) : list_del(u, 'keep_auto', [ r.id ]);
		if (!ch) return (op == 'keep') ? { ok: true, code: 'unchanged', id: r.id, actions: [] } : { ok: false, code: 'not_found' };
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		if (op == 'keep') drop_marks([ r.id ]);
		return { ok: true, code: 'saved', id: r.id, actions: [ 'USR1' ] };
	}
	if (op == 'connect') {
		if (!r) return { ok: false, code: 'not_found' };
		if (r.node?._deferred) return { ok: false, code: 'not_found' };
		u.set('vpnpool', 'main', 'preferred_node', r.id);
		let acts = [];
		// a favourite no source has: it joins the pool from the archive, then the daemon switches
		if (!r.node && r.fav) {
			let fav = fav_read();
			fav[r.id].active = true;
			if (!fav_write(fav)) return { ok: false, code: 'write_failed' };
			list_del(u, 'hidden', [ r.id ]);
			acts = [ 'USR1' ];
		}
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		if (!r.node) return { ok: true, code: 'connect_pending', id: r.id, actions: acts };
		let c = clash_put('proxy', r.tag);
		if (c == '204') return { ok: true, code: 'applied', id: r.id, actions: acts };
		if (c == '000') return { ok: true, code: 'saved_not_applied', id: r.id, actions: acts };
		return { ok: false, code: 'clash_failed', http: c };
	}
	return { ok: false, code: 'unknown_method' };
}

// api.uc sub <op>  stdin {...} -> {ok, code, actions, ...}
//   set {id, name?, url?, enabled?, mode?, pick?}   del {id|url}   probe_pick {url, idx?|ids?, name?}
//   set_primary {url} (legacy set_url: the first subscription that takes every node)
function sub_op(op, inp) {
	if (type(inp) != 'object') return { ok: false, code: 'invalid', errors: { '': 'bad_type' } };
	let u = cursor();
	if (op == 'set') {
		let s = sub_find(u, inp.id);
		if (!s) return { ok: false, code: 'not_found' };
		let errors = {}, f = {}, acts = {};
		if (inp.name != null) { if (type(inp.name) != 'string') errors.name = 'bad_type'; else f.name = clean_name(inp.name) ?? ''; }
		if (inp.url != null) {
			// the masked URL the status showed, sent back = unchanged
			if (type(inp.url) == 'string' && inp.url == mask_url(s.url)) { }
			else { let r = chk_url(inp.url, false); if (r[1]) errors.url = r[1]; else if (r[0] != s.url) { f.url = r[0]; acts.USR2 = true; } }
		}
		if (inp.enabled != null) {
			let r = chk_bool(inp.enabled);
			if (r[1]) errors.enabled = r[1];
			else if ((r[0] == '1') != s.enabled) { f.enabled = (r[0] == '1'); acts[f.enabled ? 'USR2' : 'USR1'] = true; }
		}
		if (inp.mode != null) {
			if (!(inp.mode in [ 'all', 'pick' ])) errors.mode = 'bad_mode';
			else if (inp.mode != s.mode) { f.mode = inp.mode; acts.USR1 = true; }
		}
		if (inp.pick != null) {
			if (type(inp.pick) != 'array' || length(filter(inp.pick, (x) => !is_id(x)))) errors.pick = 'bad_value';
			else { let p = uniq_list(inp.pick); if (join(',', p) != join(',', s.pick)) { f.pick = p; acts.USR1 = true; } }
		}
		if (length(errors)) return { ok: false, code: 'invalid', errors: errors };
		if (!length(f)) return { ok: true, code: 'unchanged', id: s.id, actions: [] };
		if (!sub_write(u, s.id, f) || !u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		return { ok: true, code: 'saved', id: s.id, actions: acts.USR2 ? [ 'USR2' ] : (acts.USR1 ? [ 'USR1' ] : []) };
	}
	if (op == 'del') {
		let s = sub_find(u, inp.id ?? inp.url);
		if (!s) return { ok: false, code: 'not_found' };
		u.delete('vpnpool', s.id);
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		// favourites from it stay (kept with their links; "connect" brings one back)
		return { ok: true, code: 'deleted', id: s.id, actions: [ 'USR1' ] };
	}
	if (op == 'set_primary') {
		let url = inp.url;
		let prim = null;
		for (let s in subs_of(u)) if (s.mode == 'all') { prim = s; break; }
		if (type(url) != 'string') return { ok: false, code: 'bad_url', errors: { url: 'bad_url' } };
		if (prim && url == mask_url(prim.url)) return { ok: true, code: 'unchanged', actions: [] };
		if (url == '') {
			if (!prim) return { ok: true, code: 'unchanged', actions: [] };
			u.delete('vpnpool', prim.id);
			if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
			return { ok: true, code: 'saved', actions: [ 'USR2' ] };
		}
		let r = chk_url(url, false);
		if (r[1]) return { ok: false, code: r[1], errors: { url: r[1] } };
		if (prim && prim.url == r[0]) return { ok: true, code: 'unchanged', actions: [] };
		let sid = prim ? prim.id : sub_name_for(u, r[0]);
		if (!sub_write(u, sid, prim ? { url: r[0] } : { url: r[0], enabled: true, mode: 'all' }) || !u.commit('vpnpool'))
			return { ok: false, code: 'write_failed' };
		return { ok: true, code: 'saved', id: sid, actions: [ 'USR2' ] };
	}
	if (op == 'probe_pick') {
		// the nodes picked in the probe dialog (probe.sh cached the probed list of THIS url) ->
		// a subscription in "pick" mode taking exactly those ids (a new one, or this URL's own)
		let cache = read_json(SB + '/.probe-cache.json', null);
		if (type(cache) != 'object' || cache.url != inp.url || !length(inp.url)) return { ok: false, code: 'not_found' };
		let ids = [];
		if (inp.ids != null) {
			if (type(inp.ids) != 'array' || length(filter(inp.ids, (x) => !is_id(x)))) return { ok: false, code: 'invalid', errors: { ids: 'bad_value' } };
			ids = inp.ids;
		} else {
			if (type(inp.idx) != 'array') return { ok: false, code: 'invalid', errors: { idx: 'bad_type' } };
			let want = {};
			for (let i in inp.idx) want['' + i] = true;
			for (let n in (cache.nodes ?? [])) if (want['' + n.i] && is_id(n.id)) push(ids, n.id);
		}
		ids = uniq_list(ids);
		let s = sub_find(u, inp.url);
		let sid = s ? s.id : sub_name_for(u, inp.url);
		let f = { url: inp.url, mode: 'pick', pick: ids, enabled: true };
		if (!s && type(inp.name) == 'string') f.name = clean_name(inp.name);
		if (!sub_write(u, sid, f) || !u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
		return { ok: true, code: 'imported', id: sid, count: length(ids), actions: [ s && s.enabled ? 'USR1' : 'USR2' ] };
	}
	return { ok: false, code: 'unknown_method' };
}

// Trial download of a subscription URL: does it give nodes at all? (a typo / a panel port blocked
// from the router must not be stored silently). Short timeouts keep a call inside rpcd's budget.
function sub_probe(url) {
	mkdir(SB);
	let f = sprintf('%s/.subcheck.%s', SB, uniq());
	let http = trim(run(sprintf("curl -sfL --connect-timeout 4 -m 9 -A 'v2rayNG/1.9.5' -o %s -w '%%{http_code}' %s 2>/dev/null", sq(f), sq(url))));
	let n = 0;
	if ((stat(f)?.size ?? 0) > 0) {
		let v = null;
		try { v = json(run(sprintf('ucode %s %s 2>/dev/null', PARSER, sq(f)))); } catch (e) { v = null; }
		if (type(v) == 'array') n = length(v);
	}
	unlink(f);
	return { n: n, http: length(http) ? http : '000' };
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
	// options for the subscription URLs of this add (ROADMAP 9.1, "add URL: take every node / pick
	// nodes"): mode all|pick, pick = the ids to take, name (one URL only), enabled
	let opts = (type(input.options) == 'object') ? input.options : {};
	if (input.options != null && type(input.options) != 'object') return { ok: false, code: 'invalid', errors: { options: 'bad_type' } };
	let sub_mode = opts.mode ?? 'all';
	if (!(sub_mode in [ 'all', 'pick' ])) return { ok: false, code: 'invalid', errors: { 'options.mode': 'bad_mode' } };
	let sub_pick = [];
	if (opts.pick != null) {
		if (type(opts.pick) != 'array' || length(filter(opts.pick, (x) => !is_id(x))))
			return { ok: false, code: 'invalid', errors: { 'options.pick': 'bad_value' } };
		sub_pick = uniq_list(opts.pick);
	}
	let sub_label = (type(opts.name) == 'string') ? clean_name(opts.name) : null;
	let sub_on = (opts.enabled == null) ? true : (chk_bool(opts.enabled)[0] == '1');
	let pick = null;
	if (input.lines != null) {
		if (type(input.lines) != 'array') return { ok: false, code: 'invalid', errors: { lines: 'bad_type' } };
		pick = {};
		for (let l in input.lines) pick['' + l] = true;
	}
	let a = analyze(text, type(input.items) == 'array');
	let u = cursor();
	let added = 0, dup = 0, failed = [], acts = {}, addlinks = [], addurls = [], probes = [], addawg = [], awg_ids = [], sub_ids = [], warning = null;
	for (let it in a.items) {
		if (pick && !pick['' + it.line]) continue;
		if (it.status == 'dup') { dup++; continue; }
		if (it.status != 'add') {
			let fl = { line: it.line, reason: it.reason ?? it.status };
			if (it.field) fl.field = it.field;
			push(failed, fl);
			continue;
		}
		let line = a.lines[it.line];
		if (it.kind == 'subscription_url') {
			let pr = sub_probe(line);
			push(probes, { line: it.line, fetched: pr.n, http: pr.http });
			if (pr.n < 1) { push(failed, { line: it.line, reason: 'fetch_failed', http: pr.http }); continue; }
			push(addurls, line); acts[sub_on ? 'USR2' : 'none'] = true;
		} else if (it.kind == 'link') { push(addlinks, line); acts.USR1 = true; }
		else if (it.kind == 'awg' && AN.confs['' + it.line]) {
			let c = AN.confs['' + it.line];
			push(addawg, { id: c.id, name: c.name, conf: c.conf });
			if (it.deferred) warning = it.deferred;
			acts.USR1 = true;
		}
		else { push(failed, { line: it.line, reason: 'unsupported' }); continue; }
		added++;
	}
	// AWG / WireGuard: /etc/vpnpool/awg/<id>.conf, the name as a "# Name =" comment on top
	// (written atomically; the parser reads the name back as the node's tag)
	for (let a in addawg) {
		mkdir('/etc/vpnpool'); mkdir(AWG_DIR);
		let body = [ '# Name = ' + a.name ];
		for (let l in split(a.conf, /\r?\n/))
			if (!match(l, /^[#;][ \t]*[Nn][Aa][Mm][Ee][ \t]*=/)) push(body, l);
		let dst = AWG_DIR + '/' + a.id + '.conf', tmp = dst + '.tmp.' + time();
		if (!write_secret(tmp, join('\n', body) + '\n') || !rename(tmp, dst)) {
			unlink(tmp);
			return { ok: false, code: 'write_failed' };
		}
		push(awg_ids, a.id);
	}
	// a node re-added by the user gets a new try even if the start guard set it aside
	if (length(awg_ids)) {
		let bad = read_json(BAD_NODES, null);
		if (type(bad) == 'object') {
			let ch = false;
			for (let i in awg_ids) if (bad[i] != null) { delete bad[i]; ch = true; }
			if (ch) writefile(BAD_NODES, sprintf('%J', bad));
		}
	}
	if (length(addlinks) || length(addurls)) {
		let ml = as_list(u.get('vpnpool', 'main', 'manual_node'), true);
		for (let x in addlinks) push(ml, x);
		if (length(addlinks) && !u.set('vpnpool', 'main', 'manual_node', ml))
			return { ok: false, code: 'write_failed' };
		// every subscription is its own section (all subscriptions are equal, ROADMAP 9.1)
		for (let x in addurls) {
			let sid = sub_name_for(u, x);
			if (!sub_write(u, sid, { url: x, name: (length(addurls) == 1) ? sub_label : null,
			                         enabled: sub_on, mode: sub_mode, pick: sub_pick }))
				return { ok: false, code: 'write_failed' };
			push(sub_ids, sid);
		}
		if (!u.commit('vpnpool')) return { ok: false, code: 'write_failed' };
	}
	let actions = acts.USR2 ? [ 'USR2' ] : (acts.USR1 ? [ 'USR1' ] : []);
	let res = { ok: added > 0, code: added > 0 ? 'added' : 'nothing_added', added: added, dup: dup,
		failed: failed, probes: probes, actions: actions };
	if (length(awg_ids)) res.awg_ids = awg_ids;
	if (length(sub_ids)) res.sub_ids = sub_ids;
	// stored, but it waits for the AmneziaWG engine (deferred): say so
	if (added > 0 && ADD_WARN[warning]) res.warning = ADD_WARN[warning].warning;
	return res;
}

// ---------------------------------------------------------------- misc
// <kinds>: comma-separated "all" / "pick" (the mode of the subscriptions to look in) or "*"
function resolve_url(kinds, val) {
	let u = cursor(), all = [], want = {};
	for (let k in split(kinds, ',')) want[k] = true;
	for (let s in subs_of(u)) if (want['*'] || want[s.mode]) push(all, s.url);
	for (let x in all) if (x == val) return x;
	for (let x in all) if (str_key(x) == val) return x;
	for (let s in subs_of(u)) if (s.id == val && (want['*'] || want[s.mode])) return s.url;
	// two URLs on one host share the masked form: ambiguous -> nothing (use the key)
	let hit = filter(all, (x) => mask_url(x) == val);
	if (length(hit) > 1) return { ambiguous: true };
	return (length(hit) == 1) ? hit[0] : null;
}

// ---------------------------------------------------------------- import / restore check
// Options outside SCHEMA that a config may carry, with their check; anything else is kept as is
// (old versions' options, e.g. subscription_ua) — unknown options are not used by the scripts.
// A 1.x config (no schema '2', restored or imported) still has its stores by TAG and its
// subscriptions as main options: they are checked here and turned into the 2.0 model by
// migrate.sh after the restore / import.
const EXTRA_CHECKS = {
	enabled:          (v) => chk_bool(v),
	clash_api:        (v) => chk_re(v, /^[A-Za-z0-9.-]+:[0-9]{1,5}$/, 'bad_value', false),
	route_table:      (v) => chk_int(v, 1, 2147483647),
	route_priority:   (v) => chk_int(v, 1, 32767),
	speedtest_url:    (v) => chk_url(v, true),
	selected_node:    (v) => chk_tag(v),
	subscription_url: (v) => chk_url(v, true),
	probe_ua:         (v) => chk_re(v, /^[[:print:]]{1,1024}$/, 'bad_value', false),
	schema:           (v) => chk_re(v, /^[0-9]{1,3}$/, 'bad_value', false)
};
const EXTRA_URL_LISTS = { extra_sub: 1, source: 1 };
function check_config(dir, savedir) {
	let u = cursor(dir, savedir);
	let errors = {};
	let v2 = (u.get('vpnpool', 'main', 'schema') == DATA_SCHEMA);
	for (let f, d in SCHEMA) {
		let v = u.get('vpnpool', d.s, d.o ?? f);
		if (v == null) continue;
		// the node stores of a 1.x config hold tags (the migration maps them to ids); a 2.0 config
		// may name a node that is not in this router's pool: an id is checked by its form only
		let item = d.list, chk = d.c;
		if (f == 'auto_members') item = v2 ? ((x) => is_id(x) ? [ x, null ] : [ null, 'bad_tag' ]) : L_TAG;
		if (f == 'preferred_node') chk = v2 ? ((x) => is_id(x) ? [ x, null ] : [ null, 'bad_tag' ]) : chk_tag;
		if (d.list) {
			let r = chk_list(d.o ?? f, as_list(v, f != 'auto_members' || v2), item);
			if (r[1]) for (let k, c in r[1]) errors[k] = c;
			continue;
		}
		if (type(v) == 'array') { errors[d.o ?? f] = 'bad_type'; continue; }
		if (v == '') continue;                 // empty = unset = the default
		let r = chk(v);
		if (r[1]) errors[d.o ?? f] = r[1];
	}
	// 2.0 lists of node ids and the subscription sections
	for (let o in [ 'keep_auto', 'hidden' ]) {
		if (!v2) continue;
		let i = 0;
		for (let x in as_list(u.get('vpnpool', 'main', o), true)) { if (!is_id(x)) errors[o + '[' + i + ']'] = 'bad_tag'; i++; }
	}
	for (let sub in subs_of(u)) {
		let k = sub.id + '.';
		if (!is_url(sub.url)) errors[k + 'url'] = 'bad_url';
		let m = u.get('vpnpool', sub.id, 'mode');
		if (m != null && !(m in [ 'all', 'pick' ])) errors[k + 'mode'] = 'bad_mode';
		let en = u.get('vpnpool', sub.id, 'enabled');
		if (en != null && chk_bool(en)[1]) errors[k + 'enabled'] = 'bad_value';
		let i = 0;
		for (let x in as_list(u.get('vpnpool', sub.id, 'pick'), true)) { if (!is_id(x)) errors[k + 'pick[' + i + ']'] = 'bad_value'; i++; }
	}
	for (let o, c in EXTRA_CHECKS) {
		let v = u.get('vpnpool', 'main', o);
		if (v == null || v == '') continue;
		if (type(v) == 'array') { errors[o] = 'bad_type'; continue; }
		let r = c(v);
		if (r[1]) errors[o] = r[1];
	}
	for (let o in EXTRA_URL_LISTS) {
		let i = 0;
		for (let x in as_list(u.get('vpnpool', 'main', o), true)) {
			if (!is_url(x)) errors[o + '[' + i + ']'] = 'bad_url';
			i++;
		}
	}
	return length(errors) ? { ok: false, code: 'invalid', errors: errors } : { ok: true, code: 'ok' };
}

// subscription URLs (url of a subscription section; the 1.x options) carry the access token
const SECRET_URL_OPTS = { url: 1, subscription_url: 1, extra_sub: 1, source: 1 };
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
		           pending: length(filter(a.items, (i) => i.status == 'add' && i.deferred)) } });
} else if (cmd == 'add') {
	out(add(read_input()));
} else if (cmd == 'node') {
	out(node_op(ARGV[1] ?? '', read_input()));
} else if (cmd == 'sub') {
	out(sub_op(ARGV[1] ?? '', read_input()));
} else if (cmd == 'resolve_url') {
	let r = resolve_url(ARGV[1] ?? '', ARGV[2] ?? '');
	if (r == null) exit(1);
	if (type(r) == 'object') exit(3);
	print(r, '\n');
} else if (cmd == 'check_config') {
	out(check_config(ARGV[1], ARGV[2]));
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
	warn('usage: api.uc set_config|analyze|add|node <op>|sub <op>|resolve_url|check_config|check_domain|export|has_masked|b64enc|b64dec_field|backup_reply\n');
	exit(2);
}
