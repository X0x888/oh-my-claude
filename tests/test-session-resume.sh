#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESUME_SCRIPT="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-resume-handoff.sh"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
TEST_STATE_ROOT="${TEST_TMP}/state"
mkdir -p "${TEST_STATE_ROOT}"

# The resume script sources common.sh from ${HOME}/.claude/skills/autowork/scripts/.
# Create a fake HOME that symlinks to the repo bundle so we test against repo code.
FAKE_HOME="${TEST_TMP}/fakehome"
mkdir -p "${FAKE_HOME}/.claude/skills/autowork/scripts"
mkdir -p "${FAKE_HOME}/.claude/quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
  "${FAKE_HOME}/.claude/skills/autowork/scripts/common.sh"

cleanup() {
  rm -rf "${TEST_TMP}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local label="$1"
  local path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file not found: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

# Helper: run the resume script with given JSON, overriding STATE_ROOT.
# Writes output to _resume_output; sets _resume_exit.
_resume_output_file="${TEST_TMP}/.resume_output"
_resume_exit=0

run_resume() {
  local json="$1"
  _resume_exit=0
  printf '%s' "${json}" \
    | HOME="${FAKE_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" bash "${RESUME_SCRIPT}" \
    > "${_resume_output_file}" 2>/dev/null || _resume_exit=$?
}

resume_output() {
  cat "${_resume_output_file}" 2>/dev/null || true
}

# Helper: populate a source session with known state.
setup_source_session() {
  local source_id="$1"
  local source_dir="${TEST_STATE_ROOT}/${source_id}"
  mkdir -p "${source_dir}"

  # Consolidated JSON state
  cat > "${source_dir}/session_state.json" <<'STATEJSON'
{
  "workflow_mode": "ultrawork",
  "task_domain": "coding",
  "task_intent": "execution",
  "current_objective": "Implement the auth refactor",
  "last_meta_request": "explain the token flow",
  "last_assistant_message": "I finished refactoring the token validator. Next step is updating the middleware.",
  "last_verify_cmd": "bash tests/test-auth.sh"
}
STATEJSON

  # Auxiliary files
  printf '{"agent_type":"quality-reviewer","message":"No critical issues found."}\n' \
    > "${source_dir}/subagent_summaries.jsonl"
  printf '{"ts":1700000000,"text":"implement the auth refactor"}\n' \
    > "${source_dir}/recent_prompts.jsonl"
  printf '/src/auth/validator.ts\n/src/middleware/auth.ts\n' \
    > "${source_dir}/edited_files.log"
  printf '# Auth Refactor Plan\n\n1. Update token validator\n2. Update middleware\n' \
    > "${source_dir}/current_plan.md"
}

# Helper: populate a source session with legacy individual key files (no session_state.json).
setup_legacy_source_session() {
  local source_id="$1"
  local source_dir="${TEST_STATE_ROOT}/${source_id}"
  mkdir -p "${source_dir}"

  printf 'ultrawork' > "${source_dir}/workflow_mode"
  printf 'writing' > "${source_dir}/task_domain"
  printf 'execution' > "${source_dir}/task_intent"
  printf 'Draft the quarterly report' > "${source_dir}/current_objective"
}

printf '=== Session Resume Integration Tests ===\n\n'

# ------------------------------------------------------------------
# Test 1: Non-resume source exits early with no output
# ------------------------------------------------------------------
printf 'Non-resume source exits cleanly:\n'

run_resume '{"session_id":"target-001","source":"new","transcript_path":"/tmp/target-001.jsonl"}'
assert_eq "exit code 0" "0" "${_resume_exit}"
assert_eq "no output" "" "$(resume_output)"

# ------------------------------------------------------------------
# Test 2: Missing session_id exits early
# ------------------------------------------------------------------
printf '\nMissing session_id exits cleanly:\n'

run_resume '{"session_id":"","source":"resume","transcript_path":"/tmp/src.jsonl"}'
assert_eq "exit code 0" "0" "${_resume_exit}"
assert_eq "no output" "" "$(resume_output)"

# ------------------------------------------------------------------
# Test 3: Full resume cycle — consolidated JSON state
# ------------------------------------------------------------------
printf '\nFull resume cycle (consolidated JSON):\n'

source_id="source-session-100"
target_id="target-session-200"
setup_source_session "${source_id}"

run_resume "{\"session_id\":\"${target_id}\",\"source\":\"resume\",\"transcript_path\":\"/transcripts/${source_id}.jsonl\"}"
output="$(resume_output)"

# Verify state was copied to target directory
target_dir="${TEST_STATE_ROOT}/${target_id}"
assert_file_exists "session_state.json copied" "${target_dir}/session_state.json"
assert_file_exists "subagent_summaries.jsonl copied" "${target_dir}/subagent_summaries.jsonl"
assert_file_exists "recent_prompts.jsonl copied" "${target_dir}/recent_prompts.jsonl"
assert_file_exists "edited_files.log copied" "${target_dir}/edited_files.log"
assert_file_exists "current_plan.md copied" "${target_dir}/current_plan.md"

# Verify state content was preserved
state_json="$(cat "${target_dir}/session_state.json")"
assert_contains "workflow_mode preserved" '"workflow_mode": "ultrawork"' "${state_json}"
assert_contains "task_domain preserved" '"task_domain": "coding"' "${state_json}"
assert_contains "current_objective preserved" '"current_objective": "Implement the auth refactor"' "${state_json}"

# Verify resume_source_session_id was recorded
resume_src="$(jq -r '.resume_source_session_id // empty' "${target_dir}/session_state.json")"
assert_eq "resume source recorded" "${source_id}" "${resume_src}"

# Verify JSON output has additionalContext with key preserved fields
assert_contains "output has hookEventName" '"hookEventName":"SessionStart"' "${output}"
context="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${output}")"
assert_contains "context has workflow mode" "Preserved workflow mode: ultrawork" "${context}"
assert_contains "context has task domain" "Preserved task domain: coding" "${context}"
assert_contains "context has objective" "Preserved objective: Implement the auth refactor" "${context}"
assert_contains "context has last meta request" "explain the token flow" "${context}"
assert_contains "context has last assistant message" "refactoring the token validator" "${context}"
assert_contains "context has specialist conclusions" "quality-reviewer" "${context}"
assert_contains "context has plan" "Auth Refactor Plan" "${context}"
assert_contains "context has coding domain advice" "Make changes incrementally" "${context}"
assert_contains "context has resumed session preamble" "resumed Claude Code session" "${context}"

# ------------------------------------------------------------------
# Test 4: Backwards-compatible resume from legacy individual files
# ------------------------------------------------------------------
printf '\nBackwards-compatible resume (legacy individual files):\n'

legacy_id="legacy-source-300"
legacy_target="legacy-target-400"
setup_legacy_source_session "${legacy_id}"

run_resume "{\"session_id\":\"${legacy_target}\",\"source\":\"resume\",\"transcript_path\":\"/transcripts/${legacy_id}.jsonl\"}"
output="$(resume_output)"

legacy_target_dir="${TEST_STATE_ROOT}/${legacy_target}"
assert_file_exists "session_state.json created from migration" "${legacy_target_dir}/session_state.json"

# Verify migrated state
migrated_mode="$(jq -r '.workflow_mode // empty' "${legacy_target_dir}/session_state.json")"
migrated_domain="$(jq -r '.task_domain // empty' "${legacy_target_dir}/session_state.json")"
migrated_obj="$(jq -r '.current_objective // empty' "${legacy_target_dir}/session_state.json")"
assert_eq "legacy workflow_mode migrated" "ultrawork" "${migrated_mode}"
assert_eq "legacy task_domain migrated" "writing" "${migrated_domain}"
assert_eq "legacy objective migrated" "Draft the quarterly report" "${migrated_obj}"

# Verify context output reflects writing domain
context="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${output}")"
assert_contains "context has writing domain" "Preserved task domain: writing" "${context}"
assert_contains "context has writing advice" "editor-critic" "${context}"

# ------------------------------------------------------------------
# Test 5: Resume with missing source directory — no state copied
# ------------------------------------------------------------------
printf '\nResume with missing source directory:\n'

run_resume '{"session_id":"orphan-target-500","source":"resume","transcript_path":"/transcripts/nonexistent-session.jsonl"}'
output="$(resume_output)"

orphan_dir="${TEST_STATE_ROOT}/orphan-target-500"
# The target directory is created by ensure_session_dir, but no state should be populated
if [[ -f "${orphan_dir}/session_state.json" ]]; then
  # If it exists, it should be empty or have no meaningful state
  obj="$(jq -r '.current_objective // empty' "${orphan_dir}/session_state.json" 2>/dev/null || echo "")"
  assert_eq "no objective in orphan" "" "${obj}"
else
  pass=$((pass + 1))
fi

# Context should still include the resumed session preamble but no preserved values
assert_contains "output has SessionStart" '"hookEventName":"SessionStart"' "${output}"
context="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${output}")"
assert_contains "orphan still has resumed preamble" "resumed Claude Code session" "${context}"
assert_not_contains "orphan has no preserved objective" "Preserved objective:" "${context}"

# ------------------------------------------------------------------
# Test 6: Resume from self (same session ID) — no copy
# ------------------------------------------------------------------
printf '\nResume from self (same session ID):\n'

self_id="self-session-600"
setup_source_session "${self_id}"

run_resume "{\"session_id\":\"${self_id}\",\"source\":\"resume\",\"transcript_path\":\"/transcripts/${self_id}.jsonl\"}"
output="$(resume_output)"

# Script should still produce output (state already exists in the session dir),
# but should NOT copy state onto itself — the original state should remain intact.
context="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${output}")"
assert_contains "self-resume has preamble" "resumed Claude Code session" "${context}"

# ------------------------------------------------------------------
# Test 7 (Wave 1 — Phase 8 continuity carry-over). The handoff hook now
# copies findings.json, gate_events.jsonl, and discovered_scope.jsonl
# to the new session so a council Phase 8 wave plan and its event
# history survive a `--resume` round-trip. It also strips any stale
# `resume_hint_emitted*` keys carried over from the source session so
# the SessionStart resume-hint hook is not silently short-circuited.
# ------------------------------------------------------------------
printf '\nWave 1 — Phase 8 carry-over + stale-hint-flag clearing:\n'

p8_source="phase8-source-700"
p8_target="phase8-target-701"
p8_source_dir="${TEST_STATE_ROOT}/${p8_source}"
mkdir -p "${p8_source_dir}"

# Copy session_state.json with stale hint flags (both legacy and per-artifact).
cat > "${p8_source_dir}/session_state.json" <<'STATEJSON'
{
  "workflow_mode": "ultrawork",
  "task_domain": "coding",
  "current_objective": "Phase 8 wave plan in flight",
  "resume_hint_emitted": "1",
  "resume_hint_emitted_old_artifact_sid": "1"
}
STATEJSON

# Phase 8 master finding list.
cat > "${p8_source_dir}/findings.json" <<'JSON'
{
  "schema_version": 1,
  "findings": [{"id":"F-001","title":"hint","status":"shipped"}],
  "waves": [{"idx":1,"total":2,"status":"shipped"},{"idx":2,"total":2,"status":"pending"}]
}
JSON

# Gate-event history.
printf '{"ts":1,"gate":"discovered-scope","event":"block","details":{"pending_count":3}}\n' \
  > "${p8_source_dir}/gate_events.jsonl"
# Discovered-scope ledger.
printf '{"id":"DS-1","status":"deferred","reason":"out of scope"}\n' \
  > "${p8_source_dir}/discovered_scope.jsonl"

run_resume "{\"session_id\":\"${p8_target}\",\"source\":\"resume\",\"transcript_path\":\"/transcripts/${p8_source}.jsonl\"}"

p8_target_dir="${TEST_STATE_ROOT}/${p8_target}"
assert_file_exists "Wave1: findings.json copied" "${p8_target_dir}/findings.json"
assert_file_exists "Wave1: gate_events.jsonl copied" "${p8_target_dir}/gate_events.jsonl"
assert_file_exists "Wave1: discovered_scope.jsonl copied" "${p8_target_dir}/discovered_scope.jsonl"

# Both stale `resume_hint_emitted*` keys must be stripped after handoff.
state_after="$(cat "${p8_target_dir}/session_state.json")"
hint_legacy="$(jq -r '.resume_hint_emitted // ""' <<<"${state_after}")"
hint_per_art="$(jq -r '.resume_hint_emitted_old_artifact_sid // ""' <<<"${state_after}")"
assert_eq "Wave1: legacy resume_hint_emitted cleared" "" "${hint_legacy}"
assert_eq "Wave1: per-artifact hint key cleared" "" "${hint_per_art}"

# But the rest of the state (objective, workflow_mode) must remain intact.
assert_contains "Wave1: current_objective preserved through clear" "Phase 8 wave plan in flight" "${state_after}"
assert_contains "Wave1: workflow_mode preserved through clear" "ultrawork" "${state_after}"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
