# suite: migrate — the 1.x -> 2.0 data-model migration (ROADMAP 9.7; migrate.sh + migrate.uc),
# on the fixture of a used 1.4.1 router (stand/tests/fixtures/migrate/141: the 1.4.1 config shape
# with subscriptions, sources + imported nodes, saved / snapshot / active saved nodes, an excluded
# node, a hard pin AND a preferred node, auto-pool members, a force-kept node, unlock badges, an
# AWG file of 1.x and an unreadable one; made-up credentials, documentation addresses).

FXM="$T_DIR/fixtures/migrate/141"
MIG=/usr/libexec/vpnpool/migrate.sh
FXT="$T_STATE/migrate"; mkdir -p "$FXT"

mig_setup() {   # a 1.4.1 router: config + /etc/vpnpool + the RAM node list of the running 1.x
	reset_state
	cp "$FXM/etc-config-vpnpool" /etc/config/vpnpool
	mkdir -p /etc/vpnpool/awg /tmp/vpnpool
	for f in links.json saved.map.json snapshot.map.json imported.map.json unlock.map.json sub.expire sub.usage; do cp "$FXM/$f" /etc/vpnpool/; done
	cp "$FXM"/awg/*.conf /etc/vpnpool/awg/
	mkdir -p /etc/vpnpool/sources_cache; cp "$FXM"/sources_cache/*.raw /etc/vpnpool/sources_cache/
	cp "$FXM/nodes.json" /tmp/vpnpool/nodes.json
}
skey() { printf '%s' "$1" | md5sum | cut -c1-12; }
# everything of the config the migration must NOT touch: uci show minus the stores it moves (and
# minus what it adds) — the routing, ports, Telegram, schedule, clients, kill-switch ...
kept_cfg() { uci -q show vpnpool | grep -v -e '^vpnpool\.main\.\(subscription_url\|extra_sub\|source\|imported_node\|saved_node\|active_saved\|excluded_node\|selected_node\|subscription_ua\|singbox_config\|preferred_node\|auto_member\|keep_auto\|hidden\|manual_node\|schema\|probe_ua\)=' -e '^vpnpool\.sub_'; }
# id of a link / of a .conf, by the 2.0 parser (what every store must hold after the migration)
lid() { printf '%s\n' "$1" > "$FXT/one.links"; ucode /usr/libexec/vpnpool/parser.uc --with-id "$FXT/one.links" 2>/dev/null | jq -r '.[0].id // ""'; }
cid() { ucode /usr/libexec/vpnpool/parser.uc --with-id "$1" 2>/dev/null | jq -r '.[0].id // ""'; }
link_of_tag() { jq -r --arg t "$1" 'map(select(.tag == $t))[0].link' "$FXM/links.json"; }
subs_tsv() { ucode /usr/libexec/vpnpool/model.uc subs 2>/dev/null; }
L_DE=$(link_of_tag Sub-DE); L_NL=$(link_of_tag Sub-NL); L_NL2=$(link_of_tag 'Sub-NL #2')
L_FREE=$(link_of_tag Free-1); L_ORPH=$(link_of_tag Orphan-Import); L_OWN=$(link_of_tag My-Own); L_OLD=$(link_of_tag Old-Saved)
L_BAD='vless://11111111-2222-4333-8444-555555555507@203.0.113.17:443?security=tls&sni=sub.example#Sub-BAD'
ID_DE=$(lid "$L_DE"); ID_NL=$(lid "$L_NL"); ID_NL2=$(lid "$L_NL2"); ID_FREE=$(lid "$L_FREE"); ID_OLD=$(lid "$L_OLD")
ID_BAD=$(lid 'vless://11111111-2222-4333-8444-555555555507@203.0.113.17:443?security=tls&sni=sub.example#Sub-Bad')
ID_JSON=$(jq -c '[.[1]]' "$FXM/nodes.json" > "$FXT/j.json"; ucode /usr/libexec/vpnpool/parser.uc --with-id "$FXT/j.json" 2>/dev/null | jq -r '.[0].id')
ID_AWG=$(cid "$FXM/awg/0a1b2c3d4e5f.conf")
ID_ORPH=$(lid "$L_ORPH"); L_UCI='vless://11111111-2222-4333-8444-555555555511@203.0.113.21:443?security=tls&sni=sub.example#Only-In-Uci'; ID_UCI=$(lid "$L_UCI")

begin "migrate/fixture-is-a-1x-config"   # positive control: the fixture holds what is migrated
mig_setup
expect_eq "no schema" "$(uci -q get vpnpool.main.schema)" ''
expect_eq "1.x subscription option" "$(uci -q get vpnpool.main.subscription_url)" 'https://sub.example.com/sub/TOKENPRIMARY'
expect_eq "1.x hard pin by tag" "$(uci -q get vpnpool.main.selected_node)" 'Sub-NL #2'
expect_true "ids of the fixture's nodes computed ($ID_DE $ID_NL2 $ID_JSON $ID_AWG)" sh -c 'for i in "$@"; do [ ${#i} -eq 12 ] || exit 1; done' _ "$ID_DE" "$ID_NL" "$ID_NL2" "$ID_FREE" "$ID_OLD" "$ID_BAD" "$ID_JSON" "$ID_AWG"
expect_true "Sub-NL and Sub-NL #2 are different nodes" [ "$ID_NL" != "$ID_NL2" ]
end

mig_setup
cp /etc/config/vpnpool "$FXT/before.cfg"; kept_cfg > "$FXT/kept.before"
sh "$MIG" > "$FXT/run1.out" 2>&1; MRC=$?
MJ=$(cat /etc/vpnpool/migration.json 2>/dev/null)
begin "migrate/runs-and-journals"
expect_eq "exit code" "$MRC" 0
expect_eq "schema 2" "$(uci -q get vpnpool.main.schema)" 2
expect_true "journal: start, backup, done" sh -c 'grep -q "start: 1.x" "$1" && grep -q "backup: " "$1" && grep -q "done: " "$1"' _ /etc/vpnpool/migrate.log
expect_jq "report" "$MJ" '.from=="1.x" and .to=="2" and (.backup|startswith("/etc/vpnpool/backup-1.x/"))'
end

BK=$(ls /etc/vpnpool/backup-1.x/vpnpool-1.x-*.tar.gz 2>/dev/null | head -n1)
rm -rf "$FXT/bk"; mkdir -p "$FXT/bk"; tar -xzf "$BK" -C "$FXT/bk" 2>/dev/null
begin "migrate/backup-before-changes"
expect_true "the backup exists ($BK)" [ -s "$BK" ]
expect_true "it holds the 1.x config byte for byte" cmp -s "$FXT/bk/etc/config/vpnpool" "$FXT/before.cfg"
expect_true "... the 1.x maps and AWG files" sh -c '[ -s "$1/etc/vpnpool/saved.map.json" ] && [ -s "$1/etc/vpnpool/imported.map.json" ] && [ -f "$1/etc/vpnpool/awg/0a1b2c3d4e5f.conf" ]' _ "$FXT/bk"
expect_eq "every member follows the backup rule (restorable from the UI)" \
	"$(tar -tzf "$BK" | grep -vEc '^(etc/?|etc/config/?|etc/config/vpnpool|etc/vpnpool/?|etc/vpnpool/awg/?|etc/vpnpool/awg/[A-Za-z0-9._-]+\.conf|etc/vpnpool/[A-Za-z0-9._-]+\.map\.json)$')" 0
expect_true "links.json / sub.* copied next to it" sh -c '[ -s /etc/vpnpool/backup-1.x/links.json ] && [ -s /etc/vpnpool/backup-1.x/sub.expire ]'
expect_eq "owner-only" "$(ls -ln "$BK" | cut -c1-10)" -rw-------
end

begin "migrate/subscriptions-become-sections"
expect_eq "in 1.x order: primary, extra, the source with an import, the source without" "$(subs_tsv | cut -f2-4)" \
	"$(printf '1\tall\thttps://sub.example.com/sub/TOKENPRIMARY\n1\tall\thttps://extra.example.com/list/TOKENEXTRA\n1\tpick\thttps://free.example.org/list.txt\n0\tpick\thttps://empty.example.org/none.txt')"
_free=$(subs_tsv | awk -F'\t' '$4 ~ /free/ {print $1}')
expect_eq "the pick subscription takes the imported node by id" "$(uci -q get "vpnpool.$_free.pick")" "$ID_FREE"
expect_jq "the 1.x quota / expiry of the primary became its meta" "$(cat /etc/vpnpool/subs.meta.json)" \
	"(.[\"$(subs_tsv | head -n1 | cut -f1)\"] | .expire==1893456000 and .upload==100 and .download==200 and .total==1000000)"
end
FAV=$(cat /etc/vpnpool/favorites.map.json 2>/dev/null)
begin "migrate/imported-nodes-become-favourites-in-the-pool"
expect_eq "manual nodes: the user's own only" "$(uci -q get vpnpool.main.manual_node)" "$L_OWN"
expect_jq "both imports (the one of a source, the orphan): favourites WITH the link, in the pool" "$FAV" \
	".[\"$ID_FREE\"].link==\"$L_FREE\" and .[\"$ID_FREE\"].active==true and .[\"$ID_FREE\"].auto==false and .[\"$ID_ORPH\"].link==\"$L_ORPH\" and .[\"$ID_ORPH\"].active==true"
end
begin "migrate/saved-nodes-become-favourites"
expect_jq "saved (by hand), snapshot (automatic), active saved (in the pool from the archive) — by id with the link" "$FAV" \
	".[\"$ID_DE\"].auto==false and .[\"$ID_DE\"].active==false and .[\"$ID_DE\"].link==\"$L_DE\" and .[\"$ID_NL\"].auto==true and .[\"$ID_OLD\"].active==true and .[\"$ID_OLD\"].tag==\"Old-Saved\""
expect_jq "a saved_node link no map has: a favourite too, not dropped" "$FAV" ".[\"$ID_UCI\"].link==\"$L_UCI\" and .[\"$ID_UCI\"].active==false"
expect_jq "6 favourites in all" "$FAV" 'length==6'
expect_jq "with what the screens show" "$FAV" ".[\"$ID_DE\"].server==\"203.0.113.14\" and .[\"$ID_DE\"].type==\"vless\""
expect_eq "owner-only (links are credentials)" "$(ls -ln /etc/vpnpool/favorites.map.json | cut -c1-10)" -rw-------
end
begin "migrate/1x-cache-moves-to-the-subscriptions"
expect_true "000.raw -> the primary's own copy" cmp -s "/etc/vpnpool/sources_cache/s-$(skey 'https://sub.example.com/sub/TOKENPRIMARY').raw" "$FXM/sources_cache/000.raw"
expect_true "001.raw -> the first extra's own copy" cmp -s "/etc/vpnpool/sources_cache/s-$(skey 'https://extra.example.com/list/TOKENEXTRA').raw" "$FXM/sources_cache/001.raw"
end
begin "migrate/subscription-ua-first-in-the-client-list"
expect_eq "probe_ua" "$(uci -q get vpnpool.main.probe_ua | cut -d' ' -f1-2)" 'MyPanelClient/2.1 v2rayNG/1.9.5'
end
kept_cfg > "$FXT/kept.after"
begin "migrate/everything-else-byte-for-byte"
expect_true "control: the routing / ports / Telegram / schedule / clients are in it" sh -c 'grep -q "client_dev=" "$1" && grep -q "telegram_token=" "$1" && grep -q "sched_off=" "$1" && grep -q "auto_domain=" "$1" && grep -q "killswitch=.1" "$1" && [ $(wc -l < "$1") -ge 45 ]' _ "$FXT/kept.before"
expect_true "the same after the migration" cmp -s "$FXT/kept.before" "$FXT/kept.after"
end
begin "migrate/excluded-becomes-hidden"
expect_eq "hidden = the excluded node's id" "$(uci -q get vpnpool.main.hidden)" "$ID_BAD"
end
begin "migrate/hard-pin-becomes-the-preferred-node"
expect_eq "preferred = the id of 'Sub-NL #2' (the hard pin wins over the old preferred Sub-DE)" "$(uci -q get vpnpool.main.preferred_node)" "$ID_NL2"
expect_eq "no hard pin left" "$(uci -q get vpnpool.main.selected_node)" ''
end
begin "migrate/tag-stores-become-ids"
expect_eq "auto_member: Sub-DE, Sub-NL #2 (Ghost-Node unmatched)" "$(uci -q get vpnpool.main.auto_member)" "$ID_DE $ID_NL2"
expect_eq "keep_auto: Json-Node, known only from the running 1.x node list" "$(uci -q get vpnpool.main.keep_auto)" "$ID_JSON"
expect_jq "unlock badges by id" "$(cat /etc/vpnpool/unlock.map.json)" "keys==[\"$ID_DE\"] and .[\"$ID_DE\"].youtube==true"
end
begin "migrate/awg-files-renamed-with-their-name"
expect_true "<id>.conf" [ -f "/etc/vpnpool/awg/$ID_AWG.conf" ]
expect_true "the 1.x name is gone" [ ! -f /etc/vpnpool/awg/0a1b2c3d4e5f.conf ]
expect_eq "# Name = its 1.x name" "$(head -n1 "/etc/vpnpool/awg/$ID_AWG.conf")" '# Name = 198.51.100.61:443'
expect_eq "the same node" "$(cid "/etc/vpnpool/awg/$ID_AWG.conf")" "$ID_AWG"
expect_eq "owner-only" "$(ls -ln "/etc/vpnpool/awg/$ID_AWG.conf" | cut -c1-10)" -rw-------
expect_true "the unreadable file is left as it is" cmp -s /etc/vpnpool/awg/5f4e3d2c1b0a.conf "$FXM/awg/5f4e3d2c1b0a.conf"
end
begin "migrate/unmatched-kept-and-reported"
expect_jq "listed: the unknown tag of two stores, the unreadable AWG file" "$MJ" \
	'([.unmatched[] | .store + ":" + .value] | sort) == ["auto_member:Ghost-Node","awg_file:5f4e3d2c1b0a.conf","unlock:Ghost-Node"]'
rcall status
expect_jq "status shows them" "$R" '(.migration.unmatched|length)==3 and .migration.from=="1.x" and .migration.state=="done"'
end
begin "migrate/1x-leftovers-gone"
expect_eq "no 1.x option" "$(uci -q show vpnpool.main | gcount -e '\.subscription_url=' -e '\.extra_sub=' -e '\.source=' -e '\.imported_node=' -e '\.saved_node=' -e '\.active_saved=' -e '\.excluded_node=' -e '\.selected_node=' -e '\.subscription_ua=' -e '\.singbox_config=')" 0
expect_true "the 1.x maps / quota files gone" sh -c '! ls /etc/vpnpool/saved.map.json /etc/vpnpool/snapshot.map.json /etc/vpnpool/imported.map.json /etc/vpnpool/sub.expire /etc/vpnpool/sub.usage 2>/dev/null | grep -q .'
expect_eq "settings kept (positive control)" "$(uci -q get vpnpool.main.failover_interval) $(uci -q get vpnpool.routing.domain)" '60 example.org'
end

# a second run (the next boot / service start): nothing changes, no second backup
cp /etc/config/vpnpool "$FXT/after1.cfg"; cp /etc/vpnpool/favorites.map.json "$FXT/fav1.json"
sh "$MIG" > "$FXT/run2.out" 2>&1; MRC2=$?
begin "migrate/idempotent"
expect_eq "exit code" "$MRC2" 0
expect_true "config byte-identical" cmp -s /etc/config/vpnpool "$FXT/after1.cfg"
expect_true "favourites identical" cmp -s /etc/vpnpool/favorites.map.json "$FXT/fav1.json"
expect_eq "one backup" "$(ls /etc/vpnpool/backup-1.x/*.tar.gz | wc -l)" 1
expect_eq "the journal has no second start" "$(gcount 'start: 1.x' /etc/vpnpool/migrate.log)" 1
end

# the 2.0 pool from the migrated config: the primary's fetched copy + the user's nodes; the
# public list of the imported node does NOT answer (it never had a cache: 1.x did not fetch it)
mkdir -p /tmp/vpnpool/sources
printf '%s\n%s\n%s\n%s\n' "$L_DE" "$L_NL" "$L_NL2" 'vless://11111111-2222-4333-8444-555555555507@203.0.113.17:443?security=tls&sni=sub.example#Sub-Bad' \
	> "/tmp/vpnpool/sources/s-$(skey 'https://sub.example.com/sub/TOKENPRIMARY').raw"
mock_on
run_with_timeout 120 sh /usr/libexec/vpnpool/build.sh > "$FXT/build.out" 2>&1; BRC=$?
rcall status
begin "migrate/the-migrated-config-builds"
expect_eq "build.sh exit code" "$BRC" 0
expect_jq "the pool: the subscription (Sub-Bad hidden), the imports (their list is down), the user's nodes, the active favourite" \
	"$(cat /tmp/vpnpool/nodes.json)" 'map(.tag) | sort == (["Free-1","My-Own","Old-Saved","Orphan-Import","Sub-DE","Sub-NL","Sub-NL #2"] | sort)'
expect_jq "the import lives from its link (a favourite), not from the list" "$(cat /tmp/vpnpool/nodes.json)" 'map(select(.tag=="Free-1"))[0]._src=="fav"'
expect_jq "the AWG node under its new name waits for the engine (stock sing-box here)" "$(cat /tmp/vpnpool/deferred.json)" \
	"map(select(.id==\"$ID_AWG\"))[0] | .tag==\"198.51.100.61:443\" and .reason==\"engine_missing\""
expect_jq "the preferred node is 'Sub-NL #2' again" "$R" '.preferred.tag=="Sub-NL #2" and .preferred.in_pool==true and .settings.preferred_node=="Sub-NL #2"'
expect_jq "status: the hidden one by name, favourites, the subscriptions" "$R" \
	'(.hidden[0].tag=="Sub-Bad") and (.favorites|length)==6 and (.subscriptions|length)==4 and .subscriptions[0].expire==1893456000'
expect_true "sing-box check accepts the config" sing-box check -c /tmp/vpnpool/sing-box.json
end

# the first fetch after the upgrade: the primary does not answer, the extra one does — the primary
# keeps its nodes from the 1.x cache the migration moved to its own copy
mock_on; mock_rule 'GET https://sub.example.com/sub/TOKENPRIMARY' 500
printf '%s\n' 'vless://11111111-2222-4333-8444-555555555513@203.0.113.23:443?security=tls&sni=extra.example#Extra-New' > "$FXT/extra.txt"
mock_rule 'GET https://extra.example.com/list/TOKENEXTRA' 200 "$FXT/extra.txt"
sh /usr/libexec/vpnpool/fetch.sh > "$FXT/fetch.out" 2>&1
begin "migrate/first-fetch-primary-down-keeps-its-nodes"
expect_true "the primary served from the moved cache" cmp -s "/tmp/vpnpool/sources/s-$(skey 'https://sub.example.com/sub/TOKENPRIMARY').raw" "$FXM/sources_cache/000.raw"
expect_true "the extra one fetched (positive control)" grep -q 'Extra-New' "/tmp/vpnpool/sources/s-$(skey 'https://extra.example.com/list/TOKENEXTRA').raw"
end

# interrupted after the files, before the commit (power loss): the next run gives the same result
cp "$FXT/after1.cfg" "$FXT/single.cfg"
mig_setup
sh "$MIG" >/dev/null 2>&1
cp "$FXM/etc-config-vpnpool" /etc/config/vpnpool                 # the commit "never happened"
for f in saved.map.json snapshot.map.json imported.map.json unlock.map.json sub.expire sub.usage; do cp "$FXM/$f" /etc/vpnpool/; done
cp "$FXM/awg/0a1b2c3d4e5f.conf" /etc/vpnpool/awg/                 # the rename's old name back too
ls /etc/vpnpool/backup-1.x/vpnpool-1.x-*.tar.gz > /etc/vpnpool/backup-1.x/.in-progress   # the run "did not finish"
sh "$MIG" > "$FXT/run3.out" 2>&1; MRC3=$?
begin "migrate/rerun-after-an-interruption"
expect_eq "exit code" "$MRC3" 0
expect_true "same config as one clean run" cmp -s /etc/config/vpnpool "$FXT/single.cfg"
expect_eq "the AWG node once (the duplicate old name removed)" "$(ls /etc/vpnpool/awg/ | grep -c "^$ID_AWG.conf$") $(ls /etc/vpnpool/awg/0a1b2c3d4e5f.conf 2>/dev/null | wc -l)" '1 0'
expect_eq "the first backup kept (the true 1.x state)" "$(ls /etc/vpnpool/backup-1.x/*.tar.gz | wc -l)" 1
expect_true "the mark of the unfinished run is gone" [ ! -e /etc/vpnpool/backup-1.x/.in-progress ]
end
# a 1.x config put back AFTER a finished migration (a restore): a backup of ITS state, not the old one
sleep 1; cp "$FXM/etc-config-vpnpool" /etc/config/vpnpool
sh "$MIG" > "$FXT/run3b.out" 2>&1
begin "migrate/second-1x-config-gets-its-own-backup"
expect_eq "two backups" "$(ls /etc/vpnpool/backup-1.x/*.tar.gz | wc -l)" 2
expect_jq "the report names the new one" "$(cat /etc/vpnpool/migration.json)" "(.backup) == \"$(ls -t /etc/vpnpool/backup-1.x/*.tar.gz | head -n1)\""
end
# the same key twice with DIFFERENT settings: the second file is not deleted, it is reported
mig_setup
cp "$FXM/awg/0a1b2c3d4e5f.conf" "/etc/vpnpool/awg/$ID_AWG.conf"; sed -i 's/^Jc = 4$/Jc = 5/' "/etc/vpnpool/awg/$ID_AWG.conf"
sh "$MIG" >/dev/null 2>&1
begin "migrate/awg-same-key-other-settings-kept"
expect_true "control: the two files differ" sh -c '! cmp -s "$1" "$2"' _ "/etc/vpnpool/awg/$ID_AWG.conf" "$FXM/awg/0a1b2c3d4e5f.conf"
expect_true "the 1.x file kept" [ -f /etc/vpnpool/awg/0a1b2c3d4e5f.conf ]
expect_jq "and reported" "$(cat /etc/vpnpool/migration.json)" '[.unmatched[] | select(.store=="awg_file") | .value] | index("0a1b2c3d4e5f.conf") != null'
end
# a run that waits for another one (init.d and the package scripts meet) instead of going on
mig_setup
sleep 3 & HOLD=$!; echo "$HOLD" > /tmp/vpnpool/.migrate.lock
sh "$MIG" > "$FXT/run5.out" 2>&1; MRC5L=$?
begin "migrate/waits-for-the-other-run"
expect_true "control: the holder was alive when it started" [ -n "$HOLD" ]
expect_eq "exit code" "$MRC5L" 0
expect_eq "migrated after the other one ended" "$(uci -q get vpnpool.main.schema)" 2
end

# no backup -> no change
mig_setup
rm -rf /etc/vpnpool/backup-1.x; : > /etc/vpnpool/backup-1.x     # a FILE where the directory goes
sh "$MIG" > "$FXT/run4.out" 2>&1; MRC4=$?
begin "migrate/no-backup-no-change"
expect_eq "exit code 1" "$MRC4" 1
expect_true "the config untouched" cmp -s /etc/config/vpnpool "$FXM/etc-config-vpnpool"
expect_true "the 1.x maps untouched" cmp -s /etc/vpnpool/saved.map.json "$FXM/saved.map.json"
expect_true "journal says why" grep -q 'FAILED: the backup' /etc/vpnpool/migrate.log
end
rcall status
begin "migrate/failure-visible-in-status"
expect_jq "migration failed, with the reason" "$R" '.migration.state=="failed" and .migration.reason=="backup_failed"'
end
# init.d start with the migration failing: the 2.0 daemon is NOT started on the 1.x config
INITD="$REPO/package/vpnpool/files/etc/init.d/vpnpool"
sh -c "procd_open_instance() { echo \"open \$1\" >> $FXT/procd.log; }; procd_set_param() { :; }; procd_close_instance() { :; }; . /lib/functions.sh; . $INITD; start_service" >/dev/null 2>&1
begin "migrate/failed-migration-daemon-not-started"
expect_eq "control: still 1.x, enabled" "$(uci -q get vpnpool.main.schema)/$(uci -q get vpnpool.main.enabled)" "/1"
expect_eq "no daemon instance opened" "$(gcount '^open vpnpoold' "$FXT/procd.log")" 0
end
# the package's uci-defaults script: its exit code is the migration's (default_postinst removes it
# only on 0, so a failed run is tried again at the next boot)
UCID="$REPO/package/vpnpool/files/etc/uci-defaults/90-vpnpool-2.0"
( cd /etc/uci-defaults 2>/dev/null || cd /; . "$UCID" ) >/dev/null 2>&1; URC1=$?
rm -f /etc/vpnpool/backup-1.x
( cd /; . "$UCID" ) >/dev/null 2>&1; URC2=$?
begin "migrate/uci-defaults-runs-it-and-reports"
expect_eq "rc 1 while the migration can't run (the file stays for the next boot)" "$URC1" 1
expect_eq "rc 0 once it ran" "$URC2" 0
expect_eq "migrated" "$(uci -q get vpnpool.main.schema)" 2
end
# init.d start runs it too (a config sysupgrade kept, ...); on schema 2 it returns at once
mig_setup; : > "$FXT/procd.log"
sh -c "procd_open_instance() { echo \"open \$1\" >> $FXT/procd.log; }; procd_set_param() { :; }; procd_close_instance() { :; }; . /lib/functions.sh; . $INITD; start_service" >/dev/null 2>&1
begin "migrate/init-d-start-migrates"
expect_eq "schema 2" "$(uci -q get vpnpool.main.schema)" 2
expect_eq "then the daemon starts (positive control of the case above)" "$(gcount '^open vpnpoold' "$FXT/procd.log")" 1
end

# a 2.0 config (the package default) is left alone: no backup, no journal
reset_state
cp /etc/config/vpnpool "$FXT/def.cfg"
sh "$MIG" >/dev/null 2>&1; MRC5=$?
begin "migrate/2x-config-untouched"
expect_eq "exit code" "$MRC5" 0
expect_true "config byte-identical" cmp -s /etc/config/vpnpool "$FXT/def.cfg"
expect_true "no backup, no journal" sh -c '[ ! -e /etc/vpnpool/backup-1.x ] && [ ! -e /etc/vpnpool/migrate.log ]'
end
