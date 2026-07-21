#!/usr/bin/env bash
# Compact install/readiness view over retained install and removal coverage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
JSON_MODE=0
SKIP_INSTALL=0
SKIP_UNINSTALL=0
ok_count=0
skip_count=0
fail_count=0
surfaces='[]'

usage() {
  printf '%s\n' \
    'Usage: bash tools/verify-install-readiness.sh [options]' \
    '' \
    'Options:' \
    '  --skip-install      Skip isolated install/artifact coverage' \
    '  --skip-uninstall    Skip merge-safe uninstall coverage' \
    '  --json'
}

append_surface() {
  local name="$1" status="$2" command="$3" output="$4" rc="$5" summary
  summary="$(awk 'NF { line=$0 } END { print line }' <<<"${output}")"
  [[ -n "${summary}" ]] || summary="command exited ${rc} without output"
  surfaces="$(jq -nc --argjson rows "${surfaces}" --arg name "${name}" \
    --arg status "${status}" --arg command "${command}" --arg summary "${summary}" \
    --arg output "${output}" --argjson exit_code "${rc}" \
    '$rows + [{name:$name,status:$status,command:$command,summary:$summary,output:$output,exit_code:$exit_code}]')"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "${status}" "${name}" "${summary}"
    [[ "${status}" != "FAIL" || -z "${output}" ]] || printf '%s\n' "${output}"
  fi
}

run_surface() {
  local name="$1" command="$2" output rc=0
  output="$(cd "${REPO_ROOT}" && bash -lc "${command}" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    ok_count=$((ok_count + 1))
    append_surface "${name}" OK "${command}" "${output}" "${rc}"
  else
    fail_count=$((fail_count + 1))
    append_surface "${name}" FAIL "${command}" "${output}" "${rc}"
  fi
}

skip_surface() {
  skip_count=$((skip_count + 1))
  append_surface "$1" SKIP "" "skipped by caller" 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-uninstall) SKIP_UNINSTALL=1; shift ;;
    # Retired surface options remain compatibility aliases for --skip-install.
    --skip-bootstrapper|--skip-handoff|--skip-recovery|--skip-onboarding) SKIP_INSTALL=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'verify-install-readiness: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "${SKIP_INSTALL}" -eq 1 ]] \
  && skip_surface install \
  || run_surface install 'bash tests/test-install-artifacts.sh'
[[ "${SKIP_UNINSTALL}" -eq 1 ]] \
  && skip_surface uninstall \
  || run_surface uninstall 'bash tests/test-uninstall-merge.sh'

summary_text="verify-install-readiness: summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
message="verify-install-readiness: retained install and removal surfaces are green"
[[ "${fail_count}" -eq 0 ]] || message="verify-install-readiness: retained install/removal surfaces have failures"

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -nc --arg summary_text "${summary_text}" --arg message "${message}" \
    --argjson ok "${ok_count}" --argjson skip "${skip_count}" \
    --argjson fail "${fail_count}" --argjson surfaces "${surfaces}" \
    '{tool:"verify-install-readiness",result:(if $fail == 0 then "ok" else "fail" end),counts:{ok:$ok,skip:$skip,fail:$fail},summary_text:$summary_text,message:$message,surfaces:$surfaces}'
else
  printf '%s\n%s\n' "${summary_text}" "${message}"
fi

(( fail_count == 0 ))
