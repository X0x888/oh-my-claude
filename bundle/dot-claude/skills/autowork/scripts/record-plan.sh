#!/usr/bin/env bash

set -euo pipefail

# v1.27.0 (F-020 / F-021): plan-recording hook does state I/O only — no
# classifier or timing-lib dependency.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
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

ensure_session_dir

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

# Soft-nudge handoff to PostToolUse:
#
# When the plan is high-complexity, set `plan_complexity_nudge_pending="1"`
# so the PostToolUse Agent hook (`reflect-after-agent.sh`) can surface
# the notice as `additionalContext` — the documented context-injection
# mechanism for that event. SubagentStop does NOT support
# `additionalContext` (silently dropped by Claude Code), so emitting
# from this hook directly does not reach the model. See CLAUDE.md
# "Stop hook output schema" rule.
#
# `reflect-after-agent.sh` clears the flag after emitting (one-shot
# semantics per high-complexity plan).
nudge_flag=""
if [[ "${_plan_complexity_high}" == "1" ]]; then
  nudge_flag="1"
fi

PLAN_DISPATCH_CAUSALITY_VERSION=1

_planner_identity_matches() {
  case "${1##*:}:${2##*:}" in
    quality-planner:quality-planner|quality-planner:prometheus|prometheus:quality-planner|prometheus:prometheus)
      return 0 ;;
    *) return 1 ;;
  esac
}

_planner_agent_exact_match() {
  [[ "$1" == "$2" ]]
}

# Consume the exact planner start row. Current SubagentStop payloads select the
# platform-bound native agent_id, including cross-planner replacements within
# the one logical current_plan.md publisher. Echoed rebind IDs and oldest-row
# selection exist only for pre-native migration. Summary-first effects-complete
# claims are removed only after the authoritative causal owner is consumed.
_consume_planner_dispatch_start_unlocked() {
  local starts_file tmp line this_type row_id row_native_id selected=""
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  _plan_dispatch_start_json=""
  _plan_use_native_agent_id=0
  _plan_native_binding_committed=0
  _plan_native_tracking_version="$(read_state "native_agent_id_tracking_version")"
  [[ "${_plan_native_agent_id_invalid}" -eq 0 ]] || return 0
  if [[ "${_plan_native_agent_id_present}" -eq 1 \
      && "${_plan_native_agent_id_invalid}" -eq 0 ]]; then
    local bindings_file
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && jq -Rse --arg id "${_plan_native_agent_id}" \
          --arg type "${AGENT_TYPE}" '
            [split("\n")[] | select(length > 0)
                | (try fromjson catch {})
                | select((.native_agent_id // "") == $id
                  and (.agent_type // "") == $type)] | length > 0
          ' "${bindings_file}" >/dev/null 2>&1; then
      _plan_native_binding_committed=1
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
  [[ -f "${starts_file}" ]] || return 0
  tmp="$(mktemp "${starts_file}.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ -z "${selected}" ]]; then
      row_id="$(jq -r '.review_dispatch_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      row_native_id="$(jq -r '.native_agent_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      if { [[ "${_plan_use_native_agent_id}" -eq 1 ]] \
            && [[ "${row_native_id}" == "${_plan_native_agent_id}" ]] \
            && [[ "${this_type}" == "${AGENT_TYPE}" ]]; } \
          || { [[ "${_plan_use_native_agent_id}" -eq 0 ]] \
            && [[ -n "${_plan_dispatch_id}" \
              && "${row_id}" == "${_plan_dispatch_id}" ]] \
            && [[ -z "${row_native_id}" ]] \
            && _planner_identity_matches "${this_type}" "${AGENT_TYPE}"; } \
          || { [[ "${_plan_use_native_agent_id}" -eq 0 ]] \
            && [[ -z "${_plan_dispatch_id}" && -z "${row_id}" \
                  && -z "${row_native_id}" ]] \
            && _planner_agent_exact_match "${this_type}" "${AGENT_TYPE}"; }; then
        selected="${line}"
        continue
      fi
    fi
    printf '%s\n' "${line}" >>"${tmp}" || {
      rm -f "${tmp}"
      return 1
    }
  done <"${starts_file}"
  if [[ -n "${selected}" ]]; then
    mv -f "${tmp}" "${starts_file}" || return 1
    _plan_dispatch_start_json="${selected}"

    local pending_file pending_tmp pending_line pending_type pending_id pending_native_id
    local wanted_id wanted_native_id wanted_agent removed_claim=0
    pending_file="$(session_file "pending_agents.jsonl")"
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
        pending_type="$(jq -r '.agent_type // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_id="$(jq -r '.review_dispatch_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_native_id="$(jq -r '.native_agent_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        if [[ "${removed_claim}" -eq 0 ]] \
            && _planner_agent_exact_match "${pending_type}" "${wanted_agent}" \
            && { { [[ -n "${wanted_native_id}" \
                     && "${pending_native_id}" == "${wanted_native_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -n "${wanted_id}" \
                     && "${pending_id}" == "${wanted_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -z "${wanted_id}" \
                      && -z "${pending_native_id}" \
                      && -z "${pending_id}" ]]; }; } \
            && [[ "$(jq -r '.completion_claim_effects_complete // false' \
              <<<"${pending_line}" 2>/dev/null || true)" == "true" ]]; then
          removed_claim=1
          continue
        fi
        printf '%s\n' "${pending_line}" >>"${pending_tmp}" || {
          rm -f "${pending_tmp}"
          return 1
        }
      done <"${pending_file}"
      mv -f "${pending_tmp}" "${pending_file}" || return 1
    fi
  else
    rm -f "${tmp}"
  fi
}

_record_plan_state_unlocked() {
  local _plan_revision _plan_tmp="" _tracking_version _row_version
  local _strict_tracking=0 _start_revision _start_ts _current_ts
  local _start_cycle_id=0 _current_cycle_id=0 _ready=false
  _plan_commit_accepted=0
  _plan_rejection_reason=""
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
  if [[ -e "${plan_file}" && ! -f "${plan_file}" ]]; then
    log_anomaly "record-plan" \
      "refusing to replace non-regular plan artifact at ${plan_file}"
    return 1
  fi
  _plan_tmp="$(mktemp "${plan_file}.XXXXXX")" || return 1
  if ! {
    printf '# Plan from %s\n\n' "${AGENT_TYPE:-planner}"
    # Strip controls before secret matching so a C0 byte cannot split a token,
    # evade redaction, and then be removed to reconstitute the secret on disk.
    printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" \
      | _omc_strip_render_unsafe \
      | omc_redact_secrets
  } >"${_plan_tmp}"; then
    rm -f "${_plan_tmp}"
    return 1
  fi
  if ! mv -f "${_plan_tmp}" "${plan_file}"; then
    rm -f "${_plan_tmp}"
    return 1
  fi

  if [[ "${_ready}" == "true" ]]; then
    if ! _write_state_batch_unlocked \
        "has_plan" "true" \
        "plan_verdict" "${plan_verdict}" \
        "plan_agent" "${AGENT_TYPE:-planner}" \
        "plan_ts" "$(now_epoch)" \
        "plan_revision" "$((_plan_revision + 1))" \
        "plan_complexity_high" "${_plan_complexity_high}" \
        "plan_complexity_signals" "${_plan_complexity_signals}" \
        "plan_complexity_nudge_pending" "${nudge_flag}" \
        "metis_gate_blocks" ""; then
      return 1
    fi
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
  fi
  _plan_commit_accepted=1
}

_snapshot_plan_transaction_unlocked() {
  local dir="$1" artifact path
  for artifact in session_state.json pending_agents.jsonl \
      agent_dispatch_starts.jsonl current_plan.md; do
    path="$(session_file "${artifact}")"
    if [[ -L "${path}" ]]; then
      : >"${dir}/${artifact}.other" || return 1
    elif [[ -f "${path}" ]]; then
      cp "${path}" "${dir}/${artifact}.file" || return 1
    elif [[ ! -e "${path}" && ! -L "${path}" ]]; then
      : >"${dir}/${artifact}.absent" || return 1
    else
      : >"${dir}/${artifact}.other" || return 1
    fi
  done
}

_restore_plan_transaction_unlocked() {
  local dir="$1" artifact path tmp rc=0
  for artifact in session_state.json pending_agents.jsonl \
      agent_dispatch_starts.jsonl current_plan.md; do
    path="$(session_file "${artifact}")"
    if [[ -f "${dir}/${artifact}.file" ]]; then
      if [[ -L "${path}" ]] \
          || { [[ -e "${path}" ]] && [[ ! -f "${path}" ]]; }; then
        rc=1
        continue
      fi
      tmp="$(mktemp "${path}.restore.XXXXXX")" || { rc=1; continue; }
      if ! cp "${dir}/${artifact}.file" "${tmp}" \
          || ! mv -f "${tmp}" "${path}"; then
        rm -f "${tmp}"
        rc=1
      fi
    elif [[ -f "${dir}/${artifact}.absent" ]]; then
      if [[ -L "${path}" ]]; then
        rc=1
      elif [[ -f "${path}" ]]; then
        rm -f "${path}" || rc=1
      elif [[ -e "${path}" ]]; then
        rc=1
      fi
    fi
  done
  return "${rc}"
}

_record_plan_transaction_unlocked() {
  local snapshot_dir rc=0 restore_rc=0
  snapshot_dir="$(mktemp -d "$(session_file ".plan-txn.XXXXXX")")" \
    || return 1
  if ! _snapshot_plan_transaction_unlocked "${snapshot_dir}"; then
    rm -f "${snapshot_dir}"/* 2>/dev/null || true
    rmdir "${snapshot_dir}" 2>/dev/null || true
    return 1
  fi
  _record_plan_state_unlocked || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    _restore_plan_transaction_unlocked "${snapshot_dir}" || restore_rc=$?
  fi
  rm -f "${snapshot_dir}"/* 2>/dev/null || true
  rmdir "${snapshot_dir}" 2>/dev/null || true
  [[ "${restore_rc}" -eq 0 ]] || return "${restore_rc}"
  return "${rc}"
}

if ! with_state_lock _record_plan_transaction_unlocked; then
  log_hook "record-plan" "plan artifact/state publication failed"
  exit 1
fi
if [[ "${_plan_commit_accepted:-0}" -ne 1 ]]; then
  log_hook "record-plan" \
    "discarded planner result reason=${_plan_rejection_reason:-unknown}"
fi
