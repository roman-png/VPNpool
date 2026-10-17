'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require vpnpool.common as common';

// "Diagnostics" tab (ROADMAP-2.0 §10.6): the checks of the router and "Check the exit through the
// VPN"; the log (the service's lines of the system log or the engine's own log) with a filter,
// up to 500 lines, "Download"; the engine (sing-box): its version, AmneziaWG yes / no and how to
// install or update it; the technical parameters — ONLY here (ports, marks, tables, the engine
// control address, limits that have no field on the settings pages).
// Methods: diag (checks + parameters + engine; heavy — a ping and a request outside — so it runs
// on open and on "Check again", never on a timer), logs (cheap: polled), conntest.
// Technical names (option names, commands, paths) are shown as DATA (not translated strings):
// the texts a human reads stay plain words (stand/tests/ui-text-guard.sh).
// SAFETY: every reply value is foreign data and goes in as text (common.E / common.txt).

var E = common.E;
var txt = common.txt;

var LOG_LINES = [ 50, 200, 500 ];
var LOG_DEFAULT = 200;
// shown to be typed on the router (SSH); data, not texts
var CMD_INSTALL = 'VPNPOOL_AWG=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)';
var CMD_UPDATE = '/usr/libexec/vpnpool/engine.sh update';

var CSS = [
	'.vp-diag .cbi-section{box-sizing:border-box;max-width:100%;min-width:0}',
	'.vp-diag-rows{display:grid;grid-template-columns:minmax(12em,auto) 1fr;gap:.35em 1em;align-items:baseline;max-width:100%}',
	'.vp-diag-label{color:var(--text-color-medium,GrayText);overflow-wrap:anywhere;min-width:0}',
	'.vp-diag-value{overflow-wrap:anywhere;min-width:0}',
	'.vp-diag-name{display:block;font-family:monospace;font-size:.85em;color:var(--text-color-medium,GrayText)}',
	'.vp-diag-mono{font-family:monospace;overflow-wrap:anywhere}',
	'.vp-diag-actions{display:flex;flex-wrap:wrap;align-items:center;gap:.5em;margin:.6em 0 0}',
	'.vp-diag-result{margin:.4em 0 0;overflow-wrap:anywhere}',
	'.vp-diag-cmd{display:block;box-sizing:border-box;max-width:100%;margin:.3em 0 .6em;padding:.4em .6em;border:1px solid var(--border-color-medium,GrayText);border-radius:4px;font-family:monospace;white-space:pre-wrap;overflow-wrap:anywhere;user-select:all}',
	'.vp-log-tools{display:flex;flex-wrap:wrap;align-items:center;gap:.5em;margin:0 0 .5em}',
	'.vp-log-tools input[type=search]{flex:1 1 12em;min-width:0;max-width:100%;box-sizing:border-box}',
	'.vp-log{box-sizing:border-box;max-width:100%;max-height:28em;overflow:auto;margin:0;padding:.5em .7em;border:1px solid var(--border-color-medium,GrayText);border-radius:4px;font-family:monospace;font-size:.85em;white-space:pre-wrap;overflow-wrap:anywhere}',
	'.vp-log-count{color:var(--text-color-medium,GrayText)}',
	'@media (max-width:600px){',
	'.vp-diag-rows{grid-template-columns:1fr;gap:0 0}',
	'.vp-diag-value{margin:0 0 .5em}',
	'.vp-diag-actions>.btn,.vp-log-tools>.btn{flex:1 1 auto}',
	'.vp-log-tools select{flex:1 1 auto}',
	'}'
].join('\n');
function injectCss() {
	if (typeof document === 'undefined' || document.getElementById('vpnpool-diag-css')) return;
	var st = document.createElement('style');
	st.id = 'vpnpool-diag-css';
	st.appendChild(document.createTextNode(CSS));
	(document.head || document.documentElement).appendChild(st);
}

function obj(v) { return (v && typeof v === 'object') ? v : {}; }
function shown(v) { return (v == null || v === '') ? '—' : String(v); }
function okBadge(v, yes, no) { return common.badge(v ? yes : no, v ? 'ok' : 'error'); }
function infoBadge(v, yes, no) { return common.badge(v ? yes : no, v ? 'info' : 'muted'); }
function row(label, value, name) {
	return [
		E('div', { 'class': 'vp-diag-label' }, [ txt(label), name ? E('span', { 'class': 'vp-diag-name' }, [ txt(name) ]) : '' ]),
		E('div', { 'class': 'vp-diag-value' }, [ (value && value.nodeType) ? value : txt(shown(value)) ])
	];
}
function rows(list) {
	var out = [];
	list.forEach(function(r) { if (r) out = out.concat(r); });
	return E('div', { 'class': 'vp-diag-rows' }, out);
}
function section(title, body, cls) {
	return E('div', { 'class': 'cbi-section' + (cls ? ' ' + cls : '') }, [ E('h3', {}, [ txt(title) ]) ].concat(body));
}
function stamp() {
	var d = new Date(Date.now()), p = function(n) { return (n < 10 ? '0' : '') + n; };
	return '' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes());
}
function utf8b64(s) { return btoa(unescape(encodeURIComponent(s))); }

return view.extend({
	load: function() {
		return Promise.all([
			common.call('diag', {}).catch(function() { return null; }),
			common.call('logs', { lines: LOG_DEFAULT, source: 'service' }, { quiet: true }).catch(function() { return null; })
		]);
	},

	// ---- checks
	checksBody: function(d) {
		var s = obj(d.service), n = obj(d.network), c = obj(d.coexist);
		return [
			rows([
				row(_('The service is turned on'), okBadge(s.enabled, _('yes'), _('no'))),
				row(_('The service is running'), okBadge(s.running, _('yes'), _('no'))),
				row(_('Traffic goes through the VPN'), okBadge(s.routing, _('yes'), _('no'))),
				row(_('Starts with the router'), okBadge(s.autostart, _('yes'), _('no'))),
				row(_('The VPN engine answers'), s.running ? okBadge(s.clash_api_ok, _('yes'), _('no')) : common.badge(_('the service is not running'), 'muted')),
				row(_('Internet without the VPN'), okBadge(n.internet, _('works'), _('does not work'))),
				row(_('Exit without the VPN'), (n.direct_ip || n.direct_country) ? [ n.direct_country, n.direct_ip ].filter(Boolean).join(', ') : _('unknown')),
				row(_('podkop on this router'), infoBadge(c.podkop_running || c.podkop_table, _('found'), _('not found'))),
				row(_('zapret on this router'), infoBadge(c.zapret_table, _('found'), _('not found')))
			])
		];
	},

	handleCheck: function() {
		var self = this;
		this.checkBtn.disabled = true;
		return common.call('diag', {}).then(function(d) {
			self.diag = d;
			self.paint();
			common.toast(_('Checked again.'));
		}, function() { return null; }).then(function() { self.checkBtn.disabled = false; });
	},

	handleExit: function() {
		var self = this, out = this.exitOut;
		this.exitBtn.disabled = true;
		out.textContent = _('Checking the exit through the VPN…');
		return common.call('conntest', {}).then(function(r) {
			var t = _('Exit through the VPN: %s, address %s.').format(shown(r.country), shown(r.ip));
			out.textContent = t;
			common.toast(t);
		}, function(e) {
			out.textContent = (e && e.text) || common.codeText('failed');
		}).then(function() { self.exitBtn.disabled = false; });
	},

	// ---- engine
	engineBody: function(d) {
		var g = obj(d.engine), a = obj(g.awg_engine), list = [], how = [];
		list.push(row(_('Version'), g.present === false ? _('not found') : shown(g.version), g.bin));
		list.push(row(_('AmneziaWG'), g.awg ? common.badge(g.awg31 ? _('supported, including 3.1') : _('supported (without 3.1)'), 'ok')
			: common.badge(_('not supported'), 'warn')));
		list.push(row(_('Engine with AmneziaWG'), a.installed
			? txt(_('installed, version %s').format(shown(a.version)) + (a.ram === true ? ' · ' + _('kept in memory (installed again at every start)') : ''))
			: common.badge(_('not installed'), 'muted'), a.path));
		if (a.installed && g.update_available) {
			how.push(E('p', {}, [ txt(_('A newer version of the engine with AmneziaWG is available: %s. To update it, connect to the router over SSH and run:').format(shown(g.target_version))) ]));
			how.push(E('code', { 'class': 'vp-diag-cmd' }, [ txt(CMD_UPDATE) ]));
		} else if (a.installed) {
			how.push(E('p', {}, [ txt(_('The engine with AmneziaWG is up to date. A later version is installed by this command on the router (over SSH):')) ]));
			how.push(E('code', { 'class': 'vp-diag-cmd' }, [ txt(CMD_UPDATE) ]));
		} else {
			how.push(E('p', {}, [ txt(_('For AmneziaWG nodes, install the engine with AmneziaWG: connect to the router over SSH and run:')) ]));
			how.push(E('code', { 'class': 'vp-diag-cmd' }, [ txt(CMD_INSTALL) ]));
		}
		how.push(E('p', { 'class': 'vp-hint' }, [ txt(_('The standard engine is updated with the other packages of the router: System → Software. If podkop is installed, update them together.')) ]));
		return [ rows(list) ].concat(how);
	},

	// ---- technical parameters (only here)
	paramsBody: function(d) {
		var p = obj(d.params), s = obj(d.service), rs = obj(d.rulesets), n = obj(d.network);
		return [
			E('p', { 'class': 'vp-hint' }, [ txt(_('For reference when something goes wrong. They must not coincide with those of other VPN services on the router (podkop has its own). They are changed only on the router itself.')) ]),
			rows([
				row(_('Port that receives the routed traffic'), p.tproxy_port, 'tproxy_port'),
				row(_('Port for checks through the VPN'), p.test_port, 'test_port'),
				row(_('Port for testing one node'), p.node_test_port, 'node_test_port'),
				row(_('Mark of the routed traffic'), p.fwmark, 'fwmark'),
				row(_('Routing table and its priority'), shown(p.route_table) + ' / ' + shown(p.route_priority), 'route_table / route_priority'),
				row(_('Engine control address'), p.clash_api, 'clash_api'),
				row(_('Network of the devices'), p.lan_if ? (p.lan_if + (p.lan_if_auto ? ' (' + _('found automatically') + ')' : '')) : null, 'lan_if'),
				row(_('Living next to other VPN services'), p.coexist, 'coexist'),
				row(_('Order of name lookups'), p.dns_strategy, 'dns_strategy'),
				row(_('Address of the connection check'), p.health_url, 'health_url'),
				row(_('Largest subscription download, KB'), p.fetch_max_kb, 'fetch_max_kb'),
				row(_('Free memory a speed test needs, KB'), p.speedtest_min_mem_kb, 'speedtest_min_mem_kb'),
				row(_('Sites checked per search run'), p.adaptive_max_per_run, 'adaptive_max_per_run'),
				row(_('Engine program'), p.singbox_bin || _('chosen automatically'), 'singbox_bin'),
				row(_('Program names used to download subscriptions'), p.probe_ua || _('the standard list'), 'probe_ua'),
				row(_('Engine process number'), s.singbox_pid),
				row(_('Ready-made lists in use'), rs.communities),
				row(_('Copy of the ready-made lists'), rs.cache_present ? _('%d KB').format(+rs.cache_kb || 0) : _('none yet')),
				row(_('Internet connection of the router'), [ n.wan_iface, n.gateway ].filter(Boolean).join(' · ') || null)
			])
		];
	},

	// ---- log
	logView: function() {
		var self = this;
		this.logSource = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Which log'), 'change': function() { self.loadLog(); } }, [
			E('option', { 'value': 'service' }, [ txt(_('The service')) ]),
			E('option', { 'value': 'engine' }, [ txt(_('The VPN engine')) ])
		]);
		this.logSource.value = 'service';
		this.logCount = E('select', { 'class': 'cbi-input-select', 'aria-label': _('How many lines'), 'change': function() { self.loadLog(); } },
			LOG_LINES.map(function(n) { return E('option', { 'value': String(n) }, [ txt(_('last %d lines').format(n)) ]); }));
		this.logCount.value = String(LOG_DEFAULT);
		this.logFilter = E('input', { 'type': 'search', 'class': 'cbi-input-text', 'placeholder': _('Filter: show the lines with this text'),
			'aria-label': _('Filter'), 'input': function() { self.paintLog(); } });
		this.logPre = E('pre', { 'class': 'vp-log', 'aria-live': 'off' }, [ txt('') ]);
		this.logInfo = E('p', { 'class': 'vp-log-count' }, [ txt('') ]);
		return [
			E('div', { 'class': 'vp-log-tools' }, [
				this.logSource, this.logCount, this.logFilter,
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button', 'click': ui.createHandlerFn(this, 'loadLog') }, [ txt(_('Refresh')) ]),
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'type': 'button', 'click': ui.createHandlerFn(this, 'handleDownload') }, [ txt(_('Download')) ])
			]),
			this.logInfo,
			this.logPre
		];
	},

	shownLines: function() {
		var all = (this.log && Array.isArray(this.log.lines)) ? this.log.lines : [];
		var f = String(this.logFilter ? this.logFilter.value : '').trim().toLowerCase();
		if (!f) return all;
		return all.filter(function(l) { return String(l).toLowerCase().indexOf(f) >= 0; });
	},

	paintLog: function() {
		if (!this.logPre) return;
		var all = (this.log && Array.isArray(this.log.lines)) ? this.log.lines : [];
		var lines = this.shownLines();
		var text = this.logError ? '' : (lines.length ? lines.join('\n') : (all.length ? _('No line has this text.') : _('The log is empty.')));
		if (this.logPre.textContent !== text) {
			var atEnd = (this.logPre.scrollHeight - this.logPre.scrollTop - this.logPre.clientHeight) < 24;
			dom.content(this.logPre, [ txt(text) ]);
			if (atEnd) this.logPre.scrollTop = this.logPre.scrollHeight;
		}
		var info = this.logError ? this.logError
			: (lines.length === all.length ? _('Lines: %d').format(all.length) : _('Lines: %d of %d').format(lines.length, all.length));
		if (this.logInfo.textContent !== info) this.logInfo.textContent = info;
	},

	loadLog: function() {
		var self = this;
		var src = this.logSource ? this.logSource.value : 'service';
		var n = this.logCount ? +this.logCount.value : LOG_DEFAULT;
		return common.call('logs', { lines: n, source: src }, { quiet: true }).then(function(r) {
			self.log = r; self.logError = null;
			self.paintLog();
		}, function(e) {
			self.logError = (e && e.text) || common.codeText('failed');
			self.paintLog();
		});
	},

	handleDownload: function() {
		var lines = this.shownLines();
		if (!lines.length) { common.toast(_('The log is empty.'), 'warning', 'logs'); return; }
		var src = this.logSource ? this.logSource.value : 'service';
		common.download('vpnpool-' + (src === 'engine' ? 'engine' : 'log') + '-' + stamp() + '.txt', utf8b64(lines.join('\n') + '\n'), 'text/plain');
	},

	// ---- page
	paint: function() {
		var d = this.diag;
		if (!d) {
			dom.content(this.checksBox, [ E('p', { 'class': 'vp-hint' }, [ txt(_('The router did not give the diagnostics. Press "Check again".')) ]) ]);
			dom.content(this.engineBox, [ txt('') ]);
			dom.content(this.paramsBox, [ txt('') ]);
			return;
		}
		dom.content(this.checksBox, this.checksBody(d));
		dom.content(this.engineBox, this.engineBody(d));
		dom.content(this.paramsBox, this.paramsBody(d));
	},

	render: function(data) {
		injectCss();
		this.diag = (data && data[0]) || null;
		this.log = (data && data[1]) || null;
		this.logError = (data && data[1]) ? null : _('The log could not be read.');
		this.checksBox = E('div', { 'class': 'vp-diag-checks' });
		this.engineBox = E('div', { 'class': 'vp-diag-engine' });
		this.paramsBox = E('div', { 'class': 'vp-diag-params' });
		this.checkBtn = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button', 'click': ui.createHandlerFn(this, 'handleCheck') }, [ txt(_('Check again')) ]);
		this.exitBtn = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button', 'click': ui.createHandlerFn(this, 'handleExit') }, [ txt(_('Check the exit through the VPN')) ]);
		this.exitOut = E('p', { 'class': 'vp-diag-result', 'aria-live': 'polite' }, [ txt('') ]);
		var root = E('div', { 'class': 'cbi-map vp-page vp-diag' }, [
			common.header(_('Diagnostics')),
			section(_('Checks'), [ this.checksBox, E('div', { 'class': 'vp-diag-actions' }, [ this.checkBtn, this.exitBtn ]), this.exitOut ]),
			section(_('Log'), this.logView()),
			section(_('VPN engine'), [ this.engineBox ]),
			section(_('Technical parameters'), [ this.paramsBox ])
		]);
		this.paint();
		this.paintLog();
		poll.add(L.bind(this.loadLog, this), 10);
		poll.start();
		return root;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
