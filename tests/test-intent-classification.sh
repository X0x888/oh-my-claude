#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common.sh functions directly (no SESSION_ID needed for classification)
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_intent() {
  local expected="$1"
  local input="$2"
  local actual
  actual="$(classify_task_intent "${input}")"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: "%s"\n    expected=%s actual=%s\n' "${input}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_imperative() {
  local input="$1"
  if is_imperative_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_imperative_request should match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_imperative() {
  local input="$1"
  if ! is_imperative_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_imperative_request should NOT match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

printf '=== Intent Classification Tests ===\n\n'

# --- Bare imperatives (should be execution) ---
printf 'Bare imperatives:\n'
assert_imperative "Fix the login bug"
assert_imperative "Add a retry mechanism to the API client"
assert_imperative "Implement the new auth flow"
assert_imperative "Refactor the database layer"
assert_imperative "Debug the failing test"
assert_imperative "Deploy the staging environment"
assert_imperative "Write a migration for the users table"
assert_imperative "Create a new component for the dashboard"
assert_imperative "Remove the deprecated endpoint"
assert_imperative "Update the config to use the new API key"
assert_imperative "Optimize the query performance"
assert_imperative "Merge the feature branch"
assert_imperative "Rewrite the parser to handle edge cases"
assert_imperative "Set up the CI pipeline"

# --- Questions should not be imperative ---
printf '\nQuestions should not be imperative:\n'
assert_not_imperative "What should I fix first?"
assert_not_imperative "Should we refactor this?"
assert_not_imperative "Is it better to use a queue?"
assert_not_imperative "Why is the test failing?"
assert_not_imperative "How do I deploy this?"

# --- Ambiguous verb starts should not be bare-imperative ---
printf '\nAmbiguous starts should not be bare-imperative:\n'
assert_not_imperative "Check if this approach makes sense"
assert_not_imperative "Test whether the assumption holds"
assert_not_imperative "Help me understand the architecture"
assert_not_imperative "Review this approach and tell me what you think"

# --- Polite imperatives (existing — should still work) ---
printf '\nPolite imperatives:\n'
assert_imperative "Can you fix the login bug?"
assert_imperative "Could you please add error handling?"
assert_imperative "Would you implement the new endpoint?"
assert_imperative "Please fix the flaky test"
assert_imperative "Go ahead and deploy it"
assert_imperative "I need you to refactor this module"

# --- Ambiguous verb starts classify as execution (fallthrough, not imperative) ---
printf '\nAmbiguous verbs (execution via fallthrough):\n'
assert_intent "execution" "Check if this approach makes sense"
assert_intent "execution" "Test whether the assumption holds"
assert_intent "execution" "Review the PR and merge it"

# --- Full classify_task_intent tests ---
printf '\nFull intent classification:\n'
assert_intent "execution" "Fix the login bug"
assert_intent "execution" "Add retry logic to the client"
assert_intent "execution" "Can you fix the auth flow?"
assert_intent "execution" "Please deploy the staging server"
assert_intent "advisory" "What should I fix first?"
assert_intent "advisory" "Should we refactor this?"
assert_intent "advisory" "Is it better to use a queue?"
assert_intent "continuation" "continue"
assert_intent "continuation" "keep going"
assert_intent "continuation" "pick it back up"

# --- Terse continuation phrases ---
printf '\nTerse continuation phrases:\n'
assert_intent "continuation" "next"
assert_intent "continuation" "go on"
assert_intent "continuation" "proceed"
assert_intent "continuation" "finish the rest"
assert_intent "continuation" "do the remaining work"
assert_intent "continuation" "do the rest"
assert_intent "continuation" "next, but skip the tests"
assert_intent "continuation" "go on, focus on the API layer"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
