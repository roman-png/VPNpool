#!/usr/bin/ucode
// vpnpool sing-box config generator.
// Input : nodes JSON (array of vless outbounds from parser.uc) as ARGV[0].
//         Settings are read from uci 'vpnpool'.
// Output: full sing-box config for OUR second instance, on stdout.
//
// Design (coexists with podkop):
//   inbound : tproxy 127.0.0.1:<tproxy_port>  (sniff via route action)
//   route   : sniff SNI -> our domains => "proxy"; everything else => "direct"
//   outbound: urltest "auto" (auto-ping + failover) + selector "proxy" (manual
//             override, default auto) + the nodes + "direct"
//   experimental.clash_api for the watchdog / LuCI.
'use strict';

import { readfile, writefile } from 'fs';
import { cursor } from 'uci';
import { VALID_COMMUNITY } from './common.uc';

let nodes_path = ARGV[0];
let nodes = nodes_path ? json(readfile(nodes_path)) : [];
if (type(nodes) != 'array')
	nodes = [];
// nodes.json carries the node identity `id` (parser --with-id: EVERY store keys on it — auto-pool
// members, dead marks, favourites, the preferred node) and bookkeeping fields `_*` (`_link`,
// `_src`): sing-box rejects unknown outbound fields, so none of them may reach the config.
// TAG_OF: id -> the tag this build gave the node (the config references nodes by tag).
let TAG_OF = {};
for (let n in nodes) {
	if (type(n) != 'object') continue;
	if (n.id != null) TAG_OF[n.id] = n.tag;
	delete n.id;
	for (let k in keys(n)) if (substr(k, 0, 1) == '_') delete n[k];
}
// a list of ids -> the tags of the nodes of THIS build (unknown ids are dropped)
function tags_of(ids) {
	let out = [];
	for (let i in ids) if (TAG_OF[i] != null) push(out, TAG_OF[i]);
	return out;
}
function as_array(v) { return (v == null) ? [] : ((type(v) == 'array') ? v : [ v ]); }

let uci = cursor();
function opt(section, name, def) {
	let v = uci.get('vpnpool', section, name);
	return (v != null && v != '') ? v : def;
}

let tproxy_port = int(opt('main', 'tproxy_port', 1603));
let clash_api   = opt('main', 'clash_api', '127.0.0.1:9091');

// ---- XHTTP nodes: the xray sidecar ----
// sing-box has no XHTTP transport. Each such node (parser: transport.type "xhttp", vless or
// trojan) becomes a sing-box socks outbound with the node's own tag to 127.0.0.1:<port>, and
// xray (VPNPOOL_XRAY_CONF, written here) carries that port's traffic to the real server. To
// sing-box it is an ordinary node: urltest, the clash delay probes, the selectors and the
// per-connection traffic work unchanged — and a delay probe measures the whole path through xray.
// Ports: xray_base_port + the node's index among the XHTTP nodes of this build (loopback only).
// No XHTTP node -> no xray config (build.sh removes the old one, the daemon runs no xray).
let XRAY_FP = { chrome: 1, firefox: 1, safari: 1, ios: 1, android: 1, edge: 1, '360': 1, qq: 1,
	random: 1, randomized: 1 };
function xray_outbound(n, tag) {
	let tr = n.transport, tls = n.tls;
	let ss = { network: 'xhttp', xhttpSettings: {} };
	if (tr.path != null) ss.xhttpSettings.path = tr.path;
	if (tr.host != null) ss.xhttpSettings.host = tr.host;
	ss.xhttpSettings.mode = tr.mode ?? 'auto';
	if (tr.extra != null) ss.xhttpSettings.extra = tr.extra;
	let fp = tls?.utls?.fingerprint;
	fp = (fp != null && XRAY_FP[fp]) ? fp : 'chrome';
	if (tls?.reality) {
		ss.security = 'reality';
		ss.realitySettings = { publicKey: tls.reality.public_key, fingerprint: fp };
		if (tls.server_name != null) ss.realitySettings.serverName = tls.server_name;
		if (tls.reality.short_id != null) ss.realitySettings.shortId = tls.reality.short_id;
		if (tls.reality.spider_x != null) ss.realitySettings.spiderX = tls.reality.spider_x;
	} else if (tls?.enabled) {
		ss.security = 'tls';
		ss.tlsSettings = {};
		if (tls.server_name != null) ss.tlsSettings.serverName = tls.server_name;
		if (tls.alpn != null) ss.tlsSettings.alpn = tls.alpn;
		if (tls.insecure) ss.tlsSettings.allowInsecure = true;
		if (tls.utls?.enabled) ss.tlsSettings.fingerprint = fp;
	} else
		ss.security = 'none';
	let ob = { tag: tag, streamSettings: ss };
	if (n.type == 'trojan') {
		ob.protocol = 'trojan';
		ob.settings = { servers: [ { address: n.server, port: n.server_port, password: n.password } ] };
	} else {
		let user = { id: n.uuid, encryption: 'none' };
		if (n.flow != null) user.flow = n.flow;
		ob.protocol = 'vless';
		ob.settings = { vnext: [ { address: n.server, port: n.server_port, users: [ user ] } ] };
	}
	return ob;
}
let xray_port = int(opt('main', 'xray_base_port', 20800));
let x_in = [], x_out = [ { tag: 'block', protocol: 'blackhole' } ], x_rules = [];
for (let i = 0; i < length(nodes); i++) {
	let n = nodes[i];
	if (type(n) != 'object' || n.transport?.type != 'xhttp') continue;
	let k = length(x_in), port = xray_port + k;
	push(x_in, { tag: 'in-' + k, listen: '127.0.0.1', port: port, protocol: 'socks',
		settings: { auth: 'noauth', udp: true, ip: '127.0.0.1' } });
	push(x_out, xray_outbound(n, 'out-' + k));
	push(x_rules, { type: 'field', inboundTag: [ 'in-' + k ], outboundTag: 'out-' + k });
	nodes[i] = { type: 'socks', tag: n.tag, server: '127.0.0.1', server_port: port, version: '5' };
}
let XRAY_CONF = getenv('VPNPOOL_XRAY_CONF');
if (length(XRAY_CONF ?? '') && length(x_in))
	writefile(XRAY_CONF, sprintf('%.J\n', {
		log: { loglevel: 'warning' },
		inbounds: x_in,
		outbounds: x_out,     // the first one is the default: nothing unmatched leaves
		routing: { rules: x_rules }
	}));
let health_url  = opt('main', 'health_url', 'http://cp.cloudflare.com/generate_204');

// urltest active-node pick + failover key on the SAME service the dead-filter / watchdog
// verify (check_services in uci), so the tunnel never settles on a node that opens
// Cloudflare but not the wanted service. We probe the host's /generate_204 (tiny response)
// — urltest only measures whether the request completes (any HTTP response = reachable; a
// blocked/over-quota exit can't connect and is excluded), and it never empties the pool
// (falls back to the first outbound), so keying it on a real service is safe. A bare host
// becomes http://<host>/generate_204; a full URL is used verbatim; empty => health_url.
let check_services = opt('main', 'check_services', '');
let probe_url = health_url;
if (length(check_services)) {
	let parts = split(trim(check_services), /[ \t\r\n]+/);
	let first = length(parts) ? parts[0] : null;
	if (first)
		probe_url = (index(first, '://') >= 0) ? first : ('http://' + first + '/generate_204');
}
// build.sh passes the URL computed by lib.sh (primary_probe_url — THE single "is it alive"
// definition shared with nodecheck / watchdog / ping) in VPNPOOL_PROBE_URL; the local
// computation above is only the fallback for a direct invocation.
let env_probe = getenv('VPNPOOL_PROBE_URL');
if (env_probe != null && length(env_probe))
	probe_url = env_probe;
let fo_interval = opt('main', 'failover_interval', '60');
let fo_tol      = int(opt('main', 'failover_tolerance', 50));
let log_level   = opt('main', 'log_level', 'warn');
// DNS resolution strategy for sing-box's OWN lookups (urltest/clash health probes
// and any in-tunnel domain). On a router whose system DNS returns AAAA first but has
// NO working IPv6 transit through the VLESS nodes, the default picks an IPv6 address
// for the probe URL and every health-check times out -> the dashboard shows "0 pings"
// for nodes that actually work (real traffic survives because it resolves at the exit
// node). 'prefer_ipv4' makes dual-stack probe hosts resolve to IPv4 while still
// allowing IPv6-only hosts. Override to 'ipv4_only' to disable IPv6 entirely.
let dns_strategy = opt('main', 'dns_strategy', 'prefer_ipv4');

// explicit domain suffixes
let domains = uci.get('vpnpool', 'routing', 'domain') ?? [];
if (type(domains) != 'array')
	domains = [domains];

// community lists -> sing-box remote SRS rule-sets (itdoginfo/allow-domains).
// sing-box downloads and auto-updates them. SRS assets live in the latest release.
let communities = uci.get('vpnpool', 'routing', 'community') ?? [];
if (type(communities) != 'array')
	communities = [communities];

let SRS_BASE = 'https://github.com/itdoginfo/allow-domains/releases/latest/download';
// stand tests only: a local server with the SRS files (the stand has no network)
if (length(getenv('VPNPOOL_SRS_BASE') ?? '')) SRS_BASE = getenv('VPNPOOL_SRS_BASE');
// VALID_COMMUNITY: the one list lives in common.uc (the settings validator uses it too).

// The config is generated FOR the engine that will run it (ROADMAP 4.2): build.sh passes its
// `version -n` in VPNPOOL_SB_VERSION (enginecap.uc). sing-box >= 1.14 downloads rule-sets
// through an HTTP client: `download_detour` is deprecated there (removed in 1.16) and the
// implicit default client is deprecated too (it dials through the DEFAULT outbound = our
// urltest). So on >= 1.14: a top-level http client WITHOUT a detour (= a plain direct dial)
// as route.default_http_client. NOT `detour: "direct"`: 1.14 refuses that at the first download
// ("detour to an empty direct outbound makes no sense" — a runtime error `check` does not see).
// 1.12/1.13 (and an unknown version) keep download_detour, which they need.
let SB_VER = getenv('VPNPOOL_SB_VERSION') ?? '';
let sbv = match(SB_VER, /^([0-9]+)\.([0-9]+)/);
let SB_GE_114 = sbv ? (int(sbv[1]) > 1 || (int(sbv[1]) == 1 && int(sbv[2]) >= 14)) : false;
let HTTP_CLIENT_TAG = 'vpnpool-direct';

let rule_sets = [];
let comm_tags = [];
for (let c in communities) {
	if (!VALID_COMMUNITY[c])
		continue;
	let tag = 'comm-' + c;
	let rs = {
		type: 'remote',
		tag: tag,
		format: 'binary',
		url: SRS_BASE + '/' + c + '.srs',
		update_interval: '24h'
	};
	// < 1.14: download_detour routes the SRS download via the "direct" outbound (so it does not
	// loop through the proxy before that is up) — verified on 1.12.25. >= 1.14: route
	// default_http_client below (see SB_GE_114).
	if (!SB_GE_114) rs.download_detour = 'direct';
	push(rule_sets, rs);
	push(comm_tags, tag);
}

// collect node tags
let node_tags = [];
for (let n in nodes)
	push(node_tags, n.tag);

// auto-pool members (uci list auto_member, node IDS): which nodes take part in urltest
// auto-switching. Empty / unset => ALL nodes (default; new nodes auto-join). When a non-empty
// subset is configured, only those nodes are auto-switched (the rest stay available for manual
// selection via the "proxy" selector). Ids of nodes not in this build are dropped; if the filter
// leaves nothing we fall back to all nodes so urltest is never empty.
let member_set = {};
for (let t in tags_of(as_array(uci.get('vpnpool', 'main', 'auto_member'))))
	member_set[t] = 1;

let auto_tags = [];
if (length(member_set)) {
	for (let t in node_tags)
		if (member_set[t]) push(auto_tags, t);
}
if (!length(auto_tags))
	auto_tags = node_tags;                               // default / fallback: all nodes

// nodes the user excluded from the automatic choice (uci list auto_exclude, node IDS; the UI's
// "Exclude from the automatic choice"): every other node takes part, new nodes too. Excluding
// every node would empty urltest: then the exclusions are ignored.
let excl_set = {};
for (let t in tags_of(as_array(uci.get('vpnpool', 'main', 'auto_exclude'))))
	excl_set[t] = 1;
if (length(excl_set)) {
	let kept = filter(auto_tags, (t) => !excl_set[t]);
	if (length(kept)) auto_tags = kept;
}

// "Favourites only" (uci favorites_only=1): the automatic choice uses only the user's
// favourite nodes (/etc/vpnpool/favorites.map.json, keyed by id). Never empties the pool: with
// no favourite in this build the option has no effect.
if (opt('main', 'favorites_only', '0') == '1') {
	let fav = json(readfile('/etc/vpnpool/favorites.map.json') ?? 'null');
	let fav_set = {};
	if (type(fav) == 'object') for (let t in tags_of(keys(fav))) fav_set[t] = 1;
	let only = filter(auto_tags, (t) => fav_set[t]);
	if (length(only)) auto_tags = only;
}

// Health prefilter (build.sh writes .alive_tags.json): keep ONLY TCP-reachable nodes
// in the urltest pool. A dead node leaves a hung probe socket every interval; ~10 of
// them pile up until urltest stalls and even live nodes stop pinging (root cause of the
// 2026-06-11 "0 pings / tunnel flaps" outage). Dead nodes stay in node_tags so they
// remain MANUALLY selectable via the 'proxy' selector — they're only dropped from auto.
// Absent/empty file (WAN blip at build) => no filtering; if the filter would empty the
// pool, keep it unfiltered — urltest must never be empty.
let alive_raw = readfile('/tmp/vpnpool/.alive_tags.json');
if (alive_raw) {
	let alive = json(alive_raw);
	if (type(alive) == 'array' && length(alive)) {
		let alive_set = {};
		for (let t in alive)
			alive_set[t] = 1;
		let filtered = [];
		for (let t in auto_tags)
			if (alive_set[t]) push(filtered, t);
		if (length(filtered))
			auto_tags = filtered;
	}
}

// Node-quality filter (nodecheck.sh writes .dead_ids.json, node ids): drop nodes that the
// e2e probe found unable to reach the user's services for a sustained run — they TCP-
// ping (and may even pass the single cp.cloudflare urltest probe) but carry no real
// traffic (expired-sub placeholders, over-quota / service-blocked exits). They stay
// in node_tags (manually selectable) but leave the auto/urltest pool. Never empty it.
let dead_raw = (opt('main', 'dead_filter', '1') != '0') ? readfile('/tmp/vpnpool/.dead_ids.json') : null;
if (dead_raw) {
	let dead = json(dead_raw);
	if (type(dead) == 'array' && length(dead)) {
		let dead_set = {};
		for (let t in tags_of(dead))
			dead_set[t] = 1;
		let kept = [];
		for (let t in auto_tags)
			if (!dead_set[t]) push(kept, t);
		if (length(kept))
			auto_tags = kept;
	}
}

// ---- outbounds ----
let outbounds = [];

// auto-ping + auto-switch group (only the configured auto-pool members)
push(outbounds, {
	type: 'urltest',
	tag: 'auto',
	outbounds: auto_tags,
	url: probe_url,
	interval: fo_interval + 's',
	tolerance: fo_tol,
	interrupt_exist_connections: true
});

// manual override selector. Its default is 'auto' (urltest + failover): the user's
// "Connect" choice is the SOFT preferred node (uci preferred_node, a node id), which the
// daemon's preferred_check puts on this selector while the node works and hands back to auto
// when it fails (ROADMAP 9.5 — there is no hard pin any more). auto_switch=0 = no automatic
// switching: the selector stays on the preferred node (or the first node).
let auto_switch = opt('main', 'auto_switch', '1');
let preferred_tag = TAG_OF[opt('main', 'preferred_node', '')] ?? null;

let sel = [ 'auto' ];
for (let t in node_tags)
	push(sel, t);

let def;
if (auto_switch == '0')
	def = preferred_tag ?? (length(node_tags) ? node_tags[0] : 'auto');
else
	def = 'auto';

push(outbounds, {
	type: 'selector',
	tag: 'proxy',
	outbounds: sel,
	default: def,
	interrupt_exist_connections: true
});

// Per-node test selector: speedtest.sh / unlock.sh point THIS selector (never the shared
// 'proxy' one) at the node under test and send their requests through the node-test-in
// inbound below — so a test never moves the LAN's traffic onto the tested node.
if (length(node_tags))
	push(outbounds, {
		type: 'selector',
		tag: 'vpnpool-test',
		outbounds: node_tags,
		default: node_tags[0],
		interrupt_exist_connections: false
	});

// the actual node outbounds (anti-DPI is applied as a route rule action below,
// not as an outbound field — sing-box only exposes tls_fragment via route-options).
// sing-box >=1.13: WireGuard/AmneziaWG is an ENDPOINT (top-level "endpoints" array),
// NOT an outbound — but its tag is still referenced from the urltest/selector groups
// like any node. So route type=='wireguard' into endpoints, the rest into outbounds.
let endpoints = [];
for (let n in nodes) {
	if (n.type == 'wireguard' || n.type == 'awg')
		push(endpoints, n);
	else
		push(outbounds, n);
}

// direct egress
push(outbounds, { type: 'direct', tag: 'direct' });

// ---- route ----
// mode 'selective' (default): listed lists/domains -> proxy, everything else -> direct.
// mode 'exclude': listed lists/domains -> direct, everything else -> proxy (full VPN
// except the chosen lists). Only the outbound direction flips; the nft layer is identical.
let mode      = opt('main', 'mode', 'selective');
let listed_ob = (mode == 'exclude') ? 'direct' : 'proxy';
let final_ob  = (mode == 'exclude') ? 'proxy'  : 'direct';

let rules = [ { action: 'sniff' } ];
// Anti-DPI: fragment the outgoing TLS ClientHello so SNI-based DPI can't match the
// handshake (incl. the Reality handshake to proxy servers). sing-box exposes this ONLY
// as the non-final "route-options" rule action (since 1.12.0) — NOT as an outbound dial
// field — so it is applied here, before the outbound-selecting rules. On a sing-box that
// predates 1.12 the field is rejected at decode time and build.sh keeps the previous
// working config (worst case: "no effect"), so the toggle is always safe.
// 3 levels (back-compat: legacy '0'->off, '1'->on):
//   off        - no fragmentation
//   on         - tls_fragment: split the ClientHello so plaintext-SNI DPI can't match it
//   aggressive - tls_record_fragment: break the handshake into multiple TLS records
// NOTE: sing-box treats tls_fragment and tls_record_fragment as MUTUALLY EXCLUSIVE
// (setting both fails decode), so aggressive uses the record variant INSTEAD of, not on
// top of, tls_fragment. Both defeat BASIC filtering only — not robust censorship (TSPU);
// for that the user needs zapret. tls_fragment_fallback_delay applies to tls_fragment only.
let antidpi = opt('main', 'antidpi', 'off');
if (antidpi == 'aggressive')
	push(rules, { action: 'route-options', tls_record_fragment: true });
else if (antidpi == '1' || antidpi == 'on')
	push(rules, { action: 'route-options', tls_fragment: true, tls_fragment_fallback_delay: '500ms' });
// the local test/SOCKS inbound always egresses through the proxy (for the
// "test exit via VPN" diagnostic and as a handy local proxy port)
push(rules, { inbound: [ 'test-mixed-in' ], outbound: 'proxy' });
if (length(node_tags))
	push(rules, { inbound: [ 'node-test-in' ], outbound: 'vpnpool-test' });
if (length(comm_tags))
	push(rules, { rule_set: comm_tags, outbound: listed_ob });
if (length(domains))
	push(rules, { domain_suffix: domains, outbound: listed_ob });

// Adaptive routing: domains auto-detected as blocked-for-direct (adaptive.sh) always
// go through the proxy, regardless of selective/exclude mode.
let adaptive = opt('main', 'adaptive_routing', '0');
let auto_domains = uci.get('vpnpool', 'routing', 'auto_domain') ?? [];
if (type(auto_domains) != 'array')
	auto_domains = [auto_domains];
let auto_dom_clean = [];
for (let d in auto_domains)
	if (length(d)) push(auto_dom_clean, d);
if (adaptive == '1' && length(auto_dom_clean))
	push(rules, { domain_suffix: auto_dom_clean, outbound: 'proxy' });

let route = {
	rules: rules,
	final: final_ob,
	auto_detect_interface: true
};
if (length(rule_sets))
	route.rule_set = rule_sets;
if (length(rule_sets) && SB_GE_114)
	route.default_http_client = HTTP_CLIENT_TAG;

// ---- inbound (tproxy) ----
// NOTE: omit "network" so tproxy listens on BOTH tcp and udp. The field is a
// single enum ("tcp"|"udp"); "tcp,udp" is invalid and fails sing-box check.
let test_port = int(opt('main', 'test_port', 1605));
let node_test_port = int(opt('main', 'node_test_port', 1606));
let inbounds = [
	{
		type: 'tproxy',
		tag: 'tproxy-in',
		listen: '127.0.0.1',
		listen_port: tproxy_port
	},
	{
		// local mixed (SOCKS+HTTP) proxy on loopback — used by the "test exit via
		// VPN" diagnostic; also usable directly by apps on the router.
		type: 'mixed',
		tag: 'test-mixed-in',
		listen: '127.0.0.1',
		listen_port: test_port
	},
	{
		// per-node tests (speedtest / unlock): egress via the 'vpnpool-test' selector only
		type: 'mixed',
		tag: 'node-test-in',
		listen: '127.0.0.1',
		listen_port: node_test_port
	}
];

// ---- dns ----
// New (1.12+) DNS server format: a single "local" server that defers to the system
// resolver (dnsmasq on OpenWrt), with a global resolution strategy. This fixes the
// IPv6-first health-probe stall described at dns_strategy above. 'off' omits the
// section entirely (legacy behaviour) for anyone who needs it.
let dns;
if (dns_strategy != 'off')
	dns = {
		servers: [ { type: 'local', tag: 'local' } ],
		strategy: dns_strategy
	};

// AmneziaWG / WireGuard endpoints log their whole device config, private and preshared keys
// included, at debug level ("AWG IPC config: ..." in the engine): never below info with them
if (length(endpoints) && (log_level == 'trace' || log_level == 'debug'))
	log_level = 'info';

// ---- assemble ----
let config = {
	log: { level: log_level, timestamp: true },
	outbounds: outbounds,
	route: route,
	experimental: {
		clash_api: { external_controller: clash_api },
		cache_file: { enabled: true, path: '/tmp/vpnpool/cache.db' }
	}
};
if (dns)
	config.dns = dns;
if (length(rule_sets) && SB_GE_114)
	config.http_clients = [ { tag: HTTP_CLIENT_TAG } ];   // no detour = direct dial (see SB_GE_114)
config.inbounds = inbounds;
if (length(endpoints))
	config.endpoints = endpoints;          // sing-box >=1.13 WireGuard/AmneziaWG endpoints

printf("%.J\n", config);
