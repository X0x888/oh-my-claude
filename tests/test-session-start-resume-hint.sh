#!/usr/bin/env bash
#
# Tests for quality-pack/scripts/session-start-resume-hint.sh — the
# unmatched SessionStart hook that detects unclaimed resume_request.json
# artifacts (left behind by a prior session's StopFailure) and surfaces
# them as additionalContext on the new session.
#
# Companion to test-stop-failure-handler.sh (the producer side); this is
# the consumer side, Wave 1 of the auto-resume harness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-resume-hint.sh"

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
  for lib in state-io.sh classifier.sh verification.sh; do
    if [[ -f "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" ]]; then
      ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" \
        "${TEST_HOME}/.claude/skills/autowork/scripts/lib/${lib}"
    fi
  done
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  unset OMC_STOP_FAILURE_CAPTURE 2>/dev/null || true
  unset OMC_RESUME_REQUEST_TTL_DAYS 2>/dev/null || true
}

teardown_test() {
  export HOME="${ORIG_HOME}"
  cd "${ORIG_PWD}" 2>/dev/null || true
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
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Build a resume_request.json. Defaults yield a CLAIMABLE artifact whose
# rate cap reset 60s ago, captured 30s ago, with a non-empty objective.
make_request() {
  local sid="$1"
  local cwd="${2:-${TEST_HOME}}"
  local objective="${3:-Ship the impeccable feature.}"
  local last_prompt="${4:-/ulw make this feature impeccable. Continue all waves.}"
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
      schema_version: 1,
      rate_limited: $rate_limited,
      matcher: $matcher,
      hook_event_name: "StopFailure",
      session_id: $session_id,
      cwd: $cwd,
      project_key: $project_key,
      transcript_path: "",
      original_objective: $objective,
      last_user_prompt: $last_prompt,
      resets_at_ts: $resets_at_ts,
      captured_at_ts: $captured_at_ts,
      model_id: "claude-opus-4-7",
      resume_attempts: $resume_attempts,
      resumed_at_ts: $resumed_at_ts,
      rate_limit_snapshot: null
    }' > "${sdir}/resume_request.json"
}

make_session_state() {
  local sid="$1"
  local sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${sdir}"
  if [[ ! -f "${sdir}/session_state.json" ]]; then
    jq -nc '{cwd: "/tmp"}' > "${sdir}/session_state.json"
  fi
}

run_hook() {
  local new_session_id="$1"
  local source="${2:-startup}"
  local cwd="${3:-${TEST_HOME}}"
  make_session_state "${new_session_id}"
  local payload
  payload="$(jq -nc \
    --arg sid "${new_session_id}" \
    --arg src "${source}" \
    --arg cwd "${cwd}" \
    '{session_id: $sid, source: $src, cwd: $cwd}')"
  printf '%s' "${payload}" | bash "${HOOK}" 2>/dev/null || true
}

# Read the most recent gate event for the new session.
read_last_gate_event() {
  local sid="$1"
  local file="${TEST_HOME}/.claude/quality-pack/state/${sid}/gate_events.jsonl"
  [[ -f "${file}" ]] || return 0
  tail -n 1 "${file}"
}

print_test_header() {
  printf '\n=== %s ===\n' "$1"
}

# ---------------------------------------------------------------------------
# Test 1: claimable artifact for current cwd → hint emitted, names objective
# ---------------------------------------------------------------------------
print_test_header "Test 1: cwd-match claimable artifact emits hint"
setup_test
make_request "sess-rl-1" "${TEST_HOME}" "Ship Wave 1 of the harness." "/ulw ship wave 1." "rate_limit"
out="$(run_hook "new-1")"
assert_contains "T1: hint mentions matcher" "matcher=rate_limit" "${out}"
assert_contains "T1: hint mentions rate cap cleared" "rate cap cleared" "${out}"
assert_contains "T1: hint mentions original objective" "Ship Wave 1 of the harness." "${out}"
assert_contains "T1: hint mentions last user prompt" "/ulw ship wave 1." "${out}"
assert_contains "T1: hint references /ulw-resume" "/ulw-resume" "${out}"
assert_contains "T1: gate event recorded" "resume-hint-emitted" "$(read_last_gate_event 'new-1')"
# Per-artifact idempotency key (post-review fix): resume_hint_emitted_<origin_sid>.
state_flag="$(jq -r '.resume_hint_emitted_sess_rl_1 // .["resume_hint_emitted_sess-rl-1"] // ""' \
  "${TEST_HOME}/.claude/quality-pack/state/new-1/session_state.json")"
assert_eq "T1: per-artifact idempotency flag set" "1" "${state_flag}"
# resume_hint.md sidecar written.
sidecar="${TEST_HOME}/.claude/quality-pack/state/new-1/resume_hint.md"
assert_eq "T1: resume_hint.md sidecar exists" "1" "$([[ -f "${sidecar}" ]] && echo 1 || echo 0)"
assert_contains "T1: sidecar names origin session" "origin_session_id: sess-rl-1" "$(cat "${sidecar}" 2>/dev/null || echo '')"
teardown_test

# ---------------------------------------------------------------------------
# Test 2: artifact already claimed → hint absent
# ---------------------------------------------------------------------------
print_test_header "Test 2: already-claimed artifact suppresses hint"
setup_test
make_request "sess-rl-2" "${TEST_HOME}" "Ship Wave 1." "/ulw foo" "rate_limit" "-60" "-30" "1" "$(date +%s)"
out="$(run_hook "new-2")"
assert_eq "T2: no stdout (hint absent)" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 3: artifact with resume_attempts > 0 → hint absent (already attempted)
# ---------------------------------------------------------------------------
print_test_header "Test 3: resume_attempts>0 suppresses hint"
setup_test
make_request "sess-rl-3" "${TEST_HOME}" "Ship." "/ulw foo" "rate_limit" "-60" "-30" "2"
out="$(run_hook "new-3")"
assert_eq "T3: no stdout" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 4: resets_at_ts in future → hint absent (cap not yet cleared)
# ---------------------------------------------------------------------------
print_test_header "Test 4: future reset suppresses hint"
setup_test
make_request "sess-rl-4" "${TEST_HOME}" "Ship." "/ulw foo" "rate_limit" "+3600"
out="$(run_hook "new-4")"
assert_eq "T4: no stdout" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 5: resets_at_ts == null (raw API session) → informational hint
# ---------------------------------------------------------------------------
print_test_header "Test 5: null resets_at_ts surfaces informational hint"
setup_test
make_request "sess-rl-5" "${TEST_HOME}" "Ship Wave 1." "/ulw foo" "rate_limit" "null"
out="$(run_hook "new-5")"
# rate_limited=true but resets_at_ts=null → "rate cap reset epoch unknown"
assert_contains "T5: hint emitted with epoch-unknown framing" "rate cap reset epoch unknown" "${out}"
assert_contains "T5: hint includes objective" "Ship Wave 1." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 6: stale artifact > OMC_RESUME_REQUEST_TTL_DAYS → hint absent
# ---------------------------------------------------------------------------
print_test_header "Test 6: stale artifact (older than TTL) suppresses hint"
setup_test
# Captured 10 days ago with default 7-day TTL.
make_request "sess-rl-6" "${TEST_HOME}" "Ship." "/ulw foo" "rate_limit" "-60" "-864000"
out="$(run_hook "new-6")"
assert_eq "T6: no stdout (stale)" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 7: cwd mismatch → hint surfaces with explicit "different cwd" note
# ---------------------------------------------------------------------------
print_test_header "Test 7: cwd mismatch labels artifact as cross-cwd"
setup_test
make_request "sess-rl-7" "/some/other/path" "Ship Wave 1." "/ulw foo" "rate_limit"
out="$(run_hook "new-7" "startup" "${TEST_HOME}")"
assert_contains "T7: hint mentions different cwd" "different working directory" "${out}"
assert_contains "T7: hint still mentions objective" "Ship Wave 1." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 8: OMC_STOP_FAILURE_CAPTURE=off → hint absent (privacy opt-out)
# ---------------------------------------------------------------------------
print_test_header "Test 8: stop_failure_capture=off suppresses hint"
setup_test
make_request "sess-rl-8" "${TEST_HOME}" "Ship." "/ulw foo" "rate_limit"
OMC_STOP_FAILURE_CAPTURE=off out="$(OMC_STOP_FAILURE_CAPTURE=off run_hook "new-8")"
assert_eq "T8: no stdout (opt-out)" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 9: missing SESSION_ID → exit 0 cleanly
# ---------------------------------------------------------------------------
print_test_header "Test 9: missing session_id is non-fatal"
setup_test
make_request "sess-rl-9" "${TEST_HOME}"
out="$(printf '%s' '{"source":"startup","cwd":"'"${TEST_HOME}"'"}' | bash "${HOOK}" 2>/dev/null || true)"
assert_eq "T9: no stdout" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 10: STATE_ROOT empty → exit 0 cleanly, no stdout
# ---------------------------------------------------------------------------
print_test_header "Test 10: empty state root is non-fatal"
setup_test
out="$(run_hook "new-10")"
assert_eq "T10: no stdout" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 11: malformed resume_request.json → skipped, other valid rows fire
# ---------------------------------------------------------------------------
print_test_header "Test 11: malformed JSON does not crash"
setup_test
make_request "sess-rl-11a" "${TEST_HOME}" "Ship valid." "/ulw foo" "rate_limit"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/sess-rl-11b"
printf 'this is not JSON' > "${TEST_HOME}/.claude/quality-pack/state/sess-rl-11b/resume_request.json"
out="$(run_hook "new-11")"
assert_contains "T11: hint emitted from valid artifact" "Ship valid." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 12: STATE_ROOT contains flat files (hooks.log etc.) → skipped
# ---------------------------------------------------------------------------
print_test_header "Test 12: flat files in STATE_ROOT do not break scan"
setup_test
make_request "sess-rl-12" "${TEST_HOME}" "Ship Wave 1." "/ulw foo" "rate_limit"
printf 'log entry\n' > "${TEST_HOME}/.claude/quality-pack/state/hooks.log"
out="$(run_hook "new-12")"
assert_contains "T12: hint still emitted" "Ship Wave 1." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 13: invalid session_id directory (path traversal) → skipped
# ---------------------------------------------------------------------------
print_test_header "Test 13: invalid session_id dirname filtered out"
setup_test
# Create a dir whose name fails validate_session_id (contains slash via rename).
# We use a name with disallowed chars per validate_session_id (a-zA-Z0-9_.-).
# Bash limits us — use a name with a colon.
bad_dir="${TEST_HOME}/.claude/quality-pack/state/bad:name"
mkdir -p "${bad_dir}"
_now13="$(date +%s)"
jq -nc --argjson ts "${_now13}" '{schema_version:1, original_objective:"hijack", captured_at_ts:$ts, resume_attempts:0}' \
  > "${bad_dir}/resume_request.json"
make_request "sess-rl-13" "${TEST_HOME}" "Ship Wave 1." "/ulw foo" "rate_limit"
out="$(run_hook "new-13")"
assert_contains "T13: only valid artifact surfaces" "Ship Wave 1." "${out}"
assert_not_contains "T13: invalid dir's artifact does NOT surface" "hijack" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 14: multiple pending → newest selected, count surfaced
# ---------------------------------------------------------------------------
print_test_header "Test 14: multiple claimable artifacts selects newest, surfaces count"
setup_test
make_request "sess-rl-14a" "${TEST_HOME}" "Old objective." "/ulw old" "rate_limit" "-60" "-7200"
make_request "sess-rl-14b" "${TEST_HOME}" "New objective." "/ulw new" "rate_limit" "-60" "-30"
out="$(run_hook "new-14")"
assert_contains "T14: newer objective surfaces" "New objective." "${out}"
assert_not_contains "T14: older objective is suppressed" "Old objective." "${out}"
assert_contains "T14: count message present" "2 unclaimed resume requests" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 15: idempotency — second SessionStart fire in same session is silent
# ---------------------------------------------------------------------------
print_test_header "Test 15: per-session idempotency suppresses repeat emit"
setup_test
make_request "sess-rl-15" "${TEST_HOME}" "Ship Wave 1." "/ulw foo" "rate_limit"
first="$(run_hook "new-15")"
second="$(run_hook "new-15")"
assert_contains "T15: first call emits hint" "Ship Wave 1." "${first}"
assert_eq "T15: second call is silent" "" "${second}"
teardown_test

# ---------------------------------------------------------------------------
# Test 16: cwd preference — same-cwd wins over newer different-cwd
# ---------------------------------------------------------------------------
print_test_header "Test 16: same-cwd preference beats newer different-cwd"
setup_test
make_request "sess-rl-16a" "/some/other/path" "Different cwd new." "/ulw foo" "rate_limit" "-60" "-15"
make_request "sess-rl-16b" "${TEST_HOME}" "Same cwd older." "/ulw foo" "rate_limit" "-60" "-3600"
out="$(run_hook "new-16" "startup" "${TEST_HOME}")"
assert_contains "T16: same-cwd objective wins" "Same cwd older." "${out}"
assert_not_contains "T16: cross-cwd warning absent (it's same cwd)" "different working directory" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 17: resume_request schema_version absent → skipped
# ---------------------------------------------------------------------------
print_test_header "Test 17: missing schema_version filtered out"
setup_test
sid="sess-rl-17"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now17="$(date +%s)"
jq -nc --argjson ts "${_now17}" '{matcher:"rate_limit", original_objective:"unversioned", captured_at_ts:$ts, resume_attempts:0}' \
  > "${sdir}/resume_request.json"
out="$(run_hook "new-17")"
assert_eq "T17: no stdout (no schema)" "" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 18: emit shape — output is valid JSON with hookSpecificOutput.additionalContext
# ---------------------------------------------------------------------------
print_test_header "Test 18: emit shape validates as expected JSON"
setup_test
make_request "sess-rl-18" "${TEST_HOME}" "Ship Wave 1." "/ulw foo" "rate_limit"
out="$(run_hook "new-18")"
echo "${out}" | python3 -m json.tool >/dev/null 2>&1 && shape_ok=1 || shape_ok=0
assert_eq "T18: output is valid JSON" "1" "${shape_ok}"
event_name="$(echo "${out}" | jq -r '.hookSpecificOutput.hookEventName')"
assert_eq "T18: hookEventName is SessionStart" "SessionStart" "${event_name}"
ctx_present="$(echo "${out}" | jq -r '.hookSpecificOutput.additionalContext | length > 0')"
assert_eq "T18: additionalContext non-empty" "true" "${ctx_present}"
teardown_test

# ---------------------------------------------------------------------------
# Test 19: P1 fix — handoff hook copies state including resume_hint_emitted,
# but the resumed session must STILL be able to surface a hint for an
# unclaimed resume_request from a different prior session.
# ---------------------------------------------------------------------------
print_test_header "Test 19: resume-handoff stale hint flag does not leak"
setup_test
# Source session A had emitted a hint and has resume_hint_emitted=1 in its
# state. The new session B inherits that state via session-start-resume-handoff.
old_session="A-source"
sdir_a="${TEST_HOME}/.claude/quality-pack/state/${old_session}"
mkdir -p "${sdir_a}"
jq -nc '{cwd: "/tmp", resume_hint_emitted: "1", resume_hint_emitted_sess_old: "1"}' \
  > "${sdir_a}/session_state.json"

# Pre-populate the new session's state via the (extended) handoff hook
# behavior — copy + clear. We simulate the sub-set of handoff that
# matters here: copy state, then handoff clears resume_hint_emitted*.
new_session="new-19"
sdir_b="${TEST_HOME}/.claude/quality-pack/state/${new_session}"
mkdir -p "${sdir_b}"
cp "${sdir_a}/session_state.json" "${sdir_b}/session_state.json"
# Apply the handoff's resume-hint-flag clearing logic.
tmp="${sdir_b}/session_state.json.tmp"
jq 'with_entries(select(.key | startswith("resume_hint_emitted") | not))' \
  "${sdir_b}/session_state.json" > "${tmp}" && mv -f "${tmp}" "${sdir_b}/session_state.json"

# Now create a fresh, unclaimed artifact from a DIFFERENT prior session.
make_request "C-fresh" "${TEST_HOME}" "Wave 1 P1 fix verification." "/ulw fix it" "rate_limit"

out="$(run_hook "${new_session}")"
assert_contains "T19: hint emitted despite legacy flag in copied state" "Wave 1 P1 fix verification." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 20: project-key match scope — different cwd, same project_key
# ---------------------------------------------------------------------------
print_test_header "Test 20: project-match scope when cwds differ but project_key matches"
setup_test
# Compute a project_key the new session will match. Use a non-git cwd,
# so target_project_key falls back to a cwd-hash. Match by encoding the
# same hash into the artifact's project_key field.
target_cwd="${TEST_HOME}/projA"
mkdir -p "${target_cwd}"
shared_key="$(printf '%s' "${target_cwd}" | shasum -a 256 2>/dev/null | cut -c1-12)"
make_request "sess-rl-20" "/some/other/path" "Project-match objective." "/ulw foo" "rate_limit" \
  "-60" "-30" "0" "null" "${shared_key}"
out="$(run_hook "new-20" "startup" "${target_cwd}")"
assert_contains "T20: hint mentions project-match scope label" "Same project, different working directory" "${out}"
assert_contains "T20: hint surfaces the project-matched objective" "Project-match objective." "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 21: per-artifact idempotency — different artifact in same session still hints
# ---------------------------------------------------------------------------
print_test_header "Test 21: per-artifact idempotency permits second-artifact hint in same session"
setup_test
make_request "sess-rl-21a" "${TEST_HOME}" "First objective." "/ulw a" "rate_limit"
out_a="$(run_hook "new-21")"
assert_contains "T21: first artifact hint emitted" "First objective." "${out_a}"

# Now claim the first artifact (set resumed_at_ts) — Wave 2 will do
# this atomically; we simulate. Also create a SECOND unclaimed artifact.
sdir_a="${TEST_HOME}/.claude/quality-pack/state/sess-rl-21a"
tmp="${sdir_a}/resume_request.json.tmp"
jq --argjson now "$(date +%s)" '. + {resumed_at_ts: $now, resume_attempts: 1}' \
  "${sdir_a}/resume_request.json" > "${tmp}" && mv -f "${tmp}" "${sdir_a}/resume_request.json"

make_request "sess-rl-21b" "${TEST_HOME}" "Second objective." "/ulw b" "rate_limit"
out_b="$(run_hook "new-21")"
assert_contains "T21: second artifact hint emitted in same session" "Second objective." "${out_b}"
# Both per-artifact flags should now be set.
state_a="$(jq -r '.resume_hint_emitted_sess_rl_21a // .["resume_hint_emitted_sess-rl-21a"] // ""' \
  "${TEST_HOME}/.claude/quality-pack/state/new-21/session_state.json")"
state_b="$(jq -r '.resume_hint_emitted_sess_rl_21b // .["resume_hint_emitted_sess-rl-21b"] // ""' \
  "${TEST_HOME}/.claude/quality-pack/state/new-21/session_state.json")"
assert_eq "T21: flag-A set" "1" "${state_a}"
assert_eq "T21: flag-B set" "1" "${state_b}"
teardown_test

# ---------------------------------------------------------------------------
# Test 22: resume_hint.md sidecar shape includes frontmatter fields
# ---------------------------------------------------------------------------
print_test_header "Test 22: sidecar markdown frontmatter shape"
setup_test
make_request "sess-rl-22" "${TEST_HOME}" "Sidecar test." "/ulw foo" "rate_limit"
run_hook "new-22" >/dev/null
sidecar_path="${TEST_HOME}/.claude/quality-pack/state/new-22/resume_hint.md"
content="$(cat "${sidecar_path}" 2>/dev/null || echo "")"
assert_contains "T22: sidecar exists with origin_session_id frontmatter" "origin_session_id: sess-rl-22" "${content}"
assert_contains "T22: sidecar contains match_scope frontmatter" "match_scope: cwd-match" "${content}"
assert_contains "T22: sidecar contains matcher" "matcher: rate_limit" "${content}"
assert_contains "T22: sidecar contains body objective" "Sidecar test." "${content}"
teardown_test

# ---------------------------------------------------------------------------
# Test 23: Wave-2-readiness — /ulw-resume skill missing → manual fallback
# ---------------------------------------------------------------------------
print_test_header "Test 23: missing /ulw-resume skill yields manual-fallback advice"
setup_test
make_request "sess-rl-23" "${TEST_HOME}" "Wave 2 not yet installed." "/ulw foo" "rate_limit"
out="$(run_hook "new-23")"
assert_contains "T23: hint advises manual replay" "is not yet installed" "${out}"
assert_contains "T23: hint suggests paste-ready imperative" "paste-ready imperative" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 24: Wave-2-installed → /ulw-resume advised directly
# ---------------------------------------------------------------------------
print_test_header "Test 24: /ulw-resume skill present routes hint to skill invocation"
setup_test
mkdir -p "${TEST_HOME}/.claude/skills/ulw-resume"
printf -- '---\nname: ulw-resume\n---\nstub\n' > "${TEST_HOME}/.claude/skills/ulw-resume/SKILL.md"
make_request "sess-rl-24" "${TEST_HOME}" "Wave 2 installed." "/ulw foo" "rate_limit"
out="$(run_hook "new-24")"
assert_contains "T24: hint references the /ulw-resume skill directly" "invoke the \`/ulw-resume\` skill" "${out}"
assert_not_contains "T24: hint does NOT show manual-fallback wording" "is not yet installed" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 25: pluralization — 1 minute vs 5 minutes
# ---------------------------------------------------------------------------
print_test_header "Test 25: humanize_delta singular vs plural"
setup_test
# Reset 70s ago → "1 minute ago".
make_request "sess-rl-25a" "${TEST_HOME}" "Singular check." "/ulw foo" "rate_limit" "-70"
out_singular="$(run_hook "new-25a")"
assert_contains "T25: 1 minute ago (singular)" "1 minute ago" "${out_singular}"
assert_not_contains "T25: no minute(s) stutter" "minute(s)" "${out_singular}"
teardown_test
setup_test
# Reset 300s ago → "5 minutes ago".
make_request "sess-rl-25b" "${TEST_HOME}" "Plural check." "/ulw foo" "rate_limit" "-300"
out_plural="$(run_hook "new-25b")"
assert_contains "T25: 5 minutes ago (plural)" "5 minutes ago" "${out_plural}"
teardown_test

# ---------------------------------------------------------------------------
# Test 26: combined cwd notes — different cwd AND cwd no longer exists
# ---------------------------------------------------------------------------
print_test_header "Test 26: cross-cwd + missing-cwd notes both surface"
setup_test
# Deliberately point at a path that does not exist. Different from the
# new session's cwd, so match_scope=other-cwd.
make_request "sess-rl-26" "/no/such/dir/anywhere" "Both notes." "/ulw foo" "rate_limit"
out="$(run_hook "new-26" "startup" "${TEST_HOME}")"
assert_contains "T26: cross-cwd note present" "different working directory" "${out}"
assert_contains "T26: missing-cwd note present" "no longer exists" "${out}"
teardown_test

# ---------------------------------------------------------------------------
# Test 27: resume_hint_emitted with NEW session-id-keyed shape
# ---------------------------------------------------------------------------
print_test_header "Test 27: invalid origin session_id falls back to legacy global key"
setup_test
# Build an artifact whose session_id is empty — exercise the fallback to
# the bare `resume_hint_emitted` key. Bypass make_request to set empty.
sid="sess-rl-27"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now27="$(date +%s)"
jq -nc --argjson cap "$((_now27 - 30))" --argjson rs "$((_now27 - 60))" '
  {schema_version:1, rate_limited:true, matcher:"rate_limit",
   hook_event_name:"StopFailure", session_id:"",
   cwd:"'"${TEST_HOME}"'", project_key:null, transcript_path:"",
   original_objective:"empty session_id artifact",
   last_user_prompt:"/ulw foo", resets_at_ts:$rs, captured_at_ts:$cap,
   model_id:null, resume_attempts:0, resumed_at_ts:null,
   rate_limit_snapshot:null}' > "${sdir}/resume_request.json"
out="$(run_hook "new-27")"
assert_contains "T27: hint still emits" "empty session_id artifact" "${out}"
state_flag="$(jq -r '.resume_hint_emitted // ""' \
  "${TEST_HOME}/.claude/quality-pack/state/new-27/session_state.json")"
assert_eq "T27: legacy global key set when origin sid is invalid" "1" "${state_flag}"
teardown_test

# ---------------------------------------------------------------------------
# Test 28: dismissed artifact (Wave 2 --dismiss) does not surface in hint
# ---------------------------------------------------------------------------
print_test_header "Test 28: dismissed artifact suppresses hint"
setup_test
sid="sess-rl-28"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
make_request "${sid}" "${TEST_HOME}" "Dismissed objective." "/ulw foo" "rate_limit"
# Stamp dismissed_at_ts directly to simulate a prior /ulw-resume --dismiss.
_now28="$(date +%s)"
tmp="${sdir}/resume_request.json.tmp"
jq --argjson now "${_now28}" '. + {dismissed_at_ts: $now}' \
  "${sdir}/resume_request.json" > "${tmp}" && mv -f "${tmp}" "${sdir}/resume_request.json"
out="$(run_hook "new-28")"
assert_eq "T28: hint absent for dismissed artifact" "" "${out}"
teardown_test

printf '\n=== Summary ===\n'
printf 'Passed: %d\nFailed: %d\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
