'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callStatus     = rpc.declare({ object: 'vpnpool', method: 'status' });
var callSetEnabled = rpc.declare({ object: 'vpnpool', method: 'set_enabled', params: [ 'enabled' ] });
var callSelect     = rpc.declare({ object: 'vpnpool', method: 'select',      params: [ 'tag' ] });
var callRefresh    = rpc.declare({ object: 'vpnpool', method: 'refresh' });
var callPing       = rpc.declare({ object: 'vpnpool', method: 'ping' });
var callSetAutoMembers = rpc.declare({ object: 'vpnpool', method: 'set_auto_members', params: [ 'members' ] });

function pingColor(d) {
	if (d == null) return '#888';
	if (d <= 0)    return '#cc3333';
	if (d < 150)   return '#2e7d32';
	if (d < 400)   return '#e08a00';
	return '#cc3333';
}
function pingText(d) {
	if (d == null) return '—';
	if (d <= 0)    return _('down');
	return d + ' ms';
}
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
	handleToggle: function(cur) {
		ui.showModal(_('Please wait'), [ E('p', { 'class': 'spinning' }, cur ? _('Stopping…') : _('Starting…')) ]);
		return callSetEnabled(!cur).then(L.bind(function() {
			window.setTimeout(L.bind(function() { ui.hideModal(); this.refresh(); }, this), cur ? 2500 : 15000);
		}, this));
	},
	handleSelect: function(tag) {
		return callSelect(tag).then(L.bind(function() {
			ui.addNotification(null, E('p', _('Switched to %s').format(tag)), 'info');
			this.refresh();
		}, this));
	},
	handleRefresh: function() {
		ui.addNotification(null, E('p', _('Updating subscription…')), 'info');
		return callRefresh().then(L.bind(function() { window.setTimeout(L.bind(this.refresh, this), 12000); }, this));
	},
	handlePing: function() {
		ui.addNotification(null, E('p', _('Pinging all nodes…')), 'info');
		return callPing().then(L.bind(function() { window.setTimeout(L.bind(this.refresh, this), 1500); }, this));
	},
	// Configure which nodes take part in automatic switching (urltest pool).
	handleConfigAuto: function(st) {
		var nodes = (st.nodes || []);
		var members = st.auto_members || [];
		var all = (members.length === 0);   // empty list = ALL nodes (default)
		if (!nodes.length) {
			ui.addNotification(null, E('p', _('No nodes yet (waiting for subscription / pings)…')), 'warning');
			return;
		}
		var checks = nodes.map(function(n) {
			var checked = all || members.indexOf(n.tag) >= 0;
			return E('label', { 'style': 'display:block;margin:5px 0;cursor:pointer' }, [
				E('input', { 'type': 'checkbox', 'data-tag': n.tag, 'checked': checked ? 'checked' : null, 'style': 'margin-right:8px;vertical-align:middle' }),
				E('span', { 'style': 'vertical-align:middle' }, n.tag),
				n.server ? E('span', { 'style': 'color:#888;font-family:monospace;margin-left:8px;vertical-align:middle' }, n.server) : ''
			]);
		});
		ui.showModal(_('Auto-switch pool'), [
			E('p', {}, _('Select which nodes take part in automatic switching (urltest). Unchecked nodes stay available for manual selection only.')),
			E('div', { 'id': 'vp-auto-list', 'style': 'max-height:320px;overflow:auto;margin:8px 0;padding:6px;border:1px solid rgba(128,128,128,.3);border-radius:4px' }, checks),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(this, 'saveAutoMembers') }, _('Save'))
			])
		]);
	},
	saveAutoMembers: function() {
		var boxes = document.querySelectorAll('#vp-auto-list input[type=checkbox]');
		var sel = [], total = boxes.length, checked = 0;
		for (var i = 0; i < boxes.length; i++) {
			if (boxes[i].checked) { sel.push(boxes[i].getAttribute('data-tag')); checked++; }
		}
		if (checked === 0) {
			ui.addNotification(null, E('p', _('Select at least one node for auto-switching.')), 'warning');
			return;
		}
		// all checked => store empty list (means "all", future nodes auto-join)
		var members = (checked === total) ? [] : sel;
		ui.hideModal();
		return callSetAutoMembers(members).then(L.bind(function() {
			ui.addNotification(null, E('p', _('Auto-switch pool saved.')), 'info');
			window.setTimeout(L.bind(this.refresh, this), 1500);
		}, this));
	},
	refresh: function() {
		return callStatus().then(L.bind(function(st) {
			var a = document.getElementById('vp-status'), b = document.getElementById('vp-nodes');
			if (a) dom.content(a, this.renderStatus(st));
			if (b) dom.content(b, this.renderNodes(st));
		}, this));
	},

	renderStatus: function(st) {
		var on = st.enabled && st.running;
		var using = (st.active === 'auto' || !st.active) ? (st.auto_now || '—') : st.active;

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
				(st.active === 'auto' || !st.active) ? E('span', { 'style': 'color:#888' }, ' (' + _('auto / urltest') + ')') : '' ])
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

		return E('div', {}, kids);
	},

	renderNodes: function(st) {
		if (!st.running) return E('em', {}, _('Service is stopped — start it to see live node pings.'));
		var nodes = (st.nodes || []).slice().sort(function(a, b) {
			var da = (a.delay == null || a.delay <= 0) ? 1e9 : a.delay;
			var db = (b.delay == null || b.delay <= 0) ? 1e9 : b.delay;
			return da - db;
		});
		if (!nodes.length) return E('em', {}, _('No nodes yet (waiting for subscription / pings)…'));
		var activeTag = (st.active === 'auto' || !st.active) ? st.auto_now : st.active;
		// auto-pool membership: empty list = ALL nodes are in the pool (default).
		var members = st.auto_members || [];
		var poolAll = (members.length === 0);
		var inPool = function(tag) { return poolAll || members.indexOf(tag) >= 0; };
		var poolLabel = poolAll ? _('all nodes') : (members.length + ' / ' + nodes.length);

		var header = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, ''), E('th', { 'class': 'th' }, _('Node')),
			E('th', { 'class': 'th' }, _('Server')), E('th', { 'class': 'th' }, _('Ping')), E('th', { 'class': 'th' }, _('Select'))
		]);
		var autoRow = E('tr', { 'class': 'tr', 'style': (st.active === 'auto') ? 'background:rgba(21,101,192,.12)' : '' }, [
			E('td', { 'class': 'td' }, (st.active === 'auto') ? '★' : ''),
			E('td', { 'class': 'td' }, E('b', {}, _('AUTO (urltest)'))),
			E('td', { 'class': 'td', 'style': 'color:#666' }, _('auto-ping + failover') + ' · ' + _('pool') + ': ' + poolLabel),
			E('td', { 'class': 'td' }, ''),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleSelect', 'auto') }, _('Use')),
				' ',
				E('button', { 'class': 'btn cbi-button', 'title': _('Configure auto-switch pool'),
					'click': ui.createHandlerFn(this, 'handleConfigAuto', st) }, '⚙ ' + _('Configure'))
			])
		]);
		var rows = nodes.map(L.bind(function(n) {
			var act = (n.tag === activeTag);
			var pooled = inPool(n.tag);
			return E('tr', { 'class': 'tr', 'style': act ? 'background:rgba(46,125,50,.12)' : (pooled ? '' : 'opacity:.55') }, [
				E('td', { 'class': 'td' }, act ? '★' : ''),
				E('td', { 'class': 'td' }, [
					E('span', {}, n.tag),
					pooled ? '' : E('span', { 'style': 'margin-left:6px;font-size:10px;color:#888;border:1px solid #888;border-radius:8px;padding:0 5px',
						'title': _('Excluded from auto-switching (manual only)') }, _('manual'))
				]),
				E('td', { 'class': 'td', 'style': 'font-family:monospace;color:#666' }, (n.server || '') + ':' + (n.port || '')),
				E('td', { 'class': 'td', 'style': 'color:' + pingColor(n.delay) + ';font-weight:bold' }, pingText(n.delay)),
				E('td', { 'class': 'td' }, E('button', { 'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleSelect', n.tag) }, _('Use')))
			]);
		}, this));
		return E('div', {}, [
			E('div', { 'style': 'margin-bottom:6px' }, E('button', { 'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handlePing') }, '↻ ' + _('Ping all nodes'))),
			E('table', { 'class': 'table' }, [ header, autoRow ].concat(rows))
		]);
	},

	load: function() { return callStatus(); },
	render: function(st) {
		var c = E('div', { 'class': 'cbi-map' }, [
			i18n.header(_('VPN Pool — Dashboard')),
			E('div', { 'class': 'cbi-section' }, [ E('div', { 'id': 'vp-status' }, this.renderStatus(st)) ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Nodes')), E('div', { 'id': 'vp-nodes' }, this.renderNodes(st)) ])
		]);
		poll.add(L.bind(this.refresh, this), 5);
		poll.start();
		return c;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
