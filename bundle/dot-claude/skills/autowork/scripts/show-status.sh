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
dim_output="$(jq -r '
  [
    ["bug_hunt",       .dim_bug_hunt_ts,       .dim_bug_hunt_verdict],
    ["code_quality",   .dim_code_quality_ts,    .dim_code_quality_verdict],
    ["stress_test",    .dim_stress_test_ts,     .dim_stress_test_verdict],
    ["completeness",   .dim_completeness_ts,    .dim_completeness_verdict],
    ["prose",          .dim_prose_ts,           .dim_prose_verdict],
    ["traceability",   .dim_traceability_ts,    .dim_traceability_verdict],
    ["design_quality", .dim_design_quality_ts,  .dim_design_quality_verdict]
  ] | map(select(.[1] != null and .[1] != "")) |
  if length > 0 then
    [.[] | "\(.[0]): ticked @ \(.[1])\(if .[2] then " [\(.[2])]" else "" end)"] | join("\n")
  else empty end
' "${state_file}" 2>/dev/null || true)"
if [[ -n "${dim_output}" ]]; then
  printf '\n--- Dimension Ticks ---\n'
  printf '%s\n' "${dim_output}"
fi

# Show verification confidence if available
verify_conf="$(jq -r '.last_verify_confidence // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${verify_conf}" ]]; then
  verify_method="$(jq -r '.last_verify_method // "unknown"' "${state_file}" 2>/dev/null || true)"
  printf '\n--- Verification Confidence ---\n'
  printf 'Confidence: %s/100  Method: %s\n' "${verify_conf}" "${verify_method}"
fi

# Show project profile if cached
profile_val="$(jq -r '.project_profile // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${profile_val}" ]]; then
  printf '\n--- Project Profile ---\n'
  printf '%s\n' "${profile_val}"
fi

# Show guard exhaustion mode
exhaust_mode="$(jq -r '.guard_exhaustion_mode // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${exhaust_mode}" ]]; then
  printf '\n--- Guard Configuration ---\n'
  printf 'Exhaustion mode: %s\n' "${exhaust_mode}"
fi

# Show agent performance metrics (cross-session)
metrics_file="${HOME}/.claude/quality-pack/agent-metrics.json"
if [[ -f "${metrics_file}" ]]; then
  metrics_output="$(jq -r '
    to_entries | sort_by(-.value.invocations) |
    if length > 0 then
      [.[] | "\(.key): \(.value.invocations) runs, \(.value.clean_verdicts) clean, \(.value.finding_verdicts) findings"] | join("\n")
    else empty end
  ' "${metrics_file}" 2>/dev/null || true)"
  if [[ -n "${metrics_output}" ]]; then
    printf '\n--- Agent Metrics (cross-session) ---\n'
    printf '%s\n' "${metrics_output}"
  fi
fi

# Show edited files if any
edits_file="${STATE_ROOT}/${latest_session}/edited_files.log"
if [[ -f "${edits_file}" ]]; then
  printf '\n--- Edited Files ---\n'
  sort -u "${edits_file}" | tail -20
fi
