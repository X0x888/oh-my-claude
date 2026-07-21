# shellcheck shell=bash
# timing.sh — Per-tool / per-subagent timing capture and aggregation.
#
# Sourced by common.sh AFTER lib/state-io.sh (needs session_file). Provides
# append-only capture (start + end rows) and a read-time aggregator. Every
# writer uses the timing-log mutex. This lets the cold prompt-end cap replace
# the file atomically without dropping a hot-path append that arrived between
# its tail snapshot and rename.
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
  _timing_uint_is_valid "${n}" || n="${#s}"
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

_timing_append_row_locked() {
  local target="$1" row="$2"
  [[ ! -L "${target}" ]] \
    && { [[ ! -e "${target}" ]] || [[ -f "${target}" ]]; } || return 1
  printf '%s\n' "${row}" >>"${target}" 2>/dev/null
}

_timing_append_row() {
  local row="$1" target
  target="$(timing_log_path)"
  with_cross_session_log_lock "${target}" \
    _timing_append_row_locked "${target}" "${row}"
}

# Timing values ultimately enter Bash arithmetic even when their first hop is
# only a JSON row. Keep state/cursor values within jq's exact-integer range and
# well below signed-shell overflow. This deliberately rejects leading zeroes:
# `08` is data to jq but invalid octal syntax to Bash 3.2 arithmetic.
_TIMING_UINT_MAX=999999999999999
_TIMING_UINT_INCREMENT_MAX=999999999999998
# Eight independently bounded token components can legitimately be present in
# one rendered total. Keep their exact sum below signed 64-bit arithmetic while
# avoiding the per-field clamp that used to under-report multi-component rows.
_TIMING_TOKEN_SUM_MAX=7999999999999992

_timing_uint_is_valid() {
  _omc_canonical_uint_in_range "${1:-}" 0 "${2:-${_TIMING_UINT_MAX}}"
}

_timing_epoch_is_valid() {
  _omc_canonical_uint_in_range "${1:-}" 1 "${_TIMING_UINT_MAX}"
}

# State I/O stores scalar values as outer JSON strings. `read_state` is the
# right general-purpose compatibility API, but raw jq output can contain NUL;
# Bash command substitution silently removes that byte before a shell-side
# validator sees it. Timing values feed arithmetic, cursor authority, and
# resume ownership, so validate their JSON type/grammar before raw output.
# These keys have always lived in session_state.json; failing closed when the
# canonical state file/key is absent avoids reintroducing the same ambiguity
# through an untyped legacy sidecar.
_timing_read_state_text_no_nul() {
  local key="${1:-}" state_file=""
  [[ -n "${key}" ]] || return 1
  state_file="$(session_file "${STATE_JSON}")"
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
  jq -er --arg k "${key}" '
    select(type == "object" and has($k))
    | .[$k]
    | select(type == "string" and (contains("\u0000") | not))
  ' "${state_file}" 2>/dev/null
}

_timing_read_state_json_object() {
  local key="${1:-}" raw=""
  raw="$(_timing_read_state_text_no_nul "${key}" 2>/dev/null)" || return 1
  jq -nec --arg raw "${raw}" '
    $raw | fromjson? | select(type == "object")
  ' 2>/dev/null
}

_timing_read_state_uint() {
  local key="${1:-}" max="${2:-${_TIMING_UINT_MAX}}" state_file=""
  [[ -n "${key}" ]] || return 1
  _timing_uint_is_valid "${max}" || return 1
  state_file="$(session_file "${STATE_JSON}")"
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
  jq -er --arg k "${key}" --argjson max "${max}" '
    select(type == "object" and has($k))
    | .[$k] as $value
    | select(($value | type) == "string"
        and ($value | test("^(0|[1-9][0-9]{0,14})$"))
        and (($value | tonumber) <= $max))
    | $value
  ' "${state_file}" 2>/dev/null
}

_timing_read_state_uint_or_zero_when_absent() {
  local key="${1:-}" max="${2:-${_TIMING_UINT_MAX}}" state_file=""
  [[ -n "${key}" ]] || return 1
  _timing_uint_is_valid "${max}" || return 1
  state_file="$(session_file "${STATE_JSON}")"
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || {
    printf '0'
    return 0
  }
  jq -er --arg k "${key}" --argjson max "${max}" '
    if type != "object" then empty
    elif has($k) then
      .[$k] as $value
      | select(($value | type) == "string"
          and ($value | test("^(0|[1-9][0-9]{0,14})$"))
          and (($value | tonumber) <= $max))
      | $value
    else "0"
    end
  ' "${state_file}" 2>/dev/null
}

_timing_read_sid_from_state_file() {
  local state_file="${1:-}" key="${2:-}"
  [[ -n "${state_file}" && -n "${key}"
      && -f "${state_file}" && ! -L "${state_file}" ]] || return 1
  jq -er --arg k "${key}" '
    select(type == "object" and has($k))
    | .[$k]
    | select(type == "string"
        and length >= 1 and length <= 128
        and test("^[a-zA-Z0-9_.-]+$")
        and (contains("..") | not)
        and (test("^\\.+$") | not))
  ' "${state_file}" 2>/dev/null
}

_timing_read_state_sid() {
  local state_file=""
  state_file="$(session_file "${STATE_JSON}")"
  _timing_read_sid_from_state_file "${state_file}" "${1:-}"
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
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0

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
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
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
  _timing_append_row "${row}" 2>/dev/null || true
}

# timing_append_end <tool> [tool_use_id] [prompt_seq]
timing_append_end() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local tool="${1:-}"
  [[ -z "${tool}" ]] && return 0
  local tool_use_id="${2:-}"
  local prompt_seq="${3:-0}"
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0

  local tool_esc tu_esc ts
  _timing_json_escape "${tool}" tool_esc
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
  local row='{"kind":"end","ts":'"${ts}"',"tool":"'"${tool_esc}"'","prompt_seq":'"${prompt_seq}"
  if [[ -n "${tool_use_id}" ]]; then
    _timing_json_escape "${tool_use_id}" tu_esc
    row+=',"tool_use_id":"'"${tu_esc}"'"'
  fi
  row+='}'

  ensure_session_dir 2>/dev/null || return 0
  _timing_append_row "${row}" 2>/dev/null || true
}

# timing_append_prompt_start <prompt_seq>
timing_append_prompt_start() {
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local prompt_seq="${1:-0}"
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0

  local ts
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
  local row='{"kind":"prompt_start","ts":'"${ts}"',"prompt_seq":'"${prompt_seq}"'}'

  ensure_session_dir 2>/dev/null || return 0
  _timing_append_row "${row}" 2>/dev/null || true
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
  _timing_uint_is_valid "${chars}" || return 0
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0

  local name_esc ts
  _timing_json_escape "${name}" name_esc
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
  local row='{"kind":"directive_emitted","ts":'"${ts}"',"prompt_seq":'"${prompt_seq}"',"name":"'"${name_esc}"'","chars":'"${chars}"'}'

  ensure_session_dir 2>/dev/null || return 0
  _timing_append_row "${row}" 2>/dev/null || true
}

# timing_append_prompt_end <prompt_seq> <duration_s>
_timing_append_prompt_end_log_locked() {
  local target="$1" prompt_seq="$2" row="$3" existing=0
  [[ ! -L "${target}" ]] \
    && { [[ ! -e "${target}" ]] || [[ -f "${target}" ]]; } || return 1
  if [[ -s "${target}" ]]; then
    existing="$(jq -Rsr --argjson seq "${prompt_seq}" '
      def canonical_uint:
        type == "number" and floor == . and . >= 0
        and . <= 999999999999999;
      reduce (split("\n")[] | select(length > 0)
          | (try fromjson catch {}) | select(type == "object")) as $row
        ({started:false, ended:false};
          if ($row.kind == "prompt_start"
              and ($row.ts | canonical_uint) and $row.ts > 0
              and ($row.prompt_seq | canonical_uint)
              and $row.prompt_seq == $seq) then
            .started = true
          elif ($row.kind == "prompt_end"
              and ($row.ts | canonical_uint) and $row.ts > 0
              and ($row.prompt_seq | canonical_uint)
              and $row.prompt_seq == $seq
              and ($row.duration_s | canonical_uint)
              and .started) then
            .ended = true
          else . end)
      # 0 means one ordered end is still admissible. A log with no valid
      # start is not an unfinished prompt and must not accumulate orphan ends
      # on repeated callbacks after rotation or corruption.
      | if .ended then 1 elif .started then 0 else 2 end
    ' "${target}" 2>/dev/null)" || return 1
  fi
  _timing_uint_is_valid "${existing}" || return 1
  (( existing == 0 )) || return 0
  printf '%s\n' "${row}" >>"${target}" 2>/dev/null || return 1
  _cap_per_session_jsonl "${target}" \
    "${OMC_TIMING_PER_SESSION_CAP:-5000}" \
    "${OMC_TIMING_PER_SESSION_RETAIN:-4000}"
}

_timing_append_prompt_end_locked() {
  local prompt_seq="$1" row="$2" target
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 1
  fi
  target="$(timing_log_path)"
  with_cross_session_log_lock "${target}" \
    _timing_append_prompt_end_log_locked \
      "${target}" "${prompt_seq}" "${row}"
}

timing_append_prompt_end() {
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 0
  fi
  is_time_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local prompt_seq="${1:-0}"
  local duration_s="${2:-0}"
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0
  _timing_uint_is_valid "${duration_s}" || duration_s=0

  local ts
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
  local row='{"kind":"prompt_end","ts":'"${ts}"',"prompt_seq":'"${prompt_seq}"',"duration_s":'"${duration_s}"'}'

  ensure_session_dir 2>/dev/null || return 0
  # The row is staged above. Recheck the captured enforcement generation as
  # the first operation under the session mutex so a delayed G1 Stop cannot
  # append/cap G2's timing ledger after release -> reactivation.
  with_state_lock _timing_append_prompt_end_locked \
    "${prompt_seq}" "${row}" \
    2>/dev/null || true
}

# _cap_per_session_jsonl <file> <cap> <retain>
#   Cap a per-session JSONL at <cap> rows, retaining the last <retain>
#   on overflow. The caller must hold this exact file's
#   with_cross_session_log_lock mutex; all timing writers use the same mutex.
#   Bash 3.2 safe.
_cap_per_session_jsonl() {
  local file="$1" cap="${2:-5000}" retain="${3:-4000}"
  [[ -f "${file}" ]] || return 0
  _omc_canonical_uint_in_range "${cap}" 1 2147483647 || return 0
  _omc_canonical_uint_in_range "${retain}" 1 2147483647 || return 0
  local lines temp
  lines="$(wc -l < "${file}" 2>/dev/null || echo 0)"
  lines="${lines//[[:space:]]/}"
  _timing_uint_is_valid "${lines}" || return 0
  [[ "${lines}" -le "${cap}" ]] && return 0
  temp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 0
  if tail -n "${retain}" "${file}" > "${temp}" 2>/dev/null; then
    if [[ -n "${OMC_TEST_TIMING_CAP_READY_FILE:-}" ]]; then
      : >"${OMC_TEST_TIMING_CAP_READY_FILE}"
      while [[ -n "${OMC_TEST_TIMING_CAP_RELEASE_FILE:-}" \
          && ! -e "${OMC_TEST_TIMING_CAP_RELEASE_FILE}" ]]; do
        sleep 0.01
      done
    fi
    mv "${temp}" "${file}" 2>/dev/null || rm -f "${temp}"
  else
    rm -f "${temp}"
  fi
}

# --- Token capture (v1.46-pre) ---
#
# timing_capture_session_tokens <transcript_path> <prompt_seq>
#   Append a `token_delta` row plus a durable `token_checkpoint` to
#   timing.jsonl, attributing tokens consumed since the previous Stop to
#   the main thread vs sub-agents.
#
#   Source of truth: Claude Code's session transcript JSONL (the hook's
#   `transcript_path`) AND the real sidechain layout used by current Claude
#   Code releases: `<transcript-stem>/subagents/*.jsonl`. Each assistant row
#   carries `message.usage` (input_tokens / output_tokens /
#   cache_read_input_tokens / cache_creation_input_tokens). Sidechain rows
#   also carry `message.model` and normally `attributionAgent`, which are
#   retained as per-model and per-role token buckets.
#
#   Why incremental (per-file cursor-based) rather than boundary-correlated: the
#   transcript's `type:"user"` rows are mostly harness injections
#   (task-notifications, Stop-feedback, slash-command sequences), so
#   "tokens since the last user prompt" cannot be located reliably by
#   content. Instead we track identity-aware per-file byte cursors in state
#   (`token_transcript_cursors`; `token_transcript_rows` remains a legacy
#   parent-transcript mirror) and parse ONLY complete rows appended since the
#   previous Stop. Reads are capped at a stat snapshot, and partial JSON tails
#   retain the prior complete-line offset. Cursors are keyed by absolute path
#   and carry a device/inode identity, so a replaced file cannot inherit a
#   stale offset. Cost is bounded to new slices after one-time migration.
#
#   Session cumulative lives in `token_totals` state and is emitted as the
#   latest token_checkpoint. Mega-sessions may lose old token_delta detail
#   when timing.jsonl is trimmed, but their cumulative token totals therefore
#   remain monotonic. The checkpoint also repairs a prior interrupted append
#   on the next Stop.
#
#   Fail-open: any missing dependency (jq, transcript, SESSION_ID) or parse
#   error returns cleanly without writing — token capture never blocks Stop.
_timing_append_token_rows_locked() {
  local target="$1" delta_row="$2" checkpoint_row="$3"
  [[ -z "${delta_row}" ]] \
    || _timing_append_row_locked "${target}" "${delta_row}" || return 1
  [[ -z "${checkpoint_row}" ]] \
    || _timing_append_row_locked "${target}" "${checkpoint_row}" || return 1
}

_timing_file_identity() {
  local file="${1:-}" ident=""
  [[ -f "${file}" ]] || return 1
  # GNU stat must be tried first: on Linux `stat -f FORMAT FILE` means
  # filesystem mode and can emit a mutable filesystem report for FILE even
  # while returning failure for FORMAT. Keep each probe in its own assignment
  # so failed-command stdout can never contaminate the fallback value.
  ident="$(stat -c '%d:%i' "${file}" 2>/dev/null)" || ident=""
  if [[ ! "${ident}" =~ ^[0-9]+:[0-9]+$ ]]; then
    ident="$(stat -f '%d:%i' "${file}" 2>/dev/null)" || ident=""
  fi
  [[ "${ident}" =~ ^[0-9]+:[0-9]+$ ]] || ident=""
  # The path fallback remains stable across appends; row-count shrink
  # detection still protects rewrites on an exotic stat implementation.
  [[ -n "${ident}" ]] || ident="path:${file}"
  printf '%s' "${ident}"
}

_timing_file_size() {
  local file="${1:-}" size=""
  [[ -f "${file}" ]] || return 1
  size="$(stat -c '%s' "${file}" 2>/dev/null)" || size=""
  if [[ ! "${size}" =~ ^[0-9]+$ ]]; then
    size="$(stat -f '%z' "${file}" 2>/dev/null)" || size=""
  fi
  _timing_uint_is_valid "${size}" || return 1
  printf '%s' "${size}"
}

# Test whether a previously-stat'ed byte snapshot ends at a JSONL record
# boundary. Read byte N rather than live EOF: the transcript may keep growing
# while Stop telemetry is being captured, and a live-EOF check would make the
# earlier size snapshot meaningless.
_timing_snapshot_ends_line() {
  local file="${1:-}" size="${2:-}" newline_count=""
  [[ -f "${file}" ]] && _timing_uint_is_valid "${size}" || return 1
  (( size == 0 )) && return 0
  # POSIX dd seeks over regular-file input for skipped blocks. Reading the
  # stat'ed final byte avoids a live-EOF race and needs only one-byte output.
  newline_count="$(dd if="${file}" bs=1 skip="$((size - 1))" count=1 \
    2>/dev/null | wc -l)"
  newline_count="${newline_count//[[:space:]]/}"
  [[ "${newline_count}" == "1" ]]
}

# Count complete JSONL rows in exactly the first N bytes. This is used only by
# legacy row-cursor migration; steady state is byte-cursored and never scans
# old transcript history.
_timing_snapshot_line_count() {
  local file="${1:-}" size="${2:-}" lines=""
  [[ -f "${file}" ]] && _timing_uint_is_valid "${size}" || return 1
  lines="$(head -c "${size}" "${file}" 2>/dev/null | wc -l | tr -d ' ')"
  _timing_uint_is_valid "${lines}" || return 1
  printf '%s' "${lines}"
}

# One process-batched snapshot of the nested sidechain directory. A session
# can leave hundreds of completed `subagents/*.jsonl` files behind. Walking
# every historical file through stat/wc/jq on every Stop made an unchanged
# second capture take seconds. The manifest includes path, device/inode, size,
# and mtime; an exact match means no nested file was added, replaced, shrunk,
# or appended, so the expensive per-file cursor path can be skipped entirely.
# Parent transcript handling remains independent because it normally grows on
# every turn. Transcript filenames are Claude-controlled UUIDs; tab/newline
# path ambiguity is therefore outside the source format.
_timing_agent_transcript_manifest() {
  local dir="${1:-}"
  [[ -d "${dir}" ]] || return 0
  if stat -c '%d:%i:%s:%Y' "${dir}" >/dev/null 2>&1; then
    find "${dir}" -maxdepth 1 -type f -name '*.jsonl' \
      -exec stat -c $'%n\t%d:%i\t%s\t%Y' {} + 2>/dev/null \
      | LC_ALL=C sort
  else
    find "${dir}" -maxdepth 1 -type f -name '*.jsonl' \
      -exec stat -f $'%N\t%d:%i\t%z\t%m' {} + 2>/dev/null \
      | LC_ALL=C sort
  fi
}

# Add two normalized token-total objects. Kept as a helper because capture
# merges one independently-cursored file at a time and jq integer arithmetic
# avoids bash overflow/format surprises from malformed telemetry.
_timing_add_token_totals() {
  local left="${1:-}" right="${2:-}"
  [[ -n "${left}" ]] || left='{}'
  [[ -n "${right}" ]] || right='{}'
  jq -nc --argjson a "${left}" --argjson b "${right}" '
    # Session state is durable but cooperative, so an interrupted older writer,
    # a hand edit, or a pre-schema value can leave a valid top-level object with
    # poisoned nested maps. Normalize at this transaction boundary: malformed
    # historical detail is unrecoverable, but it must never erase the fresh
    # slice whose cursor is about to advance. The ceiling matches
    # timing_normalize_uint and also keeps every value exactly representable by
    # jq before later Bash arithmetic consumes it.
    def n($v):
      (if ($v | type) == "number" then $v
       elif (($v | type) == "string" and ($v | test("^[0-9]+$")))
       then (try ($v | tonumber) catch 0)
       else 0 end) as $n
      | if (($n | type) == "number"
            and $n >= 0
            and $n <= 999999999999999
            and $n == ($n | floor))
        then $n else 0 end;
    def object_or_empty($v):
      if ($v | type) == "object" then $v else {} end;
    def bucket($v):
      object_or_empty($v) as $o
      | {
          input: n($o.input),
          output: n($o.output),
          cache_read: n($o.cache_read),
          cache_creation: n($o.cache_creation)
        };
    def add_n($x; $y):
      (n($x) + n($y)) as $sum
      | if $sum > 999999999999999 then 999999999999999 else $sum end;
    def normalize_buckets($x):
      reduce (object_or_empty($x) | to_entries[]) as $e ({};
        # Scalar/array bucket entries carry no trustworthy attribution. Drop
        # them instead of retaining a fake zero-valued label indefinitely.
        if ($e.value | type) == "object"
        then .[$e.key] = bucket($e.value)
        else . end
      );
    def add_bucket($x; $y):
      bucket($x) as $old
      | bucket($y) as $new
      | {
          input:          add_n($old.input;          $new.input),
          output:         add_n($old.output;         $new.output),
          cache_read:     add_n($old.cache_read;     $new.cache_read),
          cache_creation: add_n($old.cache_creation; $new.cache_creation)
        };
    def merge_buckets($x; $y):
      reduce (object_or_empty($y) | to_entries[]) as $e (normalize_buckets($x);
        if ($e.value | type) == "object"
        then .[$e.key] = add_bucket(.[$e.key]; $e.value)
        else . end
      );
    # Per-dispatch attribution is diagnostic detail, not the session total.
    # Bound it so a very long session cannot grow session_state.json without
    # limit. Re-touching an ID moves it to the recent tail; 512 retained IDs
    # comfortably exceed the 64-live-dispatch ceiling while keeping the rare
    # late/background update exact. A rotated stale run is reported as having
    # unavailable token telemetry, never assigned an invented value.
    def merge_recent_id_buckets($x; $y):
      (reduce (object_or_empty($y) | to_entries[]) as $e (normalize_buckets($x);
        if ($e.value | type) == "object" then
          add_bucket(.[$e.key]; $e.value) as $merged
          | del(.[$e.key])
          | .[$e.key] = $merged
        else . end
      )) | to_entries
      | if length > 512 then .[-512:] else . end
      | from_entries;
    {
      main_in:             add_n($a.main_in;             $b.main_in),
      main_out:            add_n($a.main_out;            $b.main_out),
      main_cache_read:     add_n($a.main_cache_read;     $b.main_cache_read),
      main_cache_creation: add_n($a.main_cache_creation; $b.main_cache_creation),
      agent_in:             add_n($a.agent_in;             $b.agent_in),
      agent_out:            add_n($a.agent_out;            $b.agent_out),
      agent_cache_read:     add_n($a.agent_cache_read;     $b.agent_cache_read),
      agent_cache_creation: add_n($a.agent_cache_creation; $b.agent_cache_creation),
      usage_rows:           add_n($a.usage_rows;           $b.usage_rows),
      agent_by_role:  merge_buckets($a.agent_by_role;  $b.agent_by_role),
      agent_by_model: merge_buckets($a.agent_by_model; $b.agent_by_model),
      agent_by_id:    merge_recent_id_buckets($a.agent_by_id; $b.agent_by_id)
    }
  ' 2>/dev/null
}

# Sum one newly-appended transcript slice. `source=agent` is authoritative
# for files below subagents/ even if a Claude Code version omits isSidechain.
#
# Claude Code writes one transcript row per assistant content block. Those
# rows can repeat the SAME API request's cumulative `message.usage` several
# times (thinking, text, and tool-use blocks commonly share requestId and
# message.id). Summing rows therefore overstates real tokens by 3-7x. Collapse
# identifiable rows by request, retain the component-wise maximum cumulative
# usage, and subtract the prior trailing request when it spans a Stop cursor.
# The return shape is `{totals,last_request}`; `last_request` is persisted in
# that file's cursor entry. API requests are sequential within one transcript,
# so only the trailing request can cross an append boundary. Rows from older
# transcript versions with neither requestId nor message.id remain independent
# observations: guessing that two identical anonymous usages are duplicates
# would silently undercount legitimate calls.
_timing_sum_token_slice() {
  local file="$1" first_row="$2" source="$3" prior="${4:-null}" last_row="${5:-0}"
  local first_byte="${6:-}" last_byte="${7:-}" byte_count=0 agent_id_hint=""
  if [[ "${source}" == "agent" ]]; then
    agent_id_hint="${file##*/}"
    agent_id_hint="${agent_id_hint%.jsonl}"
    agent_id_hint="${agent_id_hint#agent-}"
  fi
  jq -e 'type == "object" or . == null' <<<"${prior}" >/dev/null 2>&1 || prior='null'
  _omc_canonical_uint_in_range "${first_row}" 1 "${_TIMING_UINT_MAX}" \
    || first_row=1
  _timing_uint_is_valid "${last_row}" || last_row=0
  if [[ -n "${first_byte}" ]] \
      && ! _timing_uint_is_valid "${first_byte}"; then
    first_byte=""
  fi
  if [[ -n "${last_byte}" ]] \
      && ! _timing_uint_is_valid "${last_byte}"; then
    last_byte=""
  fi
  {
    if [[ -n "${first_byte}" && -n "${last_byte}" ]] \
        && (( last_byte >= first_byte )); then
      # Byte cursors make steady-state parent capture proportional to appended
      # JSONL bytes. BSD tail can seek regular files for `-c +N`; unlike
      # `tail -n +ROW`, it does not rescan a multi-million-line transcript to
      # discover the requested line boundary. Cap the read at the stat'ed
      # snapshot: the live transcript can append while this pipeline runs.
      byte_count=$((last_byte - first_byte))
      if (( byte_count > 0 )); then
        (
          set +o pipefail
          tail -c "+$((first_byte + 1))" "${file}" 2>/dev/null \
            | head -c "${byte_count}"
        )
      fi
    elif (( last_row >= first_row && last_row > 0 )); then
      sed -n "${first_row},${last_row}p" "${file}" 2>/dev/null
    else
      tail -n "+${first_row}" "${file}" 2>/dev/null
    fi
  } | jq -sc --arg source "${source}" --arg agent_id_hint "${agent_id_hint}" --argjson prior "${prior}" '
    def n($v):
      if (($v | type) == "number"
          and $v >= 0 and $v <= 999999999999999
          and $v == ($v | floor))
      then $v else 0 end;
    def add_n($left; $right):
      (n($left) + n($right)) as $sum
      | if $sum > 999999999999999 then 999999999999999 else $sum end;
    def usage($u): {
      input: n($u.input_tokens),
      output: n($u.output_tokens),
      cache_read: n($u.cache_read_input_tokens),
      cache_creation: n($u.cache_creation_input_tokens)
    };
    def max_usage($a; $b): {
      input:          ([n($a.input),          n($b.input)]          | max),
      output:         ([n($a.output),         n($b.output)]         | max),
      cache_read:     ([n($a.cache_read),     n($b.cache_read)]     | max),
      cache_creation: ([n($a.cache_creation), n($b.cache_creation)] | max)
    };
    def usage_delta($new; $old): {
      input:          ([n($new.input)          - n($old.input),          0] | max),
      output:         ([n($new.output)         - n($old.output),         0] | max),
      cache_read:     ([n($new.cache_read)     - n($old.cache_read),     0] | max),
      cache_creation: ([n($new.cache_creation) - n($old.cache_creation), 0] | max)
    };
    def safe_key($v; $fallback):
      (($v // $fallback) | tostring
       | explode | map(if . < 32 or . == 127 then 63 else . end) | implode
       | gsub("[|`]"; "_")) as $s
      | if ($s | length) == 0 then $fallback
        elif ($s | length) > 96 then ($s[0:95] + "…")
        else $s end;
    def safe_agent_id($v):
      (($v // "") | tostring
       | explode | map(if . < 32 or . == 127 then 63 else . end) | implode
       | gsub("[|`]"; "_")) as $s
      | if ($s | length) > 128 then $s[0:128] else $s end;
    def zero_bucket: {input:0, output:0, cache_read:0, cache_creation:0};
    def first_nonempty($values):
      [$values[] | select(. != null) | tostring | select(length > 0)]
      | first // "";
    def request_key($m):
      (first_nonempty([$m.requestId, $m.request_id, $m.message.id])
       | explode | map(if . < 32 or . == 127 then 63 else . end) | implode
       | if length > 160 then .[0:160] else . end);
    def zero_totals:
      {main_in:0,main_out:0,main_cache_read:0,main_cache_creation:0,
       agent_in:0,agent_out:0,agent_cache_read:0,agent_cache_creation:0,
       usage_rows:0,agent_by_role:{},agent_by_model:{},agent_by_id:{}};
    def add_bucket($obj; $key; $u):
      $obj + {($key): (($obj[$key] // zero_bucket) |
        .input          = add_n(.input;          $u.input) |
        .output         = add_n(.output;         $u.output) |
        .cache_read     = add_n(.cache_read;     $u.cache_read) |
        .cache_creation = add_n(.cache_creation; $u.cache_creation))};
    def add_record($state; $r; $u; $request_inc):
      $state | .usage_rows = add_n(.usage_rows; $request_inc) |
      if $r.agent then
        .agent_in             = add_n(.agent_in;             $u.input) |
        .agent_out            = add_n(.agent_out;            $u.output) |
        .agent_cache_read     = add_n(.agent_cache_read;     $u.cache_read) |
        .agent_cache_creation = add_n(.agent_cache_creation; $u.cache_creation) |
        .agent_by_role  = add_bucket(.agent_by_role;  $r.role;  $u) |
        .agent_by_model = add_bucket(.agent_by_model; $r.model; $u) |
        if $r.agent_id_known then
          .agent_by_id = add_bucket(.agent_by_id; $r.agent_id; $u)
        else . end
      else
        .main_in             = add_n(.main_in;             $u.input) |
        .main_out            = add_n(.main_out;            $u.output) |
        .main_cache_read     = add_n(.main_cache_read;     $u.cache_read) |
        .main_cache_creation = add_n(.main_cache_creation; $u.cache_creation)
      end;
    def record($m; $id):
      first_nonempty([$m.attributionAgent, $m.agentType]) as $role |
      first_nonempty([$m.message.model]) as $model |
      first_nonempty([$m.agentId, $m.agent_id, $agent_id_hint]) as $agent_id |
      {id:$id,
       usage:usage($m.message.usage),
       agent:($source == "agent" or $m.isSidechain == true),
       role:safe_key($role; "general-purpose"),
       model:safe_key($model; "unknown"),
       agent_id:safe_agent_id($agent_id),
       role_known:($role != ""),
       model_known:($model != ""),
       agent_id_known:($agent_id != "")};
    def merge_prior_metadata($r; $p):
      if (($p.id // "") == ($r.id // "")) then
        $r + {
          # A later transcript slice can contain a partial or regressed
          # cumulative snapshot for the same API request. Persist the
          # component-wise high-water mark, not that lower tail row, or a
          # subsequent recovery would be charged twice across Stop cursors.
          usage:max_usage(($p.usage // {}); ($r.usage // {})),
          agent:(($r.agent // false) or ($p.agent // false)),
          role:(if ($r.role_known // false) then $r.role
                elif ($p.role_known // false) then $p.role else $r.role end),
          model:(if ($r.model_known // false) then $r.model
                 elif ($p.model_known // false) then $p.model else $r.model end),
          agent_id:(if ($r.agent_id_known // false) then $r.agent_id
                   elif ($p.agent_id_known // false) then $p.agent_id else $r.agent_id end),
          role_known:(($r.role_known // false) or ($p.role_known // false)),
          model_known:(($r.model_known // false) or ($p.model_known // false)),
          agent_id_known:(($r.agent_id_known // false) or ($p.agent_id_known // false))
        }
      else $r end;

    (. | length) as $rows_scanned |
    (reduce .[] as $m ({order:[], by_id:{}, anonymous:[], last_id:null};
      if (($m.message.usage // null) == null) then . else
        request_key($m) as $id |
        record($m; $id) as $r |
        if $id == "" then
          .anonymous += [$r]
        else
          if .by_id[$id] == null then
            .order += [$id] | .by_id[$id] = $r
          else
            .by_id[$id] as $old |
            .by_id[$id] = ($r + {
              agent:($r.agent or ($old.agent // false)),
              usage:max_usage($old.usage; $r.usage),
              role:(if $r.role_known then $r.role else $old.role end),
              model:(if $r.model_known then $r.model else $old.model end),
              agent_id:(if $r.agent_id_known then $r.agent_id else $old.agent_id end),
              role_known:($r.role_known or ($old.role_known // false)),
              model_known:($r.model_known or ($old.model_known // false)),
              agent_id_known:($r.agent_id_known or ($old.agent_id_known // false))
            })
          end |
          .last_id = $id
        end
      end
    )) as $scan |
    (reduce $scan.order[] as $id (zero_totals;
      merge_prior_metadata($scan.by_id[$id]; $prior) as $r |
      if (($prior.id // "") == $id) then
        add_record(.; $r; usage_delta($r.usage; ($prior.usage // {})); 0)
      else
        add_record(.; $r; $r.usage; 1)
      end
    )) as $identified |
    (reduce $scan.anonymous[] as $r ($identified;
      add_record(.; $r; $r.usage; 1)
    )) as $totals |
    {
      totals: $totals,
      rows_scanned: $rows_scanned,
      last_request: (
        if $scan.last_id != null then
          merge_prior_metadata($scan.by_id[$scan.last_id]; $prior)
        else $prior
        end
      )
    }
  ' 2>/dev/null
}

# Parse stat-snapshot specs for newly discovered sidechain files in one jq
# process. Each argument is one manifest line (`path<TAB>identity<TAB>size...`).
# A large
# Council run can create 100+ tiny files; paying one sed+jq pair per file made
# the first economics capture take tens of seconds even though the data itself
# was tiny. We copy exactly the stat'ed prefix of each file before parsing, so
# an agent transcript that appends during capture cannot be charged now and
# then re-read from the older cursor on the next Stop. `input_filename` plus a
# bounded temp-path map keeps request dedupe and trailing-request cursors
# isolated per original transcript. The caller falls back to the conservative
# per-file path if any snapshot is partial, replaced, or cannot be parsed.
_timing_sum_new_agent_files() {
  (( $# > 0 )) || { printf '%s\n' '{"totals":{},"files":{}}'; return 0; }
  local snapshot_dir="" map_file="" spec="" file="" rest="" identity="" size=""
  local snapshot="" snapshot_meta='{}' snapshot_stat_meta='{}' current_meta='{}' result=""
  local agent_dir="" current_manifest="" stat_lines=""
  local snapshot_files=()
  snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/omc-token-snapshot.XXXXXX" 2>/dev/null)" \
    || return 1
  map_file="${snapshot_dir}/files.tsv"
  : > "${map_file}" || { rm -rf "${snapshot_dir}"; return 1; }
  local index=0
  for spec in "$@"; do
    file="${spec%%$'\t'*}"
    rest="${spec#*$'\t'}"
    identity="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    size="${rest%%$'\t'*}"
    if [[ -z "${file}" || -z "${identity}" ]] \
        || ! _timing_uint_is_valid "${size}" \
        || ! _timing_snapshot_ends_line "${file}" "${size}"; then
      rm -rf "${snapshot_dir}"
      return 1
    fi
    snapshot="${snapshot_dir}/${index}.jsonl"
    if ! head -c "${size}" "${file}" > "${snapshot}" 2>/dev/null; then
      rm -rf "${snapshot_dir}"
      return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "${snapshot}" "${file}" "${identity}" "${size}" \
      >> "${map_file}" || { rm -rf "${snapshot_dir}"; return 1; }
    snapshot_files[${#snapshot_files[@]}]="${snapshot}"
    index=$((index + 1))
  done
  snapshot_meta="$(jq -Rn '
    [inputs | split("\t")
      | select(length == 4)
      | {key:.[0], value:{original:.[1], identity:.[2], bytes:(.[3] | tonumber)}}]
    | from_entries
  ' < "${map_file}" 2>/dev/null || printf '{}')"
  if ! jq -e --argjson expected "${#snapshot_files[@]}" \
      'type == "object" and length == $expected' \
      <<<"${snapshot_meta}" >/dev/null 2>&1; then
    rm -rf "${snapshot_dir}"
    return 1
  fi

  # Validate every copied prefix in one stat process rather than paying two
  # stat forks per sidechain. Then validate the original identities/sizes with
  # one directory manifest walk. Appends are allowed (`current >= snapshot`):
  # they remain after the stored byte cursor for the next Stop.
  if stat -c '%s' "${snapshot_files[0]}" >/dev/null 2>&1; then
    stat_lines="$(stat -c $'%n\t%s' "${snapshot_files[@]}" 2>/dev/null || true)"
  else
    stat_lines="$(stat -f $'%N\t%z' "${snapshot_files[@]}" 2>/dev/null || true)"
  fi
  snapshot_stat_meta="$(printf '%s\n' "${stat_lines}" | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t"))
    | map(select(length == 2) | {key:.[0],value:(.[1] | tonumber? // -1)})
    | from_entries
  ' 2>/dev/null || printf '{}')"
  agent_dir="${file%/*}"
  current_manifest="$(_timing_agent_transcript_manifest "${agent_dir}" 2>/dev/null || true)"
  current_meta="$(printf '%s\n' "${current_manifest}" | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t"))
    | map(select(length >= 3)
      | {key:.[0],value:{identity:.[1],bytes:(.[2] | tonumber? // -1)}})
    | from_entries
  ' 2>/dev/null || printf '{}')"
  if ! jq -e --argjson actual "${snapshot_stat_meta}" \
      --argjson current "${current_meta}" '
        all(to_entries[];
          ($actual[.key] // -1) == .value.bytes
          and ($current[.value.original].identity // "") == .value.identity
          and ($current[.value.original].bytes // -1) >= .value.bytes)
      ' <<<"${snapshot_meta}" >/dev/null 2>&1; then
    rm -rf "${snapshot_dir}"
    return 1
  fi

  if result="$(jq -n --argjson snapshots "${snapshot_meta}" '
    def n($v):
      if (($v | type) == "number"
          and $v >= 0 and $v <= 999999999999999
          and $v == ($v | floor))
      then $v else 0 end;
    def add_n($left; $right):
      (n($left) + n($right)) as $sum
      | if $sum > 999999999999999 then 999999999999999 else $sum end;
    def usage($u): {
      input: n($u.input_tokens),
      output: n($u.output_tokens),
      cache_read: n($u.cache_read_input_tokens),
      cache_creation: n($u.cache_creation_input_tokens)
    };
    def max_usage($a; $b): {
      input:          ([n($a.input),          n($b.input)]          | max),
      output:         ([n($a.output),         n($b.output)]         | max),
      cache_read:     ([n($a.cache_read),     n($b.cache_read)]     | max),
      cache_creation: ([n($a.cache_creation), n($b.cache_creation)] | max)
    };
    def safe_key($v; $fallback):
      (($v // $fallback) | tostring
       | explode | map(if . < 32 or . == 127 then 63 else . end) | implode
       | gsub("[|`]"; "_")) as $s
      | if ($s | length) == 0 then $fallback
        elif ($s | length) > 96 then ($s[0:95] + "…")
        else $s end;
    def safe_agent_id($v):
      (($v // "") | tostring
       | explode | map(if . < 32 or . == 127 then 63 else . end) | implode
       | gsub("[|`]"; "_")) as $s
      | if ($s | length) > 128 then $s[0:128] else $s end;
    def first_nonempty($values):
      [$values[] | select(. != null) | tostring | select(length > 0)]
      | first // "";
    def request_key($m):
      (first_nonempty([$m.requestId, $m.request_id, $m.message.id])
       | explode | map(if . < 32 or . == 127 then 63 else . end) | implode
       | if length > 160 then .[0:160] else . end);
    def zero_bucket: {input:0, output:0, cache_read:0, cache_creation:0};
    def zero_totals:
      {main_in:0,main_out:0,main_cache_read:0,main_cache_creation:0,
       agent_in:0,agent_out:0,agent_cache_read:0,agent_cache_creation:0,
       usage_rows:0,agent_by_role:{},agent_by_model:{},agent_by_id:{}};
    def add_bucket($obj; $key; $u):
      $obj + {($key): (($obj[$key] // zero_bucket) |
        .input          = add_n(.input;          $u.input) |
        .output         = add_n(.output;         $u.output) |
        .cache_read     = add_n(.cache_read;     $u.cache_read) |
        .cache_creation = add_n(.cache_creation; $u.cache_creation))};
    def add_record($state; $r):
      $state |
      .usage_rows = add_n(.usage_rows; 1) |
      .agent_in             = add_n(.agent_in;             $r.usage.input) |
      .agent_out            = add_n(.agent_out;            $r.usage.output) |
      .agent_cache_read     = add_n(.agent_cache_read;     $r.usage.cache_read) |
      .agent_cache_creation = add_n(.agent_cache_creation; $r.usage.cache_creation) |
      .agent_by_role  = add_bucket(.agent_by_role;  $r.role;  $r.usage) |
      .agent_by_model = add_bucket(.agent_by_model; $r.model; $r.usage) |
      if $r.agent_id_known then
        .agent_by_id = add_bucket(.agent_by_id; $r.agent_id; $r.usage)
      else . end;
    def merge_buckets($x; $y):
      reduce (($y // {}) | to_entries[]) as $e (($x // {});
        .[$e.key] = {
          input:          add_n(.[$e.key].input;          $e.value.input),
          output:         add_n(.[$e.key].output;         $e.value.output),
          cache_read:     add_n(.[$e.key].cache_read;     $e.value.cache_read),
          cache_creation: add_n(.[$e.key].cache_creation; $e.value.cache_creation)
        });
    def add_totals($a; $b): {
      main_in:             add_n($a.main_in;             $b.main_in),
      main_out:            add_n($a.main_out;            $b.main_out),
      main_cache_read:     add_n($a.main_cache_read;     $b.main_cache_read),
      main_cache_creation: add_n($a.main_cache_creation; $b.main_cache_creation),
      agent_in:             add_n($a.agent_in;             $b.agent_in),
      agent_out:            add_n($a.agent_out;            $b.agent_out),
      agent_cache_read:     add_n($a.agent_cache_read;     $b.agent_cache_read),
      agent_cache_creation: add_n($a.agent_cache_creation; $b.agent_cache_creation),
      usage_rows:           add_n($a.usage_rows;           $b.usage_rows),
      agent_by_role:  merge_buckets($a.agent_by_role;  $b.agent_by_role),
      agent_by_model: merge_buckets($a.agent_by_model; $b.agent_by_model),
      agent_by_id:    merge_buckets($a.agent_by_id;    $b.agent_by_id)
    };
    def agent_id_from_path($path):
      ($path | split("/") | last | sub("[.]jsonl$"; "") | sub("^agent-"; ""));
    def summarize($s):
      (reduce $s.order[] as $id (zero_totals;
        add_record(.; $s.by_id[$id]))) as $identified |
      (reduce $s.anonymous[] as $r ($identified; add_record(.; $r))) as $totals |
      {totals:$totals, rows:$s.rows, identity:$s.identity, bytes:$s.bytes,
       last_request:(if $s.last_id == null then null else $s.by_id[$s.last_id] end)};

    (reduce inputs as $m ({files:{}};
      (input_filename) as $snapshot |
      ($snapshots[$snapshot] // {}) as $filemeta |
      ($filemeta.original // $snapshot) as $f |
      .files[$f] = (.files[$f] // {
        rows:0,order:[],by_id:{},anonymous:[],last_id:null,
        identity:($filemeta.identity // ("path:" + $f)),
        bytes:($filemeta.bytes // 0)
      }) |
      .files[$f].rows = add_n(.files[$f].rows; 1) |
      if (($m.message.usage // null) == null) then . else
        request_key($m) as $id |
        first_nonempty([$m.attributionAgent, $m.agentType]) as $role |
        first_nonempty([$m.message.model]) as $model |
        first_nonempty([$m.agentId, $m.agent_id, agent_id_from_path($f)]) as $agent_id |
        {id:$id,usage:usage($m.message.usage),
         role:safe_key($role; "general-purpose"),
         model:safe_key($model; "unknown"),
         agent_id:safe_agent_id($agent_id),
         role_known:($role != ""),
         model_known:($model != ""),
         agent_id_known:($agent_id != "")} as $r |
        if $id == "" then
          .files[$f].anonymous += [$r]
        else
          if .files[$f].by_id[$id] == null then
            .files[$f].order += [$id] |
            .files[$f].by_id[$id] = $r
          else
            .files[$f].by_id[$id] as $old |
            .files[$f].by_id[$id] = ($r + {
              usage:max_usage($old.usage; $r.usage),
              role:(if $r.role_known then $r.role else $old.role end),
              model:(if $r.model_known then $r.model else $old.model end),
              agent_id:(if $r.agent_id_known then $r.agent_id else $old.agent_id end),
              role_known:($r.role_known or ($old.role_known // false)),
              model_known:($r.model_known or ($old.model_known // false)),
              agent_id_known:($r.agent_id_known or ($old.agent_id_known // false))
            })
          end |
          .files[$f].last_id = $id
        end
      end
    )) as $scan |
    reduce ($scan.files | to_entries[]) as $entry
      ({totals:zero_totals,files:{}};
       summarize($entry.value) as $sum |
       .totals = add_totals(.totals; $sum.totals) |
       .files[$entry.key] = ({rows:$sum.rows,identity:$sum.identity,bytes:$sum.bytes}
         + if $sum.last_request == null then {}
           else {last_request:$sum.last_request} end))
  ' -- "${snapshot_files[@]}" 2>/dev/null)"; then
    rm -rf "${snapshot_dir}"
    printf '%s\n' "${result}"
    return 0
  fi
  rm -rf "${snapshot_dir}"
  return 1
}

_timing_capture_session_tokens_locked() {
  local transcript="$1" prompt_seq="$2"
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 0
  fi
  local files=("${transcript}") file agent_dir
  agent_dir="${transcript%.jsonl}/subagents"

  local cursors totals initialized legacy_cursor
  cursors="$(_timing_read_state_json_object \
    "token_transcript_cursors" 2>/dev/null || printf '{}')"
  totals="$(_timing_read_state_json_object \
    "token_totals" 2>/dev/null || printf '{}')"
  initialized="$(_timing_read_state_uint \
    "token_tracking_initialized" 1 2>/dev/null || true)"
  legacy_cursor="$(_timing_read_state_uint \
    "token_transcript_rows" 2>/dev/null || true)"

  local agent_manifest previous_agent_manifest agent_manifest_to_store
  local cursor_keys_wrapped previous_manifest_wrapped manifest_line manifest_file
  local new_agent_files=() new_agent_specs=()
  agent_manifest="$(_timing_agent_transcript_manifest "${agent_dir}" 2>/dev/null || true)"
  previous_agent_manifest="$(_timing_read_state_text_no_nul \
    "token_agent_transcript_manifest" 2>/dev/null || true)"
  agent_manifest_to_store="${agent_manifest}"
  if [[ "${agent_manifest}" != "${previous_agent_manifest}" && -d "${agent_dir}" ]]; then
    cursor_keys_wrapped=$'\n'"$(jq -r '
      keys[] | select(length <= 4096 and (contains("\u0000") | not))
    ' <<<"${cursors}" 2>/dev/null || true)"$'\n'
    previous_manifest_wrapped=$'\n'"${previous_agent_manifest}"$'\n'
    while IFS= read -r manifest_line; do
      [[ -n "${manifest_line}" ]] || continue
      # Exact stat line already covered by the prior manifest: another file
      # changed, but this completed sidechain did not. Skip it without stat,
      # wc, cursor jq, or a parser process.
      if [[ "${previous_manifest_wrapped}" == *$'\n'"${manifest_line}"$'\n'* ]]; then
        continue
      fi
      manifest_file="${manifest_line%%$'\t'*}"
      [[ -n "${manifest_file}" ]] || continue
      if [[ "${cursor_keys_wrapped}" == *$'\n'"${manifest_file}"$'\n'* ]]; then
        # Existing file grew or was replaced: preserve its trailing-request
        # delta semantics through the normal single-file path.
        files[${#files[@]}]="${manifest_file}"
      else
        # Brand-new completed sidechains share one batch parser below.
        new_agent_files[${#new_agent_files[@]}]="${manifest_file}"
        new_agent_specs[${#new_agent_specs[@]}]="${manifest_line}"
      fi
    done <<<"${agent_manifest}"
  fi

  local first_initialization=0
  [[ "${initialized}" == "1" ]] || first_initialization=1

  local delta='{}' identity total_rows total_bytes entry prior_identity cursor byte_cursor source
  local prior_request last_request slice_result slice seed_result rows_scanned
  local row_scan_mode parse_needed cursor_bytes_to_write snapshot_complete current_size current_identity
  local batch_result batch_slice merged_cursors updated_cursors merged_token_totals
  local agent_manifest_complete=1

  if (( ${#new_agent_files[@]} > 0 )); then
    if batch_result="$(_timing_sum_new_agent_files "${new_agent_specs[@]}")" \
        && jq -e '(.totals | type == "object") and (.files | type == "object")' \
          <<<"${batch_result}" >/dev/null 2>&1; then
      batch_slice="$(jq -c '.totals' <<<"${batch_result}" 2>/dev/null || printf '{}')"
      merged_cursors="$(jq -c --argjson batch "${batch_result}" '
          reduce ($batch.files | to_entries[]) as $entry (.;
            .[$entry.key] = ({
              identity:($entry.value.identity // ("path:" + $entry.key)),
              rows:($entry.value.rows // 0),
              bytes:($entry.value.bytes // 0)
            } + if ($entry.value.last_request // null) == null then {}
                else {last_request:$entry.value.last_request} end)
          )
        ' <<<"${cursors}" 2>/dev/null || true)"
      if jq -e 'type == "object"' <<<"${merged_cursors:-null}" >/dev/null 2>&1; then
        cursors="${merged_cursors}"
        # Upgrade/mid-session enable seeds cursors and trailing request state
        # but deliberately does not backfill historical economics. Merge the
        # delta only after its cursor update exists: cursor+totals are one
        # transaction, so a local merge failure can never count without a
        # dedupe boundary (or advance without counting).
        if (( first_initialization == 0 || prompt_seq <= 1 )); then
          if ! merged_token_totals="$(_timing_add_token_totals "${delta}" "${batch_slice}")"; then
            return 1
          fi
          delta="${merged_token_totals}"
        fi
      else
        for file in "${new_agent_files[@]}"; do
          files[${#files[@]}]="${file}"
        done
      fi
    else
      # A partially written row makes the all-file jq fail. Retry each file
      # independently so healthy sidechains still advance and the incomplete
      # one remains retryable on the next capture.
      for file in "${new_agent_files[@]}"; do
        files[${#files[@]}]="${file}"
      done
    fi
  fi

  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    identity="$(_timing_file_identity "${file}" 2>/dev/null || true)"
    [[ -n "${identity}" ]] || continue
    total_bytes="$(_timing_file_size "${file}" 2>/dev/null || true)"
    _timing_uint_is_valid "${total_bytes}" || continue
    snapshot_complete=0
    _timing_snapshot_ends_line "${file}" "${total_bytes}" && snapshot_complete=1
    entry="$(jq -c --arg f "${file}" '.[$f] // {}' <<<"${cursors}" 2>/dev/null || printf '{}')"
    prior_identity="$(jq -er '
      .identity
      | select(type == "string" and length <= 8192
          and (contains("\u0000") | not))
    ' <<<"${entry}" 2>/dev/null || true)"
    cursor="$(jq -er '
      .rows
      | select(type == "number" and floor == . and . >= 0
          and . <= 999999999999999)
    ' <<<"${entry}" 2>/dev/null || printf '0')"
    byte_cursor="$(jq -er '
      .bytes
      | select(type == "number" and floor == . and . >= 0
          and . <= 999999999999999)
    ' <<<"${entry}" 2>/dev/null || true)"
    prior_request="$(jq -c '.last_request // null' <<<"${entry}" 2>/dev/null || printf 'null')"
    jq -e 'type == "object" or . == null' <<<"${prior_request}" >/dev/null 2>&1 || prior_request='null'

    source="main"
    [[ "${file}" == "${transcript}" ]] || source="agent"
    row_scan_mode=0
    total_rows="${cursor}"

    if [[ -z "${prior_identity}" ]]; then
      if [[ "${file}" == "${transcript}" && -n "${legacy_cursor}" ]]; then
        # One-time migration from the old row-only parent cursor. Bound the
        # extraction by the already-computed final row so BSD tail never walks
        # the entire transcript looking for an open-ended line boundary.
        row_scan_mode=1
        total_rows="$(_timing_snapshot_line_count "${file}" "${total_bytes}" 2>/dev/null || echo 0)"
        _timing_uint_is_valid "${total_rows}" || total_rows=0
        cursor="${legacy_cursor}"
      elif (( first_initialization == 1 && prompt_seq > 1 )); then
        # Tracking enabled/upgraded mid-session: seed all files that already
        # exist. Files created after this initialization start at row zero.
        seed_result=""
        if (( snapshot_complete == 1 )); then
          seed_result="$(_timing_sum_token_slice "${file}" 1 "${source}" null 0 0 \
            "${total_bytes}" 2>/dev/null || true)"
        fi
        rows_scanned="$(jq -r '.rows_scanned // empty' <<<"${seed_result:-null}" 2>/dev/null || true)"
        if _timing_uint_is_valid "${rows_scanned}"; then
          cursor="${rows_scanned}"
          total_rows="${rows_scanned}"
          byte_cursor="${total_bytes}"
          prior_request="$(jq -c '.last_request // null' <<<"${seed_result}" 2>/dev/null || printf 'null')"
        else
          # A partial trailing JSON row is not a reason to back-charge history
          # on the next Stop. Seed only complete rows and leave the byte cursor
          # absent; the migration path retries the completed line later.
          total_rows="$(_timing_snapshot_line_count "${file}" "${total_bytes}" 2>/dev/null || echo 0)"
          _timing_uint_is_valid "${total_rows}" || total_rows=0
          cursor="${total_rows}"
          byte_cursor=""
        fi
      else
        cursor=0
        total_rows=0
        byte_cursor=0
      fi
      # Upgrade/mid-enable seeding skips historical token totals, but still
      # records the request that straddles the seeded cursor. Otherwise the
      # next content-block row for that already-running request would be
      # misclassified as a brand-new API call.
      if (( cursor > total_rows )); then
        cursor=0
        total_rows=0
        byte_cursor=0
        row_scan_mode=0
      elif (( cursor > 0 )); then
        if [[ "${prior_request}" == "null" ]]; then
          seed_result="$(_timing_sum_token_slice "${file}" 1 "${source}" null "${cursor}" 2>/dev/null || true)"
          prior_request="$(jq -c '.last_request // null' <<<"${seed_result:-null}" 2>/dev/null || printf 'null')"
        fi
      fi
    elif [[ "${prior_identity}" != "${identity}" ]] \
        || { [[ -n "${byte_cursor}" ]] && (( total_bytes < byte_cursor )); }; then
      # Replacement or compaction rewrite: the new content is real work and
      # must be counted from its beginning.
      cursor=0
      total_rows=0
      byte_cursor=0
      prior_request='null'
    elif [[ -z "${byte_cursor}" ]]; then
      # Upgrade path for cursors written before byte offsets existed. This is
      # the only steady-state branch that pays for wc/sed over old history.
      row_scan_mode=1
      total_rows="$(_timing_snapshot_line_count "${file}" "${total_bytes}" 2>/dev/null || echo 0)"
      _timing_uint_is_valid "${total_rows}" || total_rows=0
      if (( total_rows < cursor )); then
        cursor=0
        total_rows=0
        byte_cursor=0
        row_scan_mode=0
        prior_request='null'
      fi
    fi

    last_request="${prior_request}"
    parse_needed=0
    if (( row_scan_mode == 1 && total_rows > cursor )); then
      parse_needed=1
      slice_result="$(_timing_sum_token_slice "${file}" "$((cursor + 1))" \
        "${source}" "${prior_request}" "${total_rows}" 2>/dev/null || true)"
    elif (( row_scan_mode == 0 )) \
        && [[ -n "${byte_cursor}" ]] \
        && (( total_bytes > byte_cursor && snapshot_complete == 1 )); then
      parse_needed=1
      slice_result="$(_timing_sum_token_slice "${file}" 1 \
        "${source}" "${prior_request}" 0 "${byte_cursor}" "${total_bytes}" 2>/dev/null || true)"
    fi
    if (( parse_needed == 1 )); then
      # Do not advance this file's cursor on a parse failure. That makes a
      # partially-written final JSONL row retryable at the next Stop.
      if ! jq -e '(.totals | type == "object") and ((.rows_scanned // -1) >= 0)' \
          <<<"${slice_result:-null}" >/dev/null 2>&1; then
        [[ "${source}" == "agent" ]] && agent_manifest_complete=0
        continue
      fi
      slice="$(jq -c '.totals' <<<"${slice_result}" 2>/dev/null || true)"
      rows_scanned="$(jq -r '.rows_scanned' <<<"${slice_result}" 2>/dev/null || printf '0')"
      _timing_uint_is_valid "${rows_scanned}" || rows_scanned=0
      if (( row_scan_mode == 0 )); then
        if (( rows_scanned > _TIMING_UINT_MAX - cursor )); then
          [[ "${source}" == "agent" ]] && agent_manifest_complete=0
          continue
        fi
        total_rows=$((cursor + rows_scanned))
      fi
      last_request="$(jq -c '.last_request // null' <<<"${slice_result}" 2>/dev/null || printf 'null')"
    fi
    # Reject a shrink/replacement that raced the bounded read. Appends are
    # safe: only bytes through total_bytes were parsed and the later suffix is
    # intentionally left for the next Stop.
    if (( parse_needed == 1 )); then
      current_size="$(_timing_file_size "${file}" 2>/dev/null || true)"
      current_identity="$(_timing_file_identity "${file}" 2>/dev/null || true)"
      if ! _timing_uint_is_valid "${current_size}" \
          || (( current_size < total_bytes )) \
          || [[ "${current_identity}" != "${identity}" ]]; then
        [[ "${source}" == "agent" ]] && agent_manifest_complete=0
        continue
      fi
    fi

    if (( snapshot_complete == 1 )); then
      cursor_bytes_to_write="${total_bytes}"
    elif (( row_scan_mode == 1 )); then
      # A legacy row cursor can advance through complete records before a
      # partial tail, but no byte offset may point into that unfinished JSON.
      # Stay in bounded row-migration mode until the fragment completes.
      cursor_bytes_to_write=""
    else
      # Do not parse or advance beyond a partial suffix. Keeping the prior
      # complete-line byte offset makes the entire suffix retryable.
      cursor_bytes_to_write="${byte_cursor}"
      [[ "${source}" == "agent" ]] && agent_manifest_complete=0
    fi
    updated_cursors="$(jq -c --arg f "${file}" --arg ident "${identity}" --argjson rows "${total_rows}" \
      --arg bytes "${cursor_bytes_to_write}" --argjson last "${last_request}" \
      '.[$f] = ({identity:$ident, rows:$rows}
        + if ($bytes | test("^[0-9]+$")) then {bytes:($bytes | tonumber)} else {} end
        + if $last == null then {} else {last_request:$last} end)' \
      <<<"${cursors}" 2>/dev/null || true)"
    if ! jq -e 'type == "object"' <<<"${updated_cursors:-null}" >/dev/null 2>&1; then
      [[ "${source}" == "agent" ]] && agent_manifest_complete=0
      continue
    fi
    cursors="${updated_cursors}"
    if (( parse_needed == 1 )); then
      if ! merged_token_totals="$(_timing_add_token_totals "${delta}" "${slice}")"; then
        return 1
      fi
      delta="${merged_token_totals}"
    fi
  done

  if (( agent_manifest_complete == 0 )); then
    agent_manifest_to_store="${previous_agent_manifest}"
  fi

  if ! merged_token_totals="$(_timing_add_token_totals "${totals}" "${delta}")"; then
    return 1
  fi
  totals="${merged_token_totals}"
  local main_rows=0
  main_rows="$(jq -er --arg f "${transcript}" '
    .[$f].rows
    | select(type == "number" and floor == . and . >= 0
        and . <= 999999999999999)
  ' <<<"${cursors}" 2>/dev/null || printf '0')"
  _timing_uint_is_valid "${main_rows}" || main_rows=0
  # State is the durable side of the transaction. Never append a delta after
  # a failed cursor/totals commit: the next Stop would retry the same slice and
  # double-count prompt detail. Conversely, if a later JSONL append fails, the
  # committed totals are safe and the next Stop re-emits a self-healing
  # checkpoint even with no new transcript rows.
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 0
  fi
  if ! write_state_batch \
      "token_transcript_cursors" "${cursors}" \
      "token_agent_transcript_manifest" "${agent_manifest_to_store}" \
      "token_tracking_initialized" "1" \
      "token_transcript_rows" "${main_rows}" \
      "token_totals" "${totals}" 2>/dev/null; then
    return 1
  fi

  local ts delta_has_tokens row="" checkpoint=""
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
  delta_has_tokens="$(jq -r '
    [.main_in,.main_out,.main_cache_read,.main_cache_creation,
     .agent_in,.agent_out,.agent_cache_read,.agent_cache_creation]
    | if any(.[]; type == "number" and floor == .
                  and . > 0 and . <= 999999999999999)
      then 1 else 0 end
  ' <<<"${delta}" 2>/dev/null || printf '0')"
  _timing_uint_is_valid "${delta_has_tokens}" || delta_has_tokens=0
  ensure_session_dir 2>/dev/null || return 0
  if (( delta_has_tokens > 0 )); then
    row="$(jq -nc --argjson ts "${ts}" --argjson ps "${prompt_seq}" --argjson d "${delta}" \
      '{kind:"token_delta",ts:$ts,prompt_seq:$ps} + $d' 2>/dev/null || true)"
  fi
  # Always refresh a non-zero checkpoint, even when no file had new rows.
  # This makes a state-write/log-append interruption self-healing.
  local total_has_tokens
  total_has_tokens="$(jq -r '
    [.main_in,.main_out,.main_cache_read,.main_cache_creation,
     .agent_in,.agent_out,.agent_cache_read,.agent_cache_creation]
    | if any(.[]; type == "number" and floor == .
                  and . > 0 and . <= 999999999999999)
      then 1 else 0 end
  ' <<<"${totals}" 2>/dev/null || printf '0')"
  _timing_uint_is_valid "${total_has_tokens}" || total_has_tokens=0
  if (( total_has_tokens > 0 )); then
    checkpoint="$(jq -nc --argjson ts "${ts}" --argjson ps "${prompt_seq}" --argjson t "${totals}" \
      '{kind:"token_checkpoint",ts:$ts,prompt_seq:$ps} + $t' 2>/dev/null || true)"
  fi
  local timing_target
  timing_target="$(timing_log_path)"
  if [[ -n "${row}" || -n "${checkpoint}" ]]; then
    with_cross_session_log_lock "${timing_target}" \
      _timing_append_token_rows_locked \
        "${timing_target}" "${row}" "${checkpoint}" \
      2>/dev/null || true
  fi
}

timing_capture_session_tokens() {
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 0
  fi
  is_time_tracking_enabled || return 0
  is_token_tracking_enabled || return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local transcript="${1:-}" prompt_seq="${2:-0}"
  _timing_uint_is_valid "${prompt_seq}" || prompt_seq=0
  [[ -n "${transcript}" && -f "${transcript}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Stop and SubagentStop events can overlap. Cursor advancement, cumulative
  # total update, and JSONL append form one per-session transaction.
  with_state_lock _timing_capture_session_tokens_locked "${transcript}" "${prompt_seq}" 2>/dev/null || true
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
  _timing_uint_is_valid "${prompt_filter}" || prompt_filter=0

  if [[ ! -f "${log}" ]] || [[ ! -s "${log}" ]]; then
    printf '%s\n' '{}'
    return 0
  fi

  # Read raw lines and parse them independently. A killed append can leave one
  # truncated JSON value in the middle/tail; valid later checkpoints must still
  # self-heal the aggregate instead of the whole session collapsing to `{}`.
  jq -Rsc --argjson pfilter "${prompt_filter}" '
    def canonical_uint:
      type == "number" and floor == . and . >= 0 and . <= 999999999999999;
    def uint:
      if canonical_uint then
        (if . > 999999999999999 then 999999999999999 else . end)
      else 0 end;
    def clamp_uint:
      if type == "number" and floor == . and . >= 0 then
        (if . > 999999999999999 then 999999999999999 else . end)
      else 0 end;
    def add_uint($left; $right):
      (($left | uint) + ($right | uint))
      | if . > 999999999999999 then 999999999999999 else . end;
    def sum_uint:
      reduce .[] as $value (0; add_uint(.; $value));
    def safe_bucket_map:
      if type != "object" then {}
      else with_entries(
        .value = ((.value // {}) |
          if type == "object" then {
            input: ((.input // 0) | uint),
            output: ((.output // 0) | uint),
            cache_read: ((.cache_read // 0) | uint),
            cache_creation: ((.cache_creation // 0) | uint)
          } else {input:0,output:0,cache_read:0,cache_creation:0} end)
      ) end;
    def bucket_map_numeric_fields_valid:
      . as $map
      | type == "object"
        and all(($map | to_entries[]); .value as $bucket
          | ($bucket | type) == "object"
            and all(["input","output","cache_read","cache_creation"][];
              . as $key
              | (($bucket | has($key) | not)
                  or ($bucket[$key] | canonical_uint))));
    def numeric_fields_valid:
      . as $o
      | (all([
          "ts","prompt_seq","duration_s","chars",
          "main_in","main_out","main_cache_read","main_cache_creation",
          "agent_in","agent_out","agent_cache_read","agent_cache_creation",
          "usage_rows"
          ][]; . as $k
          | (($o | has($k) | not)
             or (($o[$k] | type) == "number"
                 and ($o[$k] | floor) == $o[$k]
                 and $o[$k] >= 0 and $o[$k] <= 999999999999999)))
        and all(["agent_by_role","agent_by_model","agent_by_id"][];
          . as $key
          | (($o | has($key) | not)
              or ($o[$key] | bucket_map_numeric_fields_valid))));
    def kind_fields_valid:
      . as $o
      | (($o.kind | type) == "string")
        and ($o.kind == "prompt_start" or $o.kind == "prompt_end"
          or $o.kind == "directive_emitted" or $o.kind == "token_delta"
          or $o.kind == "token_checkpoint" or $o.kind == "start"
          or $o.kind == "end")
        and ($o | has("ts")) and ($o.ts | canonical_uint) and ($o.ts > 0)
        and ($o | has("prompt_seq")) and ($o.prompt_seq | canonical_uint)
        and (if $o.kind == "prompt_end" then
               ($o | has("duration_s")) and ($o.duration_s | canonical_uint)
             elif $o.kind == "directive_emitted" then
               ($o | has("chars")) and ($o.chars | canonical_uint)
               and (($o.name | type) == "string")
               and ($o.name | length) > 0 and ($o.name | length) <= 160
             elif $o.kind == "token_delta" or $o.kind == "token_checkpoint" then
               any(["main_in","main_out","main_cache_read",
                 "main_cache_creation","agent_in","agent_out",
                 "agent_cache_read","agent_cache_creation"][];
                 . as $key | $o | has($key))
             elif $o.kind == "start" or $o.kind == "end" then
               (($o.tool | type) == "string")
               and ($o.tool | length) > 0 and ($o.tool | length) <= 160
             else true end);
    def normalize_row:
      . as $raw
      | reduce [
          "ts","prompt_seq","duration_s","chars",
          "main_in","main_out","main_cache_read","main_cache_creation",
          "agent_in","agent_out","agent_cache_read","agent_cache_creation",
          "usage_rows"
        ][] as $k (.;
          if has($k) then .[$k] = (.[$k] | uint) else . end)
      | .kind = ((.kind // "") | if type == "string" then . else "" end)
      | .tool = ((.tool // "") | if type == "string" then . else "" end)
      | .subagent = ((.subagent // "") | if type == "string" then . else "" end)
      | .name = ((.name // "") | if type == "string" then . else "" end)
      | .agent_by_role = ((.agent_by_role // {}) | safe_bucket_map)
      | .agent_by_model = ((.agent_by_model // {}) | safe_bucket_map)
      | .agent_by_id = ((.agent_by_id // {}) | safe_bucket_map)
      | ._timing_numeric_valid = ($raw
          | (numeric_fields_valid and kind_fields_valid));

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

    def merge_token_buckets($x; $y):
      reduce (($y | safe_bucket_map) | to_entries[]) as $e (($x | safe_bucket_map);
        .[$e.key] = {
          input: add_uint((.[$e.key].input // 0); ($e.value.input // 0)),
          output: add_uint((.[$e.key].output // 0); ($e.value.output // 0)),
          cache_read: add_uint((.[$e.key].cache_read // 0); ($e.value.cache_read // 0)),
          cache_creation: add_uint((.[$e.key].cache_creation // 0); ($e.value.cache_creation // 0))
        }
      );
    def checkpoint_token_total($x):
      # Eight canonical components total at most 7,999,999,999,999,992,
      # still below the jq/IEEE-754 exact-integer ceiling. Do not route this
      # comparison-only sum through the one-field saturating helper: two
      # same-second cumulative checkpoints above that smaller ceiling would
      # otherwise tie and leave the older checkpoint authoritative.
      reduce [($x.main_in // 0), ($x.main_out // 0),
              ($x.main_cache_read // 0), ($x.main_cache_creation // 0),
              ($x.agent_in // 0), ($x.agent_out // 0),
              ($x.agent_cache_read // 0), ($x.agent_cache_creation // 0)][]
        as $value (0; . + ($value | uint));
    def checkpoint_key($x):
      [($x.prompt_seq // 0), ($x.ts // 0), checkpoint_token_total($x)];

    [split("\n")[]
      | select(length > 0)
      | (try fromjson catch empty)
      | select(type == "object")
      | normalize_row
      | select(._timing_numeric_valid == true)
    ] as $parsed |

    # Optional prompt_seq slice: only retain rows tagged with the requested
    # prompt_seq when pfilter > 0. Untagged rows (legacy / pre-router
    # captures) are dropped from a slice but kept in whole-session aggregation.
    [$parsed[] | select(
      ($pfilter == 0) or ((.prompt_seq // 0) == $pfilter)
    )] as $rows |

    (reduce $rows[] as $r (
      { pending: [], agent: {}, tool: {}, agent_n: {}, tool_n: {}, dir_chars: {}, dir_n: {}, prompts: [], orphan_end: 0,
        tk_min: 0, tk_mout: 0, tk_mcr: 0, tk_mcw: 0, tk_ain: 0, tk_aout: 0, tk_acr: 0, tk_acw: 0,
        tk_usage_rows: 0, tk_roles: {}, tk_models: {}, tk_ids: {}, tk_checkpoint: null };
      if $r.kind == "prompt_start" then
        .prompts += [{ ps: ($r.prompt_seq // 0), start: $r.ts, end: null, dur: 0 }]
      elif $r.kind == "prompt_end" then
        .prompts |= map(
          if .ps == ($r.prompt_seq // 0) and .end == null then
            . + { end: $r.ts,
                  dur: (($r.duration_s // ($r.ts - .start)) | uint) }
          else . end
        )
      elif $r.kind == "directive_emitted" then
        (($r.name // "") | tostring) as $name |
        (($r.chars // 0) | tonumber? // 0) as $chars |
        if $name == "" or $chars <= 0 then
          .
        else
          .dir_chars[$name] = add_uint((.dir_chars[$name] // 0); $chars) |
          .dir_n[$name] = add_uint((.dir_n[$name] // 0); 1)
        end
      elif $r.kind == "token_delta" then
        .tk_min = add_uint(.tk_min; ($r.main_in // 0)) |
        .tk_mout = add_uint(.tk_mout; ($r.main_out // 0)) |
        .tk_mcr = add_uint(.tk_mcr; ($r.main_cache_read // 0)) |
        .tk_mcw = add_uint(.tk_mcw; ($r.main_cache_creation // 0)) |
        .tk_ain = add_uint(.tk_ain; ($r.agent_in // 0)) |
        .tk_aout = add_uint(.tk_aout; ($r.agent_out // 0)) |
        .tk_acr = add_uint(.tk_acr; ($r.agent_cache_read // 0)) |
        .tk_acw = add_uint(.tk_acw; ($r.agent_cache_creation // 0)) |
        .tk_usage_rows = add_uint(.tk_usage_rows; ($r.usage_rows // 0)) |
        .tk_roles = merge_token_buckets(.tk_roles; $r.agent_by_role) |
        .tk_models = merge_token_buckets(.tk_models; $r.agent_by_model) |
        .tk_ids = merge_token_buckets(.tk_ids; $r.agent_by_id)
      elif $r.kind == "token_checkpoint" and $pfilter == 0
          and ($r._timing_numeric_valid == true) then
        # Checkpoints are cumulative and supersede detail rows for whole-
        # session aggregation. Prompt slices deliberately continue to use
        # token_delta rows so /ulw-time last-prompt is not inflated. Select
        # chronologically by prompt_seq/ts (total breaks same-second ties),
        # rather than trusting physical JSONL order after recovery/rotation.
        if .tk_checkpoint == null or checkpoint_key($r) > checkpoint_key(.tk_checkpoint)
        then .tk_checkpoint = $r else . end
      elif $r.kind == "start" then
        .pending += [$r]
      elif $r.kind == "end" then
        find_match(.pending; $r) as $m |
        if $m == null then
          .orphan_end = add_uint(.orphan_end; 1)
        else
          (($r.ts - $m.value.ts) | uint) as $dur |
          (.pending |= (.[:$m.key] + .[$m.key+1:])) |
          if $r.tool == "Agent" then
            (($m.value.subagent // "general-purpose")) as $sub |
            .agent[$sub] = add_uint((.agent[$sub] // 0); $dur) |
            .agent_n[$sub] = add_uint((.agent_n[$sub] // 0); 1)
          else
            .tool[$r.tool] = add_uint((.tool[$r.tool] // 0); $dur) |
            .tool_n[$r.tool] = add_uint((.tool_n[$r.tool] // 0); 1)
          end
        end
      else .
      end
    )) as $st |
    (if $st.tk_checkpoint != null then $st.tk_checkpoint else {
      main_in:$st.tk_min, main_out:$st.tk_mout,
      main_cache_read:$st.tk_mcr, main_cache_creation:$st.tk_mcw,
      agent_in:$st.tk_ain, agent_out:$st.tk_aout,
      agent_cache_read:$st.tk_acr, agent_cache_creation:$st.tk_acw,
      usage_rows:$st.tk_usage_rows,
      agent_by_role:$st.tk_roles, agent_by_model:$st.tk_models,
      agent_by_id:$st.tk_ids
    } end) as $tk |
    {
      walltime_s:       ([$st.prompts[] | select(.end != null) | .dur] | sum_uint),
      agent_total_s:    ([$st.agent[]] | sum_uint),
      agent_breakdown:  $st.agent,
      agent_calls:      $st.agent_n,
      tool_total_s:     ([$st.tool[]] | sum_uint),
      tool_breakdown:   $st.tool,
      tool_calls:       $st.tool_n,
      directive_total_chars: ([$st.dir_chars[]] | sum_uint),
      directive_breakdown: $st.dir_chars,
      directive_counts: $st.dir_n,
      directive_count: ([$st.dir_n[]] | sum_uint),
      prompt_count:     (([$st.prompts[] | select(.end != null)] | length) | uint),
      prompts_seq:      [$st.prompts[] | select(.end != null) | {ps:.ps, dur:.dur}],
      active_pending:   (($st.pending | length) | uint),
      orphan_end_count: ($st.orphan_end | uint),
      tokens_main_in:             (($tk.main_in // 0) | uint),
      tokens_main_out:            (($tk.main_out // 0) | uint),
      tokens_main_cache_read:     (($tk.main_cache_read // 0) | uint),
      tokens_main_cache_creation: (($tk.main_cache_creation // 0) | uint),
      tokens_agent_in:             (($tk.agent_in // 0) | uint),
      tokens_agent_out:            (($tk.agent_out // 0) | uint),
      tokens_agent_cache_read:     (($tk.agent_cache_read // 0) | uint),
      tokens_agent_cache_creation: (($tk.agent_cache_creation // 0) | uint),
      token_usage_rows:             (($tk.usage_rows // 0) | uint),
      agent_tokens_by_role:         (($tk.agent_by_role // {}) | safe_bucket_map),
      agent_tokens_by_model:        (($tk.agent_by_model // {}) | safe_bucket_map),
      agent_tokens_by_id:           (($tk.agent_by_id // {}) | safe_bucket_map)
    }
    | . + {
        idle_model_s: ((.walltime_s - .agent_total_s - .tool_total_s) | uint),
        # v1.34.1+ (data-lens D-002 / design-lens X-002):
        # When parallel agents/tools complete in less wall-time than their
        # serial work-time would suggest (i.e., agent + tool > walltime),
        # surface the parallelism overhead as a positive quantity. The
        # `agents X% · tools Y% · idle Z%` bar in show-time.sh / show-status.sh
        # otherwise reads as broken (X+Y+Z > 100) when callers naively
        # divide work-time by walltime — exposing this field lets the
        # renderers either disclose the overlap explicitly OR re-normalize.
        # Always non-negative; 0 when work fits inside walltime.
        concurrent_overhead_s: ((.agent_total_s + .tool_total_s - .walltime_s) | clamp_uint)
      }
  ' < "${log}" 2>/dev/null || printf '%s\n' '{}'
}

# --- Format helpers ---

# Canonical bounded decimal for Bash arithmetic. JSON imports and legacy state
# may contain digit strings such as "08" (octal syntax to Bash) or values large
# enough to wrap signed arithmetic. Strip leading zeroes without a subprocess
# and cap at 15 digits so the eight-field token sums and percentage products
# remain below signed 64-bit limits.
timing_normalize_uint() {
  local n="${1:-0}"
  [[ "${n}" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  n="${n#"${n%%[!0]*}"}"
  [[ -n "${n}" ]] || n=0
  if (( ${#n} > 15 )); then
    n=999999999999999
  fi
  printf '%s' "${n}"
}

timing_normalize_token_sum_uint() {
  local n="${1:-0}" max="${_TIMING_TOKEN_SUM_MAX}" LC_ALL=C
  [[ "${n}" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  n="${n#"${n%%[!0]*}"}"
  [[ -n "${n}" ]] || n=0
  if (( ${#n} > ${#max} )) \
      || { (( ${#n} == ${#max} )) && (( 10#${n} > max )); }; then
    n="${max}"
  fi
  printf '%s' "${n}"
}

# Format integer seconds as a compact human string ("0s", "12s", "3m 04s",
# "1h 23m"). Used by every surface (Stop epilogue, /ulw-time, status, report).
timing_fmt_secs() {
  local s
  s="$(timing_normalize_uint "${1:-0}")"
  if (( s < 60 )); then
    printf '%ds' "${s}"
  elif (( s < 3600 )); then
    printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# timing_fmt_tokens <n> — compact token-count formatter (1234567 -> "1.2M",
# 12345 -> "12.3K", 920 -> "920"). Integer-only math (bash 3.2 safe; no
# floating point). Used by the token line in the time card, /ulw-status,
# and /ulw-report.
timing_fmt_tokens() {
  local n
  n="$(timing_normalize_token_sum_uint "${1:-0}")"
  if (( n >= 1000000 )); then
    printf '%d.%dM' $(( n / 1000000 )) $(( (n % 1000000) / 100000 ))
  elif (( n >= 1000 )); then
    printf '%d.%dK' $(( n / 1000 )) $(( (n % 1000) / 100 ))
  else
    printf '%d' "${n}"
  fi
}

# timing_token_line <agg_json> — render the one-line token summary for the
# time card / status / report, or empty string when no token data exists.
# Shape: "tokens   in 1.2M (89% cached) · out 340K · agents 45%".
#   in        = input_tokens + cache_read + cache_creation (full input side)
#   cached %  = cache_read / in  (share of input served from cache)
#   out       = output_tokens
#   agents %  = agent token share of the grand total (omitted when no agents)
# Pure formatter — no I/O. Returns 0 always.
timing_token_line() {
  local agg="${1:-}"
  [[ -z "${agg}" ]] && return 0
  local m_in m_out m_cr m_cw a_in a_out a_cr a_cw
  m_in="$(jq -r '.tokens_main_in // 0' <<<"${agg}" 2>/dev/null)"
  m_out="$(jq -r '.tokens_main_out // 0' <<<"${agg}" 2>/dev/null)"
  m_cr="$(jq -r '.tokens_main_cache_read // 0' <<<"${agg}" 2>/dev/null)"
  m_cw="$(jq -r '.tokens_main_cache_creation // 0' <<<"${agg}" 2>/dev/null)"
  a_in="$(jq -r '.tokens_agent_in // 0' <<<"${agg}" 2>/dev/null)"
  a_out="$(jq -r '.tokens_agent_out // 0' <<<"${agg}" 2>/dev/null)"
  a_cr="$(jq -r '.tokens_agent_cache_read // 0' <<<"${agg}" 2>/dev/null)"
  a_cw="$(jq -r '.tokens_agent_cache_creation // 0' <<<"${agg}" 2>/dev/null)"
  local v
  for v in m_in m_out m_cr m_cw a_in a_out a_cr a_cw; do
    printf -v "${v}" '%s' "$(timing_normalize_uint "${!v}")"
  done

  local in_total out_total cache_read_total agent_total grand
  in_total=$(( m_in + m_cr + m_cw + a_in + a_cr + a_cw ))
  out_total=$(( m_out + a_out ))
  cache_read_total=$(( m_cr + a_cr ))
  agent_total=$(( a_in + a_out + a_cr + a_cw ))
  grand=$(( in_total + out_total ))
  (( grand == 0 )) && return 0

  local cached_pct=0
  (( in_total > 0 )) && cached_pct=$(( cache_read_total * 100 / in_total ))
  local line
  line="$(printf 'tokens   in %s (%d%% cached) · out %s' \
    "$(timing_fmt_tokens "${in_total}")" "${cached_pct}" "$(timing_fmt_tokens "${out_total}")")"
  if (( agent_total > 0 )); then
    local agent_pct=$(( agent_total * 100 / grand ))
    line="${line} · agents ${agent_pct}%"
  fi
  printf '%s' "${line}"
}

# timing_format_oneline <agg_json>
#   One-line distribution string suitable for Stop additionalContext.
#   Returns empty (suppressing emission) when walltime_s < 5 (noise floor).
timing_format_oneline() {
  local agg="${1:-}"
  [[ -z "${agg}" ]] && return 0

  local walltime
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  walltime="$(timing_normalize_uint "${walltime:-0}")"

  if (( walltime < 5 )); then
    return 0
  fi

  local agent_total tool_total idle_model directive_total_chars directive_count
  agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg}" 2>/dev/null)"
  tool_total="$(jq -r '.tool_total_s // 0' <<<"${agg}" 2>/dev/null)"
  idle_model="$(jq -r '.idle_model_s // 0' <<<"${agg}" 2>/dev/null)"
  directive_total_chars="$(jq -r '.directive_total_chars // 0' <<<"${agg}" 2>/dev/null)"
  directive_count="$(jq -r '.directive_count // 0' <<<"${agg}" 2>/dev/null)"
  agent_total="$(timing_normalize_uint "${agent_total:-0}")"
  tool_total="$(timing_normalize_uint "${tool_total:-0}")"
  idle_model="$(timing_normalize_uint "${idle_model:-0}")"
  directive_total_chars="$(timing_normalize_uint "${directive_total_chars:-0}")"
  directive_count="$(timing_normalize_uint "${directive_count:-0}")"

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

  walltime="$(timing_normalize_uint "${walltime:-0}")"
  agent_total="$(timing_normalize_uint "${agent_total:-0}")"
  tool_total="$(timing_normalize_uint "${tool_total:-0}")"
  idle_model="$(timing_normalize_uint "${idle_model:-0}")"
  orphan="$(timing_normalize_uint "${orphan:-0}")"
  active_pending="$(timing_normalize_uint "${active_pending:-0}")"
  overhead="$(timing_normalize_uint "${overhead:-0}")"

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
    secs="$(timing_normalize_uint "${secs:-0}")"
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
    tsecs="$(timing_normalize_uint "${tsecs:-0}")"
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
  total_tool_calls="$(timing_normalize_uint "${total_tool_calls:-0}")"
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
  distinct_agents="$(timing_normalize_uint "${distinct_agents:-0}")"
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
  walltime="$(timing_normalize_uint "${walltime:-0}")"
  if (( walltime == 0 )); then
    # Orphan-only fall-through: surface the anomaly so a session killed
    # before any prompt finalized still produces output on manual
    # /ulw-time. The Stop hook's 5s floor independently suppresses this
    # case automatically.
    local _orphan _active _tok0
    _orphan="$(jq -r '.orphan_end_count // 0' <<<"${agg}" 2>/dev/null)"
    _active="$(jq -r '.active_pending // 0' <<<"${agg}" 2>/dev/null)"
    _orphan="$(timing_normalize_uint "${_orphan:-0}")"
    _active="$(timing_normalize_uint "${_active:-0}")"
    # Token line still renders here: a session may have captured token
    # usage before any prompt finalized (manual /ulw-time mid-turn), so
    # "no finalized prompts" should not hide the tokens already spent.
    _tok0="$(timing_token_line "${agg}")"
    if (( _orphan > 0 )) || (( _active > 0 )) || [[ -n "${_tok0}" ]]; then
      printf '─── %s ─── no finalized prompts yet\n' "${title}"
    fi
    if (( _orphan > 0 )) || (( _active > 0 )); then
      printf '  %d unfinished start%s, %d orphan end%s — likely killed mid-flight or still in-flight.\n' \
        "${_active}" "$( (( _active == 1 )) && printf '' || printf 's' )" \
        "${_orphan}" "$( (( _orphan == 1 )) && printf '' || printf 's' )"
    fi
    if [[ -n "${_tok0}" ]]; then
      printf '  %s\n' "${_tok0}"
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

  agent_total="$(timing_normalize_uint "${agent_total:-0}")"
  tool_total="$(timing_normalize_uint "${tool_total:-0}")"
  idle_model="$(timing_normalize_uint "${idle_model:-0}")"
  prompt_count="$(timing_normalize_uint "${prompt_count:-0}")"
  active_pending="$(timing_normalize_uint "${active_pending:-0}")"
  orphan_end="$(timing_normalize_uint "${orphan_end:-0}")"
  overhead="$(timing_normalize_uint "${overhead:-0}")"

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

  # Token line (v1.46-pre) — input/output/cache + agent share, when token
  # capture recorded any usage for this window. Sits below the time
  # breakdown so the card answers "where did the TOKENS go" alongside
  # "where did the TIME go". Empty (and skipped) when no token data.
  local _tok_line
  _tok_line="$(timing_token_line "${agg}")"
  if [[ -n "${_tok_line}" ]]; then
    printf '\n  %s\n' "${_tok_line}"
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
  total="$(timing_normalize_uint "${total:-0}")"
  walltime="$(timing_normalize_uint "${walltime:-0}")"

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
    total_calls="$(timing_normalize_uint "${total_calls:-0}")"
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
      secs="$(timing_normalize_uint "${secs:-0}")"
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
      calls="$(timing_normalize_uint "${calls:-0}")"
      if (( calls > 0 )); then
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
  _omc_canonical_uint_in_range "${pct_a}" 0 100 || pct_a=0
  _omc_canonical_uint_in_range "${pct_b}" 0 100 || pct_b=0
  _omc_canonical_uint_in_range "${pct_c}" 0 100 || pct_c=0
  _omc_canonical_uint_in_range "${width}" 1 1000 || width=30

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

  # v1.36.x W3 F-014: OMC_PLAIN=1 forces ASCII-only output for
  # monochrome/color-blind terminals, narrow-font logs, and clipboard
  # captures where Unicode block characters degrade to indistinguishable
  # boxes. Default (unset) keeps the high-contrast Unicode glyphs.
  local glyph_a="█" glyph_b="▒" glyph_c="░"
  case "${OMC_PLAIN:-}" in
    1|on|true|yes)
      glyph_a="#" glyph_b="=" glyph_c="."
      ;;
  esac

  local out=""
  local i
  for (( i = 0; i < n_a; i++ )); do out+="${glyph_a}"; done
  for (( i = 0; i < n_b; i++ )); do out+="${glyph_b}"; done
  for (( i = 0; i < n_c; i++ )); do out+="${glyph_c}"; done
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
  # v1.36.x W3 F-014: OMC_PLAIN=1 falls back to single-line digits 0-7
  # so the sparkline survives non-UTF8 locales / narrow fonts.
  local levels=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
  case "${OMC_PLAIN:-}" in
    1|on|true|yes)
      levels=("." "_" "-" "=" "+" "*" "%" "#")
      ;;
  esac
  local out=""
  while IFS=$'\t' read -r dur mx; do
    _timing_uint_is_valid "${dur}" || continue
    _timing_uint_is_valid "${mx}" || continue
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
  _omc_canonical_uint_in_range "${pct}" 0 100 || pct=0
  _omc_canonical_uint_in_range "${width}" 1 1000 || width=20
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
#   Deduplicated and capped under one cross-session log lock transaction.
timing_record_session_summary() {
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 0
  fi
  is_time_tracking_enabled || return 0
  local agg="${1:-}"
  [[ -z "${agg}" ]] && return 0

  local walltime token_total stale_reviewer_count
  walltime="$(jq -r '.walltime_s // 0' <<<"${agg}" 2>/dev/null)"
  walltime="$(timing_normalize_uint "${walltime:-0}")"
  # Do not throw away short, token-bearing turns. The 5-second threshold is
  # a presentation noise floor, not an economics-data threshold.
  token_total="$(jq -r '[
      (.tokens_main_in // 0), (.tokens_main_out // 0),
      (.tokens_main_cache_read // 0), (.tokens_main_cache_creation // 0),
      (.tokens_agent_in // 0), (.tokens_agent_out // 0),
      (.tokens_agent_cache_read // 0), (.tokens_agent_cache_creation // 0)
    ] | add // 0' <<<"${agg}" 2>/dev/null || printf '0')"
  token_total="$(timing_normalize_token_sum_uint "${token_total:-0}")"
  stale_reviewer_count="$(jq -r '.stale_reviewer_count // 0' <<<"${agg}" 2>/dev/null || printf '0')"
  stale_reviewer_count="$(timing_normalize_uint "${stale_reviewer_count:-0}")"
  # Stale-review causality rejections are an economics signal even when token
  # tracking is disabled or the transcript did not expose usage rows.
  (( walltime < 5 && token_total == 0 && stale_reviewer_count == 0 )) && return 0

  local sid="${SESSION_ID:-}"
  [[ -z "${sid}" ]] && return 0
  local row ts
  # v1.31.0 Wave 4 (data-lens F-3 + F-5): rename `session` field to
  # `session_id` for cross-ledger join consistency (gate_events,
  # session_summary, serendipity, classifier_misfires all use
  # `session_id`). Add `_v:1` schema_version for future migrations.
  # Pre-Wave-4 rows (with `session` field) coexist via the
  # backwards-compat dedup filter below — see the `(.session // "")`
  # / `(.session_id // "")` reads.
  ts="$(now_epoch 2>/dev/null || true)"
  _timing_epoch_is_valid "${ts}" || return 0
  row="$(jq -nc \
    --argjson ts "${ts}" \
    --arg session_id "${sid}" \
    --arg project_key "$(_omc_project_key 2>/dev/null || _omc_project_id)" \
    --argjson agg "${agg}" \
    '$agg + {_v:1,ts:$ts,session_id:$session_id,project_key:$project_key}' 2>/dev/null)"
  [[ -z "${row}" ]] && return 0

  local target
  target="$(timing_xs_log_path)"

  # Dedup-on-write: every Stop hook fires this with a fresh whole-session
  # aggregate. A multi-prompt session would otherwise accrue N monotonically
  # growing rows whose walltime_s sums incorrectly in timing_xs_aggregate.
  # Keep only the latest aggregate per session_id by rewriting the file
  # without rows whose .session matches us, then appending. Cost is O(file
  # size) per Stop, but the file is capped at 10000 rows and shrinks to
  # one-row-per-session under this rule, so steady-state is small.
  # The complete read-filter-append-rotate transaction is locked. Previously
  # only the cap helper locked, so two Stop hooks could both rewrite from the
  # same snapshot and silently lose one session summary.
  # Lock ordering is deliberately session -> cross-session. Re-check the
  # captured enforcement generation only after the session lock is held, then
  # retain that lock for the complete shared-ledger rewrite. This prevents a
  # Stop from publishing a G1 summary after it waited behind a G2 transition,
  # without introducing the inverse cross-session -> session order anywhere.
  with_state_lock _timing_record_session_summary_generation_locked \
    "${target}" "${sid}" "${row}" 2>/dev/null || true
}

_timing_record_session_summary_generation_locked() {
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 1
  fi
  local target="$1" sid="$2" row="$3"
  local transferred_session_owner="" current_resume_state=""
  local resume_ancestor_sids='[]' resume_walk_seen_sids='[]'
  local resume_child_sid="${sid}" resume_candidate_sid=""
  local resume_candidate_owner="" resume_next_sid="" resume_chain_steps=0

  # Dormant resume sources carry an ownership fence and must never publish a
  # cross-session checkpoint. Re-read this after acquiring the session lock:
  # a same-generation handoff can commit while Stop is building its aggregate.
  transferred_session_owner="$(_timing_read_state_sid \
    "resume_transferred_to" 2>/dev/null || true)"
  if [[ -n "${transferred_session_owner}" ]] \
      && [[ "${transferred_session_owner}" != "${sid}" ]] \
      && validate_session_id "${transferred_session_owner}" 2>/dev/null; then
    return 1
  fi

  # Derive the exact ancestry used by the shared-ledger rewrite while this
  # session remains locked. A can have a global summary, A→B can die before B
  # writes one, and B→C can then finish with a cumulative checkpoint. Every
  # traversed edge must be proven by source.resume_transferred_to == child;
  # corrupt/manual provenance stops the walk at the last validated edge.
  current_resume_state="$(session_file "${STATE_JSON}")"
  if [[ -f "${current_resume_state}" ]]; then
    resume_ancestor_sids="$(jq -c '
      def valid_sid:
        type == "string"
        and (length >= 1 and length <= 128)
        and test("^[a-zA-Z0-9_.-]+$")
        and (contains("..") | not)
        and (test("^\\.+$") | not);
      if .resume_ancestry_version == 1
          and ((.resume_ancestor_session_ids // null) | type) == "array" then
        reduce (.resume_ancestor_session_ids[] | select(valid_sid)) as $ancestor
          ([]; if index($ancestor) == null then . + [$ancestor] else . end)
        | .[-16:]
      else [] end
    ' "${current_resume_state}" 2>/dev/null || printf '[]')"
  fi
  jq -e 'type == "array"' <<<"${resume_ancestor_sids}" >/dev/null 2>&1 \
    || resume_ancestor_sids='[]'
  resume_candidate_sid="$(_timing_read_state_sid \
    "resume_source_session_id" 2>/dev/null || true)"
  while (( resume_chain_steps < 16 )); do
    [[ -n "${resume_candidate_sid}" ]] || break
    validate_session_id "${resume_candidate_sid}" 2>/dev/null || break
    [[ "${resume_candidate_sid}" != "${resume_child_sid}" ]] || break
    jq -e --arg sid "${resume_candidate_sid}" 'index($sid) == null' \
      <<<"${resume_walk_seen_sids}" >/dev/null 2>&1 || break
    resume_candidate_owner="$(_timing_read_sid_from_state_file \
      "${STATE_ROOT}/${resume_candidate_sid}/${STATE_JSON}" \
      "resume_transferred_to" 2>/dev/null || true)"
    [[ "${resume_candidate_owner}" == "${resume_child_sid}" ]] || break
    resume_walk_seen_sids="$(jq -c --arg sid "${resume_candidate_sid}" \
      '. + [$sid]' <<<"${resume_walk_seen_sids}" \
      2>/dev/null || printf '[]')"
    resume_ancestor_sids="$(jq -c --arg sid "${resume_candidate_sid}" \
      'if index($sid) == null then . + [$sid] else . end | .[-16:]' \
      <<<"${resume_ancestor_sids}" 2>/dev/null || printf '[]')"
    resume_next_sid="$(_timing_read_sid_from_state_file \
      "${STATE_ROOT}/${resume_candidate_sid}/${STATE_JSON}" \
      "resume_source_session_id" 2>/dev/null || true)"
    resume_child_sid="${resume_candidate_sid}"
    resume_candidate_sid="${resume_next_sid}"
    resume_chain_steps=$((resume_chain_steps + 1))
  done

  mkdir -p "$(dirname "${target}")" 2>/dev/null || return 1
  with_cross_session_log_lock "${target}" \
    _timing_record_session_summary_locked \
      "${target}" "${sid}" "${resume_ancestor_sids}" "${row}"
}

_timing_record_session_summary_locked() {
  local target="$1" sid="$2" resume_ancestor_sids="$3" row="$4" tmp lines trim
  tmp="$(mktemp "${target}.XXXXXX" 2>/dev/null)" || return 1
  if [[ -f "${target}" ]] && [[ -s "${target}" ]]; then
    # Parse one JSON value per raw line so a single malformed legacy row is
    # skipped rather than aborting the entire dedup transaction.
    # A native --resume is one logical accounting chain.  Replacing the
    # target checkpoint removes every validated ancestor in this same locked
    # rewrite; otherwise A can remain beside cumulative C when intermediate B
    # dies before writing a summary, counting inherited tokens twice.
    jq -Rrc --arg sid "${sid}" --argjson ancestors "${resume_ancestor_sids}" '
      fromjson?
      | (((.session_id // .session) // "") | tostring) as $row_sid
      | select($row_sid != $sid and (($ancestors | index($row_sid)) == null))
    ' "${target}" > "${tmp}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
  else
    : > "${tmp}"
  fi
  printf '%s\n' "${row}" >> "${tmp}" || { rm -f "${tmp}"; return 1; }
  lines="$(wc -l < "${tmp}" 2>/dev/null || echo 0)"
  lines="${lines//[[:space:]]/}"
  if _timing_uint_is_valid "${lines}" && (( lines > 10000 )); then
    trim="$(mktemp "${target}.trim.XXXXXX" 2>/dev/null)" || { rm -f "${tmp}"; return 1; }
    if tail -n 8000 "${tmp}" > "${trim}" 2>/dev/null; then
      rm -f "${tmp}"
      tmp="${trim}"
    else
      rm -f "${trim}"
    fi
  fi
  mv "${tmp}" "${target}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
}

# --- Helpers used by show-time / report ---

# timing_xs_aggregate <cutoff_epoch> [log_path] [session_id] [dispatch_keys_json]
#   Reads the cross-session log (or an explicit read-only merged view) and
#   returns an aggregate over rows with ts >= cutoff. When session_id is
#   supplied, only that exact session contributes; this keeps `report last`
#   aligned across summaries, gate events, and token economics. An explicit
#   dispatch-key array limits per-native-ID materialization to those joins;
#   omitted/null retains every ID for compatibility with direct consumers.
#   Output: {sessions:N, walltime_s:T, agent_breakdown:{...}, tool_breakdown:{...},
#            directive_breakdown:{...}, directive_counts:{...}}
timing_xs_aggregate() {
  local cutoff="${1:-0}"
  local log="${2:-}" session_filter="${3:-}" dispatch_keys_json="${4:-null}"
  cutoff="$(timing_normalize_uint "${cutoff:-0}")"
  jq -e '(type == "array" and all(.[]; type == "string")) or . == null' \
    <<<"${dispatch_keys_json}" >/dev/null 2>&1 \
    || dispatch_keys_json='null'

  [[ -n "${log}" ]] || log="$(timing_xs_log_path)"
  if [[ ! -f "${log}" ]] || [[ ! -s "${log}" ]]; then
    printf '%s\n' '{}'
    return 0
  fi

  local aggregate_log="${log}" aggregate_cutoff="${cutoff}"
  local aggregate_session="${session_filter}" filtered_log="" aggregate_result=""
  if [[ "${dispatch_keys_json}" != "null" ]]; then
    # Report callers normally need only the handful of IDs rejected as stale.
    # Stream-filter each JSONL row before the aggregate slurp so a retained
    # 10k-session ledger with 512 recent IDs per row cannot inflate into a
    # multi-million-object in-memory dispatch map. Malformed/torn JSONL rows
    # are skipped just like the report merge path rather than aborting every
    # otherwise valid session.
    filtered_log="$(mktemp "${TMPDIR:-/tmp}/omc-timing-rollup.XXXXXX" 2>/dev/null || true)"
    if [[ -n "${filtered_log}" ]] && jq -Rc \
        --argjson dispatch_keys "${dispatch_keys_json}" '
      def canonical_uint:
        type == "number" and floor == . and . >= 0 and . <= 999999999999999;
      def bucket_map_numeric_fields_valid:
        . as $map
        | type == "object"
          and all(($map | to_entries[]); .value as $bucket
            | ($bucket | type) == "object"
              and all(["input","output","cache_read","cache_creation"][];
                . as $key
                | (($bucket | has($key) | not)
                    or ($bucket[$key] | canonical_uint))));
      fromjson?
      | select(type == "object")
      | . as $raw
      | select(
          (($raw | has("agent_tokens_by_id")) | not)
          or ($raw.agent_tokens_by_id | bucket_map_numeric_fields_valid)
        )
      | (((.session_id // .session) // "unknown")
          | if type == "string" then .[0:128] else "unknown" end
          | . + "::") as $prefix
      | ($raw.agent_tokens_by_id // {}) as $ids
      | .agent_tokens_by_id = (
          reduce $dispatch_keys[] as $key ({};
            if ($key | startswith($prefix)) then
              ($key | ltrimstr($prefix)) as $id
              | if ($ids | has($id)) then .[$id] = $ids[$id] else . end
            else . end))
    ' "${log}" > "${filtered_log}" 2>/dev/null; then
      aggregate_log="${filtered_log}"
    else
      [[ -n "${filtered_log}" ]] && rm -f "${filtered_log}"
      filtered_log=""
    fi
  fi

  aggregate_result="$(jq -Rsc --argjson cutoff "${aggregate_cutoff}" --arg session "${aggregate_session}" \
    --argjson dispatch_keys "${dispatch_keys_json}" '
    def canonical_uint:
      type == "number" and floor == . and . >= 0 and . <= 999999999999999;
    def uint:
      if canonical_uint then .
      else 0 end;
    def add_uint($left; $right):
      (($left | uint) + ($right | uint))
      | if . > 999999999999999 then 999999999999999 else . end;
    def sum_uint:
      reduce .[] as $value (0; add_uint(.; $value));
    def num_map_numeric_fields_valid:
      type == "object" and all(to_entries[]; .value | canonical_uint);
    def bucket_map_numeric_fields_valid:
      . as $map
      | type == "object"
        and all(($map | to_entries[]); .value as $bucket
          | ($bucket | type) == "object"
            and all(["input","output","cache_read","cache_creation"][];
              . as $key
              | (($bucket | has($key) | not)
                  or ($bucket[$key] | canonical_uint))));
    def xs_numeric_fields_valid:
      . as $row
      | (($row | has("ts")) and ($row.ts | canonical_uint) and ($row.ts > 0)
        and (((($row.session_id // $row.session) | type) == "string")
          and (($row.session_id // $row.session) | length) > 0
          and (($row.session_id // $row.session) | length) <= 128)
        and all([
          "ts","walltime_s","agent_total_s","tool_total_s","idle_model_s",
          "concurrent_overhead_s","directive_total_chars","directive_count",
          "tokens_main_in","tokens_main_out","tokens_main_cache_read",
          "tokens_main_cache_creation","tokens_agent_in","tokens_agent_out",
          "tokens_agent_cache_read","tokens_agent_cache_creation",
          "token_usage_rows","stale_reviewer_count","prompt_count"
        ][]; . as $key
          | (($row | has($key) | not)
              or ($row[$key] | canonical_uint)))
        and all([
          "agent_breakdown","tool_breakdown","directive_breakdown",
          "directive_counts"
        ][]; . as $key
          | (($row | has($key) | not)
              or ($row[$key] | num_map_numeric_fields_valid)))
        and all([
          "agent_tokens_by_role","agent_tokens_by_model","agent_tokens_by_id"
        ][]; . as $key
          | (($row | has($key) | not)
              or ($row[$key] | bucket_map_numeric_fields_valid))));
    def safe_num_map:
      if type != "object" then {}
      else to_entries | .[-512:] | map(.value |= uint) | from_entries end;
    def safe_bucket_map:
      if type != "object" then {}
      else to_entries | .[-512:] | map(
        .value = ((.value // {}) |
          if type == "object" then {
            input: ((.input // 0) | uint),
            output: ((.output // 0) | uint),
            cache_read: ((.cache_read // 0) | uint),
            cache_creation: ((.cache_creation // 0) | uint)
          } else {input:0,output:0,cache_read:0,cache_creation:0} end)
      ) | from_entries end;
    def normalize_xs_row:
      . as $raw
      | reduce ([
        "ts","walltime_s","agent_total_s","tool_total_s","idle_model_s",
        "concurrent_overhead_s","directive_total_chars","directive_count",
        "tokens_main_in","tokens_main_out","tokens_main_cache_read",
        "tokens_main_cache_creation","tokens_agent_in","tokens_agent_out",
        "tokens_agent_cache_read","tokens_agent_cache_creation",
        "token_usage_rows","stale_reviewer_count","prompt_count"
      ][]) as $key (.;
        if has($key) then .[$key] = (.[$key] | uint) else .[$key] = 0 end)
      | .session_id = (((.session_id // .session) // "") |
          if type == "string" then .[0:128] else "" end)
      | .agent_breakdown = ((.agent_breakdown // {}) | safe_num_map)
      | .tool_breakdown = ((.tool_breakdown // {}) | safe_num_map)
      | .directive_breakdown = ((.directive_breakdown // {}) | safe_num_map)
      | .directive_counts = ((.directive_counts // {}) | safe_num_map)
      | .agent_tokens_by_role = ((.agent_tokens_by_role // {}) | safe_bucket_map)
      | .agent_tokens_by_model = ((.agent_tokens_by_model // {}) | safe_bucket_map)
      | .agent_tokens_by_id = ((.agent_tokens_by_id // {}) | safe_bucket_map)
      | ._timing_numeric_valid = ($raw | xs_numeric_fields_valid);

    [split("\n")[]
      | select(length > 0)
      | (try fromjson catch empty)
      | select(type == "object")
      | normalize_xs_row
      | select(._timing_numeric_valid == true)
      | select(.ts >= $cutoff)
      | select($session == "" or .session_id == $session)
    ] as $rows |
    {
      sessions:        (($rows | length) | uint),
      walltime_s:      ([$rows[] | .walltime_s] | sum_uint),
      agent_total_s:   ([$rows[] | .agent_total_s] | sum_uint),
      tool_total_s:    ([$rows[] | .tool_total_s] | sum_uint),
      idle_model_s:    ([$rows[] | .idle_model_s] | sum_uint),
      # Sum parallelism overhead so the renderer can disclose time saved by
      # parallel work. Legacy rows simply normalize the missing field to zero.
      concurrent_overhead_s: ([$rows[] | .concurrent_overhead_s] | sum_uint),
      directive_total_chars: ([$rows[] | .directive_total_chars] | sum_uint),
      directive_count: ([$rows[] | .directive_count] | sum_uint),
      agent_breakdown: (
        [$rows[] | .agent_breakdown | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | sum_uint)})
        | from_entries
      ),
      tool_breakdown: (
        [$rows[] | .tool_breakdown | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | sum_uint)})
        | from_entries
      ),
      directive_breakdown: (
        [$rows[] | .directive_breakdown | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | sum_uint)})
        | from_entries
      ),
      directive_counts: (
        [$rows[] | .directive_counts | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: ([.[].value] | sum_uint)})
        | from_entries
      ),
      tokens_main_in:              ([$rows[] | .tokens_main_in] | sum_uint),
      tokens_main_out:             ([$rows[] | .tokens_main_out] | sum_uint),
      tokens_main_cache_read:      ([$rows[] | .tokens_main_cache_read] | sum_uint),
      tokens_main_cache_creation:  ([$rows[] | .tokens_main_cache_creation] | sum_uint),
      tokens_agent_in:             ([$rows[] | .tokens_agent_in] | sum_uint),
      tokens_agent_out:            ([$rows[] | .tokens_agent_out] | sum_uint),
      tokens_agent_cache_read:     ([$rows[] | .tokens_agent_cache_read] | sum_uint),
      tokens_agent_cache_creation: ([$rows[] | .tokens_agent_cache_creation] | sum_uint),
      token_usage_rows:            ([$rows[] | .token_usage_rows] | sum_uint),
      stale_reviewer_count:        ([$rows[] | .stale_reviewer_count] | sum_uint),
      agent_tokens_by_role: (
        [$rows[] | .agent_tokens_by_role | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: {
            input: ([.[].value.input] | sum_uint),
            output: ([.[].value.output] | sum_uint),
            cache_read: ([.[].value.cache_read] | sum_uint),
            cache_creation: ([.[].value.cache_creation] | sum_uint)
          }})
        | from_entries
      ),
      agent_tokens_by_model: (
        [$rows[] | .agent_tokens_by_model | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: {
            input: ([.[].value.input] | sum_uint),
            output: ([.[].value.output] | sum_uint),
            cache_read: ([.[].value.cache_read] | sum_uint),
            cache_creation: ([.[].value.cache_creation] | sum_uint)
          }})
        | from_entries
      ),
      # Native Claude Code IDs are unique per invocation. Namespace them by
      # session so stale-review joins identify exactly one sidechain.
      agent_tokens_by_dispatch: (
        [$rows[] as $row
          | (($row.session_id | if . == "" then "unknown" else . end) + "::") as $prefix
          | $row.agent_tokens_by_id as $ids
          | if $dispatch_keys == null then
              $ids | to_entries[] | .key = ($prefix + .key)
            else
              $dispatch_keys[] as $key
              | select($key | startswith($prefix))
              | ($key | ltrimstr($prefix)) as $id
              | select($ids | has($id))
              | {key:$key,value:$ids[$id]}
            end]
        | group_by(.key)
        | map({key: .[0].key, value: {
            input: ([.[].value.input] | sum_uint),
            output: ([.[].value.output] | sum_uint),
            cache_read: ([.[].value.cache_read] | sum_uint),
            cache_creation: ([.[].value.cache_creation] | sum_uint)
          }})
        | from_entries
      ),
      prompts: ([$rows[] | .prompt_count] | sum_uint)
    }
  ' < "${aggregate_log}" 2>/dev/null || printf '%s' '{}')"
  [[ -n "${filtered_log}" ]] && rm -f "${filtered_log}"
  if [[ -n "${aggregate_result}" ]]; then
    printf '%s\n' "${aggregate_result}"
  else
    printf '%s\n' '{}'
  fi
}

# timing_next_prompt_seq
#   Atomic increment of the per-session prompt counter. Stored in
#   session_state.json under key 'prompt_seq'. Called once per
#   UserPromptSubmit. Returns the new value.
_timing_next_prompt_seq_unlocked() {
  local current next
  current="$(_timing_read_state_uint_or_zero_when_absent \
    "prompt_seq" "${_TIMING_UINT_INCREMENT_MAX}" 2>/dev/null)" || return 1
  next=$((current + 1))
  _write_state_unlocked "prompt_seq" "${next}" 2>/dev/null || return 1
  printf '%s' "${next}"
}

timing_next_prompt_seq() {
  is_time_tracking_enabled || { printf '0'; return 0; }
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }

  local next=""
  if ! next="$(with_state_lock _timing_next_prompt_seq_unlocked 2>/dev/null)"; then
    printf '0'
    return 0
  fi
  printf '%s' "${next}"
}

# timing_current_prompt_seq
#   Read-only access to the latest assigned prompt_seq. Used by hooks that
#   tag start/end rows so they pair within the right epoch.
timing_current_prompt_seq() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local current
  current="$(_timing_read_state_uint "prompt_seq" 2>/dev/null || printf '0')"
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
  seq="$(jq -Rsr '
    def canonical_uint:
      type == "number" and floor == . and . >= 0
      and . <= 999999999999999;
    [split("\n")[] | select(length > 0) | fromjson?
      | select(type == "object")] as $rows
    | reduce $rows[] as $row ({started:{}, latest:0};
        if ($row.kind == "prompt_start"
            and ($row.ts | canonical_uint) and $row.ts > 0
            and ($row.prompt_seq | canonical_uint)) then
          .started[($row.prompt_seq | tostring)] = true
        elif ($row.kind == "prompt_end"
            and ($row.ts | canonical_uint) and $row.ts > 0
            and ($row.prompt_seq | canonical_uint)
            and ($row.duration_s | canonical_uint)
            and (.started[($row.prompt_seq | tostring)] == true)) then
          .latest = ([.latest, $row.prompt_seq] | max)
        else . end)
    | .latest
  ' < "${log}" 2>/dev/null || printf '0')"
  seq="${seq:-0}"
  _timing_uint_is_valid "${seq}" || seq=0
  printf '%s' "${seq}"
}
