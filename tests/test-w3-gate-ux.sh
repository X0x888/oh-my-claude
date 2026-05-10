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

# Count of dual-audience sites in stop-guard.sh.
#
# v1.37.0 W3 baseline: 5 sites (advisory, session-handoff, wave-shape,
# discovered-scope, shortcut-ratio).
# v1.37.x W1 follow-up: 9 more sites (exemplifying-scope, review-coverage
# block-mode + per-block, excellence, metis-on-plan, delivery-contract,
# final-closure, block-mode-exhaustion, terminal quality block) ⇒ 14 total
# emit_stop_block call sites in stop-guard.sh.
#
# The assertion is bumped to ≥13 so a regression that silently drops a
# wrap is caught; ≥5 stayed green even under multi-site rollback. The
# metis pressure-test (Wave 1 sub-task) flagged this as the principal
# regression-risk gap. Note: grep counts INVOCATIONS, so each multi-line
# call adds 1 (the name appears once in `"$(format_gate_block_dual \`)
# even when args span multiple lines).
dual_count="$(grep -cE "format_gate_block_dual" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh" || true)"
if [[ "${dual_count}" -ge 13 ]]; then
  ok
else
  fail_msg "F-011 follow-up: expected ≥13 format_gate_block_dual sites in stop-guard.sh after Wave 1 migration (got: ${dual_count})"
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
# F-011 follow-up — terminal quality block FOR YOU is state-aware.
#
# The dynamic builder at stop-guard.sh:1255+ composes a different FOR YOU
# summary per state combination (verify_failed, verify_low_confidence,
# missing_review × missing_verify, review_unremediated, guard_blocks=2
# tail). The count assertion above (≥13 invocations) catches silent
# drops; these fixture tests catch state-mismatch — a regression that
# breaks the if/elif ordering and falls through to the generic else
# would still pass the count check otherwise.
# ----------------------------------------------------------------------
printf '\n--- F-011 follow-up: terminal-quality FOR YOU varies by state ---\n'

GATE_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"

# Fixture sandbox helper: build a fresh quality-pack state dir + session
# state, run stop-guard.sh against it, capture stdout. The terminal
# quality block needs the upstream gates to be SATISFIED so it actually
# reaches the dynamic-builder path — that means review/verify EITHER
# valid (so the gate doesn't trip earlier) OR specifically missing in
# the way we want to test.
run_terminal_quality_fixture() {
  # $1 = session id, $2 = state-overrides as a valid JSON object
  # literal (quoted keys, string values). Time-sensitive fields are
  # injected here as $NOW/$TS_OLD so callers don't need jq expressions.
  local sid="$1" overrides_json="$2"
  local fixture_home fixture_state now ts_old
  fixture_home="$(mktemp -d)"
  fixture_state="${fixture_home}/.claude/quality-pack/state/${sid}"
  mkdir -p "${fixture_state}"
  touch "${fixture_home}/.claude/quality-pack/state/.ulw_active"
  now="$(date +%s)"
  ts_old=$((now - 60))

  # Build base state, then merge overrides via jq. The base reaches the
  # terminal quality block — the upstream advisory/session-handoff/
  # exemplifying-scope/discovered-scope/shortcut-ratio/excellence/metis/
  # delivery-contract/final-closure gates either don't fire (no advisory
  # intent, no example-marker prompt, etc.) or get satisfied by the
  # override seed.
  jq -nc \
    --arg now "${now}" \
    --arg ts_old "${ts_old}" \
    --argjson overrides "${overrides_json}" \
    '({
      workflow_mode:"ultrawork",
      task_domain:"coding",
      task_intent:"execution",
      current_objective:"terminal-quality fixture test",
      last_user_prompt_ts:$ts_old,
      last_edit_ts:$now,
      last_code_edit_ts:$now
    } + $overrides)' \
    > "${fixture_state}/session_state.json"
  printf '/tmp/project/src/foo.ts\n' > "${fixture_state}/edited_files.log"

  HOME="${fixture_home}" \
  SESSION_ID="${sid}" \
  STATE_ROOT="${fixture_home}/.claude/quality-pack/state" \
  bash -c "printf '%s' \"\$(jq -nc --arg s '${sid}' '{session_id:\$s,last_assistant_message:\"work shipped\"}')\" \
    | bash '${GATE_SCRIPT}' 2>/dev/null" || true

  rm -rf "${fixture_home}" 2>/dev/null || true
}

NOW_TS="$(date +%s)"
REVIEW_TS=$((NOW_TS + 10))

# Test A: verify_failed=1 → "Verification failed" FOR YOU prefix.
out_a="$(run_terminal_quality_fixture "tq_verify_failed" \
  "{\"last_review_ts\":\"${NOW_TS}\",\"review_had_findings\":\"false\",\"subagent_dispatch_count\":\"1\",\"last_verify_ts\":\"${NOW_TS}\",\"last_verify_outcome\":\"failed\",\"last_verify_cmd\":\"npm test\"}")"
if [[ "${out_a}" == *"**FOR YOU:** Verification failed"* ]]; then
  ok
else
  fail_msg "F-011 FOR YOU: verify_failed=1 should produce 'Verification failed' prefix (got first 300 chars: ${out_a:0:300})"
fi

# Test B: missing_review + missing_verify → "Both review and verification missing".
out_b="$(run_terminal_quality_fixture "tq_both_missing" '{}')"
if [[ "${out_b}" == *"**FOR YOU:** Both review and verification missing"* ]]; then
  ok
else
  fail_msg "F-011 FOR YOU: missing review+verify should produce 'Both review and verification missing' prefix (got first 300 chars: ${out_b:0:300})"
fi

# Test C: review_unremediated=1 → "Reviewer flagged findings" prefix.
# Need last_review_ts > last_edit_ts (so review is fresh AND was after
# the edit) AND review_had_findings="true" (so unremediated condition
# trips). Setting REVIEW_TS = NOW+10 guarantees the strict inequality
# in stop-guard.sh:657: `effective_edit_ts < last_review_ts`.
out_c="$(run_terminal_quality_fixture "tq_unremediated" \
  "{\"last_review_ts\":\"${REVIEW_TS}\",\"review_had_findings\":\"true\",\"subagent_dispatch_count\":\"1\",\"last_verify_ts\":\"${REVIEW_TS}\",\"last_verify_outcome\":\"passed\",\"last_verify_cmd\":\"npm test\",\"last_verify_confidence\":\"95\"}")"
if [[ "${out_c}" == *"**FOR YOU:** Reviewer flagged findings"* ]]; then
  ok
else
  fail_msg "F-011 FOR YOU: review_unremediated=1 should produce 'Reviewer flagged findings' prefix (got first 300 chars: ${out_c:0:300})"
fi

# Test D: stop_guard_blocks=2 (final-block tail) appends the "final guard block" sentence.
# stop-guard.sh reads guard_blocks from state key `stop_guard_blocks`
# (see read_state_keys block at stop-guard.sh:546). When guard_blocks
# starts at 2, the next emission is block 3/3 — the final guard block.
out_d="$(run_terminal_quality_fixture "tq_final_block" '{"stop_guard_blocks":"2"}')"
if [[ "${out_d}" == *"final guard block"* ]] \
  && [[ "${out_d}" == *"**FOR YOU:**"* ]]; then
  ok
else
  fail_msg "F-011 FOR YOU: stop_guard_blocks=2 should append 'final guard block' tail (got first 400 chars: ${out_d:0:400})"
fi

# ----------------------------------------------------------------------
# F-013 follow-up (Item 5): runtime regression for objective truncation.
# The source-greps above (lines 145-152) test that the literal `240` and
# `_ellipsis="..."` strings exist in show-status.sh, but a typo in the
# variable referenced by the jq filter would still leave those literals
# in source while the actual rendered output skipped truncation. This
# fixture seeds a long current_objective (>240 chars), invokes
# show-status, and asserts the output is truncated AND contains the
# ellipsis suffix.
# ----------------------------------------------------------------------
printf '\n--- F-013 runtime: objective truncation actually fires ---\n'

f013_runtime_home="${TEST_TMP}/f013-runtime-home"
mkdir -p "${f013_runtime_home}/.claude"
ln -sf "${REPO_ROOT}/bundle/dot-claude/skills" "${f013_runtime_home}/.claude/skills"
ln -sf "${REPO_ROOT}/bundle/dot-claude/quality-pack" "${f013_runtime_home}/.claude/quality-pack"

f013_state="${TEST_TMP}/f013-state"
f013_sid="aaaaaaaa-bbbb-cccc-dddd-000000000013"
mkdir -p "${f013_state}/${f013_sid}"

# Build an objective: 240 'A's prefix + a unique trailing token. The
# unique token only appears once in the source string AND is at
# position > 240 char threshold, so a properly-truncated line cannot
# contain it. (The earlier prepared-string approach used a repeated
# sentence; the position-based marker collided with earlier reps.)
f013_long_prefix="$(printf 'A%.0s' $(seq 1 240))"
f013_unique_tail="UNIQUE_F013_TAIL_MARKER_THAT_MUST_BE_TRUNCATED"
f013_long="${f013_long_prefix}${f013_unique_tail}"

jq -nc --arg obj "${f013_long}" \
  '{workflow_mode:"ulw",task_intent:"execution",task_domain:"coding",current_objective:$obj}' \
  > "${f013_state}/${f013_sid}/session_state.json"

f013_out="$(HOME="${f013_runtime_home}" \
  STATE_ROOT="${f013_state}" \
  SESSION_ID="${f013_sid}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh" 2>/dev/null || true)"

# Find the rendered Objective line from the output.
f013_obj_line="$(printf '%s\n' "${f013_out}" | grep '^Objective:' | head -1)"

# Assertion 1: the objective line ends with the ellipsis (Unicode … or ASCII ...).
if [[ "${f013_obj_line}" == *"…"* ]] || [[ "${f013_obj_line}" == *"..."* ]]; then
  ok
else
  fail_msg "F-013 runtime: objective line should contain ellipsis suffix when objective > 240 chars (got: ${f013_obj_line})"
fi

# Assertion 2: the unique trailing marker (positioned > 240 chars in)
# must NOT be in the rendered line — truncation must have fired.
if [[ "${f013_obj_line}" != *"${f013_unique_tail}"* ]]; then
  ok
else
  fail_msg "F-013 runtime: objective line still contains the unique tail marker — truncation did not fire (line: ${f013_obj_line})"
fi

# Assertion 3: OMC_PLAIN=1 swaps the Unicode … for ASCII "..." in the
# rendered output (not just in the source).
f013_plain_out="$(HOME="${f013_runtime_home}" \
  STATE_ROOT="${f013_state}" \
  SESSION_ID="${f013_sid}" \
  OMC_PLAIN=1 \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh" 2>/dev/null || true)"
f013_plain_line="$(printf '%s\n' "${f013_plain_out}" | grep '^Objective:' | head -1)"
if [[ "${f013_plain_line}" == *"..."* ]] && [[ "${f013_plain_line}" != *"…"* ]]; then
  ok
else
  fail_msg "F-013 runtime: OMC_PLAIN=1 should render ASCII '...' not Unicode '…' (got: ${f013_plain_line})"
fi

# ----------------------------------------------------------------------
printf '\n=== Wave 3 gate-UX tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
