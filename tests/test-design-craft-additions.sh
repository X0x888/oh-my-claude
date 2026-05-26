#!/usr/bin/env bash
#
# test-design-craft-additions.sh
#
# Regression net for Wave C of the 2026-05-26 deep-evaluation port wave:
# the three new vendored design-craft references.
#
#   1. `taste-skill-doctrine.md`     (Leonxlnx/taste-skill v2, MIT)
#   2. `design-for-hackers.md`       (ryanthedev/design-for-ai,   MIT)
#   3. `a11y-doctrine.md`            (fecarrico/A11Y.md,          MIT)
#
# All three are vendored verbatim with a leading HTML-comment vendoring
# header that names the upstream source, the MIT license, the vendoring
# date, and the no-hand-edit / re-pull rule. This test asserts:
#
#   (1) Each file exists with its vendoring header and the load-bearing
#       anchors that name the headline content.
#   (2) verify.sh required_paths registers all three files.
#   (3) Each of the 5 visual-craft consuming surfaces references all
#       three files. The consumers are visual-craft-lens, design-reviewer,
#       frontend-developer, ios-ui-developer, and the frontend-design
#       SKILL — same five surfaces that already inline art-taste-doctrine
#       calibration.
#   (4) The UX-trimmed consumer (design-lens) references ONLY a11y-doctrine.
#       The other two new files are visual-craft scope and MUST NOT
#       appear in design-lens — the UX/visual-craft lens boundary is the
#       whole reason the variant exists, mirroring the existing scope-
#       discipline check in tests/test-art-taste-doctrine.sh.
#   (5) Each consumer surface (5 + 1) has the literal heading
#       "Additional design-craft references" so the section that hosts
#       the references is structurally locatable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CRAFT_DIR_REL="bundle/dot-claude/quality-pack/design-craft"
CRAFT_DIR="${REPO_ROOT}/${CRAFT_DIR_REL}"

# Installed-path strings — the consumer surfaces reference the canonical
# `~/.claude/...` path so a rename forces this test to be updated
# explicitly rather than leaving stale agent pointers.
# shellcheck disable=SC2088
TASTE_REF="~/.claude/quality-pack/design-craft/taste-skill-doctrine.md"
# shellcheck disable=SC2088
HACKERS_REF="~/.claude/quality-pack/design-craft/design-for-hackers.md"
# shellcheck disable=SC2088
A11Y_REF="~/.claude/quality-pack/design-craft/a11y-doctrine.md"

pass=0
fail=0

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected file to exist: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_contains() {
  local label="$1" needle="$2" path="$3"
  if [[ ! -f "${path}" ]]; then
    printf '  FAIL: %s\n    file missing: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
    return
  fi
  if grep -q -F -- "${needle}" "${path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    %s does not contain: %q\n' "${label}" "${path}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_not_contains() {
  local label="$1" needle="$2" path="$3"
  if [[ ! -f "${path}" ]]; then
    printf '  FAIL: %s\n    file missing: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
    return
  fi
  if ! grep -q -F -- "${needle}" "${path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    %s unexpectedly contains: %q\n' "${label}" "${path}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# ----- (1) Files exist with vendoring headers and headline content -----

printf 'Checking taste-skill-doctrine.md\n'

TASTE_PATH="${CRAFT_DIR}/taste-skill-doctrine.md"
assert_file_exists "taste-skill-doctrine.md exists" "${TASTE_PATH}"
assert_file_contains "taste-skill vendoring header names upstream" \
  "Vendored verbatim from Leonxlnx/taste-skill" "${TASTE_PATH}"
assert_file_contains "taste-skill vendoring header names MIT" \
  "MIT" "${TASTE_PATH}"
# Headline content: dials + em-dash ban + Jane Doe rules.
assert_file_contains "taste-skill has DESIGN_VARIANCE dial" \
  "DESIGN_VARIANCE" "${TASTE_PATH}"
assert_file_contains "taste-skill has MOTION_INTENSITY dial" \
  "MOTION_INTENSITY" "${TASTE_PATH}"
assert_file_contains "taste-skill has VISUAL_DENSITY dial" \
  "VISUAL_DENSITY" "${TASTE_PATH}"
assert_file_contains "taste-skill has em-dash ban (§9.G)" \
  "EM-DASH BAN" "${TASTE_PATH}"
assert_file_contains "taste-skill has Jane Doe rules (§9.D)" \
  "Jane Doe" "${TASTE_PATH}"
assert_file_contains "taste-skill has italic descender clearance" \
  "ITALIC DESCENDER" "${TASTE_PATH}"

printf 'Checking design-for-hackers.md\n'

HACKERS_PATH="${CRAFT_DIR}/design-for-hackers.md"
assert_file_exists "design-for-hackers.md exists" "${HACKERS_PATH}"
assert_file_contains "hackers vendoring header names upstream" \
  "Vendored verbatim from ryanthedev/design-for-ai" "${HACKERS_PATH}"
assert_file_contains "hackers vendoring header names MIT" \
  "MIT" "${HACKERS_PATH}"
# Headline content: 10-category CHECKER + 8-phase APPLIER + Symptom→Chapter + Anti-Rationalization
assert_file_contains "hackers has CHECKER mode" \
  "CHECKER Mode" "${HACKERS_PATH}"
assert_file_contains "hackers has APPLIER mode" \
  "APPLIER Mode" "${HACKERS_PATH}"
assert_file_contains "hackers has Symptom→Chapter lookup" \
  "Symptom" "${HACKERS_PATH}"
assert_file_contains "hackers has Anti-Rationalization table" \
  "Anti-Rationalization" "${HACKERS_PATH}"
assert_file_contains "hackers credits Kadavy as source" \
  "Kadavy" "${HACKERS_PATH}"

printf 'Checking a11y-doctrine.md\n'

A11Y_PATH="${CRAFT_DIR}/a11y-doctrine.md"
assert_file_exists "a11y-doctrine.md exists" "${A11Y_PATH}"
assert_file_contains "a11y vendoring header names upstream" \
  "Vendored verbatim from fecarrico/A11Y.md" "${A11Y_PATH}"
assert_file_contains "a11y vendoring header names MIT" \
  "MIT" "${A11Y_PATH}"
# Headline content: POUR framework + severity matrix + AI Behavior Contract + DoD
assert_file_contains "a11y has POUR framework header" \
  "POUR Framework" "${A11Y_PATH}"
assert_file_contains "a11y has Severity & Impact Model" \
  "Severity" "${A11Y_PATH}"
assert_file_contains "a11y has AI Behavior Contract" \
  "AI Behavior Contract" "${A11Y_PATH}"
assert_file_contains "a11y has Definition of Done verification" \
  "Definition of Done" "${A11Y_PATH}"
assert_file_contains "a11y has Clickable Divs anti-pattern" \
  "Clickable Divs" "${A11Y_PATH}"
assert_file_contains "a11y references WCAG 2.2" \
  "WCAG 2.2" "${A11Y_PATH}"

# ----- (2) verify.sh registers all three -----

printf 'Checking verify.sh wiring\n'

VERIFY_PATH="${REPO_ROOT}/verify.sh"
assert_file_contains "verify.sh registers taste-skill-doctrine.md" \
  "design-craft/taste-skill-doctrine.md" "${VERIFY_PATH}"
assert_file_contains "verify.sh registers design-for-hackers.md" \
  "design-craft/design-for-hackers.md" "${VERIFY_PATH}"
assert_file_contains "verify.sh registers a11y-doctrine.md" \
  "design-craft/a11y-doctrine.md" "${VERIFY_PATH}"

# ----- (3) Visual-craft consumer surfaces reference all three -----

printf 'Checking visual-craft consumer surfaces\n'

visual_craft_consumers=(
  "bundle/dot-claude/agents/visual-craft-lens.md"
  "bundle/dot-claude/agents/design-reviewer.md"
  "bundle/dot-claude/agents/frontend-developer.md"
  "bundle/dot-claude/agents/ios-ui-developer.md"
  "bundle/dot-claude/skills/frontend-design/SKILL.md"
)

for rel_path in "${visual_craft_consumers[@]}"; do
  agent_path="${REPO_ROOT}/${rel_path}"
  label="${rel_path##*/}"

  assert_file_contains "${label} has 'Additional design-craft references' section" \
    "Additional design-craft references" "${agent_path}"
  assert_file_contains "${label} references taste-skill-doctrine" \
    "${TASTE_REF}" "${agent_path}"
  assert_file_contains "${label} references design-for-hackers" \
    "${HACKERS_REF}" "${agent_path}"
  assert_file_contains "${label} references a11y-doctrine" \
    "${A11Y_REF}" "${agent_path}"
done

# ----- (4) design-lens (UX-trimmed): a11y only; NOT taste-skill or design-for-hackers -----
#
# The UX-trimmed variant is scope-bounded — it excludes visual-craft
# principles by design (mirrors the existing test-art-taste-doctrine.sh
# scope-discipline check). Adding taste-skill-doctrine or design-for-
# hackers references would cross the UX/visual-craft lens boundary the
# variant was created to defend.

printf 'Checking design-lens (UX-trimmed) scope discipline\n'

DESIGN_LENS_PATH="${REPO_ROOT}/bundle/dot-claude/agents/design-lens.md"
assert_file_contains "design-lens has 'Additional design-craft reference' section" \
  "Additional design-craft reference" "${DESIGN_LENS_PATH}"
assert_file_contains "design-lens references a11y-doctrine" \
  "${A11Y_REF}" "${DESIGN_LENS_PATH}"

# The two filenames CAN appear in design-lens — in the scope-disclaimer
# paragraph naming them as out-of-scope. But the **path** form
# `~/.claude/quality-pack/...` must NOT appear, because that would
# imply the agent should load them. Asserting on the canonical path
# string (not the bare filename) makes the test tolerant of a scope-
# disclaimer that names the files while remaining strict on whether
# they are presented as load targets.
assert_file_not_contains "design-lens does NOT load taste-skill-doctrine" \
  "${TASTE_REF}" "${DESIGN_LENS_PATH}"
assert_file_not_contains "design-lens does NOT load design-for-hackers" \
  "${HACKERS_REF}" "${DESIGN_LENS_PATH}"

# ----- Summary -----

printf '\n'
total=$((pass + fail))
printf 'Results: %d/%d passed' "${pass}" "${total}"
if [[ "${fail}" -gt 0 ]]; then
  printf ' (%d FAILED)\n' "${fail}"
  exit 1
fi
printf '\n'

if [[ "${pass}" -eq 0 ]]; then
  printf 'FAIL: test ran but no checks fired\n' >&2
  exit 1
fi
exit 0
