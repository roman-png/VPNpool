#!/usr/bin/ucode
// vpnpool sing-box config generator.
// Input : nodes JSON (array of vless outbounds from parser.uc) as ARGV[0].
//         Settings are read from uci 'vpnpool'.
// Output: full sing-box config for OUR second instance, on stdout.
//
// Design (coexists with podkop, see PLAN.md):
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
let clash_api   = opt('main', 'clash_api', '192.168.10.1:9091');
let health_url  = opt('main', 'health_url', 'http://cp.cloudflare.com/generate_204');
let fo_interval = opt('main', 'failover_interval', '60');
let fo_tol      = int(opt('main', 'failover_tolerance', 50));
let log_level   = opt('main', 'log_level', 'warn');

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
		download_detour: 'direct',
		update_interval: '24h'
	});
	push(comm_tags, tag);
}

// collect node tags
let node_tags = [];
for (let n in nodes)
	push(node_tags, n.tag);

// ---- outbounds ----
let outbounds = [];

// auto-ping + auto-switch group
push(outbounds, {
	type: 'urltest',
	tag: 'auto',
	outbounds: node_tags,
	url: health_url,
	interval: fo_interval + 's',
	tolerance: fo_tol,
	interrupt_exist_connections: true
});

// manual override selector (default = auto)
let sel = [ 'auto' ];
for (let t in node_tags)
	push(sel, t);
push(outbounds, {
	type: 'selector',
	tag: 'proxy',
	outbounds: sel,
	default: 'auto',
	interrupt_exist_connections: true
});

// the actual node outbounds
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
if (length(comm_tags))
	push(rules, { rule_set: comm_tags, outbound: listed_ob });
if (length(domains))
	push(rules, { domain_suffix: domains, outbound: listed_ob });

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
let inbounds = [ {
	type: 'tproxy',
	tag: 'tproxy-in',
	listen: '127.0.0.1',
	listen_port: tproxy_port
} ];

// ---- assemble ----
let config = {
	log: { level: log_level, timestamp: true },
	inbounds: inbounds,
	outbounds: outbounds,
	route: route,
	experimental: {
		clash_api: { external_controller: clash_api },
		cache_file: { enabled: true, path: '/etc/vpnpool/cache.db' }
	}
};

printf("%.J\n", config);
