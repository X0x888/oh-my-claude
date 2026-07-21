#!/usr/bin/env bash
#
# closeout-preflight.sh — hidden, isolated closeout readiness check.
#
# PostToolBatch mode evaluates likely terminal evidence batches before the next
# model call. Manual mode is the model's explicit fallback when Stop asks it to
# re-check. The live Stop guard is reused against an isolated HOME/STATE_ROOT,
# so the preflight has exactly the same gate semantics without publishing gate
# events, outcomes, one-shot notes, or touching the ULW sentinel. Monotonic
# capped-gate consumption is the sole narrow import from a successful shadow
# evaluation: otherwise one-time warning gates would repeat forever in shadow.

set -euo pipefail

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

_CLOSEOUT_TMP=""
_closeout_cleanup_tmp() {
  if [[ -n "${_CLOSEOUT_TMP:-}" ]]; then
    rm -rf -- "${_CLOSEOUT_TMP}" 2>/dev/null || true
    _CLOSEOUT_TMP=""
  fi
}
trap _closeout_cleanup_tmp EXIT
trap '_closeout_cleanup_tmp; exit 130' INT
trap '_closeout_cleanup_tmp; exit 143' TERM

# shellcheck disable=SC2329 # invoked indirectly through with_state_lock
_closeout_commit_seal_unlocked() {
  local expected="$1" manifest="$2" anchors="$3" current cycle prompt_revision
  current="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  [[ -n "${current}" && "${current}" == "${expected}" ]] || return 2
  cycle="$(read_state "review_cycle_id" 2>/dev/null || true)"
  prompt_revision="$(read_state "prompt_revision" 2>/dev/null || true)"
  _write_state_batch_unlocked \
    "closeout_preflight_status" "ready" \
    "closeout_seal_schema" "1" \
    "closeout_seal_fingerprint" "${expected}" \
    "closeout_seal_prompt_revision" "${prompt_revision}" \
    "closeout_seal_review_cycle_id" "${cycle}" \
    "closeout_seal_edit_revision" "$(read_state "edit_revision" 2>/dev/null || true)" \
    "closeout_seal_plan_revision" "$(read_state "plan_revision" 2>/dev/null || true)" \
    "closeout_seal_manifest" "${manifest}" \
    "closeout_seal_required_anchors" "${anchors}" \
    "closeout_preflight_feedback" "" \
    "closeout_preflight_fingerprint" "${expected}" \
    "closeout_preflight_ts" "$(now_epoch)" \
    "closeout_preflight_context_fingerprint" ""
}

_closeout_store_not_ready_unlocked() {
  local fingerprint="$1" feedback="$2" current status seal
  current="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  if [[ -n "${fingerprint}" && "${current}" != "${fingerprint}" ]]; then
    return 2
  fi
  status="$(read_state "closeout_preflight_status" 2>/dev/null || true)"
  seal="$(read_state "closeout_seal_fingerprint" 2>/dev/null || true)"
  # A concurrent evaluation may have consumed the same warning counter and
  # sealed this generation already. Never let the older blocked shadow clobber
  # that newer READY result merely because counters are fingerprint-excluded.
  if [[ "${status}" == "ready" && -n "${seal}" && "${seal}" == "${current}" ]]; then
    return 3
  fi
  _write_state_batch_unlocked \
    "closeout_preflight_status" "not_ready" \
    "closeout_seal_fingerprint" "" \
    "closeout_seal_manifest" "" \
    "closeout_seal_required_anchors" "" \
    "closeout_preflight_feedback" "$(truncate_chars 7600 "${feedback}")" \
    "closeout_preflight_fingerprint" "${fingerprint}" \
    "closeout_preflight_ts" "$(now_epoch)" \
    "closeout_preflight_context_fingerprint" ""
}

_closeout_store_not_ready() {
  with_state_lock _closeout_store_not_ready_unlocked "$1" "$2" 2>/dev/null || true
}

# Import only two presentation-warning acknowledgements from a blocked shadow.
# Never consume substantive review, verification, objective, goal, dimension,
# scope, or generic exhaustion budgets before a real completion attempt.
# Max-merge makes concurrent preflights idempotent.
# shellcheck disable=SC2329 # invoked indirectly through with_state_lock
_closeout_import_shadow_consumption_unlocked() {
  local expected="$1" shadow_file="$2" current key shadow_value live_value
  local -a updates=()
  current="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  [[ -n "${current}" && "${current}" == "${expected}" ]] || return 2
  [[ -f "${shadow_file}" ]] || return 1
  while IFS=$'\t' read -r key shadow_value; do
    [[ -n "${key}" ]] || continue
    _omc_canonical_uint_in_range \
      "${shadow_value}" 0 999999999999999999 || return 1
    live_value="$(read_state "${key}" 2>/dev/null || true)"
    live_value="${live_value:-0}"
    _omc_canonical_uint_in_range \
      "${live_value}" 0 999999999999999999 || return 1
    if (( shadow_value > live_value )); then
      updates+=("${key}" "${shadow_value}")
    fi
  done < <(jq -r '
    to_entries[]
    | select(.key == "shortcut_ratio_blocks" or .key == "wave_shape_blocks")
    | select((.value | tostring) | test("^[0-9]+$"))
    | [.key, (.value | tostring)] | @tsv
  ' "${shadow_file}" 2>/dev/null || true)
  (( ${#updates[@]} > 0 )) || return 0
  _write_state_batch_unlocked "${updates[@]}"
}

_closeout_import_shadow_consumption() {
  with_state_lock _closeout_import_shadow_consumption_unlocked "$1" "$2"
}

# shellcheck disable=SC2329 # invoked indirectly through with_state_lock
_closeout_advance_material_generation_unlocked() {
  local nonce_claim="${1:-}" generation
  if ! is_ultrawork_mode; then
    closeout_clear_material_nonce_claim "${nonce_claim}"
    return 20
  fi
  generation="$(read_state "work_material_generation" 2>/dev/null || true)"
  generation="${generation:-0}"
  _omc_canonical_uint_in_range \
    "${generation}" 0 999999999999999998 || return 21
  _write_state_batch_unlocked \
    "work_material_generation" "$((generation + 1))" \
    "closeout_material_activity" "1"
}

_closeout_evaluate() {
  local start_fp end_fp tmp shadow_home shadow_state shadow_session
  local conf_file shadow_out shadow_rc shadow_outcome shadow_json_valid synthetic payload reason manifest anchors commit_rc import_rc

  start_fp="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  if [[ -z "${start_fp}" ]]; then
    _closeout_store_not_ready "" "[Closeout preflight] session readiness state could not be fingerprinted. Continue without a completion summary and repair/read the session state before retrying."
    return 1
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/omc-closeout.XXXXXX")" || {
    _closeout_store_not_ready "${start_fp}" "[Closeout preflight] could not allocate an isolated state copy. Continue without a completion summary and retry the preflight."
    return 1
  }
  _CLOSEOUT_TMP="${tmp}"
  shadow_home="${tmp}/home"
  shadow_state="${shadow_home}/.claude/quality-pack/state"
  shadow_session="${shadow_state}/${SESSION_ID}"
  mkdir -p "${shadow_state}" "${shadow_home}/.claude"
  if ! cp -R "${STATE_ROOT}/${SESSION_ID}" "${shadow_session}" 2>/dev/null; then
    _closeout_cleanup_tmp
    _closeout_store_not_ready "${start_fp}" "[Closeout preflight] the active session could not be copied atomically enough to evaluate. Continue without a completion summary and retry after current tool/state writes settle."
    return 1
  fi
  # The mutex protects only the live session directory. A copied lock keeps
  # the live holder PID but can never be released by that holder inside the
  # detached shadow, so carrying it into the probe creates a false timeout.
  # Readiness is still guarded by the live start/end fingerprint and the
  # commit-time state lock; only this non-state synchronization artifact is
  # discarded from the isolated copy.
  rm -rf "${shadow_session}/.state.lock" "${shadow_session}/.state.lock.owner"
  touch "${shadow_state}/.ulw_active"
  conf_file="${HOME}/.claude/oh-my-claude.conf"
  if [[ -f "${conf_file}" ]]; then
    cp "${conf_file}" "${shadow_home}/.claude/oh-my-claude.conf" 2>/dev/null || true
  fi

  synthetic="$(printf 'Verification command recorded above: %s\n\n**Changed.** Complete original-objective work is ready for one cumulative closeout.\n**Verification.** The exact command above passed with the recorded result.\n**Risks.** Every deferred item, if any, is named with its reason.\n**Objective coverage.** A fresh completeness audit covers the full original objective.\n**Goal achieved.** Declared criteria are covered by the recorded evidence.\n**Next.** Done.' \
    "$(read_state "last_verify_cmd" 2>/dev/null || true)")"
  payload="$(jq -nc \
    --arg sid "${SESSION_ID}" \
    --arg cwd "${PWD}" \
    --arg message "${synthetic}" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$message,background_tasks:[],session_crons:[]}')"

  shadow_rc=0
  shadow_out="$(
    HOME="${shadow_home}" \
    STATE_ROOT="${shadow_state}" \
    OMC_LAZY_CLASSIFIER=0 \
    OMC_LAZY_TIMING=0 \
    OMC_CLOSEOUT_PREFLIGHT_PROBE=1 \
    bash "${SCRIPT_DIR}/stop-guard.sh" <<<"${payload}"
  )" || shadow_rc=$?
  shadow_outcome="$(jq -r '.session_outcome // empty' "${shadow_session}/${STATE_JSON}" 2>/dev/null || true)"
  end_fp="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  shadow_json_valid=1
  if [[ -n "${shadow_out}" ]]; then
    if jq -s -e 'length == 1 and (.[0] | type == "object")' <<<"${shadow_out}" >/dev/null 2>&1; then
      shadow_out="$(jq -sc '.[0]' <<<"${shadow_out}")"
    else
      shadow_json_valid=0
    fi
  fi

  if [[ "${shadow_rc}" -ne 0 ]]; then
    reason="[Closeout preflight] the isolated guard crashed (exit ${shadow_rc}); completion is not certified. Continue without a completion summary, inspect the hook log, and retry."
  elif [[ "${shadow_json_valid}" -ne 1 ]]; then
    reason="[Closeout preflight] the isolated guard returned invalid or multiple responses; completion is not certified. Continue without a completion summary, inspect the hook log, and retry."
  elif [[ -z "${end_fp}" || "${start_fp}" != "${end_fp}" ]]; then
    reason="[Closeout preflight] work/evidence changed while readiness was evaluated. Continue without a completion summary, wait for active writes/reviewers to settle, then retry."
  elif [[ "${shadow_outcome}" == "completed" ]] \
      && { [[ -z "${shadow_out}" ]] || jq -e '(.decision // "") != "block" and (.hookSpecificOutput.additionalContext // "") == ""' <<<"${shadow_out}" >/dev/null 2>&1; }; then
    anchors="$(closeout_build_required_anchors)"
    manifest="$(closeout_build_manifest "${anchors}")"
    commit_rc=0
    with_state_lock _closeout_commit_seal_unlocked "${start_fp}" "${manifest}" "${anchors}" || commit_rc=$?
    _closeout_cleanup_tmp
    if [[ "${commit_rc}" -ne 0 ]]; then
      _closeout_store_not_ready "${end_fp}" "[Closeout preflight] readiness changed before the seal could be committed. Continue without a completion summary and retry after current writes settle."
      return 1
    fi
    # A ledger that does not share the state mutex could move immediately
    # after commit. Recompute once more; conditionally invalidate our seal if
    # it no longer names the current report.
    end_fp="$(closeout_readiness_fingerprint 2>/dev/null || true)"
    if [[ "${end_fp}" != "${start_fp}" ]]; then
      _closeout_store_not_ready "${end_fp}" "[Closeout preflight] readiness changed immediately after sealing. Continue without a completion summary and run the check again."
      return 1
    fi
    return 0
  else
    if jq -e '.decision == "block"' <<<"${shadow_out}" >/dev/null 2>&1; then
      reason="$(jq -r '.reason // empty' <<<"${shadow_out}" 2>/dev/null || true)"
    elif jq -e '.systemMessage | type == "string"' <<<"${shadow_out}" >/dev/null 2>&1; then
      reason="$(jq -r '.systemMessage' <<<"${shadow_out}" 2>/dev/null || true)"
    else
      reason="[Closeout preflight] the isolated guard did not certify a completed outcome. Continue the original objective and retry the check after fresh evidence is recorded."
    fi
    # A hidden check is still a genuine attempt at a capped warning gate. Copy
    # only its monotonic consumption counters, under a full-generation CAS, so
    # the next tool batch can progress instead of seeing warning 1 forever.
    if [[ "${shadow_rc}" -eq 0 && "${shadow_json_valid}" -eq 1 && -n "${end_fp}" && "${start_fp}" == "${end_fp}" ]]; then
      import_rc=0
      _closeout_import_shadow_consumption "${start_fp}" "${shadow_session}/${STATE_JSON}" || import_rc=$?
      if [[ "${import_rc}" -eq 2 ]]; then
        reason="[Closeout preflight] work/evidence changed while capped-gate state was being committed. Continue without completion prose and retry after active writes settle."
      elif [[ "${import_rc}" -ne 0 ]]; then
        reason="[Closeout preflight] capped-gate progress could not be committed safely. Continue without completion prose and retry the check."
      fi
    fi
  fi

  _closeout_cleanup_tmp
  _closeout_store_not_ready "${end_fp:-${start_fp}}" "${reason}"
  return 1
}

_closeout_emit_posttool_context() {
  local status fingerprint sealed current injected feedback manifest context payload
  status="$(read_state "closeout_preflight_status" 2>/dev/null || true)"
  fingerprint="$(read_state "closeout_preflight_fingerprint" 2>/dev/null || true)"
  sealed="$(read_state "closeout_seal_fingerprint" 2>/dev/null || true)"
  current="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  injected="$(read_state "closeout_preflight_context_fingerprint" 2>/dev/null || true)"

  if [[ "${status}" == "ready" && -n "${sealed}" && "${sealed}" == "${current}" ]]; then
    [[ "${injected}" != "ready:${sealed}" ]] || return 0
    manifest="$(read_state "closeout_seal_manifest" 2>/dev/null || true)"
    printf -v context '%s\n\n%s\n%s' \
      "OMC INTERNAL CLOSEOUT PREFLIGHT: READY for the sealed work generation. Write exactly ONE self-contained cumulative final response now, with NO more tool calls after completion prose. It replaces every candidate/delta summary and must preserve the original objective, every material shipped change, exact verification command/result, reviewer findings and dispositions, residual risks/deferrals, and next state. Do not say only what changed since a prior summary." \
      "CUMULATIVE EVIDENCE MANIFEST:" \
      "${manifest}"
    if (( ${#context} >= 9500 )); then
      _closeout_store_not_ready "${current}" \
        "[Closeout preflight] the cumulative evidence packet exceeded the safe hook-output budget. Continue without completion prose; reduce or consolidate redundant evidence while preserving required facts, then retry."
      context="OMC INTERNAL CLOSEOUT PREFLIGHT: NOT READY. The cumulative evidence packet exceeded the safe hook-output budget, so no tail-truncated final is authorized. Consolidate redundant evidence without dropping required facts, then retry the closeout preflight."
      payload="$(jq -nc --arg ctx "${context}" '{
        suppressOutput: true,
        hookSpecificOutput: {hookEventName: "PostToolBatch", additionalContext: $ctx}
      }')" || return 0
      printf '%s\n' "${payload}"
      return 0
    fi
    payload="$(jq -nc --arg ctx "${context}" '{
      suppressOutput: true,
      hookSpecificOutput: {hookEventName: "PostToolBatch", additionalContext: $ctx}
    }')" || return 0
    printf '%s\n' "${payload}"
    write_state "closeout_preflight_context_fingerprint" "ready:${sealed}" 2>/dev/null || true
    return 0
  elif [[ "${status}" == "not_ready" && -n "${fingerprint}" && "${fingerprint}" == "${current}" ]]; then
    [[ "${injected}" != "not_ready:${fingerprint}" ]] || return 0
    feedback="$(read_state "closeout_preflight_feedback" 2>/dev/null || true)"
    printf -v context '%s\n\n%s' \
      "OMC INTERNAL CLOSEOUT PREFLIGHT: NOT READY. Do not produce a completion summary yet and do not narrate a provisional final. Continue the original objective, resolve the gate below, then let PostToolBatch re-check or run closeout-preflight.sh explicitly." \
      "${feedback}"
  elif [[ "${status}" == "ready" && -n "${sealed}" && "${sealed}" != "${current}" ]]; then
    write_state_batch \
      "closeout_preflight_status" "stale" \
      "closeout_seal_fingerprint" "" \
      "closeout_preflight_context_fingerprint" "stale:${current}" 2>/dev/null || true
    context="OMC INTERNAL CLOSEOUT PREFLIGHT: the READY seal became stale because work/evidence changed. Do not produce completion prose. Finish and re-verify/re-review the new generation; a fresh terminal evidence batch will re-check it."
  else
    return 0
  fi

  payload="$(jq -nc --arg ctx "$(truncate_chars 9500 "${context}")" '{
    suppressOutput: true,
    hookSpecificOutput: {
      hookEventName: "PostToolBatch",
      additionalContext: $ctx
    }
  }')" || return 0
  printf '%s\n' "${payload}"
  if [[ "${status}" == "not_ready" ]]; then
    write_state "closeout_preflight_context_fingerprint" "not_ready:${fingerprint}" 2>/dev/null || true
  fi
}

if [[ "${1:-}" == "--posttool-batch" ]]; then
  HOOK_JSON="$(_omc_read_hook_stdin)"
  SESSION_ID="$(json_get '.session_id')"
  [[ -n "${SESSION_ID}" ]] || exit 0
  validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
  if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
    jq -nc --arg ctx \
      "OMC INTERNAL CLOSEOUT PREFLIGHT: PAUSED. Agent admission is interrupted; no material-generation, seal, or gate state was advanced. Run the exact /ulw-off reset before continuing." '{suppressOutput:true,hookSpecificOutput:{hookEventName:"PostToolBatch",additionalContext:$ctx}}'
    exit 0
  fi
  ensure_session_dir
  capture_ulw_enforcement_interval || exit 0

  # File edits are not the only material work. A connector call, research
  # read, or Agent result can produce the whole deliverable without touching
  # edited_files.log. Arm the closeout lifecycle after the first real batch;
  # the fresh execution router clears it before any tool is used.
  if jq -e 'any(.tool_calls[]?; true)' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
    case "$(read_state "task_intent" 2>/dev/null || true)" in
      execution|continuation)
        _nonce_claim="$(closeout_advance_material_nonce "${_OMC_ULW_CAPTURED_GENERATION}")" || {
          jq -nc --arg ctx "OMC INTERNAL CLOSEOUT PREFLIGHT: NOT READY. Material-work generation could not be recorded safely, so any earlier READY seal is untrusted. Continue no completion prose; retry after the session filesystem is writable." '{suppressOutput:true,hookSpecificOutput:{hookEventName:"PostToolBatch",additionalContext:$ctx}}'
          exit 0
        }
        _advance_rc=0
        with_state_lock _closeout_advance_material_generation_unlocked "${_nonce_claim}" 2>/dev/null || _advance_rc=$?
        if [[ "${_advance_rc}" -eq 20 ]]; then
          # The callback belongs to a finalized or superseded interval. Its
          # conditional nonce cleanup ran under lock; do not inject stale
          # recovery into the current interval.
          exit 0
        elif [[ "${_advance_rc}" -ne 0 ]]; then
          # The nonce above already invalidated any old seal. Never inspect or
          # re-emit cached READY state after the diagnostic counter failed.
          jq -nc --arg ctx "OMC INTERNAL CLOSEOUT PREFLIGHT: NOT READY. Material-work generation is newer, but its state transaction is still contended. Continue no completion prose and retry closeout after the active state writer finishes." '{suppressOutput:true,hookSpecificOutput:{hookEventName:"PostToolBatch",additionalContext:$ctx}}'
          exit 0
        fi
        ;;
    esac
  fi
  closeout_seal_is_required || exit 0

  # A READY result can be invalidated cheaply on any later batch. The
  # relatively expensive isolated guard runs only on likely terminal evidence;
  # a sticky NOT_READY/STALE status alone must not make every edit batch run a
  # full shadow Stop evaluation.
  _status="$(read_state "closeout_preflight_status" 2>/dev/null || true)"
  _current="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  _ready_became_stale=0
  if [[ "${_status}" == "ready" ]]; then
    _sealed="$(read_state "closeout_seal_fingerprint" 2>/dev/null || true)"
    if [[ -n "${_sealed}" && "${_sealed}" == "${_current}" ]]; then
      _closeout_emit_posttool_context
      exit 0
    fi
    _ready_became_stale=1
  fi

  _candidate=0
  if jq -e '
      any(.tool_calls[]?;
        (.tool_name == "Agent" and ((.tool_input.subagent_type // "")
          | test("reviewer|critic|metis|briefing-analyst"; "i")))
        or (((.tool_name // "") | startswith("mcp__"))
          and ((.tool_name // "") | test("test|verify|check|validate|inspect|render|screenshot"; "i")))
        or (.tool_name == "Bash" and ((.tool_input.command // "")
          | test("(test|tests|check|lint|verify|validate|build|git\\s+(commit|push|tag)|gh\\s+(pr|release)|closeout-preflight|record-(finding|scope|delivery))"; "i"))))
    ' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
    _candidate=1
  fi
  if [[ "${_ready_became_stale}" -eq 1 && "${_candidate}" -eq 0 ]]; then
    # Emit one STALE packet for this non-terminal mutation. Candidate batches
    # skip this intermediate packet and emit only their re-evaluated result.
    _closeout_emit_posttool_context
    exit 0
  fi
  if [[ "${_ready_became_stale}" -eq 1 ]]; then
    write_state_batch \
      "closeout_preflight_status" "stale" \
      "closeout_seal_fingerprint" "" \
      "closeout_seal_required_anchors" "" \
      "closeout_preflight_context_fingerprint" "" 2>/dev/null || true
    _status="stale"
  fi
  [[ "${_candidate}" -eq 1 ]] || exit 0

  _evaluated="$(read_state "closeout_preflight_fingerprint" 2>/dev/null || true)"
  if [[ -z "${_status}" || "${_current}" != "${_evaluated}" ]]; then
    _closeout_evaluate || true
  fi
  _closeout_emit_posttool_context
  exit 0
fi

# Manual fallback: use an exact session identity when Claude supplies one.
# Direct-shell compatibility accepts only one active same-cwd candidate; this
# mutating helper never guesses by mtime or falls back across projects.
if [[ -n "${1:-}" ]]; then
  SESSION_ID="$1"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  SESSION_ID="${CLAUDE_CODE_SESSION_ID}"
elif [[ -n "${SESSION_ID:-}" ]]; then
  : # Legacy/manual exact-session environment.
else
  SESSION_ID=""
fi
_manual_authority_unknown=0
if [[ -n "${SESSION_ID}" ]]; then
  if ! validate_session_id "${SESSION_ID}" 2>/dev/null; then
    printf 'OMC closeout preflight: NOT_READY — invalid session identity.\n'
    exit 0
  fi
  _manual_state="${STATE_ROOT}/${SESSION_ID}/${STATE_JSON}"
  _manual_active="$(jq -r '
    ((.ulw_enforcement_active // "") | tostring) as $active
    | if (.workflow_mode // "") == "ultrawork" then
        if $active == "1" then "on"
        elif $active == "0" then "off"
        elif (.session_outcome // "") == "" then "on"
        else "off"
        end
      elif $active == "0" then "off"
      elif (.workflow_mode // "") == "" and (.session_outcome // "") == "" then "unknown"
      else "off"
      end
  ' "${_manual_state}" 2>/dev/null || true)"
  if [[ "${_manual_active}" == "unknown" \
      && -f "${STATE_ROOT}/${SESSION_ID}/.ulw_active" ]]; then
    _manual_authority_unknown=1
  elif [[ "${_manual_active}" != "on" ]]; then
    # An explicit identity from argv or the current process environment is
    # authority, not a discovery hint. Falling through could mutate a different
    # same-cwd session when the addressed session is stale or already closed.
    printf 'OMC closeout preflight: NOT_READY — addressed session is missing or inactive.\n'
    exit 0
  fi
fi
if [[ -z "${SESSION_ID}" ]]; then
  _manual_count=0
  _manual_candidates=""
  for _manual_dir in "${STATE_ROOT}"/*/; do
    [[ -d "${_manual_dir}" ]] || continue
    _manual_state="${_manual_dir}/${STATE_JSON}"
    _manual_cwd="$(_omc_read_nul_free_string_field \
      "${_manual_state}" "cwd" 2>/dev/null || true)"
    [[ -n "${PWD:-}" && "${_manual_cwd}" == "${PWD}" ]] || continue
    _manual_active="$(jq -r '
      ((.ulw_enforcement_active // "") | tostring) as $active
      | if (.workflow_mode // "") == "ultrawork" then
          if $active == "1" then "on"
          elif $active == "0" then "off"
          elif (.session_outcome // "") == "" then "on"
          else "off"
          end
        elif $active == "0" then "off"
        elif (.workflow_mode // "") == "" and (.session_outcome // "") == "" then "unknown"
        else "off"
        end
    ' "${_manual_state}" 2>/dev/null || true)"
    _manual_candidate_unknown=0
    if [[ "${_manual_active}" == "unknown" \
        && -f "${_manual_dir}/.ulw_active" ]]; then
      _manual_candidate_unknown=1
    elif [[ "${_manual_active}" != "on" ]]; then
      continue
    fi
    _manual_sid="$(basename "${_manual_dir}")"
    validate_session_id "${_manual_sid}" 2>/dev/null || continue
    _manual_count=$((_manual_count + 1))
    _manual_candidates="${_manual_candidates:+${_manual_candidates} }${_manual_sid}"
    SESSION_ID="${_manual_sid}"
    _manual_authority_unknown="${_manual_candidate_unknown}"
  done
  if [[ "${_manual_count}" -gt 1 ]]; then
    printf 'OMC closeout preflight: NOT_READY — multiple active sessions share this working directory (%s); pass the exact session id.\n' \
      "${_manual_candidates}"
    exit 0
  fi
fi
if [[ -z "${SESSION_ID}" ]]; then
  printf 'OMC closeout preflight: NOT_READY — no active session found for this working directory.\n'
  exit 0
fi
if [[ "${_manual_authority_unknown}" -eq 1 ]]; then
  printf 'OMC closeout preflight: NOT_READY — the addressed active marker has incomplete or recovered state; repair/recover session authority before certifying completion.\n'
  exit 0
fi
ensure_session_dir

# Manual preflight is itself a certifying read/mutation. Linearize the complete
# no-seal/evaluate decision under the session mutex: a dispatch journal created
# before acquisition is rejected by with_state_lock's outer/in-lock fences, and
# an Agent admission cannot begin between our final journal check and READY.
# This matters most for the no-material fast path, which otherwise never entered
# a locked writer and could certify an interrupted Agent admission as READY.
_closeout_manual_preflight_unlocked() {
  if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
    return 76
  fi
  if ! closeout_seal_is_required; then
    printf 'OMC closeout preflight: READY — no material closeout seal is required for this turn.\n'
    return 0
  fi
  if _closeout_evaluate; then
    printf 'OMC closeout preflight: READY — one cumulative final response may now be written.\n'
  else
    local feedback
    feedback="$(read_state "closeout_preflight_feedback" 2>/dev/null || true)"
    printf 'OMC closeout preflight: NOT_READY — %s\n' \
      "$(closeout_compact_gate_feedback "${feedback}")"
  fi
  return 0
}

_manual_preflight_rc=0
with_state_lock _closeout_manual_preflight_unlocked \
  || _manual_preflight_rc=$?
if [[ "${_manual_preflight_rc}" -eq 76 ]]; then
  printf 'OMC closeout preflight: NOT_READY — Agent admission is interrupted; no completion seal was certified. Run the exact /ulw-off reset before continuing.\n'
  exit 0
elif [[ "${_manual_preflight_rc}" -ne 0 ]]; then
  printf 'OMC closeout preflight: NOT_READY — session state could not be certified under the closeout lock; retry after the active writer settles.\n'
  exit 0
fi
exit 0
