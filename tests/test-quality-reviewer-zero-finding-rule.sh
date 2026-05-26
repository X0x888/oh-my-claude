#!/usr/bin/env bash
# Regression net for v1.44-pre Port 3 — quality-reviewer.md priority 12
# (zero-finding evidence anchor rule).
#
# This test asserts the rule's PRESENCE and SHAPE in the agent prompt.
# It cannot assert the rule's EFFECT (whether real reviewers follow it)
# — that signal lives in `/ulw-report` over time. The grep here is the
# load-bearing regression net against future edits silently dropping
# the rule.
#
# Cross-ref: cc10x's code-reviewer.md "zero-finding gate caps at 70%
# unless substantiated" was the source pattern; oh-my-claude's port is
# narrower (prompt-only) and deliberately leaves enforcement to model
# discipline + the existing two-pass reviewer chain. See
# `~/.claude/projects/-Users-xxxcoding-Documents-ai-coding-oh-my-claude/memory/project_v1_44_pre_5port_wave_landed.md`
# for the considered-and-declined alternative (hook-side anchor counting
# in record-reviewer.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENT_FILE="${REPO_ROOT}/bundle/dot-claude/agents/quality-reviewer.md"

pass=0
fail=0

assert_grep() {
  local label="$1" pattern="$2"
  if grep -qE "${pattern}" "${AGENT_FILE}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%q not found in %s\n' "${label}" "${pattern}" "${AGENT_FILE}" >&2
    fail=$((fail + 1))
  fi
}

assert_count_at_least() {
  local label="$1" pattern="$2" min="$3"
  local count
  count="$(grep -cE "${pattern}" "${AGENT_FILE}" || true)"
  if (( count >= min )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%q found %d times, expected ≥%d\n' "${label}" "${pattern}" "${count}" "${min}" >&2
    fail=$((fail + 1))
  fi
}

[[ -f "${AGENT_FILE}" ]] || { printf 'FATAL: missing %s\n' "${AGENT_FILE}" >&2; exit 1; }

# T1: priority 12 exists and is named.
assert_grep "T1: priority 12 'Zero-finding evidence anchor' present" \
  '^12\. Zero-finding evidence anchor'

# T2: rule names the ≥2 anchor requirement explicitly.
assert_grep "T2: rule requires ≥2 file:line anchors" \
  '≥2[[:space:]]+concrete file:line evidence anchors'

# T3: rule names the downgrade contract (FINDINGS + meta-finding).
assert_grep "T3: rule specifies downgrade to FINDINGS (1)" \
  'VERDICT: FINDINGS \(1\)'
assert_grep "T3: rule names the meta-finding shape" \
  'meta-finding'

# T4: priority 12 comes AFTER priority 11 in document order.
p11_line="$(grep -nE '^11\. Documented contracts' "${AGENT_FILE}" | head -1 | cut -d: -f1)"
p12_line="$(grep -nE '^12\. Zero-finding evidence anchor' "${AGENT_FILE}" | head -1 | cut -d: -f1)"
if [[ -n "${p11_line}" && -n "${p12_line}" ]] && (( p12_line > p11_line )); then
  pass=$((pass + 1))
else
  printf '  FAIL: T4: priority 12 must follow priority 11\n    p11_line=%s p12_line=%s\n' "${p11_line}" "${p12_line}" >&2
  fail=$((fail + 1))
fi

# T5: existing terminal contract (`End with exactly one line`) is still
# present — proves the insertion did not displace the contract.
assert_grep "T5: terminal VERDICT contract still present" \
  'End with exactly one line on its own'

# T6: rule explicitly names "/ulw-report" as the measurement path
# (per memory file — the rule is prompt-only by design, not mechanical).
assert_grep "T6: rule names /ulw-report as effectiveness measurement path" \
  '/ulw-report'

printf '\n'
printf 'test-quality-reviewer-zero-finding-rule: %d passed, %d failed\n' "${pass}" "${fail}"
exit "${fail}"
