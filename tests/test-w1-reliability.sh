#!/usr/bin/env bash
# v1.36.x Wave 1 reliability hardening regression tests.
#
# Covers F-001 (record-finding-list + record-scope-checklist locks routed
# through with_findings_lock / with_exemplifying_scope_checklist_lock,
# inheriting PID-stale recovery from _with_lockdir), F-002 (hooks.log lock
# + recursion guard + 3500-byte detail cap), F-003 (directive_budget=off
# hard cap on chars/count), F-004 (resume-request scan caps at
# OMC_RESUME_SCAN_MAX_SESSIONS), F-005 (omc_check_install_drift bash
# port returning tag: / commits: descriptors).

# Note: deliberately not using `set -e` — each assert handles its own
# failure path. set -u stays on to catch typos in fixture variables.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
FINDING_LIST="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-finding-list.sh"
SCOPE_CHECKLIST="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-scope-checklist.sh"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
export STATE_ROOT="${TEST_TMP}/state"
mkdir -p "${STATE_ROOT}"

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); }
fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# F-001 — record-finding-list.sh + record-scope-checklist.sh route
# through with_findings_lock / with_exemplifying_scope_checklist_lock.
# Verify: (a) helpers exist in common.sh; (b) the scripts no longer
# define the legacy _acquire_lock; (c) PID-stale reclaim works end-to-end.
# ----------------------------------------------------------------------
printf '\n--- F-001: lock helpers exist + scripts use them ---\n'

if grep -q "^with_findings_lock()" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-001: with_findings_lock missing from common.sh"
fi

if grep -q "^with_exemplifying_scope_checklist_lock()" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-001: with_exemplifying_scope_checklist_lock missing from common.sh"
fi

if grep -qE '^[[:space:]]*_acquire_lock\(\)' "${FINDING_LIST}"; then
  fail_msg "F-001: record-finding-list.sh still defines _acquire_lock (refactor incomplete)"
else
  ok
fi

if grep -qE '^[[:space:]]*_acquire_lock\(\)' "${SCOPE_CHECKLIST}"; then
  fail_msg "F-001: record-scope-checklist.sh still defines _acquire_lock (refactor incomplete)"
else
  ok
fi

if grep -q "with_findings_lock _do_" "${FINDING_LIST}"; then
  ok
else
  fail_msg "F-001: record-finding-list.sh does not invoke with_findings_lock"
fi

if grep -q "with_exemplifying_scope_checklist_lock _do_" "${SCOPE_CHECKLIST}"; then
  ok
else
  fail_msg "F-001: record-scope-checklist.sh does not invoke with_exemplifying_scope_checklist_lock"
fi

# End-to-end: orphan a lockdir under a dead PID, confirm next caller
# reclaims it instead of timing out for the full retry budget.
printf '\n--- F-001: orphaned-lock PID reclaim end-to-end ---\n'
mkdir -p "${STATE_ROOT}/f001-session"
findings_path_test="${STATE_ROOT}/f001-session/findings.json"
findings_lock_test="${findings_path_test}.lock"
echo '[]' > "${findings_path_test}"
mkdir -p "${findings_lock_test}"
# PID 1 always exists but is owned by init/launchd. The kill -0 in
# _with_lockdir reads the pidfile and tests liveness; an unused-but-
# unrelated PID would defeat the test. The realistic shape is "the
# pidfile is empty or missing", which the helper treats as legacy
# stale and reclaims after stale-secs elapse.
: > "${findings_lock_test}/holder.pid"
# Backdate the lockdir mtime past the stale window so the PID-empty
# branch fires on the very next acquire. Use a recent-but-stale time
# (1 hour ago) — _with_lockdir's predicate requires held_since > 0,
# so an epoch-0 stamp (`touch -t 197001010000` → 0) defeats the test.
old_ts=$(($(date +%s) - 3600))
old_iso="$(date -r "${old_ts}" '+%Y%m%d%H%M' 2>/dev/null \
  || date -d "@${old_ts}" '+%Y%m%d%H%M' 2>/dev/null)"
touch -t "${old_iso}" "${findings_lock_test}" 2>/dev/null || true

# Run record-finding-list.sh init under the same fixture session. The
# script's session discovery walks STATE_ROOT for the most recent dir;
# we override SESSION_ID to pin it to f001-session.
init_payload='[
  {"id":"F-001-a","summary":"reclaim-test","severity":"medium","surface":"test"}
]'
SESSION_ID=f001-session bash "${FINDING_LIST}" init --force <<<"${init_payload}" >/dev/null 2>&1 \
  && ok || fail_msg "F-001: PID-stale reclaim did not allow init to proceed"

if [[ ! -d "${findings_lock_test}" ]] && [[ -f "${findings_path_test}" ]]; then
  ok
else
  fail_msg "F-001: lockdir not cleaned up after _with_lockdir reclaim"
fi

# ----------------------------------------------------------------------
# F-002 — hooks.log routes through with_cross_session_log_lock + has
# a recursion guard + caps detail at 3500 bytes.
# ----------------------------------------------------------------------
printf '\n--- F-002: hooks.log lock + recursion guard + detail cap ---\n'

if grep -q "_OMC_HOOK_LOG_RECURSION" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-002: _OMC_HOOK_LOG_RECURSION recursion guard missing"
fi

if grep -q "with_cross_session_log_lock \"\${HOOK_LOG}\"" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-002: _write_hook_log does not invoke with_cross_session_log_lock on HOOK_LOG"
fi

# Detail cap — load common.sh and call _write_hook_log with a 4500-byte
# string; verify the on-disk row's tail is the truncation marker. The
# function derives HOOK_LOG from STATE_ROOT at source time (common.sh:7),
# so the assertion reads ${STATE_ROOT}/hooks.log, not a custom HOOK_LOG.
test_log_dir="${TEST_TMP}/hooks-log-test"
mkdir -p "${test_log_dir}"
bash -c "
  set +u
  STATE_ROOT='${test_log_dir}'
  source '${COMMON_SH}'
  long_detail=\"\$(printf 'x%.0s' \$(seq 1 4500))\"
  _write_hook_log 'test' 'detail-cap-test' \"\${long_detail}\"
"

if [[ -f "${test_log_dir}/hooks.log" ]] && grep -q '…truncated' "${test_log_dir}/hooks.log"; then
  ok
else
  fail_msg "F-002: long detail string was not truncated with …truncated marker"
fi

# Recursion guard: the bare-append fallback must execute without
# stack-blowing when _OMC_HOOK_LOG_RECURSION=1 is exported.
test_log_dir2="${TEST_TMP}/hooks-recursion-test"
mkdir -p "${test_log_dir2}"
bash -c "
  set +u
  export _OMC_HOOK_LOG_RECURSION=1
  STATE_ROOT='${test_log_dir2}'
  source '${COMMON_SH}'
  _write_hook_log 'recursion-test' 'guard-fallback' 'short-detail'
" && ok || fail_msg "F-002: recursion-guard bare-append path failed"

if grep -q "guard-fallback" "${test_log_dir2}/hooks.log" 2>/dev/null; then
  ok
else
  fail_msg "F-002: recursion-guard fallback did not write the row"
fi

# ----------------------------------------------------------------------
# F-003 — directive_budget=off has a hard ceiling.
# ----------------------------------------------------------------------
printf '\n--- F-003: directive_budget=off hard cap ---\n'

if grep -q "directive_budget_off_hard_cap" "${ROUTER}"; then
  ok
else
  fail_msg "F-003: directive_budget_off_hard_cap helper missing"
fi

if grep -q "off_mode_count_cap\|off_mode_char_cap" "${ROUTER}"; then
  ok
else
  fail_msg "F-003: off-mode suppression reasons not emitted"
fi

# Numeric values: 12000 chars / 12 count. Sourcing the router directly
# is unreliable (its top-level code reads HOOK_JSON from stdin, may
# short-circuit on side effects); extract the function definition into
# a temp file and source that.
off_helper="${TEST_TMP}/off_helper.sh"
sed -n '/^directive_budget_off_hard_cap()/,/^}$/p' "${ROUTER}" > "${off_helper}"
off_chars="$(bash -c "source '${off_helper}'; directive_budget_off_hard_cap chars" 2>/dev/null || true)"
if [[ "${off_chars}" == "12000" ]]; then
  ok
else
  fail_msg "F-003: off-mode char cap should be 12000 (got: ${off_chars})"
fi

off_count="$(bash -c "source '${off_helper}'; directive_budget_off_hard_cap count" 2>/dev/null || true)"
if [[ "${off_count}" == "12" ]]; then
  ok
else
  fail_msg "F-003: off-mode count cap should be 12 (got: ${off_count})"
fi

# ----------------------------------------------------------------------
# F-004 — find_claimable_resume_requests caps the candidate scan at
# OMC_RESUME_SCAN_MAX_SESSIONS most-recently-modified session dirs.
# ----------------------------------------------------------------------
printf '\n--- F-004: resume-scan max-sessions cap ---\n'

if grep -q "OMC_RESUME_SCAN_MAX_SESSIONS" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-004: OMC_RESUME_SCAN_MAX_SESSIONS env not honored"
fi

# Build 50 fake session dirs each with a resume_request.json. Set the
# cap to 5; verify only 5 candidates are emitted.
f004_state="${TEST_TMP}/f004-state"
mkdir -p "${f004_state}"
now_ts="$(date +%s)"
for i in $(seq 1 50); do
  sdir="${f004_state}/$(printf '%032d' "${i}" | sed 's/.\{8\}/&-/g; s/-$//')"
  # Make IDs match validate_session_id: hex + dashes, 32 chars + 4 dashes
  sdir="${f004_state}/$(printf 'aaaaaaaa-bbbb-cccc-dddd-%012d' "${i}")"
  mkdir -p "${sdir}"
  jq -n --argjson ts "$((now_ts - i))" \
    '{schema_version:1, captured_at_ts:$ts, cwd:"/tmp/f004", project_key:"k", original_objective:"x", last_user_prompt:"y", matcher:"Stop"}' \
    > "${sdir}/resume_request.json"
done

# Run find_claimable_resume_requests with cap=5. Bash needs to source
# common.sh to pick up the function.
candidate_count="$(STATE_ROOT="${f004_state}" \
  OMC_RESUME_SCAN_MAX_SESSIONS=5 \
  bash -c "source '${COMMON_SH}'; find_claimable_resume_requests | wc -l")"
candidate_count="${candidate_count//[!0-9]/}"

if [[ "${candidate_count}" -le 5 ]] && [[ "${candidate_count}" -gt 0 ]]; then
  ok
else
  fail_msg "F-004: expected ≤5 candidates with cap=5, got ${candidate_count}"
fi

# Default cap (30) returns all 50? No — capped at 30.
candidate_count_default="$(STATE_ROOT="${f004_state}" \
  bash -c "source '${COMMON_SH}'; find_claimable_resume_requests | wc -l")"
candidate_count_default="${candidate_count_default//[!0-9]/}"
if [[ "${candidate_count_default}" -le 30 ]] && [[ "${candidate_count_default}" -gt 0 ]]; then
  ok
else
  fail_msg "F-004: default cap should yield ≤30 candidates, got ${candidate_count_default}"
fi

# ----------------------------------------------------------------------
# F-005 — omc_check_install_drift returns tag:<v> or commits:<v>:<n>
# from a fixture conf+repo.
# ----------------------------------------------------------------------
printf '\n--- F-005: omc_check_install_drift output shape ---\n'

if grep -q "^omc_check_install_drift()" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-005: omc_check_install_drift function missing"
fi

# Fixture: a fake repo with VERSION=1.99.0, conf with installed_version=1.36.0.
# Expect tag:1.99.0.
f005_repo="${TEST_TMP}/f005-repo"
mkdir -p "${f005_repo}"
echo '1.99.0' > "${f005_repo}/VERSION"
f005_home="${TEST_TMP}/f005-home"
mkdir -p "${f005_home}/.claude"
cat > "${f005_home}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.36.0
repo_path=${f005_repo}
EOF

drift_result="$(HOME="${f005_home}" \
  bash -c "source '${COMMON_SH}'; omc_check_install_drift")"
if [[ "${drift_result}" == "tag:1.99.0" ]]; then
  ok
else
  fail_msg "F-005: tag-ahead branch should return 'tag:1.99.0', got: ${drift_result}"
fi

# Fixture: VERSION matches but commits-ahead via a real git repo.
f005_git="${TEST_TMP}/f005-git"
mkdir -p "${f005_git}"
(
  cd "${f005_git}" || exit 1
  git init -q
  git config user.email t@t
  git config user.name t
  echo '1.36.0' > VERSION
  git add VERSION
  git commit -q -m "v1.36.0"
  initial_sha="$(git rev-parse HEAD)"
  echo "x" > new.txt
  git add new.txt
  git commit -q -m "add new.txt"
  echo "y" > new2.txt
  git add new2.txt
  git commit -q -m "add new2.txt"
  echo "${initial_sha}" > "${TEST_TMP}/f005-git-initial-sha"
)
initial_sha="$(cat "${TEST_TMP}/f005-git-initial-sha")"
cat > "${f005_home}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.36.0
installed_sha=${initial_sha}
repo_path=${f005_git}
EOF
drift_result_commits="$(HOME="${f005_home}" \
  bash -c "source '${COMMON_SH}'; omc_check_install_drift")"
if [[ "${drift_result_commits}" == "commits:1.36.0:2" ]]; then
  ok
else
  fail_msg "F-005: commits-ahead should return 'commits:1.36.0:2', got: ${drift_result_commits}"
fi

# Disable flag returns empty.
cat > "${f005_home}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.36.0
installed_sha=${initial_sha}
repo_path=${f005_git}
installation_drift_check=false
EOF
drift_disabled="$(HOME="${f005_home}" \
  bash -c "source '${COMMON_SH}'; omc_check_install_drift")"
if [[ -z "${drift_disabled}" ]]; then
  ok
else
  fail_msg "F-005: installation_drift_check=false should return empty, got: ${drift_disabled}"
fi

# ----------------------------------------------------------------------
# F-005 (E2E) — session-start-drift-check.sh hook composes a payload
# from omc_check_install_drift, emits to stdout, then writes the
# dedupe state. End-to-end test invokes the hook script via stdin
# with a fixture conf+repo and asserts the JSON payload shape +
# dedupe-after-printf ordering (excellence-reviewer F-W1-E).
# ----------------------------------------------------------------------
printf '\n--- F-005 E2E: drift-check hook payload + dedupe ordering ---\n'

f005_e2e_repo="${TEST_TMP}/f005-e2e-repo"
mkdir -p "${f005_e2e_repo}"
echo '1.99.0' > "${f005_e2e_repo}/VERSION"

# The hook sources `${HOME}/.claude/skills/autowork/scripts/common.sh`,
# so we need to symlink the bundle's skills/ + quality-pack/ trees into
# the test's HOME/.claude.
f005_e2e_home="${TEST_TMP}/f005-e2e-home"
mkdir -p "${f005_e2e_home}/.claude"
ln -sf "${REPO_ROOT}/bundle/dot-claude/skills" "${f005_e2e_home}/.claude/skills"
ln -sf "${REPO_ROOT}/bundle/dot-claude/quality-pack" "${f005_e2e_home}/.claude/quality-pack"
cat > "${f005_e2e_home}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.36.0
repo_path=${f005_e2e_repo}
EOF

# Provide a fake STATE_ROOT and SESSION_ID for the hook.
f005_e2e_state="${TEST_TMP}/f005-e2e-state"
fake_sid="aaaaaaaa-bbbb-cccc-dddd-000000000001"
mkdir -p "${f005_e2e_state}/${fake_sid}"
# Stub session_state.json so write_state can mutate it.
echo '{}' > "${f005_e2e_state}/${fake_sid}/session_state.json"

hook_stdin="$(jq -nc --arg sid "${fake_sid}" --arg src startup --arg cwd "${TEST_TMP}" \
  '{session_id:$sid, source:$src, cwd:$cwd}')"

# Wrap the hook in a tempfile so we can invoke it with HOME override.
hook_out="$(HOME="${f005_e2e_home}" \
  STATE_ROOT="${f005_e2e_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-drift-check.sh" <<<"${hook_stdin}" 2>/dev/null || true)"

# Hook output should be a JSON object with hookSpecificOutput.additionalContext.
hook_payload_kind="$(printf '%s' "${hook_out}" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)"
if [[ "${hook_payload_kind}" == "SessionStart" ]]; then
  ok
else
  fail_msg "F-005 E2E: hook output missing hookSpecificOutput.hookEventName=SessionStart (got: ${hook_payload_kind})"
fi

hook_drift_msg="$(printf '%s' "${hook_out}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
if [[ "${hook_drift_msg}" == *"Bundle drift detected"* ]]; then
  ok
else
  fail_msg "F-005 E2E: drift notice missing 'Bundle drift detected' lead in additionalContext"
fi

# Dedupe state should be set AFTER successful printf — the file should
# now have drift_check_emitted=1 in session_state.json.
emit_state="$(jq -r '.drift_check_emitted // empty' "${f005_e2e_state}/${fake_sid}/session_state.json" 2>/dev/null || true)"
if [[ "${emit_state}" == "1" ]]; then
  ok
else
  fail_msg "F-005 E2E: drift_check_emitted not set to 1 after successful emit"
fi

# Re-running the hook should NO-OP (idempotency via drift_check_emitted).
hook_out_2="$(HOME="${f005_e2e_home}" \
  STATE_ROOT="${f005_e2e_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-drift-check.sh" <<<"${hook_stdin}" 2>/dev/null || true)"
if [[ -z "${hook_out_2}" ]]; then
  ok
else
  fail_msg "F-005 E2E: idempotency violated — second invocation re-emitted payload (got: ${hook_out_2})"
fi

# ----------------------------------------------------------------------
# F-024 — show-status.sh emits a Harness Health section when the
# watchdog tombstone is present. Smoke check: the section header and
# tombstone path appear in the output.
# ----------------------------------------------------------------------
printf '\n--- F-024: harness health section surfaces watchdog tombstone ---\n'

if grep -q "Harness Health" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"; then
  ok
else
  fail_msg "F-024: show-status.sh missing 'Harness Health' header"
fi

if grep -q "watchdog-last-error" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"; then
  ok
else
  fail_msg "F-024: show-status.sh does not reference the tombstone path"
fi

# ----------------------------------------------------------------------
printf '\n=== Wave 1 reliability tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
