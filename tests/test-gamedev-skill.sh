#!/usr/bin/env bash
#
# test-gamedev-skill.sh
#
# Regression net for the gamedev skill (ecosystem-integration wave).
#
# gamedev is an ORIGINAL model-invoked skill (not vendored) modeled on
# swiftui-pro: Claude Code auto-loads it on game-dev work. It guides and
# reviews Unity / Godot / web game code, encodes the frame-grounded
# verification loop (run -> capture -> evaluate visible defects -> fix),
# and routes to per-engine reference files (partial-load token discipline).
#
# What this tests:
#   (1) SKILL.md + the 3 engine reference files exist
#   (2) frontmatter has name: gamedev + a non-empty description <=1024 chars
#   (3) SKILL.md routes to each engine reference (partial-load)
#   (4) the frame-grounded loop + per-engine MCP recommendations are present
#   (5) verify.sh required_paths registers every file the skill ships
#   (6) uninstall.sh SKILL_DIRS includes skills/gamedev (no leak)
#   (7) memory/skills.md surfaces the skill (model knows to suggest it)
#   (8) README.md skill table includes the skill row
#   (9) each engine reference carries engine-specific content + a checklist
#
# Drift in any of those sites silently breaks discoverability or the loop.
# This test is part of the CI-pinned suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKILL_DIR_REL="bundle/dot-claude/skills/gamedev"
SKILL_DIR="${REPO_ROOT}/${SKILL_DIR_REL}"
SKILL_MD="${SKILL_DIR}/SKILL.md"

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

printf 'Checking gamedev skill files\n'

assert_file_exists "SKILL.md exists" "${SKILL_MD}"
engine_references=(unity godot web)
for ref in "${engine_references[@]}"; do
  assert_file_exists "references/${ref}.md exists" "${SKILL_DIR}/references/${ref}.md"
done

# ----- (2) Frontmatter: name + bounded description -----

printf 'Checking SKILL.md frontmatter\n'

assert_file_contains "frontmatter has name: gamedev" "name: gamedev" "${SKILL_MD}"

desc="$(sed -n 's/^description:[[:space:]]*//p' "${SKILL_MD}" | head -1)"
desc_len=${#desc}
if [[ "${desc_len}" -gt 0 && "${desc_len}" -le 1024 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: description must be non-empty and <=1024 chars (Anthropic skill limit); got %d\n' "${desc_len}" >&2
  fail=$((fail + 1))
fi

# The description drives auto-invocation, so it must carry trigger terms.
for term in Unity Godot; do
  if printf '%s' "${desc}" | grep -q -F -- "${term}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: description should name "%s" so it auto-fires on that engine\n' "${term}" >&2
    fail=$((fail + 1))
  fi
done

# ----- (3) SKILL.md routes to each engine reference (partial-load) -----

printf 'Checking engine routing (partial-load)\n'

for ref in "${engine_references[@]}"; do
  assert_file_contains "SKILL.md routes to references/${ref}.md" \
    "references/${ref}.md" "${SKILL_MD}"
done

# ----- (4) Frame-grounded loop + per-engine MCP recommendations -----

printf 'Checking frame-grounded loop + MCP recommendations\n'

assert_file_contains "SKILL.md names the frame-grounded loop" \
  "frame-grounded" "${SKILL_MD}"
assert_file_contains "SKILL.md recommends Unity MCP" \
  "unity-mcp" "${SKILL_MD}"
assert_file_contains "SKILL.md recommends Godot MCP" \
  "godot-mcp" "${SKILL_MD}"
assert_file_contains "SKILL.md references godogen workflow" \
  "godogen" "${SKILL_MD}"
assert_file_contains "SKILL.md keeps the User-must-verify follow-up convention" \
  "User-must-verify" "${SKILL_MD}"
# Anti-fabrication: API specifics must be routed to current docs, not memory.
assert_file_contains "SKILL.md routes API specifics to current docs" \
  "current docs" "${SKILL_MD}"

# ----- (5) verify.sh registers every file the skill ships -----

printf 'Checking verify.sh wiring\n'

VERIFY_PATH="${REPO_ROOT}/verify.sh"
assert_file_contains "verify.sh registers SKILL.md" \
  "skills/gamedev/SKILL.md" "${VERIFY_PATH}"
for ref in "${engine_references[@]}"; do
  assert_file_contains "verify.sh registers references/${ref}.md" \
    "skills/gamedev/references/${ref}.md" "${VERIFY_PATH}"
done

# ----- (6) uninstall.sh SKILL_DIRS prevents leak -----

printf 'Checking uninstall.sh wiring\n'

UNINSTALL_PATH="${REPO_ROOT}/uninstall.sh"
assert_file_contains "uninstall.sh removes skills/gamedev" \
  "skills/gamedev" "${UNINSTALL_PATH}"

# ----- (7) memory/skills.md surfaces the skill -----

printf 'Checking memory/skills.md surface\n'

MEMORY_SKILLS_PATH="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/skills.md"
assert_file_contains "memory/skills.md mentions gamedev" \
  "gamedev" "${MEMORY_SKILLS_PATH}"

# ----- (8) README.md skill table includes the skill -----

printf 'Checking README.md skill table\n'

README_PATH="${REPO_ROOT}/README.md"
assert_file_contains "README mentions gamedev" \
  "gamedev" "${README_PATH}"

# ----- (9) each engine reference carries content + a checklist -----

printf 'Checking engine reference content\n'

assert_file_contains "unity.md cites the Update-loop GetComponent pitfall" \
  "GetComponent" "${SKILL_DIR}/references/unity.md"
assert_file_contains "godot.md cites _physics_process" \
  "_physics_process" "${SKILL_DIR}/references/godot.md"
assert_file_contains "web.md cites requestAnimationFrame" \
  "requestAnimationFrame" "${SKILL_DIR}/references/web.md"
for ref in "${engine_references[@]}"; do
  assert_file_contains "${ref}.md ends with a review checklist" \
    "Review checklist" "${SKILL_DIR}/references/${ref}.md"
done

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
