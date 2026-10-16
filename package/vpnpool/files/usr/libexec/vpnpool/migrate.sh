#!/bin/sh
# vpnpool: migrate a 1.x configuration to the 2.0 data model (ROADMAP 9.7; the mapping is in
# migrate.uc). Idempotent: a config already on schema 2 is left alone at once (one uci read), so
# every caller may simply run it:
#   /etc/uci-defaults/90-vpnpool-2.0   at package install / upgrade (opkg AND apk: the package's
#                                      postinst runs default_postinst, which runs the package's
#                                      uci-defaults files) and at the first boot of an image;
#   /etc/init.d/vpnpool start          a safety net (a config restored by sysupgrade, ...); it
#                                      does NOT start the daemon when this fails;
#   rpcd restore / import              a 1.x backup or export put back on 2.0 (a failure is
#                                      answered migration_failed and the state before comes back).
# Before ANY change a backup in the stage-3 format (the files of rpcd backup: the config, the AWG
# files, the *.map.json maps — restorable from the UI) goes to /etc/vpnpool/backup-1.x/ and is
# verified (links.json, sub.expire, sub.usage are copied next to it); without it nothing is
# changed. A backup is reused only from an attempt that did not finish (its .in-progress mark).
# The 1.x subscription cache (sources_cache/NNN.raw: 000 = subscription_url, then extra_sub in
# order) is copied to the subscriptions' own s-<key>.raw, so a subscription that does not answer
# the first fetch after the upgrade keeps its nodes.
# Journal: /etc/vpnpool/migrate.log (+ syslog); report: migration.json; a failure is recorded in
# RAM for status (/tmp/vpnpool/migration_failed.json {at, reason}).
# Exit: 0 migrated or nothing to do; 1 failed (nothing committed — the next run tries again).
. /usr/libexec/vpnpool/lib.sh

LOGF="$CONF_DIR/migrate.log"
BKDIR="$CONF_DIR/backup-1.x"
FAILF="$SB_DATA/migration_failed.json"
journal() { mkdir -p "$CONF_DIR"; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGF"; log "migrate: $*"; }
failed() {   # $1 = reason code, $2 = what the journal says
	journal "FAILED: $2"
	mkdir -p "$SB_DATA"
	jq -nc --arg r "$1" --argjson at "$(date +%s)" '{at:$at, reason:$r}' > "$FAILF" 2>/dev/null
	exit 1
}

if [ "$(uci -q get vpnpool.main.schema)" = 2 ]; then rm -f "$FAILF"; exit 0; fi
[ "$(uci -q get vpnpool.main)" = vpnpool ] || exit 0   # no vpnpool config at all: nothing to migrate

# single flight (init.d and the package scripts may meet): wait for the other run (up to 60 s)
# instead of going on with the 1.x config
mkdir -p "$SB_DATA"
LOCK="$SB_DATA/.migrate.lock"
i=0
while ! ( set -C; echo $$ > "$LOCK" ) 2>/dev/null; do
	clear_stale_lock "$LOCK" 300
	i=$((i + 1))
	[ "$i" -ge 60 ] && failed busy "another migration still runs after 60 s"
	sleep 1
done
trap 'rm -f "$LOCK"' EXIT INT TERM
if [ "$(uci -q get vpnpool.main.schema)" = 2 ]; then rm -f "$FAILF"; exit 0; fi   # the other run did it

journal "start: 1.x configuration -> 2.0"
mkdir -p "$BKDIR" 2>/dev/null; chmod 700 "$BKDIR" 2>/dev/null
BK=""
[ -f "$BKDIR/.in-progress" ] && BK=$(cat "$BKDIR/.in-progress" 2>/dev/null)
if [ -n "$BK" ] && [ -f "$BK" ] && tar -tzf "$BK" >/dev/null 2>&1; then
	journal "backup kept from the attempt that did not finish: $BK"
else
	BK="$BKDIR/vpnpool-1.x-$(date +%Y%m%d-%H%M%S).tar.gz"
	# shellcheck disable=SC2046
	if ! { tar -czf "$BK.tmp" -C / $(backup_members) 2>/dev/null && tar -tzf "$BK.tmp" 2>/dev/null | grep -qx etc/config/vpnpool && mv -f "$BK.tmp" "$BK"; }; then
		rm -f "$BK.tmp"
		failed backup_failed "the backup could not be written — nothing changed"
	fi
	chmod 600 "$BK" 2>/dev/null
	for f in links.json sub.expire sub.usage; do
		[ -f "$CONF_DIR/$f" ] && cp "$CONF_DIR/$f" "$BKDIR/$f" 2>/dev/null
	done
	echo "$BK" > "$BKDIR/.in-progress"
	journal "backup: $BK"
fi

# the 1.x cache -> the subscriptions' own cache (copies: the 1.x files stay until fetch drops them)
CACHE="$CONF_DIR/sources_cache"
n=0
for url in $(uci -q get vpnpool.main.subscription_url) $(uci -q get vpnpool.main.extra_sub); do
	f="$CACHE/$(printf '%03d' "$n").raw"; n=$((n + 1))
	[ -s "$f" ] || continue
	t="$CACHE/s-$(src_key "$url").raw"
	[ -s "$t" ] || { cp "$f" "$t.tmp" && mv -f "$t.tmp" "$t" && journal "cache: $(basename "$f") -> $(mask_url "$url")"; }
done

REP=$(VPNPOOL_DEFAULT_UAS="$DEFAULT_UAS" ucode /usr/libexec/vpnpool/migrate.uc "$BK" 2>>"$LOGF"); rc=$?
if [ "$rc" -ne 0 ] || [ "$(printf '%s' "$REP" | jq -r '.to // ""' 2>/dev/null)" != 2 ]; then
	failed "$(printf '%s' "$REP" | jq -r '.error // "migrate_error"' 2>/dev/null || echo migrate_error)" \
		"(rc $rc) $(printf '%s' "$REP" | jq -c '{error}' 2>/dev/null) — the config is unchanged, the next start tries again"
fi
rm -f "$BKDIR/.in-progress" "$FAILF"
journal "done: $(printf '%s' "$REP" | jq -c '.moved' 2>/dev/null); not matched: $(printf '%s' "$REP" | jq -r '.unmatched | length' 2>/dev/null) (listed in migration.json)"
exit 0
