#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Prefer an explicitly addressed session. Claude Code 2.1.132+ exports
# CLAUDE_CODE_SESSION_ID to Bash subprocesses, while skill substitution can
# pass the same identity as argv. SESSION_ID remains a legacy/manual fallback.
# A mutating lifecycle command must never guess by newest mtime.
target_source=""
if [[ -n "${1:-}" ]]; then
  latest_session="$1"
  target_source="argument"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  latest_session="${CLAUDE_CODE_SESSION_ID}"
  target_source="claude-environment"
elif [[ -n "${SESSION_ID:-}" ]]; then
  latest_session="${SESSION_ID}"
  target_source="legacy-environment"
else
  latest_session=""
fi
if [[ -n "${latest_session}" ]]; then
  validate_session_id "${latest_session}" || {
    printf 'Invalid ULW session id; nothing deactivated.\n' >&2
    exit 1
  }
  selected_state="${STATE_ROOT}/${latest_session}/${STATE_JSON}"
  selected_active="$(jq -r '
    ((.ulw_enforcement_active // "") | tostring) as $active
    | if (.workflow_mode // "") == "ultrawork" then
        if $active == "1" then "on"
        elif $active == "0" then "off"
        elif (.session_outcome // "") == "" then "on"
        else "off"
        end
      elif $active == "0" then "off"
      elif (.workflow_mode // "") == "" and (.session_outcome // "") == "" then "unknown"
      else "off"
      end
  ' "${selected_state}" 2>/dev/null || true)"
  if [[ "${selected_active}" == "unknown" \
      && -f "${STATE_ROOT}/${latest_session}/.ulw_active" ]]; then
    selected_active="on"
  fi
  if [[ "${selected_active}" != "on" ]]; then
    if [[ "${target_source}" == "argument" ]]; then
      if [[ -f "${selected_state}" ]]; then
        printf 'Ultrawork mode is already inactive for session %s.\n' "${latest_session}"
        exit 0
      fi
      printf 'No state exists for ULW session %s; nothing deactivated.\n' \
        "${latest_session}" >&2
      exit 1
    fi
    # `--continue`/ID-less resume can expose an older startup ID in the Bash
    # environment. Do not mutate it; fall through to the unique-active-cwd
    # compatibility search below.
    latest_session=""
  fi
fi

if [[ -z "${latest_session}" ]]; then
  # Last-resort compatibility for direct shells: accept exactly one active
  # ULW session whose recorded cwd is this cwd. Refuse zero/multiple matches;
  # unlike read-only status helpers, deactivation never falls back across
  # projects or picks one of two same-repo Claude sessions by recency.
  current_cwd="${PWD:-}"
  active_candidate_count=0
  active_candidate_list=""
  for candidate_dir in "${STATE_ROOT}"/*/; do
    [[ -d "${candidate_dir}" ]] || continue
    candidate_state="${candidate_dir}/${STATE_JSON}"
    [[ -f "${candidate_state}" ]] || continue
    candidate_cwd="$(jq -r '.cwd // ""' "${candidate_state}" 2>/dev/null || true)"
    [[ -n "${current_cwd}" && "${candidate_cwd}" == "${current_cwd}" ]] || continue
    candidate_active="$(jq -r '
      ((.ulw_enforcement_active // "") | tostring) as $active
      | if (.workflow_mode // "") == "ultrawork" then
          if $active == "1" then "on"
          elif $active == "0" then "off"
          elif (.session_outcome // "") == "" then "on"
          else "off"
          end
        elif $active == "0" then "off"
        elif (.workflow_mode // "") == "" and (.session_outcome // "") == "" then "unknown"
        else "off"
        end
    ' "${candidate_state}" 2>/dev/null || true)"
    if [[ "${candidate_active}" == "unknown" \
        && -f "${candidate_dir}/.ulw_active" ]]; then
      candidate_active="on"
    fi
    [[ "${candidate_active}" == "on" ]] || continue
    candidate_sid="$(basename "${candidate_dir}")"
    validate_session_id "${candidate_sid}" 2>/dev/null || continue
    active_candidate_count=$((active_candidate_count + 1))
    active_candidate_list="${active_candidate_list:+${active_candidate_list} }${candidate_sid}"
    latest_session="${candidate_sid}"
  done
  if [[ "${active_candidate_count}" -gt 1 ]]; then
    printf 'Multiple active ULW sessions share this cwd; pass the exact session id: %s\n' \
      "${active_candidate_list}" >&2
    exit 1
  fi
fi

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

# Clear workflow_mode in the addressed session state, along with all the
# compact-continuity flags that would otherwise linger and surprise the user
# on a later compact resume. In particular, a stale review_pending_at_compact
# flag would re-inject a "MUST run quality-reviewer" directive on the next
# compact cycle *after* the user explicitly turned ULW off — that is exactly
# the kind of spooky action at a distance ulw-off is meant to prevent.
SESSION_ID="${latest_session}"
[[ -f "${STATE_ROOT}/${SESSION_ID}/${STATE_JSON}" ]] || {
  printf 'No state exists for ULW session %s; nothing deactivated.\n' \
    "${SESSION_ID}" >&2
  exit 1
}

_deactivate_session_unlocked() {
  local artifact artifact_path verification_starts
  local taint_file taint_tmp taint_dedup txn deactivate_txn moved_artifacts

  # A universal SubagentStop recorder holds its exact pending row as a short
  # completion lease while publishing claim-scoped effects. Do not tear the
  # interval out from under that transaction; a retry moments later succeeds.
  artifact_path="$(session_file "pending_agents.jsonl")"
  if [[ -s "${artifact_path}" ]] && jq -Rse \
      --argjson cutoff "$(( $(now_epoch) - 120 ))" '
        any(split("\n")[] | select(length > 0);
          (try fromjson catch {}) as $row
          | (($row.completion_claim_id // "") | length) > 0
          and (($row.completion_claim_effects_complete // false) != true)
          and (($row.completion_claim_ts // 0) >= $cutoff))
      ' "${artifact_path}" >/dev/null 2>&1; then
    log_anomaly "ulw-deactivate" \
      "active subagent completion lease; deactivation refused for retry" \
      2>/dev/null || true
    return 1
  fi

  # Recover a prior interrupted deactivation that staged transient evidence
  # but never committed the final inactive state. This function only runs for
  # an active interval, so staged rows still belong live and must be restored.
  for txn in "$(session_file ".deactivate-txn.")"*; do
    [[ -d "${txn}" ]] || continue
    for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl .verification-starts \
                    .closeout-material-generation .closeout-material-generations; do
      [[ -e "${txn}/${artifact}" ]] || continue
      artifact_path="$(session_file "${artifact}")"
      [[ ! -e "${artifact_path}" ]] || return 1
      mv "${txn}/${artifact}" "${artifact_path}" || return 1
    done
    rmdir "${txn}" 2>/dev/null || return 1
  done

  # Every deleted live identity remains capable of returning after reactivation.
  # Persist the taint before removing causal rows so a later same-agent launch
  # must use a never-reused echoed ID instead of accepting the old result.
  taint_file="$(session_file "dispatch_tainted_identities.log")"
  [[ ! -L "${taint_file}" ]] \
    && { [[ ! -e "${taint_file}" ]] || [[ -f "${taint_file}" ]]; } \
    || return 1
  taint_tmp="$(mktemp "${taint_file}.XXXXXX")" || return 1
  [[ ! -f "${taint_file}" ]] || cp "${taint_file}" "${taint_tmp}" || {
    rm -f "${taint_tmp}"
    return 1
  }
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl; do
    artifact_path="$(session_file "${artifact}")"
    [[ -s "${artifact_path}" ]] || continue
    jq -Rr '
      fromjson?
      | select((.review_dispatch_abandoned // false) != true)
      | (.agent_type // empty)
      | select(type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
    ' "${artifact_path}" >>"${taint_tmp}" || {
      rm -f "${taint_tmp}"
      return 1
    }
  done
  taint_dedup="$(mktemp "${taint_file}.dedup.XXXXXX")" || {
    rm -f "${taint_tmp}"
    return 1
  }
  if ! awk 'NF && !seen[$0]++' "${taint_tmp}" >"${taint_dedup}" \
      || ! mv -f "${taint_dedup}" "${taint_file}"; then
    rm -f "${taint_tmp}" "${taint_dedup}"
    return 1
  fi
  rm -f "${taint_tmp}"

  # Interrupted dispatch/native-bind/plan journals are never replayed over
  # newer state.
  # Once every live identity above is tainted, deactivation is the safe reset
  # point for removing those fail-closed recovery sentinels.
  for txn in "$(session_file ".dispatch-txn.")"* \
             "$(session_file ".native-bind-txn.")"* \
             "$(session_file ".plan-txn.")"*; do
    [[ -d "${txn}" ]] || continue
    rm -f "${txn}/.ready" "${txn}"/* 2>/dev/null || return 1
    rmdir "${txn}" 2>/dev/null || return 1
  done

  # /ulw-off is a lifecycle boundary. Pending agents, reviewer-generation
  # starts, and per-tool verification starts all describe work launched under
  # the old active interval; retaining any of them can block or misattribute a
  # later dispatch after reactivation. Keep the tracking-version state key:
  # it makes a late pre-deactivation reviewer completion fail closed instead
  # of falling back to the explicit legacy migration path.
  # Stage every transient path by same-filesystem rename before changing the
  # authority bit. If any rename or state commit fails, restore the staged
  # paths and leave enforcement active; a partial `/ulw-off` must never wedge
  # Stop or silently disarm evidence producers.
  deactivate_txn="$(session_file ".deactivate-txn.$$")"
  mkdir "${deactivate_txn}" || return 1
  moved_artifacts=""
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl .verification-starts \
                  .closeout-material-generation .closeout-material-generations; do
    artifact_path="$(session_file "${artifact}")"
    [[ ! -e "${artifact_path}" ]] && continue
    [[ ! -L "${artifact_path}" ]] || {
      rmdir "${deactivate_txn}" 2>/dev/null || true
      return 1
    }
    if ! mv "${artifact_path}" "${deactivate_txn}/${artifact}"; then
      for restore_artifact in ${moved_artifacts}; do
        mv "${deactivate_txn}/${restore_artifact}" "$(session_file "${restore_artifact}")" 2>/dev/null || true
      done
      rmdir "${deactivate_txn}" 2>/dev/null || true
      return 1
    fi
    moved_artifacts="${moved_artifacts:+${moved_artifacts} }${artifact}"
  done

  if ! _write_state_batch_unlocked \
      "workflow_mode" "" \
      "ulw_enforcement_active" "0" \
      "just_compacted" "" \
      "just_compacted_ts" "" \
      "review_pending_at_compact" "" \
      "compact_race_count" "" \
      "pretool_intent_blocks" "" \
      "agent_first_specialist_ts" "" \
      "agent_first_specialist_type" "" \
      "agent_first_gate_blocks" "" \
      "first_mutation_ts" "" \
      "first_mutation_tool" "" \
      "council_phase8_active" "" \
      "council_phase8_prompt_revision" ""; then
    for artifact in ${moved_artifacts}; do
      mv "${deactivate_txn}/${artifact}" "$(session_file "${artifact}")" 2>/dev/null || true
    done
    rmdir "${deactivate_txn}" 2>/dev/null || true
    return 1
  fi

  # Authority is now off and the live paths are absent. Cleanup is advisory:
  # a crash or permission error here leaves only a quarantined transaction,
  # never replayable live evidence and never a partially-active session.
  rm -rf "${deactivate_txn}" 2>/dev/null || true
}

if ! with_state_lock _deactivate_session_unlocked; then
  printf 'Ultrawork mode deactivation could not clear transient state for session %s.\n' \
    "${latest_session}" >&2
  exit 1
fi
rm -f "$(session_file ".ulw_active")" 2>/dev/null || true

printf 'Ultrawork mode deactivated for session %s.\n' "${latest_session}"
