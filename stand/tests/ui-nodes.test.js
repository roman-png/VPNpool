#!/usr/bin/env node
// Behaviour tests of the "Nodes" tab (resources/view/vpnpool/nodes.js) outside the browser: the
// real view and the real common.js run on the fakes of ui-fake.js (LuCI globals + a DOM that
// records every innerHTML write and drops the focus of an element that is moved or removed).
// The backend is a table of fake rpcd replies; every call is logged with its arguments.
//   node stand/tests/ui-nodes.test.js            -> "NODES: passed=N failed=M checked=K", exit 1 on failure
//   node stand/tests/ui-nodes.test.js --negative -> break nodes.js in memory, one mutation at a
//                                                   time; each must turn its tests red
//                                                   ("NODES-NEG: passed=N failed=M")
// What is judged: groups by source and the state words of a card; updates cell by cell (the
// same elements, the focus stays, no reordering); "+ Add" (analyze preview with a chip and a
// reason per line -> add with the checked lines -> the result with the error lines; a
// subscription address with picked nodes; a file; nothing added); "Connect" / "Back to automatic
// choice"; the "⋯" menu (favourites, hide / return, the automatic choice); the bulk panel (only
// with a selection, delete asks first, one call); the subscription group (pick nodes, turn off,
// delete); speed test; only the 2.0 methods are used.
'use strict';
const fs = require('fs');
const path = require('path');
const { makeEnv, load } = require('./ui-fake.js');

const REPO = process.env.REPO_DIR || path.resolve(__dirname, '../..');
const RES = path.join(REPO, 'package/luci-app-vpnpool/files/www/luci-static/resources');
const VIEW_PATH = path.join(RES, 'view/vpnpool/nodes.js');
const COMMON_PATH = path.join(RES, 'vpnpool/common.js');
const XSS = '<img src=x onerror="window.pwned=1">';

// LuCI's String.prototype.format (%s, %d) for the view's texts
if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', { value: function(...a) {
		let i = 0;
		return this.replace(/%([sd%])/g, (m, t) => t === '%' ? '%' : (t === 'd' ? String(parseInt(a[i++], 10)) : String(a[i++])));
	} });
}

// ---------- fixture: a status reply of the 2.0 backend (status.uc) ----------
const ID = { A: 'aaaaaaaaaaa1', B: 'bbbbbbbbbbb2', C: 'ccccccccccc3', D: 'ddddddddddd4', M: 'eeeeeeeeeee5', W: 'fffffffffff6',
	F: '0000000000f7', H: '0000000000a8', N: '0000000000b9' };
const NOW = 1000000;   // seconds; the fake clock starts at 1 000 000 ms, the view reads Date.now()
const GB = 1073741824;
function fixture(over) {
	const now = Math.floor(NOW / 1000);
	const st = {
		ok: true, code: 'ok', daemon: 'n/a', enabled: true, running: true,
		active: 'auto', auto_now: 'Alpha', preferred: null,
		settings: { check_services: 'www.youtube.com https://openai.com/x', auto_switch: true },
		subscriptions: [
			{ id: 'sub_main', key: 'k1main', name: 'Main provider', url: 'https://p.example/***', enabled: true, mode: 'all', picked: 0,
				pick_missing: 0, in_pool: 3, expire: now + 5 * 86400 + 3600, used: 10 * GB - 512 * 1048576, total: 10 * GB, updated_at: now - 600, result: 'ok' },
			{ id: 'sub_pick', key: 'k2pick', name: 'Picked list', url: 'https://q.example/***', enabled: true, mode: 'pick', picked: 1,
				pick_missing: 0, in_pool: 1, expire: null, used: null, total: null, updated_at: now - 7200, result: 'failed' }
		],
		nodes: [
			{ tag: 'Alpha', id: ID.A, proto: 'vless', server: 'a.example', delay: 85, source: 'subscription', sub: 'sub_main', favorite: false, preferred: false, dead: false, kept: false, unlock: { youtube: true, netflix: false } },
			{ tag: 'Bravo', id: ID.B, proto: 'trojan', server: 'b.example', delay: 0, source: 'subscription', sub: 'sub_main', dead: true, kept: false },
			{ tag: 'Charlie', id: ID.C, proto: 'vless', server: 'c.example', delay: 120, source: 'subscription', sub: 'sub_main' },
			{ tag: 'Delta', id: ID.D, proto: 'vless', server: 'd.example', delay: 200, source: 'subscription', sub: 'sub_pick' },
			{ tag: 'My link', id: ID.M, proto: 'vmess', server: 'm.example', delay: 50, source: 'manual', favorite: true },
			{ tag: 'Home AWG', id: ID.W, proto: 'awg', server: 'w.example', delay: null, source: 'awg', deferred: true, reason: 'engine_missing' }
		],
		auto_member_ids: [], auto_exclude_ids: [ ID.C ],   // Charlie is excluded by the user
		dead_ids: [ ID.B ], kept_ids: [],
		favorites: [ { id: ID.M, tag: 'My link', in_pool: true }, { id: ID.F, tag: 'Old favourite', in_pool: false, type: 'vless' } ],
		hidden: [ { id: ID.H, tag: 'Hidden one', type: 'vless', in_source: true } ],
		unreadable: [], busy: {}, ping_progress: {}
	};
	if (over) over(st);
	return st;
}
const node = (st, tag) => st.nodes.find(n => n.tag === tag);

// ---------- harness ----------
let CHECKS = 0;
function eq(a, b, what) { CHECKS++; if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((what || 'value') + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b)); }
function ok(c, what) { CHECKS++; if (!c) throw new Error(what || 'assertion failed'); }

function setup(viewSrc, commonSrc, opts) {
	const env = makeEnv(opts);
	env.win.btoa = s => Buffer.from(s, 'binary').toString('base64');
	const common = load(commonSrc, env);
	const view = { extend(proto) { function V() {} V.prototype = proto; return V; } };
	class FakeReader { readAsText(f) { this.result = f.text; Promise.resolve().then(() => this.onload && this.onload()); } }
	const fn = new Function('view', 'ui', 'poll', 'dom', 'common', 'E', '_', 'N_', 'L', 'window', 'document', 'console', 'Date', 'URL', 'Image', 'FileReader', viewSrc);
	const V = fn(view, env.ui, env.poll, env.dom, common, env.D.E, s => s, (n, one, many) => (n === 1 ? one : many), env.L, env.win, env.doc, env.consoleQuiet, env.DateC, {}, function() {}, FakeReader);
	const v = new V();
	const calls = m => env.rpcLog.filter(x => x[0] === m).map(x => x[1]);
	return { env, common, v, calls, viewSrc };
}
async function open(t, st) {
	t.env.handlers.status = () => st;
	const r = await t.v.load();
	const root = t.v.render(r);
	t.env.mc.appendChild(root);
	return root;
}
const settle = t => t.env.tick(50);
async function poll(t, st) { t.env.handlers.status = () => st; await t.env.pollFns[0](); await settle(t); }
const cards = root => root.querySelectorAll('.vp-card');
const titleOf = c => c.querySelector('.vp-card-title').textContent;
const card = (root, title) => cards(root).find(c => titleOf(c) === title);
const stateOf = c => c.querySelector('.vp-card-state').textContent;
const primaryOf = c => c.querySelector('.vp-card-primary');
const badgesOf = c => c.querySelector('.vp-card-badges').children.map(b => b.textContent + '/' + [ ...b.classes ].find(x => /^vp-badge-/.test(x)));
const menuLabels = el => el.querySelectorAll('.vp-menu-item').map(b => b.textContent);
function clickMenu(t, el, label) {
	const it = el.querySelectorAll('.vp-menu-item').find(b => b.textContent === label);
	if (!it) throw new Error('menu item not found: ' + label + ' in ' + JSON.stringify(menuLabels(el)));
	t.env.D.fire(it, 'click', {});
}
const click = (t, el) => t.env.D.fire(el, 'click', {});
function check(t, el, v) { el.checked = v; t.env.D.fire(el, 'change', {}); }
const groupTitles = root => root.querySelectorAll('.vp-group-title').map(n => n.textContent);
const group = (root, title) => root.querySelectorAll('.vp-group').find(g => g.querySelector('.vp-group-title').textContent === title);
const toasts = (t, kind) => t.env.mc.children.filter(n => n.classes && n.classes.has('vp-toast') && (!kind || n.classes.has(kind))).map(n => n.textContent);
const modal = t => t.env.doc.body.querySelector('.modal');
const confirmDlg = t => t.env.doc.body.querySelector('.vp-confirm');

const T = [];
function test(name, fn) { T.push({ name, fn }); }

// ---------- tests ----------
test('groups by source, state words of every kind of card, no innerHTML', async (t) => {
	const st = fixture(s => { node(s, 'Charlie').tag = XSS; s.subscriptions[1].name = XSS; });
	const root = await open(t, st);
	eq(cards(root).length, 8, 'positive control: cards (3 + 1 subscription, 2 mine, 1 favourite, 1 hidden)');
	eq(groupTitles(root), [ 'Main provider', XSS, 'My nodes', 'Favourites no subscription has', 'Hidden' ], 'groups in order');
	eq(group(root, 'Main provider').querySelectorAll('.vp-card').map(titleOf), [ 'Alpha', 'Bravo', XSS ], 'cards of the first subscription');
	const A = card(root, 'Alpha');
	eq(stateOf(A), 'In use: automatic choice', 'Alpha state');
	ok(A.classes.has('vp-active'), 'Alpha is the active card');
	eq(A.querySelector('.vp-card-sub').textContent, 'VLESS · 85 ms', 'Alpha type and delay');
	eq(badgesOf(A), [ 'YouTube/vp-badge-ok', 'Netflix/vp-badge-error' ], 'service badges');
	eq(primaryOf(A).textContent, 'Connect', 'Alpha main button');
	eq(stateOf(card(root, 'Bravo')), 'Does not open one of the checked sites (www.youtube.com, openai.com), so it is left out of the automatic choice', 'dead node: the strict check over two sites');
	ok(card(root, 'Bravo').classes.has('vp-dimmed'), 'dead node dimmed');
	eq(stateOf(card(root, XSS)), 'Excluded by you from the automatic choice', 'excluded node');
	eq(stateOf(card(root, 'Delta')), 'In the automatic choice', 'plain node');
	const W = card(root, 'Home AWG');
	eq(stateOf(W), 'Waits for the AmneziaWG engine', 'deferred node');
	ok(primaryOf(W).disabled, 'deferred: Connect disabled');
	ok(!menuLabels(W).includes('Speed test') && menuLabels(W).includes('Delete'), 'deferred: no tests in the menu, delete is there');
	eq(primaryOf(card(root, 'Old favourite')).textContent, 'Connect', 'favourite no subscription has: Connect');
	eq(primaryOf(card(root, 'Hidden one')).textContent, 'Return', 'hidden: Return');
	eq(badgesOf(card(root, 'My link')), [ 'Favourite/vp-badge-info' ], 'favourite badge');
	const info = group(root, 'Main provider').querySelector('.vp-group-info').textContent;
	ok(/valid until .* \(5 days left\)/.test(info), 'expiry in the header: ' + info);
	ok(info.includes('512.0 MB of 10.00 GB left') && info.includes('updated 10 min ago') && info.includes('best ping 85 ms') && info.includes('every node'), 'quota / updated / best ping: ' + info);
	const info2 = group(root, XSS).querySelector('.vp-group-info').textContent;
	ok(info2.includes('picked nodes: 1') && info2.includes('the last update failed') && info2.includes('updated 2 h ago'), 'picked subscription header: ' + info2);
	ok(t.env.doc.body.querySelector('.vp-bulk').hidden, 'no bulk panel without a selection');
	// the dialogs too: their own texts and the foreign names of a pasted line stay text
	t.env.handlers.analyze = () => ({ ok: true, code: 'ok', items: [ { line: 1, kind: 'link', status: 'add', name: XSS, type: 'vless', server: XSS },
		{ line: 2, kind: 'link', status: 'skip', reason: 'parse_error' } ] });
	const D = t.v.handleAdd();
	D.ta.value = 'vless://x\n' + XSS;
	t.env.D.fire(D.checkBtn, 'click', {}); await settle(t);
	ok(D.preview.querySelectorAll('.vp-add-row').length === 2, 'positive control: the preview is rendered');
	t.v.handleAutoPool();
	t.v.handleExport();
	eq(t.env.doc.unsafe, [], 'innerHTML writes');
});

test('a poll updates cell by cell: same elements, focus kept, no reordering; gone and new cards', async (t) => {
	const root = await open(t, fixture());
	const A = card(root, 'Alpha'), title = A.querySelector('.vp-card-title'), btn = primaryOf(A);
	btn.focus();
	const before = cards(root).map(titleOf);
	ok(before.length === 8, 'positive control: 8 cards');
	await poll(t, fixture(s => {
		node(s, 'Alpha').delay = 95;
		node(s, 'Bravo').dead = false; s.dead_ids = [];
		s.nodes = s.nodes.filter(n => n.tag !== 'Delta');
		s.nodes.splice(3, 0, { tag: 'Echo', id: ID.N, proto: 'hysteria2', delay: 30, source: 'subscription', sub: 'sub_main' });
	}));
	ok(card(root, 'Alpha') === A && A.querySelector('.vp-card-title') === title, 'the same card and title elements');
	eq(A.querySelector('.vp-card-sub').textContent, 'VLESS · 95 ms', 'delay updated in place');
	ok(t.env.doc.activeElement === btn, 'focus stays on the button');
	eq(group(root, 'Main provider').querySelectorAll('.vp-card').map(titleOf), [ 'Alpha', 'Bravo', 'Charlie', 'Echo' ], 'order kept, the new card at its place');
	ok(!card(root, 'Delta'), 'a gone node is removed');
	eq(stateOf(card(root, 'Bravo')), 'In the automatic choice', 'state updated');
	eq(group(root, 'Picked list').querySelector('.vp-group-empty').hidden, false, 'an empty subscription says so');
});

async function analyzeWith(t, items, lines) {
	// the real analyze answers line NUMBERS (no texts): the view numbers the lines itself, after
	// dropping the blank lines around the paste (as api.uc does)
	t.env.handlers.analyze = () => ({ ok: true, code: 'ok', daemon: 'n/a', items });
	const D = t.v.handleAdd();
	D.ta.value = '\n \n' + Object.keys(lines).map(k => lines[k]).join('\n') + '\n\n';
	click(t, D.checkBtn);
	await settle(t);
	return D;
}
const rowsOf = D => D.preview.querySelectorAll('.vp-add-row');
const chips = D => rowsOf(D).map(r => r.querySelector('.vp-add-chip').textContent);

test('"+ Add": a chip and a reason per line, add sends the checked lines, the result names the error lines', async (t) => {
	await open(t, fixture());
	const D = await analyzeWith(t, [
		{ line: 1, kind: 'link', status: 'add', name: 'New A', type: 'vless', server: '1.2.3.4' },
		{ line: 2, kind: 'link', status: 'add', name: 'New B', type: 'trojan' },
		{ line: 3, kind: 'link', status: 'dup', reason: 'exists' },
		{ line: 4, kind: 'unknown', status: 'skip', reason: 'not_a_link' },
		{ line: 5, kind: 'link', status: 'add', name: 'New C' }
	], { 1: 'vless://a', 2: 'trojan://b', 3: 'vless://c', 4: 'hello', 5: 'vless://e' });
	eq(t.calls('analyze'), [ { text: '\n \nvless://a\ntrojan://b\nvless://c\nhello\nvless://e\n\n' } ], 'analyze got the text');
	eq(rowsOf(D).length, 5, 'positive control: a row per line');
	eq(chips(D), [ 'Will be added', 'Will be added', 'Already there', 'Will not be added', 'Will be added' ], 'chips');
	eq(rowsOf(D)[3].querySelector('.vp-add-why').textContent, t.common.REASON_TEXT.not_a_link, 'reason of a line that is not added');
	eq(rowsOf(D)[2].querySelector('.vp-add-why').textContent, t.common.REASON_TEXT.exists, 'reason of a duplicate');
	eq(rowsOf(D)[2].querySelector('.vp-add-name').textContent, 'vless://c', 'a line without a name shows its own text');
	eq(rowsOf(D)[0].querySelector('.vp-add-meta').textContent, 'VLESS · 1.2.3.4', 'type and server');
	eq(D.summary.textContent, 'Will be added: 3, already there: 1, will not be added: 1', 'summary of the check');
	ok(!D.addBtn.disabled, 'Add enabled');
	check(t, rowsOf(D)[4].querySelector('input'), false);   // the user leaves line 5 out
	t.env.handlers.add = () => ({ ok: true, code: 'added', daemon: 'signalled', added: 1, dup: 0, failed: [ { line: 2, reason: 'unsupported_transport' } ] });
	click(t, D.addBtn);
	await settle(t);
	eq(t.calls('add'), [ { text: D.text, lines: [ 1, 2 ] } ], 'add: only the checked lines');
	eq(D.result.textContent, 'Added: 1, already there: 1, errors: 2 (lines 2, 4)', 'result');
	ok(t.env.ui.modalOpen, 'the dialog stays open while there are errors');
	eq(chips(D)[0] + '|' + chips(D)[1], 'Added|Not added', 'chips after adding');
	eq(rowsOf(D)[1].querySelector('.vp-add-why').textContent, t.common.REASON_TEXT.unsupported_transport, 'why line 2 failed');
	ok(D.addBtn.disabled, 'Add locked until the text changes');
	ok(t.calls('status').length >= 2, 'the list is refreshed after adding');
});

test('"+ Add": everything fine closes the dialog with the result; "nothing added" is a result, not an error', async (t) => {
	await open(t, fixture());
	let D = await analyzeWith(t, [ { line: 1, kind: 'link', status: 'add', name: 'New A' } ], { 1: 'vless://a' });
	t.env.handlers.add = () => ({ ok: true, code: 'added', daemon: 'signalled', added: 1, dup: 0, failed: [] });
	click(t, D.addBtn); await settle(t);
	ok(!t.env.ui.modalOpen, 'closed');
	eq(toasts(t, 'info'), [ 'Added: 1, already there: 0, errors: 0' ], 'result toast');
	D = await analyzeWith(t, [ { line: 1, kind: 'link', status: 'add', name: 'New A' }, { line: 2, kind: 'link', status: 'add', name: 'New B' } ], { 1: 'vless://a', 2: 'vless://b' });
	t.env.handlers.add = () => ({ ok: false, code: 'nothing_added', error: 'nothing_added', daemon: 'n/a', added: 0, dup: 1, failed: [ { line: 2, reason: 'parse_error' } ] });
	click(t, D.addBtn); await settle(t);
	eq(D.result.textContent, 'Added: 0, already there: 1, errors: 1 (lines 2)', 'nothing added: counted from the reply');
	eq(toasts(t, 'danger'), [], 'no error toast for "nothing added"');
	// a field error of analyze is said under the field (common.js), and goes with the next good check
	t.env.handlers.analyze = () => ({ ok: false, code: 'invalid', error: 'invalid', daemon: 'n/a', errors: { text: 'bad_type' } });
	click(t, D.checkBtn); await settle(t);
	eq(D.box.querySelectorAll('.vp-field-error-text').map(n => n.textContent), [ t.common.FIELD_TEXT.bad_type ], 'field error under the field');
	t.env.handlers.analyze = () => ({ ok: true, code: 'ok', items: [ { line: 1, kind: 'link', status: 'add', name: 'X' } ] });
	click(t, D.checkBtn); await settle(t);
	eq(D.box.querySelectorAll('.vp-field-error-text').length, 0, 'gone after a good check');
});

test('"+ Add" a subscription address: pick nodes -> add with mode pick and the picked ids', async (t) => {
	await open(t, fixture());
	const D = await analyzeWith(t, [ { line: 1, kind: 'subscription_url', status: 'add', name: 'https://sub.example/***' } ], { 1: 'https://sub.example/abc' });
	const row = rowsOf(D)[0];
	const sel = row.querySelector('.vp-add-mode');
	ok(sel, 'a subscription line offers what to take');
	t.env.handlers.probe_source = () => ({ ok: true, code: 'started', daemon: 'n/a', running: true });
	t.env.handlers.probe_result = (p, n) => n < 2 ? { ok: true, code: 'running', running: true }
		: { ok: true, code: 'done', running: false, nodes: [ { i: 0, id: '111111111111', tag: 'P1', server: 's1', delay: 40 },
			{ i: 1, id: '222222222222', tag: 'P2', delay: null }, { i: 2, id: '333333333333', tag: 'P3', delay: 70 } ] };
	sel.value = 'pick'; t.env.D.fire(sel, 'change', {});
	await t.env.tick(10000);
	eq(t.calls('probe_source'), [ { url: 'https://sub.example/abc' } ], 'the address is checked on the router');
	const boxes = row.querySelectorAll('.vp-pick-item').map(l => l.querySelector('input'));
	eq(boxes.length, 3, 'positive control: the nodes of the subscription');
	eq(boxes.map(b => b.checked), [ true, false, true ], 'the answering ones are picked first');
	boxes.forEach(b => check(t, b, false));
	t.env.handlers.add = () => ({ ok: true, code: 'added', daemon: 'signalled', added: 1, dup: 0, failed: [] });
	click(t, D.addBtn); await settle(t);
	eq(t.calls('add'), [], 'nothing sent with no node picked');
	ok(toasts(t, 'warning').some(x => /^Line 1: pick at least one node/.test(x)), 'warning: ' + JSON.stringify(toasts(t, 'warning')));
	check(t, boxes[0], true);
	click(t, D.addBtn); await settle(t);
	eq(t.calls('add'), [ { text: D.text, lines: [ 1 ], options: { mode: 'pick', pick: [ '111111111111' ] } } ], 'add with the picked ids');
});

test('"+ Add" from a file: links are added to the field, AmneziaWG settings replace it, a huge file is refused', async (t) => {
	await open(t, fixture());
	t.env.handlers.analyze = () => ({ ok: true, code: 'ok', items: [] });
	const D = t.v.handleAdd();
	D.ta.value = 'vless://x';
	await t.v.addFile(D, { size: 10, text: 'trojan://y' }); await settle(t);
	eq(D.ta.value, 'vless://x\ntrojan://y', 'appended');
	eq(t.calls('analyze').length, 1, 'checked at once');
	await t.v.addFile(D, { size: 30, text: '[Interface]\nPrivateKey = k\n' }); await settle(t);
	eq(D.ta.value, '[Interface]\nPrivateKey = k\n', 'settings replace the field');
	ok(toasts(t, 'info').some(x => /one file at a time/.test(x)), 'the user is told why');
	await t.v.addFile(D, { size: 5 * 1048576, text: 'x' }); await settle(t);
	eq(t.calls('analyze').length, 2, 'a huge file is not sent');
	ok(toasts(t, 'danger').includes(t.common.CODE_TEXT.too_large), 'too large');
	// the request limit counts bytes: 35 000 Cyrillic letters = 70 000 bytes in the request
	D.ta.value = '';
	await t.v.addFile(D, { size: 70000, text: 'я'.repeat(35000) }); await settle(t);
	D.ta.value = '';
	eq(t.calls('analyze').length, 2, 'a text over the request limit (in bytes) is not sent');
	ok(toasts(t, 'danger').some(x => /too large to check at once/.test(x)), 'said why');
	await t.v.addFile(D, { size: 50000, text: 'a'.repeat(50000) }); await settle(t);
	eq(t.calls('analyze').length, 3, 'positive control: 50 000 plain letters pass');
});

test('"Connect" is the soft choice; the chosen node offers "Back to automatic choice"', async (t) => {
	const root = await open(t, fixture());
	t.env.handlers.connect = () => ({ ok: true, code: 'applied', daemon: 'n/a', id: ID.D });
	click(t, primaryOf(card(root, 'Delta'))); await settle(t);
	eq(t.calls('connect'), [ { id: ID.D } ], 'connect by id');
	ok(toasts(t, 'info').includes('Connected to Delta.'), 'toast: ' + JSON.stringify(toasts(t, 'info')));
	await poll(t, fixture(s => { s.preferred = { id: ID.D, tag: 'Delta', in_pool: true }; s.active = 'Delta'; node(s, 'Delta').preferred = true; }));
	const Dc = card(root, 'Delta');
	eq(primaryOf(Dc).textContent, 'Back to automatic choice', 'the chosen node: back to automatic');
	eq(stateOf(Dc), 'In use: chosen by you', 'state of the chosen node');
	ok(/^Connected to Delta: chosen by you/.test(root.querySelector('.vp-now-text').textContent), 'the line on top says it');
	ok(!root.querySelector('.vp-auto-btn').hidden, 'and offers the way back');
	t.env.handlers.auto_select = () => ({ ok: true, code: 'applied', daemon: 'n/a' });
	click(t, primaryOf(Dc)); await settle(t);
	eq(t.calls('auto_select'), [ {} ], 'auto_select');
	t.env.handlers.connect = () => ({ ok: true, code: 'connect_pending', daemon: 'signalled', id: ID.F });
	click(t, primaryOf(card(root, 'Old favourite'))); await settle(t);
	eq(t.calls('connect')[1], { id: ID.F }, 'a favourite no subscription has connects by id');
	ok(toasts(t, 'info').includes(t.common.CODE_TEXT.connect_pending), 'pending text');
	eq(t.calls('select').length + t.calls('set_preferred').length, 0, 'no legacy method');
});

test('"⋯" menu: favourites, hide and return, the automatic choice; the menu follows the node', async (t) => {
	const root = await open(t, fixture());
	const A = card(root, 'Alpha');
	eq(menuLabels(A), [ 'Add to favourites', 'QR code and link', 'Speed test', 'Check services', 'Exclude from the automatic choice', 'Hide', 'Delete' ], 'menu of a node');
	t.env.handlers.fav = () => ({ ok: true, code: 'saved', daemon: 'n/a', id: ID.A });
	clickMenu(t, A, 'Add to favourites'); await settle(t);
	eq(t.calls('fav'), [ { id: ID.A } ], 'fav by id');
	await poll(t, fixture(s => { node(s, 'Alpha').favorite = true; }));
	eq(menuLabels(A)[0], 'Remove from favourites', 'the menu follows the node');
	ok(badgesOf(A).includes('Favourite/vp-badge-info'), 'favourite badge');
	t.env.handlers.hide = () => ({ ok: true, code: 'hidden', daemon: 'signalled', id: ID.A });
	clickMenu(t, A, 'Hide'); await settle(t);
	eq(t.calls('hide'), [ { id: ID.A } ], 'hide by id');
	t.env.handlers.unhide = () => ({ ok: true, code: 'restored', daemon: 'signalled', id: ID.H });
	click(t, primaryOf(card(root, 'Hidden one'))); await settle(t);
	eq(t.calls('unhide'), [ { id: ID.H } ], 'Return = unhide');
	t.env.handlers.restore_node = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	clickMenu(t, card(root, 'Bravo'), 'Return to the automatic choice'); await settle(t);
	eq(t.calls('restore_node'), [ { id: ID.B } ], 'a node that fails the check: kept by the user');
	t.env.handlers.auto_include = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	t.env.handlers.auto_exclude = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	clickMenu(t, card(root, 'Charlie'), 'Return to the automatic choice'); await settle(t);
	clickMenu(t, card(root, 'Alpha'), 'Exclude from the automatic choice'); await settle(t);
	eq([ t.calls('auto_include'), t.calls('auto_exclude') ], [ [ { id: ID.C } ], [ { id: ID.A } ] ], 'one node in, one node out — by id, nothing about the others');
	eq(t.calls('set_auto_members').length, 0, 'no "everyone but" list written');
});

test('bulk panel only with a selection; bulk delete asks first and is one call', async (t) => {
	const root = await open(t, fixture());
	const bulk = root.querySelector('.vp-bulk');
	ok(bulk.hidden, 'hidden without a selection');
	check(t, card(root, 'Alpha').querySelector('.vp-card-sel'), true);
	check(t, card(root, 'My link').querySelector('.vp-card-sel'), true);
	ok(!bulk.hidden, 'shown with a selection');
	eq(bulk.querySelector('.vp-bulk-count').textContent, 'Selected: 2', 'count');
	eq(bulk.querySelectorAll('button').map(b => b.textContent), [ 'Add to favourites', 'Hide', 'Delete', 'Clear the selection' ], 'labelled buttons');
	t.env.handlers.delete_nodes = () => ({ ok: true, code: 'deleted', daemon: 'signalled', deleted: 2 });
	click(t, bulk.querySelector('.vp-bulk-del')); await settle(t);
	const dlg = confirmDlg(t);
	ok(dlg && t.env.ui.modalOpen, 'asks first');
	eq(dlg.querySelectorAll('li').map(l => l.textContent), [
		'Nodes of a subscription (1) are hidden: the subscription will not bring them back. You can return them from the hidden nodes.',
		'Your links (1) are removed from your nodes.', 'Favourites (1) stay in your favourites.' ], 'consequences');
	click(t, dlg.querySelector('.vp-confirm-cancel')); await settle(t);
	eq(t.calls('delete_nodes'), [], 'Cancel deletes nothing');
	click(t, bulk.querySelector('.vp-bulk-del')); await settle(t);
	click(t, confirmDlg(t).querySelector('.vp-confirm-ok')); await settle(t);
	eq(t.calls('delete_nodes'), [ { ids: [ ID.A, ID.M ] } ], 'one call for all');
	ok(bulk.hidden, 'the deleted ones leave the selection');
	t.env.handlers.hide = () => ({ ok: true, code: 'hidden', daemon: 'signalled' });
	check(t, card(root, 'Alpha').querySelector('.vp-card-sel'), true);
	check(t, card(root, 'Delta').querySelector('.vp-card-sel'), true);
	click(t, bulk.querySelector('.vp-bulk-hide')); await settle(t);
	eq(t.calls('hide'), [ { id: ID.A }, { id: ID.D } ], 'hide each');
	ok(bulk.hidden && !card(root, 'Alpha').querySelector('.vp-card-sel').checked, 'selection cleared');
});

test('subscription group: pick nodes, turn off, delete', async (t) => {
	const root = await open(t, fixture());
	const G = group(root, 'Main provider'), acts = G.querySelector('.vp-group-actions');
	eq(menuLabels(acts), [ 'Pick nodes…', 'Turn off', 'Delete the subscription' ], 'group menu');
	t.env.handlers.sub_set = () => ({ ok: true, code: 'saved', daemon: 'signalled', id: 'sub_main' });
	clickMenu(t, acts, 'Turn off'); await settle(t);
	eq(t.calls('sub_set'), [ { id: 'sub_main', enabled: false } ], 'turn off');
	t.env.handlers.sub_del = () => ({ ok: true, code: 'deleted', daemon: 'signalled' });
	clickMenu(t, acts, 'Delete the subscription'); await settle(t);
	ok(confirmDlg(t), 'delete asks first');
	click(t, confirmDlg(t).querySelector('.vp-confirm-ok')); await settle(t);
	eq(t.calls('sub_del'), [ { id: 'sub_main' } ], 'delete by id');
	t.env.handlers.probe_source = () => ({ ok: true, code: 'started', running: true });
	t.env.handlers.probe_result = () => ({ ok: true, code: 'done', running: false, nodes: [ { id: ID.A, tag: 'Alpha', delay: 85, in_pool: true }, { id: ID.C, tag: 'Charlie', delay: 120 }, { id: ID.N, tag: 'Echo', delay: null } ] });
	clickMenu(t, acts, 'Pick nodes…'); await t.env.tick(5000);
	eq(t.calls('probe_source'), [ { url: 'k1main' } ], 'probe by the key of the subscription');
	const box = modal(t).querySelector('.vp-pick-box');
	const items = box.querySelectorAll('.vp-pick-item').map(l => l.querySelector('input'));
	eq(items.length, 4, 'positive control: "every node" + 3 nodes');
	ok(items[0].checked && items.slice(1).every(b => b.checked && b.disabled), 'a subscription taking every node: all checked, list locked');
	check(t, items[0], false);
	ok(!items[1].disabled, 'unlocked');
	check(t, items[3], false);
	const save = modal(t).querySelectorAll('button').find(b => b.textContent === 'Save');
	click(t, save); await settle(t);
	eq(t.calls('sub_set')[1], { id: 'sub_main', mode: 'pick', pick: [ ID.A, ID.C ] }, 'picked ids');
});

test('speed test: the card says it is testing, the result is a badge; a failure is said', async (t) => {
	const root = await open(t, fixture());
	t.env.handlers.speedtest = () => ({ ok: true, code: 'started', daemon: 'n/a', running: true });
	t.env.handlers.speedtest_result = (p, n) => n < 2 ? { ok: true, code: 'running', running: true } : { ok: true, code: 'done', running: false, mbps: 42.5 };
	clickMenu(t, card(root, 'Alpha'), 'Speed test'); await settle(t);
	eq(t.calls('speedtest'), [ { id: ID.A } ], 'by id');
	eq(stateOf(card(root, 'Alpha')), 'Testing the speed…', 'busy state on the card');
	await t.env.tick(4500);   // the result comes with the 2nd poll (4 s); an info toast fades after ~4.6 s
	ok(badgesOf(card(root, 'Alpha')).includes('42.5 Mbit/s/vp-badge-muted'), 'result badge: ' + JSON.stringify(badgesOf(card(root, 'Alpha'))));
	ok(toasts(t, 'info').includes('Alpha: 42.5 Mbit/s'), 'result toast');
	eq(stateOf(card(root, 'Alpha')), 'In use: automatic choice', 'state back');
	t.env.handlers.speedtest_result = () => ({ ok: false, code: 'low_memory', error: 'low_memory', running: false });
	clickMenu(t, card(root, 'Delta'), 'Speed test'); await t.env.tick(10000);
	ok(toasts(t, 'danger').includes(t.common.CODE_TEXT.low_memory), 'failure said: ' + JSON.stringify(toasts(t, 'danger')));
});

test('service off: a banner; nothing at all: the empty state with "+ Add"', async (t) => {
	const root = await open(t, fixture(s => { s.enabled = false; s.running = false; }));
	const b = root.querySelector('.vp-nodes-banner');
	ok(!b.hidden && /^VPN is off/.test(b.textContent), 'banner: ' + b.textContent);
	ok(root.querySelector('.vp-empty').hidden, 'no empty state with nodes');
	await poll(t, fixture(s => { s.nodes = []; s.subscriptions = []; s.favorites = []; s.hidden = []; s.enabled = true; s.running = true; }));
	ok(!root.querySelector('.vp-empty').hidden, 'empty state');
	eq(cards(root).length, 0, 'no cards left');
	ok(b.hidden, 'banner gone when the service runs');
});

// ui1 review: who takes part in the automatic choice is said the way the engine config is built
test('automatic choice by the engine\'s rule: a stale member list excludes nobody, "favourites only", the dialog', async (t) => {
	const stale = fixture(s => { s.auto_member_ids = [ '0000000000c1' ]; s.auto_exclude_ids = []; });
	ok(!stale.nodes.some(n => stale.auto_member_ids.includes(n.id)), 'fixture: the member list names no node of the build');
	const root = await open(t, stale);
	const words = cards(root).map(stateOf);
	ok(!words.some(w => /Excluded by you|Not on the list/.test(w)), 'nobody is left out by a stale list: ' + JSON.stringify(words));
	ok(menuLabels(card(root, 'Charlie')).includes('Exclude from the automatic choice'), '"Exclude" is offered (it will act)');
	t.v.handleAutoPool();
	const boxes = modal(t).querySelectorAll('.vp-pick-item').map(l => l.querySelector('input'));
	eq([ boxes.length, boxes.filter(b => b.checked).length ], [ 5, 5 ], 'the dialog: every node of the build checked');
	// a member list in effect (1.x): the others are off it, "Return" puts one back
	await poll(t, fixture(s => { s.auto_member_ids = [ ID.A ]; s.auto_exclude_ids = []; }));
	eq(stateOf(card(root, 'Delta')), 'Not on the list of nodes for the automatic choice', 'off a member list in effect');
	t.env.handlers.auto_include = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	clickMenu(t, card(root, 'Delta'), 'Return to the automatic choice'); await settle(t);
	eq(t.calls('auto_include'), [ { id: ID.D } ], 'return by id');
	// "favourites only" with a favourite in the pool: the others are not in the automatic choice
	await poll(t, fixture(s => { s.settings.favorites_only = true; }));
	eq(stateOf(card(root, 'Delta')), 'Not in the automatic choice: "favourites only" is on', 'favourites only');
	eq(stateOf(card(root, 'My link')), 'In the automatic choice', 'the favourite takes part');
	ok(!menuLabels(card(root, 'Delta')).some(l => /automatic choice/.test(l)), 'no Exclude / Return that would change nothing');
	await poll(t, fixture(s => { s.settings.favorites_only = true; s.nodes.forEach(n => { n.favorite = false; }); }));
	eq(stateOf(card(root, 'Delta')), 'In the automatic choice', 'favourites only without a favourite in the pool: no effect');
	// the dialog saves exclusions (and drops a 1.x member list) in one call
	await poll(t, fixture());
	t.env.handlers.set_config = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	t.v.handleAutoPool();
	const b2 = modal(t).querySelectorAll('.vp-pick-item').map(l => l.querySelector('input'));
	eq(b2.map(b => b.checked), [ true, true, false, true, true ], 'checked = not excluded (Charlie is)');
	check(t, b2[3], false);
	click(t, modal(t).querySelectorAll('button').find(b => b.textContent === 'Save')); await settle(t);
	eq(t.calls('set_config'), [ { settings: { auto_members: [], auto_excludes: [ ID.C, ID.D ] } } ], 'exclusions saved');
});

test('a hidden favourite is one card (in "Hidden"), not also "not among the nodes"', async (t) => {
	const root = await open(t, fixture(s => { s.favorites.push({ id: ID.H, tag: 'Hidden one', in_pool: false, type: 'vless' }); }));
	eq(cards(root).filter(c => titleOf(c) === 'Hidden one').length, 1, 'one card');
	eq(group(root, 'Favourites no subscription has').querySelectorAll('.vp-card').map(titleOf), [ 'Old favourite' ], 'favourites group');
	ok(badgesOf(card(root, 'Hidden one')).includes('Favourite/vp-badge-info'), 'the hidden card says it is a favourite');
	eq(stateOf(card(root, 'Old favourite')), 'Not among the nodes now: it is kept in your favourites and connects with one button', 'favourite text claims only what is known');
});

test('picking nodes shows only the result of OUR probe; a long list says it is cut', async (t) => {
	const root = await open(t, fixture());
	const acts = group(root, 'Main provider').querySelector('.vp-group-actions');
	// another window is checking another address
	t.env.handlers.probe_source = () => ({ ok: true, code: 'already_running', daemon: 'n/a', running: true, already: true });
	t.env.handlers.probe_result = () => ({ ok: true, code: 'done', running: false, nodes: [ { id: ID.N, tag: 'Foreign' } ] });
	clickMenu(t, acts, 'Pick nodes…'); await t.env.tick(5000);
	eq(t.calls('probe_result').length, 0, 'no poll of someone else\'s check');
	ok(/Another address is being checked/.test(modal(t).querySelector('.vp-pick-box').textContent), 'said: ' + modal(t).querySelector('.vp-pick-box').textContent);
	// our start, but the result is another job's
	t.env.handlers.probe_source = () => ({ ok: true, code: 'started', daemon: 'n/a', running: true, job: 'ours' });
	t.env.handlers.probe_result = () => ({ ok: true, code: 'done', running: false, job: 'theirs', nodes: [ { id: ID.N, tag: 'Foreign' } ] });
	clickMenu(t, acts, 'Pick nodes…'); await t.env.tick(5000);
	eq(modal(t).querySelectorAll('.vp-pick-item').length, 0, 'a foreign result is not shown');
	ok(modal(t).querySelectorAll('button').find(b => b.textContent === 'Save').disabled, 'and cannot be saved');
	// ours, cut on the router
	t.env.handlers.probe_result = () => ({ ok: true, code: 'done', running: false, job: 'ours', total: 512, shown: 2, capped: true,
		nodes: [ { id: ID.A, tag: 'Alpha' }, { id: ID.C, tag: 'Charlie' } ] });
	clickMenu(t, acts, 'Pick nodes…'); await t.env.tick(5000);
	eq(modal(t).querySelectorAll('.vp-pick-item').length, 3, 'positive control: our result shown ("every node" + 2)');
	eq(modal(t).querySelector('.vp-pick-capped').textContent, 'Shown: the first 2 of 512 nodes.', 'the cut is said');
});

test('only the 2.0 methods: no legacy call, every method known to common.js, no own rpc', async (t) => {
	const src = t.viewSrc;   // the source under test (a mutation of --negative included)
	const used = new Set([ ...src.matchAll(/(?:common\.call|pollResult)\('([a-z_]+)'/g) ].map(m => m[1]));
	ok(used.size >= 15, 'positive control: methods found ' + used.size);
	const LEGACY = [ 'select', 'set_preferred', 'save_node', 'unsave_node', 'activate_saved', 'deactivate_saved', 'add_node', 'del_node',
		'import_nodes', 'set_url', 'del_subscription', 'del_source', 'add_sub', 'del_sub', 'import_select', 'set_option', 'set_auto_members' ];
	eq([ ...used ].filter(m => LEGACY.includes(m)), [], 'legacy methods used');
	eq([ ...used ].filter(m => !t.common.METHODS[m]), [], 'methods unknown to common.js');
	ok(!/rpc\.declare|'require rpc'/.test(src), 'no own rpc declarations');
	for (const m of [ 'analyze', 'add', 'connect', 'auto_select', 'fav', 'unfav', 'hide', 'unhide', 'sub_set', 'sub_del', 'delete_nodes' ])
		ok(used.has(m), 'uses ' + m);
});

// ---------- runner ----------
async function run(viewSrc, commonSrc, quiet) {
	let pass = 0, fail = 0;
	const failed = [];
	for (const x of T) {
		const t = setup(viewSrc, commonSrc);
		try {
			await x.fn(t);
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
	{ name: 'cards rebuilt on every poll', from: "if (C) self.updateCard(C, it); else C = self.cards[it.key] = self.makeCard(it);", to: "C = self.cards[it.key] = self.makeCard(it);", expect: [ 'a poll updates cell by cell: same elements, focus kept, no reordering; gone and new cards' ] },
	{ name: 'cards moved even when in place', from: "if (cur === el) return;\n", to: "if (cur === el) parent.removeChild(el);\n", expect: [ 'a poll updates cell by cell: same elements, focus kept, no reordering; gone and new cards' ] },
	{ name: 'raw LuCI E (strings into innerHTML)', from: "var E = common.E;", to: "var E0 = common.E;", expect: [ 'groups by source, state words of every kind of card, no innerHTML' ] },
	{ name: 'excluded nodes not recognised', from: "var excl = arr(st && st.auto_exclude_ids);", to: "var excl = [];", expect: [ 'groups by source, state words of every kind of card, no innerHTML' ] },
	{ name: 'a stale member list counts (the old formula)', from: "var members = arr(st && st.auto_member_ids).filter(function(i) { return has(ids, i); });", to: "var members = arr(st && st.auto_member_ids);", expect: [ 'automatic choice by the engine\'s rule: a stale member list excludes nobody, "favourites only", the dialog' ] },
	{ name: '"favourites only" ignored', from: "if (((st && st.settings) || {}).favorites_only) {", to: "if (false) {", expect: [ 'automatic choice by the engine\'s rule: a stale member list excludes nobody, "favourites only", the dialog' ] },
	{ name: 'the card computes its own "excluded"', from: "var why = autoPool(st).why(n.id);", to: "var why = (arr(st.auto_member_ids).length && arr(st.auto_member_ids).indexOf(n.id) < 0) ? 'not_member' : autoPool(st).why(n.id);", expect: [ 'automatic choice by the engine\'s rule: a stale member list excludes nobody, "favourites only", the dialog' ] },
	{ name: 'exclusion written as "everyone but"', from: "common.call('auto_exclude', { id: idOf(n) }", to: "common.call('set_auto_members', { members: autoPool(this.st).participants.filter(function(i) { return i !== n.id; }) }", expect: [ '"⋯" menu: favourites, hide and return, the automatic choice; the menu follows the node', 'only the 2.0 methods: no legacy call, every method known to common.js, no own rpc' ] },
	{ name: 'a hidden favourite shown twice', from: "return f && f.id && !f.in_pool && !hiddenIds[f.id];", to: "return f && f.id && !f.in_pool;", expect: [ 'a hidden favourite is one card (in "Hidden"), not also "not among the nodes"' ] },
	{ name: 'already_running taken as our start', from: "if (r && r.code === 'already_running') throw new common.Error('probe_busy', 'probe_source', r);", to: "", expect: [ 'picking nodes shows only the result of OUR probe; a long list says it is cut' ] },
	{ name: 'the probe job not compared', from: "if (job != null && (!res || res.job !== job))", to: "if (false)", expect: [ 'picking nodes shows only the result of OUR probe; a long list says it is cut' ] },
	{ name: 'a cut list not said', from: "var capped = !!(res && res.capped && res.total > nodes.length);", to: "var capped = false;", expect: [ 'picking nodes shows only the result of OUR probe; a long list says it is cut' ] },
	{ name: 'the first checked site named for a strict check over several', from: "if (s.length > 1) return", to: "if (false) return", expect: [ 'groups by source, state words of every kind of card, no innerHTML' ] },
	{ name: 'deferred node can be connected', from: "primary: n.deferred ? { label: _('Connect'), disabled: true }", to: "primary: false ? { label: _('Connect'), disabled: true }", expect: [ 'groups by source, state words of every kind of card, no innerHTML' ] },
	{ name: 'add ignores the checkboxes', from: "if (!row.cb || !row.cb.checked) return;", to: "if (!row.cb) return;", expect: [ '"+ Add": a chip and a reason per line, add sends the checked lines, the result names the error lines' ] },
	{ name: 'result leaves out the lines the check refused', from: "else if (it.status !== 'add') errLines.push(it.line);", to: "", expect: [ '"+ Add": a chip and a reason per line, add sends the checked lines, the result names the error lines' ] },
	{ name: '"nothing added" taken as a failure', from: "if (e instanceof common.Error && e.code === 'nothing_added' && e.reply) return take(e.reply);", to: "", expect: [ '"+ Add": everything fine closes the dialog with the result; "nothing added" is a result, not an error' ] },
	{ name: 'dialog closes even with errors', from: "if (!errLines.length) {\n\t\t\tui.hideModal();", to: "if (true) {\n\t\t\tui.hideModal();", expect: [ '"+ Add": a chip and a reason per line, add sends the checked lines, the result names the error lines' ] },
	{ name: 'picked nodes of an address ignored', from: "if (row.mode && row.mode.value === 'pick') {", to: "if (false) {", expect: [ '"+ Add" a subscription address: pick nodes -> add with mode pick and the picked ids' ] },
	{ name: 'AmneziaWG settings appended to links', from: "D.ta.value = (conf || !had) ? t :", to: "D.ta.value = (!had) ? t :", expect: [ '"+ Add" from a file: links are added to the field, AmneziaWG settings replace it, a huge file is refused' ] },
	{ name: 'the chosen node only offers Connect again', from: "return n.preferred ? this.doAuto() : this.doConnect(idOf(n), n.tag || n.id);", to: "return this.doConnect(idOf(n), n.tag || n.id);", expect: [ '"Connect" is the soft choice; the chosen node offers "Back to automatic choice"' ] },
	{ name: 'Connect through the legacy select', from: "common.call('connect', { id: id }", to: "common.call('select', { id: id }", expect: [ '"Connect" is the soft choice; the chosen node offers "Back to automatic choice"', 'only the 2.0 methods: no legacy call, every method known to common.js, no own rpc' ] },
	{ name: 'menu never rebuilt', from: "if (rec.menuSig === sig) return;", to: "if (rec.menuSig != null) return;", expect: [ '"⋯" menu: favourites, hide and return, the automatic choice; the menu follows the node' ] },
	{ name: 'Return hides again', from: "common.call('unhide', { id: id }", to: "common.call('hide', { id: id }", expect: [ '"⋯" menu: favourites, hide and return, the automatic choice; the menu follows the node' ] },
	{ name: 'bulk panel always shown', from: "this.bulk.hidden = keys.length === 0;", to: "this.bulk.hidden = false;", expect: [ 'bulk panel only with a selection; bulk delete asks first and is one call', 'groups by source, state words of every kind of card, no innerHTML' ] },
	{ name: 'delete without asking', from: "\t\t\tif (!yes) return;\n\t\t\tvar ids = nodes.map(idOf)", to: "\t\t\tvar ids = nodes.map(idOf)", expect: [ 'bulk panel only with a selection; bulk delete asks first and is one call' ] },
	{ name: 'lines numbered without dropping the blank lines on top', from: "return t.replace(/^", to: "return t.replace(/^$^", expect: [ '"+ Add": a chip and a reason per line, add sends the checked lines, the result names the error lines', '"+ Add" a subscription address: pick nodes -> add with mode pick and the picked ids' ] },
	{ name: 'request limit counted in characters', from: "if (requestBytes(text) > MAX_TEXT) {", to: "if (text.length > MAX_TEXT) {", expect: [ '"+ Add" from a file: links are added to the field, AmneziaWG settings replace it, a huge file is refused' ] },
	{ name: 'field error of analyze not shown', from: "}, function(e) { common.markFieldErrors(D.box, e); });", to: "}, noop);", expect: [ '"+ Add": everything fine closes the dialog with the result; "nothing added" is a result, not an error' ] },
	{ name: 'speed result not shown', from: "self.speed[n.id] = res.mbps;", to: "", expect: [ 'speed test: the card says it is testing, the result is a badge; a failure is said' ] },
	{ name: 'service off not said', from: "var b = !st.enabled ?", to: "var b = false ?", expect: [ 'service off: a banner; nothing at all: the empty state with "+ Add"' ] }
];

(async function main() {
	const viewSrc = fs.readFileSync(VIEW_PATH, 'utf8');
	const commonSrc = fs.readFileSync(COMMON_PATH, 'utf8');
	if (process.argv.includes('--negative')) {
		const base = await run(viewSrc, commonSrc, true);
		if (base.fail) { console.log('NODES-NEG: baseline not green: ' + base.failed.join('; ')); console.log('NODES-NEG: passed=0 failed=1'); process.exit(1); }
		let p = 0, f = 0;
		for (const m of MUTATIONS) {
			if (!viewSrc.includes(m.from)) { f++; console.log('FAIL - [' + m.name + '] mutation anchor not found in nodes.js'); continue; }
			const r = await run(viewSrc.replace(m.from, m.to), commonSrc, true);
			const missing = m.expect.filter(x => !r.failed.includes(x));
			if (missing.length || !r.fail) { f++; console.log('FAIL - [' + m.name + '] stayed green: ' + (missing.join('; ') || '(nothing failed)')); }
			else { p++; console.log('ok   - [' + m.name + '] -> red: ' + r.failed.join('; ')); }
		}
		console.log('NODES-NEG: passed=' + p + ' failed=' + f);
		process.exit(f || !p ? 1 : 0);
	}
	const r = await run(viewSrc, commonSrc, false);
	console.log('NODES: passed=' + r.pass + ' failed=' + r.fail + ' checked=' + CHECKS);
	process.exit(r.fail || !r.pass || !CHECKS ? 1 : 0);
})();
