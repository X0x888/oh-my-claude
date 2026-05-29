#!/usr/bin/env bash
#
# test-intellectual-craft-doctrine.sh
#
# Regression net for the intellectual-craft doctrine wiring.
#
# This doctrine names eight operational moves of mind distilled from
# named physicists and philosophers (Feynman, Wheeler, Socrates, Fermi,
# Bohr, Popper, Wittgenstein, Lakatos). It sits in the global @-include
# memory chain because *thinking* applies to every session, not just to
# specialist deliberation — distinct from art-taste-doctrine.md, which
# is scoped to design surfaces and loaded on demand.
#
# The 4-site memory-file lockstep documented in `CLAUDE.md` Coordination
# Rules is enforced here AND in `tests/test-coordination-rules.sh`
# Contract 6 (which auto-discovers any *.md in the memory dir). This
# file's additional job is to assert the doctrine's *content* invariants
# — the eight named figures, the eight instrument headings, the
# defensive `What this file is — and is NOT` section, and the inline
# references in the seven deliberative specialist agents.
#
# If any assertion below fails, the doctrine has been hollowed out into
# generic priming or a deliberative agent has lost its instrument
# anchoring — both are the exact failure modes the doctrine closes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOCTRINE_REL="bundle/dot-claude/quality-pack/memory/intellectual-craft.md"
DOCTRINE_PATH="${REPO_ROOT}/${DOCTRINE_REL}"
BUNDLE_CLAUDE_MD="${REPO_ROOT}/bundle/dot-claude/CLAUDE.md"
VERIFY_SH="${REPO_ROOT}/verify.sh"

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

# ----- (1) Doctrine file integrity -----

printf 'Checking doctrine file integrity\n'

assert_file_exists "doctrine file exists" "${DOCTRINE_PATH}"

# The eight named figures. Removing any of these collapses the doctrine
# back to generic "think harder" priming — the regress that
# model-robustness.md warned against. Each appears multiple times in
# the doctrine; the substring check confirms the figure has a section.
for figure in Feynman Wheeler Socrates Fermi Bohr Popper Wittgenstein Lakatos; do
  assert_file_contains "doctrine names ${figure}" "${figure}" "${DOCTRINE_PATH}"
done

# The eight instrument section headings. These are the load-bearing
# anchor each agent reaches for; a numbered heading rename would silently
# break the references in the deliberative agents below.
assert_file_contains "instrument heading #1 Feynman test" "### 1. The Feynman test" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #2 Wheeler test" "### 2. The Wheeler test" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #3 Socratic move" "### 3. The Socratic move" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #4 Fermi probe" "### 4. The Fermi probe" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #5 Bohr probe" "### 5. The Bohr probe" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #6 Popper test" "### 6. The Popper test" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #7 Wittgenstein discipline" "### 7. The Wittgenstein discipline" "${DOCTRINE_PATH}"
assert_file_contains "instrument heading #8 Lakatos move" "### 8. The Lakatos move" "${DOCTRINE_PATH}"

# Verdict-challenge discipline (this wave): shipped as the SYMMETRIC HALF of
# Popper #6 (own-PASS-insufficient + incoming-verdict-not-automatic), NOT a 9th
# instrument — a fresh abstraction-critic ruled the standalone form solving-by-
# accretion + an anti-finding inversion risk. These nets armor the content AND
# guard the chosen shape (no "### 9." heading; count stays eight).
assert_file_contains "Popper #6 incoming-verdict symmetric half present" "symmetric half" "${DOCTRINE_PATH}"
assert_file_contains "verdict-challenge anti-finding inversion guard present" "anti-finding bypass" "${DOCTRINE_PATH}"
assert_file_contains "verdict-challenge bounded (not a debate loop)" "not a debate loop" "${DOCTRINE_PATH}"
assert_file_contains "verdict-challenge carve-out excludes mechanical gate blocks" "does NOT license reasoning around a stop-guard" "${DOCTRINE_PATH}"
if grep -Eq '^### 9\.' "${DOCTRINE_PATH}"; then
  printf '  FAIL: verdict-challenge must NOT ship as a 9th instrument heading — the abstraction-critic verdict was extend Popper #6, keep the count at eight\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# Defensive structure — the "What this file is and is NOT" section
# closes the doctrine-layering regress that model-robustness.md warned
# against. Removing this section is the same anti-pattern class as
# softening the no-defer contract; assert the anchor explicitly.
assert_file_contains "defensive what-this-is-NOT section" \
  "## What this file is — and is NOT" "${DOCTRINE_PATH}"

# Coupling section — without this, the doctrine drifts away from its
# siblings and starts looking like a substitute for the structural
# mechanisms it explicitly is not. Assert the section anchor.
assert_file_contains "coupling section to other doctrine" \
  "## Coupling to the rest of the doctrine" "${DOCTRINE_PATH}"

# Each instrument carries a 'The move:' line (concrete operational
# action) AND a 'Catches:' line (the harness-named failure mode it
# addresses). Bulk-check the marker counts via grep -c.
move_count="$(grep -c -E '^\*\*The move:\*\*' "${DOCTRINE_PATH}" || printf 0)"
catches_count="$(grep -c -E '^\*\*Catches:\*\*' "${DOCTRINE_PATH}" || printf 0)"
if [[ "${move_count}" -ge 8 && "${catches_count}" -ge 8 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: each instrument must carry "The move:" + "Catches:" — got %d moves, %d catches (need ≥8 each)\n' \
    "${move_count}" "${catches_count}" >&2
  fail=$((fail + 1))
fi

# ----- (2) @-include wiring -----

printf '\nChecking @-include wiring\n'

assert_file_contains "intellectual-craft.md @-included" \
  "@~/.claude/quality-pack/memory/intellectual-craft.md" "${BUNDLE_CLAUDE_MD}"

# ----- (3) verify.sh required_paths wiring -----

printf '\nChecking verify.sh required_paths\n'

assert_file_contains "intellectual-craft.md in verify.sh required_paths" \
  '${CLAUDE_HOME}/quality-pack/memory/intellectual-craft.md' "${VERIFY_SH}"

# ----- (4) Deliberative-specialist agent references -----
#
# The doctrine is globally loaded, but specialist agents start with their
# own system prompts and do not inherit the user's @-include chain the
# same way the main thread does. The seven deliberative specialists below
# each get an inline reference to the doctrine + at least one assigned
# instrument inlined so the agent has baseline access to the moves of
# mind even before reaching for the deep doctrine read.
#
# The instrument-per-agent assignment (one canonical anchor per agent,
# additional inlines allowed) is enforced below as a strong-named token:
#
#   oracle             → Feynman test + Popper test
#   metis              → Fermi probe + Bohr probe
#   abstraction-critic → Socratic move + Lakatos move
#   excellence-reviewer→ Feynman test + Wittgenstein discipline
#   quality-planner    → Wheeler test + Fermi probe
#   prometheus         → Wheeler test + Socratic move
#   divergent-framer   → Socratic move + Lakatos move
#
# Drift (an agent loses its assigned instrument anchor) silently
# degrades the doctrine integration back to vocabulary-only generality.

printf '\nChecking deliberative-specialist agent references\n'

AGENTS_DIR="${REPO_ROOT}/bundle/dot-claude/agents"

# Canonical installed reference path used in agent inlines. The ~ is a
# literal grep pattern, not a path to expand — SC2088 is intentional.
# shellcheck disable=SC2088
INSTALLED_REF_PATH="~/.claude/quality-pack/memory/intellectual-craft.md"

check_agent_reference() {
  local agent_file="$1"
  local agent_path="${AGENTS_DIR}/${agent_file}"
  shift
  local -a instruments=("$@")

  if [[ ! -f "${agent_path}" ]]; then
    printf '  FAIL: agent file missing: %s\n' "${agent_path}" >&2
    fail=$((fail + 1))
    return
  fi

  # (a) The doctrine path is referenced in the agent body.
  if grep -q -F -- "${INSTALLED_REF_PATH}" "${agent_path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s does not reference doctrine path %s\n' \
      "${agent_file}" "${INSTALLED_REF_PATH}" >&2
    fail=$((fail + 1))
  fi

  # (b) Each assigned instrument is named in the agent body.
  for instrument in "${instruments[@]}"; do
    if grep -q -F -- "${instrument}" "${agent_path}"; then
      pass=$((pass + 1))
    else
      printf '  FAIL: %s does not anchor instrument %q\n' \
        "${agent_file}" "${instrument}" >&2
      fail=$((fail + 1))
    fi
  done
}

check_agent_reference "oracle.md"              "Feynman test"   "Popper test"
check_agent_reference "metis.md"               "Fermi probe"    "Bohr probe"
check_agent_reference "abstraction-critic.md"  "Socratic move"  "Lakatos move"
check_agent_reference "excellence-reviewer.md" "Feynman test"   "Wittgenstein discipline"
check_agent_reference "quality-planner.md"     "Wheeler test"   "Fermi probe"
check_agent_reference "prometheus.md"          "Wheeler test"   "Fermi probe"
check_agent_reference "divergent-framer.md"    "Socratic move"  "Lakatos move"

# ----- (5) Each agent carries the named calibration heading anchor -----
#
# F-Q3 (quality-reviewer): without the heading anchor check, a future
# edit could move the instrument names out of an `## Intellectual-Craft
# Calibration` section and the assignment grep above would still pass.
# Asserting the section heading explicitly closes that drift surface.

printf '\nChecking calibration-heading anchor in each agent\n'

for agent_file in oracle.md metis.md abstraction-critic.md excellence-reviewer.md \
                  quality-planner.md prometheus.md divergent-framer.md; do
  agent_path="${AGENTS_DIR}/${agent_file}"
  if [[ ! -f "${agent_path}" ]]; then
    printf '  FAIL: agent file missing: %s\n' "${agent_path}" >&2
    fail=$((fail + 1))
    continue
  fi
  if grep -q -F -- "## Intellectual-Craft Calibration" "${agent_path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s missing `## Intellectual-Craft Calibration` heading anchor\n' \
      "${agent_file}" >&2
    fail=$((fail + 1))
  fi
done

# ----- (6) Declined-instruments audit log section exists -----
#
# F-E2/F-E4 (excellence-reviewer): the "Considered and declined" log
# records what was weighed but not shipped (Hamming, executor-agent
# threading). Removing the log would silently drop the protective-belt
# evidence that future revisions need to consult before re-proposing.

printf '\nChecking declined-instruments audit log\n'

assert_file_contains "declined-log section present" \
  "### Considered and declined" "${DOCTRINE_PATH}"
assert_file_contains "declined-log names Hamming" \
  "Hamming" "${DOCTRINE_PATH}"

# ----- Summary -----

printf '\n=== intellectual-craft-doctrine tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
