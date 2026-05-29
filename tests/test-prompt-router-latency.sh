#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
#
# tests/test-prompt-router-latency.sh — redact-dedup zero-behavior-change net.
#
# The prompt-intent-router previously redacted the user prompt TWICE per
# prompt: once into PROMPT_TEXT_SAFE (line ~39) and again into
# _omc_persisted_prompt_safe (the persist branch). The second computation
# was byte-for-byte identical input (PROMPT_TEXT, never reassigned) through
# the identical filter chain (omc_redact_secrets | tr -d '\000'). The
# latency optimization reuses PROMPT_TEXT_SAFE instead of recomputing,
# saving the router's heaviest avoidable per-prompt fork (a multi-pattern
# `sed -E` plus printf+tr) on every persist-on prompt.
#
# This test locks in the ZERO-BEHAVIOR-CHANGE contract: the persisted
# `last_user_prompt` must remain byte-identical to an independent
# recomputation of the old redaction path, for plain and secret-bearing
# prompts alike. If the dedup ever drifts from the canonical redaction,
# this net fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
ROUTER_SH="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${STATE_ROOT}"
touch "${STATE_ROOT}/.ulw_active"
mkdir -p "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${TEST_HOME}/.claude/skills/autowork"
mkdir -p "${TEST_HOME}/.claude/quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${TEST_HOME}/.claude/quality-pack/scripts"

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

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

assert_true() {
  local label="$1" cmd="$2"
  if eval "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — command false: %s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

# Run the router on a prompt; echo the persisted last_user_prompt.
run_router_persist() {
  local prompt="$1"
  local sid="lat-$$-${RANDOM}"
  local sdir="${STATE_ROOT}/${sid}"
  mkdir -p "${sdir}"
  local payload
  payload="$(jq -nc --arg s "${sid}" --arg c "${REPO_ROOT}" --arg p "${prompt}" \
    '{session_id:$s, cwd:$c, prompt:$p}')"
  printf '%s' "${payload}" | bash "${ROUTER_SH}" >/dev/null 2>&1 || true
  jq -r '.last_user_prompt // ""' "${sdir}/session_state.json" 2>/dev/null || printf ''
}

# Independent recomputation of the OLD redaction path (the falsifier:
# if the dedup drifts from this, the persisted value will differ).
canonical_redact() {
  printf '%s' "$1" \
    | ( . "${COMMON_SH}"; omc_redact_secrets ) \
    | tr -d '\000'
}

printf '\n--- redact-dedup zero-behavior-change ---\n'

# T1: plain prompt (redaction is identity) — persisted == input.
P1='ulw implement a small feature with tests'
assert_eq "T1 plain prompt persists verbatim" "$(canonical_redact "${P1}")" "$(run_router_persist "${P1}")"

# T2: secret-bearing prompt — persisted == canonical redaction, no raw leak.
P2='ulw deploy with --api-key sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA and Bearer abcdefgh12345678'
PERSISTED2="$(run_router_persist "${P2}")"
assert_eq "T2 secret prompt persists canonical redaction" "$(canonical_redact "${P2}")" "${PERSISTED2}"
assert_true "T2 no raw Anthropic key leaks" "! printf '%s' \"${PERSISTED2}\" | grep -q 'sk-ant-AAAA'"
assert_true "T2 redaction marker present" "printf '%s' \"${PERSISTED2}\" | grep -q '<redacted-secret>'"

# T3: KEY=VALUE flag form — another redaction shape, still byte-identical.
P3='ulw run with password=hunter2supersecretvalue please'
assert_eq "T3 key=value form persists canonical redaction" "$(canonical_redact "${P3}")" "$(run_router_persist "${P3}")"

printf '\n--- source-level dedup guard ---\n'

# T4: the persist branch must REUSE PROMPT_TEXT_SAFE, not recompute. The
# router body must contain the reuse assignment and must NOT pipe
# PROMPT_TEXT through omc_redact_secrets a second time into the persisted
# variable.
assert_true "T4 persist branch reuses PROMPT_TEXT_SAFE" \
  "grep -q '_omc_persisted_prompt_safe=\"\${PROMPT_TEXT_SAFE}\"' '${ROUTER_SH}'"
assert_true "T4 no second redaction pipe into persisted var" \
  "! grep -E '_omc_persisted_prompt_safe=\"\\\$\\(printf.*omc_redact_secrets' '${ROUTER_SH}'"
# PROMPT_TEXT_SAFE itself must still be computed exactly once (the single
# canonical redaction the dedup now reuses).
assert_eq "T4 PROMPT_TEXT_SAFE computed exactly once" "1" \
  "$(grep -c 'PROMPT_TEXT_SAFE="\$(printf' "${ROUTER_SH}")"

printf '\n=== test-prompt-router-latency.sh: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
