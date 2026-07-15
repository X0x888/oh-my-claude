#!/usr/bin/env bash

set -euo pipefail

# Thin CLI over common.sh's authoritative runtime resolver. Council uses one
# invocation for its selected set when no /ulw router directive is present;
# hooks call resolve_agent_model directly and avoid this process boundary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1
. "${SCRIPT_DIR}/common.sh"

purpose="standard"
deep=0
risk="low"
format="text"
agents=()

usage() {
  local rc="${1:-2}"
  printf 'Usage: %s [--context standard|council] [--deep] [--risk low|medium|high] [--json] agent...\n' "$0" >&2
  exit "${rc}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      [[ $# -ge 2 ]] || usage
      purpose="$2"
      shift 2
      ;;
    --deep)
      deep=1
      shift
      ;;
    --risk)
      [[ $# -ge 2 ]] || usage
      risk="$2"
      shift 2
      ;;
    --json)
      format="json"
      shift
      ;;
    --help|-h)
      usage 0
      ;;
    --*)
      usage
      ;;
    *)
      agents+=("$1")
      shift
      ;;
  esac
done

case "${purpose}" in standard|council) ;; *) usage ;; esac
case "${risk}" in low|medium|high) ;; *) usage ;; esac
[[ "${#agents[@]}" -gt 0 ]] || usage

effective_tier="$(omc_effective_model_tier)"

if [[ "${format}" == "json" ]]; then
  rows='[]'
  for agent in "${agents[@]}"; do
    resolved="$(resolve_agent_model "${agent}" "${purpose}" "${deep}" "${risk}")"
    if [[ "${resolved}" == "inherit" || "${resolved}" == "definition" ]]; then
      tool_model=""
      action="omit"
    else
      tool_model="${resolved}"
      action="pass"
    fi
    rows="$(jq -c \
      --arg agent "${agent}" \
      --arg resolved "${resolved}" \
      --arg action "${action}" \
      --arg tool_model "${tool_model}" \
      '. + [{agent:$agent,resolved:$resolved,action:$action,tool_model:$tool_model}]' \
      <<<"${rows}")"
  done
  jq -nc \
    --arg tier "${effective_tier}" \
    --arg purpose "${purpose}" \
    --arg risk "${risk}" \
    --argjson deep "${deep}" \
    --argjson routes "${rows}" \
    '{tier:$tier,purpose:$purpose,risk:$risk,deep:($deep == 1),routes:$routes}'
else
  for agent in "${agents[@]}"; do
    resolved="$(resolve_agent_model "${agent}" "${purpose}" "${deep}" "${risk}")"
    case "${resolved}" in
      inherit) printf '%s\tomit model\tinherit current session\n' "${agent}" ;;
      definition) printf '%s\tomit model\tuse agent definition\n' "${agent}" ;;
      *) printf '%s\tpass model=%s\texplicit\n' "${agent}" "${resolved}" ;;
    esac
  done
fi
