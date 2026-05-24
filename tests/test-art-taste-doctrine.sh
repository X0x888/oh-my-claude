#!/usr/bin/env bash
#
# test-art-taste-doctrine.sh
#
# Regression net for the art-taste doctrine wiring.
#
# This doctrine is the load-bearing surface that gives the design-side
# agents canonical art-historical grounding — color/composition/typography
# masters in §1–§7, the §8 non-obvious calls (Rothko-vs-colorblock,
# committee-vs-person, restraint-as-taste-vs-fear, maximalism-as-decision-
# vs-clutter), the §10 named anti-pattern catalog, and the §11 motion +
# digital-native canon (Disney 12 principles, Maeda, Tufte, Susan Kare,
# Don Norman, Bret Victor). The 4-site lockstep documented in
# `CLAUDE.md` Coordination Rules is enforced here:
#   (1) the doctrine file exists and contains the canonical citations
#       AND each of the named sections (§8, §10, §11)
#   (2) verify.sh required_paths includes the doctrine path
#   (3) each of the 6 consuming surfaces (5 agents + 1 skill) references
#       the on-disk doctrine path AND inlines key principles (so the agent
#       has baseline taste even without doing the deep Read); design-lens
#       uses the UX-trimmed 3-principle variant with explicit scope-
#       disclaimer
#   (4) CLAUDE.md Key Directories names the design-craft surface and
#       Coordination Rules includes the design-craft lockstep entry
#
# Drift in any of those sites silently degrades the workflow's design
# critique back to generic-vocabulary output — the exact failure mode
# the doctrine was shipped to close.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOCTRINE_REL="bundle/dot-claude/quality-pack/design-craft/art-taste-doctrine.md"
DOCTRINE_PATH="${REPO_ROOT}/${DOCTRINE_REL}"

# Canonical reference path used inside the agents' inlined sections.
# Tests assert the agents reference THIS exact string so a rename of the
# on-disk file forces the test to be updated explicitly rather than
# leaving stale agent pointers. The ~ is a literal grep pattern, not a
# path to expand — SC2088 is intentionally suppressed.
# shellcheck disable=SC2088
INSTALLED_REF_PATH="~/.claude/quality-pack/design-craft/art-taste-doctrine.md"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=  %q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

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

# ----- (1) Doctrine file exists and is properly grounded -----

printf 'Checking doctrine file integrity\n'

assert_file_exists "doctrine file exists" "${DOCTRINE_PATH}"

# Canonical citations the doctrine MUST carry. If a future edit removes
# any of these named figures, the doctrine has been hollowed out into
# generic vocabulary again — the exact failure mode this file closes.
# Each entry doubles as primary-source grounding for the agent that
# reads it. The list is intentionally narrow (the most load-bearing
# names from the doctrine's eight diagnostics + §10 catalog) rather
# than every artist mentioned — that keeps the regression net tight
# and reduces false failures on minor edits.
# Two-tier citation check. The substring-match tier confirms the name
# *appears somewhere* in the doctrine; the section-anchor tier confirms
# the name has its own section heading or bold inline entry, which is
# what makes the citation actually load-bearing rather than incidental.
#
# Why anchor-checks: short tokens like `Klein`, `Klimt`, `Memphis`, and
# `Bauhaus` could be satisfied by future unrelated prose that mentions
# the word in passing. The anchor tier catches the regression where the
# load-bearing section is removed but a stray mention survives.
#
# `Brockmann` (not `Müller-Brockmann`) is intentionally checked without
# the combining-mark prefix. The `ü` in `Müller-Brockmann` is encoded
# NFC (UTF-8 `c3 bc`) but a macOS HFS+/APFS roundtrip can normalize
# it to NFD (`u` + combining diaeresis) silently, which `grep -F` would
# miss byte-for-byte even though the citation is semantically present.
# Matching on the unambiguous surname removes the encoding fragility
# without weakening the regression net — `Brockmann` is rare enough that
# coincidental satisfaction is implausible.
canonical_citations=(
  "Rothko"
  "Albers"
  "Interaction of Color"
  "Dieter Rams"
  "Tschichold"
  "Hokusai"
  "Vermeer"
  "Mondrian"
  "Cartier-Bresson"
  "Fukasawa"
  "Vignelli"
  "Brockmann"
  "Klein"
  "Klimt"
  "Bauhaus"
  "Memphis"
  # §11 motion + digital-natives — added when §11 shipped; without
  # these citations the 4-site lockstep would let a future edit silently
  # delete §11 with CI staying green (caught by 2nd-wave quality review).
  "Disney"
  "Maeda"
  "Tufte"
  "Susan Kare"
  "Don Norman"
  "Bret Victor"
)

for citation in "${canonical_citations[@]}"; do
  assert_file_contains "doctrine cites ${citation}" "${citation}" "${DOCTRINE_PATH}"
done

# Anchor-tier: at least one citation per short-token name must have its
# own `###` heading or bold inline entry. This defends against the
# accidental-substring failure mode where a load-bearing section is
# removed but coincidental prose remains.
section_anchors=(
  "### Mark Rothko"
  "### Josef Albers"
  "### Yves Klein"
  "### Gustav Klimt"
  "### Hokusai"
  "### Vermeer"
  "### Piet Mondrian"
  "### Henri Cartier-Bresson"
  "**Jan Tschichold"
  "**Dieter Rams"
  "**Bauhaus**"
  "**Memphis"
  "Brockmann — Swiss grid"
  "Vignelli"
  "Fukasawa"
)

for anchor in "${section_anchors[@]}"; do
  assert_file_contains "doctrine has anchor ${anchor}" "${anchor}" "${DOCTRINE_PATH}"
done

# §8 "non-obvious calls" — the highest-leverage section per the
# doctrine's own framing. Removing the four diagnostic pairs would
# regress the doctrine to vocabulary-only.
assert_file_contains "doctrine has §8 Rothko-vs-colorblock diagnostic" "Rothko vs colorblock" "${DOCTRINE_PATH}"
assert_file_contains "doctrine has restraint-as-taste-vs-fear diagnostic" "Restraint as taste" "${DOCTRINE_PATH}"
assert_file_contains "doctrine has committee-vs-person diagnostic" "Designed by committee" "${DOCTRINE_PATH}"

# §10 named anti-patterns — these must stay enumerated so agents have
# a concrete catalog of failure shapes to recognize.
assert_file_contains "doctrine has §10 anti-pattern catalog" "§10. The art-taste failure modes" "${DOCTRINE_PATH}"

# §11 motion + digital-natives — UI is increasingly motion-driven and
# the original doctrine was thin on motion/digital. Without an anchor
# the section is unprotected (caught by 2nd-wave quality review).
assert_file_contains "doctrine has §11 motion + digital-natives section" "## §11. Motion and digital-native masters" "${DOCTRINE_PATH}"
assert_file_contains "doctrine §11 cites Disney 12 principles" "12 Basic Principles of Animation" "${DOCTRINE_PATH}"
assert_file_contains "doctrine §11 cites Laws of Simplicity" "Laws of Simplicity" "${DOCTRINE_PATH}"

# ----- (2) verify.sh required_paths includes the doctrine -----

printf 'Checking verify.sh wiring\n'

VERIFY_PATH="${REPO_ROOT}/verify.sh"
assert_file_contains "verify.sh references design-craft path" \
  "quality-pack/design-craft/art-taste-doctrine.md" \
  "${VERIFY_PATH}"

# ----- (3) Each of the 6 consuming agents references the doctrine
#           and inlines variant-appropriate key principles -----
#
# Six agents consume the doctrine. Five use the *visual-craft* variant
# (visual-craft-lens, design-reviewer, frontend-developer,
# frontend-design SKILL, ios-ui-developer) — they critique or produce
# visual surfaces and inline the 6 core visual-craft anchors (Rothko
# color depth, Albers neighbor effect, Hokusai palette discipline,
# Vermeer light coherence, Mondrian asymmetric balance, Rams
# principle #10 / restraint).
#
# The sixth (design-lens) uses the *UX-trimmed* variant — it lives in
# the UX lane (information architecture, empty/error states, feedback)
# and inlines only the three principles that transfer to UX: Cartier-
# Bresson decisive moments, Fukasawa "Without Thought", and the §8
# person-vs-committee diagnostic. Visual-craft principles are
# deliberately NOT in the design-lens variant — they belong to
# visual-craft-lens. Asserting them on design-lens would force a
# scope-bleed the agent body explicitly rejects.
#
# All 6 agents must share: the canonical doctrine reference path AND
# the literal "Art-Taste Calibration" section header — those are the
# minimum guarantees that distinguish "agent consciously calibrated"
# from "agent reverted to generic vocabulary."

printf 'Checking agent wiring\n'

# Visual-craft variant (5 agents)
visual_craft_agents=(
  "bundle/dot-claude/agents/visual-craft-lens.md:visual-craft-lens"
  "bundle/dot-claude/agents/design-reviewer.md:design-reviewer"
  "bundle/dot-claude/agents/frontend-developer.md:frontend-developer"
  "bundle/dot-claude/skills/frontend-design/SKILL.md:frontend-design SKILL"
  "bundle/dot-claude/agents/ios-ui-developer.md:ios-ui-developer"
)

visual_craft_anchors=(
  "Art-Taste Calibration"
  "Rothko"
  "Albers"
  "Hokusai"
  "Vermeer"
  "Mondrian"
  "Rams"
)

for entry in "${visual_craft_agents[@]}"; do
  rel_path="${entry%%:*}"
  label="${entry##*:}"
  agent_path="${REPO_ROOT}/${rel_path}"

  # (a) Agent must reference the canonical doctrine path so a deep
  #     Read is one tool call away.
  assert_file_contains "${label} references doctrine path" \
    "${INSTALLED_REF_PATH}" "${agent_path}"

  # (b) Agent must inline the visual-craft calibration anchors so
  #     baseline taste applies even without the deep Read.
  for anchor in "${visual_craft_anchors[@]}"; do
    assert_file_contains "${label} inlines ${anchor}" \
      "${anchor}" "${agent_path}"
  done
done

# UX-trimmed variant (design-lens — 1 agent)
ux_trimmed_agent="${REPO_ROOT}/bundle/dot-claude/agents/design-lens.md"

assert_file_contains "design-lens references doctrine path" \
  "${INSTALLED_REF_PATH}" "${ux_trimmed_agent}"
assert_file_contains "design-lens has Art-Taste Calibration header" \
  "Art-Taste Calibration" "${ux_trimmed_agent}"

# The 3 UX-transferable principles. visual-craft principles
# (Rothko/Albers/Hokusai/Vermeer/Mondrian/Rams) are deliberately
# excluded from the design-lens variant — they belong to
# visual-craft-lens.
ux_trimmed_anchors=(
  "Cartier-Bresson"
  "Fukasawa"
  "committee"
)

for anchor in "${ux_trimmed_anchors[@]}"; do
  assert_file_contains "design-lens inlines UX principle ${anchor}" \
    "${anchor}" "${ux_trimmed_agent}"
done

# Scope-bleed defense: design-lens MUST NOT pull in the visual-craft
# principles. If it does, the UX/visual-craft lens boundary the body
# explicitly defends has been crossed. The intentional-exclusion check
# is the variant's whole point.
#
# Two-part defense (replaces same-line regex; closes the
# 2nd-wave-reviewer F2 false-negative where a real bleed paired with
# disclaimer words on the SAME line could pass):
#
#   (a) The exact verbatim disclaimer paragraph must exist in
#       design-lens.md. This single line bundles all 6 visual-craft
#       principle names with the literal phrase "are scoped to
#       `visual-craft-lens`" — it is the ONLY legitimate site where
#       those names appear in design-lens.
#
#   (b) Each visual-craft principle must appear EXACTLY ONCE in
#       design-lens.md. The single legitimate occurrence is inside
#       the disclaimer paragraph asserted in (a). count=0 means the
#       disclaimer was deleted; count=2+ means a real bleed was added
#       elsewhere. Either case fails.
#
# This shape eliminates the same-line false-negative risk because the
# defense no longer depends on grep matching prose-shape — it depends
# on a structural property (single occurrence + literal anchor) that
# is hard to defeat without consciously editing both sites.
assert_file_contains "design-lens has verbatim scope-disclaimer anchor" \
  "(Rothko, Albers, Hokusai, Vermeer, Mondrian, Rams) are scoped to \`visual-craft-lens\`" \
  "${ux_trimmed_agent}"

visual_only_principles=("Rothko" "Albers" "Hokusai" "Vermeer" "Mondrian")
for principle in "${visual_only_principles[@]}"; do
  occ_count="$(grep -c -F -- "${principle}" "${ux_trimmed_agent}" 2>/dev/null || printf '0')"
  if [[ "${occ_count}" -eq 1 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: design-lens scope check — %s appears %s times (expected exactly 1, inside the disclaimer paragraph)\n' \
      "${principle}" "${occ_count}" >&2
    fail=$((fail + 1))
  fi
done

# ----- (4) CLAUDE.md Key Directories names design-craft -----

printf 'Checking CLAUDE.md wiring\n'

CLAUDE_MD_PATH="${REPO_ROOT}/CLAUDE.md"
assert_file_contains "CLAUDE.md Key Directories names design-craft" \
  "bundle/dot-claude/quality-pack/design-craft/" "${CLAUDE_MD_PATH}"
assert_file_contains "CLAUDE.md Coordination Rules covers design-craft lockstep" \
  "Adding or removing a design-craft reference" "${CLAUDE_MD_PATH}"

# ----- Summary -----

printf '\n'
total=$((pass + fail))
printf 'Results: %d/%d passed' "${pass}" "${total}"
if [[ "${fail}" -gt 0 ]]; then
  printf ' (%d FAILED)\n' "${fail}"
  exit 1
fi
printf '\n'

# Final assertion: at least one passing check fired. Defends against
# a future edit that silently neuters the test (e.g., empties the
# consuming_agents loop).
if [[ "${pass}" -eq 0 ]]; then
  printf 'FAIL: test ran but no checks fired\n' >&2
  exit 1
fi

assert_eq "test exit clean" "0" "${fail}"
