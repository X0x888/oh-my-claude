# ULW Workflow Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three high-impact gaps in the ULW/autowork workflow: intent classification blind spots, silent stop guard exhaustion, and lack of workflow observability.

**Architecture:** All changes are in the existing bash hook scripts under `bundle/dot-claude/skills/autowork/scripts/` and `bundle/dot-claude/quality-pack/scripts/`. One new skill (`ulw-status`) and one new script (`show-status.sh`) are added. A test harness validates intent classification logic.

**Tech Stack:** Bash, jq, Claude Code hooks

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Modify | `bundle/dot-claude/skills/autowork/scripts/common.sh` | Add bare-imperative detection to `is_imperative_request` |
| Modify | `bundle/dot-claude/skills/autowork/scripts/stop-guard.sh` | Write `guard_exhausted` state flag on give-up |
| Modify | `bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh` | Inject guard-exhaustion warning on next prompt |
| Create | `bundle/dot-claude/skills/ulw-status/SKILL.md` | Observability skill definition |
| Create | `bundle/dot-claude/skills/autowork/scripts/show-status.sh` | Status formatting script |
| Modify | `verify.sh` | Add new files to required_paths and hook_scripts |
| Create | `tests/test-intent-classification.sh` | Test harness for intent classification |

---

### Task 1: Add bare-imperative detection to intent classification

**Files:**
- Modify: `bundle/dot-claude/skills/autowork/scripts/common.sh:286-315`
- Create: `tests/test-intent-classification.sh`

- [ ] **Step 1: Create the test harness**

Create `tests/test-intent-classification.sh` with test cases that cover existing behavior plus the new bare-imperative gap:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common.sh functions directly
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

# --- Bare imperatives (NEW — these should be execution) ---
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

# --- Bare imperatives should NOT match questions ---
printf '\nQuestions should not be imperative:\n'
assert_not_imperative "What should I fix first?"
assert_not_imperative "Should we refactor this?"
assert_not_imperative "Is it better to use a queue?"
assert_not_imperative "Why is the test failing?"
assert_not_imperative "How do I deploy this?"

# --- Bare imperatives should NOT match ambiguous verbs ---
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

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
```

- [ ] **Step 2: Run the test to verify bare imperatives fail**

Run: `bash tests/test-intent-classification.sh`
Expected: FAIL — bare imperatives like "Fix the login bug" should fail `is_imperative_request` because the pattern doesn't exist yet.

- [ ] **Step 3: Add bare-imperative detection to `is_imperative_request`**

In `bundle/dot-claude/skills/autowork/scripts/common.sh`, add a new pattern block inside `is_imperative_request`, after the existing "I need/want you to" block (line ~308) and before the closing `fi`:

```bash
  # Bare imperative: starts with unambiguous action verb, no trailing question mark
  # Excludes: check, test, help, review — too ambiguous as bare starts
  elif [[ ! "${text}" =~ \?[[:space:]]*$ ]] && [[ "${text}" =~ ^[[:space:]]*(fix|implement|add|create|build|update|refactor|debug|deploy|write|make|change|modify|remove|delete|move|rename|install|configure|run|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|start|stop|enable|disable|open|close|set[[:space:]]+up|proceed)[[:space:]] ]]; then
    result=0
```

- [ ] **Step 4: Run the test to verify all cases pass**

Run: `bash tests/test-intent-classification.sh`
Expected: All tests PASS.

- [ ] **Step 5: Run existing verification**

Run: `bash verify.sh 2>&1 || true` and `bash -n bundle/dot-claude/skills/autowork/scripts/common.sh`
Expected: Both pass with no errors.

- [ ] **Step 6: Commit**

```bash
git add tests/test-intent-classification.sh bundle/dot-claude/skills/autowork/scripts/common.sh
git commit -m "feat: add bare-imperative detection to intent classification

Bare verbs like 'Fix the login bug' now correctly classify as
execution intent instead of falling through to advisory. Ambiguous
verbs (check, test, help, review) are excluded. Prompts ending with
'?' are excluded to preserve advisory classification for questions."
```

---

### Task 2: Make stop guard emit exhaustion warning

**Files:**
- Modify: `bundle/dot-claude/skills/autowork/scripts/stop-guard.sh:117-119`
- Modify: `bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh:60-61`

- [ ] **Step 1: Add guard-exhaustion state flag in stop-guard.sh**

In `bundle/dot-claude/skills/autowork/scripts/stop-guard.sh`, replace the silent give-up block (lines 117-119):

Old:
```bash
if [[ "${guard_blocks}" -ge 2 ]]; then
  rm -f "${STATE_ROOT}/.ulw_active"
  exit 0
fi
```

New:
```bash
if [[ "${guard_blocks}" -ge 2 ]]; then
  rm -f "${STATE_ROOT}/.ulw_active"
  write_state_batch \
    "guard_exhausted" "$(now_epoch)" \
    "guard_exhausted_detail" "review=${missing_review},verify=${missing_verify}"
  exit 0
fi
```

- [ ] **Step 2: Inject exhaustion warning in prompt-intent-router.sh**

In `bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh`, add a guard-exhaustion check right before the final context output block (before line 182 `if [[ "${#context_parts[@]}" -eq 0 ]]; then`):

```bash
# Guard exhaustion warning from previous response
guard_exhausted="$(read_state "guard_exhausted")"
if [[ -n "${guard_exhausted}" ]]; then
  guard_detail="$(read_state "guard_exhausted_detail")"
  context_parts+=("WARNING — PREVIOUS RESPONSE INCOMPLETE: The stop guard was exhausted after 2 blocks. Missing quality gates: ${guard_detail}. Before starting new work, verify and review the previous changes if they haven't been checked yet. Briefly tell the user about this gap.")
  write_state_batch "guard_exhausted" "" "guard_exhausted_detail" ""
fi
```

- [ ] **Step 3: Verify bash syntax**

Run: `bash -n bundle/dot-claude/skills/autowork/scripts/stop-guard.sh && bash -n bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh`
Expected: Both pass.

- [ ] **Step 4: Run full verification**

Run: `bash verify.sh 2>&1 || true`
Expected: Pass with no new errors.

- [ ] **Step 5: Commit**

```bash
git add bundle/dot-claude/skills/autowork/scripts/stop-guard.sh bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh
git commit -m "fix: warn user when stop guard is exhausted

Instead of silently allowing the stop after 2 blocks, the guard now
writes an exhaustion flag to session state. The prompt-intent-router
detects this on the next prompt and injects a warning so both the
model and user are informed of the gap."
```

---

### Task 3: Add observability via /ulw-status

**Files:**
- Create: `bundle/dot-claude/skills/ulw-status/SKILL.md`
- Create: `bundle/dot-claude/skills/autowork/scripts/show-status.sh`
- Modify: `verify.sh`

- [ ] **Step 1: Create the status formatting script**

Create `bundle/dot-claude/skills/autowork/scripts/show-status.sh`:

```bash
#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${HOME}/.claude/quality-pack/state"

# Find the most recent session directory (excluding dotfiles like .ulw_active)
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  latest_session="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v '^\.' | head -1)"
fi

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

state_file="${STATE_ROOT}/${latest_session}/session_state.json"

if [[ ! -f "${state_file}" ]]; then
  printf 'Session %s has no state file.\n' "${latest_session}"
  exit 0
fi

printf '=== ULW Session Status ===\n'
printf 'Session: %s\n\n' "${latest_session}"

jq -r '
  "Workflow mode:     \(.workflow_mode // "none")",
  "Task domain:       \(.task_domain // "unset")",
  "Task intent:       \(.task_intent // "unset")",
  "Objective:         \(.current_objective // "none" | .[0:100])",
  "",
  "--- Timestamps ---",
  "Last user prompt:  \(.last_user_prompt_ts // "never")",
  "Last edit:         \(.last_edit_ts // "never")",
  "Last verify:       \(.last_verify_ts // "never")",
  "Last review:       \(.last_review_ts // "never")",
  "",
  "--- Counters ---",
  "Stop guard blocks: \(.stop_guard_blocks // "0")",
  "Session handoffs:  \(.session_handoff_blocks // "0")",
  "Stall counter:     \(.stall_counter // "0")",
  "Advisory guards:   \(.advisory_guard_blocks // "0")",
  "",
  "--- Flags ---",
  "Has plan:          \(.has_plan // "false")",
  "Guard exhausted:   \(.guard_exhausted // "no")"
' "${state_file}"

# Show edited files if any
edits_file="${STATE_ROOT}/${latest_session}/edited_files.log"
if [[ -f "${edits_file}" ]]; then
  printf '\n--- Edited Files ---\n'
  sort -u "${edits_file}" | tail -20
fi
```

- [ ] **Step 2: Create the skill definition**

Create `bundle/dot-claude/skills/ulw-status/SKILL.md`:

```markdown
---
name: ulw-status
description: Show the current ULW session state — workflow mode, domain, intent, counters, and flags. Use for debugging or inspecting what the hooks decided.
---
# ULW Status

Run the status script and display the output to the user:

\`\`\`
bash ~/.claude/skills/autowork/scripts/show-status.sh
\`\`\`

Display the output as-is. If the session shows issues (guard exhausted, high stall counter, missing verification), briefly note what it means.
```

- [ ] **Step 3: Make show-status.sh executable and verify syntax**

Run: `chmod +x bundle/dot-claude/skills/autowork/scripts/show-status.sh && bash -n bundle/dot-claude/skills/autowork/scripts/show-status.sh`
Expected: Pass.

- [ ] **Step 4: Add new files to verify.sh**

In `verify.sh`, add to the `required_paths` array (after the ulw SKILL.md entry around line 98):

```bash
  "${CLAUDE_HOME}/skills/ulw-status/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
```

Add to the `hook_scripts` array (after the stop-guard.sh entry around line 163):

```bash
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
```

- [ ] **Step 5: Run full verification**

Run: `bash verify.sh 2>&1 || true`
Expected: Pass (new paths won't exist in `~/.claude/` yet since we're editing the bundle, but syntax checks should pass for existing scripts).

- [ ] **Step 6: Commit**

```bash
git add bundle/dot-claude/skills/ulw-status/SKILL.md bundle/dot-claude/skills/autowork/scripts/show-status.sh verify.sh
git commit -m "feat: add /ulw-status skill for workflow observability

New skill shows session state: workflow mode, domain, intent,
timestamps, counters, and flags. Helps debug what the hooks decided
and whether verification/review gates were satisfied."
```

---

### Task 4: Final integration verification

- [ ] **Step 1: Run all tests**

Run: `bash tests/test-intent-classification.sh`
Expected: All pass.

- [ ] **Step 2: Run shellcheck on changed files**

Run: `shellcheck -S warning bundle/dot-claude/skills/autowork/scripts/common.sh bundle/dot-claude/skills/autowork/scripts/stop-guard.sh bundle/dot-claude/skills/autowork/scripts/show-status.sh bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh`
Expected: No errors at warning severity.

- [ ] **Step 3: Run bash syntax check on all scripts**

Run: `bash -n bundle/dot-claude/skills/autowork/scripts/*.sh && bash -n bundle/dot-claude/quality-pack/scripts/*.sh`
Expected: All pass.

- [ ] **Step 4: Run full verify.sh**

Run: `bash verify.sh 2>&1 || true`
Expected: Pass.
