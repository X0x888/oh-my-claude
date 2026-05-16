#!/usr/bin/env bash
#
# Tests for bundle/dot-claude/install-resume-watchdog.sh — the opt-in
# installer for the headless resume daemon. Locks the v1.41.x post-
# install audit fix: the installer used to invoke the watchdog as a
# "dry-run" but the watchdog actually executed its full claim/launch
# loop, silently consuming any claimable `resume_request.json` on disk
# and spawning detached `claude --resume <objective>` tmux sessions
# (observed: 4 artifacts spent across 4 install runs in production).
# The fix sets OMC_WATCHDOG_SELF_TEST=1 when calling the watchdog so
# the main loop short-circuits before claim.
#
# These tests run install-resume-watchdog.sh under an isolated HOME
# with mocked launchctl / systemctl / tmux / claude binaries and a
# pre-seeded claimable artifact. The installer must complete without
# claiming the artifact or invoking tmux new-session.
#
# Regression seed: revert the `OMC_WATCHDOG_SELF_TEST=1 ` prefix on
# install-resume-watchdog.sh line 281 and watch T1 fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${REPO_ROOT}/bundle/dot-claude/install-resume-watchdog.sh"

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
ORIG_PATH="${PATH}"
pass=0
fail=0
TEST_HOME=""
MOCK_BIN=""

# Resolve real binaries we need available alongside our mocks so a
# strict-PATH (MOCK_BIN-only) environment doesn't break the installer's
# subprocess calls to bash, jq, sed, mkdir, etc.
install_path_deps() {
  local dep src
  for dep in bash jq sed date mkdir cat grep awk find rm mv touch chmod \
             head tail tr cut sort dirname basename printf readlink \
             xargs uname tee cp mktemp rmdir realpath flock stat ls \
             id wc tac ln chown chgrp env sleep kill sha256sum shasum \
             paste timeout; do
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
  mkdir -p "${TEST_HOME}/.claude/launchd"
  mkdir -p "${TEST_HOME}/.claude/systemd"
  mkdir -p "${TEST_HOME}/Library/LaunchAgents"
  mkdir -p "${TEST_HOME}/.config/systemd/user"

  # Symlink bundle files the installer + watchdog need.
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
  ln -sf "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/resume-watchdog.sh" \
    "${TEST_HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"

  # Platform scheduler templates — symlink whichever exist so installer's
  # platform branch finds its source file regardless of uname.
  if [[ -f "${REPO_ROOT}/bundle/dot-claude/launchd/dev.ohmyclaude.resume-watchdog.plist" ]]; then
    ln -sf "${REPO_ROOT}/bundle/dot-claude/launchd/dev.ohmyclaude.resume-watchdog.plist" \
      "${TEST_HOME}/.claude/launchd/dev.ohmyclaude.resume-watchdog.plist"
  fi
  if [[ -f "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" ]]; then
    ln -sf "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" \
      "${TEST_HOME}/.claude/systemd/oh-my-claude-resume-watchdog.service"
    ln -sf "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.timer" \
      "${TEST_HOME}/.claude/systemd/oh-my-claude-resume-watchdog.timer"
  fi

  MOCK_BIN="${TEST_HOME}/.mockbin"
  mkdir -p "${MOCK_BIN}"
  export PATH="${MOCK_BIN}:${ORIG_PATH}"
  install_path_deps

  # Mock launchctl (macOS) - all subcommands succeed.
  cat > "${MOCK_BIN}/launchctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/launchctl.calls"
exit 0
MOCK

  # Mock systemctl (Linux) - all subcommands succeed.
  cat > "${MOCK_BIN}/systemctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/systemctl.calls"
exit 0
MOCK

  # Mock tmux — new-session is the smoking gun for the bug we test.
  cat > "${MOCK_BIN}/tmux" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/tmux.calls"
case "\$1" in
  has-session) exit 1 ;;
  *) exit 0 ;;
esac
MOCK

  # Mock claude — the binary the watchdog would invoke under --resume.
  cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/claude.calls"
exit 0
MOCK

  chmod +x "${MOCK_BIN}"/launchctl "${MOCK_BIN}"/systemctl "${MOCK_BIN}"/tmux "${MOCK_BIN}"/claude

  cd "${TEST_HOME}"
  # Opt the watchdog on (the installer also sets this, but make sure the
  # script-level guard would not silently exit if conf reading flakes).
  export OMC_RESUME_WATCHDOG=on
  unset SESSION_ID 2>/dev/null || true
}

teardown_test() {
  cd "${ORIG_PWD}" 2>/dev/null || true
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  unset OMC_RESUME_WATCHDOG 2>/dev/null || true
  if [[ -n "${TEST_HOME}" && -d "${TEST_HOME}" ]]; then
    rm -rf "${TEST_HOME}" 2>/dev/null || true
  fi
  TEST_HOME=""
}

trap 'teardown_test' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=[%s]\n    actual=[%s]\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1" cond="$2"
  if eval "${cond}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — condition [%s] was false\n' "${label}" "${cond}" >&2
    fail=$((fail + 1))
  fi
}

make_artifact() {
  local sid="$1"
  local now_ts
  now_ts="$(date +%s)"
  local sdir="${HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${sdir}"
  jq -nc \
    --arg sid "${sid}" --arg cwd "${HOME}" \
    --argjson rs "$((now_ts - 60))" --argjson cap "$((now_ts - 300))" \
    '{schema_version:1, rate_limited:true, matcher:"rate_limit",
      hook_event_name:"StopFailure", session_id:$sid, cwd:$cwd,
      project_key:null, transcript_path:"",
      original_objective:"installer-test objective",
      last_user_prompt:"/ulw installer-test",
      resets_at_ts:$rs, captured_at_ts:$cap,
      model_id:"claude-opus-4-7",
      resume_attempts:0, resumed_at_ts:null, rate_limit_snapshot:null}' \
    > "${sdir}/resume_request.json"
}

# ---------------------------------------------------------------------------
# T1: install with a claimable artifact MUST NOT claim or launch it
# The smoking-gun regression test. Without OMC_WATCHDOG_SELF_TEST=1 set
# by the installer, the watchdog's full claim path would mutate the
# artifact (resume_attempts: 0 → 1, resumed_at_ts stamped) and invoke
# `tmux new-session -d -s omc-resume-test-sess-install -- claude --resume ...`.
# ---------------------------------------------------------------------------
echo "=== T1: install with claimable artifact does not consume it ==="
setup_test
make_artifact "test-sess-install"
artifact_path="${HOME}/.claude/quality-pack/state/test-sess-install/resume_request.json"
attempts_before="$(jq -r '.resume_attempts // 0' "${artifact_path}")"

bash "${INSTALLER}" >/dev/null 2>&1 || true

attempts_after="$(jq -r '.resume_attempts // 0' "${artifact_path}")"
tmux_launches=0
if [[ -f "${MOCK_BIN}/tmux.calls" ]]; then
  tmux_launches="$(grep -c new-session "${MOCK_BIN}/tmux.calls" 2>/dev/null || echo 0)"
fi
claude_calls=0
if [[ -f "${MOCK_BIN}/claude.calls" ]]; then
  claude_calls="$(wc -l < "${MOCK_BIN}/claude.calls" 2>/dev/null | tr -d ' \t' || echo 0)"
fi
resumed_at="$(jq -r '.resumed_at_ts // ""' "${artifact_path}" 2>/dev/null | tr -d 'null')"

assert_eq "T1: artifact NOT claimed (resume_attempts unchanged at ${attempts_before})" "${attempts_before}" "${attempts_after}"
assert_eq "T1: no tmux new-session call" "0" "${tmux_launches}"
assert_eq "T1: no claude --resume invocation" "0" "${claude_calls}"
assert_eq "T1: resumed_at_ts not stamped" "" "${resumed_at}"
teardown_test

# ---------------------------------------------------------------------------
# T2: code-shape backstop — installer MUST set OMC_WATCHDOG_SELF_TEST=1
# when invoking the watchdog. A future "clean up env-var prefix" PR that
# strips this prefix would re-introduce the v1.41.x bug; this assertion
# locks the surface even if T1's mock infrastructure ever drifts.
# ---------------------------------------------------------------------------
echo "=== T2: installer code shape sets OMC_WATCHDOG_SELF_TEST=1 ==="
if grep -E 'OMC_WATCHDOG_SELF_TEST=1 bash "\$\{WATCHDOG_SCRIPT\}"' "${INSTALLER}" >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2: installer must invoke watchdog with OMC_WATCHDOG_SELF_TEST=1 prefix (regression of v1.41.x post-install audit)\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# T3: install with NO claimable artifact still completes cleanly
# Sanity check that the self-test path doesn't introduce a false-negative
# on the common case (no artifacts on disk = nothing to consume anyway).
# ---------------------------------------------------------------------------
echo "=== T3: install with no claimable artifact succeeds ==="
setup_test
out="$(bash "${INSTALLER}" 2>&1 || true)"
# Use case statement instead of assert_true+eval — the installer output
# contains shell metacharacters that mangle eval-based string matching.
if [[ "${out}" == *"self-test: OK"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: install output missing "self-test: OK" marker\n' >&2
  fail=$((fail + 1))
fi
if grep -q '^resume_watchdog=on' "${HOME}/.claude/oh-my-claude.conf"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: install did not set resume_watchdog=on in conf\n' >&2
  fail=$((fail + 1))
fi
teardown_test

printf '\n=== test-install-resume-watchdog: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
