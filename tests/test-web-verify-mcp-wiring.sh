#!/usr/bin/env bash
#
# test-web-verify-mcp-wiring.sh — regression net for the Playwright +
# Chrome DevTools MCP "verify the rendered result" wiring across the web
# surfaces (commit 440764c, v1.44-pre ecosystem-integration).
#
# WHY THIS EXISTS: the MCP recommendation is prose in agent/skill markdown,
# not hook wiring, so a future edit can silently drop it from a surface
# with green CI. This test pins:
#   (1) every web surface still recommends browser-MCP rendered-result
#       verification framed as an accessibility snapshot (not pixels);
#   (2) the builder surfaces carry the `User-must-verify-UI` fallback for
#       when no MCP is installed (design-reviewer, a reviewer, intentionally
#       uses an "evaluate from code" fallback instead);
#   (3) the verification scorer (lib/verification.sh) still recognizes the
#       Playwright browser tool family — so the recommendation and the gate
#       cannot drift apart (a surface telling the model to use a tool the
#       gate would not credit).
#
# Pinned in .github/workflows/validate.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0
assert_pass() { printf '  [ok]   %s\n' "$1"; pass=$((pass + 1)); }
assert_fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then printf '         %s\n' "$2" >&2; fi
  fail=$((fail + 1))
}

AGENTS_DIR="${REPO_ROOT}/bundle/dot-claude/agents"
SKILLS_DIR="${REPO_ROOT}/bundle/dot-claude/skills"
VERIFICATION_LIB="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/verification.sh"

# Every web surface that received the Playwright/Chrome-DevTools MCP wiring.
WEB_SURFACES=(
  "${AGENTS_DIR}/frontend-developer.md"
  "${AGENTS_DIR}/fullstack-feature-builder.md"
  "${AGENTS_DIR}/design-reviewer.md"
  "${SKILLS_DIR}/frontend-design/SKILL.md"
)

# Builder surfaces SHIP UI and so must carry the `User-must-verify-UI`
# fallback. design-reviewer is a reviewer (evaluates, does not ship) and
# uses an "evaluate from code" fallback instead — deliberately excluded.
BUILDER_SURFACES=(
  "${AGENTS_DIR}/frontend-developer.md"
  "${AGENTS_DIR}/fullstack-feature-builder.md"
  "${SKILLS_DIR}/frontend-design/SKILL.md"
)

printf 'Web-verify MCP wiring\n'

# (1) Every web surface recommends Playwright MCP rendered-result verification.
for surface in "${WEB_SURFACES[@]}"; do
  name="$(basename "$(dirname "${surface}")")/$(basename "${surface}")"
  if [[ ! -f "${surface}" ]]; then
    assert_fail "missing web surface: ${surface}" "the MCP-wiring set changed — update WEB_SURFACES"
    continue
  fi
  if grep -qi 'playwright mcp' "${surface}"; then
    assert_pass "${name} recommends Playwright MCP"
  else
    assert_fail "${name} no longer references Playwright MCP" \
      "the rendered-result verification recommendation was dropped from this surface"
  fi
  if grep -qiE 'accessibility[ -]?tree snapshot|accessibility snapshot' "${surface}"; then
    assert_pass "${name} frames it as an accessibility snapshot (not pixel screenshots)"
  else
    assert_fail "${name} lost the accessibility-snapshot framing" \
      "snapshot-over-screenshot is the load-bearing rationale of the recommendation"
  fi
done

# (2) Builder surfaces carry the User-must-verify-UI fallback.
for surface in "${BUILDER_SURFACES[@]}"; do
  name="$(basename "$(dirname "${surface}")")/$(basename "${surface}")"
  if grep -q 'User-must-verify-UI' "${surface}"; then
    assert_pass "${name} carries the User-must-verify-UI fallback"
  else
    assert_fail "${name} lost the User-must-verify-UI fallback" \
      "without an MCP the surface must end with User-must-verify-UI, not claim unverified UI works"
  fi
done

# (3) design-reviewer uses the code-evaluation fallback (it reviews, not ships).
if grep -qiE 'evaluate from code|from code as below|from code alone' "${AGENTS_DIR}/design-reviewer.md"; then
  assert_pass "design-reviewer.md keeps the absent-MCP code-evaluation fallback"
else
  assert_fail "design-reviewer.md lost its absent-MCP fallback" \
    "design-reviewer should still say how to evaluate when Playwright MCP is unavailable"
fi

# (4) The verification scorer recognizes the Playwright browser tool family,
#     so a surface's recommendation maps to a tool the gate actually credits.
if [[ ! -f "${VERIFICATION_LIB}" ]]; then
  assert_fail "lib/verification.sh missing" "expected at ${VERIFICATION_LIB}"
else
  for tool in browser_snapshot browser_take_screenshot browser_console_messages browser_network_requests; do
    if grep -q "${tool}" "${VERIFICATION_LIB}"; then
      assert_pass "verification scorer recognizes ${tool}"
    else
      assert_fail "verification scorer no longer recognizes ${tool}" \
        "web surfaces recommend Playwright MCP but the gate would ignore ${tool} — recommendation and scorer drifted"
    fi
  done
fi

printf '\n=== web-verify MCP wiring: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
