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
NIX_SYNC_BIN=""
NIX_SYNC_TARGET=""
NIX_SYNC_INSTALLER=""

# Resolve real binaries we need available alongside our mocks so a
# strict-PATH (MOCK_BIN-only) environment doesn't break the installer's
# subprocess calls to bash, jq, sed, mkdir, etc.
install_path_deps() {
  local dep src
  for dep in bash jq sed date mkdir cat grep awk find rm mv touch chmod \
             head tail tr cut sort dirname basename printf readlink \
             xargs uname tee cp mktemp rmdir realpath flock stat ls \
             id wc tac ln chown chgrp env sleep kill sha256sum shasum \
             paste timeout cmp; do
    [[ -e "${MOCK_BIN}/${dep}" ]] && continue
    src="$(PATH="${ORIG_PATH}" command -v "${dep}" 2>/dev/null || true)"
    if [[ -n "${src}" && -x "${src}" ]]; then
      ln -sf "${src}" "${MOCK_BIN}/${dep}"
    fi
  done
}

setup_test() {
  if [[ "${1:-}" == "spaced-percent-home" ]]; then
    TEST_HOME="$(mktemp -d \
      "${TMPDIR:-/tmp}/omc watchdog percent-%.XXXXXX")"
  else
    TEST_HOME="$(mktemp -d)"
  fi
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
  for lib in state-io.sh classifier.sh verification.sh timing.sh; do
    if [[ -f "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" ]]; then
      ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" \
        "${TEST_HOME}/.claude/skills/autowork/scripts/lib/${lib}"
    fi
  done
  cp "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/resume-watchdog.sh" \
    "${TEST_HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"

  # Platform scheduler templates are copied as real files because production
  # source authority deliberately rejects symlink templates.
  if [[ -f "${REPO_ROOT}/bundle/dot-claude/launchd/dev.ohmyclaude.resume-watchdog.plist" ]]; then
    cp "${REPO_ROOT}/bundle/dot-claude/launchd/dev.ohmyclaude.resume-watchdog.plist" \
      "${TEST_HOME}/.claude/launchd/dev.ohmyclaude.resume-watchdog.plist"
  fi
  if [[ -f "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" ]]; then
    cp "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" \
      "${TEST_HOME}/.claude/systemd/oh-my-claude-resume-watchdog.service"
    cp "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.timer" \
      "${TEST_HOME}/.claude/systemd/oh-my-claude-resume-watchdog.timer"
  fi

  MOCK_BIN="${TEST_HOME}/.mockbin"
  mkdir -p "${MOCK_BIN}"
  export PATH="${MOCK_BIN}:${ORIG_PATH}"
  install_path_deps

  # Stateful scheduler mocks: status probes must reflect bootstrap/enable and
  # bootout/disable, otherwise cleanup verification would be a false success.
  cat > "${MOCK_BIN}/launchctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/launchctl.calls"
state="${MOCK_BIN}/launchctl.loaded"
case "\${1:-}" in
  print) [[ -f "\${state}" ]] ;;
  bootstrap) : > "\${state}" ;;
  bootout) rm -f "\${state}" ;;
  kickstart) exit 0 ;;
  *) exit 0 ;;
esac
MOCK

  cat > "${MOCK_BIN}/systemctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/systemctl.calls"
enabled="${MOCK_BIN}/systemctl.enabled"
active="${MOCK_BIN}/systemctl.active"
case "\$*" in
  *' is-enabled '*)
    if [[ -f "\${enabled}" ]]; then printf 'enabled\\n'; exit 0; fi
    printf 'disabled\\n'; exit 1 ;;
  *' is-active '*)
    if [[ -f "\${active}" ]]; then printf 'active\\n'; exit 0; fi
    printf 'inactive\\n'; exit 3 ;;
  *' enable --now '*) : > "\${enabled}"; : > "\${active}" ;;
  *' disable --now '*) rm -f "\${enabled}" "\${active}" ;;
  *' enable '*) : > "\${enabled}" ;;
  *' start '*) : > "\${active}" ;;
  *) exit 0 ;;
esac
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
  NIX_SYNC_BIN=""
  NIX_SYNC_TARGET=""
  NIX_SYNC_INSTALLER=""
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

assert_true() {
  local label="$1" cond="$2"
  if eval "${cond}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — condition [%s] was false\n' "${label}" "${cond}" >&2
    fail=$((fail + 1))
  fi
}

install_mock_crontab() {
  local store_path="${HOME}/mock.crontab"
  cat > "${MOCK_BIN}/crontab" <<MOCK
#!/usr/bin/env bash
store_path="${store_path}"
case "\${1:-}" in
  -l|"")
    if [[ -f "\${store_path}" ]]; then
      cat "\${store_path}"
      exit 0
    fi
    exit 1
    ;;
  -)
    cat > "\${store_path}"
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
MOCK
  chmod +x "${MOCK_BIN}/crontab"
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

test_sha256_text() {
  local value="${1:-}" output=""
  if PATH="${ORIG_PATH}" command -v shasum >/dev/null 2>&1; then
    output="$(printf '%s' "${value}" | PATH="${ORIG_PATH}" shasum -a 256)"
  else
    output="$(printf '%s' "${value}" | PATH="${ORIG_PATH}" sha256sum)"
  fi
  printf '%s' "${output%%[[:space:]]*}"
}

test_sha256_file() {
  local path="${1:-}" output=""
  if PATH="${ORIG_PATH}" command -v shasum >/dev/null 2>&1; then
    output="$(PATH="${ORIG_PATH}" shasum -a 256 -- "${path}")"
  else
    output="$(PATH="${ORIG_PATH}" sha256sum -- "${path}")"
  fi
  printf '%s' "${output%%[[:space:]]*}"
}

install_mock_recovery_authority() {
  local switcher="${HOME}/.claude/switch-tier.sh"
  local omc="${HOME}/.claude/skills/autowork/scripts/omc-config.sh"
  local hashes="${HOME}/.claude/quality-pack/state/installed-hashes.txt"
  rm -f -- "${switcher}" "${omc}"
  cat > "${switcher}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--recover-only" && $# -eq 1 ]]
mode="$(stat -c '%a' "$0" 2>/dev/null || stat -f '%Lp' "$0")"
[[ "${mode}" == "400" && -z "${BASH_ENV:-}" && -z "${ENV:-}" ]]
printf 'switch\n' >> "${HOME}/recovery-order.log"
if [[ -d "${HOME}/.claude/.switch-tier-transaction" \
    && ! -L "${HOME}/.claude/.switch-tier-transaction" ]]; then
  rmdir "${HOME}/.claude/.switch-tier-transaction"
fi
for candidate in "${HOME}/.claude"/.switch-tier-transaction.stage.* \
    "${HOME}/.claude"/.switch-tier-retired.*; do
  [[ -e "${candidate}" || -L "${candidate}" ]] || continue
  [[ -d "${candidate}" && ! -L "${candidate}" ]]
  rmdir "${candidate}"
done
MOCK
  cat > "${omc}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "recover-only" && $# -eq 1 ]]
mode="$(stat -c '%a' "$0" 2>/dev/null || stat -f '%Lp' "$0")"
[[ "${mode}" == "400" && -z "${BASH_ENV:-}" && -z "${ENV:-}" ]]
[[ ! -e "${HOME}/.claude/.switch-tier-transaction" \
    && ! -L "${HOME}/.claude/.switch-tier-transaction" ]]
printf 'omc\n' >> "${HOME}/recovery-order.log"
if [[ -d "${HOME}/.claude/.omc-config-transaction" \
    && ! -L "${HOME}/.claude/.omc-config-transaction" ]]; then
  rmdir "${HOME}/.claude/.omc-config-transaction"
fi
for candidate in "${HOME}/.claude"/.omc-config-transaction.stage.* \
    "${HOME}/.claude"/.omc-config-retired.*; do
  [[ -e "${candidate}" || -L "${candidate}" ]] || continue
  [[ -d "${candidate}" && ! -L "${candidate}" ]]
  rmdir "${candidate}"
done
MOCK
  chmod 700 "${switcher}" "${omc}"
  printf '%s  %s\n' "$(test_sha256_file "${switcher}")" \
    'switch-tier.sh' > "${hashes}"
  printf '%s  %s\n' "$(test_sha256_file "${omc}")" \
    'skills/autowork/scripts/omc-config.sh' >> "${hashes}"
  chmod 600 "${hashes}"
}

mock_platform() {
  local name="${1:-Linux}"
  cat > "${MOCK_BIN}/uname" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' '${name}'
MOCK
  chmod +x "${MOCK_BIN}/uname"
}

# Exercise the immutable-Nix resolver branch without requiring the test host
# itself to use Nix or granting the suite write access to /nix/store. The copy
# changes only the trusted-store root and removes the fixed FHS directories
# from this resolver's search prefix; all transaction logic remains byte-for-
# byte identical to the production installer. This is deliberately a test-
# artifact relocation, not a production environment override of trust roots.
prepare_relocated_nix_sync_installer() {
  local store_root="${HOME}/nix/store"
  local store_object="${store_root}/test-coreutils"
  [[ "${store_root}" != *['&|']* ]] || return 1
  NIX_SYNC_BIN="${store_object}/bin"
  NIX_SYNC_TARGET="${store_object}/libexec/sync-real"
  NIX_SYNC_INSTALLER="${HOME}/install-resume-watchdog-nix-test.sh"
  mkdir -p "${NIX_SYNC_BIN}" "${store_object}/libexec"
  cat > "${NIX_SYNC_TARGET}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$0" >> "${HOME}/nix-sync.calls"
MOCK
  chmod 555 "${NIX_SYNC_TARGET}"
  ln -s ../libexec/sync-real "${NIX_SYNC_BIN}/sync"
  sed \
    -e "s|/nix/store/|${store_root}/|g" \
    -e 's|local search_path="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"|local search_path="${PATH:-}"|' \
    "${INSTALLER}" > "${NIX_SYNC_INSTALLER}"
  chmod 700 "${NIX_SYNC_INSTALLER}"
  grep -Fq 'local search_path="${PATH:-}"' "${NIX_SYNC_INSTALLER}" \
    && ! grep -Fq '/nix/store/' "${NIX_SYNC_INSTALLER}"
}

write_head_rendered_systemd_units() {
  local service="" timer="" render_path="${1:-${MOCK_BIN}}"
  local claude_home="${HOME}/.claude"
  local current_exec='ExecStart=/bin/bash "__OMC_HOME__/quality-pack/scripts/resume-watchdog.sh"'
  local historical_exec='ExecStart=/bin/bash __OMC_HOME__/quality-pack/scripts/resume-watchdog.sh'
  service="$(<"${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service")"
  timer="$(<"${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.timer")"
  service="${service//${current_exec}/${historical_exec}}"
  service="${service//__OMC_HOME__/${claude_home}}"
  service="${service//__OMC_USER_HOME__/${HOME}}"
  service="${service//__OMC_PATH__/${render_path}}"
  timer="${timer//__OMC_HOME__/${claude_home}}"
  timer="${timer//__OMC_USER_HOME__/${HOME}}"
  timer="${timer//__OMC_PATH__/${render_path}}"
  printf '%s\n' "${service}" \
    > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
  printf '%s\n' "${timer}" \
    > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
  chmod 644 \
    "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" \
    "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
}

write_head_rendered_launchd_plist() {
  local plist="" render_path="${1:-${MOCK_BIN}}"
  local claude_home="${HOME}/.claude"
  local log_dir="${HOME}/.claude/quality-pack/state/.watchdog-logs"
  plist="$(<"${REPO_ROOT}/bundle/dot-claude/launchd/dev.ohmyclaude.resume-watchdog.plist")"
  plist="${plist//__OMC_HOME__/${claude_home}}"
  plist="${plist//__OMC_USER_HOME__/${HOME}}"
  plist="${plist//__OMC_LOG_DIR__/${log_dir}}"
  plist="${plist//__OMC_PATH__/${render_path}}"
  printf '%s\n' "${plist}" \
    > "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
  chmod 644 \
    "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
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

t1_install_rc=0
bash "${INSTALLER}" >/dev/null 2>&1 || t1_install_rc=$?

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
assert_eq "T1: watchdog installer succeeds" "0" "${t1_install_rc}"
assert_eq "T1: no tmux new-session call" "0" "${tmux_launches}"
assert_eq "T1: no claude --resume invocation" "0" "${claude_calls}"
assert_eq "T1: resumed_at_ts not stamped" "" "${resumed_at}"
teardown_test

# ---------------------------------------------------------------------------
# T2: Linux without systemctl falls back to a MANAGED cron install.
# The entry should be written automatically, preserve unrelated crontab
# lines, and remain idempotent across re-runs.
# ---------------------------------------------------------------------------
echo "=== T2: linux-without-systemctl installs managed cron entry ==="
setup_test
install_mock_crontab
rm -f "${MOCK_BIN}/systemctl"
rm -f "${MOCK_BIN}/uname"
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf 'MAILTO=ops@example.test\n' > "${HOME}/mock.crontab"
out="$(PATH="${MOCK_BIN}" bash "${INSTALLER}" 2>&1 || true)"
out_repeat="$(PATH="${MOCK_BIN}" bash "${INSTALLER}" 2>&1 || true)"
cron_contents="$(cat "${HOME}/mock.crontab" 2>/dev/null || true)"
cron_count="$(printf '%s\n' "${cron_contents}" | grep -c 'resume-watchdog\.sh' || true)"
marker_count="$(printf '%s\n' "${cron_contents}" | grep -c '^# oh-my-claude resume-watchdog$' || true)"

assert_contains "T2: installer announces cron install" "Cron watchdog entry installed via crontab." "${out}"
assert_contains "T2: repeat install still announces cron install" "Cron watchdog entry installed via crontab." "${out_repeat}"
assert_contains "T2: unrelated crontab line preserved" "MAILTO=ops@example.test" "${cron_contents}"
assert_eq "T2: exactly one managed cron command line" "1" "${cron_count}"
assert_eq "T2: exactly one managed cron marker line" "1" "${marker_count}"
teardown_test

# ---------------------------------------------------------------------------
# T3: cron uninstall removes only the managed watchdog block and honors
# --reset-conf while preserving unrelated crontab lines.
# ---------------------------------------------------------------------------
echo "=== T3: cron uninstall removes managed block and resets conf ==="
setup_test
install_mock_crontab
rm -f "${MOCK_BIN}/systemctl"
rm -f "${MOCK_BIN}/uname"
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf '%s\n' 'MAILTO=ops@example.test' \
  '17 * * * * bash /opt/acme/resume-watchdog.sh --custom' \
  > "${HOME}/mock.crontab"
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 || true
out_uninstall="$(PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf 2>&1 || true)"
cron_after_uninstall="$(cat "${HOME}/mock.crontab" 2>/dev/null || true)"
cron_residue="$(printf '%s\n' "${cron_after_uninstall}" \
  | grep -Fc "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh" || true)"

assert_contains "T3: uninstall announces cron removal" "Cron watchdog entry removed." "${out_uninstall}"
assert_contains "T3: unrelated crontab line still present" "MAILTO=ops@example.test" "${cron_after_uninstall}"
assert_eq "T3: no managed watchdog cron command line remains" "0" "${cron_residue}"
assert_contains "T3: foreign same-basename cron line survives" \
  "/opt/acme/resume-watchdog.sh --custom" "${cron_after_uninstall}"
if grep -q '^resume_watchdog=off' "${HOME}/.claude/oh-my-claude.conf"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: uninstall --reset-conf did not set resume_watchdog=off\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# ---------------------------------------------------------------------------
# T3b: scheduler uninstall must remain available after the runtime watchdog
# script is missing. The harness uninstaller uses this ordering deliberately:
# scheduler first, then quality-pack removal; repair runs also need a cleanup
# path when quality-pack was already partially removed.
# ---------------------------------------------------------------------------
echo "=== T3b: uninstall does not require runtime watchdog script ==="
setup_test
install_mock_crontab
rm -f "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
rm -f "${MOCK_BIN}/uname"
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
missing_runtime_rc=0
missing_runtime_out="$(PATH="${MOCK_BIN}:${ORIG_PATH}" \
  bash "${INSTALLER}" --uninstall --reset-conf 2>&1)" || missing_runtime_rc=$?
assert_eq "T3b: scheduler uninstall succeeds without runtime script" \
  "0" "${missing_runtime_rc}"
assert_eq "T3b: missing runtime is not reported as install prerequisite" "0" \
  "$(grep -c 'missing .*resume-watchdog.sh' <<<"${missing_runtime_out}" || true)"
if grep -q '^resume_watchdog=off' "${HOME}/.claude/oh-my-claude.conf"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3b: uninstall without runtime did not reset conf\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# ---------------------------------------------------------------------------
# T4: code-shape backstop — installer MUST set OMC_WATCHDOG_SELF_TEST=1
# when invoking the watchdog. A future "clean up env-var prefix" PR that
# strips this prefix would re-introduce the v1.41.x bug; this assertion
# locks the surface even if T1's mock infrastructure ever drifts.
# ---------------------------------------------------------------------------
echo "=== T4: installer code shape sets OMC_WATCHDOG_SELF_TEST=1 ==="
if grep -E 'OMC_WATCHDOG_SELF_TEST=1 bash "\$\{WATCHDOG_SCRIPT\}"' "${INSTALLER}" >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4: installer must invoke watchdog with OMC_WATCHDOG_SELF_TEST=1 prefix (regression of v1.41.x post-install audit)\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# T5: install with NO claimable artifact still completes cleanly
# Sanity check that the self-test path doesn't introduce a false-negative
# on the common case (no artifacts on disk = nothing to consume anyway).
# ---------------------------------------------------------------------------
echo "=== T5: install with no claimable artifact succeeds ==="
setup_test
out="$(bash "${INSTALLER}" 2>&1 || true)"
# Use case statement instead of assert_true+eval — the installer output
# contains shell metacharacters that mangle eval-based string matching.
if [[ "${out}" == *"self-test: OK"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T5: install output missing "self-test: OK" marker\n' >&2
  fail=$((fail + 1))
fi
if grep -q '^resume_watchdog=on' "${HOME}/.claude/oh-my-claude.conf"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T5: install did not set resume_watchdog=on in conf\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# ---------------------------------------------------------------------------
# T-path-inject: a control byte in the probed $PATH must fail before any
# launchd/systemd rendering. Normalizing the value would make preflight and
# publication reason about different strings.
# ---------------------------------------------------------------------------
echo "=== T-path-inject: PATH controls fail before scheduler rendering ==="
setup_test
# Mock SHELL to emit an embedded CR/LF plus an injection payload.
cat > "${MOCK_BIN}/evilshell" <<'MOCK'
#!/usr/bin/env bash
printf '/omc/sentinel/bin\r\nOMCINJECTEDDIRECTIVE'
MOCK
chmod +x "${MOCK_BIN}/evilshell"
path_inject_rc=0
path_inject_out="$(SHELL="${MOCK_BIN}/evilshell" \
  bash "${INSTALLER}" 2>&1)" || path_inject_rc=$?
assert_eq "T-path-inject: control-bearing PATH is rejected" "1" \
  "${path_inject_rc}"
assert_contains "T-path-inject: rejection identifies unsafe render input" \
  "refusing unsafe scheduler render input" "${path_inject_out}"
assert_eq "T-path-inject: no systemd service is rendered" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
assert_eq "T-path-inject: no LaunchAgent is rendered" "false" \
  "$([[ -e "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist" ]] \
    && printf true || printf false)"
assert_eq "T-path-inject: rejection precedes transaction creation" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-scheduler-txn.*' -print | wc -l | tr -d '[:space:]')"
teardown_test

# ---------------------------------------------------------------------------
# T6: a marker that is not immediately followed by the exact managed command
# is foreign/orphan text. Cleanup must not consume the following cron line.
# ---------------------------------------------------------------------------
echo "=== T6: orphan cron marker preserves following foreign line ==="
setup_test
install_mock_crontab
rm -f "${MOCK_BIN}/systemctl"
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf '%s\n' '# oh-my-claude resume-watchdog' \
  '23 * * * * /opt/acme/important-job' > "${HOME}/mock.crontab"
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1
orphan_after="$(cat "${HOME}/mock.crontab")"
assert_contains "T6: orphan marker survives" \
  '# oh-my-claude resume-watchdog' "${orphan_after}"
assert_contains "T6: following foreign cron line survives" \
  '/opt/acme/important-job' "${orphan_after}"
teardown_test

# ---------------------------------------------------------------------------
# T7: cron publication is compare-and-swap. A concurrent edit between the
# initial read and publication is preserved, and failed rollback must not
# restore the older snapshot when this invocation never published.
# ---------------------------------------------------------------------------
echo "=== T7: concurrent crontab edit aborts without clobber ==="
setup_test
rm -f "${MOCK_BIN}/systemctl"
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf 'MAILTO=ops@example.test\n' > "${HOME}/mock.crontab"
cat > "${MOCK_BIN}/crontab" <<MOCK
#!/usr/bin/env bash
store="${HOME}/mock.crontab"
count_file="${HOME}/mock.crontab.read-count"
case "\${1:-}" in
  -l|"")
    count=0
    [[ -f "\${count_file}" ]] && count="\$(cat "\${count_file}")"
    count=\$((count + 1))
    printf '%s\n' "\${count}" > "\${count_file}"
    if [[ "\${count}" -eq 3 ]]; then
      printf '41 * * * * /opt/acme/concurrent-job\n' >> "\${store}"
    fi
    cat "\${store}"
    ;;
  -) cat > "\${store}" ;;
  *) exit 64 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/crontab"
cas_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 || cas_rc=$?
assert_eq "T7: concurrent cron mutation aborts install" "1" "${cas_rc}"
cas_after="$(cat "${HOME}/mock.crontab")"
assert_contains "T7: concurrent cron line is preserved" \
  '/opt/acme/concurrent-job' "${cas_after}"
assert_eq "T7: failed CAS publishes no managed cron command" "0" \
  "$(grep -Fc "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh" \
      "${HOME}/mock.crontab" || true)"
teardown_test

# ---------------------------------------------------------------------------
# T8: a fatal self-test rolls back scheduler files, config, and active state.
# ---------------------------------------------------------------------------
echo "=== T8: failed self-test rolls back scheduler transaction ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf 'sentinel=before\n' > "${HOME}/.claude/oh-my-claude.conf"
printf 'old-service\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
printf 'old-timer\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
rm -f "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' \
  > "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
chmod +x "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
selftest_rc=0
bash "${INSTALLER}" >/dev/null 2>&1 || selftest_rc=$?
assert_eq "T8: failed self-test is fatal" "1" "${selftest_rc}"
assert_eq "T8: config bytes restored" 'sentinel=before' \
  "$(cat "${HOME}/.claude/oh-my-claude.conf")"
assert_eq "T8: prior service restored" 'old-service' \
  "$(cat "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service")"
assert_eq "T8: prior timer restored" 'old-timer' \
  "$(cat "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer")"
assert_eq "T8: newly active timer disabled by rollback" "false" \
  "$([[ -e "${MOCK_BIN}/systemctl.active" ]] && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T9: watchdog operations share the install/uninstall mutex. Standalone work
# fails while it is held; a nested uninstaller call may borrow only the exact
# PID/token pair and must leave ownership with the parent.
# ---------------------------------------------------------------------------
echo "=== T9: shared operation lock excludes standalone and admits exact borrow ==="
setup_test
install_mock_crontab
mkdir "${HOME}/.claude/.install.lock"
printf '424242\n' > "${HOME}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${HOME}/.claude/.install.lock/token"
lock_rc=0
OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=1 bash "${INSTALLER}" \
  >/dev/null 2>&1 || lock_rc=$?
assert_eq "T9: standalone watchdog is excluded by shared lock" "1" "${lock_rc}"

# A borrowed credential must match canonical file bytes, not the value Bash
# would obtain after dropping a NUL or trailing blank record.
printf '424242\000\n' > "${HOME}/.claude/.install.lock/pid"
nul_borrow_rc=0
OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=1 \
OMC_PARENT_OPERATION_LOCK_PID=424242 \
OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token \
  bash "${INSTALLER}" --uninstall --reset-conf \
    >/dev/null 2>&1 || nul_borrow_rc=$?
assert_eq "T9: raw-NUL owner PID cannot authorize a borrowed lock" "1" \
  "${nul_borrow_rc}"
assert_eq "T9: raw-NUL borrowed-lock refusal preserves the lock" "true" \
  "$([[ -d "${HOME}/.claude/.install.lock" ]] \
    && printf true || printf false)"
printf '424242\n' > "${HOME}/.claude/.install.lock/pid"
printf 'parent-token\n\n' > "${HOME}/.claude/.install.lock/token"
blank_borrow_rc=0
OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=1 \
OMC_PARENT_OPERATION_LOCK_PID=424242 \
OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token \
  bash "${INSTALLER}" --uninstall --reset-conf \
    >/dev/null 2>&1 || blank_borrow_rc=$?
assert_eq "T9: trailing blank token cannot authorize a borrowed lock" "1" \
  "${blank_borrow_rc}"
assert_eq "T9: malformed token creates no participant authority" "0" \
  "$(find "${HOME}/.claude/.install.lock" -maxdepth 1 \
      -name 'participant.*' -print | wc -l | tr -d '[:space:]')"
printf 'parent-token\n' > "${HOME}/.claude/.install.lock/token"
borrow_rc=0
OMC_PARENT_OPERATION_LOCK_PID=424242 \
OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token \
  bash "${INSTALLER}" --uninstall --reset-conf \
    >/dev/null 2>&1 || borrow_rc=$?
assert_eq "T9: exact parent lock token permits nested cleanup" "0" \
  "${borrow_rc}"
assert_eq "T9: borrowed operation lock remains parent-owned" "parent-token" \
  "$(cat "${HOME}/.claude/.install.lock/token")"
assert_eq "T9: ordinary borrowed cleanup retires its participant" "0" \
  "$(find "${HOME}/.claude/.install.lock" -maxdepth 1 \
      -name 'participant.*' -print | wc -l | tr -d '[:space:]')"

# Keep a borrowed child live at its final cleanup barrier. Its participant row
# is the parent's durable reason not to remove pid/token from an EXIT trap.
borrow_ready="${HOME}/borrowed-watchdog.ready"
borrow_release="${HOME}/borrowed-watchdog.release"
borrow_lock_id="$(stat -c '%d:%i' "${HOME}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${HOME}/.claude/.install.lock")"
(
  OMC_TEST_WATCHDOG_BARRIER_ENABLE=1 \
  OMC_TEST_WATCHDOG_TX_CLEANUP_READY_FILE="${borrow_ready}" \
  OMC_TEST_WATCHDOG_TX_CLEANUP_RELEASE_FILE="${borrow_release}" \
  OMC_PARENT_OPERATION_LOCK_PID=424242 \
  OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token \
  OMC_PARENT_OPERATION_LOCK_ID="${borrow_lock_id}" \
    bash "${INSTALLER}" --uninstall --reset-conf >/dev/null 2>&1
) &
borrow_pid=$!
borrow_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${borrow_ready}" ]] && { borrow_seen=1; break; }
  kill -0 "${borrow_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T9: borrowed watchdog reaches cleanup while still registered" "1" \
  "${borrow_seen}"
assert_eq "T9: live borrowed watchdog publishes one participant" "1" \
  "$(find "${HOME}/.claude/.install.lock" -maxdepth 1 \
      -name 'participant.*' -type f -print | wc -l | tr -d '[:space:]')"
assert_eq "T9: participant keeps parent pid/token generation present" \
  "424242:parent-token" \
  "$(printf '%s:%s' \
    "$(cat "${HOME}/.claude/.install.lock/pid" 2>/dev/null || true)" \
    "$(cat "${HOME}/.claude/.install.lock/token" 2>/dev/null || true)")"
# Model the parent EXIT handoff while its child is still live. The marker is
# bound to this exact lock inode and owner credential; the participant must
# keep the generation in place until its own exact cleanup becomes the last
# borrower, at which point it atomically retires and reaps that generation.
printf 'v1\t%s\t424242\tparent-token\n' "${borrow_lock_id}" \
  > "${HOME}/.claude/.install.lock/owner-released"
chmod 600 "${HOME}/.claude/.install.lock/owner-released"
assert_eq "T9: owner release preserves a live participant generation" \
  "424242:parent-token" \
  "$(printf '%s:%s' \
    "$(cat "${HOME}/.claude/.install.lock/pid" 2>/dev/null || true)" \
    "$(cat "${HOME}/.claude/.install.lock/token" 2>/dev/null || true)")"
: > "${borrow_release}"
borrow_lifecycle_rc=0
wait "${borrow_pid}" || borrow_lifecycle_rc=$?
assert_eq "T9: borrowed watchdog completes after participant barrier" "0" \
  "${borrow_lifecycle_rc}"
assert_eq "T9: last borrower atomically reaps the released generation" \
  "absent" \
  "$([[ -e "${HOME}/.claude/.install.lock" \
      || -L "${HOME}/.claude/.install.lock" ]] \
      && printf present || printf absent)"
assert_eq "T9: successful handoff leaves no retirement scratch" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
      -name '.install-lock-retired.*' -print | wc -l \
      | tr -d '[:space:]')"

# A marker whose binding does not match the lock generation is not cleanup
# authority. The nested caller must fail closed and preserve every byte.
mkdir "${HOME}/.claude/.install.lock"
printf '424242\n' > "${HOME}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${HOME}/.claude/.install.lock/token"
printf 'v1\tforged-id\t424242\tparent-token\n' \
  > "${HOME}/.claude/.install.lock/owner-released"
chmod 600 "${HOME}/.claude/.install.lock/owner-released"
forged_marker_before="$(cat \
  "${HOME}/.claude/.install.lock/owner-released")"
forged_marker_rc=0
OMC_PARENT_OPERATION_LOCK_PID=424242 \
OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token \
  bash "${INSTALLER}" --uninstall --reset-conf \
    >/dev/null 2>&1 || forged_marker_rc=$?
assert_eq "T9: forged release marker rejects nested admission" "1" \
  "${forged_marker_rc}"
assert_eq "T9: forged release marker is preserved exactly" \
  "${forged_marker_before}" \
  "$(cat "${HOME}/.claude/.install.lock/owner-released")"
assert_eq "T9: forged marker cannot erase the owner credential" \
  "424242:parent-token" \
  "$(printf '%s:%s' \
    "$(cat "${HOME}/.claude/.install.lock/pid")" \
    "$(cat "${HOME}/.claude/.install.lock/token")")"
teardown_test

# A stranded release marker is equally byte-exact. NUL-normalized or
# additional-line variants must remain in place rather than being reaped.
echo "=== T9a2: malformed release authority is preserved ==="
setup_test
install_mock_crontab
mkdir "${HOME}/.claude/.install.lock"
printf '424242\n' > "${HOME}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${HOME}/.claude/.install.lock/token"
malformed_release_id="$(stat -c '%d:%i' "${HOME}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${HOME}/.claude/.install.lock")"
printf 'v1\t%s\t424242\tparent-token\000\n' \
  "${malformed_release_id}" \
  > "${HOME}/.claude/.install.lock/owner-released"
chmod 600 "${HOME}/.claude/.install.lock/owner-released"
nul_release_rc=0
OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=1 bash "${INSTALLER}" \
  --uninstall --reset-conf >/dev/null 2>&1 || nul_release_rc=$?
assert_eq "T9a2: raw-NUL release marker cannot be reaped" "1" \
  "${nul_release_rc}"
assert_eq "T9a2: raw-NUL release generation remains inspectable" "true" \
  "$([[ -d "${HOME}/.claude/.install.lock" ]] \
    && printf true || printf false)"
printf 'v1\t%s\t424242\tparent-token\n\n' "${malformed_release_id}" \
  > "${HOME}/.claude/.install.lock/owner-released"
blank_release_rc=0
OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=1 bash "${INSTALLER}" \
  --uninstall --reset-conf >/dev/null 2>&1 || blank_release_rc=$?
assert_eq "T9a2: extra blank release marker cannot be reaped" "1" \
  "${blank_release_rc}"
assert_eq "T9a2: malformed release bytes are never retired" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
      -name '.install-lock-retired.*' -print | wc -l \
      | tr -d '[:space:]')"
teardown_test

echo "=== T9a3: scheduler transaction metadata is byte-canonical ==="
setup_test
eval "$(sed -n \
  '/^watchdog_metadata_file_is_canonical()/,/^}/p' "${INSTALLER}")"
eval "$(sed -n \
  '/^watchdog_read_canonical_metadata_snapshot()/,/^}/p' "${INSTALLER}")"
eval "$(sed -n \
  '/^watchdog_read_canonical_metadata_line()/,/^}/p' "${INSTALLER}")"
scheduler_meta_probe="${HOME}/scheduler-meta.probe"
printf 'present\n' > "${scheduler_meta_probe}"
assert_eq "T9a3: canonical scheduler enum is readable" "present" \
  "$(watchdog_read_canonical_metadata_line "${scheduler_meta_probe}" 32)"
printf 'present\000\n' > "${scheduler_meta_probe}"
assert_eq "T9a3: raw-NUL scheduler enum is rejected" "rejected" \
  "$(if watchdog_read_canonical_metadata_line \
      "${scheduler_meta_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf 'present\n\n' > "${scheduler_meta_probe}"
assert_eq "T9a3: extra scheduler enum row is rejected" "rejected" \
  "$(if watchdog_read_canonical_metadata_line \
      "${scheduler_meta_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf '1:2\tpresent\t3:4\t%s\t600\n' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  > "${scheduler_meta_probe}"
assert_eq "T9a3: canonical scheduler history is byte-stable" "accepted" \
  "$(if watchdog_metadata_file_is_canonical \
      "${scheduler_meta_probe}" 4096 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf '\n' >> "${scheduler_meta_probe}"
assert_eq "T9a3: trailing blank scheduler history is rejected" "rejected" \
  "$(if watchdog_metadata_file_is_canonical \
      "${scheduler_meta_probe}" 4096 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
teardown_test

# ---------------------------------------------------------------------------
# T9b: a process can die after publishing owner-released but before it moves
# the lock aside. A later standalone operation must authenticate and reap that
# participant-free generation instead of timing out behind a stranded lock.
# ---------------------------------------------------------------------------
echo "=== T9b: stranded released generation is reaped on takeover ==="
setup_test
install_mock_crontab
mkdir "${HOME}/.claude/.install.lock"
printf '424242\n' > "${HOME}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${HOME}/.claude/.install.lock/token"
stranded_lock_id="$(stat -c '%d:%i' "${HOME}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${HOME}/.claude/.install.lock")"
printf 'v1\t%s\t424242\tparent-token\n' "${stranded_lock_id}" \
  > "${HOME}/.claude/.install.lock/owner-released"
chmod 600 "${HOME}/.claude/.install.lock/owner-released"
stranded_takeover_rc=0
bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || stranded_takeover_rc=$?
assert_eq "T9b: valid stranded release permits standalone takeover" "0" \
  "${stranded_takeover_rc}"
assert_eq "T9b: takeover leaves no active lock generation" "absent" \
  "$([[ -e "${HOME}/.claude/.install.lock" \
      || -L "${HOME}/.claude/.install.lock" ]] \
      && printf present || printf absent)"
assert_eq "T9b: takeover exactly removes retirement scratch" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
      -name '.install-lock-retired.*' -print | wc -l \
      | tr -d '[:space:]')"
teardown_test

# ---------------------------------------------------------------------------
# T9b2: retry-count test seams are bounded before they enter shell arithmetic.
# An oversized value must fail promptly rather than turning lock contention
# into an effectively unbounded loop (or an implementation-width wrap).
# ---------------------------------------------------------------------------
echo "=== T9b2: oversized lock retry seam is rejected promptly ==="
setup_test
mkdir "${HOME}/.claude/.install.lock"
printf '424242\n' >"${HOME}/.claude/.install.lock/pid"
printf 'busy-owner\n' >"${HOME}/.claude/.install.lock/token"
(
  OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=999999999999999999999999 \
    bash "${INSTALLER}" --uninstall --reset-conf >/dev/null 2>&1
) & oversized_attempt_pid=$!
oversized_attempt_done=0
for _wait in $(seq 1 100); do
  if ! kill -0 "${oversized_attempt_pid}" 2>/dev/null; then
    oversized_attempt_done=1
    break
  fi
  sleep 0.01
done
if [[ "${oversized_attempt_done}" -ne 1 ]]; then
  kill "${oversized_attempt_pid}" 2>/dev/null || true
fi
wait "${oversized_attempt_pid}" 2>/dev/null || true
assert_eq "T9b2: oversized retry count cannot extend lock wait" "1" \
  "${oversized_attempt_done}"
teardown_test

# ---------------------------------------------------------------------------
# T9c: the public pathname becomes available at the retirement rename. A new
# owner may acquire it before the old reaper finishes; that valid next
# generation must not make exact cleanup of the retired inode fail or leak.
# ---------------------------------------------------------------------------
echo "=== T9c: next generation may acquire during retired cleanup ==="
setup_test
install_mock_crontab
mkdir "${HOME}/.claude/.install.lock"
printf '424242\n' > "${HOME}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${HOME}/.claude/.install.lock/token"
old_lock_id="$(stat -c '%d:%i' "${HOME}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${HOME}/.claude/.install.lock")"
printf 'v1\t%s\t424242\tparent-token\n' "${old_lock_id}" \
  > "${HOME}/.claude/.install.lock/owner-released"
chmod 600 "${HOME}/.claude/.install.lock/owner-released"
retired_ready="${HOME}/retired-lock.ready"
retired_release="${HOME}/retired-lock.release"
(
  OMC_TEST_WATCHDOG_BARRIER_ENABLE=1 \
  OMC_TEST_WATCHDOG_LOCK_RETIRED_READY_FILE="${retired_ready}" \
  OMC_TEST_WATCHDOG_LOCK_RETIRED_RELEASE_FILE="${retired_release}" \
  OMC_TEST_WATCHDOG_LOCK_ATTEMPTS=1 \
    bash "${INSTALLER}" --uninstall --reset-conf >/dev/null 2>&1
) & old_reaper_pid=$!
retired_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${retired_ready}" ]] && { retired_seen=1; break; }
  kill -0 "${old_reaper_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T9c: old generation reaches post-rename cleanup barrier" "1" \
  "${retired_seen}"

next_ready="${HOME}/next-generation.ready"
next_release="${HOME}/next-generation.release"
(
  OMC_TEST_WATCHDOG_BARRIER_ENABLE=1 \
  OMC_TEST_WATCHDOG_TX_CLEANUP_READY_FILE="${next_ready}" \
  OMC_TEST_WATCHDOG_TX_CLEANUP_RELEASE_FILE="${next_release}" \
    bash "${INSTALLER}" --uninstall --reset-conf >/dev/null 2>&1
) & next_owner_pid=$!
next_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${next_ready}" ]] && { next_seen=1; break; }
  kill -0 "${next_owner_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T9c: contender acquires the immediate next generation" "1" \
  "${next_seen}"
next_lock_id="$(stat -c '%d:%i' "${HOME}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${HOME}/.claude/.install.lock" \
  2>/dev/null || true)"
assert_eq "T9c: public pathname belongs to a different generation" "different" \
  "$([[ -n "${next_lock_id}" && "${next_lock_id}" != "${old_lock_id}" ]] \
      && printf different || printf wrong)"
: > "${retired_release}"
old_reaper_rc=0
wait "${old_reaper_pid}" || old_reaper_rc=$?
assert_eq "T9c: first contender loses only to the live next owner" "1" \
  "${old_reaper_rc}"
assert_eq "T9c: next owner remains intact after old cleanup" \
  "${next_lock_id}" \
  "$(stat -c '%d:%i' "${HOME}/.claude/.install.lock" \
    2>/dev/null || stat -f '%d:%i' "${HOME}/.claude/.install.lock")"
assert_eq "T9c: old retired generation leaves no scratch" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
      -name '.install-lock-retired.*' -print | wc -l \
      | tr -d '[:space:]')"
: > "${next_release}"
next_owner_rc=0
wait "${next_owner_pid}" || next_owner_rc=$?
assert_eq "T9c: immediate next owner completes normally" "0" \
  "${next_owner_rc}"
assert_eq "T9c: next owner releases the public lock" "absent" \
  "$([[ -e "${HOME}/.claude/.install.lock" \
      || -L "${HOME}/.claude/.install.lock" ]] \
      && printf present || printf absent)"
teardown_test

# ---------------------------------------------------------------------------
# T10: a scheduler leaf that appears after rendering wins the CAS and is
# preserved. No rollback path may treat an unpublished leaf as owned.
# ---------------------------------------------------------------------------
echo "=== T10: scheduler artifact publication rejects concurrent winner ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
artifact_ready="${HOME}/artifact-stage.ready"
artifact_release="${HOME}/artifact-stage.release"
(
  OMC_TEST_WATCHDOG_BARRIER_ENABLE=1 \
  OMC_TEST_WATCHDOG_ARTIFACT_STAGE_MATCH=linux-service \
  OMC_TEST_WATCHDOG_ARTIFACT_STAGE_READY_FILE="${artifact_ready}" \
  OMC_TEST_WATCHDOG_ARTIFACT_STAGE_RELEASE_FILE="${artifact_release}" \
    bash "${INSTALLER}" >/dev/null 2>&1
) &
artifact_pid=$!
artifact_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${artifact_ready}" ]] && { artifact_seen=1; break; }
  sleep 0.01
done
assert_eq "T10: artifact race reaches staged publication" "1" \
  "${artifact_seen}"
printf 'concurrent-service-winner\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
: > "${artifact_release}"
artifact_rc=0
wait "${artifact_pid}" || artifact_rc=$?
assert_eq "T10: concurrent scheduler winner aborts install" "1" \
  "${artifact_rc}"
assert_eq "T10: unpublished scheduler winner survives rollback" \
  "concurrent-service-winner" \
  "$(cat "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service")"
teardown_test

# ---------------------------------------------------------------------------
# T11: config publication uses the same sealed compare-and-swap. A concurrent
# edit after staging is preserved while already-published scheduler artifacts
# roll back to their initial state.
# ---------------------------------------------------------------------------
echo "=== T11: config publication rejects concurrent edit ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf 'sentinel=before\n' > "${HOME}/.claude/oh-my-claude.conf"
conf_ready="${HOME}/conf-stage.ready"
conf_release="${HOME}/conf-stage.release"
(
  OMC_TEST_WATCHDOG_BARRIER_ENABLE=1 \
  OMC_TEST_WATCHDOG_CONF_STAGE_READY_FILE="${conf_ready}" \
  OMC_TEST_WATCHDOG_CONF_STAGE_RELEASE_FILE="${conf_release}" \
    bash "${INSTALLER}" >/dev/null 2>&1
) &
conf_pid=$!
conf_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${conf_ready}" ]] && { conf_seen=1; break; }
  sleep 0.01
done
assert_eq "T11: config race reaches staged publication" "1" "${conf_seen}"
printf 'concurrent=config-winner\n' > "${HOME}/.claude/oh-my-claude.conf"
: > "${conf_release}"
conf_rc=0
wait "${conf_pid}" || conf_rc=$?
assert_eq "T11: concurrent config edit aborts install" "1" "${conf_rc}"
assert_eq "T11: unpublished config winner survives rollback" \
  "concurrent=config-winner" \
  "$(cat "${HOME}/.claude/oh-my-claude.conf")"
assert_eq "T11: prior scheduler publication is rolled back" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T12: rollback itself is compare-and-swap. Concurrent edits made after both
# scheduler and config publication must survive a later self-test failure.
# ---------------------------------------------------------------------------
echo "=== T12: rollback preserves post-publication concurrent edits ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
rm -f "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
cat > "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'concurrent=config-after-publication\n' > "${HOME}/.claude/oh-my-claude.conf"
printf 'concurrent-service-after-publication\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
exit 1
MOCK
chmod +x "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
post_publish_rc=0
bash "${INSTALLER}" >/dev/null 2>&1 || post_publish_rc=$?
assert_eq "T12: self-test failure remains fatal" "1" "${post_publish_rc}"
assert_eq "T12: rollback preserves concurrent config" \
  "concurrent=config-after-publication" \
  "$(cat "${HOME}/.claude/oh-my-claude.conf")"
assert_eq "T12: rollback preserves concurrent scheduler artifact" \
  "concurrent-service-after-publication" \
  "$(cat "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service")"
teardown_test

# ---------------------------------------------------------------------------
# T13: if rollback loses the artifact CAS, it must not reactivate the
# preserved concurrent unit under the prior timer's enabled/active state.
# ---------------------------------------------------------------------------
echo "=== T13: rollback never activates a concurrent scheduler winner ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
printf 'prior-service\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
printf 'prior-timer\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
: > "${MOCK_BIN}/systemctl.enabled"
: > "${MOCK_BIN}/systemctl.active"
cat > "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'concurrent-unit-winner\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
exit 1
MOCK
chmod +x "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
concurrent_active_rc=0
bash "${INSTALLER}" >/dev/null 2>&1 || concurrent_active_rc=$?
assert_eq "T13: concurrent-unit self-test failure remains fatal" "1" \
  "${concurrent_active_rc}"
assert_eq "T13: concurrent unit bytes survive rollback" \
  "concurrent-unit-winner" \
  "$(cat "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service")"
assert_eq "T13: concurrent unit is not re-enabled" "false" \
  "$([[ -e "${MOCK_BIN}/systemctl.enabled" ]] && printf true || printf false)"
assert_eq "T13: concurrent unit is not restarted" "false" \
  "$([[ -e "${MOCK_BIN}/systemctl.active" ]] && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T14: persisted artifact provenance, not today's PATH/template rendering,
# owns a historical scheduler generation during uninstall.
# ---------------------------------------------------------------------------
echo "=== T14: uninstall accepts owned historical render after PATH/template drift ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
bash "${INSTALLER}" >/dev/null 2>&1
printf '\n# newer source template after installed generation\n' \
  >> "${HOME}/.claude/systemd/oh-my-claude-resume-watchdog.service"
cat > "${MOCK_BIN}/different-shell" <<'MOCK'
#!/usr/bin/env bash
printf '%s' '/different/path/after/install'
MOCK
chmod +x "${MOCK_BIN}/different-shell"
historical_uninstall_rc=0
SHELL="${MOCK_BIN}/different-shell" bash "${INSTALLER}" \
  --uninstall --reset-conf >/dev/null 2>&1 || historical_uninstall_rc=$?
assert_eq "T14: historical owned render uninstalls after drift" "0" \
  "${historical_uninstall_rc}"
assert_eq "T14: historical service is removed" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T15: a host may acquire systemd after a historical cron installation. With
# no unit files or loaded timer, Linux cleanup must proceed to cron instead of
# failing an irrelevant `disable --now` call.
# ---------------------------------------------------------------------------
echo "=== T15: historical cron uninstall survives later systemctl availability ==="
setup_test
install_mock_crontab
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
mv "${MOCK_BIN}/systemctl" "${MOCK_BIN}/systemctl.held"
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1
mv "${MOCK_BIN}/systemctl.held" "${MOCK_BIN}/systemctl"
historical_cron_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || historical_cron_rc=$?
assert_eq "T15: later systemctl does not block cron cleanup" "0" \
  "${historical_cron_rc}"
assert_eq "T15: managed cron marker is removed" "0" \
  "$(grep -Fc '# oh-my-claude resume-watchdog' \
    "${HOME}/mock.crontab" 2>/dev/null || true)"
teardown_test

# ---------------------------------------------------------------------------
# T16: executable scheduler authority must come from regular installed files,
# never symlink templates that can be retargeted after validation.
# ---------------------------------------------------------------------------
echo "=== T16: symlink scheduler template is rejected ==="
setup_test
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Linux\n'
MOCK
chmod +x "${MOCK_BIN}/uname"
rm -f "${HOME}/.claude/systemd/oh-my-claude-resume-watchdog.service"
ln -s "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" \
  "${HOME}/.claude/systemd/oh-my-claude-resume-watchdog.service"
symlink_template_rc=0
bash "${INSTALLER}" >/dev/null 2>&1 || symlink_template_rc=$?
assert_eq "T16: symlink template fails closed" "1" "${symlink_template_rc}"
assert_eq "T16: rejected template publishes no service" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T17: migrate both prior cron ownership forms. The immediately preceding
# format used Bash %q but did not protect cron's special `%` character; an
# older raw-path form is admitted only when paired with the managed marker.
# ---------------------------------------------------------------------------
echo "=== T17: historical cron quoting and digest ownership migrate safely ==="
setup_test spaced-percent-home
install_mock_crontab
rm -f "${MOCK_BIN}/systemctl"
mock_platform Linux
historical_script="${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
printf -v historical_quoted '%q' "${historical_script}"
historical_cron_line="*/2 * * * * bash ${historical_quoted} >/dev/null 2>&1"
printf '%s\n' 'MAILTO=ops@example.test' \
  '# oh-my-claude resume-watchdog' "${historical_cron_line}" \
  > "${HOME}/mock.crontab"
printf '%s\n' 'resume_watchdog=on' 'resume_watchdog_scheduler=cron' \
  > "${HOME}/.claude/oh-my-claude.conf"
legacy_cron_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || legacy_cron_rc=$?
assert_eq "T17: spaced/percent historical cron cleanup succeeds" "0" \
  "${legacy_cron_rc}"
assert_eq "T17: historical percent cron line is removed" "0" \
  "$(grep -Fc "${historical_cron_line}" "${HOME}/mock.crontab" || true)"
assert_contains "T17: unrelated cron content survives" \
  'MAILTO=ops@example.test' "$(cat "${HOME}/mock.crontab")"
teardown_test

setup_test
install_mock_crontab
rm -f "${MOCK_BIN}/systemctl"
mock_platform Linux
digest_owned_line='13 4 * * * bash /opt/oh-my-claude-v1/resume-watchdog.sh --legacy'
digest_owned_value="$(test_sha256_text "${digest_owned_line}")"
printf '%s\n' "${digest_owned_line}" '29 4 * * * /opt/acme/foreign-job' \
  > "${HOME}/mock.crontab"
printf '%s\n' 'resume_watchdog=on' 'resume_watchdog_scheduler=cron' \
  "resume_watchdog_cron_sha256=${digest_owned_value}" \
  > "${HOME}/.claude/oh-my-claude.conf"
digest_cron_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || digest_cron_rc=$?
assert_eq "T17: persisted historical cron digest cleans exact line" "0" \
  "${digest_cron_rc}"
assert_eq "T17: digest-owned line is removed" "0" \
  "$(grep -Fc "${digest_owned_line}" "${HOME}/mock.crontab" || true)"
assert_contains "T17: non-matching cron line survives digest cleanup" \
  '/opt/acme/foreign-job' "$(cat "${HOME}/mock.crontab")"
teardown_test

# ---------------------------------------------------------------------------
# T18: a systemd-only uninstall does not require a cron client. Conversely,
# a configured/present scheduler must not be deleted if its platform control
# command is unavailable, because disabled/unloaded state cannot be proved.
# ---------------------------------------------------------------------------
echo "=== T18: scheduler cleanup requires only the relevant control plane ==="
setup_test
mock_platform Linux
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1
systemd_only_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || systemd_only_rc=$?
assert_eq "T18: systemd-only uninstall succeeds without crontab" "0" \
  "${systemd_only_rc}"
teardown_test

setup_test
mock_platform Linux
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1
rm -f "${MOCK_BIN}/systemctl"
missing_systemctl_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || missing_systemctl_rc=$?
assert_eq "T18: missing systemctl blocks owned unit deletion" "1" \
  "${missing_systemctl_rc}"
assert_eq "T18: service survives unprovable systemd cleanup" "true" \
  "$([[ -f "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

setup_test
mock_platform Darwin
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1
rm -f "${MOCK_BIN}/launchctl"
missing_launchctl_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || missing_launchctl_rc=$?
assert_eq "T18: missing launchctl blocks owned plist deletion" "1" \
  "${missing_launchctl_rc}"
assert_eq "T18: plist survives unprovable launchd cleanup" "true" \
  "$([[ -f "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T19: pre-receipt HEAD units were exact 0644 renders and the service used an
# unquoted ExecStart. Reregister owns only those exact bytes, migrates both
# files to the current 0600 render, and records durable digests.
# ---------------------------------------------------------------------------
echo "=== T19: exact pre-receipt systemd units migrate on reregister ==="
setup_test
mock_platform Linux
write_head_rendered_systemd_units "${MOCK_BIN}"
printf '%s\n' 'resume_watchdog=on' 'resume_watchdog_scheduler=systemd' \
  > "${HOME}/.claude/oh-my-claude.conf"
historical_reregister_rc=0
SHELL='' PATH="${MOCK_BIN}" bash "${INSTALLER}" --reregister \
  >/dev/null 2>&1 || historical_reregister_rc=$?
assert_eq "T19: exact historical units reregister" "0" \
  "${historical_reregister_rc}"
service_mode="$(stat -c '%a' \
  "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" \
  2>/dev/null || stat -f '%Lp' \
  "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service")"
timer_mode="$(stat -c '%a' \
  "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer" \
  2>/dev/null || stat -f '%Lp' \
  "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer")"
assert_eq "T19: migrated service mode is private" "600" "${service_mode}"
assert_eq "T19: migrated timer mode is private" "600" "${timer_mode}"
assert_eq "T19: migrated service uses quoted ExecStart" "1" \
  "$(grep -Fc 'ExecStart=/bin/bash "' \
    "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" || true)"
assert_eq "T19: service ownership digest recorded" "1" \
  "$(grep -Ec '^resume_watchdog_systemd_service_sha256=[0-9a-f]{64}$' \
    "${HOME}/.claude/oh-my-claude.conf" || true)"
assert_eq "T19: timer ownership digest recorded" "1" \
  "$(grep -Ec '^resume_watchdog_systemd_timer_sha256=[0-9a-f]{64}$' \
    "${HOME}/.claude/oh-my-claude.conf" || true)"
teardown_test

setup_test
mock_platform Darwin
write_head_rendered_launchd_plist "${MOCK_BIN}"
printf '%s\n' 'resume_watchdog=on' 'resume_watchdog_scheduler=launchd' \
  > "${HOME}/.claude/oh-my-claude.conf"
historical_launchd_rc=0
SHELL='' PATH="${MOCK_BIN}" bash "${INSTALLER}" --reregister \
  >/dev/null 2>&1 || historical_launchd_rc=$?
assert_eq "T19: exact historical LaunchAgent reregisters" "0" \
  "${historical_launchd_rc}"
plist_mode="$(stat -c '%a' \
  "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist" \
  2>/dev/null || stat -f '%Lp' \
  "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist")"
assert_eq "T19: migrated LaunchAgent mode is private" "600" "${plist_mode}"
assert_eq "T19: LaunchAgent ownership digest recorded" "1" \
  "$(grep -Ec '^resume_watchdog_launchd_sha256=[0-9a-f]{64}$' \
    "${HOME}/.claude/oh-my-claude.conf" || true)"
teardown_test

setup_test
mock_platform Linux
write_head_rendered_systemd_units "${MOCK_BIN}"
printf '%s\n' 'resume_watchdog=on' 'resume_watchdog_scheduler=systemd' \
  > "${HOME}/.claude/oh-my-claude.conf"
historical_uninstall_no_digest_rc=0
SHELL='' PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || historical_uninstall_no_digest_rc=$?
assert_eq "T19: exact no-digest historical units uninstall" "0" \
  "${historical_uninstall_no_digest_rc}"
assert_eq "T19: historical service is removed after proven disable" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T20: reregister is never authority to overwrite foreign scheduler files or
# activate them. Both platform implementations must refuse before publish.
# ---------------------------------------------------------------------------
echo "=== T20: foreign scheduler artifacts cannot be reregistered ==="
setup_test
mock_platform Linux
printf 'foreign-service\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
printf 'foreign-timer\n' \
  > "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
chmod 600 "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog."{service,timer}
foreign_systemd_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --reregister \
  >/dev/null 2>&1 || foreign_systemd_rc=$?
assert_eq "T20: foreign systemd units are refused" "1" "${foreign_systemd_rc}"
assert_eq "T20: foreign service bytes survive" "foreign-service" \
  "$(cat "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service")"
assert_eq "T20: foreign systemd units are not activated" "0" \
  "$(grep -c 'enable --now' "${MOCK_BIN}/systemctl.calls" 2>/dev/null || true)"
teardown_test

setup_test
mock_platform Darwin
printf 'foreign-plist\n' \
  > "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
chmod 600 "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
foreign_macos_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --reregister \
  >/dev/null 2>&1 || foreign_macos_rc=$?
assert_eq "T20: foreign LaunchAgent is refused" "1" "${foreign_macos_rc}"
assert_eq "T20: foreign plist bytes survive" "foreign-plist" \
  "$(cat "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist")"
assert_eq "T20: foreign LaunchAgent is not bootstrapped" "0" \
  "$(grep -c '^bootstrap ' "${MOCK_BIN}/launchctl.calls" 2>/dev/null || true)"
teardown_test

# ---------------------------------------------------------------------------
# T21: success from enable/bootstrap/disable/bootout is not enough. The final
# scheduler generation must be observably active for install and inactive for
# uninstall before the transaction can commit.
# ---------------------------------------------------------------------------
echo "=== T21: scheduler command success without state change fails closed ==="
setup_test
mock_platform Linux
cat > "${MOCK_BIN}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *' is-enabled '*|*' is-active '*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/systemctl"
noop_enable_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 || noop_enable_rc=$?
assert_eq "T21: no-op systemd enable fails install" "1" "${noop_enable_rc}"
teardown_test

setup_test
mock_platform Darwin
cat > "${MOCK_BIN}/launchctl" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  print) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/launchctl"
noop_bootstrap_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 \
  || noop_bootstrap_rc=$?
assert_eq "T21: no-op launchctl bootstrap fails install" "1" \
  "${noop_bootstrap_rc}"
teardown_test

setup_test
mock_platform Linux
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1
cat > "${MOCK_BIN}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *' is-enabled '*|*' is-active '*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/systemctl"
noop_disable_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || noop_disable_rc=$?
assert_eq "T21: no-op systemd disable fails cleanup" "1" "${noop_disable_rc}"
assert_eq "T21: units survive no-op disable" "true" \
  "$([[ -f "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer" ]] \
    && printf true || printf false)"
teardown_test

setup_test
mock_platform Darwin
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1
cat > "${MOCK_BIN}/launchctl" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  print) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/launchctl"
noop_bootout_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --uninstall --reset-conf \
  >/dev/null 2>&1 || noop_bootout_rc=$?
assert_eq "T21: no-op launchctl bootout fails cleanup" "1" \
  "${noop_bootout_rc}"
assert_eq "T21: plist survives no-op bootout" "true" \
  "$([[ -f "${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T22: destination directories are created one component at a time under a
# sealed, no-symlink ancestor chain. Install and reregister must never follow
# a hostile intermediate link into another tree.
# ---------------------------------------------------------------------------
echo "=== T22: scheduler destination ancestor symlinks are refused ==="
setup_test
mock_platform Linux
foreign_tree="$(mktemp -d)"
rm -rf "${HOME}/.config"
ln -s "${foreign_tree}" "${HOME}/.config"
unsafe_linux_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 || unsafe_linux_rc=$?
assert_eq "T22: Linux install refuses symlinked destination ancestor" "1" \
  "${unsafe_linux_rc}"
assert_eq "T22: Linux install writes nothing through ancestor symlink" "false" \
  "$([[ -e "${foreign_tree}/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
rm -rf "${foreign_tree}"
teardown_test

setup_test
mock_platform Darwin
foreign_tree="$(mktemp -d)"
rm -rf "${HOME}/Library"
ln -s "${foreign_tree}" "${HOME}/Library"
unsafe_macos_install_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 \
  || unsafe_macos_install_rc=$?
assert_eq "T22: macOS install refuses symlinked destination ancestor" "1" \
  "${unsafe_macos_install_rc}"
unsafe_macos_rr_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" --reregister >/dev/null 2>&1 \
  || unsafe_macos_rr_rc=$?
assert_eq "T22: macOS reregister refuses symlinked destination ancestor" "1" \
  "${unsafe_macos_rr_rc}"
assert_eq "T22: macOS paths are not written through ancestor symlink" "false" \
  "$([[ -e "${foreign_tree}/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist" ]] \
    && printf true || printf false)"
rm -rf "${foreign_tree}"
teardown_test

# ---------------------------------------------------------------------------
# T23: watchdog mutation settles the two shared durable WALs while it owns the
# global mutation lock. Recovery executes manifest-attested private helper
# copies in tier-before-config order; helper drift fails before either WAL or
# any scheduler/config destination is touched.
# ---------------------------------------------------------------------------
echo "=== T23: shared transaction recovery is ordered and manifest-attested ==="
setup_test
mock_platform Linux
install_mock_recovery_authority
mkdir "${HOME}/.claude/.switch-tier-transaction"
mkdir "${HOME}/.claude/.switch-tier-transaction.stage.STAGE1"
mkdir "${HOME}/.claude/.switch-tier-retired.RETIRED1"
mkdir "${HOME}/.claude/.omc-config-transaction"
mkdir "${HOME}/.claude/.omc-config-transaction.stage.STAGE1"
mkdir "${HOME}/.claude/.omc-config-retired.RETIRED1"
cat > "${HOME}/recovery-bash-env.sh" <<'MOCK'
case "$0" in
  *'.watchdog-recovery-helpers.'*)
    printf 'unexpected startup injection\n' >> "${HOME}/recovery-env-injected.log"
    ;;
esac
MOCK
shared_recovery_rc=0
BASH_ENV="${HOME}/recovery-bash-env.sh" \
ENV="${HOME}/recovery-bash-env.sh" \
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 \
  || shared_recovery_rc=$?
assert_eq "T23: watchdog install settles shared transactions" "0" \
  "${shared_recovery_rc}"
assert_eq "T23: recovery helper order is tier then config" $'switch\nomc' \
  "$(cat "${HOME}/recovery-order.log" 2>/dev/null || true)"
assert_eq "T23: switch-tier WAL is retired" "false" \
  "$([[ -e "${HOME}/.claude/.switch-tier-transaction" \
      || -L "${HOME}/.claude/.switch-tier-transaction" ]] \
    && printf true || printf false)"
assert_eq "T23: omc-config WAL is retired" "false" \
  "$([[ -e "${HOME}/.claude/.omc-config-transaction" \
      || -L "${HOME}/.claude/.omc-config-transaction" ]] \
    && printf true || printf false)"
assert_eq "T23: complete switch metadata class is swept" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    \( -name '.switch-tier-transaction' \
      -o -name '.switch-tier-transaction.stage.*' \
      -o -name '.switch-tier-retired.*' \) -print \
    | wc -l | tr -d '[:space:]')"
assert_eq "T23: complete omc metadata class is swept" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    \( -name '.omc-config-transaction' \
      -o -name '.omc-config-transaction.stage.*' \
      -o -name '.omc-config-retired.*' \) -print \
    | wc -l | tr -d '[:space:]')"
assert_eq "T23: sealed helper execution clears Bash startup injection" "false" \
  "$([[ -e "${HOME}/recovery-env-injected.log" ]] \
    && printf true || printf false)"
assert_eq "T23: private recovery snapshots are exactly cleaned" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-recovery-helpers.*' -print | wc -l | tr -d '[:space:]')"
teardown_test

setup_test
mock_platform Linux
install_mock_recovery_authority
mkdir "${HOME}/.claude/.omc-config-transaction.stage.ONLYOMC"
printf '# irrelevant switch helper drift\n' >> "${HOME}/.claude/switch-tier.sh"
omc_only_recovery_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 \
  || omc_only_recovery_rc=$?
assert_eq "T23: omc-only metadata invokes only omc authority" "0" \
  "${omc_only_recovery_rc}"
assert_eq "T23: omc-only recovery skips unused switch helper" "omc" \
  "$(cat "${HOME}/recovery-order.log" 2>/dev/null || true)"
teardown_test

setup_test
mock_platform Linux
install_mock_recovery_authority
mkdir "${HOME}/.claude/.switch-tier-transaction"
mkdir "${HOME}/.claude/.omc-config-transaction"
printf '# drift after manifest publication\n' \
  >> "${HOME}/.claude/switch-tier.sh"
drifted_recovery_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 \
  || drifted_recovery_rc=$?
assert_eq "T23: drifted recovery helper fails closed" "1" \
  "${drifted_recovery_rc}"
assert_eq "T23: drift leaves switch-tier WAL untouched" "true" \
  "$([[ -d "${HOME}/.claude/.switch-tier-transaction" ]] \
    && printf true || printf false)"
assert_eq "T23: drift leaves omc-config WAL untouched" "true" \
  "$([[ -d "${HOME}/.claude/.omc-config-transaction" ]] \
    && printf true || printf false)"
assert_eq "T23: drift fails before scheduler publication" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T24: the private scheduler transaction directory is an exact generation,
# not a pathname-shaped rm -rf capability. A descendant injected during the
# cleanup barrier makes cleanup fail closed and survives for inspection.
# ---------------------------------------------------------------------------
echo "=== T24: scheduler transaction cleanup preserves changed subtrees ==="
setup_test
mock_platform Linux
tx_cleanup_ready="${HOME}/watchdog-tx-cleanup.ready"
tx_cleanup_release="${HOME}/watchdog-tx-cleanup.release"
tx_cleanup_out="${HOME}/watchdog-tx-cleanup.out"
(
  OMC_TEST_WATCHDOG_BARRIER_ENABLE=1 \
  OMC_TEST_WATCHDOG_TX_CLEANUP_READY_FILE="${tx_cleanup_ready}" \
  OMC_TEST_WATCHDOG_TX_CLEANUP_RELEASE_FILE="${tx_cleanup_release}" \
  PATH="${MOCK_BIN}" bash "${INSTALLER}" >"${tx_cleanup_out}" 2>&1
) &
tx_cleanup_pid=$!
tx_cleanup_seen=0
for _wait in $(seq 1 2000); do
  [[ -e "${tx_cleanup_ready}" ]] \
    && { tx_cleanup_seen=1; break; }
  kill -0 "${tx_cleanup_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T24: watchdog reaches exact transaction cleanup barrier" "1" \
  "${tx_cleanup_seen}"
tx_cleanup_dir="$(head -1 "${tx_cleanup_ready}" 2>/dev/null || true)"
if [[ "${tx_cleanup_seen}" -eq 1 && -n "${tx_cleanup_dir}" ]]; then
  mkdir -p "${tx_cleanup_dir}/concurrent"
  printf 'must-survive\n' > "${tx_cleanup_dir}/concurrent/foreign"
fi
: > "${tx_cleanup_release}"
tx_cleanup_rc=0
wait "${tx_cleanup_pid}" || tx_cleanup_rc=$?
assert_eq "T24: changed transaction subtree fails exact cleanup" "1" \
  "${tx_cleanup_rc}"
assert_eq "T24: injected descendant is never swept by cleanup" \
  "must-survive" \
  "$(cat "${tx_cleanup_dir}/concurrent/foreign" 2>/dev/null || true)"
assert_contains "T24: cleanup refusal is visible" \
  "scheduler transaction scratch could not be exactly removed" \
  "$(<"${tx_cleanup_out}")"
teardown_test

# ---------------------------------------------------------------------------
# T25: binary presence is not scheduler usability. A Linux host with a
# systemctl client but no reachable user manager must install through cron,
# and the persisted scheduler kind must report what actually shipped.
# ---------------------------------------------------------------------------
echo "=== T25: unusable systemd user manager falls back to cron ==="
setup_test
mock_platform Linux
install_mock_crontab
cat > "${MOCK_BIN}/systemctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOCK_BIN}/systemctl.calls"
case "\$*" in
  *' show-environment') exit 1 ;;
  *) exit 99 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/systemctl"
unusable_systemd_rc=0
unusable_systemd_out="$(PATH="${MOCK_BIN}" bash "${INSTALLER}" 2>&1)" \
  || unusable_systemd_rc=$?
assert_eq "T25: cron fallback succeeds with systemctl binary present" "0" \
  "${unusable_systemd_rc}"
assert_contains "T25: fallback explains unusable user manager" \
  "systemctl --user is unavailable or unusable" "${unusable_systemd_out}"
assert_eq "T25: actual scheduler kind is persisted as cron" "1" \
  "$(grep -c '^resume_watchdog_scheduler=cron$' \
    "${HOME}/.claude/oh-my-claude.conf" 2>/dev/null || true)"
assert_eq "T25: cron fallback publishes one managed command" "1" \
  "$(grep -c 'resume-watchdog\.sh' "${HOME}/mock.crontab" \
    2>/dev/null || true)"
assert_eq "T25: unusable systemd path publishes no unit" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
assert_eq "T25: unusable manager is never asked to enable a timer" "0" \
  "$(grep -c 'enable --now' "${MOCK_BIN}/systemctl.calls" \
    2>/dev/null || true)"
teardown_test

# ---------------------------------------------------------------------------
# T26: HOME/CLAUDE_HOME and the effective PATH are scheduler grammar inputs.
# Control-bearing values must be rejected before locks, WALs, or artifacts.
# ---------------------------------------------------------------------------
echo "=== T26: control-bearing HOME fails before scheduler mutation ==="
setup_test
mock_platform Linux
unsafe_home="${HOME}/unsafe"$'\n''home'
unsafe_home_rc=0
unsafe_home_out="$(HOME="${unsafe_home}" PATH="${MOCK_BIN}" \
  bash "${INSTALLER}" 2>&1)" || unsafe_home_rc=$?
assert_eq "T26: newline-bearing HOME is rejected" "1" "${unsafe_home_rc}"
assert_contains "T26: HOME rejection identifies render safety" \
  "refusing unsafe scheduler render input" "${unsafe_home_out}"
assert_eq "T26: unsafe HOME tree is never created" "false" \
  "$([[ -e "${unsafe_home}" || -L "${unsafe_home}" ]] \
    && printf true || printf false)"
assert_eq "T26: original HOME receives no scheduler artifact" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T27: SIGKILL bypasses EXIT traps. The pre-mutation durable WAL must remain
# discoverable after both filesystem and crontab publication kill points, and
# every later invocation must refuse before taking a fresh snapshot.
# ---------------------------------------------------------------------------
echo "=== T27: SIGKILL residues fail closed before a new snapshot ==="
setup_test
mock_platform Linux
systemd_kill_out="${HOME}/systemd-kill.out"
OMC_TEST_WATCHDOG_KILL_POINT=after-linux-service-publish \
PATH="${MOCK_BIN}" bash "${INSTALLER}" >"${systemd_kill_out}" 2>&1 &
systemd_kill_pid=$!
systemd_kill_rc=0
wait "${systemd_kill_pid}" 2>/dev/null || systemd_kill_rc=$?
assert_eq "T27: systemd publication kill point terminates with SIGKILL" \
  "137" "${systemd_kill_rc}"
assert_eq "T27: first systemd artifact was published" "true" \
  "$([[ -f "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
assert_eq "T27: later systemd artifact was not published" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer" ]] \
    && printf true || printf false)"
assert_eq "T27: killed systemd mutation leaves one discoverable WAL" "1" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-scheduler-txn.*' -print | wc -l | tr -d '[:space:]')"
systemd_retry_rc=0
systemd_retry_out="$(PATH="${MOCK_BIN}" bash "${INSTALLER}" 2>&1)" \
  || systemd_retry_rc=$?
assert_eq "T27: next systemd invocation fails closed" "1" \
  "${systemd_retry_rc}"
assert_contains "T27: next systemd invocation reports unfinished WAL" \
  "unfinished durable resume-watchdog scheduler transaction" \
  "${systemd_retry_out}"
assert_eq "T27: refusal creates no replacement snapshot" "1" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-scheduler-txn.*' -print | wc -l | tr -d '[:space:]')"
teardown_test

setup_test
mock_platform Linux
install_mock_crontab
cat > "${MOCK_BIN}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *' show-environment') exit 1 ;;
  *) exit 99 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/systemctl"
cron_kill_out="${HOME}/cron-kill.out"
OMC_TEST_WATCHDOG_KILL_POINT=after-cron-publish \
PATH="${MOCK_BIN}" bash "${INSTALLER}" >"${cron_kill_out}" 2>&1 &
cron_kill_pid=$!
cron_kill_rc=0
wait "${cron_kill_pid}" 2>/dev/null || cron_kill_rc=$?
assert_eq "T27: cron publication kill point terminates with SIGKILL" \
  "137" "${cron_kill_rc}"
assert_eq "T27: cron mutation was published before the kill" "1" \
  "$(grep -c 'resume-watchdog\.sh' "${HOME}/mock.crontab" \
    2>/dev/null || true)"
assert_eq "T27: killed cron mutation leaves one discoverable WAL" "1" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-scheduler-txn.*' -print | wc -l | tr -d '[:space:]')"
cron_retry_rc=0
cron_retry_out="$(PATH="${MOCK_BIN}" bash "${INSTALLER}" 2>&1)" \
  || cron_retry_rc=$?
assert_eq "T27: next cron invocation fails closed" "1" "${cron_retry_rc}"
assert_contains "T27: next cron invocation reports unfinished WAL" \
  "unfinished durable resume-watchdog scheduler transaction" \
  "${cron_retry_out}"
assert_eq "T27: pre-config crash does not claim enabled state" "0" \
  "$(grep -c '^resume_watchdog=on$' \
    "${HOME}/.claude/oh-my-claude.conf" 2>/dev/null || true)"
teardown_test

setup_test
mock_platform Linux
wal_symlink_target="${HOME}/wal-symlink-target"
printf 'preserve\n' > "${wal_symlink_target}"
ln -s "${wal_symlink_target}" \
  "${HOME}/.claude/.watchdog-scheduler-txn.attacker"
wal_symlink_rc=0
PATH="${MOCK_BIN}" bash "${INSTALLER}" >/dev/null 2>&1 \
  || wal_symlink_rc=$?
assert_eq "T27: symlink-shaped WAL residue fails closed" "1" \
  "${wal_symlink_rc}"
assert_eq "T27: WAL symlink target remains untouched" "preserve" \
  "$(cat "${wal_symlink_target}")"
assert_eq "T27: WAL symlink refusal precedes scheduler publication" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
teardown_test

# ---------------------------------------------------------------------------
# T28: hosts whose only durable sync lives in an immutable Nix store must arm
# and retire the scheduler WAL normally. Use a relocated trusted-store copy so
# this remains sterile on non-Nix hosts. The sync leaf is a Nix-style symlink;
# the installer must resolve it to the ordinary store target and pin that
# target across both the begin barrier and the committed/rolled-back exit
# barrier.
# ---------------------------------------------------------------------------
echo "=== T28: Nix sync seals commit and rollback durability barriers ==="
setup_test
mock_platform Linux
prepare_relocated_nix_sync_installer
nix_commit_rc=0
PATH="${NIX_SYNC_BIN}:${MOCK_BIN}" \
  bash "${NIX_SYNC_INSTALLER}" >/dev/null 2>&1 || nix_commit_rc=$?
assert_eq "T28: Nix-only durable sync permits commit" "0" \
  "${nix_commit_rc}"
assert_eq "T28: commit runs begin and committed-exit barriers" "2" \
  "$(wc -l < "${HOME}/nix-sync.calls" | tr -d '[:space:]')"
assert_eq "T28: barriers execute the resolved immutable target" "0" \
  "$(grep -Fvc "${NIX_SYNC_TARGET}" "${HOME}/nix-sync.calls" || true)"
assert_eq "T28: committed Nix transaction retires its WAL" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-scheduler-txn.*' -print | wc -l \
    | tr -d '[:space:]')"
teardown_test

setup_test
mock_platform Linux
prepare_relocated_nix_sync_installer
cat > "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod 700 "${HOME}/.claude/quality-pack/scripts/resume-watchdog.sh"
nix_rollback_rc=0
nix_rollback_out="$(PATH="${NIX_SYNC_BIN}:${MOCK_BIN}" \
  bash "${NIX_SYNC_INSTALLER}" 2>&1)" || nix_rollback_rc=$?
assert_eq "T28: forced post-publication failure is reported" "1" \
  "${nix_rollback_rc}"
assert_contains "T28: failure reaches the scheduler rollback path" \
  "scheduler/config changes will be rolled back" "${nix_rollback_out}"
assert_eq "T28: rollback runs begin and rolled-back-exit barriers" "2" \
  "$(wc -l < "${HOME}/nix-sync.calls" | tr -d '[:space:]')"
assert_eq "T28: rollback barriers execute the resolved immutable target" "0" \
  "$(grep -Fvc "${NIX_SYNC_TARGET}" "${HOME}/nix-sync.calls" || true)"
assert_eq "T28: completed Nix rollback retires its WAL" "0" \
  "$(find "${HOME}/.claude" -maxdepth 1 \
    -name '.watchdog-scheduler-txn.*' -print | wc -l \
    | tr -d '[:space:]')"
assert_eq "T28: rollback removes the provisional systemd service" "false" \
  "$([[ -e "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" ]] \
    && printf true || printf false)"
assert_eq "T28: rollback restores the initially absent config" "false" \
  "$([[ -e "${HOME}/.claude/oh-my-claude.conf" ]] \
    && printf true || printf false)"
teardown_test

# Renderer code-shape backstops for paths containing XML/systemd/cron
# metacharacters. These assertions complement the newline-injection execution
# case above and keep all three scheduler grammars aligned.
assert_eq "renderer escapes XML ampersands" "1" \
  "$(grep -Fc "'&') printf '&amp;'" "${INSTALLER}" || true)"
assert_eq "renderer doubles systemd percent specifiers" "1" \
  "$(grep -Fc 'value="${value//%/%%}"' "${INSTALLER}" || true)"
assert_eq "renderer escapes cron percent characters" "1" \
  "$(grep -Fc 'quoted_script="${quoted_script//%/\\%}"' \
      "${INSTALLER}" || true)"
assert_eq "systemd ExecStart quotes the script path" "1" \
  "$(grep -Fc 'ExecStart=/bin/bash "__OMC_HOME__/quality-pack/scripts/resume-watchdog.sh"' \
      "${REPO_ROOT}/bundle/dot-claude/systemd/oh-my-claude-resume-watchdog.service" \
      || true)"

printf '\n=== test-install-resume-watchdog: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
