#!/usr/bin/env node
// Unit tests of resources/vpnpool/common.js outside the browser. The LuCI globals it uses
// (baseclass, rpc, ui, dom, E, _) and the DOM are small fakes that follow LuCI's real rules —
// in particular dom.append: a string passed as the ONLY child goes into innerHTML, strings in
// an array become text nodes (luci.js openwrt-23.05/24.10/25.12). Every innerHTML write is
// recorded, so a component that lets a string reach innerHTML is caught (XSS through node
// names). Timers are a fake clock.
//   node stand/tests/ui-common.test.js             -> "UNIT: passed=N failed=M", exit 1 on failure
//   node stand/tests/ui-common.test.js --negative  -> break common.js in memory, one mutation at
//                                                     a time; each must turn its tests red
//                                                     ("NEG: passed=N failed=M")
// Backend sources (codes, method list, ACL): the tree's by default; BACKEND_DIR=<dir> with
// rpcd (the rpcd plugin), api.uc, acl.json checks against another backend (e.g. files of the
// stage3 branch: git show stage3:<path> > <dir>/<name>).
'use strict';
const fs = require('fs');
const path = require('path');

const REPO = process.env.REPO_DIR || path.resolve(__dirname, '../..');
const APP = path.join(REPO, 'package/luci-app-vpnpool');
const SRC_PATH = path.join(APP, 'files/www/luci-static/resources/vpnpool/common.js');
const BD = process.env.BACKEND_DIR || '';
const RPCD = BD ? path.join(BD, 'rpcd') : path.join(APP, 'files/usr/libexec/rpcd/vpnpool');
const APIUC = BD ? path.join(BD, 'api.uc') : path.join(REPO, 'package/vpnpool/files/usr/libexec/vpnpool/api.uc');
const ACL = BD ? path.join(BD, 'acl.json') : path.join(APP, 'files/usr/share/rpcd/acl.d/luci-app-vpnpool.json');
const PARSER = BD ? path.join(BD, 'parser.uc') : path.join(REPO, 'package/vpnpool/files/usr/libexec/vpnpool/parser.uc');
const XSS = '<img src=x onerror="window.pwned=1">';

const { makeEnv, load } = require('./ui-fake.js');

// ---------- backend sources: codes and methods, extracted by FORM (not by helper name) ----------
const CODE_RE = /^[a-z][a-z0-9]*(_[a-z0-9]+)*$/;
const SHELL_WORDS = new Set([ 'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'case', 'esac', 'while', 'until', 'for', 'in', 'return', 'exit', 'echo', 'printf', 'test' ]);
function backendCodes() {
	const out = new Map();   // code -> where
	const add = (c, w) => { if (CODE_RE.test(c) && !out.has(c)) out.set(c, w); };
	const files = [ RPCD, APIUC ].filter(f => fs.existsSync(f));
	for (const f of files) {
		const s0 = fs.readFileSync(f, 'utf8');
		const b = path.basename(f);
		// code forms are read from code lines only (a comment may say "returns true if …")
		const s = s0.split('\n').filter(l => !/^\s*(#|\/\/)/.test(l)).join('\n');
		let m;
		// <fn> true|false <code>   (reply helper, whatever its name)
		for (m of s.matchAll(/(?:^|[;&|({]\s*|\s)([a-z_][a-z0-9_]*) (true|false) ([a-z][a-z0-9_]*)\b/gm))
			if (!SHELL_WORDS.has(m[1])) add(m[3], b + ': ' + m[1] + ' ' + m[2]);
		// code: "x" / code: 'x' / code:"x" / .code = "x" / warning:"x"
		for (m of s.matchAll(/\bcode\s*:\s*["']([a-z][a-z0-9_]*)["']/g)) add(m[1], b + ': code:');
		for (m of s.matchAll(/\.code\s*=\s*"([a-z][a-z0-9_]*)"/g)) add(m[1], b + ': .code =');
		for (m of s.matchAll(/\bwarning\s*:\s*["']([a-z][a-z0-9_]*)["']/g)) add(m[1], b + ': warning:');
		// code: (if … then "x" else "y" end)  (jq)
		for (m of s.matchAll(/\bcode\s*:\s*\(if ([^)]*)\)/g)) for (const q of m[1].matchAll(/"([a-z][a-z0-9_]*)"/g)) add(q[1], b + ': code:(if)');
		// [ null, 'x' ]  (api.uc value checks: field codes)
		for (m of s.matchAll(/\[\s*null\s*,\s*'([a-z][a-z0-9_]*)'\s*\]/g)) add(m[1], b + ': [null, code]');
		// documented lists: rpcd "# ---- Codes" block, api.uc "Field error codes" block
		const lines = s0.split('\n');
		let inBlock = false, block = null;
		for (const raw of lines) {
			if (/^#\s*-+\s*Codes\b/.test(raw) || /^\/\/\s*Field error codes/.test(raw)) { inBlock = true; continue; }
			if (!inBlock) continue;
			if (!/^(#|\/\/)/.test(raw) || /^#\s*-{3,}/.test(raw)) { inBlock = false; continue; }
			let l = raw.replace(/^(#|\/\/)/, '').replace(/\([^)]*\)?/g, ' ').replace(/^\s*(success|failure|warnings)\b[^:]*:/, ' ');
			const toks = l.trim().split(/\s+/).filter(Boolean);
			if (!toks.length) continue;
			if (/[a-z]+:/.test(l) && !/^\s*(success|failure)/.test(l)) {
				if (/^\s*analyze item/.test(l)) { inBlock = false; continue; }
			}
			// "<code>   description" -> the code; a bare list of codes -> all; a wrapped
			// description (indented deeper) -> nothing
			if (/^\s{20,}/.test(l)) continue;
			// success: lines = bare lists; failure: "<code> description" lines (a bare list only
			// when every word has an underscore); api.uc field block = bare lists
			const region = /^\s*(success|failure|warnings)\b/.test(raw.replace(/^(#|\/\/)/, '')) ? raw.match(/(success|failure|warnings)/)[1] : null;
			if (region) block = region;
			if (!CODE_RE.test(toks[0])) continue;
			if (block === 'failure' && !toks.every(t => CODE_RE.test(t) && t.includes('_'))) add(toks[0], b + ': documented');
			else if (toks.every(t => CODE_RE.test(t))) toks.forEach(t => add(t, b + ': documented list'));
		}
	}
	return out;
}
function backendList() {
	const s = fs.readFileSync(RPCD, 'utf8');
	const m = s.match(/^list\)\n\tcat <<'L'\n([\s\S]*?)\nL$/m);
	return m ? JSON.parse(m[1]) : null;
}

// ---------- tests ----------
const T = [];
function test(name, fn, opts) { T.push({ name, fn, opts: opts || {} }); }
function eq(a, b, what) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((what || 'value') + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b)); }
function ok(c, what) { if (!c) throw new Error(what || 'assertion failed'); }
async function rejectsWith(p) { try { await p; } catch (e) { return e; } throw new Error('expected a rejection, got a resolve'); }
const toasts = (env, kind) => env.mc.children.filter(n => n.classes && n.classes.has('vp-toast') && (!kind || n.classes.has(kind)));
const texts = (env, kind) => toasts(env, kind).map(n => n.textContent);
const key = (env, target, k, extra) => env.D.fire(target, 'keydown', Object.assign({ key: k }, extra || {}));
const click = (env, target) => env.D.fire(target, 'click', {});

test('ok reply resolves with the object', async (C, env) => {
	env.handlers.status = () => ({ nodes: [1, 2] });
	const r = await C.call('status');
	eq(r.nodes.length, 2, 'nodes');
	eq(toasts(env).length, 0, 'toasts on a plain success');
});
test('ok:false -> Error with its code and the human text, one error toast', async (C, env) => {
	env.handlers.select = () => ({ ok: false, code: 'not_found', daemon: 'n/a', error: 'not_found' });
	const e = await rejectsWith(C.call('select', { tag: 'x' }));
	ok(e instanceof C.Error, 'instance of common.Error');
	eq(e.code, 'not_found', 'code');
	eq(e.text, C.CODE_TEXT.not_found, 'text');
	eq(texts(env, 'danger'), [ C.CODE_TEXT.not_found ], 'error toasts');
});
test('args are forwarded by name', async (C, env) => {
	env.handlers.set_option = () => ({ ok: true, code: 'saved' });
	await C.call('set_option', { name: 'a', value: 'b' });
	eq(env.rpcLog[env.rpcLog.length - 1], [ 'set_option', { name: 'a', value: 'b' } ], 'rpc params');
	env.handlers.analyze = () => ({ ok: true });
	await C.call('analyze', { text: 'vless://x', extra: 1 });
	eq(env.rpcLog[env.rpcLog.length - 1], [ 'analyze', { text: 'vless://x', extra: 1 } ], 'unknown arg kept');
});
test('legacy {error:"…"} replies and pre-stage-3 codes map to today\'s codes', async (C, env) => {
	env.handlers.node_link = () => ({ error: 'no link for tag' });
	eq((await rejectsWith(C.call('node_link', { tag: 'x' }, { quiet: true }))).code, 'not_found', 'no link for tag');
	env.handlers.import = () => ({ error: 'empty config' });
	eq((await rejectsWith(C.call('import', { config: '' }, { quiet: true }))).code, 'incomplete_config', 'empty config');
	env.handlers.add_node = () => ({ error: 'something new' });
	const e = await rejectsWith(C.call('add_node', { link: 'x' }, { quiet: true }));
	eq(e.code, 'failed', 'unknown legacy error');
	eq(e.text, C.CODE_TEXT.failed, 'fallback text');
	env.handlers.select = () => ({ ok: false, code: 'no_tag', daemon: 'n/a' });
	eq((await rejectsWith(C.call('select', {}, { quiet: true }))).code, 'bad_tag', 'old no_tag -> bad_tag');
	for (const [k, v] of Object.entries(C.LEGACY_ERROR)) ok(C.codeText(v) != null, 'legacy "' + k + '" -> ' + v + ' has a text');
	for (const [k, v] of Object.entries(C.CODE_ALIAS)) ok(C.codeText(v) != null, 'alias ' + k + ' -> ' + v + ' has a text');
});
test('ubus status codes: 3 -> method_missing, 6 -> access_denied, 0 -> done', async (C, env) => {
	eq((await rejectsWith(C.call('backup', {}, { quiet: true }))).code, 'method_missing', 'no handler = ubus 3');
	env.handlers.refresh = () => 6;
	eq((await rejectsWith(C.call('refresh', {}, { quiet: true }))).code, 'access_denied', 'ubus 6');
	env.handlers.ping = () => 0;
	eq((await C.call('ping')).constructor, Object, 'ubus 0 resolves');
});
test('transport errors -> human codes; a session expiry is passed through without a toast', async (C, env) => {
	env.handlers.diag = () => new Error('RPC call to vpnpool/diag failed with error -32002: Access denied');
	eq((await rejectsWith(C.call('diag'))).code, 'access_denied', '-32002');
	env.handlers.diag = () => new Error('RPC call to vpnpool/diag failed with HTTP error 502: Bad Gateway');
	eq((await rejectsWith(C.call('diag'))).code, 'connection', 'HTTP 502');
	env.handlers.diag = () => { const e = new Error('Request timed out'); e.name = 'TimeoutError'; return e; };
	eq((await rejectsWith(C.call('diag'))).code, 'timeout', 'timeout');
	env.handlers.diag = () => new Error('RPC call to vpnpool/analyze failed with error -32700: Parse error');
	eq((await rejectsWith(C.call('diag'))).code, 'too_large', '-32700 (a request over the web server limit)');
	const before = toasts(env).length;
	env.handlers.diag = () => { const e = new Error('Login session is expired'); e.name = 'SessionError'; return e; };
	const s = await rejectsWith(C.call('diag'));
	ok(!(s instanceof C.Error) && s.name === 'SessionError', 'session error passed through');
	eq(toasts(env).length, before, 'no toast for an expired session');
});
test('non-object replies are bad_reply, never success', async (C, env) => {
	for (const v of [ [1, 2], 'text', null ]) {
		env.handlers.leases = () => v;
		eq((await rejectsWith(C.call('leases', {}, { quiet: true }))).code, 'bad_reply', 'reply ' + JSON.stringify(v));
	}
});
test('quiet / handle: no toast; success text + "service is off" note', async (C, env) => {
	env.handlers.set_domains = () => ({ ok: false, code: 'bad_value' });
	await rejectsWith(C.call('set_domains', { domains: [] }, { quiet: true }));
	eq(toasts(env).length, 0, 'quiet error');
	env.handlers.restore = () => ({ ok: false, code: 'confirm_required', report: {} });
	const e = await rejectsWith(C.call('restore', { data: 'x' }, { handle: [ 'confirm_required' ] }));
	eq([ e.code, toasts(env).length ], [ 'confirm_required', 0 ], 'handled code: no toast');
	env.handlers.set_domains = () => ({ ok: true, code: 'saved', daemon: 'not_running' });
	await C.call('set_domains', { domains: [] }, { success: 'Domains saved.' });
	eq(texts(env, 'info').length, 1, 'info toasts');
	ok(/^Domains saved\. The service is off/.test(texts(env, 'info')[0]), 'note about the stopped service: ' + texts(env, 'info')[0]);
	env.handlers.set_domains = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	await C.call('set_domains', { domains: [] }, { success: r => 'Saved ' + r.code });
	eq(texts(env, 'info'), [ 'Saved saved' ], 'function success text, no note');
});
test('ok:true with a warning is a warning that stays, not a success', async (C, env) => {
	env.handlers.set_config = () => ({ ok: true, code: 'saved', warning: 'schedule_failed', daemon: 'signalled' });
	const r = await C.call('set_config', { settings: { sched_enabled: 1 } }, { success: 'Saved.' });
	eq(r.warning, 'schedule_failed', 'reply passed through');
	eq(texts(env, 'info'), [], 'no success toast');
	eq(texts(env, 'warning'), [ C.CODE_TEXT.schedule_failed ], 'warning toast');
	await env.tick(60000);
	eq(texts(env, 'warning').length, 1, 'warning still there after a minute');
});
test('restore_failed without a rollback says the old state is NOT back', async (C, env) => {
	env.handlers.restore = () => ({ ok: false, code: 'restore_failed', rolled_back: false });
	const e = await rejectsWith(C.call('restore', { data: 'x', replace_all: true }, { quiet: true }));
	ok(e.text !== C.CODE_TEXT.restore_failed && /could not be put back/.test(e.text), 'text: ' + e.text);
	env.handlers.restore = () => ({ ok: false, code: 'restore_failed', rolled_back: true });
	eq((await rejectsWith(C.call('restore', { data: 'x', replace_all: true }, { quiet: true }))).text, C.CODE_TEXT.restore_failed, 'rolled back');
});
test('field errors: texts per field and marks next to the form fields', async (C, env) => {
	env.handlers.set_config = () => ({ ok: false, code: 'invalid', errors: { interval: 'too_small', dns: 'bad_ipv4', weird: 'zzz' } });
	const e = await rejectsWith(C.call('set_config', { settings: {} }, { quiet: true }));
	eq(e.code, 'invalid', 'code');
	eq(C.fieldErrors(e), { interval: C.FIELD_TEXT.too_small, dns: C.FIELD_TEXT.bad_ipv4, weird: C.FIELD_TEXT.bad_value }, 'fieldErrors');
	const D = env.D, form = D.E('div', {}, [ D.E('div', { 'data-field': 'interval' }), D.E('div', { 'id': 'cbid.json.main.dns' }) ]);
	env.doc.body.appendChild(form);
	const miss = C.markFieldErrors(form, e, { section: 'main' });
	eq(miss, [ 'weird' ], 'not found fields');
	eq(form.querySelectorAll('.vp-field-error-text').map(n => n.textContent), [ C.FIELD_TEXT.too_small, C.FIELD_TEXT.bad_ipv4 ], 'marks');
	C.markFieldErrors(form, { errors: {} });
	eq(form.querySelectorAll('.vp-field-error-text').length, 0, 'old marks removed');
	eq(env.doc.unsafe, [], 'no innerHTML');
});
test('one info toast; errors stay, one per action, different actions all shown', async (C, env) => {
	C.toast('A'); C.toast('B'); C.toast('C');
	eq(texts(env, 'info'), [ 'C' ], 'the last info only');
	C.toast('E1', 'error'); C.toast('E2', 'error');
	eq(texts(env, 'danger'), [ 'E2' ], 'same key: replaced');
	env.handlers.ping = () => ({ ok: false, code: 'daemon_not_running' });
	env.handlers.refresh = () => ({ ok: false, code: 'clash_failed' });
	await rejectsWith(C.call('ping'));
	await rejectsWith(C.call('refresh'));
	eq(texts(env, 'danger').sort(), [ 'E2', C.CODE_TEXT.clash_failed, C.CODE_TEXT.daemon_not_running ].sort(), 'errors of different actions coexist');
	await rejectsWith(C.call('ping'));
	eq(texts(env, 'danger').length, 3, 'a repeated error of the same action replaces its own');
	C.toast('D');
	await env.tick(C.INFO_MS + 700);
	eq(texts(env, 'info'), [], 'info faded');
	await env.tick(60000);
	eq(texts(env, 'danger').length, 3, 'errors still there a minute later');
	for (let i = 0; i < 10; i++) C.toast('X' + i, 'error', 'k' + i);
	eq(texts(env, 'danger').length, C.MAX_STICKY, 'capped');
	ok(texts(env, 'danger').includes('X9') && !texts(env, 'danger').includes('X0'), 'the oldest went first');
	C.clearToast();
	eq(toasts(env).length, 0, 'clearToast');
});
test('a later success of the same method removes its stale error toast', async (C, env) => {
	env.handlers.ping = (p, n) => n === 1 ? { ok: false, code: 'already_running' } : { ok: true, code: 'started' };
	env.handlers.ping = (p, n) => n === 1 ? { ok: false, code: 'daemon_not_running' } : { ok: true, code: 'started' };
	await rejectsWith(C.call('ping'));
	eq(toasts(env, 'danger').length, 1, 'error shown');
	env.handlers.status = () => ({});
	await C.call('status');
	eq(toasts(env, 'danger').length, 1, 'another method does not clear it');
	await C.call('ping');
	eq(toasts(env, 'danger').length, 0, 'the same method succeeded');
});
test('LuCI 23.05 (no addTimeLimitedNotification): info still fades by its own timer', async (C, env) => {
	C.toast('old luci');
	eq(env.ui.calls.filter(c => c[0] === 'timed').length, 0, 'no timed api used');
	eq(toasts(env, 'info').length, 1, 'shown');
	await env.tick(C.INFO_MS + 700);
	eq(toasts(env, 'info').length, 0, 'faded');
}, { luci2305: true });
test('waitFor polls until the predicate holds', async (C, env) => {
	env.handlers.status = (p, n) => ({ busy: { fetch: n < 3 } });
	let done = null; C.waitFor(st => !st.busy.fetch, { interval: 1000, timeout: 10000 }).then(r => { done = r; });
	await env.tick(5000);
	ok(done, 'resolved');
	eq(env.rpcLog.filter(x => x[0] === 'status').length, 3, 'status polls');
});
test('waitFor times out with code timeout; access errors stop at once', async (C, env) => {
	env.handlers.status = () => ({ busy: { fetch: true } });
	let err = null; C.waitFor(st => false, { interval: 1000, timeout: 3000 }).catch(e => { err = e; });
	await env.tick(5000);
	ok(err && err.code === 'timeout', 'timeout code: ' + (err && err.code));
	const n0 = env.rpcLog.length;
	env.handlers.status = () => 6;
	let err2 = null; C.waitFor(st => true, { interval: 1000, timeout: 30000 }).catch(e => { err2 = e; });
	await env.tick(5000);
	ok(err2 && err2.code === 'access_denied', 'access_denied');
	eq(env.rpcLog.length - n0, 1, 'polls after access denied');
	eq(toasts(env).length, 0, 'waitFor itself shows no toast');
});
test('waitFor retries connection hiccups', async (C, env) => {
	env.handlers.status = (p, n) => n === 1 ? new Error('RPC call to vpnpool/status failed with HTTP error 502: x') : { ready: true };
	let r = null; C.waitFor(st => st.ready, { interval: 1000, timeout: 10000 }).then(x => { r = x; });
	await env.tick(3000);
	ok(r && r.ready, 'resolved after a failed poll');
});
test('waitIdle(build): done only when build.at moved; an already running build does not count', async (C, env) => {
	// a scheduled build is running when we ask; it ends (at=100 -> 150 is ITS mark? no: ours
	// is the one after since=150); then ours runs and finishes at 200
	const seq = [ { busy: { build: true }, build: { at: 150 } }, { busy: {}, build: { at: 150 } },
		{ busy: {}, build: { at: 150 } }, { busy: { build: true }, build: { at: 150 } }, { busy: {}, build: { at: 200 } } ];
	env.handlers.status = (p, n) => seq[Math.min(n - 1, seq.length - 1)];
	let r = null; C.waitIdle('build', { since: 150, interval: 1000, timeout: 30000, grace: 100000 }).then(x => { r = x; });
	await env.tick(3500);
	ok(!r, 'not done while the mark did not move (the old build ended)');
	await env.tick(2000);
	ok(r && r.done === true && r.status.build.at === 200, 'done after the mark moved: ' + JSON.stringify(r));
	eq(C.stampOf('fetch', { subscriptions: [ { last_fetch_at: 5 }, { last_fetch_at: 9 }, {} ] }), 9, 'fetch mark = newest last_fetch_at');
	ok(C.isBusy({ busy: { ping: 1 } }) && !C.isBusy({ busy: { ping: 0 } }) && !C.isBusy({}) && C.isBusy({ busy: { a: 0, b: true } }, 'b'), 'isBusy');
});
test('waitIdle: a job never seen running is NOT reported as done', async (C, env) => {
	env.handlers.status = () => ({ busy: {}, build: { at: 100 } });
	let r = null; C.waitIdle('build', { interval: 1000, timeout: 30000 }).then(x => { r = x; });
	await env.tick(5000);
	ok(r && r.done === false, 'done:false after the grace: ' + JSON.stringify(r && r.done));
	env.rpcLog.length = 0;
	const seq = [ { busy: {} }, { busy: { ping: true } }, { busy: {} } ];
	env.handlers.status = (p, n) => seq[Math.min(n - 1, 2)];
	let r2 = null; C.waitIdle('ping', { interval: 1000, timeout: 30000, grace: 100000 }).then(x => { r2 = x; });
	await env.tick(1500);
	ok(!r2, 'ping: not done on the first idle poll');
	await env.tick(3000);
	ok(r2 && r2.done === true, 'ping: done after busy -> idle');
});

// --- components: everything shown is text, never innerHTML (LuCI E()/showModal rule)
test('fake DOM positive control: a bare string child IS recorded as innerHTML', async (C, env) => {
	env.D.E('b', {}, '<i>x</i>');
	eq(env.doc.unsafe.length, 1, 'recorded');
	env.D.E('b', {}, [ '<i>x</i>' ]);
	eq(env.doc.unsafe.length, 1, 'a string in an array is text');
});
test('foreign strings stay text in every component (node names with markup)', async (C, env) => {
	const D = env.D;
	const card = C.nodeCard({ id: 'n', title: XSS, sub: XSS, state: XSS, badges: [ { text: XSS, kind: 'ok', title: XSS }, XSS ],
		onSelect() {}, primary: { label: XSS, handler() {} }, menu: [ { label: XSS, handler() {} } ], menuLabel: XSS });
	env.doc.body.appendChild(card);
	C.updateNodeCard(card, { title: XSS + '2', badges: [ { text: XSS } ], primary: { label: XSS } });
	env.doc.body.appendChild(C.badge(XSS, 'ok', XSS));
	env.doc.body.appendChild(C.emptyState({ title: XSS, text: XSS, actions: [ { label: XSS, handler() {} } ] }));
	env.doc.body.appendChild(C.header(XSS));
	env.doc.body.appendChild(C.menu([ { label: XSS, handler() {} } ], { label: XSS }));
	C.toast(XSS); C.toast(XSS, 'error'); C.toast(XSS, 'warning', 'w');
	C.confirm({ title: XSS, text: XSS, consequences: [ XSS, XSS ], confirm: XSS, cancel: XSS });
	env.handlers.select = () => ({ ok: true, code: 'applied' });
	await C.call('select', { tag: XSS }, { success: 'Connected to ' + XSS });
	eq(env.doc.unsafe, [], 'innerHTML writes');
	ok(card.querySelector('.vp-card-title').textContent === XSS + '2', 'card title kept as text');
	const dlg = env.D.doc.body.querySelector('.vp-confirm');
	ok(dlg && dlg.querySelector('h4').textContent === XSS, 'dialog title as text');
	ok(texts(env, 'info')[0] === 'Connected to ' + XSS, 'toast text');
	void D;
});
test('common.E: every call form keeps strings as text', async (C, env) => {
	const a = C.E('p', {}, XSS), b = C.E('p', XSS), c = C.E('td', {}, 0), d = C.E('p', null, XSS),
		e = C.E('div', {}, [ XSS, C.E('b', {}, XSS) ]), f = C.E('div', {}, C.E('i', {}, 'n')), g = C.E('p', { 'class': 'x' });
	eq(env.doc.unsafe, [], 'innerHTML writes');
	eq([ a.textContent, b.textContent, c.textContent, d.textContent, e.textContent, f.textContent ], [ XSS, XSS, '0', XSS, XSS + XSS, 'n' ], 'texts');
	ok(g.classes.has('x') && g.children.length === 0, 'attrs only');
});
test('old views: E is common.E, dialog titles are text', async (C) => {
	const dir = path.join(APP, 'files/www/luci-static/resources/view/vpnpool');
	const views = fs.readdirSync(dir).filter(f => f.endsWith('.js') && !f.startsWith('_'));
	ok(views.length >= 5, 'positive control: views found ' + views.length);
	const bad = [];
	for (const f of views) {
		const s = fs.readFileSync(path.join(dir, f), 'utf8');
		if (!/^'require vpnpool\.common as common';$/m.test(s)) bad.push(f + ': no \'require vpnpool.common as common\'');
		const code = s.replace(/^\s*\/\/.*$/mg, ''); // comments may mention E(
		const decl = code.search(/^var E = common\.E;$/m), use = code.search(/[^A-Za-z0-9_$.]E\(/);
		if (decl < 0) bad.push(f + ': no "var E = common.E;"');
		else if (use >= 0 && use < decl) bad.push(f + ': E( used before "var E = common.E;"');
		for (const m of s.matchAll(/ui\.showModal\(\s*([^,]+?),/g))
			if (!/^_\('(?:[^'\\]|\\.)*'\)$/.test(m[1].trim()) && !/^common\.txt\(/.test(m[1].trim())) bad.push(f + ': showModal title not text: ' + m[1].trim());
		if (/\.innerHTML\b|insertAdjacentHTML|dom\.parse\(/.test(s)) bad.push(f + ': raw HTML sink');
	}
	eq(bad, [], 'unsafe spots in the views');
});
test('menu: keyboard, Escape returns focus, one open at a time, click outside', async (C, env) => {
	let hit = 0;
	const m = C.menu([ { label: 'A', handler() { hit++; } }, { label: 'X', disabled: true }, { label: 'B', handler() {} } ]);
	const m2 = C.menu([ { label: 'Z', handler() {} } ]);
	env.doc.body.appendChild(m); env.doc.body.appendChild(m2);
	const btn = m.querySelector('.vp-menu-btn'), list = m.querySelector('.vp-menu-list');
	eq(btn.getAttribute('aria-controls'), list.id, 'aria-controls');
	btn.focus(); key(env, btn, 'ArrowDown');
	ok(!list.hidden && btn.getAttribute('aria-expanded') === 'true', 'opened');
	eq(env.doc.activeElement.textContent, 'A', 'first item focused');
	key(env, list, 'ArrowDown'); eq(env.doc.activeElement.textContent, 'B', 'disabled skipped');
	key(env, list, 'ArrowDown'); eq(env.doc.activeElement.textContent, 'A', 'wraps');
	key(env, list, 'Escape');
	ok(list.hidden && env.doc.activeElement === btn, 'Escape closes and returns focus');
	click(env, btn); click(env, m2.querySelector('.vp-menu-btn'));
	ok(list.hidden && !m2.querySelector('.vp-menu-list').hidden, 'second menu closes the first');
	click(env, env.doc.body);
	ok(m2.querySelector('.vp-menu-list').hidden, 'click outside closes');
	click(env, btn); click(env, list.querySelectorAll('.vp-menu-item')[0]);
	ok(hit === 1 && list.hidden, 'item runs its handler and closes');
});
test('confirm: focus on Cancel, Escape = Cancel, Tab stays inside, focus comes back', async (C, env) => {
	const opener = env.D.E('button', {}, [ 'open' ]); env.doc.body.appendChild(opener); opener.focus();
	let v = null; C.confirm({ title: 't', consequences: [ 'c1', '', null, 'c2' ] }).then(x => { v = x; });
	const dlg = env.doc.body.querySelector('.vp-confirm');
	eq(dlg.querySelectorAll('li').map(n => n.textContent), [ 'c1', 'c2' ], 'consequences (empty ones dropped)');
	ok(env.doc.activeElement.classes.has('vp-confirm-cancel'), 'focus on Cancel');
	const ok_ = dlg.querySelector('.vp-confirm-ok');
	ok_.focus(); key(env, ok_, 'Tab');
	ok(env.doc.activeElement.classes.has('vp-confirm-cancel'), 'Tab from the last wraps to the first');
	key(env, env.doc.activeElement, 'Tab', { shiftKey: true });
	ok(env.doc.activeElement.classes.has('vp-confirm-ok'), 'Shift+Tab from the first goes to the last');
	key(env, env.doc.activeElement, 'Escape'); await env.flush();
	eq(v, false, 'Escape = Cancel');
	ok(!env.ui.modalOpen, 'dialog closed');
	ok(env.doc.activeElement === opener, 'focus back on the opener');
	let v2 = null; C.confirm({ title: 't' }).then(x => { v2 = x; });
	click(env, env.doc.body.querySelector('.vp-confirm-ok')); await env.flush();
	eq(v2, true, 'Continue = true');
});
test('confirm replaced by another dialog: resolves false, never closes the other one', async (C, env) => {
	let v = null; C.confirm({ title: 't' }).then(x => { v = x; });
	env.ui.showModal('Session expired', [ env.D.E('p', {}, [ 'log in' ]) ]);
	const hides = env.ui.calls.filter(c => c[0] === 'hideModal').length;
	key(env, env.doc.body, 'Escape'); await env.flush();
	eq(v, false, 'resolved false');
	eq(env.ui.calls.filter(c => c[0] === 'hideModal').length, hides, 'the other dialog was not closed');
	ok(env.ui.modalOpen, 'still open');
});
test('node card: cell updates keep the elements; dimming does not touch the menu', async (C, env) => {
	const card = C.nodeCard({ id: 1, title: 'A', sub: '10 ms', state: 's', primary: { label: 'Connect', handler() {} }, menu: [ { label: 'x', handler() {} } ] });
	const t = card.querySelector('.vp-card-title'), p = card.querySelector('.vp-card-primary');
	p.focus();
	C.updateNodeCard(card, { title: 'B', sub: '20 ms', dimmed: true, active: true, primary: { disabled: true } });
	ok(card.querySelector('.vp-card-title') === t && t.textContent === 'B', 'same title element, new text');
	ok(env.doc.activeElement === p && p.disabled, 'focus kept, button disabled');
	ok(card.classes.has('vp-dimmed') && card.classes.has('vp-active'), 'classes');
	const css = env.doc.head.querySelector('style').textContent;
	ok(!/\.vp-card\.vp-dimmed\{opacity/.test(css), 'no opacity on the whole dimmed card (would dim its menu)');
	ok(/\.vp-card\.vp-dimmed \.vp-card-head[^{]*\{opacity/.test(css), 'dims the content');
});

// --- packaging: the translation reaches the router, stand-only pages do not
test('packaging: translation in installer, feeds and CI; stand-only pages left out', async () => {
	const rd = p => fs.readFileSync(path.join(REPO, p), 'utf8');
	const mk = rd('package/luci-app-vpnpool/Makefile'), inst = rd('install.sh'), pages = rd('.github/workflows/pages.yml'),
		build = rd('.github/workflows/build.yml'), dep = rd('scripts/deploy.sh');
	const bad = [];
	if (!/^\trm -f \$\(1\)\/www\/luci-static\/resources\/view\/vpnpool\/_\*\.js$/m.test(mk)) bad.push('Makefile: _*.js not removed from the package');
	if (!/^include \$\(TOPDIR\)\/feeds\/luci\/luci\.mk$/m.test(mk)) bad.push('Makefile: not built with luci.mk (no translation package)');
	if (!/I18N_GLOB="luci-i18n-vpnpool-ru-\[0-9\]\*\.apk"/.test(inst) || !/I18N_GLOB="luci-i18n-vpnpool-ru_\*\.ipk"/.test(inst)) bad.push('install.sh: no translation package glob');
	if ((inst.match(/^\tinstall_i18n\b/mg) || []).length < 2) bad.push('install.sh: translation not installed in both flows');
	if (!/luci-i18n-vpnpool-ru_\*\.ipk/.test(pages) || !/luci-i18n-vpnpool-ru-\[0-9\]\*\.apk/.test(pages) || !/expected 3 \.ipk/.test(pages)) bad.push('pages.yml: translation not published');
	if (!/luci-i18n-vpnpool-ru_\*\.ipk/.test(build) || !/expected 3/.test(build)) bad.push('build.yml: translation not collected');
	if (!/ui-common\.test\.js --negative/.test(build) || !/ui-nodes\.test\.js --negative/.test(build) ||!/ui-i18n\.sh check/.test(build) || !/ui-components\.sh/.test(build)) bad.push('build.yml: UI checks not run in CI');
	if (!/vpnpool\.ru\.lmo/.test(dep) || !/--exclude='\.\/www\/luci-static\/resources\/view\/vpnpool\/_\*'/.test(dep)) bad.push('deploy.sh: translation / stand-only pages');
	eq(bad, [], 'packaging');
});

// --- the backend contract
test('every code the backend answers with has a human text', async (C) => {
	const codes = backendCodes();
	if (process.env.T_CODES) console.log('# backend codes (' + codes.size + '): ' + [ ...codes.keys() ].sort().join(' '));
	const min = fs.existsSync(APIUC) ? 50 : 10;   // positive control: the extraction found the lists
	ok(codes.size >= min, 'positive control: ' + codes.size + ' codes extracted from ' + [ RPCD, APIUC ].filter(f => fs.existsSync(f)).join(', ') + ' (want >= ' + min + ')');
	const miss = [ ...codes.keys() ].filter(c => C.codeText(c) == null).map(c => c + ' (' + codes.get(c) + ')');
	eq(miss, [], 'codes without a text');
	const legacy = [ ...new Set([ ...fs.readFileSync(RPCD, 'utf8').matchAll(/"error":"([^"]+)"/g) ].map(x => x[1]).filter(x => !CODE_RE.test(x))) ];
	eq(legacy.filter(x => !C.LEGACY_ERROR[x]), [], 'old {error:"text"} replies without a code');
	if (fs.existsSync(APIUC)) {
		const field = [ ...codes.entries() ].filter(([c, w]) => /api\.uc: (\[null|documented)/.test(w)).map(([c]) => c);
		ok(field.length >= 10, 'positive control: field codes ' + field.length);
		eq(field.filter(c => !C.FIELD_TEXT[c]), [], 'field codes without a field text');
	}
});
// reasons a pasted line is not added (analyze / add, the "+ Add" dialog of the Nodes tab): the
// parser's and api.uc's reason codes, read by FORM from their code lines
function backendReasons() {
	const out = new Map();
	const add = (c, w) => { if (CODE_RE.test(c) && !out.has(c)) out.set(c, w); };
	for (const f of [ PARSER, APIUC ].filter(x => fs.existsSync(x))) {
		const b = path.basename(f);
		const s = fs.readFileSync(f, 'utf8').split('\n').filter(l => !/^\s*\/\//.test(l)).join('\n');
		let m;
		for (m of s.matchAll(/\breason\s*[:=]\s*'([a-z][a-z0-9_]*)'/g)) add(m[1], b + ': reason');
		for (m of s.matchAll(/\berr\s*:\s*'([a-z][a-z0-9_]*)'/g)) add(m[1], b + ': err');
		for (m of s.matchAll(/\bE_[A-Z_]+\s*:\s*'([a-z][a-z0-9_]*)'/g)) add(m[1], b + ': decoder code');
		if (b === 'parser.uc') for (m of s.matchAll(/\breturn '([a-z][a-z0-9]*_[a-z0-9_]+)';/g)) add(m[1], b + ': check result');
	}
	return out;
}
test('every reason the backend gives for a pasted line has a human text', async (C) => {
	const rs = backendReasons();
	if (process.env.T_CODES) console.log('# backend reasons (' + rs.size + '): ' + [ ...rs.keys() ].sort().join(' '));
	ok(rs.size >= 25, 'positive control: ' + rs.size + ' reasons extracted from ' + [ PARSER, APIUC ].filter(f => fs.existsSync(f)).join(', ') + ' (want >= 25)');
	const miss = [ ...rs.keys() ].filter(c => !(C.REASON_TEXT[c] || C.CODE_TEXT[c] || C.FIELD_TEXT[c])).map(c => c + ' (' + rs.get(c) + ')');
	eq(miss, [], 'reasons without a text');
	eq(C.reasonText('no_such_reason_x'), C.REASON_TEXT.parse_error, 'unknown reason -> "could not be read"');
	eq(C.reasonText('exists'), C.REASON_TEXT.exists, 'own reason text first');
	eq(C.reasonText('fetch_failed'), C.CODE_TEXT.fetch_failed, 'then the code text');
});
test('every rpcd method and every ACL method is declared in METHODS with the same arguments', async (C) => {
	const listed = backendList();
	ok(listed, 'rpcd list block found');
	const acl = JSON.parse(fs.readFileSync(ACL, 'utf8'))['luci-app-vpnpool'];
	const aclm = [].concat(acl.read.ubus.vpnpool, acl.write.ubus.vpnpool);
	ok(Object.keys(listed).length >= 40 && aclm.length >= 40, 'positive control: methods found rpcd=' + Object.keys(listed).length + ' acl=' + aclm.length);
	const miss = [ ...new Set(Object.keys(listed).concat(aclm)) ].filter(x => !C.METHODS[x]);
	eq(miss, [], 'methods missing in common.js METHODS');
	const args = Object.keys(listed).filter(m => JSON.stringify(Object.keys(listed[m]).sort()) !== JSON.stringify(C.METHODS[m].params.slice().sort()))
		.map(m => m + ': backend ' + JSON.stringify(Object.keys(listed[m])) + ' vs ' + JSON.stringify(C.METHODS[m].params));
	eq(args, [], 'arguments differ');
	const rd = new Set(acl.read.ubus.vpnpool);
	const wrongRw = Object.keys(C.METHODS).filter(k => (rd.has(k) && C.METHODS[k].write) || (aclm.includes(k) && !rd.has(k) && !C.METHODS[k].write));
	eq(wrongRw, [], 'read/write class differs from the ACL');
});

// ---------- runner ----------
async function run(src, quiet) {
	let pass = 0, fail = 0;
	const failed = [];
	for (const t of T) {
		const env = makeEnv(t.opts);
		try {
			const C = load(src, env);
			await t.fn(C, env);
			pass++;
			if (!quiet) console.log('ok   - ' + t.name);
		} catch (e) {
			fail++;
			failed.push(t.name);
			if (!quiet) console.log('FAIL - ' + t.name + ': ' + (e && e.message));
		}
	}
	return { pass, fail, failed };
}

const MUTATIONS = [
	{ name: 'ok:false treated as success', from: "if (ret.ok === false) {", to: "if (false) {", expect: [ 'ok:false -> Error with its code and the human text, one error toast' ] },
	{ name: 'legacy error ignored', from: "if (typeof ret.error === 'string' || (ret.error != null && ret.ok !== true))", to: "if (false)", expect: [ 'legacy {error:"…"} replies and pre-stage-3 codes map to today\'s codes' ] },
	{ name: 'array reply accepted', from: "if (ret == null || typeof ret !== 'object' || Array.isArray(ret))", to: "if (ret == null || typeof ret !== 'object')", expect: [ 'non-object replies are bad_reply, never success' ] },
	{ name: 'info toast not replaced', from: "\t\tremoveNode(toastInfo);\n\t\tvar n = addToast", to: "\t\tvar n = addToast", expect: [ 'one info toast; errors stay, one per action, different actions all shown' ] },
	{ name: 'one error slot for all actions (M3)', from: "dropSticky(key);\n\t\t\tvar s = addToast", to: "dropSticky(null);\n\t\t\tvar s = addToast", expect: [ 'one info toast; errors stay, one per action, different actions all shown' ] },
	{ name: 'errors pile up for the same action', from: "dropSticky(key);\n\t\t\tvar s = addToast", to: "var s = addToast", expect: [ 'one info toast; errors stay, one per action, different actions all shown' ] },
	{ name: 'error toast auto-hides', from: "var s = addToast(text, kind, 0);", to: "var s = addToast(text, kind, 0); (function(n){ window.setTimeout(function(){ removeNode(n); }, 5000); })(s);", expect: [ 'one info toast; errors stay, one per action, different actions all shown', 'ok:true with a warning is a warning that stays, not a success' ] },
	{ name: 'no own fade timer (23.05)', from: "if (toastInfo === n) { removeNode(n); toastInfo = null; }", to: "", expect: [ 'LuCI 23.05 (no addTimeLimitedNotification): info still fades by its own timer' ] },
	{ name: 'warning shown as success (В2)', from: "if (c.reply && typeof c.reply.warning === 'string' && c.reply.warning) {", to: "if (false) {", expect: [ 'ok:true with a warning is a warning that stays, not a success' ] },
	{ name: 'restore_failed rollback ignored', from: "if (c === 'restore_failed' && ret.rolled_back === false) c = 'restore_failed_kept';", to: "", expect: [ 'restore_failed without a rollback says the old state is NOT back' ] },
	{ name: 'field codes not translated', from: "for (var f in errs) if (has(errs, f)) out[f] = fieldText(errs[f]);", to: "for (var f in errs) if (has(errs, f)) out[f] = errs[f];", expect: [ 'field errors: texts per field and marks next to the form fields' ] },
	{ name: 'waitFor gives up after one poll', from: "\t\t\t\t\tnext();\n\t\t\t\t}, function(e) {", to: "\t\t\t\t\treject(new VpnpoolError('timeout', method));\n\t\t\t\t}, function(e) {", expect: [ 'waitFor polls until the predicate holds' ] },
	{ name: 'waitIdle: grace = done (В5)', from: "return Date.now() - idleSince >= grace;", to: "if (Date.now() - idleSince >= grace) { done = true; return true; } return false;", expect: [ 'waitIdle: a job never seen running is NOT reported as done' ] },
	{ name: 'waitIdle: a seen-busy job is enough (В5)', from: "if (sawBusy) return false;                 // a mark exists but did not move yet", to: "if (sawBusy) { done = true; return true; }", expect: [ 'waitIdle(build): done only when build.at moved; an already running build does not count' ] },
	{ name: 'request over the web server limit = "no connection"', from: "if (/error -32700\\b/.test(msg)) return 'too_large';", to: "", expect: [ 'transport errors -> human codes; a session expiry is passed through without a toast' ] },
	{ name: 'session expiry toasted', from: "if (code === 'session') throw e;", to: "", expect: [ 'transport errors -> human codes; a session expiry is passed through without a toast' ] },
	{ name: 'method dropped from METHODS', from: "\trefresh:          { params: [], write: true },\n", to: "", expect: [ 'every rpcd method and every ACL method is declared in METHODS with the same arguments' ] },
	{ name: 'code text dropped', from: "\tnot_found:          _('Not found: it may have been removed already.'),\n", to: "", expect: [ 'every code the backend answers with has a human text', 'ok:false -> Error with its code and the human text, one error toast' ] },
	{ name: 'stale error never cleared', from: "\t\t\tdropSticky(method);\n\t\t\tif (c.reply", to: "\t\t\tif (c.reply", expect: [ 'a later success of the same method removes its stale error toast' ] },
	// components (R4-R6 of the review + the XSS blocker)
	{ name: 'txt() returns the bare string (Б1)', from: "return document.createTextNode(v == null ? '' : String(v));", to: "return v == null ? '' : String(v);", expect: [ 'foreign strings stay text in every component (node names with markup)' ] },
	{ name: 'card button label as a bare string (Б1)', from: "}, [ txt('') ]) : null;", to: "}, (o.primary.label)) : null;", expect: [ 'foreign strings stay text in every component (node names with markup)' ] },
	{ name: 'dialog title as a string (Б1)', from: "dlg = ui.showModal(txt(o.title || _('Are you sure?')), [", to: "dlg = ui.showModal(o.title || _('Are you sure?'), [", expect: [ 'foreign strings stay text in every component (node names with markup)' ] },
	{ name: 'toast body as a string (Б1)', from: "var body = E('p', {}, [ txt(text) ]);", to: "var body = E('p', {}, text);", expect: [ 'foreign strings stay text in every component (node names with markup)' ] },
	{ name: 'common.E passes strings on (Б1, old views)', from: "if (data != null && typeof data !== 'object' && typeof data !== 'function') data = [ txt(data) ];", to: "", expect: [ 'common.E: every call form keeps strings as text' ] },
	{ name: 'common.E two-argument form loses the text', from: "{ data = attr; attr = null; }", to: "{ attr = null; }", expect: [ 'common.E: every call form keeps strings as text' ] },
	{ name: 'card title via innerHTML (R5)', from: "if (n && n.textContent !== s) n.textContent = s;", to: "if (n) n.innerHTML = s;", expect: [ 'foreign strings stay text in every component (node names with markup)' ] },
	{ name: 'Escape does not close the menu (R4)', from: "case 'Escape': case 'Esc': ev.preventDefault(); closeMenu(true); break;", to: "", expect: [ 'menu: keyboard, Escape returns focus, one open at a time, click outside' ] },
	{ name: 'Escape in the dialog = Continue (R6)', from: "{ ev.preventDefault(); finish(false); return; }", to: "{ ev.preventDefault(); finish(true); return; }", expect: [ 'confirm: focus on Cancel, Escape = Cancel, Tab stays inside, focus comes back' ] },
	{ name: 'no focus trap in the dialog', from: "else if (i < 0 || i === f.length - 1) { ev.preventDefault(); f[0].focus(); }", to: "", expect: [ 'confirm: focus on Cancel, Escape = Cancel, Tab stays inside, focus comes back' ] },
	{ name: 'focus not returned after the dialog', from: "if (prevFocus && typeof prevFocus.focus === 'function') prevFocus.focus();", to: "", expect: [ 'confirm: focus on Cancel, Escape = Cancel, Tab stays inside, focus comes back' ] },
	{ name: 'Escape closes a foreign dialog', from: "if (!ours()) { cleanup(); resolve(false); return; }", to: "", expect: [ 'confirm replaced by another dialog: resolves false, never closes the other one' ] },
	{ name: 'whole dimmed card transparent (М1)', from: "'.vp-card.vp-dimmed .vp-card-head,.vp-card.vp-dimmed .vp-card-state,.vp-card.vp-dimmed .vp-card-badges{opacity:.6}',", to: "'.vp-card.vp-dimmed{opacity:.6}',", expect: [ 'node card: cell updates keep the elements; dimming does not touch the menu' ] },
	{ name: 'set_config argument renamed (В6)', from: "set_config:       { params: [ 'settings' ]", to: "set_config:       { params: [ 'config' ]", expect: [ 'every rpcd method and every ACL method is declared in METHODS with the same arguments' ], needsListed: 'set_config' },
	{ name: 'reason text dropped', from: "\tbad_uuid:               _('The user key in the link is not valid.'),\n", to: "", expect: [ 'every reason the backend gives for a pasted line has a human text' ] },
	{ name: 'reasonText falls back to the code itself', from: "\treturn REASON_TEXT.parse_error;\n}", to: "\treturn code;\n}", expect: [ 'every reason the backend gives for a pasted line has a human text' ] },
	{ name: 'field text dropped', from: "\tbad_ipv4:      _('Enter an address like 192.168.1.10.'),\n", to: "", expect: [ 'field errors: texts per field and marks next to the form fields' ] }
];

(async function main() {
	const src = fs.readFileSync(SRC_PATH, 'utf8');
	if (process.argv.includes('--negative')) {
		const base = await run(src, true);
		if (base.fail) { console.log('NEG: baseline not green: ' + base.failed.join('; ')); console.log('NEG: passed=0 failed=1'); process.exit(1); }
		const listed = backendList() || {};
		let p = 0, f = 0, skipped = 0;
		for (const m of MUTATIONS) {
			if (m.needsListed && !listed[m.needsListed]) { skipped++; console.log('skip - [' + m.name + '] the backend has no ' + m.needsListed + ' yet'); continue; }
			if (!src.includes(m.from)) { f++; console.log('FAIL - [' + m.name + '] mutation anchor not found in common.js'); continue; }
			const r = await run(src.replace(m.from, m.to), true);
			const missing = m.expect.filter(x => !r.failed.includes(x));
			if (missing.length) { f++; console.log('FAIL - [' + m.name + '] stayed green: ' + missing.join('; ')); }
			else { p++; console.log('ok   - [' + m.name + '] -> red: ' + r.failed.join('; ')); }
		}
		console.log('NEG: passed=' + p + ' failed=' + f + (skipped ? ' skipped=' + skipped : ''));
		process.exit(f || !p ? 1 : 0);
	}
	const r = await run(src, false);
	console.log('UNIT: passed=' + r.pass + ' failed=' + r.fail);
	process.exit(r.fail || !r.pass ? 1 : 0);
})();
