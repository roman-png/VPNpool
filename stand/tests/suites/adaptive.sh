# suite: adaptive — adaptive.sh routes domains that fail DIRECT but work via the proxy (sourced by run.sh)
# Known defect (ROADMAP 2.7): the host filter uses jq test() and OpenWrt's jq is built
# without oniguruma -> jq errors, HOSTS is empty, the script exits 0 having done nothing.

AD=/usr/libexec/vpnpool/adaptive.sh
FXA="$T_STATE/adaptive"; mkdir -p "$FXA"
cat > "$FXA/conn.json" <<'EOF'
{"connections":[
 {"metadata":{"host":"blocked.example.com"},"chains":["direct"]},
 {"metadata":{"host":"open.example.org"},"chains":["direct"]},
 {"metadata":{"host":"news.bbc.co.uk"},"chains":["direct"]},
 {"metadata":{"host":"1.2.3.4"},"chains":["direct"]},
 {"metadata":{"host":"already.proxied.net"},"chains":["Good1","auto","proxy"]}
]}
EOF
echo ok > "$FXA/ok.html"

adaptive_setup() {   # <adaptive_routing 0|1>
	reset_state
	uci set vpnpool.main.adaptive_routing="$1"; uci commit vpnpool
	mock_on
	mock_rule 'GET http://127.0.0.1:9091/connections' 200 "$FXA/conn.json"
	mock_rule 'P GET https://blocked.example.com/' 200 "$FXA/ok.html"
	mock_rule 'GET https://open.example.org/' 200 "$FXA/ok.html"
	mock_rule 'P GET https://news.bbc.co.uk/' 200 "$FXA/ok.html"
	# everything else (direct blocked.example.com / news.bbc.co.uk) -> 000 = blocked
}
autodom() { uci -q get vpnpool.routing.auto_domain | tr ' ' '\n' | grep -v '^$'; }

# ---- positive control: disabled => no clash query, nothing added ----
adaptive_setup 0
sh "$AD" >/dev/null 2>&1; ARC=$?
begin "adaptive/disabled-does-nothing"
expect_eq "exit code" "$ARC" 0
expect_eq "no /connections query" "$(mock_calls 'GET http://127.0.0.1:9091/connections')" 0
expect_eq "no auto_domain" "$(autodom | wc -l)" 0
end

# ---- blocked-direct host gets routed via the proxy; open and proxied hosts don't ----
adaptive_setup 1
sh "$AD" >/dev/null 2>&1; ARC=$?
begin "adaptive/blocked-direct-routed-via-proxy"
expect_eq "exit code" "$ARC" 0
expect_eq "clash /connections queried" "$(mock_calls 'GET http://127.0.0.1:9091/connections')" 1
expect_eq "example.com added" "$(autodom | gcount -x example.com)" 1
expect_eq "example.org NOT added (works direct)" "$(autodom | gcount -x example.org)" 0
expect_eq "proxied host not re-tested" "$(mock_calls 'already.proxied.net')" 0
expect_eq "bare IP host not tested" "$(mock_calls 'https://1.2.3.4/')" 0
expect_true "verdict cache written" jq -e '."blocked.example.com"=="proxy"' /etc/vpnpool/adaptive.cache.json
end 2.7

begin "adaptive/public-suffix-base-domain"
expect_eq "bbc.co.uk added" "$(autodom | gcount -x bbc.co.uk)" 1
expect_eq "co.uk NOT added" "$(autodom | gcount -x co.uk)" 0
end 2.7
