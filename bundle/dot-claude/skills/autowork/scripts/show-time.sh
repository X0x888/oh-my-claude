#!/usr/bin/env bash
#
# show-time.sh — render the time-distribution breakdown that backs the
# `/ulw-time` skill. Diagnostic surface, not a hook — discovers the
# active or latest session itself.
#
# Modes:
#   (none)|current   Active session (best guess via discover_latest_session).
#   last             Most recent finalized session — same data source as
#                    `current` here, since per-session timing.jsonl is the
#                    only per-session record. Distinct mostly for clarity.
#   last-prompt      Slice the most recently finalized prompt out of the
#                    active session. Answers "where did THAT prompt go?"
#                    without aggregating prior prompts.
#   week (default for cross-session rollups)
#   month
#   all              Cross-session rollup pulled from
#                    ~/.claude/quality-pack/timing.jsonl.
#
# Exit codes: 0 always (empty-state messages instead of failure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

MODE="${1:-current}"
# v1.36.x W5 F-022: accept both positional (`current|last|week|...`) AND
# double-dash flag (`--current|--last|--week|...`) forms. Pre-fix
# /ulw-time only accepted positional, while /ulw-status accepted both —
# users typing `/ulw-time --week` got "unknown mode --week" with no
# recovery path. Both grammars now map to the same modes.
case "${MODE}" in
  --current)     MODE="current" ;;
  --last)        MODE="last" ;;
  --last-prompt) MODE="last-prompt" ;;
  --week)        MODE="week" ;;
  --month)       MODE="month" ;;
  --all)         MODE="all" ;;
esac

case "${MODE}" in
  -h|--help)
    cat <<'USAGE'
Usage: show-time.sh [current|last|last-prompt|week|month|all]
       show-time.sh [--current|--last|--last-prompt|--week|--month|--all]

  current      Active session (default).
  last         Most recent finalized session.
  last-prompt  Most recently finalized prompt within the active session.
  week         Cross-session rollup, last 7 days.
  month        Cross-session rollup, last 30 days.
  all          Cross-session rollup, every recorded row.

Both positional and --double-dash flag forms are accepted (matches
/ulw-status grammar). Backs the `/ulw-time` skill. Reads
<session>/timing.jsonl for per-session modes and
~/.claude/quality-pack/timing.jsonl for cross-session rollups.
USAGE
    exit 0
    ;;
esac

case "${MODE}" in
  current|last|last-prompt|week|month|all) ;;
  *)
    printf 'show-time: unknown mode %q (expected: current|last|last-prompt|week|month|all, or --double-dash equivalent)\n' "${MODE}" >&2
    exit 2
    ;;
esac

if ! is_time_tracking_enabled; then
  printf 'Time tracking is disabled (time_tracking=off). Enable in\n'
  printf '%s/.claude/oh-my-claude.conf or via /omc-config.\n' "${HOME}"
  exit 0
fi

case "${MODE}" in
  current|last|last-prompt)
    latest="$(discover_latest_session)"
    if [[ -z "${latest}" ]]; then
      printf 'No active or recent ULW session found.\n'
      exit 0
    fi

    log="${STATE_ROOT}/${latest}/timing.jsonl"
    if [[ ! -f "${log}" ]]; then
      printf 'No timing data captured yet for session %s.\n' "${latest}"
      printf 'Run a few tool calls and try again.\n'
      exit 0
    fi

    SESSION_ID="${latest}"

    if [[ "${MODE}" == "last-prompt" ]]; then
      seq="$(timing_latest_finalized_prompt_seq "${log}")"
      if [[ "${seq}" == "0" ]]; then
        printf 'No finalized prompts yet in session %s.\n' "${latest}"
        printf 'A prompt finalizes when the Stop hook fires; until then\n'
        printf 'the per-prompt breakdown is not available.\n'
        exit 0
      fi
      agg="$(timing_aggregate "${log}" "${seq}")"
      title="Time breakdown — last prompt (#${seq})"
    else
      agg="$(timing_aggregate "${log}")"
    fi

    walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
    walltime="${walltime:-0}"
    if [[ "${walltime}" == "0" ]]; then
      printf 'No finalized prompts yet in session %s.\n' "${latest}"
      printf 'The first prompt boundary is recorded once the session\n'
      printf 'releases (Stop hook). Active prompts surface after Stop.\n'
      exit 0
    fi

    case "${MODE}" in
      current)     title="Time breakdown — current session" ;;
      last)        title="Time breakdown — last session"    ;;
      last-prompt) : ;;  # title set above
    esac
    timing_format_full "${agg}" "${title}"
    exit 0
    ;;

  week|month|all)
    now="$(date +%s)"
    case "${MODE}" in
      week)  cutoff=$(( now - 7 * 86400 )); window_label="last 7 days" ;;
      month) cutoff=$(( now - 30 * 86400 )); window_label="last 30 days" ;;
      all)   cutoff=0; window_label="all time" ;;
    esac

    log="$(timing_xs_log_path)"
    if [[ ! -f "${log}" ]] || [[ ! -s "${log}" ]]; then
      printf 'No cross-session timing data yet (%s).\n' "${window_label}"
      printf 'Each finalized session adds a row at Stop time.\n'
      exit 0
    fi

    rollup="$(timing_xs_aggregate "${cutoff}")"

    sessions="$(jq -r '.sessions // 0' <<<"${rollup}" 2>/dev/null)"
    sessions="${sessions:-0}"
    if [[ "${sessions}" == "0" ]]; then
      printf 'No sessions in window: %s.\n' "${window_label}"
      exit 0
    fi

    walltime="$(jq -r '.walltime_s // 0' <<<"${rollup}" 2>/dev/null)"
    agent_total="$(jq -r '.agent_total_s // 0' <<<"${rollup}" 2>/dev/null)"
    tool_total="$(jq -r '.tool_total_s // 0' <<<"${rollup}" 2>/dev/null)"
    idle_total="$(jq -r '.idle_model_s // 0' <<<"${rollup}" 2>/dev/null)"
    overhead_total="$(jq -r '.concurrent_overhead_s // 0' <<<"${rollup}" 2>/dev/null)"
    prompts="$(jq -r '.prompts // 0' <<<"${rollup}" 2>/dev/null)"

    sessions_label="sessions"
    prompts_label="prompts"
    (( ${sessions:-0} == 1 )) && sessions_label="session"
    (( ${prompts:-0} == 1 )) && prompts_label="prompt"
    printf '─── Time spent across sessions ─── %s · %s · %s %s · %s %s\n' \
      "${window_label}" \
      "$(timing_fmt_secs "${walltime:-0}")" \
      "${sessions:-0}" "${sessions_label}" \
      "${prompts:-0}" "${prompts_label}"

    if (( walltime > 0 )); then
      # v1.34.1+ (D-002 / X-002): when work fits inside walltime (idle >= 0),
      # render percentages against walltime — agents+tools+idle = 100. When
      # parallel agents/tools overran walltime (concurrent_overhead_s > 0),
      # the three buckets cannot partition walltime, so re-normalize against
      # work-time (agent + tool + idle) and disclose the overlap explicitly.
      # Buckets-overlap-walltime = 100% always; the disclosure tells the
      # user how much serial time the parallelism saved.
      overhead_total="${overhead_total:-0}"
      [[ "${overhead_total}" =~ ^[0-9]+$ ]] || overhead_total=0
      if (( overhead_total > 0 )); then
        denom=$(( agent_total + tool_total + idle_total ))
        (( denom == 0 )) && denom=1
        pct_a=$(( agent_total * 100 / denom ))
        pct_t=$(( tool_total * 100 / denom ))
        pct_i=$(( idle_total * 100 / denom ))
      else
        pct_a=$(( agent_total * 100 / walltime ))
        pct_t=$(( tool_total * 100 / walltime ))
        pct_i=$(( idle_total * 100 / walltime ))
      fi
      stacked_bar="$(_timing_stacked_bar "${pct_a}" "${pct_t}" "${pct_i}" 30)"
      printf '  %s  agents %d%% · tools %d%% · idle %d%%\n' \
        "${stacked_bar}" "${pct_a}" "${pct_t}" "${pct_i}"
      if (( overhead_total > 0 )); then
        printf '  parallelism saved ~%s of serial work-time\n' \
          "$(timing_fmt_secs "${overhead_total}")"
      fi
      printf '\n'
      printf '  agents       %s (%d%%)\n'     "$(timing_fmt_secs "${agent_total}")" "${pct_a}"
      printf '  tools        %s (%d%%)\n'     "$(timing_fmt_secs "${tool_total}")"  "${pct_t}"
      printf '  idle/model   %s (%d%%)\n'     "$(timing_fmt_secs "${idle_total}")"  "${pct_i}"
    fi

    # Skip the entire "Top agents" section when the breakdown is empty
    # (idle-only window). Same for "Top tools". An empty heading followed
    # by zero rows is worse UX than no heading at all.
    agent_rows="$(jq -r '
      (.agent_breakdown // {})
      | to_entries
      | sort_by(-.value)
      | .[0:10]
      | .[]
      | "\(.value)\t\(.key)"
    ' <<<"${rollup}" 2>/dev/null)"
    if [[ -n "${agent_rows}" ]]; then
      printf '\n  Top agents by time:\n'
      while IFS=$'\t' read -r secs name; do
        [[ -z "${name}" ]] && continue
        printf '    %-30s %s\n' "${name}" "$(timing_fmt_secs "${secs}")"
      done <<<"${agent_rows}"
    fi

    tool_rows="$(jq -r '
      (.tool_breakdown // {})
      | to_entries
      | sort_by(-.value)
      | .[0:10]
      | .[]
      | "\(.value)\t\(.key)"
    ' <<<"${rollup}" 2>/dev/null)"
    if [[ -n "${tool_rows}" ]]; then
      printf '\n  Top tools by time:\n'
      while IFS=$'\t' read -r secs name; do
        [[ -z "${name}" ]] && continue
        printf '    %-30s %s\n' "${name}" "$(timing_fmt_secs "${secs}")"
      done <<<"${tool_rows}"
    fi

    if (( sessions > 0 )); then
      printf '\n  Average prompt walltime: %s\n' \
        "$(timing_fmt_secs $(( prompts > 0 ? walltime / prompts : 0 )))"
    fi

    insight="$(timing_generate_insight "${rollup}" "window")"
    if [[ -n "${insight}" ]]; then
      printf '\n  %s\n' "${insight}"
    fi

    exit 0
    ;;
esac
