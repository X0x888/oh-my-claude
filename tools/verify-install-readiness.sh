#!/usr/bin/env bash
#
# tools/verify-install-readiness.sh — top-level install/onboarding audit
# across the first-run proof surfaces that matter for professional
# distribution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BOOTSTRAPPER_CMD="${OMC_INSTALL_READINESS_BOOTSTRAPPER_CMD:-bash tests/test-install-remote.sh}"
HANDOFF_CMD="${OMC_INSTALL_READINESS_HANDOFF_CMD:-bash tests/test-install-handoff.sh}"
RECOVERY_CMD="${OMC_INSTALL_READINESS_RECOVERY_CMD:-bash tests/test-install-recovery.sh}"
ONBOARDING_CMD="${OMC_INSTALL_READINESS_ONBOARDING_CMD:-bash tests/test-w4-onboarding.sh}"

SKIP_BOOTSTRAPPER=0
SKIP_HANDOFF=0
SKIP_RECOVERY=0
SKIP_ONBOARDING=0
JSON_MODE=0

ok_count=0
skip_count=0
fail_count=0
overall_rc=0
surfaces_json='[]'

usage() {
  cat <<'EOF'
Usage: bash tools/verify-install-readiness.sh [options]

Runs the canonical install/onboarding audit for oh-my-claude across the
first-run proof surfaces that matter for professional distribution.

Default surfaces:
  1. bootstrapper / canonical update path contract
  2. fresh-install handoff contract
  3. first-run recovery-path contract
  4. AI-assisted onboarding/install prompt contract

Options:
  --skip-bootstrapper   Skip bootstrapper / update-path coverage.
  --skip-handoff        Skip fresh-install handoff coverage.
  --skip-recovery       Skip first-run recovery-path coverage.
  --skip-onboarding     Skip AI-assisted onboarding-doc coverage.
  --json                Emit a machine-readable JSON report.
EOF
}

append_surface_json() {
  local name="$1"
  local status="$2"
  local summary="$3"
  local command="$4"
  local output="$5"
  local exit_code="$6"

  surfaces_json="$(
    jq -nc \
      --argjson arr "${surfaces_json}" \
      --arg name "${name}" \
      --arg status "${status}" \
      --arg summary "${summary}" \
      --arg command "${command}" \
      --arg output "${output}" \
      --argjson exit_code "${exit_code}" \
      '$arr + [{
        name: $name,
        status: $status,
        summary: $summary,
        command: $command,
        output: $output,
        exit_code: $exit_code
      }]'
  )"
}

last_nonempty_line() {
  local text="$1"
  awk 'NF { line=$0 } END { print line }' <<<"${text}"
}

summarize_command_output() {
  local text="$1"
  local last_line=""
  local pass_line=""
  local fail_line=""

  last_line="$(last_nonempty_line "${text}")"
  pass_line="$(awk '/^PASS:[[:space:]]*[0-9]+$/ { line=$0 } END { print line }' <<<"${text}")"
  fail_line="$(awk '/^FAIL:[[:space:]]*[0-9]+$/ { line=$0 } END { print line }' <<<"${text}")"

  if [[ -n "${pass_line}" && -n "${fail_line}" ]]; then
    printf '%s, %s' "${pass_line}" "${fail_line}"
    return 0
  fi

  printf '%s' "${last_line}"
}

record_skip() {
  local name="$1"
  local summary="$2"
  skip_count=$((skip_count + 1))
  append_surface_json "${name}" "SKIP" "${summary}" "" "" 0
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf 'SKIP\t%s\t%s\n' "${name}" "${summary}"
  fi
}

run_surface() {
  local name="$1"
  local command="$2"
  local output=""
  local summary=""
  local rc=0
  local status="OK"

  if output="$(cd "${REPO_ROOT}" && bash -lc "${command}" 2>&1)"; then
    rc=0
    ok_count=$((ok_count + 1))
  else
    rc=$?
    status="FAIL"
    fail_count=$((fail_count + 1))
    overall_rc=1
  fi

  summary="$(summarize_command_output "${output}")"
  if [[ -z "${summary}" ]]; then
    if [[ "${rc}" -eq 0 ]]; then
      summary="command completed without output"
    else
      summary="command exited ${rc} without output"
    fi
  fi

  append_surface_json "${name}" "${status}" "${summary}" "${command}" "${output}" "${rc}"

  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "${status}" "${name}" "${summary}"
    if [[ "${status}" == "FAIL" && -n "${output}" ]]; then
      printf '\n[%s]\n%s\n' "${name}" "${output}"
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-bootstrapper)
      SKIP_BOOTSTRAPPER=1
      shift
      ;;
    --skip-handoff)
      SKIP_HANDOFF=1
      shift
      ;;
    --skip-recovery)
      SKIP_RECOVERY=1
      shift
      ;;
    --skip-onboarding)
      SKIP_ONBOARDING=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'verify-install-readiness: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'verify-install-readiness: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${SKIP_BOOTSTRAPPER}" -eq 1 ]]; then
  record_skip "bootstrapper" "verify-install-readiness: bootstrapper audit skipped by caller"
else
  run_surface "bootstrapper" "${BOOTSTRAPPER_CMD}"
fi

if [[ "${SKIP_HANDOFF}" -eq 1 ]]; then
  record_skip "handoff" "verify-install-readiness: handoff audit skipped by caller"
else
  run_surface "handoff" "${HANDOFF_CMD}"
fi

if [[ "${SKIP_RECOVERY}" -eq 1 ]]; then
  record_skip "recovery" "verify-install-readiness: recovery audit skipped by caller"
else
  run_surface "recovery" "${RECOVERY_CMD}"
fi

if [[ "${SKIP_ONBOARDING}" -eq 1 ]]; then
  record_skip "onboarding" "verify-install-readiness: onboarding audit skipped by caller"
else
  run_surface "onboarding" "${ONBOARDING_CMD}"
fi

summary_text="verify-install-readiness: summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
message=""
if [[ "${fail_count}" -eq 0 && "${ok_count}" -gt 0 ]]; then
  message="verify-install-readiness: install/onboarding readiness is green across bootstrapper, handoff, recovery, and onboarding proof surfaces"
elif [[ "${ok_count}" -eq 0 && "${skip_count}" -gt 0 ]]; then
  message="verify-install-readiness: no install/onboarding surfaces were selected"
else
  message="verify-install-readiness: install/onboarding readiness has failing proof surfaces"
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -nc \
    --arg tool "verify-install-readiness" \
    --arg repo_root "${REPO_ROOT}" \
    --arg summary_text "${summary_text}" \
    --arg message "${message}" \
    --argjson ok_count "${ok_count}" \
    --argjson skip_count "${skip_count}" \
    --argjson fail_count "${fail_count}" \
    --argjson surfaces "${surfaces_json}" \
    '{
      tool: $tool,
      repo_root: $repo_root,
      result: (if $fail_count == 0 then "ok" else "fail" end),
      counts: {
        ok: $ok_count,
        skip: $skip_count,
        fail: $fail_count
      },
      summary_text: $summary_text,
      message: $message,
      surfaces: $surfaces
    }'
else
  printf '%s\n' "${summary_text}"
  printf '%s\n' "${message}"
fi

exit "${overall_rc}"
