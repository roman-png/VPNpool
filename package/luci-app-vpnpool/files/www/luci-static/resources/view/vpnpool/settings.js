'use strict';
'require view';
'require rpc';
'require ui';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callStatus = rpc.declare({ object: 'vpnpool', method: 'status' });
var callDiag   = rpc.declare({ object: 'vpnpool', method: 'diag' });
var callSetOpt = rpc.declare({ object: 'vpnpool', method: 'set_option', params: [ 'name', 'value' ] });
var callTgTest = rpc.declare({ object: 'vpnpool', method: 'tg_test' });
var callExport = rpc.declare({ object: 'vpnpool', method: 'export' });
var callImport = rpc.declare({ object: 'vpnpool', method: 'import', params: [ 'config' ] });

return view.extend({
	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },
	save: function(name, val) { return callSetOpt(name, String(val)).then(L.bind(function() { this.notify(_('Saved: %s').format(name)); }, this)); },

	handleSaveInterval: function(inp) { return this.save('failover_interval', inp.value || '60'); },
	handleSaveTolerance: function(inp) { return this.save('failover_tolerance', inp.value || '50'); },
	handleToggleAuto: function(cb) { return this.save('auto_switch', cb.checked ? '1' : '0'); },
	handleSaveTg: function(en, tok, chat) {
		var self = this;
		return callSetOpt('telegram_token', tok.value || '')
			.then(function() { return callSetOpt('telegram_chat', chat.value || ''); })
			.then(function() { return callSetOpt('telegram_enabled', en.checked ? '1' : '0'); })
			.then(function() { self.notify(_('Telegram settings saved.')); });
	},
	handleTgTest: function() {
		ui.addNotification(null, E('p', _('Sending test message…')), 'info');
		return callTgTest().then(function() { ui.addNotification(null, E('p', _('Test sent — check Telegram.')), 'info'); });
	},
	handleExport: function(box) {
		return callExport().then(function(r) { box.value = (r && r.config) || ''; });
	},
	handleImport: function(box) {
		var self = this;
		if (!confirm(_('Replace the current vpnpool configuration with the pasted backup?'))) return;
		return callImport(box.value || '').then(function() { self.notify(_('Configuration imported. Reloading…')); });
	},

	load: function() { return Promise.all([ callStatus(), callDiag().catch(function() { return {}; }) ]); },
	render: function(res) {
		var st = res[0] || {}, dg = res[1] || {};
		var s = st.settings || {};
		var r = dg.resources || {};

		var fi = E('input', { 'type': 'number', 'min': '10', 'class': 'cbi-input-text', 'style': 'width:120px', 'value': s.failover_interval || 60 });
		var tol = E('input', { 'type': 'number', 'min': '0', 'class': 'cbi-input-text', 'style': 'width:120px', 'value': s.failover_tolerance || 50 });
		var auto = E('input', { 'type': 'checkbox', 'checked': (s.auto_switch !== false) ? 'checked' : null });
		var tgEnable = E('input', { 'type': 'checkbox', 'checked': s.telegram_enabled ? 'checked' : null });
		var tgToken = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'value': s.telegram_token || '', 'placeholder': '123456789:ABC…' });
		var tgChat = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:220px', 'value': s.telegram_chat || '', 'placeholder': 'chat id' });
		var bkBox = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%;height:140px;font-family:monospace;font-size:11px' });

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
				E('h3', {}, _('Telegram alerts')),
				E('label', {}, [ tgEnable, E('span', { 'style': 'margin-left:6px' }, _('Enable Telegram notifications')) ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:110px' }, _('Bot token')), tgToken ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:110px' }, _('Chat ID')), tgChat ]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, 'handleSaveTg', tgEnable, tgToken, tgChat) }, _('Save')),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleTgTest') }, _('Send test'))
				]),
				E('p', { 'style': 'color:#888' }, _('Create a bot via @BotFather, get your chat id (e.g. @userinfobot). Alerts: failover, subscription expiry, start/stop.'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Backup / Restore')),
				E('div', { 'style': 'margin-bottom:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleExport', bkBox) }, _('Export')),
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleImport', bkBox) }, _('Import'))
				]),
				bkBox,
				E('p', { 'style': 'color:#888' }, _('Export fills the box with your config — copy it somewhere safe. Paste a backup and Import to restore.'))
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
