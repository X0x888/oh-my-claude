#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi

ensure_session_dir

plan_file="$(session_file "current_plan.md")"
{
  printf '# Plan from %s\n\n' "${AGENT_TYPE:-planner}"
  printf '%s\n' "${LAST_ASSISTANT_MESSAGE}"
} >"${plan_file}"

# Parse the v1.14 universal VERDICT contract for planner-class agents
# (prometheus, quality-planner). The reviewer-class parser in
# record-reviewer.sh does not run here, so the verdict is read inline.
# Default to PLAN_READY when no VERDICT line is present so legacy plans
# keep their prior has_plan=true semantics.
plan_verdict="$(printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" \
  | grep -E '^VERDICT:[[:space:]]*(PLAN_READY|NEEDS_CLARIFICATION|BLOCKED)\b' 2>/dev/null \
  | tail -n 1 \
  | sed -E 's/^VERDICT:[[:space:]]*//' \
  | awk '{print $1}' \
  || true)"
plan_verdict="${plan_verdict:-PLAN_READY}"

with_state_lock_batch \
  "has_plan" "true" \
  "plan_verdict" "${plan_verdict}" \
  "plan_agent" "${AGENT_TYPE:-planner}" \
  "plan_ts" "$(now_epoch)"

# Threshold-based plan validation nudge: detect complex plans
step_count=$(grep -cE '^\s*[0-9]+\.' <<<"${LAST_ASSISTANT_MESSAGE}" 2>/dev/null || echo 0)
file_count=$(grep -oE '[a-zA-Z0-9_/.-]+\.(ts|js|py|sh|md|json|swift|go|rs|rb|java|css|html|yaml|yml|toml)' <<<"${LAST_ASSISTANT_MESSAGE}" 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')
file_count=${file_count:-0}

if [[ "${step_count}" -gt 5 || "${file_count}" -gt 3 ]]; then
  jq -nc --arg steps "${step_count}" --arg files "${file_count}" '{
    hookSpecificOutput: {
      hookEventName: "SubagentStop",
      additionalContext: ("PLAN COMPLEXITY NOTICE: The plan has " + $steps + " numbered steps and references " + $files + " distinct files. Consider running metis to pressure-test this plan for hidden assumptions, missing constraints, and weak validation before committing to execution.")
    }
  }'
fi
