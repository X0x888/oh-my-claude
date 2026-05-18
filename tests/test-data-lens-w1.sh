#!/usr/bin/env bash
# test-data-lens-w1.sh — v1.43 data-lens W1 regression net.
#
# Covers two telemetry feedback-loop changes:
#
# 1. ulw-correct-record.sh auto-writes classifier-fixture candidates.
#    Pre-v1.43 the misfire row landed in classifier_misfires.jsonl but
#    no mechanical bridge surfaced it as a fixture promotion candidate.
#    The new behavior writes a regression.jsonl-shaped row (prompt /
#    intent / domain / note) to classifier_fixture_candidates.jsonl so
#    /ulw-report Patterns can surface "N ready to promote" and a
#    maintainer can vet+merge in bulk.
#
# 2. lib/timing.sh per-session timing.jsonl row cap (5000 rows by
#    default, retain 4000). Pre-v1.43 only the cross-session aggregate
#    was capped; long ULW sessions could land 10K+ rows in the per-
#    session file and stall /ulw-report's jq pipeline. Cap is applied
#    in the cold path of timing_append_prompt_end (once per prompt),
#    not the hot path (start/end fires ~50×/turn).

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

assert_true() {
  local label="$1" cond="$2"
  if [[ "${cond}" == "true" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — expected true\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

# Isolate HOME + STATE_ROOT so the test never touches the user state.
TEST_ROOT="$(mktemp -d)"
ORIG_HOME="${HOME}"
ORIG_STATE_ROOT="${STATE_ROOT:-}"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.claude/quality-pack"
export STATE_ROOT="${TEST_ROOT}/state"
mkdir -p "${STATE_ROOT}"

cleanup() {
  rm -rf "${TEST_ROOT}"
  export HOME="${ORIG_HOME}"
  [[ -n "${ORIG_STATE_ROOT}" ]] && export STATE_ROOT="${ORIG_STATE_ROOT}" || unset STATE_ROOT
}
trap cleanup EXIT

# ---------------------------------------------------------------
# Part 1: classifier fixture-candidate auto-write
# ---------------------------------------------------------------
#
# Drives ulw-correct-record.sh end-to-end. The script ls -t's
# STATE_ROOT to find the latest session, so seed one.

SESSION_ID="data-lens-w1-session"
SESSION_DIR="${STATE_ROOT}/${SESSION_ID}"
mkdir -p "${SESSION_DIR}"

# Minimal state file shaped for ulw-correct's read_state calls:
#   task_intent / task_domain / last_user_prompt / ultrawork sentinel
#   last_user_prompt_ts (recent) so the intent-downgrade guard does NOT
#                       fire (we want the apply path).
NOW="$(date +%s)"
cat >"${SESSION_DIR}/session_state.json" <<EOF
{
  "task_intent": "advisory",
  "task_domain": "general",
  "last_user_prompt": "How do I switch the date library to dayjs?",
  "last_user_prompt_ts": "${NOW}",
  "workflow_mode": "ultrawork"
}
EOF

# Sanity: run the corrector with parseable intent= AND domain= directives.
out="$(bash "${SCRIPTS_DIR}/ulw-correct-record.sh" \
  "this should have been execution+coding intent=execution domain=coding" 2>&1)"

# F1: fixture-candidates file exists after correction
fixture_file="${HOME}/.claude/quality-pack/classifier_fixture_candidates.jsonl"
[[ -f "${fixture_file}" ]] \
  && assert_true "F1 fixture file written after correction" "true" \
  || assert_true "F1 fixture file written after correction" "false"

# F2: row count == 1
fixture_count="$(wc -l < "${fixture_file}" 2>/dev/null | tr -d '[:space:]')"
assert_eq "F2 fixture row count after one correction" "1" "${fixture_count}"

# F3: row schema matches regression.jsonl (prompt_preview / intent / domain / note)
fixture_row="$(tail -1 "${fixture_file}")"
parsed_intent="$(jq -r '.intent' <<<"${fixture_row}")"
parsed_domain="$(jq -r '.domain' <<<"${fixture_row}")"
parsed_prompt="$(jq -r '.prompt_preview' <<<"${fixture_row}")"
parsed_source="$(jq -r '._source' <<<"${fixture_row}")"
assert_eq "F3a corrected intent landed on fixture row" "execution" "${parsed_intent}"
assert_eq "F3b corrected domain landed on fixture row" "coding" "${parsed_domain}"
assert_eq "F3c prompt_preview captured" "How do I switch the date library to dayjs?" "${parsed_prompt}"
assert_eq "F3d _source provenance tag" "ulw-correct" "${parsed_source}"

# F4: note describes the transition
parsed_note="$(jq -r '.note' <<<"${fixture_row}")"
case "${parsed_note}" in
  *"intent advisory"*"execution"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: F4 note describes intent transition (got %q)\n' "${parsed_note}" >&2; fail=$((fail + 1)) ;;
esac

# F5: intent-only correction (no domain= token) — domain falls back to prior
cat >"${SESSION_DIR}/session_state.json" <<EOF
{
  "task_intent": "execution",
  "task_domain": "writing",
  "last_user_prompt": "draft the migration runbook",
  "last_user_prompt_ts": "${NOW}",
  "workflow_mode": "ultrawork"
}
EOF
# F5 is a corner case: pre-existing intent is execution, corrected to advisory.
# Mid-turn-downgrade guard fires when last_edit_ts > last_user_prompt_ts.
# We did not set last_edit_ts so the guard does not fire — the apply path
# runs normally.
bash "${SCRIPTS_DIR}/ulw-correct-record.sh" \
  "this is advisory not execution intent=advisory" >/dev/null 2>&1 || true
fixture_count="$(wc -l < "${fixture_file}" 2>/dev/null | tr -d '[:space:]')"
assert_eq "F5 row count after intent-only correction" "2" "${fixture_count}"
last_row="$(tail -1 "${fixture_file}")"
fallback_domain="$(jq -r '.domain' <<<"${last_row}")"
assert_eq "F5b domain falls back to prior when not corrected" "writing" "${fallback_domain}"

# F6: empty-prompt session does NOT write a fixture candidate
cat >"${SESSION_DIR}/session_state.json" <<EOF
{
  "task_intent": "advisory",
  "task_domain": "general",
  "last_user_prompt": "",
  "last_user_prompt_ts": "${NOW}",
  "workflow_mode": "ultrawork"
}
EOF
prev_count="${fixture_count}"
bash "${SCRIPTS_DIR}/ulw-correct-record.sh" \
  "intent=execution domain=coding" >/dev/null 2>&1 || true
new_count="$(wc -l < "${fixture_file}" 2>/dev/null | tr -d '[:space:]')"
assert_eq "F6 empty prompt does not write fixture candidate" "${prev_count}" "${new_count}"

# F7: out-of-mode (no ultrawork sentinel) does not even run the corrector,
# so no fixture row is added.
cat >"${SESSION_DIR}/session_state.json" <<EOF
{
  "task_intent": "advisory",
  "task_domain": "general",
  "last_user_prompt": "should still skip",
  "last_user_prompt_ts": "${NOW}"
}
EOF
prev_count="${new_count}"
bash "${SCRIPTS_DIR}/ulw-correct-record.sh" \
  "intent=execution domain=coding" >/dev/null 2>&1 || true
new_count="$(wc -l < "${fixture_file}" 2>/dev/null | tr -d '[:space:]')"
assert_eq "F7 non-ulw mode does not write fixture candidate" "${prev_count}" "${new_count}"

# ---------------------------------------------------------------
# Part 2: per-session timing.jsonl row cap
# ---------------------------------------------------------------
#
# Source common.sh + lib/timing.sh, fill a per-session timing.jsonl
# above the cap, fire one timing_append_prompt_end and verify the cap
# trims to retain.

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

SESSION_ID="data-lens-w1-timing"
ensure_session_dir
TIMING_FILE="$(session_file 'timing.jsonl')"
mkdir -p "$(dirname "${TIMING_FILE}")"

# T1: cap parameters honored. Default cap=5000 retain=4000.
# Use tiny overrides to keep the test fast.
export OMC_TIMING_PER_SESSION_CAP=20
export OMC_TIMING_PER_SESSION_RETAIN=15

# Write 25 fake rows.
seq 1 25 | while read -r n; do
  printf '{"kind":"start","ts":1700000000,"tool":"FakeTool","prompt_seq":%s}\n' "${n}"
done > "${TIMING_FILE}"

pre_lines="$(wc -l < "${TIMING_FILE}" | tr -d '[:space:]')"
assert_eq "T1 pre-cap line count" "25" "${pre_lines}"

# Fire prompt_end which runs the cap in its cold path.
# is_time_tracking_enabled needs to be true; default-on unless TIMING=off.
unset OMC_TIME_TRACKING || true
timing_append_prompt_end 1 5

post_lines="$(wc -l < "${TIMING_FILE}" | tr -d '[:space:]')"
# After append+cap: file briefly held 26 rows (25 seeded + 1 prompt_end),
# then the cap triggered (26 > 20) and tail -n 15 ran, leaving exactly
# the retain value of rows. The newly-appended prompt_end is included in
# the retained tail (it's the last row), it just doesn't extend the count.
assert_eq "T2 post-cap line count equals retain" "15" "${post_lines}"

# T2b: the last row in the file is the new prompt_end (not pruned by tail)
last_row="$(tail -1 "${TIMING_FILE}")"
last_kind="$(jq -r '.kind' <<<"${last_row}" 2>/dev/null || echo "?")"
assert_eq "T2b last retained row is prompt_end (new write preserved)" "prompt_end" "${last_kind}"

# T3: cap fast-path — when already at/below cap, no rewrite happens.
export OMC_TIMING_PER_SESSION_CAP=1000
export OMC_TIMING_PER_SESSION_RETAIN=800
pre_inode="$(stat -f '%i' "${TIMING_FILE}" 2>/dev/null || stat -c '%i' "${TIMING_FILE}" 2>/dev/null)"
timing_append_prompt_end 2 7
post_inode="$(stat -f '%i' "${TIMING_FILE}" 2>/dev/null || stat -c '%i' "${TIMING_FILE}" 2>/dev/null)"
assert_eq "T3 fast-path: no inode change when below cap" "${pre_inode}" "${post_inode}"

# T4: malformed cap is rejected (cap is a no-op, file untouched).
export OMC_TIMING_PER_SESSION_CAP="abc"
export OMC_TIMING_PER_SESSION_RETAIN=5
pre_lines="$(wc -l < "${TIMING_FILE}" | tr -d '[:space:]')"
timing_append_prompt_end 3 9
post_lines="$(wc -l < "${TIMING_FILE}" | tr -d '[:space:]')"
# Appended one prompt_end; non-numeric cap leaves the file intact (no trim).
expected_lines="$(( pre_lines + 1 ))"
assert_eq "T4 malformed cap: no trim, append still works" "${expected_lines}" "${post_lines}"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
printf '\ndata-lens W1 tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
