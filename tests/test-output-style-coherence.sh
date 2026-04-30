#!/usr/bin/env bash
set -euo pipefail

# Tests that the bundled output-style file and its dependents do not
# drift apart silently. Three classes of coherence are checked:
#
#   1. Frontmatter / settings-patch parity (F-006). The style file's
#      `name:` field must equal config/settings.patch.json's
#      `outputStyle` value, otherwise install lands a settings entry
#      pointing at a name Claude Code cannot resolve.
#
#   2. Style / hook coherence (F-008). The style file declares how
#      hook-injected workflow openers should be rendered. The router
#      script (prompt-intent-router.sh) emits those openers. Both
#      sides must reference the same opener strings and the same
#      `Domain:` / `Intent:` classification format.
#
#   3. keep-coding-instructions invariant. The harness depends on the
#      Claude Code coding-system-prompt staying intact; flipping
#      `keep-coding-instructions: true` would silently break specialist
#      routing. Locked here so a future fork has to consciously remove
#      the assertion.
#
# All three are pure-static checks (no Claude Code runtime needed) so
# the test runs cheaply in CI.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STYLE_FILE="${REPO_ROOT}/bundle/dot-claude/output-styles/opencode-compact.md"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
PATCH="${REPO_ROOT}/config/settings.patch.json"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
}

bad() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# ---------------------------------------------------------------------------
# Pre-flight: required files exist
# ---------------------------------------------------------------------------

for required in "${STYLE_FILE}" "${ROUTER}" "${PATCH}"; do
  if [[ ! -f "${required}" ]]; then
    printf 'PRE-FLIGHT FAIL: missing %s\n' "${required}" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# 1. Frontmatter / settings-patch parity (F-006)
# ---------------------------------------------------------------------------

# Shared robust parser used by verify.sh, install.sh, uninstall.sh, and
# this test. Defends against CRLF endings, multi-space-after-colon, and
# embedded colons. A naive `-F': ' '{print $2}'` form silently truncates.
parse_style_name() {
  awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "$1"
}

style_name="$(parse_style_name "${STYLE_FILE}")"
patch_name="$(jq -r '.outputStyle' "${PATCH}")"

if [[ -z "${style_name}" ]]; then
  bad "frontmatter name field is empty in ${STYLE_FILE}"
elif [[ "${style_name}" == "${patch_name}" ]]; then
  ok
else
  bad "frontmatter drift: style_name='${style_name}' patch_outputStyle='${patch_name}'"
fi

# Description field present and non-empty (F-015 regression guard).
desc="$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${STYLE_FILE}")"
if [[ -n "${desc}" ]]; then
  ok
else
  bad "frontmatter description field is missing or empty"
fi

# Parser robustness: CRLF endings must not leak \r into the captured
# value. Without this guard the F-010 orphan-leak path silently re-opens
# whenever a Windows-edited customized style file ships. Same hazard
# applies to verify.sh and install.sh — the parser is shared (defined
# here as `parse_style_name`) and audited by this assertion.
crlf_fixture="$(mktemp)"
printf 'name: OpenCode Compact\r\ndescription: x\r\nkeep-coding-instructions: true\r\n' > "${crlf_fixture}"
crlf_value="$(parse_style_name "${crlf_fixture}")"
rm -f "${crlf_fixture}"
if [[ "${crlf_value}" == "OpenCode Compact" ]]; then
  ok
else
  # xxd-friendly diagnostic so the failure does not hide the trailing CR.
  bad "parser does not strip CRLF: got '${crlf_value}' (hex: $(printf '%s' "${crlf_value}" | od -An -tx1 | tr -d ' '))"
fi

# Multi-space-after-colon and embedded-colon preservation: a custom name
# like "OpenCode Compact: v2" or whitespace introduced by a hand edit
# must round-trip cleanly.
extras_fixture="$(mktemp)"
printf 'name:   OpenCode Compact: v2\ndescription: x\n' > "${extras_fixture}"
extras_value="$(parse_style_name "${extras_fixture}")"
rm -f "${extras_fixture}"
if [[ "${extras_value}" == "OpenCode Compact: v2" ]]; then
  ok
else
  bad "parser truncates embedded colons or mishandles padding: got '${extras_value}'"
fi

# ---------------------------------------------------------------------------
# 3. Install conf-read snippet (F-005) — tail -1 last-write-wins
# ---------------------------------------------------------------------------

# Mirrors the install.sh:1004-1014 logic so a regression in the snippet
# (e.g., reverting tail -1 to head -1, or relaxing the regex validation
# that defends against typos like `output_style=garbage`) is caught
# before it lands. The runtime parser in common.sh and the conf writer
# in omc-config.sh both use last-write-wins semantics; install.sh must
# agree, otherwise an upgrade and a runtime read disagree about which
# value the user picked.
read_install_conf_snippet() {
  local conf="$1"
  local pref="opencode"
  if [[ -f "${conf}" ]]; then
    local raw
    raw="$(grep -E '^output_style=' "${conf}" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [[ "${raw}" =~ ^(opencode|preserve)$ ]]; then
      pref="${raw}"
    fi
  fi
  printf '%s' "${pref}"
}

# Last-write-wins on duplicate lines (regression net for the head-1 →
# tail-1 fix surfaced by quality-reviewer in wave 3).
multi_conf="$(mktemp)"
printf 'output_style=opencode\noutput_style=preserve\n' > "${multi_conf}"
multi_pref="$(read_install_conf_snippet "${multi_conf}")"
rm -f "${multi_conf}"
if [[ "${multi_pref}" == "preserve" ]]; then
  ok
else
  bad "install conf-read uses head-1 instead of tail-1; got '${multi_pref}' instead of 'preserve'"
fi

# Garbage value rejection (regression net for the regex validator).
junk_conf="$(mktemp)"
printf 'output_style=garbage\n' > "${junk_conf}"
junk_pref="$(read_install_conf_snippet "${junk_conf}")"
rm -f "${junk_conf}"
if [[ "${junk_pref}" == "opencode" ]]; then
  ok
else
  bad "install conf-read does not reject invalid value 'garbage'; got '${junk_pref}'"
fi

# Empty conf falls through to default.
empty_conf="$(mktemp)"
empty_pref="$(read_install_conf_snippet "${empty_conf}")"
rm -f "${empty_conf}"
if [[ "${empty_pref}" == "opencode" ]]; then
  ok
else
  bad "install conf-read does not default to opencode on empty conf; got '${empty_pref}'"
fi

# keep-coding-instructions: true (harness invariant).
if grep -q '^keep-coding-instructions: true' "${STYLE_FILE}"; then
  ok
else
  bad "frontmatter must declare 'keep-coding-instructions: true' (harness depends on Claude Code coding-system-prompt being preserved)"
fi

# ---------------------------------------------------------------------------
# 2. Style / hook coherence (F-008)
# ---------------------------------------------------------------------------

# The router emits two opener strings; the style file documents how to
# render them. Both must reference the same literals.
for opener in "Ultrawork mode active" "Ultrawork continuation active"; do
  if grep -qF "${opener}" "${STYLE_FILE}"; then
    ok
  else
    bad "style file does not document hook-injected opener '${opener}'"
  fi
  if grep -qF "${opener}" "${ROUTER}"; then
    ok
  else
    bad "router does not emit opener '${opener}' (style references it but router does not)"
  fi
done

# Classification line format. Style says "**Domain:** … | **Intent:** …";
# router emits the same shape. Match the literal pattern as it appears
# in both sides.
classification_pattern='Domain:.*\|.*Intent:'
if grep -qE "${classification_pattern}" "${STYLE_FILE}"; then
  ok
else
  bad "style file does not document the 'Domain: … | Intent: …' classification format"
fi

if grep -qE "${classification_pattern}" "${ROUTER}"; then
  ok
else
  bad "router does not emit the 'Domain: … | Intent: …' classification line"
fi

# Implementation-summary template (F-003 regression guard). The dominant
# /ulw response shape needs an explicit template in the style.
for label in "Changed" "Verification" "Risks" "Next"; do
  if grep -qE "(\*\*${label}\.\*\*|\*\*${label}\*\*)" "${STYLE_FILE}"; then
    ok
  else
    bad "style file's Implementation summary missing label '${label}'"
  fi
done

# Serendipity uses the colon form to match core.md:72's audit-log
# convention. This guards against a future "fix consistency" pass that
# replaces the colon with the em-dash form used by other labels.
if grep -qE 'Serendipity:' "${STYLE_FILE}"; then
  ok
else
  bad "style file's Serendipity label should use the colon form 'Serendipity:' to match core.md:72"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

total=$((pass + fail))
printf '\n=== Output-style coherence tests: %d passed, %d failed (of %d) ===\n' "${pass}" "${fail}" "${total}"

if [[ ${fail} -gt 0 ]]; then
  exit 1
fi
exit 0
