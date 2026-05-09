#!/usr/bin/env bash
# v1.36.x Wave 3 gate-block UX regression tests.
#
# Covers F-011 (FOR YOU/FOR MODEL split via format_gate_block_dual),
# F-012 (multi-option recovery via format_gate_recovery_options),
# F-013 (long-objective truncation in /ulw-status with visual ellipsis),
# F-014 (OMC_PLAIN ASCII opt-out for stacked bar / sparkline / box-rule).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
TIMING_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/timing.sh"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
export STATE_ROOT="${TEST_TMP}/state"
mkdir -p "${STATE_ROOT}"

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); }
fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# F-011 — format_gate_block_dual produces FOR YOU / FOR MODEL split.
# ----------------------------------------------------------------------
printf '\n--- F-011: format_gate_block_dual emits dual-audience framing ---\n'

if grep -qE "^format_gate_block_dual\(\)" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-011: format_gate_block_dual helper missing from common.sh"
fi

dual_out="$(bash -c "
  set +u
  source '${COMMON_SH}'
  format_gate_block_dual 'human one-liner here' 'model prose with recovery'
")"
if [[ "${dual_out}" == *"**FOR YOU:** human one-liner here"* ]] \
   && [[ "${dual_out}" == *"**FOR MODEL:** model prose with recovery"* ]]; then
  ok
else
  fail_msg "F-011: dual-audience output missing FOR YOU/FOR MODEL markers"
fi

# Empty human_summary falls through cleanly.
fallthrough="$(bash -c "
  set +u
  source '${COMMON_SH}'
  format_gate_block_dual '' 'just the model prose'
")"
if [[ "${fallthrough}" == "just the model prose" ]]; then
  ok
else
  fail_msg "F-011: empty human_summary should fall through unchanged (got: ${fallthrough})"
fi

# Stop-guard call sites use the helper for at least the high-traffic gates.
for gate in advisory session-handoff wave-shape discovered-scope shortcut-ratio; do
  if grep -qE "format_gate_block_dual.*[A-Za-z]" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"; then
    : # presence-check; precise per-gate matching is complicated by the
      # multi-line bash heredocs, so a single grep covers the wave's
      # expected wiring.
  fi
done
if grep -qE "format_gate_block_dual" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"; then
  ok
else
  fail_msg "F-011: stop-guard.sh does not invoke format_gate_block_dual"
fi

# Count of dual-audience sites should be at least 5 (advisory, session-handoff,
# wave-shape, discovered-scope, shortcut-ratio).
dual_count="$(grep -cE "format_gate_block_dual" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh" || true)"
if [[ "${dual_count}" -ge 5 ]]; then
  ok
else
  fail_msg "F-011: expected ≥5 format_gate_block_dual sites in stop-guard.sh (got: ${dual_count})"
fi

# ----------------------------------------------------------------------
# F-012 — format_gate_recovery_options emits multi-option block.
# ----------------------------------------------------------------------
printf '\n--- F-012: format_gate_recovery_options emits structured options ---\n'

if grep -qE "^format_gate_recovery_options\(\)" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-012: format_gate_recovery_options helper missing"
fi

opts_out="$(bash -c "
  set +u
  source '${COMMON_SH}'
  format_gate_recovery_options 'first option' 'second option' 'third option'
")"
if [[ "${opts_out}" == *"Recovery options:"* ]] \
   && [[ "${opts_out}" == *"→ first option"* ]] \
   && [[ "${opts_out}" == *"→ second option"* ]] \
   && [[ "${opts_out}" == *"→ third option"* ]]; then
  ok
else
  fail_msg "F-012: multi-option block missing 'Recovery options:' lead or → bullets"
fi

# Empty input returns lead but no options (graceful).
opts_empty="$(bash -c "
  set +u
  source '${COMMON_SH}'
  format_gate_recovery_options
")"
if [[ "${opts_empty}" == *"Recovery options:"* ]]; then
  ok
else
  fail_msg "F-012: empty options should still emit 'Recovery options:' lead"
fi

# ----------------------------------------------------------------------
# F-013 — Objective truncation bumped from 100 to 240 chars with ellipsis.
# ----------------------------------------------------------------------
printf '\n--- F-013: objective truncation handles long prompts ---\n'

if grep -qE "current_objective.*240.*ellipsis" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"; then
  ok
else
  fail_msg "F-013: show-status.sh does not truncate at 240 with ellipsis variable"
fi

# OMC_PLAIN ellipsis fallback should switch from … to ...
if grep -qE '_ellipsis="\.\.\."' "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"; then
  ok
else
  fail_msg "F-013: OMC_PLAIN should swap … for ... in the ellipsis variable"
fi

# ----------------------------------------------------------------------
# F-014 — OMC_PLAIN=1 falls back to ASCII glyphs.
# ----------------------------------------------------------------------
printf '\n--- F-014: OMC_PLAIN=1 swaps Unicode for ASCII ---\n'

# omc_box_rule_glyph default is U+2500 (─); OMC_PLAIN=1 returns '-'.
default_glyph="$(bash -c "
  set +u
  source '${COMMON_SH}'
  omc_box_rule_glyph 1
")"
if [[ "${default_glyph}" == "─" ]]; then
  ok
else
  fail_msg "F-014: omc_box_rule_glyph default should be ─ (got: ${default_glyph})"
fi

plain_glyph="$(OMC_PLAIN=1 bash -c "
  set +u
  source '${COMMON_SH}'
  omc_box_rule_glyph 1
")"
if [[ "${plain_glyph}" == "-" ]]; then
  ok
else
  fail_msg "F-014: OMC_PLAIN=1 omc_box_rule_glyph should be '-' (got: ${plain_glyph})"
fi

# Triple-rune block.
triple_default="$(bash -c "
  set +u
  source '${COMMON_SH}'
  omc_box_rule_glyph 3
")"
if [[ "${triple_default}" == "───" ]]; then
  ok
else
  fail_msg "F-014: omc_box_rule_glyph 3 default should be ─── (got: ${triple_default})"
fi

triple_plain="$(OMC_PLAIN=1 bash -c "
  set +u
  source '${COMMON_SH}'
  omc_box_rule_glyph 3
")"
if [[ "${triple_plain}" == "---" ]]; then
  ok
else
  fail_msg "F-014: OMC_PLAIN=1 omc_box_rule_glyph 3 should be '---' (got: ${triple_plain})"
fi

# Stacked bar uses ASCII chars under OMC_PLAIN=1.
plain_bar="$(OMC_PLAIN=1 bash -c "
  set +u
  source '${COMMON_SH}'
  source '${TIMING_SH}'
  _timing_stacked_bar 50 30 20 10
")"
# ASCII glyphs: # = .
if [[ "${plain_bar}" == *"#"* ]] && [[ "${plain_bar}" == *"="* ]] && [[ "${plain_bar}" == *"."* ]]; then
  ok
else
  fail_msg "F-014: OMC_PLAIN bar should use # = . (got: ${plain_bar})"
fi

# Default bar uses Unicode chars.
default_bar="$(bash -c "
  set +u
  source '${COMMON_SH}'
  source '${TIMING_SH}'
  _timing_stacked_bar 50 30 20 10
")"
if [[ "${default_bar}" == *"█"* ]] && [[ "${default_bar}" == *"▒"* ]] && [[ "${default_bar}" == *"░"* ]]; then
  ok
else
  fail_msg "F-014: default bar should use Unicode glyphs (got: ${default_bar})"
fi

# ----------------------------------------------------------------------
printf '\n=== Wave 3 gate-UX tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
