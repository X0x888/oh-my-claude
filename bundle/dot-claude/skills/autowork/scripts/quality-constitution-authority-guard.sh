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

# This guard decides whether a tool may touch durable user taste. Reject a
# malformed envelope before ANY jq -r projection: Bash command substitution
# discards decoded NUL bytes and could otherwise turn a non-exact helper
# command, connector action/path, or foreign session ID into allowlisted
# authority. The recursive check also covers nested MCP/tool_input strings.
if ! jq -e '
    type == "object"
    and all(.. | strings; index("\u0000") == null)
  ' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
  deny_qc_tool \
    "[Quality Constitution authority] Malformed lifecycle input contains a decoded NUL or is not a JSON object. Protected storage access is denied before command/path classification."
fi
SESSION_ID="$(jq -r '.session_id // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
TOOL_NAME="$(jq -r '.tool_name // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
COMMAND_TEXT="$(jq -r '.tool_input.command // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
FILE_PATH="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
TOOL_INPUT_JSON="$(jq -c '.tool_input // {}' <<<"${HOOK_JSON}" 2>/dev/null || printf '{}')"
HOOK_CWD_RAW="$(jq -r '.cwd // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"

[[ -n "${SESSION_ID}" ]] || exit 0
validate_session_id "${SESSION_ID}" 2>/dev/null \
  || deny_qc_tool \
    "[Quality Constitution authority] Invalid lifecycle session identity. Protected storage access is denied before command/path classification."

targets_qc_authority_receipt() {
  local value="${1:-}" normalized=""
  value="$(qc_path_candidate_value "${value}" 2>/dev/null || true)"
  [[ -n "${value}" ]] || return 1
  if [[ "${value}" == *"quality_constitution_authorization.json"* ]] \
    || { [[ "${value}" == *"quality_constitution"* ]] \
         && [[ "${value}" == *"authorization"* ]]; }; then
    return 0
  fi
  [[ -n "${QC_AUTH_CANONICAL_PATH:-}" ]] || return 1
  normalized="$(qc_physical_path "${value}" "${HOOK_CWD:-/}" 2>/dev/null || true)"
  [[ "${normalized}" == "${QC_AUTH_CANONICAL_PATH}" \
      || "${normalized}" == "${QC_AUTH_PHYSICAL_PATH}" ]]
}

qc_lexical_path() {
  local value="${1:-}" base="${2:-}" part="" result="" index=0
  local -a parts stack
  [[ -n "${value}" && "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || return 1
  case "${value}" in
    [~]) value="${HOME}" ;;
    [~]/*) value="${HOME}/${value:2}" ;;
    '$HOME') value="${HOME}" ;;
    '$HOME/'*) value="${HOME}/${value#\$HOME/}" ;;
    '${HOME}') value="${HOME}" ;;
    '${HOME}/'*) value="${HOME}/${value#\$\{HOME\}/}" ;;
  esac
  if [[ "${value}" != /* ]]; then
    [[ -n "${base}" && "${base}" == /* ]] || return 1
    value="${base}/${value}"
  fi
  IFS='/' read -r -a parts <<<"${value}"
  for part in "${parts[@]}"; do
    case "${part}" in
      ''|.) ;;
      ..)
        if (( ${#stack[@]} > 0 )); then
          index=$((${#stack[@]} - 1))
          unset 'stack[index]'
        fi
        ;;
      *) stack[${#stack[@]}]="${part}" ;;
    esac
  done
  if (( ${#stack[@]} == 0 )); then
    printf '/'
    return 0
  fi
  for part in "${stack[@]}"; do
    result="${result}/${part}"
  done
  printf '%s' "${result}"
}

qc_physical_path() {
  local value="${1:-}" base="${2:-}" depth="${3:-0}"
  local normalized="" probe="" suffix="" parent="" leaf="" target="" physical=""
  (( depth < 16 )) || return 1
  normalized="$(qc_lexical_path "${value}" "${base}")" || return 1
  probe="${normalized}"
  while [[ ! -e "${probe}" && ! -L "${probe}" ]]; do
    [[ "${probe}" != "/" ]] || break
    leaf="${probe##*/}"
    suffix="/${leaf}${suffix}"
    parent="${probe%/*}"
    [[ -n "${parent}" ]] || parent="/"
    [[ "${parent}" != "${probe}" ]] || return 1
    probe="${parent}"
  done
  if [[ -L "${probe}" ]]; then
    target="$(readlink "${probe}" 2>/dev/null)" || return 1
    case "${target}" in
      /*) ;;
      *) target="${probe%/*}/${target}" ;;
    esac
    qc_physical_path "${target}${suffix}" "/" "$((depth + 1))"
    return
  fi
  if [[ -d "${probe}" ]]; then
    physical="$(cd "${probe}" 2>/dev/null && pwd -P)" || return 1
  elif [[ -e "${probe}" ]]; then
    parent="${probe%/*}"
    leaf="${probe##*/}"
    [[ -n "${parent}" ]] || parent="/"
    parent="$(cd "${parent}" 2>/dev/null && pwd -P)" || return 1
    physical="${parent%/}/${leaf}"
  else
    physical="/"
  fi
  qc_lexical_path "${physical}${suffix}" "/"
}

qc_path_within() {
  local candidate="${1:-}" root="${2:-}"
  [[ -n "${candidate}" && -n "${root}" ]] || return 1
  [[ "${candidate}" == "${root}" || "${candidate}" == "${root%/}/"* ]]
}

HOOK_CWD=""
if [[ -n "${HOOK_CWD_RAW}" ]]; then
  HOOK_CWD="$(qc_physical_path "${HOOK_CWD_RAW}" "$(pwd -P)" 2>/dev/null || true)"
fi
[[ -n "${HOOK_CWD}" ]] || HOOK_CWD="$(pwd -P)"
QC_CANONICAL_ROOT="$(qc_lexical_path "${HOME}/.claude/omc-user/quality-constitutions" "/")"
QC_PHYSICAL_ROOT="$(qc_physical_path "${QC_CANONICAL_ROOT}" "/" 2>/dev/null || true)"
[[ -n "${QC_PHYSICAL_ROOT}" ]] || QC_PHYSICAL_ROOT="${QC_CANONICAL_ROOT}"
QC_OMC_USER_ROOT="$(qc_physical_path "${HOME}/.claude/omc-user" "/" 2>/dev/null || true)"
[[ -n "${QC_OMC_USER_ROOT}" ]] \
  || QC_OMC_USER_ROOT="$(qc_lexical_path "${HOME}/.claude/omc-user" "/")"
QC_AUTH_CANONICAL_PATH="$(qc_lexical_path \
  "$(session_file "quality_constitution_authorization.json")" "${HOOK_CWD}")"
QC_AUTH_PHYSICAL_PATH="$(qc_physical_path \
  "${QC_AUTH_CANONICAL_PATH}" "/" 2>/dev/null || true)"
[[ -n "${QC_AUTH_PHYSICAL_PATH}" ]] \
  || QC_AUTH_PHYSICAL_PATH="${QC_AUTH_CANONICAL_PATH}"

targets_qc_storage_path() {
  local value="${1:-}" normalized=""
  value="$(qc_path_candidate_value "${value}" 2>/dev/null || true)"
  [[ -n "${value}" ]] || return 1
  normalized="$(qc_physical_path "${value}" "${HOOK_CWD}" 2>/dev/null || true)"
  if qc_path_within "${normalized}" "${QC_CANONICAL_ROOT}" \
      || qc_path_within "${normalized}" "${QC_PHYSICAL_ROOT}"; then
    return 0
  fi
  # Ambiguous or not-yet-existing targets still fail closed when their raw
  # shape names both protected path components.
  [[ "${value}" == *"omc-user/quality-constitutions"* ]] \
    || { [[ "${value}" == *"omc-user"* ]] \
         && [[ "${value}" == *"quality-constitutions"* ]]; }
}

# Normalize only filesystem-shaped connector operands. URI/resource fields are
# common connector spellings for local files, but arbitrary http/app/database
# URIs are not filesystem authority and must not be interpreted as paths. Keep
# percent-encoded paths fail-closed instead of invoking an input-controlled
# decoder: canonical local file URIs and symlink aliases need no decoding.
qc_path_candidate_value() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != *$'\n'* \
      && "${value}" != *$'\r'* ]] || return 1
  case "${value}" in
    [Ff][Ii][Ll][Ee]:*)
      # Percent escapes, query/fragment syntax, remote authorities, and
      # relative opaque `file:` forms cannot be compared without parsing or
      # decoding connector-controlled bytes. Admit only unescaped local forms
      # whose absolute path boundary is unambiguous.
      [[ "${value}" != *'%'* && "${value}" != *'?'* \
          && "${value}" != *'#'* ]] || return 1
      case "${value}" in
        [Ff][Ii][Ll][Ee]://[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]/*)
          value="${value:16}" ;;
        [Ff][Ii][Ll][Ee]:///*)
          value="${value:7}"
          # Four-or-more slash spellings leave a `//` path, whose authority
          # semantics are platform-dependent. Keep only the canonical local
          # triple-slash form.
          [[ "${value}" == /* && "${value}" != //* ]] || return 1
          ;;
        [Ff][Ii][Ll][Ee]://*) return 1 ;;
        [Ff][Ii][Ll][Ee]:/*)
          value="${value:5}"
          [[ "${value}" == /* && "${value}" != //* ]] || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    *://*) return 1 ;;
  esac
  printf '%s' "${value}"
}

command_targets_qc_authority_receipt() {
  local value="${1:-}" token=""
  targets_qc_authority_receipt "${value}" && return 0
  if qc_tokenize_simple_command "${value}" paths; then
    for token in "${_QC_SHELL_TOKENS[@]}"; do
      case "${token}" in
        /*|./*|../*|[~]/*|'$HOME'/*|'${HOME}'/*)
          targets_qc_authority_receipt "${token}" && return 0
          ;;
      esac
    done
  fi
  return 1
}

command_targets_qc_storage() {
  local value="${1:-}" token="" normalized=""
  if qc_path_within "${HOOK_CWD}" "${QC_CANONICAL_ROOT}" \
      || qc_path_within "${HOOK_CWD}" "${QC_PHYSICAL_ROOT}"; then
    return 0
  fi
  if [[ "${value}" == *"omc-user/quality-constitutions"* ]] \
    || { [[ "${value}" == *"omc-user"* ]] \
         && [[ "${value}" == *"quality-constitutions"* ]]; } \
    || { qc_path_within "${HOOK_CWD}" "${QC_OMC_USER_ROOT}" \
         && [[ "${value}" == *"quality-constitutions"* ]]; }; then
    return 0
  fi
  # Resolve every literal shell token as an over-approximation. This catches
  # absolute, relative, traversal, and symlink-alias spellings used as `dd`
  # destinations, archive extraction roots, `cd` targets, and similar. Shell
  # indirection is intentionally not evaluated; helper-shaped indirection is
  # rejected separately by the exact whole-command grammar below.
  if qc_tokenize_simple_command "${value}" paths; then
    for token in "${_QC_SHELL_TOKENS[@]}"; do
      case "${token}" in
        /*|./*|../*|[~]/*|'$HOME'/*|'${HOME}'/*)
          normalized="$(qc_physical_path "${token}" "${HOOK_CWD}" 2>/dev/null || true)"
          if qc_path_within "${normalized}" "${QC_CANONICAL_ROOT}" \
              || qc_path_within "${normalized}" "${QC_PHYSICAL_ROOT}"; then
            return 0
          fi
          ;;
      esac
    done
  fi
  return 1
}

qc_tool_input_path_candidates() {
  jq -r '
    def path_key:
      ascii_downcase
      | gsub("[^a-z0-9]"; "")
      | . as $key
      | ($key | IN(
          "path", "paths", "filepath", "filepaths", "file", "files",
          "filename", "filenames", "directory", "directories", "dir",
          "dirs", "root", "roots", "target", "targets", "destination",
          "destinations", "dest", "dests", "source", "sources", "src",
          "from", "to", "location", "locations", "uri", "uris",
          "url", "urls", "fileurl", "fileurls",
          "resource", "resources", "resourceuri", "resourceuris",
          "objectkey", "objectkeys", "outputfile", "outputfiles",
          "savefile", "savefiles", "targeturl", "targeturls",
          "sourceurl", "sourceurls", "destinationurl",
          "destinationurls", "outputurl", "outputurls"))
        or (($key != "curl") and
            ($key | test("(path|paths|uri|uris|url|urls|fileurl|fileurls|objectkey|objectkeys|outputfile|outputfiles|savefile|savefiles)$")));
    .. | objects | to_entries[] |
    select(.key | path_key) |
    .value |
    if type == "string" then .
    elif type == "array" then .[] | select(type == "string")
    else empty
    end
  ' <<<"${TOOL_INPUT_JSON}" 2>/dev/null || true
}

qc_tool_input_has_opaque_local_file_uri() {
  local candidate=""
  while IFS= read -r candidate; do
    case "${candidate}" in
      [Ff][Ii][Ll][Ee]:*)
        qc_path_candidate_value "${candidate}" >/dev/null 2>&1 || return 0
        ;;
    esac
  done < <(qc_tool_input_path_candidates)
  return 1
}

tool_input_targets_qc_path() {
  local matcher="${1:-}" candidate="" base="" combined=""
  local -a candidates=()
  case "${matcher}" in
    targets_qc_authority_receipt|targets_qc_storage_path) ;;
    *) return 1 ;;
  esac
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    candidates[${#candidates[@]}]="${candidate}"
  done < <(qc_tool_input_path_candidates)
  for candidate in "${candidates[@]}"; do
    "${matcher}" "${candidate}" && return 0
  done
  # Some connector schemas split one destination across `directory`/`root`
  # and a relative `path`/`filename`. Resolve each relative path-like scalar
  # against each absolute/file-URI candidate. This inspects only path-bearing
  # fields, never content/prompt/message prose.
  for base in "${candidates[@]}"; do
    base="$(qc_path_candidate_value "${base}" 2>/dev/null || true)"
    [[ "${base}" == /* || "${base}" == [~]/* \
        || "${base}" == '$HOME'/* || "${base}" == '${HOME}'/* ]] || continue
    for candidate in "${candidates[@]}"; do
      candidate="$(qc_path_candidate_value "${candidate}" 2>/dev/null || true)"
      [[ -n "${candidate}" && "${candidate}" != /* \
          && "${candidate}" != [~]/* \
          && "${candidate}" != '$HOME'/* \
          && "${candidate}" != '${HOME}'/* ]] || continue
      combined="${base%/}/${candidate#./}"
      "${matcher}" "${combined}" && return 0
    done
  done
  return 1
}

qc_mcp_operation_is_explicit_read_only() {
  local terminal="" action="" normalized=""
  # Reuse the shared, fail-closed classifier first. It recognizes mixed names
  # such as read_and_replace and action verbs such as rename/append/set/apply;
  # unknown terminal operations are mutations by default.
  mcp_tool_attempts_artifact_mutation \
    "${TOOL_NAME}" "${TOOL_INPUT_JSON}" && return 1
  terminal="${TOOL_NAME##*__}"
  terminal="$(printf '%s' "${terminal}" \
    | tr '[:upper:]-' '[:lower:]_')"
  case "${terminal}" in
    read|read_*|*_read|get|get_*|*_get|list|list_*|*_list|stat|stat_*|*_stat|inspect|inspect_*|*_inspect|search|search_*|*_search|find|find_*|*_find)
      ;;
    *) return 1 ;;
  esac
  while IFS= read -r action; do
    [[ -n "${action}" ]] || continue
    normalized="$(printf '%s' "${action}" \
      | tr '[:upper:]- ' '[:lower:]__')"
    case "${normalized}" in
      read|read_*|get|get_*|list|list_*|stat|stat_*|inspect|inspect_*|search|search_*|find|find_*) ;;
      *) return 1 ;;
    esac
  done < <(jq -r '[.action?,.operation?,.mode?,.method?,.verb?,.request_type?]
    | .[] | select(type == "string" and length > 0)' \
    <<<"${TOOL_INPUT_JSON}" 2>/dev/null || true)
  return 0
}

case "${TOOL_NAME}" in
  Edit|Write|MultiEdit|NotebookEdit)
    if targets_qc_authority_receipt "${FILE_PATH}"; then
      deny_qc_tool "[Quality Constitution authority] Direct editor writes to the one-use authorization receipt are forbidden. Only the real UserPromptSubmit router may issue that causal sidecar."
    fi
    if targets_qc_storage_path "${FILE_PATH}"; then
      deny_qc_tool "[Quality Constitution authority] Direct editor writes to user-owned Constitution storage are not authorized. Use a real user /quality-constitution mutation, then execute only the one-use apply-authorized command issued for that prompt."
    fi
    ;;
  Bash)
    ;;
  mcp__*)
    # Never decode connector-controlled URI bytes inside this guard. A local
    # file URI with escapes, a remote authority, or malformed/relative syntax
    # can alias protected storage but cannot be compared safely as a literal
    # path. Mutations and unclassified operations therefore fail closed; an
    # exact read-only operation remains non-mutating regardless of the opaque
    # destination.
    if qc_tool_input_has_opaque_local_file_uri; then
      if mcp_tool_attempts_artifact_mutation \
          "${TOOL_NAME}" "${TOOL_INPUT_JSON}"; then
        deny_qc_tool "[Quality Constitution authority] Connector mutation through an opaque local file URI is denied fail-closed because the protected destination cannot be proven absent without parsing or decoding input-controlled bytes."
      fi
      if ! qc_mcp_operation_is_explicit_read_only; then
        deny_qc_tool "[Quality Constitution authority] An unclassified connector operation uses an opaque local file URI. It is denied fail-closed because the hook cannot prove either the destination or read-only semantics."
      fi
    fi
    if tool_input_targets_qc_path targets_qc_authority_receipt \
        || tool_input_targets_qc_path targets_qc_storage_path; then
      if mcp_tool_attempts_artifact_mutation \
          "${TOOL_NAME}" "${TOOL_INPUT_JSON}"; then
        deny_qc_tool "[Quality Constitution authority] Connector mutation of user-owned Constitution storage is not authorized. Durable taste must enter through the current prompt's exact one-use helper grant."
      fi
      if ! qc_mcp_operation_is_explicit_read_only; then
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

qc_benign_helper_source_inspection() {
  local command_text="${1:-}"
  [[ "${command_text}" == *"quality-constitution.sh"* ]] || return 1
  # Keep this deliberately narrower than a shell parser. These tools are
  # read/parse-only in the admitted forms; compound syntax, substitutions,
  # redirects, and executable rg preprocessors remain denied. Git diff is not
  # admitted: repository/user config and attributes can attach executable
  # textconv or external-diff drivers to an apparently read-only spelling.
  if [[ "${command_text}" == *';'* || "${command_text}" == *'|'* \
      || "${command_text}" == *'&'* || "${command_text}" == *'>'* \
      || "${command_text}" == *'<'* || "${command_text}" == *'`'* \
      || "${command_text}" == *'$('* ]]; then
    return 1
  fi
  case "${command_text}" in
    *--pre*|*--output*) return 1 ;;
  esac
  printf '%s\n' "${command_text}" | grep -Eq \
    "^[[:space:]]*(shellcheck([[:space:]]+-[A-Za-z0-9_=,.-]+)*|bash[[:space:]]+-n|rg([[:space:]]+-[A-Za-z0-9_=,.-]+)*)[[:space:]]+[^[:cntrl:]]*quality-constitution\\.sh['\"]?[[:space:]]*$"
}

_QC_SHELL_TOKENS=()
qc_tokenize_simple_command() {
  local text="${1:-}" mode="${2:-strict}" token="" quote="" ch="" next=""
  local escaped=0 index=0
  _QC_SHELL_TOKENS=()
  for (( index = 0; index < ${#text}; index++ )); do
    ch="${text:index:1}"
    if (( escaped == 1 )); then
      if [[ "${ch}" != $'\n' ]]; then
        token="${token}${ch}"
      fi
      escaped=0
      continue
    fi
    case "${quote}" in
      single)
        if [[ "${ch}" == "'" ]]; then quote=""; else token="${token}${ch}"; fi
        ;;
      double)
        case "${ch}" in
          '"') quote="" ;;
          \\) escaped=1 ;;
          '`') return 1 ;;
          '$')
            next="${text:index+1:1}"
            [[ "${next}" != "(" ]] || return 1
            token="${token}${ch}"
            ;;
          *) token="${token}${ch}" ;;
        esac
        ;;
      *)
        case "${ch}" in
          "'") quote="single" ;;
          '"') quote="double" ;;
          \\) escaped=1 ;;
          ' '|$'\t'|$'\n'|$'\r')
            if [[ -n "${token}" ]]; then
              _QC_SHELL_TOKENS[${#_QC_SHELL_TOKENS[@]}]="${token}"
              token=""
            fi
            ;;
          ';'|'|'|'&'|'<'|'>'|'('|')'|'`'|'#'|'=')
            if [[ "${mode}" == "paths" ]]; then
              if [[ -n "${token}" ]]; then
                _QC_SHELL_TOKENS[${#_QC_SHELL_TOKENS[@]}]="${token}"
                token=""
              fi
            else
              return 1
            fi
            ;;
          '$')
            next="${text:index+1:1}"
            [[ "${next}" != "(" ]] || return 1
            token="${token}${ch}"
            ;;
          *) token="${token}${ch}" ;;
        esac
        ;;
    esac
  done
  [[ -z "${quote}" && "${escaped}" -eq 0 ]] || return 1
  if [[ -n "${token}" ]]; then
    _QC_SHELL_TOKENS[${#_QC_SHELL_TOKENS[@]}]="${token}"
  fi
  (( ${#_QC_SHELL_TOKENS[@]} > 0 ))
}

qc_helper_script_token_allowed() {
  local token="${1:-}" resolved="" source_helper="" installed_helper=""
  resolved="$(qc_physical_path "${token}" "${HOOK_CWD}" 2>/dev/null || true)"
  source_helper="$(qc_physical_path "${SCRIPT_DIR}/quality-constitution.sh" "/" 2>/dev/null || true)"
  installed_helper="$(qc_physical_path "${HOME}/.claude/skills/autowork/scripts/quality-constitution.sh" "/" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] || return 1
  [[ "${resolved}" == "${source_helper}" || "${resolved}" == "${installed_helper}" ]]
}

qc_allowlisted_helper_read_or_proposal() {
  local command_text="${1:-}" index=0 count=0 command="" argument=""
  qc_tokenize_simple_command "${command_text}" || return 1
  count=${#_QC_SHELL_TOKENS[@]}
  if [[ "${_QC_SHELL_TOKENS[0]}" == "bash" ]]; then
    index=1
  fi
  (( index < count )) || return 1
  qc_helper_script_token_allowed "${_QC_SHELL_TOKENS[index]}" || return 1
  index=$((index + 1))
  (( index < count )) || return 1
  command="${_QC_SHELL_TOKENS[index]}"
  index=$((index + 1))
  case "${command}" in
    show|resolve|audit)
      (( index == count )) && return 0
      (( index + 1 == count )) && [[ "${_QC_SHELL_TOKENS[index]}" == "--json" ]]
      return
      ;;
    digest)
      (( index == count ))
      return
      ;;
    compile)
      while (( index < count )); do
        argument="${_QC_SHELL_TOKENS[index]}"
        index=$((index + 1))
        case "${argument}" in
          --json) ;;
          --role|--domain|--task-type|--surface|--audience|--path|--max-chars)
            (( index < count )) || return 1
            index=$((index + 1))
            ;;
          *) return 1 ;;
        esac
      done
      return 0
      ;;
    propose)
      while (( index < count )); do
        argument="${_QC_SHELL_TOKENS[index]}"
        index=$((index + 1))
        case "${argument}" in
          --statement|--quote|--signal|--category|--polarity|--rationale|--concept-key|--domain|--task-type|--surface|--audience|--path|--session-id)
            (( index < count )) || return 1
            index=$((index + 1))
            ;;
          *) return 1 ;;
        esac
      done
      return 0
      ;;
    *) return 1 ;;
  esac
}

qc_allowlisted_managed_apply() {
  local command_text="${1:-}" count=0
  qc_tokenize_simple_command "${command_text}" || return 1
  count=${#_QC_SHELL_TOKENS[@]}
  (( count == 9 )) || return 1
  [[ "${_QC_SHELL_TOKENS[0]}" == "bash" ]] || return 1
  qc_helper_script_token_allowed "${_QC_SHELL_TOKENS[1]}" || return 1
  [[ "${_QC_SHELL_TOKENS[2]}" == "apply-authorized" \
      && "${_QC_SHELL_TOKENS[3]}" == "--session-id" \
      && "${_QC_SHELL_TOKENS[4]}" == "${SESSION_ID}" \
      && "${_QC_SHELL_TOKENS[5]}" == "--grant" \
      && "${_QC_SHELL_TOKENS[6]}" =~ ^qca_[A-Za-z0-9_.-]+$ \
      && "${_QC_SHELL_TOKENS[7]}" == "--operation-b64" \
      && "${_QC_SHELL_TOKENS[8]}" =~ ^[A-Za-z0-9+/=]+$ ]]
}

# The supported helper surface is intentionally literal. Treat split
# quoting/concatenation as helper-shaped too (for example
# `quality-"constitution.sh"`). Any raw mutator in the same compound command
# causes the whole tool call to be denied.
_qc_helper_shaped=0
_qc_helper_allowed=0
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
  if qc_benign_helper_source_inspection "${COMMAND_TEXT}"; then
    _qc_helper_allowed=1
  elif qc_allowlisted_managed_apply "${COMMAND_TEXT}"; then
    _qc_helper_allowed=1
  elif qc_allowlisted_helper_read_or_proposal "${COMMAND_TEXT}"; then
    _qc_helper_allowed=1
  fi
  if [[ "${_qc_helper_allowed}" -ne 1 ]]; then
    deny_qc_tool "[Quality Constitution authority] This assistant-side Constitution helper invocation is not an allowlisted read/proposal or the exact managed apply-authorized path. Raw/direct/variable-indirected mutations are human-terminal only. Use the one-use command issued for the current prompt."
  fi
fi

qc_command_invokes_physical_helper() {
  local command_text="${1:-}" token=""
  qc_tokenize_simple_command "${command_text}" paths || return 1
  for token in "${_QC_SHELL_TOKENS[@]}"; do
    case "${token}" in
      /*|./*|../*|[~]/*|'$HOME'/*|'${HOME}'/*)
        qc_helper_script_token_allowed "${token}" && return 0
        ;;
    esac
  done
  return 1
}

# Raw-name matching is only a fast path. A pre-existing symlink can spell the
# trusted helper as `/tmp/qh`; resolve literal command tokens physically and
# apply the same exact grammar regardless of alias. Copied/modified helpers
# remain outside this cooperative same-user boundary, but a resolvable alias
# to the protected helper is not an escape hatch.
if [[ "${_qc_helper_allowed}" -ne 1 ]] \
    && qc_command_invokes_physical_helper "${COMMAND_TEXT}"; then
  if qc_allowlisted_helper_read_or_proposal "${COMMAND_TEXT}"; then
    _qc_helper_allowed=1
  else
    deny_qc_tool "[Quality Constitution authority] This physical Constitution helper target is not an exact allowlisted read/proposal command. Symlink aliases do not authorize direct or variable-indirected mutation."
  fi
fi

# Raw Bash access to either authority surface is denied fail-closed. Shell
# mutability is open-ended (`dd`, archive extraction, language runtimes,
# configured preprocessors, redirects, and many more), so a mutator denylist
# cannot prove a command read-only. Use the allowlisted helper read surfaces
# (`show`, `resolve`, `compile`, `audit`, `digest`) instead; the exact managed
# apply-authorized command remains the only assistant-side mutation entrance.
if command_targets_qc_authority_receipt "${COMMAND_TEXT}"; then
  deny_qc_tool "[Quality Constitution authority] Raw Bash access to the one-use authorization receipt is forbidden. Only the real UserPromptSubmit router may issue or consume that causal sidecar."
fi
if command_targets_qc_storage "${COMMAND_TEXT}"; then
  deny_qc_tool "[Quality Constitution authority] Raw Bash access to user-owned Constitution storage is not authorized. Use the deterministic helper read surfaces or the current one-use apply-authorized command."
fi

exit 0
