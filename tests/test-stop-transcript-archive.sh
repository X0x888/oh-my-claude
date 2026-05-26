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
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-transcript-archive.sh" \
    <<<"${payload}" 2>/dev/null || true
}

_init_sid() {
  local sid="$1"
  local sdir="${_test_state_root}/${sid}"
  mkdir -p "${sdir}"
  printf '{"workflow_mode":"ultrawork"}\n' >"${sdir}/session_state.json"
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

printf '\ntest-stop-transcript-archive: %d passed, %d failed\n' "${pass}" "${fail}"
exit "${fail}"
