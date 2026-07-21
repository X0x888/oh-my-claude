#!/usr/bin/env bash
# Persist and validate the adaptive Council coverage/selection lifecycle.
#
# Usage:
#   record-council-coverage.sh init      < coverage.json
#   record-council-coverage.sh update    < coverage.json
#   record-council-coverage.sh complete
#   record-council-coverage.sh validate
#   record-council-coverage.sh show
#   record-council-coverage.sh path

set -euo pipefail

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="${SESSION_ID:-$(discover_current_project_session)}"
if [[ -z "${SESSION_ID}" ]]; then
  printf 'record-council-coverage: no active session found under %s\n' "${STATE_ROOT}" >&2
  exit 1
fi
ensure_session_dir

LEDGER_FILE="$(session_file "council_coverage.json")"
RETURNS_FILE="$(session_file "council_returns.jsonl")"
COMMAND="${1:-show}"

# The common schema is deliberately strict about identity and mandate shape.
# Runtime-owned fields (generation, resolved_agent, timestamps) are allowed so
# `validate` can check a persisted ledger with the same predicate.
_validate_payload() {
  jq -e '
    type == "object"
    and ((.objective // "") | type == "string" and length > 0)
    and ((.coverage_rows // []) | type == "array" and length > 0)
    and ((.coverage_rows // []) | all(
      ((.id // "") | type == "string" and length > 0)
      and ((.need // "") | type == "string" and length > 0)
      and ((.evidence // "") | type == "string" and length > 0)
      and ((.impact // "") | type == "string" and length > 0)
      and ((.competence // "") | type == "string" and length > 0)
      and ((.status // "") | IN("selected", "covered-inline", "skipped"))
      and (if .status == "skipped" or .status == "covered-inline"
           then ((.reason // "") | type == "string" and length > 0)
           else true end)
    ))
    and ((.selections // []) | type == "array" and length > 0)
    and ((.selections // []) | all(
      ((.agent // "") | type == "string" and length > 0)
      and ((.phase // "") | IN("primary", "gap-fill"))
      and ((.coverage_ids // []) | type == "array" and length > 0
           and all(.[]; type == "string" and length > 0))
      and ((.reason // "") | type == "string" and length > 0)
      and ((.non_goals // []) | type == "array" and length > 0
           and all(.[]; type == "string" and length > 0))
      and ((.resolved_agent // "") | type == "string")
      and ((.added_generation // 1) | type == "number" and . >= 1)
    ))
    and (([.coverage_rows[].id] | length) == ([.coverage_rows[].id] | unique | length))
    and (([.selections[] | (.agent + "\u0000" + .phase)] | length)
         == ([.selections[] | (.agent + "\u0000" + .phase)] | unique | length))
    and (([.selections[].coverage_ids[]] | length) == ([.selections[].coverage_ids[]] | unique | length))
    and (([.selections[].coverage_ids[]] - [.coverage_rows[].id]) | length == 0)
    and (([.coverage_rows[] | select(.status == "selected") | .id]
          - [.selections[].coverage_ids[]]) | length == 0)
    and (([.selections[].coverage_ids[]]
          - [.coverage_rows[] | select(.status == "selected") | .id]) | length == 0)
  ' >/dev/null
}

_validate_primary_envelope() {
  jq -e '
    [.selections[] | select(.phase == "primary")] as $primary
    | [$primary[].coverage_ids[]] as $primary_ids
    | ($primary | length) >= 1
      and (
        ($primary | length) <= 4
        or (
          ((.primary_exception // {}) | type == "object")
          and ((.primary_exception.reason // "") | type == "string" and length > 0)
          and ((.primary_exception.cost // "") | type == "string" and length > 0)
          and ((.primary_exception.independent_high_impact_coverage_ids // []) | type == "array")
          and ((.primary_exception.independent_high_impact_coverage_ids | length)
               == (.primary_exception.independent_high_impact_coverage_ids | unique | length))
          and ((.primary_exception.independent_high_impact_coverage_ids | sort)
               == ($primary_ids | sort))
        )
      )
  ' >/dev/null
}

_validate_init_payload() {
  local content
  content="$(cat)"
  printf '%s' "${content}" | _validate_payload \
    && printf '%s' "${content}" | _validate_primary_envelope \
    && printf '%s' "${content}" | jq -e '
      ([.selections[] | select(.phase == "gap-fill")] | length) == 0
      and (has("reconciliation") | not)
    ' >/dev/null
}

# Reconciliation is not free-form prose. It accounts for every selected row,
# names every returned primary, and ties each gap-fill mandate to a row that
# was partial, uncovered, or newly discovered in those returns.
_validate_reconciled_payload() {
  jq -e '
    [.selections[] | select(.phase == "primary") | .agent] as $primary_agents
    | [.selections[] | select(.phase == "primary") | .coverage_ids[]] as $primary_ids
    | [.selections[] | select(.phase == "gap-fill") | .agent] as $gap_agents
    | [.selections[] | select(.phase == "gap-fill") | .coverage_ids[]] as $gap_ids
    | [.selections[].coverage_ids[]] as $selected_ids
    | (.reconciliation // {}) as $r
    | ($r | type == "object")
      and (($r.status // "") | IN("primary-complete", "gap-fill-required", "gap-fill-complete"))
      and (($r.evidence // "") | type == "string" and length > 0)
      and (($r.primary_returns // []) | type == "array"
           and all(.[]; type == "string" and length > 0))
      and (($r.primary_returns | length) == ($r.primary_returns | unique | length))
      and (($r.primary_returns | sort) == ($primary_agents | sort))
      and (($r.gap_fill_returns // []) | type == "array"
           and all(.[]; type == "string" and length > 0))
      and (($r.gap_fill_returns | length) == ($r.gap_fill_returns | unique | length))
      and (($r.coverage_results // []) | type == "array" and length > 0)
      and (($r.coverage_results // []) | all(
        ((.coverage_id // "") | type == "string" and length > 0)
        and ((.status // "") | IN("evidenced", "partial", "uncovered", "newly-discovered"))
        and ((.evidence // "") | type == "string" and length > 0)
        and ((.reason // "") | type == "string" and length > 0)
      ))
      and (([$r.coverage_results[].coverage_id] | length)
           == ([$r.coverage_results[].coverage_id] | unique | length))
      and (([$r.coverage_results[].coverage_id] | sort) == ($selected_ids | sort))
      and (
        if ($gap_agents | length) == 0 then
          $r.status == "primary-complete"
          and (($r.gap_fill_returns // []) | length) == 0
          and all($r.coverage_results[]; .status == "evidenced")
        elif $r.status == "gap-fill-required" then
          ($gap_agents | length) <= 2
          and (($r.gap_fill_returns // []) | length) == 0
          and all($gap_ids[];
            . as $id
            | any($r.coverage_results[];
                .coverage_id == $id
                and (.status == "partial" or .status == "uncovered" or .status == "newly-discovered")
              )
          )
        else
          $r.status == "gap-fill-complete"
          and ($gap_agents | length) <= 2
          and (($r.gap_fill_returns | sort) == ($gap_agents | sort))
        end
      )
  ' >/dev/null
}

_current_prompt_numbers_unlocked() {
  _coverage_prompt_ts="$(read_state "last_user_prompt_ts")"
  [[ "${_coverage_prompt_ts}" =~ ^[0-9]+$ ]] || _coverage_prompt_ts=0
  _coverage_prompt_revision="$(read_state "prompt_revision")"
  [[ "${_coverage_prompt_revision}" =~ ^[0-9]+$ ]] || _coverage_prompt_revision=0
  _coverage_cycle_id="$(read_state "review_cycle_id")"
  [[ "${_coverage_cycle_id}" =~ ^[0-9]+$ ]] || _coverage_cycle_id=0
}

_ledger_is_current_unlocked() {
  local ledger_prompt_ts ledger_prompt_revision ledger_cycle_id
  [[ -f "${LEDGER_FILE}" ]] || return 1
  ledger_prompt_ts="$(jq -r '.objective_prompt_ts // 0' "${LEDGER_FILE}" 2>/dev/null || true)"
  ledger_prompt_revision="$(jq -r '.objective_prompt_revision // 0' "${LEDGER_FILE}" 2>/dev/null || true)"
  ledger_cycle_id="$(jq -r '.objective_cycle_id // 0' "${LEDGER_FILE}" 2>/dev/null || true)"
  [[ "${ledger_prompt_ts}" =~ ^[0-9]+$ ]] || ledger_prompt_ts=0
  [[ "${ledger_prompt_revision}" =~ ^[0-9]+$ ]] || ledger_prompt_revision=0
  [[ "${ledger_cycle_id}" =~ ^[0-9]+$ ]] || ledger_cycle_id=0
  (( ledger_prompt_ts == _coverage_prompt_ts
     && ledger_prompt_revision == _coverage_prompt_revision
     && (_coverage_cycle_id == 0 || ledger_cycle_id == _coverage_cycle_id) ))
}

_selection_returns_complete_unlocked() {
  local phase="$1"
  [[ -f "${RETURNS_FILE}" ]] || return 1
  jq -s -e \
    --slurpfile ledger "${LEDGER_FILE}" \
    --arg phase "${phase}" \
    --argjson objective_ts "${_coverage_prompt_ts}" \
    --argjson prompt_revision "${_coverage_prompt_revision}" \
    --argjson cycle_id "${_coverage_cycle_id}" '
      [$ledger[0].selections[] | select(.phase == $phase) | .agent] as $expected
      | [.[]
          | select((.objective_prompt_ts // -1) == $objective_ts)
          | select((.objective_prompt_revision // -1) == $prompt_revision)
          | select($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
          | select((.contract_valid // true) == true)
          | select((.council_phase // "") == $phase)
          | .selection_agent] | unique as $returned
      | ($expected | length) > 0
        and (($expected - $returned) | length) == 0
    ' "${RETURNS_FILE}" >/dev/null 2>&1
}

_no_current_council_pending_unlocked() {
  local pending_file has_pending
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" ]] || return 0
  if ! has_pending="$(jq -s -r \
      --argjson objective_ts "${_coverage_prompt_ts}" \
      --argjson prompt_revision "${_coverage_prompt_revision}" \
      --argjson cycle_id "${_coverage_cycle_id}" '
        any(.[]?;
          (.purpose // "") == "council"
          and ((.council_phase // "")
               | IN("primary", "gap-fill", "verification"))
          and (.council_objective_prompt_ts // -1) == $objective_ts
          and (.council_objective_prompt_revision // -1) == $prompt_revision
          and ($cycle_id == 0
            or (.objective_cycle_id // -1) == $cycle_id)
          and (.review_dispatch_abandoned // false) != true
          and (.completion_claim_effects_complete // false) != true
        )
      ' "${pending_file}" 2>/dev/null)"; then
    # A corrupt pending ledger cannot prove that all selected work returned.
    return 1
  fi
  if [[ "${has_pending}" == "true" ]]; then
    return 1
  fi
  return 0
}

_write_ledger_unlocked() {
  local content="$1" archive_previous="${2:-0}" tmp previous
  if [[ "${archive_previous}" == "1" && -f "${LEDGER_FILE}" ]]; then
    previous="$(jq -c . "${LEDGER_FILE}" 2>/dev/null || true)"
    if [[ -n "${previous}" ]]; then
      append_limited_state "council_coverage_history.jsonl" "${previous}" "16"
    fi
  fi
  tmp="${LEDGER_FILE}.tmp.$$"
  printf '%s\n' "${content}" >"${tmp}"
  mv -f "${tmp}" "${LEDGER_FILE}"
}

_drop_prior_objective_council_pending_unlocked() {
  local pending_file tmp line updated artifact abandoned_ts
  abandoned_ts="$(now_epoch)"
  [[ "${abandoned_ts}" =~ ^[0-9]+$ ]] || abandoned_ts=0
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl; do
    pending_file="$(session_file "${artifact}")"
    [[ -s "${pending_file}" ]] || continue
    tmp="$(mktemp "${pending_file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      if jq -e \
          --argjson objective_ts "${_coverage_prompt_ts}" \
          --argjson prompt_revision "${_coverage_prompt_revision}" \
          --argjson cycle_id "${_coverage_cycle_id}" '
            (.purpose // "") == "council"
            and (
              (.council_objective_prompt_ts // -1) != $objective_ts
              or (.council_objective_prompt_revision // -1) != $prompt_revision
              or ($cycle_id > 0
                and (.objective_cycle_id // -1) != $cycle_id)
            )
          ' <<<"${line}" >/dev/null 2>&1; then
        # Keep a bounded suppression tombstone instead of deleting provenance.
        # A late prior-objective SubagentStop must bind here and be ignored, not
        # fall through as a trusted untracked/legacy completion.
        updated="$(jq -c --argjson abandoned_ts "${abandoned_ts}" '
          . + {
            review_dispatch_abandoned:true,
            review_dispatch_abandonment_reason:"prior-objective",
            review_dispatch_abandoned_ts:$abandoned_ts
          }
        ' <<<"${line}" 2>/dev/null || true)"
        [[ -n "${updated}" ]] && line="${updated}"
      fi
      printf '%s\n' "${line}" >>"${tmp}"
    done <"${pending_file}"
    mv -f "${tmp}" "${pending_file}"
  done
}

_init_unlocked() {
  local payload="$1" now archive_previous=0 normalized
  local phase8_active phase8_prompt_revision
  _current_prompt_numbers_unlocked
  now="$(now_epoch)"

  if [[ -f "${LEDGER_FILE}" ]]; then
    if _ledger_is_current_unlocked; then
      printf 'record-council-coverage: ledger already exists for this prompt; use update\n' >&2
      return 3
    fi
    archive_previous=1
  fi

  normalized="$(printf '%s' "${payload}" | jq -c \
    --argjson now "${now}" \
    --argjson prompt_ts "${_coverage_prompt_ts}" \
    --argjson prompt_revision "${_coverage_prompt_revision}" \
    --argjson cycle_id "${_coverage_cycle_id}" '
      del(.version,.created_ts,.updated_ts,.objective_prompt_ts,.objective_prompt_revision,.objective_cycle_id,
          .generation,.lifecycle,.completion)
      | .selections |= map(del(.resolved_agent,.added_generation) + {added_generation:1})
      | . + {
          version:2,
          generation:1,
          lifecycle:"primary",
          created_ts:$now,
          updated_ts:$now,
          objective_prompt_ts:$prompt_ts,
          objective_prompt_revision:$prompt_revision,
          objective_cycle_id:$cycle_id
        }
    ')"
  _write_ledger_unlocked "${normalized}" "${archive_previous}"
  # A new objective cannot ever accept an old Council return. Retain bounded
  # abandoned tombstones so a late return is suppressed, while dispatch logic
  # requires an ID-bound replacement when reusing that exact identity.
  _drop_prior_objective_council_pending_unlocked
  # Starting a new assessment invalidates any older two-turn handoff. This
  # script remains the sole producer of a ready=1 state; init only clears it.
  # Preserve Phase 8 only when the router stamped it for this exact prompt.
  # A sticky active bit from an older objective cannot suppress this prompt's
  # eventual advisory handoff.
  phase8_active="$(read_state "council_phase8_active")"
  phase8_prompt_revision="$(read_state "council_phase8_prompt_revision")"
  if [[ "${phase8_active}" == "1" \
      && "${phase8_prompt_revision}" =~ ^[0-9]+$ \
      && "${phase8_prompt_revision}" -eq "${_coverage_prompt_revision}" ]]; then
    write_state_batch \
      "council_assessment_ready" "" \
      "council_assessment_ts" "" \
      "council_assessment_prompt_revision" "" \
      "council_assessment_objective_prompt_ts" ""
  else
    write_state_batch \
      "council_assessment_ready" "" \
      "council_assessment_ts" "" \
      "council_assessment_prompt_revision" "" \
      "council_assessment_objective_prompt_ts" "" \
      "council_phase8_active" "" \
      "council_phase8_prompt_revision" ""
  fi
}

_update_unlocked() {
  local payload="$1" now previous_generation next_generation created normalized
  _current_prompt_numbers_unlocked
  if [[ ! -f "${LEDGER_FILE}" ]]; then
    printf 'record-council-coverage: no ledger exists; use init\n' >&2
    return 4
  fi
  if ! _ledger_is_current_unlocked; then
    printf 'record-council-coverage: prior-prompt ledger cannot be updated; use init\n' >&2
    return 5
  fi
  if jq -e 'has("completion")' "${LEDGER_FILE}" >/dev/null 2>&1; then
    printf 'record-council-coverage: completed ledger is immutable\n' >&2
    return 6
  fi
  if ! _selection_returns_complete_unlocked "primary"; then
    printf 'record-council-coverage: update requires a recorded return from every selected primary\n' >&2
    return 7
  fi
  if ! _no_current_council_pending_unlocked; then
    printf 'record-council-coverage: cannot update while a current Council round is still in flight\n' >&2
    return 8
  fi

  # Primary mandates are immutable after dispatch. Existing gap mandates also
  # cannot disappear or change; an update may only append up to two total.
  if ! printf '%s' "${payload}" | jq -e --slurpfile old "${LEDGER_FILE}" '
      def public_selection: del(.resolved_agent,.added_generation);
      ([ $old[0].selections[] | select(.phase == "primary") | public_selection ] | sort_by(.agent))
        == ([ .selections[] | select(.phase == "primary") | public_selection ] | sort_by(.agent))
      and
      (([ $old[0].selections[] | select(.phase == "gap-fill") | public_selection ]
        - [ .selections[] | select(.phase == "gap-fill") | public_selection ]) | length) == 0
      and ([.selections[] | select(.phase == "gap-fill")] | length) <= 2
      and (
        ([ $old[0].selections[] | select(.phase == "gap-fill") ] | length) == 0
        or
        (([ $old[0].selections[] | select(.phase == "gap-fill") | public_selection ] | sort_by(.agent))
          == ([ .selections[] | select(.phase == "gap-fill") | public_selection ] | sort_by(.agent)))
      )
      and
      (.objective == $old[0].objective)
      and
      ((($old[0].coverage_rows // []) - (.coverage_rows // [])) | length) == 0
    ' >/dev/null; then
    printf 'record-council-coverage: update may preserve the objective and prior mandates/coverage rows and add at most two gap-fill mandates; it may not rewrite prior evidence\n' >&2
    return 9
  fi

  # A final gap-fill reconciliation is causal: all selected gap agents must
  # actually have returned before the payload may call the round complete.
  if [[ "$(printf '%s' "${payload}" | jq -r '.reconciliation.status // empty')" == "gap-fill-complete" ]] \
      && ! _selection_returns_complete_unlocked "gap-fill"; then
    printf 'record-council-coverage: gap-fill-complete requires a recorded return from every selected gap-fill agent\n' >&2
    return 10
  fi

  previous_generation="$(jq -r '.generation // 1' "${LEDGER_FILE}" 2>/dev/null || true)"
  [[ "${previous_generation}" =~ ^[0-9]+$ ]] || previous_generation=1
  next_generation=$((previous_generation + 1))
  created="$(jq -r '.created_ts // empty' "${LEDGER_FILE}" 2>/dev/null || true)"
  [[ "${created}" =~ ^[0-9]+$ ]] || created="$(now_epoch)"
  now="$(now_epoch)"

  normalized="$(printf '%s' "${payload}" | jq -c \
    --slurpfile old "${LEDGER_FILE}" \
    --argjson now "${now}" \
    --argjson created "${created}" \
    --argjson generation "${next_generation}" \
    --argjson prompt_ts "${_coverage_prompt_ts}" \
    --argjson prompt_revision "${_coverage_prompt_revision}" \
    --argjson cycle_id "${_coverage_cycle_id}" '
      ($old[0].selections // []) as $old_selections
      | del(.version,.created_ts,.updated_ts,.objective_prompt_ts,.objective_prompt_revision,.objective_cycle_id,
            .generation,.lifecycle,.completion)
      | .selections |= map(
          . as $selection
          | ([$old_selections[]
                | select(.agent == $selection.agent and .phase == $selection.phase)] | first // {}) as $prior
          | del(.resolved_agent,.added_generation)
          | . + {added_generation:($prior.added_generation // $generation)}
          | if (($prior.resolved_agent // "") | length) > 0
            then . + {resolved_agent:$prior.resolved_agent}
            else . end
        )
      | . + {
          version:2,
          generation:$generation,
          lifecycle:.reconciliation.status,
          created_ts:$created,
          updated_ts:$now,
          objective_prompt_ts:$prompt_ts,
          objective_prompt_revision:$prompt_revision,
          objective_cycle_id:$cycle_id
        }
    ')"
  _write_ledger_unlocked "${normalized}" "0"
}

_complete_unlocked() {
  local now normalized status phase8_active phase8_prompt_revision ready_value
  _current_prompt_numbers_unlocked
  if ! _ledger_is_current_unlocked \
      || ! _validate_payload <"${LEDGER_FILE}" \
      || ! _validate_primary_envelope <"${LEDGER_FILE}" \
      || ! _validate_reconciled_payload <"${LEDGER_FILE}"; then
    printf 'record-council-coverage: complete requires a valid current-objective ledger\n' >&2
    return 11
  fi
  if jq -e 'has("completion")' "${LEDGER_FILE}" >/dev/null 2>&1; then
    printf 'record-council-coverage: this Council assessment is already complete\n' >&2
    return 12
  fi
  status="$(jq -r '.reconciliation.status // empty' "${LEDGER_FILE}" 2>/dev/null || true)"
  if [[ "${status}" != "primary-complete" && "${status}" != "gap-fill-complete" ]]; then
    printf 'record-council-coverage: complete requires final reconciliation (primary-complete or gap-fill-complete)\n' >&2
    return 13
  fi
  if ! _selection_returns_complete_unlocked "primary"; then
    printf 'record-council-coverage: complete requires every selected primary return\n' >&2
    return 14
  fi
  if jq -e 'any(.selections[]; .phase == "gap-fill")' "${LEDGER_FILE}" >/dev/null 2>&1 \
      && ! _selection_returns_complete_unlocked "gap-fill"; then
    printf 'record-council-coverage: complete requires every selected gap-fill return\n' >&2
    return 15
  fi
  if ! _no_current_council_pending_unlocked; then
    printf 'record-council-coverage: complete refused while a current Council round is still in flight\n' >&2
    return 16
  fi

  now="$(now_epoch)"
  normalized="$(jq -c \
    --argjson now "${now}" \
    --argjson prompt_ts "${_coverage_prompt_ts}" \
    --argjson prompt_revision "${_coverage_prompt_revision}" \
    --argjson cycle_id "${_coverage_cycle_id}" '
      .updated_ts = $now
      | .completion = {
          ts:$now,
          objective_prompt_ts:$prompt_ts,
          objective_prompt_revision:$prompt_revision,
          objective_cycle_id:$cycle_id
        }
    ' "${LEDGER_FILE}")"
  _write_ledger_unlocked "${normalized}" "0"
  phase8_active="$(read_state "council_phase8_active")"
  phase8_prompt_revision="$(read_state "council_phase8_prompt_revision")"
  ready_value="1"
  # A same-turn evaluate+implement request has already entered Phase 8. Its
  # completed assessment should not create a redundant next-turn handoff or
  # erase that authorization; advisory assessments arm ready=1 instead.
  if [[ "${phase8_active}" == "1" \
      && "${phase8_prompt_revision}" =~ ^[0-9]+$ \
      && "${phase8_prompt_revision}" -eq "${_coverage_prompt_revision}" ]]; then
    ready_value=""
  fi
  if [[ "${ready_value}" == "1" ]]; then
    write_state_batch \
      "council_assessment_ready" "${ready_value}" \
      "council_assessment_ts" "${now}" \
      "council_assessment_prompt_revision" "${_coverage_prompt_revision}" \
      "council_assessment_objective_prompt_ts" "${_coverage_prompt_ts}" \
      "council_phase8_active" "" \
      "council_phase8_prompt_revision" ""
  else
    write_state_batch \
      "council_assessment_ready" "${ready_value}" \
      "council_assessment_ts" "${now}" \
      "council_assessment_prompt_revision" "${_coverage_prompt_revision}" \
      "council_assessment_objective_prompt_ts" "${_coverage_prompt_ts}"
  fi
}

case "${COMMAND}" in
  init)
    payload="$(cat)"
    if ! printf '%s' "${payload}" | _validate_init_payload; then
      printf 'record-council-coverage: init requires 1-4 primary selections (or an evidenced >4 exception), zero gap-fill, and exact non-overlapping coverage\n' >&2
      exit 2
    fi
    with_state_lock _init_unlocked "${payload}"
    printf '%s\n' "${LEDGER_FILE}"
    ;;
  update)
    payload="$(cat)"
    if ! printf '%s' "${payload}" | _validate_payload \
        || ! printf '%s' "${payload}" | _validate_primary_envelope \
        || ! printf '%s' "${payload}" | _validate_reconciled_payload; then
      printf 'record-council-coverage: update requires complete primary reconciliation and at most two evidence-linked gap-fill selections\n' >&2
      exit 2
    fi
    with_state_lock _update_unlocked "${payload}"
    printf '%s\n' "${LEDGER_FILE}"
    ;;
  complete)
    with_state_lock _complete_unlocked
    printf '%s\n' "${LEDGER_FILE}"
    ;;
  validate)
    [[ -f "${LEDGER_FILE}" ]] \
      && _validate_payload <"${LEDGER_FILE}" \
      && _validate_primary_envelope <"${LEDGER_FILE}" \
      && if [[ "$(jq -r '.generation // 1' "${LEDGER_FILE}")" == "1" ]]; then
           jq -e '
             .lifecycle == "primary"
             and ([.selections[] | select(.phase == "gap-fill")] | length) == 0
             and (has("reconciliation") | not)
           ' "${LEDGER_FILE}" >/dev/null
         else
           _validate_reconciled_payload <"${LEDGER_FILE}"
         fi
    ;;
  show)
    [[ -f "${LEDGER_FILE}" ]] || { printf 'record-council-coverage: no ledger\n' >&2; exit 1; }
    jq . "${LEDGER_FILE}"
    ;;
  path)
    printf '%s\n' "${LEDGER_FILE}"
    ;;
  *)
    printf 'Usage: %s init|update|complete|validate|show|path\n' "$0" >&2
    exit 2
    ;;
esac
