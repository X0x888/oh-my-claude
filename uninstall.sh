#!/usr/bin/env bash
#
# oh-my-claude uninstaller
#
# Cleanly removes oh-my-claude files from ~/.claude/ without touching
# user-created content, other hooks, or backup directories.
#
# Usage:
#   bash uninstall.sh           # interactive (asks for confirmation)
#   bash uninstall.sh --yes     # non-interactive (skip confirmation)
#   bash uninstall.sh --purge-quality-constitutions  # also remove user-owned taste data

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
CLAUDE_HOME="${TARGET_HOME}/.claude"
SETTINGS="${CLAUDE_HOME}/settings.json"
SETTINGS_PATCH="${SCRIPT_DIR}/config/settings.patch.json"
# Tests that need to exercise a corrupt/racing authority use an explicit seam;
# production callers cannot redefine ownership through ambient SETTINGS_PATCH.
if [[ "${OMC_TEST_UNINSTALL_ALLOW_SETTINGS_PATCH:-0}" == "1" ]]; then
  SETTINGS_PATCH="${OMC_TEST_UNINSTALL_SETTINGS_PATCH:-${SETTINGS_PATCH}}"
fi

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

AUTO_CONFIRM=false
PURGE_QUALITY_CONSTITUTIONS=false

for arg in "$@"; do
  case "${arg}" in
    --yes|-y)
      AUTO_CONFIRM=true
      ;;
    --purge-quality-constitutions)
      PURGE_QUALITY_CONSTITUTIONS=true
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: bash uninstall.sh [--yes] [--purge-quality-constitutions]\n' >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Destructive user-data preflight
# ---------------------------------------------------------------------------

QUALITY_CONSTITUTIONS_DIR="${CLAUDE_HOME}/omc-user/quality-constitutions"

SETTINGS_CLEANUP_ENGINE=""
SETTINGS_PHYSICAL_TARGET=""
SETTINGS_STAGE_PATH=""
SETTINGS_STAGE_COMMITTED=0
SETTINGS_SEAL_LEXICAL_KIND=""
SETTINGS_SEAL_LINK_TEXT=""
SETTINGS_SEAL_LEXICAL_PARENT_PATH=""
SETTINGS_SEAL_LEXICAL_PARENT_ID=""
SETTINGS_SEAL_LEXICAL_NODE_ID=""
SETTINGS_SEAL_PHYSICAL_PATH=""
SETTINGS_SEAL_TARGET_ID=""
SETTINGS_SEAL_PARENT_ID=""
SETTINGS_SEAL_HASH=""
SETTINGS_ORIGINAL_MODE=""
SETTINGS_SHA256_TOOL=""
SETTINGS_PATCH_SEAL_PATH=""
SETTINGS_PATCH_SEAL_TARGET_ID=""
SETTINGS_PATCH_SEAL_PARENT_ID=""
SETTINGS_PATCH_SEAL_HASH=""
SETTINGS_PATCH_SNAPSHOT=""
SETTINGS_PATCH_SNAPSHOT_TARGET_ID=""
SETTINGS_PATCH_SNAPSHOT_PARENT_ID=""
SETTINGS_PATCH_SNAPSHOT_HASH=""
SETTINGS_PATCH_SNAPSHOT_MODE=""
SETTINGS_STAGE_SEAL_PATH=""
SETTINGS_STAGE_SEAL_TARGET_ID=""
SETTINGS_STAGE_SEAL_NODE_ID=""
SETTINGS_STAGE_SEAL_PARENT_ID=""
SETTINGS_STAGE_SEAL_HASH=""
SETTINGS_STAGE_SEAL_MODE=""
SETTINGS_STAGE_CREATED_NODE_ID=""
SETTINGS_PUBLISHED_NODE_ID=""
SETTINGS_PUBLISHED_PARENT_ID=""
SETTINGS_PUBLISHED_HASH=""
SETTINGS_PUBLISHED_MODE=""
UNINSTALL_LOCK_DIR="${CLAUDE_HOME}/.install.lock"
UNINSTALL_LOCK_TOKEN=""
UNINSTALL_LOCK_HELD=0
UNINSTALL_LOCK_DIR_ID=""
UNINSTALL_LOCK_RELEASE_MARKER="${UNINSTALL_LOCK_DIR}/owner-released"
MANAGED_REMOVAL_SEALS_CAPTURED=0
MANAGED_REMOVAL_SEAL_FILE=""
MANAGED_REMOVAL_ANCESTOR_FILE=""
MANAGED_REMOVAL_TREE_FILE=""
MANAGED_REMOVAL_ENUM_FILE=""
MANAGED_REMOVAL_ENUM_FILE_ID=""
MANAGED_REMOVAL_SEAL_FILE_ID=""
MANAGED_REMOVAL_SEAL_FILE_HASH=""
MANAGED_REMOVAL_ANCESTOR_FILE_ID=""
MANAGED_REMOVAL_ANCESTOR_FILE_HASH=""
MANAGED_REMOVAL_TREE_FILE_ID=""
MANAGED_REMOVAL_TREE_FILE_HASH=""
MANAGED_REMOVAL_REFRESH_SEAL_FILE=""
MANAGED_REMOVAL_REFRESH_SEAL_FILE_ID=""
MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE=""
MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE_ID=""
TRANSACTION_RECOVERY_SNAPSHOT_DIR=""
TRANSACTION_RECOVERY_SNAPSHOT_DIR_ID=""
TRANSACTION_RECOVERY_SEALS=""
TRANSACTION_RECOVERY_SEALS_ID=""
TRANSACTION_RECOVERY_SEALS_HASH=""
TRANSACTION_RECOVERY_SEALS_MODE=""
TRANSACTION_RECOVERY_SWITCHER=""
TRANSACTION_RECOVERY_CONFIGURER=""
WATCHDOG_OUTER_ROLLBACK_DIR=""
WATCHDOG_OUTER_ROLLBACK_DIR_ID=""
WATCHDOG_OUTER_ROLLBACK_META=""
WATCHDOG_OUTER_ROLLBACK_PHASE="none"
WATCHDOG_OUTER_ROLLBACK_PREPARED=0
WATCHDOG_OUTER_ROLLBACK_POST_CAPTURED=0
WATCHDOG_OUTER_ROLLBACK_ARMED=0
WATCHDOG_OUTER_ROLLBACK_PATH_COUNT=0
WATCHDOG_OUTER_ROLLBACK_POST_COUNT=0
WATCHDOG_OUTER_ROLLBACK_KEYS=()
WATCHDOG_OUTER_ROLLBACK_PATHS=()
WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS=()
WATCHDOG_OUTER_ROLLBACK_PARENT_IDS=()
WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES=()
WATCHDOG_OUTER_ROLLBACK_INITIAL_IDS=()
WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES=()
WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES=()
WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS=()
WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS=()
WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES=()
WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES=()
WATCHDOG_OUTER_ROLLBACK_POST_STATES=()
WATCHDOG_OUTER_ROLLBACK_POST_IDS=()
WATCHDOG_OUTER_ROLLBACK_POST_HASHES=()
WATCHDOG_OUTER_ROLLBACK_POST_MODES=()
WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES=()
WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES=()
WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES=()
WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL=""
WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID=""
WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH=""
WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE=""
WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE="unavailable"
WATCHDOG_OUTER_ROLLBACK_CRON_POST=""
WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID=""
WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH=""
WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE=""
WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE="unavailable"
WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED=""
WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_ID=""
WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_HASH=""
WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_MODE=""
WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_STATE="unavailable"
WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED=0
WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED=0
WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE=0
WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH=""
WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID=""
WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH=""
WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED=0
WATCHDOG_OUTER_RECOVERY_ACTIVE=0
WATCHDOG_OUTER_RECOVERY_LOCK_ID=""
WATCHDOG_OUTER_RECOVERY_OWNER_PID=""
WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN=""
WATCHDOG_OUTER_RECOVERY_CLAIM=""
WATCHDOG_OUTER_RECOVERY_CLAIM_ID=""
WATCHDOG_OUTER_RECOVERY_CLAIM_TOKEN=""
WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE=""
WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE_NAME=""
WATCHDOG_OUTER_ROLLBACK_LOCK_ID=""
WATCHDOG_OUTER_ROLLBACK_OWNER_PID=""
WATCHDOG_OUTER_ROLLBACK_OWNER_TOKEN=""
WATCHDOG_OUTER_CAPTURED_PARENT_PATH=""
WATCHDOG_OUTER_CAPTURED_PARENT_ID=""
WATCHDOG_OUTER_CAPTURED_RELATIVE_TARGET=""

uninstall_test_barrier() {
  local ready="${1:-}" release="${2:-}" payload="${3:-ready}" attempt=0
  [[ "${OMC_TEST_UNINSTALL_BARRIER_ENABLE:-0}" == "1" ]] || return 0
  [[ -z "${ready}" && -z "${release}" ]] && return 0
  [[ "${ready}" == /* && "${release}" == /* ]] || return 1
  printf '%s\n' "${payload}" >"${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 6000 ]] || return 1
    sleep 0.01
  done
}

cleanup_uninstall_stage() {
  local cleanup_stage_path=""
  if settings_patch_snapshot_is_current 2>/dev/null; then
    rm -f -- "${SETTINGS_PATCH_SNAPSHOT}" 2>/dev/null || true
  fi
  remove_uninstall_lock_file_if_owned \
    "${MANAGED_REMOVAL_SEAL_FILE:-}" \
    "${MANAGED_REMOVAL_SEAL_FILE_ID:-}"
  remove_uninstall_lock_file_if_owned \
    "${MANAGED_REMOVAL_ANCESTOR_FILE:-}" \
    "${MANAGED_REMOVAL_ANCESTOR_FILE_ID:-}"
  remove_uninstall_lock_file_if_owned \
    "${MANAGED_REMOVAL_TREE_FILE:-}" \
    "${MANAGED_REMOVAL_TREE_FILE_ID:-}"
  remove_uninstall_lock_file_if_owned \
    "${MANAGED_REMOVAL_ENUM_FILE:-}" \
    "${MANAGED_REMOVAL_ENUM_FILE_ID:-}"
  remove_uninstall_lock_file_if_owned \
    "${MANAGED_REMOVAL_REFRESH_SEAL_FILE:-}" \
    "${MANAGED_REMOVAL_REFRESH_SEAL_FILE_ID:-}"
  remove_uninstall_lock_file_if_owned \
    "${MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE:-}" \
    "${MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE_ID:-}"
  if [[ -n "${TRANSACTION_RECOVERY_SNAPSHOT_DIR:-}" \
      && -d "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" \
      && ! -L "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" \
      && "$(portable_node_identity \
        "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" 2>/dev/null || true)" \
        == "${TRANSACTION_RECOVERY_SNAPSHOT_DIR_ID:-}" ]]; then
    rm -f -- "${TRANSACTION_RECOVERY_SWITCHER:-}" \
      "${TRANSACTION_RECOVERY_CONFIGURER:-}" \
      "${TRANSACTION_RECOVERY_SEALS:-}" 2>/dev/null || true
    rmdir "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" 2>/dev/null || true
  fi
  if [[ -n "${WATCHDOG_HELPER_SNAPSHOT_DIR:-}" \
      && -d "${WATCHDOG_HELPER_SNAPSHOT_DIR}" \
      && ! -L "${WATCHDOG_HELPER_SNAPSHOT_DIR}" \
      && "$(portable_node_identity "${WATCHDOG_HELPER_SNAPSHOT_DIR}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SNAPSHOT_DIR_ID:-}" ]]; then
    rm -f -- "${WATCHDOG_HELPER_SNAPSHOT:-}" 2>/dev/null || true
    rmdir "${WATCHDOG_HELPER_SNAPSHOT_DIR}" 2>/dev/null || true
  fi
  if [[ "${SETTINGS_STAGE_COMMITTED:-0}" -ne 1 \
      && -n "${SETTINGS_STAGE_PATH:-}" ]]; then
    for cleanup_stage_path in \
        "${SETTINGS_STAGE_PATH}" "${SETTINGS_STAGE_PATH}.ready"; do
      if [[ -n "${SETTINGS_STAGE_CREATED_NODE_ID:-}" \
          && -f "${cleanup_stage_path}" \
          && ! -L "${cleanup_stage_path}" \
          && "$(portable_node_identity "${cleanup_stage_path}" \
            2>/dev/null || true)" \
            == "${SETTINGS_STAGE_CREATED_NODE_ID}" ]]; then
        rm -f -- "${cleanup_stage_path}" 2>/dev/null || true
      fi
    done
  fi
  if [[ "${WATCHDOG_OUTER_ROLLBACK_ARMED:-0}" -eq 0 \
      && -n "${WATCHDOG_OUTER_ROLLBACK_DIR:-}" ]] \
      && [[ "$(type -t cleanup_watchdog_outer_rollback_snapshot \
        2>/dev/null || true)" == "function" ]]; then
    cleanup_watchdog_outer_rollback_snapshot || true
  fi
}

remove_uninstall_lock_file_if_owned() {
  local path="${1:-}" expected_id="${2:-}"
  [[ -n "${path}" && -n "${expected_id}" \
      && "${path}" == "${UNINSTALL_LOCK_DIR}/"* ]] || return 0
  uninstall_lock_generation_is_current || return 0
  [[ -f "${path}" && ! -L "${path}" \
      && "$(uninstall_lock_node_identity "${path}" \
        2>/dev/null || true)" == "${expected_id}" ]] || return 0
  rm -f -- "${path}" 2>/dev/null || true
}

# The shared lock is acquired before the general filesystem helpers below are
# defined, so keep this minimal identity reader beside the lock implementation.
uninstall_lock_node_identity() {
  local path="${1:-}"
  if stat -c '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -c '%d:%i' "${path}" 2>/dev/null
  elif stat -f '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -f '%d:%i' "${path}" 2>/dev/null
  else
    return 1
  fi
}

# Lock and rollback-WAL metadata is mutation authority. Validate the complete
# bounded byte stream before any record reaches Bash, then compare a byte-for-
# byte reconstruction so NUL stripping, CRs, extra/embedded lines, and
# concurrent replacement all fail closed.
uninstall_metadata_file_is_canonical() {
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

uninstall_read_canonical_metadata_snapshot() {
  local path="${1:-}" max_bytes="${2:-1048576}" snapshot=""
  uninstall_metadata_file_is_canonical "${path}" "${max_bytes}" || return 1
  snapshot="$(< "${path}")" 2>/dev/null || return 1
  [[ -n "${snapshot}" ]] || return 1
  printf '%s\n' "${snapshot}" | cmp -s - "${path}" 2>/dev/null || return 1
  printf '%s' "${snapshot}"
}

uninstall_read_canonical_metadata_line() {
  local path="${1:-}" max_bytes="${2:-4096}" record=""
  record="$(uninstall_read_canonical_metadata_snapshot \
    "${path}" "${max_bytes}")" || return 1
  [[ -n "${record}" && "${record}" != *$'\n'* ]] || return 1
  printf '%s' "${record}"
}

uninstall_read_canonical_tsv_snapshot() {
  local path="${1:-}" field_count="${2:-}" max_bytes="${3:-1048576}"
  local snapshot="" row="" rest="" field_index=0
  [[ "${field_count}" =~ ^([2-9]|[1-9][0-9])$ ]] || return 1
  snapshot="$(uninstall_read_canonical_metadata_snapshot \
    "${path}" "${max_bytes}")" || return 1
  while IFS= read -r row; do
    [[ -n "${row}" && "${row}" != $'\t'* \
        && "${row}" != *$'\t' && "${row}" != *$'\t\t'* ]] || return 1
    rest="${row}"
    for ((field_index=1; field_index<field_count; field_index++)); do
      [[ "${rest}" == *$'\t'* ]] || return 1
      rest="${rest#*$'\t'}"
    done
    [[ "${rest}" != *$'\t'* ]] || return 1
  done <<< "${snapshot}"
  printf '%s' "${snapshot}"
}

acquire_uninstall_lock() {
  [[ -d "${CLAUDE_HOME}" ]] || return 0
  local attempts=0 owner_pid="" recovery_rc=0
  while ! (umask 077; mkdir "${UNINSTALL_LOCK_DIR}") 2>/dev/null; do
    if uninstall_lock_reap_stranded_released_generation; then
      continue
    fi
    recovery_rc=0
    if [[ "$(type -t recover_stranded_watchdog_outer_transaction \
        2>/dev/null || true)" == "function" ]]; then
      recover_stranded_watchdog_outer_transaction || recovery_rc=$?
      case "${recovery_rc}" in
        0) continue ;;
        1) ;;
        *) return 1 ;;
      esac
    fi
    attempts=$((attempts + 1))
    owner_pid="$(uninstall_read_canonical_metadata_line \
      "${UNINSTALL_LOCK_DIR}/pid" 32 2>/dev/null || true)"
    if [[ "${attempts}" -ge 120 ]]; then
      printf 'Another oh-my-claude install/uninstall appears active (pid=%s, lock=%s).\n' \
        "${owner_pid:-unknown}" "${UNINSTALL_LOCK_DIR}" >&2
      printf 'If the owner is gone, inspect and remove this exact lock manually before retrying.\n' >&2
      printf 'First verify every participant.* PID is also gone; a child may still be using the borrowed lock.\n' >&2
      return 1
    fi
    # Do not reclaim pidless/dead locks: a live owner can be paused between
    # mkdir and metadata publication, and PID reuse is not an ownership token.
    sleep 0.25 2>/dev/null || sleep 1
  done
  if ! chmod 700 "${UNINSTALL_LOCK_DIR}" 2>/dev/null; then
    rmdir "${UNINSTALL_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  UNINSTALL_LOCK_TOKEN="$$.${RANDOM}.$(date +%s)"
  if ! (umask 077; set -o noclobber; \
      printf '%s\n' "$$" > "${UNINSTALL_LOCK_DIR}/pid" \
      && printf '%s\n' "${UNINSTALL_LOCK_TOKEN}" \
        > "${UNINSTALL_LOCK_DIR}/token") 2>/dev/null; then
    rm -f -- "${UNINSTALL_LOCK_DIR}/pid" "${UNINSTALL_LOCK_DIR}/token" \
      2>/dev/null || true
    rmdir "${UNINSTALL_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  UNINSTALL_LOCK_DIR_ID="$(uninstall_lock_node_identity \
    "${UNINSTALL_LOCK_DIR}")" || {
    rm -f -- "${UNINSTALL_LOCK_DIR}/pid" \
      "${UNINSTALL_LOCK_DIR}/token" 2>/dev/null || true
    rmdir "${UNINSTALL_LOCK_DIR}" 2>/dev/null || true
    return 1
  }
  UNINSTALL_LOCK_HELD=1
}

uninstall_lock_generation_matches() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  [[ "${lock_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${owner_pid}" =~ ^[1-9][0-9]{0,19}$ \
      && -n "${owner_token}" && "${owner_token}" != *[[:cntrl:]]* \
      && -d "${UNINSTALL_LOCK_DIR}" && ! -L "${UNINSTALL_LOCK_DIR}" \
      && "$(uninstall_lock_node_identity "${UNINSTALL_LOCK_DIR}" \
        2>/dev/null || true)" == "${lock_id}" \
      && -f "${UNINSTALL_LOCK_DIR}/pid" \
      && ! -L "${UNINSTALL_LOCK_DIR}/pid" \
      && -f "${UNINSTALL_LOCK_DIR}/token" \
      && ! -L "${UNINSTALL_LOCK_DIR}/token" \
      && "$(uninstall_read_canonical_metadata_line \
        "${UNINSTALL_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${owner_pid}" \
      && "$(uninstall_read_canonical_metadata_line \
        "${UNINSTALL_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${owner_token}" ]]
}

uninstall_lock_generation_is_current() {
  [[ "${UNINSTALL_LOCK_HELD:-0}" -eq 1 ]] \
    && uninstall_lock_generation_matches "${UNINSTALL_LOCK_DIR_ID:-}" \
      "$$" "${UNINSTALL_LOCK_TOKEN}"
}

uninstall_lock_release_marker_matches() {
  local marker_path="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" line=""
  [[ -n "${marker_path}" && -n "${lock_id}" && -n "${owner_pid}" \
      && -n "${owner_token}" && -f "${marker_path}" \
      && ! -L "${marker_path}" \
      && "$(portable_file_mode "${marker_path}" 2>/dev/null || true)" \
        == "600" ]] || return 1
  line="$(uninstall_read_canonical_metadata_line "${marker_path}" 1024)" \
    || return 1
  [[ "${line}" == $'v1\t'"${lock_id}"$'\t'"${owner_pid}"$'\t'"${owner_token}" ]]
}

uninstall_lock_publish_release_marker() {
  uninstall_lock_generation_is_current || return 1
  if [[ -e "${UNINSTALL_LOCK_RELEASE_MARKER}" \
      || -L "${UNINSTALL_LOCK_RELEASE_MARKER}" ]]; then
    uninstall_lock_release_marker_matches \
      "${UNINSTALL_LOCK_RELEASE_MARKER}" "${UNINSTALL_LOCK_DIR_ID}" \
      "$$" "${UNINSTALL_LOCK_TOKEN}"
    return
  fi
  if ! (umask 077; set -o noclobber; printf 'v1\t%s\t%s\t%s\n' \
      "${UNINSTALL_LOCK_DIR_ID}" "$$" "${UNINSTALL_LOCK_TOKEN}" \
      > "${UNINSTALL_LOCK_RELEASE_MARKER}") 2>/dev/null; then
    return 1
  fi
  chmod 600 "${UNINSTALL_LOCK_RELEASE_MARKER}" || return 1
  uninstall_lock_generation_is_current \
    && uninstall_lock_release_marker_matches \
      "${UNINSTALL_LOCK_RELEASE_MARKER}" "${UNINSTALL_LOCK_DIR_ID}" \
      "$$" "${UNINSTALL_LOCK_TOKEN}"
}

uninstall_lock_released_generation_is_exact() (
  local root="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" pid_id="${5:-}" token_id="${6:-}"
  local marker_id="${7:-}" entry=""
  local -a entries=()
  [[ -d "${root}" && ! -L "${root}" \
      && "$(uninstall_lock_node_identity "${root}" \
        2>/dev/null || true)" == "${lock_id}" ]] || return 1
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
      && "$(uninstall_lock_node_identity "${root}/pid" \
        2>/dev/null || true)" == "${pid_id}" \
      && "$(uninstall_read_canonical_metadata_line \
        "${root}/pid" 32 2>/dev/null || true)" == "${owner_pid}" \
      && -f "${root}/token" && ! -L "${root}/token" \
      && "$(uninstall_lock_node_identity "${root}/token" \
        2>/dev/null || true)" == "${token_id}" \
      && "$(uninstall_read_canonical_metadata_line \
        "${root}/token" 512 2>/dev/null || true)" == "${owner_token}" \
      && -f "${root}/owner-released" \
      && ! -L "${root}/owner-released" \
      && "$(uninstall_lock_node_identity "${root}/owner-released" \
        2>/dev/null || true)" == "${marker_id}" ]] || return 1
  uninstall_lock_release_marker_matches "${root}/owner-released" \
    "${lock_id}" "${owner_pid}" "${owner_token}"
)

uninstall_lock_retire_released_generation() {
  local lock_id="${1:-${UNINSTALL_LOCK_DIR_ID}}" owner_pid="${2:-$$}"
  local owner_token="${3:-${UNINSTALL_LOCK_TOKEN}}"
  local participant="" pid_id="" token_id="" marker_id=""
  local retired_root="" retired_root_id="" retired_lock=""
  [[ -e "${UNINSTALL_LOCK_RELEASE_MARKER}" \
      || -L "${UNINSTALL_LOCK_RELEASE_MARKER}" ]] || return 0
  uninstall_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  uninstall_lock_release_marker_matches \
    "${UNINSTALL_LOCK_RELEASE_MARKER}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" || return 1
  for participant in "${UNINSTALL_LOCK_DIR}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 0
  done
  pid_id="$(uninstall_lock_node_identity "${UNINSTALL_LOCK_DIR}/pid")" \
    || return 1
  token_id="$(uninstall_lock_node_identity "${UNINSTALL_LOCK_DIR}/token")" \
    || return 1
  marker_id="$(uninstall_lock_node_identity \
    "${UNINSTALL_LOCK_RELEASE_MARKER}")" || return 1
  uninstall_lock_released_generation_is_exact "${UNINSTALL_LOCK_DIR}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" \
    "${pid_id}" "${token_id}" "${marker_id}" || return 1

  retired_root="$(mktemp -d \
    "${CLAUDE_HOME}/.install-lock-retired.XXXXXX")" || return 1
  if ! chmod 700 "${retired_root}"; then
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  retired_root_id="$(uninstall_lock_node_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  if ! uninstall_lock_released_generation_is_exact \
      "${UNINSTALL_LOCK_DIR}" "${lock_id}" "${owner_pid}" \
      "${owner_token}" "${pid_id}" "${token_id}" \
      "${marker_id}"; then
    [[ "$(uninstall_lock_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  if ! command mv -- "${UNINSTALL_LOCK_DIR}" "${retired_lock}"; then
    [[ "$(uninstall_lock_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  # The public pathname may already contain a valid next generation. From
  # this point onward, validate and remove only the retired exact inode.
  [[ "$(uninstall_lock_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  uninstall_lock_released_generation_is_exact "${retired_lock}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" \
    "${pid_id}" "${token_id}" "${marker_id}" || return 1
  [[ "$(uninstall_lock_node_identity "${retired_lock}/pid" \
      2>/dev/null || true)" == "${pid_id}" ]] \
    && rm -f -- "${retired_lock}/pid" || return 1
  [[ "$(uninstall_lock_node_identity "${retired_lock}/token" \
      2>/dev/null || true)" == "${token_id}" ]] \
    && rm -f -- "${retired_lock}/token" || return 1
  [[ "$(uninstall_lock_node_identity "${retired_lock}/owner-released" \
      2>/dev/null || true)" == "${marker_id}" ]] \
    && uninstall_lock_release_marker_matches \
      "${retired_lock}/owner-released" "${lock_id}" \
      "${owner_pid}" "${owner_token}" \
    && rm -f -- "${retired_lock}/owner-released" || return 1
  rmdir "${retired_lock}" || return 1
  [[ "$(uninstall_lock_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  rmdir "${retired_root}"
}

uninstall_lock_reap_stranded_released_generation() {
  local lock_id="" owner_pid="" owner_token="" source_id=""
  [[ -d "${UNINSTALL_LOCK_DIR}" && ! -L "${UNINSTALL_LOCK_DIR}" \
      && -f "${UNINSTALL_LOCK_DIR}/pid" \
      && ! -L "${UNINSTALL_LOCK_DIR}/pid" \
      && -f "${UNINSTALL_LOCK_DIR}/token" \
      && ! -L "${UNINSTALL_LOCK_DIR}/token" \
      && -f "${UNINSTALL_LOCK_RELEASE_MARKER}" \
      && ! -L "${UNINSTALL_LOCK_RELEASE_MARKER}" ]] || return 1
  lock_id="$(uninstall_lock_node_identity "${UNINSTALL_LOCK_DIR}")" \
    || return 1
  owner_pid="$(uninstall_read_canonical_metadata_line \
    "${UNINSTALL_LOCK_DIR}/pid" 32)" || return 1
  owner_token="$(uninstall_read_canonical_metadata_line \
    "${UNINSTALL_LOCK_DIR}/token" 512)" || return 1
  uninstall_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  uninstall_lock_release_marker_matches "${UNINSTALL_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  uninstall_lock_retire_released_generation "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  source_id="$(uninstall_lock_node_identity "${UNINSTALL_LOCK_DIR}" \
    2>/dev/null || true)"
  [[ "${source_id}" != "${lock_id}" ]]
}

release_uninstall_lock() {
  [[ "${UNINSTALL_LOCK_HELD}" -eq 1 ]] || return 0
  if uninstall_lock_generation_is_current; then
    if ! uninstall_lock_publish_release_marker \
        || ! uninstall_lock_retire_released_generation; then
      printf 'WARNING: the exact released uninstall-lock generation could not be retired; it was preserved for manual inspection: %s\n' \
        "${UNINSTALL_LOCK_DIR}" >&2
    fi
  fi
  UNINSTALL_LOCK_HELD=0
}

uninstall_exit_handler() {
  local rc=$?
  set +e
  if [[ "${WATCHDOG_OUTER_RECOVERY_ACTIVE:-0}" -eq 1 ]]; then
    # Recovery borrows a dead owner's exact lock generation. Never run the
    # normal-owner cleanup path against that generation on interruption; drop
    # only this process's claim and leave the WAL replayable for the next run.
    watchdog_outer_release_recovery_claim 2>/dev/null || true
    WATCHDOG_OUTER_RECOVERY_ACTIVE=0
    return "${rc}"
  fi
  if [[ "${rc}" -ne 0 \
      && "${WATCHDOG_OUTER_ROLLBACK_ARMED:-0}" -eq 1 ]] \
      && [[ "$(type -t rollback_watchdog_outer_transaction \
        2>/dev/null || true)" == "function" ]]; then
    printf >&2 'Uninstall stopped after scheduler cleanup; restoring the exact pre-uninstall scheduler, config, and settings generation.\n'
    if rollback_watchdog_outer_transaction; then
      printf >&2 'Uninstall scheduler rollback complete. No harness files were removed.\n'
    else
      printf >&2 'WARNING: uninstall scheduler rollback was incomplete; the owned rollback snapshot and operation lock were preserved for inspection.\n'
      rc=1
    fi
  fi
  cleanup_uninstall_stage
  release_uninstall_lock
  return "${rc}"
}

trap uninstall_exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Validate a deletion path lexically rather than resolving it. Both `rm -rf
# parent/link/child` and `rm -f parent/link/file` traverse an intermediate
# symlink before removing the leaf. Refuse that shape before preview or any
# scheduler/filesystem mutation. Leaf symlinks are refused by default too;
# callers may explicitly allow one only for the managed ~/.local/bin/omc link,
# where rm removes the link itself and never follows it.
preflight_no_symlinked_path_components() {
  local path="${1:-}" allow_leaf_symlink="${2:-0}"
  local managed_root="${TARGET_HOME%/}" relative=""
  local component="" segment="" index=0 segment_count=0
  local -a path_segments

  [[ "${path}" == /* && "${path}" != *$'\n'* && "${path}" != *$'\r'* ]] || {
    printf 'Refusing uninstall through unsafe non-absolute path: %s\n' \
      "${path}" >&2
    return 1
  }
  if [[ -z "${managed_root}" || "${managed_root}" == "/" ]]; then
    printf 'Refusing uninstall with an unsafe TARGET_HOME boundary: %s\n' \
      "${TARGET_HOME}" >&2
    return 1
  fi

  # Paths managed below TARGET_HOME are anchored at that lexical boundary.
  # System roots such as macOS /var -> private/var and /tmp -> private/tmp are
  # outside the user's mutation authority and are commonly present in mktemp
  # paths; rejecting them makes every safe temp-home uninstall impossible.
  # The TARGET_HOME node itself is still checked, so a user-controlled home
  # alias cannot redirect the complete uninstall into an external tree.
  case "${path}" in
    "${managed_root}")
      if [[ -L "${managed_root}" ]]; then
        printf 'Refusing uninstall through symlinked path component: %s\n' \
          "${managed_root}" >&2
        return 1
      fi
      if [[ -e "${managed_root}" && ! -d "${managed_root}" ]]; then
        printf 'Refusing uninstall through non-directory path component: %s\n' \
          "${managed_root}" >&2
        return 1
      fi
      return 0
      ;;
    "${managed_root}"/*)
      if [[ -L "${managed_root}" ]]; then
        printf 'Refusing uninstall through symlinked path component: %s\n' \
          "${managed_root}" >&2
        return 1
      fi
      if [[ ! -d "${managed_root}" ]]; then
        printf 'Refusing uninstall through non-directory path component: %s\n' \
          "${managed_root}" >&2
        return 1
      fi
      component="${managed_root}"
      relative="${path#"${managed_root}"/}"
      ;;
    *)
      # Repository/git-hook authority may live outside TARGET_HOME. Retain the
      # conservative full lexical walk for those uncommon paths.
      component=""
      relative="${path#/}"
      ;;
  esac

  IFS='/' read -r -a path_segments <<<"${relative}"
  segment_count="${#path_segments[@]}"
  for segment in "${path_segments[@]}"; do
    [[ -n "${segment}" ]] || continue
    index=$((index + 1))
    case "${segment}" in
      .|..)
        printf 'Refusing uninstall through unsafe traversal component: %s\n' \
          "${segment}" >&2
        return 1
        ;;
    esac
    component="${component%/}/${segment}"
    if [[ -L "${component}" ]]; then
      if [[ "${allow_leaf_symlink}" -eq 1 && "${index}" -eq "${segment_count}" ]]; then
        continue
      fi
      printf 'Refusing uninstall through symlinked path component: %s\n' \
        "${component}" >&2
      return 1
    fi
    if [[ "${index}" -lt "${segment_count}" \
        && -e "${component}" && ! -d "${component}" ]]; then
      printf 'Refusing uninstall through non-directory path component: %s\n' \
        "${component}" >&2
      return 1
    fi
  done
}

preflight_quality_constitution_purge() {
  preflight_no_symlinked_path_components "${QUALITY_CONSTITUTIONS_DIR}" \
    || return 1
  if [[ "${MANAGED_REMOVAL_SEALS_CAPTURED:-0}" -eq 1 ]]; then
    managed_removal_path_seal_is_current "${QUALITY_CONSTITUTIONS_DIR}"
  fi
}

# Refuse an unsafe purge before install detection, preview, git-hook removal,
# settings cleanup, or any other mutation. A destructive option must be atomic
# on precondition failure even when the managed harness is also present.
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]]; then
  preflight_quality_constitution_purge || exit 1
fi

# Resolve a possibly symlinked settings file to the physical regular leaf while
# preserving the lexical link for publication. Parent components are
# canonicalized at every hop, so a relative target and a symlinked ancestor
# cannot make Python and jq publish to different objects. Missing/dangling,
# directory, FIFO, socket, and device nodes fail without ever being opened.
resolve_regular_file_physical_path() {
  local candidate="${1:-}" parent="" leaf="" physical_parent="" target=""
  local hops=0
  [[ "${candidate}" == /* && "${candidate}" != *$'\n'* \
      && "${candidate}" != *$'\r'* ]] || return 1
  while :; do
    parent="${candidate%/*}"
    leaf="${candidate##*/}"
    [[ -n "${parent}" ]] || parent="/"
    [[ -n "${leaf}" && "${leaf}" != "." && "${leaf}" != ".." ]] \
      || return 1
    physical_parent="$(cd "${parent}" 2>/dev/null && pwd -P)" || return 1
    candidate="${physical_parent%/}/${leaf}"
    if [[ -L "${candidate}" ]]; then
      hops=$((hops + 1))
      [[ "${hops}" -le 40 ]] || return 1
      target="$(readlink "${candidate}" 2>/dev/null)" || return 1
      [[ -n "${target}" && "${target}" != *$'\n'* \
          && "${target}" != *$'\r'* ]] || return 1
      case "${target}" in
        /*) candidate="${target}" ;;
        *) candidate="${physical_parent%/}/${target}" ;;
      esac
      continue
    fi
    [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
    printf '%s\n' "${candidate}"
    return 0
  done
}

portable_file_identity() {
  local path="${1:-}"
  if stat -c '%d:%i:%s:%Z' "${path}" >/dev/null 2>&1; then
    stat -c '%d:%i:%s:%Z' "${path}" 2>/dev/null
  elif stat -f '%d:%i:%z:%c' "${path}" >/dev/null 2>&1; then
    stat -f '%d:%i:%z:%c' "${path}" 2>/dev/null
  else
    return 1
  fi
}

portable_node_identity() {
  local path="${1:-}"
  if stat -c '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -c '%d:%i' "${path}" 2>/dev/null
  elif stat -f '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -f '%d:%i' "${path}" 2>/dev/null
  else
    return 1
  fi
}

portable_directory_identity() {
  local path="${1:-}"
  if stat -c '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -c '%d:%i' "${path}" 2>/dev/null
  elif stat -f '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -f '%d:%i' "${path}" 2>/dev/null
  else
    return 1
  fi
}

portable_file_mode() {
  local path="${1:-}"
  if stat -c '%a' "${path}" >/dev/null 2>&1; then
    stat -c '%a' "${path}" 2>/dev/null
  elif stat -f '%Lp' "${path}" >/dev/null 2>&1; then
    stat -f '%Lp' "${path}" 2>/dev/null
  else
    return 1
  fi
}

resolve_settings_sha256_tool() {
  local candidate="" resolved=""
  for candidate in /usr/bin/shasum /bin/shasum \
      /usr/bin/sha256sum /bin/sha256sum; do
    if [[ -f "${candidate}" && -x "${candidate}" && ! -L "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  for candidate in shasum sha256sum; do
    resolved="$(command -v "${candidate}" 2>/dev/null || true)"
    case "${resolved}" in
      /nix/store/*/bin/*)
        [[ -f "${resolved}" && -x "${resolved}" ]] || continue
        printf '%s\n' "${resolved}"
        return 0
        ;;
    esac
  done
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  return 1
}

settings_sha256_file() {
  local path="${1:-}" output="" digest=""
  case "${SETTINGS_SHA256_TOOL}" in
    python3)
      python3 - "${path}" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open("rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
      ;;
    */shasum)
      output="$("${SETTINGS_SHA256_TOOL}" -a 256 "${path}" 2>/dev/null)" \
        || return 1
      digest="${output%%[[:space:]]*}"
      [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
      printf '%s\n' "${digest}"
      ;;
    */sha256sum)
      output="$("${SETTINGS_SHA256_TOOL}" "${path}" 2>/dev/null)" \
        || return 1
      digest="${output%%[[:space:]]*}"
      [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
      printf '%s\n' "${digest}"
      ;;
    *) return 1 ;;
  esac
}

capture_settings_patch_seal() {
  local physical="" parent=""
  [[ -f "${SETTINGS_PATCH}" && ! -L "${SETTINGS_PATCH}" ]] || return 1
  physical="$(resolve_regular_file_physical_path \
    "${SETTINGS_PATCH}" 2>/dev/null)" || return 1
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_PATCH_SEAL_PATH="${physical}"
  SETTINGS_PATCH_SEAL_TARGET_ID="$(portable_file_identity "${physical}")" \
    || return 1
  SETTINGS_PATCH_SEAL_PARENT_ID="$(portable_directory_identity "${parent}")" \
    || return 1
  SETTINGS_PATCH_SEAL_HASH="$(settings_sha256_file "${physical}")" || return 1
  [[ "${SETTINGS_PATCH_SEAL_HASH}" =~ ^[0-9A-Fa-f]{64}$ ]]
}

settings_patch_seal_is_current() {
  local physical="" parent="" target_id="" parent_id="" digest=""
  [[ -f "${SETTINGS_PATCH}" && ! -L "${SETTINGS_PATCH}" ]] || return 1
  physical="$(resolve_regular_file_physical_path \
    "${SETTINGS_PATCH}" 2>/dev/null)" || return 1
  [[ "${physical}" == "${SETTINGS_PATCH_SEAL_PATH}" ]] || return 1
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  target_id="$(portable_file_identity "${physical}")" || return 1
  parent_id="$(portable_directory_identity "${parent}")" || return 1
  digest="$(settings_sha256_file "${physical}")" || return 1
  [[ "${target_id}" == "${SETTINGS_PATCH_SEAL_TARGET_ID}" \
      && "${parent_id}" == "${SETTINGS_PATCH_SEAL_PARENT_ID}" \
      && "${digest}" == "${SETTINGS_PATCH_SEAL_HASH}" ]]
}

capture_settings_patch_snapshot() {
  local parent="" copied_hash=""
  SETTINGS_PATCH_SNAPSHOT="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/settings-patch.XXXXXX")" || return 1
  [[ -f "${SETTINGS_PATCH_SNAPSHOT}" && ! -L "${SETTINGS_PATCH_SNAPSHOT}" ]] \
    || return 1
  cp -- "${SETTINGS_PATCH_SEAL_PATH}" "${SETTINGS_PATCH_SNAPSHOT}" \
    || return 1
  copied_hash="$(settings_sha256_file "${SETTINGS_PATCH_SNAPSHOT}")" \
    || return 1
  [[ "${copied_hash}" == "${SETTINGS_PATCH_SEAL_HASH}" ]] || return 1
  chmod 400 "${SETTINGS_PATCH_SNAPSHOT}" 2>/dev/null || return 1
  parent="${SETTINGS_PATCH_SNAPSHOT%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_PATCH_SNAPSHOT_TARGET_ID="$(portable_file_identity \
    "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  SETTINGS_PATCH_SNAPSHOT_PARENT_ID="$(portable_directory_identity \
    "${parent}")" || return 1
  SETTINGS_PATCH_SNAPSHOT_HASH="$(settings_sha256_file \
    "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  SETTINGS_PATCH_SNAPSHOT_MODE="$(portable_file_mode \
    "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  [[ "${SETTINGS_PATCH_SNAPSHOT_HASH}" == "${SETTINGS_PATCH_SEAL_HASH}" \
      && "${SETTINGS_PATCH_SNAPSHOT_MODE}" =~ ^0?400$ ]]
}

settings_patch_snapshot_is_current() {
  local parent="" target_id="" parent_id="" digest="" mode=""
  [[ -n "${SETTINGS_PATCH_SNAPSHOT}" \
      && -f "${SETTINGS_PATCH_SNAPSHOT}" \
      && ! -L "${SETTINGS_PATCH_SNAPSHOT}" ]] || return 1
  parent="${SETTINGS_PATCH_SNAPSHOT%/*}"
  [[ -n "${parent}" ]] || parent="/"
  target_id="$(portable_file_identity "${SETTINGS_PATCH_SNAPSHOT}")" \
    || return 1
  parent_id="$(portable_directory_identity "${parent}")" || return 1
  digest="$(settings_sha256_file "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  mode="$(portable_file_mode "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  [[ "${target_id}" == "${SETTINGS_PATCH_SNAPSHOT_TARGET_ID}" \
      && "${parent_id}" == "${SETTINGS_PATCH_SNAPSHOT_PARENT_ID}" \
      && "${digest}" == "${SETTINGS_PATCH_SNAPSHOT_HASH}" \
      && "${mode}" == "${SETTINGS_PATCH_SNAPSHOT_MODE}" ]]
}

# Exact hook ownership is derived from the repository's settings patch. Prove
# both JSON inputs and every shape the selected cleaner traverses before the
# preview. The complete cleaned document is rendered later (after style-name
# capture) but still before any external scheduler or managed-file mutation.
preflight_settings_cleanup_inputs() {
  local validation_rc=0
  if [[ ! -e "${SETTINGS}" && ! -L "${SETTINGS}" ]]; then
    return 0
  fi

  if ! SETTINGS_PHYSICAL_TARGET="$(resolve_regular_file_physical_path \
      "${SETTINGS}" 2>/dev/null)"; then
    printf 'Refusing to uninstall: settings.json is dangling or not a regular file: %s\n' \
      "${SETTINGS}" >&2
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    SETTINGS_CLEANUP_ENGINE="python"
  elif command -v jq >/dev/null 2>&1; then
    SETTINGS_CLEANUP_ENGINE="jq"
  else
    printf 'Refusing to uninstall: python3 or jq is required to clean settings.json before managed hooks are removed.\n' >&2
    return 1
  fi

  if [[ ! -f "${SETTINGS_PATCH}" || -L "${SETTINGS_PATCH}" ]]; then
    printf 'Refusing to uninstall: managed settings patch is missing or not a regular file: %s\n' \
      "${SETTINGS_PATCH}" >&2
    return 1
  fi

  SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool 2>/dev/null || true)"
  if [[ -z "${SETTINGS_SHA256_TOOL}" ]]; then
    printf 'Refusing to uninstall: a SHA-256 implementation is required to seal settings.json against concurrent replacement.\n' >&2
    return 1
  fi
  if ! capture_settings_patch_seal; then
    printf 'Refusing to uninstall: could not seal the managed settings patch before cleanup.\n' >&2
    return 1
  fi
  if ! capture_settings_patch_snapshot; then
    printf 'Refusing to uninstall: could not take a verified private managed-patch snapshot.\n' >&2
    return 1
  fi
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_PATCH_SNAPSHOT_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_PATCH_SNAPSHOT_RELEASE_FILE:-}" \
    "${SETTINGS_PATCH_SNAPSHOT}" || return 1

  if [[ "${SETTINGS_CLEANUP_ENGINE}" == "python" ]]; then
    python3 - "${SETTINGS_PHYSICAL_TARGET}" \
      "${SETTINGS_PATCH_SNAPSHOT}" <<'PY' \
      || validation_rc=$?
import json
import pathlib
import re
import sys

def reject_constant(value):
    raise ValueError(f"non-standard JSON constant: {value}")

def load(path):
    with pathlib.Path(path).open() as handle:
        return json.load(handle, parse_constant=reject_constant)

try:
    settings = load(sys.argv[1])
    patch = load(sys.argv[2])
except (OSError, ValueError) as exc:
    raise SystemExit(f"settings cleanup preflight failed: {exc}")

if not isinstance(settings, dict):
    raise SystemExit("settings cleanup preflight failed: settings root must be an object")
settings_hooks = settings.get("hooks")
if settings_hooks is not None and not isinstance(settings_hooks, dict):
    raise SystemExit("settings cleanup preflight failed: settings hooks must be an object or null")
if isinstance(settings_hooks, dict):
    for event, entries in settings_hooks.items():
        if not isinstance(event, str) or (entries is not None and not isinstance(entries, list)):
            raise SystemExit("settings cleanup preflight failed: hook events must map to arrays or null")
        for entry in entries or []:
            if entry is None:
                continue
            if not isinstance(entry, dict):
                raise SystemExit("settings cleanup preflight failed: hook entries must be objects or null")
            matcher = entry.get("matcher")
            if matcher is not None and not isinstance(matcher, str):
                raise SystemExit("settings cleanup preflight failed: hook matchers must be strings or null")
            hooks = entry.get("hooks")
            if hooks is not None and not isinstance(hooks, list):
                raise SystemExit("settings cleanup preflight failed: entry hooks must be arrays or null")
            for hook in hooks or []:
                if hook is None:
                    continue
                if not isinstance(hook, dict):
                    raise SystemExit("settings cleanup preflight failed: hooks must be objects or null")
                command = hook.get("command")
                if command is not None and not isinstance(command, str):
                    raise SystemExit("settings cleanup preflight failed: hook commands must be strings or null")
spinner = settings.get("spinnerVerbs")
if spinner is not None:
    if not isinstance(spinner, dict):
        raise SystemExit("settings cleanup preflight failed: spinnerVerbs must be an object or null")
    if spinner.get("mode") == "replace":
        verbs = spinner.get("verbs")
        if not isinstance(verbs, list) or not all(isinstance(item, str) for item in verbs):
            raise SystemExit("settings cleanup preflight failed: replacement spinner verbs must be strings")

if not isinstance(patch, dict):
    raise SystemExit("settings cleanup preflight failed: patch root must be an object")
if not isinstance(patch.get("statusLine"), dict):
    raise SystemExit("settings cleanup preflight failed: patch statusLine must be an object")
if not isinstance(patch.get("spinnerVerbs"), dict):
    raise SystemExit("settings cleanup preflight failed: patch spinnerVerbs must be an object")
if not isinstance(patch.get("spinnerTipsEnabled"), bool):
    raise SystemExit("settings cleanup preflight failed: patch spinnerTipsEnabled must be boolean")
if not isinstance(patch.get("effortLevel"), str):
    raise SystemExit("settings cleanup preflight failed: patch effortLevel must be a string")
patch_hooks = patch.get("hooks")
if not isinstance(patch_hooks, dict) or not patch_hooks:
    raise SystemExit("settings cleanup preflight failed: patch hooks must be a non-empty object")
command_pattern = re.compile(
    r"^(?:bash )?\$HOME/\.claude/"
    r"(?:skills/autowork|quality-pack)/scripts/"
    r"[A-Za-z0-9_-]+\.(?:sh|py)(?: [A-Za-z0-9_-]+)*$"
)
for event, entries in patch_hooks.items():
    if not isinstance(event, str) or not isinstance(entries, list) or not entries:
        raise SystemExit("settings cleanup preflight failed: patch hook events must map to non-empty arrays")
    for entry in entries:
        if not isinstance(entry, dict):
            raise SystemExit("settings cleanup preflight failed: patch hook entries must be objects")
        matcher = entry.get("matcher")
        if matcher is not None and not isinstance(matcher, str):
            raise SystemExit("settings cleanup preflight failed: patch hook matchers must be strings")
        hooks = entry.get("hooks")
        if not isinstance(hooks, list) or not hooks:
            raise SystemExit("settings cleanup preflight failed: patch entry hooks must be non-empty arrays")
        for hook in hooks:
            if not isinstance(hook, dict) or hook.get("type") != "command":
                raise SystemExit("settings cleanup preflight failed: patch hooks must be command objects")
            command = hook.get("command")
            if not isinstance(command, str) or not command:
                raise SystemExit("settings cleanup preflight failed: patch hook commands must be non-empty strings")
            if command_pattern.fullmatch(command) is None:
                raise SystemExit("settings cleanup preflight failed: unsupported patch hook command")
PY
  else
    jq -e '
      def valid_hook:
        . == null or (type == "object"
          and ((has("command") | not) or .command == null
            or (.command | type) == "string"));
      def valid_entry:
        . == null or (type == "object"
          and ((has("matcher") | not) or .matcher == null
            or (.matcher | type) == "string")
          and ((has("hooks") | not) or .hooks == null
            or ((.hooks | type) == "array"
              and all(.hooks[]; valid_hook))));
      def valid_event:
        (.key | type) == "string"
        and (.value == null or ((.value | type) == "array"
          and all(.value[]; valid_entry)));
      type == "object"
      and ((has("hooks") | not) or .hooks == null or (.hooks | type) == "object")
      and (((if (.hooks | type) == "object" then .hooks else {} end) | to_entries)
        | all(.[]; valid_event))
      and ((has("spinnerVerbs") | not) or .spinnerVerbs == null
        or ((.spinnerVerbs | type) == "object"
          and (.spinnerVerbs.mode != "replace"
            or ((.spinnerVerbs.verbs | type) == "array"
              and all(.spinnerVerbs.verbs[]; type == "string")))))
    ' "${SETTINGS_PHYSICAL_TARGET}" >/dev/null \
      && jq -e '
        type == "object"
        and (.statusLine | type) == "object"
        and (.spinnerVerbs | type) == "object"
        and (.spinnerTipsEnabled | type) == "boolean"
        and (.effortLevel | type) == "string"
        and (.hooks | type) == "object" and (.hooks | length) > 0
        and all(.hooks | to_entries[];
          (.key | type) == "string"
          and (.value | type) == "array" and (.value | length) > 0
          and all(.value[];
            type == "object"
            and ((has("matcher") | not) or (.matcher | type) == "string")
            and (.hooks | type) == "array" and (.hooks | length) > 0
            and all(.hooks[];
              type == "object"
              and .type == "command"
              and (.command | type) == "string" and (.command | length) > 0
              and (.command | test("^(?:bash )?[$]HOME/[.]claude/(?:skills/autowork|quality-pack)/scripts/[A-Za-z0-9_-]+[.](?:sh|py)(?: [A-Za-z0-9_-]+)*$")))))
      ' "${SETTINGS_PATCH_SNAPSHOT}" >/dev/null || validation_rc=$?
  fi
  if [[ "${validation_rc}" -ne 0 ]]; then
    printf 'Refusing to uninstall: settings or managed patch validation failed.\n' >&2
    return "${validation_rc}"
  fi
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_PATCH_VALIDATED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_PATCH_VALIDATED_RELEASE_FILE:-}" \
    "${SETTINGS_PATCH_SNAPSHOT}" || return 1
  if ! settings_patch_seal_is_current; then
    printf 'Refusing to uninstall: managed settings patch changed during preflight.\n' >&2
    return 1
  fi
  if ! settings_patch_snapshot_is_current; then
    printf 'Refusing to uninstall: private managed-patch snapshot changed during preflight.\n' >&2
    return 1
  fi
}

capture_settings_seal() {
  local lexical_parent="${SETTINGS%/*}" lexical_parent_physical=""
  local physical="" parent=""

  [[ -n "${lexical_parent}" ]] || lexical_parent="/"
  lexical_parent_physical="$(builtin cd -- "${lexical_parent}" \
    2>/dev/null && builtin pwd -P)" || return 1
  SETTINGS_SEAL_LEXICAL_PARENT_PATH="${lexical_parent_physical}"
  SETTINGS_SEAL_LEXICAL_PARENT_ID="$(portable_directory_identity \
    "${lexical_parent_physical}")" || return 1

  if [[ -L "${SETTINGS}" ]]; then
    SETTINGS_SEAL_LEXICAL_KIND="symlink"
    SETTINGS_SEAL_LINK_TEXT="$(readlink "${SETTINGS}" 2>/dev/null)" || return 1
  elif [[ -f "${SETTINGS}" ]]; then
    SETTINGS_SEAL_LEXICAL_KIND="regular"
    SETTINGS_SEAL_LINK_TEXT=""
  else
    return 1
  fi
  SETTINGS_SEAL_LEXICAL_NODE_ID="$(portable_node_identity "${SETTINGS}")" \
    || return 1

  physical="$(resolve_regular_file_physical_path "${SETTINGS}" 2>/dev/null)" \
    || return 1
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_PHYSICAL_TARGET="${physical}"
  SETTINGS_SEAL_PHYSICAL_PATH="${physical}"
  SETTINGS_SEAL_TARGET_ID="$(portable_file_identity "${physical}")" \
    || return 1
  SETTINGS_SEAL_PARENT_ID="$(portable_directory_identity "${parent}")" \
    || return 1
  SETTINGS_SEAL_HASH="$(settings_sha256_file "${physical}")" || return 1
  SETTINGS_ORIGINAL_MODE="$(portable_file_mode "${physical}")" || return 1
  [[ "${SETTINGS_SEAL_HASH}" =~ ^[0-9A-Fa-f]{64}$ \
      && "${SETTINGS_ORIGINAL_MODE}" =~ ^[0-7]{3,4}$ ]]
}

settings_seal_is_current() {
  local lexical_kind="" link_text="" lexical_node_id=""
  local lexical_parent="${SETTINGS%/*}" lexical_parent_physical=""
  local physical="" parent=""
  local target_id="" parent_id="" digest="" mode=""

  [[ -n "${lexical_parent}" ]] || lexical_parent="/"
  lexical_parent_physical="$(builtin cd -- "${lexical_parent}" \
    2>/dev/null && builtin pwd -P)" || return 1
  [[ "${lexical_parent_physical}" \
        == "${SETTINGS_SEAL_LEXICAL_PARENT_PATH}" \
      && "$(portable_directory_identity "${lexical_parent_physical}" \
        2>/dev/null || true)" == "${SETTINGS_SEAL_LEXICAL_PARENT_ID}" ]] \
    || return 1

  if [[ -L "${SETTINGS}" ]]; then
    lexical_kind="symlink"
    link_text="$(readlink "${SETTINGS}" 2>/dev/null)" || return 1
  elif [[ -f "${SETTINGS}" ]]; then
    lexical_kind="regular"
  else
    return 1
  fi
  lexical_node_id="$(portable_node_identity "${SETTINGS}")" || return 1
  [[ "${lexical_kind}" == "${SETTINGS_SEAL_LEXICAL_KIND}" \
      && "${link_text}" == "${SETTINGS_SEAL_LINK_TEXT}" \
      && "${lexical_node_id}" == "${SETTINGS_SEAL_LEXICAL_NODE_ID}" ]] \
    || return 1

  physical="$(resolve_regular_file_physical_path "${SETTINGS}" 2>/dev/null)" \
    || return 1
  [[ "${physical}" == "${SETTINGS_SEAL_PHYSICAL_PATH}" ]] || return 1
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  target_id="$(portable_file_identity "${physical}")" || return 1
  parent_id="$(portable_directory_identity "${parent}")" || return 1
  digest="$(settings_sha256_file "${physical}")" || return 1
  mode="$(portable_file_mode "${physical}")" || return 1
  [[ "${target_id}" == "${SETTINGS_SEAL_TARGET_ID}" \
      && "${parent_id}" == "${SETTINGS_SEAL_PARENT_ID}" \
      && "${digest}" == "${SETTINGS_SEAL_HASH}" \
      && "${mode}" == "${SETTINGS_ORIGINAL_MODE}" ]]
}

capture_settings_cleanup_stage_seal() {
  local parent="${SETTINGS_STAGE_PATH%/*}"
  [[ -n "${SETTINGS_STAGE_PATH}" && -f "${SETTINGS_STAGE_PATH}" \
      && ! -L "${SETTINGS_STAGE_PATH}" ]] || return 1
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_STAGE_SEAL_PATH="${SETTINGS_STAGE_PATH}"
  SETTINGS_STAGE_SEAL_TARGET_ID="$(portable_file_identity \
    "${SETTINGS_STAGE_PATH}")" || return 1
  SETTINGS_STAGE_SEAL_NODE_ID="$(portable_node_identity \
    "${SETTINGS_STAGE_PATH}")" || return 1
  SETTINGS_STAGE_SEAL_PARENT_ID="$(portable_directory_identity \
    "${parent}")" || return 1
  SETTINGS_STAGE_SEAL_HASH="$(settings_sha256_file \
    "${SETTINGS_STAGE_PATH}")" || return 1
  SETTINGS_STAGE_SEAL_MODE="$(portable_file_mode \
    "${SETTINGS_STAGE_PATH}")" || return 1
  [[ "${SETTINGS_STAGE_SEAL_HASH}" =~ ^[0-9A-Fa-f]{64}$ \
      && "${SETTINGS_STAGE_SEAL_MODE}" =~ ^[0-7]{3,4}$ ]]
}

settings_cleanup_stage_seal_is_current() {
  local parent="${SETTINGS_STAGE_PATH%/*}" target_id="" parent_id=""
  local digest="" mode=""
  [[ -n "${SETTINGS_STAGE_PATH}" \
      && "${SETTINGS_STAGE_PATH}" == "${SETTINGS_STAGE_SEAL_PATH}" \
      && -f "${SETTINGS_STAGE_PATH}" && ! -L "${SETTINGS_STAGE_PATH}" ]] \
    || return 1
  [[ -n "${parent}" ]] || parent="/"
  target_id="$(portable_file_identity "${SETTINGS_STAGE_PATH}")" \
    || return 1
  parent_id="$(portable_directory_identity "${parent}")" || return 1
  digest="$(settings_sha256_file "${SETTINGS_STAGE_PATH}")" || return 1
  mode="$(portable_file_mode "${SETTINGS_STAGE_PATH}")" || return 1
  [[ "${target_id}" == "${SETTINGS_STAGE_SEAL_TARGET_ID}" \
      && "${parent_id}" == "${SETTINGS_STAGE_SEAL_PARENT_ID}" \
      && "${digest}" == "${SETTINGS_STAGE_SEAL_HASH}" \
      && "${mode}" == "${SETTINGS_STAGE_SEAL_MODE}" ]]
}

stage_settings_cleanup() {
  local original_settings="${SETTINGS}" parent="" render_rc=0
  local copied_hash=""

  [[ -n "${SETTINGS_CLEANUP_ENGINE}" ]] || return 0
  if ! capture_settings_seal; then
    printf 'Refusing to uninstall: settings.json changed type or target after preflight. No managed files were removed.\n' >&2
    return 1
  fi
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current; then
    printf 'Refusing to uninstall: managed settings patch changed after preflight. No managed files were removed.\n' >&2
    return 1
  fi

  parent="${SETTINGS_PHYSICAL_TARGET%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_STAGE_PATH="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-uninstall.XXXXXX")" || {
      printf 'Refusing to uninstall: cannot stage settings cleanup beside physical target: %s\n' \
        "${SETTINGS_PHYSICAL_TARGET}" >&2
      return 1
    }
  SETTINGS_STAGE_CREATED_NODE_ID="$(portable_node_identity \
    "${SETTINGS_STAGE_PATH}")" || return 1
  if ! cp -p "${SETTINGS_PHYSICAL_TARGET}" "${SETTINGS_STAGE_PATH}"; then
    printf 'Refusing to uninstall: could not snapshot settings.json into its publication directory.\n' >&2
    return 1
  fi
  copied_hash="$(settings_sha256_file "${SETTINGS_STAGE_PATH}")" || return 1
  if [[ "${copied_hash}" != "${SETTINGS_SEAL_HASH}" ]]; then
    printf 'Refusing to uninstall: the staged settings snapshot does not match the sealed original. No managed files were removed.\n' >&2
    return 1
  fi

  SETTINGS="${SETTINGS_STAGE_PATH}"
  if [[ "${SETTINGS_CLEANUP_ENGINE}" == "python" ]]; then
    clean_settings_python || render_rc=$?
  else
    clean_settings_jq || render_rc=$?
  fi
  SETTINGS="${original_settings}"
  if [[ "${render_rc}" -ne 0 ]]; then
    printf 'Refusing to uninstall: could not render the complete settings cleanup. No managed files were removed.\n' >&2
    return "${render_rc}"
  fi
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_PATCH_RENDER_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_PATCH_RENDER_RELEASE_FILE:-}" \
    "${SETTINGS_STAGE_PATH}" || return 1
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current; then
    printf 'Refusing to uninstall: managed settings patch changed during cleanup rendering. No managed files were removed.\n' >&2
    return 1
  fi

  chmod "${SETTINGS_ORIGINAL_MODE}" "${SETTINGS_STAGE_PATH}" 2>/dev/null || {
    printf 'Refusing to uninstall: could not preserve settings.json mode on the staged cleanup.\n' >&2
    return 1
  }
  if [[ ! -f "${SETTINGS_STAGE_PATH}" || -L "${SETTINGS_STAGE_PATH}" ]]; then
    printf 'Refusing to uninstall: rendered settings stage is not a safe regular file.\n' >&2
    return 1
  fi
  if [[ "${SETTINGS_CLEANUP_ENGINE}" == "python" ]]; then
    if ! python3 - "${SETTINGS_STAGE_PATH}" <<'PY' >/dev/null
import json
import pathlib
import sys

def reject_constant(value):
    raise ValueError(value)

with pathlib.Path(sys.argv[1]).open() as handle:
    value = json.load(handle, parse_constant=reject_constant)
if not isinstance(value, dict):
    raise SystemExit(1)
PY
    then
      printf 'Refusing to uninstall: Python rendered an invalid settings cleanup stage.\n' >&2
      return 1
    fi
  else
    if ! jq -e 'type == "object"' "${SETTINGS_STAGE_PATH}" >/dev/null; then
      printf 'Refusing to uninstall: jq rendered an invalid settings cleanup stage.\n' >&2
      return 1
    fi
  fi

  # Exercise two same-directory renames before any destructive operation. The
  # final publication is the same primitive, replacing the sealed physical
  # target rather than the lexical symlink.
  mv "${SETTINGS_STAGE_PATH}" "${SETTINGS_STAGE_PATH}.ready" || return 1
  mv "${SETTINGS_STAGE_PATH}.ready" "${SETTINGS_STAGE_PATH}" || return 1

  if ! capture_settings_cleanup_stage_seal; then
    printf 'Refusing to uninstall: could not seal the rendered settings cleanup stage.\n' >&2
    return 1
  fi
  # jq publishes its rendered output over the original mktemp inode. From
  # this point onward, cleanup and the durable outer WAL own the sealed
  # rendered inode, not the placeholder identity captured before rendering.
  SETTINGS_STAGE_CREATED_NODE_ID="${SETTINGS_STAGE_SEAL_NODE_ID}"

  if ! settings_seal_is_current; then
    printf 'Refusing to uninstall: settings.json changed while its cleanup was staged. No managed files were removed.\n' >&2
    return 1
  fi
}

publish_staged_settings_cleanup() {
  local lexical_parent="${SETTINGS%/*}" lexical_parent_physical=""
  local physical=""
  [[ -n "${SETTINGS_STAGE_PATH}" ]] || return 0
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_SETTINGS_STAGE_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_SETTINGS_STAGE_RELEASE_FILE:-}" \
    "${SETTINGS_STAGE_PATH}" || return 1
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current; then
    printf 'Uninstall stopped before settings publication because the managed-patch authority changed.\n' >&2
    return 1
  fi
  if ! settings_seal_is_current; then
    printf 'Uninstall stopped before settings publication because settings.json was edited or its symlink target changed.\n' >&2
    printf 'The concurrent user version was preserved; rerun uninstall.sh to clean the remaining settings safely.\n' >&2
    return 1
  fi
  if ! settings_cleanup_stage_seal_is_current; then
    printf 'Uninstall stopped before settings publication because the rendered cleanup stage was replaced or modified.\n' >&2
    return 1
  fi
  if ! mv -f "${SETTINGS_STAGE_PATH}" "${SETTINGS_SEAL_PHYSICAL_PATH}"; then
    printf 'Failed to publish the staged settings cleanup to physical target: %s\n' \
      "${SETTINGS_SEAL_PHYSICAL_PATH}" >&2
    printf 'Your original settings seal was preserved. Repair the target directory and rerun uninstall.sh.\n' >&2
    return 1
  fi
  SETTINGS_STAGE_COMMITTED=1
  SETTINGS_PUBLISHED_NODE_ID="${SETTINGS_STAGE_SEAL_NODE_ID}"
  SETTINGS_PUBLISHED_PARENT_ID="${SETTINGS_STAGE_SEAL_PARENT_ID}"
  SETTINGS_PUBLISHED_HASH="${SETTINGS_STAGE_SEAL_HASH}"
  SETTINGS_PUBLISHED_MODE="${SETTINGS_STAGE_SEAL_MODE}"
  if [[ "${SETTINGS_SEAL_LEXICAL_KIND}" == "symlink" ]]; then
    [[ -n "${lexical_parent}" ]] || lexical_parent="/"
    lexical_parent_physical="$(builtin cd -- "${lexical_parent}" \
      2>/dev/null && builtin pwd -P)" || return 1
    [[ "${lexical_parent_physical}" \
          == "${SETTINGS_SEAL_LEXICAL_PARENT_PATH}" \
        && "$(portable_directory_identity "${lexical_parent_physical}" \
          2>/dev/null || true)" == "${SETTINGS_SEAL_LEXICAL_PARENT_ID}" \
        && -L "${SETTINGS}" \
        && "$(portable_node_identity "${SETTINGS}" \
          2>/dev/null || true)" == "${SETTINGS_SEAL_LEXICAL_NODE_ID}" \
        && "$(readlink "${SETTINGS}" 2>/dev/null || true)" \
          == "${SETTINGS_SEAL_LINK_TEXT}" ]] || return 1
    physical="$(resolve_regular_file_physical_path "${SETTINGS}" \
      2>/dev/null)" || return 1
    [[ "${physical}" == "${SETTINGS_SEAL_PHYSICAL_PATH}" ]] || return 1
  fi
  if [[ ! -f "${SETTINGS_SEAL_PHYSICAL_PATH}" \
      || -L "${SETTINGS_SEAL_PHYSICAL_PATH}" \
      || "$(portable_directory_identity \
          "${SETTINGS_SEAL_PHYSICAL_PATH%/*}" 2>/dev/null || true)" \
        != "${SETTINGS_PUBLISHED_PARENT_ID}" \
      || "$(portable_node_identity "${SETTINGS_SEAL_PHYSICAL_PATH}" \
          2>/dev/null || true)" != "${SETTINGS_PUBLISHED_NODE_ID}" \
      || "$(settings_sha256_file "${SETTINGS_SEAL_PHYSICAL_PATH}" \
          2>/dev/null || true)" != "${SETTINGS_PUBLISHED_HASH}" \
      || "$(portable_file_mode "${SETTINGS_SEAL_PHYSICAL_PATH}" \
          2>/dev/null || true)" != "${SETTINGS_PUBLISHED_MODE}" ]]; then
    printf 'Uninstall stopped after settings publication because the published leaf was concurrently replaced or modified. Managed files remain installed.\n' >&2
    return 1
  fi
  # The post-captured receipt already carries the exact rendered-settings
  # identity, so a crash here is recoverable even though the phase has not yet
  # advanced. Keep this seam at the otherwise unavoidable publication/receipt
  # boundary and cover it explicitly with SIGKILL recovery tests.
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_UNRECORDED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_UNRECORDED_RELEASE_FILE:-}" \
    "${WATCHDOG_OUTER_ROLLBACK_DIR:-${SETTINGS_SEAL_PHYSICAL_PATH}}" \
    || return 1
  if [[ "${WATCHDOG_OUTER_ROLLBACK_PREPARED:-0}" -eq 1 ]]; then
    watchdog_outer_publish_meta settings-published || {
      printf 'Uninstall stopped after settings publication because the durable scheduler rollback receipt could not advance. Managed files remain installed.\n' >&2
      return 1
    }
    uninstall_test_barrier \
      "${OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_READY_FILE:-}" \
      "${OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_RELEASE_FILE:-}" \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
  fi
  SETTINGS_STAGE_PATH=""
  removed+=("Cleaned settings.json: removed oh-my-claude hooks and keys")
}

settings_contains_managed_residue() {
  [[ -n "${SETTINGS_CLEANUP_ENGINE}" \
      && -n "${SETTINGS_PHYSICAL_TARGET}" ]] || return 1
  if [[ "${SETTINGS_CLEANUP_ENGINE}" == "python" ]]; then
    python3 - "${SETTINGS_PHYSICAL_TARGET}" \
      "${SETTINGS_PATCH_SNAPSHOT}" <<'PY'
import json
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open() as handle:
    settings = json.load(handle)
with pathlib.Path(sys.argv[2]).open() as handle:
    patch = json.load(handle)

expected_by_event = {}
for event, entries in (patch.get("hooks") or {}).items():
    expected_by_event[event] = [
        ({key: value for key, value in entry.items() if key != "hooks"},
         [hook for hook in (entry.get("hooks") or []) if isinstance(hook, dict)])
        for entry in entries or [] if isinstance(entry, dict)
    ]
expected_by_event.setdefault("SessionStart", []).append(({}, [
    {"type": "command", "command": "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-resume.sh"},
    {"type": "command", "command": "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh"},
]))

has_hook = False
for event, entries in (settings.get("hooks") or {}).items():
    for entry in entries or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            continue
        contract = {key: value for key, value in entry.items() if key != "hooks"}
        managed_hooks = [
            hook
            for expected_contract, hooks in expected_by_event.get(event, [])
            if contract == expected_contract
            for hook in hooks
        ]
        if any(hook in managed_hooks for hook in entry["hooks"]):
            has_hook = True
            break
    if has_hook:
        break
permissions = settings.get("permissions")
has_bypass = (
    isinstance(permissions, dict)
    and permissions.get("defaultMode") == "bypassPermissions"
) or settings.get("skipDangerousModePermissionPrompt") is True
has_owned_value = any((
    settings.get("statusLine") == patch.get("statusLine"),
    settings.get("effortLevel") == patch.get("effortLevel"),
    settings.get("spinnerTipsEnabled") == patch.get("spinnerTipsEnabled"),
    settings.get("spinnerVerbs") == patch.get("spinnerVerbs"),
    settings.get("outputStyle") in {
        "oh-my-claude", "executive-brief", "OpenCode Compact",
    },
))
raise SystemExit(0 if has_hook or has_bypass or has_owned_value else 1)
PY
  else
    jq -e --slurpfile patch "${SETTINGS_PATCH_SNAPSHOT}" '
      . as $settings
      | def hook_tuples($hooks):
          [($hooks // {}) | to_entries[] as $event
            | ($event.value // [])[]? as $entry
            | select(($entry | type) == "object"
                and (($entry.hooks | type) == "array"))
            | $entry.hooks[]? as $hook
            | select(($hook | type) == "object")
            | {event: $event.key, contract: ($entry | del(.hooks)), hook: $hook}];
        hook_tuples($settings.hooks) as $actual
      | (hook_tuples($patch[0].hooks) + [
          {event: "SessionStart", contract: {}, hook:
            {type: "command", command: "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-resume.sh"}},
          {event: "SessionStart", contract: {}, hook:
            {type: "command", command: "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh"}}
        ]) as $managed
      | (any($actual[]; . as $candidate
          | ($managed | index($candidate)) != null))
        or (($settings.permissions | type) == "object"
          and $settings.permissions.defaultMode == "bypassPermissions")
        or $settings.skipDangerousModePermissionPrompt == true
        or $settings.statusLine == $patch[0].statusLine
        or $settings.effortLevel == $patch[0].effortLevel
        or $settings.spinnerTipsEnabled == $patch[0].spinnerTipsEnabled
        or $settings.spinnerVerbs == $patch[0].spinnerVerbs
        or ($settings.outputStyle == "oh-my-claude"
          or $settings.outputStyle == "executive-brief"
          or $settings.outputStyle == "OpenCode Compact")
    ' "${SETTINGS_PHYSICAL_TARGET}" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Git checkout helpers
# ---------------------------------------------------------------------------

is_git_checkout() {
  local repo_root="${1:-}"
  [[ -n "${repo_root}" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  git -C "${repo_root}" rev-parse --show-toplevel >/dev/null 2>&1
}

git_hooks_dir_for_checkout() {
  local repo_root="${1:-}"
  local hooks_dir=""

  is_git_checkout "${repo_root}" || return 1
  hooks_dir="$(git -C "${repo_root}" rev-parse --git-path hooks 2>/dev/null || true)"
  [[ -n "${hooks_dir}" ]] || return 1
  if [[ "${hooks_dir}" != /* ]]; then
    hooks_dir="${repo_root}/${hooks_dir}"
  fi
  printf '%s\n' "${hooks_dir}"
}

WATCHDOG_HELPER_SOURCE="${SCRIPT_DIR}/bundle/dot-claude/install-resume-watchdog.sh"
WATCHDOG_HELPER_SOURCE_PARENT_ID=""
WATCHDOG_HELPER_SOURCE_NODE_ID=""
WATCHDOG_HELPER_SOURCE_HASH=""
WATCHDOG_HELPER_SOURCE_MODE=""
WATCHDOG_HELPER_SNAPSHOT_DIR=""
WATCHDOG_HELPER_SNAPSHOT_DIR_ID=""
WATCHDOG_HELPER_SNAPSHOT=""
WATCHDOG_HELPER_SNAPSHOT_NODE_ID=""
WATCHDOG_HELPER_SNAPSHOT_HASH=""
WATCHDOG_HELPER_SNAPSHOT_MODE=""
WATCHDOG_LAUNCHD_DEST="${TARGET_HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
WATCHDOG_SYSTEMD_SERVICE="${TARGET_HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
WATCHDOG_SYSTEMD_TIMER="${TARGET_HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"

# Scheduler cleanup is externally visible before the harness-removal pass: it
# disables a launchd/systemd/cron registration and rewrites the watchdog rows
# in oh-my-claude.conf. Keep an invocation-owned outer snapshot until every
# later pre-delete re-attestation succeeds. The watchdog helper remains the
# authority for its own operation; this outer layer only reverses a successful
# helper call when the enclosing uninstall subsequently aborts.
watchdog_outer_field() {
  local value="${1:-}"
  [[ -n "${value}" ]] && printf '%s' "${value}" || printf '-'
}

watchdog_outer_unfield() {
  local value="${1:-}"
  [[ "${value}" == "-" ]] && printf '' || printf '%s' "${value}"
}

watchdog_outer_recovery_claim_is_current() {
  local schema="" recovery_pid="" recovery_token="" lock_id=""
  local owner_pid="" owner_token="" stage_name="" extra="" line=""
  local rest="" field_index=0
  [[ "${WATCHDOG_OUTER_RECOVERY_ACTIVE:-0}" -eq 1 \
      && -n "${WATCHDOG_OUTER_RECOVERY_CLAIM:-}" \
      && -f "${WATCHDOG_OUTER_RECOVERY_CLAIM}" \
      && ! -L "${WATCHDOG_OUTER_RECOVERY_CLAIM}" \
      && "$(portable_node_identity "${WATCHDOG_OUTER_RECOVERY_CLAIM}" \
        2>/dev/null || true)" == "${WATCHDOG_OUTER_RECOVERY_CLAIM_ID:-}" \
      && "$(portable_file_mode "${WATCHDOG_OUTER_RECOVERY_CLAIM}" \
        2>/dev/null || true)" == "600" \
      && -d "${UNINSTALL_LOCK_DIR}" && ! -L "${UNINSTALL_LOCK_DIR}" \
      && "$(portable_node_identity "${UNINSTALL_LOCK_DIR}" \
        2>/dev/null || true)" == "${WATCHDOG_OUTER_RECOVERY_LOCK_ID:-}" \
      && -f "${UNINSTALL_LOCK_DIR}/pid" \
      && ! -L "${UNINSTALL_LOCK_DIR}/pid" \
      && -f "${UNINSTALL_LOCK_DIR}/token" \
      && ! -L "${UNINSTALL_LOCK_DIR}/token" \
      && "$(uninstall_read_canonical_metadata_line \
        "${UNINSTALL_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_RECOVERY_OWNER_PID:-}" \
      && "$(uninstall_read_canonical_metadata_line \
        "${UNINSTALL_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN:-}" ]] || return 1
  line="$(uninstall_read_canonical_metadata_line \
    "${WATCHDOG_OUTER_RECOVERY_CLAIM}" 2048)" || return 1
  [[ "${line}" != *$'\t\t'* ]] || return 1
  rest="${line}"
  for ((field_index=1; field_index<7; field_index++)); do
    [[ "${rest}" == *$'\t'* ]] || return 1
    rest="${rest#*$'\t'}"
  done
  [[ "${rest}" != *$'\t'* ]] || return 1
  IFS=$'\t' read -r schema recovery_pid recovery_token lock_id owner_pid \
    owner_token stage_name extra <<< "${line}" || return 1
  [[ -z "${extra}" ]] || return 1
  [[ "${schema}" == "v1" \
      && "${recovery_pid}" == "$$" \
      && "${recovery_token}" == "${WATCHDOG_OUTER_RECOVERY_CLAIM_TOKEN:-}" \
      && "${lock_id}" == "${WATCHDOG_OUTER_RECOVERY_LOCK_ID:-}" \
      && "${owner_pid}" == "${WATCHDOG_OUTER_RECOVERY_OWNER_PID:-}" \
      && "${owner_token}" == "${WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN:-}" \
      && "${stage_name}" == "${WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE_NAME:-}" \
      && "${stage_name}" \
        =~ ^[.]watchdog-outer-recovery-claim[.]stage[.][A-Za-z0-9]+$ ]]
}

watchdog_outer_rollback_authority_is_current() {
  if [[ "${WATCHDOG_OUTER_RECOVERY_ACTIVE:-0}" -eq 1 ]]; then
    watchdog_outer_recovery_claim_is_current
  else
    uninstall_lock_generation_is_current
  fi
}

watchdog_outer_publish_meta() {
  local phase="${1:-}" stage="" stage_id="" pub_parent=""
  local pub_node="" pub_hash="" pub_mode="" quarantine_path=""
  case "${phase}" in
    preparing|prepared|cleanup-started|post-captured|settings-published|committed|rolled-back) ;;
    *) return 1 ;;
  esac
  watchdog_outer_rollback_directory_is_current || return 1
  if [[ "${phase}" == "preparing" ]]; then
    [[ "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" -eq 0 ]] || return 1
  else
    [[ "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" -ge 4 \
        && "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" -le 5 ]] || return 1
  fi
  [[ "${WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED}" =~ ^[01]$ \
      && "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" =~ ^[01]$ \
      && "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" =~ ^[01]$ ]] \
    || return 1
  if [[ "${WATCHDOG_OUTER_RECOVERY_ACTIVE:-0}" -eq 1 ]]; then
    pub_parent="${SETTINGS_PUBLISHED_PARENT_ID:-}"
    pub_node="${SETTINGS_PUBLISHED_NODE_ID:-}"
    pub_hash="${SETTINGS_PUBLISHED_HASH:-}"
    pub_mode="${SETTINGS_PUBLISHED_MODE:-}"
  else
    pub_parent="${SETTINGS_STAGE_SEAL_PARENT_ID:-}"
    pub_node="${SETTINGS_STAGE_SEAL_NODE_ID:-}"
    pub_hash="${SETTINGS_STAGE_SEAL_HASH:-}"
    pub_mode="${SETTINGS_STAGE_SEAL_MODE:-}"
  fi
  if [[ -n "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH:-}" ]]; then
    quarantine_path="${WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH:-}"
    [[ "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID:-}" \
          == "${pub_node}" \
        && -n "${pub_parent}" \
        && "${pub_hash}" =~ ^[0-9A-Fa-f]{64}$ \
        && "${pub_mode}" =~ ^[0-7]{3,4}$ \
        && "${quarantine_path}" \
          == "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}.watchdog-quarantine" \
        && ! -e "${quarantine_path}" && ! -L "${quarantine_path}" ]] \
      || return 1
  else
    [[ -z "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID:-}${WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH:-}${pub_parent}${pub_node}${pub_hash}${pub_mode}" ]] \
      || return 1
  fi
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.meta.XXXXXX")" \
    || return 1
  stage_id="$(portable_node_identity "${stage}")" || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  if ! printf 'v2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${phase}" "${WATCHDOG_OUTER_ROLLBACK_LOCK_ID}" \
      "${WATCHDOG_OUTER_ROLLBACK_OWNER_PID}" \
      "${WATCHDOG_OUTER_ROLLBACK_OWNER_TOKEN}" \
      "${WATCHDOG_OUTER_ROLLBACK_DIR_ID}" \
      "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" \
      "${WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED}" \
      "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" \
      "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID}")" \
      "$(watchdog_outer_field "${pub_parent}")" \
      "$(watchdog_outer_field "${pub_node}")" \
      "$(watchdog_outer_field "${pub_hash}")" \
      "$(watchdog_outer_field "${pub_mode}")" \
      "$(watchdog_outer_field "${quarantine_path}")" \
      > "${stage}" \
      || ! chmod 600 "${stage}" \
      || [[ "$(portable_node_identity "${stage}" 2>/dev/null || true)" \
        != "${stage_id}" ]] \
      || ! mv -f -- "${stage}" "${WATCHDOG_OUTER_ROLLBACK_META}"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  WATCHDOG_OUTER_ROLLBACK_PHASE="${phase}"
}

watchdog_outer_publish_initial_paths() {
  local stage="" index=0 key="" snapshot=""
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.paths-initial.XXXXXX")" \
    || return 1
  : > "${stage}" || return 1
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    key="${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}"
    snapshot="${WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS[index]:-}"
    [[ -z "${snapshot}" \
        || "${snapshot}" == "${WATCHDOG_OUTER_ROLLBACK_DIR}/${key}.initial" ]] \
      || { rm -f -- "${stage}"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${key}" "${WATCHDOG_OUTER_ROLLBACK_PATHS[index]}" \
      "${WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS[index]}" \
      "${WATCHDOG_OUTER_ROLLBACK_PARENT_IDS[index]}" \
      "${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]}" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_INITIAL_IDS[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]}")" \
      "$(watchdog_outer_field "${snapshot##*/}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES[index]}")" \
      >> "${stage}" || { rm -f -- "${stage}"; return 1; }
  done
  if ! chmod 400 "${stage}" \
      || ! mv -f -- "${stage}" \
        "${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.initial.tsv"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

watchdog_outer_render_expected_config() {
  local index="${1:-}" source="/dev/null" first="" expected=""
  local grep_rc=0 target_mode="600"
  [[ "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]:-}" == "config" ]] \
    || return 1
  if [[ "${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]}" == "regular" ]]; then
    source="${WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS[index]}"
    watchdog_outer_snapshot_file_is_current "${index}" || return 1
    target_mode="${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]}"
  fi
  first="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.config-expected-one.XXXXXX")" \
    || return 1
  expected="${WATCHDOG_OUTER_ROLLBACK_DIR}/config.expected"
  [[ ! -e "${expected}" && ! -L "${expected}" ]] \
    || { rm -f -- "${first}"; return 1; }
  grep_rc=0
  grep -v -E '^resume_watchdog=' "${source}" > "${first}" 2>/dev/null \
    || grep_rc=$?
  if [[ "${grep_rc}" -gt 1 ]]; then
    rm -f -- "${first}"
    return 1
  fi
  printf '%s\n' 'resume_watchdog=off' >> "${first}" || return 1
  grep_rc=0
  grep -v -E '^resume_watchdog_scheduler=' "${first}" > "${expected}" \
    2>/dev/null || grep_rc=$?
  rm -f -- "${first}" || return 1
  [[ "${grep_rc}" -le 1 ]] || { rm -f -- "${expected}"; return 1; }
  printf '%s\n' 'resume_watchdog_scheduler=off' >> "${expected}" \
    || return 1
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES[index]="regular"
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES[index]="$(settings_sha256_file \
    "${expected}")" || return 1
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES[index]="${target_mode}"
  chmod 400 "${expected}" || return 1
}

watchdog_outer_prepare_expected_paths() {
  local platform_name="other" index=0 key="" stage=""
  case "$(uname 2>/dev/null || true)" in
    Darwin) platform_name="macos" ;;
    Linux) platform_name="linux" ;;
  esac
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES=()
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    key="${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}"
    WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES[index]="${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]}"
    WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES[index]="${WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES[index]}"
    WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES[index]="${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]}"
    case "${platform_name}:${key}" in
      macos:launchd|linux:systemd-service|linux:systemd-timer)
        WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES[index]="absent"
        WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES[index]=""
        WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES[index]=""
        ;;
      *:config) watchdog_outer_render_expected_config "${index}" || return 1 ;;
    esac
  done
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.paths-expected.XXXXXX")" \
    || return 1
  : > "${stage}" || return 1
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    printf '%s\t%s\t%s\t%s\n' \
      "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}" \
      "${WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES[index]}" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES[index]}")" \
      >> "${stage}" || { rm -f -- "${stage}"; return 1; }
  done
  if ! chmod 400 "${stage}" \
      || ! mv -f -- "${stage}" \
        "${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.expected.tsv"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

watchdog_outer_rollback_directory_is_current() {
  [[ -n "${WATCHDOG_OUTER_ROLLBACK_DIR}" \
      && -d "${WATCHDOG_OUTER_ROLLBACK_DIR}" \
      && ! -L "${WATCHDOG_OUTER_ROLLBACK_DIR}" \
      && "${WATCHDOG_OUTER_ROLLBACK_DIR}" == "${UNINSTALL_LOCK_DIR}/"* \
      && "$(portable_node_identity "${WATCHDOG_OUTER_ROLLBACK_DIR}" \
        2>/dev/null || true)" == "${WATCHDOG_OUTER_ROLLBACK_DIR_ID}" \
      && "$(portable_file_mode "${WATCHDOG_OUTER_ROLLBACK_DIR}" \
        2>/dev/null || true)" == "700" ]] \
    && watchdog_outer_rollback_authority_is_current
}

# Capture the nearest existing directory that physically anchors a rollback
# target's lexical parent. Active scheduler/config targets always capture their
# immediate parent; absent platform-specific trees capture the first existing
# ancestor, so a later directory or symlink graft cannot silently redirect the
# target before recovery. Both the canonical path and inode are durable WAL
# authority.
watchdog_outer_capture_parent_authority() {
  local path="${1:-}" parent="" physical="" parent_id="" relative=""
  [[ "${path}" == /* && "${path}" != *[[:cntrl:]]* ]] || return 1
  parent="${path%/*}"
  [[ -n "${parent}" ]] || parent="/"
  while [[ ! -d "${parent}" || -L "${parent}" ]]; do
    [[ ! -e "${parent}" && ! -L "${parent}" \
        && "${parent}" != "/" ]] || return 1
    parent="${parent%/*}"
    [[ -n "${parent}" ]] || parent="/"
  done
  physical="$(builtin cd -- "${parent}" 2>/dev/null \
    && builtin pwd -P)" || return 1
  [[ "${physical}" == /* && "${physical}" != *[[:cntrl:]]* \
      && -d "${physical}" && ! -L "${physical}" ]] || return 1
  parent_id="$(portable_directory_identity "${physical}")" || return 1
  [[ "${parent_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  if [[ "${parent}" == "/" ]]; then
    relative="${path#/}"
  else
    [[ "${path}" == "${parent}/"* ]] || return 1
    relative="${path#"${parent}/"}"
  fi
  [[ -n "${relative}" && "${relative}" != /* \
      && "/${relative}/" != *"/../"* \
      && "/${relative}/" != *"/./"* ]] || return 1
  WATCHDOG_OUTER_CAPTURED_PARENT_PATH="${physical}"
  WATCHDOG_OUTER_CAPTURED_PARENT_ID="${parent_id}"
  WATCHDOG_OUTER_CAPTURED_RELATIVE_TARGET="${relative}"
}

watchdog_outer_parent_authority_is_current() {
  local index="${1:-}" expected_path="" expected_id=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  expected_path="${WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS[index]:-}"
  expected_id="${WATCHDOG_OUTER_ROLLBACK_PARENT_IDS[index]:-}"
  [[ "${expected_path}" == /* \
      && "${expected_path}" != *[[:cntrl:]]* \
      && "${expected_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  watchdog_outer_capture_parent_authority \
    "${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}" || return 1
  [[ "${WATCHDOG_OUTER_CAPTURED_PARENT_PATH}" == "${expected_path}" \
      && "${WATCHDOG_OUTER_CAPTURED_PARENT_ID}" == "${expected_id}" ]]
}

# Resolve a rollback target relative to its durable parent anchor. Recovery
# enters that directory before its final generation check, so renaming or
# replacing the public parent pathname cannot redirect the following rm/mv.
watchdog_outer_relative_target_for_index() {
  local index="${1:-}" path="" anchor="" anchor_id="" relative=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  path="${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}"
  anchor="${WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS[index]:-}"
  anchor_id="${WATCHDOG_OUTER_ROLLBACK_PARENT_IDS[index]:-}"
  [[ "${path}" == /* && "${anchor}" == /* \
      && "${path}" != *[[:cntrl:]]* \
      && "${anchor}" != *[[:cntrl:]]* ]] || return 1
  watchdog_outer_capture_parent_authority "${path}" || return 1
  [[ "${WATCHDOG_OUTER_CAPTURED_PARENT_PATH}" == "${anchor}" \
      && "${WATCHDOG_OUTER_CAPTURED_PARENT_ID}" == "${anchor_id}" ]] \
    || return 1
  relative="${WATCHDOG_OUTER_CAPTURED_RELATIVE_TARGET}"
  [[ -n "${relative}" && "${relative}" != /* \
      && "/${relative}/" != *"/../"* \
      && "/${relative}/" != *"/./"* ]] || return 1
  printf '%s' "${relative}"
}

watchdog_outer_relative_components_are_safe() {
  local relative="${1:-}" component="" current="." index=0
  local -a components=()
  [[ -n "${relative}" && "${relative}" != /* \
      && "${relative}" != *[[:cntrl:]]* ]] || return 1
  IFS='/' read -r -a components <<< "${relative}"
  [[ "${#components[@]}" -gt 0 ]] || return 1
  for ((index=0; index<${#components[@]}; index++)); do
    component="${components[index]}"
    [[ -n "${component}" && "${component}" != "." \
        && "${component}" != ".." ]] || return 1
    current="${current}/${component}"
    if [[ "${index}" -lt $((${#components[@]} - 1)) ]]; then
      [[ -d "${current}" && ! -L "${current}" ]] || return 1
    fi
  done
}

capture_watchdog_outer_initial_path() {
  local key="${1:-}" path="${2:-}" state="absent" node_id=""
  local digest="" mode="" snapshot="" snapshot_id=""
  local snapshot_hash="" snapshot_mode="" parent_path="" parent_id=""
  local relative_target=""
  [[ "${key}" =~ ^[a-z0-9-]+$ \
      && "${path}" == /* && "${path}" != *[[:cntrl:]]* ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  preflight_no_symlinked_path_components "${path}" || return 1
  watchdog_outer_capture_parent_authority "${path}" || return 1
  parent_path="${WATCHDOG_OUTER_CAPTURED_PARENT_PATH}"
  parent_id="${WATCHDOG_OUTER_CAPTURED_PARENT_ID}"
  relative_target="${WATCHDOG_OUTER_CAPTURED_RELATIVE_TARGET}"
  [[ -n "${relative_target}" && "${relative_target}" != /* \
      && "/${relative_target}/" != *"/../"* \
      && "/${relative_target}/" != *"/./"* ]] || return 1
  if [[ -f "${path}" && ! -L "${path}" ]]; then
    state="regular"
    node_id="$(portable_node_identity "${path}")" || return 1
    digest="$(settings_sha256_file "${path}")" || return 1
    mode="$(portable_file_mode "${path}")" || return 1
    snapshot="${WATCHDOG_OUTER_ROLLBACK_DIR}/${key}.initial"
    [[ ! -e "${snapshot}" && ! -L "${snapshot}" ]] || return 1
    cp -p -- "${path}" "${snapshot}" || return 1
    chmod 400 "${snapshot}" || return 1
    snapshot_id="$(portable_node_identity "${snapshot}")" || return 1
    snapshot_hash="$(settings_sha256_file "${snapshot}")" || return 1
    snapshot_mode="$(portable_file_mode "${snapshot}")" || return 1
    [[ "${snapshot_hash}" == "${digest}" \
        && "${snapshot_mode}" == "400" \
        && -f "${path}" && ! -L "${path}" \
        && "$(portable_node_identity "${path}" 2>/dev/null || true)" \
          == "${node_id}" \
        && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
          == "${digest}" \
        && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
          == "${mode}" ]] || return 1
  elif [[ -e "${path}" || -L "${path}" ]]; then
    return 1
  fi
  watchdog_outer_capture_parent_authority "${path}" || return 1
  [[ "${WATCHDOG_OUTER_CAPTURED_PARENT_PATH}" == "${parent_path}" \
      && "${WATCHDOG_OUTER_CAPTURED_PARENT_ID}" == "${parent_id}" ]] \
    || return 1
  WATCHDOG_OUTER_ROLLBACK_KEYS+=("${key}")
  WATCHDOG_OUTER_ROLLBACK_PATHS+=("${path}")
  WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS+=("${parent_path}")
  WATCHDOG_OUTER_ROLLBACK_PARENT_IDS+=("${parent_id}")
  WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES+=("${state}")
  WATCHDOG_OUTER_ROLLBACK_INITIAL_IDS+=("${node_id}")
  WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES+=("${digest}")
  WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES+=("${mode}")
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS+=("${snapshot}")
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS+=("${snapshot_id}")
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES+=("${snapshot_hash}")
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES+=("${snapshot_mode}")
  WATCHDOG_OUTER_ROLLBACK_PATH_COUNT=$((WATCHDOG_OUTER_ROLLBACK_PATH_COUNT + 1))
}

watchdog_outer_snapshot_file_is_current() {
  local index="${1:-}" snapshot=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  snapshot="${WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS[index]:-}"
  [[ -n "${snapshot}" \
      && -f "${snapshot}" && ! -L "${snapshot}" \
      && "$(portable_node_identity "${snapshot}" \
        2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS[index]:-}" \
      && "$(settings_sha256_file "${snapshot}" \
        2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES[index]:-}" \
      && "$(portable_file_mode "${snapshot}" \
        2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES[index]:-}" ]]
}

capture_watchdog_outer_cron_snapshot() {
  local phase="${1:-}" snapshot="" state="unavailable"
  local snapshot_id="" snapshot_hash="" snapshot_mode=""
  [[ "${phase}" == "initial" || "${phase}" == "post" ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  snapshot="${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.${phase}"
  [[ ! -e "${snapshot}" && ! -L "${snapshot}" ]] || return 1
  if command -v crontab >/dev/null 2>&1; then
    if crontab -l >"${snapshot}" 2>/dev/null; then
      state="present"
    else
      : >"${snapshot}" || return 1
      state="absent"
    fi
  else
    : >"${snapshot}" || return 1
  fi
  chmod 400 "${snapshot}" || return 1
  snapshot_id="$(portable_node_identity "${snapshot}")" || return 1
  snapshot_hash="$(settings_sha256_file "${snapshot}")" || return 1
  snapshot_mode="$(portable_file_mode "${snapshot}")" || return 1
  case "${phase}" in
    initial)
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL="${snapshot}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID="${snapshot_id}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH="${snapshot_hash}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE="${snapshot_mode}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE="${state}"
      ;;
    post)
      WATCHDOG_OUTER_ROLLBACK_CRON_POST="${snapshot}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID="${snapshot_id}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH="${snapshot_hash}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE="${snapshot_mode}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE="${state}"
      ;;
  esac
}

watchdog_outer_cron_snapshot_is_current() {
  local phase="${1:-}" snapshot="" snapshot_id="" snapshot_hash=""
  local snapshot_mode=""
  case "${phase}" in
    initial)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE}"
      ;;
    post)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_POST}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE}"
      ;;
    *) return 1 ;;
  esac
  [[ -n "${snapshot}" && -f "${snapshot}" && ! -L "${snapshot}" \
      && "$(portable_node_identity "${snapshot}" \
        2>/dev/null || true)" == "${snapshot_id}" \
      && "$(settings_sha256_file "${snapshot}" \
        2>/dev/null || true)" == "${snapshot_hash}" \
      && "$(portable_file_mode "${snapshot}" \
        2>/dev/null || true)" == "${snapshot_mode}" ]]
}

watchdog_outer_publish_cron_meta() {
  local phase="${1:-}" snapshot="" state="" snapshot_id=""
  local snapshot_hash="" snapshot_mode="" meta="" stage=""
  case "${phase}" in
    initial)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}"
      state="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE}"
      ;;
    post)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_POST}"
      state="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE}"
      ;;
    *) return 1 ;;
  esac
  watchdog_outer_cron_snapshot_is_current "${phase}" || return 1
  [[ "${state}" =~ ^(present|absent|unavailable)$ ]] || return 1
  meta="${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.${phase}.meta"
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.cron-${phase}-meta.XXXXXX")" \
    || return 1
  if ! printf 'v1\t%s\t%s\t%s\t%s\n' "${state}" "${snapshot_id}" \
      "${snapshot_hash}" "${snapshot_mode}" > "${stage}" \
      || ! chmod 400 "${stage}" \
      || ! mv -f -- "${stage}" "${meta}"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

watchdog_outer_sha256_text() {
  local value="${1:-}" stage="" digest=""
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.text-hash.XXXXXX")" \
    || return 1
  printf '%s' "${value}" > "${stage}" || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  digest="$(settings_sha256_file "${stage}")" || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  rm -f -- "${stage}" || return 1
  printf '%s' "${digest}"
}

render_uninstall_watchdog_previous_cron_line() {
  local quoted_script=""
  printf -v quoted_script '%q' \
    "${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${quoted_script}"
}

render_uninstall_watchdog_raw_cron_line() {
  printf '*/2 * * * * bash %s >/dev/null 2>&1' \
    "${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
}

watchdog_outer_cron_line_is_owned() {
  local line="${1:-}" allow_marker_legacy="${2:-0}"
  local expected_digest="" actual_digest=""
  [[ "${line}" == "$(render_uninstall_watchdog_cron_line)" ]] && return 0
  expected_digest="$(read_last_valid_conf_sha256 \
    "${CLAUDE_HOME}/oh-my-claude.conf" \
    resume_watchdog_cron_sha256)"
  if [[ -n "${expected_digest}" ]]; then
    actual_digest="$(watchdog_outer_sha256_text "${line}")" || return 1
    [[ "${actual_digest}" == "${expected_digest}" ]] && return 0
  fi
  if [[ "${allow_marker_legacy}" -eq 1 ]]; then
    [[ "${line}" == "$(render_uninstall_watchdog_previous_cron_line)" \
        || "${line}" == "$(render_uninstall_watchdog_raw_cron_line)" ]] \
      && return 0
  fi
  return 1
}

watchdog_outer_strip_managed_cron_entries() {
  local current="${1:-}" line="" pending_marker=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${pending_marker}" -eq 1 ]]; then
      if watchdog_outer_cron_line_is_owned "${line}" 1; then
        pending_marker=0
        continue
      fi
      printf '%s\n' '# oh-my-claude resume-watchdog'
      pending_marker=0
    fi
    if [[ "${line}" == '# oh-my-claude resume-watchdog' ]]; then
      pending_marker=1
    elif ! watchdog_outer_cron_line_is_owned "${line}" 0; then
      printf '%s\n' "${line}"
    fi
  done <<< "${current}"
  [[ "${pending_marker}" -eq 0 ]] \
    || printf '%s\n' '# oh-my-claude resume-watchdog'
}

watchdog_outer_cron_has_managed_entry() {
  local current="${1:-}" line=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    watchdog_outer_cron_line_is_owned "${line}" 0 && return 0
  done <<< "${current}"
  return 1
}

watchdog_outer_cron_has_managed_marker() {
  local current="${1:-}" line="" previous=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${previous}" == '# oh-my-claude resume-watchdog' ]] \
        && watchdog_outer_cron_line_is_owned "${line}" 1; then
      return 0
    fi
    previous="${line}"
  done <<< "${current}"
  return 1
}

watchdog_outer_prepare_expected_cron() {
  local current="" next="" expected="" expected_state=""
  local expected_id="" expected_hash="" expected_mode="" meta="" stage=""
  watchdog_outer_cron_snapshot_is_current initial || return 1
  current="$(<"${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}")"
  expected="${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.expected"
  expected_state="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE}"
  if [[ "${expected_state}" != "unavailable" ]] \
      && { watchdog_outer_cron_has_managed_entry "${current}" \
        || watchdog_outer_cron_has_managed_marker "${current}"; }; then
    next="$(watchdog_outer_strip_managed_cron_entries "${current}")" \
      || return 1
    printf '%s\n' "${next}" > "${expected}" || return 1
    expected_state="present"
  else
    cp -- "${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}" "${expected}" \
      || return 1
  fi
  chmod 400 "${expected}" || return 1
  expected_id="$(portable_node_identity "${expected}")" || return 1
  expected_hash="$(settings_sha256_file "${expected}")" || return 1
  expected_mode="$(portable_file_mode "${expected}")" || return 1
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED="${expected}"
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_STATE="${expected_state}"
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_ID="${expected_id}"
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_HASH="${expected_hash}"
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_MODE="${expected_mode}"
  meta="${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.expected.meta"
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.cron-expected-meta.XXXXXX")" \
    || return 1
  if ! printf 'v1\t%s\t%s\t%s\t%s\n' "${expected_state}" \
      "${expected_id}" "${expected_hash}" "${expected_mode}" > "${stage}" \
      || ! chmod 400 "${stage}" \
      || ! mv -f -- "${stage}" "${meta}"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

prepare_watchdog_outer_rollback() {
  local fixed_dir="" staged_dir="" preparing_meta_id=""
  local preparing_meta_hash=""
  [[ "${WATCHDOG_OUTER_ROLLBACK_PREPARED}" -eq 0 ]] || return 1
  uninstall_lock_generation_is_current || return 1
  fixed_dir="${UNINSTALL_LOCK_DIR}/watchdog-outer-rollback"
  [[ ! -e "${fixed_dir}" && ! -L "${fixed_dir}" ]] || return 1
  staged_dir="$(mktemp -d \
    "${UNINSTALL_LOCK_DIR}/.watchdog-outer-rollback.stage.XXXXXX")" \
    || return 1
  [[ "${staged_dir##*/}" \
      =~ ^[.]watchdog-outer-rollback[.]stage[.][A-Za-z0-9]+$ ]] \
    || return 1
  WATCHDOG_OUTER_ROLLBACK_DIR="${staged_dir}"
  chmod 700 "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
  WATCHDOG_OUTER_ROLLBACK_DIR_ID="$(portable_node_identity \
    "${WATCHDOG_OUTER_ROLLBACK_DIR}")" || return 1
  WATCHDOG_OUTER_ROLLBACK_META="${WATCHDOG_OUTER_ROLLBACK_DIR}/meta.tsv"
  WATCHDOG_OUTER_ROLLBACK_LOCK_ID="${UNINSTALL_LOCK_DIR_ID}"
  WATCHDOG_OUTER_ROLLBACK_OWNER_PID="$$"
  WATCHDOG_OUTER_ROLLBACK_OWNER_TOKEN="${UNINSTALL_LOCK_TOKEN}"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH="${SETTINGS_STAGE_PATH:-}"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID="${SETTINGS_STAGE_CREATED_NODE_ID:-}"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH=""
  if [[ -n "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}" ]]; then
    [[ "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}" == /* \
        && "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}" \
          != *[[:cntrl:]]* \
        && -f "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}" \
        && ! -L "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}" \
        && "$(portable_node_identity \
          "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}" \
          2>/dev/null || true)" \
          == "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID}" ]] \
      || return 1
    WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH="${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH}.watchdog-quarantine"
    [[ ! -e "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH}" \
        && ! -L "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH}" ]] \
      || return 1
    WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED=1
  fi
  watchdog_outer_publish_meta preparing || return 1
  preparing_meta_id="$(portable_node_identity \
    "${WATCHDOG_OUTER_ROLLBACK_META}")" || return 1
  preparing_meta_hash="$(settings_sha256_file \
    "${WATCHDOG_OUTER_ROLLBACK_META}")" || return 1
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_WAL_STAGED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_WAL_STAGED_RELEASE_FILE:-}" \
    "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  [[ -f "${WATCHDOG_OUTER_ROLLBACK_META}" \
      && ! -L "${WATCHDOG_OUTER_ROLLBACK_META}" \
      && "$(portable_node_identity "${WATCHDOG_OUTER_ROLLBACK_META}" \
        2>/dev/null || true)" == "${preparing_meta_id}" \
      && "$(settings_sha256_file "${WATCHDOG_OUTER_ROLLBACK_META}" \
        2>/dev/null || true)" == "${preparing_meta_hash}" \
      && "$(portable_file_mode "${WATCHDOG_OUTER_ROLLBACK_META}" \
        2>/dev/null || true)" == "600" \
      && ! -e "${fixed_dir}" && ! -L "${fixed_dir}" ]] || return 1
  mv -- "${WATCHDOG_OUTER_ROLLBACK_DIR}" "${fixed_dir}" || return 1
  WATCHDOG_OUTER_ROLLBACK_DIR="${fixed_dir}"
  WATCHDOG_OUTER_ROLLBACK_META="${fixed_dir}/meta.tsv"
  watchdog_outer_rollback_directory_is_current \
    && [[ ! -e "${staged_dir}" && ! -L "${staged_dir}" ]] \
    && [[ "$(portable_node_identity "${WATCHDOG_OUTER_ROLLBACK_META}" \
      2>/dev/null || true)" == "${preparing_meta_id}" ]] \
    || return 1
  capture_watchdog_outer_initial_path launchd \
    "${WATCHDOG_LAUNCHD_DEST}" || return 1
  capture_watchdog_outer_initial_path systemd-service \
    "${WATCHDOG_SYSTEMD_SERVICE}" || return 1
  capture_watchdog_outer_initial_path systemd-timer \
    "${WATCHDOG_SYSTEMD_TIMER}" || return 1
  if [[ -n "${SETTINGS_STAGE_PATH}" ]]; then
    capture_watchdog_outer_initial_path settings \
      "${SETTINGS_SEAL_PHYSICAL_PATH}" || return 1
  fi
  capture_watchdog_outer_initial_path config \
    "${CLAUDE_HOME}/oh-my-claude.conf" || return 1
  capture_watchdog_outer_cron_snapshot initial || return 1
  if command -v launchctl >/dev/null 2>&1 \
      && launchctl print \
        "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
        >/dev/null 2>&1; then
    WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED=1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user is-enabled \
      oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED=1
    systemctl --user is-active \
      oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE=1
  fi
  watchdog_outer_publish_initial_paths || return 1
  watchdog_outer_publish_cron_meta initial || return 1
  watchdog_outer_prepare_expected_paths || return 1
  watchdog_outer_prepare_expected_cron || return 1
  watchdog_outer_publish_meta prepared || return 1
  WATCHDOG_OUTER_ROLLBACK_PREPARED=1
}

capture_watchdog_outer_post_path() {
  local index="${1:-}" path="" state="absent" node_id="" digest="" mode=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  path="${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}"
  preflight_no_symlinked_path_components "${path}" || return 1
  if [[ -f "${path}" && ! -L "${path}" ]]; then
    state="regular"
    node_id="$(portable_node_identity "${path}")" || return 1
    digest="$(settings_sha256_file "${path}")" || return 1
    mode="$(portable_file_mode "${path}")" || return 1
    [[ -f "${path}" && ! -L "${path}" \
        && "$(portable_node_identity "${path}" \
          2>/dev/null || true)" == "${node_id}" \
        && "$(settings_sha256_file "${path}" \
          2>/dev/null || true)" == "${digest}" \
        && "$(portable_file_mode "${path}" \
          2>/dev/null || true)" == "${mode}" ]] || return 1
  elif [[ -e "${path}" || -L "${path}" ]]; then
    return 1
  fi
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  WATCHDOG_OUTER_ROLLBACK_POST_STATES+=("${state}")
  WATCHDOG_OUTER_ROLLBACK_POST_IDS+=("${node_id}")
  WATCHDOG_OUTER_ROLLBACK_POST_HASHES+=("${digest}")
  WATCHDOG_OUTER_ROLLBACK_POST_MODES+=("${mode}")
  WATCHDOG_OUTER_ROLLBACK_POST_COUNT=$((WATCHDOG_OUTER_ROLLBACK_POST_COUNT + 1))
}

watchdog_outer_publish_post_paths() {
  local stage="" index=0
  stage="$(mktemp "${WATCHDOG_OUTER_ROLLBACK_DIR}/.paths-post.XXXXXX")" \
    || return 1
  : > "${stage}" || return 1
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}" \
      "${WATCHDOG_OUTER_ROLLBACK_POST_STATES[index]}" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_POST_IDS[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_POST_HASHES[index]}")" \
      "$(watchdog_outer_field "${WATCHDOG_OUTER_ROLLBACK_POST_MODES[index]}")" \
      >> "${stage}" || { rm -f -- "${stage}"; return 1; }
  done
  if ! chmod 400 "${stage}" \
      || ! mv -f -- "${stage}" \
        "${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.post.tsv"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

watchdog_outer_mark_cleanup_started() {
  [[ "${WATCHDOG_OUTER_ROLLBACK_PREPARED}" -eq 1 \
      && "${WATCHDOG_OUTER_ROLLBACK_PHASE}" == "prepared" ]] || return 1
  watchdog_outer_publish_meta cleanup-started || return 1
  WATCHDOG_OUTER_ROLLBACK_ARMED=1
}

capture_watchdog_outer_post_state() {
  local index=0
  [[ "${WATCHDOG_OUTER_ROLLBACK_PREPARED}" -eq 1 ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  WATCHDOG_OUTER_ROLLBACK_POST_STATES=()
  WATCHDOG_OUTER_ROLLBACK_POST_IDS=()
  WATCHDOG_OUTER_ROLLBACK_POST_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_POST_MODES=()
  WATCHDOG_OUTER_ROLLBACK_POST_COUNT=0
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    capture_watchdog_outer_post_path "${index}" || return 1
  done
  capture_watchdog_outer_cron_snapshot post || return 1
  [[ "${WATCHDOG_OUTER_ROLLBACK_POST_COUNT}" \
      -eq "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" ]] || return 1
  watchdog_outer_all_expected_paths_are_current \
    && watchdog_outer_cron_expected_is_current || return 1
  watchdog_outer_publish_post_paths || return 1
  watchdog_outer_publish_cron_meta post || return 1
  WATCHDOG_OUTER_ROLLBACK_POST_CAPTURED=1
  WATCHDOG_OUTER_ROLLBACK_ARMED=1
  watchdog_outer_publish_meta post-captured || return 1
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_POST_CAPTURED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_POST_CAPTURED_RELEASE_FILE:-}" \
    "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
}

watchdog_outer_post_path_is_current() {
  local index="${1:-}" path="" state=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  path="${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}"
  state="${WATCHDOG_OUTER_ROLLBACK_POST_STATES[index]:-}"
  case "${state}" in
    absent) [[ ! -e "${path}" && ! -L "${path}" ]] ;;
    regular)
      [[ -f "${path}" && ! -L "${path}" \
          && "$(portable_node_identity "${path}" \
            2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_POST_IDS[index]:-}" \
          && "$(settings_sha256_file "${path}" \
            2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_POST_HASHES[index]:-}" \
          && "$(portable_file_mode "${path}" \
            2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_POST_MODES[index]:-}" ]]
      ;;
    *) return 1 ;;
  esac || return 1
  watchdog_outer_parent_authority_is_current "${index}"
}

watchdog_outer_expected_path_is_current() {
  local index="${1:-}" path="" state=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  path="${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}"
  state="${WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES[index]:-}"
  case "${state}" in
    absent) [[ ! -e "${path}" && ! -L "${path}" ]] ;;
    regular)
      [[ -f "${path}" && ! -L "${path}" \
          && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES[index]:-}" \
          && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES[index]:-}" ]]
      ;;
    *) return 1 ;;
  esac || return 1
  watchdog_outer_parent_authority_is_current "${index}"
}

watchdog_outer_all_initial_paths_are_current() {
  local index=0
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    watchdog_outer_initial_content_is_current "${index}" || return 1
  done
}

watchdog_outer_all_expected_paths_are_current() {
  local index=0
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    watchdog_outer_expected_path_is_current "${index}" || return 1
  done
}

watchdog_outer_initial_content_is_current() {
  local index="${1:-}" path="" state=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  path="${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}"
  state="${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]:-}"
  case "${state}" in
    absent) [[ ! -e "${path}" && ! -L "${path}" ]] ;;
    regular)
      [[ -f "${path}" && ! -L "${path}" \
          && "$(settings_sha256_file "${path}" \
            2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES[index]:-}" \
          && "$(portable_file_mode "${path}" \
            2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]:-}" ]]
      ;;
    *) return 1 ;;
  esac || return 1
  watchdog_outer_parent_authority_is_current "${index}"
}

watchdog_outer_settings_publication_is_current() {
  local index="${1:-}" path="" parent_id="" node_id="" digest="" mode=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  path="${WATCHDOG_OUTER_ROLLBACK_PATHS[index]:-}"
  [[ "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]:-}" == "settings" ]] \
    || return 1
  if [[ "${SETTINGS_STAGE_COMMITTED:-0}" -ne 1 \
      && "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED:-0}" \
        -ne 1 ]]; then
    return 1
  fi
  if [[ "${WATCHDOG_OUTER_RECOVERY_ACTIVE:-0}" -eq 1 ]]; then
    parent_id="${SETTINGS_PUBLISHED_PARENT_ID:-}"
    node_id="${SETTINGS_PUBLISHED_NODE_ID:-}"
    digest="${SETTINGS_PUBLISHED_HASH:-}"
    mode="${SETTINGS_PUBLISHED_MODE:-}"
  else
    parent_id="${SETTINGS_STAGE_SEAL_PARENT_ID:-}"
    node_id="${SETTINGS_STAGE_SEAL_NODE_ID:-}"
    digest="${SETTINGS_STAGE_SEAL_HASH:-}"
    mode="${SETTINGS_STAGE_SEAL_MODE:-}"
  fi
  [[ -f "${path}" && ! -L "${path}" \
      && "$(portable_directory_identity "${path%/*}" \
        2>/dev/null || true)" == "${parent_id}" \
      && "$(portable_node_identity "${path}" 2>/dev/null || true)" \
        == "${node_id}" \
      && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
        == "${digest}" \
      && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
        == "${mode}" ]] \
    && watchdog_outer_parent_authority_is_current "${index}"
}

watchdog_outer_cron_generation_is_current() {
  local phase="${1:-}" current="" state="unavailable" snapshot=""
  local snapshot_id="" snapshot_hash="" snapshot_mode="" expected_state=""
  case "${phase}" in
    initial)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE}"
      expected_state="${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE}"
      ;;
    expected)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_MODE}"
      expected_state="${WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_STATE}"
      ;;
    post)
      snapshot="${WATCHDOG_OUTER_ROLLBACK_CRON_POST}"
      snapshot_id="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID}"
      snapshot_hash="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH}"
      snapshot_mode="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE}"
      expected_state="${WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE}"
      ;;
    *) return 1 ;;
  esac
  [[ -n "${snapshot}" && -f "${snapshot}" && ! -L "${snapshot}" \
      && "$(portable_node_identity "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_id}" \
      && "$(settings_sha256_file "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_hash}" \
      && "$(portable_file_mode "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_mode}" ]] || return 1
  current="$(mktemp \
    "${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.current.XXXXXX")" || return 1
  if command -v crontab >/dev/null 2>&1; then
    if crontab -l >"${current}" 2>/dev/null; then
      state="present"
    else
      : >"${current}" || { rm -f -- "${current}"; return 1; }
      state="absent"
    fi
  else
    : >"${current}" || { rm -f -- "${current}"; return 1; }
  fi
  if [[ "${state}" != "${expected_state}" ]] \
      || ! cmp -s "${current}" "${snapshot}"; then
    rm -f -- "${current}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${current}"
}

watchdog_outer_cron_initial_is_current() {
  watchdog_outer_cron_generation_is_current initial
}

watchdog_outer_cron_expected_is_current() {
  watchdog_outer_cron_generation_is_current expected
}

watchdog_outer_cron_post_is_current() {
  watchdog_outer_cron_generation_is_current post
}

watchdog_outer_pinned_path_generation_is_current() {
  local index="${1:-}" phase="${2:-}" path="${3:-}" state=""
  local node_id="" digest="" mode=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  [[ -n "${path}" && "${path}" != *[[:cntrl:]]* ]] || return 1
  case "${phase}" in
    initial)
      state="${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]:-}"
      digest="${WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES[index]:-}"
      mode="${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]:-}"
      ;;
    post)
      state="${WATCHDOG_OUTER_ROLLBACK_POST_STATES[index]:-}"
      node_id="${WATCHDOG_OUTER_ROLLBACK_POST_IDS[index]:-}"
      digest="${WATCHDOG_OUTER_ROLLBACK_POST_HASHES[index]:-}"
      mode="${WATCHDOG_OUTER_ROLLBACK_POST_MODES[index]:-}"
      ;;
    publication)
      [[ "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]:-}" == "settings" ]] \
        || return 1
      if [[ "${SETTINGS_STAGE_COMMITTED:-0}" -ne 1 \
          && "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED:-0}" \
            -ne 1 ]]; then
        return 1
      fi
      state="regular"
      node_id="${SETTINGS_PUBLISHED_NODE_ID:-${SETTINGS_STAGE_SEAL_NODE_ID:-}}"
      digest="${SETTINGS_PUBLISHED_HASH:-${SETTINGS_STAGE_SEAL_HASH:-}}"
      mode="${SETTINGS_PUBLISHED_MODE:-${SETTINGS_STAGE_SEAL_MODE:-}}"
      ;;
    *) return 1 ;;
  esac
  case "${state}" in
    absent) [[ ! -e "${path}" && ! -L "${path}" ]] ;;
    regular)
      [[ -f "${path}" && ! -L "${path}" \
          && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
            == "${digest}" \
          && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
            == "${mode}" ]] || return 1
      [[ -z "${node_id}" \
          || "$(portable_node_identity "${path}" 2>/dev/null || true)" \
            == "${node_id}" ]]
      ;;
    *) return 1 ;;
  esac || return 1
}

restore_watchdog_outer_path() (
  local index="${1:-}" state="" anchor="" anchor_id="" relative=""
  local target="" target_parent="." target_name="" snapshot=""
  local stage="" stage_id="" stage_hash="" stage_mode=""
  [[ "${index}" =~ ^[0-9]+$ ]] || return 1
  watchdog_outer_parent_authority_is_current "${index}" || return 1
  anchor="${WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS[index]:-}"
  anchor_id="${WATCHDOG_OUTER_ROLLBACK_PARENT_IDS[index]:-}"
  relative="$(watchdog_outer_relative_target_for_index "${index}")" \
    || return 1
  state="${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]:-}"
  snapshot="${WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS[index]:-}"
  builtin cd -- "${anchor}" || return 1
  [[ "$(portable_directory_identity . 2>/dev/null || true)" \
      == "${anchor_id}" ]] || return 1
  target="./${relative}"
  watchdog_outer_pinned_path_generation_is_current \
    "${index}" initial "${target}" && return 0
  watchdog_outer_relative_components_are_safe "${relative}" || return 1
  watchdog_outer_pinned_path_generation_is_current \
    "${index}" post "${target}" \
    || watchdog_outer_pinned_path_generation_is_current \
      "${index}" publication "${target}" \
    || return 1

  # This is deliberately after cwd has pinned the recorded directory inode and
  # after the final admissible-generation check. A public-parent retarget in
  # this seam must not redirect either mutation below.
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_PARENT_PINNED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_PARENT_PINNED_RELEASE_FILE:-}" \
    "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}:${relative}" || return 1
  [[ "$(portable_directory_identity . 2>/dev/null || true)" \
      == "${anchor_id}" ]] || return 1
  watchdog_outer_relative_components_are_safe "${relative}" || return 1
  watchdog_outer_pinned_path_generation_is_current \
    "${index}" post "${target}" \
    || watchdog_outer_pinned_path_generation_is_current \
      "${index}" publication "${target}" \
    || return 1

  case "${state}" in
    absent)
      [[ ! -d "${target}" ]] || return 1
      rm -f -- "${target}" || return 1
      ;;
    regular)
      watchdog_outer_snapshot_file_is_current "${index}" || return 1
      if [[ "${relative}" == */* ]]; then
        target_parent="./${relative%/*}"
      fi
      target_name="${relative##*/}"
      [[ -d "${target_parent}" && ! -L "${target_parent}" ]] || return 1
      stage="$(mktemp \
        "${target_parent}/.${target_name}.uninstall-rollback.XXXXXX")" \
        || return 1
      if ! cp -p -- "${snapshot}" "${stage}" \
          || ! chmod "${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]}" \
            "${stage}"; then
        rm -f -- "${stage}" 2>/dev/null || true
        return 1
      fi
      stage_id="$(portable_node_identity "${stage}")" || {
        rm -f -- "${stage}" 2>/dev/null || true
        return 1
      }
      stage_hash="$(settings_sha256_file "${stage}")" || {
        rm -f -- "${stage}" 2>/dev/null || true
        return 1
      }
      stage_mode="$(portable_file_mode "${stage}")" || {
        rm -f -- "${stage}" 2>/dev/null || true
        return 1
      }
      if [[ "${stage_hash}" \
            != "${WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES[index]}" \
          || "${stage_mode}" \
            != "${WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES[index]}" \
          || ! -f "${stage}" || -L "${stage}" \
          || "$(portable_node_identity "${stage}" \
            2>/dev/null || true)" != "${stage_id}" \
          || "$(settings_sha256_file "${stage}" \
            2>/dev/null || true)" != "${stage_hash}" \
          || "$(portable_file_mode "${stage}" \
            2>/dev/null || true)" != "${stage_mode}" \
          || "$(portable_directory_identity . 2>/dev/null || true)" \
            != "${anchor_id}" ]] \
          || { ! watchdog_outer_pinned_path_generation_is_current \
                "${index}" post "${target}" \
            && ! watchdog_outer_pinned_path_generation_is_current \
                "${index}" publication "${target}"; } \
          || ! mv -f -- "${stage}" "${target}"; then
        rm -f -- "${stage}" 2>/dev/null || true
        return 1
      fi
      ;;
    *) return 1 ;;
  esac

  watchdog_outer_pinned_path_generation_is_current \
    "${index}" initial "${target}" || return 1
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_PARENT_MUTATED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_PARENT_MUTATED_RELEASE_FILE:-}" \
    "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}:${relative}" || return 1
  [[ "$(portable_directory_identity . 2>/dev/null || true)" \
      == "${anchor_id}" ]] \
    && watchdog_outer_pinned_path_generation_is_current \
      "${index}" initial "${target}"
)

restore_watchdog_outer_cron() {
  watchdog_outer_cron_snapshot_is_current initial || return 1
  watchdog_outer_cron_initial_is_current && return 0
  watchdog_outer_cron_post_is_current || return 1
  if [[ "${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE}" \
        == "${WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE}" ]] \
      && cmp -s "${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}" \
        "${WATCHDOG_OUTER_ROLLBACK_CRON_POST}"; then
    return 0
  fi
  command -v crontab >/dev/null 2>&1 || return 1
  case "${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE}" in
    present)
      crontab - <"${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL}" || return 1
      ;;
    absent)
      crontab -r >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  watchdog_outer_cron_initial_is_current
}

watchdog_outer_discard_unpublished_post_artifacts() {
  local path=""
  [[ "${WATCHDOG_OUTER_ROLLBACK_PHASE}" == "cleanup-started" ]] \
    || return 1
  for path in \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.post.tsv" \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.post" \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.post.meta" \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}"/.paths-post.* \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}"/.cron-post-meta.*; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    [[ "${path}" == "${WATCHDOG_OUTER_ROLLBACK_DIR}/"* \
        && -f "${path}" && ! -L "${path}" ]] || return 1
    rm -f -- "${path}" || return 1
  done
}

watchdog_outer_prepare_post_for_rollback() {
  if [[ "${WATCHDOG_OUTER_ROLLBACK_POST_CAPTURED}" -eq 1 ]]; then
    return 0
  fi
  if watchdog_outer_all_initial_paths_are_current \
      && watchdog_outer_cron_initial_is_current \
      && watchdog_outer_runtime_matches_initial; then
    watchdog_outer_publish_meta rolled-back || return 1
    WATCHDOG_OUTER_ROLLBACK_ARMED=0
    return 0
  fi
  watchdog_outer_all_expected_paths_are_current \
    && watchdog_outer_cron_expected_is_current || return 1
  watchdog_outer_discard_unpublished_post_artifacts || return 1
  capture_watchdog_outer_post_state
}

rollback_watchdog_outer_transaction() {
  local index=0 path_count="${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT:-0}"
  local current_enabled=0 current_active=0
  [[ "${WATCHDOG_OUTER_ROLLBACK_ARMED}" -eq 1 \
      && "${path_count}" -gt 0 ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  watchdog_outer_lock_has_participants && return 1
  watchdog_outer_prepare_post_for_rollback || return 1
  [[ "${WATCHDOG_OUTER_ROLLBACK_ARMED}" -eq 1 ]] || return 0
  [[ "${WATCHDOG_OUTER_ROLLBACK_POST_CAPTURED}" -eq 1 ]] || return 1
  watchdog_outer_cron_snapshot_is_current initial \
    && watchdog_outer_cron_snapshot_is_current post || return 1
  for ((index=0; index<path_count; index++)); do
    if [[ "${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[index]}" \
        == "regular" ]]; then
      watchdog_outer_snapshot_file_is_current "${index}" || return 1
    fi
    watchdog_outer_initial_content_is_current "${index}" \
      || watchdog_outer_post_path_is_current "${index}" \
      || watchdog_outer_settings_publication_is_current "${index}" \
      || return 1
  done
  watchdog_outer_cron_post_is_current \
    || watchdog_outer_cron_initial_is_current || return 1

  # Quiesce any current registration before restoring executable scheduler
  # artifacts and configuration. Prior runtime state is re-established last.
  if command -v launchctl >/dev/null 2>&1 \
      && launchctl print \
        "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
        >/dev/null 2>&1; then
    launchctl bootout \
      "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
      >/dev/null 2>&1 || return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user is-enabled \
      oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && current_enabled=1
    systemctl --user is-active \
      oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
      && current_active=1
    if [[ "${current_enabled}" -eq 1 || "${current_active}" -eq 1 ]]; then
      systemctl --user disable --now \
        oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 || return 1
    fi
  fi

  for ((index=0; index<path_count; index++)); do
    [[ "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}" == "config" ]] \
      && continue
    restore_watchdog_outer_path "${index}" || return 1
  done
  restore_watchdog_outer_cron || return 1
  for ((index=0; index<path_count; index++)); do
    [[ "${WATCHDOG_OUTER_ROLLBACK_KEYS[index]}" == "config" ]] \
      || continue
    restore_watchdog_outer_path "${index}" || return 1
  done

  if [[ "${WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED}" -eq 1 ]]; then
    command -v launchctl >/dev/null 2>&1 || return 1
    launchctl bootstrap "gui/$(id -u)" \
      "${WATCHDOG_LAUNCHD_DEST}" >/dev/null 2>&1 || return 1
  fi
  if command -v systemctl >/dev/null 2>&1 \
      && { [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" -eq 1 ]] \
        || [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" -eq 1 ]]; }; then
    systemctl --user daemon-reload >/dev/null 2>&1 || return 1
    if [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" -eq 1 ]]; then
      systemctl --user enable \
        oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 || return 1
    fi
    if [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" -eq 1 ]]; then
      systemctl --user start \
        oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 || return 1
    fi
  fi
  if [[ "${WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED}" -eq 1 ]]; then
    launchctl print \
      "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
      >/dev/null 2>&1 || return 1
  fi
  if [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" -eq 1 ]]; then
    systemctl --user is-enabled \
      oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 || return 1
  fi
  if [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" -eq 1 ]]; then
    systemctl --user is-active \
      oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 || return 1
  fi
  for ((index=0; index<path_count; index++)); do
    watchdog_outer_initial_content_is_current "${index}" || return 1
  done
  watchdog_outer_cron_initial_is_current || return 1
  watchdog_outer_publish_meta rolled-back || return 1
  WATCHDOG_OUTER_ROLLBACK_ARMED=0
}

cleanup_watchdog_outer_rollback_snapshot() {
  local index=0 path="" name="" had_nullglob=0 had_dotglob=0
  local -a paths=()
  [[ "${WATCHDOG_OUTER_ROLLBACK_ARMED:-0}" -eq 0 ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  for ((index=0; index<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; index++)); do
    path="${WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS[index]:-}"
    [[ -n "${path}" ]] || continue
    watchdog_outer_snapshot_file_is_current "${index}" || return 1
  done
  if [[ -n "${WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL:-}" ]]; then
    watchdog_outer_cron_snapshot_is_current initial || return 1
  fi
  shopt -q nullglob && had_nullglob=1
  shopt -q dotglob && had_dotglob=1
  shopt -s nullglob dotglob
  paths=("${WATCHDOG_OUTER_ROLLBACK_DIR}"/*)
  [[ "${had_nullglob}" -eq 1 ]] || shopt -u nullglob
  [[ "${had_dotglob}" -eq 1 ]] || shopt -u dotglob
  for path in "${paths[@]}"; do
    name="${path##*/}"
    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    case "${name}" in
      meta.tsv|paths.initial.tsv|paths.expected.tsv|paths.post.tsv|\
      config.expected|cron.initial|cron.initial.meta|cron.expected|\
      cron.expected.meta|cron.post|cron.post.meta|\
      .meta.*|.paths-initial.*|.paths-expected.*|.paths-post.*|\
      .cron-*-meta.*|.config-expected-one.*|.text-hash.*|cron.current.*|\
      launchd.initial|systemd-service.initial|systemd-timer.initial|\
      settings.initial|config.initial) ;;
      *) return 1 ;;
    esac
  done
  for path in "${paths[@]}"; do
    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    rm -f -- "${path}" || return 1
  done
  rmdir "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
  WATCHDOG_OUTER_ROLLBACK_DIR=""
  WATCHDOG_OUTER_ROLLBACK_DIR_ID=""
  WATCHDOG_OUTER_ROLLBACK_META=""
  WATCHDOG_OUTER_ROLLBACK_PHASE="none"
}

watchdog_outer_expected_path_for_key() {
  local key="${1:-}" physical=""
  case "${key}" in
    launchd) printf '%s' "${WATCHDOG_LAUNCHD_DEST}" ;;
    systemd-service) printf '%s' "${WATCHDOG_SYSTEMD_SERVICE}" ;;
    systemd-timer) printf '%s' "${WATCHDOG_SYSTEMD_TIMER}" ;;
    settings)
      physical="$(resolve_regular_file_physical_path "${SETTINGS}" \
        2>/dev/null || true)"
      [[ -n "${physical}" ]] || return 1
      printf '%s' "${physical}"
      ;;
    config) printf '%s' "${CLAUDE_HOME}/oh-my-claude.conf" ;;
    *) return 1 ;;
  esac
}

watchdog_outer_load_meta() {
  local schema="" phase="" lock_id="" owner_pid="" owner_token=""
  local dir_id="" path_count="" launchd_loaded="" systemd_enabled=""
  local systemd_active="" stage_path="" stage_id="" pub_parent=""
  local pub_node="" pub_hash="" pub_mode="" quarantine_path=""
  local extra="" line="" rest="" field_index=0
  local settings_physical="" settings_parent="" stage_parent=""
  [[ -f "${WATCHDOG_OUTER_ROLLBACK_META}" \
      && ! -L "${WATCHDOG_OUTER_ROLLBACK_META}" ]] || return 1
  [[ "$(portable_file_mode "${WATCHDOG_OUTER_ROLLBACK_META}" \
        2>/dev/null || true)" == "600" ]] || return 1
  line="$(uninstall_read_canonical_metadata_line \
    "${WATCHDOG_OUTER_ROLLBACK_META}" 8192)" || return 1
  [[ "${line}" != *$'\t\t'* ]] || return 1
  rest="${line}"
  for ((field_index=1; field_index<17; field_index++)); do
    [[ "${rest}" == *$'\t'* ]] || return 1
    rest="${rest#*$'\t'}"
  done
  [[ "${rest}" != *$'\t'* ]] || return 1
  IFS=$'\t' read -r schema phase lock_id owner_pid owner_token dir_id \
    path_count launchd_loaded systemd_enabled systemd_active stage_path \
    stage_id pub_parent pub_node pub_hash pub_mode quarantine_path extra \
    <<< "${line}" || return 1
  [[ -z "${extra}" ]] || return 1
  [[ "${schema}" == "v2" \
      && "${phase}" =~ ^(preparing|prepared|cleanup-started|post-captured|settings-published|committed|rolled-back)$ \
      && "${lock_id}" == "${WATCHDOG_OUTER_RECOVERY_LOCK_ID}" \
      && "${owner_pid}" == "${WATCHDOG_OUTER_RECOVERY_OWNER_PID}" \
      && "${owner_token}" == "${WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN}" \
      && "${dir_id}" == "${WATCHDOG_OUTER_ROLLBACK_DIR_ID}" \
      && "${launchd_loaded}" =~ ^[01]$ \
      && "${systemd_enabled}" =~ ^[01]$ \
      && "${systemd_active}" =~ ^[01]$ ]] || return 1
  if [[ "${phase}" == "preparing" ]]; then
    [[ "${path_count}" == "0" ]] || return 1
  else
    [[ "${path_count}" =~ ^[45]$ ]] || return 1
  fi
  stage_path="$(watchdog_outer_unfield "${stage_path}")"
  stage_id="$(watchdog_outer_unfield "${stage_id}")"
  pub_parent="$(watchdog_outer_unfield "${pub_parent}")"
  pub_node="$(watchdog_outer_unfield "${pub_node}")"
  pub_hash="$(watchdog_outer_unfield "${pub_hash}")"
  pub_mode="$(watchdog_outer_unfield "${pub_mode}")"
  quarantine_path="$(watchdog_outer_unfield "${quarantine_path}")"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED=0
  if [[ -n "${stage_path}" ]]; then
    [[ "${stage_path}" == /* \
        && "${stage_path}" != *[[:cntrl:]]* \
        && "${stage_path##*/}" \
          =~ ^[.]settings[.]json[.]oh-my-claude-uninstall[.][A-Za-z0-9]+$ \
        && "${stage_id}" =~ ^[0-9]+:[0-9]+$ \
        && "${quarantine_path}" \
          == "${stage_path}.watchdog-quarantine" \
        && "${quarantine_path}" != *[[:cntrl:]]* ]] || return 1
  fi
  if [[ -n "${pub_hash}" ]]; then
    [[ "${pub_parent}" =~ ^[0-9]+:[0-9]+$ \
        && "${pub_node}" =~ ^[0-9]+:[0-9]+$ \
        && "${pub_hash}" =~ ^[0-9A-Fa-f]{64}$ \
        && "${pub_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED=1
  else
    [[ -z "${pub_parent}${pub_node}${pub_mode}" ]] || return 1
  fi
  if [[ -n "${stage_path}" ]]; then
    settings_physical="$(resolve_regular_file_physical_path \
      "${SETTINGS}" 2>/dev/null)" || return 1
    settings_parent="${settings_physical%/*}"
    stage_parent="${stage_path%/*}"
    [[ -n "${settings_parent}" ]] || settings_parent="/"
    [[ -n "${stage_parent}" ]] || stage_parent="/"
    [[ "${stage_id}" == "${pub_node}" \
        && "${stage_parent}" == "${settings_parent}" \
        && "$(portable_directory_identity "${settings_parent}" \
          2>/dev/null || true)" == "${pub_parent}" ]] || return 1
  else
    [[ -z "${stage_id}${quarantine_path}${pub_parent}${pub_node}${pub_hash}${pub_mode}" ]] \
      || return 1
  fi
  WATCHDOG_OUTER_ROLLBACK_PHASE="${phase}"
  WATCHDOG_OUTER_ROLLBACK_LOCK_ID="${lock_id}"
  WATCHDOG_OUTER_ROLLBACK_OWNER_PID="${owner_pid}"
  WATCHDOG_OUTER_ROLLBACK_OWNER_TOKEN="${owner_token}"
  WATCHDOG_OUTER_ROLLBACK_PATH_COUNT="${path_count}"
  WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED="${launchd_loaded}"
  WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED="${systemd_enabled}"
  WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE="${systemd_active}"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH="${stage_path}"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID="${stage_id}"
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH="${quarantine_path}"
  SETTINGS_PUBLISHED_PARENT_ID="${pub_parent}"
  SETTINGS_PUBLISHED_NODE_ID="${pub_node}"
  SETTINGS_PUBLISHED_HASH="${pub_hash}"
  SETTINGS_PUBLISHED_MODE="${pub_mode}"
}

watchdog_outer_load_initial_paths() {
  local file="${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.initial.tsv"
  local ledger_snapshot=""
  local key="" path="" parent_path="" parent_id="" state="" node_id=""
  local digest="" mode=""
  local snapshot_name="" snapshot_id="" snapshot_hash=""
  local snapshot_mode="" extra="" expected_key="" expected_path=""
  local count=0 snapshot=""
  [[ -f "${file}" && ! -L "${file}" \
      && "$(portable_file_mode "${file}" 2>/dev/null || true)" == "400" ]] \
    || return 1
  ledger_snapshot="$(uninstall_read_canonical_tsv_snapshot \
    "${file}" 12 1048576)" || return 1
  WATCHDOG_OUTER_ROLLBACK_KEYS=()
  WATCHDOG_OUTER_ROLLBACK_PATHS=()
  WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS=()
  WATCHDOG_OUTER_ROLLBACK_PARENT_IDS=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_IDS=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES=()
  while IFS=$'\t' read -r key path parent_path parent_id state node_id \
      digest mode snapshot_name snapshot_id snapshot_hash snapshot_mode \
      extra; do
    [[ -z "${extra}" ]] || return 1
    case "${count}:${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" in
      0:*) expected_key="launchd" ;;
      1:*) expected_key="systemd-service" ;;
      2:*) expected_key="systemd-timer" ;;
      3:5) expected_key="settings" ;;
      3:4|4:5) expected_key="config" ;;
      *) return 1 ;;
    esac
    expected_path="$(watchdog_outer_expected_path_for_key \
      "${expected_key}")" || return 1
    [[ "${key}" == "${expected_key}" && "${path}" == "${expected_path}" \
        && "${path}" != *[[:cntrl:]]* \
        && "${parent_path}" == /* \
        && "${parent_path}" != *[[:cntrl:]]* \
        && "${parent_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    node_id="$(watchdog_outer_unfield "${node_id}")"
    digest="$(watchdog_outer_unfield "${digest}")"
    mode="$(watchdog_outer_unfield "${mode}")"
    snapshot_name="$(watchdog_outer_unfield "${snapshot_name}")"
    snapshot_id="$(watchdog_outer_unfield "${snapshot_id}")"
    snapshot_hash="$(watchdog_outer_unfield "${snapshot_hash}")"
    snapshot_mode="$(watchdog_outer_unfield "${snapshot_mode}")"
    case "${state}" in
      absent)
        [[ -z "${node_id}${digest}${mode}${snapshot_name}${snapshot_id}${snapshot_hash}${snapshot_mode}" ]] \
          || return 1
        snapshot=""
        ;;
      regular)
        [[ "${node_id}" =~ ^[0-9]+:[0-9]+$ \
            && "${digest}" =~ ^[0-9A-Fa-f]{64}$ \
            && "${mode}" =~ ^[0-7]{3,4}$ \
            && "${snapshot_name}" == "${key}.initial" \
            && "${snapshot_id}" =~ ^[0-9]+:[0-9]+$ \
            && "${snapshot_hash}" == "${digest}" \
            && "${snapshot_mode}" == "400" ]] || return 1
        snapshot="${WATCHDOG_OUTER_ROLLBACK_DIR}/${snapshot_name}"
        ;;
      *) return 1 ;;
    esac
    WATCHDOG_OUTER_ROLLBACK_KEYS+=("${key}")
    WATCHDOG_OUTER_ROLLBACK_PATHS+=("${path}")
    WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS+=("${parent_path}")
    WATCHDOG_OUTER_ROLLBACK_PARENT_IDS+=("${parent_id}")
    WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES+=("${state}")
    WATCHDOG_OUTER_ROLLBACK_INITIAL_IDS+=("${node_id}")
    WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES+=("${digest}")
    WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES+=("${mode}")
    WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS+=("${snapshot}")
    WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS+=("${snapshot_id}")
    WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES+=("${snapshot_hash}")
    WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES+=("${snapshot_mode}")
    count=$((count + 1))
  done <<< "${ledger_snapshot}"
  [[ "${count}" -eq "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" ]] || return 1
  for ((count=0; count<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; count++)); do
    watchdog_outer_parent_authority_is_current "${count}" || return 1
    [[ "${WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES[count]}" != "regular" ]] \
      || watchdog_outer_snapshot_file_is_current "${count}" || return 1
  done
}

watchdog_outer_load_expected_paths() {
  local file="${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.expected.tsv"
  local ledger_snapshot=""
  local key="" state="" digest="" mode="" extra="" count=0
  [[ -f "${file}" && ! -L "${file}" \
      && "$(portable_file_mode "${file}" 2>/dev/null || true)" == "400" ]] \
    || return 1
  ledger_snapshot="$(uninstall_read_canonical_tsv_snapshot \
    "${file}" 4 1048576)" || return 1
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES=()
  while IFS=$'\t' read -r key state digest mode extra; do
    [[ -z "${extra}" && "${key}" == "${WATCHDOG_OUTER_ROLLBACK_KEYS[count]:-}" ]] \
      || return 1
    digest="$(watchdog_outer_unfield "${digest}")"
    mode="$(watchdog_outer_unfield "${mode}")"
    case "${state}" in
      absent) [[ -z "${digest}${mode}" ]] || return 1 ;;
      regular)
        [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ \
            && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
        ;;
      *) return 1 ;;
    esac
    WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES+=("${state}")
    WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES+=("${digest}")
    WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES+=("${mode}")
    count=$((count + 1))
  done <<< "${ledger_snapshot}"
  [[ "${count}" -eq "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" ]] || return 1
  for ((count=0; count<WATCHDOG_OUTER_ROLLBACK_PATH_COUNT; count++)); do
    if [[ "${WATCHDOG_OUTER_ROLLBACK_KEYS[count]}" == "config" ]]; then
      [[ -f "${WATCHDOG_OUTER_ROLLBACK_DIR}/config.expected" \
          && ! -L "${WATCHDOG_OUTER_ROLLBACK_DIR}/config.expected" \
          && "$(settings_sha256_file \
            "${WATCHDOG_OUTER_ROLLBACK_DIR}/config.expected" \
            2>/dev/null || true)" \
            == "${WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES[count]}" \
          && "$(portable_file_mode \
            "${WATCHDOG_OUTER_ROLLBACK_DIR}/config.expected" \
            2>/dev/null || true)" == "400" ]] || return 1
    fi
  done
}

watchdog_outer_load_cron_generation() {
  local phase="${1:-}" snapshot=""
  snapshot="${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.${phase}"
  local meta="${WATCHDOG_OUTER_ROLLBACK_DIR}/cron.${phase}.meta"
  local schema="" state="" snapshot_id="" snapshot_hash=""
  local snapshot_mode="" extra="" line="" rest="" field_index=0
  [[ "${phase}" == "initial" || "${phase}" == "expected" \
      || "${phase}" == "post" ]] || return 1
  [[ -f "${snapshot}" && ! -L "${snapshot}" \
      && -f "${meta}" && ! -L "${meta}" \
      && "$(portable_file_mode "${meta}" 2>/dev/null || true)" == "400" ]] \
    || return 1
  line="$(uninstall_read_canonical_metadata_line "${meta}" 2048)" \
    || return 1
  [[ "${line}" != *$'\t\t'* ]] || return 1
  rest="${line}"
  for ((field_index=1; field_index<5; field_index++)); do
    [[ "${rest}" == *$'\t'* ]] || return 1
    rest="${rest#*$'\t'}"
  done
  [[ "${rest}" != *$'\t'* ]] || return 1
  IFS=$'\t' read -r schema state snapshot_id snapshot_hash snapshot_mode \
    extra <<< "${line}" || return 1
  [[ -z "${extra}" ]] || return 1
  [[ "${schema}" == "v1" \
      && "${state}" =~ ^(present|absent|unavailable)$ \
      && "${snapshot_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${snapshot_hash}" =~ ^[0-9A-Fa-f]{64}$ \
      && "${snapshot_mode}" == "400" \
      && "$(portable_node_identity "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_id}" \
      && "$(settings_sha256_file "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_hash}" \
      && "$(portable_file_mode "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_mode}" ]] || return 1
  case "${phase}" in
    initial)
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL="${snapshot}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE="${state}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID="${snapshot_id}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH="${snapshot_hash}"
      WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE="${snapshot_mode}"
      ;;
    expected)
      WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED="${snapshot}"
      WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_STATE="${state}"
      WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_ID="${snapshot_id}"
      WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_HASH="${snapshot_hash}"
      WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_MODE="${snapshot_mode}"
      ;;
    post)
      WATCHDOG_OUTER_ROLLBACK_CRON_POST="${snapshot}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE="${state}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID="${snapshot_id}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH="${snapshot_hash}"
      WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE="${snapshot_mode}"
      ;;
  esac
}

watchdog_outer_load_post_paths() {
  local file="${WATCHDOG_OUTER_ROLLBACK_DIR}/paths.post.tsv"
  local ledger_snapshot=""
  local key="" state="" node_id="" digest="" mode="" extra="" count=0
  [[ -f "${file}" && ! -L "${file}" \
      && "$(portable_file_mode "${file}" 2>/dev/null || true)" == "400" ]] \
    || return 1
  ledger_snapshot="$(uninstall_read_canonical_tsv_snapshot \
    "${file}" 5 1048576)" || return 1
  WATCHDOG_OUTER_ROLLBACK_POST_STATES=()
  WATCHDOG_OUTER_ROLLBACK_POST_IDS=()
  WATCHDOG_OUTER_ROLLBACK_POST_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_POST_MODES=()
  while IFS=$'\t' read -r key state node_id digest mode extra; do
    [[ -z "${extra}" && "${key}" == "${WATCHDOG_OUTER_ROLLBACK_KEYS[count]:-}" ]] \
      || return 1
    node_id="$(watchdog_outer_unfield "${node_id}")"
    digest="$(watchdog_outer_unfield "${digest}")"
    mode="$(watchdog_outer_unfield "${mode}")"
    case "${state}" in
      absent) [[ -z "${node_id}${digest}${mode}" ]] || return 1 ;;
      regular)
        [[ "${node_id}" =~ ^[0-9]+:[0-9]+$ \
            && "${digest}" =~ ^[0-9A-Fa-f]{64}$ \
            && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
        ;;
      *) return 1 ;;
    esac
    WATCHDOG_OUTER_ROLLBACK_POST_STATES+=("${state}")
    WATCHDOG_OUTER_ROLLBACK_POST_IDS+=("${node_id}")
    WATCHDOG_OUTER_ROLLBACK_POST_HASHES+=("${digest}")
    WATCHDOG_OUTER_ROLLBACK_POST_MODES+=("${mode}")
    count=$((count + 1))
  done <<< "${ledger_snapshot}"
  [[ "${count}" -eq "${WATCHDOG_OUTER_ROLLBACK_PATH_COUNT}" ]] || return 1
  WATCHDOG_OUTER_ROLLBACK_POST_COUNT="${count}"
  WATCHDOG_OUTER_ROLLBACK_POST_CAPTURED=1
}

watchdog_outer_runtime_matches_initial() {
  local loaded=0 enabled=0 active=0
  if command -v launchctl >/dev/null 2>&1; then
    launchctl print "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
      >/dev/null 2>&1 && loaded=1
    [[ "${loaded}" -eq "${WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED}" ]] \
      || return 1
  elif [[ "${WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED}" -eq 1 ]]; then
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user is-enabled oh-my-claude-resume-watchdog.timer \
      >/dev/null 2>&1 && enabled=1
    systemctl --user is-active oh-my-claude-resume-watchdog.timer \
      >/dev/null 2>&1 && active=1
    [[ "${enabled}" -eq "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" \
        && "${active}" -eq "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" ]] \
      || return 1
  elif [[ "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED}" -eq 1 \
      || "${WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE}" -eq 1 ]]; then
    return 1
  fi
}

watchdog_outer_lock_has_participants() {
  local participant=""
  for participant in "${UNINSTALL_LOCK_DIR}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 0
  done
  return 1
}

watchdog_outer_remove_dead_recovery_claim() {
  local claim="${UNINSTALL_LOCK_DIR}/watchdog-outer-recovery-claim"
  local schema="" recovery_pid="" recovery_token="" lock_id=""
  local owner_pid="" owner_token="" stage_name="" extra="" claim_id=""
  local stage="" line="" rest="" field_index=0
  [[ -e "${claim}" || -L "${claim}" ]] || return 0
  [[ -f "${claim}" && ! -L "${claim}" \
      && "$(portable_file_mode "${claim}" 2>/dev/null || true)" == "600" ]] \
    || return 1
  claim_id="$(portable_node_identity "${claim}")" || return 1
  line="$(uninstall_read_canonical_metadata_line "${claim}" 2048)" \
    || return 1
  [[ "${line}" != *$'\t\t'* ]] || return 1
  rest="${line}"
  for ((field_index=1; field_index<7; field_index++)); do
    [[ "${rest}" == *$'\t'* ]] || return 1
    rest="${rest#*$'\t'}"
  done
  [[ "${rest}" != *$'\t'* ]] || return 1
  IFS=$'\t' read -r schema recovery_pid recovery_token lock_id owner_pid \
    owner_token stage_name extra <<< "${line}" || return 1
  [[ -z "${extra}" ]] || return 1
  [[ "${schema}" == "v1" && "${recovery_pid}" =~ ^[1-9][0-9]*$ \
      && -n "${recovery_token}" \
      && "${lock_id}" == "${WATCHDOG_OUTER_RECOVERY_LOCK_ID}" \
      && "${owner_pid}" == "${WATCHDOG_OUTER_RECOVERY_OWNER_PID}" \
      && "${owner_token}" == "${WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN}" \
      && "${stage_name}" =~ ^[.]watchdog-outer-recovery-claim[.]stage[.][A-Za-z0-9]+$ ]] \
    || return 1
  if kill -0 "${recovery_pid}" 2>/dev/null; then
    return 1
  fi
  stage="${UNINSTALL_LOCK_DIR}/${stage_name}"
  if [[ -e "${stage}" || -L "${stage}" ]]; then
    [[ -f "${stage}" && ! -L "${stage}" \
        && "$(portable_node_identity "${stage}" 2>/dev/null || true)" \
          == "${claim_id}" ]] || return 1
    rm -f -- "${stage}" || return 1
  fi
  [[ "$(portable_node_identity "${claim}" 2>/dev/null || true)" \
      == "${claim_id}" ]] || return 1
  rm -f -- "${claim}"
}

watchdog_outer_acquire_recovery_claim() {
  local stage="" stage_id="" stage_name="" claim=""
  watchdog_outer_remove_dead_recovery_claim || return 1
  claim="${UNINSTALL_LOCK_DIR}/watchdog-outer-recovery-claim"
  [[ ! -e "${claim}" && ! -L "${claim}" ]] || return 1
  stage="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/.watchdog-outer-recovery-claim.stage.XXXXXX")" \
    || return 1
  stage_name="${stage##*/}"
  WATCHDOG_OUTER_RECOVERY_CLAIM_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
  if ! printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\n' "$$" \
      "${WATCHDOG_OUTER_RECOVERY_CLAIM_TOKEN}" \
      "${WATCHDOG_OUTER_RECOVERY_LOCK_ID}" \
      "${WATCHDOG_OUTER_RECOVERY_OWNER_PID}" \
      "${WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN}" "${stage_name}" \
      > "${stage}" \
      || ! chmod 600 "${stage}"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  stage_id="$(portable_node_identity "${stage}")" || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  if ! ln "${stage}" "${claim}" 2>/dev/null; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  WATCHDOG_OUTER_RECOVERY_CLAIM="${claim}"
  WATCHDOG_OUTER_RECOVERY_CLAIM_ID="${stage_id}"
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE="${stage}"
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE_NAME="${stage_name}"
  if ! watchdog_outer_recovery_claim_is_current; then
    [[ "$(portable_node_identity "${claim}" 2>/dev/null || true)" \
      == "${stage_id}" ]] && rm -f -- "${claim}" 2>/dev/null || true
    [[ "$(portable_node_identity "${stage}" 2>/dev/null || true)" \
      == "${stage_id}" ]] && rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${stage}" || return 1
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE=""
  watchdog_outer_recovery_claim_is_current
}

watchdog_outer_release_recovery_claim() {
  if watchdog_outer_recovery_claim_is_current; then
    rm -f -- "${WATCHDOG_OUTER_RECOVERY_CLAIM}" 2>/dev/null || true
  fi
  if [[ -n "${WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE:-}" \
      && -f "${WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE}" \
      && ! -L "${WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE}" \
      && "$(portable_node_identity "${WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE}" \
        2>/dev/null || true)" == "${WATCHDOG_OUTER_RECOVERY_CLAIM_ID:-}" ]]; then
    rm -f -- "${WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE}" 2>/dev/null || true
  fi
  WATCHDOG_OUTER_RECOVERY_CLAIM=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_ID=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE_NAME=""
}

watchdog_outer_staged_settings_node_is_exact() {
  local path="${1:-}" settings_physical="" settings_parent=""
  local stage_parent=""
  [[ -n "${path}" ]] || return 1
  settings_physical="$(resolve_regular_file_physical_path \
    "${SETTINGS}" 2>/dev/null)" || return 1
  settings_parent="${settings_physical%/*}"
  stage_parent="${path%/*}"
  [[ -n "${settings_parent}" ]] || settings_parent="/"
  [[ -n "${stage_parent}" ]] || stage_parent="/"
  [[ -f "${path}" && ! -L "${path}" \
      && "${stage_parent}" == "${settings_parent}" \
      && "$(portable_directory_identity "${settings_parent}" \
        2>/dev/null || true)" == "${SETTINGS_PUBLISHED_PARENT_ID:-}" \
      && "$(portable_node_identity "${path}" 2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID:-}" \
      && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
        == "${SETTINGS_PUBLISHED_HASH:-}" \
      && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
        == "${SETTINGS_PUBLISHED_MODE:-}" ]] || return 1
}

watchdog_outer_recorded_settings_node_is_exact() {
  local path="${1:-}"
  [[ -n "${path}" && -f "${path}" && ! -L "${path}" \
      && "$(portable_node_identity "${path}" 2>/dev/null || true)" \
        == "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID:-}" \
      && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
        == "${SETTINGS_PUBLISHED_HASH:-}" \
      && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
        == "${SETTINGS_PUBLISHED_MODE:-}" ]]
}

# A rename can capture a different source generation in the final pathname
# window. Preserve that unexpected regular file by moving it back to the
# public stage pathname when the latter is vacant. The caller still fails
# closed: this restoration is about avoiding data loss, not granting the
# replacement the recorded inode's retirement authority.
watchdog_outer_unexpected_settings_node_is_current() {
  local path="${1:-}" kind="${2:-}" node_id="${3:-}"
  local digest="${4:-}" mode="${5:-}" link_text="${6:-}"
  [[ -n "${path}" && "${node_id}" =~ ^[0-9]+:[0-9]+$ \
      && "$(portable_node_identity "${path}" 2>/dev/null || true)" \
        == "${node_id}" ]] || return 1
  case "${kind}" in
    regular)
      [[ -f "${path}" && ! -L "${path}" \
          && "$(settings_sha256_file "${path}" 2>/dev/null || true)" \
            == "${digest}" \
          && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
            == "${mode}" ]]
      ;;
    symlink)
      [[ -L "${path}" \
          && "$(readlink "${path}" 2>/dev/null || true)" == "${link_text}" ]]
      ;;
    directory)
      [[ -d "${path}" && ! -L "${path}" \
          && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
            == "${mode}" ]]
      ;;
    other)
      [[ -e "${path}" && ! -L "${path}" \
          && ! -f "${path}" && ! -d "${path}" \
          && "$(portable_file_mode "${path}" 2>/dev/null || true)" \
            == "${mode}" ]]
      ;;
    *) return 1 ;;
  esac
}

watchdog_outer_restore_unexpected_settings_node() {
  local candidate="${1:-}" path="${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH:-}"
  local candidate_id="" candidate_hash="" candidate_mode=""
  local candidate_kind="" candidate_link=""
  [[ -n "${candidate}" && -n "${path}" \
      && ! -e "${path}" && ! -L "${path}" ]] || return 1
  [[ -e "${candidate}" || -L "${candidate}" ]] || return 1
  candidate_id="$(portable_node_identity "${candidate}")" || return 1
  if [[ -L "${candidate}" ]]; then
    candidate_kind="symlink"
    candidate_link="$(readlink "${candidate}")" || return 1
    [[ -n "${candidate_link}" \
        && "${candidate_link}" != *[[:cntrl:]]* ]] || return 1
  elif [[ -f "${candidate}" ]]; then
    candidate_kind="regular"
    candidate_hash="$(settings_sha256_file "${candidate}")" || return 1
    candidate_mode="$(portable_file_mode "${candidate}")" || return 1
    [[ "${candidate_hash}" =~ ^[0-9A-Fa-f]{64}$ \
        && "${candidate_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  elif [[ -d "${candidate}" ]]; then
    candidate_kind="directory"
    candidate_mode="$(portable_file_mode "${candidate}")" || return 1
    [[ "${candidate_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  else
    candidate_kind="other"
    candidate_mode="$(portable_file_mode "${candidate}")" || return 1
    [[ "${candidate_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  fi
  [[ "${candidate_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1
  watchdog_outer_unexpected_settings_node_is_current "${candidate}" \
    "${candidate_kind}" "${candidate_id}" "${candidate_hash}" \
    "${candidate_mode}" "${candidate_link}" || return 1
  [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
  mv -n -- "${candidate}" "${path}" || return 1
  [[ ! -e "${candidate}" && ! -L "${candidate}" ]] \
    && watchdog_outer_unexpected_settings_node_is_current "${path}" \
      "${candidate_kind}" "${candidate_id}" "${candidate_hash}" \
      "${candidate_mode}" "${candidate_link}"
}

watchdog_outer_unlink_recorded_retired_settings() (
  local retired_name="settings-stage.retired"
  local retired="./${retired_name}"
  local retired_absolute="${WATCHDOG_OUTER_ROLLBACK_DIR}/${retired_name}"
  watchdog_outer_rollback_directory_is_current || return 1
  builtin cd -- "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
  [[ "$(portable_directory_identity . 2>/dev/null || true)" \
      == "${WATCHDOG_OUTER_ROLLBACK_DIR_ID}" ]] || return 1
  watchdog_outer_recorded_settings_node_is_exact "${retired}" || return 1
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_FINAL_UNLINK_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_FINAL_UNLINK_RELEASE_FILE:-}" \
    "${retired_absolute}" || return 1
  if [[ "$(portable_directory_identity . 2>/dev/null || true)" \
        != "${WATCHDOG_OUTER_ROLLBACK_DIR_ID}" ]] \
      || ! watchdog_outer_recorded_settings_node_is_exact "${retired}"; then
    watchdog_outer_restore_unexpected_settings_node "${retired}" \
      >/dev/null 2>&1 || true
    return 1
  fi
  # The final unlink is relative to the cwd-pinned private WAL inode. Its
  # namespace is owned by the exact uninstall lock/recovery claim, and the
  # deterministic seam above is followed by one final leaf-generation check.
  rm -f -- "${retired}" || return 1
  [[ ! -e "${retired}" && ! -L "${retired}" ]]
)

# Retire the rendered settings stage through a same-filesystem quarantine.
# The quarantine pathname is committed in meta.tsv before scheduler mutation,
# so SIGKILL at any point leaves one replayable exact generation at the source,
# external quarantine, or WAL-local retired pathname. Unexpected generations
# are restored when possible and are never unlinked under the old inode's
# authority.
watchdog_outer_remove_exact_staged_settings() {
  local path="${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH:-}"
  local quarantine="${WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH:-}"
  local retired="${WATCHDOG_OUTER_ROLLBACK_DIR}/settings-stage.retired"
  [[ -n "${path}" ]] || {
    [[ -z "${quarantine}" ]] || return 1
    return 0
  }
  [[ "${quarantine}" == "${path}.watchdog-quarantine" \
      && "${quarantine}" != *[[:cntrl:]]* ]] || return 1
  watchdog_outer_rollback_directory_is_current || return 1

  if [[ -e "${retired}" || -L "${retired}" ]]; then
    if ! watchdog_outer_recorded_settings_node_is_exact "${retired}"; then
      watchdog_outer_restore_unexpected_settings_node "${retired}" \
        >/dev/null 2>&1 || true
      return 1
    fi
  else
    if [[ -e "${quarantine}" || -L "${quarantine}" ]]; then
      if ! watchdog_outer_staged_settings_node_is_exact "${quarantine}"; then
        watchdog_outer_restore_unexpected_settings_node "${quarantine}" \
          >/dev/null 2>&1 || true
        return 1
      fi
    else
      if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        return 0
      fi
      watchdog_outer_staged_settings_node_is_exact "${path}" || return 1
      uninstall_test_barrier \
        "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_READY_FILE:-}" \
        "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_RELEASE_FILE:-}" \
        "${path}" || return 1
      watchdog_outer_rollback_directory_is_current \
        && watchdog_outer_staged_settings_node_is_exact "${path}" \
        && [[ ! -e "${quarantine}" && ! -L "${quarantine}" ]] \
        || return 1
      uninstall_test_barrier \
        "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_SOURCE_CHECKED_READY_FILE:-}" \
        "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_SOURCE_CHECKED_RELEASE_FILE:-}" \
        "${path}" || return 1
      uninstall_test_barrier \
        "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_DESTINATION_READY_FILE:-}" \
        "${OMC_TEST_UNINSTALL_SETTINGS_RETIRE_DESTINATION_RELEASE_FILE:-}" \
        "${quarantine}" || return 1
      # -n makes a destination collision non-destructive. A source swap is
      # detected from the moved inode and durably restored above.
      mv -n -- "${path}" "${quarantine}" || return 1
      if ! watchdog_outer_staged_settings_node_is_exact "${quarantine}"; then
        watchdog_outer_restore_unexpected_settings_node "${quarantine}" \
          >/dev/null 2>&1 || true
        return 1
      fi
    fi

    uninstall_test_barrier \
      "${OMC_TEST_UNINSTALL_SETTINGS_QUARANTINED_READY_FILE:-}" \
      "${OMC_TEST_UNINSTALL_SETTINGS_QUARANTINED_RELEASE_FILE:-}" \
      "${quarantine}" || return 1
    watchdog_outer_rollback_directory_is_current \
      && watchdog_outer_staged_settings_node_is_exact "${quarantine}" \
      && [[ ! -e "${retired}" && ! -L "${retired}" ]] \
      || return 1
    mv -n -- "${quarantine}" "${retired}" || return 1
    if ! watchdog_outer_recorded_settings_node_is_exact "${retired}"; then
      watchdog_outer_restore_unexpected_settings_node "${retired}" \
        >/dev/null 2>&1 || true
      return 1
    fi
  fi

  watchdog_outer_unlink_recorded_retired_settings || return 1
  [[ ! -e "${retired}" && ! -L "${retired}" \
      && ! -e "${quarantine}" && ! -L "${quarantine}" ]]
}

watchdog_outer_retired_tree_is_exact() {
  local root="${1:-}" lock_id="${2:-}" node="" relative="" node_id=""
  local root_device=""
  [[ -d "${root}" && ! -L "${root}" \
      && "$(portable_node_identity "${root}" 2>/dev/null || true)" \
        == "${lock_id}" ]] || return 1
  root_device="${lock_id%%:*}"
  (
    set -o pipefail
    find -P "${root}" -mindepth 1 -print0 2>/dev/null \
      | while IFS= read -r -d '' node; do
          relative="${node#"${root}"/}"
          [[ "${relative}" != "${node}" \
              && "${relative}" != *[[:cntrl:]]* \
              && ! -L "${node}" ]] || exit 1
          node_id="$(portable_node_identity "${node}")" || exit 1
          [[ "${node_id}" == "${root_device}:"* ]] || exit 1
          if [[ -d "${node}" ]]; then
            case "${relative}" in
              transaction-recovery|watchdog-outer-rollback) ;;
              watchdog-source.*)
                [[ "${relative}" != */* \
                    && "${relative#watchdog-source.}" \
                      =~ ^[A-Za-z0-9]+$ ]] || exit 1
                ;;
              *) exit 1 ;;
            esac
          elif [[ -f "${node}" ]]; then
            case "${relative}" in
              pid|token|owner-released|watchdog-outer-recovery-claim|\
              .watchdog-outer-recovery-claim.stage.*|\
              removal-seals.*|removal-ancestors.*|removal-trees.*|\
              removal-tree-enumeration.*|removal-seals-refresh.*|\
              removal-ancestors-refresh.*)
                [[ "${relative}" != */* ]] || exit 1
                ;;
              settings-patch.*)
                [[ "${relative}" != */* \
                    && "${relative#settings-patch.}" \
                      =~ ^[A-Za-z0-9]+$ ]] || exit 1
                ;;
              watchdog-source.*/install-resume-watchdog.sh)
                [[ "${relative%/*}" != */* \
                    && "${relative%/*}" \
                      =~ ^watchdog-source[.][A-Za-z0-9]+$ ]] \
                  || exit 1
                ;;
              transaction-recovery/seals.tsv|\
              transaction-recovery/switch-tier.sh|\
              transaction-recovery/omc-config.sh|\
              watchdog-outer-rollback/meta.tsv|\
              watchdog-outer-rollback/paths.initial.tsv|\
              watchdog-outer-rollback/paths.expected.tsv|\
              watchdog-outer-rollback/paths.post.tsv|\
              watchdog-outer-rollback/config.expected|\
              watchdog-outer-rollback/cron.initial|\
              watchdog-outer-rollback/cron.initial.meta|\
              watchdog-outer-rollback/cron.expected|\
              watchdog-outer-rollback/cron.expected.meta|\
              watchdog-outer-rollback/cron.post|\
              watchdog-outer-rollback/cron.post.meta|\
              watchdog-outer-rollback/launchd.initial|\
              watchdog-outer-rollback/systemd-service.initial|\
              watchdog-outer-rollback/systemd-timer.initial|\
              watchdog-outer-rollback/settings.initial|\
              watchdog-outer-rollback/config.initial|\
              watchdog-outer-rollback/.meta.*|\
              watchdog-outer-rollback/.paths-*|\
              watchdog-outer-rollback/.cron-*-meta.*|\
              watchdog-outer-rollback/.config-expected-one.*|\
              watchdog-outer-rollback/.text-hash.*|\
              watchdog-outer-rollback/cron.current.*) ;;
              *) exit 1 ;;
            esac
          else
            exit 1
          fi
        done
  )
}

watchdog_outer_retire_recovered_lock() {
  local retired_root="" retired_root_id="" retired_lock=""
  watchdog_outer_recovery_claim_is_current || return 1
  watchdog_outer_lock_has_participants && return 1
  retired_root="$(mktemp -d \
    "${CLAUDE_HOME}/.install-lock-watchdog-recovered.XXXXXX")" || return 1
  chmod 700 "${retired_root}" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_root_id="$(portable_node_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  watchdog_outer_recovery_claim_is_current || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  mv -- "${UNINSTALL_LOCK_DIR}" "${retired_lock}" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  [[ "$(portable_node_identity "${retired_root}" 2>/dev/null || true)" \
      == "${retired_root_id}" \
      && "$(portable_node_identity "${retired_lock}" \
        2>/dev/null || true)" == "${WATCHDOG_OUTER_RECOVERY_LOCK_ID}" ]] \
    || return 1
  if ! watchdog_outer_retired_tree_is_exact "${retired_lock}" \
      "${WATCHDOG_OUTER_RECOVERY_LOCK_ID}"; then
    printf 'WARNING: recovered scheduler state, but preserved an unexpected retired uninstall-lock tree for inspection: %s\n' \
      "${retired_root}" >&2
    return 0
  fi
  rm -rf -- "${retired_lock}" || return 1
  [[ "$(portable_node_identity "${retired_root}" 2>/dev/null || true)" \
      == "${retired_root_id}" ]] || return 1
  rmdir "${retired_root}"
}

recover_stranded_watchdog_outer_transaction() {
  local owner_pid="" owner_token="" recovery_rc=0
  local fixed_wal="${UNINSTALL_LOCK_DIR}/watchdog-outer-rollback"
  local wal="" wal_is_staged=0 had_nullglob=0 staged_name=""
  local staged_meta_id="" staged_meta_hash=""
  local -a staged_wals=()
  if [[ ! -d "${UNINSTALL_LOCK_DIR}" || -L "${UNINSTALL_LOCK_DIR}" \
      || ! -f "${UNINSTALL_LOCK_DIR}/pid" \
      || -L "${UNINSTALL_LOCK_DIR}/pid" \
      || ! -f "${UNINSTALL_LOCK_DIR}/token" \
      || -L "${UNINSTALL_LOCK_DIR}/token" \
      || "$(portable_file_mode "${UNINSTALL_LOCK_DIR}" \
        2>/dev/null || true)" != "700" ]]; then
    printf 'Refusing automatic uninstall recovery because the stranded lock/WAL shape is unsafe: %s\n' \
      "${UNINSTALL_LOCK_DIR}" >&2
    return 2
  fi
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  staged_wals=(
    "${UNINSTALL_LOCK_DIR}"/.watchdog-outer-rollback.stage.*
  )
  [[ "${had_nullglob}" -eq 1 ]] || shopt -u nullglob
  if [[ -e "${fixed_wal}" || -L "${fixed_wal}" ]]; then
    [[ "${#staged_wals[@]}" -eq 0 ]] || {
      printf 'Refusing automatic uninstall recovery because fixed and staged watchdog WAL generations coexist: %s\n' \
        "${UNINSTALL_LOCK_DIR}" >&2
      return 2
    }
    wal="${fixed_wal}"
  else
    case "${#staged_wals[@]}" in
      0) return 1 ;;
      1)
        wal="${staged_wals[0]}"
        wal_is_staged=1
        staged_name="${wal##*/}"
        ;;
      *)
        printf 'Refusing automatic uninstall recovery because multiple staged watchdog WAL generations exist: %s\n' \
          "${UNINSTALL_LOCK_DIR}" >&2
        return 2
        ;;
    esac
  fi
  if [[ ! -d "${wal}" || -L "${wal}" \
      || "$(portable_file_mode "${wal}" 2>/dev/null || true)" != "700" ]] \
      || { [[ "${wal_is_staged}" -eq 1 ]] \
        && [[ ! "${staged_name}" \
          =~ ^[.]watchdog-outer-rollback[.]stage[.][A-Za-z0-9]+$ ]]; }; then
    printf 'Refusing automatic uninstall recovery because the stranded lock/WAL shape is unsafe: %s\n' \
      "${UNINSTALL_LOCK_DIR}" >&2
    return 2
  fi
  WATCHDOG_OUTER_RECOVERY_LOCK_ID="$(portable_node_identity \
    "${UNINSTALL_LOCK_DIR}")" || return 2
  owner_pid="$(uninstall_read_canonical_metadata_line \
    "${UNINSTALL_LOCK_DIR}/pid" 32)" || return 2
  owner_token="$(uninstall_read_canonical_metadata_line \
    "${UNINSTALL_LOCK_DIR}/token" 512)" || return 2
  [[ "${owner_pid}" =~ ^[1-9][0-9]*$ && -n "${owner_token}" \
      && "${owner_token}" != *[[:cntrl:]]* ]] || return 2
  if kill -0 "${owner_pid}" 2>/dev/null; then
    return 1
  fi
  WATCHDOG_OUTER_RECOVERY_OWNER_PID="${owner_pid}"
  WATCHDOG_OUTER_RECOVERY_OWNER_TOKEN="${owner_token}"
  watchdog_outer_lock_has_participants && return 1
  WATCHDOG_OUTER_RECOVERY_ACTIVE=1
  if ! watchdog_outer_acquire_recovery_claim; then
    WATCHDOG_OUTER_RECOVERY_ACTIVE=0
    return 1
  fi
  WATCHDOG_OUTER_ROLLBACK_DIR="${wal}"
  WATCHDOG_OUTER_ROLLBACK_DIR_ID="$(portable_node_identity "${wal}")" \
    || recovery_rc=1
  WATCHDOG_OUTER_ROLLBACK_META="${wal}/meta.tsv"
  if [[ "${recovery_rc}" -eq 0 && "${wal_is_staged}" -eq 1 ]]; then
    [[ -n "${SETTINGS_SHA256_TOOL}" ]] \
      || SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool \
        2>/dev/null || true)"
    [[ -n "${SETTINGS_SHA256_TOOL}" ]] || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 && "${wal_is_staged}" -eq 1 ]]; then
    staged_meta_id="$(portable_node_identity \
      "${WATCHDOG_OUTER_ROLLBACK_META}" 2>/dev/null || true)"
    staged_meta_hash="$(settings_sha256_file \
      "${WATCHDOG_OUTER_ROLLBACK_META}" 2>/dev/null || true)"
    [[ -n "${staged_meta_id}" \
        && "${staged_meta_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] \
      || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 ]]; then
    watchdog_outer_load_meta || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 && "${wal_is_staged}" -eq 1 ]]; then
    [[ "${WATCHDOG_OUTER_ROLLBACK_PHASE}" == "preparing" ]] \
      || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 && "${wal_is_staged}" -eq 1 ]]; then
    watchdog_outer_recovery_claim_is_current \
      && watchdog_outer_rollback_directory_is_current \
      && [[ "$(portable_node_identity \
          "${WATCHDOG_OUTER_ROLLBACK_META}" 2>/dev/null || true)" \
        == "${staged_meta_id}" ]] \
      && [[ "$(settings_sha256_file \
          "${WATCHDOG_OUTER_ROLLBACK_META}" 2>/dev/null || true)" \
        == "${staged_meta_hash}" ]] \
      && [[ ! -e "${fixed_wal}" && ! -L "${fixed_wal}" ]] \
      && mv -- "${wal}" "${fixed_wal}" \
      || recovery_rc=1
    if [[ "${recovery_rc}" -eq 0 ]]; then
      wal="${fixed_wal}"
      WATCHDOG_OUTER_ROLLBACK_DIR="${fixed_wal}"
      WATCHDOG_OUTER_ROLLBACK_META="${fixed_wal}/meta.tsv"
      watchdog_outer_rollback_directory_is_current \
        && [[ "$(portable_node_identity \
            "${WATCHDOG_OUTER_ROLLBACK_META}" 2>/dev/null || true)" \
          == "${staged_meta_id}" ]] \
        || recovery_rc=1
    fi
  fi
  if [[ "${recovery_rc}" -eq 0 ]] \
      && { [[ "${WATCHDOG_OUTER_ROLLBACK_PHASE}" != "preparing" ]] \
        || [[ -n "${WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH:-}" ]]; }; then
    [[ -n "${SETTINGS_SHA256_TOOL}" ]] \
      || SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool \
        2>/dev/null || true)"
    [[ -n "${SETTINGS_SHA256_TOOL}" ]] || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 \
      && "${WATCHDOG_OUTER_ROLLBACK_PHASE}" != "preparing" ]]; then
    watchdog_outer_load_initial_paths \
      && watchdog_outer_load_expected_paths \
      && watchdog_outer_load_cron_generation initial \
      && watchdog_outer_load_cron_generation expected \
      || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 ]]; then
    WATCHDOG_OUTER_ROLLBACK_PREPARED=1
    case "${WATCHDOG_OUTER_ROLLBACK_PHASE}" in
      preparing)
        WATCHDOG_OUTER_ROLLBACK_ARMED=0
        ;;
      prepared)
        watchdog_outer_all_initial_paths_are_current \
          && watchdog_outer_cron_initial_is_current \
          && watchdog_outer_runtime_matches_initial \
          && watchdog_outer_publish_meta rolled-back \
          || recovery_rc=1
        ;;
      cleanup-started)
        WATCHDOG_OUTER_ROLLBACK_ARMED=1
        rollback_watchdog_outer_transaction || recovery_rc=1
        ;;
      post-captured|settings-published)
        watchdog_outer_load_post_paths \
          && watchdog_outer_load_cron_generation post \
          || recovery_rc=1
        if [[ "${recovery_rc}" -eq 0 ]]; then
          WATCHDOG_OUTER_ROLLBACK_ARMED=1
          rollback_watchdog_outer_transaction || recovery_rc=1
        fi
        ;;
      rolled-back)
        watchdog_outer_all_initial_paths_are_current \
          && watchdog_outer_cron_initial_is_current \
          && watchdog_outer_runtime_matches_initial \
          || recovery_rc=1
        ;;
      committed)
        WATCHDOG_OUTER_ROLLBACK_ARMED=0
        ;;
      *) recovery_rc=1 ;;
    esac
  fi
  if [[ "${recovery_rc}" -eq 0 ]]; then
    watchdog_outer_remove_exact_staged_settings || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 ]]; then
    uninstall_test_barrier \
      "${OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_READY_FILE:-}" \
      "${OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_RELEASE_FILE:-}" \
      "${wal}" || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -eq 0 ]]; then
    printf 'Recovering the exact scheduler/config generation from an interrupted uninstall.\n' >&2
    watchdog_outer_retire_recovered_lock || recovery_rc=1
  fi
  if [[ "${recovery_rc}" -ne 0 ]]; then
    printf 'Refusing automatic uninstall recovery because the exact durable watchdog rollback generation could not be validated or restored: %s\n' \
      "${wal}" >&2
    watchdog_outer_release_recovery_claim
    WATCHDOG_OUTER_RECOVERY_ACTIVE=0
    return 2
  fi
  WATCHDOG_OUTER_RECOVERY_ACTIVE=0
  WATCHDOG_OUTER_RECOVERY_CLAIM=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_ID=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_TOKEN=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE=""
  WATCHDOG_OUTER_RECOVERY_CLAIM_STAGE_NAME=""
  WATCHDOG_OUTER_ROLLBACK_DIR=""
  WATCHDOG_OUTER_ROLLBACK_DIR_ID=""
  WATCHDOG_OUTER_ROLLBACK_META=""
  WATCHDOG_OUTER_ROLLBACK_PHASE="none"
  WATCHDOG_OUTER_ROLLBACK_PREPARED=0
  WATCHDOG_OUTER_ROLLBACK_POST_CAPTURED=0
  WATCHDOG_OUTER_ROLLBACK_ARMED=0
  WATCHDOG_OUTER_ROLLBACK_PATH_COUNT=0
  WATCHDOG_OUTER_ROLLBACK_POST_COUNT=0
  WATCHDOG_OUTER_ROLLBACK_KEYS=()
  WATCHDOG_OUTER_ROLLBACK_PATHS=()
  WATCHDOG_OUTER_ROLLBACK_PARENT_PATHS=()
  WATCHDOG_OUTER_ROLLBACK_PARENT_IDS=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_STATES=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_IDS=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_INITIAL_MODES=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOTS=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_IDS=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_SNAPSHOT_MODES=()
  WATCHDOG_OUTER_ROLLBACK_POST_STATES=()
  WATCHDOG_OUTER_ROLLBACK_POST_IDS=()
  WATCHDOG_OUTER_ROLLBACK_POST_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_POST_MODES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_STATES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_HASHES=()
  WATCHDOG_OUTER_ROLLBACK_EXPECTED_MODES=()
  WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL=""
  WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_ID=""
  WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_HASH=""
  WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_MODE=""
  WATCHDOG_OUTER_ROLLBACK_CRON_INITIAL_STATE="unavailable"
  WATCHDOG_OUTER_ROLLBACK_CRON_POST=""
  WATCHDOG_OUTER_ROLLBACK_CRON_POST_ID=""
  WATCHDOG_OUTER_ROLLBACK_CRON_POST_HASH=""
  WATCHDOG_OUTER_ROLLBACK_CRON_POST_MODE=""
  WATCHDOG_OUTER_ROLLBACK_CRON_POST_STATE="unavailable"
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED=""
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_ID=""
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_HASH=""
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_MODE=""
  WATCHDOG_OUTER_ROLLBACK_CRON_EXPECTED_STATE="unavailable"
  WATCHDOG_OUTER_ROLLBACK_LAUNCHD_LOADED=0
  WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ENABLED=0
  WATCHDOG_OUTER_ROLLBACK_SYSTEMD_ACTIVE=0
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_PATH=""
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_STAGE_ID=""
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_QUARANTINE_PATH=""
  WATCHDOG_OUTER_ROLLBACK_SETTINGS_PUBLISHED_EXPECTED=0
  SETTINGS_PUBLISHED_PARENT_ID=""
  SETTINGS_PUBLISHED_NODE_ID=""
  SETTINGS_PUBLISHED_HASH=""
  SETTINGS_PUBLISHED_MODE=""
  return 0
}

watchdog_helper_source_is_current() {
  local source_parent="${WATCHDOG_HELPER_SOURCE%/*}"
  [[ -f "${WATCHDOG_HELPER_SOURCE}" \
      && ! -L "${WATCHDOG_HELPER_SOURCE}" \
      && -d "${source_parent}" && ! -L "${source_parent}" \
      && "$(portable_directory_identity "${source_parent}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SOURCE_PARENT_ID}" \
      && "$(portable_node_identity "${WATCHDOG_HELPER_SOURCE}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SOURCE_NODE_ID}" \
      && "$(settings_sha256_file "${WATCHDOG_HELPER_SOURCE}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SOURCE_HASH}" \
      && "$(portable_file_mode "${WATCHDOG_HELPER_SOURCE}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SOURCE_MODE}" ]]
}

watchdog_helper_snapshot_is_current() {
  [[ -n "${WATCHDOG_HELPER_SNAPSHOT}" \
      && -f "${WATCHDOG_HELPER_SNAPSHOT}" \
      && ! -L "${WATCHDOG_HELPER_SNAPSHOT}" \
      && -d "${WATCHDOG_HELPER_SNAPSHOT_DIR}" \
      && ! -L "${WATCHDOG_HELPER_SNAPSHOT_DIR}" \
      && "$(portable_node_identity "${WATCHDOG_HELPER_SNAPSHOT_DIR}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SNAPSHOT_DIR_ID}" \
      && "$(portable_node_identity "${WATCHDOG_HELPER_SNAPSHOT}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SNAPSHOT_NODE_ID}" \
      && "$(settings_sha256_file "${WATCHDOG_HELPER_SNAPSHOT}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SNAPSHOT_HASH}" \
      && "$(portable_file_mode "${WATCHDOG_HELPER_SNAPSHOT}" \
        2>/dev/null || true)" == "${WATCHDOG_HELPER_SNAPSHOT_MODE}" ]]
}

prepare_watchdog_helper_snapshot() {
  local source_parent="${WATCHDOG_HELPER_SOURCE%/*}" copied_hash=""
  preflight_no_symlinked_path_components "${WATCHDOG_HELPER_SOURCE}" \
    || return 1
  [[ -f "${WATCHDOG_HELPER_SOURCE}" \
      && ! -L "${WATCHDOG_HELPER_SOURCE}" ]] || return 1
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] \
    || SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool \
      2>/dev/null || true)"
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] || return 1
  WATCHDOG_HELPER_SOURCE_PARENT_ID="$(portable_directory_identity \
    "${source_parent}")" || return 1
  WATCHDOG_HELPER_SOURCE_NODE_ID="$(portable_node_identity \
    "${WATCHDOG_HELPER_SOURCE}")" || return 1
  WATCHDOG_HELPER_SOURCE_HASH="$(settings_sha256_file \
    "${WATCHDOG_HELPER_SOURCE}")" || return 1
  WATCHDOG_HELPER_SOURCE_MODE="$(portable_file_mode \
    "${WATCHDOG_HELPER_SOURCE}")" || return 1
  WATCHDOG_HELPER_SNAPSHOT_DIR="$(mktemp -d \
    "${UNINSTALL_LOCK_DIR}/watchdog-source.XXXXXX")" || return 1
  chmod 700 "${WATCHDOG_HELPER_SNAPSHOT_DIR}" || return 1
  WATCHDOG_HELPER_SNAPSHOT_DIR_ID="$(portable_node_identity \
    "${WATCHDOG_HELPER_SNAPSHOT_DIR}")" || return 1
  WATCHDOG_HELPER_SNAPSHOT="${WATCHDOG_HELPER_SNAPSHOT_DIR}/install-resume-watchdog.sh"
  cp -p -- "${WATCHDOG_HELPER_SOURCE}" "${WATCHDOG_HELPER_SNAPSHOT}" \
    || return 1
  chmod 400 "${WATCHDOG_HELPER_SNAPSHOT}" || return 1
  copied_hash="$(settings_sha256_file "${WATCHDOG_HELPER_SNAPSHOT}")" \
    || return 1
  [[ "${copied_hash}" == "${WATCHDOG_HELPER_SOURCE_HASH}" ]] || return 1
  WATCHDOG_HELPER_SNAPSHOT_NODE_ID="$(portable_node_identity \
    "${WATCHDOG_HELPER_SNAPSHOT}")" || return 1
  WATCHDOG_HELPER_SNAPSHOT_HASH="${copied_hash}"
  WATCHDOG_HELPER_SNAPSHOT_MODE="$(portable_file_mode \
    "${WATCHDOG_HELPER_SNAPSHOT}")" || return 1
  watchdog_helper_source_is_current \
    && watchdog_helper_snapshot_is_current
}

TRANSACTION_RECOVERY_SWITCHER_SOURCE="${SCRIPT_DIR}/bundle/dot-claude/switch-tier.sh"
TRANSACTION_RECOVERY_CONFIGURER_SOURCE="${SCRIPT_DIR}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"

transaction_metadata_present() {
  local candidate=""
  for candidate in \
      "${CLAUDE_HOME}/.switch-tier-transaction" \
      "${CLAUDE_HOME}"/.switch-tier-transaction.stage.* \
      "${CLAUDE_HOME}"/.switch-tier-retired.* \
      "${CLAUDE_HOME}/.omc-config-transaction" \
      "${CLAUDE_HOME}"/.omc-config-transaction.stage.* \
      "${CLAUDE_HOME}"/.omc-config-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

switch_transaction_metadata_present() {
  local candidate=""
  for candidate in \
      "${CLAUDE_HOME}/.switch-tier-transaction" \
      "${CLAUDE_HOME}"/.switch-tier-transaction.stage.* \
      "${CLAUDE_HOME}"/.switch-tier-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

omc_config_transaction_metadata_present() {
  local candidate=""
  for candidate in \
      "${CLAUDE_HOME}/.omc-config-transaction" \
      "${CLAUDE_HOME}"/.omc-config-transaction.stage.* \
      "${CLAUDE_HOME}"/.omc-config-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

snapshot_transaction_recovery_helper() {
  local source="${1:-}" snapshot="${2:-}" source_parent=""
  local source_parent_id="" source_node_id="" source_hash="" source_mode=""
  local snapshot_node_id="" snapshot_hash="" snapshot_mode=""
  [[ "${source}" == /* && "${snapshot}" == /* \
      && "${source}" != *[[:cntrl:]]* \
      && "${snapshot}" != *[[:cntrl:]]* ]] || return 1
  preflight_no_symlinked_path_components "${source}" || return 1
  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  source_parent="${source%/*}"
  source_parent_id="$(portable_directory_identity "${source_parent}")" \
    || return 1
  source_node_id="$(portable_node_identity "${source}")" || return 1
  source_hash="$(settings_sha256_file "${source}")" || return 1
  source_mode="$(portable_file_mode "${source}")" || return 1
  cp -p -- "${source}" "${snapshot}" || return 1
  chmod 400 "${snapshot}" || return 1
  snapshot_node_id="$(portable_node_identity "${snapshot}")" || return 1
  snapshot_hash="$(settings_sha256_file "${snapshot}")" || return 1
  snapshot_mode="$(portable_file_mode "${snapshot}")" || return 1
  [[ "${snapshot_hash}" == "${source_hash}" \
      && "${snapshot_mode}" == "400" \
      && -f "${source}" && ! -L "${source}" \
      && "$(portable_directory_identity "${source_parent}" \
        2>/dev/null || true)" == "${source_parent_id}" \
      && "$(portable_node_identity "${source}" \
        2>/dev/null || true)" == "${source_node_id}" \
      && "$(settings_sha256_file "${source}" \
        2>/dev/null || true)" == "${source_hash}" \
      && "$(portable_file_mode "${source}" \
        2>/dev/null || true)" == "${source_mode}" ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${source}" "${source_parent_id}" "${source_node_id}" \
    "${source_hash}" "${source_mode}" "${snapshot}" \
    "${snapshot_node_id}" "${snapshot_hash}" "${snapshot_mode}" \
    >> "${TRANSACTION_RECOVERY_SEALS}"
}

transaction_recovery_helpers_are_current() {
  local source="" source_parent_id="" source_node_id="" source_hash=""
  local source_mode="" snapshot="" snapshot_node_id="" snapshot_hash=""
  local snapshot_mode="" source_parent="" row_count=0
  [[ -n "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" \
      && -d "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" \
      && ! -L "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" \
      && "$(portable_node_identity \
        "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" 2>/dev/null || true)" \
        == "${TRANSACTION_RECOVERY_SNAPSHOT_DIR_ID}" \
      && -f "${TRANSACTION_RECOVERY_SEALS}" \
      && ! -L "${TRANSACTION_RECOVERY_SEALS}" \
      && "$(portable_node_identity "${TRANSACTION_RECOVERY_SEALS}" \
        2>/dev/null || true)" == "${TRANSACTION_RECOVERY_SEALS_ID}" \
      && "$(settings_sha256_file "${TRANSACTION_RECOVERY_SEALS}" \
        2>/dev/null || true)" == "${TRANSACTION_RECOVERY_SEALS_HASH}" \
      && "$(portable_file_mode "${TRANSACTION_RECOVERY_SEALS}" \
        2>/dev/null || true)" == "${TRANSACTION_RECOVERY_SEALS_MODE}" ]] \
    || return 1
  while IFS=$'\t' read -r source source_parent_id source_node_id \
      source_hash source_mode snapshot snapshot_node_id snapshot_hash \
      snapshot_mode; do
    row_count=$((row_count + 1))
    [[ -n "${source}" && -n "${snapshot_mode}" \
        && "${source}" != *[[:cntrl:]]* \
        && "${snapshot}" != *[[:cntrl:]]* ]] || return 1
    source_parent="${source%/*}"
    [[ -f "${source}" && ! -L "${source}" \
        && "$(portable_directory_identity "${source_parent}" \
          2>/dev/null || true)" == "${source_parent_id}" \
        && "$(portable_node_identity "${source}" \
          2>/dev/null || true)" == "${source_node_id}" \
        && "$(settings_sha256_file "${source}" \
          2>/dev/null || true)" == "${source_hash}" \
        && "$(portable_file_mode "${source}" \
          2>/dev/null || true)" == "${source_mode}" \
        && -f "${snapshot}" && ! -L "${snapshot}" \
        && "$(portable_node_identity "${snapshot}" \
          2>/dev/null || true)" == "${snapshot_node_id}" \
        && "$(settings_sha256_file "${snapshot}" \
          2>/dev/null || true)" == "${snapshot_hash}" \
        && "$(portable_file_mode "${snapshot}" \
          2>/dev/null || true)" == "${snapshot_mode}" ]] || return 1
  done < "${TRANSACTION_RECOVERY_SEALS}"
  [[ "${row_count}" -eq 2 ]]
}

prepare_transaction_recovery_helpers() {
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] \
    || SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool \
      2>/dev/null || true)"
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] || return 1
  TRANSACTION_RECOVERY_SNAPSHOT_DIR="${UNINSTALL_LOCK_DIR}/transaction-recovery"
  [[ ! -e "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" \
      && ! -L "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" ]] || return 1
  mkdir -- "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" || return 1
  chmod 700 "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" || return 1
  TRANSACTION_RECOVERY_SNAPSHOT_DIR_ID="$(portable_node_identity \
    "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}")" || return 1
  TRANSACTION_RECOVERY_SEALS="${TRANSACTION_RECOVERY_SNAPSHOT_DIR}/seals.tsv"
  TRANSACTION_RECOVERY_SWITCHER="${TRANSACTION_RECOVERY_SNAPSHOT_DIR}/switch-tier.sh"
  TRANSACTION_RECOVERY_CONFIGURER="${TRANSACTION_RECOVERY_SNAPSHOT_DIR}/omc-config.sh"
  : > "${TRANSACTION_RECOVERY_SEALS}" || return 1
  chmod 600 "${TRANSACTION_RECOVERY_SEALS}" || return 1
  snapshot_transaction_recovery_helper \
    "${TRANSACTION_RECOVERY_SWITCHER_SOURCE}" \
    "${TRANSACTION_RECOVERY_SWITCHER}" || return 1
  snapshot_transaction_recovery_helper \
    "${TRANSACTION_RECOVERY_CONFIGURER_SOURCE}" \
    "${TRANSACTION_RECOVERY_CONFIGURER}" || return 1
  chmod 400 "${TRANSACTION_RECOVERY_SEALS}" || return 1
  TRANSACTION_RECOVERY_SEALS_ID="$(portable_node_identity \
    "${TRANSACTION_RECOVERY_SEALS}")" || return 1
  TRANSACTION_RECOVERY_SEALS_HASH="$(settings_sha256_file \
    "${TRANSACTION_RECOVERY_SEALS}")" || return 1
  TRANSACTION_RECOVERY_SEALS_MODE="$(portable_file_mode \
    "${TRANSACTION_RECOVERY_SEALS}")" || return 1
  transaction_recovery_helpers_are_current
}

settle_interrupted_configuration_transactions() {
  transaction_metadata_present || return 0
  uninstall_lock_generation_is_current || return 1
  prepare_transaction_recovery_helpers || return 1
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_TX_HELPERS_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_TX_HELPERS_RELEASE_FILE:-}" \
    "${TRANSACTION_RECOVERY_SNAPSHOT_DIR}" || return 1
  transaction_recovery_helpers_are_current || return 1
  uninstall_lock_generation_is_current || return 1

  if switch_transaction_metadata_present; then
    HOME="${TARGET_HOME}" BASH_ENV='' ENV='' \
      OMC_PARENT_OPERATION_LOCK_PID="$$" \
      OMC_PARENT_OPERATION_LOCK_TOKEN="${UNINSTALL_LOCK_TOKEN}" \
      OMC_PARENT_OPERATION_LOCK_ID="${UNINSTALL_LOCK_DIR_ID}" \
      bash "${TRANSACTION_RECOVERY_SWITCHER}" --recover-only || return 1
    uninstall_lock_generation_is_current || return 1
    transaction_recovery_helpers_are_current || return 1
    switch_transaction_metadata_present && return 1
  fi
  if omc_config_transaction_metadata_present; then
    HOME="${TARGET_HOME}" BASH_ENV='' ENV='' \
      OMC_PARENT_OPERATION_LOCK_PID="$$" \
      OMC_PARENT_OPERATION_LOCK_TOKEN="${UNINSTALL_LOCK_TOKEN}" \
      OMC_PARENT_OPERATION_LOCK_ID="${UNINSTALL_LOCK_DIR_ID}" \
      bash "${TRANSACTION_RECOVERY_CONFIGURER}" recover-only || return 1
    uninstall_lock_generation_is_current || return 1
    transaction_recovery_helpers_are_current || return 1
    omc_config_transaction_metadata_present && return 1
  fi
  ! transaction_metadata_present
}

render_uninstall_watchdog_cron_line() {
  local quoted_script=""
  printf -v quoted_script '%q' \
    "${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
  quoted_script="${quoted_script//%/\\%}"
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${quoted_script}"
}

watchdog_scheduler_present() {
  local configured="" configured_scheduler="" cron_contents=""
  local managed_cron_line=""
  local line="" value=""
  if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        resume_watchdog=*)
          value="${line#*=}"
          value="${value#"${value%%[![:space:]]*}"}"
          value="${value%"${value##*[![:space:]]}"}"
          case "${value}" in
            on|off) configured="${value}" ;;
          esac
          ;;
        resume_watchdog_scheduler=*)
          value="${line#*=}"
          value="${value#"${value%%[![:space:]]*}"}"
          value="${value%"${value##*[![:space:]]}"}"
          case "${value}" in
            launchd|systemd|cron) configured_scheduler="${value}" ;;
            off) configured_scheduler="" ;;
          esac
          ;;
      esac
    done < "${CLAUDE_HOME}/oh-my-claude.conf"
    [[ "${configured}" == "on" ]] && return 0
    [[ -n "${configured_scheduler}" ]] && return 0
  fi
  if [[ -e "${WATCHDOG_LAUNCHD_DEST}" || -L "${WATCHDOG_LAUNCHD_DEST}" \
      || -e "${WATCHDOG_SYSTEMD_SERVICE}" || -L "${WATCHDOG_SYSTEMD_SERVICE}" \
      || -e "${WATCHDOG_SYSTEMD_TIMER}" || -L "${WATCHDOG_SYSTEMD_TIMER}" ]]; then
    return 0
  fi
  if command -v launchctl >/dev/null 2>&1 \
      && launchctl print \
        "gui/$(id -u)/dev.ohmyclaude.resume-watchdog" \
        >/dev/null 2>&1; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 \
      && { systemctl --user is-enabled \
          oh-my-claude-resume-watchdog.timer >/dev/null 2>&1 \
        || systemctl --user is-active \
          oh-my-claude-resume-watchdog.timer >/dev/null 2>&1; }; then
    return 0
  fi
  if command -v crontab >/dev/null 2>&1; then
    cron_contents="$(crontab -l 2>/dev/null || true)"
    managed_cron_line="$(render_uninstall_watchdog_cron_line)"
    if printf '%s\n' "${cron_contents}" \
        | grep -Fqx -- '# oh-my-claude resume-watchdog' \
        || printf '%s\n' "${cron_contents}" \
          | grep -Fqx -- "${managed_cron_line}"; then
      return 0
    fi
  fi
  return 1
}

cleanup_watchdog_scheduler() {
  if [[ "${WATCHDOG_OUTER_ROLLBACK_PREPARED:-0}" -ne 1 ]]; then
    watchdog_scheduler_present || return 0
    printf 'Refusing to remove a scheduler generation that appeared after the enclosing rollback preflight. Rerun uninstall.sh.\n' >&2
    return 1
  fi

  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_SOURCE_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_SOURCE_RELEASE_FILE:-}" \
    "${WATCHDOG_HELPER_SNAPSHOT}" || return 1
  if ! watchdog_helper_source_is_current \
      || ! watchdog_helper_snapshot_is_current; then
    printf 'Refusing to uninstall: trusted watchdog cleanup helper is missing or unsafe: %s\n' \
      "${WATCHDOG_HELPER_SOURCE}" >&2
    return 1
  fi
  preflight_no_symlinked_path_components "${WATCHDOG_LAUNCHD_DEST}" || return 1
  preflight_no_symlinked_path_components "${WATCHDOG_SYSTEMD_SERVICE}" || return 1
  preflight_no_symlinked_path_components "${WATCHDOG_SYSTEMD_TIMER}" || return 1
  watchdog_outer_mark_cleanup_started || {
    printf 'Refusing to remove the harness because the durable enclosing scheduler rollback could not be armed.\n' >&2
    return 1
  }

  if ! (
    export HOME="${TARGET_HOME}"
    export TARGET_HOME
    export OMC_PARENT_OPERATION_LOCK_PID="$$"
    export OMC_PARENT_OPERATION_LOCK_TOKEN="${UNINSTALL_LOCK_TOKEN}"
    export OMC_PARENT_OPERATION_LOCK_ID="${UNINSTALL_LOCK_DIR_ID}"
    bash "${WATCHDOG_HELPER_SNAPSHOT}" --uninstall --reset-conf
  ); then
    printf 'Refusing to remove the harness because watchdog scheduler cleanup failed.\n' >&2
    printf 'The staged settings cleanup was not published; repair the scheduler command and rerun uninstall.sh.\n' >&2
    return 1
  fi
  uninstall_test_barrier \
    "${OMC_TEST_UNINSTALL_WATCHDOG_HELPER_RETURNED_READY_FILE:-}" \
    "${OMC_TEST_UNINSTALL_WATCHDOG_HELPER_RETURNED_RELEASE_FILE:-}" \
    "${WATCHDOG_OUTER_ROLLBACK_DIR:-${CLAUDE_HOME}}" || return 1
  if ! capture_watchdog_outer_post_state; then
    printf 'Refusing to remove the harness because the post-cleanup scheduler generation could not be sealed for enclosing rollback.\n' >&2
    return 1
  fi
  if ! watchdog_helper_source_is_current \
      || ! watchdog_helper_snapshot_is_current; then
    printf 'Refusing to remove the harness because watchdog cleanup authority changed during execution.\n' >&2
    return 1
  fi
  if ! refresh_managed_removal_path_seal \
      "${CLAUDE_HOME}/oh-my-claude.conf"; then
    printf 'Refusing to remove the harness because the watchdog cleanup conf generation could not be sealed.\n' >&2
    return 1
  fi
  removed+=("Removed resume-watchdog platform scheduler")
}

# ---------------------------------------------------------------------------
# Directories and files installed by oh-my-claude
# ---------------------------------------------------------------------------

# Skill directories (entire trees).
SKILL_DIRS=(
  "${CLAUDE_HOME}/skills/autowork"
  "${CLAUDE_HOME}/skills/ulw"
  "${CLAUDE_HOME}/skills/ultrawork"
  "${CLAUDE_HOME}/skills/sisyphus"
  "${CLAUDE_HOME}/skills/atlas"
  "${CLAUDE_HOME}/skills/council"
  "${CLAUDE_HOME}/skills/diverge"
  "${CLAUDE_HOME}/skills/librarian"
  "${CLAUDE_HOME}/skills/metis"
  "${CLAUDE_HOME}/skills/oracle"
  "${CLAUDE_HOME}/skills/plan-hard"
  "${CLAUDE_HOME}/skills/prometheus"
  "${CLAUDE_HOME}/skills/research-hard"
  "${CLAUDE_HOME}/skills/review-hard"
  "${CLAUDE_HOME}/skills/skills"
  "${CLAUDE_HOME}/skills/ulw-demo"
  "${CLAUDE_HOME}/skills/ulw-off"
  "${CLAUDE_HOME}/skills/ulw-report"
  "${CLAUDE_HOME}/skills/ulw-skip"
  "${CLAUDE_HOME}/skills/ulw-correct"
  "${CLAUDE_HOME}/skills/ulw-status"
  "${CLAUDE_HOME}/skills/ulw-time"
  "${CLAUDE_HOME}/skills/mark-deferred"
  "${CLAUDE_HOME}/skills/ulw-pause"
  "${CLAUDE_HOME}/skills/goal"
  "${CLAUDE_HOME}/skills/ulw-resume"
  "${CLAUDE_HOME}/skills/memory-audit"
  "${CLAUDE_HOME}/skills/test-audit"
  "${CLAUDE_HOME}/skills/frontend-design"
  "${CLAUDE_HOME}/skills/swiftui-pro"
  "${CLAUDE_HOME}/skills/gamedev"
  "${CLAUDE_HOME}/skills/omc-config"
  "${CLAUDE_HOME}/skills/whats-new"
  "${CLAUDE_HOME}/skills/omc-doctor"
  "${CLAUDE_HOME}/skills/data-analysis"
  "${CLAUDE_HOME}/skills/lit-review"
  "${CLAUDE_HOME}/skills/manuscript"
  "${CLAUDE_HOME}/skills/quality-constitution"
)

# Quality pack (scripts, memory, state, README).
QP_DIR="${CLAUDE_HOME}/quality-pack"

# Agent files installed by oh-my-claude.
AGENT_FILES=(
  "${CLAUDE_HOME}/agents/abstraction-critic.md"
  "${CLAUDE_HOME}/agents/atlas.md"
  "${CLAUDE_HOME}/agents/divergent-framer.md"
  "${CLAUDE_HOME}/agents/backend-api-developer.md"
  "${CLAUDE_HOME}/agents/briefing-analyst.md"
  "${CLAUDE_HOME}/agents/chief-of-staff.md"
  "${CLAUDE_HOME}/agents/data-lens.md"
  "${CLAUDE_HOME}/agents/design-lens.md"
  "${CLAUDE_HOME}/agents/devops-infrastructure-engineer.md"
  "${CLAUDE_HOME}/agents/draft-writer.md"
  "${CLAUDE_HOME}/agents/editor-critic.md"
  "${CLAUDE_HOME}/agents/excellence-reviewer.md"
  "${CLAUDE_HOME}/agents/frontend-developer.md"
  "${CLAUDE_HOME}/agents/fullstack-feature-builder.md"
  "${CLAUDE_HOME}/agents/growth-lens.md"
  "${CLAUDE_HOME}/agents/ios-core-engineer.md"
  "${CLAUDE_HOME}/agents/ios-deployment-specialist.md"
  "${CLAUDE_HOME}/agents/ios-ecosystem-integrator.md"
  "${CLAUDE_HOME}/agents/ios-ui-developer.md"
  "${CLAUDE_HOME}/agents/librarian.md"
  "${CLAUDE_HOME}/agents/metis.md"
  "${CLAUDE_HOME}/agents/oracle.md"
  "${CLAUDE_HOME}/agents/product-lens.md"
  "${CLAUDE_HOME}/agents/prometheus.md"
  "${CLAUDE_HOME}/agents/quality-planner.md"
  "${CLAUDE_HOME}/agents/quality-researcher.md"
  "${CLAUDE_HOME}/agents/quality-reviewer.md"
  "${CLAUDE_HOME}/agents/release-reviewer.md"
  "${CLAUDE_HOME}/agents/security-lens.md"
  "${CLAUDE_HOME}/agents/sre-lens.md"
  "${CLAUDE_HOME}/agents/test-automation-engineer.md"
  "${CLAUDE_HOME}/agents/visual-craft-lens.md"
  "${CLAUDE_HOME}/agents/writing-architect.md"
  "${CLAUDE_HOME}/agents/design-reviewer.md"
  "${CLAUDE_HOME}/agents/research-data-analyst.md"
  "${CLAUDE_HOME}/agents/literature-scout.md"
  "${CLAUDE_HOME}/agents/rigor-reviewer.md"
)

# Standalone files.
STANDALONE_FILES=(
  "${CLAUDE_HOME}/output-styles/oh-my-claude.md"
  "${CLAUDE_HOME}/output-styles/executive-brief.md"
  "${CLAUDE_HOME}/output-styles/opencode-compact.md"
  "${CLAUDE_HOME}/statusline.py"
  "${CLAUDE_HOME}/switch-tier.sh"
  "${CLAUDE_HOME}/omc-repro.sh"
  "${CLAUDE_HOME}/oh-my-claude.conf"
  "${CLAUDE_HOME}/oh-my-claude.conf.example"
  "${CLAUDE_HOME}/.install-stamp"
  "${CLAUDE_HOME}/install-resume-watchdog.sh"
  "${CLAUDE_HOME}/bin/omc"
)

# Wave 3 resume-watchdog scheduler templates. Removed wholesale during
# uninstall; the user-installed LaunchAgent / systemd unit / cron entry
# is removed via `install-resume-watchdog.sh --uninstall` separately
# (uninstall.sh prints a reminder before removing the bundle so a user
# with a live watchdog gets a clean shutdown path).
WATCHDOG_DIRS=(
  "${CLAUDE_HOME}/launchd"
  "${CLAUDE_HOME}/systemd"
)

OMC_SYMLINK="${TARGET_HOME}/.local/bin/omc"
MANAGED_GIT_HOOK_PATH=""
MANAGED_GIT_HOOK_TEMPLATE="${SCRIPT_DIR}/config/post-merge.hook"
LEGACY_GIT_HOOK_SHA256_V1="bdd46902aa5fe24d08a101cc9dbf0683e951109901faf33a657606c78b87d545"
MANAGED_GIT_HOOK_PARENT_ID=""
MANAGED_GIT_HOOK_NODE_ID=""
MANAGED_GIT_HOOK_HASH=""
MANAGED_GIT_HOOK_MODE=""
MANAGED_GIT_HOOK_PREFLIGHT_DONE=0

read_last_repo_path() {
  local conf_path="${1:-}" line="" value="" result=""
  [[ -f "${conf_path}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "repo_path="* ]] || continue
    value="${line#*=}"
    # Only edge whitespace is syntax. Interior spaces, apostrophes, and
    # backslashes are literal pathname bytes and must survive unchanged.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    result="${value}"
  done < "${conf_path}"
  printf '%s' "${result}"
}

read_last_valid_conf_sha256() {
  local conf_path="${1:-}" key="${2:-}" line="" value="" result=""
  [[ "${key}" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  [[ -f "${conf_path}" && ! -L "${conf_path}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ "${value}" =~ ^[0-9A-Fa-f]{64}$ ]] && result="${value}"
  done < "${conf_path}"
  printf '%s' "${result}"
}

preflight_managed_git_hook_path() {
  local conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  local repo_path="" hook_dir="" hook_path="" provenance_hash=""
  local current_hash="" current_mode="" parent="" legacy_owned=0

  if [[ "${MANAGED_GIT_HOOK_PREFLIGHT_DONE}" -eq 1 ]]; then
    [[ -n "${MANAGED_GIT_HOOK_PATH}" ]] || return 0
    parent="${MANAGED_GIT_HOOK_PATH%/*}"
    preflight_no_symlinked_path_components "${MANAGED_GIT_HOOK_PATH}" \
      || return 1
    [[ -f "${MANAGED_GIT_HOOK_PATH}" \
        && ! -L "${MANAGED_GIT_HOOK_PATH}" \
        && "$(portable_directory_identity "${parent}" \
          2>/dev/null || true)" == "${MANAGED_GIT_HOOK_PARENT_ID}" \
        && "$(portable_node_identity "${MANAGED_GIT_HOOK_PATH}" \
          2>/dev/null || true)" == "${MANAGED_GIT_HOOK_NODE_ID}" \
        && "$(settings_sha256_file "${MANAGED_GIT_HOOK_PATH}" \
          2>/dev/null || true)" == "${MANAGED_GIT_HOOK_HASH}" \
        && "$(portable_file_mode "${MANAGED_GIT_HOOK_PATH}" \
          2>/dev/null || true)" == "${MANAGED_GIT_HOOK_MODE}" ]]
    return $?
  fi
  MANAGED_GIT_HOOK_PREFLIGHT_DONE=1
  MANAGED_GIT_HOOK_PATH=""
  MANAGED_GIT_HOOK_PARENT_ID=""
  MANAGED_GIT_HOOK_NODE_ID=""
  MANAGED_GIT_HOOK_HASH=""
  MANAGED_GIT_HOOK_MODE=""
  [[ -f "${conf_path}" ]] || return 0
  repo_path="$(read_last_repo_path "${conf_path}")"
  [[ -n "${repo_path}" ]] || return 0
  hook_dir="$(git_hooks_dir_for_checkout "${repo_path}" 2>/dev/null || true)"
  [[ -n "${hook_dir}" ]] || return 0
  hook_path="${hook_dir}/post-merge"
  preflight_no_symlinked_path_components "${hook_path}" || return 1
  [[ -f "${hook_path}" && ! -L "${hook_path}" ]] || return 0
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] \
    || SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool \
      2>/dev/null || true)"
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] || return 1
  provenance_hash="$(read_last_valid_conf_sha256 "${conf_path}" \
    git_post_merge_hook_sha256)"
  current_hash="$(settings_sha256_file "${hook_path}")" || return 1
  current_mode="$(portable_file_mode "${hook_path}")" || return 1
  if [[ -z "${provenance_hash}" \
      && "${current_hash}" == "${LEGACY_GIT_HOOK_SHA256_V1}" \
      && "${current_mode}" =~ ^[0-7]{3,4}$ \
      && $((8#${current_mode} & 8#100)) -ne 0 ]]; then
    legacy_owned=1
  fi
  if { [[ "${legacy_owned}" -ne 1 ]] \
        && [[ "${current_mode}" != "700" ]]; } \
      || { [[ -n "${provenance_hash}" ]] \
        && [[ "${current_hash}" != "${provenance_hash}" ]]; } \
      || { [[ -z "${provenance_hash}" && "${legacy_owned}" -ne 1 ]] \
        && { [[ ! -f "${MANAGED_GIT_HOOK_TEMPLATE}" \
              || -L "${MANAGED_GIT_HOOK_TEMPLATE}" ]] \
          || ! cmp -s "${MANAGED_GIT_HOOK_TEMPLATE}" "${hook_path}"; }; }; then
    return 0
  fi
  parent="${hook_path%/*}"
  MANAGED_GIT_HOOK_PATH="${hook_path}"
  MANAGED_GIT_HOOK_PARENT_ID="$(portable_directory_identity "${parent}")" \
    || return 1
  MANAGED_GIT_HOOK_NODE_ID="$(portable_node_identity "${hook_path}")" \
    || return 1
  MANAGED_GIT_HOOK_HASH="${current_hash}"
  MANAGED_GIT_HOOK_MODE="${current_mode}"
}

capture_managed_removal_subtree() {
  local root="${1:-}" node="" state="" node_id="" digest=""
  local mode="" link_text=""
  local root_id="" root_device=""
  [[ "${root}" == /* && "${root}" != *[[:cntrl:]]* \
      && -d "${root}" && ! -L "${root}" \
      && -n "${MANAGED_REMOVAL_TREE_FILE}" ]] || return 1
  root_id="$(portable_node_identity "${root}")" || return 1
  [[ "${root_id}" == *:* ]] || return 1
  root_device="${root_id%%:*}"
  # A root marker distinguishes a deliberately sealed empty tree from parent
  # containers that are authorized only for a later non-recursive rmdir.
  printf '%s\t%s\troot\t-\t-\t-\t-\n' "${root}" "${root}" \
    >> "${MANAGED_REMOVAL_TREE_FILE}" || return 1
  MANAGED_REMOVAL_ENUM_FILE="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-tree-enumeration.XXXXXX")" \
    || return 1
  MANAGED_REMOVAL_ENUM_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_ENUM_FILE}")" || return 1
  chmod 600 "${MANAGED_REMOVAL_ENUM_FILE}" || return 1
  find -P "${root}" -mindepth 1 -print0 \
    > "${MANAGED_REMOVAL_ENUM_FILE}" || return 1
  [[ "$(portable_node_identity "${MANAGED_REMOVAL_ENUM_FILE}" \
      2>/dev/null || true)" == "${MANAGED_REMOVAL_ENUM_FILE_ID}" ]] \
    || return 1
  while IFS= read -r -d '' node; do
    [[ "${node}" == "${root}/"* \
        && "${node}" != *[[:cntrl:]]* ]] || return 1
    state=""
    node_id=""
    digest=""
    mode=""
    link_text=""
    if [[ -L "${node}" ]]; then
      state="symlink"
      node_id="$(portable_node_identity "${node}")" || return 1
      link_text="$(readlink "${node}")" || return 1
      [[ "${link_text}" != *[[:cntrl:]]* ]] || return 1
    elif [[ -f "${node}" ]]; then
      state="regular"
      node_id="$(portable_node_identity "${node}")" || return 1
      digest="$(settings_sha256_file "${node}")" || return 1
      mode="$(portable_file_mode "${node}")" || return 1
    elif [[ -d "${node}" ]]; then
      state="directory"
      node_id="$(portable_node_identity "${node}")" || return 1
      mode="$(portable_file_mode "${node}")" || return 1
    else
      # Bundle-owned trees contain only directories, regular files, and
      # symlinks. A device/socket/FIFO is foreign state and is never swept.
      return 1
    fi
    # A recursive remove follows mounted directories. Bundle ownership never
    # extends across a filesystem boundary nested below the managed root.
    [[ "${node_id}" == "${root_device}:"* ]] || return 1
    [[ -n "${digest}" ]] || digest="-"
    [[ -n "${mode}" ]] || mode="-"
    [[ -n "${link_text}" ]] || link_text="-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${root}" "${node}" "${state}" "${node_id}" "${digest}" \
      "${mode}" "${link_text}" >> "${MANAGED_REMOVAL_TREE_FILE}" \
      || return 1
  done < "${MANAGED_REMOVAL_ENUM_FILE}"
  [[ "$(portable_node_identity "${MANAGED_REMOVAL_ENUM_FILE}" \
      2>/dev/null || true)" == "${MANAGED_REMOVAL_ENUM_FILE_ID}" ]] \
    || return 1
  rm -f -- "${MANAGED_REMOVAL_ENUM_FILE}" || return 1
  MANAGED_REMOVAL_ENUM_FILE=""
  MANAGED_REMOVAL_ENUM_FILE_ID=""
}

capture_managed_removal_control_seals() {
  [[ -f "${MANAGED_REMOVAL_SEAL_FILE}" \
      && ! -L "${MANAGED_REMOVAL_SEAL_FILE}" \
      && -f "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
      && ! -L "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
      && -f "${MANAGED_REMOVAL_TREE_FILE}" \
      && ! -L "${MANAGED_REMOVAL_TREE_FILE}" ]] || return 1
  MANAGED_REMOVAL_SEAL_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_SEAL_FILE}")" || return 1
  MANAGED_REMOVAL_SEAL_FILE_HASH="$(settings_sha256_file \
    "${MANAGED_REMOVAL_SEAL_FILE}")" || return 1
  MANAGED_REMOVAL_ANCESTOR_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_ANCESTOR_FILE}")" || return 1
  MANAGED_REMOVAL_ANCESTOR_FILE_HASH="$(settings_sha256_file \
    "${MANAGED_REMOVAL_ANCESTOR_FILE}")" || return 1
  MANAGED_REMOVAL_TREE_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_TREE_FILE}")" || return 1
  MANAGED_REMOVAL_TREE_FILE_HASH="$(settings_sha256_file \
    "${MANAGED_REMOVAL_TREE_FILE}")" || return 1
}

managed_removal_control_seals_are_current() {
  uninstall_lock_generation_is_current \
    && [[ -f "${MANAGED_REMOVAL_SEAL_FILE}" \
      && ! -L "${MANAGED_REMOVAL_SEAL_FILE}" \
      && "$(portable_node_identity "${MANAGED_REMOVAL_SEAL_FILE}" \
        2>/dev/null || true)" == "${MANAGED_REMOVAL_SEAL_FILE_ID}" \
      && "$(settings_sha256_file "${MANAGED_REMOVAL_SEAL_FILE}" \
        2>/dev/null || true)" == "${MANAGED_REMOVAL_SEAL_FILE_HASH}" \
      && "$(portable_file_mode "${MANAGED_REMOVAL_SEAL_FILE}" \
        2>/dev/null || true)" == "400" \
      && -f "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
      && ! -L "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
      && "$(portable_node_identity "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
        2>/dev/null || true)" == "${MANAGED_REMOVAL_ANCESTOR_FILE_ID}" \
      && "$(settings_sha256_file "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
        2>/dev/null || true)" == "${MANAGED_REMOVAL_ANCESTOR_FILE_HASH}" \
      && "$(portable_file_mode "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
        2>/dev/null || true)" == "400" \
      && -f "${MANAGED_REMOVAL_TREE_FILE}" \
      && ! -L "${MANAGED_REMOVAL_TREE_FILE}" \
      && "$(portable_node_identity "${MANAGED_REMOVAL_TREE_FILE}" \
        2>/dev/null || true)" == "${MANAGED_REMOVAL_TREE_FILE_ID}" \
      && "$(settings_sha256_file "${MANAGED_REMOVAL_TREE_FILE}" \
        2>/dev/null || true)" == "${MANAGED_REMOVAL_TREE_FILE_HASH}" \
      && "$(portable_file_mode "${MANAGED_REMOVAL_TREE_FILE}" \
        2>/dev/null || true)" == "400" ]]
}

managed_removal_subtree_seal_is_current() {
  local wanted="${1:-}" row_root="" node="" state="" node_id=""
  local digest="" mode="" link_text="" sealed_count=0 current_count=0
  local root_markers=0
  [[ -d "${wanted}" && ! -L "${wanted}" ]] || return 1
  while IFS=$'\t' read -r row_root node state node_id digest mode \
      link_text; do
    [[ "${row_root}" == "${wanted}" ]] || continue
    case "${state}" in
      root)
        [[ "${node}" == "${wanted}" \
            && "${node_id}" == "-" && "${digest}" == "-" \
            && "${mode}" == "-" && "${link_text}" == "-" ]] \
          || return 1
        root_markers=$((root_markers + 1))
        continue
        ;;
      regular)
        [[ "${node}" == "${wanted}/"* \
            && "${node}" != *[[:cntrl:]]* ]] || return 1
        sealed_count=$((sealed_count + 1))
        [[ -f "${node}" && ! -L "${node}" \
            && "$(portable_node_identity "${node}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(settings_sha256_file "${node}" \
              2>/dev/null || true)" == "${digest}" \
            && "$(portable_file_mode "${node}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        ;;
      directory)
        [[ "${node}" == "${wanted}/"* \
            && "${node}" != *[[:cntrl:]]* ]] || return 1
        sealed_count=$((sealed_count + 1))
        [[ -d "${node}" && ! -L "${node}" \
            && "$(portable_node_identity "${node}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(portable_file_mode "${node}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        ;;
      symlink)
        [[ "${node}" == "${wanted}/"* \
            && "${node}" != *[[:cntrl:]]* ]] || return 1
        sealed_count=$((sealed_count + 1))
        [[ -L "${node}" \
            && "$(portable_node_identity "${node}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(readlink "${node}" 2>/dev/null || true)" \
              == "${link_text}" ]] || return 1
        ;;
      *) return 1 ;;
    esac
  done < "${MANAGED_REMOVAL_TREE_FILE}"
  [[ "${root_markers}" -eq 1 ]] || return 1
  MANAGED_REMOVAL_ENUM_FILE="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-tree-enumeration.XXXXXX")" \
    || return 1
  MANAGED_REMOVAL_ENUM_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_ENUM_FILE}")" || return 1
  chmod 600 "${MANAGED_REMOVAL_ENUM_FILE}" || return 1
  find -P "${wanted}" -mindepth 1 -print0 \
    > "${MANAGED_REMOVAL_ENUM_FILE}" || return 1
  [[ "$(portable_node_identity "${MANAGED_REMOVAL_ENUM_FILE}" \
      2>/dev/null || true)" == "${MANAGED_REMOVAL_ENUM_FILE_ID}" ]] \
    || return 1
  while IFS= read -r -d '' node; do
    [[ "${node}" == "${wanted}/"* \
        && "${node}" != *[[:cntrl:]]* ]] || return 1
    current_count=$((current_count + 1))
  done < "${MANAGED_REMOVAL_ENUM_FILE}"
  [[ "$(portable_node_identity "${MANAGED_REMOVAL_ENUM_FILE}" \
      2>/dev/null || true)" == "${MANAGED_REMOVAL_ENUM_FILE_ID}" ]] \
    || return 1
  rm -f -- "${MANAGED_REMOVAL_ENUM_FILE}" || return 1
  MANAGED_REMOVAL_ENUM_FILE=""
  MANAGED_REMOVAL_ENUM_FILE_ID=""
  [[ "${current_count}" -eq "${sealed_count}" ]]
}

capture_managed_removal_path_seal() {
  local path="${1:-}" allow_leaf_symlink="${2:-0}"
  local capture_subtree="${3:-0}" parent="" relative=""
  local current="/" segment="" ancestor_id="" state="" node_id=""
  local digest="" mode="" link_text=""
  local -a segments=()
  [[ "${path}" == /* && "${path}" != *[[:cntrl:]]* ]] || return 1
  preflight_no_symlinked_path_components "${path}" \
    "${allow_leaf_symlink}" || return 1
  parent="${path%/*}"
  [[ -n "${parent}" ]] || parent="/"
  relative="${parent#/}"
  ancestor_id="$(portable_directory_identity /)" || return 1
  printf '%s\t%s\t/\n' "${path}" "${ancestor_id}" \
    >> "${MANAGED_REMOVAL_ANCESTOR_FILE}" || return 1
  if [[ -n "${relative}" ]]; then
    IFS='/' read -r -a segments <<< "${relative}"
    for segment in "${segments[@]}"; do
      [[ -n "${segment}" && "${segment}" != "." \
          && "${segment}" != ".." ]] || return 1
      current="${current%/}/${segment}"
      if [[ ! -e "${current}" && ! -L "${current}" ]]; then
        break
      fi
      [[ -d "${current}" && ! -L "${current}" ]] || return 1
      ancestor_id="$(portable_directory_identity "${current}")" \
        || return 1
      printf '%s\t%s\t%s\n' "${path}" "${ancestor_id}" "${current}" \
        >> "${MANAGED_REMOVAL_ANCESTOR_FILE}" || return 1
    done
  fi
  if [[ -L "${path}" ]]; then
    [[ "${allow_leaf_symlink}" -eq 1 ]] || return 1
    state="symlink"
    node_id="$(portable_node_identity "${path}")" || return 1
    link_text="$(readlink "${path}")" || return 1
  elif [[ -f "${path}" ]]; then
    state="regular"
    node_id="$(portable_node_identity "${path}")" || return 1
    digest="$(settings_sha256_file "${path}")" || return 1
    mode="$(portable_file_mode "${path}")" || return 1
  elif [[ -d "${path}" ]]; then
    state="directory"
    node_id="$(portable_node_identity "${path}")" || return 1
    mode="$(portable_file_mode "${path}")" || return 1
    if [[ "${capture_subtree}" -eq 1 ]]; then
      capture_managed_removal_subtree "${path}" || return 1
    fi
  elif [[ ! -e "${path}" ]]; then
    state="absent"
  else
    state="other"
    node_id="$(portable_node_identity "${path}")" || return 1
    mode="$(portable_file_mode "${path}")" || return 1
  fi
  [[ -n "${node_id}" ]] || node_id="-"
  [[ -n "${digest}" ]] || digest="-"
  [[ -n "${mode}" ]] || mode="-"
  [[ -n "${link_text}" ]] || link_text="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${path}" "${state}" "${node_id}" "${digest}" "${mode}" \
    "${link_text}" >> "${MANAGED_REMOVAL_SEAL_FILE}" || return 1
}

managed_removal_path_seal_is_current() {
  local wanted="${1:-}" skip_control="${2:-0}"
  local row_path="" expected_id="" ancestor=""
  local state="" node_id="" digest="" mode="" link_text="" rows=0
  local tree_root="" tree_node="" tree_state="" tree_rest=""
  local subtree_markers=0
  [[ "${MANAGED_REMOVAL_SEALS_CAPTURED}" -eq 1 \
      && -f "${MANAGED_REMOVAL_SEAL_FILE}" \
      && ! -L "${MANAGED_REMOVAL_SEAL_FILE}" \
      && -f "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
      && ! -L "${MANAGED_REMOVAL_ANCESTOR_FILE}" ]] || return 1
  if [[ "${skip_control}" -ne 1 ]]; then
    managed_removal_control_seals_are_current || return 1
  fi
  while IFS=$'\t' read -r row_path expected_id ancestor; do
    [[ "${row_path}" == "${wanted}" ]] || continue
    rows=$((rows + 1))
    [[ -d "${ancestor}" && ! -L "${ancestor}" \
        && "$(portable_directory_identity "${ancestor}" \
          2>/dev/null || true)" == "${expected_id}" ]] || return 1
  done < "${MANAGED_REMOVAL_ANCESTOR_FILE}"
  [[ "${rows}" -gt 0 ]] || return 1
  rows=0
  while IFS=$'\t' read -r row_path state node_id digest mode link_text; do
    [[ "${row_path}" == "${wanted}" ]] || continue
    rows=$((rows + 1))
    case "${state}" in
      absent)
        [[ ! -e "${wanted}" && ! -L "${wanted}" ]] || return 1
        ;;
      regular)
        [[ -f "${wanted}" && ! -L "${wanted}" \
            && "$(portable_node_identity "${wanted}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(settings_sha256_file "${wanted}" \
              2>/dev/null || true)" == "${digest}" \
            && "$(portable_file_mode "${wanted}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        ;;
      directory)
        [[ -d "${wanted}" && ! -L "${wanted}" \
            && "$(portable_node_identity "${wanted}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(portable_file_mode "${wanted}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        subtree_markers=0
        while IFS=$'\t' read -r tree_root tree_node tree_state \
            tree_rest; do
          [[ "${tree_root}" == "${wanted}" \
              && "${tree_state}" == "root" ]] \
            && subtree_markers=$((subtree_markers + 1))
        done < "${MANAGED_REMOVAL_TREE_FILE}"
        [[ "${subtree_markers}" -le 1 ]] || return 1
        if [[ "${subtree_markers}" -eq 1 ]]; then
          managed_removal_subtree_seal_is_current "${wanted}" || return 1
        fi
        ;;
      symlink)
        [[ -L "${wanted}" \
            && "$(portable_node_identity "${wanted}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(readlink "${wanted}" 2>/dev/null || true)" \
              == "${link_text}" ]] || return 1
        ;;
      other)
        [[ -e "${wanted}" && ! -L "${wanted}" \
            && ! -f "${wanted}" && ! -d "${wanted}" \
            && "$(portable_node_identity "${wanted}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(portable_file_mode "${wanted}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        ;;
      *) return 1 ;;
    esac
  done < "${MANAGED_REMOVAL_SEAL_FILE}"
  [[ "${rows}" -eq 1 ]]
}

capture_all_managed_removal_seals() {
  local path=""
  [[ "${UNINSTALL_LOCK_HELD}" -eq 1 \
      && -d "${UNINSTALL_LOCK_DIR}" \
      && ! -L "${UNINSTALL_LOCK_DIR}" ]] || return 1
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] \
    || SETTINGS_SHA256_TOOL="$(resolve_settings_sha256_tool \
      2>/dev/null || true)"
  [[ -n "${SETTINGS_SHA256_TOOL}" ]] || return 1
  MANAGED_REMOVAL_SEAL_FILE="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-seals.XXXXXX")" || return 1
  MANAGED_REMOVAL_SEAL_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_SEAL_FILE}")" || return 1
  MANAGED_REMOVAL_ANCESTOR_FILE="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-ancestors.XXXXXX")" || return 1
  MANAGED_REMOVAL_ANCESTOR_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_ANCESTOR_FILE}")" || return 1
  MANAGED_REMOVAL_TREE_FILE="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-trees.XXXXXX")" || return 1
  MANAGED_REMOVAL_TREE_FILE_ID="$(portable_node_identity \
    "${MANAGED_REMOVAL_TREE_FILE}")" || return 1
  chmod 600 "${MANAGED_REMOVAL_SEAL_FILE}" \
    "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
    "${MANAGED_REMOVAL_TREE_FILE}" || return 1
  for path in "${SKILL_DIRS[@]}" "${WATCHDOG_DIRS[@]}" "${QP_DIR}"; do
    capture_managed_removal_path_seal "${path}" 0 1 || return 1
  done
  for path in "${AGENT_FILES[@]}" "${STANDALONE_FILES[@]}" \
      "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/output-styles" \
      "${CLAUDE_HOME}/skills" "${CLAUDE_HOME}/bin"; do
    capture_managed_removal_path_seal "${path}" || return 1
  done
  capture_managed_removal_path_seal "${OMC_SYMLINK}" 1 || return 1
  if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]]; then
    capture_managed_removal_path_seal \
      "${QUALITY_CONSTITUTIONS_DIR}" 0 1 || return 1
  fi
  chmod 400 "${MANAGED_REMOVAL_SEAL_FILE}" \
    "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
    "${MANAGED_REMOVAL_TREE_FILE}" || return 1
  capture_managed_removal_control_seals || return 1
  MANAGED_REMOVAL_SEALS_CAPTURED=1
}

verify_all_managed_removal_seals() {
  local path=""
  managed_removal_control_seals_are_current || return 1
  for path in "${SKILL_DIRS[@]}" "${WATCHDOG_DIRS[@]}" "${QP_DIR}" \
      "${AGENT_FILES[@]}" "${STANDALONE_FILES[@]}" \
      "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/output-styles" \
      "${CLAUDE_HOME}/skills" "${CLAUDE_HOME}/bin"; do
    managed_removal_path_seal_is_current "${path}" 1 || return 1
  done
  managed_removal_path_seal_is_current "${OMC_SYMLINK}" 1 || return 1
  if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]]; then
    managed_removal_path_seal_is_current \
      "${QUALITY_CONSTITUTIONS_DIR}" 1 || return 1
  fi
}

refresh_managed_removal_path_seal() {
  local wanted="${1:-}" seal_tmp="" ancestor_tmp="" path=""
  local line="" row_path=""
  [[ "${MANAGED_REMOVAL_SEALS_CAPTURED}" -eq 1 \
      && "${wanted}" == /* && "${wanted}" != *[[:cntrl:]]* ]] || return 1
  managed_removal_control_seals_are_current || return 1
  # Every sibling generation must remain exact. Only the trusted scheduler
  # helper may advance the conf leaf it transactionally edited.
  for path in "${SKILL_DIRS[@]}" "${WATCHDOG_DIRS[@]}" "${QP_DIR}" \
      "${AGENT_FILES[@]}" "${STANDALONE_FILES[@]}" \
      "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/output-styles" \
      "${CLAUDE_HOME}/skills" "${CLAUDE_HOME}/bin" "${OMC_SYMLINK}"; do
    [[ "${path}" == "${wanted}" ]] && continue
    managed_removal_path_seal_is_current "${path}" 1 || return 1
  done
  seal_tmp="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-seals-refresh.XXXXXX")" || return 1
  MANAGED_REMOVAL_REFRESH_SEAL_FILE="${seal_tmp}"
  MANAGED_REMOVAL_REFRESH_SEAL_FILE_ID="$(portable_node_identity \
    "${seal_tmp}")" || return 1
  ancestor_tmp="$(mktemp \
    "${UNINSTALL_LOCK_DIR}/removal-ancestors-refresh.XXXXXX")" \
    || return 1
  MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE="${ancestor_tmp}"
  MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE_ID="$(portable_node_identity \
    "${ancestor_tmp}")" || return 1
  : > "${seal_tmp}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    row_path="${line%%$'\t'*}"
    [[ "${row_path}" == "${wanted}" ]] \
      || printf '%s\n' "${line}" >> "${seal_tmp}" || return 1
  done < "${MANAGED_REMOVAL_SEAL_FILE}"
  : > "${ancestor_tmp}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    row_path="${line%%$'\t'*}"
    [[ "${row_path}" == "${wanted}" ]] \
      || printf '%s\n' "${line}" >> "${ancestor_tmp}" || return 1
  done < "${MANAGED_REMOVAL_ANCESTOR_FILE}"
  chmod 600 "${seal_tmp}" "${ancestor_tmp}" || return 1
  mv -f -- "${seal_tmp}" "${MANAGED_REMOVAL_SEAL_FILE}" || return 1
  MANAGED_REMOVAL_REFRESH_SEAL_FILE=""
  MANAGED_REMOVAL_REFRESH_SEAL_FILE_ID=""
  mv -f -- "${ancestor_tmp}" "${MANAGED_REMOVAL_ANCESTOR_FILE}" \
    || return 1
  MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE=""
  MANAGED_REMOVAL_REFRESH_ANCESTOR_FILE_ID=""
  capture_managed_removal_path_seal "${wanted}" || return 1
  chmod 400 "${MANAGED_REMOVAL_SEAL_FILE}" \
    "${MANAGED_REMOVAL_ANCESTOR_FILE}" || return 1
  capture_managed_removal_control_seals || return 1
  managed_removal_path_seal_is_current "${wanted}"
}

authorize_managed_removal() {
  local path="${1:-}"
  managed_removal_path_seal_is_current "${path}" || return 1
  if [[ -n "${OMC_TEST_UNINSTALL_REMOVE_MATCH:-}" \
      && "${path}" == "${OMC_TEST_UNINSTALL_REMOVE_MATCH}" ]]; then
    uninstall_test_barrier \
      "${OMC_TEST_UNINSTALL_REMOVE_READY_FILE:-}" \
      "${OMC_TEST_UNINSTALL_REMOVE_RELEASE_FILE:-}" \
      "${path}" || return 1
  fi
  managed_removal_path_seal_is_current "${path}"
}

preflight_managed_removal_paths() {
  local path=""
  for path in "${SKILL_DIRS[@]}" "${WATCHDOG_DIRS[@]}" "${QP_DIR}" \
      "${AGENT_FILES[@]}" "${STANDALONE_FILES[@]}" \
      "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/output-styles" \
      "${CLAUDE_HOME}/skills" "${CLAUDE_HOME}/bin"; do
    preflight_no_symlinked_path_components "${path}" || return 1
  done
  # The omc leaf is intentionally a symlink. Its ancestors must still be real
  # directories so removing that leaf cannot be redirected into another tree.
  preflight_no_symlinked_path_components "${OMC_SYMLINK}" 1 || return 1
  preflight_managed_git_hook_path || return 1
  if [[ "${MANAGED_REMOVAL_SEALS_CAPTURED}" -eq 1 ]]; then
    verify_all_managed_removal_seals || return 1
  fi
}

acquire_uninstall_lock

if ! settle_interrupted_configuration_transactions; then
  printf 'No managed files were removed because an interrupted model/config transaction could not be settled safely.\n' >&2
  exit 1
fi
uninstall_test_barrier \
  "${OMC_TEST_UNINSTALL_TX_SETTLED_READY_FILE:-}" \
  "${OMC_TEST_UNINSTALL_TX_SETTLED_RELEASE_FILE:-}" \
  "${CLAUDE_HOME}" || exit 1
if ! preflight_settings_cleanup_inputs; then
  printf 'No managed files were removed. Repair the inputs above and rerun uninstall.sh.\n' >&2
  exit 1
fi
if ! preflight_managed_removal_paths; then
  printf 'No managed files were removed. Repair the unsafe path above and rerun uninstall.sh.\n' >&2
  exit 1
fi
if ! capture_all_managed_removal_seals \
    || ! verify_all_managed_removal_seals; then
  printf 'No managed files were removed because exact removal generations could not be sealed.\n' >&2
  exit 1
fi
uninstall_test_barrier \
  "${OMC_TEST_UNINSTALL_REMOVAL_SEALS_READY_FILE:-}" \
  "${OMC_TEST_UNINSTALL_REMOVAL_SEALS_RELEASE_FILE:-}" \
  "${MANAGED_REMOVAL_SEAL_FILE}" || exit 1
if ! preflight_managed_removal_paths; then
  printf 'No managed files were removed because a sealed removal generation changed.\n' >&2
  exit 1
fi
if watchdog_scheduler_present \
    && ! prepare_watchdog_helper_snapshot; then
  printf 'No managed files were removed because the watchdog cleanup helper could not be sealed privately.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect whether oh-my-claude is installed
# ---------------------------------------------------------------------------

omc_installed=false
SETTINGS_MANAGED_RESIDUE=false

if [[ -d "${QP_DIR}" ]]; then
  omc_installed=true
fi
for dir in "${SKILL_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    omc_installed=true
    break
  fi
done
for f in "${STANDALONE_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    omc_installed=true
    break
  fi
done
for wdir in "${WATCHDOG_DIRS[@]}"; do
  if [[ -d "${wdir}" ]]; then
    omc_installed=true
    break
  fi
done
for f in "${AGENT_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    omc_installed=true
    break
  fi
done
if [[ -L "${OMC_SYMLINK}" ]] \
    && [[ "$(readlink "${OMC_SYMLINK}" 2>/dev/null || true)" \
      == "${CLAUDE_HOME}/bin/omc" ]]; then
  omc_installed=true
fi
  if [[ -n "${MANAGED_GIT_HOOK_PATH}" ]]; then
  omc_installed=true
fi
if watchdog_scheduler_present; then
  omc_installed=true
fi
if settings_contains_managed_residue; then
  SETTINGS_MANAGED_RESIDUE=true
  omc_installed=true
fi
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]] \
    && [[ -d "${QUALITY_CONSTITUTIONS_DIR}" ]]; then
  # Explicit purge remains usable after the managed harness was already
  # removed. User-owned Constitution data deliberately outlives an ordinary
  # uninstall, so a later purge-only invocation is a valid operation.
  omc_installed=true
fi

if [[ "${omc_installed}" != "true" ]]; then
  printf 'oh-my-claude does not appear to be installed under %s.\n' "${CLAUDE_HOME}"
  printf 'Nothing to do.\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Preview what will be removed
# ---------------------------------------------------------------------------

printf 'oh-my-claude uninstaller\n'
printf '=======================\n\n'
printf 'The following will be removed from %s:\n\n' "${CLAUDE_HOME}"

# Collect items for preview.
items_to_remove=()

for dir in "${SKILL_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    items_to_remove+=("  [dir]  ${dir}")
  fi
done

if [[ -d "${QP_DIR}" ]]; then
  items_to_remove+=("  [dir]  ${QP_DIR}")
fi

for wdir in "${WATCHDOG_DIRS[@]}"; do
  if [[ -d "${wdir}" ]]; then
    items_to_remove+=("  [dir]  ${wdir}")
  fi
done

for f in "${AGENT_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    items_to_remove+=("  [file] ${f}")
  fi
done

for f in "${STANDALONE_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    items_to_remove+=("  [file] ${f}")
  fi
done

if [[ "${SETTINGS_MANAGED_RESIDUE}" == "true" ]]; then
  items_to_remove+=("  [edit] ${SETTINGS} (remove oh-my-claude hooks and settings)")
fi
if [[ -L "${OMC_SYMLINK}" ]] \
    && [[ "$(readlink "${OMC_SYMLINK}" 2>/dev/null || true)" \
      == "${CLAUDE_HOME}/bin/omc" ]]; then
  items_to_remove+=("  [link] ${OMC_SYMLINK}")
fi
if [[ -n "${MANAGED_GIT_HOOK_PATH}" ]]; then
  items_to_remove+=("  [file] ${MANAGED_GIT_HOOK_PATH} (managed post-merge hook)")
fi
if watchdog_scheduler_present; then
  items_to_remove+=("  [sched] resume-watchdog platform scheduler")
fi

if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]] \
    && { [[ -e "${CLAUDE_HOME}/omc-user/quality-constitutions" ]] \
      || [[ -L "${CLAUDE_HOME}/omc-user/quality-constitutions" ]]; }; then
  # Besides making the destructive opt-in visible, this keeps a purge-only
  # run non-empty on Bash 3.2 with `set -u` (expanding an empty declared array
  # is treated as an unbound variable by that shell).
  items_to_remove+=("  [dir]  ${QUALITY_CONSTITUTIONS_DIR} (explicit user purge)")
fi

for item in "${items_to_remove[@]}"; do
  printf '%s\n' "${item}"
done

printf '\nThe following will NOT be removed:\n'
printf '  - CLAUDE.md (may contain user content)\n'
printf '  - omc-user/ (user customizations)\n'
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]]; then
  printf '    EXCEPT quality-constitutions/ (explicit purge requested)\n'
else
  printf '    including quality constitutions, exemplars, and learned taste candidates\n'
fi
printf '  - Backup directories under %s/backups/\n' "${CLAUDE_HOME}"
printf '  - Other hooks or settings not installed by oh-my-claude\n'
printf '\n'

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

if [[ "${AUTO_CONFIRM}" != "true" ]]; then
  printf 'Proceed with uninstall? [y/N] '
  read -r confirm
  case "${confirm}" in
    [yY]|[yY][eE][sS])
      ;;
    *)
      printf 'Aborted.\n'
      exit 0
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Capture cleanup authority before any mutation
# ---------------------------------------------------------------------------

removed=()

# Capture each bundled output-style file's frontmatter `name:` BEFORE we
# remove the files, so the settings cleanup (below) can value-gate against
# the user's actual current name (which may have been customized in place
# per docs/customization.md guidance) rather than a hardcoded literal.
# Without this, a user who edited a bundled file's frontmatter to
# something like "oh-my-claude v2" and updated their settings to
# match would have the file removed but the orphaned outputStyle entry
# left pointing at a missing style. Falls back to the historical default
# names when a file is absent or the parse returns empty. Both bundled
# names are captured separately so cleanup recognizes either; the legacy
# "OpenCode Compact" name is also accepted for pre-v1.26.0 installs.
OMC_BUNDLED_STYLE_NAME="oh-my-claude"
OMC_BUNDLED_STYLE_NAME_EXECUTIVE="executive-brief"
_parse_style_name() {
  # Robust parser: strips trailing \r (CRLF defense — without it, a
  # Windows-edited customized file would re-introduce the exact orphan
  # leak F-010 was meant to fix), tolerates multi-space-after-colon, and
  # preserves embedded colons in the name itself.
  awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "$1" 2>/dev/null || true
}
_bundled_style_path="${CLAUDE_HOME}/output-styles/oh-my-claude.md"
if [[ -f "${_bundled_style_path}" ]]; then
  _parsed_style_name="$(_parse_style_name "${_bundled_style_path}")"
  if [[ -n "${_parsed_style_name}" ]]; then
    OMC_BUNDLED_STYLE_NAME="${_parsed_style_name}"
  fi
fi
_bundled_style_path_exec="${CLAUDE_HOME}/output-styles/executive-brief.md"
if [[ -f "${_bundled_style_path_exec}" ]]; then
  _parsed_style_name_exec="$(_parse_style_name "${_bundled_style_path_exec}")"
  if [[ -n "${_parsed_style_name_exec}" ]]; then
    OMC_BUNDLED_STYLE_NAME_EXECUTIVE="${_parsed_style_name_exec}"
  fi
fi
export OMC_BUNDLED_STYLE_NAME
export OMC_BUNDLED_STYLE_NAME_EXECUTIVE

# ---------------------------------------------------------------------------
# Clean settings.json — remove oh-my-claude hooks and keys
# ---------------------------------------------------------------------------

clean_settings_python() {
  python3 - "${SETTINGS}" "${SETTINGS_PATCH_SNAPSHOT}" <<'PY'
import json
import os
import pathlib
import re
import sys

settings_path = pathlib.Path(sys.argv[1])
patch_path = pathlib.Path(sys.argv[2])

with settings_path.open() as f:
    settings = json.load(f)
with patch_path.open() as f:
    patch = json.load(f)

# Bundled style names captured by the parent shell before the .md files
# were removed. Falls back to historical defaults if the parent did not
# export them (e.g. when this function is invoked outside the normal
# uninstall flow). Also accepts the legacy "OpenCode Compact" name.
omc_style_name = os.environ.get("OMC_BUNDLED_STYLE_NAME", "oh-my-claude")
omc_style_name_executive = os.environ.get("OMC_BUNDLED_STYLE_NAME_EXECUTIVE", "executive-brief")

# ---- Remove exact managed hook objects, preserving mixed foreign hooks ----
path_pattern = re.compile(
    r'(?:\$HOME|\$\{HOME\}|~)/\.claude/'
    r'((?:skills/autowork|quality-pack)/scripts/[A-Za-z0-9_-]+\.(?:sh|py))'
)

def patch_relative(command):
    match = path_pattern.search(command or "")
    return match.group(1) if match else ""

# Ownership is the complete event + entry envelope + exact hook object. A
# command string under the wrong event/matcher, an entry with extra modifiers,
# or a hook object with extra fields is foreign and must survive uninstall.
expected_by_event = {}
for event, entries in (patch.get("hooks") or {}).items():
    expected_by_event[event] = [
        ({key: value for key, value in entry.items() if key != "hooks"},
         [hook for hook in (entry.get("hooks") or []) if isinstance(hook, dict)])
        for entry in entries or [] if isinstance(entry, dict)
    ]

# Versioned historical ownership is equally tuple-scoped. These two commands
# were emitted only as universal SessionStart hooks.
expected_by_event.setdefault("SessionStart", []).append(({}, [
    {"type": "command", "command": "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-resume.sh"},
    {"type": "command", "command": "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh"},
]))

def managed_hooks_for(event, entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
        return []
    contract = {key: value for key, value in entry.items() if key != "hooks"}
    result = []
    for expected_contract, hooks in expected_by_event.get(event, []):
        if contract == expected_contract:
            result.extend(hooks)
    return result

settings_hooks = settings.get("hooks") or {}
if isinstance(settings_hooks, dict) and settings_hooks:
    for event in list(settings_hooks.keys()):
        entries = settings_hooks.get(event) or []
        cleaned_entries = []
        event_changed = False
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                cleaned_entries.append(entry)
                continue
            original_hooks = entry["hooks"]
            managed_hooks = managed_hooks_for(event, entry)
            kept_hooks = [hook for hook in original_hooks if hook not in managed_hooks]
            if len(kept_hooks) == len(original_hooks):
                cleaned_entries.append(entry)
                continue
            event_changed = True
            if kept_hooks:
                updated = dict(entry)
                updated["hooks"] = kept_hooks
                cleaned_entries.append(updated)
        if event_changed:
            if cleaned_entries:
                settings_hooks[event] = cleaned_entries
            else:
                del settings_hooks[event]
    # Remove hooks key if empty.
    if not settings_hooks:
        settings.pop("hooks", None)
    else:
        settings["hooks"] = settings_hooks
elif "hooks" in settings:
    # hooks was present but null/empty — drop the key for parity with
    # jq's `if (.hooks | length) == 0 then del(.hooks) else . end`.
    settings.pop("hooks", None)

# ---- Remove oh-my-claude settings keys (only if they match our values) ----

# outputStyle — only remove if set to one of the bundled styles'
# frontmatter names (captured before removal so in-place customizations
# are matched). Both the compact `oh-my-claude` style and the
# `executive-brief` CEO-report style are recognized, plus the legacy
# "OpenCode Compact" name from pre-v1.26.0 installs. A custom user style
# that does NOT match any bundled name is preserved (orphaned but at
# least the user's choice is not silently overwritten).
if settings.get("outputStyle") in (omc_style_name, omc_style_name_executive, "OpenCode Compact"):
    del settings["outputStyle"]

# effortLevel — only remove if it still equals the patch-owned value.
if settings.get("effortLevel") == patch.get("effortLevel"):
    del settings["effortLevel"]

# spinnerTipsEnabled — only remove if it still equals the patch-owned value.
if settings.get("spinnerTipsEnabled") == patch.get("spinnerTipsEnabled"):
    del settings["spinnerTipsEnabled"]

# spinnerVerbs — exact object equality preserves duplicates/order and keeps the
# Python and jq ownership decisions identical for every JSON value.
if settings.get("spinnerVerbs") == patch.get("spinnerVerbs"):
    del settings["spinnerVerbs"]

# --bypass-permissions writes these two values. Once the harness and its gates
# are gone, leaving the global bypass behind is unsafe. Remove only the exact
# values OMC writes; preserve foreign modes and every sibling permission key.
permissions = settings.get("permissions")
if isinstance(permissions, dict) and permissions.get("defaultMode") == "bypassPermissions":
    permissions = dict(permissions)
    del permissions["defaultMode"]
    if permissions:
        settings["permissions"] = permissions
    else:
        settings.pop("permissions", None)
if settings.get("skipDangerousModePermissionPrompt") is True:
    del settings["skipDangerousModePermissionPrompt"]

# statusLine — remove only the complete object owned by the patch. A foreign
# command that merely shares the basename is user state and must survive.
if settings.get("statusLine") == patch.get("statusLine"):
    del settings["statusLine"]

with settings_path.open("w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
}

clean_settings_jq() {
  local temp_path=""
  local omc_style_name="${OMC_BUNDLED_STYLE_NAME:-oh-my-claude}"
  local omc_style_name_executive="${OMC_BUNDLED_STYLE_NAME_EXECUTIVE:-executive-brief}"
  local expected_entries_json
  if ! expected_entries_json="$(jq -c '
    [(.hooks // {}) | to_entries[] as $event | $event.value[]?
      | select(type == "object")
      | {event: $event.key, contract: del(.hooks),
         hooks: [(.hooks // [])[]? | select(type == "object")]}]
    + [{event: "SessionStart", contract: {}, hooks: [
        {type: "command", command: "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-resume.sh"},
        {type: "command", command: "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh"}
      ]}]
  ' "${SETTINGS_PATCH_SNAPSHOT}")"; then
    return 1
  fi

  temp_path="$(mktemp "${SETTINGS}.tmp.XXXXXX")"
  # Seed the random same-directory temp from the input so mode/ownership are
  # retained when jq truncates it for rendered output.
  cp -p "${SETTINGS}" "${temp_path}"

  if ! jq --arg omc_style "${omc_style_name}" \
     --arg omc_style_executive "${omc_style_name_executive}" \
     --argjson expected_entries "${expected_entries_json}" \
     --slurpfile patch "${SETTINGS_PATCH_SNAPSHOT}" '
    def managed_hooks($event; $entry):
      ($entry | del(.hooks)) as $contract
      | [$expected_entries[]
          | select(.event == $event and .contract == $contract)
          | .hooks[]];
    # Remove managed hooks individually so a mixed entry retains every
    # foreign hook and its matcher. Drop an event only when managed removal
    # itself empties that event; pre-existing null/empty structures survive.
    .hooks = (
      (.hooks // {}) | to_entries | map(.key as $event |
        (.value // []) as $original
        | ([ $original[]? as $entry
             | select(($entry | type) == "object"
                 and (($entry.hooks | type) == "array"))
             | managed_hooks($event; $entry) as $managed
             | $entry.hooks[]? | select($managed | index(.) != null) ]
           | length > 0) as $changed
        | if $changed then
            .value = [
              $original[] as $entry
              | if (($entry | type) == "object" and (($entry.hooks | type) == "array")) then
                  managed_hooks($event; $entry) as $managed
                  | [$entry.hooks[] | select($managed | index(.) == null)] as $kept
                  | if ($kept | length) == ($entry.hooks | length) then $entry
                    elif ($kept | length) == 0 then empty
                    else $entry | .hooks = $kept
                    end
                else $entry
                end
            ]
            | select((.value | length) > 0)
          else .
          end
      ) | from_entries
    )
    # Remove hooks key if empty.
    | if (.hooks | length) == 0 then del(.hooks) else . end
    # Remove oh-my-claude settings keys only if they match our values.
    # outputStyle is matched against either bundled style frontmatter name
    # captured before removal (env $omc_style for oh-my-claude.md,
    # $omc_style_executive for executive-brief.md), so in-place
    # customizations are correctly cleaned rather than orphaned. The
    # legacy "OpenCode Compact" name is also recognized for pre-v1.26.0
    # installs. Custom user outputStyle values are preserved (cannot be
    # cleaned without false positives).
    | if (.outputStyle == $omc_style or .outputStyle == $omc_style_executive or .outputStyle == "OpenCode Compact") then del(.outputStyle) else . end
    | if .effortLevel == $patch[0].effortLevel then del(.effortLevel) else . end
    | if .spinnerTipsEnabled == $patch[0].spinnerTipsEnabled then del(.spinnerTipsEnabled) else . end
    | if .spinnerVerbs == $patch[0].spinnerVerbs then del(.spinnerVerbs) else . end
    | if ((.permissions | type) == "object" and .permissions.defaultMode == "bypassPermissions") then
        .permissions |= del(.defaultMode)
        | if .permissions == {} then del(.permissions) else . end
      else . end
    | if .skipDangerousModePermissionPrompt == true then del(.skipDangerousModePermissionPrompt) else . end
    | if .statusLine == $patch[0].statusLine then del(.statusLine) else . end
  ' "${SETTINGS}" > "${temp_path}"; then
    rm -f "${temp_path}"
    return 1
  fi

  if ! mv "${temp_path}" "${SETTINGS}"; then
    rm -f "${temp_path}"
    return 1
  fi
}

if ! stage_settings_cleanup; then
  printf 'No managed files were removed. Repair the settings condition above and rerun uninstall.sh.\n' >&2
  exit 1
fi

# Re-attest after rendering and immediately before the first external or
# managed mutation. Publication performs the same complete seal check again.
if [[ -n "${SETTINGS_STAGE_PATH}" ]] && ! settings_seal_is_current; then
  printf 'No managed files were removed because settings.json changed after staging. Rerun uninstall.sh.\n' >&2
  exit 1
fi

# Disable and remove the live platform scheduler while its cleanup authority
# and the installed harness are still present. A failed cleanup aborts before
# any harness file or staged settings document is removed/published.
if watchdog_scheduler_present \
    && ! prepare_watchdog_outer_rollback; then
  printf 'No managed files were removed because the pre-cleanup scheduler generation could not be snapshotted for enclosing rollback.\n' >&2
  exit 1
fi
if ! cleanup_watchdog_scheduler; then
  exit 1
fi
uninstall_test_barrier \
  "${OMC_TEST_UNINSTALL_WATCHDOG_CLEANED_READY_FILE:-}" \
  "${OMC_TEST_UNINSTALL_WATCHDOG_CLEANED_RELEASE_FILE:-}" \
  "${WATCHDOG_OUTER_ROLLBACK_DIR:-${CLAUDE_HOME}}" || exit 1

# Re-attest every removal target after the unbounded confirmation window and
# scheduler mutation. Publish settings while all managed scripts still exist;
# a publication failure therefore leaves a runnable harness and a safe rerun.
if ! preflight_managed_removal_paths; then
  printf 'Uninstall stopped because a managed removal path changed after confirmation. No harness files were removed.\n' >&2
  exit 1
fi
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]] \
    && ! preflight_quality_constitution_purge; then
  printf 'Uninstall stopped because the Quality Constitution purge path changed after confirmation. No harness files were removed.\n' >&2
  exit 1
fi
if [[ -n "${SETTINGS_STAGE_PATH}" ]] \
    && ! settings_patch_seal_is_current; then
  printf 'Uninstall stopped because the managed settings patch changed after staging. No harness files were removed.\n' >&2
  exit 1
fi
publish_staged_settings_cleanup

# Settings are now clean, so a later path-race refusal cannot leave hooks
# pointing at removed scripts. Re-attest once more immediately before the
# destructive purge/removal loops.
if ! preflight_managed_removal_paths; then
  printf 'Uninstall stopped because a managed removal path changed before deletion. Settings were cleaned; rerun uninstall.sh after repairing the path.\n' >&2
  exit 1
fi
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]] \
    && ! preflight_quality_constitution_purge; then
  printf 'Uninstall stopped because the Quality Constitution purge path changed before deletion. Settings were cleaned; rerun uninstall.sh after repairing the path.\n' >&2
  exit 1
fi

commit_watchdog_outer_rollback_before_harness_mutation() {
  # Re-enabling a scheduler after the first destructive harness mutation could
  # point it at a partially removed runtime. Keep rollback armed through every
  # read-only authorization and cross this boundary only beside the first rm.
  if [[ "${WATCHDOG_OUTER_ROLLBACK_PREPARED:-0}" -eq 1 \
      && "${WATCHDOG_OUTER_ROLLBACK_PHASE:-none}" != "committed" ]]; then
    watchdog_outer_publish_meta committed || return 1
    WATCHDOG_OUTER_ROLLBACK_ARMED=0
    uninstall_test_barrier \
      "${OMC_TEST_UNINSTALL_WATCHDOG_COMMITTED_READY_FILE:-}" \
      "${OMC_TEST_UNINSTALL_WATCHDOG_COMMITTED_RELEASE_FILE:-}" \
      "${WATCHDOG_OUTER_ROLLBACK_DIR}" || return 1
  fi
  WATCHDOG_OUTER_ROLLBACK_ARMED=0
}

# Purge the already-preflighted user-owned subtree only after every settings
# and scheduler precondition has succeeded.
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]] \
    && [[ -d "${QUALITY_CONSTITUTIONS_DIR}" ]]; then
  preflight_quality_constitution_purge \
    && authorize_managed_removal "${QUALITY_CONSTITUTIONS_DIR}" || {
    printf 'Uninstall stopped because the Quality Constitution path changed immediately before deletion.\n' >&2
    exit 1
  }
  commit_watchdog_outer_rollback_before_harness_mutation
  rm -rf -- "${QUALITY_CONSTITUTIONS_DIR}"
  removed+=("Removed user-requested Quality Constitutions: ${QUALITY_CONSTITUTIONS_DIR}")
fi

# Remove the exact preflighted oh-my-claude-authored post-merge git hook. A
# second path check closes the ordinary preflight-to-delete window if the
# repository or hooks directory was retargeted while the confirmation prompt
# was open.
if [[ -n "${MANAGED_GIT_HOOK_PATH}" ]]; then
  preflight_no_symlinked_path_components "${MANAGED_GIT_HOOK_PATH}" || {
    printf 'Uninstall stopped because the managed git-hook path changed after preflight.\n' >&2
    exit 1
  }
  if ! preflight_managed_git_hook_path; then
    printf 'Uninstall stopped because the managed git hook changed after confirmation. Settings were cleaned; the hook and harness files were preserved.\n' >&2
    exit 1
  fi
  commit_watchdog_outer_rollback_before_harness_mutation
  rm -f -- "${MANAGED_GIT_HOOK_PATH}" || exit 1
  [[ ! -e "${MANAGED_GIT_HOOK_PATH}" \
      && ! -L "${MANAGED_GIT_HOOK_PATH}" ]] || exit 1
  removed+=("Removed git hook: ${MANAGED_GIT_HOOK_PATH}")
fi

for dir in "${SKILL_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    authorize_managed_removal "${dir}" || exit 1
    commit_watchdog_outer_rollback_before_harness_mutation
    rm -rf -- "${dir}"
    removed+=("Removed directory: ${dir}")
  fi
done

for wdir in "${WATCHDOG_DIRS[@]}"; do
  if [[ -d "${wdir}" ]]; then
    authorize_managed_removal "${wdir}" || exit 1
    commit_watchdog_outer_rollback_before_harness_mutation
    rm -rf -- "${wdir}"
    removed+=("Removed directory: ${wdir}")
  fi
done

if [[ -d "${QP_DIR}" ]]; then
  authorize_managed_removal "${QP_DIR}" || exit 1
  commit_watchdog_outer_rollback_before_harness_mutation
  rm -rf -- "${QP_DIR}"
  removed+=("Removed directory: ${QP_DIR}")
fi

for f in "${AGENT_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    authorize_managed_removal "${f}" || exit 1
    commit_watchdog_outer_rollback_before_harness_mutation
    rm -f -- "${f}"
    removed+=("Removed file: ${f}")
  fi
done

for f in "${STANDALONE_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    authorize_managed_removal "${f}" || exit 1
    commit_watchdog_outer_rollback_before_harness_mutation
    rm -f -- "${f}"
    removed+=("Removed file: ${f}")
  fi
done

# omc CLI symlink — only remove the exact installer-owned link target.
if [[ -L "${OMC_SYMLINK}" ]] \
    && [[ "$(readlink "${OMC_SYMLINK}" 2>/dev/null)" \
      == "${CLAUDE_HOME}/bin/omc" ]]; then
  authorize_managed_removal "${OMC_SYMLINK}" || exit 1
  commit_watchdog_outer_rollback_before_harness_mutation
  rm -f -- "${OMC_SYMLINK}"
  removed+=("Removed symlink: ${OMC_SYMLINK}")
fi

for dir in "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/output-styles" \
    "${CLAUDE_HOME}/skills" "${CLAUDE_HOME}/bin"; do
  if [[ -d "${dir}" ]] && [[ -z "$(ls -A "${dir}" 2>/dev/null)" ]]; then
    authorize_managed_removal "${dir}" || exit 1
    commit_watchdog_outer_rollback_before_harness_mutation
    if rmdir "${dir}" 2>/dev/null; then
      removed+=("Removed empty directory: ${dir}")
    fi
  fi
done

# Scheduler/config-only and settings-only uninstalls have no harness rm at
# which to cross the boundary; successful completion itself commits cleanup.
commit_watchdog_outer_rollback_before_harness_mutation

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '=== oh-my-claude uninstall complete ===\n'
printf '\n'
for msg in "${removed[@]}"; do
  printf '  %s\n' "${msg}"
done
printf '\n'
printf 'Your CLAUDE.md and backup directories were preserved.\n'
if [[ "${PURGE_QUALITY_CONSTITUTIONS}" == "true" ]]; then
  printf 'Your user-owned Quality Constitution data was explicitly purged.\n'
else
  printf 'Your user-owned Quality Constitution data was preserved.\n'
fi
printf '\n'
printf 'Note: If ~/.claude/CLAUDE.md still contains oh-my-claude references\n'
printf '(lines starting with @~/.claude/quality-pack/), you may want to\n'
printf 'remove those lines or restore your original from the backup directory.\n'
printf '\n'
printf 'Restart Claude Code for changes to take effect.\n'
