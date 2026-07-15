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
RUNNER="${REPO_ROOT}/tools/run-tests.sh"

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    printf '  FAIL: %s — unexpected [%s]\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
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
printf 'Test 8: full-suite CI runner dynamically pins every Bash test\n'
fixture="$(mktemp -d)"
mkdir -p "${fixture}/tools" "${fixture}/tests" "${fixture}/.github/workflows"
cp "${REPO_ROOT}/tools/list-ci-pinned-tests.sh" "${fixture}/tools/"
touch "${fixture}/tests/test-alpha.sh" "${fixture}/tests/test-beta.sh"
cat > "${fixture}/.github/workflows/validate.yml" <<'YML'
jobs:
  native:
    steps:
      - run: bash tools/run-tests.sh --full --shard "${{ matrix.shard }}/2"
YML
pins="$(bash "${fixture}/tools/list-ci-pinned-tests.sh" \
  "${fixture}/.github/workflows/validate.yml")"
assert_contains "T8: dynamic full-suite pin includes alpha" \
  "tests/test-alpha.sh" "${pins}"
assert_contains "T8: dynamic full-suite pin includes beta" \
  "tests/test-beta.sh" "${pins}"
assert_eq "T8: full-suite runner emits each test exactly once" "2" \
  "$(printf '%s\n' "${pins}" | grep -c . || true)"
rm -rf "${fixture}"

# ---------------------------------------------------------------------
printf 'Test 9: workflow uses sharded native and proportional sterile jobs\n'
workflow="$(cat "${REPO_ROOT}/.github/workflows/validate.yml")"
assert_contains "T9: native suite uses full sharded runner" \
  'tools/run-tests.sh --full --shard' "${workflow}"
assert_contains "T9: historical test check aggregates every old surface" \
  'needs: [lint, test-native, test-sterile]' "${workflow}"
assert_contains "T9: aggregate check observes failures instead of skipping" \
  'if: always()' "${workflow}"
assert_contains "T9: PR sterile suite is change-proportional" \
  'run-sterile.sh --changed --base' "${workflow}"
assert_contains "T9: push sterile suite remains exhaustive" \
  'run-sterile.sh --full' "${workflow}"
assert_contains "T9: historical context consumes sterile result" \
  'STERILE_RESULT: ${{ needs.test-sterile.result }}' "${workflow}"
assert_contains "T9: historical context consumes lint/Python result" \
  'LINT_RESULT: ${{ needs.lint.result }}' "${workflow}"

# ---------------------------------------------------------------------
printf 'Test 10: local container keeps exhaustive sterile coverage\n'
local_ci_source="$(cat "${SCRIPT}")"
assert_contains "T10: local-ci explicitly requests full sterile suite" \
  'bash tests/run-sterile.sh --full' "${local_ci_source}"
assert_not_contains "T10: local-ci never opts into PR-only changed selection" \
  'bash tests/run-sterile.sh --changed' "${local_ci_source}"

# ---------------------------------------------------------------------
printf 'Test 11: change-aware runner is selective, fail-closed, quiet, and diagnosable\n'
runner_fixture="$(mktemp -d)"
mkdir -p "${runner_fixture}/tools" "${runner_fixture}/tests" \
  "${runner_fixture}/src"
cp "${RUNNER}" "${runner_fixture}/tools/run-tests.sh"
chmod +x "${runner_fixture}/tools/run-tests.sh"

cat > "${runner_fixture}/tests/test-alpha.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Owner: src/alpha.sh
printf 'ALPHA_BODY_NOISE\n'
SH
cat > "${runner_fixture}/tests/test-beta.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'BETA_BODY_NOISE\n'
SH
cat > "${runner_fixture}/tests/test-coordination-rules.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'COORDINATION_BODY_NOISE\n'
SH
cat > "${runner_fixture}/tests/test-consumer-contracts.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'CONSUMER_BODY_NOISE\n'
SH
printf '# alpha producer\n' > "${runner_fixture}/src/alpha.sh"
printf '# deliberately unmapped producer\n' > "${runner_fixture}/src/unmapped.sh"

git -C "${runner_fixture}" init -q
git -C "${runner_fixture}" config user.email test@example.test
git -C "${runner_fixture}" config user.name 'Test Runner'
git -C "${runner_fixture}" add .
git -C "${runner_fixture}" commit -q -m baseline

printf '# changed\n' >> "${runner_fixture}/src/alpha.sh"
out="$(cd "${runner_fixture}" && bash tools/run-tests.sh --list --no-record)"
assert_contains "T11: mapped source selects owning test" \
  "tests/test-alpha.sh" "${out}"
assert_contains "T11: mapped selection retains coordination contract" \
  "tests/test-coordination-rules.sh" "${out}"
assert_contains "T11: mapped selection retains consumer contract" \
  "tests/test-consumer-contracts.sh" "${out}"
assert_not_contains "T11: mapped source excludes unrelated test" \
  "tests/test-beta.sh" "${out}"

git -C "${runner_fixture}" add src/alpha.sh
git -C "${runner_fixture}" commit -q -m mapped-change
printf '# changed without an owner\n' >> "${runner_fixture}/src/unmapped.sh"
out="$(cd "${runner_fixture}" && bash tools/run-tests.sh --list --no-record)"
assert_contains "T11: unmapped production change fails closed" \
  "unmapped production path; conservative full fallback" "${out}"
assert_contains "T11: fail-closed selection includes unrelated test" \
  "tests/test-beta.sh" "${out}"

out="$(cd "${runner_fixture}" && bash tools/run-tests.sh --full --no-record)"
assert_contains "T11: quiet run reports concise pass receipt" \
  "Test run passed: 4/4" "${out}"
assert_not_contains "T11: quiet run suppresses passing test body" \
  "ALPHA_BODY_NOISE" "${out}"
assert_not_contains "T11: quiet run suppresses every passing body" \
  "CONSUMER_BODY_NOISE" "${out}"
assert_not_contains "T11: execution omits verbose ownership reasons" \
  "explicit full suite" "${out}"
assert_not_contains "T11: execution avoids duplicate per-test PASS receipts" \
  "PASS tests/test-alpha.sh" "${out}"

audit_out="$(cd "${runner_fixture}" && bash tools/run-tests.sh --audit)"
assert_contains "T11: audit names evidence-first principle" \
  "age and slowness are review signals, never deletion proof" "${audit_out}"
assert_contains "T11: audit emits portfolio decisions" \
  $'Decision\tTest\tRuntime\tEvidence' "${audit_out}"

# A SIGKILL can bypass EXIT cleanup. The next runner must reclaim an abandoned
# receipt lock instead of silently losing runtime evidence forever.
timing_receipt="${runner_fixture}/test-times.tsv"
mkdir "${timing_receipt}.lock"
printf '999999\tdead-runner\t1\n' > "${timing_receipt}.lock/owner"
timed_out="$(cd "${runner_fixture}" \
  && OMC_TEST_TIMING_FILE="${timing_receipt}" \
     bash tools/run-tests.sh --full)"
assert_contains "T11: stale timing lock does not block the next run" \
  "Test run passed: 4/4" "${timed_out}"
assert_eq "T11: reclaimed lock records every test receipt" "4" \
  "$(wc -l < "${timing_receipt}" | tr -d '[:space:]')"
assert_eq "T11: timing lock is released after recording" "0" \
  "$([[ -d "${timing_receipt}.lock" ]] && printf 1 || printf 0)"

orphan_tree="$(git -C "${runner_fixture}" mktree </dev/null)"
orphan_commit="$(printf 'unrelated history\n' \
  | git -C "${runner_fixture}" commit-tree "${orphan_tree}")"
set +e
no_merge_base_out="$(cd "${runner_fixture}" \
  && bash tools/run-tests.sh --base "${orphan_commit}" --list --no-record 2>&1)"
no_merge_base_rc=$?
set -e
assert_eq "T11: unrelated base history exits nonzero instead of selecting a subset" \
  "2" "${no_merge_base_rc}"
assert_contains "T11: unrelated base failure explains the merge-base problem" \
  "cannot compute changes" "${no_merge_base_out}"

shard_paths=""
for shard in 1 2; do
  shard_out="$(cd "${runner_fixture}" \
    && bash tools/run-tests.sh --full --shard "${shard}/2" --list --no-record)"
  shard_paths="${shard_paths}"$'\n'"$(printf '%s\n' "${shard_out}" \
    | sed -n 's|^[[:space:]]*\(tests/test-[^[:space:]]*\.sh\).*|\1|p')"
done
shard_paths="$(printf '%s\n' "${shard_paths}" | sed '/^$/d')"
assert_eq "T11: shards cover every selected test once" "4" \
  "$(printf '%s\n' "${shard_paths}" | wc -l | tr -d '[:space:]')"
assert_eq "T11: shard ownership has no duplicates" "4" \
  "$(printf '%s\n' "${shard_paths}" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')"

set +e
too_many_shards_out="$(cd "${runner_fixture}" \
  && bash tools/run-tests.sh --full --shard 1/5 --list --no-record 2>&1)"
too_many_shards_rc=$?
set -e
assert_eq "T11: shard count cannot exceed selected test count" "1" \
  "${too_many_shards_rc}"
assert_contains "T11: excessive shard count explains the empty-shard risk" \
  "shard count 5 exceeds selected test count 4; refusing empty shard(s)" \
  "${too_many_shards_out}"

# Zero-line Bash files are valid tests, but their zero LOC weights expose a
# pathological greedy assignment in which a legal N/TOTAL topology can still
# leave one requested shard empty. The post-assignment guard must fail closed.
touch "${runner_fixture}/tests/test-empty-one.sh" \
  "${runner_fixture}/tests/test-empty-two.sh"
set +e
empty_shard_out="$(cd "${runner_fixture}" \
  && bash tools/run-tests.sh --full --shard 6/6 --list --no-record 2>&1)"
empty_shard_rc=$?
set -e
assert_eq "T11: requested empty shard exits nonzero" "1" \
  "${empty_shard_rc}"
assert_contains "T11: empty requested shard rejects a false-green job" \
  "shard 6/6 selected zero tests; refusing a false-green shard" \
  "${empty_shard_out}"
rm -f "${runner_fixture}/tests/test-empty-one.sh" \
  "${runner_fixture}/tests/test-empty-two.sh"

cat > "${runner_fixture}/tests/test-beta.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'BETA_FAIL_SENTINEL\n' >&2
exit 7
SH
set +e
failure_out="$(cd "${runner_fixture}" \
  && bash tools/run-tests.sh --full --no-record 2>&1)"
failure_rc=$?
set -e
assert_eq "T11: failing test preserves its exit code" "7" "${failure_rc}"
assert_contains "T11: failure prints only the useful failing tail" \
  "BETA_FAIL_SENTINEL" "${failure_out}"
assert_contains "T11: failure points to its full retained log" \
  "Full failure log:" "${failure_out}"
if [[ -f "${runner_fixture}/.git/omc-test-failures/test-beta.log" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T11: retained failure log is missing\n' >&2
  fail=$((fail + 1))
fi
rm -rf "${runner_fixture}"

# ---------------------------------------------------------------------
printf '\n=== local-ci tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
