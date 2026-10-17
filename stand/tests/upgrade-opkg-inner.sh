#!/bin/sh
# Inside the 24.10 stand container (started by upgrade-opkg-test.sh). See there.
P=0; F=0
ok()  { P=$((P+1)); echo "ok   - $1"; }
bad() { F=$((F+1)); echo "FAIL - $1"; }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
command -v opkg >/dev/null || { echo "UPGRADE: passed=0 failed=1 (no opkg in this image)"; exit 1; }

W=/tmp/upg; rm -rf "$W"; mkdir -p "$W" /etc/vpnpool /tmp/vpnpool /var/run
LOG=$W/calls.log; : > "$LOG"
FX=/repo/stand/tests/fixtures/migrate/141
cp "$FX/etc-config-vpnpool" /etc/config/vpnpool
for f in links.json saved.map.json snapshot.map.json imported.map.json; do cp "$FX/$f" /etc/vpnpool/; done

# the package scripts, as package-pack.mk writes them (header + the Makefile body without #!/bin/sh)
HDR_POST='#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@'
HDR_PRERM='#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@'
HDR_PRE='#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh'
mkfn() {   # <Makefile> <name> -> the define body without its first line, $$ -> $
	awk -v n="define Package/vpnpool/$2" '$0 == n {on=1; next} on && $0 == "endef" {exit} on' "$1" | sed '1d; s/\$\$/$/g'
}
# 1.4.1 (package/vpnpool/Makefile of v1.4.1: no preinst; postinst = enable; prerm = stop + disable)
OLD_POST='[ -n "${IPKG_INSTROOT}" ] || {
	mkdir -p /etc/vpnpool
	/etc/init.d/vpnpool enable >/dev/null 2>&1
}
exit 0'
OLD_PRERM='[ -n "${IPKG_INSTROOT}" ] || {
	/etc/init.d/vpnpool stop >/dev/null 2>&1
	/etc/init.d/vpnpool disable >/dev/null 2>&1
}
exit 0'
MK=/repo/package/vpnpool/Makefile
[ -n "$(mkfn "$MK" postinst)" ] || { echo "UPGRADE: passed=0 failed=1 (no postinst in the Makefile)"; exit 1; }

# a stub init script: every call logged with the config's schema at that moment and whether the
# stand-in daemon still runs; "stop" stops it, "start" starts a new one
cat > "$W/init" <<'EOF'
#!/bin/sh
p=$(cat /var/run/vpnpool.pid 2>/dev/null); alive=no
[ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=yes
echo "init $1 schema=$(uci -q get vpnpool.main.schema) daemon=$alive" >> /tmp/upg/calls.log
case "$1" in
	stop) [ "$alive" = yes ] && kill "$p"; rm -f /var/run/vpnpool.pid ;;
	start) sleep 1000 & echo $! > /var/run/vpnpool.pid ;;
	enabled) exit 0 ;;
esac
exit 0
EOF

mkipk() {   # <dir> <version> <with uci-defaults 0|1> <preinst|-> <postinst> <prerm>
	d=$1; rm -rf "$d"; mkdir -p "$d/data/etc/init.d" "$d/ctl"
	cp "$W/init" "$d/data/etc/init.d/vpnpool"; chmod 755 "$d/data/etc/init.d/vpnpool"
	if [ "$3" = 1 ]; then mkdir -p "$d/data/etc/uci-defaults"; cp /repo/package/vpnpool/files/etc/uci-defaults/90-vpnpool-2.0 "$d/data/etc/uci-defaults/"; fi
	printf 'Package: vpnpool\nVersion: %s\nArchitecture: all\nInstalled-Size: 1\nDescription: upgrade test\n' "$2" > "$d/ctl/control"
	[ "$4" != - ] && { printf '%s\n%s\n' "$HDR_PRE" "$4" > "$d/ctl/preinst"; }
	printf '%s\n%s\n' "$HDR_POST" "$5" > "$d/ctl/postinst"
	printf '%s\n%s\n' "$HDR_PRERM" "$6" > "$d/ctl/prerm"
	chmod 755 "$d"/ctl/*
	( cd "$d/data" && tar -czf ../data.tar.gz . ) && ( cd "$d/ctl" && tar -czf ../control.tar.gz . ) && echo 2.0 > "$d/debian-binary"
	( cd "$d" && tar -czf "$d.ipk" ./debian-binary ./data.tar.gz ./control.tar.gz )
}
mkipk "$W/old" 1.4.1-1 0 - "$OLD_POST" "$OLD_PRERM"
PRE=$(mkfn "$MK" preinst); [ -n "$PRE" ] || PRE=-
mkipk "$W/new" 2.0.0-1 1 "$PRE" "$(mkfn "$MK" postinst)" "$(mkfn "$MK" prerm)"

opkg install "$W/old.ipk" > "$W/opkg1.out" 2>&1; R1=$?
check "control: the 1.4.1 package installs (rc $R1)" [ "$R1" -eq 0 ]
/etc/init.d/vpnpool start                                   # the 1.x daemon runs
: > "$LOG"
check "control: the stand-in 1.x daemon runs" sh -c 'kill -0 "$(cat /var/run/vpnpool.pid)"'
opkg install "$W/new.ipk" > "$W/opkg2.out" 2>&1; R2=$?
echo "--- package script calls during the upgrade:"; cat "$LOG"
check "the 2.0 package upgrades it (rc $R2)" [ "$R2" -eq 0 ]
check "migrated (schema 2)" [ "$(uci -q get vpnpool.main.schema)" = 2 ]
first=$(head -n1 "$LOG")
check "the 1.x daemon is stopped while the config is still 1.x (first call: $first)" \
	sh -c 'head -n1 "$1" | grep -qx "init stop schema= daemon=yes"' _ "$LOG"
check "the old package's prerm stopped it (opkg runs it on an upgrade)" sh -c 'grep -q "^init disable schema= " "$1"' _ "$LOG"
check "the call right before the first one on the migrated config sees no daemon" \
	sh -c 'awk "/schema=2/ {print prev; exit} {prev=\$0}" "$1" | grep -q "daemon=no"' _ "$LOG"
check "the service is started again after the migration" sh -c 'grep -q "^init start schema=2 daemon=no" "$1"' _ "$LOG"
check "the uci-defaults file is gone (it exited 0)" [ ! -e /etc/uci-defaults/90-vpnpool-2.0 ]
kill "$(cat /var/run/vpnpool.pid 2>/dev/null)" 2>/dev/null
echo "UPGRADE: passed=$P failed=$F"
[ "$F" -eq 0 ]
