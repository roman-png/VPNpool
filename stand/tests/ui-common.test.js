#!/usr/bin/env node
// Unit tests of resources/vpnpool/common.js outside the browser: the LuCI globals it uses
// (baseclass, rpc, ui, dom, E, _) are replaced by small fakes, timers by a fake clock.
// DOM components (menu keyboard, confirm dialog, card layout) are checked in a real browser
// on the stand (see stand/tests/ui-components.sh); here: reply/error handling, the code
// table, the one-toast rule, waitFor/waitIdle, and drift against the rpcd method list.
//   node stand/tests/ui-common.test.js             -> "UNIT: passed=N failed=M", exit 1 on failure
//   node stand/tests/ui-common.test.js --negative  -> break common.js in memory, one mutation at
//                                                     a time; each must turn its tests red
//                                                     ("NEG: passed=N failed=M")
'use strict';
const fs = require('fs');
const path = require('path');

const REPO = process.env.REPO_DIR || path.resolve(__dirname, '../..');
const APP = path.join(REPO, 'package/luci-app-vpnpool');
const SRC_PATH = path.join(APP, 'files/www/luci-static/resources/vpnpool/common.js');
const RPCD = path.join(APP, 'files/usr/libexec/rpcd/vpnpool');
const ACL = path.join(APP, 'files/usr/share/rpcd/acl.d/luci-app-vpnpool.json');

// ---------- fakes ----------
function makeEnv(opts) {
	opts = opts || {};
	const clock = { now: 1000000, timers: [], seq: 0 };
	const setTimeout_ = (fn, ms) => { const id = ++clock.seq; clock.timers.push({ id, at: clock.now + (ms || 0), fn }); return id; };
	const clearTimeout_ = id => { clock.timers = clock.timers.filter(t => t.id !== id); };
	async function tick(ms) {
		const end = clock.now + ms;
		for (;;) {
			await flush();
			clock.timers.sort((a, b) => a.at - b.at);
			const t = clock.timers[0];
			if (!t || t.at > end) break;
			clock.timers.shift();
			clock.now = t.at;
			t.fn();
		}
		clock.now = end;
		await flush();
	}
	async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
	const FakeDate = { now: () => clock.now };

	const mc = { children: [], removeChild(n) { this.children = this.children.filter(x => x !== n); n.parentNode = null; } };
	function node(tag, attrs, children) {
		const n = { tag, attrs: attrs || {}, children: [].concat(children == null ? [] : children), parentNode: null,
			classes: new Set(), attr: {},
			setAttribute(k, v) { this.attr[k] = v; } };
		n.classList = { add: (...c) => c.forEach(x => n.classes.add(x)), contains: c => n.classes.has(c), remove: c => n.classes.delete(c), toggle: (c, v) => v ? n.classes.add(c) : n.classes.delete(c) };
		if (attrs && attrs['class']) String(attrs['class']).split(/\s+/).forEach(c => c && n.classes.add(c));
		return n;
	}
	const E = (tag, attrs, children) => node(tag, attrs, children);
	function textOf(n) { if (n == null) return ''; if (typeof n === 'string') return n; return (n.children || []).map(textOf).join(''); }
	const ui = {
		calls: [],
		addNotification(title, children, ...cls) { const n = node('div', { 'class': 'alert-message' }, children); cls.forEach(c => n.classes.add(c)); n.parentNode = mc; mc.children.unshift(n); ui.calls.push(['add', cls.join(' ')]); return n; },
		addTimeLimitedNotification(title, children, timeout, ...cls) { const n = ui.addNotification(title, children, ...cls); ui.calls.push(['timed', timeout]); setTimeout_(() => { if (n.parentNode) n.parentNode.removeChild(n); }, timeout); return n; },
		createHandlerFn: (ctx, fn) => fn,
		showModal() {}, hideModal() {}
	};
	if (opts.lucI2305) delete ui.addTimeLimitedNotification;
	const handlers = {};
	const rpcLog = [];
	const rpc = {
		declare(o) {
			return function(...args) {
				const p = {};
				(o.params || []).forEach((k, i) => { p[k] = args[i]; });
				rpcLog.push([o.method, p]);
				const h = handlers[o.method];
				return new Promise((resolve, reject) => {
					try {
						if (!h) return resolve(3);   // rpcd: method not found -> [3]
						const r = h(p, rpcLog.filter(x => x[0] === o.method).length);
						if (r instanceof Error) reject(r); else resolve(r);
					} catch (e) { reject(e); }
				});
			};
		}
	};
	const dom = { content(n, c) { n.children = [].concat(c); } };
	const baseclass = { extend(proto) { function C() { if (proto.__init__) proto.__init__.apply(this, arguments); } C.prototype = proto; return C; } };
	const consoleQuiet = { warn() {}, info() {}, log() {} };
	const win = { setTimeout: setTimeout_, clearTimeout: clearTimeout_ };
	return { clock, tick, flush, FakeDate, mc, E, ui, rpc, dom, baseclass, handlers, rpcLog, textOf, win, consoleQuiet };
}

function load(src, env) {
	const fn = new Function('baseclass', 'rpc', 'ui', 'dom', 'E', '_', 'window', 'console', 'Date', 'document', src);
	const C = fn(env.baseclass, env.rpc, env.ui, env.dom, env.E, s => s, env.win, env.consoleQuiet, env.FakeDate, undefined);
	return new C();
}

// ---------- tests ----------
const T = [];
function test(name, fn, opts) { T.push({ name, fn, opts: opts || {} }); }
function eq(a, b, what) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((what || 'value') + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b)); }
function ok(c, what) { if (!c) throw new Error(what || 'assertion failed'); }
async function rejectsWith(p) { try { await p; } catch (e) { return e; } throw new Error('expected a rejection, got a resolve'); }
const toasts = (env, kind) => env.mc.children.filter(n => n.classes.has('vp-toast') && (!kind || n.classes.has(kind)));

test('ok reply resolves with the object', async (C, env) => {
	env.handlers.status = () => ({ nodes: [1, 2] });
	const r = await C.call('status');
	eq(r.nodes.length, 2, 'nodes');
	eq(toasts(env).length, 0, 'toasts on a plain success');
});
test('ok:false -> Error with its code and the human text, one error toast', async (C, env) => {
	env.handlers.select = () => ({ ok: false, code: 'not_found', daemon: 'n/a' });
	const e = await rejectsWith(C.call('select', { tag: 'x' }));
	ok(e instanceof C.Error, 'instance of common.Error');
	eq(e.code, 'not_found', 'code');
	eq(e.text, C.CODE_TEXT.not_found, 'text');
	eq(toasts(env, 'danger').length, 1, 'error toasts');
	eq(env.textOf(toasts(env, 'danger')[0]), C.CODE_TEXT.not_found, 'toast text');
});
test('args are forwarded by name', async (C, env) => {
	env.handlers.set_option = () => ({ ok: true, code: 'saved' });
	await C.call('set_option', { name: 'a', value: 'b' });
	eq(env.rpcLog[env.rpcLog.length - 1], [ 'set_option', { name: 'a', value: 'b' } ], 'rpc params');
	env.handlers.analyze = () => ({ ok: true });
	await C.call('analyze', { text: 'vless://x', extra: 1 });
	eq(env.rpcLog[env.rpcLog.length - 1], [ 'analyze', { text: 'vless://x', extra: 1 } ], 'unknown arg kept');
});
test('legacy {error:"…"} replies map to codes', async (C, env) => {
	env.handlers.node_link = () => ({ error: 'no link for tag' });
	eq((await rejectsWith(C.call('node_link', { tag: 'x' }, { quiet: true }))).code, 'not_found', 'no link for tag');
	env.handlers.import = () => ({ error: 'empty config' });
	eq((await rejectsWith(C.call('import', { config: '' }, { quiet: true }))).code, 'empty', 'empty config');
	env.handlers.add_node = () => ({ error: 'something new' });
	const e = await rejectsWith(C.call('add_node', { link: 'x' }, { quiet: true }));
	eq(e.code, 'failed', 'unknown legacy error');
	eq(e.text, C.CODE_TEXT.failed, 'fallback text');
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
test('quiet: no toast; success text + "service is off" note', async (C, env) => {
	env.handlers.set_domains = () => ({ ok: false, code: 'bad_value' });
	await rejectsWith(C.call('set_domains', { domains: [] }, { quiet: true }));
	eq(toasts(env).length, 0, 'quiet error');
	env.handlers.set_domains = () => ({ ok: true, code: 'saved', daemon: 'not_running' });
	await C.call('set_domains', { domains: [] }, { success: 'Domains saved.' });
	const t = toasts(env, 'info');
	eq(t.length, 1, 'info toasts');
	ok(/^Domains saved\. The service is off/.test(env.textOf(t[0])), 'note about the stopped service: ' + env.textOf(t[0]));
	env.handlers.set_domains = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	await C.call('set_domains', { domains: [] }, { success: r => 'Saved ' + r.code });
	eq(env.textOf(toasts(env, 'info')[0]), 'Saved saved', 'function success text, no note');
});
test('one toast: infos replace each other and fade; errors stay, one at a time', async (C, env) => {
	C.toast('A'); C.toast('B'); C.toast('C');
	eq(toasts(env, 'info').length, 1, 'infos after 3 toasts');
	eq(env.textOf(toasts(env, 'info')[0]), 'C', 'the last info stays');
	C.toast('E1', 'error'); C.toast('E2', 'error');
	eq(toasts(env, 'danger').length, 1, 'errors after 2 error toasts');
	eq(env.textOf(toasts(env, 'danger')[0]), 'E2', 'the last error');
	C.toast('D');
	eq(toasts(env, 'danger').length, 1, 'an info does not remove the error');
	await env.tick(C.INFO_MS + 700);
	eq(toasts(env, 'info').length, 0, 'info faded');
	eq(toasts(env, 'danger').length, 1, 'error still there after the info timeout');
	await env.tick(60000);
	eq(toasts(env, 'danger').length, 1, 'error still there after a minute');
	C.clearToast();
	eq(toasts(env).length, 0, 'clearToast');
});
test('a later success of the same method removes its stale error toast', async (C, env) => {
	env.handlers.ping = (p, n) => n === 1 ? { ok: false, code: 'busy' } : { ok: true, code: 'started' };
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
}, { lucI2305: true });
test('waitFor polls until the predicate holds', async (C, env) => {
	env.handlers.status = (p, n) => ({ busy: { fetch: n < 3 } });
	const pr = C.waitFor(st => !st.busy.fetch, { interval: 1000, timeout: 10000 });
	let done = null; pr.then(r => { done = r; });
	await env.tick(5000);
	ok(done, 'resolved');
	eq(env.rpcLog.filter(x => x[0] === 'status').length, 3, 'status polls');
});
test('waitFor times out with code timeout; access errors stop at once', async (C, env) => {
	env.handlers.status = () => ({ busy: { fetch: true } });
	const pr = C.waitFor(st => false, { interval: 1000, timeout: 3000 });
	let err = null; pr.catch(e => { err = e; });
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
test('waitIdle: done only after the job was seen busy or its stamp moved', async (C, env) => {
	// job not started yet on the first poll, then busy, then idle
	const seq = [ { busy: {} }, { busy: { build: true } }, { busy: { build: false } } ];
	env.handlers.status = (p, n) => seq[Math.min(n - 1, seq.length - 1)];
	let r = null; C.waitIdle('build', { interval: 1000, timeout: 20000, grace: 100000 }).then(x => { r = x; });
	await env.tick(1500);
	ok(!r, 'not done on the first idle poll (job not started yet)');
	await env.tick(3000);
	ok(r, 'done after busy -> idle');
	// stamp: idle all the time, stamp moves on the 3rd poll
	const st2 = [ 100, 100, 150 ];
	env.rpcLog.length = 0;
	env.handlers.status = (p, n) => ({ busy: {}, build: { time: st2[Math.min(n - 1, 2)] } });
	let r2 = null; C.waitIdle('build', { since: 100, stamp: s => s.build.time, interval: 1000, timeout: 20000 }).then(x => { r2 = x; });
	await env.tick(1500);
	ok(!r2, 'stamp unchanged -> not done');
	await env.tick(2000);
	ok(r2 && r2.build.time === 150, 'stamp moved -> done');
	ok(C.isBusy({ busy: { ping: 1 } }) && !C.isBusy({ busy: { ping: 0 } }) && !C.isBusy({}) && C.isBusy({ busy: { a: 0, b: true } }, 'b'), 'isBusy');
});
test('every rpcd method and every ACL method is declared in METHODS', async (C) => {
	const src = fs.readFileSync(RPCD, 'utf8');
	const m = src.match(/^list\)\n\tcat <<'L'\n([\s\S]*?)\nL$/m);
	ok(m, 'rpcd list block found');
	const listed = Object.keys(JSON.parse(m[1]));
	const acl = JSON.parse(fs.readFileSync(ACL, 'utf8'))['luci-app-vpnpool'];
	const aclm = [].concat(acl.read.ubus.vpnpool, acl.write.ubus.vpnpool);
	ok(listed.length >= 40 && aclm.length >= 40, 'positive control: methods found rpcd=' + listed.length + ' acl=' + aclm.length);
	const miss = [...new Set(listed.concat(aclm))].filter(x => !C.METHODS[x]);
	eq(miss, [], 'methods missing in common.js METHODS');
	const rd = new Set(acl.read.ubus.vpnpool);
	const wrongRw = Object.keys(C.METHODS).filter(k => (rd.has(k) && C.METHODS[k].write) || (aclm.includes(k) && !rd.has(k) && !C.METHODS[k].write));
	eq(wrongRw, [], 'read/write class differs from the ACL');
});
test('every code the backend answers with has a human text', async (C) => {
	const src = fs.readFileSync(RPCD, 'utf8');
	const codes = [...new Set([...src.matchAll(/\breply (?:true|false) ([a-z_]+)/g)].map(x => x[1]))];
	const legacy = [...new Set([...src.matchAll(/"error":"([^"]+)"/g)].map(x => x[1]))];
	ok(codes.length >= 10 && legacy.length >= 5, 'positive control: codes=' + codes.length + ' legacy=' + legacy.length);
	eq(codes.filter(c => C.codeText(c) == null), [], 'codes without a text');
	const L = new Function('return ' + fs.readFileSync(SRC_PATH, 'utf8').match(/var LEGACY_ERROR = (\{[\s\S]*?\});/)[1])();
	eq(legacy.filter(x => !L[x]), [], 'legacy error strings without a code');
	eq(Object.values(L).filter(c => C.codeText(c) == null), [], 'legacy codes without a text');
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
	{ name: 'ok:false treated as success', from: "if (ret.ok === false)", to: "if (false && ret.ok === false)", expect: [ 'ok:false -> Error with its code and the human text, one error toast' ] },
	{ name: 'legacy error ignored', from: "if (typeof ret.error === 'string' || (ret.error != null && ret.ok !== true))", to: "if (false)", expect: [ 'legacy {error:\"…\"} replies map to codes' ] },
	{ name: 'array reply accepted', from: "if (ret == null || typeof ret !== 'object' || Array.isArray(ret))", to: "if (ret == null || typeof ret !== 'object')", expect: [ 'non-object replies are bad_reply, never success' ] },
	{ name: 'info toast not replaced', from: "\t\tremoveNode(toastInfo);\n\t\tvar ms", to: "\t\tvar ms", expect: [ 'one toast: infos replace each other and fade; errors stay, one at a time' ] },
	{ name: 'error toast piles up', from: "\t\t\tremoveNode(toastError);\n\t\t\ttoastErrorMethod = null;", to: "\t\t\ttoastErrorMethod = null;", expect: [ 'one toast: infos replace each other and fade; errors stay, one at a time' ] },
	{ name: 'error toast auto-hides', from: "toastError = addToast(text, 'error', 0);", to: "toastError = addToast(text, 'error', 0); (function(n){ window.setTimeout(function(){ removeNode(n); }, 5000); })(toastError);", expect: [ 'one toast: infos replace each other and fade; errors stay, one at a time' ] },
	{ name: 'no own fade timer (23.05)', from: "if (toastInfo === n) { removeNode(n); toastInfo = null; }", to: "", expect: [ 'LuCI 23.05 (no addTimeLimitedNotification): info still fades by its own timer' ] },
	{ name: 'waitFor gives up after one poll', from: "\t\t\t\t\tnext();\n\t\t\t\t}, function(e) {", to: "\t\t\t\t\treject(new VpnpoolError('timeout', method));\n\t\t\t\t}, function(e) {", expect: [ 'waitFor polls until the predicate holds' ] },
	{ name: 'waitIdle accepts the first idle poll', from: "if (sawBusy) return true;", to: "return true;", expect: [ 'waitIdle: done only after the job was seen busy or its stamp moved' ] },
	{ name: 'session expiry toasted', from: "if (code === 'session') throw e;", to: "", expect: [ 'transport errors -> human codes; a session expiry is passed through without a toast' ] },
	{ name: 'method dropped from METHODS', from: "\ttg_test:          { params: [], write: true },\n", to: "", expect: [ 'every rpcd method and every ACL method is declared in METHODS' ] },
	{ name: 'code text dropped', from: "\tsched_failed:       _('The schedule could not be saved.'),\n", to: "", expect: [ 'every code the backend answers with has a human text' ] },
	{ name: 'stale error never cleared', from: "if (toastError && toastErrorMethod === method) self.clearToast('error');", to: "", expect: [ 'a later success of the same method removes its stale error toast' ] }
];

(async function main() {
	const src = fs.readFileSync(SRC_PATH, 'utf8');
	if (process.argv.includes('--negative')) {
		const base = await run(src, true);
		if (base.fail) { console.log('NEG: baseline not green: ' + base.failed.join('; ')); console.log('NEG: passed=0 failed=1'); process.exit(1); }
		let p = 0, f = 0;
		for (const m of MUTATIONS) {
			if (!src.includes(m.from)) { f++; console.log('FAIL - [' + m.name + '] mutation anchor not found in common.js'); continue; }
			const r = await run(src.replace(m.from, m.to), true);
			const missing = m.expect.filter(x => !r.failed.includes(x));
			if (missing.length) { f++; console.log('FAIL - [' + m.name + '] stayed green: ' + missing.join('; ')); }
			else { p++; console.log('ok   - [' + m.name + '] -> red: ' + r.failed.join('; ')); }
		}
		console.log('NEG: passed=' + p + ' failed=' + f);
		process.exit(f || !p ? 1 : 0);
	}
	const r = await run(src, false);
	console.log('UNIT: passed=' + r.pass + ' failed=' + r.fail);
	process.exit(r.fail || !r.pass ? 1 : 0);
})();
