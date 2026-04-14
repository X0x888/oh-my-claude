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
assert_imperative "Redesign the navigation component"

# --- Design/style: polite forms are imperative, bare forms are NOT ---
# "design" and "style" are noun/verb ambiguous (like "plan", "review"),
# so bare forms are excluded to prevent false positives.
assert_not_imperative "Design patterns cause problems in large codebases"
assert_not_imperative "Design is important for user retention"
assert_not_imperative "Style changes are needed in the header"
assert_imperative "Can you design a checkout flow?"
assert_imperative "Please design the login page"
assert_imperative "Could you style the navigation menu?"
assert_imperative "Please style the button components"

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

# --- Adverb-imperatives (v1.2.2: "Please carefully evaluate" pattern) ---
printf '\nAdverb imperatives:\n'
assert_imperative "Please carefully evaluate the options"
assert_imperative "Please quickly fix the login bug"
assert_imperative "Please thoroughly audit the permissions"
assert_imperative "Please absolutely refactor this"

# --- New imperative verbs (v1.2.2: evaluate/plan/audit/etc.) ---
printf '\nNew imperative verbs (polite/please forms):\n'
assert_imperative "Please evaluate the three options"
assert_imperative "Please plan the migration"
assert_imperative "Please audit the agent permissions"
assert_imperative "Please investigate the memory leak"
assert_imperative "Please research Redis vs Memcached"
assert_imperative "Please analyze the query performance"
assert_imperative "Please assess the impact of the change"
assert_imperative "Please execute the rollout plan"
assert_imperative "Please document the new API"
assert_imperative "Please extend the test suite"
assert_imperative "Please raise the retry limit"
assert_imperative "Can you evaluate the options?"
assert_imperative "Could you plan the rollout?"
assert_imperative "Would you investigate the issue?"
assert_imperative "Can you audit the permissions?"

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

# --- Skill-body extraction (v1.2.2: extract_skill_primary_task) ---
printf '\nSkill body extraction:\n'

assert_extraction() {
  local input="$1"
  local expected="$2"
  local actual
  if actual="$(extract_skill_primary_task "${input}")"; then
    :
  else
    actual=""
  fi
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: extract_skill_primary_task\n    input=%q\n    expected=%q\n    actual=%q\n' "${input}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# No marker → empty (and exit 1 surfaced as empty)
assert_extraction "plain text with no marker" ""

# Full skill expansion → extracts task body
assert_extraction "$(printf 'Base directory: /x\n\n# ULW\n\nPrimary task:\n\nDo the thing\n\nFollow the `/autowork` operating rules.')" "Do the thing"

# Missing tail marker → returns remainder after head marker
assert_extraction "$(printf 'Primary task:\n\nDo X')" "Do X"

# Leading /ulw inside task body is preserved (classify path handles stripping)
assert_extraction "$(printf 'Primary task:\n\n/ulw Do X\n\nFollow the `/autowork` operating rules.')" "/ulw Do X"

# Mid-sentence false-positive guard: the marker must be line-anchored.
# "Hello. The docs say Primary task: should be something." is not a skill body
# and must NOT trigger extraction (regression: previously extracted wrongly).
assert_extraction "Hello. The docs say Primary task: should be something. Please plan the migration." ""

# Specific pathological case that flipped classification from execution → advisory
# before the line-anchor fix: a user prompt starting with an imperative, then
# mentioning "Primary task:" mid-sentence.
assert_intent "execution" "Please fix the login bug. Primary task: do the rollout."

# --- /ulw-in-advice-wrapper regression (v1.2.2 item #4) ---
printf '\n/ulw in advice-wrapper regression:\n'

# Regression: a /ulw skill-body expansion whose quoted task contains
# "this session's" + "worth" must still classify as execution, not SM or advisory.
# This is the exact shape of the prompt that misclassified in v1.2.0.
ULW_ADVICE_WRAPPER="$(cat <<'PROMPT_EOF'
Base directory for this skill: /Users/xxxcoding/.claude/skills/ulw

# ULW

Short alias for `/autowork`. Runs the identical maximum-autonomy workflow.

Primary task:

/ulw Please evaluate, plan and implement all items in these comments: "  Next session (ranked)

  1. Cut v1.2.1 patch release

  Bottom line: [Unreleased] now has meaningful content. Per the CLAUDE.md
  release checklist, cut a patch. Low risk, procedural, ~10 minutes.

  4. Intent gate misclassification investigation

  Bottom line: This session's opening prompt ("Please carefully evaluate these comments and then carry on" + embedded /ulw blocks with concrete /ulw subject-verb commands) was classified as session-management advice, not execution by the intent gate. Worth fixing."

Follow the `/autowork` operating rules and thinking requirements exactly.
PROMPT_EOF
)"
assert_intent "execution" "${ULW_ADVICE_WRAPPER}"

# Plain-text version of the same pattern (no skill body wrapper)
PLAIN_ADVICE_WRAPPER='Please carefully evaluate these comments and then carry on: "1. Cut release. 4. This session'"'"'s prompt was misclassified. Worth fixing."'
assert_intent "execution" "${PLAIN_ADVICE_WRAPPER}"

# Genuine SM queries must still classify correctly (imperative override must not over-fire)
printf '\nGenuine SM queries (no imperative front):\n'
assert_intent "session_management" "Is it better to continue in a new session?"
assert_intent "session_management" "Do you think we should compact this session or push through?"

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

# --- Directive extraction (tests extract_continuation_directive) ---
printf '\nDirective extraction:\n'

assert_directive() {
  local input="$1"
  local expected="$2"
  local actual
  actual="$(extract_continuation_directive "${input}")"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: extract_continuation_directive "%s"\n    expected="%s" actual="%s"\n' "${input}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_directive "continue" ""
assert_directive "carry on, focus on the API layer" "focus on the API layer"
assert_directive "keep going but skip tests" "but skip tests"
assert_directive "pick it back up, do the remaining tasks" "do the remaining tasks"
assert_directive "pick up where you left off" ""
assert_directive "next, but skip the tests" "but skip the tests"
assert_directive "go on, focus on the API layer" "focus on the API layer"
assert_directive "proceed" ""
assert_directive "finish the rest" ""
assert_directive "do the remaining work, starting with auth" "starting with auth"

# ====================================================================
# Domain Classification Tests (infer_domain)
# ====================================================================

assert_domain() {
  local expected="$1"
  local input="$2"
  local actual
  actual="$(infer_domain "${input}")"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: infer_domain "%s"\n    expected=%s actual=%s\n' "${input}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

printf '\n=== Domain Classification Tests ===\n\n'

# --- Coding: strong unigram signals ---
printf 'Coding (strong signals):\n'
assert_domain "coding" "Fix the login bug in the auth module"
assert_domain "coding" "Refactor the database query layer"
assert_domain "coding" "Implement the new API endpoint"
assert_domain "coding" "Debug the failing React component"
assert_domain "coding" "Add a migration for the users schema"

# --- Coding: bigram disambiguation ---
printf '\nCoding (bigram signals):\n'
assert_domain "coding" "Write tests for the login flow"
assert_domain "coding" "Write unit tests"
assert_domain "coding" "Add tests for the new feature"
assert_domain "coding" "Create tests for edge cases"
assert_domain "coding" "Write code to handle retries"
assert_domain "coding" "Add a new endpoint for user profiles"
assert_domain "coding" "Create a handler for webhook events"
assert_domain "coding" "Update the migration to add an index"
assert_domain "coding" "Run tests and fix any failures"

# --- Writing: strong signals ---
printf '\nWriting (strong signals):\n'
assert_domain "writing" "Draft the quarterly report for leadership"
assert_domain "writing" "Write a personal statement for grad school"
assert_domain "writing" "Polish the abstract and introduction"
assert_domain "writing" "Rewrite the proposal to be more concise"

# --- Writing: bigram signals ---
printf '\nWriting (bigram signals):\n'
assert_domain "writing" "Write a paper about distributed systems"
assert_domain "writing" "Draft an email to the client about the delay"
assert_domain "writing" "Compose a memo for the team meeting"
assert_domain "writing" "Write an article about AI trends"

# --- Writing: negative keywords should NOT inflate writing ---
printf '\nWriting negatives (false positive prevention):\n'
assert_domain "coding" "Fix the bug report endpoint"
assert_domain "coding" "Fix the bug report submission endpoint"
assert_domain "coding" "Fix the POST endpoint for user creation"

# --- Research ---
printf '\nResearch:\n'
assert_domain "research" "Research the best caching strategies"
assert_domain "research" "Compare Redis vs Memcached and summarize tradeoffs"
assert_domain "research" "Investigate why latency spiked last Tuesday"
assert_domain "research" "Evaluate options for the new logging framework"
assert_domain "research" "Audit the current security posture"

# --- Operations ---
printf '\nOperations:\n'
assert_domain "operations" "Create a project plan for the Q3 launch"
assert_domain "operations" "Set up the meeting agenda for Monday"
assert_domain "operations" "Build a checklist for the release process"
assert_domain "operations" "Prioritize the roadmap items for next sprint"

# --- Mixed: coding + secondary domain both significant ---
printf '\nMixed:\n'
assert_domain "mixed" "Implement the caching layer and write a report on performance improvements"
assert_domain "mixed" "Refactor the API and summarize the architecture changes"

# --- Coding: design/UI signals ---
printf '\nCoding (design/UI signals):\n'
assert_domain "coding" "Build a landing page for our SaaS product"
assert_domain "coding" "Create a dashboard with charts and filters"
assert_domain "coding" "Build a responsive navigation component"
assert_domain "coding" "Style the login form with Tailwind"
assert_domain "coding" "Add animation to the hero section"
assert_domain "coding" "Create a Vue component for the settings page"
assert_domain "coding" "Build a responsive layout for the admin panel"

# --- Coding: design+UI bigram signals ---
printf '\nCoding (design bigram signals):\n'
assert_domain "coding" "Design a checkout form with validation"
assert_domain "coding" "Design the landing page for our app"
assert_domain "coding" "Style the card components for the dashboard"
assert_domain "coding" "Redesign the navigation sidebar"

# --- General: no strong signals ---
printf '\nGeneral:\n'
assert_domain "general" "Help me with this"
assert_domain "general" "What do you think?"
assert_domain "general" "Tell me about the weather"

# =============================================================
# Council evaluation detection
# =============================================================

assert_council() {
  local input="$1"
  if is_council_evaluation_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL (expected council): "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_council() {
  local input="$1"
  if ! is_council_evaluation_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL (unexpected council): "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

printf '\n=== Council Evaluation Detection Tests ===\n'

# --- Positive: should detect as council evaluation ---
printf '\nCouncil positives (whole-project evaluation):\n'
assert_council "evaluate my project"
assert_council "Evaluate the project and plan for improvements"
assert_council "please evaluate my project"
assert_council "assess our codebase"
assert_council "review my application"
assert_council "audit this project"
assert_council "evaluate this codebase"
assert_council "Can you review our entire product?"
assert_council "analyze the whole project"
assert_council "inspect my repo"

printf '\nCouncil positives (holistic qualifiers):\n'
assert_council "do a full project review"
assert_council "comprehensive evaluation"
assert_council "holistic review of the codebase"
assert_council "complete assessment"
assert_council "broad project analysis"
assert_council "overall project audit"

printf '\nCouncil positives (improvement questions):\n'
assert_council "what should I improve"
assert_council "what should we improve"
assert_council "what needs improvement"
assert_council "what needs to be fixed"
assert_council "what am I missing"
assert_council "what could be improved"
assert_council "what could be better"

printf '\nCouncil positives (blind spot patterns):\n'
assert_council "find blind spots in my project"
assert_council "identify gaps in the codebase"
assert_council "surface weaknesses"
assert_council "find what is missing"

printf '\nCouncil positives (evaluate and plan):\n'
assert_council "evaluate and plan for improvements"
assert_council "evaluate the project and then plan"
assert_council "plan for improvements"

# --- Negative: should NOT detect as council evaluation ---
printf '\nCouncil positives (plural and compound edge cases):\n'
assert_council "evaluate my projects"
assert_council "assess our products"

printf '\nCouncil negatives (Pattern 1: post-noun compounds):\n'
assert_not_council "evaluate my project manager"
assert_not_council "evaluate my project manager's performance"
assert_not_council "review my project plan"
assert_not_council "audit the project structure"
assert_not_council "evaluate my product team"
assert_not_council "evaluate my project documentation"
assert_not_council "evaluate my product roadmap"
assert_not_council "evaluate my product backlog"
assert_not_council "evaluate my project dependencies"
assert_not_council "evaluate my project configuration"
assert_not_council "evaluate my product strategy"

printf '\nCouncil negatives (narrowing qualifiers — scoped to specific artifacts):\n'
assert_not_council "what should I improve in this function"
assert_not_council "find what is missing in the tests"
assert_not_council "what am I missing in my error handling"
assert_not_council "identify what config option is missing from the docs"
assert_not_council "what needs to be fixed in the database query"
assert_not_council "what should I improve in this PR"
assert_not_council "what should I improve in this commit"
assert_not_council "review and improve this function"

printf '\nCouncil negatives (Pattern 5: scoped improve targets):\n'
assert_not_council "plan for improvements to the login flow"
assert_not_council "plan for improvements to the database layer"
assert_not_council "plan for improvements to the API"
assert_not_council "review and improve the tests"
assert_not_council "review and improve the error handling"
assert_not_council "review and improve authentication"

printf '\nCouncil positives (Pattern 5: improvements to project-level targets):\n'
assert_council "plan for improvements to the project"
assert_council "plan for improvements to the codebase"
assert_council "plan for improvements to the application"

printf '\nCouncil negatives (architectural/subsystem narrowing):\n'
assert_not_council "what am I missing in error handling"
assert_not_council "what am I missing from the architecture"
assert_not_council "what should I improve about authentication"
assert_not_council "find gaps in security testing"
assert_not_council "identify blind spots in the API design"

printf '\nCouncil negatives (focused requests):\n'
assert_not_council "fix this bug"
assert_not_council "implement the login page"
assert_not_council "add error handling to the upload endpoint"
assert_not_council "review this PR"
assert_not_council "debug the authentication flow"
assert_not_council "write tests for the user model"
assert_not_council "refactor the database module"
assert_not_council "what does this function do"
assert_not_council "explain the architecture"
assert_not_council "how does the caching work"
assert_not_council "should I use Redis or Memcached"

# --- Git operations as weak coding signals ---
printf '\nDomain: git operations as coding context:\n'

# Git keywords alone are weak — need 3+ to trigger coding
assert_domain "coding" "commit all changes and push to the remote branch"
assert_domain "coding" "merge the feature branch, rebase onto main, then push"
assert_domain "coding" "cherry-pick the fix commit and tag the release"
# Single git keyword is not enough alone
assert_domain "general" "commit this"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
