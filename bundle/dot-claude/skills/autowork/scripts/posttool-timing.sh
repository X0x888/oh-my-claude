#!/usr/bin/env bash
#
# posttool-timing.sh — Universal-matcher PostToolUse hook that records
# an `end` row in `<session>/timing.jsonl`. Pairs with pretool-timing.sh
# at aggregation time (Stop hook / /ulw-time / status / report).
#
# Lock-free hot path: a single sub-PIPE_BUF JSONL append per call.

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

prompt_seq="$(timing_current_prompt_seq)"

timing_append_end "${tool_name}" "${tool_use_id}" "${prompt_seq}"

exit 0
