'use strict';
'require baseclass';
'require rpc';
'require ui';
'require dom';

// Shared layer of the vpnpool web UI (ROADMAP-2.0 §10.1). Load it from a view with
//   'require vpnpool.common as common';
// What lives here (and nowhere else):
//   - every rpcd method of the "vpnpool" ubus object (METHODS) and ONE way to call them:
//     common.call(method, args, opts) — checks transport errors, the {ok, code, daemon}
//     reply of ROADMAP §6.1 and the legacy {error:"…"} shape, and turns any failure into a
//     human text (CODE_TEXT, translated through the standard LuCI _() and po/);
//   - ONE toast: an info toast fades after ~4 s and the next one replaces it; an error toast
//     stays until dismissed and is replaced only by the next error (no pile-up);
//   - waiting on the daemon's busy/last_* state instead of blind timers (waitFor/waitIdle);
//   - small components: badge, empty state, "⋯" menu (keyboard accessible), confirmation
//     dialog with a list of consequences, node card with cell-level updates;
//   - styles through the LuCI theme variables (light and dark), mobile layout <= 600px.
// Works on LuCI 23.05, 24.10 and 25.12 (ES5 syntax; 23.05 has no addTimeLimitedNotification,
// the fallback is a plain timer here).
//
// Human texts only through _() with an English msgid; the Russian text is in
// po/ru/vpnpool.po. No technical words in them (stand/tests/ui-text-guard.sh checks this).

var OBJECT = 'vpnpool';

// rpcd methods of the "vpnpool" object. params = argument names (documentation and the
// order rpc.declare sends them in; call() forwards the args object as is, so a method
// whose arguments are not listed here still works). write = needs the write ACL.
// future = announced by ROADMAP-2.0 §6, may be missing in the installed backend: calling it
// there fails with the human text of "method_missing", the module itself keeps working.
var METHODS = {
	// read
	status:           { params: [] },
	diag:             { params: [] },
	conntest:         { params: [] },
	leases:           { params: [] },
	'export':         { params: [] },
	node_link:        { params: [ 'tag' ] },
	export_nodes:     { params: [ 'scope' ] },
	unlock_result:    { params: [] },
	probe_result:     { params: [] },
	speedtest_result: { params: [] },
	analyze:          { params: [ 'text' ], future: true },
	// write
	set_enabled:      { params: [ 'enabled' ], write: true },
	select:           { params: [ 'tag' ], write: true },
	refresh:          { params: [], write: true },
	ping:             { params: [], write: true },
	set_url:          { params: [ 'url' ], write: true },
	del_subscription: { params: [], write: true },
	del_source:       { params: [ 'url' ], write: true },
	probe_source:     { params: [ 'url' ], write: true },
	import_select:    { params: [ 'url', 'idx' ], write: true },
	add_node:         { params: [ 'link' ], write: true },
	del_node:         { params: [ 'link' ], write: true },
	import_nodes:     { params: [ 'text' ], write: true },
	delete_node:      { params: [ 'tag' ], write: true },
	delete_nodes:     { params: [ 'tags' ], write: true },
	restore_node:     { params: [ 'tag' ], write: true },
	refilter_node:    { params: [ 'tag' ], write: true },
	save_node:        { params: [ 'tag' ], write: true },
	unsave_node:      { params: [ 'tag' ], write: true },
	activate_saved:   { params: [ 'tag' ], write: true },
	deactivate_saved: { params: [ 'tag' ], write: true },
	add_sub:          { params: [ 'url' ], write: true },
	del_sub:          { params: [ 'url' ], write: true },
	unlock:           { params: [ 'tag' ], write: true },
	add_auto_domain:  { params: [ 'domain' ], write: true },
	del_auto_domain:  { params: [ 'domain' ], write: true },
	run_adaptive:     { params: [], write: true },
	set_domains:      { params: [ 'domains' ], write: true },
	set_communities:  { params: [ 'communities' ], write: true },
	set_option:       { params: [ 'name', 'value' ], write: true },
	set_clients:      { params: [ 'mode', 'clients', 'devices' ], write: true },
	set_auto_members: { params: [ 'members' ], write: true },
	set_preferred:    { params: [ 'tag' ], write: true },
	set_schedule:     { params: [ 'enabled', 'on', 'off', 'refresh' ], write: true },
	speedtest:        { params: [ 'tag' ], write: true },
	tg_test:          { params: [], write: true },
	'import':         { params: [ 'config' ], write: true },
	// ROADMAP-2.0 §6.3-6.6
	set_config:       { params: [ 'config' ], write: true, future: true },
	add:              { params: [ 'text', 'items', 'options' ], write: true, future: true },
	backup:           { params: [], write: true, future: true },
	restore:          { params: [ 'archive', 'replace' ], write: true, future: true }
};

// Machine code -> human text (msgid). The ONE place where codes become words. Unknown codes
// fall back to "failed" (ok:false) or "done" (ok:true); the raw code goes to the console.
var CODE_TEXT = {
	// transport / platform
	access_denied:      _('No permission for this action. Log out and log in again: permissions are refreshed at login.'),
	method_missing:     _('This action is not supported by the installed version of the service. Update VPN Pool.'),
	timeout:            _('The router did not answer in time. Try again in a moment.'),
	connection:         _('No connection to the router. Check the connection and try again.'),
	bad_reply:          _('The router sent an unexpected answer. Try again; if it repeats, open Diagnostics.'),
	invalid_argument:   _('The router did not accept the request: some values are invalid.'),
	failed:             _('The action failed. Try again; if it repeats, open Diagnostics.'),
	// answers of the service
	not_found:          _('Not found: it may have been removed already.'),
	no_tag:             _('No node is chosen.'),
	no_url:             _('Enter an address first.'),
	empty:              _('Nothing to process: the field is empty.'),
	bad_value:          _('The value is not valid.'),
	invalid:            _('Some values are not valid. Check the highlighted fields.'),
	unknown_option:     _('This setting is not supported by the installed version of the service.'),
	too_small:          _('The value is too small.'),
	bad_time:           _('The time is not valid. Use hours and minutes, for example 07:30.'),
	sched_failed:       _('The schedule could not be saved.'),
	no_nodes:           _('There are no nodes yet.'),
	daemon_not_running: _('The service is off. Turn it on and try again.'),
	clash_error:        _('The VPN engine did not accept the command. Try again in a moment.'),
	bad_link:           _('The link could not be recognized.'),
	bad_awg:            _('The AmneziaWG settings could not be recognized.'),
	nothing_found:      _('No nodes were found in the text.'),
	busy:               _('Another operation is still running. Wait until it finishes.'),
	disabled:           _('This feature is turned off in the settings.'),
	duplicate:          _('This is already added.'),
	unsupported:        _('This type of node is not supported.'),
	awg_deferred:       _('Saved. AmneziaWG nodes wait until the AmneziaWG engine is installed.'),
	backup_invalid:     _('This file is not a VPN Pool backup or it is damaged.'),
	fetch_failed:       _('The subscription could not be downloaded. Check the address and the internet connection.'),
	// successful answers
	done:               _('Done.'),
	applied:            _('Applied.'),
	saved:              _('Saved.'),
	saved_not_applied:  _('Saved. It takes effect when the service starts.'),
	started:            _('Started.'),
	already_running:    _('Already running.'),
	on:                 _('VPN is on.'),
	off:                _('VPN is off.')
};

// Old backend replies {error:"<English text>"} -> code (until every method speaks §6.1).
var LEGACY_ERROR = {
	'no tag': 'no_tag',
	'no url': 'no_url',
	'empty': 'empty',
	'empty config': 'empty',
	'no link for tag': 'not_found',
	'unknown method': 'method_missing',
	'could not decode vpn:// link': 'bad_link',
	'invalid AmneziaWG config': 'bad_awg',
	'no node links found': 'nothing_found',
	'bad result': 'bad_reply'
};

// ubus status codes (rpc.js getStatusText) -> code
var UBUS_CODE = { 1: 'failed', 2: 'invalid_argument', 3: 'method_missing', 4: 'not_found', 5: 'bad_reply',
	6: 'access_denied', 7: 'timeout', 8: 'method_missing', 9: 'failed', 10: 'connection' };

var INFO_MS = 4000;

function codeText(code) {
	return Object.prototype.hasOwnProperty.call(CODE_TEXT, code) ? CODE_TEXT[code] : null;
}

// Error object every failed call() rejects with: .code (machine), .text (human), .method,
// .reply (the raw answer, if any), .cause (the transport error, if any).
function VpnpoolError(code, method, reply, cause) {
	this.name = 'VpnpoolError';
	this.code = code;
	this.method = method || null;
	this.reply = reply != null ? reply : null;
	this.cause = cause || null;
	this.text = codeText(code) || CODE_TEXT.failed;
	this.message = this.text;
	this.stack = (new Error(this.text)).stack;
}
VpnpoolError.prototype = Object.create(Error.prototype);
VpnpoolError.prototype.constructor = VpnpoolError;

// transport error (rpc.js RPCError text, fetch TypeError, LuCI SessionError) -> code
function transportCode(e) {
	var msg = String((e && e.message) || e || '');
	var m;
	if (e && e.name === 'SessionError') return 'session';
	if ((m = msg.match(/ubus code (\d+)/))) return UBUS_CODE[+m[1]] || 'failed';
	if (/error -32002\b/.test(msg)) return 'access_denied';
	if (/error -32000\b/.test(msg)) return 'method_missing';   // object not found
	if (/error -3260[01]\b/.test(msg)) return 'invalid_argument';
	if (/HTTP error (401|403)\b/.test(msg)) return 'access_denied';
	if (/HTTP error (408|504)\b/.test(msg)) return 'timeout';
	if (/HTTP error \d+/.test(msg)) return 'connection';
	if (/timed? ?out|timeout/i.test(msg)) return 'timeout';
	if (/invalid message frame|JSON|Unexpected token/i.test(msg)) return 'bad_reply';
	if (e && (e.name === 'TypeError' || e.name === 'NetworkError')) return 'connection';
	return 'connection';
}

// Classify an answer of rpc: returns { ok, code, reply }.
function classify(method, ret) {
	if (typeof ret === 'number')                 // [status] without data: a ubus status code
		return ret === 0 ? { ok: true, code: 'done', reply: {} } : { ok: false, code: UBUS_CODE[ret] || 'failed', reply: null };
	if (ret == null || typeof ret !== 'object' || Array.isArray(ret))
		return { ok: false, code: 'bad_reply', reply: ret };
	if (ret.ok === false)
		return { ok: false, code: (typeof ret.code === 'string' && ret.code) ? ret.code : 'failed', reply: ret };
	if (typeof ret.error === 'string' || (ret.error != null && ret.ok !== true))
		return { ok: false, code: LEGACY_ERROR[String(ret.error)] || 'failed', reply: ret };
	return { ok: true, code: (typeof ret.code === 'string' && ret.code) ? ret.code : 'done', reply: ret };
}

var declared = {};
function declared_fn(method, keys) {
	var sig = method + '(' + keys.join(',') + ')';
	if (!declared[sig])
		declared[sig] = rpc.declare({ object: OBJECT, method: method, params: keys });
	return declared[sig];
}

// toast state: one info slot, one error slot
var toastInfo = null, toastInfoTimer = null, toastError = null, toastErrorMethod = null;

function removeNode(n) {
	if (n && n.parentNode) n.parentNode.removeChild(n);
}

function addToast(text, kind, timeout) {
	var cls = (kind === 'error') ? 'danger' : (kind === 'warning' ? 'warning' : 'info');
	var body = E('p', {}, text);
	var n;
	if (timeout > 0 && typeof ui.addTimeLimitedNotification === 'function')
		n = ui.addTimeLimitedNotification(null, body, timeout, cls);
	else
		n = ui.addNotification(null, body, cls);
	if (n && n.classList) {
		n.classList.add('vp-toast');
		n.setAttribute('role', kind === 'error' ? 'alert' : 'status');
	}
	return n;
}

var CSS = [
	'.vp-card{box-sizing:border-box;border:1px solid var(--border-color-medium,GrayText);border-radius:6px;padding:.6em .8em;margin:0 0 .6em;background:var(--background-color-high,transparent);color:var(--text-color-high,inherit);min-width:0;max-width:100%}',
	'.vp-card.vp-dimmed{opacity:.6}',
	'.vp-card.vp-active{border-color:var(--primary-color-high,var(--main-bright-color,Highlight));border-width:2px}',
	'.vp-card-head{display:flex;align-items:center;gap:.5em;min-width:0}',
	'.vp-card-sel{flex:0 0 auto;margin:0}',
	'.vp-card-title{flex:1 1 auto;min-width:0;font-weight:bold;overflow-wrap:anywhere}',
	'.vp-card-sub{flex:0 1 auto;color:var(--text-color-medium,GrayText);white-space:nowrap}',
	'.vp-card-body{display:flex;flex-wrap:wrap;align-items:center;gap:.25em .6em;margin:.35em 0 0;min-width:0}',
	'.vp-card-state{color:var(--text-color-medium,GrayText);overflow-wrap:anywhere;min-width:0}',
	'.vp-card-state[data-kind=error]{color:var(--error-color-medium,var(--danger-color,inherit))}',
	'.vp-card-state[data-kind=warn]{color:var(--warn-color-high,var(--warning-color,inherit))}',
	'.vp-card-state[data-kind=ok]{color:var(--success-color-medium,var(--success-color,inherit))}',
	'.vp-card-actions{display:flex;align-items:center;gap:.4em;margin-left:auto}',
	'.vp-badge{display:inline-block;box-sizing:border-box;border:1px solid currentColor;border-radius:1em;padding:0 .55em;font-size:.85em;line-height:1.5;white-space:nowrap;max-width:100%;overflow:hidden;text-overflow:ellipsis;vertical-align:middle}',
	'.vp-badge-ok{color:var(--success-color-medium,var(--success-color,currentColor))}',
	'.vp-badge-warn{color:var(--warn-color-high,var(--warning-color,currentColor))}',
	'.vp-badge-error{color:var(--error-color-medium,var(--danger-color,currentColor))}',
	'.vp-badge-info{color:var(--primary-color-high,var(--main-bright-color,currentColor))}',
	'.vp-badge-muted{color:var(--text-color-medium,GrayText)}',
	'.vp-menu{position:relative;display:inline-block}',
	'.vp-menu-btn{min-width:2.4em;font-weight:bold;letter-spacing:.1em}',
	'.vp-menu-list{position:absolute;right:0;top:100%;z-index:200;box-sizing:border-box;min-width:12em;max-width:calc(100vw - 16px);margin:.2em 0 0;padding:.25em 0;list-style:none;border:1px solid var(--border-color-medium,GrayText);border-radius:6px;background:var(--background-color-high,Canvas);color:var(--text-color-high,CanvasText)}',
	'.vp-menu-list[hidden]{display:none}',
	'.vp-menu-list li{margin:0;padding:0;list-style:none}',
	'.vp-menu-item{display:block;width:100%;box-sizing:border-box;margin:0;padding:.45em .9em;border:0;border-radius:0;background:transparent;color:inherit;text-align:left;font:inherit;cursor:pointer;white-space:normal}',
	'.vp-menu-item:hover,.vp-menu-item:focus{background:var(--background-color-low,Highlight);color:var(--text-color-highest,HighlightText);outline:none}',
	'.vp-menu-item[disabled]{opacity:.5;cursor:default}',
	'.vp-menu-item.vp-danger{color:var(--error-color-medium,var(--danger-color,inherit))}',
	'.vp-empty{box-sizing:border-box;text-align:center;padding:1.5em 1em;border:1px dashed var(--border-color-medium,GrayText);border-radius:6px;color:var(--text-color-medium,GrayText);max-width:100%}',
	'.vp-empty-title{font-weight:bold;color:var(--text-color-high,inherit);margin:0 0 .4em}',
	'.vp-empty p{margin:0 0 .8em}',
	'.vp-empty-actions{display:flex;flex-wrap:wrap;justify-content:center;gap:.5em}',
	'.vp-confirm-list{margin:.4em 0 .8em 1.2em;padding:0}',
	'.vp-confirm-list li{margin:.15em 0;overflow-wrap:anywhere}',
	'.vp-confirm .button-row,.vp-confirm .right{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:.5em}',
	'.vp-toast{position:sticky;top:0;z-index:150}',
	'@media (max-width:600px){',
	'.vp-card{padding:.55em .6em}',
	'.vp-card-head{flex-wrap:wrap}',
	'.vp-card-title{flex:1 1 10em}',
	'.vp-card-sub{white-space:normal}',
	'.vp-card-actions{width:100%;margin-left:0;justify-content:flex-end}',
	'.vp-card-actions>.btn,.vp-card-actions>.cbi-button{flex:1 1 auto}',
	'.vp-menu-list{position:fixed;left:8px;right:8px;top:auto;bottom:8px;max-width:none;min-width:0}',
	'.vp-menu-item{padding:.8em 1em}',
	'.vp-confirm .button-row>*,.vp-confirm .right>*{flex:1 1 auto}',
	'}'
].join('\n');

function injectStyles() {
	if (typeof document === 'undefined' || document.getElementById('vpnpool-common-css')) return;
	var st = document.createElement('style');
	st.id = 'vpnpool-common-css';
	st.appendChild(document.createTextNode(CSS));
	(document.head || document.documentElement).appendChild(st);
}

// "⋯" menu: one open at a time; Escape / Tab / click outside closes it.
var openMenu = null;

function closeMenu(focusButton) {
	if (!openMenu) return;
	var m = openMenu;
	openMenu = null;
	m.list.hidden = true;
	m.button.setAttribute('aria-expanded', 'false');
	if (focusButton) m.button.focus();
}

function menuItems(list) {
	return Array.prototype.filter.call(list.querySelectorAll('.vp-menu-item'), function(b) { return !b.disabled; });
}

if (typeof document !== 'undefined') {
	document.addEventListener('click', function(ev) {
		if (openMenu && !openMenu.root.contains(ev.target)) closeMenu(false);
	}, true);
}

return baseclass.extend({
	METHODS: METHODS,
	CODE_TEXT: CODE_TEXT,
	Error: VpnpoolError,
	INFO_MS: INFO_MS,

	__init__: function() {
		injectStyles();
	},

	/** Human text of a machine code (or null if the code is unknown). */
	codeText: codeText,

	/** Human text for anything thrown by call()/waitFor() or by LuCI. */
	errorText: function(e) {
		if (e instanceof VpnpoolError) return e.text;
		var c = transportCode(e);
		return codeText(c) || CODE_TEXT.failed;
	},

	/**
	 * Call an rpcd method of the "vpnpool" object.
	 *   args: object of named arguments (forwarded as is)
	 *   opts.quiet:   true = no error toast (the caller shows the error itself)
	 *   opts.success: text (or function(reply) -> text) for an info toast on success; when the
	 *                 reply says daemon:"not_running", a note that the change waits for the
	 *                 service is added
	 * Resolves with the reply object; rejects with common.Error (.code, .text).
	 */
	call: function(method, args, opts) {
		var self = this;
		opts = opts || {};
		args = (args && typeof args === 'object') ? args : {};
		var spec = METHODS[method];
		var keys = (spec ? spec.params.slice() : []);
		Object.keys(args).forEach(function(k) { if (keys.indexOf(k) < 0) keys.push(k); });
		keys = keys.filter(function(k) { return args[k] !== undefined; });
		var fn = declared_fn(method, keys);

		return fn.apply(null, keys.map(function(k) { return args[k]; })).then(function(ret) {
			var c = classify(method, ret);
			if (!c.ok) {
				if (!spec || spec.future) console.warn('vpnpool: %s -> %s', method, c.code);
				throw new VpnpoolError(c.code, method, c.reply);
			}
			if (codeText(c.code) == null) console.info('vpnpool: %s -> unknown success code %s', method, c.code);
			if (toastError && toastErrorMethod === method) self.clearToast('error');
			if (opts.success) {
				var t = (typeof opts.success === 'function') ? opts.success(c.reply) : opts.success;
				if (t) {
					if (c.reply && c.reply.daemon === 'not_running')
						t = t + ' ' + _('The service is off: the change takes effect after it is turned on.');
					self.toast(t);
				}
			}
			return c.reply;
		}, function(e) {
			var code = transportCode(e);
			if (code === 'session') throw e;          // LuCI already shows "Session expired"
			console.warn('vpnpool: %s failed: %s', method, (e && e.message) || e);
			throw new VpnpoolError(code, method, null, e);
		}).catch(function(e) {
			if (e instanceof VpnpoolError && !opts.quiet) {
				self.toast(e.text, 'error');
				toastErrorMethod = method;
			}
			throw e;
		});
	},

	/**
	 * The one toast. kind: 'info' (default; fades after ~4 s, the next toast replaces it),
	 * 'warning' (same as info, but stays twice as long), 'error' (stays until dismissed;
	 * the next error replaces it, info toasts do not touch it).
	 */
	toast: function(text, kind) {
		kind = kind || 'info';
		if (kind === 'error') {
			removeNode(toastError);
			toastErrorMethod = null;
			toastError = addToast(text, 'error', 0);
			return toastError;
		}
		if (toastInfoTimer) { window.clearTimeout(toastInfoTimer); toastInfoTimer = null; }
		removeNode(toastInfo);
		var ms = (kind === 'warning') ? INFO_MS * 2 : INFO_MS;
		var n = addToast(text, kind, ms);
		toastInfo = n;
		// own timer as well: 23.05 has no addTimeLimitedNotification, and a fade-out
		// transition does not run in a hidden tab
		toastInfoTimer = window.setTimeout(function() {
			if (toastInfo === n) { removeNode(n); toastInfo = null; }
			toastInfoTimer = null;
		}, ms + 600);
		return n;
	},

	/** Remove the toast(s): kind 'info' | 'error' | undefined (both). */
	clearToast: function(kind) {
		if (!kind || kind === 'info') {
			if (toastInfoTimer) { window.clearTimeout(toastInfoTimer); toastInfoTimer = null; }
			removeNode(toastInfo); toastInfo = null;
		}
		if (!kind || kind === 'error') {
			removeNode(toastError); toastError = null; toastErrorMethod = null;
		}
	},

	/**
	 * Poll a read method (default "status") until predicate(reply) is true — instead of a
	 * blind setTimeout. opts: timeout (ms, default 60000), interval (ms, default 2000),
	 * method, args. Resolves with the reply that satisfied the predicate; rejects with
	 * common.Error('timeout'). Connection hiccups are retried until the timeout; access
	 * and "method missing" errors stop at once.
	 */
	waitFor: function(predicate, opts) {
		var self = this;
		opts = opts || {};
		var timeout = (opts.timeout > 0) ? opts.timeout : 60000;
		var interval = (opts.interval > 0) ? opts.interval : 2000;
		var method = opts.method || 'status';
		var deadline = Date.now() + timeout;

		return new Promise(function(resolve, reject) {
			function step() {
				self.call(method, opts.args, { quiet: true }).then(function(r) {
					var ok;
					try { ok = predicate(r); } catch (e) { return reject(e); }
					if (ok) return resolve(r);
					next();
				}, function(e) {
					if (e instanceof VpnpoolError && (e.code === 'access_denied' || e.code === 'method_missing'))
						return reject(e);
					if (!(e instanceof VpnpoolError)) return reject(e);   // session expired
					next();
				});
			}
			function next() {
				if (Date.now() + interval > deadline) return reject(new VpnpoolError('timeout', method));
				window.setTimeout(step, interval);
			}
			step();
		});
	},

	/** Is the daemon busy with `kind` (fetch|build|ping|nodecheck|probe), or with anything? */
	isBusy: function(status, kind) {
		var b = status && status.busy;
		if (!b || typeof b !== 'object') return false;
		if (kind) return !!b[kind];
		for (var k in b) if (b[k]) return true;
		return false;
	},

	/**
	 * Wait until the daemon has finished a job it was asked to start.
	 *   kind: busy key; opts.stamp(status) -> number: a last_* time that grows when the job
	 *   ends (e.g. status => status.build && status.build.time); opts.since: that time
	 *   before the job was asked for. Done when the job is not busy AND (it was seen busy
	 *   or the stamp moved past `since`). Without a stamp, a job that never showed up as
	 *   busy is accepted after opts.grace ms (default 2 polls).
	 */
	waitIdle: function(kind, opts) {
		var self = this;
		opts = opts || {};
		var sawBusy = false, idleSince = null;
		var interval = (opts.interval > 0) ? opts.interval : 2000;
		var grace = (opts.grace >= 0) ? opts.grace : 2 * interval;
		return this.waitFor(function(st) {
			if (self.isBusy(st, kind)) { sawBusy = true; idleSince = null; return false; }
			if (sawBusy) return true;
			if (typeof opts.stamp === 'function') {
				var s = +opts.stamp(st);
				if (!isNaN(s) && s > (+opts.since || 0)) return true;
				return false;
			}
			if (idleSince == null) idleSince = Date.now();
			return Date.now() - idleSince >= grace;
		}, { timeout: opts.timeout, interval: interval, method: opts.method, args: opts.args });
	},

	/** Page title (same markup as the old i18n.header(), so a view can drop vpnpool.i18n). */
	header: function(title) {
		return E('h2', { 'style': 'margin:0 0 10px' }, title);
	},

	/** Small label. kind: ok | warn | error | info | muted. */
	badge: function(text, kind, title) {
		return E('span', { 'class': 'vp-badge vp-badge-' + (kind || 'muted'), 'title': title || null }, text);
	},

	/**
	 * Empty state: { title, text, actions: [ { label, handler, primary } ] }.
	 */
	emptyState: function(o) {
		o = o || {};
		var acts = (o.actions || []).map(function(a) {
			return E('button', {
				'class': 'btn cbi-button ' + (a.primary ? 'cbi-button-action important' : 'cbi-button-neutral'),
				'click': ui.createHandlerFn(null, a.handler)
			}, a.label);
		});
		return E('div', { 'class': 'vp-empty' }, [
			o.title ? E('div', { 'class': 'vp-empty-title' }, o.title) : '',
			o.text ? E('p', {}, o.text) : '',
			acts.length ? E('div', { 'class': 'vp-empty-actions' }, acts) : ''
		]);
	},

	/**
	 * "⋯" menu. items: [ { label, handler, danger, disabled } ] (null entries are skipped).
	 * Keyboard: Enter/Space/ArrowDown opens and focuses the first item, ArrowUp/ArrowDown/
	 * Home/End move, Escape closes and returns to the button, Tab closes.
	 */
	menu: function(items, opts) {
		opts = opts || {};
		var label = opts.label || _('More actions');
		var list = E('ul', { 'class': 'vp-menu-list', 'role': 'menu', 'hidden': 'hidden', 'aria-label': label });
		var button = E('button', {
			'class': 'btn cbi-button cbi-button-neutral vp-menu-btn',
			'type': 'button',
			'aria-haspopup': 'menu',
			'aria-expanded': 'false',
			'aria-label': label,
			'title': label
		}, '⋯');
		var root = E('div', { 'class': 'vp-menu' }, [ button, list ]);
		var me = { root: root, button: button, list: list };

		function open(focusIdx) {
			if (openMenu && openMenu !== me) closeMenu(false);
			openMenu = me;
			list.hidden = false;
			button.setAttribute('aria-expanded', 'true');
			var its = menuItems(list);
			if (its.length) its[(focusIdx < 0) ? its.length - 1 : 0].focus();
		}

		(items || []).forEach(function(it) {
			if (!it) return;
			var b = E('button', {
				'class': 'vp-menu-item' + (it.danger ? ' vp-danger' : ''),
				'type': 'button',
				'role': 'menuitem',
				'tabindex': '-1',
				'disabled': it.disabled ? 'disabled' : null,
				'click': function(ev) {
					ev.preventDefault();
					closeMenu(true);
					if (!it.disabled && typeof it.handler === 'function') it.handler(ev);
				}
			}, it.label);
			list.appendChild(E('li', { 'role': 'none' }, b));
		});

		button.addEventListener('click', function(ev) {
			ev.preventDefault();
			if (openMenu === me) closeMenu(false); else open(0);
		});
		button.addEventListener('keydown', function(ev) {
			if (ev.key === 'ArrowDown' || ev.key === 'Down') { ev.preventDefault(); open(0); }
			else if (ev.key === 'ArrowUp' || ev.key === 'Up') { ev.preventDefault(); open(-1); }
		});
		list.addEventListener('keydown', function(ev) {
			var its = menuItems(list), i = its.indexOf(document.activeElement);
			switch (ev.key) {
			case 'ArrowDown': case 'Down': ev.preventDefault(); if (its.length) its[(i + 1) % its.length].focus(); break;
			case 'ArrowUp': case 'Up': ev.preventDefault(); if (its.length) its[(i - 1 + its.length) % its.length].focus(); break;
			case 'Home': ev.preventDefault(); if (its.length) its[0].focus(); break;
			case 'End': ev.preventDefault(); if (its.length) its[its.length - 1].focus(); break;
			case 'Escape': case 'Esc': ev.preventDefault(); closeMenu(true); break;
			case 'Tab': closeMenu(false); break;
			}
		});
		return root;
	},

	/**
	 * Confirmation dialog (LuCI modal) instead of window.confirm().
	 *   { title, text, consequences: [ 'what will happen', … ], confirm: label,
	 *     cancel: label, danger: true }
	 * Resolves true (confirmed) or false (cancelled, Escape). Focus starts on "Cancel".
	 */
	confirm: function(o) {
		o = o || {};
		return new Promise(function(resolve) {
			var done = false;
			function finish(v) {
				if (done) return;
				done = true;
				document.removeEventListener('keydown', onKey, true);
				ui.hideModal();
				resolve(v);
			}
			function onKey(ev) {
				if (ev.key === 'Escape' || ev.key === 'Esc') { ev.preventDefault(); finish(false); }
			}
			var cancelBtn = E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'type': 'button', 'click': function() { finish(false); } },
				o.cancel || _('Cancel'));
			var okBtn = E('button', { 'class': 'btn cbi-button ' + (o.danger ? 'cbi-button-negative' : 'cbi-button-positive important'),
				'type': 'button', 'click': function() { finish(true); } }, o.confirm || _('Continue'));
			var cons = (o.consequences || []).filter(function(c) { return c; });
			ui.showModal(o.title || _('Are you sure?'), [
				o.text ? E('p', {}, o.text) : '',
				cons.length ? E('ul', { 'class': 'vp-confirm-list' }, cons.map(function(c) { return E('li', {}, c); })) : '',
				E('div', { 'class': 'button-row right' }, [ cancelBtn, okBtn ])
			], 'vp-confirm');
			document.addEventListener('keydown', onKey, true);
			cancelBtn.focus();
		});
	},

	/**
	 * Node card: container + main button + "⋯" menu.
	 *   { id, title, sub, state, stateKind, badges: [Node|{text,kind,title}], selected,
	 *     onSelect(checked), primary: { label, handler, disabled }, menu: [items],
	 *     active, dimmed }
	 * Update in place with updateNodeCard(el, partial) — focus and hover are kept.
	 */
	nodeCard: function(o) {
		o = o || {};
		var self = this;
		var sel = (typeof o.onSelect === 'function')
			? E('input', { 'type': 'checkbox', 'class': 'vp-card-sel', 'aria-label': _('Select'),
				'change': function(ev) { o.onSelect(ev.target.checked); } })
			: null;
		var primary = o.primary ? E('button', {
			'class': 'btn cbi-button cbi-button-action vp-card-primary',
			'type': 'button',
			'click': ui.createHandlerFn(this, function(ev) { return o.primary.handler(ev); })
		}, o.primary.label) : null;
		var el = E('div', { 'class': 'vp-card', 'data-id': o.id != null ? String(o.id) : null }, [
			E('div', { 'class': 'vp-card-head' }, [
				sel || '',
				E('span', { 'class': 'vp-card-title' }),
				E('span', { 'class': 'vp-card-sub' })
			]),
			E('div', { 'class': 'vp-card-body' }, [
				E('span', { 'class': 'vp-card-state' }),
				E('span', { 'class': 'vp-card-badges' }),
				E('span', { 'class': 'vp-card-actions' }, [
					primary || '',
					(o.menu && o.menu.length) ? this.menu(o.menu, { label: o.menuLabel }) : ''
				])
			])
		]);
		this.updateNodeCard(el, o);
		return el;
	},

	updateNodeCard: function(el, o) {
		if (!el || !o) return el;
		var self = this;
		function setText(cls, v) {
			if (v === undefined) return;
			var n = el.querySelector('.' + cls);
			if (n && n.textContent !== String(v == null ? '' : v)) n.textContent = (v == null ? '' : v);
		}
		setText('vp-card-title', o.title);
		setText('vp-card-sub', o.sub);
		if (o.state !== undefined || o.stateKind !== undefined) {
			var st = el.querySelector('.vp-card-state');
			if (o.state !== undefined) setText('vp-card-state', o.state);
			if (st && o.stateKind !== undefined) st.setAttribute('data-kind', o.stateKind || '');
		}
		if (o.badges !== undefined) {
			var b = el.querySelector('.vp-card-badges');
			if (b) dom.content(b, (o.badges || []).map(function(x) {
				return (x && x.nodeType) ? x : self.badge(x.text, x.kind, x.title);
			}));
		}
		if (o.selected !== undefined) {
			var cb = el.querySelector('.vp-card-sel');
			if (cb) cb.checked = !!o.selected;
		}
		if (o.primary && o.primary.label !== undefined) setText('vp-card-primary', o.primary.label);
		if (o.primary && o.primary.disabled !== undefined) {
			var pb = el.querySelector('.vp-card-primary');
			if (pb) pb.disabled = !!o.primary.disabled;
		}
		if (o.active !== undefined) el.classList.toggle('vp-active', !!o.active);
		if (o.dimmed !== undefined) el.classList.toggle('vp-dimmed', !!o.dimmed);
		return el;
	}
});
