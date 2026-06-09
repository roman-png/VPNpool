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
var callSaveNode   = rpc.declare({ object: 'vpnpool', method: 'save_node',   params: [ 'tag' ] });
var callUnsaveNode = rpc.declare({ object: 'vpnpool', method: 'unsave_node', params: [ 'tag' ] });
var callSpeedtest  = rpc.declare({ object: 'vpnpool', method: 'speedtest',   params: [ 'tag' ] });
var callSpeedRes   = rpc.declare({ object: 'vpnpool', method: 'speedtest_result' });
var callNodeLink   = rpc.declare({ object: 'vpnpool', method: 'node_link',    params: [ 'tag' ] });
var callExportNodes = rpc.declare({ object: 'vpnpool', method: 'export_nodes', params: [ 'scope' ] });
var callUnlock     = rpc.declare({ object: 'vpnpool', method: 'unlock',        params: [ 'tag' ] });
var callUnlockRes  = rpc.declare({ object: 'vpnpool', method: 'unlock_result' });

// short labels for the per-node service-unlock badges
var UNLOCK_LABELS = { youtube: 'YT', openai: 'AI', netflix: 'NF', instagram: 'IG', telegram: 'TG', google: 'GG' };
function unlockBadges(u) {
	if (!u) return '';
	var chips = [];
	for (var k in UNLOCK_LABELS) {
		if (u[k] === true || u[k] === false)
			chips.push(E('span', { 'style': 'margin-left:3px;font-size:10px;padding:0 4px;border-radius:6px;color:#fff;background:' + (u[k] ? '#2e7d32' : '#aaa'),
				'title': k + (u[k] ? ': ok' : ': blocked') }, UNLOCK_LABELS[k]));
	}
	return E('span', { 'style': 'margin-left:6px;white-space:nowrap' }, chips);
}

// client-side node view state (filter/sort), persisted across polls
var nodeFilter = '';
var nodeSort = 'ping';            // ping | name | down
var nodeReachOnly = false;
var speedResults = {};            // tag -> mbps (last speed test)

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
	handleSaveNode: function(tag) {
		return callSaveNode(tag).then(L.bind(function() {
			ui.addNotification(null, E('p', _('Node saved: %s').format(tag)), 'info');
			window.setTimeout(L.bind(this.refresh, this), 1500);
		}, this));
	},
	handleUnsaveNode: function(tag) {
		return callUnsaveNode(tag).then(L.bind(function() {
			ui.addNotification(null, E('p', _('Node removed from saved: %s').format(tag)), 'info');
			window.setTimeout(L.bind(this.refresh, this), 1500);
		}, this));
	},
	handleSpeedtest: function(tag) {
		var self = this;
		var poller = function() {
			return callSpeedRes().then(function(r) {
				if (r && r.running) { window.setTimeout(poller, 2000); return; }
				if (r && r.ok) {
					speedResults[tag] = r.mbps;
					ui.addNotification(null, E('p', _('%s: %s Mbit/s').format(tag, r.mbps)), 'info');
				} else {
					ui.addNotification(null, E('p', _('Speed test failed for %s.').format(tag)), 'warning');
				}
				if (self._st) { var b = document.getElementById('vp-nodes'); if (b) dom.content(b, self.renderNodes(self._st)); }
			});
		};
		return callSpeedtest(tag).then(function(r) {
			if (r && r.lowmem) {
				var avail = Math.round((r.avail_kb || 0) / 1024), need = Math.round((r.need_kb || 0) / 1024);
				ui.addNotification(null, E('p', _('Not enough free memory for a speed test: %s MB free, need ≥ %s MB. Skipped to keep the VPN stable.').format(avail, need)), 'warning');
				return;
			}
			ui.addNotification(null, E('p', _('Speed-testing %s… (router traffic briefly uses this node)').format(tag)), 'info');
			window.setTimeout(poller, 2000);
		});
	},
	handleUnlock: function(tag) {
		var self = this;
		var poller = function() {
			return callUnlockRes().then(function(r) {
				if (r && r.running) { window.setTimeout(poller, 2000); return; }
				if (r && r.ok) {
					ui.addNotification(null, E('p', _('Unlock test done for %s.').format(tag)), 'info');
					window.setTimeout(L.bind(self.refresh, self), 500);   // pull persisted badges
				} else {
					ui.addNotification(null, E('p', _('Unlock test failed for %s.').format(tag)), 'warning');
				}
			});
		};
		return callUnlock(tag).then(function(r) {
			if (r && r.lowmem) {
				var avail = Math.round((r.avail_kb || 0) / 1024), need = Math.round((r.need_kb || 0) / 1024);
				ui.addNotification(null, E('p', _('Not enough free memory for a speed test: %s MB free, need ≥ %s MB. Skipped to keep the VPN stable.').format(avail, need)), 'warning');
				return;
			}
			ui.addNotification(null, E('p', _('Testing what %s unblocks… (router traffic briefly uses this node)').format(tag)), 'info');
			window.setTimeout(poller, 2000);
		});
	},
	rerenderNodes: function() {
		if (this._st) { var b = document.getElementById('vp-nodes'); if (b) dom.content(b, this.renderNodes(this._st)); }
	},
	// QR is rendered fully client-side (vendored qrcodejs) so node secrets never
	// leave the router — loaded on demand to keep the page light.
	renderQR: function(el, text) {
		var make = function() { try { dom.content(el, ''); new window.QRCode(el, { text: text, width: 220, height: 220, correctLevel: window.QRCode.CorrectLevel.M }); } catch (e) {} };
		if (window.QRCode) { make(); return; }
		var s = document.createElement('script');
		s.src = L.resource('vpnpool/qrcode.min.js');
		s.onload = make;
		s.onerror = function() { dom.content(el, E('em', { 'style': 'color:#888' }, _('QR library unavailable.'))); };
		document.head.appendChild(s);
	},
	handleShowLink: function(tag) {
		return callNodeLink(tag).then(L.bind(function(r) {
			if (!r || !r.ok || !r.link) {
				ui.addNotification(null, E('p', _('No shareable link for this node.')), 'warning');
				return;
			}
			var qr = E('div', { 'style': 'display:flex;justify-content:center;min-height:220px;margin:10px 0' }, E('em', { 'style': 'color:#888' }, '…'));
			var ta = E('textarea', { 'rows': '4', 'readonly': 'readonly', 'style': 'width:100%;font-family:monospace;font-size:11px' }, r.link);
			ui.showModal(_('Share node') + ': ' + tag, [
				E('p', {}, _('Scan the QR with your phone VPN app, or copy the link.')),
				qr, ta,
				E('div', { 'class': 'right', 'style': 'margin-top:8px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': function() { ta.select(); try { document.execCommand('copy'); } catch (e) {} } }, _('Copy link')),
					' ',
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
				])
			]);
			this.renderQR(qr, r.link);
		}, this));
	},
	handleExport: function() {
		var self = this;
		var mk = function(scope, label) {
			return E('button', { 'class': 'btn cbi-button', 'style': 'margin:3px', 'click': function() { self.doExport(scope); } }, label);
		};
		ui.showModal(_('Export nodes as subscription'), [
			E('p', {}, _('Pick which nodes to export. You get the raw vless:// links and a base64 subscription you can import elsewhere.')),
			E('div', {}, [ mk('saved', _('Saved')), mk('manual', _('Manual')), mk('all', _('All nodes')) ]),
			E('div', { 'id': 'vp-export-out', 'style': 'margin-top:10px' }, ''),
			E('div', { 'class': 'right', 'style': 'margin-top:8px' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')))
		]);
	},
	doExport: function(scope) {
		return callExportNodes(scope).then(function(r) {
			var out = document.getElementById('vp-export-out');
			if (!out) return;
			var links = (r && r.links) || [];
			if (!links.length) { dom.content(out, E('em', { 'style': 'color:#888' }, _('Nothing to export in this set.'))); return; }
			var text = links.join('\n');
			var b64 = '';
			try { b64 = btoa(unescape(encodeURIComponent(text))); } catch (e) { b64 = ''; }
			// one reusable block: a labelled, read-only textarea + Copy + Download.
			var block = function(label, value, filename) {
				var ta = E('textarea', { 'rows': '5', 'readonly': 'readonly',
					'style': 'width:100%;font-family:monospace;font-size:11px' }, value);
				return E('div', { 'style': 'margin-top:8px' }, [
					E('p', { 'style': 'margin:4px 0' }, E('b', {}, label)),
					ta,
					E('div', { 'style': 'margin-top:6px' }, [
						E('button', { 'class': 'btn cbi-button cbi-button-action',
							'click': function() { ta.select(); try { document.execCommand('copy'); } catch (e) {} } }, _('Copy')),
						' ',
						E('a', { 'class': 'btn cbi-button', 'download': filename,
							'href': 'data:text/plain;charset=utf-8,' + encodeURIComponent(value) }, _('Download'))
					])
				]);
			};
			dom.content(out, [
				E('p', { 'style': 'margin:4px 0' }, E('b', {}, _('%d nodes').format(links.length))),
				block(_('vless:// links'), text, 'vpnpool-nodes.txt'),
				block(_('base64 subscription'), b64, 'vpnpool-subscription.txt')
			]);
		});
	},
	refresh: function() {
		return callStatus().then(L.bind(function(st) {
			this._st = st;
			var a = document.getElementById('vp-status'), b = document.getElementById('vp-nodes'), c = document.getElementById('vp-clients');
			if (a) dom.content(a, this.renderStatus(st));
			if (b) dom.content(b, this.renderNodes(st));
			if (c) dom.content(c, this.renderClients(st));
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

	renderToolbar: function() {
		var self = this;
		var search = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:200px',
			'placeholder': _('Search node / server…'), 'value': nodeFilter });
		search.addEventListener('input', function(ev) { nodeFilter = ev.target.value; self.rerenderNodes(); });
		var sort = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'ping',  'selected': nodeSort === 'ping' ? 'selected' : null }, _('Sort: ping')),
			E('option', { 'value': 'name',  'selected': nodeSort === 'name' ? 'selected' : null }, _('Sort: name')),
			E('option', { 'value': 'down',  'selected': nodeSort === 'down' ? 'selected' : null }, _('Sort: traffic'))
		]);
		sort.addEventListener('change', function(ev) { nodeSort = ev.target.value; self.rerenderNodes(); });
		var reach = E('input', { 'type': 'checkbox', 'checked': nodeReachOnly ? 'checked' : null });
		reach.addEventListener('change', function(ev) { nodeReachOnly = ev.target.checked; self.rerenderNodes(); });
		return E('div', { 'style': 'display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:8px' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handlePing') }, '↻ ' + _('Ping all nodes')),
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleExport') }, '⬇ ' + _('Export')),
			search, sort,
			E('label', { 'style': 'cursor:pointer' }, [ reach, E('span', { 'style': 'margin-left:5px' }, _('reachable only')) ])
		]);
	},
	renderNodes: function(st) {
		if (!st.running) return E('em', {}, _('Service is stopped — start it to see live node pings.'));
		var allNodes = (st.nodes || []);
		if (!allNodes.length) return E('em', {}, _('No nodes yet (waiting for subscription / pings)…'));

		// client-side filter + sort
		var f = (nodeFilter || '').toLowerCase();
		var nodes = allNodes.filter(function(n) {
			if (nodeReachOnly && !(n.delay > 0)) return false;
			if (!f) return true;
			return (n.tag || '').toLowerCase().indexOf(f) >= 0 || (n.server || '').toLowerCase().indexOf(f) >= 0;
		});
		nodes = nodes.slice().sort(function(a, b) {
			if (nodeSort === 'name') return (a.tag || '').localeCompare(b.tag || '');
			if (nodeSort === 'down') return ((b.down || 0) + (b.up || 0)) - ((a.down || 0) + (a.up || 0));
			var da = (a.delay == null || a.delay <= 0) ? 1e9 : a.delay;
			var db = (b.delay == null || b.delay <= 0) ? 1e9 : b.delay;
			return da - db;
		});

		var activeTag = (st.active === 'auto' || !st.active) ? st.auto_now : st.active;
		var members = st.auto_members || [];
		var poolAll = (members.length === 0);
		var inPool = function(tag) { return poolAll || members.indexOf(tag) >= 0; };
		var poolLabel = poolAll ? _('all nodes') : (members.length + ' / ' + allNodes.length);
		var NCOL = '7';

		var header = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, ''), E('th', { 'class': 'th' }, _('Node')),
			E('th', { 'class': 'th' }, _('Server')), E('th', { 'class': 'th' }, _('Ping')),
			E('th', { 'class': 'th' }, _('Speed')), E('th', { 'class': 'th' }, _('Traffic')),
			E('th', { 'class': 'th' }, _('Actions'))
		]);
		var autoRow = E('tr', { 'class': 'tr', 'style': (st.active === 'auto') ? 'background:rgba(21,101,192,.12)' : '' }, [
			E('td', { 'class': 'td' }, (st.active === 'auto') ? '★' : ''),
			E('td', { 'class': 'td' }, E('b', {}, _('AUTO (urltest)'))),
			E('td', { 'class': 'td', 'style': 'color:#666' }, _('auto-ping + failover') + ' · ' + _('pool') + ': ' + poolLabel),
			E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, ''),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleSelect', 'auto') }, _('Use')),
				' ',
				E('button', { 'class': 'btn cbi-button', 'title': _('Configure auto-switch pool'),
					'click': ui.createHandlerFn(this, 'handleConfigAuto', st) }, '⚙ ' + _('Configure'))
			])
		]);
		var makeRow = L.bind(function(n) {
			var act = (n.tag === activeTag);
			var pooled = inPool(n.tag);
			var sp = speedResults[n.tag];
			var traf = ((n.down || 0) + (n.up || 0)) > 0 ? ('↓' + fmtBytes(n.down) + ' ↑' + fmtBytes(n.up)) : '—';
			return E('tr', { 'class': 'tr', 'style': act ? 'background:rgba(46,125,50,.12)' : (pooled ? '' : 'opacity:.55') }, [
				E('td', { 'class': 'td' }, act ? '★' : ''),
				E('td', { 'class': 'td' }, [
					n.saved ? E('span', { 'style': 'color:#e0a800;margin-right:4px', 'title': _('Saved') }, '⭐') : '',
					E('span', {}, n.tag),
					pooled ? '' : E('span', { 'style': 'margin-left:6px;font-size:10px;color:#888;border:1px solid #888;border-radius:8px;padding:0 5px',
						'title': _('Excluded from auto-switching (manual only)') }, _('manual')),
					unlockBadges(n.unlock)
				]),
				E('td', { 'class': 'td', 'style': 'font-family:monospace;color:#666' }, (n.server || '') + ':' + (n.port || '')),
				E('td', { 'class': 'td', 'style': 'color:' + pingColor(n.delay) + ';font-weight:bold' }, pingText(n.delay)),
				E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, (sp != null) ? (sp + ' ' + _('Mbit/s')) : '—'),
				E('td', { 'class': 'td', 'style': 'font-family:monospace;color:#666;white-space:nowrap;font-size:11px' }, traf),
				E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleSelect', n.tag) }, _('Use')),
					' ',
					E('button', { 'class': 'btn cbi-button', 'title': n.saved ? _('Remove from saved') : _('Save node (keep after subscription expires)'),
						'click': ui.createHandlerFn(this, n.saved ? 'handleUnsaveNode' : 'handleSaveNode', n.tag) }, n.saved ? '☆' : '⭐'),
					' ',
					E('button', { 'class': 'btn cbi-button', 'title': _('Real speed test'),
						'click': ui.createHandlerFn(this, 'handleSpeedtest', n.tag) }, '⚡'),
					' ',
					E('button', { 'class': 'btn cbi-button', 'title': _('Share link / QR'),
						'click': ui.createHandlerFn(this, 'handleShowLink', n.tag) }, '🔗'),
					' ',
					E('button', { 'class': 'btn cbi-button', 'title': _('Test what this node unblocks'),
						'click': ui.createHandlerFn(this, 'handleUnlock', n.tag) }, '🔓')
				])
			]);
		}, this);

		var order = [ 'subscription', 'imported', 'manual' ];
		var labels = { subscription: _('Subscription'), imported: _('Imported'), manual: _('Manual') };
		var byGroup = {};
		nodes.forEach(function(n) { var g = n.group || 'subscription'; (byGroup[g] = byGroup[g] || []).push(n); });
		var present = order.filter(function(g) { return byGroup[g] && byGroup[g].length; });
		Object.keys(byGroup).forEach(function(g) { if (present.indexOf(g) < 0) { present.push(g); labels[g] = labels[g] || g; } });
		var showHeaders = present.length > 1;
		var bodyRows = [];
		if (!nodes.length)
			bodyRows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': NCOL, 'style': 'color:#888' }, _('No nodes match the filter.')) ]));
		present.forEach(function(g) {
			if (showHeaders)
				bodyRows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': NCOL, 'style': 'background:rgba(128,128,128,.12);font-weight:bold;padding:5px 8px' },
						labels[g] + ' · ' + byGroup[g].length)
				]));
			byGroup[g].forEach(function(n) { bodyRows.push(makeRow(n)); });
		});
		return E('table', { 'class': 'table' }, [ header, autoRow ].concat(bodyRows));
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
		return E('table', { 'class': 'table' }, [ header ].concat(rows));
	},

	load: function() { return callStatus(); },
	render: function(st) {
		this._st = st;
		var c = E('div', { 'class': 'cbi-map' }, [
			i18n.header(_('VPN Pool — Dashboard')),
			E('div', { 'class': 'cbi-section' }, [ E('div', { 'id': 'vp-status' }, this.renderStatus(st)) ]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Nodes')),
				this.renderToolbar(),
				E('div', { 'id': 'vp-nodes' }, this.renderNodes(st))
			]),
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
