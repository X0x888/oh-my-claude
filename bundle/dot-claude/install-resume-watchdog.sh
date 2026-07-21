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
OPERATION_LOCK_DIR="${CLAUDE_HOME}/.install.lock"
OPERATION_LOCK_HELD=0
OPERATION_LOCK_BORROWED=0
OPERATION_LOCK_TOKEN=""
OPERATION_LOCK_AUTH_PID=""
OPERATION_LOCK_AUTH_TOKEN=""
OPERATION_LOCK_DIR_ID=""
OPERATION_LOCK_PARTICIPANT_PATH=""
OPERATION_LOCK_PARTICIPANT_TOKEN=""
OPERATION_LOCK_PARTICIPANT_ID=""
OPERATION_LOCK_RELEASE_MARKER="${OPERATION_LOCK_DIR}/owner-released"
SCHEDULER_LOCK_DIR="${CLAUDE_HOME}/.resume-watchdog-scheduler.lock"
SCHEDULER_LOCK_HELD=0
SCHEDULER_LOCK_TOKEN=""
SCHEDULER_LOCK_DIR_ID=""
SCHEDULER_TX_DIR=""
SCHEDULER_TX_DIR_ID=""
SCHEDULER_TX_PARENT_ID=""
SCHEDULER_TX_ARMED=0
SCHEDULER_TX_COMMITTED=0
SCHEDULER_DURABLE_SYNC_TOOL=""
SCHEDULER_DURABLE_SYNC_TOOL_ID=""
SCHEDULER_DURABLE_SYNC_TOOL_OWNER=""
SCHEDULER_DURABLE_SYNC_TOOL_DOMAIN=""
LINUX_INSTALLED_SCHEDULER=""
CONF_WAS_PRESENT=0
CRON_SNAPSHOT_KNOWN=0
CRON_SNAPSHOT=""
CRON_LAST_PUBLISHED=""
CRON_PUBLISHED=0
MACOS_DEST="${HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
LINUX_SERVICE_DEST="${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
LINUX_TIMER_DEST="${HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
MACOS_WAS_LOADED=0
LINUX_WAS_ENABLED=0
LINUX_WAS_ACTIVE=0
MACOS_RUNTIME_EXPECTATION=""
LINUX_RUNTIME_EXPECTATION=""
RECOVERY_HELPER_DIR=""
RECOVERY_HELPER_DIR_ID=""
RECOVERY_SWITCH_SOURCE_ID=""
RECOVERY_SWITCH_SOURCE_HASH=""
RECOVERY_SWITCH_COPY_ID=""
RECOVERY_SWITCH_COPY_HASH=""
RECOVERY_OMC_SOURCE_ID=""
RECOVERY_OMC_SOURCE_HASH=""
RECOVERY_OMC_COPY_ID=""
RECOVERY_OMC_COPY_HASH=""
RECOVERY_MANIFEST_ID=""
RECOVERY_MANIFEST_HASH=""
RECOVERY_SHA_TOOL=""
RECOVERY_SHA_TOOL_ID=""
RECOVERY_BASH_TOOL=""
RECOVERY_BASH_TOOL_ID=""
RECOVERY_NEEDS_SWITCH=0
RECOVERY_NEEDS_OMC=0

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

watchdog_test_barrier() {
  local ready="${1:-}" release="${2:-}" payload="${3:-ready}" attempt=0
  [[ "${OMC_TEST_WATCHDOG_BARRIER_ENABLE:-0}" == "1" ]] || return 0
  [[ -z "${ready}" && -z "${release}" ]] && return 0
  [[ "${ready}" == /* && "${release}" == /* ]] || return 1
  printf '%s\n' "${payload}" > "${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 6000 ]] || return 1
    sleep 0.01
  done
}

watchdog_test_killpoint() {
  local point="${1:-}"
  [[ -n "${point}" ]] || return 1
  [[ "${OMC_TEST_WATCHDOG_KILL_POINT:-}" == "${point}" ]] || return 0
  # Test-only deterministic crash seam. SIGKILL deliberately bypasses every
  # trap so the next invocation must discover the durable transaction.
  kill -KILL "$$"
  return 137
}

scheduler_render_value_is_safe() {
  local value="${1-}"
  [[ -n "${value}" && "${value}" != *[[:cntrl:]]* ]]
}

scheduler_static_render_inputs_are_safe() {
  local value=""
  [[ "${HOME}" == /* ]] || return 1
  for value in "${HOME}" "${CLAUDE_HOME}" "${WATCHDOG_SCRIPT}" \
      "${LOG_DIR}" "${MACOS_DEST}" "${LINUX_SERVICE_DEST}" \
      "${LINUX_TIMER_DEST}"; do
    scheduler_render_value_is_safe "${value}" || return 1
  done
}

validate_scheduler_render_inputs() {
  local effective_path=""
  scheduler_static_render_inputs_are_safe || return 1
  effective_path="$(resolved_path)" || return 1
  scheduler_render_value_is_safe "${effective_path}"
}

assert_no_unsettled_scheduler_transaction() (
  local candidate="" found=0
  local -a candidates=()
  shopt -s nullglob
  candidates=("${CLAUDE_HOME}"/.watchdog-scheduler-txn.* \
    "${CLAUDE_HOME}/.watchdog-scheduler-transaction")
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    if [[ -e "${candidate}" || -L "${candidate}" ]]; then
      found=1
      break
    fi
  done
  if [[ "${found}" -eq 1 ]]; then
    printf 'ERROR: an unfinished durable resume-watchdog scheduler transaction exists; refusing a new snapshot. Inspect and recover the exact .watchdog-scheduler-txn.* generation before retrying.\n' >&2
    return 1
  fi
)

# Authority files are deliberately tiny text records. Validate their complete
# raw byte stream before exposing a value to Bash: NUL/CR, a non-final or extra
# newline, an empty row, and any reconstruction mismatch all fail closed.
watchdog_metadata_file_is_canonical() {
  local path="${1:-}" max_bytes="${2:-1048576}"
  local byte_count="" newline_count="" record=""
  [[ -f "${path}" && ! -L "${path}" \
      && "${max_bytes}" =~ ^[1-9][0-9]{0,7}$ ]] || return 1
  byte_count="$(LC_ALL=C wc -c < "${path}" 2>/dev/null)" || return 1
  byte_count="${byte_count//[[:space:]]/}"
  [[ "${byte_count}" =~ ^[0-9]{1,8}$ ]] || return 1
  (( 10#${byte_count} >= 2 && 10#${byte_count} <= 10#${max_bytes} )) \
    || return 1
  LC_ALL=C tr -d '\000\r' < "${path}" \
    | cmp -s - "${path}" 2>/dev/null || return 1
  newline_count="$(LC_ALL=C tr -cd '\n' < "${path}" \
    | LC_ALL=C wc -c 2>/dev/null)" || return 1
  newline_count="${newline_count//[[:space:]]/}"
  [[ "${newline_count}" =~ ^[1-9][0-9]{0,7}$ ]] || return 1
  LC_ALL=C tail -c 1 "${path}" 2>/dev/null \
    | cmp -s - <(printf '\n') 2>/dev/null || return 1
  {
    while IFS= read -r record; do
      [[ -n "${record}" ]] || exit 1
      printf '%s\n' "${record}"
    done < "${path}"
  } | cmp -s - "${path}" 2>/dev/null
}

watchdog_read_canonical_metadata_snapshot() {
  local path="${1:-}" max_bytes="${2:-1048576}" snapshot=""
  watchdog_metadata_file_is_canonical "${path}" "${max_bytes}" || return 1
  snapshot="$(< "${path}")" 2>/dev/null || return 1
  [[ -n "${snapshot}" ]] || return 1
  printf '%s\n' "${snapshot}" | cmp -s - "${path}" 2>/dev/null || return 1
  printf '%s' "${snapshot}"
}

watchdog_read_canonical_metadata_line() {
  local path="${1:-}" max_bytes="${2:-4096}" record=""
  record="$(watchdog_read_canonical_metadata_snapshot \
    "${path}" "${max_bytes}")" || return 1
  [[ -n "${record}" && "${record}" != *$'\n'* ]] || return 1
  printf '%s' "${record}"
}

operation_lock_release_marker_matches() {
  local marker_path="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" line=""
  [[ -n "${marker_path}" && -n "${lock_id}" && -n "${owner_pid}" \
      && -n "${owner_token}" && -f "${marker_path}" \
      && ! -L "${marker_path}" \
      && "$(watchdog_file_mode "${marker_path}" 2>/dev/null || true)" \
        == "600" ]] || return 1
  line="$(watchdog_read_canonical_metadata_line "${marker_path}" 1024)" \
    || return 1
  [[ "${line}" == $'v1\t'"${lock_id}"$'\t'"${owner_pid}"$'\t'"${owner_token}" ]]
}

operation_lock_generation_matches() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  [[ "${lock_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${owner_pid}" =~ ^[1-9][0-9]{0,19}$ \
      && -n "${owner_token}" && "${owner_token}" != *[[:cntrl:]]* \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && "$(watchdog_node_identity "${OPERATION_LOCK_DIR}" \
        2>/dev/null || true)" == "${lock_id}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${owner_pid}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${owner_token}" ]]
}

publish_operation_lock_release_marker() {
  operation_lock_generation_matches "${OPERATION_LOCK_DIR_ID}" "$$" \
    "${OPERATION_LOCK_TOKEN}" || return 1
  if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]]; then
    operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
      "${OPERATION_LOCK_DIR_ID}" "$$" "${OPERATION_LOCK_TOKEN}"
    return
  fi
  if ! (umask 077; set -o noclobber; printf 'v1\t%s\t%s\t%s\n' \
      "${OPERATION_LOCK_DIR_ID}" "$$" "${OPERATION_LOCK_TOKEN}" \
      > "${OPERATION_LOCK_RELEASE_MARKER}") 2>/dev/null; then
    return 1
  fi
  chmod 600 "${OPERATION_LOCK_RELEASE_MARKER}" || return 1
  operation_lock_generation_matches "${OPERATION_LOCK_DIR_ID}" "$$" \
    "${OPERATION_LOCK_TOKEN}" \
    && operation_lock_release_marker_matches \
      "${OPERATION_LOCK_RELEASE_MARKER}" "${OPERATION_LOCK_DIR_ID}" \
      "$$" "${OPERATION_LOCK_TOKEN}"
}

released_operation_lock_is_exact() (
  local root="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" pid_id="${5:-}" token_id="${6:-}"
  local marker_id="${7:-}" entry=""
  local -a entries=()
  [[ -d "${root}" && ! -L "${root}" \
      && "$(watchdog_node_identity "${root}" 2>/dev/null || true)" \
        == "${lock_id}" ]] || return 1
  shopt -s nullglob dotglob
  entries=("${root}"/*)
  [[ "${#entries[@]}" -eq 3 ]] || return 1
  for entry in "${entries[@]}"; do
    case "${entry}" in
      "${root}/pid"|"${root}/token"|"${root}/owner-released") ;;
      *) return 1 ;;
    esac
  done
  [[ -f "${root}/pid" && ! -L "${root}/pid" \
      && "$(watchdog_node_identity "${root}/pid" \
        2>/dev/null || true)" == "${pid_id}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${root}/pid" 32 2>/dev/null || true)" == "${owner_pid}" \
      && -f "${root}/token" && ! -L "${root}/token" \
      && "$(watchdog_node_identity "${root}/token" \
        2>/dev/null || true)" == "${token_id}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${root}/token" 512 2>/dev/null || true)" == "${owner_token}" \
      && -f "${root}/owner-released" \
      && ! -L "${root}/owner-released" \
      && "$(watchdog_node_identity "${root}/owner-released" \
        2>/dev/null || true)" == "${marker_id}" ]] || return 1
  operation_lock_release_marker_matches "${root}/owner-released" \
    "${lock_id}" "${owner_pid}" "${owner_token}"
)

reap_released_operation_lock() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  local participant="" pid_id="" token_id="" marker_id=""
  local retired_root="" retired_root_id="" retired_lock=""
  [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]] || return 0
  operation_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  for participant in "${OPERATION_LOCK_DIR}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 0
  done
  pid_id="$(watchdog_node_identity "${OPERATION_LOCK_DIR}/pid")" \
    || return 1
  token_id="$(watchdog_node_identity "${OPERATION_LOCK_DIR}/token")" \
    || return 1
  marker_id="$(watchdog_node_identity "${OPERATION_LOCK_RELEASE_MARKER}")" \
    || return 1
  released_operation_lock_is_exact "${OPERATION_LOCK_DIR}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" "${pid_id}" "${token_id}" \
    "${marker_id}" || return 1
  retired_root="$(mktemp -d \
    "${CLAUDE_HOME}/.install-lock-retired.XXXXXX")" || return 1
  if ! chmod 700 "${retired_root}"; then
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  retired_root_id="$(watchdog_node_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  if ! released_operation_lock_is_exact "${OPERATION_LOCK_DIR}" \
      "${lock_id}" "${owner_pid}" "${owner_token}" "${pid_id}" \
      "${token_id}" "${marker_id}"; then
    [[ "$(watchdog_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  if ! command mv -- "${OPERATION_LOCK_DIR}" "${retired_lock}"; then
    [[ "$(watchdog_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  watchdog_test_barrier \
    "${OMC_TEST_WATCHDOG_LOCK_RETIRED_READY_FILE:-}" \
    "${OMC_TEST_WATCHDOG_LOCK_RETIRED_RELEASE_FILE:-}" \
    "${retired_lock}" || return 1
  # A contender may create the next public generation immediately after the
  # rename. Cleanup is bound only to the retired inode from here onward.
  [[ "$(watchdog_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  released_operation_lock_is_exact "${retired_lock}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" "${pid_id}" "${token_id}" \
    "${marker_id}" || return 1
  [[ "$(watchdog_node_identity "${retired_lock}/pid" \
      2>/dev/null || true)" == "${pid_id}" ]] \
    && rm -f -- "${retired_lock}/pid" || return 1
  [[ "$(watchdog_node_identity "${retired_lock}/token" \
      2>/dev/null || true)" == "${token_id}" ]] \
    && rm -f -- "${retired_lock}/token" || return 1
  [[ "$(watchdog_node_identity "${retired_lock}/owner-released" \
      2>/dev/null || true)" == "${marker_id}" ]] \
    && operation_lock_release_marker_matches \
      "${retired_lock}/owner-released" "${lock_id}" \
      "${owner_pid}" "${owner_token}" \
    && rm -f -- "${retired_lock}/owner-released" || return 1
  rmdir "${retired_lock}" || return 1
  [[ "$(watchdog_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  rmdir "${retired_root}"
}

reap_stranded_released_operation_lock() {
  local lock_id="" owner_pid="" owner_token="" source_id=""
  [[ -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && -f "${OPERATION_LOCK_RELEASE_MARKER}" \
      && ! -L "${OPERATION_LOCK_RELEASE_MARKER}" ]] || return 1
  lock_id="$(watchdog_node_identity "${OPERATION_LOCK_DIR}")" || return 1
  owner_pid="$(watchdog_read_canonical_metadata_line \
    "${OPERATION_LOCK_DIR}/pid" 32)" || return 1
  owner_token="$(watchdog_read_canonical_metadata_line \
    "${OPERATION_LOCK_DIR}/token" 512)" || return 1
  operation_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  reap_released_operation_lock "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  source_id="$(watchdog_node_identity "${OPERATION_LOCK_DIR}" \
    2>/dev/null || true)"
  [[ "${source_id}" != "${lock_id}" ]]
}

remove_exact_operation_lock_participant() {
  [[ -n "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && -n "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && -f "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && ! -L "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && "$(watchdog_node_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true)" == "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_PARTICIPANT_PATH}" 512 2>/dev/null || true)" \
        == "${OPERATION_LOCK_PARTICIPANT_TOKEN}" ]] || return 1
  rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}"
}

acquire_operation_lock() {
  mkdir -p "${CLAUDE_HOME}"
  local attempt=0 owner_pid="" attempt_limit="120"
  local parent_pid="${OMC_PARENT_OPERATION_LOCK_PID:-}"
  local parent_token="${OMC_PARENT_OPERATION_LOCK_TOKEN:-}"
  local parent_lock_id="${OMC_PARENT_OPERATION_LOCK_ID:-}"
  if [[ "${parent_pid}" =~ ^[1-9][0-9]{0,19}$ \
      && -n "${parent_token}" && "${parent_token}" != *[[:cntrl:]]* \
      && ( -z "${parent_lock_id}" \
        || "${parent_lock_id}" =~ ^[0-9]+:[0-9]+$ ) \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${parent_pid}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${parent_token}" ]]; then
    OPERATION_LOCK_DIR_ID="$(watchdog_node_identity \
      "${OPERATION_LOCK_DIR}")" || return 1
    if [[ -n "${parent_lock_id}" \
        && "${OPERATION_LOCK_DIR_ID}" != "${parent_lock_id}" ]]; then
      OPERATION_LOCK_DIR_ID=""
      return 1
    fi
    if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]]; then
      reap_released_operation_lock "${OPERATION_LOCK_DIR_ID}" \
        "${parent_pid}" "${parent_token}" || true
      OPERATION_LOCK_DIR_ID=""
      return 1
    fi
    OPERATION_LOCK_PARTICIPANT_PATH="${OPERATION_LOCK_DIR}/participant.$$"
    OPERATION_LOCK_PARTICIPANT_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
    [[ ! -e "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        && ! -L "${OPERATION_LOCK_PARTICIPANT_PATH}" ]] || return 1
    if ! (umask 077; set -o noclobber; \
        printf '%s\n' "${OPERATION_LOCK_PARTICIPANT_TOKEN}" \
          > "${OPERATION_LOCK_PARTICIPANT_PATH}") 2>/dev/null \
        || ! chmod 600 "${OPERATION_LOCK_PARTICIPANT_PATH}"; then
      rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}" 2>/dev/null || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    fi
    OPERATION_LOCK_PARTICIPANT_ID="$(watchdog_node_identity \
      "${OPERATION_LOCK_PARTICIPANT_PATH}")" || {
      rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}" 2>/dev/null || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    }
    if [[ "$(watchdog_node_identity "${OPERATION_LOCK_DIR}" \
          2>/dev/null || true)" != "${OPERATION_LOCK_DIR_ID}" \
        || -e "${OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${OPERATION_LOCK_RELEASE_MARKER}" \
        || "$(watchdog_read_canonical_metadata_line \
          "${OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
          != "${parent_pid}" \
        || "$(watchdog_read_canonical_metadata_line \
          "${OPERATION_LOCK_DIR}/token" 512 2>/dev/null || true)" \
          != "${parent_token}" \
        || ! -f "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        || -L "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        || "$(watchdog_node_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
          2>/dev/null || true)" != "${OPERATION_LOCK_PARTICIPANT_ID}" \
        || "$(watchdog_read_canonical_metadata_line \
          "${OPERATION_LOCK_PARTICIPANT_PATH}" 512 \
          2>/dev/null || true)" \
          != "${OPERATION_LOCK_PARTICIPANT_TOKEN}" ]]; then
      remove_exact_operation_lock_participant || true
      reap_released_operation_lock "${OPERATION_LOCK_DIR_ID}" \
        "${parent_pid}" "${parent_token}" || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      OPERATION_LOCK_PARTICIPANT_ID=""
      return 1
    fi
    OPERATION_LOCK_BORROWED=1
    OPERATION_LOCK_AUTH_PID="${parent_pid}"
    OPERATION_LOCK_AUTH_TOKEN="${parent_token}"
    return 0
  fi
  if [[ -n "${OMC_TEST_WATCHDOG_LOCK_ATTEMPTS:-}" ]]; then
    [[ "${OMC_TEST_WATCHDOG_LOCK_ATTEMPTS}" \
        =~ ^[1-9][0-9]{0,3}$ ]] \
      && (( OMC_TEST_WATCHDOG_LOCK_ATTEMPTS <= 6000 )) || return 1
    attempt_limit="${OMC_TEST_WATCHDOG_LOCK_ATTEMPTS}"
  fi
  while ! (umask 077; mkdir "${OPERATION_LOCK_DIR}") 2>/dev/null; do
    # A prior owner may have died after publishing its exact release marker
    # but before retirement. Such a participant-free generation is safe to
    # settle before retrying atomic acquisition; malformed markers stay put.
    if reap_stranded_released_operation_lock; then
      continue
    fi
    attempt=$((attempt + 1))
    owner_pid="$(watchdog_read_canonical_metadata_line \
      "${OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)"
    if [[ "${attempt}" -ge "${attempt_limit}" ]]; then
      printf 'ERROR: another oh-my-claude install/uninstall/watchdog operation is active (pid=%s, lock=%s).\n' \
        "${owner_pid:-unknown}" "${OPERATION_LOCK_DIR}" >&2
      printf 'If the owner is gone, verify every participant.* PID is also gone before removing this exact lock manually.\n' >&2
      return 1
    fi
    sleep 0.25 2>/dev/null || sleep 1
  done
  OPERATION_LOCK_DIR_ID="$(watchdog_node_identity \
    "${OPERATION_LOCK_DIR}")" || return 1
  if ! chmod 700 "${OPERATION_LOCK_DIR}" 2>/dev/null; then
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  OPERATION_LOCK_TOKEN="$$.${RANDOM}.$(date +%s)"
  if ! (umask 077; set -o noclobber; \
      printf '%s\n' "$$" > "${OPERATION_LOCK_DIR}/pid" \
      && printf '%s\n' "${OPERATION_LOCK_TOKEN}" \
        > "${OPERATION_LOCK_DIR}/token") 2>/dev/null; then
    rm -f -- "${OPERATION_LOCK_DIR}/pid" \
      "${OPERATION_LOCK_DIR}/token" 2>/dev/null || true
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  OPERATION_LOCK_HELD=1
  OPERATION_LOCK_AUTH_PID="$$"
  OPERATION_LOCK_AUTH_TOKEN="${OPERATION_LOCK_TOKEN}"
}

release_operation_lock() {
  if [[ "${OPERATION_LOCK_BORROWED}" -eq 1 ]]; then
    remove_exact_operation_lock_participant || true
    reap_released_operation_lock "${OPERATION_LOCK_DIR_ID}" \
      "${OPERATION_LOCK_AUTH_PID}" "${OPERATION_LOCK_AUTH_TOKEN}" || true
    OPERATION_LOCK_BORROWED=0
    OPERATION_LOCK_PARTICIPANT_PATH=""
    OPERATION_LOCK_PARTICIPANT_TOKEN=""
    OPERATION_LOCK_PARTICIPANT_ID=""
    OPERATION_LOCK_AUTH_PID=""
    OPERATION_LOCK_AUTH_TOKEN=""
    OPERATION_LOCK_DIR_ID=""
    return 0
  fi
  if [[ "${OPERATION_LOCK_HELD}" -ne 1 ]]; then
    OPERATION_LOCK_AUTH_PID=""
    OPERATION_LOCK_AUTH_TOKEN=""
    OPERATION_LOCK_DIR_ID=""
    return 0
  fi
  if operation_lock_generation_matches "${OPERATION_LOCK_DIR_ID}" "$$" \
      "${OPERATION_LOCK_TOKEN}"; then
    publish_operation_lock_release_marker \
      && reap_released_operation_lock "${OPERATION_LOCK_DIR_ID}" "$$" \
        "${OPERATION_LOCK_TOKEN}" || true
  fi
  OPERATION_LOCK_HELD=0
  OPERATION_LOCK_AUTH_PID=""
  OPERATION_LOCK_AUTH_TOKEN=""
  OPERATION_LOCK_DIR_ID=""
}

acquire_scheduler_lock() {
  mkdir -p "${CLAUDE_HOME}"
  local attempt=0 owner_pid=""
  while ! (umask 077; mkdir "${SCHEDULER_LOCK_DIR}") 2>/dev/null; do
    attempt=$((attempt + 1))
    owner_pid="$(watchdog_read_canonical_metadata_line \
      "${SCHEDULER_LOCK_DIR}/pid" 32 2>/dev/null || true)"
    if [[ "${attempt}" -ge 120 ]]; then
      printf 'ERROR: another resume-watchdog scheduler operation is active (pid=%s, lock=%s).\n' \
        "${owner_pid:-unknown}" "${SCHEDULER_LOCK_DIR}" >&2
      return 1
    fi
    # A pidless lock is never reclaimed: it may be an owner paused between
    # mkdir and metadata publication. This is intentionally fail-closed.
    sleep 0.25 2>/dev/null || sleep 1
  done
  SCHEDULER_LOCK_DIR_ID="$(watchdog_node_identity \
    "${SCHEDULER_LOCK_DIR}")" || return 1
  if ! chmod 700 "${SCHEDULER_LOCK_DIR}" 2>/dev/null; then
    rmdir "${SCHEDULER_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  SCHEDULER_LOCK_TOKEN="$$.${RANDOM}.$(date +%s)"
  if ! (umask 077; set -o noclobber; \
      printf '%s\n' "$$" > "${SCHEDULER_LOCK_DIR}/pid" \
      && printf '%s\n' "${SCHEDULER_LOCK_TOKEN}" \
        > "${SCHEDULER_LOCK_DIR}/token") 2>/dev/null; then
    rm -f -- "${SCHEDULER_LOCK_DIR}/pid" \
      "${SCHEDULER_LOCK_DIR}/token" 2>/dev/null || true
    rmdir "${SCHEDULER_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  SCHEDULER_LOCK_HELD=1
}

release_scheduler_lock() {
  [[ "${SCHEDULER_LOCK_HELD}" -eq 1 ]] || return 0
  if [[ -d "${SCHEDULER_LOCK_DIR}" && ! -L "${SCHEDULER_LOCK_DIR}" \
      && "$(watchdog_node_identity "${SCHEDULER_LOCK_DIR}" \
        2>/dev/null || true)" == "${SCHEDULER_LOCK_DIR_ID}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_LOCK_DIR}/pid" 32 2>/dev/null || true)" == "$$" \
      && "$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${SCHEDULER_LOCK_TOKEN}" ]]; then
    rm -f -- "${SCHEDULER_LOCK_DIR}/pid" \
      "${SCHEDULER_LOCK_DIR}/token" 2>/dev/null || true
    rmdir "${SCHEDULER_LOCK_DIR}" 2>/dev/null || true
  fi
  SCHEDULER_LOCK_HELD=0
  SCHEDULER_LOCK_DIR_ID=""
}

safe_scheduler_leaf() {
  local path="${1:-}" component="" segment="" relative=""
  local -a segments=()
  [[ "${path}" == "${HOME}"/* && "${path}" != *[[:cntrl:]]* \
      && -d "${HOME}" && ! -L "${HOME}" ]] || return 1
  relative="${path#"${HOME}"/}"
  component="${HOME}"
  IFS='/' read -r -a segments <<< "${relative}"
  for segment in "${segments[@]}"; do
    [[ -n "${segment}" && "${segment}" != "." && "${segment}" != ".." ]] \
      || return 1
    component="${component}/${segment}"
    [[ ! -L "${component}" ]] || return 1
    if [[ "${component}" != "${path}" && -e "${component}" \
        && ! -d "${component}" ]]; then
      return 1
    fi
  done
  [[ ! -e "${path}" || -f "${path}" ]]
}

ensure_safe_scheduler_directory() {
  local path="${1:-}" key="${2:-}" component="" segment="" relative=""
  local parent_id="" component_id="" seal=""
  local -a segments=()
  scheduler_transaction_is_current || return 1
  [[ "${path}" == "${HOME}"/* && "${path}" != *[[:cntrl:]]* \
      && "${key}" =~ ^[A-Za-z0-9_-]+$ \
      && -d "${HOME}" && ! -L "${HOME}" ]] || return 1
  seal="${SCHEDULER_TX_DIR}/${key}.directory-seal"
  : > "${seal}" || return 1
  chmod 600 "${seal}" 2>/dev/null || true
  component="${HOME}"
  component_id="$(watchdog_directory_identity "${component}")" || return 1
  printf '%s\t%s\n' "${component}" "${component_id}" >> "${seal}" \
    || return 1
  relative="${path#"${HOME}"/}"
  IFS='/' read -r -a segments <<< "${relative}"
  for segment in "${segments[@]}"; do
    [[ -n "${segment}" && "${segment}" != "." && "${segment}" != ".." ]] \
      || return 1
    parent_id="${component_id}"
    component="${component}/${segment}"
    if [[ ! -e "${component}" && ! -L "${component}" ]]; then
      [[ "$(watchdog_directory_identity "${component%/*}" \
          2>/dev/null || true)" == "${parent_id}" ]] || return 1
      mkdir -- "${component}" || return 1
      [[ "$(watchdog_directory_identity "${component%/*}" \
          2>/dev/null || true)" == "${parent_id}" ]] || return 1
    fi
    [[ -d "${component}" && ! -L "${component}" ]] || return 1
    component_id="$(watchdog_directory_identity "${component}")" || return 1
    printf '%s\t%s\n' "${component}" "${component_id}" >> "${seal}" \
      || return 1
  done
  scheduler_directory_seal_is_current "${key}"
}

scheduler_directory_seal_is_current() {
  local key="${1:-}" seal="" path="" expected_id="" row=""
  local seal_snapshot=""
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  seal="${SCHEDULER_TX_DIR}/${key}.directory-seal"
  [[ -f "${seal}" && ! -L "${seal}" ]] || return 1
  seal_snapshot="$(watchdog_read_canonical_metadata_snapshot \
    "${seal}" 1048576)" || return 1
  while IFS= read -r row; do
    [[ "${row}" == *$'\t'* ]] || return 1
    path="${row%%$'\t'*}"
    expected_id="${row#*$'\t'}"
    [[ "${expected_id}" != *$'\t'* \
        && "${path}" == /* && "${path}" != *[[:cntrl:]]* \
        && "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
        && -d "${path}" && ! -L "${path}" \
        && "$(watchdog_directory_identity "${path}" \
          2>/dev/null || true)" == "${expected_id}" ]] || return 1
  done <<< "${seal_snapshot}"
}

ensure_safe_scheduler_parent() {
  local path="${1:-}" key="${2:-}"
  ensure_safe_scheduler_directory "${path%/*}" "${key}"
}

watchdog_stat_value() {
  local path="${1:-}" bsd_format="${2:-}" gnu_format="${3:-}"
  if stat -c "${gnu_format}" "${path}" >/dev/null 2>&1; then
    stat -c "${gnu_format}" "${path}" 2>/dev/null
  else
    stat -f "${bsd_format}" "${path}" 2>/dev/null
  fi
}

watchdog_file_identity() {
  watchdog_stat_value "${1:-}" '%d:%i:%z:%m:%c' '%d:%i:%s:%Y:%Z'
}

watchdog_node_identity() {
  watchdog_stat_value "${1:-}" '%d:%i' '%d:%i'
}

watchdog_directory_identity() {
  watchdog_stat_value "${1:-}" '%d:%i' '%d:%i'
}

watchdog_file_mode() {
  watchdog_stat_value "${1:-}" '%Lp' '%a'
}

watchdog_file_owner() {
  watchdog_stat_value "${1:-}" '%u' '%u'
}

scheduler_canonical_directory() (
  POSIXLY_CORRECT=1 || \return 1
  \unset -f builtin cd pwd return unset || \return 1
  [[ -n "${1:-}" ]] || \return 1
  \builtin cd -- "$1" 2>/dev/null && \builtin pwd -P
)

scheduler_nix_bin_directory_is_trusted() {
  local canonical="${1:-}" store_object=""
  case "${canonical}" in /nix/store/*/bin) ;; *) return 1 ;; esac
  store_object="${canonical#/nix/store/}"
  store_object="${store_object%/bin}"
  [[ -n "${store_object}" && "${store_object}" != */* \
      && "${store_object}" != "." && "${store_object}" != ".." \
      && "${store_object}" != *[[:cntrl:]]* ]]
}

scheduler_nix_store_path_is_trusted() {
  local path="${1:-}" relative="" store_object=""
  case "${path}" in /nix/store/*/*) ;; *) return 1 ;; esac
  relative="${path#/nix/store/}"
  store_object="${relative%%/*}"
  [[ -n "${store_object}" && "${store_object}" != "." \
      && "${store_object}" != ".." \
      && "${store_object}" != *[[:cntrl:]]* ]]
}

resolve_scheduler_durable_sync_tool() {
  local search_path="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
  local remaining="" directory="" canonical="" candidate=""
  local reader="" resolved="" owner="" identity="" domain=""
  [[ -z "${SCHEDULER_DURABLE_SYNC_TOOL}" ]] || return 0
  [[ "${search_path}" != *$'\n'* && "${search_path}" != *$'\r'* ]] \
    || return 1
  remaining="${search_path}:"
  while [[ "${remaining}" == *:* ]]; do
    directory="${remaining%%:*}"
    remaining="${remaining#*:}"
    [[ -n "${directory}" && "${directory}" == /* \
        && "${directory}" != *[[:cntrl:]]* ]] || continue
    canonical="$(scheduler_canonical_directory "${directory}")" \
      || continue
    domain=""
    case "${canonical}" in
      /usr/bin|/bin|/usr/sbin|/sbin) domain="system" ;;
      /nix/store/*/bin)
        # A case-pattern `*` can span slashes. Prove this is exactly one
        # immutable store object followed by /bin before trusting its leaf.
        scheduler_nix_bin_directory_is_trusted "${canonical}" || continue
        domain="nix"
        ;;
      *) continue ;;
    esac
    candidate="${canonical%/}/sync"
    [[ -f "${candidate}" && -x "${candidate}" ]] || continue
    resolved="${candidate}"
    if [[ -L "${candidate}" ]]; then
      [[ "${domain}" == "nix" ]] || continue
      resolved=""
      # Nix bin outputs commonly expose immutable symlink leaves. Resolve the
      # leaf only with an exact system/store readlink, and execute the final
      # ordinary store file so a later alias change cannot redirect a barrier.
      for reader in /usr/bin/readlink /bin/readlink \
          "${canonical%/}/readlink"; do
        [[ -x "${reader}" ]] || continue
        resolved="$("${reader}" -f -- "${candidate}" 2>/dev/null)" \
          || resolved=""
        scheduler_nix_store_path_is_trusted "${resolved}" \
          || resolved=""
        [[ -n "${resolved}" && -f "${resolved}" \
            && -x "${resolved}" && ! -L "${resolved}" ]] && break
        resolved=""
      done
      [[ -n "${resolved}" ]] || continue
    else
      [[ ! -L "${resolved}" ]] || continue
    fi
    if [[ "${domain}" == "nix" ]]; then
      scheduler_nix_store_path_is_trusted "${resolved}" || continue
    fi
    owner="$(watchdog_file_owner "${resolved}" 2>/dev/null || true)"
    [[ "${owner}" =~ ^(0|[1-9][0-9]*)$ ]] || continue
    [[ "${domain}" == "nix" || "${owner}" == "0" ]] || continue
    identity="$(watchdog_file_identity "${resolved}" 2>/dev/null || true)"
    [[ -n "${identity}" ]] || continue
    SCHEDULER_DURABLE_SYNC_TOOL="${resolved}"
    SCHEDULER_DURABLE_SYNC_TOOL_ID="${identity}"
    SCHEDULER_DURABLE_SYNC_TOOL_OWNER="${owner}"
    SCHEDULER_DURABLE_SYNC_TOOL_DOMAIN="${domain}"
    return 0
  done
  return 1
}

watchdog_scheduler_durable_barrier() {
  resolve_scheduler_durable_sync_tool || return 1
  case "${SCHEDULER_DURABLE_SYNC_TOOL_DOMAIN}" in
    system)
      case "${SCHEDULER_DURABLE_SYNC_TOOL}" in
        /usr/bin/sync|/bin/sync|/usr/sbin/sync|/sbin/sync) ;;
        *) return 1 ;;
      esac
      [[ "${SCHEDULER_DURABLE_SYNC_TOOL_OWNER}" == "0" ]] || return 1
      ;;
    nix)
      scheduler_nix_store_path_is_trusted \
        "${SCHEDULER_DURABLE_SYNC_TOOL}" || return 1
      ;;
    *) return 1 ;;
  esac
  [[ -f "${SCHEDULER_DURABLE_SYNC_TOOL}" \
      && ! -L "${SCHEDULER_DURABLE_SYNC_TOOL}" \
      && -x "${SCHEDULER_DURABLE_SYNC_TOOL}" \
      && "$(watchdog_file_owner "${SCHEDULER_DURABLE_SYNC_TOOL}" \
        2>/dev/null || true)" == "${SCHEDULER_DURABLE_SYNC_TOOL_OWNER}" \
      && "$(watchdog_file_identity "${SCHEDULER_DURABLE_SYNC_TOOL}" \
        2>/dev/null || true)" == "${SCHEDULER_DURABLE_SYNC_TOOL_ID}" ]] \
    || return 1
  "${SCHEDULER_DURABLE_SYNC_TOOL}" >/dev/null 2>&1
}

scheduler_lock_authority_is_current() {
  [[ "${SCHEDULER_LOCK_HELD:-0}" -eq 1 \
      && -n "${SCHEDULER_LOCK_DIR_ID:-}" \
      && -d "${SCHEDULER_LOCK_DIR}" && ! -L "${SCHEDULER_LOCK_DIR}" \
      && "$(watchdog_node_identity "${SCHEDULER_LOCK_DIR}" \
        2>/dev/null || true)" == "${SCHEDULER_LOCK_DIR_ID}" \
      && -f "${SCHEDULER_LOCK_DIR}/pid" \
      && ! -L "${SCHEDULER_LOCK_DIR}/pid" \
      && -f "${SCHEDULER_LOCK_DIR}/token" \
      && ! -L "${SCHEDULER_LOCK_DIR}/token" \
      && "$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_LOCK_DIR}/pid" 32 2>/dev/null || true)" == "$$" \
      && "$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${SCHEDULER_LOCK_TOKEN}" ]]
}

scheduler_transaction_is_current() {
  operation_lock_authority_is_current \
    && scheduler_lock_authority_is_current \
    && [[ -n "${SCHEDULER_TX_DIR:-}" \
      && -n "${SCHEDULER_TX_DIR_ID:-}" \
      && -n "${SCHEDULER_TX_PARENT_ID:-}" \
      && "${SCHEDULER_TX_DIR}" == "${CLAUDE_HOME}/.watchdog-scheduler-txn."* \
      && "${SCHEDULER_TX_DIR}" != *[[:cntrl:]]* \
      && -d "${CLAUDE_HOME}" && ! -L "${CLAUDE_HOME}" \
      && "$(watchdog_directory_identity "${CLAUDE_HOME}" \
        2>/dev/null || true)" == "${SCHEDULER_TX_PARENT_ID}" \
      && -d "${SCHEDULER_TX_DIR}" && ! -L "${SCHEDULER_TX_DIR}" \
      && "$(watchdog_directory_identity "${SCHEDULER_TX_DIR}" \
        2>/dev/null || true)" == "${SCHEDULER_TX_DIR_ID}" \
      && "$(watchdog_file_mode "${SCHEDULER_TX_DIR}" \
        2>/dev/null || true)" == "700" ]]
}

watchdog_sha256_file() {
  local path="${1:-}" output="" digest=""
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    output="$(shasum -a 256 -- "${path}" 2>/dev/null)" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output="$(sha256sum -- "${path}" 2>/dev/null)" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    output="$(python3 - "${path}" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
)" || return 1
  else
    return 1
  fi
  digest="${output%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s' "${digest}"
}

watchdog_sha256_text() {
  local value="${1:-}" output="" digest=""
  if command -v shasum >/dev/null 2>&1; then
    output="$(printf '%s' "${value}" | shasum -a 256 2>/dev/null)" \
      || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output="$(printf '%s' "${value}" | sha256sum 2>/dev/null)" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    output="$(printf '%s' "${value}" | python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' \
      2>/dev/null)" || return 1
  else
    return 1
  fi
  digest="${output%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s' "${digest}"
}

resolve_recovery_sha256_tool() {
  local candidate="" owner=""
  for candidate in /usr/bin/shasum /usr/bin/sha256sum /bin/sha256sum; do
    [[ -f "${candidate}" && ! -L "${candidate}" && -x "${candidate}" ]] \
      || continue
    owner="$(watchdog_file_owner "${candidate}" 2>/dev/null || true)"
    [[ "${owner}" == "0" ]] || continue
    RECOVERY_SHA_TOOL="${candidate}"
    RECOVERY_SHA_TOOL_ID="$(watchdog_file_identity "${candidate}")" \
      || return 1
    return 0
  done
  return 1
}

resolve_recovery_bash_tool() {
  local candidate="" owner=""
  for candidate in /bin/bash /usr/bin/bash; do
    [[ -f "${candidate}" && ! -L "${candidate}" && -x "${candidate}" ]] \
      || continue
    owner="$(watchdog_file_owner "${candidate}" 2>/dev/null || true)"
    [[ "${owner}" == "0" ]] || continue
    RECOVERY_BASH_TOOL="${candidate}"
    RECOVERY_BASH_TOOL_ID="$(watchdog_file_identity "${candidate}")" \
      || return 1
    return 0
  done
  return 1
}

trusted_recovery_bash() {
  local script="${1:-}" argument="${2:-}"
  [[ -n "${RECOVERY_BASH_TOOL}" \
      && -f "${RECOVERY_BASH_TOOL}" && ! -L "${RECOVERY_BASH_TOOL}" \
      && -x "${RECOVERY_BASH_TOOL}" \
      && "$(watchdog_file_owner "${RECOVERY_BASH_TOOL}" \
        2>/dev/null || true)" == "0" \
      && "$(watchdog_file_identity "${RECOVERY_BASH_TOOL}" \
        2>/dev/null || true)" == "${RECOVERY_BASH_TOOL_ID}" \
      && -f "${script}" && ! -L "${script}" \
      && -n "${argument}" ]] || return 1
  OMC_PARENT_OPERATION_LOCK_PID="${OPERATION_LOCK_AUTH_PID}" \
  OMC_PARENT_OPERATION_LOCK_TOKEN="${OPERATION_LOCK_AUTH_TOKEN}" \
  OMC_PARENT_OPERATION_LOCK_ID="${OPERATION_LOCK_DIR_ID}" \
  BASH_ENV='' ENV='' command \
    "${RECOVERY_BASH_TOOL}" "${script}" "${argument}"
}

trusted_recovery_sha256_file() {
  local path="${1:-}" output="" digest=""
  [[ -n "${RECOVERY_SHA_TOOL}" \
      && -f "${RECOVERY_SHA_TOOL}" && ! -L "${RECOVERY_SHA_TOOL}" \
      && -x "${RECOVERY_SHA_TOOL}" \
      && "$(watchdog_file_owner "${RECOVERY_SHA_TOOL}" \
        2>/dev/null || true)" == "0" \
      && "$(watchdog_file_identity "${RECOVERY_SHA_TOOL}" \
        2>/dev/null || true)" == "${RECOVERY_SHA_TOOL_ID}" \
      && -f "${path}" && ! -L "${path}" ]] || return 1
  case "${RECOVERY_SHA_TOOL##*/}" in
    shasum)
      output="$(command "${RECOVERY_SHA_TOOL}" -a 256 -- "${path}" \
        2>/dev/null)" || return 1
      ;;
    sha256sum)
      output="$(command "${RECOVERY_SHA_TOOL}" -- "${path}" \
        2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  digest="${output%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s' "${digest}"
}

operation_lock_participant_is_current() {
  [[ "${OPERATION_LOCK_BORROWED:-0}" -ne 1 ]] && return 0
  [[ -n "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && -n "${OPERATION_LOCK_PARTICIPANT_TOKEN}" \
      && -n "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && -f "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && ! -L "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && "$(watchdog_node_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true)" == "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_PARTICIPANT_PATH}" 512 \
        2>/dev/null || true)" \
        == "${OPERATION_LOCK_PARTICIPANT_TOKEN}" ]]
}

operation_lock_authority_is_current() {
  [[ -n "${OPERATION_LOCK_AUTH_PID}" \
      && -n "${OPERATION_LOCK_AUTH_TOKEN}" \
      && -n "${OPERATION_LOCK_DIR_ID}" \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && "$(watchdog_node_identity "${OPERATION_LOCK_DIR}" \
        2>/dev/null || true)" == "${OPERATION_LOCK_DIR_ID}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${OPERATION_LOCK_AUTH_PID}" \
      && "$(watchdog_read_canonical_metadata_line \
        "${OPERATION_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${OPERATION_LOCK_AUTH_TOKEN}" ]] \
    && operation_lock_participant_is_current
}

installed_recovery_helper_digest() {
  local relative="${1:-}" manifest="${2:-}" line="" result="" count=0
  [[ "${relative}" == "switch-tier.sh" \
      || "${relative}" == "skills/autowork/scripts/omc-config.sh" ]] \
    || return 1
  [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^([0-9A-Fa-f]{64})[[:space:]][[:space:]](.+)$ \
        && "${BASH_REMATCH[2]}" == "${relative}" ]]; then
      result="${BASH_REMATCH[1]}"
      count=$((count + 1))
    fi
  done < "${manifest}"
  [[ "${count}" -eq 1 ]] || return 1
  printf '%s' "${result}"
}

recovery_helper_source_is_current() {
  local path="${1:-}" expected_id="${2:-}" expected_hash="${3:-}"
  safe_scheduler_leaf "${path}" \
    && [[ -f "${path}" && ! -L "${path}" \
      && "$(watchdog_file_identity "${path}" 2>/dev/null || true)" \
        == "${expected_id}" \
      && "$(trusted_recovery_sha256_file "${path}" 2>/dev/null || true)" \
        == "${expected_hash}" ]]
}

private_recovery_helper_is_current() {
  local path="${1:-}" expected_id="${2:-}" expected_hash="${3:-}"
  [[ -n "${RECOVERY_HELPER_DIR}" \
      && -d "${RECOVERY_HELPER_DIR}" && ! -L "${RECOVERY_HELPER_DIR}" \
      && "$(watchdog_directory_identity "${RECOVERY_HELPER_DIR}" \
        2>/dev/null || true)" == "${RECOVERY_HELPER_DIR_ID}" \
      && -f "${path}" && ! -L "${path}" \
      && "$(watchdog_node_identity "${path}" 2>/dev/null || true)" \
        == "${expected_id}" \
      && "$(trusted_recovery_sha256_file "${path}" 2>/dev/null || true)" \
        == "${expected_hash}" \
      && "$(watchdog_file_mode "${path}" 2>/dev/null || true)" \
        == "400" ]]
}

recovery_authority_is_current() {
  local manifest="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
  operation_lock_authority_is_current \
    && safe_scheduler_leaf "${manifest}" \
    && [[ -f "${manifest}" && ! -L "${manifest}" \
      && "$(watchdog_file_identity "${manifest}" 2>/dev/null || true)" \
        == "${RECOVERY_MANIFEST_ID}" \
      && "$(trusted_recovery_sha256_file "${manifest}" \
        2>/dev/null || true)" \
        == "${RECOVERY_MANIFEST_HASH}" ]] \
    || return 1
  if [[ "${RECOVERY_NEEDS_SWITCH}" -eq 1 ]]; then
    recovery_helper_source_is_current \
      "${CLAUDE_HOME}/switch-tier.sh" \
      "${RECOVERY_SWITCH_SOURCE_ID}" "${RECOVERY_SWITCH_SOURCE_HASH}" \
      && private_recovery_helper_is_current \
        "${RECOVERY_HELPER_DIR}/switch-tier.sh" \
        "${RECOVERY_SWITCH_COPY_ID}" "${RECOVERY_SWITCH_COPY_HASH}" \
      || return 1
  fi
  if [[ "${RECOVERY_NEEDS_OMC}" -eq 1 ]]; then
    recovery_helper_source_is_current \
      "${CLAUDE_HOME}/skills/autowork/scripts/omc-config.sh" \
      "${RECOVERY_OMC_SOURCE_ID}" "${RECOVERY_OMC_SOURCE_HASH}" \
      && private_recovery_helper_is_current \
        "${RECOVERY_HELPER_DIR}/omc-config.sh" \
        "${RECOVERY_OMC_COPY_ID}" "${RECOVERY_OMC_COPY_HASH}" \
      || return 1
  fi
}

shared_metadata_class_exists() {
  local class="${1:-}" candidate=""
  case "${class}" in
    switch)
      [[ -e "${CLAUDE_HOME}/.switch-tier-transaction" \
          || -L "${CLAUDE_HOME}/.switch-tier-transaction" ]] && return 0
      for candidate in "${CLAUDE_HOME}"/.switch-tier-transaction.stage.* \
          "${CLAUDE_HOME}"/.switch-tier-retired.*; do
        [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
      done
      ;;
    omc)
      [[ -e "${CLAUDE_HOME}/.omc-config-transaction" \
          || -L "${CLAUDE_HOME}/.omc-config-transaction" ]] && return 0
      for candidate in "${CLAUDE_HOME}"/.omc-config-transaction.stage.* \
          "${CLAUDE_HOME}"/.omc-config-retired.*; do
        [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
      done
      ;;
    *) return 2 ;;
  esac
  return 1
}

shared_metadata_class_is_absent() {
  ! shared_metadata_class_exists "${1:-}"
}

cleanup_private_recovery_helpers() {
  local failures=0 path=""
  [[ -n "${RECOVERY_HELPER_DIR}" ]] || return 0
  path="${RECOVERY_HELPER_DIR}/switch-tier.sh"
  if [[ -e "${path}" || -L "${path}" ]]; then
    if private_recovery_helper_is_current "${path}" \
        "${RECOVERY_SWITCH_COPY_ID}" "${RECOVERY_SWITCH_COPY_HASH}"; then
      rm -f -- "${path}" || failures=$((failures + 1))
    else
      failures=$((failures + 1))
    fi
  fi
  path="${RECOVERY_HELPER_DIR}/omc-config.sh"
  if [[ -e "${path}" || -L "${path}" ]]; then
    if private_recovery_helper_is_current "${path}" \
        "${RECOVERY_OMC_COPY_ID}" "${RECOVERY_OMC_COPY_HASH}"; then
      rm -f -- "${path}" || failures=$((failures + 1))
    else
      failures=$((failures + 1))
    fi
  fi
  if [[ -d "${RECOVERY_HELPER_DIR}" && ! -L "${RECOVERY_HELPER_DIR}" \
      && "$(watchdog_directory_identity "${RECOVERY_HELPER_DIR}" \
        2>/dev/null || true)" == "${RECOVERY_HELPER_DIR_ID}" ]]; then
    rmdir "${RECOVERY_HELPER_DIR}" 2>/dev/null \
      || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  [[ "${failures}" -eq 0 ]]
}

settle_shared_transactions() {
  local manifest="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
  local switch_source="${CLAUDE_HOME}/switch-tier.sh"
  local omc_source="${CLAUDE_HOME}/skills/autowork/scripts/omc-config.sh"
  local switch_expected="" omc_expected="" switch_copy="" omc_copy=""
  RECOVERY_NEEDS_SWITCH=0
  RECOVERY_NEEDS_OMC=0
  shared_metadata_class_exists switch && RECOVERY_NEEDS_SWITCH=1
  shared_metadata_class_exists omc && RECOVERY_NEEDS_OMC=1
  if [[ "${RECOVERY_NEEDS_SWITCH}" -eq 0 \
      && "${RECOVERY_NEEDS_OMC}" -eq 0 ]]; then
    return 0
  fi
  operation_lock_authority_is_current || return 1
  resolve_recovery_sha256_tool || return 1
  resolve_recovery_bash_tool || return 1
  safe_scheduler_leaf "${manifest}" \
    && [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
  RECOVERY_MANIFEST_ID="$(watchdog_file_identity "${manifest}")" \
    || return 1
  RECOVERY_MANIFEST_HASH="$(trusted_recovery_sha256_file "${manifest}")" \
    || return 1
  if [[ "${RECOVERY_NEEDS_SWITCH}" -eq 1 ]]; then
    switch_expected="$(installed_recovery_helper_digest \
      switch-tier.sh "${manifest}")" || return 1
    safe_scheduler_leaf "${switch_source}" \
      && [[ -f "${switch_source}" && ! -L "${switch_source}" ]] \
      || return 1
    RECOVERY_SWITCH_SOURCE_ID="$(watchdog_file_identity \
      "${switch_source}")" || return 1
    RECOVERY_SWITCH_SOURCE_HASH="$(trusted_recovery_sha256_file \
      "${switch_source}")" || return 1
    [[ "${RECOVERY_SWITCH_SOURCE_HASH}" == "${switch_expected}" ]] \
      || return 1
  fi
  if [[ "${RECOVERY_NEEDS_OMC}" -eq 1 ]]; then
    omc_expected="$(installed_recovery_helper_digest \
      skills/autowork/scripts/omc-config.sh "${manifest}")" || return 1
    safe_scheduler_leaf "${omc_source}" \
      && [[ -f "${omc_source}" && ! -L "${omc_source}" ]] || return 1
    RECOVERY_OMC_SOURCE_ID="$(watchdog_file_identity "${omc_source}")" \
      || return 1
    RECOVERY_OMC_SOURCE_HASH="$(trusted_recovery_sha256_file \
      "${omc_source}")" || return 1
    [[ "${RECOVERY_OMC_SOURCE_HASH}" == "${omc_expected}" ]] \
      || return 1
  fi
  if [[ "${RECOVERY_NEEDS_SWITCH}" -eq 1 ]]; then
    recovery_helper_source_is_current "${switch_source}" \
      "${RECOVERY_SWITCH_SOURCE_ID}" "${RECOVERY_SWITCH_SOURCE_HASH}" \
      || return 1
  fi
  if [[ "${RECOVERY_NEEDS_OMC}" -eq 1 ]]; then
    recovery_helper_source_is_current "${omc_source}" \
      "${RECOVERY_OMC_SOURCE_ID}" "${RECOVERY_OMC_SOURCE_HASH}" \
      || return 1
  fi
  [[ "$(watchdog_file_identity "${manifest}" 2>/dev/null || true)" \
          == "${RECOVERY_MANIFEST_ID}" \
      && "$(trusted_recovery_sha256_file "${manifest}" \
        2>/dev/null || true)" \
          == "${RECOVERY_MANIFEST_HASH}" ]] || return 1
  RECOVERY_HELPER_DIR="$(mktemp -d \
    "${CLAUDE_HOME}/.watchdog-recovery-helpers.XXXXXX")" || return 1
  [[ "${RECOVERY_HELPER_DIR}" \
        == "${CLAUDE_HOME}"/.watchdog-recovery-helpers.* \
      && "${RECOVERY_HELPER_DIR##*/}" \
        =~ ^\.watchdog-recovery-helpers\.[A-Za-z0-9]+$ \
      && -d "${RECOVERY_HELPER_DIR}" \
      && ! -L "${RECOVERY_HELPER_DIR}" ]] || return 1
  chmod 700 "${RECOVERY_HELPER_DIR}" || return 1
  RECOVERY_HELPER_DIR_ID="$(watchdog_directory_identity \
    "${RECOVERY_HELPER_DIR}")" || return 1
  switch_copy="${RECOVERY_HELPER_DIR}/switch-tier.sh"
  omc_copy="${RECOVERY_HELPER_DIR}/omc-config.sh"
  if [[ "${RECOVERY_NEEDS_SWITCH}" -eq 1 ]]; then
    cp -p -- "${switch_source}" "${switch_copy}" || return 1
    chmod 400 "${switch_copy}" || return 1
    RECOVERY_SWITCH_COPY_ID="$(watchdog_node_identity "${switch_copy}")" \
      || return 1
    RECOVERY_SWITCH_COPY_HASH="$(trusted_recovery_sha256_file \
      "${switch_copy}")" || return 1
    [[ "${RECOVERY_SWITCH_COPY_HASH}" == "${switch_expected}" ]] \
      || return 1
  fi
  if [[ "${RECOVERY_NEEDS_OMC}" -eq 1 ]]; then
    cp -p -- "${omc_source}" "${omc_copy}" || return 1
    chmod 400 "${omc_copy}" || return 1
    RECOVERY_OMC_COPY_ID="$(watchdog_node_identity "${omc_copy}")" \
      || return 1
    RECOVERY_OMC_COPY_HASH="$(trusted_recovery_sha256_file "${omc_copy}")" \
      || return 1
    [[ "${RECOVERY_OMC_COPY_HASH}" == "${omc_expected}" ]] || return 1
  fi
  recovery_authority_is_current || return 1
  if [[ "${RECOVERY_NEEDS_SWITCH}" -eq 1 ]]; then
    trusted_recovery_bash "${switch_copy}" --recover-only || return 1
    recovery_authority_is_current || return 1
    shared_metadata_class_is_absent switch || return 1
  fi
  shared_metadata_class_is_absent switch || return 1
  if [[ "${RECOVERY_NEEDS_OMC}" -eq 1 ]]; then
    trusted_recovery_bash "${omc_copy}" recover-only || return 1
    recovery_authority_is_current || return 1
    shared_metadata_class_is_absent omc || return 1
  fi
  shared_metadata_class_is_absent switch \
    && shared_metadata_class_is_absent omc
}

capture_scheduler_path_phase() {
  local key="${1:-}" path="${2:-}" phase="${3:-}"
  local copy_payload="${4:-0}" parent="" parent_id="" identity="" digest=""
  local mode=""
  local captured_state=""
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ \
      && "${phase}" =~ ^(initial|published)$ ]] || return 1
  safe_scheduler_leaf "${path}" || return 1
  parent="${path%/*}"
  rm -f -- "${SCHEDULER_TX_DIR}/${key}.${phase}-state" \
    "${SCHEDULER_TX_DIR}/${key}.${phase}-parent-id" \
    "${SCHEDULER_TX_DIR}/${key}.${phase}-id" \
    "${SCHEDULER_TX_DIR}/${key}.${phase}-hash" \
    "${SCHEDULER_TX_DIR}/${key}.${phase}-mode" 2>/dev/null || return 1
  if [[ -d "${parent}" && ! -L "${parent}" ]]; then
    parent_id="$(watchdog_directory_identity "${parent}")" || return 1
  elif [[ ! -e "${parent}" && ! -L "${parent}" ]]; then
    parent_id="absent"
  else
    return 1
  fi
  printf '%s\n' "${parent_id}" \
    > "${SCHEDULER_TX_DIR}/${key}.${phase}-parent-id" || return 1
  if [[ -f "${path}" && ! -L "${path}" ]]; then
    identity="$(watchdog_file_identity "${path}")" || return 1
    digest="$(watchdog_sha256_file "${path}")" || return 1
    mode="$(watchdog_file_mode "${path}")" || return 1
    if [[ "${copy_payload}" -eq 1 ]]; then
      cp -p -- "${path}" "${SCHEDULER_TX_DIR}/${key}.before" || return 1
      [[ "$(watchdog_sha256_file "${SCHEDULER_TX_DIR}/${key}.before")" \
          == "${digest}" \
          && "$(watchdog_file_mode \
            "${SCHEDULER_TX_DIR}/${key}.before" 2>/dev/null || true)" \
            == "${mode}" \
          && "$(watchdog_file_identity "${path}" 2>/dev/null || true)" \
            == "${identity}" \
          && "$(watchdog_sha256_file "${path}" 2>/dev/null || true)" \
            == "${digest}" ]] || return 1
    fi
    printf 'present\n' > "${SCHEDULER_TX_DIR}/${key}.${phase}-state" \
      || return 1
    captured_state="present"
    printf '%s\n' "${identity}" \
      > "${SCHEDULER_TX_DIR}/${key}.${phase}-id" || return 1
    printf '%s\n' "${digest}" \
      > "${SCHEDULER_TX_DIR}/${key}.${phase}-hash" || return 1
    printf '%s\n' "${mode}" \
      > "${SCHEDULER_TX_DIR}/${key}.${phase}-mode" || return 1
  elif [[ ! -e "${path}" && ! -L "${path}" ]]; then
    printf 'absent\n' > "${SCHEDULER_TX_DIR}/${key}.${phase}-state" \
      || return 1
    captured_state="absent"
  else
    return 1
  fi
  safe_scheduler_leaf "${path}" || return 1
  if [[ "${parent_id}" == "absent" ]]; then
    [[ ! -e "${parent}" && ! -L "${parent}" \
        && "${captured_state}" == "absent" ]] || return 1
  else
    [[ -d "${parent}" && ! -L "${parent}" \
        && "$(watchdog_directory_identity "${parent}" 2>/dev/null || true)" \
          == "${parent_id}" ]] || return 1
  fi
  if [[ "${captured_state}" == "present" ]]; then
    [[ -f "${path}" && ! -L "${path}" \
        && "$(watchdog_file_identity "${path}" 2>/dev/null || true)" \
          == "${identity}" \
        && "$(watchdog_sha256_file "${path}" 2>/dev/null || true)" \
          == "${digest}" \
        && "$(watchdog_file_mode "${path}" 2>/dev/null || true)" \
          == "${mode}" ]] || return 1
  else
    [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
  fi
}

scheduler_path_seal_is_current() {
  local key="${1:-}" path="${2:-}" phase="${3:-}"
  local state="" parent="" expected_parent_id="" expected_id=""
  local expected_hash="" expected_mode=""
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ \
      && "${phase}" =~ ^(initial|published)$ \
      && -f "${SCHEDULER_TX_DIR}/${key}.${phase}-state" \
      && ! -L "${SCHEDULER_TX_DIR}/${key}.${phase}-state" \
      && -f "${SCHEDULER_TX_DIR}/${key}.${phase}-parent-id" \
      && ! -L "${SCHEDULER_TX_DIR}/${key}.${phase}-parent-id" ]] || return 1
  state="$(watchdog_read_canonical_metadata_line \
    "${SCHEDULER_TX_DIR}/${key}.${phase}-state" 32)" || return 1
  expected_parent_id="$(watchdog_read_canonical_metadata_line \
    "${SCHEDULER_TX_DIR}/${key}.${phase}-parent-id" 128)" || return 1
  [[ "${state}" =~ ^(absent|present)$ \
      && ( "${expected_parent_id}" == "absent" \
        || "${expected_parent_id}" =~ ^[0-9]+:[0-9]+$ ) ]] || return 1
  parent="${path%/*}"
  safe_scheduler_leaf "${path}" || return 1
  if [[ "${expected_parent_id}" == "absent" ]]; then
    [[ ! -e "${parent}" && ! -L "${parent}" \
        && "${state}" == "absent" ]] || return 1
  else
    [[ -d "${parent}" && ! -L "${parent}" \
        && "$(watchdog_directory_identity "${parent}" 2>/dev/null || true)" \
          == "${expected_parent_id}" ]] || return 1
  fi
  case "${state}" in
    absent)
      [[ ! -e "${path}" && ! -L "${path}" ]]
      ;;
    present)
      [[ -f "${SCHEDULER_TX_DIR}/${key}.${phase}-id" \
          && -f "${SCHEDULER_TX_DIR}/${key}.${phase}-hash" \
          && -f "${SCHEDULER_TX_DIR}/${key}.${phase}-mode" ]] || return 1
      expected_id="$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_TX_DIR}/${key}.${phase}-id" 256)" || return 1
      expected_hash="$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_TX_DIR}/${key}.${phase}-hash" 128)" || return 1
      expected_mode="$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_TX_DIR}/${key}.${phase}-mode" 16)" || return 1
      [[ "${expected_id}" =~ ^[0-9]+:[0-9]+(:[0-9]+:[0-9]+:[0-9]+)?$ \
          && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
          && "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      local current_id=""
      if [[ "${phase}" == "published" ]]; then
        current_id="$(watchdog_node_identity "${path}" \
          2>/dev/null || true)"
      else
        current_id="$(watchdog_file_identity "${path}" \
          2>/dev/null || true)"
      fi
      [[ -f "${path}" && ! -L "${path}" \
          && "${current_id}" == "${expected_id}" \
          && "$(watchdog_sha256_file "${path}" 2>/dev/null || true)" \
            == "${expected_hash}" \
          && "$(watchdog_file_mode "${path}" 2>/dev/null || true)" \
            == "${expected_mode}" ]]
      ;;
    *) return 1 ;;
  esac
}

snapshot_scheduler_path() {
  capture_scheduler_path_phase "${1:-}" "${2:-}" initial 1
}

clear_scheduler_published_seal() {
  local key="${1:-}"
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  rm -f -- "${SCHEDULER_TX_DIR}/${key}.published-state" \
    "${SCHEDULER_TX_DIR}/${key}.published-parent-id" \
    "${SCHEDULER_TX_DIR}/${key}.published-id" \
    "${SCHEDULER_TX_DIR}/${key}.published-hash" \
    "${SCHEDULER_TX_DIR}/${key}.published-mode" 2>/dev/null
}

arm_scheduler_publication() {
  local key="${1:-}" path="${2:-}" expected_id="${3:-}"
  local expected_hash="${4:-}" expected_mode="${5:-}"
  local parent="" parent_id="" state="present"
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  safe_scheduler_leaf "${path}" || return 1
  parent="${path%/*}"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  parent_id="$(watchdog_directory_identity "${parent}")" || return 1
  if [[ "${expected_id}" == "absent" ]]; then
    state="absent"
    expected_hash=""
    expected_mode=""
  else
    [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
        && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
        && "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  fi
  clear_scheduler_published_seal "${key}" || return 1
  printf '%s\n' "${state}" \
    > "${SCHEDULER_TX_DIR}/${key}.published-state" || return 1
  printf '%s\n' "${parent_id}" \
    > "${SCHEDULER_TX_DIR}/${key}.published-parent-id" || return 1
  if [[ "${state}" == "present" ]]; then
    printf '%s\n' "${expected_id}" \
      > "${SCHEDULER_TX_DIR}/${key}.published-id" || return 1
    printf '%s\n' "${expected_hash}" \
      > "${SCHEDULER_TX_DIR}/${key}.published-hash" || return 1
    printf '%s\n' "${expected_mode}" \
      > "${SCHEDULER_TX_DIR}/${key}.published-mode" || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${parent_id}" "${state}" \
    "${expected_id}" "${expected_hash}" "${expected_mode}" \
    >> "${SCHEDULER_TX_DIR}/${key}.published-history" || return 1
}

record_scheduler_publication() {
  local key="${1:-}" path="${2:-}" expected_id="${3:-}"
  local expected_hash="${4:-}" expected_mode="${5:-}"
  local state="present"
  scheduler_transaction_is_current || return 1
  [[ "${expected_id}" == "absent" ]] && state="absent"
  [[ "$(watchdog_read_canonical_metadata_line \
      "${SCHEDULER_TX_DIR}/${key}.published-state" 32 \
      2>/dev/null || true)" == "${state}" ]] || return 1
  if [[ "${state}" == "present" ]]; then
    [[ "$(watchdog_read_canonical_metadata_line \
          "${SCHEDULER_TX_DIR}/${key}.published-id" 256)" \
          == "${expected_id}" \
        && "$(watchdog_read_canonical_metadata_line \
          "${SCHEDULER_TX_DIR}/${key}.published-hash" 128)" \
          == "${expected_hash}" \
        && "$(watchdog_read_canonical_metadata_line \
          "${SCHEDULER_TX_DIR}/${key}.published-mode" 16)" \
          == "${expected_mode}" ]] || return 1
  fi
  scheduler_path_seal_is_current "${key}" "${path}" published \
    || return 1
  watchdog_test_killpoint "after-${key}-publish"
}

scheduler_any_published_generation_is_current() {
  local key="${1:-}" path="${2:-}" parent="" parent_id="" state=""
  local expected_id="" expected_hash="" expected_mode="" row="" rest=""
  local matched=0 history_snapshot=""
  local history="${SCHEDULER_TX_DIR}/${key}.published-history"
  scheduler_transaction_is_current || return 1
  [[ -f "${history}" && ! -L "${history}" ]] || return 1
  history_snapshot="$(watchdog_read_canonical_metadata_snapshot \
    "${history}" 1048576)" || return 1
  parent="${path%/*}"
  safe_scheduler_leaf "${path}" || return 1
  while IFS= read -r row; do
    rest="${row}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    parent_id="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    state="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    expected_id="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    expected_hash="${rest%%$'\t'*}"
    expected_mode="${rest#*$'\t'}"
    [[ "${expected_mode}" != *$'\t'* \
        && "${parent_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    case "${state}" in
      absent)
        [[ -z "${expected_id}${expected_hash}${expected_mode}" ]] \
          || return 1
        ;;
      present)
        [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
            && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
            && "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
        ;;
      *) return 1 ;;
    esac
    [[ -d "${parent}" && ! -L "${parent}" \
        && "$(watchdog_directory_identity "${parent}" \
          2>/dev/null || true)" == "${parent_id}" ]] || continue
    case "${state}" in
      absent)
        [[ ! -e "${path}" && ! -L "${path}" ]] && matched=1
        ;;
      present)
        [[ -f "${path}" && ! -L "${path}" \
            && "$(watchdog_node_identity "${path}" \
              2>/dev/null || true)" == "${expected_id}" \
            && "$(watchdog_sha256_file "${path}" \
              2>/dev/null || true)" == "${expected_hash}" \
            && "$(watchdog_file_mode "${path}" \
              2>/dev/null || true)" == "${expected_mode}" ]] && matched=1
        ;;
    esac
  done <<< "${history_snapshot}"
  [[ "${matched}" -eq 1 ]]
}

verify_latest_scheduler_path_if_published() {
  local key="${1:-}" path="${2:-}"
  local history="${SCHEDULER_TX_DIR}/${key}.published-history"
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  if [[ ! -e "${history}" && ! -L "${history}" ]]; then
    return 0
  fi
  [[ -f "${history}" && ! -L "${history}" ]] || return 1
  scheduler_path_seal_is_current "${key}" "${path}" published
}

verify_latest_scheduler_publications() {
  local current=""
  scheduler_transaction_is_current || return 1
  verify_latest_scheduler_path_if_published conf "${CONF_FILE}" \
    || return 1
  verify_latest_scheduler_path_if_published macos "${MACOS_DEST}" \
    || return 1
  verify_latest_scheduler_path_if_published linux-service \
    "${LINUX_SERVICE_DEST}" || return 1
  verify_latest_scheduler_path_if_published linux-timer \
    "${LINUX_TIMER_DEST}" || return 1
  if [[ "${CRON_PUBLISHED}" -eq 1 ]]; then
    current="$(read_crontab_contents)" || return 1
    [[ "${current}" == "${CRON_LAST_PUBLISHED}" ]] || return 1
  fi
}

restore_scheduler_path() {
  local key="${1:-}" path="${2:-}" parent="" stage="" initial_state=""
  local expected_hash="" expected_mode=""
  scheduler_transaction_is_current || return 1
  [[ -f "${SCHEDULER_TX_DIR}/${key}.published-history" ]] || return 0
  # A WAL may be armed while the initial generation is still current. That is
  # an already-restored no-op, not authority to rewrite the path.
  if scheduler_path_seal_is_current "${key}" "${path}" initial; then
    return 0
  fi
  if ! scheduler_any_published_generation_is_current "${key}" "${path}"; then
    printf 'WARNING: %s changed after watchdog publication; preserving concurrent contents during rollback.\n' \
      "${path}" >&2
    return 1
  fi
  initial_state="$(watchdog_read_canonical_metadata_line \
    "${SCHEDULER_TX_DIR}/${key}.initial-state" 32)" || return 1
  parent="${path%/*}"
  case "${initial_state}" in
    present)
      [[ -f "${SCHEDULER_TX_DIR}/${key}.before" \
          && ! -L "${SCHEDULER_TX_DIR}/${key}.before" \
          && -d "${parent}" && ! -L "${parent}" ]] || return 1
      expected_hash="$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_TX_DIR}/${key}.initial-hash" 128)" || return 1
      expected_mode="$(watchdog_read_canonical_metadata_line \
        "${SCHEDULER_TX_DIR}/${key}.initial-mode" 16)" || return 1
      [[ "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
          && "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      stage="$(mktemp "${parent}/.watchdog-rollback.XXXXXX")" || return 1
      if ! cp -p -- "${SCHEDULER_TX_DIR}/${key}.before" "${stage}" \
          || [[ "$(watchdog_sha256_file "${stage}" 2>/dev/null || true)" \
            != "${expected_hash}" ]] \
          || [[ "$(watchdog_file_mode "${stage}" 2>/dev/null || true)" \
            != "${expected_mode}" ]] \
          || ! scheduler_any_published_generation_is_current \
            "${key}" "${path}" \
          || ! mv -f -- "${stage}" "${path}"; then
        rm -f -- "${stage}" 2>/dev/null || true
        return 1
      fi
      [[ -f "${path}" && ! -L "${path}" \
          && "$(watchdog_sha256_file "${path}" 2>/dev/null || true)" \
            == "${expected_hash}" \
          && "$(watchdog_file_mode "${path}" 2>/dev/null || true)" \
            == "${expected_mode}" ]]
      ;;
    absent)
      scheduler_any_published_generation_is_current "${key}" "${path}" \
        || return 1
      if [[ -e "${path}" || -L "${path}" ]]; then
        rm -f -- "${path}" || return 1
      fi
      [[ ! -e "${path}" && ! -L "${path}" ]]
      ;;
    *) return 1 ;;
  esac
}

begin_scheduler_transaction() {
  local conf_initial_state=""
  operation_lock_authority_is_current \
    && scheduler_lock_authority_is_current || return 1
  SCHEDULER_TX_DIR="$(mktemp -d "${CLAUDE_HOME}/.watchdog-scheduler-txn.XXXXXX")" \
    || return 1
  chmod 700 "${SCHEDULER_TX_DIR}" 2>/dev/null || return 1
  SCHEDULER_TX_DIR_ID="$(watchdog_directory_identity \
    "${SCHEDULER_TX_DIR}")" || return 1
  SCHEDULER_TX_PARENT_ID="$(watchdog_directory_identity \
    "${CLAUDE_HOME}")" || return 1
  scheduler_transaction_is_current || return 1
  printf 'v1\t%s\t%s\n' "$$" "${mode}" \
    > "${SCHEDULER_TX_DIR}/transaction" || return 1
  chmod 600 "${SCHEDULER_TX_DIR}/transaction" 2>/dev/null || return 1
  snapshot_scheduler_path conf "${CONF_FILE}" || return 1
  conf_initial_state="$(watchdog_read_canonical_metadata_line \
    "${SCHEDULER_TX_DIR}/conf.initial-state" 32)" || return 1
  case "${conf_initial_state}" in
    present) CONF_WAS_PRESENT=1 ;;
    absent) CONF_WAS_PRESENT=0 ;;
    *) return 1 ;;
  esac
  # The discoverable transaction must reach stable storage before the first
  # scheduler/config mutation. A later power loss may leave a partial target,
  # but it cannot be followed by a fresh snapshot that blesses that target.
  watchdog_scheduler_durable_barrier || return 1
  SCHEDULER_TX_ARMED=1
}

restore_conf_snapshot() {
  restore_scheduler_path conf "${CONF_FILE}"
}

rollback_scheduler_transaction() {
  local failures=0 current="" macos_restore_ok=1 linux_restore_ok=1
  scheduler_transaction_is_current || return 1
  if [[ -f "${SCHEDULER_TX_DIR}/macos.snapshot" ]]; then
    if command -v launchctl >/dev/null 2>&1 \
        && launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
          >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
        >/dev/null 2>&1 || failures=$((failures + 1))
    fi
    if ! restore_scheduler_path macos "${MACOS_DEST}"; then
      failures=$((failures + 1))
      macos_restore_ok=0
    fi
  fi
  if [[ -f "${SCHEDULER_TX_DIR}/linux.snapshot" ]]; then
    if systemd_user_is_usable; then
      systemctl --user disable --now oh-my-claude-resume-watchdog.timer \
        >/dev/null 2>&1 || failures=$((failures + 1))
    else
      failures=$((failures + 1))
    fi
    if ! restore_scheduler_path linux-service "${LINUX_SERVICE_DEST}"; then
      failures=$((failures + 1))
      linux_restore_ok=0
    fi
    if ! restore_scheduler_path linux-timer "${LINUX_TIMER_DEST}"; then
      failures=$((failures + 1))
      linux_restore_ok=0
    fi
  fi
  if [[ "${CRON_SNAPSHOT_KNOWN}" -eq 1 \
      && "${CRON_PUBLISHED}" -eq 1 ]] \
      && command -v crontab >/dev/null 2>&1; then
    current="$(read_crontab_contents 2>/dev/null || true)"
    if [[ "${current}" == "${CRON_LAST_PUBLISHED}" ]]; then
      printf '%s\n' "${CRON_SNAPSHOT}" | crontab - >/dev/null 2>&1 \
        || failures=$((failures + 1))
    else
      printf 'WARNING: crontab changed after watchdog publication; preserving concurrent contents during rollback.\n' >&2
      failures=$((failures + 1))
    fi
  fi
  # Keep the newly installed scheduler disabled while artifact and cron
  # rollback settles. Restore configuration only after no new schedule can
  # observe it, and reactivate a proven prior generation last.
  restore_conf_snapshot || failures=$((failures + 1))
  # Never reactivate a path whose rollback CAS lost to a concurrent edit.
  # Preserving those bytes while loading them as a trusted scheduler would
  # turn the safety rollback itself into an execution primitive.
  if [[ "${macos_restore_ok}" -eq 1 \
      && "${MACOS_WAS_LOADED}" -eq 1 && -f "${MACOS_DEST}" ]] \
      && command -v launchctl >/dev/null 2>&1; then
    launchctl bootstrap "gui/$(id -u)" "${MACOS_DEST}" >/dev/null 2>&1 \
      || failures=$((failures + 1))
  fi
  if [[ "${linux_restore_ok}" -eq 1 \
      && -f "${SCHEDULER_TX_DIR}/linux.snapshot" ]] \
      && systemd_user_is_usable; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [[ "${LINUX_WAS_ENABLED}" -eq 1 ]]; then
      systemctl --user enable oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
        || failures=$((failures + 1))
    fi
    if [[ "${LINUX_WAS_ACTIVE}" -eq 1 ]]; then
      systemctl --user start oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
        || failures=$((failures + 1))
    fi
  fi
  [[ "${failures}" -eq 0 ]]
}

cleanup_scheduler_transaction() {
  local path="" index=0 had_nullglob=0 had_dotglob=0
  local -a paths=() ids=() hashes=() modes=() current_paths=()
  [[ -n "${SCHEDULER_TX_DIR:-}" ]] || return 0
  scheduler_transaction_is_current || return 1

  shopt -q nullglob && had_nullglob=1
  shopt -q dotglob && had_dotglob=1
  shopt -s nullglob dotglob
  paths=("${SCHEDULER_TX_DIR}"/*)
  [[ "${had_nullglob}" -eq 1 ]] || shopt -u nullglob
  [[ "${had_dotglob}" -eq 1 ]] || shopt -u dotglob

  for path in "${paths[@]}"; do
    [[ "${path}" == "${SCHEDULER_TX_DIR}/"* \
        && "${path##*/}" != *[[:cntrl:]]* \
        && -f "${path}" && ! -L "${path}" ]] || return 1
    ids+=("$(watchdog_file_identity "${path}")") || return 1
    hashes+=("$(watchdog_sha256_file "${path}")") || return 1
    modes+=("$(watchdog_file_mode "${path}")") || return 1
  done

  watchdog_test_barrier \
    "${OMC_TEST_WATCHDOG_TX_CLEANUP_READY_FILE:-}" \
    "${OMC_TEST_WATCHDOG_TX_CLEANUP_RELEASE_FILE:-}" \
    "${SCHEDULER_TX_DIR}" || return 1
  scheduler_transaction_is_current || return 1

  had_nullglob=0
  had_dotglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -q dotglob && had_dotglob=1
  shopt -s nullglob dotglob
  current_paths=("${SCHEDULER_TX_DIR}"/*)
  [[ "${had_nullglob}" -eq 1 ]] || shopt -u nullglob
  [[ "${had_dotglob}" -eq 1 ]] || shopt -u dotglob
  [[ "${#current_paths[@]}" -eq "${#paths[@]}" ]] || return 1

  for ((index=0; index<${#paths[@]}; index++)); do
    path="${paths[index]}"
    [[ -f "${path}" && ! -L "${path}" \
        && "$(watchdog_file_identity "${path}" \
          2>/dev/null || true)" == "${ids[index]}" \
        && "$(watchdog_sha256_file "${path}" \
          2>/dev/null || true)" == "${hashes[index]}" \
        && "$(watchdog_file_mode "${path}" \
          2>/dev/null || true)" == "${modes[index]}" ]] || return 1
  done

  for ((index=0; index<${#paths[@]}; index++)); do
    path="${paths[index]}"
    scheduler_transaction_is_current || return 1
    [[ -f "${path}" && ! -L "${path}" \
        && "$(watchdog_file_identity "${path}" \
          2>/dev/null || true)" == "${ids[index]}" \
        && "$(watchdog_sha256_file "${path}" \
          2>/dev/null || true)" == "${hashes[index]}" \
        && "$(watchdog_file_mode "${path}" \
          2>/dev/null || true)" == "${modes[index]}" ]] || return 1
    rm -f -- "${path}" || return 1
    [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
  done
  scheduler_transaction_is_current || return 1
  rmdir "${SCHEDULER_TX_DIR}" || return 1
  SCHEDULER_TX_DIR=""
  SCHEDULER_TX_DIR_ID=""
  SCHEDULER_TX_PARENT_ID=""
}

watchdog_exit_handler() {
  local rc=$? cleanup_rc=0 transaction_may_retire=1
  set +e
  if [[ "${rc}" -ne 0 && "${SCHEDULER_TX_ARMED}" -eq 1 \
      && "${SCHEDULER_TX_COMMITTED}" -ne 1 ]]; then
    if ! rollback_scheduler_transaction; then
      printf 'WARNING: resume-watchdog scheduler rollback was incomplete; durable transaction retained.\n' >&2
      transaction_may_retire=0
      rc=1
    fi
  fi
  if [[ -n "${SCHEDULER_TX_DIR}" \
      && "${transaction_may_retire}" -eq 1 ]]; then
    # Flush either the committed generation or the completed rollback before
    # deleting the durable fail-closed marker. If durability cannot be proved,
    # retain the transaction so the next invocation cannot normalize a partial
    # generation into a new baseline.
    if [[ "${SCHEDULER_TX_ARMED}" -eq 1 ]] \
        && ! watchdog_scheduler_durable_barrier; then
      printf 'WARNING: scheduler durability barrier failed; durable transaction retained.\n' >&2
      cleanup_rc=1
      rc=1
    elif ! cleanup_scheduler_transaction; then
      printf 'WARNING: scheduler transaction scratch could not be exactly removed.\n' >&2
      cleanup_rc=1
    fi
  fi
  cleanup_private_recovery_helpers || cleanup_rc=$?
  if [[ "${cleanup_rc}" -ne 0 ]]; then
    printf 'WARNING: private watchdog recovery-helper snapshots could not be exactly removed.\n' >&2
    rc=1
  fi
  release_scheduler_lock
  release_operation_lock
  # Bash preserves the pre-EXIT-trap status when the trap merely returns, so
  # an exact-cleanup failure after an otherwise successful install would be
  # reported as success. Terminate explicitly with the cumulative status.
  trap - EXIT
  exit "${rc}"
}

trap watchdog_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_file() {
  if [[ ! -f "$1" || -L "$1" ]]; then
    printf 'ERROR: missing %s — run install.sh first.\n' "$1" >&2
    exit 1
  fi
}

snapshot_watchdog_source() {
  local source="${1:-}" key="${2:-}" output_var="${3:-}"
  local parent="" parent_id="" source_id="" source_hash="" source_mode=""
  local snapshot=""
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ \
      && "${output_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
      && -f "${source}" && ! -L "${source}" ]] || return 1
  parent="${source%/*}"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  parent_id="$(watchdog_directory_identity "${parent}")" || return 1
  source_id="$(watchdog_file_identity "${source}")" || return 1
  source_hash="$(watchdog_sha256_file "${source}")" || return 1
  source_mode="$(watchdog_file_mode "${source}")" || return 1
  snapshot="${SCHEDULER_TX_DIR}/${key}.source"
  cp -p -- "${source}" "${snapshot}" || return 1
  if [[ ! -f "${snapshot}" || -L "${snapshot}" \
      || "$(watchdog_sha256_file "${snapshot}" 2>/dev/null || true)" \
        != "${source_hash}" \
      || "$(watchdog_file_mode "${snapshot}" 2>/dev/null || true)" \
        != "${source_mode}" \
      || "$(watchdog_directory_identity "${parent}" \
          2>/dev/null || true)" != "${parent_id}" \
      || "$(watchdog_file_identity "${source}" \
          2>/dev/null || true)" != "${source_id}" \
      || "$(watchdog_sha256_file "${source}" 2>/dev/null || true)" \
        != "${source_hash}" \
      || "$(watchdog_file_mode "${source}" 2>/dev/null || true)" \
        != "${source_mode}" ]]; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  chmod 400 "${snapshot}" || return 1
  printf -v "${output_var}" '%s' "${snapshot}"
}

read_last_valid_conf_digest() {
  local key="${1:-}" line="" value="" result=""
  [[ "${key}" =~ ^[A-Za-z0-9_]+$ \
      && -f "${CONF_FILE}" && ! -L "${CONF_FILE}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ "${value}" =~ ^[0-9A-Fa-f]{64}$ ]] && result="${value}"
  done < "${CONF_FILE}"
  printf '%s' "${result}"
}

read_last_valid_scheduler_kind() {
  local line="" value="" result=""
  [[ -f "${CONF_FILE}" && ! -L "${CONF_FILE}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "resume_watchdog_scheduler="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "${value}" in
      launchd|systemd|cron|off) result="${value}" ;;
    esac
  done < "${CONF_FILE}"
  printf '%s' "${result}"
}

scheduler_artifact_is_owned() {
  local destination="${1:-}" provenance_key="${2:-}"
  local kind="${3:-}" live_source="${4:-}" expected="" actual=""
  local source_snapshot="" rendered="" historical_rendered="" mode=""
  scheduler_transaction_is_current || return 1
  [[ -f "${destination}" && ! -L "${destination}" ]] || return 1
  mode="$(watchdog_file_mode "${destination}" 2>/dev/null || true)"
  expected="$(read_last_valid_conf_digest "${provenance_key}")"
  actual="$(watchdog_sha256_file "${destination}")" || return 1
  if [[ -n "${expected}" ]]; then
    [[ "${mode}" == "600" && "${actual}" == "${expected}" ]]
    return $?
  fi
  # Compatibility for installs that predate durable provenance: compare
  # against a sealed invocation-private copy of the current template.
  snapshot_watchdog_source "${live_source}" \
    "legacy-${provenance_key}" source_snapshot || return 1
  rendered="$(mktemp "${SCHEDULER_TX_DIR}/legacy-render.XXXXXX")" \
    || return 1
  render_template_file "${kind}" "${source_snapshot}" "${rendered}" \
    || return 1
  chmod 600 "${rendered}" || return 1
  if [[ "${mode}" == "600" ]] && cmp -s "${rendered}" "${destination}"; then
    return 0
  fi
  # Releases before durable scheduler receipts wrote their rendered units
  # with the shell's ordinary 0644 redirection mode. Recognize only the
  # exact templates shipped by that release (including its unquoted systemd
  # ExecStart); marker-like text or a merely plausible unit is never enough.
  [[ "${mode}" == "644" ]] || return 1
  historical_rendered="$(mktemp \
    "${SCHEDULER_TX_DIR}/historical-render.XXXXXX")" || return 1
  render_known_historical_scheduler_artifact "${provenance_key}" \
    "${source_snapshot}" "${historical_rendered}" || return 1
  cmp -s "${historical_rendered}" "${destination}"
}

set_conf_value() {
  local key="$1" value="$2"
  local parent="${CONF_FILE%/*}" tmp="" source_snapshot=""
  local phase="initial" expected_hash="" source_mode="600" state=""
  local tmp_id="" tmp_hash="" tmp_mode="" grep_rc=0
  scheduler_transaction_is_current || return 1
  safe_scheduler_leaf "${CONF_FILE}" || {
    printf 'ERROR: refusing unsafe config target: %s\n' "${CONF_FILE}" >&2
    return 1
  }
  mkdir -p "${parent}"
  [[ -f "${SCHEDULER_TX_DIR}/conf.published-state" ]] \
    && phase="published"
  scheduler_path_seal_is_current conf "${CONF_FILE}" "${phase}" \
    || return 1
  state="$(watchdog_read_canonical_metadata_line \
    "${SCHEDULER_TX_DIR}/conf.${phase}-state" 32)" || return 1
  [[ "${state}" =~ ^(absent|present)$ ]] || return 1
  source_snapshot="$(mktemp "${SCHEDULER_TX_DIR}/conf-source.XXXXXX")" \
    || return 1
  if [[ "${state}" == "present" ]]; then
    expected_hash="$(watchdog_read_canonical_metadata_line \
      "${SCHEDULER_TX_DIR}/conf.${phase}-hash" 128)" || return 1
    source_mode="$(watchdog_read_canonical_metadata_line \
      "${SCHEDULER_TX_DIR}/conf.${phase}-mode" 16)" || return 1
    [[ "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
        && "${source_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    if ! cp -p -- "${CONF_FILE}" "${source_snapshot}" \
        || [[ "$(watchdog_sha256_file "${source_snapshot}" 2>/dev/null || true)" \
          != "${expected_hash}" ]] \
        || ! scheduler_path_seal_is_current conf "${CONF_FILE}" "${phase}"; then
      rm -f -- "${source_snapshot}"
      return 1
    fi
  else
    : > "${source_snapshot}" || return 1
    chmod 600 "${source_snapshot}" 2>/dev/null || true
  fi
  tmp="$(mktemp "${parent}/.oh-my-claude.conf.watchdog.XXXXXX")" || return 1
  if [[ "${state}" == "present" ]]; then
    # Drop existing key if present, then append. Mirrors install.sh's
    # set_conf semantics.
    grep -v -E "^${key}=" "${source_snapshot}" > "${tmp}" 2>/dev/null \
      || grep_rc=$?
    if [[ "${grep_rc}" -gt 1 ]]; then
      rm -f -- "${source_snapshot}" "${tmp}"
      return 1
    fi
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    chmod "${source_mode}" "${tmp}" || {
      rm -f -- "${source_snapshot}" "${tmp}"
      return 1
    }
  else
    printf '%s=%s\n' "${key}" "${value}" > "${tmp}"
    chmod 600 "${tmp}" 2>/dev/null || true
  fi
  rm -f -- "${source_snapshot}"
  tmp_id="$(watchdog_node_identity "${tmp}")" || return 1
  tmp_hash="$(watchdog_sha256_file "${tmp}")" || return 1
  tmp_mode="$(watchdog_file_mode "${tmp}")" || return 1
  watchdog_test_barrier \
    "${OMC_TEST_WATCHDOG_CONF_STAGE_READY_FILE:-}" \
    "${OMC_TEST_WATCHDOG_CONF_STAGE_RELEASE_FILE:-}" \
    "${CONF_FILE}" || { rm -f -- "${tmp}"; return 1; }
  if ! safe_scheduler_leaf "${CONF_FILE}" \
      || ! scheduler_path_seal_is_current conf "${CONF_FILE}" "${phase}" \
      || [[ ! -f "${tmp}" || -L "${tmp}" \
        || "$(watchdog_node_identity "${tmp}" 2>/dev/null || true)" \
          != "${tmp_id}" \
        || "$(watchdog_sha256_file "${tmp}" 2>/dev/null || true)" \
          != "${tmp_hash}" \
        || "$(watchdog_file_mode "${tmp}" 2>/dev/null || true)" \
          != "${tmp_mode}" ]] \
      || ! arm_scheduler_publication conf "${CONF_FILE}" \
        "${tmp_id}" "${tmp_hash}" "${tmp_mode}" \
      || ! mv -f -- "${tmp}" "${CONF_FILE}" \
      || ! record_scheduler_publication conf "${CONF_FILE}" \
        "${tmp_id}" "${tmp_hash}" "${tmp_mode}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
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
  # This value is rendered into launchd/systemd (and may originate in a login
  # shell). Reject every control byte instead of normalizing it: normalization
  # could make validation and publication reason about different strings.
  scheduler_render_value_is_safe "${result}" || return 1
  printf '%s' "${result}"
}

xml_escape() {
  local value="${1:-}" index=0 character=""
  while [[ "${index}" -lt "${#value}" ]]; do
    character="${value:index:1}"
    case "${character}" in
      '&') printf '&amp;' ;;
      '<') printf '&lt;' ;;
      '>') printf '&gt;' ;;
      '"') printf '&quot;' ;;
      "'") printf '&apos;' ;;
      *) printf '%s' "${character}" ;;
    esac
    index=$((index + 1))
  done
}

systemd_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  # Percent is a systemd specifier introducer even inside quotes.
  value="${value//%/%%}"
  printf '%s' "${value}"
}

render_template_file() {
  local kind="${1:-}" source="${2:-}" output="${3:-}"
  local home_value="" claude_value="" log_value="" path_value=""
  local raw_path="" line="" source_id="" source_hash="" source_mode=""
  [[ -f "${source}" && ! -L "${source}" && ! -L "${output}" ]] \
    || return 1
  scheduler_static_render_inputs_are_safe || return 1
  raw_path="$(resolved_path)" || return 1
  source_id="$(watchdog_file_identity "${source}")" || return 1
  source_hash="$(watchdog_sha256_file "${source}")" || return 1
  source_mode="$(watchdog_file_mode "${source}")" || return 1
  case "${kind}" in
    plist)
      home_value="$(xml_escape "${HOME}")"
      claude_value="$(xml_escape "${CLAUDE_HOME}")"
      log_value="$(xml_escape "${LOG_DIR}")"
      path_value="$(xml_escape "${raw_path}")"
      ;;
    systemd)
      home_value="$(systemd_escape "${HOME}")"
      claude_value="$(systemd_escape "${CLAUDE_HOME}")"
      log_value="$(systemd_escape "${LOG_DIR}")"
      path_value="$(systemd_escape "${raw_path}")"
      ;;
    *) return 1 ;;
  esac
  : > "${output}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//__OMC_HOME__/${claude_value}}"
    line="${line//__OMC_USER_HOME__/${home_value}}"
    line="${line//__OMC_LOG_DIR__/${log_value}}"
    line="${line//__OMC_PATH__/${path_value}}"
    printf '%s\n' "${line}" >> "${output}" || return 1
  done < "${source}"
  [[ -f "${source}" && ! -L "${source}" \
      && "$(watchdog_file_identity "${source}" 2>/dev/null || true)" \
        == "${source_id}" \
      && "$(watchdog_sha256_file "${source}" 2>/dev/null || true)" \
        == "${source_hash}" \
      && "$(watchdog_file_mode "${source}" 2>/dev/null || true)" \
        == "${source_mode}" ]]
}

render_known_historical_scheduler_artifact() {
  local provenance_key="${1:-}" source="${2:-}" output="${3:-}"
  local source_hash="" line="" path_value=""
  [[ -f "${source}" && ! -L "${source}" && ! -L "${output}" ]] \
    || return 1
  scheduler_static_render_inputs_are_safe || return 1
  source_hash="$(watchdog_sha256_file "${source}")" || return 1
  case "${provenance_key}:${source_hash}" in
    resume_watchdog_launchd_sha256:8e21306ce850c7cc52ac08832dfa2b08e98ca3d623732f6430f6a2ad3f512eb4|\
    resume_watchdog_systemd_timer_sha256:e48edde598951913d4ab99db26f82c895965e364dbe7b6adfa589fb8e092b907|\
    resume_watchdog_systemd_service_sha256:796a615f41956a32ba8cd163f2d99777b0d7039120608b66757500306afe1ca4|\
    resume_watchdog_systemd_service_sha256:c3cbc8ad73cd0e5b94ec8b2f2c7b18d2f55128d1948fd658922605dbbb5be158)
      ;;
    *) return 1 ;;
  esac
  path_value="$(resolved_path)" || return 1
  : > "${output}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${provenance_key}" \
        == "resume_watchdog_systemd_service_sha256" \
        && "${line}" \
          == 'ExecStart=/bin/bash "__OMC_HOME__/quality-pack/scripts/resume-watchdog.sh"' ]]; then
      line='ExecStart=/bin/bash __OMC_HOME__/quality-pack/scripts/resume-watchdog.sh'
    fi
    line="${line//__OMC_HOME__/${CLAUDE_HOME}}"
    line="${line//__OMC_USER_HOME__/${HOME}}"
    line="${line//__OMC_LOG_DIR__/${LOG_DIR}}"
    line="${line//__OMC_PATH__/${path_value}}"
    printf '%s\n' "${line}" >> "${output}" || return 1
  done < "${source}"
}

publish_scheduler_artifact() {
  local kind="${1:-}" source="${2:-}" destination="${3:-}" key="${4:-}"
  local parent="${destination%/*}" stage="" stage_id="" stage_hash=""
  local stage_mode=""
  local barrier_match="${OMC_TEST_WATCHDOG_ARTIFACT_STAGE_MATCH:-}"
  scheduler_transaction_is_current || return 1
  [[ "${key}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  scheduler_directory_seal_is_current "${key}" || return 1
  safe_scheduler_leaf "${destination}" || {
    printf 'ERROR: refusing unsafe scheduler artifact target: %s\n' \
      "${destination}" >&2
    return 1
  }
  scheduler_directory_seal_is_current "${key}" \
    && safe_scheduler_leaf "${destination}" \
    && scheduler_path_seal_is_current "${key}" "${destination}" initial \
    || return 1
  stage="$(mktemp "${parent}/.watchdog-render.XXXXXX")" || return 1
  if ! render_template_file "${kind}" "${source}" "${stage}"; then
    rm -f -- "${stage}"
    return 1
  fi
  chmod 600 "${stage}" 2>/dev/null || true
  stage_id="$(watchdog_node_identity "${stage}")" || return 1
  stage_hash="$(watchdog_sha256_file "${stage}")" || return 1
  stage_mode="$(watchdog_file_mode "${stage}")" || return 1
  if [[ -n "${barrier_match}" ]] \
      && [[ "${barrier_match}" == "${key}" \
        || "${barrier_match}" == "${destination}" ]]; then
    watchdog_test_barrier \
      "${OMC_TEST_WATCHDOG_ARTIFACT_STAGE_READY_FILE:-}" \
      "${OMC_TEST_WATCHDOG_ARTIFACT_STAGE_RELEASE_FILE:-}" \
      "${destination}" || { rm -f -- "${stage}"; return 1; }
  fi
  if ! scheduler_directory_seal_is_current "${key}" \
      || ! safe_scheduler_leaf "${destination}" \
      || ! scheduler_path_seal_is_current "${key}" "${destination}" initial \
      || [[ ! -f "${stage}" || -L "${stage}" \
        || "$(watchdog_node_identity "${stage}" 2>/dev/null || true)" \
          != "${stage_id}" \
        || "$(watchdog_sha256_file "${stage}" 2>/dev/null || true)" \
          != "${stage_hash}" \
        || "$(watchdog_file_mode "${stage}" 2>/dev/null || true)" \
          != "${stage_mode}" ]] \
      || ! arm_scheduler_publication "${key}" "${destination}" \
        "${stage_id}" "${stage_hash}" "${stage_mode}" \
      || ! mv -f -- "${stage}" "${destination}" \
      || [[ ! -f "${destination}" || -L "${destination}" \
        || "$(watchdog_node_identity "${destination}" 2>/dev/null || true)" \
          != "${stage_id}" \
        || "$(watchdog_sha256_file "${destination}" 2>/dev/null || true)" \
          != "${stage_hash}" \
        || "$(watchdog_file_mode "${destination}" 2>/dev/null || true)" \
          != "${stage_mode}" ]] \
      || ! record_scheduler_publication "${key}" "${destination}" \
        "${stage_id}" "${stage_hash}" "${stage_mode}"; then
    rm -f -- "${stage}"
    return 1
  fi
}

render_cron_line() {
  local quoted_script=""
  scheduler_static_render_inputs_are_safe || return 1
  printf -v quoted_script '%q' "${WATCHDOG_SCRIPT}"
  quoted_script="${quoted_script//%/\\%}"
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${quoted_script}"
}

render_previous_cron_line() {
  # The immediately preceding release used Bash %q but did not escape `%`
  # for cron's special stdin-splitting grammar.
  local quoted_script=""
  scheduler_static_render_inputs_are_safe || return 1
  printf -v quoted_script '%q' "${WATCHDOG_SCRIPT}"
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${quoted_script}"
}

render_raw_legacy_cron_line() {
  # An earlier short-lived format emitted the path raw. Both legacy forms are
  # recognized only beside the exact managed marker (or by a persisted
  # digest), so a user's manually-added watchdog line is not silently owned.
  scheduler_static_render_inputs_are_safe || return 1
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${WATCHDOG_SCRIPT}"
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

cron_line_is_owned() {
  local line="${1:-}" allow_marker_legacy="${2:-0}"
  local managed_line="" previous_line="" raw_line=""
  local expected_digest="" actual_digest=""
  managed_line="$(render_cron_line)" || return 1
  [[ "${line}" == "${managed_line}" ]] && return 0
  expected_digest="$(read_last_valid_conf_digest resume_watchdog_cron_sha256)"
  if [[ -n "${expected_digest}" ]]; then
    actual_digest="$(watchdog_sha256_text "${line}")" || return 1
    [[ "${actual_digest}" == "${expected_digest}" ]] && return 0
  fi
  if [[ "${allow_marker_legacy}" -eq 1 ]]; then
    previous_line="$(render_previous_cron_line)" || return 1
    [[ "${line}" == "${previous_line}" ]] && return 0
    raw_line="$(render_raw_legacy_cron_line)" || return 1
    [[ "${line}" == "${raw_line}" ]] && return 0
  fi
  return 1
}

strip_managed_cron_entries() {
  local current="${1:-}" line="" pending_marker=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${pending_marker}" -eq 1 ]]; then
      if cron_line_is_owned "${line}" 1; then
        pending_marker=0
        continue
      fi
      printf '%s\n' "${CRON_MARKER}"
      pending_marker=0
    fi
    if [[ "${line}" == "${CRON_MARKER}" ]]; then
      pending_marker=1
    elif ! cron_line_is_owned "${line}" 0; then
      printf '%s\n' "${line}"
    fi
  done <<< "${current}"
  [[ "${pending_marker}" -eq 0 ]] || printf '%s\n' "${CRON_MARKER}"
}

cron_has_managed_entry() {
  local current="${1:-}" line=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    cron_line_is_owned "${line}" 0 && return 0
  done <<< "${current}"
  return 1
}

cron_has_managed_marker() {
  local current="${1:-}" line="" previous=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${previous}" == "${CRON_MARKER}" ]] \
        && cron_line_is_owned "${line}" 1; then
      return 0
    fi
    previous="${line}"
  done <<< "${current}"
  return 1
}

write_crontab_contents() {
  local expected_contents="${1:-}" next_contents="${2:-}"
  local current_now=""
  if ! current_now="$(read_crontab_contents)"; then
    return 1
  fi
  if [[ "${current_now}" != "${expected_contents}" ]]; then
    printf 'WARNING: crontab changed concurrently; preserving the newer contents.\n' >&2
    return 75
  fi
  if ! printf '%s\n' "${next_contents}" | crontab -; then
    return 1
  fi
  current_now="$(read_crontab_contents)" || return 1
  [[ "${current_now}" == "${next_contents}" ]] || return 1
  CRON_LAST_PUBLISHED="${next_contents}"
  CRON_PUBLISHED=1
  watchdog_test_killpoint after-cron-publish
}

capture_cron_snapshot() {
  [[ "${CRON_SNAPSHOT_KNOWN}" -eq 0 ]] || return 0
  CRON_SNAPSHOT="$(read_crontab_contents)" || return 1
  CRON_SNAPSHOT_KNOWN=1
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

systemd_user_is_usable() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1
}

verify_scheduler_runtime_expectations() {
  local enabled_state="" active_state="" enabled_rc=0 active_rc=0
  case "${MACOS_RUNTIME_EXPECTATION}" in
    loaded)
      command -v launchctl >/dev/null 2>&1 \
        && launchctl print \
          "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" >/dev/null 2>&1 \
        || return 1
      ;;
    unloaded)
      command -v launchctl >/dev/null 2>&1 || return 1
      if launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
          >/dev/null 2>&1; then
        return 1
      fi
      ;;
  esac
  case "${LINUX_RUNTIME_EXPECTATION}" in
    active)
      systemd_user_is_usable || return 1
      enabled_state="$(systemctl --user is-enabled \
        oh-my-claude-resume-watchdog.timer 2>/dev/null)" || enabled_rc=$?
      active_state="$(systemctl --user is-active \
        oh-my-claude-resume-watchdog.timer 2>/dev/null)" || active_rc=$?
      [[ "${enabled_rc}" -eq 0 \
          && "${active_rc}" -eq 0 \
          && "${enabled_state}" =~ ^enabled(-runtime)?$ \
          && "${active_state}" == "active" ]] || return 1
      ;;
    inactive)
      systemd_user_is_usable || return 1
      enabled_state="$(systemctl --user is-enabled \
        oh-my-claude-resume-watchdog.timer 2>/dev/null)" || enabled_rc=$?
      active_state="$(systemctl --user is-active \
        oh-my-claude-resume-watchdog.timer 2>/dev/null)" || active_rc=$?
      [[ "${enabled_rc}" -ne 0 \
          && "${active_rc}" -ne 0 \
          && "${enabled_state}" =~ ^(disabled|masked|static|indirect|generated|transient|not-found)$ \
          && "${active_state}" =~ ^(inactive|failed|unknown)$ ]] || return 1
      ;;
  esac
}

macos_install() {
  local src="${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
  local source_snapshot=""
  scheduler_transaction_is_current || return 1
  require_file "${src}"
  snapshot_watchdog_source "${src}" macos-template source_snapshot \
    || return 1
  local dest_dir="${HOME}/Library/LaunchAgents"
  local dest="${MACOS_DEST}"
  command -v launchctl >/dev/null 2>&1 || return 1
  ensure_safe_scheduler_parent "${dest}" macos || return 1
  ensure_safe_scheduler_directory "${LOG_DIR}" watchdog-log || return 1
  snapshot_scheduler_path macos "${dest}" || return 1
  : > "${SCHEDULER_TX_DIR}/macos.snapshot"
  if launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" >/dev/null 2>&1; then
    MACOS_WAS_LOADED=1
  fi
  publish_scheduler_artifact plist "${source_snapshot}" "${dest}" macos \
    || return 1

  # Bootstrap into the user's gui domain. If already loaded, kickstart
  # to apply changes (idempotent — safe to re-run).
  if [[ "${MACOS_WAS_LOADED}" -eq 1 ]]; then
    if ! launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null; then
      printf 'WARNING: launchctl bootout failed; existing scheduler was left active.\n' >&2
      return 1
    fi
  fi
  launchctl bootstrap "gui/$(id -u)" "${dest}" 2>/dev/null || {
    printf 'WARNING: launchctl bootstrap failed — load manually with:\n  launchctl bootstrap gui/%s %s\n' "$(id -u)" "${dest}"
    return 1
  }
  launchctl kickstart -k "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null || true
  MACOS_RUNTIME_EXPECTATION="loaded"
  verify_scheduler_runtime_expectations || {
    printf 'WARNING: launchd job was not loaded after bootstrap.\n' >&2
    return 1
  }
  cleanup_cron_if_available_or_required || return 1
  printf 'macOS LaunchAgent installed at %s\n' "${dest}"
  printf 'Tail logs: tail -f %s/resume-watchdog.log\n' "${LOG_DIR}"
}

macos_uninstall() {
  local dest="${MACOS_DEST}"
  local src="${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
  local configured_scheduler="" cleanup_required=0
  scheduler_transaction_is_current || return 1
  configured_scheduler="$(read_last_valid_scheduler_kind)"
  snapshot_scheduler_path macos "${dest}" || return 1
  : > "${SCHEDULER_TX_DIR}/macos.snapshot"
  if [[ -e "${dest}" ]] \
      && ! scheduler_artifact_is_owned "${dest}" \
        resume_watchdog_launchd_sha256 plist "${src}"; then
    printf 'ERROR: refusing to delete modified/foreign LaunchAgent: %s\n' \
      "${dest}" >&2
    return 1
  fi
  if [[ "${configured_scheduler}" == "launchd" || -e "${dest}" ]]; then
    cleanup_required=1
  fi
  if [[ "${cleanup_required}" -eq 1 ]] \
      && ! command -v launchctl >/dev/null 2>&1; then
    printf 'ERROR: cannot prove LaunchAgent cleanup because `launchctl` is unavailable.\n' >&2
    return 1
  fi
  if command -v launchctl >/dev/null 2>&1 \
      && launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
        >/dev/null 2>&1; then
    cleanup_required=1
    if [[ ! -f "${dest}" ]]; then
      printf 'ERROR: refusing to unload a LaunchAgent with no owned on-disk artifact.\n' >&2
      return 1
    fi
    MACOS_WAS_LOADED=1
    launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null \
      || return 1
  fi
  if [[ "${cleanup_required}" -eq 1 ]]; then
    MACOS_RUNTIME_EXPECTATION="unloaded"
    verify_scheduler_runtime_expectations || {
      printf 'ERROR: launchd job remained loaded after cleanup.\n' >&2
      return 1
    }
  fi
  if [[ -e "${dest}" ]]; then
    safe_scheduler_leaf "${dest}" \
      && scheduler_path_seal_is_current macos "${dest}" initial \
      && arm_scheduler_publication macos "${dest}" absent \
      && rm -f -- "${dest}" \
      && record_scheduler_publication macos "${dest}" absent \
      || return 1
  fi
  printf 'macOS LaunchAgent removed.\n'
}

# --- Linux systemd user timer ---

linux_install() {
  local src_svc="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service"
  local src_tmr="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer"
  local service_snapshot="" timer_snapshot=""
  local configured_scheduler=""
  local dest_dir="${HOME}/.config/systemd/user"
  scheduler_transaction_is_current || return 1
  LINUX_INSTALLED_SCHEDULER=""

  if systemd_user_is_usable; then
    require_file "${src_svc}"
    require_file "${src_tmr}"
    snapshot_watchdog_source "${src_svc}" systemd-service-template \
      service_snapshot || return 1
    snapshot_watchdog_source "${src_tmr}" systemd-timer-template \
      timer_snapshot || return 1
    ensure_safe_scheduler_parent "${LINUX_SERVICE_DEST}" linux-service \
      || return 1
    ensure_safe_scheduler_parent "${LINUX_TIMER_DEST}" linux-timer \
      || return 1
    systemctl --user is-enabled oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && LINUX_WAS_ENABLED=1
    systemctl --user is-active oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && LINUX_WAS_ACTIVE=1
    snapshot_scheduler_path linux-service "${LINUX_SERVICE_DEST}" || return 1
    snapshot_scheduler_path linux-timer "${LINUX_TIMER_DEST}" || return 1
    : > "${SCHEDULER_TX_DIR}/linux.snapshot"
    publish_scheduler_artifact systemd "${service_snapshot}" \
      "${LINUX_SERVICE_DEST}" \
      linux-service \
      || return 1
    publish_scheduler_artifact systemd "${timer_snapshot}" \
      "${LINUX_TIMER_DEST}" \
      linux-timer \
      || return 1
    systemctl --user daemon-reload 2>/dev/null || return 1
    systemctl --user enable --now oh-my-claude-resume-watchdog.timer 2>/dev/null || {
      printf 'WARNING: systemctl --user enable failed — try manually:\n  systemctl --user daemon-reload\n  systemctl --user enable --now oh-my-claude-resume-watchdog.timer\n'
      return 1
    }
    LINUX_RUNTIME_EXPECTATION="active"
    verify_scheduler_runtime_expectations || {
      printf 'WARNING: systemd watchdog timer was not enabled and active after install.\n' >&2
      return 1
    }
    cleanup_cron_if_available_or_required || return 1
    LINUX_INSTALLED_SCHEDULER="systemd"
    printf 'Linux systemd user-timer installed at %s/\n' "${dest_dir}"
    printf 'Status: systemctl --user status oh-my-claude-resume-watchdog.timer\n'
    printf 'Logs:   journalctl --user -u oh-my-claude-resume-watchdog.service -f\n'
  else
    # Never silently create a second scheduler when a prior systemd
    # generation cannot be inspected or disabled. Fresh hosts may safely use
    # cron when the user manager is absent even if the systemctl binary exists.
    configured_scheduler="$(read_last_valid_scheduler_kind)"
    if [[ "${configured_scheduler}" == "systemd" \
        || -e "${LINUX_SERVICE_DEST}" || -L "${LINUX_SERVICE_DEST}" \
        || -e "${LINUX_TIMER_DEST}" || -L "${LINUX_TIMER_DEST}" ]]; then
      printf 'ERROR: systemctl --user is unusable and a systemd watchdog generation exists; refusing an unproved switch to cron.\n' >&2
      return 1
    fi
    printf 'systemctl --user is unavailable or unusable — falling back to cron.\n'
    cron_install || return 1
    LINUX_INSTALLED_SCHEDULER="cron"
  fi
  [[ "${LINUX_INSTALLED_SCHEDULER}" =~ ^(systemd|cron)$ ]]
}

linux_uninstall() {
  local src_svc="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service"
  local src_tmr="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer"
  local configured_scheduler="" cleanup_required=0
  scheduler_transaction_is_current || return 1
  configured_scheduler="$(read_last_valid_scheduler_kind)"
  snapshot_scheduler_path linux-service "${LINUX_SERVICE_DEST}" || return 1
  snapshot_scheduler_path linux-timer "${LINUX_TIMER_DEST}" || return 1
  : > "${SCHEDULER_TX_DIR}/linux.snapshot"
  if [[ -e "${LINUX_SERVICE_DEST}" ]] \
      && ! scheduler_artifact_is_owned "${LINUX_SERVICE_DEST}" \
        resume_watchdog_systemd_service_sha256 systemd "${src_svc}"; then
    printf 'ERROR: refusing to delete modified/foreign systemd watchdog service.\n' >&2
    return 1
  fi
  if [[ -e "${LINUX_TIMER_DEST}" ]] \
      && ! scheduler_artifact_is_owned "${LINUX_TIMER_DEST}" \
        resume_watchdog_systemd_timer_sha256 systemd "${src_tmr}"; then
    printf 'ERROR: refusing to delete modified/foreign systemd watchdog timer.\n' >&2
    return 1
  fi
  if [[ "${configured_scheduler}" == "systemd" \
      || -e "${LINUX_SERVICE_DEST}" || -e "${LINUX_TIMER_DEST}" ]]; then
    cleanup_required=1
  fi
  if [[ "${cleanup_required}" -eq 1 ]] \
      && ! systemd_user_is_usable; then
    printf 'ERROR: cannot prove systemd watchdog cleanup because `systemctl --user` is unavailable or unusable.\n' >&2
    return 1
  fi
  if systemd_user_is_usable; then
    systemctl --user is-enabled oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && LINUX_WAS_ENABLED=1
    systemctl --user is-active oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && LINUX_WAS_ACTIVE=1
    if [[ "${LINUX_WAS_ENABLED}" -eq 1 \
        || "${LINUX_WAS_ACTIVE}" -eq 1 ]]; then
      cleanup_required=1
    fi
    if [[ "${LINUX_WAS_ENABLED}" -eq 1 \
        || "${LINUX_WAS_ACTIVE}" -eq 1 ]]; then
      if [[ ! -e "${LINUX_SERVICE_DEST}" \
          && ! -e "${LINUX_TIMER_DEST}" ]]; then
        printf 'ERROR: refusing to disable a systemd timer with no owned on-disk artifact.\n' >&2
        return 1
      fi
      systemctl --user disable --now \
        oh-my-claude-resume-watchdog.timer 2>/dev/null || return 1
    fi
  fi
  if [[ "${cleanup_required}" -eq 1 ]]; then
    LINUX_RUNTIME_EXPECTATION="inactive"
    verify_scheduler_runtime_expectations || {
      printf 'ERROR: systemd timer remained enabled or active after cleanup.\n' >&2
      return 1
    }
  fi
  if [[ -e "${LINUX_SERVICE_DEST}" ]]; then
    safe_scheduler_leaf "${LINUX_SERVICE_DEST}" \
      && scheduler_path_seal_is_current linux-service \
        "${LINUX_SERVICE_DEST}" initial \
      && arm_scheduler_publication linux-service \
        "${LINUX_SERVICE_DEST}" absent \
      && rm -f -- "${LINUX_SERVICE_DEST}" \
      && record_scheduler_publication linux-service \
        "${LINUX_SERVICE_DEST}" absent \
      || return 1
  fi
  if [[ -e "${LINUX_TIMER_DEST}" ]]; then
    safe_scheduler_leaf "${LINUX_TIMER_DEST}" \
      && scheduler_path_seal_is_current linux-timer \
        "${LINUX_TIMER_DEST}" initial \
      && arm_scheduler_publication linux-timer \
        "${LINUX_TIMER_DEST}" absent \
      && rm -f -- "${LINUX_TIMER_DEST}" \
      && record_scheduler_publication linux-timer "${LINUX_TIMER_DEST}" absent \
      || return 1
  fi
  if systemd_user_is_usable; then
    systemctl --user daemon-reload 2>/dev/null || return 1
  fi
  printf 'Linux systemd user-timer removed.\n'
}

# --- cron fallback ---

cron_install() {
  local line=""
  local current=""
  local next_contents=""

  line="$(render_cron_line)"
  ensure_safe_scheduler_directory "${LOG_DIR}" watchdog-log || return 1

  if ! command -v crontab >/dev/null 2>&1; then
    printf 'ERROR: cron fallback selected, but `crontab` is not available.\n' >&2
    printf 'Add this line manually:\n  %s\n\n' "${line}"
    printf 'Once `crontab` is available, re-run this installer to register it automatically.\n'
    return 1
  fi

  if ! current="$(read_crontab_contents)"; then
    printf 'WARNING: could not read current crontab — add this line manually:\n  %s\n' "${line}"
    return 1
  fi
  capture_cron_snapshot || return 1

  next_contents="$(cron_install_block "${current}")"
  if ! write_crontab_contents "${current}" "${next_contents}"; then
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
    printf 'ERROR: cannot prove resume-watchdog cron cleanup because `crontab` is unavailable.\n' >&2
    return 1
  fi

  if ! current="$(read_crontab_contents)"; then
    printf 'WARNING: could not read current crontab — remove the watchdog entry manually.\n'
    return 1
  fi
  capture_cron_snapshot || return 1

  if ! cron_has_managed_entry "${current}" \
      && ! cron_has_managed_marker "${current}"; then
    return 0
  fi

  next_contents="$(strip_managed_cron_entries "${current}")"
  if ! write_crontab_contents "${current}" "${next_contents}"; then
    printf 'WARNING: could not remove the watchdog cron entry automatically.\n'
    return 1
  fi

  current="$(read_crontab_contents)" || return 1
  if cron_has_managed_entry "${current}" || cron_has_managed_marker "${current}"; then
    printf 'WARNING: managed watchdog cron block remains after cleanup.\n' >&2
    return 1
  fi

  printf 'Cron watchdog entry removed.\n'
}

cleanup_cron_if_available_or_required() {
  local configured_scheduler=""
  configured_scheduler="$(read_last_valid_scheduler_kind)"
  if command -v crontab >/dev/null 2>&1; then
    cron_uninstall
    return $?
  fi
  if [[ "${configured_scheduler}" == "cron" ]]; then
    printf 'ERROR: resume-watchdog was previously registered through cron, but `crontab` is unavailable for proven cleanup.\n' >&2
    return 1
  fi
  return 0
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
  local source_snapshot=""
  scheduler_transaction_is_current || return 1
  require_file "${src}"
  snapshot_watchdog_source "${src}" macos-reregister-template \
    source_snapshot || return 1
  local dest_dir="${HOME}/Library/LaunchAgents"
  local dest="${dest_dir}/dev.ohmyclaude.resume-watchdog.plist"
  ensure_safe_scheduler_parent "${dest}" macos || return 1
  ensure_safe_scheduler_directory "${LOG_DIR}" watchdog-log || return 1

  if ! command -v launchctl >/dev/null 2>&1; then
    return 1
  fi
  if launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
      >/dev/null 2>&1; then
    MACOS_WAS_LOADED=1
  fi
  snapshot_scheduler_path macos "${dest}" || return 1
  : > "${SCHEDULER_TX_DIR}/macos.snapshot"
  if [[ -e "${dest}" ]] \
      && ! scheduler_artifact_is_owned "${dest}" \
        resume_watchdog_launchd_sha256 plist "${source_snapshot}"; then
    printf 'reregister: refusing modified/foreign LaunchAgent: %s\n' \
      "${dest}" >&2
    return 1
  fi
  if [[ "${MACOS_WAS_LOADED}" -eq 1 && ! -f "${dest}" ]]; then
    printf 'reregister: refusing to replace a loaded LaunchAgent with no owned on-disk artifact\n' >&2
    return 1
  fi
  scheduler_path_seal_is_current macos "${dest}" initial || return 1
  publish_scheduler_artifact plist "${source_snapshot}" "${dest}" macos \
    || return 1
  set_conf_value "resume_watchdog_launchd_sha256" \
    "$(watchdog_sha256_file "${dest}")" || return 1
  # Bootout-if-loaded, then bootstrap. The bootstrap triggers the plist's
  # RunAtLoad tick (guarded safe by reregister_is_safe). NO explicit
  # `kickstart -k` — it only widens the claim window for no benefit here.
  if [[ "${MACOS_WAS_LOADED}" -eq 1 ]]; then
    launchctl bootout "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" 2>/dev/null \
      || return 1
  fi
  launchctl bootstrap "gui/$(id -u)" "${dest}" 2>/dev/null || return 1
  MACOS_RUNTIME_EXPECTATION="loaded"
  verify_scheduler_runtime_expectations || return 1
  return 0
}

linux_reregister() {
  local src_svc="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service"
  local src_tmr="${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer"
  local service_snapshot="" timer_snapshot=""
  local dest_dir="${HOME}/.config/systemd/user"
  local svc="${dest_dir}/oh-my-claude-resume-watchdog.service"
  local tmr="${dest_dir}/oh-my-claude-resume-watchdog.timer"
  local configured_scheduler=""
  scheduler_transaction_is_current || return 1
  safe_scheduler_leaf "${svc}" || return 1
  safe_scheduler_leaf "${tmr}" || return 1
  configured_scheduler="$(read_last_valid_scheduler_kind)"
  if ! systemd_user_is_usable; then
    if [[ "${configured_scheduler}" == "systemd" \
        || -e "${svc}" || -e "${tmr}" ]]; then
      printf 'reregister: systemd scheduler exists but `systemctl --user` is unavailable or unusable\n' >&2
      return 1
    fi
    # No systemd generation exists; a cron entry can heal independently.
    cron_reregister
    return $?
  fi
  # If the units were never installed, there is nothing to reregister via
  # systemd — fall back to cron semantics.
  if [[ ! -e "${svc}" && ! -L "${svc}" \
      && ! -e "${tmr}" && ! -L "${tmr}" ]]; then
    cron_reregister
    return $?
  fi
  if [[ ! -f "${svc}" || -L "${svc}" \
      || ! -f "${tmr}" || -L "${tmr}" ]]; then
    printf 'reregister: refusing incomplete/unsafe systemd watchdog units\n' >&2
    return 1
  fi
  require_file "${src_svc}"
  require_file "${src_tmr}"
  snapshot_watchdog_source "${src_svc}" systemd-reregister-service-template \
    service_snapshot || return 1
  snapshot_watchdog_source "${src_tmr}" systemd-reregister-timer-template \
    timer_snapshot || return 1
  ensure_safe_scheduler_parent "${svc}" linux-service || return 1
  ensure_safe_scheduler_parent "${tmr}" linux-timer || return 1
  systemctl --user is-enabled oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
    && LINUX_WAS_ENABLED=1
  systemctl --user is-active oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
    && LINUX_WAS_ACTIVE=1
  snapshot_scheduler_path linux-service "${svc}" || return 1
  snapshot_scheduler_path linux-timer "${tmr}" || return 1
  : > "${SCHEDULER_TX_DIR}/linux.snapshot"
  if ! scheduler_artifact_is_owned "${svc}" \
      resume_watchdog_systemd_service_sha256 systemd "${service_snapshot}" \
      || ! scheduler_artifact_is_owned "${tmr}" \
        resume_watchdog_systemd_timer_sha256 systemd "${timer_snapshot}" \
      || ! scheduler_path_seal_is_current linux-service "${svc}" initial \
      || ! scheduler_path_seal_is_current linux-timer "${tmr}" initial; then
    printf 'reregister: refusing modified/foreign systemd watchdog units\n' >&2
    return 1
  fi
  publish_scheduler_artifact systemd "${service_snapshot}" "${svc}" \
    linux-service || return 1
  publish_scheduler_artifact systemd "${timer_snapshot}" "${tmr}" \
    linux-timer || return 1
  set_conf_value "resume_watchdog_systemd_service_sha256" \
    "$(watchdog_sha256_file "${svc}")" || return 1
  set_conf_value "resume_watchdog_systemd_timer_sha256" \
    "$(watchdog_sha256_file "${tmr}")" || return 1
  systemctl --user daemon-reload 2>/dev/null || return 1
  # `enable --now` re-establishes the timer if it was disabled/stopped and
  # starts it immediately; idempotent if already active. The .timer's
  # Persistent=true catch-up tick is the systemd analogue of RunAtLoad and
  # is guarded safe by reregister_is_safe.
  systemctl --user enable --now oh-my-claude-resume-watchdog.timer 2>/dev/null \
    || return 1
  LINUX_RUNTIME_EXPECTATION="active"
  verify_scheduler_runtime_expectations \
    && scheduler_path_seal_is_current linux-service "${svc}" published \
    && scheduler_path_seal_is_current linux-timer "${tmr}" published
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
  if cron_has_managed_entry "${current}"; then
    printf 'cron: managed entry present; fires on schedule (nothing to restart)\n'
    return 0
  fi
  local next_contents=""
  next_contents="$(cron_install_block "${current}")"
  capture_cron_snapshot || return 1
  if ! write_crontab_contents "${current}" "${next_contents}"; then
    return 1
  fi
  set_conf_value "resume_watchdog_cron_sha256" \
    "$(watchdog_sha256_text "$(render_cron_line)")" || return 1
  printf 'cron: managed entry restored\n'
  return 0
}

# --- main ---

# Lock ordering is global operation lock, then watchdog scheduler lock. The
# uninstaller lends its already-owned operation token to this helper so nested
# cleanup cannot deadlock while still excluding an independent install.
if ! validate_scheduler_render_inputs; then
  printf 'ERROR: refusing unsafe scheduler render input (HOME, Claude paths, and effective PATH must be absolute where applicable and contain no control characters).\n' >&2
  exit 1
fi
# This early check makes a SIGKILL/power-loss residue fail quickly even when
# the killed process also stranded its operation lock. The second check under
# both mutation locks closes the race with a concurrently-starting operation.
assert_no_unsettled_scheduler_transaction
acquire_operation_lock
settle_shared_transactions || {
  printf 'ERROR: could not safely settle shared config/model recovery state before watchdog mutation.\n' >&2
  exit 1
}
acquire_scheduler_lock
assert_no_unsettled_scheduler_transaction
begin_scheduler_transaction

if [[ "${mode}" == "uninstall" ]]; then
  case "$(platform)" in
    macos)
      macos_uninstall
      cleanup_cron_if_available_or_required
      ;;
    linux)
      # Remove both known scheduler forms. A host may have installed the cron
      # fallback before systemctl became available; choosing only today's
      # platform command would leave that historical daemon live.
      linux_uninstall
      cleanup_cron_if_available_or_required
      ;;
    other) cleanup_cron_if_available_or_required ;;
  esac
  if [[ "${reset_conf}" -eq 1 ]]; then
    set_conf_value "resume_watchdog" "off"
    set_conf_value "resume_watchdog_scheduler" "off"
    printf 'Set resume_watchdog=off in %s\n' "${CONF_FILE}"
  fi
  verify_latest_scheduler_publications \
    && verify_scheduler_runtime_expectations || {
    printf 'ERROR: watchdog uninstall publication/runtime state changed before commit.\n' >&2
    exit 1
  }
  SCHEDULER_TX_COMMITTED=1
  exit 0
fi

require_file "${WATCHDOG_SCRIPT}"

if [[ "${mode}" == "reregister" ]]; then
  # Quiet self-heal path (invoked by session-start-watchdog-health.sh).
  # Does NOT touch the conf flag or claude_bin pin; it may refresh internal
  # artifact-ownership receipts. It does not print the activation banner — the
  # caller composes the user-facing message from the exit code and minimal
  # stdout.
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
  if [[ "${rr_rc}" -eq 0 ]]; then
    if verify_latest_scheduler_publications \
        && verify_scheduler_runtime_expectations; then
      SCHEDULER_TX_COMMITTED=1
    else
      printf 'reregister: published scheduler state changed before commit\n' >&2
      rr_rc=1
    fi
  fi
  exit "${rr_rc}"
fi

# Install path.
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
installed_scheduler=""
case "$(platform)" in
  macos) macos_install; installed_scheduler="launchd" ;;
  linux)
    linux_install
    installed_scheduler="${LINUX_INSTALLED_SCHEDULER}"
    ;;
  other) cron_install; installed_scheduler="cron" ;;
esac

# Publish config only after a scheduler has been installed successfully. A
# launchd RunAtLoad/systemd immediate tick before this point exits at the
# existing off guard; the next scheduled tick observes the committed config.
case "${installed_scheduler}" in
  launchd)
    set_conf_value "resume_watchdog_launchd_sha256" \
      "$(watchdog_sha256_file "${MACOS_DEST}")"
    ;;
  systemd)
    set_conf_value "resume_watchdog_systemd_service_sha256" \
      "$(watchdog_sha256_file "${LINUX_SERVICE_DEST}")"
    set_conf_value "resume_watchdog_systemd_timer_sha256" \
      "$(watchdog_sha256_file "${LINUX_TIMER_DEST}")"
    ;;
  cron)
    set_conf_value "resume_watchdog_cron_sha256" \
      "$(watchdog_sha256_text "$(render_cron_line)")"
    ;;
esac
set_conf_value "resume_watchdog" "on"
set_conf_value "resume_watchdog_scheduler" "${installed_scheduler}"
printf 'Set resume_watchdog=on in %s\n' "${CONF_FILE}"
if [[ -n "${claude_path}" ]] && [[ "${claude_path}" =~ ^/ ]]; then
  set_conf_value "claude_bin" "${claude_path}"
  printf 'Pinned claude_bin=%s in %s (PATH-hijack defense)\n' "${claude_path}" "${CONF_FILE}"
else
  printf 'NOTE: `claude` not on PATH; skipping claude_bin pin.\n'
  printf '      Watchdog will fall back to live `command -v claude` at launch.\n'
  printf '      Set claude_bin=<absolute path> manually in %s if PATH resolution at\n' "${CONF_FILE}"
  printf '      launch time is unreliable on this host.\n'
fi

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
  printf '\nERROR: watchdog self-test returned non-zero; scheduler/config changes will be rolled back.\n' >&2
  printf 'Inspect the script manually:\n  OMC_WATCHDOG_SELF_TEST=1 bash %s\n' \
    "${WATCHDOG_SCRIPT}" >&2
  exit 1
fi

verify_latest_scheduler_publications \
  && verify_scheduler_runtime_expectations || {
  printf '\nERROR: watchdog scheduler/config publication or runtime state changed before commit; changes will be rolled back.\n' >&2
  exit 1
}

SCHEDULER_TX_COMMITTED=1

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
