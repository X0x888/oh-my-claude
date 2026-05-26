#!/usr/bin/env bash
#
# test-swiftui-pro-skill.sh
#
# Regression net for the vendored swiftui-pro skill (Wave B of the
# 2026-05-26 deep-evaluation port wave).
#
# The skill is lifted verbatim from twostraws/SwiftUI-Agent-Skill v1.1
# (MIT, © 2026 Paul Hudson). It is a MODEL-INVOKED skill — Claude Code
# auto-loads it on SwiftUI work — so wiring lockstep is what we test:
#
#   (1) SKILL.md + LICENSE + all 9 references exist
#   (2) SKILL.md frontmatter preserves upstream identity (name,
#       license, author) AND adds vendoring provenance (bundled-from)
#   (3) LICENSE preserves the MIT text + Paul Hudson copyright
#   (4) Key LLM-failure-mode rules are present in references/api.md —
#       these are the rules the skill specifically exists to enforce;
#       drift here means upstream evolved and we silently fell behind
#   (5) verify.sh required_paths registers every file the skill ships
#   (6) uninstall.sh SKILL_DIRS includes skills/swiftui-pro so the
#       directory does not leak on uninstall
#   (7) memory/skills.md mentions the skill so the model knows to
#       suggest it during planning
#   (8) README.md skill table includes the skill row
#
# Drift in any of those sites silently breaks the skill's discoverability
# or upgrade path. This test is the regression net documented in
# CHANGELOG.md Wave B and is part of the CI-pinned suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKILL_DIR_REL="bundle/dot-claude/skills/swiftui-pro"
SKILL_DIR="${REPO_ROOT}/${SKILL_DIR_REL}"

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

# ----- (1) Skill files exist -----

printf 'Checking swiftui-pro skill files\n'

assert_file_exists "SKILL.md exists" "${SKILL_DIR}/SKILL.md"
assert_file_exists "LICENSE exists" "${SKILL_DIR}/LICENSE"

upstream_references=(
  api accessibility data design hygiene navigation performance swift views
)
for ref in "${upstream_references[@]}"; do
  assert_file_exists "references/${ref}.md exists" "${SKILL_DIR}/references/${ref}.md"
done

# ----- (2) Frontmatter preserves upstream identity + adds provenance -----

printf 'Checking SKILL.md frontmatter\n'

assert_file_contains "frontmatter has name: swiftui-pro" \
  "name: swiftui-pro" "${SKILL_DIR}/SKILL.md"
assert_file_contains "frontmatter declares MIT license" \
  "license: MIT" "${SKILL_DIR}/SKILL.md"
assert_file_contains "frontmatter credits Paul Hudson" \
  "author: Paul Hudson" "${SKILL_DIR}/SKILL.md"
assert_file_contains "frontmatter declares upstream source" \
  "bundled-from: twostraws/SwiftUI-Agent-Skill" "${SKILL_DIR}/SKILL.md"
assert_file_contains "vendoring comment names upstream license" \
  "MIT" "${SKILL_DIR}/SKILL.md"

# ----- (3) LICENSE preserves upstream copyright -----

printf 'Checking LICENSE\n'

assert_file_contains "LICENSE preserves MIT header" \
  "MIT License" "${SKILL_DIR}/LICENSE"
assert_file_contains "LICENSE preserves Paul Hudson copyright" \
  "Paul Hudson" "${SKILL_DIR}/LICENSE"

# ----- (4) Key LLM-failure-mode rules present in references/api.md -----
#
# These are the rules the skill specifically exists to enforce — they
# are the most LLM-distinctive content in the entire skill. If upstream
# evolves and we silently fall behind, these grep checks let us notice
# (a vendored skill where api.md no longer mentions modern API rules is
# evidence the lift is stale or hand-edited).

printf 'Checking api.md LLM-failure-mode rules\n'

api_rules=(
  "foregroundStyle"     # the headline rule — every LLM mistakes this
  "clipShape"           # cornerRadius() deprecation
  "tabItem"             # Tab API replaces deprecated tabItem()
  "onChange"            # 1-param variant deprecated
  "GeometryReader"      # prefer modern alternatives
  "sensoryFeedback"     # haptics modernization
  "@Entry"              # macro for EnvironmentValues
  "topBarLeading"       # not navigationBarLeading
)
for rule in "${api_rules[@]}"; do
  assert_file_contains "api.md cites '${rule}' rule" \
    "${rule}" "${SKILL_DIR}/references/api.md"
done

# ----- (5) verify.sh registers every file the skill ships -----

printf 'Checking verify.sh wiring\n'

VERIFY_PATH="${REPO_ROOT}/verify.sh"
assert_file_contains "verify.sh registers SKILL.md" \
  "skills/swiftui-pro/SKILL.md" "${VERIFY_PATH}"
assert_file_contains "verify.sh registers LICENSE" \
  "skills/swiftui-pro/LICENSE" "${VERIFY_PATH}"
# Spot-check that at least the api.md reference is registered.
# Asserting every reference inflates the test without adding signal —
# missing api.md is the load-bearing-rules failure case.
assert_file_contains "verify.sh registers references/api.md" \
  "skills/swiftui-pro/references/api.md" "${VERIFY_PATH}"

# ----- (6) uninstall.sh SKILL_DIRS prevents leak -----

printf 'Checking uninstall.sh wiring\n'

UNINSTALL_PATH="${REPO_ROOT}/uninstall.sh"
assert_file_contains "uninstall.sh removes skills/swiftui-pro" \
  "skills/swiftui-pro" "${UNINSTALL_PATH}"

# ----- (7) memory/skills.md surfaces the skill -----

printf 'Checking memory/skills.md surface\n'

MEMORY_SKILLS_PATH="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/skills.md"
assert_file_contains "memory/skills.md mentions swiftui-pro" \
  "swiftui-pro" "${MEMORY_SKILLS_PATH}"
assert_file_contains "memory/skills.md notes model-invoked" \
  "model-invoked" "${MEMORY_SKILLS_PATH}"

# ----- (8) README.md skill table includes the skill -----

printf 'Checking README.md skill table\n'

README_PATH="${REPO_ROOT}/README.md"
assert_file_contains "README skill table lists swiftui-pro" \
  "swiftui-pro" "${README_PATH}"

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
