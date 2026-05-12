#!/usr/bin/env bash
#
# SessionStart resume-hint hook.
#
# Fires on EVERY SessionStart (resume|startup|compact|clear), no matcher.
# Scans STATE_ROOT/*/resume_request.json for an unclaimed artifact whose
# rate-limit window has cleared, and surfaces the original objective +
# matcher + reset timing as `additionalContext` so the model knows there
# is a pending /ulw resume to claim.
#
# Match precedence (most-relevant first):
#   1. cwd-match     — artifact's .cwd equals new session's cwd.
#   2. project-match — artifact's .project_key equals new session's
#                      _omc_project_key (worktree / clone-anywhere stable).
#   3. other-cwd     — artifact exists for a different project entirely.
# The hint labels the match scope so the user/model can decide.
#
# Idempotency rules:
#   1. Per-session-AND-per-artifact: writes
#      `resume_hint_emitted_<origin_session_id>=1` after a successful
#      emit. The hook is no-op on subsequent SessionStart fires within
#      the same session for the SAME artifact, but a *different*
#      claimable artifact in the same session can still be hinted.
#      Replaces the original `resume_hint_emitted` boolean which leaked
#      across `--resume` boundaries via the resume-handoff state copy.
#   2. Cross-session: this hook NEVER claims the artifact (Wave 2's
#      claim-resume-request.sh is the SSOT for claim). The hint can
#      legitimately re-emit across many sessions until claimed; the
#      OMC_RESUME_REQUEST_TTL_DAYS sweep (default 7d) bounds re-emission.
#
# Privacy: respects `is_stop_failure_capture_enabled` — opt-out at the
# producer (StopFailure) implies opt-out at the consumer (this hook).

set -euo pipefail


. "${HOME}/.claude/skills/autowork/scripts/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
SOURCE="$(json_get '.source')"
HOOK_CWD="$(json_get '.cwd')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

if ! is_stop_failure_capture_enabled; then
  exit 0
fi

ensure_session_dir

# v1.32.8: tag the session with project_key BEFORE any record_gate_event
# call so the sweep aggregator can correctly tag cross-session
# telemetry rows for multi-project /ulw-report slicing. See
# common.sh:record_project_key_if_unset for the rationale (was
# router-only pre-1.32.8; non-ULW sessions slipped past).
record_project_key_if_unset

target_cwd="${HOOK_CWD:-${PWD}}"

# Compute the project key for the new session. Best-effort — when the
# cwd is not a git repo this falls back to a cwd-hash, which still
# matches a same-cwd artifact via the cwd-match path. Failures are
# silently tolerated.
target_project_key=""
if [[ -d "${target_cwd}" ]]; then
  target_project_key="$(cd "${target_cwd}" 2>/dev/null && _omc_project_key 2>/dev/null || true)"
fi

claimable_jsonl="$(find_claimable_resume_requests || true)"
if [[ -z "${claimable_jsonl}" ]]; then
  exit 0
fi

# Single-pass JSON summary: pick the best-scoped match and capture
# total / cwd-match / project-match counts in one jq invocation.
# Output format: a single-line JSON object the bash side parses out.
summary_json="$(printf '%s\n' "${claimable_jsonl}" \
  | jq -s -c \
      --arg cwd "${target_cwd}" \
      --arg key "${target_project_key}" \
      '
      def best:
        (map(select(.cwd == $cwd)) | first // null) as $cwd_match
        | (map(select($key != "" and (.project_key // "") == $key)) | first // null) as $proj_match
        | (.[0] // null) as $any_match
        | if $cwd_match != null then {scope: "cwd-match", row: $cwd_match}
          elif $proj_match != null then {scope: "project-match", row: $proj_match}
          elif $any_match != null then {scope: "other-cwd", row: $any_match}
          else null end;
      {
        total: length,
        cwd_count: (map(select(.cwd == $cwd)) | length),
        project_count: (map(select($key != "" and (.project_key // "") == $key)) | length),
        match: best
      }
      ' 2>/dev/null || true)"

if [[ -z "${summary_json}" ]] || [[ "${summary_json}" == "null" ]]; then
  exit 0
fi

if [[ "$(printf '%s' "${summary_json}" | jq -r '.match // null')" == "null" ]]; then
  exit 0
fi

match_scope="$(printf '%s' "${summary_json}" | jq -r '.match.scope')"
match_row="$(printf '%s' "${summary_json}" | jq -c '.match.row')"
total_pending="$(printf '%s' "${summary_json}" | jq -r '.total')"
cwd_match_count="$(printf '%s' "${summary_json}" | jq -r '.cwd_count')"
project_match_count="$(printf '%s' "${summary_json}" | jq -r '.project_count')"

match_path="$(printf '%s' "${match_row}" | jq -r '.path // ""')"
if [[ -z "${match_path}" ]] || [[ ! -f "${match_path}" ]]; then
  exit 0
fi

origin_session="$(printf '%s' "${match_row}" | jq -r '.session_id // ""')"
matcher="$(printf '%s' "${match_row}" | jq -r '.matcher // "unknown"')"
rate_limited="$(printf '%s' "${match_row}" | jq -r '.rate_limited // false')"
objective="$(printf '%s' "${match_row}" | jq -r '.original_objective // ""')"
last_prompt="$(printf '%s' "${match_row}" | jq -r '.last_user_prompt // ""')"
artifact_cwd="$(printf '%s' "${match_row}" | jq -r '.cwd // ""')"
# All numerics are pre-normalized by find_claimable_resume_requests, but
# guard with a regex check before bash arithmetic in case the upstream
# helper is replaced with a less-defensive one in the future.
resets_at="$(printf '%s' "${match_row}" | jq -r '(.resets_at_ts // empty) | tostring')"
captured_at="$(printf '%s' "${match_row}" | jq -r '(.captured_at_ts // 0) | tostring')"
[[ "${resets_at}" =~ ^[0-9]+$ ]] || resets_at=""
[[ "${captured_at}" =~ ^[0-9]+$ ]] || captured_at="0"

# Per-session-AND-per-artifact idempotency. Validate the origin session
# id before using it as a key suffix — defense against a corrupted
# artifact poisoning the state file. validate_session_id rejects
# slashes, dots-only, > 128 chars, and characters outside [a-zA-Z0-9_.-].
hint_key="resume_hint_emitted"
if [[ -n "${origin_session}" ]] && validate_session_id "${origin_session}"; then
  hint_key="resume_hint_emitted_${origin_session}"
fi

if [[ "$(read_state "${hint_key}")" == "1" ]]; then
  exit 0
fi

now_ts="$(now_epoch)"

# Humanize a non-negative seconds delta. Singular vs plural.
humanize_delta() {
  local delta="$1"
  if (( delta < 60 )); then
    if (( delta <= 1 )); then printf 'just now'; else printf '%d seconds ago' "${delta}"; fi
  elif (( delta < 3600 )); then
    local m=$((delta / 60))
    if (( m == 1 )); then printf '1 minute ago'; else printf '%d minutes ago' "${m}"; fi
  elif (( delta < 86400 )); then
    local h=$((delta / 3600))
    if (( h == 1 )); then printf '1 hour ago'; else printf '%d hours ago' "${h}"; fi
  else
    local d=$((delta / 86400))
    if (( d == 1 )); then printf '1 day ago'; else printf '%d days ago' "${d}"; fi
  fi
}

reset_text=""
if [[ -n "${resets_at}" ]]; then
  delta=$(( now_ts - resets_at ))
  if (( delta >= 0 )); then
    reset_text="rate cap cleared $(humanize_delta "${delta}")"
  else
    # Defensive: find_claimable_resume_requests filters out future
    # resets, but record the inconsistency to the anomaly log so it is
    # not silently swallowed if the helper gains a bug in the future.
    log_anomaly "session-start-resume-hint" \
      "future reset epoch reached consumer despite filter (resets_at=${resets_at} now=${now_ts}); skipping"
    exit 0
  fi
elif [[ "${rate_limited}" == "true" ]]; then
  reset_text="rate cap reset epoch unknown — proceed only after manual confirmation"
else
  reset_text="non-rate-limit stop (matcher=${matcher}); informational only"
fi

captured_text=""
if [[ "${captured_at}" -gt 0 ]]; then
  captured_text=" Captured $(humanize_delta $((now_ts - captured_at)))."
fi

# Cwd labeling. Multiple notes can apply (e.g. cross-cwd AND missing).
cwd_notes=""
if [[ "${match_scope}" == "project-match" ]]; then
  cwd_notes+=" Same project, different working directory (${artifact_cwd})."
elif [[ "${match_scope}" == "other-cwd" ]]; then
  cwd_notes+=" The artifact was recorded in a different working directory (${artifact_cwd}); confirm before resuming."
fi
if [[ -n "${artifact_cwd}" && ! -d "${artifact_cwd}" ]]; then
  cwd_notes+=" The artifact's working directory (${artifact_cwd}) no longer exists; resuming may fail."
fi

multi_text=""
if (( total_pending > 1 )); then
  multi_text=" There are ${total_pending} unclaimed resume requests on disk (${cwd_match_count} match this cwd, ${project_match_count} match this project); the most-relevant one is shown."
fi

# Wave-2-readiness pre-check. If `/ulw-resume` skill is installed, the
# hint advises invoking it directly. Otherwise (early-adopter / partial
# install) the hint provides a manual fallback so the user is not told
# to invoke a skill that does not exist.
ulw_resume_skill="${HOME}/.claude/skills/ulw-resume/SKILL.md"
resume_advice=""
if [[ -f "${ulw_resume_skill}" ]]; then
  resume_advice="To resume the prior /ulw task as-if-uninterrupted, invoke the \`/ulw-resume\` skill. It atomically claims this resume request, replays the original objective into the current session, and continues the work without losing scope."
else
  resume_advice="The \`/ulw-resume\` skill is not yet installed in this harness. To manually resume, paste this command back to the user as a paste-ready imperative: \`/ulw <restate the original objective above>\`. The skill landing in Wave 2 will automate the atomic claim — for now, the manual replay is the recommended path."
fi

obj_trimmed="$(truncate_chars 600 "${objective}")"
prompt_trimmed="$(truncate_chars 800 "${last_prompt}")"

context="A previous Claude Code session was terminated by a StopFailure (matcher=${matcher}; ${reset_text}).${captured_text}${cwd_notes}${multi_text}

Original objective from the interrupted session:
${obj_trimmed:-(none recorded)}

Verbatim last user prompt:
${prompt_trimmed:-(none recorded)}

${resume_advice} If the prior task is no longer relevant, ignore this hint and proceed with the user's current prompt — the artifact will time out automatically after ${OMC_RESUME_REQUEST_TTL_DAYS:-7} days (artifact session_id=${origin_session}, scope=${match_scope})."

# Build the JSON payload BEFORE any state mutation so a jq failure
# does not record telemetry for a hint that was never actually emitted.
hint_payload="$(jq -nc --arg context "${context}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || true)"

if [[ -z "${hint_payload}" ]]; then
  log_anomaly "session-start-resume-hint" "failed to compose hint payload"
  exit 0
fi

# Sidecar: write the rendered context to <new-session>/resume_hint.md so
# /ulw-status can surface it and the future Wave 3 watchdog has a paper
# trail of what was hinted to whom and when. Not load-bearing — failure
# is silently tolerated.
sidecar="$(session_file 'resume_hint.md')"
{
  printf -- '---\n'
  printf 'origin_session_id: %s\n' "${origin_session}"
  printf 'artifact_path: %s\n' "${match_path}"
  printf 'match_scope: %s\n' "${match_scope}"
  printf 'matcher: %s\n' "${matcher}"
  printf 'emitted_at_ts: %s\n' "${now_ts}"
  printf 'source: %s\n' "${SOURCE:-unknown}"
  printf -- '---\n'
  printf '%s\n' "${context}"
} > "${sidecar}" 2>/dev/null || true

write_state "${hint_key}" "1"

record_gate_event "session-start-resume" "resume-hint-emitted" \
  matcher="${matcher}" \
  rate_limited="${rate_limited}" \
  match_scope="${match_scope}" \
  pending_count="${total_pending}" \
  cwd_match_count="${cwd_match_count}" \
  project_match_count="${project_match_count}" \
  origin_session="${origin_session}" \
  source="${SOURCE:-unknown}"

log_hook "session-start-resume-hint" "emitted matcher=${matcher} pending=${total_pending} scope=${match_scope} origin=${origin_session}"

printf '%s\n' "${hint_payload}"
