#!/usr/bin/env bash
# Tests for the orphan-specialist routing nudges added to the
# coding-domain hint in prompt-intent-router.sh.
#
# Before this change, the coding-domain hint named only the reasoning
# specialists (prometheus, quality-planner, quality-researcher,
# librarian, metis, oracle) and ended with a generic "domain-specific
# execution → the closest specialist engineering agent" line. The
# engineering specialists (backend-api-developer,
# devops-infrastructure-engineer, test-automation-engineer,
# fullstack-feature-builder, the four ios-* lanes, abstraction-critic)
# were orphaned: discoverable only through manual slash commands. This test
# locks in their presence in the routing table so a future router
# refactor cannot silently drop them again.
#
# Mirrors the sandbox setup of test-bias-defense-directives.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t specialist-routing-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack(first 400)=%q\n' "${label}" "${needle}" "${haystack:0:400}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    unexpected needle=%q in haystack\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

_cleanup_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup_test EXIT

_run_router() {
  local session_id="$1"
  local prompt_text="$2"
  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    '{session_id:$sid, prompt:$p, cwd:env.PWD}')"
  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true
}

# A coding-domain ULW prompt with explicit code-anchored signals so the
# router consistently selects the `coding` branch (not `mixed`) across
# project profiles. The classifier scores prompts by keyword density,
# so we use unambiguous terms ("fix the off-by-one bug", file path).
_CODING_PROMPT="ulw fix the off-by-one bug in src/payment/processor.ts line 42"

# ----------------------------------------------------------------------
printf 'Test 1: coding-domain hint enumerates engineering specialists\n'
out="$(_run_router "t1-${RANDOM}" "${_CODING_PROMPT}")"

assert_contains "domain hint present"            "Detected likely task domain: coding" "${out}"
assert_contains "names backend-api-developer"    "backend-api-developer"               "${out}"
assert_contains "names frontend-developer (v1.27.0 F-016)" "frontend-developer"        "${out}"
assert_contains "names devops-infrastructure"    "devops-infrastructure-engineer"      "${out}"
assert_contains "names test-automation"          "test-automation-engineer"            "${out}"
assert_contains "names fullstack-feature"        "fullstack-feature-builder"           "${out}"
assert_contains "names ios-ui-developer"         "ios-ui-developer"                    "${out}"
assert_contains "names ios-core-engineer"        "ios-core-engineer"                   "${out}"
assert_contains "names ios-deployment"           "ios-deployment-specialist"           "${out}"
assert_contains "names ios-ecosystem"            "ios-ecosystem-integrator"            "${out}"
assert_contains "names abstraction-critic"       "abstraction-critic"                  "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: existing reasoning specialists are still routed\n'
out="$(_run_router "t2-${RANDOM}" "${_CODING_PROMPT}")"

assert_contains "names prometheus"               "prometheus for interview-first"      "${out}"
assert_contains "names quality-planner"          "quality-planner"                     "${out}"
assert_contains "names quality-researcher"       "quality-researcher"                  "${out}"
assert_contains "names librarian"                "librarian"                           "${out}"
assert_contains "names metis"                    "metis"                               "${out}"
assert_contains "names oracle"                   "oracle"                              "${out}"

# ----------------------------------------------------------------------
printf 'Test 2b: planner/prometheus disambiguation guidance present (v1.27.0 F-017)\n'
out="$(_run_router "t2b-${RANDOM}" "${_CODING_PROMPT}")"
assert_contains "prometheus → quality-planner deferral guidance" \
  "Defer to quality-planner instead when the request is concrete enough" "${out}"
assert_contains "quality-planner → prometheus deferral guidance" \
  "Defer to prometheus instead when the request is broad" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: vague catch-all line is gone\n'
out="$(_run_router "t3-${RANDOM}" "${_CODING_PROMPT}")"

assert_not_contains "no generic catch-all" "the closest specialist engineering agent" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: writing-domain prompt does NOT inject engineering routing\n'
out="$(_run_router "t4-${RANDOM}" "ulw draft a quarterly business proposal")"

# Writing-domain hint is independent of the coding routing. The new
# specialist nudges should not bleed into other domains.
assert_not_contains "no backend leak in writing"  "backend-api-developer"          "${out}"
assert_not_contains "no devops leak in writing"   "devops-infrastructure-engineer" "${out}"
assert_not_contains "no test-auto leak in writing" "test-automation-engineer"      "${out}"

# ----------------------------------------------------------------------
printf '\n'
printf 'specialist-routing: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
