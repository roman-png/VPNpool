# suite: status — status.sh cost on a 300-node pool (sourced by run.sh)
# Metrics: wall time and processes spawned per dashboard poll (kernel PID counter of the
# container's PID namespace). Target (ROADMAP 3.7): < 10 processes per poll; today ~100+.

ST=/usr/libexec/vpnpool/status.sh
U=9c5b7d60-86ba-4f6f-9f81-29e9afb0c5ce
FXS="$T_STATE/status"; mkdir -p "$FXS"

reset_state
i=1; : > "$FXS/links.txt"
while [ $i -le 300 ]; do
	printf 'vless://%s@10.%d.%d.%d:443?security=tls&sni=n%d.example#Node%03d\n' "$U" $((i / 250)) $((i % 250)) 7 "$i" "$i" >> "$FXS/links.txt"
	i=$((i + 1))
done
ucode /usr/libexec/vpnpool/parser.uc "$FXS/links.txt" > "$FXS/nodes.json"
jq '{proxies: ((map({key: .tag, value: {type: "VLESS", history: [{delay: 120}]}}) | from_entries)
	+ {proxy: {type: "Selector", now: "auto"}, auto: {type: "URLTest", now: "Node001"}})}' "$FXS/nodes.json" > "$FXS/proxies.json"
echo '{"uploadTotal":100,"downloadTotal":2000,"connections":[{"metadata":{"sourceIP":"192.168.1.10","host":"a.example"},"chains":["Node001","auto","proxy"],"upload":10,"download":20}]}' > "$FXS/conns.json"

# calibrate: what does reading the counter itself cost?
b=$(last_pid); a=$(last_pid); CAL=$((a - b))

measure_status() {   # -> SOUT, SSECS, SPROCS
	cp "$FXS/nodes.json" /tmp/vpnpool/nodes.json
	_b=$(last_pid); read _u0 _ < /proc/uptime        # `read` is a builtin: no extra process
	SOUT=$(sh "$ST" 2>/dev/null)
	read _u1 _ < /proc/uptime; _a=$(last_pid)
	_c0=$(echo "$_u0" | tr -d .); _c1=$(echo "$_u1" | tr -d .)   # centiseconds (outside the window)
	SSECS="$(( (_c1 - _c0) / 100 )).$(printf '%02d' $(( (_c1 - _c0) % 100 )))"; SPROCS=$((_a - _b - CAL))
}

# ---- daemon down ----
measure_status
begin "status/300-nodes-daemon-down-valid"
expect_jq "valid status object" "$SOUT" 'type=="object" and (.nodes|length)==300 and .running==false'
end
metric status_300_down_seconds "$SSECS"
metric status_300_down_processes "$SPROCS"
begin "status/300-nodes-daemon-down-under-10-processes"
expect_le "processes per poll" "$SPROCS" 9
end 3.7

# ---- daemon up (fake vpnpoold + mocked clash API) ----
daemon_start
mock_on
mock_rule 'GET http://127.0.0.1:9091/proxies' 200 "$FXS/proxies.json"
mock_rule 'GET http://127.0.0.1:9091/connections' 200 "$FXS/conns.json"
measure_status
begin "status/300-nodes-daemon-up-valid"
expect_jq "running + 300 nodes" "$SOUT" '.running==true and (.nodes|length)==300'
expect_jq "delay from clash history" "$SOUT" '(.nodes[0].delay)==120'
expect_jq "per-node traffic" "$SOUT" '(.nodes[] | select(.tag=="Node001") | .down)==20'
expect_jq "active node" "$SOUT" '.auto_now=="Node001"'
end
metric status_300_up_seconds "$SSECS"
metric status_300_up_processes "$SPROCS"
begin "status/300-nodes-daemon-up-under-10-processes"
expect_le "processes per poll" "$SPROCS" 9
end 3.7
# secrets: status must not hand the Telegram token to the browser (ROADMAP 3.5)
uci set vpnpool.main.telegram_token='123456:SECRET-BOT-TOKEN'; uci commit vpnpool
measure_status
begin "status/with-token-valid"   # positive control, outside the xfail below
expect_jq "status still valid" "$SOUT" '.settings|type=="object"'
end
begin "status/telegram-token-masked"
expect_eq "token occurrences in status" "$(printf '%s' "$SOUT" | gcount 'SECRET-BOT-TOKEN')" 0
end 3.5
daemon_stop
