#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# Note: this is a diagnostic script, not a hook — no SESSION_ID guard needed.
# It discovers the latest session itself rather than operating on the current one.

# --- Argument parsing ---
# `--summary` prints a compact one-shot recap: session duration, edit/verify/
# block counts, reviewer verdicts, commits, classifier misfires, outcome.
# Intended for end-of-session review so invisible quality signals (e.g.
# "3 PreTool blocks, all corrections-not-defects") become visible.
SUMMARY_MODE=0
CLASSIFIER_MODE=0
for arg in "$@"; do
  case "${arg}" in
    --summary|-s)
      SUMMARY_MODE=1
      ;;
    --classifier|-c)
      CLASSIFIER_MODE=1
      ;;
    --help|-h)
      printf 'Usage: show-status.sh [--summary | --classifier]\n'
      printf '\n'
      printf '  (no flag)      Full diagnostic status (default).\n'
      printf '  --summary      Compact end-of-session recap.\n'
      printf '  --classifier   Intent-classifier telemetry for this session\n'
      printf '                 plus cross-session misfire patterns.\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: show-status.sh [--summary | --classifier]\n' >&2
      exit 1
      ;;
  esac
done

# Find the most recent session directory via shared helper in common.sh.
latest_session="$(discover_latest_session)"

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

state_file="${STATE_ROOT}/${latest_session}/session_state.json"

if [[ ! -f "${state_file}" ]]; then
  printf 'Session %s has no state file.\n' "${latest_session}"
  exit 0
fi

SESSION_ID="${latest_session}"

# ---------------------------------------------------------------------------
# Summary mode — compact recap
# ---------------------------------------------------------------------------
if [[ "${SUMMARY_MODE}" -eq 1 ]]; then
  # Session duration
  start_ts="$(jq -r '.session_start_ts // empty' "${state_file}" 2>/dev/null || true)"
  now_ts="$(now_epoch)"
  if [[ -n "${start_ts}" ]]; then
    age=$(( now_ts - start_ts ))
    hours=$(( age / 3600 ))
    minutes=$(( (age % 3600) / 60 ))
    if [[ "${hours}" -gt 0 ]]; then
      age_human="${hours}h ${minutes}m"
    else
      age_human="${minutes}m"
    fi
  else
    age_human="unknown"
  fi

  # Edit counts
  code_edits="$(jq -r '.code_edit_count // "0"' "${state_file}" 2>/dev/null || echo "0")"
  doc_edits="$(jq -r '.doc_edit_count // "0"' "${state_file}" 2>/dev/null || echo "0")"

  # Unique files touched (from edited_files.log if present)
  unique_files=0
  edits_file="${STATE_ROOT}/${latest_session}/edited_files.log"
  if [[ -f "${edits_file}" ]]; then
    unique_files="$(sort -u "${edits_file}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  fi

  # Guard blocks (all categories) — the "invisible friction" signal
  stop_blocks="$(jq -r '.stop_guard_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"
  dim_blocks="$(jq -r '.dimension_guard_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"
  handoff_blocks="$(jq -r '.session_handoff_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"
  advisory_blocks="$(jq -r '.advisory_guard_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"
  pretool_blocks="$(jq -r '.pretool_intent_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"
  scope_blocks="$(jq -r '.discovered_scope_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"

  # Classifier misfires — how many of those blocks the post-classifier
  # heuristic judged as false-positives (prior advisory classification
  # followed by an execution-intent prompt, etc.).
  #
  # `grep -c` with no matches on a non-empty file prints "0" AND exits 1.
  # The naive `$(grep -c ... || echo 0)` concatenates "0\n0\n", which then
  # breaks `-gt 0` with `bash: [[: 0\n0: syntax error`. Pipe through
  # `tail -n1` inside a grouped command so we always get a single value.
  misfire_count=0
  telemetry_file="${STATE_ROOT}/${latest_session}/classifier_telemetry.jsonl"
  if [[ -f "${telemetry_file}" ]]; then
    misfire_count="$({ grep -c '"misfire":true' "${telemetry_file}" 2>/dev/null || true; } | tail -n1)"
    misfire_count="${misfire_count:-0}"
  fi

  # Reviewer verdicts by dimension
  verdicts_line=""
  for dim in bug_hunt code_quality stress_test completeness prose traceability design_quality; do
    verdict="$(read_state "dim_${dim}_verdict" 2>/dev/null || true)"
    [[ -z "${verdict}" ]] && continue
    # Shorten verdict to fit on one line: CLEAN → clean, FINDINGS(N) as-is
    verdicts_line="${verdicts_line:+${verdicts_line} · }${dim}:${verdict}"
  done

  # Verification status
  verify_status="none"
  verify_conf="$(jq -r '.last_verify_confidence // empty' "${state_file}" 2>/dev/null || true)"
  verify_outcome="$(jq -r '.last_verify_outcome // empty' "${state_file}" 2>/dev/null || true)"
  if [[ -n "${verify_outcome}" ]]; then
    verify_status="${verify_outcome}"
    if [[ -n "${verify_conf}" ]]; then
      verify_status="${verify_status} (${verify_conf}/100)"
    fi
  fi

  # Commits made during this session (based on session_start_ts)
  commits_line="n/a"
  if [[ -n "${start_ts}" ]] && command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    # Use --since with epoch timestamp. git accepts "@<epoch>" as a valid
    # timestamp since git 1.7.7 — same form as git log --since="@1234567890".
    commits_count="$(git log --since="@${start_ts}" --oneline 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)"
    if [[ "${commits_count}" -gt 0 ]]; then
      # Show most recent commit subjects (up to 3)
      commit_subjects="$(git log --since="@${start_ts}" --pretty=format:'%s' 2>/dev/null | head -3 | tr '\n' '|' | sed 's/|$//' | sed 's/|/ · /g' || true)"
      if [[ -n "${commit_subjects}" ]]; then
        commits_line="${commits_count} (${commit_subjects})"
      else
        commits_line="${commits_count}"
      fi
    else
      commits_line="0"
    fi
  fi

  # Subagent dispatches
  dispatches="$(jq -r '.subagent_dispatch_count // "0"' "${state_file}" 2>/dev/null || echo "0")"

  # Session outcome — the harness's own self-reported exit state
  outcome="$(jq -r '.session_outcome // "in-progress"' "${state_file}" 2>/dev/null || echo "in-progress")"

  # Current state.flags
  domain="$(jq -r '.task_domain // "unset"' "${state_file}" 2>/dev/null || echo "unset")"
  intent="$(jq -r '.task_intent // "unset"' "${state_file}" 2>/dev/null || echo "unset")"

  printf '=== ULW Session Summary ===\n'
  printf 'Session:    %s · %s · domain=%s · intent=%s\n' "${latest_session}" "${age_human}" "${domain}" "${intent}"
  printf 'Work:       %s unique files · %s code edits · %s doc edits · %s dispatches\n' \
    "${unique_files}" "${code_edits}" "${doc_edits}" "${dispatches}"
  printf 'Verify:     %s\n' "${verify_status}"
  if [[ -n "${verdicts_line}" ]]; then
    printf 'Reviews:    %s\n' "${verdicts_line}"
  else
    printf 'Reviews:    none recorded\n'
  fi

  # Guard activity — only show when non-zero to keep summary tight
  blocks_parts=""
  [[ "${stop_blocks}" -ne 0 ]]     && blocks_parts="${blocks_parts:+${blocks_parts} · }stop=${stop_blocks}"
  [[ "${dim_blocks}" -ne 0 ]]      && blocks_parts="${blocks_parts:+${blocks_parts} · }coverage=${dim_blocks}"
  [[ "${handoff_blocks}" -ne 0 ]]  && blocks_parts="${blocks_parts:+${blocks_parts} · }handoff=${handoff_blocks}"
  [[ "${advisory_blocks}" -ne 0 ]] && blocks_parts="${blocks_parts:+${blocks_parts} · }advisory=${advisory_blocks}"
  [[ "${pretool_blocks}" -ne 0 ]]  && blocks_parts="${blocks_parts:+${blocks_parts} · }pretool=${pretool_blocks}"
  [[ "${scope_blocks}" -ne 0 ]]    && blocks_parts="${blocks_parts:+${blocks_parts} · }scope=${scope_blocks}"
  if [[ -n "${blocks_parts}" ]]; then
    if [[ "${misfire_count}" -gt 0 ]]; then
      printf 'Blocks:     %s · classifier misfires=%s (see classifier_telemetry.jsonl)\n' "${blocks_parts}" "${misfire_count}"
    else
      printf 'Blocks:     %s\n' "${blocks_parts}"
    fi
  else
    printf 'Blocks:     none\n'
  fi

  printf 'Commits:    %s\n' "${commits_line}"
  printf 'Outcome:    %s\n' "${outcome}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Classifier mode — inspect intent-classifier telemetry
# ---------------------------------------------------------------------------
if [[ "${CLASSIFIER_MODE}" -eq 1 ]]; then
  telemetry_file="${STATE_ROOT}/${latest_session}/classifier_telemetry.jsonl"

  printf '=== Classifier Telemetry (current session) ===\n'
  if [[ ! -f "${telemetry_file}" ]]; then
    printf '(No telemetry recorded for session %s yet.)\n\n' "${latest_session}"
  else
    # Same `grep -c || echo 0` pitfall as above — see comment on line 110.
    total_rows="$({ wc -l < "${telemetry_file}" 2>/dev/null || true; } | tail -n1 | tr -d '[:space:]')"
    total_rows="${total_rows:-0}"
    misfire_rows="$({ grep -c '"misfire":true' "${telemetry_file}" 2>/dev/null || true; } | tail -n1)"
    misfire_rows="${misfire_rows:-0}"
    prompt_rows=$(( total_rows - misfire_rows ))

    printf 'Rows: %s prompts · %s misfires\n\n' "${prompt_rows}" "${misfire_rows}"

    printf -- '--- Classifications (last 10) ---\n'
    tail -n 10 "${telemetry_file}" 2>/dev/null | \
      jq -r 'select(.misfire != true) |
        "  [\(.intent // "?")/\(.domain // "?")] \(.prompt_preview // .prompt // "")"' 2>/dev/null || true

    if [[ "${misfire_rows}" -gt 0 ]]; then
      printf '\n--- Misfires detected ---\n'
      jq -r 'select(.misfire == true) |
        "  prior=\(.prior_intent // "?") reason=\(.reason // "?") blocks=\(.pretool_blocks_in_window // 0)"' \
        "${telemetry_file}" 2>/dev/null || true
    fi
  fi

  # Cross-session misfire ledger
  cross_file="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"
  if [[ -f "${cross_file}" ]]; then
    cross_total="$(wc -l < "${cross_file}" 2>/dev/null || echo 0)"
    cross_total="${cross_total##* }"
    printf '\n=== Classifier Misfires (cross-session) ===\n'
    printf 'Total recorded misfires: %s\n\n' "${cross_total}"
    printf -- '--- By prior intent ---\n'
    jq -r '.prior_intent // "unknown"' "${cross_file}" 2>/dev/null | \
      sort | uniq -c | sort -rn | sed 's/^/  /'
    printf '\n--- By reason ---\n'
    jq -r '.reason // "unknown"' "${cross_file}" 2>/dev/null | \
      sort | uniq -c | sort -rn | sed 's/^/  /'
    printf '\nSee %s for raw rows.\n' "${cross_file}"
  else
    printf '\n(No cross-session misfire ledger yet — it is populated during session sweeps.)\n'
  fi
  exit 0
fi

printf '=== ULW Session Status ===\n'
printf 'Session: %s\n\n' "${latest_session}"

jq -r '
  "Workflow mode:     \(.workflow_mode // "none")",
  "Task domain:       \(.task_domain // "unset")",
  "Task intent:       \(.task_intent // "unset")",
  "Project maturity:  \(.project_maturity // "unset")",
  "Objective:         \(.current_objective // "none" | .[0:100])",
  "",
  "--- Pause State (v1.18.0) ---",
  "Pause active:      \(if (.ulw_pause_active // "") == "1" then "YES (clears at next user prompt)" else "no" end)",
  "Pause count:       \((.ulw_pause_count // "0"))/2 this session",
  "Last pause reason: \(.ulw_pause_reason // "—")",
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
  "Discovered-scope:  \(.discovered_scope_blocks // "0")",
  "Serendipity fires: \(.serendipity_count // "0")\(if (.last_serendipity_fix // "") != "" then " (last: \(.last_serendipity_fix))" else "" end)",
  "Stall counter:     \(.stall_counter // "0")",
  "",
  "--- Intent Guards ---",
  "Advisory guards:       \(.advisory_guard_blocks // "0")",
  "PreTool intent blocks: \(.pretool_intent_blocks // "0")",
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

# Memory health — surfaces auto-memory dir state so users can see drift
# trends rather than discover them via the session-start hint. Reads the
# project memory dir resolved via Claude Code's cwd-encoding convention
# (cwd → cwd with `/` → `-`). Skipped when auto_memory=off (no signal
# worth surfacing) or when the dir does not exist (fresh user).
if is_auto_memory_enabled 2>/dev/null; then
  _mem_dir="$(omc_memory_dir_for_cwd)"
  if [[ -n "${_mem_dir}" && -d "${_mem_dir}" ]]; then
    _mem_total="$(find "${_mem_dir}" -maxdepth 1 -type f -name '*.md' \
      -not -name 'MEMORY.md' 2>/dev/null | wc -l | tr -d '[:space:]')"
    _mem_stale="$(find "${_mem_dir}" -maxdepth 1 -type f -name '*.md' \
      -not -name 'MEMORY.md' -mtime +30 2>/dev/null | wc -l | tr -d '[:space:]')"
    _mem_oldest_iso="-"
    if [[ "${_mem_total}" -gt 0 ]]; then
      # Oldest mtime in YYYY-MM-DD form; cross-platform stat -f / -c shim.
      # NUL-delimited handoff (-print0 / xargs -0) keeps non-alphanumeric
      # memory filenames safe and is the SC2038-clean form. BSD stat
      # (macOS) accepts multiple file args, so dropping `-I {}` lets
      # xargs batch them into one invocation. The GNU-find fallback
      # (`-printf`) does not pipe through xargs, so it is unaffected.
      _mem_oldest_path="$(find "${_mem_dir}" -maxdepth 1 -type f -name '*.md' \
        -not -name 'MEMORY.md' -print0 2>/dev/null \
        | xargs -0 stat -f '%m %N' 2>/dev/null \
        || find "${_mem_dir}" -maxdepth 1 -type f -name '*.md' \
          -not -name 'MEMORY.md' -printf '%T@ %p\n' 2>/dev/null \
        || true)"
      if [[ -n "${_mem_oldest_path}" ]]; then
        _mem_oldest_iso="$(printf '%s\n' "${_mem_oldest_path}" \
          | sort -n | head -1 | awk '{print $1}' \
          | xargs -I {} date -r {} +%Y-%m-%d 2>/dev/null \
          || printf '?')"
      fi
    fi
    _mem_hint_emitted="$(jq -r '.memory_drift_hint_emitted // ""' \
      "${state_file}" 2>/dev/null || true)"
    printf '\n--- Memory Health ---\n'
    printf 'Memory dir:                %s\n' "${_mem_dir}"
    printf 'Total entries:             %s (oldest: %s)\n' "${_mem_total}" "${_mem_oldest_iso}"
    if [[ "${_mem_stale}" -gt 0 ]]; then
      printf 'Stale (>30d):              %s — run /memory-audit to triage\n' "${_mem_stale}"
    else
      printf 'Stale (>30d):              0 — directory is fresh\n'
    fi
    printf 'Drift hint emitted (this session): %s\n' \
      "$( [[ "${_mem_hint_emitted}" == "1" ]] && printf 'yes' || printf 'no' )"
  fi
fi

# Discovered-scope findings (advisory specialist findings captured this session)
scope_file="${STATE_ROOT}/${latest_session}/discovered_scope.jsonl"
if [[ -f "${scope_file}" ]]; then
  scope_total="$(read_total_scope_count)"
  scope_pending="$(read_scope_count_by_status "pending")"
  scope_shipped="$(read_scope_count_by_status "shipped")"
  scope_deferred="$(read_scope_count_by_status "deferred")"
  printf 'Discovered findings:       %s total · %s pending · %s shipped · %s deferred\n' \
    "${scope_total:-0}" "${scope_pending:-0}" "${scope_shipped:-0}" "${scope_deferred:-0}"
fi

# Council Phase 8 wave plan (when active)
findings_file="${STATE_ROOT}/${latest_session}/findings.json"
if [[ -f "${findings_file}" ]]; then
  wave_total="$(jq -r '(.waves // []) | length' "${findings_file}" 2>/dev/null || echo 0)"
  if [[ "${wave_total:-0}" -gt 0 ]]; then
    waves_done="$(jq -r '[(.waves // [])[] | select(.status == "completed")] | length' "${findings_file}" 2>/dev/null || echo 0)"
    waves_in_prog="$(jq -r '[(.waves // [])[] | select(.status == "in_progress")] | length' "${findings_file}" 2>/dev/null || echo 0)"
    f_total="$(jq -r '.findings | length' "${findings_file}" 2>/dev/null || echo 0)"
    f_shipped="$(jq -r '[.findings[] | select(.status == "shipped")] | length' "${findings_file}" 2>/dev/null || echo 0)"
    f_pending="$(jq -r '[.findings[] | select(.status == "pending")] | length' "${findings_file}" 2>/dev/null || echo 0)"
    current_surface="$(jq -r 'first((.waves // [])[] | select(.status == "in_progress") | .surface) // first((.waves // [])[] | select(.status == "pending") | .surface) // "—"' "${findings_file}" 2>/dev/null)"
    printf 'Wave plan:                 %s/%s completed · %s in-progress · current surface: %s\n' \
      "${waves_done:-0}" "${wave_total}" "${waves_in_prog:-0}" "${current_surface:-—}"
    printf 'Wave findings:             %s total · %s shipped · %s pending\n' \
      "${f_total:-0}" "${f_shipped:-0}" "${f_pending:-0}"
  fi
fi

# Show dimension status if dimensions are active
dim_output=""
for dim in bug_hunt code_quality stress_test completeness prose traceability design_quality; do
  dim_ts="$(read_state "$(_dim_key "${dim}")")"
  dim_verdict="$(read_state "dim_${dim}_verdict")"
  [[ -n "${dim_ts}" || -n "${dim_verdict}" ]] || continue

  if [[ -n "${dim_ts}" ]]; then
    if is_dimension_valid "${dim}"; then
      dim_line="${dim}: ticked @ ${dim_ts}"
    else
      dim_line="${dim}: stale @ ${dim_ts}"
    fi
    [[ -n "${dim_verdict}" ]] && dim_line="${dim_line} [${dim_verdict}]"
  elif [[ "${dim_verdict}" == "FINDINGS" ]]; then
    dim_line="${dim}: findings reported"
  else
    dim_line="${dim}: ${dim_verdict}"
  fi

  dim_output="${dim_output}${dim_line}\n"
done
if [[ -n "${dim_output}" ]]; then
  printf '\n--- Dimension Ticks ---\n'
  printf '%b' "${dim_output}"
fi

# Show verification confidence if available
verify_conf="$(jq -r '.last_verify_confidence // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${verify_conf}" ]]; then
  verify_method="$(jq -r '.last_verify_method // "unknown"' "${state_file}" 2>/dev/null || true)"
  printf '\n--- Verification Confidence ---\n'
  printf 'Confidence: %s/100  Method: %s\n' "${verify_conf}" "${verify_method}"
fi

# Show project profile (cached or detected on demand)
profile_val="$(get_project_profile 2>/dev/null || true)"
if [[ -n "${profile_val}" ]]; then
  printf '\n--- Project Profile ---\n'
  printf '%s\n' "${profile_val}"
fi

# Show guard exhaustion mode
printf '\n--- Guard Configuration ---\n'
printf 'Exhaustion mode:     %s\n' "${OMC_GUARD_EXHAUSTION_MODE}"
printf 'Gate level:          %s\n' "${OMC_GATE_LEVEL}"
printf 'Verify confidence:   %s (threshold: %s)\n' \
  "$(jq -r '.last_verify_confidence // "n/a"' "${state_file}" 2>/dev/null || echo "n/a")" \
  "${OMC_VERIFY_CONFIDENCE_THRESHOLD}"

# Session timing
session_start="$(jq -r '.session_start_ts // empty' "${state_file}" 2>/dev/null || true)"
if [[ -n "${session_start}" ]]; then
  session_age=$(( $(date +%s) - session_start ))
  printf 'Session age:         %dm %ds\n' "$((session_age / 60))" "$((session_age % 60))"
fi

# Subagent dispatch count
dispatch_count="$(jq -r '.subagent_dispatch_count // "0"' "${state_file}" 2>/dev/null || echo "0")"
printf 'Subagent dispatches: %s\n' "${dispatch_count}"

# Show agent performance metrics (cross-session)
metrics_file="${HOME}/.claude/quality-pack/agent-metrics.json"
if [[ -f "${metrics_file}" ]]; then
  metrics_output="$(jq -r '
    to_entries | map(select(.key | startswith("_") | not)) | map(select(.value | type == "object")) |
    sort_by(-.value.invocations) |
    if length > 0 then
      [.[] | "\(.key): \(.value.invocations) runs, \(.value.clean_verdicts) clean, \(.value.finding_verdicts) findings"] | join("\n")
    else empty end
  ' "${metrics_file}" 2>/dev/null || true)"
  if [[ -n "${metrics_output}" ]]; then
    printf '\n--- Agent Metrics (cross-session) ---\n'
    printf '%s\n' "${metrics_output}"
  fi
fi

# Show defect patterns (cross-session)
defect_file="${HOME}/.claude/quality-pack/defect-patterns.json"
if [[ -f "${defect_file}" ]]; then
  _ensure_valid_defect_patterns
  cutoff_ts="$(( $(now_epoch) - 90 * 86400 ))"
  defect_output="$(jq -r --argjson cutoff "${cutoff_ts}" '
    to_entries |
    map(select(.key | startswith("_") | not)) |
    map(select(.value | type == "object")) |
    map(select(.value.last_seen_ts > $cutoff)) |
    sort_by(-.value.count) |
    if length > 0 then
      [.[] | "\(.key): \(.value.count) occurrences (last example: \((.value.examples // [])[-1] // "n/a" | .[0:60]))"] | join("\n")
    else empty end
  ' "${defect_file}" 2>/dev/null || true)"
  if [[ -n "${defect_output}" ]]; then
    printf '\n--- Defect Patterns (cross-session) ---\n'
    printf '%s\n' "${defect_output}"
  fi
fi

# Show edited files if any
edits_file="${STATE_ROOT}/${latest_session}/edited_files.log"
if [[ -f "${edits_file}" ]]; then
  printf '\n--- Edited Files ---\n'
  sort -u "${edits_file}" | tail -20
fi
