'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callDiag = rpc.declare({ object: 'vpnpool', method: 'diag' });

function yn(v) { return E('span', { 'style': 'color:' + (v ? '#2e7d32' : '#cc3333') + ';font-weight:bold' }, v ? '✓' : '✗'); }
function row(label, valNode) {
	return E('div', { 'style': 'margin:2px 0' }, [ E('b', { 'style': 'display:inline-block;width:230px' }, label), valNode ]);
}
function txt(v) { return E('span', { 'style': 'font-family:monospace' }, (v == null || v === '') ? '—' : String(v)); }

return view.extend({
	refresh: function() { return callDiag().then(L.bind(function(d) {
		var el = document.getElementById('vp-diag'); if (el) dom.content(el, this.renderDiag(d));
	}, this)); },

	renderDiag: function(d) {
		d = d || {};
		var s = d.service || {}, c = d.coexist || {}, n = d.network || {}, r = d.resources || {};
		var logs = d.logs || [];

		return E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service')),
				row(_('Enabled'), yn(s.enabled)), row(_('Daemon running'), yn(s.running)),
				row(_('Routing active'), yn(s.routing)), row(_('Autostart on boot'), yn(s.autostart)),
				row(_('sing-box PID'), txt(s.singbox_pid)), row(_('Clash API reachable'), yn(s.clash_api_ok))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Coexistence')),
				row(_('podkop running'), yn(c.podkop_running)), row(_('podkop nft table'), yn(c.podkop_table)),
				row(_('zapret nft table'), yn(c.zapret_table))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Network (direct / ISP path)')),
				row(_('Internet (direct)'), yn(n.internet)),
				row(_('WAN interface'), txt(n.wan_iface)), row(_('Gateway'), txt(n.gateway)),
				row(_('Direct egress IP'), txt(n.direct_ip)), row(_('Direct egress country'), txt(n.direct_country)),
				E('p', { 'style': 'color:#888' }, _('This is your ISP exit (traffic NOT via VPN). Proxied nodes exit elsewhere — see Dashboard pings.'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Resources')),
				row(_('sing-box version'), txt(r.singbox_version)), row(_('tproxy port'), txt(r.tproxy_port)),
				row(_('fwmark / table'), txt((r.fwmark || '') + ' / ' + (r.route_table || ''))), row(_('Clash API'), txt(r.clash_api))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Recent logs')),
				E('pre', { 'style': 'max-height:280px;overflow:auto;background:#111;color:#ddd;padding:8px;font-size:11px;border-radius:4px' },
					logs.length ? logs.join('\n') : _('(no logs)'))
			])
		]);
	},

	load: function() { return callDiag(); },
	render: function(d) {
		var c = E('div', { 'class': 'cbi-map' }, [
			i18n.header(_('VPN Pool — Diagnostics')),
			E('div', { 'style': 'margin-bottom:8px' }, E('button', { 'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'refresh') }, '↻ ' + _('Refresh'))),
			E('div', { 'id': 'vp-diag' }, this.renderDiag(d))
		]);
		poll.add(L.bind(this.refresh, this), 10);
		poll.start();
		return c;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
