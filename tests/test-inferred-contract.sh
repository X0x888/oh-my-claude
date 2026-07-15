#!/usr/bin/env bash
# shellcheck disable=SC1090
#
# test-inferred-contract.sh — Delivery Contract v2 inference (v1.34.0)
#
# Covers `derive_inferred_contract_surfaces`, `inferred_contract_*`
# helpers in common.sh, and the stop-guard wiring that blocks Stop on
# inferred-but-untouched adjacent surfaces. The test cases simulate
# real ULW sessions where the user prompt does NOT explicitly name
# tests, changelog, parser-lockstep, or release notes — but the work
# implies them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
MARK_EDIT_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh"
RECORD_DELIVERY_ACTION_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-delivery-action.sh"
STOP_GUARD_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"

TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${STATE_ROOT}"
touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    haystack: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_empty() {
  local label="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected empty\n    actual: %s\n' "${label}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_empty() {
  local label="$1" actual="$2"
  if [[ -n "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected non-empty, got empty\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

# --- session helpers --------------------------------------------------------

DEFAULT_EXEC_STATE='{"task_intent":"execution","task_domain":"coding"}'

setup_session() {
  local sid="$1"
  local state_json="${2:-${DEFAULT_EXEC_STATE}}"
  local sdir="${STATE_ROOT}/${sid}"
  rm -rf "${sdir}"
  mkdir -p "${sdir}"
  printf '%s' "${state_json}" > "${sdir}/session_state.json"
}

write_edits() {
  local sid="$1"
  shift
  local log_path="${STATE_ROOT}/${sid}/edited_files.log"
  : > "${log_path}"
  for p in "$@"; do printf '%s\n' "${p}" >> "${log_path}"; done
}

run_derive() {
  local sid="$1"
  ( export SESSION_ID="${sid}"
    export OMC_INFERRED_CONTRACT="${OMC_INFERRED_CONTRACT:-on}"
    . "${COMMON_SH}"
    derive_inferred_contract_surfaces )
}

run_blockers() {
  local sid="$1"
  ( export SESSION_ID="${sid}"
    export OMC_INFERRED_CONTRACT="${OMC_INFERRED_CONTRACT:-on}"
    . "${COMMON_SH}"
    inferred_contract_blocking_items )
}

run_delivery_blockers() {
  local sid="$1"
  ( cd "${TEST_HOME}"
    export SESSION_ID="${sid}"
    . "${COMMON_SH}"
    delivery_contract_blocking_items )
}

run_delivery_remaining() {
  local sid="$1"
  ( export SESSION_ID="${sid}"
    . "${COMMON_SH}"
    delivery_contract_remaining_items )
}

run_refresh() {
  local sid="$1"
  ( export SESSION_ID="${sid}"
    export OMC_INFERRED_CONTRACT="${OMC_INFERRED_CONTRACT:-on}"
    . "${COMMON_SH}"
    refresh_inferred_contract )
}

run_delivery_action() {
  local sid="$1" command="$2" output="${3:-}"
  jq -nc --arg s "${sid}" --arg cmd "${command}" --arg out "${output}" \
    '{session_id:$s,tool_name:"Bash",tool_input:{command:$cmd},tool_response:$out}' \
    | bash "${RECORD_DELIVERY_ACTION_SH}" 2>/dev/null
}

read_state_key() {
  local sid="$1" key="$2"
  jq -r --arg k "${key}" '.[$k] // ""' "${STATE_ROOT}/${sid}/session_state.json"
}

# --- shared default state ----------------------------------------------------

EXEC_STATE='{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"unspecified","last_user_prompt_ts":"100"}'

printf '\n--- Path classifiers (v2-specific) ---\n'

# is_version_file_path
( . "${COMMON_SH}"
  is_version_file_path "/repo/VERSION" && echo "VERSION:yes" || echo "VERSION:no"
  is_version_file_path "/repo/version" && echo "version:yes" || echo "version:no"
  is_version_file_path "/repo/version.txt" && echo "version.txt:yes" || echo "version.txt:no"
  is_version_file_path "/repo/src/foo.go" && echo "foo.go:yes" || echo "foo.go:no" ) > "${TEST_HOME}/version_results"
assert_contains "is_version_file_path matches VERSION" "VERSION:yes" "$(cat "${TEST_HOME}/version_results")"
assert_contains "is_version_file_path matches version" "version:yes" "$(cat "${TEST_HOME}/version_results")"
assert_contains "is_version_file_path matches version.txt" "version.txt:yes" "$(cat "${TEST_HOME}/version_results")"
assert_contains "is_version_file_path rejects code" "foo.go:no" "$(cat "${TEST_HOME}/version_results")"

# is_changelog_path strict (does NOT match VERSION)
( . "${COMMON_SH}"
  is_changelog_path "/repo/CHANGELOG.md" && echo "CHANGELOG:yes" || echo "CHANGELOG:no"
  is_changelog_path "/repo/RELEASE_NOTES.md" && echo "RELEASE_NOTES:yes" || echo "RELEASE_NOTES:no"
  is_changelog_path "/repo/HISTORY" && echo "HISTORY:yes" || echo "HISTORY:no"
  is_changelog_path "/repo/VERSION" && echo "VERSION_changelog:yes" || echo "VERSION_changelog:no"
  is_changelog_path "/repo/releases/v1.0.md" && echo "releases_dir:yes" || echo "releases_dir:no" ) > "${TEST_HOME}/changelog_results"
assert_contains "is_changelog_path matches CHANGELOG.md" "CHANGELOG:yes" "$(cat "${TEST_HOME}/changelog_results")"
assert_contains "is_changelog_path matches RELEASE_NOTES.md" "RELEASE_NOTES:yes" "$(cat "${TEST_HOME}/changelog_results")"
assert_contains "is_changelog_path matches HISTORY" "HISTORY:yes" "$(cat "${TEST_HOME}/changelog_results")"
assert_contains "is_changelog_path REJECTS VERSION (key correctness fix)" "VERSION_changelog:no" "$(cat "${TEST_HOME}/changelog_results")"
assert_contains "is_changelog_path matches releases/ dir" "releases_dir:yes" "$(cat "${TEST_HOME}/changelog_results")"

# is_conf_example_path
( . "${COMMON_SH}"
  is_conf_example_path "/repo/oh-my-claude.conf.example" && echo "omc_conf_example:yes" || echo "omc_conf_example:no"
  is_conf_example_path "/repo/some.conf.example" && echo "generic_conf_example:yes" || echo "generic_conf_example:no"
  is_conf_example_path "/repo/foo.conf" && echo "non_example:yes" || echo "non_example:no" ) > "${TEST_HOME}/cfg_example_results"
assert_contains "is_conf_example_path matches oh-my-claude.conf.example" "omc_conf_example:yes" "$(cat "${TEST_HOME}/cfg_example_results")"
assert_contains "is_conf_example_path matches generic .conf.example" "generic_conf_example:yes" "$(cat "${TEST_HOME}/cfg_example_results")"
assert_contains "is_conf_example_path rejects bare .conf" "non_example:no" "$(cat "${TEST_HOME}/cfg_example_results")"

# is_conf_parser_path — matches common.sh ONLY (after R3 split into R3a/R3b)
( . "${COMMON_SH}"
  is_conf_parser_path "/repo/bundle/dot-claude/skills/autowork/scripts/common.sh" && echo "common:yes" || echo "common:no"
  is_conf_parser_path "/repo/bundle/dot-claude/skills/autowork/scripts/omc-config.sh" && echo "omc:yes" || echo "omc:no"
  is_conf_parser_path "/repo/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh" && echo "other:yes" || echo "other:no" ) > "${TEST_HOME}/parser_results"
assert_contains "is_conf_parser_path matches common.sh" "common:yes" "$(cat "${TEST_HOME}/parser_results")"
assert_contains "is_conf_parser_path REJECTS omc-config.sh (R3 split)" "omc:no" "$(cat "${TEST_HOME}/parser_results")"
assert_contains "is_conf_parser_path rejects other autowork scripts" "other:no" "$(cat "${TEST_HOME}/parser_results")"

# is_omc_config_table_path — matches omc-config.sh ONLY
( . "${COMMON_SH}"
  is_omc_config_table_path "/repo/bundle/dot-claude/skills/autowork/scripts/common.sh" && echo "common:yes" || echo "common:no"
  is_omc_config_table_path "/repo/bundle/dot-claude/skills/autowork/scripts/omc-config.sh" && echo "omc:yes" || echo "omc:no"
  is_omc_config_table_path "/repo/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh" && echo "other:yes" || echo "other:no" ) > "${TEST_HOME}/table_results"
assert_contains "is_omc_config_table_path matches omc-config.sh" "omc:yes" "$(cat "${TEST_HOME}/table_results")"
assert_contains "is_omc_config_table_path rejects common.sh" "common:no" "$(cat "${TEST_HOME}/table_results")"

# is_inference_skip_path
( . "${COMMON_SH}"
  is_inference_skip_path "/Users/me/.claude/quality-pack/state/sid/edited_files.log" && echo "state:skip" || echo "state:keep"
  is_inference_skip_path "/repo/.git/HEAD" && echo "git:skip" || echo "git:keep"
  is_inference_skip_path "/repo/src/foo.go" && echo "code:skip" || echo "code:keep"
  is_inference_skip_path "/repo/node_modules/lib/index.js" && echo "nm:skip" || echo "nm:keep"
  is_inference_skip_path "/repo/vendor/foo/bar.go" && echo "vendor:skip" || echo "vendor:keep"
  is_inference_skip_path "/repo/dist/main.js" && echo "dist:skip" || echo "dist:keep"
  is_inference_skip_path "/repo/build/output.js" && echo "build:skip" || echo "build:keep"
  is_inference_skip_path "/repo/.next/build-manifest.json" && echo "next:skip" || echo "next:keep"
  is_inference_skip_path "/repo/.turbo/cache.log" && echo "turbo:skip" || echo "turbo:keep"
  is_inference_skip_path "/repo/.cache/foo.tmp" && echo "cache:skip" || echo "cache:keep"
  is_inference_skip_path "/repo/target/release/foo" && echo "target:skip" || echo "target:keep" ) > "${TEST_HOME}/skip_results"
assert_contains "is_inference_skip_path skips state dir" "state:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips .git" "git:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path keeps code" "code:keep" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips node_modules" "nm:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips vendor" "vendor:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips dist" "dist:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips build" "build:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips .next" "next:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips .turbo" "turbo:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips .cache" "cache:skip" "$(cat "${TEST_HOME}/skip_results")"
assert_contains "is_inference_skip_path skips target" "target:skip" "$(cat "${TEST_HOME}/skip_results")"

# Vendor/build paths should not pollute inferred-rule code counts.
setup_session "skip_vendor" "${EXEC_STATE}"
write_edits "skip_vendor" \
  /repo/node_modules/foo/index.js \
  /repo/vendor/lib/bar.go \
  /repo/dist/main.js \
  /repo/src/real_only.go
result="$(run_derive "skip_vendor")"
assert_eq "vendor/dist paths do not create an inferred rule" "|" "${result}"

# --- Test anti-accumulation -------------------------------------------------

printf '\n--- tests: code fan-out does not imply a new test file ---\n'

setup_session "r1a" "${EXEC_STATE}"
write_edits "r1a" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1a")"
assert_eq "2 code files do not infer a missing-test blocker" "|" "${result}"

setup_session "r1b" "${EXEC_STATE}"
write_edits "r1b" /repo/src/auth.go
result="$(run_derive "r1b")"
assert_eq "1 code file does not infer a missing-test blocker" "|" "${result}"

setup_session "r1c" "${EXEC_STATE}"
write_edits "r1c" /repo/src/auth.go /repo/src/payment.go /repo/tests/test-auth.go
result="$(run_derive "r1c")"
assert_eq "a test edit does not manufacture an inferred rule" "|" "${result}"

# Explicit requests remain a hard Delivery Contract surface. This is
# intentionally separate from inference: the user asked for the test.
explicit_expectation="$(
  . "${COMMON_SH}"
  derive_done_contract_test_expectation \
    "fix the auth bug and add regression coverage" "coding"
)"
assert_eq "explicit regression coverage derives a test-edit contract" \
  "add_or_update_tests" "${explicit_expectation}"

generic_expectation="$(
  . "${COMMON_SH}"
  derive_done_contract_test_expectation "fix the auth bug" "coding"
)"
assert_eq "ordinary code work still derives a verification contract" \
  "verify" "${generic_expectation}"

setup_session "r1-explicit" '{"task_intent":"execution","task_domain":"coding","done_contract_test_expectation":"add_or_update_tests","done_contract_commit_mode":"unspecified","done_contract_push_mode":"unspecified","session_start_ts":"100","done_contract_updated_ts":"100"}'
write_edits "r1-explicit" /repo/src/auth.go /repo/src/payment.go
blockers="$(run_delivery_blockers "r1-explicit")"
assert_contains "explicit test request still blocks without a test edit" \
  "add or update the requested tests/regression coverage" "${blockers}"
write_edits "r1-explicit" /repo/src/auth.go /repo/src/payment.go /repo/tests/test-auth.go
blockers="$(run_delivery_blockers "r1-explicit")"
assert_empty "explicit test request clears only after a test edit" "${blockers}"

setup_session "verify-fresh" '{"task_intent":"execution","task_domain":"coding","done_contract_test_expectation":"verify","done_contract_commit_mode":"unspecified","done_contract_push_mode":"unspecified","session_start_ts":"100","done_contract_updated_ts":"100","last_code_edit_ts":"200","last_review_ts":"220","last_verify_ts":"150","last_verify_outcome":"passed","last_verify_confidence":"80"}'
write_edits "verify-fresh" /repo/src/auth.go
remaining="$(run_delivery_remaining "verify-fresh")"
assert_contains "stale verification still blocks after a code edit" \
  "run verification after the latest code edits" "${remaining}"
jq '.last_verify_ts="230"' "${STATE_ROOT}/verify-fresh/session_state.json" \
  >"${STATE_ROOT}/verify-fresh/session_state.json.tmp"
mv "${STATE_ROOT}/verify-fresh/session_state.json.tmp" \
  "${STATE_ROOT}/verify-fresh/session_state.json"
remaining="$(run_delivery_remaining "verify-fresh")"
[[ "${remaining}" != *"run verification after the latest code edits"* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: fresh verification should clear its gate — actual=${remaining}" >&2; }

# --- R2 VERSION without CHANGELOG --------------------------------------------

printf '\n--- R2: VERSION bumped without changelog ---\n'

setup_session "r2a" "${EXEC_STATE}"
write_edits "r2a" /repo/VERSION
result="$(run_derive "r2a")"
assert_eq "R2 fires on VERSION alone" "changelog|R2_version_no_changelog" "${result}"

setup_session "r2b" "${EXEC_STATE}"
write_edits "r2b" /repo/VERSION /repo/CHANGELOG.md
result="$(run_derive "r2b")"
assert_eq "R2 silent when CHANGELOG.md also touched" "|" "${result}"

setup_session "r2c" "${EXEC_STATE}"
write_edits "r2c" /repo/VERSION /repo/RELEASE_NOTES.md
result="$(run_derive "r2c")"
assert_eq "R2 silent when RELEASE_NOTES.md also touched" "|" "${result}"

# --- R3 conf flag without parser lockstep ------------------------------------

printf '\n--- R3 split: parser-site (R3a) + config-table (R3b) ---\n'

setup_session "r3a_only" "${EXEC_STATE}"
write_edits "r3a_only" /repo/bundle/dot-claude/oh-my-claude.conf.example
result="$(run_derive "r3a_only")"
# Both R3a and R3b fire because conf.example was touched and neither
# parser site nor table was — the triple-write rule requires all
# three sites in lockstep.
assert_contains "R3a fires on bare conf example" "R3a_conf_no_parser" "${result}"
assert_contains "R3b fires on bare conf example" "R3b_conf_no_config_table" "${result}"

setup_session "r3a_satisfied" "${EXEC_STATE}"
write_edits "r3a_satisfied" \
  /repo/bundle/dot-claude/oh-my-claude.conf.example \
  /repo/bundle/dot-claude/skills/autowork/scripts/common.sh
result="$(run_derive "r3a_satisfied")"
# common.sh satisfies R3a but R3b should still fire (omc-config.sh
# table not touched). This is the bug-fix case from the review.
assert_contains "R3b still fires when only parser touched" "R3b_conf_no_config_table" "${result}"
[[ "${result}" != *R3a_conf_no_parser* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: R3a satisfied by common.sh — actual=${result}" >&2; }

setup_session "r3b_satisfied" "${EXEC_STATE}"
write_edits "r3b_satisfied" \
  /repo/bundle/dot-claude/oh-my-claude.conf.example \
  /repo/bundle/dot-claude/skills/autowork/scripts/omc-config.sh
result="$(run_derive "r3b_satisfied")"
assert_contains "R3a still fires when only table touched" "R3a_conf_no_parser" "${result}"
[[ "${result}" != *R3b_conf_no_config_table* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: R3b satisfied by omc-config.sh — actual=${result}" >&2; }

setup_session "r3_full" "${EXEC_STATE}"
write_edits "r3_full" \
  /repo/bundle/dot-claude/oh-my-claude.conf.example \
  /repo/bundle/dot-claude/skills/autowork/scripts/common.sh \
  /repo/bundle/dot-claude/skills/autowork/scripts/omc-config.sh
result="$(run_derive "r3_full")"
[[ "${result}" != *R3a_conf_no_parser* && "${result}" != *R3b_conf_no_config_table* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: R3a+R3b silent when both parser sites touched — actual=${result}" >&2; }

# --- R4 migration without changelog ------------------------------------------

printf '\n--- R4: migration without changelog ---\n'

setup_session "r4a" "${EXEC_STATE}"
write_edits "r4a" /repo/db/migrations/202605_init.sql
result="$(run_derive "r4a")"
assert_eq "R4 fires on migration alone" "changelog|R4_migration_no_release" "${result}"

setup_session "r4b" "${EXEC_STATE}"
write_edits "r4b" /repo/db/migrations/202605_init.sql /repo/CHANGELOG.md
result="$(run_derive "r4b")"
assert_eq "R4 silent when CHANGELOG.md also touched" "|" "${result}"

# --- R5 substantial code without docs --------------------------------------

printf '\n--- R5: ≥4 code files but no doc edited ---\n'

setup_session "r5a" "${EXEC_STATE}"
write_edits "r5a" /repo/src/a.go /repo/src/b.go /repo/src/c.go /repo/src/d.go
result="$(run_derive "r5a")"
assert_contains "R5 fires on 4 code, 0 doc" "R5_code_no_docs" "${result}"

setup_session "r5b" "${EXEC_STATE}"
write_edits "r5b" /repo/src/a.go /repo/src/b.go /repo/src/c.go
result="$(run_derive "r5b")"
[[ "${result}" != *R5_code_no_docs* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: R5 silent on 3 code (under threshold) — actual=${result}" >&2; }

setup_session "r5c" "${EXEC_STATE}"
write_edits "r5c" /repo/src/a.go /repo/src/b.go /repo/src/c.go /repo/src/d.go /repo/README.md
result="$(run_derive "r5c")"
[[ "${result}" != *R5_code_no_docs* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: R5 silent when README touched — actual=${result}" >&2; }

setup_session "r5d" "${EXEC_STATE}"
write_edits "r5d" /repo/src/a.go /repo/src/b.go /repo/src/c.go /repo/src/d.go /repo/docs/architecture.md
result="$(run_derive "r5d")"
[[ "${result}" != *R5_code_no_docs* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: R5 silent when docs/* touched — actual=${result}" >&2; }

# --- Multi-rule co-firing ----------------------------------------------------

printf '\n--- Multi-rule firing ---\n'

setup_session "multi" "${EXEC_STATE}"
write_edits "multi" \
  /repo/src/auth.go /repo/src/payment.go \
  /repo/VERSION \
  /repo/bundle/dot-claude/oh-my-claude.conf.example
result="$(run_derive "multi")"
assert_contains "multi: R2 in rules" "R2_version_no_changelog" "${result}"
assert_contains "multi: R3a in rules" "R3a_conf_no_parser" "${result}"
assert_contains "multi: R3b in rules" "R3b_conf_no_config_table" "${result}"
[[ "${result}" != *R1_missing_tests* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: multi-rule inference must not restore retired R1 — actual=${result}" >&2; }

# --- Refresh gating: skip when not execution-intent --------------------------

printf '\n--- refresh_inferred_contract gating ---\n'

setup_session "adv" '{"task_intent":"advisory","task_domain":"coding"}'
write_edits "adv" /repo/src/a.go /repo/src/b.go
run_refresh "adv"
assert_eq "refresh skipped on advisory intent (no surfaces)" "" "$(read_state_key "adv" "inferred_contract_surfaces")"
assert_eq "refresh skipped on advisory intent (no rules)" "" "$(read_state_key "adv" "inferred_contract_rules")"

setup_session "writ" '{"task_intent":"execution","task_domain":"writing"}'
write_edits "writ" /repo/src/a.go /repo/src/b.go
run_refresh "writ"
assert_eq "refresh skipped on writing domain" "" "$(read_state_key "writ" "inferred_contract_rules")"

setup_session "fbd" '{"task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"forbidden"}'
write_edits "fbd" /repo/src/a.go /repo/src/b.go
run_refresh "fbd"
assert_eq "refresh with commit_mode=forbidden keeps tests non-inferred" "" "$(read_state_key "fbd" "inferred_contract_rules")"

setup_session "exec" "${EXEC_STATE}"
write_edits "exec" /repo/src/a.go /repo/src/b.go
run_refresh "exec"
assert_eq "refresh does not infer a test surface from code fan-out" "" "$(read_state_key "exec" "inferred_contract_surfaces")"
assert_eq "refresh does not infer a missing-test rule" "" "$(read_state_key "exec" "inferred_contract_rules")"
assert_not_empty "refresh stamps timestamp" "$(read_state_key "exec" "inferred_contract_ts")"

# --- Conf-flag opt-out -------------------------------------------------------

printf '\n--- conf-flag opt-out ---\n'

setup_session "off" "${EXEC_STATE}"
write_edits "off" /repo/src/a.go /repo/src/b.go
( export OMC_INFERRED_CONTRACT=off
  export SESSION_ID="off"
  . "${COMMON_SH}"
  refresh_inferred_contract )
assert_eq "refresh no-op when flag=off" "" "$(read_state_key "off" "inferred_contract_rules")"

result_off=$(
  export OMC_INFERRED_CONTRACT=off
  export SESSION_ID="off"
  . "${COMMON_SH}"
  inferred_contract_blocking_items
)
assert_empty "blocking_items empty when flag=off" "${result_off}"

summary_off=$(
  export OMC_INFERRED_CONTRACT=off
  export SESSION_ID="off"
  . "${COMMON_SH}"
  inferred_contract_summary
)
assert_eq "summary returns 'off' when flag=off" "off" "${summary_off}"

# --- Blocker messages --------------------------------------------------------

printf '\n--- blocker messages ---\n'

setup_session "msg" "${EXEC_STATE}"
write_edits "msg" /repo/src/a.go /repo/src/b.go /repo/VERSION
run_refresh "msg"
blockers="$(run_blockers "msg")"
assert_contains "blocker: R2 message" "VERSION bumped without release lockstep (R2)" "${blockers}"
[[ "${blockers}" != *"add or update tests"* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: blocker must not infer a test edit — actual=${blockers}" >&2; }

# --- Delivery action contract -----------------------------------------------

printf '\n--- delivery action recording + contract blockers ---\n'

setup_session "da1" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"required","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
blockers="$(run_delivery_blockers "da1")"
assert_contains "delivery: missing commit blocker" "create the requested commit" "${blockers}"
assert_contains "delivery: missing publish blocker" "push/tag/release/publish" "${blockers}"

run_delivery_action "da1" "git commit -m 'ship auth fix' && git push origin main" "pushed"
assert_eq "delivery: commit action recorded" "1" "$(read_state_key "da1" "commit_action_count")"
assert_eq "delivery: publish action recorded" "1" "$(read_state_key "da1" "publish_action_count")"
blockers="$(run_delivery_blockers "da1")"
assert_empty "delivery: commit+push action clears blockers" "${blockers}"

setup_session "da2" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da2" "git push --dry-run origin main" "dry run ok"
assert_eq "delivery: dry-run push does not record publish" "" "$(read_state_key "da2" "last_publish_action_ts")"
blockers="$(run_delivery_blockers "da2")"
assert_contains "delivery: dry-run push does not satisfy publish contract" "push/tag/release/publish" "${blockers}"

setup_session "da3" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3" "git push origin main" "exit code: 1"
assert_eq "delivery: failed push does not record publish" "" "$(read_state_key "da3" "last_publish_action_ts")"

setup_session "da3b" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
jq -nc --arg s "da3b" \
  '{session_id:$s,tool_name:"Bash",tool_input:{command:"git push origin main"},tool_response:{exit_code:1,output:"remote rejected"}}' \
  | bash "${RECORD_DELIVERY_ACTION_SH}" 2>/dev/null
assert_eq "delivery: structured exit_code failure does not record publish" "" "$(read_state_key "da3b" "last_publish_action_ts")"

setup_session "da3c" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3c" "git tag" "v1.0.0"
assert_eq "delivery: bare tag listing does not record publish" "" "$(read_state_key "da3c" "last_publish_action_ts")"
run_delivery_action "da3c" "git tag --ignore-case --force v2.0.0" "created"
assert_eq "delivery: ignore-case cannot hide forced tag publication" "1" "$(read_state_key "da3c" "publish_action_count")"

setup_session "da3d" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3d" "git tag v2.0.0 --sort=refname" "created"
assert_eq "delivery: name-first display option still records tag publication" "1" "$(read_state_key "da3d" "publish_action_count")"

setup_session "da3e" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3e" "git tag --format='foo|bar;baz&&qux'" "foo|bar;baz&&qux"
assert_eq "delivery: quoted separators in display format do not record publication" "" "$(read_state_key "da3e" "last_publish_action_ts")"
run_delivery_action "da3e" "git tag --format='foo|bar;baz&&qux' v2.0.1" "created"
assert_eq "delivery: quoted separators cannot hide positional tag publication" "1" "$(read_state_key "da3e" "publish_action_count")"

setup_session "da3f" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3f" "git tag --list & git tag newtag" "created"
assert_eq "delivery: background separator cannot hide tag publication" "1" "$(read_state_key "da3f" "publish_action_count")"

setup_session "da3g" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3g" "echo prefix git tag v1" "prefix git tag v1"
run_delivery_action "da3g" "printf %s git commit -m x" "gitcommit-mx"
run_delivery_action "da3g" "printf '%s' ' gh release create v1'" " gh release create v1"
run_delivery_action "da3g" $'printf "%s" "hello\n git tag v1"' $'hello\n git tag v1'
assert_eq "delivery: command-like arguments cannot spoof delivery evidence" "" "$(read_state_key "da3g" "last_publish_action_ts")$(read_state_key "da3g" "last_commit_action_ts")"

setup_session "da3h" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h" 'git tag --list "$(git tag nested-one)"' "created"
run_delivery_action "da3h" 'git tag --list $(git tag nested-two)' "created"
run_delivery_action "da3h" 'git tag --list `git tag nested-three`' "created"
run_delivery_action "da3h" 'git tag --list <(git tag nested-four)' "created"
assert_eq "delivery: nested actions under read-only outer commands are not evidence" "" "$(read_state_key "da3h" "publish_action_count")"

setup_session "da3h-fail" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h-fail" 'git tag --list "$(git tag --delete definitely-missing)"' \
  "fatal: tag 'definitely-missing' not found"
assert_eq "delivery: masked nested failure cannot fabricate publication" "" "$(read_state_key "da3h-fail" "publish_action_count")"

setup_session "da3h-direct" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"required","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h-direct" 'git tag --list "$(date +%s)"' ""
assert_eq "delivery: benign substitution does not make tag listing a publish" "" "$(read_state_key "da3h-direct" "publish_action_count")"
run_delivery_action "da3h-direct" 'git commit -m "$(date +%s)"' "committed"
run_delivery_action "da3h-direct" 'git tag "v$(date +%s)"' "created"
assert_eq "delivery: benign substitution preserves direct commit evidence" "1" "$(read_state_key "da3h-direct" "commit_action_count")"
assert_eq "delivery: benign substitution preserves direct publish evidence" "1" "$(read_state_key "da3h-direct" "publish_action_count")"

setup_session "da3h-dry" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"required","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h-dry" 'git commit -a --dry-run' "dry run"
run_delivery_action "da3h-dry" 'git commit -S --dry-run' "dry run"
run_delivery_action "da3h-dry" 'git commit --gpg-sign --dry-run' "dry run"
run_delivery_action "da3h-dry" 'git push origin main -n' "dry run"
run_delivery_action "da3h-dry" 'git push --signed --dry-run origin main' "dry run"
run_delivery_action "da3h-dry" 'git push --recurse-submodules --dry-run origin main' "dry run"
assert_eq "delivery: later and optional-argument dry-run flags are not commit evidence" "" "$(read_state_key "da3h-dry" "commit_action_count")"
assert_eq "delivery: later and optional-argument dry-run flags are not publish evidence" "" "$(read_state_key "da3h-dry" "publish_action_count")"

setup_session "da3h-values" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"required","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h-values" 'git commit -m --dry-run --allow-empty' "committed"
run_delivery_action "da3h-values" 'git commit -am --dry-run --allow-empty' "committed"
run_delivery_action "da3h-values" 'git push -o -n origin main' "pushed"
run_delivery_action "da3h-values" 'git push -fo -n origin main' "pushed"
assert_eq "delivery: dry-run-looking commit option values remain commit evidence" "2" "$(read_state_key "da3h-values" "commit_action_count")"
assert_eq "delivery: dry-run-looking push option values remain publish evidence" "2" "$(read_state_key "da3h-values" "publish_action_count")"

setup_session "da3h-status" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"required","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h-status" 'true || git tag skipped-one' ""
run_delivery_action "da3h-status" 'false && git tag skipped-two; true' ""
run_delivery_action "da3h-status" 'git tag --delete definitely-missing; true' ""
run_delivery_action "da3h-status" 'if false; then git tag skipped-three; fi' ""
run_delivery_action "da3h-status" 'while false; do git commit -m skipped; done' ""
quoted_heredoc="$(printf '%s\n' "cat <<'EOF'" '$(git tag heredoc-fake)' 'EOF')"
run_delivery_action "da3h-status" "${quoted_heredoc}" "git tag heredoc-fake"
assert_eq "delivery: skipped, masked-failure, control, and heredoc actions are not commit evidence" "" "$(read_state_key "da3h-status" "commit_action_count")"
assert_eq "delivery: skipped, masked-failure, control, and heredoc actions are not publish evidence" "" "$(read_state_key "da3h-status" "publish_action_count")"

setup_session "da3h-wrapper" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3h-wrapper" 'env -iuFOO git tag env-cluster-new' "created"
run_delivery_action "da3h-wrapper" 'sudo -EHus git tag sudo-cluster-new' "created"
run_delivery_action "da3h-wrapper" 'exec -claPROBE git tag exec-cluster-new' "created"
run_delivery_action "da3h-wrapper" '/usr/bin/time -po /tmp/time.out git tag time-cluster-new' "created"
assert_eq "delivery: mixed/attached wrapper clusters preserve direct publication evidence" "4" "$(read_state_key "da3h-wrapper" "publish_action_count")"

segment_shapes="$(
  . "${COMMON_SH}"
  for command in 'printf x |& sed s/x/y/' 'printf x &>out' 'printf x &>>out' \
      'printf x >&2' 'printf x 2>&1' 'read x <&0'; do
    count=0
    while IFS= read -r -d '' _segment; do count=$((count + 1)); done \
      < <(omc_shell_compound_segments "${command}")
    printf '%s,' "${count}"
  done
)"
assert_eq "delivery parser preserves pipe-stderr and redirect operators" "2,1,1,1,1,1," "${segment_shapes}"

setup_session "da3i" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3i" "sudo git tag --list" "v1.0.0"
run_delivery_action "da3i" "env git tag --format='foo|bar'" "foo|bar"
assert_eq "delivery: wrapped read-only tags do not record publication" "" "$(read_state_key "da3i" "last_publish_action_ts")"
run_delivery_action "da3i" "sudo git tag wrapped-new" "created"
assert_eq "delivery: wrapped tag creation records publication" "1" "$(read_state_key "da3i" "publish_action_count")"

setup_session "da3j" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3j" "env -u FOO git tag env-unset-new" "created"
run_delivery_action "da3j" "env -C /tmp git tag env-chdir-new" "created"
run_delivery_action "da3j" "command -p git tag command-new" "created"
run_delivery_action "da3j" "sudo -n git tag sudo-new" "created"
assert_eq "delivery: standard wrapper options retain publication evidence" "4" "$(read_state_key "da3j" "publish_action_count")"

setup_session "da3k" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3k" "'/usr/bin/git' tag quoted-path-new" "created"
run_delivery_action "da3k" "FOO='a b' git tag assignment-new" "created"
run_delivery_action "da3k" "env 'FOO=a b' git tag env-assignment-new" "created"
assert_eq "delivery: quoted executable/assignment launch forms retain evidence" "3" "$(read_state_key "da3k" "publish_action_count")"

setup_session "da3l" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3l" "env -S 'git tag split-new'" "created"
assert_eq "delivery: opaque env split-string body cannot fabricate evidence" "" "$(read_state_key "da3l" "last_publish_action_ts")"

setup_session "da3m" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3m" 'echo "$(git tag nested-tag)"' "nested-tag"
run_delivery_action "da3m" 'printf %s "$(git push --force)"' "pushed"
run_delivery_action "da3m" "sh -c 'git tag shell-tag'" "created"
run_delivery_action "da3m" "eval 'git tag eval-tag'" "created"
run_delivery_action "da3m" "bash -lc 'git tag combined-option-tag'" "created"
run_delivery_action "da3m" "timeout 5 sh -c 'git tag timeout-tag'" "created"
run_delivery_action "da3m" "sh -c 'git -c foo.bar=baz tag option-tag'" "created"
run_delivery_action "da3m" "command env -S 'git tag split-tag'" "created"
run_delivery_action "da3m" '$(printf git) tag substitution-executable' "created"
run_delivery_action "da3m" 'git $(printf tag) substitution-verb' "created"
assert_eq "delivery: nested executors do not fabricate direct-action evidence" "" "$(read_state_key "da3m" "last_publish_action_ts")"

setup_session "da3n" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_push_mode":"required","done_contract_updated_ts":"100","session_start_ts":"50"}'
run_delivery_action "da3n" "sudo -- git tag sudo-end-new" "created"
run_delivery_action "da3n" "sudo --user root git tag sudo-user-new" "created"
run_delivery_action "da3n" "sudo -i git tag sudo-login-new" "created"
run_delivery_action "da3n" "sudo -p prompt git tag sudo-prompt-new" "created"
assert_eq "delivery: standard sudo option forms retain publication evidence" "4" "$(read_state_key "da3n" "publish_action_count")"

setup_session "da4" '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","done_contract_commit_mode":"required","done_contract_updated_ts":"200","session_start_ts":"50","last_commit_action_ts":"150","commit_action_count":"1"}'
blockers="$(run_delivery_blockers "da4")"
assert_contains "delivery: stale commit action does not satisfy fresh prompt" "create the requested commit" "${blockers}"
run_delivery_action "da4" "git commit -m 'fresh prompt commit'" "committed"
blockers="$(run_delivery_blockers "da4")"
assert_empty "delivery: fresh commit action clears commit blocker" "${blockers}"

# --- mark-edit triggers refresh on new unique paths --------------------------

printf '\n--- mark-edit refreshes inferred contract ---\n'

setup_session "me" "${EXEC_STATE}"
HOOK_INPUT_1=$(jq -nc '{session_id:"me",tool_input:{file_path:"/repo/src/foo.go"}}')
HOOK_INPUT_2=$(jq -nc '{session_id:"me",tool_input:{file_path:"/repo/src/bar.go"}}')

printf '%s' "${HOOK_INPUT_1}" | bash "${MARK_EDIT_SH}" 2>/dev/null
printf '%s' "${HOOK_INPUT_2}" | bash "${MARK_EDIT_SH}" 2>/dev/null

assert_eq "mark-edit: 2 unique code edits do not infer tests" "" "$(read_state_key "me" "inferred_contract_rules")"

# Re-edit the same path — should NOT refresh (no new unique path)
prior_ts="$(read_state_key "me" "inferred_contract_ts")"
sleep 1
printf '%s' "${HOOK_INPUT_1}" | bash "${MARK_EDIT_SH}" 2>/dev/null
new_ts="$(read_state_key "me" "inferred_contract_ts")"
assert_eq "mark-edit: dup path does NOT refresh ts" "${prior_ts}" "${new_ts}"

# --- Real-user-task simulations ----------------------------------------------
# Each block models a user task whose prompt does NOT explicitly name
# tests / changelog / parser-lockstep / release notes — exactly the
# user's stated motivation for v2.

printf '\n--- real-user-task simulations ---\n'

# Task 1: "Fix the auth bug." Two files edited; fresh verification is
# still required elsewhere, but a new test file is not inferred.
setup_session "rt1" '{"task_intent":"execution","task_domain":"coding","done_contract_prompt_surfaces":"","done_contract_commit_mode":"unspecified","last_user_prompt_ts":"100"}'
write_edits "rt1" /repo/src/auth/login.go /repo/src/auth/session.go
run_refresh "rt1"
assert_eq "real-task 'fix bug' does not force a new test file" "" "$(read_state_key "rt1" "inferred_contract_rules")"

# Task 2: "Bump to v1.34.0." User edits VERSION but forgets CHANGELOG.
setup_session "rt2" '{"task_intent":"execution","task_domain":"coding","done_contract_prompt_surfaces":"","done_contract_commit_mode":"required","last_user_prompt_ts":"100"}'
write_edits "rt2" /repo/VERSION
run_refresh "rt2"
assert_eq "real-task 'bump version' → R2 fires" "R2_version_no_changelog" "$(read_state_key "rt2" "inferred_contract_rules")"

# Task 3: "Add a debounce flag." Conf example edited, parser AND table forgotten.
setup_session "rt3" '{"task_intent":"execution","task_domain":"coding","done_contract_prompt_surfaces":"config","done_contract_commit_mode":"unspecified","last_user_prompt_ts":"100"}'
write_edits "rt3" /repo/bundle/dot-claude/oh-my-claude.conf.example
run_refresh "rt3"
rules_rt3="$(read_state_key "rt3" "inferred_contract_rules")"
assert_contains "real-task 'add config flag' → R3a fires" "R3a_conf_no_parser" "${rules_rt3}"
assert_contains "real-task 'add config flag' → R3b fires" "R3b_conf_no_config_table" "${rules_rt3}"

# Task 4: "Add a contracts table." Migration without changelog.
setup_session "rt4" '{"task_intent":"execution","task_domain":"coding","done_contract_prompt_surfaces":"migration","done_contract_commit_mode":"unspecified","last_user_prompt_ts":"100"}'
write_edits "rt4" /repo/db/migrations/202605010001_contracts.sql
run_refresh "rt4"
assert_eq "real-task 'add migration' → R4 fires" "R4_migration_no_release" "$(read_state_key "rt4" "inferred_contract_rules")"

# Task 5: clean session — only docs touched, no inference rule should fire.
setup_session "rt5" "${EXEC_STATE}"
write_edits "rt5" /repo/README.md /repo/docs/architecture.md
run_refresh "rt5"
assert_eq "real-task 'doc-only' → no rule fires" "" "$(read_state_key "rt5" "inferred_contract_rules")"

# --- F10 — verify the brief premise: prompt does NOT name surface --------
# These cases pipe natural-language prompts through the prompt-surface
# deriver, then verify that inferred lockstep rules do not invent a test
# edit when the prompt did not request one.

printf '\n--- F10: prompt-NL did not name the surface, v2 catches it ---\n'

derive_prompt_surfaces() {
  ( . "${COMMON_SH}"
    derive_done_contract_prompt_surfaces "$1" )
}

# "fix the auth bug" — prompt names neither tests nor docs nor changelog.
nl_prompt_1="fix the auth bug in login and session"
prompt_surfaces_1="$(derive_prompt_surfaces "${nl_prompt_1}")"
assert_eq "F10: prompt 'fix bug' yields no prompt-side surfaces" "" "${prompt_surfaces_1}"
# Now simulate the work — 2 code files, no test. No inferred test
# surface should be created.
setup_session "f10a" "${EXEC_STATE}"
write_edits "f10a" /repo/src/auth/login.go /repo/src/auth/session.go
run_refresh "f10a"
assert_eq "F10: inference does not manufacture test work" "" "$(read_state_key "f10a" "inferred_contract_rules")"

# "bump the version" — prompt names release/version but not changelog
# (depending on regex). Run the actual prompt deriver to see what
# surface IS extracted, then verify v2 catches the missing-changelog
# even when the prompt's "release" surface is detected.
nl_prompt_2="bump the version to v1.34.0"
prompt_surfaces_2="$(derive_prompt_surfaces "${nl_prompt_2}")"
# Whatever v1 extracts (could be "release" or empty), v2's R2 fires
# specifically on the VERSION-without-CHANGELOG-edit shape.
setup_session "f10b" "${EXEC_STATE}"
write_edits "f10b" /repo/VERSION
run_refresh "f10b"
assert_eq "F10: v2 catches VERSION-without-CHANGELOG (R2 fires)" "R2_version_no_changelog" "$(read_state_key "f10b" "inferred_contract_rules")"

# "implement a debounce flag for the input" — prompt names neither
# config/parser-lockstep nor anything that derives `config` surface.
nl_prompt_3="implement a debounce flag for the input"
prompt_surfaces_3="$(derive_prompt_surfaces "${nl_prompt_3}")"
assert_eq "F10: prompt 'implement debounce' yields no surfaces" "" "${prompt_surfaces_3}"
setup_session "f10c" "${EXEC_STATE}"
write_edits "f10c" /repo/bundle/dot-claude/oh-my-claude.conf.example
run_refresh "f10c"
rules_f10c="$(read_state_key "f10c" "inferred_contract_rules")"
assert_contains "F10: v2 catches conf example without parser (R3a)" "R3a_conf_no_parser" "${rules_f10c}"
assert_contains "F10: v2 catches conf example without table (R3b)" "R3b_conf_no_config_table" "${rules_f10c}"

# --- Skip path coverage ------------------------------------------------------

printf '\n--- inference skips state/git internals ---\n'

setup_session "skip" "${EXEC_STATE}"
write_edits "skip" \
  "${TEST_HOME}/.claude/quality-pack/state/skip/something.log" \
  /repo/.git/HEAD \
  /repo/src/real_a.go \
  /repo/src/real_b.go
result="$(run_derive "skip")"
assert_eq "skip-paths plus two code files do not infer tests" "|" "${result}"

# --- Final ------------------------------------------------------------------

printf '\n=== Inferred Contract Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
