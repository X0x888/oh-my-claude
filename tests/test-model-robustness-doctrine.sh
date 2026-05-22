#!/usr/bin/env bash
#
# tests/test-model-robustness-doctrine.sh — semantic-invariant regression
# net for the model-robustness doctrine at
# bundle/dot-claude/quality-pack/memory/model-robustness.md.
#
# Catches the specific drift surfaces the council pass flagged before
# the doctrine shipped:
#
#   T1 — file exists at the canonical path.
#   T2 — premise sentence ("reasoning-shaped tokens") is present (the
#        load-bearing insight per the abstraction-critic verdict).
#   T3 — doctrine does NOT reintroduce the "two-strike circuit breaker"
#        habit (metis Finding 1: numeric conflict with core.md's
#        three-strike Failure Recovery rule).
#   T4 — doctrine does NOT name "sycophancy" as a failure mode
#        (abstraction-critic Finding 2: adversarial-framing paradigm
#        concern from project_v1_43_audit_paradigm_concerns.md).
#   T5 — doctrine does NOT introduce a "premise check" habit (metis
#        Finding 2: conflict with the declare-and-proceed contract in
#        core.md).
#   T6 — bidirectional inoculation: core.md FORBIDDEN list names
#        model-robustness.md as part of the consolidation anti-pattern
#        class (so the doctrine and core.md defend each other against
#        future "consolidate redundant priming" waves).
#   T7 — doctrine names the dual failure-mode families (stopping-short
#        + shallow-thinking) and the FORBIDDEN consolidation guard.
#   T8 — doctrine names the three genuine gaps (pattern-match,
#        miscalibration, fabrication) honestly rather than papering
#        over them with habit-shaped band-aids.
#
# This is a SEMANTIC test: it asserts what content must (and must not)
# be present. Wiring tests (@-include presence, verify.sh required_paths)
# live in tests/test-coordination-rules.sh Contract 6.
#
# Pinned in .github/workflows/validate.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCTRINE="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/model-robustness.md"
CORE_MD="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/core.md"

pass=0
fail=0

assert_pass() { pass=$((pass + 1)); }
assert_fail() {
  local label="$1" detail="$2"
  printf '  FAIL: %s\n    %s\n' "${label}" "${detail}" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# T1 — Doctrine file exists at canonical path.
# ----------------------------------------------------------------------
printf '\nT1: doctrine file exists\n'
if [[ -f "${DOCTRINE}" ]]; then
  assert_pass "T1: ${DOCTRINE} exists"
else
  assert_fail "T1: doctrine file missing" \
    "expected ${DOCTRINE} to exist; if you renamed/moved it, update bundle/dot-claude/CLAUDE.md @-include and verify.sh required_paths"
fi

# ----------------------------------------------------------------------
# T2 — Premise is present.
#
# The load-bearing insight ("reasoning-shaped tokens without doing
# reasoning") is what makes the doctrine net-new vs core.md. If it goes
# missing, the file has either drifted toward duplicating core.md or
# been replaced with something that lost the original purpose.
# ----------------------------------------------------------------------
printf '\nT2: load-bearing premise present\n'
# Broad alternation so benign rewordings ("reasoning-token theater,"
# "reasoning-without-reasoning") still match. The load-bearing concept
# is "model emits reasoning-shaped output without doing reasoning" —
# any phrasing that names that concept should pass.
if grep -Eq 'reasoning[- ]shaped|reasoning[- ]token|reasoning[- ]without[- ]' "${DOCTRINE}"; then
  assert_pass "T2: premise concept present (reasoning-shaped/reasoning-token/reasoning-without)"
else
  assert_fail "T2: premise concept absent" \
    "expected the doctrine to name the 'model emits reasoning-shaped output without reasoning' concept (any of: 'reasoning-shaped', 'reasoning-token', 'reasoning-without-') — the distinctive premise per the council pass"
fi

# ----------------------------------------------------------------------
# T3 — No "two-strike circuit breaker" habit.
#
# metis Finding 1: the original draft proposed a two-strike pause,
# which numerically conflicts with core.md Failure Recovery (3 times).
# Two competing thresholds in always-loaded files = silent failure.
# ----------------------------------------------------------------------
printf '\nT3: no two-strike circuit breaker (numeric conflict guard)\n'
if grep -Eq 'two[- ]strike|2[- ]strike' "${DOCTRINE}"; then
  assert_fail "T3: doctrine reintroduces two-strike threshold" \
    "core.md Failure Recovery specifies 3 strikes; introducing a competing two-strike rule here creates a silent numeric conflict between always-loaded files"
else
  assert_pass "T3: no competing strike-threshold rule"
fi

# ----------------------------------------------------------------------
# T4 — No "sycophancy" failure mode.
#
# abstraction-critic Finding 2: naming sycophancy is the agent-as-
# adversary frame that project_v1_43_audit_paradigm_concerns.md
# Finding 5 explicitly named as the regress-producing paradigm.
# The premise check habit is also a downstream artifact of this frame
# and is guarded separately in T5.
# ----------------------------------------------------------------------
printf '\nT4: no sycophancy failure mode (adversarial-framing guard)\n'
if grep -Eiq '\bsycophan' "${DOCTRINE}"; then
  assert_fail "T4: doctrine names sycophancy as a failure mode" \
    "this is the adversarial-framing paradigm concern documented in project_v1_43_audit_paradigm_concerns.md — premise-test the user's framing via mechanisms (verification, sub-dispatch), not via sycophancy-named habits"
else
  assert_pass "T4: no adversarial sycophancy framing"
fi

# ----------------------------------------------------------------------
# T5 — No "premise check" habit (declare-and-proceed conflict).
#
# metis Finding 2: a "premise check" pause case re-introduces the
# ask-and-hold pattern v1.40.0 explicitly removed (core.md Workflow
# Veteran default for ambiguous prompts: declare-and-proceed).
# ----------------------------------------------------------------------
printf '\nT5: no premise-check pause habit (declare-and-proceed guard)\n'
if grep -Eiq 'premise check\b' "${DOCTRINE}"; then
  assert_fail "T5: doctrine introduces a 'premise check' habit" \
    "core.md Workflow forbids ask-and-hold on ambiguous prompts; a 'check then ask' habit reintroduces the v1.39 credible-approach pause case v1.40.0 removed"
else
  assert_pass "T5: no premise-check pause habit"
fi

# ----------------------------------------------------------------------
# T6 — Bidirectional inoculation in core.md.
#
# The doctrine self-inoculates via its own "FORBIDDEN — not optional or
# consolidate-able" section; core.md must inoculate in the other
# direction so a future "consolidate the memory dir" wave can't argue
# the doctrine is redundant without violating core.md's own FORBIDDEN
# anti-pattern class.
# ----------------------------------------------------------------------
printf '\nT6: bidirectional inoculation in core.md\n'
if grep -Eq 'model-robustness\.md' "${CORE_MD}"; then
  assert_pass "T6: core.md FORBIDDEN list references model-robustness.md"
else
  assert_fail "T6: core.md does not reference model-robustness.md" \
    "core.md 'FORBIDDEN — softening the contract' must include a bullet naming model-robustness.md as part of the same anti-pattern class as the dual-failure-mode-collapse, so the inoculation is bidirectional"
fi

# ----------------------------------------------------------------------
# T7 — Dual failure-mode families + consolidation guard present.
#
# The doctrine names the two equally-weighted failure families
# (stopping-short via no-defer; shallow-thinking via depth + mechanisms)
# AND a FORBIDDEN guard against consolidating them. Both must be
# present — losing either invites the regress.
# ----------------------------------------------------------------------
printf '\nT7: dual failure-mode framing + consolidation guard\n'
if grep -Eq 'stopping-short' "${DOCTRINE}" \
  && grep -Eq 'shallow-thinking' "${DOCTRINE}" \
  && grep -Eq 'FORBIDDEN.*consolidat' "${DOCTRINE}"; then
  assert_pass "T7: doctrine names both failure families and FORBIDDEN consolidation"
else
  assert_fail "T7: dual-failure-mode framing incomplete" \
    "doctrine must name 'stopping-short' AND 'shallow-thinking' families AND a FORBIDDEN guard against consolidation — the dual framing is load-bearing per core.md 'Anti-Patterns'"
fi

# ----------------------------------------------------------------------
# T8 — Honest gap admission for the three modes without mechanisms.
#
# Pattern-match, miscalibration, and fabrication have no structural
# mechanism in the current harness. Honest admission > habit-shaped
# band-aids. The doctrine must name these three explicitly so future
# paradigm-level work has named targets, and so the model knows where
# its judgment is the only line of defense.
# ----------------------------------------------------------------------
printf '\nT8: honest gap admission for three failure modes\n'
if grep -Eiq 'pattern-match' "${DOCTRINE}" \
  && grep -Eiq 'miscalibrat' "${DOCTRINE}" \
  && grep -Eiq 'fabricat' "${DOCTRINE}"; then
  assert_pass "T8: doctrine names pattern-match, miscalibration, and fabrication as gaps"
else
  assert_fail "T8: gap admission incomplete" \
    "doctrine must name pattern-match-without-understanding, confidence miscalibration, and fabrication-from-training as the three failure modes without structural mechanisms"
fi

# ----------------------------------------------------------------------
printf '\n=== model-robustness-doctrine tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
