#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Find the most recent session directory
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # Pick the newest session DIRECTORY — the `*/` glob is load-bearing;
  # state-root files (hooks.log, gate_events.jsonl) out-sort session
  # dirs under bare `ls -t` (same family as the ulw-skip-register.sh
  # crash observed 2026-07-05).
  # shellcheck disable=SC2012
  latest_session="$(cd "${STATE_ROOT}" 2>/dev/null && ls -td -- */ 2>/dev/null | head -1 || true)"
  latest_session="${latest_session%/}"
fi

# Clear the sentinel
rm -f "${STATE_ROOT}/.ulw_active"

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found. Sentinel cleared.\n'
  exit 0
fi

# Clear workflow_mode in the latest session state, along with all the
# compact-continuity flags that would otherwise linger and surprise the user
# on a later compact resume. In particular, a stale review_pending_at_compact
# flag would re-inject a "MUST run quality-reviewer" directive on the next
# compact cycle *after* the user explicitly turned ULW off — that is exactly
# the kind of spooky action at a distance ulw-off is meant to prevent.
SESSION_ID="${latest_session}"
ensure_session_dir

_deactivate_session_unlocked() {
  local artifact artifact_path verification_starts
  local taint_file taint_tmp taint_dedup txn

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

  _write_state_batch_unlocked \
    "workflow_mode" "" \
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
    "council_phase8_prompt_revision" "" || return 1

  # /ulw-off is a lifecycle boundary. Pending agents, reviewer-generation
  # starts, and per-tool verification starts all describe work launched under
  # the old active interval; retaining any of them can block or misattribute a
  # later dispatch after reactivation. Keep the tracking-version state key:
  # it makes a late pre-deactivation reviewer completion fail closed instead
  # of falling back to the explicit legacy migration path.
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl; do
    artifact_path="$(session_file "${artifact}")"
    [[ ! -e "${artifact_path}" ]] || rm -f "${artifact_path}" || return 1
  done
  verification_starts="$(session_file ".verification-starts")"
  [[ ! -e "${verification_starts}" ]] \
    || rm -rf "${verification_starts}" \
    || return 1
}

if ! with_state_lock _deactivate_session_unlocked; then
  printf 'Ultrawork mode deactivation could not clear transient state for session %s.\n' \
    "${latest_session}" >&2
  exit 1
fi

printf 'Ultrawork mode deactivated for session %s.\n' "${latest_session}"
