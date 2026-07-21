#!/usr/bin/env bash
#
# switch-tier.sh — Switch oh-my-claude model tier without a full reinstall.
#
# Usage:
#   bash ~/.claude/switch-tier.sh quality    # execution agents on Opus; deliberators keep `inherit`
#   bash ~/.claude/switch-tier.sh balanced   # default split (inherit for planning/review, Sonnet for execution)
#   bash ~/.claude/switch-tier.sh economy    # inherit deliberators; Sonnet specialists; live risk escalation
#   bash ~/.claude/switch-tier.sh quality --force-reconstruct  # reset stale materialized overrides first
#   bash ~/.claude/switch-tier.sh            # show current tier
#
# Reconstructs the 37 shipped `model:` declarations from the embedded
# declaration rosters, applies the tier, and persists it to
# ~/.claude/oh-my-claude.conf. The switch works after the source clone moves;
# custom/plugin agent definitions are never rewritten.
# Per-agent `model_overrides` from the conf are re-applied after the tier
# rewrite so a user's pinned agents survive a tier switch.

set -euo pipefail

CLAUDE_HOME="${HOME}/.claude"
CONF_PATH="${CLAUDE_HOME}/oh-my-claude.conf"
OPERATION_LOCK_DIR="${CLAUDE_HOME}/.install.lock"
OPERATION_LOCK_HELD=0
OPERATION_LOCK_BORROWED=0
OPERATION_LOCK_TOKEN=""
OPERATION_LOCK_ID=""
OPERATION_LOCK_AUTH_PID=""
OPERATION_LOCK_AUTH_TOKEN=""
OPERATION_LOCK_PARTICIPANT_PATH=""
OPERATION_LOCK_PARTICIPANT_TOKEN=""
OPERATION_LOCK_PARTICIPANT_ID=""
OPERATION_LOCK_RELEASE_MARKER="${OPERATION_LOCK_DIR}/owner-released"
SWITCH_TX_DIR="${CLAUDE_HOME}/.switch-tier-transaction"
SWITCH_TX_ACTIVE=0
SWITCH_RECOVERING=0
SWITCH_COMMITTED=0
SWITCH_TX_ID=""
ENTRY_MODELS=""
MODEL_OVERRIDE_EXPECTATIONS=""
PARENT_CONFIG_TX_DIR="${CLAUDE_HOME}/.omc-config-transaction"
PARENT_CONFIG_TX_ID=""
PARENT_CONFIG_CAP_ID=""
PARENT_CONFIG_INTENTS_ID=""
SWITCH_TX_TEXT_SNAPSHOT=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

operation_lock_release_marker_matches() {
  local marker_path="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" marker_snapshot="" marker_lock_id=""
  local marker_owner_pid="" marker_owner_token=""
  [[ -n "${marker_path}" && -n "${lock_id}" && -n "${owner_pid}" \
      && -n "${owner_token}" && -f "${marker_path}" \
      && ! -L "${marker_path}" \
      && "$(file_mode_value "${marker_path}" 2>/dev/null || true)" \
        == "600" ]] || return 1
  _switch_tx_read_tsv_row "${marker_path}" 4096 || return 1
  marker_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "$(awk -F '\t' 'END { print (NR == 1 && NF == 4 && $1 == "v1") ? 1 : 0 }' \
    < <(printf '%s' "${marker_snapshot}"))" == "1" ]] || return 1
  IFS=$'\t' read -r _ marker_lock_id marker_owner_pid marker_owner_token \
    < <(printf '%s' "${marker_snapshot}") || return 1
  [[ "${marker_lock_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${marker_owner_pid}" =~ ^[1-9][0-9]*$ \
      && "${marker_owner_token}" \
        =~ ^[0-9]+(\.[0-9]+){2,3}$ \
      && "${marker_lock_id}" == "${lock_id}" \
      && "${marker_owner_pid}" == "${owner_pid}" \
      && "${marker_owner_token}" == "${owner_token}" ]]
}

operation_lock_generation_matches() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  local actual_pid="" actual_token=""
  _switch_lock_read_pid "${OPERATION_LOCK_DIR}/pid" || return 1
  actual_pid="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_lock_read_token "${OPERATION_LOCK_DIR}/token" || return 1
  actual_token="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ -n "${lock_id}" && -n "${owner_pid}" && -n "${owner_token}" \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && "$(file_identity "${OPERATION_LOCK_DIR}" 2>/dev/null || true)" \
        == "${lock_id}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && "${actual_pid}" == "${owner_pid}" \
      && "${actual_token}" == "${owner_token}" ]]
}

publish_operation_lock_release_marker() {
  operation_lock_generation_matches "${OPERATION_LOCK_ID}" "$$" \
    "${OPERATION_LOCK_TOKEN}" || return 1
  if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]]; then
    operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
      "${OPERATION_LOCK_ID}" "$$" "${OPERATION_LOCK_TOKEN}"
    return
  fi
  if ! (umask 077; set -o noclobber; printf 'v1\t%s\t%s\t%s\n' \
      "${OPERATION_LOCK_ID}" "$$" "${OPERATION_LOCK_TOKEN}" \
      > "${OPERATION_LOCK_RELEASE_MARKER}") 2>/dev/null; then
    return 1
  fi
  chmod 600 "${OPERATION_LOCK_RELEASE_MARKER}" || return 1
  operation_lock_generation_matches "${OPERATION_LOCK_ID}" "$$" \
    "${OPERATION_LOCK_TOKEN}" \
    && operation_lock_release_marker_matches \
      "${OPERATION_LOCK_RELEASE_MARKER}" "${OPERATION_LOCK_ID}" \
      "$$" "${OPERATION_LOCK_TOKEN}"
}

released_operation_lock_is_exact() (
  local root="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" pid_id="${5:-}" token_id="${6:-}"
  local marker_id="${7:-}" entry=""
  local actual_pid="" actual_token=""
  local -a entries=()
  [[ -d "${root}" && ! -L "${root}" \
      && "$(file_identity "${root}" 2>/dev/null || true)" \
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
  _switch_lock_read_pid "${root}/pid" || return 1
  actual_pid="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_lock_read_token "${root}/token" || return 1
  actual_token="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ -f "${root}/pid" && ! -L "${root}/pid" \
      && "$(file_identity "${root}/pid" 2>/dev/null || true)" \
        == "${pid_id}" \
      && "${actual_pid}" == "${owner_pid}" \
      && -f "${root}/token" && ! -L "${root}/token" \
      && "$(file_identity "${root}/token" 2>/dev/null || true)" \
        == "${token_id}" \
      && "${actual_token}" == "${owner_token}" \
      && -f "${root}/owner-released" \
      && ! -L "${root}/owner-released" \
      && "$(file_identity "${root}/owner-released" \
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
  pid_id="$(file_identity "${OPERATION_LOCK_DIR}/pid")" || return 1
  token_id="$(file_identity "${OPERATION_LOCK_DIR}/token")" || return 1
  marker_id="$(file_identity "${OPERATION_LOCK_RELEASE_MARKER}")" \
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
  retired_root_id="$(file_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  if ! released_operation_lock_is_exact "${OPERATION_LOCK_DIR}" \
      "${lock_id}" "${owner_pid}" "${owner_token}" "${pid_id}" \
      "${token_id}" "${marker_id}"; then
    [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
        == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  if ! command mv -- "${OPERATION_LOCK_DIR}" "${retired_lock}"; then
    [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
        == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  # A contender may create the next public generation immediately after the
  # rename. Cleanup is bound only to the retired inode from here onward.
  [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
      == "${retired_root_id}" ]] || return 1
  released_operation_lock_is_exact "${retired_lock}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" "${pid_id}" "${token_id}" \
    "${marker_id}" || return 1
  _switch_lock_read_pid "${retired_lock}/pid" \
    && [[ "${SWITCH_TX_TEXT_SNAPSHOT}" == "${owner_pid}" ]] \
    && [[ "$(file_identity "${retired_lock}/pid" 2>/dev/null || true)" \
      == "${pid_id}" ]] \
    && rm -f -- "${retired_lock}/pid" || return 1
  _switch_lock_read_token "${retired_lock}/token" \
    && [[ "${SWITCH_TX_TEXT_SNAPSHOT}" == "${owner_token}" ]] \
    && [[ "$(file_identity "${retired_lock}/token" 2>/dev/null || true)" \
      == "${token_id}" ]] \
    && rm -f -- "${retired_lock}/token" || return 1
  [[ "$(file_identity "${retired_lock}/owner-released" \
      2>/dev/null || true)" == "${marker_id}" ]] \
    && operation_lock_release_marker_matches \
      "${retired_lock}/owner-released" "${lock_id}" \
      "${owner_pid}" "${owner_token}" \
    && rm -f -- "${retired_lock}/owner-released" || return 1
  rmdir "${retired_lock}" || return 1
  [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
      == "${retired_root_id}" ]] || return 1
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
  lock_id="$(file_identity "${OPERATION_LOCK_DIR}")" || return 1
  _switch_lock_read_pid "${OPERATION_LOCK_DIR}/pid" || return 1
  owner_pid="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_lock_read_token "${OPERATION_LOCK_DIR}/token" || return 1
  owner_token="${SWITCH_TX_TEXT_SNAPSHOT}"
  operation_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  reap_released_operation_lock "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  source_id="$(file_identity "${OPERATION_LOCK_DIR}" \
    2>/dev/null || true)"
  [[ "${source_id}" != "${lock_id}" ]]
}

remove_exact_operation_lock_participant() {
  local actual_token=""
  _switch_lock_read_token "${OPERATION_LOCK_PARTICIPANT_PATH}" || return 1
  actual_token="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ -n "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && -n "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && -f "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && ! -L "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && "$(file_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true)" == "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && "${actual_token}" == "${OPERATION_LOCK_PARTICIPANT_TOKEN}" ]] \
    || return 1
  rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}"
}

acquire_operation_lock() {
  mkdir -p "${CLAUDE_HOME}" || return 1
  local attempt=0 owner_pid="" attempt_limit=120
  local parent_pid="${OMC_PARENT_OPERATION_LOCK_PID:-}"
  local parent_token="${OMC_PARENT_OPERATION_LOCK_TOKEN:-}"
  local parent_lock_id="${OMC_PARENT_OPERATION_LOCK_ID:-}"
  local observed_pid="" observed_token=""
  if [[ -n "${parent_pid}" && -n "${parent_token}" ]]; then
    if _switch_lock_read_pid "${OPERATION_LOCK_DIR}/pid"; then
      observed_pid="${SWITCH_TX_TEXT_SNAPSHOT}"
    fi
    if _switch_lock_read_token "${OPERATION_LOCK_DIR}/token"; then
      observed_token="${SWITCH_TX_TEXT_SNAPSHOT}"
    fi
  fi
  if [[ -n "${parent_pid}" && -n "${parent_token}" \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && "${observed_pid}" == "${parent_pid}" \
      && "${observed_token}" == "${parent_token}" ]]; then
    OPERATION_LOCK_ID="$(file_identity "${OPERATION_LOCK_DIR}")" || return 1
    if [[ -n "${parent_lock_id}" \
        && "${OPERATION_LOCK_ID}" != "${parent_lock_id}" ]]; then
      OPERATION_LOCK_ID=""
      return 1
    fi
    if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]]; then
      reap_released_operation_lock "${OPERATION_LOCK_ID}" \
        "${parent_pid}" "${parent_token}" || true
      OPERATION_LOCK_ID=""
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
    OPERATION_LOCK_PARTICIPANT_ID="$(file_identity \
      "${OPERATION_LOCK_PARTICIPANT_PATH}")" || {
      rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}" 2>/dev/null || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    }
    observed_pid=""
    observed_token=""
    if _switch_lock_read_pid "${OPERATION_LOCK_DIR}/pid"; then
      observed_pid="${SWITCH_TX_TEXT_SNAPSHOT}"
    fi
    if _switch_lock_read_token "${OPERATION_LOCK_DIR}/token"; then
      observed_token="${SWITCH_TX_TEXT_SNAPSHOT}"
    fi
    if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]] \
        || [[ "${observed_pid}" != "${parent_pid}" ]] \
        || [[ "${observed_token}" != "${parent_token}" ]] \
        || [[ "$(file_identity "${OPERATION_LOCK_DIR}" \
          2>/dev/null || true)" != "${OPERATION_LOCK_ID}" ]] \
        || [[ "$(file_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
          2>/dev/null || true)" != "${OPERATION_LOCK_PARTICIPANT_ID}" ]]; then
      remove_exact_operation_lock_participant || true
      reap_released_operation_lock "${OPERATION_LOCK_ID}" \
        "${parent_pid}" "${parent_token}" || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      OPERATION_LOCK_PARTICIPANT_ID=""
      return 1
    fi
    OPERATION_LOCK_BORROWED=1
    OPERATION_LOCK_AUTH_PID="${parent_pid}"
    OPERATION_LOCK_AUTH_TOKEN="${parent_token}"
    export OMC_PARENT_OPERATION_LOCK_PID="${parent_pid}"
    export OMC_PARENT_OPERATION_LOCK_TOKEN="${parent_token}"
    export OMC_PARENT_OPERATION_LOCK_ID="${OPERATION_LOCK_ID}"
    return 0
  fi
  if [[ -n "${OMC_TEST_SWITCH_TIER_LOCK_ATTEMPTS:-}" ]]; then
    [[ "${OMC_TEST_SWITCH_TIER_LOCK_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] \
      || return 1
    attempt_limit="${OMC_TEST_SWITCH_TIER_LOCK_ATTEMPTS}"
  fi
  while ! (umask 077; mkdir "${OPERATION_LOCK_DIR}") 2>/dev/null; do
    if reap_stranded_released_operation_lock; then
      continue
    fi
    attempt=$((attempt + 1))
    owner_pid=""
    if _switch_lock_read_pid "${OPERATION_LOCK_DIR}/pid"; then
      owner_pid="${SWITCH_TX_TEXT_SNAPSHOT}"
    fi
    if [[ "${attempt}" -ge "${attempt_limit}" ]]; then
      printf 'Error: another oh-my-claude mutation is active (pid=%s, lock=%s).\n' \
        "${owner_pid:-unknown}" "${OPERATION_LOCK_DIR}" >&2
      printf 'If the owner is gone, verify every participant.* PID is also gone before removing this exact lock manually.\n' >&2
      return 1
    fi
    sleep 0.25 2>/dev/null || sleep 1
  done
  OPERATION_LOCK_ID="$(file_identity "${OPERATION_LOCK_DIR}")" || {
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  }
  if ! chmod 700 "${OPERATION_LOCK_DIR}" 2>/dev/null; then
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  OPERATION_LOCK_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
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
  export OMC_PARENT_OPERATION_LOCK_PID="$$"
  export OMC_PARENT_OPERATION_LOCK_TOKEN="${OPERATION_LOCK_TOKEN}"
  export OMC_PARENT_OPERATION_LOCK_ID="${OPERATION_LOCK_ID}"
}

release_operation_lock() {
  if [[ "${OPERATION_LOCK_BORROWED}" -eq 1 ]]; then
    remove_exact_operation_lock_participant || true
    reap_released_operation_lock "${OPERATION_LOCK_ID}" \
      "${OPERATION_LOCK_AUTH_PID}" "${OPERATION_LOCK_AUTH_TOKEN}" || true
    OPERATION_LOCK_BORROWED=0
    OPERATION_LOCK_PARTICIPANT_PATH=""
    OPERATION_LOCK_PARTICIPANT_TOKEN=""
    OPERATION_LOCK_PARTICIPANT_ID=""
    OPERATION_LOCK_AUTH_PID=""
    OPERATION_LOCK_AUTH_TOKEN=""
    OPERATION_LOCK_ID=""
    return 0
  fi
  [[ "${OPERATION_LOCK_HELD}" -eq 1 ]] || return 0
  if operation_lock_generation_matches "${OPERATION_LOCK_ID}" "$$" \
      "${OPERATION_LOCK_TOKEN}"; then
    publish_operation_lock_release_marker \
      && reap_released_operation_lock "${OPERATION_LOCK_ID}" "$$" \
        "${OPERATION_LOCK_TOKEN}" || true
  fi
  OPERATION_LOCK_HELD=0
  OPERATION_LOCK_AUTH_PID=""
  OPERATION_LOCK_AUTH_TOKEN=""
  OPERATION_LOCK_ID=""
}

safe_regular_leaf_or_absent() {
  local path="${1:-}"
  [[ ! -L "${path}" ]] || return 1
  [[ ! -e "${path}" || -f "${path}" ]]
}

safe_regular_leaf() {
  local path="${1:-}"
  [[ -f "${path}" && ! -L "${path}" ]]
}

file_mode_value() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-7]{3,4}$ ]] || return 1
  printf '%s' "${candidate}"
}

file_size_value() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%z' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%s' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

copy_file_mode() {
  local source="${1:-}" destination="${2:-}" mode=""
  mode="$(file_mode_value "${source}")" || return 1
  chmod "${mode}" "${destination}"
}

file_identity() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%d:%i' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%d:%i' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

file_owner_value() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%u' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%u' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

file_digest() {
  local path="${1:-}" digest=""
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "${path}" 2>/dev/null)" || return 1
    printf 'sha256:%s' "${digest%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "${path}" 2>/dev/null)" || return 1
    printf 'sha256:%s' "${digest%% *}"
  else
    digest="$(cksum < "${path}" 2>/dev/null)" || return 1
    printf 'cksum:%s' "${digest}"
  fi
}

_record_parent_model_intent() {
  local name="${1:-}" digest="${2:-}" mode="${3:-}"
  local capability="" roster_count="" version="" needs_model=""
  local agents_snapshot="" intents_snapshot=""
  [[ "${SKIP_CONF_PERSIST}" -eq 1 ]] || return 0
  [[ "${name}" =~ ^[A-Za-z0-9_-]+\.md$ \
      && -n "${digest}" && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ -n "${PARENT_CONFIG_TX_ID}" \
      && "$(file_identity "${PARENT_CONFIG_TX_DIR}" 2>/dev/null || true)" \
        == "${PARENT_CONFIG_TX_ID}" \
      && "$(file_identity "${PARENT_CONFIG_TX_DIR}/switch-capability" \
        2>/dev/null || true)" == "${PARENT_CONFIG_CAP_ID}" \
      && "$(file_identity "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
        2>/dev/null || true)" == "${PARENT_CONFIG_INTENTS_ID}" \
      && -f "${PARENT_CONFIG_TX_DIR}/version" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/version" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/version" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/needs-model" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/needs-model" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/needs-model" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/switch-capability" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/switch-capability" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/switch-capability" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
      && -f "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
        2>/dev/null || true)" == "600" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
        2>/dev/null || true)" == "600" ]] || return 1
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/version" || return 1
  version="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/needs-model" || return 1
  needs_model="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/switch-capability" || return 1
  capability="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${PARENT_CONFIG_TX_DIR}/agents.tsv" || return 1
  agents_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model-roster "${agents_snapshot}" || return 1
  _switch_tx_read_tsv "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" || return 1
  _switch_tx_validate_tsv_snapshot model "${SWITCH_TX_TEXT_SNAPSHOT}" || return 1
  [[ "${version}" == "1" && "${needs_model}" == "1" ]] || return 1
  [[ -n "${OMC_SWITCH_PARENT_TX_CAPABILITY:-}" \
      && "${capability}" == "${OMC_SWITCH_PARENT_TX_CAPABILITY}" ]] || return 1
  roster_count="$(awk -F '\t' -v wanted="${name}" \
    'NF == 3 && $1 == wanted { count++ } END { print count + 0 }' \
    < <(printf '%s' "${agents_snapshot}"))" || return 1
  [[ "${roster_count}" == "1" ]] || return 1
  printf '%s\t%s\t%s\n' "${name}" "${digest}" "${mode}" \
    >> "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" || return 1
  _switch_tx_read_tsv "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" || return 1
  intents_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model "${intents_snapshot}" || return 1
  [[ -n "${intents_snapshot}" ]] || return 1
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/switch-capability" || return 1
  [[ "$(file_identity "${PARENT_CONFIG_TX_DIR}" 2>/dev/null || true)" \
        == "${PARENT_CONFIG_TX_ID}" \
      && "$(file_identity "${PARENT_CONFIG_TX_DIR}/switch-capability" \
        2>/dev/null || true)" == "${PARENT_CONFIG_CAP_ID}" \
      && "$(file_identity "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
        2>/dev/null || true)" == "${PARENT_CONFIG_INTENTS_ID}" \
      && "${SWITCH_TX_TEXT_SNAPSHOT}" \
        == "${OMC_SWITCH_PARENT_TX_CAPABILITY}" ]] || return 1
}

remove_switch_transaction() {
  local expected_id="" retirement_parent="" retired="" retired_id=""
  local marker=""
  if [[ ! -e "${SWITCH_TX_DIR}" && ! -L "${SWITCH_TX_DIR}" ]]; then
    [[ -z "${SWITCH_TX_ID}" ]]
    return
  fi
  if [[ -L "${SWITCH_TX_DIR}" || ! -d "${SWITCH_TX_DIR}" ]]; then
    printf 'Error: refusing unsafe tier transaction path: %s\n' \
      "${SWITCH_TX_DIR}" >&2
    return 1
  fi
  expected_id="$(file_identity "${SWITCH_TX_DIR}")" || return 1
  if [[ -n "${SWITCH_TX_ID}" && "${expected_id}" != "${SWITCH_TX_ID}" ]]; then
    return 1
  fi
  SWITCH_TX_ID="${expected_id}"
  retirement_parent="$(mktemp -d \
    "${CLAUDE_HOME}/.switch-tier-retired.XXXXXX")" || return 1
  chmod 700 "${retirement_parent}" || {
    rmdir "${retirement_parent}" 2>/dev/null || true
    return 1
  }
  retired="${retirement_parent}/transaction"
  if ! mv -- "${SWITCH_TX_DIR}" "${retired}"; then
    rmdir "${retirement_parent}" 2>/dev/null || true
    return 1
  fi
  retired_id="$(file_identity "${retired}" 2>/dev/null || true)"
  if [[ -e "${SWITCH_TX_DIR}" || -L "${SWITCH_TX_DIR}" \
      || "${retired_id}" != "${expected_id}" ]]; then
    if [[ "${retired_id}" == "${expected_id}" \
        && ! -e "${SWITCH_TX_DIR}" && ! -L "${SWITCH_TX_DIR}" ]]; then
      mv -- "${retired}" "${SWITCH_TX_DIR}" 2>/dev/null || true
    fi
    printf 'Error: tier transaction retirement raced with another writer; retained metadata under %s.\n' \
      "${retirement_parent}" >&2
    return 1
  fi
  switch_tier_test_barrier \
    "${OMC_TEST_SWITCH_RETIRE_MOVED_READY_FILE:-}" \
    "${OMC_TEST_SWITCH_RETIRE_MOVED_RELEASE_FILE:-}" "${retirement_parent}" \
    || return 1
  marker="${retirement_parent}/retirement-authorized"
  if ! printf '1\n%s\n' "${retired_id}" > "${marker}" \
      || ! chmod 600 "${marker}"; then
    rm -f -- "${marker}" 2>/dev/null || true
    if [[ ! -e "${SWITCH_TX_DIR}" && ! -L "${SWITCH_TX_DIR}" \
        && "$(file_identity "${retired}" 2>/dev/null || true)" \
          == "${expected_id}" ]]; then
      mv -- "${retired}" "${SWITCH_TX_DIR}" 2>/dev/null || true
    fi
    rmdir "${retirement_parent}" 2>/dev/null || true
    return 1
  fi
  switch_tier_test_barrier \
    "${OMC_TEST_SWITCH_RETIRE_READY_FILE:-}" \
    "${OMC_TEST_SWITCH_RETIRE_RELEASE_FILE:-}" "${retirement_parent}" \
    || return 1
  [[ -d "${retired}" && ! -L "${retired}" \
      && "$(file_identity "${retired}" 2>/dev/null || true)" \
        == "${retired_id}" ]] \
    && _switch_retirement_marker_valid "${retirement_parent}" || return 1
  rm -rf -- "${retired}" || return 1
  SWITCH_TX_ACTIVE=0
  rm -f -- "${marker}" || return 1
  rmdir "${retirement_parent}" || return 1
  [[ ! -e "${retirement_parent}" && ! -L "${retirement_parent}" ]] \
    || return 1
  SWITCH_TX_ID=""
}

_switch_private_owned_dir() {
  local path="${1:-}" expected_name_re="${2:-}" name="" uid=""
  [[ -d "${path}" && ! -L "${path}" ]] || return 1
  name="$(basename "${path}")"
  [[ "${name}" =~ ${expected_name_re} ]] || return 1
  uid="$(id -u)" || return 1
  [[ "$(file_owner_value "${path}" 2>/dev/null || true)" == "${uid}" \
      && "$(file_mode_value "${path}" 2>/dev/null || true)" == "700" ]]
}

_switch_retirement_marker_valid() {
  local parent="${1:-}" tx="" marker="" marker_snapshot="" marker_id=""
  tx="${parent}/transaction"
  marker="${parent}/retirement-authorized"
  _switch_tx_file_is_safe "${marker}" || return 1
  [[ "$(file_mode_value "${marker}" 2>/dev/null || true)" == "600" ]] \
    || return 1
  _switch_tx_read_tsv "${marker}" 4096 || return 1
  marker_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "$(awk 'NR == 1 { version=$0 } NR == 2 { identity=$0 }
    END { print (NR == 2 && version == "1" && identity ~ /^[0-9]+:[0-9]+$/) ? 1 : 0 }' \
    < <(printf '%s' "${marker_snapshot}"))" == "1" ]] || return 1
  marker_id="$(awk 'NR == 2 { print; exit }' \
    < <(printf '%s' "${marker_snapshot}"))" || return 1
  if [[ -e "${tx}" || -L "${tx}" ]]; then
    [[ -d "${tx}" && ! -L "${tx}" \
        && "$(file_identity "${tx}" 2>/dev/null || true)" \
          == "${marker_id}" ]] || return 1
  fi
}

sweep_switch_transaction_orphans() {
  local candidate="" old_tx="" old_active=0 old_id="" marker=""
  for candidate in "${CLAUDE_HOME}"/.switch-tier-transaction.stage.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    _switch_private_owned_dir "${candidate}" \
      '^\.switch-tier-transaction\.stage\.[A-Za-z0-9]+$' || {
      printf 'Error: unsafe orphan tier stage requires manual inspection: %s\n' \
        "${candidate}" >&2
      return 1
    }
    rm -rf -- "${candidate}" || return 1
  done
  for candidate in "${CLAUDE_HOME}"/.switch-tier-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    _switch_private_owned_dir "${candidate}" \
      '^\.switch-tier-retired\.[A-Za-z0-9]+$' || {
      printf 'Error: unsafe retired tier transaction requires manual inspection: %s\n' \
        "${candidate}" >&2
      return 1
    }
    marker="${candidate}/retirement-authorized"
    if _switch_retirement_marker_valid "${candidate}"; then
      _switch_private_owned_dir "${candidate}" \
        '^\.switch-tier-retired\.[A-Za-z0-9]+$' \
        && _switch_retirement_marker_valid "${candidate}" || return 1
      rm -rf -- "${candidate}/transaction" || return 1
      rm -f -- "${marker}" || return 1
      rmdir "${candidate}" || return 1
      continue
    fi
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      _switch_tx_file_is_safe "${marker}" \
        && [[ "$(file_owner_value "${marker}" 2>/dev/null || true)" \
          == "$(id -u)" ]] || return 1
      rm -f -- "${marker}" || return 1
    fi
    if [[ ! -e "${candidate}/transaction" \
        && ! -L "${candidate}/transaction" ]]; then
      rmdir "${candidate}" || return 1
      continue
    fi
    [[ -d "${candidate}/transaction" \
        && ! -L "${candidate}/transaction" ]] || return 1
    old_tx="${SWITCH_TX_DIR}"
    old_active="${SWITCH_TX_ACTIVE}"
    old_id="${SWITCH_TX_ID}"
    SWITCH_TX_DIR="${candidate}/transaction"
    SWITCH_TX_ID=""
    if ! recover_switch_transaction; then
      SWITCH_TX_DIR="${old_tx}"
      SWITCH_TX_ACTIVE="${old_active}"
      SWITCH_TX_ID="${old_id}"
      return 1
    fi
    SWITCH_TX_DIR="${old_tx}"
    SWITCH_TX_ACTIVE="${old_active}"
    SWITCH_TX_ID="${old_id}"
    rmdir "${candidate}" || {
      printf 'Error: retired tier transaction still contains unexpected data: %s\n' \
        "${candidate}" >&2
      return 1
    }
  done
}

_switch_tx_file_is_safe() {
  local path="${1:-}"
  [[ -f "${path}" && ! -L "${path}" ]]
}

# Durable metadata is imported through one bounded byte snapshot. Bash removes
# raw NUL bytes during command substitution, so validating only the normalized
# shell value can turn (for example) `1<NUL>` into an authoritative `1`. Seal
# the exact source generation, reject non-canonical framing/control bytes, and
# only then expose the snapshot to callers. `line` is exactly one non-empty LF-
# terminated record; `tsv` is empty or a sequence of non-empty LF-terminated
# records; `tsv-row` is exactly one such record.
_switch_tx_read_text_snapshot() {
  local path="${1:-}" kind="${2:-}" max_bytes="${3:-262144}"
  local source_id="" source_digest="" size="" bad_bytes="" lf_count=""
  local payload="" payload_digest=""
  local LC_ALL=C
  SWITCH_TX_TEXT_SNAPSHOT=""
  _switch_tx_file_is_safe "${path}" || return 1
  [[ "${max_bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  source_id="$(file_identity "${path}")" || return 1
  size="$(file_size_value "${path}")" || return 1
  [[ "${size}" =~ ^[0-9]+$ && "${size}" -le "${max_bytes}" ]] || return 1
  source_digest="$(file_digest "${path}")" || return 1
  bad_bytes="$(LC_ALL=C tr -cd '\000\r' < "${path}" \
    | LC_ALL=C wc -c | tr -d '[:space:]')" || return 1
  [[ "${bad_bytes}" == "0" ]] || return 1
  [[ "${kind}" == "line" || "${kind}" == "tsv" \
      || "${kind}" == "tsv-row" ]] || return 1
  payload="$(command cat -- "${path}" && printf '\034')" || return 1
  [[ "${payload}" == *$'\034' ]] || return 1
  payload="${payload%$'\034'}"
  [[ "${#payload}" -eq "${size}" ]] || return 1
  payload_digest="$(file_digest <(printf '%s' "${payload}"))" || return 1
  [[ "${payload_digest}" == "${source_digest}" ]] || return 1
  case "${payload}" in
    *'\u0000'*|*'\U0000'*|*'\x00'*|*'\X00'*|*'\0'*) return 1 ;;
  esac
  [[ "${payload}" != *$'\r'* ]] || return 1
  case "${kind}" in
    line)
      [[ "${#payload}" -gt 1 && "${payload}" == *$'\n' \
          && "${payload}" != *$'\t'* ]] || return 1
      lf_count="$(printf '%s' "${payload}" | LC_ALL=C tr -cd '\n' \
        | LC_ALL=C wc -c | tr -d '[:space:]')" || return 1
      [[ "${lf_count}" == "1" ]] || return 1
      ;;
    tsv|tsv-row)
      if [[ -z "${payload}" ]]; then
        [[ "${kind}" == "tsv" ]] || return 1
      else
        [[ "${payload}" == *$'\n' ]] || return 1
        awk 'length($0) == 0 { exit 1 }' \
          < <(printf '%s' "${payload}") || return 1
        if [[ "${kind}" == "tsv-row" ]]; then
          lf_count="$(printf '%s' "${payload}" | LC_ALL=C tr -cd '\n' \
            | LC_ALL=C wc -c | tr -d '[:space:]')" || return 1
          [[ "${lf_count}" == "1" ]] || return 1
        fi
      fi
      ;;
  esac
  [[ -f "${path}" && ! -L "${path}" \
      && "$(file_identity "${path}" 2>/dev/null || true)" == "${source_id}" \
      && "$(file_size_value "${path}" 2>/dev/null || true)" == "${size}" \
      && "$(file_digest "${path}" 2>/dev/null || true)" \
        == "${source_digest}" ]] || return 1
  SWITCH_TX_TEXT_SNAPSHOT="${payload}"
}

_switch_tx_read_line() {
  _switch_tx_read_text_snapshot "${1:-}" line "${2:-4096}" || return 1
  SWITCH_TX_TEXT_SNAPSHOT="${SWITCH_TX_TEXT_SNAPSHOT%$'\n'}"
}

_switch_lock_read_pid() {
  _switch_tx_read_line "${1:-}" 128 || return 1
  [[ "${SWITCH_TX_TEXT_SNAPSHOT}" =~ ^[1-9][0-9]*$ ]]
}

_switch_lock_read_token() {
  _switch_tx_read_line "${1:-}" 512 || return 1
  [[ "${SWITCH_TX_TEXT_SNAPSHOT}" \
    =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]
}

_switch_tx_read_tsv() {
  _switch_tx_read_text_snapshot "${1:-}" tsv "${2:-262144}"
}

_switch_tx_read_tsv_row() {
  _switch_tx_read_text_snapshot "${1:-}" tsv-row "${2:-4096}"
}

_switch_tx_validate_tsv_snapshot() {
  local kind="${1:-}" snapshot="${2-}" name="" digest="" mode=""
  local unique=0
  [[ "${kind}" == "model-roster" ]] && unique=1
  case "${kind}" in
    model|model-roster)
      awk -F '\t' -v unique="${unique}" \
        'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ ||
          (unique == 1 && seen[$1]++) { bad=1 } END { exit(bad ? 1 : 0) }' \
        < <(printf '%s' "${snapshot}") || return 1
      while IFS=$'\t' read -r name digest mode; do
        _switch_tx_digest_is_valid "${digest}" || return 1
        [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      done < <(printf '%s' "${snapshot}")
      ;;
    digest)
      awk -F '\t' 'NF != 2 { exit 1 }' \
        < <(printf '%s' "${snapshot}") || return 1
      while IFS=$'\t' read -r digest mode; do
        _switch_tx_digest_is_valid "${digest}" || return 1
        [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      done < <(printf '%s' "${snapshot}")
      ;;
    override)
      awk -F '\t' 'NF != 2 || $1 !~ /^[A-Za-z0-9_-]+$/ ||
        $2 !~ /^(inherit|opus|sonnet|haiku)$/ { exit 1 }' \
        < <(printf '%s' "${snapshot}")
      ;;
    *) return 1 ;;
  esac
}

_switch_tx_digest_is_valid() {
  local value="${1:-}" payload=""
  case "${value}" in
    sha256:*)
      payload="${value#sha256:}"
      [[ "${#payload}" -eq 64 && "${payload}" =~ ^[0-9a-fA-F]+$ ]]
      ;;
    cksum:*)
      payload="${value#cksum:}"
      [[ "${payload}" =~ ^[0-9]+[[:space:]][0-9]+$ ]]
      ;;
    *) return 1 ;;
  esac
}

_switch_tx_model_current_is_accepted() {
  local name="${1:-}" entry_digest="${2:-}" entry_mode="${3:-}"
  local path="${AGENTS_DIR}/${name}" digest="" mode="" intents=""
  safe_regular_leaf "${path}" || return 1
  digest="$(file_digest "${path}")" || return 1
  mode="$(file_mode_value "${path}")" || return 1
  if [[ "${digest}" == "${entry_digest}" && "${mode}" == "${entry_mode}" ]]; then
    return 0
  fi
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  intents="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model "${intents}" || return 1
  awk -F '\t' -v wanted="${name}" -v digest="${digest}" -v mode="${mode}" \
    '$1 == wanted && $2 == digest && $3 == mode { found=1 } END { exit(found ? 0 : 1) }' \
    < <(printf '%s' "${intents}")
}

_switch_tx_conf_current_is_accepted() {
  local original_state="${1:-}" entry_digest="${2:-}" entry_mode="${3:-}"
  local digest="" mode="" intents=""
  if [[ "${original_state}" == "absent" ]]; then
    if [[ ! -e "${CONF_PATH}" && ! -L "${CONF_PATH}" ]]; then
      return 0
    fi
  fi
  safe_regular_leaf "${CONF_PATH}" || return 1
  digest="$(file_digest "${CONF_PATH}")" || return 1
  mode="$(file_mode_value "${CONF_PATH}")" || return 1
  if [[ "${original_state}" == "present" \
      && "${digest}" == "${entry_digest}" && "${mode}" == "${entry_mode}" ]]; then
    return 0
  fi
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  intents="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot digest "${intents}" || return 1
  awk -F '\t' -v digest="${digest}" -v mode="${mode}" \
    '$1 == digest && $2 == mode { found=1 } END { exit(found ? 0 : 1) }' \
    < <(printf '%s' "${intents}")
}

_restore_switch_snapshot_file() {
  local snapshot="${1:-}" target="${2:-}" expected_mode="${3:-}" tmp=""
  _switch_tx_file_is_safe "${snapshot}" || return 1
  tmp="$(mktemp "${target%/*}/.$(basename "${target}").switch-recover.XXXXXX")" \
    || return 1
  if ! cp -- "${snapshot}" "${tmp}" \
      || ! chmod "${expected_mode}" "${tmp}" \
      || ! mv -f -- "${tmp}" "${target}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  safe_regular_leaf "${target}" \
    && [[ "$(file_digest "${target}" 2>/dev/null || true)" \
      == "$(file_digest "${snapshot}" 2>/dev/null || true)" ]] \
    && [[ "$(file_mode_value "${target}" 2>/dev/null || true)" \
      == "${expected_mode}" ]]
}

_verify_restored_switch_generations() {
  local name="" expected_digest="" expected_mode="" state=""
  local agents_dir_id="" entry_rows="" conf_entry=""
  _switch_tx_read_line "${SWITCH_TX_DIR}/agents-dir-id" || return 1
  agents_dir_id="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "${agents_dir_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/entry-models.tsv" || return 1
  entry_rows="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model-roster "${entry_rows}" || return 1
  _switch_tx_read_line "${SWITCH_TX_DIR}/conf-state" || return 1
  state="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ -d "${AGENTS_DIR}" && ! -L "${AGENTS_DIR}" \
      && "$(file_identity "${AGENTS_DIR}" 2>/dev/null || true)" \
        == "${agents_dir_id}" ]] || return 1
  while IFS=$'\t' read -r name expected_digest expected_mode; do
    safe_regular_leaf "${AGENTS_DIR}/${name}" || return 1
    [[ "$(file_digest "${AGENTS_DIR}/${name}" 2>/dev/null || true)" \
          == "${expected_digest}" \
        && "$(file_mode_value "${AGENTS_DIR}/${name}" \
          2>/dev/null || true)" == "${expected_mode}" ]] || return 1
  done < <(printf '%s' "${entry_rows}")
  if [[ "${state}" == "absent" ]]; then
    [[ ! -e "${CONF_PATH}" && ! -L "${CONF_PATH}" ]]
    return
  fi
  _switch_tx_read_tsv_row "${SWITCH_TX_DIR}/conf-entry.tsv" || return 1
  conf_entry="${SWITCH_TX_TEXT_SNAPSHOT}"
  IFS=$'\t' read -r expected_digest expected_mode \
    < <(printf '%s' "${conf_entry}") || return 1
  safe_regular_leaf "${CONF_PATH}" || return 1
  [[ "$(file_digest "${CONF_PATH}" 2>/dev/null || true)" \
        == "${expected_digest}" \
      && "$(file_mode_value "${CONF_PATH}" 2>/dev/null || true)" \
        == "${expected_mode}" ]]
}

recover_switch_transaction() {
  local version="" committed="" original_state="" target_tier=""
  local name="" entry_digest="" entry_mode="" snapshot="" path=""
  local conf_entry_digest="" conf_entry_mode=""
  local agents_dir_id="" entry_models="" model_intents=""
  local override_expectations="" conf_intents="" conf_entry=""
  [[ -e "${SWITCH_TX_DIR}" || -L "${SWITCH_TX_DIR}" ]] || return 0
  if [[ -L "${SWITCH_TX_DIR}" || ! -d "${SWITCH_TX_DIR}" ]]; then
    printf 'Error: unsafe durable tier transaction path; inspect it manually: %s\n' \
      "${SWITCH_TX_DIR}" >&2
    return 1
  fi
  [[ "$(file_mode_value "${SWITCH_TX_DIR}" 2>/dev/null || true)" \
    == "700" ]] || return 1
  local current_tx_id=""
  current_tx_id="$(file_identity "${SWITCH_TX_DIR}")" || return 1
  [[ -z "${SWITCH_TX_ID}" || "${SWITCH_TX_ID}" == "${current_tx_id}" ]] \
    || return 1
  SWITCH_TX_ID="${current_tx_id}"
  for path in version target-tier agents-dir-id entry-models.tsv model-intents.tsv \
      override-expectations.tsv conf-state conf-intents.tsv; do
    _switch_tx_file_is_safe "${SWITCH_TX_DIR}/${path}" || {
      printf 'Error: incomplete or unsafe durable tier transaction (%s).\n' \
        "${path}" >&2
      return 1
    }
    [[ "$(file_mode_value "${SWITCH_TX_DIR}/${path}" 2>/dev/null || true)" \
      == "600" ]] || return 1
  done
  [[ -d "${SWITCH_TX_DIR}/models" \
      && ! -L "${SWITCH_TX_DIR}/models" \
      && "$(file_mode_value "${SWITCH_TX_DIR}/models" \
        2>/dev/null || true)" == "700" ]] || return 1
  _switch_tx_read_line "${SWITCH_TX_DIR}/version" || return 1
  version="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "${version}" == "1" ]] || {
    printf 'Error: unsupported tier transaction version %q.\n' "${version}" >&2
    return 1
  }
  _switch_tx_read_line "${SWITCH_TX_DIR}/target-tier" || return 1
  target_tier="${SWITCH_TX_TEXT_SNAPSHOT}"
  case "${target_tier}" in
    quality|balanced|economy) ;;
    *) return 1 ;;
  esac
  _switch_tx_read_line "${SWITCH_TX_DIR}/agents-dir-id" || return 1
  agents_dir_id="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "${agents_dir_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  _switch_tx_read_line "${SWITCH_TX_DIR}/conf-state" || return 1
  original_state="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/entry-models.tsv" || return 1
  entry_models="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  model_intents="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/override-expectations.tsv" || return 1
  override_expectations="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  conf_intents="${SWITCH_TX_TEXT_SNAPSHOT}"

  awk -F '\t' 'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ || seen[$1]++ { bad=1 }
    END { exit(bad || NR == 0 ? 1 : 0) }' \
    < <(printf '%s' "${entry_models}") || return 1
  local entry_count="" snapshot_count="" ios_count=0 roster_agent=""
  entry_count="$(awk 'END { print NR + 0 }' \
    < <(printf '%s' "${entry_models}"))" || return 1
  snapshot_count="$(find "${SWITCH_TX_DIR}/models" -mindepth 1 -maxdepth 1 \
    -print 2>/dev/null | wc -l | tr -d '[:space:]')" || return 1
  [[ "${snapshot_count}" == "${entry_count}" ]] || return 1
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    _switch_tx_digest_is_valid "${entry_digest}" || return 1
    [[ "${entry_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    _shipped_agent_is_known "${name%.md}" || return 1
  done < <(printf '%s' "${entry_models}")
  for roster_agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    if [[ " ${SHIPPED_OPTIONAL_IOS_AGENTS} " == *" ${roster_agent} "* ]]; then
      [[ "$(awk -F '\t' -v wanted="${roster_agent}.md" \
        '$1 == wanted { count++ } END { print count + 0 }' \
        < <(printf '%s' "${entry_models}"))" == "1" ]] \
        && ios_count=$((ios_count + 1))
    else
      [[ "$(awk -F '\t' -v wanted="${roster_agent}.md" \
        '$1 == wanted { count++ } END { print count + 0 }' \
        < <(printf '%s' "${entry_models}"))" == "1" ]] || return 1
    fi
  done
  [[ "${ios_count}" -eq 0 || "${ios_count}" -eq 4 ]] || return 1
  awk -F '\t' 'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ { exit 1 }' \
    < <(printf '%s' "${model_intents}") || return 1
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    _switch_tx_digest_is_valid "${entry_digest}" || return 1
    [[ "${entry_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ "$(awk -F '\t' -v wanted="${name}" \
      '$1 == wanted { count++ } END { print count + 0 }' \
      < <(printf '%s' "${entry_models}"))" == "1" ]] || return 1
  done < <(printf '%s' "${model_intents}")
  awk -F '\t' 'NF != 2 || $1 !~ /^[A-Za-z0-9_-]+$/ ||
      $2 !~ /^(inherit|opus|sonnet|haiku)$/ { exit 1 }' \
    < <(printf '%s' "${override_expectations}") || return 1
  while IFS=$'\t' read -r name entry_mode; do
    [[ "$(awk -F '\t' -v wanted="${name}.md" \
      '$1 == wanted { count++ } END { print count + 0 }' \
      < <(printf '%s' "${entry_models}"))" == "1" ]] || return 1
  done < <(printf '%s' "${override_expectations}")
  awk -F '\t' 'NF != 2 { exit 1 }' \
    < <(printf '%s' "${conf_intents}") || return 1
  while IFS=$'\t' read -r entry_digest entry_mode; do
    _switch_tx_digest_is_valid "${entry_digest}" || return 1
    [[ "${entry_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  done < <(printf '%s' "${conf_intents}")

  case "${original_state}" in
    present)
      _switch_tx_file_is_safe "${SWITCH_TX_DIR}/conf-entry" || return 1
      _switch_tx_file_is_safe "${SWITCH_TX_DIR}/conf-entry.tsv" || return 1
      [[ "$(file_mode_value "${SWITCH_TX_DIR}/conf-entry.tsv" \
        2>/dev/null || true)" == "600" ]] || return 1
      _switch_tx_read_tsv_row "${SWITCH_TX_DIR}/conf-entry.tsv" || return 1
      conf_entry="${SWITCH_TX_TEXT_SNAPSHOT}"
      [[ "$(awk -F '\t' 'END { print (NR == 1 && NF == 2) ? 1 : 0 }' \
        < <(printf '%s' "${conf_entry}"))" == "1" ]] || return 1
      IFS=$'\t' read -r conf_entry_digest conf_entry_mode \
        < <(printf '%s' "${conf_entry}") || return 1
      _switch_tx_digest_is_valid "${conf_entry_digest}" || return 1
      [[ "${conf_entry_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      [[ "$(file_digest "${SWITCH_TX_DIR}/conf-entry" 2>/dev/null || true)" \
          == "${conf_entry_digest}" \
          && "$(file_mode_value "${SWITCH_TX_DIR}/conf-entry" 2>/dev/null || true)" \
          == "${conf_entry_mode}" ]] || return 1
      ;;
    absent)
      [[ ! -e "${SWITCH_TX_DIR}/conf-entry" \
          && ! -L "${SWITCH_TX_DIR}/conf-entry" \
          && ! -e "${SWITCH_TX_DIR}/conf-entry.tsv" \
          && ! -L "${SWITCH_TX_DIR}/conf-entry.tsv" ]] || return 1
      ;;
    *) return 1 ;;
  esac

  # Validate every leaf before restoring any of them. Unknown content is a
  # competing writer, never something this transaction is allowed to erase.
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    [[ "${name}" =~ ^[A-Za-z0-9_-]+\.md$ \
        && -n "${entry_digest}" && "${entry_mode}" =~ ^[0-7]{3,4}$ ]] \
      || return 1
    _shipped_agent_is_known "${name%.md}" || return 1
    snapshot="${SWITCH_TX_DIR}/models/${name}"
    _switch_tx_file_is_safe "${snapshot}" || return 1
    [[ "$(file_digest "${snapshot}" 2>/dev/null || true)" == "${entry_digest}" \
        && "$(file_mode_value "${snapshot}" 2>/dev/null || true)" \
          == "${entry_mode}" ]] || return 1
  done < <(printf '%s' "${entry_models}")
  if [[ -e "${SWITCH_TX_DIR}/committed" \
      || -L "${SWITCH_TX_DIR}/committed" ]]; then
    _switch_tx_file_is_safe "${SWITCH_TX_DIR}/committed" || return 1
    _switch_tx_read_line "${SWITCH_TX_DIR}/committed" || return 1
    committed="${SWITCH_TX_TEXT_SNAPSHOT}"
    [[ "${committed}" == "committed" \
        && "$(file_mode_value "${SWITCH_TX_DIR}/committed" \
          2>/dev/null || true)" == "600" ]] || return 1
    remove_switch_transaction || return 1
    printf 'Recovered committed model-tier transaction metadata.\n'
    return 0
  fi
  [[ -d "${AGENTS_DIR}" && ! -L "${AGENTS_DIR}" ]] || return 1
  [[ "$(file_identity "${AGENTS_DIR}" 2>/dev/null || true)" \
    == "${agents_dir_id}" ]] || return 1
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    _switch_tx_model_current_is_accepted \
      "${name}" "${entry_digest}" "${entry_mode}" || {
      printf 'Error: %s changed outside the interrupted tier transaction; leaving the WAL for inspection.\n' \
        "${AGENTS_DIR}/${name}" >&2
      return 1
    }
  done < <(printf '%s' "${entry_models}")
  _switch_tx_conf_current_is_accepted \
    "${original_state}" "${conf_entry_digest}" "${conf_entry_mode}" || {
    printf 'Error: %s changed outside the interrupted tier transaction; leaving the WAL for inspection.\n' \
      "${CONF_PATH}" >&2
    return 1
  }

  SWITCH_RECOVERING=1
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    path="${AGENTS_DIR}/${name}"
    _switch_tx_model_current_is_accepted \
      "${name}" "${entry_digest}" "${entry_mode}" || {
      SWITCH_RECOVERING=0
      return 1
    }
    _restore_switch_snapshot_file \
      "${SWITCH_TX_DIR}/models/${name}" "${path}" "${entry_mode}" || {
      SWITCH_RECOVERING=0
      return 1
    }
  done < <(printf '%s' "${entry_models}")
  if [[ "${original_state}" == "present" ]]; then
    _switch_tx_conf_current_is_accepted \
      "${original_state}" "${conf_entry_digest}" "${conf_entry_mode}" \
      || { SWITCH_RECOVERING=0; return 1; }
    _restore_switch_snapshot_file "${SWITCH_TX_DIR}/conf-entry" \
      "${CONF_PATH}" "${conf_entry_mode}" \
      || { SWITCH_RECOVERING=0; return 1; }
  elif [[ -e "${CONF_PATH}" || -L "${CONF_PATH}" ]]; then
    _switch_tx_conf_current_is_accepted \
      "${original_state}" "" "" || { SWITCH_RECOVERING=0; return 1; }
    rm -f -- "${CONF_PATH}" || { SWITCH_RECOVERING=0; return 1; }
  fi
  switch_tier_test_barrier \
    "${OMC_TEST_SWITCH_RECOVERY_READY_FILE:-}" \
    "${OMC_TEST_SWITCH_RECOVERY_RELEASE_FILE:-}" "${SWITCH_TX_DIR}" \
    || { SWITCH_RECOVERING=0; return 1; }
  _verify_restored_switch_generations \
    || { SWITCH_RECOVERING=0; return 1; }
  SWITCH_RECOVERING=0
  remove_switch_transaction || return 1
  printf 'Recovered interrupted model-tier transaction; restored the prior configuration.\n'
}

begin_switch_transaction() {
  local stage="" agent_name="" agent_file="" snapshot=""
  local source_id="" source_digest="" source_mode=""
  local conf_id="" conf_digest="" conf_mode="" stage_id="" agents_dir_id=""
  local entries_snapshot="" conf_entry_snapshot=""
  local metadata_value="" snapshot_count="" entry_count=""
  [[ ! -e "${SWITCH_TX_DIR}" && ! -L "${SWITCH_TX_DIR}" ]] || return 1
  stage="$(mktemp -d "${CLAUDE_HOME}/.switch-tier-transaction.stage.XXXXXX")" \
    || return 1
  chmod 700 "${stage}" || { rm -rf -- "${stage}"; return 1; }
  mkdir "${stage}/models" || { rm -rf -- "${stage}"; return 1; }
  chmod 700 "${stage}/models" || { rm -rf -- "${stage}"; return 1; }
  agents_dir_id="$(file_identity "${AGENTS_DIR}")" \
    || { rm -rf -- "${stage}"; return 1; }
  printf '1\n' > "${stage}/version" || { rm -rf -- "${stage}"; return 1; }
  printf '%s\n' "${TIER}" > "${stage}/target-tier" \
    || { rm -rf -- "${stage}"; return 1; }
  printf '%s\n' "${agents_dir_id}" > "${stage}/agents-dir-id" \
    || { rm -rf -- "${stage}"; return 1; }
  : > "${stage}/entry-models.tsv"
  : > "${stage}/model-intents.tsv"
  : > "${stage}/override-expectations.tsv"
  : > "${stage}/conf-intents.tsv"
  chmod 600 "${stage}/"{version,target-tier,agents-dir-id,entry-models.tsv,model-intents.tsv,override-expectations.tsv,conf-intents.tsv} \
    || { rm -rf -- "${stage}"; return 1; }
  for agent_name in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    _shipped_agent_is_active "${agent_name}" || continue
    agent_file="${AGENTS_DIR}/${agent_name}.md"
    safe_regular_leaf "${agent_file}" || { rm -rf -- "${stage}"; return 1; }
    source_id="$(file_identity "${agent_file}")" || { rm -rf -- "${stage}"; return 1; }
    source_digest="$(file_digest "${agent_file}")" || { rm -rf -- "${stage}"; return 1; }
    source_mode="$(file_mode_value "${agent_file}")" || { rm -rf -- "${stage}"; return 1; }
    snapshot="${stage}/models/${agent_name}.md"
    cp -p -- "${agent_file}" "${snapshot}" \
      || { rm -rf -- "${stage}"; return 1; }
    if [[ "$(file_identity "${agent_file}" 2>/dev/null || true)" != "${source_id}" \
        || "$(file_digest "${agent_file}" 2>/dev/null || true)" != "${source_digest}" \
        || "$(file_mode_value "${agent_file}" 2>/dev/null || true)" != "${source_mode}" \
        || "$(file_digest "${snapshot}" 2>/dev/null || true)" != "${source_digest}" \
        || "$(file_mode_value "${snapshot}" 2>/dev/null || true)" != "${source_mode}" ]]; then
      rm -rf -- "${stage}"
      return 1
    fi
    printf '%s\t%s\t%s\n' "${agent_name}.md" "${source_digest}" "${source_mode}" \
      >> "${stage}/entry-models.tsv" || { rm -rf -- "${stage}"; return 1; }
  done
  if [[ -f "${CONF_PATH}" ]]; then
    conf_id="$(file_identity "${CONF_PATH}")" || { rm -rf -- "${stage}"; return 1; }
    conf_digest="$(file_digest "${CONF_PATH}")" || { rm -rf -- "${stage}"; return 1; }
    conf_mode="$(file_mode_value "${CONF_PATH}")" || { rm -rf -- "${stage}"; return 1; }
    cp -p -- "${CONF_PATH}" "${stage}/conf-entry" \
      || { rm -rf -- "${stage}"; return 1; }
    if [[ "$(file_identity "${CONF_PATH}" 2>/dev/null || true)" != "${conf_id}" \
        || "$(file_digest "${CONF_PATH}" 2>/dev/null || true)" != "${conf_digest}" \
        || "$(file_mode_value "${CONF_PATH}" 2>/dev/null || true)" != "${conf_mode}" \
        || "$(file_digest "${stage}/conf-entry" 2>/dev/null || true)" != "${conf_digest}" \
        || "$(file_mode_value "${stage}/conf-entry" 2>/dev/null || true)" != "${conf_mode}" ]]; then
      rm -rf -- "${stage}"
      return 1
    fi
    printf 'present\n' > "${stage}/conf-state"
    printf '%s\t%s\n' "${conf_digest}" "${conf_mode}" > "${stage}/conf-entry.tsv"
    chmod 600 "${stage}/conf-entry.tsv" || { rm -rf -- "${stage}"; return 1; }
  else
    printf 'absent\n' > "${stage}/conf-state"
  fi
  chmod 600 "${stage}/conf-state" || { rm -rf -- "${stage}"; return 1; }
  stage_id="$(file_identity "${stage}")" || { rm -rf -- "${stage}"; return 1; }
  switch_tier_test_barrier \
    "${OMC_TEST_SWITCH_WAL_STAGE_READY_FILE:-}" \
    "${OMC_TEST_SWITCH_WAL_STAGE_RELEASE_FILE:-}" "${stage}" || {
    rm -rf -- "${stage}"
    return 1
  }
  mv -- "${stage}" "${SWITCH_TX_DIR}" || { rm -rf -- "${stage}"; return 1; }
  if [[ -e "${stage}" || -L "${stage}" \
      || ! -d "${SWITCH_TX_DIR}" || -L "${SWITCH_TX_DIR}" \
      || "$(file_identity "${SWITCH_TX_DIR}" 2>/dev/null || true)" \
        != "${stage_id}" ]]; then
    printf 'Error: durable tier transaction publication lost its exact directory generation.\n' >&2
    return 1
  fi
  [[ -d "${AGENTS_DIR}" && ! -L "${AGENTS_DIR}" \
      && "$(file_identity "${AGENTS_DIR}" 2>/dev/null || true)" \
        == "${agents_dir_id}" ]] || return 1
  SWITCH_TX_ACTIVE=1
  SWITCH_TX_ID="${stage_id}"
  ENTRY_MODELS="${SWITCH_TX_DIR}/entry-models.tsv"
  MODEL_OVERRIDE_EXPECTATIONS="${SWITCH_TX_DIR}/override-expectations.tsv"
  _switch_tx_read_line "${SWITCH_TX_DIR}/version" || return 1
  metadata_value="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "${metadata_value}" == "1" ]] || return 1
  _switch_tx_read_line "${SWITCH_TX_DIR}/target-tier" || return 1
  metadata_value="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "${metadata_value}" == "${TIER}" ]] || return 1
  _switch_tx_read_line "${SWITCH_TX_DIR}/agents-dir-id" || return 1
  metadata_value="${SWITCH_TX_TEXT_SNAPSHOT}"
  [[ "${metadata_value}" == "${agents_dir_id}" ]] || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  [[ -z "${SWITCH_TX_TEXT_SNAPSHOT}" ]] || return 1
  _switch_tx_read_tsv "${MODEL_OVERRIDE_EXPECTATIONS}" || return 1
  [[ -z "${SWITCH_TX_TEXT_SNAPSHOT}" ]] || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  [[ -z "${SWITCH_TX_TEXT_SNAPSHOT}" ]] || return 1
  _switch_tx_read_tsv "${ENTRY_MODELS}" || return 1
  entries_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model-roster "${entries_snapshot}" || return 1
  [[ "$(awk -F '\t' 'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ ||
      seen[$1]++ { bad=1 } END { print (bad || NR == 0) ? 0 : 1 }' \
      < <(printf '%s' "${entries_snapshot}"))" == "1" ]] \
    || return 1
  entry_count="$(awk 'END { print NR + 0 }' \
    < <(printf '%s' "${entries_snapshot}"))" || return 1
  snapshot_count="$(find "${SWITCH_TX_DIR}/models" -mindepth 1 -maxdepth 1 \
    -print 2>/dev/null | wc -l | tr -d '[:space:]')" || return 1
  [[ "${entry_count}" == "${snapshot_count}" ]] || return 1
  while IFS=$'\t' read -r agent_name source_digest source_mode; do
    _switch_tx_digest_is_valid "${source_digest}" \
      && [[ "${source_mode}" =~ ^[0-7]{3,4}$ ]] \
      && _shipped_agent_is_known "${agent_name%.md}" || return 1
    _switch_tx_model_current_is_accepted \
      "${agent_name}" "${source_digest}" "${source_mode}" || {
      remove_switch_transaction
      return 1
    }
  done < <(printf '%s' "${entries_snapshot}")
  _switch_tx_read_line "${SWITCH_TX_DIR}/conf-state" || return 1
  metadata_value="${SWITCH_TX_TEXT_SNAPSHOT}"
  if [[ -f "${SWITCH_TX_DIR}/conf-entry.tsv" ]]; then
    [[ "${metadata_value}" == "present" ]] || return 1
    _switch_tx_read_tsv_row "${SWITCH_TX_DIR}/conf-entry.tsv" || return 1
    conf_entry_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
    IFS=$'\t' read -r conf_digest conf_mode \
      < <(printf '%s' "${conf_entry_snapshot}") || return 1
    _switch_tx_digest_is_valid "${conf_digest}" \
      && [[ "${conf_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    _switch_tx_conf_current_is_accepted present "${conf_digest}" "${conf_mode}" \
      || { remove_switch_transaction; return 1; }
  else
    [[ "${metadata_value}" == "absent" ]] || return 1
    _switch_tx_conf_current_is_accepted absent "" "" \
      || { remove_switch_transaction; return 1; }
  fi
}

record_switch_model_intent() {
  local path="${1:-}" name="" digest="" mode=""
  [[ "${SWITCH_TX_ACTIVE}" -eq 1 && "${SWITCH_RECOVERING}" -eq 0 ]] \
    || return 0
  name="$(basename "${path}")"
  digest="$(file_digest "${2:-}")" || return 1
  mode="$(file_mode_value "${2:-}")" || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  _switch_tx_validate_tsv_snapshot model "${SWITCH_TX_TEXT_SNAPSHOT}" || return 1
  printf '%s\t%s\t%s\n' "${name}" "${digest}" "${mode}" \
    >> "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  _switch_tx_validate_tsv_snapshot model "${SWITCH_TX_TEXT_SNAPSHOT}" || return 1
  _record_parent_model_intent "${name}" "${digest}" "${mode}"
}

record_switch_conf_intent() {
  local staged="${1:-}" digest="" mode=""
  [[ "${SWITCH_TX_ACTIVE}" -eq 1 && "${SWITCH_RECOVERING}" -eq 0 ]] \
    || return 0
  digest="$(file_digest "${staged}")" || return 1
  mode="$(file_mode_value "${staged}")" || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  _switch_tx_validate_tsv_snapshot digest "${SWITCH_TX_TEXT_SNAPSHOT}" || return 1
  printf '%s\t%s\n' "${digest}" "${mode}" \
    >> "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  _switch_tx_validate_tsv_snapshot digest "${SWITCH_TX_TEXT_SNAPSHOT}"
}

commit_switch_transaction() {
  local marker=""
  [[ "${SWITCH_TX_ACTIVE}" -eq 1 ]] || return 1
  marker="$(mktemp "${SWITCH_TX_DIR}/.committed.XXXXXX")" || return 1
  if ! printf 'committed\n' > "${marker}" \
      || ! chmod 600 "${marker}" \
      || ! switch_tier_test_barrier \
        "${OMC_TEST_SWITCH_COMMIT_STAGE_READY_FILE:-}" \
        "${OMC_TEST_SWITCH_COMMIT_STAGE_RELEASE_FILE:-}" "${marker}" \
      || ! ln -- "${marker}" "${SWITCH_TX_DIR}/committed" \
      || ! switch_tier_test_barrier \
        "${OMC_TEST_SWITCH_COMMIT_LINK_READY_FILE:-}" \
        "${OMC_TEST_SWITCH_COMMIT_LINK_RELEASE_FILE:-}" \
        "${SWITCH_TX_DIR}/committed" \
      || ! rm -f -- "${marker}"; then
    rm -f -- "${marker}" 2>/dev/null || true
    return 1
  fi
  _switch_tx_read_line "${SWITCH_TX_DIR}/committed" || return 1
  [[ "${SWITCH_TX_TEXT_SNAPSHOT}" == "committed" \
      && "$(file_mode_value "${SWITCH_TX_DIR}/committed" 2>/dev/null || true)" \
        == "600" ]] || return 1
  SWITCH_COMMITTED=1
}

switch_tier_test_barrier() {
  local ready="${1:-}" release="${2:-}" payload="${3:-ready}" attempt=0
  [[ "${OMC_TEST_SWITCH_BARRIER_ENABLE:-0}" == "1" ]] || return 0
  [[ -n "${ready}" && -n "${release}" \
      && "${ready}" == /* && "${release}" == /* ]] || return 1
  printf '%s\n' "${payload}" > "${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 6000 ]] || return 1
    sleep 0.01
  done
}

rewrite_agent_model_file() {
  local agent_file="${1:-}" model="${2:-}" tmp=""
  local source_id="" source_digest="" source_mode=""
  local target_digest="" target_mode=""
  safe_regular_leaf "${agent_file}" || return 1
  source_id="$(file_identity "${agent_file}")" || return 1
  source_digest="$(file_digest "${agent_file}")" || return 1
  source_mode="$(file_mode_value "${agent_file}")" || return 1
  tmp="$(mktemp "${agent_file%/*}/.$(basename "${agent_file}").switch-tier.XXXXXX")" \
    || return 1
  if ! sed "s/^model: .*$/model: ${model}/" "${agent_file}" > "${tmp}" \
      || ! copy_file_mode "${agent_file}" "${tmp}" \
      || ! switch_tier_test_barrier \
        "${OMC_TEST_SWITCH_AGENT_STAGE_READY_FILE:-}" \
        "${OMC_TEST_SWITCH_AGENT_STAGE_RELEASE_FILE:-}" "${agent_file}" \
      || ! safe_regular_leaf "${agent_file}" \
      || [[ "$(file_identity "${agent_file}" 2>/dev/null || true)" \
        != "${source_id}" ]] \
      || [[ "$(file_digest "${agent_file}" 2>/dev/null || true)" \
        != "${source_digest}" ]] \
      || [[ "$(file_mode_value "${agent_file}" 2>/dev/null || true)" \
        != "${source_mode}" ]] \
      || ! record_switch_model_intent "${agent_file}" "${tmp}" \
      || ! target_digest="$(file_digest "${tmp}")" \
      || ! target_mode="$(file_mode_value "${tmp}")" \
      || ! mv -f -- "${tmp}" "${agent_file}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  if ! safe_regular_leaf "${agent_file}" \
      || [[ "$(file_digest "${agent_file}" 2>/dev/null || true)" \
        != "${target_digest}" ]] \
      || [[ "$(file_mode_value "${agent_file}" 2>/dev/null || true)" \
        != "${target_mode}" ]]; then
    return 1
  fi
}

get_conf() {
  local key="$1"
  local line="" value="" result="" last_seen="" saw_row=0
  [[ -f "${CONF_PATH}" ]] || return 1
  # The standalone switcher currently reads only model_tier. Keep its parser
  # aligned with common.sh: exact keys, trimmed values, and last *valid* row
  # wins. A malformed later hand edit cannot erase an earlier valid choice.
  [[ "${key}" == "model_tier" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    last_seen="${value}"
    saw_row=1
    case "${value}" in
      quality|balanced|economy) result="${value}" ;;
    esac
  done < "${CONF_PATH}"
  if [[ -n "${result}" ]]; then
    printf '%s' "${result}"
  elif [[ "${saw_row}" -eq 1 && -n "${last_seen}" ]]; then
    # Preserve the existing diagnostic when no valid authority exists at all;
    # callers still map this noncanonical value to the Balanced default.
    printf '%s' "${last_seen}"
  else
    return 1
  fi
}

# Standalone switcher copies of the two shipped declaration rosters. Keep them
# lockstep with common.sh:omc_agent_declared_model; test-model-overrides.sh
# compares them with the bundle frontmatter. We need the rosters here because an
# installed switcher must be able to prove a source-less Balanced → Quality
# transition is safe without sourcing the much larger runtime hook library.
SHIPPED_INHERIT_AGENTS='abstraction-critic chief-of-staff divergent-framer draft-writer editor-critic excellence-reviewer metis oracle prometheus quality-planner quality-reviewer release-reviewer rigor-reviewer writing-architect'
SHIPPED_FIXED_AGENTS='atlas backend-api-developer briefing-analyst data-lens design-lens design-reviewer devops-infrastructure-engineer frontend-developer fullstack-feature-builder growth-lens ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer librarian literature-scout product-lens quality-researcher research-data-analyst security-lens sre-lens test-automation-engineer visual-craft-lens'
SHIPPED_OPTIONAL_IOS_AGENTS='ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer'
OPTIONAL_IOS_DISABLED=0

_shipped_agent_is_known() {
  local wanted="$1" agent
  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    [[ "${wanted}" == "${agent}" ]] && return 0
  done
  return 1
}

_shipped_agent_is_active() {
  local agent="$1" optional
  if [[ "${OPTIONAL_IOS_DISABLED}" -eq 1 ]]; then
    for optional in ${SHIPPED_OPTIONAL_IOS_AGENTS}; do
      [[ "${agent}" == "${optional}" ]] && return 1
    done
  fi
  return 0
}

_agent_has_exact_valid_model() {
  local agent_file="${AGENTS_DIR}/$1.md" model_count model_value
  [[ -f "${agent_file}" ]] || return 1
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  [[ "${model_count}" == "1" \
      && "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]
}

_agent_has_exact_inherit_model() {
  local agent_file="${AGENTS_DIR}/$1.md"
  [[ -f "${agent_file}" ]] || return 1
  [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" \
      && "$(grep -cE '^model: inherit$' "${agent_file}" 2>/dev/null || true)" == "1" ]]
}

# Return the enforceable subset of one model_overrides row. This mirrors the
# runtime resolver: malformed pairs are discarded individually, while a row
# with no valid pins is not an authority capable of erasing an earlier valid
# duplicate. An explicit empty row remains the supported clear operation.
_filter_model_overrides() {
  local raw="${1:-}" pair="" agent="" model="" summary=""
  local -a pairs=()
  [[ -n "${raw}" ]] || return 0
  IFS=',' read -ra pairs <<< "${raw}"
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ "${pair}" == *:* ]] || continue
    agent="${pair%:*}"
    model="${pair##*:}"
    [[ "${agent}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] || continue
    case "${model}" in
      opus|sonnet|haiku) ;;
      inherit)
        [[ "${agent}" != *:* ]] || continue
        if _shipped_agent_is_known "${agent}"; then
          _shipped_agent_is_active "${agent}" \
            && _agent_has_exact_valid_model "${agent}" || continue
        else
          _agent_has_exact_inherit_model "${agent}" || continue
        fi
        ;;
      *) continue ;;
    esac
    summary="${summary}${summary:+,}${agent}:${model}"
  done
  printf '%s' "${summary}"
}

_read_last_valid_model_overrides() {
  local conf="${1:-}" line="" value="" normalized="" result=""
  [[ -f "${conf}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "model_overrides="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "${value}" ]]; then
      result=""
      continue
    fi
    normalized="$(_filter_model_overrides "${value}")"
    # The filtered subset proves row authority; retain the accepted raw row so
    # apply-time diagnostics still name each rejected sibling pair.
    [[ -n "${normalized}" ]] && result="${value}"
  done < "${conf}"
  printf '%s' "${result}"
}

_preflight_shipped_roster() {
  local agent agent_file model_count model_value ios_present=0 failures=0
  for agent in ${SHIPPED_OPTIONAL_IOS_AGENTS}; do
    if [[ -e "${AGENTS_DIR}/${agent}.md" \
        || -L "${AGENTS_DIR}/${agent}.md" ]]; then
      ios_present=$((ios_present + 1))
    fi
  done
  if [[ "${ios_present}" -eq 0 ]]; then
    # `install.sh --no-ios` intentionally removes this complete optional pack.
    OPTIONAL_IOS_DISABLED=1
  elif [[ "${ios_present}" -ne 4 ]]; then
    printf 'Error: incomplete optional iOS agent pack (%d/4 present); reinstall before switching tiers.\n' \
      "${ios_present}" >&2
    return 1
  fi

  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    _shipped_agent_is_active "${agent}" || continue
    agent_file="${AGENTS_DIR}/${agent}.md"
    if ! safe_regular_leaf "${agent_file}"; then
      printf 'Error: missing, symlinked, or non-regular shipped agent definition: %s\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
      continue
    fi
    model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
    model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
    if [[ "${model_count}" != "1" ]] \
        || [[ ! "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]; then
      printf 'Error: malformed shipped agent model frontmatter: %s (expected exactly one valid model: line).\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

_set_shipped_agent_model() {
  local agent="$1" model="$2" agent_file
  agent_file="${AGENTS_DIR}/${agent}.md"
  _shipped_agent_is_active "${agent}" || return 0
  safe_regular_leaf "${agent_file}" || return 1
  [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" ]] \
    || return 1
  grep -qE "^model: ${model}$" "${agent_file}" && return 0
  rewrite_agent_model_file "${agent_file}" "${model}"
}

_apply_shipped_tier() {
  local tier="$1" agent inherit_model fixed_model
  case "${tier}" in
    quality)  inherit_model="inherit"; fixed_model="opus" ;;
    balanced) inherit_model="inherit"; fixed_model="sonnet" ;;
    # Keep the inherited half of the composition explicit in installed
    # frontmatter. Runtime Economy may omit the Agent model for a
    # medium/high-risk deliberator; that omission must land on `inherit`, not
    # on a stale flattened definition that silently defeats the escalation.
    economy)  inherit_model="inherit"; fixed_model="sonnet" ;;
    *) return 1 ;;
  esac
  for agent in ${SHIPPED_INHERIT_AGENTS}; do
    _set_shipped_agent_model "${agent}" "${inherit_model}"
  done
  for agent in ${SHIPPED_FIXED_AGENTS}; do
    _set_shipped_agent_model "${agent}" "${fixed_model}"
  done
}

# ---------------------------------------------------------------------------
# Show current tier if no argument
# ---------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  current="$(get_conf model_tier 2>/dev/null || true)"
  case "${current}" in
    quality|balanced|economy)
      printf 'Saved/materialized model tier: %s\n' "${current}"
      ;;
    "")
      printf 'Saved/materialized model tier: balanced (default)\n'
      ;;
    *)
      printf 'Saved/materialized model tier: balanced (invalid saved value %q ignored)\n' "${current}"
      ;;
  esac
  if [[ -n "${OMC_MODEL_TIER:-}" ]]; then
    case "${OMC_MODEL_TIER}" in
      quality|balanced|economy)
        printf 'Active runtime environment override: %s\n' "${OMC_MODEL_TIER}"
        ;;
      *)
        printf 'Ignored invalid OMC_MODEL_TIER override: %q\n' \
          "${OMC_MODEL_TIER}"
        ;;
    esac
  fi
  printf '\nUsage: bash %s <quality|balanced|economy>\n' "$0"
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate tier argument
# ---------------------------------------------------------------------------

RECOVER_ONLY=0
if [[ "${1:-}" == "--recover-only" ]]; then
  RECOVER_ONLY=1
  TIER="balanced"
  shift
  [[ $# -eq 0 ]] || die "--recover-only accepts no additional arguments."
else
  TIER="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      # Compatibility flag: reconstruction is now roster-based, source-less,
      # and safe enough to run on every switch.
      --force-reconstruct) ;;
      *) die "Unknown argument '$1'." ;;
    esac
    shift
  done

  case "${TIER}" in
    quality|balanced|economy) ;;
    *) die "Invalid tier '${TIER}'. Must be one of: quality, balanced, economy." ;;
  esac
fi

# ---------------------------------------------------------------------------
# Locate installed agent definitions
# ---------------------------------------------------------------------------

AGENTS_DIR="${CLAUDE_HOME}/agents"

# ---------------------------------------------------------------------------
# Persist tier choice
# ---------------------------------------------------------------------------

set_conf() {
  local key="$1" value="$2"
  local tmp="" source_exists=0 grep_rc=0
  local source_id="" source_digest="" source_mode=""
  safe_regular_leaf_or_absent "${CONF_PATH}" || {
    printf 'Error: refusing symlinked or non-regular config target: %s\n' \
      "${CONF_PATH}" >&2
    return 1
  }
  [[ -f "${CONF_PATH}" ]] && source_exists=1
  if [[ "${source_exists}" -eq 1 ]]; then
    source_id="$(file_identity "${CONF_PATH}")" || return 1
    source_digest="$(file_digest "${CONF_PATH}")" || return 1
    source_mode="$(file_mode_value "${CONF_PATH}")" || return 1
  fi
  tmp="$(mktemp "${CLAUDE_HOME}/.oh-my-claude.conf.switch-tier.XXXXXX")" \
    || return 1
  if [[ "${source_exists}" -eq 1 ]]; then
    grep -v -E "^${key}=" "${CONF_PATH}" > "${tmp}" 2>/dev/null \
      || grep_rc=$?
    if [[ "${grep_rc}" -gt 1 ]]; then
      rm -f -- "${tmp}" 2>/dev/null || true
      printf 'Error: failed to read existing config safely; no tier row published.\n' >&2
      return 1
    fi
  else
    : > "${tmp}" || {
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    }
  fi
  if ! printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  if [[ "${source_exists}" -eq 1 ]]; then
    if ! copy_file_mode "${CONF_PATH}" "${tmp}"; then
      rm -f -- "${tmp}" 2>/dev/null || true
      printf 'Error: could not preserve config mode; no tier row published.\n' >&2
      return 1
    fi
  elif ! chmod 600 "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  switch_tier_test_barrier \
    "${OMC_TEST_SWITCH_CONF_STAGE_READY_FILE:-}" \
    "${OMC_TEST_SWITCH_CONF_STAGE_RELEASE_FILE:-}" "${CONF_PATH}" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  }
  if ! safe_regular_leaf_or_absent "${CONF_PATH}" \
      || { [[ "${source_exists}" -eq 1 ]] && [[ ! -f "${CONF_PATH}" ]]; } \
      || { [[ "${source_exists}" -eq 0 ]] \
        && { [[ -e "${CONF_PATH}" ]] || [[ -L "${CONF_PATH}" ]]; }; }; then
    rm -f -- "${tmp}" 2>/dev/null || true
    printf 'Error: config target changed during staging; no tier row published.\n' >&2
    return 1
  fi
  if [[ "${source_exists}" -eq 1 ]] \
      && { [[ "$(file_identity "${CONF_PATH}" 2>/dev/null || true)" \
            != "${source_id}" ]] \
        || [[ "$(file_digest "${CONF_PATH}" 2>/dev/null || true)" \
            != "${source_digest}" ]] \
        || [[ "$(file_mode_value "${CONF_PATH}" 2>/dev/null || true)" \
            != "${source_mode}" ]]; }; then
    rm -f -- "${tmp}" 2>/dev/null || true
    printf 'Error: config changed during staging; refusing to overwrite the newer file.\n' >&2
    return 1
  fi
  if ! record_switch_conf_intent "${tmp}" \
      || ! mv -f -- "${tmp}" "${CONF_PATH}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  local published_digest="" published_mode=""
  local conf_intents_snapshot="" published=""
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  conf_intents_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  published="$(awk -F '\t' 'NF == 2 { digest=$1; mode=$2 }
    END { if (digest != "") printf "%s\t%s", digest, mode }' \
    < <(printf '%s' "${conf_intents_snapshot}"))" || return 1
  [[ -n "${published}" ]] || return 1
  IFS=$'\t' read -r published_digest published_mode \
    <<< "${published}" || return 1
  if ! safe_regular_leaf "${CONF_PATH}" \
      || [[ "$(file_digest "${CONF_PATH}" 2>/dev/null || true)" \
        != "${published_digest}" ]] \
      || [[ "$(file_mode_value "${CONF_PATH}" 2>/dev/null || true)" \
        != "${published_mode}" ]]; then
    printf 'Error: config publication did not retain the staged bytes and mode.\n' >&2
    return 1
  fi
}

# Apply per-agent model overrides on top of the tier rewrite. Mirrors
# install.sh's apply_model_overrides (kept in lockstep — see the matching
# function there). Format: model_overrides=agent:model,agent:model where
# model is opus|sonnet|haiku|inherit. Bad pairs are skipped, never fatal.
apply_model_overrides() {
  local agents_dir="$1"
  local conf_path="$2"
  local env_raw="${OMC_MODEL_OVERRIDES:-}" raw="${OMC_MODEL_OVERRIDES:-}"
  if [[ -n "${MODEL_OVERRIDE_EXPECTATIONS:-}" ]]; then
    _switch_tx_read_tsv "${MODEL_OVERRIDE_EXPECTATIONS}" || return 1
    _switch_tx_validate_tsv_snapshot override "${SWITCH_TX_TEXT_SNAPSHOT}" \
      || return 1
  fi

  # Environment precedence is earned by at least one resolver-valid pin. A
  # wholly malformed environment value must not shadow valid saved pins. A
  # valid explicit-model namespaced pin still establishes environment
  # precedence, but remains runtime-only because there is no safe one-file
  # materialization for plugin identities in ~/.claude/agents. Namespaced
  # inherit is not valid authority: omission cannot change a plugin definition.
  if [[ -n "${env_raw}" ]]; then
    local env_pair env_agent env_model env_has_valid=0
    local -a env_pairs=()
    IFS=',' read -ra env_pairs <<< "${env_raw}"
    for env_pair in "${env_pairs[@]}"; do
      env_pair="${env_pair//[[:space:]]/}"
      [[ "${env_pair}" == *:* ]] || continue
      env_agent="${env_pair%:*}"
      env_model="${env_pair##*:}"
      [[ "${env_agent}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] \
        || continue
      case "${env_model}" in
        opus|sonnet|haiku) env_has_valid=1; break ;;
        inherit)
          if [[ "${env_agent}" != *:* ]] \
              && { { _shipped_agent_is_known "${env_agent}" \
                    && _shipped_agent_is_active "${env_agent}" \
                    && _agent_has_exact_valid_model "${env_agent}"; } \
                || { ! _shipped_agent_is_known "${env_agent}" \
                    && _agent_has_exact_inherit_model "${env_agent}"; }; }; then
            env_has_valid=1
            break
          fi
          ;;
      esac
    done
    if [[ "${env_has_valid}" -eq 0 ]]; then
      printf '  model_overrides: OMC_MODEL_OVERRIDES has no valid pins; falling back to saved overrides\n' >&2
      raw=""
    fi
  fi
  if [[ -z "${raw}" && -f "${conf_path}" ]]; then
    raw="$(_read_last_valid_model_overrides "${conf_path}")"
  fi
  [[ -z "${raw}" ]] && return 0

  local -a pairs=()
  IFS=',' read -ra pairs <<< "${raw}"
  [[ "${#pairs[@]}" -eq 0 ]] && return 0

  local applied=0 runtime_only=0 definition_backed=0 skipped=0
  local pair agent model agent_file model_count model_value
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ -z "${pair}" ]] && continue
    agent="${pair%:*}"
    model="${pair##*:}"
    if [[ -z "${agent}" || -z "${model}" || "${agent}" == "${pair}" ]]; then
      printf '  model_overrides: skipping %q — expected agent:model\n' "${pair}" >&2
      skipped=$((skipped + 1)); continue
    fi
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *)
        printf '  model_overrides: skipping %s — invalid model %q (use opus|sonnet|haiku|inherit)\n' "${agent}" "${model}" >&2
        skipped=$((skipped + 1)); continue ;;
    esac
    if [[ ! "${agent}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      if [[ "${agent}" =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]]; then
        if [[ "${model}" == "inherit" ]]; then
          printf '  model_overrides: skipping %s — namespaced inherit is unenforceable because Agent model omission uses the plugin definition\n' "${agent}" >&2
          skipped=$((skipped + 1))
        else
          printf '  model_overrides: runtime-only %s — namespaced pin is enforced at dispatch; plugin definitions are never rewritten\n' "${agent}" >&2
          runtime_only=$((runtime_only + 1))
        fi
      else
        printf '  model_overrides: skipping %q — invalid bare agent id\n' "${agent}" >&2
        skipped=$((skipped + 1))
      fi
      continue
    fi
    if ! _shipped_agent_is_known "${agent}"; then
      if [[ "${model}" == "inherit" ]]; then
        if _agent_has_exact_inherit_model "${agent}"; then
          printf '  model_overrides: definition-backed %s — custom file already declares inherit and remains untouched\n' \
            "${agent}" >&2
          definition_backed=$((definition_backed + 1))
        else
          printf '  model_overrides: skipping %s — custom inherit is definition-backed only; the custom file must already contain exactly one model: inherit line\n' \
            "${agent}" >&2
          skipped=$((skipped + 1))
        fi
      else
        printf '  model_overrides: runtime-only %s — custom bare pin is enforced at dispatch; custom definitions are never rewritten\n' \
          "${agent}" >&2
        runtime_only=$((runtime_only + 1))
      fi
      continue
    fi
    agent_file="${agents_dir}/${agent}.md"
    if ! safe_regular_leaf "${agent_file}"; then
      printf '  model_overrides: skipping %s — no safe regular agent file at %s\n' \
        "${agent}" "${agent_file}" >&2
      skipped=$((skipped + 1)); continue
    fi
    model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
    model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
    if [[ "${model_count}" != "1" ]] \
        || [[ ! "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]; then
      printf '  model_overrides: skipping %s — agent definition must contain exactly one valid model: line\n' \
        "${agent}" >&2
      skipped=$((skipped + 1)); continue
    fi
    rewrite_agent_model_file "${agent_file}" "${model}" || return 1
    if [[ -n "${MODEL_OVERRIDE_EXPECTATIONS:-}" ]]; then
      _switch_tx_read_tsv "${MODEL_OVERRIDE_EXPECTATIONS}" || return 1
      _switch_tx_validate_tsv_snapshot override "${SWITCH_TX_TEXT_SNAPSHOT}" \
        || return 1
      printf '%s\t%s\n' "${agent}" "${model}" \
        >> "${MODEL_OVERRIDE_EXPECTATIONS}" || return 1
      _switch_tx_read_tsv "${MODEL_OVERRIDE_EXPECTATIONS}" || return 1
      _switch_tx_validate_tsv_snapshot override "${SWITCH_TX_TEXT_SNAPSHOT}" \
        || return 1
    fi
    applied=$((applied + 1))
  done

  if [[ "${applied}" -gt 0 || "${runtime_only}" -gt 0 \
      || "${definition_backed}" -gt 0 || "${skipped}" -gt 0 ]]; then
    printf '  Model overrides: %d materialized, %d runtime-only, %d definition-backed, %d skipped\n' \
      "${applied}" "${runtime_only}" "${definition_backed}" "${skipped}"
  fi
}

_last_override_expectation() {
  local agent="$1" expectations=""
  [[ -n "${MODEL_OVERRIDE_EXPECTATIONS:-}" \
      && -f "${MODEL_OVERRIDE_EXPECTATIONS}" ]] || return 0
  _switch_tx_read_tsv "${MODEL_OVERRIDE_EXPECTATIONS}" || return 1
  expectations="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot override "${expectations}" || return 1
  awk -F '\t' -v wanted="${agent}" \
    '$1 == wanted { expected=$2 } END { print expected }' \
    < <(printf '%s' "${expectations}")
}

_verify_one_agent_model() {
  local agent="$1" expected="$2" agent_file model_count actual
  agent_file="${AGENTS_DIR}/${agent}.md"
  if [[ ! -f "${agent_file}" ]]; then
    printf 'Error: tier verification lost agent definition: %s\n' \
      "${agent_file}" >&2
    return 1
  fi
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  actual="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  if [[ "${model_count}" != "1" || "${actual}" != "${expected}" ]]; then
    printf 'Error: tier verification mismatch for %s (expected %s, found %s).\n' \
      "${agent}" "${expected}" "${actual:-missing/malformed}" >&2
    return 1
  fi
  return 0
}

_verify_materialized_tier() {
  local agent expected override failures=0
  local inherit_expected="inherit" fixed_expected="sonnet"
  [[ "${TIER}" == "quality" ]] && fixed_expected="opus"

  for agent in ${SHIPPED_INHERIT_AGENTS}; do
    _shipped_agent_is_active "${agent}" || continue
    expected="${inherit_expected}"
    override="$(_last_override_expectation "${agent}")"
    [[ -n "${override}" ]] && expected="${override}"
    _verify_one_agent_model "${agent}" "${expected}" \
      || failures=$((failures + 1))
  done
  for agent in ${SHIPPED_FIXED_AGENTS}; do
    _shipped_agent_is_active "${agent}" || continue
    expected="${fixed_expected}"
    override="$(_last_override_expectation "${agent}")"
    [[ -n "${override}" ]] && expected="${override}"
    _verify_one_agent_model "${agent}" "${expected}" \
      || failures=$((failures + 1))
  done

  [[ "${failures}" -eq 0 ]]
}

_verify_final_switch_generations() {
  local name="" entry_digest="" entry_mode="" expected=""
  local expected_digest="" expected_mode="" path="" state=""
  local agents_dir_id="" entry_rows="" model_intents="" conf_intents=""
  local conf_entry=""
  _switch_tx_read_line "${SWITCH_TX_DIR}/agents-dir-id" || return 1
  agents_dir_id="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/entry-models.tsv" || return 1
  entry_rows="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model-roster "${entry_rows}" || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/model-intents.tsv" || return 1
  model_intents="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model "${model_intents}" || return 1
  _switch_tx_read_tsv "${SWITCH_TX_DIR}/conf-intents.tsv" || return 1
  conf_intents="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot digest "${conf_intents}" || return 1
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    [[ "$(awk -F '\t' -v wanted="${name}" \
      '$1 == wanted { count++ } END { print count + 0 }' \
      < <(printf '%s' "${entry_rows}"))" == "1" ]] || return 1
  done < <(printf '%s' "${model_intents}")
  [[ -d "${AGENTS_DIR}" && ! -L "${AGENTS_DIR}" \
      && "$(file_identity "${AGENTS_DIR}" 2>/dev/null || true)" \
        == "${agents_dir_id}" ]] || return 1
  while IFS=$'\t' read -r name entry_digest entry_mode; do
    expected="$(awk -F '\t' -v wanted="${name}" \
      '$1 == wanted { digest=$2; mode=$3 }
        END { if (digest != "") printf "%s\t%s", digest, mode }' \
      < <(printf '%s' "${model_intents}"))" || return 1
    if [[ -n "${expected}" ]]; then
      IFS=$'\t' read -r expected_digest expected_mode <<< "${expected}"
    else
      expected_digest="${entry_digest}"
      expected_mode="${entry_mode}"
    fi
    path="${AGENTS_DIR}/${name}"
    safe_regular_leaf "${path}" || return 1
    [[ "$(file_digest "${path}" 2>/dev/null || true)" \
          == "${expected_digest}" \
        && "$(file_mode_value "${path}" 2>/dev/null || true)" \
          == "${expected_mode}" ]] || return 1
  done < <(printf '%s' "${entry_rows}")

  expected="$(awk -F '\t' '$1 != "" { digest=$1; mode=$2 }
    END { if (digest != "") printf "%s\t%s", digest, mode }' \
    < <(printf '%s' "${conf_intents}"))" || return 1
  if [[ -n "${expected}" ]]; then
    IFS=$'\t' read -r expected_digest expected_mode <<< "${expected}"
    safe_regular_leaf "${CONF_PATH}" || return 1
    [[ "$(file_digest "${CONF_PATH}" 2>/dev/null || true)" \
          == "${expected_digest}" \
        && "$(file_mode_value "${CONF_PATH}" 2>/dev/null || true)" \
          == "${expected_mode}" ]] || return 1
    return 0
  fi
  _switch_tx_read_line "${SWITCH_TX_DIR}/conf-state" || return 1
  state="${SWITCH_TX_TEXT_SNAPSHOT}"
  if [[ "${state}" == "absent" ]]; then
    [[ ! -e "${CONF_PATH}" && ! -L "${CONF_PATH}" ]]
    return
  fi
  _switch_tx_read_tsv_row "${SWITCH_TX_DIR}/conf-entry.tsv" || return 1
  conf_entry="${SWITCH_TX_TEXT_SNAPSHOT}"
  IFS=$'\t' read -r expected_digest expected_mode \
    < <(printf '%s' "${conf_entry}") || return 1
  safe_regular_leaf "${CONF_PATH}" || return 1
  [[ "$(file_digest "${CONF_PATH}" 2>/dev/null || true)" \
        == "${expected_digest}" \
      && "$(file_mode_value "${CONF_PATH}" 2>/dev/null || true)" \
        == "${expected_mode}" ]]
}

# ---------------------------------------------------------------------------
# Apply tier
# ---------------------------------------------------------------------------

_switch_lock_only_cleanup() {
  local rc=$?
  release_operation_lock
  return "${rc}"
}
trap '_switch_lock_only_cleanup' EXIT
acquire_operation_lock \
  || die "Could not acquire the shared oh-my-claude mutation lock."

SKIP_CONF_PERSIST=0
if [[ "${RECOVER_ONLY}" -eq 1 ]]; then
  unset OMC_SWITCH_SKIP_CONF_PERSIST OMC_SWITCH_PARENT_TX_CAPABILITY
fi
sweep_switch_transaction_orphans \
  || die "Could not safely settle orphan model-tier transaction metadata."
if [[ "${OMC_SWITCH_SKIP_CONF_PERSIST:-0}" == "1" ]]; then
  parent_version=""
  parent_needs_model=""
  parent_capability=""
  parent_agents_snapshot=""
  parent_intents_snapshot=""
  [[ "${OPERATION_LOCK_BORROWED}" -eq 1 ]] \
    || die "The internal no-persist tier mode requires a verified parent operation lock."
  [[ -d "${PARENT_CONFIG_TX_DIR}" && ! -L "${PARENT_CONFIG_TX_DIR}" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}" 2>/dev/null || true)" \
        == "700" \
      && -f "${PARENT_CONFIG_TX_DIR}/switch-capability" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/switch-capability" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/switch-capability" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/version" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/version" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/version" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/needs-model" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/needs-model" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/needs-model" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
        2>/dev/null || true)" == "600" \
      && -f "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
      && ! -L "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
      && "$(file_mode_value "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
        2>/dev/null || true)" == "600" \
      && -n "${OMC_SWITCH_PARENT_TX_CAPABILITY:-}" ]] \
    || die "The internal no-persist tier capability is missing or stale."
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/version" \
    || die "The parent config transaction version is malformed."
  parent_version="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/needs-model" \
    || die "The parent config model flag is malformed."
  parent_needs_model="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_line "${PARENT_CONFIG_TX_DIR}/switch-capability" \
    || die "The parent config transaction capability is malformed."
  parent_capability="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_read_tsv "${PARENT_CONFIG_TX_DIR}/agents.tsv" \
    || die "The parent config agent roster is malformed."
  parent_agents_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model-roster "${parent_agents_snapshot}" \
    || die "The parent config agent roster is malformed."
  _switch_tx_read_tsv "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv" \
    || die "The parent config intent ledger is malformed."
  parent_intents_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
  _switch_tx_validate_tsv_snapshot model "${parent_intents_snapshot}" \
    || die "The parent config intent ledger is malformed."
  [[ "${parent_version}" == "1" && "${parent_needs_model}" == "1" \
      && "${parent_capability}" == "${OMC_SWITCH_PARENT_TX_CAPABILITY}" \
      && -n "${parent_agents_snapshot}" ]] \
    || die "The internal no-persist tier capability is missing or stale."
  : "${parent_intents_snapshot}"
  PARENT_CONFIG_TX_ID="$(file_identity "${PARENT_CONFIG_TX_DIR}")" \
    || die "The parent config transaction identity could not be sealed."
  PARENT_CONFIG_CAP_ID="$(file_identity \
    "${PARENT_CONFIG_TX_DIR}/switch-capability")" \
    || die "The parent config transaction capability could not be sealed."
  PARENT_CONFIG_INTENTS_ID="$(file_identity \
    "${PARENT_CONFIG_TX_DIR}/agent-intents.tsv")" \
    || die "The parent config intent ledger could not be sealed."
  SKIP_CONF_PERSIST=1
fi

if ! recover_switch_transaction; then
  die "Could not recover the durable tier transaction. If a prior process was killed, inspect ${SWITCH_TX_DIR}; after verifying the owner is gone, remove only ${OPERATION_LOCK_DIR} and retry."
fi
if [[ "${RECOVER_ONLY}" -eq 1 ]]; then
  exit 0
fi
parent_config_aux_metadata_pending=0
for candidate in "${CLAUDE_HOME}"/.omc-config-transaction.stage.* \
    "${CLAUDE_HOME}"/.omc-config-retired.*; do
  if [[ -e "${candidate}" || -L "${candidate}" ]]; then
    parent_config_aux_metadata_pending=1
    break
  fi
done
if [[ "${parent_config_aux_metadata_pending}" -eq 1 ]] \
    || { [[ "${SKIP_CONF_PERSIST}" -eq 0 ]] \
      && { [[ -e "${PARENT_CONFIG_TX_DIR}" ]] \
        || [[ -L "${PARENT_CONFIG_TX_DIR}" ]]; }; }; then
  die "A parent omc-config transaction must be settled with omc-config.sh recover-only before a standalone tier change."
fi
if [[ ! -d "${AGENTS_DIR}" || -L "${AGENTS_DIR}" ]]; then
  die "No safe physical agents directory at ${AGENTS_DIR}. Run the full installer first."
fi
if ! safe_regular_leaf_or_absent "${CONF_PATH}"; then
  die "Refusing symlinked or non-regular config target: ${CONF_PATH}"
fi
if ! _preflight_shipped_roster; then
  die "Tier switch aborted before changing files; reinstall oh-my-claude to repair the shipped agent roster."
fi

printf 'Switching to model tier: %s\n' "${TIER}"

# Publish a complete same-filesystem write-ahead snapshot before the first
# model edit. It survives SIGKILL; the next invocation rolls back only files
# whose exact bytes and modes are either the entry generation or a recorded
# transaction intent. A foreign generation fails closed and keeps the WAL.
begin_switch_transaction \
  || die "Cannot publish the durable model-tier transaction snapshot."
_switch_cleanup() {
  local rc=$?
  if [[ "${SWITCH_TX_ACTIVE}" -eq 1 ]]; then
    if ! recover_switch_transaction; then
      printf 'Error: durable tier rollback did not complete; transaction retained at %s.\n' \
        "${SWITCH_TX_DIR}" >&2
      [[ "${rc}" -ne 0 ]] || rc=1
    fi
  fi
  release_operation_lock
  return "${rc}"
}
trap '_switch_cleanup' EXIT

# The embedded rosters are the canonical declaration source. Rebuild only
# shipped filenames on every transition: this clears removed pins and repairs
# Economy/unknown materialization without a clone, while custom/plugin agents
# retain their author-selected model declaration.
_apply_shipped_tier "${TIER}"

apply_model_overrides "${AGENTS_DIR}" "${CONF_PATH}"

if ! _verify_materialized_tier; then
  die "Tier switch verification failed; restored prior model declarations and left the saved tier unchanged."
fi

# Persist only after every active shipped declaration and materialized bare pin
# matches the composed target. A missing or malformed file can no longer leave
# a false successful tier row behind.
if [[ "${SKIP_CONF_PERSIST}" -eq 0 ]]; then
  set_conf "model_tier" "${TIER}"
fi

if [[ "${OMC_TEST_SWITCH_FAIL_AFTER_CONF:-0}" == "1" ]]; then
  die "Injected failure after tier config publication."
fi
switch_tier_test_barrier \
  "${OMC_TEST_SWITCH_POST_CONF_READY_FILE:-}" \
  "${OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE:-}" "${CONF_PATH}" \
  || die "Tier switch post-publication barrier failed."
if ! _verify_materialized_tier || ! _verify_final_switch_generations; then
  die "Tier switch final generation changed before commit; restored the prior configuration."
fi
commit_switch_transaction \
  || die "Could not commit the durable model-tier transaction."

changed=0
_switch_tx_read_tsv "${ENTRY_MODELS}" \
  || die "Committed tier roster metadata became malformed before reporting."
entry_models_snapshot="${SWITCH_TX_TEXT_SNAPSHOT}"
_switch_tx_validate_tsv_snapshot model-roster "${entry_models_snapshot}" \
  || die "Committed tier roster metadata became malformed before reporting."
while IFS=$'\t' read -r agent_name entry_digest entry_mode; do
  [[ -n "${agent_name}" ]] || continue
  entry_model="$(sed -n 's/^model: //p' \
    "${SWITCH_TX_DIR}/models/${agent_name}" | head -1)"
  final_model="$(grep -E '^model: ' "${AGENTS_DIR}/${agent_name}" 2>/dev/null \
    | head -1 | sed 's/^model: //' || true)"
  [[ "${final_model}" != "${entry_model}" ]] && changed=$((changed + 1))
done < <(printf '%s' "${entry_models_snapshot}")
printf 'Done. %d agent(s) updated to %s tier.\n' "${changed}" "${TIER}"
remove_switch_transaction \
  || die "Tier switch committed, but its completed transaction metadata could not be removed."
