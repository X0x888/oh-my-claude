#!/usr/bin/env bash
#
# posttool-timing.sh — Universal-matcher PostToolUse hook that records
# an `end` row in `<session>/timing.jsonl`. Pairs with pretool-timing.sh
# at aggregation time (Stop hook / /ulw-time / status / report).
#
# Lock-free hot path: a single sub-PIPE_BUF JSONL append per call.

set -euo pipefail

# v1.27.0 (F-022): pre-source fast-exit for OMC_TIME_TRACKING=off. See
# pretool-timing.sh for rationale.
if [[ "${OMC_TIME_TRACKING:-}" == "off" ]]; then
  exit 0
fi

# v1.27.0 (F-020): no classifier dependency — opt out of eager source.
export OMC_LAZY_CLASSIFIER=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

is_time_tracking_enabled || exit 0

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

tool_name="$(json_get '.tool_name')"
[[ -z "${tool_name}" ]] && exit 0

tool_use_id="$(json_get '.tool_use_id')"

prompt_seq="$(timing_current_prompt_seq)"

timing_append_end "${tool_name}" "${tool_use_id}" "${prompt_seq}"

exit 0
