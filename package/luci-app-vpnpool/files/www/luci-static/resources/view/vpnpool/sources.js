'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require vpnpool.i18n as i18n';

var _ = function(s) { return i18n.tr(s); };

var callStatus   = rpc.declare({ object: 'vpnpool', method: 'status' });
var callRefresh  = rpc.declare({ object: 'vpnpool', method: 'refresh' });
var callSetUrl   = rpc.declare({ object: 'vpnpool', method: 'set_url',          params: [ 'url' ] });
var callDelSub   = rpc.declare({ object: 'vpnpool', method: 'del_subscription' });
var callAddSrc   = rpc.declare({ object: 'vpnpool', method: 'add_source',       params: [ 'url' ] });
var callDelSrc   = rpc.declare({ object: 'vpnpool', method: 'del_source',       params: [ 'url' ] });
var callAddNode  = rpc.declare({ object: 'vpnpool', method: 'add_node',         params: [ 'link' ] });
var callDelNode  = rpc.declare({ object: 'vpnpool', method: 'del_node',         params: [ 'link' ] });
var callSetOpt   = rpc.declare({ object: 'vpnpool', method: 'set_option',       params: [ 'name', 'value' ] });

function nodeName(l) {
	var h = l.indexOf('#');
	if (h < 0) return l;
	try { return decodeURIComponent(l.slice(h + 1)); } catch (e) { return l.slice(h + 1); }
}

return view.extend({
	reload: function() { return callStatus().then(L.bind(function(st) { this.st = st;
		dom.content(document.getElementById('vp-srclist'), this.renderSources(st));
		dom.content(document.getElementById('vp-manlist'), this.renderManual(st)); }, this)); },

	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },

	renderSources: function(st) {
		var self = this;
		var items = (st.sources || []).map(function(u) {
			return E('li', { 'style': 'margin:3px 0' }, [
				E('span', { 'style': 'font-family:monospace;font-size:12px' }, u),
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-left:8px',
					'click': ui.createHandlerFn(self, 'handleDelSrc', u) }, _('Remove'))
			]);
		});
		return E('ul', {}, items.length ? items : [ E('li', { 'style': 'color:#888' }, _('(no extra sources)')) ]);
	},
	renderManual: function(st) {
		var self = this;
		var items = (st.manual_nodes || []).map(function(l) {
			return E('li', { 'style': 'margin:3px 0' }, [
				E('span', {}, nodeName(l)),
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-left:8px',
					'click': ui.createHandlerFn(self, 'handleDelNode', l) }, _('Remove'))
			]);
		});
		return E('ul', {}, items.length ? items : [ E('li', { 'style': 'color:#888' }, _('(no manual nodes)')) ]);
	},

	handleSaveUrl: function(inp) { return callSetUrl(inp.value || '').then(L.bind(function() { this.notify(_('Subscription URL saved.')); }, this)); },
	handleDelSub: function() { if (!confirm(_('Delete the subscription URL?'))) return; return callDelSub().then(L.bind(function() { this.notify(_('Subscription deleted.')); this.reload(); }, this)); },
	handleAddSrc: function(inp) { var v = (inp.value || '').trim(); if (!v) return; return callAddSrc(v).then(L.bind(function() { inp.value = ''; this.notify(_('Source added.')); this.reload(); }, this)); },
	handleDelSrc: function(u) { return callDelSrc(u).then(L.bind(this.reload, this)); },
	handleAddNode: function(inp) { var v = (inp.value || '').trim(); if (!v) return; return callAddNode(v).then(L.bind(function() { inp.value = ''; this.notify(_('Node added.')); this.reload(); }, this)); },
	handleDelNode: function(l) { return callDelNode(l).then(L.bind(this.reload, this)); },
	handleSaveInterval: function(inp) { return callSetOpt('subscription_interval', inp.value || '6h').then(L.bind(function() { this.notify(_('Update interval saved.')); }, this)); },
	handleUpdateNow: function() { this.notify(_('Updating from all sources…')); return callRefresh(); },

	load: function() { return callStatus(); },
	render: function(st) {
		this.st = st;
		var urlInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
			'value': (st.subscription && st.subscription.url) || '', 'placeholder': 'https://…/sub' });
		var srcInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
			'placeholder': 'https://raw.githubusercontent.com/…' });
		var manInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'placeholder': 'vless://…' });
		var intInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:120px',
			'value': (st.settings && st.settings.subscription_interval) || '6h' });

		return E('div', { 'class': 'cbi-map' }, [
			i18n.header(_('VPN Pool — Sources')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Main subscription')),
				urlInput,
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, 'handleSaveUrl', urlInput) }, _('Save URL')),
					E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleDelSub') }, _('Delete subscription')),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleUpdateNow') }, _('Update now'))
				]),
				E('div', { 'style': 'margin-top:10px' }, [
					E('b', {}, _('Auto-update interval') + ': '), intInput,
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'style': 'margin-left:8px', 'click': ui.createHandlerFn(this, 'handleSaveInterval', intInput) }, _('Save')),
					E('span', { 'style': 'color:#888;margin-left:8px' }, _('e.g. 6h, 30m, 12h'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Extra sources (auto-updating raw files)')),
				E('p', { 'style': 'color:#888' }, _('Add raw URLs that contain vless:// lists or base64 subscriptions (e.g. auto-updating repo files).')),
				srcInput,
				E('button', { 'class': 'btn cbi-button cbi-button-add', 'style': 'margin-top:6px', 'click': ui.createHandlerFn(this, 'handleAddSrc', srcInput) }, _('Add source')),
				E('div', { 'id': 'vp-srclist', 'style': 'margin-top:8px' }, this.renderSources(st))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Manual VLESS nodes')),
				manInput,
				E('button', { 'class': 'btn cbi-button cbi-button-add', 'style': 'margin-top:6px', 'click': ui.createHandlerFn(this, 'handleAddNode', manInput) }, _('Add node')),
				E('div', { 'id': 'vp-manlist', 'style': 'margin-top:8px' }, this.renderManual(st))
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
