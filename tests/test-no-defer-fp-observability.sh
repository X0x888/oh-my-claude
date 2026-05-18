#!/usr/bin/env bash
# test-no-defer-fp-observability.sh — v1.43 oracle Wave 3 regression net.
#
# Tests the no-defer false-positive observability instrumentation:
#
# 1. When stop-guard fires `no-defer-mode/stop-block`, it now writes
#    `last_no_defer_block_ts` to session state.
# 2. The new helper `no_defer_check_post_block_reprompt` (common.sh)
#    reads that timestamp on the next user prompt; when the prompt
#    arrives within the reprompt window (default 60s), records
#    `no-defer-mode/post-block-reprompt` to gate events.
# 3. The state flag is cleared on every helper call (single-use), so a
#    block is paired with at most one prompt.
# 4. Outside the window or with no prior block, the helper is a no-op.
# 5. Tunable via OMC_NO_DEFER_REPROMPT_WINDOW_SECS.
#
# Behavior of the no-defer contract itself is unchanged — only the
# observability is new. The /ulw-report Patterns heuristic that
# consumes these events is tested via the integration shape (event
# names + gate-event JSON schema), not by running show-report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

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

# Isolate HOME + STATE_ROOT.
TEST_ROOT="$(mktemp -d)"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.claude/quality-pack"
export STATE_ROOT="${TEST_ROOT}/state"
mkdir -p "${STATE_ROOT}"
cd "${TEST_ROOT}"

cleanup() { rm -rf "${TEST_ROOT}"; }
trap cleanup EXIT

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

SESSION_ID="no-defer-fp-test"
ensure_session_dir
gate_events="$(session_file "gate_events.jsonl")"

count_events() {
  local gate="$1" event="$2"
  if [[ -f "${gate_events}" ]]; then
    jq -c --arg g "${gate}" --arg e "${event}" \
       'select(.gate == $g and .event == $e)' "${gate_events}" 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    echo "0"
  fi
}

# ---------------------------------------------------------------
# N1: helper is a no-op when no last_no_defer_block_ts has been set
# ---------------------------------------------------------------
no_defer_check_post_block_reprompt
assert_eq "N1 no prior block -> no event recorded" "0" "$(count_events no-defer-mode post-block-reprompt)"

# ---------------------------------------------------------------
# N2: fresh block (within window) -> event recorded
# ---------------------------------------------------------------
now_ts="$(now_epoch)"
write_state "last_no_defer_block_ts" "$(( now_ts - 30 ))"  # 30s ago, well within 60s window
no_defer_check_post_block_reprompt
assert_eq "N2a fresh block within window -> event recorded" "1" "$(count_events no-defer-mode post-block-reprompt)"

# N2b: state flag was cleared (single-use)
flag_after="$(read_state "last_no_defer_block_ts")"
assert_eq "N2b state flag cleared after pairing" "" "${flag_after}"

# N2c: event detail includes block_age_secs
last_event="$(jq -c 'select(.gate == "no-defer-mode" and .event == "post-block-reprompt")' "${gate_events}" | tail -1)"
age_str="$(jq -r '.details.block_age_secs' <<<"${last_event}")"
# 30 ± clock-jitter — accept anything 28..32
case "${age_str}" in
  28|29|30|31|32) pass=$((pass + 1)) ;;
  *) printf '  FAIL: N2c block_age_secs unexpected (got %q)\n' "${age_str}" >&2; fail=$((fail + 1)) ;;
esac

# ---------------------------------------------------------------
# N3: stale block (outside window) -> no event, but flag still cleared
# ---------------------------------------------------------------
: > "${gate_events}"  # reset
write_state "last_no_defer_block_ts" "$(( now_ts - 600 ))"  # 10 min ago, beyond 60s
no_defer_check_post_block_reprompt
assert_eq "N3a stale block -> no event recorded" "0" "$(count_events no-defer-mode post-block-reprompt)"
flag_after="$(read_state "last_no_defer_block_ts")"
assert_eq "N3b stale block: state flag still cleared" "" "${flag_after}"

# ---------------------------------------------------------------
# N4: corrupt content -> silent skip + flag cleared
# ---------------------------------------------------------------
: > "${gate_events}"
write_state "last_no_defer_block_ts" "not-a-number"
no_defer_check_post_block_reprompt
assert_eq "N4a corrupt content -> no event recorded" "0" "$(count_events no-defer-mode post-block-reprompt)"
flag_after="$(read_state "last_no_defer_block_ts")"
assert_eq "N4b corrupt content cleared" "" "${flag_after}"

# ---------------------------------------------------------------
# N5: env override of reprompt window
# ---------------------------------------------------------------
# 90 seconds ago — outside default 60s, inside override 120s.
: > "${gate_events}"
write_state "last_no_defer_block_ts" "$(( now_ts - 90 ))"
OMC_NO_DEFER_REPROMPT_WINDOW_SECS=120 no_defer_check_post_block_reprompt
assert_eq "N5 widened window captures 90s-old block" "1" "$(count_events no-defer-mode post-block-reprompt)"

# ---------------------------------------------------------------
# N6: window=0 or non-numeric env falls back to default
# ---------------------------------------------------------------
: > "${gate_events}"
write_state "last_no_defer_block_ts" "$(( now_ts - 90 ))"
OMC_NO_DEFER_REPROMPT_WINDOW_SECS="bogus" no_defer_check_post_block_reprompt
assert_eq "N6a non-numeric env -> default 60s applied -> no event for 90s-old block" \
  "0" "$(count_events no-defer-mode post-block-reprompt)"

: > "${gate_events}"
write_state "last_no_defer_block_ts" "$(( now_ts - 90 ))"
OMC_NO_DEFER_REPROMPT_WINDOW_SECS="0" no_defer_check_post_block_reprompt
assert_eq "N6b zero env -> default 60s applied -> no event for 90s-old block" \
  "0" "$(count_events no-defer-mode post-block-reprompt)"

# ---------------------------------------------------------------
# N7: future timestamp (clock skew) -> no event (negative age), flag cleared
# ---------------------------------------------------------------
: > "${gate_events}"
write_state "last_no_defer_block_ts" "$(( now_ts + 3600 ))"  # 1h in the future
no_defer_check_post_block_reprompt
assert_eq "N7a future ts -> no event (negative age skipped)" \
  "0" "$(count_events no-defer-mode post-block-reprompt)"
flag_after="$(read_state "last_no_defer_block_ts")"
assert_eq "N7b future ts -> flag still cleared" "" "${flag_after}"

# ---------------------------------------------------------------
# N8: lockstep — both call sites still reference the state key
# ---------------------------------------------------------------
STOP_GUARD="${SCRIPTS_DIR}/stop-guard.sh"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

if grep -q 'write_state "last_no_defer_block_ts"' "${STOP_GUARD}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: N8a lockstep — stop-guard.sh no longer writes last_no_defer_block_ts\n' >&2
  fail=$((fail + 1))
fi

if grep -q 'no_defer_check_post_block_reprompt' "${ROUTER}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: N8b lockstep — prompt-intent-router.sh no longer calls the helper\n' >&2
  fail=$((fail + 1))
fi

printf '\nno-defer FP observability tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
