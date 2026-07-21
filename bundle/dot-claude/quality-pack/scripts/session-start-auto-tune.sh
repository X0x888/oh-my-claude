#!/usr/bin/env bash
#
# SessionStart auto-tune: the harness observes -> recommends -> applies.
#
# v1.48-pre. `/ulw-report`'s Headline heuristics have long computed a
# directional signal ("Objective-contract block reprompt-rate 63% ...
# Raise objective_contract_min_files ... if it over-fires on your
# prompts") and then stopped — the user still has to read the report,
# decide, and hand-edit oh-my-claude.conf. This hook closes that one
# case end to end, opt-in: when `auto_tune=on`, it reuses show-report.sh's
# objective-contract reprompt-rate arithmetic and thresholds over the same
# global-plus-live evidence view exposed by `/ulw-report --sweep` (see
# "Evidence rule" below) to decide whether the gate looks like it is
# over-firing, and if the evidence is strong enough, nudges
# `objective_contract_min_files` up by one step itself.
#
# This is the harness's first self-modifying case, so it is
# deliberately narrow and conservative:
#   - ONE tuning case (objective_contract_min_files). Not a generic
#     tuning engine.
#   - Mechanical evidence only — no LLM judgment call, no reasoning
#     about whether the user "really" wants this; the rule is a fixed
#     arithmetic threshold over gate_events.jsonl, identical to what
#     show-report.sh already surfaces as a suggestion.
#   - A materially higher confidence bar than the suggestion it is
#     based on: show-report.sh mentions the signal at >=3 blocks and
#     calls it "calibrated correctly" at >=5; this hook requires >=10
#     qualifying blocks in the SAME 7-day window it re-checks on
#     (chosen to match both show-report.sh's own default `week` mode
#     and this hook's own cadence — a narrower, more conservative
#     window than `month`/`all`, so a thin recent sample can't drive a
#     conf write; a determined heavy /ulw user who is genuinely
#     hitting this gate will clear 10 in a week, a light user simply
#     stays a no-op, which is the right failure direction for a
#     mechanism that writes global config).
#   - At most one step per run, clamped to [2,12], and only when the
#     CURRENT value is already inside that managed range — a value of
#     0 (the documented "disable the volume arm" sentinel) or anything
#     above 12 is treated as an explicit user choice this hook does
#     not override.
#   - At most once per 7 days regardless of outcome (state file), so
#     the evidence read + potential conf write only ever happens once
#     a week, not once a session.
#   - Reuses the EXISTING atomic conf-write path
#     (`omc-config.sh set user <k=v>` -> `write_conf_atomic`) instead
#     of a second hand-rolled tmp+mv — same validation, same
#     byte-for-byte preservation of every other conf line.
#
# Evidence rule (mirrors `/ulw-report --sweep week`; grep show-report.sh for
# `objective_contract` to see the arithmetic this hook must stay aligned with):
#   eligibility   = producer-issued event_id is valid and unique; copied resume
#                   rows sharing an ID count once, conflicting reuse rejects the
#                   snapshot, and legacy ID-less rows remain report-only
#   oc_blocks     = global + eligible live gate-event rows where
#                   gate=="objective-contract"
#                   and event=="block", ts within the last 7 days
#   oc_reprompts  = same window, event=="post-block-reprompt"
#   oc_pct        = oc_reprompts * 100 / oc_blocks (clamped to 100 when
#                   reprompts > blocks, i.e. the cross-window pairing
#                   case show-report.sh also clamps)
#   Requires oc_blocks >= 10. When oc_pct >= 50 (show-report.sh's own
#   "over-firing" bar), raise objective_contract_min_files by 1 step.
#   Anything else is a no-op (insufficient signal, or the rate is
#   below the over-firing bar) — show-report.sh's calibrated-correct
#   branch says "no action needed", not "consider lowering", so this
#   hook has no lower-the-threshold case; inventing one would not be
#   reusing existing logic/thresholds, it would be a new rule.
#
# SECURITY: `auto_tune` is deny-listed at project-conf scope (see
# common.sh `_parse_conf_file`) — a hostile repo flipping it on via its
# own `.claude/oh-my-claude.conf` could otherwise rewrite the user's
# GLOBAL `~/.claude/oh-my-claude.conf` gate thresholds the moment the
# user `cd`s in, an even larger blast radius than the other deny-listed
# flags (this one is not scoped to the repo at all — it reaches into
# every future project). Only user-level conf or `OMC_AUTO_TUNE=on`
# can enable it.
#
# Disable via `auto_tune=off` (default) in the conf or
# `OMC_AUTO_TUNE=off` env.
#
# Idempotency: per-session `auto_tune_checked` state key, the cross-session
# 7-day state file, AND the shared `~/.claude/.install.lock` guard
# re-evaluation. The operation lock spans cadence/evidence reads, the nested
# omc-config write, audit publication, and cadence stamping, so two SessionStart
# processes cannot both act on one stale threshold. The per-session flag still
# avoids redundant lock traffic from matcher fan-out for one logical start.

set -euo pipefail

# shellcheck source=../../skills/autowork/scripts/common.sh
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${HOME}/.claude/skills/autowork/scripts/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
HOOK_JSON="$(_omc_read_hook_stdin)"

AUTO_TUNE_OPERATION_LOCK_DIR="${HOME}/.claude/.install.lock"
AUTO_TUNE_OPERATION_LOCK_HELD=0
AUTO_TUNE_OPERATION_LOCK_BORROWED=0
AUTO_TUNE_OPERATION_LOCK_TOKEN=""
AUTO_TUNE_OPERATION_LOCK_ID=""
AUTO_TUNE_OPERATION_LOCK_AUTH_PID=""
AUTO_TUNE_OPERATION_LOCK_AUTH_TOKEN=""
AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH=""
AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN=""
AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID=""
AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER="${AUTO_TUNE_OPERATION_LOCK_DIR}/owner-released"

# common.sh's state-I/O module already provides the bounded raw-byte validator
# used for lock authority. Keep a local name so every copied operation-lock
# read is visibly routed through the same canonical one-line boundary.
auto_tune_read_canonical_lock_line() {
  _omc_read_canonical_metadata_line "${1:-}" "${2:-512}"
}

auto_tune_operation_lock_release_marker_matches() {
  local marker_path="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" line=""
  [[ -n "${marker_path}" && -n "${lock_id}" && -n "${owner_pid}" \
      && -n "${owner_token}" && -f "${marker_path}" \
      && ! -L "${marker_path}" \
      && "$(auto_tune_file_mode "${marker_path}" 2>/dev/null || true)" \
        == "600" ]] || return 1
  line="$(auto_tune_read_canonical_lock_line "${marker_path}" 1024)" \
    || return 1
  [[ "${line}" == $'v1\t'"${lock_id}"$'\t'"${owner_pid}"$'\t'"${owner_token}" ]]
}

auto_tune_operation_lock_generation_is_current() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  [[ "${lock_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${owner_pid}" =~ ^[1-9][0-9]{0,19}$ \
      && -n "${owner_token}" && "${owner_token}" != *[[:cntrl:]]* \
      && -d "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
      && "$(auto_tune_file_identity "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
        2>/dev/null || true)" == "${lock_id}" \
      && -f "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" \
      && -f "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" \
      && "$(auto_tune_read_canonical_lock_line \
        "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${owner_pid}" \
      && "$(auto_tune_read_canonical_lock_line \
        "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" 512 \
        2>/dev/null || true)" \
        == "${owner_token}" ]]
}

auto_tune_publish_operation_lock_release_marker() {
  auto_tune_operation_lock_generation_is_current \
    "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
    "${AUTO_TUNE_OPERATION_LOCK_TOKEN}" || return 1
  if [[ -e "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" ]]; then
    auto_tune_operation_lock_release_marker_matches \
      "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
      "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
      "${AUTO_TUNE_OPERATION_LOCK_TOKEN}"
    return
  fi
  if ! (umask 077; set -o noclobber; printf 'v1\t%s\t%s\t%s\n' \
      "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
      "${AUTO_TUNE_OPERATION_LOCK_TOKEN}" \
      > "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}") 2>/dev/null; then
    return 1
  fi
  chmod 600 "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" || return 1
  auto_tune_operation_lock_generation_is_current \
    "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
    "${AUTO_TUNE_OPERATION_LOCK_TOKEN}" \
    && auto_tune_operation_lock_release_marker_matches \
      "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
      "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
      "${AUTO_TUNE_OPERATION_LOCK_TOKEN}"
}

auto_tune_released_operation_lock_is_exact() (
  local root="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" pid_id="${5:-}" token_id="${6:-}"
  local marker_id="${7:-}" entry=""
  local -a entries=()
  [[ -d "${root}" && ! -L "${root}" \
      && "$(auto_tune_file_identity "${root}" 2>/dev/null || true)" \
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
      && "$(auto_tune_file_identity "${root}/pid" \
        2>/dev/null || true)" == "${pid_id}" \
      && "$(auto_tune_read_canonical_lock_line \
        "${root}/pid" 32 2>/dev/null || true)" == "${owner_pid}" \
      && -f "${root}/token" && ! -L "${root}/token" \
      && "$(auto_tune_file_identity "${root}/token" \
        2>/dev/null || true)" == "${token_id}" \
      && "$(auto_tune_read_canonical_lock_line \
        "${root}/token" 512 2>/dev/null || true)" == "${owner_token}" \
      && -f "${root}/owner-released" \
      && ! -L "${root}/owner-released" \
      && "$(auto_tune_file_identity "${root}/owner-released" \
        2>/dev/null || true)" == "${marker_id}" ]] || return 1
  auto_tune_operation_lock_release_marker_matches \
    "${root}/owner-released" "${lock_id}" "${owner_pid}" "${owner_token}"
)

auto_tune_reap_released_operation_lock() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  local participant="" pid_id="" token_id="" marker_id=""
  local retired_root="" retired_root_id="" retired_lock=""
  [[ -e "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" ]] || return 0
  auto_tune_operation_lock_generation_is_current \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  auto_tune_operation_lock_release_marker_matches \
    "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  for participant in "${AUTO_TUNE_OPERATION_LOCK_DIR}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 0
  done
  pid_id="$(auto_tune_file_identity \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid")" || return 1
  token_id="$(auto_tune_file_identity \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}/token")" || return 1
  marker_id="$(auto_tune_file_identity \
    "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}")" || return 1
  auto_tune_released_operation_lock_is_exact \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}" "${lock_id}" "${owner_pid}" \
    "${owner_token}" "${pid_id}" "${token_id}" "${marker_id}" \
    || return 1

  retired_root="$(mktemp -d \
    "${HOME}/.claude/.install-lock-retired.XXXXXX")" || return 1
  if ! chmod 700 "${retired_root}"; then
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  retired_root_id="$(auto_tune_file_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  if ! auto_tune_released_operation_lock_is_exact \
      "${AUTO_TUNE_OPERATION_LOCK_DIR}" "${lock_id}" "${owner_pid}" \
      "${owner_token}" "${pid_id}" "${token_id}" "${marker_id}"; then
    [[ "$(auto_tune_file_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  if ! command mv -- "${AUTO_TUNE_OPERATION_LOCK_DIR}" "${retired_lock}"; then
    [[ "$(auto_tune_file_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  if [[ -n "${OMC_TEST_AUTO_TUNE_LOCK_RETIRED_READY_FILE:-}" ]]; then
    : > "${OMC_TEST_AUTO_TUNE_LOCK_RETIRED_READY_FILE}" || return 1
    while [[ -n "${OMC_TEST_AUTO_TUNE_LOCK_RETIRED_RELEASE_FILE:-}" \
        && ! -e "${OMC_TEST_AUTO_TUNE_LOCK_RETIRED_RELEASE_FILE}" ]]; do
      sleep 0.01
    done
  fi
  # A contender may create the next public generation immediately after the
  # rename. Cleanup is bound only to the retired inode from here onward.
  [[ "$(auto_tune_file_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  auto_tune_released_operation_lock_is_exact "${retired_lock}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" \
    "${pid_id}" "${token_id}" "${marker_id}" || return 1
  [[ "$(auto_tune_file_identity "${retired_lock}/pid" \
      2>/dev/null || true)" == "${pid_id}" ]] \
    && rm -f -- "${retired_lock}/pid" || return 1
  [[ "$(auto_tune_file_identity "${retired_lock}/token" \
      2>/dev/null || true)" == "${token_id}" ]] \
    && rm -f -- "${retired_lock}/token" || return 1
  [[ "$(auto_tune_file_identity "${retired_lock}/owner-released" \
      2>/dev/null || true)" == "${marker_id}" ]] \
    && auto_tune_operation_lock_release_marker_matches \
      "${retired_lock}/owner-released" "${lock_id}" \
      "${owner_pid}" "${owner_token}" \
    && rm -f -- "${retired_lock}/owner-released" || return 1
  rmdir "${retired_lock}" || return 1
  [[ "$(auto_tune_file_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  rmdir "${retired_root}"
}

auto_tune_reap_stranded_released_operation_lock() {
  local lock_id="" owner_pid="" owner_token="" source_id=""
  [[ -d "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
      && -f "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" \
      && -f "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" \
      && -f "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" ]] || return 1
  lock_id="$(auto_tune_file_identity \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}")" || return 1
  owner_pid="$(auto_tune_read_canonical_lock_line \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" 32)" || return 1
  owner_token="$(auto_tune_read_canonical_lock_line \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" 512)" || return 1
  auto_tune_operation_lock_generation_is_current "${lock_id}" \
    "${owner_pid}" "${owner_token}" || return 1
  auto_tune_operation_lock_release_marker_matches \
    "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" || return 1
  auto_tune_reap_released_operation_lock "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  source_id="$(auto_tune_file_identity "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
    2>/dev/null || true)"
  [[ "${source_id}" != "${lock_id}" ]]
}

auto_tune_remove_exact_participant() {
  [[ -n "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
      && -n "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID}" \
      && -f "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
      && "$(auto_tune_file_identity \
        "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true)" \
        == "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID}" \
      && "$(auto_tune_read_canonical_lock_line \
        "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" 512 \
        2>/dev/null || true)" \
        == "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN}" ]] || return 1
  rm -f -- "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}"
}

acquire_auto_tune_operation_lock() {
  mkdir -p "${HOME}/.claude" || return 1
  local attempt=0 owner_pid="" attempt_limit=20
  local parent_pid="${OMC_PARENT_OPERATION_LOCK_PID:-}"
  local parent_token="${OMC_PARENT_OPERATION_LOCK_TOKEN:-}"
  local parent_lock_id="${OMC_PARENT_OPERATION_LOCK_ID:-}"
  if [[ "${parent_pid}" =~ ^[1-9][0-9]{0,19}$ \
      && -n "${parent_token}" && "${parent_token}" != *[[:cntrl:]]* \
      && ( -z "${parent_lock_id}" \
        || "${parent_lock_id}" =~ ^[0-9]+:[0-9]+$ ) \
      && -d "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
      && ! -L "${AUTO_TUNE_OPERATION_LOCK_DIR}" \
      && "$(auto_tune_read_canonical_lock_line \
        "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)" \
        == "${parent_pid}" \
      && "$(auto_tune_read_canonical_lock_line \
        "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" 512 \
        2>/dev/null || true)" \
        == "${parent_token}" ]]; then
    AUTO_TUNE_OPERATION_LOCK_ID="$(auto_tune_file_identity \
      "${AUTO_TUNE_OPERATION_LOCK_DIR}")" || return 1
    if [[ -n "${parent_lock_id}" \
        && "${AUTO_TUNE_OPERATION_LOCK_ID}" != "${parent_lock_id}" ]]; then
      AUTO_TUNE_OPERATION_LOCK_ID=""
      return 1
    fi
    if [[ -e "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" ]]; then
      auto_tune_reap_released_operation_lock \
        "${AUTO_TUNE_OPERATION_LOCK_ID}" "${parent_pid}" \
        "${parent_token}" || true
      AUTO_TUNE_OPERATION_LOCK_ID=""
      return 1
    fi
    AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH="${AUTO_TUNE_OPERATION_LOCK_DIR}/participant.$$"
    AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
    [[ ! -e "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
        && ! -L "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" ]] || return 1
    if ! (umask 077; set -o noclobber; \
        printf '%s\n' "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN}" \
          > "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}") 2>/dev/null \
        || ! chmod 600 "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}"; then
      rm -f -- "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH=""
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    fi
    AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID="$(auto_tune_file_identity \
      "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}")" || {
      rm -f -- "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH=""
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    }
    if [[ -e "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${AUTO_TUNE_OPERATION_LOCK_RELEASE_MARKER}" ]] \
        || [[ "$(auto_tune_read_canonical_lock_line \
          "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" 32 \
          2>/dev/null || true)" != "${parent_pid}" ]] \
        || [[ "$(auto_tune_read_canonical_lock_line \
          "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" 512 \
          2>/dev/null || true)" != "${parent_token}" ]] \
        || [[ "$(auto_tune_file_identity \
          "${AUTO_TUNE_OPERATION_LOCK_DIR}" 2>/dev/null || true)" \
          != "${AUTO_TUNE_OPERATION_LOCK_ID}" ]] \
        || [[ "$(auto_tune_file_identity \
          "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" \
          2>/dev/null || true)" \
          != "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID}" ]] \
        || [[ "$(auto_tune_read_canonical_lock_line \
          "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH}" 512 \
          2>/dev/null || true)" \
          != "${AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN}" ]]; then
      auto_tune_remove_exact_participant || true
      auto_tune_reap_released_operation_lock \
        "${AUTO_TUNE_OPERATION_LOCK_ID}" "${parent_pid}" \
        "${parent_token}" || true
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH=""
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN=""
      AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID=""
      return 1
    fi
    AUTO_TUNE_OPERATION_LOCK_BORROWED=1
    AUTO_TUNE_OPERATION_LOCK_AUTH_PID="${parent_pid}"
    AUTO_TUNE_OPERATION_LOCK_AUTH_TOKEN="${parent_token}"
    export OMC_PARENT_OPERATION_LOCK_PID="${parent_pid}"
    export OMC_PARENT_OPERATION_LOCK_TOKEN="${parent_token}"
    export OMC_PARENT_OPERATION_LOCK_ID="${AUTO_TUNE_OPERATION_LOCK_ID}"
    return 0
  fi
  if [[ -n "${OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS:-}" ]]; then
    _omc_canonical_uint_in_range \
      "${OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS}" 1 6000 || return 1
    attempt_limit="${OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS}"
  fi
  while ! (umask 077; mkdir "${AUTO_TUNE_OPERATION_LOCK_DIR}") \
      2>/dev/null; do
    if auto_tune_reap_stranded_released_operation_lock; then
      continue
    fi
    attempt=$((attempt + 1))
    owner_pid="$(auto_tune_read_canonical_lock_line \
      "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" 32 2>/dev/null || true)"
    if [[ "${attempt}" -ge "${attempt_limit}" ]]; then
      log_anomaly "session-start-auto-tune" \
        "shared mutation lock busy (pid=${owner_pid:-unknown}); deferred this check"
      return 1
    fi
    sleep 0.25 2>/dev/null || sleep 1
  done
  AUTO_TUNE_OPERATION_LOCK_ID="$(auto_tune_file_identity \
    "${AUTO_TUNE_OPERATION_LOCK_DIR}")" || {
    rmdir "${AUTO_TUNE_OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  }
  if ! chmod 700 "${AUTO_TUNE_OPERATION_LOCK_DIR}" 2>/dev/null; then
    rmdir "${AUTO_TUNE_OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  AUTO_TUNE_OPERATION_LOCK_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
  if ! (umask 077; set -o noclobber; \
      printf '%s\n' "$$" > "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" \
      && printf '%s\n' "${AUTO_TUNE_OPERATION_LOCK_TOKEN}" \
        > "${AUTO_TUNE_OPERATION_LOCK_DIR}/token") 2>/dev/null; then
    rm -f -- "${AUTO_TUNE_OPERATION_LOCK_DIR}/pid" \
      "${AUTO_TUNE_OPERATION_LOCK_DIR}/token" 2>/dev/null || true
    rmdir "${AUTO_TUNE_OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  AUTO_TUNE_OPERATION_LOCK_HELD=1
  AUTO_TUNE_OPERATION_LOCK_AUTH_PID="$$"
  AUTO_TUNE_OPERATION_LOCK_AUTH_TOKEN="${AUTO_TUNE_OPERATION_LOCK_TOKEN}"
  export OMC_PARENT_OPERATION_LOCK_PID="$$"
  export OMC_PARENT_OPERATION_LOCK_TOKEN="${AUTO_TUNE_OPERATION_LOCK_TOKEN}"
  export OMC_PARENT_OPERATION_LOCK_ID="${AUTO_TUNE_OPERATION_LOCK_ID}"
}

release_auto_tune_operation_lock() {
  if [[ "${AUTO_TUNE_OPERATION_LOCK_BORROWED}" -eq 1 ]]; then
    auto_tune_remove_exact_participant || true
    auto_tune_reap_released_operation_lock \
      "${AUTO_TUNE_OPERATION_LOCK_ID}" \
      "${AUTO_TUNE_OPERATION_LOCK_AUTH_PID}" \
      "${AUTO_TUNE_OPERATION_LOCK_AUTH_TOKEN}" || true
    AUTO_TUNE_OPERATION_LOCK_BORROWED=0
    AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_PATH=""
    AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_TOKEN=""
    AUTO_TUNE_OPERATION_LOCK_PARTICIPANT_ID=""
    AUTO_TUNE_OPERATION_LOCK_AUTH_PID=""
    AUTO_TUNE_OPERATION_LOCK_AUTH_TOKEN=""
    AUTO_TUNE_OPERATION_LOCK_ID=""
    return 0
  fi
  [[ "${AUTO_TUNE_OPERATION_LOCK_HELD}" -eq 1 ]] || return 0
  if auto_tune_operation_lock_generation_is_current \
      "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
      "${AUTO_TUNE_OPERATION_LOCK_TOKEN}"; then
    auto_tune_publish_operation_lock_release_marker \
      && auto_tune_reap_released_operation_lock \
        "${AUTO_TUNE_OPERATION_LOCK_ID}" "$$" \
        "${AUTO_TUNE_OPERATION_LOCK_TOKEN}" || true
  fi
  AUTO_TUNE_OPERATION_LOCK_HELD=0
  AUTO_TUNE_OPERATION_LOCK_AUTH_PID=""
  AUTO_TUNE_OPERATION_LOCK_AUTH_TOKEN=""
  AUTO_TUNE_OPERATION_LOCK_ID=""
}

auto_tune_safe_regular_leaf_or_absent() {
  local path="${1:-}"
  [[ ! -L "${path}" ]] || return 1
  [[ ! -e "${path}" || -f "${path}" ]]
}

auto_tune_file_identity() {
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

auto_tune_file_owner() {
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

auto_tune_file_link_count() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%l' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%h' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

auto_tune_file_mode() {
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

auto_tune_file_size() {
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

auto_tune_file_digest() {
  local path="${1:-}" sum="" size=""
  read -r sum size _ < <(cksum < "${path}") || return 1
  [[ "${sum}" =~ ^[0-9]+$ && "${size}" =~ ^[0-9]+$ ]] || return 1
  printf 'cksum:%s %s' "${sum}" "${size}"
}

auto_tune_digest_is_valid() {
  [[ "${1:-}" =~ ^cksum:[0-9]+[[:space:]][0-9]+$ ]]
}

auto_tune_owned_single_regular_file() {
  local path="${1:-}" uid=""
  uid="$(id -u)" || return 1
  [[ -f "${path}" && ! -L "${path}" \
      && "$(auto_tune_file_owner "${path}" 2>/dev/null || true)" \
        == "${uid}" \
      && "$(auto_tune_file_link_count "${path}" 2>/dev/null || true)" \
      == "1" ]]
}

auto_tune_owned_regular_file_with_links() {
  local path="${1:-}" expected_links="${2:-1}" uid=""
  [[ "${expected_links}" == "1" || "${expected_links}" == "2" ]] \
    || return 1
  uid="$(id -u)" || return 1
  [[ -f "${path}" && ! -L "${path}" \
      && "$(auto_tune_file_owner "${path}" 2>/dev/null || true)" \
        == "${uid}" \
      && "$(auto_tune_file_link_count "${path}" 2>/dev/null || true)" \
        == "${expected_links}" ]]
}

# Capture one bounded, owner-controlled leaf before parsing it. Path-level
# validation followed by a fresh jq/grep/hash open is not sufficient: the
# public name can be replaced with a FIFO or different regular generation in
# between. common.sh's hard-link-backed reader never opens an unproved public
# special file and corroborates the complete byte stream before returning.
auto_tune_capture_safe_regular_snapshot() {
  local source="${1:-}" snapshot="${2:-}" max_bytes="${3:-}"
  auto_tune_evidence_path_is_safe "${source}" "${max_bytes}" || return 1
  _omc_capture_regular_file_snapshot \
    "${source}" "${snapshot}" "${max_bytes}" || return 1
  auto_tune_evidence_path_is_safe "${source}" "${max_bytes}" || return 1
  _omc_regular_file_snapshot_is_current \
    "${source}" "${snapshot}" "${max_bytes}"
}

auto_tune_safe_regular_snapshot_is_current() {
  local source="${1:-}" snapshot="${2:-}" max_bytes="${3:-}"
  auto_tune_evidence_path_is_safe "${source}" "${max_bytes}" || return 1
  _omc_regular_file_snapshot_is_current \
    "${source}" "${snapshot}" "${max_bytes}" || return 1
  auto_tune_evidence_path_is_safe "${source}" "${max_bytes}"
}

# Pending receipts authorize recovery side effects, so every reader and
# remover is bound to one exact private generation. The operation lock
# serializes cooperating OMC writers; these identity/digest checks additionally
# fail closed if an out-of-band same-user process swaps the leaf while a hook is
# running. Every live-path read is independently capped at max+1 bytes before a
# digest is calculated. The Bash-native reader preserves the atomic writer's
# canonical trailing newline; byte-count and digest equality reject truncation,
# embedded NULs, and ambiguous trailing whitespace.
AUTO_TUNE_PENDING_CAPTURE_ID=""
AUTO_TUNE_PENDING_CAPTURE_DIGEST=""
AUTO_TUNE_PENDING_CAPTURE_MODE=""
AUTO_TUNE_PENDING_CAPTURE_SIZE=""
AUTO_TUNE_PENDING_CAPTURE_JSON=""
AUTO_TUNE_PENDING_PROBE_ID=""
AUTO_TUNE_PENDING_PROBE_DIGEST=""
AUTO_TUNE_PENDING_PROBE_MODE=""
AUTO_TUNE_PENDING_PROBE_SIZE=""
AUTO_TUNE_PENDING_PROBE_JSON=""

auto_tune_clear_pending_capture() {
  AUTO_TUNE_PENDING_CAPTURE_ID=""
  AUTO_TUNE_PENDING_CAPTURE_DIGEST=""
  AUTO_TUNE_PENDING_CAPTURE_MODE=""
  AUTO_TUNE_PENDING_CAPTURE_SIZE=""
  AUTO_TUNE_PENDING_CAPTURE_JSON=""
}

auto_tune_clear_pending_probe() {
  AUTO_TUNE_PENDING_PROBE_ID=""
  AUTO_TUNE_PENDING_PROBE_DIGEST=""
  AUTO_TUNE_PENDING_PROBE_MODE=""
  AUTO_TUNE_PENDING_PROBE_SIZE=""
  AUTO_TUNE_PENDING_PROBE_JSON=""
}

auto_tune_probe_pending_path() {
  local path="${1:-}"
  local max_bytes="${2:-${AUTO_TUNE_PENDING_MAX_BYTES:-32768}}"
  local expected_links="${3:-1}"
  local captured_id="" captured_mode="" captured_size=""
  local snapshot="" snapshot_sum="" snapshot_size=""
  local confirm="" confirm_sum="" confirm_size="" read_limit=0
  auto_tune_clear_pending_probe
  [[ -n "${path}" ]] || return 1
  _omc_canonical_uint_in_range "${max_bytes}" 1 2147483646 || return 1
  [[ "${expected_links}" == "1" || "${expected_links}" == "2" ]] \
    || return 1
  auto_tune_control_root_is_current || return 1
  [[ "${path%/*}" == "${QP_ROOT:-}" ]] || return 1
  auto_tune_owned_regular_file_with_links "${path}" "${expected_links}" \
    || return 1
  captured_id="$(auto_tune_file_identity "${path}")" || return 1
  captured_mode="$(auto_tune_file_mode "${path}")" || return 1
  captured_size="$(auto_tune_file_size "${path}")" || return 1
  [[ "${captured_mode}" == "600" ]] || return 1
  _omc_canonical_uint_in_range "${captured_size}" 1 \
    "${max_bytes}" || return 1

  # `-d ''` makes newline ordinary data; stock macOS Bash lacks `read -N`, so
  # combine it with portable Bash `-n` instead. A replacement between stat and
  # open can therefore contribute at most max+1 bytes to either snapshot.
  read_limit=$((max_bytes + 1))
  IFS= LC_ALL=C read -r -d '' -n "${read_limit}" snapshot \
    <"${path}" || true
  read -r snapshot_sum snapshot_size _ < <(LC_ALL=C \
    printf '%s' "${snapshot}" \
    | cksum) || return 1
  [[ "${snapshot_sum}" =~ ^[0-9]+$ && "${snapshot_size}" =~ ^[0-9]+$ \
      && "${snapshot_size}" == "${captured_size}" ]] || return 1
  auto_tune_control_root_is_current || return 1
  auto_tune_owned_regular_file_with_links "${path}" "${expected_links}" \
    || return 1
  [[ "$(auto_tune_file_identity "${path}" \
      2>/dev/null || true)" == "${captured_id}" \
      && "$(auto_tune_file_mode "${path}" \
        2>/dev/null || true)" == "${captured_mode}" \
      && "$(auto_tune_file_size "${path}" \
        2>/dev/null || true)" == "${captured_size}" ]] || return 1

  # A second independently bounded read closes the ordinary equal-size
  # in-place rewrite window without ever streaming an unchecked pathname.
  IFS= LC_ALL=C read -r -d '' -n "${read_limit}" confirm \
    <"${path}" || true
  read -r confirm_sum confirm_size _ < <(LC_ALL=C \
    printf '%s' "${confirm}" \
    | cksum) || return 1
  [[ "${confirm_sum}" =~ ^[0-9]+$ && "${confirm_size}" =~ ^[0-9]+$ \
      && "${confirm_size}" == "${captured_size}" \
      && "${confirm_sum}" == "${snapshot_sum}" ]] || return 1
  auto_tune_control_root_is_current || return 1
  auto_tune_owned_regular_file_with_links "${path}" "${expected_links}" \
    || return 1
  [[ "$(auto_tune_file_identity "${path}" \
      2>/dev/null || true)" == "${captured_id}" \
      && "$(auto_tune_file_mode "${path}" \
        2>/dev/null || true)" == "${captured_mode}" \
      && "$(auto_tune_file_size "${path}" \
        2>/dev/null || true)" == "${captured_size}" ]] || return 1

  AUTO_TUNE_PENDING_PROBE_ID="${captured_id}"
  AUTO_TUNE_PENDING_PROBE_DIGEST="cksum:${snapshot_sum} ${snapshot_size}"
  AUTO_TUNE_PENDING_PROBE_MODE="${captured_mode}"
  AUTO_TUNE_PENDING_PROBE_SIZE="${captured_size}"
  AUTO_TUNE_PENDING_PROBE_JSON="${snapshot}"
}

auto_tune_pending_receipt_structure_is_valid() {
  local receipt_json="${1:-}"
  [[ "$(printf '%s' "${receipt_json}" \
      | jq -s 'length' 2>/dev/null || true)" == "1" ]] || return 1
  jq -e '
    type == "object" and
    ((keys | sort) == ["decision_id","entry_digest","entry_mode",
      "entry_state","evidence","final_digest","final_mode","host",
      "new","oc_blocks","oc_pct","oc_reprompts","old","phase",
      "reason","ts","version"]) and
    .version == 1 and
    (.phase == "prepared" or .phase == "write-observed") and
    (.decision_id | type == "string" and length > 0 and length <= 160 and
      test("^auto-tune-[0-9]+-[0-9]+-[0-9]+-[0-9]+$")) and
    (.ts | type == "number" and floor == . and . >= 0 and . <= 9999999999) and
    (.old | type == "number" and floor == . and . >= 2 and . <= 11) and
    (.new | type == "number" and floor == . and . >= 3 and . <= 12) and
    (.new == (.old + 1)) and
    (.reason | type == "string" and length > 0 and length <= 2048 and
      (test("[\u0000-\u001f\u007f]") | not)) and
    (.evidence | type == "string" and length > 0 and length <= 1024 and
      (test("[\u0000-\u001f\u007f]") | not)) and
    (.host | type == "string" and length > 0 and length <= 512 and
      test("^[A-Za-z0-9._-]+$")) and
    (.oc_pct | type == "number" and floor == . and . >= 0 and . <= 100) and
    (.oc_pct >= 50) and
    (.oc_blocks | type == "number" and floor == . and . >= 10 and
      . <= 2147483647) and
    (.oc_reprompts | type == "number" and floor == . and . >= 0 and
      . <= 2147483647) and
    (.oc_pct == (if .oc_reprompts > .oc_blocks then 100
      else ((.oc_reprompts * 100 / .oc_blocks) | floor) end)) and
    (.entry_state == "present" or .entry_state == "absent") and
    (if .entry_state == "present" then
      (.entry_digest | type == "string" and
        test("^cksum:[0-9]+ [0-9]+$")) and
      (.entry_mode | type == "string" and test("^[0-7]{3,4}$"))
     else .entry_digest == "none" and .entry_mode == "none" end) and
    (.final_digest | type == "string" and
      test("^cksum:[0-9]+ [0-9]+$")) and
    (.final_mode | type == "string" and test("^[0-7]{3,4}$"))
  ' <<<"${receipt_json}" >/dev/null 2>&1
}

auto_tune_capture_pending_generation() {
  auto_tune_clear_pending_capture
  auto_tune_probe_pending_path "${PENDING_FILE}" || return 1
  AUTO_TUNE_PENDING_CAPTURE_ID="${AUTO_TUNE_PENDING_PROBE_ID}"
  AUTO_TUNE_PENDING_CAPTURE_DIGEST="${AUTO_TUNE_PENDING_PROBE_DIGEST}"
  AUTO_TUNE_PENDING_CAPTURE_MODE="${AUTO_TUNE_PENDING_PROBE_MODE}"
  AUTO_TUNE_PENDING_CAPTURE_SIZE="${AUTO_TUNE_PENDING_PROBE_SIZE}"
  AUTO_TUNE_PENDING_CAPTURE_JSON="${AUTO_TUNE_PENDING_PROBE_JSON}"
}

auto_tune_pending_generation_is_current() {
  [[ -n "${AUTO_TUNE_PENDING_CAPTURE_ID:-}" \
      && -n "${AUTO_TUNE_PENDING_CAPTURE_DIGEST:-}" \
      && -n "${AUTO_TUNE_PENDING_CAPTURE_MODE:-}" \
      && -n "${AUTO_TUNE_PENDING_CAPTURE_SIZE:-}" ]] || return 1
  auto_tune_probe_pending_path "${PENDING_FILE}" || return 1
  [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
        == "${AUTO_TUNE_PENDING_CAPTURE_ID}" \
      && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" \
        == "${AUTO_TUNE_PENDING_CAPTURE_DIGEST}" \
      && "${AUTO_TUNE_PENDING_PROBE_MODE}" \
        == "${AUTO_TUNE_PENDING_CAPTURE_MODE}" \
      && "${AUTO_TUNE_PENDING_PROBE_SIZE}" \
        == "${AUTO_TUNE_PENDING_CAPTURE_SIZE}" ]]
}

auto_tune_pending_barrier() {
  local ready="${1:-}" release="${2:-}" attempts=0
  [[ -n "${ready}" || -n "${release}" ]] || return 0
  [[ -n "${ready}" && -n "${release}" ]] || return 1
  : >"${ready}" || return 1
  while [[ ! -e "${release}" && "${attempts}" -lt 1000 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [[ -e "${release}" ]]
}

auto_tune_pending_retire_test_barrier() {
  auto_tune_pending_barrier \
    "${OMC_TEST_AUTO_TUNE_PENDING_RETIRE_READY_FILE:-}" \
    "${OMC_TEST_AUTO_TUNE_PENDING_RETIRE_RELEASE_FILE:-}"
}

auto_tune_pending_pre_retire_test_barrier() {
  auto_tune_pending_barrier \
    "${OMC_TEST_AUTO_TUNE_PENDING_PRE_RETIRE_READY_FILE:-}" \
    "${OMC_TEST_AUTO_TUNE_PENDING_PRE_RETIRE_RELEASE_FILE:-}"
}

AUTO_TUNE_PENDING_RETIRE_CLAIM_ID=""
AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST=""
AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE=""
AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE=""
AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID=""
AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST=""
AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE=""
AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE=""
AUTO_TUNE_PENDING_RETIRE_OPERATION=""
AUTO_TUNE_PENDING_RETIRE_PHASE=""
AUTO_TUNE_PENDING_ADVANCE_FINAL_ID=""
AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST=""
AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE=""
AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE=""

auto_tune_clear_pending_retire_claim() {
  AUTO_TUNE_PENDING_RETIRE_CLAIM_ID=""
  AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST=""
  AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE=""
  AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE=""
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID=""
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST=""
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE=""
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE=""
  AUTO_TUNE_PENDING_RETIRE_OPERATION=""
  AUTO_TUNE_PENDING_RETIRE_PHASE=""
  AUTO_TUNE_PENDING_ADVANCE_FINAL_ID=""
  AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST=""
  AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE=""
  AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE=""
}

auto_tune_capture_pending_retire_claim() {
  local claim_json="" expected_id="" expected_digest=""
  local expected_mode="" expected_size="" digest_size=""
  local operation="" transition_phase="" final_id="" final_digest=""
  local final_mode="" final_size="" final_digest_size=""
  auto_tune_clear_pending_retire_claim
  auto_tune_probe_pending_path "${PENDING_RETIRE_CLAIM_FILE}" \
    "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MAX_BYTES:-4096}" || return 1
  claim_json="${AUTO_TUNE_PENDING_PROBE_JSON}"
  [[ "$(printf '%s' "${claim_json}" \
      | jq -s 'length' 2>/dev/null || true)" == "1" ]] || return 1
  jq -e '
    type == "object" and
    (if .version == 1 then
      ((keys | sort) == ["pending_digest","pending_id","pending_mode",
        "pending_size","version"])
     elif .version == 2 then
      ((keys | sort) == ["final_digest","final_id","final_mode",
        "final_size","operation","pending_digest","pending_id",
        "pending_mode","pending_size","transition_phase","version"]) and
      .operation == "advance" and
      (.transition_phase == "claimed" or
        .transition_phase == "staged" or
        .transition_phase == "published") and
      (if .transition_phase == "claimed" then
        .final_id == "none" and .final_digest == "none" and
        .final_mode == "none" and .final_size == 0
       else
        (.final_id | type == "string" and test("^[0-9]+:[0-9]+$")) and
        (.final_digest | type == "string" and
          test("^cksum:[0-9]+ [0-9]+$")) and
        .final_mode == "600" and
        (.final_size | type == "number" and floor == . and
          . >= 1 and . <= 32768)
       end)
     else false end) and
    (.pending_id | type == "string" and test("^[0-9]+:[0-9]+$")) and
    (.pending_digest | type == "string" and
      test("^cksum:[0-9]+ [0-9]+$")) and
    .pending_mode == "600" and
    (.pending_size | type == "number" and floor == . and . >= 1 and
      . <= 32768)
  ' <<<"${claim_json}" >/dev/null 2>&1 || return 1
  IFS=$'\t' read -r operation transition_phase expected_id \
    expected_digest expected_mode expected_size final_id final_digest \
    final_mode final_size < <(jq -r '
      if .version == 1 then
        ["retire", "claimed", .pending_id, .pending_digest,
          .pending_mode, .pending_size, "none", "none", "none", 0]
      else
        [.operation, .transition_phase, .pending_id, .pending_digest,
          .pending_mode, .pending_size, .final_id, .final_digest,
          .final_mode, .final_size]
      end | @tsv
    ' <<<"${claim_json}") || return 1
  _omc_canonical_uint_in_range "${expected_size}" 1 \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" || return 1
  auto_tune_digest_is_valid "${expected_digest}" || return 1
  digest_size="${expected_digest##* }"
  [[ "${digest_size}" == "${expected_size}" ]] || return 1
  if [[ "${transition_phase}" != "claimed" ]]; then
    _omc_canonical_uint_in_range "${final_size}" 1 \
      "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" || return 1
    auto_tune_digest_is_valid "${final_digest}" || return 1
    final_digest_size="${final_digest##* }"
    [[ "${final_digest_size}" == "${final_size}" ]] || return 1
  fi

  AUTO_TUNE_PENDING_RETIRE_CLAIM_ID="${AUTO_TUNE_PENDING_PROBE_ID}"
  AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST="${AUTO_TUNE_PENDING_PROBE_DIGEST}"
  AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE="${AUTO_TUNE_PENDING_PROBE_MODE}"
  AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE="${AUTO_TUNE_PENDING_PROBE_SIZE}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID="${expected_id}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST="${expected_digest}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE="${expected_mode}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE="${expected_size}"
  AUTO_TUNE_PENDING_RETIRE_OPERATION="${operation}"
  AUTO_TUNE_PENDING_RETIRE_PHASE="${transition_phase}"
  AUTO_TUNE_PENDING_ADVANCE_FINAL_ID="${final_id}"
  AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST="${final_digest}"
  AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE="${final_mode}"
  AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE="${final_size}"
}

auto_tune_pending_retire_claim_is_current() {
  [[ -n "${AUTO_TUNE_PENDING_RETIRE_CLAIM_ID:-}" \
      && -n "${AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST:-}" \
      && -n "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE:-}" \
      && -n "${AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE:-}" ]] || return 1
  auto_tune_probe_pending_path "${PENDING_RETIRE_CLAIM_FILE}" \
    "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MAX_BYTES:-4096}" || return 1
  [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
        == "${AUTO_TUNE_PENDING_RETIRE_CLAIM_ID}" \
      && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" \
        == "${AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST}" \
      && "${AUTO_TUNE_PENDING_PROBE_MODE}" \
        == "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE}" \
      && "${AUTO_TUNE_PENDING_PROBE_SIZE}" \
        == "${AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE}" ]]
}

auto_tune_remove_pending_retire_claim() {
  auto_tune_pending_retire_claim_is_current || return 1
  rm -f -- "${PENDING_RETIRE_CLAIM_FILE}" || return 1
  [[ ! -e "${PENDING_RETIRE_CLAIM_FILE}" \
      && ! -L "${PENDING_RETIRE_CLAIM_FILE}" ]] || return 1
  auto_tune_clear_pending_retire_claim
}

auto_tune_build_pending_retire_claim_json() {
  local operation="${1:-retire}" transition_phase="${2:-claimed}"
  local final_id="${3:-none}" final_digest="${4:-none}"
  local final_mode="${5:-none}" final_size="${6:-0}"
  [[ "${operation}" == "retire" || "${operation}" == "advance" ]] \
    || return 1
  if [[ "${operation}" == "retire" ]]; then
    [[ "${transition_phase}" == "claimed" && "${final_id}" == "none" \
        && "${final_digest}" == "none" && "${final_mode}" == "none" \
        && "${final_size}" == "0" ]] || return 1
    jq -nc --argjson version 1 \
      --arg pending_id "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID}" \
      --arg pending_digest "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST}" \
      --arg pending_mode "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE}" \
      --argjson pending_size "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE}" \
      '{version:$version,pending_id:$pending_id,
        pending_digest:$pending_digest,pending_mode:$pending_mode,
        pending_size:$pending_size}'
    return
  fi
  [[ "${transition_phase}" == "claimed" \
      || "${transition_phase}" == "staged" \
      || "${transition_phase}" == "published" ]] || return 1
  jq -nc --argjson version 2 --arg operation "${operation}" \
    --arg transition_phase "${transition_phase}" \
    --arg pending_id "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID}" \
    --arg pending_digest "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST}" \
    --arg pending_mode "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE}" \
    --argjson pending_size "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE}" \
    --arg final_id "${final_id}" --arg final_digest "${final_digest}" \
    --arg final_mode "${final_mode}" --argjson final_size "${final_size}" \
    '{version:$version,operation:$operation,
      transition_phase:$transition_phase,pending_id:$pending_id,
      pending_digest:$pending_digest,pending_mode:$pending_mode,
      pending_size:$pending_size,final_id:$final_id,
      final_digest:$final_digest,final_mode:$final_mode,
      final_size:$final_size}'
}

auto_tune_publish_pending_retire_claim() {
  local operation="${1:-retire}"
  local claim_json="" parent="" tmp="" tmp_id="" tmp_mode=""
  local tmp_size="" tmp_digest=""
  [[ -n "${AUTO_TUNE_PENDING_CAPTURE_ID:-}" \
      && -n "${AUTO_TUNE_PENDING_CAPTURE_DIGEST:-}" \
      && "${AUTO_TUNE_PENDING_CAPTURE_MODE:-}" == "600" ]] || return 1
  _omc_canonical_uint_in_range "${AUTO_TUNE_PENDING_CAPTURE_SIZE:-}" 1 \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" || return 1
  auto_tune_digest_is_valid "${AUTO_TUNE_PENDING_CAPTURE_DIGEST}" \
    || return 1
  [[ "${operation}" == "retire" || "${operation}" == "advance" ]] \
    || return 1
  [[ ! -e "${PENDING_RETIRE_CLAIM_FILE}" \
      && ! -L "${PENDING_RETIRE_CLAIM_FILE}" ]] || return 1
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID="${AUTO_TUNE_PENDING_CAPTURE_ID}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST="${AUTO_TUNE_PENDING_CAPTURE_DIGEST}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE="${AUTO_TUNE_PENDING_CAPTURE_MODE}"
  AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE="${AUTO_TUNE_PENDING_CAPTURE_SIZE}"
  claim_json="$(auto_tune_build_pending_retire_claim_json \
    "${operation}" claimed none none none 0)" || return 1
  parent="${PENDING_RETIRE_CLAIM_FILE%/*}"
  [[ "${parent}" == "${QP_ROOT:-}" ]] || return 1
  tmp="$(mktemp "${parent}/.auto-tune-pending.retire-claim.XXXXXX")" \
    || return 1
  if ! printf '%s\n' "${claim_json}" >"${tmp}" \
      || ! chmod 600 "${tmp}" \
      || ! tmp_id="$(auto_tune_file_identity "${tmp}")" \
      || ! tmp_mode="$(auto_tune_file_mode "${tmp}")" \
      || ! tmp_size="$(auto_tune_file_size "${tmp}")" \
      || ! _omc_canonical_uint_in_range "${tmp_size}" 1 \
        "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MAX_BYTES:-4096}" \
      || ! tmp_digest="$(auto_tune_file_digest "${tmp}")" \
      || ! auto_tune_control_root_is_current \
      || [[ -e "${PENDING_RETIRE_CLAIM_FILE}" \
        || -L "${PENDING_RETIRE_CLAIM_FILE}" ]] \
      || ! mv -n -- "${tmp}" "${PENDING_RETIRE_CLAIM_FILE}" \
      || ! auto_tune_capture_pending_retire_claim \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_ID}" != "${tmp_id}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST}" \
        != "${tmp_digest}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE}" != "${tmp_mode}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE}" != "${tmp_size}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID}" \
        != "${AUTO_TUNE_PENDING_CAPTURE_ID}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST}" \
        != "${AUTO_TUNE_PENDING_CAPTURE_DIGEST}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE}" \
        != "${AUTO_TUNE_PENDING_CAPTURE_MODE}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE}" \
        != "${AUTO_TUNE_PENDING_CAPTURE_SIZE}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_OPERATION}" != "${operation}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_PHASE}" != "claimed" ]]; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
}

auto_tune_replace_pending_advance_claim() {
  local transition_phase="${1:-}" final_id="${2:-}"
  local final_digest="${3:-}" final_mode="${4:-}" final_size="${5:-}"
  local claim_json="" parent="" tmp="" tmp_id="" tmp_mode=""
  local tmp_size="" tmp_digest=""
  [[ "${AUTO_TUNE_PENDING_RETIRE_OPERATION:-}" == "advance" \
      && ( "${transition_phase}" == "staged" \
        || "${transition_phase}" == "published" ) \
      && ( ( "${AUTO_TUNE_PENDING_RETIRE_PHASE:-}" == "claimed" \
          && "${transition_phase}" == "staged" ) \
        || ( "${AUTO_TUNE_PENDING_RETIRE_PHASE:-}" == "staged" \
          && "${transition_phase}" == "published" ) ) \
      && "${final_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${final_mode}" == "600" ]] || return 1
  auto_tune_digest_is_valid "${final_digest}" || return 1
  _omc_canonical_uint_in_range "${final_size}" 1 \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" || return 1
  [[ "${final_digest##* }" == "${final_size}" ]] || return 1
  auto_tune_pending_retire_claim_is_current || return 1
  claim_json="$(auto_tune_build_pending_retire_claim_json advance \
    "${transition_phase}" "${final_id}" "${final_digest}" \
    "${final_mode}" "${final_size}")" || return 1
  parent="${PENDING_RETIRE_CLAIM_FILE%/*}"
  [[ "${parent}" == "${QP_ROOT:-}" ]] || return 1
  tmp="$(mktemp "${parent}/.auto-tune-pending.retire-claim.XXXXXX")" \
    || return 1
  if ! printf '%s\n' "${claim_json}" >"${tmp}" \
      || ! chmod 600 "${tmp}" \
      || ! tmp_id="$(auto_tune_file_identity "${tmp}")" \
      || ! tmp_mode="$(auto_tune_file_mode "${tmp}")" \
      || ! tmp_size="$(auto_tune_file_size "${tmp}")" \
      || ! _omc_canonical_uint_in_range "${tmp_size}" 1 \
        "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MAX_BYTES:-4096}" \
      || ! tmp_digest="$(auto_tune_file_digest "${tmp}")" \
      || ! auto_tune_control_root_is_current \
      || ! auto_tune_pending_retire_claim_is_current \
      || ! mv -f -- "${tmp}" "${PENDING_RETIRE_CLAIM_FILE}" \
      || ! auto_tune_capture_pending_retire_claim \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_ID}" != "${tmp_id}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_DIGEST}" \
        != "${tmp_digest}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_MODE}" != "${tmp_mode}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_CLAIM_SIZE}" != "${tmp_size}" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_OPERATION}" != "advance" ]] \
      || [[ "${AUTO_TUNE_PENDING_RETIRE_PHASE}" \
        != "${transition_phase}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_FINAL_ID}" != "${final_id}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST}" \
        != "${final_digest}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE}" \
        != "${final_mode}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE}" \
        != "${final_size}" ]]; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
}

auto_tune_path_matches_pending_retire_expectation() {
  local path="${1:-}"
  [[ -n "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID:-}" \
      && -n "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST:-}" \
      && -n "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE:-}" \
      && -n "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE:-}" ]] || return 1
  auto_tune_probe_pending_path "${path}" || return 1
  [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
        == "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_ID}" \
      && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" \
        == "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_DIGEST}" \
      && "${AUTO_TUNE_PENDING_PROBE_MODE}" \
        == "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_MODE}" \
      && "${AUTO_TUNE_PENDING_PROBE_SIZE}" \
        == "${AUTO_TUNE_PENDING_RETIRE_EXPECTED_SIZE}" ]]
}

auto_tune_restore_unexpected_retired_pending() {
  local wrong_id="" wrong_mode="" wrong_size="" wrong_links="" uid=""
  # A post-validation replacement is not required to be JSON. Bind its inode
  # and metadata without transferring bytes through a Bash variable so an
  # embedded NUL (or an oversized but otherwise ordinary file) can still be
  # restored byte-for-byte instead of becoming stranded in quarantine.
  auto_tune_control_root_is_current || return 1
  uid="$(id -u)" || return 1
  [[ -f "${PENDING_RETIRED_FILE}" && ! -L "${PENDING_RETIRED_FILE}" \
      && "$(auto_tune_file_owner "${PENDING_RETIRED_FILE}" \
        2>/dev/null || true)" == "${uid}" ]] || return 1
  wrong_id="$(auto_tune_file_identity "${PENDING_RETIRED_FILE}")" \
    || return 1
  wrong_mode="$(auto_tune_file_mode "${PENDING_RETIRED_FILE}")" \
    || return 1
  wrong_size="$(auto_tune_file_size "${PENDING_RETIRED_FILE}")" \
    || return 1
  wrong_links="$(auto_tune_file_link_count "${PENDING_RETIRED_FILE}")" \
    || return 1
  [[ "${wrong_mode}" =~ ^[0-7]{3,4}$ \
      && "${wrong_size}" =~ ^[0-9]+$ \
      && "${wrong_links}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ ! -e "${PENDING_FILE}" && ! -L "${PENDING_FILE}" ]] || return 1
  mv -n -- "${PENDING_RETIRED_FILE}" "${PENDING_FILE}" || return 1
  [[ ! -e "${PENDING_RETIRED_FILE}" \
      && ! -L "${PENDING_RETIRED_FILE}" ]] || return 1
  auto_tune_control_root_is_current || return 1
  [[ -f "${PENDING_FILE}" && ! -L "${PENDING_FILE}" \
      && "$(auto_tune_file_owner "${PENDING_FILE}" \
        2>/dev/null || true)" == "${uid}" \
      && "$(auto_tune_file_identity "${PENDING_FILE}" \
        2>/dev/null || true)" == "${wrong_id}" \
      && "$(auto_tune_file_mode "${PENDING_FILE}" \
        2>/dev/null || true)" == "${wrong_mode}" \
      && "$(auto_tune_file_size "${PENDING_FILE}" \
        2>/dev/null || true)" == "${wrong_size}" \
      && "$(auto_tune_file_link_count "${PENDING_FILE}" \
        2>/dev/null || true)" == "${wrong_links}" ]]
}

auto_tune_remove_captured_pending() {
  auto_tune_pending_generation_is_current || return 1
  [[ ! -e "${PENDING_RETIRED_FILE}" \
      && ! -L "${PENDING_RETIRED_FILE}" \
      && ! -e "${PENDING_RETIRE_CLAIM_FILE}" \
      && ! -L "${PENDING_RETIRE_CLAIM_FILE}" ]] || return 1
  auto_tune_publish_pending_retire_claim || return 1
  if ! auto_tune_pending_retire_claim_is_current \
      || ! auto_tune_pending_generation_is_current; then
    auto_tune_remove_pending_retire_claim >/dev/null 2>&1 || true
    return 1
  fi
  # Test-only pause after the final source check makes the otherwise tiny
  # check-to-rename window deterministic. The durable claim below ensures a
  # different inode caught by rename is restored, never discarded.
  if ! auto_tune_pending_pre_retire_test_barrier; then
    auto_tune_remove_pending_retire_claim >/dev/null 2>&1 || true
    return 1
  fi
  # Rename the authorized generation out of the public slot first. From this
  # point onward cleanup addresses only the fixed retirement quarantine, so a
  # newly published pending receipt can never be unlinked by this finalizer.
  mv -n -- "${PENDING_FILE}" "${PENDING_RETIRED_FILE}" || return 1
  if [[ -e "${PENDING_FILE}" || -L "${PENDING_FILE}" ]]; then
    return 1
  fi
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_RETIRE_RENAME:-0}" \
      == "1" ]]; then
    exit 75
  fi
  if ! auto_tune_pending_retire_claim_is_current; then
    return 1
  fi
  if ! auto_tune_path_matches_pending_retire_expectation \
      "${PENDING_RETIRED_FILE}"; then
    if auto_tune_restore_unexpected_retired_pending; then
      auto_tune_remove_pending_retire_claim >/dev/null 2>&1 || true
    fi
    return 1
  fi
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_RETIRE:-0}" == "1" ]]; then
    exit 75
  fi
  auto_tune_pending_retire_test_barrier || return 1
  auto_tune_pending_retire_claim_is_current || return 1
  auto_tune_path_matches_pending_retire_expectation \
    "${PENDING_RETIRED_FILE}" || return 1
  rm -f -- "${PENDING_RETIRED_FILE}" || return 1
  [[ ! -e "${PENDING_RETIRED_FILE}" \
      && ! -L "${PENDING_RETIRED_FILE}" ]] || return 1
  auto_tune_remove_pending_retire_claim || return 1
  auto_tune_clear_pending_capture
}

auto_tune_pending_snapshot_test_barrier() {
  auto_tune_pending_barrier \
    "${OMC_TEST_AUTO_TUNE_PENDING_SNAPSHOT_READY_FILE:-}" \
    "${OMC_TEST_AUTO_TUNE_PENDING_SNAPSHOT_RELEASE_FILE:-}"
}

auto_tune_pending_initial_publish_test_barrier() {
  auto_tune_pending_barrier \
    "${OMC_TEST_AUTO_TUNE_PENDING_INITIAL_READY_FILE:-}" \
    "${OMC_TEST_AUTO_TUNE_PENDING_INITIAL_RELEASE_FILE:-}"
}

auto_tune_pending_advance_test_barrier() {
  auto_tune_pending_barrier \
    "${OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_READY_FILE:-}" \
    "${OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_RELEASE_FILE:-}"
}

auto_tune_pending_advance_link_test_barrier() {
  auto_tune_pending_barrier \
    "${OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_LINK_READY_FILE:-}" \
    "${OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_LINK_RELEASE_FILE:-}"
}

AUTO_TUNE_PENDING_ADVANCE_OBSERVED_JSON=""
AUTO_TUNE_PENDING_ADVANCE_STAGE_ID=""
AUTO_TUNE_PENDING_ADVANCE_STAGE_DIGEST=""
AUTO_TUNE_PENDING_ADVANCE_STAGE_MODE=""
AUTO_TUNE_PENDING_ADVANCE_STAGE_SIZE=""

auto_tune_build_pending_advance_observed_json() {
  local source="${1:-}" source_json=""
  AUTO_TUNE_PENDING_ADVANCE_OBSERVED_JSON=""
  auto_tune_probe_pending_path "${source}" || return 1
  source_json="${AUTO_TUNE_PENDING_PROBE_JSON}"
  auto_tune_pending_receipt_structure_is_valid "${source_json}" || return 1
  jq -e '.phase == "prepared"' <<<"${source_json}" \
    >/dev/null 2>&1 || return 1
  AUTO_TUNE_PENDING_ADVANCE_OBSERVED_JSON="$(printf '%s' "${source_json}" \
    | jq -c '.phase = "write-observed"')" || return 1
  [[ -n "${AUTO_TUNE_PENDING_ADVANCE_OBSERVED_JSON}" ]]
}

auto_tune_capture_pending_advance_stage() {
  local expected_links="${1:-1}"
  AUTO_TUNE_PENDING_ADVANCE_STAGE_ID=""
  AUTO_TUNE_PENDING_ADVANCE_STAGE_DIGEST=""
  AUTO_TUNE_PENDING_ADVANCE_STAGE_MODE=""
  AUTO_TUNE_PENDING_ADVANCE_STAGE_SIZE=""
  auto_tune_probe_pending_path "${PENDING_ADVANCE_STAGE_FILE}" \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" "${expected_links}" || return 1
  AUTO_TUNE_PENDING_ADVANCE_STAGE_ID="${AUTO_TUNE_PENDING_PROBE_ID}"
  AUTO_TUNE_PENDING_ADVANCE_STAGE_DIGEST="${AUTO_TUNE_PENDING_PROBE_DIGEST}"
  AUTO_TUNE_PENDING_ADVANCE_STAGE_MODE="${AUTO_TUNE_PENDING_PROBE_MODE}"
  AUTO_TUNE_PENDING_ADVANCE_STAGE_SIZE="${AUTO_TUNE_PENDING_PROBE_SIZE}"
}

auto_tune_pending_advance_stage_matches_claim() {
  local expected_links="${1:-1}"
  auto_tune_capture_pending_advance_stage "${expected_links}" || return 1
  [[ "${AUTO_TUNE_PENDING_ADVANCE_STAGE_ID}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_ID:-}" \
      && "${AUTO_TUNE_PENDING_ADVANCE_STAGE_DIGEST}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST:-}" \
      && "${AUTO_TUNE_PENDING_ADVANCE_STAGE_MODE}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE:-}" \
      && "${AUTO_TUNE_PENDING_ADVANCE_STAGE_SIZE}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE:-}" ]]
}

auto_tune_pending_advance_public_matches_claim() {
  local expected_links="${1:-1}"
  auto_tune_probe_pending_path "${PENDING_FILE}" \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" "${expected_links}" || return 1
  [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_ID:-}" \
      && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST:-}" \
      && "${AUTO_TUNE_PENDING_PROBE_MODE}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE:-}" \
      && "${AUTO_TUNE_PENDING_PROBE_SIZE}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE:-}" ]]
}

auto_tune_ensure_pending_advance_stage() {
  local expected_json="${1:-}" expected_file="" parent="" tmp=""
  local tmp_id="" tmp_digest="" tmp_mode="" tmp_size=""
  [[ -n "${expected_json}" ]] || return 1
  auto_tune_pending_receipt_structure_is_valid "${expected_json}" || return 1
  jq -e '.phase == "write-observed"' <<<"${expected_json}" \
    >/dev/null 2>&1 || return 1
  expected_file="${expected_json}"$'\n'
  if [[ -e "${PENDING_ADVANCE_STAGE_FILE}" \
      || -L "${PENDING_ADVANCE_STAGE_FILE}" ]]; then
    auto_tune_capture_pending_advance_stage 1 || return 1
    [[ "${AUTO_TUNE_PENDING_PROBE_JSON}" == "${expected_file}" ]] \
      || return 1
    return 0
  fi
  parent="${PENDING_ADVANCE_STAGE_FILE%/*}"
  [[ "${parent}" == "${QP_ROOT:-}" ]] || return 1
  tmp="$(mktemp "${parent}/.auto-tune-pending.advance.XXXXXX")" \
    || return 1
  if ! printf '%s\n' "${expected_json}" >"${tmp}" \
      || ! chmod 600 "${tmp}" \
      || ! auto_tune_probe_pending_path "${tmp}" \
        "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" 1; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  tmp_id="${AUTO_TUNE_PENDING_PROBE_ID}"
  tmp_digest="${AUTO_TUNE_PENDING_PROBE_DIGEST}"
  tmp_mode="${AUTO_TUNE_PENDING_PROBE_MODE}"
  tmp_size="${AUTO_TUNE_PENDING_PROBE_SIZE}"
  if [[ "${AUTO_TUNE_PENDING_PROBE_JSON}" != "${expected_file}" ]] \
      || ! auto_tune_control_root_is_current \
      || [[ -e "${PENDING_ADVANCE_STAGE_FILE}" \
        || -L "${PENDING_ADVANCE_STAGE_FILE}" ]] \
      || ! mv -n -- "${tmp}" "${PENDING_ADVANCE_STAGE_FILE}" \
      || ! auto_tune_capture_pending_advance_stage 1 \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_STAGE_ID}" != "${tmp_id}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_STAGE_DIGEST}" \
        != "${tmp_digest}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_STAGE_MODE}" != "${tmp_mode}" ]] \
      || [[ "${AUTO_TUNE_PENDING_ADVANCE_STAGE_SIZE}" != "${tmp_size}" ]] \
      || [[ "${AUTO_TUNE_PENDING_PROBE_JSON}" != "${expected_file}" ]]; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
}

auto_tune_finalize_pending_advance() {
  [[ "${AUTO_TUNE_PENDING_RETIRE_OPERATION:-}" == "advance" \
      && "${AUTO_TUNE_PENDING_RETIRE_PHASE:-}" == "published" ]] \
    || return 1
  auto_tune_pending_retire_claim_is_current || return 1
  if [[ -e "${PENDING_ADVANCE_STAGE_FILE}" \
      || -L "${PENDING_ADVANCE_STAGE_FILE}" ]]; then
    auto_tune_pending_advance_stage_matches_claim 2 || return 1
    auto_tune_pending_advance_public_matches_claim 2 || return 1
    [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
        == "${AUTO_TUNE_PENDING_ADVANCE_STAGE_ID}" ]] || return 1
    auto_tune_pending_retire_claim_is_current || return 1
    auto_tune_pending_advance_stage_matches_claim 2 || return 1
    rm -f -- "${PENDING_ADVANCE_STAGE_FILE}" || return 1
    [[ ! -e "${PENDING_ADVANCE_STAGE_FILE}" \
        && ! -L "${PENDING_ADVANCE_STAGE_FILE}" ]] || return 1
  fi
  auto_tune_pending_advance_public_matches_claim 1 || return 1
  auto_tune_pending_retire_claim_is_current || return 1
  if [[ -e "${PENDING_RETIRED_FILE}" \
      || -L "${PENDING_RETIRED_FILE}" ]]; then
    auto_tune_path_matches_pending_retire_expectation \
      "${PENDING_RETIRED_FILE}" || return 1
    auto_tune_pending_advance_public_matches_claim 1 || return 1
    auto_tune_pending_retire_claim_is_current || return 1
    rm -f -- "${PENDING_RETIRED_FILE}" || return 1
    [[ ! -e "${PENDING_RETIRED_FILE}" \
        && ! -L "${PENDING_RETIRED_FILE}" ]] || return 1
  fi
  auto_tune_pending_advance_public_matches_claim 1 || return 1
  auto_tune_remove_pending_retire_claim
}

auto_tune_continue_pending_advance() {
  local stage_links=""
  [[ "${AUTO_TUNE_PENDING_RETIRE_OPERATION:-}" == "advance" ]] \
    || return 1
  if [[ "${AUTO_TUNE_PENDING_RETIRE_PHASE}" == "claimed" ]]; then
    auto_tune_path_matches_pending_retire_expectation \
      "${PENDING_RETIRED_FILE}" || return 1
    auto_tune_build_pending_advance_observed_json \
      "${PENDING_RETIRED_FILE}" || return 1
    auto_tune_ensure_pending_advance_stage \
      "${AUTO_TUNE_PENDING_ADVANCE_OBSERVED_JSON}" || return 1
    auto_tune_replace_pending_advance_claim staged \
      "${AUTO_TUNE_PENDING_ADVANCE_STAGE_ID}" \
      "${AUTO_TUNE_PENDING_ADVANCE_STAGE_DIGEST}" \
      "${AUTO_TUNE_PENDING_ADVANCE_STAGE_MODE}" \
      "${AUTO_TUNE_PENDING_ADVANCE_STAGE_SIZE}" || return 1
  fi

  if [[ "${AUTO_TUNE_PENDING_RETIRE_PHASE}" == "staged" ]]; then
    auto_tune_path_matches_pending_retire_expectation \
      "${PENDING_RETIRED_FILE}" || return 1
    stage_links="$(auto_tune_file_link_count \
      "${PENDING_ADVANCE_STAGE_FILE}" 2>/dev/null || true)"
    if [[ ! -e "${PENDING_FILE}" && ! -L "${PENDING_FILE}" ]]; then
      [[ "${stage_links}" == "1" ]] || return 1
      auto_tune_pending_advance_stage_matches_claim 1 || return 1
      auto_tune_pending_retire_claim_is_current || return 1
      auto_tune_path_matches_pending_retire_expectation \
        "${PENDING_RETIRED_FILE}" || return 1
      auto_tune_pending_advance_link_test_barrier || return 1
      # POSIX link(2) creation is an atomic no-clobber publication. Unlike
      # BSD `mv -n`, it cannot overwrite a receipt that appears after the
      # preceding absence check.
      command ln "${PENDING_ADVANCE_STAGE_FILE}" "${PENDING_FILE}" \
        2>/dev/null || return 1
      auto_tune_pending_advance_stage_matches_claim 2 || return 1
      auto_tune_pending_advance_public_matches_claim 2 || return 1
      [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
          == "${AUTO_TUNE_PENDING_ADVANCE_STAGE_ID}" ]] || return 1
    else
      [[ "${stage_links}" == "2" ]] || return 1
      auto_tune_pending_advance_stage_matches_claim 2 || return 1
      auto_tune_pending_advance_public_matches_claim 2 || return 1
      [[ "${AUTO_TUNE_PENDING_PROBE_ID}" \
          == "${AUTO_TUNE_PENDING_ADVANCE_STAGE_ID}" ]] || return 1
    fi
    if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_ADVANCE_LINK:-0}" \
        == "1" ]]; then
      exit 75
    fi
    auto_tune_replace_pending_advance_claim published \
      "${AUTO_TUNE_PENDING_ADVANCE_FINAL_ID}" \
      "${AUTO_TUNE_PENDING_ADVANCE_FINAL_DIGEST}" \
      "${AUTO_TUNE_PENDING_ADVANCE_FINAL_MODE}" \
      "${AUTO_TUNE_PENDING_ADVANCE_FINAL_SIZE}" || return 1
  fi

  [[ "${AUTO_TUNE_PENDING_RETIRE_PHASE}" == "published" ]] || return 1
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_ADVANCE_CLAIM:-0}" \
      == "1" ]]; then
    exit 75
  fi
  auto_tune_finalize_pending_advance
}

auto_tune_advance_captured_pending() {
  local observed_json="${1:-}" expected_observed=""
  auto_tune_pending_generation_is_current || return 1
  [[ ! -e "${PENDING_RETIRED_FILE}" \
      && ! -L "${PENDING_RETIRED_FILE}" \
      && ! -e "${PENDING_RETIRE_CLAIM_FILE}" \
      && ! -L "${PENDING_RETIRE_CLAIM_FILE}" \
      && ! -e "${PENDING_ADVANCE_STAGE_FILE}" \
      && ! -L "${PENDING_ADVANCE_STAGE_FILE}" ]] || return 1
  auto_tune_pending_receipt_structure_is_valid "${observed_json}" || return 1
  jq -e '.phase == "write-observed"' <<<"${observed_json}" \
    >/dev/null 2>&1 || return 1
  expected_observed="$(printf '%s' "${AUTO_TUNE_PENDING_CAPTURE_JSON}" \
    | jq -c '.phase = "write-observed"')" || return 1
  [[ "${observed_json}" == "${expected_observed}" ]] || return 1
  auto_tune_publish_pending_retire_claim advance || return 1
  if ! auto_tune_pending_retire_claim_is_current \
      || ! auto_tune_pending_generation_is_current; then
    auto_tune_remove_pending_retire_claim >/dev/null 2>&1 || true
    return 1
  fi
  # This pause is deliberately after the last source validation. If another
  # generation wins the public pathname now, rename quarantines it and the
  # post-rename identity check restores it before returning failure.
  auto_tune_pending_advance_test_barrier || return 1
  mv -n -- "${PENDING_FILE}" "${PENDING_RETIRED_FILE}" || return 1
  [[ ! -e "${PENDING_FILE}" && ! -L "${PENDING_FILE}" ]] || return 1
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_ADVANCE_RAW_RENAME:-0}" \
      == "1" ]]; then
    exit 75
  fi
  auto_tune_pending_retire_claim_is_current || return 1
  if ! auto_tune_path_matches_pending_retire_expectation \
      "${PENDING_RETIRED_FILE}"; then
    if auto_tune_restore_unexpected_retired_pending; then
      auto_tune_remove_pending_retire_claim >/dev/null 2>&1 || true
    fi
    return 1
  fi
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_ADVANCE_RENAME:-0}" \
      == "1" ]]; then
    exit 75
  fi
  auto_tune_continue_pending_advance || return 1
  auto_tune_clear_pending_capture
  auto_tune_capture_pending_generation
}

# A crash after the public receipt was renamed but before its private
# quarantine was unlinked leaves one fixed retirement artifact plus a durable
# expected-generation claim. Recovery may delete the quarantine only when its
# exact tuple matches that claim. A different receipt is restored to the public
# slot when it is free, or retained untouched when another generation already
# occupies that slot.
auto_tune_recover_retired_pending() {
  local retired_exists=0 claim_exists=0
  [[ -e "${PENDING_RETIRED_FILE}" \
      || -L "${PENDING_RETIRED_FILE}" ]] && retired_exists=1
  [[ -e "${PENDING_RETIRE_CLAIM_FILE}" \
      || -L "${PENDING_RETIRE_CLAIM_FILE}" ]] && claim_exists=1
  [[ "${retired_exists}" -eq 1 || "${claim_exists}" -eq 1 ]] || return 0
  # A quarantine without its pre-rename claim has no deletion authority. It
  # may be an arbitrary valid receipt moved by an interrupted older process.
  [[ "${claim_exists}" -eq 1 ]] || return 1
  auto_tune_capture_pending_retire_claim || return 1

  if [[ "${AUTO_TUNE_PENDING_RETIRE_OPERATION}" == "advance" ]]; then
    case "${AUTO_TUNE_PENDING_RETIRE_PHASE}" in
      claimed)
        if [[ "${retired_exists}" -eq 1 ]]; then
          if ! auto_tune_path_matches_pending_retire_expectation \
              "${PENDING_RETIRED_FILE}"; then
            auto_tune_restore_unexpected_retired_pending || return 1
            auto_tune_remove_pending_retire_claim
            return
          fi
        else
          auto_tune_path_matches_pending_retire_expectation \
            "${PENDING_FILE}" || return 1
          [[ ! -e "${PENDING_RETIRED_FILE}" \
              && ! -L "${PENDING_RETIRED_FILE}" ]] || return 1
          mv -n -- "${PENDING_FILE}" "${PENDING_RETIRED_FILE}" || return 1
          [[ ! -e "${PENDING_FILE}" && ! -L "${PENDING_FILE}" ]] \
            || return 1
          if ! auto_tune_path_matches_pending_retire_expectation \
              "${PENDING_RETIRED_FILE}"; then
            auto_tune_restore_unexpected_retired_pending || return 1
            auto_tune_remove_pending_retire_claim
            return
          fi
        fi
        ;;
      staged)
        [[ "${retired_exists}" -eq 1 ]] || return 1
        auto_tune_path_matches_pending_retire_expectation \
          "${PENDING_RETIRED_FILE}" || return 1
        ;;
      published)
        # The old quarantine may already be absent if interruption happened
        # after its exact deletion but before claim cleanup.
        if [[ "${retired_exists}" -eq 1 ]]; then
          auto_tune_path_matches_pending_retire_expectation \
            "${PENDING_RETIRED_FILE}" || return 1
        fi
        ;;
      *) return 1 ;;
    esac
    auto_tune_continue_pending_advance
    return
  fi

  if [[ "${retired_exists}" -eq 1 ]]; then
    if auto_tune_path_matches_pending_retire_expectation \
        "${PENDING_RETIRED_FILE}"; then
      auto_tune_pending_retire_claim_is_current || return 1
      auto_tune_path_matches_pending_retire_expectation \
        "${PENDING_RETIRED_FILE}" || return 1
      rm -f -- "${PENDING_RETIRED_FILE}" || return 1
      [[ ! -e "${PENDING_RETIRED_FILE}" \
          && ! -L "${PENDING_RETIRED_FILE}" ]] || return 1
      auto_tune_remove_pending_retire_claim
      return
    fi
    # The rename captured a different generation in its final race window.
    # Restore that exact inode when possible; if another pending generation is
    # already live, retain both artifacts and fail closed for manual recovery.
    auto_tune_restore_unexpected_retired_pending || return 1
    auto_tune_remove_pending_retire_claim
    return
  fi

  # No quarantine means the crash happened before rename, or after exact
  # quarantine deletion but before claim cleanup. In both cases the claim is
  # stale metadata; never mutate whatever receipt currently occupies the
  # public slot while clearing it.
  auto_tune_remove_pending_retire_claim
}

# Atomic initial publication briefly gives the staged inode two names. A hard
# interruption between link(2) and staged-name cleanup is recognizable without
# trusting pathname bytes: exactly one reserved temp name and the public receipt
# must be the same private two-link inode. A failed no-clobber attempt leaves a
# one-link temp, which is safe to discard only when it is itself a valid
# pre-mutation prepared receipt.
auto_tune_recover_pending_initial_link() {
  local had_nullglob=0 temp="" temp_links="" pending_links=""
  local temp_id="" temp_digest="" temp_mode="" temp_size="" temp_json=""
  local -a candidates=()
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  candidates=("${QP_ROOT}"/.auto-tune-pending.json.auto-tune.*)
  [[ "${had_nullglob}" -eq 1 ]] || shopt -u nullglob
  [[ "${#candidates[@]}" -gt 0 ]] || return 0
  [[ "${#candidates[@]}" -eq 1 ]] || return 1
  temp="${candidates[0]}"
  [[ "${temp##*/}" =~ ^[.]auto-tune-pending[.]json[.]auto-tune[.][A-Za-z0-9]+$ \
      && "${temp%/*}" == "${QP_ROOT}" ]] || return 1
  temp_links="$(auto_tune_file_link_count "${temp}" \
    2>/dev/null || true)"
  [[ "${temp_links}" == "1" || "${temp_links}" == "2" ]] || return 1
  auto_tune_probe_pending_path "${temp}" \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" "${temp_links}" || return 1
  temp_id="${AUTO_TUNE_PENDING_PROBE_ID}"
  temp_digest="${AUTO_TUNE_PENDING_PROBE_DIGEST}"
  temp_mode="${AUTO_TUNE_PENDING_PROBE_MODE}"
  temp_size="${AUTO_TUNE_PENDING_PROBE_SIZE}"
  temp_json="${AUTO_TUNE_PENDING_PROBE_JSON}"
  auto_tune_pending_receipt_structure_is_valid "${temp_json}" || return 1
  jq -e '.phase == "prepared"' <<<"${temp_json}" \
    >/dev/null 2>&1 || return 1
  if [[ -e "${PENDING_FILE}" || -L "${PENDING_FILE}" ]]; then
    pending_links="$(auto_tune_file_link_count "${PENDING_FILE}" \
      2>/dev/null || true)"
    if [[ "${temp_links}" == "2" && "${pending_links}" == "2" ]]; then
      auto_tune_probe_pending_path "${PENDING_FILE}" \
        "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" 2 || return 1
      [[ "${AUTO_TUNE_PENDING_PROBE_ID}" == "${temp_id}" \
          && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" == "${temp_digest}" \
          && "${AUTO_TUNE_PENDING_PROBE_MODE}" == "${temp_mode}" \
          && "${AUTO_TUNE_PENDING_PROBE_SIZE}" == "${temp_size}" ]] \
        || return 1
    elif [[ "${temp_links}" != "1" ]]; then
      return 1
    fi
  elif [[ "${temp_links}" != "1" ]]; then
    return 1
  fi
  auto_tune_probe_pending_path "${temp}" \
    "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" "${temp_links}" || return 1
  [[ "${AUTO_TUNE_PENDING_PROBE_ID}" == "${temp_id}" \
      && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" == "${temp_digest}" \
      && "${AUTO_TUNE_PENDING_PROBE_MODE}" == "${temp_mode}" \
      && "${AUTO_TUNE_PENDING_PROBE_SIZE}" == "${temp_size}" ]] \
    || return 1
  rm -f -- "${temp}" || return 1
  [[ ! -e "${temp}" && ! -L "${temp}" ]] || return 1
  if [[ "${temp_links}" == "2" ]]; then
    auto_tune_probe_pending_path "${PENDING_FILE}" \
      "${AUTO_TUNE_PENDING_MAX_BYTES:-32768}" 1 || return 1
    [[ "${AUTO_TUNE_PENDING_PROBE_ID}" == "${temp_id}" \
        && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" == "${temp_digest}" \
        && "${AUTO_TUNE_PENDING_PROBE_MODE}" == "${temp_mode}" \
        && "${AUTO_TUNE_PENDING_PROBE_SIZE}" == "${temp_size}" ]] \
      || return 1
  fi
}

auto_tune_pending_initial_temp_exists() {
  local had_nullglob=0
  local -a candidates=()
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  candidates=("${QP_ROOT}"/.auto-tune-pending.json.auto-tune.*)
  [[ "${had_nullglob}" -eq 1 ]] || shopt -u nullglob
  [[ "${#candidates[@]}" -gt 0 ]]
}

auto_tune_control_root_is_safe() {
  local root="${1:-}" uid="" mode=""
  uid="$(id -u)" || return 1
  [[ -d "${root}" && ! -L "${root}" \
      && "$(auto_tune_file_owner "${root}" 2>/dev/null || true)" \
        == "${uid}" ]] || return 1
  mode="$(auto_tune_file_mode "${root}" 2>/dev/null || true)"
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  (( ((8#${mode}) & 8#22) == 0 ))
}

auto_tune_control_root_is_current() {
  [[ -n "${QP_ROOT:-}" && -n "${AUTO_TUNE_QP_ROOT_ID:-}" ]] || return 1
  auto_tune_control_root_is_safe "${QP_ROOT}" \
    && [[ "$(auto_tune_file_identity "${QP_ROOT}" \
      2>/dev/null || true)" == "${AUTO_TUNE_QP_ROOT_ID}" ]]
}

auto_tune_evidence_leaf_is_safe() {
  local mode=""
  [[ -e "${GATE_EVENTS_FILE}" || -L "${GATE_EVENTS_FILE}" ]] || return 0
  auto_tune_owned_single_regular_file "${GATE_EVENTS_FILE}" || return 1
  mode="$(auto_tune_file_mode "${GATE_EVENTS_FILE}" \
    2>/dev/null || true)"
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  (( ((8#${mode}) & 8#22) == 0 ))
}

auto_tune_evidence_path_is_safe() {
  local path="${1:-}" max_bytes="${2:-0}" mode="" size=""
  [[ "${max_bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  auto_tune_owned_single_regular_file "${path}" || return 1
  mode="$(auto_tune_file_mode "${path}" 2>/dev/null || true)"
  size="$(auto_tune_file_size "${path}" 2>/dev/null || true)"
  [[ "${mode}" =~ ^[0-7]{3,4}$ && "${size}" =~ ^[0-9]+$ ]] || return 1
  (( ((8#${mode}) & 8#22) == 0 && size <= max_bytes ))
}

_auto_tune_jsonl_snapshot_is_complete_and_valid() {
  local path="${1:-}" max_bytes="${2:-${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}}"
  local size=""
  [[ "${max_bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  auto_tune_owned_single_regular_file "${path}" || return 1
  size="$(auto_tune_file_size "${path}" 2>/dev/null || true)"
  [[ "${size}" =~ ^[0-9]+$ && "${size}" -le "${max_bytes}" ]] \
    || return 1
  [[ ! -s "${path}" || -z "$(tail -c 1 "${path}" 2>/dev/null)" ]] \
    || return 1
  [[ ! -s "${path}" ]] || LC_ALL=C tr -d '\000' <"${path}" \
    | cmp -s - "${path}" 2>/dev/null || return 1
  [[ ! -s "${path}" ]] || jq -Rse '
    select(index("\u0000") == null) |
    def bounded_text($n):
      type == "string" and length > 0 and length <= $n and
      (test("[\u0000-\u001f\u007f]") | not);
    def audit_keys:
      ["_v","decision_id","evidence","flag","host","new","old","ts"];
    def legacy_audit_keys:
      ["evidence","flag","host","new","old","ts"];
    def valid_audit:
      type == "object" and
      ((((keys | sort) == audit_keys and ._v == 1) and
          (.decision_id | type == "string" and length > 0 and
            length <= 160 and
            test("^auto-tune-[0-9]+-[0-9]+-[0-9]+-[0-9]+$"))) or
       ((keys | sort) == legacy_audit_keys and
          (has("_v") | not) and (has("decision_id") | not))) and
      (.ts | type == "number" and floor == . and . >= 0 and
        . <= 9999999999) and
      .flag == "objective_contract_min_files" and
      (.old | type == "number" and floor == . and . >= 2 and . <= 11) and
      (.new | type == "number" and floor == . and . >= 3 and . <= 12) and
      (.new == (.old + 1)) and
      (.evidence | bounded_text(1024)) and
      (.host | type == "string" and length > 0 and length <= 512 and
        test("^[A-Za-z0-9._-]+$"));
    split("\n") as $lines
    | [$lines[0:-1][] | select(length > 0) | fromjson?] as $rows
    | ($lines[-1] == "") and
      (($rows | length) == (($lines | length) - 1)) and
      all($rows[]; valid_audit)
  ' "${path}" >/dev/null 2>&1
}

auto_tune_capture_valid_jsonl_snapshot() {
  local path="${1:-}" snapshot="${2:-}"
  local max_bytes="${3:-${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}}"
  if ! auto_tune_capture_safe_regular_snapshot \
      "${path}" "${snapshot}" "${max_bytes}" \
      || ! _auto_tune_jsonl_snapshot_is_complete_and_valid \
        "${snapshot}" "${max_bytes}" \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${path}" "${snapshot}" "${max_bytes}"; then
    return 1
  fi
}

auto_tune_jsonl_is_complete_and_valid() {
  local path="${1:-}" max_bytes="${2:-${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}}"
  local snapshot=""
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-jsonl-read.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_valid_jsonl_snapshot \
      "${path}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null
}

# Releases before durable decision IDs wrote an exact six-key audit row with a
# plain shell append. Under the normal umask that left an otherwise-valid
# ledger at 0644. Preserve those historical rows, but replace the leaf with a
# byte-identical private generation before any new decision is evaluated. The
# operation lock is already held; the identity/digest/mode recheck closes an
# out-of-band replacement race without chmod-following a path that changed.
_auto_tune_tighten_audit_mode_locked() {
  local parent="" source_id="" source_mode=""
  local source_snapshot="" tmp="" tmp_id="" tmp_digest="" tmp_size=""
  auto_tune_control_root_is_current || return 1
  [[ -e "${AUDIT_LEDGER}" ]] || return 0
  source_snapshot="$(mktemp \
    "${QP_ROOT}/.auto-tune-audit-mode-source.XXXXXX")" || return 1
  if ! auto_tune_capture_valid_jsonl_snapshot \
      "${AUDIT_LEDGER}" "${source_snapshot}" \
      "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  source_id="$(auto_tune_file_identity "${AUDIT_LEDGER}")" || {
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  source_mode="$(auto_tune_file_mode "${AUDIT_LEDGER}")" || {
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  if [[ "${source_mode}" == "600" ]]; then
    rm -f -- "${source_snapshot}" 2>/dev/null || return 1
    return 0
  fi
  if [[ ! "${source_mode}" =~ ^[0-7]{3,4}$ ]] \
      || (( ((8#${source_mode}) & 8#22) != 0 )); then
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  parent="${AUDIT_LEDGER%/*}"
  tmp="$(mktemp "${parent}/.auto-tune.jsonl.private.XXXXXX")" || {
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  if ! cat -- "${source_snapshot}" >"${tmp}" \
      || ! chmod 600 "${tmp}" \
      || ! auto_tune_jsonl_is_complete_and_valid "${tmp}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
      || [[ "$(auto_tune_file_identity "${AUDIT_LEDGER}" \
        2>/dev/null || true)" != "${source_id}" ]] \
      || [[ "$(auto_tune_file_mode "${AUDIT_LEDGER}" \
        2>/dev/null || true)" != "${source_mode}" ]] \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${AUDIT_LEDGER}" "${source_snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
      || ! auto_tune_control_root_is_current; then
    rm -f -- "${tmp}" 2>/dev/null || true
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  tmp_id="$(auto_tune_file_identity "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  tmp_digest="$(auto_tune_file_digest "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  tmp_size="$(auto_tune_file_size "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  if ! auto_tune_control_root_is_current \
      || ! mv -f -- "${tmp}" "${AUDIT_LEDGER}" \
      || ! auto_tune_published_regular_generation_matches \
        "${AUDIT_LEDGER}" "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
        "${tmp_id}" "${tmp_digest}" 600 "${tmp_size}" \
      || ! auto_tune_jsonl_is_complete_and_valid "${AUDIT_LEDGER}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${source_snapshot}" 2>/dev/null
}

auto_tune_tighten_audit_mode() {
  with_cross_session_log_lock "${AUDIT_LEDGER}" \
    _auto_tune_tighten_audit_mode_locked
}

# A new mutation must have enough durable-audit capacity before its pending
# receipt is published or omc-config is called. Otherwise a valid ledger sitting
# just below the hard ceiling could let the config write land and strand a
# write-observed receipt that can never append its row.
auto_tune_audit_has_capacity_for_row() {
  local row="${1:-}" current_size=0 row_size="" snapshot=""
  [[ -n "${row}" ]] || return 1
  auto_tune_control_root_is_current || return 1
  printf '%s\n' "${row}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || return 1
  if [[ -e "${AUDIT_LEDGER}" ]]; then
    snapshot="$(mktemp "${QP_ROOT}/.auto-tune-audit-capacity.XXXXXX")" \
      || return 1
    if ! auto_tune_capture_valid_jsonl_snapshot \
        "${AUDIT_LEDGER}" "${snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
      rm -f -- "${snapshot}" 2>/dev/null || true
      return 1
    fi
    current_size="$(auto_tune_file_size "${snapshot}")" || {
      rm -f -- "${snapshot}" 2>/dev/null || true
      return 1
    }
    if ! auto_tune_safe_regular_snapshot_is_current \
        "${AUDIT_LEDGER}" "${snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
      rm -f -- "${snapshot}" 2>/dev/null || true
      return 1
    fi
    rm -f -- "${snapshot}" 2>/dev/null || return 1
  fi
  row_size="$(LC_ALL=C printf '%s\n' "${row}" | wc -c \
    | tr -d '[:space:]')"
  [[ "${current_size}" =~ ^[0-9]+$ && "${row_size}" =~ ^[1-9][0-9]*$ ]] \
    || return 1
  (( current_size + row_size <= ${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304} ))
}

auto_tune_published_regular_generation_matches() {
  local path="${1:-}" max_bytes="${2:-}" expected_id="${3:-}"
  local expected_digest="${4:-}" expected_mode="${5:-}"
  local expected_size="${6:-}" snapshot="" actual_digest=""
  local actual_mode="" actual_size="" actual_id="" rc=0
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-published.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_safe_regular_snapshot \
      "${path}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  actual_id="$(auto_tune_file_identity "${path}")" || rc=1
  actual_digest="$(auto_tune_file_digest "${snapshot}")" || rc=1
  actual_mode="$(auto_tune_file_mode "${path}")" || rc=1
  actual_size="$(auto_tune_file_size "${snapshot}")" || rc=1
  if [[ "${rc}" -ne 0 || "${actual_id}" != "${expected_id}" \
      || "${actual_digest}" != "${expected_digest}" \
      || "${actual_mode}" != "${expected_mode}" \
      || "${actual_size}" != "${expected_size}" ]] \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${path}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null
}

# Publish a private JSON control artifact without ever replacing an alias or
# moving a stage inside a directory. State publication snapshots whichever
# state generation is current. Initial pending publication requires an absent
# public slot and uses an atomic hard-link create, never BSD `mv -n`'s
# check-then-rename implementation. Prepared-to-observed advancement has its
# own durable quarantine transaction above.
write_auto_tune_json_atomic() {
  local destination="${1:-}" payload="${2:-}" expectation="${3:-auto}"
  local parent="" tmp="" source_snapshot=""
  local source_exists=0 source_digest="" source_mode=""
  local source_size="" tmp_id="" tmp_digest="" tmp_mode="" tmp_size=""
  local max_bytes=0 is_pending=0
  parent="${destination%/*}"
  [[ "${parent}" == "${QP_ROOT:-}" ]] || return 1
  auto_tune_control_root_is_current || return 1
  case "${destination}" in
    "${STATE_FILE:-}")
      [[ "${expectation}" == "auto" ]] || return 1
      max_bytes="${AUTO_TUNE_STATE_MAX_BYTES:-16384}"
      ;;
    "${PENDING_FILE:-}")
      [[ "${expectation}" == "absent" ]] || return 1
      max_bytes="${AUTO_TUNE_PENDING_MAX_BYTES:-32768}"
      is_pending=1
      ;;
    *) return 1 ;;
  esac
  _omc_canonical_uint_in_range "${max_bytes}" 1 2147483646 || return 1
  printf '%s\n' "${payload}" | jq -e . >/dev/null 2>&1 || return 1
  auto_tune_safe_regular_leaf_or_absent "${destination}" || return 1
  if [[ "${is_pending}" -eq 1 ]]; then
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  elif [[ -f "${destination}" ]]; then
    source_exists=1
    source_snapshot="$(mktemp \
      "${parent}/.auto-tune-state-source.XXXXXX")" || return 1
    if ! auto_tune_capture_safe_regular_snapshot \
        "${destination}" "${source_snapshot}" "${max_bytes}"; then
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
    source_mode="$(auto_tune_file_mode "${destination}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
    source_size="$(auto_tune_file_size "${source_snapshot}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
    if ! _omc_canonical_uint_in_range "${source_size}" 1 "${max_bytes}"; then
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
    source_digest="$(auto_tune_file_digest "${source_snapshot}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
  fi
  tmp="$(mktemp "${parent}/.$(basename "${destination}").auto-tune.XXXXXX")" \
    || {
      [[ -z "${source_snapshot}" ]] \
        || rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
  if ! printf '%s\n' "${payload}" > "${tmp}" \
      || ! chmod 600 "${tmp}" \
      || ! tmp_id="$(auto_tune_file_identity "${tmp}")" \
      || ! tmp_mode="$(auto_tune_file_mode "${tmp}")" \
      || ! tmp_size="$(auto_tune_file_size "${tmp}")" \
      || ! _omc_canonical_uint_in_range "${tmp_size}" 1 "${max_bytes}" \
      || ! tmp_digest="$(auto_tune_file_digest "${tmp}")" \
      || ! auto_tune_control_root_is_current; then
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi

  if [[ "${is_pending}" -eq 1 ]]; then
    # The seam is after the last absence validation. Atomic link creation is
    # the actual guard if another process publishes while the seam is open.
    if [[ -e "${destination}" || -L "${destination}" ]] \
        || ! auto_tune_pending_initial_publish_test_barrier; then
      rm -f -- "${tmp}" 2>/dev/null || true
      [[ -z "${source_snapshot}" ]] \
        || rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  elif ! auto_tune_safe_regular_leaf_or_absent "${destination}" \
      || { [[ "${source_exists}" -eq 1 ]] \
        && { [[ "$(auto_tune_file_mode "${destination}" \
              2>/dev/null || true)" != "${source_mode}" ]] \
          || ! auto_tune_safe_regular_snapshot_is_current \
            "${destination}" "${source_snapshot}" "${max_bytes}"; }; } \
      || { [[ "${source_exists}" -eq 0 ]] \
        && { [[ -e "${destination}" ]] || [[ -L "${destination}" ]]; }; }; then
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi

  if ! auto_tune_control_root_is_current; then
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ "${is_pending}" -eq 1 || "${source_exists}" -eq 0 ]]; then
    if ! command ln "${tmp}" "${destination}" 2>/dev/null; then
      rm -f -- "${tmp}" 2>/dev/null || true
      [[ -z "${source_snapshot}" ]] \
        || rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  elif ! mv -f -- "${tmp}" "${destination}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ "${is_pending}" -eq 1 ]]; then
    if ! auto_tune_probe_pending_path "${tmp}" "${max_bytes}" 2 \
        || [[ "${AUTO_TUNE_PENDING_PROBE_ID}" != "${tmp_id}" ]] \
        || [[ "${AUTO_TUNE_PENDING_PROBE_DIGEST}" != "${tmp_digest}" ]] \
        || [[ "${AUTO_TUNE_PENDING_PROBE_MODE}" != "${tmp_mode}" ]] \
        || [[ "${AUTO_TUNE_PENDING_PROBE_SIZE}" != "${tmp_size}" ]] \
        || ! auto_tune_probe_pending_path "${destination}" "${max_bytes}" 2 \
        || [[ "${AUTO_TUNE_PENDING_PROBE_ID}" != "${tmp_id}" ]] \
        || [[ "${AUTO_TUNE_PENDING_PROBE_DIGEST}" != "${tmp_digest}" ]] \
        || [[ "${AUTO_TUNE_PENDING_PROBE_MODE}" != "${tmp_mode}" ]] \
        || [[ "${AUTO_TUNE_PENDING_PROBE_SIZE}" != "${tmp_size}" ]]; then
      return 1
    fi
    if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_INITIAL_LINK:-0}" \
        == "1" ]]; then
      exit 75
    fi
    auto_tune_probe_pending_path "${tmp}" "${max_bytes}" 2 || return 1
    [[ "${AUTO_TUNE_PENDING_PROBE_ID}" == "${tmp_id}" ]] || return 1
    rm -f -- "${tmp}" || return 1
    [[ ! -e "${tmp}" && ! -L "${tmp}" ]] || return 1
    auto_tune_probe_pending_path "${destination}" "${max_bytes}" 1 \
      || return 1
    [[ "${AUTO_TUNE_PENDING_PROBE_ID}" == "${tmp_id}" \
        && "${AUTO_TUNE_PENDING_PROBE_DIGEST}" == "${tmp_digest}" \
        && "${AUTO_TUNE_PENDING_PROBE_MODE}" == "${tmp_mode}" \
        && "${AUTO_TUNE_PENDING_PROBE_SIZE}" == "${tmp_size}" ]] \
      || return 1
  else
    if [[ "${source_exists}" -eq 0 ]]; then
      if [[ ! -f "${tmp}" || -L "${tmp}" \
          || ! -f "${destination}" || -L "${destination}" \
          || ! "${tmp}" -ef "${destination}" ]]; then
        rm -f -- "${tmp}" 2>/dev/null || true
        return 1
      fi
      rm -f -- "${tmp}" || return 1
    fi
    if ! auto_tune_published_regular_generation_matches \
        "${destination}" "${max_bytes}" "${tmp_id}" "${tmp_digest}" \
        "${tmp_mode}" "${tmp_size}"; then
      [[ ! -e "${tmp}" && ! -L "${tmp}" ]] \
        || rm -f -- "${tmp}" 2>/dev/null || true
      [[ -z "${source_snapshot}" ]] \
        || rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || return 1
  fi
}

AUTO_TUNE_AUDIT_ROW=""
AUTO_TUNE_AUDIT_DECISION_ID=""
_append_auto_tune_audit_row() {
  local parent="" tmp="" source_snapshot="" published_snapshot=""
  local source_exists=0 source_id="" source_mode=""
  local tmp_id="" tmp_digest="" tmp_mode="" tmp_size=""
  parent="${AUDIT_LEDGER%/*}"
  [[ "${parent}" == "${QP_ROOT:-}" ]] || return 1
  auto_tune_control_root_is_current || return 1
  auto_tune_safe_regular_leaf_or_absent "${AUDIT_LEDGER}" || return 1
  if [[ -e "${AUDIT_LEDGER}" ]]; then
    source_exists=1
    source_snapshot="$(mktemp \
      "${parent}/.auto-tune-audit-source.XXXXXX")" || return 1
    if ! auto_tune_capture_valid_jsonl_snapshot \
        "${AUDIT_LEDGER}" "${source_snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
    source_id="$(auto_tune_file_identity "${AUDIT_LEDGER}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
    source_mode="$(auto_tune_file_mode "${AUDIT_LEDGER}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
    if ! jq -se --arg id "${AUTO_TUNE_AUDIT_DECISION_ID}" \
      'map(select(.decision_id? == $id)) | length == 0' \
        "${source_snapshot}" >/dev/null 2>&1; then
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  fi
  printf '%s\n' "${AUTO_TUNE_AUDIT_ROW}" \
    | jq -e --arg id "${AUTO_TUNE_AUDIT_DECISION_ID}" \
      'type == "object" and .decision_id == $id' >/dev/null 2>&1 \
    || return 1
  tmp="$(mktemp "${parent}/.auto-tune.jsonl.XXXXXX")" || {
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  if ! chmod 600 "${tmp}" \
      || { [[ "${source_exists}" -eq 1 ]] \
        && ! cat -- "${source_snapshot}" > "${tmp}"; } \
      || ! printf '%s\n' "${AUTO_TUNE_AUDIT_ROW}" >> "${tmp}" \
      || ! auto_tune_jsonl_is_complete_and_valid "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ "${source_exists}" -eq 1 ]]; then
    if [[ "$(auto_tune_file_identity "${AUDIT_LEDGER}" \
          2>/dev/null || true)" != "${source_id}" ]] \
        || [[ "$(auto_tune_file_mode "${AUDIT_LEDGER}" \
          2>/dev/null || true)" != "${source_mode}" ]] \
        || ! auto_tune_safe_regular_snapshot_is_current \
          "${AUDIT_LEDGER}" "${source_snapshot}" \
          "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
      rm -f -- "${tmp}" 2>/dev/null || true
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  elif [[ -e "${AUDIT_LEDGER}" || -L "${AUDIT_LEDGER}" ]]; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  tmp_id="$(auto_tune_file_identity "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  tmp_digest="$(auto_tune_file_digest "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  tmp_mode="$(auto_tune_file_mode "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  tmp_size="$(auto_tune_file_size "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  if ! auto_tune_control_root_is_current; then
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ "${source_exists}" -eq 1 ]]; then
    if ! mv -f -- "${tmp}" "${AUDIT_LEDGER}"; then
      rm -f -- "${tmp}" 2>/dev/null || true
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  else
    if ! command ln "${tmp}" "${AUDIT_LEDGER}" 2>/dev/null \
        || [[ ! -f "${AUDIT_LEDGER}" || -L "${AUDIT_LEDGER}" \
          || ! "${tmp}" -ef "${AUDIT_LEDGER}" ]]; then
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    fi
    rm -f -- "${tmp}" || return 1
  fi
  published_snapshot="$(mktemp \
    "${parent}/.auto-tune-audit-published.XXXXXX")" || {
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  }
  if ! auto_tune_published_regular_generation_matches \
      "${AUDIT_LEDGER}" "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
      "${tmp_id}" "${tmp_digest}" "${tmp_mode}" "${tmp_size}" \
      || ! auto_tune_capture_valid_jsonl_snapshot \
        "${AUDIT_LEDGER}" "${published_snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
      || ! jq -se --arg id "${AUTO_TUNE_AUDIT_DECISION_ID}" \
        --argjson expected "${AUTO_TUNE_AUDIT_ROW}" \
        '[.[] | select(.decision_id? == $id)] == [$expected]' \
        "${published_snapshot}" >/dev/null 2>&1 \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${AUDIT_LEDGER}" "${published_snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
    rm -f -- "${published_snapshot}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${published_snapshot}" 2>/dev/null || return 1
  [[ -z "${source_snapshot}" ]] \
    || rm -f -- "${source_snapshot}" 2>/dev/null || return 1
}

append_auto_tune_audit_row() {
  AUTO_TUNE_AUDIT_ROW="${1:-}"
  AUTO_TUNE_AUDIT_DECISION_ID="${2:-}"
  [[ -n "${AUTO_TUNE_AUDIT_ROW}" \
      && -n "${AUTO_TUNE_AUDIT_DECISION_ID}" ]] || return 1
  auto_tune_safe_regular_leaf_or_absent "${AUDIT_LEDGER}" || return 1
  with_cross_session_log_lock "${AUDIT_LEDGER}" \
    _append_auto_tune_audit_row
}

# Run capacity reservation, receipt publication, the nested config writer, and
# the matching audit append under one audit-ledger generation lock. This is
# intentionally broader than current-version process serialization: an older
# already-running SessionStart hook knows the cross-session ledger lock but not
# the newer shared install/config operation lock. Holding both prevents that
# old writer from landing an append between our capacity check and atomic
# replacement. The callback returns 75 for deterministic crash seams so the
# wrapper can release the ledger lock before the hook exits.
AUTO_TUNE_DECISION_ABORT=0
_apply_auto_tune_decision_locked() {
  local audit_row="${1:-}" pending_receipt="${2:-}"
  local decision_id="${3:-}" user_conf="${4:-}" new_value="${5:-}"
  local current="${6:-}" oc_pct="${7:-}" oc_blocks="${8:-}"
  [[ -n "${audit_row}" && -n "${pending_receipt}" \
      && -n "${decision_id}" && -n "${user_conf}" \
      && "${new_value}" =~ ^[0-9]+$ && "${current}" =~ ^[0-9]+$ \
      && "${oc_pct}" =~ ^[0-9]+$ && "${oc_blocks}" =~ ^[0-9]+$ ]] \
    || return 1
  if ! auto_tune_authority_enabled_now \
      || auto_tune_threshold_authority_is_shadowed \
      || ! auto_tune_conf_matches_generation "${AUTO_TUNE_ENTRY_STATE}" \
        "${AUTO_TUNE_ENTRY_DIGEST}" "${AUTO_TUNE_ENTRY_MODE}"; then
    reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but tuning authority or the sealed entry config generation changed before publication — no config change attempted"
    retryable_error=1
    return 0
  fi
  if ! auto_tune_audit_has_capacity_for_row "${audit_row}"; then
    reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the durable audit ledger has no capacity for this decision — no config change attempted"
    retryable_error=1
    return 0
  fi
  if ! write_auto_tune_json_atomic "${PENDING_FILE}" \
      "${pending_receipt}" absent; then
    reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the durable decision receipt could not be published — no config change attempted"
    retryable_error=1
    return 0
  fi
  if ! auto_tune_capture_pending_generation; then
    log_anomaly "session-start-auto-tune" \
      "published prepared receipt for ${decision_id} could not be bound to one exact private generation"
    AUTO_TUNE_DECISION_ABORT=1
    return 0
  fi
  if [[ ! -f "${omc_config_sh}" ]]; then
    if ! auto_tune_remove_captured_pending; then
      log_anomaly "session-start-auto-tune" \
        "could not retire the exact pre-mutation receipt for ${decision_id}; receipt retained"
      AUTO_TUNE_DECISION_ABORT=1
      return 0
    fi
    reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the conf write via omc-config.sh failed — no change applied"
    retryable_error=1
    return 0
  fi
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_RECEIPT:-0}" == "1" ]]; then
    return 75
  fi
  config_rc=0
  bash "${omc_config_sh}" set user \
    "objective_contract_min_files=${new_value}" >/dev/null 2>&1 \
    || config_rc=$?
  if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_CHILD:-0}" == "1" ]]; then
    return 75
  fi
  if ! settled_current="$(read_last_valid_user_objective_min_files \
      "${user_conf}")"; then
    log_anomaly "session-start-auto-tune" \
      "config writer result could not be read from one stable generation; receipt retained"
    AUTO_TUNE_DECISION_ABORT=1
    return 0
  fi
  [[ -n "${settled_current}" ]] || settled_current=4
  if [[ "${settled_current}" == "${new_value}" ]]; then
    if ! auto_tune_conf_matches_generation present \
        "${AUTO_TUNE_FINAL_DIGEST}" "${AUTO_TUNE_FINAL_MODE}"; then
      log_anomaly "session-start-auto-tune" \
        "config writer returned an unexpected final generation for ${decision_id}; receipt retained"
      AUTO_TUNE_DECISION_ABORT=1
      return 0
    fi
    if [[ "${config_rc}" -ne 0 ]]; then
      log_anomaly "session-start-auto-tune" \
        "config writer returned ${config_rc} after publishing ${decision_id}; finalizing from settled state"
    fi
    observed_receipt="$(printf '%s\n' "${pending_receipt}" \
      | jq -c '.phase = "write-observed"')" || {
      AUTO_TUNE_DECISION_ABORT=1
      return 0
    }
    if ! auto_tune_advance_captured_pending "${observed_receipt}"; then
      log_anomaly "session-start-auto-tune" \
        "config changed for ${decision_id}, but its write-observed receipt could not be published"
      AUTO_TUNE_DECISION_ABORT=1
      return 0
    fi
    if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_CONF:-0}" == "1" ]]; then
      return 75
    fi
    AUTO_TUNE_AUDIT_ROW="${audit_row}"
    AUTO_TUNE_AUDIT_DECISION_ID="${decision_id}"
    if _append_auto_tune_audit_row; then
      applied=1
      if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_AUDIT:-0}" == "1" ]]; then
        return 75
      fi
    else
      log_anomaly "session-start-auto-tune" \
        "config changed for ${decision_id}, but audit append failed; durable receipt retained for recovery"
      AUTO_TUNE_DECISION_ABORT=1
    fi
  elif auto_tune_conf_matches_generation "${AUTO_TUNE_ENTRY_STATE}" \
      "${AUTO_TUNE_ENTRY_DIGEST}" "${AUTO_TUNE_ENTRY_MODE}"; then
    if ! auto_tune_remove_captured_pending; then
      log_anomaly "session-start-auto-tune" \
        "config write failed but the exact prepared receipt changed before retirement; receipt retained"
      AUTO_TUNE_DECISION_ABORT=1
      return 0
    fi
    reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the conf write via omc-config.sh failed before publication (status ${config_rc}) — no change applied"
    retryable_error=1
  else
    log_anomaly "session-start-auto-tune" \
      "config writer settled an unexpected config generation (objective_contract_min_files=${settled_current}); receipt retained"
    AUTO_TUNE_DECISION_ABORT=1
  fi
}

auto_tune_audit_has_exact_row() {
  local expected_row="${1:-}" decision_id="${2:-}" snapshot=""
  [[ -n "${expected_row}" && -n "${decision_id}" ]] || return 1
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-audit-query.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_valid_jsonl_snapshot \
      "${AUDIT_LEDGER}" "${snapshot}" \
      "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
      || ! jq -se --arg id "${decision_id}" \
        --argjson expected "${expected_row}" \
    '[.[] | select(.decision_id? == $id)] == [$expected]' \
        "${snapshot}" >/dev/null 2>&1 \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${AUDIT_LEDGER}" "${snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null
}

auto_tune_audit_has_decision_id() {
  local decision_id="${1:-}" snapshot=""
  [[ -n "${decision_id}" ]] || return 1
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-audit-query.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_valid_jsonl_snapshot \
      "${AUDIT_LEDGER}" "${snapshot}" \
      "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}" \
      || ! jq -se --arg id "${decision_id}" \
        'map(select(.decision_id? == $id)) | length > 0' \
        "${snapshot}" >/dev/null 2>&1 \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${AUDIT_LEDGER}" "${snapshot}" \
        "${AUTO_TUNE_AUDIT_MAX_BYTES:-4194304}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null
}

build_auto_tune_state_json() {
  local ts="${1:-}" reason="${2:-}" applied="${3:-0}"
  jq -nc --argjson v 1 --argjson ts "${ts}" --arg reason "${reason}" \
    --argjson applied "${applied}" \
    '{_v: $v, last_check_ts: $ts, last_reason: $reason,
      last_applied: ($applied == 1)}'
}

# This hook intentionally rereads the user file because it mutates that same
# global authority. Mirror common.sh's exact-key, trimmed, last-valid parsing
# before any arithmetic: a malformed later duplicate (including an octal-like
# `08` or an oversized decimal) must not erase a prior valid threshold or reach
# Bash's arithmetic evaluator.
read_last_valid_objective_min_files_from_snapshot() {
  local conf="${1:-}" line="" value="" normalized="" result=""
  [[ -f "${conf}" && ! -L "${conf}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "objective_contract_min_files="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if normalized="$(_omc_normalize_config_value \
        objective_contract_min_files "${value}")"; then
      result="${normalized}"
    fi
  done < "${conf}"
  printf '%s' "${result}"
}

read_last_valid_user_objective_min_files() {
  local conf="${1:-}" snapshot="" result=""
  [[ ! -L "${conf}" ]] || return 1
  if [[ ! -e "${conf}" ]]; then
    [[ ! -e "${conf}" && ! -L "${conf}" ]] || return 1
    return 0
  fi
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-user-conf.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_safe_regular_snapshot "${conf}" "${snapshot}" \
      "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  result="$(read_last_valid_objective_min_files_from_snapshot \
    "${snapshot}")" || {
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  }
  if ! auto_tune_safe_regular_snapshot_is_current \
      "${conf}" "${snapshot}" "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null || return 1
  printf '%s' "${result}"
}

# The common library loads config once when sourced. A pre-existing durable
# omc transaction may roll that file back after this hook acquires the shared
# mutation lock, so re-read only the user-owned authority before tuning. A
# valid environment override remains authoritative; project config is never
# consulted because auto_tune is deliberately user-only.
auto_tune_authority_enabled_now() {
  local conf="${HOME}/.claude/oh-my-claude.conf"
  local line="" value="" normalized="" result="off" snapshot=""
  if [[ -n "${_omc_env_auto_tune:-}" ]]; then
    [[ "${_omc_env_auto_tune}" == "on" ]]
    return
  fi
  auto_tune_safe_regular_leaf_or_absent "${conf}" || return 1
  [[ -f "${conf}" ]] || return 1
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-authority-conf.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_safe_regular_snapshot "${conf}" "${snapshot}" \
      "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "auto_tune="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if normalized="$(_omc_normalize_config_value auto_tune "${value}")"; then
      result="${normalized}"
    fi
  done < "${snapshot}"
  if ! auto_tune_safe_regular_snapshot_is_current \
      "${conf}" "${snapshot}" "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null || return 1
  [[ "${result}" == "on" ]]
}

auto_tune_threshold_authority_is_shadowed() {
  local dir="" depth=0 conf="" line="" value="" normalized=""
  local snapshot="" shadowed=0
  [[ -z "${_omc_env_objective_contract_min_files:-}" ]] || return 0
  dir="${PWD}"
  while [[ "${dir}" != "/" && "${depth}" -lt 10 ]]; do
    conf="${dir}/.claude/oh-my-claude.conf"
    if [[ "${dir}" != "${HOME}" ]] \
        && { [[ -e "${conf}" ]] || [[ -L "${conf}" ]]; }; then
      snapshot="$(mktemp "${QP_ROOT}/.auto-tune-project-conf.XXXXXX")" \
        || return 0
      if ! auto_tune_capture_safe_regular_snapshot \
          "${conf}" "${snapshot}" \
          "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
        rm -f -- "${snapshot}" 2>/dev/null || true
        return 0
      fi
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == "objective_contract_min_files="* ]] || continue
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if normalized="$(_omc_normalize_config_value \
            objective_contract_min_files "${value}")"; then
          shadowed=1
          break
        fi
      done < "${snapshot}"
      if ! auto_tune_safe_regular_snapshot_is_current \
          "${conf}" "${snapshot}" \
          "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
        rm -f -- "${snapshot}" 2>/dev/null || true
        return 0
      fi
      rm -f -- "${snapshot}" 2>/dev/null || return 0
      [[ "${shadowed}" -eq 1 ]]
      return
    fi
    dir="${dir%/*}"
    [[ -n "${dir}" ]] || dir="/"
    depth=$((depth + 1))
  done
  return 1
}

auto_tune_conf_matches_generation() {
  local state="${1:-}" expected_digest="${2:-}" expected_mode="${3:-}"
  local conf="${HOME}/.claude/oh-my-claude.conf"
  local snapshot="" actual_digest="" actual_mode="" rc=0
  if [[ "${state}" == "absent" ]]; then
    [[ ! -e "${conf}" && ! -L "${conf}" ]]
    return
  fi
  [[ "${state}" == "present" ]] || return 1
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-conf-match.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_safe_regular_snapshot "${conf}" "${snapshot}" \
      "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  actual_digest="$(auto_tune_file_digest "${snapshot}")" || rc=1
  actual_mode="$(auto_tune_file_mode "${conf}" 2>/dev/null || true)"
  if [[ "${rc}" -ne 0 || "${actual_digest}" != "${expected_digest}" \
      || "${actual_mode}" != "${expected_mode}" ]] \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${conf}" "${snapshot}" "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null
}

AUTO_TUNE_ENTRY_STATE=""
AUTO_TUNE_ENTRY_DIGEST=""
AUTO_TUNE_ENTRY_MODE=""
AUTO_TUNE_FINAL_DIGEST=""
AUTO_TUNE_FINAL_MODE=""
prepare_auto_tune_conf_generations() {
  local conf="${1:-}" new_value="${2:-}" expected_current="${3:-}"
  local parent="" tmp="" source_snapshot="" grep_rc=0
  local source_digest="" source_mode="" observed_current=""
  parent="${conf%/*}"
  AUTO_TUNE_ENTRY_STATE="absent"
  AUTO_TUNE_ENTRY_DIGEST="none"
  AUTO_TUNE_ENTRY_MODE="none"
  if [[ -e "${conf}" || -L "${conf}" ]]; then
    source_snapshot="$(mktemp \
      "${QP_ROOT}/.auto-tune-conf-entry.XXXXXX")" || return 1
    if ! auto_tune_capture_safe_regular_snapshot \
        "${conf}" "${source_snapshot}" \
        "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
    AUTO_TUNE_ENTRY_STATE="present"
    source_digest="$(auto_tune_file_digest "${source_snapshot}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
    source_mode="$(auto_tune_file_mode "${conf}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
    AUTO_TUNE_ENTRY_DIGEST="${source_digest}"
    AUTO_TUNE_ENTRY_MODE="${source_mode}"
  fi
  if [[ "${AUTO_TUNE_ENTRY_STATE}" == "present" ]]; then
    observed_current="$(read_last_valid_objective_min_files_from_snapshot \
      "${source_snapshot}")" || {
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
  fi
  [[ -n "${observed_current}" ]] || observed_current=4
  if [[ ! "${expected_current}" =~ ^[0-9]+$ \
      || "${observed_current}" != "${expected_current}" ]]; then
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  tmp="$(mktemp "${parent}/.oh-my-claude.conf.auto-tune-preview.XXXXXX")" \
    || {
      [[ -z "${source_snapshot}" ]] \
        || rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    }
  if [[ "${AUTO_TUNE_ENTRY_STATE}" == "present" ]]; then
    grep -vE '^objective_contract_min_files=' "${source_snapshot}" > "${tmp}" \
      2>/dev/null || grep_rc=$?
    if [[ "${grep_rc}" -gt 1 ]]; then
      rm -f -- "${tmp}" 2>/dev/null || true
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  elif ! : > "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  if ! printf 'objective_contract_min_files=%s\n' "${new_value}" \
        >> "${tmp}" \
      || { [[ "${AUTO_TUNE_ENTRY_STATE}" == "present" ]] \
        && ! chmod "${source_mode}" "${tmp}"; } \
      || { [[ "${AUTO_TUNE_ENTRY_STATE}" == "absent" ]] \
        && ! chmod 600 "${tmp}"; }; then
    rm -f -- "${tmp}" 2>/dev/null || true
    [[ -z "${source_snapshot}" ]] \
      || rm -f -- "${source_snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ "${AUTO_TUNE_ENTRY_STATE}" == "present" ]]; then
    if [[ "$(auto_tune_file_mode "${conf}" 2>/dev/null || true)" \
          != "${source_mode}" ]] \
        || ! auto_tune_safe_regular_snapshot_is_current \
          "${conf}" "${source_snapshot}" \
          "${AUTO_TUNE_CONF_MAX_BYTES:-1048576}"; then
      rm -f -- "${tmp}" 2>/dev/null || true
      rm -f -- "${source_snapshot}" 2>/dev/null || true
      return 1
    fi
  elif [[ -e "${conf}" || -L "${conf}" ]]; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  if [[ -n "${source_snapshot}" ]]; then
    rm -f -- "${source_snapshot}" 2>/dev/null || {
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    }
  fi
  AUTO_TUNE_FINAL_DIGEST="$(auto_tune_file_digest "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  }
  AUTO_TUNE_FINAL_MODE="$(auto_tune_file_mode "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  }
  rm -f -- "${tmp}"
}

AUTO_TUNE_WINDOW_ROWS=""
AUTO_TUNE_EVIDENCE_SNAPSHOT=""
AUTO_TUNE_EVIDENCE_CUTOFF=""
AUTO_TUNE_EVIDENCE_CURRENT=""
AUTO_TUNE_EVIDENCE_SOURCE_DIR=""
AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID=""
AUTO_TUNE_EVIDENCE_INPUT_BYTES=0
AUTO_TUNE_EVIDENCE_MAX_INPUT_BYTES=67108864
AUTO_TUNE_LAST_EVIDENCE_SOURCE_DIGEST=""
AUTO_TUNE_LAST_EVIDENCE_SOURCE_MODE=""
AUTO_TUNE_LAST_EVIDENCE_SOURCE_SIZE=""

reserve_auto_tune_evidence_input_bytes() {
  local bytes="${1:-}"
  [[ "${bytes}" =~ ^[0-9]+$ \
      && "${AUTO_TUNE_EVIDENCE_INPUT_BYTES}" =~ ^[0-9]+$ \
      && "${AUTO_TUNE_EVIDENCE_MAX_INPUT_BYTES}" =~ ^[1-9][0-9]*$ ]] \
    || return 1
  (( bytes <= AUTO_TUNE_EVIDENCE_MAX_INPUT_BYTES \
      - AUTO_TUNE_EVIDENCE_INPUT_BYTES )) || return 1
  AUTO_TUNE_EVIDENCE_INPUT_BYTES=$((AUTO_TUNE_EVIDENCE_INPUT_BYTES + bytes))
}

append_auto_tune_evidence_file() {
  local source="${1:-}" max_bytes="${2:-8388608}"
  local source_digest="" source_mode="" source_size="" snapshot=""
  local aggregate_size="" rc=0
  [[ -n "${source}" && -n "${AUTO_TUNE_EVIDENCE_SNAPSHOT}" ]] || return 1
  AUTO_TUNE_LAST_EVIDENCE_SOURCE_DIGEST=""
  AUTO_TUNE_LAST_EVIDENCE_SOURCE_MODE=""
  AUTO_TUNE_LAST_EVIDENCE_SOURCE_SIZE=""
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-evidence-source.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_safe_regular_snapshot \
      "${source}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  source_size="$(auto_tune_file_size "${snapshot}")" || rc=1
  source_digest="$(auto_tune_file_digest "${snapshot}")" || rc=1
  source_mode="$(auto_tune_file_mode "${source}" 2>/dev/null || true)"
  if [[ "${rc}" -ne 0 || ! "${source_size}" =~ ^[0-9]+$ \
      || ! "${source_mode}" =~ ^[0-7]{3,4}$ ]] \
      || ! reserve_auto_tune_evidence_input_bytes "${source_size}" \
      || [[ -s "${snapshot}" \
        && -n "$(tail -c 1 "${snapshot}" 2>/dev/null)" ]]; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ ! -s "${snapshot}" ]]; then
    if ! auto_tune_safe_regular_snapshot_is_current \
        "${source}" "${snapshot}" "${max_bytes}"; then
      rm -f -- "${snapshot}" 2>/dev/null || true
      return 1
    fi
    AUTO_TUNE_LAST_EVIDENCE_SOURCE_DIGEST="${source_digest}"
    AUTO_TUNE_LAST_EVIDENCE_SOURCE_MODE="${source_mode}"
    AUTO_TUNE_LAST_EVIDENCE_SOURCE_SIZE="${source_size}"
    rm -f -- "${snapshot}" 2>/dev/null || return 1
    return 0
  fi
  # jq may accept a literal NUL outside a JSON string as numeric zero. Reject
  # the raw byte stream before either validation/filter pass so a sealed but
  # invalid ledger cannot manufacture timestamp/evidence authority. The
  # pinned reader above already rejected raw NUL, and every parse below uses
  # only that captured generation.
  if ! jq -e -c . "${snapshot}" >/dev/null 2>&1 \
      || ! jq -c --argjson cutoff "${AUTO_TUNE_EVIDENCE_CUTOFF}" \
    --argjson current "${AUTO_TUNE_EVIDENCE_CURRENT}" '
      def valid_gate_id:
        type == "string"
        and ((try capture(
            "^ge:(?<session>[A-Za-z0-9_.-]{1,128}):[1-9][0-9]{0,14}$"
          ) catch null) as $parts
          | ($parts != null)
          and (($parts.session | contains("..")) | not)
          and (($parts.session | test("^[.]+$")) | not));
      select(type == "object" and
        (.event_id | valid_gate_id) and
        (.ts | type) == "number" and
        (.ts | floor) == .ts and .ts >= $cutoff and .ts <= $current and
        .gate == "objective-contract" and
        (.event == "block" or .event == "post-block-reprompt"))
      | {
          event_id: .event_id,
          ts: .ts,
          host: (.host // null),
          gate: .gate,
          event: .event,
          block_count: (.block_count // null),
          block_cap: (.block_cap // null),
          details: (.details // null)
        }
    ' "${snapshot}" >> "${AUTO_TUNE_EVIDENCE_SNAPSHOT}" 2>/dev/null \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${source}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  AUTO_TUNE_LAST_EVIDENCE_SOURCE_DIGEST="${source_digest}"
  AUTO_TUNE_LAST_EVIDENCE_SOURCE_MODE="${source_mode}"
  AUTO_TUNE_LAST_EVIDENCE_SOURCE_SIZE="${source_size}"
  rm -f -- "${snapshot}" 2>/dev/null || return 1
  aggregate_size="$(auto_tune_file_size \
    "${AUTO_TUNE_EVIDENCE_SNAPSHOT}" 2>/dev/null || true)"
  [[ "${aggregate_size}" =~ ^[0-9]+$ \
      && "${aggregate_size}" -le 33554432 ]]
}

auto_tune_evidence_source_matches_signature() {
  local source="${1:-}" max_bytes="${2:-}" expected_digest="${3:-}"
  local expected_mode="${4:-}" expected_size="${5:-}" snapshot=""
  local actual_digest="" actual_mode="" actual_size="" rc=0
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-evidence-recheck.XXXXXX")" \
    || return 1
  if ! auto_tune_capture_safe_regular_snapshot \
      "${source}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  actual_digest="$(auto_tune_file_digest "${snapshot}")" || rc=1
  actual_size="$(auto_tune_file_size "${snapshot}")" || rc=1
  actual_mode="$(auto_tune_file_mode "${source}" 2>/dev/null || true)"
  if [[ "${rc}" -ne 0 || "${actual_digest}" != "${expected_digest}" \
      || "${actual_mode}" != "${expected_mode}" \
      || "${actual_size}" != "${expected_size}" ]] \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${source}" "${snapshot}" "${max_bytes}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null
}

append_auto_tune_live_session_evidence_locked() {
  local dir="${AUTO_TUNE_EVIDENCE_SOURCE_DIR}" sid="" state="" events=""
  local dir_mode="" transferred_to="" state_size="" state_snapshot=""
  local state_present=0 rc=0
  [[ -d "${dir}" && ! -L "${dir}" \
      && "$(auto_tune_file_identity "${dir}" 2>/dev/null || true)" \
        == "${AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID}" \
      && "$(auto_tune_file_owner "${dir}" 2>/dev/null || true)" \
        == "$(id -u)" ]] || return 1
  dir_mode="$(auto_tune_file_mode "${dir}" 2>/dev/null || true)"
  [[ "${dir_mode}" =~ ^[0-7]{3,4}$ \
      && $(( (8#${dir_mode}) & 8#22 )) -eq 0 ]] || return 1
  sid="${dir##*/}"
  validate_session_id "${sid}" 2>/dev/null || return 1
  [[ "${sid}" != "_watchdog" ]] || return 0

  state="${dir}/session_state.json"
  events="${dir}/gate_events.jsonl"
  [[ -e "${events}" || -L "${events}" ]] || return 0
  if [[ -e "${state}" || -L "${state}" ]]; then
    state_present=1
    state_snapshot="$(mktemp \
      "${QP_ROOT}/.auto-tune-session-state.XXXXXX")" || return 1
    if ! auto_tune_capture_safe_regular_snapshot \
        "${state}" "${state_snapshot}" 1048576; then
      rm -f -- "${state_snapshot}" 2>/dev/null || true
      return 1
    fi
    state_size="$(auto_tune_file_size "${state_snapshot}")" || rc=1
    if [[ "${rc}" -ne 0 || ! "${state_size}" =~ ^[0-9]+$ ]] \
        || ! reserve_auto_tune_evidence_input_bytes "${state_size}" \
        || ! jq -e 'type == "object"' \
          "${state_snapshot}" >/dev/null 2>&1; then
      rm -f -- "${state_snapshot}" 2>/dev/null || true
      return 1
    fi
    # Validate the complete transfer field before jq emits raw bytes. Bash
    # command substitution discards embedded NUL bytes, so validating only
    # after `-r` could turn an invalid `"target\u0000"` marker into the valid
    # `target` session ID and incorrectly suppress this ledger. Unrelated
    # decoded-NUL state is not transfer authority and must not hide an otherwise
    # valid evidence ledger; the snapshot reader already rejects raw NUL bytes.
    transferred_to="$(jq -er '
      (.resume_transferred_to // "")
      | select(
          type == "string"
          and test("^[A-Za-z0-9_.-]{1,128}$")
          and (contains("..") | not)
          and (test("^\\.+$") | not)
        )
    ' "${state_snapshot}" 2>/dev/null || true)"
    if [[ -n "${transferred_to}" ]] \
        && validate_session_id "${transferred_to}" 2>/dev/null; then
      if ! auto_tune_safe_regular_snapshot_is_current \
          "${state}" "${state_snapshot}" 1048576 \
          || [[ ! -d "${dir}" || -L "${dir}" \
            || "$(auto_tune_file_identity "${dir}" \
              2>/dev/null || true)" \
              != "${AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID}" ]]; then
        rm -f -- "${state_snapshot}" 2>/dev/null || true
        return 1
      fi
      rm -f -- "${state_snapshot}" 2>/dev/null || return 1
      return 0
    fi
  fi

  if ! append_auto_tune_evidence_file "${events}" \
      || [[ ! -d "${dir}" || -L "${dir}" \
        || "$(auto_tune_file_identity "${dir}" 2>/dev/null || true)" \
          != "${AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID}" ]]; then
    [[ -z "${state_snapshot}" ]] \
      || rm -f -- "${state_snapshot}" 2>/dev/null || true
    return 1
  fi
  if [[ "${state_present}" -eq 1 ]]; then
    if ! auto_tune_safe_regular_snapshot_is_current \
        "${state}" "${state_snapshot}" 1048576; then
      rm -f -- "${state_snapshot}" 2>/dev/null || true
      return 1
    fi
    rm -f -- "${state_snapshot}" 2>/dev/null || return 1
  elif [[ -e "${state}" || -L "${state}" ]]; then
    return 1
  fi
}

read_auto_tune_evidence_window_locked() {
  local cutoff="${1:-}" current="${2:-}" snapshot=""
  local global_exists=0 global_digest="" global_mode="" global_size=""
  local state_root_id="" state_root_mode="" candidate_count=0
  local candidate="" rc=0 find_status_seen=0 find_status=""
  AUTO_TUNE_WINDOW_ROWS=""
  snapshot="$(mktemp "${QP_ROOT}/.auto-tune-evidence.XXXXXX")" || return 1
  if ! chmod 600 "${snapshot}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    return 1
  fi
  AUTO_TUNE_EVIDENCE_SNAPSHOT="${snapshot}"
  AUTO_TUNE_EVIDENCE_CUTOFF="${cutoff}"
  AUTO_TUNE_EVIDENCE_CURRENT="${current}"
  AUTO_TUNE_EVIDENCE_INPUT_BYTES=0

  if [[ -e "${GATE_EVENTS_FILE}" || -L "${GATE_EVENTS_FILE}" ]]; then
    global_exists=1
    if ! append_auto_tune_evidence_file \
        "${GATE_EVENTS_FILE}" 33554432; then
      rc=1
    else
      global_digest="${AUTO_TUNE_LAST_EVIDENCE_SOURCE_DIGEST}"
      global_mode="${AUTO_TUNE_LAST_EVIDENCE_SOURCE_MODE}"
      global_size="${AUTO_TUNE_LAST_EVIDENCE_SOURCE_SIZE}"
      [[ -n "${global_digest}" && -n "${global_mode}" \
          && "${global_size}" =~ ^[0-9]+$ ]] || rc=1
    fi
  fi

  if [[ "${rc}" -eq 0 && ( -e "${STATE_ROOT}" || -L "${STATE_ROOT}" ) ]]; then
    if [[ ! -d "${STATE_ROOT}" || -L "${STATE_ROOT}" \
        || "$(auto_tune_file_owner "${STATE_ROOT}" 2>/dev/null || true)" \
          != "$(id -u)" ]]; then
      rc=1
    else
      state_root_id="$(auto_tune_file_identity "${STATE_ROOT}")" || rc=1
      state_root_mode="$(auto_tune_file_mode "${STATE_ROOT}")" || rc=1
      if [[ ! "${state_root_mode}" =~ ^[0-7]{3,4}$ ]] \
          || (( ((8#${state_root_mode}) & 8#22) != 0 )); then
        rc=1
      fi
    fi
  fi

  if [[ "${rc}" -eq 0 && -n "${state_root_id}" ]]; then
    # Per-session producers replace gate_events.jsonl while holding this same
    # state mutex. A short lock budget makes contention retryable on the next
    # SessionStart instead of stalling the status path for many seconds per
    # active session; partial evidence never advances the weekly cadence.
    local OMC_STATE_LOCK_MAX_ATTEMPTS=5
    while IFS= read -r -d '' candidate; do
      if [[ "${candidate}" == __OMC_AUTO_TUNE_FIND_STATUS__:* ]]; then
        find_status="${candidate#__OMC_AUTO_TUNE_FIND_STATUS__:}"
        if [[ ! "${find_status}" =~ ^[0-9]+$ \
            || "${find_status}" -ne 0 ]]; then
          rc=1
        fi
        find_status_seen=1
        break
      fi
      [[ "${candidate##*/}" != "_watchdog" ]] || continue
      candidate_count=$((candidate_count + 1))
      if [[ "${candidate_count}" -gt 4096 ]]; then
        rc=1
        break
      fi
      [[ -e "${candidate}/gate_events.jsonl" \
          || -L "${candidate}/gate_events.jsonl" ]] || continue
      AUTO_TUNE_EVIDENCE_SOURCE_DIR="${candidate}"
      AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID="$(auto_tune_file_identity \
        "${candidate}" 2>/dev/null || true)"
      if [[ -z "${AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID}" ]] \
          || ! _with_lockdir "${candidate}/.state.lock" \
            "session-start-auto-tune-evidence" \
            append_auto_tune_live_session_evidence_locked; then
        rc=1
        break
      fi
    done < <(
      _auto_tune_find_rc=0
      find -P "${STATE_ROOT}" -maxdepth 1 -type d \
        ! -path "${STATE_ROOT}" ! -name '.*' -print0 2>/dev/null \
        || _auto_tune_find_rc=$?
      printf '__OMC_AUTO_TUNE_FIND_STATUS__:%s\0' \
        "${_auto_tune_find_rc}"
    )
    [[ "${find_status_seen}" -eq 1 ]] || rc=1
    if [[ "${rc}" -eq 0 ]] \
        && [[ ! -d "${STATE_ROOT}" || -L "${STATE_ROOT}" \
          || "$(auto_tune_file_identity "${STATE_ROOT}" \
            2>/dev/null || true)" != "${state_root_id}" \
          || "$(auto_tune_file_mode "${STATE_ROOT}" \
            2>/dev/null || true)" != "${state_root_mode}" ]]; then
      rc=1
    fi
  fi

  if [[ "${rc}" -eq 0 ]]; then
    if [[ "${global_exists}" -eq 1 ]]; then
      auto_tune_evidence_source_matches_signature \
        "${GATE_EVENTS_FILE}" 33554432 "${global_digest}" \
        "${global_mode}" "${global_size}" || rc=1
    elif [[ -e "${GATE_EVENTS_FILE}" || -L "${GATE_EVENTS_FILE}" ]]; then
      rc=1
    fi
  fi
  if [[ "${rc}" -eq 0 ]]; then
    # Resume handoff copies a session ledger byte-for-byte into its target.
    # Durable producer-issued IDs make that copy exactly deduplicable without
    # collapsing two genuine same-second events. Legacy rows without an ID are
    # intentionally excluded from this mutation-authorizing evidence window;
    # they remain report-readable but cannot safely prove unique observations.
    # A reused ID with conflicting payloads poisons the snapshot and fails
    # closed rather than allowing either payload to influence global config.
    AUTO_TUNE_WINDOW_ROWS="$(jq -sc '
      group_by(.event_id) as $groups
      | if all($groups[];
          ([.[] | del(.event_id)] | unique | length) == 1)
        then $groups[] | .[0]
        else error("conflicting gate event identity")
        end
    ' "${snapshot}" 2>/dev/null)" || rc=1
  fi
  rm -f -- "${snapshot}" 2>/dev/null || rc=1
  AUTO_TUNE_EVIDENCE_SNAPSHOT=""
  AUTO_TUNE_EVIDENCE_CUTOFF=""
  AUTO_TUNE_EVIDENCE_CURRENT=""
  AUTO_TUNE_EVIDENCE_SOURCE_DIR=""
  AUTO_TUNE_EVIDENCE_SOURCE_DIR_ID=""
  AUTO_TUNE_EVIDENCE_INPUT_BYTES=0
  [[ "${rc}" -eq 0 ]]
}

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

QP_ROOT="${HOME}/.claude/quality-pack"
STATE_FILE="${QP_ROOT}/auto-tune-state.json"
AUDIT_LEDGER="${QP_ROOT}/auto-tune.jsonl"
PENDING_FILE="${QP_ROOT}/auto-tune-pending.json"
PENDING_RETIRED_FILE="${QP_ROOT}/.auto-tune-pending.retired"
PENDING_RETIRE_CLAIM_FILE="${QP_ROOT}/.auto-tune-pending.retire-claim.json"
PENDING_ADVANCE_STAGE_FILE="${QP_ROOT}/.auto-tune-pending.advance-stage"
GATE_EVENTS_FILE="${QP_ROOT}/gate_events.jsonl"
AUTO_TUNE_STATE_MAX_BYTES=16384
AUTO_TUNE_PENDING_MAX_BYTES=32768
AUTO_TUNE_PENDING_RETIRE_CLAIM_MAX_BYTES=4096
AUTO_TUNE_AUDIT_MAX_BYTES=4194304
AUTO_TUNE_CONF_MAX_BYTES=1048576
AUTO_TUNE_QP_ROOT_ID=""

# Disabled sessions stay cheap unless a durable receipt already exists. An
# applied decision must finish its audit/cadence transaction even if the user
# turns auto_tune off after the config write; disabled authority only prevents
# a new decision from starting.
AUTO_TUNE_INITIAL_ENABLED=0
is_auto_tune_enabled && AUTO_TUNE_INITIAL_ENABLED=1
if [[ "${AUTO_TUNE_INITIAL_ENABLED}" -eq 0 \
    && ! -e "${PENDING_FILE}" && ! -L "${PENDING_FILE}" \
    && ! -e "${PENDING_RETIRED_FILE}" \
    && ! -L "${PENDING_RETIRED_FILE}" \
    && ! -e "${PENDING_RETIRE_CLAIM_FILE}" \
    && ! -L "${PENDING_RETIRE_CLAIM_FILE}" \
    && ! -e "${PENDING_ADVANCE_STAGE_FILE}" \
    && ! -L "${PENDING_ADVANCE_STAGE_FILE}" ]] \
    && ! auto_tune_pending_initial_temp_exists; then
  exit 0
fi

# Every control stage and rename is relative to this directory. Reject an
# aliased, foreign-owned, or group/world-writable root before even creating the
# per-session guard; leaf-only checks cannot prevent mktemp/mv from being
# redirected when the immediate parent itself is a symlink.
if ! mkdir -p "${QP_ROOT}" 2>/dev/null \
    || ! auto_tune_control_root_is_safe "${QP_ROOT}" \
    || ! AUTO_TUNE_QP_ROOT_ID="$(auto_tune_file_identity "${QP_ROOT}")"; then
  printf '%s\n' \
    'session-start-auto-tune: refusing unsafe quality-pack control root' >&2
  exit 0
fi

# Per-session guard FIRST, before any real work — the check below reads
# and parses gate_events.jsonl and can mutate the user's conf, unlike
# the cheap version-compare in session-start-whats-new.sh, so this
# guards the whole evaluation, not just a message emission.
ensure_session_dir
existing_checked="$(read_state "auto_tune_checked" 2>/dev/null || true)"
if [[ "${existing_checked}" == "1" ]]; then
  exit 0
fi
write_state "auto_tune_checked" "1"

# Serialize the complete decision/publication transaction across sessions.
# Install, uninstall, watchdog setup, omc-config, and switch-tier use this same
# directory mutex; the nested omc-config child borrows our exact pid/token.
trap 'release_auto_tune_operation_lock' EXIT
acquire_auto_tune_operation_lock || exit 0
if ! auto_tune_control_root_is_current; then
  log_anomaly "session-start-auto-tune" \
    "quality-pack control root changed before transaction admission"
  exit 0
fi

# Resolve the two recoverable multi-link/rename intermediates before the
# generic single-link control-artifact admission below. Each recovery path
# independently validates the exact inode, bytes, mode, and durable claim.
if ! auto_tune_recover_pending_initial_link; then
  log_anomaly "session-start-auto-tune" \
    "could not validate and settle an interrupted atomic pending publication"
  exit 0
fi
if ! auto_tune_recover_retired_pending; then
  log_anomaly "session-start-auto-tune" \
    "could not validate and settle the pending-receipt transaction quarantine: ${PENDING_RETIRED_FILE}"
  exit 0
fi
if [[ -e "${PENDING_RETIRED_FILE}" || -L "${PENDING_RETIRED_FILE}" \
    || -e "${PENDING_RETIRE_CLAIM_FILE}" \
    || -L "${PENDING_RETIRE_CLAIM_FILE}" \
    || -e "${PENDING_ADVANCE_STAGE_FILE}" \
    || -L "${PENDING_ADVANCE_STAGE_FILE}" ]]; then
  log_anomaly "session-start-auto-tune" \
    "pending-receipt transaction recovery left unresolved private artifacts"
  exit 0
fi

unsafe_control_leaf=""
for control_leaf in "${STATE_FILE}" "${PENDING_FILE}" \
    "${PENDING_RETIRED_FILE}" "${PENDING_RETIRE_CLAIM_FILE}" \
    "${PENDING_ADVANCE_STAGE_FILE}" "${AUDIT_LEDGER}"; do
  if [[ -e "${control_leaf}" || -L "${control_leaf}" ]] \
      && ! auto_tune_owned_single_regular_file "${control_leaf}"; then
    unsafe_control_leaf="${control_leaf}"
    break
  fi
done
if [[ -n "${unsafe_control_leaf}" ]]; then
  log_anomaly "session-start-auto-tune" \
    "refusing aliased, multiply-linked, foreign-owned, or non-regular control artifact: ${unsafe_control_leaf}"
  exit 0
fi
for private_control_leaf in "${STATE_FILE}" "${PENDING_FILE}" \
    "${PENDING_RETIRED_FILE}" "${PENDING_RETIRE_CLAIM_FILE}" \
    "${PENDING_ADVANCE_STAGE_FILE}"; do
  if [[ -e "${private_control_leaf}" \
      && "$(auto_tune_file_mode "${private_control_leaf}" \
        2>/dev/null || true)" != "600" ]]; then
    log_anomaly "session-start-auto-tune" \
      "refusing non-private control artifact: ${private_control_leaf}"
    exit 0
  fi
done
for bounded_control_leaf in "${STATE_FILE}" "${PENDING_FILE}" \
    "${PENDING_RETIRED_FILE}" "${PENDING_RETIRE_CLAIM_FILE}" \
    "${PENDING_ADVANCE_STAGE_FILE}" "${AUDIT_LEDGER}"; do
  [[ -e "${bounded_control_leaf}" ]] || continue
  case "${bounded_control_leaf}" in
    "${STATE_FILE}") control_max_bytes="${AUTO_TUNE_STATE_MAX_BYTES}" ;;
    "${PENDING_FILE}"|"${PENDING_RETIRED_FILE}"|\
      "${PENDING_ADVANCE_STAGE_FILE}")
      control_max_bytes="${AUTO_TUNE_PENDING_MAX_BYTES}"
      ;;
    "${PENDING_RETIRE_CLAIM_FILE}")
      control_max_bytes="${AUTO_TUNE_PENDING_RETIRE_CLAIM_MAX_BYTES}"
      ;;
    "${AUDIT_LEDGER}") control_max_bytes="${AUTO_TUNE_AUDIT_MAX_BYTES}" ;;
    *) exit 0 ;;
  esac
  control_size="$(auto_tune_file_size "${bounded_control_leaf}" \
    2>/dev/null || true)"
  if [[ ! "${control_size}" =~ ^[0-9]+$ ]] \
      || (( control_size > control_max_bytes )); then
    log_anomaly "session-start-auto-tune" \
      "refusing oversized control artifact: ${bounded_control_leaf}"
    exit 0
  fi
done
if [[ -e "${AUDIT_LEDGER}" ]] \
    && ! auto_tune_jsonl_is_complete_and_valid "${AUDIT_LEDGER}" \
      "${AUTO_TUNE_AUDIT_MAX_BYTES}"; then
  log_anomaly "session-start-auto-tune" \
    "malformed or oversized audit ledger requires manual inspection: ${AUDIT_LEDGER}"
  exit 0
fi
if [[ -e "${AUDIT_LEDGER}" ]] \
    && ! auto_tune_tighten_audit_mode; then
  log_anomaly "session-start-auto-tune" \
    "could not replace the validated legacy audit ledger with a private generation: ${AUDIT_LEDGER}"
  exit 0
fi
# Settle every older config/model transaction before reading a pending receipt,
# cadence, evidence, or the current threshold. Otherwise a nested omc-config
# call could first roll back an older generation and then apply a "one-step"
# decision calculated from the abandoned live bytes.
omc_config_sh="${HOME}/.claude/skills/autowork/scripts/omc-config.sh"
if [[ ! -f "${omc_config_sh}" ]] \
    || ! bash "${omc_config_sh}" recover-only >/dev/null 2>&1; then
  log_anomaly "session-start-auto-tune" \
    "could not settle shared config/model transaction metadata before evaluation"
  exit 0
fi
now_ts="$(now_epoch)"
seven_days=$((7 * 86400))
if ! _omc_canonical_uint_in_range "${now_ts}" 0 9999999999; then
  log_anomaly "session-start-auto-tune" \
    "invalid current epoch from now_epoch: ${now_ts}"
  exit 0
fi

# Recover a crash after the durable decision receipt was published. A prepared
# receipt is bound to the exact entry config generation and can only be safely
# cancelled while that generation is still live. After the writer returns, the
# receipt is atomically advanced to `write-observed` only by the still-running
# parent after its child returns and the exact final generation is observed.
# Recovery never upgrades `prepared` from config bytes alone: an independent
# serialized writer can legitimately produce those same deterministic bytes.
if [[ -f "${PENDING_FILE}" ]]; then
  if ! auto_tune_capture_pending_generation; then
    log_anomaly "session-start-auto-tune" \
      "pending receipt changed or could not be captured as one exact private generation: ${PENDING_FILE}"
    exit 0
  fi
  pending_json="${AUTO_TUNE_PENDING_CAPTURE_JSON}"
  if ! auto_tune_pending_snapshot_test_barrier \
      || ! auto_tune_pending_generation_is_current; then
    log_anomaly "session-start-auto-tune" \
      "pending receipt generation changed after its bounded snapshot: ${PENDING_FILE}"
    exit 0
  fi
  if [[ "$(printf '%s' "${pending_json}" \
      | jq -s 'length' 2>/dev/null || true)" \
        != "1" ]] \
      || ! jq -e '
      type == "object" and
      ((keys | sort) == ["decision_id","entry_digest","entry_mode",
        "entry_state","evidence","final_digest","final_mode","host",
        "new","oc_blocks","oc_pct","oc_reprompts","old","phase",
        "reason","ts","version"]) and
      .version == 1 and
      (.phase == "prepared" or .phase == "write-observed") and
      (.decision_id | type == "string" and length > 0 and length <= 160 and
        test("^auto-tune-[0-9]+-[0-9]+-[0-9]+-[0-9]+$")) and
      (.ts | type == "number" and floor == . and . >= 0 and . <= 9999999999) and
      (.old | type == "number" and floor == . and . >= 2 and . <= 11) and
      (.new | type == "number" and floor == . and . >= 3 and . <= 12) and
      (.new == (.old + 1)) and
      (.reason | type == "string" and length > 0 and length <= 2048 and
        (test("[\u0000-\u001f\u007f]") | not)) and
      (.evidence | type == "string" and length > 0 and length <= 1024 and
        (test("[\u0000-\u001f\u007f]") | not)) and
      (.host | type == "string" and length > 0 and length <= 512 and
        test("^[A-Za-z0-9._-]+$")) and
      (.oc_pct | type == "number" and floor == . and . >= 0 and . <= 100) and
      (.oc_pct >= 50) and
      (.oc_blocks | type == "number" and floor == . and . >= 10 and . <= 2147483647) and
      (.oc_reprompts | type == "number" and floor == . and . >= 0 and . <= 2147483647) and
      (.oc_pct == (if .oc_reprompts > .oc_blocks then 100
        else ((.oc_reprompts * 100 / .oc_blocks) | floor) end)) and
      (.entry_state == "present" or .entry_state == "absent") and
      (if .entry_state == "present" then
        (.entry_digest | type == "string" and
          test("^cksum:[0-9]+ [0-9]+$")) and
        (.entry_mode | type == "string" and test("^[0-7]{3,4}$"))
       else .entry_digest == "none" and .entry_mode == "none" end) and
      (.final_digest | type == "string" and
        test("^cksum:[0-9]+ [0-9]+$")) and
      (.final_mode | type == "string" and test("^[0-7]{3,4}$"))
    ' <<<"${pending_json}" >/dev/null 2>&1; then
    log_anomaly "session-start-auto-tune" \
      "malformed pending receipt requires manual inspection: ${PENDING_FILE}"
    exit 0
  fi
  IFS=$'\t' read -r pending_phase pending_decision_id pending_ts \
    pending_old pending_new pending_reason pending_evidence pending_host \
    pending_pct pending_blocks pending_reprompts pending_entry_state \
    pending_entry_digest pending_entry_mode pending_final_digest \
    pending_final_mode < <(jq -r '[.phase, .decision_id, .ts, .old, .new,
      .reason, .evidence, .host, .oc_pct, .oc_blocks, .oc_reprompts,
      .entry_state, .entry_digest, .entry_mode, .final_digest, .final_mode]
      | @tsv' <<<"${pending_json}") || {
    log_anomaly "session-start-auto-tune" \
      "pending receipt snapshot could not be projected: ${PENDING_FILE}"
    exit 0
  }
  expected_pending_reason="reprompt-rate ${pending_pct}% over ${pending_blocks} objective-contract blocks (>=50% over-firing bar, >=10-block signal floor, 7-day window) — raised objective_contract_min_files ${pending_old} -> ${pending_new}"
  expected_pending_evidence="reprompt_rate_pct=${pending_pct} blocks=${pending_blocks} reprompts=${pending_reprompts} window_days=7"
  if ! _omc_canonical_uint_in_range "${pending_ts}" 0 9999999999 \
      || ! _omc_canonical_uint_in_range "${pending_old}" 2 11 \
      || ! _omc_canonical_uint_in_range "${pending_new}" 3 12 \
      || ! _omc_canonical_uint_in_range "${pending_pct}" 0 100 \
      || ! _omc_canonical_uint_in_range "${pending_blocks}" 10 2147483647 \
      || ! _omc_canonical_uint_in_range "${pending_reprompts}" 0 2147483647 \
      || (( pending_new != pending_old + 1 )) \
      || (( pending_pct < 50 )) \
      || (( pending_ts > now_ts )) \
      || [[ "${pending_decision_id}" != "auto-tune-${pending_ts}-"* ]] \
      || [[ ! "${pending_host}" =~ ^[A-Za-z0-9._-]+$ ]] \
      || [[ "${pending_reason}" != "${expected_pending_reason}" ]] \
      || [[ "${pending_evidence}" != "${expected_pending_evidence}" ]] \
      || { [[ "${pending_entry_state}" == "present" ]] \
        && { ! auto_tune_digest_is_valid "${pending_entry_digest}" \
          || [[ ! "${pending_entry_mode}" =~ ^[0-7]{3,4}$ ]]; }; } \
      || ! auto_tune_digest_is_valid "${pending_final_digest}" \
      || [[ ! "${pending_final_mode}" =~ ^[0-7]{3,4}$ ]]; then
    log_anomaly "session-start-auto-tune" \
      "pending receipt contains impossible numeric values: ${PENDING_FILE}"
    exit 0
  fi
  pending_audit_row="$(jq -nc \
    --argjson v 1 --arg decision_id "${pending_decision_id}" \
    --argjson ts "${pending_ts}" \
    --arg flag "objective_contract_min_files" \
    --argjson old "${pending_old}" --argjson new "${pending_new}" \
    --arg evidence "${pending_evidence}" --arg host "${pending_host}" \
    '{_v:$v, decision_id:$decision_id, ts:$ts, flag:$flag, old:$old,
      new:$new, evidence:$evidence, host:$host}')" || exit 0

  pending_applied=0
  if [[ "${pending_phase}" == "prepared" ]]; then
    if auto_tune_conf_matches_generation "${pending_entry_state}" \
        "${pending_entry_digest}" "${pending_entry_mode}"; then
      if [[ -e "${AUDIT_LEDGER}" ]] \
          && auto_tune_audit_has_decision_id "${pending_decision_id}"; then
        log_anomaly "session-start-auto-tune" \
          "pre-mutation decision unexpectedly collides with an audit row; receipt retained"
        exit 0
      fi
      auto_tune_remove_captured_pending || {
        log_anomaly "session-start-auto-tune" \
          "could not clear the exact pre-mutation pending receipt generation: ${PENDING_FILE}"
        exit 0
      }
    else
      log_anomaly "session-start-auto-tune" \
        "prepared decision no longer matches its exact entry generation; writer authorship was not observed, so receipt is retained"
      exit 0
    fi
  else
    # This phase is the parent-authored attestation that its nested writer
    # returned and the exact final generation was observed. Later user edits
    # may legitimately change unrelated config bytes before recovery; they do
    # not erase the historical application that still needs audit settlement.
    pending_applied=1
  fi
  if [[ "${pending_applied}" -eq 1 ]]; then
    if auto_tune_audit_has_exact_row "${pending_audit_row}" \
        "${pending_decision_id}"; then
      :
    elif [[ -e "${AUDIT_LEDGER}" ]] \
        && auto_tune_audit_has_decision_id "${pending_decision_id}"; then
      log_anomaly "session-start-auto-tune" \
        "pending decision ID collides with a non-canonical audit row; receipt retained"
      exit 0
    elif ! append_auto_tune_audit_row "${pending_audit_row}" \
        "${pending_decision_id}"; then
      log_anomaly "session-start-auto-tune" \
        "pending applied decision could not publish its audit row"
      exit 0
    fi
    if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_AUDIT:-0}" == "1" ]]; then
      exit 75
    fi
    pending_state="$(build_auto_tune_state_json \
      "${pending_ts}" "${pending_reason}" 1)" || exit 0
    if ! write_auto_tune_json_atomic "${STATE_FILE}" "${pending_state}"; then
      log_anomaly "session-start-auto-tune" \
        "pending applied decision could not publish cadence state"
      exit 0
    fi
    if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_STATE:-0}" == "1" ]]; then
      exit 75
    fi
    auto_tune_remove_captured_pending || {
      log_anomaly "session-start-auto-tune" \
        "applied decision finalized but its exact pending receipt generation could not be removed"
      exit 0
    }
    if auto_tune_evidence_leaf_is_safe; then
      record_gate_event "auto-tune" "checked" \
        "applied=1" "oc_blocks=${pending_blocks}" \
        "oc_reprompts=${pending_reprompts}" \
        "decision_id=${pending_decision_id}"
    else
      log_anomaly "session-start-auto-tune" \
        "recovered decision without writing to an unsafe evidence ledger"
    fi
    log_hook "session-start-auto-tune" \
      "recovered auto-tune decision ${pending_decision_id}: ${pending_reason}"
    msg="**Auto-tune applied (recovered).** Raised \`objective_contract_min_files\` ${pending_old} -> ${pending_new} — the durable write-observed receipt bound the exact resulting config generation, and this session completed its audit/cadence publication (${pending_pct}% reprompt-rate over ${pending_blocks} blocks). Revert with \`objective_contract_min_files=${pending_old}\` in \`~/.claude/oh-my-claude.conf\`, or turn the mechanism off with \`auto_tune=off\`."
    payload="$(jq -nc --arg context "${msg}" '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $context
      }
    }' 2>/dev/null || true)"
    [[ -n "${payload}" ]] && printf '%s\n' "${payload}"
    exit 0
  fi
fi

if ! auto_tune_authority_enabled_now; then
  log_hook "session-start-auto-tune" \
    "auto-tune disabled by the settled user configuration"
  exit 0
fi

last_check_ts=0
if [[ -f "${STATE_FILE}" ]]; then
  state_snapshot="$(mktemp "${QP_ROOT}/.auto-tune-state-read.XXXXXX")" \
    || exit 0
  if ! auto_tune_capture_safe_regular_snapshot \
      "${STATE_FILE}" "${state_snapshot}" "${AUTO_TUNE_STATE_MAX_BYTES}" \
      || [[ ! -s "${state_snapshot}" \
        || -n "$(tail -c 1 "${state_snapshot}" 2>/dev/null)" ]] \
      || ! last_check_ts="$(jq -er '
      select(type == "object" and
      (((keys | sort) == ["_v","last_applied","last_check_ts",
          "last_reason"] and ._v == 1) or
       ((keys | sort) == ["last_applied","last_check_ts","last_reason"]
          and (has("_v") | not))) and
      (.last_check_ts | type == "number" and floor == . and
        . >= 0 and . <= 9999999999) and
      (.last_reason | type == "string" and length <= 4096) and
      (.last_applied | type == "boolean") and
      all(.. | strings; index("\u0000") == null) and
      all(.. | objects | keys[]; index("\u0000") == null))
      | .last_check_ts
    ' "${state_snapshot}" 2>/dev/null)" \
      || ! auto_tune_safe_regular_snapshot_is_current \
        "${STATE_FILE}" "${state_snapshot}" \
        "${AUTO_TUNE_STATE_MAX_BYTES}"; then
    rm -f -- "${state_snapshot}" 2>/dev/null || true
    log_anomaly "session-start-auto-tune" \
      "malformed cadence state requires manual inspection: ${STATE_FILE}"
    exit 0
  fi
  rm -f -- "${state_snapshot}" 2>/dev/null || exit 0
  if ! _omc_canonical_uint_in_range "${last_check_ts}" 0 9999999999 \
      || (( last_check_ts > now_ts )); then
    log_anomaly "session-start-auto-tune" \
      "invalid/future cadence state requires manual inspection: ${last_check_ts}"
    exit 0
  fi
fi

if (( last_check_ts != 0 )) && (( now_ts - last_check_ts < seven_days )); then
  exit 0
fi

# A valid environment or project threshold outranks the user file this hook is
# authorized to mutate. Writing the hidden lower-precedence value would have no
# live effect and would surprise the user when that temporary authority goes
# away, so record a throttled no-op instead.
if auto_tune_threshold_authority_is_shadowed; then
  shadow_reason="objective_contract_min_files is controlled by a higher-precedence environment or project setting — user config left unchanged"
  shadow_state="$(build_auto_tune_state_json \
    "${now_ts}" "${shadow_reason}" 0)" || exit 0
  if ! write_auto_tune_json_atomic "${STATE_FILE}" "${shadow_state}"; then
    log_anomaly "session-start-auto-tune" \
      "could not publish cadence state for a shadowed threshold"
    exit 0
  fi
  if auto_tune_evidence_leaf_is_safe; then
    record_gate_event "auto-tune" "checked" \
      "applied=0" "reason=authority-shadowed"
  fi
  log_hook "session-start-auto-tune" "${shadow_reason}"
  exit 0
fi

# --- Evidence rule ---------------------------------------------------
if ! auto_tune_evidence_leaf_is_safe; then
  log_anomaly "session-start-auto-tune" \
    "refusing aliased, multiply-linked, foreign-owned, or group/world-writable evidence ledger"
  exit 0
fi
cutoff_ts=$(( now_ts - seven_days ))
oc_blocks=0
oc_reprompts=0
reason=""
applied=0
applied_finalized=0
evidence_error=0
retryable_error=0

if ! with_cross_session_log_lock "${GATE_EVENTS_FILE}" \
    read_auto_tune_evidence_window_locked "${cutoff_ts}" "${now_ts}"; then
  evidence_error=1
  reason="invalid, truncated, oversized, busy, or unstable global/live gate-event evidence — refusing to auto-tune from a partial snapshot"
elif [[ -z "${AUTO_TUNE_WINDOW_ROWS}" ]]; then
  reason="no gate_events.jsonl ledger yet — nothing to evaluate"
else
  oc_blocks="$(printf '%s\n' "${AUTO_TUNE_WINDOW_ROWS}" \
    | jq -c 'select(.gate == "objective-contract" and .event == "block")' 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  oc_reprompts="$(printf '%s\n' "${AUTO_TUNE_WINDOW_ROWS}" \
    | jq -c 'select(.gate == "objective-contract" and .event == "post-block-reprompt")' 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  [[ "${oc_blocks}" =~ ^[0-9]+$ ]] || oc_blocks=0
  [[ "${oc_reprompts}" =~ ^[0-9]+$ ]] || oc_reprompts=0
fi

if (( evidence_error == 1 )); then
  log_anomaly "session-start-auto-tune" "${reason}"
  exit 0
elif (( oc_blocks < 10 )); then
  reason="insufficient signal (${oc_blocks} objective-contract block(s) in the last 7 days, need >=10)"
else
  if (( oc_reprompts > oc_blocks )); then
    oc_pct=100
  else
    oc_pct=$(( oc_reprompts * 100 / oc_blocks ))
  fi

  if (( oc_pct < 50 )); then
    reason="calibrated (${oc_reprompts}/${oc_blocks} = ${oc_pct}% reprompt-rate over the last 7 days — below the 50% over-firing bar; no change)"
  else
    user_conf="${HOME}/.claude/oh-my-claude.conf"
    if ! current="$(read_last_valid_user_objective_min_files \
        "${user_conf}")"; then
      reason="objective_contract_min_files could not be read from one bounded stable user-config generation — leaving it untouched"
      retryable_error=1
      current=""
    fi
    [[ -n "${current}" ]] || current=4

    if (( retryable_error == 1 )); then
      :
    elif (( current < 2 || current > 12 )); then
      reason="objective_contract_min_files=${current} is outside auto-tune's managed range [2,12] (0 is the documented volume-arm-disable sentinel; anything above 12 is an explicit override) — leaving it untouched despite a ${oc_pct}% reprompt-rate signal"
    else
      new_value=$(( current + 1 ))
      (( new_value > 12 )) && new_value=12
      if (( new_value == current )); then
        reason="objective_contract_min_files already at the auto-tune ceiling (${current}) — a ${oc_pct}% reprompt-rate signal was present but no further raise is available this cycle"
      else
        reason="reprompt-rate ${oc_pct}% over ${oc_blocks} objective-contract blocks (>=50% over-firing bar, >=10-block signal floor, 7-day window) — raised objective_contract_min_files ${current} -> ${new_value}"
        evidence="reprompt_rate_pct=${oc_pct} blocks=${oc_blocks} reprompts=${oc_reprompts} window_days=7"
        decision_id="auto-tune-${now_ts}-$$-${RANDOM}-${RANDOM}"
        decision_host="$(omc_host)"
        if ! prepare_auto_tune_conf_generations "${user_conf}" \
            "${new_value}" "${current}"; then
          reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the exact entry/final config generations could not be sealed — no config change attempted"
          continue_auto_tune_decision=0
          retryable_error=1
        else
          continue_auto_tune_decision=1
        fi
        audit_row="$(jq -nc \
          --argjson v 1 --arg decision_id "${decision_id}" \
          --argjson ts "${now_ts}" \
          --arg flag "objective_contract_min_files" \
          --argjson old "${current}" --argjson new "${new_value}" \
          --arg evidence "${evidence}" --arg host "${decision_host}" \
          '{_v:$v, decision_id:$decision_id, ts:$ts, flag:$flag, old:$old,
            new:$new, evidence:$evidence, host:$host}')"
        pending_receipt="$(jq -nc \
          --argjson version 1 --arg phase "prepared" \
          --arg decision_id "${decision_id}" --argjson ts "${now_ts}" \
          --argjson old "${current}" --argjson new "${new_value}" \
          --arg reason "${reason}" --arg evidence "${evidence}" \
          --arg host "${decision_host}" --argjson oc_pct "${oc_pct}" \
          --argjson oc_blocks "${oc_blocks}" \
          --argjson oc_reprompts "${oc_reprompts}" \
          --arg entry_state "${AUTO_TUNE_ENTRY_STATE}" \
          --arg entry_digest "${AUTO_TUNE_ENTRY_DIGEST}" \
          --arg entry_mode "${AUTO_TUNE_ENTRY_MODE}" \
          --arg final_digest "${AUTO_TUNE_FINAL_DIGEST}" \
          --arg final_mode "${AUTO_TUNE_FINAL_MODE}" \
          '{version:$version, phase:$phase, decision_id:$decision_id,
            ts:$ts, old:$old, new:$new,
            reason:$reason, evidence:$evidence, host:$host, oc_pct:$oc_pct,
            oc_blocks:$oc_blocks, oc_reprompts:$oc_reprompts,
            entry_state:$entry_state, entry_digest:$entry_digest,
            entry_mode:$entry_mode, final_digest:$final_digest,
            final_mode:$final_mode}')"
        # -f, not -x: invoked via `bash <path>`, so only readability
        # matters — omc-config.sh does not carry the executable bit in
        # the source tree (install.sh does not chmod it either), and an
        # -x gate would spuriously refuse a perfectly runnable script.
        if [[ "${continue_auto_tune_decision}" -eq 1 ]]; then
          decision_rc=0
          AUTO_TUNE_DECISION_ABORT=0
          with_cross_session_log_lock "${AUDIT_LEDGER}" \
            _apply_auto_tune_decision_locked "${audit_row}" \
              "${pending_receipt}" "${decision_id}" "${user_conf}" \
              "${new_value}" "${current}" "${oc_pct}" "${oc_blocks}" \
            || decision_rc=$?
          if [[ "${decision_rc}" -eq 75 ]]; then
            exit 75
          elif [[ "${decision_rc}" -ne 0 ]]; then
            reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the durable audit transaction lock was unavailable — no config change attempted"
            retryable_error=1
          elif [[ "${AUTO_TUNE_DECISION_ABORT}" -eq 1 ]]; then
            exit 0
          fi
        fi
      fi
    fi
  fi
fi

if (( retryable_error == 1 )); then
  log_anomaly "session-start-auto-tune" \
    "${reason}; cadence was not advanced so a later session can retry"
  exit 0
fi

# Cross-session cadence stamp. Written regardless of outcome — the
# EVALUATION itself (reading + parsing gate_events.jsonl) is throttled
# to once every 7 days, not just the conf write, so a light workload
# that never clears the signal floor doesn't re-read the ledger every
# session either.
state_payload="$(build_auto_tune_state_json "${now_ts}" "${reason}" \
  "${applied}")" || state_payload=""
if [[ -n "${state_payload}" ]] \
    && write_auto_tune_json_atomic "${STATE_FILE}" "${state_payload}"; then
  if (( applied == 1 )); then
    if [[ "${OMC_TEST_AUTO_TUNE_FAIL_AFTER_STATE:-0}" == "1" ]]; then
      exit 75
    fi
    if auto_tune_remove_captured_pending; then
      applied_finalized=1
    else
      log_anomaly "session-start-auto-tune" \
        "applied decision audited/stamped but pending receipt removal failed"
    fi
  fi
else
  log_anomaly "session-start-auto-tune" \
    "failed to publish ${STATE_FILE}; any applied decision remains recoverable from its receipt"
fi

record_gate_event "auto-tune" "checked" \
  "applied=${applied_finalized}" \
  "oc_blocks=${oc_blocks}" \
  "oc_reprompts=${oc_reprompts}" \
  "decision_id=${decision_id:-}"

log_hook "session-start-auto-tune" "auto-tune check: ${reason}"

if (( applied_finalized == 1 )); then
  msg="**Auto-tune applied.** Raised \`objective_contract_min_files\` ${current} -> ${new_value} — the last 7 days show a ${oc_pct}% reprompt-rate over ${oc_blocks} objective-contract re-anchor blocks (>=50% over-firing bar, >=10-block signal floor), matching the pattern \`/ulw-report\` already surfaces as a suggestion. Revert with \`objective_contract_min_files=${current}\` in \`~/.claude/oh-my-claude.conf\`, or turn the mechanism off entirely with \`auto_tune=off\`."
  payload="$(jq -nc --arg context "${msg}" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $context
    }
  }' 2>/dev/null || true)"
  if [[ -n "${payload}" ]]; then
    printf '%s\n' "${payload}" || log_anomaly "session-start-auto-tune" "failed to emit payload to stdout"
  else
    log_anomaly "session-start-auto-tune" "failed to compose payload"
  fi
fi
