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
#     {"kind":"directive_emitted", "ts":N, "prompt_seq":I, "name":S, "chars":N}
#                                                          -- prompt-intent-router
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

# Display-cell width helper. Returns the number of CHARACTERS (not
# bytes) in the input, suitable for terminal-column alignment.
# Pre-Wave-3 sites used `${#var}` which counts bytes — a 3-cell
# UTF-8 sparkline `▂█▃` reads as 9 on macOS bash 3.2 and 3 on
# Linux bash 5+, breaking column alignment in `_timing_render_bucket`
# (22-char truncation budget) and the per-prompt sparkline assertion.
#
# Implementation: `printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m`
# — POSIX-portable on BSD coreutils (macOS) and GNU coreutils (Linux),
# locale-aware, ~50µs per call. Trim trailing whitespace because BSD
# wc emits leading whitespace on numeric output (e.g., "       3\n").
#
# v1.31.0 Wave 3 (visual-craft F-5 + metis Item 6).
timing_display_width() {
  local s="${1:-}"
  [[ -z "${s}" ]] && { printf 0; return 0; }
  local n
  n="$(printf '%s' "${s}" | LC_ALL=en_US.UTF-8 wc -m 2>/dev/null || printf 0)"
  # Strip ALL whitespace (BSD wc pads with leading spaces; GNU wc emits
  # plain digits). Falls back to byte count on any wc failure (exotic
  # systems missing wc -m support).
  n="${n//[[:space:]]/}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n="${#s}"
  printf '%s' "${n}"
}

# --- Path helpers ---

timing_log_path() {
  printf '%s' "$(session_file 'timing.jsonl')"
}

timing_xs_log_path() {
  printf '%s' "${HOME}/.claude/quality-pack/timing.jsonl"
}

# --- Capture helpers (called from hook scripts) ---
#
# v1.29.0 perf: replaces `jq -nc` per row with pure-bash JSON emission.
# Timing append fires on every PreToolUse + PostToolUse hook (~50 calls
# per heavy turn) — each `jq -nc` fork costs ~3ms on bash 3.2 macOS, so
# the baseline timing tax was ~300ms of pure overhead per turn. Pure-
# bash emission with parameter-expansion escaping drops this to <0.1ms
# per row. Trade-off: the timing fields are trusted enums (tool name,
# UUID-shaped tool_use_id, agent name) so escaping only `\` and `"` is
# sufficient; the aggregator (`jq -c` over the file) silently skips
# unparseable rows so a malformed edge case is graceful, not catastrophic.

# JSON-escape <input> in place into the bash variable named by <out_var>.
# Pure parameter-expansion + `printf -v` (no subshell, no fork). This is
# the load-bearing primitive that lets the timing append helpers
# replace `jq -nc` without paying the same fork cost via `$(...)`
# capture. Bash 3.2 safe.
_timing_json_escape() {
  local _s="$1"
  _s="${_s//\\/\\\\}"
  _s="${_s//\"/\\\"}"
  printf -v "$2" '%s' "${_s}"
}

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

  # v1.29.0 perf: pure-bash JSON emission (was: `jq -nc` fork per call).
  # Timing append fires on every PreToolUse + PostToolUse — at ~50 calls
  # per heavy turn × ~3ms/jq-fork = ~300ms/turn baseline tax. Pure bash
  # parameter-expansion drops it to <0.1ms/call. The fields are trusted
  # enums (tool name, UUID-like tool_use_id, agent name) so escaping
  # only `\` and `"` is sufficient for valid JSON; jq's aggregator
  # silently skips unparseable rows so a malformed edge case is graceful.
  # _timing_json_escape uses `printf -v` (no subshell) so the 30× win
  # is real wallclock, not just fork-count.
  local tool_esc tu_esc sa_esc ts
  _timing_json_escape "${tool}" tool_esc
  ts="$(now_epoch)"
  local row='{"kind":"start","ts":'"${ts}"',"tool":"'"${tool_esc}"'","prompt_seq":'"${prompt_seq}"
  if [[ -n "${tool_use_id}" ]]; then
    _timing_json_escape "${tool_use_id}" tu_esc
    row+=',"tool_use_id":"'"${tu_esc}"'"'
  fi
  if [[ -n "${subagent}" ]]; then
    _timing_json_escape "${subagent}" sa_esc
    row+=',"subagent":"'"${sa_esc}"'"'
  fi
  row+='}'

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

  local tool_esc tu_esc ts
  _timing_json_escape "${tool}" tool_esc
  ts="$(now_epoch)"
  local row='{"kind":"end","ts":'"${ts}"',"tool":"'"${tool_esc}"'","prompt_seq":'"${prompt_seq}"
  if [[ -n "${tool_use_id}" ]]; then
    _timing_json_escape "${tool_use_id}" tu_esc
    row+=',"tool_use_id":"'"${tu_esc}"'"'
  fi
  row+='}'

  ensure_session_dir 2>/dev/null || return 0
  printf '%s\n' "${row}" >> "$(timing_log_path)" 2>/dev/null || true
}

# timing_append_prompt_start <prompt_seq>
timing_append_prompt_start() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local prompt_seq="${1:-0}"
  [[ "${prompt_seq}" =~ ^[0-9]+$ ]] || prompt_seq=0

  local ts
  ts="$(now_epoch)"
  local row='{"kind":"prompt_start","ts":'"${ts}"',"prompt_seq":'"${prompt_seq}"'}'

  ensure_session_dir 2>/dev/null || return 0
  printf '%s\n' "${row}" >> "$(timing_log_path)" 2>/dev/null || true
}

# timing_append_directive <name> <chars> [prompt_seq]
#   Append a per-directive emission row to timing.jsonl. Used by the
#   prompt-intent-router to record per-directive size so future
#   /ulw-report and offline analyses can attribute the prompt's
#   additionalContext tax by category (intent classification, bias
#   defense, archetype priors, intent broadening, divergent framing,
#   etc.).
#
#   The size field is `chars` (locale-aware codepoint count via bash
#   `${#var}`), NOT raw bytes. Naming reflects this honestly so consumers
#   don't double-count multi-byte content. Characters correlate with
#   token cost better than raw bytes anyway — Anthropic's tokenizer
#   operates on codepoints, so 1 em-dash is 1 token regardless of UTF-8
#   byte width.
#
#   Token counting is deliberately deferred to the analysis layer because
#   chars/4 heuristics still misattribute by 15-30% on directive-shaped
#   text — the actual tokenizer (Anthropic count_tokens / public BPE)
#   is the right surface for tokenization.
timing_append_directive() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local name="${1:-}"
  local chars="${2:-0}"
  local prompt_seq="${3:-0}"
  [[ -z "${name}" ]] && return 0
  [[ "${chars}" =~ ^[0-9]+$ ]] || return 0
  [[ "${prompt_seq}" =~ ^[0-9]+$ ]] || prompt_seq=0

  local name_esc ts
  _timing_json_escape "${name}" name_esc
  ts="$(now_epoch)"
  local row='{"kind":"directive_emitted","ts":'"${ts}"',"prompt_seq":'"${prompt_seq}"',"name":"'"${name_esc}"'","chars":'"${chars}"'}'

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

  local ts
  ts="$(now_epoch)"
  local row='{"kind":"prompt_end","ts":'"${ts}"',"prompt_seq":'"${prompt_seq}"',"duration_s":'"${duration_s}"'}'

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
#     directive_total_chars — sum of directive_emitted.chars
#     directive_breakdown   — {directive_name: total_chars}
#     directive_counts      — {directive_name: fire_count}
#     directive_count       — total directive_emitted rows
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

    (reduce $rows[] as $r (
      { pending: [], agent: {}, tool: {}, agent_n: {}, tool_n: {}, dir_chars: {}, dir_n: {}, prompts: [], orphan_end: 0 };
      if $r.kind == "prompt_start" then
        .prompts += [{ ps: ($r.prompt_seq // 0), start: $r.ts, end: null, dur: 0 }]
      elif $r.kind == "prompt_end" then
        .prompts |= map(
          if .ps == ($r.prompt_seq // 0) and .end == null then
            . + { end: $r.ts, dur: ($r.duration_s // ($r.ts - .start)) }
          else . end
        )
      elif $r.kind == "directive_emitted" then
        (($r.name // "") | tostring) as $name |
        (($r.chars // 0) | tonumber? // 0) as $chars |
        if $name == "" or $chars <= 0 then
          .
        else
          .dir_chars[$name] = ((.dir_chars[$name] // 0) + $chars) |
          .dir_n[$name] = ((.dir_n[$name] // 0) + 1)
        end
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
    )) as $st |
    {
      walltime_s:       ([$st.prompts[] | select(.end != null) | .dur] | add // 0),
      agent_total_s:    ([$st.agent[]] | add // 0),
      agent_breakdown:  $st.agent,
      agent_calls:      $st.agent_n,
      tool_total_s:     ([$st.tool[]] | add // 0),
      tool_breakdown:   $st.tool,
      tool_calls:       $st.tool_n,
      directive_total_chars: ([$st.dir_chars[]] | add // 0),
      directive_breakdown: $st.dir_chars,
      directive_counts: $st.dir_n,
      directive_count: ([$st.dir_n[]] | add // 0),
      prompt_count:     ([$st.prompts[] | select(.end != null)] | length),
      prompts_seq:      [$st.prompts[] | select(.end != null) | {ps:.ps, dur:.dur}],
      active_pending:   ($st.pending | length),
      orphan_end_count: $st.orphan_end
    }
    | . + {
        idle_model_s: ((.walltime_s - .agent_total_s - .tool_total_s) | if . < 0 then 0 else . end),
        # v1.34.1+ (data-lens D-002 / design-lens X-002):
        # When parallel agents/tools complete in less wall-time than their
        # serial work-time would suggest (i.e., agent + tool > walltime),
        # surface the parallelism overhead as a positive quantity. The
        # `agents X% · tools Y% · idle Z%` bar in show-time.sh / show-status.sh
        # otherwise reads as broken (X+Y+Z > 100) when callers naively
        # divide work-time by walltime — exposing this field lets the
        # renderers either disclose the overlap explicitly OR re-normalize.
        # Always non-negative; 0 when work fits inside walltime.
        concurrent_overhead_s: ((.agent_total_s + .tool_total_s - .walltime_s) | if . < 0 then 0 else . end)
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

  local agent_total tool_total idle_model directive_total_chars directive_count
  agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg}" 2>/dev/null)"
  tool_total="$(jq -r '.tool_total_s // 0' <<<"${agg}" 2>/dev/null)"
  idle_model="$(jq -r '.idle_model_s // 0' <<<"${agg}" 2>/dev/null)"
  directive_total_chars="$(jq -r '.directive_total_chars // 0' <<<"${agg}" 2>/dev/null)"
  directive_count="$(jq -r '.directive_count // 0' <<<"${agg}" 2>/dev/null)"
  agent_total="${agent_total:-0}"
  tool_total="${tool_total:-0}"
  idle_model="${idle_model:-0}"
  directive_total_chars="${directive_total_chars:-0}"
  directive_count="${directive_count:-0}"
  [[ "${directive_total_chars}" =~ ^[0-9]+$ ]] || directive_total_chars=0
  [[ "${directive_count}" =~ ^[0-9]+$ ]] || directive_count=0

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

  if (( directive_count > 0 )); then
    out+=" · directive surface ${directive_total_chars} chars (${directive_count} fire"
    if (( directive_count == 1 )); then
      out+=")"
    else
      out+="s)"
    fi
  fi

  printf '%s' "${out}"
}

# timing_generate_insight <agg_json> [scope]
#   At-most-one-line observation about the aggregate. Shown at the bottom
#   of the polished epilogue. Priority order — only the FIRST matching rule
#   fires, so the user sees the most load-bearing signal exactly once:
#
#     1. Anomaly  — orphan/active_pending > 0 (calls killed mid-flight)
#     2. Dominance — top agent or tool >= 60% of walltime
#     3. Idle-heavy — idle/model >= 60% on a turn >= 30s (reassurance)
#     4. Tool churn — total tool calls >= 30 (parallelization hint)
#     5. Diversity — distinct subagents >= 4 (fun fact)
#     6. Reassurance — substantive turn (>=60s) with everything paired
#
#   <scope> defaults to "turn" — used by Stop hook and per-session views.
#   Pass "window" for cross-session rollup so wording reads correctly
#   ("across this window" instead of "this turn"). Anomaly/idle insights
#   only fire on per-session aggregates because orphan_end_count and
#   active_pending aren't carried into the cross-session row.
#
#   Returns empty (no insight) when no rule fires. Empty output causes the
#   caller to omit the insight line entirely rather than print a placeholder.
timing_generate_insight() {
  local agg="${1:-}"
  local scope="${2:-turn}"
  [[ -z "${agg}" ]] && return 0

  local span_word
  case "${scope}" in
    window) span_word="window" ;;
    *)      span_word="turn"   ;;
  esac

  local walltime agent_total tool_total idle_model orphan active_pending overhead
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg}" 2>/dev/null)"
  tool_total="$(jq -r '.tool_total_s // 0' <<<"${agg}" 2>/dev/null)"
  idle_model="$(jq -r '.idle_model_s // 0' <<<"${agg}" 2>/dev/null)"
  orphan="$(jq -r '.orphan_end_count // 0' <<<"${agg}" 2>/dev/null)"
  active_pending="$(jq -r '.active_pending // 0' <<<"${agg}" 2>/dev/null)"
  overhead="$(jq -r '.concurrent_overhead_s // 0' <<<"${agg}" 2>/dev/null)"

  walltime="${walltime:-0}"
  agent_total="${agent_total:-0}"
  tool_total="${tool_total:-0}"
  idle_model="${idle_model:-0}"
  orphan="${orphan:-0}"
  active_pending="${active_pending:-0}"
  overhead="${overhead:-0}"

  [[ "${walltime}" =~ ^[0-9]+$ ]] || walltime=0
  [[ "${agent_total}" =~ ^[0-9]+$ ]] || agent_total=0
  [[ "${tool_total}" =~ ^[0-9]+$ ]] || tool_total=0
  [[ "${idle_model}" =~ ^[0-9]+$ ]] || idle_model=0
  [[ "${orphan}" =~ ^[0-9]+$ ]] || orphan=0
  [[ "${active_pending}" =~ ^[0-9]+$ ]] || active_pending=0
  [[ "${overhead}" =~ ^[0-9]+$ ]] || overhead=0

  (( walltime < 1 )) && return 0

  # v1.34.1+ (D-002 follow-up): same denominator pattern as
  # timing_format_full so the insight line's percentages stay
  # consistent with the top bar / per-bucket rendering. Under
  # parallelism (overhead > 0), divide by work-time instead of
  # walltime; otherwise the insight could claim "X carried 133%".
  local insight_denom="${walltime}"
  if (( overhead > 0 )); then
    insight_denom=$(( agent_total + tool_total + idle_model ))
    (( insight_denom == 0 )) && insight_denom="${walltime}"
  fi

  # 1. Anomaly — distinguish two genuinely different signals:
  #   * orphan_end_count > 0 → an end row arrived with no matching start
  #     in the same prompt_seq. Almost always means the call was killed
  #     between PreToolUse and PostToolUse (rate limit, signal, OOM).
  #   * active_pending > 0  → a start row never got an end. Could mean
  #     killed (same as above), but could also mean the call is genuinely
  #     still in-flight when the Stop hook fires between two PreTool /
  #     PostTool pairs. Don't claim "killed" for in-flight calls — it
  #     misleads users mid-session.
  # Surface both signals with separate wording when both are present.
  if (( orphan > 0 )) && (( active_pending > 0 )); then
    printf 'Heads up: %d tool call%s killed mid-flight, %d still in-flight. Aggregates above may underestimate.' \
      "${orphan}" "$( (( orphan == 1 )) && printf '' || printf 's' )" \
      "${active_pending}"
    return 0
  elif (( orphan > 0 )); then
    if (( orphan == 1 )); then
      printf 'Heads up: 1 tool call killed mid-flight (likely rate-limited or interrupted). Aggregates above may underestimate.'
    else
      printf 'Heads up: %d tool calls killed mid-flight (likely rate-limited or interrupted). Aggregates above may underestimate.' "${orphan}"
    fi
    return 0
  elif (( active_pending > 0 )); then
    if (( active_pending == 1 )); then
      printf 'Heads up: 1 tool call still in-flight at Stop time — its duration will fold into the next epilogue.'
    else
      printf 'Heads up: %d tool calls still in-flight at Stop time — their durations will fold into the next epilogue.' "${active_pending}"
    fi
    return 0
  fi

  # 2a. Single-agent dominance — common when an `excellence-reviewer` or
  # `quality-reviewer` deep run carries a wave-completion turn. Reassures
  # the user that the time was spent in a known specialist, not lost.
  if (( agent_total > 0 )); then
    local row
    row="$(jq -r '
      (.agent_breakdown // {})
      | to_entries
      | sort_by(-.value)
      | first
      | "\(.value)\t\(.key)"
    ' <<<"${agg}" 2>/dev/null)"
    local secs="" name=""
    IFS=$'\t' read -r secs name <<<"${row}"
    [[ "${secs}" =~ ^[0-9]+$ ]] || secs=0
    if (( secs > 0 )); then
      local pct=$(( secs * 100 / insight_denom ))
      if (( pct >= 60 )); then
        printf '%s carried %d%% of this %s (%s) — typical for a deep specialist run.' \
          "${name}" "${pct}" "${span_word}" "$(timing_fmt_secs "${secs}")"
        return 0
      fi
    fi
  fi

  # 2b. Single-tool dominance — flag when one tool ate the budget. Useful
  # for spotting a Bash-heavy turn worth parallelizing or a runaway test
  # loop.
  if (( tool_total > 0 )); then
    local trow
    trow="$(jq -r '
      (.tool_breakdown // {})
      | to_entries
      | sort_by(-.value)
      | first
      | "\(.value)\t\(.key)"
    ' <<<"${agg}" 2>/dev/null)"
    local tsecs="" tname=""
    IFS=$'\t' read -r tsecs tname <<<"${trow}"
    [[ "${tsecs}" =~ ^[0-9]+$ ]] || tsecs=0
    if (( tsecs > 0 )); then
      local tpct=$(( tsecs * 100 / insight_denom ))
      if (( tpct >= 60 )); then
        printf '%s dominated this %s at %d%% (%s) — consider whether parallelizable next time.' \
          "${tname}" "${span_word}" "${tpct}" "$(timing_fmt_secs "${tsecs}")"
        return 0
      fi
    fi
  fi

  # 3. Idle-heavy on a long turn. Specifically reassures: "thinking, not
  # stuck". Triggers only on turns >= 30s so a quick clarification doesn't
  # produce a hollow reassurance.
  if (( walltime >= 30 )); then
    local idle_pct=$(( idle_model * 100 / insight_denom ))
    if (( idle_pct >= 60 )); then
      printf 'Most time was model thinking (%d%% idle/model) — depth, not stalling.' "${idle_pct}"
      return 0
    fi
  fi

  # 4. Tool churn — many discrete tool calls suggests a read-heavy
  # exploration turn. Hint at parallelizing without nagging.
  local total_tool_calls
  total_tool_calls="$(jq -r '(.tool_calls // {}) | [.[]] | add // 0' <<<"${agg}" 2>/dev/null)"
  total_tool_calls="${total_tool_calls:-0}"
  [[ "${total_tool_calls}" =~ ^[0-9]+$ ]] || total_tool_calls=0
  if (( total_tool_calls >= 30 )); then
    printf 'Heavy tool %s — %d total calls. Batching reads/greps in parallel can shave wallclock next time.' \
      "${span_word}" "${total_tool_calls}"
    return 0
  fi

  # 5. Diversity — many distinct subagents engaged in one turn. Fun fact;
  # signals a multi-specialist wave-completion run.
  local distinct_agents
  distinct_agents="$(jq -r '(.agent_breakdown // {}) | length' <<<"${agg}" 2>/dev/null)"
  distinct_agents="${distinct_agents:-0}"
  [[ "${distinct_agents}" =~ ^[0-9]+$ ]] || distinct_agents=0
  if (( distinct_agents >= 4 )); then
    printf 'Diverse %s — %d distinct subagents engaged.' "${span_word}" "${distinct_agents}"
    return 0
  fi

  # 6. Substantive clean run. Last-resort positive signal so users on a
  # long, well-behaved turn don't get a silent epilogue.
  if (( walltime >= 60 )); then
    printf 'Clean run — every call paired correctly, no orphans.'
    return 0
  fi

  return 0
}

# timing_format_full <agg_json> [title]
#   Polished multi-line epilogue: title, stacked-segment top-line bar,
#   per-bucket detail rows (agents / tools / idle), residual note when
#   idle is non-trivial, anomaly note when calls were killed mid-flight,
#   and a single insight line picked by timing_generate_insight.
#
#   Used by both the Stop hook (always-on epilogue at end of every turn
#   above the 5s noise floor — applied by the caller) and /ulw-time. Same
#   render across both surfaces so users build muscle memory for the layout.
#
#   Returns empty when walltime_s == 0 AND no orphans / in-flight calls
#   exist. When walltime_s == 0 but orphans/active > 0 (session killed
#   before any prompt finalized), renders a single-line orphan message
#   so manual /ulw-time invocations still surface the in-flight signal.
timing_format_full() {
  local agg="${1:-}"
  local title="${2:-Time breakdown}"
  [[ -z "${agg}" ]] && return 0

  local walltime
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  walltime="${walltime:-0}"
  [[ "${walltime}" =~ ^[0-9]+$ ]] || walltime=0
  if (( walltime == 0 )); then
    # Orphan-only fall-through: surface the anomaly so a session killed
    # before any prompt finalized still produces output on manual
    # /ulw-time. The Stop hook's 5s floor independently suppresses this
    # case automatically.
    local _orphan _active
    _orphan="$(jq -r '.orphan_end_count // 0' <<<"${agg}" 2>/dev/null)"
    _active="$(jq -r '.active_pending // 0' <<<"${agg}" 2>/dev/null)"
    _orphan="${_orphan:-0}"; [[ "${_orphan}" =~ ^[0-9]+$ ]] || _orphan=0
    _active="${_active:-0}"; [[ "${_active}" =~ ^[0-9]+$ ]] || _active=0
    if (( _orphan > 0 )) || (( _active > 0 )); then
      printf '─── %s ─── no finalized prompts yet\n' "${title}"
      printf '  %d unfinished start%s, %d orphan end%s — likely killed mid-flight or still in-flight.\n' \
        "${_active}" "$( (( _active == 1 )) && printf '' || printf 's' )" \
        "${_orphan}" "$( (( _orphan == 1 )) && printf '' || printf 's' )"
    fi
    return 0
  fi

  local agent_total tool_total idle_model prompt_count active_pending orphan_end overhead
  agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg}" 2>/dev/null)"
  tool_total="$(jq -r '.tool_total_s // 0' <<<"${agg}" 2>/dev/null)"
  idle_model="$(jq -r '.idle_model_s // 0' <<<"${agg}" 2>/dev/null)"
  prompt_count="$(jq -r '.prompt_count // 0' <<<"${agg}" 2>/dev/null)"
  active_pending="$(jq -r '.active_pending // 0' <<<"${agg}" 2>/dev/null)"
  orphan_end="$(jq -r '.orphan_end_count // 0' <<<"${agg}" 2>/dev/null)"
  overhead="$(jq -r '.concurrent_overhead_s // 0' <<<"${agg}" 2>/dev/null)"

  agent_total="${agent_total:-0}"
  tool_total="${tool_total:-0}"
  idle_model="${idle_model:-0}"
  prompt_count="${prompt_count:-0}"
  active_pending="${active_pending:-0}"
  orphan_end="${orphan_end:-0}"
  overhead="${overhead:-0}"
  [[ "${overhead}" =~ ^[0-9]+$ ]] || overhead=0

  # Header — boxed-rule title puts the epilogue visually distinct from
  # surrounding text. The leading "─── " is intentional; gives the eye
  # a fixed anchor when scanning a long Claude Code transcript.
  printf '─── %s ─── %s · %d prompt%s\n' \
    "${title}" \
    "$(timing_fmt_secs "${walltime}")" \
    "${prompt_count}" \
    "$( (( prompt_count == 1 )) && printf '' || printf 's' )"

  # Stacked top-line bar — three segment chars give three bands at-a-glance:
  #   █ agents · ▒ tools · ░ idle/model.
  # Percentages on the right echo the legend so colour-blind users / no-Unicode
  # terminals still get the proportions even if the segment glyphs collapse.
  #
  # v1.34.1+ (D-002 / X-002): when concurrent_overhead_s > 0, parallel work
  # outran walltime — re-normalize the bar against agent+tool+idle so the
  # three buckets always partition 100%, then disclose the overlap on the
  # next line. Without this, the bar can read "agents 32% · tools 58% ·
  # idle 27% = 117%" which looks broken.
  # Compute the correct denominator for percentages. Under parallelism
  # (overhead > 0), agent + tool can exceed walltime, so use the work-
  # time sum (agent + tool + idle) which is always >= walltime. Under
  # serial work, that sum equals walltime, so the formula collapses to
  # the original. Used for BOTH the top bar AND the per-bucket rows
  # (passed in as the "walltime" arg of _timing_render_bucket so the
  # bucket-level percentage stays consistent with the top bar).
  local pct_denom="${walltime}"
  if (( walltime > 0 )) && (( overhead > 0 )); then
    pct_denom=$(( agent_total + tool_total + idle_model ))
    (( pct_denom == 0 )) && pct_denom=1
  fi
  local pct_a=0 pct_t=0 pct_i=0
  if (( pct_denom > 0 )); then
    pct_a=$(( agent_total * 100 / pct_denom ))
    pct_t=$(( tool_total * 100 / pct_denom ))
    pct_i=$(( idle_model * 100 / pct_denom ))
  fi
  local stacked_bar
  stacked_bar="$(_timing_stacked_bar "${pct_a}" "${pct_t}" "${pct_i}" 30)"
  printf '  %s  agents %d%% · tools %d%% · idle %d%%\n' \
    "${stacked_bar}" "${pct_a}" "${pct_t}" "${pct_i}"
  if (( overhead > 0 )); then
    printf '  parallelism saved ~%s of serial work-time\n' \
      "$(timing_fmt_secs "${overhead}")"
  fi

  # Per-prompt sparkline — one cell per prompt, height encodes that
  # prompt's walltime relative to the heaviest in the session. Surfaces
  # exactly what the per-bucket bars cannot: where the heavy turns
  # landed inside a multi-prompt session. Hidden on single-prompt views
  # because there's nothing to compare against.
  if (( prompt_count > 1 )); then
    local spark
    spark="$(_timing_sparkline "${agg}")"
    if [[ -n "${spark}" ]]; then
      printf '  prompts: %s  (one cell per prompt, height ∝ walltime)\n' "${spark}"
    fi
  fi
  printf '\n'

  # Use pct_denom (work-time when parallelism, walltime otherwise) so
  # per-bucket percentages stay consistent with the top bar. Pre-fix
  # the per-bucket rows under parallelism showed e.g. "1m 20s (133%)"
  # while the top bar (correctly) showed "agents 72%" — broken-looking
  # math the user could see.
  _timing_render_bucket "agents"     "${agent_total}"  "${pct_denom}" "agent_breakdown" "${agg}" "agent_calls"
  _timing_render_bucket "tools"      "${tool_total}"   "${pct_denom}" "tool_breakdown"  "${agg}" "tool_calls"
  _timing_render_bucket "idle/model" "${idle_model}"   "${pct_denom}" ""                "${agg}" ""

  if (( idle_model > 0 )); then
    printf '    %s\n' "(residual: model thinking, permission waits, hook overhead)"
  fi

  if (( active_pending > 0 )) || (( orphan_end > 0 )); then
    printf '\n'
    printf '  Note: %d unfinished start%s, %d orphan end%s (likely killed mid-call).\n' \
      "${active_pending}" "$( (( active_pending == 1 )) && printf '' || printf 's' )" \
      "${orphan_end}" "$( (( orphan_end == 1 )) && printf '' || printf 's' )"
  fi

  local insight
  insight="$(timing_generate_insight "${agg}")"
  if [[ -n "${insight}" ]]; then
    printf '\n  %s\n' "${insight}"
  fi
}

# Render one bucket row plus its sub-rows. Module-level (not nested in
# timing_format_full) so future surfaces — cross-session rollup, status
# command, /ulw-report — can reuse the same row layout. Sub-second tools
# (Read/Grep/Edit) routinely round to 0s under whole-second precision;
# we still render rows when call_count > 0 because the count itself is
# useful signal even when the time bar collapses.
_timing_render_bucket() {
  local label="$1" total="$2" walltime="$3" subkey="$4" agg="$5" countkey="${6:-}"
  [[ "${total}" =~ ^[0-9]+$ ]] || return 0

  # Honor the docstring contract: render the row when total==0 if and
  # only if the bucket has non-zero call counts. Sub-second tools
  # (Read/Grep/Edit) routinely round to 0s, but their call counts are
  # useful signal — skipping the whole row hides exploration-heavy
  # turns from the epilogue.
  if (( total == 0 )); then
    if [[ -z "${countkey}" ]]; then
      return 0
    fi
    local total_calls
    total_calls="$(jq -r --arg ck "${countkey}" \
      '(.[$ck] // {}) | [.[]] | add // 0' <<<"${agg}" 2>/dev/null)"
    total_calls="${total_calls:-0}"
    [[ "${total_calls}" =~ ^[0-9]+$ ]] || total_calls=0
    (( total_calls == 0 )) && return 0
  fi

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
      # Names over 22 chars push the bar/secs/count columns rightward and
      # break vertical alignment with the parent row. Real subagent names
      # like `excellence-reviewer` (19) fit fine; long custom subagent
      # types or hyphenated MCP tool names (`mcp__playwright__browser_*`)
      # would otherwise overflow. Truncate with U+2026 so the original
      # name remains identifiable while the columns stay locked.
      local display_name="${name}"
      # v1.31.0 Wave 3 (visual-craft F-5 + metis Item 6): use display-cell
      # width, not byte count. ${#name} would count bytes — a multi-byte
      # name like `mcp__测试tool` would over-truncate (10 chars but 14
      # bytes). timing_display_width returns the column-cell count via
      # `wc -m` which is locale-aware and POSIX-portable.
      local _name_w
      _name_w="$(timing_display_width "${name}")"
      if (( _name_w > 22 )); then
        display_name="${name:0:21}…"
      fi
      printf '    %-22s %-14s %s%s\n' \
        "${display_name}" "${sub_bars}" "$(timing_fmt_secs "${secs}")" "${count_suffix}"
    done <<<"${rows}"
  fi
}

# Stacked horizontal bar with up to three segments rendered with three
# distinct fill chars: █ (full block, agents), ▒ (medium shade, tools),
# ░ (light shade, idle/model). The three chars are visually separable
# even on monochrome terminals, so the bar reads correctly without
# colour. Width default 30 cells; segments < 1% but > 0 still get one
# cell so a tiny non-zero bucket stays visible. Trims the highest
# segment when rounding overshoots width; pads remainder with spaces.
_timing_stacked_bar() {
  local pct_a="${1:-0}" pct_b="${2:-0}" pct_c="${3:-0}" width="${4:-30}"
  [[ "${pct_a}" =~ ^[0-9]+$ ]] || pct_a=0
  [[ "${pct_b}" =~ ^[0-9]+$ ]] || pct_b=0
  [[ "${pct_c}" =~ ^[0-9]+$ ]] || pct_c=0
  [[ "${width}" =~ ^[0-9]+$ ]] || width=30

  local n_a=$(( pct_a * width / 100 ))
  local n_b=$(( pct_b * width / 100 ))
  local n_c=$(( pct_c * width / 100 ))
  (( pct_a > 0 && n_a == 0 )) && n_a=1
  (( pct_b > 0 && n_b == 0 )) && n_b=1
  (( pct_c > 0 && n_c == 0 )) && n_c=1

  local total=$(( n_a + n_b + n_c ))
  while (( total > width )); do
    if (( n_a >= n_b && n_a >= n_c )); then n_a=$(( n_a - 1 ))
    elif (( n_b >= n_c )); then n_b=$(( n_b - 1 ))
    else n_c=$(( n_c - 1 ))
    fi
    total=$(( n_a + n_b + n_c ))
  done

  local out=""
  local i
  for (( i = 0; i < n_a; i++ )); do out+="█"; done
  for (( i = 0; i < n_b; i++ )); do out+="▒"; done
  for (( i = 0; i < n_c; i++ )); do out+="░"; done
  for (( i = total; i < width; i++ )); do out+=" "; done
  printf '%s' "${out}"
}

# Render a per-prompt sparkline from a JSONL list of {ps, dur} pairs.
# Each prompt becomes one cell; height encodes the prompt's walltime
# normalized to the heaviest prompt in the session. Eight discrete
# levels via U+2581..U+2588 (block elements). Skipped silently when
# there are fewer than 2 prompts (single-prompt session has nothing
# to compare). Output is a single line — no leading/trailing spaces.
#
# v1.31.0 Wave 3 (visual-craft F-5 + metis Item 6 portability fix):
# Display-width is measured via timing_display_width — `wc -m` with
# LC_ALL=en_US.UTF-8 — so a 3-cell `▁▂▃` sparkline reads as 3 chars
# on bash 5+ Linux + bash 3.2 macOS uniformly. Pre-Wave-3 used
# `${#var}` byte-count which returned 9 on macOS (3 chars × 3 bytes
# each in UTF-8) and 3 on Linux, breaking T37's char-cell assertion.
_timing_sparkline() {
  local agg="${1:-}"
  [[ -z "${agg}" ]] && return 0

  local rows
  rows="$(jq -r '
    (.prompts_seq // []) as $ps |
    if ($ps | length) < 2 then empty
    else
      ($ps | map(.dur) | max) as $mx |
      if $mx == 0 or $mx == null then empty
      else
        $ps[] | "\(.dur)\t\($mx)"
      end
    end
  ' <<<"${agg}" 2>/dev/null)"

  [[ -z "${rows}" ]] && return 0

  # Eight ascending block heights — U+2581 (▁) through U+2588 (█).
  local levels=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
  local out=""
  while IFS=$'\t' read -r dur mx; do
    [[ "${dur}" =~ ^[0-9]+$ ]] || continue
    [[ "${mx}" =~ ^[0-9]+$ ]] || continue
    (( mx == 0 )) && continue
    local idx
    if (( dur == 0 )); then
      idx=0
    else
      # 1..mx maps to indices 0..7 across eight levels.
      idx=$(( (dur * 8 - 1) / mx ))
      (( idx > 7 )) && idx=7
      (( idx < 0 )) && idx=0
    fi
    out+="${levels[$idx]}"
  done <<<"${rows}"

  printf '%s' "${out}"
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
  # v1.31.0 Wave 4 (data-lens F-3 + F-5): rename `session` field to
  # `session_id` for cross-ledger join consistency (gate_events,
  # session_summary, serendipity, classifier_misfires all use
  # `session_id`). Add `_v:1` schema_version for future migrations.
  # Pre-Wave-4 rows (with `session` field) coexist via the
  # backwards-compat dedup filter below — see the `(.session // "")`
  # / `(.session_id // "")` reads.
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg session_id "${sid}" \
    --arg project_key "$(_omc_project_key 2>/dev/null || _omc_project_id)" \
    --argjson agg "${agg}" \
    '{_v:1,ts:$ts,session_id:$session_id,project_key:$project_key} + $agg' 2>/dev/null)"
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
      # v1.31.0 Wave 4: backwards-compat dedup over BOTH the legacy
      # `.session` and the new `.session_id` field — old rows from
      # pre-v1.31.0 timing.jsonl still need to be deduped against
      # the current sid until they age out via the cross-session cap.
      if jq -c --arg sid "${sid}" 'select(((.session_id // .session) // "") != $sid)' \
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
#   Output: {sessions:N, walltime_s:T, agent_breakdown:{...}, tool_breakdown:{...},
#            directive_breakdown:{...}, directive_counts:{...}}
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
      # v1.34.1+ (D-002): sum the parallelism overhead so the renderer
      # can disclose "X minutes saved by parallel work" across the window.
      # Pre-Wave-1 rows lack the field; default to 0 keeps math clean.
      concurrent_overhead_s: ([$rows[] | (.concurrent_overhead_s // 0)] | add // 0),
      directive_total_chars: ([$rows[] | (.directive_total_chars // 0)] | add // 0),
      directive_count: ([$rows[] | (.directive_count // 0)] | add // 0),
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
      directive_breakdown: (
        [$rows[] | (.directive_breakdown // {}) | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | add)})
        | from_entries
      ),
      directive_counts: (
        [$rows[] | (.directive_counts // {}) | to_entries[]]
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
