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
# Reads the session's `timing.jsonl` (lock-free append-only log
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
  # verification set. Count distinct tool_use_id values to dedupe
  # any malformed double-emit.
  #
  # timing.jsonl schema (set by timing.sh — verify against
  # `head -3 ~/.claude/quality-pack/state/<sid>/timing.jsonl` if you
  # see schema drift):
  #   {kind, ts, tool, prompt_seq, tool_use_id} for tool start/end
  #   {kind:"prompt_start"|"prompt_end", ts, prompt_seq, ...} for prompt boundaries
  jq -r --arg ps "${prompt_seq}" '
    select(.kind == "start"
           and (.prompt_seq // "" | tostring) == $ps
           and (.tool | IN("Read","Bash","Grep","Glob","WebFetch","NotebookRead")))
    | .tool_use_id // empty
  ' "${timing_file}" 2>/dev/null | sort -u | wc -l | tr -d ' '
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
  [[ ! -f "${sf}" ]] && return
  jq -r '.prompt_seq // empty' "${sf}" 2>/dev/null || true
}

# canary_run_audit <session_id>
#
# The hot path. Called from canary-claim-audit.sh at Stop time. Reads
# the model's last assistant message, extracts the claim count, reads
# the turn's verification tool count, and writes one canary.jsonl row
# describing the audit result. Always exit-0 (audit failures must not
# block Stop).
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
# Returns 0 always. On error, logs to hooks.log via log_hook and exits
# 0 — the canary is informational and must not become a failure mode.
canary_run_audit() {
  local session_id="$1"
  [[ -z "${session_id}" ]] && return 0

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

  local row
  row="$(jq -nc \
    --arg ts "$(now_epoch)" \
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
    return 0
  fi

  local sess_jsonl
  sess_jsonl="$(session_file "canary.jsonl")"
  printf '%s\n' "${row}" >> "${sess_jsonl}"
  # Cap per-session canary log to prevent runaway. 200 rows is enough
  # to track a long session; older rows roll off.
  if [[ "$(wc -l < "${sess_jsonl}" 2>/dev/null || printf 0)" -gt 200 ]]; then
    tail -n 200 "${sess_jsonl}" > "${sess_jsonl}.tmp" && mv "${sess_jsonl}.tmp" "${sess_jsonl}"
  fi

  # Cross-session aggregate at ~/.claude/quality-pack/canary.jsonl.
  # Stamped with project_key (git-remote-first, cwd-hash fallback) so
  # /ulw-report can split by project. Capped via existing helper.
  local xs_jsonl="${HOME}/.claude/quality-pack/canary.jsonl"
  mkdir -p "$(dirname "${xs_jsonl}")" 2>/dev/null || true
  local project_key
  project_key="$(_omc_project_key 2>/dev/null || printf 'unknown')"
  jq -nc \
    --arg ts "$(now_epoch)" \
    --arg pk "${project_key}" \
    --arg sid "${session_id}" \
    --arg ps "${prompt_seq}" \
    --argjson cc "${claim_count}" \
    --argjson tc "${tool_count}" \
    --argjson rp "${ratio_pct}" \
    --arg verdict "${verdict}" \
    '{ts: ($ts|tonumber), project_key: $pk, session_id: $sid, prompt_seq: $ps, claim_count: $cc, tool_count: $tc, ratio_pct: $rp, verdict: $verdict}' \
    >> "${xs_jsonl}" 2>/dev/null || true

  if command -v _cap_cross_session_jsonl >/dev/null 2>&1; then
    _cap_cross_session_jsonl "${xs_jsonl}" 10000 8000 || true
  fi

  # Also emit a gate-event row when the verdict is unverified (the
  # strongest single-event signal). /ulw-report consumes gate_events
  # for the bias-defense + canary surfaces.
  if [[ "${verdict}" == "unverified" ]]; then
    record_gate_event "canary" "unverified_claim" \
      "claim_count=${claim_count}" \
      "tool_count=${tool_count}" \
      "prompt_seq=${prompt_seq}"
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

# canary_should_alert <session_id>
#
# Returns 0 (true) when the session has crossed the unverified-claim
# alert threshold AND the soft alert has not yet been emitted this
# session. The alert is one-shot per session — drift_warning_emitted
# state flag prevents repetition.
#
# Threshold: >= 2 unverified verdicts in the session. Two is enough to
# distinguish noise (a single confused claim under unusual prose) from
# pattern (the model is consistently claiming verification work it
# isn't doing).
canary_should_alert() {
  local session_id="$1"
  local emitted
  emitted="$(read_state "drift_warning_emitted")"
  [[ "${emitted}" == "1" ]] && return 1
  local count
  count="$(canary_session_unverified_count "${session_id}")"
  [[ "${count}" -ge 2 ]]
}
