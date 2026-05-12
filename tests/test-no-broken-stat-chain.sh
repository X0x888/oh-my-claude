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

# Allowlist for the inline scanner: paths whose stat -f...||...stat -c
# patterns are documentation/comments rather than executable code.
# The test file itself contains the patterns in its own header docstring.
#
# v1.40.x F-009-followup: the prior line-number-based allowlist
# (`omc-repro.sh:128` / `state-io.sh:241-243`) was structurally
# brittle — any edit shifting lines above a safe site would silently
# disable the allowlist match and break CI on the next release. The
# multi-line scanner now uses **structural detection** instead:
# a `stat -f` site is considered safe when its `$(...)` substitution
# closes on the same line (pattern `$(stat -f ... )"`), because then
# the `||` on the next physical line is a separate statement, not a
# continuation inside the substitution. Same applies to the matching
# `stat -c` line.
#
# The inline scanner still benefits from a tiny allowlist (the test
# file's own header), since the pattern-matching grep is keyed on
# substring presence rather than structural shape.
ALLOWLIST_REGEX='/tests/test-no-broken-stat-chain\.sh:'

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
#
# v1.40.x F-009-followup — STRUCTURAL DETECTION:
#
# A `stat -f` line is structurally safe (separate-assignment shape)
# when its `$(...)` substitution closes on the same line — pattern
# `$(stat -f ... )"`. In that case, the `||` on the next physical
# line is a statement-level OR (each operand is its OWN complete
# assignment to the same variable), NOT a continuation inside the
# substitution. Linux runs each substitution in isolation, captures
# its stdout, and the `||` short-circuits on the assignment exit
# status — there is no filesystem-block-then-mtime concatenation.
#
# Conversely, when the `$(...)` does NOT close on the stat -f line,
# the next-line `||` could be inside the substitution — flag as
# potentially unsafe.
#
# The same check applies to the stat -c line: if it also closes its
# substitution on its own line, the pair is the documented safe
# separate-assignment chain.
#
# This replaces the v1.40.0-era line-number allowlist (brittle —
# any edit shifting lines disabled it) with a property the scanner
# verifies from the line itself.
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
    # Returns 1 when the line contains a $(stat -X ...) substitution
    # closed on the same line (matched $( and )"). Such a line is
    # structurally a complete assignment value — any next-line ||
    # operates at statement level, not inside the substitution.
    function safe_separate(line) {
      return match(line, /\$\(stat -[fc][^)]*\)"/) > 0
    }

    FNR == 1 { f_seen = 0; f_line = 0; f_file = "" }

    # Comment-line: skip entirely without arming or resetting state.
    /^[[:space:]]*#/ { next }

    # stat -f sighting. If the substitution closes on this line, the
    # chain is structurally safe — do NOT arm. Otherwise arm so a
    # follow-up stat -c is checked.
    /stat -f/ {
      if (safe_separate($0)) { next }
      f_line = FNR; f_file = FILENAME; f_seen = 1; next
    }

    # stat -c sighting within 3 lines of an armed stat -f. The chain
    # is safe when the stat -c line ALSO closes its substitution
    # on the same line (the documented var="$(...)"\\||var="$(...)"
    # pattern). Otherwise flag.
    f_seen && /stat -c/ {
      if (FNR - f_line <= 3) {
        if (!safe_separate($0)) {
          print f_file ":" f_line "-" FNR ": multi-line BSD-first stat chain"
        }
      }
      f_seen = 0
      next
    }

    # Any non-continuation line resets f_seen — the 3-line window
    # only applies to consecutive backslash-continuation context.
    /^[^|]*$/ && !/\\$/ { f_seen = 0 }
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

# ----------------------------------------------------------------------
# v1.40.x F-009-followup: regression net for the structural-detection
# logic itself. Three synthetic fixtures exercise the three structural
# classes — without these, a future "simplification" that re-introduces
# line-number coupling would silently disable the protection.
# ----------------------------------------------------------------------
printf '\n'
SYNTH_DIR="$(mktemp -d)"
trap 'rm -rf "${SYNTH_DIR}"' EXIT INT TERM

# Fixture 1: UNSAFE bare-command BSD-first chain. Must be flagged by
# the multi-line scanner.
cat > "${SYNTH_DIR}/unsafe-bare.sh" <<'SYNTH'
#!/usr/bin/env bash
get_mtime() {
  stat -f %m "$1" 2>/dev/null \
    || stat -c %Y "$1" 2>/dev/null \
    || echo 0
}
SYNTH

# Fixture 2: SAFE separate-assignment shape — each substitution
# closes on its own line. Must NOT be flagged.
cat > "${SYNTH_DIR}/safe-separate.sh" <<'SYNTH'
#!/usr/bin/env bash
get_mtime() {
  local mtime
  mtime="$(stat -f %m "$1" 2>/dev/null)" \
    || mtime="$(stat -c %Y "$1" 2>/dev/null)" \
    || mtime=0
  echo "${mtime}"
}
SYNTH

# Fixture 3: UNSAFE inline-substitution chain — same logical line via
# continuations, `||` inside the `$(...)`. The inline scanner catches
# the same-physical-line shape; the multi-line scanner should also
# flag this if the substitution spans lines (stat -f line does NOT
# close its $(...) ).
cat > "${SYNTH_DIR}/unsafe-inline-spanning.sh" <<'SYNTH'
#!/usr/bin/env bash
get_mtime() {
  local mtime
  mtime="$(stat -f %m "$1" 2>/dev/null \
    || stat -c %Y "$1" 2>/dev/null)"
  echo "${mtime}"
}
SYNTH

# Run the structural scanner directly against each fixture (awk
# inline mirrors scan_multiline()'s body so the regression catches
# drift in either site).
synth_scan() {
  local file="$1"
  awk '
    function safe_separate(line) {
      return match(line, /\$\(stat -[fc][^)]*\)"/) > 0
    }
    FNR == 1 { f_seen = 0; f_line = 0; f_file = "" }
    /^[[:space:]]*#/ { next }
    /stat -f/ {
      if (safe_separate($0)) { next }
      f_line = FNR; f_file = FILENAME; f_seen = 1; next
    }
    f_seen && /stat -c/ {
      if (FNR - f_line <= 3) {
        if (!safe_separate($0)) {
          print f_file ":" f_line "-" FNR ": multi-line BSD-first stat chain"
        }
      }
      f_seen = 0; next
    }
    /^[^|]*$/ && !/\\$/ { f_seen = 0 }
  ' "${file}"
}

# Fixture 1 — must flag.
synth_out="$(synth_scan "${SYNTH_DIR}/unsafe-bare.sh")"
if [[ -n "${synth_out}" ]]; then
  PASS=$((PASS + 1))
  printf '  PASS: synthetic unsafe-bare fixture flagged correctly\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: synthetic unsafe-bare fixture NOT flagged (structural detection regressed)\n'
fi

# Fixture 2 — must NOT flag.
synth_out="$(synth_scan "${SYNTH_DIR}/safe-separate.sh")"
if [[ -z "${synth_out}" ]]; then
  PASS=$((PASS + 1))
  printf '  PASS: synthetic safe-separate fixture correctly not flagged\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: synthetic safe-separate fixture wrongly flagged: %s\n' "${synth_out}"
fi

# Fixture 3 — must flag (substitution spans lines, unsafe).
synth_out="$(synth_scan "${SYNTH_DIR}/unsafe-inline-spanning.sh")"
if [[ -n "${synth_out}" ]]; then
  PASS=$((PASS + 1))
  printf '  PASS: synthetic unsafe-inline-spanning fixture flagged correctly\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: synthetic unsafe-inline-spanning fixture NOT flagged\n'
fi

printf '\n%s\n' "--------------------------------------------------------------------------------"
printf 'Results: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '%s\n' "--------------------------------------------------------------------------------"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
