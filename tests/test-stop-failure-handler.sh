#!/usr/bin/env bash
#
# Tests for quality-pack/scripts/stop-failure-handler.sh — the StopFailure
# hook that captures rate-limit and other terminal-stop signals into a
# per-session resume_request.json sidecar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HANDLER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/stop-failure-handler.sh"

ORIG_HOME="${HOME}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
}

teardown_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}" 2>/dev/null || true
}

trap 'teardown_test' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected file: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [[ ! -e "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected absent: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

# Initialize a session with optional state and rate_limit_status sidecar.
init_session() {
  local sid="$1"
  local objective="${2:-}"
  local last_prompt="${3:-}"
  local sidecar_json="${4:-}"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${state_dir}"
  jq -nc \
    --arg objective "${objective}" \
    --arg prompt "${last_prompt}" \
    --arg ts "$(date +%s)" \
    '{current_objective: $objective, last_user_prompt: $prompt, session_start_ts: $ts}' \
    > "${state_dir}/session_state.json"
  if [[ -n "${sidecar_json}" ]]; then
    printf '%s' "${sidecar_json}" > "${state_dir}/rate_limit_status.json"
  fi
}

# Pipe a hook payload to the handler script.
run_handler() {
  local payload="$1"
  printf '%s' "${payload}" | bash "${HANDLER}" 2>/dev/null || true
}

resume_path() {
  printf '%s/.claude/quality-pack/state/%s/resume_request.json' "${TEST_HOME}" "$1"
}

# ---------------------------------------------------------------------------
# Test 1: rate_limit matcher with sidecar present → rate_limited:true,
# resets_at_ts pulled from sidecar (earliest of the two windows).
# ---------------------------------------------------------------------------
setup_test

sidecar='{"five_hour":{"used_percentage":85,"resets_at_ts":1738425600},"seven_day":{"used_percentage":42,"resets_at_ts":1738857600},"captured_at_ts":1738400000}'
init_session "sess-rl" "Ship Wave A" "okay, do wave A." "${sidecar}"

run_handler "$(jq -nc \
  --arg sid "sess-rl" \
  '{session_id:$sid, matcher:"rate_limit", hook_event_name:"StopFailure", cwd:"/repo", transcript_path:"/tmp/t.jsonl"}')"

target="$(resume_path sess-rl)"
assert_file_exists "rate_limit: resume_request.json written" "${target}"
assert_eq "rate_limit: rate_limited=true" "true" "$(jq -r '.rate_limited' "${target}")"
assert_eq "rate_limit: matcher preserved" "rate_limit" "$(jq -r '.matcher' "${target}")"
assert_eq "rate_limit: resets_at_ts uses earliest window" "1738425600" "$(jq -r '.resets_at_ts' "${target}")"
assert_eq "rate_limit: original_objective preserved" "Ship Wave A" "$(jq -r '.original_objective' "${target}")"
assert_eq "rate_limit: last_user_prompt preserved" "okay, do wave A." "$(jq -r '.last_user_prompt' "${target}")"
assert_eq "rate_limit: session_id preserved" "sess-rl" "$(jq -r '.session_id' "${target}")"
assert_eq "rate_limit: cwd preserved" "/repo" "$(jq -r '.cwd' "${target}")"
assert_eq "rate_limit: rate_limit_snapshot.five_hour.resets_at_ts persisted" \
  "1738425600" "$(jq -r '.rate_limit_snapshot.five_hour.resets_at_ts' "${target}")"
# Wave 3 forward-compat fields — present and seeded so the watchdog can
# round-trip without a schema migration on artifacts already on disk.
assert_eq "rate_limit: schema_version=1" "1" "$(jq -r '.schema_version' "${target}")"
assert_eq "rate_limit: resume_attempts=0" "0" "$(jq -r '.resume_attempts' "${target}")"
assert_eq "rate_limit: model_id present (null when not recorded)" "null" \
  "$(jq -r '.model_id' "${target}")"
# Wave 1 added project_key (additive forward-compat) — must be present
# even when null (cwd does not exist in the test fixture's filesystem,
# so _omc_project_key is not invoked → field is null, not absent).
assert_eq "rate_limit: project_key key present" "true" "$(jq 'has("project_key")' "${target}")"
assert_eq "rate_limit: project_key=null when cwd does not exist" "null" \
  "$(jq -r '.project_key' "${target}")"

teardown_test

# ---------------------------------------------------------------------------
# Test 2: authentication_failed matcher → rate_limited:false, resets_at_ts:null.
# Still writes the row (useful for /ulw-report visibility).
# ---------------------------------------------------------------------------
setup_test

init_session "sess-auth" "Run tests" "fix login" ""

run_handler "$(jq -nc \
  --arg sid "sess-auth" \
  '{session_id:$sid, matcher:"authentication_failed", hook_event_name:"StopFailure", cwd:"/repo"}')"

target="$(resume_path sess-auth)"
assert_file_exists "auth_failed: resume_request.json written" "${target}"
assert_eq "auth_failed: rate_limited=false" "false" "$(jq -r '.rate_limited' "${target}")"
assert_eq "auth_failed: matcher=authentication_failed" "authentication_failed" \
  "$(jq -r '.matcher' "${target}")"
assert_eq "auth_failed: resets_at_ts=null" "null" "$(jq -r '.resets_at_ts' "${target}")"
assert_eq "auth_failed: rate_limit_snapshot=null when no sidecar" "null" \
  "$(jq -r '.rate_limit_snapshot' "${target}")"

teardown_test

# ---------------------------------------------------------------------------
# Test 3: missing SESSION_ID → exit 0 cleanly, no file written, no crash.
# ---------------------------------------------------------------------------
setup_test

set +e
out="$(printf '%s' '{"matcher":"rate_limit"}' | bash "${HANDLER}" 2>&1)"
rc=$?
set -e

assert_eq "no session_id: exit code 0" "0" "${rc}"
# Nothing under state/ should have been created.
state_dirs="$(ls -A "${TEST_HOME}/.claude/quality-pack/state" 2>/dev/null | grep -v '^\.' || true)"
assert_eq "no session_id: no state dir created" "" "${state_dirs}"

teardown_test

# ---------------------------------------------------------------------------
# Test 4: rate_limit matcher with NO sidecar → rate_limited:true,
# resets_at_ts:null (graceful degradation when statusline never wrote one).
# ---------------------------------------------------------------------------
setup_test

init_session "sess-bare" "improve harness" "do it" ""

run_handler "$(jq -nc \
  --arg sid "sess-bare" \
  '{session_id:$sid, matcher:"rate_limit", hook_event_name:"StopFailure"}')"

target="$(resume_path sess-bare)"
assert_file_exists "no sidecar: resume_request.json written" "${target}"
assert_eq "no sidecar: rate_limited=true" "true" "$(jq -r '.rate_limited' "${target}")"
assert_eq "no sidecar: resets_at_ts=null" "null" "$(jq -r '.resets_at_ts' "${target}")"
assert_eq "no sidecar: original_objective preserved" "improve harness" \
  "$(jq -r '.original_objective' "${target}")"

teardown_test

# ---------------------------------------------------------------------------
# Test 5: malformed sidecar JSON → treated as null, hook still succeeds.
# ---------------------------------------------------------------------------
setup_test

init_session "sess-broken" "X" "Y" "this is not json"

run_handler "$(jq -nc \
  --arg sid "sess-broken" \
  '{session_id:$sid, matcher:"rate_limit", hook_event_name:"StopFailure"}')"

target="$(resume_path sess-broken)"
assert_file_exists "broken sidecar: resume_request.json written" "${target}"
assert_eq "broken sidecar: rate_limit_snapshot=null" "null" \
  "$(jq -r '.rate_limit_snapshot' "${target}")"
assert_eq "broken sidecar: resets_at_ts=null" "null" "$(jq -r '.resets_at_ts' "${target}")"

teardown_test

# ---------------------------------------------------------------------------
# Test 6: empty matcher → normalized to "unknown" (keeps row auditable
# even if Claude Code drops the matcher field on this event).
# ---------------------------------------------------------------------------
setup_test

init_session "sess-empty" "task" "prompt" ""

run_handler "$(jq -nc \
  --arg sid "sess-empty" \
  '{session_id:$sid, hook_event_name:"StopFailure"}')"

target="$(resume_path sess-empty)"
assert_file_exists "empty matcher: resume_request.json written" "${target}"
assert_eq "empty matcher: normalized to 'unknown'" "unknown" "$(jq -r '.matcher' "${target}")"
assert_eq "empty matcher: rate_limited=false" "false" "$(jq -r '.rate_limited' "${target}")"

teardown_test

# ---------------------------------------------------------------------------
# Test 7: gate_events.jsonl row appended with stop-failure-captured event.
# ---------------------------------------------------------------------------
setup_test

sidecar='{"five_hour":{"used_percentage":99,"resets_at_ts":1738999999},"captured_at_ts":1738400000}'
init_session "sess-evt" "" "" "${sidecar}"

run_handler "$(jq -nc \
  --arg sid "sess-evt" \
  '{session_id:$sid, matcher:"rate_limit", hook_event_name:"StopFailure"}')"

events_file="${TEST_HOME}/.claude/quality-pack/state/sess-evt/gate_events.jsonl"
assert_file_exists "events: gate_events.jsonl appended" "${events_file}"
assert_eq "events: gate is stop-failure (canonical helper shape)" "stop-failure" \
  "$(jq -r 'select(.event=="stop-failure-captured") | .gate' "${events_file}" | head -1)"
assert_eq "events: event name is stop-failure-captured" "stop-failure-captured" \
  "$(jq -r 'select(.event=="stop-failure-captured") | .event' "${events_file}" | head -1)"
assert_eq "events: ts is numeric (helper coerces via --argjson)" "number" \
  "$(jq -r 'select(.event=="stop-failure-captured") | .ts | type' "${events_file}" | head -1)"
assert_eq "events: matcher in details" "rate_limit" \
  "$(jq -r 'select(.event=="stop-failure-captured") | .details.matcher' "${events_file}" | head -1)"
assert_eq "events: rate_limited in details" "true" \
  "$(jq -r 'select(.event=="stop-failure-captured") | .details.rate_limited' "${events_file}" | head -1)"
assert_eq "events: resets_at_ts in details" "1738999999" \
  "$(jq -r 'select(.event=="stop-failure-captured") | .details.resets_at_ts' "${events_file}" | head -1)"

teardown_test

# ---------------------------------------------------------------------------
# Test 7b: full matcher vocabulary documented by Claude Code's hooks docs
# (rate_limit, authentication_failed, billing_error, invalid_request,
# server_error, max_output_tokens, unknown). All non-rate-limit matchers
# round-trip identically with rate_limited=false.
# ---------------------------------------------------------------------------
for m in rate_limit authentication_failed billing_error invalid_request server_error max_output_tokens unknown; do
  setup_test
  init_session "sess-${m}" "obj-${m}" "prompt-${m}" ""
  run_handler "$(jq -nc --arg sid "sess-${m}" --arg matcher "${m}" \
    '{session_id:$sid, matcher:$matcher, hook_event_name:"StopFailure"}')"
  target="$(resume_path "sess-${m}")"
  assert_file_exists "matcher ${m}: resume_request.json written" "${target}"
  assert_eq "matcher ${m}: matcher round-trips" "${m}" "$(jq -r '.matcher' "${target}")"
  if [[ "${m}" == "rate_limit" ]]; then
    expected_rl="true"
  else
    expected_rl="false"
  fi
  assert_eq "matcher ${m}: rate_limited=${expected_rl}" "${expected_rl}" \
    "$(jq -r '.rate_limited' "${target}")"
  teardown_test
done

# ---------------------------------------------------------------------------
# Test 8: only seven_day window in sidecar → resets_at_ts uses it (no
# five_hour value to compete with).
# ---------------------------------------------------------------------------
setup_test

sidecar='{"seven_day":{"used_percentage":15,"resets_at_ts":1738900000},"captured_at_ts":1738400000}'
init_session "sess-7d" "" "" "${sidecar}"

run_handler "$(jq -nc \
  --arg sid "sess-7d" \
  '{session_id:$sid, matcher:"rate_limit"}')"

target="$(resume_path sess-7d)"
assert_eq "seven_day-only: resets_at_ts pulled from seven_day" "1738900000" \
  "$(jq -r '.resets_at_ts' "${target}")"

teardown_test

# ---------------------------------------------------------------------------
# Test 9: model_id round-trip — when current_model_id is in session_state,
# resume_request.json captures it for Wave 3 watchdog re-dispatch.
# ---------------------------------------------------------------------------
setup_test
state_dir="${TEST_HOME}/.claude/quality-pack/state/sess-model"
mkdir -p "${state_dir}"
jq -nc --arg ts "$(date +%s)" \
  '{current_objective:"X", last_user_prompt:"Y", current_model_id:"claude-opus-4-7", session_start_ts:$ts}' \
  > "${state_dir}/session_state.json"
run_handler "$(jq -nc --arg sid "sess-model" '{session_id:$sid, matcher:"rate_limit"}')"
target="$(resume_path sess-model)"
assert_eq "model_id: round-trips from state" "claude-opus-4-7" "$(jq -r '.model_id' "${target}")"
teardown_test

# ---------------------------------------------------------------------------
# Test 10: stop_failure_capture=off opt-out — env var suppresses the
# entire capture (no resume_request.json, no gate_events row).
# ---------------------------------------------------------------------------
setup_test
init_session "sess-optout" "obj" "prompt" ""
OMC_STOP_FAILURE_CAPTURE=off run_handler "$(jq -nc --arg sid "sess-optout" \
  '{session_id:$sid, matcher:"rate_limit"}')"
assert_file_absent "opt-out: no resume_request.json" "$(resume_path sess-optout)"
assert_file_absent "opt-out: no gate_events.jsonl" \
  "${TEST_HOME}/.claude/quality-pack/state/sess-optout/gate_events.jsonl"
teardown_test

# ---------------------------------------------------------------------------
# Test 11: stop_failure_capture=off via project conf — same effect via
# `.claude/oh-my-claude.conf` walk-up rather than env var.
# ---------------------------------------------------------------------------
setup_test
init_session "sess-optout-conf" "obj" "prompt" ""
project_conf_dir="${TEST_HOME}/proj/.claude"
mkdir -p "${project_conf_dir}"
printf 'stop_failure_capture=off\n' > "${project_conf_dir}/oh-my-claude.conf"
( cd "${TEST_HOME}/proj" && \
  printf '%s' "$(jq -nc --arg sid "sess-optout-conf" '{session_id:$sid, matcher:"rate_limit"}')" \
  | bash "${HANDLER}" 2>/dev/null || true )
assert_file_absent "opt-out via conf: no resume_request.json" "$(resume_path sess-optout-conf)"
teardown_test

# ---------------------------------------------------------------------------
# Test 12: Wave 1 addition — project_key captured from a real cwd with a
# git remote. Verifies the additive forward-compat field that Wave 1's
# SessionStart resume hint uses for project-key match scope.
# ---------------------------------------------------------------------------
setup_test
real_cwd="${TEST_HOME}/realproj"
mkdir -p "${real_cwd}"
(
  cd "${real_cwd}" || exit 1
  git init -q -b main 2>/dev/null
  git config user.email test@example.com
  git config user.name test
  git remote add origin https://github.com/example/proj.git
) >/dev/null 2>&1
init_session "sess-pk" "Ship Wave 1." "/ulw foo." ""
run_handler "$(jq -nc \
  --arg sid "sess-pk" \
  --arg cwd "${real_cwd}" \
  '{session_id:$sid, matcher:"rate_limit", hook_event_name:"StopFailure", cwd:$cwd}')"
target="$(resume_path sess-pk)"
assert_file_exists "project_key: resume_request.json written" "${target}"
captured_pk="$(jq -r '.project_key' "${target}")"
# 12-char lowercase hex string per _omc_project_key (`shasum -a 256 | cut -c1-12`).
if [[ "${captured_pk}" =~ ^[0-9a-f]{12}$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: project_key matches expected 12-hex shape\n    actual=%s\n' "${captured_pk}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

printf '\n=== test-stop-failure-handler: %d passed, %d failed ===\n' "${pass}" "${fail}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
