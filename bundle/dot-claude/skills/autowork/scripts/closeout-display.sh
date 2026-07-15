#!/usr/bin/env bash
#
# closeout-display.sh — lossless presentation safeguard for provisional closes.
#
# MessageDisplay is display-only and emits one replacement string per streamed
# batch. It cannot safely buffer multiple batches and later replay an accepted
# answer: hook strings are capped at 10,000 characters, and a timeout displays
# only the current original batch. Therefore ordinary prose and every response
# written after a current READY seal pass through byte-for-byte. Before READY,
# the first completion-shaped batch is replaced by one compact marker and later
# batches from that same message are suppressed. Neutral preamble lines may
# pass before a later canonical closeout heading reveals the completion attempt.

set -euo pipefail

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null 2>&1 || exit 0
HOOK_JSON="$(/bin/cat 2>/dev/null || true)"
_header="$(jq -r '[.session_id // "", .message_id // "", ((.index // 0) | tostring), ((.final // false) | tostring)] | @tsv' <<<"${HOOK_JSON}" 2>/dev/null || true)"
IFS=$'\t' read -r SESSION_ID message_id index final <<<"${_header}"
[[ "${SESSION_ID:-}" =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] || exit 0
[[ "${SESSION_ID}" != *".."* && ! "${SESSION_ID}" =~ ^\.+$ ]] || exit 0
[[ -n "${message_id:-}" ]] || exit 0
[[ "${index:-}" =~ ^[0-9]+$ ]] || index=0

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
_state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
[[ -f "${_state_file}" ]] || exit 0
_state_header="$(jq -r '[
  .workflow_mode // "", .ulw_enforcement_active // "migration",
  .session_outcome // "", .closeout_preflight_required // "",
  .closeout_material_activity // "", .closeout_display_active_message_id // "",
  .closeout_display_watch_message_id // ""
] | join("\u001f")' "${_state_file}" 2>/dev/null || true)"
IFS=$'\x1f' read -r _workflow _active _outcome _required _material active_id watch_id <<<"${_state_header}"
[[ "${_workflow:-}" == "ultrawork" && "${_required:-}" == "1" ]] || exit 0
[[ "${_active:-}" == "1" || ("${_active:-}" == "migration" && -z "${_outcome:-}") ]] || exit 0

# Command substitution strips trailing newlines. A sentinel preserves the exact
# delta for classification; passing through means emitting no hook output, so
# Claude Code renders the untouched original bytes itself.
delta="$({ jq -j '.delta // ""' <<<"${HOOK_JSON}" 2>/dev/null || true; printf '\x1e'; })"
delta="${delta%$'\x1e'}"

if [[ "${active_id:-}" != "${message_id}" \
    && "${watch_id:-}" != "${message_id}" \
    && "${index}" -ne 0 ]]; then
  exit 0
fi

. "${SCRIPT_DIR}/common.sh"
ensure_session_dir
is_ultrawork_mode || exit 0
closeout_seal_is_required || exit 0

_display_payload() {
  jq -nc --arg content "${1:-}" \
    '{hookSpecificOutput:{hookEventName:"MessageDisplay",displayContent:$content}}'
}

_display_looks_like_closeout() {
  local text="${1:-}"
  closeout_message_is_completion_style "${text}" && return 0
  printf '%s' "${text}" | grep -Eiq \
    '^[[:space:]]*(\*\*)?(Changed|Shipped|Headline|Bottom line|Goal achieved|Objective coverage)(\.)?([*][*])?([^[:alnum:]_]|$)' \
    && return 0
  printf '%s' "${text}" | grep -Eiq \
    '^[[:space:]]*((Here (is|are|you go)|This is)[^[:cntrl:]]{0,80}(finished|final|complete|result|summary|wrap-up)|Final([[:space:]]+(answer|result|summary|wrap-up))?[[:space:]]*[:.!-]|(Completed|Finished)([[:space:]]+(the[[:space:]]+)?(requested[[:space:]]+)?(work|task))?[[:space:]]*[:.!])' \
    && return 0
  return 1
}

marker="$(omc_box_rule_glyph 1) oh-my-claude · checking closeout gates; detailed summary will appear once ready."

# Remove sidecars/keys created by the short-lived buffering design. They are
# never consulted: accepted text must not depend on a later replay hook.
if [[ -n "$(read_state "closeout_display_buffer_message_id" 2>/dev/null || true)" \
    || -n "$(read_state "closeout_display_passthrough_message_id" 2>/dev/null || true)" \
    || -f "$(session_file "closeout-display-buffer.txt")" ]]; then
  rm -f "$(session_file "closeout-display-buffer.txt")" 2>/dev/null || true
  write_state_batch \
    "closeout_display_buffer_message_id" "" \
    "closeout_display_buffer_overflow" "" \
    "closeout_display_passthrough_message_id" "" 2>/dev/null || true
fi

# Once suppression starts, keep this one provisional message coherent. A READY
# seal acquired mid-stream applies to the next response, not the already hidden
# prefix. Hook failure still fails open for the current batch, never erasing an
# accepted final because accepted finals do not enter this branch.
if [[ "${active_id:-}" == "${message_id}" ]]; then
  _display_payload ""
  if [[ "${final}" == "true" ]]; then
    write_state_batch \
      "closeout_display_active_message_id" "" \
      "closeout_display_watch_message_id" "" \
      "closeout_display_last_suppressed_message_id" "${message_id}" 2>/dev/null || true
  fi
  exit 0
fi

# READY is the lossless boundary. Stop remains the exact final prose validator;
# if it rejects malformed presentation it can continue, but MessageDisplay must
# never eat bytes from the candidate that may ultimately be accepted.
if closeout_seal_is_current; then
  if [[ "${watch_id:-}" == "${message_id}" ]]; then
    write_state "closeout_display_watch_message_id" "" 2>/dev/null || true
  fi
  exit 0
fi

_suppress_current_message() {
  if ! write_state_batch \
    "closeout_display_watch_message_id" "" \
    "closeout_display_suppressed_ts" "$(now_epoch)" \
    "closeout_display_active_message_id" "$([[ "${final}" == "true" ]] && printf '' || printf '%s' "${message_id}")" \
    "closeout_display_last_suppressed_message_id" "$([[ "${final}" == "true" ]] && printf '%s' "${message_id}" || printf '')" \
    2>/dev/null; then
    # Fail open for presentation: without the committed message ID, later
    # batches could not be suppressed coherently. Emitting nothing lets Claude
    # Code render this original detailed delta unchanged.
    return 0
  fi
  _display_payload "${marker}"
}

if [[ "${watch_id:-}" == "${message_id}" ]]; then
  if _display_looks_like_closeout "${delta}"; then
    _suppress_current_message
  elif [[ "${final}" == "true" ]]; then
    write_state "closeout_display_watch_message_id" "" 2>/dev/null || true
  fi
  exit 0
fi

if [[ "${index}" -eq 0 ]] && _display_looks_like_closeout "${delta}"; then
  _suppress_current_message
  exit 0
fi

# Observe later whole-line batches without withholding this neutral first one.
# If the state write fails, presentation fails open and no user text is lost.
if [[ "${index}" -eq 0 && "${final}" != "true" && "${_material:-}" == "1" ]]; then
  write_state "closeout_display_watch_message_id" "${message_id}" 2>/dev/null || true
fi
exit 0
