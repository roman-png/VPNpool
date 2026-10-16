// Fakes of the LuCI globals (baseclass, rpc, ui, dom, E, poll, L) and of the DOM, shared by the
// unit tests of resources/vpnpool/common.js (ui-common.test.js) and of the views (ui-nodes.test.js).
// They follow LuCI's real rules where a test depends on them — in particular dom.append: a
// string passed as the ONLY child goes into innerHTML (recorded in doc.unsafe), strings in an
// array become text nodes (luci.js openwrt-23.05/24.10/25.12) — and the browser's: moving or
// removing an element that holds the focus takes the focus away (document.activeElement ->
// body). Timers are a fake clock.
'use strict';

// ---------- fake DOM (enough of it for common.js) ----------
function makeDom() {
	const doc = { unsafe: [], listeners: [], activeElement: null };
	// the browser moves the focus to the body when the focused element (or its ancestor) leaves the tree
	function dropFocus(n) { if (n && n.nodeType === 1 && doc.activeElement && n.contains(doc.activeElement)) doc.activeElement = doc.body; }
	class TextNode {
		constructor(s) { this.nodeType = 3; this.data = String(s); this.parentNode = null; }
		get textContent() { return this.data; }
	}
	class El {
		constructor(tag) {
			this.nodeType = 1; this.tagName = String(tag).toUpperCase(); this.children = []; this.parentNode = null;
			this.attrs = {}; this.ls = {}; this.classes = new Set(); this.hidden = false; this.disabled = false; this.checked = false;
			this.value = ''; this.style = {};
			const self = this;
			this.classList = {
				add: (...c) => c.forEach(x => self.classes.add(x)), remove: (...c) => c.forEach(x => self.classes.delete(x)),
				contains: c => self.classes.has(c), toggle: (c, v) => { if (v === undefined) v = !self.classes.has(c); v ? self.classes.add(c) : self.classes.delete(c); return v; }
			};
		}
		get className() { return [...this.classes].join(' '); }
		setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'id') this.id = String(v); if (k === 'class') String(v).split(/\s+/).forEach(c => c && this.classes.add(c)); }
		getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
		appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); c.parentNode = this; this.children.push(c); return c; }
		insertBefore(c, ref) { if (c.parentNode) c.parentNode.removeChild(c); c.parentNode = this; const i = this.children.indexOf(ref); if (i < 0) this.children.push(c); else this.children.splice(i, 0, c); return c; }
		removeChild(c) { this.children = this.children.filter(x => x !== c); c.parentNode = null; dropFocus(c); return c; }
		replaceChild(n, o) { const i = this.children.indexOf(o); if (i < 0) throw new Error('fake DOM: replaceChild of a non-child'); if (n.parentNode) n.parentNode.removeChild(n); this.children[i] = n; n.parentNode = this; o.parentNode = null; dropFocus(o); return o; }
		select() {}
		click() {}
		get firstElementChild() { return this.children.find(c => c.nodeType === 1) || null; }
		get lastChild() { return this.children[this.children.length - 1] || null; }
		contains(n) { while (n) { if (n === this) return true; n = n.parentNode; } return false; }
		get textContent() { return this.children.map(c => c.textContent).join(''); }
		set textContent(v) { this.children.forEach(c => { c.parentNode = null; dropFocus(c); }); this.children = []; this.appendChild(new TextNode(v)); }
		set innerHTML(v) { doc.unsafe.push({ tag: this.tagName, html: String(v) }); this.children = []; this.appendChild(new TextNode(String(v))); }
		focus() { doc.activeElement = this; }
		blur() { if (doc.activeElement === this) doc.activeElement = doc.body; }
		addEventListener(t, fn) { (this.ls[t] = this.ls[t] || []).push(fn); }
		removeEventListener(t, fn) { this.ls[t] = (this.ls[t] || []).filter(f => f !== fn); }
		matches(sel) {
			return sel.split(',').map(s => s.trim()).some(s => {
				let m;
				if ((m = s.match(/^\.([\w-]+)$/))) return this.classes.has(m[1]);
				if ((m = s.match(/^#(.+)$/))) return this.id === m[1];
				if ((m = s.match(/^\[([\w-]+)="([^"]*)"\]$/))) return this.attrs[m[1]] === m[2];
				if ((m = s.match(/^(\w+)\[([\w-]+)\]$/))) return this.tagName === m[1].toUpperCase() && m[2] in this.attrs;
				if ((m = s.match(/^(\w+)$/))) return this.tagName === m[1].toUpperCase();
				throw new Error('fake DOM: unsupported selector ' + s);
			});
		}
		querySelectorAll(sel) { const out = []; const walk = n => n.children.forEach(c => { if (c.nodeType === 1) { if (c.matches(sel)) out.push(c); walk(c); } }); walk(this); return out; }
		querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
	}
	function fire(target, type, init) {
		const ev = Object.assign({ type, target, defaultPrevented: false, bubbles: true }, init || {});
		ev.preventDefault = () => { ev.defaultPrevented = true; };
		for (const l of doc.listeners.filter(l => l.type === type && l.capture)) l.fn(ev);
		for (let n = target; n; n = n.parentNode) for (const fn of (n.ls[type] || []).slice()) { ev.currentTarget = n; fn(ev); }
		for (const l of doc.listeners.filter(l => l.type === type && !l.capture)) l.fn(ev);
		return ev;
	}
	doc.createTextNode = s => new TextNode(s);
	doc.createElement = t => new El(t);
	doc.addEventListener = (type, fn, capture) => doc.listeners.push({ type, fn, capture: !!capture });
	doc.removeEventListener = (type, fn, capture) => { doc.listeners = doc.listeners.filter(l => !(l.type === type && l.fn === fn && l.capture === !!capture)); };
	doc.documentElement = new El('html'); doc.head = new El('head'); doc.body = new El('body');
	doc.documentElement.appendChild(doc.head); doc.documentElement.appendChild(doc.body);
	doc.getElementById = id => doc.documentElement.querySelectorAll('#' + id)[0] || null;
	doc.activeElement = doc.body;
	// LuCI dom.append rule (luci.js): array -> elements appended, other values as TEXT nodes;
	// a single non-node value -> innerHTML
	function append(node, children) {
		if (Array.isArray(children)) {
			children.forEach(c => { if (c && c.nodeType) node.appendChild(c); else node.appendChild(new TextNode(`${c}`)); });
		} else if (children && children.nodeType) node.appendChild(children);
		else if (children !== null && children !== undefined) node.innerHTML = `${children}`;
	}
	function E(tag, attrs, children) {
		const n = new El(tag);
		for (const k in (attrs || {})) {
			const v = attrs[k];
			if (v === null || v === undefined) continue;
			if (typeof v === 'function') n.addEventListener(k, v);
			else if (k === 'hidden') n.hidden = true;
			else if (k === 'disabled') n.disabled = true;
			else n.setAttribute(k, v);
		}
		append(n, children);
		return n;
	}
	return { doc, El, TextNode, E, append, fire };
}

function makeEnv(opts) {
	opts = opts || {};
	const D = makeDom();
	const clock = { now: 1000000, timers: [], seq: 0 };
	const setTimeout_ = (fn, ms) => { const id = ++clock.seq; clock.timers.push({ id, at: clock.now + (ms || 0), fn }); return id; };
	const clearTimeout_ = id => { clock.timers = clock.timers.filter(t => t.id !== id); };
	async function flush() { for (let i = 0; i < 30; i++) await Promise.resolve(); }
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
	const FakeDate = { now: () => clock.now };
	const mc = D.E('div', { id: 'maincontent' });
	D.doc.body.appendChild(mc);
	const modalDiv = D.E('div', { id: 'modal_overlay' }, [ D.E('div', { 'class': 'modal' }) ]);
	D.doc.body.appendChild(modalDiv);
	const ui = {
		calls: [], modalOpen: false,
		addNotification(title, children, ...cls) {
			const n = D.E('div', { 'class': 'alert-message' });
			if (title != null) n.appendChild(D.E('h4', {}, title));
			D.append(n, children);
			cls.forEach(c => n.classes.add(c));
			mc.insertBefore(n, mc.firstElementChild);
			ui.calls.push(['add', cls.join(' ')]);
			return n;
		},
		addTimeLimitedNotification(title, children, timeout, ...cls) {
			const n = ui.addNotification(title, children, ...cls);
			ui.calls.push(['timed', timeout]);
			setTimeout_(() => { if (n.parentNode) n.parentNode.removeChild(n); }, timeout);
			return n;
		},
		showModal(title, children, ...cls) {   // ui.js: dom.content(dlg, dom.create('h4', {}, title))
			const dlg = modalDiv.firstElementChild;
			dlg.children.forEach(c => { c.parentNode = null; }); dlg.children = []; dlg.classes = new Set([ 'modal', ...cls ]);
			dlg.appendChild(D.E('h4', {}, title));
			D.append(dlg, children);
			ui.modalOpen = true; ui.calls.push(['showModal']);
			return dlg;
		},
		hideModal() { ui.modalOpen = false; ui.calls.push(['hideModal']); if (D.doc.activeElement) D.doc.activeElement.blur(); },
		// ui.js: a method name or a function; extra args first, the event last
		createHandlerFn: (ctx, fn, ...pre) => function(...a) { const f = (typeof fn === 'string') ? ctx[fn] : fn; return f.apply(ctx, pre.concat(a)); }
	};
	if (opts.luci2305) delete ui.addTimeLimitedNotification;
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
	const dom = { content(n, c) { n.children.forEach(x => { x.parentNode = null; if (x.nodeType === 1 && x.contains(D.doc.activeElement)) D.doc.activeElement = D.doc.body; }); n.children = []; D.append(n, c); } };
	const baseclass = { extend(proto) { function C() { if (proto.__init__) proto.__init__.apply(this, arguments); } C.prototype = proto; return C; } };
	const consoleQuiet = { warn() {}, info() {}, log() {} };
	const store = {};
	const win = { setTimeout: setTimeout_, clearTimeout: clearTimeout_, innerHeight: 800,
		localStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } } };
	// poll.js: the views register their refresh; a test runs them by hand (pollFns)
	const pollFns = [];
	const poll = { add(fn) { pollFns.push(fn); }, start() {}, active() { return true; } };
	const L = { bind: (fn, ctx) => fn.bind(ctx), resource: p => '/luci-static/resources/' + p, url: (...p) => '/cgi-bin/luci/' + p.join('/') };
	// Date for code that builds dates (new Date(ts).toLocaleDateString()) as well as Date.now()
	const RealDate = Date;
	function DateC(...a) { return a.length ? new RealDate(...a) : new RealDate(clock.now); }
	DateC.now = () => clock.now;
	return { clock, tick, flush, FakeDate, DateC, mc, D, doc: D.doc, ui, rpc, dom, baseclass, handlers, rpcLog, win, consoleQuiet, poll, pollFns, L };
}

function load(src, env) {
	const fn = new Function('baseclass', 'rpc', 'ui', 'dom', 'E', '_', 'window', 'console', 'Date', 'document', src);
	const C = fn(env.baseclass, env.rpc, env.ui, env.dom, env.D.E, s => s, env.win, env.consoleQuiet, env.FakeDate, env.doc);
	return new C();
}

module.exports = { makeDom, makeEnv, load };
