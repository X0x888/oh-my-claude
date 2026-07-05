#!/usr/bin/env bash
#
# test-research-pack.sh
#
# Umbrella regression net for the v1.49-pre research pack: the
# research-craft doctrine layer (scientific-rigor / citation-integrity /
# figure-craft), the research trio of agents (research-data-analyst /
# literature-scout / rigor-reviewer), the three research skills
# (data-analysis / lit-review / manuscript), the scientific-signal
# routing surface, and every lockstep list the pack touches.
#
# Mirrors tests/test-art-taste-doctrine.sh: the doctrine is load-bearing
# only while (1) the files carry their canonical anchors, (2) verify.sh
# pins them, (3) every consuming surface references the installed path
# AND inlines the baseline principles, and (4) CLAUDE.md names the
# directory + coordination rule. Drift in any site silently regresses
# research work to generic-vocabulary output with no rigor/citation/
# figure contract — the exact failure mode the pack was shipped to close.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RC_DIR="${REPO_ROOT}/bundle/dot-claude/quality-pack/research-craft"
AGENTS_DIR="${REPO_ROOT}/bundle/dot-claude/agents"
SKILLS_DIR="${REPO_ROOT}/bundle/dot-claude/skills"

RIGOR="${RC_DIR}/scientific-rigor.md"
CITE="${RC_DIR}/citation-integrity.md"
FIGURE="${RC_DIR}/figure-craft.md"

# Canonical installed-path references the consumers must carry. Literal
# grep patterns (the ~ is not expanded) — a rename of the on-disk files
# forces this test to be updated explicitly rather than leaving stale
# agent pointers. shellcheck disable=SC2088 on each use site is implied
# by -F matching below (no expansion happens).
# shellcheck disable=SC2088
REF_RIGOR='~/.claude/quality-pack/research-craft/scientific-rigor.md'
# shellcheck disable=SC2088
REF_CITE='~/.claude/quality-pack/research-craft/citation-integrity.md'
# shellcheck disable=SC2088
REF_FIGURE='~/.claude/quality-pack/research-craft/figure-craft.md'

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

# ----- (1) Doctrine files exist and carry their canonical anchors -----

printf 'Checking doctrine file integrity\n'

assert_file_exists "scientific-rigor.md exists" "${RIGOR}"
assert_file_exists "citation-integrity.md exists" "${CITE}"
assert_file_exists "figure-craft.md exists" "${FIGURE}"

# scientific-rigor.md — section anchors + load-bearing citations.
rigor_anchors=(
  "## §1. The provenance contract"
  "## §2. Uncertainty discipline"
  "## §3. Error-bar disclosure"
  "## §4. Fitting discipline"
  "## §5. Statistics honesty"
  "## §6. The assumptions log"
  "## §7. Non-obvious calls"
  "Run-manifest beside every result"
  "Cumming, Fidler & Vaux 2007"
  "Sandve et al. 2013"
  "The Turing Way"
  "absolute_sigma=True"
  "Selection bias is disclosed"
  "you must not fool yourself"
  "np.random.default_rng"
)
for anchor in "${rigor_anchors[@]}"; do
  assert_file_contains "rigor anchor: ${anchor}" "${anchor}" "${RIGOR}"
done

# citation-integrity.md — the iron rule, registries, failure catalog.
cite_anchors=(
  "## §1. The iron rule: verify-before-write"
  "## §2. The verification loop"
  "## §3. Keyless registry endpoints"
  "## §4. Existence is not faithfulness"
  "## §6. Failure-mode catalog"
  "resolve targets, never generation targets"
  "api.crossref.org"
  "api.openalex.org"
  "api.semanticscholar.org"
  "export.arxiv.org"
  "application/x-bibtex"
  "Citation laundering"
  "Stale numeric claim"
)
for anchor in "${cite_anchors[@]}"; do
  assert_file_contains "citation anchor: ${anchor}" "${anchor}" "${CITE}"
done

# figure-craft.md — journal numbers, palettes, submission gate.
figure_anchors=(
  "## §1. A figure is an argument"
  "## §2. Journal mechanical specs"
  "## §3. Color discipline"
  "## §7. Submission-readiness check"
  "89 mm"
  "86 mm (3 3/8 in)"
  "Okabe-Ito"
  "#E69F00"
  "viridis"
  "cividis"
  "Never rainbow/jet"
  "pdf.fonttype"
  "SciencePlots"
)
for anchor in "${figure_anchors[@]}"; do
  assert_file_contains "figure anchor: ${anchor}" "${anchor}" "${FIGURE}"
done

# ----- (2) verify.sh pins the doctrine, agents, and skills -----

printf 'Checking verify.sh wiring\n'

VERIFY_PATH="${REPO_ROOT}/verify.sh"
verify_pins=(
  "quality-pack/research-craft/scientific-rigor.md"
  "quality-pack/research-craft/citation-integrity.md"
  "quality-pack/research-craft/figure-craft.md"
  "agents/research-data-analyst.md"
  "agents/literature-scout.md"
  "agents/rigor-reviewer.md"
  "skills/data-analysis/SKILL.md"
  "skills/lit-review/SKILL.md"
  "skills/manuscript/SKILL.md"
)
for pin in "${verify_pins[@]}"; do
  assert_file_contains "verify.sh pins ${pin}" "${pin}" "${VERIFY_PATH}"
done

# ----- (3) Consumer wiring: installed path + inlined baseline -----
#
# Per-file consumer subsets (pinned here per the CLAUDE.md coordination
# rule): rigor -> analyst, rigor-reviewer, /data-analysis; citation ->
# scout, rigor-reviewer, draft-writer, editor-critic, /lit-review,
# /manuscript; figure -> analyst, rigor-reviewer, /data-analysis,
# /manuscript. Each agent consumer must also carry the literal
# "Research-Craft Calibration" header — the minimum guarantee that
# distinguishes "consciously calibrated" from "reverted to generic
# vocabulary".

printf 'Checking consumer wiring\n'

ANALYST="${AGENTS_DIR}/research-data-analyst.md"
SCOUT="${AGENTS_DIR}/literature-scout.md"
RREV="${AGENTS_DIR}/rigor-reviewer.md"
DWRITER="${AGENTS_DIR}/draft-writer.md"
ECRITIC="${AGENTS_DIR}/editor-critic.md"
SK_DATA="${SKILLS_DIR}/data-analysis/SKILL.md"
SK_LIT="${SKILLS_DIR}/lit-review/SKILL.md"
SK_MS="${SKILLS_DIR}/manuscript/SKILL.md"

# research-data-analyst: rigor + figure, calibration header, baseline anchors
assert_file_contains "analyst references rigor path" "${REF_RIGOR}" "${ANALYST}"
assert_file_contains "analyst references figure path" "${REF_FIGURE}" "${ANALYST}"
assert_file_contains "analyst has calibration header" "Research-Craft Calibration" "${ANALYST}"
for anchor in "Run-manifest" "absolute_sigma" "Okabe-Ito" "Selection-bias disclosure" "Assumptions log"; do
  assert_file_contains "analyst inlines ${anchor}" "${anchor}" "${ANALYST}"
done

# literature-scout: citation path, calibration header, iron rule
assert_file_contains "scout references citation path" "${REF_CITE}" "${SCOUT}"
assert_file_contains "scout has calibration header" "Research-Craft Calibration" "${SCOUT}"
for anchor in "verify-before-write" "resolve targets, never generation targets" "Existence is not faithfulness"; do
  assert_file_contains "scout inlines ${anchor}" "${anchor}" "${SCOUT}"
done

# rigor-reviewer: all three paths, calibration header, audit anchors,
# FINDINGS_JSON contract (9th emitter), reviewer verdict vocabulary
assert_file_contains "rigor-reviewer references rigor path" "${REF_RIGOR}" "${RREV}"
assert_file_contains "rigor-reviewer references citation path" "${REF_CITE}" "${RREV}"
assert_file_contains "rigor-reviewer references figure path" "${REF_FIGURE}" "${RREV}"
assert_file_contains "rigor-reviewer has calibration header" "Research-Craft Calibration" "${RREV}"
for anchor in "absolute_sigma" "FINDINGS_JSON" "VERDICT: CLEAN" "Stale numeric claims"; do
  assert_file_contains "rigor-reviewer carries ${anchor}" "${anchor}" "${RREV}"
done

# writing chain: citation-integrity consumers
assert_file_contains "draft-writer references citation path" "${REF_CITE}" "${DWRITER}"
assert_file_contains "draft-writer carries verify-before-write" "verify-before-write" "${DWRITER}"
assert_file_contains "editor-critic references citation path" "${REF_CITE}" "${ECRITIC}"
assert_file_contains "editor-critic carries fabrication catalog" "fabrication catalog" "${ECRITIC}"

# skills
assert_file_contains "/data-analysis references rigor path" "${REF_RIGOR}" "${SK_DATA}"
assert_file_contains "/data-analysis references figure path" "${REF_FIGURE}" "${SK_DATA}"
assert_file_contains "/data-analysis has calibration header" "Research-Craft Calibration" "${SK_DATA}"
assert_file_contains "/lit-review references citation path" "${REF_CITE}" "${SK_LIT}"
assert_file_contains "/lit-review forks literature-scout" "agent: literature-scout" "${SK_LIT}"
assert_file_contains "/manuscript references citation path" "${REF_CITE}" "${SK_MS}"
assert_file_contains "/manuscript references figure path" "${REF_FIGURE}" "${SK_MS}"
assert_file_contains "/manuscript carries verify-before-write" "verify-before-write" "${SK_MS}"
assert_file_contains "/manuscript sequences scout before draft" "BEFORE drafting begins" "${SK_MS}"

# ----- (4) CLAUDE.md wiring -----

printf 'Checking CLAUDE.md wiring\n'

CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"
assert_file_contains "CLAUDE.md names research-craft dir" \
  "bundle/dot-claude/quality-pack/research-craft/" "${CLAUDE_MD}"
assert_file_contains "CLAUDE.md has research-craft coordination rule" \
  "Adding or removing a research-craft reference" "${CLAUDE_MD}"

# ----- (5) Routing surface: classifier + router -----

printf 'Checking routing wiring\n'

CLASSIFIER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

assert_file_contains "classifier defines _scientific_signal_score" \
  "_scientific_signal_score()" "${CLASSIFIER}"
assert_file_contains "classifier defines prompt_has_scientific_signal" \
  "prompt_has_scientific_signal()" "${CLASSIFIER}"
assert_file_contains "infer_domain feeds scientific score into research" \
  "scientific_research_bigrams" "${CLASSIFIER}"
assert_file_contains "router gates on prompt_has_scientific_signal" \
  'prompt_has_scientific_signal "${PROMPT_TEXT}"' "${ROUTER}"
assert_file_contains "router emits domain_routing_scientific" \
  "domain_routing_scientific" "${ROUTER}"
assert_file_contains "router directive names the research trio" \
  "research-data-analyst" "${ROUTER}"

# ----- (6) Advisory capture parity (rigor-reviewer on BOTH lists) -----

printf 'Checking capture-list parity\n'

COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
PENDING="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh"

capture_has=0
pending_has=0
grep -q '"rigor-reviewer"' "${COMMON}" && capture_has=1
grep -qE '_is_advisory_specialist|rigor-reviewer' "${PENDING}" \
  && grep -q 'rigor-reviewer' "${PENDING}" && pending_has=1

if [[ "${capture_has}" -eq 1 && "${pending_has}" -eq 1 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: rigor-reviewer capture parity — common.sh=%s record-pending-agent.sh=%s (must be on BOTH lists)\n' \
    "${capture_has}" "${pending_has}" >&2
  fail=$((fail + 1))
fi

# literature-scout must NOT be on the capture lists (prometheus
# precedent: report-shaped output, not findings — counting it would
# over-trigger the advisory-no-findings gate).
if grep -q '"literature-scout"' "${COMMON}"; then
  printf '  FAIL: literature-scout must NOT be in discovered_scope_capture_targets (report-shaped output)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----- (7) Uninstall + index surfaces -----

printf 'Checking uninstall and index surfaces\n'

UNINSTALL="${REPO_ROOT}/uninstall.sh"
for entry in "agents/research-data-analyst.md" "agents/literature-scout.md" "agents/rigor-reviewer.md" \
  "skills/data-analysis" "skills/lit-review" "skills/manuscript"; do
  assert_file_contains "uninstall.sh removes ${entry}" "${entry}" "${UNINSTALL}"
done

SKILLS_INDEX="${SKILLS_DIR}/skills/SKILL.md"
MEMORY_SKILLS="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/skills.md"
README_MD="${REPO_ROOT}/README.md"
for surface in "${SKILLS_INDEX}" "${MEMORY_SKILLS}" "${README_MD}"; do
  for cmd in "/data-analysis" "/lit-review" "/manuscript"; do
    assert_file_contains "$(basename "${surface}") lists ${cmd}" "${cmd}" "${surface}"
  done
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
