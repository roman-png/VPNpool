#!/usr/bin/env node
// Behaviour tests of the "Overview" tab (resources/view/vpnpool/dashboard.js) outside the browser:
// the real view and the real common.js run on the fakes of ui-fake.js (LuCI globals + a DOM that
// records every innerHTML write and drops the focus of an element that is moved or removed).
// The backend is a table of fake rpcd replies (the status.uc shape); every call is logged.
//   node stand/tests/ui-overview.test.js            -> "OVERVIEW: passed=N failed=M checked=K", exit 1 on failure
//   node stand/tests/ui-overview.test.js --negative -> break dashboard.js / common.js in memory, one
//                                                      mutation at a time; each must turn its tests red
//                                                      ("OVERVIEW-NEG: passed=N failed=M")
// What is judged: the "Now" card (the state in words for every daemon state, the node, the exit IP
// and country, the delay, the speed, automatic choice / chosen by you + "Back to automatic choice");
// the alerts in words; the subscription cards; the traffic per device; the wizard of an empty
// install (-> Nodes "+ Add"); on/off waits for the daemon instead of a timer; a poll updates in
// place (same elements, focus kept); only the 2.0 methods are used.
'use strict';
const fs = require('fs');
const path = require('path');
const { makeEnv, load } = require('./ui-fake.js');

const REPO = process.env.REPO_DIR || path.resolve(__dirname, '../..');
const RES = path.join(REPO, 'package/luci-app-vpnpool/files/www/luci-static/resources');
const VIEW_PATH = path.join(RES, 'view/vpnpool/dashboard.js');
const COMMON_PATH = path.join(RES, 'vpnpool/common.js');
const XSS = '<img src=x onerror="window.pwned=1">';

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', { value: function(...a) {
		let i = 0;
		return this.replace(/%([sd%])/g, (m, t) => t === '%' ? '%' : (t === 'd' ? String(parseInt(a[i++], 10)) : String(a[i++])));
	} });
}

// ---------- fixture: a status reply of the 2.0 backend (status.uc) ----------
const ID = { A: 'aaaaaaaaaaa1', B: 'bbbbbbbbbbb2', C: 'ccccccccccc3', K: 'ddddddddddd4', W: 'fffffffffff6', S: '0000000000c1' };
const NOW = 1000000;   // ms of the fake clock; seconds below
const SEC = Math.floor(NOW / 1000);
const GB = 1073741824;
function fixture(over) {
	const st = {
		ok: true, code: 'ok', daemon: 'n/a', enabled: true, running: true, routing: true, paused: false,
		mode: 'selective', active: 'auto', auto_now: 'Alpha', preferred: null,
		tunnel: { state: 'up', since: SEC - 300 },
		exit: { ip: '198.51.100.7', country: 'DE', node: 'Alpha', at: SEC - 60 },
		settings: { check_services: 'www.youtube.com', killswitch: false },
		traffic: { up_total: 1000, down_total: 5000, connections: 3 },
		client_traffic: [
			{ ip: '192.168.1.10', host: 'laptop', down: 3 * 1048576, up: 1024, conns: 2 },
			{ ip: '192.168.1.11', host: '', down: 2048, up: 0, conns: 1 }
		],
		subscriptions: [
			{ id: 'sub_main', name: 'Main provider', enabled: true, mode: 'all', picked: 0, pick_missing: 0, in_pool: 2,
				expire: SEC + 40 * 86400 + 3600, used: 2 * GB, total: 10 * GB, updated_at: SEC - 600, result: 'ok' }
		],
		nodes: [
			{ tag: 'Alpha', id: ID.A, proto: 'vless', delay: 85, source: 'subscription', sub: 'sub_main' },
			{ tag: 'Bravo', id: ID.B, proto: 'trojan', delay: 120, source: 'subscription', sub: 'sub_main' }
		],
		favorites: [], hidden: [], unreadable: [], busy: {}, build: { ok: true, at: SEC - 700 }
	};
	if (over) over(st);
	return st;
}
const node = (st, tag) => st.nodes.find(n => n.tag === tag);

// ---------- harness ----------
let CHECKS = 0;
function eq(a, b, what) { CHECKS++; if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((what || 'value') + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b)); }
function ok(c, what) { CHECKS++; if (!c) throw new Error(what || 'assertion failed'); }

function setup(viewSrc, commonSrc) {
	const env = makeEnv();
	env.doc.documentElement.setAttribute('lang', 'en');   // country names in English, whatever the host's locale
	const common = load(commonSrc, env);
	const view = { extend(proto) { function V() {} V.prototype = proto; return V; } };
	const fn = new Function('view', 'ui', 'poll', 'dom', 'common', 'E', '_', 'N_', 'L', 'window', 'document', 'console', 'Date', viewSrc);
	const V = fn(view, env.ui, env.poll, env.dom, common, env.D.E, s => s, (n, one, many) => (n === 1 ? one : many), env.L, env.win, env.doc, env.consoleQuiet, env.DateC);
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
async function poll(t, st, ms) { t.env.handlers.status = () => st; await t.env.tick(ms || 5000); await t.env.pollFns[0](); await settle(t); }
const q = (root, sel) => root.querySelector(sel);
const text = (root, sel) => { const n = q(root, sel); return n ? n.textContent : null; };
const shown = (root, sel) => { const n = q(root, sel); return !!n && !n.hidden; };
const stateOf = root => [ text(root, '.vp-ov-state'), q(root, '.vp-ov-state').getAttribute('data-kind') ];
const alerts = root => root.querySelectorAll('.vp-ov-alert').map(a => a.querySelector('.vp-ov-alert-text').textContent);
const alertLinks = root => root.querySelectorAll('.vp-ov-alert').map(a => { const l = a.querySelector('a'); return l ? l.textContent + ' ' + l.getAttribute('href') : null; });
const toasts = (t, kind) => t.env.mc.children.filter(n => n.classes && n.classes.has('vp-toast') && (!kind || n.classes.has(kind))).map(n => n.textContent);
const click = (t, el) => t.env.D.fire(el, 'click', {});

const T = [];
function test(name, fn) { T.push({ name, fn }); }

// ---------- tests ----------
test('Now: a working VPN — state, node, exit with the country, delay, speed, automatic choice; no innerHTML', async (t) => {
	const st = fixture(s => { node(s, 'Alpha').tag = XSS; s.auto_now = XSS; s.exit.node = XSS; s.subscriptions[0].name = XSS; s.subscriptions[0].used = 9.5 * GB; s.client_traffic[0].host = XSS; });
	const root = await open(t, st);
	eq(stateOf(root), [ 'VPN works', 'ok' ], 'state in words');
	eq(text(root, '.vp-ov-detail'), 'Only the chosen sites', 'the routing mode under it');
	eq(text(root, '.vp-ov-toggle'), 'Turn the VPN off', 'toggle while on');
	eq(text(root, '.vp-ov-node'), XSS, 'the node, as text');
	eq(text(root, '.vp-ov-exit'), '198.51.100.7 · Germany', 'exit IP and the country by name');
	eq(text(root, '.vp-ov-delay'), '85 ms', 'delay of the active node');
	ok(!shown(root, '.vp-ov-speed'), 'no speed before the second poll (positive control of the next check)');
	eq(alerts(root), [ 'The subscription ' + XSS + ' has little traffic left: 512.0 MB of 10.00 GB.' ], 'a foreign name in an alert, as text');
	eq(text(root, '.vp-ov-sub-name'), XSS, 'a foreign subscription name, as text');
	eq(text(root, '.vp-dev-name'), XSS, 'a foreign device name, as text');
	eq(text(root, '.vp-ov-who-text'), 'Automatic choice: the best working node is used.', 'automatic choice');
	ok(!shown(root, '.vp-ov-auto'), 'no "Back to automatic choice" without a choice');
	await poll(t, fixture(s => { node(s, 'Alpha').tag = XSS; s.auto_now = XSS; s.exit.node = XSS; s.traffic = { up_total: 1000 + 5120, down_total: 5000 + 10240, connections: 4 }; }));
	eq(text(root, '.vp-ov-speed'), '↓ 2.0 KB/s ↑ 1.0 KB/s · connections: 4', 'speed = the change of the totals over 5 s');
	eq(alerts(root), [], 'nothing to warn about');
	ok(!shown(root, '.vp-empty'), 'no wizard with nodes');
	eq(t.env.doc.unsafe, [], 'innerHTML writes');
});

test('state in words for every state the daemon reports', async (t) => {
	const root = await open(t, fixture());
	const cases = [
		[ s => { s.enabled = false; s.running = false; s.routing = false; s.tunnel = null; s.exit = null; }, 'VPN is off', '', 'The internet goes directly, without the VPN.' ],
		[ s => { s.running = false; s.routing = false; s.tunnel = null; }, 'VPN is on, but the service is not running', 'error', 'Turn the VPN off and on again; if it repeats, open Diagnostics.' ],
		[ s => { s.running = false; s.paused = true; s.routing = false; s.tunnel = null; }, 'VPN is on, but the service is not running', 'error', 'Press "Turn the VPN on"; if it repeats, open Diagnostics.' ],
		[ s => { s.paused = true; s.routing = false; }, 'Paused', 'warn', 'Paused from Telegram: the internet goes directly, without the VPN. "Turn the VPN on" resumes it.' ],
		[ s => { s.tunnel = { state: 'down', since: 1 }; }, 'No node works', 'error', 'If no node works again in a moment, what should go through the VPN goes directly.' ],
		[ s => { s.tunnel = { state: 'wan_down', since: 1 }; s.routing = false; }, 'The router has no internet', 'error', 'Check the cable or the internet provider.' ],
		[ s => { s.tunnel = { state: 'wan_down', since: 1 }; s.settings.killswitch = true; }, 'The router has no internet', 'error', 'What should go through the VPN is blocked until the internet is back.' ],
		[ s => { s.tunnel = { state: 'down', since: 1 }; s.routing = false; }, 'No node works', 'error', 'What should go through the VPN goes directly until a node works.' ],
		[ s => { s.tunnel = { state: 'down', since: 1 }; s.settings.killswitch = true; }, 'No node works', 'error', 'What should go through the VPN is blocked until a node works (protection is on).' ],
		[ s => { s.routing = false; }, 'The VPN works, but the traffic does not go through it', 'error', null ],
		[ s => { s.mode = 'exclude'; }, 'VPN works', 'ok', 'Everything except the chosen sites' ],
		[ s => { s.tunnel = { state: 'starting', since: 1 }; s.routing = false; }, 'Starting…', '', 'Looking for a working node.' ],
		[ s => { s.tunnel = null; }, 'VPN is on', 'ok', null ],
		[ s => { s.migration = { state: 'failed' }; s.running = false; }, 'Not started: the settings of the previous version could not be converted', 'error', null ]
	];
	let n = 0;
	for (const [ over, words, kind, detail ] of cases) {
		await poll(t, fixture(over));
		eq(stateOf(root), [ words, kind ], 'state of case ' + n);
		if (detail != null) eq(text(root, '.vp-ov-detail'), detail, 'detail of case ' + n);
		n++;
	}
	eq(n, 14, 'positive control: every case ran');
	// the words name the button that is on the screen: a pause left from before a restart of the service
	await poll(t, fixture(s => { s.running = false; s.paused = true; s.routing = false; s.tunnel = null; }));
	eq(text(root, '.vp-ov-toggle'), 'Turn the VPN on', 'the button named in the words is there');
	await poll(t, fixture(s => { s.running = false; s.routing = false; s.tunnel = null; }));
	eq(text(root, '.vp-ov-toggle'), 'Turn the VPN off', 'positive control: without the pause the words say off and on, the button is off');
	await poll(t, fixture(s => { s.enabled = false; s.running = false; s.tunnel = null; s.exit = null; }));
	ok(!shown(root, '.vp-ov-facts'), 'off: no node / exit / speed rows');
	eq(text(root, '.vp-ov-toggle'), 'Turn the VPN on', 'toggle while off');
	ok(!shown(root, '.vp-ov-who'), 'off: no "automatic choice" line');
});

test('exit: only while the tunnel works; "being checked" before the lookup; a failed lookup is said', async (t) => {
	const root = await open(t, fixture(s => { s.exit = null; }));
	eq(text(root, '.vp-ov-exit'), 'being checked…', 'tunnel up, no lookup yet');
	// the exit of the last lookup is still in the reply (exit.json outlives a dead tunnel)
	for (const state of [ 'down', 'wan_down', 'starting' ]) {
		await poll(t, fixture(s => { s.tunnel = { state, since: 1 }; }));
		ok(t.env.handlers.status().exit && t.env.handlers.status().exit.ip, 'positive control: the reply has an exit (' + state + ')');
		ok(shown(root, '.vp-ov-node'), 'positive control: the node row is there (' + state + ')');
		ok(!shown(root, '.vp-ov-exit'), 'no exit row while the tunnel is ' + state);
	}
	await poll(t, fixture(s => { s.exit = { ok: false, ip: null, country: null, node: 'Alpha', at: SEC - 30 }; }));
	eq(text(root, '.vp-ov-exit'), 'could not be determined: the address check services did not answer', 'a lookup that found nothing');
	await poll(t, fixture(s => { s.exit = { ok: true, ip: '2001:db8::1', country: null, node: 'Alpha' }; }));
	eq(text(root, '.vp-ov-exit'), '2001:db8::1', 'an address without a country');
});

test('a pause from Telegram: "Turn the VPN on" ends it; no node / exit / choice rows', async (t) => {
	const root = await open(t, fixture(s => { s.paused = true; s.routing = false; s.preferred = { id: ID.B, tag: 'Bravo', in_pool: true }; }));
	eq(stateOf(root), [ 'Paused', 'warn' ], 'positive control: paused');
	eq(text(root, '.vp-ov-detail'), 'Paused from Telegram: the internet goes directly, without the VPN. "Turn the VPN on" resumes it.', 'the words name the real button');
	eq(text(root, '.vp-ov-toggle'), 'Turn the VPN on', 'the button turns the VPN on');
	ok(!shown(root, '.vp-ov-facts') && !shown(root, '.vp-ov-who') && !shown(root, '.vp-ov-auto'), 'no node / exit / speed / choice rows while paused');
	t.env.handlers.set_enabled = () => ({ ok: true, code: 'on', daemon: 'n/a' });
	let polls = 0;
	t.env.handlers.status = () => (++polls < 3) ? fixture(s => { s.paused = true; s.routing = false; }) : fixture();
	click(t, q(root, '.vp-ov-toggle')); await settle(t);
	eq(t.calls('set_enabled'), [ { enabled: true } ], 'set_enabled on (ends the pause)');
	eq(toasts(t, 'info'), [ 'Turning the VPN on…' ], 'waits while still paused');
	await t.env.tick(6000);
	eq(toasts(t, 'info'), [ 'VPN is on.' ], 'done once the pause is over');
	eq(text(root, '.vp-ov-toggle'), 'Turn the VPN off', 'the button follows');
});

test('"Connected to X" and "Back to automatic choice"; a chosen node that is gone', async (t) => {
	const root = await open(t, fixture(s => { s.preferred = { id: ID.B, tag: 'Bravo', in_pool: true }; s.active = 'Bravo'; }));
	eq(text(root, '.vp-ov-who-text'), 'Connected to Bravo: chosen by you. If it stops working, the automatic choice takes over until it is back.', 'chosen by you');
	eq(text(root, '.vp-ov-node'), 'Bravo', 'the node of the selector');
	eq(text(root, '.vp-ov-delay'), '120 ms', 'its delay');
	ok(shown(root, '.vp-ov-auto'), 'the button is there');
	t.env.handlers.auto_select = () => ({ ok: true, code: 'ok', daemon: 'signalled' });
	click(t, q(root, '.vp-ov-auto')); await settle(t);
	eq(t.calls('auto_select'), [ {} ], 'auto_select called');
	eq(toasts(t, 'info'), [ 'Back to automatic choice.' ], 'said');
	await poll(t, fixture(s => { s.preferred = { id: ID.S, tag: 'Gone one', in_pool: false }; }));
	eq(text(root, '.vp-ov-who-text'), 'Chosen by you: Gone one. It is not among the nodes now, so the automatic choice works.', 'chosen but gone');
	ok(shown(root, '.vp-ov-auto'), 'can go back to automatic choice');
});

test('alerts in words: failing nodes, engine, set aside, unreadable files, subscriptions, the last update', async (t) => {
	const root = await open(t, fixture(s => {
		s.nodes.push({ tag: 'Dead1', id: ID.C, proto: 'vless', dead: true, kept: false, source: 'subscription', sub: 'sub_main' });
		s.nodes.push({ tag: 'Kept', id: ID.K, proto: 'vless', dead: true, kept: true, source: 'manual' });
		node(s, 'Bravo').dead = true;
		s.nodes.push({ tag: 'Home AWG', id: ID.W, proto: 'awg', deferred: true, reason: 'engine_missing', source: 'awg' });
		s.nodes.push({ tag: 'Broken', id: ID.S, proto: 'vless', deferred: true, reason: 'start_failed', source: 'manual' });
		s.unreadable = [ { file: 'a.conf', reason: 'awg_no_peer' }, { file: 'b.conf', reason: 'awg_bad_value' } ];
		s.subscriptions.push({ id: 'sub_soon', name: 'Soon', enabled: true, mode: 'all', in_pool: 0, expire: SEC + 5 * 86400 + 3600, used: 9.5 * GB, total: 10 * GB, result: 'failed' });
		s.subscriptions.push({ id: 'sub_old', name: 'Old', enabled: true, mode: 'all', in_pool: 0, expire: SEC - 86400 });
		s.subscriptions.push({ id: 'sub_off', name: 'Off one', enabled: false, mode: 'all', in_pool: 0, expire: SEC + 86400, result: 'failed' });
		s.build = { ok: false, error: 'check_failed', at: SEC - 10 };
	}));
	const soonDate = new Date((SEC + 5 * 86400 + 3600) * 1000).toLocaleDateString();
	eq(alerts(root), [
		'The last update of the VPN settings failed; the previous ones keep working.',
		'2 nodes do not open www.youtube.com: they are left out of the automatic choice.',
		'1 AmneziaWG node waits for the AmneziaWG engine: it starts working once the engine is installed.',
		'1 node was set aside: the VPN engine could not start with it.',
		'2 AmneziaWG settings files could not be read.',
		'The subscription Soon expires in 5 days (' + soonDate + ').',
		'The subscription Soon has little traffic left: 512.0 MB of 10.00 GB.',
		'The subscription Soon could not be updated the last time.',
		'The subscription Old has expired: its nodes may stop working.'
	], 'every alert, in order (a kept node and a turned-off subscription do not warn)');
	eq(alertLinks(root).slice(0, 3), [ 'Diagnostics /cgi-bin/luci/admin/services/vpnpool/diagnostics', 'Nodes /cgi-bin/luci/admin/services/vpnpool/nodes',
		'How to install it /cgi-bin/luci/admin/services/vpnpool/diagnostics' ], 'each alert leads where it is fixed');
	eq(root.querySelectorAll('.vp-ov-alert').map(a => a.getAttribute('data-kind')), [ 'error', 'warn', 'warn', 'warn', 'warn', 'warn', 'warn', 'error', 'error' ], 'error and warning look');
	await poll(t, fixture(s => { node(s, 'Bravo').dead = true; s.settings.check_services = 'www.youtube.com chat.example'; }));
	eq(alerts(root), [ '1 node fails the check of the sites (www.youtube.com, chat.example): it is left out of the automatic choice.' ], 'several sites: the strict check over all of them');
	await poll(t, fixture(s => { s.nodes = []; s.build = { ok: false, error: 'no_nodes', at: SEC }; }));
	eq(alerts(root), [ 'There is not a single node: the subscriptions could not be downloaded or have no nodes.' ], 'a subscription without nodes');
	await poll(t, fixture(s => { s.nodes = [ { tag: 'Home AWG', id: ID.W, proto: 'awg', deferred: true, reason: 'engine_no_awg', source: 'awg' } ]; }));
	eq(alerts(root), [ '1 AmneziaWG node waits for the AmneziaWG engine: it starts working once the engine is installed.',
		'No node can work right now: all nodes are waiting (the reason is shown next to each node).' ], 'only waiting nodes');
	// which site: the node checker's own answer (as on the Nodes cards), not the settings
	await poll(t, fixture(s => { node(s, 'Bravo').dead = true; node(s, 'Bravo').check = { fails: 2, at: SEC - 60, failed: [ 'chat.example' ] }; }));
	eq(alerts(root), [ '1 node does not open chat.example: it is left out of the automatic choice.' ], 'the site of the real check');
	// mixed: one failing node named its sites, the other has no check data (its card says the sites of the settings)
	await poll(t, fixture(s => { node(s, 'Bravo').dead = true; node(s, 'Bravo').check = { fails: 2, at: SEC - 60, failed: [ 'chat.example' ] }; node(s, 'Alpha').dead = true; }));
	ok(!node(t.env.handlers.status(), 'Alpha').check, 'positive control: Alpha has no check data');
	eq(alerts(root), [ '2 nodes fail the check of the sites (www.youtube.com, chat.example): they are left out of the automatic choice.' ], 'node by node: every site the alert names is on the card of its node');
	eq(t.common.failedSites(t.env.handlers.status(), [ node(t.env.handlers.status(), 'Alpha') ]).sites, [ 'www.youtube.com' ], 'Alpha alone (its card): the settings');
	await poll(t, fixture(s => { node(s, 'Bravo').dead = true; s.settings.check_services = ''; }));
	eq(alerts(root), [ '1 node fails the connection check: it is left out of the automatic choice.' ], 'no sites set and no check data: the general words');
	await poll(t, fixture(s => { s.subscriptions[0].expire = SEC + 3600; }));
	eq(alerts(root), [ 'The subscription Main provider expires today (' + new Date((SEC + 3600) * 1000).toLocaleDateString() + ').' ], 'the last day: "today", not "in 0 days"');
});

test('subscription cards: expiry, traffic left with a bar, "updated", nodes in use', async (t) => {
	const root = await open(t, fixture(s => {
		s.subscriptions.push({ id: 'sub_pick', name: 'Picked', enabled: false, mode: 'pick', picked: 3, pick_missing: 1, in_pool: 1, updated_at: SEC - 7200, result: 'ok' });
	}));
	const cards = root.querySelectorAll('.vp-ov-sub');
	eq(cards.length, 2, 'positive control: a card per subscription');
	eq(cards.map(c => c.querySelector('.vp-ov-sub-name').textContent), [ 'Main provider', 'Picked' ], 'names');
	eq(cards.map(c => c.querySelector('.vp-ov-sub-count').textContent), [ '2 nodes in use', '1 node in use' ], 'nodes in use');
	const f0 = cards[0].querySelector('.vp-ov-sub-facts').textContent;
	ok(/^every node · valid until .+ \(40 days left\) · 8\.00 GB of 10\.00 GB left · updated 10 min ago$/.test(f0), 'main: ' + f0);
	eq(cards[0].querySelector('.vp-ov-bar').getAttribute('aria-label'), 'Traffic left: 80%', 'the bar of the traffic left');
	eq(cards[1].querySelector('.vp-ov-sub-facts').textContent, 'turned off · picked nodes: 3 · updated 2 h ago · picked nodes gone from it: 1', 'picked, off');
	ok(!cards[1].querySelector('.vp-ov-bar'), 'no bar without a quota');
	await poll(t, fixture(s => { s.subscriptions = []; }));
	ok(!shown(root, '.vp-ov-subs-sec'), 'no subscriptions: the section is hidden');
});

test('traffic by device: the name or the address, ↓↑, connections; nothing while off', async (t) => {
	const root = await open(t, fixture());
	const rows = root.querySelectorAll('.vp-ov-dev');
	eq(rows.length, 2, 'positive control: a row per device');
	eq(rows.map(r => r.textContent), [ 'laptop192.168.1.10↓ 3.0 MB ↑ 1.0 KB2 connections', '192.168.1.11↓ 2.0 KB ↑ 0 B1 connection' ], 'rows');
	await poll(t, fixture(s => { s.client_traffic = []; }));
	eq(text(root, '.vp-ov-devices'), 'No device uses the internet through the router right now.', 'no traffic');
	await poll(t, fixture(s => { s.enabled = false; s.running = false; }));
	eq(text(root, '.vp-ov-devices'), 'The VPN is not running: there is no traffic to show.', 'off');
});

test('nothing added yet: the wizard leads to Nodes and its "+ Add"', async (t) => {
	const root = await open(t, fixture(s => { s.nodes = []; s.subscriptions = []; s.running = true; s.tunnel = { state: 'starting', since: 1 }; s.routing = false;
		s.build = { ok: false, error: 'no_nodes', at: SEC - 5 }; }));   // the daemon's build of an empty install fails
	ok(shown(root, '.vp-empty'), 'the wizard is shown');
	eq(text(root, '.vp-empty-title'), 'Add a subscription or a node', 'its title');
	eq(q(root, '.vp-ov-add').getAttribute('href'), '/cgi-bin/luci/admin/services/vpnpool/nodes#add', '"+ Add" opens the dialog on Nodes');
	eq(q(root, '.vp-empty').querySelectorAll('a').map(a => a.textContent), [ '+ Add', 'Open Nodes' ], 'both ways');
	eq(alerts(root), [], 'no alerts on an empty install');
	ok(!shown(root, '.vp-ov-subs-sec'), 'no subscription section');
	await poll(t, fixture());
	ok(!shown(root, '.vp-empty'), 'gone once there is a node');
});

test('on/off: set_enabled with the opposite, waits for the daemon, then says it; a slow start is said', async (t) => {
	const root = await open(t, fixture(s => { s.enabled = false; s.running = false; s.routing = false; s.tunnel = null; }));
	t.env.handlers.set_enabled = () => ({ ok: true, code: 'on', daemon: 'n/a' });
	let polls = 0;
	t.env.handlers.status = () => (++polls < 4) ? fixture(s => { s.running = false; s.routing = false; s.tunnel = null; }) : fixture();
	click(t, q(root, '.vp-ov-toggle')); await settle(t);
	eq(t.calls('set_enabled'), [ { enabled: true } ], 'turn on');
	eq(toasts(t, 'info'), [ 'Turning the VPN on…' ], 'said while waiting (no "done" before the daemon runs)');
	await t.env.tick(3000);
	ok(polls >= 2 && polls < 4, 'positive control: still waiting after ' + polls + ' polls');
	eq(toasts(t, 'info'), [ 'Turning the VPN on…' ], 'still waiting');
	await t.env.tick(5000);
	eq(toasts(t, 'info'), [ 'VPN is on.' ], 'done once the daemon runs');
	eq(stateOf(root), [ 'VPN works', 'ok' ], 'the state follows');
	// a daemon that does not start in time
	t.env.handlers.status = () => fixture(s => { s.running = false; s.routing = false; s.tunnel = null; });
	t.env.handlers.set_enabled = () => ({ ok: true, code: 'off', daemon: 'n/a' });
	click(t, q(root, '.vp-ov-toggle')); await t.env.tick(1000);
	eq(t.calls('set_enabled')[1], { enabled: false }, 'the opposite of the last state');
	t.env.handlers.status = () => fixture(s => { s.enabled = true; });
	t.env.handlers.set_enabled = () => ({ ok: true, code: 'on', daemon: 'n/a' });
	await t.env.tick(25000);
	ok(toasts(t, 'warning').some(x => /has not stopped yet/.test(x)), 'a stop that did not happen is said: ' + JSON.stringify(toasts(t, 'warning')));
});

test('a poll updates in place: the same elements, the focus stays, unchanged lists are not rebuilt', async (t) => {
	const st = fixture(s => { node(s, 'Bravo').dead = true; });
	const root = await open(t, st);
	const btn = q(root, '.vp-ov-toggle'), al = q(root, '.vp-ov-alert'), link = al.querySelector('a'), dev = q(root, '.vp-ov-dev'), sub = q(root, '.vp-ov-sub');
	ok(al && dev && sub, 'positive control: an alert, a device, a subscription');
	link.focus();
	await poll(t, fixture(s => { node(s, 'Bravo').dead = true; node(s, 'Alpha').delay = 99; }));
	ok(q(root, '.vp-ov-alert') === al, 'the same alert'); ok(q(root, '.vp-ov-dev') === dev, 'the same device row'); ok(q(root, '.vp-ov-sub') === sub, 'the same subscription card');
	ok(t.env.doc.activeElement === link, 'the focus stays on the alert link');
	ok(q(root, '.vp-ov-toggle') === btn, 'the same toggle');
	eq(text(root, '.vp-ov-delay'), '99 ms', 'the delay updated in place');
	await poll(t, fixture());
	eq(alerts(root), [], 'a fixed problem leaves');
});

test('only the 2.0 methods: no legacy call, no own rpc, no own dictionary', async (t) => {
	const src = t.viewSrc;
	const used = new Set([ ...src.matchAll(/common\.(?:call|waitFor)\('([a-z_]+)'/g) ].map(m => m[1]));
	ok(used.size >= 3, 'positive control: methods found ' + [ ...used ].join(','));
	eq([ ...used ].filter(m => [ 'status', 'set_enabled', 'auto_select' ].indexOf(m) < 0), [], 'methods other than status / set_enabled / auto_select');
	ok(!/rpc\.declare|'require rpc'/.test(src), 'no own rpc.declare');
	ok(!/vpnpool\.i18n/.test(src), 'no own dictionary (vpnpool.i18n)');
	ok(!/\bconfirm\(|setTimeout\(/.test(src.replace(/^\s*\/\/.*$/mg, '')), 'no confirm(), no blind timers');
	for (const m of used) ok(t.common.METHODS[m] && !t.common.METHODS[m].legacy, 'known to common.js: ' + m);
});

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

const T_NOW = 'Now: a working VPN — state, node, exit with the country, delay, speed, automatic choice; no innerHTML';
const T_STATE = 'state in words for every state the daemon reports';
const T_EXIT = 'exit: only while the tunnel works; "being checked" before the lookup; a failed lookup is said';
const T_PAUSE = 'a pause from Telegram: "Turn the VPN on" ends it; no node / exit / choice rows';
const T_PREF = '"Connected to X" and "Back to automatic choice"; a chosen node that is gone';
const T_ALERT = 'alerts in words: failing nodes, engine, set aside, unreadable files, subscriptions, the last update';
const T_SUBS = 'subscription cards: expiry, traffic left with a bar, "updated", nodes in use';
const T_DEV = 'traffic by device: the name or the address, ↓↑, connections; nothing while off';
const T_WIZ = 'nothing added yet: the wizard leads to Nodes and its "+ Add"';
const T_TOGGLE = 'on/off: set_enabled with the opposite, waits for the daemon, then says it; a slow start is said';
const T_POLL = 'a poll updates in place: the same elements, the focus stays, unchanged lists are not rebuilt';
const T_API = 'only the 2.0 methods: no legacy call, no own rpc, no own dictionary';
const MUTATIONS = [
	{ name: 'the tunnel check ignored (a dead tunnel looks fine)', from: "if (tn === 'down') return", to: "if (false) return", expect: [ T_STATE ] },
	{ name: 'the protection not considered', from: "d: (set.killswitch && st.routing) ? _('What should go through the VPN is blocked until the internet is back.')", to: "d: false ? _('What should go through the VPN is blocked until the internet is back.')", expect: [ T_STATE ] },
	{ name: 'a working tunnel without the routes said as working', from: "if (tn === 'up') return st.routing", to: "if (tn === 'up') return true", expect: [ T_STATE ] },
	{ name: 'the exit of the daemon not shown', from: ": (ex && ex.ok !== false && ex.ip) ?", to: ": false ?", expect: [ T_NOW, T_EXIT ] },
	{ name: 'the exit shown without the tunnel check', from: "exit: !(live && tunnelUp && tag) ? null", to: "exit: !(live && tag) ? null", expect: [ T_EXIT ] },
	{ name: 'a failed lookup shown as "being checked"', from: ": (ex && ex.ok === false) ? _('could", to: ": false ? _('could", expect: [ T_EXIT ] },
	{ name: 'a pause taken as on', from: "function vpnOn(st) { return !!(st && st.enabled && !st.paused); }", to: "function vpnOn(st) { return !!(st && st.enabled); }", expect: [ T_PAUSE ] },
	{ name: 'the rows shown while paused', from: "var live = !!(on && st.running);", to: "var live = !!(st.enabled && st.running);", expect: [ T_PAUSE ] },
	{ name: 'the alert names the settings, not the check', from: "var sites = common.failedSites(st, dead).sites;", to: "var sites = common.checkSites(st);", expect: [ T_ALERT ] },
	{ name: '"(connection)" in brackets again', from: ": N_(dead.length, '%d node fails the connection check", to: ": N_(dead.length, '%d node fails the check of the sites (connection)", expect: [ T_ALERT ] },
	{ name: 'common: the last day as "in 0 days"', file: 'common', from: "else if (days === 0) out.push(", to: "else if (false) out.push(", expect: [ T_ALERT ] },
	{ name: 'common: the sites of the check ignored', file: 'common', from: "c.failed.filter(Boolean).length) c.failed.forEach(add);", to: "false) c.failed.forEach(add);", expect: [ T_ALERT ] },
	{ name: 'common: a node without check data left out (only the nodes that named sites)', file: 'common', from: "else { exact = false; (conf = conf || checkSites(st)).forEach(add); }", to: "else exact = false;", expect: [ T_ALERT ] },
	{ name: 'a stopped service with a pause: the words name the missing "off" button', from: "d: st.paused ? _('Press", to: "d: false ? _('Press", expect: [ T_STATE ] },
	{ name: '"goes directly" while the routes still lead into the tunnel', from: ": (st.routing ? _('If no node works again", to: ": (false ? _('If no node works again", expect: [ T_STATE ] },
	{ name: 'the choice of the user not said', from: "if (pref && pref.id) {", to: "if (false) {", expect: [ T_PREF ] },
	{ name: 'back to automatic choice through a legacy method', from: "common.call('auto_select'", to: "common.call('set_preferred'", expect: [ T_PREF, T_API ] },
	{ name: 'kept nodes counted as failing', from: "n.dead && !n.kept && !n.deferred", to: "n.dead && !n.deferred", expect: [ T_ALERT ] },
	{ name: 'nodes waiting for the engine not said', from: "if (engine.length)", to: "if (false)", expect: [ T_ALERT ] },
	{ name: 'the alerts of the subscriptions dropped', from: "if (f.alert) out.push", to: "if (false) out.push", expect: [ T_ALERT ] },
	{ name: 'no node at all said as a failed update', from: "if (b && b.ok === false && b.error === 'no_nodes')", to: "if (false)", expect: [ T_ALERT ] },
	{ name: 'the failed update of the settings not said', from: "if (b && b.ok === false && b.error", to: "if (false && b.error", expect: [ T_ALERT ] },
	{ name: 'common: a turned-off subscription warns', file: 'common', from: "alert: (days < 7 && s.enabled) ?", to: "alert: (days < 7) ?", expect: [ T_ALERT ] },
	{ name: 'common: the quota threshold off', file: 'common', from: "var low = left <= s.total * 0.1;", to: "var low = false;", expect: [ T_ALERT ] },
	{ name: 'no bar of the traffic left', from: "if (v.total > 0) {\n\t\t\t\tvar pct", to: "if (false) {\n\t\t\t\tvar pct", expect: [ T_SUBS ] },
	{ name: 'devices shown while off', from: "var view = live ? arr(st.client_traffic)", to: "var view = true ? arr(st.client_traffic)", expect: [ T_DEV ] },
	{ name: 'the wizard never shown', from: "this.wizard.hidden = !empty;", to: "this.wizard.hidden = true;", expect: [ T_WIZ ] },
	{ name: 'alerts on an empty install', from: "this.updateAlerts(empty ? [] : alertsOf(st));", to: "this.updateAlerts(alertsOf(st));", expect: [ T_WIZ ] },
	{ name: '"done" before the daemon runs (no waiting)', from: "return target ? (vpnOn(s) && !!s.running) : (!s.enabled && !s.running);", to: "return true;", expect: [ T_TOGGLE, T_PAUSE ] },
	{ name: 'the end of a pause not waited for', from: "return target ? (vpnOn(s) && !!s.running)", to: "return target ? (!!s.enabled && !!s.running)", expect: [ T_PAUSE ] },
	{ name: 'a start that did not happen not said', from: "if (e instanceof common.Error && e.code === 'timeout')", to: "if (false)", expect: [ T_TOGGLE ] },
	{ name: 'the toggle sends the same state', from: "var target = !vpnOn(st);", to: "var target = !!st.enabled || true;", expect: [ T_TOGGLE ] },
	{ name: 'lists rebuilt on every poll', from: "if (this.sigs[key] === s) return false;", to: "", expect: [ T_POLL ] }
];

(async function main() {
	const viewSrc = fs.readFileSync(VIEW_PATH, 'utf8');
	const commonSrc = fs.readFileSync(COMMON_PATH, 'utf8');
	if (process.argv.includes('--negative')) {
		const base = await run(viewSrc, commonSrc, true);
		if (base.fail) { console.log('OVERVIEW-NEG: baseline not green: ' + base.failed.join('; ')); console.log('OVERVIEW-NEG: passed=0 failed=1'); process.exit(1); }
		let p = 0, f = 0;
		for (const m of MUTATIONS) {
			const src = m.file === 'common' ? commonSrc : viewSrc;
			if (!src.includes(m.from)) { f++; console.log('FAIL - [' + m.name + '] mutation anchor not found in ' + (m.file === 'common' ? 'common.js' : 'dashboard.js')); continue; }
			const mut = src.replace(m.from, m.to);
			const r = await run(m.file === 'common' ? viewSrc : mut, m.file === 'common' ? mut : commonSrc, true);
			const missing = m.expect.filter(x => !r.failed.includes(x));
			if (missing.length || !r.fail) { f++; console.log('FAIL - [' + m.name + '] stayed green: ' + (missing.join('; ') || '(nothing failed)')); }
			else { p++; console.log('ok   - [' + m.name + '] -> red: ' + r.failed.join('; ')); }
		}
		console.log('OVERVIEW-NEG: passed=' + p + ' failed=' + f);
		process.exit(f || !p ? 1 : 0);
	}
	const r = await run(viewSrc, commonSrc, false);
	console.log('OVERVIEW: passed=' + r.pass + ' failed=' + r.fail + ' checked=' + CHECKS);
	process.exit(r.fail || !r.pass || !CHECKS ? 1 : 0);
})();
