#!/usr/bin/env bash
# omc-config.sh — backend for the /omc-config skill.
#
# Inspects and mutates user/project oh-my-claude.conf via cleanly-named
# subcommands. The /omc-config skill markdown calls this script and the
# AskUserQuestion tool to produce a multi-choice setup/update/change UX.
#
# Atomic writes use tmp+mv. Reads tolerate missing files. Validation
# refuses unknown flags and out-of-range values BEFORE any write lands,
# so a malformed `set` invocation never half-writes the conf.
#
# Subcommands:
#   detect-mode                          Print setup|update|change|not-installed
#   show                                 Pretty-print current effective config
#   list-flags                           Emit known flags as JSON (for skill)
#   set <user|project> <k=v>...          Atomic write of one or more keys
#   apply-preset <user|project> <name>   Apply preset (maximum|zero-steering|balanced|minimal)
#   presets <name>                       Print preset key=value pairs to stdout
#   apply-tier <tier>                    Run switch-tier.sh (rewrites agent files)
#   install-watchdog                     Run install-resume-watchdog.sh
#   mark-completed [user|project]        Stamp omc_config_completed=<ISO date>
#
# Exit codes:
#   0 — success
#   1 — runtime failure (missing dependency, IO error)
#   2 — invalid invocation (unknown flag, bad enum value, bad scope)

set -euo pipefail

CLAUDE_HOME="${HOME}/.claude"
USER_CONF="${CLAUDE_HOME}/oh-my-claude.conf"
SENTINEL_KEY="omc_config_completed"
OPERATION_LOCK_DIR="${CLAUDE_HOME}/.install.lock"
OPERATION_LOCK_HELD=0
OPERATION_LOCK_BORROWED=0
OPERATION_LOCK_TOKEN=""
OPERATION_LOCK_ID=""
OPERATION_LOCK_AUTH_PID=""
OPERATION_LOCK_AUTH_TOKEN=""
OPERATION_LOCK_PARTICIPANT_PATH=""
OPERATION_LOCK_PARTICIPANT_TOKEN=""
OPERATION_LOCK_PARTICIPANT_ID=""
OPERATION_LOCK_RELEASE_MARKER="${OPERATION_LOCK_DIR}/owner-released"
OMC_CONFIG_TX_DIR="${CLAUDE_HOME}/.omc-config-transaction"
OMC_CONFIG_TX_ACTIVE=0
OMC_CONFIG_TX_RECOVERING=0
OMC_CONFIG_TX_ID=""

# Serialize every mutation surface shared with install/uninstall, the watchdog
# installer, and switch-tier. SessionStart auto-tune invokes this helper too,
# so the old "interactive single writer" assumption could lose unrelated rows
# when two sessions or an install overlapped. A pidless/dead-looking lock is
# never reclaimed automatically: the owner may be paused immediately after
# mkdir, and PID reuse is not proof of ownership.
operation_lock_release_marker_matches() {
  local marker_path="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" marker_snapshot="" marker_lock_id=""
  local marker_owner_pid="" marker_owner_token=""
  [[ -n "${marker_path}" && -n "${lock_id}" && -n "${owner_pid}" \
      && -n "${owner_token}" && -f "${marker_path}" \
      && ! -L "${marker_path}" \
      && "$(file_mode_value "${marker_path}" 2>/dev/null || true)" \
        == "600" ]] || return 1
  omc_tx_read_tsv_row "${marker_path}" 4096 || return 1
  marker_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
  [[ "$(awk -F '\t' 'END { print (NR == 1 && NF == 4 && $1 == "v1") ? 1 : 0 }' \
    < <(printf '%s' "${marker_snapshot}"))" == "1" ]] || return 1
  IFS=$'\t' read -r _ marker_lock_id marker_owner_pid marker_owner_token \
    < <(printf '%s' "${marker_snapshot}") || return 1
  [[ "${marker_lock_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${marker_owner_pid}" =~ ^[1-9][0-9]*$ \
      && "${marker_owner_token}" =~ ^[0-9]+(\.[0-9]+){2,3}$ \
      && "${marker_lock_id}" == "${lock_id}" \
      && "${marker_owner_pid}" == "${owner_pid}" \
      && "${marker_owner_token}" == "${owner_token}" ]]
}

operation_lock_generation_matches() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  local actual_pid="" actual_token=""
  omc_lock_read_pid "${OPERATION_LOCK_DIR}/pid" || return 1
  actual_pid="${OMC_TX_TEXT_SNAPSHOT}"
  omc_lock_read_token "${OPERATION_LOCK_DIR}/token" || return 1
  actual_token="${OMC_TX_TEXT_SNAPSHOT}"
  [[ -n "${lock_id}" && -n "${owner_pid}" && -n "${owner_token}" \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && "$(file_identity "${OPERATION_LOCK_DIR}" 2>/dev/null || true)" \
        == "${lock_id}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && "${actual_pid}" == "${owner_pid}" \
      && "${actual_token}" == "${owner_token}" ]]
}

publish_operation_lock_release_marker() {
  operation_lock_generation_matches "${OPERATION_LOCK_ID}" "$$" \
    "${OPERATION_LOCK_TOKEN}" || return 1
  if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]]; then
    operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
      "${OPERATION_LOCK_ID}" "$$" "${OPERATION_LOCK_TOKEN}"
    return
  fi
  if ! (umask 077; set -o noclobber; printf 'v1\t%s\t%s\t%s\n' \
      "${OPERATION_LOCK_ID}" "$$" "${OPERATION_LOCK_TOKEN}" \
      > "${OPERATION_LOCK_RELEASE_MARKER}") 2>/dev/null; then
    return 1
  fi
  chmod 600 "${OPERATION_LOCK_RELEASE_MARKER}" || return 1
  operation_lock_generation_matches "${OPERATION_LOCK_ID}" "$$" \
    "${OPERATION_LOCK_TOKEN}" \
    && operation_lock_release_marker_matches \
      "${OPERATION_LOCK_RELEASE_MARKER}" "${OPERATION_LOCK_ID}" \
      "$$" "${OPERATION_LOCK_TOKEN}"
}

released_operation_lock_is_exact() (
  local root="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" pid_id="${5:-}" token_id="${6:-}"
  local marker_id="${7:-}" entry=""
  local actual_pid="" actual_token=""
  local -a entries=()
  [[ -d "${root}" && ! -L "${root}" \
      && "$(file_identity "${root}" 2>/dev/null || true)" \
        == "${lock_id}" ]] || return 1
  shopt -s nullglob dotglob
  entries=("${root}"/*)
  [[ "${#entries[@]}" -eq 3 ]] || return 1
  for entry in "${entries[@]}"; do
    case "${entry}" in
      "${root}/pid"|"${root}/token"|"${root}/owner-released") ;;
      *) return 1 ;;
    esac
  done
  omc_lock_read_pid "${root}/pid" || return 1
  actual_pid="${OMC_TX_TEXT_SNAPSHOT}"
  omc_lock_read_token "${root}/token" || return 1
  actual_token="${OMC_TX_TEXT_SNAPSHOT}"
  [[ -f "${root}/pid" && ! -L "${root}/pid" \
      && "$(file_identity "${root}/pid" 2>/dev/null || true)" \
        == "${pid_id}" \
      && "${actual_pid}" == "${owner_pid}" \
      && -f "${root}/token" && ! -L "${root}/token" \
      && "$(file_identity "${root}/token" 2>/dev/null || true)" \
        == "${token_id}" \
      && "${actual_token}" == "${owner_token}" \
      && -f "${root}/owner-released" \
      && ! -L "${root}/owner-released" \
      && "$(file_identity "${root}/owner-released" \
        2>/dev/null || true)" == "${marker_id}" ]] || return 1
  operation_lock_release_marker_matches "${root}/owner-released" \
    "${lock_id}" "${owner_pid}" "${owner_token}"
)

reap_released_operation_lock() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  local participant="" pid_id="" token_id="" marker_id=""
  local retired_root="" retired_root_id="" retired_lock=""
  [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
      || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]] || return 0
  operation_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  for participant in "${OPERATION_LOCK_DIR}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 0
  done
  pid_id="$(file_identity "${OPERATION_LOCK_DIR}/pid")" || return 1
  token_id="$(file_identity "${OPERATION_LOCK_DIR}/token")" || return 1
  marker_id="$(file_identity "${OPERATION_LOCK_RELEASE_MARKER}")" \
    || return 1
  released_operation_lock_is_exact "${OPERATION_LOCK_DIR}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" "${pid_id}" "${token_id}" \
    "${marker_id}" || return 1
  retired_root="$(mktemp -d \
    "${CLAUDE_HOME}/.install-lock-retired.XXXXXX")" || return 1
  if ! chmod 700 "${retired_root}"; then
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  retired_root_id="$(file_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  if ! released_operation_lock_is_exact "${OPERATION_LOCK_DIR}" \
      "${lock_id}" "${owner_pid}" "${owner_token}" "${pid_id}" \
      "${token_id}" "${marker_id}"; then
    [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
        == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  if ! command mv -- "${OPERATION_LOCK_DIR}" "${retired_lock}"; then
    [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
        == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  # A contender may create the next public generation immediately after the
  # rename. Cleanup is bound only to the retired inode from here onward.
  [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
      == "${retired_root_id}" ]] || return 1
  released_operation_lock_is_exact "${retired_lock}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" "${pid_id}" "${token_id}" \
    "${marker_id}" || return 1
  omc_lock_read_pid "${retired_lock}/pid" \
    && [[ "${OMC_TX_TEXT_SNAPSHOT}" == "${owner_pid}" ]] \
    && [[ "$(file_identity "${retired_lock}/pid" 2>/dev/null || true)" \
      == "${pid_id}" ]] \
    && rm -f -- "${retired_lock}/pid" || return 1
  omc_lock_read_token "${retired_lock}/token" \
    && [[ "${OMC_TX_TEXT_SNAPSHOT}" == "${owner_token}" ]] \
    && [[ "$(file_identity "${retired_lock}/token" 2>/dev/null || true)" \
      == "${token_id}" ]] \
    && rm -f -- "${retired_lock}/token" || return 1
  [[ "$(file_identity "${retired_lock}/owner-released" \
      2>/dev/null || true)" == "${marker_id}" ]] \
    && operation_lock_release_marker_matches \
      "${retired_lock}/owner-released" "${lock_id}" \
      "${owner_pid}" "${owner_token}" \
    && rm -f -- "${retired_lock}/owner-released" || return 1
  rmdir "${retired_lock}" || return 1
  [[ "$(file_identity "${retired_root}" 2>/dev/null || true)" \
      == "${retired_root_id}" ]] || return 1
  rmdir "${retired_root}"
}

reap_stranded_released_operation_lock() {
  local lock_id="" owner_pid="" owner_token="" source_id=""
  [[ -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && -f "${OPERATION_LOCK_DIR}/pid" \
      && ! -L "${OPERATION_LOCK_DIR}/pid" \
      && -f "${OPERATION_LOCK_DIR}/token" \
      && ! -L "${OPERATION_LOCK_DIR}/token" \
      && -f "${OPERATION_LOCK_RELEASE_MARKER}" \
      && ! -L "${OPERATION_LOCK_RELEASE_MARKER}" ]] || return 1
  lock_id="$(file_identity "${OPERATION_LOCK_DIR}")" || return 1
  omc_lock_read_pid "${OPERATION_LOCK_DIR}/pid" || return 1
  owner_pid="${OMC_TX_TEXT_SNAPSHOT}"
  omc_lock_read_token "${OPERATION_LOCK_DIR}/token" || return 1
  owner_token="${OMC_TX_TEXT_SNAPSHOT}"
  operation_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  operation_lock_release_marker_matches "${OPERATION_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  reap_released_operation_lock "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  source_id="$(file_identity "${OPERATION_LOCK_DIR}" \
    2>/dev/null || true)"
  [[ "${source_id}" != "${lock_id}" ]]
}

remove_exact_operation_lock_participant() {
  local actual_token=""
  omc_lock_read_token "${OPERATION_LOCK_PARTICIPANT_PATH}" || return 1
  actual_token="${OMC_TX_TEXT_SNAPSHOT}"
  [[ -n "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && -n "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && -f "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && ! -L "${OPERATION_LOCK_PARTICIPANT_PATH}" \
      && "$(file_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        2>/dev/null || true)" == "${OPERATION_LOCK_PARTICIPANT_ID}" \
      && "${actual_token}" == "${OPERATION_LOCK_PARTICIPANT_TOKEN}" ]] \
    || return 1
  rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}"
}

acquire_operation_lock() {
  mkdir -p "${CLAUDE_HOME}" || return 1
  local attempt=0 owner_pid="" attempt_limit=120
  local parent_pid="${OMC_PARENT_OPERATION_LOCK_PID:-}"
  local parent_token="${OMC_PARENT_OPERATION_LOCK_TOKEN:-}"
  local parent_lock_id="${OMC_PARENT_OPERATION_LOCK_ID:-}"
  local observed_pid="" observed_token=""
  if [[ -n "${parent_pid}" && -n "${parent_token}" ]]; then
    if omc_lock_read_pid "${OPERATION_LOCK_DIR}/pid"; then
      observed_pid="${OMC_TX_TEXT_SNAPSHOT}"
    fi
    if omc_lock_read_token "${OPERATION_LOCK_DIR}/token"; then
      observed_token="${OMC_TX_TEXT_SNAPSHOT}"
    fi
  fi
  if [[ -n "${parent_pid}" && -n "${parent_token}" \
      && -d "${OPERATION_LOCK_DIR}" && ! -L "${OPERATION_LOCK_DIR}" \
      && "${observed_pid}" == "${parent_pid}" \
      && "${observed_token}" == "${parent_token}" ]]; then
    OPERATION_LOCK_ID="$(file_identity "${OPERATION_LOCK_DIR}")" || return 1
    if [[ -n "${parent_lock_id}" \
        && "${OPERATION_LOCK_ID}" != "${parent_lock_id}" ]]; then
      OPERATION_LOCK_ID=""
      return 1
    fi
    if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]]; then
      reap_released_operation_lock "${OPERATION_LOCK_ID}" \
        "${parent_pid}" "${parent_token}" || true
      OPERATION_LOCK_ID=""
      return 1
    fi
    OPERATION_LOCK_PARTICIPANT_PATH="${OPERATION_LOCK_DIR}/participant.$$"
    OPERATION_LOCK_PARTICIPANT_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
    [[ ! -e "${OPERATION_LOCK_PARTICIPANT_PATH}" \
        && ! -L "${OPERATION_LOCK_PARTICIPANT_PATH}" ]] || return 1
    if ! (umask 077; set -o noclobber; \
        printf '%s\n' "${OPERATION_LOCK_PARTICIPANT_TOKEN}" \
          > "${OPERATION_LOCK_PARTICIPANT_PATH}") 2>/dev/null \
        || ! chmod 600 "${OPERATION_LOCK_PARTICIPANT_PATH}"; then
      rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}" 2>/dev/null || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    fi
    OPERATION_LOCK_PARTICIPANT_ID="$(file_identity \
      "${OPERATION_LOCK_PARTICIPANT_PATH}")" || {
      rm -f -- "${OPERATION_LOCK_PARTICIPANT_PATH}" 2>/dev/null || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      return 1
    }
    observed_pid=""
    observed_token=""
    if omc_lock_read_pid "${OPERATION_LOCK_DIR}/pid"; then
      observed_pid="${OMC_TX_TEXT_SNAPSHOT}"
    fi
    if omc_lock_read_token "${OPERATION_LOCK_DIR}/token"; then
      observed_token="${OMC_TX_TEXT_SNAPSHOT}"
    fi
    if [[ -e "${OPERATION_LOCK_RELEASE_MARKER}" \
        || -L "${OPERATION_LOCK_RELEASE_MARKER}" ]] \
        || [[ "${observed_pid}" != "${parent_pid}" ]] \
        || [[ "${observed_token}" != "${parent_token}" ]] \
        || [[ "$(file_identity "${OPERATION_LOCK_DIR}" \
          2>/dev/null || true)" != "${OPERATION_LOCK_ID}" ]] \
        || [[ "$(file_identity "${OPERATION_LOCK_PARTICIPANT_PATH}" \
          2>/dev/null || true)" != "${OPERATION_LOCK_PARTICIPANT_ID}" ]]; then
      remove_exact_operation_lock_participant || true
      reap_released_operation_lock "${OPERATION_LOCK_ID}" \
        "${parent_pid}" "${parent_token}" || true
      OPERATION_LOCK_PARTICIPANT_PATH=""
      OPERATION_LOCK_PARTICIPANT_TOKEN=""
      OPERATION_LOCK_PARTICIPANT_ID=""
      return 1
    fi
    OPERATION_LOCK_BORROWED=1
    OPERATION_LOCK_AUTH_PID="${parent_pid}"
    OPERATION_LOCK_AUTH_TOKEN="${parent_token}"
    export OMC_PARENT_OPERATION_LOCK_PID="${parent_pid}"
    export OMC_PARENT_OPERATION_LOCK_TOKEN="${parent_token}"
    export OMC_PARENT_OPERATION_LOCK_ID="${OPERATION_LOCK_ID}"
    return 0
  fi
  if [[ -n "${OMC_TEST_CONFIG_LOCK_ATTEMPTS:-}" ]]; then
    [[ "${OMC_TEST_CONFIG_LOCK_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] || return 1
    attempt_limit="${OMC_TEST_CONFIG_LOCK_ATTEMPTS}"
  fi
  while ! (umask 077; mkdir "${OPERATION_LOCK_DIR}") 2>/dev/null; do
    if reap_stranded_released_operation_lock; then
      continue
    fi
    attempt=$((attempt + 1))
    owner_pid=""
    if omc_lock_read_pid "${OPERATION_LOCK_DIR}/pid"; then
      owner_pid="${OMC_TX_TEXT_SNAPSHOT}"
    fi
    if [[ "${attempt}" -ge "${attempt_limit}" ]]; then
      printf 'omc-config: another oh-my-claude mutation is active (pid=%s, lock=%s).\n' \
        "${owner_pid:-unknown}" "${OPERATION_LOCK_DIR}" >&2
      printf 'If the owner is gone, verify every participant.* PID is also gone before removing this exact lock manually.\n' >&2
      return 1
    fi
    sleep 0.25 2>/dev/null || sleep 1
  done
  OPERATION_LOCK_ID="$(file_identity "${OPERATION_LOCK_DIR}")" || {
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  }
  if ! chmod 700 "${OPERATION_LOCK_DIR}" 2>/dev/null; then
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  OPERATION_LOCK_TOKEN="$$.${RANDOM}.${RANDOM}.$(date +%s)"
  if ! (umask 077; set -o noclobber; \
      printf '%s\n' "$$" > "${OPERATION_LOCK_DIR}/pid" \
      && printf '%s\n' "${OPERATION_LOCK_TOKEN}" \
        > "${OPERATION_LOCK_DIR}/token") 2>/dev/null; then
    rm -f -- "${OPERATION_LOCK_DIR}/pid" \
      "${OPERATION_LOCK_DIR}/token" 2>/dev/null || true
    rmdir "${OPERATION_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  OPERATION_LOCK_HELD=1
  OPERATION_LOCK_AUTH_PID="$$"
  OPERATION_LOCK_AUTH_TOKEN="${OPERATION_LOCK_TOKEN}"
  export OMC_PARENT_OPERATION_LOCK_PID="$$"
  export OMC_PARENT_OPERATION_LOCK_TOKEN="${OPERATION_LOCK_TOKEN}"
  export OMC_PARENT_OPERATION_LOCK_ID="${OPERATION_LOCK_ID}"
}

release_operation_lock() {
  if [[ "${OPERATION_LOCK_BORROWED}" -eq 1 ]]; then
    remove_exact_operation_lock_participant || true
    reap_released_operation_lock "${OPERATION_LOCK_ID}" \
      "${OPERATION_LOCK_AUTH_PID}" "${OPERATION_LOCK_AUTH_TOKEN}" || true
    OPERATION_LOCK_BORROWED=0
    OPERATION_LOCK_PARTICIPANT_PATH=""
    OPERATION_LOCK_PARTICIPANT_TOKEN=""
    OPERATION_LOCK_PARTICIPANT_ID=""
    OPERATION_LOCK_AUTH_PID=""
    OPERATION_LOCK_AUTH_TOKEN=""
    OPERATION_LOCK_ID=""
    return 0
  fi
  [[ "${OPERATION_LOCK_HELD}" -eq 1 ]] || return 0
  if operation_lock_generation_matches "${OPERATION_LOCK_ID}" "$$" \
      "${OPERATION_LOCK_TOKEN}"; then
    publish_operation_lock_release_marker \
      && reap_released_operation_lock "${OPERATION_LOCK_ID}" "$$" \
        "${OPERATION_LOCK_TOKEN}" || true
  fi
  OPERATION_LOCK_HELD=0
  OPERATION_LOCK_AUTH_PID=""
  OPERATION_LOCK_AUTH_TOKEN=""
  OPERATION_LOCK_ID=""
}

get_project_conf() {
  local physical_root=""
  physical_root="$(pwd -P)" || return 1
  printf '%s/.claude/oh-my-claude.conf' "${physical_root}"
}

# --- Static metadata about every flag this skill understands ---
#
# Format per line: name|type|default|category|description
#
# Types:
#   bool         — on|off
#   true_false   — true|false
#   int          — canonical decimal integer, 0..2147483647 unless narrower
#   pint         — canonical decimal integer, 1..2147483647 unless narrower
#   enum:a/b/c   — must be one of the listed values
#   str          — control-character-free text; named strings add stricter validation
#
# Categories drive the grouping in `show` output and the skill's
# AskUserQuestion clusters. Order is display-order (most user-facing
# first; exotic tuning knobs last).
emit_known_flags() {
  cat <<'EOF'
gate_level|enum:basic/standard/full|full|gates|Quality-gate enforcement depth
guard_exhaustion_mode|enum:silent/scorecard/block|block|gates|Behavior when gate-block cap is reached
verify_confidence_threshold|int|40|gates|Minimum verification confidence (0-100)
quality_policy|enum:balanced/zero_steering|balanced|gates|User-only adaptive quality posture for no-steering work; project conf cannot weaken it
definition_of_excellent|enum:adaptive/always/off|adaptive|gates|User-only frozen five-axis quality contract (deliberate, distinctive, coherent, visionary, complete); adaptive arms serious/ambitious work, always arms every execution objective
quality_constitution|bool|on|memory|User-only consumption of explicit project/global quality standards stored under ~/.claude/omc-user; project conf cannot disable it
taste_learning|enum:off/review/adaptive|review|memory|User-only exact-user taste learning: review records candidates for approval; adaptive may activate repeated signals as advisory only
quality_constitution_max_context_chars|pint|2400|memory|User-only cap for compiled Constitution context; raw evidence/reference content is never injected
discovered_scope|bool|on|gates|Capture advisory findings + gate stop until addressed
advisory_no_findings_gate|bool|on|gates|Block stop when N+ advisory specialists dispatched but zero findings recorded (closes fail-open of finding-gated gates)
advisory_no_findings_threshold|pint|2|gates|Positive specialist dispatch count that activates the advisory-no-findings gate
ulw_pause_validator|bool|on|gates|/ulw-pause validator: reject pause reasons that name technical-judgment categories without an operational signal
pause_external_blocker_threshold|int|3|gates|/ulw-pause case-2 (external blocker — rate limit / API down / network failure / dependency upgrade) requires N consecutive attempts on the same blocker before allowing the pause. Ported from openai/codex `continuation.md` 3-turn blocked threshold (v1.46-pre). 0 disables; case-1/3/4 (credentials/destructive/unfamiliar-state) and stakeholder/legal/user-auth signals bypass the gate.
pretool_intent_guard|true_false|true|gates|User-only: block destructive git/gh under non-execution intent; project conf cannot disable it
agent_first_gate|bool|off|gates|User-only: block first /ulw mutation until a fresh-context specialist returns (default off v1.43+; was mandatory pre-v1.43). See conf.example / docs/customization.md for the full rationale and when to turn it on.
bg_spawn_gate|true_false|true|gates|User-only: block Bash poll-loop + background detach (hygiene; v1.43.x); project conf cannot disable it
stall_threshold|pint|12|gates|Consecutive read/grep before stall fires
excellence_file_count|pint|3|gates|Breadth floor for cross-surface completeness review
dimension_gate_file_count|pint|3|gates|Breadth floor combined with semantic/cross-surface evidence
traceability_file_count|pint|6|gates|Breadth floor for cross-surface/plan traceability review
wave_override_ttl_seconds|int|7200|gates|Wave-plan freshness window for pretool guard; project conf may shorten but cannot widen the user/default authorization window
custom_verify_mcp_tools|str||gates|User-only pipe-separated MCP tool patterns that count as verification; project conf cannot broaden proof admission
custom_verify_patterns|str||gates|User-only extended regex for trusted Bash verification wrappers; project conf cannot broaden proof admission
metis_on_plan_gate|bool|off|advisory|Block stop on complex plan until metis stress-test
prometheus_suggest|bool|off|advisory|Declare-and-proceed scope interpretation on short product-shaped prompts
intent_verify_directive|bool|off|advisory|Declare-and-proceed goal interpretation on short unanchored prompts
exemplifying_directive|bool|on|advisory|Completeness/coverage directive — enumerate the search universe, verify each (v1.26.0 broadens to completeness verbs + advisory turns)
exemplifying_scope_gate|bool|on|gates|Require checklist for example-marker prompts before stop
objective_contract_gate|bool|on|gates|Re-anchor verbatim original objective + completion audit before stop on substantive turns (Codex /goal port; anti-premature-stop sibling of pause_external_blocker_threshold)
objective_contract_min_files|int|4|gates|Per-cycle unique-file edit count that marks an objective-cycle substantive (volume arm of the objective-completion gate; 0 disables the volume arm)
objective_contract_arm_on_god_scope|bool|on|gates|Arm the objective-completion gate on bare-imperative god-scope prompts ("improve it"/"harden"/"audit everything") as an INTENT signal, so ambitious-but-vague one-word imperatives drive relentlessly instead of stopping at round one (high-precision subset; recall-tuned open_mandate prose stays a nudge — use /goal for it)
auto_tune|bool|off|gates|Opt-in self-tuning: at most once per 7 days, raise objective_contract_min_files by 1 step (clamped [2,12]) when show-report.sh's own reprompt-rate signal clears its >=50% over-firing bar over >=10 blocks. Deny-listed at project-conf scope (rewrites your GLOBAL conf, not just this repo's).
goal_gate|bool|on|gates|Master switch for the /goal relentless driver — re-anchor a user-declared goal and block premature Stop until achieved (fresh audit + **Goal achieved.** attestation) or a no-progress stuck-wall; voluntary sibling of objective_contract_gate (inert until a goal is armed via /goal or auto-arm)
goal_stuck_threshold|int|3|gates|Consecutive no-progress /goal blocks before the stuck-wall surfaces and releases (0 = uncapped, never auto-release)
goal_auto_arm|bool|on|gates|Auto-arm the /goal relentless driver when a fresh /ulw execution prompt carries an explicit goal declaration ("don't stop until tests pass" / "your goal is ..." / "keep going until ...") — the v1.47 single-entrance embed; high-precision markers only, every auto-arm is announced, /goal clear stands down (preset sibling: objective_contract_arm_on_god_scope)
prompt_text_override|bool|on|gates|PreTool guard trusts prompt-text imperative when classifier disagrees
mark_deferred_strict|bool|on|gates|Reject low-information defer reasons (out of scope / follow-up) AND effort excuses (requires significant effort / blocked by complexity)
shortcut_ratio_gate|bool|on|gates|Soft-block when wave plan total≥10 AND deferred-to-decided ratio ≥0.5 (catches shortcut-on-big-tasks)
no_defer_mode|bool|on|gates|User-only v1.40.0 contract: under ULW execution, /mark-deferred refuses, findings status=deferred rejected, stop-guard hard-blocks on any deferred entry. Project conf cannot disable it.
god_scope_on_bare_prompt|bool|on|advisory|v1.44: bare-imperative prompts (single-word "fix"/"audit"/"ship") inject GOD-SCOPE-SCAN directive — identify-and-implement across the whole project, no clarification, no defer to next session.
exhaustive_auth_directive|bool|on|advisory|v1.46: prose open mandates ("implement all"/"comprehensively"/"make it better") inject an OPEN-MANDATE / INNOVATION-GENERATION directive — generate the delta to the most powerful version, not a defect audit; non-blocking, model honors explicit narrow scope.
circuit_breaker|bool|on|gates|v1.44-pre Port 1: PostToolUse:Bash hook — 3 consecutive same-target failures emit a revert+oracle directive and set a 60s quiet window. Enforces core.md:128 mechanically; ported from Citadel circuit-breaker.js.
transcript_archive|bool|off|telemetry|v1.44-pre Port 5: archive session JSONL to ~/.claude/quality-pack/state/<project_key>/<session_id>/transcript.json on Stop. Idempotent; disabled by default — disk cost ~50-500 KB/session.
installation_drift_check|true_false|true|advisory|User-only statusline yellow arrow when bundle is behind source
statusline_retention|bool|on|advisory|User-only statusline [gw:N] token — quality-gate blocks across all sessions in the last 7 days
statusline_width|bool|on|advisory|User-only statusline width fit — sheds/shrinks lowest-priority tokens until each line fits the terminal
whats_new_session_hint|true_false|true|advisory|SessionStart "you upgraded — run /whats-new" notice; project may suppress but cannot re-enable a user opt-out
self_audit_nudge|bool|on|advisory|SessionStart stale /council --self-audit nudge; project may suppress but cannot re-enable a user opt-out
lazy_session_start|bool|off|gates|Defer whats-new/drift-check/welcome SessionStart hooks to first UserPromptSubmit. Throwaway sessions skip the work AND preserve dedupe stamps for the next real session.
mid_session_memory_checkpoint|bool|on|memory|Inject MID-SESSION CHECKPOINT directive when user returns after ≥30 min idle gap. Nudges auto-memory.md sweep on the just-closed stretch before responding.
auto_memory|bool|on|memory|Cross-session auto-memory writes (project/feedback/user/reference)
repo_lessons|bool|off|memory|Team-shareable, git-committable memory — record-repo-lesson.sh prepends capped bullets to .claude/lessons.md / .claude/backlog.md at the repo root (v1.48-pre). Off by default; deny-listed at project-conf scope (data-persistence-into-repo security restriction) — user-level conf or env only.
prompt_persist|bool|on|memory|In-session prompt persistence (recent_prompts.jsonl + last_user_prompt). Off skips writes and degrades prompt-text-override gracefully.
classifier_telemetry|bool|on|telemetry|Per-turn classifier telemetry to session state
model_tier|enum:quality/balanced/economy|balanced|cost|User-only quality-first model posture: quality=inherit deliberators + Opus specialists; balanced=default split with high-risk escalation; economy=Sonnet-first with adaptive reasoning-risk escalation. Council lenses escalate only with deep. Inherit means omit model and ride the current session. Project conf cannot set this flag.
model_overrides|str||cost|User-only highest-precedence per-agent pin. Format agent:model,agent:model with opus/sonnet/haiku/inherit (e.g. oracle:inherit,librarian:haiku). Shipped bare inherit pins are materialized before live omission; custom inherit must already be definition-backed, and custom/plugin named-model pins stay runtime-only. Namespaced inherit is rejected. Env OMC_MODEL_OVERRIDES wins for enforceable pins; project conf cannot set this flag.
council_deep_default|bool|off|cost|User-only auto-Council deep routing: selected Sonnet-backed specialists escalate to Opus; project conf cannot change model strength/spend
stop_failure_capture|bool|on|watchdog|Capture resume_request.json on rate-limit / fatal stop
resume_request_ttl_days|pint|7|watchdog|User-only days a resume_request stays claimable; shared with the machine-wide watchdog
resume_watchdog|bool|off|watchdog|User-only machine-wide daemon switch: launch claude --resume after cap clears
resume_watchdog_cooldown_secs|pint|600|watchdog|User-only per-artifact cooldown between machine-wide watchdog launches
resume_session_ttl_secs|pint|7200|watchdog|User-only max lifetime for headless omc-resume tmux sessions before reaper kills them
resume_scan_max_sessions|pint|30|watchdog|User-only max session dirs find_claimable_resume_requests walks; shared with the machine-wide watchdog
claude_bin|str||watchdog|User-only pinned absolute path to claude binary (PATH-hijack defense; auto-set by install-resume-watchdog.sh)
resume_request_per_cwd_cap|int|3|watchdog|Max resume_request artifacts per cwd before stop-failure-handler prunes oldest (0 disables)
time_tracking|bool|on|telemetry|Per-tool / per-subagent timing capture; backs Stop epilogue + /ulw-time
time_tracking_xs_retain_days|pint|30|telemetry|User-only cross-session timing log retention (days); controls destructive pruning across all projects
time_card_min_seconds|int|5|telemetry|Min walltime to render the Stop epilogue time card (seconds; 0 = always)
token_tracking|bool|on|telemetry|Incremental token capture from parent + nested sidechain transcripts with main/sub-agent and role/model/native-dispatch attribution; backs /ulw-time + /ulw-status + /ulw-report
state_ttl_days|pint|7|cleanup|User-only days before stale session-state dirs across all projects are swept
output_style|enum:opencode/executive/preserve|opencode|cost|User-only bundled output style: opencode = oh-my-claude (compact CLI), executive = executive-brief (CEO-style status report), preserve = leave settings.json untouched
model_drift_canary|bool|on|telemetry|Stop-hook canary detects silent confabulation (claims-vs-tool-calls audit; surfaces in /ulw-report)
blindspot_inventory|bool|on|gates|Project-surface scanner backing the intent-broadening directive (lazy-cached, 24h TTL)
intent_broadening|bool|on|advisory|Inject project-context reconciliation directive on complex execution prompts (defends against language-as-limitation failure)
divergence_directive|bool|on|advisory|Inject divergent-framing directive on paradigm-shape decisions (X-vs-Y, "best way", "how should we", "design the X strategy") — enumerate 2-3 framings inline before commit
workflow_substrate|bool|on|cost|User-only permission for Claude Code's background Workflow tool as an opt-in HEAVY fan-out substrate; project conf cannot arm/suppress this cost and execution posture
inferred_contract|bool|on|gates|Delivery Contract v2: infer required adjacent surfaces (tests/changelog/parser-lockstep/migration-notes) from actual edits, block stop when silently missed
directive_budget|enum:off/maximum/balanced/minimal|balanced|advisory|How much injected pre-answer scaffolding you see per prompt: whole-payload + optional caps trim lower-priority repetition while mandatory quality contracts remain fail-safe. minimal = leanest optional layer, maximum = widest bounded aperture, off = very high aperture with runaway ceiling, balanced = default
blindspot_ttl_seconds|pint|86400|gates|Cache TTL (seconds) for blindspot inventory; default 86400 = 24h
EOF
}

# --- Preset definitions ---
#
# `maximum`: quality + max automation (this project's intended posture).
#   Internally consistent with `model_tier=quality` — every quality lever
#   is pulled, including `council_deep_default=on` so auto-triggered
#   Council dispatches use deep routing: selected Sonnet-backed agents
#   escalate to Opus while inherit deliberators stay on the session model.
# `zero-steering`: explicit alias for maximum. It exists so a user can
#   name the outcome they want ("ship without steering") instead of
#   reverse-engineering which quality levers that implies.
# `balanced`: close to install-time defaults; safe for most users. Cost
#   caps live here, not in `maximum` — `council_deep_default=off` leaves
#   each auto-Council specialist on its normal tier for the typical user.
# `minimal`: lightest footprint while keeping core gates working.
#
# stop_failure_capture stays on across all presets — it is privacy-aware,
# tiny, and the only thing that makes /ulw-resume work after a Claude
# Code rate-limit kill. Users who actually need it off should set it
# explicitly, not adopt a preset.
#
# v1.40.0 LOAD-BEARING (do NOT optimize away): `no_defer_mode=on` MUST
# ship in `maximum`/`zero-steering` AND `balanced` presets. This is the
# recommended-preset half of the no-defer contract documented in
# `~/.claude/quality-pack/memory/core.md` ("The v1.40.0 no-defer
# contract"). A recommended preset that shipped `no_defer_mode=off`
# would teach new installs that defer is normal behavior, defeating the
# contract before it ever fires. The `minimal` preset legitimately ships
# `no_defer_mode=off` because that preset's stance is "lightest footprint
# while keeping core gates working" — power-user opt-out by design.
# Flipping any of the three values triggers tests/test-no-defer-contract.sh.
emit_preset() {
  local profile="$1"
  case "${profile}" in
    maximum|zero-steering|zero_steering)
      cat <<'EOF'
gate_level=full
guard_exhaustion_mode=block
quality_policy=zero_steering
definition_of_excellent=always
quality_constitution=on
taste_learning=adaptive
quality_constitution_max_context_chars=4000
auto_memory=on
prompt_persist=on
classifier_telemetry=on
discovered_scope=on
council_deep_default=on
prometheus_suggest=on
intent_verify_directive=on
exemplifying_directive=on
exemplifying_scope_gate=on
objective_contract_gate=on
objective_contract_arm_on_god_scope=on
goal_gate=on
goal_auto_arm=on
prompt_text_override=on
mark_deferred_strict=on
shortcut_ratio_gate=on
no_defer_mode=on
god_scope_on_bare_prompt=on
exhaustive_auth_directive=on
circuit_breaker=on
transcript_archive=off
metis_on_plan_gate=on
stop_failure_capture=on
resume_watchdog=on
time_tracking=on
token_tracking=on
model_drift_canary=on
blindspot_inventory=on
intent_broadening=on
divergence_directive=on
workflow_substrate=on
inferred_contract=on
directive_budget=maximum
model_tier=quality
EOF
      ;;
    balanced)
      cat <<'EOF'
gate_level=full
guard_exhaustion_mode=scorecard
quality_policy=balanced
definition_of_excellent=adaptive
quality_constitution=on
taste_learning=review
quality_constitution_max_context_chars=2400
auto_memory=on
prompt_persist=on
classifier_telemetry=on
discovered_scope=on
council_deep_default=off
prometheus_suggest=off
intent_verify_directive=off
exemplifying_directive=on
exemplifying_scope_gate=on
objective_contract_gate=on
objective_contract_arm_on_god_scope=on
goal_gate=on
goal_auto_arm=on
prompt_text_override=on
mark_deferred_strict=on
shortcut_ratio_gate=on
no_defer_mode=on
god_scope_on_bare_prompt=on
exhaustive_auth_directive=on
circuit_breaker=on
transcript_archive=off
metis_on_plan_gate=off
stop_failure_capture=on
resume_watchdog=off
time_tracking=on
token_tracking=on
model_drift_canary=on
blindspot_inventory=on
intent_broadening=on
divergence_directive=on
workflow_substrate=on
inferred_contract=on
directive_budget=balanced
model_tier=balanced
EOF
      ;;
    minimal)
      cat <<'EOF'
gate_level=basic
guard_exhaustion_mode=silent
quality_policy=balanced
definition_of_excellent=off
quality_constitution=off
taste_learning=off
quality_constitution_max_context_chars=1200
auto_memory=off
prompt_persist=off
classifier_telemetry=off
discovered_scope=off
council_deep_default=off
prometheus_suggest=off
intent_verify_directive=off
exemplifying_directive=off
exemplifying_scope_gate=off
objective_contract_gate=off
objective_contract_arm_on_god_scope=off
goal_gate=on
goal_auto_arm=off
prompt_text_override=on
mark_deferred_strict=off
shortcut_ratio_gate=off
no_defer_mode=off
god_scope_on_bare_prompt=off
exhaustive_auth_directive=off
circuit_breaker=off
transcript_archive=off
metis_on_plan_gate=off
stop_failure_capture=on
resume_watchdog=off
time_tracking=off
token_tracking=off
model_drift_canary=off
blindspot_inventory=off
intent_broadening=off
divergence_directive=off
workflow_substrate=off
inferred_contract=off
directive_budget=minimal
model_tier=economy
EOF
      ;;
    *)
      printf 'omc-config: unknown preset: %s (expected maximum|zero-steering|balanced|minimal)\n' "${profile}" >&2
      return 2
      ;;
  esac
}

# Read a single key from a conf file, tolerating absence.
# Last-occurrence wins (matches install.sh `set_conf` semantics).
read_conf_value() {
  local conf="$1" key="$2" line="" result=""
  [[ -f "${conf}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    result="$(trim_conf_value "${line#*=}")"
  done < "${conf}"
  printf '%s' "${result}"
}

trim_conf_value() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

# Bound and shell-escape attacker-controlled invalid values before rendering
# them in terminal diagnostics. Effective canonical values remain human-readable;
# this applies only to rejected previews.
diagnostic_preview() {
  local raw="${1-}" bounded="" suffix="" escaped=""
  bounded="${raw:0:120}"
  [[ "${#raw}" -le 120 ]] || suffix="…"
  printf -v escaped '%q' "${bounded}"
  printf '%s%s' "${escaped}" "${suffix}"
}

canonical_uint_in_range() {
  local value="${1:-}" minimum="${2:-}" maximum="${3:-}"
  local value_len minimum_len maximum_len
  local LC_ALL=C
  # Shell globs do not give `*` regex semantics. Check the whole value for
  # non-digits, then enforce canonical zero/no-leading-zero spelling.
  case "${value}" in
    ''|*[!0-9]*|0?*) return 1 ;;
    0|[1-9]*) ;;
    *) return 1 ;;
  esac
  value_len="${#value}"
  minimum_len="${#minimum}"
  maximum_len="${#maximum}"
  (( value_len < minimum_len || value_len > maximum_len )) && return 1
  if (( value_len == minimum_len )) && [[ "${value}" < "${minimum}" ]]; then
    return 1
  fi
  if (( value_len == maximum_len )) && [[ "${value}" > "${maximum}" ]]; then
    return 1
  fi
  return 0
}

canonical_uint_lte() {
  local left="${1:-}" right="${2:-}" left_len right_len
  local LC_ALL=C
  canonical_uint_in_range "${left}" 0 2147483647 || return 1
  canonical_uint_in_range "${right}" 0 2147483647 || return 1
  left_len="${#left}"
  right_len="${#right}"
  (( left_len < right_len )) && return 0
  (( left_len > right_len )) && return 1
  [[ "${left}" < "${right}" || "${left}" == "${right}" ]]
}

normalize_compat_toggle() {
  local value="${1:-}" enabled="${2:-on}" disabled="${3:-off}"
  case "${value}" in
    [Tt][Rr][Uu][Ee]|[Oo][Nn]|1|[Yy][Ee][Ss]) printf '%s' "${enabled}" ;;
    [Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0|[Nn][Oo]) printf '%s' "${disabled}" ;;
    *) return 1 ;;
  esac
}

ere_is_valid() {
  local pattern="${1-}" rc=0
  local PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:/run/current-system/sw/bin"
  LC_ALL=C grep -Eq -- "${pattern}" </dev/null 2>/dev/null || rc=$?
  [[ "${rc}" -ne 2 ]]
}

# Convert a single already-trimmed value to the exact spelling consumed by its
# owning runtime. Invalid rows fail so a prior valid duplicate or lower source
# remains authoritative.
normalize_config_value() {
  local key="${1:-}" value="${2-}" normalized=""
  case "${key}" in
    installation_drift_check)
      normalize_compat_toggle "${value}" true false
      ;;
    statusline_retention|statusline_width)
      normalize_compat_toggle "${value}" on off
      ;;
    agent_first_gate)
      case "${value}" in
        [Oo][Nn]) printf 'on' ;;
        [Oo][Ff][Ff]) printf 'off' ;;
        *) return 1 ;;
      esac
      ;;
    guard_exhaustion_mode)
      case "${value}" in
        silent|release) printf 'silent' ;;
        scorecard|warn) printf 'scorecard' ;;
        block|strict) printf 'block' ;;
        *) return 1 ;;
      esac
      ;;
    model_overrides)
      [[ -n "${value}" ]] || return 0
      normalized="$(valid_model_overrides_summary "${value}")"
      [[ -n "${normalized}" ]] || return 1
      printf '%s' "${normalized}"
      ;;
    custom_verify_mcp_tools)
      [[ -n "${value}" ]] || return 0
      validate_kv "${key}=${value}" >/dev/null 2>&1 || return 1
      printf '%s' "${value}"
      ;;
    custom_verify_patterns)
      [[ -n "${value}" ]] || return 0
      validate_kv "${key}=${value}" >/dev/null 2>&1 || return 1
      printf '%s' "${value}"
      ;;
    claude_bin)
      # An explicit empty write is still the supported clear operation because
      # write_conf_atomic removes the former row. While reading hand-edited
      # duplicates, however, empty is not a runtime value and must not erase an
      # earlier valid executable (matching common.sh's parser).
      [[ -n "${value}" ]] || return 1
      validate_kv "${key}=${value}" >/dev/null 2>&1 || return 1
      printf '%s' "${value}"
      ;;
    *)
      validate_kv "${key}=${value}" >/dev/null 2>&1 || return 1
      printf '%s' "${value}"
      ;;
  esac
}

read_last_runtime_valid_conf_value() {
  local conf="$1" key="$2" line raw normalized result=""
  [[ -f "${conf}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    raw="$(trim_conf_value "${line#*=}")"
    if normalized="$(normalize_config_value "${key}" "${raw}")"; then
      result="${normalized}"
    fi
  done < "${conf}"
  printf '%s' "${result}"
}

# Find the nearest project-scope conf by walking up from PWD, capped at
# 10 levels — same logic as `load_conf` in common.sh. Skips $HOME so the
# user conf is not double-counted as project. Prints the path and exits 0
# if found; exits 1 if no project conf exists in the walked chain.
find_project_conf() {
  local dir="${PWD}" depth=0
  while [[ "${dir}" != "/" && "${depth}" -lt 10 ]]; do
    if [[ "${dir}" != "${HOME}" && -f "${dir}/.claude/oh-my-claude.conf" ]]; then
      printf '%s' "${dir}/.claude/oh-my-claude.conf"
      return 0
    fi
    dir="$(dirname "${dir}")"
    depth=$((depth + 1))
  done
  return 1
}

# Project-conf restrictions are one contract across the runtime and config UX.
# The first group mirrors common.sh's protected deny-list; the three statusline
# controls are also user-only because their Python/grep consumers never read a
# project overlay. Reuse this registry for reads, writes, source markers,
# warnings, and preset filtering so /omc-config cannot advertise dead rows.
PROJECT_DENIED_FLAGS=(
  pretool_intent_guard
  bg_spawn_gate
  agent_first_gate
  no_defer_mode
  quality_policy
  definition_of_excellent
  quality_constitution
  taste_learning
  quality_constitution_max_context_chars
  model_tier
  model_overrides
  council_deep_default
  workflow_substrate
  repo_lessons
  auto_tune
  output_style
  resume_watchdog
  resume_watchdog_cooldown_secs
  resume_session_ttl_secs
  resume_request_ttl_days
  resume_scan_max_sessions
  claude_bin
  state_ttl_days
  time_tracking_xs_retain_days
  installation_drift_check
  statusline_retention
  statusline_width
  custom_verify_mcp_tools
  custom_verify_patterns
)

flag_is_project_denied() {
  local requested="${1:-}" denied_flag
  for denied_flag in "${PROJECT_DENIED_FLAGS[@]}"; do
    [[ "${requested}" == "${denied_flag}" ]] && return 0
  done
  return 1
}

flag_is_monotonic_project_capture() {
  case "${1:-}" in
    classifier_telemetry|auto_memory|prompt_persist|stop_failure_capture|\
    transcript_archive|time_tracking|token_tracking|model_drift_canary|\
    blindspot_inventory) return 0 ;;
    *) return 1 ;;
  esac
}

project_capture_default() {
  case "${1:-}" in
    transcript_archive) printf 'off' ;;
    classifier_telemetry|auto_memory|prompt_persist|stop_failure_capture|\
    time_tracking|token_tracking|model_drift_canary|blindspot_inventory)
      printf 'on'
      ;;
    *) return 1 ;;
  esac
}

flag_is_monotonic_project_ceiling() {
  case "${1:-}" in
    wave_override_ttl_seconds) return 0 ;;
    *) return 1 ;;
  esac
}

project_ceiling_default() {
  case "${1:-}" in
    wave_override_ttl_seconds) printf '7200' ;;
    *) return 1 ;;
  esac
}

flag_is_monotonic_project_notice() {
  case "${1:-}" in
    self_audit_nudge|whats_new_session_hint) return 0 ;;
    *) return 1 ;;
  esac
}

project_notice_default() {
  case "${1:-}" in
    self_audit_nudge) printf 'on' ;;
    whats_new_session_hint) printf 'true' ;;
    *) return 1 ;;
  esac
}

# Mirror common.sh's monotonic project overlay. Project config may reduce
# sensitive persistence, never promote it over the user/default baseline.
# resume_request_per_cwd_cap uses 0 as unlimited; positive project values may
# only retain the same or fewer prompt-bearing resume artifacts. Authorization
# ceilings may likewise be shortened, never widened.
project_value_is_allowed() {
  local key="${1:-}" value="${2:-}" baseline=""
  if flag_is_monotonic_project_capture "${key}"; then
    [[ "${value}" == "on" ]] || return 0
    baseline="$(read_last_runtime_valid_conf_value "${USER_CONF}" "${key}")"
    [[ -n "${baseline}" ]] || baseline="$(project_capture_default "${key}")"
    [[ "${baseline}" != "off" ]]
    return
  fi
  if [[ "${key}" == "resume_request_per_cwd_cap" ]]; then
    baseline="$(read_last_runtime_valid_conf_value "${USER_CONF}" "${key}")"
    [[ -n "${baseline}" ]] || baseline=3
    if [[ "${value}" == "0" ]]; then
      [[ "${baseline}" == "0" ]]
    elif [[ "${baseline}" == "0" ]]; then
      return 0
    else
      canonical_uint_lte "${value}" "${baseline}"
    fi
    return
  fi
  if flag_is_monotonic_project_ceiling "${key}"; then
    baseline="$(read_last_runtime_valid_conf_value "${USER_CONF}" "${key}")"
    [[ -n "${baseline}" ]] || baseline="$(project_ceiling_default "${key}")"
    canonical_uint_lte "${value}" "${baseline}"
    return
  fi
  if flag_is_monotonic_project_notice "${key}"; then
    case "${value}" in off|false) return 0 ;; esac
    baseline="$(read_last_runtime_valid_conf_value "${USER_CONF}" "${key}")"
    [[ -n "${baseline}" ]] || baseline="$(project_notice_default "${key}")"
    case "${baseline}" in off|false) return 1 ;; *) return 0 ;; esac
  fi
  return 0
}

# Project policy is applied per row, just like common.sh. If a later valid row
# is an unsafe promotion, it is ignored without erasing an earlier allowed
# project reduction (for example resume cap `2` followed by rejected `4`).
read_last_project_allowed_conf_value() {
  local conf="${1:-}" key="${2:-}" line="" raw="" normalized="" result=""
  [[ -f "${conf}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    raw="${line#*=}"
    raw="$(trim_conf_value "${raw}")"
    normalized="$(normalize_config_value "${key}" "${raw}" \
      2>/dev/null || true)"
    [[ -n "${normalized}" ]] || continue
    project_value_is_allowed "${key}" "${normalized}" || continue
    result="${normalized}"
  done < "${conf}"
  printf '%s' "${result}"
}

flag_is_model_user_only() {
  case "${1:-}" in
    model_tier|model_overrides) return 0 ;;
    *) return 1 ;;
  esac
}

# Keep the write-time `inherit` authority boundary independent of custom file
# names. Shipped definitions can be reconstructed by switch-tier.sh; custom
# definitions are user-owned and must never be rewritten as a side effect of
# saving a pin. Keep these rosters lockstep with the bundle, install.sh, and
# switch-tier.sh; tests/test-omc-config.sh regression-locks their union.
OMC_CONFIG_SHIPPED_INHERIT_AGENTS='abstraction-critic chief-of-staff divergent-framer draft-writer editor-critic excellence-reviewer metis oracle prometheus quality-planner quality-reviewer release-reviewer rigor-reviewer writing-architect'
OMC_CONFIG_SHIPPED_FIXED_AGENTS='atlas backend-api-developer briefing-analyst data-lens design-lens design-reviewer devops-infrastructure-engineer frontend-developer fullstack-feature-builder growth-lens ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer librarian literature-scout product-lens quality-researcher research-data-analyst security-lens sre-lens test-automation-engineer visual-craft-lens'

model_agent_is_shipped() {
  local wanted="${1:-}" agent
  for agent in ${OMC_CONFIG_SHIPPED_INHERIT_AGENTS} \
      ${OMC_CONFIG_SHIPPED_FIXED_AGENTS}; do
    [[ "${wanted}" == "${agent}" ]] && return 0
  done
  return 1
}

# `inherit` is represented by Agent-model omission, so it can only be a live
# override when the bare installed definition already declares inherit. The
# official set path materializes shipped bare pins immediately. Custom and
# plugin definitions are never rewritten; custom inherit is valid only when
# the custom file already declares it exactly once, while namespaced plugin
# inherit cannot be proven or materialized.
inherit_override_is_materialized() {
  local name="${1:-}" agent_file line model_count=0 model_value=""
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  agent_file="${HOME}/.claude/agents/${name}.md"
  [[ -f "${agent_file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      model:*)
        model_count=$((model_count + 1))
        model_value="${line#model: }"
        ;;
    esac
  done < "${agent_file}"
  [[ "${model_count}" -eq 1 && "${model_value}" == "inherit" ]]
}

inherit_override_is_materializable() {
  local name="${1:-}" agent_file model_count model_value
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  agent_file="${HOME}/.claude/agents/${name}.md"
  [[ -f "${agent_file}" ]] || return 1
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  [[ "${model_count}" == "1" \
      && "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]
}

# Keep this parser in lockstep with common.sh's
# `omc_valid_model_overrides_summary`: `show` must not present a malformed or
# unenforceable environment entry as an active pin when the live resolver will
# ignore it. Namespaced plugin identities contain one additional colon, so
# split on the final colon rather than the first.
valid_model_overrides_summary() {
  local raw="${1:-}" pair name model summary=""
  local -a pairs=()
  [[ -z "${raw}" ]] && return 0
  IFS=',' read -ra pairs <<< "${raw}"
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ "${pair}" == *:* ]] || continue
    name="${pair%:*}"
    model="${pair##*:}"
    [[ "${name}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] || continue
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *) continue ;;
    esac
    if [[ "${model}" == "inherit" ]] \
        && ! inherit_override_is_materialized "${name}"; then
      continue
    fi
    summary="${summary}${summary:+,}${name}:${model}"
  done
  printf '%s' "${summary}"
}

model_overrides_have_invalid_entries() {
  local raw="${1:-}" normalized pair name model
  local -a pairs=()
  [[ -z "${raw}" ]] && return 1
  normalized="${raw//[[:space:]]/}"
  [[ -n "${normalized}" ]] || return 0
  case "${normalized}" in
    ,*|*,|*,,*) return 0 ;;
  esac
  IFS=',' read -ra pairs <<< "${normalized}"
  for pair in "${pairs[@]}"; do
    [[ -n "${pair}" ]] || return 0
    if [[ "${pair}" != *:* ]]; then
      return 0
    fi
    name="${pair%:*}"
    model="${pair##*:}"
    if [[ ! "${name}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]]; then
      return 0
    fi
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *) return 0 ;;
    esac
    if [[ "${model}" == "inherit" ]] \
        && ! inherit_override_is_materialized "${name}"; then
      return 0
    fi
  done
  return 1
}

# Strict write-time validator. Runtime and `show` intentionally fail soft for
# hand-edited legacy config, but `/omc-config set` must not persist a value the
# resolver will partly or wholly discard. Empty is the supported clear action.
# Shipped bare inherit is accepted because the write path can materialize it.
# Custom bare inherit is accepted only when the user-owned definition already
# declares inherit exactly once. Namespaced inherit is rejected because
# Agent-model omission cannot rewrite or prove a plugin definition. Explicit
# named-model custom/plugin pins remain valid runtime-only pins.
model_overrides_value_is_valid() {
  local raw="${1-}" normalized pair name model
  local -a pairs=()
  [[ -z "${raw}" ]] && return 0
  normalized="${raw//[[:space:]]/}"
  [[ -n "${normalized}" ]] || return 1
  case "${normalized}" in
    ,*|*,|*,,*) return 1 ;;
  esac
  IFS=',' read -ra pairs <<< "${normalized}"
  [[ "${#pairs[@]}" -gt 0 ]] || return 1
  for pair in "${pairs[@]}"; do
    [[ "${pair}" == *:* ]] || return 1
    name="${pair%:*}"
    model="${pair##*:}"
    [[ "${name}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] \
      || return 1
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *) return 1 ;;
    esac
    if [[ "${model}" == "inherit" ]]; then
      [[ "${name}" != *:* ]] || return 1
      if model_agent_is_shipped "${name}"; then
        inherit_override_is_materializable "${name}" || return 1
      else
        inherit_override_is_materialized "${name}" || return 1
      fi
    fi
  done
  return 0
}

# User-conf values as the runtime actually consumes them. This is deliberately
# fail-soft: manually edited malformed rows remain on disk for diagnosis, but
# never appear as active values in `show`/`list-flags`.
read_effective_user_conf_value() {
  read_last_runtime_valid_conf_value "${USER_CONF}" "$1"
}

# The common runtime gives valid environment values precedence over both conf
# scopes. `/omc-config show` reproduces that for the user-facing model controls.
# A malformed tier is ignored so it cannot silently demote a saved Quality
# posture; user conf wins, or Balanced remains the no-valid-source default.
model_env_override_value() {
  case "${1:-}" in
    model_tier)
      [[ -n "${OMC_MODEL_TIER:-}" ]] || return 1
      case "${OMC_MODEL_TIER}" in
        quality|balanced|economy) printf '%s' "${OMC_MODEL_TIER}" ;;
        *) return 1 ;;
      esac
      ;;
    model_overrides)
      [[ -n "${OMC_MODEL_OVERRIDES:-}" ]] || return 1
      local valid_overrides
      valid_overrides="$(valid_model_overrides_summary \
        "${OMC_MODEL_OVERRIDES}")"
      [[ -n "${valid_overrides}" ]] || return 1
      printf '%s' "${valid_overrides}"
      ;;
    *) return 1 ;;
  esac
}

# Compare the Constitution context cap without feeding unbounded user text to
# Bash arithmetic. Bash integers are machine-width and accept octal-looking
# input, so a huge decimal can wrap and a leading-zero value can be
# misinterpreted. The only arithmetic here is over the bounded string length;
# fixed-width digit patterns define the two boundary intervals.
quality_constitution_context_cap_is_valid() {
  canonical_uint_in_range "${1:-}" 512 12000
}

quality_constitution_context_cap_exceeds_max() {
  local value="${1:-}" length
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
  length="${#value}"
  (( length > 5 )) && return 0
  (( length < 5 )) && return 1
  case "${value}" in
    1[01][0-9][0-9][0-9]|12000) return 1 ;;
    *) return 0 ;;
  esac
}

quality_constitution_context_cap_below_min() {
  local value="${1:-}" length
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
  length="${#value}"
  (( length < 3 )) && return 0
  (( length > 3 )) && return 1
  case "${value}" in
    [1-4][0-9][0-9]|50[0-9]|51[01]) return 0 ;;
    *) return 1 ;;
  esac
}

config_env_name_for_key() {
  local key="${1:-}" upper=""
  [[ "${key}" =~ ^[a-z][a-z0-9_]*$ ]] || return 1
  upper="$(printf '%s' "${key}" | LC_ALL=C tr '[:lower:]' '[:upper:]')" \
    || return 1
  [[ -n "${upper}" ]] || return 1
  printf 'OMC_%s' "${upper}"
}

# Resolve every documented environment authority, not only the model and
# Definition controls. Names are mechanically OMC_<UPPERCASE_FLAG>; values
# pass the same public validator as saved config before they can appear as an
# effective source. Two runtime compatibility spellings are canonicalized to
# match common.sh: case-insensitive agent_first_gate and legacy exhaustion
# vocabulary. Model overrides retain their per-pin fail-soft semantics.
runtime_env_override_value() {
  local key="${1:-}" value="" env_name="" normalized=""
  case "${key}" in
    model_tier|model_overrides)
      model_env_override_value "${key}"
      return
      ;;
  esac

  env_name="$(config_env_name_for_key "${key}")" || return 1
  value="${!env_name-}"
  [[ -n "${value}" ]] || return 1
  case "${key}" in
    installation_drift_check|statusline_retention|statusline_width)
      # statusline.py preserves its historical strip()+casefold grammar for
      # environment toggles; mirror it so `show` reports the live value.
      value="$(trim_conf_value "${value}")"
      ;;
  esac
  normalized="$(normalize_config_value "${key}" "${value}")" || return 1
  printf '%s' "${normalized}"
}

warn_model_env_shadow() {
  local env_tier="" env_overrides=""
  env_tier="$(model_env_override_value model_tier 2>/dev/null || true)"
  env_overrides="$(model_env_override_value model_overrides 2>/dev/null || true)"
  if [[ -n "${env_tier}" || -n "${env_overrides}" ]]; then
    printf 'omc-config: WARNING: active OMC_MODEL_TIER/OMC_MODEL_OVERRIDES still govern this process at runtime. Saved config was materialized for persistent/direct-skill use; remove the environment override and start a new session to use the saved posture.\n' >&2
  fi
}

# Persistent writes cannot alter the environment of this process. Warn for
# every touched non-model control whose valid environment authority differs
# from the value just saved at that scope. Model controls retain their richer
# materialization warning below; equal env/saved values need no warning.
warn_config_env_shadows_for_touched() {
  local scope="$1"
  shift
  local conf="" key kv touched saved env_value env_name
  conf="$(resolve_scope_conf "${scope}")" || return 0
  while IFS='|' read -r key _type _default _category _desc; do
    case "${key}" in ""|model_tier|model_overrides) continue ;; esac
    touched=0
    for kv in "$@"; do
      if [[ "${kv%%=*}" == "${key}" ]]; then
        touched=1
        break
      fi
    done
    (( touched == 1 )) || continue
    env_value="$(runtime_env_override_value "${key}" 2>/dev/null || true)"
    [[ -n "${env_value}" ]] || continue
    saved="$(read_last_runtime_valid_conf_value "${conf}" "${key}")"
    [[ "${env_value}" != "${saved}" ]] || continue
    env_name="$(config_env_name_for_key "${key}")"
    printf 'omc-config: WARNING: active %s=%s overrides saved %s %s=%s for this process; remove the environment override and start a new session to use the saved value.\n' \
      "${env_name}" "${env_value}" "${scope}" "${key}" "${saved}" >&2
  done < <(emit_known_flags)
}

# Read a value with environment > allowed-project > user precedence, matching
# `load_conf` in common.sh. Denied project rows are deliberately invisible:
# the table reflects what the harness actually sees, not merely what a file
# contains.
read_effective_value() {
  local key="$1"
  local proj_conf proj_val user_val env_val
  if env_val="$(runtime_env_override_value "${key}")"; then
    printf '%s' "${env_val}"
    return 0
  fi
  if ! flag_is_project_denied "${key}" && proj_conf="$(find_project_conf)"; then
    proj_val="$(read_last_project_allowed_conf_value \
      "${proj_conf}" "${key}")"
    if [[ -n "${proj_val}" ]]; then
      printf '%s' "${proj_val}"
      return 0
    fi
  fi
  user_val="$(read_effective_user_conf_value "${key}")"
  printf '%s' "${user_val}"
}

# Resolve the bundle's VERSION via the conf's repo_path. Only accepts the
# semver shape `MAJOR.MINOR.PATCH` (with optional `-prerelease`); anything
# else returns `unknown` so detect-mode never compares garbage against
# `installed_version` and lands in the wrong branch on a malformed file.
resolve_bundle_version() {
  local repo_path raw
  repo_path="$(read_conf_value "${USER_CONF}" repo_path)"
  if [[ -n "${repo_path}" && -f "${repo_path}/VERSION" ]]; then
    raw="$(tr -d '[:space:]' < "${repo_path}/VERSION")"
    if [[ "${raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
      printf '%s' "${raw}"
      return 0
    fi
  fi
  printf 'unknown'
}

# Validate one key=value pair against the KNOWN_FLAGS table.
# Exits the script on failure (preserves atomic-write semantics —
# no partial conf writes when an apply-preset has one bad value).
validate_kv() {
  local kv="$1"
  local LC_ALL=C
  if [[ "${kv}" != *"="* ]]; then
    printf 'omc-config: malformed pair (no =): %s\n' \
      "$(diagnostic_preview "${kv}")" >&2
    return 2
  fi
  local key="${kv%%=*}"
  local value="${kv#*=}"
  local key_preview="" value_preview=""
  key_preview="$(diagnostic_preview "${key}")"
  value_preview="$(diagnostic_preview "${value}")"

  local flag_type=""
  local found=false
  local name typ
  while IFS='|' read -r name typ _default _category _desc; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == "${key}" ]]; then
      flag_type="${typ}"
      found=true
      break
    fi
  done < <(emit_known_flags)

  if [[ "${found}" != "true" ]]; then
    printf 'omc-config: unknown flag: %s\n' "${key_preview}" >&2
    return 2
  fi

  case "${flag_type}" in
    bool)
      if [[ ! "${value}" =~ ^(on|off)$ ]]; then
        printf 'omc-config: %s must be on|off (got: %s)\n' \
          "${key_preview}" "${value_preview}" >&2
        return 2
      fi
      ;;
    true_false)
      if [[ ! "${value}" =~ ^(true|false)$ ]]; then
        printf 'omc-config: %s must be true|false (got: %s)\n' \
          "${key_preview}" "${value_preview}" >&2
        return 2
      fi
      ;;
    int)
      if ! canonical_uint_in_range "${value}" 0 2147483647; then
        printf 'omc-config: %s must be a non-negative integer in canonical decimal form, no greater than 2147483647 (got: %s)\n' \
          "${key_preview}" "${value_preview}" >&2
        return 2
      fi
      if [[ "${key}" == "verify_confidence_threshold" ]] \
          && ! canonical_uint_in_range "${value}" 0 100; then
        printf 'omc-config: %s must be from 0 to 100 (got: %s)\n' \
          "${key_preview}" "${value_preview}" >&2
        return 2
      fi
      ;;
    pint)
      # Positive integer (>= 1). Use this for retention windows / TTLs
      # where 0 would silently be rejected by common.sh's parser regex
      # (^[1-9][0-9]*$) and the user would get the default instead — a
      # silent-fallback footgun the strict validator prevents.
      if ! canonical_uint_in_range "${value}" 1 2147483647; then
        printf 'omc-config: %s must be a positive integer in canonical decimal form, no greater than 2147483647 (got: %s)\n' \
          "${key_preview}" "${value_preview}" >&2
        return 2
      fi
      if [[ "${key}" == "quality_constitution_max_context_chars" ]] \
          && ! quality_constitution_context_cap_is_valid "${value}"; then
        if quality_constitution_context_cap_exceeds_max "${value}"; then
          printf 'omc-config: %s must be at most 12000 (got: %s)\n' \
            "${key_preview}" "${value_preview}" >&2
        elif quality_constitution_context_cap_below_min "${value}"; then
          printf 'omc-config: %s must be at least 512 (got: %s)\n' \
            "${key_preview}" "${value_preview}" >&2
        else
          printf 'omc-config: %s must be a canonical decimal integer from 512 to 12000 (got: %s)\n' \
            "${key_preview}" "${value_preview}" >&2
        fi
        return 2
      fi
      ;;
    enum:*)
      local raw="${flag_type#enum:}"
      local pattern="^(${raw//\//|})$"
      if [[ ! "${value}" =~ ${pattern} ]]; then
        printf 'omc-config: %s must be one of %s (got: %s)\n' \
          "${key_preview}" "${raw}" "${value_preview}" >&2
        return 2
      fi
      ;;
    str)
      # Free-form values still must not contain control chars — a value
      # carrying a literal newline would smuggle a second `key=value` line
      # into the conf at write time, bypassing validation entirely. This
      # is the conf-equivalent of CRLF injection.
      if [[ "${value}" == *[[:cntrl:]]* ]]; then
        printf 'omc-config: %s value cannot contain control characters (including newlines or carriage returns)\n' \
          "${key_preview}" >&2
        return 2
      fi
      if [[ "${key}" == "custom_verify_patterns" && -n "${value}" ]] \
          && ! ere_is_valid "${value}"; then
        printf 'omc-config: custom_verify_patterns must be a valid extended regular expression\n' >&2
        return 2
      fi
      # v1.32.16 (4-attacker security review, A2-LOW-5): claude_bin
      # carries a path that the resume-watchdog later execs. Apply the
      # same executable and path-prefix constraints as common.sh so the
      # writer never lands a value the runtime will silently drop.
      # Pre-fix divergence: `omc-config set user claude_bin=relative`
      # would write the line (parser later silently ignores), causing
      # an audit confusion where the user thinks the pin is set but
      # the watchdog uses live `command -v claude` instead.
      #
      # Path-prefix denylist mirrors the post-load common.sh block
      # (rejects `/tmp/`, `/var/tmp/`, `/Users/Shared/`, `/dev/shm/`,
      # `/private/tmp/`) so an attacker who tries to write a hostile
      # pin through omc-config gets blocked at write time too.
      if [[ "${key}" == "claude_bin" && -n "${value}" ]]; then
        if [[ ! "${value}" =~ ^/ ]]; then
          printf 'omc-config: claude_bin must be an absolute path (^/), got: %s\n' \
            "${value_preview}" >&2
          return 2
        fi
        case "${value}" in
          /tmp/*|/private/tmp/*|/var/tmp/*|/Users/Shared/*|/dev/shm/*)
            printf 'omc-config: claude_bin under world-writable / shared location is rejected: %s\n' \
              "${value_preview}" >&2
            return 2
            ;;
        esac
        if [[ ! -f "${value}" || ! -x "${value}" ]]; then
          printf 'omc-config: claude_bin must name an existing executable file (got: %s)\n' \
            "${value_preview}" >&2
          return 2
        fi
      fi
      if [[ "${key}" == "model_overrides" ]] \
          && ! model_overrides_value_is_valid "${value}"; then
        printf 'omc-config: model_overrides must be empty or comma-separated agent:model pins; agent is a bare or one-colon namespaced id, model is opus|sonnet|haiku|inherit, and inherit requires a bare materializable agent (got: %s)\n' \
          "${value_preview}" >&2
        return 2
      fi
      ;;
  esac
  return 0
}

# Refuse lexical aliases and non-regular leaves for mutation. Read-only config
# discovery may follow an existing user symlink, but a writer must never sever
# that alias or move a staged file inside a directory while reporting success.
safe_mutation_leaf() {
  local path="${1:-}" label="${2:-file}"
  if [[ -L "${path}" ]]; then
    printf 'omc-config: refusing symlinked %s target: %s\n' \
      "${label}" "$(diagnostic_preview "${path}")" >&2
    return 1
  fi
  if [[ -e "${path}" && ! -f "${path}" ]]; then
    printf 'omc-config: refusing non-regular %s target: %s\n' \
      "${label}" "$(diagnostic_preview "${path}")" >&2
    return 1
  fi
}

safe_project_conf_parent() {
  local conf="${1:-}" physical_root="" expected_parent="" parent=""
  physical_root="$(pwd -P)" || return 1
  expected_parent="${physical_root}/.claude"
  parent="${conf%/*}"
  if [[ "${parent}" != "${expected_parent}" || -L "${parent}" ]] \
      || { [[ -e "${parent}" ]] && [[ ! -d "${parent}" ]]; }; then
    printf 'omc-config: refusing unsafe project config directory: %s\n' \
      "$(diagnostic_preview "${parent}")" >&2
    return 1
  fi
  if [[ -d "${parent}" \
      && "$(cd "${parent}" 2>/dev/null && pwd -P)" \
        != "${expected_parent}" ]]; then
    printf 'omc-config: project config directory escapes the physical project root: %s\n' \
      "$(diagnostic_preview "${parent}")" >&2
    return 1
  fi
}

file_mode_value() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-7]{3,4}$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-7]{3,4}$ ]] || return 1
  printf '%s' "${candidate}"
}

file_size_value() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%z' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%s' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

copy_file_mode() {
  local source="${1:-}" destination="${2:-}" mode=""
  mode="$(file_mode_value "${source}")" || return 1
  chmod "${mode}" "${destination}"
}

file_identity() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%d:%i' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%d:%i' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

file_owner_value() {
  local path="${1:-}" candidate=""
  candidate="$(stat -f '%u' "${path}" 2>/dev/null || true)"
  if [[ "${candidate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${candidate}"
    return 0
  fi
  candidate="$(stat -c '%u' "${path}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${candidate}"
}

file_digest() {
  local path="${1:-}" digest=""
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "${path}" 2>/dev/null)" || return 1
    printf 'sha256:%s' "${digest%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "${path}" 2>/dev/null)" || return 1
    printf 'sha256:%s' "${digest%% *}"
  else
    digest="$(cksum < "${path}" 2>/dev/null)" || return 1
    printf 'cksum:%s' "${digest}"
  fi
}

omc_tx_safe_file() {
  [[ -f "${1:-}" && ! -L "${1:-}" ]]
}

OMC_TX_TEXT_SNAPSHOT=""

# Snapshot durable text before Bash can normalize it. In particular, command
# substitution silently discards raw NUL bytes; byte-count equality plus exact
# record framing prevents malformed WAL authority from becoming valid after
# import. `line` is one non-empty LF-terminated record, `tsv` is empty or a
# sequence of non-empty records, and `tsv-row` is exactly one record.
omc_tx_read_text_snapshot() {
  local path="${1:-}" kind="${2:-}" max_bytes="${3:-262144}"
  local source_id="" source_digest="" size="" bad_bytes="" lf_count=""
  local payload="" payload_digest=""
  local LC_ALL=C
  OMC_TX_TEXT_SNAPSHOT=""
  omc_tx_safe_file "${path}" || return 1
  [[ "${max_bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  source_id="$(file_identity "${path}")" || return 1
  size="$(file_size_value "${path}")" || return 1
  [[ "${size}" =~ ^[0-9]+$ && "${size}" -le "${max_bytes}" ]] || return 1
  source_digest="$(file_digest "${path}")" || return 1
  bad_bytes="$(LC_ALL=C tr -cd '\000\r' < "${path}" \
    | LC_ALL=C wc -c | tr -d '[:space:]')" || return 1
  [[ "${bad_bytes}" == "0" ]] || return 1
  [[ "${kind}" == "line" || "${kind}" == "tsv" \
      || "${kind}" == "tsv-row" ]] || return 1
  payload="$(command cat -- "${path}" && printf '\034')" || return 1
  [[ "${payload}" == *$'\034' ]] || return 1
  payload="${payload%$'\034'}"
  [[ "${#payload}" -eq "${size}" ]] || return 1
  payload_digest="$(file_digest <(printf '%s' "${payload}"))" || return 1
  [[ "${payload_digest}" == "${source_digest}" ]] || return 1
  case "${payload}" in
    *'\u0000'*|*'\U0000'*|*'\x00'*|*'\X00'*|*'\0'*) return 1 ;;
  esac
  [[ "${payload}" != *$'\r'* ]] || return 1
  case "${kind}" in
    line)
      [[ "${#payload}" -gt 1 && "${payload}" == *$'\n' \
          && "${payload}" != *$'\t'* ]] || return 1
      lf_count="$(printf '%s' "${payload}" | LC_ALL=C tr -cd '\n' \
        | LC_ALL=C wc -c | tr -d '[:space:]')" || return 1
      [[ "${lf_count}" == "1" ]] || return 1
      ;;
    tsv|tsv-row)
      if [[ -z "${payload}" ]]; then
        [[ "${kind}" == "tsv" ]] || return 1
      else
        [[ "${payload}" == *$'\n' ]] || return 1
        awk 'length($0) == 0 { exit 1 }' \
          < <(printf '%s' "${payload}") || return 1
        if [[ "${kind}" == "tsv-row" ]]; then
          lf_count="$(printf '%s' "${payload}" | LC_ALL=C tr -cd '\n' \
            | LC_ALL=C wc -c | tr -d '[:space:]')" || return 1
          [[ "${lf_count}" == "1" ]] || return 1
        fi
      fi
      ;;
  esac
  [[ -f "${path}" && ! -L "${path}" \
      && "$(file_identity "${path}" 2>/dev/null || true)" == "${source_id}" \
      && "$(file_size_value "${path}" 2>/dev/null || true)" == "${size}" \
      && "$(file_digest "${path}" 2>/dev/null || true)" \
        == "${source_digest}" ]] || return 1
  OMC_TX_TEXT_SNAPSHOT="${payload}"
}

omc_tx_read_line() {
  omc_tx_read_text_snapshot "${1:-}" line "${2:-4096}" || return 1
  OMC_TX_TEXT_SNAPSHOT="${OMC_TX_TEXT_SNAPSHOT%$'\n'}"
}

omc_lock_read_pid() {
  omc_tx_read_line "${1:-}" 128 || return 1
  [[ "${OMC_TX_TEXT_SNAPSHOT}" =~ ^[1-9][0-9]*$ ]]
}

omc_lock_read_token() {
  omc_tx_read_line "${1:-}" 512 || return 1
  [[ "${OMC_TX_TEXT_SNAPSHOT}" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]
}

omc_tx_read_tsv() {
  omc_tx_read_text_snapshot "${1:-}" tsv "${2:-262144}"
}

omc_tx_read_tsv_row() {
  omc_tx_read_text_snapshot "${1:-}" tsv-row "${2:-4096}"
}

omc_tx_validate_tsv_snapshot() {
  local kind="${1:-}" snapshot="${2-}" name="" digest="" mode=""
  local unique=0
  [[ "${kind}" == "agent-roster" ]] && unique=1
  case "${kind}" in
    agent|agent-roster)
      awk -F '\t' -v unique="${unique}" \
        'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ ||
          (unique == 1 && seen[$1]++) { bad=1 } END { exit(bad ? 1 : 0) }' \
        < <(printf '%s' "${snapshot}") || return 1
      while IFS=$'\t' read -r name digest mode; do
        omc_tx_digest_is_valid "${digest}" || return 1
        [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      done < <(printf '%s' "${snapshot}")
      ;;
    digest)
      awk -F '\t' 'NF != 2 { exit 1 }' \
        < <(printf '%s' "${snapshot}") || return 1
      while IFS=$'\t' read -r digest mode; do
        omc_tx_digest_is_valid "${digest}" || return 1
        [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      done < <(printf '%s' "${snapshot}")
      ;;
    *) return 1 ;;
  esac
}

omc_tx_digest_is_valid() {
  local value="${1:-}" payload=""
  case "${value}" in
    sha256:*)
      payload="${value#sha256:}"
      [[ "${#payload}" -eq 64 && "${payload}" =~ ^[0-9a-fA-F]+$ ]]
      ;;
    cksum:*)
      payload="${value#cksum:}"
      [[ "${payload}" =~ ^[0-9]+[[:space:]][0-9]+$ ]]
      ;;
    *) return 1 ;;
  esac
}

omc_tx_leaf_matches() {
  local path="${1:-}" digest="${2:-}" mode="${3:-}"
  safe_mutation_leaf "${path}" "transaction leaf" >/dev/null 2>&1 || return 1
  [[ -f "${path}" ]] || return 1
  [[ "$(file_digest "${path}" 2>/dev/null || true)" == "${digest}" \
      && "$(file_mode_value "${path}" 2>/dev/null || true)" == "${mode}" ]]
}

omc_tx_current_is_accepted() {
  local kind="${1:-}" path="${2:-}" state="${3:-}"
  local entry_digest="${4:-}" entry_mode="${5:-}" digest="" mode=""
  local intents=""
  if [[ "${state}" == "absent" \
      && ! -e "${path}" && ! -L "${path}" ]]; then
    return 0
  fi
  [[ "${state}" == "present" || "${state}" == "absent" ]] || return 1
  safe_mutation_leaf "${path}" "${kind}" >/dev/null 2>&1 || return 1
  [[ -f "${path}" ]] || return 1
  digest="$(file_digest "${path}")" || return 1
  mode="$(file_mode_value "${path}")" || return 1
  if [[ "${state}" == "present" && "${digest}" == "${entry_digest}" \
      && "${mode}" == "${entry_mode}" ]]; then
    return 0
  fi
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/${kind}-intents.tsv" || return 1
  intents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot digest "${intents}" || return 1
  awk -F '\t' -v digest="${digest}" -v mode="${mode}" \
    '$1 == digest && $2 == mode { found=1 } END { exit(found ? 0 : 1) }' \
    < <(printf '%s' "${intents}")
}

omc_tx_restore_file() {
  local snapshot="${1:-}" target="${2:-}" mode="${3:-}" tmp=""
  omc_tx_safe_file "${snapshot}" || return 1
  tmp="$(mktemp "${target%/*}/.$(basename "${target}").omc-recover.XXXXXX")" \
    || return 1
  if ! cp -- "${snapshot}" "${tmp}" || ! chmod "${mode}" "${tmp}" \
      || ! mv -f -- "${tmp}" "${target}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  omc_tx_leaf_matches "${target}" "$(file_digest "${snapshot}")" "${mode}"
}

omc_tx_verify_restored_generations() {
  local state="" digest="" mode="" name="" settings_state=""
  local conf_entry="" settings_entry="" agents="" agents_dir_id=""
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/conf-state" || return 1
  state="${OMC_TX_TEXT_SNAPSHOT}"
  if [[ "${state}" == "present" ]]; then
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" || return 1
    conf_entry="${OMC_TX_TEXT_SNAPSHOT}"
    IFS=$'\t' read -r digest mode \
      < <(printf '%s' "${conf_entry}") || return 1
    omc_tx_digest_is_valid "${digest}" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    omc_tx_leaf_matches "${USER_CONF}" "${digest}" "${mode}" || return 1
  elif [[ "${state}" == "absent" ]]; then
    [[ ! -e "${USER_CONF}" && ! -L "${USER_CONF}" ]] || return 1
  else
    return 1
  fi
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/settings-state" || return 1
  settings_state="${OMC_TX_TEXT_SNAPSHOT}"
  if [[ "${settings_state}" == "present" ]]; then
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" || return 1
    settings_entry="${OMC_TX_TEXT_SNAPSHOT}"
    IFS=$'\t' read -r digest mode \
      < <(printf '%s' "${settings_entry}") || return 1
    omc_tx_digest_is_valid "${digest}" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    omc_tx_leaf_matches "${CLAUDE_HOME}/settings.json" \
      "${digest}" "${mode}" || return 1
  elif [[ "${settings_state}" == "absent" ]]; then
    [[ ! -e "${CLAUDE_HOME}/settings.json" \
        && ! -L "${CLAUDE_HOME}/settings.json" ]] || return 1
  elif [[ "${settings_state}" != "ignored" ]]; then
    return 1
  fi
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agents.tsv" || return 1
  agents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot agent-roster "${agents}" || return 1
  if [[ -n "${agents}" ]]; then
    omc_tx_read_line "${OMC_CONFIG_TX_DIR}/agents-dir-id" || return 1
    agents_dir_id="${OMC_TX_TEXT_SNAPSHOT}"
    [[ -d "${CLAUDE_HOME}/agents" && ! -L "${CLAUDE_HOME}/agents" \
        && "$(file_identity "${CLAUDE_HOME}/agents" \
          2>/dev/null || true)" \
          == "${agents_dir_id}" ]] || return 1
  fi
  while IFS=$'\t' read -r name digest mode; do
    omc_tx_leaf_matches "${CLAUDE_HOME}/agents/${name}" \
      "${digest}" "${mode}" || return 1
  done < <(printf '%s' "${agents}")
}

retire_omc_config_transaction() {
  local expected_id="" parent="" retired="" retired_id=""
  local marker=""
  if [[ ! -e "${OMC_CONFIG_TX_DIR}" && ! -L "${OMC_CONFIG_TX_DIR}" ]]; then
    [[ -z "${OMC_CONFIG_TX_ID}" ]]
    return
  fi
  [[ -d "${OMC_CONFIG_TX_DIR}" && ! -L "${OMC_CONFIG_TX_DIR}" ]] || return 1
  OMC_CONFIG_TX_ACTIVE=1
  expected_id="$(file_identity "${OMC_CONFIG_TX_DIR}")" || return 1
  if [[ -n "${OMC_CONFIG_TX_ID}" \
      && "${expected_id}" != "${OMC_CONFIG_TX_ID}" ]]; then
    return 1
  fi
  OMC_CONFIG_TX_ID="${expected_id}"
  parent="$(mktemp -d "${CLAUDE_HOME}/.omc-config-retired.XXXXXX")" \
    || return 1
  chmod 700 "${parent}" || { rmdir "${parent}" 2>/dev/null || true; return 1; }
  retired="${parent}/transaction"
  mv -- "${OMC_CONFIG_TX_DIR}" "${retired}" || {
    rmdir "${parent}" 2>/dev/null || true
    return 1
  }
  retired_id="$(file_identity "${retired}" 2>/dev/null || true)"
  if [[ -e "${OMC_CONFIG_TX_DIR}" || -L "${OMC_CONFIG_TX_DIR}" \
      || "${retired_id}" != "${expected_id}" ]]; then
    if [[ "${retired_id}" == "${expected_id}" \
        && ! -e "${OMC_CONFIG_TX_DIR}" && ! -L "${OMC_CONFIG_TX_DIR}" ]]; then
      mv -- "${retired}" "${OMC_CONFIG_TX_DIR}" 2>/dev/null || true
    fi
    return 1
  fi
  omc_config_test_barrier \
    "${OMC_TEST_CONFIG_RETIRE_MOVED_READY_FILE:-}" \
    "${OMC_TEST_CONFIG_RETIRE_MOVED_RELEASE_FILE:-}" "${parent}" || return 1
  marker="${parent}/retirement-authorized"
  if ! printf '1\n%s\n' "${retired_id}" > "${marker}" \
      || ! chmod 600 "${marker}"; then
    rm -f -- "${marker}" 2>/dev/null || true
    if [[ ! -e "${OMC_CONFIG_TX_DIR}" && ! -L "${OMC_CONFIG_TX_DIR}" \
        && "$(file_identity "${retired}" 2>/dev/null || true)" \
          == "${expected_id}" ]]; then
      mv -- "${retired}" "${OMC_CONFIG_TX_DIR}" 2>/dev/null || true
    fi
    rmdir "${parent}" 2>/dev/null || true
    return 1
  fi
  omc_config_test_barrier \
    "${OMC_TEST_CONFIG_RETIRE_READY_FILE:-}" \
    "${OMC_TEST_CONFIG_RETIRE_RELEASE_FILE:-}" "${parent}" || return 1
  [[ -d "${retired}" && ! -L "${retired}" \
      && "$(file_identity "${retired}" 2>/dev/null || true)" \
        == "${retired_id}" ]] \
    && omc_retirement_marker_valid "${parent}" || return 1
  rm -rf -- "${retired}" || return 1
  OMC_CONFIG_TX_ACTIVE=0
  rm -f -- "${marker}" || return 1
  rmdir "${parent}" || return 1
  [[ ! -e "${parent}" && ! -L "${parent}" ]] || return 1
  OMC_CONFIG_TX_ID=""
}

omc_private_owned_dir() {
  local path="${1:-}" expected_name_re="${2:-}" name="" uid=""
  [[ -d "${path}" && ! -L "${path}" ]] || return 1
  name="$(basename "${path}")"
  [[ "${name}" =~ ${expected_name_re} ]] || return 1
  uid="$(id -u)" || return 1
  [[ "$(file_owner_value "${path}" 2>/dev/null || true)" == "${uid}" \
      && "$(file_mode_value "${path}" 2>/dev/null || true)" == "700" ]]
}

omc_retirement_marker_valid() {
  local parent="${1:-}" tx="" marker="" marker_snapshot="" marker_id=""
  tx="${parent}/transaction"
  marker="${parent}/retirement-authorized"
  omc_tx_safe_file "${marker}" || return 1
  [[ "$(file_mode_value "${marker}" 2>/dev/null || true)" == "600" ]] \
    || return 1
  omc_tx_read_tsv "${marker}" 4096 || return 1
  marker_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
  [[ "$(awk 'NR == 1 { version=$0 } NR == 2 { identity=$0 }
    END { print (NR == 2 && version == "1" && identity ~ /^[0-9]+:[0-9]+$/) ? 1 : 0 }' \
    < <(printf '%s' "${marker_snapshot}"))" == "1" ]] || return 1
  marker_id="$(awk 'NR == 2 { print; exit }' \
    < <(printf '%s' "${marker_snapshot}"))" || return 1
  if [[ -e "${tx}" || -L "${tx}" ]]; then
    [[ -d "${tx}" && ! -L "${tx}" \
        && "$(file_identity "${tx}" 2>/dev/null || true)" \
          == "${marker_id}" ]] || return 1
  fi
}

sweep_omc_config_transaction_orphans() {
  local candidate="" old_tx="" old_active=0 old_recovering=0 old_id=""
  local marker=""
  for candidate in "${CLAUDE_HOME}"/.omc-config-transaction.stage.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    omc_private_owned_dir "${candidate}" \
      '^\.omc-config-transaction\.stage\.[A-Za-z0-9]+$' || {
      printf 'omc-config: unsafe orphan config stage requires manual inspection: %s\n' \
        "${candidate}" >&2
      return 1
    }
    rm -rf -- "${candidate}" || return 1
  done
  for candidate in "${CLAUDE_HOME}"/.omc-config-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    omc_private_owned_dir "${candidate}" \
      '^\.omc-config-retired\.[A-Za-z0-9]+$' || {
      printf 'omc-config: unsafe retired config transaction requires manual inspection: %s\n' \
        "${candidate}" >&2
      return 1
    }
    marker="${candidate}/retirement-authorized"
    if omc_retirement_marker_valid "${candidate}"; then
      omc_private_owned_dir "${candidate}" \
        '^\.omc-config-retired\.[A-Za-z0-9]+$' \
        && omc_retirement_marker_valid "${candidate}" || return 1
      rm -rf -- "${candidate}/transaction" || return 1
      rm -f -- "${marker}" || return 1
      rmdir "${candidate}" || return 1
      continue
    fi
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      omc_tx_safe_file "${marker}" \
        && [[ "$(file_owner_value "${marker}" 2>/dev/null || true)" \
          == "$(id -u)" ]] || return 1
      rm -f -- "${marker}" || return 1
    fi
    if [[ ! -e "${candidate}/transaction" \
        && ! -L "${candidate}/transaction" ]]; then
      rmdir "${candidate}" || return 1
      continue
    fi
    [[ -d "${candidate}/transaction" \
        && ! -L "${candidate}/transaction" ]] || return 1
    old_tx="${OMC_CONFIG_TX_DIR}"
    old_active="${OMC_CONFIG_TX_ACTIVE}"
    old_recovering="${OMC_CONFIG_TX_RECOVERING}"
    old_id="${OMC_CONFIG_TX_ID}"
    OMC_CONFIG_TX_DIR="${candidate}/transaction"
    OMC_CONFIG_TX_ID=""
    if ! recover_omc_config_transaction; then
      OMC_CONFIG_TX_DIR="${old_tx}"
      OMC_CONFIG_TX_ACTIVE="${old_active}"
      OMC_CONFIG_TX_RECOVERING="${old_recovering}"
      OMC_CONFIG_TX_ID="${old_id}"
      return 1
    fi
    OMC_CONFIG_TX_DIR="${old_tx}"
    OMC_CONFIG_TX_ACTIVE="${old_active}"
    OMC_CONFIG_TX_RECOVERING="${old_recovering}"
    OMC_CONFIG_TX_ID="${old_id}"
    rmdir "${candidate}" || {
      printf 'omc-config: retired config transaction still contains unexpected data: %s\n' \
        "${candidate}" >&2
      return 1
    }
  done
}

switch_transaction_metadata_pending() {
  local candidate=""
  [[ -e "${CLAUDE_HOME}/.switch-tier-transaction" \
      || -L "${CLAUDE_HOME}/.switch-tier-transaction" ]] \
    && return 0
  for candidate in "${CLAUDE_HOME}"/.switch-tier-transaction.stage.* \
      "${CLAUDE_HOME}"/.switch-tier-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

settle_switch_transaction_metadata() {
  local switcher="${CLAUDE_HOME}/switch-tier.sh"
  switch_transaction_metadata_pending || return 0
  [[ -x "${switcher}" ]] || return 1
  bash "${switcher}" --recover-only
}

begin_omc_config_transaction() {
  local needs_model="${1:-0}" needs_settings="${2:-0}" stage="" stage_id=""
  local state="" id="" digest="" mode="" snapshot=""
  local agent="" path="" agents_dir_id="" agents_snapshot=""
  local entry_snapshot="" metadata_value="" intent_snapshot=""
  [[ "${needs_model}" =~ ^[01]$ && "${needs_settings}" =~ ^[01]$ ]] || return 1
  [[ ! -e "${OMC_CONFIG_TX_DIR}" && ! -L "${OMC_CONFIG_TX_DIR}" ]] || return 1
  stage="$(mktemp -d "${CLAUDE_HOME}/.omc-config-transaction.stage.XXXXXX")" \
    || return 1
  chmod 700 "${stage}" || { rm -rf -- "${stage}"; return 1; }
  local switch_capability=""
  switch_capability="$$.${RANDOM}.${RANDOM}.$(date +%s)" || {
    rm -rf -- "${stage}"
    return 1
  }
  if ! printf '1\n' > "${stage}/version" \
      || ! printf '%s\n' "${needs_model}" > "${stage}/needs-model" \
      || ! printf '%s\n' "${needs_settings}" > "${stage}/needs-settings" \
      || ! printf '%s\n' "${switch_capability}" > "${stage}/switch-capability" \
      || ! : > "${stage}/conf-intents.tsv" \
      || ! : > "${stage}/settings-intents.tsv" \
      || ! : > "${stage}/agent-intents.tsv" \
      || ! : > "${stage}/agents.tsv"; then
    rm -rf -- "${stage}"
    return 1
  fi
  chmod 600 "${stage}/"{version,needs-model,needs-settings,switch-capability,conf-intents.tsv,settings-intents.tsv,agent-intents.tsv,agents.tsv} \
    || { rm -rf -- "${stage}"; return 1; }

  safe_mutation_leaf "${USER_CONF}" "config" || { rm -rf -- "${stage}"; return 1; }
  if [[ -f "${USER_CONF}" ]]; then
    id="$(file_identity "${USER_CONF}")" || { rm -rf -- "${stage}"; return 1; }
    digest="$(file_digest "${USER_CONF}")" || { rm -rf -- "${stage}"; return 1; }
    mode="$(file_mode_value "${USER_CONF}")" || { rm -rf -- "${stage}"; return 1; }
    cp -p -- "${USER_CONF}" "${stage}/conf-entry" \
      || { rm -rf -- "${stage}"; return 1; }
    [[ "$(file_identity "${USER_CONF}" 2>/dev/null || true)" == "${id}" \
        && "$(file_digest "${USER_CONF}" 2>/dev/null || true)" == "${digest}" \
        && "$(file_mode_value "${USER_CONF}" 2>/dev/null || true)" == "${mode}" \
        && "$(file_digest "${stage}/conf-entry" 2>/dev/null || true)" == "${digest}" \
        && "$(file_mode_value "${stage}/conf-entry" 2>/dev/null || true)" == "${mode}" ]] \
      || { rm -rf -- "${stage}"; return 1; }
    if ! printf 'present\n' > "${stage}/conf-state" \
        || ! printf '%s\t%s\n' "${digest}" "${mode}" \
          > "${stage}/conf-entry.tsv" \
        || ! chmod 600 "${stage}/conf-entry.tsv"; then
      rm -rf -- "${stage}"
      return 1
    fi
  else
    printf 'absent\n' > "${stage}/conf-state" \
      || { rm -rf -- "${stage}"; return 1; }
  fi
  chmod 600 "${stage}/conf-state" || { rm -rf -- "${stage}"; return 1; }

  local settings="${CLAUDE_HOME}/settings.json"
  if [[ "${needs_settings}" -eq 1 ]]; then
    safe_mutation_leaf "${settings}" "settings.json" \
      || { rm -rf -- "${stage}"; return 1; }
    if [[ -f "${settings}" ]]; then
      id="$(file_identity "${settings}")" || { rm -rf -- "${stage}"; return 1; }
      digest="$(file_digest "${settings}")" || { rm -rf -- "${stage}"; return 1; }
      mode="$(file_mode_value "${settings}")" || { rm -rf -- "${stage}"; return 1; }
      cp -p -- "${settings}" "${stage}/settings-entry" \
        || { rm -rf -- "${stage}"; return 1; }
      [[ "$(file_identity "${settings}" 2>/dev/null || true)" == "${id}" \
          && "$(file_digest "${settings}" 2>/dev/null || true)" == "${digest}" \
          && "$(file_mode_value "${settings}" 2>/dev/null || true)" == "${mode}" \
          && "$(file_digest "${stage}/settings-entry" 2>/dev/null || true)" == "${digest}" \
          && "$(file_mode_value "${stage}/settings-entry" 2>/dev/null || true)" == "${mode}" ]] \
        || { rm -rf -- "${stage}"; return 1; }
      if ! printf 'present\n' > "${stage}/settings-state" \
          || ! printf '%s\t%s\n' "${digest}" "${mode}" \
            > "${stage}/settings-entry.tsv" \
          || ! chmod 600 "${stage}/settings-entry.tsv"; then
        rm -rf -- "${stage}"
        return 1
      fi
    else
      printf 'absent\n' > "${stage}/settings-state" \
        || { rm -rf -- "${stage}"; return 1; }
    fi
  else
    printf 'ignored\n' > "${stage}/settings-state" \
      || { rm -rf -- "${stage}"; return 1; }
  fi
  chmod 600 "${stage}/settings-state" || { rm -rf -- "${stage}"; return 1; }

  if [[ "${needs_model}" -eq 1 ]]; then
    [[ -d "${CLAUDE_HOME}/agents" \
        && ! -L "${CLAUDE_HOME}/agents" ]] \
      || { rm -rf -- "${stage}"; return 1; }
    agents_dir_id="$(file_identity "${CLAUDE_HOME}/agents")" \
      || { rm -rf -- "${stage}"; return 1; }
    printf '%s\n' "${agents_dir_id}" > "${stage}/agents-dir-id" \
      || { rm -rf -- "${stage}"; return 1; }
    chmod 600 "${stage}/agents-dir-id" \
      || { rm -rf -- "${stage}"; return 1; }
    mkdir "${stage}/agents" || { rm -rf -- "${stage}"; return 1; }
    chmod 700 "${stage}/agents" || { rm -rf -- "${stage}"; return 1; }
    for agent in ${OMC_CONFIG_SHIPPED_INHERIT_AGENTS} \
        ${OMC_CONFIG_SHIPPED_FIXED_AGENTS}; do
      path="${CLAUDE_HOME}/agents/${agent}.md"
      [[ -e "${path}" || -L "${path}" ]] || continue
      safe_mutation_leaf "${path}" "agent definition" \
        || { rm -rf -- "${stage}"; return 1; }
      id="$(file_identity "${path}")" || { rm -rf -- "${stage}"; return 1; }
      digest="$(file_digest "${path}")" || { rm -rf -- "${stage}"; return 1; }
      mode="$(file_mode_value "${path}")" || { rm -rf -- "${stage}"; return 1; }
      snapshot="${stage}/agents/${agent}.md"
      cp -p -- "${path}" "${snapshot}" || { rm -rf -- "${stage}"; return 1; }
      [[ "$(file_identity "${path}" 2>/dev/null || true)" == "${id}" \
          && "$(file_digest "${path}" 2>/dev/null || true)" == "${digest}" \
          && "$(file_mode_value "${path}" 2>/dev/null || true)" == "${mode}" \
          && "$(file_digest "${snapshot}" 2>/dev/null || true)" == "${digest}" \
          && "$(file_mode_value "${snapshot}" 2>/dev/null || true)" == "${mode}" ]] \
        || { rm -rf -- "${stage}"; return 1; }
      printf '%s\t%s\t%s\n' "${agent}.md" "${digest}" "${mode}" \
        >> "${stage}/agents.tsv" \
        || { rm -rf -- "${stage}"; return 1; }
    done
    [[ -s "${stage}/agents.tsv" ]] || { rm -rf -- "${stage}"; return 1; }
  fi
  stage_id="$(file_identity "${stage}")" || { rm -rf -- "${stage}"; return 1; }
  omc_config_test_barrier \
    "${OMC_TEST_CONFIG_WAL_STAGE_READY_FILE:-}" \
    "${OMC_TEST_CONFIG_WAL_STAGE_RELEASE_FILE:-}" "${stage}" || {
    rm -rf -- "${stage}"
    return 1
  }
  mv -- "${stage}" "${OMC_CONFIG_TX_DIR}" \
    || { rm -rf -- "${stage}"; return 1; }
  if [[ -e "${stage}" || -L "${stage}" \
      || ! -d "${OMC_CONFIG_TX_DIR}" || -L "${OMC_CONFIG_TX_DIR}" \
      || "$(file_identity "${OMC_CONFIG_TX_DIR}" 2>/dev/null || true)" \
        != "${stage_id}" ]]; then
    printf 'omc-config: durable parent transaction publication raced with another writer\n' >&2
    return 1
  fi
  if [[ "${needs_model}" -eq 1 ]] \
      && { [[ ! -d "${CLAUDE_HOME}/agents" ]] \
        || [[ -L "${CLAUDE_HOME}/agents" ]] \
        || [[ "$(file_identity "${CLAUDE_HOME}/agents" \
          2>/dev/null || true)" != "${agents_dir_id}" ]]; }; then
    return 1
  fi
  OMC_CONFIG_TX_ACTIVE=1
  OMC_CONFIG_TX_ID="${stage_id}"
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/version" || return 1
  [[ "${OMC_TX_TEXT_SNAPSHOT}" == "1" ]] || return 1
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/needs-model" || return 1
  [[ "${OMC_TX_TEXT_SNAPSHOT}" == "${needs_model}" ]] || return 1
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/needs-settings" || return 1
  [[ "${OMC_TX_TEXT_SNAPSHOT}" == "${needs_settings}" ]] || return 1
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/switch-capability" || return 1
  [[ "${OMC_TX_TEXT_SNAPSHOT}" == "${switch_capability}" ]] || return 1
  for path in conf-intents.tsv settings-intents.tsv agent-intents.tsv; do
    omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/${path}" || return 1
    intent_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
    [[ -z "${intent_snapshot}" ]] || return 1
  done
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/conf-state" || return 1
  state="${OMC_TX_TEXT_SNAPSHOT}"
  if [[ "${state}" == "present" ]]; then
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" || return 1
    entry_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
    IFS=$'\t' read -r digest mode \
      < <(printf '%s' "${entry_snapshot}") || return 1
    omc_tx_digest_is_valid "${digest}" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  elif [[ "${state}" == "absent" ]]; then
    digest=""
    mode=""
  else
    return 1
  fi
  omc_tx_current_is_accepted conf "${USER_CONF}" "${state}" "${digest}" "${mode}" \
    || { retire_omc_config_transaction; return 1; }
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/settings-state" || return 1
  state="${OMC_TX_TEXT_SNAPSHOT}"
  if [[ "${state}" == "present" ]]; then
    [[ "${needs_settings}" == "1" ]] || return 1
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" || return 1
    entry_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
    IFS=$'\t' read -r digest mode \
      < <(printf '%s' "${entry_snapshot}") || return 1
    omc_tx_digest_is_valid "${digest}" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    omc_tx_current_is_accepted settings "${settings}" present "${digest}" "${mode}" \
      || { retire_omc_config_transaction; return 1; }
  elif [[ "${state}" == "absent" ]]; then
    [[ "${needs_settings}" == "1" ]] || return 1
    omc_tx_current_is_accepted settings "${settings}" absent "" "" \
      || { retire_omc_config_transaction; return 1; }
  elif [[ "${state}" != "ignored" || "${needs_settings}" != "0" ]]; then
    return 1
  fi
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agents.tsv" || return 1
  agents_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot agent-roster "${agents_snapshot}" || return 1
  if [[ "${needs_model}" == "1" ]]; then
    [[ -n "${agents_snapshot}" ]] || return 1
    omc_tx_read_line "${OMC_CONFIG_TX_DIR}/agents-dir-id" || return 1
    metadata_value="${OMC_TX_TEXT_SNAPSHOT}"
    [[ "${metadata_value}" == "${agents_dir_id}" ]] || return 1
  elif [[ -n "${agents_snapshot}" ]]; then
    return 1
  fi
  [[ "$(awk -F '\t' 'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ ||
      seen[$1]++ { bad=1 } END { print bad ? 0 : 1 }' \
      < <(printf '%s' "${agents_snapshot}"))" == "1" ]] || return 1
  while IFS=$'\t' read -r agent digest mode; do
    omc_tx_digest_is_valid "${digest}" \
      && [[ "${mode}" =~ ^[0-7]{3,4}$ ]] \
      && model_agent_is_shipped "${agent%.md}" || return 1
    path="${CLAUDE_HOME}/agents/${agent}"
    omc_tx_leaf_matches "${path}" "${digest}" "${mode}" \
      || { retire_omc_config_transaction; return 1; }
  done < <(printf '%s' "${agents_snapshot}")
}

omc_tx_record_intent() {
  local kind="${1:-}" staged="${2:-}" digest="" mode=""
  [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 \
      && "${OMC_CONFIG_TX_RECOVERING}" -eq 0 ]] || return 0
  case "${kind}" in conf|settings) ;; *) return 1 ;; esac
  digest="$(file_digest "${staged}")" || return 1
  mode="$(file_mode_value "${staged}")" || return 1
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/${kind}-intents.tsv" || return 1
  omc_tx_validate_tsv_snapshot digest "${OMC_TX_TEXT_SNAPSHOT}" || return 1
  printf '%s\t%s\n' "${digest}" "${mode}" \
    >> "${OMC_CONFIG_TX_DIR}/${kind}-intents.tsv" || return 1
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/${kind}-intents.tsv" || return 1
  omc_tx_validate_tsv_snapshot digest "${OMC_TX_TEXT_SNAPSHOT}"
}

omc_tx_record_agent_generations() {
  local name="" ignored_digest="" ignored_mode=""
  local path="" digest="" mode="" expected="" expected_digest=""
  local expected_mode="" agents="" intents=""
  [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 ]] || return 0
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agents.tsv" || return 1
  agents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot agent-roster "${agents}" || return 1
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agent-intents.tsv" || return 1
  intents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot agent "${intents}" || return 1
  while IFS=$'\t' read -r name expected_digest expected_mode; do
    model_agent_is_shipped "${name%.md}" || return 1
    [[ "$(awk -F '\t' -v wanted="${name}" \
      '$1 == wanted { count++ } END { print count + 0 }' \
      < <(printf '%s' "${agents}"))" == "1" ]] || return 1
  done < <(printf '%s' "${intents}")
  while IFS=$'\t' read -r name ignored_digest ignored_mode; do
    path="${CLAUDE_HOME}/agents/${name}"
    safe_mutation_leaf "${path}" "agent definition" >/dev/null 2>&1 || return 1
    digest="$(file_digest "${path}")" || return 1
    mode="$(file_mode_value "${path}")" || return 1
    expected="$(awk -F '\t' -v wanted="${name}" \
      '$1 == wanted { digest=$2; mode=$3 }
        END { if (digest != "") printf "%s\t%s", digest, mode }' \
      < <(printf '%s' "${intents}"))" || return 1
    if [[ -n "${expected}" ]]; then
      IFS=$'\t' read -r expected_digest expected_mode <<< "${expected}"
    else
      expected_digest="${ignored_digest}"
      expected_mode="${ignored_mode}"
    fi
    [[ "${digest}" == "${expected_digest}" \
        && "${mode}" == "${expected_mode}" ]] || return 1
  done < <(printf '%s' "${agents}")
}

omc_tx_verify_final_leaf() {
  local kind="${1:-}" path="${2:-}" entry_state="${3:-}"
  local entry_digest="${4:-}" entry_mode="${5:-}" expected=""
  local expected_digest="" expected_mode="" current_digest="" current_mode=""
  local intents=""
  case "${kind}" in conf|settings) ;; *) return 1 ;; esac
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/${kind}-intents.tsv" || return 1
  intents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot digest "${intents}" || return 1
  expected="$(awk -F '\t' '$1 != "" { digest=$1; mode=$2 }
    END { if (digest != "") printf "%s\t%s", digest, mode }' \
    < <(printf '%s' "${intents}"))" || return 1
  if [[ -n "${expected}" ]]; then
    IFS=$'\t' read -r expected_digest expected_mode <<< "${expected}"
  elif [[ "${entry_state}" == "present" ]]; then
    expected_digest="${entry_digest}"
    expected_mode="${entry_mode}"
  else
    [[ "${entry_state}" == "absent" \
        && ! -e "${path}" && ! -L "${path}" ]]
    return
  fi
  safe_mutation_leaf "${path}" "${kind}" >/dev/null 2>&1 || return 1
  [[ -f "${path}" ]] || return 1
  current_digest="$(file_digest "${path}")" || return 1
  current_mode="$(file_mode_value "${path}")" || return 1
  [[ "${current_digest}" == "${expected_digest}" \
      && "${current_mode}" == "${expected_mode}" ]]
}

omc_tx_verify_final_generations() {
  local state="" digest="" mode="" settings_state=""
  local agents="" agents_dir_id="" entry_snapshot=""
  [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 ]] || return 0
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agents.tsv" || return 1
  agents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_validate_tsv_snapshot agent-roster "${agents}" || return 1
  if [[ -n "${agents}" ]]; then
    omc_tx_read_line "${OMC_CONFIG_TX_DIR}/agents-dir-id" || return 1
    agents_dir_id="${OMC_TX_TEXT_SNAPSHOT}"
    [[ -d "${CLAUDE_HOME}/agents" && ! -L "${CLAUDE_HOME}/agents" \
        && "$(file_identity "${CLAUDE_HOME}/agents" \
          2>/dev/null || true)" \
          == "${agents_dir_id}" ]] || return 1
  fi
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/conf-state" || return 1
  state="${OMC_TX_TEXT_SNAPSHOT}"
  if [[ "${state}" == "present" ]]; then
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" || return 1
    entry_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
    IFS=$'\t' read -r digest mode \
      < <(printf '%s' "${entry_snapshot}") || return 1
  else
    digest=""
    mode=""
  fi
  omc_tx_verify_final_leaf conf "${USER_CONF}" "${state}" \
    "${digest}" "${mode}" || return 1
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/settings-state" || return 1
  settings_state="${OMC_TX_TEXT_SNAPSHOT}"
  if [[ "${settings_state}" != "ignored" ]]; then
    digest=""
    mode=""
    if [[ "${settings_state}" == "present" ]]; then
      omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" || return 1
      entry_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
      IFS=$'\t' read -r digest mode \
        < <(printf '%s' "${entry_snapshot}") || return 1
    fi
    omc_tx_verify_final_leaf settings "${CLAUDE_HOME}/settings.json" \
      "${settings_state}" "${digest}" "${mode}" || return 1
  fi
  omc_tx_record_agent_generations
}

commit_omc_config_transaction() {
  local marker=""
  [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 ]] || return 0
  marker="$(mktemp "${OMC_CONFIG_TX_DIR}/.committed.XXXXXX")" || return 1
  if ! printf 'committed\n' > "${marker}" || ! chmod 600 "${marker}" \
      || ! omc_config_test_barrier \
        "${OMC_TEST_CONFIG_COMMIT_STAGE_READY_FILE:-}" \
        "${OMC_TEST_CONFIG_COMMIT_STAGE_RELEASE_FILE:-}" "${marker}" \
      || ! ln -- "${marker}" "${OMC_CONFIG_TX_DIR}/committed" \
      || ! omc_config_test_barrier \
        "${OMC_TEST_CONFIG_COMMIT_LINK_READY_FILE:-}" \
        "${OMC_TEST_CONFIG_COMMIT_LINK_RELEASE_FILE:-}" \
        "${OMC_CONFIG_TX_DIR}/committed" \
      || ! rm -f -- "${marker}"; then
    rm -f -- "${marker}" 2>/dev/null || true
    return 1
  fi
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/committed" \
    && [[ "${OMC_TX_TEXT_SNAPSHOT}" == "committed" \
      && "$(file_mode_value "${OMC_CONFIG_TX_DIR}/committed" \
        2>/dev/null || true)" == "600" ]]
}

recover_omc_config_transaction() {
  local version="" needs_model="" needs_settings="" state=""
  local digest="" mode="" name="" path="" current_digest=""
  local current_mode=""
  local conf_digest="" conf_mode=""
  local capability="" settings_state="" settings_digest="" settings_mode=""
  local agents_dir_id="" agents="" agent_intents=""
  local conf_intents="" settings_intents="" entry_snapshot=""
  local settings="${CLAUDE_HOME}/settings.json"
  [[ -e "${OMC_CONFIG_TX_DIR}" || -L "${OMC_CONFIG_TX_DIR}" ]] || return 0
  [[ -d "${OMC_CONFIG_TX_DIR}" && ! -L "${OMC_CONFIG_TX_DIR}" ]] || return 1
  [[ "$(file_mode_value "${OMC_CONFIG_TX_DIR}" 2>/dev/null || true)" \
    == "700" ]] || return 1
  local current_tx_id=""
  current_tx_id="$(file_identity "${OMC_CONFIG_TX_DIR}")" || return 1
  [[ -z "${OMC_CONFIG_TX_ID}" || "${OMC_CONFIG_TX_ID}" == "${current_tx_id}" ]] \
    || return 1
  OMC_CONFIG_TX_ID="${current_tx_id}"
  OMC_CONFIG_TX_ACTIVE=1
  for path in version needs-model needs-settings switch-capability conf-state conf-intents.tsv \
      settings-state settings-intents.tsv agents.tsv agent-intents.tsv; do
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/${path}" || return 1
    [[ "$(file_mode_value "${OMC_CONFIG_TX_DIR}/${path}" 2>/dev/null || true)" \
      == "600" ]] || return 1
  done
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/version" || return 1
  version="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/needs-model" || return 1
  needs_model="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/needs-settings" || return 1
  needs_settings="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/switch-capability" || return 1
  capability="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/conf-state" || return 1
  state="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_line "${OMC_CONFIG_TX_DIR}/settings-state" || return 1
  settings_state="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agents.tsv" || return 1
  agents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/agent-intents.tsv" || return 1
  agent_intents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/conf-intents.tsv" || return 1
  conf_intents="${OMC_TX_TEXT_SNAPSHOT}"
  omc_tx_read_tsv "${OMC_CONFIG_TX_DIR}/settings-intents.tsv" || return 1
  settings_intents="${OMC_TX_TEXT_SNAPSHOT}"
  [[ "${version}" == "1" && "${needs_model}" =~ ^[01]$ \
      && "${needs_settings}" =~ ^[01]$ ]] || return 1
  [[ "${capability}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  awk -F '\t' 'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ || seen[$1]++ { bad=1 }
    END { exit(bad ? 1 : 0) }' < <(printf '%s' "${agents}") || return 1
  while IFS=$'\t' read -r name digest mode; do
    omc_tx_digest_is_valid "${digest}" || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    model_agent_is_shipped "${name%.md}" || return 1
  done < <(printf '%s' "${agents}")
  for path in conf settings; do
    if [[ "${path}" == "conf" ]]; then
      entry_snapshot="${conf_intents}"
    else
      entry_snapshot="${settings_intents}"
    fi
    awk -F '\t' 'NF != 2 { exit 1 }' \
      < <(printf '%s' "${entry_snapshot}") || return 1
    while IFS=$'\t' read -r digest mode; do
      omc_tx_digest_is_valid "${digest}" || return 1
      [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    done < <(printf '%s' "${entry_snapshot}")
  done
  awk -F '\t' 'NF != 3 || $1 !~ /^[A-Za-z0-9_-]+[.]md$/ { exit 1 }' \
    < <(printf '%s' "${agent_intents}") || return 1
  while IFS=$'\t' read -r name digest mode; do
    omc_tx_digest_is_valid "${digest}" || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ "$(awk -F '\t' -v wanted="${name}" \
      '$1 == wanted { count++ } END { print count + 0 }' \
      < <(printf '%s' "${agents}"))" == "1" ]] || return 1
  done < <(printf '%s' "${agent_intents}")
  if [[ "${needs_model}" == "0" ]]; then
    [[ -z "${agents}" \
        && -z "${agent_intents}" \
        && ! -e "${OMC_CONFIG_TX_DIR}/agents-dir-id" \
        && ! -L "${OMC_CONFIG_TX_DIR}/agents-dir-id" \
        && ! -e "${OMC_CONFIG_TX_DIR}/agents" \
        && ! -L "${OMC_CONFIG_TX_DIR}/agents" ]] || return 1
  else
    [[ -n "${agents}" \
        && -f "${OMC_CONFIG_TX_DIR}/agents-dir-id" \
        && ! -L "${OMC_CONFIG_TX_DIR}/agents-dir-id" \
        && "$(file_mode_value "${OMC_CONFIG_TX_DIR}/agents-dir-id" \
          2>/dev/null || true)" == "600" \
        && -d "${OMC_CONFIG_TX_DIR}/agents" \
        && ! -L "${OMC_CONFIG_TX_DIR}/agents" \
        && "$(file_mode_value "${OMC_CONFIG_TX_DIR}/agents" \
          2>/dev/null || true)" == "700" ]] || return 1
    omc_tx_read_line "${OMC_CONFIG_TX_DIR}/agents-dir-id" || return 1
    agents_dir_id="${OMC_TX_TEXT_SNAPSHOT}"
    [[ "${agents_dir_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    local listed_count="" snapshot_count=""
    listed_count="$(awk 'END { print NR + 0 }' \
      < <(printf '%s' "${agents}"))" || return 1
    snapshot_count="$(find "${OMC_CONFIG_TX_DIR}/agents" -mindepth 1 \
      -maxdepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')" \
      || return 1
    [[ "${snapshot_count}" == "${listed_count}" ]] || return 1
  fi
  if [[ "${needs_settings}" == "0" ]]; then
    [[ "${settings_state}" == "ignored" \
        && ! -e "${OMC_CONFIG_TX_DIR}/settings-entry" \
        && ! -L "${OMC_CONFIG_TX_DIR}/settings-entry" \
        && ! -e "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" \
        && ! -L "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" \
        && -z "${settings_intents}" ]] || return 1
  else
    case "${settings_state}" in
      present|absent) ;;
      *) return 1 ;;
    esac
  fi
  if [[ "${state}" == "present" ]]; then
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/conf-entry" || return 1
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" || return 1
    [[ "$(file_mode_value "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" \
      2>/dev/null || true)" == "600" ]] || return 1
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" || return 1
    entry_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
    [[ "$(awk -F '\t' 'END { print (NR == 1 && NF == 2) ? 1 : 0 }' \
      < <(printf '%s' "${entry_snapshot}"))" == "1" ]] || return 1
    IFS=$'\t' read -r conf_digest conf_mode \
      < <(printf '%s' "${entry_snapshot}") \
      || return 1
    omc_tx_digest_is_valid "${conf_digest}" || return 1
    [[ "${conf_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    omc_tx_leaf_matches "${OMC_CONFIG_TX_DIR}/conf-entry" \
      "${conf_digest}" "${conf_mode}" \
      || return 1
  elif [[ "${state}" != "absent" ]]; then
    return 1
  elif [[ -e "${OMC_CONFIG_TX_DIR}/conf-entry" \
      || -L "${OMC_CONFIG_TX_DIR}/conf-entry" \
      || -e "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" \
      || -L "${OMC_CONFIG_TX_DIR}/conf-entry.tsv" ]]; then
    return 1
  fi
  if [[ "${settings_state}" == "present" ]]; then
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/settings-entry" || return 1
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" || return 1
    [[ "$(file_mode_value "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" \
      2>/dev/null || true)" == "600" ]] || return 1
    omc_tx_read_tsv_row "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" || return 1
    entry_snapshot="${OMC_TX_TEXT_SNAPSHOT}"
    [[ "$(awk -F '\t' 'END { print (NR == 1 && NF == 2) ? 1 : 0 }' \
      < <(printf '%s' "${entry_snapshot}"))" == "1" ]] || return 1
    IFS=$'\t' read -r settings_digest settings_mode \
      < <(printf '%s' "${entry_snapshot}") || return 1
    omc_tx_digest_is_valid "${settings_digest}" || return 1
    [[ "${settings_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    omc_tx_leaf_matches "${OMC_CONFIG_TX_DIR}/settings-entry" \
      "${settings_digest}" "${settings_mode}" || return 1
  elif [[ "${settings_state}" != "absent" \
      && "${settings_state}" != "ignored" ]]; then
    return 1
  elif [[ "${settings_state}" == "absent" ]] \
      && { [[ -e "${OMC_CONFIG_TX_DIR}/settings-entry" ]] \
        || [[ -L "${OMC_CONFIG_TX_DIR}/settings-entry" ]] \
        || [[ -e "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" ]] \
        || [[ -L "${OMC_CONFIG_TX_DIR}/settings-entry.tsv" ]]; }; then
    return 1
  fi
  while IFS=$'\t' read -r name digest mode; do
    [[ "${name}" =~ ^[A-Za-z0-9_-]+\.md$ \
        && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/agents/${name}" || return 1
    omc_tx_leaf_matches "${OMC_CONFIG_TX_DIR}/agents/${name}" \
      "${digest}" "${mode}" || return 1
  done < <(printf '%s' "${agents}")

  if [[ -e "${OMC_CONFIG_TX_DIR}/committed" \
      || -L "${OMC_CONFIG_TX_DIR}/committed" ]]; then
    omc_tx_safe_file "${OMC_CONFIG_TX_DIR}/committed" || return 1
    omc_tx_read_line "${OMC_CONFIG_TX_DIR}/committed" || return 1
    [[ "${OMC_TX_TEXT_SNAPSHOT}" == "committed" \
        && "$(file_mode_value "${OMC_CONFIG_TX_DIR}/committed" \
          2>/dev/null || true)" == "600" ]] || return 1
    retire_omc_config_transaction || return 1
    printf 'omc-config: recovered committed parent transaction metadata\n'
    return 0
  fi

  if [[ "${needs_model}" == "1" ]]; then
    [[ -d "${CLAUDE_HOME}/agents" && ! -L "${CLAUDE_HOME}/agents" \
        && "$(file_identity "${CLAUDE_HOME}/agents" \
          2>/dev/null || true)" \
          == "${agents_dir_id}" ]] || return 1
  fi

  OMC_CONFIG_TX_RECOVERING=1
  settle_switch_transaction_metadata \
    || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  omc_tx_current_is_accepted conf "${USER_CONF}" "${state}" \
    "${conf_digest}" "${conf_mode}" \
    || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  if [[ "${settings_state}" != "ignored" ]]; then
    omc_tx_current_is_accepted settings "${settings}" "${settings_state}" \
      "${settings_digest}" "${settings_mode}" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  fi
  while IFS=$'\t' read -r name digest mode; do
    path="${CLAUDE_HOME}/agents/${name}"
    safe_mutation_leaf "${path}" "agent definition" >/dev/null 2>&1 \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
    current_digest="$(file_digest "${path}")" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
    current_mode="$(file_mode_value "${path}")" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
    if [[ "${current_digest}" != "${digest}" \
        || "${current_mode}" != "${mode}" ]]; then
      if ! awk -F '\t' -v wanted="${name}" -v current="${current_digest}" \
          -v current_mode="${current_mode}" \
          '$1 == wanted && $2 == current && $3 == current_mode { found=1 } END { exit(found ? 0 : 1) }' \
          < <(printf '%s' "${agent_intents}"); then
        OMC_CONFIG_TX_RECOVERING=0
        return 1
      fi
    fi
  done < <(printf '%s' "${agents}")
  if [[ "${state}" == "present" ]]; then
    omc_tx_restore_file "${OMC_CONFIG_TX_DIR}/conf-entry" \
      "${USER_CONF}" "${conf_mode}" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  elif [[ -e "${USER_CONF}" || -L "${USER_CONF}" ]]; then
    omc_tx_current_is_accepted conf "${USER_CONF}" absent "" "" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
    rm -f -- "${USER_CONF}" || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  fi
  if [[ "${settings_state}" == "present" ]]; then
    omc_tx_restore_file "${OMC_CONFIG_TX_DIR}/settings-entry" \
      "${settings}" "${settings_mode}" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  elif [[ "${settings_state}" == "absent" ]] \
      && { [[ -e "${settings}" ]] || [[ -L "${settings}" ]]; }; then
    omc_tx_current_is_accepted settings "${settings}" absent "" "" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
    rm -f -- "${settings}" || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  fi
  while IFS=$'\t' read -r name digest mode; do
    omc_tx_restore_file "${OMC_CONFIG_TX_DIR}/agents/${name}" \
      "${CLAUDE_HOME}/agents/${name}" "${mode}" \
      || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  done < <(printf '%s' "${agents}")
  omc_config_test_barrier \
    "${OMC_TEST_CONFIG_RECOVERY_READY_FILE:-}" \
    "${OMC_TEST_CONFIG_RECOVERY_RELEASE_FILE:-}" "${OMC_CONFIG_TX_DIR}" \
    || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  omc_tx_verify_restored_generations \
    || { OMC_CONFIG_TX_RECOVERING=0; return 1; }
  OMC_CONFIG_TX_RECOVERING=0
  retire_omc_config_transaction || return 1
  printf 'omc-config: recovered interrupted config/materialization transaction\n'
}

omc_config_test_barrier() {
  local ready="${1:-}" release="${2:-}" payload="${3:-ready}" attempt=0
  [[ "${OMC_TEST_CONFIG_BARRIER_ENABLE:-0}" == "1" ]] || return 0
  [[ -n "${ready}" && -n "${release}" \
      && "${ready}" == /* && "${release}" == /* ]] || return 1
  printf '%s\n' "${payload}" > "${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 6000 ]] || return 1
    sleep 0.01
  done
}

# Atomic multi-key conf write. Strips any prior occurrence of each key
# (last-write-wins semantics matching install.sh) and appends the new values in
# an exclusive same-directory stage, then rename-replaces the conf. Existing
# mode bits are preserved; a new conf is private (0600). All OMC writers share
# the operation lock acquired by main(), so unrelated concurrent edits cannot
# be lost between the source read and publication.
#
# Within-batch dedup: when the same key appears multiple times in the
# argument list (e.g. `set user gate_level=full gate_level=basic`), only
# the LAST occurrence is appended. Without this, repeated invocations
# would accumulate dead lines in the conf even though the parser's
# `tail -1` resolution masks the user impact.
#
write_conf_atomic() {
  local conf="$1"
  local scope="$2"
  shift 2
  local parent="${conf%/*}" tmp="" source_exists=0 grep_rc=0
  local source_id="" source_digest="" source_mode=""
  local target_digest="" target_mode=""
  if [[ "${scope}" == "project" ]]; then
    safe_project_conf_parent "${conf}" || return 1
  fi
  safe_mutation_leaf "${conf}" "config" || return 1
  mkdir -p "${parent}" || return 1
  if [[ "${scope}" == "project" ]]; then
    safe_project_conf_parent "${conf}" || return 1
  fi
  safe_mutation_leaf "${conf}" "config" || return 1
  [[ -f "${conf}" ]] && source_exists=1
  if [[ "${source_exists}" -eq 1 ]]; then
    source_id="$(file_identity "${conf}")" || return 1
    source_digest="$(file_digest "${conf}")" || return 1
    source_mode="$(file_mode_value "${conf}")" || return 1
  fi
  tmp="$(mktemp "${parent}/.oh-my-claude.conf.omc-config.XXXXXX")" \
    || return 1

  # Walk args, keeping the LAST kv per key. Bash 3-compat (no associative
  # arrays — macOS ships /bin/bash 3.2). Order of preserved keys follows
  # last-occurrence insertion order so the conf stays reasonable to read.
  local -a deduped_keys=()
  local -a deduped_values=()
  local kv key value i found
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    found=-1
    for ((i = 0; i < ${#deduped_keys[@]}; i++)); do
      if [[ "${deduped_keys[$i]}" == "${key}" ]]; then
        found=$i
        break
      fi
    done
    if [[ $found -ge 0 ]]; then
      deduped_values[$found]="${value}"
    else
      deduped_keys+=( "${key}" )
      deduped_values+=( "${value}" )
    fi
  done

  local strip_pattern=""
  local k
  for k in "${deduped_keys[@]}"; do
    if [[ -z "${strip_pattern}" ]]; then
      strip_pattern="^${k}="
    else
      strip_pattern="${strip_pattern}|^${k}="
    fi
  done

  if [[ "${source_exists}" -eq 1 ]]; then
    grep -vE "${strip_pattern}" "${conf}" > "${tmp}" 2>/dev/null \
      || grep_rc=$?
    if [[ "${grep_rc}" -gt 1 ]]; then
      rm -f -- "${tmp}" 2>/dev/null || true
      printf 'omc-config: failed to read existing config safely; no changes published\n' >&2
      return 1
    fi
  else
    : > "${tmp}" || {
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    }
  fi

  for ((i = 0; i < ${#deduped_keys[@]}; i++)); do
    if ! printf '%s=%s\n' "${deduped_keys[$i]}" \
        "${deduped_values[$i]}" >> "${tmp}"; then
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    fi
  done

  if [[ "${source_exists}" -eq 1 ]]; then
    if ! copy_file_mode "${conf}" "${tmp}"; then
      rm -f -- "${tmp}" 2>/dev/null || true
      printf 'omc-config: could not preserve config mode; no changes published\n' >&2
      return 1
    fi
  elif ! chmod 600 "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi

  omc_config_test_barrier \
    "${OMC_TEST_CONFIG_STAGE_READY_FILE:-}" \
    "${OMC_TEST_CONFIG_STAGE_RELEASE_FILE:-}" "${conf}" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  }

  # Revalidate the lexical leaf immediately before publication. Also preserve
  # initial presence/absence so an out-of-band creator/remover cannot be
  # silently overwritten despite the cooperative operation lock.
  if { [[ "${scope}" == "project" ]] \
        && ! safe_project_conf_parent "${conf}"; } \
      || ! safe_mutation_leaf "${conf}" "config" \
      || { [[ "${source_exists}" -eq 1 ]] && [[ ! -f "${conf}" ]]; } \
      || { [[ "${source_exists}" -eq 0 ]] \
        && { [[ -e "${conf}" ]] || [[ -L "${conf}" ]]; }; }; then
    rm -f -- "${tmp}" 2>/dev/null || true
    printf 'omc-config: config target changed during staging; no changes published\n' >&2
    return 1
  fi
  if [[ "${source_exists}" -eq 1 ]] \
      && { [[ "$(file_identity "${conf}" 2>/dev/null || true)" \
            != "${source_id}" ]] \
        || [[ "$(file_digest "${conf}" 2>/dev/null || true)" \
            != "${source_digest}" ]] \
        || [[ "$(file_mode_value "${conf}" 2>/dev/null || true)" \
            != "${source_mode}" ]]; }; then
    rm -f -- "${tmp}" 2>/dev/null || true
    printf 'omc-config: config changed during staging; refusing to overwrite the newer file\n' >&2
    return 1
  fi
  target_digest="$(file_digest "${tmp}")" || { rm -f -- "${tmp}"; return 1; }
  target_mode="$(file_mode_value "${tmp}")" || { rm -f -- "${tmp}"; return 1; }
  if [[ "${conf}" == "${USER_CONF}" ]]; then
    omc_tx_record_intent conf "${tmp}" \
      || { rm -f -- "${tmp}"; return 1; }
  fi
  if ! mv -f -- "${tmp}" "${conf}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  if ! safe_mutation_leaf "${conf}" "config" \
      || [[ ! -f "${conf}" ]] \
      || [[ "$(file_digest "${conf}" 2>/dev/null || true)" \
        != "${target_digest}" ]] \
      || [[ "$(file_mode_value "${conf}" 2>/dev/null || true)" \
        != "${target_mode}" ]]; then
    printf 'omc-config: config publication did not retain the staged generation\n' >&2
    return 1
  fi
}

# Resolve scope label to a conf path. Refuses unknown scopes.
resolve_scope_conf() {
  local scope="$1"
  local conf=""
  case "${scope}" in
    user)    printf '%s' "${USER_CONF}" ;;
    project)
      conf="$(get_project_conf)" || return 1
      safe_project_conf_parent "${conf}" || return 1
      printf '%s' "${conf}"
      ;;
    *)
      printf 'omc-config: unknown scope: %s (expected user|project)\n' "${scope}" >&2
      return 2 ;;
  esac
}

# --- Subcommands ---

cmd_detect_mode() {
  if [[ ! -f "${USER_CONF}" ]]; then
    printf 'not-installed\n'
    return 0
  fi
  local installed_v
  installed_v="$(read_conf_value "${USER_CONF}" installed_version)"
  if [[ -z "${installed_v}" ]]; then
    printf 'not-installed\n'
    return 0
  fi

  local completed
  completed="$(read_conf_value "${USER_CONF}" "${SENTINEL_KEY}")"
  if [[ -z "${completed}" ]]; then
    printf 'setup\n'
    return 0
  fi

  local bundle_v
  bundle_v="$(resolve_bundle_version)"
  if [[ -n "${bundle_v}" && "${bundle_v}" != "unknown" && "${bundle_v}" != "${installed_v}" ]]; then
    local first
    first="$(printf '%s\n%s\n' "${installed_v}" "${bundle_v}" | sort -V | head -1)"
    if [[ "${first}" == "${installed_v}" ]]; then
      printf 'update\n'
      return 0
    fi
  fi
  printf 'change\n'
}

cmd_show() {
  local installed_v bundle_v conf_marker="" proj_conf=""
  installed_v="$(read_conf_value "${USER_CONF}" installed_version)"
  bundle_v="$(resolve_bundle_version)"
  [[ -f "${USER_CONF}" ]] || conf_marker=" (missing)"
  proj_conf="$(find_project_conf || true)"

  printf 'oh-my-claude config\n'
  printf '  user conf:    %s%s\n' \
    "$(diagnostic_preview "${USER_CONF}")" "${conf_marker}"
  if [[ -n "${proj_conf}" ]]; then
    printf '  project conf: %s (overrides user except user-only and monotonic privacy/retention/authorization/notice controls)\n' \
      "$(diagnostic_preview "${proj_conf}")"
    local ignored_project_flags="" denied_flag
    for denied_flag in "${PROJECT_DENIED_FLAGS[@]}"; do
      if [[ -n "$(read_conf_value "${proj_conf}" "${denied_flag}")" ]]; then
        ignored_project_flags="${ignored_project_flags}${ignored_project_flags:+,}${denied_flag}"
      fi
    done
    if [[ -n "${ignored_project_flags}" ]]; then
      printf '  ! ignored project entries for user-only flags: %s\n' "${ignored_project_flags}"
    fi
    if [[ "${ignored_project_flags}" == *model_tier* ]] \
        || [[ "${ignored_project_flags}" == *model_overrides* ]]; then
      printf '  ! project model_tier/model_overrides entries are ignored; model strength and cost remain user-controlled.\n'
    fi
    local project_flag project_raw project_trimmed project_preview
    local project_normalized
    while IFS='|' read -r project_flag _type _default _category _desc; do
      [[ -n "${project_flag}" ]] || continue
      flag_is_project_denied "${project_flag}" && continue
      project_raw="$(read_conf_value "${proj_conf}" "${project_flag}")"
      [[ -n "${project_raw}" ]] || continue
      project_trimmed="$(trim_conf_value "${project_raw}")"
      project_normalized="$(normalize_config_value "${project_flag}" \
        "${project_trimmed}" 2>/dev/null || true)"
      if [[ -z "${project_normalized}" ]]; then
        project_preview="$(diagnostic_preview "${project_raw}")"
        printf '  ! project %s=%s is invalid and ignored; the last valid project row or next authority remains effective.\n' \
          "${project_flag}" "${project_preview}"
      elif ! project_value_is_allowed "${project_flag}" \
          "${project_normalized}"; then
        printf '  ! project %s=%s is a privacy/retention/authorization/notice promotion and is ignored; user/default authority remains effective.\n' \
          "${project_flag}" "${project_normalized}"
      fi
    done < <(emit_known_flags)
  fi
  local env_flag env_name env_raw env_preview
  while IFS='|' read -r env_flag _type _default _category _desc; do
    case "${env_flag}" in ""|model_tier|model_overrides) continue ;; esac
    env_name="$(config_env_name_for_key "${env_flag}")"
    env_raw="${!env_name-}"
    [[ -n "${env_raw}" ]] || continue
    if ! runtime_env_override_value "${env_flag}" >/dev/null 2>&1; then
      env_preview="$(diagnostic_preview "${env_raw}")"
      printf '  ! invalid %s=%s is ignored; saved configuration or the default remains effective.\n' \
        "${env_name}" "${env_preview}"
    fi
  done < <(emit_known_flags)
  if [[ -n "${OMC_MODEL_TIER:-}" ]] \
      && [[ ! "${OMC_MODEL_TIER}" =~ ^(quality|balanced|economy)$ ]]; then
    printf '  ! invalid OMC_MODEL_TIER=%s is ignored; saved user tier or the balanced default remains effective.\n' \
      "$(diagnostic_preview "${OMC_MODEL_TIER}")"
  fi
  if [[ -n "${OMC_MODEL_OVERRIDES:-}" ]] \
      && model_overrides_have_invalid_entries "${OMC_MODEL_OVERRIDES}"; then
    local valid_env_overrides=""
    valid_env_overrides="$(valid_model_overrides_summary \
      "${OMC_MODEL_OVERRIDES}")"
    if [[ -n "${valid_env_overrides}" ]]; then
      printf '  ! OMC_MODEL_OVERRIDES contains invalid entries; rejected pairs are ignored and only the accepted environment pins govern.\n'
    else
      printf '  ! OMC_MODEL_OVERRIDES contains no valid pins and is ignored; saved user pins remain effective.\n'
    fi
  fi
  local saved_model_tier_raw saved_model_overrides_raw valid_saved_overrides
  saved_model_tier_raw="$(read_conf_value "${USER_CONF}" model_tier)"
  if [[ -n "${saved_model_tier_raw}" ]] \
      && ! normalize_config_value model_tier \
        "$(trim_conf_value "${saved_model_tier_raw}")" >/dev/null 2>&1; then
    printf '  ! saved model_tier=%s is invalid and ignored; a valid environment tier or the balanced default remains effective.\n' \
      "$(diagnostic_preview "${saved_model_tier_raw}")"
  fi
  saved_model_overrides_raw="$(read_conf_value \
    "${USER_CONF}" model_overrides)"
  if [[ -n "${saved_model_overrides_raw}" ]] \
      && model_overrides_have_invalid_entries "${saved_model_overrides_raw}"; then
    valid_saved_overrides="$(valid_model_overrides_summary \
      "${saved_model_overrides_raw}")"
    if [[ -n "${valid_saved_overrides}" ]]; then
      printf '  ! saved model_overrides contains invalid entries; rejected pairs are ignored by the live resolver.\n'
    else
      printf '  ! saved model_overrides contains no valid pins and is ignored by the live resolver.\n'
    fi
  fi
  local saved_flag raw_saved_flag trimmed_saved_flag saved_preview
  while IFS='|' read -r saved_flag _type _default _category _desc; do
    case "${saved_flag}" in
      ""|model_tier|model_overrides) continue ;;
    esac
    raw_saved_flag="$(read_conf_value "${USER_CONF}" "${saved_flag}")"
    [[ -n "${raw_saved_flag}" ]] || continue
    trimmed_saved_flag="$(trim_conf_value "${raw_saved_flag}")"
    if ! normalize_config_value "${saved_flag}" "${trimmed_saved_flag}" \
        >/dev/null 2>&1; then
      saved_preview="$(diagnostic_preview "${raw_saved_flag}")"
      printf '  ! saved %s=%s is invalid and ignored; the last valid saved row or next authority remains effective.\n' \
        "${saved_flag}" "${saved_preview}"
    fi
  done < <(emit_known_flags)
  printf '  installed:    %s\n' "${installed_v:-unknown}"
  printf '  bundle:       %s\n' "${bundle_v:-unknown}"
  if [[ -n "${installed_v}" && -n "${bundle_v}" && "${bundle_v}" != "unknown" && "${bundle_v}" != "${installed_v}" ]]; then
    printf '  ! bundle differs from installed — run install.sh in the source repo to sync.\n'
  fi
  printf '\n'
  printf '  %-32s %-10s %-10s  %s\n' "FLAG" "VALUE" "DEFAULT" "DESCRIPTION"
  printf '  %-32s %-10s %-10s  %s\n' "----" "-----" "-------" "-----------"

  local prev_category=""
  local name flag_type default category desc
  while IFS='|' read -r name flag_type default category desc; do
    [[ -z "${name}" ]] && continue
    # Effective value uses environment>allowed-project>user>default
    # precedence (matches load_conf in common.sh).
    local val
    val="$(read_effective_value "${name}")"
    [[ -z "${val}" ]] && val="${default}"
    if [[ "${category}" != "${prev_category}" ]]; then
      printf '  -- %s --\n' "${category}"
      prev_category="${category}"
    fi
    # Build the source annotation so users can see which authority supplied
    # the effective value. Malformed tiers and wholly invalid override sets are
    # ignored; mixed override sets retain [E] precedence for their valid subset.
    local marker="  " source_tag="" project_effective=""
    if [[ -n "${proj_conf}" ]] && ! flag_is_project_denied "${name}"; then
      project_effective="$(read_last_project_allowed_conf_value \
        "${proj_conf}" "${name}")"
    fi
    if runtime_env_override_value "${name}" >/dev/null 2>&1; then
      source_tag=" [E]"
    elif [[ -n "${project_effective}" ]]; then
      source_tag=" [P]"
    elif [[ -n "$(read_effective_user_conf_value "${name}")" ]]; then
      source_tag=" [U]"
    fi
    if [[ -n "${val}" && "${val}" != "${default}" ]]; then
      marker="* "
    fi
    printf '  %s%-30s %-10s %-10s  %s%s\n' "${marker}" "${name}" "${val:-(unset)}" "${default:-(none)}" "${desc}" "${source_tag}"
  done < <(emit_known_flags)

  printf '\n  Marked * = differs from default.  [E]=environment override, [P]=project override, [U]=user setting\n'
}

cmd_list_flags_json() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'omc-config: jq is required for list-flags --json\n' >&2
    return 1
  fi
  local out='[]'
  local name flag_type default category desc
  while IFS='|' read -r name flag_type default category desc; do
    [[ -z "${name}" ]] && continue
    local val
    val="$(read_effective_value "${name}")"
    [[ -z "${val}" ]] && val="${default}"
    out="$(printf '%s' "${out}" | jq \
      --arg name "${name}" \
      --arg type "${flag_type}" \
      --arg default "${default}" \
      --arg category "${category}" \
      --arg desc "${desc}" \
      --arg current "${val}" \
      '. += [{name: $name, type: $type, default: $default, category: $category, description: $desc, current: $current}]')"
  done < <(emit_known_flags)
  printf '%s\n' "${out}"
}

cmd_set() {
  if [[ $# -lt 2 ]]; then
    printf 'omc-config: set requires <scope> and at least one key=value pair\n' >&2
    printf 'usage: omc-config.sh set <user|project> <k=v> [<k=v>...]\n' >&2
    return 2
  fi
  local scope="$1"
  shift
  local conf
  conf="$(resolve_scope_conf "${scope}")"

  # Validate all pairs first; commit only when every value is sound.
  local kv
  for kv in "$@"; do
    validate_kv "${kv}"
  done

  # A project-scoped write here would be worse than a no-op: common.sh would
  # ignore the line, while the historical model_tier side effect below could
  # still rewrite the machine-wide installed agent fallbacks. Reject the whole
  # batch before touching either config or agent files.
  if [[ "${scope}" == "project" ]]; then
    for kv in "$@"; do
      if flag_is_project_denied "${kv%%=*}"; then
        if flag_is_model_user_only "${kv%%=*}"; then
          printf 'omc-config: %s is user-only; use `set user %s` (project config cannot choose model strength or cost)\n' \
            "${kv%%=*}" "${kv}" >&2
        else
          printf 'omc-config: %s is user-only and ignored by project config; use `set user %s`\n' \
            "${kv%%=*}" "${kv}" >&2
        fi
        return 2
      fi
      local project_key="${kv%%=*}" project_value="${kv#*=}"
      project_value="$(trim_conf_value "${project_value}")"
      project_value="$(normalize_config_value "${project_key}" \
        "${project_value}")"
      if ! project_value_is_allowed "${project_key}" "${project_value}"; then
        if flag_is_monotonic_project_capture "${project_key}"; then
          printf 'omc-config: project %s=on cannot re-enable sensitive persistence disabled by user/default authority; use `set user %s` to opt in globally\n' \
            "${project_key}" "${kv}" >&2
        elif flag_is_monotonic_project_ceiling "${project_key}"; then
          printf 'omc-config: project %s=%s cannot increase the user/default authorization ceiling\n' \
            "${project_key}" "${project_value}" >&2
        elif flag_is_monotonic_project_notice "${project_key}"; then
          printf 'omc-config: project %s=%s cannot re-enable a user-disabled machine-wide session notice\n' \
            "${project_key}" "${project_value}" >&2
        else
          printf 'omc-config: project %s=%s cannot increase prompt-bearing resume artifact retention above the user/default cap\n' \
            "${project_key}" "${project_value}" >&2
        fi
        return 2
      fi
    done
  fi

  # Mirror `apply-preset`'s defense-in-depth for both halves of model config.
  # A tier change must rewrite declarations, and an override-only change must
  # reapply the current tier so direct-skill frontmatter matches the live ULW
  # resolver immediately. One switch call handles a batch that changes both.
  local prior_tier="" new_tier=""
  local prior_overrides="" new_overrides="" has_new_overrides=0
  local overrides_changed=0
  local new_style="" effective_env_style=""
  local needs_parent_model=0 needs_parent_settings=0
  for kv in "$@"; do
    case "${kv%%=*}" in
      model_tier) new_tier="${kv#*=}" ;;
      model_overrides)
        new_overrides="${kv#*=}"
        has_new_overrides=1
        ;;
      output_style) new_style="${kv#*=}" ;;
    esac
  done
  if [[ -n "${new_tier}" ]]; then
    prior_tier="$(read_last_runtime_valid_conf_value "${conf}" model_tier)"
  fi
  if (( has_new_overrides == 1 )); then
    prior_overrides="$(read_last_runtime_valid_conf_value "${conf}" model_overrides)"
    if [[ "${new_overrides}" != "${prior_overrides}" ]]; then
      overrides_changed=1
    fi
  fi

  if [[ "${scope}" == "user" ]]; then
    if [[ -n "${new_tier}" || "${has_new_overrides}" -eq 1 ]]; then
      needs_parent_model=1
    fi
    case "${new_style}" in opencode|executive) needs_parent_settings=1 ;; esac
    if [[ "${needs_parent_model}" -eq 1 \
        || "${needs_parent_settings}" -eq 1 ]]; then
      begin_omc_config_transaction \
        "${needs_parent_model}" "${needs_parent_settings}" || {
        printf 'omc-config: could not publish the config/materialization transaction; nothing changed\n' >&2
        return 1
      }
    fi
  fi

  write_conf_atomic "${conf}" "${scope}" "$@"

  local model_apply_tier="" model_apply_reason=""
  if [[ -n "${new_tier}" ]]; then
    if [[ "${new_tier}" != "${prior_tier}" ]]; then
      printf 'omc-config: model_tier changed (%s -> %s); rewriting agents...\n' \
        "${prior_tier:-unset}" "${new_tier}"
    else
      printf 'omc-config: model_tier unchanged at %s; re-materializing agent definitions...\n' \
        "${new_tier}"
    fi
    model_apply_tier="${new_tier}"
    model_apply_reason="tier"
  elif (( has_new_overrides == 1 )); then
    model_apply_tier="$(read_last_runtime_valid_conf_value \
      "${USER_CONF}" model_tier)"
    case "${model_apply_tier}" in
      quality|balanced|economy) ;;
      *) model_apply_tier="balanced" ;;
    esac
    model_apply_reason="overrides"
    if (( overrides_changed == 1 )); then
      printf 'omc-config: model_overrides changed; reapplying %s tier to direct-skill agent fallbacks...\n' \
        "${model_apply_tier}"
    else
      printf 'omc-config: model_overrides unchanged; re-materializing %s tier and saved pins...\n' \
        "${model_apply_tier}"
    fi
  fi

  if [[ -n "${model_apply_tier}" ]]; then
    # A changed quality override can leave an old pin indistinguishable from
    # the tier's own materialized frontmatter (oracle:opus, librarian:haiku,
    # etc.). The switcher reconstructs both shipped declaration classes on
    # every tier, so Economy also repairs legacy flattened installs before
    # pins are reapplied. --force-reconstruct remains a compatibility signal
    # for older installed switchers on Quality transitions.
    local force_reconstruct=0
    if [[ "${model_apply_tier}" == "quality" ]]; then
      if (( has_new_overrides == 1 )) || [[ "${prior_tier}" == "economy" ]]; then
        force_reconstruct=1
      fi
    fi
    if [[ -x "${HOME}/.claude/switch-tier.sh" ]]; then
      if ! cmd_apply_saved_tier "${model_apply_tier}" "${force_reconstruct}"; then
        printf 'omc-config: apply-tier failed after model %s change; rolling back the whole config/materialization batch\n' \
          "${model_apply_reason}" >&2
        return 1
      fi
      omc_tx_record_agent_generations || return 1
    else
      printf 'omc-config: switch-tier.sh is missing; rolling back because saved model config cannot be materialized atomically\n' >&2
      return 1
    fi
    omc_config_test_barrier \
      "${OMC_TEST_CONFIG_POST_MODEL_READY_FILE:-}" \
      "${OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE:-}" "${model_apply_tier}" \
      || return 1
    if [[ "${OMC_TEST_CONFIG_FAIL_AFTER_MODEL:-0}" == "1" ]]; then
      printf 'omc-config: injected failure after model materialization; rolling back the whole batch\n' >&2
      return 1
    fi
    warn_model_env_shadow
  fi

  # v1.31.0 Wave 6 (design-lens F-028): auto-sync settings.json when
  # output_style changes via /omc-config. Pre-Wave-6 the conf flag
  # was written but settings.json was untouched until the next
  # `bash install.sh` run — users picked "executive" and got the old
  # voice the rest of the session, with no signal that a reinstall
  # was required. The explicit write flips the selected style immediately;
  # `output_style=preserve` is the user's no-touch choice.
  # Materialize every explicit persistent write, even when the saved row is
  # unchanged: settings.json may have drifted or a prior sync may have failed.
  # Like model-tier materialization above, this deliberately applies the value
  # the user asked to save. A launch-time OMC_OUTPUT_STYLE still governs a
  # later installer invocation, so call that conflict out explicitly.
  if [[ -n "${new_style}" ]]; then
    if ! sync_output_style_settings "${new_style}"; then
      printf 'omc-config: output_style sync failed; rolling back the whole config/materialization batch\n' >&2
      return 1
    fi
    omc_config_test_barrier \
      "${OMC_TEST_CONFIG_POST_SETTINGS_READY_FILE:-}" \
      "${OMC_TEST_CONFIG_POST_SETTINGS_RELEASE_FILE:-}" "${new_style}" \
      || return 1
    if [[ "${OMC_TEST_CONFIG_FAIL_AFTER_SETTINGS:-0}" == "1" ]]; then
      printf 'omc-config: injected failure after output-style materialization; rolling back the whole batch\n' >&2
      return 1
    fi
    effective_env_style="$(runtime_env_override_value output_style \
      2>/dev/null || true)"
    if [[ -n "${effective_env_style}" \
        && "${effective_env_style}" != "${new_style}" ]]; then
      printf 'omc-config: WARNING: materialized saved output_style=%s now, but active OMC_OUTPUT_STYLE=%s will override it on the next install run in this environment.\n' \
        "${new_style}" "${effective_env_style}" >&2
    fi
  fi
  if [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 ]]; then
    omc_tx_verify_final_generations || return 1
    commit_omc_config_transaction || return 1
    retire_omc_config_transaction || return 1
  fi
  warn_config_env_shadows_for_touched "${scope}" "$@"
  printf 'omc-config: wrote %d key(s) to %s\n' \
    "$#" "$(diagnostic_preview "${conf}")"
}

# v1.31.0 Wave 6 (design-lens F-028): write settings.json's
# outputStyle field from an explicit user choice. Unlike a passive install,
# `/omc-config set user output_style=opencode|executive` is direct authority to
# replace a current custom style. `preserve` is the explicit no-touch choice.
# A missing settings file is created as a minimal JSON object so a successful
# command never falsely claims materialization that did not happen.
# Returns 0 on success, non-zero on failure (the parent transaction rolls back
# both the saved value and every materialized side effect).
sync_output_style_settings() {
  local pref="$1"
  local target_style=""
  case "${pref}" in
    opencode)  target_style="oh-my-claude" ;;
    executive) target_style="executive-brief" ;;
    preserve)  return 0 ;;  # explicit no-op
    *) return 1 ;;
  esac

  local settings_file="${HOME}/.claude/settings.json" settings_exists=0
  local settings_id="" settings_digest="" settings_mode=""
  if [[ -e "${settings_file}" || -L "${settings_file}" ]]; then
    safe_mutation_leaf "${settings_file}" "settings.json" || return 1
    settings_exists=1
    settings_id="$(file_identity "${settings_file}")" || return 1
    settings_digest="$(file_digest "${settings_file}")" || return 1
    settings_mode="$(file_mode_value "${settings_file}")" || return 1
  fi
  mkdir -p "${settings_file%/*}" || return 1

  local tmp render_rc=0 target_digest="" target_mode=""
  tmp="$(mktemp "${settings_file}.tmp.XXXXXX")" || return 1
  if [[ "${settings_exists}" -eq 1 ]]; then
    jq --arg target "${target_style}" '.outputStyle = $target' \
      "${settings_file}" > "${tmp}" 2>/dev/null || render_rc=$?
  else
    jq -n --arg target "${target_style}" '{outputStyle: $target}' \
      > "${tmp}" 2>/dev/null || render_rc=$?
  fi
  if [[ "${render_rc}" -eq 0 ]]; then
    if [[ "${settings_exists}" -eq 1 ]]; then
      copy_file_mode "${settings_file}" "${tmp}" || render_rc=1
    else
      chmod 600 "${tmp}" || render_rc=1
    fi
  fi
  if [[ "${render_rc}" -eq 0 ]]; then
    omc_config_test_barrier \
      "${OMC_TEST_SETTINGS_STAGE_READY_FILE:-}" \
      "${OMC_TEST_SETTINGS_STAGE_RELEASE_FILE:-}" "${settings_file}" \
      || render_rc=1
  fi
  if [[ "${render_rc}" -eq 0 ]]; then
    if ! safe_mutation_leaf "${settings_file}" "settings.json" \
        || { [[ "${settings_exists}" -eq 1 ]] \
          && [[ ! -f "${settings_file}" ]]; } \
        || { [[ "${settings_exists}" -eq 0 ]] \
          && { [[ -e "${settings_file}" ]] \
            || [[ -L "${settings_file}" ]]; }; }; then
      render_rc=1
    elif [[ "${settings_exists}" -eq 1 ]] \
        && { [[ "$(file_identity "${settings_file}" 2>/dev/null || true)" \
              != "${settings_id}" ]] \
          || [[ "$(file_digest "${settings_file}" 2>/dev/null || true)" \
              != "${settings_digest}" ]] \
          || [[ "$(file_mode_value "${settings_file}" 2>/dev/null || true)" \
              != "${settings_mode}" ]]; }; then
      printf 'omc-config: settings.json changed during staging; refusing to overwrite the newer file\n' >&2
      render_rc=1
    else
      target_digest="$(file_digest "${tmp}")" || render_rc=1
      target_mode="$(file_mode_value "${tmp}")" || render_rc=1
      if [[ "${render_rc}" -eq 0 ]]; then
        omc_tx_record_intent settings "${tmp}" || render_rc=1
      fi
    fi
    if [[ "${render_rc}" -eq 0 ]] \
        && mv -f -- "${tmp}" "${settings_file}" \
        && safe_mutation_leaf "${settings_file}" "settings.json" \
        && [[ -f "${settings_file}" ]] \
        && [[ "$(file_digest "${settings_file}" 2>/dev/null || true)" \
          == "${target_digest}" ]] \
        && [[ "$(file_mode_value "${settings_file}" 2>/dev/null || true)" \
          == "${target_mode}" ]]; then
      printf 'omc-config: settings.json outputStyle synced to %s\n' "${target_style}"
      return 0
    fi
  fi
  rm -f -- "${tmp}" 2>/dev/null
  return 1
}

cmd_apply_preset() {
  if [[ $# -ne 2 ]]; then
    printf 'omc-config: apply-preset requires <scope> <profile>\n' >&2
    printf 'usage: omc-config.sh apply-preset <user|project> <maximum|zero-steering|balanced|minimal>\n' >&2
    return 2
  fi
  local scope="$1" profile="$2"
  local conf
  conf="$(resolve_scope_conf "${scope}")"

  local pairs=()
  local omitted_user_only=()
  local omitted_policy_promotions=()
  local line key value
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    key="${line%%=*}"
    if [[ "${scope}" == "project" ]] && flag_is_project_denied "${key}"; then
      omitted_user_only+=( "${key}" )
      continue
    fi
    value="${line#*=}"
    if [[ "${scope}" == "project" ]] \
        && ! project_value_is_allowed "${key}" "${value}"; then
      omitted_policy_promotions+=( "${key}" )
      continue
    fi
    pairs+=( "${line}" )
  done < <(emit_preset "${profile}")

  if [[ ${#pairs[@]} -eq 0 ]]; then
    printf 'omc-config: preset %s produced no entries\n' "${profile}" >&2
    return 2
  fi

  local kv
  for kv in "${pairs[@]}"; do
    validate_kv "${kv}"
  done

  # Capture the prior model_tier (from the same scope's conf) BEFORE the
  # write so we can detect whether the preset is changing the tier. If it
  # is, the helper invokes `apply-tier` itself — defense-in-depth for the
  # case where the SKILL flow's "Step 5a — invoke apply-tier when tier
  # changed" instruction is skipped. Without this, the conf could claim
  # `model_tier=quality` while every agent file still says `sonnet`.
  local prior_tier new_tier
  prior_tier="$(read_last_runtime_valid_conf_value "${conf}" model_tier)"
  new_tier=""
  for kv in "${pairs[@]}"; do
    if [[ "${kv%%=*}" == "model_tier" ]]; then
      new_tier="${kv#*=}"
      break
    fi
  done

  if [[ "${scope}" == "user" && -n "${new_tier}" ]]; then
    begin_omc_config_transaction 1 0 || {
      printf 'omc-config: could not publish the preset/materialization transaction; nothing changed\n' >&2
      return 1
    }
  fi

  write_conf_atomic "${conf}" "${scope}" "${pairs[@]}"
  if [[ ${#omitted_user_only[@]} -gt 0 ]]; then
    printf 'omc-config: project scope preserved user-wide restricted settings; omitted user-only preset key(s): %s\n' \
      "$(IFS=,; printf '%s' "${omitted_user_only[*]}")"
    if printf '%s\n' "${omitted_user_only[@]}" | grep -qE '^model_(tier|overrides)$'; then
      printf 'omc-config: model strength and cost are unchanged at the active user/environment setting.\n'
    fi
  fi
  if [[ ${#omitted_policy_promotions[@]} -gt 0 ]]; then
    printf 'omc-config: project scope preserved stricter user/default privacy and authorization; omitted capture/retention/authorization promotion(s): %s\n' \
      "$(IFS=,; printf '%s' "${omitted_policy_promotions[*]}")"
  fi

  # Every explicit user preset re-materializes its tier. This repairs drifted
  # installed frontmatter even when the saved enum was already unchanged. The
  # parent transaction keeps the config and materialized definitions atomic.
  if [[ -n "${new_tier}" ]]; then
    if [[ "${new_tier}" != "${prior_tier}" ]]; then
      printf 'omc-config: model_tier changed (%s -> %s); rewriting agents...\n' \
        "${prior_tier:-unset}" "${new_tier}"
    else
      printf 'omc-config: model_tier unchanged at %s; re-materializing agent definitions...\n' \
        "${new_tier}"
    fi
    if [[ -x "${HOME}/.claude/switch-tier.sh" ]]; then
      # The preset write above has already changed conf, so switch-tier cannot
      # infer the old materialized tier from disk. Economy erased the shipped
      # inherit split, and a surviving `agent:inherit` override can otherwise
      # make the new Quality state look canonical. Pass the captured prior tier
      # through as an explicit reconstruction decision.
      local force_reconstruct=0
      if [[ "${new_tier}" == "quality" && "${prior_tier}" == "economy" ]]; then
        force_reconstruct=1
      fi
      if ! cmd_apply_saved_tier "${new_tier}" "${force_reconstruct}"; then
        printf 'omc-config: apply-tier failed; rolling back the whole preset/materialization batch\n' >&2
        return 1
      fi
      omc_tx_record_agent_generations || return 1
    else
      printf 'omc-config: switch-tier.sh is missing; rolling back because the preset tier cannot be materialized atomically\n' >&2
      return 1
    fi
    omc_config_test_barrier \
      "${OMC_TEST_CONFIG_POST_MODEL_READY_FILE:-}" \
      "${OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE:-}" "${new_tier}" \
      || return 1
    if [[ "${OMC_TEST_CONFIG_FAIL_AFTER_MODEL:-0}" == "1" ]]; then
      printf 'omc-config: injected failure after preset model materialization; rolling back the whole batch\n' >&2
      return 1
    fi
    warn_model_env_shadow
  fi
  if [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 ]]; then
    omc_tx_verify_final_generations || return 1
    commit_omc_config_transaction || return 1
    retire_omc_config_transaction || return 1
  fi
  warn_config_env_shadows_for_touched "${scope}" "${pairs[@]}"
  printf 'omc-config: applied preset "%s" (%d keys) to %s\n' \
    "${profile}" "${#pairs[@]}" "$(diagnostic_preview "${conf}")"
}

cmd_mark_completed() {
  # Sentinel is "this user has been through the wizard once" — a
  # per-machine flag, not per-project. `detect-mode` only reads
  # USER_CONF for this key, so writing it to the project conf would
  # leave the user stuck in `setup` mode forever. Ignore any scope
  # argument and always stamp USER_CONF; the scope arg is preserved
  # for backward-compat with callers that pass it (the SKILL flow did
  # before the fix landed) but the scope no longer changes the path.
  local _scope_ignored="${1:-user}"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_conf_atomic "${USER_CONF}" user "${SENTINEL_KEY}=${stamp}"
  printf 'omc-config: stamped %s=%s in %s (always user scope)\n' \
    "${SENTINEL_KEY}" "${stamp}" "$(diagnostic_preview "${USER_CONF}")"
}

cmd_apply_tier() {
  local tier="${1:-}"
  local force_reconstruct="${2:-0}"
  local internal_skip_persist="${3:-0}"
  if [[ -z "${tier}" ]]; then
    printf 'omc-config: apply-tier requires <quality|balanced|economy>\n' >&2
    return 2
  fi
  if [[ ! "${tier}" =~ ^(quality|balanced|economy)$ ]]; then
    printf 'omc-config: tier must be quality|balanced|economy (got: %s)\n' "${tier}" >&2
    return 2
  fi
  case "${force_reconstruct}" in
    0|1) ;;
    *)
      printf 'omc-config: internal force-reconstruct value must be 0|1 (got: %s)\n' \
        "${force_reconstruct}" >&2
      return 2
      ;;
  esac
  case "${internal_skip_persist}" in 0|1) ;; *) return 2 ;; esac
  local switcher="${HOME}/.claude/switch-tier.sh"
  if [[ ! -x "${switcher}" ]]; then
    printf 'omc-config: switch-tier.sh not found at %s\n' "${switcher}" >&2
    printf '            Re-run install.sh to refresh the bundle, then retry.\n' >&2
    return 1
  fi
  unset OMC_SWITCH_SKIP_CONF_PERSIST OMC_SWITCH_PARENT_TX_CAPABILITY
  if [[ "${internal_skip_persist}" == "1" ]]; then
    [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 \
        && -f "${OMC_CONFIG_TX_DIR}/switch-capability" \
        && ! -L "${OMC_CONFIG_TX_DIR}/switch-capability" ]] || return 1
    omc_tx_read_line "${OMC_CONFIG_TX_DIR}/switch-capability" || return 1
    OMC_SWITCH_PARENT_TX_CAPABILITY="${OMC_TX_TEXT_SNAPSHOT}"
    export OMC_SWITCH_SKIP_CONF_PERSIST=1
    export OMC_SWITCH_PARENT_TX_CAPABILITY
  fi
  if [[ "${force_reconstruct}" == "1" ]]; then
    bash "${switcher}" "${tier}" --force-reconstruct
  else
    bash "${switcher}" "${tier}"
  fi
}

# Persistent `set user` / user-preset writes materialize the value just saved
# to disk. A launch-time environment override still governs live routing, but
# must not silently rewrite direct-skill frontmatter to a different value than
# the persistent config the user requested.
cmd_apply_saved_tier() {
  (
    unset OMC_MODEL_TIER OMC_MODEL_OVERRIDES
    cmd_apply_tier "$@" 1
  )
}

cmd_install_watchdog() {
  local installer="${HOME}/.claude/install-resume-watchdog.sh"
  if [[ ! -x "${installer}" ]]; then
    printf 'omc-config: watchdog installer not found at %s\n' "${installer}" >&2
    printf '            Re-run install.sh to refresh the bundle, then retry.\n' >&2
    return 1
  fi
  bash "${installer}"
}

usage() {
  cat <<'EOF'
omc-config.sh — backend for /omc-config skill.

Subcommands:
  detect-mode                          Print setup|update|change|not-installed
  show                                 Pretty-print current effective config
  list-flags                           Emit known flags as JSON (for skill)
  set <user|project> <k=v>...          Atomic write of one or more keys
  apply-preset <user|project> <name>   Apply preset (maximum|zero-steering|balanced|minimal)
  presets <name>                       Print preset key=value pairs to stdout
  apply-tier <quality|balanced|economy>  Run switch-tier.sh (rewrites agent files)
  recover-only                         Settle durable config/tier transactions only
  install-watchdog                     Run install-resume-watchdog.sh
  mark-completed [user|project]        Stamp omc_config_completed=<ISO date>

Conventions:
  user scope    -> ~/.claude/oh-my-claude.conf
  project scope -> $(pwd)/.claude/oh-my-claude.conf
                   (security/persistence/model/statusline authority is user-only)

Exit codes:
  0 success | 1 runtime failure | 2 invalid invocation
EOF
}

omc_config_exit_cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "${OMC_CONFIG_TX_ACTIVE}" -eq 1 ]]; then
    if ! recover_omc_config_transaction; then
      printf 'omc-config: durable rollback did not complete; transaction retained at %s\n' \
        "${OMC_CONFIG_TX_DIR}" >&2
      rc=1
    fi
  fi
  release_operation_lock
  exit "${rc}"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    set|apply-preset|apply-tier|recover-only|install-watchdog|mark-completed)
      trap 'omc_config_exit_cleanup' EXIT
      acquire_operation_lock || return 1
      sweep_omc_config_transaction_orphans || {
        printf 'omc-config: could not safely settle orphan config transaction metadata\n' >&2
        return 1
      }
      recover_omc_config_transaction || {
        printf 'omc-config: could not recover the prior config/materialization transaction\n' >&2
        return 1
      }
      if ! settle_switch_transaction_metadata; then
        printf 'omc-config: could not recover the prior model-tier transaction\n' >&2
        return 1
      fi
      ;;
  esac
  case "${cmd}" in
    detect-mode)      cmd_detect_mode ;;
    show)             cmd_show ;;
    list-flags)       cmd_list_flags_json ;;
    set)              cmd_set "$@" ;;
    apply-preset)     cmd_apply_preset "$@" ;;
    presets)          emit_preset "${1:-}" ;;
    apply-tier)       cmd_apply_tier "${1:-}" ;;
    recover-only)     : ;;
    install-watchdog) cmd_install_watchdog ;;
    mark-completed)   cmd_mark_completed "$@" ;;
    ""|-h|--help)     usage ;;
    *)
      printf 'omc-config: unknown subcommand: %s\n' "${cmd}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
