#!/usr/bin/env bash
# v1.36.x Wave 4 onboarding-funnel regression tests.
#
# Covers F-015 (README ordering: Comparison/proof above Install/procedure),
# F-016 (docs/showcase.md replaces synthetic seed with real entries),
# F-017 (README links ohmyclaude.dev), F-018 (install.sh footer collapsed
# to single canonical /ulw-demo CTA), F-019 (post-restart welcome banner
# differentiates the post-install session).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

ok() { pass=$((pass + 1)); }
fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# F-015 — README orders Comparison/proof BEFORE Install/procedure.
# ----------------------------------------------------------------------
printf '\n--- F-015: README proof-before-procedure ---\n'

readme="${REPO_ROOT}/README.md"
# The new comparison section header is "## How is this different from vanilla Claude Code?"
compare_line="$(grep -n '^## How is this different' "${readme}" | head -1 | cut -d: -f1)"
install_line="$(grep -n '^## Quick start' "${readme}" | head -1 | cut -d: -f1)"

if [[ -n "${compare_line}" && -n "${install_line}" && "${compare_line}" -lt "${install_line}" ]]; then
  ok
else
  fail_msg "F-015: comparison section (line ${compare_line:-?}) should appear before Quick start (line ${install_line:-?})"
fi

# Old "## Comparison" section should NOT appear (we moved it).
if grep -qE "^## Comparison$" "${readme}"; then
  fail_msg "F-015: legacy '## Comparison' header still present — should be moved to 'How is this different' above Quick start"
else
  ok
fi

# ----------------------------------------------------------------------
# F-016 — docs/showcase.md replaces synthetic seed with real entries.
# ----------------------------------------------------------------------
printf '\n--- F-016: showcase has real entries, not synthetic seed ---\n'

showcase="${REPO_ROOT}/docs/showcase.md"
if grep -qF "(synthetic seed)" "${showcase}"; then
  fail_msg "F-016: showcase still contains '(synthetic seed)' marker — should be replaced with real entries"
else
  ok
fi

# At least 3 entries (each starts with '### v1.')
entry_count="$(grep -cE "^### v1\." "${showcase}" || true)"
entry_count="${entry_count//[!0-9]/}"
entry_count="${entry_count:-0}"
if [[ "${entry_count}" -ge 3 ]]; then
  ok
else
  fail_msg "F-016: expected ≥3 versioned entries in showcase (got: ${entry_count})"
fi

# ----------------------------------------------------------------------
# F-017 — README links ohmyclaude.dev.
# ----------------------------------------------------------------------
printf '\n--- F-017: README links ohmyclaude.dev ---\n'

if grep -qF "ohmyclaude.dev" "${readme}"; then
  ok
else
  fail_msg "F-017: README missing ohmyclaude.dev link"
fi

# Specifically in the nav line (above the GIF) so visitors find it early.
nav_has_dev="$(awk '/^\*\*Jump to:\*\*/{print; exit}' "${readme}")"
if [[ "${nav_has_dev}" == *"ohmyclaude.dev"* ]]; then
  ok
else
  fail_msg "F-017: nav line should link ohmyclaude.dev (found: ${nav_has_dev})"
fi

# ----------------------------------------------------------------------
# F-018 — install.sh footer collapsed to single /ulw-demo CTA.
# ----------------------------------------------------------------------
printf '\n--- F-018: install footer single canonical CTA ---\n'

install_sh="${REPO_ROOT}/install.sh"

# Old format had "Then:\n  1. Verify... 2. Configure... 3. See gates... 4. Real work..."
# New format has "Then run /ulw-demo in the new Claude Code session"
if grep -qE "Then run /ulw-demo" "${install_sh}"; then
  ok
else
  fail_msg "F-018: install.sh footer missing single /ulw-demo CTA"
fi

# The 4-numbered-step format should be gone.
if grep -qE "1\. Verify the install:.*2\. Configure" "${install_sh}"; then
  fail_msg "F-018: install.sh still has the 4-step staircase format"
else
  ok
fi

# ----------------------------------------------------------------------
# F-019 — Post-restart welcome banner differentiates the session.
# ----------------------------------------------------------------------
printf '\n--- F-019: welcome banner has post-install differentiation ---\n'

welcome_sh="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-welcome.sh"
if grep -qE "You.*re now running oh-my-claude" "${welcome_sh}"; then
  ok
else
  fail_msg "F-019: welcome banner missing 'You're now running oh-my-claude vX.Y.Z' framing"
fi

if grep -qE "Claude Code reloaded the hooks" "${welcome_sh}"; then
  ok
else
  fail_msg "F-019: welcome banner should ack the hook reload (post-restart signal)"
fi

# ----------------------------------------------------------------------
printf '\n=== Wave 4 onboarding tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
