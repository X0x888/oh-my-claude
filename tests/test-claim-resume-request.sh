#!/usr/bin/env bash
#
# Tests for skills/autowork/scripts/claim-resume-request.sh — the
# atomic claim helper that backs the /ulw-resume skill (Wave 2) and
# will back the headless watchdog (Wave 3). Single source of truth
# for the cross-session claim flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/claim-resume-request.sh"

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/claim-resume-request.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/claim-resume-request.sh"
  for lib in state-io.sh classifier.sh verification.sh; do
    if [[ -f "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" ]]; then
      ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" \
        "${TEST_HOME}/.claude/skills/autowork/scripts/lib/${lib}"
    fi
  done
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  unset OMC_STOP_FAILURE_CAPTURE 2>/dev/null || true
  unset OMC_RESUME_REQUEST_TTL_DAYS 2>/dev/null || true
  cd "${TEST_HOME}" || exit 1
}

teardown_test() {
  cd "${ORIG_PWD}" 2>/dev/null || true
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}" 2>/dev/null || true
}

trap 'teardown_test' EXIT

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
    printf '  FAIL: %s\n    expected contains: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Build a claimable resume_request.json. Defaults: rate cap cleared 60s
# ago, captured 30s ago, unclaimed (resumed_at_ts=null, attempts=0).
make_request() {
  local sid="$1"
  local cwd="${2:-${TEST_HOME}}"
  local objective="${3:-Ship the wave.}"
  local last_prompt="${4:-/ulw ship it.}"
  local matcher="${5:-rate_limit}"
  local resets_offset="${6:--60}"
  local captured_offset="${7:--30}"
  local resume_attempts="${8:-0}"
  local resumed_at_ts="${9:-null}"
  local project_key="${10:-}"

  local now_ts
  now_ts="$(date +%s)"
  local captured_ts=$((now_ts + captured_offset))
  local resets_ts=""
  if [[ "${resets_offset}" != "null" ]]; then
    resets_ts=$((now_ts + resets_offset))
  fi

  local sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${sdir}"

  local rate_limited="false"
  [[ "${matcher}" == "rate_limit" ]] && rate_limited="true"

  local pk_arg="null"
  if [[ -n "${project_key}" ]]; then
    pk_arg="\"${project_key}\""
  fi

  jq -nc \
    --arg session_id "${sid}" \
    --arg cwd "${cwd}" \
    --arg objective "${objective}" \
    --arg last_prompt "${last_prompt}" \
    --arg matcher "${matcher}" \
    --argjson rate_limited "${rate_limited}" \
    --argjson resume_attempts "${resume_attempts}" \
    --argjson captured_at_ts "${captured_ts}" \
    --argjson resets_at_ts "${resets_ts:-null}" \
    --argjson resumed_at_ts "${resumed_at_ts}" \
    --argjson project_key "${pk_arg}" \
    '{
      schema_version: 1, rate_limited: $rate_limited, matcher: $matcher,
      hook_event_name: "StopFailure", session_id: $session_id, cwd: $cwd,
      project_key: $project_key, transcript_path: "",
      original_objective: $objective, last_user_prompt: $last_prompt,
      resets_at_ts: $resets_at_ts, captured_at_ts: $captured_at_ts,
      model_id: "claude-opus-4-7", resume_attempts: $resume_attempts,
      resumed_at_ts: $resumed_at_ts, rate_limit_snapshot: null
    }' > "${sdir}/resume_request.json"

  printf '%s/.claude/quality-pack/state/%s/resume_request.json' "${TEST_HOME}" "${sid}"
}

read_field() {
  local path="$1" field="$2"
  jq -r ".${field} // empty" "${path}" 2>/dev/null || true
}

print_test_header() {
  printf '\n=== %s ===\n' "$1"
}

# ---------------------------------------------------------------------------
# T1: happy path — claim the only artifact, exit 0, mutation applied
# ---------------------------------------------------------------------------
print_test_header "T1: happy path claim"
setup_test
target_path="$(make_request "sess-1" "${TEST_HOME}" "Ship Wave 2.")"
out="$(bash "${HELPER}" 2>/dev/null || true)"
rc="$?"
assert_eq "T1: exit 0" "0" "$([[ -n "${out}" ]] && echo 0 || echo 1)"
assert_contains "T1: stdout has original objective" "Ship Wave 2." "${out}"
assert_contains "T1: stdout marks _claimed_path" "_claimed_path" "${out}"
assert_eq "T1: artifact resumed_at_ts is set" "true" \
  "$([[ "$(read_field "${target_path}" resumed_at_ts)" =~ ^[0-9]+$ ]] && echo true || echo false)"
assert_eq "T1: resume_attempts = 1 after claim" "1" "$(read_field "${target_path}" resume_attempts)"
assert_eq "T1: last_attempt_outcome = session-claimed" "session-claimed" \
  "$(read_field "${target_path}" last_attempt_outcome)"
teardown_test

# ---------------------------------------------------------------------------
# T2: already-claimed → exit 1, no mutation
# ---------------------------------------------------------------------------
print_test_header "T2: already-claimed artifact rejected"
setup_test
already_resumed="$(date +%s)"
target_path="$(make_request "sess-2" "${TEST_HOME}" "obj." "/ulw foo" "rate_limit" "-60" "-30" "1" "${already_resumed}")"
out="$(bash "${HELPER}" 2>/dev/null || true)"
rc=$?
# Note: bash || true masks rc. Re-run capturing exit explicitly.
set +e
bash "${HELPER}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2: exit code 1" "1" "${rc}"
# Mutation NOT applied beyond what was already there.
assert_eq "T2: resume_attempts unchanged" "1" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T3: --peek prints contents without mutation
# ---------------------------------------------------------------------------
print_test_header "T3: peek mode is read-only"
setup_test
target_path="$(make_request "sess-3" "${TEST_HOME}" "Peek test.")"
out="$(bash "${HELPER}" --peek)"
assert_contains "T3: peek prints objective" "Peek test." "${out}"
assert_contains "T3: peek marks _peek: true" "\"_peek\":true" "${out}"
assert_eq "T3: artifact still unclaimed" "" \
  "$(jq -r '.resumed_at_ts // ""' "${target_path}" | tr -d 'null')"
assert_eq "T3: resume_attempts still 0" "0" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T4: --list enumerates claimable artifacts as TSV
# ---------------------------------------------------------------------------
print_test_header "T4: --list emits TSV rows for all claimable"
setup_test
make_request "sess-4a" "${TEST_HOME}" "First." > /dev/null
make_request "sess-4b" "/some/elsewhere" "Second cross-cwd." > /dev/null
out="$(bash "${HELPER}" --list)"
row_count="$(printf '%s\n' "${out}" | grep -c $'\t' || true)"
assert_eq "T4: 2 rows present" "2" "${row_count}"
assert_contains "T4: cwd-match scope present" "cwd-match" "${out}"
assert_contains "T4: other-cwd scope present" "other-cwd" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# T5: --cwd filter selects matching artifact
# ---------------------------------------------------------------------------
print_test_header "T5: --cwd filter selects matching cwd"
setup_test
mkdir -p "${TEST_HOME}/projA" "${TEST_HOME}/projB"
make_request "sess-5a" "${TEST_HOME}/projA" "Project A objective." > /dev/null
make_request "sess-5b" "${TEST_HOME}/projB" "Project B objective." > /dev/null
out="$(bash "${HELPER}" --cwd "${TEST_HOME}/projA")"
assert_contains "T5: chose A by cwd filter" "Project A objective." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# T6: --session-id filter pins to specific session
# ---------------------------------------------------------------------------
print_test_header "T6: --session-id filter pins target"
setup_test
target_a="$(make_request "sess-6a" "${TEST_HOME}" "Older A obj." "/ulw foo" "rate_limit" "-60" "-3600")"
target_b="$(make_request "sess-6b" "${TEST_HOME}" "Newer B obj." "/ulw foo" "rate_limit" "-60" "-30")"
# Without filter, newer (B) wins. With --session-id sess-6a, older A wins.
out="$(bash "${HELPER}" --session-id "sess-6a")"
assert_contains "T6: filter pins to sess-6a" "Older A obj." "${out}"
# A claimed; B still unclaimed.
assert_eq "T6: A claimed" "1" "$(read_field "${target_a}" resume_attempts)"
assert_eq "T6: B not claimed" "0" "$(read_field "${target_b}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T7: --target PATH always wins
# ---------------------------------------------------------------------------
print_test_header "T7: --target PATH highest precedence"
setup_test
target_a="$(make_request "sess-7a" "${TEST_HOME}" "A new." "/ulw foo" "rate_limit" "-60" "-30")"
target_b="$(make_request "sess-7b" "${TEST_HOME}" "B old." "/ulw foo" "rate_limit" "-60" "-3600")"
out="$(bash "${HELPER}" --target "${target_b}")"
assert_contains "T7: claimed B by --target" "B old." "${out}"
assert_eq "T7: A still unclaimed" "0" "$(read_field "${target_a}" resume_attempts)"
assert_eq "T7: B claimed" "1" "$(read_field "${target_b}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T8: --watchdog-launch increments attempts and stamps pid
# ---------------------------------------------------------------------------
print_test_header "T8: watchdog mode stamps pid + outcome"
setup_test
target_path="$(make_request "sess-8" "${TEST_HOME}" "Watchdog test.")"
out="$(bash "${HELPER}" --watchdog-launch 12345 --target "${target_path}")"
assert_contains "T8: stdout has original obj" "Watchdog test." "${out}"
assert_eq "T8: outcome = watchdog-launched" "watchdog-launched" \
  "$(read_field "${target_path}" last_attempt_outcome)"
assert_eq "T8: last_attempt_pid = 12345" "12345" "$(read_field "${target_path}" last_attempt_pid)"
assert_eq "T8: resume_attempts = 1" "1" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T9: watchdog respects 3-attempt cap
# ---------------------------------------------------------------------------
print_test_header "T9: watchdog refuses after attempt cap"
setup_test
target_path="$(make_request "sess-9" "${TEST_HOME}" "obj." "/ulw foo" "rate_limit" "-60" "-30" "3")"
set +e
bash "${HELPER}" --watchdog-launch 99 --target "${target_path}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T9: exit code 1 (capped)" "1" "${rc}"
assert_eq "T9: resume_attempts unchanged at 3" "3" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T10: --cwd no match → exit 1
# ---------------------------------------------------------------------------
print_test_header "T10: cwd filter with no match exits 1"
setup_test
make_request "sess-10" "${TEST_HOME}/projA" "obj." > /dev/null
set +e
bash "${HELPER}" --cwd "/no/such/path" --session-id "nope" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T10: exit code 1" "1" "${rc}"
teardown_test

# ---------------------------------------------------------------------------
# T11: Privacy opt-out (OMC_STOP_FAILURE_CAPTURE=off) → exit 1, no claim
# ---------------------------------------------------------------------------
print_test_header "T11: privacy opt-out skips claim entirely"
setup_test
target_path="$(make_request "sess-11" "${TEST_HOME}" "obj.")"
set +e
OMC_STOP_FAILURE_CAPTURE=off bash "${HELPER}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T11: exit 1 with opt-out" "1" "${rc}"
assert_eq "T11: artifact untouched" "0" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T12: race condition — two parallel claimers, exactly one wins
# ---------------------------------------------------------------------------
print_test_header "T12: parallel claim race resolves to one winner"
setup_test
target_path="$(make_request "sess-12" "${TEST_HOME}" "Race obj.")"
# Spawn two parallel claimers; the `with_resume_lock` mutex must
# serialize them so exactly one mutates the artifact. Disable
# errexit inside the test block so a non-zero rc from one of the
# subshells does not fire the EXIT trap mid-test.
race_a_rc_file="${TEST_HOME}/.race_a.rc"
race_b_rc_file="${TEST_HOME}/.race_b.rc"
set +e
( bash "${HELPER}" >/dev/null 2>&1; printf '%s' "$?" > "${race_a_rc_file}" ) &
pid_a=$!
( bash "${HELPER}" >/dev/null 2>&1; printf '%s' "$?" > "${race_b_rc_file}" ) &
pid_b=$!
wait "${pid_a}"
wait "${pid_b}"
set -e
rc_a="$(cat "${race_a_rc_file}" 2>/dev/null || echo "?")"
rc_b="$(cat "${race_b_rc_file}" 2>/dev/null || echo "?")"
# Exactly one should be 0, the other 1 (race-loss).
winners=0
[[ "${rc_a}" == "0" ]] && winners=$((winners + 1))
[[ "${rc_b}" == "0" ]] && winners=$((winners + 1))
assert_eq "T12: exactly one winner (rc_a=${rc_a} rc_b=${rc_b})" "1" "${winners}"
# resume_attempts must be exactly 1 — the loser's claim was rejected
# AFTER the winner mutated, so the helper exits 1 without bumping.
assert_eq "T12: resume_attempts = 1 (no double mutation)" "1" \
  "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T13: --peek then claim still works (peek doesn't claim)
# ---------------------------------------------------------------------------
print_test_header "T13: peek-then-claim sequence"
setup_test
target_path="$(make_request "sess-13" "${TEST_HOME}" "Peek-then-claim.")"
peek_out="$(bash "${HELPER}" --peek)"
claim_out="$(bash "${HELPER}")"
assert_contains "T13: peek printed objective" "Peek-then-claim." "${peek_out}"
assert_contains "T13: claim printed objective" "Peek-then-claim." "${claim_out}"
assert_eq "T13: claimed exactly once" "1" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T14: project-match — different cwd, same project_key
# ---------------------------------------------------------------------------
print_test_header "T14: project-match scope wins when cwd differs but project_key matches"
setup_test
target_cwd="${TEST_HOME}/proj14"
mkdir -p "${target_cwd}"
shared_key="$(printf '%s' "${target_cwd}" | shasum -a 256 2>/dev/null | cut -c1-12)"
make_request "sess-14" "/elsewhere/repo" "Project key match obj." "/ulw foo" "rate_limit" \
  "-60" "-30" "0" "null" "${shared_key}" > /dev/null
out="$(bash "${HELPER}" --cwd "${target_cwd}")"
assert_contains "T14: project-key match selected" "Project key match obj." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# T15: empty STATE_ROOT exits 1 cleanly
# ---------------------------------------------------------------------------
print_test_header "T15: no claimable artifacts → exit 1"
setup_test
set +e
bash "${HELPER}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T15: exit 1" "1" "${rc}"
teardown_test

# ---------------------------------------------------------------------------
# T16: stale lock recovered (mkdir lock without process)
# ---------------------------------------------------------------------------
print_test_header "T16: stale lock recovered, claim still succeeds"
setup_test
target_path="$(make_request "sess-16" "${TEST_HOME}" "Stale lock obj.")"
# Pre-create the lock dir with an old mtime to simulate a crashed claimer.
lock="${TEST_HOME}/.claude/quality-pack/.resume-request.lock"
mkdir -p "${lock}"
# touch with -t format is BSD/GNU compatible at YYYYMMDDhhmm.
touch -t 200001010000 "${lock}" 2>/dev/null || touch "${lock}"
out="$(bash "${HELPER}" 2>/dev/null || true)"
assert_contains "T16: claim succeeded after stale-lock recovery" "Stale lock obj." "${out}"
assert_eq "T16: resume_attempts = 1 after recovery" "1" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T17: malformed artifact JSON → skipped, other valid artifact succeeds
# ---------------------------------------------------------------------------
print_test_header "T17: corrupted artifact does not crash claim"
setup_test
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/sess-bad"
printf 'not json' > "${TEST_HOME}/.claude/quality-pack/state/sess-bad/resume_request.json"
target_path="$(make_request "sess-17" "${TEST_HOME}" "Valid obj.")"
out="$(bash "${HELPER}" 2>/dev/null || true)"
assert_contains "T17: claimed valid artifact" "Valid obj." "${out}"
assert_eq "T17: valid artifact claimed" "1" "$(read_field "${target_path}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T18: unknown flag exits 64
# ---------------------------------------------------------------------------
print_test_header "T18: unknown CLI flag fails fast"
setup_test
make_request "sess-18" "${TEST_HOME}" "obj." > /dev/null
set +e
bash "${HELPER}" --bogus 2>/dev/null
rc=$?
set -e
assert_eq "T18: unknown-flag exit 64" "64" "${rc}"
teardown_test

# ---------------------------------------------------------------------------
# T19: gate event recorded on successful claim
# ---------------------------------------------------------------------------
print_test_header "T19: claim emits gate-event row"
setup_test
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/active-sess"
export SESSION_ID="active-sess"
make_request "sess-19" "${TEST_HOME}" "GateEvent obj." > /dev/null
bash "${HELPER}" >/dev/null 2>&1
events_file="${TEST_HOME}/.claude/quality-pack/state/active-sess/gate_events.jsonl"
assert_eq "T19: gate_events.jsonl exists" "1" "$([[ -f "${events_file}" ]] && echo 1 || echo 0)"
assert_contains "T19: claim-success row recorded" "claim-success" "$(cat "${events_file}" 2>/dev/null || echo '')"
unset SESSION_ID
teardown_test

# ---------------------------------------------------------------------------
# T20: --watchdog-launch without --target or --session-id rejected (P1 fix)
# ---------------------------------------------------------------------------
print_test_header "T20: watchdog mode requires pinned target or session-id"
setup_test
make_request "sess-20" "${TEST_HOME}" "obj." > /dev/null
set +e
bash "${HELPER}" --watchdog-launch 99 2>/tmp/.t20.err
rc=$?
set -e
assert_eq "T20: exit 64 (arg validation)" "64" "${rc}"
assert_contains "T20: stderr names the requirement" "requires --target" "$(cat /tmp/.t20.err 2>/dev/null || echo '')"
teardown_test

# Watchdog WITH --target passes (sanity).
print_test_header "T20b: watchdog mode with --target works"
setup_test
target_path="$(make_request "sess-20b" "${TEST_HOME}" "Watchdog target obj.")"
out="$(bash "${HELPER}" --watchdog-launch 42 --target "${target_path}")"
assert_contains "T20b: claim succeeds with --target" "Watchdog target obj." "${out}"
assert_eq "T20b: outcome = watchdog-launched" "watchdog-launched" \
  "$(read_field "${target_path}" last_attempt_outcome)"
teardown_test

# Watchdog with --session-id also works.
print_test_header "T20c: watchdog mode with --session-id works"
setup_test
target_path="$(make_request "sess-20c" "${TEST_HOME}" "Watchdog sid obj.")"
out="$(bash "${HELPER}" --watchdog-launch 99 --session-id "sess-20c")"
assert_contains "T20c: --session-id pin works for watchdog" "Watchdog sid obj." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# T21: empty-payload guard — refuses claim when both fields empty
# ---------------------------------------------------------------------------
print_test_header "T21: empty-payload guard refuses to claim"
setup_test
sid="sess-21"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now21="$(date +%s)"
jq -nc --argjson cap "$((_now21 - 30))" --argjson rs "$((_now21 - 60))" --arg cwd "${TEST_HOME}" '
  {schema_version:1, rate_limited:true, matcher:"rate_limit",
   hook_event_name:"StopFailure", session_id:"sess-21",
   cwd:$cwd, project_key:null, transcript_path:"",
   original_objective:"", last_user_prompt:"",
   resets_at_ts:$rs, captured_at_ts:$cap,
   model_id:null, resume_attempts:0, resumed_at_ts:null,
   rate_limit_snapshot:null}' > "${sdir}/resume_request.json"
set +e
bash "${HELPER}" 2>/tmp/.t21.err
rc=$?
set -e
assert_eq "T21: empty-payload exit 1" "1" "${rc}"
assert_contains "T21: stderr explains empty-payload" "empty original_objective" "$(cat /tmp/.t21.err 2>/dev/null || echo '')"
# Verify artifact is unmutated.
assert_eq "T21: artifact resume_attempts unchanged" "0" "$(read_field "${sdir}/resume_request.json" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T22: empty-payload guard does NOT block --peek or --dismiss
# ---------------------------------------------------------------------------
print_test_header "T22: empty-payload artifact still peek-able and dismiss-able"
setup_test
sid="sess-22"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now22="$(date +%s)"
jq -nc --argjson cap "$((_now22 - 30))" --argjson rs "$((_now22 - 60))" --arg cwd "${TEST_HOME}" '
  {schema_version:1, rate_limited:true, matcher:"rate_limit",
   hook_event_name:"StopFailure", session_id:"sess-22",
   cwd:$cwd, project_key:null, transcript_path:"",
   original_objective:"", last_user_prompt:"",
   resets_at_ts:$rs, captured_at_ts:$cap,
   model_id:null, resume_attempts:0, resumed_at_ts:null,
   rate_limit_snapshot:null}' > "${sdir}/resume_request.json"
peek_out="$(bash "${HELPER}" --peek)"
assert_contains "T22: peek works" "_peek" "${peek_out}"
dismiss_out="$(bash "${HELPER}" --dismiss)"
assert_contains "T22: dismiss works on empty-payload" "_dismissed" "${dismiss_out}"
teardown_test

# ---------------------------------------------------------------------------
# T23: --dismiss stamps dismissed_at_ts; subsequent claim rejected
# ---------------------------------------------------------------------------
print_test_header "T23: dismiss suppresses future claims"
setup_test
target_path="$(make_request "sess-23" "${TEST_HOME}" "Dismiss test.")"
dismiss_out="$(bash "${HELPER}" --dismiss)"
assert_contains "T23: dismiss prints dismissed marker" "_dismissed" "${dismiss_out}"
assert_eq "T23: artifact has dismissed_at_ts set" "true" \
  "$([[ "$(read_field "${target_path}" dismissed_at_ts)" =~ ^[0-9]+$ ]] && echo true || echo false)"
assert_eq "T23: outcome = user-dismissed" "user-dismissed" \
  "$(read_field "${target_path}" last_attempt_outcome)"
# resumed_at_ts must NOT be set (dismiss doesn't claim).
assert_eq "T23: dismissed != claimed (no resumed_at_ts)" "" \
  "$(jq -r '.resumed_at_ts // ""' "${target_path}" 2>/dev/null | tr -d 'null')"
# A subsequent --peek does NOT show dismissed artifacts (filtered by helper).
set +e
bash "${HELPER}" --peek >/dev/null 2>&1
peek_rc=$?
set -e
assert_eq "T23: peek excludes dismissed artifact" "1" "${peek_rc}"
# A subsequent claim is also rejected.
set +e
bash "${HELPER}" >/dev/null 2>&1
claim_rc=$?
set -e
assert_eq "T23: claim of dismissed artifact rejected" "1" "${claim_rc}"
teardown_test

# ---------------------------------------------------------------------------
# T24: --dismiss is single-shot (second dismiss exits 1)
# ---------------------------------------------------------------------------
print_test_header "T24: double-dismiss is a clean no-op"
setup_test
make_request "sess-24" "${TEST_HOME}" "Double dismiss." > /dev/null
bash "${HELPER}" --dismiss >/dev/null 2>&1
set +e
bash "${HELPER}" --dismiss >/dev/null 2>&1
rc=$?
set -e
assert_eq "T24: second dismiss exits 1" "1" "${rc}"
teardown_test

# ---------------------------------------------------------------------------
# T25: dismissed artifact does not bleed into find_claimable_resume_requests
# ---------------------------------------------------------------------------
print_test_header "T25: dismissed artifacts excluded from --list"
setup_test
make_request "sess-25-active" "${TEST_HOME}" "Still active." > /dev/null
make_request "sess-25-dismiss-me" "${TEST_HOME}" "Dismiss this." > /dev/null
bash "${HELPER}" --session-id "sess-25-dismiss-me" --dismiss >/dev/null 2>&1
list_out="$(bash "${HELPER}" --list)"
assert_contains "T25: active artifact still listed" "sess-25-active" "${list_out}"
assert_eq "T25: dismissed artifact NOT listed" "0" \
  "$(printf '%s' "${list_out}" | grep -c 'dismiss-me' || true)"
teardown_test

# ---------------------------------------------------------------------------
# T26: symlink-shaped session dirs and artifacts rejected (v1.29.0 Wave 1
#      security backfill — closes find_claimable_resume_requests symlink-
#      elevation chain). An attacker with write access to STATE_ROOT could
#      otherwise drop a UUID-shaped symlink at an attacker-controlled
#      directory containing a hostile resume_request.json; combined with
#      the watchdog launch path, that was a credible RCE vector.
# ---------------------------------------------------------------------------
print_test_header "T26: symlink session dirs and artifacts excluded from --list"
setup_test
# Real session, real artifact — should appear in --list.
make_request "sess-26-real" "${TEST_HOME}" "Legitimate." > /dev/null
# Create a UUID-shaped SYMLINK pointing at a victim dir with a hostile artifact.
victim_dir="$(mktemp -d "${TEST_HOME}/victim.XXXXXX")"
cat > "${victim_dir}/resume_request.json" <<EOF
{"schema_version":1,"session_id":"sess-26-evil","cwd":"${victim_dir}","captured_at_ts":$(date +%s),"original_objective":"hostile","last_user_prompt":"hostile","resets_at_ts":null,"resume_attempts":0}
EOF
ln -s "${victim_dir}" "${TEST_HOME}/.claude/quality-pack/state/sess-26-evil-symlink-dir"
# Also create a real session dir but with the artifact itself a symlink.
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/sess-26-artifact-symlink"
ln -s "${victim_dir}/resume_request.json" "${TEST_HOME}/.claude/quality-pack/state/sess-26-artifact-symlink/resume_request.json"
# Run --list and verify ONLY the real artifact is listed.
list_out="$(bash "${HELPER}" --list 2>/dev/null || true)"
assert_contains "T26: real artifact listed" "sess-26-real" "${list_out}"
assert_eq "T26: symlinked dir NOT listed" "0" \
  "$(printf '%s' "${list_out}" | grep -c 'sess-26-evil-symlink-dir' || true)"
assert_eq "T26: symlinked artifact NOT listed" "0" \
  "$(printf '%s' "${list_out}" | grep -c 'sess-26-artifact-symlink' || true)"
teardown_test

printf '\n=== test-claim-resume-request: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
