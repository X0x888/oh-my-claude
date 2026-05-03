#!/usr/bin/env bash
set -euo pipefail

# Tests that the bundled output-style files and their dependents do not
# drift apart silently. Three classes of coherence are checked:
#
#   1. Frontmatter / settings-patch parity (F-006). Exactly one bundled
#      style file's `name:` field must equal config/settings.patch.json's
#      `outputStyle` value (the active patch style). The other bundled
#      style files are still validated for frontmatter integrity, but they
#      are opt-in alternatives selected via `output_style=<value>` in
#      ~/.claude/oh-my-claude.conf, not the install-time default.
#
#   2. Style / hook coherence (F-008). Each style file declares how
#      hook-injected workflow openers should be rendered. The router
#      script (prompt-intent-router.sh) emits those openers. Every
#      bundled style must reference the same opener strings and the same
#      `Domain:` / `Intent:` classification format.
#
#   3. keep-coding-instructions invariant. The harness depends on the
#      Claude Code coding-system-prompt staying intact; flipping
#      `keep-coding-instructions: true` would silently break specialist
#      routing. Locked here so a future fork has to consciously remove
#      the assertion. Applied to every bundled style.
#
# All three are pure-static checks (no Claude Code runtime needed) so
# the test runs cheaply in CI.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STYLES_DIR="${REPO_ROOT}/bundle/dot-claude/output-styles"
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

for required in "${STYLES_DIR}" "${ROUTER}" "${PATCH}"; do
  if [[ ! -e "${required}" ]]; then
    printf 'PRE-FLIGHT FAIL: missing %s\n' "${required}" >&2
    exit 2
  fi
done

# Discover bundled style files. Sort for deterministic iteration order so
# CI output is stable across runs and the failure messages are predictable
# when reading logs. `mapfile` would be cleaner but is bash 4+; the
# while-read loop matches the project's bash 3.2 portability rule
# (project_v1_28_linux_portability_lessons memory).
STYLE_FILES=()
while IFS= read -r _line; do
  [[ -n "${_line}" ]] && STYLE_FILES+=("${_line}")
done < <(find "${STYLES_DIR}" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)

if [[ ${#STYLE_FILES[@]} -eq 0 ]]; then
  printf 'PRE-FLIGHT FAIL: no bundled style files found under %s\n' "${STYLES_DIR}" >&2
  exit 2
fi

# Two bundled styles ship today: oh-my-claude (default, active patch
# style) and executive-brief (CEO-style status report, opt-in via
# `output_style=executive`). If a future release adds a third, this
# floor catches accidental file removal.
if [[ ${#STYLE_FILES[@]} -lt 2 ]]; then
  bad "expected at least 2 bundled style files in ${STYLES_DIR}; found ${#STYLE_FILES[@]}"
fi

# Shared robust parser used by verify.sh, install.sh, uninstall.sh, and
# this test. Defends against CRLF endings, multi-space-after-colon, and
# embedded colons. A naive `-F': ' '{print $2}'` form silently truncates.
parse_style_name() {
  awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "$1"
}

# ---------------------------------------------------------------------------
# 1. Frontmatter / settings-patch parity (F-006) — active patch style only
# ---------------------------------------------------------------------------

patch_name="$(jq -r '.outputStyle' "${PATCH}")"
matched_patch_style=""
for sf in "${STYLE_FILES[@]}"; do
  sn="$(parse_style_name "${sf}")"
  if [[ "${sn}" == "${patch_name}" ]]; then
    matched_patch_style="${sf}"
    break
  fi
done

if [[ -n "${matched_patch_style}" ]]; then
  ok
else
  styles_summary=""
  for sf in "${STYLE_FILES[@]}"; do
    styles_summary+="$(basename "${sf}"):$(parse_style_name "${sf}") "
  done
  bad "no bundled style frontmatter matches config/settings.patch.json's outputStyle='${patch_name}' (bundled styles: ${styles_summary})"
fi

# Parser robustness: CRLF endings must not leak \r into the captured
# value. Without this guard the F-010 orphan-leak path silently re-opens
# whenever a Windows-edited customized style file ships. Same hazard
# applies to verify.sh and install.sh — the parser is shared (defined
# here as `parse_style_name`) and audited by this assertion.
crlf_fixture="$(mktemp)"
printf 'name: oh-my-claude\r\ndescription: x\r\nkeep-coding-instructions: true\r\n' > "${crlf_fixture}"
crlf_value="$(parse_style_name "${crlf_fixture}")"
rm -f "${crlf_fixture}"
if [[ "${crlf_value}" == "oh-my-claude" ]]; then
  ok
else
  bad "parser does not strip CRLF: got '${crlf_value}' (hex: $(printf '%s' "${crlf_value}" | od -An -tx1 | tr -d ' '))"
fi

# Multi-space-after-colon and embedded-colon preservation: a custom name
# like "oh-my-claude: v2" or whitespace introduced by a hand edit
# must round-trip cleanly.
extras_fixture="$(mktemp)"
printf 'name:   oh-my-claude: v2\ndescription: x\n' > "${extras_fixture}"
extras_value="$(parse_style_name "${extras_fixture}")"
rm -f "${extras_fixture}"
if [[ "${extras_value}" == "oh-my-claude: v2" ]]; then
  ok
else
  bad "parser truncates embedded colons or mishandles padding: got '${extras_value}'"
fi

# Per-style frontmatter integrity. Description non-empty (F-015 regression
# guard) and keep-coding-instructions: true (harness invariant). Applied to
# EVERY bundled style file — both the active patch style and any opt-in
# alternatives — because a corrupted alternative would silently break a
# user who switched their conf flag to point at it.
for sf in "${STYLE_FILES[@]}"; do
  sf_basename="$(basename "${sf}")"

  sf_name="$(parse_style_name "${sf}")"
  if [[ -n "${sf_name}" ]]; then
    ok
  else
    bad "frontmatter name field is empty in ${sf_basename}"
  fi

  sf_desc="$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${sf}")"
  if [[ -n "${sf_desc}" ]]; then
    ok
  else
    bad "frontmatter description field is missing or empty in ${sf_basename}"
  fi

  if grep -q '^keep-coding-instructions: true' "${sf}"; then
    ok
  else
    bad "${sf_basename}: frontmatter must declare 'keep-coding-instructions: true' (harness depends on Claude Code coding-system-prompt being preserved)"
  fi
done

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
    if [[ "${raw}" =~ ^(opencode|executive|preserve)$ ]]; then
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

# Last-write-wins also exercised across all three legal values (regression
# net for the executive enum addition — head-1 in older code would lock
# users into 'opencode' even after they switched to 'executive').
multi_conf_exec="$(mktemp)"
printf 'output_style=opencode\noutput_style=executive\n' > "${multi_conf_exec}"
multi_pref_exec="$(read_install_conf_snippet "${multi_conf_exec}")"
rm -f "${multi_conf_exec}"
if [[ "${multi_pref_exec}" == "executive" ]]; then
  ok
else
  bad "install conf-read does not honor 'executive' enum value; got '${multi_pref_exec}' instead of 'executive'"
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

# ---------------------------------------------------------------------------
# 2. Style / hook coherence (F-008) — every bundled style
# ---------------------------------------------------------------------------

# The router emits two opener strings; every style file documents how to
# render them. Both must reference the same literals.
for opener in "Ultrawork mode active" "Ultrawork continuation active"; do
  if grep -qF "${opener}" "${ROUTER}"; then
    ok
  else
    bad "router does not emit opener '${opener}'"
  fi
  for sf in "${STYLE_FILES[@]}"; do
    sf_basename="$(basename "${sf}")"
    if grep -qF "${opener}" "${sf}"; then
      ok
    else
      bad "${sf_basename} does not document hook-injected opener '${opener}'"
    fi
  done
done

# Classification line format. Each style says "**Domain:** … | **Intent:** …";
# router emits the same shape. Match the literal pattern as it appears
# in both sides.
classification_pattern='Domain:.*\|.*Intent:'
if grep -qE "${classification_pattern}" "${ROUTER}"; then
  ok
else
  bad "router does not emit the 'Domain: … | Intent: …' classification line"
fi
for sf in "${STYLE_FILES[@]}"; do
  sf_basename="$(basename "${sf}")"
  if grep -qE "${classification_pattern}" "${sf}"; then
    ok
  else
    bad "${sf_basename} does not document the 'Domain: … | Intent: …' classification format"
  fi
done

# Implementation-summary template (F-003 regression guard). The dominant
# /ulw response shape needs an explicit template in every bundled style.
# The "what changed" bucket has two synonyms across styles:
#   oh-my-claude  → `**Changed.**`  (implementation framing)
#   executive-brief → `**Shipped.**` (delivery framing)
# Both are accepted; the test fails only if NEITHER appears in a style.
# The remaining buckets (Verification, Risks, Next) have no synonyms
# because their semantics are universal across briefing shapes.
for sf in "${STYLE_FILES[@]}"; do
  sf_basename="$(basename "${sf}")"

  if grep -qE '(\*\*Changed\.\*\*|\*\*Changed\*\*|\*\*Shipped\.\*\*|\*\*Shipped\*\*)' "${sf}"; then
    ok
  else
    bad "${sf_basename}: Implementation summary missing the change-bucket label (expected '**Changed.**' or '**Shipped.**')"
  fi

  for label in "Verification" "Risks" "Next"; do
    if grep -qE "(\*\*${label}\.\*\*|\*\*${label}\*\*)" "${sf}"; then
      ok
    else
      bad "${sf_basename}: Implementation summary missing label '${label}'"
    fi
  done
done

# Serendipity uses the colon form to match core.md:72's audit-log
# convention. This guards against a future "fix consistency" pass that
# replaces the colon with the em-dash form used by other labels.
for sf in "${STYLE_FILES[@]}"; do
  sf_basename="$(basename "${sf}")"
  if grep -qE 'Serendipity:' "${sf}"; then
    ok
  else
    bad "${sf_basename}: Serendipity label should use the colon form 'Serendipity:' to match core.md:72"
  fi
done

# ---------------------------------------------------------------------------
# 4. Bundled enum coverage (executive-brief addition)
# ---------------------------------------------------------------------------

# The output_style conf flag must accept all three legal values, and
# common.sh's parser must agree with install.sh's regex. A drift here
# would let users set `output_style=executive` in their conf only to
# have it silently ignored at install time (or vice versa).
PARSER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
OMC_CONFIG="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"

# common.sh parser regex must match all three legal values.
if grep -qE 'output_style\)' "${PARSER}" && \
   grep -qE '\^\(opencode\|executive\|preserve\)\$' "${PARSER}"; then
  ok
else
  bad "common.sh output_style parser regex is missing the executive enum value or has drifted"
fi

# omc-config.sh enum table must list all three.
if grep -qE '^output_style\|enum:opencode/executive/preserve\|' "${OMC_CONFIG}"; then
  ok
else
  bad "omc-config.sh output_style enum table is missing the executive value or has drifted"
fi

# install.sh's conf-read regex must match all three (in the snippet that
# reads ~/.claude/oh-my-claude.conf at upgrade time — independent of the
# parser in common.sh).
INSTALL_SH="${REPO_ROOT}/install.sh"
if grep -qE '\^\(opencode\|executive\|preserve\)\$' "${INSTALL_SH}"; then
  ok
else
  bad "install.sh conf-read regex is missing the executive enum value"
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
