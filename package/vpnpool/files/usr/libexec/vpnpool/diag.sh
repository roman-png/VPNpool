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
SBPID=$(pgrep -f 'sing-box run -c /etc/vpnpool/sing-box.json' | head -1)
CLASH=$(uci -q get vpnpool.main.clash_api); [ -n "$CLASH" ] || CLASH=192.168.10.1:9091
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

SBVER=$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')
LOGS=$(logread 2>/dev/null | grep 'vpnpool:' | tail -40 | sed 's/^\(.\{15\}\).*vpnpool: /\1 /' | jq -R . | jq -s . 2>/dev/null)
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
	--argjson logs "$LOGS" \
	'{
		service: { enabled: ($enabled==1), running: $running, routing: $routing,
		           autostart: $autostart, singbox_pid: $sbpid, clash_api_ok: $clash_ok },
		coexist: { podkop_running: $pod_run, podkop_table: $pod_tbl, zapret_table: $zap_tbl },
		network: { wan_iface: $wan, gateway: $gw, internet: $inet,
		           direct_ip: $dip, direct_country: $dco },
		resources: { fwmark: $fwmark, route_table: $rttab, tproxy_port: $tport, clash_api: $clash, singbox_version: $sbver },
		logs: $logs
	}'
