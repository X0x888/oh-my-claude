#!/usr/bin/env bash
#
# Regression net for verify.sh --health (v1.42.x-newer sre-lens F-005).
# The output contract is "single greppable line"; this test pins the
# shape so future edits cannot silently break external monitor wraps
# that grep `^OK:`.
#
# Coverage:
#   T1  — happy path: no _watchdog dir → `OK: watchdog=no-watchdog ...`.
#   T2  — healthy heartbeat (5s ago) → `OK: watchdog=ok-Ns ...`.
#   T3  — stale heartbeat (15min) → `WARN: watchdog=warn-stale-Ns ...`.
#   T4  — very stale heartbeat (1hr) → `FAIL: watchdog=fail-stale-Ns ...`.
#   T5  — unreadable heartbeat (garbage) → `WARN: watchdog=warn-unreadable ...`.
#   T5b — noncanonical, oversized, mixed, binary, future, and unsafe heartbeat nodes are unreadable.
#   T5c — a noncanonical system clock fails before arithmetic/JSON import.
#   T6  — active session count reflects dir mtime.
#   T6b — traversal failure still emits one WARN status line.
#   T6c — an unsafe/unreadable anomaly node degrades health to WARN.
#   T7  — anomaly count from the production hooks.log ≥ 4 → WARN escalation.
#   T8  — anomaly count > 10 → FAIL escalation.
#   T9  — exit code maps to status (OK=0, WARN=1, FAIL=2).
#   T10 — output line matches regex contract for external monitor wrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY="${REPO_ROOT}/verify.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "${actual}" =~ ${pattern} ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%s\n    actual=%q\n' "${label}" "${pattern}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

run_health() {
  local target="$1"
  set +e
  out="$(TARGET_HOME="${target}" bash "${VERIFY}" --health 2>&1)"
  rc=$?
  set -e
  printf '%s' "${out}"
  return "${rc}"
}

setup_target() {
  local td
  td="$(mktemp -d -t verify-health-XXXXXX)"
  mkdir -p "${td}/.claude/quality-pack/state"
  printf '%s' "${td}"
}

# T1: no _watchdog dir → no-watchdog
printf 'T1: no watchdog dir → no-watchdog status\n'
T="$(setup_target)"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T1: exit code 0" "0" "${rc}"
assert_match "T1: output starts with OK:" '^OK:' "${out}"
assert_match "T1: watchdog=no-watchdog" 'watchdog=no-watchdog' "${out}"
rm -rf "${T}"

# T2: healthy heartbeat (5s ago) → ok-Ns
printf 'T2: healthy heartbeat → ok status\n'
T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
_now="$(date +%s)"
printf '%s' "$(( _now - 5 ))" \
  > "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T2: exit code 0" "0" "${rc}"
assert_match "T2: status is OK" '^OK:' "${out}"
assert_match "T2: watchdog=ok-Ns" 'watchdog=ok-[0-9]+s' "${out}"
rm -rf "${T}"

# T3: stale heartbeat (15min) → warn
printf 'T3: stale heartbeat 15min → WARN\n'
T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
_now="$(date +%s)"
printf '%s' "$(( _now - 900 ))" \
  > "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T3: exit code 1 (WARN)" "1" "${rc}"
assert_match "T3: status is WARN" '^WARN:' "${out}"
assert_match "T3: warn-stale-Ns" 'watchdog=warn-stale-[0-9]+s' "${out}"
rm -rf "${T}"

# T4: very stale heartbeat (2hr) → fail
printf 'T4: very stale heartbeat 2hr → FAIL\n'
T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
_now="$(date +%s)"
printf '%s' "$(( _now - 7200 ))" \
  > "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T4: exit code 2 (FAIL)" "2" "${rc}"
assert_match "T4: status is FAIL" '^FAIL:' "${out}"
assert_match "T4: fail-stale-Ns" 'watchdog=fail-stale-[0-9]+s' "${out}"
rm -rf "${T}"

# T5: garbage heartbeat → warn-unreadable
printf 'T5: garbage heartbeat → warn-unreadable\n'
T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
printf 'not-a-number' \
  > "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T5: exit code 1 (WARN)" "1" "${rc}"
assert_match "T5: warn-unreadable" 'watchdog=warn-unreadable' "${out}"
rm -rf "${T}"

# T5b: numeric-looking poison must not be normalized into a healthy heartbeat.
printf 'T5b: noncanonical heartbeat values remain unreadable\n'
_now="$(date +%s)"
for _heartbeat_case in \
    '08' \
    '9999999999999999' \
    '123mixed456' \
    "$(( _now + 3600 ))"; do
  T="$(setup_target)"
  mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
  printf '%s\n' "${_heartbeat_case}" \
    > "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
  set +e
  out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
  rc=$?
  set -e
  assert_eq "T5b: ${_heartbeat_case} exits WARN" "1" "${rc}"
  assert_match "T5b: ${_heartbeat_case} is unreadable" \
    'watchdog=warn-unreadable' "${out}"
  rm -rf "${T}"
done

T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
printf '%s\0' "${_now}" \
  > "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T5b: NUL-suffixed epoch exits WARN" "1" "${rc}"
assert_match "T5b: NUL-suffixed epoch is unreadable" \
  'watchdog=warn-unreadable' "${out}"
rm -rf "${T}"

T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/_watchdog"
ln -s "${T}/missing-heartbeat-target" \
  "${T}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T5b: dangling heartbeat symlink exits WARN" "1" "${rc}"
assert_match "T5b: dangling heartbeat symlink is unreadable" \
  'watchdog=warn-unreadable' "${out}"
rm -rf "${T}"

# T5c: `date` output crosses the same canonical boundary before it reaches
# Bash arithmetic or jq --argjson.
printf 'T5c: noncanonical system clock fails closed\n'
T="$(setup_target)"
_clock_bin="${T}/bin"
mkdir -p "${_clock_bin}"
cat > "${_clock_bin}/date" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '08'
EOF
chmod +x "${_clock_bin}/date"
set +e
out="$(PATH="${_clock_bin}:${PATH}" TARGET_HOME="${T}" \
  bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T5c: invalid clock exits FAIL" "2" "${rc}"
assert_match "T5c: invalid clock has one-line failure status" \
  '^FAIL: watchdog=clock-unreadable sessions=0 anomalies_1h=0$' "${out}"
rm -rf "${T}"

# T6: active-session count reflects directory mtime
printf 'T6: active-session count from mtime\n'
T="$(setup_target)"
mkdir -p "${T}/.claude/quality-pack/state/abcdef0123456789-fresh"
mkdir -p "${T}/.claude/quality-pack/state/abcdef0123456789-stale"
# Backdate the stale one by 25h via touch.
touch -t "$(date -v-25H '+%Y%m%d%H%M' 2>/dev/null || date -d '25 hours ago' '+%Y%m%d%H%M' 2>/dev/null)" \
  "${T}/.claude/quality-pack/state/abcdef0123456789-stale" 2>/dev/null || true
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
# Should see exactly 1 active session (the fresh one); the stale one is >24h.
assert_match "T6: sessions=1 (stale dir excluded)" 'sessions=1' "${out}"
rm -rf "${T}"

# T6b: a failed state traversal must not trip `set -e` and exit without the
# health endpoint's mandatory one-line status contract.
printf 'T6b: active-session traversal failure degrades to one WARN line\n'
T="$(setup_target)"
_find_bin="${T}/bin"
mkdir -p "${_find_bin}"
cat > "${_find_bin}/find" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
chmod +x "${_find_bin}/find"
set +e
out="$(PATH="${_find_bin}:${PATH}" TARGET_HOME="${T}" \
  bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T6b: traversal failure exits WARN" "1" "${rc}"
assert_match "T6b: traversal failure retains one-line schema" \
  '^WARN: watchdog=no-watchdog sessions=0 anomalies_1h=0$' "${out}"
assert_eq "T6b: traversal failure emits exactly one line" "1" \
  "$(printf '%s' "${out}" | grep -c '^' || true)"
rm -rf "${T}"

# T6c: an existing anomaly node is not the same as a benign missing log. An
# unsafe node or read failure must degrade health rather than silently report
# zero anomalies.
printf 'T6c: unreadable anomaly source degrades to one WARN line\n'
T="$(setup_target)"
ln -s "${T}/missing-hooks-target" \
  "${T}/.claude/quality-pack/state/hooks.log"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T6c: dangling anomaly symlink exits WARN" "1" "${rc}"
assert_match "T6c: anomaly read failure retains one-line schema" \
  '^WARN: watchdog=no-watchdog sessions=0 anomalies_1h=0$' "${out}"
assert_eq "T6c: anomaly read failure emits exactly one line" "1" \
  "$(printf '%s' "${out}" | grep -c '^' || true)"
rm -rf "${T}"

# T7: anomaly count 4-10 → WARN escalation
printf 'T7: anomaly count >=4 → WARN\n'
T="$(setup_target)"
_now_text="$(date '+%Y-%m-%d %H:%M:%S')"
{
  for i in 1 2 3 4 5; do
    printf '%s  [anomaly]  test  r%s\n' "${_now_text}" "${i}"
  done
} > "${T}/.claude/quality-pack/state/hooks.log"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T7: exit code 1 (WARN)" "1" "${rc}"
assert_match "T7: WARN status" '^WARN:' "${out}"
assert_match "T7: anomalies_1h=5" 'anomalies_1h=5' "${out}"
rm -rf "${T}"

# T8: anomaly count > 10 → FAIL escalation
printf 'T8: anomaly count >10 → FAIL\n'
T="$(setup_target)"
_now_text="$(date '+%Y-%m-%d %H:%M:%S')"
{
  for i in $(seq 1 12); do
    printf '%s  [anomaly]  test  r%s\n' "${_now_text}" "${i}"
  done
} > "${T}/.claude/quality-pack/state/hooks.log"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T8: exit code 2 (FAIL)" "2" "${rc}"
assert_match "T8: FAIL status" '^FAIL:' "${out}"
assert_match "T8: anomalies_1h=12" 'anomalies_1h=12' "${out}"
rm -rf "${T}"

# T9: exit code/status alignment baseline (single OK case)
printf 'T9: exit code 0 baseline\n'
T="$(setup_target)"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
assert_eq "T9: OK → exit 0" "0" "${rc}"
rm -rf "${T}"

# T10: line shape contract — single line, regex-matches
printf 'T10: output is greppable single line\n'
T="$(setup_target)"
set +e
out="$(TARGET_HOME="${T}" bash "${VERIFY}" --health 2>&1)"
rc=$?
set -e
line_count="$(printf '%s' "${out}" | grep -c '^' || true)"
assert_eq "T10: output is single line" "1" "${line_count}"
assert_match "T10: contract regex matches" \
  '^(OK|WARN|FAIL):\ watchdog=[a-z0-9-]+\ sessions=[0-9]+\ anomalies_1h=[0-9]+$' \
  "${out}"
rm -rf "${T}"

printf '\n=== verify-health: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
