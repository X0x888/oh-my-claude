#!/usr/bin/env bash
# canary.sh — Model-drift canary signal computations (v1.26.0 Wave 2).
#
# Detects silent confabulation patterns in the model's output by
# comparing assertive verification claims in the prose against the
# actual tool calls executed in the same turn. The signal exists
# because a model in regression often produces text like "I read
# /path/to/file.swift and verified the imports" without firing a
# corresponding Read tool call — the user accepts the claim, ships
# the work, and learns later that the claim was confabulation.
#
# This library is sourced by:
#   - canary-claim-audit.sh  (Stop hook, runs the audit)
#   - show-report.sh         (cross-session rollup for /ulw-report)
#
# Constraints inherited from common.sh:
#   - bash + jq + grep + awk only; no Python, no daemons.
#   - All disk I/O respects STATE_ROOT / cross-session paths.
#   - Hot path is "extract claims, count tools, compare" — keep it
#     under ~50ms on the user's machine even for multi-KB responses.
#
# Pre-mortem context: metis flagged the original Wave 2 design (false-
# completion regex on the prose tail) as Goodhart-vulnerable and
# false-positive-prone. metis explicitly recommended the claim-audit
# shape — "the gap between claimed and executed tool calls is the
# most direct silent-confabulation signal." This library is the
# implementation of that recommendation. The signal is INTENTIONALLY
# coarse (claim count vs tool count, not path-level matching) so the
# audit cost stays sub-50ms and the pattern survives prose-style
# evolution. False positives (model says "I read the docs" without a
# Read on a doc URL) are tolerable — false negatives (the model
# confabulates and we miss it) are the failure we care about. metis
# also called out that aggregating multiple signals into a composite
# score hides single-axis catastrophic failures; this library
# deliberately keeps the signal as a per-event count plus a single
# threshold rather than a weighted aggregate.

set -euo pipefail

# canary_extract_claim_count <text>
#
# Returns (on stdout) the count of assertive verification claims in
# the supplied text. A "claim" is a sentence-shaped assertion that
# the model performed a verification action — read, verified, checked,
# examined, inspected, reviewed, confirmed, validated, ran, tested,
# executed — typically tied to a specific noun (a path, a file, a
# function, a config). The regex is intentionally generous on the
# verb axis and tighter on the noun axis (requires either a
# code-anchor pattern, a backtick-fenced span, or a definite article
# + noun) so casual claims like "I read the docs" or "I verified our
# approach" do not contribute to the count.
#
# Patterns matched:
#   - "I (verified|checked|examined|inspected|reviewed|read|confirmed|
#      validated|ran|tested|executed) <X>" where X is:
#       a) a backtick-fenced span (`some_path` or `path/to/file.ext`)
#       b) a slash-bearing path (/abs/path or rel/path)
#       c) a "the <noun>" phrase where noun is a code-shape word
#   - "the <X> (lives|is|exists) (in|at) <path>"
#   - "I have (read|verified|checked|examined|inspected|reviewed|run|
#      tested|executed) <X>"
#
# Parsing is line-aware: the input text is split into lines, each
# line is matched against the regex, and the total match count is
# summed. This avoids regex-engine blowup on multi-KB single strings.
#
# Returns 0 on stdout for empty input or non-matching text.
canary_extract_claim_count() {
  local text="$1"
  [[ -z "${text}" ]] && { printf '0'; return; }

  # The verb set deliberately excludes weak / aspirational verbs like
  # "should", "could", "might" — only assertive past-tense and
  # present-tense factual claims count. Backtick-fenced spans, paths
  # with slashes, paths with extensions (.swift, .ts, .py, .sh, .md,
  # .json, .yaml, .yml, .toml, .lock, .sql, .css, .html, .xml, .conf,
  # .env), and function-call shapes (foo()) count as code anchors.
  local verbs='(verified|checked|examined|inspected|reviewed|read|confirmed|validated|ran|tested|executed|opened|loaded|grepped|searched)'
  local pronouns='(i|we)'
  # codepat — code anchors that count as "verifiable" referents.
  # The slash-only branch excludes trailing punctuation (`, ; .`) so
  # that "I read /path/A.swift, /path/B.ts" doesn't eat the comma into
  # the path and break the continuation regex's separator match. The
  # extension-bearing branch is unaffected (it stops at the matched
  # extension naturally). Backticks and `foo()` shapes are
  # self-terminating and don't have this hazard.
  local codepat='(`[^`]+`|/[^[:space:],;]+|[a-zA-Z_][a-zA-Z0-9_/.-]*\.(swift|ts|tsx|js|jsx|py|sh|bash|zsh|md|json|yaml|yml|toml|lock|sql|css|scss|html|xml|conf|env|rb|go|rs|java|kt|cpp|c|h|hpp|m|mm|gradle|cmake|mk|dockerfile|pdf|txt|ini|properties|gitignore|gitkeep|gitattributes|editorconfig|prettierrc|eslintrc|csv|tsv|xlsx)|[a-zA-Z_][a-zA-Z0-9_]*\(\))'

  # Pattern A — verb-then-direct-object form: "I read /path", "we verified `foo`"
  local pat_active="\\b${pronouns}[[:space:]]+(have[[:space:]]+|just[[:space:]]+|already[[:space:]]+|now[[:space:]]+)?${verbs}[[:space:]]+([a-z[:space:]]+[[:space:]])?${codepat}"

  # Pattern B (v1.26.0 Wave 2 excellence-reviewer F1) — continuation
  # form: ", /path/B" or " and /path/B" or " and verified /path/B"
  # following an initial active claim. Catches the natural multi-file
  # confab prose shape "I read A.swift, B.ts, and C.go" where only
  # the first claim has a pronoun anchor — without this pattern,
  # 3-file confab scores 1, defeating the audit's primary signal on
  # exactly the prose shape that motivated v1.26.0.
  #
  # Continuation count is ONLY added when at least one Pattern A claim
  # was found in the same prose; without that gate, neutral prose
  # like "see also /docs, /src" would inflate the count without any
  # claim verb being asserted.
  local pat_continuation="(,[[:space:]]+|[[:space:]]+and[[:space:]]+)(${verbs}[[:space:]]+([a-z[:space:]]+[[:space:]])?)?${codepat}"

  # Pattern C — "the foo function lives in /path" form
  local pat_at="\\bthe[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+(lives|is|exists|sits)[[:space:]]+(in|at)[[:space:]]+${codepat}"

  # grep -c counts MATCHED LINES, not match instances. For accurate
  # counting on multi-claim lines, use -o (one match per line) then
  # count the resulting line count.
  local count_active count_cont count_at total
  count_active="$(printf '%s\n' "${text}" | grep -Eio "${pat_active}" 2>/dev/null | wc -l | tr -d ' ')"
  count_cont="$(printf '%s\n' "${text}" | grep -Eio "${pat_continuation}" 2>/dev/null | wc -l | tr -d ' ')"
  count_at="$(printf '%s\n' "${text}" | grep -Eio "${pat_at}" 2>/dev/null | wc -l | tr -d ' ')"
  count_active="${count_active:-0}"
  count_cont="${count_cont:-0}"
  count_at="${count_at:-0}"
  total=$((count_active + count_at))
  if [[ "${count_active}" -ge 1 ]]; then
    total=$((total + count_cont))
  fi
  printf '%d' "${total}"
}

# canary_count_verification_tools <session_id> <prompt_seq>
#
# Returns (on stdout) the number of verification-class tool calls
# the model fired in the given prompt_seq epoch. "Verification-class"
# means tools that read or query existing state — Read, Bash, Grep,
# Glob, WebFetch, NotebookRead. Edit, Write, and TaskCreate do NOT
# count because they are mutation operations, not verification.
#
# Reads the session's `timing.jsonl` (mutex-serialized append-only log
# already used by the time-tracking subsystem) and filters rows by
# prompt_seq + tool_name. The timing log carries `event` (start|end),
# `tool_name`, `prompt_seq`, `tool_use_id` per row; the audit only
# needs the count of distinct `tool_use_id`s on `event=start` rows
# whose `tool_name` is in the verification set.
#
# Returns 0 on stdout when timing.jsonl is missing, the prompt_seq
# is empty, or the input is malformed.
canary_count_verification_tools() {
  local session_id="$1"
  local prompt_seq="${2:-}"
  [[ -z "${session_id}" || -z "${prompt_seq}" ]] && { printf '0'; return; }

  local timing_file
  timing_file="${STATE_ROOT}/${session_id}/timing.jsonl"
  [[ ! -f "${timing_file}" ]] && { printf '0'; return; }

  # Filter rows: kind=start, prompt_seq matches, tool is in the
  # verification set. Count distinct tool_use_id values when present to
  # dedupe any malformed double-emit; fall back to the row index when
  # Claude Code omits tool_use_id so real verification calls still count.
  #
  # timing.jsonl schema (set by timing.sh — verify against
  # `head -3 ~/.claude/quality-pack/state/<sid>/timing.jsonl` if you
  # see schema drift):
  #   {kind, ts, tool, prompt_seq, tool_use_id?} for tool start/end
  #   {kind:"prompt_start"|"prompt_end", ts, prompt_seq, ...} for prompt boundaries
  jq -Rsr --arg ps "${prompt_seq}" '
    def canonical_uint:
      type == "number" and floor == . and . >= 0
      and . <= 999999999999999;
    [split("\n")[] | select(length > 0) | fromjson?
      | select(type == "object")] as $rows
    | [
      $rows | to_entries[]
      | select(.value.kind == "start"
          and (.value.ts | canonical_uint) and .value.ts > 0
          and (.value.prompt_seq | canonical_uint)
          and (.value.prompt_seq | tostring) == $ps
          and (((.value.tool_use_id // "") | type) == "string")
          and (.value.tool | IN("Read","Bash","Grep","Glob","WebFetch","NotebookRead")))
      | if ((.value.tool_use_id // "") != "") then
          "id:\(.value.tool_use_id)"
        else
          "row:\(.key)"
        end
    ]
    | unique
    | length
  ' "${timing_file}" 2>/dev/null || printf '0'
}

# canary_get_current_prompt_seq <session_id>
#
# Returns (on stdout) the prompt_seq value for the most recent
# UserPromptSubmit. The time-tracking subsystem persists this in
# session_state.json under `prompt_seq` (last-write-wins via
# `timing_next_prompt_seq` at UserPromptSubmit time).
#
# Returns empty when not set.
canary_get_current_prompt_seq() {
  local session_id="$1"
  [[ -z "${session_id}" ]] && return
  local sf="${STATE_ROOT}/${session_id}/session_state.json"
  [[ -f "${sf}" && ! -L "${sf}" ]] || return
  # Validate before raw projection: Bash drops decoded NUL, so a persisted
  # `"1\u0000"` must not become prompt 1 and bind unrelated timing evidence.
  jq -er '
    select(type == "object"
      and all(.. | strings; index("\u0000") == null))
    | .prompt_seq
    | if type == "number" then
        select(floor == . and . >= 0 and . <= 999999999999999)
        | tostring
      elif type == "string" then
        select(test("^(0|[1-9][0-9]{0,14})$"))
      else empty
      end
  ' "${sf}" 2>/dev/null || true
}

# Publish one fully-computed audit while holding the session mutex. The
# generation check must be the first operation under that mutex: an old Stop
# callback can finish its read/encode work after a release -> reactivation and
# must not append G1 evidence to G2's ledgers (or emit a G2 gate event).
_canary_finalizer_claim_valid_unlocked() {
  local accepted="${1:-0}" claim_id="${2:-}"
  [[ "${accepted}" == "1" ]] || return 0
  declare -F _closeout_finalization_claim_is_current_unlocked \
    >/dev/null 2>&1 || return 1
  _closeout_finalization_claim_is_current_unlocked "${claim_id}"
}

_canary_append_xs_locked() {
  local target="$1" session_id="$2" prompt_seq="$3" row="$4"
  local accepted="$5" claim_id="$6"
  local temp trim lines
  _canary_finalizer_claim_valid_unlocked "${accepted}" "${claim_id}" \
    || return 1
  [[ ! -L "${target}" ]] \
    && { [[ ! -e "${target}" ]] || [[ -f "${target}" ]]; } || return 1
  temp="$(mktemp "${target}.XXXXXX" 2>/dev/null)" || return 1
  if [[ -s "${target}" ]]; then
    if ! jq -Rr --arg sid "${session_id}" --arg ps "${prompt_seq}" '
        . as $raw
        | (try ($raw | fromjson) catch null) as $parsed
        | select(($parsed | type) == "object")
        | select(($parsed.session_id // "") != $sid
          or (($parsed.prompt_seq // "") | tostring) != $ps)
        | $raw
      ' "${target}" >"${temp}" 2>/dev/null; then
      rm -f "${temp}"
      return 1
    fi
  else
    : >"${temp}"
  fi
  printf '%s\n' "${row}" >>"${temp}" || { rm -f "${temp}"; return 1; }
  lines="$(wc -l <"${temp}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${lines}" =~ ^[0-9]+$ ]] || { rm -f "${temp}"; return 1; }
  if (( lines > 10000 )); then
    trim="$(mktemp "${target}.trim.XXXXXX" 2>/dev/null)" \
      || { rm -f "${temp}"; return 1; }
    if ! tail -n 8000 "${temp}" >"${trim}" 2>/dev/null; then
      rm -f "${temp}" "${trim}"
      return 1
    fi
    rm -f "${temp}"
    temp="${trim}"
  fi
  if [[ -n "${OMC_TEST_CANARY_XS_READY_FILE:-}" ]]; then
    : >"${OMC_TEST_CANARY_XS_READY_FILE}"
    while [[ -n "${OMC_TEST_CANARY_XS_RELEASE_FILE:-}" \
        && ! -e "${OMC_TEST_CANARY_XS_RELEASE_FILE}" ]]; do
      sleep 0.01
    done
  fi
  _canary_finalizer_claim_valid_unlocked "${accepted}" "${claim_id}" \
    || { rm -f "${temp}"; return 1; }
  mv -f "${temp}" "${target}" 2>/dev/null \
    || { rm -f "${temp}"; return 1; }
}

_canary_publish_gate_event_locked() {
  local claim_count="$1" tool_count="$2" prompt_seq="$3"
  local accepted="$4" finalizer_claim_id="$5"
  local gate_file exact_count conflict_count
  _canary_finalizer_claim_valid_unlocked \
    "${accepted}" "${finalizer_claim_id}" || return 1
  gate_file="$(session_file "gate_events.jsonl")"
  exact_count=0
  conflict_count=0
  if [[ -s "${gate_file}" ]]; then
    exact_count="$(jq -Rsr --arg ps "${prompt_seq}" \
      --argjson cc "${claim_count}" --argjson tc "${tool_count}" '
        [split("\n")[] | select(length > 0)
          | (try fromjson catch null) | select(type == "object")
          | select(.gate == "canary" and .event == "unverified_claim"
            and ((.details.prompt_seq // "") | tostring) == $ps
            and (.details.claim_count // null) == $cc
            and (.details.tool_count // null) == $tc)] | length
      ' "${gate_file}" 2>/dev/null)" || return 1
    conflict_count="$(jq -Rsr --arg ps "${prompt_seq}" '
        [split("\n")[] | select(length > 0)
          | (try fromjson catch null) | select(type == "object")
          | select(.gate == "canary" and .event == "unverified_claim"
            and ((.details.prompt_seq // "") | tostring) == $ps)] | length
      ' "${gate_file}" 2>/dev/null)" || return 1
  fi
  [[ "${exact_count}" =~ ^[0-9]+$ && "${conflict_count}" =~ ^[0-9]+$ ]] \
    || return 1
  if [[ "${exact_count}" -eq 1 && "${conflict_count}" -eq 1 ]]; then
    return 0
  fi
  [[ "${conflict_count}" -eq 0 ]] || return 1
  _canary_finalizer_claim_valid_unlocked \
    "${accepted}" "${finalizer_claim_id}" || return 1
  record_gate_event "canary" "unverified_claim" \
    "claim_count=${claim_count}" \
    "tool_count=${tool_count}" \
    "prompt_seq=${prompt_seq}"
  [[ -s "${gate_file}" ]] || return 1
  exact_count="$(jq -Rsr --arg ps "${prompt_seq}" \
    --argjson cc "${claim_count}" --argjson tc "${tool_count}" '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null) | select(type == "object")
        | select(.gate == "canary" and .event == "unverified_claim"
          and ((.details.prompt_seq // "") | tostring) == $ps
          and (.details.claim_count // null) == $cc
          and (.details.tool_count // null) == $tc)] | length
    ' "${gate_file}" 2>/dev/null)" || return 1
  [[ "${exact_count}" == "1" ]]
}

_canary_publish_audit_locked() {
  local session_id="$1" row="$2" xs_row="$3" verdict="$4"
  local claim_count="$5" tool_count="$6" prompt_seq="$7"
  local accepted="$8" finalizer_claim_id="$9"
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 1
  fi
  _canary_finalizer_claim_valid_unlocked \
    "${accepted}" "${finalizer_claim_id}" || return 1
  [[ "${OMC_TEST_CANARY_PUBLISH_FAIL:-0}" != "1" ]] || return 1

  local sess_jsonl xs_jsonl existing_bundle existing_status durable_row
  local durable_ts
  sess_jsonl="$(session_file "canary.jsonl")"
  if [[ -s "${sess_jsonl}" ]]; then
    existing_bundle="$(jq -Rsr --arg ps "${prompt_seq}" \
      --argjson expected "${row}" '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null) | select(type == "object")
        | select(((.prompt_seq // "") | tostring) == $ps)] as $rows
      | if ($rows | length) == 0 then {status:"absent",row:$expected}
        elif ($rows | length) == 1
          and (($rows[0].ts // null) | type) == "number"
          and (($rows[0] | del(.ts)) == ($expected | del(.ts)))
          then {status:"match",row:$rows[0]}
        else {status:"conflict",row:null} end
    ' "${sess_jsonl}" 2>/dev/null)" || return 1
  else
    existing_bundle="$(jq -cn --argjson row "${row}" \
      '{status:"absent",row:$row}')" || return 1
  fi
  existing_status="$(jq -r '.status // ""' <<<"${existing_bundle}")" \
    || return 1
  [[ "${existing_status}" == "absent" \
      || "${existing_status}" == "match" ]] || return 1
  durable_row="$(jq -c '.row' <<<"${existing_bundle}")" || return 1
  if [[ "${existing_status}" == "absent" ]]; then
    _canary_finalizer_claim_valid_unlocked \
      "${accepted}" "${finalizer_claim_id}" || return 1
    _append_limited_state_locked "${sess_jsonl}" "${row}" 200 || return 1
  fi
  # Deterministic partial-publication seam: a retry must accept the already
  # committed semantic session row even though its audit timestamp differs.
  [[ "${OMC_TEST_CANARY_FAIL_AFTER_SESSION_APPEND:-0}" != "1" ]] \
    || return 1

  # The first durable session row owns this audit's timestamp. A retry after a
  # partial publication reuses it in the global row instead of manufacturing a
  # split identity from the retry clock.
  durable_ts="$(jq -r '.ts' <<<"${durable_row}")" || return 1
  [[ "${durable_ts}" =~ ^[0-9]+$ ]] || return 1
  xs_row="$(jq -c --argjson ts "${durable_ts}" '.ts = $ts' \
    <<<"${xs_row}")" || return 1

  # The cross-session row belongs to the same generation-dependent publish.
  # Keep it inside the session critical section so a stale callback cannot
  # leave a global row after its per-session row was rejected.
  xs_jsonl="${HOME}/.claude/quality-pack/canary.jsonl"
  _canary_finalizer_claim_valid_unlocked \
    "${accepted}" "${finalizer_claim_id}" || return 1
  mkdir -p "$(dirname "${xs_jsonl}")" 2>/dev/null || return 1
  with_cross_session_log_lock "${xs_jsonl}" _canary_append_xs_locked \
    "${xs_jsonl}" "${session_id}" "${prompt_seq}" "${xs_row}" \
    "${accepted}" "${finalizer_claim_id}" \
    || return 1
  # A retry after this boundary replaces the same global semantic key with the
  # session-owned durable timestamp, so it cannot split one audit into two
  # cross-session observations.
  [[ "${OMC_TEST_CANARY_FAIL_AFTER_GLOBAL_APPEND:-0}" != "1" ]] \
    || return 1

  if [[ "${verdict}" == "unverified" ]]; then
    _canary_publish_gate_event_locked \
      "${claim_count}" "${tool_count}" "${prompt_seq}" \
      "${accepted}" "${finalizer_claim_id}" || return 1
    [[ "${OMC_TEST_CANARY_FAIL_AFTER_GATE_EVENT:-0}" != "1" ]] \
      || return 1
  fi
}

# canary_run_audit <session_id>
#
# The hot path. Called from canary-claim-audit.sh at Stop time. Reads
# the model's last assistant message, extracts the claim count, reads
# the turn's verification tool count, and writes one canary.jsonl row
# describing the audit result. Standalone calls fail open; accepted dispatcher
# children propagate publication failure so the finalizer claim can be retried.
#
# Row schema (per-session):
#   {ts, prompt_seq, claim_count, tool_count, ratio, verdict,
#    response_preview}
#
# verdict values:
#   "clean"           — claim_count <= 1 (low-claim turns are noise-free)
#   "covered"         — tool_count >= claim_count (claims appear backed)
#   "low_coverage"    — claim_count >= 2 AND tool_count < claim_count
#   "unverified"      — claim_count >= 2 AND tool_count == 0 (the strongest
#                       silent-confab signal — model claimed verification
#                       work but fired zero verification tools in the turn)
#
# Standalone calls remain fail-open. An accepted-Stop child returns non-zero
# when its locked publication fails so the dispatcher can abandon its
# finalizer lease and retry instead of marking incomplete evidence complete.
canary_run_audit() {
  local session_id="$1"
  local accepted="${OMC_STOP_ACCEPTED:-0}"
  local finalizer_claim_id="${OMC_CLOSEOUT_FINALIZATION_CLAIM_ID:-}"
  [[ -z "${session_id}" ]] && return 0
  if [[ "${accepted}" == "1" \
      && ! "${finalizer_claim_id}" =~ ^finalizer-[a-f0-9]{48}$ ]]; then
    return 1
  fi
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 0
  fi

  # Hard-dependency check: the audit needs timing.jsonl to count tool
  # calls per prompt_seq. When time_tracking is off (minimal preset
  # default) the file does not exist; the audit must skip gracefully
  # rather than report a false "unverified" verdict on every Stop.
  local timing_file="${STATE_ROOT}/${session_id}/timing.jsonl"
  if [[ ! -f "${timing_file}" ]]; then
    log_hook "canary" "skip: no timing.jsonl (time_tracking off?)"
    return 0
  fi

  local prompt_seq
  prompt_seq="$(canary_get_current_prompt_seq "${session_id}")"
  if [[ -z "${prompt_seq}" ]]; then
    log_hook "canary" "skip: no prompt_seq for session"
    return 0
  fi

  local last_assistant
  last_assistant="$(read_state "last_assistant_message")"
  if [[ -z "${last_assistant}" ]]; then
    log_hook "canary" "skip: no last_assistant_message"
    return 0
  fi

  local claim_count tool_count verdict ratio_pct response_preview
  claim_count="$(canary_extract_claim_count "${last_assistant}")"
  tool_count="$(canary_count_verification_tools "${session_id}" "${prompt_seq}")"
  claim_count="${claim_count:-0}"
  tool_count="${tool_count:-0}"

  if [[ "${claim_count}" -lt 2 ]]; then
    verdict="clean"
  elif [[ "${tool_count}" -eq 0 ]]; then
    verdict="unverified"
  elif [[ "${tool_count}" -ge "${claim_count}" ]]; then
    verdict="covered"
  else
    verdict="low_coverage"
  fi

  # Ratio expressed as percentage of claims that have a backing tool
  # call. Capped at 999 to avoid weird display.
  if [[ "${claim_count}" -eq 0 ]]; then
    ratio_pct="100"
  else
    ratio_pct=$(( tool_count * 100 / claim_count ))
    [[ "${ratio_pct}" -gt 999 ]] && ratio_pct=999
  fi

  response_preview="$(truncate_chars 240 "${last_assistant}")"

  local audit_ts row xs_row project_key
  audit_ts="$(now_epoch)"
  project_key="$(_omc_project_key 2>/dev/null || printf 'unknown')"
  row="$(jq -nc \
    --argjson ts "${audit_ts}" \
    --arg ps "${prompt_seq}" \
    --argjson cc "${claim_count}" \
    --argjson tc "${tool_count}" \
    --argjson rp "${ratio_pct}" \
    --arg verdict "${verdict}" \
    --arg preview "${response_preview}" \
    '{ts: ($ts|tonumber), prompt_seq: $ps, claim_count: $cc, tool_count: $tc, ratio_pct: $rp, verdict: $verdict, response_preview: $preview}' \
    2>/dev/null || true)"

  if [[ -z "${row}" ]]; then
    log_hook "canary" "skip: jq encoding failed"
    [[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] && return 1
    return 0
  fi

  xs_row="$(jq -nc \
    --argjson ts "${audit_ts}" \
    --arg pk "${project_key}" \
    --arg sid "${session_id}" \
    --arg ps "${prompt_seq}" \
    --argjson cc "${claim_count}" \
    --argjson tc "${tool_count}" \
    --argjson rp "${ratio_pct}" \
    --arg verdict "${verdict}" \
    '{ts: ($ts|tonumber), project_key: $pk, session_id: $sid, prompt_seq: $ps, claim_count: $cc, tool_count: $tc, ratio_pct: $rp, verdict: $verdict}' \
    2>/dev/null || true)"
  if [[ -z "${xs_row}" ]]; then
    log_hook "canary" "skip: cross-session jq encoding failed"
    [[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] && return 1
    return 0
  fi

  # All expensive reads and encodes above are staged outside the mutex. The
  # short locked publish rechecks the captured generation atomically with the
  # per-session/global rows and any unverified gate event.
  local publish_rc=0
  with_state_lock _canary_publish_audit_locked \
    "${session_id}" "${row}" "${xs_row}" "${verdict}" \
    "${claim_count}" "${tool_count}" "${prompt_seq}" \
    "${accepted}" "${finalizer_claim_id}" \
    2>/dev/null || publish_rc=$?

  if [[ "${publish_rc}" -ne 0 ]]; then
    log_hook "canary" "locked audit publication failed"
    [[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] && return "${publish_rc}"
  fi

  return 0
}

# canary_session_unverified_count <session_id>
#
# Returns count of unverified verdicts in the session's canary log.
# Used by canary_should_alert to decide if a soft alert should fire.
canary_session_unverified_count() {
  local session_id="$1"
  local f
  f="${STATE_ROOT}/${session_id}/canary.jsonl"
  [[ ! -f "${f}" ]] && { printf '0'; return; }
  jq -r 'select(.verdict == "unverified") | .verdict' "${f}" 2>/dev/null | wc -l | tr -d ' '
}

# canary_session_max_unverified_claims <session_id>
#
# Returns the maximum claim_count across all `unverified` verdict rows
# in the session. Used by canary_should_alert to detect "loud sessions"
# — a single turn that confabulates many claims with zero verification
# tools. v1.27.0 (F-010): lets the canary alert on the FIRST unverified
# event when that single event is loud (claim_count ≥ 4), instead of
# waiting for two events to accumulate. Closes the gap where a single
# very-confident-but-fully-confabulated turn would ship without a soft
# alert.
canary_session_max_unverified_claims() {
  local session_id="$1"
  local f
  f="${STATE_ROOT}/${session_id}/canary.jsonl"
  [[ ! -f "${f}" ]] && { printf '0'; return; }
  jq -rs '[.[] | select(.verdict == "unverified") | .claim_count] | (max // 0)' "${f}" 2>/dev/null \
    || printf '0'
}

# canary_should_alert <session_id>
#
# Returns 0 (true) when the session has crossed the unverified-claim
# alert threshold AND the soft alert has not yet been emitted this
# session. The alert is one-shot per session — drift_warning_emitted
# state flag prevents repetition.
#
# Two thresholds (either fires the alert):
#   1. Pattern threshold: >= 2 unverified verdicts in the session.
#      Distinguishes noise (a single confused claim under unusual
#      prose) from pattern (the model is consistently claiming
#      verification work it isn't doing).
#   2. Loud-session threshold (v1.27.0 F-010): single unverified
#      event with claim_count >= 4. A single turn that asserts 4+
#      verification claims with zero backing tool calls is itself
#      strong-enough signal to alert immediately — waiting for a
#      second event lets a "one big confabulated turn" session ship
#      silently. Threshold of 4 chosen to be strictly above the
#      claim_count >= 2 floor that triggers `unverified` verdict at
#      all, and well above the noise-floor any single turn of normal
#      execution prose generates.
canary_should_alert() {
  local session_id="$1"
  local emitted
  emitted="$(read_state "drift_warning_emitted")"
  [[ "${emitted}" == "1" ]] && return 1
  local count max_claims
  count="$(canary_session_unverified_count "${session_id}")"
  max_claims="$(canary_session_max_unverified_claims "${session_id}")"
  # Either pattern threshold or loud-session threshold fires.
  if [[ "${count}" -ge 2 ]] || [[ "${max_claims}" -ge 4 ]]; then
    return 0
  fi
  return 1
}

# Atomically test and claim the one-shot drift alert. Returning the count from
# the locked body lets the caller render prose only after this generation won
# the claim; concurrent/stale Stop callbacks return non-zero with no output.
_canary_claim_alert_locked() {
  local session_id="$1" accepted="$2" finalizer_claim_id="$3"
  local emitted count max_claims
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 1
  fi
  _canary_finalizer_claim_valid_unlocked \
    "${accepted}" "${finalizer_claim_id}" || return 1

  emitted="$(read_state "drift_warning_emitted")"
  [[ "${emitted}" != "1" ]] || return 2
  count="$(canary_session_unverified_count "${session_id}")"
  max_claims="$(canary_session_max_unverified_claims "${session_id}")"
  if [[ "${count}" -lt 2 && "${max_claims}" -lt 4 ]]; then
    return 2
  fi
  _canary_finalizer_claim_valid_unlocked \
    "${accepted}" "${finalizer_claim_id}" || return 1
  _write_state_batch_unlocked "drift_warning_emitted" "1" || return 1
  printf '%s' "${count}"
}

canary_claim_alert() {
  local session_id="$1"
  local accepted="${OMC_STOP_ACCEPTED:-0}"
  local finalizer_claim_id="${OMC_CLOSEOUT_FINALIZATION_CLAIM_ID:-}"
  [[ -n "${session_id}" && "${SESSION_ID:-}" == "${session_id}" ]] \
    || return 1
  if [[ "${accepted}" == "1" \
      && ! "${finalizer_claim_id}" =~ ^finalizer-[a-f0-9]{48}$ ]]; then
    return 1
  fi
  with_state_lock _canary_claim_alert_locked "${session_id}" \
    "${accepted}" "${finalizer_claim_id}"
}
