#!/bin/sh
# Stand UI init: wire rpcd backend + seed config (as in the base entrypoint), set a known
# root password so LuCI login works, then start ubusd + rpcd + uhttpd (with /ubus + cgi)
# so the REAL shipped dashboard is reachable over HTTP for user-interaction tests.
set -e
mkdir -p /var/lock /var/run/ubus /usr/libexec/rpcd /etc/vpnpool /tmp/vpnpool /etc/config /www/cgi-bin

[ -e /stage/rpcd/vpnpool ] && ln -sf /stage/rpcd/vpnpool /usr/libexec/rpcd/vpnpool
[ -f /etc/config/vpnpool ] || cp /work/fixtures/etc-config-vpnpool /etc/config/vpnpool
[ -f /etc/config/network ] || printf "config interface 'lan'\n\toption device 'br-lan'\n" > /etc/config/network

# Known root password for LuCI login (stand-only): root / vpnpool
if command -v openssl >/dev/null 2>&1; then
  HASH=$(openssl passwd -1 vpnpool 2>/dev/null)
  [ -n "$HASH" ] && awk -v h="$HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' /etc/shadow > /tmp/shadow && cp /tmp/shadow /etc/shadow
fi

# Stub the "system" ubus object (normally provided by procd, which doesn't run here).
# LuCI's chrome calls `system board`/`system info` to render the header — without it the
# dispatcher null-derefs (HTTP 500). This stand-only rpcd plugin satisfies that.
cat > /usr/libexec/rpcd/system <<'PLUGIN'
#!/bin/sh
case "$1" in
  list) echo '{ "board": {}, "info": {} }' ;;
  call)
    read -r input
    case "$2" in
      board) echo '{"kernel":"5.15.0","hostname":"vpnpool-stand","system":"x86_64","model":"vpnpool stand","board_name":"stand","release":{"distribution":"OpenWrt","version":"23.05.5","revision":"stand","target":"x86/64","description":"OpenWrt 23.05.5 stand"}}' ;;
      info) echo '{"localtime":0,"uptime":1000,"load":[0,0,0],"memory":{"total":536870912,"free":268435456,"shared":0,"buffered":0,"available":268435456},"swap":{"total":0,"free":0}}' ;;
      *) echo '{}' ;;
    esac ;;
esac
PLUGIN
chmod +x /usr/libexec/rpcd/system

# Bus + rpcd (genuine ubus). rpcd serves both LuCI's session/acl methods and vpnpool.
pgrep -x ubusd >/dev/null 2>&1 || ubusd &
i=0; while [ ! -S /var/run/ubus/ubus.sock ] && [ ! -S /var/run/ubus.sock ] && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
pgrep -x rpcd >/dev/null 2>&1 || rpcd &
sleep 1

# uhttpd: serve /www, LuCI cgi at /cgi-bin/luci, ubus bridge at /ubus (uhttpd-mod-ubus).
pgrep -x uhttpd >/dev/null 2>&1 || \
  uhttpd -f -h /www -r vpnpool-stand -x /cgi-bin -u /ubus -t 60 -T 30 -p 0.0.0.0:80 &

echo "stand-ui: up — http://localhost:8080/  (login root / vpnpool)" >&2
exec "$@"
