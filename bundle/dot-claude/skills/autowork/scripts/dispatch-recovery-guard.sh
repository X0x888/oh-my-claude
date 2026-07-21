#!/usr/bin/env bash

# Universal PreToolUse fence for interrupted Agent admission and dormant
# resume sources. This stays separate from intent/mutation classification
# because Read, Grep, Agent, browser, and future tool names must all stop on
# the same causal gap or logical-ownership boundary.

set -euo pipefail
umask 077

_omc_guard_state_snapshot=""
_omc_guard_state_token=""
_omc_guard_stat_bin=""
_omc_guard_cksum_bin=""
_omc_guard_dd_bin=""
_omc_guard_mktemp_bin=""
_omc_guard_rm_bin=""
_omc_guard_sleep_bin=""
_omc_guard_cleanup_snapshot() {
  if [[ -n "${_omc_guard_state_snapshot:-}" ]]; then
    if [[ -n "${_omc_guard_rm_bin:-}" ]]; then
      "${_omc_guard_rm_bin}" -f -- "${_omc_guard_state_snapshot}" \
        2>/dev/null || true
    fi
    _omc_guard_state_snapshot=""
  fi
}
trap _omc_guard_cleanup_snapshot EXIT

_omc_guard_static_deny() {
  case "${1:-malformed}" in
    timeout)
      builtin printf '%s\n' \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[Lifecycle input] The PreTool payload did not reach EOF before the bounded guard timeout, so a partial input was not trusted."}}'
      ;;
    oversized)
      builtin printf '%s\n' \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[Lifecycle input] The PreTool payload exceeded the bounded guard input limit, so no session identity or reset authority was trusted."}}'
      ;;
    parser)
      builtin printf '%s\n' \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[Lifecycle input] The trusted JSON parser was unavailable or failed its integrity check, so no session identity or reset authority was trusted."}}'
      ;;
    state)
      builtin printf '%s\n' \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[Lifecycle input] Lifecycle state could not be parsed authoritatively, so dormant-session and reset authority were not trusted."}}'
      ;;
    *)
      builtin printf '%s\n' \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[Lifecycle input] The PreTool payload was not a complete valid top-level hook object, so no session identity or reset authority was trusted."}}'
      ;;
  esac
  exit 0
}

# Read stdin before the ordinary global-marker fast path because a completed
# resume transfer can outlive that shared marker. Bash's timed NUL-delimited
# read preserves the hook-wide partial-pipe timeout without executing anything
# from project PATH; `-n` also caps hostile/unclosed input. Hook JSON contains
# no NUL bytes. Oversize input fails closed instead of parsing a truncated
# top-level identity.
HOOK_JSON=""
_omc_guard_read_timeout="${OMC_HOOK_STDIN_TIMEOUT_S:-5}"
_omc_guard_max_bytes="${OMC_HOOK_STDIN_MAX_BYTES:-1048576}"
if [[ ! "${_omc_guard_read_timeout}" =~ ^[1-9][0-9]?$ \
    || "${_omc_guard_read_timeout}" -gt 30 ]]; then
  _omc_guard_read_timeout=5
fi
if [[ ! "${_omc_guard_max_bytes}" =~ ^[1-9][0-9]{0,7}$ \
    || "${_omc_guard_max_bytes}" -gt 16777216 ]]; then
  _omc_guard_max_bytes=1048576
fi
_omc_guard_read_limit=$((_omc_guard_max_bytes + 1))
# `read -n` and `${#...}` are character-oriented under a UTF-8 locale. Pin
# this hook process to the byte locale so the advertised cap cannot expand by
# several times for multibyte input. The hook is a child process, so this does
# not mutate the caller's locale.
export LC_ALL=C
_omc_guard_read_status=0
if IFS='' read -r -d '' -n "${_omc_guard_read_limit}" \
    -t "${_omc_guard_read_timeout}" HOOK_JSON 2>/dev/null; then
  _omc_guard_read_status=0
else
  _omc_guard_read_status=$?
fi
if (( ${#HOOK_JSON} > _omc_guard_max_bytes )); then
  _omc_guard_static_deny oversized
fi
if [[ "${_omc_guard_read_status}" -gt 128 ]]; then
  _omc_guard_static_deny timeout
fi
# A normal pipe/file closes at EOF and makes `read -d ''` return 1. Success
# before the byte limit therefore means an unexpected NUL delimiter; any other
# status is likewise not proof of a complete EOF-delimited payload.
[[ "${_omc_guard_read_status}" -eq 1 ]] \
  || _omc_guard_static_deny malformed
unset _omc_guard_read_timeout _omc_guard_max_bytes _omc_guard_read_limit
unset _omc_guard_read_status

# Imported functions and aliases resolve before PATH. The guard never delegates
# parsing to either one, even after common.sh pins the observer path.
unset -f jq 2>/dev/null || true
unalias jq 2>/dev/null || true

# Select an absolute parser from system bins or an immutable Nix-store bin.
# Merely being executable is insufficient: require an exact probe result before
# the parser sees hook or state authority. The test-only failure mode can only
# force this guard closed; it cannot substitute a parser or admit a tool.
_omc_guard_trusted_jq=""
if [[ "${OMC_TEST_DISPATCH_GUARD_JQ_FAILURE:-}" == "broken" ]]; then
  # Exercise the real probe-failure path with a command that cannot parse or
  # emit the expected sentinel. This test seam is denial-only by construction.
  _omc_guard_trusted_jq="/bin/false"
elif [[ "${OMC_TEST_DISPATCH_GUARD_JQ_FAILURE:-}" != "missing" ]]; then
  for _omc_guard_jq_candidate in \
      /usr/bin/jq /bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq \
      /run/current-system/sw/bin/jq \
      "${HOME}"/.nix-profile/bin/jq \
      "${HOME}"/.local/state/nix/profiles/*/bin/jq \
      /etc/profiles/per-user/*/bin/jq; do
    [[ -x "${_omc_guard_jq_candidate}" \
        && ! -d "${_omc_guard_jq_candidate}" ]] || continue
    case "${_omc_guard_jq_candidate}" in
      /usr/bin/jq|/bin/jq|/opt/homebrew/bin/jq|/usr/local/bin/jq)
        _omc_guard_trusted_jq="${_omc_guard_jq_candidate}"
        ;;
      *)
        _omc_guard_jq_dir="${_omc_guard_jq_candidate%/*}"
        _omc_guard_jq_dir="$(
          builtin cd "${_omc_guard_jq_dir}" 2>/dev/null \
            && builtin pwd -P
        )" || continue
        case "${_omc_guard_jq_dir}" in
          /nix/store/*/bin)
            _omc_guard_store_object="${_omc_guard_jq_dir#/nix/store/}"
            _omc_guard_store_object="${_omc_guard_store_object%/bin}"
            [[ -n "${_omc_guard_store_object}" \
                && "${_omc_guard_store_object}" != */* ]] || continue
            _omc_guard_trusted_jq="${_omc_guard_jq_dir}/jq"
            ;;
          *) continue ;;
        esac
        ;;
    esac
    break
  done
fi
[[ -n "${_omc_guard_trusted_jq}" ]] || _omc_guard_static_deny parser

_omc_guard_jq_probe=""
if ! _omc_guard_jq_probe="$(
      "${_omc_guard_trusted_jq}" -r '
        if type == "object" and .probe == "ok"
          then "omc-jq-ok" else error("probe") end
      ' <<<'{"probe":"ok"}' 2>/dev/null
    )" \
    || [[ "${_omc_guard_jq_probe}" != "omc-jq-ok" ]]; then
  _omc_guard_static_deny parser
fi

# Resolve the fixed utilities used by the authority snapshot without consulting
# caller-shadowable PATH entries. Standard system locations are accepted
# directly; profile paths are accepted only after their directory
# resolves into one immutable Nix-store object. Keep this lazy-fail: sessions
# with no addressed state still take the no-I/O fast path on unusual hosts.
_omc_guard_resolve_system_tool() {
  local tool="${1:-}" candidate="" candidate_dir="" store_object=""
  [[ "${tool}" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  for candidate in \
      "/usr/bin/${tool}" "/bin/${tool}" \
      "/run/current-system/sw/bin/${tool}" \
      "/nix/var/nix/profiles/default/bin/${tool}" \
      "${HOME}/.nix-profile/bin/${tool}" \
      "${HOME}"/.local/state/nix/profiles/*/bin/"${tool}" \
      /etc/profiles/per-user/*/bin/"${tool}"; do
    [[ -x "${candidate}" && ! -d "${candidate}" ]] || continue
    case "${candidate}" in
      "/usr/bin/${tool}"|"/bin/${tool}")
        builtin printf '%s' "${candidate}"
        return 0
        ;;
      *)
        candidate_dir="${candidate%/*}"
        candidate_dir="$(
          builtin cd "${candidate_dir}" 2>/dev/null \
            && builtin pwd -P
        )" || continue
        case "${candidate_dir}" in
          /nix/store/*/bin)
            store_object="${candidate_dir#/nix/store/}"
            store_object="${store_object%/bin}"
            [[ -n "${store_object}" && "${store_object}" != */* \
                && -x "${candidate_dir}/${tool}" \
                && ! -d "${candidate_dir}/${tool}" ]] || continue
            builtin printf '%s' "${candidate_dir}/${tool}"
            return 0
            ;;
        esac
        ;;
    esac
  done
  return 1
}

_omc_guard_stat_bin="$(_omc_guard_resolve_system_tool stat || true)"
_omc_guard_cksum_bin="$(_omc_guard_resolve_system_tool cksum || true)"
_omc_guard_dd_bin="$(_omc_guard_resolve_system_tool dd || true)"
_omc_guard_mktemp_bin="$(_omc_guard_resolve_system_tool mktemp || true)"
_omc_guard_rm_bin="$(_omc_guard_resolve_system_tool rm || true)"
_omc_guard_sleep_bin="$(_omc_guard_resolve_system_tool sleep || true)"

_omc_guard_snapshot_tools_are_available() {
  [[ -n "${_omc_guard_stat_bin}" && -x "${_omc_guard_stat_bin}" \
      && -n "${_omc_guard_cksum_bin}" && -x "${_omc_guard_cksum_bin}" \
      && -n "${_omc_guard_dd_bin}" && -x "${_omc_guard_dd_bin}" \
      && -n "${_omc_guard_mktemp_bin}" && -x "${_omc_guard_mktemp_bin}" \
      && -n "${_omc_guard_rm_bin}" && -x "${_omc_guard_rm_bin}" \
      && -n "${_omc_guard_sleep_bin}" && -x "${_omc_guard_sleep_bin}" ]]
}

# Lifecycle state is authority-bearing input on every PreTool call. Snapshot at
# most 1 MiB through fixed system tools, verify the source identity+digest on
# both sides of the copy, and parse only the stable private snapshot. This
# prevents a large/corrupt state from wedging the hook and prevents an atomic
# writer from changing transfer/init authority between the two field reads.
_omc_guard_state_max_bytes=1048576
_omc_guard_stat_tuple() {
  local path="${1:-}" value=""
  [[ -n "${_omc_guard_stat_bin}" ]] || return 1
  value="$(
    "${_omc_guard_stat_bin}" -f '%d:%i:%z' "${path}" 2>/dev/null || true
  )"
  if [[ "${value}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
    builtin printf '%s' "${value}"
    return 0
  fi
  value="$(
    "${_omc_guard_stat_bin}" -c '%d:%i:%s' "${path}" 2>/dev/null || true
  )"
  [[ "${value}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  builtin printf '%s' "${value}"
}

_omc_guard_file_digest() {
  local path="${1:-}" value="" sum="" bytes=""
  [[ -n "${_omc_guard_cksum_bin}" ]] || return 1
  value="$("${_omc_guard_cksum_bin}" <"${path}" 2>/dev/null)" \
    || return 1
  read -r sum bytes _ <<<"${value}"
  [[ "${sum}" =~ ^[0-9]+$ && "${bytes}" =~ ^[0-9]+$ ]] || return 1
  builtin printf '%s:%s' "${sum}" "${bytes}"
}

_omc_guard_bounded_copy() {
  local source="${1:-}" destination="${2:-}" copied_tuple=""
  local dd_pid="" timer_pid="" dd_rc=0 copy_timeout=2
  [[ -n "${_omc_guard_dd_bin}" && -n "${_omc_guard_sleep_bin}" ]] \
    || return 1
  if [[ "${OMC_TEST_DISPATCH_GUARD_COPY_TIMEOUT_S:-}" == "1" ]]; then
    copy_timeout=1
  fi
  # One max+1-byte block gives the copy a physical I/O ceiling even if the
  # pathname is replaced or grows after its initial lstat. A later identity
  # check rejects any pathname generation other than the one first observed.
  # Opening a raced FIFO can block before dd reads a byte, so a fixed pinned
  # sleep process terminates that copy as well. The timer trap reaps its sleep
  # child when the normal fast copy wins, avoiding one orphan per hook call.
  "${_omc_guard_dd_bin}" if="${source}" of="${destination}" \
    bs="$((_omc_guard_state_max_bytes + 1))" count=1 2>/dev/null &
  dd_pid=$!
  (
    timer_sleep_pid=""
    trap '
      if [[ -n "${timer_sleep_pid:-}" ]]; then
        builtin kill -TERM "${timer_sleep_pid}" 2>/dev/null || true
        wait "${timer_sleep_pid}" 2>/dev/null || true
      fi
      exit 0
    ' HUP INT TERM
    "${_omc_guard_sleep_bin}" "${copy_timeout}" &
    timer_sleep_pid=$!
    wait "${timer_sleep_pid}" 2>/dev/null || exit 0
    timer_sleep_pid=""
    builtin kill -TERM "${dd_pid}" 2>/dev/null || true
  ) &
  timer_pid=$!
  if wait "${dd_pid}"; then
    dd_rc=0
  else
    dd_rc=$?
  fi
  builtin kill -TERM "${timer_pid}" 2>/dev/null || true
  wait "${timer_pid}" 2>/dev/null || true
  [[ "${dd_rc}" -eq 0 ]] || return 1
  copied_tuple="$(_omc_guard_stat_tuple "${destination}")" || return 1
  [[ "${copied_tuple##*:}" =~ ^[0-9]+$ ]] || return 1
  (( ${copied_tuple##*:} <= _omc_guard_state_max_bytes ))
}

_omc_guard_test_copy_barrier() {
  local ready="${OMC_TEST_DISPATCH_GUARD_COPY_READY_FILE:-}"
  local release="${OMC_TEST_DISPATCH_GUARD_COPY_RELEASE_FILE:-}"
  [[ -n "${ready}" || -n "${release}" ]] || return 0
  [[ "${ready}" == /* && "${release}" == /* \
      && ! -L "${ready}" && ! -L "${release}" \
      && ( ! -e "${ready}" || -f "${ready}" ) \
      && ( ! -e "${release}" || -f "${release}" ) \
      && -n "${_omc_guard_sleep_bin}" ]] || return 1
  : >"${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    "${_omc_guard_sleep_bin}" 0.01
  done
  [[ -f "${release}" && ! -L "${release}" ]]
}

_omc_guard_snapshot_authoritative_state() {
  local source="${1:-}" before_tuple="" after_tuple=""
  local snapshot_tuple="" snapshot_digest="" source_size=""
  _omc_guard_cleanup_snapshot
  _omc_guard_snapshot_tools_are_available || return 1
  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  before_tuple="$(_omc_guard_stat_tuple "${source}")" || return 1
  source_size="${before_tuple##*:}"
  [[ "${source_size}" =~ ^[0-9]+$ ]] || return 1
  (( source_size <= _omc_guard_state_max_bytes )) || return 1
  _omc_guard_state_snapshot="$("${_omc_guard_mktemp_bin}" \
    /tmp/omc-dispatch-state.XXXXXX)" || return 1
  _omc_guard_test_copy_barrier || {
    _omc_guard_cleanup_snapshot
    return 1
  }
  if ! _omc_guard_bounded_copy \
      "${source}" "${_omc_guard_state_snapshot}" \
      || [[ ! -f "${_omc_guard_state_snapshot}" \
        || -L "${_omc_guard_state_snapshot}" ]]; then
    _omc_guard_cleanup_snapshot
    return 1
  fi
  after_tuple="$(_omc_guard_stat_tuple "${source}")" || {
    _omc_guard_cleanup_snapshot
    return 1
  }
  snapshot_tuple="$(_omc_guard_stat_tuple \
    "${_omc_guard_state_snapshot}")" || {
      _omc_guard_cleanup_snapshot
      return 1
    }
  snapshot_digest="$(_omc_guard_file_digest \
    "${_omc_guard_state_snapshot}")" || {
      _omc_guard_cleanup_snapshot
      return 1
    }
  [[ "${before_tuple}" == "${after_tuple}" \
      && "${snapshot_tuple##*:}" == "${source_size}" \
      && "${snapshot_digest##*:}" == "${source_size}" ]] || {
    _omc_guard_cleanup_snapshot
    return 1
  }
  _omc_guard_state_token="${before_tuple}|${snapshot_digest}"
}

_omc_guard_state_generation_is_current() {
  local source="${1:-}" tuple="" after_tuple="" digest=""
  local expected_tuple="" expected_digest="" verify=""
  _omc_guard_snapshot_tools_are_available || return 1
  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  tuple="$(_omc_guard_stat_tuple "${source}")" || return 1
  expected_tuple="${_omc_guard_state_token%%|*}"
  expected_digest="${_omc_guard_state_token#*|}"
  [[ "${tuple}" == "${expected_tuple}" ]] || return 1
  verify="$("${_omc_guard_mktemp_bin}" \
    /tmp/omc-dispatch-verify.XXXXXX)" || return 1
  if ! _omc_guard_bounded_copy "${source}" "${verify}"; then
    "${_omc_guard_rm_bin}" -f -- "${verify}" 2>/dev/null || true
    return 1
  fi
  after_tuple="$(_omc_guard_stat_tuple "${source}")" || {
    "${_omc_guard_rm_bin}" -f -- "${verify}" 2>/dev/null || true
    return 1
  }
  digest="$(_omc_guard_file_digest "${verify}")" || {
    "${_omc_guard_rm_bin}" -f -- "${verify}" 2>/dev/null || true
    return 1
  }
  "${_omc_guard_rm_bin}" -f -- "${verify}" 2>/dev/null || return 1
  [[ "${after_tuple}" == "${expected_tuple}" \
      && "${digest}" == "${expected_digest}" ]]
}

_omc_guard_test_snapshot_barrier() {
  local ready="${OMC_TEST_DISPATCH_GUARD_STATE_READY_FILE:-}"
  local release="${OMC_TEST_DISPATCH_GUARD_STATE_RELEASE_FILE:-}"
  [[ -n "${ready}" || -n "${release}" ]] || return 0
  [[ "${ready}" == /* && "${release}" == /* \
      && ! -L "${ready}" && ! -L "${release}" \
      && ( ! -e "${ready}" || -f "${ready}" ) \
      && ( ! -e "${release}" || -f "${release}" ) \
      && -n "${_omc_guard_sleep_bin}" ]] || return 1
  : >"${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    "${_omc_guard_sleep_bin}" 0.01
  done
  [[ -f "${release}" && ! -L "${release}" ]]
}

# Classify the resume-initialization generation without trusting tolerant state
# readers. Absent lifecycle fields are the settled legacy shape; when either
# initialization coordinate exists, both must exist, both must be strings, and
# both must be empty or form one valid active pair. A present transfer field is
# likewise string-typed. Nulls, partial pairs, and malformed active identities
# are lifecycle corruption and fail closed.
_omc_guard_resume_initialization_class() {
  "${_omc_guard_trusted_jq}" -r '
    def absent_or_string($key):
      (has($key) | not) or (.[$key] | type) == "string";
    def valid_sid:
      type == "string"
      and (length >= 1 and length <= 128)
      and test("^[A-Za-z0-9_.-]+$")
      and (contains("..") | not)
      and (test("^\\.+$") | not);
    if type != "object"
        or (absent_or_string("resume_initialization_txn_id") | not)
        or (absent_or_string("resume_initialization_source_id") | not)
        or (absent_or_string("resume_transferred_to") | not)
        or (((has("resume_initialization_txn_id")
              and has("resume_initialization_source_id"))
            or
            ((has("resume_initialization_txn_id") | not)
              and (has("resume_initialization_source_id") | not))) | not)
        or ((((.resume_initialization_txn_id // "") == "")
              == ((.resume_initialization_source_id // "") == "")) | not)
      then error("invalid resume lifecycle fields")
    elif (.resume_initialization_txn_id // "") != "" then
      if ((.resume_initialization_txn_id
            | test("^[A-Za-z0-9][A-Za-z0-9._:-]{15,159}$"))
          and (.resume_initialization_source_id | valid_sid))
        then "active" else error("invalid resume initialization identity") end
    else "none" end
  ' "${1:-}" 2>/dev/null
}

# Validate the entire top-level hook envelope before consulting even the
# process-wide marker. A regex fallback cannot distinguish an escaped nested
# decoy from authority-bearing fields, and a syntactically complete prefix on
# an open pipe is not an EOF-complete payload.
_omc_guard_payload_probe=""
if ! _omc_guard_payload_probe="$(
    "${_omc_guard_trusted_jq}" -r '
      if type == "object"
          and has("session_id") and (.session_id | type) == "string"
          and has("tool_name") and (.tool_name | type) == "string"
          and has("tool_input") and (.tool_input | type) == "object"
          and .hook_event_name == "PreToolUse"
        then "omc-hook-ok" else error("invalid hook envelope") end
    ' <<<"${HOOK_JSON}" 2>/dev/null
  )" \
    || [[ "${_omc_guard_payload_probe}" != "omc-hook-ok" ]]; then
  _omc_guard_static_deny malformed
fi

if ! _omc_guard_sid="$(
    "${_omc_guard_trusted_jq}" -er '
      .session_id
      | select(type == "string"
          and length >= 1 and length <= 128
          and test("^[a-zA-Z0-9_.-]+$")
          and (contains("..") | not)
          and (test("^\\.+$") | not))
    ' \
      <<<"${HOOK_JSON}" 2>/dev/null
  )"; then
  _omc_guard_static_deny parser
fi
[[ "${_omc_guard_sid}" =~ ^[a-zA-Z0-9_.-]{1,128}$ \
    && "${_omc_guard_sid}" != *".."* \
    && ! "${_omc_guard_sid}" =~ ^\.+$ ]] \
  || _omc_guard_static_deny malformed

_omc_guard_early_tool="$(
  "${_omc_guard_trusted_jq}" -er '
    .tool_name | select(type == "string" and (contains("\u0000") | not))
  ' <<<"${HOOK_JSON}" \
    2>/dev/null
)" || _omc_guard_static_deny parser
_omc_guard_early_command="$(
  "${_omc_guard_trusted_jq}" -er '
    (.tool_input.command // "")
    | select(type == "string" and (contains("\u0000") | not))
  ' <<<"${HOOK_JSON}" 2>/dev/null
)" || _omc_guard_static_deny parser
_omc_guard_exact_reset=0
if [[ "${_omc_guard_early_tool}" == "Bash" \
    && "${_omc_guard_early_command}" == \
      'bash ~/.claude/skills/autowork/scripts/ulw-deactivate.sh "${CLAUDE_SESSION_ID}"' ]]; then
  _omc_guard_exact_reset=1
fi
_omc_guard_state_deny_or_exact_reset() {
  [[ "${_omc_guard_exact_reset}" -ne 1 ]] || exit 0
  _omc_guard_static_deny state
}

# When the shared marker is absent, the validated top-level ID supports a
# markerless fast path. The authoritative common.sh helpers still decide any
# hinted transaction. A regex scan is never used for identity or authority.
_omc_guard_global_active=0
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] \
  && _omc_guard_global_active=1
if [[ "${_omc_guard_global_active}" -eq 0 ]]; then
  _omc_guard_state_root="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
  _omc_guard_session_dir="${_omc_guard_state_root}/${_omc_guard_sid}"
  _omc_guard_needs_common=0
  # Hints may only create false positives. The authoritative helper below
  # distinguishes active versus inert reset quarantine; any direct admission
  # or native-bind node is always a fence, even before its first child exists.
  for _omc_guard_txn in \
      "${_omc_guard_session_dir}/.dispatch-txn."* \
      "${_omc_guard_session_dir}/.native-bind-txn."* \
      "${_omc_guard_session_dir}/.deactivate-txn."*; do
    if [[ -e "${_omc_guard_txn}" || -L "${_omc_guard_txn}" ]]; then
      _omc_guard_needs_common=1
      break
    fi
  done
  if [[ "${_omc_guard_needs_common}" -eq 0 ]]; then
    _omc_guard_state="${_omc_guard_session_dir}/session_state.json"
    [[ -e "${_omc_guard_state}" || -L "${_omc_guard_state}" ]] || exit 0
    _omc_guard_snapshot_authoritative_state "${_omc_guard_state}" \
      || _omc_guard_state_deny_or_exact_reset
    if ! _omc_guard_resume_class="$(
        _omc_guard_resume_initialization_class \
          "${_omc_guard_state_snapshot}"
      )"; then
      _omc_guard_state_deny_or_exact_reset
    fi
    [[ "${_omc_guard_resume_class}" == "active" \
        || "${_omc_guard_resume_class}" == "none" ]] \
      || _omc_guard_state_deny_or_exact_reset
    if [[ "${_omc_guard_resume_class}" == "active" ]]; then
      _omc_guard_needs_common=1
    fi
    if ! _omc_guard_owner="$(
        "${_omc_guard_trusted_jq}" -er --arg sid "${_omc_guard_sid}" '
          def valid_sid:
            type == "string" and length >= 1 and length <= 128
            and test("^[a-zA-Z0-9_.-]+$")
            and (contains("..") | not) and (test("^\\.+$") | not);
          if type == "object"
              and ((.resume_transferred_to // "") | type) == "string" then
            (.resume_transferred_to // "") as $owner
            | if $owner == "" or (($owner | valid_sid) and $owner != $sid)
              then $owner else error("invalid resume owner") end
          else error("invalid resume owner") end
        ' "${_omc_guard_state_snapshot}" 2>/dev/null
      )"; then
      _omc_guard_state_deny_or_exact_reset
    fi
    if [[ -n "${_omc_guard_owner}" ]] \
        && { [[ ! "${_omc_guard_owner}" \
              =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] \
          || [[ "${_omc_guard_owner}" == *".."* ]] \
          || [[ "${_omc_guard_owner}" =~ ^\.+$ ]] \
          || [[ "${_omc_guard_owner}" == "${_omc_guard_sid}" ]]; }; then
      _omc_guard_state_deny_or_exact_reset
    fi
    _omc_guard_test_snapshot_barrier \
      || _omc_guard_state_deny_or_exact_reset
    if [[ "${_omc_guard_needs_common}" -eq 0 ]]; then
      if [[ -n "${_omc_guard_owner}" ]]; then
        _omc_guard_needs_common=1
      elif _omc_guard_state_generation_is_current "${_omc_guard_state}"; then
        _omc_guard_cleanup_snapshot
        exit 0
      else
        # A generation replacement during the markerless observation cannot
        # inherit the benign snapshot's authority. Re-read under the shared
        # state mutex after common.sh is loaded.
        _omc_guard_needs_common=1
      fi
    fi
    _omc_guard_cleanup_snapshot
  fi
fi
unset _omc_guard_jq_candidate _omc_guard_sid _omc_guard_state_root
unset _omc_guard_session_dir _omc_guard_needs_common _omc_guard_txn
unset _omc_guard_state _omc_guard_owner
unset _omc_guard_resume_class
unset _omc_guard_jq_probe _omc_guard_payload_probe _omc_guard_store_object

# Make the already-verified parser visible while common.sh constructs and pins
# its own observer PATH. Nix candidates above have already been canonicalized.
_omc_guard_jq_dir="${_omc_guard_trusted_jq%/*}"
case ":${PATH:-}:" in
  *":${_omc_guard_jq_dir}:"*) ;;
  *) PATH="${_omc_guard_jq_dir}:${PATH:-}" ;;
esac
export PATH

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(builtin cd "${SCRIPT_DIR}" && builtin pwd -P)"
unset _omc_hook_source
# shellcheck source=common.sh
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE

SESSION_ID="${_omc_guard_sid}"
TOOL_NAME="${_omc_guard_early_tool}"
COMMAND_TEXT="${_omc_guard_early_command}"
unset _omc_guard_early_tool _omc_guard_early_command

validate_session_id "${SESSION_ID}" 2>/dev/null \
  || _omc_guard_static_deny malformed
# The process-wide active marker may belong to another session, but an
# addressed state node is authoritative lifecycle input. Once present it must
# remain a bounded, stable, non-symlinked top-level object with typed
# transfer/init fields and a complete paired generation. Read state and the
# related dispatch journals under the same mutex used by their publishers;
# common.sh's tolerant legacy readers are not sufficient for this fence.
_omc_guard_authoritative_state="${STATE_ROOT}/${SESSION_ID}/${STATE_JSON}"
RESUME_INITIALIZATION_ACTIVE=0
TRANSFER_OWNER=""
DISPATCH_INTERRUPTED=0
_omc_guard_load_authority_locked() {
  local state_probe="" owner=""
  if [[ -e "${_omc_guard_authoritative_state}" \
      || -L "${_omc_guard_authoritative_state}" ]]; then
    _omc_guard_snapshot_authoritative_state \
      "${_omc_guard_authoritative_state}" || return 1
    state_probe="$(_omc_guard_resume_initialization_class \
      "${_omc_guard_state_snapshot}")" || {
        _omc_guard_cleanup_snapshot
        return 1
      }
    [[ "${state_probe}" == "active" || "${state_probe}" == "none" ]] || {
      _omc_guard_cleanup_snapshot
      return 1
    }
    owner="$("${_omc_guard_trusted_jq}" -er --arg sid "${SESSION_ID}" '
      def valid_sid:
        type == "string" and length >= 1 and length <= 128
        and test("^[a-zA-Z0-9_.-]+$")
        and (contains("..") | not) and (test("^\\.+$") | not);
      if type == "object"
          and ((.resume_transferred_to // "") | type) == "string" then
        (.resume_transferred_to // "") as $owner
        | if $owner == "" or (($owner | valid_sid) and $owner != $sid)
          then $owner else error("invalid resume owner") end
      else error("invalid resume owner") end
    ' "${_omc_guard_state_snapshot}" 2>/dev/null)" || {
      _omc_guard_cleanup_snapshot
      return 1
    }
    _omc_guard_state_generation_is_current \
      "${_omc_guard_authoritative_state}" || {
        _omc_guard_cleanup_snapshot
        return 1
      }
    _omc_guard_cleanup_snapshot
    if [[ -n "${owner}" ]] \
        && { [[ ! "${owner}" =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] \
          || [[ "${owner}" == *".."* ]] \
          || [[ "${owner}" =~ ^\.+$ ]] \
          || [[ "${owner}" == "${SESSION_ID}" ]]; }; then
      return 1
    fi
    [[ "${state_probe}" != "active" ]] \
      || RESUME_INITIALIZATION_ACTIVE=1
    TRANSFER_OWNER="${owner}"
  fi
  if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
    DISPATCH_INTERRUPTED=1
  fi
}

_omc_guard_session_dir="${STATE_ROOT}/${SESSION_ID}"
if [[ -e "${_omc_guard_session_dir}" || -L "${_omc_guard_session_dir}" ]]; then
  [[ -d "${_omc_guard_session_dir}" && ! -L "${_omc_guard_session_dir}" ]] \
    || _omc_guard_state_deny_or_exact_reset
  if ! _with_lockdir "${_omc_guard_session_dir}/.state.lock" \
      "dispatch-recovery-guard" _omc_guard_load_authority_locked; then
    _omc_guard_state_deny_or_exact_reset
  fi
fi
[[ -n "${TRANSFER_OWNER}" || "${DISPATCH_INTERRUPTED}" -eq 1 \
    || "${RESUME_INITIALIZATION_ACTIVE}" -eq 1 ]] || exit 0

# The installed /ulw-off skill emits this one literal Bash command. No
# argument-bearing, redirected, chained, aliased, or alternate-path spelling
# inherits reset authority.
if [[ "${TOOL_NAME}" == "Bash" \
    && "${COMMAND_TEXT}" == \
      'bash ~/.claude/skills/autowork/scripts/ulw-deactivate.sh "${CLAUDE_SESSION_ID}"' ]]; then
  exit 0
fi

if [[ "${RESUME_INITIALIZATION_ACTIVE}" -eq 1 ]]; then
  DENIAL_REASON="[Resume initialization] This target has an active exact-generation resume transaction, so ${TOOL_NAME:-this tool} was denied until its owning handoff commits or rolls back. Only the exact bundled /ulw-off reset may retire malformed or abandoned lifecycle authority."
  log_anomaly "dispatch-recovery-guard" \
    "active resume initialization; denied ${TOOL_NAME:-unknown}" \
    2>/dev/null || true
elif [[ -n "${TRANSFER_OWNER}" ]]; then
  DENIAL_REASON="[Resume ownership] This session transferred its live task ownership to ${TRANSFER_OWNER}, so ${TOOL_NAME:-this tool} was denied in the dormant source. Continue in the owning resumed session, or run the exact bundled /ulw-off reset here to retire local harness state."
  log_anomaly "dispatch-recovery-guard" \
    "dormant resume source owned by ${TRANSFER_OWNER}; denied ${TOOL_NAME:-unknown}" \
    2>/dev/null || true
else
  DENIAL_REASON="[Dispatch recovery] A prior Agent authorization was interrupted mid-transaction, so ${TOOL_NAME:-this tool} was denied before partial pending/start/Council state could be used or advanced. Run the exact bundled /ulw-off reset, reactivate /ulw, and dispatch only the still-required role with a fresh identity."
  log_anomaly "dispatch-recovery-guard" \
    "interrupted Agent admission journal; denied ${TOOL_NAME:-unknown}" \
    2>/dev/null || true
fi
_omc_guard_denial_json=""
if ! _omc_guard_denial_json="$(
    "${_omc_guard_trusted_jq}" -nc --arg reason "${DENIAL_REASON}" '
      {hookSpecificOutput:{hookEventName:"PreToolUse",
        permissionDecision:"deny",permissionDecisionReason:$reason}}
    ' 2>/dev/null
  )" \
    || [[ -z "${_omc_guard_denial_json}" ]]; then
  _omc_guard_static_deny parser
fi
builtin printf '%s\n' "${_omc_guard_denial_json}"
