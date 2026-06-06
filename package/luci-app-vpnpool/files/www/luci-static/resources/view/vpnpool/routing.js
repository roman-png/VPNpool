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

	load: function() { return callStatus(); },
	render: function(st) {
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

		return E('div', { 'class': 'cbi-map' }, [
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
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
