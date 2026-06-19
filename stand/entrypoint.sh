#!/bin/sh
# Stand init: wire the rpcd backend, seed uci config, start ubusd+rpcd for real ubus calls.
mkdir -p /var/lock /var/run/ubus /usr/libexec/rpcd /etc/vpnpool /tmp/vpnpool /etc/config

# The luci-app rpcd backend is mounted read-only at /stage/rpcd; symlink it into the real
# rpcd plugin dir (symlink target stays RO, so it can't be edited in the container).
[ -e /stage/rpcd/vpnpool ] && ln -sf /stage/rpcd/vpnpool /usr/libexec/rpcd/vpnpool

# Seed the uci config (writable) from the fixture on first boot. uci needs to write here,
# so it is a normal file in the writable layer, NOT a read-only bind.
[ -f /etc/config/vpnpool ] || cp /work/fixtures/etc-config-vpnpool /etc/config/vpnpool
# Minimal network stub so lib.sh LAN auto-detect stays quiet (it falls back to br-lan anyway).
[ -f /etc/config/network ] || printf "config interface 'lan'\n\toption device 'br-lan'\n" > /etc/config/network

# Real ubus + rpcd so `ubus call vpnpool <m>` works against the genuine bus (the direct
# `/usr/libexec/rpcd/vpnpool call <m>` path also works without these).
pgrep -x ubusd >/dev/null 2>&1 || ubusd &
i=0; while [ ! -S /var/run/ubus/ubus.sock ] && [ ! -S /var/run/ubus.sock ] && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
pgrep -x rpcd >/dev/null 2>&1 || rpcd &

exec "$@"
