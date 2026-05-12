#!/usr/bin/env bash
# test-session-risk-tier.sh — v1.39.0 W2 regression net for
# `current_session_risk_tier` + `is_high_session_risk` (common.sh).
#
# The prompt-time classifier (classify_task_risk_tier) runs once in
# UserPromptSubmit before any tools or edits exist. By Stop time the
# session has accumulated strictly better evidence — edited surfaces,
# reviewer findings severity, verify confidence, discovered-scope
# depth. v1.39.0 W2 introduces a derived helper that layers session
# evidence on top of the prompt-time tier so gates fire on what the
# work IS, not what the opening sentence said.
#
# This test pins:
#   1. Prompt-time `high` short-circuits — the four gate consumer
#      sites keep firing without re-running expensive evidence checks.
#   2. Escalator 1: reviewer findings with severity high|critical in
#      findings.json escalate prompt-time low/medium → high.
#   3. Escalator 2: edited files matching the sensitive-surface regex
#      (auth, payment, migration, secret, etc.) escalate.
#   4. Escalator 3: verification ran with low confidence and did NOT
#      pass escalates.
#   5. Escalator 4: 3+ pending discovered_scope rows escalate.
#   6. De-escalation: medium prompt-time tier with all-docs edits and
#      no findings → low.
#   7. session_risk_factors state is persisted with the escalation
#      reasons when any escalator fires, idempotent on re-evaluation.
#   8. is_high_session_risk wraps the predicate consistently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_HOME="$(mktemp -d -t session-risk-tier-home-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
mkdir -p "${TEST_HOME}/.claude/quality-pack" "${TEST_STATE_ROOT}"
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
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# Each test gets a fresh session dir so state from one test does not
# leak into the next.
fresh_session() {
  export SESSION_ID="sess-$1-$$"
  local _sd="${STATE_ROOT}/${SESSION_ID}"
  mkdir -p "${_sd}"
  printf '{}' >"${_sd}/session_state.json"
}

# ---------------------------------------------------------------
# Part A: prompt-time high short-circuits
# ---------------------------------------------------------------
fresh_session "A1"
write_state "task_risk_tier" "high"
assert_eq "A1 prompt-time high stays high" "high" "$(current_session_risk_tier)"
assert_eq "A1 is_high_session_risk true" "yes" \
  "$(if is_high_session_risk; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------
# Part B: escalator 1 — findings.json severity
# ---------------------------------------------------------------
fresh_session "B1"
write_state "task_risk_tier" "low"
printf '{"findings":[{"severity":"high","claim":"x"}]}' >"$(session_file "findings.json")"
assert_eq "B1 high-severity finding escalates low→high" "high" "$(current_session_risk_tier)"
assert_eq "B1 session_risk_factors recorded" "high_severity_findings" \
  "$(read_state "session_risk_factors")"

fresh_session "B2"
write_state "task_risk_tier" "medium"
printf '{"findings":[{"severity":"critical","claim":"x"}]}' >"$(session_file "findings.json")"
assert_eq "B2 critical-severity finding escalates medium→high" "high" "$(current_session_risk_tier)"

fresh_session "B3"
write_state "task_risk_tier" "low"
printf '{"findings":[{"severity":"low","claim":"x"},{"severity":"medium","claim":"y"}]}' >"$(session_file "findings.json")"
assert_eq "B3 only low/medium findings → no escalation" "low" "$(current_session_risk_tier)"

fresh_session "B4"
write_state "task_risk_tier" "low"
# Empty findings array — must not escalate.
printf '{"findings":[]}' >"$(session_file "findings.json")"
assert_eq "B4 empty findings array → no escalation" "low" "$(current_session_risk_tier)"

# ---------------------------------------------------------------
# Part C: escalator 2 — edited-surface regex
# ---------------------------------------------------------------
fresh_session "C1"
write_state "task_risk_tier" "low"
printf '%s\n' "src/auth/middleware.go" >"$(session_file "edited_files.log")"
assert_eq "C1 auth/ path escalates" "high" "$(current_session_risk_tier)"
assert_eq "C1 factor recorded" "sensitive_surface_edited" \
  "$(read_state "session_risk_factors")"

fresh_session "C2"
write_state "task_risk_tier" "low"
printf '%s\n' "db/migrations/001_init.sql" >"$(session_file "edited_files.log")"
assert_eq "C2 migrations/ path escalates" "high" "$(current_session_risk_tier)"

fresh_session "C3"
write_state "task_risk_tier" "medium"
printf '%s\n' "payments/stripe.ts" >"$(session_file "edited_files.log")"
assert_eq "C3 payments path escalates medium→high" "high" "$(current_session_risk_tier)"

fresh_session "C4"
write_state "task_risk_tier" "low"
# author.go contains "author" but not the bounded auth keyword
printf '%s\n' "src/blog/author.go" >"$(session_file "edited_files.log")"
assert_eq "C4 'author' substring does NOT escalate (bounded match)" "low" "$(current_session_risk_tier)"

# ---------------------------------------------------------------
# Part D: escalator 3 — verify confidence
# ---------------------------------------------------------------
fresh_session "D1"
write_state_batch \
  "task_risk_tier" "low" \
  "last_verify_confidence" "20" \
  "last_verify_outcome" "failed"
assert_eq "D1 low verify confidence + failed outcome escalates" "high" "$(current_session_risk_tier)"

fresh_session "D2"
write_state_batch \
  "task_risk_tier" "low" \
  "last_verify_confidence" "20" \
  "last_verify_outcome" "passed"
assert_eq "D2 low confidence BUT passed outcome → no escalation" "low" "$(current_session_risk_tier)"

fresh_session "D3"
write_state_batch \
  "task_risk_tier" "low" \
  "last_verify_confidence" "80" \
  "last_verify_outcome" "failed"
assert_eq "D3 high confidence + failed → no escalation" "low" "$(current_session_risk_tier)"

# ---------------------------------------------------------------
# Part E: escalator 4 — discovered_scope pending
# ---------------------------------------------------------------
fresh_session "E1"
write_state "task_risk_tier" "low"
{
  printf '{"id":"S1","status":"pending"}\n'
  printf '{"id":"S2","status":"pending"}\n'
  printf '{"id":"S3","status":"pending"}\n'
} >"$(session_file "discovered_scope.jsonl")"
assert_eq "E1 3 pending discovered scope items escalate" "high" "$(current_session_risk_tier)"

fresh_session "E2"
write_state "task_risk_tier" "low"
{
  printf '{"id":"S1","status":"pending"}\n'
  printf '{"id":"S2","status":"pending"}\n'
} >"$(session_file "discovered_scope.jsonl")"
assert_eq "E2 only 2 pending → no escalation" "low" "$(current_session_risk_tier)"

fresh_session "E3"
write_state "task_risk_tier" "low"
{
  printf '{"id":"S1","status":"shipped"}\n'
  printf '{"id":"S2","status":"deferred"}\n'
  printf '{"id":"S3","status":"shipped"}\n'
} >"$(session_file "discovered_scope.jsonl")"
assert_eq "E3 3 non-pending items → no escalation" "low" "$(current_session_risk_tier)"

# ---------------------------------------------------------------
# Part F: de-escalation — medium + all-docs edits
# ---------------------------------------------------------------
fresh_session "F1"
write_state_batch \
  "task_risk_tier" "medium" \
  "code_edit_count" "0" \
  "doc_edit_count" "5"
assert_eq "F1 medium + 0 code + 5 doc edits de-escalates" "low" "$(current_session_risk_tier)"

fresh_session "F2"
write_state_batch \
  "task_risk_tier" "medium" \
  "code_edit_count" "2" \
  "doc_edit_count" "5"
assert_eq "F2 medium + 2 code edits → stays medium" "medium" "$(current_session_risk_tier)"

fresh_session "F3"
write_state_batch \
  "task_risk_tier" "low" \
  "code_edit_count" "0" \
  "doc_edit_count" "5"
assert_eq "F3 low + all docs → stays low (no de-escalation needed)" "low" "$(current_session_risk_tier)"

fresh_session "F4"
write_state_batch \
  "task_risk_tier" "medium" \
  "code_edit_count" "0" \
  "doc_edit_count" "2"
assert_eq "F4 medium + < 3 doc edits → stays medium" "medium" "$(current_session_risk_tier)"

# F5 (quality-reviewer Q3): pin the escalator-over-deescalator precedence.
# Without this, a medium prompt with all-docs edits would de-escalate
# even when discovered_scope or findings.json escalators fire — making
# the strict-gate posture leakable through doc-only-looking work.
fresh_session "F5"
write_state_batch \
  "task_risk_tier" "medium" \
  "code_edit_count" "0" \
  "doc_edit_count" "5"
{
  printf '{"id":"S1","status":"pending"}\n'
  printf '{"id":"S2","status":"pending"}\n'
  printf '{"id":"S3","status":"pending"}\n'
} >"$(session_file "discovered_scope.jsonl")"
assert_eq "F5 escalator wins over de-escalation precedence" "high" "$(current_session_risk_tier)"

fresh_session "F6"
write_state_batch \
  "task_risk_tier" "medium" \
  "code_edit_count" "0" \
  "doc_edit_count" "5"
printf '{"findings":[{"severity":"high"}]}' >"$(session_file "findings.json")"
assert_eq "F6 findings escalator wins over docs-only de-escalation" "high" "$(current_session_risk_tier)"

# ---------------------------------------------------------------
# Part G: factor accumulation + idempotent write
# ---------------------------------------------------------------
fresh_session "G1"
write_state "task_risk_tier" "low"
printf '{"findings":[{"severity":"high"}]}' >"$(session_file "findings.json")"
printf '%s\n' "src/auth/login.go" >"$(session_file "edited_files.log")"
result1="$(current_session_risk_tier)"
factors1="$(read_state "session_risk_factors")"
assert_eq "G1 multiple escalators compose to high" "high" "${result1}"
# Both factors should be in the comma-joined list
if [[ "${factors1}" == *"high_severity_findings"* ]] && [[ "${factors1}" == *"sensitive_surface_edited"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: G1 multiple factors recorded\n    actual=%q\n' "${factors1}" >&2
  fail=$((fail + 1))
fi
# Idempotency: re-running yields the same factors AND the same state
result2="$(current_session_risk_tier)"
factors2="$(read_state "session_risk_factors")"
assert_eq "G1 idempotent tier on re-run" "high" "${result2}"
assert_eq "G1 idempotent factors on re-run" "${factors1}" "${factors2}"

# ---------------------------------------------------------------
# Part H: missing state safety
# ---------------------------------------------------------------
fresh_session "H1"
# No task_risk_tier written — defaults to low
assert_eq "H1 missing tier defaults to low" "low" "$(current_session_risk_tier)"
assert_eq "H1 is_high_session_risk false on default" "no" \
  "$(if is_high_session_risk; then echo yes; else echo no; fi)"

fresh_session "H2"
write_state "task_risk_tier" "medium"
# All evidence files missing — no escalation, returns prompt-time tier
assert_eq "H2 medium + no evidence files → stays medium" "medium" "$(current_session_risk_tier)"

# ---------------------------------------------------------------
# Part I: classify_task_risk_tier still works (no regression)
# ---------------------------------------------------------------
assert_eq "I1 prompt classifier still high on auth+production" "high" \
  "$(classify_task_risk_tier "audit our auth flow for production" "execution" "coding")"
assert_eq "I2 prompt classifier still low on simple typo" "low" \
  "$(classify_task_risk_tier "fix the typo" "execution" "general")"

# ---------------------------------------------------------------
# Part J: directive-selection callers can still use prompt-time tier
# ---------------------------------------------------------------
fresh_session "J1"
write_state "task_risk_tier" "high"
assert_eq "J1 is_high_task_risk reads prompt-time tier" "yes" \
  "$(if is_high_task_risk; then echo yes; else echo no; fi)"

fresh_session "J2"
write_state "task_risk_tier" "low"
# Even with session evidence pushing to high, is_high_task_risk still
# reads prompt-time tier (UserPromptSubmit can't see session evidence).
printf '{"findings":[{"severity":"high"}]}' >"$(session_file "findings.json")"
assert_eq "J2 is_high_task_risk stays prompt-time-only" "no" \
  "$(if is_high_task_risk; then echo yes; else echo no; fi)"
assert_eq "J2 is_high_session_risk picks up evidence" "yes" \
  "$(if is_high_session_risk; then echo yes; else echo no; fi)"

printf '\nSession-risk-tier tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
