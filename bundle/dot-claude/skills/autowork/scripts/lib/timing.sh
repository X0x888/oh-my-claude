# shellcheck shell=bash
# timing.sh — Per-tool / per-subagent timing capture and aggregation.
#
# Sourced by common.sh AFTER lib/state-io.sh (needs session_file). Provides
# append-only capture (start + end rows) and a read-time aggregator. The
# hot path (PreToolUse / PostToolUse / UserPromptSubmit) is lock-free:
# each hook appends one sub-PIPE_BUF JSONL row via O_APPEND, which is
# kernel-serialized on POSIX. Read-modify-write happens only at the
# aggregation surface (Stop hook, /ulw-time, status, report), where the
# cost of jq parsing is amortized over an entire session.
#
# Capture model:
#   timing.jsonl rows
#     {"kind":"prompt_start", "ts":N, "prompt_seq":I}      -- UserPromptSubmit
#     {"kind":"prompt_end",   "ts":N, "prompt_seq":I, "duration_s":D}  -- Stop
#     {"kind":"start", "ts":N, "tool":T, "prompt_seq":I, "tool_use_id":?, "subagent":?}
#                                                          -- PreToolUse
#     {"kind":"end",   "ts":N, "tool":T, "prompt_seq":I, "tool_use_id":?}
#                                                          -- PostToolUse
#
# Pairing rules (in aggregator):
#   - tool_use_id present in BOTH start and end → exact match
#   - tool_use_id absent → match by tool_name within same prompt_seq:
#       Agent uses LIFO (last-pending wins; agents rarely overlap in
#       practice, and the most-recently-dispatched is most likely to
#       complete first when nesting occurs)
#       all other tools use FIFO (parallel calls of the same tool
#       complete in roughly start order; per-tool aggregate sums are
#       the goal, so per-call swaps cancel out)
#
# Time precision:
#   - now_epoch returns whole seconds. Sub-second tool calls round to 0
#     and contribute nothing to per-tool sums. This is acceptable: short
#     calls don't dominate any bucket. ms precision would require
#     non-portable date formatting (gdate / date +%s%N) and is deferred.
#
# Privacy / noise floor:
#   - is_time_tracking_enabled fast-path: when off, every helper returns
#     immediately (no disk I/O, no jq spawn). Defines the kill-switch.
#   - timing.jsonl is per-session under STATE_ROOT and inherits the
#     OMC_STATE_TTL_DAYS sweep.
#   - Cross-session aggregate at ~/.claude/quality-pack/timing.jsonl is
#     swept by OMC_TIME_TRACKING_XS_RETAIN_DAYS (default 30 days).

# --- Path helpers ---

timing_log_path() {
  printf '%s' "$(session_file 'timing.jsonl')"
}

timing_xs_log_path() {
  printf '%s' "${HOME}/.claude/quality-pack/timing.jsonl"
}

# --- Capture helpers (called from hook scripts) ---

# timing_append_start <tool> [tool_use_id] [subagent] [prompt_seq]
timing_append_start() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local tool="${1:-}"
  [[ -z "${tool}" ]] && return 0
  local tool_use_id="${2:-}"
  local subagent="${3:-}"
  local prompt_seq="${4:-0}"
  [[ "${prompt_seq}" =~ ^[0-9]+$ ]] || prompt_seq=0

  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg tool "${tool}" \
    --arg tool_use_id "${tool_use_id}" \
    --arg subagent "${subagent}" \
    --argjson prompt_seq "${prompt_seq}" \
    '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$prompt_seq}
     + (if $tool_use_id != "" then {tool_use_id:$tool_use_id} else {} end)
     + (if $subagent != "" then {subagent:$subagent} else {} end)' 2>/dev/null)"
  [[ -z "${row}" ]] && return 0

  ensure_session_dir 2>/dev/null || return 0
  printf '%s\n' "${row}" >> "$(timing_log_path)" 2>/dev/null || true
}

# timing_append_end <tool> [tool_use_id] [prompt_seq]
timing_append_end() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local tool="${1:-}"
  [[ -z "${tool}" ]] && return 0
  local tool_use_id="${2:-}"
  local prompt_seq="${3:-0}"
  [[ "${prompt_seq}" =~ ^[0-9]+$ ]] || prompt_seq=0

  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg tool "${tool}" \
    --arg tool_use_id "${tool_use_id}" \
    --argjson prompt_seq "${prompt_seq}" \
    '{kind:"end",ts:$ts,tool:$tool,prompt_seq:$prompt_seq}
     + (if $tool_use_id != "" then {tool_use_id:$tool_use_id} else {} end)' 2>/dev/null)"
  [[ -z "${row}" ]] && return 0

  ensure_session_dir 2>/dev/null || return 0
  printf '%s\n' "${row}" >> "$(timing_log_path)" 2>/dev/null || true
}

# timing_append_prompt_start <prompt_seq>
timing_append_prompt_start() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local prompt_seq="${1:-0}"
  [[ "${prompt_seq}" =~ ^[0-9]+$ ]] || prompt_seq=0

  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --argjson prompt_seq "${prompt_seq}" \
    '{kind:"prompt_start",ts:$ts,prompt_seq:$prompt_seq}' 2>/dev/null)"
  [[ -z "${row}" ]] && return 0

  ensure_session_dir 2>/dev/null || return 0
  printf '%s\n' "${row}" >> "$(timing_log_path)" 2>/dev/null || true
}

# timing_append_prompt_end <prompt_seq> <duration_s>
timing_append_prompt_end() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local prompt_seq="${1:-0}"
  local duration_s="${2:-0}"
  [[ "${prompt_seq}" =~ ^[0-9]+$ ]] || prompt_seq=0
  [[ "${duration_s}" =~ ^[0-9]+$ ]] || duration_s=0

  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --argjson prompt_seq "${prompt_seq}" \
    --argjson duration_s "${duration_s}" \
    '{kind:"prompt_end",ts:$ts,prompt_seq:$prompt_seq,duration_s:$duration_s}' 2>/dev/null)"
  [[ -z "${row}" ]] && return 0

  ensure_session_dir 2>/dev/null || return 0
  printf '%s\n' "${row}" >> "$(timing_log_path)" 2>/dev/null || true
}

# --- Aggregator ---

# timing_aggregate [log_path] [prompt_seq_filter]
#   Reads a timing.jsonl, pairs start/end rows, returns aggregated JSON.
#   Emits {} when the file is missing or empty.
#
#   Optional <prompt_seq_filter>: if non-zero, only rows with matching
#   prompt_seq are included (used by /ulw-time last-prompt mode to slice
#   one prompt's worth of activity out of a multi-prompt session).
#
#   Output schema (top-level keys):
#     walltime_s        — sum of prompt_end.duration_s
#     agent_total_s     — sum of paired Agent durations
#     agent_breakdown   — {subagent_name: total_s}
#     agent_calls       — {subagent_name: call_count}
#     tool_total_s      — sum of paired non-Agent durations
#     tool_breakdown    — {tool_name: total_s}
#     tool_calls        — {tool_name: call_count}
#     idle_model_s      — walltime_s - (agent_total_s + tool_total_s)
#                         (clamped to 0)
#     prompt_count      — number of prompts with both start and end
#     active_pending    — start rows still awaiting end (orphans-in-flight)
#     orphan_end_count  — end rows with no matching start
timing_aggregate() {
  local log="${1:-}"
  if [[ -z "${log}" ]]; then
    log="$(timing_log_path)"
  fi
  local prompt_filter="${2:-0}"
  [[ "${prompt_filter}" =~ ^[0-9]+$ ]] || prompt_filter=0

  if [[ ! -f "${log}" ]] || [[ ! -s "${log}" ]]; then
    printf '%s\n' '{}'
    return 0
  fi

  jq -sc --argjson pfilter "${prompt_filter}" '
    def find_match($pending; $r):
      [$pending | to_entries[] | select(
        if (($r.tool_use_id // "") != "") and ((.value.tool_use_id // "") != "") then
          .value.tool_use_id == $r.tool_use_id
        else
          .value.tool == $r.tool
          and ((.value.prompt_seq // 0) == ($r.prompt_seq // 0))
        end
      )] |
      if length == 0 then null
      elif $r.tool == "Agent" then .[-1]
      else .[0]
      end;

    # Optional prompt_seq slice: only retain rows tagged with the requested
    # prompt_seq when pfilter > 0. Untagged rows (legacy / pre-router
    # captures) are dropped from a slice but kept in whole-session aggregation.
    [.[] | select(
      ($pfilter == 0) or ((.prompt_seq // 0) == $pfilter)
    )] as $rows |

    reduce $rows[] as $r (
      { pending: [], agent: {}, tool: {}, agent_n: {}, tool_n: {}, prompts: [], orphan_end: 0 };
      if $r.kind == "prompt_start" then
        .prompts += [{ ps: ($r.prompt_seq // 0), start: $r.ts, end: null, dur: 0 }]
      elif $r.kind == "prompt_end" then
        .prompts |= map(
          if .ps == ($r.prompt_seq // 0) and .end == null then
            . + { end: $r.ts, dur: ($r.duration_s // ($r.ts - .start)) }
          else . end
        )
      elif $r.kind == "start" then
        .pending += [$r]
      elif $r.kind == "end" then
        find_match(.pending; $r) as $m |
        if $m == null then
          .orphan_end += 1
        else
          ($r.ts - $m.value.ts) as $dur |
          (if $dur < 0 then 0 else $dur end) as $dur |
          (.pending |= (.[:$m.key] + .[$m.key+1:])) |
          if $r.tool == "Agent" then
            (($m.value.subagent // "general-purpose")) as $sub |
            .agent[$sub] = ((.agent[$sub] // 0) + $dur) |
            .agent_n[$sub] = ((.agent_n[$sub] // 0) + 1)
          else
            .tool[$r.tool] = ((.tool[$r.tool] // 0) + $dur) |
            .tool_n[$r.tool] = ((.tool_n[$r.tool] // 0) + 1)
          end
        end
      else .
      end
    ) as $st |
    {
      walltime_s:       ([$st.prompts[] | select(.end != null) | .dur] | add // 0),
      agent_total_s:    ([$st.agent[]] | add // 0),
      agent_breakdown:  $st.agent,
      agent_calls:      $st.agent_n,
      tool_total_s:     ([$st.tool[]] | add // 0),
      tool_breakdown:   $st.tool,
      tool_calls:       $st.tool_n,
      prompt_count:     ([$st.prompts[] | select(.end != null)] | length),
      active_pending:   ($st.pending | length),
      orphan_end_count: $st.orphan_end
    }
    | . + {
        idle_model_s: ((.walltime_s - .agent_total_s - .tool_total_s) | if . < 0 then 0 else . end)
      }
  ' < "${log}" 2>/dev/null || printf '%s\n' '{}'
}

# --- Format helpers ---

# Format integer seconds as a compact human string ("0s", "12s", "3m 04s",
# "1h 23m"). Used by every surface (Stop epilogue, /ulw-time, status, report).
timing_fmt_secs() {
  local s="${1:-0}"
  [[ "${s}" =~ ^[0-9]+$ ]] || s=0
  if (( s < 60 )); then
    printf '%ds' "${s}"
  elif (( s < 3600 )); then
    printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# timing_format_oneline <agg_json>
#   One-line distribution string suitable for Stop additionalContext.
#   Returns empty (suppressing emission) when walltime_s < 5 (noise floor).
timing_format_oneline() {
  local agg="${1:-}"
  [[ -z "${agg}" ]] && return 0

  local walltime
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  walltime="${walltime:-0}"
  [[ "${walltime}" =~ ^[0-9]+$ ]] || walltime=0

  if (( walltime < 5 )); then
    return 0
  fi

  local agent_total tool_total idle_model
  agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg}" 2>/dev/null)"
  tool_total="$(jq -r '.tool_total_s // 0' <<<"${agg}" 2>/dev/null)"
  idle_model="$(jq -r '.idle_model_s // 0' <<<"${agg}" 2>/dev/null)"
  agent_total="${agent_total:-0}"
  tool_total="${tool_total:-0}"
  idle_model="${idle_model:-0}"

  local out
  out="Time: $(timing_fmt_secs "${walltime}")"

  if (( agent_total > 0 )); then
    local top_agents
    top_agents="$(jq -r '
      (.agent_breakdown // {})
      | to_entries
      | sort_by(-.value)
      | .[0:3]
      | map("\(.key) \(.value)")
      | .[]?
    ' <<<"${agg}" 2>/dev/null)"

    local agent_total_count
    agent_total_count="$(jq -r '(.agent_breakdown // {}) | length' <<<"${agg}" 2>/dev/null)"
    agent_total_count="${agent_total_count:-0}"

    local breakdown=""
    local shown=0
    while IFS=' ' read -r name secs; do
      [[ -z "${name}" ]] && continue
      [[ -n "${breakdown}" ]] && breakdown+=", "
      breakdown+="${name} $(timing_fmt_secs "${secs}")"
      shown=$((shown + 1))
    done <<<"${top_agents}"

    if (( agent_total_count > shown )); then
      breakdown+=", +$((agent_total_count - shown))"
    fi

    out+=" · agents $(timing_fmt_secs "${agent_total}")"
    [[ -n "${breakdown}" ]] && out+=" (${breakdown})"
  fi

  if (( tool_total > 0 )); then
    local top_tools
    top_tools="$(jq -r '
      (.tool_breakdown // {})
      | to_entries
      | sort_by(-.value)
      | .[0:3]
      | map("\(.key) \(.value)")
      | .[]?
    ' <<<"${agg}" 2>/dev/null)"

    local tool_total_count
    tool_total_count="$(jq -r '(.tool_breakdown // {}) | length' <<<"${agg}" 2>/dev/null)"
    tool_total_count="${tool_total_count:-0}"

    local breakdown=""
    local shown=0
    while IFS=' ' read -r name secs; do
      [[ -z "${name}" ]] && continue
      [[ -n "${breakdown}" ]] && breakdown+=", "
      breakdown+="${name} $(timing_fmt_secs "${secs}")"
      shown=$((shown + 1))
    done <<<"${top_tools}"

    if (( tool_total_count > shown )); then
      breakdown+=", +$((tool_total_count - shown))"
    fi

    out+=" · tools $(timing_fmt_secs "${tool_total}")"
    [[ -n "${breakdown}" ]] && out+=" (${breakdown})"
  fi

  if (( idle_model > 0 )); then
    out+=" · idle/model $(timing_fmt_secs "${idle_model}")"
  fi

  printf '%s' "${out}"
}

# timing_format_full <agg_json> [title]
#   Multi-line ASCII bar chart. Used by /ulw-time and /ulw-status.
#   Returns empty when walltime_s == 0 (no data to render).
timing_format_full() {
  local agg="${1:-}"
  local title="${2:-Time breakdown}"
  [[ -z "${agg}" ]] && return 0

  local walltime
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  walltime="${walltime:-0}"
  [[ "${walltime}" =~ ^[0-9]+$ ]] || walltime=0
  if (( walltime == 0 )); then
    return 0
  fi

  local agent_total tool_total idle_model prompt_count active_pending orphan_end
  agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg}" 2>/dev/null)"
  tool_total="$(jq -r '.tool_total_s // 0' <<<"${agg}" 2>/dev/null)"
  idle_model="$(jq -r '.idle_model_s // 0' <<<"${agg}" 2>/dev/null)"
  prompt_count="$(jq -r '.prompt_count // 0' <<<"${agg}" 2>/dev/null)"
  active_pending="$(jq -r '.active_pending // 0' <<<"${agg}" 2>/dev/null)"
  orphan_end="$(jq -r '.orphan_end_count // 0' <<<"${agg}" 2>/dev/null)"

  printf '%s — %s total (%d prompt%s)\n' \
    "${title}" \
    "$(timing_fmt_secs "${walltime}")" \
    "${prompt_count:-0}" \
    "$( [[ "${prompt_count:-0}" -eq 1 ]] && printf '' || printf 's' )"
  printf '\n'

  _timing_render_bucket() {
    local label="$1" total="$2" walltime="$3" subkey="$4" agg="$5" countkey="${6:-}"
    [[ "${total}" =~ ^[0-9]+$ ]] || return 0
    (( total == 0 )) && return 0

    local pct=0
    if (( walltime > 0 )); then
      pct=$(( total * 100 / walltime ))
    fi
    local bars
    bars="$(_timing_bar "${pct}" 20)"
    printf '  %-13s %-20s %s (%d%%)\n' \
      "${label}" "${bars}" "$(timing_fmt_secs "${total}")" "${pct}"

    if [[ -n "${subkey}" ]]; then
      local rows
      rows="$(jq -r --arg sk "${subkey}" --arg ck "${countkey}" '
        (.[$sk] // {}) as $totals |
        (if $ck == "" then {} else (.[$ck] // {}) end) as $counts |
        ($totals | to_entries | sort_by(-.value))
        | .[]
        | "\(.value)\t\(($counts[.key] // 0))\t\(.key)"
      ' <<<"${agg}" 2>/dev/null)"

      while IFS=$'\t' read -r secs calls name; do
        [[ -z "${name}" ]] && continue
        [[ "${secs}" =~ ^[0-9]+$ ]] || continue
        # Render even when secs == 0 if calls > 0 — sub-second tools
        # (Read/Grep/Edit) routinely round to 0s under whole-second
        # precision, but their call counts are still useful signal.
        if (( secs == 0 )) && [[ -z "${calls}" || "${calls}" == "0" ]]; then
          continue
        fi
        local sub_pct=0
        if (( walltime > 0 )); then
          sub_pct=$(( secs * 100 / walltime ))
        fi
        local sub_bars
        sub_bars="$(_timing_bar "${sub_pct}" 14)"
        local count_suffix=""
        if [[ -n "${calls}" ]] && [[ "${calls}" =~ ^[0-9]+$ ]] && (( calls > 0 )); then
          count_suffix=" (${calls})"
        fi
        printf '    %-22s %-14s %s%s\n' \
          "${name}" "${sub_bars}" "$(timing_fmt_secs "${secs}")" "${count_suffix}"
      done <<<"${rows}"
    fi
  }

  _timing_render_bucket "agents"     "${agent_total:-0}"  "${walltime}" "agent_breakdown" "${agg}" "agent_calls"
  _timing_render_bucket "tools"      "${tool_total:-0}"   "${walltime}" "tool_breakdown"  "${agg}" "tool_calls"
  _timing_render_bucket "idle/model" "${idle_model:-0}"   "${walltime}" ""                "${agg}" ""

  if (( idle_model > 0 )); then
    printf '    %s\n' "(residual: model thinking, permission waits, hook overhead)"
  fi

  if (( active_pending > 0 )) || (( orphan_end > 0 )); then
    printf '\n'
    printf '  Note: %d unfinished start%s, %d orphan end%s (likely killed mid-call).\n' \
      "${active_pending:-0}" "$( [[ "${active_pending:-0}" -eq 1 ]] && printf '' || printf 's' )" \
      "${orphan_end:-0}" "$( [[ "${orphan_end:-0}" -eq 1 ]] && printf '' || printf 's' )"
  fi
}

# Render an ASCII bar of given percentage and width. Uses block U+2588.
_timing_bar() {
  local pct="${1:-0}" width="${2:-20}"
  [[ "${pct}" =~ ^[0-9]+$ ]] || pct=0
  [[ "${width}" =~ ^[0-9]+$ ]] || width=20
  (( pct > 100 )) && pct=100
  local n=$(( pct * width / 100 ))
  (( pct > 0 && n == 0 )) && n=1
  local out=""
  local i
  for (( i = 0; i < n; i++ )); do
    out+="█"
  done
  printf '%s' "${out}"
}

# --- Cross-session aggregate ---

# timing_record_session_summary <agg_json>
#   Append a finalized session summary to the cross-session timing log.
#   Called from stop-time-summary.sh after a successful aggregate run.
#   Capped via append_limited_state (10000 rows).
timing_record_session_summary() {
  is_time_tracking_enabled || return 0
  local agg="${1:-}"
  [[ -z "${agg}" ]] && return 0

  local walltime
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  walltime="${walltime:-0}"
  [[ "${walltime}" =~ ^[0-9]+$ ]] || walltime=0
  (( walltime < 5 )) && return 0

  local sid="${SESSION_ID:-}"
  [[ -z "${sid}" ]] && return 0

  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg session "${sid}" \
    --arg project_key "$(_omc_project_key 2>/dev/null || _omc_project_id)" \
    --argjson agg "${agg}" \
    '{ts:$ts,session:$session,project_key:$project_key} + $agg' 2>/dev/null)"
  [[ -z "${row}" ]] && return 0

  local target
  target="$(timing_xs_log_path)"
  mkdir -p "$(dirname "${target}")" 2>/dev/null || true

  # Dedup-on-write: every Stop hook fires this with a fresh whole-session
  # aggregate. A multi-prompt session would otherwise accrue N monotonically
  # growing rows whose walltime_s sums incorrectly in timing_xs_aggregate.
  # Keep only the latest aggregate per session_id by rewriting the file
  # without rows whose .session matches us, then appending. Cost is O(file
  # size) per Stop, but the file is capped at 10000 rows and shrinks to
  # one-row-per-session under this rule, so steady-state is small.
  if [[ -f "${target}" ]] && [[ -s "${target}" ]]; then
    local tmp
    tmp="$(mktemp "${target}.XXXXXX" 2>/dev/null)" || tmp=""
    if [[ -n "${tmp}" ]]; then
      if jq -c --arg sid "${sid}" 'select((.session // "") != $sid)' \
          "${target}" > "${tmp}" 2>/dev/null; then
        printf '%s\n' "${row}" >> "${tmp}"
        mv "${tmp}" "${target}" 2>/dev/null || rm -f "${tmp}"
      else
        rm -f "${tmp}"
        printf '%s\n' "${row}" >> "${target}" 2>/dev/null || true
      fi
    else
      printf '%s\n' "${row}" >> "${target}" 2>/dev/null || true
    fi
  else
    printf '%s\n' "${row}" >> "${target}" 2>/dev/null || true
  fi

  _cap_cross_session_jsonl "${target}" 10000 8000 2>/dev/null || true
}

# --- Helpers used by show-time / report ---

# timing_xs_aggregate <cutoff_epoch>
#   Reads cross-session log; returns aggregated rollup over rows with ts >= cutoff.
#   Output: {sessions:N, walltime_s:T, agent_breakdown:{...}, tool_breakdown:{...}}
timing_xs_aggregate() {
  local cutoff="${1:-0}"
  [[ "${cutoff}" =~ ^[0-9]+$ ]] || cutoff=0

  local log
  log="$(timing_xs_log_path)"
  if [[ ! -f "${log}" ]] || [[ ! -s "${log}" ]]; then
    printf '%s\n' '{}'
    return 0
  fi

  jq -sc --argjson cutoff "${cutoff}" '
    [.[] | select((.ts // 0) >= $cutoff)] as $rows |
    {
      sessions:        ($rows | length),
      walltime_s:      ([$rows[] | (.walltime_s // 0)] | add // 0),
      agent_total_s:   ([$rows[] | (.agent_total_s // 0)] | add // 0),
      tool_total_s:    ([$rows[] | (.tool_total_s // 0)] | add // 0),
      idle_model_s:    ([$rows[] | (.idle_model_s // 0)] | add // 0),
      agent_breakdown: (
        [$rows[] | (.agent_breakdown // {}) | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | add)})
        | from_entries
      ),
      tool_breakdown: (
        [$rows[] | (.tool_breakdown // {}) | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | add)})
        | from_entries
      ),
      prompts:        ([$rows[] | (.prompt_count // 0)] | add // 0)
    }
  ' < "${log}" 2>/dev/null || printf '%s\n' '{}'
}

# timing_next_prompt_seq
#   Atomic-ish increment of the per-session prompt counter. Stored in
#   session_state.json under key 'prompt_seq'. Called once per
#   UserPromptSubmit. Returns the new value.
timing_next_prompt_seq() {
  is_time_tracking_enabled || { printf '0'; return 0; }
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }

  local current
  current="$(read_state "prompt_seq" 2>/dev/null || true)"
  current="${current:-0}"
  [[ "${current}" =~ ^[0-9]+$ ]] || current=0
  local next=$(( current + 1 ))

  with_state_lock write_state "prompt_seq" "${next}" 2>/dev/null || true
  printf '%s' "${next}"
}

# timing_current_prompt_seq
#   Read-only access to the latest assigned prompt_seq. Used by hooks that
#   tag start/end rows so they pair within the right epoch.
timing_current_prompt_seq() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local current
  current="$(read_state "prompt_seq" 2>/dev/null || true)"
  current="${current:-0}"
  [[ "${current}" =~ ^[0-9]+$ ]] || current=0
  printf '%s' "${current}"
}

# timing_latest_finalized_prompt_seq <log_path>
#   Returns the prompt_seq of the most recent prompt that has both a
#   prompt_start and prompt_end row in the timing log. Used by /ulw-time
#   last-prompt mode to slice the most recently completed prompt out of a
#   multi-prompt session. Returns 0 when no finalized prompt exists.
timing_latest_finalized_prompt_seq() {
  local log="${1:-$(timing_log_path)}"
  if [[ ! -f "${log}" ]] || [[ ! -s "${log}" ]]; then
    printf '0'
    return 0
  fi

  local seq
  seq="$(jq -sr '
    [.[] | select(.kind == "prompt_end") | (.prompt_seq // 0)]
    | if length == 0 then 0 else max end
  ' < "${log}" 2>/dev/null || printf '0')"
  seq="${seq:-0}"
  [[ "${seq}" =~ ^[0-9]+$ ]] || seq=0
  printf '%s' "${seq}"
}
