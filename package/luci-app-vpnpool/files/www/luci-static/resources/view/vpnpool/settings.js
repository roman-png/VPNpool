'use strict';
'require view';
'require form';
'require dom';
'require vpnpool.common as common';

// "Settings" page (ROADMAP-2.0 §10.5). Two form.JSONMap (the main settings and the folded
// "Advanced"), ONE save panel for both (common.formSaver -> one set_config with the changed
// fields only). Not settings, so not in the save: the Telegram test (it sends what is TYPED,
// before saving) and the backup (download / restore from a file).
// Technical parameters (ports, marks, the engine) are shown only on the Diagnostics page.
// SAFETY: LuCI puts option titles and descriptions into innerHTML — our own texts only.

// LuCI E(tag, attrs, 'string') = innerHTML; every string child goes in as text (common.E)
var E = common.E;
var txt = common.txt;

// The file goes as base64 inside ONE JSON-RPC request; uhttpd refuses a request body over 64 KiB
// (measured on the stand, 24.10 and 25.12: 65536 bytes pass, 65537 -> -32700 Parse error).
// 60000 base64 characters leave room for the envelope and a call LuCI batches along: a file up
// to 45000 bytes. Bigger archives need an upload to the router (cgi-upload + restore {path}).
var RESTORE_MAX_B64 = 60000;
var RESTORE_MAX_BYTES = RESTORE_MAX_B64 / 4 * 3;

// A restore file that is not an archive: the text copy of the settings an older version (1.x)
// saved with "Export" (the configuration as text). The router checks it and moves it to this
// version (import: incomplete, masked or invalid copies are refused, nothing changes then).
function isGzip(bytes) { return bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b; }
function textOf(bytes) {
	if (typeof TextDecoder === 'function') {
		try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch (e) { return null; }
	}
	var s = '';
	for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
	try { return decodeURIComponent(escape(s)); } catch (e) { return null; }
}
function looksLikeConfig(t) { return typeof t === 'string' && /^[ \t]*(package[ \t]+vpnpool|config[ \t]+vpnpool[ \t])/m.test(t); }
// bytes of the text inside the JSON-RPC request (escapes and UTF-8 counted)
function jsonBytes(t) { return unescape(encodeURIComponent(JSON.stringify(t))).length; }

function settings(st) { return (st && st.settings) || {}; }
function sv(name, def) { return function(st) { var v = settings(st)[name]; return (v == null) ? def : v; }; }
function bool(name, def) { return function(st) { var v = settings(st)[name]; return (v == null) ? def : !!v; }; }

// The page's settings: set_config field <-> form option (common.formSaver, kinds there).
var FIELDS = [
	{ f: 'auto_switch', o: 'auto.auto_switch', t: 'bool', v: bool('auto_switch', true) },
	{ f: 'favorites_only', o: 'auto.favorites_only', t: 'bool', v: bool('favorites_only', false) },
	{ f: 'auto_snapshot', o: 'auto.auto_snapshot', t: 'bool', v: bool('auto_snapshot', false) },
	{ f: 'auto_snapshot_max', o: 'auto.auto_snapshot_max', t: 'int', v: sv('auto_snapshot_max', 20) },
	{ f: 'check_services', o: 'check.check_services', t: 'words', v: sv('check_services', '') },
	{ f: 'dead_filter', o: 'check.dead_filter', t: 'bool', v: bool('dead_filter', true) },
	{ f: 'killswitch', o: 'protect.killswitch', t: 'bool', v: bool('killswitch', false) },
	{ f: 'dns_protect', o: 'protect.dns_protect', t: 'bool', v: bool('dns_protect', false) },
	{ f: 'telegram_enabled', o: 'telegram.telegram_enabled', t: 'bool', v: bool('telegram_enabled', false) },
	{ f: 'telegram_control', o: 'telegram.telegram_control', t: 'bool', v: bool('telegram_control', false) },
	// the router shows a saved token masked (<bot number>:***); sent back unchanged = keep it
	{ f: 'telegram_token', o: 'telegram.telegram_token', t: 'str', v: sv('telegram_token', '') },
	{ f: 'telegram_chat', o: 'telegram.telegram_chat', t: 'str', v: sv('telegram_chat', '') },
	{ f: 'telegram_via_proxy', o: 'telegram.telegram_via_proxy', t: 'bool', v: bool('telegram_via_proxy', true) },
	{ f: 'sched_enabled', o: 'schedule.sched_enabled', t: 'bool', v: bool('sched_enabled', false) },
	{ f: 'sched_on', o: 'schedule.sched_on', t: 'str', v: sv('sched_on', '') },
	{ f: 'sched_off', o: 'schedule.sched_off', t: 'str', v: sv('sched_off', '') },
	{ f: 'sched_refresh', o: 'schedule.sched_refresh', t: 'str', v: sv('sched_refresh', '') },
	// "Advanced" (folded)
	{ f: 'failover_interval', o: 'adv.failover_interval', t: 'int', v: sv('failover_interval', 60) },
	{ f: 'failover_tolerance', o: 'adv.failover_tolerance', t: 'int', v: sv('failover_tolerance', 50) },
	{ f: 'dead_filter_strikes', o: 'adv.dead_filter_strikes', t: 'int', v: sv('dead_filter_strikes', 3) },
	{ f: 'dead_filter_tries', o: 'adv.dead_filter_tries', t: 'int', v: sv('dead_filter_tries', 3) },
	{ f: 'subscription_interval', o: 'adv.subscription_interval', t: 'str', v: sv('subscription_interval', '6h') },
	{ f: 'antidpi', o: 'adv.antidpi', t: 'str', v: sv('antidpi', 'off') },
	{ f: 'ipv6', o: 'adv.ipv6', t: 'str', v: sv('ipv6', 'block') },
	{ f: 'log_level', o: 'adv.log_level', t: 'str', v: sv('log_level', 'warn') },
	{ f: 'prefilter_concurrency', o: 'adv.prefilter_concurrency', t: 'int', v: sv('prefilter_concurrency', 16) }
];

var INTERVALS = [
	[ '10m', _('10 minutes') ], [ '30m', _('30 minutes') ], [ '1h', _('1 hour') ], [ '3h', _('3 hours') ],
	[ '6h', _('6 hours') ], [ '12h', _('12 hours') ], [ '24h', _('24 hours') ]
];
var LOG_LEVELS = [
	[ 'trace', _('Everything (very large)') ], [ 'debug', _('Detailed') ], [ 'info', _('Normal') ],
	[ 'warn', _('Warnings and errors') ], [ 'error', _('Errors only') ], [ 'fatal', _('Severe errors only') ],
	[ 'panic', _('Crashes only') ]
];

function timeOk(section_id, v) {
	return (v == null || v === '' || /^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(String(v).trim())) ? true
		: common.fieldText('bad_time');
}

// An input-less option: our own widget (buttons, a line of explanation)
var Action = form.DummyValue.extend({
	renderWidget: function(section_id) {
		return this.build(section_id);
	}
});

return view.extend({
	FIELDS: FIELDS,

	load: function() {
		return common.call('status');
	},

	// Telegram test: what the page shows NOW (typed, not saved). A masked token = the saved one.
	testTelegram: function() {
		var saver = this.saver, cur = saver.collect(), mine = [ 'telegram_token', 'telegram_chat' ];
		saver.clearErrors(mine);   // marks of an earlier test (a save's marks of other fields stay)
		return common.call('tg_test', { token: cur.telegram_token, chat: cur.telegram_chat, via_proxy: cur.telegram_via_proxy },
			{ handle: [ 'invalid' ], success: _('The test message is sent: check Telegram.') }).then(null, function(e) {
			if (e && e.code === 'invalid') {
				saver.sent = {};
				saver.showErrors(e, mine);
				common.toast(common.codeText('invalid'), 'error', 'tg_test');
			}
			return null;
		});
	},

	downloadBackup: function() {
		return common.call('backup', {}).then(function(r) {
			if (!r || typeof r.data !== 'string' || !r.data) throw new common.Error('bad_reply', 'backup', r);
			common.download(r.name || 'vpnpool-backup.tar.gz', r.data, 'application/gzip');
			var rep = r.report || {};
			common.toast(_('The backup is downloaded. Nodes: %d, subscriptions: %d, favourites: %d.')
				.format(+rep.nodes || 0, +rep.subscriptions || 0, +rep.saved || 0));
			return r;
		}).catch(function(e) {
			if (e instanceof common.Error && e.code === 'bad_reply') common.toast(e.text, 'error', 'backup');
			return null;
		});
	},

	// Restore: the router checks the file first and says what it holds; replacing needs a yes
	restoreFile: function(file) {
		var self = this;
		if (!file) return Promise.resolve(null);
		var tooBig = function() {
			common.toast(_('This file is too large to upload through the page: at most %d KB.').format(Math.floor(RESTORE_MAX_BYTES / 1024)), 'error', 'restore');
			return null;
		};
		if (Math.ceil(file.size / 3) * 4 > RESTORE_MAX_B64) return Promise.resolve(tooBig());
		return common.readFileBase64(file).then(function(b64) {
			if (b64.length > RESTORE_MAX_B64) return tooBig();
			var bytes = common.b64ToBytes(b64);
			if (!isGzip(bytes)) return self.importText(textOf(bytes), tooBig);
			return common.call('restore', { data: b64 }, { handle: [ 'confirm_required' ] }).then(function() {
				return null;   // the router never replaces without replace_all: nothing happened
			}, function(e) {
				if (!e || e.code !== 'confirm_required') return null;
				var rep = (e.reply && e.reply.report) || {};
				var cons = [
					_('Nodes: %d').format(+rep.nodes || 0),
					_('Subscriptions: %d').format(+rep.subscriptions || 0),
					_('Favourites: %d').format(+rep.saved || 0),
					_('AmneziaWG and WireGuard nodes: %d').format(+rep.awg || 0)
				];
				if (self.saver && self.saver.dirty()) cons.push(_('The unsaved changes on this page are lost.'));
				return common.confirm({
					title: _('Restore from this backup?'),
					text: _('All current settings, subscriptions and nodes are replaced by the ones from the file. The file holds:'),
					consequences: cons,
					confirm: _('Replace everything'),
					danger: true
				}).then(function(yes) {
					if (!yes) return null;
					return common.call('restore', { data: b64, replace_all: true },
						// the service off: "Restored." + common's note that it waits for the service
						{ success: function(r) { return (r && r.daemon === 'not_running') ? common.codeText('restored')
							: _('Restored. The service starts again with the restored settings.'); } })
						.then(function(r) { return self.reload().then(function() { return r; }); }, function() { return null; });
				});
			});
		}, function() {
			common.toast(common.codeText('invalid_archive'), 'error', 'restore');
			return null;
		});
	},

	// the text copy of an older version: the router can't check it without importing, so the
	// page asks first (what is replaced), then import
	importText: function(text, tooBig) {
		var self = this;
		if (!looksLikeConfig(text)) {
			common.toast(common.codeText('invalid_archive'), 'error', 'restore');
			return Promise.resolve(null);
		}
		if (jsonBytes(text) > RESTORE_MAX_B64) return Promise.resolve(tooBig());
		var cons = [ _('The subscriptions, nodes and settings in the file are moved over to this version.') ];
		if (self.saver && self.saver.dirty()) cons.push(_('The unsaved changes on this page are lost.'));
		return common.confirm({
			title: _('Restore the settings of an older version?'),
			text: _('This is a text copy of the settings saved by an older version of VPN Pool, not a backup file. All current settings, subscriptions and nodes are replaced by the ones from it.'),
			consequences: cons,
			confirm: _('Replace everything'),
			danger: true
		}).then(function(yes) {
			if (!yes) return null;
			return common.call('import', { config: text },
				{ success: function(r) { return (r && r.daemon === 'not_running') ? common.codeText('restored')
					: _('Restored. The service starts again with the restored settings.'); } })
				.then(function(r) { return self.reload().then(function() { return r; }); }, function() { return null; });
		});
	},

	render: function(st) {
		var self = this;
		st = st || {};
		var fd = common.formData(FIELDS, st);
		var adv = { adv: fd.adv };
		delete fd.adv;
		fd.backup = {};
		var m = new form.JSONMap(fd, null, null);
		var ma = new form.JSONMap(adv, null, null);
		var s, o;

		// ---- automatic switching
		s = m.section(form.NamedSection, 'auto', 'auto', _('Automatic switching'));
		s.option(form.Flag, 'auto_switch', _('Switch to a working node automatically'),
			_('When the current node stops working, the router moves to the fastest working one.'));
		s.option(form.Flag, 'favorites_only', _('Choose only among favourite nodes'),
			_('The automatic choice uses only your favourite nodes while at least one of them works.'));
		s.option(form.Flag, 'auto_snapshot', _('Add working nodes to favourites automatically'),
			_('From time to time the fastest working nodes are kept in favourites, so they stay when a subscription ends. Your own favourites are never touched.'));
		o = s.option(form.Value, 'auto_snapshot_max', _('How many to keep'));
		o.datatype = 'and(uinteger,range(1,1000))';
		o.placeholder = '20';
		o.depends('auto_snapshot', '1');

		// ---- checked services
		s = m.section(form.NamedSection, 'check', 'check', _('Checked sites'));
		o = s.option(form.TextValue, 'check_services', _('Sites to check'),
			_('The sites the VPN must really open, one per line — usually the blocked ones, for example youtube.com. The automatic choice uses a node only if it opens every one of them. Empty: a general internet check.'));
		o.rows = 4;
		o.placeholder = 'www.youtube.com';
		s.option(form.Flag, 'dead_filter', _('Set aside nodes that do not open these sites'),
			_('Such nodes stay in the list and can be chosen by hand, but the automatic choice skips them.'));

		// ---- protection
		s = m.section(form.NamedSection, 'protect', 'protect', _('Protection'));
		s.option(form.Flag, 'killswitch', _('Block the internet while the VPN is down'),
			_('While no node works, what should go through the VPN does not go directly: with "everything except the chosen sites" that is the whole internet, with "only the chosen sites" only those sites. Off: it goes directly until a node works again.'));
		s.option(form.Flag, 'dns_protect', _('Send site name lookups through the VPN'),
			_('The internet provider does not see which sites the devices look up.'));

		// ---- Telegram
		s = m.section(form.NamedSection, 'telegram', 'telegram', _('Telegram'));
		s.option(form.Flag, 'telegram_enabled', _('Send notifications'),
			_('About node switching, subscription ends, start and stop.'));
		s.option(form.Flag, 'telegram_control', _('Control from Telegram'),
			_('Commands to the bot: status, nodes, switching, on and off. The bot obeys only your chat.'));
		var tgDeps = function(opt) { opt.depends('telegram_enabled', '1'); opt.depends('telegram_control', '1'); };
		o = s.option(form.Value, 'telegram_token', _('Bot token'), _('Create a bot with @BotFather and paste its token here.'));
		o.password = true;
		o.placeholder = '123456789:ABC…';
		tgDeps(o);
		o = s.option(form.Value, 'telegram_chat', _('Chat'), _('Your chat number (for example from @userinfobot) or a channel name like @mychannel.'));
		o.placeholder = '123456789';
		tgDeps(o);
		o = s.option(form.Flag, 'telegram_via_proxy', _('Reach Telegram through the VPN'), _('Needed where Telegram is blocked.'));
		tgDeps(o);
		o = s.option(Action, 'tg_test', '');
		o.build = function() {
			return E('div', {}, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button', 'click': function(ev) {
					ev.preventDefault(); self.testTelegram();
				} }, [ txt(_('Send a test message')) ]),
				E('p', { 'class': 'vp-hint' }, [ txt(_('Uses the token and the chat typed above, even before you save them.')) ])
			]);
		};
		tgDeps(o);

		// ---- schedule
		s = m.section(form.NamedSection, 'schedule', 'schedule', _('Schedule'));
		s.option(form.Flag, 'sched_enabled', _('Turn on and off by the clock'), _('The router\'s time. Leave a time empty to skip that action.'));
		[ [ 'sched_on', _('Turn on at') ], [ 'sched_off', _('Turn off at') ], [ 'sched_refresh', _('Update subscriptions at') ] ].forEach(function(x) {
			o = s.option(form.Value, x[0], x[1]);
			o.placeholder = '07:30';
			o.validate = timeOk;
			o.depends('sched_enabled', '1');
		});

		// ---- backup (actions, not settings)
		s = m.section(form.NamedSection, 'backup', 'backup', _('Backup'),
			_('A file with all settings, subscriptions and nodes, including the Telegram token. Keep it safe.'));
		o = s.option(Action, 'files', '');
		o.build = function() {
			var file = E('input', { 'type': 'file', 'accept': '.gz,.tgz,.txt,.conf,application/gzip,text/plain', 'style': 'display:none', 'change': function(ev) {
				var f = ev.target.files && ev.target.files[0];
				ev.target.value = '';
				self.restoreFile(f);
			} });
			return E('div', { 'class': 'vp-inline' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button', 'click': function(ev) {
					ev.preventDefault(); self.downloadBackup();
				} }, [ txt(_('Download a backup')) ]),
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'type': 'button', 'click': function(ev) {
					ev.preventDefault(); file.click();
				} }, [ txt(_('Restore from a file…')) ]),
				file,
				E('p', { 'class': 'vp-hint' }, [ txt(_('A text copy of the settings saved by an older version can be restored here too.')) ])
			]);
		};

		// ---- advanced (folded)
		s = ma.section(form.NamedSection, 'adv', 'adv', null);
		o = s.option(form.Value, 'failover_interval', _('Node check interval, s'));
		o.datatype = 'and(uinteger,range(10,86400))';
		o.placeholder = '60';
		o = s.option(form.Value, 'failover_tolerance', _('Switching threshold, ms'),
			_('Keeps the router from jumping between nodes of almost the same speed.'));
		o.datatype = 'and(uinteger,range(0,5000))';
		o.placeholder = '50';
		o = s.option(form.Value, 'dead_filter_strikes', _('Failed checks in a row before a node is set aside'));
		o.datatype = 'and(uinteger,range(1,100))';
		o.placeholder = '3';
		o = s.option(form.Value, 'dead_filter_tries', _('Attempts per check'),
			_('A node passes a check if any attempt succeeds: some nodes miss the first one.'));
		o.datatype = 'and(uinteger,range(1,10))';
		o.placeholder = '3';
		o = s.option(form.ListValue, 'subscription_interval', _('Update subscriptions every'),
			_('More often than every 10 minutes is not allowed: providers block too frequent updates.'));
		INTERVALS.forEach(function(x) { o.value(x[0], x[1]); });
		var curInt = String(settings(st).subscription_interval || '');
		if (curInt && !INTERVALS.some(function(x) { return x[0] === curInt; })) o.value(curInt, curInt);
		o = s.option(form.ListValue, 'antidpi', _('Get past the provider\'s filtering'),
			_('Splits the start of secure connections so that simple provider filters cannot read the site name. Does not help against strong blocking.'));
		o.value('off', _('Off'));
		o.value('on', _('Normal'));
		o.value('aggressive', _('Strong'));
		o = s.option(form.Flag, 'ipv6', _('Block IPv6 past the VPN'),
			_('Devices cannot reach the internet over IPv6, so nothing leaks past the VPN.'));
		o.enabled = 'block';
		o.disabled = 'off';
		o = s.option(form.ListValue, 'log_level', _('Log detail'), _('What the log on the Diagnostics page keeps.'));
		LOG_LEVELS.forEach(function(x) { o.value(x[0], x[1]); });
		o = s.option(form.Value, 'prefilter_concurrency', _('Nodes checked at once'),
			_('Lower it on a router with little memory.'));
		o.datatype = 'and(uinteger,range(1,64))';
		o.placeholder = '16';

		return Promise.all([ m.render(), ma.render() ]).then(function(nodes) {
			self.map = m;
			self.advMap = ma;
			self.saver = common.formSaver({ fields: FIELDS, maps: [ m, ma ], onSaved: function() { return self.reload(); } });
			var box = self.box || (self.box = E('div', { 'class': 'vp-page' }));
			var more = E('details', { 'class': 'vp-more' }, [ E('summary', {}, [ txt(_('Advanced')) ]), nodes[1] ]);
			if (self.advOpen) more.open = true;
			more.addEventListener('toggle', function() { self.advOpen = more.open; });
			dom.content(box, [
				common.header(_('Settings')),
				nodes[0],
				more,
				self.saver.bar()
			]);
			return box;
		});
	},

	// after a save / restore: the page again from the router's answer
	reload: function() {
		var self = this;
		return this.load().then(function(st) { return self.render(st); });
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
