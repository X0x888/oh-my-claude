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

# v1.31.0 Wave 8 (growth-lens F-037): --share flag emits a privacy-safe
# numbers-only digest suitable for posting to Slack / PRs / Twitter.
# NEVER includes prompt text, gate reason free-text, or any free-form
# string field. Distribution counts and aggregate totals only.
SHARE_MODE=0
FIELD_SHAPE_AUDIT=0
# v1.36.0 (item #8): --sweep aggregates currently-active session dirs
# (under ${STATE_ROOT}) into the in-memory view used by this report,
# without writing to the cross-session ledger or claiming the source
# dirs. Closes the gap where /ulw-report run during an active session
# missed that session's gate events because session_summary.jsonl /
# gate_events.jsonl only populate at the daily TTL sweep.
SWEEP_MODE=0
NEW_ARGS=()
for _arg in "$@"; do
  case "${_arg}" in
    --share)              SHARE_MODE=1 ;;
    --field-shape-audit)  FIELD_SHAPE_AUDIT=1 ;;
    --sweep)              SWEEP_MODE=1 ;;
    *)                    NEW_ARGS+=("${_arg}") ;;
  esac
done
set -- "${NEW_ARGS[@]+${NEW_ARGS[@]}}"

MODE="${1:-week}"
# v1.36.x W5 F-022: accept both positional (`last|week|month|all`) AND
# double-dash flag (`--last|--week|--month|--all`) forms. Pre-fix
# /ulw-report only accepted positional, while /ulw-status accepted
# both — users typing `/ulw-report --week` got "unknown mode".
case "${MODE}" in
  --last)  MODE="last" ;;
  --week)  MODE="week" ;;
  --month) MODE="month" ;;
  --all)   MODE="all" ;;
esac

case "${MODE}" in
  last|week|month|all) ;;
  --help|-h)
    cat <<'USAGE'
Usage: show-report.sh [last|week|month|all] [--share] [--sweep] [--field-shape-audit]

  last     Most recent session only.
  week     Sessions in the last 7 days (default).
  month    Sessions in the last 30 days.
  all      Every available row across cross-session aggregates.
  --share  Emit a privacy-safe numbers-only digest suitable for
           posting to Slack / PRs / Twitter. NEVER includes prompt
           text, free-text reasons, or any free-form fields. Only
           counts and distributions. Combine with last|week|month|all
           to scope the window. (v1.31.0)
  --sweep  Fold currently-active session dirs (under
           ~/.claude/quality-pack/state/) into the in-memory view.
           Read-only — never writes to the cross-session ledger
           and never claims (deletes) the source dirs. Closes the
           gap where /ulw-report run during an active session
           missed that session's gate events because
           session_summary.jsonl / gate_events.jsonl only populate
           at the daily TTL sweep. Synthesizes per-session rows
           using the same jq formula as sweep_stale_sessions and
           tags them `_live: true`. Combine with last|week|month|all
           to scope the window. Banner prefaces the report so the
           user knows the cross-session aggregate was extended on
           the fly. (v1.36.0)
  --field-shape-audit
           Run a field-shape sanity audit over
           ~/.claude/quality-pack/gate_events.jsonl. Per-gate-shape
           expectations (path-shaped vs numeric vs token-shaped) are
           checked against actual values; any rows whose detail
           fields fail their declared shape are surfaced with the
           offending gate, event, field, expected shape, and
           offending excerpt. Catches the Bug B-class leak shape
           where a positional misalignment lands prompt-text
           fragments into typed detail fields. Bypasses the verbose
           report body. Combine with last|week|month|all to scope
           the audit window.

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
_xs_rollup_cache=""

# v1.36.0 (item #8): --sweep rollup. For each active session dir under
# STATE_ROOT (excluding _watchdog), synthesize a session_summary row
# AND fold its per-session gate_events.jsonl into the report's view —
# without writing to the cross-session ledger and without claiming
# (deleting) the source dirs. The render below uses the SUMMARY_FILE
# and GATE_EVENTS_FILE variables; we redirect them to merged temp
# files. Cleanup happens on EXIT trap below.
_omc_sweep_active_count=0
_OMC_SWEEP_TMPDIR=""
if [[ "${SWEEP_MODE}" -eq 1 ]]; then
  _OMC_SWEEP_TMPDIR="$(mktemp -d 2>/dev/null || true)"
  if [[ -n "${_OMC_SWEEP_TMPDIR}" ]] && [[ -d "${_OMC_SWEEP_TMPDIR}" ]]; then
    # Mirror SUMMARY_FILE + GATE_EVENTS_FILE if they exist.
    _sweep_merged_summary="${_OMC_SWEEP_TMPDIR}/session_summary.jsonl"
    _sweep_merged_gate="${_OMC_SWEEP_TMPDIR}/gate_events.jsonl"
    [[ -f "${SUMMARY_FILE}" ]] && cp "${SUMMARY_FILE}" "${_sweep_merged_summary}" || true
    [[ -f "${GATE_EVENTS_FILE}" ]] && cp "${GATE_EVENTS_FILE}" "${_sweep_merged_gate}" || true
    # Ensure the files exist (empty is fine) so >>append works downstream.
    : > "${_sweep_merged_summary}.lock" 2>/dev/null || true
    [[ ! -f "${_sweep_merged_summary}" ]] && : > "${_sweep_merged_summary}"
    [[ ! -f "${_sweep_merged_gate}" ]] && : > "${_sweep_merged_gate}"

    # Walk active session dirs. STATE_ROOT comes from common.sh; if
    # unset (degenerate environment), default to ~/.claude/quality-pack/state.
    _sweep_state_root="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
    if [[ -d "${_sweep_state_root}" ]]; then
      while IFS= read -r _sweep_dir; do
        [[ -z "${_sweep_dir}" ]] && continue
        # Exclude _watchdog (synthetic daemon session — its rows
        # don't belong in the human-facing report).
        local_basename="$(basename "${_sweep_dir}")"
        [[ "${local_basename}" == "_watchdog" ]] && continue
        local_state="${_sweep_dir}/session_state.json"
        [[ -f "${local_state}" ]] || continue

        # session_summary row — same jq formula as sweep_stale_sessions
        # (common.sh:1278). Kept inline rather than extracting a helper
        # because the show-report.sh use is the only second consumer.
        local_edits_log="${_sweep_dir}/edited_files.log"
        local_ec=0
        [[ -f "${local_edits_log}" ]] && local_ec="$(sort -u "${local_edits_log}" | wc -l | tr -d '[:space:]')"

        local_findings_file="${_sweep_dir}/findings.json"
        local_findings_block='null'
        local_waves_block='null'
        if [[ -f "${local_findings_file}" ]]; then
          local_findings_block="$(jq -c '
            (.findings // []) | {
              total: length,
              shipped:     ([.[] | select(.status=="shipped")]     | length),
              deferred:    ([.[] | select(.status=="deferred")]    | length),
              rejected:    ([.[] | select(.status=="rejected")]    | length),
              in_progress: ([.[] | select(.status=="in_progress")] | length),
              pending:     ([.[] | select(.status=="pending")]     | length)
            }
          ' "${local_findings_file}" 2>/dev/null || echo 'null')"
          local_waves_block="$(jq -c '
            (.waves // []) | { total: length, completed: ([.[] | select(.status=="completed")] | length) }
          ' "${local_findings_file}" 2>/dev/null || echo 'null')"
        fi

        jq -c --arg sid "${local_basename}" --argjson ec "${local_ec:-0}" \
          --argjson findings "${local_findings_block}" \
          --argjson waves "${local_waves_block}" '
          {
            session_id: $sid,
            project_key: (.project_key // null),
            start_ts: (.session_start_ts // .last_user_prompt_ts // null),
            end_ts: (.last_edit_ts // .last_review_ts // null),
            domain: (.task_domain // "unknown"),
            intent: (.task_intent // "unknown"),
            edit_count: $ec,
            code_edits: ((.code_edit_count // "0") | tonumber),
            doc_edits: ((.doc_edit_count // "0") | tonumber),
            verified: (if .last_verify_ts then true else false end),
            verify_outcome: (.last_verify_outcome // null),
            verify_confidence: ((.last_verify_confidence // "0") | tonumber),
            reviewed: (if .last_review_ts then true else false end),
            guard_blocks: ((.stop_guard_blocks // "0") | tonumber),
            dim_blocks: ((.dimension_guard_blocks // "0") | tonumber),
            exhausted: (if .guard_exhausted then true else false end),
            dispatches: ((.subagent_dispatch_count // "0") | tonumber),
            outcome: (.session_outcome // "active"),
            skip_count: ((.skip_count // "0") | tonumber),
            serendipity_count: ((.serendipity_count // "0") | tonumber),
            findings: $findings,
            waves: $waves,
            _live: true
          }
        ' "${local_state}" >> "${_sweep_merged_summary}" 2>/dev/null || true

        # Per-session gate_events.jsonl — append each row with
        # session_id and project_key tags so the cross-session
        # query shape works unchanged.
        local_gate_file="${_sweep_dir}/gate_events.jsonl"
        if [[ -f "${local_gate_file}" ]] && [[ -s "${local_gate_file}" ]]; then
          local_pkey="$(jq -r '.project_key // ""' "${local_state}" 2>/dev/null || echo "")"
          jq -c --arg sid "${local_basename}" --arg pkey "${local_pkey}" \
            '. + {session_id: $sid, project_key: ($pkey // null), _live: true}' \
            "${local_gate_file}" >> "${_sweep_merged_gate}" 2>/dev/null || true
        fi

        _omc_sweep_active_count=$(( _omc_sweep_active_count + 1 ))
      done < <(find "${_sweep_state_root}" -maxdepth 1 -type d \
                  ! -name '.' ! -name '..' ! -path "${_sweep_state_root}" 2>/dev/null)
    fi

    # Repoint the report's data sources at the merged temps.
    SUMMARY_FILE="${_sweep_merged_summary}"
    GATE_EVENTS_FILE="${_sweep_merged_gate}"
  fi

  # Cleanup on EXIT — never delete the on-disk ledger files since we
  # only ever wrote to the temp copy. Function-form trap (vs embedded
  # variable expansion) avoids the SC2064 quote-injection class — the
  # path is read from a captured variable at trap-fire time, not
  # interpolated into a single-quoted shell argument at trap-set time.
  _omc_sweep_cleanup() {
    if [[ -n "${_OMC_SWEEP_TMPDIR:-}" ]] && [[ -d "${_OMC_SWEEP_TMPDIR}" ]]; then
      rm -rf "${_OMC_SWEEP_TMPDIR:?}" 2>/dev/null || true
    fi
  }
  trap _omc_sweep_cleanup EXIT

  # Banner emits to STDOUT (not stderr) so it travels with the report
  # in pipe / tee / file-redirect flows. F-1 fix: pre-fix the banner
  # went to >&2, which lost it for users running
  # `/ulw-report --sweep | tee report.md`.
  printf '_[--sweep] Including %d active session(s) in this view (read-only; ledger not modified)._\n\n' \
    "${_omc_sweep_active_count}"
fi

# v1.31.0 Wave 8 (growth-lens F-037): --share renders a fully-sanitized
# digest. Numbers, distributions, and structural counts only — no
# prompt text, no reason free-text, no claim/finding strings, no
# session IDs. The only identifying surface is the project directory
# basename (which the user controls; if they share publicly they
# either edit the basename out or accept it). Bypasses the verbose
# diagnostic body and emits a fixed-shape markdown card the user
# can paste verbatim.
if [[ "${SHARE_MODE}" -eq 1 ]]; then
  # v1.31.2 quality-reviewer F-1 + F-2: handle MODE=last correctly
  # under --share. Pre-1.31.2 left cutoff_ts=0 for last mode, which
  # the share queries treated as "all rows after epoch 0" = entire
  # history under a "most recent session" header — the share digest
  # was lying. Materialize the rows the share queries should
  # consider into a temp jsonl and re-point the cutoff: under
  # MODE=last, that's the most recent session_summary row only.
  _share_sessions_src="${SUMMARY_FILE}"
  if [[ "${MODE}" == "last" ]] && [[ -f "${SUMMARY_FILE}" ]] && [[ -s "${SUMMARY_FILE}" ]]; then
    _share_sessions_src="$(mktemp)"
    tail -n 1 "${SUMMARY_FILE}" > "${_share_sessions_src}" 2>/dev/null || true
    # Compute the gate_events cutoff from the last-session start_ts
    # so gate-event distribution is also scoped correctly.
    cutoff_ts="$(jq -r '.start_ts // 0 | tonumber? // 0' "${_share_sessions_src}" 2>/dev/null || echo 0)"
  fi

  # v1.34.1+ (growth-lens G-002): make --share a real shareable card.
  # Pre-fix the output read as a debug dump (counts in raw bullets, no
  # narrative, contradictory numbers when sessions=0 but gate-events
  # ledger has rows). The new shape leads with a one-line headline,
  # adds a time-saved estimate, and ends with a copy-paste-to-Twitter
  # line. Suppresses bullets entirely when sessions=0 (no signal).
  _share_sessions=0
  _share_blocks=0
  _share_dispatches=0
  _share_serendipity=0
  if [[ -f "${_share_sessions_src}" ]] && [[ -s "${_share_sessions_src}" ]]; then
    _share_sessions="$(jq -s --argjson cutoff "${cutoff_ts}" \
      'map(select((.start_ts // 0 | tonumber? // 0) >= $cutoff)) | length' \
      "${_share_sessions_src}" 2>/dev/null || echo 0)"
    # v1.31.2 quality-reviewer F-1: count BOTH guard_blocks AND
    # dim_blocks. Dimension-tick blocks (SubagentStop reviewer chain)
    # are real "caught issues" and the verbose mode (line 189) sums
    # both. The publicly-shareable headline number must agree.
    _share_blocks="$(jq -s --argjson cutoff "${cutoff_ts}" \
      'map(select((.start_ts // 0 | tonumber? // 0) >= $cutoff) | (.guard_blocks // 0) + (.dim_blocks // 0)) | add // 0' \
      "${_share_sessions_src}" 2>/dev/null || echo 0)"
    _share_dispatches="$(jq -s --argjson cutoff "${cutoff_ts}" \
      'map(select((.start_ts // 0 | tonumber? // 0) >= $cutoff) | .dispatches // 0) | add // 0' \
      "${_share_sessions_src}" 2>/dev/null || echo 0)"
  fi
  if [[ -f "${SERENDIPITY_FILE}" ]] && [[ -s "${SERENDIPITY_FILE}" ]]; then
    _share_serendipity="$(jq -s --argjson cutoff "${cutoff_ts}" \
      'map(select(((.ts // 0) | tonumber? // 0) >= $cutoff)) | length' \
      "${SERENDIPITY_FILE}" 2>/dev/null || echo 0)"
  fi

  # Time-saved heuristic (v1.36.x W2 F-009 — weighted by gate type).
  #
  # Pre-fix: every block weighted at 8 min, every serendipity at 5 min,
  # ignoring the gate type and not subtracting false-positive skips.
  # The fixed formula was honest about being a heuristic but conflated
  # high-stakes blocks (delivery-contract publish requirements; missed
  # tests) with low-stakes ones (advisory misroute prevention).
  #
  # New shape: weight gate-block events by category and subtract a
  # cost per /ulw-skip (false positives where the user said the gate
  # was wrong). The weights are still heuristic, but now they reflect
  # the actual cost-of-a-defect class.
  #
  # Gate weights (seconds saved per block):
  #   - delivery-contract / dim_block: 600s (10 min) — heaviest defects,
  #     e.g. publish requirements / missing tests / failed excellence.
  #   - discovered-scope / wave-shape / shortcut-ratio: 360s (6 min)
  #     — coverage / segmentation defenses.
  #   - advisory / session-handoff / pretool: 240s (4 min)
  #     — early-redirect defenses; saved a misroute cycle.
  #   - everything else: 300s (5 min) — middle of the road.
  # Serendipity stays at 300s (5 min) — bugs caught while doing other
  # work, fixed in-session per the Serendipity Rule.
  # SUBTRACTED: each /ulw-skip is 60s (1 min) — the false-positive
  # cost the user paid because the gate fired on legitimate work.
  _share_blocks_weighted_secs=0
  if [[ -f "${GATE_EVENTS_FILE}" ]] && [[ -s "${GATE_EVENTS_FILE}" ]]; then
    _share_blocks_weighted_secs="$(jq -s --argjson cutoff "${cutoff_ts}" '
        map(select((.ts // 0) >= $cutoff and .event == "block"))
        | map(
            .gate as $g
            | (
                if ($g == "delivery-contract" or $g == "dim_block") then 600
                elif ($g == "discovered-scope" or $g == "wave-shape" or $g == "shortcut-ratio") then 360
                elif ($g == "advisory" or $g == "session-handoff" or $g == "pretool") then 240
                else 300
                end
              )
          )
        | add // 0
      ' "${GATE_EVENTS_FILE}" 2>/dev/null || echo 0)"
    [[ "${_share_blocks_weighted_secs}" =~ ^[0-9]+$ ]] || _share_blocks_weighted_secs=0
  fi
  # If we have no per-event signal (e.g. early sessions before
  # gate_events.jsonl was populated), fall back to the legacy
  # 480s/block heuristic so the share card still has a defensible
  # number — better than $0 and the upgrade path is gracious.
  if [[ "${_share_blocks_weighted_secs}" -eq 0 ]] && [[ "${_share_blocks:-0}" -gt 0 ]]; then
    _share_blocks_weighted_secs=$(( _share_blocks * 480 ))
  fi

  # Read total skips from session_summary rows in window — each is
  # 60s of false-positive cost subtracted from the gross savings.
  _share_skip_count=0
  if [[ -f "${_share_sessions_src}" ]] && [[ -s "${_share_sessions_src}" ]]; then
    _share_skip_count="$(jq -s --argjson cutoff "${cutoff_ts}" \
      'map(select((.start_ts // 0 | tonumber? // 0) >= $cutoff) | .skip_count // 0) | add // 0' \
      "${_share_sessions_src}" 2>/dev/null || echo 0)"
    [[ "${_share_skip_count}" =~ ^[0-9]+$ ]] || _share_skip_count=0
  fi
  _share_skip_cost_secs=$(( _share_skip_count * 60 ))

  _share_caught_total=$(( _share_blocks + _share_serendipity ))
  _share_saved_secs=$(( _share_blocks_weighted_secs + _share_serendipity * 300 - _share_skip_cost_secs ))
  # Floor at 0 — a session dominated by false-positive skips can produce
  # a negative net (e.g. 1 cheap block × 240s minus 5 skips × 60s = -60s).
  # Claiming "saved -1m of debugging" reads as broken/dishonest in a
  # public share card; floor at 0 instead. The asymmetry is intentional:
  # over-firing gates DO cost the user real time, but the share-card
  # surface is for headline value, not full cost accounting. The full
  # signal (skip count, false-positive rate, gate-block density) is
  # surfaced uncensored in the non-share `/ulw-report` view at top of
  # report.
  if [[ "${_share_saved_secs}" -lt 0 ]]; then
    _share_saved_secs=0
  fi
  _share_saved_human="$(timing_fmt_secs "${_share_saved_secs}" 2>/dev/null || printf '%ds' "${_share_saved_secs}")"

  printf '## oh-my-claude — %s\n\n' "${window_label}"

  # Headline line — the share-friendly one-liner. Only emit when there
  # is something to brag about. Pre-fix the card showed "Sessions: 0"
  # next to "Top gates: 280 events" which read as broken.
  if [[ "${_share_sessions}" -gt 0 ]]; then
    printf '**Caught %s issue%s across %s session%s.** Estimated time saved: ~%s of debugging.\n\n' \
      "${_share_caught_total}" \
      "$( [[ "${_share_caught_total}" == "1" ]] && printf '' || printf 's' )" \
      "${_share_sessions}" \
      "$( [[ "${_share_sessions}" == "1" ]] && printf '' || printf 's' )" \
      "${_share_saved_human}"
  else
    printf '_No sessions in window — nothing to share yet. Run /ulw <task> to start._\n\n'
  fi

  printf '_Privacy-safe digest. Numbers and distributions only._\n\n'

  # Detail bullets — only when there's actual session activity.
  if [[ "${_share_sessions}" -gt 0 ]]; then
    printf -- '- **Sessions:** %s\n' "${_share_sessions}"
    printf -- '- **Quality-gate blocks (caught issues):** %s\n' "${_share_blocks}"
    printf -- '- **Specialist dispatches:** %s\n' "${_share_dispatches}"
    if [[ "${_share_serendipity}" -gt 0 ]]; then
      printf -- '- **Serendipity Rule fires (adjacent defects caught):** %s\n' "${_share_serendipity}"
    fi
    # Gate-event distribution — gate names + counts only, never the
    # `reason` / `details` payloads (which can carry arbitrary text).
    if [[ -f "${GATE_EVENTS_FILE}" ]] && [[ -s "${GATE_EVENTS_FILE}" ]]; then
      _share_gate_distrib="$(jq -sr --argjson cutoff "${cutoff_ts}" \
        'map(select((.ts // 0) >= $cutoff))
         | map(.gate)
         | group_by(.) | map({gate: .[0], n: length})
         | sort_by(-.n) | .[0:10]
         | .[] | "  • \(.gate): \(.n)"' \
        "${GATE_EVENTS_FILE}" 2>/dev/null || true)"
      if [[ -n "${_share_gate_distrib}" ]]; then
        printf '\n**Top gates by fire count:**\n'
        printf '%s\n' "${_share_gate_distrib}"
      fi
    fi

    # Copy-paste-friendly one-liner at the bottom — the line a user
    # actually pastes into Slack/Twitter without editing.
    case "${MODE}" in
      week)  _share_window_phrase="this week" ;;
      month) _share_window_phrase="this month" ;;
      all)   _share_window_phrase="to date" ;;
      last)  _share_window_phrase="this session" ;;
      *)     _share_window_phrase="${window_label}" ;;
    esac
    printf '\n---\n\n'
    printf '_Share-friendly one-liner:_\n'
    printf '> oh-my-claude caught %s issue%s across %s session%s %s (~%s saved).\n' \
      "${_share_caught_total}" \
      "$( [[ "${_share_caught_total}" == "1" ]] && printf '' || printf 's' )" \
      "${_share_sessions}" \
      "$( [[ "${_share_sessions}" == "1" ]] && printf '' || printf 's' )" \
      "${_share_window_phrase}" \
      "${_share_saved_human}"
  fi

  printf '\n_Generated by [oh-my-claude](https://github.com/X0x888/oh-my-claude). All free-text fields suppressed; numbers and gate-name distribution only._\n'
  # Clean up the MODE=last temp file (if we created one).
  if [[ "${_share_sessions_src}" != "${SUMMARY_FILE}" ]] && [[ -f "${_share_sessions_src}" ]]; then
    rm -f "${_share_sessions_src}" 2>/dev/null || true
  fi
  exit 0
fi

# v1.34.x — Field-shape audit (Bug B post-mortem rule #2).
#
# Walks ~/.claude/quality-pack/gate_events.jsonl and asserts every
# row's detail fields match their gate-shape contract. The 4 leaked
# rows in this session's pre-scrub ledger (state-corruption rows
# carrying prompt-text fragments in archive_path) would have been
# flagged in v1.29.0 if this audit had existed then. The audit is
# read-only — surfaces violations, does not modify the ledger.
#
# Per-gate field-shape contract (the truthful shape of each detail
# field, derived from the producer source):
#
#   state-corruption.recovered:
#     details.archive_path  ~ /\.corrupt\.[0-9]+$/   (path-shaped, ends in .corrupt.<epoch>)
#     details.recovered_ts  ~ /^[0-9]{10,}$/         (Unix epoch, ≥ 10 digits)
#
#   wave-plan.wave-assigned:
#     details.wave_idx       ~ /^[0-9]+$/
#     details.wave_total     ~ /^[0-9]+$/
#     details.finding_count  ~ /^[0-9]+$/
#     details.surface        ≤ 200 chars (free-text but bounded)
#
#   finding-status.finding-status-change:
#     details.finding_id      ~ /^F-[0-9]+$/
#     details.finding_status  ∈ {pending, in_progress, shipped, deferred, rejected}
#
#   bias-defense.directive_fired:
#     details.directive       ∈ {prometheus-suggest, intent-verify,
#                                exemplifying, completeness, intent-broadening,
#                                intent-broadening-no-inventory, divergence}
#
# A row that violates ANY of these shapes is reported. Other gates
# (advisory, discovered-scope, pretool-intent, quality, session-handoff,
# wave-shape, ulw-pause, mark-deferred, canary, directive-budget,
# delivery-contract, session-start-welcome, stop-failure) have no
# typed detail-field invariants today; they are passed through with
# only a generic length bound (every detail value ≤ 1024 chars per
# the record_gate_event cap, with 256-char cap for state-corruption).
# When a new gate adds typed detail invariants, extend this audit AND
# the contract docstring on record_gate_event.
if [[ "${FIELD_SHAPE_AUDIT}" -eq 1 ]]; then
  printf '# Field-shape audit — %s\n\n' "${window_label}"
  printf '_Source: `%s` · cutoff_ts=%s_\n\n' "${GATE_EVENTS_FILE}" "${cutoff_ts}"

  if [[ ! -f "${GATE_EVENTS_FILE}" ]] || [[ ! -s "${GATE_EVENTS_FILE}" ]]; then
    printf '_No `gate_events.jsonl` ledger to audit._\n'
    exit 0
  fi

  # Apply window cutoff first, then audit. Materialize to a temp file
  # so the per-gate jq passes don't re-scan the entire ledger N times.
  _audit_window_jsonl="$(mktemp)"
  trap 'rm -f "${_audit_window_jsonl}"' EXIT
  if [[ "${MODE}" == "all" ]]; then
    cp "${GATE_EVENTS_FILE}" "${_audit_window_jsonl}"
  elif [[ "${MODE}" == "last" ]]; then
    tail -n 200 "${GATE_EVENTS_FILE}" > "${_audit_window_jsonl}"
  else
    jq -c --argjson cutoff "${cutoff_ts}" 'select((.ts // 0) >= $cutoff)' \
      "${GATE_EVENTS_FILE}" > "${_audit_window_jsonl}" 2>/dev/null || true
  fi

  _audit_total="$(wc -l < "${_audit_window_jsonl}" | tr -d '[:space:]')"
  printf '_Audited %s row(s) in window._\n\n' "${_audit_total:-0}"

  _violations=0
  _violations_file="$(mktemp)"
  trap 'rm -f "${_audit_window_jsonl}" "${_violations_file}"' EXIT

  # Helper: emit one violation row to the violations table.
  emit_violation() {
    local gate="$1" event="$2" field="$3" expected="$4" got="$5" ts="$6"
    # Truncate `got` aggressively for table render; ≤ 80 chars + ellipsis.
    if (( ${#got} > 80 )); then
      got="${got:0:77}…"
    fi
    # Replace newlines / RS / tabs / pipes in the excerpt to keep the
    # markdown table render-safe. Pipes break the table; control bytes
    # break terminal render and (with ANSI) could be hostile.
    got="${got//$'\n'/␤}"
    got="${got//$'\r'/␍}"
    got="${got//$'\t'/␉}"
    got="${got//$'\x1e'/␞}"
    got="${got//|/\\|}"
    printf '| `%s.%s` | `%s` | `%s` | `%s` | %s |\n' \
      "${gate}" "${event}" "${field}" "${expected}" "${got}" "${ts}" >> "${_violations_file}"
    _violations=$((_violations + 1))
  }

  # ── state-corruption.recovered ────────────────────────────────────
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    ts="$(jq -r '.ts // "?"' <<<"${row}")"
    archive_path="$(jq -r '.details.archive_path // ""' <<<"${row}")"
    recovered_ts="$(jq -r '.details.recovered_ts // ""' <<<"${row}")"
    recovery_count="$(jq -r '.details.recovery_count // ""' <<<"${row}")"
    if [[ -n "${archive_path}" ]] && [[ ! "${archive_path}" =~ \.corrupt\.[0-9]+$ ]]; then
      emit_violation "state-corruption" "recovered" "archive_path" \
        "ends in .corrupt.<epoch>" "${archive_path}" "${ts}"
    fi
    if [[ -n "${recovered_ts}" ]] && [[ ! "${recovered_ts}" =~ ^[0-9]{10,}$ ]]; then
      emit_violation "state-corruption" "recovered" "recovered_ts" \
        "Unix epoch (≥10 digits)" "${recovered_ts}" "${ts}"
    fi
    # recovery_count is non-negative int when present (added with the
    # Bug B post-mortem alarm — counts state-recovery fires per session
    # and escalates the directive on the second fire).
    if [[ -n "${recovery_count}" ]] && [[ ! "${recovery_count}" =~ ^[0-9]+$ ]]; then
      emit_violation "state-corruption" "recovered" "recovery_count" \
        "non-negative int" "${recovery_count}" "${ts}"
    fi
  done < <(jq -c 'select(.gate=="state-corruption" and .event=="recovered")' "${_audit_window_jsonl}" 2>/dev/null)

  # ── wave-plan.wave-assigned ──────────────────────────────────────
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    ts="$(jq -r '.ts // "?"' <<<"${row}")"
    wave_idx="$(jq -r '.details.wave_idx // ""' <<<"${row}")"
    wave_total="$(jq -r '.details.wave_total // ""' <<<"${row}")"
    finding_count="$(jq -r '.details.finding_count // ""' <<<"${row}")"
    surface="$(jq -r '.details.surface // ""' <<<"${row}")"
    if [[ -n "${wave_idx}" ]] && [[ ! "${wave_idx}" =~ ^[0-9]+$ ]]; then
      emit_violation "wave-plan" "wave-assigned" "wave_idx" "non-negative int" "${wave_idx}" "${ts}"
    fi
    if [[ -n "${wave_total}" ]] && [[ ! "${wave_total}" =~ ^[0-9]+$ ]]; then
      emit_violation "wave-plan" "wave-assigned" "wave_total" "non-negative int" "${wave_total}" "${ts}"
    fi
    if [[ -n "${finding_count}" ]] && [[ ! "${finding_count}" =~ ^[0-9]+$ ]]; then
      emit_violation "wave-plan" "wave-assigned" "finding_count" "non-negative int" "${finding_count}" "${ts}"
    fi
    if [[ -n "${surface}" ]] && (( ${#surface} > 200 )); then
      emit_violation "wave-plan" "wave-assigned" "surface" "≤200 chars" "${surface}" "${ts}"
    fi
  done < <(jq -c 'select(.gate=="wave-plan" and .event=="wave-assigned")' "${_audit_window_jsonl}" 2>/dev/null)

  # ── finding-status.finding-status-change ─────────────────────────
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    ts="$(jq -r '.ts // "?"' <<<"${row}")"
    finding_id="$(jq -r '.details.finding_id // ""' <<<"${row}")"
    finding_status="$(jq -r '.details.finding_status // ""' <<<"${row}")"
    if [[ -n "${finding_id}" ]] && [[ ! "${finding_id}" =~ ^F-[0-9]+$ ]]; then
      emit_violation "finding-status" "finding-status-change" "finding_id" "F-<int>" "${finding_id}" "${ts}"
    fi
    if [[ -n "${finding_status}" ]]; then
      case "${finding_status}" in
        pending|in_progress|shipped|deferred|rejected) ;;
        *) emit_violation "finding-status" "finding-status-change" "finding_status" \
             "{pending,in_progress,shipped,deferred,rejected}" "${finding_status}" "${ts}" ;;
      esac
    fi
  done < <(jq -c 'select(.gate=="finding-status" and .event=="finding-status-change")' "${_audit_window_jsonl}" 2>/dev/null)

  # ── bias-defense.directive_fired ─────────────────────────────────
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    ts="$(jq -r '.ts // "?"' <<<"${row}")"
    directive="$(jq -r '.details.directive // ""' <<<"${row}")"
    if [[ -n "${directive}" ]]; then
      case "${directive}" in
        prometheus-suggest|intent-verify|exemplifying|completeness|intent-broadening|intent-broadening-no-inventory|divergence) ;;
        *) emit_violation "bias-defense" "directive_fired" "directive" \
             "{prometheus-suggest,intent-verify,exemplifying,completeness,intent-broadening,intent-broadening-no-inventory,divergence}" \
             "${directive}" "${ts}" ;;
      esac
    fi
  done < <(jq -c 'select(.gate=="bias-defense" and .event=="directive_fired")' "${_audit_window_jsonl}" 2>/dev/null)

  # ── Render result ────────────────────────────────────────────────
  if [[ "${_violations}" -eq 0 ]]; then
    printf '## Result: ✅ clean\n\n'
    printf 'Every audited gate-event row matches its detail-field shape contract.\n\n'
    printf 'Gates with typed detail invariants checked: `state-corruption`, `wave-plan`, `finding-status`, `bias-defense`.\n'
    printf 'Other gates have no typed detail invariants today and are bounded only by the per-event 1024-char value cap (256 for state-corruption).\n'
    exit 0
  fi

  printf '## Result: ❌ %d violation(s)\n\n' "${_violations}"
  printf '_Each row below shows a gate event whose detail field violates its declared shape contract. Bug B-class leaks (positional misalignment dropping prompt-text into typed fields) appear here as values that fail their regex/enum/length contract._\n\n'
  printf '| Gate.event | Field | Expected | Got (excerpt) | ts |\n'
  printf '|---|---|---|---|---|\n'
  cat "${_violations_file}"
  printf '\n'
  printf '_The full ledger is at `%s`. Investigate each violating row before scrubbing — it indicates either a producer bug, a misclassified gate event, or a contract that needs updating._\n' \
    "${GATE_EVENTS_FILE}"
  exit 1
fi

printf '# Harness report — %s\n\n' "${window_label}"
printf '_Generated %s. Source: `~/.claude/quality-pack/`._\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ----------------------------------------------------------------------
# Helper: filter JSONL rows by a timestamp field within the cutoff window.
# Reads file path from $1, ts field jq path from $2 (e.g. '.start_ts' or '.ts').
# Hoisted above the Headline pre-pass (v1.36.x W2 F-008) so the headline
# heuristics can call it before the detail sections.
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

# Interpretation footer accumulators (v1.17.0). Each section below
# updates these as it computes its own metrics; the bottom "Patterns to
# consider" block turns them into 1-line actionable suggestions.
# v1.36.x W2 F-008 hoists the heuristic computation to a "Headline"
# pre-pass at the top so a user opening the report once sees the
# decision-ready insight before the table walls. Defaults to "no signal"
# so headline renders cleanly on empty datasets.
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
# v1.36.x W2 F-008 — Headline pre-pass.
#
# Runs the same heuristic queries the bottom "Patterns to consider"
# section runs, but rendered FIRST so the user sees the
# decision-ready insight before scrolling through 13 detail sections.
# The detail sections re-derive their own values (small jq cost
# duplication, ~5-10ms total); the predicates and thresholds match
# the bottom section's so the two never disagree.
#
# Insight ranking (data-lens recommended):
#   1. Anomaly outranks dominance outranks reassurance outranks fun
#      fact. Specifically: gate-fire density and skip rate are
#      anomaly signals (something off-target); serendipity catches
#      and reviewer-low-find are reassurance/dominance signals.
#   2. Render the top 3 strongest signals at the headline. The full
#      list is still rendered at the bottom under "Patterns to
#      consider" for users who want the comprehensive view.
_headline_lines=()

_hl_session_rows="$(filter_by_window "${SUMMARY_FILE}" '.start_ts')"
_hl_session_count="$(printf '%s\n' "${_hl_session_rows}" | grep -c . || true)"
_hl_session_count="${_hl_session_count//[!0-9]/}"
_hl_session_count="${_hl_session_count:-0}"
_hl_block_total=0
_hl_skip_total=0
_hl_serendipity_total=0
_hl_reviewed=0
if [[ "${_hl_session_count}" -gt 0 ]]; then
  _hl_block_total="$(printf '%s\n' "${_hl_session_rows}" | jq -s 'map((.guard_blocks // 0) + (.dim_blocks // 0)) | add // 0' 2>/dev/null || echo 0)"
  _hl_skip_total="$(printf '%s\n' "${_hl_session_rows}" | jq -s 'map(.skip_count // 0) | add // 0' 2>/dev/null || echo 0)"
  _hl_serendipity_total="$(printf '%s\n' "${_hl_session_rows}" | jq -s 'map(.serendipity_count // 0) | add // 0' 2>/dev/null || echo 0)"
  _hl_reviewed="$(printf '%s\n' "${_hl_session_rows}" | jq -s 'map(select(.reviewed == true)) | length' 2>/dev/null || echo 0)"
fi

# H1: gate-fire density >2/session is the strongest anomaly signal.
if [[ "${_hl_session_count}" -gt 0 && "${_hl_block_total}" -gt 0 ]]; then
  _hl_bps=$(( _hl_block_total * 10 / _hl_session_count ))
  if [[ "${_hl_bps}" -ge 21 ]]; then
    _hl_int=$(( _hl_bps / 10 ))
    _hl_dec=$(( _hl_bps % 10 ))
    _headline_lines+=("**High gate-fire density: ~${_hl_int}.${_hl_dec} blocks/session.** ${_hl_block_total} blocks across ${_hl_session_count} sessions. Gates may be over-firing — try \`/metis\` on the next big task or \`/plan-hard\` for tighter scope.")
  fi
fi

# H2: skip-to-block ratio >40% suggests gates fire on legitimate work.
if [[ "${_hl_block_total}" -gt 0 && "${_hl_skip_total}" -gt 0 ]]; then
  _hl_skip_pct=$(( _hl_skip_total * 100 / _hl_block_total ))
  if [[ "${_hl_skip_pct}" -ge 40 ]]; then
    _headline_lines+=("**High skip rate: ${_hl_skip_pct}%.** ${_hl_skip_total}/${_hl_block_total} blocks ended in \`/ulw-skip\`. Gates are likely firing on legitimate work — review the most-skipped gate type below and consider tightening trigger conditions.")
  fi
fi

# H3: classifier misfire trend.
_hl_misfires=0
if [[ -f "${HOME}/.claude/quality-pack/classifier_misfires.jsonl" ]]; then
  if [[ "${MODE}" == "all" ]]; then
    _hl_misfires="$(grep -c . "${HOME}/.claude/quality-pack/classifier_misfires.jsonl" 2>/dev/null || echo 0)"
  else
    _hl_misfires="$(jq -c --argjson cutoff "${cutoff_ts}" 'select((.ts // 0 | tonumber) >= $cutoff)' "${HOME}/.claude/quality-pack/classifier_misfires.jsonl" 2>/dev/null | grep -c . || echo 0)"
  fi
  _hl_misfires="${_hl_misfires//[!0-9]/}"
  _hl_misfires="${_hl_misfires:-0}"
fi
if [[ "${_hl_misfires}" -ge 5 && "${MODE}" == "week" ]] || \
   [[ "${_hl_misfires}" -ge 20 && "${MODE}" == "month" ]] || \
   [[ "${_hl_misfires}" -ge 5 && "${MODE}" == "all" ]]; then
  _headline_lines+=("**Classifier misfires accumulating: ${_hl_misfires}.** Run \`tools/replay-classifier-telemetry.sh\` against the regression fixture to spot structural patterns worth codifying in \`lib/classifier.sh\`.")
fi

# H4: serendipity (reassurance signal — only render if no anomaly above).
if [[ "${#_headline_lines[@]}" -lt 3 && "${_hl_serendipity_total}" -gt 0 ]]; then
  _headline_lines+=("**Serendipity caught ${_hl_serendipity_total} adjacent defect$([[ "${_hl_serendipity_total}" -eq 1 ]] && echo "" || echo "s")** in window — bugs found while doing other work, fixed in-session per the Serendipity Rule. Sustained > 0 means the rule is paying for itself.")
fi

# Render the headline section.
printf '## Headline\n\n'
if [[ "${#_headline_lines[@]}" -eq 0 ]]; then
  if [[ "${_hl_session_count}" -eq 0 ]]; then
    printf '_No sessions in window — run a few \`/ulw\` cycles, then re-check after the next daily sweep._\n\n'
  else
    printf '_No anomalies surfaced. %s session(s), %s gate-block(s), %s skip(s), %s serendipity catch(es) in window — ship with confidence._\n\n' \
      "${_hl_session_count}" "${_hl_block_total}" "${_hl_skip_total}" "${_hl_serendipity_total}"
  fi
else
  for _hl_line in "${_headline_lines[@]}"; do
    printf -- '- %s\n\n' "${_hl_line}"
  done
fi
printf '_Detail sections below; comprehensive heuristic review at the bottom under **Patterns to consider**._\n\n'

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
  # A3-MED-2 (4-attacker security review): strip control bytes from
  # the archetype label before render. .archetype is recorded by
  # record-archetype.sh from model-influenced palette/contract output.
  printf '%s\n' "${archetype_rows}" | jq -r '.archetype // "unknown"' \
    | sort | uniq -c | sort -rn | head -5 \
    | while read -r n arche; do
        _safe_arche="$(printf '%s' "${arche}" | _omc_strip_render_unsafe)"
        printf -- '- `%s` × %s\n' "${_safe_arche}" "${n}"
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
  # v1.32.16 (4-attacker security review, A3-MED-1): strip C0/C1
  # control bytes from model-controllable .fix / .original_task fields
  # before render. jq -r decodes JSON `...` escapes back to raw
  # bytes; without the strip a hostile model can drive ANSI sequences
  # to the user's terminal via this render path.
  printf '%s\n' "${serendipity_rows}" | tail -n 5 \
    | jq -r '"- \(.fix)\(if (.original_task // "") != "" then " (during: \(.original_task))" else "" end)"' 2>/dev/null \
    | _omc_strip_render_unsafe || true
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
  # A3-MED-2 (4-attacker security review): strip control bytes from
  # the model-influenced misfire .reason field before render.
  printf '%s\n' "${misfire_rows}" | jq -r '.reason // "unknown"' | sort | uniq -c | sort -rn | head -5 | while read -r n reason; do
    _safe_reason="$(printf '%s' "${reason}" | _omc_strip_render_unsafe)"
    printf -- '- `%s` × %s\n' "${_safe_reason}" "${n}"
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

  # v1.37.x W4 (Item 6): per-gate skip-rate sub-table. Joins ulw-skip:
  # registered events back to the gate they bypassed (recorded by
  # ulw-skip-register.sh:48+). High skip rate on a gate is a false-
  # positive proxy — that gate is firing on legitimate work. The
  # share-card weighting (show-report.sh:359 — wave-shape and
  # discovered-scope both at 360s) was an open question per Item 6;
  # this surface lets the user empirically answer "is wave-shape
  # over-firing?" before any reweighting decision. Skip rate column
  # only renders when at least one ulw-skip:registered event exists
  # in the window, so clean sessions get a quiet section.
  ulw_skip_rows="$(printf '%s\n' "${gate_event_rows}" \
    | jq -c 'select(.gate == "ulw-skip" and .event == "registered")' 2>/dev/null || true)"
  if [[ -n "${ulw_skip_rows}" ]]; then
    printf '_Per-gate skip rate (false-positive proxy):_\n\n'
    printf '| Gate | Blocks | Skips | Skip-rate |\n'
    printf '|---|---:|---:|---:|\n'
    # For each gate that fired AT LEAST one block, compute skip count
    # by joining ulw-skip rows on details.skipped_gate. Skip rate =
    # skips/blocks (capped at 100%; values >1 are theoretically
    # possible if a stale skip carries over, treat as 100%).
    printf '%s\n' "${gate_event_rows}" \
      | jq -r 'select(.event == "block") | .gate' \
      | sort -u \
      | while IFS= read -r _gate; do
          [[ -z "${_gate}" ]] && continue
          [[ "${_gate}" == "ulw-skip" ]] && continue
          _gate_blocks="$(printf '%s\n' "${gate_event_rows}" \
            | jq -c --arg g "${_gate}" 'select(.gate == $g and .event == "block")' \
            | wc -l | tr -d '[:space:]')"
          _gate_skips="$(printf '%s\n' "${ulw_skip_rows}" \
            | jq -c --arg g "${_gate}" 'select(.details.skipped_gate == $g)' \
            | wc -l | tr -d '[:space:]')"
          [[ "${_gate_blocks}" =~ ^[0-9]+$ ]] || _gate_blocks=0
          [[ "${_gate_skips}" =~ ^[0-9]+$ ]] || _gate_skips=0
          if [[ "${_gate_blocks}" -gt 0 ]]; then
            _skip_rate_pct=$(( _gate_skips * 100 / _gate_blocks ))
            [[ "${_skip_rate_pct}" -gt 100 ]] && _skip_rate_pct=100
            printf '| `%s` | %d | %d | %d%% |\n' \
              "${_gate}" "${_gate_blocks}" "${_gate_skips}" "${_skip_rate_pct}"
          fi
        done
    printf '\n'
    printf '_High skip-rate on a single gate suggests false-positive firing — used to empirically re-evaluate the share-card weighting (currently uniform 360s for wave-shape / discovered-scope / shortcut-ratio per show-report.sh:359). Two weeks of multi-session data is a reasonable cohort before re-weighting._\n\n'
  fi
fi

# ----------------------------------------------------------------------
# Section 4c: Bias-defense directive fires (v1.23.0; broadened v1.26.0)
#
# The router emits gate events with gate="bias-defense" when a
# directive fires (prometheus-suggest, intent-verify, exemplifying,
# completeness). Without this section the user could not answer "is
# the broadened completeness directive actually firing on my prompts?"
# or "how often does the narrowing layer kick in?" — the very telemetry
# needed to validate that the v1.23.0 / v1.26.0 releases are working.
#
# v1.26.0 split: `directive=exemplifying` rows fire when example markers
# matched AND execution intent (preserves the v1.23.0 narrow trigger).
# `directive=completeness` rows fire when the broader trigger matched
# (completeness verbs OR example markers on advisory) but the narrow
# example-marker+execution combo did NOT — the new code path that fixes
# the iOS-orphan-files miss.
printf '## Bias-defense directives fired\n\n'
bias_defense_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "bias-defense" and .event == "directive_fired")' 2>/dev/null || true)"
if [[ -z "${bias_defense_rows}" ]]; then
  printf '_No bias-defense directives fired in window. Telemetry is new in v1.23.0; populates as sessions sweep._\n\n'
else
  printf '| Directive | Fires |\n|---|---:|\n'
  for _directive in exemplifying completeness prometheus-suggest intent-verify intent-broadening intent-broadening-no-inventory divergence; do
    _fire_count="$(printf '%s\n' "${bias_defense_rows}" | jq -c --arg d "${_directive}" 'select(.details.directive == $d)' | wc -l | tr -d '[:space:]')"
    [[ "${_fire_count}" -eq 0 ]] && continue
    printf '| `%s` | %s |\n' "${_directive}" "${_fire_count}"
  done
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4c0.5: Router directive footprint (v1.32.x instrumentation payoff)
#
# `directive_emitted` timing rows record the character cost of every
# router-added directive body. The first landing proved the rows existed;
# this section is the user-facing payoff. It answers "which directives are
# costing me the most prompt surface?" using recorded codepoint counts.
#
# Deliberately reports chars, not fake tokens. The instrumentation itself
# stores codepoint counts and explicitly defers exact tokenization to a
# tokenizer-aware analysis layer. Relative chars are still valuable for
# ranking heavy directives and spotting prompt-tax drift.
printf '## Router directive footprint\n\n'
if ! is_time_tracking_enabled; then
  printf '_Time tracking is disabled (`time_tracking=off`), so directive footprint is unavailable._\n\n'
else
  if [[ -z "${_xs_rollup_cache}" ]]; then
    _xs_rollup_cache="$(timing_xs_aggregate "${cutoff_ts}")"
  fi
  _directive_total_chars="$(jq -r '.directive_total_chars // 0' <<<"${_xs_rollup_cache}" 2>/dev/null)"
  _directive_total_fires="$(jq -r '.directive_count // 0' <<<"${_xs_rollup_cache}" 2>/dev/null)"
  _directive_total_chars="${_directive_total_chars:-0}"
  _directive_total_fires="${_directive_total_fires:-0}"
  [[ "${_directive_total_chars}" =~ ^[0-9]+$ ]] || _directive_total_chars=0
  [[ "${_directive_total_fires}" =~ ^[0-9]+$ ]] || _directive_total_fires=0

  if [[ "${_directive_total_fires}" -eq 0 ]]; then
    printf '_No directive footprint rows in window. Populates from v1.32.x timing telemetry as sessions sweep._\n\n'
  else
    printf '_Window total: %s directive fires, %s chars of router-added prompt surface. Char counts are recorded codepoints, not token estimates._\n\n' \
      "${_directive_total_fires}" "${_directive_total_chars}"
    printf '| Directive | Fires | Total chars | Avg chars/fire |\n'
    printf '|---|---:|---:|---:|\n'
    jq -r '
      (.directive_breakdown // {}) as $chars
      | (.directive_counts // {}) as $counts
      | ($chars | to_entries | map({name: .key, chars: .value, fires: ($counts[.key] // 0)}))
      | sort_by(-.chars, .name)
      | .[0:12]
      | .[]
      | [
          .name,
          (.fires | tostring),
          (.chars | tostring),
          (if (.fires // 0) > 0 then ((.chars / .fires) | floor | tostring) else "0" end)
        ]
      | @tsv
    ' <<<"${_xs_rollup_cache}" 2>/dev/null \
      | while IFS=$'\t' read -r _d_name _d_fires _d_chars _d_avg; do
          [[ -z "${_d_name}" ]] && continue
          printf '| `%s` | %s | %s | %s |\n' "${_d_name}" "${_d_fires}" "${_d_chars}" "${_d_avg}"
        done
    printf '\n'
  fi
fi

# ----------------------------------------------------------------------
# Section 4c0.6: Directive value attribution (v1.36.x W2 F-006)
#
# Joins bias-defense directive_fired gate events with session_summary
# outcomes (committed vs abandoned) so a user can answer "of sessions
# where directive X fired, what fraction shipped?". A directive that
# fires often but the sessions never commit may be over-firing or
# misrouted; a directive that fires on sessions that ship at high
# rate is paying for itself.
#
# Closes the v1.36.0 deferred audit (#15) read path: the firing-rate
# audit needed a "did downstream behavior change" signal. Outcome is a
# coarse but defensible proxy — committed sessions are the harness's
# success surface; abandoned sessions are where steering may have
# missed.
printf '## Directive value attribution\n\n'
_directive_fires_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "bias-defense" and .event == "directive_fired" and (.details.directive // "") != "" and (.session_id // "") != "")' 2>/dev/null || true)"
if [[ -z "${_directive_fires_rows}" ]]; then
  printf '_No bias-defense directive fires with session attribution in window. The 4c (Bias-defense directives fired) section reports raw fire counts; this section adds session-outcome correlation when both data feeds are populated._\n\n'
else
  # Build a session_id → outcome map from session_summary rows in window.
  if [[ -n "${_hl_session_rows}" ]]; then
    _session_outcome_map="$(printf '%s\n' "${_hl_session_rows}" \
      | jq -s 'map({key: .session_id, value: (.outcome // "unknown")}) | from_entries' 2>/dev/null || printf '{}')"
  else
    _session_outcome_map="{}"
  fi

  if [[ "${_session_outcome_map}" == "{}" ]] || [[ -z "${_session_outcome_map}" ]]; then
    printf '_Directive fires recorded but no session_summary rows in window — outcome attribution requires both feeds._\n\n'
  else
    printf '| Directive | Fires | Sessions | Shipped | Dropped | Other | Apply rate |\n'
    printf '|---|---:|---:|---:|---:|---:|---:|\n'
    printf '%s\n' "${_directive_fires_rows}" \
      | jq -sr --argjson outcomes "${_session_outcome_map}" '
        # Group fires by directive name, collect unique session_ids
        # touched, then look up the outcome of each session from the map.
        #
        # v1.39.0 W1: token alignment. Producer (stop-guard.sh) emits
        # one of {completed, released, skip-released, exhausted} on
        # Stop, and the persisted sweep inference adds {completed_inferred,
        # idle, unclassified_by_sweep} (common.sh:1540). The live-sweep
        # synthesizer defaults to "active" (show-report.sh:220). The
        # prior "committed"/"abandoned" buckets matched none of these,
        # so apply-rate was structurally 0/N. The "shipped" bucket now
        # counts every terminal Stop-derived success (completed +
        # completed_inferred + released + skip-released); "dropped"
        # counts every terminal failure shape (abandoned + exhausted +
        # unclassified_by_sweep); "other" absorbs in-flight (active)
        # and idle (zero-activity) sessions so they do not deflate the
        # rate.
        group_by(.details.directive)
        | map({
            directive: .[0].details.directive,
            fires: length,
            sessions: (map(.session_id) | unique),
          })
        | map(. + {
            outcomes: (.sessions | map($outcomes[.] // "unknown"))
          })
        | map(. + {
            n_sessions: (.sessions | length),
            n_shipped: (.outcomes | map(select(. == "completed" or . == "completed_inferred" or . == "released" or . == "skip-released")) | length),
            n_dropped: (.outcomes | map(select(. == "abandoned" or . == "exhausted" or . == "unclassified_by_sweep")) | length),
            n_other: (.outcomes | map(select(. == "active" or . == "idle" or . == "unknown")) | length)
          })
        | sort_by(-.fires)
        | .[0:10]
        | .[]
        | [
            .directive,
            (.fires | tostring),
            (.n_sessions | tostring),
            (.n_shipped | tostring),
            (.n_dropped | tostring),
            (.n_other | tostring),
            (if (.n_shipped + .n_dropped) > 0 then ((.n_shipped * 100 / (.n_shipped + .n_dropped)) | floor | tostring + "%") else "—" end)
          ]
        | @tsv
      ' 2>/dev/null \
      | while IFS=$'\t' read -r _dva_name _dva_fires _dva_sess _dva_ship _dva_drop _dva_other _dva_rate; do
          [[ -z "${_dva_name}" ]] && continue
          printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' \
            "${_dva_name}" "${_dva_fires}" "${_dva_sess}" "${_dva_ship}" "${_dva_drop}" "${_dva_other}" "${_dva_rate}"
        done
    printf '\n_Apply rate = shipped / (shipped + dropped). "Shipped" counts `completed` + `completed_inferred` + `released` + `skip-released`; "Dropped" counts `abandoned` + `exhausted` + `unclassified_by_sweep`; "Other" counts in-flight `active` and zero-activity `idle` sessions excluded from the rate. A directive with low apply rate AND high fire count is a candidate for budget removal — it is contributing prompt-tax without correlating to ship signal._\n\n'
  fi
fi

# ----------------------------------------------------------------------
# Section 4c0.75: Router directive suppressions (v1.33.0)
#
# The directive budget records suppressions as gate events so users can
# audit when the router trimmed lower-priority SOFT directives. This is
# the second half of the budget contract: emitted prompt surface is
# visible above, and suppressed prompt surface is visible here.
printf '## Router directive suppressions\n\n'
directive_budget_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "directive-budget" and .event == "suppressed")' 2>/dev/null || true)"
if [[ -z "${directive_budget_rows}" ]]; then
  printf '_No directive-budget suppressions in window._\n\n'
else
  _directive_budget_total="$(printf '%s\n' "${directive_budget_rows}" | wc -l | tr -d '[:space:]')"
  printf '_Window total: %s suppressed directive(s). Counts below are grouped by directive and suppression reason._\n\n' \
    "${_directive_budget_total}"
  printf '| Directive | Reason | Count |\n'
  printf '|---|---|---:|\n'
  jq -sr '
    map({
      directive: (.details.directive // "unknown"),
      reason: (.details.reason // "unknown")
    })
    | group_by(.directive + "|" + .reason)
    | map({
        directive: .[0].directive,
        reason: .[0].reason,
        n: length
      })
    | sort_by(-.n, .directive, .reason)
    | .[0:12]
    | .[]
    | [.directive, .reason, (.n | tostring)]
    | @tsv
  ' <<<"${directive_budget_rows}" 2>/dev/null \
    | while IFS=$'\t' read -r _db_name _db_reason _db_count; do
        [[ -z "${_db_name}" ]] && continue
        printf '| `%s` | `%s` | %s |\n' "${_db_name}" "${_db_reason}" "${_db_count}"
      done
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4c0.5: Installation drift (v1.36.x W1 F-005)
#
# session-start-drift-check.sh emits an `installation-drift drift-detected`
# row each time it surfaces a stale-bundle warning. Aggregate the rate
# across the window so a user can see how often they were running a
# stale install — high counts signal the user habitually skips
# `bash install.sh` after `git pull`.
printf '## Installation drift\n\n'
drift_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "installation-drift" and .event == "drift-detected")' 2>/dev/null || true)"
if [[ -z "${drift_rows}" ]]; then
  printf '_No installation-drift events in window. Either you keep your install fresh, or `installation_drift_check=false`._\n\n'
else
  _drift_total="$(printf '%s\n' "${drift_rows}" | wc -l | tr -d '[:space:]')"
  printf '_Window total: %s drift detection(s). Each row marks a SessionStart where the installed bundle was older than the source repo — a `bash install.sh` would resolve the gap._\n\n' \
    "${_drift_total}"
  printf '| Drift kind | Source version | Commits ahead | Count |\n'
  printf '|---|---|---:|---:|\n'
  jq -sr '
    map({
      drift_kind: (.details.drift_kind // "unknown"),
      version: (.details.version // "unknown"),
      commits: (.details.commits // "0")
    })
    | group_by(.drift_kind + "|" + .version + "|" + .commits)
    | map({
        drift_kind: .[0].drift_kind,
        version: .[0].version,
        commits: .[0].commits,
        n: length
      })
    | sort_by(-.n, .drift_kind, .version)
    | .[0:8]
    | .[]
    | [.drift_kind, .version, .commits, (.n | tostring)]
    | @tsv
  ' <<<"${drift_rows}" 2>/dev/null \
    | while IFS=$'\t' read -r _dk_kind _dk_ver _dk_commits _dk_count; do
        [[ -z "${_dk_kind}" ]] && continue
        printf '| `%s` | `%s` | %s | %s |\n' "${_dk_kind}" "${_dk_ver}" "${_dk_commits}" "${_dk_count}"
      done
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4c1.0: Delivery-contract fires (v1.34.0 Delivery Contract v2)
#
# stop-guard records `delivery-contract` block events with rich detail
# (`prompt_blocker_count`, `inferred_blocker_count`, `inferred_rules`,
# `commit_mode`, `prompt_surfaces`, `test_expectation`). This section
# aggregates the rule-fire frequency across the window so the user
# can answer "is v2 catching real misses, or chiming on noise?"
#
# The aggregation splits prompt-side blockers (v1) from inferred-side
# blockers (v2) and groups by inferred rule ID (R1/R2/R3a/R3b/R4/R5)
# so each inference rule's value is observable.
printf '## Delivery contract fires\n\n'
delivery_contract_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "delivery-contract" and .event == "block")' 2>/dev/null || true)"
if [[ -z "${delivery_contract_rows}" ]]; then
  printf '_No delivery-contract blocks in window._\n\n'
else
  _dc_total="$(printf '%s\n' "${delivery_contract_rows}" | wc -l | tr -d '[:space:]')"
  _dc_with_inferred="$(printf '%s\n' "${delivery_contract_rows}" | jq -c \
      'select((.details.inferred_blocker_count // "0" | tonumber) > 0)' 2>/dev/null \
      | wc -l | tr -d '[:space:]')"
  _dc_prompt_only=$(( _dc_total - _dc_with_inferred ))
  printf '_Window total: %s delivery-contract block(s) — %s prompt-only (v1) + %s inferred (v2)._\n\n' \
    "${_dc_total}" "${_dc_prompt_only}" "${_dc_with_inferred}"

  # Per-rule fire counts. inferred_rules is a CSV ("R1_missing_tests,
  # R3a_conf_no_parser") so we split each row into one record per
  # rule before grouping.
  printf '| Inference rule | Fires | Avg blocker count |\n'
  printf '|---|---:|---:|\n'
  jq -sr '
    [.[] | . as $row | (.details.inferred_rules // "" | split(",") | .[]) | select(length > 0) |
      {rule: ., total: ($row.details.inferred_blocker_count // "0" | tonumber)}]
    | group_by(.rule)
    | map({
        rule: .[0].rule,
        n: length,
        avg: ((map(.total) | add) / length | floor)
      })
    | sort_by(-.n, .rule)
    | .[0:12]
    | .[]
    | [.rule, (.n | tostring), (.avg | tostring)]
    | @tsv
  ' <<<"${delivery_contract_rows}" 2>/dev/null \
    | while IFS=$'\t' read -r _dc_rule _dc_n _dc_avg; do
        [[ -z "${_dc_rule}" ]] && continue
        printf '| `%s` | %s | %s |\n' "${_dc_rule}" "${_dc_n}" "${_dc_avg}"
      done
  printf '\n'
fi

# ----------------------------------------------------------------------
# Section 4c1.5: Model-drift canary signals (v1.26.0 Wave 2)
#
# Surfaces the silent-confabulation canary readings recorded by
# canary-claim-audit.sh at Stop time. The audit compares assertive
# verification claims in the model's response against the actual
# verification tool calls (Read/Bash/Grep/Glob/WebFetch/NotebookRead)
# fired in the same prompt_seq epoch. When the claim count exceeds the
# tool count by enough to suggest the model is asserting work it
# didn't do, the audit emits a per-event row with verdict in
# {clean, covered, low_coverage, unverified}. unverified is the
# strongest single-event signal — it ALSO emits a gate-event row that
# the section below counts.
#
# The renderer reads the cross-session canary aggregate first (rich
# verdict distribution); if the aggregate is missing or empty it falls
# back to gate_events to count unverified-claim fires alone. This
# preserves a useful surface even on installs where the canary library
# has emitted gate events but the cross-session JSONL hasn't accrued
# yet (fresh install, opt-out then opt-in, etc.).
canary_xs_jsonl="${HOME}/.claude/quality-pack/canary.jsonl"
canary_event_rows="$(printf '%s\n' "${gate_event_rows}" | jq -c \
    'select(.gate == "canary" and .event == "unverified_claim")' 2>/dev/null || true)"
if [[ -f "${canary_xs_jsonl}" && -s "${canary_xs_jsonl}" ]] || [[ -n "${canary_event_rows}" ]]; then
  printf '## Model-drift canary\n\n'
  if [[ -f "${canary_xs_jsonl}" && -s "${canary_xs_jsonl}" ]]; then
    # Distribution by verdict over the user's window (default 7d). Use
    # the same `cutoff_ts` epoch the report's other sections use (declared
    # at the top of show-report.sh based on the user's window argument).
    canary_window_rows="$(jq -c --argjson cutoff "${cutoff_ts}" 'select((.ts // 0) >= $cutoff)' "${canary_xs_jsonl}" 2>/dev/null || true)"
    if [[ -n "${canary_window_rows}" ]]; then
      total_audits="$(printf '%s\n' "${canary_window_rows}" | grep -c . || printf 0)"
      printf '_%s audits in the window. Verdict distribution:_\n\n' "${total_audits}"
      printf '| Verdict | Count | What it means |\n|---|---:|---|\n'
      for v in unverified low_coverage covered clean; do
        c="$(printf '%s\n' "${canary_window_rows}" | jq -c --arg v "$v" 'select(.verdict==$v)' 2>/dev/null | wc -l | tr -d ' ')"
        c="${c:-0}"
        case "$v" in
          unverified)   meaning="Model claimed verification, fired ZERO verification tools — silent confab signal" ;;
          low_coverage) meaning="Tool count below claim count — partial verification" ;;
          covered)      meaning="Tool count >= claim count — claims appear backed" ;;
          clean)        meaning="Few or no claims — low-noise turn" ;;
        esac
        [[ "$c" -gt 0 ]] && printf '| `%s` | %s | %s |\n' "$v" "$c" "${meaning}"
      done
      printf '\n'
      unv_count="$(printf '%s\n' "${canary_window_rows}" | jq -c 'select(.verdict=="unverified")' 2>/dev/null | wc -l | tr -d ' ')"
      unv_count="${unv_count:-0}"
      if [[ "${unv_count}" -gt 0 ]]; then
        printf '_See `~/.claude/quality-pack/canary.jsonl` for per-event detail. To opt out: `model_drift_canary=off`._\n\n'
      else
        printf '_No silent-confab signals in window — clean run._\n\n'
      fi
    fi
  elif [[ -n "${canary_event_rows}" ]]; then
    canary_event_count="$(printf '%s\n' "${canary_event_rows}" | grep -c .)"
    printf '_%s `unverified_claim` events in the window (cross-session aggregate not yet populated). The model named files/paths in its response without firing a corresponding Read/Bash/Grep — silent-confab signal._\n\n' "${canary_event_count}"
  fi
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

    # ----------------------------------------------------------------
    # v1.36.x W2 F-007 — Reviewer ROI.
    #
    # Joins agent-metrics.json (find rate) with the cross-session
    # timing rollup's agent_breakdown (per-reviewer total seconds).
    # Closes the data-lens deferred audit (#19) by giving the user
    # per-invocation cost so a reviewer with 50 cheap zero-find
    # calls can be cleanly distinguished from one with 5 expensive
    # zero-find --deep calls. Time-per-invocation high AND find rate
    # low is the candidate-for-balanced/minimal pattern.
    if [[ -z "${_xs_rollup_cache}" ]]; then
      _xs_rollup_cache="$(timing_xs_aggregate "${cutoff_ts}" 2>/dev/null || printf '{}')"
    fi
    # v1.40.x data-lens F-006: do NOT gate on _roi_breakdown being non-empty.
    # _xs_rollup_cache.agent_breakdown is window-scoped (paired Agent timing
    # rows); AGENT_METRICS_FILE.agents is lifetime. They populate via
    # independent paths — agent_breakdown is empty whenever time_tracking=off,
    # the window cuts before all sessions, or the timing flush did not run.
    # The per-row jq fallbacks below already emit `—` when window-timing is
    # missing, so the table renders correctly with lifetime inv/finds and
    # dashed time columns when the rollup is empty.
    _roi_breakdown="$(jq -r '(.agent_breakdown // {})' <<<"${_xs_rollup_cache}" 2>/dev/null || printf '{}')"
    [[ -z "${_roi_breakdown}" ]] && _roi_breakdown='{}'
    printf '\n**Reviewer ROI** _(joins lifetime find rate with window time when available)_\n\n'
    printf '| Reviewer | Inv | Finds | Find rate | Total time | Avg/inv |\n'
    printf '|---|---:|---:|---:|---:|---:|\n'
    jq -r --argjson breakdown "${_roi_breakdown}" '
      .agents // {} | to_entries
      | map({
          name: .key,
          inv: (.value.invocations // 0),
          finds: (.value.finding_verdicts // 0),
          total_s: ($breakdown[.key] // 0)
        })
      | map(select(.inv > 0))
      | sort_by(-.total_s, -.inv)
      | .[0:8]
      | .[]
      | [
          .name,
          (.inv | tostring),
          (.finds | tostring),
          (if .inv > 0 then ((.finds * 100 / .inv) | floor | tostring + "%") else "—" end),
          (if .total_s > 0 then ((.total_s | floor | tostring) + "s") else "—" end),
          (if .inv > 0 and .total_s > 0 then ((.total_s / .inv) | floor | tostring + "s") else "—" end)
        ]
      | @tsv
    ' "${AGENT_METRICS_FILE}" 2>/dev/null \
      | while IFS=$'\t' read -r _roi_name _roi_inv _roi_finds _roi_rate _roi_total _roi_avg; do
          [[ -z "${_roi_name}" ]] && continue
          printf '| `%s` | %s | %s | %s | %s | %s |\n' \
            "${_roi_name}" "${_roi_inv}" "${_roi_finds}" "${_roi_rate}" "${_roi_total}" "${_roi_avg}"
        done
    printf '\n_Sorted by total time when window timing is available, else by invocations. A reviewer with high `Avg/inv` and low `Find rate` is a candidate for `reviewer_budget=balanced` or removal — runs often, finds little. A reviewer with low cost and high find rate is paying for itself even at low invocation count._\n\n'
    printf '_Note: invocations and find rate are LIFETIME counts from `agent-metrics.json`; total time is WINDOW-scoped from the timing rollup and shows `—` when no paired Agent timing rows exist for the window (e.g., `time_tracking=off`, short window, or sessions whose timing flush did not run). Find rate is directional, not within-window precision._\n\n'
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
    if [[ -z "${_xs_rollup_cache}" ]]; then
      _xs_rollup_cache="$(timing_xs_aggregate "${cutoff_ts}")"
    fi
    _xs_rollup="${_xs_rollup_cache}"
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

# Heuristic 7: Unknown defect bucket size. The Bug B post-mortem
# named "unbinned-signal-loss" as a structural failure: defects we
# can't classify get forgotten instead of investigated. When the
# unknown bucket exceeds 50 entries, the report nudges the user to
# run a quarterly clustering pass via tools/cluster-unknown-defects.sh.
# 50 is the threshold below which a clustering pass usually has too
# little signal to reveal a category; above it, the cumulative
# evidence justifies the review cost.
if [[ -f "${DEFECT_PATTERNS_FILE}" ]]; then
  _unknown_count="$(jq -r '.unknown.count // 0' "${DEFECT_PATTERNS_FILE}" 2>/dev/null || echo 0)"
  [[ "${_unknown_count}" =~ ^[0-9]+$ ]] || _unknown_count=0
  if [[ "${_unknown_count}" -ge 50 ]]; then
    _intp_lines+=("**Unknown defect bucket has ${_unknown_count} entries.** Defects the auto-classifier could not categorize accumulate into the unknown bucket and are otherwise dropped from review. Run \`tools/cluster-unknown-defects.sh\` to surface candidate clusters (top tokens, bigrams, and path mentions) — the Bug B post-mortem traced part of its longevity to this bucket never being inspected. If clusters emerge, codify them as new categories in \`lib/classifier.sh\`.")
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
