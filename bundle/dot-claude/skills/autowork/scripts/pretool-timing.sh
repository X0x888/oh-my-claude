#!/usr/bin/env bash
#
# pretool-timing.sh — Universal-matcher PreToolUse hook that records a
# `start` row in `<session>/timing.jsonl` for every tool call. Pairs
# with posttool-timing.sh, which writes the matching `end` row.
#
# Hot path: a single sub-PIPE_BUF JSONL append per call under the timing
# log's dedicated mutex. This path never takes the broader session-state
# lock; Stop's cap-and-rename rotation uses the same log mutex.
#
# Fast-exit when:
#   - jq is unavailable (common.sh exits 0 in that case before this runs)
#   - SESSION_ID missing (validates_session_id failure)
#   - is_time_tracking_enabled returns false (kill switch)

set -euo pipefail

# v1.27.0 (F-022): pre-source fast-exit for OMC_TIME_TRACKING=off. The
# is_time_tracking_enabled check below also catches conf-file-driven
# opt-outs, but only AFTER common.sh has sourced (~25-30ms cold-start
# tax on bash 3.2 macOS). The env-var path is the cheap branch — users
# who set OMC_TIME_TRACKING=off in their shell or omc-config.sh export
# now skip the entire hook overhead.
if [[ "${OMC_TIME_TRACKING:-}" == "off" ]]; then
  exit 0
fi

# v1.27.0 (F-020): timing hooks have no classifier dependency. Opt out
# of the eager classifier source so common.sh doesn't pay the lib's
# parse cost on every PreTool fire.
export OMC_LAZY_CLASSIFIER=1

_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
HOOK_JSON="$(_omc_read_hook_stdin)"

is_time_tracking_enabled || exit 0

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 0

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
