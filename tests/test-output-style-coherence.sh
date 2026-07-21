#!/usr/bin/env bash
set -euo pipefail

# Tests that the bundled output-style files and their dependents do not
# drift apart silently. Four classes of coherence are checked:
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
#   4. Structural WAIT parity. Every bundled style must end a verified
#      live-work wait with the exact final line consumed by stop-dispatch,
#      including automatic wake and no-user-action signals.
#
# All four are pure-static checks (no Claude Code runtime needed) so
# the test runs cheaply in CI.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STYLES_DIR="${REPO_ROOT}/bundle/dot-claude/output-styles"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
PATCH="${REPO_ROOT}/config/settings.patch.json"
STOP_DISPATCH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-dispatch.sh"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

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

for required in "${STYLES_DIR}" "${ROUTER}" "${PATCH}" \
    "${STOP_DISPATCH}" "${COMMON}"; do
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

# Structural WAIT contract. A live-reviewer wait is recognized only from the
# final non-empty assistant line, and only when it promises the registered
# completion wake plus no required user action. Keep every bundled style on
# the exact same line so switching presentation cannot accidentally turn a
# nonterminal live wait into completion prose.
canonical_wait_line='⏳ **Waiting on `<what>`** — running in the background; I'"'"'ll resume automatically when it finishes. Nothing for you to do.'
for sf in "${STYLE_FILES[@]}"; do
  sf_basename="$(basename "${sf}")"
  documented_wait_line="$(grep -F '⏳ **Waiting on `<what>`**' "${sf}" || true)"
  if [[ "${documented_wait_line}" == "${canonical_wait_line}" ]]; then
    ok
  else
    bad "${sf_basename}: live-work WAIT line must exactly match the stop-dispatch structural contract"
  fi

  if grep -Fqi 'task registry reports' "${sf}" \
      && grep -Fqi 'registered completion notification' "${sf}" \
      && grep -Fqi 'end with this exact plain' "${sf}" \
      && grep -Fqi 'unquoted line' "${sf}"; then
    ok
  else
    bad "${sf_basename}: WAIT guidance must require a live registry, completion notification, and an exact unquoted final line"
  fi
done

# Static consumer lock: stop-dispatch must continue reducing the response to
# its final non-empty line before invoking the shared classifier, and the
# classifier must retain all three canonical signals. This is deliberately a
# source-contract check; the behavioral wait/dead-wait matrix lives in
# test-stop-dispatch.sh.
if grep -qF '_wait_claim_line="$(_stop_wait_final_line' "${STOP_DISPATCH}" \
    && grep -qF '_wait_claim_kind="$(omc_stop_wait_claim_kind' "${STOP_DISPATCH}"; then
  ok
else
  bad "stop-dispatch no longer classifies only the structural final wait line"
fi
wait_classifier_source="$(awk '
  /^omc_stop_wait_claim_kind\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "${COMMON}")"
if [[ "${wait_classifier_source}" == *'"waiting"'* ]] \
    && [[ "${wait_classifier_source}" == *'"resume automatically"'* ]] \
    && [[ "${wait_classifier_source}" == *'"nothing for you to do"'* ]]; then
  ok
else
  bad "shared Stop wait classifier drifted from waiting + automatic-resume + no-user-action signals"
fi

# ---------------------------------------------------------------------------
# 3. Install conf-read snippet (F-005) — typed last-valid precedence
# ---------------------------------------------------------------------------

# Mirrors install.sh: a strict canonical environment value wins; otherwise
# the last valid, whitespace-trimmed conf row wins; otherwise use opencode.
# Malformed later rows cannot erase a prior valid user choice.
read_install_conf_snippet() {
  local conf="$1"
  local env_value="${2:-}"
  local requested="${3:-preference}"
  local pref="opencode"
  local explicit=0
  local line="" raw=""
  if [[ "${env_value}" =~ ^(opencode|executive|preserve)$ ]]; then
    pref="${env_value}"
    explicit=1
  elif [[ -f "${conf}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == "output_style="* ]] || continue
      raw="${line#*=}"
      raw="${raw#"${raw%%[![:space:]]*}"}"
      raw="${raw%"${raw##*[![:space:]]}"}"
      case "${raw}" in
        opencode|executive|preserve)
          pref="${raw}"
          explicit=1
          ;;
      esac
    done < "${conf}"
  fi
  if [[ "${requested}" == "explicit" ]]; then
    printf '%s' "${explicit}"
  else
    printf '%s' "${pref}"
  fi
}

# Last-valid-row wins on duplicate lines.
multi_conf="$(mktemp)"
printf 'output_style=opencode\noutput_style=preserve\n' > "${multi_conf}"
multi_pref="$(read_install_conf_snippet "${multi_conf}")"
rm -f "${multi_conf}"
if [[ "${multi_pref}" == "preserve" ]]; then
  ok
else
  bad "install conf-read uses head-1 instead of tail-1; got '${multi_pref}' instead of 'preserve'"
fi

# Last-valid-row also exercised across all three legal values (regression
# net for the executive enum addition — first-row logic would lock
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

invalid_newest_conf="$(mktemp)"
printf 'output_style=preserve\noutput_style=garbage\n' \
  > "${invalid_newest_conf}"
invalid_newest_pref="$(read_install_conf_snippet "${invalid_newest_conf}")"
rm -f "${invalid_newest_conf}"
if [[ "${invalid_newest_pref}" == "preserve" ]]; then
  ok
else
  bad "invalid newest output_style erased prior valid preserve choice"
fi
padded_env_conf="$(mktemp)"
printf 'output_style=executive\n' > "${padded_env_conf}"
padded_env_pref="$(read_install_conf_snippet "${padded_env_conf}" ' preserve ')"
rm -f "${padded_env_conf}"
if [[ "${padded_env_pref}" == "executive" ]]; then
  ok
else
  bad "whitespace-padded output-style env incorrectly shadowed saved executive choice"
fi

explicit_conf="$(mktemp)"
printf 'output_style=executive\noutput_style=garbage\n' > "${explicit_conf}"
if [[ "$(read_install_conf_snippet "${explicit_conf}" '' explicit)" == "1" ]] \
    && [[ "$(read_install_conf_snippet "${explicit_conf}" executive explicit)" == "1" ]]; then
  ok
else
  bad "valid output-style env/conf authority was not marked explicit"
fi
rm -f "${explicit_conf}"

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
empty_conf="$(mktemp)"
if [[ "$(read_install_conf_snippet "${empty_conf}" '' explicit)" == "0" ]]; then
  ok
else
  bad "implicit output-style default was incorrectly marked explicit"
fi
rm -f "${empty_conf}"

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

  if grep -qF 'OMC INTERNAL CLOSEOUT PREFLIGHT: READY' "${sf}" \
      && grep -Eiq 'self-contained cumulative replacement' "${sf}" \
      && grep -Eiq 'never a (thin )?delta' "${sf}"; then
    ok
  else
    bad "${sf_basename}: closeout must wait for READY and be one cumulative replacement, never a retry delta"
  fi
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
PARSER="${COMMON}"
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

# install.sh's typed conf resolver must list all three values and publish the
# explicit-authority bit consumed by both merge implementations.
INSTALL_SH="${REPO_ROOT}/install.sh"
if grep -Fq 'opencode|executive|preserve) _pref_from_conf=' "${INSTALL_SH}" \
    && grep -q 'OMC_OUTPUT_STYLE_PREF_EXPLICIT' "${INSTALL_SH}" \
    && [[ "$(grep -c 'output_style_pref_explicit' "${INSTALL_SH}")" -ge 3 ]]; then
  ok
else
  bad "install.sh typed output-style resolver/explicit merge contract drifted"
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
