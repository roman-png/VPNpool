'use strict';
'require baseclass';
'require rpc';
'require ui';
'require dom';

// Shared layer of the vpnpool web UI (ROADMAP-2.0 §10.1). Load it from a view with
//   'require vpnpool.common as common';
// What lives here (and nowhere else):
//   - every rpcd method of the "vpnpool" ubus object (METHODS, argument names as the backend
//     lists them) and ONE way to call them: common.call(method, args, opts) — checks transport
//     errors, the {ok, code, daemon, errors?, warning?} reply of ROADMAP §6.1 and the legacy
//     {error:"…"} shape, and turns any failure into a human text (CODE_TEXT / FIELD_TEXT,
//     translated through the standard LuCI _() and po/);
//   - toasts: an info toast fades after ~4 s and the next one replaces it; errors and
//     warnings stay until dismissed, one per action (a new error of the same action replaces
//     its old one; errors of different actions are all shown, at most MAX_STICKY);
//   - waiting on the daemon's busy/last_* state instead of blind timers (waitFor/waitIdle);
//   - small components: badge, empty state, "⋯" menu (keyboard accessible), confirmation
//     dialog with a list of consequences, node card with cell-level updates;
//   - styles through the LuCI theme variables (light and dark), mobile layout <= 600px.
// Works on LuCI 23.05, 24.10 and 25.12 (ES5 syntax; 23.05 has no addTimeLimitedNotification,
// the fallback is a plain timer here).
//
// SAFETY: in LuCI, E(tag, attrs, 'string') and ui.showModal('string', …) put the string into
// innerHTML. Node names, subscription names and every reply field are foreign data, so every
// string this module shows goes through txt() (a text node) — never as a bare string child.
//
// Human texts only through _() with an English msgid; the Russian text is in
// po/ru/vpnpool.po. No technical words in them (stand/tests/ui-text-guard.sh checks this).

var OBJECT = 'vpnpool';

// rpcd methods of the "vpnpool" object. params = argument names exactly as the backend's
// `list` declares them (stand/tests/ui-common.test.js compares). call() forwards the args
// object as is, so an argument not listed here still reaches the backend. write = needs the
// write ACL. future = new in ROADMAP-2.0 §6 (stage 3), may be missing in an older backend:
// calling it there fails with the text of "method_missing", the module keeps working.
var METHODS = {
	// read
	status:           { params: [] },
	diag:             { params: [] },
	conntest:         { params: [] },
	leases:           { params: [] },
	'export':         { params: [] },
	node_link:        { params: [ 'tag', 'id' ] },
	export_nodes:     { params: [ 'scope' ] },
	unlock_result:    { params: [] },
	probe_result:     { params: [] },
	speedtest_result: { params: [] },
	analyze:          { params: [ 'text' ], future: true },
	// write
	set_enabled:      { params: [ 'enabled' ], write: true },
	select:           { params: [ 'tag', 'id' ], write: true },
	refresh:          { params: [], write: true },
	ping:             { params: [], write: true },
	set_url:          { params: [ 'url' ], write: true },
	del_subscription: { params: [], write: true },
	del_source:       { params: [ 'url' ], write: true },
	probe_source:     { params: [ 'url' ], write: true },
	import_select:    { params: [ 'url', 'idx', 'ids', 'name' ], write: true },
	add_node:         { params: [ 'link' ], write: true },
	del_node:         { params: [ 'link' ], write: true },
	import_nodes:     { params: [ 'text' ], write: true },
	delete_node:      { params: [ 'tag', 'id', 'file' ], write: true },
	delete_nodes:     { params: [ 'tags', 'ids' ], write: true },
	restore_node:     { params: [ 'tag', 'id' ], write: true },
	refilter_node:    { params: [ 'tag', 'id' ], write: true },
	save_node:        { params: [ 'tag', 'id' ], write: true },
	unsave_node:      { params: [ 'tag', 'id' ], write: true },
	activate_saved:   { params: [ 'tag', 'id' ], write: true },
	deactivate_saved: { params: [ 'tag', 'id' ], write: true },
	add_sub:          { params: [ 'url' ], write: true },
	del_sub:          { params: [ 'url' ], write: true },
	unlock:           { params: [ 'tag', 'id' ], write: true },
	add_auto_domain:  { params: [ 'domain' ], write: true },
	del_auto_domain:  { params: [ 'domain' ], write: true },
	run_adaptive:     { params: [], write: true },
	set_domains:      { params: [ 'domains' ], write: true },
	set_communities:  { params: [ 'communities' ], write: true },
	set_option:       { params: [ 'name', 'value' ], write: true },
	set_clients:      { params: [ 'mode', 'clients', 'devices' ], write: true },
	set_auto_members: { params: [ 'members' ], write: true },
	set_preferred:    { params: [ 'tag', 'id' ], write: true },
	set_schedule:     { params: [ 'enabled', 'on', 'off', 'refresh' ], write: true },
	speedtest:        { params: [ 'tag', 'id' ], write: true },
	tg_test:          { params: [], write: true },
	'import':         { params: [ 'config' ], write: true },
	// ROADMAP-2.0 §6.3-6.6 (stage 3)
	set_config:       { params: [ 'settings' ], write: true, future: true },
	add:              { params: [ 'text', 'items', 'lines', 'options' ], write: true, future: true },
	backup:           { params: [], write: true, future: true },
	restore:          { params: [ 'data', 'path', 'replace_all' ], write: true, future: true },
	// ROADMAP-2.0 §9 (stage 6): nodes by id, favourites / hidden, "Connect" + "Back to automatic
	// choice", subscriptions as their own entries
	fav:              { params: [ 'id' ], write: true, future: true },
	unfav:            { params: [ 'id' ], write: true, future: true },
	hide:             { params: [ 'id' ], write: true, future: true },
	unhide:           { params: [ 'id' ], write: true, future: true },
	connect:          { params: [ 'id' ], write: true, future: true },
	auto_select:      { params: [], write: true, future: true },
	sub_set:          { params: [ 'id', 'name', 'url', 'enabled', 'mode', 'pick' ], write: true, future: true },
	sub_del:          { params: [ 'id' ], write: true, future: true }
};

// Reply code -> human text (msgid). The ONE place where codes become words. The codes are the
// backend's (rpcd header "Codes" + api.uc); ui-common.test.js extracts them from the backend
// sources and fails on a code without a text. Unknown codes fall back to "failed" (ok:false)
// or "done" (ok:true); the raw code only goes to the console.
var CODE_TEXT = {
	// transport / platform (made here, not by the backend)
	access_denied:      _('No permission for this action. Log out and log in again: permissions are refreshed at login.'),
	method_missing:     _('This action is not supported by the installed version of the service. Update VPN Pool.'),
	timeout:            _('The router did not answer in time. Try again in a moment.'),
	connection:         _('No connection to the router. Check the connection and try again.'),
	bad_reply:          _('The router sent an unexpected answer. Try again; if it repeats, open Diagnostics.'),
	invalid_argument:   _('The router did not accept the request: some values are invalid.'),
	failed:             _('The action failed. Try again; if it repeats, open Diagnostics.'),
	restore_failed_kept: _('Restoring failed, and the previous settings could not be put back completely. Restore the backup again or check the settings.'),
	// successful answers
	ok:                 _('Done.'),
	done:               _('Done.'),
	saved:              _('Saved.'),
	unchanged:          _('Nothing has changed.'),
	applied:            _('Applied.'),
	added:              _('Added.'),
	deleted:            _('Deleted.'),
	imported:           _('Imported.'),
	restored:           _('Restored.'),
	started:            _('Started.'),
	running:            _('Still in progress.'),
	idle:               _('Nothing has been run yet.'),
	already_running:    _('Already in progress.'),
	already_exists:     _('This is already added.'),
	cleared:            _('Cleared.'),
	set:                _('Set.'),
	sent:               _('Sent.'),
	on:                 _('VPN is on.'),
	off:                _('VPN is off.'),
	saved_not_applied:  _('Saved. It takes effect when the service starts.'),
	empty:              _('There is nothing to export.'),
	hidden:             _('Hidden. The node will not be used; you can return it from the hidden nodes.'),
	connect_pending:    _('Connecting: the node is being added back, this takes a moment.'),
	// failures
	invalid:            _('Some values are not valid. Check the highlighted fields.'),
	not_found:          _('Not found: it may have been removed already.'),
	disabled:           _('This feature is turned off in the settings.'),
	not_configured:     _('Telegram is not set up: enter the bot token and the chat first.'),
	daemon_not_running: _('The service is off. Turn it on and try again.'),
	clash_failed:       _('The VPN engine did not accept the command. Try again in a moment.'),
	script_failed:      _('The router could not complete the action. Try again; if it repeats, open Diagnostics.'),
	fetch_failed:       _('The subscription could not be downloaded or has no nodes. Check the address and the internet connection.'),
	exit_unreachable:   _('The exit could not be checked: nothing answered through the VPN. Check that the service is on and a node works.'),
	send_failed:        _('Telegram did not accept the message. Check the bot token and the chat.'),
	no_nodes:           _('There are no nodes yet.'),
	low_memory:         _('Not enough free memory on the router for this test.'),
	nothing_added:      _('Nothing was added: everything is already there or could not be recognized.'),
	decode_failed:      _('The AmneziaVPN link could not be read.'),
	incomplete_config:  _('This is not a complete VPN Pool configuration.'),
	too_large:          _('Too large: the value or the file exceeds the limit.'),
	restore_failed:     _('Restoring failed. The previous settings are back in place.'),
	ambiguous:          _('Several subscriptions fit. Choose the subscription from the list.'),
	masked_values:      _('This text has hidden values (passwords, addresses). Restore from a backup file instead.'),
	invalid_archive:    _('This file is not a VPN Pool backup or it is damaged.'),
	confirm_required:   _('Restoring replaces all current settings. Confirm to continue.'),
	write_failed:       _('The settings could not be written on the router.'),
	unknown_option:     _('This setting is not supported by the installed version of the service.'),
	unknown_method:     _('This action is not supported by the installed version of the service. Update VPN Pool.'),
	// warnings (ok:true + warning:"…")
	schedule_failed:    _('The settings are saved, but the schedule could not be set up.'),
	engine_missing:     _('Saved. The node waits for the AmneziaWG engine: it starts working once the engine is installed on the router.'),
	engine_no_awg:      _('Saved. The installed VPN engine cannot run AmneziaWG: the node waits until an engine with AmneziaWG is installed.'),
	engine_no_awg31:    _('Saved. This node needs AmneziaWG 3.1, and the installed VPN engine only has an older AmneziaWG: the node waits until the AmneziaWG engine is installed.'),
	// node states and build results (status: deferred nodes, build.error)
	start_failed:       _('This node stopped the VPN engine from starting, so it was set aside. Check the node settings or add it again.'),
	only_deferred:      _('No node can work right now: all nodes are waiting (the reason is shown next to each node).'),
	awg_random_trailers: _('This node uses random packet trailers: the server must run AmneziaWG 3.1 too, otherwise it will not answer.'),
	// reasons of AmneziaVPN links and AmneziaWG settings that were not added
	api_key:            _('This AmneziaVPN link is an account key, not server settings. In the AmneziaVPN app, share the connection as a settings file or link and paste that.'),
	full_access:        _('This AmneziaVPN link gives full access to the server (the administrator password), so it was not saved. Share a user connection instead.'),
	unsupported_container: _('This AmneziaVPN link has no protocol the router supports (AmneziaWG, WireGuard, XRay, Shadowsocks).'),
	no_conf:            _('This AmneziaVPN link has no connection settings inside.'),
	awg_no_peer:        _('The settings have no server: the [Peer] part with the server address and key is missing.'),
	awg_multi_peer:     _('The settings list several servers ([Peer] parts). One node holds one server: split them into separate files.'),
	awg_bad_value:      _('A value in the AmneziaWG settings is not valid.'),
	awg_unsupported_param: _('The AmneziaWG settings have an option the router does not know. Update VPN Pool or remove that option.')
};

// Field codes (api.uc: errors{field: code}; set_option/set_schedule/set_url return the one
// field's code as the reply code). Texts said next to the field.
var FIELD_TEXT = {
	bad_type:      _('Wrong kind of value.'),
	bad_value:     _('The value is not valid.'),
	too_small:     _('The value is too small.'),
	too_large:     _('The value is too large.'),
	bad_time:      _('The time is not valid. Use hours and minutes, for example 07:30.'),
	bad_url:       _('Enter a full address starting with http:// or https://.'),
	bad_domain:    _('Enter a site name, for example example.com.'),
	bad_community: _('Unknown list.'),
	bad_ipv4:      _('Enter an address like 192.168.1.10.'),
	bad_mac:       _('Enter a device hardware address like AA:BB:CC:DD:EE:FF.'),
	bad_ifname:    _('Unknown network interface.'),
	bad_mark:      _('Enter a whole number.'),
	bad_token:     _('This does not look like a Telegram bot token.'),
	bad_chat:      _('This does not look like a Telegram chat number.'),
	bad_tag:       _('No such node.'),
	bad_path:      _('There is no such program on the router.'),
	bad_mode:      _('Choose whether to take every node or only the nodes you pick.'),
	unknown_field: _('This setting is not supported by the installed version of the service.')
};

// Codes of the backend before stage 3 -> today's codes (until every router runs the new one).
var CODE_ALIAS = {
	no_tag: 'bad_tag',
	clash_error: 'clash_failed',
	sched_failed: 'write_failed'
};

// Old backend replies {error:"<English text>"} -> code.
var LEGACY_ERROR = {
	'no tag': 'bad_tag',
	'no url': 'bad_url',
	'empty': 'no_nodes',
	'empty config': 'incomplete_config',
	'no link for tag': 'not_found',
	'unknown method': 'unknown_method',
	'could not decode vpn:// link': 'decode_failed',
	'invalid AmneziaWG config': 'bad_value',
	'no node links found': 'no_nodes',
	'bad result': 'script_failed'
};

// ubus status codes (rpc.js getStatusText) -> code
var UBUS_CODE = { 1: 'failed', 2: 'invalid_argument', 3: 'method_missing', 4: 'not_found', 5: 'bad_reply',
	6: 'access_denied', 7: 'timeout', 8: 'method_missing', 9: 'failed', 10: 'connection' };

var INFO_MS = 4000;
var MAX_STICKY = 5;   // my limit: at most this many errors/warnings on screen, the oldest goes

function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
function canon(code) { return has(CODE_ALIAS, code) ? CODE_ALIAS[code] : code; }

function codeText(code) {
	code = canon(code);
	if (has(CODE_TEXT, code)) return CODE_TEXT[code];
	if (has(FIELD_TEXT, code)) return FIELD_TEXT[code];
	return null;
}
function fieldText(code) {
	code = canon(code);
	if (has(FIELD_TEXT, code)) return FIELD_TEXT[code];
	if (has(CODE_TEXT, code)) return CODE_TEXT[code];
	return FIELD_TEXT.bad_value;
}

// A text node for any value (a DOM node is passed through). The only way strings reach the
// page from this module.
function txt(v) {
	if (v != null && typeof v === 'object' && v.nodeType) return v;
	return document.createTextNode(v == null ? '' : String(v));
}

// LuCI's E() with every non-node child turned into text: E(tag, attrs, 'x') would put 'x'
// into innerHTML. Same call forms as E: (tag), (tag, children), (tag, attrs, children).
// Views shadow the global with it:  var E = common.E;
function safeE(tag, attr, data) {
	if (arguments.length < 3 && (!(attr instanceof Object) || Array.isArray(attr) || (attr && attr.nodeType))) { data = attr; attr = null; }
	if (data != null && typeof data !== 'object' && typeof data !== 'function') data = [ txt(data) ];
	return E(tag, attr || {}, data);
}

// Error object every failed call() rejects with: .code (machine), .text (human), .method,
// .reply (the raw answer, if any), .errors ({field: code} of an "invalid" reply), .cause.
function VpnpoolError(code, method, reply, cause) {
	this.name = 'VpnpoolError';
	this.code = code;
	this.method = method || null;
	this.reply = reply != null ? reply : null;
	this.errors = (reply && reply.errors && typeof reply.errors === 'object') ? reply.errors : null;
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
	if (ret.ok === false) {
		var c = (typeof ret.code === 'string' && ret.code) ? canon(ret.code) : 'failed';
		if (c === 'restore_failed' && ret.rolled_back === false) c = 'restore_failed_kept';
		return { ok: false, code: c, reply: ret };
	}
	if (typeof ret.error === 'string' || (ret.error != null && ret.ok !== true))
		return { ok: false, code: LEGACY_ERROR[String(ret.error)] || 'failed', reply: ret };
	return { ok: true, code: (typeof ret.code === 'string' && ret.code) ? canon(ret.code) : 'done', reply: ret };
}

var declared = {};
function declared_fn(method, keys) {
	var sig = method + '(' + keys.join(',') + ')';
	if (!declared[sig])
		declared[sig] = rpc.declare({ object: OBJECT, method: method, params: keys });
	return declared[sig];
}

// toast state: one info slot; sticky (error/warning) slots keyed by the action
var toastInfo = null, toastInfoTimer = null;
var sticky = [];   // [{ key, node }], oldest first

function removeNode(n) {
	if (n && n.parentNode) n.parentNode.removeChild(n);
}

function addToast(text, kind, timeout) {
	var cls = (kind === 'error') ? 'danger' : (kind === 'warning' ? 'warning' : 'info');
	var body = E('p', {}, [ txt(text) ]);
	var n;
	if (timeout > 0 && typeof ui.addTimeLimitedNotification === 'function')
		n = ui.addTimeLimitedNotification(null, body, timeout, cls);
	else
		n = ui.addNotification(null, body, cls);
	if (n && n.classList) {
		n.classList.add('vp-toast');
		n.setAttribute('role', (kind === 'error' || kind === 'warning') ? 'alert' : 'status');
	}
	return n;
}

function dropSticky(key) {
	sticky = sticky.filter(function(s) {
		if (key != null && s.key !== key) return true;
		removeNode(s.node);
		return false;
	});
}

var CSS = [
	'.vp-card{box-sizing:border-box;border:1px solid var(--border-color-medium,GrayText);border-radius:6px;padding:.6em .8em;margin:0 0 .6em;background:var(--background-color-high,transparent);color:var(--text-color-high,inherit);min-width:0;max-width:100%}',
	// dim the content, not the whole card: an opacity on the card would also dim its "⋯" list
	// and trap the list's z-index inside the card
	'.vp-card.vp-dimmed .vp-card-head,.vp-card.vp-dimmed .vp-card-state,.vp-card.vp-dimmed .vp-card-badges{opacity:.6}',
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
	'.vp-menu-list.vp-menu-up{top:auto;bottom:100%;margin:0 0 .2em}',
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
	'.vp-field-error-text{color:var(--error-color-medium,var(--danger-color,inherit));margin:.2em 0 0}',
	'@media (max-width:600px){',
	'.vp-card{padding:.55em .6em}',
	'.vp-card-head{flex-wrap:wrap}',
	'.vp-card-title{flex:1 1 10em}',
	'.vp-card-sub{white-space:normal}',
	'.vp-card-actions{width:100%;margin-left:0;justify-content:flex-end}',
	'.vp-card-actions>.btn,.vp-card-actions>.cbi-button{flex:1 1 auto}',
	'.vp-menu-list,.vp-menu-list.vp-menu-up{position:fixed;left:8px;right:8px;top:auto;bottom:8px;max-width:none;min-width:0;margin:0}',
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
var openMenu = null, menuSeq = 0;

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

function focusables(root) {
	return Array.prototype.filter.call(root.querySelectorAll('button, input, select, textarea, a[href]'), function(b) { return !b.disabled; });
}

if (typeof document !== 'undefined') {
	document.addEventListener('click', function(ev) {
		if (openMenu && !openMenu.root.contains(ev.target)) closeMenu(false);
	}, true);
}

return baseclass.extend({
	METHODS: METHODS,
	CODE_TEXT: CODE_TEXT,
	FIELD_TEXT: FIELD_TEXT,
	CODE_ALIAS: CODE_ALIAS,
	LEGACY_ERROR: LEGACY_ERROR,
	Error: VpnpoolError,
	INFO_MS: INFO_MS,
	MAX_STICKY: MAX_STICKY,

	__init__: function() {
		injectStyles();
	},

	/** A text node for any value (DOM nodes pass through). Use it for every foreign string. */
	txt: txt,

	/** E() that never puts a string into innerHTML (see safeE). */
	E: safeE,

	/** Human text of a reply code (or null if the code is unknown). */
	codeText: codeText,

	/** Human text of a field code (errors{field: code}); unknown -> "The value is not valid." */
	fieldText: fieldText,

	/** Human text for anything thrown by call()/waitFor() or by LuCI. */
	errorText: function(e) {
		if (e instanceof VpnpoolError) return e.text;
		var c = transportCode(e);
		return codeText(c) || CODE_TEXT.failed;
	},

	/** {field: human text} of a failed call() (an "invalid" reply), {} if it has none. */
	fieldErrors: function(e) {
		var out = {}, errs = e && (e.errors || (e.reply && e.reply.errors));
		if (!errs || typeof errs !== 'object') return out;
		for (var f in errs) if (has(errs, f)) out[f] = fieldText(errs[f]);
		return out;
	},

	/**
	 * Show field errors next to the fields of a form under `root`: a field is the element
	 * with data-field="<name>" or the LuCI form option id "cbid.<config>.<section>.<name>"
	 * (opts.config default "json", opts.section). Earlier marks are removed first. Returns
	 * the names of the fields that were not found (the caller shows those in a toast).
	 */
	markFieldErrors: function(root, e, opts) {
		opts = opts || {};
		var texts = this.fieldErrors(e), missing = [];
		var old = root.querySelectorAll('.vp-field-error-text');
		Array.prototype.forEach.call(old, function(n) {
			if (n.parentNode && n.parentNode.classList) n.parentNode.classList.remove('vp-field-error');
			removeNode(n);
		});
		for (var f in texts) {
			if (!has(texts, f)) continue;
			var el = root.querySelector('[data-field="' + String(f).replace(/["\\]/g, '') + '"]');
			if (!el && opts.section != null)
				el = document.getElementById('cbid.' + (opts.config || 'json') + '.' + opts.section + '.' + f);
			if (!el) { missing.push(f); continue; }
			el.classList.add('vp-field-error');
			el.appendChild(E('div', { 'class': 'vp-field-error-text', 'role': 'alert' }, [ txt(texts[f]) ]));
		}
		return missing;
	},

	/**
	 * Call an rpcd method of the "vpnpool" object.
	 *   args: object of named arguments (forwarded as is)
	 *   opts.quiet:   true = no error toast (the caller shows the error itself)
	 *   opts.handle:  codes the caller handles itself (rejected without a toast), e.g.
	 *                 ['confirm_required']
	 *   opts.success: text (or function(reply) -> text) for an info toast on success; when the
	 *                 reply says daemon:"not_running", a note that the change waits for the
	 *                 service is added
	 * A reply ok:true with warning:"…" is NOT shown as a success: it gives a warning toast
	 * that stays (the success text is dropped). Resolves with the reply object; rejects with
	 * common.Error (.code, .text, .errors).
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
			dropSticky(method);
			if (c.reply && typeof c.reply.warning === 'string' && c.reply.warning) {
				self.toast(codeText(c.reply.warning) || CODE_TEXT.failed, 'warning', method);
			}
			else if (opts.success) {
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
			if (e instanceof VpnpoolError && !opts.quiet && (opts.handle || []).indexOf(e.code) < 0)
				self.toast(e.text, 'error', method);
			throw e;
		});
	},

	/**
	 * Toasts. kind: 'info' (default; fades after ~4 s, the next info replaces it), 'error' and
	 * 'warning' (stay until dismissed; one per key — a new one with the same key replaces the
	 * old; different keys are all shown, at most MAX_STICKY, the oldest goes first). key: the
	 * action (call() uses the method name); default one shared key.
	 */
	toast: function(text, kind, key) {
		kind = kind || 'info';
		if (kind === 'error' || kind === 'warning') {
			key = (key == null) ? '' : String(key);
			dropSticky(key);
			var s = addToast(text, kind, 0);
			sticky.push({ key: key, node: s });
			while (sticky.length > MAX_STICKY) removeNode(sticky.shift().node);
			return s;
		}
		if (toastInfoTimer) { window.clearTimeout(toastInfoTimer); toastInfoTimer = null; }
		removeNode(toastInfo);
		var n = addToast(text, kind, INFO_MS);
		toastInfo = n;
		// own timer as well: 23.05 has no addTimeLimitedNotification, and a fade-out
		// transition does not run in a hidden tab
		toastInfoTimer = window.setTimeout(function() {
			if (toastInfo === n) { removeNode(n); toastInfo = null; }
			toastInfoTimer = null;
		}, INFO_MS + 600);
		return n;
	},

	/** Remove toasts: kind 'info' | 'error' (all errors and warnings) | undefined (all). */
	clearToast: function(kind) {
		if (!kind || kind === 'info') {
			if (toastInfoTimer) { window.clearTimeout(toastInfoTimer); toastInfoTimer = null; }
			removeNode(toastInfo); toastInfo = null;
		}
		if (!kind || kind === 'error' || kind === 'warning') dropSticky(null);
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

	/** Is the daemon busy with `kind` (fetch|build|ping|nodecheck|probe|…), or with anything? */
	isBusy: function(status, kind) {
		var b = status && status.busy;
		if (!b || typeof b !== 'object') return false;
		if (kind) return !!b[kind];
		for (var k in b) if (b[k]) return true;
		return false;
	},

	/**
	 * The "finished at" mark of a job in the status reply (seconds), or null:
	 * build -> build.at (build_status.json); fetch -> the newest subscriptions[].last_fetch_at.
	 */
	stampOf: function(kind, st) {
		if (!st || typeof st !== 'object') return null;
		if (kind === 'build') return (st.build && st.build.at != null && !isNaN(+st.build.at)) ? +st.build.at : null;
		if (kind === 'fetch') {
			var m = null;
			(Array.isArray(st.subscriptions) ? st.subscriptions : []).forEach(function(s) {
				var v = s && s.last_fetch_at;
				if (v != null && !isNaN(+v) && (m == null || +v > m)) m = +v;
			});
			return m;
		}
		return null;
	},

	/**
	 * Wait until the daemon has finished a job it was asked to start.
	 *   kind: busy key (fetch|build|ping|nodecheck|probe|speedtest|unlock).
	 *   opts.since: the job's finish mark (stampOf / opts.stamp) taken BEFORE asking for the
	 *   job; without it the mark of the first poll is the baseline.
	 *   opts.stamp(status) -> number: a custom finish mark (default stampOf(kind)).
	 * Kinds with a mark: done only when the mark moved past the baseline and the job is not
	 * busy — a job of the same kind that was already running (a scheduled fetch) does not
	 * count. Kinds without a mark: done when the job was seen busy and then idle. A job never
	 * seen busy is NOT reported as done: after opts.grace ms (default 2 polls) the wait
	 * resolves with done:false ("asked for, not seen running") — the screen says "started",
	 * not "finished". Resolves { done: bool, status }; rejects common.Error('timeout').
	 */
	waitIdle: function(kind, opts) {
		var self = this;
		opts = opts || {};
		var interval = (opts.interval > 0) ? opts.interval : 2000;
		var grace = (opts.grace >= 0) ? opts.grace : 2 * interval;
		var stamp = (typeof opts.stamp === 'function') ? opts.stamp : function(st) { return self.stampOf(kind, st); };
		var base = (opts.since != null && !isNaN(+opts.since)) ? +opts.since : undefined;
		var sawBusy = false, idleSince = null, done = false;
		return this.waitFor(function(st) {
			var busy = self.isBusy(st, kind);
			var s = stamp(st);
			s = (s == null || isNaN(+s)) ? null : +s;
			if (base === undefined) base = s;          // first poll: baseline (may be null)
			if (busy) { sawBusy = true; idleSince = null; return false; }
			if (s != null && (base == null || s > base)) { done = true; return true; }
			if (s == null && base == null && sawBusy) { done = true; return true; }   // no mark for this kind
			if (sawBusy) return false;                 // a mark exists but did not move yet
			if (idleSince == null) idleSince = Date.now();
			return Date.now() - idleSince >= grace;
		}, { timeout: opts.timeout, interval: interval, method: opts.method, args: opts.args })
			.then(function(st) { return { done: done, status: st }; });
	},

	/** Page title (same markup as the old i18n.header(), so a view can drop vpnpool.i18n). */
	header: function(title) {
		return E('h2', { 'style': 'margin:0 0 10px' }, [ txt(title) ]);
	},

	/** Small label. kind: ok | warn | error | info | muted. */
	badge: function(text, kind, title) {
		return E('span', { 'class': 'vp-badge vp-badge-' + (kind || 'muted'), 'title': title != null ? String(title) : null }, [ txt(text) ]);
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
			}, [ txt(a.label) ]);
		});
		return E('div', { 'class': 'vp-empty' }, [
			o.title != null ? E('div', { 'class': 'vp-empty-title' }, [ txt(o.title) ]) : '',
			o.text != null ? E('p', {}, [ txt(o.text) ]) : '',
			acts.length ? E('div', { 'class': 'vp-empty-actions' }, acts) : ''
		]);
	},

	/**
	 * "⋯" menu. items: [ { label, handler, danger, disabled } ] (null entries are skipped).
	 * Keyboard: Enter/Space/ArrowDown opens and focuses the first item, ArrowUp/ArrowDown/
	 * Home/End move, Escape closes and returns to the button, Tab closes. The list opens
	 * upwards when there is no room below.
	 */
	menu: function(items, opts) {
		opts = opts || {};
		var label = opts.label || _('More actions');
		var id = 'vp-menu-' + (++menuSeq);
		var list = E('ul', { 'class': 'vp-menu-list', 'id': id, 'role': 'menu', 'hidden': 'hidden', 'aria-label': label });
		var button = E('button', {
			'class': 'btn cbi-button cbi-button-neutral vp-menu-btn',
			'type': 'button',
			'aria-haspopup': 'menu',
			'aria-expanded': 'false',
			'aria-controls': id,
			'aria-label': label,
			'title': label
		}, [ txt('⋯') ]);
		var root = E('div', { 'class': 'vp-menu' }, [ button, list ]);
		var me = { root: root, button: button, list: list };

		function place() {
			list.classList.remove('vp-menu-up');
			if (typeof window === 'undefined' || !window.innerHeight || typeof button.getBoundingClientRect !== 'function') return;
			var b = button.getBoundingClientRect(), h = list.offsetHeight || 0;
			if (b.bottom + h > window.innerHeight && b.top > window.innerHeight - b.bottom) list.classList.add('vp-menu-up');
		}
		function open(focusIdx) {
			if (openMenu && openMenu !== me) closeMenu(false);
			openMenu = me;
			list.hidden = false;
			button.setAttribute('aria-expanded', 'true');
			place();
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
			}, [ txt(it.label) ]);
			list.appendChild(E('li', { 'role': 'none' }, [ b ]));
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
	 * Resolves true (confirmed) or false (cancelled, Escape, or the dialog was replaced by
	 * another LuCI dialog). Focus starts on "Cancel", Tab stays inside the dialog, and on
	 * close the focus returns to the element that had it before.
	 */
	confirm: function(o) {
		o = o || {};
		return new Promise(function(resolve) {
			var done = false;
			var prevFocus = (typeof document !== 'undefined') ? document.activeElement : null;
			var dlg = null;
			function cleanup() {
				done = true;
				document.removeEventListener('keydown', onKey, true);
			}
			function finish(v) {
				if (done) return;
				cleanup();
				ui.hideModal();
				if (prevFocus && typeof prevFocus.focus === 'function') prevFocus.focus();
				resolve(v);
			}
			function ours() { return !!(dlg && dlg.contains && dlg.contains(okBtn)); }
			function onKey(ev) {
				if (done) return;
				if (!ours()) { cleanup(); resolve(false); return; }   // another dialog took over: leave it alone
				if (ev.key === 'Escape' || ev.key === 'Esc') { ev.preventDefault(); finish(false); return; }
				if (ev.key === 'Tab') {
					var f = focusables(dlg);
					if (!f.length) return;
					var i = f.indexOf(document.activeElement);
					if (ev.shiftKey) { if (i <= 0) { ev.preventDefault(); f[f.length - 1].focus(); } }
					else if (i < 0 || i === f.length - 1) { ev.preventDefault(); f[0].focus(); }
				}
			}
			var cancelBtn = E('button', { 'class': 'btn cbi-button cbi-button-neutral vp-confirm-cancel', 'type': 'button', 'click': function() { finish(false); } },
				[ txt(o.cancel || _('Cancel')) ]);
			var okBtn = E('button', { 'class': 'btn cbi-button vp-confirm-ok ' + (o.danger ? 'cbi-button-negative' : 'cbi-button-positive important'),
				'type': 'button', 'click': function() { finish(true); } }, [ txt(o.confirm || _('Continue')) ]);
			var cons = (o.consequences || []).filter(function(c) { return c != null && c !== ''; });
			dlg = ui.showModal(txt(o.title || _('Are you sure?')), [
				o.text != null ? E('p', {}, [ txt(o.text) ]) : '',
				cons.length ? E('ul', { 'class': 'vp-confirm-list' }, cons.map(function(c) { return E('li', {}, [ txt(c) ]); })) : '',
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
		var sel = (typeof o.onSelect === 'function')
			? E('input', { 'type': 'checkbox', 'class': 'vp-card-sel', 'aria-label': _('Select'),
				'change': function(ev) { o.onSelect(ev.target.checked); } })
			: null;
		var primary = o.primary ? E('button', {
			'class': 'btn cbi-button cbi-button-action vp-card-primary',
			'type': 'button',
			'click': ui.createHandlerFn(this, function(ev) { return o.primary.handler(ev); })
		}, [ txt('') ]) : null;
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
			var s = (v == null) ? '' : String(v);
			if (n && n.textContent !== s) n.textContent = s;
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
				return (x && x.nodeType) ? x : self.badge(x && x.text, x && x.kind, x && x.title);
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
