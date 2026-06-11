#!/usr/bin/env bash
#
# install-resume-watchdog.sh — opt-in installer for the Wave 3 headless
# resume watchdog.
#
# What it does:
#   1. Sets `resume_watchdog=on` in ~/.claude/oh-my-claude.conf so the
#      script-level guard passes.
#   2. Installs the platform scheduler:
#        - macOS: copy plist to ~/Library/LaunchAgents/, run
#          `launchctl bootstrap gui/$UID <path>`.
#        - Linux: copy .service + .timer to ~/.config/systemd/user/,
#          run `systemctl --user daemon-reload && systemctl --user
#          enable --now oh-my-claude-resume-watchdog.timer`.
#        - Other: installs a managed cron entry when `crontab` is
#          available; otherwise prints the exact line to add manually.
#   3. Verifies the watchdog can run (single tick, dry).
#   4. Prints the activation instructions and how to monitor / disable.
#
# Idempotent: re-running this script updates the installed plist /
# unit / cron entry in place. Does not duplicate.
#
# Uninstall: `bash $HOME/.claude/install-resume-watchdog.sh --uninstall`
# disables the scheduler and removes the installed files. The conf
# flag is left at `resume_watchdog=on` so a re-install picks up the
# user's stated preference; pass `--reset-conf` to also flip it off.
#
# Reregister (self-heal): `--reregister` re-establishes the schedule
# QUIETLY for an already-installed watchdog whose agent died in the
# field (laptop sleep, `launchctl bootout`, macOS update). It re-
# bootstraps the launchd plist / restarts the systemd unit / reports
# cron-fires-on-schedule, WITHOUT the explicit claiming `kickstart -k`
# and WITHOUT the conf/claude_bin writes or the activation banner. It
# is the recovery path the SessionStart watchdog-health hook invokes.
# SAFETY: it REFUSES (exit 3) when any claimable resume_request.json
# exists, because re-bootstrap fires a RunAtLoad tick that would claim
# it and spawn an orphan `claude --resume`. Resolve the artifact via
# /ulw-resume first.

set -euo pipefail

CLAUDE_HOME="${HOME}/.claude"
CONF_FILE="${CLAUDE_HOME}/oh-my-claude.conf"
WATCHDOG_SCRIPT="${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
LOG_DIR="${CLAUDE_HOME}/quality-pack/state/.watchdog-logs"
CRON_MARKER="# oh-my-claude resume-watchdog"

mode="install"
reset_conf=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --uninstall) mode="uninstall"; shift ;;
    --reregister) mode="reregister"; shift ;;
    --reset-conf) reset_conf=1; shift ;;
    -h|--help)
      sed -n '2,55p' "$0"
      exit 0 ;;
    *)
      printf 'install-resume-watchdog: unknown arg: %s\n' "$1" >&2
      exit 64 ;;
  esac
done

require_file() {
  if [[ ! -f "$1" ]]; then
    printf 'ERROR: missing %s — run install.sh first.\n' "$1" >&2
    exit 1
  fi
}

set_conf_value() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "${CONF_FILE}")"
  if [[ -f "${CONF_FILE}" ]]; then
    # Drop existing key if present, then append. Mirrors install.sh's
    # set_conf semantics.
    local tmp="${CONF_FILE}.tmp.$$"
    grep -v -E "^${key}=" "${CONF_FILE}" > "${tmp}" 2>/dev/null || true
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    mv -f "${tmp}" "${CONF_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" > "${CONF_FILE}"
  fi
}

platform() {
  case "$(uname 2>/dev/null || echo "")" in
    Darwin) printf 'macos' ;;
    Linux)  printf 'linux' ;;
    *)      printf 'other' ;;
  esac
}

# Resolve the user's effective PATH so `claude` and `tmux` are found
# under launchd / systemd-user, which otherwise inherit a barebones
# PATH. Probe the user's login shell when available; fall back to the
# current $PATH; further fall back to a safe default that covers
# Homebrew + system bins. Required because Claude Code's binary may
# live at ~/.local/bin/claude (npm global) or ~/.nvm/versions/.../bin
# (nvm) — neither is on launchd's default PATH.
#
# The login-shell probe is wrapped in `timeout 5` when available so a
# misconfigured rc file (network-fetch on shell init, asdf-plugin
# refresh, slow brew shellenv, etc.) cannot hang the watchdog
# installer indefinitely. On systems without `timeout` the bare probe
# runs and the user can Ctrl-C if it stalls.
resolved_path() {
  local from_shell="" result=""
  if [[ -n "${SHELL:-}" ]] && [[ -x "${SHELL}" ]]; then
    if command -v timeout >/dev/null 2>&1; then
      from_shell="$(timeout 5 "${SHELL}" -ilc 'printf %s "${PATH}"' 2>/dev/null || true)"
    else
      from_shell="$("${SHELL}" -ilc 'printf %s "${PATH}"' 2>/dev/null || true)"
    fi
  fi
  if [[ -n "${from_shell}" ]]; then
    result="${from_shell}"
  elif [[ -n "${PATH:-}" ]]; then
    result="${PATH}"
  else
    result='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
  fi
  # security-lens P2: this value is sed-substituted into the launchd
  # <string> / systemd Environment= line. A newline or CR in $PATH (from a
  # hostile login-shell rc) would terminate that value and inject arbitrary
  # additional plist keys / unit directives. A PATH legitimately never
  # contains line breaks, so strip them before the value leaves this
  # function (single source for both the macOS and Linux install paths).
  result="${result//$'\n'/}"
  result="${result//$'\r'/}"
  printf '%s' "${result}"
}

render_cron_line() {
  local quoted_script=""
  printf -v quoted_script '%q' "${WATCHDOG_SCRIPT}"
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${quoted_script}"
}

read_crontab_contents() {
  if ! command -v crontab >/dev/null 2>&1; then
    return 127
  fi

  local current=""
  local rc=0
  set +e
  current="$(crontab -l 2>/dev/null)"
  rc=$?
  set -e

  case "${rc}" in
    0)
      printf '%s' "${current}"
      return 0
      ;;
    1)
      return 0
      ;;
    *)
      return "${rc}"
      ;;
  esac
}

strip_managed_cron_entries() {
  local current="${1:-}"
  printf '%s\n' "${current}" | awk -v marker="${CRON_MARKER}" '
    $0 == marker { next }
    /resume-watchdog\.sh/ { next }
    { print }
  '
}

write_crontab_contents() {
  local next_contents="${1:-}"
  printf '%s\n' "${next_contents}" | crontab -
}

cron_install_block() {
  local current="${1:-}"
  local stripped=""
  local cron_line=""

  stripped="$(strip_managed_cron_entries "${current}")"
  cron_line="$(render_cron_line)"

  if [[ -n "${stripped}" ]]; then
    printf '%s\n%s\n%s\n' "${stripped}" "${CRON_MARKER}" "${cron_line}"
  else
    printf '%s\n%s\n' "${CRON_MARKER}" "${cron_line}"
  fi
}

# --- macOS LaunchAgent ---

macos_install() {
  local src="${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
  require_file "${src}"
  local dest_dir="${HOME}/Library/LaunchAgents"
  local dest="${dest_dir}/dev.ohmyclaude.resume-watchdog.plist"
  mkdir -p "${dest_dir}" "${LOG_DIR}"

  local user_path
  user_path="$(resolved_path)"

  # Escape `&` and `|` for sed (PATH may contain neither, but defense).
  local user_path_esc
  user_path_esc="${user_path//&/\\&}"
  user_path_esc="${user_path_esc//|/\\|}"

  # Substitute placeholders.
  sed \
    -e "s|__OMC_HOME__|${CLAUDE_HOME}|g" \
    -e "s|__OMC_USER_HOME__|${HOME}|g" \
    -e "s|__OMC_LOG_DIR__|${LOG_DIR}|g" \
    -e "s|__OMC_PATH__|${user_path_esc}|g" \
    "${src}" > "${dest}"

  # Bootstrap into the user's gui domain. If already loaded, kickstart
  # to apply changes (idempotent — safe to re-run).
  if launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null || true
  fi
  launchctl bootstrap "gui/$(id -u)" "${dest}" 2>/dev/null || {
    printf 'WARNING: launchctl bootstrap failed — load manually with:\n  launchctl bootstrap gui/%s %s\n' "$(id -u)" "${dest}"
    return 1
  }
  launchctl kickstart -k "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null || true
  printf 'macOS LaunchAgent installed at %s\n' "${dest}"
  printf 'Tail logs: tail -f %s/resume-watchdog.log\n' "${LOG_DIR}"
}

macos_uninstall() {
  local dest="${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
  if launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null || true
  fi
  rm -f "${dest}"
  printf 'macOS LaunchAgent removed.\n'
}

# --- Linux systemd user timer ---

linux_install() {
  local src_svc="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service"
  local src_tmr="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer"
  require_file "${src_svc}"
  require_file "${src_tmr}"

  local dest_dir="${HOME}/.config/systemd/user"
  mkdir -p "${dest_dir}"

  local user_path user_path_esc
  user_path="$(resolved_path)"
  user_path_esc="${user_path//&/\\&}"
  user_path_esc="${user_path_esc//|/\\|}"

  sed -e "s|__OMC_HOME__|${CLAUDE_HOME}|g" \
      -e "s|__OMC_USER_HOME__|${HOME}|g" \
      -e "s|__OMC_PATH__|${user_path_esc}|g" \
    "${src_svc}" > "${dest_dir}/oh-my-claude-resume-watchdog.service"
  sed -e "s|__OMC_HOME__|${CLAUDE_HOME}|g" \
      -e "s|__OMC_USER_HOME__|${HOME}|g" \
      -e "s|__OMC_PATH__|${user_path_esc}|g" \
    "${src_tmr}" > "${dest_dir}/oh-my-claude-resume-watchdog.timer"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now oh-my-claude-resume-watchdog.timer 2>/dev/null || {
      printf 'WARNING: systemctl --user enable failed — try manually:\n  systemctl --user daemon-reload\n  systemctl --user enable --now oh-my-claude-resume-watchdog.timer\n'
      return 1
    }
    printf 'Linux systemd user-timer installed at %s/\n' "${dest_dir}"
    printf 'Status: systemctl --user status oh-my-claude-resume-watchdog.timer\n'
    printf 'Logs:   journalctl --user -u oh-my-claude-resume-watchdog.service -f\n'
  else
    printf 'systemctl not found — falling back to cron.\n'
    cron_install
  fi
}

linux_uninstall() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now oh-my-claude-resume-watchdog.timer 2>/dev/null || true
  fi
  rm -f "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service" \
        "${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  printf 'Linux systemd user-timer removed.\n'
}

# --- cron fallback ---

cron_install() {
  local line=""
  local current=""
  local next_contents=""

  line="$(render_cron_line)"
  mkdir -p "${LOG_DIR}"

  if ! command -v crontab >/dev/null 2>&1; then
    printf 'Cron fallback selected, but `crontab` is not available.\n'
    printf 'Add this line manually:\n  %s\n\n' "${line}"
    printf 'Once `crontab` is available, re-run this installer to register it automatically.\n'
    return 0
  fi

  if ! current="$(read_crontab_contents)"; then
    printf 'WARNING: could not read current crontab — add this line manually:\n  %s\n' "${line}"
    return 1
  fi

  next_contents="$(cron_install_block "${current}")"
  if ! write_crontab_contents "${next_contents}"; then
    printf 'WARNING: could not install the watchdog cron entry automatically.\n'
    printf 'Add this line manually:\n  %s\n' "${line}"
    return 1
  fi

  printf 'Cron watchdog entry installed via crontab.\n'
  printf 'Inspect with: crontab -l\n'
}

cron_uninstall() {
  local current=""
  local next_contents=""

  if ! command -v crontab >/dev/null 2>&1; then
    printf 'Manual uninstall: remove the crontab line that runs resume-watchdog.sh.\n'
    return 0
  fi

  if ! current="$(read_crontab_contents)"; then
    printf 'WARNING: could not read current crontab — remove the watchdog entry manually.\n'
    return 1
  fi

  next_contents="$(strip_managed_cron_entries "${current}")"
  if ! write_crontab_contents "${next_contents}"; then
    printf 'WARNING: could not remove the watchdog cron entry automatically.\n'
    return 1
  fi

  printf 'Cron watchdog entry removed.\n'
}

# --- reregister (self-heal) ---
#
# The SessionStart watchdog-health hook calls these when a stale watchdog
# needs reviving. They MUST stay quiet (hook-friendly: minimal stdout, no
# prompts) and MUST NOT issue the explicit claiming `launchctl kickstart -k`
# that the install path uses — re-bootstrap already triggers a RunAtLoad
# tick, and that single guarded tick is enough to refresh the heartbeat.
# The orphan-prevention guard (reregister_is_safe) runs FIRST so the
# RunAtLoad tick can never find a claimable artifact to spawn against.

# reregister_is_safe — orphan-prevention backstop.
#
# Returns 0 ONLY when it is provably safe to re-bootstrap: the claimable-
# artifact scan succeeded AND found nothing. Returns 1 (unsafe) when a
# claimable resume_request.json exists OR the scan could not be run /
# trusted. Fail-CLOSED: any uncertainty blocks the re-register, because a
# RunAtLoad tick firing against an unknown claim state is exactly the
# orphan-spawn foot-gun this guard exists to prevent
# (project_watchdog_reregister_claims_artifacts.md).
reregister_is_safe() {
  local common="${CLAUDE_HOME}/skills/autowork/scripts/common.sh"
  if [[ ! -f "${common}" ]]; then
    # Cannot load the canonical claimability helper — refuse rather than
    # guess. The hook degrades to its warning.
    return 1
  fi
  # Scope the source to this subshell so the installer's other modes are
  # unaffected by common.sh's globals/side effects. Guard the substitution
  # with `|| rc=$?` so `set -e` does not abort on a non-zero subshell exit
  # (we want to inspect rc and fail-CLOSED, not crash).
  local claimable="" rc=0
  claimable="$(
    # shellcheck source=/dev/null
    . "${common}" 2>/dev/null || exit 99
    find_claimable_resume_requests 2>/dev/null || exit 98
  )" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    # Helper unavailable or errored — treat as unsafe.
    return 1
  fi
  if [[ -n "${claimable}" ]]; then
    # A claimable artifact exists — re-bootstrapping would claim it.
    return 1
  fi
  return 0
}

macos_reregister() {
  local src="${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
  require_file "${src}"
  local dest_dir="${HOME}/Library/LaunchAgents"
  local dest="${dest_dir}/dev.ohmyclaude.resume-watchdog.plist"
  mkdir -p "${dest_dir}" "${LOG_DIR}"

  local user_path user_path_esc
  user_path="$(resolved_path)"
  user_path_esc="${user_path//&/\\&}"
  user_path_esc="${user_path_esc//|/\\|}"

  # Re-render the plist — this alone heals plist-signature drift, one of
  # the documented silent-death causes.
  sed \
    -e "s|__OMC_HOME__|${CLAUDE_HOME}|g" \
    -e "s|__OMC_USER_HOME__|${HOME}|g" \
    -e "s|__OMC_LOG_DIR__|${LOG_DIR}|g" \
    -e "s|__OMC_PATH__|${user_path_esc}|g" \
    "${src}" > "${dest}"

  if ! command -v launchctl >/dev/null 2>&1; then
    return 1
  fi
  # Bootout-if-loaded, then bootstrap. The bootstrap triggers the plist's
  # RunAtLoad tick (guarded safe by reregister_is_safe). NO explicit
  # `kickstart -k` — it only widens the claim window for no benefit here.
  if launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null || true
  fi
  launchctl bootstrap "gui/$(id -u)" "${dest}" 2>/dev/null || return 1
  return 0
}

linux_reregister() {
  if ! command -v systemctl >/dev/null 2>&1; then
    # No systemd — the cron entry (if present) fires on its own schedule;
    # nothing to restart. Treat as cron.
    cron_reregister
    return $?
  fi
  local dest_dir="${HOME}/.config/systemd/user"
  local svc="${dest_dir}/oh-my-claude-resume-watchdog.service"
  local tmr="${dest_dir}/oh-my-claude-resume-watchdog.timer"
  # If the units were never installed, there is nothing to reregister via
  # systemd — fall back to cron semantics.
  if [[ ! -f "${svc}" ]] || [[ ! -f "${tmr}" ]]; then
    cron_reregister
    return $?
  fi
  systemctl --user daemon-reload 2>/dev/null || true
  # `enable --now` re-establishes the timer if it was disabled/stopped and
  # starts it immediately; idempotent if already active. The .timer's
  # Persistent=true catch-up tick is the systemd analogue of RunAtLoad and
  # is guarded safe by reregister_is_safe.
  systemctl --user enable --now oh-my-claude-resume-watchdog.timer 2>/dev/null || return 1
  return 0
}

cron_reregister() {
  # Cron fires on its own schedule — a "stale" cron watchdog means the
  # crontab entry is gone, not that a loaded agent died. If the managed
  # entry is missing, re-install it; otherwise report nothing-to-do. No
  # claiming tick is triggered either way (the next */2 fire is a normal
  # guarded tick).
  if ! command -v crontab >/dev/null 2>&1; then
    printf 'cron: crontab unavailable; cannot reregister automatically\n'
    return 1
  fi
  local current=""
  if ! current="$(read_crontab_contents)"; then
    return 1
  fi
  if printf '%s\n' "${current}" | grep -q 'resume-watchdog\.sh'; then
    printf 'cron: managed entry present; fires on schedule (nothing to restart)\n'
    return 0
  fi
  local next_contents=""
  next_contents="$(cron_install_block "${current}")"
  if ! write_crontab_contents "${next_contents}"; then
    return 1
  fi
  printf 'cron: managed entry restored\n'
  return 0
}

# --- main ---

require_file "${WATCHDOG_SCRIPT}"

if [[ "${mode}" == "uninstall" ]]; then
  case "$(platform)" in
    macos) macos_uninstall ;;
    linux)
      if command -v systemctl >/dev/null 2>&1; then
        linux_uninstall
      else
        cron_uninstall
      fi
      ;;
    other) cron_uninstall ;;
  esac
  if [[ "${reset_conf}" -eq 1 ]]; then
    set_conf_value "resume_watchdog" "off"
    printf 'Set resume_watchdog=off in %s\n' "${CONF_FILE}"
  fi
  exit 0
fi

if [[ "${mode}" == "reregister" ]]; then
  # Quiet self-heal path (invoked by session-start-watchdog-health.sh).
  # Does NOT touch the conf flag or claude_bin pin and does NOT print the
  # activation banner — the caller (a SessionStart hook) composes the
  # user-facing message from the exit code and minimal stdout.
  #
  # Exit codes:
  #   0  reregistered (or cron nothing-to-restart) — heartbeat will refresh
  #   3  REFUSED: a claimable resume_request.json exists (orphan risk)
  #   1  reregister attempted but the platform command failed
  if ! reregister_is_safe; then
    printf 'reregister: refused — a claimable resume artifact exists (handle via /ulw-resume first)\n' >&2
    exit 3
  fi
  # Capture the platform handler's status without `set -e` aborting on a
  # non-zero return (a failed restart is exit 1, surfaced to the hook).
  rr_rc=0
  case "$(platform)" in
    macos) macos_reregister || rr_rc=$? ;;
    linux) linux_reregister || rr_rc=$? ;;
    other) cron_reregister || rr_rc=$? ;;
  esac
  exit "${rr_rc}"
fi

# Install path.
set_conf_value "resume_watchdog" "on"
printf 'Set resume_watchdog=on in %s\n' "${CONF_FILE}"

# v1.31.0 Wave 1: pin the absolute path to `claude` so the daemon
# launches the user's chosen Claude Code binary, defeating the
# security-lens F-5 PATH-hijack threat where an attacker drops
# ~/.local/bin/claude ahead of the real binary in launchd's PATH.
# The pin is host-specific (do not sync ~/.claude across machines if
# the binary lives at different paths). When `command -v claude`
# returns nothing at install time (npx-only users with no stable
# path), the pin is left empty — the watchdog's live `command -v`
# at launch time is the unchanged legacy fallback.
claude_path="$(command -v claude 2>/dev/null || true)"
if [[ -n "${claude_path}" ]] && [[ "${claude_path}" =~ ^/ ]]; then
  set_conf_value "claude_bin" "${claude_path}"
  printf 'Pinned claude_bin=%s in %s (PATH-hijack defense)\n' "${claude_path}" "${CONF_FILE}"
else
  printf 'NOTE: `claude` not on PATH; skipping claude_bin pin.\n'
  printf '      Watchdog will fall back to live `command -v claude` at launch.\n'
  printf '      Set claude_bin=<absolute path> manually in %s if PATH resolution at\n' "${CONF_FILE}"
  printf '      launch time is unreliable on this host.\n'
fi

case "$(platform)" in
  macos) macos_install ;;
  linux) linux_install ;;
  other) cron_install ;;
esac

# Self-test: verify the watchdog can source common.sh, pass its guards
# (conf-flag / capture-flag / claim-helper-present), and exit cleanly —
# WITHOUT claiming any artifact or launching `claude --resume` in tmux.
# OMC_WATCHDOG_SELF_TEST=1 short-circuits the main loop in
# resume-watchdog.sh immediately after the guard layer. Real launchd /
# systemd / cron ticks never set this env, so they execute the full
# claim/launch path.
#
# This used to be `bash "${WATCHDOG_SCRIPT}"` — a label-as-dry-run that
# actually ran the live tick. With any claimable `resume_request.json` on
# disk, every install re-run silently spawned a detached tmux session
# running `claude --resume <objective>`, accumulating orphan agents that
# could commit and push work without the user realizing. Closed by the
# v1.41.x post-install audit (4 artifacts spent / 4 install runs).
if OMC_WATCHDOG_SELF_TEST=1 bash "${WATCHDOG_SCRIPT}" >/dev/null 2>&1; then
  printf '\nWatchdog self-test: OK\n'
else
  printf '\nWARNING: watchdog self-test returned non-zero. Inspect the script manually:\n  OMC_WATCHDOG_SELF_TEST=1 bash %s\n' "${WATCHDOG_SCRIPT}"
fi

cat <<EOM

Activation summary
==================
- Conf flag: resume_watchdog=on (in ${CONF_FILE})
- Script:    ${WATCHDOG_SCRIPT}
- Schedule:  every 2 minutes via the platform scheduler

How it works
------------
When the watchdog fires it walks ~/.claude/quality-pack/state/*/resume_request.json,
finds artifacts whose rate-limit window cleared, and (if tmux + claude
are on PATH) launches \`claude --resume <session_id> '<prompt>'\` in a
detached tmux session named \`omc-resume-<session-id>\`. Attach with:
  tmux attach -t omc-resume-<sid>

If tmux is not available the watchdog falls back to an OS notification
(macOS osascript / Linux notify-send) and does NOT auto-launch — you
get a desktop alert telling you to invoke /ulw-resume manually.

Privacy
-------
- The watchdog respects \`stop_failure_capture=off\`. If you opted out
  of the producer side, the watchdog has nothing to do.
- No data leaves your machine. Verbatim user prompts live in
  resume_request.json on local disk only.

Disable
-------
- Mid-session pause:  stop using \`/ulw\`.
- Dismiss one resume: \`/ulw-resume --dismiss\`.
- Disable globally:   bash ${0} --uninstall [--reset-conf]
EOM
