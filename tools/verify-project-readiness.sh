#!/usr/bin/env bash
#
# tools/verify-project-readiness.sh — top-level maintainer audit that
# composes product-readiness, install/onboarding readiness, and
# distribution-readiness into one canonical release-candidate view.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFESSIONAL_READINESS_CMD="${OMC_PROJECT_READINESS_PROFESSIONAL_CMD:-bash tools/verify-professional-readiness.sh}"
INSTALL_READINESS_CMD="${OMC_PROJECT_READINESS_INSTALL_CMD:-bash tools/verify-install-readiness.sh}"
DISTRIBUTION_READINESS_CMD="${OMC_PROJECT_READINESS_DISTRIBUTION_CMD:-bash tools/verify-distribution-readiness.sh}"

REPO_OVERRIDE=""
REMOTE_NAME="origin"
REMOTE_REF=""
LOCAL_REF="WORKTREE"
ALLOW_EXTRA_STAGED=0
FETCH_REMOTE=0
RELEASE_VERSION=""
RELEASE_SHA=""
HISTORY_LIMIT=""
CURRENT_ATTESTATIONS_MODE=""
HISTORY_ATTESTATIONS_MODE=""
TRIGGER_ATTESTATIONS_IF_MISSING=0
ATTESTATION_POLL_ATTEMPTS=""
ATTESTATION_POLL_INTERVAL=""
ATTESTATION_RUN_LIMIT=""
PAIRWISE_RECEIPTS=()
PAIRWISE_CAMPAIGN_RECEIPT=""
SKIP_PROFESSIONAL=0
SKIP_INSTALL=0
SKIP_DISTRIBUTION=0
SKIP_DEPLOYMENT=0
SKIP_CURRENT_RELEASE=0
SKIP_HISTORY=0
JSON_MODE=0

ok_count=0
skip_count=0
fail_count=0
overall_rc=0
surfaces_json='[]'
LAST_SURFACE_STATUS=""
LAST_SURFACE_SUMMARY=""
LAST_SURFACE_OUTPUT=""
professional_surface_status="SKIP"
install_surface_status="SKIP"
distribution_surface_status="SKIP"
distribution_surface_output=""

usage() {
  cat <<'EOF'
Usage: bash tools/verify-project-readiness.sh [options]

Runs the canonical top-level maintainer audit for oh-my-claude by
combining:
  1. product readiness for professional users across coding, writing,
     research, scholarly, operations, mixed, advisory, and general
     workflows
  2. install/onboarding readiness across the bootstrapper, first-run
     handoff, recovery, and AI-assisted onboarding surfaces
  3. distribution readiness of the published release surface, the
     local deployment candidate, and the deployed
     release/distribution automation stack

Options:
  --repo <owner/name>               Passed through to the distribution
                                    readiness surface.
  --remote <name>                   Passed through to distribution
                                    deployment audit. Default: origin.
  --remote-ref <ref>                Passed through to distribution audit.
  --local-ref <ref>                 Passed through to distribution audit.
  --allow-extra-staged             Passed through to distribution audit.
  --fetch                           Passed through to distribution audit.
  --release-version <X.Y.Z>         Passed through to distribution audit.
  --release-sha <commit-sha>        Passed through to distribution audit.
  --history-limit <N>               Passed through to distribution audit.
  --current-attestations <mode>     skip|verify|wait for current release.
  --history-attestations <mode>     skip|verify|wait for history audit.
  --trigger-attestations-if-missing Passed through to distribution audit.
  --attestation-poll-attempts <N>   Passed through to distribution audit.
  --attestation-poll-interval <N>   Passed through to distribution audit.
  --attestation-run-limit <N>       Passed through to distribution audit.
  --pairwise-receipt <file>         Pass one sealed schema-v7 causal-generation
                                    pair receipt to the professional claim gate.
                                    Repeat per pair.
  --pairwise-campaign-receipt <file>
                                    Pass the single sealed campaign receipt that
                                    binds the complete first-attempt roster.
  --skip-professional               Skip the product-readiness surface.
  --skip-install                    Skip the install/onboarding surface.
  --skip-distribution               Skip the distribution-readiness surface.
  --skip-deployment                 Passed through to distribution audit.
  --skip-current-release            Passed through to distribution audit.
  --skip-history                    Passed through to distribution audit.
  --json                            Emit a machine-readable JSON report.
EOF
}

append_surface_json() {
  local name="$1"
  local status="$2"
  local summary="$3"
  local command="$4"
  local output="$5"
  local exit_code="$6"

  if [[ -n "${output}" ]] && printf '%s' "${output}" | jq -e . >/dev/null 2>&1; then
    surfaces_json="$(
      jq -nc \
        --argjson arr "${surfaces_json}" \
        --arg name "${name}" \
        --arg status "${status}" \
        --arg summary "${summary}" \
        --arg command "${command}" \
        --argjson details "${output}" \
        --argjson exit_code "${exit_code}" \
        '$arr + [{
          name: $name,
          status: $status,
          summary: $summary,
          command: $command,
          details: $details,
          exit_code: $exit_code
        }]'
    )"
  else
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
          raw_output: (if $output == "" then null else $output end),
          exit_code: $exit_code
        }]'
    )"
  fi
}

last_nonempty_line() {
  local text="$1"
  awk 'NF { line=$0 } END { print line }' <<<"${text}"
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
    LAST_SURFACE_STATUS="OK"
  else
    rc=$?
    status="FAIL"
    fail_count=$((fail_count + 1))
    overall_rc=1
    LAST_SURFACE_STATUS="FAIL"
  fi

  if [[ -n "${output}" ]] && printf '%s' "${output}" | jq -e . >/dev/null 2>&1; then
    summary="$(printf '%s' "${output}" | jq -r '.summary_text // .message // empty' 2>/dev/null || true)"
  else
    summary="$(last_nonempty_line "${output}")"
  fi
  if [[ -z "${summary}" ]]; then
    if [[ "${rc}" -eq 0 ]]; then
      summary="command completed without output"
    else
      summary="command exited ${rc} without output"
    fi
  fi

  append_surface_json "${name}" "${status}" "${summary}" "${command}" "${output}" "${rc}"
  LAST_SURFACE_SUMMARY="${summary}"
  LAST_SURFACE_OUTPUT="${output}"

  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "${status}" "${name}" "${summary}"
    if [[ "${status}" == "FAIL" && -n "${output}" ]]; then
      printf '\n[%s]\n%s\n' "${name}" "${output}"
    fi
  fi
}

distribution_cmd() {
  local cmd="${DISTRIBUTION_READINESS_CMD}"

  if [[ -n "${REPO_OVERRIDE}" ]]; then
    cmd+=" --repo $(printf '%q' "${REPO_OVERRIDE}")"
  fi
  if [[ -n "${REMOTE_NAME}" ]]; then
    cmd+=" --remote $(printf '%q' "${REMOTE_NAME}")"
  fi
  if [[ -n "${REMOTE_REF}" ]]; then
    cmd+=" --remote-ref $(printf '%q' "${REMOTE_REF}")"
  fi
  if [[ -n "${LOCAL_REF}" ]]; then
    cmd+=" --local-ref $(printf '%q' "${LOCAL_REF}")"
  fi
  if [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]]; then
    cmd+=" --allow-extra-staged"
  fi
  if [[ "${FETCH_REMOTE}" -eq 1 ]]; then
    cmd+=" --fetch"
  fi
  if [[ -n "${RELEASE_VERSION}" ]]; then
    cmd+=" --release-version $(printf '%q' "${RELEASE_VERSION}")"
  fi
  if [[ -n "${RELEASE_SHA}" ]]; then
    cmd+=" --release-sha $(printf '%q' "${RELEASE_SHA}")"
  fi
  if [[ -n "${HISTORY_LIMIT}" ]]; then
    cmd+=" --history-limit $(printf '%q' "${HISTORY_LIMIT}")"
  fi
  if [[ -n "${CURRENT_ATTESTATIONS_MODE}" ]]; then
    cmd+=" --current-attestations $(printf '%q' "${CURRENT_ATTESTATIONS_MODE}")"
  fi
  if [[ -n "${HISTORY_ATTESTATIONS_MODE}" ]]; then
    cmd+=" --history-attestations $(printf '%q' "${HISTORY_ATTESTATIONS_MODE}")"
  fi
  if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 ]]; then
    cmd+=" --trigger-attestations-if-missing"
  fi
  if [[ -n "${ATTESTATION_POLL_ATTEMPTS}" ]]; then
    cmd+=" --attestation-poll-attempts $(printf '%q' "${ATTESTATION_POLL_ATTEMPTS}")"
  fi
  if [[ -n "${ATTESTATION_POLL_INTERVAL}" ]]; then
    cmd+=" --attestation-poll-interval $(printf '%q' "${ATTESTATION_POLL_INTERVAL}")"
  fi
  if [[ -n "${ATTESTATION_RUN_LIMIT}" ]]; then
    cmd+=" --attestation-run-limit $(printf '%q' "${ATTESTATION_RUN_LIMIT}")"
  fi
  if [[ "${SKIP_DEPLOYMENT}" -eq 1 ]]; then
    cmd+=" --skip-deployment"
  fi
  if [[ "${SKIP_CURRENT_RELEASE}" -eq 1 ]]; then
    cmd+=" --skip-current-release"
  fi
  if [[ "${SKIP_HISTORY}" -eq 1 ]]; then
    cmd+=" --skip-history"
  fi
  if [[ "${JSON_MODE}" -eq 1 ]]; then
    cmd+=" --json"
  fi

  printf '%s' "${cmd}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --remote)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REMOTE_NAME="$2"
      shift 2
      ;;
    --remote-ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REMOTE_REF="$2"
      shift 2
      ;;
    --local-ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      LOCAL_REF="$2"
      shift 2
      ;;
    --allow-extra-staged)
      ALLOW_EXTRA_STAGED=1
      shift
      ;;
    --fetch)
      FETCH_REMOTE=1
      shift
      ;;
    --release-version)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --release-sha)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      RELEASE_SHA="$2"
      shift 2
      ;;
    --history-limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      HISTORY_LIMIT="$2"
      shift 2
      ;;
    --current-attestations)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CURRENT_ATTESTATIONS_MODE="$2"
      shift 2
      ;;
    --history-attestations)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      HISTORY_ATTESTATIONS_MODE="$2"
      shift 2
      ;;
    --trigger-attestations-if-missing)
      TRIGGER_ATTESTATIONS_IF_MISSING=1
      shift
      ;;
    --attestation-poll-attempts)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATION_POLL_ATTEMPTS="$2"
      shift 2
      ;;
    --attestation-poll-interval)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATION_POLL_INTERVAL="$2"
      shift 2
      ;;
    --attestation-run-limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATION_RUN_LIMIT="$2"
      shift 2
      ;;
    --pairwise-receipt)
      [[ $# -ge 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
      PAIRWISE_RECEIPTS+=("$2")
      shift 2
      ;;
    --pairwise-campaign-receipt)
      [[ $# -ge 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
      [[ -z "${PAIRWISE_CAMPAIGN_RECEIPT}" ]] || {
        printf 'verify-project-readiness: --pairwise-campaign-receipt may be supplied only once\n' >&2
        exit 2
      }
      PAIRWISE_CAMPAIGN_RECEIPT="$2"
      shift 2
      ;;
    --pairwise-report)
      printf 'verify-project-readiness: aggregate reports are not evidence; pass raw --pairwise-receipt files\n' >&2
      exit 2
      ;;
    --skip-professional)
      SKIP_PROFESSIONAL=1
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --skip-distribution)
      SKIP_DISTRIBUTION=1
      shift
      ;;
    --skip-deployment)
      SKIP_DEPLOYMENT=1
      shift
      ;;
    --skip-current-release)
      SKIP_CURRENT_RELEASE=1
      shift
      ;;
    --skip-history)
      SKIP_HISTORY=1
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
      printf 'verify-project-readiness: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'verify-project-readiness: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 && -z "${PAIRWISE_CAMPAIGN_RECEIPT}" ]]; then
  printf 'verify-project-readiness: raw --pairwise-receipt evidence requires --pairwise-campaign-receipt\n' >&2
  exit 2
fi
if [[ "${#PAIRWISE_RECEIPTS[@]}" -eq 0 && -n "${PAIRWISE_CAMPAIGN_RECEIPT}" ]]; then
  printf 'verify-project-readiness: --pairwise-campaign-receipt requires at least one --pairwise-receipt\n' >&2
  exit 2
fi

if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 ]]; then
  [[ "${SKIP_PROFESSIONAL}" -eq 0 ]] || {
    printf 'verify-project-readiness: pairwise receipt evidence cannot be combined with --skip-professional\n' >&2
    exit 2
  }
  for pairwise_index in "${!PAIRWISE_RECEIPTS[@]}"; do
    pairwise_receipt="${PAIRWISE_RECEIPTS[$pairwise_index]}"
    [[ -f "${pairwise_receipt}" ]] || {
      printf 'verify-project-readiness: pairwise receipt not found: %s\n' "${pairwise_receipt}" >&2
      exit 2
    }
    PAIRWISE_RECEIPTS[pairwise_index]="$(cd "$(dirname "${pairwise_receipt}")" && pwd -P)/$(basename "${pairwise_receipt}")"
  done
  [[ -f "${PAIRWISE_CAMPAIGN_RECEIPT}" ]] || {
    printf 'verify-project-readiness: pairwise campaign receipt not found: %s\n' \
      "${PAIRWISE_CAMPAIGN_RECEIPT}" >&2
    exit 2
  }
  PAIRWISE_CAMPAIGN_RECEIPT="$(cd "$(dirname "${PAIRWISE_CAMPAIGN_RECEIPT}")" \
    && pwd -P)/$(basename "${PAIRWISE_CAMPAIGN_RECEIPT}")"
fi

if [[ "${SKIP_PROFESSIONAL}" -eq 1 ]]; then
  record_skip "professional" "verify-project-readiness: professional-readiness audit skipped by caller"
else
  professional_cmd="${PROFESSIONAL_READINESS_CMD}"
  if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 ]]; then
    for pairwise_receipt in "${PAIRWISE_RECEIPTS[@]}"; do
      professional_cmd+=" --pairwise-receipt $(printf '%q' "${pairwise_receipt}")"
    done
    professional_cmd+=" --pairwise-campaign-receipt $(printf '%q' "${PAIRWISE_CAMPAIGN_RECEIPT}")"
  fi
  if [[ "${JSON_MODE}" -eq 1 ]]; then
    professional_cmd+=" --json"
  fi
  run_surface "professional" "${professional_cmd}"
  professional_surface_status="${LAST_SURFACE_STATUS}"
fi

if [[ "${SKIP_INSTALL}" -eq 1 ]]; then
  record_skip "install" "verify-project-readiness: install-readiness audit skipped by caller"
else
  install_cmd="${INSTALL_READINESS_CMD}"
  if [[ "${JSON_MODE}" -eq 1 ]]; then
    install_cmd+=" --json"
  fi
  run_surface "install" "${install_cmd}"
  install_surface_status="${LAST_SURFACE_STATUS}"
fi

if [[ "${SKIP_DISTRIBUTION}" -eq 1 ]]; then
  record_skip "distribution" "verify-project-readiness: distribution-readiness audit skipped by caller"
else
  run_surface "distribution" "$(distribution_cmd)"
  distribution_surface_status="${LAST_SURFACE_STATUS}"
  distribution_surface_output="${LAST_SURFACE_OUTPUT}"
fi

summary_text="verify-project-readiness: summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
if [[ "${fail_count}" -eq 0 && "${ok_count}" -gt 0 ]]; then
  message="verify-project-readiness: project is green across professional, install, and distribution readiness surfaces"
elif [[ "${ok_count}" -eq 0 && "${skip_count}" -gt 0 ]]; then
  message="verify-project-readiness: no readiness surfaces were selected"
elif [[ "${fail_count}" -eq 1 && "${professional_surface_status}" == "OK" && "${install_surface_status}" == "OK" && "${distribution_surface_status}" == "FAIL" ]]; then
  distribution_message=""
  if [[ -n "${distribution_surface_output}" ]] && printf '%s' "${distribution_surface_output}" | jq -e . >/dev/null 2>&1; then
    distribution_message="$(printf '%s' "${distribution_surface_output}" | jq -r '.message // empty' 2>/dev/null || true)"
  else
    distribution_message="$(printf '%s' "${distribution_surface_output}" | grep -F 'local deployment candidate is coherent' | tail -1 || true)"
  fi
  if [[ "${distribution_message}" == *"local deployment candidate is coherent"* ]]; then
    message="verify-project-readiness: professional and install readiness are green; remaining blocker is remote deployment while the local distribution candidate is coherent"
  else
    message="verify-project-readiness: project readiness has failing surfaces"
  fi
else
  message="verify-project-readiness: project readiness has failing surfaces"
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -nc \
    --arg tool "verify-project-readiness" \
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
