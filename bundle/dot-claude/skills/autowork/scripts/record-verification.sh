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
# v1.47 (sre-lens R-1): observable fail-open for verification-evidence capture.
omc_arm_failopen_err_trap "record-verification" "(verification evidence for this tool result was not recorded)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi
capture_ulw_enforcement_interval || exit 0

# Determine verification source: Bash command or MCP tool
tool_name="$(json_get '.tool_name' 2>/dev/null || true)"
command_text=""
mcp_verify_type=""
source_verify_type=""
mcp_mutating=0
tool_input_json="{}"
tool_use_id="$(json_get '.tool_use_id' 2>/dev/null || true)"

if [[ "${tool_name}" == "Bash" || -z "${tool_name}" ]]; then
  command_text="$(json_get '.tool_input.command' 2>/dev/null || true)"
elif [[ "${tool_name}" == "Read" ]]; then
  source_verify_type="source"
elif [[ "${tool_name}" == "Grep" ]]; then
  source_verify_type="inspection"
else
  tool_input_json="$(jq -c '.tool_input // {}' <<<"${HOOK_JSON}" 2>/dev/null || printf '{}')"
  if mcp_tool_attempts_artifact_mutation "${tool_name}" "${tool_input_json}"; then
    mcp_mutating=1
  fi
  # Check if this MCP tool qualifies as verification
  mcp_verify_type="$(classify_mcp_verification_tool "${tool_name}")"
fi

_verification_start_path() {
  local _id="$1" _digest=""
  [[ -n "${_id}" ]] || return 1
  _digest="$(_omc_token_digest "${_id}" 2>/dev/null || true)"
  [[ -n "${_digest}" ]] || return 1
  printf '%s/%s/.verification-starts/%s.json\n' \
    "${STATE_ROOT}" "${SESSION_ID}" "${_digest}"
}

_discard_verification_start_locked() {
  local _path=""
  _path="$(_verification_start_path "${tool_use_id}" 2>/dev/null || true)"
  [[ -n "${_path}" ]] && rm -f "${_path}" 2>/dev/null || true
}

# Connector calls run independent PostToolUse hooks in parallel. A mutating
# connector must never mint proof for the same call merely because its name
# also resembles a browser/check tool; consume its start snapshot here and let
# mark-edit.sh advance the mutation clocks.
if [[ "${mcp_mutating}" -eq 1 ]]; then
  with_state_lock _discard_verification_start_locked || true
  exit 0
fi

# Consume the PreToolUse snapshot and persist the result under one state lock.
# Return codes 10-13 are expected fail-closed rejections, not hook crashes.
# In every rejection path, prior last_verify_* evidence stays untouched.
_record_verification_state() {
  local _path="" _start_revision="" _stored_id="" _stored_tool=""
  local _current_revision="" _reason="" _stale_count=""
  local _start_edit_revision="" _start_plan_revision="" _start_cycle=""
  local _start_contract_id="" _start_contract_revision="" _start_input_digest=""
  local _current_edit_revision="" _current_plan_revision="" _current_contract=""

  # Stop or /ulw-off may have finalized this interval while the PostToolUse
  # callback waited for the session lock. Never publish late proof.
  is_ultrawork_mode || return 20

  _path="$(_verification_start_path "${tool_use_id}" 2>/dev/null || true)"
  _current_revision="$(read_state "last_code_edit_revision")"
  [[ "${_current_revision}" =~ ^[0-9]+$ ]] || _current_revision="0"

  if [[ -z "${tool_use_id}" ]] || [[ -z "${_path}" ]] || [[ ! -f "${_path}" ]]; then
    _reason="missing_start_snapshot"
  else
    _stored_id="$(jq -r '.tool_use_id // empty' "${_path}" 2>/dev/null || true)"
    _stored_tool="$(jq -r '.tool_name // empty' "${_path}" 2>/dev/null || true)"
    _start_revision="$(jq -r '.code_revision // empty' "${_path}" 2>/dev/null || true)"
    _start_edit_revision="$(jq -r '.edit_revision // empty' "${_path}" 2>/dev/null || true)"
    _start_plan_revision="$(jq -r '.plan_revision // empty' "${_path}" 2>/dev/null || true)"
    _start_cycle="$(jq -r '.review_cycle_id // empty' "${_path}" 2>/dev/null || true)"
    _start_contract_id="$(jq -r '.quality_contract_id // empty' "${_path}" 2>/dev/null || true)"
    _start_contract_revision="$(jq -r '.quality_contract_revision // empty' "${_path}" 2>/dev/null || true)"
    _start_input_digest="$(jq -r '.input_digest // empty' "${_path}" 2>/dev/null || true)"
    # Consume before any state write so a duplicate completion cannot replay
    # the same dispatch evidence. The enclosing state lock serializes peers.
    rm -f "${_path}" 2>/dev/null || true

    if [[ "${_stored_id}" != "${tool_use_id}" ]] \
        || [[ "${_stored_tool}" != "${tool_name}" ]]; then
      _reason="start_snapshot_identity_mismatch"
    elif [[ ! "${_start_revision}" =~ ^[0-9]+$ ]]; then
      _reason="invalid_start_snapshot"
    elif [[ "${_start_revision}" != "${_current_revision}" ]]; then
      _reason="code_revision_changed"
    elif [[ "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]]; then
      _current_edit_revision="$(read_state "edit_revision" 2>/dev/null || true)"
      _current_plan_revision="$(read_state "plan_revision" 2>/dev/null || true)"
      [[ "${_current_edit_revision}" =~ ^[0-9]+$ ]] || _current_edit_revision=0
      [[ "${_current_plan_revision}" =~ ^[0-9]+$ ]] || _current_plan_revision=0
      if [[ ! "${_start_edit_revision}" =~ ^[0-9]+$ \
          || ! "${_start_plan_revision}" =~ ^[0-9]+$ \
          || ! "${_start_cycle}" =~ ^[0-9]+$ \
          || ! "${_start_contract_revision}" =~ ^[1-9][0-9]*$ \
          || ! "${_start_contract_id}" =~ ^qc-[A-Za-z0-9._:-]{8,80}$ \
          || ! "${_start_input_digest}" =~ ^[A-Za-z0-9._:-]{8,80}$ ]]; then
        _reason="invalid_definition_start_snapshot"
      elif [[ "${_start_edit_revision}" != "${_current_edit_revision}" ]]; then
        _reason="edit_revision_changed"
      elif [[ "${_start_plan_revision}" != "${_current_plan_revision}" ]]; then
        _reason="plan_revision_changed"
      elif ! _omc_load_quality_contract 2>/dev/null \
          || ! _current_contract="$(quality_contract_validate_current 2>/dev/null)"; then
        _reason="quality_contract_stale"
      elif [[ "${_start_contract_id}" != "$(jq -r '.contract_id' <<<"${_current_contract}")" \
          || "${_start_contract_revision}" != "$(jq -r '.contract_revision' <<<"${_current_contract}")" \
          || "${_start_cycle}" != "$(jq -r '.review_cycle_id' <<<"${_current_contract}")" ]]; then
        _reason="quality_contract_changed"
      fi
    fi
  fi

  if [[ -n "${_reason}" ]]; then
    _stale_count="$(read_state "stale_verify_count")"
    [[ "${_stale_count}" =~ ^[0-9]+$ ]] || _stale_count="0"
    _stale_count=$((_stale_count + 1))
    _write_state_batch_unlocked \
      "last_stale_verify_ts" "$(now_epoch)" \
      "last_stale_verify_tool" "${tool_name}" \
      "last_stale_verify_reason" "${_reason}" \
      "last_stale_verify_start_code_revision" "${_start_revision}" \
      "last_stale_verify_current_code_revision" "${_current_revision}" \
      "stale_verify_count" "${_stale_count}"
    _OMC_VERIFY_REJECTION_REASON="${_reason}"
    _OMC_VERIFY_REJECTION_START="${_start_revision}"
    _OMC_VERIFY_REJECTION_CURRENT="${_current_revision}"
    case "${_reason}" in
      missing_start_snapshot) return 10 ;;
      code_revision_changed) return 11 ;;
      invalid_start_snapshot) return 12 ;;
      *) return 13 ;;
    esac
  fi

  _verify_start_code_revision="${_start_revision}"
  _verify_start_edit_revision="${_start_edit_revision:-0}"
  _verify_start_plan_revision="${_start_plan_revision:-0}"
  _verify_start_cycle="${_start_cycle:-0}"
  _verify_start_contract_id="${_start_contract_id}"
  _verify_start_contract_revision="${_start_contract_revision:-0}"
  _verify_start_input_digest="${_start_input_digest}"
  if [[ "${_verification_receipt_only:-0}" -ne 1 ]]; then
    _write_state_batch_unlocked "$@" \
      "last_verify_code_revision" "${_start_revision}" || return 1
  fi
  if [[ "${_verification_receipt_ready:-0}" -eq 1 ]]; then
    _append_verification_receipt_unlocked || return 1
  fi
}

_persist_verification_state() {
  local _rc=0
  _OMC_VERIFY_REJECTION_REASON=""
  _OMC_VERIFY_REJECTION_START=""
  _OMC_VERIFY_REJECTION_CURRENT=""
  with_state_lock _record_verification_state "$@" || _rc=$?

  if [[ "${_rc}" -ge 10 && "${_rc}" -le 13 ]]; then
    log_hook "record-verification" \
      "rejected result tool=${tool_name} reason=${_OMC_VERIFY_REJECTION_REASON} start_revision=${_OMC_VERIFY_REJECTION_START} current_revision=${_OMC_VERIFY_REJECTION_CURRENT}"
    record_gate_event "verification" "stale-result-rejected" \
      "tool=${tool_name}" \
      "reason=${_OMC_VERIFY_REJECTION_REASON}" \
      "start_revision=${_OMC_VERIFY_REJECTION_START}" \
      "current_revision=${_OMC_VERIFY_REJECTION_CURRENT}" \
      2>/dev/null || true
    return 1
  elif [[ "${_rc}" -ne 0 ]]; then
    log_anomaly "record-verification" \
      "failed to atomically consume start snapshot and persist result rc=${_rc}"
    return 1
  fi
  return 0
}

_prepare_verification_receipt() {
  _receipt_command="${1:-}"
  _receipt_outcome="${2:-unknown}"
  _receipt_confidence="${3:-0}"
  _receipt_method="${4:-unknown}"
  _receipt_scope="${5:-unknown}"
  _receipt_result_raw="${6:-}"
  _receipt_evidence_kind="${7:-unknown}"
  _receipt_artifact_target="${8:-}"
  _receipt_artifact_digest="${9:-}"
  _verification_receipt_ready=1
}

_mcp_verification_target_descriptor() {
  local input_json="${1:-{}}" output="${2:-}" descriptor="" observed_url=""
  descriptor="$(jq -r '
    def leaf: ascii_downcase
      | . == "url" or . == "page_url" or . == "path" or . == "file_path"
        or . == "route" or . == "endpoint" or . == "selector"
        or . == "locator" or . == "target";
    [paths(scalars) as $p
      | select(($p[-1] | tostring | leaf))
      | (getpath($p) | tostring) as $v
      | select(($v | length) > 0)
      | {k:($p | map(tostring) | join(".")),
         v:(if (($p[-1] | tostring | ascii_downcase) | test("url|endpoint"))
            then ($v | sub("[?#].*$"; "")) else $v end)}]
    | sort_by(.k) | .[0:12]
    | map(.k + "=" + (.v[0:240])) | join(";")
  ' <<<"${input_json}" 2>/dev/null || true)"
  if [[ -z "${descriptor}" ]]; then
    observed_url="$(printf '%s\n' "${output}" \
      | sed -nE 's/.*(Page URL|URL):[[:space:]]*(https?:\/\/[^[:space:];]+).*/\2/p' \
      | head -1 | sed -E 's/[?#].*$//' || true)"
    [[ -z "${observed_url}" ]] || descriptor="observed_url=${observed_url}"
  fi
  descriptor="$(printf '%s' "${descriptor}" | omc_redact_secrets | tr -d '\000\r\n')"
  truncate_chars 1000 "${descriptor}"
}

# This runs inside the same session lock that consumes the PreTool sidecar and
# publishes last_verify_* state. Every Definition proof row therefore names a
# harness-minted receipt bound to the exact tool ID, contract, mutation/plan
# generations, observed outcome, and output digest. Reviewer prose never
# creates or edits these facts.
_append_verification_receipt_unlocked() {
  local command_safe proof_command result_excerpt result_digest command_digest proof_material
  local proof_identity receipt_identity receipt_id row confidence
  local prior_receipts prior_bytes prior_lines
  command_safe="$(printf '%s' "${_receipt_command:-}" \
    | omc_redact_secrets | tr -d '\000')"
  command_safe="$(truncate_chars 500 "${command_safe}")"
  proof_command="${command_safe}"
  if [[ "${tool_name}" == "Bash" ]]; then
    # Proof identity describes the executed check, not incidental shell-input
    # formatting. Collapse whitespace only outside quotes while preserving
    # quoted/escaped bytes, so `pytest  -q` and `pytest -q` are one proof but
    # distinct quoted test selectors remain distinct.
    proof_command="$(printf '%s' "${command_safe}" | awk '
      BEGIN { sq=0; dq=0; esc=0; pending=0; out="" }
      {
        for (i=1; i<=length($0); i++) {
          c=substr($0,i,1)
          if (esc) { if (pending) { out=out " "; pending=0 }; out=out c; esc=0; continue }
          if (c == "\\" && !sq) { if (pending) { out=out " "; pending=0 }; out=out c; esc=1; continue }
          if (c == "\047" && !dq) { if (pending) { out=out " "; pending=0 }; sq=!sq; out=out c; continue }
          if (c == "\"" && !sq) { if (pending) { out=out " "; pending=0 }; dq=!dq; out=out c; continue }
          if (c ~ /[[:space:]]/ && !sq && !dq) { if (length(out)>0) pending=1; continue }
          if (pending) { out=out " "; pending=0 }
          out=out c
        }
      }
      END { print out }
    ')"
  fi
  command_digest="$(_omc_token_digest "${proof_command}" 2>/dev/null || true)"
  result_digest="$(_omc_token_digest "${_receipt_result_raw:-}" 2>/dev/null || true)"
  [[ -n "${command_digest}" && -n "${result_digest}" ]] || return 1
  confidence="${_receipt_confidence:-0}"
  [[ "${confidence}" =~ ^[0-9]+$ ]] || confidence=0
  result_excerpt="$(printf '%s\n' "${_receipt_result_raw:-}" \
    | omc_redact_secrets \
    | tr -d '\000' \
    | grep -Ei '([0-9]+[[:space:]]+(passed|failed|errors?|tests?|specs?|checks?)|pass(ed)?|fail(ed)?|error|exit (code|status)|success|match|found|render)' 2>/dev/null \
    | tail -5 \
    | tr '\n\r\t' '   ' \
    | sed -E 's/[[:space:]]+/ /g' || true)"
  result_excerpt="$(truncate_chars 500 "${result_excerpt:-${_receipt_outcome:-unknown}}")"
  proof_material="$(jq -cnS \
    --arg tool_name "${tool_name}" --arg command_digest "${command_digest}" \
    --arg artifact_target "${_receipt_artifact_target:-}" \
    --arg evidence_kind "${_receipt_evidence_kind}" \
    --argjson edit_revision "${_verify_start_edit_revision:-0}" \
    --argjson plan_revision "${_verify_start_plan_revision:-0}" \
    --argjson review_cycle_id "${_verify_start_cycle:-0}" \
    --arg quality_contract_id "${_verify_start_contract_id:-}" \
    --argjson quality_contract_revision "${_verify_start_contract_revision:-0}" '
      {tool_name:$tool_name,command_digest:$command_digest,
       artifact_target:$artifact_target,
       evidence_kind:$evidence_kind,edit_revision:$edit_revision,
       plan_revision:$plan_revision,review_cycle_id:$review_cycle_id,
       quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision}')" || return 1
  proof_identity="vp-$(_omc_token_digest "${proof_material}" 2>/dev/null || true)"
  [[ "${proof_identity}" =~ ^vp-[A-Za-z0-9._:-]{8,80}$ ]] || return 1
  receipt_identity="$(jq -cnS \
    --arg tool_use_id "${tool_use_id}" --arg tool_name "${tool_name}" \
    --arg input_digest "${_verify_start_input_digest}" \
    --arg command_digest "${command_digest}" --arg result_digest "${result_digest}" \
    --arg outcome "${_receipt_outcome}" --argjson confidence "${confidence}" \
    --arg method "${_receipt_method}" --arg scope "${_receipt_scope}" \
    --arg evidence_kind "${_receipt_evidence_kind}" \
    --arg artifact_target "${_receipt_artifact_target:-}" \
    --arg artifact_digest "${_receipt_artifact_digest:-}" \
    --arg proof_identity "${proof_identity}" \
    --argjson edit_revision "${_verify_start_edit_revision:-0}" \
    --argjson code_revision "${_verify_start_code_revision:-0}" \
    --argjson plan_revision "${_verify_start_plan_revision:-0}" \
    --argjson review_cycle_id "${_verify_start_cycle:-0}" \
    --arg quality_contract_id "${_verify_start_contract_id:-}" \
    --argjson quality_contract_revision "${_verify_start_contract_revision:-0}" '
      {tool_use_id:$tool_use_id,tool_name:$tool_name,input_digest:$input_digest,
       command_digest:$command_digest,result_digest:$result_digest,
       outcome:$outcome,confidence:$confidence,method:$method,scope:$scope,
       evidence_kind:$evidence_kind,artifact_target:$artifact_target,
       artifact_digest:$artifact_digest,proof_identity:$proof_identity,
       edit_revision:$edit_revision,
       code_revision:$code_revision,plan_revision:$plan_revision,
       review_cycle_id:$review_cycle_id,quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision}'
  )" || return 1
  receipt_id="vr-$(_omc_token_digest "${receipt_identity}" 2>/dev/null || true)"
  [[ "${receipt_id}" =~ ^vr-[A-Za-z0-9._:-]{8,80}$ ]] || return 1
  row="$(jq -cnS \
    --argjson _v 2 --arg receipt_id "${receipt_id}" \
    --arg tool_use_id "${tool_use_id}" --arg tool_name "${tool_name}" \
    --arg input_digest "${_verify_start_input_digest}" \
    --arg command "${command_safe}" --arg command_digest "${command_digest}" \
    --arg outcome "${_receipt_outcome}" --argjson confidence "${confidence}" \
    --arg method "${_receipt_method}" --arg scope "${_receipt_scope}" \
    --arg evidence_kind "${_receipt_evidence_kind}" --arg result "${result_excerpt}" \
    --arg result_digest "${result_digest}" \
    --arg artifact_target "${_receipt_artifact_target:-}" \
    --arg artifact_digest "${_receipt_artifact_digest:-}" \
    --arg proof_identity "${proof_identity}" \
    --argjson edit_revision "${_verify_start_edit_revision:-0}" \
    --argjson code_revision "${_verify_start_code_revision:-0}" \
    --argjson plan_revision "${_verify_start_plan_revision:-0}" \
    --argjson review_cycle_id "${_verify_start_cycle:-0}" \
    --arg quality_contract_id "${_verify_start_contract_id:-}" \
    --argjson quality_contract_revision "${_verify_start_contract_revision:-0}" \
    --argjson ts "$(now_epoch)" '
      {_v:$_v,receipt_id:$receipt_id,tool_use_id:$tool_use_id,
       tool_name:$tool_name,input_digest:$input_digest,command:$command,
       command_digest:$command_digest,outcome:$outcome,confidence:$confidence,
       method:$method,scope:$scope,evidence_kind:$evidence_kind,result:$result,
       result_digest:$result_digest,artifact_target:$artifact_target,
       artifact_digest:$artifact_digest,proof_identity:$proof_identity,
       edit_revision:$edit_revision,
       code_revision:$code_revision,plan_revision:$plan_revision,
       review_cycle_id:$review_cycle_id,quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision,ts:$ts}'
  )" || return 1
  local ledger source tmp retention_contract="null" evidence_ledger
  local current_frontier_file current_frontier current_frontier_receipt_ids='[]'
  local frontier_history frontier_history_parsed frontier_receipt_ids='[]'
  local protected_receipt_ids='[]'
  ledger="$(session_file "verification_receipts.jsonl")"
  [[ ! -L "${ledger}" ]] \
    && { [[ ! -e "${ledger}" ]] || [[ -f "${ledger}" ]]; } || return 1
  source="${ledger}"
  [[ -f "${source}" ]] || source="/dev/null"
  # Retention is a compactor, never a repair authority. Before any group/tail
  # rewrite, require every existing Definition receipt to be valid under the
  # exact production schema and require receipt IDs to remain unique. The
  # higher pre-compaction ceiling intentionally admits the bounded 520-row
  # stress case; the gate's normal 512-row ceiling still applies after rewrite.
  if [[ -n "${_verify_start_contract_id:-}" && -s "${source}" ]]; then
    prior_bytes="$(wc -c <"${source}" | tr -d '[:space:]')"
    prior_lines="$(wc -l <"${source}" | tr -d '[:space:]')"
    [[ "${prior_bytes}" =~ ^[0-9]+$ && "${prior_bytes}" -le 2097152 \
        && "${prior_lines}" =~ ^[0-9]+$ && "${prior_lines}" -le 2048 ]] \
      || return 1
    prior_receipts="$(jq -sc '.' "${source}" 2>/dev/null)" || return 1
    declare -F _quality_contract_receipts_schema_valid >/dev/null 2>&1 \
      || return 1
    _quality_contract_receipts_schema_valid "${prior_receipts}" 2048 || return 1
  fi
  tmp="$(mktemp "${ledger}.tmp.XXXXXX")" || return 1
  chmod 600 "${tmp}" 2>/dev/null || true
  if [[ -n "${_verify_start_contract_id:-}" ]]; then
    retention_contract="$(jq -ce \
      --arg id "${_verify_start_contract_id}" \
      --argjson rev "${_verify_start_contract_revision:-0}" \
      'select(.contract_id == $id and .contract_revision == $rev)' \
      "$(session_file "quality_contract.json")" 2>/dev/null || printf 'null')"
  fi
  evidence_ledger="$(session_file "quality_evidence.jsonl")"
  if [[ -f "${evidence_ledger}" && ! -L "${evidence_ledger}" ]]; then
    protected_receipt_ids="$(jq -Rsc \
      --arg contract "${_verify_start_contract_id:-}" \
      --argjson revision "${_verify_start_contract_revision:-0}" \
      --argjson edit "${_verify_start_edit_revision:-0}" \
      --argjson plan "${_verify_start_plan_revision:-0}" '
        [split("\n")[] | select(length > 0) | (try fromjson catch empty)
          | select(.contract_id == $contract
            and .contract_revision == $revision
            and .edit_revision == $edit and .plan_revision == $plan)
          | .receipt_id
          | select(type == "string" and test("^vr-[A-Za-z0-9._:-]{8,80}$"))]
        | unique | .[-32:]
      ' "${evidence_ledger}" 2>/dev/null || printf '[]')"
  fi
  # An additive, floor-preserving re-contract retains an accepted open frontier
  # pair as redundant causal authority while its old contract coordinates keep
  # it ineligible for certification. Preserve the bounded receipt portfolio it
  # names even after the contract advances. This lets remediation survive later
  # history loss/corruption instead of turning a fail-closed finding into either
  # a silent release or an unrecoverable missing-receipt deadlock.
  current_frontier_file="$(session_file "quality_frontier.json")"
  if [[ -f "${current_frontier_file}" && ! -L "${current_frontier_file}" \
      && "${_verify_start_cycle:-0}" =~ ^[1-9][0-9]*$ ]]; then
    current_frontier="$(_quality_contract_read_json_file \
      "${current_frontier_file}" 65536 2>/dev/null || true)"
    if [[ -n "${current_frontier}" ]] \
        && _quality_contract_frontier_schema_valid "${current_frontier}" \
        && [[ "$(jq -r '.status' <<<"${current_frontier}")" == "open" ]] \
        && [[ "$(jq -r '.review_cycle_id' <<<"${current_frontier}")" \
          == "${_verify_start_cycle}" ]]; then
      current_frontier_receipt_ids="$(jq -c '.evidence | unique' \
        <<<"${current_frontier}")" || return 1
      protected_receipt_ids="$(jq -cn \
        --argjson accepted "${protected_receipt_ids}" \
        --argjson frontier "${current_frontier_receipt_ids}" \
        '$accepted + $frontier | unique')" || return 1
    fi
  fi

  # History remains the compatibility/fallback authority for an additive
  # re-contract produced before open-pair carryover existed. A later clear
  # review still needs every affected criterion backed by causally newer,
  # distinct proof; the generic four-row receipt tail is too small for the
  # protocol's mandatory five-axis floor.
  #
  # Use the same authoritative history parser as record-reviewer and reporting,
  # so retention and admission agree about which ordered same-cycle row is
  # current. A later clear row releases the preservation set. The row schema
  # bounds `.evidence` to 20 unique receipt IDs, while current accepted evidence
  # is independently bounded by the contract ceiling.
  frontier_history="$(session_file "quality_frontier_history.jsonl")"
  if [[ -f "${frontier_history}" && ! -L "${frontier_history}" \
      && "${_verify_start_cycle:-0}" =~ ^[1-9][0-9]*$ ]]; then
    frontier_history_parsed="$(_quality_frontier_history_parse \
      "${frontier_history}" 2>/dev/null || true)"
    if [[ -n "${frontier_history_parsed}" ]]; then
      frontier_receipt_ids="$(jq -c \
        --argjson cycle "${_verify_start_cycle}" '
          [.rows[] | select(.review_cycle_id == $cycle)]
          | if length > 0 and .[-1].status == "open"
            then .[-1].evidence
            else []
            end
        ' <<<"${frontier_history_parsed}" 2>/dev/null || printf '[]')"
      protected_receipt_ids="$(jq -cn \
        --argjson accepted "${protected_receipt_ids}" \
        --argjson frontier "${frontier_receipt_ids}" \
        '$accepted + $frontier | unique')" || return 1
    fi
  fi
  # Keep a bounded, criterion-aware proof portfolio. For each live criterion,
  # retain the newest independent proof identities needed by its minimum plus
  # one diagnostic spare; then add only a tiny recent/live and history tail.
  # This prevents high-volume observation from evicting required proof without
  # letting hundreds of current receipts exceed the gate reader's byte cap.
  if ! jq -Rsr --arg row "${row}" \
      --arg contract "${_verify_start_contract_id:-}" \
      --argjson revision "${_verify_start_contract_revision:-0}" \
      --argjson edit "${_verify_start_edit_revision:-0}" \
      --argjson plan "${_verify_start_plan_revision:-0}" \
      --argjson protected "${protected_receipt_ids}" \
      --argjson definition "${retention_contract}" '
        def tool_match($pattern;$actual):
          if ($pattern | endswith("*")) then
            $actual | startswith($pattern[0:-1])
          else $actual == $pattern end;
        def matches($receipt;$criterion):
          ($criterion.proof_spec.receipt_kinds
            | index($receipt.evidence_kind)) != null
          and any($criterion.proof_spec.tool_names[];
            tool_match(.;$receipt.tool_name))
          and all($criterion.proof_spec.command_contains[];
            . as $token | ($receipt.command | ascii_downcase
              | contains($token | ascii_downcase)))
          and all($criterion.proof_spec.artifact_contains[];
            . as $token | ($receipt.artifact_target | ascii_downcase
              | contains($token | ascii_downcase)));
        def matching_ids($receipt):
          [$definition.definition.criteria[]
            | select(matches($receipt;.)) | .id];
        def observation_bearing($receipt):
          ($receipt.evidence_kind == "source")
          or ($receipt.evidence_kind == "inspection"
            and ($receipt.tool_name == "Read"
              or $receipt.tool_name == "Grep"
              or ($receipt.tool_name | startswith("mcp__"))))
          or ($receipt.evidence_kind == "render"
            and ($receipt.tool_name | startswith("mcp__")));
        # Retention rewrites the JSONL ledger, so second-resolution timestamps
        # cannot carry causal order. Attach the original append ordinal before
        # dedupe/portfolio selection and restore that order at the end; a later
        # failed proof must remain later than the approval receipt it invalidates.
        # The ledger is proof authority. Never "repair" malformed prior bytes
        # by silently dropping them during retention; leave the ledger intact
        # and let the gate expose the corruption.
        (([split("\n")[] | select(length > 0) | fromjson]
          + [($row | fromjson)])
          | to_entries
          | map(.value + {__omc_receipt_ordinal:.key})) as $rows
        | ([$rows[] | select(.quality_contract_id == $contract
              and .quality_contract_revision == $revision
              and .edit_revision == $edit and .plan_revision == $plan)]
            | sort_by(.__omc_receipt_ordinal)) as $live
        | ([$rows[] | .receipt_id as $id
              | select(($protected | index($id)) != null)]
            | sort_by(.__omc_receipt_ordinal)) as $accepted
        | if $definition == null then
            ((($rows | sort_by(.__omc_receipt_ordinal) | .[-64:]) + $accepted)
              | group_by(.receipt_id)
              | map(max_by(.__omc_receipt_ordinal))
              | sort_by(.__omc_receipt_ordinal))
          else
            ([$definition.definition.criteria[] as $criterion
              | ([$live[] | select(matches(.;$criterion))]
                  | group_by(.proof_identity)
                  | map(max_by(.__omc_receipt_ordinal))
                  | sort_by(.__omc_receipt_ordinal)) as $matches
              | ($criterion.evidence_policy.minimum + 1) as $keep
              | $matches[(-$keep):][]]) as $criterion_proof
            # An accepted review is invalidated by any later matching failure
            # until a reviewer accepts causally newer proof. A stream of fresh
            # unreviewed passes must not compact that negative receipt away and
            # resurrect the old approval. Preserve the newest post-accept
            # failure per criterion independently of the ordinary spare proof
            # portfolio (which dedupes by proof identity/outcome-agnostic key).
            | ([$definition.definition.criteria[] as $criterion
              | ([$accepted[] | select(matches(.;$criterion))
                    | .__omc_receipt_ordinal] | max // -1) as $accepted_ordinal
              | [$live[] | select(matches(.;$criterion)
                    and .outcome == "failed"
                    and (observation_bearing(.) | not)
                    and .__omc_receipt_ordinal > $accepted_ordinal)]
              | .[-1:][]]) as $invalidating_failures
            # Successful observational calls have reviewer-owned semantics: a
            # later observation may reveal either side of the criterion and
            # therefore requires a fresh independent assessment. Preserve the
            # newest uniquely matching post-review observation until a reviewer
            # cites it. Failed observations are unavailable data, not semantic
            # counterproof, and deliberately receive neither retention class.
            | ([$definition.definition.criteria[] as $criterion
              | ([$accepted[] | select(matches(.;$criterion))
                    | .__omc_receipt_ordinal] | max // -1) as $accepted_ordinal
              | [$live[] | select(matches(.;$criterion)
                    and $accepted_ordinal >= 0
                    and .outcome == "passed"
                    and observation_bearing(.)
                    and matching_ids(.) == [$criterion.id]
                    and .__omc_receipt_ordinal > $accepted_ordinal)]
              | .[-1:][]]) as $unreviewed_observations
            | ([$rows[] | select((.quality_contract_id == $contract
              and .quality_contract_revision == $revision
              and .edit_revision == $edit and .plan_revision == $plan) | not)]
                | sort_by(.__omc_receipt_ordinal) | .[-4:]) as $history
            | (($history + $criterion_proof + $invalidating_failures
                  + $unreviewed_observations
                  + ($live[-8:]) + $accepted)
                | group_by(.receipt_id)
                | map(max_by(.__omc_receipt_ordinal))
                | sort_by(.__omc_receipt_ordinal))
          end
        | .[] | del(.__omc_receipt_ordinal) | @json
      ' "${source}" >"${tmp}" \
      || ! mv -f "${tmp}" "${ledger}"; then
    rm -f "${tmp}" 2>/dev/null || true
    return 1
  fi
}

_verification_receipt_ready=0
_verification_receipt_only=0

# The dispatcher runs mark-edit before this handler. When that handler proved
# (or conservatively recorded) an edit-bearing Bash call, it leaves a per-tool marker here.
# A compound `tests; mutate` call must not count as verification of the bytes
# written after the tests; conservatively require a separate verification
# call for every edit-bearing Bash invocation, regardless of segment order.
if [[ "${tool_name}" == "Bash" ]] && [[ -n "${command_text}" ]]; then
  tool_cwd="$(json_get '.cwd' 2>/dev/null || true)"
  tool_cwd="${tool_cwd:-${PWD}}"
  if consume_bash_edit_outcome "${tool_use_id}" "${tool_cwd}" "${command_text}"; then
    with_state_lock _discard_verification_start_locked || true
    log_hook "record-verification" "skipped compound Bash verification because the same tool call changed the worktree"
    exit 0
  fi
fi

# Exit if neither Bash verification command, source inspection, nor MCP verification tool
if [[ -z "${command_text}" && -z "${mcp_verify_type}" \
    && -z "${source_verify_type}" ]]; then
  with_state_lock _discard_verification_start_locked || true
  exit 0
fi

# Extract tool output (shared by both paths)
tool_output="$(json_get '.tool_response' 2>/dev/null || true)"
if [[ -z "${tool_output}" ]]; then
  tool_output="$(json_get '.tool_result' 2>/dev/null || true)"
fi
if [[ -z "${tool_output}" ]]; then
  # PostToolUseFailure commonly carries a sparse top-level error instead of a
  # normal result object. Preserve it in the negative receipt's result digest.
  tool_output="$(json_get '.error' 2>/dev/null || true)"
fi

# --- Path 1: Bash command verification ---
if [[ -n "${command_text}" ]]; then

  custom_patterns=""
  conf_file="${HOME}/.claude/oh-my-claude.conf"
  if [[ -f "${conf_file}" ]]; then
    custom_patterns="$(grep -E '^custom_verify_patterns=' "${conf_file}" | head -1 | cut -d= -f2-)" || true
  fi

  builtin_pattern='(^|[[:space:]])(npm|pnpm|yarn|bun|cargo|go|pytest|python|uv|ruff|mypy|eslint|tsc|vitest|jest|phpunit|rspec|gradle|xcodebuild|swift|make|just|bash|docker|terraform|ansible|helm|kubectl|mvn|maven|dotnet|mix|elixir|ruby|bundle|rake|zig|deno|nix|markdownlint|mdl|vale|textlint|alex|aspell|hunspell|languagetool|write-good)([[:space:]].*)?(test|tests|check|lint|typecheck|build|validate|verify|plan|apply)|\b(pytest|vitest|jest|cargo test|go test|swift test|swift build|ruff check|mypy|eslint|tsc|typecheck|phpunit|rspec|gradle test|xcodebuild test|shellcheck|bash -n|docker build|docker compose build|terraform plan|terraform validate|ansible-lint|helm lint|mvn test|mvn verify|dotnet test|mix test|bundle exec rspec|rake test|zig build|deno test|nix build|markdownlint|mdl|vale|textlint|alex|write-good)\b'
  if [[ -n "${custom_patterns}" ]]; then
    _custom_rc=0
    printf 'test' | grep -Eq "${custom_patterns}" 2>/dev/null || _custom_rc=$?
    if [[ "${_custom_rc}" -eq 2 ]]; then
      log_hook "record-verification" "invalid custom_verify_patterns syntax, ignoring"
    else
      builtin_pattern="${builtin_pattern}|${custom_patterns}"
    fi
  fi

  if grep -Eiq "${builtin_pattern}" <<<"${command_text}" 2>/dev/null; then

    verify_outcome="passed"
    if [[ -n "${tool_output}" ]]; then
      if printf '%s' "${tool_output}" | grep -Eq '\b(FAIL(ED)?|ERROR(S)?|FAILURE(S)?)\b|error\[E[0-9]' \
        || printf '%s' "${tool_output}" | grep -Eiq 'exit (code|status)[: ]*[1-9]|[1-9][0-9]* (failed|failing|failures?|errors?)'; then
        verify_outcome="failed"
      fi
    fi
    if omc_hook_tool_failed "${HOOK_JSON}"; then
      verify_outcome="failed"
    fi

    project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
    if [[ -z "${project_test_cmd}" ]]; then
      project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
    fi

    if [[ "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]] \
        && ! verification_command_is_authoritative_execution \
          "${command_text}" "${project_test_cmd}"; then
      with_state_lock _discard_verification_start_locked || true
      log_hook "record-verification" \
        "rejected Definition proof from non-executing or compound command"
      record_gate_event "definition-of-excellent/verification" \
        "non-authoritative-command" "tool=Bash" 2>/dev/null || true
      exit 0
    fi

    verify_confidence="$(score_verification_confidence "${command_text}" "${tool_output}" "${project_test_cmd}")"
    verify_method="$(detect_verification_method "${command_text}" "${tool_output}" "${project_test_cmd}")"
    verify_scope="$(classify_verification_scope "${command_text}" "${project_test_cmd}")"
    # v1.27.0 (F-023): persist per-factor breakdown so /ulw-status can
    # explain WHY a verification scored what it did. Empty/short cmds
    # produce "test_match:0|framework:0|output_counts:0|clear_outcome:0|total:0".
    verify_factors="$(score_verification_confidence_factors "${command_text}" "${tool_output}" "${project_test_cmd}")"

    # v1.34.1+ (security-lens Z-003): redact obvious secret patterns
    # from the captured verification command BEFORE persisting to state.
    # Closes a real leak: a model running `pytest --auth-token=$X tests/`
    # would otherwise land $X verbatim in last_verify_cmd, where
    # omc-repro bundles it for support tarballs. Cap to 500 chars too.
    last_verify_cmd_safe="$(printf '%s' "${command_text}" | omc_redact_secrets | tr -d '\000')"
    last_verify_cmd_safe="$(truncate_chars 500 "${last_verify_cmd_safe}")"
    verify_evidence_kind="$(verification_receipt_evidence_kind \
      "${verify_method}" "${verify_scope}" "${command_text}")"
    _prepare_verification_receipt "${last_verify_cmd_safe}" "${verify_outcome}" \
      "${verify_confidence}" "${verify_method}" "${verify_scope}" \
      "${tool_output}" "${verify_evidence_kind}" "" ""
    if _persist_verification_state \
      "last_verify_ts" "$(now_epoch)" \
      "last_verify_cmd" "${last_verify_cmd_safe}" \
      "last_verify_outcome" "${verify_outcome}" \
      "last_verify_confidence" "${verify_confidence}" \
      "last_verify_factors" "${verify_factors}" \
      "last_verify_method" "${verify_method}" \
      "last_verify_scope" "${verify_scope}" \
      "project_test_cmd" "${project_test_cmd}" \
      "stop_guard_blocks" "0" \
      "session_handoff_blocks" "0" \
      "stall_counter" "0"; then
      log_hook "record-verification" "cmd=${command_text} outcome=${verify_outcome} confidence=${verify_confidence} method=${verify_method} scope=${verify_scope}"
    fi
  else
    # The PreToolUse recorder snapshots all Bash calls because command
    # classification can evolve independently. Non-verification completions
    # consume their snapshot so long sessions do not accumulate sidecars.
    with_state_lock _discard_verification_start_locked || true
  fi

# --- Path 2: MCP tool verification ---
elif [[ -n "${source_verify_type}" ]]; then
  source_path="$(json_get '.tool_input.file_path' 2>/dev/null || true)"
  [[ -n "${source_path}" ]] || source_path="$(json_get '.tool_input.path' 2>/dev/null || true)"
  source_pattern="$(json_get '.tool_input.pattern' 2>/dev/null || true)"
  source_cwd="$(json_get '.cwd' 2>/dev/null || true)"
  source_cwd="${source_cwd:-${PWD}}"
  source_target=""
  source_digest=""
  if [[ -n "${source_path}" ]]; then
    if [[ "${source_path}" != /* ]]; then source_path="${source_cwd%/}/${source_path}"; fi
    source_parent="${source_path%/*}"
    [[ "${source_parent}" == "${source_path}" ]] && source_parent="."
    source_base="${source_path##*/}"
    canonical_parent="$(cd "${source_parent}" 2>/dev/null && pwd -P || true)"
    canonical_root="$(git -C "${source_cwd}" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "${canonical_root}" ]] || canonical_root="$(cd "${source_cwd}" 2>/dev/null && pwd -P || true)"
    if [[ -n "${canonical_parent}" && -n "${canonical_root}" ]]; then
      source_target="${canonical_parent}/${source_base}"
      case "${source_target}" in
        "${canonical_root}"|"${canonical_root}"/*) ;;
        *) source_target="" ;;
      esac
    fi
  fi
  if [[ "${source_verify_type}" == "source" ]]; then
    if [[ -n "${source_target}" && -f "${source_target}" \
        && ! -L "${source_target}" ]]; then
      source_digest="$(_omc_digest_file "${source_target}" 2>/dev/null || true)"
    fi
  elif [[ -n "${source_target}" && -e "${source_target}" \
      && ! -L "${source_target}" ]]; then
    source_digest="$(_omc_token_digest "${tool_output}" 2>/dev/null || true)"
  fi
  source_outcome="passed"
  if omc_hook_tool_failed "${HOOK_JSON}" \
      || [[ -z "${source_target}" || -z "${source_digest}" ]]; then
    source_outcome="failed"
  fi
  source_confidence=70
  source_method="source_${source_verify_type}"
  source_scope="workspace_source"
  source_command="${tool_name}:${source_target:-invalid}"
  [[ -z "${source_pattern}" ]] \
    || source_command="${source_command}:$(truncate_chars 120 "${source_pattern}")"
  _prepare_verification_receipt "${source_command}" "${source_outcome}" \
    "${source_confidence}" "${source_method}" "${source_scope}" \
    "${tool_output}" "${source_verify_type}" "${source_target}" "${source_digest}"
  # Source inspection is criterion-scoped Definition evidence. It must never
  # overwrite the universal executable-test state and let a Read masquerade as
  # a post-edit test run.
  _verification_receipt_only=1
  if _persist_verification_state; then
    log_hook "record-verification" "source_tool=${tool_name} target=${source_target:-invalid} outcome=${source_outcome}"
  fi
  _verification_receipt_only=0

# --- Path 3: MCP tool verification ---
elif [[ -n "${mcp_verify_type}" ]]; then

  # Determine UI context: did recent edits include UI files?
  has_ui_context="false"
  edited_log="$(session_file "edited_files.log" 2>/dev/null || true)"
  if [[ -f "${edited_log}" ]]; then
    while IFS= read -r _path; do
      if is_ui_path "${_path}"; then
        has_ui_context="true"
        break
      fi
    done < <(sort -u "${edited_log}" 2>/dev/null || true)
  fi

  verify_outcome="$(detect_mcp_verification_outcome "${tool_output}" "${mcp_verify_type}")"
  # Text heuristics may classify a sparse connector failure as unknown (or
  # even infer success from incidental wording). The hook event/structured
  # failure envelope is authoritative and must dominate those heuristics.
  if omc_hook_tool_failed "${HOOK_JSON}"; then
    verify_outcome="failed"
  fi
  verify_confidence="$(score_mcp_verification_confidence "${mcp_verify_type}" "${tool_output}" "${has_ui_context}")"
  verify_scope="mcp_${mcp_verify_type}"

  # Detect project test command for remediation messaging (shared with Bash path)
  project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
  if [[ -z "${project_test_cmd}" ]]; then
    project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  fi

  verify_evidence_kind="$(verification_receipt_evidence_kind \
    "mcp_${mcp_verify_type}" "${verify_scope}" "${tool_name}")"
  mcp_target_descriptor="$(_mcp_verification_target_descriptor \
    "${tool_input_json}" "${tool_output}")"
  mcp_artifact_digest="$(_omc_token_digest \
    "${mcp_target_descriptor}|${tool_output}" 2>/dev/null || true)"
  mcp_receipt_command="${tool_name}"
  [[ -z "${mcp_target_descriptor}" ]] \
    || mcp_receipt_command="${mcp_receipt_command} ${mcp_target_descriptor}"
  _prepare_verification_receipt "${mcp_receipt_command}" "${verify_outcome}" \
    "${verify_confidence}" "mcp_${mcp_verify_type}" "${verify_scope}" \
    "${tool_output}" "${verify_evidence_kind}" \
    "${mcp_target_descriptor}" "${mcp_artifact_digest}"
  if _persist_verification_state \
    "last_verify_ts" "$(now_epoch)" \
    "last_verify_cmd" "${tool_name}" \
    "last_verify_outcome" "${verify_outcome}" \
    "last_verify_confidence" "${verify_confidence}" \
    "last_verify_method" "mcp_${mcp_verify_type}" \
    "last_verify_scope" "${verify_scope}" \
    "project_test_cmd" "${project_test_cmd}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "stall_counter" "0"; then
    log_hook "record-verification" "mcp_tool=${tool_name} type=${mcp_verify_type} outcome=${verify_outcome} confidence=${verify_confidence} scope=${verify_scope}"
  fi
fi
