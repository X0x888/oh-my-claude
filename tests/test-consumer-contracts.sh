#!/usr/bin/env bash
# tests/test-consumer-contracts.sh — regression net for
# tools/check-consumer-contracts.sh.
#
# Why this exists. The linter enforces that every value-stream
# producer (jq -j + delimiter byte) carries a `Consumer contract`
# docstring block. Without a regression net for the linter itself,
# a future refactor to the linter could silently neuter the check
# and the Bug B post-mortem rule would stop being enforced.
#
# Tests:
#   T1 — production tree passes the linter (the live state-io.sh
#        producer has its Consumer contract block).
#   T2 — synthetic producer WITHOUT a contract block is flagged
#        (proves the rule fires when violated).
#   T3 — synthetic producer WITH a contract block is accepted
#        (proves the rule's escape hatch is honored).
#   T4 — non-producer functions in the same file are NOT flagged
#        (proves the detection rule is specific, not greedy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LINT="${REPO_ROOT}/tools/check-consumer-contracts.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain=%q\n    actual=%q\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# ----------------------------------------------------------------------
printf 'T1: production tree passes the linter (clean state)\n'
rc=0
output="$(bash "${LINT}" 2>&1)" || rc=$?
assert_eq "T1: linter exits 0 on production tree" "0" "${rc}"
assert_contains "T1: success message names producer count" "producer function(s) audited" "${output}"

# ----------------------------------------------------------------------
printf 'T2: synthetic producer WITHOUT a Consumer contract block is flagged\n'
# Use the textual `` escape — this is what the production
# source uses for the RS delimiter and what the linter detects.
cat > "${TMPROOT}/missing-contract.sh" <<'EOF'
# Some leading docstring that does NOT mention the contract.
# This producer joins values with RS but the implicit alignment
# rules are not documented.
my_bulk_emitter() {
  jq -j --args '$ARGS.positional[] | . + ""' "$@"
}
EOF
rc=0
output="$(bash "${LINT}" "${TMPROOT}/missing-contract.sh" 2>&1)" || rc=$?
assert_eq "T2: linter exits 1 on missing contract" "1" "${rc}"
assert_contains "T2: violation cites function name" "my_bulk_emitter" "${output}"
assert_contains "T2: violation references CONTRIBUTING anchor" "Consumer contract" "${output}"

# ----------------------------------------------------------------------
printf 'T3: synthetic producer WITH a Consumer contract block passes\n'
cat > "${TMPROOT}/has-contract.sh" <<'EOF'
# Bulk emitter for a hypothetical store.
#
# Consumer contract:
#   - delimiter: ASCII RS (0x1e)
#   - positional alignment: argv length === record count
#   - value sanitization: embedded RS bytes are stripped from values
#   - regression net: tests/test-fake-store.sh (hypothetical)
my_bulk_emitter() {
  jq -j --args '$ARGS.positional[] | . + ""' "$@"
}
EOF
rc=0
output="$(bash "${LINT}" "${TMPROOT}/has-contract.sh" 2>&1)" || rc=$?
assert_eq "T3: linter exits 0 when contract present" "0" "${rc}"

# ----------------------------------------------------------------------
printf 'T4: non-producer function in the same file is NOT flagged\n'
cat > "${TMPROOT}/mixed.sh" <<'EOF'
# A function that does NOT use jq -j and does NOT emit a delimited stream.
# Should not require a Consumer contract block.
my_regular_helper() {
  printf 'hello\n'
}

# A producer with a contract — should pass.
#
# Consumer contract:
#   delimiter: ASCII RS, alignment guaranteed.
my_documented_producer() {
  jq -j --args '$ARGS.positional[] | . + ""' "$@"
}
EOF
rc=0
output="$(bash "${LINT}" "${TMPROOT}/mixed.sh" 2>&1)" || rc=$?
assert_eq "T4: linter exits 0 (only one producer, contract present)" "0" "${rc}"
assert_contains "T4: audit count names exactly 1 producer" "1 producer function(s) audited" "${output}"

# ----------------------------------------------------------------------
printf 'T5: producer using newline-tail (jq -j ... + "\\n") is flagged when undocumented\n'
# The detector treats `jq -j ... + "\n"` as a positional record
# emitter — this was the original Bug B v1.27.0 shape. Include the
# bare `\n` form so the test exercises the Bug-B detection path.
cat > "${TMPROOT}/newline-delim.sh" <<'EOF'
# Pre-Bug-B style: jq -j with newline tail. Same contract requirement.
my_newline_producer() {
  jq -j --args '$ARGS.positional[] | . + "\n"' "$@"
}
EOF
rc=0
output="$(bash "${LINT}" "${TMPROOT}/newline-delim.sh" 2>&1)" || rc=$?
assert_eq "T5: newline-delim producers ARE flagged" "1" "${rc}"
assert_contains "T5: violation cites function name" "my_newline_producer" "${output}"

# ----------------------------------------------------------------------
printf '\n=== Consumer-Contract Lint Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
