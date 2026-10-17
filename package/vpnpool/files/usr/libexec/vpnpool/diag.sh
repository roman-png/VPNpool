#!/bin/sh
# vpnpool: emit a JSON diagnostics snapshot for the Diagnostics tab.
# service/sing-box state, coexistence with podkop/zapret, routing artifacts,
# direct egress (ISP) IP/country, sing-box version, and recent log lines.
. /usr/libexec/vpnpool/lib.sh

bool() { [ "$1" = "0" ] && echo false || echo true; }

EN=$(uci -q get vpnpool.main.enabled); [ -n "$EN" ] || EN=0
RUN=false; pgrep -f '/usr/libexec/vpnpool/vpnpoold' >/dev/null 2>&1 && RUN=true
ROUT=false; nft list table inet vpnpool >/dev/null 2>&1 && ROUT=true
AUTOSTART=false; [ -n "$(ls /etc/rc.d/S*vpnpool 2>/dev/null)" ] && AUTOSTART=true
SBPID=$(our_singbox_pids | head -1)
CLASH=$(uci -q get vpnpool.main.clash_api); [ -n "$CLASH" ] || CLASH=127.0.0.1:9091
CLASH_OK=false; [ "$RUN" = true ] && curl -s -m3 "http://$CLASH/version" >/dev/null 2>&1 && CLASH_OK=true

POD_RUN=false; pgrep -f 'sing-box run -c /etc/sing-box/config.json' >/dev/null 2>&1 && POD_RUN=true
POD_TBL=false; nft list table inet PodkopTable >/dev/null 2>&1 && POD_TBL=true
ZAP_TBL=false; nft list table inet zapret2 >/dev/null 2>&1 && ZAP_TBL=true

WAN=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
INET=false; ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && INET=true

DJSON=$(curl -s -m6 https://ifconfig.co/json 2>/dev/null)
DIP=$(echo "$DJSON" | jq -r '.ip // ""' 2>/dev/null)
DCO=$(echo "$DJSON" | jq -r '.country_iso // .country // ""' 2>/dev/null)

# the engine that runs (or will run) the config (lib.sh sb_bin); `version -n` = the version only
SBVER=$("$(sb_bin)" version -n 2>/dev/null | head -1)
COMM_N=$(uci -q get vpnpool.routing.community | tr ' ' '\n' | grep -c .)
CACHE=false; CACHE_KB=0
if [ -f /tmp/vpnpool/cache.db ]; then CACHE=true; CACHE_KB=$(( $(wc -c < /tmp/vpnpool/cache.db) / 1024 )); fi
LOGS=$(log_lines service 40 | jq -R . | jq -s . 2>/dev/null)

# Technical parameters (read-only, shown only on the Diagnostics page): ports, marks and tables
# the routing uses (they must not collide with podkop / other services), the engine binary and
# limits that have no field on the settings pages.
uopt() { uci -q get "vpnpool.main.$1"; }
PARAMS=$(jq -nc \
	--arg tproxy "$TPROXY_PORT" --arg test "$(uopt test_port)" --arg ntest "$(uopt node_test_port)" \
	--arg fwmark "$FWMARK" --arg table "$RT_TABLE" --arg prio "$RT_PRIO" --arg clash "$CLASH" \
	--arg lan "$LAN_IF" --arg lan_cfg "$(uopt lan_if)" --arg coexist "$COEXIST" \
	--arg dns "$(uopt dns_strategy)" --arg health "$(uopt health_url)" \
	--arg fetchkb "$(uopt fetch_max_kb)" --arg memkb "$(uopt speedtest_min_mem_kb)" \
	--arg conc "$(uopt prefilter_concurrency)" --arg amax "$(uopt adaptive_max_per_run)" \
	--arg sbcfg "$(uopt singbox_bin)" --arg loglevel "$(uopt log_level)" --arg ua "$(uopt probe_ua)" \
	'def v($x; $d): if $x == "" then $d else $x end;
	{tproxy_port: $tproxy, test_port: v($test; "1605"), node_test_port: v($ntest; "1606"),
	 fwmark: $fwmark, route_table: $table, route_priority: $prio, clash_api: $clash,
	 lan_if: $lan, lan_if_auto: ($lan_cfg == ""), coexist: $coexist,
	 dns_strategy: v($dns; "prefer_ipv4"), health_url: $health,
	 fetch_max_kb: v($fetchkb; "2048"), speedtest_min_mem_kb: v($memkb; "8192"),
	 prefilter_concurrency: v($conc; "16"), adaptive_max_per_run: v($amax; "8"),
	 singbox_bin: $sbcfg, log_level: v($loglevel; "warn"), probe_ua: $ua}' 2>/dev/null)
[ -n "$PARAMS" ] || PARAMS='{}'

# The engine (sing-box): the binary that runs the config, its version and AmneziaWG support
# (enginecap.uc, cached by mtime:size), the AmneziaWG build if installed (its record from
# engine.sh) and the version this package pins for it (an update is due when they differ).
ECAP=/usr/libexec/vpnpool/enginecap.uc
SB_AWG_BIN=${VPNPOOL_SB_AWG:-/usr/bin/sing-box-awg}
PINNED=$(sed -n 's/^ENGINE_PINNED="\([^"]*\)".*/\1/p' /usr/libexec/vpnpool/engine.sh 2>/dev/null | head -1)
ENGINE=$(jq -nc --argjson run "$(ucode "$ECAP" cap "$(sb_bin)" 2>/dev/null || echo null)" \
	--argjson awgb "$(ucode "$ECAP" cap "$SB_AWG_BIN" 2>/dev/null || echo null)" \
	--argjson rec "$(jq -c . /etc/vpnpool/awg-engine.json 2>/dev/null || echo null)" \
	--arg pinned "$PINNED" \
	'{bin: ($run.bin // null), version: ($run.version // null), present: ($run.present // false),
	  awg: ($run.awg // false), awg31: ($run.awg31 // false),
	  awg_engine: {path: ($awgb.bin // null), installed: ($awgb.present // false), version: ($awgb.version // null),
	               awg: ($awgb.awg // false), awg31: ($awgb.awg31 // false),
	               ram: (if ($rec | type) == "object" then ($rec.ram // false) else null end),
	               installed_at: (if ($rec | type) == "object" then ($rec.installed_at // null) else null end)},
	  target_version: (if $pinned == "" then null else $pinned end),
	  update_available: (($awgb.present // false) and $pinned != "" and ($awgb.version // "") != $pinned)}' 2>/dev/null)
[ -n "$ENGINE" ] || ENGINE=null
[ -n "$LOGS" ] || LOGS='[]'

jq -n \
	--argjson enabled "${EN:-0}" \
	--argjson running "$RUN" \
	--argjson routing "$ROUT" \
	--argjson autostart "$AUTOSTART" \
	--arg sbpid "$SBPID" \
	--argjson clash_ok "$CLASH_OK" \
	--argjson pod_run "$POD_RUN" \
	--argjson pod_tbl "$POD_TBL" \
	--argjson zap_tbl "$ZAP_TBL" \
	--arg wan "$WAN" \
	--arg gw "$GW" \
	--argjson inet "$INET" \
	--arg dip "$DIP" \
	--arg dco "$DCO" \
	--arg sbver "$SBVER" \
	--arg fwmark "$FWMARK" \
	--arg rttab "$RT_TABLE" \
	--arg tport "$TPROXY_PORT" \
	--arg clash "$CLASH" \
	--argjson comm_n "${COMM_N:-0}" \
	--argjson cache "$CACHE" \
	--argjson cache_kb "${CACHE_KB:-0}" \
	--argjson logs "$LOGS" \
	--argjson params "$PARAMS" \
	--argjson engine "$ENGINE" \
	'{
		service: { enabled: ($enabled==1), running: $running, routing: $routing,
		           autostart: $autostart, singbox_pid: $sbpid, clash_api_ok: $clash_ok },
		coexist: { podkop_running: $pod_run, podkop_table: $pod_tbl, zapret_table: $zap_tbl },
		network: { wan_iface: $wan, gateway: $gw, internet: $inet,
		           direct_ip: $dip, direct_country: $dco },
		rulesets: { communities: $comm_n, cache_present: $cache, cache_kb: $cache_kb },
		resources: { fwmark: $fwmark, route_table: $rttab, tproxy_port: $tport, clash_api: $clash, singbox_version: $sbver },
		params: $params,
		engine: $engine,
		logs: $logs
	}'
