#!/usr/bin/env bash
# v1.36.x Wave 5 discovery & status surfaces regression tests.
#
# Covers F-020 (symptom→skill quick-table at top of /skills),
# F-021 (/whats-new skill: SKILL.md + show-whats-new.sh script),
# F-022 (/ulw-time + /ulw-report accept --double-dash flags AND
# positional args, matching /ulw-status grammar), F-023 (first-ULW
# demo nudge with sentinel), F-025 (/ulw-status --changed filter).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHOW_TIME="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-time.sh"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"
SHOW_STATUS="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"
SHOW_WHATS_NEW="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-whats-new.sh"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); }
fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# F-020 — /skills index has a Symptom → Skill quick-table at top.
# ----------------------------------------------------------------------
printf '\n--- F-020: /skills symptom-table at top ---\n'

skills_md="${REPO_ROOT}/bundle/dot-claude/skills/skills/SKILL.md"
if grep -qE "^## Symptom → Skill" "${skills_md}"; then
  ok
else
  fail_msg "F-020: missing 'Symptom → Skill' header in skills/SKILL.md"
fi

# Quick-table should appear ABOVE phase-grouped tables (before "### Onboarding").
quick_line=$(grep -n "Symptom → Skill" "${skills_md}" | head -1 | cut -d: -f1)
phases_line=$(grep -n "^### Onboarding" "${skills_md}" | head -1 | cut -d: -f1)
if [[ -n "${quick_line}" && -n "${phases_line}" && "${quick_line}" -lt "${phases_line}" ]]; then
  ok
else
  fail_msg "F-020: symptom-table (line ${quick_line:-?}) should be above phase-grouped tables (line ${phases_line:-?})"
fi

# ----------------------------------------------------------------------
# F-021 — /whats-new skill exists with SKILL.md and backing script.
# ----------------------------------------------------------------------
printf '\n--- F-021: /whats-new SKILL + script + behavior ---\n'

if [[ -f "${REPO_ROOT}/bundle/dot-claude/skills/whats-new/SKILL.md" ]]; then
  ok
else
  fail_msg "F-021: missing skills/whats-new/SKILL.md"
fi

if [[ -x "${SHOW_WHATS_NEW}" ]]; then
  ok
else
  fail_msg "F-021: missing or non-executable show-whats-new.sh"
fi

# Behavior — empty conf → graceful "no installed_version" message.
mkdir -p "${TEST_TMP}/empty-home/.claude"
out_empty="$(HOME="${TEST_TMP}/empty-home" bash "${SHOW_WHATS_NEW}" 2>&1 || true)"
if [[ "${out_empty}" == *"No installed_version"* ]]; then
  ok
else
  fail_msg "F-021: empty conf should produce 'No installed_version' message (got: ${out_empty})"
fi

# Behavior — drift detected → renders changelog delta.
mkdir -p "${TEST_TMP}/drift-home/.claude"
cat > "${TEST_TMP}/drift-home/.claude/oh-my-claude.conf" <<EOF
installed_version=1.34.0
repo_path=${REPO_ROOT}
EOF
out_drift="$(HOME="${TEST_TMP}/drift-home" bash "${SHOW_WHATS_NEW}" 2>&1 || true)"
if [[ "${out_drift}" == *"changelog delta"* ]] && [[ "${out_drift}" == *"v1.34.0"* ]]; then
  ok
else
  fail_msg "F-021: drift case should render changelog delta with installed version"
fi

# ----------------------------------------------------------------------
# F-022 — /ulw-time + /ulw-report accept --double-dash flag AND positional.
# ----------------------------------------------------------------------
printf '\n--- F-022: arg grammar uniformity ---\n'

# show-time.sh accepts --week as alias for week.
if grep -qE '\-\-week\)[[:space:]]+MODE="week"' "${SHOW_TIME}"; then
  ok
else
  fail_msg "F-022: show-time.sh missing --week mapping"
fi

# show-report.sh accepts --week.
if grep -qE '\-\-week\)[[:space:]]+MODE="week"' "${SHOW_REPORT}"; then
  ok
else
  fail_msg "F-022: show-report.sh missing --week mapping"
fi

# Functional: bash show-time.sh --week parses without "unknown mode" error.
out_time="$(bash "${SHOW_TIME}" --week 2>&1 || true)"
if [[ "${out_time}" != *"unknown mode"* ]]; then
  ok
else
  fail_msg "F-022: --week should be accepted by show-time, got: ${out_time}"
fi

out_report="$(bash "${SHOW_REPORT}" --week 2>&1 | head -3 || true)"
if [[ "${out_report}" != *"unknown mode"* ]]; then
  ok
else
  fail_msg "F-022: --week should be accepted by show-report"
fi

# ----------------------------------------------------------------------
# F-023 — first_ulw_demo_nudge directive in router; sentinel created.
# ----------------------------------------------------------------------
printf '\n--- F-023: first-ULW demo nudge directive ---\n'

if grep -qE 'first_ulw_demo_nudge' "${ROUTER}"; then
  ok
else
  fail_msg "F-023: prompt-intent-router missing first_ulw_demo_nudge directive"
fi

# The sentinel path must be under HOME/.claude/quality-pack/ to follow
# the cross-session-data convention.
if grep -qE '\.demo_completed' "${ROUTER}"; then
  ok
else
  fail_msg "F-023: router missing .demo_completed sentinel reference"
fi

# ----------------------------------------------------------------------
# F-025 — /ulw-status --changed filter for non-default flags.
# ----------------------------------------------------------------------
printf '\n--- F-025: /ulw-status --changed filter ---\n'

if grep -qE '\-\-changed\|\-\-diff\|changed\|diff' "${SHOW_STATUS}"; then
  ok
else
  fail_msg "F-025: show-status missing --changed/--diff flag handling"
fi

if grep -qE 'CHANGED_ONLY' "${SHOW_STATUS}"; then
  ok
else
  fail_msg "F-025: show-status missing CHANGED_ONLY mode variable"
fi

# Functional: --changed implies --explain and produces a non-error result
# even when no flags differ from defaults (clean install case).
mkdir -p "${TEST_TMP}/clean-home/.claude"
out_changed="$(HOME="${TEST_TMP}/clean-home" bash "${SHOW_STATUS}" --explain --changed 2>&1 || true)"
if [[ "${out_changed}" == *"No flags differ from defaults"* ]] \
   || [[ "${out_changed}" == *"flag rationale"* ]]; then
  ok
else
  fail_msg "F-025: --changed should produce a coherent output even on clean install (got: ${out_changed})"
fi

# Help text mentions --changed.
out_help="$(bash "${SHOW_STATUS}" --help 2>&1 || true)"
if [[ "${out_help}" == *"--changed"* ]]; then
  ok
else
  fail_msg "F-025: --help should mention --changed"
fi

# ----------------------------------------------------------------------
printf '\n=== Wave 5 discovery tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
