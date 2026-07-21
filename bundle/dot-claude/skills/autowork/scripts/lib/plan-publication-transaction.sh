#!/usr/bin/env bash

# Shared fixed-name write-ahead-log helpers for planner publication.  This file
# is sourced by record-plan.sh before either its normal hook payload or its
# internal --recover-active entrypoint is handled.  Keep this module limited to
# filesystem/state-lock work: caller-specific causal validation and summary
# effects remain in their owning hooks.

_plan_transaction_artifacts() {
  printf '%s\n' \
    session_state.json \
    pending_agents.jsonl \
    agent_dispatch_starts.jsonl \
    current_plan.md \
    quality_contract.json \
    quality_contract_history.jsonl \
    quality_evidence.jsonl \
    quality_frontier.json \
    quality_frontier_history.jsonl \
    plan_publication_outcomes.jsonl \
    plan_recovery_notices.jsonl
}

_plan_snapshot_sha256() {
  local file="$1" digest=""
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "${file}" 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "${file}" 2>/dev/null | awk '{print $1}')"
  else
    return 1
  fi
  [[ "${digest}" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
  printf '%s\n' "${digest}"
}

_plan_snapshot_seal_json() {
  local file="$1" size digest
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  size="$(wc -c <"${file}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  digest="$(_plan_snapshot_sha256 "${file}")" || return 1
  jq -cn --argjson size "${size}" --arg sha256 "${digest}" \
    '{size:$size,sha256:$sha256}'
}

_plan_snapshot_matches_seal() {
  local file="$1" seal="$2" observed
  observed="$(_plan_snapshot_seal_json "${file}")" || return 1
  jq -e --argjson expected "${seal}" '. == $expected' \
    <<<"${observed}" >/dev/null 2>&1
}

_cleanup_plan_transaction_staging_unlocked() {
  local dir="$1" staged
  [[ -d "${dir}" && ! -L "${dir}" ]] || return 1
  for staged in "${dir}/.ready.next" \
      "${dir}/.pending_agents.jsonl.cold-next" \
      "${dir}/.agent_dispatch_starts.jsonl.cold-next"; do
    [[ -e "${staged}" || -L "${staged}" ]] || continue
    [[ -f "${staged}" && ! -L "${staged}" ]] || return 1
    rm -f -- "${staged}" || return 1
  done
}

_discard_plan_transaction_dir() {
  local dir="$1" artifact retry_temp retry_name
  [[ -d "${dir}" && ! -L "${dir}" ]] || return 1
  while IFS= read -r artifact; do
    rm -f "${dir}/${artifact}.file" "${dir}/${artifact}.absent" \
      2>/dev/null || return 1
  done < <(_plan_transaction_artifacts)
  _cleanup_plan_transaction_staging_unlocked "${dir}" || return 1
  # A summary continuation publishes its one-use retry counter through a temp
  # inside the active WAL. SIGKILL between mktemp and rename may carry that temp
  # into a committed/recovered inert directory. Remove only the exact bounded
  # mktemp shape; unknown residue must continue to make rmdir fail closed.
  for retry_temp in "${dir}"/.summary-retry-count.*; do
    [[ -e "${retry_temp}" || -L "${retry_temp}" ]] || continue
    retry_name="${retry_temp##*/}"
    [[ "${retry_name}" \
        =~ ^\.summary-retry-count\.[A-Za-z0-9]{6,64}$ \
        && -f "${retry_temp}" && ! -L "${retry_temp}" ]] || return 1
    rm -f -- "${retry_temp}" 2>/dev/null || return 1
  done
  rm -f "${dir}/.ready" "${dir}/.summary-retry-count" \
    2>/dev/null || return 1
  rmdir "${dir}" 2>/dev/null || return 1
}

_cleanup_plan_transaction_inert_dirs_unlocked() {
  local kind prefix inert_dir
  for kind in stage committed recovered; do
    prefix="$(session_file ".plan-txn.${kind}.")"
    for inert_dir in "${prefix}"*; do
      [[ -e "${inert_dir}" || -L "${inert_dir}" ]] || continue
      # Random stage bytes are inert until renamed to the fixed active WAL;
      # committed/recovered names are inert after that fixed name was retired.
      # The exact-file discard helper never follows a symlink and rejects
      # non-directories or unexpected contents via rmdir.
      _discard_plan_transaction_dir "${inert_dir}" || return 1
    done
  done
}

_snapshot_plan_transaction_unlocked() {
  local dir="$1" owner="$2" artifact path transaction_id marker seal descriptor
  local descriptors='[]'
  jq -e '
    type == "object"
    and (keys | sort == ["agent_type","completion_digest","lifecycle_dispatch_id",
      "native_agent_id","tracked"])
    and (.tracked | type == "boolean")
    and (.agent_type | type == "string" and length > 0 and length <= 128)
    and (.completion_digest | type == "string"
      and test("^[A-Fa-f0-9]{16,128}$"))
    and (.lifecycle_dispatch_id | type == "string" and length <= 128)
    and (.native_agent_id | type == "string" and length <= 128)
    and (if .tracked then
      (.lifecycle_dispatch_id | test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
      and (.native_agent_id == ""
        or (.native_agent_id | test("^[A-Za-z0-9._:-]{1,128}$")))
    else .lifecycle_dispatch_id == "" end)
  ' <<<"${owner}" >/dev/null 2>&1 || return 1
  transaction_id="plan-txn-$(_omc_token_digest \
    "${SESSION_ID}|${owner}|$(now_epoch)|$$|${RANDOM}")" || return 1
  for artifact in $(_plan_transaction_artifacts); do
    path="$(session_file "${artifact}")"
    if [[ -L "${path}" ]] \
        || { [[ -e "${path}" ]] && [[ ! -f "${path}" ]]; }; then
      return 1
    elif [[ -f "${path}" ]]; then
      marker="${dir}/${artifact}.file"
      cp "${path}" "${marker}" || return 1
      chmod 600 "${marker}" 2>/dev/null || return 1
      seal="$(_plan_snapshot_seal_json "${marker}")" || return 1
      descriptor="$(jq -cn --arg name "${artifact}" \
        --argjson seal "${seal}" \
        '{name:$name,kind:"file",seals:[$seal]}')" || return 1
    else
      marker="${dir}/${artifact}.absent"
      : >"${marker}" || return 1
      chmod 600 "${marker}" 2>/dev/null || return 1
      descriptor="$(jq -cn --arg name "${artifact}" \
        '{name:$name,kind:"absent",seals:[]}')" || return 1
    fi
    descriptors="$(jq -cn --argjson rows "${descriptors}" \
      --argjson row "${descriptor}" '$rows + [$row]')" || return 1
  done
  if ! jq -nc --argjson owner "${owner}" \
      --argjson artifacts "${descriptors}" \
      --arg transaction_id "${transaction_id}" '
      {
        schema_version:2,
        status:"prepared",
        transaction_id:$transaction_id,
        owner:$owner,
        artifacts:$artifacts
      }
    ' >"${dir}/.ready"; then
    return 1
  fi
  chmod 600 "${dir}/.ready" 2>/dev/null || return 1
}

_validate_plan_transaction_targets_unlocked() {
  local artifact path
  while IFS= read -r artifact; do
    path="$(session_file "${artifact}")"
    if [[ -L "${path}" ]] \
        || { [[ -e "${path}" ]] && [[ ! -f "${path}" ]]; }; then
      log_anomaly "record-plan" \
        "refusing non-regular transaction artifact at ${path}"
      return 1
    fi
  done < <(_plan_transaction_artifacts)
}

_validate_plan_transaction_ready_unlocked() {
  local ready="$1"
  [[ -f "${ready}" && ! -L "${ready}" ]] || return 1
  [[ "$(wc -c <"${ready}" 2>/dev/null | tr -d '[:space:]' || printf 0)" \
      -le 16384 ]] || return 1
  jq -e '
    type == "object"
    and (keys | sort == ["artifacts","owner","schema_version","status",
      "transaction_id"])
    and .schema_version == 2
    and .status == "prepared"
    and (.transaction_id | type == "string"
      and test("^plan-txn-[A-Fa-f0-9]{16,128}$"))
    and (.owner | type == "object"
      and (keys | sort == ["agent_type","completion_digest",
        "lifecycle_dispatch_id","native_agent_id","tracked"])
      and (.tracked | type == "boolean")
      and (.agent_type | type == "string" and length > 0 and length <= 128)
      and (.completion_digest | type == "string"
        and test("^[A-Fa-f0-9]{16,128}$"))
      and (.lifecycle_dispatch_id | type == "string" and length <= 128)
      and (.native_agent_id | type == "string" and length <= 128)
      and (if .tracked then
        (.lifecycle_dispatch_id
          | test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
        and (.native_agent_id == ""
          or (.native_agent_id | test("^[A-Za-z0-9._:-]{1,128}$")))
      else .lifecycle_dispatch_id == "" end))
    and (.artifacts | type == "array" and length == 11)
    and ([.artifacts[].name] == [
      "session_state.json",
      "pending_agents.jsonl",
      "agent_dispatch_starts.jsonl",
      "current_plan.md",
      "quality_contract.json",
      "quality_contract_history.jsonl",
      "quality_evidence.jsonl",
      "quality_frontier.json",
      "quality_frontier_history.jsonl",
      "plan_publication_outcomes.jsonl",
      "plan_recovery_notices.jsonl"
    ])
    and all(.artifacts[];
      type == "object"
      and (keys | sort == ["kind","name","seals"])
      and (.name | type == "string")
      and (.kind == "file" or .kind == "absent")
      and (.seals | type == "array")
      and (if .kind == "absent" then (.seals | length) == 0
        else (.seals | length) >= 1 and (.seals | length) <= 2
          and all(.seals[];
            type == "object"
            and (keys | sort == ["sha256","size"])
            and (.size | type == "number" and . >= 0 and floor == .)
            and (.sha256 | type == "string"
              and test("^[A-Fa-f0-9]{64}$")))
          and ((.seals | unique_by([.size,.sha256]) | length)
            == (.seals | length))
        end))
  ' "${ready}" >/dev/null 2>&1
}

_validate_active_plan_transaction_unlocked() {
  local dir="$1" artifact file_marker absent_marker marker_count kind seal
  [[ -d "${dir}" && ! -L "${dir}" ]] || return 1
  _validate_plan_transaction_ready_unlocked "${dir}/.ready" || return 1
  while IFS= read -r artifact; do
    file_marker="${dir}/${artifact}.file"
    absent_marker="${dir}/${artifact}.absent"
    marker_count=0
    if [[ -e "${file_marker}" || -L "${file_marker}" ]]; then
      [[ -f "${file_marker}" && ! -L "${file_marker}" ]] || return 1
      marker_count=$((marker_count + 1))
    fi
    if [[ -e "${absent_marker}" || -L "${absent_marker}" ]]; then
      [[ -f "${absent_marker}" && ! -L "${absent_marker}" ]] || return 1
      marker_count=$((marker_count + 1))
    fi
    [[ "${marker_count}" -eq 1 ]] || return 1
    kind="$(jq -r --arg name "${artifact}" \
      '.artifacts[] | select(.name == $name) | .kind' \
      "${dir}/.ready")" || return 1
    if [[ "${kind}" == "file" ]]; then
      [[ -f "${file_marker}" && ! -L "${file_marker}" \
          && ! -e "${absent_marker}" && ! -L "${absent_marker}" ]] \
        || return 1
      seal="$(_plan_snapshot_seal_json "${file_marker}")" || return 1
      jq -e --arg name "${artifact}" --argjson observed "${seal}" '
        any(.artifacts[] | select(.name == $name).seals[];
          . == $observed)
      ' "${dir}/.ready" >/dev/null 2>&1 || return 1
    elif [[ "${kind}" == "absent" ]]; then
      [[ -f "${absent_marker}" && ! -L "${absent_marker}" \
          && ! -s "${absent_marker}" \
          && ! -e "${file_marker}" && ! -L "${file_marker}" ]] \
        || return 1
    else
      return 1
    fi
  done < <(_plan_transaction_artifacts)
}

_plan_authorize_snapshot_candidate_unlocked() {
  local active_dir="$1" artifact="$2" candidate="$3"
  local marker ready next current_seal candidate_seal boundary
  marker="${active_dir}/${artifact}.file"
  ready="${active_dir}/.ready"
  next="${active_dir}/.ready.next"
  _validate_active_plan_transaction_unlocked "${active_dir}" || return 1
  [[ -f "${marker}" && ! -L "${marker}" \
      && -f "${candidate}" && ! -L "${candidate}" \
      && ! -e "${next}" && ! -L "${next}" ]] || return 1
  current_seal="$(_plan_snapshot_seal_json "${marker}")" || return 1
  candidate_seal="$(_plan_snapshot_seal_json "${candidate}")" || return 1
  if ! jq --arg name "${artifact}" \
      --argjson current "${current_seal}" \
      --argjson candidate "${candidate_seal}" '
      if ([.artifacts[] | select(.name == $name and .kind == "file")]
          | length) != 1 then error("missing file snapshot descriptor")
      else .artifacts |= map(
        if .name == $name then
          .seals = ([$current,$candidate] | unique_by([.size,.sha256]))
        else . end)
      end
    ' "${ready}" >"${next}"; then
    rm -f "${next}" 2>/dev/null || true
    return 1
  fi
  chmod 600 "${next}" 2>/dev/null || {
    rm -f "${next}" 2>/dev/null || true
    return 1
  }
  _validate_plan_transaction_ready_unlocked "${next}" \
    && _plan_snapshot_matches_seal "${marker}" "${current_seal}" \
    && _plan_snapshot_matches_seal "${candidate}" "${candidate_seal}" \
    || { rm -f "${next}" 2>/dev/null || true; return 1; }
  mv -f "${next}" "${ready}" || return 1
  case "${artifact}" in
    pending_agents.jsonl)
      boundary="after-cold-pending-ready-seal-before-marker-rename"
      ;;
    agent_dispatch_starts.jsonl)
      boundary="after-cold-start-ready-seal-before-marker-rename"
      ;;
    *) return 1 ;;
  esac
  # `.ready` now authorizes both the old and candidate snapshot seals. A death
  # before the marker rename must therefore remain a valid, retryable WAL.
  _plan_transaction_boundary "${boundary}" || return 1
  _plan_snapshot_matches_seal "${marker}" "${current_seal}" \
    && _plan_snapshot_matches_seal "${candidate}" "${candidate_seal}" \
    || return 1
  mv -f "${candidate}" "${marker}" || return 1
  _plan_snapshot_matches_seal "${marker}" "${candidate_seal}" \
    && _validate_active_plan_transaction_unlocked "${active_dir}"
}

_plan_replace_snapshot_line_authorized_unlocked() {
  local active_dir="$1" artifact="$2" selected="$3" replacement="$4"
  local marker candidate
  case "${artifact}" in
    pending_agents.jsonl|agent_dispatch_starts.jsonl) ;;
    *) return 1 ;;
  esac
  marker="${active_dir}/${artifact}.file"
  candidate="${active_dir}/.${artifact}.cold-next"
  [[ -f "${marker}" && ! -L "${marker}" \
      && ! -e "${candidate}" && ! -L "${candidate}" ]] || return 1
  cp "${marker}" "${candidate}" || return 1
  chmod 600 "${candidate}" 2>/dev/null || {
    rm -f "${candidate}" 2>/dev/null || true
    return 1
  }
  if ! rewrite_jsonl_line_atomic "${candidate}" \
      "${selected}" "${replacement}"; then
    rm -f "${candidate}" 2>/dev/null || true
    return 1
  fi
  _plan_authorize_snapshot_candidate_unlocked \
    "${active_dir}" "${artifact}" "${candidate}"
}

_publish_plan_recovery_notice_unlocked() {
  local active_dir="$1" notice_file source temp transaction_id owner notice
  local rows
  transaction_id="$(jq -r '.transaction_id' "${active_dir}/.ready")" \
    || return 1
  owner="$(jq -c '.owner' "${active_dir}/.ready")" || return 1
  notice_file="$(session_file "plan_recovery_notices.jsonl")"
  [[ ! -L "${notice_file}" ]] \
    && { [[ ! -e "${notice_file}" ]] || [[ -f "${notice_file}" ]]; } \
    || return 1
  source="${notice_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  rows="$(jq -Rsc '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null)]
    | if all(.[];
        type == "object"
        and .schema_version == 1
        and (.transaction_id | type == "string"
          and test("^plan-txn-[A-Fa-f0-9]{16,128}$"))
        and (.recovered_at | type == "number" and . >= 0)
        and (.retry_issued | type == "boolean")
        and (.owner | type == "object"))
      then . else error("invalid planner recovery notice ledger") end
  ' "${source}")" || return 1
  if jq -e --arg transaction_id "${transaction_id}" \
      --argjson owner "${owner}" '
      ([.[] | select(.transaction_id == $transaction_id)] | length) == 1
      and ([.[] | select(.transaction_id == $transaction_id)][0].owner
        == $owner)
    ' <<<"${rows}" >/dev/null 2>&1; then
    return 0
  fi
  jq -e --arg transaction_id "${transaction_id}" '
    all(.[]; .transaction_id != $transaction_id)
  ' <<<"${rows}" >/dev/null 2>&1 || return 1
  notice="$(jq -nc \
    --arg transaction_id "${transaction_id}" \
    --argjson recovered_at "$(now_epoch)" \
    --argjson owner "${owner}" '
      {
        schema_version:1,
        transaction_id:$transaction_id,
        recovered_at:$recovered_at,
        retry_issued:false,
        owner:$owner
      }
    ')" || return 1
  temp="$(mktemp "${notice_file}.XXXXXX")" || return 1
  chmod 600 "${temp}" 2>/dev/null || {
    rm -f "${temp}"
    return 1
  }
  if ! jq -cn --argjson rows "${rows}" --argjson notice "${notice}" '
      (($rows | if length > 31 then .[-31:] else . end) + [$notice])[]
    ' >"${temp}" || ! mv -f "${temp}" "${notice_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
}

_recover_plan_transaction_unlocked() {
  local active_dir recovered_dir artifact path marker tmp owner
  _plan_recovery_performed=0
  _plan_recovery_owner_json='{}'
  _cleanup_plan_transaction_inert_dirs_unlocked || return 1
  active_dir="$(session_file ".plan-txn.active")"
  if [[ ! -e "${active_dir}" && ! -L "${active_dir}" ]]; then
    return 0
  fi
  _cleanup_plan_transaction_staging_unlocked "${active_dir}" || return 1
  _validate_active_plan_transaction_unlocked "${active_dir}" || {
    log_anomaly "record-plan" "corrupt or ambiguous active plan transaction"
    return 1
  }
  owner="$(jq -c '.owner' "${active_dir}/.ready")" || return 1
  # Preflight every current target before restoring the first one.  A hostile
  # target shape leaves the complete journal in place for explicit recovery.
  _validate_plan_transaction_targets_unlocked || return 1
  while IFS= read -r artifact; do
    path="$(session_file "${artifact}")"
    marker="${active_dir}/${artifact}.file"
    if [[ -f "${marker}" ]]; then
      tmp="$(mktemp "${path}.recover.XXXXXX")" || return 1
      if ! cp "${marker}" "${tmp}" \
          || ! chmod 600 "${tmp}" 2>/dev/null \
          || ! mv -f "${tmp}" "${path}"; then
        rm -f "${tmp}" 2>/dev/null || true
        return 1
      fi
    elif [[ -f "${path}" ]]; then
      rm -f "${path}" || return 1
    fi
    _plan_transaction_boundary "after-recover-${artifact}" || return 1
  done < <(_plan_transaction_artifacts)
  # This exact-owner notice is part of rollback publication. It lands while
  # the fixed WAL is still live, after its own old snapshot has been restored.
  # A death before the fixed-name rename simply restores and republishes the
  # same transaction-id row on retry; after rename it is durable evidence that
  # only this planner callback may receive one re-publication continuation.
  _publish_plan_recovery_notice_unlocked "${active_dir}" || return 1
  _plan_transaction_boundary "after-recovery-notice-publish" || return 1
  recovered_dir="$(session_file ".plan-txn.recovered.$$.$RANDOM")"
  [[ ! -e "${recovered_dir}" && ! -L "${recovered_dir}" ]] || return 1
  # Renaming the fixed active name is the rollback commit point.  Before it,
  # recovery is idempotent; after it, the restored old generation is canonical.
  mv "${active_dir}" "${recovered_dir}" || return 1
  _plan_recovery_performed=1
  _plan_recovery_owner_json="${owner}"
  _plan_transaction_boundary "after-recovery-commit" || return 1
  _discard_plan_transaction_dir "${recovered_dir}" 2>/dev/null || true
}

# Cold SessionStart has no retained native callback to return the interrupted
# plan again. Validate the exact planner authority from the rollback snapshot,
# convert that snapshot's two causal rows into explicit abandonment tombstones,
# restore the old generation, retire only its now-unreceiptable waiter, and
# expose a fresh one-use rebind token. Modifying the rollback snapshot before
# restore keeps interruption recoverable: the fixed WAL remains authoritative
# until both tombstones and every old artifact have reached their canonical
# paths.
_recover_plan_transaction_for_cold_resume_unlocked() {
  local active_dir pending_snapshot starts_snapshot owner bundle pending_line start_line
  local marked_pending marked_start lifecycle native agent waiters_file receipts_file
  local matches waiter_line owner_completion_digest token_digest token suffix=1
  local base_token existing_pending_token existing_start_token existing_token
  local existing_expected existing_total token_count token_is_derived
  local now registry token_in_use transaction_id handoff_file handoff_temp handoff
  local _plan_cold_path _plan_cold_line _plan_cold_allow_noise
  _plan_cold_resume_recovered=0
  _plan_cold_resume_rebind_id=""
  _plan_cold_resume_lifecycle_id=""
  _plan_cold_resume_native_id=""
  _plan_cold_resume_agent_type=""
  _cleanup_plan_transaction_inert_dirs_unlocked || return 1
  active_dir="$(session_file ".plan-txn.active")"
  if [[ ! -e "${active_dir}" && ! -L "${active_dir}" ]]; then
    return 0
  fi
  _cleanup_plan_transaction_staging_unlocked "${active_dir}" || return 1
  _validate_active_plan_transaction_unlocked "${active_dir}" || return 1
  owner="$(jq -c '.owner' "${active_dir}/.ready")" || return 1
  transaction_id="$(jq -r '.transaction_id // empty' \
    "${active_dir}/.ready")" || return 1
  jq -e '
    .tracked == true
    and (.lifecycle_dispatch_id
      | test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
    and (.native_agent_id | test("^[A-Za-z0-9._:-]{1,128}$"))
  ' <<<"${owner}" >/dev/null 2>&1 || return 1
  pending_snapshot="${active_dir}/pending_agents.jsonl.file"
  starts_snapshot="${active_dir}/agent_dispatch_starts.jsonl.file"
  [[ -f "${pending_snapshot}" && ! -L "${pending_snapshot}" \
      && -f "${starts_snapshot}" && ! -L "${starts_snapshot}" ]] || return 1
  bundle="$(jq -n \
    --rawfile pending "${pending_snapshot}" \
    --rawfile starts "${starts_snapshot}" \
    --argjson owner "${owner}" '
      # pending_agents is a compatibility ledger and historically preserves
      # unrelated malformed lines.  They are not planner authority: select
      # exact object rows while keeping the stateful start snapshot strict.
      def pending_rows($raw): [$raw | split("\n")[]
        | select(length > 0)
        | (try fromjson catch null) | select(type == "object")];
      def rows($raw): [$raw | split("\n")[] | select(length > 0) | fromjson];
      def planner: ((.agent_type // "")
        | IN("quality-planner","prometheus"));
      (pending_rows($pending) | map(select(planner
        and (((.review_dispatch_abandoned // false) != true)
          or (.review_dispatch_abandonment_reason // "")
            == "cold-resume-interrupted-planner-publication")
        and ((.lifecycle_dispatch_id // "")
          | test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
        and ((.native_agent_id // "")
          | test("^[A-Za-z0-9._:-]{1,128}$"))
        and (.lifecycle_dispatch_id // "") == $owner.lifecycle_dispatch_id
        and (.native_agent_id // "") == $owner.native_agent_id
        and (.agent_type // "") == $owner.agent_type))) as $p
      | (rows($starts) | map(select(planner
        and (((.review_dispatch_abandoned // false) != true)
          or (.review_dispatch_abandonment_reason // "")
            == "cold-resume-interrupted-planner-publication")
        and (.lifecycle_dispatch_id // "") == $owner.lifecycle_dispatch_id
        and (.native_agent_id // "") == $owner.native_agent_id
        and (.agent_type // "") == $owner.agent_type))) as $s
      | if ($p | length) != 1 or ($s | length) != 1
          or $p[0].lifecycle_dispatch_id != $s[0].lifecycle_dispatch_id
          or $p[0].native_agent_id != $s[0].native_agent_id
          or $p[0].agent_type != $s[0].agent_type
        then error("ambiguous cold-resume planner authority")
        else {pending:$p[0],start:$s[0]} end
    ' 2>/dev/null)" || return 1
  pending_line="$(jq -c '.pending' <<<"${bundle}")"
  start_line="$(jq -c '.start' <<<"${bundle}")"
  lifecycle="$(jq -r '.lifecycle_dispatch_id' <<<"${pending_line}")"
  native="$(jq -r '.native_agent_id' <<<"${pending_line}")"
  agent="$(jq -r '.agent_type' <<<"${pending_line}")"
  owner_completion_digest="$(jq -r '.completion_digest' <<<"${owner}")"

  token_digest="$(_omc_token_digest "${lifecycle}|${native}|cold-resume")" \
    || return 1
  base_token="rebind-resume-${token_digest:0:24}"
  token="${base_token}"
  registry="$(session_file "dispatch_rebind_ids.log")"
  existing_pending_token="$(jq -r '.cold_resume_rebind_id // empty' \
    <<<"${pending_line}")" || return 1
  existing_start_token="$(jq -r '.cold_resume_rebind_id // empty' \
    <<<"${start_line}")" || return 1
  existing_token="${existing_pending_token:-${existing_start_token}}"
  if [[ -n "${existing_token}" ]]; then
    [[ -z "${existing_pending_token}" \
        || "${existing_pending_token}" == "${existing_token}" ]] || return 1
    [[ -z "${existing_start_token}" \
        || "${existing_start_token}" == "${existing_token}" ]] || return 1
    # A prior interrupted attempt may already have written one or both exact
    # tombstones. Reuse only this transaction's deterministic token family;
    # treating its own token as a foreign collision would wedge every retry.
    token_is_derived=0
    [[ "${existing_token}" == "${base_token}" ]] && token_is_derived=1
    suffix=2
    while (( suffix <= 9 && token_is_derived == 0 )); do
      [[ "${existing_token}" \
          == "rebind-resume-${token_digest:0:20}-${suffix}" ]] \
        && token_is_derived=1
      suffix=$((suffix + 1))
    done
    [[ "${token_is_derived}" -eq 1 ]] || return 1
    if [[ -s "${registry}" ]] \
        && awk -F '\t' -v wanted="${existing_token}" \
          '$1 == wanted { found=1 } END { exit(found ? 0 : 1) }' \
          "${registry}" 2>/dev/null; then
      return 1
    fi
    existing_expected=0
    [[ "${existing_pending_token}" == "${existing_token}" ]] \
      && existing_expected=$((existing_expected + 1))
    [[ "${existing_start_token}" == "${existing_token}" ]] \
      && existing_expected=$((existing_expected + 1))
    existing_total=0
    for _plan_cold_path in "${pending_snapshot}" "${starts_snapshot}"; do
      _plan_cold_allow_noise=0
      [[ "${_plan_cold_path}" == "${pending_snapshot}" ]] \
        && _plan_cold_allow_noise=1
      token_count="$(jq -Rsr --arg token "${existing_token}" \
          --argjson allow_noise "${_plan_cold_allow_noise}" '
          [split("\n")[] | select(length > 0)
            | (if $allow_noise == 1 then (try fromjson catch null)
               else fromjson end)
            | select(type == "object")
            | select((.cold_resume_rebind_id // "") == $token
              or (.review_dispatch_id // "") == $token)] | length
        ' "${_plan_cold_path}")" || return 1
      [[ "${token_count}" =~ ^[0-9]+$ ]] || return 1
      existing_total=$((existing_total + token_count))
    done
    [[ "${existing_total}" -eq "${existing_expected}" \
        && "${existing_expected}" -ge 1 ]] || return 1
    token="${existing_token}"
  else
    suffix=1
    while true; do
      token_in_use=0
      if [[ -s "${registry}" ]] \
          && awk -F '\t' -v wanted="${token}" \
            '$1 == wanted { found=1 } END { exit(found ? 0 : 1) }' \
            "${registry}" 2>/dev/null; then
        token_in_use=1
      fi
      for _plan_cold_path in "${pending_snapshot}" "${starts_snapshot}"; do
        _plan_cold_allow_noise=0
        [[ "${_plan_cold_path}" == "${pending_snapshot}" ]] \
          && _plan_cold_allow_noise=1
        if jq -Rse --arg token "${token}" \
            --argjson allow_noise "${_plan_cold_allow_noise}" '
            any(split("\n")[] | select(length > 0);
              (if $allow_noise == 1 then (try fromjson catch {})
               else fromjson end
              | ((.review_dispatch_id // "") == $token
                or (.cold_resume_rebind_id // "") == $token)))
          ' "${_plan_cold_path}" >/dev/null 2>&1; then
          token_in_use=1
        fi
      done
      [[ "${token_in_use}" -eq 0 ]] && break
      suffix=$((suffix + 1))
      (( suffix <= 9 )) || return 1
      token="rebind-resume-${token_digest:0:20}-${suffix}"
    done
  fi

  # A retry after death between the two snapshot rewrites must converge to the
  # same deterministic tombstones, never mint a second identity.
  for _plan_cold_line in "${pending_line}" "${start_line}"; do
    if [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${_plan_cold_line}")" == "true" ]]; then
      [[ "$(jq -r '.review_dispatch_abandonment_reason // empty' \
          <<<"${_plan_cold_line}")" \
          == "cold-resume-interrupted-planner-publication" \
        && "$(jq -r '.cold_resume_rebind_id // empty' \
          <<<"${_plan_cold_line}")" == "${token}" ]] || return 1
    fi
  done
  now="$(now_epoch)"
  [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  marked_pending="$(jq -c --arg token "${token}" --argjson now "${now}" '
      . + {
        review_dispatch_abandoned:true,
        review_dispatch_abandonment_reason:
          "cold-resume-interrupted-planner-publication",
        review_dispatch_abandoned_ts:$now,
        cold_resume_rebind_id:$token
      }
    ' <<<"${pending_line}")" || return 1
  marked_start="$(jq -c --arg token "${token}" --argjson now "${now}" '
      . + {
        review_dispatch_abandoned:true,
        review_dispatch_abandonment_reason:
          "cold-resume-interrupted-planner-publication",
        review_dispatch_abandoned_ts:$now,
        cold_resume_rebind_id:$token
      }
    ' <<<"${start_line}")" || return 1
  [[ "${pending_line}" == "${marked_pending}" ]] \
    || _plan_replace_snapshot_line_authorized_unlocked "${active_dir}" \
      "pending_agents.jsonl" "${pending_line}" "${marked_pending}" \
      || return 1
  _plan_transaction_boundary "after-cold-pending-tombstone" || return 1
  [[ "${start_line}" == "${marked_start}" ]] \
    || _plan_replace_snapshot_line_authorized_unlocked "${active_dir}" \
      "agent_dispatch_starts.jsonl" "${start_line}" "${marked_start}" \
      || return 1
  _plan_transaction_boundary "after-cold-start-tombstone" || return 1

  # Persist the compaction/resume handoff before retiring the fixed WAL. A
  # PreCompact hook may be the process that performs cold recovery, so the
  # following compact SessionStart can no longer discover the owner from the
  # WAL itself. Staging this exact sidecar first closes the crash gap: while a
  # WAL remains it is never trusted, and after successful rollback the
  # tombstoned causal pair below authenticates it.
  handoff_file="$(session_file "plan_cold_recovery_handoff.json")"
  [[ ! -L "${handoff_file}" ]] \
    && { [[ ! -e "${handoff_file}" ]] || [[ -f "${handoff_file}" ]]; } \
    || return 1
  handoff="$(jq -cnS \
    --arg transaction_id "${transaction_id}" \
    --arg lifecycle_dispatch_id "${lifecycle}" \
    --arg native_agent_id "${native}" \
    --arg agent_type "${agent}" \
    --arg completion_digest "${owner_completion_digest}" \
    --arg rebind_id "${token}" \
    --argjson created_at "${now}" '
      {
        schema_version:1,
        status:"pending",
        transaction_id:$transaction_id,
        lifecycle_dispatch_id:$lifecycle_dispatch_id,
        native_agent_id:$native_agent_id,
        agent_type:$agent_type,
        completion_digest:$completion_digest,
        rebind_id:$rebind_id,
        created_at:$created_at
      }
    ')" || return 1
  handoff_temp="$(mktemp "${handoff_file}.XXXXXX")" || return 1
  if ! (umask 077; printf '%s\n' "${handoff}" >"${handoff_temp}") \
      || ! mv -f "${handoff_temp}" "${handoff_file}"; then
    rm -f "${handoff_temp}" 2>/dev/null || true
    return 1
  fi
  _plan_transaction_boundary "after-cold-handoff-stage" || return 1

  _recover_plan_transaction_unlocked || return 1
  # Keep paths and JSON rows as independent values. A colon is legal in HOME
  # and session-root path components, so a `path:${json}` tuple would split a
  # valid target at the wrong byte and make cold recovery spuriously fail.
  _plan_cold_path="$(session_file "pending_agents.jsonl")"
  [[ -f "${_plan_cold_path}" && ! -L "${_plan_cold_path}" ]] || return 1
  matches="$(jq -Rsr --argjson target "${marked_pending}" '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")
      | select(. == $target)] | length
  ' "${_plan_cold_path}" 2>/dev/null)" || return 1
  [[ "${matches}" == "1" ]] || return 1
  _plan_cold_path="$(session_file "agent_dispatch_starts.jsonl")"
  [[ -f "${_plan_cold_path}" && ! -L "${_plan_cold_path}" ]] || return 1
  matches="$(jq -Rsr --argjson target "${marked_start}" '
    [split("\n")[] | select(length > 0) | fromjson
      | select(. == $target)] | length
  ' "${_plan_cold_path}" 2>/dev/null)" || return 1
  [[ "${matches}" == "1" ]] || return 1

  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  receipts_file="$(session_file "plan_publication_outcomes.jsonl")"
  [[ ! -L "${waiters_file}" ]] \
    && { [[ ! -e "${waiters_file}" ]] || [[ -f "${waiters_file}" ]]; } \
    || return 1
  [[ ! -L "${receipts_file}" ]] \
    && { [[ ! -e "${receipts_file}" ]] || [[ -f "${receipts_file}" ]]; } \
    || return 1
  # Rollback must have removed every provisional receipt. An accepted or
  # rejected exact decision belongs to the normal receipt-bound replay path,
  # not cold abandonment.
  if [[ -s "${receipts_file}" ]]; then
    jq -Rse --arg lifecycle "${lifecycle}" '
      all(split("\n")[] | select(length > 0);
        (fromjson | .lifecycle_dispatch_id // "") != $lifecycle)
    ' "${receipts_file}" >/dev/null 2>&1 || return 1
  fi
  if [[ -s "${waiters_file}" ]]; then
    matches="$(jq -Rsr --arg lifecycle "${lifecycle}" \
      --arg native "${native}" --arg agent "${agent}" \
      --arg digest "${owner_completion_digest}" '
        [split("\n")[] | select(length > 0) | . as $raw
          | (fromjson) as $row | select(
            $row.lifecycle_dispatch_id == $lifecycle
            and $row.native_agent_id == $native
            and $row.agent_type == $agent
            and $row.completion_digest == $digest) | $raw] | length
      ' "${waiters_file}" 2>/dev/null)" || return 1
    [[ "${matches}" == "0" || "${matches}" == "1" ]] || return 1
    if [[ "${matches}" == "1" ]]; then
      waiter_line="$(jq -Rsr --arg lifecycle "${lifecycle}" '
        [split("\n")[] | select(length > 0) | . as $raw
          | (fromjson) as $row
          | select($row.lifecycle_dispatch_id == $lifecycle) | $raw][0]
      ' "${waiters_file}")" || return 1
      rewrite_jsonl_line_atomic "${waiters_file}" "${waiter_line}" "" \
        || return 1
    fi
  fi

  _plan_cold_resume_recovered=1
  _plan_cold_resume_rebind_id="${token}"
  _plan_cold_resume_lifecycle_id="${lifecycle}"
  _plan_cold_resume_native_id="${native}"
  _plan_cold_resume_agent_type="${agent}"
}

_activate_plan_transaction_unlocked() {
  local owner="$1" stage_dir active_dir
  _cleanup_plan_transaction_inert_dirs_unlocked || return 1
  active_dir="$(session_file ".plan-txn.active")"
  [[ ! -e "${active_dir}" && ! -L "${active_dir}" ]] || return 1
  stage_dir="$(mktemp -d "$(session_file ".plan-txn.stage.XXXXXX")")" \
    || return 1
  chmod 700 "${stage_dir}" 2>/dev/null || {
    rmdir "${stage_dir}" 2>/dev/null || true
    return 1
  }
  if ! _snapshot_plan_transaction_unlocked "${stage_dir}" "${owner}"; then
    _discard_plan_transaction_dir "${stage_dir}" 2>/dev/null || true
    return 1
  fi
  if ! _plan_transaction_boundary "before-journal-activate"; then
    _discard_plan_transaction_dir "${stage_dir}" 2>/dev/null || true
    return 1
  fi
  if ! mv "${stage_dir}" "${active_dir}"; then
    _discard_plan_transaction_dir "${stage_dir}" 2>/dev/null || true
    return 1
  fi
  _plan_transaction_boundary "after-journal-activate" || return 1
}

_commit_plan_transaction_unlocked() {
  local active_dir committed_dir
  active_dir="$(session_file ".plan-txn.active")"
  _cleanup_plan_transaction_staging_unlocked "${active_dir}" || return 1
  _validate_active_plan_transaction_unlocked "${active_dir}" || return 1
  committed_dir="$(session_file ".plan-txn.committed.$$.$RANDOM")"
  [[ ! -e "${committed_dir}" && ! -L "${committed_dir}" ]] || return 1
  mv "${active_dir}" "${committed_dir}" || return 1
  _plan_transaction_boundary "after-transaction-commit" || return 1
  _discard_plan_transaction_dir "${committed_dir}" 2>/dev/null || true
}

_settle_orphaned_plan_waiter_from_outcome_unlocked() {
  local waiter="$1" lifecycle agent native digest waiters_file receipts_file
  local pending_file starts_file outcomes_file outcomes waiter_raw receipt_status expected
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' <<<"${waiter}")"
  agent="$(jq -r '.agent_type // empty' <<<"${waiter}")"
  native="$(jq -r '.native_agent_id // empty' <<<"${waiter}")"
  digest="$(jq -r '.completion_digest // empty' <<<"${waiter}")"
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  receipts_file="$(session_file "plan_publication_outcomes.jsonl")"
  pending_file="$(session_file "pending_agents.jsonl")"
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  for _plan_settle_file in "${waiters_file}" "${receipts_file}" \
      "${pending_file}" "${starts_file}" "${outcomes_file}"; do
    [[ ! -L "${_plan_settle_file}" ]] \
      && { [[ ! -e "${_plan_settle_file}" ]] \
        || [[ -f "${_plan_settle_file}" ]]; } || return 1
  done
  [[ -s "${waiters_file}" && -s "${receipts_file}" \
      && -s "${outcomes_file}" ]] || return 1
  if [[ -s "${pending_file}" ]] \
      && ! jq -Rse --arg lifecycle "${lifecycle}" '
        all(split("\n")[] | select(length > 0);
          ((try fromjson catch {}) | .lifecycle_dispatch_id // "")
            != $lifecycle)
      ' "${pending_file}" >/dev/null 2>&1; then
    return 1
  fi
  if [[ -s "${starts_file}" ]] \
      && ! jq -Rse --arg lifecycle "${lifecycle}" '
        all(split("\n")[] | select(length > 0);
          (fromjson | .lifecycle_dispatch_id // "") != $lifecycle)
      ' "${starts_file}" >/dev/null 2>&1; then
    return 1
  fi
  waiter_raw="$(jq -Rsr \
    --arg lifecycle "${lifecycle}" --arg agent "${agent}" \
    --arg native "${native}" --arg digest "${digest}" '
      [split("\n")[] | select(length > 0) | . as $raw
        | (fromjson) as $row | select(
          $row.lifecycle_dispatch_id == $lifecycle
          and $row.agent_type == $agent
          and $row.native_agent_id == $native
          and $row.completion_digest == $digest) | $raw] as $matches
      | if ($matches | length) == 1 then $matches[0] else error("waiter") end
    ' "${waiters_file}" 2>/dev/null)" || return 1
  receipt_status="$(jq -Rsr \
    --arg lifecycle "${lifecycle}" --arg agent "${agent}" \
    --arg native "${native}" --arg digest "${digest}" '
      [split("\n")[] | select(length > 0) | fromjson | select(
        .lifecycle_dispatch_id == $lifecycle
        and .agent_type == $agent and .native_agent_id == $native
        and .completion_digest == $digest)] as $matches
      | if ($matches | length) == 1 then $matches[0].status
        else error("receipt") end
    ' "${receipts_file}" 2>/dev/null)" || return 1
  case "${receipt_status}" in
    accepted) expected="accepted" ;;
    rejected) expected="ignored" ;;
    *) return 1 ;;
  esac
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" \
      --arg lifecycle "${lifecycle}" --arg agent "${agent}" \
      --arg native "${native}" --arg expected "${expected}" '
    ([$outcomes[] | select(
      .lifecycle_dispatch_id == $lifecycle
      and .agent_type == $agent and .native_agent_id == $native
      and .status == $expected)] | length) == 1
  ' >/dev/null 2>&1 || return 1
  rewrite_jsonl_line_atomic "${waiters_file}" "${waiter_raw}" ""
}

# Replay every waiter whose exact dedicated-plan receipt is already durable.
# The waiter is itself the post-commit recovery queue: a crash after the WAL's
# commit point but before the in-process replay loses only volatile work. The
# next router/Agent/continuity barrier calls this function, and success requires
# the universal hook to retire the exact waiter. Waiters without a receipt still
# represent a genuinely in-flight planner and are left untouched.
_replay_receipted_plan_summary_waiters() {
  local script_dir="$1" waiters_file receipts_file waiters receipts waiter
  local pending_file pending_rows lifecycle agent native digest message
  local claim match_count remaining
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  receipts_file="$(session_file "plan_publication_outcomes.jsonl")"
  pending_file="$(session_file "pending_agents.jsonl")"
  for _plan_replay_file in "${waiters_file}" "${receipts_file}" \
      "${pending_file}"; do
    [[ ! -L "${_plan_replay_file}" ]] \
      && { [[ ! -e "${_plan_replay_file}" ]] \
        || [[ -f "${_plan_replay_file}" ]]; } || return 1
  done
  [[ -s "${waiters_file}" ]] || return 0
  # The waiter's digest is executable replay authority, not just a field with
  # a plausible shape. Use the shared snapshot parser so modified/NUL-bearing
  # messages fail before a child summary hook can recursively redispatch this
  # same unrecoverable pair.
  waiters="$(omc_summary_waiter_ledger_json_unlocked \
    plan "${waiters_file}")" || return 1
  if [[ -s "${receipts_file}" ]]; then
    receipts="$(_omc_strict_jsonl_array_unlocked \
      "${receipts_file}" 4194304 128)" || return 1
  else
    receipts='[]'
  fi
  jq -e '
    all(.[];
      type == "object" and .schema_version == 1
      and (keys | sort == ["agent_type","completion_digest","decided_at",
        "lifecycle_dispatch_id","native_agent_id","reason",
        "result_plan_revision","schema_version","start_plan_revision",
        "status","verdict"])
      and all(.. | strings; index("\u0000") == null)
      and (.decided_at | type == "number" and . >= 0
        and . <= 999999999999999 and floor == .)
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
      and (.agent_type | type == "string" and length > 0
        and length <= 128)
      and (.native_agent_id | type == "string"
        and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.completion_digest | type == "string"
        and test("^[A-Fa-f0-9]{16,128}$"))
      and (.status | IN("accepted","rejected"))
      and (.reason | type == "string" and length <= 120)
      and (.verdict | IN("PLAN_READY","NEEDS_CLARIFICATION","BLOCKED"))
      and (.start_plan_revision | type == "number" and . >= 0
        and . <= 999999999999999 and floor == .)
      and (.result_plan_revision | type == "number" and . >= 0
        and . <= 999999999999999 and floor == .))
    and (([.[].lifecycle_dispatch_id] | unique | length) == length)
  ' <<<"${receipts}" >/dev/null 2>&1 || return 1
  pending_rows='[]'
  if [[ -s "${pending_file}" ]]; then
    _omc_publication_claim_timestamps_valid_unlocked \
      "${pending_file}" || return 1
    pending_rows="$(omc_dispatch_authority_ledger_json_unlocked \
      "${pending_file}")" || return 1
  fi

  while IFS= read -r waiter; do
    [[ -n "${waiter}" ]] || continue
    lifecycle="$(jq -r '.lifecycle_dispatch_id' <<<"${waiter}")"
    agent="$(jq -r '.agent_type' <<<"${waiter}")"
    native="$(jq -r '.native_agent_id' <<<"${waiter}")"
    digest="$(jq -r '.completion_digest' <<<"${waiter}")"
    message="$(jq -r '.message' <<<"${waiter}")"
    claim="$(jq -r -n --argjson pending "${pending_rows}" \
      --arg lifecycle "${lifecycle}" --arg agent "${agent}" \
      --arg native "${native}" '
        [$pending[] | select(
          (.lifecycle_dispatch_id // "") == $lifecycle
          and (.agent_type // "") == $agent
          and (.native_agent_id // "") == $native
          and (.review_dispatch_abandoned // false) != true)] as $matches
        | if ($matches | length) <= 1
          then ($matches[0].completion_claim_id // "")
          else error("ambiguous pending lifecycle") end
      ' 2>/dev/null)" || return 1
    [[ -z "${claim}" \
        || "${claim}" =~ ^completion-[A-Za-z0-9._:-]{8,160}$ ]] \
      || return 1
    match_count="$(jq -r \
      --arg lifecycle "${lifecycle}" --arg agent "${agent}" \
      --arg native "${native}" --arg digest "${digest}" '
        [.[] | select(
          (.lifecycle_dispatch_id // "") == $lifecycle
          and (.agent_type // "") == $agent
          and (.native_agent_id // "") == $native
          and (.completion_digest // "") == $digest
          and ((.status // "") | IN("accepted","rejected"))
        )] | length
      ' <<<"${receipts}")" || return 1
    [[ "${match_count}" == "0" ]] && continue
    [[ "${match_count}" == "1" ]] || return 1
    jq -nc \
      --arg sid "${SESSION_ID}" --arg agent "${agent}" \
      --arg native "${native}" --arg message "${message}" '
        {session_id:$sid,agent_type:$agent,agent_id:$native,
         last_assistant_message:$message,stop_hook_active:false}
      ' | OMC_PLAN_SUMMARY_REPLAY=1 OMC_PUBLICATION_RECOVERY_INTERNAL=1 \
        OMC_PUBLICATION_RECOVERY_CLAIM_ID="${claim}" \
        bash "${script_dir}/record-subagent-summary.sh" \
        >/dev/null 2>&1 || return 1
    remaining="$(jq -Rsr --arg lifecycle "${lifecycle}" '
      [split("\n")[] | select(length > 0) | fromjson
        | select(.lifecycle_dispatch_id == $lifecycle)] | length
    ' "${waiters_file}" 2>/dev/null)" || return 1
    if [[ "${remaining}" != "0" ]]; then
      with_state_lock_publication_recovery \
        _settle_orphaned_plan_waiter_from_outcome_unlocked \
        "${waiter}" || return 1
      remaining="$(jq -Rsr --arg lifecycle "${lifecycle}" '
        [split("\n")[] | select(length > 0) | fromjson
          | select(.lifecycle_dispatch_id == $lifecycle)] | length
      ' "${waiters_file}" 2>/dev/null)" || return 1
    fi
    [[ "${remaining}" == "0" ]] || return 1
  done < <(jq -c '.[]' <<<"${waiters}")
}
