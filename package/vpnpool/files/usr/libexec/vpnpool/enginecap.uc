#!/usr/bin/ucode
// vpnpool: which sing-box engine runs the config, and what it can do (ROADMAP 4.1).
//   ucode enginecap.uc cap <binary> [--force]   {bin, present, sig, version, major, minor, awg}
//   ucode enginecap.uc select <0|1>             the binary to build/run with for a pool without /
//                                               with AmneziaWG nodes: the cap above + reason
//                                               (null | engine_missing | engine_no_awg) + explicit
//   ucode enginecap.uc refresh                  re-measure every known binary (after engine.sh)
// The logic lives in common.uc (engine_cap / engine_select): status.uc and api.uc use it inline.
// One JSON object on stdout, exit 0 (select: exit 0 even when AWG can't run — the reason says it).
'use strict';

import { cursor } from 'uci';
import { SB_STOCK, SB_AWG, engine_cap, engine_select } from './common.uc';

let cmd = ARGV[0];
if (cmd == 'cap' && length(ARGV[1])) {
	printf('%J\n', engine_cap(ARGV[1], ARGV[2] == '--force'));
} else if (cmd == 'select') {
	let cfg = cursor().get('vpnpool', 'main', 'singbox_bin');
	printf('%J\n', engine_select(cfg, ARGV[1] == '1'));
} else if (cmd == 'refresh') {
	let cfg = cursor().get('vpnpool', 'main', 'singbox_bin');
	let out = {};
	for (let b in [ SB_STOCK, SB_AWG, cfg ])
		if (type(b) == 'string' && length(b)) out[b] = engine_cap(b, true);
	printf('%J\n', out);
} else {
	warn('usage: enginecap.uc cap <binary> [--force] | select <0|1> | refresh\n');
	exit(2);
}
