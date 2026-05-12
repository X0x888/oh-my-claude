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
#   T3  — core.md Anti-Patterns has the no-defer cross-reference
#   T4  — skills.md (in-session memory) has the LOAD-BEARING note
#   T5  — council/SKILL.md Phase 5 step 6 marks the criterion as LOAD-BEARING
#   T6  — omc-config.sh emit_preset() has the load-bearing comment
#   T7  — emit_preset maximum/zero-steering emits no_defer_mode=on
#   T8  — emit_preset balanced emits no_defer_mode=on
#   T9  — emit_preset minimal legitimately emits no_defer_mode=off
#   T10 — no_defer_mode default in common.sh is "on"
#   T11 — oh-my-claude.conf.example documents the flag with default "on"
#
# Failure modes this catches:
#   - "Doc cleanup" silently deletes the contract section.
#   - "Preset tidy-up" flips no_defer_mode=on to off in maximum/balanced.
#   - "Default rebase" changes OMC_NO_DEFER_MODE default to off in
#     common.sh.
#   - Adding a new preset that ships no_defer_mode=off as recommended.
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

printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
