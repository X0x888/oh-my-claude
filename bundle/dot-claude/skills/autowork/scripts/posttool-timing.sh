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

# Retain the legacy background-Bash edge marker for old-client/message-only
# hints. It is never proof that work remains live: current Stop processing
# reconciles the level `background_tasks` registry before promising a wake.
# Two-stage detection stays
# cheap AND precise: (1) a fork-free substring pre-filter on the raw
# HOOK_JSON, then (2) — only on the rare pre-filter hit — CONFIRM the marker
# is in `.tool_response` (the dispatch confirmation), not the command text
# or stdout, so a foreground command that merely prints the phrase does not
# set the flag. The json_get fork fires only on the pre-filter hit, so the
# common PostToolUse path stays fork-free. The marker is single-shot —
# stop-guard consumes it — so it cannot persist into a later turn. This is
# the Bash background marker specifically; all tool types use the Stop-level
# registry for first-class WAIT/dead-wait decisions.
if [[ "${HOOK_JSON}" == *"running in background with ID:"* ]] \
   && [[ "$(json_get '.tool_response' 2>/dev/null || true)" == *"running in background with ID:"* ]]; then
  write_state "bg_work_dispatched_ts" "$(now_epoch)" 2>/dev/null || true
fi

prompt_seq="$(timing_current_prompt_seq)"

timing_append_end "${tool_name}" "${tool_use_id}" "${prompt_seq}"

exit 0
