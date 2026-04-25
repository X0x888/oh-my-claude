#!/usr/bin/env bash
# test-design-contract.sh — Regression net for the 9-section Design Contract
# baked into the UI-generation surface.
#
# Asserts the canonical Stitch DESIGN.md schema (per VoltAgent/awesome-design-md)
# is present in:
#   - bundle/dot-claude/agents/frontend-developer.md
#   - bundle/dot-claude/agents/design-reviewer.md
#   - bundle/dot-claude/skills/frontend-design/SKILL.md
#   - bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh
#
# Also asserts:
#   - Brand-archetype priors (>=10) listed in frontend-design SKILL.md
#   - DESIGN.md awareness clauses present in all four surfaces
#   - The "never auto-write/overwrite" no-clobber rule is documented
#   - Opt-out detector lives in the router with the documented tokens
#   - VERDICT contract lines on the two agent files are preserved as the
#     final non-empty line (catches the most common edit-time corruption)
#
# Without this test, the prompt-engineering surface that drives "/ulw"-mode
# UI generation can silently regress without any other gate noticing —
# verify.sh's path check, shellcheck, and bash -n cannot detect content drift.
#
# Mirrors the pattern of test-classifier.sh and test-agent-verdict-contract.sh
# (set -euo pipefail, pass/fail counters, no associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FRONTEND_DEV="${REPO_ROOT}/bundle/dot-claude/agents/frontend-developer.md"
DESIGN_REVIEWER="${REPO_ROOT}/bundle/dot-claude/agents/design-reviewer.md"
FRONTEND_DESIGN_SKILL="${REPO_ROOT}/bundle/dot-claude/skills/frontend-design/SKILL.md"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

pass=0
fail=0

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -q -- "${pattern}" "${file}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%q\n    file=%s\n' "${label}" "${pattern}" "${file}" >&2
    fail=$((fail + 1))
  fi
}

assert_grep_count_at_least() {
  local label="$1" pattern="$2" file="$3" min="$4"
  local actual
  actual=$(grep -cE -- "${pattern}" "${file}" || true)
  if (( actual >= min )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%q\n    file=%s\n    expected>=%d actual=%d\n' "${label}" "${pattern}" "${file}" "${min}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_last_nonblank_line() {
  local label="$1" expected_pattern="$2" file="$3"
  local actual
  actual=$(awk 'NF' "${file}" | tail -n 1)
  if [[ "${actual}" =~ ${expected_pattern} ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected last non-blank line to match: %q\n    actual: %q\n    file: %s\n' "${label}" "${expected_pattern}" "${actual}" "${file}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: missing file %s\n' "${file}" >&2
    fail=$((fail + 1))
  fi
}

# --- Files exist (sanity) -----------------------------------------------
assert_file_exists "${FRONTEND_DEV}"
assert_file_exists "${DESIGN_REVIEWER}"
assert_file_exists "${FRONTEND_DESIGN_SKILL}"
assert_file_exists "${ROUTER}"

# --- 9 canonical Stitch DESIGN.md section names -------------------------
# Order matches the canonical Stitch schema. Each section name is asserted
# in the three "agent-facing" surfaces (frontend-developer, design-reviewer,
# frontend-design SKILL) so an LLM seeing any one surface gets the full
# contract. The router gets a different shape (compact list); checked below.
section_names=(
  "Visual Theme & Atmosphere"
  "Color Palette & Roles"
  "Typography Rules"
  "Component Stylings"
  "Layout Principles"
  "Depth & Elevation"
  "Do's and Don'ts"
  "Responsive Behavior"
  "Agent Prompt Guide"
)

for section in "${section_names[@]}"; do
  assert_grep "9-section: '${section}' in frontend-developer.md" "${section}" "${FRONTEND_DEV}"
  assert_grep "9-section: '${section}' in frontend-design SKILL.md" "${section}" "${FRONTEND_DESIGN_SKILL}"
done

# design-reviewer's 9th lens is "DESIGN.md drift" — a reviewer-specific
# evaluation, not a contract section to author. Reviewer surface only
# needs 8 of the 9 canonical authoring sections; the 9th lens is checked
# separately as the drift handler below.
reviewer_section_hits=0
for section in "${section_names[@]}"; do
  if grep -q -- "${section}" "${DESIGN_REVIEWER}"; then
    reviewer_section_hits=$((reviewer_section_hits + 1))
  fi
done
if (( reviewer_section_hits >= 8 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: design-reviewer.md references fewer than 8 of the 9 canonical section names (got %d)\n' "${reviewer_section_hits}" >&2
  fail=$((fail + 1))
fi

# Router carries the compact list, not the full contract — assert the
# 9-section anchor phrase + at least 5 of the section names so a rewrite
# that drops the list is caught without being brittle to a one-section
# wording change.
assert_grep "router: '9-section Design Contract' anchor phrase" "9-section Design Contract" "${ROUTER}"
router_section_hits=0
for section in "${section_names[@]}"; do
  if grep -q -- "${section}" "${ROUTER}"; then
    router_section_hits=$((router_section_hits + 1))
  fi
done
if (( router_section_hits >= 5 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: router lists fewer than 5 of the 9 canonical section names (got %d)\n' "${router_section_hits}" >&2
  fail=$((fail + 1))
fi

# --- Brand-archetype priors --------------------------------------------
# Canonical home is frontend-design SKILL.md; the agent file links to a
# subset, the router lists names compactly. Assert the canonical home has
# >=10 archetype names, and that >=8 specific named archetypes appear.
core_archetypes=(
  "Linear"
  "Stripe"
  "Vercel"
  "Notion"
  "Apple"
  "Airbnb"
  "Spotify"
  "Tesla"
  "Figma"
  "Discord"
  "Raycast"
  "Anthropic"
  "Webflow"
  "Mintlify"
  "Supabase"
)

archetype_hits_skill=0
for arch in "${core_archetypes[@]}"; do
  if grep -q -- "${arch}" "${FRONTEND_DESIGN_SKILL}"; then
    archetype_hits_skill=$((archetype_hits_skill + 1))
  fi
done
if (( archetype_hits_skill >= 10 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: frontend-design SKILL.md has fewer than 10 brand archetypes (got %d)\n' "${archetype_hits_skill}" >&2
  fail=$((fail + 1))
fi

# Anti-anchoring directive — must reframe archetypes as "point of departure"
# not "starting point to emulate", to mitigate the homogenization risk.
# Use the unambiguous phrase "anti-anchoring" (not present anywhere else
# in the bundle) rather than the surrounding prose, which contains
# markdown emphasis that breaks plain-grep patterns.
assert_grep "anti-anchoring directive in SKILL" "anti-anchoring" "${FRONTEND_DESIGN_SKILL}"
assert_grep "anti-anchoring directive in frontend-developer" "anti-anchoring" "${FRONTEND_DEV}"

# --- DESIGN.md awareness ------------------------------------------------
# All four surfaces must reference DESIGN.md, and the no-clobber rule must
# appear in the two surfaces that could plausibly emit a file (skill,
# frontend-developer agent). The router's hint also carries the no-write
# rule so the user's first interaction sets expectations correctly.
assert_grep "DESIGN.md mentioned in frontend-developer" "DESIGN.md" "${FRONTEND_DEV}"
assert_grep "DESIGN.md mentioned in design-reviewer" "DESIGN.md" "${DESIGN_REVIEWER}"
assert_grep "DESIGN.md mentioned in frontend-design SKILL" "DESIGN.md" "${FRONTEND_DESIGN_SKILL}"
assert_grep "DESIGN.md mentioned in router" "DESIGN.md" "${ROUTER}"

# No-clobber clause: the literal phrase varies, but each must contain the
# phrase "never auto" (case-insensitive) AND a project-root reference, OR
# an explicit "auto-write" prohibition. We check for the strong phrasing.
assert_grep_count_at_least "no-clobber clause in SKILL" "[Nn]ever auto-(write|create)" "${FRONTEND_DESIGN_SKILL}" 1
assert_grep_count_at_least "no-clobber clause in frontend-developer" "[Nn]ever auto-(write|create)" "${FRONTEND_DEV}" 1
assert_grep_count_at_least "no-clobber clause in router" "[Nn]ever auto-(write|create|overwrite)" "${ROUTER}" 1

# DESIGN.md-as-prior framing in design-reviewer (not contract).
assert_grep "design-reviewer: DESIGN.md as prior" "prior" "${DESIGN_REVIEWER}"
assert_grep "design-reviewer: drift handling" "[Dd]rift" "${DESIGN_REVIEWER}"

# --- Scope-tier guidance ------------------------------------------------
# Mitigates F2 (9-section ritual on tiny fixes). frontend-developer must
# document Tier A/B/C; the router carries a compact form referencing all
# three so an LLM can self-tier without paging into the agent file. The
# router test asserts every tier individually — it would be silently broken
# if a future edit dropped Tier B or C while keeping Tier A.
assert_grep "scope-tier in frontend-developer (Tier A)" "Tier A" "${FRONTEND_DEV}"
assert_grep "scope-tier in frontend-developer (Tier B)" "Tier B" "${FRONTEND_DEV}"
assert_grep "scope-tier in frontend-developer (Tier C)" "Tier C" "${FRONTEND_DEV}"
assert_grep "scope-tier in router (Tier A)" "Tier A" "${ROUTER}"
assert_grep "scope-tier in router (Tier B)" "Tier B" "${ROUTER}"
assert_grep "scope-tier in router (Tier C)" "Tier C" "${ROUTER}"

# --- Anti-anchoring / differentiation directive in router ---------------
# The router carries the spirit-form ("commit to at least three things you
# will do differently") rather than the literal phrase "anti-anchoring",
# because the visible UI hint is meant for direct LLM consumption — not for
# code grep. We assert the substantive equivalent so a future edit cannot
# silently drop the differentiation directive from the most-frequently-fired
# surface and pass review on agent/skill assertions alone.
assert_grep "differentiation directive in router" "three things" "${ROUTER}"
assert_grep "differentiation directive in router (differently)" "differently" "${ROUTER}"

# --- Opt-out token detector --------------------------------------------
# The router must (a) recognize the documented opt-out tokens and (b)
# reference at least one of them in the visible UI hint so the user knows
# the escape hatch exists.
assert_grep "opt-out detector regex in router" "no design polish" "${ROUTER}"
assert_grep "opt-out detector regex in router (functional only)" "functional only" "${ROUTER}"
assert_grep "opt-out detector regex in router (backend only)" "backend only" "${ROUTER}"
assert_grep_count_at_least "opt-out detector branches in router" "ui_design_opt_out" "${ROUTER}" 2

# --- VERDICT contract preservation -------------------------------------
# Catches the most common edit-time corruption: text appended after the
# load-bearing final-line VERDICT instruction. The canonical agent prompts
# do not literally end with `VERDICT: ...` (the agent emits that at runtime);
# they end with the meta-instruction that *defines* the VERDICT contract.
# Pattern matches what test-agent-verdict-contract.sh checks: the final
# non-blank line must contain the substring `VERDICT:` — confirming the
# contract instruction was not displaced by the Design Contract additions.
assert_last_nonblank_line "frontend-developer last line carries VERDICT instruction" "VERDICT:" "${FRONTEND_DEV}"
assert_last_nonblank_line "design-reviewer last line carries VERDICT instruction" "VERDICT:" "${DESIGN_REVIEWER}"

# --- Router shell-syntax guard ----------------------------------------
# Cheap syntax check — catches a quoting mistake in the new opt-out branch
# without running the hook.
if bash -n "${ROUTER}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: bash -n failed on router\n' >&2
  fail=$((fail + 1))
fi

# --- Summary ------------------------------------------------------------
total=$((pass + fail))
printf '\ntest-design-contract: %d/%d passed\n' "${pass}" "${total}"

if (( fail > 0 )); then
  exit 1
fi
exit 0
