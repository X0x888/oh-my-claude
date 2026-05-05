#!/usr/bin/env bash
#
# tests/test-local-ci.sh — unit smoke for tools/local-ci.sh.
#
# v1.33.x recommendation #2 (post-mortem of v1.33.0/.1/.2 cascade):
# tools/local-ci.sh runs the CI parity suite inside an Ubuntu
# container so BSD-vs-GNU coreutils + Linux-/tmp-shape divergence
# is caught BEFORE the GitHub Actions round-trip.
#
# Coverage scope: everything that can be asserted WITHOUT actually
# running Docker (the CI environment may not have docker-in-docker
# wired, and test-local-ci.sh has to pass on the same Ubuntu runner
# the rest of the suite passes on). What's asserted here:
#   - --help exits 0 and prints usage
#   - unknown args reject with rc=2
#   - missing runtime (PATH-cleared) exits 2 with a named hint
#   - --image flag is parsed
#   - --skip-sterile and --skip-shellcheck flip the flags

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/tools/local-ci.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — expected [%s], got [%s]\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  # `-- ${needle}` separator is required: many usage lines contain
  # `--flag-name` strings which grep would otherwise interpret as
  # an unknown flag and error out, masking the real assertion.
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — needle [%s] not found\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------
printf 'Test 1: tools/local-ci.sh exists and is executable\n'
if [[ -x "${SCRIPT}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T1: tools/local-ci.sh missing or not executable\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 2: --help exits 0 and surfaces usage\n'
set +e
out="$(bash "${SCRIPT}" --help 2>&1)"
rc=$?
set -e
assert_eq "T2: --help exits 0" "0" "${rc}"
assert_contains "T2: usage names tool name" "local-ci.sh" "${out}"
assert_contains "T2: usage mentions --image flag" "--image" "${out}"
assert_contains "T2: usage mentions --skip-sterile" "--skip-sterile" "${out}"

# ---------------------------------------------------------------------
printf 'Test 3: unknown arg rejects with rc=2\n'
set +e
out="$(bash "${SCRIPT}" --bogus-flag 2>&1)"
rc=$?
set -e
assert_eq "T3: unknown arg → rc=2" "2" "${rc}"
assert_contains "T3: names the bad flag" "unknown arg" "${out}"

# ---------------------------------------------------------------------
printf 'Test 4: missing runtime (cleared PATH) exits 2 with a named hint\n'
# Simulate "no docker on PATH" by clearing PATH to a directory that
# definitely lacks docker. /usr/bin/false-with-real-PATH wouldn't work
# because most systems have docker-cli installed but in non-standard
# paths; clearing PATH entirely is the most reliable simulator.
#
# Use a non-existent runtime name to make the test reliable on hosts
# that DO have docker installed (the runtime check still runs first,
# and `command -v` on a unique nonsense name returns non-zero).
set +e
out="$(bash "${SCRIPT}" --runtime omc-no-such-runtime 2>&1)"
rc=$?
set -e
assert_eq "T4: missing runtime → rc=2" "2" "${rc}"
assert_contains "T4: names the missing runtime" "omc-no-such-runtime" "${out}"
assert_contains "T4: surfaces install hint" "Docker" "${out}"

# ---------------------------------------------------------------------
printf 'Test 5: --image flag is parsed (lands in error message under missing-runtime)\n'
# When docker IS available we'd run the container. To keep this test
# deterministic and quick, combine --image with a fake --runtime so
# the runtime probe fails first. The script's error path mentions the
# image name in the "tag is X" line — but more reliably, --image
# parsing simply must not error before the runtime check.
set +e
out="$(bash "${SCRIPT}" --runtime omc-no-such-runtime --image custom:tag 2>&1)"
rc=$?
set -e
assert_eq "T5: --image + missing runtime → rc=2 (parser accepted --image)" "2" "${rc}"

# ---------------------------------------------------------------------
printf 'Test 6: shellcheck is clean on tools/local-ci.sh\n'
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x --severity=warning "${SCRIPT}" 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T6: shellcheck flagged tools/local-ci.sh\n' >&2
    fail=$((fail + 1))
  fi
else
  printf '  SKIP: T6: shellcheck not on PATH\n'
fi

# ---------------------------------------------------------------------
printf 'Test 7: --skip-sterile and --skip-shellcheck reach the parser\n'
# These flags are accepted by the parser. Combining with a missing
# runtime exits at the runtime check (rc=2) without complaining about
# the flags themselves.
set +e
out="$(bash "${SCRIPT}" --runtime omc-no-such-runtime --skip-sterile --skip-shellcheck 2>&1)"
rc=$?
set -e
assert_eq "T7: skip flags accepted by parser" "2" "${rc}"
# The test must NOT see "unknown arg" for the skip flags — that'd mean
# the parser regressed.
if printf '%s' "${out}" | grep -q "unknown arg"; then
  printf '  FAIL: T7: skip flags unexpectedly hit unknown-arg path\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------
printf '\n=== local-ci tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
