#!/usr/bin/env bash
# Regression net for record-discovered-scope.sh (v1.46): the resolve verb
# that lets the model clear a discovered_scope row it shipped or determined
# is not-a-defect, instead of eating the 2-block cap or /ulw-skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-discovered-scope.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
export STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_DIR="${STATE_ROOT}/dss-test-session"
mkdir -p "${SESSION_DIR}"
SCOPE_FILE="${SESSION_DIR}/discovered_scope.jsonl"

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Run the script and assert its exit code (without aborting under set -e).
assert_exit() {
  local label="$1" expected="$2"; shift 2
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  assert_eq "${label}" "${expected}" "${code}"
}

seed() {
  cat > "${SCOPE_FILE}" <<'EOF'
{"_v":1,"id":"aaaa1111bbbb","source":"metis","summary":"caveat one","severity":"low","category":"other","status":"pending","reason":"","ts":1700000000}
{"_v":1,"id":"cccc2222dddd","source":"quality-reviewer","summary":"real bug","severity":"high","category":"bug","status":"pending","reason":"","ts":1700000001}
{"_v":1,"id":"eeee3333ffff","source":"oracle","summary":"another","severity":"medium","category":"other","status":"pending","reason":"","ts":1700000002}
EOF
}

printf 'T1: path emits discovered_scope.jsonl under STATE_ROOT\n'
p="$("${SCRIPT}" path)"
assert_contains "path under STATE_ROOT" "${STATE_ROOT}" "${p}"
assert_contains "path ends with discovered_scope.jsonl" "discovered_scope.jsonl" "${p}"

printf 'T2: counts reflects seeded pending rows\n'
seed
c="$("${SCRIPT}" counts)"
assert_contains "pending=3" "pending=3" "${c}"
assert_contains "total=3" "total=3" "${c}"

printf 'T3: status shipped flips one row pending->shipped and stamps evidence\n'
"${SCRIPT}" status aaaa1111 shipped "abc123def" >/dev/null
assert_eq "row status=shipped" "shipped" "$(jq -r 'select(.id=="aaaa1111bbbb")|.status' "${SCOPE_FILE}")"
assert_eq "row reason=evidence" "abc123def" "$(jq -r 'select(.id=="aaaa1111bbbb")|.reason' "${SCOPE_FILE}")"
rts="$(jq -r 'select(.id=="aaaa1111bbbb")|.resolved_ts' "${SCOPE_FILE}")"
assert_eq "resolved_ts is numeric" "yes" "$([[ "${rts}" =~ ^[0-9]+$ ]] && echo yes || echo no)"
c="$("${SCRIPT}" counts)"
assert_contains "pending dropped to 2" "pending=2" "${c}"
assert_contains "shipped=1" "shipped=1" "${c}"
# untouched rows preserved verbatim (per-line rewrite, not a slurp-rewrite)
assert_eq "other row unchanged" "real bug" "$(jq -r 'select(.id=="cccc2222dddd")|.summary' "${SCOPE_FILE}")"

printf 'T4: shipped with empty evidence is refused (no silent clear)\n'
assert_exit "empty evidence -> exit 2" 2 "${SCRIPT}" status cccc2222 shipped ""
assert_eq "row still pending after refused empty-evidence ship" "pending" "$(jq -r 'select(.id=="cccc2222dddd")|.status' "${SCOPE_FILE}")"

printf 'T5: status rejected with a concrete WHY flips pending->rejected\n'
"${SCRIPT}" status cccc2222 rejected "false positive" >/dev/null
assert_eq "row status=rejected" "rejected" "$(jq -r 'select(.id=="cccc2222dddd")|.status' "${SCOPE_FILE}")"
c="$("${SCRIPT}" counts)"
assert_contains "rejected=1" "rejected=1" "${c}"
assert_contains "pending=1" "pending=1" "${c}"

printf 'T6: rejected with a bare silent-skip reason is refused\n'
assert_exit "weak WHY -> exit 2" 2 "${SCRIPT}" status eeee3333 rejected "out of scope"
assert_eq "row still pending after weak-WHY reject" "pending" "$(jq -r 'select(.id=="eeee3333ffff")|.status' "${SCOPE_FILE}")"

printf 'T7: rejected "duplicate" (valid bare token) succeeds; pending hits 0\n'
"${SCRIPT}" status eeee3333 rejected "duplicate" >/dev/null
pending="$("${SCRIPT}" counts | grep -oE 'pending=[0-9]+' | cut -d= -f2)"
assert_eq "pending=0 after all resolved (gate would release)" "0" "${pending}"

printf 'T8: no-match prefix is refused\n'
seed
assert_exit "no match -> exit 2" 2 "${SCRIPT}" status zzzznomatch shipped "sha"

printf 'T9: ambiguous prefix is refused, leaves rows untouched\n'
cat > "${SCOPE_FILE}" <<'EOF'
{"_v":1,"id":"dup00000001","source":"metis","summary":"a","severity":"low","category":"other","status":"pending","reason":"","ts":1700000000}
{"_v":1,"id":"dup00000002","source":"metis","summary":"b","severity":"low","category":"other","status":"pending","reason":"","ts":1700000001}
EOF
assert_exit "ambiguous prefix -> exit 2" 2 "${SCRIPT}" status dup0000 shipped "sha"
assert_eq "both rows still pending after ambiguous reject" "2" "$(jq -rs '[.[]|select(.status=="pending")]|length' "${SCOPE_FILE}")"

printf 'T10: invalid status token is refused\n'
assert_exit "invalid status -> exit 2" 2 "${SCRIPT}" status dup00000001 bogus "x"

printf 'T11: status pending un-resolves a resolved row\n'
seed
"${SCRIPT}" status aaaa1111 shipped "sha" >/dev/null
"${SCRIPT}" status aaaa1111 pending >/dev/null
assert_eq "row restored to pending" "pending" "$(jq -r 'select(.id=="aaaa1111bbbb")|.status' "${SCOPE_FILE}")"

printf '\n=== record-discovered-scope status: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
