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
# `--explain` (v1.30.0) prints a per-flag rationale: each known oh-my-claude
# conf flag with its current value, default, and one-line purpose. Closes
# the v1.29.0 product-lens P2-10 deferred item — `omc-config show` previously
# dumped a bare star-table without explaining what each flag does, so users
# wanting to disable e.g. `intent_broadening` had no in-CLI signal of what
# they would lose. The conf-example file IS the source of truth (422 lines)
# but most users never read it. This surface walks the omc-config flag
# manifest so explanations stay synced with the parser/conf-example trio.
SUMMARY_MODE=0
CLASSIFIER_MODE=0
EXPLAIN_MODE=0
# v1.36.x W5 F-025: --changed filter for explain mode prints ONLY flags
# whose current value differs from the documented default. Closes the
# design-lens grievance that --explain dumps 43 flags every call —
# users wanting "what's not default" had to scan the * marker.
CHANGED_ONLY=0
# v1.31.0 Wave 6 (design-lens F-027): accept BOTH --double-dash AND
# bare-positional argument forms so the skill grammar matches /ulw-time
# (which uses positional `current|last|week`) and /ulw-report
# (positional `last|week|month|all`). Pre-Wave-6 only --summary / -s
# / --classifier / -c / --explain / -e were accepted; users typing
# `/ulw-status summary` got "Unknown argument" with no recovery path.
# Both forms map to the same modes; --help mentions both.
for arg in "$@"; do
  case "${arg}" in
    --summary|-s|summary)
      SUMMARY_MODE=1
      ;;
    --classifier|-c|classifier)
      CLASSIFIER_MODE=1
      ;;
    --explain|-e|explain)
      EXPLAIN_MODE=1
      ;;
    --changed|--diff|changed|diff)
      # v1.36.x W5 F-025: only meaningful with --explain. Implies it.
      EXPLAIN_MODE=1
      CHANGED_ONLY=1
      ;;
    --help|-h|help)
      printf 'Usage: show-status.sh [summary | classifier | explain] [--changed]\n'
      printf '       show-status.sh [--summary | --classifier | --explain] [--changed]\n'
      printf '\n'
      printf '  (no flag)      Full diagnostic status (default).\n'
      printf '  summary, -s    Compact end-of-session recap.\n'
      printf '  classifier, -c Intent-classifier telemetry for this session\n'
      printf '                 plus cross-session misfire patterns.\n'
      printf '  explain, -e    Per-flag rationale: every known oh-my-claude\n'
      printf '                 conf flag with current value, default, and\n'
      printf '                 one-line purpose, grouped by cluster.\n'
      printf '  --changed      With explain: only show flags whose current\n'
      printf '                 value differs from the default.\n'
      exit 0
      ;;
    *)
      # v1.34.1+ (X-007): name the accepted forms inline so the user can
      # recover from a typo without consulting --help. Mirrors show-time.sh
      # and show-report.sh error shapes.
      printf 'show-status: unknown argument %q (expected: summary, classifier, explain, --changed, or no argument for full diagnostic).\n' "${arg}" >&2
      printf '             See --help for the full form list.\n' >&2
      exit 2
      ;;
  esac
done

# --- Explain mode: per-flag rationale walker ---
# Reads the omc-config flag manifest (the canonical name|type|default|cluster
# |description registry — see `omc-config.sh:emit_known_flags`) and prints
# a grouped explanation for every flag. Intentionally side-effect-free and
# session-independent: skipped before the latest-session lookup so even a
# pristine install (no session state yet) renders correctly.
if [[ "${EXPLAIN_MODE}" -eq 1 ]]; then
  # Co-locate with show-status.sh so the dev-tree and installed-tree
  # paths resolve correctly without an environment dependency on
  # ~/.claude/. SCRIPT_DIR is the directory of this script (set near
  # the top of the file).
  _ssd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  OMC_CONFIG_SH="${_ssd}/omc-config.sh"
  if [[ ! -f "${OMC_CONFIG_SH}" ]]; then
    printf 'omc-config.sh not found at %s — cannot render explain.\n' "${OMC_CONFIG_SH}" >&2
    exit 1
  fi

  # Load the flag manifest by sourcing omc-config.sh and calling its
  # emit_known_flags helper. The helper streams `name|type|default|cluster
  # |description` rows on stdout. Suppress any output from sourcing (the
  # file is a script with subcommand dispatch but `source` only defines
  # functions when called without args at the top of an interactive shell).
  # shellcheck source=/dev/null
  (
    # Subshell to avoid leaking omc-config's local helpers into the
    # outer scope of this script. `set --` clears positional parameters
    # before sourcing because omc-config.sh's bottom-line `main "$@"`
    # would otherwise see this script's argv (`--explain`) and exit 2
    # via the unknown-subcommand branch.
    set +e
    # pipefail + nounset must also be off so a grep miss in the conf
    # walk does not silently abort the loop (grep exits 1 on no match;
    # under -o pipefail the command substitution propagates that and
    # the assignment fails the calling context). Treat the explain
    # renderer as best-effort: partial output is better than no output.
    set +o pipefail
    set +u
    set --
    # Suppress both stdout AND stderr while sourcing — omc-config.sh's
    # bottom-line `main "$@"` runs with empty $@ → triggers the usage
    # print to stdout. We only need its function definitions, not its
    # main output.
    source "${OMC_CONFIG_SH}" >/dev/null 2>&1 || true
    if ! declare -F emit_known_flags >/dev/null 2>&1; then
      printf 'omc-config.sh did not export emit_known_flags — cannot render.\n' >&2
      exit 1
    fi

    printf '\n'
    # v1.31.0 Wave 5 (visual-craft F-1): unified box-rule card head.
    # v1.36.x W3 F-014: omc_box_rule_glyph honors OMC_PLAIN=1.
    _box="$(omc_box_rule_glyph 3)"
    printf '%s oh-my-claude flag rationale %s\n' "${_box}" "${_box}"
    printf '\n'
    printf 'Each line is: <flag>=<current> (default=<default>)\n'
    printf '             <one-line purpose>\n'
    printf '\n'
    printf 'Source: omc-config.sh emit_known_flags manifest. To change a\n'
    printf 'flag value, run /omc-config or edit ~/.claude/oh-my-claude.conf\n'
    printf 'directly. To inspect the full set including descriptions for\n'
    printf 'flags not yet in your conf, see ~/.claude/oh-my-claude.conf\n'
    printf '(the canonical reference) or oh-my-claude.conf.example in the\n'
    printf 'source repo.\n'
    printf '\n'

    # Group rows by cluster. Stable-sort by cluster (column 4 in the
    # manifest's pipe-delimited shape) so all flags of the same cluster
    # are contiguous; intra-cluster ordering preserves emit_known_flags's
    # display order. Without the sort, an interleaved manifest produces
    # duplicate cluster headers (── advisory ── ... ── gates ── ... ──
    # advisory ── again) — a real UX defect surfaced by design-lens X-005
    # in the v1.34.1 council. The aspirational pre-fix comment was
    # "Single-pass: stream rows, sort by cluster then name" but the
    # actual code only rendered headers on boundary changes — manifests
    # ordered by importance (the v1.34.x convention) drifted from the
    # cluster grouping the comment promised.
    last_cluster=""
    while IFS='|' read -r _name _type _default _cluster _description; do
      [[ -z "${_name}" ]] && continue
      [[ "${_name}" == "EOF" ]] && break

      # Resolve current value via the same precedence chain common.sh
      # uses: project conf (PWD/.claude/oh-my-claude.conf) → user conf
      # (~/.claude/oh-my-claude.conf) → default. Common.sh eagerly seeds
      # OMC_* variables with defaults at source-time, so a "shell env vs
      # default" distinction is not reliable from this script's vantage
      # point. The conf-file value is the actionable signal — that's
      # what the user actually configured. Env-var overrides still
      # produce a `*` marker because OMC_FOO != default at the conf-
      # check level. Direct grep avoids the read_conf_value 2-arg form
      # complication and works whether or not omc-config.sh's helpers
      # leaked into scope.
      _cur=""
      _proj_conf="${PWD}/.claude/oh-my-claude.conf"
      _user_conf="${HOME}/.claude/oh-my-claude.conf"
      for _conf in "${_proj_conf}" "${_user_conf}"; do
        [[ -f "${_conf}" ]] || continue
        # `|| true` neutralizes the pipeline's exit status: grep exits 1
        # on no-match, and depending on shell-flag inheritance into the
        # `$(...)` subshell, that 1 has historically aborted the
        # explain-render mid-loop. Best-effort posture documented above.
        _conf_val="$(grep -E "^${_name}=" "${_conf}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
        if [[ -n "${_conf_val}" ]]; then
          _cur="${_conf_val}"
          break
        fi
      done
      [[ -z "${_cur}" ]] && _cur="${_default}"

      _delta_marker=""
      _is_changed=0
      if [[ "${_cur}" != "${_default}" ]]; then
        _delta_marker=" *"
        _is_changed=1
      fi

      # v1.36.x W5 F-025: --changed filter skips flags at default.
      if [[ "${CHANGED_ONLY:-0}" -eq 1 ]] && [[ "${_is_changed}" -eq 0 ]]; then
        continue
      fi

      if [[ "${_cluster}" != "${last_cluster}" ]]; then
        [[ -n "${last_cluster}" ]] && printf '\n'
        printf '── %s ──\n' "${_cluster}"
        last_cluster="${_cluster}"
      fi

      printf '  %s=%s (default=%s)%s\n' \
        "${_name}" "${_cur}" "${_default}" "${_delta_marker}"
      if [[ -n "${_description}" ]]; then
        printf '      %s\n' "${_description}"
      fi
    done < <(emit_known_flags 2>/dev/null | sort -t'|' -k4,4 -s)

    printf '\n'
    if [[ "${CHANGED_ONLY:-0}" -eq 1 ]]; then
      if [[ -z "${last_cluster}" ]]; then
        printf 'No flags differ from defaults — your install is at the canonical Balanced profile.\n'
        printf 'Drop --changed to see the full flag list.\n'
      else
        printf 'Showing only flags whose value differs from the default. Run\n'
        printf '/ulw-status --explain (without --changed) for the full list.\n'
      fi
    else
      printf '* = value differs from default. Run /omc-config show to see the\n'
      printf '    raw conf file, or /omc-config to change values interactively.\n'
      printf 'Tip: pass --changed to filter to only the flags you have customized.\n'
    fi
  )
  exit 0
fi

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
contract_primary="$(read_state "done_contract_primary" 2>/dev/null || true)"
if [[ -z "${contract_primary}" ]]; then
  contract_primary="$(jq -r '.current_objective // "none"' "${state_file}" 2>/dev/null || echo "none")"
fi
contract_commit_mode="$(delivery_contract_commit_mode_label "$(read_state "done_contract_commit_mode" 2>/dev/null || true)")"
# v1.34.0 (Bug C): push-side intent renders alongside commit-side so a
# "commit X. don't push Y." prompt makes both halves auditable here.
contract_push_mode="$(delivery_contract_commit_mode_label "$(read_state "done_contract_push_mode" 2>/dev/null || true)")"
contract_prompt_surfaces="$(csv_humanize "$(read_state "done_contract_prompt_surfaces" 2>/dev/null || true)")"
contract_verify_required="$(csv_humanize "$(read_state "verification_contract_required" 2>/dev/null || true)")"
contract_touched_surfaces="$(delivery_contract_touched_surfaces_summary 2>/dev/null || printf 'none')"
contract_remaining_items="$(delivery_contract_remaining_items 2>/dev/null || true)"
contract_blocking_items="$(delivery_contract_blocking_items 2>/dev/null || true)"
delivery_commit_actions="$(read_state "commit_action_count" 2>/dev/null || true)"
delivery_publish_actions="$(read_state "publish_action_count" 2>/dev/null || true)"
delivery_commit_actions="${delivery_commit_actions:-0}"
delivery_publish_actions="${delivery_publish_actions:-0}"

# Delivery Contract v2 — inferred adjacent surfaces (v1.34.0).
inferred_contract_status="$(inferred_contract_summary 2>/dev/null || printf 'unknown')"
inferred_contract_blockers="$(inferred_contract_blocking_items 2>/dev/null || true)"

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
  exemplifying_scope_blocks="$(jq -r '.exemplifying_scope_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"
  wave_shape_blocks="$(jq -r '.wave_shape_blocks // "0"' "${state_file}" 2>/dev/null || echo "0")"

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

  _box="$(omc_box_rule_glyph 3)"
  printf '%s ULW Session Summary %s\n' "${_box}" "${_box}"
  printf 'Session:    %s · %s · domain=%s · intent=%s\n' "${latest_session}" "${age_human}" "${domain}" "${intent}"
  printf 'Work:       %s unique files · %s code edits · %s doc edits · %s dispatches\n' \
    "${unique_files}" "${code_edits}" "${doc_edits}" "${dispatches}"
  printf 'Verify:     %s\n' "${verify_status}"
  printf 'Contract:   commit=%s · prompt surfaces=%s\n' \
    "${contract_commit_mode}" "${contract_prompt_surfaces}"
  if [[ "${delivery_commit_actions}" != "0" || "${delivery_publish_actions}" != "0" ]]; then
    printf 'Actions:    commits=%s · publish=%s\n' "${delivery_commit_actions}" "${delivery_publish_actions}"
  fi
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
  [[ "${exemplifying_scope_blocks}" -ne 0 ]] && blocks_parts="${blocks_parts:+${blocks_parts} · }example-scope=${exemplifying_scope_blocks}"
  [[ "${wave_shape_blocks}" -ne 0 ]] && blocks_parts="${blocks_parts:+${blocks_parts} · }wave-shape=${wave_shape_blocks}"
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
  if [[ -n "${contract_remaining_items}" ]]; then
    printf 'Remaining:  %s\n' "$(printf '%s' "${contract_remaining_items}" | head -1)"
  else
    printf 'Remaining:  none\n'
  fi

  # Wave plan health (F-019): single-line summary when a Phase 8 plan is
  # active. Calls the dedicated status-line helper to keep formatting
  # consistent with the in-session resume hint.
  _wave_status_line="$("${HOME}/.claude/skills/autowork/scripts/record-finding-list.sh" status-line 2>/dev/null || true)"
  if [[ -n "${_wave_status_line}" ]] && [[ "${_wave_status_line}" != *"no plan yet"* ]]; then
    printf 'Wave plan:  %s\n' "${_wave_status_line#Findings: }"
  fi

  if is_time_tracking_enabled; then
    _time_log="${STATE_ROOT}/${latest_session}/timing.jsonl"
    if [[ -f "${_time_log}" ]]; then
      _time_agg="$(timing_aggregate "${_time_log}")"
      _time_oneline="$(timing_format_oneline "${_time_agg}")"
      if [[ -n "${_time_oneline}" ]]; then
        printf '%s\n' "${_time_oneline}"
      fi
    fi
  fi

  printf 'Outcome:    %s\n' "${outcome}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Classifier mode — inspect intent-classifier telemetry
# ---------------------------------------------------------------------------
if [[ "${CLASSIFIER_MODE}" -eq 1 ]]; then
  telemetry_file="${STATE_ROOT}/${latest_session}/classifier_telemetry.jsonl"

  _box="$(omc_box_rule_glyph 3)"
  printf '%s Classifier Telemetry (current session) %s\n' "${_box}" "${_box}"
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
    _box="$(omc_box_rule_glyph 3)"
    printf '\n%s Classifier Misfires (cross-session) %s\n' "${_box}" "${_box}"
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

_box="$(omc_box_rule_glyph 3)"
printf '%s ULW Session Status %s\n' "${_box}" "${_box}"
printf 'Session: %s\n\n' "${latest_session}"

_ellipsis="…"
case "${OMC_PLAIN:-}" in
  1|on|true|yes) _ellipsis="..." ;;
esac
jq -r --arg ellipsis "${_ellipsis}" '
  "Workflow mode:     \(.workflow_mode // "none")",
  "Task domain:       \(.task_domain // "unset")",
  "Task intent:       \(.task_intent // "unset")",
  "Project maturity:  \(.project_maturity // "unset")",
  "Objective:         \(.current_objective // "none" | if length > 240 then .[0:240] + $ellipsis else . end)",
  "",
  "--- Pause State ---",
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
  "Stop guard blocks: \( ((.stop_guard_blocks // "") | if . == "" then "0" else . end) )",
  "Dimension blocks:  \( ((.dimension_guard_blocks // "") | if . == "" then "0" else . end) )",
  "Session handoffs:  \( ((.session_handoff_blocks // "") | if . == "" then "0" else . end) )",
  "Discovered-scope:  \( ((.discovered_scope_blocks // "") | if . == "" then "0" else . end) )",
  "Example-scope:     \( ((.exemplifying_scope_blocks // "") | if . == "" then "0" else . end) )",
  "Wave-shape blocks: \( ((.wave_shape_blocks // "") | if . == "" then "0" else . end) )",
  "Serendipity fires: \( ((.serendipity_count // "") | if . == "" then "0" else . end) )\(if (.last_serendipity_fix // "") != "" then " (last: \(.last_serendipity_fix))" else "" end)",
  "Stall counter:     \( ((.stall_counter // "") | if . == "" then "0" else . end) ) (fires gate at default 12 reads/greps without an edit)",
  "",
  "--- Intent Guards ---",
  "Advisory guards:       \( ((.advisory_guard_blocks // "") | if . == "" then "0" else . end) )",
  "PreTool intent blocks: \( ((.pretool_intent_blocks // "") | if . == "" then "0" else . end) )",
  "",
  "--- Flags ---",
  "Has plan:          \(.has_plan // "false")",
  "Excellence gate:   \(if (.excellence_guard_triggered // "") == "1" then "triggered" else "not triggered" end)",
  "Guard exhausted:   \(if (.guard_exhausted // "") != "" then "YES (\(.guard_exhausted_detail // "unknown"))" else "no" end)",
  "",
  "--- Edit Counts ---",
  "Code files edited: \( ((.code_edit_count // "") | if . == "" then "0" else . end) )",
  "Doc files edited:  \( ((.doc_edit_count // "") | if . == "" then "0" else . end) )",
  "",
  (
    if (.last_compact_trigger // "") == ""
       and ((.compact_race_count // "0") | tonumber? // 0) == 0
       and (.just_compacted // "") != "1" then
      ""
    else
      "--- Compact Continuity ---\nLast compact trigger:      \(.last_compact_trigger // "never")\nLast compact request ts:   \(.last_compact_request_ts // "never")\nLast compact rehydrate ts: \(.last_compact_rehydrate_ts // "never")\nCompact race count:        \(.compact_race_count // "0")\nReview pending at compact: \(if (.review_pending_at_compact // "") == "1" then "YES" else "no" end)\nJust-compacted flag:       \(if (.just_compacted // "") == "1" then "set (age: \(.just_compacted_ts // "?"))" else "clear" end)"
    end
  )
' "${state_file}" | grep -v '^$' || true

printf '\n--- Delivery Contract ---\n'
printf 'Primary deliverable: %s\n' "${contract_primary}"
printf 'Commit intent:       %s\n' "${contract_commit_mode}"
printf 'Push intent:         %s\n' "${contract_push_mode}"
printf 'Prompt surfaces:     %s\n' "${contract_prompt_surfaces}"
printf 'Proof contract:      %s\n' "${contract_verify_required}"
printf 'Touched surfaces:    %s\n' "${contract_touched_surfaces}"
printf 'Recorded actions:    commits=%s · publish=%s\n' "${delivery_commit_actions}" "${delivery_publish_actions}"
printf 'Inferred (v2):       %s\n' "${inferred_contract_status}"
if [[ -n "${contract_blocking_items}" ]]; then
  printf 'Explicit blockers:   %s\n' "$(printf '%s' "${contract_blocking_items}" | head -1)"
fi
if [[ -n "${inferred_contract_blockers}" ]]; then
  printf 'Inferred blockers:\n'
  while IFS= read -r _inferred_item; do
    [[ -z "${_inferred_item}" ]] && continue
    printf '  - %s\n' "${_inferred_item}"
  done <<<"${inferred_contract_blockers}"
fi
if [[ -n "${contract_remaining_items}" ]]; then
  printf 'Remaining:\n'
  while IFS= read -r _contract_item; do
    [[ -z "${_contract_item}" ]] && continue
    printf '  - %s\n' "${_contract_item}"
  done <<<"${contract_remaining_items}"
else
  printf 'Remaining:           none\n'
fi

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
      # Linux GNU find -printf first; macOS BSD xargs+stat fallback. The
      # reverse order silently broke on Linux: xargs+stat -f dumped
      # filesystem info to stdout (because `-f` means --file-system on
      # GNU stat), then `||` ran the find branch and concatenated more
      # output. See blindspot-inventory.sh:616 for the full rationale.
      _mem_oldest_path="$(find "${_mem_dir}" -maxdepth 1 -type f -name '*.md' \
        -not -name 'MEMORY.md' -printf '%T@ %p\n' 2>/dev/null \
        || find "${_mem_dir}" -maxdepth 1 -type f -name '*.md' \
          -not -name 'MEMORY.md' -print0 2>/dev/null \
          | xargs -0 stat -f '%m %N' 2>/dev/null \
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

# v1.36.x W1 F-024 — Harness Health surface.
#
# Pre-1.36 the watchdog wrote a tombstone to ~/.cache/omc/watchdog-last-error
# when STATE_ROOT became unwritable, but nothing surfaced it — a user
# whose watchdog had been silently dead for days only discovered the
# breakage when an expected resume failed to fire. This section reads the
# tombstone (and the per-session corruption-recovery counter) and prints
# them WHEN they exist; silent on a clean install.
_harness_health_emitted=0
_watchdog_tomb="${HOME}/.cache/omc/watchdog-last-error"
if [[ -f "${_watchdog_tomb}" ]] && [[ -s "${_watchdog_tomb}" ]]; then
  if [[ "${_harness_health_emitted}" -eq 0 ]]; then
    printf '\n--- Harness Health ---\n'
    _harness_health_emitted=1
  fi
  # The tombstone format (resume-watchdog.sh:106-110) is two lines:
  #   ts=<epoch>
  #   reason=<message>
  # Read both defensively — corrupt or partial writes fall back to the
  # raw first 200 chars so the user still sees something useful.
  _wd_ts="$(grep -E '^ts=' "${_watchdog_tomb}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '[:space:]')"
  _wd_reason="$(grep -E '^reason=' "${_watchdog_tomb}" 2>/dev/null | head -1 | cut -d'=' -f2-)"
  if [[ -z "${_wd_reason}" ]]; then
    _wd_reason="$(head -c 200 "${_watchdog_tomb}" 2>/dev/null | tr -d '\n')"
  fi
  if [[ "${_wd_ts}" =~ ^[0-9]+$ ]]; then
    _wd_iso="$(date -r "${_wd_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || date -d "@${_wd_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || printf '%s' "${_wd_ts}")"
    printf 'Watchdog last error:       %s — %s\n' "${_wd_iso}" "${_wd_reason:-(no reason recorded)}"
  else
    printf 'Watchdog last error:       (tombstone present) — %s\n' "${_wd_reason:-(no reason recorded)}"
  fi
  printf '                           Tombstone: %s\n' "${_watchdog_tomb}"
  printf '                           Run /omc-config to inspect or repair the watchdog (resume_watchdog flag).\n'
fi

# Per-session state-recovery counter — surfaced only when non-zero so a
# clean session is silent. The counter is bumped by ensure_valid_state
# (lib/state-io.sh) when session_state.json corruption forces an archive
# + rebuild. A counter > 0 means the recovery actually fired during this
# session — worth highlighting since the silent-archive behavior is easy
# to miss otherwise.
_recovery_count="$(read_state "recovery_count" 2>/dev/null || true)"
if [[ "${_recovery_count}" =~ ^[0-9]+$ ]] && [[ "${_recovery_count}" -gt 0 ]]; then
  if [[ "${_harness_health_emitted}" -eq 0 ]]; then
    printf '\n--- Harness Health ---\n'
    _harness_health_emitted=1
  fi
  printf 'State recovery (this session): %s — corruption was archived + rebuilt %s time(s).\n' \
    "${_recovery_count}" "${_recovery_count}"
  printf '                           Inspect ~/.claude/quality-pack/state/<session>/.recovered_from_corrupt_archive\n'
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

# Exemplifying-scope checklist (example-marker prompts)
exemplifying_file="${STATE_ROOT}/${latest_session}/exemplifying_scope.json"
if [[ -f "${exemplifying_file}" ]]; then
  ex_total="$(jq -r '(.items // []) | length' "${exemplifying_file}" 2>/dev/null || echo 0)"
  ex_pending="$(jq -r '[.items[]? | select(.status == "pending")] | length' "${exemplifying_file}" 2>/dev/null || echo 0)"
  ex_shipped="$(jq -r '[.items[]? | select(.status == "shipped")] | length' "${exemplifying_file}" 2>/dev/null || echo 0)"
  ex_declined="$(jq -r '[.items[]? | select(.status == "declined")] | length' "${exemplifying_file}" 2>/dev/null || echo 0)"
  printf 'Exemplified scope:         %s total · %s pending · %s shipped · %s declined\n' \
    "${ex_total:-0}" "${ex_pending:-0}" "${ex_shipped:-0}" "${ex_declined:-0}"
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
  # v1.27.0 (F-023): show per-factor breakdown when available so the
  # user can see WHY the score is what it is. Format from
  # score_verification_confidence_factors:
  #   "test_match:40|framework:30|output_counts:20|clear_outcome:10|total:100"
  # Each factor's max contribution is annotated in parentheses.
  verify_factors="$(jq -r '.last_verify_factors // empty' "${state_file}" 2>/dev/null || true)"
  if [[ -n "${verify_factors}" ]]; then
    # Defensive parse: each segment must be `name:N` where N is a non-
    # negative integer. Malformed/legacy state (e.g., from a pre-v1.27.0
    # session whose key happens to share the name, or from a manual edit)
    # falls back to 0 instead of trying to do arithmetic on a non-number.
    f_test="${verify_factors#*test_match:}"; f_test="${f_test%%|*}"
    f_fwk="${verify_factors#*framework:}";    f_fwk="${f_fwk%%|*}"
    f_out="${verify_factors#*output_counts:}"; f_out="${f_out%%|*}"
    f_clr="${verify_factors#*clear_outcome:}"; f_clr="${f_clr%%|*}"
    [[ "${f_test}" =~ ^[0-9]+$ ]] || f_test=0
    [[ "${f_fwk}"  =~ ^[0-9]+$ ]] || f_fwk=0
    [[ "${f_out}"  =~ ^[0-9]+$ ]] || f_out=0
    [[ "${f_clr}"  =~ ^[0-9]+$ ]] || f_clr=0
    threshold="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
    printf 'Breakdown:  test-cmd-match=%s/40  framework-keyword=%s/30  output-counts=%s/20  clear-outcome=%s/10\n' \
      "${f_test}" "${f_fwk}" "${f_out}" "${f_clr}"
    if [[ "${verify_conf}" -lt "${threshold}" ]]; then
      printf 'Status:     BELOW threshold (need %s+)\n' "${threshold}"
      # Suggest the cheapest factor combination that would clear the
      # threshold. Pick the single largest missing factor when it covers
      # the gap; otherwise enumerate the missing factors so the user can
      # combine them.
      _need=$(( threshold - verify_conf ))
      _project_cmd="$(jq -r '.project_test_cmd // "<none detected>"' "${state_file}" 2>/dev/null || echo "<none>")"
      if [[ "${f_test}" -eq 0 ]] && [[ "${_need}" -le 40 ]]; then
        printf 'Hint:       run the project test command (detected: %s) to add +40\n' "${_project_cmd}"
      elif [[ "${f_fwk}" -eq 0 ]] && [[ "${_need}" -le 30 ]]; then
        printf 'Hint:       use a recognized framework command (pytest, jest, cargo test, etc.) to add +30\n'
      elif [[ "${f_out}" -eq 0 ]] && [[ "${_need}" -le 20 ]]; then
        printf 'Hint:       capture test-counts in the output (e.g., ensure stderr/stdout is not silenced) to add +20\n'
      else
        # Threshold gap exceeds the largest single missing factor — list
        # every zero factor with its potential contribution so the user
        # knows which to combine.
        _hints=""
        [[ "${f_test}" -eq 0 ]] && _hints="${_hints:+${_hints}; }run project test cmd \`${_project_cmd}\` (+40)"
        [[ "${f_fwk}"  -eq 0 ]] && _hints="${_hints:+${_hints}; }framework keyword (pytest/jest/cargo/etc., +30)"
        [[ "${f_out}"  -eq 0 ]] && _hints="${_hints:+${_hints}; }surface test-counts in output (+20)"
        [[ "${f_clr}"  -eq 0 ]] && _hints="${_hints:+${_hints}; }surface PASS/FAIL outcome (+10)"
        if [[ -n "${_hints}" ]]; then
          printf 'Hint:       combine — %s\n' "${_hints}"
        fi
      fi
    else
      printf 'Status:     PASS (>= %s threshold)\n' "${threshold}"
    fi
  else
    # MCP-path verification: confidence + method are recorded but the
    # per-factor breakdown is not (the MCP scorer has its own factor
    # model — base + UI-context bonus + output-bearing bonus — that is
    # not surfaced as state in v1.27.0). Make the silence explicit so
    # the user understands the panel isn't broken.
    if [[ "${verify_method}" == mcp_* ]]; then
      printf 'Breakdown:  (MCP-path verification — per-factor breakdown not yet recorded)\n'
    fi
  fi
fi

# v1.27.0 (F-026): canary verdict distribution for the active session.
# Surfaces drift-canary state alongside the verification confidence so
# the user can see at a glance how many turns this session emitted
# unverified verdicts (the silent-confab pattern).
#
# `grep -c PATTERN FILE` returns exit 1 on zero matches AND prints "0"
# to stdout. The `|| printf 0` fallback then concatenates a SECOND "0",
# producing the literal string "0\n0" — which corrupts the subsequent
# arithmetic ($(( "0\n0" + ... )) is a syntax error). Solution: drop
# the `|| printf 0` and let grep's "0" output stand. The default-zero
# expansion `${var:-0}` covers the case where the file is missing
# (caught by the outer `[[ -f ${canary_log} ]]` anyway).
canary_log="${STATE_ROOT}/${latest_session}/canary.jsonl"
if [[ -f "${canary_log}" ]] && [[ -s "${canary_log}" ]]; then
  # `grep -c` exits 1 on zero matches; under `set -e` the bare assignment
  # would propagate the failure. `|| true` lets stdout's "0" land in the
  # variable. Do NOT use `|| printf 0` — that concatenates a second "0"
  # because grep ALSO prints "0" on no match.
  c_clean="$(grep -c '"verdict":"clean"' "${canary_log}" 2>/dev/null || true)"
  c_covered="$(grep -c '"verdict":"covered"' "${canary_log}" 2>/dev/null || true)"
  c_low="$(grep -c '"verdict":"low_coverage"' "${canary_log}" 2>/dev/null || true)"
  c_unver="$(grep -c '"verdict":"unverified"' "${canary_log}" 2>/dev/null || true)"
  c_clean="${c_clean:-0}"
  c_covered="${c_covered:-0}"
  c_low="${c_low:-0}"
  c_unver="${c_unver:-0}"
  c_total=$(( c_clean + c_covered + c_low + c_unver ))
  if [[ "${c_total}" -gt 0 ]]; then
    printf '\n--- Model-drift canary ---\n'
    printf 'Verdicts:   total=%s · clean=%s · covered=%s · low_coverage=%s · unverified=%s\n' \
      "${c_total}" "${c_clean}" "${c_covered}" "${c_low}" "${c_unver}"
    # v1.31.0 Wave 6 (design-lens F-030): one-line legend for the
    # verdict shapes. Pre-Wave-6 a first-time user saw `unverified=1`
    # with no explanation and no recovery-path. The legend explicitly
    # names what each verdict means so users can interpret the row
    # without leaving the terminal for docs.
    printf 'Legend:     clean=no claims · covered=claims+tools · low_coverage=fewer tools than claims · unverified=claims with no tools (silent-confab pattern)\n'
    if [[ "${c_unver}" -gt 0 ]]; then
      drift_emitted="$(jq -r '.drift_warning_emitted // empty' "${state_file}" 2>/dev/null || true)"
      if [[ "${drift_emitted}" == "1" ]]; then
        printf 'Alert:      drift warning EMITTED this session\n'
      else
        printf 'Alert:      not yet emitted (threshold: 2 unverified events OR 1 with claim_count>=4)\n'
      fi
    fi
  fi
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

# Time distribution — one-line composition for the active session.
# Surfaces "where the time went" alongside the existing session-age line
# so the user sees workflow shape without having to invoke /ulw-time.
if is_time_tracking_enabled; then
  _time_log="${STATE_ROOT}/${latest_session}/timing.jsonl"
  if [[ -f "${_time_log}" ]]; then
    _time_agg="$(timing_aggregate "${_time_log}")"
    _time_oneline="$(timing_format_oneline "${_time_agg}")"
    if [[ -n "${_time_oneline}" ]]; then
      printf '%s\n' "${_time_oneline}"
    fi
  fi
fi

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
      [.[] | "\(.key): \(.value.count) occurrences"] | join("\n")
    else empty end
  ' "${defect_file}" 2>/dev/null || true)"
  if [[ -n "${defect_output}" ]]; then
    # v1.34.1+ (X-010): drop the truncated mid-word example field. The
    # category counts are signal; 60-char prompt fragments cut at random
    # offsets are noise (and a privacy-leak risk — fragments can include
    # user prompts from prior sessions on different repos). Full examples
    # remain accessible via /ulw-report or the JSON file.
    printf '\n--- Defect Patterns (cross-session) ---\n'
    printf '%s\n' "${defect_output}"
    printf '(Run /ulw-report week for examples and counts in context.)\n'
  fi
fi

# Show edited files if any
edits_file="${STATE_ROOT}/${latest_session}/edited_files.log"
if [[ -f "${edits_file}" ]]; then
  printf '\n--- Edited Files ---\n'
  sort -u "${edits_file}" | tail -20
fi
