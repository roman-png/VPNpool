'use strict';
'require view';
'require form';
'require ui';
'require rpc';
'require poll';
'require dom';
'require vpnpool.common as common';

// TEMPORARY component showcase for the stand (ROADMAP-2.0 §10.1), not in the menu: the stand
// test stand/tests/ui-components.sh mounts a route for it. Removed with the screen packs.
// Strings here are plain English on purpose (not translated, not in po/).
// window.vpDemo.selfTest() returns the platform/feature probe used for the LuCI
// compatibility table; window.vpDemo.jsonmap holds the JSONMap form for probing.

// JSONMap data: an object value = one named section (its key is the name and the type)
var DATA = {
	main: { enabled: '1', port: '1605', mode: 'auto', name: 'Router' }
};

function cssVar(name) {
	try { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
	catch (e) { return ''; }
}

function selfTest() {
	var r = {
		luci_version: (L.env && (L.env.luciversion || L.env.version)) || null,
		jsonmap: typeof form.JSONMap === 'function',
		jsonmap_handles: !!(form.JSONMap && form.JSONMap.prototype && typeof form.JSONMap.prototype.save === 'function' && typeof form.JSONMap.prototype.reset === 'function'),
		view_handleSave: typeof view.prototype === 'object' ? typeof (view.prototype.handleSave) === 'function' : null,
		addNotification: typeof ui.addNotification === 'function',
		addTimeLimitedNotification: typeof ui.addTimeLimitedNotification === 'function',
		showModal: typeof ui.showModal === 'function',
		hideModal: typeof ui.hideModal === 'function',
		createHandlerFn: typeof ui.createHandlerFn === 'function',
		poll_add: typeof poll.add === 'function',
		rpc_declare: typeof rpc.declare === 'function',
		resolveDefault: typeof L.resolveDefault === 'function',
		translate_fn: typeof _ === 'function',
		translations_loaded: !!(window.TR && Object.keys(window.TR).length),
		darkmode_attr: document.documentElement.getAttribute('data-darkmode'),
		css_bg_high: cssVar('--background-color-high'),
		css_text_high: cssVar('--text-color-high'),
		css_border_medium: cssVar('--border-color-medium'),
		css_error_medium: cssVar('--error-color-medium'),
		common_loaded: !!(common && typeof common.call === 'function'),
		common_methods: common ? Object.keys(common.METHODS).length : 0,
		common_css: !!document.getElementById('vpnpool-common-css'),
		page_scroll_x: document.documentElement.scrollWidth > document.documentElement.clientWidth
	};
	return r;
}

return view.extend({
	load: function() {
		return L.resolveDefault(common.call('status', {}, { quiet: true }), null);
	},

	render: function(status) {
		var self = this;
		var log = E('pre', { 'id': 'vp-demo-log', 'style': 'white-space:pre-wrap;max-height:12em;overflow:auto' }, '');
		function out(s) { log.textContent = s + '\n' + log.textContent; }

		var m = new form.JSONMap(DATA, 'Components (stand only)', 'JSONMap probe: a port field (datatype), a switch and a field that depends on it.');
		var s = m.section(form.NamedSection, 'main', 'main', 'Form');
		var o;
		o = s.option(form.Flag, 'enabled', 'Enabled');
		o.rmempty = false;
		o = s.option(form.Value, 'port', 'Port');
		o.datatype = 'port';
		o.depends('enabled', '1');
		o = s.option(form.ListValue, 'mode', 'Mode');
		o.value('auto', 'Automatic');
		o.value('manual', 'Manual');
		o = s.option(form.Value, 'name', 'Name');
		o.depends('mode', 'manual');
		this.jsonmap = m;

		var cards = E('div', { 'id': 'vp-demo-cards' });
		var states = [
			{ id: 'n1', title: '🇩🇪 Germany, Frankfurt — a very long node name that has to wrap on a phone', sub: 'VLESS · 42 ms', state: 'in automatic choice', badges: [ { text: 'YouTube', kind: 'ok' }, { text: 'Telegram', kind: 'ok' } ], active: true },
			{ id: 'n2', title: '🇳🇱 Amsterdam', sub: 'Trojan · 180 ms', state: 'does not open youtube.com: 3 checks in a row', stateKind: 'error', badges: [ { text: 'YouTube', kind: 'error' } ] },
			{ id: 'n3', title: 'AmneziaWG home', sub: 'AmneziaWG', state: 'waits for the AmneziaWG engine', badges: [ { text: 'waiting', kind: 'warn' } ], dimmed: true }
		];
		var cardEls = states.map(function(st) {
			var el = common.nodeCard({
				id: st.id, title: st.title, sub: st.sub, state: st.state, stateKind: st.stateKind, badges: st.badges,
				active: st.active, dimmed: st.dimmed,
				onSelect: function(c) { out('select ' + st.id + ' = ' + c); },
				primary: { label: 'Connect', handler: function() { common.toast('Connected to ' + st.id); } },
				menu: [
					{ label: 'Add to favourites', handler: function() { common.toast('favourite ' + st.id); } },
					{ label: 'Speed test', handler: function() { common.toast('speed ' + st.id); } },
					{ label: 'Disabled item', disabled: true },
					{ label: 'Delete', danger: true, handler: function() {
						return common.confirm({ title: 'Delete node?', text: st.title, danger: true, confirm: 'Delete',
							consequences: [ 'The node disappears from the list.', 'If it came from a subscription, it is hidden until the subscription is deleted.' ] })
							.then(function(yes) { out('confirm ' + st.id + ' -> ' + yes); });
					} }
				]
			});
			cards.appendChild(el);
			return el;
		});
		var tick = 0;

		var btn = function(id, label, fn) {
			return E('button', { 'id': id, 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, fn) }, label);
		};

		var res = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:.4em;margin:.5em 0' }, [
			btn('vp-t-info', 'Info toast', function() { common.toast('Info ' + (++tick)); }),
			btn('vp-t-info3', '3 info toasts', function() { common.toast('A'); common.toast('B'); common.toast('C (only this one stays)'); }),
			btn('vp-t-err', 'Error toast', function() { common.toast('Error ' + (++tick), 'error'); }),
			btn('vp-t-clear', 'Clear toasts', function() { common.clearToast(); }),
			btn('vp-c-status', 'call(status)', function() {
				return common.call('status').then(function(r) { out('status keys: ' + Object.keys(r).join(', ')); }, function(e) { out('status error: ' + e.code); });
			}),
			btn('vp-c-missing', 'call(unknown method)', function() {
				return common.call('no_such_method').catch(function(e) { out('no_such_method -> ' + e.code); });
			}),
			btn('vp-c-select', 'call(select) without a node', function() {
				return common.call('select', {}).catch(function(e) { out('select {} -> ' + e.code); });
			}),
			btn('vp-w-ok', 'waitFor (true)', function() {
				return common.waitFor(function() { return true; }, { timeout: 5000, interval: 500 }).then(function() { out('waitFor true -> resolved'); });
			}),
			btn('vp-w-to', 'waitFor (timeout 3 s)', function() {
				return common.waitFor(function() { return false; }, { timeout: 3000, interval: 1000 }).catch(function(e) { out('waitFor false -> ' + e.code); });
			}),
			btn('vp-u-cells', 'Update cells', function() {
				tick++;
				common.updateNodeCard(cardEls[1], { sub: 'Trojan · ' + (100 + tick) + ' ms', state: tick % 2 ? 'in automatic choice' : 'excluded by you', badges: [ { text: 'YouTube', kind: tick % 2 ? 'ok' : 'error' } ] });
				common.updateNodeCard(cardEls[0], { active: tick % 2 === 0 });
			}),
			btn('vp-confirm', 'Confirm dialog', function() {
				return common.confirm({ title: 'Replace everything?', text: 'The backup replaces the current settings.',
					consequences: [ '12 nodes are restored.', 'Routing settings are replaced.', 'The service restarts.' ] })
					.then(function(v) { out('confirm -> ' + v); });
			})
		]);

		window.vpDemo = { selfTest: selfTest, jsonmap: m, common: common, cards: cardEls, out: out };

		return m.render().then(function(formEl) {
			return E('div', { 'class': 'vpnpool-view vp-demo' }, [
				E('h2', {}, 'VPN Pool — components (stand only)'),
				E('p', {}, 'Status from the router: ' + (status ? 'answered (' + Object.keys(status).length + ' fields)' : 'no answer')),
				E('h3', {}, 'Badges'),
				E('div', { 'id': 'vp-demo-badges', 'style': 'display:flex;flex-wrap:wrap;gap:.4em' }, [
					common.badge('works', 'ok'), common.badge('slow', 'warn'), common.badge('down', 'error'),
					common.badge('favourite', 'info'), common.badge('hidden', 'muted')
				]),
				E('h3', {}, 'Empty state'),
				E('div', { 'id': 'vp-demo-empty' }, common.emptyState({ title: 'No nodes yet', text: 'Add a subscription or a node to start.',
					actions: [ { label: '+ Add', primary: true, handler: function() { common.toast('add'); } }, { label: 'How it works', handler: function() { common.toast('help'); } } ] })),
				E('h3', {}, 'Node cards'),
				cards,
				E('h3', {}, 'Actions'),
				res,
				log,
				formEl
			]);
		});
	},

	handleSaveApply: null,

	handleSave: function(ev) {
		var m = this.jsonmap;
		return m.save().then(function() {
			var d = m.data.get('json', 'main');
			var txt = JSON.stringify({ enabled: d.enabled, port: d.port, mode: d.mode, name: d.name });
			window.vpDemo.saved = txt;
			window.vpDemo.out('JSONMap saved: ' + txt);
			common.toast('Form saved');
		}, function(e) {
			window.vpDemo.saveError = String(e && e.message || e);
			window.vpDemo.out('JSONMap save rejected: ' + window.vpDemo.saveError);
		});
	},

	handleReset: function(ev) {
		return this.jsonmap.reset();
	}
});
