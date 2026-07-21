#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): record/edit hooks have no classifier or timing-lib
# dependency — opt out of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

if [[ -z "${_OMC_HOOK_CALLER_PATH+x}" ]]; then
  _OMC_HOOK_CALLER_PATH="${PATH:-}"
fi
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
# v1.47 (sre-lens R-1): observable fail-open for verification-evidence capture.
omc_arm_failopen_err_trap "record-verification" "(verification evidence for this tool result was not recorded)"
HOOK_JSON="$(_omc_read_hook_stdin)"

_VERIFY_UINT_MAX=999999999999999

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 0

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
  _digest="$(_omc_authority_digest "${_id}" 2>/dev/null || true)"
  [[ -n "${_digest}" ]] || return 1
  printf '%s/%s/.verification-starts/%s.json\n' \
    "${STATE_ROOT}" "${SESSION_ID}" "${_digest}"
}

# A PreTool snapshot is one-shot causal authority. Move the exact regular node
# out of its public lookup pathname before reading any of its bytes. The move
# stays within .verification-starts, so it is an atomic rename on the same
# filesystem; the private directory is deliberately not addressable from a
# tool_use_id and therefore cannot be replayed by a second completion.
_consume_verification_start_locked() {
  local _path="${1:-}" _dir="" _private_dir="" _private_path=""
  _OMC_CONSUMED_VERIFICATION_START=""
  _OMC_CONSUMED_VERIFICATION_DIR=""
  [[ -n "${_path}" ]] || return 10
  _dir="${_path%/*}"
  [[ ! -L "${_dir}" && -d "${_dir}" ]] || return 12
  [[ -e "${_path}" || -L "${_path}" ]] || return 10
  [[ ! -L "${_path}" && -f "${_path}" ]] || return 12

  _private_dir="$(umask 077; mktemp -d \
    "${_dir}/.verification-consumed.XXXXXX" 2>/dev/null)" || return 13
  [[ -n "${_private_dir}" && ! -L "${_private_dir}" \
      && -d "${_private_dir}" ]] || return 13
  _private_path="${_private_dir}/snapshot"
  if [[ "${OMC_TEST_VERIFICATION_CONSUME_RENAME_FAIL:-0}" == "1" ]] \
      || ! mv -f "${_path}" "${_private_path}" 2>/dev/null; then
    rmdir "${_private_dir}" 2>/dev/null || true
    return 13
  fi
  if [[ -e "${_path}" || -L "${_path}" \
      || -L "${_private_path}" || ! -f "${_private_path}" ]]; then
    rm -f "${_private_path}" 2>/dev/null || true
    rmdir "${_private_dir}" 2>/dev/null || true
    return 13
  fi
  _OMC_CONSUMED_VERIFICATION_START="${_private_path}"
  _OMC_CONSUMED_VERIFICATION_DIR="${_private_dir}"
}

_release_consumed_verification_start_locked() {
  local _path="${_OMC_CONSUMED_VERIFICATION_START:-}"
  local _dir="${_OMC_CONSUMED_VERIFICATION_DIR:-}"
  [[ -n "${_path}" && ! -L "${_path}" && -f "${_path}" ]] || return 1
  rm -f "${_path}" 2>/dev/null || return 1
  [[ ! -e "${_path}" && ! -L "${_path}" ]] || return 1
  [[ -z "${_dir}" ]] || rmdir "${_dir}" 2>/dev/null || true
  _OMC_CONSUMED_VERIFICATION_START=""
  _OMC_CONSUMED_VERIFICATION_DIR=""
}

_discard_verification_start_locked() {
  local _path="" _consume_rc=0
  _path="$(_verification_start_path "${tool_use_id}" 2>/dev/null || true)"
  [[ -n "${_path}" ]] || return 0
  _consume_verification_start_locked "${_path}" || _consume_rc=$?
  case "${_consume_rc}" in
    0) _release_consumed_verification_start_locked ;;
    10) return 0 ;;
    *) return 1 ;;
  esac
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
  local _path="" _path_dir="" _snapshot_json="" _snapshot_size="" _consume_rc=0
  local _start_revision="" _stored_id="" _stored_tool=""
  local _current_revision="" _current_cycle="" _reason="" _stale_count=""
  local _start_edit_revision="" _start_plan_revision="" _start_cycle=""
  local _start_contract_id="" _start_contract_revision="" _start_input_digest=""
  local _current_edit_revision="" _current_plan_revision="" _current_contract=""
  local _current_input_json="" _current_input_digest=""
  local _start_launcher_path="" _start_launcher_digest=""
  local _start_launcher_identity="" _current_launcher_path=""
  local _current_launcher_digest="" _current_launcher_identity=""
  local _start_subject_path="" _start_subject_digest=""
  local _start_subject_identity="" _current_subject_path=""
  local _current_subject_digest="" _current_subject_identity=""
  local _start_tool_cwd="" _normalized_start_tool_cwd=""
  local _current_tool_cwd_raw="" _current_tool_cwd=""
  local _invalid_current_numeric_state=0

  # Stop or /ulw-off may have finalized this interval while the PostToolUse
  # callback waited for the session lock. Never publish late proof.
  is_ultrawork_mode || return 20

  _path="$(_verification_start_path "${tool_use_id}" 2>/dev/null || true)"
  _path_dir="${_path%/*}"
  _current_revision="$(read_state "last_code_edit_revision")"
  if [[ -z "${_current_revision}" ]]; then
    _current_revision="0"
  elif ! _omc_canonical_uint_in_range \
      "${_current_revision}" 0 "${_VERIFY_UINT_MAX}"; then
    _invalid_current_numeric_state=1
  fi
  _current_cycle="$(read_state "review_cycle_id")"
  if [[ -z "${_current_cycle}" ]]; then
    _current_cycle="0"
  elif ! _omc_canonical_uint_in_range \
      "${_current_cycle}" 0 "${_VERIFY_UINT_MAX}"; then
    _invalid_current_numeric_state=1
  fi
  _current_input_json="$(jq -cS '.tool_input // {}' \
    <<<"${HOOK_JSON}" 2>/dev/null || true)"
  _current_input_digest="$(_omc_authority_digest \
    "${_current_input_json}" 2>/dev/null || true)"
  _current_tool_cwd_raw="$(jq -r '.cwd // empty' \
    <<<"${HOOK_JSON}" 2>/dev/null || true)"
  _current_tool_cwd_raw="${_current_tool_cwd_raw:-${PWD}}"
  _current_tool_cwd="$(_verification_normalize_proof_path \
    "${_current_tool_cwd_raw}" 0 content 2>/dev/null || true)"

  if [[ -z "${tool_use_id}" ]] || [[ -z "${_path}" ]]; then
    _reason="missing_start_snapshot"
  else
    _consume_verification_start_locked "${_path}" || _consume_rc=$?
    case "${_consume_rc}" in
      0) ;;
      10) _reason="missing_start_snapshot" ;;
      12) _reason="invalid_start_snapshot" ;;
      *) _reason="start_snapshot_consume_failed" ;;
    esac
  fi

  if [[ -z "${_reason}" ]]; then
    # Parse only the atomically renamed private node. Parsing fields directly
    # from the public pathname would leave a successful result replayable when
    # removal fails and would permit replacement between individual reads.
    _snapshot_size="$(LC_ALL=C wc -c \
      <"${_OMC_CONSUMED_VERIFICATION_START}" 2>/dev/null \
      | tr -d '[:space:]')"
    if [[ ! "${_snapshot_size}" =~ ^[0-9]+$ \
        || "${_snapshot_size}" -lt 2 \
        || "${_snapshot_size}" -gt 65536 ]] \
        || ! _omc_regular_file_has_no_raw_nul \
          "${_OMC_CONSUMED_VERIFICATION_START}" 65536; then
      _snapshot_json=""
    else
      _snapshot_json="$(jq -cse '
      if length == 1 and (.[0] | type) == "object"
        and all(.[0] | .. | strings; index("\u0000") == null)
        and (.[0] | keys | sort == ["code_revision","edit_revision",
          "input_digest","launcher_digest","launcher_identity","launcher_path","plan_revision",
          "quality_contract_id","quality_contract_revision","review_cycle_id",
          "started_at","subject_digest","subject_identity","subject_path",
          "tool_cwd","tool_name","tool_use_id"])
        and (.[0].tool_use_id | type == "string"
          and length >= 1 and length <= 512
          and (test("[\u0000-\u001f\u007f]") | not))
        and (.[0].tool_name | type == "string"
          and test("^(Bash|Read|Grep|mcp__[A-Za-z0-9_.:-]{1,240})$"))
        and (.[0].code_revision | type == "number" and floor == .
          and . >= 0 and . <= 999999999999999)
        and (.[0].edit_revision | type == "number" and floor == .
          and . >= 0 and . <= 999999999999999)
        and (.[0].plan_revision | type == "number" and floor == .
          and . >= 0 and . <= 999999999999999)
        and (.[0].review_cycle_id | type == "number" and floor == .
          and . >= 0 and . <= 999999999999999)
        and (.[0].quality_contract_id | type == "string"
          and test("^$|^qc-[A-Za-z0-9._:-]{8,80}$"))
        and (.[0].quality_contract_revision | type == "number" and floor == .
          and . >= 0 and . <= 999999999999999)
        and (if .[0].quality_contract_id == "" then
          .[0].quality_contract_revision == 0
          else .[0].quality_contract_revision >= 1 end)
        # Authority identities intentionally retain the established 24-hex
        # wire format (see _omc_authority_digest). Requiring a full SHA-256
        # here rejects every snapshot emitted by the paired PreTool hook.
        and (.[0].input_digest | type == "string"
          and test("^[0-9a-f]{24}$"))
        and (.[0].started_at | type == "number" and floor == .
          and . >= 1 and . <= 999999999999999)
        and (.[0].launcher_path | type == "string" and length <= 1000
          and (test("[\u0000-\u001f\u007f]") | not))
        and (.[0].launcher_digest | type == "string"
          and (. == "" or test("^[0-9a-f]{64}$")))
        and (.[0].launcher_identity | type == "string" and length <= 512
          and (test("[\u0000-\u001f\u007f]") | not))
        and ((.[0].launcher_path == "") == (.[0].launcher_digest == "")
          and (.[0].launcher_path == "") == (.[0].launcher_identity == ""))
        and (.[0].subject_path | type == "string" and length <= 1000
          and (test("[\u0000-\u001f\u007f]") | not))
        and (.[0].subject_digest | type == "string"
          and (. == "" or test("^[0-9a-f]{64}$")))
        and (.[0].subject_identity | type == "string" and length <= 512
          and (test("[\u0000-\u001f\u007f]") | not))
        and ((.[0].subject_path == "") == (.[0].subject_digest == "")
          and (.[0].subject_path == "") == (.[0].subject_identity == ""))
        and (.[0].tool_cwd | type == "string" and length >= 1 and length <= 1000
          and (test("[\u0000-\u001f\u007f]") | not))
      then .[0]
      else empty
      end
    ' \
        "${_OMC_CONSUMED_VERIFICATION_START}" 2>/dev/null || true)"
    fi
    if ! _release_consumed_verification_start_locked; then
      _snapshot_json=""
      _reason="start_snapshot_consume_failed"
    fi

    if [[ -z "${_reason}" && -z "${_snapshot_json}" ]]; then
      _reason="invalid_start_snapshot"
    elif [[ -z "${_reason}" ]]; then
      _stored_id="$(jq -r '.tool_use_id // empty' <<<"${_snapshot_json}")"
      _stored_tool="$(jq -r '.tool_name // empty' <<<"${_snapshot_json}")"
      _start_revision="$(jq -r '.code_revision // empty' <<<"${_snapshot_json}")"
      _start_edit_revision="$(jq -r '.edit_revision // empty' <<<"${_snapshot_json}")"
      _start_plan_revision="$(jq -r '.plan_revision // empty' <<<"${_snapshot_json}")"
      _start_cycle="$(jq -r '.review_cycle_id // empty' <<<"${_snapshot_json}")"
      _start_contract_id="$(jq -r '.quality_contract_id // empty' <<<"${_snapshot_json}")"
      _start_contract_revision="$(jq -r '.quality_contract_revision // empty' <<<"${_snapshot_json}")"
      _start_input_digest="$(jq -r '.input_digest // empty' <<<"${_snapshot_json}")"
      _start_launcher_path="$(jq -r '.launcher_path // empty' <<<"${_snapshot_json}")"
      _start_launcher_digest="$(jq -r '.launcher_digest // empty' <<<"${_snapshot_json}")"
      _start_launcher_identity="$(jq -r '.launcher_identity // empty' <<<"${_snapshot_json}")"
      _start_subject_path="$(jq -r '.subject_path // empty' <<<"${_snapshot_json}")"
      _start_subject_digest="$(jq -r '.subject_digest // empty' <<<"${_snapshot_json}")"
      _start_subject_identity="$(jq -r '.subject_identity // empty' <<<"${_snapshot_json}")"
      _start_tool_cwd="$(jq -r '.tool_cwd // empty' <<<"${_snapshot_json}")"
      _normalized_start_tool_cwd="$(_verification_normalize_proof_path \
        "${_start_tool_cwd}" 0 content 2>/dev/null || true)"
    fi

    if [[ -z "${_reason}" && "${_invalid_current_numeric_state}" -eq 1 ]]; then
      # Current causal clocks are authority, not optional telemetry. A corrupt
      # value must not be normalized to zero and accidentally match a migrated
      # start snapshot.
      _reason="invalid_current_numeric_state"
    elif [[ -z "${_reason}" ]] \
        && { [[ "${_stored_id}" != "${tool_use_id}" ]] \
          || [[ "${_stored_tool}" != "${tool_name}" ]]; }; then
      _reason="start_snapshot_identity_mismatch"
    elif [[ -z "${_reason}" ]] && { \
        ! _omc_canonical_uint_in_range \
          "${_start_revision}" 0 "${_VERIFY_UINT_MAX}" \
        || ! _omc_canonical_uint_in_range \
          "${_start_edit_revision}" 0 "${_VERIFY_UINT_MAX}" \
        || ! _omc_canonical_uint_in_range \
          "${_start_plan_revision}" 0 "${_VERIFY_UINT_MAX}" \
        || ! _omc_canonical_uint_in_range \
          "${_start_cycle}" 0 "${_VERIFY_UINT_MAX}" \
        || ! _omc_canonical_uint_in_range \
          "${_start_contract_revision}" 0 "${_VERIFY_UINT_MAX}"; \
      }; then
      _reason="invalid_start_snapshot"
    elif [[ -z "${_reason}" ]] \
        && [[ ! "${_start_input_digest}" =~ ^[A-Za-z0-9._:-]{8,80}$ \
        || ! "${_current_input_digest}" =~ ^[A-Za-z0-9._:-]{8,80}$ \
        || "${_normalized_start_tool_cwd}" != "${_start_tool_cwd}" \
        || "${_current_tool_cwd}" != "${_start_tool_cwd}" ]]; then
      _reason="invalid_start_snapshot"
    elif [[ -z "${_reason}" \
        && "${_start_input_digest}" != "${_current_input_digest}" ]]; then
      # Tool IDs and names are insufficient when a queued/replayed PostTool
      # envelope carries different arguments. Bind the result to the exact
      # canonical PreTool input before it can update clocks or mint a receipt.
      _reason="tool_input_changed"
    elif [[ -z "${_reason}" && "${_start_cycle}" != "${_current_cycle}" ]]; then
      # A fresh objective invalidates even otherwise-identical verification.
      # This is universal rather than Definition-only so a late completion
      # cannot certify a newer objective while that optional policy is off.
      _reason="review_cycle_changed"
    elif [[ -z "${_reason}" && "${_start_revision}" != "${_current_revision}" ]]; then
      _reason="code_revision_changed"
    elif [[ -z "${_reason}" \
        && "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]]; then
      _current_edit_revision="$(read_state "edit_revision" 2>/dev/null || true)"
      _current_plan_revision="$(read_state "plan_revision" 2>/dev/null || true)"
      [[ -n "${_current_edit_revision}" ]] || _current_edit_revision=0
      [[ -n "${_current_plan_revision}" ]] || _current_plan_revision=0
      if ! _omc_canonical_uint_in_range \
          "${_current_edit_revision}" 0 "${_VERIFY_UINT_MAX}" \
          || ! _omc_canonical_uint_in_range \
            "${_current_plan_revision}" 0 "${_VERIFY_UINT_MAX}"; then
        _reason="invalid_definition_current_state"
      elif ! _omc_canonical_uint_in_range \
          "${_start_contract_revision}" 1 "${_VERIFY_UINT_MAX}" \
          || [[ ! "${_start_contract_id}" =~ ^qc-[A-Za-z0-9._:-]{8,80}$ ]]; then
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
      elif [[ "${tool_name}" == "Bash" ]]; then
        _current_launcher_path="$(verification_command_launcher_path \
          "$(jq -r '.command // empty' <<<"${_current_input_json}")" \
          2>/dev/null || true)"
        _current_launcher_digest="$(_verification_sha256_file \
          "${_current_launcher_path}" 2>/dev/null || true)"
        _current_launcher_identity="$(_verification_file_identity \
          "${_current_launcher_path}" 2>/dev/null || true)"
        if [[ -z "${_start_launcher_path}" \
            || ! "${_start_launcher_digest}" =~ ^[0-9a-f]{64}$ \
            || -z "${_start_launcher_identity}" ]]; then
          _reason="missing_launcher_snapshot"
        elif [[ "${_current_launcher_path}" != "${_start_launcher_path}" ]]; then
          _reason="launcher_resolution_changed"
        elif [[ "${_current_launcher_digest}" != "${_start_launcher_digest}" ]]; then
          _reason="launcher_content_changed"
        elif [[ "${_current_launcher_identity}" != "${_start_launcher_identity}" ]]; then
          _reason="launcher_identity_changed"
        fi
      fi
      if [[ -z "${_reason}" && ( "${tool_name}" == "Bash" \
          || "${tool_name}" == "Read" || "${tool_name}" == "Grep" ) ]]; then
        if [[ "${tool_name}" == "Bash" ]]; then
          _current_subject_path="$(verification_command_subject_path \
            "$(jq -r '.command // empty' <<<"${_current_input_json}")" \
            "${_current_tool_cwd_raw}" 2>/dev/null || true)"
        else
          _current_subject_path="$(verification_read_subject_path \
            "${_current_input_json}" "${_current_tool_cwd_raw}" \
            2>/dev/null || true)"
        fi
        if [[ -n "${_current_subject_path}" ]]; then
          _current_subject_digest="$(_verification_sha256_file \
            "${_current_subject_path}" 2>/dev/null || true)"
          _current_subject_identity="$(_verification_file_identity \
            "${_current_subject_path}" "${_start_tool_cwd}" \
            2>/dev/null || true)"
        fi
        if [[ "${tool_name}" == "Bash" \
            && -z "${_start_subject_path}" ]]; then
          _reason="missing_subject_snapshot"
        elif [[ -n "${_start_subject_path}" \
            && "${_current_subject_path}" != "${_start_subject_path}" ]]; then
          _reason="subject_resolution_changed"
        elif [[ -n "${_start_subject_digest}" \
            && "${_current_subject_digest}" != "${_start_subject_digest}" ]]; then
          _reason="subject_content_changed"
        elif [[ -n "${_start_subject_identity}" \
            && "${_current_subject_identity}" != "${_start_subject_identity}" ]]; then
          _reason="subject_identity_changed"
        elif [[ -z "${_start_subject_path}" \
            && -n "${_current_subject_path}" ]]; then
          _reason="subject_resolution_changed"
        elif [[ ( "${tool_name}" == "Read" || "${tool_name}" == "Grep" ) \
            && "${_receipt_outcome:-failed}" == "passed" \
            && -z "${_start_subject_path}" ]]; then
          _reason="missing_subject_snapshot"
        elif [[ "${tool_name}" == "Read" \
            && "${_receipt_outcome:-failed}" == "passed" \
            && -n "${_start_subject_path}" ]] \
            && { [[ "${_receipt_artifact_target:-}" != "${_start_subject_path}" ]] \
              || [[ "${_receipt_artifact_digest:-}" != "${_start_subject_digest}" ]]; }; then
          # The receipt bytes are computed before entering this state lock.
          # Requiring start == receipt == current closes both sides of that
          # interval instead of merely checking whichever file is live now.
          _reason="subject_receipt_mismatch"
        fi
      fi
    fi
  fi

  if [[ -n "${_reason}" ]]; then
    _stale_count="$(read_state "stale_verify_count")"
    if _omc_canonical_uint_in_range \
        "${_stale_count:-0}" 0 999999999999999998; then
      _stale_count=$((_stale_count + 1))
    else
      # This is a monotonic causal-rejection counter. Saturation preserves the
      # conservative signal; resetting malformed/overflowed state to zero
      # would make prior stale completions disappear from telemetry.
      _stale_count=999999999999999999
    fi
    _write_state_batch_unlocked \
      "last_stale_verify_ts" "$(now_epoch)" \
      "last_stale_verify_tool" "${tool_name}" \
      "last_stale_verify_reason" "${_reason}" \
      "last_stale_verify_start_code_revision" "${_start_revision}" \
      "last_stale_verify_current_code_revision" "${_current_revision}" \
      "stale_verify_count" "${_stale_count}" || return 1
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
  _verify_start_launcher_path="${_start_launcher_path}"
  _verify_start_launcher_digest="${_start_launcher_digest}"
  _verify_start_launcher_identity="${_start_launcher_identity}"
  _verify_start_subject_path="${_start_subject_path}"
  _verify_start_subject_digest="${_start_subject_digest}"
  _verify_start_subject_identity="${_start_subject_identity}"
  _verify_start_tool_cwd="${_start_tool_cwd}"
  # Publish the causal receipt before advancing the scalar success mirrors.
  # A compactor/input failure must not leave `last_verify_*` claiming success
  # for a receipt that never became durable. If the later state write fails,
  # the extra receipt remains fail-closed because certification also requires
  # current scalar verification state.
  if [[ "${_verification_receipt_ready:-0}" -eq 1 ]]; then
    _append_verification_receipt_unlocked || return 1
  fi
  if [[ "${_verification_receipt_only:-0}" -ne 1 ]]; then
    _write_state_batch_unlocked "$@" \
      "last_verify_code_revision" "${_start_revision}" || return 1
  fi
}

_persist_verification_state() {
  local _rc=0 _tool_use_digest="unavailable"
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
    # Keep failure telemetry attributable without copying an untrusted,
    # potentially overlong platform ID into the cross-session hook log.
    # The bounded authority digest is enough to correlate a callback with its
    # PreTool/PostTool envelope during incident review.
    _tool_use_digest="$(_omc_authority_digest \
      "${tool_use_id}" 2>/dev/null || printf 'unavailable')"
    log_anomaly "record-verification" \
      "failed to atomically consume start snapshot and persist result rc=${_rc} tool=${tool_name} tool_use_digest=${_tool_use_digest}"
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
  _receipt_proof_target="${10:-}"
  _verification_receipt_ready=1
}

_mcp_verification_target_descriptor() {
  local input_json="${1:-}" output="${2:-}" descriptor="" observed_url=""
  [[ -n "${input_json}" ]] || input_json='{}'
  local redacted_descriptor=""
  descriptor="$(jq -r '
    def safe:
      if test("[\u0000-\u001f\u007f]") then
        error("verification target descriptor contains control bytes")
      else . end;
    def leaf: ascii_downcase
      | . == "url" or . == "page_url" or . == "path" or . == "file_path"
        or . == "route" or . == "endpoint" or . == "selector"
        or . == "locator" or . == "target";
    [paths(scalars) as $p
      | select(($p[-1] | tostring | leaf))
      | (getpath($p) | tostring | safe
          | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $v
      | select(($v | length) > 0)
      | {k:($p | map(tostring | safe
            | gsub("%"; "%25") | gsub(";"; "%3B")
            | gsub("="; "%3D") | gsub("\\."; "%2E")) | join(".")),
         v:($v | gsub("%"; "%25") | gsub(";"; "%3B"))}]
    | sort_by(.k)
    | if length > 12 or any(.[]; (.v | length) > 240)
      then error("verification target descriptor exceeds persistence bounds")
      else map(.k + "=" + .v) | join(";") end
  ' <<<"${input_json}" 2>/dev/null || true)"
  observed_url="$(printf '%s\n' "${output}" \
    | sed -nE 's/.*(Page URL|URL):[[:space:]]*(https?:\/\/[^[:space:]]+).*/\2/p' \
    | head -1 || true)"
  if [[ -n "${observed_url}" ]]; then
    [[ ${#observed_url} -le 240 ]] \
      && _verification_url_is_canonical "${observed_url}" || return 1
    observed_url="$(_verification_descriptor_encode_value \
      "${observed_url}")" || return 1
    [[ ${#observed_url} -le 240 ]] || return 1
    if [[ -z "${descriptor}" ]]; then
      descriptor="observed_url=${observed_url}"
    elif [[ ";${descriptor};" != *';observed_url='* ]]; then
      descriptor="${descriptor};observed_url=${observed_url}"
    fi
  fi
  [[ ${#descriptor} -le 1000 ]] || return 1
  redacted_descriptor="$(printf '%s' "${descriptor}" \
    | omc_redact_secrets | tr -d '\000\r\n')"
  # Redaction is safe for display, never for proof identity. Otherwise a
  # literal frozen `[REDACTED]` selector can collide with any runtime secret.
  [[ "${redacted_descriptor}" == "${descriptor}" ]] || return 1
  descriptor="${redacted_descriptor}"
  [[ ${#descriptor} -le 1000 ]] || return 1
  printf '%s' "${descriptor}"
}

# This runs inside the same session lock that consumes the PreTool sidecar and
# publishes last_verify_* state. Every Definition proof row therefore names a
# harness-minted receipt bound to the exact tool ID, contract, mutation/plan
# generations, observed outcome, and output digest. Reviewer prose never
# creates or edits these facts.
_append_verification_receipt_unlocked() {
  local command_safe proof_command proof_target proof_tool_name
  local result_excerpt result_digest
  local command_digest proof_target_digest proof_material
  local proof_identity receipt_identity receipt_id row confidence
  local prior_receipts='[]'
  command_safe="$(printf '%s' "${_receipt_command:-}" \
    | omc_redact_secrets | tr -d '\000')"
  command_safe="$(truncate_chars 500 "${command_safe}")"
  proof_command="${command_safe}"
  proof_command="$(verification_receipt_command_material \
    "${command_safe}" "${tool_name}" 2>/dev/null || true)"
  command_digest="$(verification_receipt_command_digest \
    "${command_safe}" "${tool_name}" 2>/dev/null || true)"
  proof_target="${_receipt_proof_target:-${proof_command}}"
  proof_tool_name="${tool_name}"
  if [[ "${tool_name}" == "Bash" ]]; then
    # Opaque policy/diagnostic argv is sealed by command_digest and therefore
    # remains part of the unique receipt identity. It is not an independent
    # empirical proof surface: adding a timeout, label, or evidence-kind flag
    # to the same verifier must not manufacture new counterevidence.
    proof_target="${proof_target%%|policy=*}"
  fi
  if [[ "${tool_name}" == mcp__* \
      && "${_receipt_method:-}" == mcp_* ]]; then
    # Connector installation aliases are transport identity, not proof
    # identity. The classifier family plus canonical target descriptor is the
    # observable verification surface shared by equivalent aliases.
    proof_tool_name="${_receipt_method}"
  fi
  proof_target_digest="$(_omc_authority_digest "${proof_target}" 2>/dev/null || true)"
  result_digest="$(_omc_authority_digest "${_receipt_result_raw:-}" 2>/dev/null || true)"
  [[ -n "${command_digest}" && -n "${proof_target_digest}" \
      && -n "${result_digest}" ]] || return 1
  confidence="${_receipt_confidence:-0}"
  _omc_canonical_uint_in_range "${confidence}" 0 100 || confidence=0
  result_excerpt="$(printf '%s\n' "${_receipt_result_raw:-}" \
    | omc_redact_secrets \
    | tr -d '\000' \
    | grep -Ei '([0-9]+[[:space:]]+(passed|failed|errors?|tests?|specs?|checks?|benchmarks?|comparisons?|renders?|snapshots?|screenshots?)|pass(ed)?|fail(ed)?|error|exit (code|status)|success|match|found|benchmark|latency|throughput|ops/s|req/s|comparison|compare|diff|difference|delta|baseline|render|snapshot|screenshot|artifact|digest)' 2>/dev/null \
    | awk '
        {
          lower=tolower($0)
          if (special == "" && lower ~ /(benchmark|latency|throughput|ops\/s|req\/s|comparison|compare|diff|difference|delta|baseline|render|snapshot|screenshot|artifact|digest)/) special=$0
          n++; ring[n % 4]=$0
        }
        END {
          if (special != "") print special
          start=(n > 4 ? n-3 : 1)
          for (i=start; i<=n; i++) {
            line=ring[i % 4]
            if (line != "" && line != special) print line
          }
        }' \
    | tr '\n\r\t' '   ' \
    | sed -E 's/[[:space:]]+/ /g' || true)"
  result_excerpt="$(truncate_chars 500 "${result_excerpt:-${_receipt_outcome:-unknown}}")"
  proof_material="$(jq -cnS \
    --arg tool_name "${proof_tool_name}" \
    --arg proof_target_digest "${proof_target_digest}" \
    --arg artifact_target "${_receipt_artifact_target:-}" \
    --argjson edit_revision "${_verify_start_edit_revision:-0}" \
    --argjson plan_revision "${_verify_start_plan_revision:-0}" \
    --argjson review_cycle_id "${_verify_start_cycle:-0}" \
    --arg quality_contract_id "${_verify_start_contract_id:-}" \
    --argjson quality_contract_revision "${_verify_start_contract_revision:-0}" '
      {tool_name:$tool_name,proof_target_digest:$proof_target_digest,
       artifact_target:$artifact_target,
       edit_revision:$edit_revision,
       plan_revision:$plan_revision,review_cycle_id:$review_cycle_id,
       quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision}')" || return 1
  proof_identity="vp-$(_omc_authority_digest "${proof_material}" 2>/dev/null || true)"
  [[ "${proof_identity}" =~ ^vp-[A-Za-z0-9._:-]{8,80}$ ]] || return 1
  receipt_identity="$(jq -cnS \
    --arg tool_use_id "${tool_use_id}" --arg tool_name "${tool_name}" \
    --arg input_digest "${_verify_start_input_digest}" \
    --arg command_digest "${command_digest}" --arg result "${result_excerpt}" \
    --arg result_digest "${result_digest}" \
    --arg outcome "${_receipt_outcome}" --argjson confidence "${confidence}" \
    --arg method "${_receipt_method}" --arg scope "${_receipt_scope}" \
    --arg evidence_kind "${_receipt_evidence_kind}" \
    --arg artifact_target "${_receipt_artifact_target:-}" \
    --arg artifact_digest "${_receipt_artifact_digest:-}" \
    --arg launcher_path "${_verify_start_launcher_path:-}" \
    --arg launcher_digest "${_verify_start_launcher_digest:-}" \
    --arg launcher_identity "${_verify_start_launcher_identity:-}" \
    --arg subject_path "${_verify_start_subject_path:-}" \
    --arg subject_digest "${_verify_start_subject_digest:-}" \
    --arg subject_identity "${_verify_start_subject_identity:-}" \
    --arg tool_cwd "${_verify_start_tool_cwd:-}" \
    --arg proof_identity "${proof_identity}" \
    --argjson edit_revision "${_verify_start_edit_revision:-0}" \
    --argjson code_revision "${_verify_start_code_revision:-0}" \
    --argjson plan_revision "${_verify_start_plan_revision:-0}" \
    --argjson review_cycle_id "${_verify_start_cycle:-0}" \
    --arg quality_contract_id "${_verify_start_contract_id:-}" \
    --argjson quality_contract_revision "${_verify_start_contract_revision:-0}" '
      {tool_use_id:$tool_use_id,tool_name:$tool_name,input_digest:$input_digest,
       command_digest:$command_digest,result:$result,result_digest:$result_digest,
       outcome:$outcome,confidence:$confidence,method:$method,scope:$scope,
       evidence_kind:$evidence_kind,artifact_target:$artifact_target,
       artifact_digest:$artifact_digest,launcher_path:$launcher_path,
       launcher_digest:$launcher_digest,launcher_identity:$launcher_identity,
       subject_path:$subject_path,subject_digest:$subject_digest,
       subject_identity:$subject_identity,tool_cwd:$tool_cwd,
       proof_identity:$proof_identity,
       edit_revision:$edit_revision,
       code_revision:$code_revision,plan_revision:$plan_revision,
       review_cycle_id:$review_cycle_id,quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision}'
  )" || return 1
  receipt_id="vr-$(_omc_authority_digest "${receipt_identity}" 2>/dev/null || true)"
  [[ "${receipt_id}" =~ ^vr-[A-Za-z0-9._:-]{8,80}$ ]] || return 1
  row="$(jq -cnS \
    --argjson _v 3 --arg receipt_id "${receipt_id}" \
    --arg tool_use_id "${tool_use_id}" --arg tool_name "${tool_name}" \
    --arg input_digest "${_verify_start_input_digest}" \
    --arg command "${command_safe}" --arg command_digest "${command_digest}" \
    --arg outcome "${_receipt_outcome}" --argjson confidence "${confidence}" \
    --arg method "${_receipt_method}" --arg scope "${_receipt_scope}" \
    --arg evidence_kind "${_receipt_evidence_kind}" --arg result "${result_excerpt}" \
    --arg result_digest "${result_digest}" \
    --arg artifact_target "${_receipt_artifact_target:-}" \
    --arg artifact_digest "${_receipt_artifact_digest:-}" \
    --arg launcher_path "${_verify_start_launcher_path:-}" \
    --arg launcher_digest "${_verify_start_launcher_digest:-}" \
    --arg launcher_identity "${_verify_start_launcher_identity:-}" \
    --arg subject_path "${_verify_start_subject_path:-}" \
    --arg subject_digest "${_verify_start_subject_digest:-}" \
    --arg subject_identity "${_verify_start_subject_identity:-}" \
    --arg tool_cwd "${_verify_start_tool_cwd:-}" \
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
       artifact_digest:$artifact_digest,launcher_path:$launcher_path,
       launcher_digest:$launcher_digest,launcher_identity:$launcher_identity,
       subject_path:$subject_path,subject_digest:$subject_digest,
       subject_identity:$subject_identity,tool_cwd:$tool_cwd,
       proof_identity:$proof_identity,
       edit_revision:$edit_revision,
       code_revision:$code_revision,plan_revision:$plan_revision,
       review_cycle_id:$review_cycle_id,quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision,ts:$ts}'
  )" || return 1
  declare -F _quality_contract_receipts_schema_valid >/dev/null 2>&1 \
    || _omc_load_quality_contract 2>/dev/null || return 1
  # Validate every candidate before it enters the shared ledger, including
  # pre-contract receipts. Otherwise one self-produced invalid v3 row can
  # poison later Definition admission when the full ledger fails closed.
  _quality_contract_receipts_schema_valid "[$(printf '%s' "${row}")]" 1 \
    || return 1
  local ledger source tmp retention_contract="null" retention_contract_file
  local evidence_ledger evidence_rows='[]'
  local current_frontier_file current_frontier current_frontier_receipt_ids='[]'
  local frontier_history frontier_history_parsed frontier_receipt_ids='[]'
  local protected_receipt_ids='[]'
  local retention_authority='{}' retention_criterion="" retention_id=""
  local retention_criterion_authority="" retention_threshold="40"
  local retention_receipts='[]' retention_bash_surfaces='{}'
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
  if [[ -s "${source}" ]]; then
    prior_receipts="$(_quality_contract_read_jsonl_array \
      "${source}" 2097152 2048)" || return 1
    # Retention is never repair authority, including before a Definition is
    # armed. Every current producer emits the same sealed v3 schema for both
    # pre-contract and contract-bound receipts. Validate the complete prior
    # ledger unconditionally so a valid-JSON malformed or duplicate row cannot
    # be normalized by group/sort/dedupe and later poison Definition admission.
    declare -F _quality_contract_receipts_schema_valid >/dev/null 2>&1 \
      || return 1
    _quality_contract_receipts_schema_valid "${prior_receipts}" 2048 \
      || return 1
  fi
  if [[ -n "${_verify_start_contract_id:-}" ]]; then
    retention_contract_file="$(session_file "quality_contract.json")"
    retention_contract="$(_quality_contract_read_json_file \
      "${retention_contract_file}" 65536)" || return 1
    quality_contract_validate_envelope "${retention_contract}" || return 1
    retention_contract="$(jq -ce \
      --arg id "${_verify_start_contract_id}" \
      --argjson rev "${_verify_start_contract_revision:-0}" \
      'select(.contract_id == $id and .contract_revision == $rev)' \
      <<<"${retention_contract}" 2>/dev/null)" || return 1
  fi
  evidence_ledger="$(session_file "quality_evidence.jsonl")"
  if [[ -e "${evidence_ledger}" || -L "${evidence_ledger}" ]]; then
    if [[ ! -f "${evidence_ledger}" || -L "${evidence_ledger}" ]]; then
      return 1
    fi
    evidence_rows="$(_quality_contract_read_jsonl_array \
      "${evidence_ledger}" 2097152 512)" || return 1
    _quality_contract_evidence_schema_valid "${evidence_rows}" || return 1
    protected_receipt_ids="$(jq -c \
      --arg contract "${_verify_start_contract_id:-}" \
      --argjson revision "${_verify_start_contract_revision:-0}" \
      --argjson edit "${_verify_start_edit_revision:-0}" \
      --argjson plan "${_verify_start_plan_revision:-0}" '
        [.[] | select(.contract_id == $contract
            and .contract_revision == $revision
            and .edit_revision == $edit and .plan_revision == $plan)
          | .receipt_id
          | select(type == "string" and test("^vr-[A-Za-z0-9._:-]{8,80}$"))]
        | unique | .[-32:]
      ' <<<"${evidence_rows}" 2>/dev/null)" || return 1
  fi
  # An additive, floor-preserving re-contract retains an accepted open frontier
  # pair as redundant causal authority while its old contract coordinates keep
  # it ineligible for certification. Preserve the bounded receipt portfolio it
  # names even after the contract advances. This lets remediation survive later
  # history loss/corruption instead of turning a fail-closed finding into either
  # a silent release or an unrecoverable missing-receipt deadlock.
  current_frontier_file="$(session_file "quality_frontier.json")"
  if [[ -e "${current_frontier_file}" || -L "${current_frontier_file}" ]]; then
    if [[ ! -f "${current_frontier_file}" \
        || -L "${current_frontier_file}" ]]; then
      return 1
    fi
    current_frontier="$(_quality_contract_read_json_file \
      "${current_frontier_file}" 65536)" || return 1
    _quality_contract_frontier_schema_valid "${current_frontier}" || return 1
    if _omc_canonical_uint_in_range \
        "${_verify_start_cycle:-0}" 1 "${_VERIFY_UINT_MAX}" \
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
  if [[ -e "${frontier_history}" || -L "${frontier_history}" ]]; then
    if [[ ! -f "${frontier_history}" || -L "${frontier_history}" ]]; then
      return 1
    fi
    frontier_history_parsed="$(_quality_frontier_history_parse \
      "${frontier_history}" 2>/dev/null)" || return 1
    if ! jq -e '.invalid_rows == 0 and (.rows | type == "array")' \
        <<<"${frontier_history_parsed}" >/dev/null 2>&1; then
      return 1
    fi
    if _omc_canonical_uint_in_range \
        "${_verify_start_cycle:-0}" 1 "${_VERIFY_UINT_MAX}"; then
      frontier_receipt_ids="$(jq -c \
        --argjson cycle "${_verify_start_cycle}" '
          [.rows[] | select(.review_cycle_id == $cycle)]
          | if length > 0 and .[-1].status == "open"
            then .[-1].evidence
            else []
            end
        ' <<<"${frontier_history_parsed}" 2>/dev/null)" || return 1
      protected_receipt_ids="$(jq -cn \
        --argjson accepted "${protected_receipt_ids}" \
        --argjson frontier "${frontier_receipt_ids}" \
        '$accepted + $frontier | unique')" || return 1
    fi
  fi
  if [[ "${retention_contract}" != "null" ]]; then
    retention_threshold="$(jq -r '.verification_threshold // 40' \
      <<<"${retention_contract}" 2>/dev/null || printf '40')"
    _omc_canonical_uint_in_range "${retention_threshold}" 0 100 \
      || retention_threshold=40
    while IFS= read -r retention_criterion; do
      [[ -n "${retention_criterion}" ]] || continue
      retention_id="$(jq -r '.id' <<<"${retention_criterion}")"
      retention_criterion_authority="$(quality_contract_criterion_authority_json \
        "${retention_criterion}" "${retention_contract}" \
        "${_verify_start_edit_revision:-0}" \
        "${_verify_start_plan_revision:-0}" "${retention_threshold}" \
        2>/dev/null || true)"
      [[ "$(jq -r 'type' <<<"${retention_criterion_authority}" \
          2>/dev/null || true)" == "object" ]] || return 1
      retention_authority="$(jq -cn \
        --argjson map "${retention_authority}" \
        --arg id "${retention_id}" \
        --argjson authority "${retention_criterion_authority}" \
        '$map + {($id):$authority}')" || return 1
    done < <(jq -c '.definition.criteria[]' <<<"${retention_contract}")
    retention_receipts="$(jq -cn \
      --argjson prior "${prior_receipts}" --argjson current "${row}" \
      '$prior + [$current]')" || return 1
    retention_bash_surfaces="$(_quality_contract_bash_receipt_surface_map \
      "${retention_receipts}" "${retention_contract}" 2>/dev/null)" \
      || return 1
  fi
  # Keep a bounded, criterion-aware proof portfolio. For each live criterion,
  # retain the newest independent proof identities needed by its minimum plus
  # one diagnostic spare; then add only a tiny recent/live and history tail.
  # This prevents high-volume observation from evicting required proof without
  # letting hundreds of current receipts exceed the gate reader's byte cap.
  tmp="$(mktemp "${ledger}.tmp.XXXXXX")" || return 1
  chmod 600 "${tmp}" 2>/dev/null || true
  if ! printf '%s' "${prior_receipts}" | jq -r --arg row "${row}" \
      --arg contract "${_verify_start_contract_id:-}" \
      --argjson revision "${_verify_start_contract_revision:-0}" \
      --argjson edit "${_verify_start_edit_revision:-0}" \
      --argjson plan "${_verify_start_plan_revision:-0}" \
      --argjson protected "${protected_receipt_ids}" \
      --argjson authority "${retention_authority}" \
      --argjson bash_surfaces "${retention_bash_surfaces}" \
      --argjson definition "${retention_contract}" '
        def tool_match($pattern;$actual):
          if ($pattern | endswith("*")) then
            $actual | startswith($pattern[0:-1])
          else $actual == $pattern end;
        def same_surface($receipt;$criterion):
          ($authority[$criterion.id] // {}) as $auth
          | if $auth.mode == "bash_surface" then
              $receipt.tool_name == "Bash"
              and ($bash_surfaces[$receipt.receipt_id] // "")
                == $auth.proof_surface
              and $receipt.artifact_target == $auth.artifact_target
            elif $auth.mode == "proof_identity" then
              $receipt.proof_identity == $auth.proof_identity
              and $receipt.artifact_target == $auth.artifact_target
              and (if ($auth.expected_command // "") != "" then
                $receipt.command == $auth.expected_command else true end)
            elif $auth.mode == "mcp" then
              $receipt.method == ("mcp_" + $auth.classifier)
              and (($receipt.artifact_target | split(";")) as $actual
                | all(($auth.descriptor | split(";"))[];
                    . as $descriptor | ($actual | index($descriptor)) != null))
            else false end;
        def matches($receipt;$criterion):
          ($criterion.proof_spec.receipt_kinds
            | index($receipt.evidence_kind)) != null
          and any($criterion.proof_spec.tool_names[];
            tool_match(.;$receipt.tool_name))
          and (if $receipt.tool_name == "Read" or $receipt.tool_name == "Grep"
            then true
            else all($criterion.proof_spec.command_contains[];
              . as $token | ($receipt.command | ascii_downcase
                | contains($token | ascii_downcase))) end)
          and same_surface($receipt;$criterion);
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
        . as $prior
        | (($prior + [($row | fromjson)])
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
              | [$live[] | select(same_surface(.;$criterion)
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
              | ([$accepted[] | select(matches(.;$criterion))]
                    | max_by(.__omc_receipt_ordinal) // null) as $accepted_receipt
              | ($accepted_receipt.__omc_receipt_ordinal // -1) as $accepted_ordinal
              | [$live[] | select(matches(.;$criterion)
                    and $accepted_ordinal >= 0
                    and .outcome == "passed"
                    and observation_bearing(.)
                    and matching_ids(.) == [$criterion.id]
                    and (($accepted_receipt.artifact_digest // "") == ""
                      or (.artifact_digest // "") == ""
                      or .artifact_digest != $accepted_receipt.artifact_digest)
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
      ' >"${tmp}" \
      || ! mv -f "${tmp}" "${ledger}"; then
    rm -f "${tmp}" 2>/dev/null || true
    return 1
  fi
}

_verification_receipt_ready=0
_verification_receipt_only=0
definition_required="$(read_state \
  "quality_contract_required" 2>/dev/null || true)"

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

  project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
  if [[ -z "${project_test_cmd}" ]]; then
    project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  fi

  # `common.sh` resolves this user-authorized proof-admission extension with
  # valid environment > user conf precedence and last-valid duplicate
  # semantics. Project config is intentionally denied: a repository-owned
  # catch-all regex must not be able to turn arbitrary Bash calls into proof.
  custom_patterns="${OMC_CUSTOM_VERIFY_PATTERNS:-}"

  builtin_pattern='(^|[[:space:]])(npm|pnpm|yarn|bun|cargo|go|pytest|python|uv|ruff|mypy|eslint|tsc|vitest|jest|phpunit|rspec|gradle|xcodebuild|swift|make|just|bash|zsh|sh|docker|terraform|ansible|helm|kubectl|mvn|maven|dotnet|mix|elixir|ruby|bundle|rake|zig|deno|nix|markdownlint|mdl|vale|textlint|alex|aspell|hunspell|languagetool|write-good)([[:space:]].*)?(test|tests|check|lint|typecheck|build|validate|verify|plan|apply)|\b(pytest|vitest|jest|cargo test|go test|swift test|swift build|ruff check|mypy|eslint|tsc|typecheck|phpunit|rspec|gradle test|xcodebuild test|shellcheck|bash -n|zsh -n|sh -n|docker build|docker compose build|terraform plan|terraform validate|ansible-lint|helm lint|mvn test|mvn verify|dotnet test|mix test|bundle exec rspec|rake test|zig build|deno test|nix build|markdownlint|mdl|vale|textlint|alex|write-good)\b'
  if [[ -n "${custom_patterns}" ]]; then
    _custom_rc=0
    printf 'test' | LC_ALL=C grep -Eq -- "${custom_patterns}" 2>/dev/null || _custom_rc=$?
    if [[ "${_custom_rc}" -eq 2 ]]; then
      log_hook "record-verification" "invalid custom_verify_patterns syntax, ignoring"
    else
      builtin_pattern="${builtin_pattern}|${custom_patterns}"
    fi
  fi

  bash_verification_candidate=0
  if [[ "${definition_required}" == "1" ]]; then
    if [[ ${#command_text} -gt 500 ]]; then
      with_state_lock _discard_verification_start_locked || true
      log_hook "record-verification" \
        "rejected Definition proof whose Bash argv exceeds receipt bounds"
      record_gate_event "definition-of-excellent/verification" \
        "overlong-command" "tool=Bash" 2>/dev/null || true
      exit 0
    fi
    if [[ "$(printf '%s' "${command_text}" | omc_redact_secrets)" \
        != "${command_text}" ]]; then
      with_state_lock _discard_verification_start_locked || true
      log_hook "record-verification" \
        "rejected Definition proof whose Bash argv requires redaction"
      record_gate_event "definition-of-excellent/verification" \
        "redacted-command" "tool=Bash" 2>/dev/null || true
      exit 0
    fi
    # A frozen contract admits named/direct proof scripts through the
    # authoritative, non-evaluating parser. Reapplying the older discovery
    # regex here would accept the contract but make its proof impossible to
    # record (for example, scripts/benchmark-release.sh --benchmark).
    if verification_command_is_authoritative_execution \
        "${command_text}" "${project_test_cmd}"; then
      bash_verification_candidate=1
    else
      with_state_lock _discard_verification_start_locked || true
      log_hook "record-verification" \
        "rejected Definition proof from non-executing or compound command"
      record_gate_event "definition-of-excellent/verification" \
        "non-authoritative-command" "tool=Bash" 2>/dev/null || true
      exit 0
    fi
  elif LC_ALL=C grep -Eiq -- "${builtin_pattern}" <<<"${command_text}" 2>/dev/null; then
    bash_verification_candidate=1
  fi

  if [[ "${bash_verification_candidate}" -eq 1 ]]; then

    verify_requested_kind="$(verification_command_requested_evidence_kind \
      "${command_text}" 2>/dev/null || true)"
    verify_outcome="passed"
    if omc_hook_tool_failed "${HOOK_JSON}"; then
      verify_outcome="failed"
    elif [[ "${verify_requested_kind}" =~ ^(benchmark|comparison|render)$ ]] \
        && verification_output_reports_kind_observation \
          "${tool_output}" "${verify_requested_kind}"; then
      # Specialized retries are ordered: a later concrete observation may
      # recover an earlier diagnostic, while a terminal negative is removed
      # by the same last-decisive parser and fails below.
      verify_outcome="passed"
    elif verification_output_reports_failure "${tool_output}"; then
      verify_outcome="failed"
    fi

    verify_proof_target=""
    if [[ "${definition_required}" == "1" ]]; then
      verify_proof_target="$(verification_command_semantic_target \
        "${command_text}" "${project_test_cmd}" 2>/dev/null || true)"
      if [[ -z "${verify_proof_target}" ]]; then
        with_state_lock _discard_verification_start_locked || true
        log_hook "record-verification" \
          "rejected Definition proof without a semantic execution target"
        record_gate_event "definition-of-excellent/verification" \
          "missing-semantic-target" "tool=Bash" 2>/dev/null || true
        exit 0
      fi
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
      "${verify_method}" "${verify_scope}" "${command_text}" \
      "${tool_output}" "${verify_outcome}")"
    verify_receipt_result="${tool_output}"
    if [[ "${definition_required}" == "1" \
        && "${verify_requested_kind}" =~ ^(benchmark|comparison|render)$ ]]; then
      if [[ "${verify_outcome}" == "failed" ]]; then
        verify_evidence_kind="${verify_requested_kind}"
      elif ! verification_output_reports_kind_observation \
          "${tool_output}" "${verify_requested_kind}"; then
        # Specialized argv is a claim about what was observed. A successful
        # process with only generic PASS/SUCCESS prose did not establish that
        # observation and must supersede an older green receipt as current
        # negative evidence for the same specialized target.
        verify_outcome="failed"
        verify_evidence_kind="${verify_requested_kind}"
        verify_receipt_result="${tool_output}"$'\n''oh-my-claude: failed - missing specialized empirical observation'
        log_hook "record-verification" \
          "recorded Definition proof as failed because specialized output was absent"
        record_gate_event "definition-of-excellent/verification" \
          "missing-specialized-observation" "tool=Bash" \
          "kind=${verify_requested_kind}" 2>/dev/null || true
      fi
    fi
    if [[ "${definition_required}" == "1" ]] \
        && verification_output_reports_zero_execution \
          "${tool_output}" "${verify_evidence_kind}"; then
      # Zero observation is a current negative result, not an absent result.
      # Persist it so a later empty/skipped rerun invalidates previously
      # accepted proof at this exact generation regardless of process exit.
      verify_outcome="failed"
      verify_receipt_result="${tool_output}"$'\n''oh-my-claude: failed - zero empirical execution'
      log_hook "record-verification" \
        "recorded Definition proof as failed because it made zero empirical observations"
      record_gate_event "definition-of-excellent/verification" \
        "zero-empirical-execution" "tool=Bash" \
        "kind=${verify_evidence_kind}" 2>/dev/null || true
    fi
    _prepare_verification_receipt "${last_verify_cmd_safe}" "${verify_outcome}" \
      "${verify_confidence}" "${verify_method}" "${verify_scope}" \
      "${verify_receipt_result}" "${verify_evidence_kind}" "" "" \
      "${verify_proof_target}"
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
  source_scope_valid=1
  if [[ "${definition_required}" == "1" ]]; then
    case "${tool_name}" in
      Read)
        # Definition source proof represents the whole frozen file. Offset,
        # limit, and any other observation-shaping input would otherwise mint
        # the same full-file proof identity from a partial view.
        jq -e '
          (.tool_input | type) == "object"
          and ((.tool_input | keys) == ["file_path"]
            or (.tool_input | keys) == ["path"])
          and ((.tool_input.file_path? // .tool_input.path?)
            | type == "string" and length > 0)
        ' <<<"${HOOK_JSON}" >/dev/null 2>&1 || source_scope_valid=0
        ;;
      Grep)
        # The frozen Grep identity is exact path + exact pattern. Glob/type,
        # head limits, case changes, context/output modes, or future unknown
        # fields narrow or reshape that observation and therefore fail closed.
        jq -e '
          (.tool_input | type) == "object"
          and ((.tool_input | keys) == ["file_path","pattern"]
            or (.tool_input | keys) == ["path","pattern"])
          and ((.tool_input.file_path? // .tool_input.path?)
            | type == "string" and length > 0)
          and (.tool_input.pattern | type == "string")
        ' <<<"${HOOK_JSON}" >/dev/null 2>&1 || source_scope_valid=0
        ;;
    esac
  fi
  source_path="$(json_get '.tool_input.file_path' 2>/dev/null || true)"
  [[ -n "${source_path}" ]] || source_path="$(json_get '.tool_input.path' 2>/dev/null || true)"
  source_pattern="$(json_get '.tool_input.pattern' 2>/dev/null || true)"
  source_cwd="$(json_get '.cwd' 2>/dev/null || true)"
  source_cwd="${source_cwd:-${PWD}}"
  source_target=""
  source_digest=""
  if [[ "${definition_required}" == "1" \
      && "${source_verify_type}" == "inspection" \
      && ${#source_pattern} -gt 120 ]]; then
    # The persisted Grep command is bounded at 120 characters. Reject a
    # longer runtime pattern before target binding so truncation cannot turn a
    # broader/different regex into the frozen exact proof pattern.
    source_path=""
  fi
  [[ "${source_scope_valid}" -eq 1 ]] || source_path=""
  if [[ -n "${source_path}" ]]; then
    if [[ "${source_path}" != /* ]]; then
      source_path="${source_cwd%/}/${source_path}"
    fi
    canonical_root="$(git -C "${source_cwd}" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "${canonical_root}" ]] || canonical_root="$(cd "${source_cwd}" 2>/dev/null && pwd -P || true)"
    [[ -z "${canonical_root}" ]] \
      || canonical_root="$(_verification_normalize_proof_path \
        "${canonical_root}" 2>/dev/null || true)"
    # Preserve the no-symlink source policy, then canonicalize the complete
    # existing target. Canonicalizing only its parent leaves case aliases (and
    # hardlink spellings) as distinct proof identities on Darwin volumes.
    if [[ ! -L "${source_path}" && -n "${canonical_root}" ]]; then
      source_target="$(_verification_normalize_proof_path \
        "${source_path}" 0 source 2>/dev/null || true)"
      case "${source_target}" in
        "${canonical_root}"|"${canonical_root}"/*) ;;
        *) source_target="" ;;
      esac
      # The receipt schema is intentionally bounded. An overlong canonical
      # target is unavailable proof, not a value to truncate into a different
      # identity or append as a ledger-poisoning row.
      [[ ${#source_target} -le 1000 ]] || source_target=""
    fi
  fi
  if [[ "${source_verify_type}" == "source" ]]; then
    if [[ -n "${source_target}" && -f "${source_target}" \
        && ! -L "${source_target}" ]]; then
      if [[ "${definition_required}" == "1" ]] \
          && ! awk 'NR > 2000 || length($0) > 2000 { exit 1 }' \
              "${source_target}" 2>/dev/null; then
        # Claude Code Read truncates after 2,000 lines and truncates longer
        # individual lines. Such a call cannot establish whole-file source
        # proof even when it omitted explicit offset/limit fields.
        source_target=""
      else
        # Keep the durable artifact digest identical to the full pre-tool
        # subject digest. The state-lock callback requires start == receipt ==
        # current bytes before accepting a whole-file Read observation.
        source_digest="$(_verification_sha256_file \
          "${source_target}" 2>/dev/null || true)"
      fi
    fi
  elif [[ -n "${source_target}" && -e "${source_target}" \
      && ! -L "${source_target}" ]]; then
    source_digest="$(_omc_authority_digest "${tool_output}" 2>/dev/null || true)"
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
  if [[ "${definition_required}" == "1" \
      && "$(printf '%s' "${source_command}" | omc_redact_secrets)" \
        != "${source_command}" ]]; then
    source_target=""
    source_digest=""
    source_outcome="failed"
    source_command="${tool_name}:invalid"
  fi
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
  mcp_visual_content_digest=""
  if [[ "${definition_required}" == "1" ]] \
      && [[ "${mcp_verify_type}" == "browser_visual_check" \
        || "${mcp_verify_type}" == "visual_check" ]]; then
    mcp_visual_content_digest="$(mcp_verification_embedded_image_digest \
      "${HOOK_JSON}" 2>/dev/null || true)"
    if [[ -z "${mcp_visual_content_digest}" ]]; then
      tool_cwd="$(json_get '.cwd' 2>/dev/null || true)"
      tool_cwd="${tool_cwd:-${PWD}}"
      mcp_visual_content_digest="$(mcp_verification_screenshot_file_digest \
        "${tool_name}" "${tool_output}" "${tool_cwd}" 2>/dev/null || true)"
    fi
  fi
  if [[ "${definition_required}" == "1" ]]; then
    mcp_observation_present=0
    case "${mcp_verify_type}" in
      browser_visual_check|visual_check)
        [[ -n "${mcp_visual_content_digest}" ]] \
          && mcp_observation_present=1
        ;;
      browser_console_check|browser_network_check)
        if jq -e '
          def present:
            . != null and (if type == "string" then length > 0 else true end);
          ((has("tool_response") and (.tool_response | present))
           or (has("tool_result") and (.tool_result | present)))
        ' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
          mcp_observation_present=1
        fi
        ;;
      *)
        if jq -e '
          def substantive:
            . != null and
            (if type == "string" or type == "array" or type == "object"
             then length > 0 else true end);
          ((has("tool_response") and (.tool_response | substantive))
           or (has("tool_result") and (.tool_result | substantive)))
        ' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
          mcp_observation_present=1
        fi
        ;;
    esac
    if [[ "${mcp_observation_present}" -ne 1 ]]; then
      verify_outcome="failed"
      log_hook "record-verification" \
        "recorded Definition MCP proof as failed because no observation result was present"
    fi
  fi
  verify_confidence="$(score_mcp_verification_confidence "${mcp_verify_type}" "${tool_output}" "${has_ui_context}")"
  verify_scope="mcp_${mcp_verify_type}"

  # Detect project test command for remediation messaging (shared with Bash path)
  project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
  if [[ -z "${project_test_cmd}" ]]; then
    project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  fi

  verify_evidence_kind="$(verification_receipt_evidence_kind \
    "mcp_${mcp_verify_type}" "${verify_scope}" "${tool_name}" \
    "${tool_output}" "${verify_outcome}")"
  mcp_target_descriptor="$(_mcp_verification_target_descriptor \
    "${tool_input_json}" "${tool_output}" 2>/dev/null || true)"
  if [[ "${mcp_verify_type}" == "browser_visual_check" \
      || "${mcp_verify_type}" == "visual_check" ]]; then
    if [[ -n "${mcp_visual_content_digest}" ]]; then
      mcp_digest_material="$(mcp_verification_observation_digest_material \
        "${tool_name}" "${tool_output}")|image-sha256=${mcp_visual_content_digest}"
    else
      # Without pixels there is no authority for erasing a transport path.
      # The failed receipt retains its exact response for diagnostics.
      mcp_digest_material="${tool_output}"
    fi
  else
    mcp_digest_material="$(mcp_verification_observation_digest_material \
      "${tool_name}" "${tool_output}")"
  fi
  mcp_artifact_digest="$(_omc_authority_digest \
    "${mcp_target_descriptor}|${mcp_digest_material}" 2>/dev/null || true)"
  mcp_receipt_command="${tool_name}"
  [[ -z "${mcp_target_descriptor}" ]] \
    || mcp_receipt_command="${mcp_receipt_command} ${mcp_target_descriptor}"
  _prepare_verification_receipt "${mcp_receipt_command}" "${verify_outcome}" \
    "${verify_confidence}" "mcp_${mcp_verify_type}" "${verify_scope}" \
    "${tool_output}" "${verify_evidence_kind}" \
    "${mcp_target_descriptor}" "${mcp_artifact_digest}" \
    "mcp:${mcp_verify_type}:${mcp_target_descriptor:-untargeted}"
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
