#!/usr/bin/env bash
# Regression net for v1.44-pre Port 5 — stop-transcript-archive.sh (Stop hook).
#
# Default OFF. When on, archives Claude Code's session JSONL to
# ~/.claude/quality-pack/state/<project_key>/<session_id>/transcript.json.
# Idempotent; honors is_stop_failure_capture_enabled (privacy parity);
# skips on fatal matchers (rate_limit / authentication_failed / etc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t tarch-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack/state" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

# .ulw_active sentinel at the path the hook reads.
touch "${_test_home}/.claude/quality-pack/state/.ulw_active"

# Fake transcript file
_fake_transcript="$(mktemp -t tarch-jsonl-XXXXXX)"
cat >"${_fake_transcript}" <<'EOF'
{"type":"user","content":"hello"}
{"type":"assistant","content":"hi back"}
{"type":"tool_use","tool":"Read"}
EOF

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

pass=0
fail=0
TEST_FINALIZER_CLAIM_ID="finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

_cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
  rm -f "${_fake_transcript}"
}
trap _cleanup EXIT

# Drive the hook with synthesized Stop hook payload.
_drive() {
  local sid="$1" archive_flag="$2" stop_failure_flag="$3" matcher="${4:-}" \
        transcript="${5:-${_fake_transcript}}"
  local payload
  if [[ -n "${matcher}" ]]; then
    payload="$(jq -nc --arg sid "${sid}" --arg tp "${transcript}" --arg m "${matcher}" \
      '{session_id:$sid, transcript_path:$tp, matcher:$m}')"
  else
    payload="$(jq -nc --arg sid "${sid}" --arg tp "${transcript}" \
      '{session_id:$sid, transcript_path:$tp}')"
  fi
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE="${archive_flag}" \
    OMC_STOP_FAILURE_CAPTURE="${stop_failure_flag}" \
    OMC_STOP_ACCEPTED=1 \
    OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    <<<"${payload}" 2>/dev/null || true
}

_init_sid() {
  local sid="$1"
  local sdir="${_test_state_root}/${sid}"
  mkdir -p "${sdir}"
  jq -nc --arg claim "${TEST_FINALIZER_CLAIM_ID}" \
    --argjson now "$(date +%s)" '
      {workflow_mode:"ultrawork",review_cycle_id:"1",prompt_revision:"1",
       session_outcome:"completed",closeout_finalized_token:"1:1:completed",
       closeout_finalization_status:"claimed",
       closeout_finalization_claimed_ts:$now,
       closeout_finalization_claim_id:$claim}
    ' >"${sdir}/session_state.json"
}

_claim_fresh_finalizer() {
  local sid="$1"
  env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    SESSION_ID="${sid}" bash -c '
      . "$1"
      closeout_claim_finalization
    ' -- "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
}

_find_archive() {
  local sid="$1"
  # Walk the project_key dir tree under ~/.claude/quality-pack/state/<key>/<sid>/
  find "${_test_home}/.claude/quality-pack/state" -path "*/${sid}/transcript.json" -o -path "*/${sid}/transcript.jsonl" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# T1: flag off → no archive written
# ---------------------------------------------------------------------------
printf 'T1: flag off → no archive\n'
sid="t1-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" off on
archive_path="$(_find_archive "${sid}")"
assert_eq "T1: no archive when flag off" "" "${archive_path}"

# ---------------------------------------------------------------------------
# T2: flag on + valid transcript → archive written as JSON array
# ---------------------------------------------------------------------------
printf 'T2: flag on → archive captured\n'
sid="t2-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" on on
archive_path="$(_find_archive "${sid}")"
if [[ -f "${archive_path}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2: archive not written (looked for path)\n' >&2
  fail=$((fail + 1))
fi
# Validate: when jq is present, top-level is a JSON array.
if [[ -f "${archive_path}" && "${archive_path}" == *.json ]]; then
  if jq -e 'type == "array"' "${archive_path}" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T2: archive content is not a JSON array\n' >&2
    fail=$((fail + 1))
  fi
fi

# ---------------------------------------------------------------------------
# T3: missing transcript_path → silent exit, no write
# ---------------------------------------------------------------------------
printf 'T3: missing transcript_path → silent\n'
sid="t3-${RANDOM}"
_init_sid "${sid}"
payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
out="$(HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
  OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
  OMC_STOP_ACCEPTED=1 \
  OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
  <<<"${payload}" 2>/dev/null || true)"
assert_eq "T3: empty output" "" "${out}"
archive_path="$(_find_archive "${sid}")"
assert_eq "T3: no archive when transcript_path empty" "" "${archive_path}"

# ---------------------------------------------------------------------------
# T4: nonexistent transcript_path → silent exit
# ---------------------------------------------------------------------------
printf 'T4: unreadable transcript_path → silent\n'
sid="t4-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" on on "" "/nonexistent/path.jsonl"
archive_path="$(_find_archive "${sid}")"
assert_eq "T4: no archive when transcript_path unreadable" "" "${archive_path}"

# ---------------------------------------------------------------------------
# T5: idempotent — second invocation doesn't re-archive
# ---------------------------------------------------------------------------
printf 'T5: idempotent on repeat invocations\n'
sid="t5-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" on on
archive_path="$(_find_archive "${sid}")"
if [[ -f "${archive_path}" ]]; then
  mtime1="$(stat -c '%Y' "${archive_path}" 2>/dev/null || stat -f '%m' "${archive_path}" 2>/dev/null)"
  # Touch with a different mtime to make a re-write detectable.
  sleep 1
  _drive "${sid}" on on
  mtime2="$(stat -c '%Y' "${archive_path}" 2>/dev/null || stat -f '%m' "${archive_path}" 2>/dev/null)"
  assert_eq "T5: archive mtime unchanged on second invocation" "${mtime1}" "${mtime2}"
else
  printf '  FAIL: T5: first invocation failed to create archive\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# T6: privacy parity — stop_failure_capture=off suppresses archive
# ---------------------------------------------------------------------------
printf 'T6: stop_failure_capture=off opts out (privacy parity, F-5)\n'
sid="t6-${RANDOM}"
_init_sid "${sid}"
_drive "${sid}" on off
archive_path="$(_find_archive "${sid}")"
assert_eq "T6: no archive when stop_failure_capture=off" "" "${archive_path}"

# ---------------------------------------------------------------------------
# T7: fatal matcher skip (F-5) — rate_limit / authentication_failed etc.
# ---------------------------------------------------------------------------
printf 'T7: fatal matcher skip (rate_limit / etc.)\n'
for matcher in rate_limit authentication_failed billing_error max_output_tokens; do
  sid="t7-${matcher}-${RANDOM}"
  _init_sid "${sid}"
  _drive "${sid}" on on "${matcher}"
  archive_path="$(_find_archive "${sid}")"
  assert_eq "T7: no archive on matcher=${matcher}" "" "${archive_path}"
done

# ---------------------------------------------------------------------------
# T8: generation changes while G1 waits for publication lock. The stale G1
# must not win the first-write slot; the current G2 invocation must still be
# able to publish the archive afterward.
# ---------------------------------------------------------------------------
printf 'T8: stale G1 cannot suppress G2 archive publication\n'
sid="t8-${RANDOM}"
_init_sid "${sid}"
jq '. + {ulw_enforcement_generation:"801"}' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
payload="$(jq -nc --arg sid "${sid}" --arg tp "${_fake_transcript}" \
  '{session_id:$sid, transcript_path:$tp}')"
archive_ready="${_test_state_root}/t8.ready"
archive_release="${_test_state_root}/t8.release"
(
  printf '%s' "${payload}" \
    | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
      OMC_STOP_ACCEPTED=1 _OMC_ULW_CAPTURED_GENERATION=801 \
      OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
      OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${archive_ready}" \
      OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${archive_release}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
      >/dev/null 2>&1 || true
) &
archive_pid=$!
archive_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${archive_ready}" ]]; then
    archive_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "T8: G1 reached deterministic pre-acquire barrier" "1" \
  "${archive_barrier_seen}"
jq '.ulw_enforcement_generation="802"' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
: >"${archive_release}"
wait "${archive_pid}" || true
archive_path="$(_find_archive "${sid}")"
assert_eq "T8: stale G1 published no archive" "" "${archive_path}"
assert_eq "T8: stale G1 emitted no captured event" "0" \
  "$(jq -sr '[.[] | select(.gate == "transcript-archive" and .event == "captured")] | length' \
      "${_test_state_root}/${sid}/gate_events.jsonl" 2>/dev/null || printf 0)"
stage_count="$(find "${_test_home}/.claude/quality-pack/state/.transcript-archive-staging" \
  -type f -name ".${sid}.*" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T8: rejected G1 cleaned its staged copy" "0" "${stage_count}"

printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_STOP_ACCEPTED=1 _OMC_ULW_CAPTURED_GENERATION=802 \
    OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1 || true
archive_path="$(_find_archive "${sid}")"
if [[ -f "${archive_path}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T8: current G2 could not publish after stale G1 rejection\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# T9: accepted child failures are visible to the dispatcher, while a direct
# standalone invocation remains fail-open. A fresh accepted retry publishes.
# ---------------------------------------------------------------------------
printf 'T9: accepted publication failure propagates and remains retryable\n'
sid="t9-${RANDOM}"
_init_sid "${sid}"
payload="$(jq -nc --arg sid "${sid}" --arg tp "${_fake_transcript}" \
  '{session_id:$sid, transcript_path:$tp}')"
missing_claim_rc=0
printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_STOP_ACCEPTED=1 \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1 || missing_claim_rc=$?
assert_eq "T9: accepted archive child requires an exact claimant ID" "1" \
  "${missing_claim_rc}"
accepted_failure_rc=0
printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_STOP_ACCEPTED=1 OMC_TEST_TRANSCRIPT_ARCHIVE_PUBLISH_FAIL=1 \
    OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1 || accepted_failure_rc=$?
assert_eq "T9: accepted publication failure returns non-zero" "1" \
  "${accepted_failure_rc}"
assert_eq "T9: failed accepted publication leaves no archive" "" \
  "$(_find_archive "${sid}")"
standalone_failure_rc=0
printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_TEST_TRANSCRIPT_ARCHIVE_PUBLISH_FAIL=1 \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1 || standalone_failure_rc=$?
assert_eq "T9: standalone archive hook remains fail-open" "0" \
  "${standalone_failure_rc}"
retry_rc=0
printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_STOP_ACCEPTED=1 \
    OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1 || retry_rc=$?
assert_eq "T9: fresh accepted retry succeeds" "0" "${retry_rc}"
archive_path="$(_find_archive "${sid}")"
if [[ -f "${archive_path}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T9: retry did not publish an archive\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# T10: claimant A stages while current, then claimant B replaces its expired
# lease before A takes the publication mutex. A must publish nothing; B owns
# the only archive and captured event.
# ---------------------------------------------------------------------------
printf 'T10: expired claimant A cannot publish after replacement B\n'
sid="t10-${RANDOM}"
_init_sid "${sid}"
claim_a="${TEST_FINALIZER_CLAIM_ID}"
payload="$(jq -nc --arg sid "${sid}" --arg tp "${_fake_transcript}" \
  '{session_id:$sid,transcript_path:$tp}')"
archive_ready="${_test_state_root}/t10.ready"
archive_release="${_test_state_root}/t10.release"
archive_rc_file="${_test_state_root}/t10.rc"
(
  archive_a_rc=0
  printf '%s' "${payload}" \
    | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
      OMC_STOP_ACCEPTED=1 \
      OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${claim_a}" \
      OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${archive_ready}" \
      OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${archive_release}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
      >/dev/null 2>&1 || archive_a_rc=$?
  printf '%s\n' "${archive_a_rc}" >"${archive_rc_file}"
) &
archive_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${archive_ready}" ]] && break
  sleep 0.01
done
assert_eq "T10: claimant A reached the publication boundary" "true" \
  "$([[ -e "${archive_ready}" ]] && printf true || printf false)"
jq --argjson expired_at "$(( $(date +%s) - 121 ))" '
  .closeout_finalization_claimed_ts=$expired_at
' "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
claim_b="$(_claim_fresh_finalizer "${sid}")"
assert_eq "T10: expired claimant is replaced with a fresh exact identity" \
  "true" \
  "$([[ "${claim_b}" =~ ^finalizer-[a-f0-9]{48}$ \
        && "${claim_b}" != "${claim_a}" ]] \
    && printf true || printf false)"
: >"${archive_release}"
wait "${archive_pid}" || true
assert_eq "T10: replaced claimant A returns failure" "1" \
  "$(<"${archive_rc_file}")"
assert_eq "T10: replaced claimant A publishes no archive" "" \
  "$(_find_archive "${sid}")"
printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_STOP_ACCEPTED=1 OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${claim_b}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1
assert_eq "T10: replacement B publishes exactly one archive" "1" \
  "$(find "${_test_home}/.claude/quality-pack/state" \
      \( -path "*/${sid}/transcript.json" -o \
         -path "*/${sid}/transcript.jsonl" \) -type f \
      | wc -l | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# T11: the staging cleanup trap is armed before chmod. A failure at that exact
# boundary must leave neither an archive nor an inert privacy-sensitive temp.
# ---------------------------------------------------------------------------
printf 'T11: stage chmod failure is cleaned immediately\n'
sid="t11-${RANDOM}"
_init_sid "${sid}"
payload="$(jq -nc --arg sid "${sid}" --arg tp "${_fake_transcript}" \
  '{session_id:$sid,transcript_path:$tp}')"
chmod_failure_rc=0
printf '%s' "${payload}" \
  | env HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
    OMC_STOP_ACCEPTED=1 \
    OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
    OMC_TEST_TRANSCRIPT_ARCHIVE_CHMOD_FAIL=1 \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    >/dev/null 2>&1 || chmod_failure_rc=$?
assert_eq "T11: injected chmod failure propagates" "1" \
  "${chmod_failure_rc}"
assert_eq "T11: chmod failure publishes no archive" "" \
  "$(_find_archive "${sid}")"
stage_count="$(find "${_test_home}/.claude/quality-pack/state/.transcript-archive-staging" \
  -type f -name ".${sid}.*" 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "T11: chmod failure leaves no staged transcript" "0" \
  "${stage_count}"

printf '\ntest-stop-transcript-archive: %d passed, %d failed\n' "${pass}" "${fail}"
exit "${fail}"
