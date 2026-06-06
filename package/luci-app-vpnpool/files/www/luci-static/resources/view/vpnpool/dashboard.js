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
		return E('div', {}, [
			E('div', { 'style': 'display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:8px' }, [
				E('button', { 'class': 'btn cbi-button ' + (on ? 'cbi-button-negative' : 'cbi-button-positive'),
					'click': ui.createHandlerFn(this, 'handleToggle', st.enabled) }, on ? _('Turn OFF') : _('Turn ON')),
				on ? badge(_('running'), '#2e7d32') : badge(_('stopped'), '#888'),
				st.routing ? badge(_('routing up'), '#2e7d32') : badge(_('no routing'), '#888'),
				badge(st.mode === 'exclude' ? _('all except lists') : _('only lists'), '#1565c0')
			]),
			E('div', { 'style': 'margin:4px 0' }, [ E('b', {}, _('Active node') + ': '), E('span', {}, using),
				(st.active === 'auto' || !st.active) ? E('span', { 'style': 'color:#888' }, ' (' + _('auto / urltest') + ')') : '' ]),
			E('div', { 'style': 'margin:4px 0' }, [ E('b', {}, _('Subscription') + ': '),
				E('span', {}, _('expires %s').format(fmtExpire(st.subscription && st.subscription.expire))),
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-left:10px',
					'click': ui.createHandlerFn(this, 'handleRefresh') }, _('Update now')) ])
		]);
	},

	renderNodes: function(st) {
		if (!st.running) return E('em', {}, _('Service is stopped — start it to see live node pings.'));
		var nodes = st.nodes || [];
		if (!nodes.length) return E('em', {}, _('No nodes yet (waiting for subscription / pings)…'));
		var activeTag = (st.active === 'auto' || !st.active) ? st.auto_now : st.active;

		var header = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, ''), E('th', { 'class': 'th' }, _('Node')),
			E('th', { 'class': 'th' }, _('Server')), E('th', { 'class': 'th' }, _('Ping')), E('th', { 'class': 'th' }, _('Select'))
		]);
		var autoRow = E('tr', { 'class': 'tr', 'style': (st.active === 'auto') ? 'background:rgba(21,101,192,.12)' : '' }, [
			E('td', { 'class': 'td' }, (st.active === 'auto') ? '★' : ''),
			E('td', { 'class': 'td' }, E('b', {}, _('AUTO (urltest)'))),
			E('td', { 'class': 'td', 'style': 'color:#666' }, _('auto-ping + failover')),
			E('td', { 'class': 'td' }, ''),
			E('td', { 'class': 'td' }, E('button', { 'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleSelect', 'auto') }, _('Use')))
		]);
		var rows = nodes.map(L.bind(function(n) {
			var act = (n.tag === activeTag);
			return E('tr', { 'class': 'tr', 'style': act ? 'background:rgba(46,125,50,.12)' : '' }, [
				E('td', { 'class': 'td' }, act ? '★' : ''),
				E('td', { 'class': 'td' }, n.tag),
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
