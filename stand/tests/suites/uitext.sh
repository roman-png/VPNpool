# suite: uitext — technical words in human-visible UI strings (sourced by run.sh)
# The guard itself is stand/tests/ui-text-guard.uc (host wrapper: ui-text-guard.sh).

G="$T_DIR/ui-text-guard.uc"
SL="$T_DIR/ui-text-stoplist.txt"
BL="$T_DIR/ui-text-baseline.txt"
FXU="$T_DIR/fixtures/uitext"
OUTU="$T_STATE/uitext"; mkdir -p "$OUTU"

# ---- positive control: a fixture tree with known-bad strings is caught ----
ucode "$G" "$FXU/bad" "$SL" - > "$OUTU/bad.out" 2>&1; GRC=$?
begin "uitext/positive-control-bad-fixture-caught"
expect_eq "exit code 1 (new violations)" "$GRC" 1
expect_eq "strings extracted" "$(sed -n 's/^STRINGS //p' "$OUTU/bad.out")" 11
expect_eq "urltest in a view" "$(gcount 'NEW .*bad.js	urltest	Restart the urltest group' "$OUTU/bad.out")" 1
expect_eq "clash in a view" "$(gcount 'NEW .*bad.js	clash	Clash API is down' "$OUTU/bad.out")" 1
expect_eq "uci option name" "$(gcount 'NEW .*bad.js	snake_case	Set check_services first' "$OUTU/bad.out")" 1
expect_eq "filesystem path" "$(gcount 'NEW .*bad.js	fs-path	Logs are in /tmp/vpnpool' "$OUTU/bad.out")" 1
expect_eq "rpcd in the RU dictionary" "$(gcount 'NEW .*i18n.js	rpcd	Пинг через rpcd' "$OUTU/bad.out")" 1
expect_eq "ubus in a menu title" "$(gcount 'NEW .*bad.json	ubus	ubus monitor' "$OUTU/bad.out")" 1
expect_eq "non-gettext call ignored" "$(gcount 'non-gettext' "$OUTU/bad.out")" 0
expect_eq "exactly 6 violations" "$(sed -n 's/^VIOLATIONS //p' "$OUTU/bad.out")" 6
end

# ---- negative control: a clean fixture tree yields nothing ----
ucode "$G" "$FXU/good" "$SL" - > "$OUTU/good.out" 2>&1; GRC=$?
begin "uitext/clean-fixture-no-violations"
expect_eq "exit code 0" "$GRC" 0
expect_eq "strings extracted" "$(sed -n 's/^STRINGS //p' "$OUTU/good.out")" 5
expect_eq "violations" "$(sed -n 's/^VIOLATIONS //p' "$OUTU/good.out")" 0
end

# ---- the real app vs the baseline: no NEW violation ----
APP="$REPO/package/luci-app-vpnpool"
ucode "$G" "$APP" "$SL" "$BL" > "$OUTU/real.out" 2>&1; GRC=$?
NS=$(sed -n 's/^STRINGS //p' "$OUTU/real.out")
begin "uitext/real-app-no-new-violations"
expect_true "guard scanned the app (>=300 strings, got ${NS:-0})" [ "${NS:-0}" -ge 300 ]
expect_eq "exit code 0" "$GRC" 0
expect_eq "new violations" "$(sed -n 's/^NEW_COUNT //p' "$OUTU/real.out")" 0
end
[ "$GRC" -ne 0 ] && grep '^NEW ' "$OUTU/real.out" | head -20
metric ui_strings_scanned "${NS:-0}"
metric ui_violations_current "$(sed -n 's/^VIOLATIONS //p' "$OUTU/real.out")"
metric ui_violations_baseline "$(gcount -v '^#' "$BL")"
begin "uitext/baseline-exact-no-stale-lines"
expect_eq "baseline lines that no longer occur (run ui-text-guard.sh --update-baseline)" "$(sed -n 's/^GONE_COUNT //p' "$OUTU/real.out")" 0
end
grep '^GONE ' "$OUTU/real.out" | head -20

# ---- a stale baseline line fails the guard (exit 3), so a fixed violation can't come back ----
{ cat "$BL"; printf 'luci-app-vpnpool/files/x.js\turltest\tthis string no longer exists\n'; } > "$OUTU/stale.baseline"
ucode "$G" "$APP" "$SL" "$OUTU/stale.baseline" > "$OUTU/stale.out" 2>&1; GRC=$?
begin "uitext/stale-baseline-line-fails"
expect_eq "exit code 3" "$GRC" 3
expect_eq "exactly one GONE" "$(sed -n 's/^GONE_COUNT //p' "$OUTU/stale.out")" 1
expect_eq "no NEW" "$(sed -n 's/^NEW_COUNT //p' "$OUTU/stale.out")" 0
end

# ---- the baseline really gates: drop one baseline line => that violation becomes NEW ----
grep -v '^#' "$BL" | sed '1d' > "$OUTU/short.baseline"
ucode "$G" "$APP" "$SL" "$OUTU/short.baseline" > "$OUTU/short.out" 2>&1; GRC=$?
begin "uitext/baseline-gates-new-violations"
expect_true "baseline is not empty (else this control is void)" [ "$(gcount -v '^#' "$BL")" -ge 1 ]
expect_eq "exit code 1" "$GRC" 1
expect_eq "exactly one NEW" "$(sed -n 's/^NEW_COUNT //p' "$OUTU/short.out")" 1
end
