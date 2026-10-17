#!/usr/bin/env node
// Behaviour tests of the "Diagnostics" tab (resources/view/vpnpool/diagnostics.js) outside the
// browser: the real view and the real common.js on the fakes of ui-fake.js (LuCI globals + a DOM
// that records every innerHTML write). The backend is a table of fake rpcd replies (diag, logs,
// conntest); every call is logged with its arguments.
//   node stand/tests/ui-diag.test.js            -> "DIAG: passed=N failed=M checked=K", exit 1 on failure
//   node stand/tests/ui-diag.test.js --negative -> break diagnostics.js in memory, one mutation at
//                                                  a time; each must turn its tests red
//                                                  ("DIAG-NEG: passed=N failed=M")
// What is judged: the checks and "Check the exit through the VPN"; the log (more than 40 lines,
// the filter, the count, "Download" of what is shown, the source and the number of lines; polled,
// diag never on a timer); the engine (version, AmneziaWG yes/no, how to install / update in each
// case); EVERY technical parameter diag.sh gives is shown here (with its option name), including
// the ones the Settings page used to show; foreign values are text; only diag/logs/conntest.
'use strict';
const fs = require('fs');
const path = require('path');
const { makeEnv, load } = require('./ui-fake.js');

const REPO = process.env.REPO_DIR || path.resolve(__dirname, '../..');
const RES = path.join(REPO, 'package/luci-app-vpnpool/files/www/luci-static/resources');
const VIEW_PATH = path.join(RES, 'view/vpnpool/diagnostics.js');
const COMMON_PATH = path.join(RES, 'vpnpool/common.js');
const DIAG_SH = path.join(REPO, 'package/vpnpool/files/usr/libexec/vpnpool/diag.sh');
const ENGINE_SH = path.join(REPO, 'package/vpnpool/files/usr/libexec/vpnpool/engine.sh');
const XSS = '<img src=x onerror="window.pwned=1">';

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', { value: function(...a) {
		let i = 0;
		return this.replace(/%([sd%])/g, (m, t) => t === '%' ? '%' : (t === 'd' ? String(parseInt(a[i++], 10)) : String(a[i++])));
	} });
}

// the keys of the "params" object diag.sh builds (its jq object), read from the script
function paramKeys() {
	const s = fs.readFileSync(DIAG_SH, 'utf8');
	const a = s.indexOf('PARAMS=$(jq'), b = s.indexOf("[ -n \"$PARAMS\" ]");
	if (a < 0 || b < a) throw new Error('diag.sh: the PARAMS block is not found');
	const blk = s.slice(a, b), o = blk.indexOf('{tproxy_port');
	if (o < 0) throw new Error('diag.sh: the params object is not found');
	return [ ...blk.slice(o).matchAll(/([a-z_]+): /g) ].map(m => m[1]);
}
const PINNED = (fs.readFileSync(ENGINE_SH, 'utf8').match(/^ENGINE_PINNED="([^"]+)"/m) || [])[1];

function diagFixture(over) {
	const d = {
		ok: true, code: 'ok', daemon: 'n/a',
		service: { enabled: true, running: true, routing: false, autostart: true, singbox_pid: '4321', clash_api_ok: true },
		coexist: { podkop_running: true, podkop_table: true, zapret_table: false },
		network: { wan_iface: 'wan', gateway: '10.0.0.1', internet: true, direct_ip: '198.51.100.7', direct_country: 'RU' },
		rulesets: { communities: 2, cache_present: true, cache_kb: 300 },
		resources: { fwmark: '0x400000', route_table: '142', tproxy_port: '1603', clash_api: '127.0.0.1:9091', singbox_version: '1.12.25' },
		params: { tproxy_port: '1603', test_port: '1605', node_test_port: '1606', fwmark: '0x400000', route_table: '142', route_priority: '106',
			clash_api: '127.0.0.1:9091', lan_if: 'br-lan', lan_if_auto: true, coexist: 'auto', dns_strategy: 'prefer_ipv4',
			health_url: 'http://cp.example/' + XSS, fetch_max_kb: '2048', speedtest_min_mem_kb: '8192', prefilter_concurrency: '16',
			adaptive_max_per_run: '8', singbox_bin: '', log_level: 'warn', probe_ua: '' },
		engine: { bin: '/usr/bin/sing-box', version: '1.12.25', present: true, awg: false, awg31: false,
			awg_engine: { path: '/usr/bin/sing-box-awg', installed: false, version: null, awg: false, awg31: false, ram: null, installed_at: null },
			target_version: PINNED, update_available: false },
		logs: []
	};
	if (over) over(d);
	return d;
}
function logFixture(n, src) {
	const lines = [];
	for (let i = 1; i <= n; i++) lines.push('Fri Oct 17 10:' + String(i % 60).padStart(2, '0') + ' 2026 ' + (i % 70 === 0 ? 'error: node ' + i + ' failed' : 'line ' + i));
	return { ok: true, code: 'ok', daemon: 'n/a', source: src || 'service', lines };
}

// ---------- harness ----------
let CHECKS = 0;
function eq(a, b, what) { CHECKS++; if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((what || 'value') + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b)); }
function ok(c, what) { CHECKS++; if (!c) throw new Error(what || 'assertion failed'); }

function setup(viewSrc, commonSrc) {
	const env = makeEnv();
	const common = load(commonSrc, env);
	const downloads = [];
	common.download = (name, b64, mime) => { downloads.push({ name, text: Buffer.from(b64, 'base64').toString('utf8'), mime }); };
	const view = { extend(proto) { function V() {} V.prototype = proto; return V; } };
	const fn = new Function('view', 'ui', 'poll', 'dom', 'common', 'E', '_', 'L', 'window', 'document', 'console', 'Date', viewSrc);
	const V = fn(view, env.ui, env.poll, env.dom, common, env.D.E, s => s, env.L, env.win, env.doc, env.consoleQuiet, env.DateC);
	const v = new V();
	const calls = m => env.rpcLog.filter(x => x[0] === m).map(x => x[1]);
	return { env, common, v, calls, viewSrc, downloads };
}
async function open(t, d, logs) {
	t.env.handlers.diag = () => d;
	t.env.handlers.logs = (p) => (logs ? logs(p) : logFixture(10, p.source));
	const r = await t.v.load();
	const root = t.v.render(r);
	t.env.mc.appendChild(root);
	await t.env.flush();
	return root;
}
const settle = t => t.env.tick(50);
const click = (t, el) => t.env.D.fire(el, 'click', {});
const button = (root, label) => root.querySelectorAll('button').find(b => b.textContent === label);
const toasts = (t, kind) => t.env.mc.children.filter(n => n.classes && n.classes.has('vp-toast') && (!kind || n.classes.has(kind))).map(n => n.textContent);
// "label -> value" of every row of a section box
function rowsOf(box) {
	const out = {};
	const labels = box.querySelectorAll('.vp-diag-label');
	labels.forEach(l => {
		const name = l.querySelector('.vp-diag-name');
		const key = l.children.filter(c => c !== name).map(c => c.textContent).join('');
		const val = l.parentNode.children[l.parentNode.children.indexOf(l) + 1];
		out[key] = { value: val.textContent, name: name ? name.textContent : null, badge: (val.querySelector('.vp-badge') || { classes: new Set() }) };
	});
	return out;
}
const kindOf = r => [ ...r.badge.classes ].find(c => /^vp-badge-/.test(c)) || null;

const T = [];
function test(name, fn) { T.push({ name, fn }); }

// ---------- tests ----------
test('checks, the engine and every technical parameter from diag; foreign values are text', async (t) => {
	const root = await open(t, diagFixture());
	const C = rowsOf(root.querySelector('.vp-diag-checks'));
	ok(Object.keys(C).length >= 8, 'positive control: check rows ' + Object.keys(C).length);
	eq([ C['The service is running'].value, kindOf(C['The service is running']) ], [ 'yes', 'vp-badge-ok' ], 'running');
	eq([ C['Traffic goes through the VPN'].value, kindOf(C['Traffic goes through the VPN']) ], [ 'no', 'vp-badge-error' ], 'no routing: a problem');
	eq(C['Exit without the VPN'].value, 'RU, 198.51.100.7', 'the direct exit');
	eq(C['podkop on this router'].value, 'found', 'podkop found');
	const P = rowsOf(root.querySelector('.vp-diag-params'));
	const keys = paramKeys();
	ok(keys.length >= 15, 'positive control: parameters of diag.sh ' + keys.length);
	const names = Object.values(P).map(r => r.name).filter(Boolean).join(' / ').split(' / ');
	// on the Settings pages (not technical, no second place): log detail, nodes checked at once;
	// lan_if_auto is said next to lan_if
	const elsewhere = [ 'log_level', 'prefilter_concurrency', 'lan_if_auto' ];
	eq(keys.filter(k => !elsewhere.includes(k) && !names.includes(k)), [], 'parameters of diag.sh not on the page');
	// what the Settings page showed before 2.0 ("Technical (read-only)"): only here now
	for (const k of [ 'tproxy_port', 'fwmark', 'route_table', 'clash_api' ]) ok(names.includes(k), 'moved from Settings: ' + k);
	const byName = {};
	Object.values(P).forEach(r => { if (r.name) byName[r.name] = r.value; });
	eq(byName.fwmark, '0x400000', 'mark value');
	eq(byName['route_table / route_priority'], '142 / 106', 'table and priority');
	eq(byName.lan_if, 'br-lan (found automatically)', 'LAN interface');
	eq(byName.health_url, 'http://cp.example/' + XSS, 'foreign value shown as is (text)');
	eq(byName.singbox_bin, 'chosen automatically', 'empty engine program: said in words');
	const E = rowsOf(root.querySelector('.vp-diag-engine'));
	eq([ E.Version.value, E.Version.name ], [ '1.12.25', '/usr/bin/sing-box' ], 'engine version and program');
	eq([ E.AmneziaWG.value, kindOf(E.AmneziaWG) ], [ 'not supported', 'vp-badge-warn' ], 'AmneziaWG: no');
	eq(t.calls('diag').length, 1, 'diag read once');
	eq(t.env.doc.unsafe, [], 'innerHTML writes');
});

test('engine: AmneziaWG yes/no and how to install or update, in every case', async (t) => {
	ok(PINNED, 'positive control: the pinned engine version read from engine.sh');
	const how = root => root.querySelector('.vp-diag-engine').textContent;
	const cmd = root => root.querySelectorAll('.vp-diag-cmd').map(c => c.textContent);
	let root = await open(t, diagFixture());
	ok(how(root).includes('install the engine with AmneziaWG'), 'not installed: says to install: ' + how(root));
	eq(cmd(root), [ 'VPNPOOL_AWG=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)' ], 'the install command');
	ok(how(root).includes('System → Software'), 'the standard engine: where it is updated');
	const t2 = setup(t.viewSrc, COMMON_SRC);
	root = await open(t2, diagFixture(d => { Object.assign(d.engine.awg_engine, { installed: true, version: '1.14.3-awg.0', awg: true, awg31: true, ram: true });
		d.engine.update_available = true; d.engine.bin = '/usr/bin/sing-box-awg'; d.engine.awg = true; d.engine.awg31 = true; }));
	const E = rowsOf(root.querySelector('.vp-diag-engine'));
	eq(E.AmneziaWG.value, 'supported, including 3.1', 'AmneziaWG 3.1: yes');
	ok(E['Engine with AmneziaWG'].value.includes('1.14.3-awg.0') && E['Engine with AmneziaWG'].value.includes('in memory'), 'installed version, kept in memory: ' + E['Engine with AmneziaWG'].value);
	ok(how(root).includes('A newer version') && how(root).includes(PINNED), 'an update is due: says the new version: ' + how(root));
	eq(cmd(root), [ '/usr/libexec/vpnpool/engine.sh update' ], 'the update command');
	const t3 = setup(t.viewSrc, COMMON_SRC);
	root = await open(t3, diagFixture(d => { Object.assign(d.engine.awg_engine, { installed: true, version: PINNED, awg: true, awg31: true, ram: false }); }));
	ok(how(root).includes('up to date') && !how(root).includes('A newer version'), 'current: up to date: ' + how(root));
	const t4 = setup(t.viewSrc, COMMON_SRC);
	root = await open(t4, diagFixture(d => { d.engine.awg = true; d.engine.awg31 = false; }));
	eq(rowsOf(root.querySelector('.vp-diag-engine')).AmneziaWG.value, 'supported (without 3.1)', 'AmneziaWG without 3.1');
});

test('log: more than 40 lines, filter and count, download of what is shown, source and size, polled', async (t) => {
	const root = await open(t, diagFixture(), p => logFixture(p.lines || 200, p.source));
	eq(t.calls('logs')[0], { lines: 200, source: 'service' }, 'first read: 200 lines of the service');
	const pre = root.querySelector('.vp-log'), info = root.querySelector('.vp-log-count');
	eq(pre.textContent.split('\n').length, 200, 'more than 40 lines shown');
	eq(info.textContent, 'Lines: 200', 'count');
	const filter = root.querySelector('input');
	filter.value = 'ERROR';
	t.env.D.fire(filter, 'input', {});
	eq(pre.textContent.split('\n'), [ 'Fri Oct 17 10:10 2026 error: node 70 failed', 'Fri Oct 17 10:20 2026 error: node 140 failed' ], 'the filter (any case)');
	eq(info.textContent, 'Lines: 2 of 200', 'count with the filter');
	click(t, button(root, 'Download')); await settle(t);
	eq(t.downloads.length, 1, 'one file');
	ok(/^vpnpool-log-[0-9]{8}-[0-9]{4}\.txt$/.test(t.downloads[0].name), 'file name: ' + t.downloads[0].name);
	eq(t.downloads[0].text, 'Fri Oct 17 10:10 2026 error: node 70 failed\nFri Oct 17 10:20 2026 error: node 140 failed\n', 'the file holds what is shown');
	eq(t.downloads[0].mime, 'text/plain', 'a text file');
	filter.value = 'no such text'; t.env.D.fire(filter, 'input', {});
	eq(pre.textContent, 'No line has this text.', 'nothing matches: said');
	filter.value = ''; t.env.D.fire(filter, 'input', {});
	const [ src, cnt ] = root.querySelectorAll('select');
	ok(cnt.querySelectorAll('option').some(o => o.getAttribute('value') === '500'), 'up to 500 lines offered');
	cnt.value = '500'; t.env.D.fire(cnt, 'change', {}); await settle(t);
	eq(t.calls('logs').slice(-1)[0], { lines: 500, source: 'service' }, '500 lines asked');
	eq(pre.textContent.split('\n').length, 500, '500 shown');
	src.value = 'engine'; t.env.D.fire(src, 'change', {}); await settle(t);
	eq(t.calls('logs').slice(-1)[0], { lines: 500, source: 'engine' }, 'the engine log asked');
	const n0 = t.calls('logs').length;
	ok(t.env.pollFns.length === 1, 'positive control: one poll function');
	await t.env.pollFns[0](); await settle(t);
	eq(t.calls('logs').length, n0 + 1, 'the poll reads the log');
	eq(t.calls('diag').length, 1, 'diag is not polled (a ping and a request outside each time)');
	t.env.handlers.logs = () => ({ ok: false, code: 'script_failed', daemon: 'n/a', error: 'script_failed' });
	await t.env.pollFns[0](); await settle(t);
	eq(info.textContent, t.common.CODE_TEXT.script_failed, 'a failed read is said');
	eq(t.env.doc.unsafe, [], 'innerHTML writes');
});

test('an empty log is said and not downloaded', async (t) => {
	const root = await open(t, diagFixture(), () => ({ ok: true, code: 'ok', daemon: 'n/a', source: 'service', lines: [] }));
	eq(root.querySelector('.vp-log').textContent, 'The log is empty.', 'empty log said');
	click(t, button(root, 'Download')); await settle(t);
	eq(t.downloads.length, 0, 'no file');
	ok(toasts(t, 'warning').includes('The log is empty.'), 'said why');
});

test('"Check the exit through the VPN": country and address; a failure says why', async (t) => {
	const root = await open(t, diagFixture());
	t.env.handlers.conntest = () => ({ ok: true, code: 'ok', daemon: 'n/a', ip: '203.0.113.5', country: XSS });
	click(t, button(root, 'Check the exit through the VPN')); await settle(t);
	eq(t.calls('conntest').length, 1, 'one test');
	const out = root.querySelector('.vp-diag-result');
	eq(out.textContent, 'Exit through the VPN: ' + XSS + ', address 203.0.113.5.', 'the result on the page');
	ok(toasts(t, 'info').includes(out.textContent), 'and as a toast');
	t.env.handlers.conntest = () => ({ ok: false, code: 'exit_unreachable', daemon: 'n/a', error: 'exit_unreachable', ip: '', country: '' });
	click(t, button(root, 'Check the exit through the VPN')); await settle(t);
	eq(out.textContent, t.common.CODE_TEXT.exit_unreachable, 'the failure: why');
	ok(!button(root, 'Check the exit through the VPN').disabled, 'the button is free again');
	eq(t.env.doc.unsafe, [], 'innerHTML writes');
});

test('"Check again" reads diag again and redraws; an unreadable diag is said', async (t) => {
	const root = await open(t, diagFixture());
	t.env.handlers.diag = () => diagFixture(d => { d.service.routing = true; });
	click(t, button(root, 'Check again')); await settle(t);
	eq(t.calls('diag').length, 2, 'diag read again');
	eq(rowsOf(root.querySelector('.vp-diag-checks'))['Traffic goes through the VPN'].value, 'yes', 'redrawn with the new answer');
	ok(toasts(t, 'info').includes('Checked again.'), 'said');
	const t2 = setup(t.viewSrc, COMMON_SRC);
	t2.env.handlers.diag = () => ({ ok: false, code: 'script_failed', daemon: 'n/a', error: 'script_failed' });
	t2.env.handlers.logs = () => logFixture(3);
	const r2 = t2.v.render(await t2.v.load()); t2.env.mc.appendChild(r2);
	ok(r2.querySelector('.vp-diag-checks').textContent.includes('did not give the diagnostics'), 'the page says diag is missing');
	ok(toasts(t2, 'danger').includes(t2.common.CODE_TEXT.script_failed), 'the error toast');
	eq(r2.querySelector('.vp-log').textContent.split('\n').length, 3, 'the log still works');
});

test('only diag, logs and conntest; no own rpc, no old dictionary module', async (t) => {
	const src = t.viewSrc;
	const used = new Set([ ...src.matchAll(/common\.call\('([a-z_]+)'/g) ].map(m => m[1]));
	eq([ ...used ].sort(), [ 'conntest', 'diag', 'logs' ], 'methods used');
	eq([ ...used ].filter(m => !t.common.METHODS[m]), [], 'methods unknown to common.js');
	ok(!/rpc\.declare|'require rpc'/.test(src), 'no own rpc declarations');
	ok(!/vpnpool\.i18n/.test(src), 'no old dictionary module (LuCI po only)');
});

// ---------- runner ----------
let COMMON_SRC = '';
async function run(viewSrc, commonSrc, quiet) {
	let pass = 0, fail = 0;
	const failed = [];
	for (const x of T) {
		const t = setup(viewSrc, commonSrc);
		try {
			let tm;
			await Promise.race([ x.fn(t), new Promise((_, rej) => { tm = setTimeout(() => rej(new Error('test did not finish (hangs)')), 15000); }) ])
				.finally(() => clearTimeout(tm));
			pass++;
			if (!quiet) console.log('ok   - ' + x.name);
		} catch (e) {
			fail++; failed.push(x.name);
			if (!quiet) console.log('FAIL - ' + x.name + ': ' + (e && e.message));
		}
	}
	return { pass, fail, failed };
}

const MUTATIONS = [
	{ name: 'a parameter row dropped', from: "row(_('Mark of the routed traffic'), p.fwmark, 'fwmark'),", to: '', expect: [ 'checks, the engine and every technical parameter from diag; foreign values are text' ] },
	{ name: 'the log cut to 40 lines', from: 'var LOG_LINES = [ 50, 200, 500 ];\nvar LOG_DEFAULT = 200;', to: 'var LOG_LINES = [ 20, 40 ];\nvar LOG_DEFAULT = 40;', expect: [ 'log: more than 40 lines, filter and count, download of what is shown, source and size, polled' ] },
	{ name: 'the filter ignored', from: "if (!f) return all;", to: "return all;", expect: [ 'log: more than 40 lines, filter and count, download of what is shown, source and size, polled' ] },
	{ name: 'download of the whole log, not what is shown', from: "var lines = this.shownLines();\n\t\tif (!lines.length) { common.toast(", to: "var lines = (this.log && this.log.lines) || [];\n\t\tif (!lines.length) { common.toast(", expect: [ 'log: more than 40 lines, filter and count, download of what is shown, source and size, polled' ] },
	{ name: 'the source not asked', from: "return common.call('logs', { lines: n, source: src }", to: "return common.call('logs', { lines: n }", expect: [ 'log: more than 40 lines, filter and count, download of what is shown, source and size, polled' ] },
	{ name: 'diag polled on a timer', from: "poll.add(L.bind(this.loadLog, this), 10);", to: "poll.add(L.bind(function() { this.loadLog(); return common.call('diag', {}); }, this), 10);", expect: [ 'log: more than 40 lines, filter and count, download of what is shown, source and size, polled' ] },
	{ name: 'the update command offered without the engine', from: "if (a.installed && g.update_available) {", to: "if (g.update_available || !a.installed) {", expect: [ 'engine: AmneziaWG yes/no and how to install or update, in every case' ] },
	{ name: 'AmneziaWG 3.1 not told apart', from: "g.awg31 ? _('supported, including 3.1') : _('supported (without 3.1)')", to: "_('supported, including 3.1')", expect: [ 'engine: AmneziaWG yes/no and how to install or update, in every case' ] },
	{ name: 'the exit result not shown', from: "\t\t\tout.textContent = t;\n", to: "\n", expect: [ '"Check the exit through the VPN": country and address; a failure says why' ] },
	{ name: '"Check again" does not redraw', from: "\t\t\tself.diag = d;\n\t\t\tself.paint();", to: "\t\t\tself.diag = d;", expect: [ '"Check again" reads diag again and redraws; an unreadable diag is said' ] },
	// two layers: the values go in as text nodes, and every child is in an array
	{ name: 'a foreign value as markup', from: [ [ "[ (value && value.nodeType) ? value : txt(shown(value)) ]", "(value && value.nodeType) ? value : shown(value)" ], [ 'var E = common.E;', '' ] ], expect: [ 'checks, the engine and every technical parameter from diag; foreign values are text' ] },
	{ name: 'a failed log read not said', from: "self.logError = (e && e.text) || common.codeText('failed');", to: "self.logError = null;", expect: [ 'log: more than 40 lines, filter and count, download of what is shown, source and size, polled' ] }
];

let FINISHED = false;
process.on('exit', () => { if (!FINISHED) { console.log('DIAG: aborted before the summary'); process.exitCode = 1; } });
(async function main() {
	const viewSrc = fs.readFileSync(VIEW_PATH, 'utf8');
	COMMON_SRC = fs.readFileSync(COMMON_PATH, 'utf8');
	if (process.argv.includes('--negative')) {
		const base = await run(viewSrc, COMMON_SRC, true);
		if (base.fail) { FINISHED = true; console.log('DIAG-NEG: baseline not green: ' + base.failed.join('; ')); console.log('DIAG-NEG: passed=0 failed=1'); process.exit(1); }
		let p = 0, f = 0;
		for (const m of MUTATIONS) {
			const pairs = Array.isArray(m.from) ? m.from : [ [ m.from, m.to ] ];
			const lost = pairs.filter(([ a ]) => !viewSrc.includes(a));
			if (lost.length) { f++; console.log('FAIL - [' + m.name + '] mutation anchor not found in diagnostics.js: ' + lost[0][0]); continue; }
			let src = viewSrc;
			pairs.forEach(([ a, z ]) => { src = src.replace(a, z); });
			const r = await run(src, COMMON_SRC, true);
			const missing = m.expect.filter(x => !r.failed.includes(x));
			if (missing.length || !r.fail) { f++; console.log('FAIL - [' + m.name + '] stayed green: ' + (missing.join('; ') || '(nothing failed)')); }
			else { p++; console.log('ok   - [' + m.name + '] -> red: ' + r.failed.join('; ')); }
		}
		FINISHED = true; console.log('DIAG-NEG: passed=' + p + ' failed=' + f);
		process.exit(f || !p ? 1 : 0);
	}
	const r = await run(viewSrc, COMMON_SRC, false);
	FINISHED = true; console.log('DIAG: passed=' + r.pass + ' failed=' + r.fail + ' checked=' + CHECKS);
	process.exit(r.fail || !r.pass || CHECKS < 50 ? 1 : 0);
})();
