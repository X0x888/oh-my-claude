#!/usr/bin/env bash
# Always-on PreToolUse boundary for the user-owned Quality Constitution.
#
# Standalone human terminal calls never traverse this hook and retain the raw
# CLI. Assistant-issued tool calls must use the router's exact one-use
# apply-authorized command; direct edits to canonical profile storage are
# refused. This is cooperative same-user process integrity, not an OS sandbox.

set -euo pipefail

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE

HOOK_JSON="$(_omc_read_hook_stdin)"
SESSION_ID="$(jq -r '.session_id // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
TOOL_NAME="$(jq -r '.tool_name // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
COMMAND_TEXT="$(jq -r '.tool_input.command // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
FILE_PATH="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
TOOL_INPUT_JSON="$(jq -c '.tool_input // {}' <<<"${HOOK_JSON}" 2>/dev/null || printf '{}')"

[[ -n "${SESSION_ID}" ]] || exit 0

deny_qc_tool() {
  local reason="$1"
  jq -nc --arg reason "${reason}" '{
    hookSpecificOutput:{
      hookEventName:"PreToolUse",
      permissionDecision:"deny",
      permissionDecisionReason:$reason
    }
  }'
  exit 0
}

targets_qc_authority_receipt() {
  local value="${1:-}"
  [[ "${value}" == *"quality_constitution_authorization.json"* ]] \
    || { [[ "${value}" == *"quality_constitution"* ]] \
         && [[ "${value}" == *"authorization"* ]]; }
}

case "${TOOL_NAME}" in
  Edit|Write|MultiEdit|NotebookEdit)
    if targets_qc_authority_receipt "${FILE_PATH}"; then
      deny_qc_tool "[Quality Constitution authority] Direct editor writes to the one-use authorization receipt are forbidden. Only the real UserPromptSubmit router may issue that causal sidecar."
    fi
    if [[ "${FILE_PATH}" == *"omc-user/quality-constitutions"* ]]; then
      deny_qc_tool "[Quality Constitution authority] Direct editor writes to user-owned Constitution storage are not authorized. Use a real user /quality-constitution mutation, then execute only the one-use apply-authorized command issued for that prompt."
    fi
    ;;
  Bash)
    ;;
  mcp__*)
    if targets_qc_authority_receipt "${TOOL_INPUT_JSON}" \
        || [[ "${TOOL_INPUT_JSON}" == *"omc-user/quality-constitutions"* ]] \
        || { [[ "${TOOL_INPUT_JSON}" == *"omc-user"* ]] \
             && [[ "${TOOL_INPUT_JSON}" == *"quality-constitutions"* ]]; }; then
      _qc_mcp_name="$(printf '%s' "${TOOL_NAME}" | tr '[:upper:]' '[:lower:]')"
      _qc_mcp_action="$(jq -r '[.action,.operation,.mode,.method] | map(select(type == "string")) | join(" ") | ascii_downcase' \
        <<<"${TOOL_INPUT_JSON}" 2>/dev/null || true)"
      if [[ "${_qc_mcp_name} ${_qc_mcp_action}" =~ (write|edit|update|create|delete|remove|move|copy|upload|save|patch|execute|mutate) ]]; then
        deny_qc_tool "[Quality Constitution authority] Connector mutation of user-owned Constitution storage is not authorized. Durable taste must enter through the current prompt's exact one-use helper grant."
      fi
      if [[ ! "${_qc_mcp_name} ${_qc_mcp_action}" =~ (read|get|list|stat|inspect|search|find) ]]; then
        deny_qc_tool "[Quality Constitution authority] An unclassified connector operation targets user-owned Constitution storage. It is denied fail-closed because the hook cannot prove it is read-only."
      fi
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

[[ -n "${COMMAND_TEXT}" ]] || exit 0

# The supported helper surface is intentionally literal. Treat split
# quoting/concatenation as helper-shaped too (for example
# `quality-"constitution.sh"`). Any raw mutator in the same compound command
# causes the whole tool call to be denied.
_qc_helper_shaped=0
if [[ "${COMMAND_TEXT}" == *"quality-constitution.sh"* ]] \
    || { [[ "${COMMAND_TEXT}" == *"quality-"* ]] \
         && [[ "${COMMAND_TEXT}" == *"constitution.sh"* ]]; } \
    || { [[ "${COMMAND_TEXT}" == *"quality"* ]] \
         && [[ "${COMMAND_TEXT}" == *"constitution.sh"* ]] \
         && printf '%s\n' "${COMMAND_TEXT}" | grep -Eq \
           '(^|[[:space:];|&"=])(direct|add-claim|accept|reject|add-reference|remove)([[:space:];|&"=]|$)'; }; then
  _qc_helper_shaped=1
fi
if [[ "${_qc_helper_shaped}" -eq 1 ]]; then
  _qc_helper_allowed=0
  if printf '%s\n' "${COMMAND_TEXT}" | grep -Eq \
      '^[[:space:]]*bash[[:space:]]+"[^"[:cntrl:]]*/\.claude/skills/autowork/scripts/quality-constitution\.sh"[[:space:]]+apply-authorized[[:space:]]+--session-id[[:space:]]+"[A-Za-z0-9_.-]+"[[:space:]]+--grant[[:space:]]+"qca_[A-Za-z0-9_.-]+"[[:space:]]+--operation-b64[[:space:]]+"[A-Za-z0-9+/=]+"[[:space:]]*$'; then
    _qc_helper_allowed=1
  elif printf '%s\n' "${COMMAND_TEXT}" | grep -Eq \
      'quality-constitution\.sh[^[:alnum:][:space:]]*[[:space:]]+(show|resolve|compile|audit|digest|propose)([[:space:]]|$)' \
      && ! printf '%s\n' "${COMMAND_TEXT}" | grep -Eq \
        '(^|[[:space:];|&"=])(direct|add-claim|accept|reject|add-reference|remove)([[:space:];|&"=]|$)'; then
    _qc_helper_allowed=1
  fi
  if [[ "${_qc_helper_allowed}" -ne 1 ]]; then
    deny_qc_tool "[Quality Constitution authority] This assistant-side Constitution helper invocation is not an allowlisted read/proposal or the exact managed apply-authorized path. Raw/direct/variable-indirected mutations are human-terminal only. Use the one-use command issued for the current prompt."
  fi
fi

# The grant sidecar is itself authority. A model/tool process must not mint or
# rewrite it and then present those bytes as a user-issued grant. The router
# and lifecycle hooks write/remove it outside Claude's tool calls.
if targets_qc_authority_receipt "${COMMAND_TEXT}"; then
  if printf '%s\n' "${COMMAND_TEXT}" | grep -Eq \
      '(^|[[:space:];|&])(rm|mv|cp|install|truncate|tee|chmod|chown)([[:space:]]|$)|(^|[[:space:]])(sed|perl)([[:space:]].*)?[[:space:]]-i([[:space:]]|$)|(^|[^>])>>?([^>]|$)|(^|[[:space:];|&])(python|python3|ruby|node|printf)([[:space:]]|$)'; then
    deny_qc_tool "[Quality Constitution authority] Direct Bash mutation of the one-use authorization receipt is forbidden. Only the real UserPromptSubmit router may issue that causal sidecar."
  fi
fi

# Defense in depth for ordinary direct-file bypass attempts. Read-only jq/cat
# inspection remains possible; explicit write-shaped shell operations do not.
if [[ "${COMMAND_TEXT}" == *"omc-user/quality-constitutions"* ]] \
    || { [[ "${COMMAND_TEXT}" == *"omc-user"* ]] \
         && [[ "${COMMAND_TEXT}" == *"quality-constitutions"* ]]; }; then
  if printf '%s\n' "${COMMAND_TEXT}" | grep -Eq \
      '(^|[[:space:];|&])(rm|mv|cp|install|truncate|tee|chmod|chown)([[:space:]]|$)|(^|[[:space:]])(sed|perl)([[:space:]].*)?[[:space:]]-i([[:space:]]|$)|(^|[^>])>>?([^>]|$)|(^|[[:space:];|&])(python|python3|ruby|node)([[:space:]]|$)'; then
    deny_qc_tool "[Quality Constitution authority] Direct Bash mutation of user-owned Constitution storage is not authorized. Use the deterministic helper with the current one-use user grant."
  fi
fi

exit 0
