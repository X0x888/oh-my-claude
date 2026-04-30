#!/usr/bin/env bash
# show-report.sh — render a markdown digest of cross-session harness activity.
#
# Backs the `/ulw-report` skill. Reads from the cross-session aggregates under
# ~/.claude/quality-pack/ and prints a sectioned markdown report so the user
# can answer "is this harness actually working for me?" without grepping JSONL.
#
# Modes (single positional arg):
#   last   — most recent session only
#   week   — sessions in the last 7 days (default)
#   month  — sessions in the last 30 days
#   all    — every available row
#
# Exit codes:
#   0 on success, even when no data is found (renders an empty-state message)
#   2 on usage error (unknown mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

QP_ROOT="${HOME}/.claude/quality-pack"
SUMMARY_FILE="${QP_ROOT}/session_summary.jsonl"
SERENDIPITY_FILE="${QP_ROOT}/serendipity-log.jsonl"
MISFIRES_FILE="${QP_ROOT}/classifier_misfires.jsonl"
GATE_EVENTS_FILE="${QP_ROOT}/gate_events.jsonl"
ARCHETYPES_FILE="${QP_ROOT}/used-archetypes.jsonl"
AGENT_METRICS_FILE="${QP_ROOT}/agent-metrics.json"
DEFECT_PATTERNS_FILE="${QP_ROOT}/defect-patterns.json"

MODE="${1:-week}"
case "${MODE}" in
  last|week|month|all) ;;
  --help|-h)
    cat <<'USAGE'
Usage: show-report.sh [last|week|month|all]

  last   Most recent session only.
  week   Sessions in the last 7 days (default).
  month  Sessions in the last 30 days.
  all    Every available row across cross-session aggregates.

Reads from ~/.claude/quality-pack/{session_summary,serendipity-log,classifier_misfires}.jsonl
and ~/.claude/quality-pack/{agent-metrics,defect-patterns}.json.
USAGE
    exit 0
    ;;
  *)
    printf 'show-report: unknown mode %q (expected: last|week|month|all)\n' "${MODE}" >&2
    exit 2
    ;;
esac

now="$(date +%s)"
case "${MODE}" in
  last)  cutoff_ts=0 ;;
  week)  cutoff_ts=$(( now - 7 * 86400 )) ;;
  month) cutoff_ts=$(( now - 30 * 86400 )) ;;
  all)   cutoff_ts=0 ;;
esac

# Window header
case "${MODE}" in
  last)  window_label="most recent session" ;;
  week)  window_label="last 7 days" ;;
  month) window_label="last 30 days" ;;
  all)   window_label="all time" ;;
esac

printf '# Harness report — %s\n\n' "${window_label}"
printf '_Generated %s. Source: `~/.claude/quality-pack/`._\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# Interpretation footer accumulators (v1.17.0). Each section below
# updates these as it computes its own metrics; the final
# "Patterns to consider" block at the bottom turns them into 1-line
# actionable suggestions. Defaults to "no signal" so the footer renders
# cleanly on empty datasets.
_intp_session_count=0
_intp_block_total=0
_intp_skip_total=0
_intp_serendipity_total=0
_intp_reviewed=0
_intp_exhausted=0
_intp_misfires=0
_intp_arche_top_count=0
_intp_arche_top_name=""
_intp_arche_unique=0
_intp_reviewer_rate=""

# ----------------------------------------------------------------------
# Helper: filter JSONL rows by a timestamp field within the cutoff window.
# Reads file path from $1, ts field jq path from $2 (e.g. '.start_ts' or '.ts').
filter_by_window() {
  local file="$1" ts_path="$2"
  [[ -f "${file}" ]] || return 0
  if [[ "${MODE}" == "all" ]]; then
    cat "${file}"
  elif [[ "${MODE}" == "last" ]]; then
    tail -n 1 "${file}"
  else
    jq -c --argjson cutoff "${cutoff_ts}" \
      "select((${ts_path} // 0 | tonumber) >= \$cutoff)" "${file}" 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------------
# Section 1: Sessions overview
printf '## Sessions\n\n'
sessions_rows="$(filter_by_window "${SUMMARY_FILE}" '.start_ts')"
if [[ -z "${sessions_rows}" ]]; then
  printf '_No session_summary rows in window. Run a few sessions, then re-check after the next daily sweep._\n\n'
else
  session_count="$(printf '%s\n' "${sessions_rows}" | grep -c .)"
  total_edits="$(printf '%s\n' "${sessions_rows}" | jq -s 'map(.edit_count // 0) | add // 0')"
  total_blocks="$(printf '%s\n' "${sessions_rows}" | jq -s 'map((.guard_blocks // 0) + (.dim_blocks // 0)) | add // 0')"
  total_dispatches="$(printf '%s\n' "${sessions_rows}" | jq -s 'map(.dispatches // 0) | add // 0')"
  total_skips="$(printf '%s\n' "${sessions_rows}" | jq -s 'map(.skip_count // 0) | add // 0')"
  total_serendipity="$(printf '%s\n' "${sessions_rows}" | jq -s 'map(.serendipity_count // 0) | add // 0')"
  reviewed_sessions="$(printf '%s\n' "${sessions_rows}" | jq -s 'map(select(.reviewed == true)) | length')"
  exhausted_sessions="$(printf '%s\n' "${sessions_rows}" | jq -s 'map(select(.exhausted == true)) | length')"
  printf '| Metric | Value |\n|---|---|\n'
  printf '| Sessions | %s |\n' "${session_count}"
  printf '| Files edited | %s |\n' "${total_edits}"
  printf '| Quality-gate blocks fired | %s |\n' "${total_blocks}"
  printf '| Skips honored | %s |\n' "${total_skips}"
  printf '| Subagent dispatches | %s |\n' "${total_dispatches}"
  printf '| Sessions with reviewer pass | %s |\n' "${reviewed_sessions}"
  printf '| Sessions that exhausted gates | %s |\n' "${exhausted_sessions}"
  printf '| Serendipity Rule applications | %s |\n' "${total_serendipity}"
  printf '\n'
  _intp_session_count="${session_count}"
  _intp_block_total="${total_blocks}"
  _intp_skip_total="${total_skips}"
  _intp_serendipity_total="${total_serendipity}"
  _intp_reviewed="${reviewed_sessions}"
  _intp_exhausted="${exhausted_sessions}"
fi

# ----------------------------------------------------------------------
# Section 2: Findings & waves (Council Phase 8)
printf '## Findings & waves\n\n'
printf '_Phase 8 findings/waves only join `session_summary.jsonl` at sweep time. Active in-flight wave plans live in the current session — use `/ulw-status` to see them._\n\n'
findings_rows="$(printf '%s\n' "${sessions_rows}" | jq -c 'select(.findings != null and (.findings.total // 0) > 0)')"
if [[ -z "${findings_rows}" ]]; then
  printf '_No swept finding lists in window._\n\n'
else
  findings_total="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.findings.total // 0) | add // 0')"
  shipped="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.findings.shipped // 0) | add // 0')"
  deferred="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.findings.deferred // 0) | add // 0')"
  rejected="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.findings.rejected // 0) | add // 0')"
  pending="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.findings.pending // 0) | add // 0')"
  waves_total="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.waves.total // 0) | add // 0')"
  waves_completed="$(printf '%s\n' "${findings_rows}" | jq -s 'map(.waves.completed // 0) | add // 0')"
  printf '| Metric | Value |\n|---|---|\n'
  printf '| Findings tracked | %s |\n' "${findings_total}"
  printf '| Shipped | %s |\n' "${shipped}"
  printf '| Deferred | %s |\n' "${deferred}"
  printf '| Rejected | %s |\n' "${rejected}"
  printf '| Still pending at sweep | %s |\n' "${pending}"
  printf '| Waves planned | %s |\n' "${waves_total}"
  printf '| Waves completed | %s |\n' "${waves_completed}"
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 2b: Design archetype variation (cross-session anti-anchoring audit)
printf '## Design archetype variation\n\n'
archetype_rows="$(filter_by_window "${ARCHETYPES_FILE}" '.ts')"
if [[ -z "${archetype_rows}" ]]; then
  printf '_No design archetypes recorded in window — UI work absent or no contracts emitted._\n\n'
else
  arche_count="$(printf '%s\n' "${archetype_rows}" | grep -c .)"
  unique_arches="$(printf '%s\n' "${archetype_rows}" | jq -r '.archetype // empty' | sort -u | grep -c . || true)"
  unique_projects="$(printf '%s\n' "${archetype_rows}" | jq -r '.project_key // empty' | sort -u | grep -c . || true)"
  printf '%s archetype emission%s across %s unique archetype%s and %s project%s.\n\n' \
    "${arche_count}" "$([[ "${arche_count}" -eq 1 ]] && echo "" || echo "s")" \
    "${unique_arches}" "$([[ "${unique_arches}" -eq 1 ]] && echo "" || echo "s")" \
    "${unique_projects}" "$([[ "${unique_projects}" -eq 1 ]] && echo "" || echo "s")"
  printf 'Top archetypes (by total emissions, newest 5):\n\n'
  printf '%s\n' "${archetype_rows}" | jq -r '.archetype // "unknown"' \
    | sort | uniq -c | sort -rn | head -5 \
    | while read -r n arche; do
        printf -- '- `%s` × %s\n' "${arche}" "${n}"
      done
  printf '\n'
  _intp_arche_unique="${unique_arches}"
  _intp_arche_top_count="$(printf '%s\n' "${archetype_rows}" | jq -r '.archetype // "unknown"' \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')"
  _intp_arche_top_name="$(printf '%s\n' "${archetype_rows}" | jq -r '.archetype // "unknown"' \
    | sort | uniq -c | sort -rn | head -1 | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
  _intp_arche_top_count="${_intp_arche_top_count:-0}"
fi

# ----------------------------------------------------------------------
# Section 3: Serendipity catches (sample)
printf '## Serendipity catches\n\n'
serendipity_rows="$(filter_by_window "${SERENDIPITY_FILE}" '.ts')"
if [[ -z "${serendipity_rows}" ]]; then
  printf '_No Serendipity Rule applications in window._\n\n'
else
  count="$(printf '%s\n' "${serendipity_rows}" | grep -c .)"
  printf '%s catch%s. Recent fixes (newest first, up to 5):\n\n' "${count}" "$([[ "${count}" -eq 1 ]] && echo "" || echo "es")"
  printf '%s\n' "${serendipity_rows}" | tail -n 5 | jq -r '"- \(.fix)\(if (.original_task // "") != "" then " (during: \(.original_task))" else "" end)"' || true
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4: Classifier health
printf '## Classifier health\n\n'
misfire_rows="$(filter_by_window "${MISFIRES_FILE}" '.ts')"
if [[ -z "${misfire_rows}" ]]; then
  printf '_No classifier misfires recorded in window — clean signal._\n\n'
else
  count="$(printf '%s\n' "${misfire_rows}" | grep -c .)"
  printf '%s misfire row%s recorded.\n\n' "${count}" "$([[ "${count}" -eq 1 ]] && echo "" || echo "s")"
  printf 'Top reasons:\n\n'
  printf '%s\n' "${misfire_rows}" | jq -r '.reason // "unknown"' | sort | uniq -c | sort -rn | head -5 | while read -r n reason; do
    printf -- '- `%s` × %s\n' "${reason}" "${n}"
  done
  printf '\n'
  _intp_misfires="${count}"
fi

# ----------------------------------------------------------------------
# Section 4b: Gate event outcomes (per-event attribution, v1.14.0)
printf '## Gate event outcomes\n\n'
gate_event_rows="$(filter_by_window "${GATE_EVENTS_FILE}" '.ts')"
if [[ -z "${gate_event_rows}" ]]; then
  printf '_No gate events recorded in window. Per-event telemetry is new in v1.14.0; populates as sessions sweep._\n\n'
else
  printf 'Per-event outcome attribution — every gate fire and finding-status change in the window.\n\n'
  printf '| Gate | Blocks | Overrides | Status changes |\n'
  printf '|---|---:|---:|---:|\n'
  # Note: prior revision had a "Releases" column, but no caller emits a
  # `release` event today (forward-compat scaffolding). Dropped to keep
  # the rendered table honest until a release-event emitter lands. The
  # "Overrides" column was added in v1.21.0 to surface `wave_override`
  # events emitted by `pretool-intent-guard.sh` when a council Phase 8
  # wave plan is active and the gate short-circuits the deny — without
  # this column, the override telemetry was on disk but invisible to
  # /ulw-report, making "how often did the wave override fire?"
  # unanswerable. Counts use `wc -l` over jq output — `grep -c . || echo
  # 0` produced a literal "0\n0" string when grep matched nothing AND
  # emitted 0, which broke the markdown table for every realistic dataset.
  # Overrides column counts BOTH wave_override (v1.21.0, council Phase 8
  # per-wave commits) AND prompt_text_override (v1.23.0, raw-prompt-text
  # trust override). Both events represent the same conceptual class —
  # the gate would have denied but a defense-in-depth path allowed —
  # so they share the column. The totals line below breaks the count
  # back out by event type for users who care which path fired.
  printf '%s\n' "${gate_event_rows}" \
    | jq -r '.gate' \
    | sort -u \
    | while IFS= read -r _gate; do
        [[ -z "${_gate}" ]] && continue
        _block_count="$(printf '%s\n' "${gate_event_rows}" | jq -c --arg g "${_gate}" 'select(.gate == $g and .event == "block")' | wc -l | tr -d '[:space:]')"
        _override_count="$(printf '%s\n' "${gate_event_rows}" | jq -c --arg g "${_gate}" 'select(.gate == $g and (.event == "wave_override" or .event == "prompt_text_override"))' | wc -l | tr -d '[:space:]')"
        _status_count="$(printf '%s\n' "${gate_event_rows}" | jq -c --arg g "${_gate}" 'select(.gate == $g and (.event == "finding-status-change" or .event == "wave-status-change" or .event == "user-decision-marked"))' | wc -l | tr -d '[:space:]')"
        printf '| `%s` | %s | %s | %s |\n' "${_gate}" "${_block_count}" "${_override_count}" "${_status_count}"
      done
  printf '\n'
  total_blocks_pe="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "block")' | wc -l | tr -d '[:space:]')"
  total_wave_overrides="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "wave_override")' | wc -l | tr -d '[:space:]')"
  total_prompt_overrides="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "prompt_text_override")' | wc -l | tr -d '[:space:]')"
  total_overrides=$((total_wave_overrides + total_prompt_overrides))
  total_status_changes="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "finding-status-change" or .event == "wave-status-change" or .event == "user-decision-marked")' | wc -l | tr -d '[:space:]')"
  shipped_changes="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "finding-status-change" and .details.finding_status == "shipped")' | wc -l | tr -d '[:space:]')"
  user_decision_marks="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "user-decision-marked")' | wc -l | tr -d '[:space:]')"
  totals_line="_Total: ${total_blocks_pe} gate blocks"
  if [[ "${total_overrides}" -gt 0 ]]; then
    if [[ "${total_wave_overrides}" -gt 0 ]] && [[ "${total_prompt_overrides}" -gt 0 ]]; then
      totals_line="${totals_line}, ${total_overrides} override allow(s) (${total_wave_overrides} wave / ${total_prompt_overrides} prompt-text)"
    elif [[ "${total_wave_overrides}" -gt 0 ]]; then
      totals_line="${totals_line}, ${total_wave_overrides} wave-override allow(s)"
    else
      totals_line="${totals_line}, ${total_prompt_overrides} prompt-text override allow(s)"
    fi
  fi
  totals_line="${totals_line}, ${total_status_changes} status changes (${shipped_changes} findings shipped"
  [[ "${user_decision_marks}" -gt 0 ]] && totals_line="${totals_line}, ${user_decision_marks} user-decision marks"
  totals_line="${totals_line})._"
  printf '%s\n\n' "${totals_line}"
fi

# ----------------------------------------------------------------------
# Section 4c: Bias-defense directive fires (v1.23.0)
#
# The router emits gate events with gate="bias-defense" when an
# execution-prompt directive fires (prometheus-suggest, intent-verify,
# exemplifying). Without this section the user could not answer "is
# the new exemplifying directive actually firing on my prompts?" or
# "how often does the narrowing layer kick in?" — the very telemetry
# needed to validate that the v1.23.0 release is working.
printf '## Bias-defense directives fired\n\n'
bias_defense_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "bias-defense" and .event == "directive_fired")' 2>/dev/null || true)"
if [[ -z "${bias_defense_rows}" ]]; then
  printf '_No bias-defense directives fired in window. Telemetry is new in v1.23.0; populates as sessions sweep._\n\n'
else
  printf '| Directive | Fires |\n|---|---:|\n'
  for _directive in exemplifying prometheus-suggest intent-verify; do
    _fire_count="$(printf '%s\n' "${bias_defense_rows}" | jq -c --arg d "${_directive}" 'select(.details.directive == $d)' | wc -l | tr -d '[:space:]')"
    [[ "${_fire_count}" -eq 0 ]] && continue
    printf '| `%s` | %s |\n' "${_directive}" "${_fire_count}"
  done
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4c2: Mark-deferred strict-bypasses
#
# When OMC_MARK_DEFERRED_STRICT=off is in effect AND the deferral reason
# would have been rejected by the require-WHY validator, mark-deferred.sh
# emits gate=mark-deferred event=strict-bypass with the reason captured
# under .details.reason. The validator's error message at line 62 of
# mark-deferred.sh promises "audited"; without this aggregation the
# audit row landed in the JSONL but was invisible to the user.
#
# Surfaces only when at least one bypass fired in the window. A clean
# session sees no row, the placeholder hides the section entirely, and
# the report stays terse.
mark_deferred_bypass_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "mark-deferred" and .event == "strict-bypass")' 2>/dev/null || true)"
if [[ -n "${mark_deferred_bypass_rows}" ]]; then
  bypass_count="$(printf '%s\n' "${mark_deferred_bypass_rows}" | grep -c .)"
  printf '## Mark-deferred strict-bypasses\n\n'
  printf '_%s reason(s) bypassed the require-WHY validator via OMC_MARK_DEFERRED_STRICT=off._\n\n' \
    "${bypass_count}"
  printf '| When | Reason (head 80) |\n|---|---|\n'
  printf '%s\n' "${mark_deferred_bypass_rows}" \
    | jq -r --slurp 'sort_by(.ts) | reverse | .[0:10][] |
      "| \(.ts // "—") | \((.details.reason // "—") | .[0:80]) |"' \
    2>/dev/null || true
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4d: Wave-shape distribution (v1.22.0 — F-019)
# Aggregates wave-plan gate events emitted by record-finding-list.sh
# assign-wave so users can answer "are my recent wave plans actually
# meeting the 5-10 findings/wave bar?" without grep'ing JSON.
printf '## Wave-shape distribution\n\n'
wave_assigned_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.event == "wave-assigned")' 2>/dev/null || true)"
narrow_warning_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.event == "narrow-wave-warning")' 2>/dev/null || true)"
wave_shape_block_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "wave-shape" and .event == "block")' 2>/dev/null || true)"
if [[ -z "${wave_assigned_rows}" ]]; then
  printf '_No wave assignments recorded in window — Council Phase 8 not used or telemetry not yet swept._\n\n'
else
  total_waves_assigned="$(printf '%s\n' "${wave_assigned_rows}" | grep -c .)"
  narrow_count="$(printf '%s\n' "${narrow_warning_rows}" | grep -c . || true)"
  block_count="$(printf '%s\n' "${wave_shape_block_rows}" | grep -c . || true)"
  # Median findings-per-wave: extract finding_count from each wave-assigned
  # row, sort, pick middle. Fail-open on empty.
  median_per_wave="$(printf '%s\n' "${wave_assigned_rows}" \
    | jq -r '.details.finding_count // empty' \
    | sort -n \
    | awk 'NR==1{first=$1} {a[NR]=$1} END{if(NR==0){print "n/a"} else {print a[int((NR+1)/2)]}}')"
  printf '| Metric | Value |\n|---|---|\n'
  printf '| Waves assigned (window) | %s |\n' "${total_waves_assigned}"
  printf '| Median findings/wave | %s |\n' "${median_per_wave}"
  printf '| Narrow-wave warnings (advisory) | %s |\n' "${narrow_count}"
  printf '| Wave-shape gate blocks | %s |\n' "${block_count}"
  printf '\n'
  if [[ "${narrow_count}" -gt 0 ]] || [[ "${block_count}" -gt 0 ]]; then
    printf '**Recent under-segmented waves:**\n\n'
    printf '%s\n' "${narrow_warning_rows}" \
      | jq -r --slurp 'sort_by(.ts) | reverse | .[0:5][] |
        "- wave \(.details.wave_idx)/\(.details.wave_total) (surface: \(.details.surface // "—"), \(.details.finding_count) finding\(if .details.finding_count == 1 then "" else "s" end), avg \(.details.avg_per_wave // "—")/wave)"' \
      2>/dev/null || true
    printf '\n'
  fi
  if [[ "${total_waves_assigned}" -gt 5 ]] && [[ "${narrow_count}" -gt 0 ]]; then
    narrow_ratio_pct=$((narrow_count * 100 / total_waves_assigned))
    if [[ "${narrow_ratio_pct}" -ge 30 ]]; then
      printf '_⚠ **%s%% of waves were under-segmented**. The canonical Phase 8 bar is 5-10 findings/wave; consistent narrow-wave warnings suggest the model is over-segmenting. Review your prompt patterns or consider tightening `is_wave_plan_under_segmented` thresholds._\n\n' "${narrow_ratio_pct}"
    fi
  fi
fi

# ----------------------------------------------------------------------
# Section 4c: User-decision queue (v1.18.0)
# Aggregate user-decision-marked events from gate_events + scan
# discovered findings.json files for findings still flagged
# requires_user_decision=true and pending. The queue is the surface
# the user wants for "what decisions are waiting on me?".
printf '## User-decision queue\n\n'
ud_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.event == "user-decision-marked")' 2>/dev/null || true)"
ud_total=0
if [[ -n "${ud_rows}" ]]; then
  ud_total="$(printf '%s\n' "${ud_rows}" | wc -l | tr -d '[:space:]')"
fi
# Walk per-session findings.json files for currently-pending USER-DECISION
# rows (the live queue, not historical marks).
state_root_for_decisions="${HOME}/.claude/quality-pack/state"
pending_ud_count=0
pending_ud_rows=""
if [[ -d "${state_root_for_decisions}" ]]; then
  while IFS= read -r findings_path; do
    [[ -f "${findings_path}" ]] || continue
    session_id_for_row="$(basename "$(dirname "${findings_path}")")"
    rows="$(jq -c --arg sid "${session_id_for_row}" \
      '.findings[]
        | select((.requires_user_decision // false) == true
                 and (.status == "pending" or .status == "in_progress"))
        | { sid: $sid, id: .id, surface: (.surface // "—"),
            summary: (.summary // "—" | gsub("\\|"; "\\|") | gsub("\n"; " ")),
            reason: (.decision_reason // "—" | gsub("\\|"; "\\|") | gsub("\n"; " ")) }' \
      "${findings_path}" 2>/dev/null || true)"
    if [[ -n "${rows}" ]]; then
      pending_ud_rows="${pending_ud_rows:+${pending_ud_rows}$'\n'}${rows}"
    fi
  done < <(find "${state_root_for_decisions}" -name 'findings.json' -type f 2>/dev/null)
  if [[ -n "${pending_ud_rows}" ]]; then
    pending_ud_count="$(printf '%s\n' "${pending_ud_rows}" | wc -l | tr -d '[:space:]')"
  fi
fi

if [[ "${ud_total}" -eq 0 && "${pending_ud_count}" -eq 0 ]]; then
  printf '_No user-decision findings in window. Findings flagged with `requires_user_decision: true` (council Phase 5 / `mark-user-decision`) and `/ulw-pause` events appear here._\n\n'
else
  printf '%d historical mark(s); %d currently awaiting input.\n\n' \
    "${ud_total}" "${pending_ud_count}"
  if [[ "${pending_ud_count}" -gt 0 ]]; then
    printf '**Awaiting input now:**\n\n'
    printf '| Session | Finding | Surface | Reason |\n'
    printf '|---|---|---|---|\n'
    printf '%s\n' "${pending_ud_rows}" | jq -r \
      '"| \(.sid[0:8]) | \(.id) | \(.surface) | \(.reason) |"'
    printf '\n'
  fi
fi

# ----------------------------------------------------------------------
# Section 5: Reviewer activity (top by invocations)
printf '## Reviewer activity\n\n'
if [[ -f "${AGENT_METRICS_FILE}" ]]; then
  has_data="$(jq 'if type == "object" then ((.agents // {}) | length) > 0 else false end' "${AGENT_METRICS_FILE}" 2>/dev/null || echo false)"
  if [[ "${has_data}" == "true" ]]; then
    printf '| Reviewer | Invocations | Clean | Findings | Find rate |\n'
    printf '|---|---:|---:|---:|---:|\n'
    jq -r '
      .agents // {} | to_entries
      | map({
          name: .key,
          inv: (.value.invocations // 0),
          clean: (.value.clean_verdicts // 0),
          finds: (.value.finding_verdicts // 0)
        })
      | map(select(.inv > 0))
      | sort_by(-.inv)
      | .[0:8]
      | .[]
      | "| `\(.name)` | \(.inv) | \(.clean) | \(.finds) | \(if .inv > 0 then ((.finds * 100 / .inv) | floor | tostring + "%") else "—" end) |"
    ' "${AGENT_METRICS_FILE}" 2>/dev/null || printf '_(failed to parse agent metrics)_\n'
    printf '\n'
    # Aggregate find rate across all reviewers — used by interpretation footer.
    _intp_reviewer_rate="$(jq -r '
      .agents // {} | to_entries
      | map({inv: (.value.invocations // 0), finds: (.value.finding_verdicts // 0)})
      | map(select(.inv > 0))
      | (map(.finds) | add // 0) as $f
      | (map(.inv) | add // 0) as $i
      | if $i > 0 then (($f * 100 / $i) | floor | tostring) else "" end
    ' "${AGENT_METRICS_FILE}" 2>/dev/null || printf '')"
  else
    printf '_No reviewer activity recorded yet._\n\n'
  fi
else
  printf '_No reviewer activity recorded yet._\n\n'
fi

# ----------------------------------------------------------------------
# Section 6: Defect categories
printf '## Defect category histogram\n\n'
if [[ -f "${DEFECT_PATTERNS_FILE}" ]]; then
  has_patterns="$(jq 'if type == "object" then ((.patterns // {}) | length) > 0 else false end' "${DEFECT_PATTERNS_FILE}" 2>/dev/null || echo false)"
  if [[ "${has_patterns}" == "true" ]]; then
    jq -r '
      .patterns // {} | to_entries
      | map(select(.value.count > 0))
      | sort_by(-.value.count)
      | .[0:10]
      | .[]
      | "- `\(.key)` × \(.value.count)"
    ' "${DEFECT_PATTERNS_FILE}" 2>/dev/null || printf '_(failed to parse defect patterns)_\n'
    printf '\n'
  else
    printf '_No defect patterns recorded yet._\n\n'
  fi
else
  printf '_No defect patterns recorded yet._\n\n'
fi

# ----------------------------------------------------------------------
# Section 6.5: Time spent across sessions
printf '## Time spent across sessions\n\n'

if ! is_time_tracking_enabled; then
  printf '_Time tracking is disabled (`time_tracking=off`)._\n\n'
else
  _xs_time_log="$(timing_xs_log_path)"
  if [[ ! -f "${_xs_time_log}" ]] || [[ ! -s "${_xs_time_log}" ]]; then
    printf '_No cross-session timing rows yet._\n\n'
  else
    _xs_rollup="$(timing_xs_aggregate "${cutoff_ts}")"
    _xs_sessions="$(jq -r '.sessions // 0' <<<"${_xs_rollup}" 2>/dev/null)"
    _xs_sessions="${_xs_sessions:-0}"

    if [[ "${_xs_sessions}" == "0" ]]; then
      printf '_No sessions in window._\n\n'
    else
      _xs_walltime="$(jq -r '.walltime_s // 0' <<<"${_xs_rollup}" 2>/dev/null)"
      _xs_agent="$(jq -r '.agent_total_s // 0' <<<"${_xs_rollup}" 2>/dev/null)"
      _xs_tool="$(jq -r '.tool_total_s // 0' <<<"${_xs_rollup}" 2>/dev/null)"
      _xs_idle="$(jq -r '.idle_model_s // 0' <<<"${_xs_rollup}" 2>/dev/null)"
      _xs_prompts="$(jq -r '.prompts // 0' <<<"${_xs_rollup}" 2>/dev/null)"

      printf '_Window: %s sessions · %s prompts · %s walltime._\n\n' \
        "${_xs_sessions}" "${_xs_prompts:-0}" "$(timing_fmt_secs "${_xs_walltime:-0}")"

      printf '| Bucket | Time | Share |\n'
      printf '|---|---|---|\n'
      _share() {
        local part="$1" total="$2"
        if [[ "${total}" =~ ^[0-9]+$ ]] && (( total > 0 )); then
          printf '%d%%' "$(( part * 100 / total ))"
        else
          printf '—'
        fi
      }
      printf '| agents | %s | %s |\n' "$(timing_fmt_secs "${_xs_agent:-0}")" "$(_share "${_xs_agent:-0}" "${_xs_walltime:-0}")"
      printf '| tools | %s | %s |\n' "$(timing_fmt_secs "${_xs_tool:-0}")" "$(_share "${_xs_tool:-0}" "${_xs_walltime:-0}")"
      printf '| idle/model | %s | %s |\n' "$(timing_fmt_secs "${_xs_idle:-0}")" "$(_share "${_xs_idle:-0}" "${_xs_walltime:-0}")"
      printf '\n'

      printf '**Top agents by time**\n\n'
      _xs_top_agents="$(jq -r '
        (.agent_breakdown // {})
        | to_entries | sort_by(-.value)
        | .[0:10]
        | .[]
        | "\(.value)\t\(.key)"
      ' <<<"${_xs_rollup}" 2>/dev/null || true)"
      if [[ -n "${_xs_top_agents}" ]]; then
        while IFS=$'\t' read -r _xs_secs _xs_name; do
          [[ -z "${_xs_name}" ]] && continue
          printf -- '- `%s` — %s\n' "${_xs_name}" "$(timing_fmt_secs "${_xs_secs}")"
        done <<<"${_xs_top_agents}"
      else
        printf '_None recorded._\n'
      fi
      printf '\n'

      printf '**Top tools by time**\n\n'
      _xs_top_tools="$(jq -r '
        (.tool_breakdown // {})
        | to_entries | sort_by(-.value)
        | .[0:10]
        | .[]
        | "\(.value)\t\(.key)"
      ' <<<"${_xs_rollup}" 2>/dev/null || true)"
      if [[ -n "${_xs_top_tools}" ]]; then
        while IFS=$'\t' read -r _xs_secs _xs_name; do
          [[ -z "${_xs_name}" ]] && continue
          printf -- '- `%s` — %s\n' "${_xs_name}" "$(timing_fmt_secs "${_xs_secs}")"
        done <<<"${_xs_top_tools}"
      else
        printf '_None recorded._\n'
      fi
      printf '\n'

      if (( _xs_prompts > 0 )) && [[ "${_xs_walltime}" =~ ^[0-9]+$ ]] && (( _xs_walltime > 0 )); then
        printf '**Average prompt walltime:** %s\n\n' \
          "$(timing_fmt_secs $(( _xs_walltime / _xs_prompts )))"
      fi
    fi
  fi
fi

# ----------------------------------------------------------------------
# Section 7: Patterns to consider (v1.17.0 interpretation footer)
#
# The previous /ulw-report contract was strictly "facts only" — the
# user got rows of numbers and was expected to draw conclusions. This
# block does the simple correlations the model is best positioned to
# do, surfacing 2-3 actionable patterns without claiming insight the
# data doesn't support. Heuristics are intentionally conservative
# (clear thresholds, no ML); when nothing trips a threshold, the
# section emits a single "no patterns to call out" line instead of
# noisy commentary.
printf '## Patterns to consider\n\n'

_intp_lines=()

# Heuristic 1: gate-block density. >2 blocks/session is noisy.
if [[ "${_intp_session_count:-0}" -gt 0 && "${_intp_block_total:-0}" -gt 0 ]]; then
  # tenths-precision avg, rendered as "X.Y"; bash 3.2 cannot do negative
  # substring slicing so we compute the integer and tenths separately.
  _block_per_session=$(( _intp_block_total * 10 / _intp_session_count ))
  if [[ "${_block_per_session}" -ge 21 ]]; then
    _bps_int=$(( _block_per_session / 10 ))
    _bps_dec=$(( _block_per_session % 10 ))
    _intp_lines+=("**High gate-fire density.** ${_intp_block_total} blocks across ${_intp_session_count} sessions (~${_bps_int}.${_bps_dec}/session). If the work was correct, the gates may be over-firing — try \`/metis\` on the next big task to scope it more tightly, or \`/plan-hard\` so reviewers see structured scope.")
  fi
fi

# Heuristic 2: skip-to-block ratio. >40% means many gates fire on
# legitimate work — calibration signal.
if [[ "${_intp_block_total:-0}" -gt 0 && "${_intp_skip_total:-0}" -gt 0 ]]; then
  _skip_pct=$(( _intp_skip_total * 100 / _intp_block_total ))
  if [[ "${_skip_pct}" -ge 40 ]]; then
    _intp_lines+=("**High skip rate.** ${_intp_skip_total}/${_intp_block_total} blocks (${_skip_pct}%) ended in \`/ulw-skip\`. The gates are likely firing on legitimate work — review the most-skipped gate type in the table above and consider tightening its trigger conditions or surfacing a clearer recovery action.")
  fi
fi

# Heuristic 3: serendipity catches. Any > 0 is a positive signal worth
# surfacing — these are bugs the harness caught that would otherwise
# have shipped silently.
if [[ "${_intp_serendipity_total:-0}" -gt 0 ]]; then
  _intp_lines+=("**Serendipity caught ${_intp_serendipity_total} adjacent defect$([[ "${_intp_serendipity_total}" -eq 1 ]] && echo "" || echo "s") in window.** These are bugs found while working on something else and fixed in-session per the Serendipity Rule. Sustained > 0 means the rule is paying for itself — keep applying it on verified, same-path, bounded fixes.")
fi

# Heuristic 4: classifier misfire trend. >5/week or >20/month flags
# that the classifier is mis-routing prompts often enough to investigate.
if [[ "${_intp_misfires:-0}" -ge 5 && "${MODE}" == "week" ]] || \
   [[ "${_intp_misfires:-0}" -ge 20 && "${MODE}" == "month" ]] || \
   [[ "${_intp_misfires:-0}" -ge 5 && "${MODE}" == "all" ]]; then
  _intp_lines+=("**Classifier misfires accumulating.** ${_intp_misfires} misfire row$([[ "${_intp_misfires}" -eq 1 ]] && echo "" || echo "s") in window. Run \`tools/replay-classifier-telemetry.sh\` against \`tools/classifier-fixtures/regression.jsonl\` to see whether the prompts your classifier is mis-routing share a structural pattern worth adding to \`lib/classifier.sh\`.")
fi

# Heuristic 5: archetype convergence. Same archetype emitted ≥3 times
# AND total unique archetypes < 4 means the harness is converging on a
# narrow set — anti-anchoring discipline weakening.
if [[ "${_intp_arche_top_count:-0}" -ge 3 && "${_intp_arche_unique:-0}" -lt 4 ]]; then
  _intp_lines+=("**Archetype convergence.** \`${_intp_arche_top_name}\` emitted ${_intp_arche_top_count} times across only ${_intp_arche_unique} unique archetype$([[ "${_intp_arche_unique}" -eq 1 ]] && echo "" || echo "s") — the cross-session anti-anchoring advisory may not be sticking. Next UI prompt, name a specific *different* archetype family in the prompt to break the pattern.")
fi

# Heuristic 6: reviewer find-rate sanity. <10% across the whole window
# may indicate reviewers are running but not surfacing real findings;
# >70% may indicate over-pedantic review prompts.
if [[ -n "${_intp_reviewer_rate:-}" ]]; then
  if [[ "${_intp_reviewer_rate}" -ge 70 ]]; then
    _intp_lines+=("**Reviewers finding ${_intp_reviewer_rate}% of the time.** That is high — consider whether reviewer prompts are flagging style/preference issues alongside correctness. Tightening reviewer scope keeps signal-to-noise high.")
  elif [[ "${_intp_reviewer_rate}" -lt 10 && "${_intp_reviewed:-0}" -ge 5 ]]; then
    _intp_lines+=("**Reviewer find-rate low (${_intp_reviewer_rate}%).** Across ${_intp_reviewed} reviewed sessions, reviewers rarely surface findings. If your work is genuinely clean, no action needed — but if you suspect bugs are slipping past, narrow reviewer prompts to specific risk areas (security, concurrency, regressions).")
  fi
fi

if [[ "${#_intp_lines[@]}" -eq 0 ]]; then
  printf '_No clear patterns to call out in this window. Default heuristics fire on high gate-fire density, skip rate, archetype convergence, and reviewer find-rate; none triggered. Ship with confidence._\n\n'
else
  for _line in "${_intp_lines[@]}"; do
    printf -- '- %s\n\n' "${_line}"
  done
fi

# ----------------------------------------------------------------------
# Footer
printf '%s\n' '---'
printf '_Re-run with `last`, `week`, `month`, or `all` to widen/narrow the window. `/ulw-status` shows the in-flight session._\n'
