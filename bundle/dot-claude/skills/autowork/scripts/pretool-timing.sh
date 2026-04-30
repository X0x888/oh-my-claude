#!/usr/bin/env bash
#
# pretool-timing.sh — Universal-matcher PreToolUse hook that records a
# `start` row in `<session>/timing.jsonl` for every tool call. Pairs
# with posttool-timing.sh, which writes the matching `end` row.
#
# Lock-free hot path: a single sub-PIPE_BUF JSONL append per call. No
# state-lock acquisition on this path. Aggregation under lock happens
# only at Stop / on-demand surfaces.
#
# Fast-exit when:
#   - jq is unavailable (common.sh exits 0 in that case before this runs)
#   - SESSION_ID missing (validates_session_id failure)
#   - is_time_tracking_enabled returns false (kill switch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

is_time_tracking_enabled || exit 0

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

tool_name="$(json_get '.tool_name')"
[[ -z "${tool_name}" ]] && exit 0

tool_use_id="$(json_get '.tool_use_id')"

subagent_type=""
if [[ "${tool_name}" == "Agent" ]]; then
  subagent_type="$(json_get '.tool_input.subagent_type')"
  [[ -z "${subagent_type}" ]] && subagent_type="general-purpose"
fi

prompt_seq="$(timing_current_prompt_seq)"

timing_append_start "${tool_name}" "${tool_use_id}" "${subagent_type}" "${prompt_seq}"

exit 0
