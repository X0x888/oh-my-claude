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

assert_checkpoint() {
  local input="$1"
  if is_checkpoint_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_checkpoint_request should match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_checkpoint() {
  local input="$1"
  if ! is_checkpoint_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_checkpoint_request should NOT match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

assert_advisory() {
  local input="$1"
  if is_advisory_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_advisory_request should match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_advisory() {
  local input="$1"
  if ! is_advisory_request "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_advisory_request should NOT match: "%s"\n' "${input}" >&2
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

# --- New bare imperative verbs (v1.3.0) ---
printf '\nNew bare imperatives:\n'
assert_imperative "Treat warnings as errors"
assert_imperative "Diagnose the memory leak"
assert_imperative "Prioritize the critical bugs"
assert_imperative "Preserve the existing API contract"
assert_imperative "Ensure all tests pass before merging"
assert_imperative "Perform the database migration"
assert_imperative "Prepare the release candidate"
assert_imperative "Verify the deployment is healthy"
assert_imperative "Validate the user input"
assert_imperative "Generate the config from the template"
assert_imperative "Apply the patch to the production branch"
assert_imperative "Revert the last commit"
assert_imperative "Simplify the error handling logic"
assert_imperative "Extract the helper into a shared module"
assert_imperative "Replace the logger with Winston"
assert_imperative "Upgrade to Node 20"
assert_imperative "Scaffold the new service"
assert_imperative "Swap Redis for Memcached"
assert_imperative "Split the module into smaller files"
assert_imperative "Inline the utility function"
assert_imperative "Expose the health endpoint"
assert_imperative "Wire up the event handler"
assert_imperative "Bootstrap the project structure"
assert_imperative "Downgrade the dependency to a stable version"

# --- New polite-only verbs (bare form should NOT match) ---
printf '\nPolite-only new verbs (bare should NOT match):\n'
assert_not_imperative "Complete list of features to implement"
assert_not_imperative "Address line parsing is broken"
assert_not_imperative "Clean code principles should guide this"
assert_not_imperative "Hook into the existing middleware"
assert_not_imperative "Determine the best approach"
assert_not_imperative "Identify the bottleneck in the pipeline"
assert_not_imperative "Examine the build output carefully"
assert_not_imperative "Inspect the container logs"
assert_not_imperative "Scan for vulnerabilities in dependencies"
assert_not_imperative "Explore the codebase for patterns"
assert_not_imperative "Establish coding conventions"
assert_not_imperative "Conduct a security review"

# --- But polite forms of those verbs SHOULD match ---
printf '\nPolite forms of new verbs:\n'
assert_imperative "Can you complete the migration?"
assert_imperative "Please address the review comments"
assert_imperative "Could you clean up the temp files?"
assert_imperative "Can you determine the root cause?"
assert_imperative "Please identify the performance bottleneck"
assert_imperative "Would you examine the failing tests?"
assert_imperative "Can you inspect the build output?"
assert_imperative "Please scan for security vulnerabilities"
assert_imperative "Could you explore the data model?"
assert_imperative "Can you establish the CI pipeline?"
assert_imperative "Please conduct a thorough audit"
assert_imperative "Can you hook up the event handler?"

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

# --- ULW activation trigger (is_ulw_trigger) ---
# Covers the word-boundary regex that decides whether a UserPromptSubmit
# should flip the session into ultrawork mode. Regression guard for the
# fix where `/ulw-demo` failed to activate because `-` sat inside the
# keyword boundary class and the bare `ulw` keyword could not match
# across the `-` to the rest of `ulw-demo`.
printf '\nULW trigger detection:\n'

assert_ulw_trigger() {
  local input="$1"
  if is_ulw_trigger "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_ulw_trigger should match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_ulw_trigger() {
  local input="$1"
  if ! is_ulw_trigger "${input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: is_ulw_trigger should NOT match: "%s"\n' "${input}" >&2
    fail=$((fail + 1))
  fi
}

# Canonical triggers
assert_ulw_trigger "ulw fix the bug"
assert_ulw_trigger "ultrawork run the migration"
assert_ulw_trigger "autowork this task"
assert_ulw_trigger "sisyphus: keep going"
assert_ulw_trigger "/ulw do something"
assert_ulw_trigger "Please ulw everything"
assert_ulw_trigger "ULW fix the bug"

# ulw-demo skill invocation (the original regression trigger)
assert_ulw_trigger "ulw-demo"
assert_ulw_trigger "/ulw-demo"
assert_ulw_trigger "run ulw-demo now"
assert_ulw_trigger "I want to see ulw-demo working"

# Substring false-positives must NOT trigger
assert_not_ulw_trigger "ulwtastic release"
assert_not_ulw_trigger "preulwalar thinking"
assert_not_ulw_trigger "culwate this"
assert_not_ulw_trigger "ultraworking hours"
assert_not_ulw_trigger "autoworks fine"
assert_not_ulw_trigger "just a regular prompt"

# Boundary edge cases: suffixes and compounds must NOT trigger
assert_not_ulw_trigger "ulw-demos"        # trailing 's' breaks match
assert_not_ulw_trigger "ulw-demo-fork"    # compound hyphen after keyword

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

# New ulw/SKILL.md footer: "Apply the autowork rules to the task above." must
# be stripped by extraction so the classifier sees only the user's task body.
assert_extraction "$(printf 'Base directory: /x\n\n# ULW\n\nPrimary task:\n\nDo the thing\n\nApply the autowork rules to the task above.')" "Do the thing"

# Both legacy and current tails in one body (unlikely but must still extract cleanly).
assert_extraction "$(printf 'Primary task:\n\nDo the thing\n\nFollow the `/autowork` operating rules.\nApply the autowork rules to the task above.')" "Do the thing"

# Tail-phrase appearing inside the user's task body must NOT truncate the
# extraction. The footer phrase is only stripped when it appears as a footer
# (line-anchored). Regression guard: a task that quotes the footer phrase
# mid-sentence should be preserved intact.
assert_extraction "$(printf 'Primary task:\n\nFix the line that says Apply the autowork rules to the task above. in SKILL.md\n\nApply the autowork rules to the task above.')" "Fix the line that says Apply the autowork rules to the task above. in SKILL.md"

# Same guard for the legacy footer phrase.
assert_extraction "$(printf 'Primary task:\n\nRewrite the sentence: Follow the `/autowork` operating rules everywhere.\n\nFollow the `/autowork` operating rules.')" "Rewrite the sentence: Follow the \`/autowork\` operating rules everywhere."

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
# Checkpoint Classification Tests (is_checkpoint_request)
# ====================================================================

printf '\n=== Checkpoint Classification Tests ===\n\n'

# --- True positives: genuine checkpoint requests ---
printf 'Checkpoint true positives:\n'
assert_checkpoint "checkpoint"
assert_checkpoint "pause here"
assert_checkpoint "stop for now"
assert_checkpoint "that's enough for now"
assert_checkpoint "wrap up for now"
assert_checkpoint "done for now"
assert_checkpoint "park it for now"
assert_checkpoint "hold for now"
assert_checkpoint "one wave at a time"
assert_checkpoint "one phase at a time"
assert_checkpoint "wave 1 only"
assert_checkpoint "phase 2 only"
assert_checkpoint "first wave only"
assert_checkpoint "first phase only"
assert_checkpoint "just wave 3"
assert_checkpoint "just phase 1"
assert_not_checkpoint "for now let's move on"
assert_not_checkpoint "just the API for now"
assert_checkpoint "stop here"
assert_checkpoint "let's stop here"

# --- Continuation/resume at prompt boundaries ---
printf '\nCheckpoint boundary-scoped keywords:\n'
assert_checkpoint "continue later with the rest"
assert_checkpoint "pick up later from here"
assert_checkpoint "resume later when context is fresh"

# --- False positives: should NOT be checkpoint ---
printf '\nCheckpoint false positives:\n'
assert_not_checkpoint "leave it unchanged for now and focus on the critical path"
assert_not_checkpoint "good enough for now, keep building the auth module"
assert_not_checkpoint "skip validation for now and focus on the core logic"
assert_not_checkpoint "remain unchanged for now"
assert_not_checkpoint "for this session, focus on the API layer"
assert_not_checkpoint "scope this for this session to the API"
assert_not_checkpoint "Fix the login bug and leave the CSS unchanged for now, the priority is auth"
assert_not_checkpoint "The config is fine for now but the tests need work"

# --- Imperative guard: imperative start overrides checkpoint ---
printf '\nCheckpoint imperative guard:\n'
assert_not_checkpoint "Fix the header bug, then stop for now"
assert_not_checkpoint "Implement the feature, we can continue later"
assert_not_checkpoint "Deploy the update and pause for now"
assert_not_checkpoint "Please fix the bug and stop for now"

# --- "for now" at start-of-text: scope qualifier, not checkpoint ---
printf '\nCheckpoint for-now scope qualifier:\n'
assert_not_checkpoint "for now, fix the bug in auth"
assert_not_checkpoint "for now just focus on the tests"
assert_not_checkpoint "for now, implement the API"

# --- "stop here" / "pause here" consistency (Phase 1 — always checkpoint) ---
printf '\nCheckpoint stop/pause here consistency:\n'
assert_checkpoint "please stop here"
assert_checkpoint "please pause here"
assert_checkpoint "Fix the bug, then stop here"
assert_checkpoint "Fix the bug, then pause here"
assert_checkpoint "Can you stop here for today"

# --- "patch" as imperative verb ---
printf '\nPatch as imperative:\n'
assert_imperative "patch the vulnerability in the auth module"
assert_imperative "Can you patch this issue?"
assert_imperative "Please patch the security hole"

# ====================================================================
# Advisory Classification Tests (is_advisory_request)
# ====================================================================

printf '\n=== Advisory Classification Tests ===\n\n'

# --- True positives: genuine advisory requests ---
printf 'Advisory true positives:\n'
assert_advisory "Should we refactor this module?"
assert_advisory "What's the best approach for caching?"
assert_advisory "Is it worth fixing the legacy code?"
assert_advisory "Would it be better to use a queue?"
assert_advisory "Do you think we should migrate?"
assert_advisory "I'd like your recommendation on the architecture"
assert_advisory "What are the tradeoffs of using GraphQL?"
assert_advisory "Can you suggest an alternative approach?"
assert_advisory "I prefer TypeScript — is that reasonable?"
assert_advisory "Would you suggest that we refactor first?"
assert_advisory "What are the pros and cons of microservices?"

# --- False positives: should NOT be advisory ---
printf '\nAdvisory false positives:\n'
assert_not_advisory "make it better for real users"
assert_not_advisory "a better approach would reduce latency"
assert_not_advisory "net worth calculator implementation"
assert_not_advisory "implement the auto-suggest feature"

# ====================================================================
# Integration Regression Tests
# ====================================================================

printf '\n=== Integration Regression Tests ===\n\n'

# The original user prompt that triggered the v1.2.x regression:
# "unchanged for now" was misclassified as checkpoint
REGRESSION_PROMPT='Treat this as a long-haul audit and improvement engagement for this Chrome extension, not a quick review. Evaluate the extension end-to-end using both the live extension and the codebase. Work holistically across architecture, code quality, performance, reliability, security/privacy, ship readiness, and user experience. Pay close attention to extension-specific concerns such as permissions and host permissions, Manifest V3 architecture, service worker behavior, content scripts, background logic, message passing, storage/state handling, cross-page behavior, failure modes, and Chrome Web Store readiness. Work in repeated passes: diagnose deeply, improve the highest-value issues, validate, review, reassess, and continue iterating. Do not stop at the first decent implementation. Keep going until additional work would mostly be low-value polish, unnecessary churn, or high regression risk. Preserve the extension intent. Avoid unnecessary rewrites. Prioritize changes that make it materially more reliable, safer to ship, easier to maintain, and better for real users. When something important should remain unchanged for now, say so explicitly and explain why.'
assert_intent "execution" "${REGRESSION_PROMPT}"

# URL with question mark should not trigger advisory when imperative
assert_intent "execution" "Fix the endpoint /api/users?page=1 that returns 500"

# Scope qualifiers with "for now" in execution prompts
assert_intent "execution" "Refactor the auth module, leave the UI unchanged for now"

# Advisory with council-eligible scope
assert_intent "advisory" "Should I do a comprehensive review of the whole codebase?"
assert_intent "advisory" "What should I improve in this project?"

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
assert_domain "writing" "Write about animation in film"

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
assert_domain "research" "Research responsive design principles"
assert_domain "research" "Analyze dashboard adoption trends"
assert_domain "research" "Provide UX recommendations for mobile onboarding"
assert_domain "research" "Evaluate layout options for the homepage"

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

# --- Mixed: non-coding pairs (v1.17.0). Both domains must score ≥2 to
# avoid misclassifying a single dominant domain with a small tangential
# mention (e.g., "draft a project proposal for an AI-assisted research
# workflow" — research is the topic, not a separate work stream).
printf '\nMixed (non-coding pairs, v1.17.0):\n'
assert_domain "mixed" "Draft the memo and prepare the agenda for next week"
assert_domain "mixed" "Research the alternatives and write the recommendation memo"

# Boundary: writing prompts with operations-shaped DELIVERABLES (v1.17.0
# broadened writing_bigrams to allow articles + recap/memo/follow-up
# style nouns). A standalone writing prompt with no operations leg
# stays writing — the deliverable noun does NOT cause the prompt to
# leak into operations.
printf '\nWriting (broader bigrams: articles + operations-shaped deliverables, v1.17.0):\n'
assert_domain "writing" "Write the follow-up email to the customer about the delay"
assert_domain "writing" "Compose a recap of the Q3 review for the leadership update"
assert_domain "writing" "Draft a brief on the performance numbers for the board"

# Boundary: writing-dominant with secondary topic mention stays writing
# (operations/research mention is the topic, not separate work).
assert_domain "writing" "Draft a project proposal for an AI-assisted research workflow"

# Boundary preservation: non-coding pairs that score 1+1 must NOT mix.
# The v1.17.0 mixed_floor=2 rule for non-coding pairs is intentional — it
# preserves the pre-v1.17.0 single-domain behavior for low-confidence
# secondary signals. Pre-v1.17.0 mixed required `coding_score > 0` so
# these prompts were never mixed; v1.17.0 keeps that behavior with the
# floor while opening the door to higher-confidence non-coding pairs.
printf '\nMixed floor preservation (non-coding pairs at score=1 each must NOT mix):\n'
# "Brainstorm options and write the announcement" — research(brainstorm? no
# unigram match) + writing(announcement? not in unigrams) + write+announcement
# bigram (+1 to writing) = w=1, r=0. Doesn't mix; deterministic primary.
# Use a more concrete shape: keep one each at score 1, both unigram-only.
assert_domain "research" "Investigate the timeline"
assert_domain "operations" "Plan the meeting"

# --- Coding: design/UI signals ---
printf '\nCoding (design/UI signals):\n'
assert_domain "coding" "Build a landing page for our SaaS product"
assert_domain "coding" "Create a dashboard with charts and filters"
assert_domain "coding" "Build a responsive navigation component"
assert_domain "coding" "Style the login form with Tailwind"
assert_domain "coding" "Add animation to the hero section"
assert_domain "coding" "Add an animation to the hero section"
assert_domain "coding" "Add an animation to the cards"
assert_domain "coding" "Add some animations to the sidebar"
assert_domain "coding" "Create a Vue component for the settings page"
assert_domain "coding" "Build a responsive layout for the admin panel"
assert_domain "coding" "Create a login page for onboarding"
assert_domain "coding" "Build a pricing page for the marketing site"
assert_domain "coding" "Create a modal for the settings flow"
assert_domain "coding" "Build a settings page for the dashboard"
assert_domain "coding" "Can you design an onboarding screen?"
assert_domain "coding" "Please style an empty state"
assert_domain "coding" "Make the header responsive"

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

printf '\nCouncil positives (new project-level nouns):\n'
assert_council "evaluate my Chrome extension end to end"
assert_council "audit the website for accessibility"
assert_council "review this library for security issues"
assert_council "assess our platform for scalability"
assert_council "evaluate this package for production readiness"
assert_council "review the plugin for compatibility"
assert_council "audit this framework for best practices"
assert_council "evaluate my site for performance"

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

printf '\nCouncil negatives (new noun compound exclusions):\n'
assert_not_council "evaluate my extension manager"
assert_not_council "review the package registry"
assert_not_council "audit the plugin marketplace"
assert_not_council "evaluate the site map"
assert_not_council "review the platform version"
assert_not_council "evaluate the framework manifest"

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

# --- Tail-position imperative: mixed-intent prompts (added in 1.8.1) ---
# Prompts that open advisory ("evaluate X") but close with an explicit
# release-action ask ("then commit/push/tag") must classify as execution.
# Regression guard for the 1.8.0 session where the classifier tagged a
# comprehensive evaluate+commit+release prompt as advisory and PreTool
# blocked the user's own release checklist.
printf '\nTail-position imperative (mixed advisory + execution):\n'

# The actual failing prompt shape (abbreviated)
assert_imperative "Please comprehensively evaluate each point. After all these. Commit the changes. Do a proper version bump and tag and release."
assert_imperative "Review my branch. Then push to origin and tag v2.0."
assert_imperative "Evaluate the plan. Now commit the changes."
assert_imperative "Assess the options. Finally, release v3.0 to production."
assert_imperative "Look over this. Also, commit the staged files."
assert_imperative "Think through the design. Afterwards, deploy to staging and merge the branch."
assert_imperative "Evaluate these points. Next, commit all changes."

# End-to-end classification parity
assert_intent "execution" "Please carefully evaluate each point. After all these. Commit the changes. Do a proper version bump and tag and release."
assert_intent "execution" "What do you think of the plan? Now commit the staged files."

# Negatives: past-tense and noun uses must NOT trigger
printf '\nTail-position imperative negatives (noun/past-tense):\n'
assert_not_imperative "We pushed yesterday. The push date is set."
assert_not_imperative "The commit message is too terse. The push date slipped."
assert_not_imperative "Tell me about the recent commit history."
assert_not_imperative "What is the push cadence? I want to understand release engineering."
assert_not_imperative "Review the merge request. Explain the tag strategy."

# --- Shell test script as framework keyword (added in 1.8.1) ---
# verification_has_framework_keyword must recognize `bash tests/*.sh` and
# similar shell-test invocations so pure-bash projects score above the
# default 40 confidence threshold without having to configure a project
# test command.
printf '\nShell test script recognition in framework_keyword:\n'
assert_shell_test_match() {
  local cmd="$1"
  if verification_has_framework_keyword "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: verification_has_framework_keyword should match: "%s"\n' "${cmd}" >&2
    fail=$((fail + 1))
  fi
}
assert_shell_test_nomatch() {
  local cmd="$1"
  if ! verification_has_framework_keyword "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: verification_has_framework_keyword should NOT match: "%s"\n' "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

assert_shell_test_match "bash tests/test-install-artifacts.sh"
assert_shell_test_match "bash tests/test-e2e-hook-sequence.sh"
assert_shell_test_match "bash test-helper.sh"
assert_shell_test_match "bash test_runner.sh"
assert_shell_test_match "./tests/runner.sh"
assert_shell_test_match "./test-foo.sh"
assert_shell_test_match "bash /abs/path/tests/foo.sh"
assert_shell_test_match "sh tests/bar.sh"
assert_shell_test_match "bash foo_test.sh"

# Must NOT match: non-test scripts, read-only ops, non-.sh files
assert_shell_test_nomatch "bash example.sh"
assert_shell_test_nomatch "bash testing.sh"
assert_shell_test_nomatch "bash testdata.sh"
assert_shell_test_nomatch "cat tests/foo.sh"
assert_shell_test_nomatch "bash tests/data.json"
assert_shell_test_nomatch "ls tests/"
assert_shell_test_nomatch "bash script.sh"

# End-to-end scoring: my failing case should now clear the 40 threshold
test_score="$(score_verification_confidence "bash tests/test-install-artifacts.sh" "=== Results: 20 passed, 0 failed ===" "")"
if [[ "${test_score}" -ge 40 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: shell test score should be >= 40 (got: %s)\n' "${test_score}" >&2
  fail=$((fail + 1))
fi

# --- Reviewer-found false-positives in shell-test recognition ---
# `tests?/` without a word boundary false-positived on any directory name
# whose tail happened to end in "tests" or "test". These must NOT match.
printf '\nShell test negatives (reviewer found false-positives):\n'
assert_shell_test_nomatch "bash contests/foo.sh"
assert_shell_test_nomatch "bash latests/foo.sh"
assert_shell_test_nomatch "bash greatestsmod/foo.sh"
assert_shell_test_nomatch "bash latest-contest.sh"
assert_shell_test_nomatch "bash contest_foo.sh"

# --- Release-action polite imperatives (single-clause Please/Can-you forms) ---
# Single-clause polite asks like "Please push the changes to main." or
# "Can you tag v2.0?" were classified advisory pre-1.8.1 because the
# tail-imperative branch required a sentence boundary and the Please/
# Can-you branches did not list release-action verbs. Added in 1.8.1.
printf '\nRelease-action polite imperatives:\n'
assert_imperative "Please push the changes to main."
assert_imperative "Please commit these and tag v2.0."
assert_imperative "Please tag v2.0."
assert_imperative "Please release to staging."
assert_imperative "Please ship the build to production."
assert_imperative "Please publish the package."
assert_imperative "Please merge the PR."
assert_imperative "Could you tag v2.0 and push?"
assert_imperative "Can you publish the release notes?"
assert_imperative "Would you please ship this to staging?"

# Polite asks with non-release verbs still work (regression guard)
assert_imperative "Please fix the bug"
assert_imperative "Could you implement the login page"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
