'use strict';
'require view';
'require ui';
'require poll';
'require dom';
'require vpnpool.common as common';

// "Nodes" tab (ROADMAP-2.0 §10.3): everything about nodes in one place — the "+ Add" dialog
// (one field, a file, a QR picture; a dry run through analyze with a chip and a reason per
// line; for a subscription address: take every node or pick nodes; then add), groups by source
// (each subscription with its expiry / quota / "updated", "My nodes", favourites no
// subscription has, hidden nodes), a card per node (state in words, "Connect" = the soft
// choice, "Back to automatic choice", a "⋯" menu), a bulk panel that appears only with a
// selection. The list is updated cell by cell on every poll: cards are reused, only changed
// texts are written, so focus and hover stay where they are.
// Backend: only the 2.0 methods (status, analyze, add, connect, auto_select, fav, unfav, hide,
// unhide, sub_set, sub_del, delete_nodes) plus the node tests (ping, refresh, speedtest,
// unlock, node_link, probe_source, restore_node, refilter_node, set_auto_members,
// export_nodes) — no legacy tag-based method.
// SAFETY: node and subscription names are foreign data — common.E keeps every string a text
// node; dialog titles go through common.txt().

var E = common.E;

// bytes of the text in one request: the router's web server takes a JSON-RPC request up to ~64 KB
// (stand 24.10: 63.5 KB of text passed, 70 KB -> "parse error"); the rest of the request fits
var MAX_TEXT = 60 * 1024;
var MAX_REQUEST = 63 * 1024;   // one "add" request as a whole (its JSON arguments)
var MAX_FILE = 1024 * 1024;   // a file bigger than this is surely not a list of links
var LS_KEY = 'vpnpool.nodes.collapsed';

var TYPE_NAMES = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'Shadowsocks', hysteria2: 'Hysteria2',
	hysteria: 'Hysteria', tuic: 'TUIC', awg: 'AmneziaWG', wireguard: 'WireGuard', anytls: 'AnyTLS', shadowtls: 'ShadowTLS' };
var SERVICE_NAMES = { youtube: 'YouTube', openai: 'ChatGPT', netflix: 'Netflix', instagram: 'Instagram', telegram: 'Telegram', google: 'Google' };

var CSS = [
	'.vp-nodes-toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:.5em;margin:0 0 .8em}',
	'.vp-nodes-search{flex:1 1 12em;min-width:0;max-width:22em;box-sizing:border-box}',
	'.vp-now{display:flex;flex-wrap:wrap;align-items:center;gap:.4em .8em;margin:0 0 .8em;overflow-wrap:anywhere}',
	// the theme's .btn / flex rules would show a [hidden] element again
	'.vp-nodes [hidden],.vp-add-dialog [hidden],.vp-pick-dialog [hidden],.vp-pool-dialog [hidden]{display:none!important}',
	'.vp-nodes-err{color:var(--error-color-medium,var(--danger-color,inherit));margin:0 0 .8em}',
	'.vp-group{margin:0 0 1.1em;min-width:0}',
	'.vp-group-head{display:flex;flex-wrap:wrap;align-items:center;gap:.3em .6em;padding:.2em 0 .35em;margin:0 0 .5em;border-bottom:1px solid var(--border-color-medium,GrayText);min-width:0}',
	'.vp-group-toggle{flex:1 1 12em;min-width:0;display:flex;align-items:baseline;gap:.4em;margin:0;padding:.2em 0;border:0;background:transparent;color:inherit;font:inherit;font-weight:bold;text-align:left;cursor:pointer}',
	'.vp-group-title{overflow-wrap:anywhere;min-width:0}',
	'.vp-group-count{font-weight:normal;color:var(--text-color-medium,GrayText);white-space:nowrap}',
	'.vp-group-actions{display:flex;flex-wrap:wrap;align-items:center;gap:.4em}',
	'.vp-group-info{flex:1 1 100%;min-width:0;color:var(--text-color-medium,GrayText);font-size:.92em;overflow-wrap:anywhere}',
	// the same readable mix of the theme colours as common.js (>= 4.5:1, measured)
	'.vp-group-info [data-kind=error]{color:var(--error-color-medium,var(--danger-color,inherit));color:color-mix(in srgb,var(--error-color-medium,var(--danger-color,#c62828)) 55%,var(--text-color-high,CanvasText))}',
	'.vp-group-info [data-kind=warn]{color:var(--warn-color-high,var(--warning-color,inherit));color:color-mix(in srgb,var(--warn-color-high,var(--warning-color,#b58900)) 35%,var(--text-color-high,CanvasText))}',
	'.vp-group-empty{color:var(--text-color-medium,GrayText);margin:.2em 0 .6em}',
	'.vp-bulk{position:sticky;bottom:0;z-index:120;display:flex;flex-wrap:wrap;align-items:center;gap:.5em;box-sizing:border-box;max-width:100%;margin:.6em 0 0;padding:.5em .6em;border:1px solid var(--border-color-medium,GrayText);border-radius:6px;background:var(--background-color-high,Canvas);color:var(--text-color-high,CanvasText)}',
	'.vp-bulk-count{font-weight:bold;margin-right:auto}',
	'.vp-add-text{width:100%;box-sizing:border-box;min-height:7em;font-family:var(--font-mono,monospace);font-size:.9em}',
	'.vp-add-tools{display:flex;flex-wrap:wrap;gap:.5em;margin:.5em 0}',
	'.vp-hidden-file{display:none}',
	'.vp-add-summary{margin:.6em 0 .2em;font-weight:bold;overflow-wrap:anywhere}',
	'.vp-add-preview{max-height:45vh;overflow:auto;margin:.4em 0}',
	'.vp-add-row{display:flex;flex-wrap:wrap;align-items:center;gap:.25em .6em;padding:.4em 0;border-bottom:1px solid var(--border-color-low,rgba(128,128,128,.25));min-width:0}',
	'.vp-add-row input[type=checkbox]{margin:0}',
	'.vp-add-line{color:var(--text-color-medium,GrayText);white-space:nowrap}',
	'.vp-add-name{font-weight:bold;overflow-wrap:anywhere;min-width:0;flex:0 1 auto}',
	'.vp-add-meta{color:var(--text-color-medium,GrayText);overflow-wrap:anywhere;min-width:0}',
	'.vp-add-why{flex:1 1 100%;color:var(--text-color-medium,GrayText);overflow-wrap:anywhere;min-width:0}',
	'.vp-add-mode{max-width:100%;box-sizing:border-box}',
	'.vp-add-pick,.vp-pick-box{flex:1 1 100%;min-width:0}',
	'.vp-pick-list{max-height:16em;overflow:auto;margin:.3em 0;padding:.2em .4em;border:1px solid var(--border-color-low,rgba(128,128,128,.3));border-radius:4px}',
	'.vp-pick-item{display:flex;align-items:center;gap:.5em;padding:.2em 0;min-width:0;cursor:pointer}',
	'.vp-pick-item span{overflow-wrap:anywhere;min-width:0}',
	'.vp-pick-tools{display:flex;flex-wrap:wrap;gap:.4em;align-items:center}',
	'.vp-add-result{margin:.5em 0;overflow-wrap:anywhere}',
	'.vp-add-result[data-kind=warn]{color:var(--warn-color-high,var(--warning-color,inherit));color:color-mix(in srgb,var(--warn-color-high,var(--warning-color,#b58900)) 35%,var(--text-color-high,CanvasText))}',
	'.vp-muted{color:var(--text-color-medium,GrayText)}',
	'.vp-qr{display:flex;justify-content:center;min-height:220px;margin:.6em 0}',
	'.vp-qr img,.vp-qr canvas{max-width:100%;height:auto}',
	'.vp-link-text{width:100%;box-sizing:border-box;font-family:var(--font-mono,monospace);font-size:.85em}',
	'.vp-export-out textarea{width:100%;box-sizing:border-box;font-family:var(--font-mono,monospace);font-size:.85em}',
	'@media (max-width:600px){',
	'.vp-nodes-toolbar>.btn,.vp-nodes-toolbar>.cbi-button{flex:1 1 auto}',
	'.vp-nodes-search{max-width:none;flex-basis:100%}',
	'.vp-group-actions{width:100%}',
	'.vp-group-actions>.btn{flex:1 1 auto}',
	'.vp-bulk>.btn{flex:1 1 auto}',
	'.vp-bulk-count{flex:1 1 100%}',
	'.vp-add-tools>.btn{flex:1 1 auto}',
	'}'
].join('\n');

function injectCss() {
	if (document.getElementById('vpnpool-nodes-css')) return;
	var st = document.createElement('style');
	st.id = 'vpnpool-nodes-css';
	st.appendChild(document.createTextNode(CSS));
	(document.head || document.documentElement).appendChild(st);
}

function noop() {}
function arr(v) { return Array.isArray(v) ? v : []; }
function loadCollapsed() {
	try { var v = JSON.parse(window.localStorage.getItem(LS_KEY) || '{}'); return (v && typeof v === 'object') ? v : {}; }
	catch (e) { return {}; }
}
function saveCollapsed(c) { try { window.localStorage.setItem(LS_KEY, JSON.stringify(c)); } catch (e) {} }

function typeName(t) { return t ? (TYPE_NAMES[t] || String(t).toUpperCase()) : ''; }
function delayText(d) {
	if (d == null) return '—';
	if (+d <= 0) return _('no answer');
	return _('%d ms').format(+d);
}
// short state of a node that waits (deferred, ROADMAP 4.7)
function deferredText(reason) {
	if (/^engine_/.test(String(reason || ''))) return _('Waits for the AmneziaWG engine');
	if (reason === 'start_failed') return _('Set aside: the VPN engine could not start with it');
	return _('Waits: it cannot work right now');
}
// why a node failed the service check, in words. The check is strict (a node must open EVERY
// checked site). The node checker's last sweep (status node.check: failed checks in a row, when,
// the hosts it did not reach) names the sites and says "3 checks in a row, 10 min ago"; without it
// (a check of an older version) one checked site is named, several are "one of them", none is the
// general connection check.
function deadText(st, n) {
	var c = (n && n.check && typeof n.check === 'object') ? n.check : null;
	var f = common.failedSites(st, [ n ]), s = f.sites, head;   // the same answer as the Overview's alert
	if (s.length && (f.exact || s.length === 1)) head = _('Does not open %s').format(s.join(', '));
	else if (s.length > 1) head = _('Does not open one of the checked sites (%s)').format(s.join(', '));
	else head = _('Fails the connection check');
	if (c && c.fails > 0) {
		var d = N_(c.fails, '%d check in a row', '%d checks in a row').format(c.fails) + (c.at ? ', ' + common.ago(c.at) : '');
		return _('%s: %s. It is left out of the automatic choice.').format(head, d);
	}
	return _('%s, so it is left out of the automatic choice').format(head);
}
// the lines of a paste numbered as analyze numbers them (a leading byte-order mark and the blank
// lines around the text dropped, then one line per newline)
function lineTexts(text) {
	var t = String(text || '');
	if (t.charCodeAt(0) === 0xfeff) t = t.slice(1);   // a byte-order mark
	return t.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '').split(/\r?\n/).map(function(l) { return l.trim(); });
}
// bytes the text takes inside a JSON request (UTF-8, escapes included)
function jsonBytes(v) {
	var j = JSON.stringify(v);
	try { return unescape(encodeURIComponent(j)).length; } catch (e) { return j.length * 3; }
}
function requestBytes(text) { return jsonBytes(String(text)); }
function shortLine(l) {
	l = String(l || '');
	return l.length > 60 ? l.slice(0, 57) + '…' : l;
}
function idOf(x) { return x && (x.id || x.tag) || null; }
function safeId(s) { return String(s).replace(/[^A-Za-z0-9_-]/g, '_'); }

// sequential calls (one rebuild signal after another is fine; parallel ones would race)
function sequence(list, fn) {
	var res = { ok: 0, err: null };
	return list.reduce(function(p, x) {
		return p.then(function() {
			return Promise.resolve().then(function() { return fn(x); }).then(function() { res.ok++; }, function(e) { if (!res.err) res.err = e; });
		});
	}, Promise.resolve()).then(function() { return res; });
}

// Poll a background job's result method (speedtest_result / unlock_result / probe_result) until
// it no longer runs. A reply ok:false is the job's own result (rejects with it); only
// connection hiccups are retried. Rejects common.Error('timeout') after `timeout` ms.
function pollResult(method, timeout, interval) {
	interval = interval || 2000;
	var deadline = Date.now() + (timeout || 90000);
	return new Promise(function(resolve, reject) {
		function next() {
			if (Date.now() + interval > deadline) return reject(new common.Error('timeout', method));
			window.setTimeout(step, interval);
		}
		function step() {
			common.call(method, {}, { quiet: true }).then(function(r) {
				if (r && r.running) return next();
				if (r && r.code === 'idle') return reject(new common.Error('failed', method, r));
				resolve(r);
			}, function(e) {
				if (e instanceof common.Error && e.reply) return reject(e);
				if (e instanceof common.Error && (e.code === 'connection' || e.code === 'timeout')) return next();
				reject(e);
			});
		}
		next();
	});
}

// Run fn() from a button: the button is busy until the promise settles; after it,
// disabledAfter() decides whether it stays disabled (ui.createHandlerFn would always enable it).
function busyClick(btn, fn, disabledAfter) {
	return function(ev) {
		if (ev && ev.preventDefault) ev.preventDefault();
		if (btn.disabled) return;
		btn.disabled = true;
		btn.classList.add('spinning');
		return Promise.resolve().then(fn).catch(noop).then(function() {
			btn.classList.remove('spinning');
			btn.disabled = disabledAfter ? !!disabledAfter() : false;
		});
	};
}

function button(label, cls, onclick, attrs) {
	var a = { 'class': 'btn cbi-button ' + (cls || 'cbi-button-neutral'), 'type': 'button' };
	for (var k in (attrs || {})) a[k] = attrs[k];
	var b = E('button', a, [ label ]);
	if (onclick) b.addEventListener('click', onclick);
	return b;
}
function setLabel(b, text) { if (b && b.textContent !== text) b.textContent = text; }

// QR from a picture, decoded in the browser: BarcodeDetector where the browser has it, else
// the vendored jsQR (loaded on demand). Resolves the text or null.
var jsqrLoading = null;
function loadJsQR() {
	if (window.jsQR) return Promise.resolve();
	if (!jsqrLoading) jsqrLoading = new Promise(function(resolve, reject) {
		var s = document.createElement('script');
		s.src = L.resource('vpnpool/jsqr.min.js');
		s.onload = function() { resolve(); };
		s.onerror = function() { jsqrLoading = null; reject(new Error('jsqr')); };
		document.head.appendChild(s);
	});
	return jsqrLoading;
}
function decodeQR(file) {
	return new Promise(function(resolve, reject) {
		var url = URL.createObjectURL(file);
		var img = new Image();
		img.onerror = function() { URL.revokeObjectURL(url); reject(new Error('image')); };
		img.onload = function() {
			URL.revokeObjectURL(url);
			var w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
			var k = Math.min(1, 1600 / Math.max(w, h, 1));
			var c = document.createElement('canvas');
			c.width = Math.max(1, Math.round(w * k)); c.height = Math.max(1, Math.round(h * k));
			var cx = c.getContext('2d');
			cx.drawImage(img, 0, 0, c.width, c.height);
			var viaJsQR = function() {
				return loadJsQR().then(function() {
					var d = cx.getImageData(0, 0, c.width, c.height);
					var r = window.jsQR(d.data, c.width, c.height, { inversionAttempts: 'attemptBoth' });
					return r && r.data ? r.data : null;
				});
			};
			var p;
			if (typeof window.BarcodeDetector === 'function') {
				p = Promise.resolve().then(function() { return new window.BarcodeDetector({ formats: [ 'qr_code' ] }).detect(c); })
					.then(function(list) { return (list && list[0] && list[0].rawValue) ? list[0].rawValue : viaJsQR(); }, viaJsQR);
			} else p = viaJsQR();
			p.then(resolve, reject);
		};
		img.src = url;
	});
}

// the QR of a link (vendored qrcodejs, drawn here: the link never leaves the router's page)
function renderQR(el, text) {
	var make = function() {
		try { dom.content(el, []); new window.QRCode(el, { text: text, width: 220, height: 220, correctLevel: window.QRCode.CorrectLevel.M }); }
		catch (e) { dom.content(el, E('em', { 'class': 'vp-muted' }, _('The link is too long for a QR code: copy it instead.'))); }
	};
	if (window.QRCode) { make(); return; }
	var s = document.createElement('script');
	s.src = L.resource('vpnpool/qrcode.min.js');
	s.onload = make;
	s.onerror = function() { dom.content(el, E('em', { 'class': 'vp-muted' }, _('The QR code could not be drawn: copy the link instead.'))); };
	document.head.appendChild(s);
}
function copyFrom(ta) {
	ta.focus();
	ta.select();
	var done = false;
	try { done = document.execCommand('copy'); } catch (e) { done = false; }
	common.toast(done ? _('Copied.') : _('Select the text and copy it.'));
}

/// A list of nodes with checkboxes (the probe of a subscription address): {el, ids(), count}.
// res: the probe result {nodes, total, shown, capped} — a long list is cut on the router, the
// list says so.
function pickList(res, checked) {
	var boxes = [];
	var nodes = arr(res && res.nodes);
	var items = nodes.filter(function(n) { return n && n.id; }).map(function(n) {
		var cb = E('input', { 'type': 'checkbox', 'data-id': n.id });
		cb.checked = !!checked(n);
		boxes.push({ cb: cb, n: n });
		return E('label', { 'class': 'vp-pick-item' }, [
			cb,
			E('span', {}, [ n.tag || n.id ]),
			E('span', { 'class': 'vp-muted' }, [ [ n.server, (n.delay != null && n.delay > 0) ? _('%d ms').format(n.delay) : _('no answer') ].filter(Boolean).join(' · ') ])
		]);
	});
	var set = function(pred) { boxes.forEach(function(b) { b.cb.checked = !!pred(b.n); }); };
	var capped = !!(res && res.capped && res.total > nodes.length);
	var el = E('div', {}, [
		capped ? E('p', { 'class': 'vp-pick-capped' }, [ _('Shown: the first %d of %d nodes.').format(res.shown || nodes.length, res.total) ]) : '',
		E('div', { 'class': 'vp-pick-tools' }, [
			button(_('All'), '', function() { set(function() { return true; }); }),
			button(_('Answering'), '', function() { set(function(n) { return n.delay != null && n.delay > 0; }); }),
			button(_('Clear all'), '', function() { set(function() { return false; }); })
		]),
		E('div', { 'class': 'vp-pick-list' }, items.length ? items : [ E('em', { 'class': 'vp-muted' }, _('No nodes were found at this address.')) ])
	]);
	return {
		el: el,
		count: boxes.length,
		ids: function() { return boxes.filter(function(b) { return b.cb.checked; }).map(function(b) { return b.n.id; }); },
		disable: function(v) { boxes.forEach(function(b) { b.cb.disabled = !!v; }); }
	};
}

// Download + parse one subscription address on the router (in the background) -> the probe
// result {nodes, total, shown, capped}. Only the result of OUR start is taken: another window
// may be checking another address (already_running -> refused, no poll), and a result whose job
// token is not the one our start got belongs to someone else (refused, never saved).
function probe(url) {
	return common.call('probe_source', { url: url }, { quiet: true }).then(function(r) {
		if (r && r.code === 'already_running') throw new common.Error('probe_busy', 'probe_source', r);
		var job = r && r.job;
		return pollResult('probe_result', 120000).then(function(res) {
			if (job != null && (!res || res.job !== job)) throw new common.Error('probe_busy', 'probe_result', res);
			return res || {};
		}, function(e) {
			// a failed result (ok:false) of another job is not ours either
			if (job != null && e instanceof common.Error && e.reply && e.reply.job !== job) throw new common.Error('probe_busy', 'probe_result', e.reply);
			throw e;
		});
	}).then(null, function(e) {
		if (e instanceof common.Error && e.code === 'no_nodes') throw new common.Error('fetch_failed', 'probe_result', e.reply);
		throw e;
	});
}
function probeError(e) {
	return (e instanceof common.Error && e.code === 'probe_busy')
		? _('Another address is being checked right now. Try again when that check ends.') : common.errorText(e);
}

// Which nodes take part in the automatic choice — the ONE place that says it, the way the
// engine config is built (generator.uc): the member list (1.x) counts only with ids of this
// build, else every node; then the excluded ids leave (unless that would leave nothing); then
// "favourites only" keeps the favourites (when one of them is left). Deferred nodes are not in
// the config at all.
function autoPool(st) {
	var pool = arr(st && st.nodes).filter(function(n) { return n && n.id && !n.deferred; });
	var ids = pool.map(function(n) { return n.id; });
	var has = function(list, i) { return list.indexOf(i) >= 0; };
	var members = arr(st && st.auto_member_ids).filter(function(i) { return has(ids, i); });
	var base = members.length ? members : ids;
	var excl = arr(st && st.auto_exclude_ids);
	var after = base.filter(function(i) { return !has(excl, i); });
	if (!after.length) after = base;
	var beforeFav = after.slice();   // the set the exclusions decide on ("favourites only" comes after)
	var favOnly = false;
	if (((st && st.settings) || {}).favorites_only) {
		var favs = pool.filter(function(n) { return n.favorite; }).map(function(n) { return n.id; });
		var only = after.filter(function(i) { return has(favs, i); });
		if (only.length) { after = only; favOnly = true; }
	}
	return {
		ids: ids,
		members: members,
		participants: after,
		beforeFav: beforeFav,
		memberListActive: members.length > 0,
		favOnly: favOnly,
		inAuto: function(id) { return has(after, id); },
		// null (takes part) | 'excluded' | 'not_member' | 'favorites_only'
		why: function(id) {
			if (has(after, id) || !has(ids, id)) return null;
			if (members.length && !has(members, id)) return 'not_member';
			if (has(excl, id)) return 'excluded';
			return favOnly ? 'favorites_only' : null;
		}
	};
}

// ---------------------------------------------------------------- groups and cards
function buildGroups(st) {
	var subs = arr(st.subscriptions), bySub = {}, mine = [], favIn = [];
	subs.forEach(function(s) { if (s && s.id) bySub[s.id] = []; });
	arr(st.nodes).forEach(function(n) {
		if (!n || typeof n !== 'object') return;
		var it = { kind: 'node', key: 'n:' + (n.id || ('tag:' + n.tag)), node: n };
		if (n.source === 'subscription' && bySub[n.sub]) bySub[n.sub].push(it);
		else if (n.source === 'favorite') favIn.push(it);
		else mine.push(it);
	});
	arr(st.unreadable).forEach(function(u) { if (u && u.file) mine.push({ kind: 'unreadable', key: 'u:' + u.file, file: u }); });
	// a hidden node lives in "Hidden" only (a hidden favourite is out of the pool too, but its
	// subscription may still have it: one fact, one card)
	var hiddenIds = {};
	arr(st.hidden).forEach(function(h) { if (h && h.id) hiddenIds[h.id] = true; });
	var favOut = arr(st.favorites).filter(function(f) { return f && f.id && !f.in_pool && !hiddenIds[f.id]; })
		.map(function(f) { return { kind: 'favout', key: 'f:' + f.id, fav: f }; });
	var favIds = {};
	arr(st.favorites).forEach(function(f) { if (f && f.id) favIds[f.id] = true; });
	var hidden = arr(st.hidden).filter(function(h) { return h && h.id; })
		.map(function(h) { return { kind: 'hidden', key: 'h:' + h.id, hid: h, favorite: !!favIds[h.id] }; });
	var out = [];
	subs.forEach(function(s) {
		if (s && s.id) out.push({ id: 'sub:' + s.id, kind: 'sub', sub: s, title: s.name || _('Subscription'), items: bySub[s.id] });
	});
	if (mine.length) out.push({ id: 'mine', kind: 'mine', title: _('My nodes'), items: mine });
	if (favIn.length || favOut.length) out.push({ id: 'fav', kind: 'fav', title: _('Favourites no subscription has'), items: favIn.concat(favOut) });
	if (hidden.length) out.push({ id: 'hidden', kind: 'hidden', title: _('Hidden'), items: hidden });
	return out;
}

return view.extend({
	load: function() {
		return common.call('status', {}, { quiet: true }).catch(function(e) { return { __error: common.errorText(e) }; });
	},

	render: function(st) {
		var self = this;
		injectCss();
		this.groups = {};       // group id -> { el, body, toggle, title, count, info, actions, menuSig, g }
		this.cards = {};        // item key -> { el, it, menuSig, badgeSig, search }
		this.sel = {};          // item key -> true
		this.speed = {};        // node id -> Mbit/s of the last speed test
		this.busyNode = {};     // node id -> 'speedtest' | 'unlock'
		this.filter = '';
		this.collapsed = loadCollapsed();
		this.st = null;

		this.addBtn = button(_('+ Add'), 'cbi-button-add vp-add-btn', ui.createHandlerFn(this, 'handleAdd'));
		this.pingBtn = button(_('Check ping'), 'cbi-button-action vp-ping-btn', ui.createHandlerFn(this, 'handlePing'));
		this.refreshBtn = button(_('Update subscriptions'), 'vp-refresh-btn', ui.createHandlerFn(this, 'handleRefresh'));
		this.search = E('input', { 'type': 'search', 'class': 'cbi-input-text vp-nodes-search', 'placeholder': _('Search by name or server'), 'aria-label': _('Search by name or server') });
		this.search.addEventListener('input', function() { self.filter = String(self.search.value || '').trim().toLowerCase(); self.applyFilter(); });
		var pageMenu = common.menu([
			{ label: _('Which nodes take part in the automatic choice…'), handler: function() { self.handleAutoPool(); } },
			{ label: _('Export nodes…'), handler: function() { self.handleExport(); } }
		], { label: _('More actions') });

		this.nowText = E('span', { 'class': 'vp-now-text' });
		this.autoBtn = button(_('Back to automatic choice'), 'cbi-button-action vp-auto-btn', ui.createHandlerFn(this, function() { return this.doAuto(); }));
		this.nowEl = E('div', { 'class': 'vp-now', 'role': 'status' }, [ this.nowText, this.autoBtn ]);
		this.banner = E('div', { 'class': 'alert-message warning vp-nodes-banner', 'hidden': 'hidden' });
		this.errLine = E('p', { 'class': 'vp-nodes-err', 'role': 'alert', 'hidden': 'hidden' });
		this.emptyEl = common.emptyState({
			title: _('No nodes yet'),
			text: _('Add a subscription or a node: paste a link, a subscription address or AmneziaWG settings.'),
			actions: [ { label: _('+ Add'), primary: true, handler: function() { return self.handleAdd(); } } ]
		});
		this.emptyEl.hidden = true;
		this.groupsEl = E('div', { 'class': 'vp-groups' });

		this.bulkCount = E('span', { 'class': 'vp-bulk-count' });
		this.bulkFav = button(_('Add to favourites'), 'vp-bulk-fav', ui.createHandlerFn(this, 'handleBulkFav'));
		this.bulkHide = button(_('Hide'), 'vp-bulk-hide', ui.createHandlerFn(this, 'handleBulkHide'));
		this.bulkDel = button(_('Delete'), 'cbi-button-negative vp-bulk-del', ui.createHandlerFn(this, 'handleBulkDelete'));
		this.bulkClear = button(_('Clear the selection'), 'vp-bulk-clear', function() { self.clearSelection(); });
		this.bulk = E('div', { 'class': 'vp-bulk', 'role': 'region', 'aria-label': _('Actions with the selected nodes'), 'hidden': 'hidden' },
			[ this.bulkCount, this.bulkFav, this.bulkHide, this.bulkDel, this.bulkClear ]);

		var root = E('div', { 'class': 'cbi-map vpnpool-view vp-nodes' }, [
			common.header(_('VPN Pool — Nodes')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'vp-nodes-toolbar' }, [ this.addBtn, this.pingBtn, this.refreshBtn, this.search, pageMenu ]),
				this.nowEl, this.banner, this.errLine, this.emptyEl, this.groupsEl, this.bulk
			])
		]);
		this.update(st);
		poll.add(L.bind(this.refresh, this), 5);
		poll.start();
		// "+ Add" of the Overview's wizard leads here with #add: open the dialog once
		var loc = window.location;
		if (loc && loc.hash === '#add') {
			try { window.history.replaceState(null, '', loc.pathname + loc.search); } catch (e) {}
			window.setTimeout(function() { self.handleAdd(); }, 0);
		}
		return root;
	},

	refresh: function() {
		var self = this;
		return common.call('status', {}, { quiet: true }).then(function(st) { self.update(st); }, function(e) {
			self.update({ __error: common.errorText(e) });
		});
	},

	// ---- the whole screen from one status reply, cell by cell ----
	update: function(st) {
		if (!st || st.__error) {
			this.errLine.textContent = (st && st.__error) || common.CODE_TEXT.failed;
			this.errLine.hidden = false;
			return;
		}
		this.errLine.hidden = true;
		this.st = st;
		this.updateToolbar(st);
		var groups = buildGroups(st);
		var seenG = {}, seenC = {};
		var self = this, gi = 0;
		groups.forEach(function(g) {
			seenG[g.id] = true;
			var G = self.groups[g.id] || (self.groups[g.id] = self.makeGroup(g));
			G.g = g;
			self.placeAt(self.groupsEl, G.el, gi++);
			self.updateGroup(G, g);
			var ci = 0;
			g.items.forEach(function(it) {
				seenC[it.key] = true;
				var C = self.cards[it.key];
				if (C) self.updateCard(C, it); else C = self.cards[it.key] = self.makeCard(it);
				self.placeAt(G.body, C.el, ci++);
			});
			// leftovers of this group (moved to another group or gone)
			Array.prototype.slice.call(G.body.children, ci).forEach(function(n) {
				if (!n.classList || !n.classList.contains('vp-group-empty')) G.body.removeChild(n);
			});
			G.empty.hidden = g.items.length > 0;
			if (!G.empty.parentNode) G.body.appendChild(G.empty);
		});
		Object.keys(this.groups).forEach(function(id) {
			if (!seenG[id]) { var G = self.groups[id]; if (G.el.parentNode) G.el.parentNode.removeChild(G.el); delete self.groups[id]; }
		});
		Object.keys(this.cards).forEach(function(k) {
			if (!seenC[k]) { var C = self.cards[k]; if (C.el.parentNode) C.el.parentNode.removeChild(C.el); delete self.cards[k]; delete self.sel[k]; }
		});
		this.emptyEl.hidden = groups.length > 0;
		this.applyFilter();
		this.updateBulk();
	},

	// put `el` at position i of `parent` — only when it is not there yet (moving an element
	// takes the focus away from it)
	placeAt: function(parent, el, i) {
		var cur = parent.children[i];
		if (cur === el) return;
		parent.insertBefore(el, cur || null);
	},

	updateToolbar: function(st) {
		var pp = st.ping_progress || {};
		var pinging = common.isBusy(st, 'ping');
		setLabel(this.pingBtn, pinging ? (pp.total ? _('Checking… %d of %d').format(pp.done || 0, pp.total) : _('Checking…')) : _('Check ping'));
		if (!this.pingBtn.classList.contains('spinning')) this.pingBtn.disabled = pinging;
		var fetching = common.isBusy(st, 'fetch') || common.isBusy(st, 'build');
		setLabel(this.refreshBtn, fetching ? _('Updating…') : _('Update subscriptions'));
		if (!this.refreshBtn.classList.contains('spinning')) this.refreshBtn.disabled = fetching;

		var pref = st.preferred;
		var t;
		if (pref && pref.id) {
			t = (pref.in_pool === false)
				? _('Chosen by you: %s. It is not among the nodes now, so the automatic choice works.').format(pref.tag || '')
				: _('Connected to %s: chosen by you. If it stops working, the automatic choice takes over until it is back.').format(pref.tag || '');
			this.autoBtn.hidden = false;
		} else {
			t = st.running ? (st.auto_now ? _('Automatic choice: now %s.').format(st.auto_now) : _('Automatic choice.')) : '';
			this.autoBtn.hidden = true;
		}
		if (this.nowText.textContent !== t) this.nowText.textContent = t;
		this.nowEl.hidden = !t;

		var b = !st.enabled ? _('VPN is off: the delays and states of the nodes are not checked now.')
			: (!st.running ? _('The service is not running: the delays and states of the nodes are not checked now.') : '');
		if (this.banner.textContent !== b) this.banner.textContent = b;
		this.banner.hidden = !b;
	},

	makeGroup: function(g) {
		var self = this;
		var G = { g: g };
		G.body = E('div', { 'class': 'vp-group-body', 'id': 'vp-g-' + safeId(g.id) });
		G.caret = E('span', { 'class': 'vp-group-caret', 'aria-hidden': 'true' });
		G.title = E('span', { 'class': 'vp-group-title' });
		G.count = E('span', { 'class': 'vp-group-count' });
		G.toggle = E('button', { 'class': 'vp-group-toggle', 'type': 'button', 'aria-controls': G.body.id, 'aria-expanded': 'true' },
			[ G.caret, G.title, G.count ]);
		G.toggle.addEventListener('click', function() { self.toggleGroup(G); });
		G.actions = E('div', { 'class': 'vp-group-actions' });
		G.info = E('div', { 'class': 'vp-group-info' });
		G.empty = E('p', { 'class': 'vp-group-empty' });
		if (g.kind === 'sub') {
			G.updateBtn = button(_('Update'), 'vp-sub-update', ui.createHandlerFn(this, function() { return this.handleSubRefresh(G.g.sub); }));
			G.actions.appendChild(G.updateBtn);
		}
		G.el = E('section', { 'class': 'vp-group', 'data-group': g.id }, [ E('div', { 'class': 'vp-group-head' }, [ G.toggle, G.actions, G.info ]), G.body ]);
		this.setCollapsed(G, !!this.collapsed[g.id]);
		return G;
	},

	setCollapsed: function(G, v) {
		G.body.hidden = v;
		G.toggle.setAttribute('aria-expanded', v ? 'false' : 'true');
		G.caret.textContent = v ? '▸' : '▾';
	},
	toggleGroup: function(G) {
		var v = !G.body.hidden;
		this.setCollapsed(G, v);
		if (v) this.collapsed[G.g.id] = true; else delete this.collapsed[G.g.id];
		saveCollapsed(this.collapsed);
	},

	updateGroup: function(G, g) {
		var self = this;
		if (G.title.textContent !== g.title) G.title.textContent = g.title;
		var cnt = N_(g.items.length, '%d node', '%d nodes').format(g.items.length);
		if (G.count.textContent !== cnt) G.count.textContent = cnt;
		var parts = [];
		if (g.kind === 'sub') {
			var s = g.sub;
			// the same facts as the Overview's subscription cards (one computation: common.subFacts)
			common.subFacts(s).forEach(function(f) { parts.push({ t: f.t, k: f.k || '' }); });
			var et = !s.enabled ? _('The subscription is turned off.') : (s.result === 'failed' ? _('The last update failed and there are no nodes from it.') : _('No nodes from this subscription yet.'));
			if (G.empty.textContent !== et) G.empty.textContent = et;
			var on = !!s.enabled;
			var items = [
				{ label: _('Pick nodes…'), handler: function() { self.handleSubPick(G.g.sub); } },
				{ label: on ? _('Turn off') : _('Turn on'), handler: function() { self.handleSubEnable(G.g.sub, !on); } },
				{ label: _('Delete the subscription'), danger: true, handler: function() { self.handleSubDelete(G.g.sub); } }
			];
			this.setMenu(G, G.actions, items);
		}
		// best delay of the group (the ping of the group, from the last check of every node)
		var best = null;
		g.items.forEach(function(it) { var d = it.node && it.node.delay; if (d != null && d > 0 && (best == null || d < best)) best = d; });
		if (best != null) parts.push({ t: _('best ping %d ms').format(best) });
		var sig = JSON.stringify(parts);
		if (G.infoSig !== sig) {
			G.infoSig = sig;
			var kids = [];
			parts.forEach(function(p, i) {
				if (i) kids.push(' · ');
				kids.push(E('span', { 'data-kind': p.k || null }, [ p.t ]));
			});
			dom.content(G.info, kids);
		}
		G.info.hidden = !parts.length;
	},

	// (re)place the "⋯" menu inside `holder` when its items changed — never while it is open
	setMenu: function(rec, holder, items) {
		var sig = items.map(function(i) { return i.label + (i.disabled ? '/off' : '') + (i.danger ? '/!' : ''); }).join('|');
		if (rec.menuSig === sig) return;
		var old = holder.querySelector('.vp-menu');
		if (old) {
			var list = old.querySelector('.vp-menu-list');
			if (list && !list.hidden) return;
		}
		var m = items.length ? common.menu(items, { label: _('More actions') }) : null;
		if (old) { if (m) holder.replaceChild(m, old); else holder.removeChild(old); }
		else if (m) holder.appendChild(m);
		rec.menuSig = sig;
	},

	// ---- one card ----
	spec: function(it) {
		var st = this.st || {};
		var self = this;
		if (it.kind === 'node') return this.nodeSpec(it.node, st);
		if (it.kind === 'favout') {
			var f = it.fav;
			return {
				title: f.tag || f.id, sub: typeName(f.type),
				// (a subscription may still have it but be turned off: the words claim only "not among the nodes")
				state: _('Not among the nodes now: it is kept in your favourites and connects with one button'), stateKind: '',
				badges: [ { text: _('Favourite'), kind: 'info' } ],
				primary: { label: _('Connect') },
				menu: [
					{ label: _('Remove from favourites'), handler: function() { self.doUnfav(f.id, f.tag); } },
					{ label: _('QR code and link'), handler: function() { self.showLink(f.id, f.tag || f.id); } }
				],
				search: [ f.tag, f.server ].join(' ')
			};
		}
		if (it.kind === 'hidden') {
			var h = it.hid;
			return {
				title: h.tag || _('A node its subscription no longer has'), sub: typeName(h.type),
				state: h.in_source === false ? _('Hidden by you. The subscription does not have it any more.') : _('Hidden by you: it is not used.'),
				stateKind: '', badges: it.favorite ? [ { text: _('Favourite'), kind: 'info' } ] : [], dimmed: true,
				primary: { label: _('Return') }, menu: [],
				search: [ h.tag, h.server ].join(' ')
			};
		}
		// an AmneziaWG settings file that could not be read
		var u = it.file;
		return {
			title: u.file, sub: 'AmneziaWG',
			state: common.reasonText(u.reason) + ' ' + _('Delete the file and add the settings again.'), stateKind: 'error',
			badges: [], dimmed: true, primary: null,
			menu: [ { label: _('Delete'), danger: true, handler: function() { self.handleDeleteFile(u.file); } } ],
			search: u.file
		};
	},

	nodeSpec: function(n, st) {
		var self = this;
		var activeTag = (st.active === 'auto' || !st.active) ? st.auto_now : st.active;
		var why = autoPool(st).why(n.id);   // the one place that knows who takes part
		var inUse = !!(st.running && n.tag && n.tag === activeTag);
		var busy = this.busyNode[n.id];
		var state, kind = '';
		if (n.deferred) { state = deferredText(n.reason); kind = 'warn'; }
		else if (busy === 'speedtest') state = _('Testing the speed…');
		else if (busy === 'unlock') state = _('Checking the services…');
		else if (inUse) { state = n.preferred ? _('In use: chosen by you') : _('In use: automatic choice'); kind = 'ok'; }
		else if (n.preferred) { state = _('Chosen by you, but not in use now: the automatic choice works instead'); kind = 'warn'; }
		else if (n.dead && !n.kept) { state = deadText(st, n); kind = 'error'; }
		else if (why === 'excluded') state = _('Excluded by you from the automatic choice');
		else if (why === 'not_member') state = _('Not on the list of nodes for the automatic choice');
		else if (why === 'favorites_only') state = _('Not in the automatic choice: "favourites only" is on');
		else if (n.kept) state = _('In the automatic choice: kept by you, although the check fails');
		else state = _('In the automatic choice');

		var badges = [];
		if (n.favorite) badges.push({ text: _('Favourite'), kind: 'info' });
		arr(n.hints).forEach(function(h) { if (h === 'awg_random_trailers') badges.push({ text: 'AmneziaWG 3.1', kind: 'warn', title: common.codeText(h) }); });
		if (this.speed[n.id] != null) badges.push({ text: _('%s Mbit/s').format(this.speed[n.id]), kind: 'muted' });
		var un = n.unlock || {};
		Object.keys(SERVICE_NAMES).forEach(function(k) {
			if (un[k] === true || un[k] === false)
				badges.push({ text: SERVICE_NAMES[k], kind: un[k] ? 'ok' : 'error',
					title: (un[k] ? _('%s opens through this node') : _('%s does not open through this node')).format(SERVICE_NAMES[k]) });
		});

		var key = idOf(n);
		var name = n.tag || n.id;
		var menu = [];
		menu.push(n.favorite
			? { label: _('Remove from favourites'), handler: function() { self.doUnfav(key, name); } }
			: { label: _('Add to favourites'), handler: function() { self.doFav(key, name); } });
		menu.push({ label: _('QR code and link'), handler: function() { self.showLink(key, name); } });
		if (!n.deferred) {
			menu.push({ label: _('Speed test'), disabled: !!busy, handler: function() { self.doSpeedtest(self.current(n)); } });
			menu.push({ label: _('Check services'), disabled: !!busy, handler: function() { self.doUnlock(self.current(n)); } });
			if (why === 'excluded' || why === 'not_member') menu.push({ label: _('Return to the automatic choice'), handler: function() { self.doInclude(self.current(n)); } });
			else if (why === 'favorites_only') { /* keeping a failing node would not make it take part */ }
			else if (n.dead && !n.kept) menu.push({ label: _('Return to the automatic choice'), handler: function() { self.doKeep(key, name); } });
			else if (why !== 'favorites_only') menu.push({ label: _('Exclude from the automatic choice'), handler: function() { self.doExclude(self.current(n)); } });
			if (n.kept) menu.push({ label: _('Check it automatically again'), handler: function() { self.doUnkeep(key, name); } });
			if (n.source !== 'favorite') menu.push({ label: _('Hide'), handler: function() { self.doHide(key, name); } });
		}
		if (n.source !== 'favorite') menu.push({ label: _('Delete'), danger: true, handler: function() { self.handleDelete([ self.current(n) ]); } });

		var sub = n.deferred ? typeName(n.proto) : [ typeName(n.proto), delayText(n.delay) ].filter(Boolean).join(' · ');
		return {
			title: name, sub: sub, state: state, stateKind: kind, badges: badges,
			primary: n.deferred ? { label: _('Connect'), disabled: true }
				: (n.preferred ? { label: _('Back to automatic choice') } : { label: _('Connect'), disabled: !key }),
			menu: menu, active: inUse, dimmed: !!(n.deferred || (n.dead && !n.kept) || why),
			search: [ n.tag, n.server ].join(' ')
		};
	},

	makeCard: function(it) {
		var self = this;
		var C = { it: it };
		var sp = this.spec(it);
		var o = {
			id: it.key, title: sp.title, sub: sp.sub, state: sp.state, stateKind: sp.stateKind, badges: sp.badges,
			active: !!sp.active, dimmed: !!sp.dimmed, menu: [], menuLabel: _('More actions')
		};
		if (sp.primary) o.primary = { label: sp.primary.label, disabled: sp.primary.disabled,
			handler: function() { return self.primaryAction(C.it); } };
		if (it.kind === 'node') o.onSelect = function(v) {
			if (v) self.sel[C.it.key] = true; else delete self.sel[C.it.key];
			self.updateBulk();
		};
		C.el = common.nodeCard(o);
		C.badgeSig = JSON.stringify(sp.badges);
		C.search = String(sp.search || '').toLowerCase();
		this.setMenu(C, C.el.querySelector('.vp-card-actions'), sp.menu);
		return C;
	},

	updateCard: function(C, it) {
		C.it = it;
		var sp = this.spec(it);
		var o = { title: sp.title, sub: sp.sub, state: sp.state, stateKind: sp.stateKind,
			active: !!sp.active, dimmed: !!sp.dimmed, selected: !!this.sel[it.key] };
		if (sp.primary) o.primary = { label: sp.primary.label, disabled: !!sp.primary.disabled };
		var bs = JSON.stringify(sp.badges);
		if (bs !== C.badgeSig) { o.badges = sp.badges; C.badgeSig = bs; }
		common.updateNodeCard(C.el, o);
		C.search = String(sp.search || '').toLowerCase();
		this.setMenu(C, C.el.querySelector('.vp-card-actions'), sp.menu);
	},

	applyFilter: function() {
		var f = this.filter, self = this;
		Object.keys(this.cards).forEach(function(k) {
			var C = self.cards[k];
			var v = !!f && C.search.indexOf(f) < 0 && String(C.el.querySelector('.vp-card-title').textContent).toLowerCase().indexOf(f) < 0;
			if (C.el.hidden !== v) C.el.hidden = v;
		});
	},

	updateBulk: function() {
		var self = this;
		var keys = Object.keys(this.sel).filter(function(k) { return self.cards[k]; });
		var t = _('Selected: %d').format(keys.length);
		if (this.bulkCount.textContent !== t) this.bulkCount.textContent = t;
		this.bulk.hidden = keys.length === 0;
	},
	selectedNodes: function() {
		var self = this;
		return Object.keys(this.sel).map(function(k) { return self.cards[k] && self.cards[k].it.node; }).filter(Boolean);
	},
	clearSelection: function() {
		var self = this;
		Object.keys(this.sel).forEach(function(k) { if (self.cards[k]) common.updateNodeCard(self.cards[k].el, { selected: false }); });
		this.sel = {};
		this.updateBulk();
	},

	// ---- actions of a card ----
	primaryAction: function(it) {
		if (it.kind === 'node') {
			var n = it.node;
			if (n.deferred) return;
			return n.preferred ? this.doAuto() : this.doConnect(idOf(n), n.tag || n.id);
		}
		if (it.kind === 'favout') return this.doConnect(it.fav.id, it.fav.tag || it.fav.id);
		if (it.kind === 'hidden') return this.doUnhide(it.hid.id, it.hid.tag);
	},
	after: function(p) {
		var self = this;
		return p.then(function() { return self.refresh(); }, noop);
	},
	doConnect: function(id, name) {
		return this.after(common.call('connect', { id: id }, { success: function(r) {
			if (r.code === 'connect_pending') return common.codeText('connect_pending');
			if (r.code === 'saved_not_applied') return _('%s is chosen: it is used once the service runs.').format(name);
			return _('Connected to %s.').format(name);
		} }));
	},
	doAuto: function() {
		return this.after(common.call('auto_select', {}, { success: function(r) {
			return r.code === 'unchanged' ? _('The automatic choice is already on.') : _('Back to the automatic choice.');
		} }));
	},
	doFav: function(id, name) { return this.after(common.call('fav', { id: id }, { success: _('Added to favourites: %s').format(name) })); },
	doUnfav: function(id, name) { return this.after(common.call('unfav', { id: id }, { success: _('Removed from favourites: %s').format(name || id) })); },
	doHide: function(id, name) {
		return this.after(common.call('hide', { id: id }, { success: _('Hidden: %s. You can return it from the hidden nodes.').format(name) }));
	},
	doUnhide: function(id, name) {
		return this.after(common.call('unhide', { id: id }, { success: name ? _('Returned: %s.').format(name) : _('Returned.') }));
	},
	doKeep: function(id, name) {
		return this.after(common.call('restore_node', { id: id }, { success: _('Back in the automatic choice: %s. It stays there even if the check fails.').format(name) }));
	},
	doUnkeep: function(id, name) {
		return this.after(common.call('refilter_node', { id: id }, { success: _('%s is checked automatically again.').format(name) }));
	},
	// the node as the last status has it (a menu is built once; its node may have changed since)
	current: function(n) {
		var cur = arr((this.st || {}).nodes).filter(function(x) { return x && n && x.id && x.id === n.id; })[0];
		return cur || n;
	},
	// exclusions are a list of EXCLUDED nodes in the backend: every other node takes part, new
	// ones too; the engine ignores exclusions that would empty the automatic choice, so excluding
	// the last one is refused here — the last one BEFORE "favourites only" (that option steps back
	// by itself when no favourite is left, as in generator.uc)
	doExclude: function(n) {
		var p = autoPool(this.st || {});
		if (p.beforeFav.length === 1 && p.beforeFav[0] === n.id) {
			common.toast(_('At least one node must stay in the automatic choice.'), 'warning', 'auto-pool');
			return Promise.resolve();
		}
		return this.after(common.call('auto_exclude', { id: idOf(n) }, { success: _('Excluded from the automatic choice: %s').format(n.tag) }));
	},
	doInclude: function(n) {
		return this.after(common.call('auto_include', { id: idOf(n) }, { success: _('Back in the automatic choice: %s').format(n.tag) }));
	},

	runTest: function(n, kind) {
		var self = this, id = idOf(n), name = n.tag || n.id;
		var start = (kind === 'speedtest') ? 'speedtest' : 'unlock';
		return common.call(start, { id: id }).then(function(r) {
			if (r.code === 'already_running') { common.toast(common.codeText('busy'), 'warning', start); return; }
			self.busyNode[n.id] = kind;
			self.update(self.st);
			common.toast((kind === 'speedtest')
				? _('Testing the speed of %s: for a moment the router sends its traffic through this node.').format(name)
				: _('Checking which services open through %s: for a moment the router sends its traffic through this node.').format(name));
			return pollResult(start + '_result', 120000).then(function(res) {
				if (kind === 'speedtest') {
					self.speed[n.id] = res.mbps;
					common.toast(_('%s: %s Mbit/s').format(name, res.mbps));
				} else common.toast(_('The service check of %s is done.').format(name));
			}, function(e) { common.toast(common.errorText(e), 'error', start); });
		}).catch(noop).then(function() {
			delete self.busyNode[n.id];
			return self.refresh();
		});
	},
	doSpeedtest: function(n) { return this.runTest(n, 'speedtest'); },
	doUnlock: function(n) { return this.runTest(n, 'unlock'); },

	showLink: function(id, name) {
		return common.call('node_link', { id: id }, { quiet: true }).then(function(r) {
			var link = String(r.link || '');
			var qr = E('div', { 'class': 'vp-qr' }, [ E('em', { 'class': 'vp-muted' }, '…') ]);
			var ta = E('textarea', { 'class': 'vp-link-text', 'rows': '4', 'readonly': 'readonly', 'aria-label': _('Link') }, [ link ]);
			ui.showModal(common.txt(_('Node link: %s').format(name)), [
				E('p', {}, _('Scan the code with the VPN app on your phone, or copy the link.')),
				qr, ta,
				E('div', { 'class': 'button-row right' }, [
					button(_('Copy the link'), 'cbi-button-action', function() { copyFrom(ta); }),
					button(_('Close'), '', function() { ui.hideModal(); })
				])
			], 'vp-link-dialog');
			renderQR(qr, link);
		}, function(e) {
			common.toast(e.code === 'not_found' ? _('This node has no link to share.') : common.errorText(e), 'error', 'node_link');
		});
	},

	consequencesOf: function(nodes) {
		var c = [], subs = 0, mine = 0, awg = 0, fav = 0, pref = false;
		nodes.forEach(function(n) {
			// the same conditions as api.uc delete_one: a file of the awg source -> the file goes, a
			// manual link -> the link goes, anything else of a build -> it is hidden
			if (n.source === 'awg' && (n.proto === 'awg' || n.proto === 'wireguard')) awg++;
			else if (n.source === 'manual') mine++;
			else subs++;
			if (n.favorite) fav++;
			if (n.preferred) pref = true;
		});
		if (subs) c.push(_('Nodes of a subscription (%d) are hidden: the subscription will not bring them back. You can return them from the hidden nodes.').format(subs));
		if (mine) c.push(_('Your links (%d) are removed from your nodes.').format(mine));
		if (awg) c.push(_('AmneziaWG settings files (%d) are removed from the router.').format(awg));
		if (fav) c.push(_('Favourites (%d) stay in your favourites.').format(fav));
		if (pref) c.push(_('The node chosen by you goes: the automatic choice takes over.'));
		return c;
	},
	handleDelete: function(nodes) {
		var self = this;
		var one = nodes.length === 1;
		return common.confirm({
			title: one ? _('Delete the node %s?').format(nodes[0].tag || nodes[0].id) : _('Delete the selected nodes (%d)?').format(nodes.length),
			consequences: this.consequencesOf(nodes),
			confirm: _('Delete'), danger: true
		}).then(function(yes) {
			if (!yes) return;
			var ids = nodes.map(idOf).filter(Boolean);
			return self.after(common.call('delete_nodes', { ids: ids }, { success: function(r) {
				var n = (r && r.deleted != null) ? r.deleted : ids.length;
				return one ? _('Deleted: %s').format(nodes[0].tag || nodes[0].id) : _('Deleted nodes: %d').format(n);
			} }).then(function(r) {
				ids.forEach(function(i) { Object.keys(self.sel).forEach(function(k) { if (self.cards[k] && idOf(self.cards[k].it.node) === i) delete self.sel[k]; }); });
				self.updateBulk();
				return r;
			}));
		});
	},
	handleDeleteFile: function(file) {
		var self = this;
		return common.confirm({ title: _('Delete the settings file %s?').format(file),
			consequences: [ _('The file is removed from the router.') ], confirm: _('Delete'), danger: true }).then(function(yes) {
			if (yes) return self.after(common.call('delete_node', { file: file }, { success: _('Deleted: %s').format(file) }));
		});
	},

	// ---- bulk ----
	handleBulkFav: function() {
		var self = this;
		var nodes = this.selectedNodes().filter(function(n) { return !n.favorite; });
		if (!nodes.length) { common.toast(_('The selected nodes are already in your favourites.')); return Promise.resolve(); }
		return sequence(nodes, function(n) { return common.call('fav', { id: idOf(n) }, { quiet: true }); }).then(function(r) {
			if (r.err) common.toast(common.errorText(r.err), 'error', 'fav');
			if (r.ok) common.toast(_('Added to favourites: %d').format(r.ok));
			return self.refresh();
		});
	},
	handleBulkHide: function() {
		var self = this;
		var nodes = this.selectedNodes().filter(function(n) { return n.source !== 'favorite' && !n.deferred; });
		if (!nodes.length) { common.toast(_('None of the selected nodes can be hidden.'), 'warning', 'hide'); return Promise.resolve(); }
		return sequence(nodes, function(n) { return common.call('hide', { id: idOf(n) }, { quiet: true }); }).then(function(r) {
			if (r.err) common.toast(common.errorText(r.err), 'error', 'hide');
			if (r.ok) common.toast(_('Hidden nodes: %d. You can return them from the hidden nodes.').format(r.ok));
			self.clearSelection();
			return self.refresh();
		});
	},
	handleBulkDelete: function() {
		var nodes = this.selectedNodes().filter(function(n) { return n.source !== 'favorite'; });
		if (!nodes.length) { common.toast(_('None of the selected nodes can be deleted: remove favourites from the favourites instead.'), 'warning', 'delete'); return Promise.resolve(); }
		return this.handleDelete(nodes);
	},

	// ---- toolbar ----
	handlePing: function() {
		return this.after(common.call('ping', {}, { success: function(r) {
			return r.code === 'already_running' ? _('The check is already running.') : _('Checking every node: the delays update as it goes.');
		} }));
	},
	handleRefresh: function() {
		return this.after(common.call('refresh', {}, { success: _('Updating every subscription: the list refreshes when it is done.') }));
	},
	// "Update" in the head of a subscription: only this subscription is downloaded again
	handleSubRefresh: function(sub) {
		var name = (sub && (sub.name || sub.url)) || '';
		return this.after(common.call('sub_refresh', { id: sub && sub.id }, { handle: [ 'disabled' ],
			success: _('Updating the subscription %s: its nodes refresh when it is done.').format(name) }).catch(function(e) {
			if (e && e.code === 'disabled') common.toast(_('The subscription is turned off. Turn it on to update it.'), 'warning', 'sub_refresh');
			throw e;
		}));
	},

	handleAutoPool: function() {
		var self = this, st = this.st || {};
		var nodes = arr(st.nodes).filter(function(n) { return n && n.id && !n.deferred; });
		if (!nodes.length) { common.toast(common.codeText('no_nodes'), 'warning', 'auto-pool'); return; }
		var p = autoPool(st);
		// checked = not left out by the user (excluded / off the 1.x member list); "favourites only" is said apart
		var list = pickList({ nodes: nodes }, function(n) { var w = p.why(n.id); return !w || w === 'favorites_only'; });
		ui.showModal(common.txt(_('Which nodes take part in the automatic choice')), [
			E('p', {}, _('The automatic choice switches only between the checked nodes; new nodes of the subscriptions take part too. The others stay in the list: you can still connect to them yourself.')),
			p.favOnly ? E('p', { 'class': 'vp-muted' }, _('"Favourites only" is on: of the checked nodes, only the favourites take part.')) : '',
			p.memberListActive ? E('p', { 'class': 'vp-pool-oldlist' }, _('A list of nodes for the automatic choice from the previous version is in effect: new nodes do not join it. Save this window and new nodes will take part by themselves.')) : '',
			list.el,
			E('div', { 'class': 'button-row right' }, [
				button(_('Cancel'), '', function() { ui.hideModal(); }),
				button(_('Save'), 'cbi-button-positive important', function() {
					var ids = list.ids();
					if (!ids.length) { common.toast(_('At least one node must stay in the automatic choice.'), 'warning', 'auto-pool'); return; }
					var shown = nodes.map(function(n) { return n.id; });
					var excl = shown.filter(function(i) { return ids.indexOf(i) < 0; });
					// set_config replaces the list: keep the exclusions of nodes this window does not
					// show (a deferred node, a subscription that is off or not fetched right now)
					arr(st.auto_exclude_ids).forEach(function(i) { if (shown.indexOf(i) < 0 && excl.indexOf(i) < 0) excl.push(i); });
					ui.hideModal();
					// one save: the unchecked ones become exclusions, a 1.x member list goes
					self.after(common.call('set_config', { settings: { auto_members: [], auto_excludes: excl } }, {
						success: (ids.length < nodes.length) ? _('Saved: %d of %d nodes take part in the automatic choice.').format(ids.length, nodes.length)
							: _('Every node takes part in the automatic choice, new ones too.') }));
				})
			])
		], 'vp-pool-dialog');
	},

	handleExport: function() {
		var out = E('div', { 'class': 'vp-export-out', 'aria-live': 'polite' });
		var show = function(scope) {
			dom.content(out, E('p', { 'class': 'spinning' }, _('Collecting the links…')));
			return common.call('export_nodes', { scope: scope }, { handle: [ 'empty' ] }).then(function(r) {
				var links = arr(r.links);
				var text = links.join('\n'), b64 = '';
				try { b64 = window.btoa(unescape(encodeURIComponent(text))); } catch (e) { b64 = ''; }
				var block = function(label, value, file) {
					var ta = E('textarea', { 'rows': '5', 'readonly': 'readonly', 'aria-label': label }, [ value ]);
					return E('div', {}, [
						E('p', {}, [ E('b', {}, label) ]), ta,
						E('div', { 'class': 'button-row' }, [
							button(_('Copy'), 'cbi-button-action', function() { copyFrom(ta); }),
							E('a', { 'class': 'btn cbi-button', 'download': file, 'href': 'data:text/plain;charset=utf-8,' + encodeURIComponent(value) }, _('Download'))
						])
					]);
				};
				dom.content(out, [
					E('p', {}, N_(links.length, '%d node', '%d nodes').format(links.length)),
					block(_('Node links'), text, 'vpnpool-nodes.txt'),
					block(_('The same as a subscription'), b64, 'vpnpool-subscription.txt')
				]);
			}, function(e) {
				dom.content(out, E('p', { 'class': 'vp-muted' }, e.code === 'empty' ? _('There is nothing to export in this set.') : common.errorText(e)));
			});
		};
		ui.showModal(common.txt(_('Export nodes')), [
			E('p', {}, _('Choose which nodes to export: you get their links and the same list as a subscription for another app.')),
			E('div', { 'class': 'button-row' }, [
				button(_('Favourites'), '', function() { show('favorites'); }),
				button(_('My nodes'), '', function() { show('manual'); }),
				button(_('Every node'), '', function() { show('all'); })
			]),
			out,
			E('div', { 'class': 'button-row right' }, [ button(_('Close'), '', function() { ui.hideModal(); }) ])
		], 'vp-export-dialog');
	},

	// ---- a subscription group ----
	handleSubPick: function(s) {
		var self = this;
		var box = E('div', { 'class': 'vp-pick-box', 'aria-live': 'polite' }, [ E('p', { 'class': 'spinning' }, _('Downloading the subscription and checking its nodes. On a slow router this takes up to a minute.')) ]);
		var saveBtn = button(_('Save'), 'cbi-button-positive important', null, { 'disabled': 'disabled' });
		ui.showModal(common.txt(_('Pick nodes: %s').format(s.name || '')), [
			box,
			E('div', { 'class': 'button-row right' }, [ button(_('Cancel'), '', function() { ui.hideModal(); }), saveBtn ])
		], 'vp-pick-dialog');
		var inPool = {};
		arr((this.st || {}).nodes).forEach(function(n) { if (n && n.sub === s.id && n.id) inPool[n.id] = true; });
		return probe(s.key || s.id).then(function(res) {
			var allBox = E('input', { 'type': 'checkbox' });
			allBox.checked = s.mode !== 'pick';
			// picked = the nodes of THIS subscription in the pool (in_pool of the probe also counts
			// another source's copy of the node)
			var list = pickList(res, function(n) { return s.mode !== 'pick' || inPool[n.id]; });
			list.disable(allBox.checked);
			allBox.addEventListener('change', function() { list.disable(allBox.checked); });
			dom.content(box, [
				E('label', { 'class': 'vp-pick-item' }, [ allBox, E('span', {}, _('Take every node of the subscription, new ones too')) ]),
				list.el
			]);
			saveBtn.disabled = false;
			saveBtn.addEventListener('click', busyClick(saveBtn, function() {
				var args = { id: s.id };
				if (allBox.checked) args.mode = 'all';
				else {
					args.mode = 'pick'; args.pick = list.ids();
					if (!args.pick.length) { common.toast(_('Pick at least one node, or take every node.'), 'warning', 'sub_set'); return; }
				}
				return common.call('sub_set', args, { success: allBox.checked ? _('Saved: the subscription gives every node, new ones too.') : _('Saved: the subscription gives %d picked nodes.').format(args.pick.length) })
					.then(function() { ui.hideModal(); return self.refresh(); });
			}));
		}, function(e) {
			dom.content(box, E('p', { 'class': 'vp-nodes-err' }, probeError(e)));
		});
	},
	handleSubEnable: function(s, on) {
		return this.after(common.call('sub_set', { id: s.id, enabled: on }, { success: on ? _('The subscription is on: its nodes come back after the update.') : _('The subscription is off: its nodes are not used.') }));
	},
	handleSubDelete: function(s) {
		var self = this;
		return common.confirm({
			title: _('Delete the subscription %s?').format(s.name || ''),
			consequences: [ _('Its nodes leave the list.'), _('Your favourites from it stay and connect with one button.') ],
			confirm: _('Delete'), danger: true
		}).then(function(yes) {
			if (yes) return self.after(common.call('sub_del', { id: s.id }, { success: _('The subscription is deleted.') }));
		});
	},

	// ---- "+ Add" ----
	handleAdd: function() {
		var self = this;
		var D = { reply: null, text: '', rows: [], lock: false };
		D.ta = E('textarea', { 'class': 'cbi-input-textarea vp-add-text', 'rows': '6', 'spellcheck': 'false',
			'aria-label': _('Links, subscription addresses or settings'),
			'placeholder': _('Paste node links (one per line), a subscription address or AmneziaWG settings') });
		// the field's error ("invalid" + errors.text of analyze / add) is said under it (common.markFieldErrors)
		D.box = E('div', {}, [ E('div', { 'class': 'vp-add-field', 'data-field': 'text' }, [ D.ta ]) ]);
		var fileIn = E('input', { 'type': 'file', 'class': 'vp-hidden-file', 'tabindex': '-1', 'aria-hidden': 'true', 'accept': '.txt,.conf,.json,text/plain,application/json' });
		var imgIn = E('input', { 'type': 'file', 'class': 'vp-hidden-file', 'tabindex': '-1', 'aria-hidden': 'true', 'accept': 'image/*' });
		D.summary = E('div', { 'class': 'vp-add-summary', 'aria-live': 'polite' });
		D.preview = E('div', { 'class': 'vp-add-preview' });
		D.result = E('div', { 'class': 'vp-add-result', 'aria-live': 'polite' });
		D.checkBtn = button(_('Check'), 'cbi-button-action vp-add-check');
		D.addBtn = button(_('Add'), 'cbi-button-positive important vp-add-commit', null, { 'disabled': 'disabled' });
		D.checkBtn.addEventListener('click', busyClick(D.checkBtn, function() { return self.addAnalyze(D); }));
		D.addBtn.addEventListener('click', busyClick(D.addBtn, function() { return self.addCommit(D); }, function() { return !self.canAdd(D); }));
		D.ta.addEventListener('input', function() {
			if (!D.reply && !D.lock) return;
			D.reply = null; D.lock = false; D.rows = [];
			dom.content(D.summary, []);
			dom.content(D.preview, E('p', { 'class': 'vp-muted' }, _('The text has changed: check it again.')));
			dom.content(D.result, []);
			D.addBtn.disabled = true;
		});
		fileIn.addEventListener('change', function() {
			var f = fileIn.files && fileIn.files[0];
			fileIn.value = '';
			if (f) self.addFile(D, f);
		});
		imgIn.addEventListener('change', function() {
			var f = imgIn.files && imgIn.files[0];
			imgIn.value = '';
			if (f) self.addQR(D, f);
		});
		ui.showModal(common.txt(_('Add nodes')), [
			E('p', {}, _('One field for everything: node links, a subscription address, an AmneziaVPN link or AmneziaWG settings. Check first: every line shows whether it will be added.')),
			D.box,
			E('div', { 'class': 'vp-add-tools' }, [
				button(_('From a file…'), 'vp-add-file', function() { fileIn.click(); }),
				button(_('QR code from a picture…'), 'vp-add-qr', function() { imgIn.click(); }),
				fileIn, imgIn
			]),
			D.summary, D.preview, D.result,
			E('div', { 'class': 'button-row right' }, [ button(_('Cancel'), '', function() { ui.hideModal(); }), D.checkBtn, D.addBtn ])
		], 'vp-add-dialog');
		D.ta.focus();
		this.addDialog = D;
		return D;
	},

	// text from a file or a QR: AmneziaWG settings are one file per add (analyze reads a paste
	// with an [Interface] part as ONE settings file), so they replace the field
	addText: function(D, t) {
		var conf = /\[interface\]/i.test(t) || /\[interface\]/i.test(D.ta.value);
		var had = !!D.ta.value.trim();
		D.ta.value = (conf || !had) ? t : D.ta.value.replace(/\s*$/, '') + '\n' + t;
		D.reply = null; D.lock = false;
		if (conf && had) common.toast(_('The field now holds only these settings: AmneziaWG settings are added one file at a time.'));
		return this.addAnalyze(D);
	},
	addFile: function(D, f) {
		var self = this;
		if (f.size > MAX_FILE) { common.toast(common.codeText('too_large'), 'error', 'add-file'); return Promise.resolve(); }
		return new Promise(function(resolve) {
			var rd = new FileReader();
			rd.onload = function() { resolve(self.addText(D, String(rd.result || ''))); };
			rd.onerror = function() { common.toast(_('The file could not be read.'), 'error', 'add-file'); resolve(); };
			rd.readAsText(f);
		});
	},
	addQR: function(D, f) {
		var self = this;
		return decodeQR(f).then(function(t) {
			if (!t) { common.toast(_('No QR code was found in the picture. Try a sharper or a closer picture.'), 'error', 'add-qr'); return; }
			return self.addText(D, t);
		}, function() { common.toast(_('The picture could not be read.'), 'error', 'add-qr'); });
	},

	canAdd: function(D) {
		return !!(D.reply && !D.lock && D.rows.some(function(r) { return r.cb && r.cb.checked; }));
	},

	addAnalyze: function(D) {
		var self = this;
		var text = String(D.ta.value || '');
		if (!text.trim()) { common.toast(_('Paste links or load a file first.'), 'warning', 'add'); return Promise.resolve(); }
		if (requestBytes(text) > MAX_TEXT) { common.toast(_('The text is too large to check at once: add it in parts.'), 'error', 'add'); return Promise.resolve(); }
		return common.call('analyze', { text: text }).then(function(r) {
			common.markFieldErrors(D.box, { errors: {} });
			D.reply = r; D.text = text; D.lock = false;
			D.lines = lineTexts(text);
			self.renderPreview(D);
		}, function(e) { common.markFieldErrors(D.box, e); });
	},

	chipOf: function(it) {
		if (it.status === 'add') return it.deferred ? common.badge(_('Will wait for the engine'), 'warn') : common.badge(_('Will be added'), 'ok');
		if (it.status === 'dup') return common.badge(it.reason === 'repeated' ? _('Repeated') : _('Already there'), 'muted');
		return common.badge(_('Will not be added'), 'error');
	},

	renderPreview: function(D) {
		var self = this;
		var r = D.reply || {};
		var items = arr(r.items);
		var lines = D.lines || [];   // analyze answers line numbers only: the texts are ours
		D.rows = [];
		dom.content(D.result, []);
		if (!items.length) {
			dom.content(D.summary, []);
			dom.content(D.preview, E('p', { 'class': 'vp-muted' }, _('Nothing that could be added was found in the text.')));
			D.addBtn.disabled = true;
			return;
		}
		var n = { add: 0, dup: 0, skip: 0 };
		var rows = items.map(function(it) {
			var row = { it: it };
			n[it.status === 'add' ? 'add' : (it.status === 'dup' ? 'dup' : 'skip')]++;
			row.chip = E('span', { 'class': 'vp-add-chip' }, [ self.chipOf(it) ]);
			var name = it.name || shortLine(lines[it.line - 1]);
			var meta = [ typeName(it.type), it.server ].filter(Boolean).join(' · ');
			var why = (it.status === 'add') ? (it.deferred ? common.codeText(it.deferred) : '') : common.reasonText(it.reason || it.status);
			row.why = E('span', { 'class': 'vp-add-why' }, [ why ]);
			var kids = [];
			if (it.status === 'add') {
				row.cb = E('input', { 'type': 'checkbox', 'aria-label': _('Add line %d').format(it.line) });
				row.cb.checked = true;
				row.cb.addEventListener('change', function() { D.addBtn.disabled = !self.canAdd(D); });
				kids.push(row.cb);
			}
			kids.push(E('span', { 'class': 'vp-add-line' }, _('line %d').format(it.line)), row.chip, E('span', { 'class': 'vp-add-name' }, [ name ]));
			if (meta) kids.push(E('span', { 'class': 'vp-add-meta' }, [ meta ]));
			if (it.kind === 'subscription_url' && it.status === 'add') {
				row.mode = E('select', { 'class': 'cbi-input-select vp-add-mode', 'aria-label': _('What to take from the subscription') }, [
					E('option', { 'value': 'all' }, _('Take every node and keep it updated')),
					E('option', { 'value': 'pick' }, _('Pick nodes…'))
				]);
				row.pickBox = E('div', { 'class': 'vp-add-pick', 'hidden': 'hidden' });
				row.mode.addEventListener('change', function() { self.addPickMode(row, lines[it.line - 1]); });
				kids.push(row.mode);
			}
			if (why) kids.push(row.why);
			if (row.pickBox) kids.push(row.pickBox);
			row.el = E('div', { 'class': 'vp-add-row', 'data-line': String(it.line), 'data-status': String(it.status || '') }, kids);
			D.rows.push(row);
			return row.el;
		});
		dom.content(D.summary, [ _('Will be added: %d, already there: %d, will not be added: %d').format(n.add, n.dup, n.skip) ]);
		dom.content(D.preview, rows);
		D.addBtn.disabled = !this.canAdd(D);
	},

	addPickMode: function(row, url) {
		if (row.mode.value !== 'pick') { row.pickBox.hidden = true; return Promise.resolve(); }
		row.pickBox.hidden = false;
		if (row.pick || row.probing) return Promise.resolve();
		row.probing = true;
		dom.content(row.pickBox, E('p', { 'class': 'spinning' }, _('Downloading the subscription and checking its nodes. On a slow router this takes up to a minute.')));
		return probe(url).then(function(res) {
			row.pick = pickList(res, function(n) { return n.delay != null && n.delay > 0; });
			dom.content(row.pickBox, row.pick.el);
		}, function(e) {
			dom.content(row.pickBox, E('p', { 'class': 'vp-nodes-err' }, probeError(e)));
		}).then(function() { row.probing = false; });
	},

	addCommit: function(D) {
		var self = this;
		if (!this.canAdd(D)) return Promise.resolve();
		var gen = [], picks = [], problem = null;
		D.rows.forEach(function(row) {
			if (!row.cb || !row.cb.checked) return;
			if (row.mode && row.mode.value === 'pick') {
				var ids = row.pick ? row.pick.ids() : [];
				if (!ids.length) { problem = problem || row; return; }
				picks.push({ line: row.it.line, ids: ids });
			} else gen.push(row.it.line);
		});
		if (problem) {
			common.toast(_('Line %d: pick at least one node of the subscription, or take every node.').format(problem.it.line), 'warning', 'add');
			return Promise.resolve();
		}
		var calls = [];
		if (gen.length) calls.push({ text: D.text, lines: gen });
		picks.forEach(function(p) { calls.push({ text: D.text, lines: [ p.line ], options: { mode: 'pick', pick: p.ids } }); });
		var tot = { added: 0, dup: 0, failed: [] };
		var take = function(r) {
			tot.added += +(r && r.added) || 0;
			tot.dup += +(r && r.dup) || 0;
			arr(r && r.failed).forEach(function(f) { if (f && f.line != null) tot.failed.push(f); });
		};
		return sequence(calls, function(args) {
			// the whole request counts (the text + the lines + hundreds of picked ids), not only the text
			if (jsonBytes(args) > MAX_REQUEST) {
				args.lines.forEach(function(l) { tot.failed.push({ line: l, text: common.codeText('too_large') }); });
				return;
			}
			return common.call('add', args, { quiet: true }).then(take, function(e) {
				if (e instanceof common.Error && e.code === 'nothing_added' && e.reply) return take(e.reply);
				args.lines.forEach(function(l) { tot.failed.push({ line: l, text: common.errorText(e) }); });
			});
		}).then(function() {
			D.lock = true;
			self.addResult(D, tot);
			return self.refresh();
		});
	},

	// the result of "Add": every row says what happened; the dialog closes by itself only when
	// nothing went wrong
	addResult: function(D, tot) {
		var failed = {};
		tot.failed.forEach(function(f) { failed[f.line] = f; });
		var sent = {};
		D.rows.forEach(function(row) { if (row.cb && row.cb.checked) sent[row.it.line] = true; });
		var dup = tot.dup, errLines = [];
		D.rows.forEach(function(row) {
			var it = row.it, f = failed[it.line];
			if (f) {
				errLines.push(it.line);
				dom.content(row.chip, common.badge(_('Not added'), 'error'));
				row.why.textContent = f.text || common.reasonText(f.reason);
				if (!row.why.parentNode) row.el.appendChild(row.why);
			} else if (sent[it.line]) {
				// the reply counts duplicates found while adding, not per line
				dom.content(row.chip, tot.dup ? common.badge(_('Added or already there'), 'ok') : common.badge(_('Added'), 'ok'));
			} else if (it.status === 'dup') dup++;
			else if (it.status !== 'add') errLines.push(it.line);
			if (row.cb) row.cb.disabled = true;
			if (row.mode) row.mode.disabled = true;
			if (row.pick) row.pick.disable(true);
		});
		errLines.sort(function(a, b) { return a - b; });
		var t = _('Added: %d, already there: %d, errors: %d').format(tot.added, dup, errLines.length);
		if (errLines.length) t += ' (' + _('lines %s').format(errLines.join(', ')) + ')';
		D.addBtn.disabled = true;
		if (!errLines.length) {
			ui.hideModal();
			common.toast(t);
			return;
		}
		D.result.setAttribute('data-kind', 'warn');
		dom.content(D.result, [ t ]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
