#!/bin/sh
# vpnpool: migrate a 1.x configuration to the 2.0 data model (ROADMAP 9.7; the mapping is in
# migrate.uc). Idempotent: a config already on schema 2 is left alone at once (one uci read), so
# every caller may simply run it:
#   /etc/uci-defaults/90-vpnpool-2.0   at package install / upgrade (opkg AND apk: the package's
#                                      postinst runs default_postinst, which runs the package's
#                                      uci-defaults files) and at the first boot of an image;
#   /etc/init.d/vpnpool start          a safety net (a config restored by sysupgrade, ...);
#   rpcd restore / import              a 1.x backup or export put back on 2.0.
# Before ANY change a backup in the stage-3 format (the files of rpcd backup: the config, the AWG
# files, the *.map.json maps — restorable from the UI) goes to /etc/vpnpool/backup-1.x/ (the first
# one is kept; links.json, sub.expire, sub.usage are copied next to it), and is verified; without
# it nothing is changed. Journal: /etc/vpnpool/migrate.log (+ syslog); report: migration.json.
# Exit: 0 migrated or nothing to do; 1 failed (nothing committed — the next run tries again).
. /usr/libexec/vpnpool/lib.sh

LOGF="$CONF_DIR/migrate.log"
BKDIR="$CONF_DIR/backup-1.x"
journal() { mkdir -p "$CONF_DIR"; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGF"; log "migrate: $*"; }

[ "$(uci -q get vpnpool.main.schema)" = 2 ] && exit 0
[ "$(uci -q get vpnpool.main)" = vpnpool ] || exit 0   # no vpnpool config at all: nothing to migrate

# single flight (init.d and the package scripts may meet)
mkdir -p "$SB_DATA"
LOCK="$SB_DATA/.migrate.lock"
clear_stale_lock "$LOCK" 300
if ! ( set -C; echo $$ > "$LOCK" ) 2>/dev/null; then journal "another migration is running — skipped"; exit 1; fi
trap 'rm -f "$LOCK"' EXIT INT TERM
[ "$(uci -q get vpnpool.main.schema)" = 2 ] && exit 0

journal "start: 1.x configuration -> 2.0"
mkdir -p "$BKDIR"; chmod 700 "$BKDIR" 2>/dev/null
BK=$(ls "$BKDIR"/vpnpool-1.x-*.tar.gz 2>/dev/null | head -n1)
if [ -z "$BK" ] || ! tar -tzf "$BK" >/dev/null 2>&1; then
	BK="$BKDIR/vpnpool-1.x-$(date +%Y%m%d-%H%M%S).tar.gz"
	# shellcheck disable=SC2046
	if ! { tar -czf "$BK.tmp" -C / $(backup_members) 2>/dev/null && tar -tzf "$BK.tmp" 2>/dev/null | grep -qx etc/config/vpnpool && mv -f "$BK.tmp" "$BK"; }; then
		rm -f "$BK.tmp"
		journal "FAILED: the backup could not be written — nothing changed"
		exit 1
	fi
	chmod 600 "$BK" 2>/dev/null
	for f in links.json sub.expire sub.usage; do
		[ -f "$CONF_DIR/$f" ] && cp "$CONF_DIR/$f" "$BKDIR/$f" 2>/dev/null
	done
	journal "backup: $BK"
else
	journal "backup kept from an earlier attempt: $BK"
fi

REP=$(ucode /usr/libexec/vpnpool/migrate.uc "$BK" 2>>"$LOGF"); rc=$?
if [ "$rc" -ne 0 ] || [ "$(printf '%s' "$REP" | jq -r '.to // ""' 2>/dev/null)" != 2 ]; then
	journal "FAILED (rc $rc): $(printf '%s' "$REP" | jq -c '{error}' 2>/dev/null) — the config is unchanged, the next start tries again"
	exit 1
fi
journal "done: $(printf '%s' "$REP" | jq -c '.moved' 2>/dev/null); not matched: $(printf '%s' "$REP" | jq -r '.unmatched | length' 2>/dev/null) (listed in migration.json)"
exit 0
