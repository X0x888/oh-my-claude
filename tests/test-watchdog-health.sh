#!/usr/bin/env bash
# test-watchdog-health.sh — v1.43 sre-lens F-001 regression net.
#
# Covers session-start-watchdog-health.sh which fires on SessionStart
# when resume_watchdog is enabled AND the watchdog heartbeat at
# ${STATE_ROOT}/_watchdog/last_tick_completed_ts is missing or stale
# (>= 3 × StartInterval = 360s by default).
#
# The hook closes the silent-failure trap where launchd unloads the
# watchdog agent (macOS update, bootout, plist signature drift) and
# the user discovers the dead agent only the next time auto-resume
# *should* have fired.
#
# Scope note (v1.47): this file covers the DETECTION + WARNING surface.
# Since this sandbox does not install ~/.claude/install-resume-watchdog.sh,
# the v1.47 guarded self-heal lands in its `attempt-failed` branch (no
# installer to invoke), which preserves the original warning text — so
# these assertions remain valid. The self-heal ACTION (safe re-register,
# orphan-prevention block, once-per-session) is covered separately in
# tests/test-watchdog-selfheal.sh, which installs a mocked installer +
# platform binaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-watchdog-health.sh"

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:200}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unwanted=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:200}" >&2
    fail=$((fail + 1))
  fi
}

# Isolate HOME + STATE_ROOT. Force resume_watchdog off by default so
# conf-bleed (load_conf walks PWD upward AND reads ${HOME}/...) cannot
# leak the developer's real `resume_watchdog=on` into the subprocess.
TEST_ROOT="$(mktemp -d)"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.claude/quality-pack" "${HOME}/.claude/skills"
# Symlink the bundle's skills/autowork into the test HOME so the hook
# can source common.sh from its standard install path.
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${HOME}/.claude/skills/autowork"
export STATE_ROOT="${TEST_ROOT}/state"
mkdir -p "${STATE_ROOT}"
# Run test from TEST_ROOT so load_conf's PWD walk does not find the
# repo's own .claude/ (if any) or any ancestor conf.
cd "${TEST_ROOT}"
export OMC_RESUME_WATCHDOG=off

cleanup() { rm -rf "${TEST_ROOT}"; }
trap cleanup EXIT

SID="watchdog-health-test"
DEFAULT_INPUT='{"session_id":"'"${SID}"'","source":"startup"}'
run_hook() {
  local input="${1:-${DEFAULT_INPUT}}"
  # Reset per-test session state by deleting the test session dir.
  # SESSION_ID comes from the JSON payload, so derive from input.
  local sid
  sid="$(printf '%s' "${input}" | jq -r '.session_id' 2>/dev/null || echo "${SID}")"
  rm -rf "${STATE_ROOT:?}/${sid}" 2>/dev/null || true
  printf '%s' "${input}" | bash "${HOOK}" 2>/dev/null || true
}

# ---------------------------------------------------------------
# H1: watchdog opt-out — silent
# ---------------------------------------------------------------
# Already exported OMC_RESUME_WATCHDOG=off at top.
out="$(run_hook '{"session_id":"'"${SID}"'","source":"startup"}')"
assert_eq "H1 watchdog disabled -> empty output" "" "${out}"

# ---------------------------------------------------------------
# H2: watchdog enabled + heartbeat missing -> stale alarm (never-started)
# ---------------------------------------------------------------
export OMC_RESUME_WATCHDOG=on
out="$(run_hook)"
assert_contains "H2a alarm banner when heartbeat missing" "resume-watchdog appears inactive" "${out}"
assert_contains "H2b reason mentions never-started semantics" "No watchdog heartbeat" "${out}"
assert_contains "H2c recovery action surfaced (re-register)" "install-resume-watchdog.sh" "${out}"
assert_contains "H2d opt-out path surfaced" "resume_watchdog=off" "${out}"

# ---------------------------------------------------------------
# H3: fresh heartbeat -> silent
# ---------------------------------------------------------------
mkdir -p "${STATE_ROOT}/_watchdog"
date +%s > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook)"
assert_eq "H3 fresh heartbeat -> empty output" "" "${out}"

# ---------------------------------------------------------------
# H4: stale heartbeat -> alarm with age rendered as Nm/NhM
# ---------------------------------------------------------------
# Set heartbeat to 600 seconds ago (10 minutes) — well above default 360s.
# Race-tolerance: between writing the heartbeat and the hook reading the
# clock, age_secs is 600 ± a small jitter, so assert with a regex match
# on `Ns ago` where N is 598..605 (covers any plausible scheduling gap).
printf '%s\n' "$(( $(date +%s) - 600 ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook)"
assert_contains "H4a stale-alarm fires" "resume-watchdog appears inactive" "${out}"
if [[ "${out}" =~ 60[0-9]s\ ago ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: H4b age rendered as "N0Ns ago" pattern (got: %s)\n' "${out:0:240}" >&2
  fail=$((fail + 1))
fi
assert_contains "H4c threshold mentioned" "Threshold is 360s" "${out}"

# ---------------------------------------------------------------
# H5: corrupt heartbeat content -> silent (avoids misleading alarm)
# ---------------------------------------------------------------
printf 'not-a-number\n' > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook)"
assert_eq "H5 corrupt heartbeat -> silent" "" "${out}"

# ---------------------------------------------------------------
# H6: per-session idempotency — second fire silent within same SESSION_ID
# ---------------------------------------------------------------
# Use a heartbeat far enough in the past to alarm; first call alarms;
# second call (same SESSION_ID, no rm of session dir) is silent.
mkdir -p "${STATE_ROOT}/_watchdog"
printf '%s\n' "$(( $(date +%s) - 1200 ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"

# First fire — alarm.
input='{"session_id":"'"${SID}-idem"'","source":"startup"}'
rm -rf "${STATE_ROOT:?}/${SID}-idem"  # ensure clean state
first="$(printf '%s' "${input}" | bash "${HOOK}" 2>/dev/null || true)"
assert_contains "H6a first SessionStart alarms" "resume-watchdog appears inactive" "${first}"

# H6c (quality-reviewer F-004): assert the state flag actually landed.
# Tests behavior (silent second call) without this assertion can silently
# pass via an unrelated code path if write_state breaks.
session_state="${STATE_ROOT}/${SID}-idem/session_state.json"
flag_value="$(jq -r '.watchdog_health_emitted // ""' "${session_state}" 2>/dev/null)"
assert_eq "H6c watchdog_health_emitted state flag written" "1" "${flag_value}"

# Second fire — same session dir already carries watchdog_health_emitted=1.
second="$(printf '%s' "${input}" | bash "${HOOK}" 2>/dev/null || true)"
assert_eq "H6b second SessionStart same session -> silent" "" "${second}"

# ---------------------------------------------------------------
# H7: env override of threshold
# ---------------------------------------------------------------
# 200s-old heartbeat. Default threshold 360s -> silent. With env override
# OMC_WATCHDOG_HEALTH_STALENESS_SECS=120 -> alarm.
printf '%s\n' "$(( $(date +%s) - 200 ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook '{"session_id":"'"${SID}-thresh-default"'","source":"startup"}')"
assert_eq "H7a default threshold (360s) silent at 200s age" "" "${out}"

export OMC_WATCHDOG_HEALTH_STALENESS_SECS=120
out="$(run_hook '{"session_id":"'"${SID}-thresh-tight"'","source":"startup"}')"
unset OMC_WATCHDOG_HEALTH_STALENESS_SECS
assert_contains "H7b tightened threshold (120s) alarms at 200s age" "resume-watchdog appears inactive" "${out}"

# ---------------------------------------------------------------
# H8: payload is valid JSON shaped as SessionStart additionalContext
# ---------------------------------------------------------------
mkdir -p "${STATE_ROOT}/_watchdog"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook '{"session_id":"'"${SID}-shape"'","source":"startup"}')"

# Validate JSON shape.
shape_ok="$(jq -r '
  if (.hookSpecificOutput.hookEventName == "SessionStart")
     and ((.hookSpecificOutput.additionalContext // "") | length > 0)
  then "ok" else "bad" end
' <<<"${out}" 2>/dev/null || echo "parse-error")"
assert_eq "H8 payload is SessionStart additionalContext JSON" "ok" "${shape_ok}"

# ---------------------------------------------------------------
# H9 (quality-reviewer Wave 2 F-001): future-timestamp guard.
# Clock skew (NTP step-back, suspend/wake) can make `hb_ts > now`,
# producing negative age_secs. Pre-fix, `-ge ${threshold}` was FALSE
# for negatives and a dead watchdog was silently treated as fresh.
# Post-fix: distinct alarm with a clock-skew reason token.
# ---------------------------------------------------------------
unset OMC_WATCHDOG_HEALTH_STALENESS_SECS || true
mkdir -p "${STATE_ROOT}/_watchdog"
# Heartbeat 1 hour in the future.
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook '{"session_id":"'"${SID}-future"'","source":"startup"}')"
assert_contains "H9a future-timestamp alarm fires" "resume-watchdog appears inactive" "${out}"
assert_contains "H9b alarm includes clock-skew reason" "future-timestamp" "${out}"
assert_contains "H9c alarm distinguishes shape (future-in-banner-text)" "in the future" "${out}"

# H9d: even at the negative-but-tiny boundary (heartbeat a few seconds
# ahead) the guard fires — there's no benign reason for a forward-skewed
# heartbeat. +3s, not +1s: with +1 a single second of scheduler delay
# between this write and the hook's read collapsed the delta to 0 and
# the assertion flaked under load (observed: 19/1, 20/0, 19/1 across
# three solo runs on a busy host). Three seconds keeps the "tiny skew"
# semantics while giving the test real slack.
printf '%s\n' "$(( $(date +%s) + 3 ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
out="$(run_hook '{"session_id":"'"${SID}-future-tiny"'","source":"startup"}')"
assert_contains "H9d tiny-future (3s ahead) still alarms" "resume-watchdog appears inactive" "${out}"

printf '\nwatchdog-health tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
