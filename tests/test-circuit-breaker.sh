#!/usr/bin/env bash
# Regression net for v1.44-pre Port 1 — circuit-breaker.sh (PostToolUse:Bash).
#
# Asserts the mechanical complement of `core.md:128`: 3 consecutive
# same-target Bash failures emit a revert+oracle directive and set a 60s
# quiet window suppressing re-fires. Counter resets on success on the
# same target; cross-target failures do NOT chain (per the "same target"
# semantics).
#
# Cross-ref: bundle/dot-claude/skills/autowork/scripts/circuit-breaker.sh;
# metis F-2 (omc_hook_tool_failed canonicalization), F-6 (quiet window),
# F-7 (background invocation skip).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t cb-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

# .ulw_active sentinel — hook fast-path checks ${HOME}/.claude/quality-pack/state/.ulw_active
mkdir -p "${_test_home}/.claude/quality-pack/state"
touch "${_test_home}/.claude/quality-pack/state/.ulw_active"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

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
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    unexpected needle=%q in haystack\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

_cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup EXIT

# Drive the hook with a synthesized PostToolUse payload.
# Args: sid, tool_input.command (or "" for missing), exit_code, [run_in_background], [breaker_flag]
_drive() {
  local sid="$1" cmd="$2" exit_code="$3" rin_bg="${4:-false}" flag="${5:-on}"
  local payload
  payload="$(jq -nc \
    --arg sid "${sid}" \
    --arg cmd "${cmd}" \
    --argjson exit "${exit_code}" \
    --argjson rb "${rin_bg}" \
    --arg cwd "/tmp/test" \
    '{
       session_id: $sid,
       tool_name: "Bash",
       tool_input: { command: $cmd, run_in_background: $rb },
       tool_response: { exit_code: $exit, is_error: ($exit != 0) },
       cwd: $cwd
     }')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_CIRCUIT_BREAKER="${flag}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/circuit-breaker.sh" \
    <<<"${payload}" 2>/dev/null || true
}

_read_state() {
  local sid="$1" key="$2"
  local sf="${_test_state_root}/${sid}/session_state.json"
  [[ -f "${sf}" ]] || { printf ''; return; }
  jq -r --arg k "${key}" '.[$k] // ""' "${sf}" 2>/dev/null || true
}

_init_sid() {
  local sid="$1"
  local sdir="${_test_state_root}/${sid}"
  mkdir -p "${sdir}"
  # workflow_mode=ultrawork so is_ultrawork_mode() passes.
  printf '{"workflow_mode":"ultrawork"}\n' >"${sdir}/session_state.json"
  printf 'fake/file.sh\n' >"${sdir}/edited_files.log"
}

# ---------------------------------------------------------------------------
# T1: flag off → exit 0 silently, no state mutation
# ---------------------------------------------------------------------------
printf 'T1: flag off → no-op\n'
sid="t1-${RANDOM}"
_init_sid "${sid}"
out="$(_drive "${sid}" "npm test" 1 false off)"
assert_eq "T1: no output when flag off" "" "${out}"
assert_eq "T1: circuit_count not set" "" "$(_read_state "${sid}" "circuit_count")"

# ---------------------------------------------------------------------------
# T2: first failure → count=1, no directive
# ---------------------------------------------------------------------------
printf 'T2: first failure increments count to 1\n'
sid="t2-${RANDOM}"
_init_sid "${sid}"
out="$(_drive "${sid}" "npm test" 1)"
assert_eq "T2: first failure count=1" "1" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T2: no directive emitted" "CIRCUIT BROKEN" "${out}"

# ---------------------------------------------------------------------------
# T3: 2 same-target failures → count=2, still no directive
# ---------------------------------------------------------------------------
printf 'T3: 2 failures, count=2, no fire\n'
sid="t3-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" "npm test" 1 >/dev/null
out="$(_drive "${sid}" "npm test" 1)"
assert_eq "T3: count=2" "2" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T3: no directive at 2 failures" "CIRCUIT BROKEN" "${out}"

# ---------------------------------------------------------------------------
# T4: 3 consecutive same-target failures → fire directive, reset counter
# ---------------------------------------------------------------------------
printf 'T4: 3 consecutive failures fire breaker\n'
sid="t4-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" "npm test" 1 >/dev/null
_drive "${sid}" "npm test" 1 >/dev/null
out="$(_drive "${sid}" "npm test" 1)"
assert_contains "T4: directive emitted" "CIRCUIT BROKEN" "${out}"
assert_contains "T4: directive references oracle" "oracle" "${out}"
assert_contains "T4: directive uses additionalContext schema" "additionalContext" "${out}"
assert_eq "T4: counter reset after fire" "" "$(_read_state "${sid}" "circuit_count")"
quiet_until="$(_read_state "${sid}" "circuit_quiet_until")"
if [[ -n "${quiet_until}" && "${quiet_until}" -gt "$(date +%s)" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4: circuit_quiet_until not set in the future (got: %s)\n' "${quiet_until}" >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# T5: success between failures resets count
# ---------------------------------------------------------------------------
printf 'T5: success on same target resets counter\n'
sid="t5-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" "npm test" 1 >/dev/null
_drive "${sid}" "npm test" 1 >/dev/null
_drive "${sid}" "npm test" 0 >/dev/null  # success on same target
out="$(_drive "${sid}" "npm test" 1)"
assert_eq "T5: counter=1 after reset-then-fail" "1" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T5: no fire after reset" "CIRCUIT BROKEN" "${out}"

# ---------------------------------------------------------------------------
# T6: different target between failures does NOT chain
# ---------------------------------------------------------------------------
printf 'T6: cross-target failures do not chain\n'
sid="t6-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" "npm test" 1 >/dev/null
_drive "${sid}" "make build" 1 >/dev/null  # different target
out="$(_drive "${sid}" "npm test" 1)"
# After 3 ops: npm(fail)=1, make(fail)=1 (replaces target), npm(fail)=1 (replaces target again).
# Counter at end = 1 on "npm" target. No fire.
assert_eq "T6: cross-target → count=1" "1" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T6: cross-target → no fire" "CIRCUIT BROKEN" "${out}"

# ---------------------------------------------------------------------------
# T7: background invocations are skipped (F-7)
# ---------------------------------------------------------------------------
printf 'T7: background invocations skipped\n'
sid="t7-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" "npm test" 1 true >/dev/null  # run_in_background=true
_drive "${sid}" "npm test" 1 true >/dev/null
out="$(_drive "${sid}" "npm test" 1 true)"
assert_eq "T7: bg failure not counted" "" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T7: no fire on bg failures" "CIRCUIT BROKEN" "${out}"

# ---------------------------------------------------------------------------
# T8: status:failed shape (omc_hook_tool_failed canonicalization, F-2)
# ---------------------------------------------------------------------------
printf 'T8: status:failed shape detected via omc_hook_tool_failed\n'
sid="t8-${RANDOM}"
_init_sid "${sid}"
# Use a payload with status:failed but exit_code=0 — must still register as failure.
_drive_status() {
  local sid="$1"
  local payload
  payload="$(jq -nc --arg sid "${sid}" '{
    session_id: $sid,
    tool_name: "Bash",
    tool_input: { command: "npm test", run_in_background: false },
    tool_response: { status: "failed" },
    cwd: "/tmp/test"
  }')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_CIRCUIT_BREAKER=on \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/circuit-breaker.sh" \
    <<<"${payload}" 2>/dev/null || true
}
_drive_status "${sid}" >/dev/null
assert_eq "T8: status:failed → count=1" "1" "$(_read_state "${sid}" "circuit_count")"

# ---------------------------------------------------------------------------
# T9: quiet window suppresses re-fire within 60s (F-6)
# ---------------------------------------------------------------------------
printf 'T9: quiet window after fire\n'
sid="t9-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" "npm test" 1 >/dev/null
_drive "${sid}" "npm test" 1 >/dev/null
_drive "${sid}" "npm test" 1 >/dev/null  # fires here
# Counter reset; quiet_until set ~60s in future. Next failure within window
# must NOT increment counter and must NOT re-fire.
out="$(_drive "${sid}" "npm test" 1)"
assert_eq "T9: quiet window blocks counter increment" "" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T9: no re-fire during quiet window" "CIRCUIT BROKEN" "${out}"

# ---------------------------------------------------------------------------
# T10: non-Bash tools are skipped
# ---------------------------------------------------------------------------
printf 'T10: non-Bash tools are skipped\n'
sid="t10-${RANDOM}"
_init_sid "${sid}"
_drive_non_bash() {
  local payload
  payload="$(jq -nc --arg sid "$1" '{
    session_id: $sid,
    tool_name: "Edit",
    tool_input: { },
    tool_response: { exit_code: 1, is_error: true },
    cwd: "/tmp/test"
  }')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_CIRCUIT_BREAKER=on \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/circuit-breaker.sh" \
    <<<"${payload}" 2>/dev/null || true
}
_drive_non_bash "${sid}" >/dev/null
_drive_non_bash "${sid}" >/dev/null
out="$(_drive_non_bash "${sid}")"
assert_eq "T10: Edit failures not counted" "" "$(_read_state "${sid}" "circuit_count")"
assert_not_contains "T10: Edit failures don't fire" "CIRCUIT BROKEN" "${out}"

printf '\ntest-circuit-breaker: %d passed, %d failed\n' "${pass}" "${fail}"
exit "${fail}"
