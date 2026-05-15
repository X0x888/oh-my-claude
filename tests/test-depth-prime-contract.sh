#!/usr/bin/env bash
# test-depth-prime-contract.sh — regression net for the v1.40.x+
# depth-on-every-prompt rebalance.
#
# The user named a /ulw failure mode (2026-05-15): "doesn't think
# deep enough on every prompt and doesn't try its best." The fix was
# structural — restore depth-of-thinking as an equal-weight contract
# alongside the v1.40.0 no-defer contract, without softening either.
# Three surfaces carry the rebalance (commit 35f4fa4):
#
#   - core.md preamble "Why /ulw exists" (sets the dual-failure-mode
#     frame before any rule fires)
#   - core.md strengthened Thinking Quality bullets (load-bearing rule,
#     full cognitive depth, verification over abstraction)
#   - Workflow lead-in bullet "Deliberation comes first, action comes
#     second" (disambiguates default-to-action from act-before-thinking)
#   - Router execution + continuation opener depth-primes (per-turn
#     counterweight to per-turn action-bias directives)
#
# All four are prose-only. A future "doc cleanup" or "consolidate
# redundant priming" wave could silently delete them and CI would stay
# green. This test asserts every load-bearing marker is present.
#
# Coverage:
#   T1  — core.md "Why /ulw exists" preamble header present
#   T2  — core.md preamble names BOTH failure modes (stop-short AND
#         shallow-think) as equal-weight contracts
#   T3  — core.md preamble disambiguates remaining-work vs thinking-time
#         deferral
#   T4  — core.md "Think before acting" elevated to load-bearing rule
#   T5  — core.md "Engage at full cognitive depth on every prompt"
#         bullet present (the try-its-best contract)
#   T6  — core.md "Favor verification over abstraction" bullet present
#         (previously ULTRATHINK-gated, now default)
#   T7  — core.md Workflow "Deliberation comes first, action comes
#         second" lead-in bullet present
#   T8  — router ulw_execution_opener carries "Engage at full cognitive
#         depth on this prompt" prime
#   T9  — router ulw_execution_opener carries "Default to action follows
#         deliberation, never replaces it" clause
#   T10 — router ulw_continuation_opener carries the autopilot counter
#         ("resist autopilot, re-read the actual state rather than what
#         you remember of it")
#   T11 — CHANGELOG.md [Unreleased] section mentions the rebalance
#   T12 — depth prime is the LEAD of the execution opener (positional
#         check, not just presence — catches a "consolidate" wave that
#         quotes the string as a historical example elsewhere while
#         removing it from the lead position)
#   T13 — Workflow "Deliberation comes first" bullet appears BEFORE
#         the "default to action" rule in core.md (positional — proves
#         the deliberation framing leads action-bias, not follows it)
#   T14 — no-defer contract FORBIDDEN list cross-references the
#         dual-failure-mode framing (depth + no-defer) so a future
#         session reading only the contract section sees the dual
#         framing as load-bearing
#
# Failure modes this catches:
#   - "Consolidate redundant priming" silently drops the new bullets.
#   - "Trim the opener" deletes the depth-prime sentence in either
#     execution or continuation opener.
#   - "Doc cleanup" deletes the Why /ulw exists preamble.
#   - "Modernize core.md" replaces the dual-failure-mode framing with
#     the v1.40.0-era no-defer-only framing.
#   - The router opener body is rewritten such that the prime is no
#     longer the first user-facing instruction.
#
# Updating this test:
#   This test exists to PREVENT softening of the depth-prime — same
#   anti-pattern class as softening the no-defer contract. If you
#   legitimately need to change the depth-prime surfaces (rare —
#   requires explicit user signal that the rebalance was wrong), update
#   this test in the same commit AND name the user-authorized change
#   in the commit body. A test change without that signal is the
#   softening anti-pattern.

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

printf '== test-depth-prime-contract ==\n'

CORE_MD="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/core.md"
ROUTER_SH="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
CHANGELOG_MD="${REPO_ROOT}/CHANGELOG.md"

# T1 — core.md "Why /ulw exists" preamble header is present.
assert_contains_file \
  "T1 — core.md preamble header present" \
  "## Why \`/ulw\` exists" \
  "${CORE_MD}"

# T2 — preamble names BOTH failure modes. The dual-failure-mode framing
# is what makes the rule unconsolidatable — a maintainer who reads core.md
# expecting only no-defer would otherwise silently trim depth-priming.
assert_contains_file \
  "T2 — preamble names stopping-short AND shallow-thinking as equal-weight" \
  "Two failure modes are equally weighted" \
  "${CORE_MD}"

# T3 — preamble disambiguates REMAINING WORK vs THINKING TIME deferral.
# This is the load-bearing distinction; collapsing it back to "deferral
# is forbidden" is the v1.40.0-era framing the rebalance was designed
# to correct.
assert_contains_file \
  "T3 — preamble disambiguates remaining-work vs thinking-time deferral" \
  "governs deferral of REMAINING WORK" \
  "${CORE_MD}"

# T4 — "Think before acting" elevated from soft suggestion to load-bearing.
# The strengthened wording overrides any "default to action" framing.
assert_contains_file \
  "T4 — Think before acting strengthened to load-bearing rule" \
  "load-bearing rule, not a soft suggestion" \
  "${CORE_MD}"

# T5 — "Engage at full cognitive depth on every prompt" — the *try-its-
# best* contract, user's exact words.
assert_contains_file \
  "T5 — Engage-at-full-cognitive-depth bullet present" \
  "Engage at full cognitive depth on every prompt" \
  "${CORE_MD}"

# T6 — "Favor verification over abstraction" — previously gated behind
# user-typed `ultrathink` magic word, now the default for non-trivial
# work because the user complaint named that the keyword was hidden.
assert_contains_file \
  "T6 — Favor-verification-over-abstraction bullet present" \
  "Favor verification over abstraction" \
  "${CORE_MD}"

# T7 — Workflow "Deliberation comes first" lead-in bullet. This is the
# bullet that disambiguates "default to action" from "act before
# thinking" — without it, a reader could interpret the very next bullet
# ("default to action") as a license to skip deliberation.
assert_contains_file \
  "T7 — Workflow Deliberation-first lead-in bullet present" \
  "Deliberation comes first, action comes second" \
  "${CORE_MD}"

# T8 — Router execution opener carries the depth prime as the first
# user-facing instruction after the mode declaration. The opener is the
# per-turn counterweight to per-turn action-bias directives.
assert_contains_file \
  "T8 — execution opener carries cognitive-depth prime" \
  "Engage at full cognitive depth on this prompt" \
  "${ROUTER_SH}"

# T9 — execution opener carries the "default to action follows
# deliberation" disambiguation. This sentence is what makes the no-defer
# contract compatible with the depth-prime — without it, a future model
# session might read "default to action" as "act before thinking."
assert_contains_file \
  "T9 — execution opener carries default-to-action disambiguation" \
  "follows deliberation, never replaces it" \
  "${ROUTER_SH}"

# T10 — Continuation opener carries the autopilot counter. Long sessions
# accumulate drift; the continuation prime says re-read actual state
# rather than what you remember of it. Without this, continuation
# prompts run on cached mental model.
assert_contains_file \
  "T10 — continuation opener carries autopilot-counter prime" \
  "resist autopilot, re-read the actual state" \
  "${ROUTER_SH}"

# T11 — CHANGELOG.md [Unreleased] mentions the rebalance. The entry
# documents the four ULW coordination-rule disclosures (failure mode /
# effect / cost / verification) and is the project's release record.
assert_contains_file \
  "T11 — CHANGELOG.md [Unreleased] mentions Depth-on-every-prompt rebalance" \
  "Depth-on-every-prompt rebalance" \
  "${CHANGELOG_MD}"

# T12 — depth prime is the LEAD of the execution opener (positional
# assertion, not just presence). Without this, a future "consolidate
# redundant priming" wave could preserve the depth-prime sentence as
# a quoted historical example elsewhere in the body while removing it
# from the actual lead position — the literal-string test (T8) would
# still pass. This test extracts the opener line and asserts the
# depth-prime appears BEFORE "Lead your first response" in byte
# position, proving the prime is the lead instruction the model reads
# first, not a footnote.
opener_line="$(grep -n 'add_directive "ulw_execution_opener"' "${ROUTER_SH}" | head -1 | cut -d: -f2-)"
prime_pos="$(printf '%s' "${opener_line}" | grep -bo "Engage at full cognitive depth" | head -1 | cut -d: -f1 || true)"
lead_pos="$(printf '%s' "${opener_line}" | grep -bo "Lead your first response" | head -1 | cut -d: -f1 || true)"
if [[ -n "${prime_pos}" && -n "${lead_pos}" && "${prime_pos}" -lt "${lead_pos}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T12 — depth prime should appear BEFORE "Lead your first response" in execution opener\n    prime_pos: %s    lead_pos: %s\n' \
    "${prime_pos:-MISSING}" "${lead_pos:-MISSING}" >&2
  fail=$((fail + 1))
fi

# T13 — Workflow "Deliberation comes first" bullet appears BEFORE the
# "default to action" rule in core.md. Positional check that proves the
# deliberation framing leads the action-bias framing — without this,
# a reader could interpret "default to action" as a license to skip
# deliberation. The dual-failure-mode framing requires deliberation
# to come FIRST in reading order.
deliberation_line="$(grep -n "Deliberation comes first, action comes second" "${CORE_MD}" | head -1 | cut -d: -f1 || true)"
action_line="$(grep -n "In maximum-autonomy mode, default to action" "${CORE_MD}" | head -1 | cut -d: -f1 || true)"
if [[ -n "${deliberation_line}" && -n "${action_line}" && "${deliberation_line}" -lt "${action_line}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T13 — Deliberation-first bullet should appear BEFORE default-to-action rule in core.md\n    deliberation: line %s    action: line %s\n' \
    "${deliberation_line:-MISSING}" "${action_line:-MISSING}" >&2
  fail=$((fail + 1))
fi

# T14 — no-defer contract FORBIDDEN list cross-references the dual-
# failure-mode framing. A future session reading only the v1.40.0
# contract section (and not the new preamble) must see the dual-
# framing collapse as the same anti-pattern as softening the contract
# itself. This assertion ensures the cross-link exists.
assert_contains_file \
  "T14 — no-defer contract cross-references dual-failure-mode framing" \
  "Collapsing the dual-failure-mode framing" \
  "${CORE_MD}"

# ---------------------------------------------------------------------
printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
exit $((fail > 0 ? 1 : 0))
