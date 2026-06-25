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
var callProbeRes = rpc.declare({ object: 'vpnpool', method: 'probe_result' });
var callImport   = rpc.declare({ object: 'vpnpool', method: 'import_select',    params: [ 'url', 'idx' ] });
var callAddNode  = rpc.declare({ object: 'vpnpool', method: 'add_node',         params: [ 'link' ] });
var callDelNode  = rpc.declare({ object: 'vpnpool', method: 'del_node',         params: [ 'link' ] });
var callImportNodes = rpc.declare({ object: 'vpnpool', method: 'import_nodes',  params: [ 'text' ] });
var callActivateSaved   = rpc.declare({ object: 'vpnpool', method: 'activate_saved',   params: [ 'tag' ] });
var callDeactivateSaved = rpc.declare({ object: 'vpnpool', method: 'deactivate_saved', params: [ 'tag' ] });
var callUnsaveNode      = rpc.declare({ object: 'vpnpool', method: 'unsave_node',       params: [ 'tag' ] });
var callSetOpt   = rpc.declare({ object: 'vpnpool', method: 'set_option',       params: [ 'name', 'value' ] });
var callAddExtraSub = rpc.declare({ object: 'vpnpool', method: 'add_sub',       params: [ 'url' ] });
var callDelExtraSub = rpc.declare({ object: 'vpnpool', method: 'del_sub',       params: [ 'url' ] });

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
		dom.content(document.getElementById('vp-manlist'), this.renderManual(st));
		var sv = document.getElementById('vp-savedlist'); if (sv) dom.content(sv, this.renderSaved(st));
		var es = document.getElementById('vp-extrasublist'); if (es) dom.content(es, this.renderExtraSubs(st)); }, this)); },

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
	renderExtraSubs: function(st) {
		var self = this;
		var items = (st.extra_subs || []).map(function(u) {
			return E('li', { 'style': 'margin:4px 0' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-right:8px',
					'click': ui.createHandlerFn(self, 'handleDelExtraSub', u) }, _('Remove')),
				E('span', { 'style': 'font-family:monospace;font-size:12px;word-break:break-all' }, u)
			]);
		});
		return E('ul', { 'style': 'list-style:none;padding-left:0' },
			items.length ? items : [ E('li', { 'style': 'color:#888' }, _('(no extra subscriptions)')) ]);
	},
	handleAddExtraSub: function(inp) {
		var v = (inp.value || '').trim(); if (!v) { ui.addNotification(null, E('p', _('Enter a subscription URL first.')), 'warning'); return; }
		var self = this;
		return callAddExtraSub(v).then(function(r) {
			inp.value = '';
			var n = (r && r.fetched != null) ? r.fetched : 0;
			if (n > 0)
				ui.addNotification(null, E('p', _('Extra subscription added — %d node(s) fetched.').format(n)), 'info');
			else
				ui.addNotification(null, E('p', _('Extra subscription added, but NO nodes were fetched (HTTP %s). Is the URL reachable from the router? Check the port/firewall on the server.').format((r && r.http) || '000')), 'warning');
			self.reload();
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Could not add subscription: %s').format(e)), 'error');
		});
	},
	handleDelExtraSub: function(u) { return callDelExtraSub(u).then(L.bind(function() { this.notify(_('Extra subscription removed.')); this.reload(); }, this)); },

	// Saved nodes = a persistent archive, separate from manual nodes. Each is either
	// ACTIVE (promoted into the live pool) or IDLE (kept for later / after sub expiry).
	renderSaved: function(st) {
		var self = this;
		var active = (st.nodes || []).filter(function(n) { return n.active_saved; })
			.map(function(n) { return { tag: n.tag, server: n.server, port: n.port, active: true }; });
		var idle = (st.saved_inactive || [])
			.map(function(n) { return { tag: n.tag, server: n.server, port: n.port, active: false }; });
		var all = active.concat(idle);
		var items = all.map(function(n) {
			return E('li', { 'style': 'display:flex;align-items:center;gap:8px;margin:4px 0;flex-wrap:wrap' }, [
				E('span', { 'style': 'min-width:64px;font-weight:bold;font-size:12px;color:' + (n.active ? '#2e7d32' : '#999') },
					n.active ? ('● ' + _('active')) : ('○ ' + _('idle'))),
				E('span', { 'style': 'flex:1;min-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap' }, n.tag),
				E('span', { 'style': 'color:#888;font-family:monospace;font-size:11px' }, (n.server || '') + ':' + (n.port || '')),
				n.active
					? E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(self, 'handleDeactivateSaved', n.tag) }, _('Deactivate'))
					: E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, 'handleActivateSaved', n.tag) }, _('Activate')),
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'click': ui.createHandlerFn(self, 'handleUnsaveNode', n.tag) }, _('Remove'))
			]);
		});
		return E('ul', { 'style': 'list-style:none;padding-left:0' },
			items.length ? items : [ E('li', { 'style': 'color:#888' },
				_('(no saved nodes yet — star nodes on the dashboard; they also land here automatically when you delete the subscription)')) ]);
	},
	handleActivateSaved: function(tag) { this.notify(_('Activating saved node…')); return callActivateSaved(tag).then(L.bind(function() { this.notify(_('Saved node activated.')); this.reload(); }, this)); },
	handleDeactivateSaved: function(tag) { return callDeactivateSaved(tag).then(L.bind(function() { this.notify(_('Saved node deactivated.')); this.reload(); }, this)); },
	handleUnsaveNode: function(tag) { if (!confirm(_('Remove this node from the saved archive?'))) return; return callUnsaveNode(tag).then(L.bind(function() { this.notify(_('Saved node removed.')); this.reload(); }, this)); },

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
	handleDelSub: function() { if (!confirm(_('Delete the subscription? All saved nodes will be auto-activated so you stay connected.'))) return; return callDelSub().then(L.bind(function(r) { this.notify(_('Subscription deleted — %d saved node(s) kept active.').replace('%d', (r && r.promoted != null) ? r.promoted : 0)); this.reload(); }, this)); },
	handleDelSrc: function(u) { return callDelSrc(u).then(L.bind(this.reload, this)); },
	handleAddNode: function(inp) { var v = (inp.value || '').trim(); if (!v) return; return callAddNode(v).then(L.bind(function() { inp.value = ''; this.notify(_('Node added.')); this.reload(); }, this)); },
	handleDelNode: function(l) { return callDelNode(l).then(L.bind(this.reload, this)); },

	// AmneziaVPN vpn:// link = base64url( 4-byte BE length + zlib(JSON) ). The router has no
	// zlib (ucode/busybox), so decode it here in the browser and hand the embedded .conf to
	// the same import path as a pasted AmneziaWG config.
	decodeAmneziaVpnLink: function(link) {
		var tok = link.trim().replace(/^vpn:\/\//, '');
		var b64 = tok.replace(/-/g, '+').replace(/_/g, '/');
		while (b64.length % 4) b64 += '=';
		var bin = atob(b64), bytes = new Uint8Array(bin.length), i;
		for (i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
		if (typeof DecompressionStream === 'undefined')
			return Promise.reject(new Error(_('browser lacks zlib support')));
		var ds = new DecompressionStream('deflate');                 // zlib (keeps 0x78 header)
		var resp = new Response(new Blob([bytes.subarray(4)]).stream().pipeThrough(ds));
		return resp.text().then(function(jsonStr) {
			var o = JSON.parse(jsonStr);
			var awg = o && o.containers && o.containers[0] && o.containers[0].awg;
			if (!awg) throw new Error(_('no AmneziaWG container in link'));
			var lc = (typeof awg.last_config === 'string') ? JSON.parse(awg.last_config) : awg.last_config;
			if (!lc || !lc.config) throw new Error(_('no config in link'));
			return lc.config;
		});
	},

	// --- bulk import: paste many links / a base64 subscription / an AmneziaWG .conf or
	//     vpn:// link, or load a file -------------------------------------------------
	handleImportNodes: function(ta) {
		var txt = (ta && ta.value || '').trim();
		if (!txt) { ui.addNotification(null, E('p', _('Paste node links (or load a file) first.')), 'warning'); return; }
		var self = this;
		var prep = /^vpn:\/\//.test(txt)
			? this.decodeAmneziaVpnLink(txt).catch(function(e) {
				ui.addNotification(null, E('p', _('Could not decode vpn:// link') + ': ' + (e && e.message || e)), 'error');
				return null;
			})
			: Promise.resolve(txt);
		return prep.then(function(payload) {
			if (payload == null) return;
			self.notify(_('Importing nodes…'));
			return callImportNodes(payload).then(L.bind(function(r) {
				if (r && r.ok) {
					ta.value = '';
					if (r.awg)
						this.notify(_('AmneziaWG node imported.'));
					else
						this.notify(_('Imported %d new node(s) (manual list: %d).').replace('%d', (r.added != null ? r.added : 0)).replace('%d', (r.total != null ? r.total : 0)));
					this.reload();
				} else {
					ui.addNotification(null, E('p', _('Import failed') + (r && r.error ? (': ' + r.error) : '.')), 'error');
				}
			}, self));
		});
	},
	handleImportFile: function(ta, fileInput) {
		var f = fileInput && fileInput.files && fileInput.files[0];
		if (!f) return;
		var self = this;
		var rd = new FileReader();
		rd.onload = function() {
			var prev = (ta.value || '');
			ta.value = (prev ? (prev.replace(/\s*$/, '') + '\n') : '') + String(rd.result || '');
			fileInput.value = '';
			self.notify(_('File loaded — review and press Import.'));
		};
		rd.onerror = function() { ui.addNotification(null, E('p', _('Could not read the file.')), 'error'); };
		rd.readAsText(f);
	},
	handleSaveInterval: function(inp) { return callSetOpt('subscription_interval', inp.value || '6h').then(L.bind(function() { this.notify(_('Update interval saved.')); }, this)); },
	handleUpdateNow: function() { this.notify(_('Updating from all sources…')); return callRefresh(); },

	// --- import flow: probe a source URL, then pick nodes -----------------------
	handleProbe: function(urlOrInput) {
		var url = (typeof urlOrInput === 'string') ? urlOrInput : ((urlOrInput && urlOrInput.value) || '').trim();
		if (!url) { ui.addNotification(null, E('p', _('Enter a source URL first.')), 'warning'); return; }
		var self = this;
		ui.showModal(_('Fetching source…'), [
			E('p', { 'class': 'spinning' }, _('Fetching and pinging nodes — this can take up to a minute on slow routers.'))
		]);
		var fail = function(msg) { ui.hideModal(); ui.addNotification(null, E('p', msg), 'error'); };
		var done = function(res) {
			if (!res || res.error || !(res.nodes || []).length) {
				fail(_('No usable nodes from this source') + (res && res.error ? (': ' + res.error) : '.'));
				return;
			}
			self.showImportModal(url, res);
		};
		// probe runs in the background on the router; poll for the result
		var tries = 0;
		var poll = function() {
			return callProbeRes().then(function(res) {
				if (res && res.running) {
					if (++tries > 45) { fail(_('Probe timed out.')); return; }
					return new Promise(function(r) { window.setTimeout(r, 3000); }).then(poll);
				}
				done(res);
			});
		};
		return callProbe(url).then(function() {
			return new Promise(function(r) { window.setTimeout(r, 2000); }).then(poll);
		}).catch(function(e) { fail(_('Probe failed') + ': ' + e); });
	},

	showImportModal: function(url, res) {
		var self = this;
		var nodes = (res.nodes || []).slice().sort(function(a, b) {
			var da = (a.delay == null) ? 1e9 : a.delay, db = (b.delay == null) ? 1e9 : b.delay; return da - db;
		});
		var rowNodes = nodes;                                       // all probed nodes (sorted)
		this._impUrl = url;
		this._impRows = rowNodes;                                   // checkbox i  <->  rowNodes[i].i

		var rows = rowNodes.map(function(n) {
			return E('label', { 'class': 'vp-imp-row', 'style': 'display:flex;align-items:center;gap:8px;margin:3px 0;cursor:pointer' }, [
				E('input', { 'type': 'checkbox', 'checked': n.in_pool ? 'checked' : null }),
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
		var idx = [];
		for (var i = 0; i < boxes.length; i++)
			if (boxes[i].checked && rows[i] && typeof rows[i].i === 'number') idx.push(rows[i].i);
		var url = this._impUrl;
		ui.hideModal();
		this.notify(_('Importing %d nodes…').replace('%d', idx.length));
		return callImport(url, idx).then(L.bind(function(r) {
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
		var extraSubInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
			'placeholder': 'https://…/sub' });
		var manInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'placeholder': 'vless://…' });
		var importTA = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%;min-height:90px;font-family:monospace;font-size:12px',
			'placeholder': 'vless://…\nvless://…\n' + _('or a base64 subscription') });
		var fileInput = E('input', { 'type': 'file', 'accept': '.txt,.text,text/plain', 'style': 'display:none' });
		fileInput.addEventListener('change', L.bind(function() { this.handleImportFile(importTA, fileInput); }, this));
		var intInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:120px',
			'value': (st.settings && st.settings.subscription_interval) || '6h' });

		return E('div', { 'class': 'cbi-map vpnpool-view' }, [
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
				E('h3', {}, _('Extra subscriptions')),
				E('p', { 'style': 'color:#888' }, _('Additional full subscriptions are bulk-merged into the pool alongside the main one (quota/expiry come only from the main subscription).')),
				extraSubInput,
				E('button', { 'class': 'btn cbi-button cbi-button-add', 'style': 'margin-top:6px',
					'click': ui.createHandlerFn(this, 'handleAddExtraSub', extraSubInput) }, _('Add subscription')),
				E('div', { 'id': 'vp-extrasublist', 'style': 'margin-top:8px' }, this.renderExtraSubs(st))
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

				E('h4', { 'style': 'margin-top:14px' }, _('Bulk import')),
				E('p', { 'style': 'color:#888' }, _('Paste many node links (one per line) or a whole base64 subscription, or load them from a file. New links are added to the manual list above.')),
				importTA,
				E('div', { 'style': 'margin-top:6px;display:flex;flex-wrap:wrap;gap:8px;align-items:center' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleImportNodes', importTA) }, '⤓ ' + _('Import')),
					fileInput,
					E('button', { 'class': 'btn cbi-button', 'click': function() { fileInput.click(); } }, '📄 ' + _('Load file…'))
				]),

				E('div', { 'id': 'vp-manlist', 'style': 'margin-top:8px' }, this.renderManual(st))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Saved nodes')),
				E('p', { 'style': 'color:#888' }, _('A persistent archive separate from manual nodes. Star nodes on the dashboard to save them; they survive subscription expiry. ACTIVE = in the live pool, IDLE = kept for later. Deleting the subscription auto-activates all of them so you stay connected.')),
				E('div', { 'id': 'vp-savedlist', 'style': 'margin-top:4px' }, this.renderSaved(st))
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
