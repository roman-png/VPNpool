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
var callDelSrc   = rpc.declare({ object: 'vpnpool', method: 'del_source',       params: [ 'url' ] });
var callProbe    = rpc.declare({ object: 'vpnpool', method: 'probe_source',     params: [ 'url' ] });
var callImport   = rpc.declare({ object: 'vpnpool', method: 'import_select',    params: [ 'url', 'scope', 'select' ] });
var callAddNode  = rpc.declare({ object: 'vpnpool', method: 'add_node',         params: [ 'link' ] });
var callDelNode  = rpc.declare({ object: 'vpnpool', method: 'del_node',         params: [ 'link' ] });
var callSetOpt   = rpc.declare({ object: 'vpnpool', method: 'set_option',       params: [ 'name', 'value' ] });

function nodeName(l) {
	var h = l.indexOf('#');
	if (h < 0) return l;
	try { return decodeURIComponent(l.slice(h + 1)); } catch (e) { return l.slice(h + 1); }
}
function pingText(d) { return (d == null) ? '—' : (Math.round(d) + ' ms'); }
function pingColor(d) { if (d == null) return '#999'; if (d < 150) return '#2e7d32'; if (d < 400) return '#f9a825'; return '#c62828'; }

return view.extend({
	reload: function() { return callStatus().then(L.bind(function(st) { this.st = st;
		dom.content(document.getElementById('vp-srclist'), this.renderSources(st));
		dom.content(document.getElementById('vp-manlist'), this.renderManual(st)); }, this)); },

	notify: function(msg) { ui.addNotification(null, E('p', msg), 'info'); },

	renderSources: function(st) {
		var self = this;
		var items = (st.sources || []).map(function(u) {
			return E('li', { 'style': 'margin:4px 0' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'title': _('Re-fetch this source and pick nodes'),
					'click': ui.createHandlerFn(self, 'handleProbe', u) }, '⟳ ' + _('Update')),
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin:0 8px',
					'click': ui.createHandlerFn(self, 'handleDelSrc', u) }, _('Remove')),
				E('span', { 'style': 'font-family:monospace;font-size:12px;word-break:break-all' }, u)
			]);
		});
		return E('ul', { 'style': 'list-style:none;padding-left:0' },
			items.length ? items : [ E('li', { 'style': 'color:#888' }, _('(no saved sources yet)')) ]);
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
	handleDelSrc: function(u) { return callDelSrc(u).then(L.bind(this.reload, this)); },
	handleAddNode: function(inp) { var v = (inp.value || '').trim(); if (!v) return; return callAddNode(v).then(L.bind(function() { inp.value = ''; this.notify(_('Node added.')); this.reload(); }, this)); },
	handleDelNode: function(l) { return callDelNode(l).then(L.bind(this.reload, this)); },
	handleSaveInterval: function(inp) { return callSetOpt('subscription_interval', inp.value || '6h').then(L.bind(function() { this.notify(_('Update interval saved.')); }, this)); },
	handleUpdateNow: function() { this.notify(_('Updating from all sources…')); return callRefresh(); },

	// --- import flow: probe a source URL, then pick nodes -----------------------
	handleProbe: function(urlOrInput) {
		var url = (typeof urlOrInput === 'string') ? urlOrInput : ((urlOrInput && urlOrInput.value) || '').trim();
		if (!url) { ui.addNotification(null, E('p', _('Enter a source URL first.')), 'warning'); return; }
		ui.showModal(_('Fetching source…'), [
			E('p', { 'class': 'spinning' }, _('Fetching and pinging nodes — this can take up to ~30 seconds.'))
		]);
		return callProbe(url).then(L.bind(function(res) {
			if (!res || res.error || !(res.nodes || []).length) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('No usable nodes from this source') + (res && res.error ? (': ' + res.error) : '.')), 'error');
				return;
			}
			this.showImportModal(url, res);
		}, this)).catch(function(e) { ui.hideModal(); ui.addNotification(null, E('p', _('Probe failed') + ': ' + e), 'error'); });
	},

	showImportModal: function(url, res) {
		var self = this;
		var nodes = (res.nodes || []).slice().sort(function(a, b) {
			var da = (a.delay == null) ? 1e9 : a.delay, db = (b.delay == null) ? 1e9 : b.delay; return da - db;
		});
		var rowNodes = nodes.filter(function(n) { return n.link && n.link.length; });
		this._impUrl = url;
		this._impRows = rowNodes;                                   // checkbox i  <->  rowNodes[i]
		this._impScope = rowNodes.map(function(n) { return n.link; });

		var rows = rowNodes.map(function(n) {
			return E('label', { 'class': 'vp-imp-row', 'style': 'display:flex;align-items:center;gap:8px;margin:3px 0;cursor:pointer' }, [
				E('input', { 'type': 'checkbox', 'data-link': n.link, 'checked': n.in_pool ? 'checked' : null }),
				E('span', { 'style': 'min-width:64px;text-align:right;font-weight:bold;color:' + pingColor(n.delay) }, pingText(n.delay)),
				E('span', { 'style': 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap' }, n.tag),
				E('span', { 'style': 'color:#888;font-family:monospace;font-size:11px' }, (n.server || '') + ':' + (n.port || ''))
			]);
		});

		var capNote = res.capped ? (' ' + _('(showing first %d of %d — narrow the source if you need more)').replace('%d', res.shown).replace('%d', res.total)) : '';
		ui.showModal(_('Pick nodes to import'), [
			E('p', {}, _('Selected nodes join the auto-switch pool and appear in the dashboard under this source.') + ' ' +
				_('Ping is ICMP (a server may block it — you can still pick it; the real latency shows in the dashboard).')),
			E('p', { 'style': 'color:#888' }, _('%d nodes').replace('%d', res.shown) + capNote),
			E('div', { 'style': 'margin:6px 0' }, [
				E('button', { 'class': 'btn cbi-button', 'click': function() { self._impToggle(true, true); } }, _('All reachable')),
				E('button', { 'class': 'btn cbi-button', 'style': 'margin-left:6px', 'click': function() { self._impToggle(true, false); } }, _('All')),
				E('button', { 'class': 'btn cbi-button', 'style': 'margin-left:6px', 'click': function() { self._impToggle(false, false); } }, _('None'))
			]),
			E('div', { 'id': 'vp-imp-list', 'style': 'max-height:50vh;overflow:auto;padding:6px;border:1px solid rgba(128,128,128,.3);border-radius:4px' }, rows),
			E('div', { 'class': 'right', 'style': 'margin-top:10px' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(self, 'saveImport') }, _('Save selection'))
			])
		]);
	},

	// reachableOnly: when checking, only tick reachable rows
	_impToggle: function(on, reachableOnly) {
		var boxes = document.querySelectorAll('#vp-imp-list input[type=checkbox]');
		for (var i = 0; i < boxes.length; i++) {
			if (on && reachableOnly) {
				var ms = boxes[i].parentNode.querySelector('span');
				boxes[i].checked = (ms && ms.textContent !== '—');
			} else { boxes[i].checked = on; }
		}
	},

	saveImport: function() {
		var boxes = document.querySelectorAll('#vp-imp-list input[type=checkbox]');
		var rows = this._impRows || [];
		var select = [];
		for (var i = 0; i < boxes.length; i++)
			if (boxes[i].checked && rows[i] && rows[i].link) select.push(rows[i].link);
		var url = this._impUrl, scope = this._impScope || [];
		ui.hideModal();
		this.notify(_('Importing %d nodes…').replace('%d', select.length));
		return callImport(url, scope, select).then(L.bind(function(r) {
			this.notify(_('Imported %d nodes from this source.').replace('%d', (r && r.count != null) ? r.count : select.length));
			this.reload();
		}, this));
	},

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
				E('h3', {}, _('Import from a source list')),
				E('p', { 'style': 'color:#888' }, _('Paste a URL with a vless:// list or base64 subscription, fetch it, then pick the nodes you want. Picked nodes join the pool and show under their own group in the dashboard.')),
				srcInput,
				E('button', { 'class': 'btn cbi-button cbi-button-action important', 'style': 'margin-top:6px',
					'click': ui.createHandlerFn(this, 'handleProbe', srcInput) }, '⤓ ' + _('Fetch & pick')),
				E('h4', { 'style': 'margin-top:12px' }, _('Saved sources')),
				E('div', { 'id': 'vp-srclist', 'style': 'margin-top:4px' }, this.renderSources(st))
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
