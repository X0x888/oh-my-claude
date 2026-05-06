#!/usr/bin/env bash
#
# stop-time-summary.sh — Stop hook that emits the polished
# "─── Time breakdown ───" card as `systemMessage` when the session
# releases. Reads `<session>/timing.jsonl`, finalizes the current
# prompt's walltime, aggregates per-tool / per-subagent totals, and rolls
# the summary into the cross-session log under
# ~/.claude/quality-pack/timing.jsonl.
#
# Schema note: Stop hooks do NOT support hookSpecificOutput.additionalContext
# (it is silently dropped). The documented user-visible Stop output field
# is `systemMessage`. See CLAUDE.md "Stop hook output schema" rule.
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

# v1.27.0 (F-020): stop-time-summary needs lib/timing.sh for the
# epilogue card but has no classifier dependency. Opt out of eager
# classifier source; lib/timing.sh stays eager-loaded by default.
export OMC_LAZY_CLASSIFIER=1

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

# Apply the 5s noise floor locally so timing_format_full stays a pure
# formatter. timing_format_oneline used to do this internally; moving it
# here keeps the formatter usable from manual /ulw-time invocations
# (where the user expects to see whatever data exists, regardless of
# walltime).
walltime_s="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
walltime_s="${walltime_s:-0}"
[[ "${walltime_s}" =~ ^[0-9]+$ ]] || walltime_s=0

# Threshold below which the polished epilogue is suppressed. Default 5s
# matches the historical noise floor (single-tool sub-second turns
# don't deserve a 4-line card). Set OMC_TIME_CARD_MIN_SECONDS=0 to
# show the card on every Stop, or =30 to only see it on substantive
# turns. Closes product-lens P1-5.
_card_threshold="${OMC_TIME_CARD_MIN_SECONDS:-5}"
[[ "${_card_threshold}" =~ ^[0-9]+$ ]] || _card_threshold=5
if (( walltime_s >= _card_threshold )); then
  epilogue="$(timing_format_full "${agg}" "Time breakdown")"
  if [[ -n "${epilogue}" ]]; then
    # v1.34.1+ (product-lens P-004 / trust-accrual): when this session
    # had concrete outcomes the user should see, prepend a one-line
    # outcome card above the time breakdown. Outcomes counted:
    #   - Serendipity Rule fires (verified adjacent defects fixed)
    #   - Quality / discovered-scope / wave-shape blocks RESOLVED
    #     (block fired AND session ended cleanly — outcome=completed/
    #     released, not exhausted)
    # Surfaces value passively so users don't have to run /ulw-report
    # to learn the harness is helping. Skip when there is no signal
    # (no blocks, no Serendipity) — silence is honest when nothing
    # was caught.
    _outcome_line=""
    _outcome_serendipity="$(read_state "serendipity_count" 2>/dev/null || true)"
    _outcome_serendipity="${_outcome_serendipity:-0}"
    [[ "${_outcome_serendipity}" =~ ^[0-9]+$ ]] || _outcome_serendipity=0
    _outcome_blocks="$(read_state "stop_guard_blocks" 2>/dev/null || true)"
    _outcome_blocks="${_outcome_blocks:-0}"
    [[ "${_outcome_blocks}" =~ ^[0-9]+$ ]] || _outcome_blocks=0
    _outcome_scope="$(read_state "discovered_scope_blocks" 2>/dev/null || true)"
    _outcome_scope="${_outcome_scope:-0}"
    [[ "${_outcome_scope}" =~ ^[0-9]+$ ]] || _outcome_scope=0
    _outcome_status="$(read_state "session_outcome" 2>/dev/null || true)"
    # v1.34.2 (release-reviewer F-1): only count blocks as "caught and
    # resolved" when the session ended with completed (all gates
    # satisfied) OR released (clean exit with no gates fired). The
    # skip-released outcome means the user explicitly bypassed the
    # gates via /ulw-skip — those gates fired but were NOT resolved
    # by the model, so claiming "caught + resolved" would be a false
    # trust signal. exhausted = same logic (gates fired, model never
    # satisfied them, scorecard release).
    _outcome_blocks_resolved=0
    if [[ "${_outcome_status}" == "completed" || "${_outcome_status}" == "released" ]]; then
      _outcome_blocks_resolved=$(( _outcome_blocks + _outcome_scope ))
    fi
    if (( _outcome_blocks_resolved > 0 )) || (( _outcome_serendipity > 0 )); then
      _outcome_parts=()
      if (( _outcome_blocks_resolved > 0 )); then
        _outcome_parts+=("${_outcome_blocks_resolved} gate$( (( _outcome_blocks_resolved == 1 )) && printf '' || printf 's' ) caught + resolved")
      fi
      if (( _outcome_serendipity > 0 )); then
        _outcome_parts+=("${_outcome_serendipity} adjacent fix$( (( _outcome_serendipity == 1 )) && printf '' || printf 'es' ) (Serendipity)")
      fi
      _outcome_joined=""
      for _p in "${_outcome_parts[@]}"; do
        if [[ -z "${_outcome_joined}" ]]; then
          _outcome_joined="${_p}"
        else
          _outcome_joined="${_outcome_joined} · ${_p}"
        fi
      done
      _outcome_line="─── Outcome ─── ${_outcome_joined}"$'\n'
    fi
    # emit_stop_message (common.sh, v1.30.0) encodes the contract: Stop
    # hooks render via top-level `systemMessage`; `hookSpecificOutput.
    # additionalContext` is silently dropped by Claude Code at Stop /
    # SubagentStop. Centralizing the schema in a primitive prevents the
    # next Stop-hook author from accidentally repeating the v1.24.0 /
    # v1.25.0 bug. See CLAUDE.md "Stop hook output schema".
    emit_stop_message "${_outcome_line}${epilogue}"
  fi
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
