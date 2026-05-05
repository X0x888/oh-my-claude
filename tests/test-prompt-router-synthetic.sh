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

# --- Result -------------------------------------------------------------

printf '\n=== Synthetic-Prompt Filter Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
