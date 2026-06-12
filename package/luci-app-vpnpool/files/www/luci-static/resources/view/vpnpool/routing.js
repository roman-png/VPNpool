'use strict';
'require view';
'require rpc';
'require ui';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callStatus       = rpc.declare({ object: 'vpnpool', method: 'status' });
var callSetOpt       = rpc.declare({ object: 'vpnpool', method: 'set_option',     params: [ 'name', 'value' ] });
var callSetDomains   = rpc.declare({ object: 'vpnpool', method: 'set_domains',    params: [ 'domains' ] });
var callSetCommunities = rpc.declare({ object: 'vpnpool', method: 'set_communities', params: [ 'communities' ] });
var callSetClients = rpc.declare({ object: 'vpnpool', method: 'set_clients', params: [ 'mode', 'clients', 'devices' ] });
var callLeases     = rpc.declare({ object: 'vpnpool', method: 'leases' });

// itdoginfo/allow-domains community lists (SRS release assets)
var COMMUNITIES = [
	'russia_inside', 'russia_outside', 'ukraine_inside', 'telegram', 'meta', 'twitter',
	'youtube', 'discord', 'tiktok', 'hdrezka', 'anime', 'news', 'block', 'porn',
	'geoblock', 'google_ai', 'google_play', 'google_meet', 'hodca', 'cloudflare',
	'cloudfront', 'digitalocean', 'hetzner', 'ovh', 'roblox'
];

return view.extend({
	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },

	handleSaveMode: function(sel) {
		return callSetOpt('mode', sel.value).then(L.bind(function() {
			this.notify(_('Routing mode saved and applied.'));
		}, this));
	},
	handleSaveCommunities: function() {
		var chosen = COMMUNITIES.filter(function(c) {
			var el = document.getElementById('comm-' + c);
			return el && el.checked;
		});
		return callSetCommunities(chosen).then(L.bind(function() {
			this.notify(_('Community lists saved and applied.'));
		}, this));
	},
	handleSaveDomains: function(box) {
		var list = (box.value || '').split(/\r?\n/).map(function(s) { return s.trim(); }).filter(function(s) { return s.length; });
		return callSetDomains(list).then(L.bind(function() { this.notify(_('Domains saved and applied.')); }, this));
	},
	handleSaveClients: function(sel, devChecks, box) {
		// MAC profiles from the device picker + any raw IPs typed manually.
		var devices = (devChecks || []).filter(function(d) { return d.el.checked; }).map(function(d) { return d.mac; });
		var ips = (box.value || '').split(/\r?\n/).map(function(s) { return s.trim(); }).filter(function(s) { return s.length; });
		return callSetClients(sel.value, ips, devices).then(L.bind(function() { this.notify(_('Per-client routing saved and applied.')); }, this));
	},

	load: function() { return Promise.all([ callStatus(), callLeases().catch(function() { return {}; }) ]); },
	render: function(data) {
		var st = data[0] || {};
		// `leases` rpc returns an OBJECT { leases: [...] } (rpcd rejects a bare array).
		var leases = (data[1] && data[1].leases) || [];
		var selectedComm = {};
		(st.communities || []).forEach(function(c) { selectedComm[c] = true; });
		var mode = (st.settings && st.mode) ? st.mode : (st.mode || 'selective');

		var modeSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'selective', 'selected': (mode !== 'exclude') ? 'selected' : null }, _('Proxy only the selected lists/domains (rest direct)')),
			E('option', { 'value': 'exclude',   'selected': (mode === 'exclude') ? 'selected' : null }, _('Proxy everything EXCEPT the selected lists/domains'))
		]);

		var checks = COMMUNITIES.map(function(c) {
			return E('label', { 'style': 'display:inline-block;width:200px;margin:3px 0' }, [
				E('input', { 'type': 'checkbox', 'id': 'comm-' + c, 'checked': selectedComm[c] ? 'checked' : null,
					'style': 'margin-right:6px' }),
				c
			]);
		});

		var domBox = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%;height:140px' }, (st.domains || []).join('\n'));

		var clMode = (st.settings && st.settings.client_mode) || 'all';
		var clSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'all',     'selected': clMode === 'all'     ? 'selected' : null }, _('All LAN clients')),
			E('option', { 'value': 'exclude', 'selected': clMode === 'exclude' ? 'selected' : null }, _('All except the listed clients (listed bypass VPN)')),
			E('option', { 'value': 'include', 'selected': clMode === 'include' ? 'selected' : null }, _('Only the listed clients use the VPN'))
		]);
		// Device picker: current DHCP leases + any saved-but-offline MACs, so a profile
		// is never lost just because the device is off. Matched by MAC (stable across
		// DHCP renewals). Manual IPv4 entry stays for static/unknown hosts.
		var savedMacs = (st.client_devices || []);
		var savedSet = {}; savedMacs.forEach(function(m) { savedSet[String(m).toLowerCase()] = true; });
		var leasedSet = {}; leases.forEach(function(l) { leasedSet[String(l.mac).toLowerCase()] = true; });
		var offline = savedMacs.filter(function(m) { return !leasedSet[String(m).toLowerCase()]; })
			.map(function(m) { return { mac: m, ip: '', host: '', offline: true }; });
		var devList = leases.concat(offline);
		var devChecks = [];
		var devRows = devList.length ? devList.map(function(d) {
			var cb = E('input', { 'type': 'checkbox', 'style': 'margin-right:8px',
				'checked': savedSet[String(d.mac).toLowerCase()] ? 'checked' : null });
			devChecks.push({ el: cb, mac: d.mac });
			var name = d.host || d.ip || d.mac;
			var meta = [ d.ip, d.mac ].filter(function(s) { return s; }).join(' · ') + (d.offline ? ' · ' + _('offline') : '');
			return E('label', { 'style': 'display:flex;align-items:baseline;padding:3px 0' }, [
				cb,
				E('span', {}, [ E('b', {}, name), E('span', { 'style': 'color:#888;margin-left:8px;font-size:90%' }, meta) ])
			]);
		}) : [ E('p', { 'style': 'color:#888;margin:4px 0' }, _('No devices seen yet (DHCP leases are empty).')) ];
		var clBox = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%;height:70px', 'placeholder': '192.168.1.50' }, (st.clients || []).join('\n'));

		return E('div', { 'class': 'cbi-map vpnpool-view' }, [
			i18n.header(_('VPN Pool — Routing')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Routing mode')),
				modeSel,
				E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px',
					'click': ui.createHandlerFn(this, 'handleSaveMode', modeSel) }, _('Save mode'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Community lists (itdoginfo/allow-domains, auto-updated SRS)')),
				E('div', {}, checks),
				E('div', { 'style': 'margin-top:8px' }, E('button', { 'class': 'btn cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, 'handleSaveCommunities') }, _('Save lists')))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Custom domains (one per line)')),
				domBox,
				E('div', { 'style': 'margin-top:6px' }, E('button', { 'class': 'btn cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, 'handleSaveDomains', domBox) }, _('Save domains')))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Per-client routing')),
				clSel,
				E('p', { 'style': 'color:#888;margin:6px 0 2px' }, _('Devices on the network (matched by MAC — survives IP changes):')),
				E('div', { 'style': 'max-height:240px;overflow:auto;padding:4px 6px;border:1px solid rgba(128,128,128,.3);border-radius:6px' }, devRows),
				E('p', { 'style': 'color:#888;margin:8px 0 2px' }, _('Extra IPv4 addresses, one per line (for static / unknown hosts):')),
				clBox,
				E('div', { 'style': 'margin-top:6px' }, E('button', { 'class': 'btn cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, 'handleSaveClients', clSel, devChecks, clBox) }, _('Save per-client')))
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
