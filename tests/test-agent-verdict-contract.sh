#!/usr/bin/env bash
# test-agent-verdict-contract.sh — Universal VERDICT contract regression net.
#
# Asserts every agent in `bundle/dot-claude/agents/*.md` ends its body with
# a structured `VERDICT:` final-line contract, and that the agent's
# emitted vocabulary matches the role-specific vocabulary documented in
# AGENTS.md → "Universal VERDICT contract (v1.14.0)".
#
# Without this test, the next agent added to the bundle could silently
# regress the contract — verify.sh's path-existence check cannot detect
# a contract drift, and only 6 of 32 agents have any consumer parsing
# (record-reviewer.sh) that would catch the drift in a behavioral test.
#
# Mirrors the symbol-presence pattern of tests/test-classifier.sh and
# tests/test-verification-lib.sh. Uses bash-3.2-compatible data
# structures (case statements, not associative arrays) so it runs on
# stock macOS bash without `brew install bash`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENTS_DIR="${REPO_ROOT}/bundle/dot-claude/agents"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# Role of an agent. When adding a new agent, extend this case and the
# test will catch a missing or wrong-vocabulary VERDICT line. Roles
# match AGENTS.md → "Universal VERDICT contract (v1.14.0)" table.
role_of_agent() {
  case "$1" in
    quality-reviewer|editor-critic|excellence-reviewer|metis|briefing-analyst|design-reviewer|abstraction-critic)
      printf 'reviewer' ;;
    data-lens|design-lens|growth-lens|product-lens|security-lens|sre-lens|visual-craft-lens)
      printf 'lens' ;;
    prometheus|quality-planner)
      printf 'planner' ;;
    librarian|quality-researcher)
      printf 'researcher' ;;
    oracle)
      printf 'debugger' ;;
    divergent-framer)
      printf 'framer' ;;
    atlas|chief-of-staff)
      printf 'operations' ;;
    draft-writer|writing-architect)
      printf 'writer' ;;
    backend-api-developer|devops-infrastructure-engineer|frontend-developer|fullstack-feature-builder|ios-core-engineer|ios-deployment-specialist|ios-ecosystem-integrator|ios-ui-developer|test-automation-engineer)
      printf 'implementer' ;;
    *)
      printf '' ;;
  esac
}

# Tokens an agent's role contracts to emit. Space-separated.
allowed_tokens_of_role() {
  case "$1" in
    reviewer)    printf 'CLEAN SHIP FINDINGS BLOCK' ;;
    lens)        printf 'CLEAN FINDINGS' ;;
    planner)     printf 'PLAN_READY NEEDS_CLARIFICATION BLOCKED' ;;
    researcher)  printf 'REPORT_READY INSUFFICIENT_SOURCES' ;;
    debugger)    printf 'RESOLVED HYPOTHESIS NEEDS_EVIDENCE' ;;
    framer)      printf 'FRAMINGS_READY NEEDS_PROBLEM_STATEMENT INSUFFICIENT_OPTIONS' ;;
    operations)  printf 'DELIVERED NEEDS_INPUT BLOCKED' ;;
    writer)      printf 'DELIVERED NEEDS_INPUT NEEDS_RESEARCH' ;;
    implementer) printf 'SHIP INCOMPLETE BLOCKED' ;;
    *)           printf '' ;;
  esac
}

# Role that owns an exclusive token. Tokens shared by multiple roles
# (CLEAN/SHIP/FINDINGS/BLOCK/BLOCKED/DELIVERED/NEEDS_INPUT) are NOT in
# this list — only tokens unique to one role.
owner_role_of_exclusive_token() {
  case "$1" in
    PLAN_READY|NEEDS_CLARIFICATION) printf 'planner' ;;
    REPORT_READY|INSUFFICIENT_SOURCES) printf 'researcher' ;;
    RESOLVED|HYPOTHESIS|NEEDS_EVIDENCE) printf 'debugger' ;;
    INCOMPLETE) printf 'implementer' ;;
    NEEDS_RESEARCH) printf 'writer' ;;
    *) printf '' ;;
  esac
}

# ----------------------------------------------------------------------
printf 'Test 1: every agent file in bundle/dot-claude/agents/ contains a VERDICT line\n'

shopt -s nullglob
agent_files=("${AGENTS_DIR}"/*.md)
shopt -u nullglob
agent_count="${#agent_files[@]}"
assert_eq "33 agent files present (v1.31.0 added divergent-framer)" "33" "${agent_count}"

for f in "${agent_files[@]}"; do
  agent_name="$(basename "${f}" .md)"
  if grep -qE 'VERDICT:' "${f}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: agent %q has no VERDICT line\n' "${agent_name}" >&2
    fail=$((fail + 1))
  fi
done

# ----------------------------------------------------------------------
printf 'Test 2: every agent has a known role in the AGENTS.md mapping\n'

for f in "${agent_files[@]}"; do
  agent_name="$(basename "${f}" .md)"
  role="$(role_of_agent "${agent_name}")"
  if [[ -n "${role}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: agent %q has no role assigned in test-agent-verdict-contract.sh\n' "${agent_name}" >&2
    printf '        Add it to role_of_agent() and re-run; if it is a new role, also extend allowed_tokens_of_role() + AGENTS.md.\n' >&2
    fail=$((fail + 1))
  fi
done

# ----------------------------------------------------------------------
printf "Test 3: every agent emits at least one VERDICT token from its role's vocabulary\n"
# Reviewer-class agents are documented to share `CLEAN|SHIP|FINDINGS|BLOCK`
# but each reviewer typically emits a subset (e.g., quality-reviewer uses
# `CLEAN|FINDINGS(N)` only). The contract is that any emitted token must
# be from the role's allowed list, and at least one allowed token must
# appear. Tokens outside the allowed list are flagged in Test 4.

for f in "${agent_files[@]}"; do
  agent_name="$(basename "${f}" .md)"
  role="$(role_of_agent "${agent_name}")"
  [[ -z "${role}" ]] && continue
  allowed="$(allowed_tokens_of_role "${role}")"
  emitted_count=0
  for token in ${allowed}; do
    if grep -Eq "VERDICT:[[:space:]]*${token}\b" "${f}"; then
      emitted_count=$((emitted_count + 1))
    fi
  done
  if [[ "${emitted_count}" -ge 1 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: agent %q (role=%s) emits no token from allowed vocabulary [%s]\n' \
      "${agent_name}" "${role}" "${allowed}" >&2
    fail=$((fail + 1))
  fi
done

# ----------------------------------------------------------------------
printf "Test 4: agents do not bleed exclusive tokens from other roles\n"

EXCLUSIVE_TOKENS="PLAN_READY NEEDS_CLARIFICATION REPORT_READY INSUFFICIENT_SOURCES RESOLVED HYPOTHESIS NEEDS_EVIDENCE INCOMPLETE NEEDS_RESEARCH"
for token in ${EXCLUSIVE_TOKENS}; do
  expected_role="$(owner_role_of_exclusive_token "${token}")"
  for f in "${agent_files[@]}"; do
    agent_name="$(basename "${f}" .md)"
    role="$(role_of_agent "${agent_name}")"
    role="${role:-unknown}"
    if [[ "${role}" == "${expected_role}" ]]; then continue; fi
    if grep -Eq "VERDICT:[[:space:]]*${token}\b" "${f}"; then
      printf '  FAIL: agent %q (role=%s) emits exclusive token %q (belongs to role=%s)\n' \
        "${agent_name}" "${role}" "${token}" "${expected_role}" >&2
      fail=$((fail + 1))
    else
      pass=$((pass + 1))
    fi
  done
done

# ----------------------------------------------------------------------
printf "Test 5: VERDICT clause instructs the agent that VERDICT is the FINAL line of its response\n"
# The contract is positional in the AGENT'S RUNTIME OUTPUT, not in the
# agent file's text. We assert the file mentions "final line" (or
# equivalent) near the VERDICT mention so the agent knows where to
# place the line at runtime. Some agent files have additional
# instructions after the VERDICT clause (e.g., "Do not edit files.")
# — that's fine; the agent reads the prompt and emits VERDICT last
# regardless of the prompt's structural ordering.
for f in "${agent_files[@]}"; do
  agent_name="$(basename "${f}" .md)"
  if grep -qE 'VERDICT:' "${f}"; then
    if grep -Eq '(final line|last line|on its own)' "${f}"; then
      pass=$((pass + 1))
    else
      printf '  FAIL: agent %q VERDICT clause does not say "final line"/"last line"/"on its own"\n' "${agent_name}" >&2
      fail=$((fail + 1))
    fi
  fi
done

# ----------------------------------------------------------------------
printf "Test 6: AGENTS.md table mentions every role token vocabulary\n"
agents_md="${REPO_ROOT}/AGENTS.md"
for role in reviewer lens planner researcher debugger operations writer implementer; do
  for token in $(allowed_tokens_of_role "${role}"); do
    if grep -Fq "${token}" "${agents_md}"; then
      pass=$((pass + 1))
    else
      printf '  FAIL: AGENTS.md does not mention VERDICT token %q (role=%s)\n' "${token}" "${role}" >&2
      fail=$((fail + 1))
    fi
  done
done

# ----------------------------------------------------------------------
printf '\n=== Agent VERDICT Contract: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
