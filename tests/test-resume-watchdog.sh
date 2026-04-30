#!/usr/bin/env bash
#
# Tests for quality-pack/scripts/resume-watchdog.sh — the headless
# resume daemon (Wave 3 of the auto-resume harness). Mocks `tmux`,
# `claude`, `osascript`, and `notify-send` to avoid spawning real
# child processes; asserts the watchdog calls the right verbs in
# the right order under each scenario.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCHDOG="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/resume-watchdog.sh"

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
ORIG_PATH="${PATH}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/scripts"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
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

  # Mock dir on PATH for tmux / claude / notify-send / osascript.
  MOCK_BIN="${TEST_HOME}/.mockbin"
  mkdir -p "${MOCK_BIN}"
  export PATH="${MOCK_BIN}:${ORIG_PATH}"

  # Default: opt the watchdog ON for tests.
  export OMC_RESUME_WATCHDOG=on
  unset OMC_STOP_FAILURE_CAPTURE 2>/dev/null || true
  unset OMC_RESUME_WATCHDOG_COOLDOWN_SECS 2>/dev/null || true
  unset SESSION_ID 2>/dev/null || true
}

teardown_test() {
  cd "${ORIG_PWD}" 2>/dev/null || true
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  unset OMC_RESUME_WATCHDOG 2>/dev/null || true
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

# Install a mock binary. Logs every invocation to a file the test can
# inspect afterwards.
install_mock() {
  local name="$1"
  local exit_code="${2:-0}"
  local log="${MOCK_BIN}/${name}.calls"
  cat > "${MOCK_BIN}/${name}" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${log}"
exit ${exit_code}
MOCK
  chmod +x "${MOCK_BIN}/${name}"
}

# Install a tmux mock that distinguishes \`has-session\` (returns 1 —
# "session does NOT exist", letting the watchdog proceed to launch)
# from other subcommands (\`new-session\` etc., return 0). Real tmux
# behaves the same way.
install_tmux_mock() {
  local log="${MOCK_BIN}/tmux.calls"
  cat > "${MOCK_BIN}/tmux" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${log}"
case "\$1" in
  has-session) exit 1 ;;   # No existing session.
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_BIN}/tmux"
}

remove_mock() {
  local name="$1"
  rm -f "${MOCK_BIN}/${name}" "${MOCK_BIN}/${name}.calls" 2>/dev/null || true
}

mock_calls() {
  local name="$1"
  cat "${MOCK_BIN}/${name}.calls" 2>/dev/null || echo ""
}

# Build a claimable resume_request.json; returns its path on stdout.
make_request() {
  local sid="$1"
  local cwd="${2:-${TEST_HOME}}"
  local objective="${3:-Ship the wave.}"
  local last_prompt="${4:-/ulw resume the wave}"
  local matcher="${5:-rate_limit}"
  local resets_offset="${6:--120}"   # 2min in the past = window cleared
  local captured_offset="${7:--300}"

  local now_ts
  now_ts="$(date +%s)"
  local captured_ts=$((now_ts + captured_offset))
  local resets_ts=$((now_ts + resets_offset))
  local rate_limited="true"
  [[ "${matcher}" == "rate_limit" ]] || rate_limited="false"

  local sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${sdir}"
  jq -nc \
    --arg sid "${sid}" --arg cwd "${cwd}" --arg obj "${objective}" \
    --arg lp "${last_prompt}" --arg mat "${matcher}" \
    --argjson rl "${rate_limited}" \
    --argjson cap "${captured_ts}" --argjson rs "${resets_ts}" \
    '{schema_version:1, rate_limited:$rl, matcher:$mat,
      hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
      project_key:null, transcript_path:"",
      original_objective:$obj, last_user_prompt:$lp,
      resets_at_ts:$rs, captured_at_ts:$cap,
      model_id:"claude-opus-4-7",
      resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null}' \
    > "${sdir}/resume_request.json"
  printf '%s' "${sdir}/resume_request.json"
}

read_field() {
  local path="$1" field="$2"
  jq -r ".${field} // empty" "${path}" 2>/dev/null || true
}

print_test_header() {
  printf '\n=== %s ===\n' "$1"
}

# ---------------------------------------------------------------------------
# T1: tmux + claude available, claimable artifact for existing cwd → launch
# ---------------------------------------------------------------------------
print_test_header "T1: tmux launch happy path"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-1" "${TEST_HOME}" "Wave 3 happy path." "/ulw ship wave 3")"
bash "${WATCHDOG}" >/dev/null 2>&1
tmux_calls="$(mock_calls tmux)"
assert_contains "T1: tmux invoked with new-session -d" "new-session -d -s omc-resume-sess-1" "${tmux_calls}"
assert_contains "T1: tmux launches claude --resume" "claude --resume 'sess-1'" "${tmux_calls}"
assert_contains "T1: tmux passes verbatim prompt" "/ulw ship wave 3" "${tmux_calls}"
# Artifact must be claimed.
assert_eq "T1: artifact resume_attempts = 1 after launch" "1" "$(read_field "${target}" resume_attempts)"
assert_eq "T1: outcome = watchdog-launched" "watchdog-launched" \
  "$(read_field "${target}" last_attempt_outcome)"
teardown_test

# ---------------------------------------------------------------------------
# T2: rate-limit reset still in future → skipped, no claim
# ---------------------------------------------------------------------------
print_test_header "T2: future reset epoch skipped"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-2" "${TEST_HOME}" "obj" "/ulw foo" "rate_limit" "+3600")"
bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T2: tmux NOT invoked" "" "$(mock_calls tmux)"
# But the artifact has a future reset, so find_claimable_resume_requests
# already filtered it out — this is the helper's behavior verified
# from the watchdog perspective.
assert_eq "T2: artifact unmutated" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T3: cwd missing → skipped, claim NOT issued
# ---------------------------------------------------------------------------
print_test_header "T3: missing cwd skipped"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-3" "/no/such/dir" "obj" "/ulw foo")"
bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T3: tmux NOT invoked" "" "$(mock_calls tmux)"
assert_eq "T3: artifact unmutated" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T4: no tmux → notification fallback (osascript on macOS, notify-send on Linux)
# ---------------------------------------------------------------------------
print_test_header "T4: no tmux falls back to notification"
setup_test
install_mock claude 0
install_mock notify-send 0
install_mock osascript 0
# Strict-PATH override: drop the inherited PATH (which on a dev box may
# already have a real tmux from `brew install`) so `command -v tmux`
# returns nothing and the watchdog takes the no-tmux fallback branch.
# Includes /usr/bin:/bin for sed, jq, etc. that are dependencies of
# common.sh helpers — strictly bare PATH would break the helper chain.
target="$(make_request "sess-4" "${TEST_HOME}" "Notify me." "/ulw foo")"
PATH="${MOCK_BIN}:/usr/bin:/bin" bash "${WATCHDOG}" >/dev/null 2>&1
notifier_called=0
[[ -n "$(mock_calls osascript)" ]] && notifier_called=1
[[ -n "$(mock_calls notify-send)" ]] && notifier_called=1
assert_eq "T4: a notifier was invoked" "1" "${notifier_called}"
# Watchdog must NOT claim under notification fallback (user-initiated only).
assert_eq "T4: artifact NOT claimed" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T5: opt-out (OMC_RESUME_WATCHDOG=off) → no-op
# ---------------------------------------------------------------------------
print_test_header "T5: watchdog opt-out exits cleanly"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-5" "${TEST_HOME}" "obj")"
OMC_RESUME_WATCHDOG=off bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T5: tmux NOT invoked" "" "$(mock_calls tmux)"
assert_eq "T5: artifact unmutated" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T6: privacy opt-out (stop_failure_capture=off) → no-op
# ---------------------------------------------------------------------------
print_test_header "T6: privacy opt-out exits cleanly"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-6" "${TEST_HOME}" "obj")"
OMC_STOP_FAILURE_CAPTURE=off bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T6: tmux NOT invoked" "" "$(mock_calls tmux)"
assert_eq "T6: artifact unmutated" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T7: cooldown — recent last_attempt_ts skips
# ---------------------------------------------------------------------------
print_test_header "T7: cooldown gates re-launch"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-7" "${TEST_HOME}" "obj")"
# Stamp last_attempt_ts to 30s ago (well within default 600s cooldown).
now_ts="$(date +%s)"
recent_ts=$((now_ts - 30))
tmp="${target}.tmp"
jq --argjson t "${recent_ts}" '. + {last_attempt_ts: $t, resume_attempts: 1}' \
  "${target}" > "${tmp}" && mv -f "${tmp}" "${target}"
bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T7: tmux NOT invoked (cooldown)" "" "$(mock_calls tmux)"
teardown_test

# ---------------------------------------------------------------------------
# T8: empty payload → skipped, no claim
# ---------------------------------------------------------------------------
print_test_header "T8: empty original_objective + last_user_prompt skipped"
setup_test
install_tmux_mock
install_mock claude 0
# Build directly — make_request's :- defaults substitute on empty
# strings, defeating the purpose of an empty-payload test.
sid="sess-8"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now8="$(date +%s)"
jq -nc \
  --arg sid "${sid}" --arg cwd "${TEST_HOME}" \
  --argjson cap "$((_now8 - 60))" --argjson rs "$((_now8 - 30))" \
  '{schema_version:1, rate_limited:true, matcher:"rate_limit",
    hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
    project_key:null, transcript_path:"",
    original_objective:"", last_user_prompt:"",
    resets_at_ts:$rs, captured_at_ts:$cap, model_id:null,
    resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null}' \
  > "${sdir}/resume_request.json"
target="${sdir}/resume_request.json"
bash "${WATCHDOG}" >/dev/null 2>&1
# `grep -c` exits 1 when zero matches; combine its stdout with `|| true`
# inline so a no-match yields exactly "0" (not "0\n0" from `|| echo 0`).
new_session_count="$(printf '%s' "$(mock_calls tmux)" | grep -c new-session 2>/dev/null || true)"
new_session_count="${new_session_count:-0}"
assert_eq "T8: tmux new-session NOT invoked (empty payload)" "0" "${new_session_count}"
assert_eq "T8: artifact unmutated" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T9: launch cap of 1 — multiple claimable artifacts → only first launches
# ---------------------------------------------------------------------------
print_test_header "T9: 1-launch-per-tick cap"
setup_test
install_tmux_mock
install_mock claude 0
make_request "sess-9a" "${TEST_HOME}" "First obj." "/ulw a" > /dev/null
sleep 1   # ensure 9b is captured AFTER 9a so the helper's sort order is stable
make_request "sess-9b" "${TEST_HOME}" "Second obj." "/ulw b" > /dev/null
bash "${WATCHDOG}" >/dev/null 2>&1
launch_count="$(printf '%s' "$(mock_calls tmux)" | grep -c new-session || echo 0)"
assert_eq "T9: exactly one tmux new-session call" "1" "${launch_count}"
teardown_test

# ---------------------------------------------------------------------------
# T10: claimed artifact (resumed_at_ts set) is invisible to helper, no launch
# ---------------------------------------------------------------------------
print_test_header "T10: already-claimed artifact ignored"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-10" "${TEST_HOME}" "obj")"
# Stamp resumed_at_ts.
now_ts="$(date +%s)"
tmp="${target}.tmp"
jq --argjson t "${now_ts}" '. + {resumed_at_ts: $t, resume_attempts: 1}' \
  "${target}" > "${tmp}" && mv -f "${tmp}" "${target}"
bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T10: tmux NOT invoked" "" "$(mock_calls tmux)"
teardown_test

# ---------------------------------------------------------------------------
# T11: dismissed artifact (dismissed_at_ts set) ignored
# ---------------------------------------------------------------------------
print_test_header "T11: dismissed artifact ignored"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-11" "${TEST_HOME}" "obj")"
now_ts="$(date +%s)"
tmp="${target}.tmp"
jq --argjson t "${now_ts}" '. + {dismissed_at_ts: $t}' \
  "${target}" > "${tmp}" && mv -f "${tmp}" "${target}"
bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T11: tmux NOT invoked (dismissed)" "" "$(mock_calls tmux)"
teardown_test

# ---------------------------------------------------------------------------
# T12: prompt with embedded single quotes survives shell escaping
# ---------------------------------------------------------------------------
print_test_header "T12: prompt with single quotes escapes correctly"
setup_test
install_tmux_mock
install_mock claude 0
make_request "sess-12" "${TEST_HOME}" "obj" "/ulw don't break it" > /dev/null
bash "${WATCHDOG}" >/dev/null 2>&1
calls="$(mock_calls tmux)"
# tmux call should include "don" "t" — verifying the shell escaping
# survived (don't would otherwise cause syntax errors).
assert_contains "T12: tmux call references 'don't' contents" "don" "${calls}"
assert_contains "T12: tmux call contains break it" "break it" "${calls}"
teardown_test

# ---------------------------------------------------------------------------
# T13: gate-event tick-complete row written
# ---------------------------------------------------------------------------
print_test_header "T13: tick-complete gate event recorded"
setup_test
install_tmux_mock
install_mock claude 0
make_request "sess-13" "${TEST_HOME}" "obj" "/ulw foo" > /dev/null
# The watchdog records to the gate_events.jsonl of the active session.
# Since the watchdog runs without a SESSION_ID env var, it lacks a
# session dir to write to. record_gate_event silently no-ops without
# SESSION_ID. To verify the row is written, set SESSION_ID before
# invoking. This is what a cron-spawned watchdog effectively gets if
# the user's environment seeds it.
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/active-sess"
SESSION_ID=active-sess bash "${WATCHDOG}" >/dev/null 2>&1
events_file="${TEST_HOME}/.claude/quality-pack/state/active-sess/gate_events.jsonl"
events="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "T13: tick-complete row recorded" "tick-complete" "${events}"
assert_contains "T13: launched-tmux row recorded" "launched-tmux" "${events}"
teardown_test

# ---------------------------------------------------------------------------
# T14: launch-then-claim ordering — claim happens BEFORE tmux fires
# ---------------------------------------------------------------------------
print_test_header "T14: claim ordered before launch"
setup_test
install_mock claude 0
# tmux mock writes to a file ONLY if the artifact is already claimed.
# Implementation: tmux mock reads the artifact and asserts resumed_at_ts is set.
target_inspect="${TEST_HOME}/.claude/quality-pack/state/sess-14/resume_request.json"
cat > "${MOCK_BIN}/tmux" <<MOCK
#!/usr/bin/env bash
# Verify the artifact was claimed BEFORE tmux fires.
if [[ -f "${target_inspect}" ]]; then
  resumed_ts=\$(jq -r '.resumed_at_ts // ""' "${target_inspect}" 2>/dev/null)
  if [[ -n "\${resumed_ts}" ]] && [[ "\${resumed_ts}" != "null" ]]; then
    printf 'CLAIMED-FIRST\n' > "${MOCK_BIN}/tmux.ordering"
  else
    printf 'NOT-CLAIMED\n' > "${MOCK_BIN}/tmux.ordering"
  fi
fi
exit 0
MOCK
chmod +x "${MOCK_BIN}/tmux"
make_request "sess-14" "${TEST_HOME}" "Order test." "/ulw foo" > /dev/null
bash "${WATCHDOG}" >/dev/null 2>&1
ordering="$(cat "${MOCK_BIN}/tmux.ordering" 2>/dev/null || echo "")"
assert_eq "T14: claim ordered before launch" "CLAIMED-FIRST" "${ordering}"
teardown_test

# ---------------------------------------------------------------------------
# T15: chain-depth cap — origin_chain_depth + resume_attempts ≥ 3 → refused
# ---------------------------------------------------------------------------
print_test_header "T15: chain-depth cap blocks runaway resume"
setup_test
install_tmux_mock
install_mock claude 0
sid="sess-15"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now15="$(date +%s)"
# Already-resumed-twice chain (depth=2), no per-artifact attempts. Sum = 2 → still allowed.
jq -nc \
  --arg sid "${sid}" --arg cwd "${TEST_HOME}" \
  --argjson cap "$((_now15 - 60))" --argjson rs "$((_now15 - 120))" \
  '{schema_version:1, rate_limited:true, matcher:"rate_limit",
    hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
    project_key:null, transcript_path:"",
    original_objective:"Chain test.", last_user_prompt:"/ulw chain",
    resets_at_ts:$rs, captured_at_ts:$cap, model_id:null,
    resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null,
    origin_session_id:"sess-zero", origin_chain_depth:2}' \
  > "${sdir}/resume_request.json"
target="${sdir}/resume_request.json"
bash "${WATCHDOG}" >/dev/null 2>&1
launch_count="$(printf '%s' "$(mock_calls tmux)" | grep -c new-session 2>/dev/null || true)"
launch_count="${launch_count:-0}"
assert_eq "T15a: chain depth=2 + 0 attempts → still allowed (sum<3)" "1" "${launch_count}"
teardown_test

# Now chain depth=3 → cap, no launch.
setup_test
install_tmux_mock
install_mock claude 0
sid="sess-15b"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now15b="$(date +%s)"
jq -nc \
  --arg sid "${sid}" --arg cwd "${TEST_HOME}" \
  --argjson cap "$((_now15b - 60))" --argjson rs "$((_now15b - 120))" \
  '{schema_version:1, rate_limited:true, matcher:"rate_limit",
    hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
    project_key:null, transcript_path:"",
    original_objective:"Capped.", last_user_prompt:"/ulw capped",
    resets_at_ts:$rs, captured_at_ts:$cap, model_id:null,
    resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null,
    origin_session_id:"sess-zero", origin_chain_depth:3}' \
  > "${sdir}/resume_request.json"
target="${sdir}/resume_request.json"
bash "${WATCHDOG}" >/dev/null 2>&1
launch_count="$(printf '%s' "$(mock_calls tmux)" | grep -c new-session 2>/dev/null || true)"
launch_count="${launch_count:-0}"
assert_eq "T15b: chain depth=3 → cap, no launch" "0" "${launch_count}"
assert_eq "T15b: artifact resume_attempts unchanged" "0" "$(read_field "${target}" resume_attempts)"
teardown_test

# Sum cap: chain depth=1 + 2 prior attempts = 3 → blocked.
setup_test
install_tmux_mock
install_mock claude 0
sid="sess-15c"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now15c="$(date +%s)"
jq -nc \
  --arg sid "${sid}" --arg cwd "${TEST_HOME}" \
  --argjson cap "$((_now15c - 60))" --argjson rs "$((_now15c - 120))" \
  '{schema_version:1, rate_limited:true, matcher:"rate_limit",
    hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
    project_key:null, transcript_path:"",
    original_objective:"Sum cap.", last_user_prompt:"/ulw sum",
    resets_at_ts:$rs, captured_at_ts:$cap, model_id:null,
    resume_attempts:2, resumed_at_ts:null, rate_limit_snapshot:null,
    origin_session_id:"sess-zero", origin_chain_depth:1}' \
  > "${sdir}/resume_request.json"
# Override cooldown so the prior attempt does not interfere.
OMC_RESUME_WATCHDOG_COOLDOWN_SECS=1 bash "${WATCHDOG}" >/dev/null 2>&1
launch_count="$(printf '%s' "$(mock_calls tmux)" | grep -c new-session 2>/dev/null || true)"
launch_count="${launch_count:-0}"
assert_eq "T15c: depth=1 + attempts=2 → cap-sum=3 → blocked" "0" "${launch_count}"
teardown_test

# ---------------------------------------------------------------------------
# T16: telemetry — gate-event rows write to synthetic _watchdog session
# ---------------------------------------------------------------------------
print_test_header "T16: telemetry writes to _watchdog synthetic session"
setup_test
install_tmux_mock
install_mock claude 0
make_request "sess-16" "${TEST_HOME}" "Telemetry test." "/ulw foo" > /dev/null
# Run watchdog with NO SESSION_ID — the daemon path.
unset SESSION_ID 2>/dev/null || true
bash "${WATCHDOG}" >/dev/null 2>&1
events_file="${TEST_HOME}/.claude/quality-pack/state/_watchdog/gate_events.jsonl"
assert_eq "T16: synthetic session dir created" "1" \
  "$([[ -d "${TEST_HOME}/.claude/quality-pack/state/_watchdog" ]] && echo 1 || echo 0)"
assert_eq "T16: gate_events.jsonl exists" "1" \
  "$([[ -f "${events_file}" ]] && echo 1 || echo 0)"
events="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "T16: tick-complete row recorded" "tick-complete" "${events}"
assert_contains "T16: launched-tmux row recorded" "launched-tmux" "${events}"
teardown_test

# ---------------------------------------------------------------------------
# T17: prompt with backticks survives shell escaping
# ---------------------------------------------------------------------------
print_test_header "T17: prompt with backticks not expanded"
setup_test
install_tmux_mock
install_mock claude 0
# Bash positional-args won't deliver backticks intact via the test
# helper — build the artifact directly to control the literal value.
sid="sess-17"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now17="$(date +%s)"
jq -nc \
  --arg sid "${sid}" --arg cwd "${TEST_HOME}" \
  --argjson cap "$((_now17 - 60))" --argjson rs "$((_now17 - 120))" \
  '{schema_version:1, rate_limited:true, matcher:"rate_limit",
    hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
    project_key:null, transcript_path:"",
    original_objective:"Backticks test.",
    last_user_prompt:"/ulw run `whoami` and $(date)",
    resets_at_ts:$rs, captured_at_ts:$cap, model_id:null,
    resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null}' \
  > "${sdir}/resume_request.json"
bash "${WATCHDOG}" >/dev/null 2>&1
calls="$(mock_calls tmux)"
# tmux call should contain the LITERAL backticks and $() — the
# single-quoting in the watchdog prevents tmux/bash from expanding them.
assert_contains "T17: backtick literal preserved" "whoami" "${calls}"
assert_contains 'T17: command-substitution literal preserved' "date" "${calls}"
# Ensure the literal form is preserved (not expanded into the user's hostname etc).
# The mock captures the raw arg list — `whoami` should appear with the
# backticks character if the escaping kept them intact.
case "${calls}" in
  *'`whoami`'*)
    pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: T17: backticks not preserved literally in tmux call\n    actual: %s\n' "${calls}" >&2
    fail=$((fail + 1)) ;;
esac
teardown_test

# ---------------------------------------------------------------------------
# T18: prompt with newline preserved
# ---------------------------------------------------------------------------
print_test_header "T18: prompt with embedded newline preserved"
setup_test
install_tmux_mock
install_mock claude 0
sid="sess-18"
sdir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${sdir}"
_now18="$(date +%s)"
# Use jq's literal string-with-newline syntax. The artifact stores
# the prompt with a real \n inside.
jq -nc \
  --arg sid "${sid}" --arg cwd "${TEST_HOME}" \
  --arg prompt "line one
line two" \
  --argjson cap "$((_now18 - 60))" --argjson rs "$((_now18 - 120))" \
  '{schema_version:1, rate_limited:true, matcher:"rate_limit",
    hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
    project_key:null, transcript_path:"",
    original_objective:"Newline test.", last_user_prompt:$prompt,
    resets_at_ts:$rs, captured_at_ts:$cap, model_id:null,
    resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null}' \
  > "${sdir}/resume_request.json"
bash "${WATCHDOG}" >/dev/null 2>&1
calls="$(mock_calls tmux)"
assert_contains "T18: 'line one' present" "line one" "${calls}"
assert_contains "T18: 'line two' present" "line two" "${calls}"
teardown_test

printf '\n=== test-resume-watchdog: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
