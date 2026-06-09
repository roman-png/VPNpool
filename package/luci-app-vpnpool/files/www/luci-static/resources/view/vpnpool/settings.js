'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callStatus = rpc.declare({ object: 'vpnpool', method: 'status' });
var callDiag   = rpc.declare({ object: 'vpnpool', method: 'diag' });
var callSetOpt = rpc.declare({ object: 'vpnpool', method: 'set_option', params: [ 'name', 'value' ] });
var callTgTest = rpc.declare({ object: 'vpnpool', method: 'tg_test' });
var callExport = rpc.declare({ object: 'vpnpool', method: 'export' });
var callImport = rpc.declare({ object: 'vpnpool', method: 'import', params: [ 'config' ] });
var callSetSchedule = rpc.declare({ object: 'vpnpool', method: 'set_schedule', params: [ 'enabled', 'on', 'off', 'refresh' ] });
var callAddAutoDom = rpc.declare({ object: 'vpnpool', method: 'add_auto_domain', params: [ 'domain' ] });
var callDelAutoDom = rpc.declare({ object: 'vpnpool', method: 'del_auto_domain', params: [ 'domain' ] });
var callRunAdaptive = rpc.declare({ object: 'vpnpool', method: 'run_adaptive' });

return view.extend({
	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },
	save: function(name, val) { return callSetOpt(name, String(val)).then(L.bind(function() { this.notify(_('Saved: %s').format(name)); }, this)); },

	handleSaveInterval: function(inp) { return this.save('failover_interval', inp.value || '60'); },
	handleSaveTolerance: function(inp) { return this.save('failover_tolerance', inp.value || '50'); },
	handleToggleAuto: function(cb) { return this.save('auto_switch', cb.checked ? '1' : '0'); },
	handleSavePreferred: function(sel) { return this.save('preferred_node', sel.value || ''); },
	handleToggleKill: function(cb) { return this.save('killswitch', cb.checked ? '1' : '0'); },
	handleToggleDns: function(cb) { return this.save('dns_protect', cb.checked ? '1' : '0'); },
	handleToggleAntidpi: function(cb) { return this.save('antidpi', cb.checked ? '1' : '0'); },
	handleToggleAdaptive: function(cb) { return this.save('adaptive_routing', cb.checked ? '1' : '0'); },
	renderAutoDomains: function(st) {
		var self = this;
		var items = (st.auto_domains || []).map(function(d) {
			return E('li', { 'style': 'margin:3px 0' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-right:8px',
					'click': ui.createHandlerFn(self, 'handleDelAutoDom', d) }, _('Remove')),
				E('span', { 'style': 'font-family:monospace' }, d)
			]);
		});
		return E('ul', { 'style': 'list-style:none;padding-left:0' },
			items.length ? items : [ E('li', { 'style': 'color:#888' }, _('(none yet — detected blocked sites will appear here)')) ]);
	},
	reloadAutoDomains: function() {
		var self = this;
		return callStatus().then(function(st) {
			var el = document.getElementById('vp-autodom'); if (el) dom.content(el, self.renderAutoDomains(st));
		});
	},
	handleAddAutoDom: function(inp) {
		var v = (inp.value || '').trim(); if (!v) { ui.addNotification(null, E('p', _('Enter a domain first.')), 'warning'); return; }
		var self = this;
		return callAddAutoDom(v).then(function() { inp.value = ''; self.notify(_('Domain added to VPN route.')); self.reloadAutoDomains(); });
	},
	handleDelAutoDom: function(d) { var self = this; return callDelAutoDom(d).then(function() { self.reloadAutoDomains(); }); },
	handleRunAdaptive: function() { this.notify(_('Adaptive scan started…')); return callRunAdaptive(); },
	handleSaveSnapshot: function(cb, maxInp) {
		var self = this, max = String(parseInt(maxInp.value, 10) || 20);
		return callSetOpt('auto_snapshot_max', max).then(function() {
			return callSetOpt('auto_snapshot', cb.checked ? '1' : '0');
		}).then(function() { self.notify(_('Auto-snapshot settings saved.')); });
	},
	handleSaveSchedule: function(en, on, off, ref) {
		var self = this;
		return callSetSchedule(en.checked ? '1' : '0', on.value || '', off.value || '', ref.value || '')
			.then(function() { self.notify(_('Schedule saved.')); });
	},
	handleSaveTg: function(en, tok, chat, ctl, viap) {
		var self = this;
		return callSetOpt('telegram_token', tok.value || '')
			.then(function() { return callSetOpt('telegram_chat', chat.value || ''); })
			.then(function() { return callSetOpt('telegram_via_proxy', viap.checked ? '1' : '0'); })
			.then(function() { return callSetOpt('telegram_control', ctl.checked ? '1' : '0'); })
			.then(function() { return callSetOpt('telegram_enabled', en.checked ? '1' : '0'); })
			.then(function() { self.notify(_('Telegram settings saved.')); });
	},
	handleTgTest: function() {
		ui.addNotification(null, E('p', _('Sending test message…')), 'info');
		return callTgTest().then(function(r) {
			if (r && r.ok)
				ui.addNotification(null, E('p', _('Test sent — check Telegram.')), 'info');
			else
				ui.addNotification(null, E('p', _('Telegram send failed (HTTP %s) — check token/chat id.').format((r && r.http) || '?')), 'warning');
		});
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

		// preferred-node dropdown (soft pin with switch-back); "" = auto
		var prefSel = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:220px' },
			[ E('option', { 'value': '' }, _('— auto (urltest) —')) ].concat(
				(st.nodes || []).map(function(n) {
					return E('option', { 'value': n.tag, 'selected': (s.preferred_node === n.tag) ? 'selected' : null }, n.tag);
				})
			));

		var kill = E('input', { 'type': 'checkbox', 'checked': s.killswitch ? 'checked' : null });
		var dns  = E('input', { 'type': 'checkbox', 'checked': s.dns_protect ? 'checked' : null });

		var antidpiCb = E('input', { 'type': 'checkbox', 'checked': s.antidpi ? 'checked' : null });
		var adaptiveCb = E('input', { 'type': 'checkbox', 'checked': s.adaptive_routing ? 'checked' : null });
		var autoDomInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:260px', 'placeholder': 'example.com' });

		var snapEnable = E('input', { 'type': 'checkbox', 'checked': s.auto_snapshot ? 'checked' : null });
		var snapMax = E('input', { 'type': 'number', 'min': '1', 'class': 'cbi-input-text', 'style': 'width:90px', 'value': String(s.auto_snapshot_max || 20) });

		var schEnable = E('input', { 'type': 'checkbox', 'checked': s.sched_enabled ? 'checked' : null });
		var schOn  = E('input', { 'type': 'time', 'class': 'cbi-input-text', 'value': s.sched_on || '' });
		var schOff = E('input', { 'type': 'time', 'class': 'cbi-input-text', 'value': s.sched_off || '' });
		var schRef = E('input', { 'type': 'time', 'class': 'cbi-input-text', 'value': s.sched_refresh || '' });

		var tgEnable = E('input', { 'type': 'checkbox', 'checked': s.telegram_enabled ? 'checked' : null });
		var tgControl = E('input', { 'type': 'checkbox', 'checked': s.telegram_control ? 'checked' : null });
		var tgViaProxy = E('input', { 'type': 'checkbox', 'checked': (s.telegram_via_proxy !== false) ? 'checked' : null });
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
				]),
				E('div', { 'style': 'margin:6px 0' }, [
					E('b', { 'style': 'display:inline-block;width:220px' }, _('Preferred node')), prefSel,
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleSavePreferred', prefSel) }, _('Save'))
				]),
				E('p', { 'style': 'color:#888' }, _('Preferred node: stick to it while it is reachable, hand over to auto if it dies, switch back when it recovers.'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Security / leak protection')),
				E('div', { 'style': 'margin:6px 0' }, [
					E('label', {}, [ kill, E('span', { 'style': 'margin-left:6px' }, _('Kill-switch (block all traffic if VPN is down)')) ]),
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleToggleKill', kill) }, _('Save'))
				]),
				E('div', { 'style': 'margin:6px 0' }, [
					E('label', {}, [ dns, E('span', { 'style': 'margin-left:6px' }, _('DNS-leak protection (route LAN DNS through the tunnel)')) ]),
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleToggleDns', dns) }, _('Save'))
				]),
				E('p', { 'style': 'color:#888' }, _('Kill-switch fails closed in full-tunnel (exclude) mode. DNS protection sends LAN DNS queries through the VPN so they can’t leak to your ISP.'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Anti-DPI & adaptive routing')),
				E('div', { 'style': 'margin:6px 0' }, [ E('label', {}, [ antidpiCb, E('span', { 'style': 'margin-left:6px' }, _('Anti-DPI: fragment the TLS handshake (defeats SNI blocking)')) ]),
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleToggleAntidpi', antidpiCb) }, _('Save')) ]),
				E('p', { 'style': 'color:#888' }, _('Needs sing-box ≥ 1.12. If your build does not support it, the service keeps the previous config (no effect).')),
				E('div', { 'style': 'margin:10px 0 6px' }, [ E('label', {}, [ adaptiveCb, E('span', { 'style': 'margin-left:6px' }, _('Adaptive routing: auto-route sites that are blocked for a direct connection')) ]),
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleToggleAdaptive', adaptiveCb) }, _('Save')),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleRunAdaptive') }, _('Scan now')) ]),
				E('div', { 'style': 'margin:6px 0' }, [
					E('b', { 'style': 'margin-right:6px' }, _('Site is blocked?')), autoDomInput,
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleAddAutoDom', autoDomInput) }, _('Route via VPN'))
				]),
				E('h4', { 'style': 'margin-top:10px' }, _('Auto-routed domains')),
				E('div', { 'id': 'vp-autodom' }, this.renderAutoDomains(st))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Auto-save working nodes')),
				E('div', { 'style': 'margin:6px 0' }, [ E('label', {}, [ snapEnable, E('span', { 'style': 'margin-left:6px' }, _('Periodically snapshot reachable nodes to the saved store')) ]) ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:220px' }, _('Keep at most (nodes)')), snapMax ]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, 'handleSaveSnapshot', snapEnable, snapMax) }, _('Save'))
				]),
				E('p', { 'style': 'color:#888' }, _('Builds a fallback set that survives subscription expiry. Manual ⭐ saves are never evicted.'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Schedule')),
				E('div', { 'style': 'margin:6px 0' }, [ E('label', {}, [ schEnable, E('span', { 'style': 'margin-left:6px' }, _('Enable schedule')) ]) ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:220px' }, _('Turn ON at (HH:MM)')), schOn ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:220px' }, _('Turn OFF at (HH:MM)')), schOff ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:220px' }, _('Refresh subscription at (HH:MM)')), schRef ]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, 'handleSaveSchedule', schEnable, schOn, schOff, schRef) }, _('Save'))
				]),
				E('p', { 'style': 'color:#888' }, _('Router local time. Leave a field empty to skip that action. Uses cron.'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Telegram alerts & control')),
				E('label', {}, [ tgEnable, E('span', { 'style': 'margin-left:6px' }, _('Enable Telegram notifications')) ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:110px' }, _('Bot token')), tgToken ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('b', { 'style': 'display:inline-block;width:110px' }, _('Chat ID')), tgChat ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('label', {}, [ tgControl, E('span', { 'style': 'margin-left:6px' }, _('Two-way control bot (/status, /nodes, /switch, /on, /off, /refresh)')) ]) ]),
				E('div', { 'style': 'margin:6px 0' }, [ E('label', {}, [ tgViaProxy, E('span', { 'style': 'margin-left:6px' }, _('Reach Telegram through the tunnel (needed where Telegram is blocked)')) ]) ]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, 'handleSaveTg', tgEnable, tgToken, tgChat, tgControl, tgViaProxy) }, _('Save')),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleTgTest') }, _('Send test'))
				]),
				E('p', { 'style': 'color:#888' }, _('Create a bot via @BotFather, get your chat id (e.g. @userinfobot). Alerts: failover, subscription expiry, start/stop. The control bot only obeys your chat id.'))
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
