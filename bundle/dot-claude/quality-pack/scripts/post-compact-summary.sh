#!/usr/bin/env bash

set -euo pipefail

_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${HOME}/.claude/skills/autowork/scripts/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
TRIGGER="$(json_get '.trigger')"
COMPACT_SUMMARY="$(json_get '.compact_summary')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

validate_session_id "${SESSION_ID}" 2>/dev/null || exit 1

# PreCompact normally refuses an armed admission journal, but PostCompact can
# still arrive if the runtime proceeds after that hook error. Do not stamp
# continuation bias or build a handoff from possibly partial dispatch bytes;
# the compact SessionStart fence will surface the exact reset guidance.
if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
  log_anomaly "post-compact-summary" \
    "interrupted Agent admission journal; compact handoff write refused" \
    2>/dev/null || true
  exit 1
fi

ensure_session_dir

# PostCompact is itself evidence that an in-flight native planner cannot return
# into the pre-compact context. Cold-retire that exact WAL first, then settle
# reviewer and receipt/claim recovery and prove the universal predicates absent
# before taking any ordinary state lock or publishing compact continuity.
_postcompact_plan_wal="$(session_file ".plan-txn.active")"
_postcompact_reviewer_wal="$(session_file ".reviewer-transaction.wal")"
if [[ -e "${_postcompact_plan_wal}" || -L "${_postcompact_plan_wal}" ]]; then
  _postcompact_cold_plan_json="$(bash \
    "${HOME}/.claude/skills/autowork/scripts/record-plan.sh" \
      --recover-cold-resume "${SESSION_ID}" </dev/null 2>/dev/null || true)"
  _postcompact_rebind_id="$(jq -r '
    select(.schema_version == 1 and .recovered == true)
    | .rebind_id // empty
  ' <<<"${_postcompact_cold_plan_json}" 2>/dev/null || true)"
  if [[ ! "${_postcompact_rebind_id}" \
        =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$ \
      || -e "${_postcompact_plan_wal}" \
      || -L "${_postcompact_plan_wal}" ]] \
      || ! omc_read_plan_cold_recovery_handoff "${SESSION_ID}" \
        >/dev/null; then
    log_anomaly "post-compact-summary" \
      "cold planner publication recovery failed; compact handoff refused" \
      2>/dev/null || true
    exit 1
  fi
fi
if ! omc_recover_active_publication_transactions "${SESSION_ID}" \
    || [[ -e "${_postcompact_plan_wal}" \
      || -L "${_postcompact_plan_wal}" \
      || -e "${_postcompact_reviewer_wal}" \
      || -L "${_postcompact_reviewer_wal}" ]] \
    || omc_publication_recovery_needed "${SESSION_ID}"; then
  log_anomaly "post-compact-summary" \
    "publication recovery barrier failed; compact handoff refused" \
    2>/dev/null || true
  exit 1
fi

# A PostCompact process may resume after its runtime timeout. Bind every debug,
# state, and artifact mutation to the exact active enforcement interval observed
# here so /ulw-off or a later reactivation permanently fences the old callback.
_postcompact_capture_rc=0
with_state_lock capture_ulw_enforcement_interval \
  || _postcompact_capture_rc=$?
if [[ "${_postcompact_capture_rc}" -eq 76 ]]; then
  exit 1
elif [[ "${_postcompact_capture_rc}" -ne 0 ]]; then
  exit 0
fi
export _OMC_ULW_CAPTURED_GENERATION

# Gap 6 — harden compact_summary handling. The PostCompact hook schema
# documents .compact_summary as a string field (verified against
# code.claude.com/docs/en/hooks), but schemas can change and we have no
# runtime guarantee the field is populated. On absence, emit a visible
# fallback marker and surface a warning in hooks.log so the gap is
# diagnosable instead of silently empty in the handoff file.
compact_summary_missing=0
if [[ -z "${COMPACT_SUMMARY}" ]]; then
  compact_summary_missing=1
  COMPACT_SUMMARY="(compact summary not provided by runtime — see compact_debug.log if HOOK_DEBUG is enabled)"
  log_hook "post-compact-summary" "warn: .compact_summary field empty or missing"
fi

# The runtime supplies its native summary to the resumed model directly. Keep
# only a bounded diagnostic copy in state; duplicating the full body inside our
# SessionStart handoff spends context without adding continuity information.
COMPACT_SUMMARY_STATE="$(truncate_chars 1800 "$(printf '%s' "${COMPACT_SUMMARY}" | tr -d '\000-\010\013-\014\016-\037\177' | omc_redact_secrets)")"

# Optional raw-hook-JSON debug log — enabled via HOOK_DEBUG=1 env var or
# hook_debug=true in oh-my-claude.conf. Useful when diagnosing schema
# drift in a future Claude Code release.
if is_hook_debug; then
  debug_file="$(session_file "compact_debug.log")"
  _append_compact_debug_unlocked() {
    is_ultrawork_mode || return 20
    [[ ! -L "${debug_file}" ]] || return 1
    [[ ! -e "${debug_file}" || -f "${debug_file}" ]] || return 1
    {
      printf '=== PostCompact @ %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      printf '%s\n' "${HOOK_JSON}"
    } >>"${debug_file}" 2>/dev/null
  }
  _postcompact_debug_rc=0
  with_state_lock _append_compact_debug_unlocked \
    || _postcompact_debug_rc=$?
  if [[ "${_postcompact_debug_rc}" -eq 20 ]]; then
    exit 0
  elif [[ "${_postcompact_debug_rc}" -ne 0 ]]; then
    exit 1
  fi
fi

combined_file="$(session_file "compact_handoff.md")"
snapshot_file="$(session_file "precompact_snapshot.md")"
combined_tmp="$(mktemp "${combined_file}.render.XXXXXX")" || exit 1

{
  printf '# Compact Handoff\n\n'
  printf 'The runtime native compact summary is already present and is not duplicated here.\n'
  if [[ "${compact_summary_missing}" -eq 1 ]]; then
    printf '\n## Runtime Summary Diagnostic\n%s\n' "${COMPACT_SUMMARY_STATE}"
  fi

  if [[ -f "${snapshot_file}" ]]; then
    printf '\n## Preserved Priority State\n'
    cat "${snapshot_file}"
    printf '\n'
  fi
} >"${combined_tmp}" || {
  rm -f -- "${combined_tmp}" 2>/dev/null || true
  exit 1
}

# Deterministic regression seam after all source bytes have been read but before
# the sole current-interval artifact/state publication transaction.
if [[ -n "${OMC_TEST_POSTCOMPACT_PUBLISH_READY_FILE:-}" \
    && -n "${OMC_TEST_POSTCOMPACT_PUBLISH_RELEASE_FILE:-}" ]]; then
  : >"${OMC_TEST_POSTCOMPACT_PUBLISH_READY_FILE}" || exit 1
  while [[ ! -e "${OMC_TEST_POSTCOMPACT_PUBLISH_RELEASE_FILE}" ]]; do
    sleep 0.01
  done
fi

postcompact_summary_ts="$(now_epoch)"
postcompact_flag_ts="$(now_epoch)"
_publish_compact_handoff_unlocked() {
  is_ultrawork_mode || return 20
  [[ -f "${combined_tmp}" && ! -L "${combined_tmp}" ]] || return 1
  [[ ! -L "${combined_file}" ]] || return 1
  [[ ! -e "${combined_file}" || -f "${combined_file}" ]] || return 1
  mv -f -- "${combined_tmp}" "${combined_file}" || return 1
  # The continuation flag and its exact handoff bytes are one generation. A
  # failed state batch retracts the artifact before releasing the mutex.
  if ! _write_state_batch_unlocked \
      "last_compact_trigger" "${TRIGGER:-unknown}" \
      "last_compact_summary" "${COMPACT_SUMMARY_STATE}" \
      "last_compact_summary_ts" "${postcompact_summary_ts}" \
      "just_compacted" "1" \
      "just_compacted_ts" "${postcompact_flag_ts}"; then
    rm -f -- "${combined_file}" 2>/dev/null || true
    return 1
  fi
}
_postcompact_publish_rc=0
with_state_lock _publish_compact_handoff_unlocked \
  || _postcompact_publish_rc=$?
if [[ "${_postcompact_publish_rc}" -eq 20 ]]; then
  rm -f -- "${combined_tmp}" 2>/dev/null || true
  exit 0
elif [[ "${_postcompact_publish_rc}" -ne 0 ]]; then
  rm -f -- "${combined_tmp}" 2>/dev/null || true
  exit 1
fi
