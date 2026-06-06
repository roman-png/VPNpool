'use strict';
'require view';
'require rpc';
'require ui';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callStatus = rpc.declare({ object: 'vpnpool', method: 'status' });
var callDiag   = rpc.declare({ object: 'vpnpool', method: 'diag' });
var callSetOpt = rpc.declare({ object: 'vpnpool', method: 'set_option', params: [ 'name', 'value' ] });

return view.extend({
	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },
	save: function(name, val) { return callSetOpt(name, String(val)).then(L.bind(function() { this.notify(_('Saved: %s').format(name)); }, this)); },

	handleSaveInterval: function(inp) { return this.save('failover_interval', inp.value || '60'); },
	handleSaveTolerance: function(inp) { return this.save('failover_tolerance', inp.value || '50'); },
	handleToggleAuto: function(cb) { return this.save('auto_switch', cb.checked ? '1' : '0'); },

	load: function() { return Promise.all([ callStatus(), callDiag().catch(function() { return {}; }) ]); },
	render: function(res) {
		var st = res[0] || {}, dg = res[1] || {};
		var s = st.settings || {};
		var r = dg.resources || {};

		var fi = E('input', { 'type': 'number', 'min': '10', 'class': 'cbi-input-text', 'style': 'width:120px', 'value': s.failover_interval || 60 });
		var tol = E('input', { 'type': 'number', 'min': '0', 'class': 'cbi-input-text', 'style': 'width:120px', 'value': s.failover_tolerance || 50 });
		var auto = E('input', { 'type': 'checkbox', 'checked': (s.auto_switch !== false) ? 'checked' : null });

		function row(label, val) {
			return E('div', { 'style': 'margin:3px 0' }, [ E('b', { 'style': 'display:inline-block;width:180px' }, label), E('span', { 'style': 'font-family:monospace' }, val == null ? '—' : String(val)) ]);
		}

		return E('div', { 'class': 'cbi-map' }, [
			i18n.header(_('VPN Pool — Settings')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Auto-ping & failover')),
				E('div', { 'style': 'margin:6px 0' }, [
					E('b', { 'style': 'display:inline-block;width:220px' }, _('Auto-ping interval (sec)')), fi,
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleSaveInterval', fi) }, _('Save'))
				]),
				E('div', { 'style': 'margin:6px 0' }, [
					E('b', { 'style': 'display:inline-block;width:220px' }, _('Switch tolerance (ms)')), tol,
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleSaveTolerance', tol) }, _('Save'))
				]),
				E('div', { 'style': 'margin:6px 0' }, [
					E('label', {}, [ auto, E('span', { 'style': 'margin-left:6px' }, _('Auto-switch to a working node (urltest)')) ]),
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleToggleAuto', auto) }, _('Save'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Technical (read-only)')),
				row(_('sing-box version'), r.singbox_version),
				row(_('tproxy port'), r.tproxy_port),
				row(_('fwmark'), r.fwmark),
				row(_('route table'), r.route_table),
				row(_('Clash API'), r.clash_api),
				E('p', { 'style': 'color:#888;margin-top:8px' }, _('These coexist with podkop (mark 0x100000, table podkop, :1602) and must not collide.'))
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
