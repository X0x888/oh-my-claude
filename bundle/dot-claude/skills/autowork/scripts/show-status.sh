#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# Note: this is a diagnostic script, not a hook — no SESSION_ID guard needed.
# It discovers the latest session itself rather than operating on the current one.

# Find the most recent session directory (excluding dotfiles like .ulw_active)
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # shellcheck disable=SC2010  # filenames are controlled session IDs, no special chars
  latest_session="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v '^\.' | head -1 || true)"
fi

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

state_file="${STATE_ROOT}/${latest_session}/session_state.json"

if [[ ! -f "${state_file}" ]]; then
  printf 'Session %s has no state file.\n' "${latest_session}"
  exit 0
fi

SESSION_ID="${latest_session}"

printf '=== ULW Session Status ===\n'
printf 'Session: %s\n\n' "${latest_session}"

jq -r '
  "Workflow mode:     \(.workflow_mode // "none")",
  "Task domain:       \(.task_domain // "unset")",
  "Task intent:       \(.task_intent // "unset")",
  "Objective:         \(.current_objective // "none" | .[0:100])",
  "",
  "--- Timestamps ---",
  "Last user prompt:  \(.last_user_prompt_ts // "never")",
  "Last edit (code):  \(.last_code_edit_ts // .last_edit_ts // "never")",
  "Last edit (doc):   \(.last_doc_edit_ts // "never")",
  "Last verify:       \(.last_verify_ts // "never")",
  "Last review:       \(.last_review_ts // "never")",
  "Last doc review:   \(.last_doc_review_ts // "never")",
  "",
  "--- Quality Status ---",
  "Verification:      \(
    if (.last_code_edit_ts // .last_edit_ts // "") == "" then "no edits"
    elif (.last_verify_ts // "") == "" then "PENDING"
    elif ((.last_verify_ts // "0") | tonumber) >= ((.last_code_edit_ts // .last_edit_ts // "0") | tonumber) then
      if (.last_verify_outcome // "passed") == "failed" then "FAILED" else "passed" end
    else "PENDING" end
  )",
  "Code review:       \(
    if (.last_code_edit_ts // .last_edit_ts // "") == "" then "no edits"
    elif (.last_review_ts // "") == "" then "PENDING"
    elif ((.last_review_ts // "0") | tonumber) >= ((.last_code_edit_ts // .last_edit_ts // "0") | tonumber) then
      if (.review_had_findings // "false") == "true" then "findings flagged" else "satisfied" end
    else "PENDING" end
  )",
  "Doc review:        \(
    if (.last_doc_edit_ts // "") == "" then "n/a"
    elif (.last_doc_review_ts // "") == "" then "PENDING"
    elif ((.last_doc_review_ts // "0") | tonumber) >= ((.last_doc_edit_ts // "0") | tonumber) then "satisfied"
    else "PENDING" end
  )",
  "",
  "--- Counters ---",
  "Stop guard blocks: \(.stop_guard_blocks // "0")",
  "Dimension blocks:  \(.dimension_guard_blocks // "0")",
  "Session handoffs:  \(.session_handoff_blocks // "0")",
  "Stall counter:     \(.stall_counter // "0")",
  "Advisory guards:   \(.advisory_guard_blocks // "0")",
  "PreTool intent blocks: \(.pretool_intent_blocks // "0")",
  "",
  "--- Flags ---",
  "Has plan:          \(.has_plan // "false")",
  "Excellence gate:   \(if (.excellence_guard_triggered // "") == "1" then "triggered" else "not triggered" end)",
  "Guard exhausted:   \(if (.guard_exhausted // "") != "" then "YES (\(.guard_exhausted_detail // "unknown"))" else "no" end)",
  "",
  "--- Edit Counts ---",
  "Code files edited: \(.code_edit_count // "0")",
  "Doc files edited:  \(.doc_edit_count // "0")",
  "",
  "--- Compact Continuity ---",
  "Last compact trigger:      \(.last_compact_trigger // "never")",
  "Last compact request ts:   \(.last_compact_request_ts // "never")",
  "Last compact rehydrate ts: \(.last_compact_rehydrate_ts // "never")",
  "Compact race count:        \(.compact_race_count // "0")",
  "Review pending at compact: \(if (.review_pending_at_compact // "") == "1" then "YES" else "no" end)",
  "Just-compacted flag:       \(if (.just_compacted // "") == "1" then "set (age: \(.just_compacted_ts // "?"))" else "clear" end)"
' "${state_file}"

# Pending specialist count (jsonl file is separate from session_state.json)
pending_file="${STATE_ROOT}/${latest_session}/pending_agents.jsonl"
if [[ -f "${pending_file}" ]]; then
  pending_count="$(wc -l <"${pending_file}" 2>/dev/null | tr -d '[:space:]')"
else
  pending_count="0"
fi
printf 'Pending specialists:       %s\n' "${pending_count}"

# Show dimension status if dimensions are active
dim_output=""
for dim in bug_hunt code_quality stress_test completeness prose traceability design_quality; do
  dim_ts="$(read_state "$(_dim_key "${dim}")")"
  dim_verdict="$(read_state "dim_${dim}_verdict")"
  [[ -n "${dim_ts}" || -n "${dim_verdict}" ]] || continue

  if [[ -n "${dim_ts}" ]]; then
    if is_dimension_valid "${dim}"; then
      dim_line="${dim}: ticked @ ${dim_ts}"
    else
      dim_line="${dim}: stale @ ${dim_ts}"
    fi
    [[ -n "${dim_verdict}" ]] && dim_line="${dim_line} [${dim_verdict}]"
  elif [[ "${dim_verdict}" == "FINDINGS" ]]; then
    dim_line="${dim}: findings reported"
  else
    dim_line="${dim}: ${dim_verdict}"
  fi

  dim_output="${dim_output}${dim_line}\n"
done
if [[ -n "${dim_output}" ]]; then
  printf '\n--- Dimension Ticks ---\n'
  printf '%b' "${dim_output}"
fi

# Show verification confidence if available
verify_conf="$(jq -r '.last_verify_confidence // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${verify_conf}" ]]; then
  verify_method="$(jq -r '.last_verify_method // "unknown"' "${state_file}" 2>/dev/null || true)"
  printf '\n--- Verification Confidence ---\n'
  printf 'Confidence: %s/100  Method: %s\n' "${verify_conf}" "${verify_method}"
fi

# Show project profile (cached or detected on demand)
profile_val="$(get_project_profile 2>/dev/null || true)"
if [[ -n "${profile_val}" ]]; then
  printf '\n--- Project Profile ---\n'
  printf '%s\n' "${profile_val}"
fi

# Show guard exhaustion mode
printf '\n--- Guard Configuration ---\n'
printf 'Exhaustion mode:     %s\n' "${OMC_GUARD_EXHAUSTION_MODE}"
printf 'Gate level:          %s\n' "${OMC_GATE_LEVEL}"
printf 'Verify confidence:   %s (threshold: %s)\n' \
  "$(jq -r '.last_verify_confidence // "n/a"' "${state_file}" 2>/dev/null || echo "n/a")" \
  "${OMC_VERIFY_CONFIDENCE_THRESHOLD}"

# Session timing
session_start="$(jq -r '.session_start_ts // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${session_start}" ]]; then
  session_age=$(( $(date +%s) - session_start ))
  printf 'Session age:         %dm %ds\n' "$((session_age / 60))" "$((session_age % 60))"
fi

# Subagent dispatch count
dispatch_count="$(jq -r '.subagent_dispatch_count // "0"' "${state_file}" 2>/dev/null || echo "0")"
printf 'Subagent dispatches: %s\n' "${dispatch_count}"

# Show agent performance metrics (cross-session)
metrics_file="${HOME}/.claude/quality-pack/agent-metrics.json"
if [[ -f "${metrics_file}" ]]; then
  metrics_output="$(jq -r '
    to_entries | map(select(.key | startswith("_") | not)) | map(select(.value | type == "object")) |
    sort_by(-.value.invocations) |
    if length > 0 then
      [.[] | "\(.key): \(.value.invocations) runs, \(.value.clean_verdicts) clean, \(.value.finding_verdicts) findings"] | join("\n")
    else empty end
  ' "${metrics_file}" 2>/dev/null || true)"
  if [[ -n "${metrics_output}" ]]; then
    printf '\n--- Agent Metrics (cross-session) ---\n'
    printf '%s\n' "${metrics_output}"
  fi
fi

# Show defect patterns (cross-session)
defect_file="${HOME}/.claude/quality-pack/defect-patterns.json"
if [[ -f "${defect_file}" ]]; then
  _ensure_valid_defect_patterns
  cutoff_ts="$(( $(now_epoch) - 90 * 86400 ))"
  defect_output="$(jq -r --argjson cutoff "${cutoff_ts}" '
    to_entries |
    map(select(.key | startswith("_") | not)) |
    map(select(.value | type == "object")) |
    map(select(.value.last_seen_ts > $cutoff)) |
    sort_by(-.value.count) |
    if length > 0 then
      [.[] | "\(.key): \(.value.count) occurrences (last example: \((.value.examples // [])[-1] // "n/a" | .[0:60]))"] | join("\n")
    else empty end
  ' "${defect_file}" 2>/dev/null || true)"
  if [[ -n "${defect_output}" ]]; then
    printf '\n--- Defect Patterns (cross-session) ---\n'
    printf '%s\n' "${defect_output}"
  fi
fi

# Show edited files if any
edits_file="${STATE_ROOT}/${latest_session}/edited_files.log"
if [[ -f "${edits_file}" ]]; then
  printf '\n--- Edited Files ---\n'
  sort -u "${edits_file}" | tail -20
fi
