#!/usr/bin/env bash
#
# stop-time-summary.sh — Stop hook that emits a one-line "Time: ..."
# distribution as additionalContext when the session releases. Reads
# `<session>/timing.jsonl`, finalizes the current prompt's walltime,
# aggregates per-tool / per-subagent totals, and rolls the summary into
# the cross-session log under ~/.claude/quality-pack/timing.jsonl.
#
# Self-suppression: stop-guard.sh is registered ahead of this hook in
# the Stop array. If stop-guard JUST emitted a `decision:block`, we do
# NOT emit a time summary on top of the user-facing block message —
# the prompt is not finished and showing partial totals is misleading.
# Detection: read the tail of `<session>/gate_events.jsonl` and check
# for an `event=block` row within the last few seconds. (stop-guard
# always exit 0s; the block decision is in the JSON payload, not the
# exit code, so the kernel-level "skip subsequent hooks on exit 2"
# semantics doesn't apply here.)
#
# Idempotence: the prompt_end row is written once per (session, prompt_seq).
# Re-emission on a second Stop event for the same prompt finds an
# already-finalized prompt and reuses its duration without double-counting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat 2>/dev/null || true)"
. "${SCRIPT_DIR}/common.sh"

is_time_tracking_enabled || exit 0

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

ensure_session_dir 2>/dev/null || exit 0

# --- Self-suppression on recent block ---
gate_events_path="$(session_file 'gate_events.jsonl')"
if [[ -f "${gate_events_path}" ]]; then
  recent_block_ts="$(tail -n 5 "${gate_events_path}" 2>/dev/null \
    | jq -rs --argjson now "$(now_epoch)" '
        [.[] | select(.event == "block")]
        | sort_by(.ts // 0)
        | last
        | (.ts // 0)
      ' 2>/dev/null || printf '0')"
  recent_block_ts="${recent_block_ts:-0}"
  [[ "${recent_block_ts}" =~ ^[0-9]+$ ]] || recent_block_ts=0
  now_ts="$(now_epoch)"
  if (( recent_block_ts > 0 )) && (( now_ts - recent_block_ts <= 3 )); then
    # stop-guard just blocked. Stay quiet.
    exit 0
  fi
fi

# --- Finalize the current prompt's walltime (idempotent) ---
log_path="$(timing_log_path)"
if [[ ! -f "${log_path}" ]]; then
  exit 0
fi

current_seq="$(timing_current_prompt_seq)"
[[ "${current_seq}" =~ ^[0-9]+$ ]] || current_seq=0

if (( current_seq > 0 )); then
  needs_end="$(jq -sr --argjson seq "${current_seq}" '
    ([.[] | select(.kind=="prompt_end" and (.prompt_seq // 0) == $seq)] | length) as $end_count
    | ([.[] | select(.kind=="prompt_start" and (.prompt_seq // 0) == $seq)] | length) as $start_count
    | if $start_count > 0 and $end_count == 0 then "yes" else "no" end
  ' < "${log_path}" 2>/dev/null || printf 'no')"

  if [[ "${needs_end}" == "yes" ]]; then
    start_ts="$(jq -sr --argjson seq "${current_seq}" '
      [.[] | select(.kind=="prompt_start" and (.prompt_seq // 0) == $seq)]
      | first
      | (.ts // 0)
    ' < "${log_path}" 2>/dev/null || printf '0')"
    start_ts="${start_ts:-0}"
    [[ "${start_ts}" =~ ^[0-9]+$ ]] || start_ts=0
    now_ts="$(now_epoch)"
    if (( start_ts > 0 )); then
      duration=$(( now_ts - start_ts ))
      (( duration < 0 )) && duration=0
      timing_append_prompt_end "${current_seq}" "${duration}"
    fi
  fi
fi

# --- Aggregate + emit ---
agg="$(timing_aggregate "${log_path}")"

oneline="$(timing_format_oneline "${agg}")"

if [[ -n "${oneline}" ]]; then
  jq -nc --arg ctx "${oneline}" '{
    hookSpecificOutput: {
      hookEventName: "Stop",
      additionalContext: $ctx
    }
  }'
fi

# --- Cross-session rollup ---
# Append the latest whole-session aggregate to the cross-session log so
# /ulw-report can render rollups by project_key. The Stop hook fires on
# every release, so multi-prompt sessions would otherwise accrue N
# growing rows whose walltime sums incorrectly. Duplicate-record
# protection is explicit: timing_record_session_summary itself dedups
# by SESSION_ID at write time (drops any prior row with the same
# session before appending the new one), so each session ends up as
# exactly one row carrying its latest aggregate.
timing_record_session_summary "${agg}" 2>/dev/null || true

exit 0
