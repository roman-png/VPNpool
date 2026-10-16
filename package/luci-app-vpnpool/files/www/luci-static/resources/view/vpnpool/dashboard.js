'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require vpnpool.i18n as i18n';
'require vpnpool.common as common';

var _ = function(s) { return i18n.tr(s); };
// LuCI E(tag, attrs, 'string') = innerHTML; node names and reply fields are foreign data,
// so every string child goes in as text (common.E)
var E = common.E;

var callStatus     = rpc.declare({ object: 'vpnpool', method: 'status' });
var callSetEnabled = rpc.declare({ object: 'vpnpool', method: 'set_enabled', params: [ 'enabled' ] });
var callRefresh    = rpc.declare({ object: 'vpnpool', method: 'refresh' });

// The node list, the import and every node action live on the Nodes tab (view/vpnpool/nodes.js);
// this page keeps the state of the service, the subscription line and the traffic per device.
function fmtExpire(ts) {
	if (!ts) return _('unknown');
	var days = Math.floor((ts * 1000 - Date.now()) / 86400000);
	return new Date(ts * 1000).toLocaleDateString() + ' (' + (days >= 0 ? days + ' ' + _('days') : _('expired')) + ')';
}
function badge(text, color) {
	return E('span', { 'style': 'display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;color:#fff;background:' + color + ';margin-right:6px' }, text);
}
function fmtBytes(n) {
	n = n || 0;
	if (n < 1024) return n.toFixed(0) + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
	return (n / 1073741824).toFixed(2) + ' GB';
}
var prevTraffic = null;


return view.extend({
	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },
	handleToggle: function(cur) {
		ui.showModal(_('Please wait'), [ E('p', { 'class': 'spinning' }, cur ? _('Stopping…') : _('Starting…')) ]);
		return callSetEnabled(!cur).then(L.bind(function() {
			window.setTimeout(L.bind(function() { ui.hideModal(); this.refresh(); }, this), cur ? 2500 : 15000);
		}, this));
	},
	handleRefresh: function() {
		ui.addNotification(null, E('p', _('Updating subscription…')), 'info');
		return callRefresh().then(L.bind(function() { window.setTimeout(L.bind(this.refresh, this), 12000); }, this));
	},
	refresh: function() {
		return callStatus().then(L.bind(function(st) {
			this._st = st;
			var a = document.getElementById('vp-status'), c = document.getElementById('vp-clients');
			if (a) dom.content(a, this.renderStatus(st));
			if (c) dom.content(c, this.renderClients(st));
		}, this));
	},

	renderStatus: function(st) {
		var on = st.enabled && st.running;
		var using = (st.active === 'auto' || !st.active) ? (st.auto_now || '—') : st.active;

		// Auto mode = no HARD manual pick (selected_node). A preferred soft-pin (📌)
		// biases the live target but stays in auto, so the AUTO indicator must stay lit.
		var hardPick = (st.settings || {}).selected_node || '';
		var preferredTag = (st.settings || {}).preferred_node || '';
		var autoMode = !hardPick;
		// traffic speed = delta of totals between polls
		var t = st.traffic || {};
		var now = Date.now(), dn = 0, up = 0;
		if (prevTraffic && now > prevTraffic.time) {
			var dt = (now - prevTraffic.time) / 1000;
			dn = Math.max(0, ((t.down_total || 0) - prevTraffic.down) / dt);
			up = Math.max(0, ((t.up_total || 0) - prevTraffic.up) / dt);
		}
		prevTraffic = { time: now, down: t.down_total || 0, up: t.up_total || 0 };

		// subscription expiry color
		var exp = st.subscription && st.subscription.expire;
		var days = exp ? Math.floor((exp * 1000 - Date.now()) / 86400000) : null;
		var expColor = (days != null && days < 7) ? '#cc3333' : (days != null && days < 30 ? '#e08a00' : '');

		var kids = [
			E('div', { 'style': 'display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:8px' }, [
				E('button', { 'class': 'btn cbi-button ' + (on ? 'cbi-button-negative' : 'cbi-button-positive'),
					'click': ui.createHandlerFn(this, 'handleToggle', st.enabled) }, on ? _('Turn OFF') : _('Turn ON')),
				on ? badge(_('running'), '#2e7d32') : badge(_('stopped'), '#888'),
				st.routing ? badge(_('routing up'), '#2e7d32') : badge(_('no routing'), '#888'),
				badge(st.mode === 'exclude' ? _('all except lists') : _('only lists'), '#1565c0')
			]),
			E('div', { 'style': 'margin:4px 0' }, [ E('b', {}, _('Active node') + ': '), E('span', {}, using),
				autoMode ? E('span', { 'style': 'color:#888' }, ' (' + _('automatic choice') + (preferredTag ? ' · 📌 ' + (using||'') : '') + ')') : '' ])
		];

		if (on)
			kids.push(E('div', { 'style': 'margin:4px 0' }, [
				E('b', {}, _('Traffic') + ': '),
				E('span', {}, '↓ ' + fmtBytes(dn) + '/s   ↑ ' + fmtBytes(up) + '/s'),
				E('span', { 'style': 'color:#888;margin-left:12px' }, (t.connections || 0) + ' ' + _('connections')),
				E('span', { 'style': 'color:#888;margin-left:12px' }, _('total') + ': ↓' + fmtBytes(t.down_total) + ' ↑' + fmtBytes(t.up_total))
			]));

		kids.push(E('div', { 'style': 'margin:4px 0' }, [ E('b', {}, _('Subscription') + ': '),
			E('span', { 'style': expColor ? ('color:' + expColor + ';font-weight:bold') : '' }, _('expires %s').format(fmtExpire(exp))),
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-left:10px',
				'click': ui.createHandlerFn(this, 'handleRefresh') }, _('Update now')) ]));

		var sub = st.subscription || {};
		if (sub.total && sub.total > 0) {
			var qused = sub.used || 0;
			var qpct = Math.min(100, Math.round(qused * 100 / sub.total));
			var qleft = Math.max(0, sub.total - qused);
			var qcolor = qpct >= 90 ? '#cc3333' : (qpct >= 75 ? '#e08a00' : '#2e7d32');
			kids.push(E('div', { 'style': 'margin:4px 0' }, [
				E('b', {}, _('Data quota') + ': '),
				E('span', {}, fmtBytes(qused) + ' / ' + fmtBytes(sub.total) + '  (' + _('%s left').format(fmtBytes(qleft)) + ')'),
				E('div', { 'style': 'margin-top:3px;background:#e0e0e0;border-radius:6px;height:10px;width:280px;overflow:hidden' }, [
					E('div', { 'style': 'height:10px;width:' + qpct + '%;background:' + qcolor }, '')
				])
			]));
		}

		return E('div', {}, kids);
	},

	// per-client (LAN device) live traffic, top consumers
	renderClients: function(st) {
		var cl = st.client_traffic || [];
		if (!cl.length) return E('em', { 'style': 'color:#888' }, _('No active client connections.'));
		var header = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Device')), E('th', { 'class': 'th' }, _('IP')),
			E('th', { 'class': 'th' }, '↓'), E('th', { 'class': 'th' }, '↑'), E('th', { 'class': 'th' }, _('connections'))
		]);
		var rows = cl.map(function(c) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, c.host || '—'),
				E('td', { 'class': 'td', 'style': 'font-family:monospace;color:#666' }, c.ip || '?'),
				E('td', { 'class': 'td', 'style': 'font-family:monospace' }, fmtBytes(c.down)),
				E('td', { 'class': 'td', 'style': 'font-family:monospace' }, fmtBytes(c.up)),
				E('td', { 'class': 'td' }, c.conns || 0)
			]);
		});
		return E('table', { 'class': 'table vp-table' }, [ header ].concat(rows));
	},

	load: function() { return callStatus(); },
	render: function(st) {
		this._st = st;
		var c = E('div', { 'class': 'cbi-map vpnpool-view' }, [
			i18n.header(_('VPN Pool — Dashboard')),
			E('div', { 'class': 'cbi-section' }, [ E('div', { 'id': 'vp-status' }, this.renderStatus(st)) ]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Per-client traffic')),
				E('div', { 'id': 'vp-clients' }, this.renderClients(st))
			])
		]);
		poll.add(L.bind(this.refresh, this), 5);
		poll.start();
		return c;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
