#!/usr/bin/env bash

set -euo pipefail

# v1.27.0 (F-020 / F-021): plan-recording hook does state I/O only — no
# classifier or timing-lib dependency.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

_OMC_HOOK_CALLER_PATH="${PATH:-}"
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
# Ambient recovery flags are not authority. Internal recovery is selected only
# by the exact argv modes below and uses a process-local state-lock capability.
unset OMC_PUBLICATION_RECOVERY_INTERNAL

# Deterministic process-death/failure boundaries for the planner publication
# transaction. Production callers leave both variables unset. Tests use the
# named boundaries to prove rollback and commit behavior.
_plan_transaction_boundary() {
  local boundary="$1"
  if [[ "${OMC_TEST_PLAN_TXN_PAUSE_AT:-}" == "${boundary}" ]]; then
    local ready release attempts=0
    ready="$(session_file ".test-plan-txn-pause-ready")"
    release="$(session_file ".test-plan-txn-pause-release")"
    : >"${ready}" || return 1
    while [[ ! -e "${release}" && "${attempts}" -lt 1000 ]]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
    rm -f "${ready}" "${release}" 2>/dev/null || true
    (( attempts < 1000 )) || return 1
  fi
  if [[ "${OMC_TEST_PLAN_TXN_KILL_AT:-}" == "${boundary}" ]]; then
    kill -9 "$$"
  fi
  [[ "${OMC_TEST_PLAN_TXN_FAIL_AT:-}" != "${boundary}" ]]
}

# shellcheck source=lib/plan-publication-transaction.sh
. "${SCRIPT_DIR}/lib/plan-publication-transaction.sh"

# Cold SessionStart cannot resume the old native callback. This internal mode
# rolls back the exact active planner transaction, converts its snapshot-bound
# causal rows to abandonment tombstones, and returns one deterministic rebind
# identity for a fresh equivalent planner. No hook payload is read.
if [[ "${1:-}" == "--recover-cold-resume" ]]; then
  [[ "$#" -eq 2 ]] || exit 1
  SESSION_ID="$2"
  validate_session_id "${SESSION_ID}" 2>/dev/null || exit 1
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 1
  ensure_session_dir
  _plan_cold_recovery_lock_attempts="${OMC_RECORD_PLAN_LOCK_MAX_ATTEMPTS:-200}"
  if [[ ! "${_plan_cold_recovery_lock_attempts}" =~ ^[1-9][0-9]*$ \
      || "${_plan_cold_recovery_lock_attempts}" -gt 2000 ]]; then
    _plan_cold_recovery_lock_attempts=200
  fi
  _recover_cold_plan_publication_unlocked() {
    _recover_plan_transaction_for_cold_resume_unlocked
  }
  _with_cold_plan_recovery_lock() {
    local OMC_STATE_LOCK_MAX_ATTEMPTS="${_plan_cold_recovery_lock_attempts}"
    with_state_lock_publication_recovery "$@"
  }
  if ! _with_cold_plan_recovery_lock \
      _recover_cold_plan_publication_unlocked; then
    log_anomaly "record-plan" \
      "cold-resume planner publication recovery failed (${SESSION_ID})"
    exit 1
  fi
  jq -nc \
    --argjson recovered "${_plan_cold_resume_recovered:-0}" \
    --arg lifecycle_dispatch_id "${_plan_cold_resume_lifecycle_id:-}" \
    --arg native_agent_id "${_plan_cold_resume_native_id:-}" \
    --arg agent_type "${_plan_cold_resume_agent_type:-}" \
    --arg rebind_id "${_plan_cold_resume_rebind_id:-}" '
      {
        schema_version:1,
        recovered:($recovered == 1),
        lifecycle_dispatch_id:$lifecycle_dispatch_id,
        native_agent_id:$native_agent_id,
        agent_type:$agent_type,
        rebind_id:$rebind_id
      }
    '
  exit 0

# Internal recovery surface used by prompt/session continuity hooks. It reads no
# hook payload and emits no user text. The fixed WAL is recovered under the same
# session mutex as ordinary publication, so a prompt cannot write a newer state
# generation and then have it silently overwritten by a delayed rollback.
elif [[ "${1:-}" == "--recover-active" \
    || "${1:-}" == "--recover-active-json" ]]; then
  [[ "$#" -eq 2 ]] || exit 1
  _plan_recovery_emit_json=0
  [[ "$1" == "--recover-active-json" ]] && _plan_recovery_emit_json=1
  SESSION_ID="$2"
  validate_session_id "${SESSION_ID}" 2>/dev/null || exit 1
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 1
  ensure_session_dir
  _plan_recovery_performed=0
  _plan_recovery_owner_json='{}'
  _plan_active_dir="$(session_file ".plan-txn.active")"
  if [[ -e "${_plan_active_dir}" || -L "${_plan_active_dir}" ]]; then
    # Direct planner calls that have never entered ULW still publish through
    # this WAL and need the same crash/concurrency recovery.  Once a session
    # has an enforcement interval, however, inactive authority must continue
    # to reject a stale rollback after /ulw-off.
    if [[ "$(workflow_mode)" == "ultrawork" \
        || -n "$(read_state \
          "ulw_enforcement_generation" 2>/dev/null || true)" ]]; then
      is_ultrawork_mode || exit 1
    fi
    _recover_active_plan_publication_unlocked() {
      _recover_plan_transaction_unlocked
    }
    _plan_recovery_lock_attempts="${OMC_RECORD_PLAN_LOCK_MAX_ATTEMPTS:-200}"
    if [[ ! "${_plan_recovery_lock_attempts}" =~ ^[1-9][0-9]*$ \
        || "${_plan_recovery_lock_attempts}" -gt 2000 ]]; then
      _plan_recovery_lock_attempts=200
    fi
    _with_active_plan_recovery_lock() {
      local OMC_STATE_LOCK_MAX_ATTEMPTS="${_plan_recovery_lock_attempts}"
      with_state_lock_publication_recovery "$@"
    }
    if ! _with_active_plan_recovery_lock \
        _recover_active_plan_publication_unlocked; then
      log_anomaly "record-plan" \
        "active planner publication recovery failed (${SESSION_ID})"
      exit 1
    fi
  fi
  if ! _replay_receipted_plan_summary_waiters "${SCRIPT_DIR}"; then
    log_anomaly "record-plan" \
      "receipt-bound planner summary replay failed (${SESSION_ID})"
    exit 1
  fi
  if [[ "${_plan_recovery_emit_json}" -eq 1 ]]; then
    jq -nc \
      --argjson rollback_performed "${_plan_recovery_performed:-0}" \
      --argjson owner "${_plan_recovery_owner_json}" '
        {
          schema_version:1,
          rollback_performed:($rollback_performed == 1),
          owner:$owner
        }
      '
  fi
  exit 0
elif [[ "$#" -gt 0 ]]; then
  exit 1
fi

HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
_plan_native_agent_id_raw="$(json_get '.agent_id')"
_plan_native_agent_id=""
_plan_native_agent_id_present=0
_plan_native_agent_id_invalid=0
if [[ -n "${_plan_native_agent_id_raw}" ]]; then
  _plan_native_agent_id_present=1
  if [[ "${_plan_native_agent_id_raw}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    _plan_native_agent_id="${_plan_native_agent_id_raw}"
  else
    _plan_native_agent_id_invalid=1
  fi
fi
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 1

ensure_session_dir

# Recover this publisher's fixed journal before resolving a retained universal
# claim. A killed transaction may have removed pending from the provisional
# live files even though its rollback snapshot contains the exact
# effects-complete summary-first claim. Restoring first lets the process bind
# that claim narrowly below; the later universal barrier still handles sibling
# reviewer/generic work and fails closed on a foreign claim.
_plan_entry_wal="$(session_file ".plan-txn.active")"
if { [[ -e "${_plan_entry_wal}" ]] \
      || [[ -L "${_plan_entry_wal}" ]]; }; then
  bash "${SCRIPT_DIR}/record-plan.sh" --recover-active "${SESSION_ID}" \
    </dev/null >/dev/null 2>&1 || exit 1
  [[ ! -e "${_plan_entry_wal}" && ! -L "${_plan_entry_wal}" ]] || exit 1
fi

# In the summary-first hook order the universal publisher may already have
# committed every summary effect and retained its exact effects-complete claim
# while this dedicated planner hook is still waiting to publish the plan
# receipt. Bind the process-local fence bypass only when native ID, role, and
# redacted completion digest identify exactly one such current pending row.
# Fresh incomplete claims and foreign completions remain fenced.
_plan_preexisting_claim_id=""
_plan_preexisting_pending="$(session_file "pending_agents.jsonl")"
if [[ -n "${_plan_native_agent_id}" \
    && -f "${_plan_preexisting_pending}" \
    && ! -L "${_plan_preexisting_pending}" ]]; then
  _plan_preexisting_digest="$(_omc_token_digest \
    "$(printf '%s' "${LAST_ASSISTANT_MESSAGE}" \
      | omc_redact_secrets | tr -d '\000')" 2>/dev/null || true)"
  if [[ "${_plan_preexisting_digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]]; then
    _plan_preexisting_claim_id="$(jq -Rsr \
      --arg agent "${AGENT_TYPE}" --arg native "${_plan_native_agent_id}" \
      --arg digest "${_plan_preexisting_digest}" '
        [split("\n")[] | select(length > 0)
          | (try fromjson catch null) | select(type == "object")
          | select(.agent_type == $agent
            and .native_agent_id == $native
            and (.completion_claim_digest // "") == $digest
            and (.completion_claim_effects_complete // false) == true
            and (.review_dispatch_abandoned // false) != true)
          | .completion_claim_id] as $matches
        | if ($matches | length) == 1 then $matches[0] else "" end
      ' "${_plan_preexisting_pending}" 2>/dev/null || true)"
    if [[ "${_plan_preexisting_claim_id}" \
        =~ ^completion-[A-Za-z0-9._:-]{8,160}$ ]]; then
      OMC_PUBLICATION_DEDICATED_CLAIM_ID="${_plan_preexisting_claim_id}"
    fi
  fi
fi

# Dedicated SubagentStop hooks perform substantial causal/contract reads before
# their publication lock. Settle any sibling or prior interrupted publisher now
# so those validations cannot derive an early decision from provisional state.
if ! omc_recover_active_publication_transactions "${SESSION_ID}"; then
  log_anomaly "record-plan" \
    "publication recovery barrier failed before planner validation"
  exit 1
fi
# Exercise the real pre-lock race in deterministic tests without granting an
# ambient recovery bypass: a sibling may publish waiter-only authority after
# this barrier but before this callback acquires the planner transaction lock.
_plan_transaction_boundary "after-entry-recovery" || exit 1

# Preserve direct non-ULW planner behavior, but once this session has entered
# an OMC enforcement interval the completion must belong to the exact active
# generation that dispatched it.
if [[ "$(workflow_mode)" == "ultrawork" \
    || -n "$(read_state "ulw_enforcement_generation" 2>/dev/null || true)" ]]; then
  is_ultrawork_mode || exit 0
  capture_ulw_enforcement_interval || exit 0
fi

plan_file="$(session_file "current_plan.md")"

# Parse only the exact final non-empty planner VERDICT. A rebound completion
# must echo its ID on the immediately preceding non-empty line. Quoted/example
# tokens elsewhere in a plan never authenticate a state-changing completion.
_plan_tail="$(printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" \
  | tr -d '\r' \
  | awk 'NF { previous = current; current = $0 }
         END { print previous; print current }')"
_plan_id_line="$(printf '%s\n' "${_plan_tail}" | sed -n '1p')"
_plan_final_line="$(printf '%s\n' "${_plan_tail}" | sed -n '2p')"
plan_verdict=""
_plan_dispatch_id=""
if [[ "${_plan_final_line}" =~ ^VERDICT:[[:space:]]*(PLAN_READY|NEEDS_CLARIFICATION|BLOCKED)[[:space:]]*$ ]]; then
  plan_verdict="${BASH_REMATCH[1]}"
  if [[ "${_plan_id_line}" =~ ^REVIEW_DISPATCH_ID:[[:space:]]*([A-Za-z0-9][A-Za-z0-9._-]{0,63})[[:space:]]*$ ]]; then
    _plan_dispatch_id="${BASH_REMATCH[1]}"
  fi
fi

# The universal SubagentStop hook owns continuation feedback. In a current
# tracked session this recorder stays silent on an intermediate planner return
# and, most importantly, exits before staging/publishing a plan or consuming
# the native-bound start row. The same planner call can then continue and land
# one valid terminal contract. Untracked migration sessions retain PLAN_READY
# fallback below.
if ! omc_enforced_terminal_verdict_valid \
    "${AGENT_TYPE:-quality-planner}" "${_plan_final_line}" \
    && { [[ "$(read_state "plan_dispatch_tracking_version")" == "1" ]] \
      || [[ "$(read_state "native_agent_id_tracking_version")" == "1" ]]; }; then
  exit 0
fi

# Definition payload validation happens before staging or causal-row
# consumption. The universal SubagentStop hook owns continuation feedback; by
# staying silent here, both hook orders preserve the exact planner call for its
# bounded correction turn instead of publishing a narration-only plan.
_plan_quality_required="$(read_state "quality_contract_required" 2>/dev/null || true)"
_plan_quality_definition=""
if [[ "${_plan_quality_required}" == "1" && "${plan_verdict}" == "PLAN_READY" ]]; then
  if ! _omc_load_quality_contract 2>/dev/null \
    || ! _plan_quality_definition="$(quality_contract_extract_json \
      "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null)"; then
    record_gate_event "definition-of-excellent/plan" "invalid-contract" \
      "agent=${AGENT_TYPE:-planner}" "reason=missing-or-malformed-payload" 2>/dev/null || true
    exit 0
  fi
  if [[ "$(read_state "quality_constitution_status" 2>/dev/null || true)" == "invalid" ]]; then
    record_gate_event "definition-of-excellent/plan" "invalid-contract" \
      "agent=${AGENT_TYPE:-planner}" "reason=invalid-constitution" 2>/dev/null || true
    exit 0
  fi
  _plan_required_profile_ids="$(read_state "quality_constitution_blocking_ids" 2>/dev/null || true)"
  if [[ -n "${_plan_required_profile_ids}" ]] \
    && ! jq -e --arg ids "${_plan_required_profile_ids}" '
      ($ids | split(",") | map(select(length > 0)) | sort) as $required
      | ([.standards[]? | .profile_entry_id? // empty] | unique | sort) as $present
      | all($required[]; . as $id | ($present | index($id)) != null)
    ' <<<"${_plan_quality_definition}" >/dev/null 2>&1; then
    record_gate_event "definition-of-excellent/plan" "invalid-contract" \
      "agent=${AGENT_TYPE:-planner}" "reason=blocking-constitution-id-omitted" 2>/dev/null || true
    exit 0
  fi
  _plan_existing_contract_file="$(session_file "quality_contract.json")"
  if [[ -n "$(read_state "first_mutation_ts" 2>/dev/null || true)" ]]; then
    if [[ ! -e "${_plan_existing_contract_file}" \
        && ! -L "${_plan_existing_contract_file}" ]]; then
      # Structural planner mistakes are corrected through the retained native
      # planner context. Do not turn a late first contract into a hook crash,
      # but also never publish it after implementation has begun.
      record_gate_event "definition-of-excellent/plan" "invalid-contract" \
        "agent=${AGENT_TYPE:-planner}" "reason=late-first-contract" 2>/dev/null || true
      exit 0
    elif [[ -f "${_plan_existing_contract_file}" \
        && ! -L "${_plan_existing_contract_file}" ]]; then
      _plan_existing_contract="$(jq -ce . "${_plan_existing_contract_file}" 2>/dev/null || true)"
      if [[ -z "${_plan_existing_contract}" ]] \
        || ! quality_contract_validate_envelope "${_plan_existing_contract}" 2>/dev/null; then
        record_gate_event "definition-of-excellent/plan" "invalid-contract" \
          "agent=${AGENT_TYPE:-planner}" "reason=existing-frozen-contract-invalid" 2>/dev/null || true
        exit 0
      fi
      if ! quality_contract_revision_preserves_floor \
        "${_plan_quality_definition}" "${_plan_existing_contract}" 2>/dev/null; then
        record_gate_event "definition-of-excellent/plan" "invalid-contract" \
          "agent=${AGENT_TYPE:-planner}" "reason=post-mutation-floor-weakened" 2>/dev/null || true
        exit 0
      fi
    fi
  fi
fi

# --- Plan-complexity computation (v1.19.0) ---
#
# Centralized in a function so the bias-defense layer (stop-guard's
# metis-on-plan gate) and the soft notice below share one source of
# truth. Four orthogonal complexity legs:
#   1. step_count   — numbered list items in the plan body
#   2. file_count   — unique file references with known source extensions
#   3. wave_count   — `Wave N/M:` headers (council Phase 8 wave plans)
#   4. risky_kw     — migration / refactor / schema / breaking / cross-cutting
#
# `plan_complexity_high` is set to "1" when ANY of:
#   - step_count > 5
#   - file_count > 3
#   - wave_count >= 2
#   - risky_kw present AND (step_count >= 4 OR file_count >= 3)
# The keyword-AND-scope condition is conservative: a one-line "refactor
# the comment" plan should not trip the gate just because the word
# 'refactor' appears.
#
# `plan_complexity_signals` is a comma-separated string capturing the
# leg values for scorecard rendering, e.g.
# "steps=7,files=4,waves=2,keywords=migration".
#
# Side-effect-only function (no command-substitution capture) so the
# leg counts and the high/low result both propagate to the caller. Sets
# the following globals:
#   _plan_step_count, _plan_file_count, _plan_wave_count, _plan_keywords
#   _plan_complexity_high  ("1" when high, "" when low)
#   _plan_complexity_signals  (CSV: steps=N,files=N,waves=N[,keywords=...])
_compute_plan_complexity() {
  local message="$1"

  # Use `grep | wc -l` rather than `grep -c || echo 0` because grep -c
  # outputs a number AND exits 1 on no matches, making the `|| echo 0`
  # fallback emit a second "0" that breaks downstream arithmetic. Wrap
  # each grep in `|| true` because `set -o pipefail` is in effect — a
  # no-match grep would otherwise abort the pipeline before wc runs.
  _plan_step_count=$( { grep -E '^\s*[0-9]+\.' <<<"${message}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
  _plan_step_count="${_plan_step_count:-0}"
  _plan_file_count=$( { grep -oE '[a-zA-Z0-9_/.-]+\.(ts|tsx|js|jsx|py|sh|md|json|swift|go|rs|rb|java|css|html|yaml|yml|toml|c|cpp|h)' <<<"${message}" 2>/dev/null || true; } | sort -u | wc -l | tr -d '[:space:]')
  _plan_file_count="${_plan_file_count:-0}"
  _plan_wave_count=$( { grep -E '\bWave [0-9]+/[0-9]+\b' <<<"${message}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
  _plan_wave_count="${_plan_wave_count:-0}"

  # Risky keyword detection — case-insensitive, word-boundary anchored.
  # Captured into a short label list rather than a count to keep the
  # scorecard readable.
  _plan_keywords=""
  local kw
  for kw in migration refactor schema breaking cross-cutting; do
    if grep -Eiq "\b${kw}\b" <<<"${message}"; then
      _plan_keywords="${_plan_keywords:+${_plan_keywords}|}${kw}"
    fi
  done

  local high=0
  if (( _plan_step_count > 5 )); then high=1; fi
  if (( _plan_file_count > 3 )); then high=1; fi
  if (( _plan_wave_count >= 2 )); then high=1; fi
  if [[ -n "${_plan_keywords}" ]] \
      && { (( _plan_step_count >= 4 )) || (( _plan_file_count >= 3 )); }; then
    high=1
  fi

  if (( high == 1 )); then
    _plan_complexity_high="1"
  else
    _plan_complexity_high=""
  fi

  _plan_complexity_signals="steps=${_plan_step_count},files=${_plan_file_count},waves=${_plan_wave_count}"
  if [[ -n "${_plan_keywords}" ]]; then
    _plan_complexity_signals="${_plan_complexity_signals},keywords=${_plan_keywords}"
  fi
}

_compute_plan_complexity "${LAST_ASSISTANT_MESSAGE}"

# Render the immutable plan body before entering the shared session mutex.
# Secret redaction can be comparatively expensive, and keeping it inside the
# lock made a simultaneous planner fan-out convoy long enough for late hooks
# to exhaust the generic three-second hot-path budget. The unique 0600 stage
# is unpublished evidence: only the locked transaction may rename it to the
# canonical artifact, and every rejection/failure path removes it at EXIT.
_plan_stage=""
_cleanup_plan_stage() {
  if [[ -n "${_plan_stage:-}" ]]; then
    rm -f -- "${_plan_stage}" 2>/dev/null || true
    _plan_stage=""
  fi
}
trap _cleanup_plan_stage EXIT

_prepare_plan_stage() {
  _plan_stage="$(mktemp "$(session_file ".current-plan-stage.XXXXXX")")" \
    || return 1
  chmod 600 "${_plan_stage}" 2>/dev/null || {
    _cleanup_plan_stage
    return 1
  }
  if ! {
    printf '# Plan from %s\n\n' "${AGENT_TYPE:-planner}"
    # Strip controls before secret matching so a C0 byte cannot split a token,
    # evade redaction, and then be removed to reconstitute the secret on disk.
    printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" \
      | _omc_strip_render_unsafe \
      | omc_redact_secrets
  } >"${_plan_stage}"; then
    _cleanup_plan_stage
    return 1
  fi
}

if ! _prepare_plan_stage; then
  log_anomaly "record-plan" "plan artifact staging failed"
  exit 1
fi

# Soft-nudge handoff to PostToolUse:
#
# When the plan is high-complexity, set `plan_complexity_nudge_pending="1"`
# so the PostToolUse Agent hook (`reflect-after-agent.sh`) can surface
# the notice as `additionalContext`. This PostToolUse handoff remains the
# compatibility path for clients predating SubagentStop continuation context
# and keeps the nudge adjacent to the returned Agent tool result. See CLAUDE.md
# "Stop orchestration and output schema" rule.
#
# `reflect-after-agent.sh` clears the flag after emitting (one-shot
# semantics per high-complexity plan).
nudge_flag=""
if [[ "${_plan_complexity_high}" == "1" ]]; then
  nudge_flag="1"
fi

PLAN_DISPATCH_CAUSALITY_VERSION=1

_plan_safe_completion_message() {
  printf '%s' "${LAST_ASSISTANT_MESSAGE}" \
    | omc_redact_secrets \
    | tr -d '\000'
}

_plan_completion_digest() {
  local safe_message
  safe_message="$(_plan_safe_completion_message)" || return 1
  _omc_token_digest "${safe_message}"
}

_planner_identity_matches() {
  case "$1:$2" in
    quality-planner:quality-planner|quality-planner:prometheus|prometheus:quality-planner|prometheus:prometheus)
      return 0 ;;
    *) return 1 ;;
  esac
}

_planner_agent_exact_match() {
  [[ "$1" == "$2" ]]
}

# Bind the fixed WAL to the exact publisher before its stage directory is
# renamed to `.plan-txn.active`.  A concurrent planner summary can then tell a
# normal foreign publication from rollback of its own native callback; mere
# fixed-name presence is never enough to request a repeated plan.
_prepare_plan_transaction_owner_unlocked() {
  local starts_file rows matches completion_digest use_native=0
  local selected=''
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  completion_digest="$(_plan_completion_digest)" || return 1
  if [[ "${_plan_native_agent_id_present}" -eq 1 \
      && "${_plan_native_agent_id_invalid}" -eq 0 ]]; then
    use_native=1
  fi
  [[ ! -L "${starts_file}" ]] \
    && { [[ ! -e "${starts_file}" ]] || [[ -f "${starts_file}" ]]; } \
    || return 1
  rows='[]'
  if [[ -s "${starts_file}" ]]; then
    rows="$(jq -Rsc '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null)]
      | if all(.[]; type == "object") then .
        else error("invalid planner start ledger") end
    ' "${starts_file}")" || return 1
  fi
  matches="$(jq -cn \
    --argjson rows "${rows}" \
    --argjson use_native "${use_native}" \
    --arg native "${_plan_native_agent_id}" \
    --arg dispatch "${_plan_dispatch_id}" \
    --arg agent "${AGENT_TYPE}" '
      def planner($name):
        (($name // "") | IN("quality-planner","prometheus"));
      [$rows[] | select(
        if $use_native == 1 then
          (.native_agent_id // "") == $native
          and (.agent_type // "") == $agent
        elif $dispatch != "" then
          (.native_agent_id // "") == ""
          and (.review_dispatch_id // "") == $dispatch
          and planner(.agent_type) and planner($agent)
        else
          (.native_agent_id // "") == ""
          and (.review_dispatch_id // "") == ""
          and (.agent_type // "") == $agent
        end)]
    ')" || return 1
  [[ "$(jq -r 'length' <<<"${matches}")" -le 1 ]] || return 1
  selected="$(jq -c '.[0] // empty' <<<"${matches}")"
  if [[ -n "${selected}" ]]; then
    _plan_transaction_owner_json="$(jq -cn \
      --arg lifecycle_dispatch_id "$(jq -r \
        '.lifecycle_dispatch_id // empty' <<<"${selected}")" \
      --arg agent_type "$(jq -r '.agent_type // empty' <<<"${selected}")" \
      --arg native_agent_id "$(jq -r \
        '.native_agent_id // empty' <<<"${selected}")" \
      --arg completion_digest "${completion_digest}" '
        {
          tracked:true,
          lifecycle_dispatch_id:$lifecycle_dispatch_id,
          agent_type:$agent_type,
          native_agent_id:$native_agent_id,
          completion_digest:$completion_digest
        }
      ')" || return 1
  else
    _plan_transaction_owner_json="$(jq -cn \
      --arg agent_type "${AGENT_TYPE}" \
      --arg native_agent_id "${_plan_native_agent_id}" \
      --arg completion_digest "${completion_digest}" '
        {
          tracked:false,
          lifecycle_dispatch_id:"",
          agent_type:$agent_type,
          native_agent_id:$native_agent_id,
          completion_digest:$completion_digest
        }
      ')" || return 1
  fi
}

_build_quality_contract_for_plan_unlocked() {
  local new_plan_revision="$1" contract_file old_contract="" contract_revision=1
  local cycle objective_ts prompt_revision objective_digest enforcement created_ts
  local planner_agent native_agent_id lifecycle_dispatch_id
  _plan_quality_contract_envelope=""
  _plan_quality_contract_old=""
  _plan_quality_required_count=0
  [[ "${_plan_quality_required}" == "1" \
      && "${plan_verdict}" == "PLAN_READY" ]] || return 0
  [[ -n "${_plan_quality_definition}" ]] || return 1

  contract_file="$(session_file "quality_contract.json")"
  if [[ -e "${contract_file}" || -L "${contract_file}" ]]; then
    [[ -f "${contract_file}" && ! -L "${contract_file}" ]] || return 1
    old_contract="$(jq -ce . "${contract_file}" 2>/dev/null)" || return 1
    quality_contract_validate_envelope "${old_contract}" || return 1
    if [[ -n "$(read_state "first_mutation_ts" 2>/dev/null || true)" ]]; then
      local frozen_floor_file frozen_floor
      frozen_floor_file="$(session_file "quality_contract_floor.json")"
      [[ -f "${frozen_floor_file}" && ! -L "${frozen_floor_file}" ]] || return 1
      frozen_floor="$(jq -ce . "${frozen_floor_file}" 2>/dev/null)" || return 1
      quality_contract_validate_envelope "${frozen_floor}" || return 1
      [[ "$(jq -r '.late' <<<"${frozen_floor}")" == "false" ]] || return 1
      quality_contract_revision_preserves_floor \
        "${_plan_quality_definition}" "${frozen_floor}" || return 1
      quality_contract_revision_preserves_floor \
        "${_plan_quality_definition}" "${old_contract}" || return 1
    fi
    contract_revision="$(jq -r '.contract_revision + 1' <<<"${old_contract}")"
  elif [[ -n "$(read_state "first_mutation_ts" 2>/dev/null || true)" ]]; then
    # Never retrofit the first Definition after implementation has started.
    return 1
  fi

  cycle="$(read_state "review_cycle_id" 2>/dev/null || true)"
  objective_ts="$(read_state "review_cycle_prompt_ts" 2>/dev/null || true)"
  [[ "${objective_ts}" =~ ^[1-9][0-9]*$ ]] \
    || objective_ts="$(read_state "last_user_prompt_ts" 2>/dev/null || true)"
  prompt_revision="$(read_state "quality_contract_prompt_revision" 2>/dev/null || true)"
  objective_digest="$(_quality_contract_digest \
    "$(read_state "current_objective" 2>/dev/null || true)")"
  if [[ -n "${old_contract}" ]]; then
    # The contract belongs to the objective cycle, not to the latest resumed
    # callback interval. Additive scope revisions preserve the original
    # contract authority generation; the exact planner start remains bound to
    # the independently advancing live interval.
    enforcement="$(jq -r '.ulw_enforcement_generation' \
      <<<"${old_contract}")"
  else
    enforcement="$(read_state \
      "ulw_enforcement_generation" 2>/dev/null || true)"
  fi
  created_ts="$(now_epoch)"
  planner_agent="$(jq -r '.agent_type // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  native_agent_id="$(jq -r '.native_agent_id // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  lifecycle_dispatch_id="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  [[ -n "${planner_agent}" ]] || planner_agent="${AGENT_TYPE:-quality-planner}"
  [[ -n "${native_agent_id}" ]] || native_agent_id="${_plan_native_agent_id}"

  _plan_quality_contract_envelope="$(quality_contract_build_envelope \
    "${_plan_quality_definition}" "${cycle}" "${objective_ts}" \
    "${prompt_revision}" "${objective_digest}" "${enforcement}" \
    "${new_plan_revision}" "${created_ts}" "${planner_agent}" \
    "${native_agent_id}" "${lifecycle_dispatch_id}" \
    "${contract_revision}")" || return 1
  _plan_quality_contract_old="${old_contract}"
  _plan_quality_required_count="$(jq -r \
    '[.definition.criteria[] | select(.class == "must")] | length' \
    <<<"${_plan_quality_contract_envelope}")"
}

_validate_open_frontier_carryover_for_plan_unlocked() {
  local frontier_file evidence_file frontier_history_file
  local current_frontier current_evidence history_rows parsed_history
  _plan_preserve_open_frontier=0
  [[ -n "${_plan_quality_contract_old:-}" ]] || return 0

  frontier_file="$(session_file "quality_frontier.json")"
  evidence_file="$(session_file "quality_evidence.jsonl")"
  frontier_history_file="$(session_file "quality_frontier_history.jsonl")"

  # No accepted current review means there is no open authority to carry. A
  # legitimate additive revision before the first review must remain possible.
  if [[ ! -e "${frontier_file}" && ! -L "${frontier_file}" ]]; then
    return 0
  fi

  current_frontier="$(_quality_contract_read_json_file \
    "${frontier_file}" 65536)" || return 1
  _quality_contract_frontier_schema_valid "${current_frontier}" || return 1
  [[ "$(jq -r '.status' <<<"${current_frontier}")" == "open" ]] || return 0

  # An inherited open frontier may belong to the immediately superseded
  # contract (or an earlier additive revision), but never to another objective
  # cycle or a future contract/plan generation.
  jq -ne --argjson frontier "${current_frontier}" \
      --argjson contract "${_plan_quality_contract_old}" '
    ($frontier.review_cycle_id == $contract.review_cycle_id)
    and ($frontier.contract_revision <= $contract.contract_revision)
    and ($frontier.plan_revision <= $contract.plan_revision)
    and (if $frontier.contract_revision == $contract.contract_revision
      then $frontier.contract_id == $contract.contract_id
        and $frontier.plan_revision == $contract.plan_revision
      else $frontier.plan_revision < $contract.plan_revision end)
  ' >/dev/null 2>&1 || return 1

  # Preserve only a complete accepted pair. This is the durable carryover
  # discriminator after the new contract makes the old assessment stale: the
  # pair cannot certify the new revision, but it continues to prove that a
  # material frontier must be causally remediated.
  current_evidence="$(_quality_contract_read_jsonl_array \
    "${evidence_file}" 262144 512)" || return 1
  _quality_contract_evidence_schema_valid "${current_evidence}" || return 1
  jq -e --argjson frontier "${current_frontier}" '
    length >= 1
    and all(.[];
      .contract_id == $frontier.contract_id
      and .contract_revision == $frontier.contract_revision
      and .review_cycle_id == $frontier.review_cycle_id
      and .edit_revision == $frontier.edit_revision
      and .plan_revision == $frontier.plan_revision
      and .reviewed_at == $frontier.reviewed_at
      and .reviewer == $frontier.reviewer
      and .native_agent_id == $frontier.native_agent_id
      and .lifecycle_dispatch_id == $frontier.lifecycle_dispatch_id)
    and (([.[].evidence_id] | unique | sort)
      == ($frontier.evidence_ids | unique | sort))
    and (([.[].receipt_id] | unique | sort)
      == ($frontier.evidence | unique | sort))
  ' <<<"${current_evidence}" >/dev/null 2>&1 || return 1

  # Reviewer publication writes current evidence, current frontier, then the
  # history row. A process death between the final two renames leaves a valid
  # open pair but stale/missing history. Refuse the additive publication unless
  # the exact open frontier is already the latest bounded authoritative row;
  # the outer plan transaction then restores every consumed causal artifact.
  history_rows="$(_quality_contract_read_jsonl_array \
    "${frontier_history_file}" 2097152 64)" || return 1
  jq -e 'length >= 1 and length <= 64' \
    <<<"${history_rows}" >/dev/null 2>&1 || return 1
  parsed_history="$(_quality_frontier_history_parse \
    "${frontier_history_file}")" || return 1
  jq -e --argjson frontier "${current_frontier}" \
      --argjson raw "${history_rows}" '
    .invalid_rows == 0
    and (.rows | length) == ($raw | length)
    and .rows[-1] == $frontier
  ' <<<"${parsed_history}" >/dev/null 2>&1 || return 1

  _plan_preserve_open_frontier=1
}

_plan_quality_contract_history_appendable() {
  local history_file="$1" rows row envelope
  [[ ! -e "${history_file}" && ! -L "${history_file}" ]] && return 0
  [[ -f "${history_file}" && ! -L "${history_file}" \
      && -r "${history_file}" ]] || return 1
  if [[ -s "${history_file}" ]]; then
    # `tail` preserves a missing terminal newline and the next append would
    # concatenate two JSON objects into one corrupt authority row.
    cmp -s <(tail -c 1 "${history_file}") <(printf '\n') || return 1
  fi
  rows="$(_quality_contract_read_jsonl_array \
    "${history_file}" 2097152 24)" || return 1
  jq -e 'type == "array" and length <= 24' \
    <<<"${rows}" >/dev/null 2>&1 || return 1
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -n "${row}" ]] || continue
    jq -e '
      (.archived_at | type == "number" and floor == . and . >= 1)
      and .archive_reason == "contract-revision"
    ' <<<"${row}" >/dev/null 2>&1 || return 1
    envelope="$(jq -c 'del(.archived_at,.archive_reason)' \
      <<<"${row}" 2>/dev/null)" || return 1
    quality_contract_validate_envelope "${envelope}" || return 1
  done <"${history_file}"
}

_publish_quality_contract_for_plan_unlocked() {
  local contract_file history_file evidence_file frontier_file
  local frontier_history_file tmp history_tmp
  [[ -n "${_plan_quality_contract_envelope:-}" ]] || return 0
  contract_file="$(session_file "quality_contract.json")"
  history_file="$(session_file "quality_contract_history.jsonl")"
  evidence_file="$(session_file "quality_evidence.jsonl")"
  frontier_file="$(session_file "quality_frontier.json")"
  frontier_history_file="$(session_file "quality_frontier_history.jsonl")"
  for _plan_quality_target in "${contract_file}" "${history_file}" \
      "${evidence_file}" "${frontier_file}" "${frontier_history_file}"; do
    [[ ! -L "${_plan_quality_target}" ]] || return 1
    [[ ! -e "${_plan_quality_target}" || -f "${_plan_quality_target}" ]] || return 1
  done
  _validate_open_frontier_carryover_for_plan_unlocked || return 1
  _plan_quality_contract_history_appendable "${history_file}" || return 1

  tmp="$(mktemp "${contract_file}.tmp.XXXXXX")" || return 1
  chmod 600 "${tmp}" 2>/dev/null || true
  printf '%s\n' "${_plan_quality_contract_envelope}" >"${tmp}" || {
    rm -f "${tmp}"; return 1;
  }
  if [[ -n "${_plan_quality_contract_old:-}" ]]; then
    history_tmp="$(mktemp "${history_file}.tmp.XXXXXX")" || {
      rm -f "${tmp}"; return 1;
    }
    chmod 600 "${history_tmp}" 2>/dev/null || true
    if [[ -f "${history_file}" ]]; then
      if [[ "${OMC_TEST_PLAN_HISTORY_TAIL_FAULT:-0}" == "1" ]] \
          || ! tail -n 23 "${history_file}" \
            >"${history_tmp}" 2>/dev/null; then
        rm -f "${tmp}" "${history_tmp}"
        return 1
      fi
    fi
    jq -c --argjson archived_at "$(now_epoch)" \
      '. + {archived_at:$archived_at,archive_reason:"contract-revision"}' \
      <<<"${_plan_quality_contract_old}" >>"${history_tmp}" || {
      rm -f "${tmp}" "${history_tmp}"; return 1;
    }
  else
    history_tmp=""
  fi
  mv -f "${tmp}" "${contract_file}" || {
    rm -f "${tmp}" "${history_tmp:-}"; return 1;
  }
  _plan_transaction_boundary "after-contract-publish" || {
    rm -f "${history_tmp:-}" 2>/dev/null || true
    return 1
  }
  if [[ -n "${history_tmp}" ]] && ! mv -f "${history_tmp}" "${history_file}"; then
    rm -f "${history_tmp}" 2>/dev/null || true
    return 1
  fi
  if [[ -n "${history_tmp}" ]]; then
    _plan_transaction_boundary "after-contract-history-publish" || return 1
  fi
  # A new contract makes prior proof ineligible to certify, so a clear review
  # (or no review yet) is removed. An open frontier is different: retain its
  # exact accepted pair as redundant causal authority until a later reviewer
  # replaces it with causally newer counterproof. Its superseded contract/plan
  # coordinates ensure the Definition gate still treats it as stale, not pass.
  if [[ "${_plan_preserve_open_frontier:-0}" -ne 1 ]]; then
    rm -f "${evidence_file}" 2>/dev/null || return 1
    _plan_transaction_boundary "after-quality-evidence-clear" || return 1
    rm -f "${frontier_file}" 2>/dev/null || return 1
    _plan_transaction_boundary "after-quality-frontier-clear" || return 1
  fi
}

# Consume the exact planner start row. Current SubagentStop payloads select the
# platform-bound native agent_id, including cross-planner replacements within
# the one logical current_plan.md publisher. Echoed rebind IDs and oldest-row
# selection exist only for pre-native migration. Summary-first effects-complete
# claims are removed only after the authoritative causal owner is consumed.
_plan_pending_summary_waiter_requires_retention_unlocked() {
  local pending_line="$1" waiters_file waiters lifecycle native agent
  local digest matches
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  [[ ! -L "${waiters_file}" ]] || return 0
  [[ -e "${waiters_file}" ]] || return 1
  [[ -f "${waiters_file}" ]] || return 0
  [[ -s "${waiters_file}" ]] || return 1
  waiters="$(omc_summary_waiter_ledger_json_unlocked \
    plan "${waiters_file}")" || return 0
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  agent="$(jq -r '.agent_type // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  digest="$(_plan_completion_digest 2>/dev/null || true)"
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
      && -n "${agent}" \
      && "${digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]] || return 0
  matches="$(jq -nr --argjson rows "${waiters}" \
    --arg lifecycle "${lifecycle}" --arg native "${native}" \
    --arg agent "${agent}" --arg digest "${digest}" '
      [$rows[] | select(
        .lifecycle_dispatch_id == $lifecycle
        and .native_agent_id == $native
        and .agent_type == $agent
        and .completion_digest == $digest)] | length
    ' 2>/dev/null)" || return 0
  [[ "${matches}" == "0" ]] && return 1
  # Exact one requires deferred replay; duplicates/ambiguity also preserve the
  # causal row so the transaction fails closed instead of deleting authority.
  return 0
}

_consume_planner_dispatch_start_unlocked() {
  local starts_file tmp line this_type row_id row_native_id selected=""
  local row_lifecycle binding_json="" binding_kind=""
  local binding_lifecycle="" binding_review_id="" binding_cycle=0
  local candidate=0 selected_count=0
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  _plan_dispatch_start_json=""
  _plan_use_native_agent_id=0
  _plan_native_binding_committed=0
  _plan_native_binding_json=""
  _plan_native_tracking_version="$(read_state "native_agent_id_tracking_version")"
  [[ "${_plan_native_agent_id_invalid}" -eq 0 ]] || return 0
  if [[ "${_plan_native_agent_id_present}" -eq 1 \
      && "${_plan_native_agent_id_invalid}" -eq 0 ]]; then
    local bindings_file
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && binding_json="$(jq -Rsc --arg id "${_plan_native_agent_id}" \
          --arg type "${AGENT_TYPE}" \
          --arg current "${_plan_native_tracking_version}" '
            def base_valid:
              type == "object"
              and (.native_agent_id | type == "string"
                and test("^[A-Za-z0-9._:-]{1,128}$"))
              and (.agent_type | type == "string"
                and test("^[A-Za-z0-9._:-]{1,128}$"));
            def current_valid:
              base_valid
              and (.lifecycle_dispatch_id | type == "string"
                and test("^dispatch-[A-Za-z0-9._:-]{8,120}$"))
              and (.review_dispatch_id | type == "string"
                and test("^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
              and (.objective_cycle_id | type == "number"
                and floor == . and . >= 0)
              and (.ts | type == "number" and floor == . and . >= 0);
            def legacy_valid:
              base_valid and (has("lifecycle_dispatch_id") | not)
              and ((has("review_dispatch_id") | not)
                or (.review_dispatch_id | type == "string"
                  and test("^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")))
              and ((has("objective_cycle_id") | not)
                or (.objective_cycle_id | type == "number"
                  and floor == . and . >= 0))
              and ((has("ts") | not)
                or (.ts | type == "number" and floor == . and . >= 0));
            [split("\n")[] | select(length > 0)
              | (try fromjson catch null)] as $rows
            | if any($rows[]; . == null or type != "object") then
                error("malformed native binding registry")
              elif any($rows[];
                  (((. | current_valid) or (. | legacy_valid)) | not)) then
                error("invalid native binding registry row")
              else
                [$rows[] | select((.native_agent_id // "") == $id)] as $matches
                | if ($matches | length) != 1 then
                    error("native binding is missing or duplicated")
                  else $matches[0] as $binding
                    | (($binding.native_agent_id == $id
                        and $binding.agent_type == $type)
                      and ($binding | current_valid)) as $current_ok
                    | (($binding.native_agent_id == $id
                        and $binding.agent_type == $type)
                      and ($binding | legacy_valid)) as $legacy_ok
                    | if ($current == "1" and ($current_ok | not))
                        or (($current_ok or $legacy_ok) | not) then
                        error("native binding has an invalid schema")
                      elif $current_ok then
                        if ([$rows[] | select(
                              (.native_agent_id // "") == $id
                              or (.lifecycle_dispatch_id // "")
                                == $binding.lifecycle_dispatch_id
                              or (($binding.review_dispatch_id // "") != ""
                                and (.agent_type // "") == $type
                                and (.review_dispatch_id // "")
                                  == $binding.review_dispatch_id))] | length) != 1
                        then error("native binding authority is duplicated")
                        else $binding + {binding_kind:"current"}
                        end
                      else $binding + {binding_kind:"legacy"}
                      end
                  end
              end
          ' "${bindings_file}" 2>/dev/null)"; then
      _plan_native_binding_committed=1
      _plan_native_binding_json="${binding_json}"
    fi
  fi
  if [[ "${_plan_native_tracking_version}" == "1" ]]; then
    [[ "${_plan_native_agent_id_present}" -eq 1 \
        && "${_plan_native_agent_id_invalid}" -eq 0 \
        && "${_plan_native_binding_committed}" -eq 1 ]] || return 0
    _plan_use_native_agent_id=1
  elif [[ "${_plan_native_binding_committed}" -eq 1 ]]; then
    _plan_use_native_agent_id=1
  fi
  if [[ "${_plan_use_native_agent_id}" -eq 1 ]]; then
    binding_kind="$(jq -r '.binding_kind' \
      <<<"${_plan_native_binding_json}")" || return 1
    if [[ "${binding_kind}" == "current" ]]; then
      binding_lifecycle="$(jq -r '.lifecycle_dispatch_id' \
        <<<"${_plan_native_binding_json}")" || return 1
      binding_review_id="$(jq -r '.review_dispatch_id // ""' \
        <<<"${_plan_native_binding_json}")" || return 1
      binding_cycle="$(jq -r '.objective_cycle_id' \
        <<<"${_plan_native_binding_json}")" || return 1
    fi
  fi
  [[ ! -L "${starts_file}" ]] \
    && { [[ ! -e "${starts_file}" ]] || [[ -f "${starts_file}" ]]; } \
    || return 1
  [[ -f "${starts_file}" ]] || return 0
  omc_dispatch_authority_ledger_shell_safe "${starts_file}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if ! jq -e 'type == "object"' <<<"${line}" >/dev/null 2>&1; then
      if [[ "${binding_kind}" == "current" ]] \
          && { [[ "${line}" == *"${_plan_native_agent_id}"* ]] \
            || [[ "${line}" == *"${binding_lifecycle}"* ]] \
            || { [[ -n "${binding_review_id}" ]] \
              && [[ "${line}" == *"${binding_review_id}"* ]]; }; }; then
        return 1
      fi
      continue
    fi
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    row_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    candidate=0
    if [[ "${_plan_use_native_agent_id}" -eq 1 \
        && "${binding_kind}" == "current" ]] \
        && { [[ "${row_native_id}" == "${_plan_native_agent_id}" ]] \
          || [[ "${row_lifecycle}" == "${binding_lifecycle}" ]] \
          || { [[ -n "${binding_review_id}" ]] \
            && [[ "${row_id}" == "${binding_review_id}" ]] \
            && [[ "${this_type}" == "${AGENT_TYPE}" ]]; }; }; then
      candidate=1
      jq -e --arg native "${_plan_native_agent_id}" \
          --arg type "${AGENT_TYPE}" \
          --arg lifecycle "${binding_lifecycle}" \
          --arg review "${binding_review_id}" \
          --argjson cycle "${binding_cycle}" '
            type == "object"
            and (.native_agent_id // "") == $native
            and (.agent_type // "") == $type
            and (.lifecycle_dispatch_id // "") == $lifecycle
            and (.review_dispatch_id // "") == $review
            and (.objective_cycle_id // -1) == $cycle
          ' <<<"${line}" >/dev/null 2>&1 || return 1
    elif [[ "${_plan_use_native_agent_id}" -eq 1 \
        && "${binding_kind}" == "legacy" \
        && "${row_native_id}" == "${_plan_native_agent_id}" ]]; then
      candidate=1
      jq -e --arg native "${_plan_native_agent_id}" \
          --arg type "${AGENT_TYPE}" '
            type == "object"
            and (.native_agent_id // "") == $native
            and (.agent_type // "") == $type
            and (has("lifecycle_dispatch_id") | not)
          ' <<<"${line}" >/dev/null 2>&1 || return 1
    elif { [[ "${_plan_use_native_agent_id}" -eq 0 ]] \
          && [[ -n "${_plan_dispatch_id}" \
            && "${row_id}" == "${_plan_dispatch_id}" ]] \
          && [[ -z "${row_native_id}" ]] \
          && _planner_identity_matches "${this_type}" "${AGENT_TYPE}"; } \
        || { [[ "${_plan_use_native_agent_id}" -eq 0 ]] \
          && [[ -z "${_plan_dispatch_id}" && -z "${row_id}" \
                && -z "${row_native_id}" ]] \
          && _planner_agent_exact_match "${this_type}" "${AGENT_TYPE}"; }; then
      candidate=1
    fi
    if [[ "${candidate}" -eq 1 ]]; then
      selected_count=$((selected_count + 1))
      selected="${line}"
    fi
  done <"${starts_file}"
  [[ "${selected_count}" -le 1 ]] || return 1
  if [[ "${_plan_use_native_agent_id}" -eq 1 \
      && "${binding_kind}" == "current" ]]; then
    [[ "${selected_count}" -eq 1 ]] || return 0
  fi
  if [[ -n "${selected}" ]]; then
    tmp="$(mktemp "${starts_file}.XXXXXX")" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      [[ "${line}" == "${selected}" ]] && continue
      printf '%s\n' "${line}" >>"${tmp}" || {
        rm -f "${tmp}"
        return 1
      }
    done <"${starts_file}"
    mv -f "${tmp}" "${starts_file}" || return 1
    _plan_transaction_boundary "after-start-consume" || return 1
    _plan_dispatch_start_json="${selected}"

    local pending_file pending_tmp pending_line pending_type pending_id pending_native_id
    local wanted_id wanted_native_id wanted_agent removed_claim=0
    local pending_lifecycle pending_candidate pending_candidate_count=0
    pending_file="$(session_file "pending_agents.jsonl")"
    [[ ! -L "${pending_file}" ]] \
      && { [[ ! -e "${pending_file}" ]] || [[ -f "${pending_file}" ]]; } \
      || return 1
    omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
    wanted_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    wanted_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    wanted_agent="$(jq -r '.agent_type // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    if [[ -s "${pending_file}" ]]; then
      pending_tmp="$(mktemp "${pending_file}.XXXXXX")" || return 1
      while IFS= read -r pending_line || [[ -n "${pending_line}" ]]; do
        [[ -n "${pending_line}" ]] || continue
        if ! jq -e 'type == "object"' \
            <<<"${pending_line}" >/dev/null 2>&1; then
          if [[ "${binding_kind}" == "current" ]] \
              && { [[ "${pending_line}" == *"${_plan_native_agent_id}"* ]] \
                || [[ "${pending_line}" == *"${binding_lifecycle}"* ]] \
                || { [[ -n "${binding_review_id}" ]] \
                  && [[ "${pending_line}" == *"${binding_review_id}"* ]]; }; }; then
            rm -f "${pending_tmp}"
            return 1
          fi
          printf '%s\n' "${pending_line}" >>"${pending_tmp}" || {
            rm -f "${pending_tmp}"
            return 1
          }
          continue
        fi
        pending_type="$(jq -r '.agent_type // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_id="$(jq -r '.review_dispatch_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_native_id="$(jq -r '.native_agent_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_candidate=0
        if [[ "${binding_kind}" == "current" ]] \
            && { [[ "${pending_native_id}" == "${_plan_native_agent_id}" ]] \
              || [[ "${pending_lifecycle}" == "${binding_lifecycle}" ]] \
              || { [[ -n "${binding_review_id}" ]] \
                && [[ "${pending_id}" == "${binding_review_id}" ]] \
                && [[ "${pending_type}" == "${AGENT_TYPE}" ]]; }; }; then
          pending_candidate=1
          jq -e --arg native "${_plan_native_agent_id}" \
              --arg type "${AGENT_TYPE}" \
              --arg lifecycle "${binding_lifecycle}" \
              --arg review "${binding_review_id}" \
              --argjson cycle "${binding_cycle}" '
                type == "object"
                and (.native_agent_id // "") == $native
                and (.agent_type // "") == $type
                and (.lifecycle_dispatch_id // "") == $lifecycle
                and (.review_dispatch_id // "") == $review
                and (.objective_cycle_id // -1) == $cycle
              ' <<<"${pending_line}" >/dev/null 2>&1 || {
                rm -f "${pending_tmp}"
                return 1
              }
          jq -e --argjson start "${selected}" '
              def frozen:
                {ts:(.ts // -1),agent_type:(.agent_type // ""),
                 description:(.description // ""),
                 lifecycle_dispatch_id:(.lifecycle_dispatch_id // ""),
                 review_dispatch_id:(.review_dispatch_id // ""),
                 native_agent_id:(.native_agent_id // ""),
                 edit_revision:(.edit_revision // 0),
                 code_revision:(.code_revision // 0),
                 doc_revision:(.doc_revision // 0),
                 bash_revision:(.bash_revision // 0),
                 ui_revision:(.ui_revision // 0),
                 plan_revision:(.plan_revision // 0),
                 review_revision:(.review_revision // 0),
                 objective_prompt_ts:(.objective_prompt_ts // 0),
                 objective_prompt_revision:(.objective_prompt_revision // 0),
                 objective_cycle_id:(.objective_cycle_id // 0),
                 ulw_enforcement_generation:
                   (.ulw_enforcement_generation // "migration"),
                 review_dispatch_causality_version:
                   (.review_dispatch_causality_version // 0),
                 review_batch_id:(.review_batch_id // ""),
                 quality_contract_id:(.quality_contract_id // ""),
                 quality_contract_revision:
                   (.quality_contract_revision // 0),
                 purpose:(.purpose // ""),
                 council_phase:(.council_phase // ""),
                 council_selection_agent:
                   (.council_selection_agent // ""),
                 council_objective_prompt_ts:
                   (.council_objective_prompt_ts // 0),
                 council_objective_prompt_revision:
                   (.council_objective_prompt_revision // 0),
                 council_ledger_generation:
                   (.council_ledger_generation // 0)};
              frozen == ($start | frozen)
            ' <<<"${pending_line}" >/dev/null 2>&1 || {
              rm -f "${pending_tmp}"
              return 1
            }
        elif [[ "${binding_kind}" == "legacy" \
            && "${pending_native_id}" == "${_plan_native_agent_id}" ]]; then
          pending_candidate=1
          jq -e --arg native "${_plan_native_agent_id}" \
              --arg type "${AGENT_TYPE}" '
                type == "object"
                and (.native_agent_id // "") == $native
                and (.agent_type // "") == $type
                and (has("lifecycle_dispatch_id") | not)
              ' <<<"${pending_line}" >/dev/null 2>&1 || {
                rm -f "${pending_tmp}"
                return 1
              }
        elif [[ "${_plan_use_native_agent_id}" -eq 0 ]] \
            && _planner_agent_exact_match \
              "${pending_type}" "${wanted_agent}" \
            && { { [[ -n "${wanted_id}" ]] \
                   && [[ "${pending_id}" == "${wanted_id}" ]] \
                   && [[ -z "${pending_native_id}" ]]; } \
              || { [[ -z "${wanted_id}" ]] \
                   && [[ -z "${pending_id}" \
                         && -z "${pending_native_id}" ]]; }; }; then
          pending_candidate=1
        fi
        [[ "${pending_candidate}" -eq 0 ]] \
          || pending_candidate_count=$((pending_candidate_count + 1))
        if [[ "${removed_claim}" -eq 0 \
            && "${pending_candidate}" -eq 1 ]] \
            && _planner_agent_exact_match "${pending_type}" "${wanted_agent}" \
            && { { [[ -n "${wanted_native_id}" \
                     && "${pending_native_id}" == "${wanted_native_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -n "${wanted_id}" \
                     && "${pending_id}" == "${wanted_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -z "${wanted_id}" \
                      && -z "${pending_native_id}" \
                      && -z "${pending_id}" ]]; }; } \
            && [[ "$(jq -r '.completion_claim_effects_complete // false' \
              <<<"${pending_line}" 2>/dev/null || true)" == "true" ]] \
            && ! _plan_pending_summary_waiter_requires_retention_unlocked \
              "${pending_line}"; then
          removed_claim=1
          continue
        fi
        printf '%s\n' "${pending_line}" >>"${pending_tmp}" || {
          rm -f "${pending_tmp}"
          return 1
        }
      done <"${pending_file}"
      if [[ "${binding_kind}" == "current" \
          && "${pending_candidate_count}" -ne 1 ]]; then
        rm -f "${pending_tmp}"
        return 1
      elif [[ "${pending_candidate_count}" -gt 1 ]]; then
        rm -f "${pending_tmp}"
        return 1
      fi
      mv -f "${pending_tmp}" "${pending_file}" || return 1
      if [[ "${removed_claim}" -eq 1 ]]; then
        _plan_transaction_boundary "after-pending-consume" || return 1
      fi
    fi
    if [[ "${binding_kind}" == "current" \
        && "${pending_candidate_count}" -ne 1 ]]; then
      return 1
    fi
  fi
}

_record_plan_state_unlocked() {
  local _plan_revision _tracking_version _row_version
  local _strict_tracking=0 _start_revision _start_ts _current_ts
  local _start_cycle_id=0 _current_cycle_id=0 _ready=false
  local _start_prompt_revision="" _quality_prompt_revision=""
  _plan_commit_accepted=0
  _plan_rejection_reason=""
  if [[ -n "${_OMC_ULW_CAPTURED_GENERATION+x}" ]] \
      && ! is_ultrawork_mode; then
    _plan_rejection_reason="enforcement_interval_closed"
    return 0
  fi
  _consume_planner_dispatch_start_unlocked || return 1

  _tracking_version="$(read_state "plan_dispatch_tracking_version")"
  local _native_tracking_version="${_plan_native_tracking_version:-$(read_state "native_agent_id_tracking_version")}"
  _row_version="$(jq -r '.review_dispatch_causality_version // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  [[ -n "${_tracking_version}" || -n "${_row_version}" \
      || "${_native_tracking_version}" == "1" \
      || "${_plan_use_native_agent_id:-0}" -eq 1 \
      || "${_plan_native_agent_id_invalid}" -eq 1 ]] \
    && _strict_tracking=1

  _plan_revision="$(read_state "plan_revision")"
  [[ "${_plan_revision}" =~ ^[0-9]+$ ]] || _plan_revision=0
  if [[ "${_strict_tracking}" -eq 1 ]]; then
    if [[ "${_plan_native_agent_id_invalid}" -eq 1 ]]; then
      _plan_rejection_reason="invalid_native_agent_id"
    elif [[ "${_native_tracking_version}" == "1" \
        && "${_plan_native_agent_id_present}" -eq 0 ]]; then
      _plan_rejection_reason="missing_native_agent_id"
    elif [[ "${_native_tracking_version}" == "1" \
        && "${_plan_native_binding_committed:-0}" -ne 1 ]]; then
      _plan_rejection_reason="native_agent_binding_uncommitted"
    elif [[ -z "${_plan_dispatch_start_json}" \
        && "${_plan_use_native_agent_id:-0}" -eq 1 ]]; then
      _plan_rejection_reason="native_agent_id_mismatch"
    elif [[ -z "${_plan_dispatch_start_json}" ]]; then
      _plan_rejection_reason="missing_start_snapshot"
    elif ! omc_row_enforcement_generation_current \
        "${_plan_dispatch_start_json}"; then
      _plan_rejection_reason="enforcement_interval_closed"
    elif [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)" == "true" ]]; then
      _plan_rejection_reason="abandoned_dispatch_completion"
    elif [[ "${_tracking_version}" != "${PLAN_DISPATCH_CAUSALITY_VERSION}" \
        || "${_row_version}" != "${PLAN_DISPATCH_CAUSALITY_VERSION}" ]]; then
      _plan_rejection_reason="invalid_start_snapshot"
    elif [[ -z "${plan_verdict}" ]]; then
      _plan_rejection_reason="invalid_plan_verdict"
    else
      _start_revision="$(jq -r '.review_revision // .plan_revision // empty' \
        <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
      _start_ts="$(jq -r '.objective_prompt_ts // empty' \
        <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
      _start_prompt_revision="$(jq -r '.objective_prompt_revision // empty' \
        <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
      _quality_prompt_revision="$(read_state "quality_contract_prompt_revision" 2>/dev/null || true)"
      _current_ts="$(read_state "review_cycle_prompt_ts")"
      if [[ ! "${_current_ts}" =~ ^[0-9]+$ ]]; then
        _current_ts="$(read_state "last_user_prompt_ts")"
      fi
      _start_cycle_id="$(jq -r '.objective_cycle_id // 0' \
        <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
      _current_cycle_id="$(read_state "review_cycle_id")"
      [[ "${_start_cycle_id}" =~ ^[0-9]+$ ]] || _start_cycle_id=0
      [[ "${_current_cycle_id}" =~ ^[0-9]+$ ]] || _current_cycle_id=0
      if [[ ! "${_start_revision}" =~ ^[0-9]+$ \
          || ! "${_start_ts}" =~ ^[0-9]+$ \
          || ! "${_current_ts}" =~ ^[0-9]+$ ]]; then
        _plan_rejection_reason="invalid_start_snapshot"
      elif (( _current_cycle_id > 0 && _start_cycle_id != _current_cycle_id )); then
        _plan_rejection_reason="plan_objective_changed"
      elif (( _start_ts != _current_ts )); then
        _plan_rejection_reason="plan_objective_changed"
      elif [[ "${_plan_quality_required}" == "1" \
          && "${plan_verdict}" == "PLAN_READY" \
          && -n "$(read_state \
            "quality_contract_scope_overflow" 2>/dev/null || true)" ]]; then
        _plan_rejection_reason="quality_contract_scope_overflow"
      elif [[ "${_plan_quality_required}" == "1" \
          && "${plan_verdict}" == "PLAN_READY" ]] \
        && { [[ ! "${_start_prompt_revision}" =~ ^[0-9]+$ ]] \
          || [[ ! "${_quality_prompt_revision}" =~ ^[0-9]+$ ]] \
          || (( _start_prompt_revision != _quality_prompt_revision )); }; then
        _plan_rejection_reason="quality_contract_prompt_changed"
      elif (( _start_revision != _plan_revision )); then
        _plan_rejection_reason="plan_generation_changed"
      fi
    fi
  else
    # Explicit migration path for plans dispatched before causal tracking.
    plan_verdict="${plan_verdict:-PLAN_READY}"
  fi

  if [[ -n "${_plan_rejection_reason}" ]]; then
    return 0
  fi

  [[ "${plan_verdict}" == "PLAN_READY" ]] && _ready=true
  if [[ "${_ready}" == "true" && "${_plan_quality_required}" == "1" ]]; then
    if ! _build_quality_contract_for_plan_unlocked "$((_plan_revision + 1))"; then
      _plan_rejection_reason="quality_contract_publication_invalid"
      # The causal planner row may already have been consumed. Force the
      # transaction wrapper to restore every ledger/artifact instead of
      # silently retiring the only valid publisher for this contract.
      return 1
    fi
  fi
  if [[ -L "${plan_file}" ]] \
      || { [[ -e "${plan_file}" ]] && [[ ! -f "${plan_file}" ]]; }; then
    log_anomaly "record-plan" \
      "refusing to replace non-regular plan artifact at ${plan_file}"
    return 1
  fi
  if [[ -z "${_plan_stage:-}" || -L "${_plan_stage}" \
      || ! -f "${_plan_stage}" ]]; then
    log_anomaly "record-plan" "plan artifact stage disappeared before publication"
    return 1
  fi
  if ! mv -f "${_plan_stage}" "${plan_file}"; then
    return 1
  fi
  _plan_stage=""
  _plan_transaction_boundary "after-plan-publish" || return 1

  if [[ "${_ready}" == "true" && "${_plan_quality_required}" == "1" ]]; then
    _publish_quality_contract_for_plan_unlocked || return 1
  fi

  if [[ "${_ready}" == "true" ]]; then
    local _ready_state_args=(
        "has_plan" "true"
        "plan_verdict" "${plan_verdict}"
        "plan_agent" "${AGENT_TYPE:-planner}"
        "plan_ts" "$(now_epoch)"
        "plan_revision" "$((_plan_revision + 1))"
        "plan_complexity_high" "${_plan_complexity_high}"
        "plan_complexity_signals" "${_plan_complexity_signals}"
        "plan_complexity_nudge_pending" "${nudge_flag}"
        "metis_gate_blocks" ""
    )
    if [[ "${_plan_quality_required}" == "1" ]]; then
      _ready_state_args+=(
        "quality_contract_id" "$(jq -r '.contract_id' <<<"${_plan_quality_contract_envelope}")"
        "quality_contract_revision" "$(jq -r '.contract_revision' <<<"${_plan_quality_contract_envelope}")"
        "quality_contract_cycle_id" "$(jq -r '.review_cycle_id' <<<"${_plan_quality_contract_envelope}")"
        "quality_contract_plan_revision" "$(jq -r '.plan_revision' <<<"${_plan_quality_contract_envelope}")"
        "quality_contract_enforcement_generation" "$(jq -r '.ulw_enforcement_generation' <<<"${_plan_quality_contract_envelope}")"
        "quality_contract_status" "$([[ "$(jq -r '.late' <<<"${_plan_quality_contract_envelope}")" == "true" ]] && printf late-frozen || printf frozen)"
        "quality_contract_late" "$([[ "$(jq -r '.late' <<<"${_plan_quality_contract_envelope}")" == "true" ]] && printf 1 || printf 0)"
        "quality_contract_recheck_required" ""
        "quality_contract_scope_transition" ""
        "quality_evidence_required_count" "${_plan_quality_required_count}"
        "quality_evidence_current_count" "0"
        "quality_evidence_blocks" "0"
        "quality_frontier_status" "missing"
        "quality_frontier_blocks" "0"
        "quality_weakest_axis" "unreviewed"
      )
    fi
    if ! _write_state_batch_unlocked "${_ready_state_args[@]}"; then
      return 1
    fi
    _plan_transaction_boundary "after-state-publish" || return 1
  else
    # Non-ready output remains visible, but it is not executable evidence and
    # cannot buy a Metis dispatch, nudge the parent, or advance plan freshness.
    if ! _write_state_batch_unlocked \
        "has_plan" "false" \
        "plan_verdict" "${plan_verdict}" \
        "plan_agent" "${AGENT_TYPE:-planner}" \
        "plan_ts" "$(now_epoch)" \
        "plan_revision" "${_plan_revision}" \
        "plan_complexity_high" "" \
        "plan_complexity_signals" "${_plan_complexity_signals}" \
        "plan_complexity_nudge_pending" ""; then
      return 1
    fi
    _plan_transaction_boundary "after-state-publish" || return 1
  fi
  _plan_commit_accepted=1
}

# Publish the dedicated planner hook's exact decision as the cross-hook
# authority for the universal summary hook. A structurally valid planner
# return is not allowed to create summaries, scope, Council evidence, or a
# parent-visible accepted outcome until this lifecycle-bound receipt exists.
_publish_plan_outcome_receipt_unlocked() {
  local status="$1" reason="$2" receipt_file source temp receipt
  local lifecycle_dispatch_id native_agent_id start_plan_revision
  local result_plan_revision completion_digest live_ids_json ledger
  local pending_ledger starts_ledger waiters_ledger waiters waiter_ids
  receipt_file="$(session_file "plan_publication_outcomes.jsonl")"
  [[ ! -L "${receipt_file}" ]] \
    && { [[ ! -e "${receipt_file}" ]] || [[ -f "${receipt_file}" ]]; } \
    || return 1
  [[ -n "${_plan_dispatch_start_json:-}" ]] || return 1
  lifecycle_dispatch_id="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  native_agent_id="$(jq -r '.native_agent_id // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  start_plan_revision="$(jq -r '.plan_revision // .review_revision // empty' \
    <<<"${_plan_dispatch_start_json}" 2>/dev/null || true)"
  result_plan_revision="$(read_state "plan_revision" 2>/dev/null || true)"
  completion_digest="$(_plan_completion_digest)" || return 1
  [[ "${lifecycle_dispatch_id}" \
      =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
      && "${start_plan_revision}" =~ ^[0-9]+$ \
      && "${result_plan_revision}" =~ ^[0-9]+$ \
      && "${completion_digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
      && "${status}" =~ ^(accepted|rejected)$ \
      && "${plan_verdict}" =~ ^(PLAN_READY|NEEDS_CLARIFICATION|BLOCKED)$ ]] \
    || return 1
  receipt="$(jq -nc \
    --argjson schema_version 1 \
    --argjson decided_at "$(now_epoch)" \
    --arg lifecycle_dispatch_id "${lifecycle_dispatch_id}" \
    --arg agent_type "${AGENT_TYPE}" \
    --arg native_agent_id "${native_agent_id}" \
    --arg completion_digest "${completion_digest}" \
    --arg status "${status}" \
    --arg reason "$(truncate_chars 120 "${reason}")" \
    --arg verdict "${plan_verdict}" \
    --argjson start_plan_revision "${start_plan_revision}" \
    --argjson result_plan_revision "${result_plan_revision}" '
      {
        schema_version:$schema_version,
        decided_at:$decided_at,
        lifecycle_dispatch_id:$lifecycle_dispatch_id,
        agent_type:$agent_type,
        native_agent_id:$native_agent_id,
        completion_digest:$completion_digest,
        status:$status,
        reason:$reason,
        verdict:$verdict,
        start_plan_revision:$start_plan_revision,
        result_plan_revision:$result_plan_revision
      }
    ')" || return 1

  # Retain every receipt whose causal pending/start row is still live, plus a
  # receipt named by an exact summary waiter. The latter closes the race where
  # this publisher passed its entry recovery barrier before a sibling process
  # committed summary effects, consumed its causal rows, and died with only
  # waiter+receipt recovery authority. Settled rows without either reference
  # are correlation history and can be pruned safely.
  # The stateful start ledger is strict receipt authority. pending_agents is a
  # compatibility queue and may retain unrelated malformed legacy noise; exact
  # object rows still contribute live IDs and the raw noise is never rewritten.
  live_ids_json='[]'
  pending_ledger="$(session_file "pending_agents.jsonl")"
  starts_ledger="$(session_file "agent_dispatch_starts.jsonl")"
  for ledger in "${pending_ledger}" "${starts_ledger}"; do
    [[ ! -L "${ledger}" ]] || return 1
    if [[ -f "${ledger}" ]]; then
      if [[ "${ledger}" == "${pending_ledger}" ]]; then
        live_ids_json="$(jq -Rsc --argjson prior "${live_ids_json}" '
          ($prior + [split("\n")[] | select(length > 0)
            | (try fromjson catch null) | select(type == "object")
            | .lifecycle_dispatch_id // empty])
          | map(select(type == "string" and length > 0)) | unique
        ' "${ledger}")" || return 1
      else
        jq -Rse '
          [split("\n")[] | select(length > 0)
            | (try fromjson catch null)]
          | all(.[]; type == "object")
        ' "${ledger}" >/dev/null 2>&1 || return 1
        live_ids_json="$(jq -Rsc --argjson prior "${live_ids_json}" '
          ($prior + [split("\n")[] | select(length > 0)
            | fromjson | .lifecycle_dispatch_id // empty])
          | map(select(type == "string" and length > 0)) | unique
        ' "${ledger}")" || return 1
      fi
    fi
  done
  waiters_ledger="$(session_file "plan_summary_waiters.jsonl")"
  [[ ! -L "${waiters_ledger}" ]] \
    && { [[ ! -e "${waiters_ledger}" ]] || [[ -f "${waiters_ledger}" ]]; } \
    || return 1
  if [[ -s "${waiters_ledger}" ]]; then
    waiters="$(omc_summary_waiter_ledger_json_unlocked \
      plan "${waiters_ledger}")" || return 1
    waiter_ids="$(jq -c '[.[].lifecycle_dispatch_id] | unique' \
      <<<"${waiters}" 2>/dev/null)" || return 1
    live_ids_json="$(jq -cn --argjson prior "${live_ids_json}" \
      --argjson waiters "${waiter_ids}" '
        ($prior + $waiters) | unique
      ')" || return 1
  fi

  source="${receipt_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  temp="$(mktemp "${receipt_file}.XXXXXX")" || return 1
  chmod 600 "${temp}" 2>/dev/null || {
    rm -f "${temp}"
    return 1
  }
  if ! jq -Rsr \
      --argjson entry "${receipt}" \
      --argjson live "${live_ids_json}" '
      def valid:
        type == "object"
        and .schema_version == 1
        and (keys | sort == ["agent_type","completion_digest","decided_at",
          "lifecycle_dispatch_id","native_agent_id","reason",
          "result_plan_revision","schema_version","start_plan_revision",
          "status","verdict"])
        and (.decided_at | type == "number" and . >= 0
          and . <= 999999999999999 and floor == .)
        and (.lifecycle_dispatch_id | type == "string"
          and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
        and (.agent_type | type == "string" and length > 0)
        and (.native_agent_id | type == "string"
          and test("^[A-Za-z0-9._:-]{1,128}$"))
        and (.completion_digest | type == "string"
          and test("^[A-Fa-f0-9]{16,128}$"))
        and (.status | IN("accepted", "rejected"))
        and (.reason | type == "string")
        and (.verdict | IN("PLAN_READY", "NEEDS_CLARIFICATION", "BLOCKED"))
        and (.start_plan_revision | type == "number" and . >= 0
          and . <= 999999999999999 and floor == .)
        and (.result_plan_revision | type == "number" and . >= 0
          and . <= 999999999999999 and floor == .);
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null)] as $rows
      | if all($rows[]; valid) | not then error("invalid receipt ledger")
        elif any($rows[];
          .lifecycle_dispatch_id == $entry.lifecycle_dispatch_id) then
          error("duplicate lifecycle receipt")
        else
          ([$rows[] | select(.lifecycle_dispatch_id as $id
              | ($live | index($id)) != null)] + [$entry]) as $kept
          | if ($kept | length) > 128 then error("live receipt cap")
            else $kept[] | @json end
        end
    ' "${source}" >"${temp}"; then
    rm -f "${temp}"
    return 1
  fi
  if ! mv -f "${temp}" "${receipt_file}"; then
    rm -f "${temp}"
    return 1
  fi
  _plan_publication_receipt_written=1
  _plan_publication_lifecycle_id="${lifecycle_dispatch_id}"
  _plan_transaction_boundary "after-receipt-publish" || return 1
}

_collect_plan_summary_replays_unlocked() {
  local waiters_file receipts_file pending_file waiters receipts pending
  _plan_summary_replays='[]'
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  receipts_file="$(session_file "plan_publication_outcomes.jsonl")"
  pending_file="$(session_file "pending_agents.jsonl")"
  for _plan_rendezvous_file in "${waiters_file}" "${receipts_file}" \
      "${pending_file}"; do
    [[ ! -L "${_plan_rendezvous_file}" ]] || return 1
    [[ ! -e "${_plan_rendezvous_file}" \
        || -f "${_plan_rendezvous_file}" ]] || return 1
  done
  [[ -s "${waiters_file}" && -s "${receipts_file}" \
      && -s "${pending_file}" ]] || return 0
  _omc_publication_claim_timestamps_valid_unlocked \
    "${pending_file}" || return 1
  waiters="$(omc_summary_waiter_ledger_json_unlocked \
    plan "${waiters_file}")" || return 1
  receipts="$(jq -cs . "${receipts_file}" 2>/dev/null)" || return 1
  pending="$(jq -Rsc '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")]
  ' "${pending_file}" 2>/dev/null)" || return 1
  _plan_summary_replays="$(jq -cn \
    --argjson waiters "${waiters}" \
    --argjson receipts "${receipts}" \
    --argjson pending "${pending}" '
      [$waiters[] as $waiter
        | select($waiter.schema_version == 1)
        | select([$receipts[] | select(
            .schema_version == 1
            and .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id
            and .agent_type == $waiter.agent_type
            and .native_agent_id == $waiter.native_agent_id
            and .completion_digest == $waiter.completion_digest
          )] | length == 1)
        | ([$pending[] | select(
            .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id
            and .agent_type == $waiter.agent_type
            and .native_agent_id == $waiter.native_agent_id
            and (.review_dispatch_abandoned // false) != true
          )]) as $matching_pending
        | select(($matching_pending | length) == 1)
        | $matching_pending[0] as $pending_row
        | $waiter
          + if (($pending_row.completion_claim_id // "") | length) > 0
            then {completion_claim_id:$pending_row.completion_claim_id}
            else {} end]
    ')" || return 1
}

_record_plan_transaction_unlocked() {
  local rc=0 receipt_status receipt_reason
  _plan_publication_receipt_written=0
  _plan_publication_lifecycle_id=""
  _plan_summary_replays='[]'
  _recover_plan_transaction_unlocked || return 1
  if [[ "${OMC_TEST_PLAN_TXN_RECOVER_ONLY:-0}" == "1" ]]; then
    _plan_commit_accepted=0
    _plan_rejection_reason="recovery-only"
    _collect_plan_summary_replays_unlocked || return 1
    return 0
  fi
  _validate_plan_transaction_targets_unlocked || return 1
  _prepare_plan_transaction_owner_unlocked || return 1
  _activate_plan_transaction_unlocked \
    "${_plan_transaction_owner_json}" || return 1
  _record_plan_state_unlocked || rc=$?
  if [[ "${rc}" -eq 0 && -n "${_plan_dispatch_start_json:-}" \
      && -n "${plan_verdict}" ]]; then
    if [[ "${_plan_commit_accepted:-0}" -eq 1 ]]; then
      receipt_status="accepted"
      receipt_reason=""
    else
      receipt_status="rejected"
      receipt_reason="${_plan_rejection_reason:-plan-publication-rejected}"
    fi
    _publish_plan_outcome_receipt_unlocked \
      "${receipt_status}" "${receipt_reason}" || rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    _recover_plan_transaction_unlocked || return 1
    return "${rc}"
  fi
  _commit_plan_transaction_unlocked || return 1
  _collect_plan_summary_replays_unlocked || return 1
}

# Planner completion is durable evidence, unlike best-effort hot-path
# telemetry. Give only this publication a ten-second bounded acquisition
# budget while retaining the shared lock's default three-second cap elsewhere.
# The local is dynamically visible to with_state_lock/_with_lockdir and cannot
# leak into later hook work in this process.
_record_plan_lock_attempts="${OMC_RECORD_PLAN_LOCK_MAX_ATTEMPTS:-200}"
if [[ ! "${_record_plan_lock_attempts}" =~ ^[1-9][0-9]*$ \
    || "${_record_plan_lock_attempts}" -gt 2000 ]]; then
  _record_plan_lock_attempts=200
fi
_with_record_plan_state_lock() {
  local OMC_STATE_LOCK_MAX_ATTEMPTS="${_record_plan_lock_attempts}"
  with_state_lock "$@"
}

if ! _with_record_plan_state_lock _record_plan_transaction_unlocked; then
  log_anomaly "record-plan" "plan artifact/state publication failed"
  exit 1
fi

# If the universal SubagentStop hook arrived first, it left a redacted,
# lifecycle-bound waiter and deliberately published no authoritative effects.
# Replay only waiters for which the dedicated plan receipt now exists. The
# summary hook's exact pending claim makes concurrent platform/replay delivery
# one-shot. A process death leaves the waiter durable for a later plan callback
# instead of manufacturing an accepted result without plan authority.
if [[ "${OMC_PLAN_SUMMARY_REPLAY:-0}" != "1" \
    && "${_plan_summary_replays:-[]}" != "[]" ]]; then
  while IFS= read -r _plan_replay_row; do
    [[ -n "${_plan_replay_row}" ]] || continue
    _plan_replay_agent="$(jq -r '.agent_type // empty' \
      <<<"${_plan_replay_row}" 2>/dev/null || true)"
    _plan_replay_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${_plan_replay_row}" 2>/dev/null || true)"
    _plan_replay_message="$(jq -r '.message // empty' \
      <<<"${_plan_replay_row}" 2>/dev/null || true)"
    _plan_replay_claim="$(jq -r '.completion_claim_id // empty' \
      <<<"${_plan_replay_row}" 2>/dev/null || true)"
    [[ -n "${_plan_replay_agent}" && -n "${_plan_replay_native_id}" \
        && -n "${_plan_replay_message}" ]] || continue
    if [[ -n "${_plan_replay_claim}" \
        && ! "${_plan_replay_claim}" \
          =~ ^completion-[A-Za-z0-9._:-]{8,160}$ ]]; then
      log_anomaly "record-plan" \
        "invalid deferred summary claim agent=${_plan_replay_agent}"
      continue
    fi
    jq -nc \
      --arg sid "${SESSION_ID}" \
      --arg agent "${_plan_replay_agent}" \
      --arg native_id "${_plan_replay_native_id}" \
      --arg message "${_plan_replay_message}" '
        {
          session_id:$sid,
          agent_type:$agent,
          agent_id:$native_id,
          last_assistant_message:$message,
          stop_hook_active:false
        }
      ' | OMC_PLAN_SUMMARY_REPLAY=1 \
        OMC_PUBLICATION_RECOVERY_INTERNAL=1 \
        OMC_PUBLICATION_RECOVERY_CLAIM_ID="${_plan_replay_claim}" \
        bash "${SCRIPT_DIR}/record-subagent-summary.sh" \
        >/dev/null 2>&1 || log_anomaly "record-plan" \
          "deferred planner summary replay failed agent=${_plan_replay_agent}"
  done < <(jq -c '.[]' <<<"${_plan_summary_replays}" 2>/dev/null || true)
fi
if [[ "${_plan_commit_accepted:-0}" -ne 1 ]]; then
  log_hook "record-plan" \
    "discarded planner result reason=${_plan_rejection_reason:-unknown}"
elif [[ "${_plan_quality_required}" == "1" \
    && "${plan_verdict}" == "PLAN_READY" ]]; then
  record_gate_event "definition-of-excellent/contract" "frozen" \
    "contract_id=$(read_state "quality_contract_id" 2>/dev/null || true)" \
    "revision=$(read_state "quality_contract_revision" 2>/dev/null || true)" \
    "must_criteria=${_plan_quality_required_count:-0}" 2>/dev/null || true
fi
