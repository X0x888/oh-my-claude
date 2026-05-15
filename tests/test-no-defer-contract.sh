#!/usr/bin/env bash
# test-no-defer-contract.sh — regression net for the v1.40.0 no-defer
# contract's load-bearing markers across the bundle.
#
# The contract itself is enforced by behavior tests (test-no-defer-mode.sh
# at 37/0). This test net protects the *documentation surface* that
# teaches future model sessions NOT to soften the contract. The
# anti-optimization clause in core.md is prose-only — a future "doc
# cleanup" or "modernization" wave could silently delete it and CI would
# stay green. This test asserts every load-bearing marker is present.
#
# Coverage:
#   T1  — core.md contains the contract section header
#   T2  — core.md lists the FORBIDDEN softening proposals concretely
#   T2b — core.md FORBIDDEN list cross-references the v1.40.x dual-
#         failure-mode framing (depth-prime + no-defer) so a future
#         "consolidate redundant priming" wave cannot remove the depth
#         half while leaving the contract intact
#   T3  — core.md Anti-Patterns has the no-defer cross-reference
#   T4  — skills.md (in-session memory) has the LOAD-BEARING note
#   T5  — council/SKILL.md Phase 5 step 6 marks the criterion as LOAD-BEARING
#   T6  — omc-config.sh emit_preset() has the load-bearing comment
#   T7  — emit_preset maximum/zero-steering emits no_defer_mode=on
#   T8  — emit_preset balanced emits no_defer_mode=on
#   T9  — emit_preset minimal legitimately emits no_defer_mode=off
#   T10 — no_defer_mode default in common.sh is "on"
#   T11 — oh-my-claude.conf.example documents the flag with default "on"
#   T12 — README.md "When stuck" table does NOT map taste/policy/brand-
#         voice to /ulw-pause (v1.39 phrasing that contradicts v1.40)
#   T13 — README.md /ulw-pause table row names operational-block scope
#   T14 — docs/prompts.md autonomy section does NOT list "Product-taste
#         or policy judgment" as a pause case (REMOVED in v1.40.0)
#   T15 — docs/prompts.md autonomy section does NOT list "Credible-
#         approach split" as a pause case (REMOVED in v1.40.0)
#   T16 — docs/prompts.md autonomy section DOES list "Hard external
#         blocker" (one of the five v1.40 cases)
#   T17 — docs/prompts.md autonomy section DOES list "Scope explosion
#         without pre-authorization" (one of the five v1.40 cases)
#   T18 — docs/faq.md item 12 does NOT map taste/policy/brand-voice/
#         credible-approach to /ulw-pause (v1.39 phrasing)
#   T19 — README.md /mark-deferred skill-table row names the v1.40.0
#         ULW refusal under no_defer_mode=on (caught by quality-reviewer
#         pre-tag on v1.40.0 release; shipped in v1.40.1 hotfix). Without
#         this assertion the canonical skill table at README:319 could
#         silently drift back to v1.39 framing even though the "When
#         stuck" mini-table (T12/T13) stays correct.
#
# T12-T19 close the docs_stale class that v1.40.0's Wave 6/7 sweeps
# missed on the user-facing surfaces — the in-session memory was swept
# but README/docs/prompts/docs/faq were not. Without these assertions
# CI cannot catch a future doc surface drifting back to the v1.39
# pause-case framing.
#
# Failure modes this catches:
#   - "Doc cleanup" silently deletes the contract section.
#   - "Preset tidy-up" flips no_defer_mode=on to off in maximum/balanced.
#   - "Default rebase" changes OMC_NO_DEFER_MODE default to off in
#     common.sh.
#   - Adding a new preset that ships no_defer_mode=off as recommended.
#   - A README/docs edit reintroduces the v1.39 "user-decision pause for
#     taste/policy/brand-voice" framing that v1.40 explicitly removed.
#
# Updating this test:
#   This test exists to PREVENT softening. If you legitimately need to
#   change the contract (rare — requires explicit user signal per
#   core.md's contract section), update this test in the same commit
#   AND name the user-authorized change in the commit body. A test
#   change without that signal is the softening anti-pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

assert_contains_file() {
  local label="$1" needle="$2" file="$3"
  if grep -Fq -- "${needle}" "${file}" 2>/dev/null; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file: %s\n    expected to contain: %s\n' \
      "${label}" "${file}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# Used by T12, T14, T15, T18 — assert a v1.39-era phrasing is NOT
# present in a user-facing doc. Fail loudly when the deprecated phrasing
# reappears so a future doc edit cannot silently regress the contract.
assert_not_contains_file() {
  local label="$1" needle="$2" file="$3"
  if grep -Fq -- "${needle}" "${file}" 2>/dev/null; then
    printf '  FAIL: %s\n    file: %s\n    expected NOT to contain: %s\n' \
      "${label}" "${file}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_preset_emits() {
  local label="$1" profile="$2" expected_line="$3"
  local script="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"
  local output
  output="$(bash -c "
    set -euo pipefail
    source '${script}'
    emit_preset '${profile}'
  " 2>/dev/null || true)"
  if printf '%s\n' "${output}" | grep -Fxq -- "${expected_line}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    preset: %s\n    expected line: %s\n    got: (%s)\n' \
      "${label}" "${profile}" "${expected_line}" "${output:0:200}…" >&2
    fail=$((fail + 1))
  fi
}

printf '== test-no-defer-contract ==\n'

CORE_MD="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/core.md"
SKILLS_MD="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/skills.md"
COUNCIL_SKILL="${REPO_ROOT}/bundle/dot-claude/skills/council/SKILL.md"
OMC_CONFIG="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
CONF_EXAMPLE="${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example"

# T1 — core.md contains the contract section header.
assert_contains_file \
  "T1 — core.md contract section header present" \
  "do NOT optimize this away" \
  "${CORE_MD}"

# T2 — core.md lists FORBIDDEN softening proposals concretely. The
# specific quoted phrasings are what makes the rule unconsolidatable —
# generic "don't soften" boilerplate would not survive a doc-cleanup
# wave, but concrete quotes that name actual reviewer proposals do.
assert_contains_file \
  "T2 — core.md FORBIDDEN list quotes a concrete softening proposal" \
  "Soft-warn instead of hard-block" \
  "${CORE_MD}"

# T2b — core.md FORBIDDEN list cross-references the v1.40.x dual-
# failure-mode framing (depth-prime rebalance). Without this entry, a
# future "consolidate redundant priming" wave could remove the
# Why-/ulw-exists preamble and the Thinking Quality strengthening
# while leaving the no-defer contract intact — recreating the v1.40.0
# action-bias-overcorrection failure mode the user named 2026-05-15
# (shallow thinking on every prompt). The cross-link names this as
# the SAME anti-pattern class as softening the contract itself.
assert_contains_file \
  "T2b — core.md FORBIDDEN list cross-references dual-failure-mode framing" \
  "Collapsing the dual-failure-mode framing" \
  "${CORE_MD}"

# T3 — Anti-Patterns has the no-defer cross-reference. The cross-ref
# is the second entry point a future model session may read.
assert_contains_file \
  "T3 — Anti-Patterns cross-reference present" \
  "Softening the v1.40.0 no-defer contract" \
  "${CORE_MD}"

# T4 — skills.md (in-session memory) carries the LOAD-BEARING note.
# This file loads on every session via CLAUDE.md @-import, so the rule
# fires before the model takes its first action.
assert_contains_file \
  "T4 — skills.md LOAD-BEARING note present" \
  "LOAD-BEARING — do NOT soften this contract" \
  "${SKILLS_MD}"

# T5 — council/SKILL.md Phase 5 step 6 marks the criterion as LOAD-BEARING.
# Phase 5 is where the council marks user-decision findings; weakening
# this step would re-introduce the v1.39 pause-on-taste behavior.
assert_contains_file \
  "T5 — council/SKILL.md step 6 marks LOAD-BEARING" \
  "LOAD-BEARING, do NOT soften" \
  "${COUNCIL_SKILL}"

# T6 — omc-config.sh emit_preset() has the load-bearing comment.
# Without this comment, a preset-tidy-up could silently flip
# no_defer_mode=on to off in the recommended profiles.
assert_contains_file \
  "T6 — omc-config.sh emit_preset() load-bearing comment present" \
  "v1.40.0 LOAD-BEARING (do NOT optimize away)" \
  "${OMC_CONFIG}"

# T7-T9 — preset behavior. The recommended presets MUST ship the
# contract on; minimal legitimately ships off (power-user opt-out).
assert_preset_emits \
  "T7 — maximum preset emits no_defer_mode=on" \
  "maximum" \
  "no_defer_mode=on"
assert_preset_emits \
  "T7b — zero-steering preset emits no_defer_mode=on" \
  "zero-steering" \
  "no_defer_mode=on"
assert_preset_emits \
  "T8 — balanced preset emits no_defer_mode=on" \
  "balanced" \
  "no_defer_mode=on"
assert_preset_emits \
  "T9 — minimal preset emits no_defer_mode=off (legit power-user opt-out)" \
  "minimal" \
  "no_defer_mode=off"

# T10 — common.sh default is "on". If someone "rebases the defaults"
# this catches the silent flip even when the user has no conf.
assert_contains_file \
  "T10 — common.sh OMC_NO_DEFER_MODE default is on" \
  'OMC_NO_DEFER_MODE="${OMC_NO_DEFER_MODE:-on}"' \
  "${COMMON_SH}"

# T11 — conf.example documents the flag with default "on".
assert_contains_file \
  "T11 — conf.example documents no_defer_mode=on default" \
  "#no_defer_mode=on" \
  "${CONF_EXAMPLE}"

# T12-T18 — user-facing doc surfaces. Wave 6 swept code, Wave 7 swept
# the in-session memory + skills/SKILL.md, but README and docs/ were
# missed. These assertions close that gap so a future doc surface
# cannot silently drift back to the v1.39 framing.

README_MD="${REPO_ROOT}/README.md"
PROMPTS_MD="${REPO_ROOT}/docs/prompts.md"
FAQ_MD="${REPO_ROOT}/docs/faq.md"

# T12 — README's "When stuck" decision table must NOT map taste / policy
# / brand voice to /ulw-pause. That's the v1.39 phrasing the v1.40
# contract explicitly forbids — a user following it hits a runtime
# refusal from omc_reason_names_operational_block.
assert_not_contains_file \
  "T12 — README 'When stuck' table does NOT map taste/policy/brand-voice to /ulw-pause" \
  "(taste, policy, brand voice) | \`/ulw-pause" \
  "${README_MD}"

# T13 — README's /ulw-pause row must name the operational-block scope
# explicitly. The replacement phrasing mirrors skills/SKILL.md line 71.
assert_contains_file \
  "T13 — README /ulw-pause row names operational-block scope" \
  "operational-block pause" \
  "${README_MD}"

# T14 — docs/prompts.md autonomy section must NOT list "Product-taste
# or policy judgment" as a pause case. core.md:23 names this as one of
# the two pause cases REMOVED in v1.40.0.
assert_not_contains_file \
  "T14 — docs/prompts.md does NOT list Product-taste/policy as a pause case" \
  "Product-taste or policy judgment" \
  "${PROMPTS_MD}"

# T15 — docs/prompts.md autonomy section must NOT list "Credible-
# approach split" as a pause case. core.md:23 names this as the second
# pause case REMOVED in v1.40.0.
assert_not_contains_file \
  "T15 — docs/prompts.md does NOT list Credible-approach split as a pause case" \
  "Credible-approach split.** Two credible approaches" \
  "${PROMPTS_MD}"

# T16 — docs/prompts.md autonomy section DOES list "Hard external
# blocker" (one of the five operational cases enumerated in core.md).
assert_contains_file \
  "T16 — docs/prompts.md lists 'Hard external blocker' as a pause case" \
  "Hard external blocker" \
  "${PROMPTS_MD}"

# T17 — docs/prompts.md autonomy section DOES list "Scope explosion
# without pre-authorization" (the fifth operational case).
assert_contains_file \
  "T17 — docs/prompts.md lists 'Scope explosion without pre-authorization'" \
  "Scope explosion without pre-authorization" \
  "${PROMPTS_MD}"

# T18 — docs/faq.md item 12 must NOT map taste / policy / brand voice
# / credible-approach split to /ulw-pause. Same defect class as T12.
assert_not_contains_file \
  "T18 — docs/faq.md item 12 does NOT use v1.39 user-decision-pause framing" \
  "taste, policy, brand voice, credible-approach split" \
  "${FAQ_MD}"

# T19 — README's canonical skill table at line 319 must name the v1.40.0
# ULW refusal for /mark-deferred. The "When stuck" mini-table earlier in
# the README (T12/T13 scope) was swept in Wave 10, but the canonical skill
# table was missed. v1.40.1 hotfix added the caveat — without this
# assertion a future doc edit could silently drift back to the v1.39
# framing on this row even while the earlier table stays correct.
assert_contains_file \
  "T19 — README /mark-deferred skill row names v1.40.0 ULW refusal" \
  "Refused under ULW execution with default" \
  "${README_MD}"

printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
