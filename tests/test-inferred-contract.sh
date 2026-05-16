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

# Vendor/build paths should not pollute R1 code count.
setup_session "skip_vendor" "${EXEC_STATE}"
write_edits "skip_vendor" \
  /repo/node_modules/foo/index.js \
  /repo/vendor/lib/bar.go \
  /repo/dist/main.js \
  /repo/src/real_only.go
result="$(run_derive "skip_vendor")"
[[ "${result}" != *R1_missing_tests* ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "  FAIL: vendor/dist paths bypass R1 (1 real code file is below threshold) — actual=${result}" >&2; }

# --- R1 missing tests --------------------------------------------------------

printf '\n--- R1: code edited but no test edited ---\n'

setup_session "r1a" "${EXEC_STATE}"
write_edits "r1a" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1a")"
assert_eq "R1 fires on 2 code, 0 test, no verify" "tests|R1_missing_tests" "${result}"

setup_session "r1b" "${EXEC_STATE}"
write_edits "r1b" /repo/src/auth.go
result="$(run_derive "r1b")"
assert_eq "R1 silent on 1 code (under threshold)" "|" "${result}"

setup_session "r1c" "${EXEC_STATE}"
write_edits "r1c" /repo/src/auth.go /repo/src/payment.go /repo/tests/test-auth.go
result="$(run_derive "r1c")"
assert_eq "R1 silent when test file edited too" "|" "${result}"

setup_session "r1d" '{"task_intent":"execution","task_domain":"coding","last_code_edit_ts":"100","last_verify_ts":"200","last_verify_outcome":"passed","last_verify_confidence":"70"}'
write_edits "r1d" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1d")"
assert_eq "R1 satisfied by passing high-conf verify after edits" "|" "${result}"

setup_session "r1d_scope" '{"task_intent":"execution","task_domain":"coding","last_code_edit_ts":"100","last_verify_ts":"200","last_verify_outcome":"passed","last_verify_confidence":"70","last_verify_scope":"lint"}'
write_edits "r1d_scope" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1d_scope")"
assert_eq "R1 fires when fresh high-conf verification is lint scope" "tests|R1_missing_tests" "${result}"

setup_session "r1d_targeted" '{"task_intent":"execution","task_domain":"coding","last_code_edit_ts":"100","last_verify_ts":"200","last_verify_outcome":"passed","last_verify_confidence":"70","last_verify_scope":"targeted"}'
write_edits "r1d_targeted" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1d_targeted")"
assert_eq "R1 satisfied by targeted verification scope" "|" "${result}"

setup_session "r1e" '{"task_intent":"execution","task_domain":"coding","last_code_edit_ts":"300","last_verify_ts":"200","last_verify_outcome":"passed","last_verify_confidence":"70"}'
write_edits "r1e" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1e")"
assert_eq "R1 fires when verify is stale (predates edit)" "tests|R1_missing_tests" "${result}"

setup_session "r1f" '{"task_intent":"execution","task_domain":"coding","last_code_edit_ts":"100","last_verify_ts":"200","last_verify_outcome":"failed","last_verify_confidence":"70"}'
write_edits "r1f" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1f")"
assert_eq "R1 fires when verify failed" "tests|R1_missing_tests" "${result}"

setup_session "r1g" '{"task_intent":"execution","task_domain":"coding","last_code_edit_ts":"100","last_verify_ts":"200","last_verify_outcome":"passed","last_verify_confidence":"30"}'
write_edits "r1g" /repo/src/auth.go /repo/src/payment.go
result="$(run_derive "r1g")"
assert_eq "R1 fires when verify confidence below threshold" "tests|R1_missing_tests" "${result}"

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
assert_contains "multi: R1 in surfaces" "tests" "${result}"
assert_contains "multi: R2 in rules" "R2_version_no_changelog" "${result}"
assert_contains "multi: R3a in rules" "R3a_conf_no_parser" "${result}"
assert_contains "multi: R3b in rules" "R3b_conf_no_config_table" "${result}"
assert_contains "multi: R1 in rules" "R1_missing_tests" "${result}"

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
assert_eq "refresh still applies when commit_mode=forbidden" "R1_missing_tests" "$(read_state_key "fbd" "inferred_contract_rules")"

setup_session "exec" "${EXEC_STATE}"
write_edits "exec" /repo/src/a.go /repo/src/b.go
run_refresh "exec"
assert_eq "refresh applies on execution intent (surfaces)" "tests" "$(read_state_key "exec" "inferred_contract_surfaces")"
assert_eq "refresh applies on execution intent (rules)" "R1_missing_tests" "$(read_state_key "exec" "inferred_contract_rules")"
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
assert_contains "blocker: R1 message names count" "R1: 2 code files, 0 test files" "${blockers}"
assert_contains "blocker: R1 message names files (auditability)" "e.g. /repo/src/a.go" "${blockers}"
assert_contains "blocker: R2 message" "VERSION bumped without release lockstep (R2)" "${blockers}"

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

assert_eq "mark-edit: 2 unique edits → R1 in state" "R1_missing_tests" "$(read_state_key "me" "inferred_contract_rules")"

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

# Task 1: "Fix the auth bug." Two files edited, no test added.
setup_session "rt1" '{"task_intent":"execution","task_domain":"coding","done_contract_prompt_surfaces":"","done_contract_commit_mode":"unspecified","last_user_prompt_ts":"100"}'
write_edits "rt1" /repo/src/auth/login.go /repo/src/auth/session.go
run_refresh "rt1"
assert_eq "real-task 'fix bug' → R1 fires" "R1_missing_tests" "$(read_state_key "rt1" "inferred_contract_rules")"

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
# These cases pipe natural-language prompts through the v1 deriver
# (`derive_done_contract_prompt_surfaces`) to confirm v1 extracts NO
# surface from the wording, then verify v2's inference fills the gap.
# Without this layer the rt1-rt5 simulations only assert state, not
# the "prompt does not name the surface" premise the user asked for.

printf '\n--- F10: prompt-NL did not name the surface, v2 catches it ---\n'

derive_prompt_surfaces() {
  ( . "${COMMON_SH}"
    derive_done_contract_prompt_surfaces "$1" )
}

# "fix the auth bug" — prompt names neither tests nor docs nor changelog.
nl_prompt_1="fix the auth bug in login and session"
prompt_surfaces_1="$(derive_prompt_surfaces "${nl_prompt_1}")"
assert_eq "F10: prompt 'fix bug' yields no prompt-side surfaces" "" "${prompt_surfaces_1}"
# Now simulate the work — 2 code files, no test. v2 R1 should fill the gap.
setup_session "f10a" "${EXEC_STATE}"
write_edits "f10a" /repo/src/auth/login.go /repo/src/auth/session.go
run_refresh "f10a"
assert_eq "F10: v2 inference fills the gap (R1 fires)" "R1_missing_tests" "$(read_state_key "f10a" "inferred_contract_rules")"

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
assert_eq "skip-paths excluded from code count" "tests|R1_missing_tests" "${result}"

# --- Final ------------------------------------------------------------------

printf '\n=== Inferred Contract Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
