# suite: sched — sched.sh renders the uci schedule into a marked crontab block (sourced by run.sh)
# Known defect (ROADMAP 2.6): `$((10#$m))` is not valid busybox-ash arithmetic -> the script
# dies after writing "BEGIN" and before "END": no job is scheduled, and the unmatched BEGIN
# makes the NEXT run's sed delete everything after it (user cron jobs included).

CRON=/etc/crontabs/root
SCHED=/usr/libexec/vpnpool/sched.sh
mkdir -p /etc/crontabs

sched_cfg() {   # <enabled> <on> <off> <refresh>
	uci set vpnpool.main.sched_enabled="$1"
	uci set vpnpool.main.sched_on="$2"
	uci set vpnpool.main.sched_off="$3"
	uci set vpnpool.main.sched_refresh="$4"
	uci commit vpnpool
}
cron_count() { gcount -- "$1" "$CRON"; }

# ---- positive control: disabled schedule removes an old block, keeps user jobs ----
reset_state; mkdir -p /etc/crontabs
printf '0 3 * * * /bin/userjob-before\n# vpnpool-sched BEGIN\n1 1 * * * /etc/init.d/vpnpool stop\n# vpnpool-sched END\n30 4 * * * /bin/userjob-after\n' > "$CRON"
sched_cfg 0 '' '' ''
sh "$SCHED" >/dev/null 2>&1
begin "sched/disabled-removes-block-keeps-user-jobs"
expect_eq "no BEGIN" "$(cron_count 'vpnpool-sched BEGIN')" 0
expect_eq "no END" "$(cron_count 'vpnpool-sched END')" 0
expect_eq "user job before kept" "$(cron_count userjob-before)" 1
expect_eq "user job after kept" "$(cron_count userjob-after)" 1
end

# ---- enabled schedule is actually written ----
reset_state; mkdir -p /etc/crontabs
printf '0 3 * * * /bin/userjob-before\n' > "$CRON"
sched_cfg 1 '07:05' '23:00' '04:30'
sh "$SCHED" >/dev/null 2>&1; SRC=$?
begin "sched/enabled-writes-jobs"
expect_eq "sched.sh exit code" "$SRC" 0
expect_eq "one BEGIN" "$(cron_count 'vpnpool-sched BEGIN')" 1
expect_eq "one END" "$(cron_count 'vpnpool-sched END')" 1
expect_eq "start job 5 7" "$(cron_count '^5 7 \* \* \* /etc/init.d/vpnpool start$')" 1
expect_eq "stop job 0 23" "$(cron_count '^0 23 \* \* \* /etc/init.d/vpnpool stop$')" 1
expect_eq "refresh job 30 4" "$(cron_count '^30 4 \* \* \* kill -USR2')" 1
expect_eq "user job kept" "$(cron_count userjob-before)" 1
end

# ---- crontab is not corrupted across runs: a user job added between runs survives ----
reset_state; mkdir -p /etc/crontabs
printf '0 3 * * * /bin/userjob-before\n' > "$CRON"
sched_cfg 1 '07:00' '' ''
sh "$SCHED" >/dev/null 2>&1
echo '15 2 * * * /bin/userjob-added-later' >> "$CRON"
sh "$SCHED" >/dev/null 2>&1
begin "sched/user-job-added-between-runs-survives"
expect_eq "late user job survives the 2nd run" "$(cron_count userjob-added-later)" 1
expect_eq "BEGIN/END balanced" "$(cron_count 'vpnpool-sched BEGIN')" "$(cron_count 'vpnpool-sched END')"
end

# ---- garbage times are rejected without breaking the file ----
reset_state; mkdir -p /etc/crontabs
printf '0 3 * * * /bin/userjob-before\n' > "$CRON"
sched_cfg 1 'abc' '25:99' ''
sh "$SCHED" >/dev/null 2>&1; SRC=$?
begin "sched/garbage-times-no-job-file-intact"
expect_eq "no vpnpool job lines" "$(gcount /etc/init.d/vpnpool "$CRON")" 0
expect_eq "user job kept" "$(cron_count userjob-before)" 1
expect_eq "BEGIN/END balanced" "$(cron_count 'vpnpool-sched BEGIN')" "$(cron_count 'vpnpool-sched END')"
expect_eq "sched.sh reports the bad time (rc 2)" "$SRC" 2
end

# ---- a lone BEGIN (left by the old broken version) must not swallow the jobs after it ----
reset_state; mkdir -p /etc/crontabs
printf '0 3 * * * /bin/userjob-before\n# vpnpool-sched BEGIN\n45 1 * * * /bin/userjob-after-lone-begin\n' > "$CRON"
sched_cfg 1 '06:00' '' ''
sh "$SCHED" >/dev/null 2>&1
begin "sched/lone-begin-keeps-following-user-jobs"
expect_eq "user job after the lone BEGIN kept" "$(cron_count userjob-after-lone-begin)" 1
expect_eq "user job before kept" "$(cron_count userjob-before)" 1
expect_eq "start job written" "$(cron_count '^0 6 \* \* \* /etc/init.d/vpnpool start$')" 1
end

# ---- leading zeros: 08:09 is a time, not an octal error ----
reset_state; mkdir -p /etc/crontabs; : > "$CRON"
sched_cfg 1 '08:09' '00:00' ''
sh "$SCHED" >/dev/null 2>&1; SRC=$?
begin "sched/leading-zeros"
expect_eq "rc" "$SRC" 0
expect_eq "start 9 8" "$(cron_count '^9 8 \* \* \* /etc/init.d/vpnpool start$')" 1
expect_eq "stop 0 0" "$(cron_count '^0 0 \* \* \* /etc/init.d/vpnpool stop$')" 1
end
