#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
TRIGGER="$(json_get '.trigger')"
CUSTOM_INSTRUCTIONS="$(json_get '.custom_instructions')"
SESSION_CWD="$(json_get '.cwd')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

snapshot_file="$(session_file "precompact_snapshot.md")"

# Gap 7 — race protection: if a prior snapshot exists and has not been
# consumed by a post-compact SessionStart handoff, archive it before we
# overwrite. "Consumed" means last_compact_rehydrate_ts is newer than the
# snapshot file's mtime. If the prior snapshot is still unread, archive it
# with a timestamp suffix and increment compact_race_count.
if [[ -f "${snapshot_file}" ]]; then
  prior_snapshot_mtime="$(_lock_mtime "${snapshot_file}")"
  last_rehydrate_ts="$(read_state "last_compact_rehydrate_ts")"
  last_rehydrate_ts="${last_rehydrate_ts:-0}"
  if [[ "${prior_snapshot_mtime}" -gt 0 ]] \
      && [[ "${prior_snapshot_mtime}" -gt "${last_rehydrate_ts}" ]]; then
    archive_name="precompact_snapshot.${prior_snapshot_mtime}.md"
    mv "${snapshot_file}" "$(session_file "${archive_name}")" 2>/dev/null || true
    prior_race_count="$(read_state "compact_race_count")"
    prior_race_count="${prior_race_count:-0}"
    write_state "compact_race_count" "$((prior_race_count + 1))"
    log_hook "pre-compact-snapshot" "race detected: archived ${archive_name}"

    # Cap archive retention at 5 to prevent unbounded accumulation.
    # shellcheck disable=SC2012
    archives_to_prune="$(ls -t "$(session_file "precompact_snapshot.")"*.md 2>/dev/null | tail -n +6 || true)"
    if [[ -n "${archives_to_prune}" ]]; then
      while IFS= read -r _old; do
        [[ -z "${_old}" ]] && continue
        rm -f "${_old}" 2>/dev/null || true
      done <<<"${archives_to_prune}"
    fi
  fi
fi

workflow_mode_value="$(workflow_mode)"
task_domain_value="$(task_domain)"
task_intent_value="$(read_state "task_intent")"
current_objective_value="$(read_state "current_objective")"
last_meta_request_value="$(read_state "last_meta_request")"
last_user_prompt_value="$(read_state "last_user_prompt")"
last_assistant_message_value="$(read_state "last_assistant_message")"
last_verify_cmd_value="$(read_state "last_verify_cmd")"
last_edit_ts="$(read_state "last_edit_ts")"
last_review_ts="$(read_state "last_review_ts")"
last_verify_ts="$(read_state "last_verify_ts")"

if [[ -z "${current_objective_value}" ]]; then
  current_objective_value="$(normalize_task_prompt "${last_user_prompt_value}")"
  if [[ -z "${current_objective_value}" ]]; then
    current_objective_value="${last_user_prompt_value}"
  fi
fi

render_review_status() {
  if [[ -z "${last_edit_ts}" ]]; then
    printf '%s\n' "No file edits recorded in this session."
    return
  fi

  if [[ -n "${last_review_ts}" && "${last_review_ts}" -ge "${last_edit_ts}" ]]; then
    printf '%s\n' "Review loop completed after the latest edits."
  else
    printf '%s\n' "Review loop still pending after the latest edits."
  fi
}

render_verification_status() {
  if [[ -z "${last_edit_ts}" ]]; then
    printf '%s\n' "No verification requirement inferred because no file edits were recorded."
    return
  fi

  if [[ -n "${last_verify_ts}" && "${last_verify_ts}" -ge "${last_edit_ts}" ]]; then
    if [[ -n "${last_verify_cmd_value}" ]]; then
      printf 'Verified after the latest edits with `%s`.\n' "${last_verify_cmd_value}"
    else
      printf '%s\n' "Verification completed after the latest edits."
    fi
  else
    printf '%s\n' "Verification is still pending or not yet recorded after the latest edits."
  fi
}

render_recent_prompts() {
  local prompts_file
  prompts_file="$(session_file "recent_prompts.jsonl")"

  if [[ ! -f "${prompts_file}" ]]; then
    return
  fi

  tail -n 3 "${prompts_file}" | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local text
    text="$(jq -r '.text | gsub("[\\r\\n]+"; " ")' <<<"${line}" 2>/dev/null || true)"
    [[ -z "${text}" ]] && continue
    printf -- '- %s\n' "$(truncate_chars 260 "${text}")"
  done
}

render_edited_files() {
  local edited_files_file
  edited_files_file="$(session_file "edited_files.log")"

  if [[ ! -f "${edited_files_file}" ]]; then
    return
  fi

  tail -n 30 "${edited_files_file}" | awk '!seen[$0]++' | tail -n 8 | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf -- '- %s\n' "${line}"
  done
}

render_subagent_summaries() {
  local summaries_file
  summaries_file="$(session_file "subagent_summaries.jsonl")"

  if [[ ! -f "${summaries_file}" ]]; then
    return
  fi

  tail -n 6 "${summaries_file}" | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    jq -r 'select(.agent_type and .message) |
      "- \(.agent_type): \(.message | gsub("[\\r\\n]+"; " ") | .[:260])"
    ' <<<"${line}" 2>/dev/null || true
  done
}

render_pending_agents() {
  local pending_file
  pending_file="$(session_file "pending_agents.jsonl")"

  if [[ ! -f "${pending_file}" ]]; then
    return
  fi

  # Unlocked read: concurrent SubagentStop may mutate the file via an
  # atomic mv() while we iterate. Because mv() is atomic on macOS/Linux,
  # we see either the pre- or post-mutation inode as a whole, never a
  # torn file. A short window of stale state in the snapshot is
  # acceptable — the snapshot is advisory, not load-bearing, and the
  # worst case is showing one extra/missing pending entry for one cycle.
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    jq -r 'select(.agent_type) |
      "- \(.agent_type): \(.description // "(no description)" | gsub("[\\r\\n]+"; " ") | .[:260])"
    ' <<<"${line}" 2>/dev/null || true
  done <"${pending_file}"
}

{
  printf '# Compact Continuity Snapshot\n\n'
  printf -- '- Session ID: `%s`\n' "${SESSION_ID}"
  printf -- '- Working directory: `%s`\n' "${SESSION_CWD}"
  printf -- '- Compact trigger: `%s`\n' "${TRIGGER:-unknown}"
  if [[ -n "${workflow_mode_value}" ]]; then
    printf -- '- Workflow mode: `%s`\n' "${workflow_mode_value}"
  fi
  if [[ -n "${task_domain_value}" ]]; then
    printf -- '- Detected task domain: `%s`\n' "${task_domain_value}"
  fi
  if [[ -n "${task_intent_value}" ]]; then
    printf -- '- Detected prompt intent: `%s`\n' "${task_intent_value}"
  fi

  if [[ -n "${current_objective_value}" ]]; then
    printf '\n## Current Objective\n%s\n' "${current_objective_value}"
  fi

  if [[ -n "${last_meta_request_value}" ]]; then
    printf '\n## Last Advisory Or Meta Request\n%s\n' "${last_meta_request_value}"
  fi

  if [[ -n "${CUSTOM_INSTRUCTIONS}" ]]; then
    printf '\n## Manual Compact Instructions\n%s\n' "${CUSTOM_INSTRUCTIONS}"
  fi

  if [[ -n "${last_assistant_message_value}" ]]; then
    printf '\n## Last Assistant State Before Compact\n%s\n' "$(truncate_chars 2000 "${last_assistant_message_value}")"
  fi

  recent_prompts_rendered="$(render_recent_prompts)"
  if [[ -n "${recent_prompts_rendered}" ]]; then
    printf '\n## Recent User Prompts\n%s\n' "${recent_prompts_rendered}"
  fi

  subagent_rendered="$(render_subagent_summaries)"
  if [[ -n "${subagent_rendered}" ]]; then
    printf '\n## Recent Specialist Conclusions\n%s\n' "${subagent_rendered}"
  fi

  pending_rendered="$(render_pending_agents)"
  if [[ -n "${pending_rendered}" ]]; then
    printf '\n## Pending Specialists (In Flight)\n%s\n' "${pending_rendered}"
  fi

  plan_file="$(session_file "current_plan.md")"
  if [[ -f "${plan_file}" ]]; then
    plan_content="$(head -c 3000 "${plan_file}")"
    if [[ -n "${plan_content}" ]]; then
      printf '\n## Active Plan\n%s\n' "${plan_content}"
    fi
  fi

  edited_files_rendered="$(render_edited_files)"
  if [[ -n "${edited_files_rendered}" ]]; then
    printf '\n## Edited Files\n%s\n' "${edited_files_rendered}"
  fi

  printf '\n## Completion State\n'
  printf -- '- %s\n' "$(render_review_status)"
  printf -- '- %s\n' "$(render_verification_status)"
} >"${snapshot_file}"

# Gap 4a — pending-review flag: if edits happened and the reviewer has not
# caught up, set a hard flag the session-start-compact handoff reads back to
# emit a "MUST run reviewer" directive on resume.
review_pending_flag=""
if [[ -n "${last_edit_ts}" ]]; then
  if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_edit_ts}" ]]; then
    review_pending_flag="1"
  fi
fi

# Gap 5 — flush: write all compact-adjacent state keys in a single batch
# so a concurrent SubagentStop cannot interleave between them. The
# atomic batch write (not the individual keys) is the mechanism that
# closes the gap; we intentionally do not set a transient "in-flight"
# marker because nothing downstream reads it and unreferenced state
# introduces a leak risk if PostCompact fails to fire.
write_state_batch \
  "last_compact_trigger" "${TRIGGER:-unknown}" \
  "last_compact_request_ts" "$(now_epoch)" \
  "review_pending_at_compact" "${review_pending_flag}"

if [[ -n "${CUSTOM_INSTRUCTIONS}" ]]; then
  write_state "last_compact_custom_instructions" "${CUSTOM_INSTRUCTIONS}"
fi
