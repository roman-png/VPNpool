#!/usr/bin/env node
// Unit tests of the settings pages view/vpnpool/routing.js ("Routes") and settings.js
// ("Settings") with the form layer of common.js (formData / formSaver), outside the browser.
// LuCI's form.JSONMap is a small fake here (makeForm): it renders every option's widget into
// the fake DOM of ui-common.test.js (custom widgets of the pages run for real), keeps what the
// "user" typed in a store, and runs the options' validate(). Real LuCI rendering is checked on
// the stand (ui-components.sh: the pages load; the payload this test builds is accepted by the
// real set_config) and by hand in a browser (handoff of pack ui3).
//   node stand/tests/ui-pages.test.js             -> "PAGES: passed=N failed=M checked=K"
//   node stand/tests/ui-pages.test.js --negative  -> break the pages / common.js in memory, one
//                                                    mutation at a time; each must turn its
//                                                    tests red ("PAGES-NEG: passed=N failed=M")
// UI_PAGES_PAYLOAD_DIR=<dir>: also write the set_config payloads of the "every field changed"
// cases (routing.json, settings.json) for ui-components.sh to send to the real backend.
'use strict';
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const REPO = process.env.REPO_DIR || path.resolve(HERE, '../..');
const APP = path.join(REPO, 'package/luci-app-vpnpool');
const RES = path.join(APP, 'files/www/luci-static/resources');
const COMMON = path.join(RES, 'vpnpool/common.js');
const VIEWS = { routing: path.join(RES, 'view/vpnpool/routing.js'), settings: path.join(RES, 'view/vpnpool/settings.js') };
const APIUC = path.join(REPO, 'package/vpnpool/files/usr/libexec/vpnpool/api.uc');
const SECRET = '987654321:SECRETtokenValue_xyz';

// ---- the fake LuCI of ui-common.test.js (DOM, ui, rpc, timers), taken from its source
const ucSrc = fs.readFileSync(path.join(HERE, 'ui-common.test.js'), 'utf8');
const cut = ucSrc.indexOf('// ---------- backend sources');
if (cut < 0) throw new Error('ui-common.test.js: the fake LuCI block is not found');
const { makeEnv } = new Function('require', '__dirname', 'process', ucSrc.slice(0, cut).replace(/^#!.*\n/, '') + '\nreturn { makeEnv, load };')(require, HERE, process);

// LuCI String.prototype.format (%s / %d, enough here)
if (!String.prototype.format)
	String.prototype.format = function() { let i = 0; const a = arguments; return this.replace(/%[sd]/g, (m) => { const v = a[i++]; return m === '%d' ? String(parseInt(v, 10)) : String(v); }); };

// ---- set_config schema, read from api.uc (field -> kind, enum values)
function schema() {
	const s = fs.readFileSync(APIUC, 'utf8');
	const m = s.match(/const SCHEMA = \{\n([\s\S]*?)\n\};/);
	if (!m) throw new Error('api.uc: SCHEMA not found');
	const out = {};
	for (const line of m[1].split('\n')) {
		const x = line.match(/^\t([a-z0-9_]+):\s+\{(.*)\},?\s*(\/\/.*)?$/);
		if (!x) continue;
		const b = x[2];
		let kind = 'string', values = null;
		if (/\blist:/.test(b)) kind = 'array';
		else if (/c: I\(/.test(b)) kind = 'int';
		else if (/c: chk_bool\b/.test(b)) kind = 'bool';
		else if (/c: E\(/.test(b)) { kind = 'enum'; values = [ ...b.match(/E\(([^)]*)\)/)[1].matchAll(/'([^']*)'/g) ].map(q => q[1]); }
		else if (/chk_enum\(v, \[/.test(b)) { kind = 'enum'; values = [ ...b.match(/chk_enum\(v, \[([^\]]*)\]/)[1].matchAll(/'([^']*)'/g) ].map(q => q[1]); }
		const r = b.match(/c: I\(([0-9]+), ([0-9]+)\)/);
		out[x[1]] = { kind, values, range: r ? [ +r[1], +r[2] ] : null };
	}
	return out;
}
function typeProblems(settings, sch) {
	const bad = [];
	for (const [f, v] of Object.entries(settings)) {
		const d = sch[f];
		if (!d) { bad.push(f + ': not a set_config field'); continue; }
		if (d.kind === 'int' && !Number.isInteger(v)) bad.push(f + ': want a whole number, got ' + JSON.stringify(v));
		if (d.kind === 'bool' && typeof v !== 'boolean') bad.push(f + ': want true/false, got ' + JSON.stringify(v));
		if (d.kind === 'string' && typeof v !== 'string') bad.push(f + ': want text, got ' + JSON.stringify(v));
		if (d.kind === 'enum' && (typeof v !== 'string' || !d.values.includes(v))) bad.push(f + ': want one of ' + d.values.join('|') + ', got ' + JSON.stringify(v));
		if (d.kind === 'array' && !(Array.isArray(v) && v.every(x => typeof x === 'string'))) bad.push(f + ': want a list of texts, got ' + JSON.stringify(v));
	}
	return bad;
}

// ---- the fake form module (LuCI form.JSONMap and the option classes the pages use)
// Like LuCI form.js (23.05 / 24.10 / 25.12): the map's data is a CBIJSONConfig-like object
// ({data: {section: {option: value}}}); Map.load() caches every option's cfgvalue; a widget
// keeps the value it was drawn with until it is drawn again; Map.parse() WRITES the active
// options' values into the data and DELETES the hidden ones (no retain); Map.reset() draws
// again without loading. FAKE.render = 'cache' draws from the cached cfgvalue (LuCI); 'data'
// draws straight from the data (stricter: a form must survive both — the runner runs both).
const FAKE = { render: 'cache' };
function makeForm(env) {
	const D = env.D, store = new Map();
	class AbstractValue {
		constructor(map, section, option, title, description) {
			Object.assign(this, { map, section, option, title, description, deps: [], keylist: [], vallist: [], rmempty: true });
		}
		depends(k, v) { this.deps.push(typeof k === 'object' ? k : { [k]: v }); }
		value(k, v) { this.keylist.push(String(k)); this.vallist.push(v); }
		cbid(sid) { return 'cbid.json.' + sid + '.' + this.option; }
		dataValue(sid) { const s = this.map.data.data[sid]; const v = s ? s[this.option] : undefined; return v === undefined ? null : v; }
		cfgvalue(sid) {
			if (FAKE.render === 'data') return this.dataValue(sid);
			const id = this.cbid(sid);
			return this.map.cache.has(id) ? this.map.cache.get(id) : null;
		}
		defvalue(sid) { const v = this.cfgvalue(sid); return v == null ? (this.default != null ? this.default : '') : v; }
		formvalue(sid) {
			const id = this.cbid(sid);
			if (store.has(id)) return store.get(id);
			if (this.ownFormvalue) return this.ownFormvalue(sid);
			return this.map.rendered.has(id) ? this.map.rendered.get(id) : this.defvalue(sid);
		}
		getUIElement(sid) { return { getValue: () => this.formvalue(sid), setValue: (v) => store.set(this.cbid(sid), v) }; }
		renderWidget(sid) { return D.E('span', { 'class': 'fake-widget', 'data-widget-of': this.cbid(sid) }); }
		static extend(proto) {
			const P = this;
			class C extends P {}
			for (const k of Object.keys(proto)) {
				if (k === 'formvalue') C.prototype.ownFormvalue = proto.formvalue;
				else C.prototype[k] = proto[k];
			}
			return C;
		}
	}
	class Value extends AbstractValue {}
	class TextValue extends Value {}
	class ListValue extends Value {
		defvalue(sid) { const v = this.cfgvalue(sid); return (v != null && this.keylist.includes(String(v))) ? String(v) : (this.default != null ? this.default : this.keylist[0]); }
	}
	class Flag extends Value {
		constructor() { super(...arguments); this.enabled = '1'; this.disabled = '0'; }
		defvalue(sid) { const v = this.cfgvalue(sid); return (v == null ? this.default : v) === this.enabled ? this.enabled : this.disabled; }
	}
	class DummyValue extends AbstractValue { defvalue() { return null; } }
	class NamedSection {
		constructor(map, name, type, title, description) { Object.assign(this, { map, name, type, title, description, children: [] }); }
		option(Cls, name, title, description) { const o = new Cls(this.map, this, name, title, description); this.children.push(o); return o; }
	}
	class JSONMap {
		constructor(data) {
			this.data = { data: JSON.parse(JSON.stringify(data || {})) };
			this.children = []; this.root = null; this.parsed = 0; this.cache = new Map(); this.rendered = new Map();
		}
		section(Cls, name, type, title, description) { const s = new Cls(this, name, type, title, description); this.children.push(s); return s; }
		options() { const out = []; this.children.forEach(s => s.children.forEach(o => out.push([ o, s.name ]))); return out; }
		optionAt(key, sid) {
			const p = key.split('.'), name = p.length === 3 ? p[2] : key, sec = p.length === 3 ? p[1] : sid;
			const s = this.children.find(x => x.name === sec);
			const o = s && s.children.find(x => x.option === name);
			return o ? [ o, sec ] : null;
		}
		isActive(o, sid) {
			return !o.deps.length || o.deps.some(d => Object.entries(d).every(([ k, v ]) => {
				const r = this.optionAt(k, sid);
				return r && String(r[0].formvalue(r[1])) === String(v);
			}));
		}
		load() {
			this.options().forEach(([ o, sid ]) => this.cache.set(o.cbid(sid), o.dataValue(sid)));
			return Promise.resolve();
		}
		renderContents() {
			if (!this.root) this.root = D.E('div', { 'class': 'cbi-map' });
			this.root.children.forEach(c => { c.parentNode = null; }); this.root.children = [];
			this.rendered.clear();
			for (const s of this.children) {
				if (!this.data.data[s.name]) continue;   // LuCI: a NamedSection without data is not shown
				const se = D.E('div', { 'class': 'cbi-section', 'data-section': s.name });
				s.children.forEach((o, i) => {
					const fr = D.E('div', { 'class': 'cbi-value', 'data-field': o.cbid(s.name), 'data-name': o.option });
					const w = o.renderWidget(s.name, i, o.cfgvalue(s.name));
					if (!(o instanceof DummyValue) && !o.ownFormvalue) this.rendered.set(o.cbid(s.name), o.defvalue(s.name));
					if (w && w.nodeType) fr.appendChild(w);
					se.appendChild(fr);
				});
				this.root.appendChild(se);
			}
			return Promise.resolve(this.root);
		}
		// a new render = new widgets: what was typed into the old ones is gone
		render() { this.options().forEach(([ o, sid ]) => store.delete(o.cbid(sid))); return this.load().then(() => this.renderContents()); }
		reset() { this.options().forEach(([ o, sid ]) => store.delete(o.cbid(sid))); return this.renderContents(); }
		parse() {
			this.parsed++;
			for (const [ o, sid ] of this.options()) {
				if (typeof o.validate !== 'function' || !this.isActive(o, sid)) continue;
				const r = o.validate(sid, o.formvalue(sid));
				if (r !== true) return Promise.reject(new TypeError('invalid: ' + o.option + ': ' + r));
			}
			for (const [ o, sid ] of this.options()) {
				if (o instanceof DummyValue || !this.data.data[sid]) continue;
				const fv = o.formvalue(sid);
				if (this.isActive(o, sid) && !(fv == null || fv === '')) this.data.data[sid][o.option] = Array.isArray(fv) ? fv.slice() : fv;
				else if (!o.retain) delete this.data.data[sid][o.option];
			}
			return Promise.resolve();
		}
		findElement(attr, val) { return this.root ? this.root.querySelector('[' + attr + '="' + val + '"]') : null; }
		lookupOption(name, sid) {
			// LuCI: dom.content() drops the class bindings of the replaced elements but leaves their
			// data-idref, so dom.findClassInstance throws on them (luci.js data(): registry[id][key])
			if (this.root && this.root._released) throw new TypeError("Cannot read properties of undefined (reading '_class')");
			const s = this.children.find(x => x.name === sid);
			const o = s && s.children.find(x => x.option === name);
			return (o && this.findElement('data-field', o.cbid(sid))) ? [ o, sid ] : null;
		}
	}
	return { store, form: { JSONMap, NamedSection, Value, TextValue, ListValue, Flag, DummyValue, AbstractValue } };
}

// ---- one page in a fresh environment
function makePage(name, srcs, opts) {
	opts = opts || {};
	const env = makeEnv();
	// LuCI E(): properties a browser derives from attributes (value, checked, type) + click()
	const E0 = env.D.E;
	const E = function(tag, attrs, children) {
		if (Array.isArray(tag)) tag = 'div';
		const n = E0(tag, attrs, children);
		if (attrs && typeof attrs === 'object' && !Array.isArray(attrs) && !attrs.nodeType) {
			if (attrs.value != null) n.value = String(attrs.value);
			if (attrs.checked != null) n.checked = true;
			if (attrs.type != null) n.type = String(attrs.type);
		}
		n.click = () => env.D.fire(n, 'click', {});
		return n;
	};
	env.D.E = E;
	// dom.content(): the replaced elements lose their LuCI class bindings (see lookupOption)
	const content0 = env.dom.content;
	env.dom.content = function(n, c) {
		const rel = (x) => { x._released = true; (x.children || []).forEach(rel); };
		(n.children || []).forEach(rel);
		return content0.call(this, n, c);
	};
	const unload = [];
	env.win.addEventListener = (t, fn) => { if (t === 'beforeunload') unload.push(fn); };
	const logs = [];
	const cons = { warn: (...a) => logs.push(a.join(' ')), info: (...a) => logs.push(a.join(' ')), log: (...a) => logs.push(a.join(' ')), error: (...a) => logs.push(a.join(' ')) };
	const blobs = [];
	const URLx = { createObjectURL: (b) => { blobs.push(b); return 'blob:x'; }, revokeObjectURL() {} };
	const FileReaderX = function() {};
	FileReaderX.prototype.readAsArrayBuffer = function(f) { const self = this; Promise.resolve().then(() => { self.result = f.buf; self.onload(); }); };
	const fnC = new Function('baseclass', 'rpc', 'ui', 'dom', 'E', '_', 'window', 'console', 'Date', 'document', 'URL', 'FileReader', srcs.common);
	const C0 = fnC(env.baseclass, env.rpc, env.ui, env.dom, E, s => s, env.win, cons, env.FakeDate, env.doc, URLx, FileReaderX);
	const common = new C0();
	const F = makeForm(env);
	const view = { extend: (proto) => proto };
	const fnV = new Function('view', 'form', 'dom', 'common', 'E', '_', 'window', 'console', 'document', srcs[name]);
	const V = fnV(view, F.form, env.dom, common, E, s => s, env.win, cons, env.doc);
	const fire = (type) => { const ev = { type, defaultPrevented: false, returnValue: undefined, preventDefault() { this.defaultPrevented = true; } }; unload.forEach(fn => fn(ev)); return ev; };
	return { env, common, V, F, store: F.store, unload, fire, logs, blobs, E };
}

// ---- fixtures
const MAC1 = 'aa:bb:cc:dd:ee:01', MAC2 = 'aa:bb:cc:dd:ee:02', MAC3 = 'aa:bb:cc:dd:ee:03';
function routingStatus() {
	return {
		ok: true, code: 'ok', mode: 'selective', communities: [ 'russia_inside' ], domains: [ 'a.example' ],
		auto_domains: [ 'found1.example', 'found2.example' ], clients: [ '192.168.1.10' ], client_devices: [ MAC3 ],
		settings: { client_mode: 'all', adaptive_routing: false }
	};
}
function leases() { return { leases: [ { mac: MAC1, ip: '192.168.1.21', host: '<img src=x onerror=alert(1)>tv' }, { mac: MAC2, ip: '192.168.1.22', host: 'phone' } ] }; }
function settingsStatus() {
	return {
		ok: true, code: 'ok',
		settings: {
			auto_switch: true, favorites_only: false, auto_snapshot: false, auto_snapshot_max: 20,
			check_services: 'www.youtube.com', dead_filter: true, killswitch: false, dns_protect: false,
			telegram_enabled: true, telegram_control: false, telegram_token: '123456:***', telegram_token_set: true,
			telegram_chat: '42', telegram_via_proxy: true, sched_enabled: false, sched_on: '', sched_off: '', sched_refresh: '',
			failover_interval: 60, failover_tolerance: 50, dead_filter_strikes: 3, dead_filter_tries: 3,
			subscription_interval: '6h', antidpi: 'off', ipv6: 'block', log_level: 'warn', prefilter_concurrency: 16
		}
	};
}
async function open(name, srcs, h) {
	const P = makePage(name, srcs);
	P.env.handlers.status = () => (name === 'routing' ? routingStatus() : settingsStatus());
	P.env.handlers.leases = () => leases();
	P.env.handlers.set_config = () => ({ ok: true, code: 'saved', daemon: 'signalled', changed: [] });
	Object.assign(P.env.handlers, h || {});
	const data = await P.V.load();
	P.box = await P.V.render(data);
	P.env.doc.body.appendChild(P.box);
	await P.env.flush();
	return P;
}
const calls = (P, m) => P.env.rpcLog.filter(x => x[0] === m);
const toastTexts = (P, kind) => P.env.mc.children.filter(n => n.classes && n.classes.has('vp-toast') && (!kind || n.classes.has(kind))).map(n => n.textContent);
const saveBtn = (P) => P.box.querySelector('.vp-save');
const revertBtn = (P) => P.box.querySelector('.vp-revert');
const setv = (P, cbid, v) => { P.store.set('cbid.json.' + cbid, v); };
async function clickSave(P) { P.env.D.fire(saveBtn(P), 'click', {}); await P.env.tick(10); await P.env.flush(); }
function field(P, cbid) { return P.box.querySelector('[data-field="cbid.json.' + cbid + '"]'); }
function devBox(P, mac) { return P.box.querySelectorAll('input').find(c => c.value === mac); }

// every field changed (valid values)
function changeAllRouting(P) {
	setv(P, 'mode.mode', 'exclude');
	setv(P, 'l_countries.russia_inside', '0');
	setv(P, 'l_services.youtube', '1');
	setv(P, 'sites.domains', 'a.example\nNew.Example\n');
	setv(P, 'sites.adaptive_routing', '1');
	setv(P, 'sites.auto_domains', 'found2.example');
	setv(P, 'devices.client_mode', 'include');
	devBox(P, MAC2).checked = true;
	setv(P, 'devices.clients', '192.168.1.10\n192.168.1.77');
}
const ROUTING_WANT = {
	mode: 'exclude', communities: [ 'youtube' ], domains: [ 'a.example', 'New.Example' ], adaptive_routing: true,
	auto_domains: [ 'found2.example' ], client_mode: 'include', client_devices: [ MAC2, MAC3 ], clients: [ '192.168.1.10', '192.168.1.77' ]
};
function changeAllSettings(P) {
	const t = {
		'auto.auto_switch': '0', 'auto.favorites_only': '1', 'auto.auto_snapshot': '1', 'auto.auto_snapshot_max': '30',
		'check.check_services': 'www.youtube.com\ninstagram.com', 'check.dead_filter': '0',
		'protect.killswitch': '1', 'protect.dns_protect': '1',
		'telegram.telegram_enabled': '0', 'telegram.telegram_control': '1', 'telegram.telegram_token': SECRET,
		'telegram.telegram_chat': '@newchat1', 'telegram.telegram_via_proxy': '0',
		'schedule.sched_enabled': '1', 'schedule.sched_on': '07:30', 'schedule.sched_off': '23:15', 'schedule.sched_refresh': '04:00',
		'adv.failover_interval': '90', 'adv.failover_tolerance': '70', 'adv.dead_filter_strikes': '4', 'adv.dead_filter_tries': '2',
		'adv.subscription_interval': '12h', 'adv.antidpi': 'aggressive', 'adv.ipv6': 'off', 'adv.log_level': 'info', 'adv.prefilter_concurrency': '8'
	};
	for (const [k, v] of Object.entries(t)) setv(P, k, v);
}
const SETTINGS_WANT = {
	auto_switch: false, favorites_only: true, auto_snapshot: true, auto_snapshot_max: 30, check_services: 'www.youtube.com instagram.com',
	dead_filter: false, killswitch: true, dns_protect: true, telegram_enabled: false, telegram_control: true, telegram_token: SECRET,
	telegram_chat: '@newchat1', telegram_via_proxy: false, sched_enabled: true, sched_on: '07:30', sched_off: '23:15', sched_refresh: '04:00',
	failover_interval: 90, failover_tolerance: 70, dead_filter_strikes: 4, dead_filter_tries: 2, subscription_interval: '12h',
	antidpi: 'aggressive', ipv6: 'off', log_level: 'info', prefilter_concurrency: 8
};

// ---- tests
const T = [];
let CHECKED = 0;   // things checked across all tests (a run that checks nothing is a failure)
function test(name, fn) { T.push({ name, fn }); }
function eq(a, b, what) { CHECKED++; if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((what || 'value') + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b)); }
function ok(c, what) { CHECKED++; if (!c) throw new Error(what || 'assertion failed'); }

for (const page of [ 'routing', 'settings' ]) {
	const WANT = page === 'routing' ? ROUTING_WANT : SETTINGS_WANT;
	const changeAll = page === 'routing' ? changeAllRouting : changeAllSettings;

	test(page + ': every field of the page has its option on the page; the form starts clean', async (S) => {
		const P = await open(page, S);
		const sv = P.common.currentForm();
		ok(sv && Array.isArray(sv.fields), 'the page made a form');
		ok(sv.fields.length >= (page === 'routing' ? 8 : 26), 'positive control: fields ' + sv.fields.length);
		eq(sv.missing(), [], 'fields without an option on the page');
		eq(sv.changes(), {}, 'changes right after loading');
		ok(saveBtn(P) && revertBtn(P), 'one save panel: Save + Revert');
		eq(P.box.querySelectorAll('.vp-savebar').length, 1, 'save panels on the page');
	});

	test(page + ': the form sends exactly the set_config schema (keys and types), every field reachable', async (S) => {
		const P = await open(page, S);
		changeAll(P);
		await clickSave(P);
		const sc = calls(P, 'set_config');
		eq(sc.length, 1, 'set_config calls');
		const sent = sc[0][1].settings;
		ok(sent && typeof sent === 'object', 'settings object sent');
		const sch = schema();
		ok(Object.keys(sch).length >= 40, 'positive control: schema fields read from api.uc: ' + Object.keys(sch).length);
		eq(typeProblems(sent, sch), [], 'type problems');
		eq(Object.keys(sent).sort(), Object.keys(WANT).sort(), 'every field of the page sent once changed');
		eq(sent, Object.assign({}, sent, WANT), 'values');
		for (const k of Object.keys(WANT)) eq(sent[k], WANT[k], k);
		if (process.env.UI_PAGES_PAYLOAD_DIR) fs.writeFileSync(path.join(process.env.UI_PAGES_PAYLOAD_DIR, page + '.json'), JSON.stringify({ settings: sent }));
		// the choices a list offers are values the router accepts
		const sv = P.common.currentForm();
		const bad = [];
		for (const fd of sv.fields) {
			if (fd.t === 'set' || !sch[fd.f] || sch[fd.f].kind !== 'enum') continue;
			const r = sv.lookup(fd.o);
			const o = r[0];
			const offered = o.keylist.length ? o.keylist : [ o.enabled, o.disabled ];
			offered.filter(v => !sch[fd.f].values.includes(v)).forEach(v => bad.push(fd.f + '=' + v));
		}
		eq(bad, [], 'choices the router does not accept');
		// review Н4: number limits of the form = the router's; the ready-made lists = the router's
		const rng = [];
		let nr = 0;
		for (const fd of sv.fields) {
			if (!sch[fd.f] || sch[fd.f].kind !== 'int') continue;
			const o = sv.lookup(fd.o)[0], m = String(o.datatype || '').match(/range\(([0-9]+),([0-9]+)\)/);
			nr++;
			if (!m || +m[1] !== sch[fd.f].range[0] || +m[2] !== sch[fd.f].range[1]) rng.push(fd.f + ': form ' + (o.datatype || 'none') + ', router ' + JSON.stringify(sch[fd.f].range));
		}
		if (page === 'settings') ok(nr >= 6, 'positive control: number fields compared ' + nr);
		eq(rng, [], 'number limits differ');
		if (page === 'routing') {
			const cu = fs.readFileSync(path.join(path.dirname(APIUC), 'common.uc'), 'utf8').match(/const VALID_COMMUNITY = \{([\s\S]*?)\};/);
			ok(cu, 'positive control: VALID_COMMUNITY found');
			const valid = [ ...cu[1].matchAll(/([a-z_]+): 1/g) ].map(q => q[1]).sort();
			ok(valid.length >= 20, 'positive control: lists of the router ' + valid.length);
			eq(Object.keys(sv.byName.communities.o).sort(), valid, 'ready-made lists on the page vs the router');
		}
	});

	test(page + ': one Save = one set_config with the changed fields only; nothing changed = no call', async (S) => {
		const P = await open(page, S);
		await clickSave(P);
		eq(calls(P, 'set_config').length, 0, 'calls when nothing changed');
		ok(toastTexts(P).includes(P.common.CODE_TEXT.unchanged), 'says nothing has changed');
		const k = page === 'routing' ? 'mode.mode' : 'protect.killswitch', f = page === 'routing' ? 'mode' : 'killswitch';
		setv(P, k, page === 'routing' ? 'exclude' : '1');
		P.env.D.fire(saveBtn(P), 'click', {}); P.env.D.fire(saveBtn(P), 'click', {});   // a double click
		await P.env.tick(10);
		eq(calls(P, 'set_config').length, 1, 'calls after one change (double click)');
		eq(Object.keys(calls(P, 'set_config')[0][1].settings), [ f ], 'only the changed field');
	});

	test(page + ': a field error of the router is shown at its field', async (S) => {
		const errs = page === 'routing'
			? { 'domains[1]': 'bad_domain', client_mode: 'bad_value', unknown_thing: 'unknown_field' }
			: { failover_interval: 'too_small', telegram_chat: 'bad_chat', unknown_thing: 'unknown_field' };
		const P = await open(page, S, { set_config: () => ({ ok: false, code: 'invalid', daemon: 'n/a', error: 'invalid', errors: errs }) });
		changeAll(P);
		await clickSave(P);
		const C = P.common;
		const at = page === 'routing' ? [ [ 'sites.domains', C.FIELD_TEXT.bad_domain, 'New.Example' ], [ 'devices.client_mode', C.FIELD_TEXT.bad_value ] ]
			: [ [ 'adv.failover_interval', C.FIELD_TEXT.too_small ], [ 'telegram.telegram_chat', C.FIELD_TEXT.bad_chat ] ];
		for (const [cb, text, item] of at) {
			const n = field(P, cb);
			ok(n, 'positive control: field ' + cb + ' is on the page');
			const e = n.querySelectorAll('.vp-field-error-text').map(x => x.textContent);
			ok(e.length === 1 && e[0].includes(text), cb + ': error text at the field: ' + JSON.stringify(e));
			if (item) ok(e[0].includes(item), cb + ': names the wrong item (' + item + '): ' + e[0]);
		}
		eq(P.box.querySelectorAll('.vp-field-error-text').length, at.length, 'error marks on the page');
		const err = toastTexts(P, 'danger');
		ok(err.length === 1 && err[0].includes(C.CODE_TEXT.invalid) && err[0].includes('another setting'), 'one error toast, names the field not on the page: ' + JSON.stringify(err));
		ok(P.common.currentForm().dirty(), 'still unsaved after the refusal');
		if (page === 'settings') ok(P.box.querySelector('details').open, 'an error inside the folded "Advanced" unfolds it');
		// a successful save afterwards clears the marks
		P.env.handlers.set_config = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
		await clickSave(P);
		eq(P.box.querySelectorAll('.vp-field-error-text').length, 0, 'marks after a successful save');
	});

	test(page + ': leaving the page asks only while there are unsaved changes', async (S) => {
		const P = await open(page, S);
		ok(P.unload.length === 1, 'positive control: one beforeunload handler installed (' + P.unload.length + ')');
		ok(!P.fire('beforeunload').defaultPrevented, 'clean page: leaves without asking');
		const k = page === 'routing' ? 'sites.domains' : 'adv.failover_interval';
		const before = P.store.has('cbid.json.' + k) ? P.store.get('cbid.json.' + k) : (page === 'routing' ? 'a.example' : '60');
		setv(P, k, page === 'routing' ? 'a.example\nb.example' : '75');
		const ev = P.fire('beforeunload');
		ok(ev.defaultPrevented && ev.returnValue === '', 'changed: asks (preventDefault + returnValue)');
		setv(P, k, before);
		ok(!P.fire('beforeunload').defaultPrevented, 'changed back: leaves without asking');
		setv(P, k, page === 'routing' ? 'a.example\nb.example' : '75');
		await clickSave(P);
		eq(calls(P, 'set_config').length, 1, 'saved');
		ok(!P.fire('beforeunload').defaultPrevented, 'after a save: leaves without asking');
		setv(P, k, page === 'routing' ? 'z.example' : '80');
		ok(P.fire('beforeunload').defaultPrevented, 'changed again: asks');
		P.env.D.fire(revertBtn(P), 'click', {}); await P.env.tick(10);
		ok(!P.fire('beforeunload').defaultPrevented, 'after Revert: leaves without asking');
	});
}

test('routing: "Search now" only once the automatic search is saved', async (S) => {
	const P = await open('routing', S);
	const f = field(P, 'sites.adaptive_run');
	ok(f, 'positive control: the search field is on the page');
	eq(f.querySelectorAll('button').length, 0, 'no button while the search is not saved');
	ok(f.textContent.includes('Save the page first'), 'says to save first');
	const P2 = await open('routing', S, { status: () => { const s = routingStatus(); s.settings.adaptive_routing = true; return s; }, run_adaptive: () => ({ ok: true, code: 'started', daemon: 'n/a' }) });
	const b = field(P2, 'sites.adaptive_run').querySelector('button');
	ok(b, 'the button once saved');
	P2.env.D.fire(b, 'click', {}); await P2.env.tick(10);
	eq(calls(P2, 'run_adaptive').length, 1, 'the search started');
});

// review ui3 O1: LuCI's parse() rewrites the map's data (hidden options deleted) on every Save
test('routing: Save with nothing changed, a change, Revert: hidden devices and addresses survive', async (S) => {
	const P = await open('routing', S);
	eq(P.common.currentForm().collect().client_devices, [ MAC3 ], 'positive control: a saved device (hidden: all devices)');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 0, 'nothing sent');
	setv(P, 'sites.domains', 'zz.example');
	P.env.D.fire(revertBtn(P), 'click', {}); await P.env.tick(10);
	eq(P.common.currentForm().changes(), {}, 'changes after Revert');
	await clickSave(P);
	eq(calls(P, 'set_config').map(c => c[1].settings), [], 'what a Save after Revert sends');
});
test('settings: Save with nothing changed, a change, Revert: the hidden Telegram token and chat survive', async (S) => {
	const P = await open('settings', S, { status: () => { const s = settingsStatus(); s.settings.telegram_enabled = false; s.settings.telegram_control = false; return s; } });
	await clickSave(P);
	setv(P, 'protect.killswitch', '1');
	P.env.D.fire(revertBtn(P), 'click', {}); await P.env.tick(10);
	eq(P.common.currentForm().changes(), {}, 'changes after Revert');
	await clickSave(P);
	eq(calls(P, 'set_config').map(c => c[1].settings), [], 'what a Save after Revert sends');
});
test('routing: after a refused save Revert brings back the loaded values; a later save keeps them', async (S) => {
	const P = await open('routing', S, { set_config: () => ({ ok: false, code: 'invalid', daemon: 'n/a', error: 'invalid', errors: { 'domains[1]': 'bad_domain' } }) });
	setv(P, 'mode.mode', 'exclude'); setv(P, 'sites.domains', 'a.example\nbad domain!');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 1, 'positive control: the refused save');
	P.env.D.fire(revertBtn(P), 'click', {}); await P.env.tick(10);
	const v = P.common.currentForm().collect();
	eq([ v.mode, v.domains, v.client_devices ], [ 'selective', [ 'a.example' ], [ MAC3 ] ], 'values after Revert');
	P.env.handlers.set_config = () => ({ ok: true, code: 'saved', daemon: 'signalled' });
	P.env.handlers.status = () => new Error('RPC call to vpnpool/status failed with HTTP error 502: Bad Gateway');
	setv(P, 'sites.adaptive_routing', '1');
	await clickSave(P);
	eq(calls(P, 'set_config')[1][1].settings, { adaptive_routing: true }, 'the next save sends only its change');
	P.env.D.fire(revertBtn(P), 'click', {}); await P.env.tick(10);
	eq(P.common.currentForm().collect().adaptive_routing, true, 'Revert after a save (page not loaded again) keeps the saved value');
});

test('settings: after a save the page is clean even if loading it again fails', async (S) => {
	const P = await open('settings', S);
	let n = 0;
	P.env.handlers.status = () => (++n === 1 ? new Error('RPC call to vpnpool/status failed with HTTP error 502: Bad Gateway') : settingsStatus());
	setv(P, 'protect.killswitch', '1');
	ok(P.fire('beforeunload').defaultPrevented, 'positive control: the change makes the page ask');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 1, 'saved');
	ok(n >= 1, 'positive control: the page tried to load again (' + n + ')');
	ok(!P.fire('beforeunload').defaultPrevented, 'the saved change is not "unsaved"');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 1, 'a second Save sends nothing');
	ok(!saveBtn(P).disabled, 'the panel is not stuck in "saving"');
	setv(P, 'protect.dns_protect', '1');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 2, 'the next change is saved');
});

test('routing: device names are text (no markup from the network); hidden device fields keep their values', async (S) => {
	const P = await open('routing', S);
	const lst = P.box.querySelector('.vp-devlist');
	ok(lst, 'positive control: the device list is rendered');
	ok(lst.textContent.includes('<img src=x onerror=alert(1)>tv'), 'the name is shown as text');
	eq(P.env.doc.unsafe.filter(u => /onerror/.test(u.html)), [], 'device name reached innerHTML');
	eq(P.box.querySelectorAll('input').filter(c => c.type === 'checkbox').length, 3, 'two leases + one saved offline device');
	eq(P.common.currentForm().collect().client_devices, [ MAC3 ], 'the saved device is chosen');
});

test('routing: "A site does not open?" adds the site to your sites (saved with the page)', async (S) => {
	const P = await open('routing', S);
	const help = field(P, 'sites.site_help');
	ok(help, 'positive control: the helper is on the page');
	const inp = help.querySelector('input'), btn = help.querySelector('button');
	inp.value = 'https://Blocked.Example/path?q=1';
	P.env.D.fire(btn, 'click', {});
	eq(P.common.currentForm().collect().domains, [ 'a.example', 'blocked.example' ], 'domains after adding');
	ok(P.common.currentForm().dirty(), 'the page has an unsaved change');
	eq(calls(P, 'set_config').length, 0, 'nothing sent before Save');
	inp.value = 'a.example';
	P.env.D.fire(btn, 'click', {});
	eq(P.common.currentForm().collect().domains, [ 'a.example', 'blocked.example' ], 'a site already in the list is not added twice');
	inp.value = 'not a site!';
	P.env.D.fire(btn, 'click', {});
	ok(help.textContent.includes(P.common.FIELD_TEXT.bad_domain), 'a wrong address is explained');
});

test('settings: the Telegram test sends what is typed (not saved); a masked token = the saved one', async (S) => {
	const P = await open('settings', S, { tg_test: () => ({ ok: true, code: 'sent', daemon: 'n/a' }) });
	const btn = field(P, 'telegram.tg_test').querySelector('button');
	ok(btn, 'positive control: the test button');
	P.env.D.fire(btn, 'click', {}); await P.env.tick(10);
	eq(calls(P, 'tg_test')[0][1], { token: '123456:***', chat: '42', via_proxy: true }, 'untouched: the masked token (= saved)');
	setv(P, 'telegram.telegram_token', SECRET); setv(P, 'telegram.telegram_chat', '@typed_chat'); setv(P, 'telegram.telegram_via_proxy', '0');
	P.env.D.fire(btn, 'click', {}); await P.env.tick(10);
	eq(calls(P, 'tg_test')[1][1], { token: SECRET, chat: '@typed_chat', via_proxy: false }, 'typed values');
	eq(calls(P, 'set_config').length, 0, 'the test saves nothing');
	// a save error of another field first (its mark must survive the tests below)
	P.env.handlers.set_config = () => ({ ok: false, code: 'invalid', daemon: 'n/a', error: 'invalid', errors: { failover_interval: 'too_small' } });
	setv(P, 'adv.failover_interval', '11');
	await clickSave(P);
	eq(field(P, 'adv.failover_interval').querySelectorAll('.vp-field-error-text').length, 1, 'positive control: the save mark');
	// a refused typed value is shown at its field
	P.env.handlers.tg_test = () => ({ ok: false, code: 'invalid', daemon: 'n/a', error: 'invalid', errors: { telegram_token: 'bad_token' } });
	P.env.D.fire(btn, 'click', {}); await P.env.tick(10);
	const e = field(P, 'telegram.telegram_token').querySelectorAll('.vp-field-error-text').map(x => x.textContent);
	eq(e, [ P.common.FIELD_TEXT.bad_token ], 'token error at the field');
	eq(field(P, 'adv.failover_interval').querySelectorAll('.vp-field-error-text').length, 1, 'the save mark stays after a refused test');
	// a test that fails otherwise: the old token mark goes, the other stays
	P.env.handlers.tg_test = () => ({ ok: false, code: 'send_failed', daemon: 'n/a', error: 'send_failed', http: '401' });
	P.env.D.fire(btn, 'click', {}); await P.env.tick(10);
	eq(field(P, 'telegram.telegram_token').querySelectorAll('.vp-field-error-text').length, 0, 'old token mark after the next test');
	eq(field(P, 'adv.failover_interval').querySelectorAll('.vp-field-error-text').length, 1, 'the save mark of another field stays');
});

test('settings: the Telegram token never reaches a log, a toast or a page text', async (S) => {
	let n = 0;
	const P = await open('settings', S, {
		tg_test: () => (++n === 1 ? new Error('RPC call to vpnpool/tg_test failed with HTTP error 502: Bad Gateway')
			: { ok: false, code: 'send_failed', daemon: 'n/a', error: 'send_failed', http: '401' }),
		set_config: () => (n < 3 ? (n = 3, { ok: false, code: 'invalid', daemon: 'n/a', error: 'invalid', errors: { telegram_token: 'bad_token', 'x[0]': 'bad_value' } })
			: { ok: true, code: 'saved', daemon: 'signalled', warning: 'schedule_failed' })
	});
	setv(P, 'telegram.telegram_token', SECRET);
	const btn = field(P, 'telegram.tg_test').querySelector('button');
	P.env.D.fire(btn, 'click', {}); await P.env.tick(10);
	P.env.D.fire(btn, 'click', {}); await P.env.tick(10);
	await clickSave(P);
	await clickSave(P);
	ok(P.env.rpcLog.some(x => JSON.stringify(x).includes(SECRET)), 'positive control: the typed token was sent to the router (so the scan below looks at a real flow)');
	ok(calls(P, 'tg_test').length === 2 && calls(P, 'set_config').length === 2, 'four requests made');
	ok(P.logs.length > 0, 'positive control: the console was written to (' + P.logs.length + ' lines)');
	const leak = [];
	P.logs.forEach(l => { if (l.includes(SECRET) || l.includes('SECRETtoken')) leak.push('console: ' + l); });
	const all = [ P.env.mc.textContent, P.box.textContent, P.env.doc.body.textContent ];
	all.forEach(t => { if (t.includes('SECRETtoken')) leak.push('text: ' + t.slice(0, 200)); });
	P.env.doc.unsafe.forEach(u => { if (u.html.includes('SECRETtoken')) leak.push('html: ' + u.html.slice(0, 200)); });
	eq(leak, [], 'token found');
});

test('settings: a wrong time stops the save before anything is sent', async (S) => {
	const P = await open('settings', S);
	setv(P, 'schedule.sched_enabled', '1');
	setv(P, 'schedule.sched_on', '25:99');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 0, 'set_config calls');
	ok(toastTexts(P, 'danger').includes(P.common.CODE_TEXT.invalid), 'error toast');
	setv(P, 'schedule.sched_on', '7:05');
	await clickSave(P);
	eq(calls(P, 'set_config').length, 1, 'a valid time is sent');
});

test('settings: backup download and restore (the router checks first, replacing needs a yes)', async (S) => {
	const bytes = Buffer.from([ 0x1f, 0x8b, 8, 0, 1, 2, 3, 250, 255 ]);
	let restores = [];
	const P = await open('settings', S, {
		backup: () => ({ ok: true, code: 'done', daemon: 'n/a', name: 'vpnpool-backup-x.tar.gz', data: bytes.toString('base64'), report: { nodes: 3, subscriptions: 1, saved: 2, awg: 1 } }),
		restore: (p) => { restores.push(p); return p.replace_all ? { ok: true, code: 'restored', daemon: 'signalled' }
			: { ok: false, code: 'confirm_required', daemon: 'n/a', error: 'confirm_required', report: { nodes: 7, subscriptions: 2, saved: 1, awg: 0 } }; }
	});
	const box = field(P, 'backup.files');
	const [ dl, rs ] = box.querySelectorAll('button');
	P.env.D.fire(dl, 'click', {}); await P.env.tick(10);
	eq(P.blobs.length, 1, 'one file made');
	eq([ ...new Uint8Array(await P.blobs[0].arrayBuffer()) ], [ ...bytes ], 'file bytes = the archive');
	ok(toastTexts(P).some(t => t.includes('Nodes: 3') && t.includes('subscriptions: 1')), 'says what it holds');
	const input = box.querySelectorAll('input').find(i => i.type === 'file');
	ok(input && rs, 'positive control: the restore button and its file input');
	// review О3: a file the router's request limit would refuse is refused BEFORE sending
	const big = Buffer.alloc(45001, 7);
	restores = [];
	P.V.restoreFile({ size: big.length, buf: big.buffer.slice(big.byteOffset, big.byteOffset + big.length) });
	await P.env.tick(10);
	eq(restores.length, 0, 'a too large file: nothing sent');
	ok(toastTexts(P, 'danger').some(t => t.includes('too large') && t.includes('43 KB')), 'a too large file: said so: ' + JSON.stringify(toastTexts(P, 'danger')));
	P.common.clearToast();
	const fits = Buffer.alloc(45000, 7);
	const pf = P.V.restoreFile({ size: fits.length, buf: fits.buffer.slice(fits.byteOffset, fits.byteOffset + fits.length) });
	await P.env.tick(10);
	eq(restores.length, 1, 'a file at the limit is sent for the check');
	P.env.D.fire(P.env.doc.getElementById('modal_overlay').firstElementChild.querySelector('.vp-confirm-cancel'), 'click', {});
	await P.env.tick(10); await pf;
	const runRestore = async (yes) => {
		const p = P.V.restoreFile({ size: bytes.length, buf: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length) });
		await P.env.tick(10);
		const dlg = P.env.doc.getElementById('modal_overlay').firstElementChild;
		ok(dlg.textContent.includes('Nodes: 7') && dlg.textContent.includes('Subscriptions: 2'), 'the dialog lists what the file holds');
		P.env.D.fire(dlg.querySelector(yes ? '.vp-confirm-ok' : '.vp-confirm-cancel'), 'click', {});
		await P.env.tick(10);
		return p;
	};
	restores = [];
	await runRestore(false);
	eq(restores.map(r => !!r.replace_all), [ false ], 'cancel: only the check was asked');
	eq(restores[0].data, bytes.toString('base64'), 'the file went as base64');
	restores = [];
	await runRestore(true);
	eq(restores.map(r => !!r.replace_all), [ false, true ], 'yes: check, then replace');
	ok(calls(P, 'status').length >= 2, 'the page is loaded again after the restore');
	ok(toastTexts(P).some(t => t.includes('starts again')), 'says the service starts again');
	// the service is off: no "starts again" (common adds that the change waits for the service)
	P.env.handlers.restore = (p) => (p.replace_all ? { ok: true, code: 'restored', daemon: 'not_running' }
		: { ok: false, code: 'confirm_required', daemon: 'n/a', error: 'confirm_required', report: { nodes: 7, subscriptions: 2, saved: 1, awg: 0 } });
	await runRestore(true);
	const last = toastTexts(P).filter(t => !t.includes('Nodes:'));
	ok(last.length === 1 && last[0].startsWith(P.common.CODE_TEXT.restored) && !last[0].includes('starts again'), 'service off: ' + JSON.stringify(last));
});

test('routing and settings: Revert brings back the loaded values and the panel says so', async (S) => {
	for (const page of [ 'routing', 'settings' ]) {
		const P = await open(page, S);
		const k = page === 'routing' ? 'mode.mode' : 'auto.auto_switch';
		setv(P, k, page === 'routing' ? 'exclude' : '0');
		P.env.handlers.set_config = () => ({ ok: false, code: 'invalid', daemon: 'n/a', error: 'invalid', errors: { [page === 'routing' ? 'mode' : 'auto_switch']: 'bad_value' } });
		await clickSave(P);
		ok(toastTexts(P, 'danger').length === 1 && P.box.querySelectorAll('.vp-field-error-text').length === 1, page + ': positive control: a refused save left its error toast and mark');
		P.common.currentForm().update();
		ok(P.box.querySelector('.vp-savebar').classes.has('vp-dirty'), page + ': the panel shows unsaved changes');
		P.env.D.fire(revertBtn(P), 'click', {}); await P.env.tick(10);
		eq(P.common.currentForm().changes(), {}, page + ': changes after Revert');
		ok(!P.box.querySelector('.vp-savebar').classes.has('vp-dirty'), page + ': the panel is clean');
		eq(toastTexts(P, 'danger').length + P.box.querySelectorAll('.vp-field-error-text').length, 0, page + ': the refused save\'s error toast and marks after Revert');
	}
});

// ---------- runner
const UNHANDLED = [];
process.on('unhandledRejection', (e) => { UNHANDLED.push(String(e && e.message || e)); });
async function run(srcs, quiet) {
	// every test in both drawing modes of the fake (see FAKE); a test fails if it fails in either
	let pass = 0, fail = 0;
	const failed = [];
	for (const t of T) {
		const why = [];
		for (const mode of [ 'cache', 'data' ]) {
			FAKE.render = mode;
			try {
				const u0 = UNHANDLED.length;
				// a test whose promise never settles must FAIL, not end the process quietly (node
				// exits 0 when nothing is pending): a real timer races it
				let tm;
				await Promise.race([ t.fn(srcs), new Promise((_, rej) => { tm = setTimeout(() => rej(new Error('test did not finish (hangs)')), 15000); }) ])
					.finally(() => clearTimeout(tm));
				await new Promise(r => setImmediate(r));
				if (UNHANDLED.length > u0) throw new Error('unhandled rejection in the page: ' + UNHANDLED[u0]);
			} catch (e) {
				why.push('[' + mode + '] ' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e));
			}
		}
		FAKE.render = 'cache';
		if (!why.length) { pass++; if (!quiet) console.log('ok   - ' + t.name); }
		else { fail++; failed.push(t.name); if (!quiet) console.log('FAIL - ' + t.name + ': ' + why.join(' || ')); }
	}
	return { pass, fail, failed };
}

// mutations: [ name, file (common|routing|settings), from, to, tests that must go red ]
const MUTATIONS = [
	[ 'one set_config per changed field', 'common', "return C.call(self.method, { settings: ch }, { handle: [ 'invalid' ], success: CODE_TEXT.saved }).then(function(r) {",
		"Object.keys(ch).forEach(function(k) { var x = {}; x[k] = ch[k]; C.call(self.method, { settings: x }, { quiet: true }).catch(function() {}); }); return C.call(self.method, { settings: ch }, { handle: [ 'invalid' ], success: CODE_TEXT.saved }).then(function(r) {",
		[ 'routing: one Save = one set_config with the changed fields only; nothing changed = no call', 'settings: one Save = one set_config with the changed fields only; nothing changed = no call', 'routing: the form sends exactly the set_config schema (keys and types), every field reachable', 'settings: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	[ 'every field sent, not the changed ones', 'common', "if (has(cur, f) && cur[f] !== undefined && !same(cur[f], this.base[f])) out[f] = cur[f];", "if (has(cur, f) && cur[f] !== undefined) out[f] = cur[f];",
		[ 'routing: one Save = one set_config with the changed fields only; nothing changed = no call', 'settings: one Save = one set_config with the changed fields only; nothing changed = no call', 'routing: leaving the page asks only while there are unsaved changes', 'settings: leaving the page asks only while there are unsaved changes' ] ],
	[ 'no double-click guard', 'common', 'if (this.busy) return this.busy;', '',
		[ 'routing: one Save = one set_config with the changed fields only; nothing changed = no call', 'settings: one Save = one set_config with the changed fields only; nothing changed = no call' ] ],
	[ 'booleans sent as "1"/"0"', 'common', "case 'bool':  return fv === '1' || fv === 1 || fv === true;", "case 'bool':  return String(fv);",
		[ 'settings: the form sends exactly the set_config schema (keys and types), every field reachable', 'routing: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	[ 'numbers sent as text', 'common', "return /^[0-9]{1,10}$/.test(s) ? Number(s) : s;", 'return s;',
		[ 'settings: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	[ 'field error not put at the field', 'common', "el.appendChild(E('div', { 'class': 'vp-field-error-text', 'role': 'alert' }, [ txt(text) ]));", '',
		[ 'routing: a field error of the router is shown at its field', 'settings: a field error of the router is shown at its field', 'settings: the Telegram test sends what is typed (not saved); a masked token = the saved one' ] ],
	[ 'list item not named in the error', 'common', "if (m && Array.isArray(sent) && sent[+m[2]] != null) text =", 'if (false) text =',
		[ 'routing: a field error of the router is shown at its field' ] ],
	[ 'beforeunload always asks', 'common', 'if (!currentForm || !currentForm.dirty()) return;', 'if (!currentForm) return;',
		[ 'routing: leaving the page asks only while there are unsaved changes', 'settings: leaving the page asks only while there are unsaved changes' ] ],
	[ 'beforeunload never asks', 'common', "\t\tev.preventDefault();\n\t\tev.returnValue = '';", '',
		[ 'routing: leaving the page asks only while there are unsaved changes', 'settings: leaving the page asks only while there are unsaved changes' ] ],
	[ 'saved values not taken as the new base', 'common', '{ self.base[f] = ch[f]; self.snapPut', '{ self.snapPut',
		[ 'settings: after a save the page is clean even if loading it again fails' ] ],
	[ 'a failed reload after the save jams the panel', 'common', 'return Promise.resolve(self.onSaved ? self.onSaved(r) : r).then(null, function() { return r; });',
		'return self.onSaved ? self.onSaved(r) : r;', [ 'settings: after a save the page is clean even if loading it again fails' ] ],
	[ 'the settings logged', 'common', 'self.sent = ch;', 'self.sent = ch; console.info("vpnpool: saving " + JSON.stringify(ch));',
		[ 'settings: the Telegram token never reaches a log, a toast or a page text' ] ],
	[ 'Telegram test sends the saved values', 'settings', "return common.call('tg_test', { token: cur.telegram_token, chat: cur.telegram_chat, via_proxy: cur.telegram_via_proxy },",
		"return common.call('tg_test', {},", [ 'settings: the Telegram test sends what is typed (not saved); a masked token = the saved one' ] ],
	// both layers: the old form stops at once, and a lookup on drawn-over elements is "not found"
	[ 'the form of a page drawn over keeps working', 'common', [ [ 'if (currentForm !== this) return false;', '' ],
		[ 'try { r = this.maps[i].lookupOption(p[1], p[0], FORM_CONFIG); } catch (e) { r = null; }', 'r = this.maps[i].lookupOption(p[1], p[0], FORM_CONFIG);' ] ], null,
		[ 'routing: leaving the page asks only while there are unsaved changes', 'settings: leaving the page asks only while there are unsaved changes' ] ],
	// both checks (by size before reading, by length after)
	[ 'a too large file is sent anyway', 'settings', [ [ 'if (Math.ceil(file.size / 3) * 4 > RESTORE_MAX_B64) return Promise.resolve(tooBig());', '' ],
		[ 'if (b64.length > RESTORE_MAX_B64) return tooBig();', '' ] ], null,
		[ 'settings: backup download and restore (the router checks first, replacing needs a yes)' ] ],
	[ 'the request limit taken as the archive limit', 'settings', 'var RESTORE_MAX_B64 = 60000;', 'var RESTORE_MAX_B64 = 5592408;',
		[ 'settings: backup download and restore (the router checks first, replacing needs a yes)' ] ],
	[ 'an error inside "Advanced" stays folded', 'common', "if (p.tagName === 'DETAILS' && !p.open) p.open = true;", '',
		[ 'settings: a field error of the router is shown at its field' ] ],
	[ '"Search now" before the search is saved', 'routing', 'if (!adaptiveSaved)', 'if (false)',
		[ 'routing: "Search now" only once the automatic search is saved' ] ],
	[ 'a form limit differs from the router', 'settings', "o.datatype = 'and(uinteger,range(1,64))';", "o.datatype = 'and(uinteger,range(1,128))';",
		[ 'settings: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	[ 'a ready-made list the router does not know', 'routing', "[ 'roblox', 'Roblox', null ]", "[ 'roblox', 'Roblox', null ], [ 'spotify', 'Spotify', null ]",
		[ 'routing: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	// review ui3 O1
	[ 'Revert draws from the data a Save has rewritten', 'common', '\t\t\trestoreSnap(m, self.snaps[i]);', '',
		[ 'routing: Save with nothing changed, a change, Revert: hidden devices and addresses survive',
		  'settings: Save with nothing changed, a change, Revert: the hidden Telegram token and chat survive',
		  'routing: after a refused save Revert brings back the loaded values; a later save keeps them' ] ],
	// LuCI draws from the cfgvalue cached at load(): without a load the saved value is not drawn
	[ 'Revert without loading again (LuCI draws from its cache)', 'common', "return Promise.resolve(typeof m.load === 'function' ? m.load() : null).then(function() { return m.reset(); });", 'return m.reset();',
		[ 'routing: after a refused save Revert brings back the loaded values; a later save keeps them' ] ],
	[ 'a saved value is not what Revert goes back to', 'common', ' self.snapPut(self.byName[f], ch[f]); }', ' }',
		[ 'routing: after a refused save Revert brings back the loaded values; a later save keeps them' ] ],
	[ 'Revert keeps the error of the refused save', 'common', 'dropSticky(self.method);   // the error of a refused save', '//',
		[ 'routing and settings: Revert brings back the loaded values and the panel says so' ] ],
	[ 'an old Telegram test mark stays', 'settings', '\t\tsaver.clearErrors(mine);', '',
		[ 'settings: the Telegram test sends what is typed (not saved); a masked token = the saved one' ] ],
	[ 'the Telegram test wipes the marks of a save', 'settings', 'saver.showErrors(e, mine);', 'saver.showErrors(e);',
		[ 'settings: the Telegram test sends what is typed (not saved); a masked token = the saved one' ] ],
	[ 'a settings field dropped from the page', 'settings', "\to = s.option(form.Value, 'prefilter_concurrency', _('Nodes checked at once'),", "\to = s.option(form.Value, 'prefilter_concurrency_x', _('Nodes checked at once'),",
		[ 'settings: every field of the page has its option on the page; the form starts clean', 'settings: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	[ 'a routing list offers a value the router refuses', 'routing', "o.value('exclude', card(_('All except the chosen devices')", "o.value('except', card(_('All except the chosen devices')",
		[ 'routing: the form sends exactly the set_config schema (keys and types), every field reachable' ] ],
	// two breaks together: common.E alone turns a bare string into text (that is its job)
	[ 'device name as markup', 'routing', [ [ "E('span', { 'class': 'vp-dev-name' }, [ txt(d.host || d.ip || d.mac.toUpperCase()) ])", "E('span', { 'class': 'vp-dev-name' }, d.host || d.ip || d.mac.toUpperCase())" ],
		[ 'var E = common.E;', '' ] ], null,
		[ 'routing: device names are text (no markup from the network); hidden device fields keep their values' ] ],
	[ 'site helper saves at once', 'routing', "w.setValue(cur.join('\\n'));", "w.setValue(cur.join('\\n')); common.call('set_config', { settings: { domains: cur } }, { quiet: true });",
		[ 'routing: "A site does not open?" adds the site to your sites (saved with the page)' ] ],
	[ 'restore without the check', 'settings', "return common.call('restore', { data: b64 }, { handle: [ 'confirm_required' ] }).then(function() {",
		"return common.call('restore', { data: b64, replace_all: true }, { handle: [ 'confirm_required' ] }).then(function() {",
		[ 'settings: backup download and restore (the router checks first, replacing needs a yes)' ] ],
	[ 'restored: "starts again" while the service is off', 'settings', "(r && r.daemon === 'not_running') ? common.codeText('restored')", "false ? common.codeText('restored')",
		[ 'settings: backup download and restore (the router checks first, replacing needs a yes)' ] ],
	[ 'time not checked', 'settings', '\t\t\to.validate = timeOk;', '',
		[ 'settings: a wrong time stops the save before anything is sent' ] ],
	[ 'Revert does nothing', 'common', [ [ '\t\t\trestoreSnap(m, self.snaps[i]);', '' ],
		[ "return Promise.resolve(typeof m.load === 'function' ? m.load() : null).then(function() { return m.reset(); });", 'return null;' ] ], null,
		[ 'routing and settings: Revert brings back the loaded values and the panel says so', 'routing: leaving the page asks only while there are unsaved changes', 'settings: leaving the page asks only while there are unsaved changes' ] ]
];

// the run ended without its summary line (something never settled): a failure, never exit 0
let FINISHED = false;
process.on('exit', () => { if (!FINISHED) { console.log('PAGES: aborted before the summary'); process.exitCode = 1; } });
(async function main() {
	const srcs = { common: fs.readFileSync(COMMON, 'utf8'), routing: fs.readFileSync(VIEWS.routing, 'utf8'), settings: fs.readFileSync(VIEWS.settings, 'utf8') };
	if (process.argv.includes('--negative')) {
		const base = await run(srcs, true);
		if (base.fail) { console.log('PAGES-NEG: baseline not green: ' + base.failed.join('; ')); console.log('PAGES-NEG: passed=0 failed=1'); FINISHED = true; process.exit(1); }
		let p = 0, f = 0;
		for (const [ name, file, from, to, expect ] of MUTATIONS) {
			const pairs = Array.isArray(from) ? from : [ [ from, to ] ];
			const m = Object.assign({}, srcs);
			const lost = pairs.filter(([ a ]) => !m[file].includes(a));
			if (lost.length) { f++; console.log('FAIL - [' + name + '] mutation anchor not found in ' + file + ': ' + lost[0][0]); continue; }
			pairs.forEach(([ a, z ]) => { m[file] = m[file].replace(a, z); });
			const r = await run(m, true);
			const missing = expect.filter(x => !r.failed.includes(x));
			if (missing.length) { f++; console.log('FAIL - [' + name + '] stayed green: ' + missing.join('; ') + (r.failed.length ? ' (red: ' + r.failed.join('; ') + ')' : '')); }
			else { p++; console.log('ok   - [' + name + '] -> red: ' + r.failed.join('; ')); }
		}
		FINISHED = true; console.log('PAGES-NEG: passed=' + p + ' failed=' + f);
		process.exit(f || !p ? 1 : 0);
	}
	const r = await run(srcs, false);
	FINISHED = true; console.log('PAGES: passed=' + r.pass + ' failed=' + r.fail + ' checked=' + CHECKED);
	process.exit(r.fail || !r.pass || CHECKED < 50 ? 1 : 0);
})();
