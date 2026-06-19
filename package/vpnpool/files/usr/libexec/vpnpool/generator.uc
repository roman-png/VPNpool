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

import { readfile } from 'fs';
import { cursor } from 'uci';

let nodes_path = ARGV[0];
let nodes = nodes_path ? json(readfile(nodes_path)) : [];
if (type(nodes) != 'array')
	nodes = [];

let uci = cursor();
function opt(section, name, def) {
	let v = uci.get('vpnpool', section, name);
	return (v != null && v != '') ? v : def;
}

let tproxy_port = int(opt('main', 'tproxy_port', 1603));
let clash_api   = opt('main', 'clash_api', '127.0.0.1:9091');
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
let VALID_COMMUNITY = {
	russia_inside: 1, russia_outside: 1, ukraine_inside: 1, geoblock: 1, block: 1,
	porn: 1, news: 1, anime: 1, youtube: 1, hdrezka: 1, tiktok: 1, google_ai: 1,
	google_play: 1, google_meet: 1, hodca: 1, discord: 1, meta: 1, twitter: 1,
	cloudflare: 1, cloudfront: 1, digitalocean: 1, hetzner: 1, ovh: 1, telegram: 1, roblox: 1
};

let rule_sets = [];
let comm_tags = [];
for (let c in communities) {
	if (!VALID_COMMUNITY[c])
		continue;
	let tag = 'comm-' + c;
	push(rule_sets, {
		type: 'remote',
		tag: tag,
		format: 'binary',
		url: SRS_BASE + '/' + c + '.srs',
		// download_detour: route rule-set downloads via the "direct" outbound (so SRS
		// fetches don't loop through the proxy before it's up). VERIFIED working on the
		// targeted sing-box 1.12.25 (rule-sets download, build ok). It is DEPRECATED from
		// 1.14 (replacement: route-level rule_set download via `http_client`) and slated
		// for REMOVAL in 1.16 — but that replacement does NOT exist before 1.14, so we must
		// keep download_detour while targeting 1.12.x. MIGRATION GATE: when the package
		// bumps sing-box to >=1.14, switch to the http_client form and re-verify on that
		// build; do NOT change it earlier or rule-set downloads break on the current target.
		download_detour: 'direct',
		update_interval: '24h'
	});
	push(comm_tags, tag);
}

// collect node tags
let node_tags = [];
for (let n in nodes)
	push(node_tags, n.tag);

// auto-pool members: which node tags take part in urltest auto-switching.
// Empty / unset => ALL nodes (default; new nodes auto-join). When a non-empty
// subset is configured, only those nodes are auto-switched (the rest stay
// available for manual selection via the "proxy" selector). Filtered to tags
// that still exist; if the filter leaves nothing (e.g. tags changed after a
// subscription update) we fall back to all nodes so urltest is never empty.
let auto_member = uci.get('vpnpool', 'main', 'auto_member') ?? [];
if (type(auto_member) != 'array')
	auto_member = [auto_member];
let member_set = {};
for (let m in auto_member)
	if (length(m)) member_set[m] = 1;

let auto_tags = [];
if (length(auto_member)) {
	for (let t in node_tags)
		if (member_set[t]) push(auto_tags, t);
}
if (!length(auto_tags))
	auto_tags = node_tags;                               // default / fallback: all nodes

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

// Node-quality filter (nodecheck.sh writes .dead_tags.json): drop nodes that the
// e2e probe found unable to reach ANY real endpoint for a sustained run — they TCP-
// ping (and may even pass the single cp.cloudflare urltest probe) but carry no real
// traffic (expired-sub placeholders, over-quota / service-blocked exits). They stay
// in node_tags (manually selectable) but leave the auto/urltest pool. Never empty it.
let dead_raw = (opt('main', 'dead_filter', '1') != '0') ? readfile('/tmp/vpnpool/.dead_tags.json') : null;
if (dead_raw) {
	let dead = json(dead_raw);
	if (type(dead) == 'array' && length(dead)) {
		let dead_set = {};
		for (let t in dead)
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

// manual override selector. Default depends on auto_switch + a persisted manual
// pick (so a chosen node survives reload/subscription updates if it still exists).
let auto_switch = opt('main', 'auto_switch', '1');
let selected    = opt('main', 'selected_node', '');

let sel = [ 'auto' ];
let sel_exists = false;
for (let t in node_tags) {
	push(sel, t);
	if (t == selected) sel_exists = true;
}

let def;
if (length(selected) && sel_exists)
	def = selected;                                  // honor persisted manual pick
else if (auto_switch == '0')
	def = length(node_tags) ? node_tags[0] : 'auto'; // off -> fixed node, no auto-switch
else
	def = 'auto';                                    // on -> urltest auto + failover

push(outbounds, {
	type: 'selector',
	tag: 'proxy',
	outbounds: sel,
	default: def,
	interrupt_exist_connections: true
});

// the actual node outbounds (anti-DPI is applied as a route rule action below,
// not as an outbound field — sing-box only exposes tls_fragment via route-options).
for (let n in nodes)
	push(outbounds, n);

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

// ---- inbound (tproxy) ----
// NOTE: omit "network" so tproxy listens on BOTH tcp and udp. The field is a
// single enum ("tcp"|"udp"); "tcp,udp" is invalid and fails sing-box check.
let test_port = int(opt('main', 'test_port', 1605));
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
config.inbounds = inbounds;

printf("%.J\n", config);
