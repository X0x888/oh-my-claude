#!/usr/bin/env bash
# shellcheck disable=SC1090
#
# tests/test-prompt-router-synthetic.sh — Bug A defense regression net.
#
# Verifies `is_synthetic_prompt` (common.sh) and the early-return guard
# in prompt-intent-router.sh: when Claude Code fires UserPromptSubmit
# with a synthetic injection (`<task-notification>`, `<system-reminder>`,
# bash-stdout/stderr wrappers), the router must NOT overwrite the
# active task contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
ROUTER_SH="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${STATE_ROOT}"
# .ulw_active sentinel so hooks that fast-path-out on its absence still run
touch "${STATE_ROOT}/.ulw_active"
# The router sources `${HOME}/.claude/skills/autowork/scripts/common.sh`,
# so wire HOME to point at the repo's bundle layout via a symlink tree.
mkdir -p "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${TEST_HOME}/.claude/skills/autowork"
mkdir -p "${TEST_HOME}/.claude/quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${TEST_HOME}/.claude/quality-pack/scripts"

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

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

assert_true() {
  local label="$1" cmd="$2"
  if eval "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — command false: %s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

assert_false() {
  local label="$1" cmd="$2"
  if ! eval "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — command true (expected false): %s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains_text() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — missing %q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains_text() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — unexpected %q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# --- is_synthetic_prompt unit cases -------------------------------------

printf '\n--- is_synthetic_prompt unit cases ---\n'

call_synthetic() {
  ( . "${COMMON_SH}"
    if is_synthetic_prompt "$1"; then echo "yes"; else echo "no"; fi )
}

assert_eq "task-notification anchor"        "yes" "$(call_synthetic '<task-notification>
<task-id>abc</task-id>
<status>completed</status>')"
assert_eq "system-reminder anchor"          "yes" "$(call_synthetic '<system-reminder>
You should ...
</system-reminder>')"
assert_eq "bash-stdout anchor"              "yes" "$(call_synthetic '<bash-stdout>
hello
</bash-stdout>')"
assert_eq "bash-stderr anchor"              "yes" "$(call_synthetic '<bash-stderr>
err
</bash-stderr>')"
assert_eq "command-message anchor"          "yes" "$(call_synthetic '<command-message>commit</command-message>')"
assert_eq "command-name anchor"             "yes" "$(call_synthetic '<command-name>/ulw</command-name>')"
assert_eq "leading whitespace tolerated"    "yes" "$(call_synthetic '   <task-notification>
data
</task-notification>')"

# Negative cases — real user prompts must not be classified as synthetic.
assert_eq "real /ulw prompt"                "no"  "$(call_synthetic '/ulw fix the auth bug')"
assert_eq "plain English prompt"            "no"  "$(call_synthetic 'commit the changes first')"
assert_eq "prompt with inline angle brackets" "no" "$(call_synthetic 'rename function <foo> to <bar>')"
assert_eq "code-fence prompt"               "no"  "$(call_synthetic 'I want this code:
\`\`\`bash
echo hi
\`\`\`')"
assert_eq "empty prompt"                    "no"  "$(call_synthetic '')"
assert_eq "single-char prompt"              "no"  "$(call_synthetic 'x')"
# A user pasting the literal text "<task-notification>" mid-sentence
# does NOT trigger — only an anchored opener does.
assert_eq "<task-notification> mid-sentence is NOT synthetic" "no" \
  "$(call_synthetic 'I saw a <task-notification> tag earlier')"

# --- Router early-return integration -------------------------------------

printf '\n--- Router early-return on synthetic injection ---\n'

run_router() {
  local prompt="$1" sid="$2"
  local input
  input="$(jq -nc --arg sid "${sid}" --arg p "${prompt}" \
    '{session_id: $sid, prompt: $p, transcript_path: "/tmp/none.jsonl"}')"
  printf '%s' "${input}" | bash "${ROUTER_SH}" 2>&1 || true
}

# Pre-populate a session with a known contract — synthetic injection
# must NOT overwrite these fields.
sid="bug-a-test"
sdir="${STATE_ROOT}/${sid}"
mkdir -p "${sdir}"
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  task_domain: "coding",
  current_objective: "fix the auth bug",
  done_contract_primary: "fix the auth bug",
  done_contract_commit_mode: "required",
  last_user_prompt_ts: "1000"
}' > "${sdir}/session_state.json"

run_router '<task-notification>
<task-id>abc</task-id>
<status>completed</status>
<summary>Agent X completed</summary>
</task-notification>' "${sid}" >/dev/null

# Contract must be preserved.
assert_eq "task-notification: current_objective unchanged" "fix the auth bug" \
  "$(jq -r '.current_objective // ""' "${sdir}/session_state.json")"
assert_eq "task-notification: task_intent unchanged" "execution" \
  "$(jq -r '.task_intent // ""' "${sdir}/session_state.json")"
assert_eq "task-notification: commit_mode unchanged" "required" \
  "$(jq -r '.done_contract_commit_mode // ""' "${sdir}/session_state.json")"

# A real user prompt re-fired must update — verify the contrast with
# the synthetic case above. Set workflow_mode so the router's ULW
# code path activates fully (consistent with how an in-progress ULW
# session looks at PromptSubmit time).
sid2="real-user-prompt"
sdir2="${STATE_ROOT}/${sid2}"
mkdir -p "${sdir2}"
echo '{"workflow_mode":"ultrawork"}' > "${sdir2}/session_state.json"
run_router '/ulw fix the payment refund' "${sid2}" >/dev/null
real_intent="$(jq -r '.task_intent // ""' "${sdir2}/session_state.json")"
real_objective="$(jq -r '.current_objective // ""' "${sdir2}/session_state.json")"
assert_true "real prompt: task_intent populated" \
  "[[ -n \"${real_intent}\" ]]"
assert_true "real prompt: current_objective updated" \
  "[[ \"${real_objective}\" == *'payment refund'* ]]"

# Monotonic objective identity is produced in the same locked transition that
# tombstones prior live dispatches. Freeze `date +%s` to prove two genuinely
# fresh prompts in one epoch second still receive distinct cycle IDs, while a
# true continuation preserves both the ID and its current live row.
fake_bin="${TEST_HOME}/fake-bin"
mkdir -p "${fake_bin}"
printf '%s\n' '#!/bin/sh' \
  'if [ "${1:-}" = "+%s" ]; then printf "424242\\n"; else exec /bin/date "$@"; fi' \
  >"${fake_bin}/date"
chmod +x "${fake_bin}/date"
run_router_same_second() {
  local prompt="$1" cycle_sid="$2" input
  input="$(jq -nc --arg sid "${cycle_sid}" --arg p "${prompt}" \
    '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
  printf '%s' "${input}" | PATH="${fake_bin}:${PATH}" bash "${ROUTER_SH}" \
    2>&1 || true
}
cycle_sid="review-cycle-producer"
cycle_dir="${STATE_ROOT}/${cycle_sid}"
mkdir -p "${cycle_dir}"
jq -nc '{workflow_mode:"ultrawork",task_intent:"execution",
  current_objective:"old objective",review_cycle_id:"4",
  review_cycle_prompt_ts:"424242"}' >"${cycle_dir}/session_state.json"
jq -nc '{ts:424242,agent_type:"old-cycle-worker",objective_cycle_id:4,
  review_dispatch_abandoned:false}' >"${cycle_dir}/pending_agents.jsonl"
run_router_same_second '/ulw implement the new export path completely' \
  "${cycle_sid}" >/dev/null
assert_eq "fresh producer increments the monotonic review cycle" "5" \
  "$(jq -r '.review_cycle_id // ""' "${cycle_dir}/session_state.json")"
assert_eq "fresh producer keeps the frozen same-second timestamp diagnostic" \
  "424242" \
  "$(jq -r '.review_cycle_prompt_ts // ""' "${cycle_dir}/session_state.json")"
assert_eq "cycle publication atomically tombstones the prior live row" "true" \
  "$(jq -s -r '[.[] | select(.agent_type == "old-cycle-worker")][0].review_dispatch_abandoned' \
    "${cycle_dir}/pending_agents.jsonl")"
jq -nc '{ts:424242,agent_type:"current-cycle-worker",objective_cycle_id:5,
  review_dispatch_abandoned:false}' >>"${cycle_dir}/pending_agents.jsonl"
run_router_same_second 'continue' "${cycle_sid}" >/dev/null
assert_eq "true continuation preserves the review cycle" "5" \
  "$(jq -r '.review_cycle_id // ""' "${cycle_dir}/session_state.json")"
assert_eq "true continuation does not retombstone current live work" "false" \
  "$(jq -s -r '[.[] | select(.agent_type == "current-cycle-worker")][0].review_dispatch_abandoned' \
    "${cycle_dir}/pending_agents.jsonl")"
run_router_same_second '/ulw implement a separate audit-log exporter' \
  "${cycle_sid}" >/dev/null
assert_eq "second fresh same-second prompt receives a new cycle" "6" \
  "$(jq -r '.review_cycle_id // ""' "${cycle_dir}/session_state.json")"
assert_eq "second fresh transition tombstones former current work" "true" \
  "$(jq -s -r '[.[] | select(.agent_type == "current-cycle-worker")][0].review_dispatch_abandoned' \
    "${cycle_dir}/pending_agents.jsonl")"

# The cycle ID is the publication point for a fresh objective. A failed
# pending-ledger rewrite must not be masked merely because the following start
# ledger is absent and the function's caller is inside an `if ! ...` context
# (which suppresses Bash errexit inside the call tree). Inject a targeted
# mktemp failure after taint staging and prove the transition fails closed.
printf '%s\n' '#!/bin/sh' \
  'case "${OMC_TEST_FAIL_OBJECTIVE_LEDGER_REWRITE:-}:$*" in' \
  '  1:*pending_agents.jsonl.XXXXXX*) exit 1 ;;' \
  'esac' \
  'exec /usr/bin/mktemp "$@"' \
  >"${fake_bin}/mktemp"
chmod +x "${fake_bin}/mktemp"
failure_sid="review-cycle-rewrite-failure"
failure_dir="${STATE_ROOT}/${failure_sid}"
mkdir -p "${failure_dir}"
jq -nc '{workflow_mode:"ultrawork",task_intent:"execution",
  current_objective:"old objective",review_cycle_id:"9",
  review_cycle_prompt_ts:"424242"}' >"${failure_dir}/session_state.json"
jq -nc '{ts:424242,agent_type:"rewrite-failure-worker",objective_cycle_id:9,
  review_dispatch_abandoned:false}' >"${failure_dir}/pending_agents.jsonl"
failure_input="$(jq -nc --arg sid "${failure_sid}" \
  --arg p '/ulw implement the separate failed-transition exporter' \
  '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
set +e
printf '%s' "${failure_input}" \
  | PATH="${fake_bin}:${PATH}" OMC_TEST_FAIL_OBJECTIVE_LEDGER_REWRITE=1 \
    bash "${ROUTER_SH}" >/dev/null 2>&1
failure_rc=$?
set -e
assert_true "ledger rewrite failure rejects fresh objective transition" \
  "[[ ${failure_rc} -ne 0 ]]"
assert_eq "ledger rewrite failure does not publish a new review cycle" "9" \
  "$(jq -r '.review_cycle_id // ""' "${failure_dir}/session_state.json")"
assert_eq "ledger rewrite failure leaves prior row live for a safe retry" "false" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "${failure_dir}/pending_agents.jsonl")"

# A bash-stdout injection must also be skipped.
sid3="bash-stdout-test"
sdir3="${STATE_ROOT}/${sid3}"
mkdir -p "${sdir3}"
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  current_objective: "untouched objective"
}' > "${sdir3}/session_state.json"

run_router '<bash-stdout>
output line one
output line two
</bash-stdout>' "${sid3}" >/dev/null
assert_eq "bash-stdout: current_objective unchanged" "untouched objective" \
  "$(jq -r '.current_objective // ""' "${sdir3}/session_state.json")"

# v1.34.1: end-to-end regression for the <system-reminder> anchor
# specifically. Claude Code injects <system-reminder>...</system-reminder>
# wrappers around several flavors of synthetic content; if a future
# refactor drops `system-reminder` from the anchor list in
# is_synthetic_prompt, this test catches it before release.
sid4="system-reminder-test"
sdir4="${STATE_ROOT}/${sid4}"
mkdir -p "${sdir4}"
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  task_domain: "coding",
  current_objective: "v1.34.1 anchor regression target",
  done_contract_commit_mode: "required",
  last_user_prompt_ts: "2000"
}' > "${sdir4}/session_state.json"

run_router '<system-reminder>
This is a notice about something the model should know.
Multiple lines of synthetic content here.
</system-reminder>' "${sid4}" >/dev/null

assert_eq "system-reminder: current_objective preserved" "v1.34.1 anchor regression target" \
  "$(jq -r '.current_objective // ""' "${sdir4}/session_state.json")"
assert_eq "system-reminder: task_intent preserved" "execution" \
  "$(jq -r '.task_intent // ""' "${sdir4}/session_state.json")"
assert_eq "system-reminder: commit_mode preserved" "required" \
  "$(jq -r '.done_contract_commit_mode // ""' "${sdir4}/session_state.json")"
assert_eq "system-reminder: last_user_prompt_ts not bumped" "2000" \
  "$(jq -r '.last_user_prompt_ts // ""' "${sdir4}/session_state.json")"

# --- Quality-first model-routing directive ---
# The router renders common.sh's authoritative resolver decision. Verify every
# tier surfaces the live decision and the expected shipped-Sonnet class.
sid5="model-tier-test"
sdir5="${STATE_ROOT}/${sid5}"

for tier in quality economy balanced; do
  mkdir -p "${sdir5}"
  echo '{"workflow_mode":"ultrawork"}' > "${sdir5}/session_state.json"
  _omc_conf_loaded=0
  export OMC_MODEL_TIER="${tier}"
  output="$(run_router '/ulw test the model tier' "${sid5}")"
  context="$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
  has_directive="no"
  if [[ "${context}" == *"SUBAGENT MODEL ROUTING"* ]]; then
    has_directive="yes"
  fi
  assert_eq "model_tier=${tier}: routing directive present" "yes" "${has_directive}"
  case "${tier}" in
    quality)
      assert_contains_text "quality: shipped-Sonnet class resolves opus" \
        'pass `model: "opus"`' "${context}"
      ;;
    balanced|economy)
      assert_contains_text "${tier}: ordinary shipped-Sonnet class resolves sonnet" \
        'pass `model: "sonnet"`' "${context}"
      ;;
  esac
  if [[ "${tier}" == "economy" ]]; then
    assert_contains_text "model_tier=economy low-risk inherit class stays sonnet" \
      'For shipped inherit deliberators (quality-planner' "${context}"
    assert_contains_text "model_tier=economy low-risk inherit instruction" \
      'chief-of-staff), pass `model: "sonnet"`' "${context}"
  else
    assert_contains_text "model_tier=${tier}: inherit is represented by omission" \
      'chief-of-staff), OMIT the `model` parameter' "${context}"
  fi
  rm -rf "${sdir5}"
done
unset OMC_MODEL_TIER

# Invalid explicit environment values are one effective Balanced posture on
# every surface: rendered directive, persisted turn snapshot, and cache key.
sid5_invalid="model-tier-invalid"
sdir5_invalid="${STATE_ROOT}/${sid5_invalid}"
mkdir -p "${sdir5_invalid}"
echo '{"workflow_mode":"ultrawork"}' > "${sdir5_invalid}/session_state.json"
printf 'model_tier=quality\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
_omc_conf_loaded=0
export OMC_MODEL_TIER="not-a-model"
invalid_output="$(run_router '/ulw test invalid model tier normalization' "${sid5_invalid}")"
invalid_context="$(printf '%s' "${invalid_output}" \
  | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
assert_contains_text "invalid env tier preserves saved quality" \
  'tier=`quality`' "${invalid_context}"
assert_not_contains_text "invalid model tier never reaches directive metadata" \
  'not-a-model' "${invalid_context}"
assert_eq "invalid env tier snapshot preserves quality" "quality" \
  "$(jq -r '.model_routing_tier // ""' "${sdir5_invalid}/session_state.json")"
unset OMC_MODEL_TIER
rm -rf "${sdir5_invalid}"
rm -f "${TEST_HOME}/.claude/oh-my-claude.conf"

# The model-routing directive is domain-neutral: it must not inject coding
# specialists into writing/operations prompts merely to illustrate the tier.
model_routing_for_prompt() {
  local prompt="$1" sid="$2" output directive
  mkdir -p "${STATE_ROOT}/${sid}"
  echo '{"workflow_mode":"ultrawork"}' > "${STATE_ROOT}/${sid}/session_state.json"
  export OMC_MODEL_TIER="balanced"
  output="$(run_router "${prompt}" "${sid}")"
  directive="$(printf '%s' "${output}" \
    | jq -r '.hookSpecificOutput.additionalContext // ""' \
    | awk '/^SUBAGENT MODEL ROUTING / { print; exit }')"
  printf '%s' "${directive}"
  rm -rf "${STATE_ROOT:?}/${sid}"
}

writing_route="$(model_routing_for_prompt \
  '/ulw draft an executive memo for the board' 'model-tier-writing')"
operations_route="$(model_routing_for_prompt \
  '/ulw create a rollout schedule with owners, deadlines, and action items' 'model-tier-operations')"
assert_not_contains_text "balanced writing route does not inject frontend agent" \
  "frontend-developer" "${writing_route}"
assert_not_contains_text "balanced operations route does not inject backend agent" \
  "backend-api-developer" "${operations_route}"
assert_contains_text "balanced writing route retains override precedence" \
  "explicit user/env override > Council deep" "${writing_route}"
assert_contains_text "balanced operations route retains unknown/custom fallback" \
  "unknown/custom agents" "${operations_route}"
unset OMC_MODEL_TIER

# Test-portfolio reflection is part of the real coding directive, not only an
# agent-description promise. A maintenance-shaped prompt should receive the
# owner-first and affected-first guidance without requiring a separate mode.
sid6="test-portfolio-routing"
mkdir -p "${STATE_ROOT}/${sid6}"
echo '{"workflow_mode":"ultrawork"}' > "${STATE_ROOT}/${sid6}/session_state.json"
portfolio_output="$(run_router '/ulw consolidate stale redundant flaky tests in tests/test-router.sh' "${sid6}")"
portfolio_context="$(printf '%s' "${portfolio_output}" \
  | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
assert_contains_text "test portfolio route includes consolidation/retirement" \
  "portfolio consolidation or retirement" "${portfolio_context}"
assert_contains_text "test portfolio route inspects existing owners" \
  "inspect existing test owners before adding another" "${portfolio_context}"
assert_contains_text "test portfolio route runs affected proof" \
  "run affected proof after edits" "${portfolio_context}"
rm -rf "${STATE_ROOT:?}/${sid6}"

# --- Result -------------------------------------------------------------

printf '\n=== Synthetic-Prompt Filter Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
