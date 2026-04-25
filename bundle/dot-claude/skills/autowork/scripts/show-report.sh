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
fi

# ----------------------------------------------------------------------
# Section 4b: Gate event outcomes (per-event attribution, v1.14.0)
printf '## Gate event outcomes\n\n'
gate_event_rows="$(filter_by_window "${GATE_EVENTS_FILE}" '.ts')"
if [[ -z "${gate_event_rows}" ]]; then
  printf '_No gate events recorded in window. Per-event telemetry is new in v1.14.0; populates as sessions sweep._\n\n'
else
  printf 'Per-event outcome attribution — every gate fire and finding-status change in the window.\n\n'
  printf '| Gate | Blocks | Status changes |\n'
  printf '|---|---:|---:|\n'
  # Note: prior revision had a "Releases" column, but no caller emits a
  # `release` event today (forward-compat scaffolding). Dropped to keep
  # the rendered table honest until a release-event emitter lands.
  # Counts use `wc -l` over jq output — `grep -c . || echo 0` produced a
  # literal "0\n0" string when grep matched nothing AND emitted 0,
  # which broke the markdown table for every realistic dataset.
  printf '%s\n' "${gate_event_rows}" \
    | jq -r '.gate' \
    | sort -u \
    | while IFS= read -r _gate; do
        [[ -z "${_gate}" ]] && continue
        _block_count="$(printf '%s\n' "${gate_event_rows}" | jq -c --arg g "${_gate}" 'select(.gate == $g and .event == "block")' | wc -l | tr -d '[:space:]')"
        _status_count="$(printf '%s\n' "${gate_event_rows}" | jq -c --arg g "${_gate}" 'select(.gate == $g and (.event == "finding-status-change" or .event == "wave-status-change"))' | wc -l | tr -d '[:space:]')"
        printf '| `%s` | %s | %s |\n' "${_gate}" "${_block_count}" "${_status_count}"
      done
  printf '\n'
  total_blocks_pe="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "block")' | wc -l | tr -d '[:space:]')"
  total_status_changes="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "finding-status-change" or .event == "wave-status-change")' | wc -l | tr -d '[:space:]')"
  shipped_changes="$(printf '%s\n' "${gate_event_rows}" | jq -c 'select(.event == "finding-status-change" and .details.finding_status == "shipped")' | wc -l | tr -d '[:space:]')"
  printf '_Total: %s gate blocks, %s status changes (%s findings shipped)._\n\n' \
    "${total_blocks_pe}" "${total_status_changes}" "${shipped_changes}"
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
# Footer
printf '%s\n' '---'
printf '_Re-run with `last`, `week`, `month`, or `all` to widen/narrow the window. `/ulw-status` shows the in-flight session._\n'
