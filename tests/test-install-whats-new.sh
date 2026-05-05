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

# Run the awk extraction in isolation. Mirrors the body of the
# install.sh "What's new" block — same awk script, same args, same
# CHANGELOG.md.
extract_whats_new() {
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
      if (kept > 12) { truncated = 1; exit }
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
printf 'Test 3: empty prev (first install) extracts nothing — handled at caller\n'
# Install.sh guard `[[ -n "${PRIOR_INSTALLED_VERSION}" ]]` skips the
# block entirely for first installs, so the awk would extract every
# entry — the test verifies that BEHAVIOR (caller would suppress) by
# confirming the awk's output IS the full changelog when prev=empty.
out="$(extract_whats_new "" "$(cat "${REPO_ROOT}/VERSION")")"
assert_contains "T3: empty prev extracts current run" "1.29.0" "${out}"
# The 6-entry cap kicks in.
truncated_count="$(printf '%s' "${out}" | grep -c "older entries" || true)"
if [[ "${truncated_count}" -ge 1 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: 6-entry cap should trigger truncation marker\n' >&2
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
printf 'Test 6: 12-entry cap renders truncation marker when changelog has > 12 versions before prev\n'
# v1.31.1: cap raised from 6 → 10 because the original 6-entry budget
# was uncomfortable for users upgrading across multiple releases (e.g.
# 1.27.0 → 1.31.1 spans 7 entries). v1.32.1: cap raised from 10 → 12
# because adding the 1.32.x patches pushed a real 1.27.0 → head upgrade
# past the 10-cap (dropping 1.28.0 from the What's-new summary). To
# exercise the cap, the synthetic CHANGELOG now has 14 versions; prev
# set to non-existent so all 14 would extract — cap triggers at 12.
synthetic="$(mktemp)"
{
  printf '# Changelog\n\n'
  for i in 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
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
  printf '  FAIL: T6: cap-truncation marker missing for 14-entry changelog\n' >&2
  fail=$((fail + 1))
fi
# Count actual entry lines (those starting with "                   - 9.")
entry_count="$(printf '%s' "${out}" | grep -c "^                   - 9\." || true)"
assert_eq "T6: 12 entries kept before truncation" "12" "${entry_count}"
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

    # (b) Positive bound — kept-entry count is in [1, 12].
    entry_count="$(printf '%s' "${out}" | grep -c "^                   - " || true)"
    if [[ "${entry_count}" -ge 1 && "${entry_count}" -le 12 ]]; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T8(%s): entry count %d not in [1,12]\n' "${prior}" "${entry_count}" >&2
      fail=$((fail + 1))
    fi
  done
fi

# ----------------------------------------------------------------------
printf '\n=== install-whats-new tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
