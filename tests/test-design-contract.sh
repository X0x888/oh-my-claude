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
IOS_UI_DEV="${REPO_ROOT}/bundle/dot-claude/agents/ios-ui-developer.md"
DESIGN_LENS="${REPO_ROOT}/bundle/dot-claude/agents/design-lens.md"
VISUAL_CRAFT_LENS="${REPO_ROOT}/bundle/dot-claude/agents/visual-craft-lens.md"
COUNCIL_SKILL="${REPO_ROOT}/bundle/dot-claude/skills/council/SKILL.md"
CLASSIFIER_LIB="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

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
assert_file_exists "${IOS_UI_DEV}"
assert_file_exists "${DESIGN_LENS}"
assert_file_exists "${VISUAL_CRAFT_LENS}"
assert_file_exists "${COUNCIL_SKILL}"
assert_file_exists "${CLASSIFIER_LIB}"

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

# --- v1.15.0: iOS Design Contract in ios-ui-developer ------------------
# The iOS-specific contract carries its own 9-section adaptation. We
# assert the same canonical section names appear (web and iOS share the
# section taxonomy; differ in body content) plus iOS-specific tokens
# that prove the body is iOS-tailored, not a copy of web content.
ios_section_hits=0
for section in "${section_names[@]}"; do
  if grep -q -- "${section}" "${IOS_UI_DEV}"; then
    ios_section_hits=$((ios_section_hits + 1))
  fi
done
if (( ios_section_hits >= 8 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: ios-ui-developer.md references fewer than 8 of the 9 canonical section names (got %d)\n' "${ios_section_hits}" >&2
  fail=$((fail + 1))
fi

assert_grep "ios-ui-dev: HIG / Liquid Glass anchor" "Liquid Glass" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: SF Symbols guidance" "SF Symbols" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: Dynamic Type guidance" "Dynamic Type" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: Tier scope-aware enforcement" "Tier A" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: Tier B+ for polish (NOT preserve)" "Tier B+" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: anti-anchoring directive" "anti-anchoring" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: Things 3 archetype" "Things 3" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: Halide archetype" "Halide" "${IOS_UI_DEV}"
assert_grep_count_at_least "ios-ui-dev: no-clobber rule" "[Nn]ever auto-(write|create)" "${IOS_UI_DEV}" 1
assert_grep "ios-ui-dev: HIG re-grounding note" "verified against HIG" "${IOS_UI_DEV}"
assert_last_nonblank_line "ios-ui-dev last line carries VERDICT instruction" "VERDICT:" "${IOS_UI_DEV}"

# macOS variation must be present so router-routed macOS prompts (which
# go through ios-ui-developer per the Apple-platforms scope) actually get
# macOS-aware contract guidance, not just iOS-with-bigger-screens. Closes
# the excellence-reviewer macOS gap finding.
assert_grep "ios-ui-dev: macOS variation section" "macOS variation" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: AppKit guidance" "AppKit" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: NSSplitView guidance" "NSSplitView" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: NSToolbar guidance" "NSToolbar" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: macOS archetype Things 3 (Mac)" "Things 3 (Mac)" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: macOS archetype Raycast (Mac)" "Raycast (Mac)" "${IOS_UI_DEV}"
assert_grep "ios-ui-dev: macOS-specific anti-patterns" "iOS-port-pretending-to-be-Mac" "${IOS_UI_DEV}"

# --- v1.15.0: visual-craft-lens (council 7th lens) ---------------------
# The new lens evaluates visual craft as a council perspective, disjoint
# from design-lens (UX) and design-reviewer (stop-gate). Assert it has
# a parseable structure, lens-class VERDICT contract, and the disjoint-
# scope clause that prevents overlap with design-lens.
assert_grep "visual-craft-lens: name field" "name: visual-craft-lens" "${VISUAL_CRAFT_LENS}"
assert_grep "visual-craft-lens: lens VERDICT contract" "VERDICT: CLEAN" "${VISUAL_CRAFT_LENS}"
assert_grep "visual-craft-lens: 9-section mapping" "9-section Design Contract" "${VISUAL_CRAFT_LENS}"
assert_grep "visual-craft-lens: disjoint from design-lens" "disjoint" "${VISUAL_CRAFT_LENS}"
assert_grep "visual-craft-lens: disjoint from design-reviewer" "design-reviewer" "${VISUAL_CRAFT_LENS}"
assert_grep "visual-craft-lens: archetype anti-cloning lens" "[Aa]rchetype anti-cloning\|archetype-cloning" "${VISUAL_CRAFT_LENS}"
assert_grep "visual-craft-lens: AI-generic pattern audit" "Anti-AI-generic" "${VISUAL_CRAFT_LENS}"
assert_last_nonblank_line "visual-craft-lens last line carries VERDICT instruction" "VERDICT:" "${VISUAL_CRAFT_LENS}"

# design-lens must NO LONGER carry "Visual hierarchy" in evaluation scope
# (moved to visual-craft-lens for clean disjoint scope per metis F5).
# We assert the absence in evaluation scope (scope numbering 1-7), and
# the explicit "What to skip" entry naming visual-craft-lens.
if grep -q "^6\.\s*\*\*Visual hierarchy" "${DESIGN_LENS}"; then
  printf '  FAIL: design-lens.md still has "6. Visual hierarchy" in evaluation scope (should be removed; rescoped to visual-craft-lens)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_grep "design-lens: defers visual craft to visual-craft-lens" "visual-craft-lens" "${DESIGN_LENS}"

# Council selection guide must list visual-craft-lens.
assert_grep "council selection guide: visual-craft-lens row" "visual-craft-lens" "${COUNCIL_SKILL}"
assert_grep "council selection guide: max 7 lenses" "maximum 7" "${COUNCIL_SKILL}"
assert_grep "council selection guide: disjoint-scope note" "disjoint" "${COUNCIL_SKILL}"

# discovered_scope_capture_targets must include visual-craft-lens so its
# council findings flow into discovered_scope.jsonl (mirrors all 6 prior
# council lenses).
assert_grep "common.sh: visual-craft-lens in discovered_scope_capture_targets" "visual-craft-lens" "${COMMON_SH}"

# uninstall.sh must list visual-craft-lens.md so a clean uninstall
# removes it.
assert_grep "uninstall.sh: visual-craft-lens.md in AGENT_FILES" "visual-craft-lens.md" "${REPO_ROOT}/uninstall.sh"

# AGENTS.md must list visual-craft-lens in the lens table.
assert_grep "AGENTS.md: visual-craft-lens in lens table" "visual-craft-lens" "${REPO_ROOT}/AGENTS.md"

# --- v1.15.0: classifier extensions for context-aware taste ------------
# The new functions infer_ui_intent / infer_ui_platform / infer_ui_domain
# back the platform/intent/domain routing in the router. Assert symbol
# presence; behavioral fixtures live in test-classifier.sh extensions.
assert_grep "classifier: infer_ui_intent defined" "^infer_ui_intent\(\)" "${CLASSIFIER_LIB}"
assert_grep "classifier: infer_ui_platform defined" "^infer_ui_platform\(\)" "${CLASSIFIER_LIB}"
assert_grep "classifier: infer_ui_domain defined" "^infer_ui_domain\(\)" "${CLASSIFIER_LIB}"
assert_grep "classifier: polish-class verbs in is_ui_request" "polish_ui_actions" "${CLASSIFIER_LIB}"

# --- Behavioral smoke: classifier returns expected values ---------------
# Source the lib and exercise the new functions with disambiguating
# fixtures. Mitigates metis F3/F4 (Tier B+ behavioral test gap; polish
# vs writing-domain collision).
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${COMMON_SH}"

# Polish-class noun gating: "polish my dashboard" → UI; "polish my essay" → not UI.
if is_ui_request "polish my dashboard"; then
  pass=$((pass + 1))
else
  printf '  FAIL: is_ui_request("polish my dashboard") returned non-zero\n' >&2
  fail=$((fail + 1))
fi
if ! is_ui_request "polish my essay"; then
  pass=$((pass + 1))
else
  printf '  FAIL: is_ui_request("polish my essay") matched but should not have (essay is writing-domain)\n' >&2
  fail=$((fail + 1))
fi

# Tier B+ classification: polish-class verbs return 'polish' (NOT 'fix').
intent="$(infer_ui_intent "polish my landing page")"
if [[ "${intent}" == "polish" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_intent("polish my landing page") returned %q, expected "polish"\n' "${intent}" >&2
  fail=$((fail + 1))
fi
intent="$(infer_ui_intent "fix the button padding")"
if [[ "${intent}" == "fix" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_intent("fix the button padding") returned %q, expected "fix"\n' "${intent}" >&2
  fail=$((fail + 1))
fi
intent="$(infer_ui_intent "build me a landing page")"
if [[ "${intent}" == "build" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_intent("build me a landing page") returned %q, expected "build"\n' "${intent}" >&2
  fail=$((fail + 1))
fi

# Platform detection.
plat="$(infer_ui_platform "build an iOS app for tracking sleep" "")"
if [[ "${plat}" == "ios" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("iOS app") returned %q, expected "ios"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
plat="$(infer_ui_platform "create a CLI tool" "")"
if [[ "${plat}" == "cli" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("CLI tool") returned %q, expected "cli"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
plat="$(infer_ui_platform "redesign my macOS menu bar app" "")"
if [[ "${plat}" == "macos" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("macOS menu bar") returned %q, expected "macos"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
plat="$(infer_ui_platform "build a landing page" "")"
if [[ "${plat}" == "web" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("landing page") returned %q, expected "web"\n' "${plat}" >&2
  fail=$((fail + 1))
fi

# v1.18.0 — profile-fallback for platform-silent prompts in Swift projects.
# Before this fix, "polish my dashboard" + swift profile fell through to
# web because the case statement only matched bare "ios|macos|cli". The
# regression hit macOS SwiftUI apps mid-session (Linear/Stripe archetypes
# where Things 3 / Mercury would belong).
plat="$(infer_ui_platform "polish my dashboard" "swift,swift-macos,docs")"
if [[ "${plat}" == "macos" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("polish my dashboard", swift-macos profile) returned %q, expected "macos"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
plat="$(infer_ui_platform "polish my dashboard" "swift,swift-ios")"
if [[ "${plat}" == "ios" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("polish my dashboard", swift-ios profile) returned %q, expected "ios"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
# Bare "swift" tag (no subtype) defaults to iOS — Apple-native routing
# rather than the previous web-archetype default. Better wrong than worse.
plat="$(infer_ui_platform "polish my dashboard" "swift")"
if [[ "${plat}" == "ios" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("polish my dashboard", bare swift profile) returned %q, expected "ios"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
# v1.18.0 — bare "SwiftUI" is platform-ambiguous (works on both iOS and
# macOS). Without macOS markers in the profile, the iOS regex no longer
# fires on it and detection falls through. With swift-macos profile, the
# fallback routes to macOS — closing the macOS SwiftUI misroute.
plat="$(infer_ui_platform "polish the SwiftUI dashboard" "swift,swift-macos")"
if [[ "${plat}" == "macos" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("SwiftUI dashboard" + swift-macos) returned %q, expected "macos"\n' "${plat}" >&2
  fail=$((fail + 1))
fi
# macOS-only SwiftUI marker (MenuBarExtra) routes to macos directly via
# the regex — no profile needed.
plat="$(infer_ui_platform "build a MenuBarExtra app" "")"
if [[ "${plat}" == "macos" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_platform("MenuBarExtra app") returned %q, expected "macos"\n' "${plat}" >&2
  fail=$((fail + 1))
fi

# Domain detection.
dom="$(infer_ui_domain "build a payment dashboard")"
if [[ "${dom}" == "fintech" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_domain("payment dashboard") returned %q, expected "fintech"\n' "${dom}" >&2
  fail=$((fail + 1))
fi
dom="$(infer_ui_domain "meditation app for sleep")"
if [[ "${dom}" == "wellness" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_domain("meditation app") returned %q, expected "wellness"\n' "${dom}" >&2
  fail=$((fail + 1))
fi
dom="$(infer_ui_domain "developer tool for monitoring APIs")"
if [[ "${dom}" == "devtool" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: infer_ui_domain("developer tool") returned %q, expected "devtool"\n' "${dom}" >&2
  fail=$((fail + 1))
fi

# --- Router platform-aware injection markers ---------------------------
# Assert the router's UI hint string carries the platform-aware case
# branches (one per platform). Without these, the router would inject the
# same generic hint regardless of platform — defeating the multi-platform
# enhancement.
assert_grep "router: case branch for iOS" "Platform: iOS" "${ROUTER}"
assert_grep "router: case branch for macOS" "Platform: macOS" "${ROUTER}"
assert_grep "router: case branch for CLI" "Platform: CLI" "${ROUTER}"
assert_grep "router: case branch for web" "Platform: web" "${ROUTER}"
assert_grep "router: domain hint for fintech" "fintech" "${ROUTER}"
assert_grep "router: domain hint for wellness" "wellness" "${ROUTER}"
assert_grep "router: domain hint for devtool" "devtool" "${ROUTER}"
assert_grep "router: Tier B+ marker for polish" "Tier B\\+" "${ROUTER}"
assert_grep "router: cross-generation discipline" "Cross-generation" "${ROUTER}"

# --- Summary ------------------------------------------------------------
total=$((pass + fail))
printf '\ntest-design-contract: %d/%d passed\n' "${pass}" "${total}"

if (( fail > 0 )); then
  exit 1
fi
exit 0
