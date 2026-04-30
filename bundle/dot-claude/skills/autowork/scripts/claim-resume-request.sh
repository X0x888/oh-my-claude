#!/usr/bin/env bash
#
# claim-resume-request.sh — atomically claim the most relevant unclaimed
# `resume_request.json` and emit its pre-claim contents on stdout for
# the caller (the `/ulw-resume` skill, the Wave 3 watchdog, or a test).
#
# Single source of truth for the cross-session claim. Every consumer
# that mutates `resumed_at_ts` / `resume_attempts` / `last_attempt_*`
# fields on `resume_request.json` MUST go through this helper so the
# claim race between Wave 1 hint, Wave 2 skill, and Wave 3 watchdog
# resolves to exactly one winner.
#
# Usage:
#   claim-resume-request.sh [--peek] [--cwd PATH] [--session-id SID]
#                            [--target PATH] [--list]
#                            [--watchdog-launch <pid>]
#
# Filters:
#   --cwd PATH         Prefer artifacts whose .cwd matches PATH (default $PWD).
#                      When no exact match, falls back to project_key match,
#                      then to most recent. Match scope is reported in stderr.
#   --session-id SID   Pin to the artifact whose .session_id equals SID;
#                      ignores cwd/project filters.
#   --target PATH      Pin to a specific resume_request.json path (highest
#                      precedence; the watchdog uses this to claim the exact
#                      artifact it scanned).
#
# Modes:
#   --peek             Read-only inspection. Prints the artifact without
#                      mutating it. No lock acquired (read-only is safe).
#   --list             Print one line per claimable artifact:
#                      `<scope> <session_id> <captured_at_ts> <path>`.
#                      Read-only, no lock.
#   --watchdog-launch <pid>
#                      Run the claim with watchdog semantics: stamps
#                      last_attempt_pid + last_attempt_ts +
#                      last_attempt_outcome="watchdog-launched" and bumps
#                      resume_attempts. Used by the Wave 3 daemon.
#
# Stdout (non-peek success): pre-claim JSON of the claimed artifact, with
#   one synthesized field `_claimed_path` containing the path that was
#   claimed.
# Stdout (peek success): the raw artifact contents, plus `_claimed_path`.
# Stdout (no match): empty.
#
# Exit codes:
#   0  — success (claimed, peeked, or listed)
#   1  — no claimable artifact found (with optional filters)
#   2  — lock contention beyond timeout, or atomic write failed
#
# Privacy: when stop_failure_capture is OFF (`is_stop_failure_capture_enabled`
# returns false) the helper exits 1 — the producer-side opt-out implies
# the consumer-side opt-out. No artifacts means nothing to claim.

set -euo pipefail

# shellcheck source=/dev/null
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

mode="claim"
filter_cwd=""
filter_sid=""
filter_target=""
watchdog_pid=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --peek)
      mode="peek"; shift ;;
    --list)
      mode="list"; shift ;;
    --dismiss)
      mode="dismiss"; shift ;;
    --watchdog-launch)
      mode="watchdog"; shift
      watchdog_pid="${1:-}"; shift || true ;;
    --cwd)
      shift
      filter_cwd="${1:-}"; shift || true ;;
    --session-id)
      shift
      filter_sid="${1:-}"; shift || true ;;
    --target)
      shift
      filter_target="${1:-}"; shift || true ;;
    -h|--help)
      sed -n '2,50p' "$0"
      exit 0 ;;
    *)
      printf 'claim-resume-request: unknown arg: %s\n' "$1" >&2
      exit 64 ;;
  esac
done

# Watchdog launch must be pinned to a specific artifact via --target
# or --session-id. Without a pin the watchdog can race itself across
# iterations and claim a sibling artifact when multiple are active —
# the daemon process is global, so its $PWD is meaningless for cwd-
# filter purposes. Wave 3's daemon must enumerate via --list first,
# then call --watchdog-launch --target <picked> to claim atomically.
if [[ "${mode}" == "watchdog" ]] \
   && [[ -z "${filter_target}" ]] \
   && [[ -z "${filter_sid}" ]]; then
  printf 'claim-resume-request: --watchdog-launch requires --target <path> or --session-id <sid>\n' >&2
  exit 64
fi

if ! is_stop_failure_capture_enabled; then
  exit 1
fi

# When no explicit cwd filter was passed, default to PWD so the
# common path "user opened claude in their project" picks the
# right artifact without forcing the caller to thread $PWD. List
# mode also defaults so the scope column ("cwd-match") is meaningful.
if [[ -z "${filter_cwd}" ]] && [[ -z "${filter_sid}" ]] && [[ -z "${filter_target}" ]]; then
  filter_cwd="${PWD}"
fi

# Resolve project key for the filter cwd (best effort).
filter_project_key=""
if [[ -n "${filter_cwd}" ]] && [[ -d "${filter_cwd}" ]]; then
  filter_project_key="$(cd "${filter_cwd}" 2>/dev/null && _omc_project_key 2>/dev/null || true)"
fi

# Find all claimable artifacts via the canonical helper.
claimable_jsonl="$(find_claimable_resume_requests || true)"
if [[ -z "${claimable_jsonl}" ]]; then
  exit 1
fi

# Pick the artifact based on filters (most-specific wins).
pick_artifact() {
  local jsonl="$1"
  local target="$2"
  local sid="$3"
  local cwd="$4"
  local pkey="$5"

  if [[ -n "${target}" ]]; then
    printf '%s\n' "${jsonl}" \
      | jq -c --arg p "${target}" 'select(.path == $p)' 2>/dev/null \
      | head -1
    return 0
  fi

  if [[ -n "${sid}" ]]; then
    printf '%s\n' "${jsonl}" \
      | jq -c --arg s "${sid}" 'select(.session_id == $s)' 2>/dev/null \
      | head -1
    return 0
  fi

  # cwd-match: artifact's cwd equals filter cwd.
  local row
  row="$(printf '%s\n' "${jsonl}" \
    | jq -c --arg c "${cwd}" 'select(.cwd == $c)' 2>/dev/null \
    | head -1)"
  if [[ -n "${row}" ]]; then
    printf '%s' "${row}"
    return 0
  fi

  # project-match: artifact's project_key matches.
  if [[ -n "${pkey}" ]]; then
    row="$(printf '%s\n' "${jsonl}" \
      | jq -c --arg k "${pkey}" 'select((.project_key // "") == $k)' 2>/dev/null \
      | head -1)"
    if [[ -n "${row}" ]]; then
      printf '%s' "${row}"
      return 0
    fi
  fi

  # Fallback: most recent overall (find_claimable_resume_requests
  # already sorts by captured_at_ts desc).
  printf '%s\n' "${jsonl}" | head -1
}

# --- list mode: print one row per claimable artifact, exit ---
if [[ "${mode}" == "list" ]]; then
  printf '%s\n' "${claimable_jsonl}" | jq -r --arg c "${filter_cwd}" --arg k "${filter_project_key}" '
    def scope:
      if .cwd == $c then "cwd-match"
      elif ($k != "" and (.project_key // "") == $k) then "project-match"
      else "other-cwd" end;
    [scope, .session_id, (.captured_at_ts // 0 | tostring), .path] | @tsv
  ' 2>/dev/null
  exit 0
fi

# Pick the artifact. Empty result → no claimable match given the filters.
target_row="$(pick_artifact "${claimable_jsonl}" "${filter_target}" "${filter_sid}" "${filter_cwd}" "${filter_project_key}")"
if [[ -z "${target_row}" ]]; then
  exit 1
fi

target_path="$(printf '%s' "${target_row}" | jq -r '.path // ""')"
target_sid="$(printf '%s' "${target_row}" | jq -r '.session_id // ""')"

if [[ -z "${target_path}" ]] || [[ ! -f "${target_path}" ]]; then
  exit 1
fi

# Determine match scope for telemetry (informational).
if [[ -n "${filter_target}" ]]; then
  match_scope="explicit-target"
elif [[ -n "${filter_sid}" ]]; then
  match_scope="explicit-session-id"
elif [[ "$(printf '%s' "${target_row}" | jq -r --arg c "${filter_cwd}" 'if .cwd == $c then "1" else "0" end')" == "1" ]]; then
  match_scope="cwd-match"
elif [[ -n "${filter_project_key}" ]] \
  && [[ "$(printf '%s' "${target_row}" | jq -r --arg k "${filter_project_key}" 'if (.project_key // "") == $k then "1" else "0" end')" == "1" ]]; then
  match_scope="project-match"
else
  match_scope="other-cwd"
fi

# --- peek mode: print and exit, no mutation, no lock ---
if [[ "${mode}" == "peek" ]]; then
  jq -c --arg path "${target_path}" --arg scope "${match_scope}" \
    '. + {_claimed_path: $path, _match_scope: $scope, _peek: true}' \
    "${target_path}" 2>/dev/null
  exit 0
fi

# Empty-payload guard. If both original_objective AND last_user_prompt
# are empty, the artifact is structurally unrecoverable — a successful
# claim would consume the artifact and leave the model with nothing to
# replay. Refuse to claim (or dismiss) and emit a clear gate-event row
# so the operator knows why the artifact lingered. The user can still
# inspect it via --peek and act manually.
if [[ "${mode}" == "claim" ]] || [[ "${mode}" == "watchdog" ]]; then
  _objective_empty="$(jq -r '(.original_objective // "") | length' "${target_path}" 2>/dev/null || echo 0)"
  _prompt_empty="$(jq -r '(.last_user_prompt // "") | length' "${target_path}" 2>/dev/null || echo 0)"
  if [[ "${_objective_empty}" == "0" ]] && [[ "${_prompt_empty}" == "0" ]]; then
    record_gate_event "ulw-resume" "claim-rejected-empty-payload" \
      mode="${mode}" \
      origin_session="${target_sid}"
    printf 'claim-resume-request: artifact has empty original_objective and last_user_prompt; nothing to replay (use --peek to inspect or --dismiss to suppress future hints)\n' >&2
    exit 1
  fi
fi

# --- claim, watchdog, or dismiss: atomic write under cross-session lock ---
do_claim() {
  # Re-read the artifact under the lock — defends against TOCTOU even
  # though the lock prevents the race in practice. Cheap insurance.
  if [[ ! -f "${target_path}" ]]; then
    return 1
  fi
  if ! jq -e . "${target_path}" >/dev/null 2>&1; then
    return 1
  fi

  local current_attempts current_resumed current_dismissed
  current_attempts="$(jq -r '(.resume_attempts // 0)' "${target_path}" 2>/dev/null || echo 0)"
  current_resumed="$(jq -r '(.resumed_at_ts // null)' "${target_path}" 2>/dev/null || echo null)"
  current_dismissed="$(jq -r '(.dismissed_at_ts // null)' "${target_path}" 2>/dev/null || echo null)"

  # Sanity: numeric coercion.
  current_attempts="${current_attempts%%.*}"
  current_attempts="${current_attempts//[!0-9]/}"
  current_attempts="${current_attempts:-0}"

  case "${mode}" in
    claim)
      # /ulw-resume claim: artifact must be unclaimed AND undismissed AND no prior attempts.
      if [[ "${current_resumed}" != "null" ]] \
         || [[ "${current_dismissed}" != "null" ]] \
         || [[ "${current_attempts}" != "0" ]]; then
        return 1
      fi
      ;;
    watchdog)
      # Watchdog launch: allow retries but bail when the CUMULATIVE
      # chain-depth + per-artifact attempts exceed the cap. The 3-attempt
      # cap (was per-artifact in Wave 3 v1) is now origin_chain_depth +
      # current_attempts so a watchdog-launched session that itself
      # rate-limits cannot reset the counter to 0 by writing a new
      # artifact. origin_chain_depth is propagated by
      # session-start-resume-handoff.sh + stop-failure-handler.sh.
      # Dismissed artifacts are also blocked — the user explicitly
      # rejected this resume.
      local chain_depth
      chain_depth="$(jq -r '((.origin_chain_depth // 0) | tonumber? // 0)' "${target_path}" 2>/dev/null || echo 0)"
      chain_depth="${chain_depth%%.*}"
      chain_depth="${chain_depth//[!0-9]/}"
      chain_depth="${chain_depth:-0}"
      if [[ "$(( chain_depth + current_attempts ))" -ge 3 ]] \
         || [[ "${current_dismissed}" != "null" ]]; then
        return 1
      fi
      ;;
    dismiss)
      # /ulw-resume --dismiss: stamp dismissed_at_ts to suppress future
      # hints. Refuse if already claimed (the resume already ran) or
      # already dismissed (idempotent — return 0 either way is fine,
      # but exit 1 makes the second dismiss a clean no-op).
      if [[ "${current_resumed}" != "null" ]] \
         || [[ "${current_dismissed}" != "null" ]]; then
        return 1
      fi
      ;;
    *)
      return 2 ;;
  esac

  local now_ts
  now_ts="$(now_epoch)"

  local jq_filter
  if [[ "${mode}" == "dismiss" ]]; then
    # Dismiss does NOT bump resume_attempts and does NOT set
    # resumed_at_ts — only stamps the dismissed_at_ts marker so
    # find_claimable_resume_requests filters it out going forward.
    jq_filter='. + {
      dismissed_at_ts: $now,
      last_attempt_ts: $now,
      last_attempt_outcome: "user-dismissed"
    }'
  else
    local new_attempts new_outcome
    new_attempts=$(( current_attempts + 1 ))
    if [[ "${mode}" == "watchdog" ]]; then
      new_outcome="watchdog-launched"
    else
      new_outcome="session-claimed"
    fi
    jq_filter='. + {
      resumed_at_ts: $now,
      resume_attempts: ($attempts | tonumber),
      last_attempt_ts: $now,
      last_attempt_outcome: $outcome,
      last_attempt_pid: (if $pid == "" then null else ($pid | tonumber? // null) end)
    }'
    # Bind the args via top-level shadow (used in jq -c below).
    _attempts_arg="${new_attempts}"
    _outcome_arg="${new_outcome}"
  fi

  local tmp="${target_path}.tmp.$$"
  if [[ "${mode}" == "dismiss" ]]; then
    if ! jq -c \
        --argjson now "${now_ts}" \
        "${jq_filter}" \
        "${target_path}" >"${tmp}" 2>/dev/null; then
      rm -f "${tmp}" 2>/dev/null || true
      return 2
    fi
  else
    if ! jq -c \
        --argjson now "${now_ts}" \
        --arg attempts "${_attempts_arg}" \
        --arg outcome "${_outcome_arg}" \
        --arg pid "${watchdog_pid:-}" \
        "${jq_filter}" \
        "${target_path}" >"${tmp}" 2>/dev/null; then
      rm -f "${tmp}" 2>/dev/null || true
      return 2
    fi
  fi

  if ! mv -f "${tmp}" "${target_path}"; then
    rm -f "${tmp}" 2>/dev/null || true
    return 2
  fi

  return 0
}

# Capture the pre-claim contents BEFORE the claim mutates the file. That's
# what the caller (skill / watchdog) prints to the model — they need
# the original objective, not the post-claim record.
pre_claim_json="$(jq -c \
  --arg path "${target_path}" \
  --arg scope "${match_scope}" \
  '. + {_claimed_path: $path, _match_scope: $scope}' \
  "${target_path}" 2>/dev/null || true)"

if [[ -z "${pre_claim_json}" ]]; then
  exit 2
fi

claim_rc=0
with_resume_lock do_claim || claim_rc=$?

case "${claim_rc}" in
  0)
    if [[ "${mode}" == "dismiss" ]]; then
      record_gate_event "ulw-resume" "dismiss-recorded" \
        origin_session="${target_sid}" \
        match_scope="${match_scope}"
      log_hook "claim-resume-request" "dismissed origin=${target_sid} scope=${match_scope}"
      jq -c --arg path "${target_path}" --arg scope "${match_scope}" \
        '. + {_claimed_path: $path, _match_scope: $scope, _dismissed: true}' \
        "${target_path}" 2>/dev/null
    else
      record_gate_event "ulw-resume" "claim-success" \
        mode="${mode}" \
        origin_session="${target_sid}" \
        match_scope="${match_scope}"
      log_hook "claim-resume-request" "claimed mode=${mode} origin=${target_sid} scope=${match_scope}"
      printf '%s\n' "${pre_claim_json}"
    fi
    exit 0 ;;
  1)
    # Artifact was claimed by another process between our scan and our
    # write — race against another claimer. Caller can retry.
    record_gate_event "ulw-resume" "claim-race-lost" \
      mode="${mode}" \
      origin_session="${target_sid}"
    exit 1 ;;
  2|*)
    record_gate_event "ulw-resume" "claim-failed" \
      mode="${mode}" \
      origin_session="${target_sid}"
    exit 2 ;;
esac
