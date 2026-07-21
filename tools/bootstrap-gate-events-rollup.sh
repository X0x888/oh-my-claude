#!/usr/bin/env bash
#
# tools/bootstrap-gate-events-rollup.sh — bounded, crash-retry-safe import of
# per-session gate_events.jsonl files into the user-scope gate-event ledger.
#
# The natural stale-session sweep performs the same aggregation eventually.
# This developer tool makes recent data available immediately without deleting
# its source. Normal imports are occurrence-aware and publish a per-session
# stamp, so a crash after ledger publication but before the stamp is harmless:
# the retry observes that the destination already contains every occurrence.
# `--force` deliberately appends another copy when a valid stamp already exists.
#
# Usage:
#   bash tools/bootstrap-gate-events-rollup.sh
#   bash tools/bootstrap-gate-events-rollup.sh --dry-run
#   bash tools/bootstrap-gate-events-rollup.sh --force

set -euo pipefail
umask 077

dry_run=0
force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --force) force=1; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
DST_FILE="${HOME}/.claude/quality-pack/gate_events.jsonl"
DST_DIR="$(dirname "${DST_FILE}")"
STAMP_NAME=".bootstrap-aggregated"
MAX_SOURCE_BYTES=8388608
MAX_STATE_BYTES=1048576
MAX_DESTINATION_BYTES=67108864
MAX_MANIFEST_BYTES=8388608
MAX_MANIFEST_ENTRIES=10000

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

# Locked publication and the natural sweep must share the exact same lock
# implementation and occurrence-aware merge primitive.
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${COMMON_SH+x}" ]]; then
  if [[ -f "${TOOL_DIR}/../bundle/dot-claude/skills/autowork/scripts/common.sh" ]]; then
    COMMON_SH="${TOOL_DIR}/../bundle/dot-claude/skills/autowork/scripts/common.sh"
  else
    COMMON_SH="${HOME}/.claude/skills/autowork/scripts/common.sh"
  fi
fi
if [[ ! -f "${COMMON_SH}" ]]; then
  printf 'error: common.sh not found: %s (locked publication is required)\n' \
    "${COMMON_SH}" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${COMMON_SH}"
for required_fn in _with_lockdir with_cross_session_log_lock \
    _sweep_file_identity _sweep_file_digest _sweep_file_mode \
    _sweep_file_size _sweep_jsonl_is_bounded_objects \
    _sweep_merge_gate_event_rows_locked; do
  if ! declare -f "${required_fn}" >/dev/null 2>&1; then
    printf 'error: common.sh does not provide required helper: %s\n' \
      "${required_fn}" >&2
    exit 1
  fi
done

_bootstrap_uid() {
  id -u 2>/dev/null
}

_bootstrap_file_uid() {
  local path="$1" value=""
  value="$(stat -f '%u' "${path}" 2>/dev/null || true)"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${value}"
    return 0
  fi
  value="$(stat -c '%u' "${path}" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${value}"
}

_bootstrap_mode_is_private() {
  local path="$1" mode="" perms=""
  mode="$(_sweep_file_mode "${path}")" || return 1
  perms="${mode}"
  if [[ "${#perms}" -eq 4 ]]; then
    perms="${perms:1:3}"
  fi
  [[ "${perms}" =~ ^[0-7]{3}$ ]] || return 1
  [[ "${perms:1:1}" != "2" && "${perms:1:1}" != "3" \
      && "${perms:1:1}" != "6" && "${perms:1:1}" != "7" \
      && "${perms:2:1}" != "2" && "${perms:2:1}" != "3" \
      && "${perms:2:1}" != "6" && "${perms:2:1}" != "7" ]]
}

_bootstrap_safe_owned_dir() {
  local path="$1" expected_uid=""
  [[ -d "${path}" && ! -L "${path}" ]] || return 1
  expected_uid="$(_bootstrap_uid)" || return 1
  [[ "$(_bootstrap_file_uid "${path}")" == "${expected_uid}" ]] || return 1
  _bootstrap_mode_is_private "${path}"
}

_bootstrap_safe_owned_regular() {
  local path="$1" expected_uid=""
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  expected_uid="$(_bootstrap_uid)" || return 1
  [[ "$(_bootstrap_file_uid "${path}")" == "${expected_uid}" ]] || return 1
  _bootstrap_mode_is_private "${path}"
}

if ! _bootstrap_safe_owned_dir "${STATE_ROOT}"; then
  printf 'error: STATE_ROOT must be a private, owned, non-symlink directory: %s\n' \
    "${STATE_ROOT}" >&2
  exit 1
fi
STATE_ROOT_ID="$(_sweep_file_identity "${STATE_ROOT}")" || exit 1

if ! mkdir -p "${DST_DIR}" || ! chmod 700 "${DST_DIR}" 2>/dev/null; then
  printf 'error: cannot create private destination directory: %s\n' \
    "${DST_DIR}" >&2
  exit 1
fi
if ! _bootstrap_safe_owned_dir "${DST_DIR}"; then
  printf 'error: destination directory must be private, owned, and non-symlink: %s\n' \
    "${DST_DIR}" >&2
  exit 1
fi
DST_DIR_ID="$(_sweep_file_identity "${DST_DIR}")" || exit 1

WORK_DIR="$(mktemp -d "${DST_DIR}/.bootstrap-work.XXXXXX")" || {
  printf 'error: cannot create bootstrap work directory\n' >&2
  exit 1
}
MANIFEST="${WORK_DIR}/sources.nul"
_bootstrap_cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" && ! -L "${WORK_DIR}" ]] || return 0
  find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type f -exec rm -f -- {} + \
    2>/dev/null || true
  rmdir "${WORK_DIR}" 2>/dev/null || true
}
_bootstrap_on_signal() {
  _bootstrap_cleanup
  exit 1
}
trap _bootstrap_cleanup EXIT
trap _bootstrap_on_signal HUP INT TERM

_bootstrap_validate_stamp() {
  local stamp="$1" size=""
  _bootstrap_safe_owned_regular "${stamp}" || return 1
  size="$(_sweep_file_size "${stamp}")" || return 1
  [[ "${size}" -eq 0 ]]
}

_bootstrap_read_project_key() {
  local state_file="$1" size="" value=""
  BOOTSTRAP_PROJECT_KEY=""
  if [[ ! -e "${state_file}" && ! -L "${state_file}" ]]; then
    return 0
  fi
  _bootstrap_safe_owned_regular "${state_file}" || return 1
  size="$(_sweep_file_size "${state_file}")" || return 1
  (( size <= MAX_STATE_BYTES )) || return 1
  jq -se '
    length == 1 and
    (.[0] | type == "object") and
    (.[0].project_key? == null or
      (.[0].project_key | type == "string" and
        (. == "" or test("^[a-f0-9]{12}$"))))
  ' "${state_file}" >/dev/null 2>&1 || return 1
  value="$(jq -r '.project_key // ""' "${state_file}" 2>/dev/null)" || return 1
  [[ -z "${value}" || "${value}" =~ ^[a-f0-9]{12}$ ]] || return 1
  BOOTSTRAP_PROJECT_KEY="${value}"
}

_bootstrap_stage_source() {
  local source="$1" sid="$2" pkey="$3" output="$4"
  local source_id="" source_digest="" source_size=""
  _bootstrap_safe_owned_regular "${source}" || return 1
  source_size="$(_sweep_file_size "${source}")" || return 1
  (( source_size > 0 && source_size <= MAX_SOURCE_BYTES )) || return 1
  _sweep_jsonl_is_bounded_objects "${source}" "${MAX_SOURCE_BYTES}" || return 1
  source_id="$(_sweep_file_identity "${source}")" || return 1
  source_digest="$(_sweep_file_digest "${source}")" || return 1
  if [[ -n "${pkey}" ]]; then
    jq -R -c --arg sid "${sid}" --arg pkey "${pkey}" '
      fromjson
      | if type == "object" then
          . + {session_id: $sid, project_key: $pkey}
        else error("gate-event row must be an object") end
    ' "${source}" >"${output}" 2>/dev/null || return 1
  else
    jq -R -c --arg sid "${sid}" '
      fromjson
      | if type == "object" then
          del(.project_key) + {session_id: $sid}
        else error("gate-event row must be an object") end
    ' "${source}" >"${output}" 2>/dev/null || return 1
  fi
  chmod 600 "${output}" || return 1
  _sweep_jsonl_is_bounded_objects "${output}" "${MAX_SOURCE_BYTES}" || return 1
  [[ "$(_sweep_file_identity "${source}" 2>/dev/null || true)" == "${source_id}" \
      && "$(_sweep_file_digest "${source}" 2>/dev/null || true)" == "${source_digest}" ]]
}

_publish_bootstrap_stamp() {
  local stamp="$1" tmp=""
  if [[ "${OMC_TEST_BOOTSTRAP_FAIL_STAMP:-0}" == "1" ]]; then
    return 1
  fi
  [[ ! -e "${stamp}" && ! -L "${stamp}" ]] || return 1
  tmp="$(mktemp "${stamp}.tmp.XXXXXX")" || return 1
  if ! chmod 600 "${tmp}" || ! mv -f -- "${tmp}" "${stamp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  _bootstrap_validate_stamp "${stamp}"
}

# Intentional force publication: construct and validate the complete next
# generation before a same-directory rename. The destination lock is held.
_bootstrap_force_append_locked() {
  local additions="$1" stage="" destination_exists=0
  local destination_id="" destination_digest="" destination_mode="600"
  local stage_size="" stage_digest=""
  if [[ -e "${DST_FILE}" || -L "${DST_FILE}" ]]; then
    _bootstrap_safe_owned_regular "${DST_FILE}" || return 1
    _sweep_jsonl_is_bounded_objects "${DST_FILE}" "${MAX_DESTINATION_BYTES}" || return 1
    destination_exists=1
    destination_id="$(_sweep_file_identity "${DST_FILE}")" || return 1
    destination_digest="$(_sweep_file_digest "${DST_FILE}")" || return 1
    destination_mode="$(_sweep_file_mode "${DST_FILE}")" || return 1
  fi
  stage="$(mktemp "${DST_DIR}/.gate-events.force.XXXXXX")" || return 1
  if [[ "${destination_exists}" -eq 1 ]]; then
    if ! cat "${DST_FILE}" "${additions}" >"${stage}"; then
      rm -f -- "${stage}"
      return 1
    fi
  elif ! cat "${additions}" >"${stage}"; then
    rm -f -- "${stage}"
    return 1
  fi
  if ! chmod "${destination_mode}" "${stage}" \
      || ! _sweep_jsonl_is_bounded_objects "${stage}" "${MAX_DESTINATION_BYTES}"; then
    rm -f -- "${stage}"
    return 1
  fi
  stage_size="$(_sweep_file_size "${stage}")" || { rm -f -- "${stage}"; return 1; }
  stage_digest="$(_sweep_file_digest "${stage}")" || { rm -f -- "${stage}"; return 1; }
  if [[ "${destination_exists}" -eq 1 ]]; then
    [[ "$(_sweep_file_identity "${DST_FILE}" 2>/dev/null || true)" == "${destination_id}" \
        && "$(_sweep_file_digest "${DST_FILE}" 2>/dev/null || true)" == "${destination_digest}" \
        && "$(_sweep_file_mode "${DST_FILE}" 2>/dev/null || true)" == "${destination_mode}" ]] \
      || { rm -f -- "${stage}"; return 1; }
  elif [[ -e "${DST_FILE}" || -L "${DST_FILE}" ]]; then
    rm -f -- "${stage}"
    return 1
  fi
  mv -f -- "${stage}" "${DST_FILE}" || { rm -f -- "${stage}"; return 1; }
  [[ "$(_sweep_file_size "${DST_FILE}" 2>/dev/null || true)" == "${stage_size}" \
      && "$(_sweep_file_digest "${DST_FILE}" 2>/dev/null || true)" == "${stage_digest}" ]]
}

BOOTSTRAP_PUBLISH_RESULT=""
_bootstrap_publish_locked() {
  local staged="$1" stamp="$2" source="$3" source_id="$4" source_digest="$5"
  local force_publish="$6" stamp_present=0
  local destination_before="" destination_after=""
  BOOTSTRAP_PUBLISH_RESULT=""
  [[ "$(_sweep_file_identity "${STATE_ROOT}" 2>/dev/null || true)" == "${STATE_ROOT_ID}" \
      && "$(_sweep_file_identity "${DST_DIR}" 2>/dev/null || true)" == "${DST_DIR_ID}" \
      && "$(_sweep_file_identity "${source}" 2>/dev/null || true)" == "${source_id}" \
      && "$(_sweep_file_digest "${source}" 2>/dev/null || true)" == "${source_digest}" ]] \
    || return 1
  if [[ -e "${stamp}" || -L "${stamp}" ]]; then
    _bootstrap_validate_stamp "${stamp}" || return 1
    stamp_present=1
  fi
  if [[ -e "${DST_FILE}" || -L "${DST_FILE}" ]]; then
    _bootstrap_safe_owned_regular "${DST_FILE}" || return 1
    destination_before="$(_sweep_file_digest "${DST_FILE}")" || return 1
  fi
  if [[ "${force_publish}" -eq 1 && "${stamp_present}" -eq 1 ]]; then
    _bootstrap_force_append_locked "${staged}" || return 1
  else
    # Always merge in normal mode, even when a legacy empty stamp exists.
    # Active sessions can append after their first bootstrap; treating stamp
    # presence as a permanent skip would strand those later rows. Exact
    # occurrence merging makes the unchanged case an inexpensive no-op and
    # also repairs a destination that was truncated after the stamp appeared.
    _sweep_merge_gate_event_rows_locked "${DST_FILE}" "${staged}" || return 1
    # If destination publication completed but this step fails, retry is safe:
    # the occurrence merge above will be a no-op before retrying the stamp.
    if [[ "${stamp_present}" -ne 1 ]]; then
      _publish_bootstrap_stamp "${stamp}" || return 1
    fi
  fi
  destination_after="$(_sweep_file_digest "${DST_FILE}")" || return 1
  if [[ "${force_publish}" -ne 1 && "${stamp_present}" -eq 1 \
      && "${destination_before}" == "${destination_after}" ]]; then
    BOOTSTRAP_PUBLISH_RESULT="already-stamped"
  else
    BOOTSTRAP_PUBLISH_RESULT="published"
  fi
}

BOOTSTRAP_SESSION_RESULT=""
BOOTSTRAP_SESSION_ROWS=0
BOOTSTRAP_SESSION_PROJECT_KEY=""
_bootstrap_process_session_locked() {
  local source="$1" sid="$2" sid_dir="$3" stamp="$4"
  local state_file="${sid_dir}/session_state.json" pkey="" staged=""
  local source_id="" source_digest="" rows=""
  BOOTSTRAP_SESSION_RESULT=""
  BOOTSTRAP_SESSION_ROWS=0
  BOOTSTRAP_SESSION_PROJECT_KEY=""
  _bootstrap_safe_owned_dir "${sid_dir}" || return 1
  [[ "$(dirname "${source}")" == "${sid_dir}" \
      && "$(basename "${source}")" == "gate_events.jsonl" ]] || return 1
  if [[ -e "${stamp}" || -L "${stamp}" ]]; then
    _bootstrap_validate_stamp "${stamp}" || return 1
  fi
  _bootstrap_read_project_key "${state_file}" || return 1
  pkey="${BOOTSTRAP_PROJECT_KEY}"
  staged="${WORK_DIR}/${sid}.jsonl"
  rm -f -- "${staged}" 2>/dev/null || true
  _bootstrap_stage_source "${source}" "${sid}" "${pkey}" "${staged}" || return 1
  source_id="$(_sweep_file_identity "${source}")" || return 1
  source_digest="$(_sweep_file_digest "${source}")" || return 1
  rows="$(wc -l <"${staged}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${rows}" =~ ^[1-9][0-9]*$ ]] || return 1

  if [[ "${dry_run}" -eq 1 ]]; then
    BOOTSTRAP_SESSION_RESULT="preview"
    BOOTSTRAP_SESSION_ROWS="${rows}"
    BOOTSTRAP_SESSION_PROJECT_KEY="${pkey}"
    rm -f -- "${staged}" 2>/dev/null || true
    return 0
  fi

  if [[ -n "${OMC_TEST_BOOTSTRAP_STAGE_READY_FILE:-}" ]]; then
    : >"${OMC_TEST_BOOTSTRAP_STAGE_READY_FILE}"
    while [[ -n "${OMC_TEST_BOOTSTRAP_STAGE_RELEASE_FILE:-}" \
        && ! -e "${OMC_TEST_BOOTSTRAP_STAGE_RELEASE_FILE}" ]]; do
      sleep 0.01
    done
  fi

  BOOTSTRAP_PUBLISH_RESULT=""
  with_cross_session_log_lock "${DST_FILE}" _bootstrap_publish_locked \
    "${staged}" "${stamp}" "${source}" "${source_id}" "${source_digest}" "${force}" \
    || return 1
  BOOTSTRAP_SESSION_RESULT="${BOOTSTRAP_PUBLISH_RESULT}"
  BOOTSTRAP_SESSION_ROWS="${rows}"
  rm -f -- "${staged}" 2>/dev/null || true
}

total_rows=0
total_files=0
skipped_stamped=0
skipped_fixture=0
skipped_watchdog=0

_bootstrap_run_locked() {
  local manifest_size="" manifest_count="" source="" sid_dir="" sid="" stamp=""
  if [[ "${OMC_TEST_BOOTSTRAP_FIND_FAILURE:-0}" == "1" ]] \
      || ! find "${STATE_ROOT}" -mindepth 2 -maxdepth 2 -type f \
        -name 'gate_events.jsonl' -size +0 -print0 >"${MANIFEST}"; then
    printf 'error: failed to enumerate gate-event sources\n' >&2
    return 1
  fi
  [[ "$(_sweep_file_identity "${STATE_ROOT}" 2>/dev/null || true)" == "${STATE_ROOT_ID}" ]] \
    || return 1
  manifest_size="$(_sweep_file_size "${MANIFEST}")" || return 1
  (( manifest_size <= MAX_MANIFEST_BYTES )) || {
    printf 'error: gate-event source manifest exceeds %d bytes\n' "${MAX_MANIFEST_BYTES}" >&2
    return 1
  }
  manifest_count="$(tr -cd '\000' <"${MANIFEST}" | wc -c | tr -d '[:space:]')"
  [[ "${manifest_count}" =~ ^[0-9]+$ ]] || return 1
  (( manifest_count <= MAX_MANIFEST_ENTRIES )) || {
    printf 'error: gate-event source manifest exceeds %d entries\n' "${MAX_MANIFEST_ENTRIES}" >&2
    return 1
  }

  while IFS= read -r -d '' source; do
    sid_dir="$(dirname "${source}")"
    sid="$(basename "${sid_dir}")"
    if [[ "${sid}" == "_watchdog" ]]; then
      skipped_watchdog=$((skipped_watchdog + 1))
      continue
    fi
    if [[ ! "${sid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      skipped_fixture=$((skipped_fixture + 1))
      [[ "${dry_run}" -ne 1 ]] || printf '  skip-fixture  %s (non-UUID shape)\n' "${sid}"
      continue
    fi
    stamp="${sid_dir}/${STAMP_NAME}"
    BOOTSTRAP_SESSION_RESULT=""
    if ! _with_lockdir "${sid_dir}/.state.lock" \
        "bootstrap-gate-events(${sid})" _bootstrap_process_session_locked \
        "${source}" "${sid}" "${sid_dir}" "${stamp}"; then
      printf 'error: locked gate-event source/publication failed for %s; retry is safe\n' \
        "${sid}" >&2
      return 1
    fi
    if [[ "${BOOTSTRAP_SESSION_RESULT}" == "already-stamped" ]]; then
      skipped_stamped=$((skipped_stamped + 1))
      if [[ "${dry_run}" -eq 1 ]]; then
        printf '  skip-stamped  %s (already aggregated; --force to override)\n' "${sid}"
      fi
      continue
    fi
    if [[ "${BOOTSTRAP_SESSION_RESULT}" == "preview" ]]; then
      total_files=$((total_files + 1))
      total_rows=$((total_rows + BOOTSTRAP_SESSION_ROWS))
      printf '  would-process %s source rows from %s (project_key=%s)\n' \
        "${BOOTSTRAP_SESSION_ROWS}" "${sid}" \
        "${BOOTSTRAP_SESSION_PROJECT_KEY:-<empty>}"
      continue
    fi
    [[ "${BOOTSTRAP_SESSION_RESULT}" == "published" ]] || return 1
    total_files=$((total_files + 1))
    total_rows=$((total_rows + BOOTSTRAP_SESSION_ROWS))
  done <"${MANIFEST}"
}

if ! _with_lockdir "${STATE_ROOT}/.sweep.lock" \
    "bootstrap-gate-events-sweep" _bootstrap_run_locked; then
  printf 'error: bootstrap transaction failed\n' >&2
  exit 1
fi

if [[ "${dry_run}" -eq 1 ]]; then
  printf '\n[dry-run] %d sessions, %d total rows would be aggregated.\n' \
    "${total_files}" "${total_rows}"
  printf '[dry-run] Skipped: %d stamped, %d fixture, %d _watchdog\n' \
    "${skipped_stamped}" "${skipped_fixture}" "${skipped_watchdog}"
  printf '[dry-run] Destination: %s\n' "${DST_FILE}"
  exit 0
fi

dst_rows=0
if [[ -e "${DST_FILE}" || -L "${DST_FILE}" ]]; then
  if ! _bootstrap_safe_owned_regular "${DST_FILE}" \
      || ! _sweep_jsonl_is_bounded_objects \
        "${DST_FILE}" "${MAX_DESTINATION_BYTES}"; then
      printf 'error: destination failed post-publication validation: %s\n' "${DST_FILE}" >&2
      exit 1
  fi
  dst_rows="$(wc -l <"${DST_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi
printf '\nAggregated %d sessions / %d source rows.\n' "${total_files}" "${total_rows}"
printf 'Skipped: %d stamped, %d fixture, %d _watchdog\n' \
  "${skipped_stamped}" "${skipped_fixture}" "${skipped_watchdog}"
printf 'Destination: %s\n' "${DST_FILE}"
printf 'Total rows in destination: %d\n' "${dst_rows}"
