#!/usr/bin/env bash
#
# test-inline-design-contract.sh
#
# Verifies the wave-1 fix for "drift lens for inline-emitted contracts":
#   - extract_inline_design_contract pulls the right block from agent output
#   - is_design_contract_emitter accepts UI specialists (incl. plugin-namespaced)
#     and rejects everyone else
#   - extract_design_archetype names known archetypes, ignores unknown text
#   - write_session_design_contract writes a frontmatter+body file to
#     <session>/design_contract.md, atomically, overwriting prior emissions
#   - record-subagent-summary.sh integration: SubagentStop on a UI specialist
#     captures the contract; SubagentStop on a non-UI agent does not
#   - find-design-contract.sh resolves the active session's contract
#     when one exists and prints empty when it doesn't

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="inline-contract-test-session"
ensure_session_dir

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=  %q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %q\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected match: %q\n    actual: %q\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected file: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_no_file() {
  local label="$1" path="$2"
  if [[ ! -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected file: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# is_design_contract_emitter
# ---------------------------------------------------------------------------
echo "Testing is_design_contract_emitter..."

if is_design_contract_emitter "frontend-developer"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: frontend-developer should match" >&2; fi
if is_design_contract_emitter "ios-ui-developer"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: ios-ui-developer should match" >&2; fi
if is_design_contract_emitter "plugin:foo:frontend-developer"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: namespaced frontend-developer should match" >&2; fi
if is_design_contract_emitter "plugin:bar:ios-ui-developer"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: namespaced ios-ui-developer should match" >&2; fi

if ! is_design_contract_emitter "backend-api-developer"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: backend-api-developer should NOT match" >&2; fi
if ! is_design_contract_emitter "design-reviewer"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: design-reviewer should NOT match (it's a reviewer, not an emitter)" >&2; fi
if ! is_design_contract_emitter "visual-craft-lens"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: visual-craft-lens should NOT match" >&2; fi
if ! is_design_contract_emitter ""; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL: empty agent should NOT match" >&2; fi

# ---------------------------------------------------------------------------
# extract_inline_design_contract
# ---------------------------------------------------------------------------
echo "Testing extract_inline_design_contract..."

contract_msg='Some preamble text.

## Implementation Plan

- Step 1: do this
- Step 2: do that

## Design Contract

### 1. Visual Theme & Atmosphere

Premium fintech, Stripe-inspired but committed to monochrome restraint.

### 2. Color Palette & Roles

- Background: `#0F1115`
- Accent: `#7CFFB2`

## Other Section

This should NOT appear in the extracted block.
'

result="$(extract_inline_design_contract "${contract_msg}")"
assert_contains "extracts header" "## Design Contract" "${result}"
assert_contains "extracts §1 heading" "### 1. Visual Theme" "${result}"
assert_contains "extracts §1 body" "Stripe-inspired" "${result}"
assert_contains "extracts §2 heading" "### 2. Color Palette" "${result}"
assert_contains "extracts §2 body" "0F1115" "${result}"
assert_not_contains "stops at next H2" "Other Section" "${result}"
assert_not_contains "does not include preamble" "preamble text" "${result}"
assert_not_contains "does not include Implementation Plan" "Implementation Plan" "${result}"

# Variant heading: ## Design Contract (iOS)
ios_msg='## Design Contract (iOS)

### 1. Visual Theme & Atmosphere

Halide-inspired, monochrome with one yellow accent.

## Closing Notes

End.
'
ios_result="$(extract_inline_design_contract "${ios_msg}")"
assert_contains "extracts iOS variant header" "## Design Contract (iOS)" "${ios_result}"
assert_contains "extracts iOS §1 body" "Halide-inspired" "${ios_result}"
assert_not_contains "stops before Closing Notes" "Closing Notes" "${ios_result}"

# No contract: empty output
no_contract_msg='Just some prose with no design contract block.

## Plan

Things to do.
'
empty_result="$(extract_inline_design_contract "${no_contract_msg}")"
assert_eq "empty output when no contract block" "" "${empty_result}"

# Empty input: empty output
empty_input_result="$(extract_inline_design_contract "")"
assert_eq "empty output for empty input" "" "${empty_input_result}"

# Regression: fenced code blocks containing H2 lines must NOT terminate capture.
# Quality-reviewer caught this — contracts often embed component/markdown
# examples in §4 that include `## …` lines, and the early-terminator awk
# rule was losing §5+ silently.
fence_msg='## Design Contract

### 1. Visual Theme

Body for §1.

### 4. Component Stylings

```html
## inner-heading-only-in-code-fence
<button class="btn-primary">Save</button>
```

### 5. Layout Principles

Body for §5 must be preserved.

## Closing summary

End.
'
fence_result="$(extract_inline_design_contract "${fence_msg}")"
assert_contains "fenced-H2: §5 preserved" "Body for §5" "${fence_result}"
assert_contains "fenced-H2: code-fenced ## still in capture" "inner-heading-only-in-code-fence" "${fence_result}"
assert_not_contains "fenced-H2: stops at outer ## Closing summary" "Closing summary" "${fence_result}"

# Regression: heading variants with punctuation suffixes must capture.
# Quality-reviewer caught this — `## Design Contract:` (colon),
# `## Design Contract — iOS` (em-dash), and similar were silently rejected.
colon_msg='## Design Contract: web

### 1. Visual Theme

Body.
'
colon_result="$(extract_inline_design_contract "${colon_msg}")"
assert_contains "colon-suffixed heading captures" "## Design Contract: web" "${colon_result}"
assert_contains "colon-suffixed §1 captured" "### 1. Visual Theme" "${colon_result}"

emdash_msg='## Design Contract — iOS

### 1. Visual Theme

Body.
'
emdash_result="$(extract_inline_design_contract "${emdash_msg}")"
assert_contains "em-dash heading captures" "## Design Contract — iOS" "${emdash_result}"

# Negative regression: a heading that STARTS with "Design Contract" but
# has a different word root must NOT spuriously match. The new regex
# allows any non-word char after "Contract" (or EOL); a line like
# `## Design Contracts` (with trailing 's') has 's' which IS a word
# char, so it should NOT capture.
plural_msg='## Design Contracts We Considered

### Option 1

Not a contract — a survey of options.
'
plural_result="$(extract_inline_design_contract "${plural_msg}")"
assert_eq "plural 'Contracts' does NOT spurious-match" "" "${plural_result}"

# ---------------------------------------------------------------------------
# extract_design_archetype
# ---------------------------------------------------------------------------
echo "Testing extract_design_archetype..."

# Single archetype mention
single_arch="$(extract_design_archetype 'Inspired by Stripe gradients but differentiated.')"
assert_contains "detects Stripe" "Stripe" "${single_arch}"

# Multiple archetypes
multi_arch="$(extract_design_archetype 'Closest archetype: Linear. Avoid: Stripe gradients, Vercel monochrome.')"
assert_contains "detects Linear in multi" "Linear" "${multi_arch}"
assert_contains "detects Stripe in multi" "Stripe" "${multi_arch}"
assert_contains "detects Vercel in multi" "Vercel" "${multi_arch}"

# Two-word archetype
two_word="$(extract_design_archetype 'Archetype: Things 3, with custom signature.')"
assert_contains "detects two-word archetype" "Things 3" "${two_word}"

# No known archetype
none_arch="$(extract_design_archetype 'A custom direction with no anchor.')"
assert_eq "empty when no known archetype" "" "${none_arch}"

# Empty input
empty_arch="$(extract_design_archetype "")"
assert_eq "empty input → empty output" "" "${empty_arch}"

# Regression: longest-match wins, no shadowing.
# Quality-reviewer caught this — `Mercury` greedy-matched inside
# `Mercury Weather`, polluting cross-session memory with archetypes
# the user never named. Same shadow risk for Linear/Linear iOS,
# Bear/Bear Mac, Things 3/Things 3 Mac, etc.
mw_only="$(extract_design_archetype 'Closest archetype: Mercury Weather (gradient-as-data).')"
assert_contains "Mercury Weather matches" "Mercury Weather" "${mw_only}"
mw_only_count="$(printf '%s\n' "${mw_only}" | grep -cwx 'Mercury' || true)"
assert_eq "Mercury does NOT shadow Mercury Weather" "0" "${mw_only_count}"

li_only="$(extract_design_archetype 'Inspired by Linear iOS — drawing density discipline.')"
assert_contains "Linear iOS matches" "Linear iOS" "${li_only}"
li_shadow_count="$(printf '%s\n' "${li_only}" | grep -cwx 'Linear' || true)"
assert_eq "Linear does NOT shadow Linear iOS" "0" "${li_shadow_count}"

bm_only="$(extract_design_archetype 'Bear Mac is the closest archetype.')"
assert_contains "Bear Mac matches" "Bear Mac" "${bm_only}"
bm_shadow_count="$(printf '%s\n' "${bm_only}" | grep -cwx 'Bear' || true)"
assert_eq "Bear does NOT shadow Bear Mac" "0" "${bm_shadow_count}"

# But both can match when distinct mentions exist.
both_arch="$(extract_design_archetype 'Closest is Linear iOS for ios, with the desktop also drawing from Linear sharp restraint.')"
assert_contains "both: Linear iOS present" "Linear iOS" "${both_arch}"
assert_contains "both: Linear present (separate mention)" "Linear" "${both_arch}"

# ---------------------------------------------------------------------------
# write_session_design_contract
# ---------------------------------------------------------------------------
echo "Testing write_session_design_contract..."

contract_path="${TEST_STATE_ROOT}/${SESSION_ID}/design_contract.md"

# Initial write
write_session_design_contract "frontend-developer" "## Design Contract

### 1. Visual Theme

Initial draft."

assert_file_exists "contract file created" "${contract_path}"
contents="$(cat "${contract_path}")"
assert_contains "has frontmatter agent" "agent: frontend-developer" "${contents}"
assert_contains "has frontmatter ts" "ts:" "${contents}"
assert_contains "has frontmatter cwd" "cwd:" "${contents}"
assert_contains "has body §1" "### 1. Visual Theme" "${contents}"
assert_contains "has body content" "Initial draft" "${contents}"

# Idempotent overwrite (latest wins)
write_session_design_contract "ios-ui-developer" "## Design Contract (iOS)

### 1. Visual Theme

Second iteration — Halide-inspired."

contents2="$(cat "${contract_path}")"
assert_contains "overwrite agent updated" "agent: ios-ui-developer" "${contents2}"
assert_contains "overwrite body updated" "Halide-inspired" "${contents2}"
assert_not_contains "old body removed" "Initial draft" "${contents2}"

# Empty contract → no-op (file remains from prior write)
write_session_design_contract "frontend-developer" ""
contents3="$(cat "${contract_path}")"
assert_contains "empty contract is no-op (file unchanged)" "Halide-inspired" "${contents3}"

# ---------------------------------------------------------------------------
# Integration: record-subagent-summary.sh end-to-end
# ---------------------------------------------------------------------------
echo "Testing record-subagent-summary.sh integration..."

# Reset session state for the integration tests so we can assert the
# file is created from scratch by the SubagentStop hook (not pre-existing
# from earlier helper-level tests above).
rm -f "${contract_path}"
[[ -f "${contract_path}" ]] && { echo "  FAIL: precondition reset" >&2; fail=$((fail + 1)); }

# Helper: build a fake SubagentStop payload and pipe it through the hook.
run_subagent_stop() {
  local agent="$1"
  local message="$2"
  local payload
  payload="$(jq -nc \
    --arg sid "${SESSION_ID}" \
    --arg agent "${agent}" \
    --arg msg "${message}" \
    '{session_id:$sid, agent_type:$agent, last_assistant_message:$msg}')"
  STATE_ROOT="${TEST_STATE_ROOT}" \
    OMC_DISCOVERED_SCOPE="off" \
    SESSION_ID="${SESSION_ID}" \
    bash "${SCRIPTS_DIR}/record-subagent-summary.sh" <<<"${payload}"
}

ui_message='Wrote the dashboard scaffolding. Here is the contract.

## Design Contract

### 1. Visual Theme & Atmosphere

Premium fintech with monochrome base + one accent.

### 2. Color Palette & Roles

Background `#0F1115`, accent `#7CFFB2`.

## Closing summary

Done with scaffolding.
'

run_subagent_stop "frontend-developer" "${ui_message}"
assert_file_exists "frontend-developer SubagentStop wrote contract" "${contract_path}"
written="$(cat "${contract_path}")"
assert_contains "integration: §1 captured" "Premium fintech" "${written}"
assert_contains "integration: §2 captured" "0F1115" "${written}"
assert_not_contains "integration: closing-summary excluded" "Done with scaffolding" "${written}"

# Non-UI agent: no contract written (reset and verify)
rm -f "${contract_path}"
non_ui_message='Refactored the auth middleware.

## Design Contract

This should be ignored — backend agents do not emit design contracts.
'
run_subagent_stop "backend-api-developer" "${non_ui_message}"
assert_no_file "backend-api-developer does not write contract" "${contract_path}"

# UI agent with no contract block: no file written
no_block_message='Quick CSS tweak. No new design direction.'
run_subagent_stop "frontend-developer" "${no_block_message}"
assert_no_file "UI agent without contract block does not write file" "${contract_path}"

# ---------------------------------------------------------------------------
# find-design-contract.sh
# ---------------------------------------------------------------------------
echo "Testing find-design-contract.sh..."

# Re-emit a contract so we have something to find.
run_subagent_stop "frontend-developer" "${ui_message}"
assert_file_exists "contract file ready for find-script test" "${contract_path}"

# The find-script reads $STATE_ROOT (env override) to discover the
# active session. Run it with the test root + the test session's
# stored cwd so cwd-matching prefers our session.
session_state_path="${TEST_STATE_ROOT}/${SESSION_ID}/session_state.json"
mkdir -p "$(dirname "${session_state_path}")"
jq -nc --arg cwd "${PWD}" '{cwd:$cwd}' >"${session_state_path}"

found_path="$(STATE_ROOT="${TEST_STATE_ROOT}" bash "${SCRIPTS_DIR}/find-design-contract.sh" || true)"
assert_eq "find-design-contract returns the active session's file" "${contract_path}" "${found_path}"

# When the file is missing, the script returns empty (not an error).
rm -f "${contract_path}"
empty_found="$(STATE_ROOT="${TEST_STATE_ROOT}" bash "${SCRIPTS_DIR}/find-design-contract.sh" || true)"
assert_eq "find-design-contract returns empty when file absent" "" "${empty_found}"

# When STATE_ROOT is empty (no sessions at all), still returns empty + exits 0.
empty_state_root="$(mktemp -d)"
no_session_found="$(STATE_ROOT="${empty_state_root}" bash "${SCRIPTS_DIR}/find-design-contract.sh" || true)"
assert_eq "find-design-contract: empty STATE_ROOT → empty stdout" "" "${no_session_found}"
rm -rf "${empty_state_root}"

# ---------------------------------------------------------------------------
echo
echo "PASS: ${pass}"
echo "FAIL: ${fail}"
[[ "${fail}" -eq 0 ]]
