#!/usr/bin/env bash
# test-posttool-dispatch.sh — focused regression for posttool-dispatch.sh
# (v1.48 W3.1 hook consolidation) and the common.sh re-source guard it
# depends on.
#
# The consolidation's contract, pinned here:
#   1. One dispatcher process replaces the four per-call processes, with
#      byte-identical handler scripts sourced in pipeline subshells.
#   2. Bash calls run all four handlers; non-Bash calls run timing only.
#   3. The three recorders stay silent; circuit-breaker's hook JSON passes
#      through the dispatcher stdout unmodified.
#   4. One handler's early `exit` (or failure) cannot starve the others.
#   5. settings.patch.json wires exactly one universal PostToolUse entry to
#      the dispatcher and none to the three folded Bash-matcher scripts —
#      while the mcp__.* record-verification matcher survives (that path
#      still invokes the script standalone).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISPATCH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/posttool-dispatch.sh"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
PATCH_JSON="${REPO_ROOT}/config/settings.patch.json"

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
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1" rc="$2"
  if [[ "${rc}" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

ORIG_HOME="${HOME}"
setup_session() {
  local sid="$1"
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state/${sid}"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
  jq -nc --arg ts "$(date +%s)" '{
    workflow_mode: "ultrawork",
    task_domain: "coding",
    task_intent: "execution",
    current_objective: "test",
    last_user_prompt_ts: $ts
  }' > "${TEST_HOME}/.claude/quality-pack/state/${sid}/session_state.json"
}

teardown_session() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}" 2>/dev/null || true
}

run_dispatch() {
  local payload="$1"
  printf '%s' "${payload}" | bash "${DISPATCH}" 2>/dev/null || true
}

bash_payload() {
  local sid="$1" cmd="$2" resp="$3"
  jq -nc --arg s "${sid}" --arg c "${cmd}" --arg r "${resp}" \
    '{session_id: $s, tool_name: "Bash", tool_use_id: "tu-1",
      tool_input: {command: $c}, tool_response: $r, cwd: "/tmp"}'
}

fail_payload() {
  local sid="$1" cmd="$2"
  jq -nc --arg s "${sid}" --arg c "${cmd}" \
    '{session_id: $s, tool_name: "Bash", tool_use_id: "tu-f",
      tool_input: {command: $c},
      tool_response: {exit_code: 1, stdout: "boom"}, cwd: "/tmp"}'
}

# ----------------------------------------------------------------------
printf 'T1: Bash call runs timing AND verification recorder in one process\n'
setup_session "d1"
out_t1="$(run_dispatch "$(bash_payload d1 'bash tests/test-sample.sh' '12 passed, 0 failed')")"
assert_eq "T1: recorders stay silent on stdout" "" "${out_t1}"
timing_file="${TEST_HOME}/.claude/quality-pack/state/d1/timing.jsonl"
rc=0; [[ -f "${timing_file}" ]] && grep -q '"kind":"end"' "${timing_file}" || rc=1
assert_true "T1: timing end row written" "${rc}"
state="${TEST_HOME}/.claude/quality-pack/state/d1/session_state.json"
assert_eq "T1: verification outcome recorded" "passed" \
  "$(jq -r '.last_verify_outcome // ""' "${state}")"
rc=0; [[ -n "$(jq -r '.last_verify_ts // ""' "${state}")" ]] || rc=1
assert_true "T1: verification timestamp recorded" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T2: non-Bash call runs timing only\n'
setup_session "d2"
payload_t2="$(jq -nc '{session_id: "d2", tool_name: "Read", tool_use_id: "tu-2",
  tool_input: {file_path: "/tmp/x"}, tool_response: "content"}')"
out_t2="$(run_dispatch "${payload_t2}")"
assert_eq "T2: silent stdout" "" "${out_t2}"
timing_file="${TEST_HOME}/.claude/quality-pack/state/d2/timing.jsonl"
rc=0; [[ -f "${timing_file}" ]] && grep -q '"kind":"end"' "${timing_file}" || rc=1
assert_true "T2: timing end row written for non-Bash tool" "${rc}"
assert_eq "T2: no verification state for non-Bash tool" "" \
  "$(jq -r '.last_verify_ts // ""' "${TEST_HOME}/.claude/quality-pack/state/d2/session_state.json")"
teardown_session

# ----------------------------------------------------------------------
printf 'T3: circuit-breaker output passes through; timing still records\n'
setup_session "d3"
p="$(fail_payload d3 'flaky-build --retry')"
out_a="$(run_dispatch "${p}")"
out_b="$(run_dispatch "${p}")"
out_c="$(run_dispatch "${p}")"
assert_eq "T3: first failure silent" "" "${out_a}"
assert_eq "T3: second failure silent" "" "${out_b}"
assert_contains "T3: third failure fires the breaker" "CIRCUIT BROKEN" "${out_c}"
rc=0; jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 <<<"${out_c}" || rc=$?
assert_true "T3: breaker JSON passes through intact" "${rc}"
timing_file="${TEST_HOME}/.claude/quality-pack/state/d3/timing.jsonl"
assert_eq "T3: all three calls produced timing rows" "3" \
  "$(grep -c '"kind":"end"' "${timing_file}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T4: a handler early-exit cannot starve later handlers\n'
# Payload with NO session_id: posttool-timing exits 0 immediately (its
# subshell), record-verification exits too — but the dispatcher itself
# must still exit 0 and stay silent, not abort under set -e.
setup_session "d4"
out_t4="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":"hi"}' \
  | bash "${DISPATCH}" 2>/dev/null)"; rc=$?
assert_eq "T4: dispatcher exit 0 despite handler early-exits" "0" "${rc}"
assert_eq "T4: silent" "" "${out_t4}"
teardown_session

# ----------------------------------------------------------------------
printf 'T5: common.sh re-source guard short-circuits and tops up lazy libs\n'
rc=0
bash -c "
  set -euo pipefail
  export OMC_LAZY_CLASSIFIER=1
  . '${COMMON}'
  [[ -n \"\${_OMC_COMMON_SOURCED}\" ]] || exit 1
  # Re-source with classifier wanted eagerly: guard must load it.
  unset OMC_LAZY_CLASSIFIER
  . '${COMMON}'
  # classifier symbol must now exist
  declare -F is_imperative_request >/dev/null || exit 2
" 2>/dev/null || rc=$?
assert_eq "T5: guarded re-source loads missing lib and returns" "0" "${rc}"

# ----------------------------------------------------------------------
printf 'T6: settings.patch.json wiring matches the consolidation\n'
assert_eq "T6: exactly one universal PostToolUse entry" "1" \
  "$(jq -r '[.hooks.PostToolUse[] | select(has("matcher") | not)] | length' "${PATCH_JSON}")"
assert_contains "T6: universal entry is the dispatcher" "posttool-dispatch.sh" \
  "$(jq -r '[.hooks.PostToolUse[] | select(has("matcher") | not)][0].hooks[0].command' "${PATCH_JSON}")"
assert_eq "T6: no Bash-matcher entries remain" "0" \
  "$(jq -r '[.hooks.PostToolUse[] | select(.matcher == "Bash")] | length' "${PATCH_JSON}")"
assert_eq "T6: mcp record-verification matcher survives" "1" \
  "$(jq -r '[.hooks.PostToolUse[] | select(.matcher == "mcp__.*")] | length' "${PATCH_JSON}")"
rc=0; grep -q 'posttool-timing.sh' "${PATCH_JSON}" && rc=1
assert_true "T6: no direct posttool-timing wiring remains" "${rc}"

# ----------------------------------------------------------------------
printf '\n=== posttool-dispatch tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
