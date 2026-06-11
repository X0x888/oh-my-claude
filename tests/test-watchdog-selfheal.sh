#!/usr/bin/env bash
# test-watchdog-selfheal.sh — v1.47 SRE-lens regression net for the
# GUARDED self-heal in session-start-watchdog-health.sh.
#
# Pre-v1.47 the hook was warn-only: a stale watchdog printed a banner
# telling the user to hand-run install-resume-watchdog.sh. v1.47 makes
# the hook attempt ONE guarded re-registration per session when it is
# SAFE, falling back to the warning otherwise. "Safe" hinges on the
# orphan-prevention guard:
#
#   Re-registering fires a launchd RunAtLoad / systemd Persistent
#   catch-up tick, and a tick CLAIMS any claimable resume_request.json
#   and launches `claude --resume` in tmux. Re-registering while a
#   claimable artifact exists spawns an ORPHAN agent mid-session that
#   burns rate-limit budget and may commit unexpected work
#   (project_watchdog_reregister_claims_artifacts.md). So the hook
#   checks find_claimable_resume_requests FIRST and does NOT invoke the
#   installer at all when an artifact exists.
#
# This file proves:
#   (a) stale + enabled + NO claimable artifact  -> self-heal taken
#       (installer --reregister invoked; platform scheduler touched;
#        green "self-healed" notice; watchdog_selfheal_attempted_ts set).
#   (b) stale + enabled + claimable artifact EXISTS -> self-heal NOT
#       taken (warn + handle-first note; THE ORPHAN-PREVENTION PROOF:
#        no platform-scheduler call runs at all).
#   (c) resume_watchdog disabled -> hook silent (no self-heal, no warn).
#   (d) once-per-session: second SessionStart does not re-attempt.
#   (e) once-per-session ACTION guard in isolation: with
#       watchdog_selfheal_attempted_ts already set (but the message flag
#       cleared), the hook warns "already attempted" and makes NO new
#       platform call.
#
# Platform is pinned to Linux+systemd in the sandbox (mock uname +
# systemctl) so the recover path is deterministic across CI hosts. The
# REAL installer's --reregister mode runs; only the platform binaries
# (systemctl/launchctl/crontab/tmux/claude) and uname are mocked, so the
# orphan-prevention guard (reregister_is_safe) executes for real too.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-watchdog-health.sh"
INSTALLER_SRC="${REPO_ROOT}/bundle/dot-claude/install-resume-watchdog.sh"

ORIG_PATH="${PATH}"
pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:280}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unwanted=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:280}" >&2
    fail=$((fail + 1))
  fi
}

TEST_ROOT=""
MOCK_BIN=""

cleanup() {
  export PATH="${ORIG_PATH}"
  [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]] && rm -rf "${TEST_ROOT}" 2>/dev/null || true
}
trap cleanup EXIT

# Resolve real binaries alongside our mocks so a strict (MOCK_BIN-first)
# PATH still finds bash/jq/sed/etc. for the installer + common.sh.
install_path_deps() {
  local dep src
  for dep in bash jq sed date mkdir cat grep awk find rm mv touch chmod \
             head tail tr cut sort dirname basename printf readlink \
             xargs tee cp mktemp rmdir realpath flock stat ls id wc tac \
             ln env sleep kill sha256sum shasum paste timeout; do
    [[ -e "${MOCK_BIN}/${dep}" ]] && continue
    src="$(PATH="${ORIG_PATH}" command -v "${dep}" 2>/dev/null || true)"
    if [[ -n "${src}" && -x "${src}" ]]; then
      ln -sf "${src}" "${MOCK_BIN}/${dep}"
    fi
  done
}

# Build a fresh sandboxed HOME. Each call resets state so tests are
# independent. Platform defaults to Linux+systemd (overridable per test).
setup_env() {
  TEST_ROOT="$(mktemp -d)"
  export HOME="${TEST_ROOT}/home"
  export STATE_ROOT="${TEST_ROOT}/state"
  mkdir -p "${HOME}/.claude/skills" \
           "${HOME}/.claude/quality-pack/scripts" \
           "${HOME}/.claude/launchd" \
           "${HOME}/.claude/systemd" \
           "${HOME}/Library/LaunchAgents" \
           "${HOME}/.config/systemd/user" \
           "${STATE_ROOT}"

  # Source path for common.sh + libs + claim helper.
  ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" \
    "${HOME}/.claude/skills/autowork"
  # The installer the hook shells out to (real script).
  ln -s "${INSTALLER_SRC}" "${HOME}/.claude/install-resume-watchdog.sh"
  # The watchdog script (installer require_file's it; reregister mode
  # also require_file's the plist).
  ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/resume-watchdog.sh" \
    "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
  # Platform templates so macos_/linux_ reregister find their sources.
  ln -s "${REPO_ROOT}/bundle/dot-claude/launchd/dev.ohmyclaude.resume-watchdog.plist" \
    "${HOME}/.claude/launchd/dev.ohmyclaude.resume-watchdog.plist"
  ln -s "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" \
    "${HOME}/.claude/systemd/oh-my-claude-resume-watchdog.service"
  ln -s "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.timer" \
    "${HOME}/.claude/systemd/oh-my-claude-resume-watchdog.timer"

  # Pre-render the systemd units into the user dir so linux_reregister
  # takes the systemd restart path (not the cron fallback) — simulates
  # an already-installed-but-stale watchdog.
  printf '[Unit]\nDescription=stub\n[Service]\nType=oneshot\n' \
    > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
  printf '[Unit]\nDescription=stub\n[Timer]\nOnUnitActiveSec=120s\n' \
    > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"

  MOCK_BIN="${TEST_ROOT}/mockbin"
  mkdir -p "${MOCK_BIN}"
  export PATH="${MOCK_BIN}:${ORIG_PATH}"
  install_path_deps

  # Pin platform to Linux by default.
  cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK

  # Record every platform-scheduler call so tests can assert
  # invoked / not-invoked. These files are the smoking guns.
  cat > "${MOCK_BIN}/systemctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/systemctl.calls"
exit 0
MOCK
  cat > "${MOCK_BIN}/launchctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/launchctl.calls"
exit 0
MOCK
  cat > "${MOCK_BIN}/crontab" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/crontab.calls"
case "\${1:-}" in
  -l|"") exit 1 ;;
  -) cat >/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  # tmux / claude must NEVER be called by the self-heal path (they only
  # run inside a real watchdog tick, which the mocked schedulers don't
  # spawn). Record any call as a hard failure signal.
  cat > "${MOCK_BIN}/tmux" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/tmux.calls"
case "\$1" in has-session) exit 1 ;; *) exit 0 ;; esac
MOCK
  cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/claude.calls"
exit 0
MOCK
  chmod +x "${MOCK_BIN}/uname" "${MOCK_BIN}/systemctl" "${MOCK_BIN}/launchctl" \
           "${MOCK_BIN}/crontab" "${MOCK_BIN}/tmux" "${MOCK_BIN}/claude"

  # Run from sandbox so load_conf's PWD walk can't find the repo conf.
  cd "${TEST_ROOT}"
  export OMC_RESUME_WATCHDOG=on
  unset OMC_WATCHDOG_HEALTH_STALENESS_SECS 2>/dev/null || true
}

teardown_env() {
  export PATH="${ORIG_PATH}"
  if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
    rm -rf "${TEST_ROOT}" 2>/dev/null || true
  fi
  TEST_ROOT=""
}

# Force a stale heartbeat (default 1200s ago — well past the 360s
# threshold). Pass an arg for a custom age.
make_stale_heartbeat() {
  local age="${1:-1200}"
  mkdir -p "${STATE_ROOT}/_watchdog"
  printf '%s\n' "$(( $(date +%s) - age ))" > "${STATE_ROOT}/_watchdog/last_tick_completed_ts"
}

# Seed a CLAIMABLE resume_request.json (rate cap already cleared,
# captured recently, attempts 0, not resumed/dismissed). Mirrors the
# shape find_claimable_resume_requests accepts.
make_claimable_artifact() {
  local sid="$1"
  local now_ts sdir
  now_ts="$(date +%s)"
  sdir="${STATE_ROOT}/${sid}"
  mkdir -p "${sdir}"
  jq -nc \
    --arg sid "${sid}" --arg cwd "${HOME}" \
    --argjson rs "$((now_ts - 60))" --argjson cap "$((now_ts - 300))" \
    '{schema_version:1, rate_limited:true, matcher:"rate_limit",
      hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
      project_key:null, transcript_path:"",
      original_objective:"selfheal-test objective",
      last_user_prompt:"/ulw selfheal-test",
      resets_at_ts:$rs, captured_at_ts:$cap,
      model_id:"claude-opus-4-8",
      resume_attempts:0, resumed_at_ts:null, dismissed_at_ts:null,
      rate_limit_snapshot:null}' \
    > "${sdir}/resume_request.json"
}

count_calls() {
  local f="$1"
  if [[ -f "${f}" ]]; then wc -l < "${f}" | tr -d ' \t'; else echo 0; fi
}

run_hook() {
  local sid="$1"
  printf '{"session_id":"%s","source":"startup"}' "${sid}" | bash "${HOOK}" 2>/dev/null || true
}

state_get() {
  local sid="$1" key="$2"
  jq -r ".${key} // \"\"" "${STATE_ROOT}/${sid}/session_state.json" 2>/dev/null || true
}

# =====================================================================
# (a) SAFE: stale + enabled + no claimable artifact -> self-heal taken
# =====================================================================
echo "=== (a) safe stale -> self-heal re-registers ==="
setup_env
make_stale_heartbeat
out="$(run_hook "sh-safe")"

sysctl_calls="$(count_calls "${MOCK_BIN}/systemctl.calls")"
assert_contains "(a) green self-healed notice" "self-healed" "${out}"
assert_contains "(a) restored-message present" "auto-resume is restored" "${out}"
assert_not_contains "(a) does NOT show warn-only banner" "appears inactive" "${out}"
# Proof the installer's reregister path ran: it issued the systemd
# enable --now timer call.
if [[ "${sysctl_calls}" -ge 1 ]] \
   && grep -q 'enable --now oh-my-claude-resume-watchdog.timer' "${MOCK_BIN}/systemctl.calls"; then
  pass=$((pass + 1))
else
  printf '  FAIL: (a) installer --reregister did not call systemctl enable --now timer (calls=%s)\n' \
    "${sysctl_calls}" >&2
  fail=$((fail + 1))
fi
# NO explicit claiming kickstart, and NO watchdog tick spawned anything.
assert_eq "(a) no tmux launch (no orphan)" "0" "$(count_calls "${MOCK_BIN}/tmux.calls")"
assert_eq "(a) no claude --resume (no orphan)" "0" "$(count_calls "${MOCK_BIN}/claude.calls")"
# Action guard stamped.
assert_eq "(a) watchdog_selfheal_attempted_ts stamped" "true" \
  "$([[ -n "$(state_get sh-safe watchdog_selfheal_attempted_ts)" ]] && echo true || echo false)"
assert_eq "(a) watchdog_health_emitted stamped" "1" "$(state_get sh-safe watchdog_health_emitted)"
teardown_env

# =====================================================================
# (b) ORPHAN-PREVENTION: stale + enabled + claimable artifact EXISTS
#     -> self-heal NOT taken; warn + handle-first; NO platform call.
# =====================================================================
echo "=== (b) claimable artifact blocks self-heal (orphan prevention) ==="
setup_env
make_stale_heartbeat
make_claimable_artifact "victim-sess"
out="$(run_hook "sh-blocked")"

assert_contains "(b) warn banner shown" "appears inactive" "${out}"
assert_contains "(b) handle-first note references /ulw-resume" "/ulw-resume" "${out}"
assert_contains "(b) explains why not auto-re-registered" "NOT auto-re-registered" "${out}"
assert_not_contains "(b) does NOT claim self-healed" "self-healed" "${out}"
# THE ORPHAN-PREVENTION PROOF: the installer/reregister path never ran,
# so NO platform-scheduler call happened (no RunAtLoad/Persistent tick,
# nothing to claim the victim artifact).
assert_eq "(b) ORPHAN PROOF: no systemctl call" "0" "$(count_calls "${MOCK_BIN}/systemctl.calls")"
assert_eq "(b) ORPHAN PROOF: no launchctl call" "0" "$(count_calls "${MOCK_BIN}/launchctl.calls")"
assert_eq "(b) ORPHAN PROOF: no tmux launch" "0" "$(count_calls "${MOCK_BIN}/tmux.calls")"
assert_eq "(b) ORPHAN PROOF: no claude --resume" "0" "$(count_calls "${MOCK_BIN}/claude.calls")"
# The victim artifact is untouched (not claimed).
victim_attempts="$(jq -r '.resume_attempts // 0' "${STATE_ROOT}/victim-sess/resume_request.json")"
victim_resumed="$(jq -r '.resumed_at_ts // ""' "${STATE_ROOT}/victim-sess/resume_request.json")"
assert_eq "(b) victim artifact NOT claimed (attempts==0)" "0" "${victim_attempts}"
assert_eq "(b) victim artifact NOT claimed (resumed_at_ts null)" "" "${victim_resumed}"
# The action guard MUST NOT be stamped — re-register was never attempted,
# so a later session (after the user clears the artifact) can still try.
assert_eq "(b) selfheal action guard NOT stamped (no attempt was made)" "" \
  "$(state_get sh-blocked watchdog_selfheal_attempted_ts)"
teardown_env

# =====================================================================
# (c) disabled: resume_watchdog off -> hook silent
# =====================================================================
echo "=== (c) disabled watchdog -> silent ==="
setup_env
make_stale_heartbeat
make_claimable_artifact "ignored-sess"
export OMC_RESUME_WATCHDOG=off
out="$(run_hook "sh-disabled")"
assert_eq "(c) disabled -> empty output" "" "${out}"
assert_eq "(c) disabled -> no systemctl call" "0" "$(count_calls "${MOCK_BIN}/systemctl.calls")"
assert_eq "(c) disabled -> no launchctl call" "0" "$(count_calls "${MOCK_BIN}/launchctl.calls")"
export OMC_RESUME_WATCHDOG=on
teardown_env

# =====================================================================
# (d) once-per-session: a second SessionStart does not re-attempt.
# =====================================================================
echo "=== (d) once-per-session: second fire does not re-attempt ==="
setup_env
make_stale_heartbeat
first="$(run_hook "sh-once")"
calls_after_first="$(count_calls "${MOCK_BIN}/systemctl.calls")"
second="$(run_hook "sh-once")"
calls_after_second="$(count_calls "${MOCK_BIN}/systemctl.calls")"
assert_contains "(d) first fire self-heals" "self-healed" "${first}"
assert_eq "(d) first fire made exactly one reregister round" "1" \
  "$(grep -c 'enable --now oh-my-claude-resume-watchdog.timer' "${MOCK_BIN}/systemctl.calls" 2>/dev/null || echo 0)"
assert_eq "(d) second fire (same session) is silent" "" "${second}"
assert_eq "(d) second fire made NO additional platform call" \
  "${calls_after_first}" "${calls_after_second}"
teardown_env

# =====================================================================
# (e) action-guard isolation: watchdog_selfheal_attempted_ts already set
#     (message flag cleared) -> "already attempted" warning, no new call.
#     This isolates the ACTION guard from the message idempotency flag.
# =====================================================================
echo "=== (e) action guard alone -> attempted-earlier warning, no re-attempt ==="
setup_env
make_stale_heartbeat
# First fire self-heals and sets BOTH flags + 1 platform call.
run_hook "sh-action" >/dev/null
calls_after_first="$(count_calls "${MOCK_BIN}/systemctl.calls")"
# Clear ONLY the message flag, keep the action flag set, to force the
# code down the attempted-earlier branch on the next fire.
state_file="${STATE_ROOT}/sh-action/session_state.json"
tmp="${state_file}.tmp"
jq 'del(.watchdog_health_emitted)' "${state_file}" > "${tmp}" && mv "${tmp}" "${state_file}"
out="$(run_hook "sh-action")"
calls_after_second="$(count_calls "${MOCK_BIN}/systemctl.calls")"
assert_contains "(e) attempted-earlier warning shown" "already attempted this session" "${out}"
assert_contains "(e) attempted-earlier still surfaces manual recovery" "install-resume-watchdog.sh" "${out}"
assert_eq "(e) action guard prevented a second platform call" \
  "${calls_after_first}" "${calls_after_second}"
teardown_env

printf '\nwatchdog-selfheal tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
