#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): record/edit hooks have no classifier or timing-lib
# dependency — opt out of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

RECORD_PENDING_MODE="${1:-dispatch}"

SESSION_ID="$(json_get '.session_id')"
if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir
is_ultrawork_mode || exit 0
capture_ulw_enforcement_interval || exit 0

# Claude Code 2.0.43+ supplies a native agent_id on SubagentStart and
# SubagentStop. PreToolUse cannot know that ID, so SubagentStart binds it to
# the one exact live row recorded immediately before launch. Same-exact-type
# duplicate admission is denied below, making this bind unique without FIFO
# guesswork. Pending + reviewer/planner start + tracking marker publish as one
# rollback-safe transaction under the session lock.
if [[ "${RECORD_PENDING_MODE}" == "start" ]]; then
  native_agent_id="$(json_get '.agent_id')"
  native_agent_type="$(json_get '.agent_type')"
  if [[ -z "${native_agent_id}" || -z "${native_agent_type}" ]]; then
    exit 0
  fi
  if [[ ! "${native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
      || ! "${native_agent_type}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    log_anomaly "record-pending-agent" \
      "SubagentStart supplied an invalid native agent identity"
    exit 1
  fi
  if ! is_ultrawork_mode; then
    exit 0
  fi

  _native_agent_start_is_stateful() {
    case "${1##*:}" in
      quality-reviewer|code-reviewer|editor-critic|excellence-reviewer|release-reviewer|metis|briefing-analyst|design-reviewer|quality-planner|prometheus)
        return 0 ;;
      *) return 1 ;;
    esac
  }

  _bind_native_agent_start_unlocked() {
    local pending_file starts_file bindings_file snapshot_dir artifact path
    local line row_type row_native row_abandoned pending_count=0
    local selected="" selected_id selected_ts selected_cycle
    local starts_count=0 temp updated rc=0 restore_rc=0
    pending_file="$(session_file "pending_agents.jsonl")"
    starts_file="$(session_file "agent_dispatch_starts.jsonl")"
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    for path in "${pending_file}" "${starts_file}" "${bindings_file}"; do
      [[ ! -L "${path}" ]] \
        && { [[ ! -e "${path}" ]] || [[ -f "${path}" ]]; } || return 1
    done
    [[ -s "${pending_file}" ]] || return 1
    if [[ -s "${bindings_file}" ]] \
        && ! jq -Rse '
          all(split("\n")[] | select(length > 0);
              (try fromjson catch null) as $row
              | ($row | type) == "object"
                and (($row.native_agent_id // "")
                     | test("^[A-Za-z0-9._:-]{1,128}$"))
                and (($row.agent_type // "")
                     | test("^[A-Za-z0-9._:-]{1,128}$")))
        ' "${bindings_file}" >/dev/null 2>&1; then
      return 1
    fi

    # A native ID is the platform-issued causal identifier for one call. Any
    # prior occurrence is a hook replay/collision and is never rebound.
    for path in "${pending_file}" "${starts_file}" "${bindings_file}"; do
      [[ -s "${path}" ]] || continue
      if jq -Rse --arg id "${native_agent_id}" '
          [split("\n")[] | select(length > 0)
              | (try fromjson catch {})
              | select((.native_agent_id // "") == $id)] | length > 0
        ' "${path}" >/dev/null 2>&1; then
        return 1
      fi
    done

    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      row_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      row_native="$(jq -r '.native_agent_id // empty' <<<"${line}" 2>/dev/null || true)"
      row_abandoned="$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${line}" 2>/dev/null || true)"
      if [[ "${row_type}" == "${native_agent_type}" \
          && -z "${row_native}" && "${row_abandoned}" != "true" ]]; then
        pending_count=$((pending_count + 1))
        selected="${line}"
      fi
    done <"${pending_file}"
    [[ "${pending_count}" -eq 1 ]] || return 1

    selected_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    selected_ts="$(jq -r '.ts // -1' <<<"${selected}" 2>/dev/null || true)"
    selected_cycle="$(jq -r '.objective_cycle_id // 0' \
      <<<"${selected}" 2>/dev/null || true)"

    if _native_agent_start_is_stateful "${native_agent_type}"; then
      [[ -s "${starts_file}" ]] || return 1
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if jq -e --arg type "${native_agent_type}" \
            --arg id "${selected_id}" \
            --argjson ts "${selected_ts}" \
            --argjson cycle "${selected_cycle}" '
              (.agent_type // "") == $type
              and (.review_dispatch_id // "") == $id
              and (.ts // -1) == $ts
              and (.objective_cycle_id // 0) == $cycle
              and (.native_agent_id // "") == ""
              and (.review_dispatch_abandoned // false) != true
            ' <<<"${line}" >/dev/null 2>&1; then
          starts_count=$((starts_count + 1))
        fi
      done <"${starts_file}"
      [[ "${starts_count}" -eq 1 ]] || return 1
    fi

    snapshot_dir="$(mktemp -d "$(session_file ".native-bind-txn.XXXXXX")")" \
      || return 1
    for artifact in session_state.json pending_agents.jsonl \
        agent_dispatch_starts.jsonl native_agent_bindings.jsonl; do
      path="$(session_file "${artifact}")"
      if [[ -f "${path}" ]]; then
        cp "${path}" "${snapshot_dir}/${artifact}.file" || rc=1
      elif [[ ! -e "${path}" && ! -L "${path}" ]]; then
        : >"${snapshot_dir}/${artifact}.absent" || rc=1
      else
        rc=1
      fi
    done

    if [[ "${rc}" -eq 0 ]]; then
      temp="$(mktemp "${pending_file}.XXXXXX")" || rc=1
    fi
    if [[ "${rc}" -eq 0 ]]; then
      local replaced=0
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if [[ "${replaced}" -eq 0 && "${line}" == "${selected}" ]]; then
          updated="$(jq -c --arg id "${native_agent_id}" \
            --arg type "${native_agent_type}" --argjson bound_ts "$(now_epoch)" '
              . + {native_agent_id:$id,native_agent_type:$type,
                   native_agent_bound_ts:$bound_ts}
            ' <<<"${line}" 2>/dev/null || true)"
          [[ -n "${updated}" ]] || { rc=1; break; }
          line="${updated}"
          replaced=1
        fi
        printf '%s\n' "${line}" >>"${temp}" || { rc=1; break; }
      done <"${pending_file}"
      [[ "${replaced}" -eq 1 ]] || rc=1
      if [[ "${rc}" -eq 0 ]]; then
        mv -f "${temp}" "${pending_file}" || rc=1
      else
        rm -f "${temp}"
      fi
    fi

    if [[ "${rc}" -eq 0 ]] \
        && _native_agent_start_is_stateful "${native_agent_type}"; then
      temp="$(mktemp "${starts_file}.XXXXXX")" || rc=1
      if [[ "${rc}" -eq 0 ]]; then
        local start_replaced=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
          [[ -n "${line}" ]] || continue
          if [[ "${start_replaced}" -eq 0 ]] \
              && jq -e --arg type "${native_agent_type}" \
                --arg id "${selected_id}" --argjson ts "${selected_ts}" \
                --argjson cycle "${selected_cycle}" '
                  (.agent_type // "") == $type
                  and (.review_dispatch_id // "") == $id
                  and (.ts // -1) == $ts
                  and (.objective_cycle_id // 0) == $cycle
                  and (.native_agent_id // "") == ""
                  and (.review_dispatch_abandoned // false) != true
                ' <<<"${line}" >/dev/null 2>&1; then
            updated="$(jq -c --arg id "${native_agent_id}" \
              --arg type "${native_agent_type}" --argjson bound_ts "$(now_epoch)" '
                . + {native_agent_id:$id,native_agent_type:$type,
                     native_agent_bound_ts:$bound_ts}
              ' <<<"${line}" 2>/dev/null || true)"
            [[ -n "${updated}" ]] || { rc=1; break; }
            line="${updated}"
            start_replaced=1
          fi
          printf '%s\n' "${line}" >>"${temp}" || { rc=1; break; }
        done <"${starts_file}"
        [[ "${start_replaced}" -eq 1 ]] || rc=1
        if [[ "${rc}" -eq 0 ]]; then
          mv -f "${temp}" "${starts_file}" || rc=1
        else
          rm -f "${temp}"
        fi
      fi
    fi
    if [[ "${rc}" -eq 0 ]]; then
      _write_state_batch_unlocked \
        "native_agent_id_tracking_version" "1" || rc=1
    fi

    # The registry row is the durable commit marker. Consumers require it in
    # addition to the bound ledger row, so a SIGKILL between the pending/start
    # renames can never turn a partial bind into authoritative evidence.
    if [[ "${rc}" -eq 0 ]]; then
      local binding_entry binding_source live_ids_json
      local -a binding_live_sources
      binding_entry="$(jq -nc --arg id "${native_agent_id}" \
        --arg type "${native_agent_type}" \
        --arg review_dispatch_id "${selected_id}" \
        --argjson objective_cycle_id "${selected_cycle}" \
        --argjson ts "$(now_epoch)" '
          {native_agent_id:$id,agent_type:$type,
           review_dispatch_id:$review_dispatch_id,
           objective_cycle_id:$objective_cycle_id,ts:$ts}
        ')" || rc=1
      binding_source="${bindings_file}"
      [[ -f "${binding_source}" ]] || binding_source="/dev/null"
      binding_live_sources=("${pending_file}")
      [[ -f "${starts_file}" ]] && binding_live_sources+=("${starts_file}")
      live_ids_json="$(jq -Rn '
        [inputs | select(length > 0)
          | (try fromjson catch {})
          | select((.review_dispatch_abandoned // false) != true)
          | .native_agent_id // empty
          | select(type == "string" and length > 0)]
        | unique
      ' "${binding_live_sources[@]}")" || rc=1
      temp="$(mktemp "${bindings_file}.XXXXXX")" || rc=1
      if [[ "${rc}" -eq 0 ]]; then
        if ! jq -Rsr --arg entry "${binding_entry}" \
            --argjson live_ids "${live_ids_json}" '
            (split("\n") | map(select(length > 0)) + [$entry]) as $lines
            | [$lines | to_entries[]
                | (.value | fromjson) as $row
                | select(($live_ids | index($row.native_agent_id)) == null)
                | .key] as $history
            | (($history | length) - 128) as $excess
            | ($history[0:(if $excess > 0 then $excess else 0 end)]) as $drop
            | $lines | to_entries[] | . as $item
            | select(($drop | index($item.key)) == null)
            | $item.value
          ' "${binding_source}" >"${temp}" \
            || ! mv -f "${temp}" "${bindings_file}"; then
          rm -f "${temp}"
          rc=1
        fi
      else
        rm -f "${temp:-}"
      fi
    fi

    if [[ "${rc}" -ne 0 ]]; then
      for artifact in session_state.json pending_agents.jsonl \
          agent_dispatch_starts.jsonl native_agent_bindings.jsonl; do
        path="$(session_file "${artifact}")"
        if [[ -f "${snapshot_dir}/${artifact}.file" ]]; then
          temp="$(mktemp "${path}.restore.XXXXXX")" || { restore_rc=1; continue; }
          cp "${snapshot_dir}/${artifact}.file" "${temp}" \
            && mv -f "${temp}" "${path}" || { rm -f "${temp}"; restore_rc=1; }
        elif [[ -f "${snapshot_dir}/${artifact}.absent" ]]; then
          [[ ! -L "${path}" ]] && rm -f "${path}" || restore_rc=1
        fi
      done
    fi
    rm -f "${snapshot_dir}"/* 2>/dev/null || true
    rmdir "${snapshot_dir}" 2>/dev/null || true
    [[ "${restore_rc}" -eq 0 ]] || return 1
    return "${rc}"
  }

  # Arm the native contract before attempting the bind. If the bind fails,
  # this marker deliberately survives so that the eventual Stop cannot fall
  # through to the legacy type/echoed-ID path.
  _count_native_start_candidates_unlocked() {
    local pending_file bindings_file
    pending_file="$(session_file "pending_agents.jsonl")"
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    _native_start_candidate_count=0
    [[ ! -L "${pending_file}" ]] \
      && { [[ ! -e "${pending_file}" ]] || [[ -f "${pending_file}" ]]; } \
      || return 1
    [[ -s "${pending_file}" ]] || return 0
    _native_start_candidate_count="$(jq -Rs \
      --arg type "${native_agent_type}" '
        [split("\n")[] | select(length > 0)
          | (try fromjson catch {})
          | select((.agent_type // "") == $type)
          | select((.native_agent_id // "") == "")
          | select((.review_dispatch_abandoned // false) != true)]
        | length
      ' "${pending_file}")" || return 1
    # A replayed platform ID is tracked even when its pending row has already
    # settled. Route it through the armed binder so duplicate-ID detection
    # fails closed rather than treating it as an unrelated untracked start.
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && jq -Rse --arg id "${native_agent_id}" '
          [split("\n")[] | select(length > 0)
              | (try fromjson catch {})
              | select((.native_agent_id // "") == $id)] | length > 0
        ' "${bindings_file}" >/dev/null 2>&1; then
      _native_start_candidate_count=1
    fi
  }
  _native_start_candidate_count=0
  if ! with_state_lock _count_native_start_candidates_unlocked; then
    log_anomaly "record-pending-agent" \
      "could not inspect native SubagentStart candidates for ${native_agent_type}"
    exit 1
  fi
  # A custom/untracked start with no matching PreToolUse:Agent row is outside
  # this harness ledger and must not arm the contract for tracked calls.
  if [[ "${_native_start_candidate_count}" -eq 0 ]]; then
    exit 0
  fi

  _arm_native_agent_tracking_unlocked() {
    _write_state_batch_unlocked "native_agent_id_tracking_version" "1"
  }
  if ! with_state_lock _arm_native_agent_tracking_unlocked; then
    log_anomaly "record-pending-agent" \
      "could not arm native SubagentStart causality for ${native_agent_type}"
    exit 1
  fi
  if ! with_state_lock _bind_native_agent_start_unlocked; then
    log_anomaly "record-pending-agent" \
      "native SubagentStart binding failed for ${native_agent_type}"
    exit 1
  fi
  exit 0
fi

tool_name="$(json_get '.tool_name')"
if [[ "${tool_name}" != "Agent" ]]; then
  exit 0
fi

subagent_type="$(json_get '.tool_input.subagent_type')"
if [[ -z "${subagent_type}" ]]; then
  subagent_type="general-purpose"
fi

description="$(json_get '.tool_input.description')"
description="$(truncate_chars 260 "${description}")"

# Council Phase 8 marks every role in one settled-revision review batch with
# the exact token `[review-batch]`. It may follow a required `[council:*]`
# prefix, so detect it as a whitespace-delimited token rather than requiring it
# at byte zero. The marker is only armed while Phase 8 state is active; ordinary
# agents cannot accidentally create a long-lived mutation freeze.
review_batch_requested=0
if [[ "${description}" =~ (^|[[:space:]])\[review-batch\]([[:space:]]|$) ]]; then
  review_batch_requested=1
fi

# Explicit recovery authorization for an abandoned same-role review. Current
# SubagentStart/Stop hooks bind a platform agent_id; the bounded description ID
# records that the operator intentionally replaced the old call. Echoing it
# before VERDICT is retained for pre-native in-flight compatibility.
review_rebind_id=""
if [[ "${description}" =~ (^|[[:space:]])\[review-rebind:([A-Za-z0-9][A-Za-z0-9._-]{0,63})\]([[:space:]]|$) ]]; then
  review_rebind_id="${BASH_REMATCH[2]}"
fi

# Council dispatches carry an explicit, machine-readable description marker.
# This lets outcome/eval consumers recognize a genuinely selected adaptive
# specialist without guessing from a `*-lens` prefix or counting panel size.
council_phase=""
case "${description}" in
  \[council:primary\]*) council_phase="primary" ;;
  \[council:gap-fill\]*) council_phase="gap-fill" ;;
  \[council:verification\]*) council_phase="verification" ;;
esac

# Runtime model contract. The prompt router stamps the resolver version and
# inputs for real ULW turns; older/resumed sessions and direct non-ULW Agent
# use fail open on their definition, preserving compatibility. Both this hook
# and the router call common.sh's resolve_agent_model — no parallel matrix.
_model_route_version="$(read_state "model_routing_resolver_version" 2>/dev/null || true)"
if [[ "$(read_state "workflow_mode" 2>/dev/null || true)" == "ultrawork" ]] \
    && [[ "${_model_route_version}" =~ ^(1|2)$ ]]; then
  # The router's turn-scoped context is authoritative. In particular, terse
  # Phase-8 approvals are Council-shaped because of their stateful handoff,
  # not because their prompt text independently matches Council evaluation.
  # Fall back to the machine-readable description marker only for partially
  # migrated/resumed v1 state that lacks a valid stored context.
  _model_route_context="$(read_state "model_routing_context" 2>/dev/null || true)"
  case "${_model_route_context}" in
    standard|council) ;;
    *)
      _model_route_context="standard"
      [[ -n "${council_phase}" ]] && _model_route_context="council"
      ;;
  esac
  _model_route_deep="$(read_state "model_routing_deep" 2>/dev/null || true)"
  _model_route_risk="$(read_state "model_routing_risk_tier" 2>/dev/null || true)"
  _model_route_deep="${_model_route_deep:-0}"
  _model_route_risk="${_model_route_risk:-low}"
  _model_route_tier="$(omc_effective_model_tier)"
  _model_route_overrides="${OMC_MODEL_OVERRIDES:-}"
  if [[ "${_model_route_version}" == "2" ]]; then
    # v2 snapshots mutable config at UserPromptSubmit. A config change made
    # later in the turn applies on the next prompt, never halfway between the
    # directive and the paid Agent call.
    _model_route_tier="$(omc_effective_model_tier \
      "$(read_state "model_routing_tier" 2>/dev/null || true)")"
    _model_route_overrides="$(omc_valid_model_overrides_summary \
      "$(read_state "model_routing_overrides" 2>/dev/null || true)")"
  fi
  _model_expected="$(resolve_agent_model "${subagent_type}" \
    "${_model_route_context}" "${_model_route_deep}" "${_model_route_risk}" \
    "${_model_route_tier}" "${_model_route_overrides}")"
  _model_requested="$(json_get '.tool_input.model')"
  _model_route_denial=""

  case "${_model_expected}" in
    inherit)
      if [[ -n "${_model_requested}" ]]; then
        _model_route_denial="omit the model parameter so this agent inherits the current session model"
      fi
      ;;
    opus|sonnet|haiku)
      if [[ "${_model_requested}" != "${_model_expected}" ]]; then
        _model_route_denial="pass model: \"${_model_expected}\""
      fi
      ;;
    definition)
      # Unknown/custom agents retain their own definition unless the user set
      # an explicit user/env override (which resolve_agent_model returns above).
      ;;
  esac

  if [[ -n "${_model_route_denial}" ]]; then
    record_gate_event "model-routing" "block" \
      "agent=${subagent_type}" \
      "tier=${_model_route_tier}" \
      "risk=${_model_route_risk}" \
      "context=${_model_route_context}" \
      "deep=${_model_route_deep}" \
      "expected=${_model_expected}" \
      "requested=${_model_requested:-omitted}"
    jq -nc --arg reason "[Model routing] ${subagent_type} resolved to ${_model_expected} under turn-scoped tier=${_model_route_tier}, risk=${_model_route_risk}, context=${_model_route_context}, deep=${_model_route_deep}. Retry once and ${_model_route_denial}. Explicit user/env model_overrides win; project-conf overrides are ignored. Inherit is represented by omitting the parameter, never by a temporary model name. These snapshotted inputs are the same ones rendered by the prompt directive; config changes apply on the next prompt." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi

# Uncertainty is a false economy when fixed-model implementation starts before
# a session-model deliberator has shaped the current objective. The router
# snapshots the uncertainty signal; a matching completion stamp is the only
# release. This gate lives after exact model validation so its retry guidance
# never competes with a model-parameter mismatch.
if [[ "$(read_state "model_routing_uncertainty" 2>/dev/null || true)" == "1" ]] \
    && omc_agent_is_fixed_implementation "${subagent_type}" \
    && [[ "${_model_expected:-}" =~ ^(opus|sonnet|haiku)$ ]]; then
  _uncertainty_objective_ts="$(read_state "review_cycle_prompt_ts" 2>/dev/null || true)"
  if [[ ! "${_uncertainty_objective_ts}" =~ ^[0-9]+$ ]]; then
    _uncertainty_objective_ts="$(read_state "last_user_prompt_ts" 2>/dev/null || true)"
  fi
  [[ "${_uncertainty_objective_ts}" =~ ^[0-9]+$ ]] || _uncertainty_objective_ts=0
  _uncertainty_cycle_id="$(read_state "review_cycle_id" 2>/dev/null || true)"
  [[ "${_uncertainty_cycle_id}" =~ ^[0-9]+$ ]] || _uncertainty_cycle_id=0
  _uncertainty_deliberator_objective_ts="$(read_state "model_uncertainty_deliberator_objective_ts" 2>/dev/null || true)"
  _uncertainty_deliberator_cycle_id="$(read_state "model_uncertainty_deliberator_cycle_id" 2>/dev/null || true)"
  if [[ "${_uncertainty_deliberator_objective_ts}" != "${_uncertainty_objective_ts}" \
      || "${_uncertainty_deliberator_cycle_id}" != "${_uncertainty_cycle_id}" ]]; then
    record_gate_event "model-routing" "block" \
      "agent=${subagent_type}" "reason=uncertainty-deliberation-required" \
      "objective_prompt_ts=${_uncertainty_objective_ts}" \
      "objective_cycle_id=${_uncertainty_cycle_id}" \
      "expected=${_model_expected}"
    jq -nc --arg reason "[Uncertainty deliberation] ${subagent_type} is fixed-model implementation for an objective classified tricky, intermittent, or root-cause-uncertain. Before paying for implementation retries, dispatch one bundled role declared to inherit the session model (for example quality-planner, metis, oracle, or a relevant inherit-declared reviewer), following the authoritative resolver for its tool call (normally omit model; an explicit user/env override still wins). Wait for that deliberator to return, then retry this implementation agent. The deliberator must shape this current objective; an older completion does not count." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi

# Append under lock so a concurrent SubagentStop cleanup does not race the write.
# Also increment the subagent dispatch counter for cost/budget visibility.
#
# v1.42.x stop-guard bypass closure (Bypass-Surface F-008):
# Separately track advisory-specialist dispatches. The
# advisory-no-findings stop-guard gate uses this counter to detect
# the "specialists dispatched but no findings recorded" pattern that
# forensics observed (10 sessions in 30d, 37 zero_capture events).
# The advisory set mirrors discovered_scope_capture_targets in
# common.sh — kept in lockstep there.
_is_advisory_specialist() {
  local _type="$1"
  case "${_type##*:}" in
    metis|briefing-analyst|oracle|abstraction-critic|editor-critic|rigor-reviewer) return 0 ;;
    security-lens|data-lens|product-lens|growth-lens|sre-lens|design-lens|visual-craft-lens) return 0 ;;
    *) return 1 ;;
  esac
}

_is_gate_reviewer() {
  local _type="${1##*:}"
  case "${_type}" in
    quality-reviewer|code-reviewer|editor-critic|excellence-reviewer|release-reviewer|metis|briefing-analyst|design-reviewer) return 0 ;;
    *) return 1 ;;
  esac
}

_is_planner_role() {
  case "${1##*:}" in
    quality-planner|prometheus) return 0 ;;
    *) return 1 ;;
  esac
}

_is_stateful_completion_role() {
  _is_gate_reviewer "$1" || _is_planner_role "$1"
}

# Both bundled planners publish the same current_plan.md and plan state. Treat
# them as one causal slot; reviewer roles remain isolated by their short name.
_stateful_identity_key() {
  local _type="${1##*:}"
  case "${_type}" in
    quality-planner|prometheus) printf 'planner' ;;
    *) printf '%s' "${_type}" ;;
  esac
}

_same_stateful_identity() {
  [[ "$(_stateful_identity_key "$1")" == "$(_stateful_identity_key "$2")" ]]
}

# Versioned reviewer-start rows let record-reviewer distinguish a current
# dispatch from an unversioned, pre-causality session. Keep this local to the
# two producer/consumer hooks: it is a persisted state/row contract, not a
# user-facing configuration surface.
REVIEW_DISPATCH_CAUSALITY_VERSION=1
REVIEW_DISPATCH_ABANDON_TTL_SECONDS=7200
COMPLETION_CLAIM_TTL_SECONDS=120
PENDING_AGENT_LIVE_CAP=64
PENDING_AGENT_TOMBSTONE_CAP=32

_dispatch_taint_file() {
  session_file "dispatch_tainted_identities.log"
}

_dispatch_rebind_registry_file() {
  session_file "dispatch_rebind_ids.log"
}

_dispatch_identity_is_tainted_unlocked() {
  local file rc=0
  file="$(_dispatch_taint_file)"
  [[ -e "${file}" ]] || return 1
  [[ -f "${file}" && -r "${file}" && ! -L "${file}" ]] || return 2
  grep -Fqx -- "$1" "${file}" || rc=$?
  (( rc == 0 )) && return 0
  (( rc == 1 )) && return 1
  return 2
}

_taint_dispatch_identity_unlocked() {
  local identity="$1" file temp
  [[ "${identity}" =~ ^[A-Za-z0-9_.:-]{1,128}$ ]] || return 1
  file="$(_dispatch_taint_file)"
  [[ ! -L "${file}" ]] \
    && { [[ ! -e "${file}" ]] || [[ -f "${file}" ]]; } || return 1
  grep -Fqx -- "${identity}" "${file}" 2>/dev/null && return 0
  temp="$(mktemp "${file}.XXXXXX")" || return 1
  [[ ! -f "${file}" ]] || cp "${file}" "${temp}" || {
    rm -f "${temp}"
    return 1
  }
  printf '%s\n' "${identity}" >>"${temp}" || {
    rm -f "${temp}"
    return 1
  }
  mv -f "${temp}" "${file}"
}

_register_dispatch_rebind_id_unlocked() {
  local id="$1" identity="$2" file temp
  [[ -n "${id}" && -n "${identity}" ]] || return 1
  file="$(_dispatch_rebind_registry_file)"
  [[ ! -L "${file}" ]] \
    && { [[ ! -e "${file}" ]] || [[ -f "${file}" ]]; } || return 1
  awk -F '\t' -v wanted="${id}" '$1 == wanted { found=1 }
    END { exit(found ? 0 : 1) }' "${file}" 2>/dev/null && return 1
  temp="$(mktemp "${file}.XXXXXX")" || return 1
  [[ ! -f "${file}" ]] || cp "${file}" "${temp}" || {
    rm -f "${temp}"
    return 1
  }
  printf '%s\t%s\n' "${id}" "${identity}" >>"${temp}" || {
    rm -f "${temp}"
    return 1
  }
  mv -f "${temp}" "${file}"
}

_validate_dispatch_registry_artifacts_unlocked() {
  local file
  for file in "$(_dispatch_taint_file)" "$(_dispatch_rebind_registry_file)"; do
    [[ ! -e "${file}" ]] && continue
    [[ -f "${file}" && -r "${file}" && ! -L "${file}" ]] || return 1
  done
}

_backfill_abandoned_dispatch_taints_unlocked() {
  local artifact ledger identity extracted
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl; do
    ledger="$(session_file "${artifact}")"
    [[ -s "${ledger}" ]] || continue
    extracted="$(mktemp "${ledger}.taints.XXXXXX")" || return 1
    if ! jq -Rr '
        fromjson?
        | select((.review_dispatch_abandoned // false) == true)
        | (.agent_type // empty)
        | select(type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      ' "${ledger}" 2>/dev/null | awk '!seen[$0]++' >"${extracted}"; then
      rm -f "${extracted}"
      return 1
    fi
    while IFS= read -r identity; do
      [[ -n "${identity}" ]] || continue
      if ! _taint_dispatch_identity_unlocked "${identity}"; then
        rm -f "${extracted}"
        return 1
      fi
    done <"${extracted}"
    rm -f "${extracted}"
  done
}

_gate_reviewer_start_revision() {
  local _type="${1##*:}" _revision=""
  case "${_type}" in
    quality-reviewer|code-reviewer)
      _revision="$(dimension_freshness_revision "code_quality")"
      ;;
    editor-critic)
      _revision="$(dimension_freshness_revision "prose")"
      ;;
    excellence-reviewer)
      _revision="$(dimension_freshness_revision "completeness")"
      ;;
    release-reviewer)
      _revision="$(read_state "edit_revision")"
      ;;
    metis)
      _revision="$(dimension_freshness_revision "stress_test")"
      ;;
    briefing-analyst)
      _revision="$(dimension_freshness_revision "traceability")"
      ;;
    design-reviewer)
      # This helper owns the canonical UI -> code migration fallback. Reading
      # last_ui_edit_revision directly and coercing absence to zero makes a
      # design review dispatched at code revision N look stale immediately.
      _revision="$(dimension_freshness_revision "design_quality")"
      ;;
    quality-planner|prometheus)
      _revision="$(read_state "plan_revision")"
      ;;
  esac
  [[ "${_revision}" =~ ^[0-9]+$ ]] || _revision=0
  printf '%s' "${_revision}"
}

_review_rebind_id_exists_unlocked() {
  local wanted="$1" artifact ledger line
  local registry
  registry="$(_dispatch_rebind_registry_file)"
  if [[ -f "${registry}" ]] \
      && awk -F '\t' -v wanted="${wanted}" '$1 == wanted { found=1 }
           END { exit(found ? 0 : 1) }' "${registry}" 2>/dev/null; then
    return 0
  fi
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl; do
    ledger="$(session_file "${artifact}")"
    [[ -s "${ledger}" ]] || continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      if jq -e --arg wanted "${wanted}" \
          '(.review_dispatch_id // "") == $wanted' \
          <<<"${line}" >/dev/null 2>&1; then
        return 0
      fi
    done <"${ledger}"
  done
  return 1
}

_set_review_rebind_suggestion_unlocked() {
  [[ -n "${_review_rebind_suggested_id:-}" ]] && return 0
  local _suggest_now _suggest_revision _base _candidate _suffix=1
  _suggest_now="$(now_epoch)"
  [[ "${_suggest_now}" =~ ^[0-9]+$ ]] || _suggest_now=0
  _suggest_revision="$(_gate_reviewer_start_revision "${subagent_type}")"
  [[ "${_suggest_revision}" =~ ^[0-9]+$ ]] || _suggest_revision=0
  _base="rebind-${_suggest_now}-r${_suggest_revision}"
  _candidate="${_base}"
  while _review_rebind_id_exists_unlocked "${_candidate}"; do
    _suffix=$((_suffix + 1))
    _candidate="${_base}-${_suffix}"
  done
  _review_rebind_suggested_id="${_candidate}"
}

# Fresh execution objectives retain bounded abandoned rows so late old
# SubagentStop events are suppressible. Reusing that exact runtime identity is
# therefore safe only with an echoed dispatch ID, regardless of whether the
# role is a reviewer, Council selection, or ordinary specialist.
_prepare_abandoned_identity_rebind_unlocked() {
  local pending_file line this_type now claim_id claim_ts claim_complete
  local has_abandoned=0 has_stale_claim=0 has_fresh_claim=0 temp updated
  local abandonment_reason
  pending_file="$(session_file "pending_agents.jsonl")"
  local _taint_lookup_rc=0
  _dispatch_identity_is_tainted_unlocked "${subagent_type}" \
    || _taint_lookup_rc=$?
  (( _taint_lookup_rc <= 1 )) || return 1
  if [[ "${_taint_lookup_rc}" -eq 0 ]]; then
    if [[ -z "${review_rebind_id}" ]]; then
      _dispatch_identity_denied=1
      _dispatch_generic_abandoned_rebind_required=1
      _set_review_rebind_suggestion_unlocked
      return 0
    fi
    if _review_rebind_id_exists_unlocked "${review_rebind_id}"; then
      _dispatch_identity_denied=1
      _dispatch_generic_abandoned_rebind_required=1
      _review_rebind_collision=1
      _set_review_rebind_suggestion_unlocked
      return 0
    fi
  fi
  [[ -s "${pending_file}" ]] || return 0
  now="$(now_epoch)"; [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    [[ "${this_type}" == "${subagent_type}" ]] || continue
    if [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${line}" 2>/dev/null || true)" == "true" ]]; then
      has_abandoned=1
      continue
    fi
    claim_id="$(jq -r '.completion_claim_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    claim_ts="$(jq -r '.completion_claim_ts // empty' \
      <<<"${line}" 2>/dev/null || true)"
    claim_complete="$(jq -r '.completion_claim_effects_complete // false' \
      <<<"${line}" 2>/dev/null || true)"
    if [[ -n "${claim_id}" && "${claim_ts}" =~ ^[0-9]+$ ]]; then
      if (( claim_ts >= now - COMPLETION_CLAIM_TTL_SECONDS )); then
        has_fresh_claim=1
      else
        has_stale_claim=1
      fi
    fi
  done <"${pending_file}"
  if [[ "${has_fresh_claim}" -eq 1 ]]; then
    _dispatch_identity_denied=1
    _review_completion_claimed=1
    return 0
  fi
  [[ "${has_abandoned}" -eq 1 || "${has_stale_claim}" -eq 1 ]] || return 0

  if [[ -z "${review_rebind_id}" ]]; then
    _dispatch_identity_denied=1
    _dispatch_generic_abandoned_rebind_required=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi
  if _review_rebind_id_exists_unlocked "${review_rebind_id}"; then
    _dispatch_identity_denied=1
    _dispatch_generic_abandoned_rebind_required=1
    _review_rebind_collision=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi

  if [[ "${has_stale_claim}" -eq 1 ]]; then
    temp="$(mktemp "${pending_file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      claim_id="$(jq -r '.completion_claim_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      claim_ts="$(jq -r '.completion_claim_ts // empty' \
        <<<"${line}" 2>/dev/null || true)"
      claim_complete="$(jq -r '.completion_claim_effects_complete // false' \
        <<<"${line}" 2>/dev/null || true)"
      if [[ "${this_type}" == "${subagent_type}" \
          && -n "${claim_id}" \
          && "${claim_ts}" =~ ^[0-9]+$ ]] \
          && (( claim_ts < now - COMPLETION_CLAIM_TTL_SECONDS )); then
        abandonment_reason="expired-completion-claim"
        [[ "${claim_complete}" == "true" ]] \
          && abandonment_reason="expired-completion-effects-complete"
        updated="$(jq -c --argjson now "${now}" \
          --arg abandonment_reason "${abandonment_reason}" '
          . + {
            review_dispatch_abandoned:true,
            review_dispatch_abandonment_reason:$abandonment_reason,
            review_dispatch_abandoned_ts:$now
          }
        ' <<<"${line}" 2>/dev/null || true)"
        [[ -n "${updated}" ]] && line="${updated}"
      fi
      printf '%s\n' "${line}" >>"${temp}"
    done <"${pending_file}"
    mv -f "${temp}" "${pending_file}"
  fi
}

# Prepare a same-role gate-reviewer retry without letting a late completion
# consume the newer start. Ordinary duplicates deny. A user-confirmed killed or
# interrupted call may be explicitly rebound immediately; stale rows require
# the same path when dispatching again after the automatic freeze TTL. The
# native ID selects the row; the echoed ID remains the legacy fallback.
_prepare_gate_reviewer_dispatch_unlocked() {
  local starts_file pending_file now cutoff line this_type row_ts row_id claim_id claim_ts
  local active=0 stale=0 id_collision=0 completion_claimed=0 tmp updated
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  now="$(now_epoch)"; [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  cutoff=$((now - REVIEW_DISPATCH_ABANDON_TTL_SECONDS))

  # A SubagentStop recorder first claims its pending row under this same lock.
  # Once claimed, even an explicit killed-call rebind must wait: the return has
  # already arrived and is being committed, so abandoning it would race accepted
  # summary/reviewer side effects.
  pending_file="$(session_file "pending_agents.jsonl")"
  if [[ -s "${pending_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      claim_id="$(jq -r '.completion_claim_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      claim_ts="$(jq -r '.completion_claim_ts // empty' \
        <<<"${line}" 2>/dev/null || true)"
      if ! _same_stateful_identity "${this_type}" "${subagent_type}"; then
        continue
      fi
      if [[ -n "${claim_id}" ]] \
          && [[ "${claim_ts}" =~ ^[0-9]+$ ]] \
          && (( claim_ts >= now - COMPLETION_CLAIM_TTL_SECONDS )) \
          && [[ "$(jq -r '.review_dispatch_abandoned // false' \
            <<<"${line}" 2>/dev/null || true)" != "true" ]]; then
        completion_claimed=1
        break
      fi
      [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${line}" 2>/dev/null || true)" != "true" ]] || continue
      row_id="$(jq -r '.review_dispatch_id // empty' <<<"${line}" 2>/dev/null || true)"
      [[ -n "${review_rebind_id}" && "${row_id}" == "${review_rebind_id}" ]] \
        && id_collision=1
      row_ts="$(jq -r '.ts // empty' <<<"${line}" 2>/dev/null || true)"
      if [[ "${row_ts}" =~ ^[0-9]+$ ]] && (( row_ts < cutoff )); then
        stale=1
      else
        active=1
      fi
    done <"${pending_file}"
  fi
  if [[ "${completion_claimed}" -eq 1 ]]; then
    _duplicate_gate_reviewer=1
    _review_completion_claimed=1
    return 0
  fi
  if [[ -s "${starts_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      if ! _same_stateful_identity "${this_type}" "${subagent_type}"; then
        continue
      fi
      [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${line}" 2>/dev/null || true)" != "true" ]] || continue
      row_id="$(jq -r '.review_dispatch_id // empty' <<<"${line}" 2>/dev/null || true)"
      [[ -n "${review_rebind_id}" && "${row_id}" == "${review_rebind_id}" ]] \
        && id_collision=1
      row_ts="$(jq -r '.ts // empty' <<<"${line}" 2>/dev/null || true)"
      if [[ "${row_ts}" =~ ^[0-9]+$ ]] && (( row_ts < cutoff )); then
        stale=1
      else
        # Missing/malformed timestamps fail closed; they cannot prove expiry.
        active=1
      fi
    done <"${starts_file}"
  fi

  if [[ "${id_collision}" -eq 1 ]]; then
    _duplicate_gate_reviewer=1
    _review_rebind_collision=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi
  if [[ "${active}" -ne 1 && "${stale}" -ne 1 ]]; then
    return 0
  fi
  if [[ -z "${review_rebind_id}" ]]; then
    _duplicate_gate_reviewer=1
    [[ "${stale}" -eq 1 && "${active}" -ne 1 ]] \
      && _review_rebind_required=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi

  if [[ -s "${starts_file}" ]]; then
    tmp="$(mktemp "${starts_file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      if _same_stateful_identity "${this_type}" "${subagent_type}"; then
        _taint_dispatch_identity_unlocked "${this_type}" || {
          rm -f "${tmp}"
          return 1
        }
        updated="$(jq -c '. + {review_dispatch_abandoned:true}' \
          <<<"${line}" 2>/dev/null || true)"
        [[ -n "${updated}" ]] && line="${updated}"
      fi
      printf '%s\n' "${line}" >>"${tmp}"
    done <"${starts_file}"
    mv "${tmp}" "${starts_file}"
  fi

  # pending_agents is consumed by record-subagent-summary independently of the
  # reviewer-only start ledger. Mirror the abandonment mark there so a late old
  # result cannot create summaries, scope, agent-first, design, uncertainty, or
  # Council side effects before its row is cleared.
  pending_file="$(session_file "pending_agents.jsonl")"
  if [[ -s "${pending_file}" ]]; then
    tmp="$(mktemp "${pending_file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      if _same_stateful_identity "${this_type}" "${subagent_type}"; then
        _taint_dispatch_identity_unlocked "${this_type}" || {
          rm -f "${tmp}"
          return 1
        }
        updated="$(jq -c '. + {review_dispatch_abandoned:true}' \
          <<<"${line}" 2>/dev/null || true)"
        [[ -n "${updated}" ]] && line="${updated}"
      fi
      printf '%s\n' "${line}" >>"${tmp}"
    done <"${pending_file}"
    mv "${tmp}" "${pending_file}"
  fi
}

# Semantic specialists in a marked frozen batch use the same exact-identity
# admission rule. Exact namespaced identity (not a permanent role list)
# controls this queue. A stale row may be rebound explicitly; native summary
# cleanup then removes only the bound row even if the abandoned call returns.
_prepare_frozen_batch_dispatch_unlocked() {
  local pending_file now cutoff line this_type batch_id row_ts row_id claim_id claim_ts
  local active=0 stale=0 id_collision=0 completion_claimed=0 tmp updated
  [[ "${review_batch_requested}" -eq 1 ]] \
    && [[ "$(read_state "council_phase8_active")" == "1" ]] || return 0
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" ]] || return 0
  now="$(now_epoch)"; [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  cutoff=$((now - REVIEW_DISPATCH_ABANDON_TTL_SECONDS))

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    [[ "${this_type}" == "${subagent_type}" ]] || continue
    batch_id="$(jq -r '.review_batch_id // empty' <<<"${line}" 2>/dev/null || true)"
    [[ -n "${batch_id}" ]] || continue
    claim_id="$(jq -r '.completion_claim_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    claim_ts="$(jq -r '.completion_claim_ts // empty' \
      <<<"${line}" 2>/dev/null || true)"
    if [[ -n "${claim_id}" ]] \
        && [[ "${claim_ts}" =~ ^[0-9]+$ ]] \
        && (( claim_ts >= now - COMPLETION_CLAIM_TTL_SECONDS )) \
        && [[ "$(jq -r '.review_dispatch_abandoned // false' \
          <<<"${line}" 2>/dev/null || true)" != "true" ]]; then
      completion_claimed=1
    fi
    row_id="$(jq -r '.review_dispatch_id // empty' <<<"${line}" 2>/dev/null || true)"
    [[ -n "${review_rebind_id}" && "${row_id}" == "${review_rebind_id}" ]] \
      && id_collision=1
    row_ts="$(jq -r '.ts // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ "${row_ts}" =~ ^[0-9]+$ ]] && (( row_ts < cutoff )); then
      stale=1
    else
      active=1
    fi
  done <"${pending_file}"

  if [[ "${completion_claimed}" -eq 1 ]]; then
    _duplicate_frozen_batch_role=1
    _review_completion_claimed=1
    return 0
  fi

  if [[ "${id_collision}" -eq 1 ]]; then
    _duplicate_frozen_batch_role=1
    _review_rebind_collision=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi
  if [[ "${active}" -ne 1 && "${stale}" -ne 1 ]]; then
    return 0
  fi
  if [[ -z "${review_rebind_id}" ]]; then
    _duplicate_frozen_batch_role=1
    [[ "${stale}" -eq 1 && "${active}" -ne 1 ]] \
      && _review_rebind_required=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi

  tmp="$(mktemp "${pending_file}.XXXXXX")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    batch_id="$(jq -r '.review_batch_id // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ "${this_type}" == "${subagent_type}" && -n "${batch_id}" ]]; then
      updated="$(jq -c '. + {review_dispatch_abandoned:true}' \
        <<<"${line}" 2>/dev/null || true)"
      [[ -n "${updated}" ]] && line="${updated}"
    fi
    printf '%s\n' "${line}" >>"${tmp}"
  done <"${pending_file}"
  mv "${tmp}" "${pending_file}"
}

# Council primary/gap/verification calls are provenance-bound even when they
# are not Phase-8 `[review-batch]` roles. Reusing an exact identity while an old
# or prior-objective return can still arrive therefore requires the same echoed
# dispatch ID. Verification additionally supersedes (never deletes) its durable
# dispatch audit row so a confirmed-kill retry keeps one logical verifier slot.
_prepare_council_identity_rebind_unlocked() {
  local pending_file line this_type row_id claim_id claim_ts now
  local current_ts current_revision row_phase row_objective_ts row_objective_revision
  local current_cycle_id row_cycle_id
  local row_abandoned row_abandonment_reason row_effects_complete
  local matching=0 active=0 abandoned=0 collision=0 claimed=0 current_attempt=0
  [[ -n "${council_phase}" ]] || return 0
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" ]] || return 0
  now="$(now_epoch)"; [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  current_ts="$(read_state "last_user_prompt_ts")"
  [[ "${current_ts}" =~ ^[0-9]+$ ]] || current_ts=0
  current_revision="$(read_state "prompt_revision")"
  [[ "${current_revision}" =~ ^[0-9]+$ ]] || current_revision=0
  current_cycle_id="$(read_state "review_cycle_id")"
  [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    [[ "${this_type}" == "${subagent_type}" ]] || continue
    [[ "$(jq -r '.purpose // empty' <<<"${line}" 2>/dev/null || true)" == "council" ]] \
      || continue
    matching=1
    row_phase="$(jq -r '.council_phase // empty' <<<"${line}" 2>/dev/null || true)"
    row_objective_ts="$(jq -r '.council_objective_prompt_ts // -1' \
      <<<"${line}" 2>/dev/null || true)"
    row_objective_revision="$(jq -r '.council_objective_prompt_revision // -1' \
      <<<"${line}" 2>/dev/null || true)"
    row_cycle_id="$(jq -r '.objective_cycle_id // 0' \
      <<<"${line}" 2>/dev/null || true)"
    row_abandoned="$(jq -r '.review_dispatch_abandoned // false' \
      <<<"${line}" 2>/dev/null || true)"
    row_abandonment_reason="$(jq -r '.review_dispatch_abandonment_reason // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_effects_complete="$(jq -r '.completion_claim_effects_complete // false' \
      <<<"${line}" 2>/dev/null || true)"
    if [[ "${row_phase}" == "${council_phase}" \
        && "${row_objective_ts}" == "${current_ts}" \
        && "${row_objective_revision}" == "${current_revision}" ]] \
        && { (( current_cycle_id == 0 )) \
          || [[ "${row_cycle_id}" == "${current_cycle_id}" ]]; } \
        && { [[ "${row_abandoned}" != "true" ]] \
          || [[ "${row_abandonment_reason}" == "expired-completion-claim" ]]; } \
        && [[ "${row_effects_complete}" != "true" ]]; then
      current_attempt=1
    fi
    row_id="$(jq -r '.review_dispatch_id // empty' <<<"${line}" 2>/dev/null || true)"
    [[ -n "${review_rebind_id}" && "${row_id}" == "${review_rebind_id}" ]] \
      && collision=1
    claim_id="$(jq -r '.completion_claim_id // empty' <<<"${line}" 2>/dev/null || true)"
    claim_ts="$(jq -r '.completion_claim_ts // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ -n "${claim_id}" && "${claim_ts}" =~ ^[0-9]+$ ]] \
        && (( claim_ts >= now - COMPLETION_CLAIM_TTL_SECONDS )) \
        && [[ "$(jq -r '.review_dispatch_abandoned // false' \
          <<<"${line}" 2>/dev/null || true)" != "true" ]]; then
      claimed=1
    elif [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${line}" 2>/dev/null || true)" == "true" ]]; then
      abandoned=1
    else
      active=1
    fi
  done <"${pending_file}"

  [[ "${matching}" -eq 1 ]] || return 0
  if [[ "${claimed}" -eq 1 ]]; then
    _dispatch_identity_denied=1
    _review_completion_claimed=1
    return 0
  fi
  if [[ "${collision}" -eq 1 ]]; then
    _dispatch_identity_denied=1
    _review_rebind_collision=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi
  if [[ -z "${review_rebind_id}" ]]; then
    _dispatch_identity_denied=1
    if [[ "${active}" -eq 1 ]]; then
      _dispatch_council_active_duplicate=1
    else
      _dispatch_abandoned_identity_rebind_required=1
    fi
    _set_review_rebind_suggestion_unlocked
    return 0
  fi

  # This is only a prepared transition. Council lifecycle/selection
  # authorization must succeed before either ledger is mutated; otherwise an
  # invalid wrong-phase or unlisted retry could abandon legitimate live work.
  _council_identity_rebind_ready=1
  _council_current_attempt_rebind_ready="${current_attempt}"
}

_apply_council_identity_rebind_unlocked() {
  local pending_file dispatches_file line this_type row_phase
  local row_objective_ts row_objective_revision now current_ts current_revision
  local current_cycle_id row_cycle_id
  local tmp updated
  [[ "${_council_identity_rebind_ready}" -eq 1 ]] || return 0
  now="$(now_epoch)"; [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  current_ts="$(read_state "last_user_prompt_ts")"
  [[ "${current_ts}" =~ ^[0-9]+$ ]] || current_ts=0
  current_revision="$(read_state "prompt_revision")"
  [[ "${current_revision}" =~ ^[0-9]+$ ]] || current_revision=0
  current_cycle_id="$(read_state "review_cycle_id")"
  [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0

  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" ]] || return 0
  tmp="$(mktemp "${pending_file}.XXXXXX")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ "${this_type}" == "${subagent_type}" ]] \
        && [[ "$(jq -r '.purpose // empty' <<<"${line}" 2>/dev/null || true)" == "council" ]]; then
      updated="$(jq -c --argjson now "${now}" '
        .review_dispatch_abandoned = true
        | .review_dispatch_abandonment_reason =
            (.review_dispatch_abandonment_reason // "explicit-rebind")
        | .review_dispatch_abandoned_ts =
            (.review_dispatch_abandoned_ts // $now)
      ' <<<"${line}" 2>/dev/null || true)"
      [[ -n "${updated}" ]] && line="${updated}"
    fi
    printf '%s\n' "${line}" >>"${tmp}"
  done <"${pending_file}"
  mv "${tmp}" "${pending_file}"

  # Preserve old dispatch audit rows but remove superseded attempts from the
  # logical verification identity/count calculation.
  dispatches_file="$(session_file "council_dispatches.jsonl")"
  if [[ "${_council_current_attempt_rebind_ready}" -eq 1 \
      && -s "${dispatches_file}" ]]; then
    tmp="$(mktemp "${dispatches_file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      row_phase="$(jq -r '.council_phase // empty' <<<"${line}" 2>/dev/null || true)"
      row_objective_ts="$(jq -r '.council_objective_prompt_ts // -1' \
        <<<"${line}" 2>/dev/null || true)"
      row_objective_revision="$(jq -r '.council_objective_prompt_revision // -1' \
        <<<"${line}" 2>/dev/null || true)"
      row_cycle_id="$(jq -r '.objective_cycle_id // 0' \
        <<<"${line}" 2>/dev/null || true)"
      if [[ "${this_type}" == "${subagent_type}" \
          && "${row_phase}" == "${council_phase}" \
          && "${row_objective_ts}" == "${current_ts}" \
          && "${row_objective_revision}" == "${current_revision}" ]] \
          && { (( current_cycle_id == 0 )) \
            || [[ "${row_cycle_id}" == "${current_cycle_id}" ]]; } \
          && [[ "$(jq -r '.review_dispatch_superseded // false' \
            <<<"${line}" 2>/dev/null || true)" != "true" ]]; then
        updated="$(jq -c \
          --arg replacement "${review_rebind_id}" \
          --argjson now "${now}" '
            . + {
              review_dispatch_superseded:true,
              superseded_by_review_dispatch_id:$replacement,
              review_dispatch_superseded_ts:$now
            }
          ' <<<"${line}" 2>/dev/null || true)"
        [[ -n "${updated}" ]] && line="${updated}"
      fi
      printf '%s\n' "${line}" >>"${tmp}"
    done <"${dispatches_file}"
    mv "${tmp}" "${dispatches_file}"
  fi
}

# Resolve one Council selection while holding the session lock. Namespaced
# ledger identities are exact: `alpha:auditor` can never authorize
# `beta:auditor`. A legacy/installed unnamespaced selection may bind to a
# namespaced runtime identity once; `resolved_agent` makes that binding
# durable so another namespace with the same short name cannot reuse it.
_authorize_council_dispatch_unlocked() {
  local ledger current_ts current_revision current_cycle_id selection selection_agent resolved
  local generation lifecycle tmp dispatches_file verification_count duplicate_verifier
  local duplicate_selection
  ledger="$(session_file "council_coverage.json")"
  current_ts="$(read_state "last_user_prompt_ts")"
  [[ "${current_ts}" =~ ^[0-9]+$ ]] || current_ts=0
  current_revision="$(read_state "prompt_revision")"
  [[ "${current_revision}" =~ ^[0-9]+$ ]] || current_revision=0
  current_cycle_id="$(read_state "review_cycle_id")"
  [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0

  if [[ ! -f "${ledger}" ]] || ! jq -e \
      --argjson objective_ts "${current_ts}" \
      --argjson prompt_revision "${current_revision}" \
      --argjson cycle_id "${current_cycle_id}" '
        (.objective_prompt_ts // -1) == $objective_ts
        and (.objective_prompt_revision // -1) == $prompt_revision
        and ($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
      ' "${ledger}" >/dev/null 2>&1; then
    _council_coverage_denied=1
    _council_coverage_reason="missing-or-stale-ledger"
    return 0
  fi

  generation="$(jq -r '.generation // 0' "${ledger}" 2>/dev/null || true)"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation=0
  lifecycle="$(jq -r '.lifecycle // empty' "${ledger}" 2>/dev/null || true)"
  if [[ "${council_phase}" == "verification" ]]; then
    # Verification is optional, but when used it is a post-reconciliation
    # round. Bind every verifier to the current finalized ledger generation;
    # do not let an ad-hoc tag create provenance before primary/gap work has
    # been reconciled or after the assessment has already been completed.
    if (( generation < 2 )) \
        || [[ "${lifecycle}" != "primary-complete" \
          && "${lifecycle}" != "gap-fill-complete" ]] \
        || ! jq -e \
          --arg lifecycle "${lifecycle}" '
            (.reconciliation.status // "") == $lifecycle
            and (has("completion") | not)
          ' "${ledger}" >/dev/null 2>&1; then
      _council_coverage_denied=1
      _council_coverage_reason="verification-before-final-reconciliation"
      return 0
    fi

    # The protocol permits up to three independent, load-bearing checks. The
    # durable dispatch log is used instead of the pending queue so a completed
    # verifier still consumes its slot and cannot be dispatched twice under
    # the same exact runtime identity.
    dispatches_file="$(session_file "council_dispatches.jsonl")"
    verification_count=0
    duplicate_verifier="false"
    if [[ -s "${dispatches_file}" ]]; then
      if ! verification_count="$(jq -s -r \
          --argjson objective_ts "${current_ts}" \
          --argjson prompt_revision "${current_revision}" \
          --argjson cycle_id "${current_cycle_id}" '
            [ .[]
              | select((.purpose // "") == "council")
              | select((.council_phase // "") == "verification")
              | select((.council_objective_prompt_ts // -1) == $objective_ts)
              | select((.council_objective_prompt_revision // -1) == $prompt_revision)
              | select($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
              | select((.review_dispatch_superseded // false) != true)
            ] | length
          ' "${dispatches_file}" 2>/dev/null)"; then
        _council_coverage_denied=1
        _council_coverage_reason="invalid-dispatch-provenance"
        return 0
      fi
      if ! duplicate_verifier="$(jq -s -r \
          --arg full "${subagent_type}" \
          --argjson objective_ts "${current_ts}" \
          --argjson prompt_revision "${current_revision}" \
          --argjson cycle_id "${current_cycle_id}" '
            any(.[]?;
              (.purpose // "") == "council"
              and (.council_phase // "") == "verification"
              and (.agent_type // "") == $full
              and (.council_objective_prompt_ts // -1) == $objective_ts
              and (.council_objective_prompt_revision // -1) == $prompt_revision
              and ($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
              and (.review_dispatch_superseded // false) != true
            )
          ' "${dispatches_file}" 2>/dev/null)"; then
        _council_coverage_denied=1
        _council_coverage_reason="invalid-dispatch-provenance"
        return 0
      fi
    fi
    [[ "${verification_count}" =~ ^[0-9]+$ ]] || verification_count=0
    # An explicitly ID-bound replacement consumes the same logical verifier
    # slot as the superseded attempt. Preparation has not mutated either
    # ledger yet; account for the one matching live audit row transactionally,
    # then apply supersession only after all lifecycle authorization succeeds.
    if [[ "${_council_current_attempt_rebind_ready}" -eq 1 \
        && "${duplicate_verifier}" == "true" ]]; then
      duplicate_verifier="false"
      (( verification_count > 0 )) && verification_count=$((verification_count - 1))
    fi
    if [[ "${duplicate_verifier}" == "true" ]]; then
      _council_coverage_denied=1
      _council_coverage_reason="duplicate-verifier-identity"
      return 0
    fi
    if (( verification_count >= 3 )); then
      _council_coverage_denied=1
      _council_coverage_reason="verification-cap-reached"
      return 0
    fi

    council_selection_agent="${subagent_type}"
    council_objective_ts="${current_ts}"
    council_prompt_revision="${current_revision}"
    council_ledger_generation="${generation}"
    return 0
  elif [[ "${council_phase}" == "primary" ]]; then
    if (( generation != 1 )) || [[ "${lifecycle}" != "primary" ]]; then
      _council_coverage_denied=1
      _council_coverage_reason="primary-round-closed"
      return 0
    fi
  elif (( generation < 2 )) || [[ "${lifecycle}" != "gap-fill-required" ]]; then
    _council_coverage_denied=1
    _council_coverage_reason="gap-fill-before-reconciliation"
    return 0
  fi

  selection="$(jq -c \
    --arg full "${subagent_type}" \
    --arg short "${subagent_type##*:}" \
    --arg phase "${council_phase}" '
      [.selections[]?
        | select((.phase // "") == $phase and (.agent // "") == $full)] as $exact
      | if ($exact | length) == 1 then $exact[0]
        elif ($exact | length) > 1 then null
        else
          [.selections[]?
            | select((.phase // "") == $phase)
            | select(((.agent // "") | contains(":") | not))
            | select((.agent // "") == $short)] as $legacy
          | if ($legacy | length) == 1 then $legacy[0] else null end
        end
    ' "${ledger}" 2>/dev/null || true)"
  if [[ -z "${selection}" || "${selection}" == "null" ]]; then
    _council_coverage_denied=1
    _council_coverage_reason="unlisted-exact-agent"
    return 0
  fi

  selection_agent="$(jq -r '.agent // empty' <<<"${selection}" 2>/dev/null || true)"
  resolved="$(jq -r '.resolved_agent // empty' <<<"${selection}" 2>/dev/null || true)"
  if [[ -n "${resolved}" && "${resolved}" != "${subagent_type}" ]]; then
    _council_coverage_denied=1
    _council_coverage_reason="selection-bound-to-${resolved}"
    return 0
  fi

  if [[ -z "${resolved}" ]]; then
    tmp="${ledger}.tmp.$$"
    if ! jq \
        --arg selected "${selection_agent}" \
        --arg phase "${council_phase}" \
        --arg resolved "${subagent_type}" '
          .selections |= map(
            if .agent == $selected and .phase == $phase
            then .resolved_agent = $resolved
            else . end
          )
        ' "${ledger}" >"${tmp}"; then
      rm -f "${tmp}"
      _council_coverage_denied=1
      _council_coverage_reason="ledger-bind-failed"
      return 0
    fi
    mv -f "${tmp}" "${ledger}"
  fi

  # A selected primary/gap specialist is one logical dispatch per objective.
  # The durable audit prevents a completed call from being paid for again. An
  # explicit replacement is allowed only while a live current pending attempt
  # proves which audit row will be superseded after authorization succeeds.
  dispatches_file="$(session_file "council_dispatches.jsonl")"
  if [[ -s "${dispatches_file}" ]]; then
    if ! duplicate_selection="$(jq -s -r \
        --arg full "${subagent_type}" \
        --arg phase "${council_phase}" \
        --argjson objective_ts "${current_ts}" \
        --argjson prompt_revision "${current_revision}" \
        --argjson cycle_id "${current_cycle_id}" '
          any(.[]?;
            (.purpose // "") == "council"
            and (.council_phase // "") == $phase
            and (.agent_type // "") == $full
            and (.council_objective_prompt_ts // -1) == $objective_ts
            and (.council_objective_prompt_revision // -1) == $prompt_revision
            and ($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
            and (.review_dispatch_superseded // false) != true
          )
        ' "${dispatches_file}" 2>/dev/null)"; then
      _council_coverage_denied=1
      _council_coverage_reason="invalid-dispatch-provenance"
      return 0
    fi
    if [[ "${duplicate_selection}" == "true" \
        && "${_council_current_attempt_rebind_ready}" -ne 1 ]]; then
      _council_coverage_denied=1
      _council_coverage_reason="duplicate-council-selection-dispatch"
      return 0
    fi
  fi

  council_selection_agent="${selection_agent}"
  council_objective_ts="${current_ts}"
  council_prompt_revision="${current_revision}"
  council_ledger_generation="${generation}"
}

_pending_identity_is_ambiguous_unlocked() {
  local pending_file
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" ]] || return 1

  # PreToolUse does not yet know the native agent_id that SubagentStart will
  # bind. Keep exactly one active row per literal identity so that bind is
  # unique and legacy clients cannot FIFO-swap two out-of-order completions.
  # Distinct specialist/reviewer identities remain fully parallel.
  jq -s -e \
    --arg full "${subagent_type}" '
      any(.[]?;
        (.agent_type // "") == $full
        and (.review_dispatch_abandoned // false) != true
      )
    ' "${pending_file}" >/dev/null 2>&1
}

# An ordinary call can be confirmed killed before Claude Code emits a
# SubagentStop. Its live row must remain until an explicit replacement proves
# the operator intended to abandon that exact identity; otherwise a transient
# duplicate prompt could silently pay for two calls. The fresh rebind token is
# authorization only on native-hook clients (SubagentStart supplies the causal
# ID); legacy clients also echo it in the final result as a compatibility path.
_prepare_active_ordinary_identity_rebind_unlocked() {
  local pending_file line this_type claim_id claim_ts now
  local active=0 claimed=0 temp updated

  # Reviewers/planners, Council calls, and Phase-8 batch roles have richer
  # ledgers and are prepared by their dedicated helpers above.
  _is_stateful_completion_role "${subagent_type}" && return 0
  [[ -z "${council_phase}" ]] || return 0
  if [[ "${review_batch_requested}" -eq 1 ]] \
      && [[ "$(read_state "council_phase8_active")" == "1" ]]; then
    return 0
  fi

  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" ]] || return 0
  now="$(now_epoch)"; [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    [[ "${this_type}" == "${subagent_type}" ]] || continue
    [[ "$(jq -r '.review_dispatch_abandoned // false' \
      <<<"${line}" 2>/dev/null || true)" != "true" ]] || continue
    active=$((active + 1))
    claim_id="$(jq -r '.completion_claim_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    claim_ts="$(jq -r '.completion_claim_ts // empty' \
      <<<"${line}" 2>/dev/null || true)"
    if [[ -n "${claim_id}" && "${claim_ts}" =~ ^[0-9]+$ ]] \
        && (( claim_ts >= now - COMPLETION_CLAIM_TTL_SECONDS )); then
      claimed=1
    fi
  done <"${pending_file}"
  [[ "${active}" -gt 0 ]] || return 0

  if [[ "${claimed}" -eq 1 ]]; then
    _dispatch_identity_denied=1
    _review_completion_claimed=1
    return 0
  fi
  # More than one live legacy row cannot be mapped to one confirmation. Keep
  # every row intact and fail closed instead of guessing which call was killed.
  if [[ "${active}" -ne 1 ]]; then
    _dispatch_identity_denied=1
    _dispatch_active_exact_duplicate=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi
  if [[ -z "${review_rebind_id}" ]]; then
    _dispatch_identity_denied=1
    _dispatch_active_exact_duplicate=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi
  if _review_rebind_id_exists_unlocked "${review_rebind_id}"; then
    _dispatch_identity_denied=1
    _dispatch_generic_abandoned_rebind_required=1
    _review_rebind_collision=1
    _set_review_rebind_suggestion_unlocked
    return 0
  fi

  _taint_dispatch_identity_unlocked "${subagent_type}" || return 1
  temp="$(mktemp "${pending_file}.XXXXXX")" || return 1
  local replaced=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ "${replaced}" -eq 0 && "${this_type}" == "${subagent_type}" \
        && "$(jq -r '.review_dispatch_abandoned // false' \
          <<<"${line}" 2>/dev/null || true)" != "true" ]]; then
      updated="$(jq -c --argjson now "${now}" '
        . + {
          review_dispatch_abandoned:true,
          review_dispatch_abandonment_reason:"confirmed-interrupted-rebind",
          review_dispatch_abandoned_ts:$now
        }
      ' <<<"${line}" 2>/dev/null || true)"
      if [[ -z "${updated}" ]]; then
        rm -f "${temp}"
        return 1
      fi
      line="${updated}"
      replaced=1
    fi
    printf '%s\n' "${line}" >>"${temp}" || {
      rm -f "${temp}"
      return 1
    }
  done <"${pending_file}"
  if [[ "${replaced}" -ne 1 ]] || ! mv -f "${temp}" "${pending_file}"; then
    rm -f "${temp}"
    return 1
  fi
}

_pending_live_cap_reached_unlocked() {
  local pending_file
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" ]] || return 1
  # One slurp/parse keeps dispatch admission O(n). Malformed rows count as
  # live: unknown provenance is safer to deny than to evict before a paid
  # completion arrives.
  jq -Rse --argjson cap "${PENDING_AGENT_LIVE_CAP}" '
    [split("\n")[]
      | select(length > 0)
      | select((try (fromjson | (.review_dispatch_abandoned // false))
                catch false) != true)]
    | length >= $cap
  ' "${pending_file}" >/dev/null 2>&1
}

_append_dispatch_ledger_preserving_live_unlocked() {
  local artifact="$1" entry="$2" tombstone_cap="$3"
  local pending_file source temp
  pending_file="$(session_file "${artifact}")"
  [[ ! -L "${pending_file}" ]] \
    && { [[ ! -e "${pending_file}" ]] || [[ -f "${pending_file}" ]]; } \
    || return 1
  source="${pending_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  temp="$(mktemp "${pending_file}.XXXXXX")" || return 1
  # Preserve every live or malformed row. Only the oldest explicit abandoned
  # tombstones are eligible for rotation, so large fan-out cannot discard an
  # in-flight completion's causal binding. Parse the ledger exactly once.
  if ! jq -Rsr \
      --arg entry "${entry}" \
      --argjson cap "${tombstone_cap}" '
        (split("\n") | map(select(length > 0)) + [$entry]) as $lines
        | [$lines | to_entries[]
            | select((try (.value | fromjson
                            | (.review_dispatch_abandoned // false))
                      catch false) == true)
            | .key] as $tombstones
        | (($tombstones | length) - $cap) as $excess
        | ($tombstones[0:(if $excess > 0 then $excess else 0 end)]) as $drop
        | $lines | to_entries[] | . as $item
        | select(($drop | index($item.key)) == null)
        | $item.value
      ' "${source}" >"${temp}"; then
    rm -f "${temp}"
    return 1
  fi
  if ! mv -f "${temp}" "${pending_file}"; then
    rm -f "${temp}"
    return 1
  fi
}

_append_council_dispatch_audit_unlocked() {
  local entry="$1" cycle_id="$2" ledger source output
  ledger="$(session_file "council_dispatches.jsonl")"
  [[ ! -L "${ledger}" ]] \
    && { [[ ! -e "${ledger}" ]] || [[ -f "${ledger}" ]]; } || return 1
  source="${ledger}"
  [[ -f "${source}" ]] || source="/dev/null"
  output="$(mktemp "${ledger}.XXXXXX")" || return 1
  # Keep every row for the active objective and only the newest 32 historical
  # rows. Invalid audit rows are historical, preserving the useful live set
  # while keeping a corrupt artifact bounded.
  if ! jq -Rsr \
      --arg entry "${entry}" \
      --argjson objective_ts "${council_objective_ts}" \
      --argjson prompt_revision "${council_prompt_revision}" \
      --argjson cycle_id "${cycle_id}" '
        def historical($raw):
          (try ($raw | fromjson) catch null) as $row
          | (($row | type) != "object")
            or (($row.council_objective_prompt_ts // -1) != $objective_ts)
            or (($row.council_objective_prompt_revision // -1) != $prompt_revision)
            or ($cycle_id > 0 and ($row.objective_cycle_id // -1) != $cycle_id);
        (split("\n") | map(select(length > 0)) + [$entry]) as $lines
        | [$lines | to_entries[]
            | select(historical(.value)) | .key] as $history
        | (($history | length) - 32) as $excess
        | ($history[0:(if $excess > 0 then $excess else 0 end)]) as $drop
        | $lines | to_entries[] | . as $item
        | select(($drop | index($item.key)) == null)
        | $item.value
      ' "${source}" >"${output}"; then
    rm -f "${output}"
    return 1
  fi
  if ! mv -f "${output}" "${ledger}"; then
    rm -f "${output}"
    return 1
  fi
}

_append_pending() {
  local _edit_rev _code_rev _doc_rev _bash_rev _ui_rev _plan_rev pending_entry
  local _is_stateful=0 _review_revision=0
  local _review_batch_id="" _objective_prompt_ts=0 _objective_prompt_revision=0
  local _objective_cycle_id=0 _enforcement_generation="migration"
  local _lifecycle_dispatch_id=""
  local _quality_contract_bound=0 _quality_contract_id="" _quality_contract_revision=0
  local _quality_contract_json=""

  # Recheck per-session authority inside the lock so a PreToolUse hook that
  # was already waiting cannot recreate a row after /ulw-off or Stop closed
  # this session while another ULW session keeps the global fast-path latch.
  if ! is_ultrawork_mode; then
    return 0
  fi
  _validate_dispatch_registry_artifacts_unlocked || return 1
  # Finish any cleanup transaction whose durable ignored outcome was committed
  # before its producer died. Admission must see the converged ledgers, not
  # deny a mandatory replacement on a row already retired in durable intent.
  omc_reconcile_all_ignored_completion_cleanups_unlocked || return 1
  _backfill_abandoned_dispatch_taints_unlocked || return 1
  # Once an identity has ever been abandoned in this session, an arbitrarily
  # late no-ID result remains possible even after bounded tombstones rotate.
  # Permanently require a fresh echoed ID for every later dispatch of that
  # exact identity; accepted IDs are themselves never reusable.
  local _taint_lookup_rc=0
  _dispatch_identity_is_tainted_unlocked "${subagent_type}" \
    || _taint_lookup_rc=$?
  (( _taint_lookup_rc <= 1 )) || return 1
  if [[ "${_taint_lookup_rc}" -eq 0 ]]; then
    if [[ -z "${review_rebind_id}" ]]; then
      _dispatch_identity_denied=1
      _dispatch_generic_abandoned_rebind_required=1
      _set_review_rebind_suggestion_unlocked
      return 0
    fi
    if _review_rebind_id_exists_unlocked "${review_rebind_id}"; then
      _dispatch_identity_denied=1
      _dispatch_generic_abandoned_rebind_required=1
      _review_rebind_collision=1
      _set_review_rebind_suggestion_unlocked
      return 0
    fi
  fi
  if [[ -n "${council_phase}" ]]; then
    # Resolve active/abandoned exact-identity collisions before Council
    # authorization mutates a legacy selection binding or spends a verifier
    # slot. A confirmed replacement supersedes the prior audit attempt, then
    # authorization evaluates only the one live logical dispatch.
    _prepare_council_identity_rebind_unlocked
    if [[ "${_dispatch_identity_denied}" -eq 1 ]]; then
      return 0
    fi
    _authorize_council_dispatch_unlocked
    if [[ "${_council_coverage_denied}" -eq 1 ]]; then
      return 0
    fi
    _apply_council_identity_rebind_unlocked
  else
    # Council uses its own prepare -> authorize -> apply transaction below;
    # generic recovery must never mutate a Council row before wrong-phase or
    # unlisted authorization has had a chance to deny without side effects.
    _prepare_abandoned_identity_rebind_unlocked
    if [[ "${_dispatch_identity_denied}" -eq 1 ]]; then
      return 0
    fi
  fi

  # PreToolUse does not yet have the platform agent_id. Active same-role
  # review-batch work is never duplicated. Stale rows require explicit recovery;
  # the preparation helpers mark the old row abandoned before appending the
  # retry, all under this same session lock.
  _prepare_frozen_batch_dispatch_unlocked
  if [[ "${_duplicate_frozen_batch_role}" -eq 1 ]]; then
    return 0
  fi

  if _is_stateful_completion_role "${subagent_type}"; then
    _prepare_gate_reviewer_dispatch_unlocked || return 1
    if [[ "${_duplicate_gate_reviewer}" -eq 1 ]]; then
      return 0
    fi
  fi

  # Excellence evidence is meaningful only for the exact Definition revision
  # it was asked to judge. Bind that revision at PreToolUse under the same lock
  # as the dispatch ledger, before paying for the reviewer call.
  if [[ "${subagent_type##*:}" == "excellence-reviewer" \
      && "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]]; then
    if ! _omc_load_quality_contract 2>/dev/null \
        || ! _quality_contract_json="$(quality_contract_validate_current 2>/dev/null)"; then
      _quality_contract_dispatch_denied=1
      return 0
    fi
    _quality_contract_id="$(jq -r '.contract_id // empty' \
      <<<"${_quality_contract_json}" 2>/dev/null || true)"
    _quality_contract_revision="$(jq -r '.contract_revision // 0' \
      <<<"${_quality_contract_json}" 2>/dev/null || true)"
    [[ "${_quality_contract_id}" =~ ^qc-[A-Za-z0-9._:-]{8,80}$ \
        && "${_quality_contract_revision}" =~ ^[1-9][0-9]*$ ]] || {
      _quality_contract_dispatch_denied=1
      return 0
    }
    _quality_contract_bound=1
  fi
  _prepare_active_ordinary_identity_rebind_unlocked || return 1
  if [[ "${_dispatch_identity_denied}" -eq 1 ]]; then
    return 0
  fi
  # Run exact-identity ambiguity after every explicit stale-row preparation.
  # Reviewer/planner/Council rebinds have marked only the replaced row
  # abandoned by this point; ordinary active duplicates still fail closed.
  if _pending_identity_is_ambiguous_unlocked; then
    _dispatch_identity_denied=1
    _dispatch_active_exact_duplicate=1
    return 0
  fi
  # Recovery preparation may just have converted one killed live row into a
  # tombstone. Apply the admission ceiling after that transition so a full
  # 64-way wave can replace one confirmed-dead slot without exceeding 64;
  # unrelated call 65 is still denied before any paid Agent launch.
  if _pending_live_cap_reached_unlocked; then
    _pending_live_cap_denied=1
    return 0
  fi

  _edit_rev="$(read_state "edit_revision")"; [[ "${_edit_rev}" =~ ^[0-9]+$ ]] || _edit_rev=0
  _code_rev="$(read_state "last_code_edit_revision")"; [[ "${_code_rev}" =~ ^[0-9]+$ ]] || _code_rev=0
  _doc_rev="$(read_state "last_doc_edit_revision")"; [[ "${_doc_rev}" =~ ^[0-9]+$ ]] || _doc_rev=0
  _bash_rev="$(read_state "last_bash_edit_revision")"; [[ "${_bash_rev}" =~ ^[0-9]+$ ]] || _bash_rev=0
  _ui_rev="$(dimension_freshness_revision "design_quality")"; [[ "${_ui_rev}" =~ ^[0-9]+$ ]] || _ui_rev=0
  _plan_rev="$(read_state "plan_revision")"; [[ "${_plan_rev}" =~ ^[0-9]+$ ]] || _plan_rev=0
  _objective_prompt_ts="$(read_state "review_cycle_prompt_ts")"
  if [[ ! "${_objective_prompt_ts}" =~ ^[0-9]+$ ]]; then
    _objective_prompt_ts="$(read_state "last_user_prompt_ts")"
  fi
  [[ "${_objective_prompt_ts}" =~ ^[0-9]+$ ]] || _objective_prompt_ts=0
  _objective_prompt_revision="$(read_state "prompt_revision")"
  [[ "${_objective_prompt_revision}" =~ ^[0-9]+$ ]] \
    || _objective_prompt_revision=0
  _objective_cycle_id="$(read_state "review_cycle_id")"
  [[ "${_objective_cycle_id}" =~ ^[0-9]+$ ]] || _objective_cycle_id=0
  _enforcement_generation="${_OMC_ULW_CAPTURED_GENERATION:-migration}"
  if [[ "${review_batch_requested}" -eq 1 ]] \
      && [[ "$(read_state "council_phase8_active")" == "1" ]]; then
    # Every dispatch on the same settled objective/edit generation receives
    # the same deterministic ID. No model-authored ID and no role allowlist is
    # trusted; pending-row cleanup naturally releases one role at a time.
    _review_batch_id="phase8-${_objective_prompt_ts}-p${_objective_prompt_revision}-e${_edit_rev}"
  fi
  if _is_stateful_completion_role "${subagent_type}"; then
    _is_stateful=1
    _review_revision="$(_gate_reviewer_start_revision "${subagent_type}")"
  fi
  _lifecycle_dispatch_id="dispatch-$(_omc_token_digest \
    "${SESSION_ID}|${subagent_type}|$(now_epoch)|$$|${RANDOM}" \
    2>/dev/null || true)"
  [[ "${_lifecycle_dispatch_id}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]] \
    || return 1
  pending_entry="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg agent_type "${subagent_type}" \
    --arg description "${description}" \
    --arg council_phase "${council_phase}" \
    --arg council_selection_agent "${council_selection_agent}" \
    --argjson council_objective_prompt_ts "${council_objective_ts}" \
    --argjson council_objective_prompt_revision "${council_prompt_revision}" \
    --argjson council_ledger_generation "${council_ledger_generation}" \
    --argjson edit_revision "${_edit_rev}" \
    --argjson code_revision "${_code_rev}" \
    --argjson doc_revision "${_doc_rev}" \
    --argjson bash_revision "${_bash_rev}" \
    --argjson ui_revision "${_ui_rev}" \
    --argjson plan_revision "${_plan_rev}" \
    --argjson objective_prompt_ts "${_objective_prompt_ts}" \
    --argjson objective_prompt_revision "${_objective_prompt_revision}" \
    --argjson objective_cycle_id "${_objective_cycle_id}" \
    --arg enforcement_generation "${_enforcement_generation}" \
    --arg lifecycle_dispatch_id "${_lifecycle_dispatch_id}" \
    --arg review_batch_id "${_review_batch_id}" \
    --arg review_dispatch_id "${review_rebind_id}" \
    --argjson is_stateful "${_is_stateful}" \
    --argjson review_dispatch_causality_version "${REVIEW_DISPATCH_CAUSALITY_VERSION}" \
    --argjson review_revision "${_review_revision}" \
    --argjson quality_contract_bound "${_quality_contract_bound}" \
    --arg quality_contract_id "${_quality_contract_id}" \
    --argjson quality_contract_revision "${_quality_contract_revision}" \
    '{ts:$ts,agent_type:$agent_type,description:$description,
      lifecycle_dispatch_id:$lifecycle_dispatch_id,
      edit_revision:$edit_revision,code_revision:$code_revision,
      doc_revision:$doc_revision,bash_revision:$bash_revision,
      ui_revision:$ui_revision,plan_revision:$plan_revision,
      objective_prompt_ts:$objective_prompt_ts,
      objective_prompt_revision:$objective_prompt_revision,
      objective_cycle_id:$objective_cycle_id,
      ulw_enforcement_generation:$enforcement_generation}
     + if $is_stateful == 1 then {
         review_dispatch_causality_version:$review_dispatch_causality_version,
         review_revision:$review_revision
      } else {} end
     + if $review_batch_id == "" then {} else {
         review_batch_id:$review_batch_id
       } end
     + if $review_dispatch_id == "" then {} else {
         review_dispatch_id:$review_dispatch_id
       } end
     + if $quality_contract_bound == 1 then {
         quality_contract_id:$quality_contract_id,
         quality_contract_revision:$quality_contract_revision
       } else {} end
     + if $council_phase == "" then {} else {
         purpose:"council",
         council_phase:$council_phase,
         council_selection_agent:$council_selection_agent,
         council_objective_prompt_ts:$council_objective_prompt_ts,
         council_objective_prompt_revision:$council_objective_prompt_revision,
         council_ledger_generation:$council_ledger_generation
       } end')"
  if [[ -n "${review_rebind_id}" ]]; then
    _taint_dispatch_identity_unlocked "${subagent_type}" || return 1
    _register_dispatch_rebind_id_unlocked \
      "${review_rebind_id}" "${subagent_type}" || return 1
  fi
  # Once a current dispatcher exists, absence of its admission-bounded pending
  # row must fail closed at SubagentStop. The marker survives /ulw-off and
  # artifact corruption, preventing a late tracked result from falling into
  # the legacy-untracked summary path after its causal row has disappeared.
  _write_state_batch_unlocked "subagent_dispatch_tracking_version" \
    "${REVIEW_DISPATCH_CAUSALITY_VERSION}" || return 1
  _append_dispatch_ledger_preserving_live_unlocked \
    "pending_agents.jsonl" "${pending_entry}" \
    "${PENDING_AGENT_TOMBSTONE_CAP}" || return 1
  # Durable FIFO consumed only by gate-reviewer hooks. Subagent-summary cleanup
  # removes pending entries independently, so reviewer start-generation
  # evidence needs its own bounded ledger to survive hook ordering. Do not put
  # ordinary specialists/builders here: their rows have no consumer and would
  # waste live-ledger capacity during large fan-out.
  if _is_stateful_completion_role "${subagent_type}"; then
    if ! _append_dispatch_ledger_preserving_live_unlocked \
        "agent_dispatch_starts.jsonl" "${pending_entry}" \
        "${PENDING_AGENT_TOMBSTONE_CAP}"; then
      return 1
    fi
    # Once a session emits a versioned start, every later reviewer completion
    # in that session must prove its row. The marker deliberately survives
    # /ulw-off so a late pre-deactivation completion cannot be mistaken for a
    # legacy untracked result after reactivation.
    if ! _write_state_batch_unlocked \
        "review_dispatch_tracking_version" \
        "${REVIEW_DISPATCH_CAUSALITY_VERSION}"; then
      return 1
    fi
    if _is_planner_role "${subagent_type}"; then
      if ! _write_state_batch_unlocked \
          "plan_dispatch_tracking_version" \
          "${REVIEW_DISPATCH_CAUSALITY_VERSION}"; then
        return 1
      fi
    fi
  fi
  if [[ -n "${council_phase}" ]]; then
    # Completion removes pending_agents entries, so keep a small durable
    # dispatch ledger for real-work scoring and auditability.
    _append_council_dispatch_audit_unlocked \
      "${pending_entry}" "${_objective_cycle_id}" || return 1
  fi
  local _count
  _count="$(read_state "subagent_dispatch_count")"
  _count="${_count:-0}"
  write_state "subagent_dispatch_count" "$((_count + 1))"

  if _is_advisory_specialist "${subagent_type}"; then
    local _adv_count
    _adv_count="$(read_state "advisory_specialist_dispatch_count")"
    _adv_count="${_adv_count:-0}"
    write_state "advisory_specialist_dispatch_count" "$((_adv_count + 1))"
  fi
}
_duplicate_gate_reviewer=0
_duplicate_frozen_batch_role=0
_review_rebind_required=0
_review_rebind_collision=0
_review_completion_claimed=0
_review_rebind_suggested_id=""
_council_coverage_denied=0
_council_coverage_reason=""
_dispatch_identity_denied=0
_dispatch_council_active_duplicate=0
_dispatch_abandoned_identity_rebind_required=0
_dispatch_generic_abandoned_rebind_required=0
_dispatch_active_exact_duplicate=0
_council_identity_rebind_ready=0
_council_current_attempt_rebind_ready=0
_pending_live_cap_denied=0
_quality_contract_dispatch_denied=0
_dispatch_interrupted_journal=0
council_selection_agent=""
council_objective_ts=0
council_prompt_revision=0
council_ledger_generation=0
_dispatch_state_rc=0

# One Agent authorization touches several causal artifacts. Treat those writes
# as a transaction: if a downstream reviewer-start/Council audit append fails,
# restore the exact pre-dispatch files so a call that was denied before launch
# cannot leave a phantom in-flight row or consume a Council slot.
_snapshot_dispatch_artifacts_unlocked() {
  local dir="$1" artifact path
  for artifact in \
      session_state.json \
      pending_agents.jsonl \
      agent_dispatch_starts.jsonl \
      council_dispatches.jsonl \
      council_coverage.json \
      dispatch_tainted_identities.log \
      dispatch_rebind_ids.log; do
    path="$(session_file "${artifact}")"
    if [[ -L "${path}" ]]; then
      : >"${dir}/${artifact}.other" || return 1
    elif [[ -f "${path}" ]]; then
      cp "${path}" "${dir}/${artifact}.file" || return 1
    elif [[ ! -e "${path}" && ! -L "${path}" ]]; then
      : >"${dir}/${artifact}.absent" || return 1
    else
      # Preserve non-regular fault sentinels exactly; never remove a directory
      # or foreign symlink while compensating our own staged writes.
      : >"${dir}/${artifact}.other" || return 1
    fi
  done
}

_restore_dispatch_artifacts_unlocked() {
  local dir="$1" artifact path restore_tmp rc=0
  for artifact in \
      session_state.json \
      pending_agents.jsonl \
      agent_dispatch_starts.jsonl \
      council_dispatches.jsonl \
      council_coverage.json \
      dispatch_tainted_identities.log \
      dispatch_rebind_ids.log; do
    path="$(session_file "${artifact}")"
    if [[ -f "${dir}/${artifact}.file" ]]; then
      if [[ -L "${path}" ]] \
          || { [[ -e "${path}" ]] && [[ ! -f "${path}" ]]; }; then
        rc=1
        continue
      fi
      restore_tmp="$(mktemp "${path}.restore.XXXXXX")" || {
        rc=1
        continue
      }
      if ! cp "${dir}/${artifact}.file" "${restore_tmp}" \
          || ! mv -f "${restore_tmp}" "${path}"; then
        rm -f "${restore_tmp}"
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

_cleanup_dispatch_snapshot() {
  local dir="$1"
  rm -f "${dir}/.ready" 2>/dev/null || true
  rm -f "${dir}"/* 2>/dev/null || true
  rmdir "${dir}" 2>/dev/null || true
}

_disarm_dispatch_snapshot() {
  rm -f "$1/.ready"
}

_recover_dispatch_snapshots_unlocked() {
  local stale rc=0
  for stale in "$(session_file ".dispatch-txn.")"*; do
    [[ -d "${stale}" ]] || continue
    if [[ -f "${stale}/.ready" ]]; then
      # Never replay an old whole-file snapshot after another hook may have
      # acquired the reclaimed lock; that would erase unrelated revisions.
      # Fail closed until /ulw-off taints identities and clears the journal.
      _dispatch_interrupted_journal=1
      log_anomaly "record-pending-agent" \
        "interrupted dispatch transaction ${stale##*/}; refusing unsafe rollback"
      rc=1
      continue
    fi
    _cleanup_dispatch_snapshot "${stale}"
  done
  return "${rc}"
}

_append_pending_transaction_unlocked() {
  local snapshot_dir body_rc=0 denied=0 restore_rc=0
  _recover_dispatch_snapshots_unlocked || return 1
  snapshot_dir="$(mktemp -d "$(session_file ".dispatch-txn.XXXXXX")")" \
    || return 1
  if ! _snapshot_dispatch_artifacts_unlocked "${snapshot_dir}"; then
    _cleanup_dispatch_snapshot "${snapshot_dir}" || true
    return 1
  fi
  : >"${snapshot_dir}/.ready" || {
    _cleanup_dispatch_snapshot "${snapshot_dir}" || true
    return 1
  }
  _append_pending || body_rc=$?
  if [[ "${_duplicate_gate_reviewer}" -eq 1 \
      || "${_duplicate_frozen_batch_role}" -eq 1 \
      || "${_council_coverage_denied}" -eq 1 \
      || "${_dispatch_identity_denied}" -eq 1 \
      || "${_pending_live_cap_denied}" -eq 1 \
      || "${_quality_contract_dispatch_denied}" -eq 1 ]]; then
    denied=1
  fi
  if [[ "${body_rc}" -ne 0 || "${denied}" -eq 1 ]]; then
    _restore_dispatch_artifacts_unlocked "${snapshot_dir}" || restore_rc=$?
  fi
  if ! _disarm_dispatch_snapshot "${snapshot_dir}"; then
    # If a successful authorization cannot disarm its rollback journal, deny
    # the tool and compensate while the same lock still excludes peers.
    if [[ "${body_rc}" -eq 0 && "${denied}" -eq 0 ]]; then
      _restore_dispatch_artifacts_unlocked "${snapshot_dir}" || restore_rc=$?
      body_rc=1
    fi
    _cleanup_dispatch_snapshot "${snapshot_dir}"
  fi
  _cleanup_dispatch_snapshot "${snapshot_dir}"
  [[ "${restore_rc}" -eq 0 ]] || return "${restore_rc}"
  [[ "${body_rc}" -eq 0 ]] || return "${body_rc}"
  return 0
}

with_state_lock _append_pending_transaction_unlocked || _dispatch_state_rc=$?

if [[ "${_dispatch_state_rc}" -ne 0 ]]; then
  if [[ "${_dispatch_interrupted_journal}" -eq 1 ]]; then
    jq -nc --arg reason "[Dispatch recovery] A prior Agent authorization was interrupted mid-transaction. To avoid either launching an untracked agent or rolling back unrelated edits, dispatch is paused. Run /ulw-off, then reactivate /ulw; deactivation taints every live identity and clears the interrupted journal safely." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
  if _is_gate_reviewer "${subagent_type}"; then
    record_gate_event "reviewer-dispatch-causality" "block" \
      "agent=${subagent_type}" "reason=start-snapshot-write-failed" \
      "rc=${_dispatch_state_rc}" 2>/dev/null || true
    jq -nc --arg reason "[Reviewer causality gate] The start generation for ${subagent_type} could not be recorded safely. Do not launch an untracked review; retry this dispatch after the active state write finishes." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  else
    record_gate_event "subagent-dispatch-causality" "block" \
      "agent=${subagent_type}" "reason=pending-snapshot-write-failed" \
      "rc=${_dispatch_state_rc}" 2>/dev/null || true
    jq -nc --arg reason "[Dispatch causality] The pending snapshot for ${subagent_type} could not be recorded safely. Do not launch an untracked agent; retry this dispatch after the active state write finishes." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  fi
  exit 0
fi

if [[ "${_pending_live_cap_denied}" -eq 1 ]]; then
  record_gate_event "subagent-dispatch-causality" "block" \
    "agent=${subagent_type}" "reason=live-pending-cap-reached" \
    "cap=${PENDING_AGENT_LIVE_CAP}" 2>/dev/null || true
  jq -nc --arg reason "[Dispatch capacity] ${PENDING_AGENT_LIVE_CAP} live specialist calls are already tracked for this session. Wait for at least one return before launching ${subagent_type}; abandoned suppression tombstones do not consume this live cap. This prevents a paid in-flight result from being evicted and discarded." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_quality_contract_dispatch_denied}" -eq 1 ]]; then
  record_gate_event "definition-of-excellent/reviewer-dispatch" "block" \
    "agent=${subagent_type}" "reason=missing-or-stale-contract" 2>/dev/null || true
  jq -nc --arg reason "[Definition of Excellent · reviewer dispatch] ${subagent_type} cannot be launched until a current frozen quality contract exists for this objective and plan revision. Dispatch quality-planner or prometheus first; after its PLAN_READY contract is recorded, retry this reviewer. This prevents a review launched against one bar from certifying another." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_council_coverage_denied}" -eq 1 ]]; then
  record_gate_event "council-coverage" "block" \
    "agent=${subagent_type}" "phase=${council_phase}" "reason=${_council_coverage_reason}"
  jq -nc --arg reason "[Council coverage gate] ${subagent_type} is tagged ${council_phase}, but the current lifecycle does not authorize that exact dispatch (${_council_coverage_reason}). Primary agents require the current generation-1 selection; gap-fill agents require the reconciled gap selection; verification requires a current final-reconciled ledger, a unique verifier identity, and one of at most three verification slots." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_dispatch_identity_denied}" -eq 1 ]]; then
  if [[ "${_dispatch_generic_abandoned_rebind_required}" -eq 1 \
      && "${_review_rebind_collision}" -eq 1 ]]; then
    _dispatch_identity_reason="review-rebind-id-collision"
    _dispatch_identity_message="[Dispatch causality] The requested review-rebind ID is already present. Retry ${subagent_type} with the fresh exact description token [review-rebind:${_review_rebind_suggested_id}] and tell it to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line."
  elif [[ "${_dispatch_generic_abandoned_rebind_required}" -eq 1 ]]; then
    _dispatch_identity_reason="abandoned-identity-rebind-required"
    _dispatch_identity_message="[Dispatch causality] A prior-objective or abandoned ${subagent_type} call can still return late. Retry with the exact description token [review-rebind:${_review_rebind_suggested_id}] and tell the replacement to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line. The tombstone remains only to suppress the old return."
  elif [[ "${_review_completion_claimed}" -eq 1 ]]; then
    _dispatch_identity_reason="completion-claim-in-progress"
    _dispatch_identity_message="[Dispatch causality] ${subagent_type} has already returned and its completion is being recorded under the durable completion claim. Wait for that transition to finish; do not rebind or pay for a replacement."
  elif [[ "${_review_rebind_collision}" -eq 1 ]]; then
    _dispatch_identity_reason="review-rebind-id-collision"
    _dispatch_identity_message="[Council provenance gate] The requested review-rebind ID is already present. Retry ${subagent_type} with the fresh exact description token [review-rebind:${_review_rebind_suggested_id}] and tell it to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line."
  elif [[ "${_dispatch_abandoned_identity_rebind_required}" -eq 1 ]]; then
    _dispatch_identity_reason="abandoned-identity-rebind-required"
    _dispatch_identity_message="[Council provenance gate] An abandoned or prior-objective ${subagent_type} call can still return late, so this exact Council identity must be rebound. Retry with the exact description token [review-rebind:${_review_rebind_suggested_id}] and tell the replacement to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line. The abandoned tombstone remains only to suppress the old return."
  elif [[ "${_dispatch_council_active_duplicate}" -eq 1 ]]; then
    _dispatch_identity_reason="duplicate-in-flight-council-identity"
    _dispatch_identity_message="[Council provenance gate] ${subagent_type} already has an active Council dispatch. Wait for it to return. Only if you have confirmed that call was killed or interrupted, retry with the exact description token [review-rebind:${_review_rebind_suggested_id}] and tell the replacement to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line."
  elif [[ "${_dispatch_active_exact_duplicate}" -eq 1 ]]; then
    _dispatch_identity_reason="duplicate-in-flight-exact-identity"
    _dispatch_identity_message="[Dispatch causality] ${subagent_type} already has an active call. Wait for it to return; distinct specialist identities remain parallel. Only if you have confirmed this exact call was killed or interrupted, retry with the fresh description token [review-rebind:${_review_rebind_suggested_id}]. Native SubagentStart binds the replacement automatically; on older clients also require REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before the final VERDICT."
  else
    _dispatch_identity_reason="ambiguous-in-flight-identity"
    _dispatch_identity_message="[Council provenance gate] ${subagent_type} already has an active dispatch whose completion would be ambiguous with this Council identity. Wait for it to return before dispatching the same exact agent identity again; other specialists may remain parallel."
  fi
  if [[ "${_dispatch_active_exact_duplicate}" -eq 1 ]]; then
    record_gate_event "subagent-dispatch-causality" "block" \
      "agent=${subagent_type}" "reason=${_dispatch_identity_reason}"
  else
    record_gate_event "council-provenance" "block" \
      "agent=${subagent_type}" "reason=${_dispatch_identity_reason}"
  fi
  jq -nc --arg reason "${_dispatch_identity_message}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_duplicate_frozen_batch_role}" -eq 1 ]]; then
  if [[ "${_review_completion_claimed}" -eq 1 ]]; then
    _batch_block_reason="completion-claim-in-progress"
    _batch_reason="[Review batch causality] ${subagent_type} has already returned and its completion is being recorded under the session lock. Wait for that hook transition to finish; do not rebind or pay for a replacement."
  elif [[ "${_review_rebind_required}" -eq 1 ]]; then
    _batch_block_reason="abandoned-role-rebind-required"
    _batch_reason="[Review batch causality] The previous ${subagent_type} batch call has exceeded the two-hour abandonment window, but its late SubagentStop can still arrive. Retry with the exact description token [review-rebind:${_review_rebind_suggested_id}] and tell that agent to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line. This one-time binding lets the retry finish without a late old completion consuming it."
  elif [[ "${_review_rebind_collision}" -eq 1 ]]; then
    _batch_block_reason="review-rebind-id-collision"
    _batch_reason="[Review batch causality] The requested review-rebind ID is already present for ${subagent_type}. Retry with a fresh exact description token [review-rebind:${_review_rebind_suggested_id}] and tell that agent to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line."
  else
    _batch_block_reason="duplicate-in-flight-role"
    _batch_reason="[Review batch causality] ${subagent_type} is already in this frozen review batch. Wait for that exact role to return; other marked batch roles may remain parallel. Only if you have confirmed that call was killed or interrupted, retry with the exact description token [review-rebind:${_review_rebind_suggested_id}] and tell the replacement to emit REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT line. The binding safely rejects any late old return."
  fi
  record_gate_event "review-batch-causality" "block" \
    "agent=${subagent_type}" "reason=${_batch_block_reason}"
  jq -nc --arg reason "${_batch_reason}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_duplicate_gate_reviewer}" -eq 1 ]]; then
  if [[ "${_review_completion_claimed}" -eq 1 ]]; then
    _reviewer_block_reason="completion-claim-in-progress"
    _reviewer_reason="[Reviewer causality gate] ${subagent_type} has already returned and its completion is being recorded under the session lock. Wait for that hook transition to finish; do not rebind or pay for a replacement."
  elif [[ "${_review_rebind_required}" -eq 1 ]]; then
    _reviewer_block_reason="abandoned-role-rebind-required"
    _reviewer_reason="[Reviewer causality gate] The previous ${subagent_type} call has exceeded the two-hour abandonment window, but its late SubagentStop can still arrive. Retry with the exact description token [review-rebind:${_review_rebind_suggested_id}]. Native SubagentStart binds the replacement automatically; on an older in-flight client also require REVIEW_DISPATCH_ID: ${_review_rebind_suggested_id} immediately before its final VERDICT."
  elif [[ "${_review_rebind_collision}" -eq 1 ]]; then
    _reviewer_block_reason="review-rebind-id-collision"
    _reviewer_reason="[Reviewer causality gate] The requested review-rebind ID is already present for ${subagent_type}. Retry with a fresh exact description token [review-rebind:${_review_rebind_suggested_id}]. Native SubagentStart binds the replacement automatically; the echoed line is needed only for older in-flight clients."
  else
    _reviewer_block_reason="duplicate-in-flight-role"
    _reviewer_reason="[Reviewer causality gate] ${subagent_type} is already in flight. Wait for the active review to finish; different reviewer identities may still run in parallel. Only if you have confirmed this call was killed or interrupted, retry with [review-rebind:${_review_rebind_suggested_id}]. The platform agent_id binds the replacement and rejects a late old return; require the echoed REVIEW_DISPATCH_ID only for an older in-flight client."
  fi
  record_gate_event "reviewer-dispatch-causality" "block" \
    "agent=${subagent_type}" "reason=${_reviewer_block_reason}"
  jq -nc --arg reason "${_reviewer_reason}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

log_hook "record-pending-agent" "dispatched=${subagent_type}"
