#!/usr/bin/env bash
#
# Tests for the v1.30.0 install.sh "What's new" block — the awk
# extraction that surfaces CHANGELOG version headings between
# PRIOR_INSTALLED_VERSION and OMC_VERSION on every install where the
# version actually changed.
#
# Closes the v1.29.0 product-lens P2-10 / growth-lens P2-10 deferred
# item: users running `git pull && bash install.sh` previously had
# zero in-context awareness of what changed; the CHANGELOG.md was the
# only source and most users skipped it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Run the awk extraction in isolation. Mirrors install.sh's NEW
# collapsed default (v1.36.0+, item #6): same-X.Y patches roll up into
# one summary line `- X.Y.x  (N entries — range X.Y.0 → X.Y.N)`. Single-
# entry minors render in full as before. Cap is now 40 unique MINORS
# (previously 40 individual entries).
extract_whats_new() {
  local prev="$1"
  local curr="$2"
  local changelog="${3:-${REPO_ROOT}/CHANGELOG.md}"
  awk -v prev="${prev}" -v curr="${curr}" '
    function flush(   line) {
      if (current_minor == "") return
      if (current_count == 1) {
        line = current_first
        if (current_first_date != "") { line = line "  (" current_first_date ")" }
        printf "                   - %s\n", line
      } else {
        printf "                   - %s.x  (%d entries — range %s → %s)\n", \
          current_minor, current_count, current_last, current_first
      }
      current_minor = ""; current_count = 0
      current_first = ""; current_first_date = ""; current_last = ""
    }
    /^## \[/ {
      ver = $0
      sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      datepart = $0
      sub(/^[^]]*\][[:space:]]*-?[[:space:]]*/, "", datepart)
      if (ver == prev) { flush(); exit }
      if (ver == "Unreleased") {
        flush()
        printf "                   - %s\n", ver
        next
      }
      n = split(ver, parts, ".")
      if (n >= 2) { minor = parts[1] "." parts[2] } else { minor = ver }
      if (minor != current_minor) {
        flush()
        minors_emitted++
        # v1.42.0: cap 40 → 60 (lockstep with install.sh:1901).
        if (minors_emitted > 60) { truncated = 1; exit }
        current_minor = minor
        current_count = 1
        current_first = ver
        current_first_date = datepart
        current_last = ver
      } else {
        current_count++
        current_last = ver
      }
    }
    END {
      flush()
      if (truncated) print "                   - ... (older entries — see CHANGELOG.md)"
    }
  ' "${changelog}" 2>/dev/null || true
}

# Verbose mode (OMC_INSTALL_VERBOSE=1) preserves the pre-v1.36.0 per-
# patch listing. Mirrors install.sh's verbose branch exactly.
extract_whats_new_verbose() {
  local prev="$1"
  local curr="$2"
  local changelog="${3:-${REPO_ROOT}/CHANGELOG.md}"
  awk -v prev="${prev}" -v curr="${curr}" '
    /^## \[/ {
      ver = $0
      sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      datepart = $0
      sub(/^[^]]*\][[:space:]]*-?[[:space:]]*/, "", datepart)
      if (ver == prev) { exit }
      kept++
      # v1.42.0: cap 40 → 60 (lockstep with install.sh:1844).
      if (kept > 60) { truncated = 1; exit }
      if (ver == "Unreleased") {
        printf "                   - %s\n", ver
      } else {
        printf "                   - %s%s\n", ver, (datepart == "" ? "" : "  (" datepart ")")
      }
    }
    END { if (truncated) print "                   - ... (older entries — see CHANGELOG.md)" }
  ' "${changelog}" 2>/dev/null || true
}

# ----------------------------------------------------------------------
printf 'Test 1: extracts versions between prev and current\n'
out="$(extract_whats_new "1.27.0" "$(cat "${REPO_ROOT}/VERSION")")"
assert_contains "T1: includes 1.29.0" "1.29.0" "${out}"
assert_contains "T1: includes 1.28.0" "1.28.0" "${out}"
assert_not_contains "T1: stops at 1.27.0 (excluded)" "[1.27.0]" "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: stops at first matching prev version\n'
# Use 1.28.0 as the prior — should include 1.29.0 + 1.28.1 only,
# and Unreleased + later if any.
out="$(extract_whats_new "1.28.0" "$(cat "${REPO_ROOT}/VERSION")")"
assert_contains "T2: includes 1.29.0" "1.29.0" "${out}"
assert_contains "T2: includes 1.28.1" "1.28.1" "${out}"
assert_not_contains "T2: stops before 1.28.0" "- 1.28.0" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: empty prev (first install) extracts the full collapsed view\n'
# Install.sh guard `[[ -n "${PRIOR_INSTALLED_VERSION}" ]]` skips the
# block entirely for first installs, so the awk would extract every
# entry — the test verifies the BEHAVIOR (caller would suppress) by
# confirming the awk's output is non-empty when prev=empty. Under the
# v1.36.0 collapsed default the cap is 40 UNIQUE MINORS rather than
# 40 individual patches, so a CHANGELOG with N<40 minors emits cleanly
# with no truncation marker. We assert "1.29.0" appears (a known minor
# in the live CHANGELOG) and at least 1 entry line is present.
out="$(extract_whats_new "" "$(cat "${REPO_ROOT}/VERSION")")"
assert_contains "T3: empty prev extracts current run" "1.29.0" "${out}"
entry_count_t3="$(printf '%s' "${out}" | grep -c "^                   - " || true)"
if [[ "${entry_count_t3}" -ge 1 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: empty prev should produce at least one entry\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 4: same-version (no upgrade) extracts only Unreleased + nothing past current\n'
# When prev == current, only the Unreleased section comes through (if
# present); the next match exits the loop.
out="$(extract_whats_new "$(cat "${REPO_ROOT}/VERSION")" "$(cat "${REPO_ROOT}/VERSION")")"
# Unreleased rendered without double-parens.
assert_not_contains "T4: no double-paren around Unreleased" "((unreleased))" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: Unreleased section renders without double-paren\n'
# Synthetic CHANGELOG with an Unreleased section.
synthetic="$(mktemp)"
cat <<'EOF' > "${synthetic}"
# Changelog

## [Unreleased]

### Wave whatever

Stuff happening.

## [1.30.0] - 2026-06-01

Released.

## [1.29.0] - 2026-05-03

Earlier release.
EOF
out="$(extract_whats_new "1.29.0" "1.30.0" "${synthetic}")"
assert_contains "T5: Unreleased present" "Unreleased" "${out}"
assert_not_contains "T5: no double-paren" "((unreleased))" "${out}"
assert_contains "T5: 1.30.0 with date wrapped once" "1.30.0  (2026-06-01)" "${out}"
rm -f "${synthetic}"

# ----------------------------------------------------------------------
printf 'Test 6: 60-MINOR cap renders truncation marker when changelog has > 60 unique minors\n'
# v1.36.0 (item #6): the cap is per UNIQUE MINOR (X.Y) rather than
# per individual patch. v1.42.0 (this commit): cap raised 40 → 60 to
# accommodate the project's actual history span (43 unique minors at
# v1.42.0, growing). Synthesize 65 distinct minors to exercise the
# new cap — under collapsed mode this still emits 65 lines so
# truncation fires at minor #61.
synthetic="$(mktemp)"
{
  printf '# Changelog\n\n'
  for i in $(seq 65 -1 1); do
    if [[ "${i}" -ge 10 ]]; then
      printf '## [9.%d.0] - 2026-01-15\n\nRelease %d.\n\n' "${i}" "${i}"
    else
      printf '## [9.%d.0] - 2026-01-0%d\n\nRelease %d.\n\n' "${i}" "${i}" "${i}"
    fi
  done
} > "${synthetic}"
out="$(extract_whats_new "non-existent-version" "9.999.0" "${synthetic}")"
truncation_count="$(printf '%s' "${out}" | grep -c "older entries" || true)"
if [[ "${truncation_count}" -ge 1 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: cap-truncation marker missing for 65-minor changelog\n' >&2
  fail=$((fail + 1))
fi
# Count actual entry lines (those starting with "                   - 9.")
entry_count="$(printf '%s' "${out}" | grep -c "^                   - 9\." || true)"
assert_eq "T6: 60 minors kept before truncation" "60" "${entry_count}"
rm -f "${synthetic}"

# T6b — collapse: a changelog with 5 minors × 4 patches each = 20 entries
# should collapse to 5 lines (well under the 40-minor cap, no truncation).
synthetic="$(mktemp)"
{
  printf '# Changelog\n\n'
  for minor in 5 4 3 2 1; do
    for patch in 4 3 2 1 0; do
      printf '## [8.%d.%d] - 2026-01-15\n\nRelease 8.%d.%d.\n\n' "${minor}" "${patch}" "${minor}" "${patch}"
    done
  done
} > "${synthetic}"
out_collapse="$(extract_whats_new "non-existent-version" "8.999.0" "${synthetic}")"
collapse_lines="$(printf '%s' "${out_collapse}" | grep -c "^                   - 8\." || true)"
assert_eq "T6b: 5 minors × 5 patches collapse to 5 lines" "5" "${collapse_lines}"
# At least one ".x  (5 entries — range" marker present.
assert_contains "T6b: collapse marker formatted with entry count" \
  "8.5.x  (5 entries — range 8.5.0 → 8.5.4)" "${out_collapse}"
rm -f "${synthetic}"

# ----------------------------------------------------------------------
printf 'Test 7: install.sh syntax + new block grep-able\n'
bash -n "${REPO_ROOT}/install.sh"
assert_eq "T7: install.sh parses cleanly" "0" "$?"
if grep -q "PRIOR_INSTALLED_VERSION" "${REPO_ROOT}/install.sh"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T7: install.sh missing PRIOR_INSTALLED_VERSION capture\n' >&2
  fail=$((fail + 1))
fi
if grep -q "What.s new" "${REPO_ROOT}/install.sh"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T7: install.sh missing What.s new label\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
# T8 (v1.32.0 R6 + R6-amended) — real-world upgrade-span coverage.
#
# v1.31.0 → v1.31.1 cascade had a defect class T6 missed: the cap
# value (then 6) was a magic number with no test asserting "the cap
# accommodates a representative real-world upgrade span against the
# LIVE CHANGELOG". T6 used a synthetic 12-version changelog that
# guaranteed truncation by construction — it tests the cap mechanism,
# not the cap value's appropriateness.
#
# T8 closes the gap with two assertions per representative prior:
#   (a) negative — `extract_whats_new` against the real CHANGELOG.md
#       MUST NOT contain the truncation marker (cap-too-low check)
#   (b) positive bound — kept-entry count is between 1 and 10
#       (cap-too-high sanity; symmetric to (a))
#
# "Representative priors" = the last 3 minor-version tags reachable
# in the repo. Minor = the X in vN.X.Y; we pick one tag per minor
# (the lowest patch, sorted ascending so the *oldest* representative
# of each minor is chosen — the most-painful upgrade-span case).
#
# Rolls forward automatically: when v1.32.0 ships, the test starts
# checking 1.31.x / 1.30.x / 1.29.x spans, etc. No magic-number rot.
printf 'Test 8: cap accommodates representative real-world upgrade spans\n'

# Extract distinct minor versions from git tags, descending-by-major-minor,
# pick the LOWEST patch in each minor. macOS dev `sort -V` works; Ubuntu
# CI also has GNU sort -V. Fallback for absent tags: skip with a logged
# notice (test passes vacuously rather than blocking pre-tag prep).
candidate_priors=()
if command -v git >/dev/null 2>&1 \
    && (cd "${REPO_ROOT}" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1); then
  # Get all v*.X.Y tags, sort by version, pick lowest patch per (major,minor).
  # macOS sort -V works on coreutils 8.32+; bash 3.2 compat preserved.
  while IFS= read -r line; do
    [[ -n "${line}" ]] && candidate_priors+=("${line}")
  done < <(
    cd "${REPO_ROOT}" && \
    git tag --list 'v*' 2>/dev/null \
      | sed 's/^v//' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | awk -F. '{ key=$1"."$2; if (!seen[key]++) print $0 }' \
      | sort -V \
      | tail -3
  )
fi

if [[ ${#candidate_priors[@]} -eq 0 ]]; then
  printf '  T8: no v*.X.Y tags found — skipping (vacuous pass)\n'
  pass=$((pass + 1))
else
  for prior in "${candidate_priors[@]}"; do
    out="$(extract_whats_new "${prior}" "$(cat "${REPO_ROOT}/VERSION")")"

    # (a) Negative — no truncation marker for representative span.
    truncation_hits="$(printf '%s' "${out}" | grep -c "older entries" || true)"
    if [[ "${truncation_hits}" -eq 0 ]]; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T8(%s): truncation marker present — cap too low for representative span\n' "${prior}" >&2
      printf '    output:\n%s\n' "${out}" >&2
      fail=$((fail + 1))
    fi

    # (b) Positive bound — kept-entry count is in [1, 50].
    # v1.42.0: bound raised 30 → 50 to track the cap bump (40 → 60 in
    # install.sh). The project has 43+ unique minors as of v1.42.0; the
    # whats-new view legitimately shows more lines than at v1.36.0 when
    # the bound was set. 50 still keeps the view readable in a terminal.
    entry_count="$(printf '%s' "${out}" | grep -c "^                   - " || true)"
    if [[ "${entry_count}" -ge 1 && "${entry_count}" -le 50 ]]; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T8(%s): entry count %d not in [1,50]\n' "${prior}" "${entry_count}" >&2
      fail=$((fail + 1))
    fi
  done
fi

# ----------------------------------------------------------------------
printf 'Test 9: OMC_INSTALL_VERBOSE=1 mode preserves per-patch output (v1.36.0 #6)\n'
# When the user opts into the legacy verbose view, every CHANGELOG
# entry between prev and curr renders on its own line — same shape as
# pre-v1.36.0 install footers. The `extract_whats_new_verbose` fixture
# mirrors install.sh's verbose branch.
synthetic="$(mktemp)"
{
  printf '# Changelog\n\n'
  for patch in 5 4 3 2 1 0; do
    printf '## [7.0.%d] - 2026-01-1%d\n\n' "${patch}" "${patch}"
  done
  printf '## [6.9.0] - 2026-01-09\n\nPrevious minor.\n\n'
} > "${synthetic}"

# Collapsed (default): 6 patches in 7.0 should collapse to ONE line.
out_collapsed_v9="$(extract_whats_new "6.9.0" "7.0.5" "${synthetic}")"
collapsed_lines="$(printf '%s' "${out_collapsed_v9}" | grep -c "^                   - " || true)"
assert_eq "T9a: collapsed yields 1 line for 7.0.x patches" "1" "${collapsed_lines}"

# Verbose: same input should emit 6 separate entry lines.
out_verbose_v9="$(extract_whats_new_verbose "6.9.0" "7.0.5" "${synthetic}")"
verbose_lines="$(printf '%s' "${out_verbose_v9}" | grep -c "^                   - 7\." || true)"
assert_eq "T9b: verbose yields 6 lines for 7.0.x patches" "6" "${verbose_lines}"
rm -f "${synthetic}"

# T9c — install.sh contains both branches and the OMC_INSTALL_VERBOSE
# env-var gate so users have a path back to per-patch output.
if grep -q 'OMC_INSTALL_VERBOSE' "${REPO_ROOT}/install.sh"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T9c: install.sh missing OMC_INSTALL_VERBOSE branch\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf '\n=== install-whats-new tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
