'use strict';
'require view';
'require form';
'require dom';
'require vpnpool.common as common';

// "Routes" page (ROADMAP-2.0 §10.4): what goes through the VPN. One form.JSONMap and ONE save
// for the whole page (common.formSaver -> one set_config with the changed fields only): the
// mode (two cards), the ready-made site lists by group, your own sites (+ "A site does not
// open?" and the automatic search), and which devices of the network use the VPN.
// SAFETY: LuCI puts option titles and descriptions into innerHTML, so only our own texts go
// there; device names (DHCP, foreign data) are shown as text nodes by the device list widget.

// LuCI E(tag, attrs, 'string') = innerHTML; every string child goes in as text (common.E)
var E = common.E;
var txt = common.txt;

// Ready-made lists (the community lists the router downloads and keeps up to date), by group:
// [ key, title, description ]
var LIST_GROUPS = [
	{ id: 'countries', title: _('Ready-made lists: by country'), items: [
		[ 'russia_inside', _('Blocked in Russia'), _('Blocked sites, and foreign services that are closed to Russia themselves. Includes most of the lists below.') ],
		[ 'russia_outside', _('Russian sites from abroad'), _('Russian sites that open only from a Russian address. For a router outside Russia with a node in Russia.') ]
	] },
	{ id: 'categories', title: _('Ready-made lists: by kind'), items: [
		[ 'block', _('Blocked sites'), _('Sites the providers block on the authorities\' demand.') ],
		[ 'geoblock', _('Services closed to Russia'), _('Foreign services that do not open from Russian addresses themselves.') ],
		[ 'news', _('News'), _('News sites and media.') ],
		[ 'anime', _('Anime'), _('Anime sites.') ],
		[ 'porn', _('Adult sites'), null ],
		[ 'hdrezka', 'HDRezka', _('Online cinema.') ]
	] },
	{ id: 'services', title: _('Ready-made lists: services'), items: [
		[ 'youtube', 'YouTube', null ],
		[ 'telegram', 'Telegram', null ],
		[ 'discord', 'Discord', null ],
		[ 'meta', 'Instagram, Facebook, WhatsApp', null ],
		[ 'twitter', 'X (Twitter)', null ],
		[ 'tiktok', 'TikTok', null ],
		[ 'google_ai', _('Google AI (Gemini)'), _('Google AI services, which Google closes to Russia.') ],
		[ 'google_play', 'Google Play', null ],
		[ 'google_meet', 'Google Meet', null ],
		[ 'roblox', 'Roblox', null ]
	] },
	{ id: 'hosting', title: _('Ready-made lists: hosting providers'),
	  descr: _('Addresses of large hosting providers. Turn them on only if sites hosted there do not open: these lists are big.'), items: [
		[ 'hodca', _('All large hosting providers'), _('Hetzner, OVH, DigitalOcean, Cloudflare, Amazon and Akamai together.') ],
		[ 'cloudflare', 'Cloudflare', null ],
		[ 'cloudfront', 'Amazon CloudFront', null ],
		[ 'digitalocean', 'DigitalOcean', null ],
		[ 'hetzner', 'Hetzner', null ],
		[ 'ovh', 'OVH', null ]
	] }
];

var COMMUNITY_OPT = {};
LIST_GROUPS.forEach(function(g) {
	g.items.forEach(function(it) { COMMUNITY_OPT[it[0]] = 'l_' + g.id + '.' + it[0]; });
});

function lc(s) { return String(s == null ? '' : s).toLowerCase(); }
function settings(st) { return (st && st.settings) || {}; }

// The page's settings: set_config field <-> form option (common.formSaver, kinds there).
var FIELDS = [
	{ f: 'mode', o: 'mode.mode', t: 'str', v: function(st) { return st.mode === 'exclude' ? 'exclude' : 'selective'; } },
	{ f: 'communities', o: COMMUNITY_OPT, t: 'set', at: 'l_countries.russia_inside', label: _('Ready-made lists'),
	  v: function(st) { return Array.isArray(st.communities) ? st.communities : []; } },
	{ f: 'domains', o: 'sites.domains', t: 'lines', v: function(st) { return Array.isArray(st.domains) ? st.domains : []; } },
	{ f: 'adaptive_routing', o: 'sites.adaptive_routing', t: 'bool', v: function(st) { return !!settings(st).adaptive_routing; } },
	{ f: 'auto_domains', o: 'sites.auto_domains', t: 'lines', v: function(st) { return Array.isArray(st.auto_domains) ? st.auto_domains : []; } },
	{ f: 'client_mode', o: 'devices.client_mode', t: 'str', v: function(st) { return settings(st).client_mode || 'all'; } },
	{ f: 'client_devices', o: 'devices.client_devices', t: 'list', v: function(st) { return (st.client_devices || []).map(lc); } },
	{ f: 'clients', o: 'devices.clients', t: 'lines', v: function(st) { return Array.isArray(st.clients) ? st.clients : []; } }
];

// A site as typed -> its name (the router does the same), or null
function siteName(v) {
	var s = lc(String(v == null ? '' : v).trim());
	s = s.replace(/^[a-z][a-z0-9+.\-]*:\/\//, '').replace(/[\/?#].*$/, '').replace(/:[0-9]+$/, '')
		.replace(/^\*?\./, '').replace(/\.$/, '');
	if (!s || s.length > 253) return null;
	var parts = s.split('.');
	for (var i = 0; i < parts.length; i++)
		if (!/^[a-z0-9_]([a-z0-9_\-]{0,61}[a-z0-9_])?$/.test(parts[i])) return null;
	return s;
}

// A choice of a radio-card option: a bold title and a line under it (our own texts)
function card(title, text) {
	return E('span', { 'class': 'vp-card-text' }, [ E('b', {}, [ txt(title) ]), E('small', {}, [ txt(text) ]) ]);
}

// ListValue shown as radio cards
var Cards = form.ListValue.extend({
	renderWidget: function(section_id, option_index, cfgvalue) {
		var n = form.ListValue.prototype.renderWidget.apply(this, [ section_id, option_index, cfgvalue ]);
		if (n && n.classList) n.classList.add('vp-cards');
		return n;
	}
});

// A line of explanation (our own text) between the options
var Hint = form.DummyValue.extend({
	renderWidget: function() {
		return E('p', { 'class': 'vp-hint' }, [ txt(this.hint || '') ]);
	}
});

// Devices of the network: DHCP leases + saved devices that are offline now (matched by the
// hardware address, so a device keeps its choice when its IP address changes). The value is
// the list of the chosen hardware addresses. Names come from the devices: text nodes only.
var DeviceList = form.Value.extend({
	renderWidget: function(section_id, option_index, cfgvalue) {
		var on = {};
		(Array.isArray(cfgvalue) ? cfgvalue : []).forEach(function(m) { on[lc(m)] = true; });
		var rows = (this.devices || []).map(function(d) {
			var meta = [ d.ip, d.mac.toUpperCase() ].filter(function(x) { return x; }).join(' · ') + (d.offline ? ' · ' + _('not on the network now') : '');
			return E('label', { 'class': 'vp-dev' }, [
				E('input', { 'type': 'checkbox', 'class': 'vp-dev-cb', 'value': d.mac, 'checked': on[d.mac] ? 'checked' : null }),
				E('span', { 'class': 'vp-dev-name' }, [ txt(d.host || d.ip || d.mac.toUpperCase()) ]),
				E('span', { 'class': 'vp-dev-meta' }, [ txt(meta) ])
			]);
		});
		return E('div', { 'class': 'vp-devlist', 'id': this.cbid(section_id) },
			rows.length ? rows : [ E('p', { 'class': 'vp-hint' }, [ txt(_('No devices have been seen on the network yet. Add them by address below.')) ]) ]);
	},
	formvalue: function(section_id) {
		var n = this.map.findElement('id', this.cbid(section_id));
		if (!n) return this.cfgvalue(section_id) || [];
		return Array.prototype.filter.call(n.querySelectorAll('input'), function(c) { return c.type === 'checkbox' && c.checked; })
			.map(function(c) { return c.value; });
	}
});

// An input + a button (not a setting itself)
var Action = form.DummyValue.extend({
	renderWidget: function(section_id) {
		return this.build(section_id);
	}
});

function deviceList(st, leases) {
	var seen = {}, out = [];
	(leases || []).forEach(function(l) {
		var mac = lc(l && l.mac);
		if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac) || seen[mac]) return;
		seen[mac] = true;
		out.push({ mac: mac, ip: l.ip || '', host: l.host || l.hostname || '' });
	});
	(st.client_devices || []).forEach(function(m) {
		var mac = lc(m);
		if (seen[mac]) return;
		seen[mac] = true;
		out.push({ mac: mac, ip: '', host: '', offline: true });
	});
	return out;
}

return view.extend({
	FIELDS: FIELDS,
	siteName: siteName,

	load: function() {
		return Promise.all([
			common.call('status'),
			common.call('leases', {}, { quiet: true }).catch(function() { return {}; })
		]);
	},

	// "A site does not open?": the site goes into "Your sites" (saved with the page)
	addSite: function(input, msg) {
		var d = siteName(input.value);
		var r = this.map.lookupOption('domains', 'sites');
		var w = r && r[0].getUIElement(r[1]);
		if (!d) { msg.textContent = common.fieldText('bad_domain'); return false; }
		if (!w) return false;
		var cur = String(w.getValue() || '').split(/\r?\n/).map(function(x) { return x.trim(); }).filter(Boolean);
		if (cur.map(siteName).indexOf(d) >= 0) { msg.textContent = _('This site is already in the list.'); return false; }
		cur.push(d);
		w.setValue(cur.join('\n'));
		input.value = '';
		msg.textContent = _('Added to your sites. Press "Save" to apply.');
		if (this.saver) this.saver.update();
		return true;
	},

	render: function(data) {
		var self = this;
		var st = (data && data[0]) || {};
		var leases = (data && data[1] && Array.isArray(data[1].leases)) ? data[1].leases : [];
		var fd = common.formData(FIELDS, st);
		var m = new form.JSONMap(fd, null, null);
		var s, o;

		// ---- the mode
		s = m.section(form.NamedSection, 'mode', 'mode', _('What goes through the VPN'));
		o = s.option(Cards, 'mode', '');
		o.widget = 'radio';
		o.orientation = 'vertical';
		o.value('selective', card(_('Only the chosen sites'),
			_('The ready-made lists and your sites go through the VPN, everything else goes directly. Faster, and saves the VPN traffic.')));
		o.value('exclude', card(_('Everything except the chosen sites'),
			_('All traffic goes through the VPN; the ready-made lists and your sites go directly.')));

		// ---- ready-made lists, by group
		LIST_GROUPS.forEach(function(g, gi) {
			s = m.section(form.NamedSection, 'l_' + g.id, 'lists', g.title, g.descr || null);
			if (gi === 0) {
				o = s.option(Hint, 'hint_sel', '');
				o.hint = _('The chosen lists go through the VPN. They are kept up to date automatically.');
				o.depends('json.mode.mode', 'selective');
				o = s.option(Hint, 'hint_exc', '');
				o.hint = _('The chosen lists go directly, past the VPN. They are kept up to date automatically.');
				o.depends('json.mode.mode', 'exclude');
			}
			g.items.forEach(function(it) {
				o = s.option(form.Flag, it[0], it[1], it[2] || null);
				o.default = '0';
			});
		});

		// ---- your sites
		s = m.section(form.NamedSection, 'sites', 'sites', _('Your sites'));
		o = s.option(Hint, 'hint_sel', '');
		o.hint = _('Your sites go through the VPN.');
		o.depends('json.mode.mode', 'selective');
		o = s.option(Hint, 'hint_exc', '');
		o.hint = _('Your sites go directly, past the VPN.');
		o.depends('json.mode.mode', 'exclude');
		o = s.option(form.TextValue, 'domains', _('Sites'), _('One per line, for example example.com. Subdomains are included too.'));
		o.rows = 6;
		o.placeholder = 'example.com';
		o = s.option(Action, 'site_help', _('A site does not open?'));
		o.build = function() {
			var inp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'example.com', 'aria-label': _('Site address') });
			var msg = E('div', { 'class': 'vp-hint', 'aria-live': 'polite' }, [ txt('') ]);
			var add = function(ev) { if (ev) ev.preventDefault(); self.addSite(inp, msg); };
			inp.addEventListener('keydown', function(ev) { if (ev.key === 'Enter') add(ev); });
			return E('div', {}, [
				E('div', { 'class': 'vp-inline' }, [ inp,
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'type': 'button', 'click': add }, [ txt(_('Add to your sites')) ]) ]),
				msg
			]);
		};
		o = s.option(Hint, 'help_sel', '');
		o.hint = _('Enter its address: it will go through the VPN. If it still does not open, check the nodes: the site may be closed for the current node.');
		o.depends('json.mode.mode', 'selective');
		o = s.option(Hint, 'help_exc', '');
		o.hint = _('Enter its address: it will go directly, past the VPN. This helps with sites that do not open from abroad.');
		o.depends('json.mode.mode', 'exclude');
		o = s.option(form.Flag, 'adaptive_routing', _('Find blocked sites automatically'),
			_('The router checks which sites do not open directly and sends them through the VPN, in any mode. They appear in the list below.'));
		// the router searches only with the SAVED setting: until then, say so instead of a button
		var adaptiveSaved = !!settings(st).adaptive_routing;
		o = s.option(Action, 'adaptive_run', '');
		o.build = function() {
			if (!adaptiveSaved)
				return E('p', { 'class': 'vp-hint' }, [ txt(_('Save the page first: then the search can be started right away.')) ]);
			return E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button', 'click': function(ev) {
				ev.preventDefault();
				common.call('run_adaptive', {}, { success: _('The search has started. Found sites appear in the list when the page is opened again.') }).catch(function() {});
			} }, [ txt(_('Search now')) ]);
		};
		o.depends('adaptive_routing', '1');
		// generator: the found sites go through the VPN only while the search is on
		o = s.option(form.TextValue, 'auto_domains', _('Found automatically'),
			_('While the automatic search is on, these sites go through the VPN in any mode. Delete a line to remove a site.'));
		o.rows = 4;

		// ---- devices
		s = m.section(form.NamedSection, 'devices', 'devices', _('Devices'));
		o = s.option(Cards, 'client_mode', '');
		o.widget = 'radio';
		o.orientation = 'vertical';
		o.value('all', card(_('All devices of the network'), _('Every device uses the routes above.')));
		o.value('include', card(_('Only the chosen devices'), _('The chosen devices use the routes above; the others go directly, past the VPN.')));
		o.value('exclude', card(_('All except the chosen devices'), _('The chosen devices go directly, past the VPN; the others use the routes above.')));
		o = s.option(DeviceList, 'client_devices', _('Chosen devices'));
		o.devices = deviceList(st, leases);
		o.depends('client_mode', 'include');
		o.depends('client_mode', 'exclude');
		o = s.option(form.TextValue, 'clients', _('Other addresses'),
			_('Addresses like 192.168.1.50, one per line: for devices with a fixed address that are not in the list above.'));
		o.rows = 3;
		o.placeholder = '192.168.1.50';
		o.depends('client_mode', 'include');
		o.depends('client_mode', 'exclude');

		return m.render().then(function(mapNode) {
			self.map = m;
			self.saver = common.formSaver({ fields: FIELDS, maps: [ m ], onSaved: function() { return self.reload(); },
				prepare: function(ch) { return self.mergeFound(ch); } });
			var box = self.box || (self.box = E('div', { 'class': 'vp-page' }));
			dom.content(box, [
				common.header(_('Routes')),
				E('p', { 'class': 'vp-hint' }, [ txt(_('Choose what goes through the VPN. Changes apply after "Save".')) ]),
				mapNode,
				self.saver.bar()
			]);
			return box;
		});
	},

	// "Found automatically" edited: the automatic search may have added sites since the page was
	// loaded. Right before the save the list is read again and the user's edit is applied to it
	// (what they deleted goes, what they added comes), so a site found meanwhile is not wiped out.
	mergeFound: function(ch) {
		if (!ch || !Object.prototype.hasOwnProperty.call(ch, 'auto_domains')) return ch;
		var base = (this.saver && this.saver.base && this.saver.base.auto_domains) || [];
		var cur = Array.isArray(ch.auto_domains) ? ch.auto_domains : [];
		return common.call('status', {}, { quiet: true }).then(function(st) {
			var fresh = (st && Array.isArray(st.auto_domains)) ? st.auto_domains : base;
			var out = [];
			var put = function(d) { if (out.indexOf(d) < 0) out.push(d); };
			fresh.forEach(function(d) { if (base.indexOf(d) < 0 || cur.indexOf(d) >= 0) put(d); });
			cur.forEach(function(d) { if (base.indexOf(d) < 0) put(d); });
			var res = {};
			Object.keys(ch).forEach(function(k) { res[k] = ch[k]; });
			res.auto_domains = out;
			return res;
		});
	},

	// after a save: the page again from the router's answer (normalised values, new state)
	reload: function() {
		var self = this;
		return this.load().then(function(d) { return self.render(d); });
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
