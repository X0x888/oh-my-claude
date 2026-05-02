#!/usr/bin/env bash
# test-no-broken-stat-chain.sh — Regression net for the v1.28.0 hotfix.
#
# Bans inline BSD-first `stat -f ... || stat -c ...` chains in single
# command substitutions or single pipelines. On Linux, GNU `stat -f`
# means `--file-system` (not "format"), so the format spec (e.g. `%m`)
# is treated as another file argument; the named target file IS valid,
# so stdout gets the multi-line filesystem-info block before the `||`
# runs `stat -c %Y` and appends the mtime number. The captured value
# then contains literal `File:`, breaking downstream arithmetic with
# `set -u` triggering on `File: unbound variable`.
#
# Safe patterns (NOT flagged):
#   1. Linux-first inline:    stat -c %Y FILE || stat -f %m FILE
#   2. Separate assignments:  var="$(stat -f ...)" || var="$(stat -c ...)"
#      (each assignment overwrites stdout cleanly across the ||)
#
# Broken pattern (FLAGGED):
#   var="$(stat -f X FILE 2>/dev/null || stat -c Y FILE 2>/dev/null)"
#   stat -f X FILE || stat -c Y FILE   (function body, single pipeline)
#   xargs stat -f ... || find ... -printf ...
#
# This test greps repository sources for the broken shape and fails
# CI if any occurrence appears. It is intentionally lenient — it only
# checks for `stat -f` literally followed by `||` then `stat -c` on
# the same OR adjacent lines (line continuation).

set -euo pipefail

TEST_NAME="test-no-broken-stat-chain.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

printf '%s\n' "================================================================================"
printf '%s\n' "${TEST_NAME}"
printf '%s\n' "================================================================================"

PASS=0
FAIL=0

# Allowlist: paths that LEGITIMATELY contain `stat -f`-then-`stat -c`
# patterns. Two reasons a path may be allowlisted:
#   (1) Documentation/comments only (this test is one of them).
#   (2) Separate-assignment pattern (each `||` operand is its OWN
#       assignment statement: `var="$(stat -f ...)" || var="$(stat -c ...)"`)
#       — each assignment overwrites stdout cleanly across the ||,
#       so the multi-line stat dump never accumulates. Verified safe.
#
# Pattern adds for separate-assignment sites (manually verified):
#   bundle/dot-claude/omc-repro.sh:128-129  (mtime = ... || mtime = ...)
#   bundle/dot-claude/skills/autowork/scripts/lib/state-io.sh:241-243  (ts = ... || ts = "")
ALLOWLIST_REGEX='/tests/test-no-broken-stat-chain\.sh:|/bundle/dot-claude/omc-repro\.sh:128|/bundle/dot-claude/skills/autowork/scripts/lib/state-io\.sh:24[123]'

scan_dir() {
  local dir="$1"
  local label="$2"
  local matches
  # Find inline BSD-first chains. The pattern: `stat -f` followed by
  # `||` followed by `stat -c` on the same logical line. We accept
  # line continuations by collapsing backslash-newlines first via awk
  # then grepping, but for simplicity scan line-by-line first (catches
  # the bulk of the pattern) and warn if any context lines suggest a
  # multi-line continuation.
  matches="$(grep -rnE 'stat -f[^|]*\|\|.*stat -c' "${dir}" 2>/dev/null \
    | grep -vE "${ALLOWLIST_REGEX}" \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
    || true)"

  if [[ -z "${matches}" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: no inline BSD-first stat chains in %s\n' "${label}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: inline BSD-first `stat -f ... || stat -c` chains in %s:\n' "${label}"
    printf '%s\n' "${matches}" | sed 's/^/    /'
    printf '  Fix: swap order — Linux GNU `stat -c` first, BSD `stat -f` fallback.\n'
    printf '       See bundle/dot-claude/skills/autowork/scripts/blindspot-inventory.sh:616\n'
    printf '       for the canonical fix shape.\n'
  fi
}

scan_dir "${REPO_ROOT}/bundle" "bundle/"
scan_dir "${REPO_ROOT}/tests" "tests/"

# Multi-line continuation check: flag function bodies / pipelines where
# `stat -f` and `stat -c` span adjacent lines via `\`. Uses per-file FNR
# so line numbers are correct AND cross-file state is reset (FNR == 1).
scan_multiline() {
  local dir="$1"
  local label="$2"
  local matches
  local -a files_arr=()
  # Collect candidate files into an array to avoid empty-arg pitfalls
  # when no .sh files exist under dir. `mapfile` is bash 4+; this
  # while-read form is bash 3.2 (macOS) compatible.
  while IFS= read -r f; do
    files_arr+=("${f}")
  done < <(find "${dir}" -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null)
  if [[ "${#files_arr[@]}" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: no multi-line BSD-first stat chains in %s (no .sh files)\n' "${label}"
    return
  fi
  matches="$(awk '
    FNR == 1 { f_seen = 0; f_line = 0; f_file = "" }
    /stat -f/ && !/^[[:space:]]*#/ { f_line=FNR; f_file=FILENAME; f_seen=1; next }
    f_seen && /stat -c/ && !/^[[:space:]]*#/ {
      if (FNR - f_line <= 3) {
        print f_file ":" f_line "-" FNR ": multi-line BSD-first stat chain"
      }
      f_seen=0
    }
    /^[^|]*$/ && !/\\$/ { f_seen=0 }
  ' "${files_arr[@]}" 2>/dev/null \
    | grep -vE "${ALLOWLIST_REGEX}" || true)"

  if [[ -z "${matches}" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: no multi-line BSD-first stat chains in %s\n' "${label}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: multi-line BSD-first stat chains in %s:\n' "${label}"
    printf '%s\n' "${matches}" | sed 's/^/    /'
  fi
}

scan_multiline "${REPO_ROOT}/bundle" "bundle/"
scan_multiline "${REPO_ROOT}/tests" "tests/"

printf '\n%s\n' "--------------------------------------------------------------------------------"
printf 'Results: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '%s\n' "--------------------------------------------------------------------------------"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
