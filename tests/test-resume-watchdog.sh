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

# Resolve a dependency from the original PATH and symlink it into
# MOCK_BIN. Skips silently if the dependency is missing or the link
# already exists — idempotent across re-invocation. Used by setup_test
# so any test can run with `PATH=${MOCK_BIN}` (strict isolation) and
# still find the binaries common.sh / resume-watchdog.sh / their
# claim-helper subprocesses need.
#
# `bash` is included because resume-watchdog.sh invokes
# `bash "${CLAIM_HELPER}" ...` as a subprocess (lines 149 + 225).
# Without it, a strict-PATH test exits 127 the moment the watchdog
# tries to call the claim helper.
install_path_deps() {
  local dep src
  for dep in bash jq sed date mkdir cat grep awk find rm mv touch chmod \
             head tail tr cut sort dirname basename printf readlink \
             xargs uname tee cp mktemp rmdir realpath flock stat ls \
             id wc tac ln chown chgrp env sleep kill sha256sum shasum \
             paste; do
    [[ -e "${MOCK_BIN}/${dep}" ]] && continue
    src="$(PATH="${ORIG_PATH}" command -v "${dep}" 2>/dev/null || true)"
    if [[ -n "${src}" && -x "${src}" ]]; then
      ln -sf "${src}" "${MOCK_BIN}/${dep}"
    fi
  done
}

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

  # Symlink common.sh / watchdog dependencies into MOCK_BIN so a test
  # that needs strict-PATH isolation (T4 — no tmux) can drop the
  # system PATH entirely without breaking the helper chain. On Ubuntu
  # CI `tmux` lives at `/usr/bin/tmux`, so the prior workaround of
  # `PATH=MOCK_BIN:/usr/bin:/bin` failed to mask it. Pinning to
  # `PATH=MOCK_BIN` only with these symlinks present is the portable
  # fix. Skips `tmux` so tests can install a tmux mock when they need
  # one (and T4 relies on tmux being absent).
  install_path_deps

  # Keep common.sh's project-level config walk inside the isolated
  # fixture. With HOME pointed at TEST_HOME but PWD left under the real
  # home, the upward walk can reach the user's ~/.claude/oh-my-claude.conf
  # and treat it as project config because it no longer equals $HOME.
  cd "${TEST_HOME}"

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
# v1.29.0 F-1 fix: pass command as separate argv tokens after `--` so
# tmux's args_escape handles shell-escaping internally rather than
# trusting hand-rolled single-quoting in a shell-command string.
# v1.31.0 Wave 1: resolve_claude_binary returns the absolute path of
# the `claude` binary (live `command -v claude` when no pin set, OR the
# pinned OMC_CLAUDE_BIN when set). The substring 'claude --resume
# sess-1' matches both bare-name and absolute-path forms because the
# resolved path always ends in `claude`. Tighter check: assert `--`
# argv-separator is in the call line followed by something ending in
# `claude` and then `--resume sess-1`.
assert_contains "T1: tmux uses -- argv-token form" "-- " "${tmux_calls}"
assert_contains "T1: tmux invokes claude --resume sess-1" "claude --resume sess-1" "${tmux_calls}"
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
# Strict-PATH override: drop the inherited PATH entirely so `command -v
# tmux` cannot find the system tmux. Earlier workaround of
# `PATH=MOCK_BIN:/usr/bin:/bin` failed on Ubuntu CI (tmux lives at
# /usr/bin/tmux). setup_test runs install_path_deps to symlink jq, sed,
# date, etc. into MOCK_BIN so common.sh's helper chain still resolves
# under PATH=MOCK_BIN — no system PATH needed.
target="$(make_request "sess-4" "${TEST_HOME}" "Notify me." "/ulw foo")"
PATH="${MOCK_BIN}" bash "${WATCHDOG}" >/dev/null 2>&1
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

# ---------------------------------------------------------------------------
# T19: tmux launch fails after successful claim → claim is REVERTED so the
# next tick re-evaluates from clean slate. Without revert, last_attempt_ts
# blocks retry for cooldown_secs (default 600s) — silent black hole.
# ---------------------------------------------------------------------------
print_test_header "T19: tmux-launch-failed reverts the claim"
setup_test
install_mock claude 0
# tmux mock that succeeds on `has-session` (returns 0 = "session exists")
# so the watchdog hits the `tmux has-session` short-circuit at line 122,
# returns code 4, and triggers the revert path. T22 below covers the
# more realistic "new-session itself exits non-zero" failure mode
# (TMUX_TMPDIR unwritable / disk full) — the two together exercise both
# launch_in_tmux failure shapes the F-002 fix targets. T19 also asserts
# the marker (`tmux-launch-reverted`) and zero-baseline contract; T20
# covers the prior-preservation contract on top.
cat > "${MOCK_BIN}/tmux" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_BIN}/tmux.calls"
case "$1" in
  has-session) exit 0 ;;        # session "exists" → launch_in_tmux returns 4
  *) exit 0 ;;
esac
MOCK
# Re-write the mock with the right MOCK_BIN expansion (heredoc above is
# single-quoted to preserve $1).
sed -i.bak "s|\${MOCK_BIN}|${MOCK_BIN}|g" "${MOCK_BIN}/tmux" && rm -f "${MOCK_BIN}/tmux.bak"
chmod +x "${MOCK_BIN}/tmux"
target="$(make_request "sess-19" "${TEST_HOME}" "Revert test." "/ulw revert")"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/active-sess"
SESSION_ID=active-sess bash "${WATCHDOG}" >/dev/null 2>&1
# After revert: resumed_at_ts must be null/empty, resume_attempts must be 0
# (back to pre-claim state), last_attempt_outcome must be the marker.
assert_eq "T19: resumed_at_ts reverted to null" "" "$(read_field "${target}" resumed_at_ts)"
assert_eq "T19: resume_attempts reverted to 0" "0" "$(read_field "${target}" resume_attempts)"
assert_eq "T19: outcome marker = tmux-launch-reverted" "tmux-launch-reverted" \
  "$(read_field "${target}" last_attempt_outcome)"
events_file="${TEST_HOME}/.claude/quality-pack/state/active-sess/gate_events.jsonl"
events="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "T19: tmux-launch-failed-reverted gate event" \
  "tmux-launch-failed-reverted" "${events}"
teardown_test

# ---------------------------------------------------------------------------
# T20: revert preserves a prior last_attempt_ts (when artifact had a
# previous failed attempt before the current cycle). Demonstrates the
# revert restores PRIOR state, not always-zero state.
# ---------------------------------------------------------------------------
print_test_header "T20: revert restores prior last_attempt_ts"
setup_test
install_mock claude 0
cat > "${MOCK_BIN}/tmux" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_BIN}/tmux.calls"
case "$1" in
  has-session) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
sed -i.bak "s|\${MOCK_BIN}|${MOCK_BIN}|g" "${MOCK_BIN}/tmux" && rm -f "${MOCK_BIN}/tmux.bak"
chmod +x "${MOCK_BIN}/tmux"
target="$(make_request "sess-20" "${TEST_HOME}" "Prior attempt test." "/ulw retry")"
# Pre-stamp an old last_attempt_ts (older than cooldown so retry isn't
# blocked) and a non-zero attempts count, simulating a prior cycle.
prior_ts=$(( $(date +%s) - 3600 ))
tmp="${target}.tmp"
jq --argjson t "${prior_ts}" '. + {last_attempt_ts: $t, resume_attempts: 1}' \
  "${target}" > "${tmp}" && mv -f "${tmp}" "${target}"
bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T20: last_attempt_ts restored to prior value" "${prior_ts}" \
  "$(read_field "${target}" last_attempt_ts)"
assert_eq "T20: resume_attempts restored to 1" "1" \
  "$(read_field "${target}" resume_attempts)"
teardown_test

# ---------------------------------------------------------------------------
# T21: pure-bash slug truncation handles non-ASCII sids without slicing
# mid-byte. Regression for the `head -c 24` byte-truncation polish.
# ---------------------------------------------------------------------------
print_test_header "T21: tmux session-name slug bounded + sanitized"
setup_test
install_tmux_mock
install_mock claude 0
# A long sid with disallowed `:` and `.` chars that tmux rejects in
# session names. Expected slug: tr replaces them with `_`, then the
# pure-bash `${var:0:24}` slicing caps the length at 24 ASCII chars.
# validate_session_id accepts [a-zA-Z0-9_.-]{1,128}, but tmux session
# names disallow `.` — so a sid with `.` is the realistic case where
# sanitization actually fires. 32-char sid means the slug must also
# truncate to 24.
long_sid="sess.aaaaa.bb.cc-extra-long-tail"
make_request "${long_sid}" "${TEST_HOME}" "Slug test." "/ulw foo" > /dev/null
bash "${WATCHDOG}" >/dev/null 2>&1
calls="$(mock_calls tmux)"
# Extract the slug from `new-session -d -s omc-resume-<slug>`.
slug="$(printf '%s' "${calls}" | sed -n 's/.*-s omc-resume-\([^ ]*\) -c.*/\1/p' | head -n 1)"
slug_len="${#slug}"
assert_eq "T21: slug length capped at 24" "24" "${slug_len}"
# `.` in the sid must be sanitized to `_` (tmux forbids them).
case "${slug}" in
  *.*)
    printf '  FAIL: T21: slug retains tmux-forbidden `.`: %s\n' "${slug}" >&2
    fail=$((fail + 1)) ;;
  *)
    pass=$((pass + 1)) ;;
esac
# Every remaining char must be from the allowed set.
case "${slug}" in
  *[!a-zA-Z0-9_-]*)
    printf '  FAIL: T21: slug contains forbidden chars: %s\n' "${slug}" >&2
    fail=$((fail + 1)) ;;
  *)
    pass=$((pass + 1)) ;;
esac
teardown_test

# ---------------------------------------------------------------------------
# T22: tmux `new-session` itself fails (e.g. TMUX_TMPDIR unwritable, disk
# full, signal trap during start) — the more realistic failure mode the
# F-002 fix targets. has-session returns 1 (no existing session) so the
# watchdog proceeds into new-session, which then fails. Revert must fire.
# ---------------------------------------------------------------------------
print_test_header "T22: new-session failure also triggers revert"
setup_test
install_mock claude 0
cat > "${MOCK_BIN}/tmux" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_BIN}/tmux.calls"
case "$1" in
  has-session) exit 1 ;;        # no existing session — proceed to new-session
  new-session) exit 2 ;;        # new-session fails → launch_in_tmux returns 2
  *) exit 0 ;;
esac
MOCK
sed -i.bak "s|\${MOCK_BIN}|${MOCK_BIN}|g" "${MOCK_BIN}/tmux" && rm -f "${MOCK_BIN}/tmux.bak"
chmod +x "${MOCK_BIN}/tmux"
target="$(make_request "sess-22" "${TEST_HOME}" "New-session fails." "/ulw retry")"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/active-sess"
SESSION_ID=active-sess bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T22: resumed_at_ts reverted to null" "" "$(read_field "${target}" resumed_at_ts)"
assert_eq "T22: resume_attempts reverted to 0" "0" "$(read_field "${target}" resume_attempts)"
assert_eq "T22: outcome marker = tmux-launch-reverted" "tmux-launch-reverted" \
  "$(read_field "${target}" last_attempt_outcome)"
events_file="${TEST_HOME}/.claude/quality-pack/state/active-sess/gate_events.jsonl"
events="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "T22: tmux-launch-failed-reverted gate event" \
  "tmux-launch-failed-reverted" "${events}"
# Confirm new-session WAS invoked (we want the new-session failure path,
# not the has-session short-circuit T19 covers).
calls="$(mock_calls tmux)"
assert_contains "T22: tmux new-session was invoked" "new-session" "${calls}"
teardown_test

# ---------------------------------------------------------------------------
# T23: after a revert, the NEXT watchdog tick re-evaluates the artifact
# from clean slate (fresh launch attempt) instead of being held off by
# the cooldown gate. Closes the F-002 user-visible promise that the
# revert restores eligibility, not just the field values.
# ---------------------------------------------------------------------------
print_test_header "T23: next tick after revert proceeds (no stuck cooldown)"
setup_test
install_mock claude 0
# tmux mock with a per-call counter: first invocation fails (force revert),
# second invocation succeeds (lets the next tick complete a real launch).
cat > "${MOCK_BIN}/tmux" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_BIN}/tmux.calls"
counter_file="${MOCK_BIN}/tmux.counter"
count=$(cat "${counter_file}" 2>/dev/null || echo 0)
case "$1" in
  has-session) exit 1 ;;       # never an existing session — proceed to new-session
  new-session)
    count=$((count + 1))
    printf '%s' "${count}" > "${counter_file}"
    if [[ "${count}" -eq 1 ]]; then
      exit 2                    # first new-session: fail → revert
    else
      exit 0                    # subsequent: success
    fi
    ;;
  *) exit 0 ;;
esac
MOCK
sed -i.bak "s|\${MOCK_BIN}|${MOCK_BIN}|g" "${MOCK_BIN}/tmux" && rm -f "${MOCK_BIN}/tmux.bak"
chmod +x "${MOCK_BIN}/tmux"
target="$(make_request "sess-23" "${TEST_HOME}" "Two-tick test." "/ulw retry-after-revert")"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/active-sess"
# Tick 1: launch fails, revert restores artifact.
SESSION_ID=active-sess bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T23: tick 1 left artifact reverted" "tmux-launch-reverted" \
  "$(read_field "${target}" last_attempt_outcome)"
# Tick 2: cooldown must NOT block — last_attempt_ts is back to 0 (or
# absent) per revert. New-session succeeds → real claim lands.
SESSION_ID=active-sess bash "${WATCHDOG}" >/dev/null 2>&1
assert_eq "T23: tick 2 launched successfully" "watchdog-launched" \
  "$(read_field "${target}" last_attempt_outcome)"
assert_eq "T23: resume_attempts = 1 after second-tick claim" "1" \
  "$(read_field "${target}" resume_attempts)"
new_session_count="$(printf '%s' "$(mock_calls tmux)" | grep -c 'new-session' 2>/dev/null || true)"
new_session_count="${new_session_count:-0}"
assert_eq "T23: new-session called twice across two ticks" "2" "${new_session_count}"
teardown_test

# ---------------------------------------------------------------------------
# T24-T27: v1.31.0 Wave 1 — claude_bin pin (security F-5 PATH-hijack defense)
# ---------------------------------------------------------------------------
# T24: pin valid — watchdog launches the pinned binary, not the PATH name
#
# v1.33.x note: Wave 4 (4-attacker security review on `main`) added a
# claude_bin path-prefix denylist that rejects pins under `/tmp/`,
# `/private/tmp/`, `/var/tmp/`, `/Users/Shared/`, `/dev/shm/`. On macOS
# `mktemp -d` returns `/var/folders/...` so TEST_HOME is fine; on Linux CI
# `mktemp -d` returns `/tmp/tmp.XXX` and a pin under TEST_HOME would be
# rejected, falling back to PATH and breaking the "pin honored" assertion
# below. T25/T26 don't care because they assert the FALLBACK path. T24
# specifically needs the pin honored — host the pinned binary outside the
# denylist by rooting it under `${HOME}/.cache/...`.
print_test_header "T24: claude_bin pin used for tmux launch"
setup_test
install_tmux_mock
install_mock claude 0
# Create a separate "pinned" claude in a non-PATH, non-denylist location.
# Use ORIG_HOME (the real home, line 15) — setup_test re-exports HOME to
# TEST_HOME (line 49), so `${HOME}/.cache` would resolve back under /tmp
# on Linux CI and the denylist would re-fire.
PIN_HOME_T24="$(mkdir -p "${ORIG_HOME}/.cache" 2>/dev/null && mktemp -d "${ORIG_HOME}/.cache/omc-test-pin-XXXXXX" 2>/dev/null || mktemp -d)"
mkdir -p "${PIN_HOME_T24}/.opt/bin"
cat > "${PIN_HOME_T24}/.opt/bin/claude" <<'PINNED'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'claude-pinned 1.0.0\n'; exit 0 ;;
  *) printf '%s\n' "$*" >> "${MOCK_BIN}/claude-pinned.calls"; exit 0 ;;
esac
PINNED
sed -i.bak "s|\${MOCK_BIN}|${MOCK_BIN}|g" "${PIN_HOME_T24}/.opt/bin/claude" && rm -f "${PIN_HOME_T24}/.opt/bin/claude.bak"
chmod +x "${PIN_HOME_T24}/.opt/bin/claude"
target="$(make_request "sess-24" "${TEST_HOME}" "Pin test." "/ulw via pin")"
OMC_CLAUDE_BIN="${PIN_HOME_T24}/.opt/bin/claude" bash "${WATCHDOG}" >/dev/null 2>&1
tmux_calls="$(mock_calls tmux)"
assert_contains "T24: tmux invokes pinned absolute path" "${PIN_HOME_T24}/.opt/bin/claude --resume sess-24" "${tmux_calls}"
assert_eq "T24: artifact claimed" "watchdog-launched" "$(read_field "${target}" last_attempt_outcome)"
rm -rf "${PIN_HOME_T24}"
teardown_test

# T25: pin missing-executable falls back to live command -v
print_test_header "T25: claude_bin pin missing-executable falls back to live PATH"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-25" "${TEST_HOME}" "Stale pin test." "/ulw via fallback")"
# Pin path doesn't exist on disk → resolver logs anomaly and falls back.
OMC_CLAUDE_BIN="${TEST_HOME}/.opt/no-such-claude" bash "${WATCHDOG}" >/dev/null 2>&1
tmux_calls="$(mock_calls tmux)"
# Falls back to live command -v which resolves to MOCK_BIN/claude.
assert_contains "T25: tmux invokes live PATH claude on stale pin" "${MOCK_BIN}/claude --resume sess-25" "${tmux_calls}"
assert_eq "T25: artifact still claimed via fallback" "watchdog-launched" "$(read_field "${target}" last_attempt_outcome)"
teardown_test

# T26: pin exists but --version fails → fallback (does NOT overwrite pin)
print_test_header "T26: claude_bin pin --version failure falls back without overwriting"
setup_test
install_tmux_mock
install_mock claude 0
mkdir -p "${TEST_HOME}/.opt/bin"
cat > "${TEST_HOME}/.opt/bin/claude" <<'BROKEN'
#!/usr/bin/env bash
exit 99
BROKEN
chmod +x "${TEST_HOME}/.opt/bin/claude"
target="$(make_request "sess-26" "${TEST_HOME}" "Broken pin." "/ulw via fallback-v")"
# Pin exists + executable + --version returns non-zero → fallback path.
OMC_CLAUDE_BIN="${TEST_HOME}/.opt/bin/claude" bash "${WATCHDOG}" >/dev/null 2>&1
tmux_calls="$(mock_calls tmux)"
assert_contains "T26: tmux invokes live claude on --version failure" "${MOCK_BIN}/claude --resume sess-26" "${tmux_calls}"
# Verify the pin is NOT overwritten — caller-set OMC_CLAUDE_BIN is preserved
# by design (we don't auto-mutate state on transient failure). No assertion
# needed beyond the launch routing because the env var is process-local.
teardown_test

# T27: empty pin (default) preserves legacy command -v behavior
print_test_header "T27: empty claude_bin uses live command -v (legacy)"
setup_test
install_tmux_mock
install_mock claude 0
target="$(make_request "sess-27" "${TEST_HOME}" "Default pin." "/ulw via live")"
unset OMC_CLAUDE_BIN
bash "${WATCHDOG}" >/dev/null 2>&1
tmux_calls="$(mock_calls tmux)"
# Live command -v from PATH = MOCK_BIN/claude (resolved absolute path).
assert_contains "T27: tmux invokes live PATH claude" "${MOCK_BIN}/claude --resume sess-27" "${tmux_calls}"
assert_eq "T27: artifact claimed via legacy resolution" "watchdog-launched" "$(read_field "${target}" last_attempt_outcome)"
teardown_test

# ---------------------------------------------------------------------------
# T28-T30: Tombstone TOCTOU defense (4-attacker security review, A1-MED-4)
# ---------------------------------------------------------------------------
#
# A1 (unprivileged shell) can pre-create
#   `${HOME}/.cache/omc-watchdog.last-error`
# as a symlink to ANY user-readable file. The pre-Wave-2 implementation
# used a `>` redirect, which follows symlinks — overwriting attacker-
# chosen targets (~/.bash_history, ~/.gnupg/gpg.conf, etc.) with the
# tombstone JSON.
#
# Fix anatomy (resume-watchdog.sh:90-104):
#   1. New tombstone path under a 700-mode subdir
#      (${HOME}/.cache/omc/) the harness controls.
#   2. Refuse to write if the parent OR target dir is a symlink
#      (defense-in-depth against parent-dir symlink attack).
#   3. mktemp + mv -f for the atomic write — replaces any pre-existing
#      file/symlink at the target without follow.
#
# These tests verify the *security primitives* in isolation (re-run the
# logic in a subshell). End-to-end triggering through the full watchdog
# is awkward because `ensure_session_dir` masks its mkdir failure with
# `chmod ... || true`, making the tombstone branch hard to fire from a
# sandbox. Testing the primitives directly is a more honest assertion
# of "this fix prevents the symlink attack" than relying on a brittle
# integration trigger.

_run_tombstone_logic() {
  # Mirrors resume-watchdog.sh:90-104 inline. Stays in lockstep with
  # the production code path; if that code changes, this helper must
  # be updated alongside it.
  local _wd_dir="${HOME}/.cache/omc"
  local _wd_path="${_wd_dir}/watchdog-last-error"
  if [[ ! -L "${HOME}/.cache" && ! -L "${_wd_dir}" ]]; then
    mkdir -p "${_wd_dir}" 2>/dev/null || true
    chmod 700 "${_wd_dir}" 2>/dev/null || true
    local _tmp
    _tmp="$(mktemp "${_wd_dir}/.last-error.XXXXXX" 2>/dev/null || true)"
    if [[ -n "${_tmp}" ]]; then
      printf '{"ts":1,"reason":"test","state_root":"/x"}\n' > "${_tmp}" 2>/dev/null || true
      mv -f "${_tmp}" "${_wd_path}" 2>/dev/null || rm -f "${_tmp}"
    fi
  fi
}

# T28: Pre-existing symlink at the tombstone path is replaced, not followed.
echo "=== T28: symlink at tombstone path replaced atomically ==="
setup_test
mkdir -p "${TEST_HOME}/.cache/omc"
target_file="${TEST_HOME}/sensitive-data.txt"
printf 'PRECIOUS USER DATA\n' > "${target_file}"
ln -sf "${target_file}" "${TEST_HOME}/.cache/omc/watchdog-last-error"

_run_tombstone_logic

assert_eq "T28: target file not overwritten" "PRECIOUS USER DATA" \
  "$(cat "${target_file}")"

if [[ -f "${TEST_HOME}/.cache/omc/watchdog-last-error" \
   && ! -L "${TEST_HOME}/.cache/omc/watchdog-last-error" ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL: T28 — tombstone path is missing or still a symlink\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# T29: Symlink at parent ${HOME}/.cache/omc/ is refused (write skipped,
# attacker-target receives nothing).
echo "=== T29: symlink at tombstone parent dir refuses write ==="
setup_test
mkdir -p "${TEST_HOME}/.cache"
mkdir -p "${TEST_HOME}/attacker-target"
ln -sf "${TEST_HOME}/attacker-target" "${TEST_HOME}/.cache/omc"

_run_tombstone_logic

attacker_files="$(find "${TEST_HOME}/attacker-target" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "T29: attacker-target has no files written through symlink" "0" "${attacker_files}"
teardown_test

# T30: Tombstone parent dir is 700-mode after the harness creates it.
echo "=== T30: tombstone parent dir is chmod 700 ==="
setup_test
_run_tombstone_logic

if [[ -d "${TEST_HOME}/.cache/omc" ]]; then
  parent_mode="$(stat -c '%a' "${TEST_HOME}/.cache/omc" 2>/dev/null \
    || stat -f '%Lp' "${TEST_HOME}/.cache/omc" 2>/dev/null \
    || printf 'unknown')"
  if [[ "${parent_mode}" == "700" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: T30 — tombstone parent dir mode is %s, expected 700\n' \
      "${parent_mode}" >&2
    fail=$((fail + 1))
  fi
else
  printf 'FAIL: T30 — tombstone parent dir was not created\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# T31: Symlink at ${HOME}/.cache itself is refused (defense-in-depth
# against parent-of-parent symlink attack).
echo "=== T31: symlink at ${HOME}/.cache refuses write ==="
setup_test
mkdir -p "${TEST_HOME}/attacker-cache"
ln -sf "${TEST_HOME}/attacker-cache" "${TEST_HOME}/.cache"

_run_tombstone_logic

attacker_cache_files="$(find "${TEST_HOME}/attacker-cache" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "T31: attacker-cache has no files written" "0" "${attacker_cache_files}"
teardown_test

# T32 (v1.34.1+ sre-lens S-004): the watchdog must write a heartbeat
# file at the TOP of each tick. /ulw-report and /ulw-status read this
# to surface "last successful tick: N min ago" — without it, absence
# of tick-complete events is indistinguishable from "no work to do"
# vs "daemon is hung". The heartbeat must fire EVEN ON IDLE TICKS
# (no claimable artifacts) so an idle daemon shows liveness signal.
# This test exercises the no-work early-exit path: no artifacts =
# tick exits early at line ~408 BUT heartbeat already wrote.
echo "=== T32: watchdog heartbeat fires at top of tick (idle case) ==="
setup_test
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/_watchdog"
# No artifacts — the tick will hit the no-list early exit. With the
# top-of-tick heartbeat write (S-004 follow-up fix), the heartbeat
# file should still appear.
HOME="${TEST_HOME}" bash "${WATCHDOG}" >/dev/null 2>&1 || true
heartbeat_file="${TEST_HOME}/.claude/quality-pack/state/_watchdog/last_tick_completed_ts"
if [[ -f "${heartbeat_file}" ]]; then
  hb_value="$(cat "${heartbeat_file}" 2>/dev/null | tr -d ' \n')"
  if [[ "${hb_value}" =~ ^[0-9]+$ ]]; then
    pass=$((pass + 1))
    now_ts=$(date +%s)
    drift=$(( now_ts - hb_value ))
    if (( drift >= 0 && drift < 300 )); then
      pass=$((pass + 1))
    else
      printf 'FAIL: T32 — heartbeat ts drift %ds (expected 0..299)\n' "${drift}" >&2
      fail=$((fail + 1))
    fi
  else
    printf 'FAIL: T32 — heartbeat content not numeric: %q\n' "${hb_value}" >&2
    fail=$((fail + 1))
  fi
else
  printf 'FAIL: T32 — heartbeat file missing at %s\n' "${heartbeat_file}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T33 (v1.34.1+ sre-lens S-002): _watchdog gate_events.jsonl must be
# capped per-tick, not only at sweep time. The cap fires AFTER the
# artifact loop completes, so we need an artifact that PASSES the
# find_claimable filter (resume_attempts=0, captured recently, no
# future resets_at) AND gets recorded as skipped in the per-artifact
# loop (so it adds an event row WITHOUT triggering tmux/claude
# launch). Use a missing-cwd artifact: cwd points to /nonexistent,
# the per-artifact loop records "skipped-missing-cwd" and continues
# — no launch path entered.
echo "=== T33: watchdog caps gate_events.jsonl per-tick ==="
setup_test
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/_watchdog"
# Seed 600 rows.
events_file="${TEST_HOME}/.claude/quality-pack/state/_watchdog/gate_events.jsonl"
for i in $(seq 1 600); do
  printf '{"ts":%s,"event":"test-row-%d"}\n' "$(date +%s)" "${i}"
done > "${events_file}"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/sid-cap"
cat > "${TEST_HOME}/.claude/quality-pack/state/sid-cap/resume_request.json" <<EOF
{"schema_version":1,"session_id":"sid-cap","cwd":"/nonexistent-dir-for-test","captured_at_ts":$(date +%s),"original_objective":"x","last_user_prompt":"x","resume_attempts":0,"resets_at_ts":0}
EOF
HOME="${TEST_HOME}" bash "${WATCHDOG}" >/dev/null 2>&1 || true
post_count="$(wc -l < "${events_file}" 2>/dev/null | tr -d ' ')"
post_count="${post_count:-0}"
# Cap is 500 default. After processing: skipped-missing-cwd event +
# tick-complete event added — but the cap should trim. Expect at most
# 502 rows (cap=500 + the tick-complete row + the trailing event added
# after the cap fires).
if [[ "${post_count}" =~ ^[0-9]+$ ]] && (( post_count > 0 )) && (( post_count <= 502 )); then
  pass=$((pass + 1))
else
  printf 'FAIL: T33 — _watchdog gate_events.jsonl not capped (post_count=%q)\n' "${post_count}" >&2
  fail=$((fail + 1))
fi
teardown_test

printf '\n=== test-resume-watchdog: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
