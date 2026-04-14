#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
SOURCE="$(json_get '.source')"

if [[ -z "${SESSION_ID}" || "${SOURCE}" != "compact" ]]; then
  exit 0
fi

ensure_session_dir

handoff_file="$(session_file "compact_handoff.md")"
snapshot_file="$(session_file "precompact_snapshot.md")"

# Prefer compact_handoff.md (includes native summary + snapshot) over raw snapshot
if [[ -f "${handoff_file}" ]]; then
  snapshot_text="$(cat "${handoff_file}")"
elif [[ -f "${snapshot_file}" ]]; then
  snapshot_text="$(cat "${snapshot_file}")"
else
  exit 0
fi
snapshot_text="$(truncate_chars 9000 "${snapshot_text}")"

write_state "last_compact_rehydrate_ts" "$(now_epoch)"

# Build the injected context as an array of directives. Each directive is a
# separate paragraph so the downstream classifier can latch onto the strongest
# signal first (ULW affirmation > base continuation > pending work).

context_parts=()

# Gap 1 — ULW mode affirmation. If the session was in ultrawork before the
# compact, the native summary may drop that framing; re-assert it explicitly
# so the main thread does not drift back to asking-for-permission behavior.
workflow_mode_value="$(workflow_mode)"
task_domain_value="$(task_domain)"
if [[ "${workflow_mode_value}" == "ultrawork" ]]; then
  ulw_directive="Ultrawork mode is still active post-compact."
  if [[ -n "${task_domain_value}" ]]; then
    ulw_directive="${ulw_directive} Active task domain: ${task_domain_value}."
  fi
  ulw_directive="${ulw_directive} Do not drift back to asking-for-permission behavior, do not restart classification from scratch, and do not treat this compact boundary as a fresh session. Preserve the active objective and keep momentum high."
  context_parts+=("${ulw_directive}")
fi

# Base continuation directive (always emitted).
context_parts+=("A compaction just occurred. Continue from the preserved state below instead of restarting the task. Use the native compact summary plus this live handoff to keep continuity high. Do not fall back to a broad recap unless the user asks for one.")

# Gap 3c — pending specialist re-dispatch. If agents were in flight when the
# compact fired, list them so the main thread can re-dispatch the interrupted
# branches rather than starting over.
pending_file="$(session_file "pending_agents.jsonl")"
if [[ -s "${pending_file}" ]]; then
  pending_rendered="$(jq -r 'select(.agent_type) |
    "- \(.agent_type): \(.description // "(no description)" | gsub("[\\r\\n]+"; " ") | .[:220])"
  ' "${pending_file}" 2>/dev/null | head -n 8 || true)"
  if [[ -n "${pending_rendered}" ]]; then
    context_parts+=("Interrupted specialist dispatches detected. These agents were in flight when the compact fired — re-dispatch any branches that are still required to complete the active objective:"$'\n'"${pending_rendered}")
  fi
fi

# Gap 4b — pending-review enforcement. If the snapshot recorded that review
# was pending when compaction fired, emit a hard directive so the main thread
# does NOT stop before running the reviewer, even if the injected summary
# glosses over it.
review_pending_at_compact="$(read_state "review_pending_at_compact")"
if [[ "${review_pending_at_compact}" == "1" ]]; then
  context_parts+=("IMPORTANT: A quality review was pending before the compact boundary. You MUST run quality-reviewer (or editor-critic for doc-only edits) before the next stop — the stop guard will block you otherwise. Do not treat the compact as a reset on the review loop.")
fi

# Quality dimension continuity: remind the model which dimensions are
# done and which are still needed, so post-compact work doesn't re-run
# already-completed reviewers.
required_dims_val="$(get_required_dimensions 2>/dev/null || true)"
if [[ -n "${required_dims_val}" ]]; then
  missing_dims_val="$(missing_dimensions "${required_dims_val}" 2>/dev/null || true)"
  done_dims_val=""
  for _dtok in ${required_dims_val//,/ }; do
    _dtick="$(read_state "$(_dim_key "${_dtok}")")"
    if [[ -n "${_dtick}" ]]; then
      done_dims_val="${done_dims_val:+${done_dims_val}, }${_dtok}"
    fi
  done
  if [[ -n "${done_dims_val}" || -n "${missing_dims_val}" ]]; then
    dim_directive="Quality dimension status:"
    [[ -n "${done_dims_val}" ]] && dim_directive="${dim_directive} Completed: ${done_dims_val}."
    [[ -n "${missing_dims_val}" ]] && dim_directive="${dim_directive} Still needed: ${missing_dims_val}."
    dim_directive="${dim_directive} Do not re-run reviewers for completed dimensions."
    context_parts+=("${dim_directive}")
  fi
fi

# Join parts with blank lines between, then append the preserved state.
context_text="$(printf '%s\n\n' "${context_parts[@]}")"
context_text="${context_text}${snapshot_text}"

jq -nc --arg context "${context_text}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
