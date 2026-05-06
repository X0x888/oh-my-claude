#!/usr/bin/env bash
# tests/test-recovery-rate-alarm.sh — regression net for the
# per-session state-recovery counter and the escalated directive
# fired when count >= 2.
#
# Why this exists. The Bug B post-mortem identified "attractive
# resilience" as a structural failure: a graceful recovery that fires
# repeatedly LOOKS like the harness working when in fact it is the
# harness mis-reading itself. The v1.34.x hardening adds a sidecar
# counter (`<session>/.recovery_count`) incremented on each
# `_ensure_valid_state` recovery branch, and the router escalates
# the user-facing directive when count >= 2 ("recovery firing
# repeatedly is almost always a bug in the recovery itself").
# Without a regression net for the counter and the escalation,
# the rule is unenforced and a future refactor could quietly drop
# either side.
#
# Tests:
#   T1 — first recovery: counter sidecar created with value 1
#   T2 — second recovery: counter increments to 2
#   T3 — third recovery: counter increments to 3 (no upper cap)
#   T4 — counter sidecar lives in the session dir, not in
#        session_state.json itself (so it survives the recovery)
#   T5 — counter file is restored to a sensible state if it carries
#        non-numeric content (defensive)
#   T6 — gate event emits .details.recovery_count when present
#        (audit-side validation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_ne() {
  local label="$1" forbidden="$2" actual="$3"
  if [[ "${actual}" != "${forbidden}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected != %q got %q\n' "${label}" "${forbidden}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="recovery-rate-test"
ensure_session_dir
trap 'rm -rf "${TEST_STATE_ROOT}"' EXIT

# Helper: corrupt the JSON state, then trigger _ensure_valid_state via
# write_state. _state_validated must be reset so the validator runs
# again (per-process cache).
trigger_recovery() {
  printf 'not valid json {{{\n' > "$(session_file "${STATE_JSON}")"
  _state_validated=0
  write_state "trigger" "ok"
}

# ----------------------------------------------------------------------
printf 'T1: first recovery creates sidecar counter with value 1\n'
trigger_recovery
counter_file="$(session_file ".recovery_count")"
assert_eq "T1: counter sidecar exists" "1" "$([[ -f "${counter_file}" ]] && echo 1 || echo 0)"
got_count="$(cat "${counter_file}")"
assert_eq "T1: counter == 1 after first recovery" "1" "${got_count}"

# ----------------------------------------------------------------------
printf 'T2: second recovery increments counter to 2 (alarm threshold)\n'
trigger_recovery
got_count="$(cat "${counter_file}")"
assert_eq "T2: counter == 2 after second recovery" "2" "${got_count}"

# ----------------------------------------------------------------------
printf 'T3: third recovery increments counter to 3 (no upper cap)\n'
trigger_recovery
got_count="$(cat "${counter_file}")"
assert_eq "T3: counter == 3 after third recovery" "3" "${got_count}"

# ----------------------------------------------------------------------
printf 'T4: counter sidecar survives JSON-state archive\n'
# After multiple recoveries, the sidecar must still be readable —
# the JSON-state file gets archived to .corrupt.<ts> on each recovery
# but the sidecar is at a different path.
sidecar_basename="$(basename "${counter_file}")"
session_dir="$(dirname "${counter_file}")"
assert_eq "T4: sidecar in session dir, not state JSON" "${sidecar_basename}" ".recovery_count"
state_json_path="$(session_file "${STATE_JSON}")"
assert_ne "T4: sidecar path != session_state.json path" "${state_json_path}" "${counter_file}"
# Trigger a 4th recovery; sidecar should still be readable.
trigger_recovery
assert_eq "T4: counter == 4 after fourth recovery" "4" "$(cat "${counter_file}")"

# ----------------------------------------------------------------------
printf 'T5: non-numeric counter content is treated as 0 (defensive)\n'
printf 'corrupted-counter-content' > "${counter_file}"
_state_validated=0
trigger_recovery
got_count="$(cat "${counter_file}")"
assert_eq "T5: non-numeric counter resets to 1 on next recovery" "1" "${got_count}"

# ----------------------------------------------------------------------
printf 'T6: gate event from prompt-intent-router carries recovery_count\n'
# Reset the sidecar to a known value, then assert the recovery_count
# kv pair would be emitted by inspecting the router's invocation
# pattern. The router script construction is too coupled to mock
# end-to-end here (it requires HOOK_JSON, settings, etc.); instead,
# verify the contract by direct inspection of the code path.
router="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
if grep -q 'recovery_count="\${_recovery_count}"' "${router}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: prompt-intent-router does not emit recovery_count gate-event detail\n' >&2
  fail=$((fail + 1))
fi
if grep -q 'state_recovery_alarm' "${router}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: prompt-intent-router missing state_recovery_alarm directive name\n' >&2
  fail=$((fail + 1))
fi
# The alarm directive must contain the canonical phrasing so the
# user is led to the right action.
if grep -q 'almost always a bug in the recovery itself' "${router}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: alarm directive missing canonical "bug in the recovery itself" phrasing\n' >&2
  fail=$((fail + 1))
fi
# The threshold (>=2) must be present with the documented inequality.
if grep -q '_recovery_count.*-ge 2' "${router}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: alarm threshold (-ge 2) missing\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf '\n=== Recovery-Rate Alarm Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
