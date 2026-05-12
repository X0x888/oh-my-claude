#!/usr/bin/env bash
# v1.40.x Wave 3 user-facing quality surfaces regression tests.
#
# Covers F-010 (Coverage row in /ulw-status --summary), F-011
# (/ulw-correct skill + ulw-correct-record.sh backing script),
# F-012 (stop-time-summary names gate kinds caught + resolved).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
SHOW_STATUS="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"
STOP_TIME_SUMMARY="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-time-summary.sh"
CORRECT_RECORD="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/ulw-correct-record.sh"
CORRECT_SKILL="${REPO_ROOT}/bundle/dot-claude/skills/ulw-correct/SKILL.md"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
export STATE_ROOT="${TEST_TMP}/state"
mkdir -p "${STATE_ROOT}"
trap 'rm -rf "${TEST_TMP}"' EXIT

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  PASS  %s\n' "${desc}"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n         expected: %s\n         in: %s\n' "${desc}" "${needle}" "${haystack:0:200}"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf '  PASS  %s\n' "${desc}"; pass=$((pass + 1))
  else
    printf '  FAIL  %s must NOT contain: %s\n' "${desc}" "${needle}"
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
# F-010: Coverage row in /ulw-status --summary
printf '\n## F-010 — Coverage row in /ulw-status --summary\n'

if grep -q 'product-lens F-010' "${SHOW_STATUS}"; then
  printf '  PASS  show-status.sh marker comment present\n'; pass=$((pass + 1))
else
  printf '  FAIL  show-status.sh missing F-010 marker\n'; fail=$((fail + 1))
fi

# Runtime check: build a fixture session with 4/6 signals true.
sid="cov-test-${RANDOM}"
sid_dir="${STATE_ROOT}/${sid}"
mkdir -p "${sid_dir}"
cat > "${sid_dir}/session_state.json" <<JSON
{
  "task_intent": "execution",
  "task_domain": "coding",
  "last_review_ts": "1000",
  "review_had_findings": "false",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "done_contract_primary": "fix the test bug",
  "last_assistant_message": "**Changed.** wired the helper.\n**Verification.** PASS.\n**Risks.** None.\n**Next.** done.",
  "workflow_mode": "ultrawork",
  "_omc_session_started_at": "1000"
}
JSON
touch "${sid_dir}/edited_files.log"
# The regex matches `*_test.py` or `*.test.py` (mirrors the eval
# producer at result-from-session.sh). `test_foo.py` does NOT match —
# use `foo_test.py` to exercise the regression-test detector.
printf 'src/foo_test.py\n' > "${sid_dir}/edited_files.log"
touch "${STATE_ROOT}/.ulw_active"
mkdir -p "${REPO_ROOT}/dummy"  # nothing; just ensures TEST_TMP exists

# Set up a transient HOME for show-status.sh to resolve common.sh.
test_home="${TEST_TMP}/home"
mkdir -p "${test_home}/.claude/quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${test_home}/.claude/quality-pack/memory"

summary_out="$(HOME="${test_home}" STATE_ROOT="${STATE_ROOT}" \
  bash "${SHOW_STATUS}" summary 2>&1)" || true
assert_contains "summary contains Coverage line" "${summary_out}" "Coverage:"
# 4 of 6: verify (passed+targeted), review (clean), regression-test (path
# matches), closeout (2 closeout labels in last_assistant_message).
# contract is set so 5. wave-plan absent. Expect 5/6.
assert_contains "Coverage tracks expected signals" "${summary_out}" "5/6"
assert_contains "Coverage names regression-test" "${summary_out}" "regression-test"
assert_contains "Coverage names contract" "${summary_out}" "contract"

# Fresh session (no signals) suppresses the Coverage row.
sid_fresh="cov-fresh-${RANDOM}"
mkdir -p "${STATE_ROOT}/${sid_fresh}"
printf '{}\n' > "${STATE_ROOT}/${sid_fresh}/session_state.json"
rm -rf "${sid_dir}"  # remove the rich session so fresh is "latest"
sleep 1
touch "${STATE_ROOT}/${sid_fresh}/session_state.json"
fresh_out="$(HOME="${test_home}" STATE_ROOT="${STATE_ROOT}" \
  bash "${SHOW_STATUS}" summary 2>&1)" || true
assert_not_contains "fresh session suppresses Coverage line" "${fresh_out}" "Coverage:"

# ----------------------------------------------------------------------
# F-011: /ulw-correct skill + recording
printf '\n## F-011 — /ulw-correct skill\n'

if [[ -f "${CORRECT_SKILL}" ]]; then
  printf '  PASS  ulw-correct/SKILL.md exists\n'; pass=$((pass + 1))
else
  printf '  FAIL  ulw-correct/SKILL.md missing\n'; fail=$((fail + 1))
fi
if [[ -x "${CORRECT_RECORD}" ]]; then
  printf '  PASS  ulw-correct-record.sh is executable\n'; pass=$((pass + 1))
else
  printf '  FAIL  ulw-correct-record.sh missing or not executable\n'; fail=$((fail + 1))
fi

# Runtime check: set up an active session, run the record script, then
# assert both session-level and cross-session ledgers carry the row,
# and the intent state was updated.
sid_c="corr-${RANDOM}"
sid_c_dir="${STATE_ROOT}/${sid_c}"
mkdir -p "${sid_c_dir}"
cat > "${sid_c_dir}/session_state.json" <<JSON
{
  "task_intent": "execution",
  "task_domain": "coding",
  "last_user_prompt": "ulw fix bug X",
  "workflow_mode": "ultrawork"
}
JSON
touch "${STATE_ROOT}/.ulw_active"
# correct-record looks at `ls -t` newest under STATE_ROOT
sleep 1
touch "${sid_c_dir}"

correction_out="$(HOME="${test_home}" STATE_ROOT="${STATE_ROOT}" \
  bash "${CORRECT_RECORD}" "intent=advisory domain=writing wrong route" 2>&1)" || true
assert_contains "ulw-correct returns 'corrected:'" "${correction_out}" "corrected:"
assert_contains "ulw-correct names intent transition" "${correction_out}" "intent execution → advisory"
assert_contains "ulw-correct names domain transition" "${correction_out}" "domain coding → writing"

# Verify state mutation
new_intent="$(jq -r '.task_intent // ""' "${sid_c_dir}/session_state.json" 2>/dev/null)"
new_domain="$(jq -r '.task_domain // ""' "${sid_c_dir}/session_state.json" 2>/dev/null)"
[[ "${new_intent}" == "advisory" ]] && { printf '  PASS  task_intent state updated\n'; pass=$((pass + 1)); } \
  || { printf '  FAIL  task_intent expected advisory, got %s\n' "${new_intent}"; fail=$((fail + 1)); }
[[ "${new_domain}" == "writing" ]] && { printf '  PASS  task_domain state updated\n'; pass=$((pass + 1)); } \
  || { printf '  FAIL  task_domain expected writing, got %s\n' "${new_domain}"; fail=$((fail + 1)); }

# Per-session telemetry row appended
tele="${sid_c_dir}/classifier_telemetry.jsonl"
if [[ -f "${tele}" ]] && grep -q '"corrected_by_user":true' "${tele}" 2>/dev/null; then
  printf '  PASS  per-session telemetry row written\n'; pass=$((pass + 1))
else
  printf '  FAIL  per-session telemetry row missing\n'; fail=$((fail + 1))
fi
# Cross-session ledger row appended
xs="${test_home}/.claude/quality-pack/classifier_misfires.jsonl"
if [[ -f "${xs}" ]] && grep -q '"corrected_by_user":true' "${xs}" 2>/dev/null; then
  printf '  PASS  cross-session misfire row written\n'; pass=$((pass + 1))
else
  printf '  FAIL  cross-session misfire row missing\n'; fail=$((fail + 1))
fi

# Bare reason (no intent= / domain=) still records as misfire.
sid_c2="corr2-${RANDOM}"
mkdir -p "${STATE_ROOT}/${sid_c2}"
cat > "${STATE_ROOT}/${sid_c2}/session_state.json" <<JSON
{"task_intent":"execution","task_domain":"coding","workflow_mode":"ultrawork"}
JSON
sleep 1
touch "${STATE_ROOT}/${sid_c2}"

bare_out="$(HOME="${test_home}" STATE_ROOT="${STATE_ROOT}" \
  bash "${CORRECT_RECORD}" "wrong but I dont know what to say" 2>&1)" || true
assert_contains "bare reason still records as misfire" "${bare_out}" "recorded as misfire"

# ----------------------------------------------------------------------
# F-012: stop-time-summary names gate kinds caught
printf '\n## F-012 — Outcome card names gate kinds\n'

if grep -q 'growth-lens F-012' "${STOP_TIME_SUMMARY}"; then
  printf '  PASS  stop-time-summary.sh F-012 marker present\n'; pass=$((pass + 1))
else
  printf '  FAIL  stop-time-summary.sh F-012 marker missing\n'; fail=$((fail + 1))
fi
# The named-gate-kinds enhancement reads gate_events.jsonl with
# `select(.event == "block")` + jq unique + sort.
if grep -qE 'select\(\.event == "block"\)' "${STOP_TIME_SUMMARY}"; then
  printf '  PASS  stop-time-summary reads gate_events for block kinds\n'; pass=$((pass + 1))
else
  printf '  FAIL  stop-time-summary missing gate-kind enumeration\n'; fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf '\n--- v1.40.x W3 user-facing quality surfaces: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
