'use strict';
'require view';
'require ui';
'require poll';
'require dom';
'require vpnpool.common as common';

// "Overview" tab (ROADMAP-2.0 §10.2): is the VPN working and through what, at a glance.
//   - "Now": on/off, the state in words (from the daemon's own tunnel check), the node, the exit
//     IP and country (the daemon's background lookup), the delay, the speed ↓↑, "Automatic choice"
//     or "Connected to X" + "Back to automatic choice";
//   - alerts in words: nodes that fail the check, subscriptions that expire / run out / failed to
//     update, AmneziaWG nodes waiting for the engine, nodes set aside, unreadable AmneziaWG files,
//     a failed update of the VPN settings;
//   - a card per subscription (expiry, the traffic left, "updated");
//   - traffic per device;
//   - nothing added yet: the "Add a subscription or a node" wizard (-> Nodes, "+ Add").
// Backend: status, set_enabled, auto_select only (2.0 methods). Every poll updates the texts in
// place; the lists are rebuilt only when what they show changed (buttons keep the focus).
// SAFETY: node, subscription and device names are foreign data — common.E keeps every string a
// text node.

var E = common.E;

var NODES = 'admin/services/vpnpool/nodes';
var DIAG = 'admin/services/vpnpool/diagnostics';
var SETTINGS = 'admin/services/vpnpool/settings';

var CSS = [
	'.vp-ov [hidden]{display:none!important}',
	// the secondary texts: the theme's grey alone is 3.95:1 on its background (bootstrap, measured on
	// the stand) - mixed with the theme's text colour for >= 4.5:1; without color-mix() the grey stays
	'.vp-ov-detail,.vp-ov-facts dt,.vp-ov-sub-facts,.vp-ov .vp-dev-meta,.vp-ov .vp-empty p,.vp-ov .vp-hint{color:var(--text-color-medium,GrayText);color:color-mix(in srgb,var(--text-color-medium,GrayText) 60%,var(--text-color-high,CanvasText))}',
	'.vp-ov-err{color:var(--error-color-medium,var(--danger-color,inherit));margin:0 0 .8em}',
	'.vp-ov-now{box-sizing:border-box;max-width:100%;min-width:0}',
	'.vp-ov-head{display:flex;flex-wrap:wrap;align-items:center;gap:.5em .8em;min-width:0}',
	'.vp-ov-state{flex:1 1 14em;min-width:0;font-size:1.25em;font-weight:bold;overflow-wrap:anywhere}',
	// the same readable mix of the theme colours as common.js (>= 4.5:1 on the theme's background)
	'.vp-ov-state[data-kind=ok]{color:var(--success-color-medium,var(--success-color,inherit));color:color-mix(in srgb,var(--success-color-medium,var(--success-color,#2e7d32)) 55%,var(--text-color-high,CanvasText))}',
	'.vp-ov-state[data-kind=warn]{color:var(--warn-color-high,var(--warning-color,inherit));color:color-mix(in srgb,var(--warn-color-high,var(--warning-color,#b58900)) 35%,var(--text-color-high,CanvasText))}',
	'.vp-ov-state[data-kind=error]{color:var(--error-color-medium,var(--danger-color,inherit));color:color-mix(in srgb,var(--error-color-medium,var(--danger-color,#c62828)) 55%,var(--text-color-high,CanvasText))}',
	'.vp-ov-detail{margin:.3em 0 0;overflow-wrap:anywhere}',
	'.vp-ov-facts{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.3em 1em;margin:.7em 0 0;min-width:0}',
	'.vp-ov-facts dt{margin:0;font-weight:normal}',
	'.vp-ov-facts dd{margin:0;min-width:0;overflow-wrap:anywhere}',
	'.vp-ov-who{display:flex;flex-wrap:wrap;align-items:center;gap:.4em .8em;margin:.7em 0 0;min-width:0;overflow-wrap:anywhere}',
	'.vp-ov-alerts{margin:0 0 .8em}',
	// an alert = a card with a coloured edge; the words keep the theme's text colour (the theme's own
	// alert boxes are gradients: dark-theme red with dark text measured 3.3:1)
	'.vp-ov-alert{display:flex;flex-wrap:wrap;align-items:center;gap:.4em .8em;margin:0 0 .5em;border-left-width:.35em;overflow-wrap:anywhere}',
	'.vp-ov-alert[data-kind=warn]{border-left-color:var(--warn-color-high,var(--warning-color,#b58900))}',
	'.vp-ov-alert[data-kind=error]{border-left-color:var(--error-color-medium,var(--danger-color,#c62828))}',
	'.vp-ov-alert-text{flex:1 1 14em;min-width:0}',
	'.vp-ov-subs{display:grid;grid-template-columns:repeat(auto-fill,minmax(16em,1fr));gap:.6em;min-width:0}',
	'.vp-ov-sub-name{font-weight:bold;overflow-wrap:anywhere}',
	'.vp-ov-sub-facts{margin:.3em 0 0;overflow-wrap:anywhere}',
	'.vp-ov-sub-facts [data-kind=error]{color:var(--error-color-medium,var(--danger-color,inherit));color:color-mix(in srgb,var(--error-color-medium,var(--danger-color,#c62828)) 55%,var(--text-color-high,CanvasText))}',
	'.vp-ov-sub-facts [data-kind=warn]{color:var(--warn-color-high,var(--warning-color,inherit));color:color-mix(in srgb,var(--warn-color-high,var(--warning-color,#b58900)) 35%,var(--text-color-high,CanvasText))}',
	'.vp-ov-bar{height:.45em;margin:.45em 0 0;border-radius:.3em;overflow:hidden;background:var(--border-color-low,rgba(128,128,128,.25))}',
	'.vp-ov-bar>span{display:block;height:100%;background:var(--primary-color-high,var(--main-bright-color,Highlight))}',
	'.vp-ov-bar[data-kind=warn]>span{background:var(--warn-color-high,var(--warning-color,#b58900))}',
	'.vp-ov-links{margin:.6em 0 0}',
	'.vp-ov-dev-traffic{white-space:nowrap}',
	'@media (max-width:600px){',
	'.vp-ov-head>.btn{flex:1 1 auto}',
	'.vp-ov-who>.btn,.vp-ov-alert>.btn{flex:1 1 auto}',
	'.vp-ov-subs{grid-template-columns:minmax(0,1fr)}',
	'}'
].join('\n');

function injectCss() {
	if (document.getElementById('vpnpool-overview-css')) return;
	var st = document.createElement('style');
	st.id = 'vpnpool-overview-css';
	st.appendChild(document.createTextNode(CSS));
	(document.head || document.documentElement).appendChild(st);
}

function arr(v) { return Array.isArray(v) ? v : []; }
function setText(el, t) { t = (t == null) ? '' : String(t); if (el.textContent !== t) el.textContent = t; }
function link(label, path, cls) {
	return E('a', { 'class': 'btn cbi-button ' + (cls || 'cbi-button-neutral'), 'href': L.url.apply(L, path.split('/')) }, [ label ]);
}
// the node the traffic goes through now: the selector, or the automatic choice behind it
function activeTag(st) { return (st.active && st.active !== 'auto') ? st.active : (st.auto_now || ''); }
function nodeOf(st, tag) {
	var n = null;
	arr(st.nodes).forEach(function(x) { if (!n && x && x.tag === tag) n = x; });
	return n;
}
// has the user added anything (else: the wizard)
function isEmpty(st) {
	return !arr(st.nodes).length && !arr(st.subscriptions).length && !arr(st.favorites).length
		&& !arr(st.hidden).length && !arr(st.unreadable).length;
}
// a country name from its two-letter code, in the page's language (the code as is without Intl)
function countryName(code) {
	if (!code) return '';
	try {
		if (typeof Intl !== 'undefined' && Intl.DisplayNames) {
			var lang = (document.documentElement && document.documentElement.getAttribute('lang')) || undefined;
			var n = new Intl.DisplayNames(lang ? [ lang ] : undefined, { type: 'region' }).of(String(code).toUpperCase());
			if (n) return n;
		}
	} catch (e) {}
	return String(code).toUpperCase();
}
// is the VPN switched on: the user's switch, and no Telegram pause
function vpnOn(st) { return !!(st && st.enabled && !st.paused); }
function speed(n) { return _('%s/s').format(common.fmtBytes(n)); }

// ---- the state in words: ONE function, from the daemon's own facts ----
// enabled (the user's switch), running (the daemon), paused (Telegram /off), tunnel.state (the
// daemon's end-to-end check: starting | up | down | wan_down), routing (our routes are up),
// settings.killswitch (block what should go through the VPN while no node works)
function stateOf(st) {
	var set = st.settings || {};
	var tn = st.tunnel && st.tunnel.state;
	if (st.migration && st.migration.state === 'failed')
		return { t: _('Not started: the settings of the previous version could not be converted'), k: 'error',
			d: _('Nothing was changed. Open Diagnostics to see why.') };
	if (!st.enabled) return { t: _('VPN is off'), k: '', d: _('The internet goes directly, without the VPN.') };
	// (a Telegram pause outlives a restart of the service: then the button on the screen is
	// "Turn the VPN on", and the words name it)
	if (!st.running) return { t: _('VPN is on, but the service is not running'), k: 'error',
		d: st.paused ? _('Press "Turn the VPN on"; if it repeats, open Diagnostics.')
			: _('Turn the VPN off and on again; if it repeats, open Diagnostics.') };
	if (st.paused) return { t: _('Paused'), k: 'warn',
		d: _('Paused from Telegram: the internet goes directly, without the VPN. "Turn the VPN on" resumes it.') };
	if (tn === 'wan_down') return { t: _('The router has no internet'), k: 'error',
		d: (set.killswitch && st.routing) ? _('What should go through the VPN is blocked until the internet is back.') : _('Check the cable or the internet provider.') };
	if (tn === 'down') return { t: _('No node works'), k: 'error',
		d: (set.killswitch && st.routing)
			? _('What should go through the VPN is blocked until a node works (protection is on).')
			// the daemon takes the routes down after its second failed check (~15-30 s): until then
			// the traffic still goes into the tunnel
			: (st.routing ? _('If no node works again in a moment, what should go through the VPN goes directly.')
				: _('What should go through the VPN goes directly until a node works.')) };
	if (tn === 'up') return st.routing
		? { t: _('VPN works'), k: 'ok', d: (st.mode === 'exclude') ? _('Everything except the chosen sites') : _('Only the chosen sites') }
		: { t: _('The VPN works, but the traffic does not go through it'), k: 'error', d: _('The routes could not be set up. Open Diagnostics.') };
	if (!st.routing) return { t: _('Starting…'), k: '', d: _('Looking for a working node.') };
	return { t: _('VPN is on'), k: 'ok', d: _('Checking that the nodes work…') };
}

// ---- the alerts in words: ONE list from the status (the order is the order of importance) ----
function alertsOf(st) {
	var out = [];
	var nodes = arr(st.nodes);
	var b = st.build;
	if (b && b.ok === false && b.error === 'no_nodes')
		out.push({ k: 'error', t: _('There is not a single node: the subscriptions could not be downloaded or have no nodes.'), go: [ _('Nodes'), NODES ] });
	else if (b && b.ok === false && b.error && b.error !== 'interrupted' && b.error !== 'only_deferred')
		out.push({ k: 'error', t: _('The last update of the VPN settings failed; the previous ones keep working.'), go: [ _('Diagnostics'), DIAG ] });
	var dead = nodes.filter(function(n) { return n && n.dead && !n.kept && !n.deferred; });
	if (dead.length) {
		// the same answer as the Nodes cards (the node checker's last sweep, else the checked sites)
		var sites = common.failedSites(st, dead).sites;
		var t = (sites.length === 1)
			? N_(dead.length, '%d node does not open %s: it is left out of the automatic choice.', '%d nodes do not open %s: they are left out of the automatic choice.').format(dead.length, sites[0])
			: sites.length
				? N_(dead.length, '%d node fails the check of the sites (%s): it is left out of the automatic choice.', '%d nodes fail the check of the sites (%s): they are left out of the automatic choice.').format(dead.length, sites.join(', '))
				: N_(dead.length, '%d node fails the connection check: it is left out of the automatic choice.', '%d nodes fail the connection check: they are left out of the automatic choice.').format(dead.length);
		out.push({ k: 'warn', t: t, go: [ _('Nodes'), NODES ] });
	}
	var engine = nodes.filter(function(n) { return n && n.deferred && /^engine_/.test(String(n.reason || '')); });
	if (engine.length)
		out.push({ k: 'warn', t: N_(engine.length, '%d AmneziaWG node waits for the AmneziaWG engine: it starts working once the engine is installed.', '%d AmneziaWG nodes wait for the AmneziaWG engine: they start working once the engine is installed.').format(engine.length),
			go: [ _('How to install it'), DIAG ] });
	var aside = nodes.filter(function(n) { return n && n.deferred && n.reason === 'start_failed'; });
	if (aside.length)
		out.push({ k: 'warn', t: N_(aside.length, '%d node was set aside: the VPN engine could not start with it.', '%d nodes were set aside: the VPN engine could not start with them.').format(aside.length), go: [ _('Nodes'), NODES ] });
	var unr = arr(st.unreadable);
	if (unr.length)
		out.push({ k: 'warn', t: N_(unr.length, '%d AmneziaWG settings file could not be read.', '%d AmneziaWG settings files could not be read.').format(unr.length), go: [ _('Nodes'), NODES ] });
	arr(st.subscriptions).forEach(function(s) {
		common.subFacts(s).forEach(function(f) { if (f.alert) out.push({ k: f.k === 'error' ? 'error' : 'warn', t: f.alert, go: [ _('Nodes'), NODES ] }); });
	});
	if (st.running && nodes.length && !nodes.some(function(n) { return n && !n.deferred; }))
		out.push({ k: 'error', t: common.codeText('only_deferred'), go: [ _('Nodes'), NODES ] });
	return out;
}

var prevTraffic = null;

return view.extend({
	load: function() {
		return common.call('status', {}, { quiet: true }).catch(function(e) { return { __error: common.errorText(e) }; });
	},

	render: function(st) {
		var self = this;
		injectCss();
		prevTraffic = null;
		this.sigs = {};
		this.st = null;

		this.errLine = E('p', { 'class': 'vp-ov-err', 'role': 'alert', 'hidden': 'hidden' });
		this.wizard = common.emptyState({
			title: _('Add a subscription or a node'),
			text: _('Paste a subscription address, a node link or AmneziaWG settings on the Nodes tab. The VPN starts working as soon as there is a node.'),
			actions: []
		});
		var acts = this.wizard.querySelector('.vp-empty-actions') || this.wizard.appendChild(E('div', { 'class': 'vp-empty-actions' }));
		acts.appendChild(E('a', { 'class': 'btn cbi-button cbi-button-action important vp-ov-add', 'href': L.url.apply(L, NODES.split('/')) + '#add' }, [ _('+ Add') ]));
		acts.appendChild(link(_('Open Nodes'), NODES));
		this.wizard.hidden = true;

		// "Now"
		this.stateEl = E('div', { 'class': 'vp-ov-state', 'role': 'status' });
		this.toggleBtn = E('button', { 'class': 'btn cbi-button vp-ov-toggle', 'type': 'button',
			'click': ui.createHandlerFn(this, 'handleToggle') }, [ '' ]);
		this.detailEl = E('p', { 'class': 'vp-ov-detail' });
		this.facts = {};
		var dl = E('dl', { 'class': 'vp-ov-facts' });
		[ [ 'node', _('Node') ], [ 'exit', _('Exit') ], [ 'delay', _('Delay') ], [ 'speed', _('Speed') ] ].forEach(function(f) {
			var dt = E('dt', {}, [ f[1] ]), dd = E('dd', { 'class': 'vp-ov-' + f[0] });
			dl.appendChild(dt); dl.appendChild(dd);
			self.facts[f[0]] = { dt: dt, dd: dd };
		});
		this.factsEl = dl;
		this.whoText = E('span', { 'class': 'vp-ov-who-text' });
		this.autoBtn = E('button', { 'class': 'btn cbi-button cbi-button-action vp-ov-auto', 'type': 'button',
			'click': ui.createHandlerFn(this, 'handleAuto') }, [ _('Back to automatic choice') ]);
		this.whoEl = E('div', { 'class': 'vp-ov-who' }, [ this.whoText, this.autoBtn ]);
		this.nowEl = E('div', { 'class': 'cbi-section vp-card vp-ov-now' }, [
			E('div', { 'class': 'vp-ov-head' }, [ this.stateEl, this.toggleBtn ]),
			this.detailEl, this.factsEl, this.whoEl
		]);

		this.alertsEl = E('div', { 'class': 'vp-ov-alerts', 'aria-live': 'polite' });
		this.subsEl = E('div', { 'class': 'vp-ov-subs' });
		this.subsSec = E('div', { 'class': 'cbi-section vp-ov-subs-sec' }, [ E('h3', {}, [ _('Subscriptions') ]), this.subsEl,
			E('div', { 'class': 'vp-ov-links' }, [ link(_('All nodes'), NODES) ]) ]);
		this.devEl = E('div', { 'class': 'vp-devlist vp-ov-devices' });
		this.devSec = E('div', { 'class': 'cbi-section vp-ov-dev-sec' }, [ E('h3', {}, [ _('Traffic by device') ]), this.devEl ]);

		var root = E('div', { 'class': 'cbi-map vpnpool-view vp-page vp-ov' }, [
			common.header(_('VPN Pool — Overview')),
			this.errLine, this.wizard, this.nowEl, this.alertsEl, this.subsSec, this.devSec
		]);
		this.update(st);
		poll.add(L.bind(this.refresh, this), 5);
		poll.start();
		return root;
	},

	refresh: function() {
		var self = this;
		return common.call('status', {}, { quiet: true }).then(function(st) { self.update(st); }, function(e) {
			self.update({ __error: common.errorText(e) });
		});
	},

	// rebuild a list only when what it shows changed
	changed: function(key, v) {
		var s = JSON.stringify(v);
		if (this.sigs[key] === s) return false;
		this.sigs[key] = s;
		return true;
	},

	update: function(st) {
		if (!st || st.__error) {
			setText(this.errLine, (st && st.__error) || common.CODE_TEXT.failed);
			this.errLine.hidden = false;
			return;
		}
		this.errLine.hidden = true;
		this.st = st;
		var empty = isEmpty(st);
		this.wizard.hidden = !empty;
		this.updateNow(st);
		this.updateAlerts(empty ? [] : alertsOf(st));
		this.updateSubs(arr(st.subscriptions));
		this.subsSec.hidden = !arr(st.subscriptions).length;
		this.updateDevices(st);
	},

	updateNow: function(st) {
		var s = stateOf(st);
		setText(this.stateEl, s.t);
		this.stateEl.setAttribute('data-kind', s.k || '');
		setText(this.detailEl, s.d);
		this.detailEl.hidden = !s.d;
		// on = the VPN carries the traffic as far as the user's switches go: a Telegram pause is an
		// "off" too (enabled stays 1, the daemon runs), and "Turn the VPN on" ends it (power.sh on)
		var on = vpnOn(st);
		setText(this.toggleBtn, on ? _('Turn the VPN off') : _('Turn the VPN on'));
		this.toggleBtn.classList.toggle('cbi-button-negative', on);
		this.toggleBtn.classList.toggle('cbi-button-positive', !on);

		// the node / exit / speed / choice rows only while the traffic can go through the VPN
		var live = !!(on && st.running);
		var tag = live ? activeTag(st) : '';
		var n = tag ? nodeOf(st, tag) : null;
		var tunnelUp = !!(st.tunnel && st.tunnel.state === 'up');
		var ex = st.exit;
		var f = {
			node: tag || null,
			// the exit only while the tunnel works (exit.json outlives a dead tunnel); a lookup that
			// found nothing is said, not "being checked" forever
			exit: !(live && tunnelUp && tag) ? null
				: (ex && ex.ok !== false && ex.ip) ? (ex.country ? _('%s · %s').format(ex.ip, countryName(ex.country)) : ex.ip)
				: (ex && ex.ok === false) ? _('could not be determined: the address check services did not answer')
				: _('being checked…'),
			delay: (n && n.delay > 0) ? _('%d ms').format(n.delay) : null,
			speed: null
		};
		// the speed = the change of the totals between two polls
		var t = st.traffic || {}, now = Date.now();
		if (live) {
			if (prevTraffic && now > prevTraffic.time) {
				var dt = (now - prevTraffic.time) / 1000;
				var dn = Math.max(0, ((+t.down_total || 0) - prevTraffic.down) / dt);
				var up = Math.max(0, ((+t.up_total || 0) - prevTraffic.up) / dt);
				f.speed = _('↓ %s ↑ %s · connections: %d').format(speed(dn), speed(up), +t.connections || 0);
			}
			prevTraffic = { time: now, down: +t.down_total || 0, up: +t.up_total || 0 };
		} else prevTraffic = null;
		var self = this;
		Object.keys(this.facts).forEach(function(k) {
			var F = self.facts[k];
			setText(F.dd, f[k]);
			F.dt.hidden = F.dd.hidden = (f[k] == null);
		});
		this.factsEl.hidden = Object.keys(f).every(function(k) { return f[k] == null; });

		// automatic choice / the node chosen by the user (the soft choice of "Connect")
		var pref = live ? st.preferred : null, who = '';
		if (pref && pref.id) {
			who = (pref.in_pool === false)
				? _('Chosen by you: %s. It is not among the nodes now, so the automatic choice works.').format(pref.tag || '')
				: _('Connected to %s: chosen by you. If it stops working, the automatic choice takes over until it is back.').format(pref.tag || '');
		} else if (live) who = _('Automatic choice: the best working node is used.');
		setText(this.whoText, who);
		this.autoBtn.hidden = !(pref && pref.id);
		this.whoEl.hidden = !who;
	},

	updateAlerts: function(list) {
		if (!this.changed('alerts', list)) return;
		dom.content(this.alertsEl, list.map(function(a) {
			return E('div', { 'class': 'vp-card vp-ov-alert', 'data-kind': a.k, 'role': a.k === 'error' ? 'alert' : null }, [
				E('span', { 'class': 'vp-ov-alert-text' }, [ a.t ]),
				a.go ? link(a.go[0], a.go[1]) : ''
			]);
		}));
		this.alertsEl.hidden = !list.length;
	},

	updateSubs: function(subs) {
		var view = subs.map(function(s) {
			return { name: s.name || _('Subscription'), facts: common.subFacts(s).map(function(f) { return { t: f.t, k: f.k || '' }; }),
				nodes: +s.in_pool || 0, total: +s.total || 0, used: +s.used || 0 };
		});
		if (!this.changed('subs', view)) return;
		dom.content(this.subsEl, view.map(function(v) {
			var kids = [];
			v.facts.forEach(function(f, i) {
				if (i) kids.push(' · ');
				kids.push(E('span', { 'data-kind': f.k || null }, [ f.t ]));
			});
			var bar = '';
			if (v.total > 0) {
				var pct = Math.max(0, Math.min(100, Math.round((v.total - v.used) * 100 / v.total)));
				bar = E('div', { 'class': 'vp-ov-bar', 'data-kind': pct <= 10 ? 'warn' : null, 'role': 'img',
					'aria-label': _('Traffic left: %d%%').format(pct) }, [ E('span', { 'style': 'width:' + pct + '%' }) ]);
			}
			return E('div', { 'class': 'vp-card vp-ov-sub' }, [
				E('div', { 'class': 'vp-ov-sub-name' }, [ v.name ]),
				E('div', { 'class': 'vp-ov-sub-count' }, [ N_(v.nodes, '%d node in use', '%d nodes in use').format(v.nodes) ]),
				E('div', { 'class': 'vp-ov-sub-facts' }, kids),
				bar
			]);
		}));
	},

	// traffic per device (LAN client), the biggest first (status.uc: top 30, from the open
	// connections); the name from the DHCP leases, else the address
	updateDevices: function(st) {
		var live = !!(st.enabled && st.running);
		var view = live ? arr(st.client_traffic).map(function(c) {
			return { name: c.host || c.ip || '?', ip: (c.host && c.ip) ? c.ip : '', down: +c.down || 0, up: +c.up || 0, conns: +c.conns || 0 };
		}) : null;
		if (!this.changed('devices', view)) return;
		if (!view) { dom.content(this.devEl, [ E('p', { 'class': 'vp-hint' }, [ _('The VPN is not running: there is no traffic to show.') ]) ]); return; }
		if (!view.length) { dom.content(this.devEl, [ E('p', { 'class': 'vp-hint' }, [ _('No device uses the internet through the router right now.') ]) ]); return; }
		dom.content(this.devEl, view.map(function(v) {
			return E('div', { 'class': 'vp-dev vp-ov-dev' }, [
				E('span', { 'class': 'vp-dev-name' }, [ v.name ]),
				v.ip ? E('span', { 'class': 'vp-dev-meta' }, [ v.ip ]) : '',
				E('span', { 'class': 'vp-dev-meta vp-ov-dev-traffic' }, [ _('↓ %s ↑ %s').format(common.fmtBytes(v.down), common.fmtBytes(v.up)) ]),
				E('span', { 'class': 'vp-dev-meta' }, [ N_(v.conns, '%d connection', '%d connections').format(v.conns) ])
			]);
		}));
	},

	// on/off: wait for the daemon's answer (status) instead of a blind timer
	handleToggle: function() {
		var self = this, st = this.st || {};
		var target = !vpnOn(st);
		return common.call('set_enabled', { enabled: target }).then(function(r) {
			common.toast(target ? _('Turning the VPN on…') : _('Turning the VPN off…'));
			return common.waitFor(function(s) { self.update(s); return target ? (vpnOn(s) && !!s.running) : (!s.enabled && !s.running); },
				{ timeout: target ? 45000 : 20000, interval: 1500 }).then(function() {
				common.toast(common.codeText(r && r.code) || (target ? common.CODE_TEXT.on : common.CODE_TEXT.off));
			}, function(e) {
				if (e instanceof common.Error && e.code === 'timeout')
					common.toast(target ? _('The VPN is switched on, but the service has not started yet. The state above shows when it does.')
						: _('The VPN is switched off, but the service has not stopped yet. The state above shows when it does.'), 'warning', 'set_enabled');
				else throw e;
			});
		}).then(function() { return self.refresh(); }, function() { return self.refresh(); });
	},

	handleAuto: function() {
		var self = this;
		return common.call('auto_select', {}, { success: _('Back to automatic choice.') }).then(function() { return self.refresh(); }, function() {});
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
