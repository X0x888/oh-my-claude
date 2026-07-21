#!/usr/bin/env bash

set -euo pipefail

_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
# shellcheck source=common.sh
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE

_deactivation_cleanup_node_present() {
  local sid="$1" node session_dir
  session_dir="${STATE_ROOT}/${sid}"
  for node in "${session_dir}"/.deactivate-txn.* \
              "${session_dir}"/.plan-txn.active \
              "${session_dir}"/.reviewer-transaction.wal \
              "${session_dir}"/.dispatch-settled.* \
              "${session_dir}"/.native-bind-settled.* \
              "${session_dir}"/.plan-txn.stage.* \
              "${session_dir}"/.plan-txn.committed.* \
              "${session_dir}"/.plan-txn.recovered.* \
              "${session_dir}"/.reviewer-transaction.prepare.* \
              "${session_dir}"/.reviewer-transaction.committed.* \
              "${session_dir}"/.reviewer-publication.stage.* \
              "${session_dir}"/quality_evidence.jsonl.tmp.* \
              "${session_dir}"/quality_frontier.json.tmp.* \
              "${session_dir}"/quality_frontier_history.jsonl.tmp.*; do
    [[ -e "${node}" || -L "${node}" ]] && return 0
  done
  return 1
}

# Prefer an explicitly addressed session. Claude Code 2.1.132+ exports
# CLAUDE_CODE_SESSION_ID to Bash subprocesses, while skill substitution can
# pass the same identity as argv. SESSION_ID remains a legacy/manual fallback.
# A mutating lifecycle command must never guess by newest mtime.
target_source=""
selected_recovery_present=0
if [[ -n "${1:-}" ]]; then
  latest_session="$1"
  target_source="argument"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  latest_session="${CLAUDE_CODE_SESSION_ID}"
  target_source="claude-environment"
elif [[ -n "${SESSION_ID:-}" ]]; then
  latest_session="${SESSION_ID}"
  target_source="legacy-environment"
else
  latest_session=""
fi
if [[ -n "${latest_session}" ]]; then
  validate_session_id "${latest_session}" || {
    printf 'Invalid ULW session id; nothing deactivated.\n' >&2
    exit 1
  }
  selected_state="${STATE_ROOT}/${latest_session}/${STATE_JSON}"
  if omc_interrupted_dispatch_transaction_present \
      "${latest_session}"; then
    selected_recovery_present=1
  elif _deactivation_cleanup_node_present "${latest_session}"; then
    # Exact reset is also the deterministic garbage collector for inert or
    # malformed reset quarantine. Do not let state=off make such nodes
    # unreachable until a later activation turns them into a global fence.
    selected_recovery_present=1
  fi
  selected_active="$(jq -r '
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
  ' "${selected_state}" 2>/dev/null || true)"
  if [[ "${selected_active}" == "unknown" \
      && -f "${STATE_ROOT}/${latest_session}/.ulw_active" ]]; then
    selected_active="on"
  fi
  if [[ "${selected_active}" != "on" ]]; then
    if [[ "${target_source}" == "argument" ]]; then
      if [[ "${selected_recovery_present}" -eq 1 ]]; then
        # The exact reset remains reachable even when interrupted state is
        # malformed or already says off. A retained direct admission node is
        # stronger evidence than the provisional authority bit and must be
        # quarantined before success is reported.
        :
      elif [[ -f "${selected_state}" ]]; then
        printf 'Ultrawork mode is already inactive for session %s.\n' "${latest_session}"
        exit 0
      else
        printf 'No state exists for ULW session %s; nothing deactivated.\n' \
          "${latest_session}" >&2
        exit 1
      fi
    else
      # `--continue`/ID-less resume can expose an older startup ID in the Bash
      # environment. Do not mutate it; fall through to the unique-active-cwd
      # compatibility search below.
      latest_session=""
    fi
  fi
fi

if [[ -z "${latest_session}" ]]; then
  # Last-resort compatibility for direct shells: accept exactly one active
  # ULW session whose recorded cwd is this cwd. Refuse zero/multiple matches;
  # unlike read-only status helpers, deactivation never falls back across
  # projects or picks one of two same-repo Claude sessions by recency.
  current_cwd="${PWD:-}"
  active_candidate_count=0
  active_candidate_list=""
  for candidate_dir in "${STATE_ROOT}"/*/; do
    [[ -d "${candidate_dir}" ]] || continue
    candidate_state="${candidate_dir}/${STATE_JSON}"
    candidate_cwd="$(_omc_read_nul_free_string_field \
      "${candidate_state}" "cwd" 2>/dev/null || true)"
    [[ -n "${current_cwd}" && "${candidate_cwd}" == "${current_cwd}" ]] || continue
    candidate_active="$(jq -r '
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
    ' "${candidate_state}" 2>/dev/null || true)"
    if [[ "${candidate_active}" == "unknown" \
        && -f "${candidate_dir}/.ulw_active" ]]; then
      candidate_active="on"
    fi
    [[ "${candidate_active}" == "on" ]] || continue
    candidate_sid="$(basename "${candidate_dir}")"
    validate_session_id "${candidate_sid}" 2>/dev/null || continue
    active_candidate_count=$((active_candidate_count + 1))
    active_candidate_list="${active_candidate_list:+${active_candidate_list} }${candidate_sid}"
    latest_session="${candidate_sid}"
  done
  if [[ "${active_candidate_count}" -gt 1 ]]; then
    printf 'Multiple active ULW sessions share this cwd; pass the exact session id: %s\n' \
      "${active_candidate_list}" >&2
    exit 1
  fi
fi

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

# Clear workflow_mode in the addressed session state, along with all the
# compact-continuity flags that would otherwise linger and surprise the user
# on a later compact resume. In particular, a stale review_pending_at_compact
# flag would re-inject a "MUST run quality-reviewer" directive on the next
# compact cycle *after* the user explicitly turned ULW off — that is exactly
# the kind of spooky action at a distance ulw-off is meant to prevent.
SESSION_ID="${latest_session}"
selected_recovery_present=0
if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
  selected_recovery_present=1
elif _deactivation_cleanup_node_present "${SESSION_ID}"; then
  selected_recovery_present=1
fi
[[ -f "${STATE_ROOT}/${SESSION_ID}/${STATE_JSON}" \
    || "${selected_recovery_present}" -eq 1 ]] || {
  printf 'No state exists for ULW session %s; nothing deactivated.\n' \
    "${SESSION_ID}" >&2
  exit 1
}

# Return success when a deactivation transaction contains lifecycle authority
# beyond its immutable generation metadata. The reset writes the generation
# marker before staging anything, so markerless non-empty transactions are
# malformed and must never be mistaken for legacy live rows.
_deactivate_txn_has_staged_authority() {
  local txn="$1" child name journals
  journals="${txn}/journals"
  [[ -d "${txn}" && ! -L "${txn}" ]] || return 0
  if [[ -e "${journals}" || -L "${journals}" ]]; then
    [[ -d "${journals}" && ! -L "${journals}" ]] || return 0
    for child in "${journals}/"* "${journals}/".[!.]* \
        "${journals}/"..?*; do
      [[ -e "${child}" || -L "${child}" ]] || continue
      return 0
    done
  fi
  for child in "${txn}/"* "${txn}/".[!.]* "${txn}/"..?*; do
    [[ -e "${child}" || -L "${child}" ]] || continue
    name="${child##*/}"
    case "${name}" in
      journals|.enforcement-generation|.enforcement-generation.tmp) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# Delete a committed/inert quarantine without ever deleting its generation
# marker before staged content. A process death during cleanup therefore
# leaves either a marked old-generation quarantine or an empty markerless
# directory; it can never make old staged authority look like same-generation
# legacy state after reactivation.
_cleanup_committed_deactivate_transaction() {
  local txn="$1" child name session_dir
  session_dir="${STATE_ROOT}/${SESSION_ID}"
  [[ "${txn%/*}" == "${session_dir}" \
      && "${txn##*/}" == .deactivate-txn.* ]] || return 1
  if [[ -L "${txn}" || ! -d "${txn}" ]]; then
    rm -f -- "${txn}" 2>/dev/null || return 1
    [[ ! -e "${txn}" && ! -L "${txn}" ]]
    return
  fi
  for child in "${txn}/"* "${txn}/".[!.]* "${txn}/"..?*; do
    [[ -e "${child}" || -L "${child}" ]] || continue
    name="${child##*/}"
    [[ "${name}" == ".enforcement-generation" ]] && continue
    rm -rf -- "${child}" 2>/dev/null || return 1
    [[ ! -e "${child}" && ! -L "${child}" ]] || return 1
  done
  rm -f -- "${txn}/.enforcement-generation" 2>/dev/null || return 1
  [[ ! -e "${txn}/.enforcement-generation" \
      && ! -L "${txn}/.enforcement-generation" ]] || return 1
  rmdir "${txn}" 2>/dev/null
}

_read_dispatch_attempted_agent_type() {
  local path="$1" value="" byte_count=""
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  byte_count="$(LC_ALL=C wc -c <"${path}" 2>/dev/null)" \
    || return 1
  byte_count="${byte_count//[[:space:]]/}"
  [[ "${byte_count}" =~ ^[0-9]+$ \
      && "${byte_count}" -ge 2 && "${byte_count}" -le 129 ]] || return 1
  value="$(cat "${path}" 2>/dev/null)" || return 1
  [[ "${value}" =~ ^[A-Za-z0-9_.:-]{1,128}$ ]] || return 1
  printf '%s\n' "${value}" \
    | cmp -s - "${path}" 2>/dev/null || return 1
  printf '%s' "${value}"
}

# Move an untrusted immediate-child artifact into the current reset quarantine
# without dereferencing it. This keeps exact /ulw-off convergent when a causal
# registry was replaced by a symlink, directory, FIFO, or other non-regular
# node: readable identities are lost conservatively, while the tracking-version
# stamps committed below reject every late unbound completion.
_stage_untrusted_reset_node() {
  local path="$1" txn="$2" label="$3" session_dir untrusted slot
  session_dir="${STATE_ROOT}/${SESSION_ID}"
  [[ "${path%/*}" == "${session_dir}" \
      && "${txn%/*}" == "${session_dir}" \
      && "${txn##*/}" == .deactivate-txn.* \
      && "${label}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || return 1
  [[ -e "${path}" || -L "${path}" ]] || return 0
  untrusted="${txn}/untrusted"
  if [[ -e "${untrusted}" || -L "${untrusted}" ]]; then
    [[ -d "${untrusted}" && ! -L "${untrusted}" ]] || return 1
  else
    mkdir "${untrusted}" || return 1
  fi
  slot="$(mktemp -d "${untrusted}/${label}.XXXXXX")" || return 1
  rmdir "${slot}" || return 1
  mv -- "${path}" "${slot}"
}

# Move an immediate-child lifecycle journal into the current reset quarantine
# without following it. A recovered quarantine may already contain the same
# basename while another direct journal with that name was created before the
# retry. Preserve both under distinct names so exact reset remains convergent
# and neither lifecycle identity is silently discarded.
_stage_reset_journal_node() {
  local path="$1" txn="$2" session_dir journals artifact destination slot
  session_dir="${STATE_ROOT}/${SESSION_ID}"
  journals="${txn}/journals"
  artifact="${path##*/}"
  [[ "${path%/*}" == "${session_dir}" \
      && "${txn%/*}" == "${session_dir}" \
      && "${txn##*/}" == .deactivate-txn.* \
      && -n "${artifact}" \
      && -d "${journals}" && ! -L "${journals}" ]] || return 1
  [[ -e "${path}" || -L "${path}" ]] || return 0
  destination="${journals}/${artifact}"
  if [[ -e "${destination}" || -L "${destination}" ]]; then
    slot="$(mktemp -d "${destination}.reset.XXXXXX")" || return 1
    rmdir "${slot}" || return 1
    destination="${slot}"
  fi
  mv -- "${path}" "${destination}"
}

# Stage a fixed-name transient after an interrupted reset without assuming the
# recovered quarantine's canonical slot is empty. Both the old quarantined
# copy and a stale process's recreated live copy are old-generation authority;
# preserve both until the inactive-state commit, then retire them together.
_stage_reset_transient_node() {
  local path="$1" txn="$2" session_dir artifact destination slot
  session_dir="${STATE_ROOT}/${SESSION_ID}"
  artifact="${path##*/}"
  [[ "${path%/*}" == "${session_dir}" \
      && "${txn%/*}" == "${session_dir}" \
      && "${txn##*/}" == .deactivate-txn.* \
      && -n "${artifact}" ]] || return 1
  [[ -e "${path}" || -L "${path}" ]] || return 0
  destination="${txn}/${artifact}"
  if [[ -e "${destination}" || -L "${destination}" ]]; then
    slot="$(mktemp -d "${destination}.reset.XXXXXX")" || return 1
    rmdir "${slot}" || return 1
    destination="${slot}"
  fi
  mv -- "${path}" "${destination}"
}

_deactivate_session_unlocked() {
  local artifact artifact_path
  local taint_file taint_tmp taint_dedup txn deactivate_txn
  local current_generation generation_tmp txn_generation
  local txn_generation_path txn_generation_tmp _tmp_generation=""
  local taint_source attempted_path attempted_agent quarantine_txn journals_dir
  local untrusted_dir reset_now recovery_was_present=0
  local recovered_deactivate_txn=""
  local stale_deactivate_count=0 attempted_dispatch_count=0 txn_index=0
  local -a stale_deactivate_txns=() attempted_dispatch_txns=()

  # A universal SubagentStop recorder holds its exact pending row as a short
  # completion lease while publishing claim-scoped effects. Do not tear the
  # interval out from under that transaction; a retry moments later succeeds.
  # Once dispatch/reset recovery is already armed, however, ordinary completion
  # hooks are themselves fenced and cannot finish that lease; exact reset must
  # remain the convergence path rather than deadlocking on an unfinishable row.
  if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
    recovery_was_present=1
  fi
  artifact_path="$(session_file "pending_agents.jsonl")"
  reset_now="$(now_epoch)"
  [[ "${reset_now}" =~ ^[0-9]+$ ]] || reset_now=0
  if [[ "${recovery_was_present}" -eq 0 \
      && ! -L "${artifact_path}" && -f "${artifact_path}" \
      && -s "${artifact_path}" ]] && jq -Rse \
      --argjson cutoff "$(( reset_now - 120 ))" \
      --argjson now "${reset_now}" '
        any(split("\n")[] | select(length > 0);
          (try fromjson catch {}) as $row
          | (($row.completion_claim_id // null) | type) == "string"
          and (($row.completion_claim_id // "")
               | test("^[A-Za-z0-9._:-]{1,160}$"))
          and ((($row.completion_claim_effects_complete // false) | type)
               == "boolean")
          and (($row.completion_claim_effects_complete // false) != true)
          and (($row.completion_claim_ts // null) | type) == "number"
          and ($row.completion_claim_ts | floor) == $row.completion_claim_ts
          and $row.completion_claim_ts >= $cutoff
          and $row.completion_claim_ts <= ($now + 5))
      ' "${artifact_path}" >/dev/null 2>&1; then
    log_anomaly "ulw-deactivate" \
      "active subagent completion lease; deactivation refused for retry" \
      2>/dev/null || true
    return 1
  fi

  # Adopt a prior interrupted same-generation deactivation in place. Restoring
  # a multi-file quarantine and staging it again would create a second crash
  # window where only a prefix was live; continuing in the original directory
  # makes every retry monotonic. A different generation is committed inert
  # quarantine from a reset that finished before later reactivation.
  current_generation="$(read_state \
    "ulw_enforcement_generation" 2>/dev/null || true)"
  current_generation="${current_generation:-migration}"
  if [[ ! "${current_generation}" \
      =~ ^(0|[1-9][0-9]{0,17}|migration)$ ]]; then
    current_generation="migration"
  fi
  for txn in "$(session_file ".deactivate-txn.")"*; do
    [[ ! -e "${txn}" && ! -L "${txn}" ]] && continue
    if [[ ! -d "${txn}" || -L "${txn}" ]]; then
      stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
      stale_deactivate_count=$((stale_deactivate_count + 1))
      continue
    fi
    txn_generation_path="${txn}/.enforcement-generation"
    txn_generation_tmp="${txn}/.enforcement-generation.tmp"
    if [[ -e "${txn_generation_tmp}" || -L "${txn_generation_tmp}" ]]; then
      _tmp_generation="$(omc_read_enforcement_generation_marker \
        "${txn_generation_tmp}" 2>/dev/null || true)"
      if [[ -z "${_tmp_generation}" ]]; then
        stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
        stale_deactivate_count=$((stale_deactivate_count + 1))
        continue
      fi
    fi
    txn_generation=""
    if [[ -e "${txn_generation_path}" || -L "${txn_generation_path}" ]]; then
      txn_generation="$(omc_read_enforcement_generation_marker \
        "${txn_generation_path}" 2>/dev/null || true)"
      if [[ -z "${txn_generation}" ]]; then
        stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
        stale_deactivate_count=$((stale_deactivate_count + 1))
        continue
      fi
    else
      # The current protocol publishes the final marker before staging. Only
      # an empty pre-stage shell may be cleaned markerless; content without
      # the final marker could be residue from an unsafe interrupted cleanup.
      if _deactivate_txn_has_staged_authority "${txn}"; then
        stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
        stale_deactivate_count=$((stale_deactivate_count + 1))
        continue
      fi
      rm -rf -- "${txn}/journals" \
        "${txn_generation_tmp}" 2>/dev/null || return 1
      rmdir "${txn}" 2>/dev/null || return 1
      continue
    fi
    if [[ -e "${txn_generation_tmp}" || -L "${txn_generation_tmp}" ]]; then
      if [[ "${_tmp_generation}" != "${txn_generation}" ]]; then
        stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
        stale_deactivate_count=$((stale_deactivate_count + 1))
        continue
      fi
      rm -f -- "${txn_generation_tmp}" || return 1
    fi
    if [[ "${txn_generation}" != "${current_generation}" ]]; then
      stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
      stale_deactivate_count=$((stale_deactivate_count + 1))
      continue
    fi
    journals_dir="${txn}/journals"
    if [[ ! -d "${journals_dir}" || -L "${journals_dir}" ]]; then
      stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
      stale_deactivate_count=$((stale_deactivate_count + 1))
      continue
    fi
    untrusted_dir="${txn}/untrusted"
    if [[ -e "${untrusted_dir}" || -L "${untrusted_dir}" ]] \
        && { [[ ! -d "${untrusted_dir}" ]] \
             || [[ -L "${untrusted_dir}" ]]; }; then
      stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
      stale_deactivate_count=$((stale_deactivate_count + 1))
      continue
    fi
    if [[ -z "${recovered_deactivate_txn}" ]]; then
      recovered_deactivate_txn="${txn}"
    else
      # Multiple canonical same-generation transactions are ambiguous as
      # recovery owners, but exact reset is explicitly authorized to retire
      # their lifecycle authority. Continue one monotonically and quarantine
      # the others as stale after conservatively extracting readable taints.
      stale_deactivate_txns[${stale_deactivate_count}]="${txn}"
      stale_deactivate_count=$((stale_deactivate_count + 1))
    fi
  done

  # Establish the one current-generation quarantine before touching any live
  # registry. This lets invalid causal nodes be renamed into the transaction
  # without dereference and guarantees a process death remains discoverable.
  if [[ -n "${recovered_deactivate_txn}" ]]; then
    deactivate_txn="${recovered_deactivate_txn}"
    current_generation="$(omc_read_enforcement_generation_marker \
      "${deactivate_txn}/.enforcement-generation" 2>/dev/null || true)"
    [[ -n "${current_generation}" ]] || return 1
  else
    deactivate_txn="$(mktemp -d \
      "$(session_file ".deactivate-txn.XXXXXX")")" || return 1
    mkdir "${deactivate_txn}/journals" || {
      rmdir "${deactivate_txn}" 2>/dev/null || true
      return 1
    }
    generation_tmp="${deactivate_txn}/.enforcement-generation.tmp"
    if ! printf '%s\n' "${current_generation}" >"${generation_tmp}" \
        || ! mv "${generation_tmp}" \
          "${deactivate_txn}/.enforcement-generation"; then
      rm -f "${generation_tmp}" 2>/dev/null || true
      rmdir "${deactivate_txn}/journals" 2>/dev/null || true
      rmdir "${deactivate_txn}" 2>/dev/null || true
      return 1
    fi
  fi

  # Durable registries survive a normal reset, but an invalid filesystem node
  # cannot be read safely and would permanently wedge the only allowed recovery
  # command. Quarantine only the invalid node itself; never follow a symlink.
  for artifact in dispatch_tainted_identities.log dispatch_rebind_ids.log \
      native_agent_bindings.jsonl; do
    artifact_path="$(session_file "${artifact}")"
    [[ -e "${artifact_path}" || -L "${artifact_path}" ]] || continue
    if [[ -L "${artifact_path}" || ! -f "${artifact_path}" \
        || ! -r "${artifact_path}" ]]; then
      _stage_untrusted_reset_node "${artifact_path}" "${deactivate_txn}" \
        "invalid-${artifact}" || return 1
    fi
  done

  # Every deleted live identity remains capable of returning after reactivation.
  # Persist the taint before removing causal rows so a later same-agent launch
  # must use a never-reused echoed ID instead of accepting the old result.
  taint_file="$(session_file "dispatch_tainted_identities.log")"
  [[ ! -L "${taint_file}" ]] \
    && { [[ ! -e "${taint_file}" ]] \
         || [[ -f "${taint_file}" && -r "${taint_file}" ]]; } \
    || return 1
  taint_tmp="$(mktemp "${taint_file}.XXXXXX")" || return 1
  [[ ! -f "${taint_file}" ]] || cp "${taint_file}" "${taint_tmp}" || {
    rm -f "${taint_tmp}"
    return 1
  }
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl; do
    taint_source="$(session_file "${artifact}")"
    if [[ ! -L "${taint_source}" && -f "${taint_source}" \
        && -s "${taint_source}" ]]; then
      if ! jq -Rr '
        fromjson?
        | select((.review_dispatch_abandoned // false) != true)
        | (.agent_type // empty)
        | select(type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      ' "${taint_source}" >>"${taint_tmp}"; then
        log_anomaly "ulw-deactivate" \
          "causal ledger unreadable; relying on tracking-version fence (${artifact})" \
          2>/dev/null || true
      fi
    fi
    # Malformed/old-generation quarantine is never restored, but regular
    # causal ledgers inside it can still contribute conservative exact taints.
    # Invalid nodes are not followed; tracking-version stamps cover them.
    for quarantine_txn in "$(session_file ".deactivate-txn.")"*; do
      [[ -d "${quarantine_txn}" && ! -L "${quarantine_txn}" ]] || continue
      taint_source="${quarantine_txn}/${artifact}"
      [[ ! -L "${taint_source}" && -f "${taint_source}" \
          && -s "${taint_source}" ]] || continue
      if ! jq -Rr '
        fromjson?
        | select((.review_dispatch_abandoned // false) != true)
        | (.agent_type // empty)
        | select(type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      ' "${taint_source}" >>"${taint_tmp}"; then
        log_anomaly "ulw-deactivate" \
          "quarantined causal ledger unreadable; relying on tracking-version fence (${artifact})" \
          2>/dev/null || true
      fi
    done
  done
  # The intent file is written immediately after the transaction directory is
  # created and before snapshot copies. It covers the process-death window
  # where Claude Code may launch the Agent after a failed PreTool hook but no
  # pending row exists yet. Missing intent in the smallest mkdir/write window
  # is still contained by the tracking-version stamps committed below.
  for txn in "$(session_file ".dispatch-txn.")"*; do
    [[ -e "${txn}" || -L "${txn}" ]] || continue
    [[ -d "${txn}" && ! -L "${txn}" ]] || continue
    attempted_dispatch_txns[${attempted_dispatch_count}]="${txn}"
    attempted_dispatch_count=$((attempted_dispatch_count + 1))
  done
  for quarantine_txn in "$(session_file ".deactivate-txn.")"*; do
    [[ -d "${quarantine_txn}" && ! -L "${quarantine_txn}" ]] || continue
    journals_dir="${quarantine_txn}/journals"
    [[ -d "${journals_dir}" && ! -L "${journals_dir}" ]] || continue
    for txn in "${journals_dir}"/.dispatch-txn.*; do
      [[ -d "${txn}" && ! -L "${txn}" ]] || continue
      attempted_dispatch_txns[${attempted_dispatch_count}]="${txn}"
      attempted_dispatch_count=$((attempted_dispatch_count + 1))
    done
  done
  for ((txn_index = 0; txn_index < attempted_dispatch_count; txn_index++)); do
    txn="${attempted_dispatch_txns[${txn_index}]}"
    attempted_path="${txn}/attempted-agent-type"
    [[ -e "${attempted_path}" || -L "${attempted_path}" ]] || continue
    attempted_agent="$(_read_dispatch_attempted_agent_type \
      "${attempted_path}" 2>/dev/null || true)"
    if [[ -z "${attempted_agent}" ]]; then
      # Do not follow or trust malformed metadata, but keep the explicit reset
      # convergent. The tracking-version stamps below make every late result
      # without a current pending/native binding fail closed even when this
      # exact attempted name cannot be tainted.
      log_anomaly "ulw-deactivate" \
        "dispatch attempt metadata invalid; relying on tracking-version fence (${txn##*/})" \
        2>/dev/null || true
      continue
    fi
    printf '%s\n' "${attempted_agent}" >>"${taint_tmp}" || {
      rm -f "${taint_tmp}"
      return 1
    }
  done
  taint_dedup="$(mktemp "${taint_file}.dedup.XXXXXX")" || {
    rm -f "${taint_tmp}"
    return 1
  }
  if ! awk 'NF && !seen[$0]++' "${taint_tmp}" >"${taint_dedup}" \
      || ! mv -f "${taint_dedup}" "${taint_file}"; then
    rm -f "${taint_tmp}" "${taint_dedup}"
    return 1
  fi
  rm -f "${taint_tmp}"

  # Interrupted dispatch/native-bind/plan/reviewer journals are never replayed
  # over newer state. Inert reviewer loose stages share the same quarantine so
  # exact reset also removes malformed nodes without dereferencing them. Stage
  # everything by same-filesystem rename with the other transient authority
  # below: deleting authority before the inactive-state commit would make a
  # failed reset silently lose its own fail-closed sentinel.
  for txn in "$(session_file ".dispatch-txn.")"* \
             "$(session_file ".dispatch-settled.")"* \
             "$(session_file ".native-bind-txn.")"* \
             "$(session_file ".native-bind-settled.")"* \
             "$(session_file ".plan-txn.stage.")"* \
             "$(session_file ".plan-txn.committed.")"* \
             "$(session_file ".plan-txn.recovered.")"* \
             "$(session_file ".reviewer-transaction.prepare.")"* \
             "$(session_file ".reviewer-transaction.committed.")"* \
             "$(session_file ".reviewer-publication.stage.")"* \
             "$(session_file "quality_evidence.jsonl.tmp.")"* \
             "$(session_file "quality_frontier.json.tmp.")"* \
             "$(session_file "quality_frontier_history.jsonl.tmp.")"*; do
    [[ ! -e "${txn}" && ! -L "${txn}" ]] && continue
    _stage_reset_journal_node "${txn}" "${deactivate_txn}" || return 1
  done
  if [[ "${OMC_TEST_DEACTIVATE_KILL_AT:-}" == \
      "after-journal-stage" ]]; then
    kill -9 "$$"
  fi

  # /ulw-off is a lifecycle boundary. Pending agents, reviewer-generation
  # starts, and per-tool verification starts all describe work launched under
  # the old active interval; retaining any of them can block or misattribute a
  # later dispatch after reactivation. Keep the tracking-version state key:
  # it makes a late pre-deactivation reviewer completion fail closed instead
  # of falling back to the explicit legacy migration path.
  # Stage every transient path by same-filesystem rename before changing the
  # authority bit. Interrupted attempts retain this same-generation quarantine
  # and the next exact reset continues it in place; no multi-file rollback is
  # needed and no partial restore can expose only a prefix as live.
  for artifact in pending_agents.jsonl agent_dispatch_starts.jsonl \
                  plan_summary_waiters.jsonl plan_publication_outcomes.jsonl \
                  plan_recovery_notices.jsonl plan_cold_recovery_handoff.json \
                  reviewer_summary_waiters.jsonl reviewer_publication_outcomes.jsonl \
                  .plan-txn.active .reviewer-transaction.wal \
                  .verification-starts \
                  .closeout-material-generation .closeout-material-generations \
                  precompact_snapshot.md compact_handoff.md compact_debug.log \
                  .ulw_active; do
    artifact_path="$(session_file "${artifact}")"
    [[ ! -e "${artifact_path}" && ! -L "${artifact_path}" ]] && continue
    _stage_reset_transient_node \
      "${artifact_path}" "${deactivate_txn}" || return 1
  done

  if [[ "${OMC_TEST_DEACTIVATE_KILL_AT:-}" == \
      "after-transient-stage" ]]; then
    kill -9 "$$"
  fi

  if ! _write_state_batch_unlocked \
      "workflow_mode" "" \
      "ulw_enforcement_active" "0" \
      "ulw_enforcement_generation" "${current_generation}" \
      "just_compacted" "" \
      "just_compacted_ts" "" \
      "review_pending_at_compact" "" \
      "compact_race_count" "" \
      "pretool_intent_blocks" "" \
      "agent_first_specialist_ts" "" \
      "agent_first_specialist_type" "" \
      "agent_first_gate_blocks" "" \
      "first_mutation_ts" "" \
      "first_mutation_tool" "" \
      "quality_contract_scope_transition" "" \
      "quality_contract_scope_overflow" "" \
      "council_phase8_active" "" \
      "council_phase8_prompt_revision" "" \
      "subagent_dispatch_tracking_version" "1" \
      "review_dispatch_tracking_version" "1" \
      "plan_dispatch_tracking_version" "1" \
      "native_agent_id_tracking_version" "1"; then
    return 1
  fi

  # The reset commit must describe the same enforcement generation that was
  # quarantined above. The per-session fast-path marker was moved into that
  # quarantine before this state write, so a pre-commit death remains fenced
  # and retryable while a post-commit death can leave only inert residue.
  # Check the complete inactive postcondition while the same state lock is
  # still held; a concurrent activation can linearize only after this returns.
  [[ "$(read_state "workflow_mode" 2>/dev/null || true)" == "" \
      && "$(read_state "ulw_enforcement_active" 2>/dev/null || true)" == "0" \
      && "$(read_state "ulw_enforcement_generation" 2>/dev/null || true)" \
         == "${current_generation}" \
      && ! -e "$(session_file ".ulw_active")" \
      && ! -L "$(session_file ".ulw_active")" ]] || return 1
  if [[ "${OMC_TEST_DEACTIVATE_KILL_AT:-}" == \
      "after-state-commit" ]]; then
    kill -9 "$$"
  fi

  # Authority is now off and the live paths are absent. Cleanup is advisory:
  # a crash or permission error here leaves only a quarantined transaction,
  # never replayable live evidence and never a partially-active session.
  _cleanup_committed_deactivate_transaction \
    "${deactivate_txn}" 2>/dev/null || true
  for ((txn_index = 0; txn_index < stale_deactivate_count; txn_index++)); do
    txn="${stale_deactivate_txns[${txn_index}]}"
    _cleanup_committed_deactivate_transaction "${txn}" \
      2>/dev/null || true
  done
  # The inactive state, absence of direct recovery authority, and retirement
  # of the per-session fast-path marker are one linearized reset commit. A
  # concurrent new /ulw activation can run only after this lock releases and
  # may then recreate its own marker without the old reset deleting it.
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && return 1
  if [[ -n "${OMC_TEST_DEACTIVATE_RETIRE_READY_FILE:-}" \
      && -n "${OMC_TEST_DEACTIVATE_RETIRE_RELEASE_FILE:-}" ]]; then
    : >"${OMC_TEST_DEACTIVATE_RETIRE_READY_FILE}" || return 1
    while [[ ! -e "${OMC_TEST_DEACTIVATE_RETIRE_RELEASE_FILE}" ]]; do
      sleep 0.01
    done
  fi
}

if ! with_state_lock_ulw_deactivate _deactivate_session_unlocked; then
  printf 'Ultrawork mode deactivation could not clear transient state for session %s.\n' \
    "${latest_session}" >&2
  exit 1
fi
printf 'Ultrawork mode deactivated for session %s.\n' "${latest_session}"
