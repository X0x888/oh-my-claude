#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_HOME="$(mktemp -d -t exemplifying-scope-home-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
TEST_PROJECT="${TEST_HOME}/project"
mkdir -p "${TEST_HOME}/.claude/quality-pack" "${TEST_STATE_ROOT}"
mkdir -p "${TEST_PROJECT}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${TEST_HOME}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${TEST_HOME}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing=%s\n    actual=%s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected=%s\n    actual=%s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

run_router() {
  local sid="$1"
  local prompt="$2"
  local hook_json
  hook_json="$(jq -nc --arg sid "${sid}" --arg p "${prompt}" --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid, prompt:$p, cwd:$cwd}')"
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash -c 'cd "$1" && bash "$2"' _ "${TEST_PROJECT}" "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<< "${hook_json}" 2>/dev/null || true
}

run_stop() {
  local sid="$1"
  local hook_json
  hook_json="$(jq -nc --arg sid "${sid}" \
    '{session_id:$sid, stop_hook_active:"false", last_assistant_message:"Done."}')"
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash -c 'cd "$1" && bash "$2"' _ "${TEST_PROJECT}" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh" \
    <<< "${hook_json}" 2>/dev/null || true
}

scope_script() {
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "${TEST_PROJECT}" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-scope-checklist.sh" "$@"
}

sid="exemplifying-scope-${RANDOM}"
prompt="ulw enhance the statusline UX, for instance adding reset countdown. Implement and commit as needed."

printf 'Test 1: router marks exemplifying-scope requirement and injects directive\n'
router_out="$(run_router "${sid}" "${prompt}")"
state_file="${TEST_STATE_ROOT}/${sid}/session_state.json"
assert_eq "router set required flag" "1" "$(jq -r '.exemplifying_scope_required // ""' "${state_file}")"
assert_eq "router classified execution" "execution" "$(jq -r '.task_intent // ""' "${state_file}")"
assert_contains "directive emitted" "EXEMPLIFYING SCOPE DETECTED" "${router_out}"
assert_contains "directive names checklist script" "record-scope-checklist.sh init" "${router_out}"

printf 'Test 2: stop-guard blocks when checklist is missing\n'
stop_out="$(run_stop "${sid}")"
assert_eq "missing checklist blocks" "block" "$(jq -r '.decision // ""' <<< "${stop_out}")"
assert_contains "missing reason names gate" "Exemplifying-scope gate" "${stop_out}"
assert_contains "missing reason rejects literal-only work" "literal example" "${stop_out}"

printf 'Test 3: checklist init records pending sibling items\n'
init_out="$(printf '%s\n' '[
  {"summary":"Show reset countdown when rate-limit data exists","surface":"statusline"},
  {"summary":"Show stale-data warning when reset metadata is old","surface":"statusline"}
]' | scope_script init)"
assert_contains "init reports pending count" "pending=2" "${init_out}"
assert_eq "scope file has prompt timestamp" \
  "$(jq -r '.exemplifying_scope_prompt_ts // "0"' "${state_file}")" \
  "$(jq -r '.source_prompt_ts // "0"' "${TEST_STATE_ROOT}/${sid}/exemplifying_scope.json")"

printf 'Test 4: stop-guard blocks while checklist items are pending\n'
stop_out="$(run_stop "${sid}")"
assert_eq "pending checklist blocks" "block" "$(jq -r '.decision // ""' <<< "${stop_out}")"
assert_contains "pending reason includes item id" "S-001" "${stop_out}"

printf 'Test 5: declined items require a concrete WHY\n'
set +e
bad_out="$(scope_script status S-002 declined "out of scope" 2>&1)"
bad_rc=$?
set -e
assert_eq "bad decline exits 2" "2" "${bad_rc}"
assert_contains "bad decline rejected" "must name a concrete WHY" "${bad_out}"

printf 'Test 6: shipped/declined checklist with WHY satisfies stop-guard\n'
scope_script status S-001 shipped "implemented in statusline render path" >/dev/null
scope_script status S-002 declined "requires telemetry timestamp source that statusline does not currently receive" >/dev/null
counts="$(scope_script counts)"
assert_contains "counts no pending" "pending=0" "${counts}"
stop_out="$(run_stop "${sid}")"
assert_eq "satisfied checklist allows stop" "" "${stop_out}"

printf 'Test 7: new non-exemplifying execution clears old requirement\n'
router_out="$(run_router "${sid}" "ulw fix the auth bug in lib/login.ts:42")"
assert_eq "required flag cleared" "" "$(jq -r '.exemplifying_scope_required // ""' "${state_file}")"
assert_not_contains "no exemplifying directive" "EXEMPLIFYING SCOPE DETECTED" "${router_out}"

printf 'Test 8: gate-off mode keeps the soft directive but does not arm the stop gate\n'
sid_gate_off="exemplifying-scope-off-${RANDOM}"
old_gate="${OMC_EXEMPLIFYING_SCOPE_GATE-__unset__}"
export OMC_EXEMPLIFYING_SCOPE_GATE=off
router_out="$(run_router "${sid_gate_off}" "${prompt}")"
state_file_gate_off="${TEST_STATE_ROOT}/${sid_gate_off}/session_state.json"
stop_out="$(run_stop "${sid_gate_off}")"
if [[ "${old_gate}" == "__unset__" ]]; then
  unset OMC_EXEMPLIFYING_SCOPE_GATE
else
  export OMC_EXEMPLIFYING_SCOPE_GATE="${old_gate}"
fi
assert_eq "gate off leaves required flag empty" "" "$(jq -r '.exemplifying_scope_required // ""' "${state_file_gate_off}")"
assert_contains "gate off still emits widening directive" "EXEMPLIFYING SCOPE DETECTED" "${router_out}"
assert_not_contains "gate off directive does not promise hard gate" "record-scope-checklist.sh init" "${router_out}"
assert_eq "gate off stop allows without checklist" "" "${stop_out}"

printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
