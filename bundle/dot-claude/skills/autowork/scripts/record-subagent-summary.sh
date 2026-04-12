#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${AGENT_TYPE}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi

ensure_session_dir

append_limited_state \
  "subagent_summaries.jsonl" \
  "$(jq -nc --arg ts "$(now_epoch)" --arg agent_type "${AGENT_TYPE}" --arg message "${LAST_ASSISTANT_MESSAGE}" '{ts:$ts,agent_type:$agent_type,message:$message}')" \
  "16"

# Clear the matching pending-agent entry so the pre-compact snapshot does not
# show completed dispatches as still in flight. We remove the FIFO-oldest
# match by subagent_type: SubagentStop does not carry a per-dispatch id, so
# exact tracking across same-type concurrent dispatches is not possible. For
# counting purposes (the only thing the snapshot needs), FIFO removal
# preserves the correct pending count.
#
# Robustness: the filter runs line-by-line instead of `jq --slurp`. A single
# malformed JSONL line would abort `--slurp` entirely and freeze the pending
# queue silently. Per-line parsing means one bad line is printed through
# unchanged (preserving as much queue state as possible) while still matching
# and removing the first valid entry with the target agent_type.
_clear_pending_match() {
  local pending_file
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" ]] || return 0
  [[ -s "${pending_file}" ]] || return 0

  local temp_file
  temp_file="$(mktemp "${pending_file}.XXXXXX")"

  local skipped=0
  local line this_type
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" ]]; then
      continue
    fi
    if [[ "${skipped}" -eq 0 ]]; then
      # Parse the line's agent_type field. On parse failure, preserve the
      # line and keep searching — never silently drop data.
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || printf '')"
      if [[ "${this_type}" == "${AGENT_TYPE}" ]]; then
        skipped=1
        continue
      fi
    fi
    printf '%s\n' "${line}"
  done <"${pending_file}" >"${temp_file}"

  if [[ "${skipped}" -eq 1 ]]; then
    mv "${temp_file}" "${pending_file}"
  else
    # Nothing matched — preserve the original file, discard the temp copy.
    # (We still rewrote a byte-equivalent copy; mv would be safe too, but
    # avoiding the mv reduces filesystem churn when SubagentStop fires for
    # agents not tracked in pending_agents.jsonl.)
    rm -f "${temp_file}"
  fi
}
with_state_lock _clear_pending_match || true
