#!/usr/bin/env bash
#
# tools/verify-distribution-readiness.sh — top-level distribution
# readiness audit across deployment state, local deployment-candidate
# state, current published release, and recent published release
# history.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOYMENT_VERIFIER="${SCRIPT_DIR}/verify-release-automation-deployment.sh"
DEPLOYMENT_CANDIDATE_HELPER="${SCRIPT_DIR}/prepare-release-automation-deployment.sh"
PUBLISHED_RELEASE_VERIFIER="${SCRIPT_DIR}/verify-published-release.sh"
PUBLISHED_HISTORY_AUDITOR="${SCRIPT_DIR}/audit-published-releases.sh"

REPO_OVERRIDE=""
REMOTE_NAME="origin"
REMOTE_REF=""
LOCAL_REF="WORKTREE"
ALLOW_EXTRA_STAGED=0
FETCH_REMOTE=0
RELEASE_VERSION=""
RELEASE_SHA=""
HISTORY_LIMIT=10
CURRENT_ATTESTATIONS_MODE="verify"
HISTORY_ATTESTATIONS_MODE="skip"
TRIGGER_ATTESTATIONS_IF_MISSING=0
ATTESTATION_POLL_ATTEMPTS=""
ATTESTATION_POLL_INTERVAL=""
ATTESTATION_RUN_LIMIT=""
SKIP_DEPLOYMENT=0
SKIP_CURRENT_RELEASE=0
SKIP_HISTORY=0
JSON_MODE=0

usage() {
  cat <<'EOF'
Usage: bash tools/verify-distribution-readiness.sh [options]

Runs the canonical distribution-readiness audit for oh-my-claude by
composing four top-level surfaces:
  1. deployment readiness of release/distribution automation on the
     remote default branch
  2. local deployment-candidate coherence for the pending pre-push
     release/distribution change-set
  3. current published release correctness/provenance
  4. recent published release history health

Defaults are chosen for routine maintainer use:
  - deployment audit enabled
  - current release attestations verified live
  - history audited over the latest 10 releases with attestation checks
    skipped by default for speed (deployment/current-release surfaces
    already prove the active provenance path)

Options:
  --repo <owner/name>               GitHub repo slug for published-release
                                    checks. Defaults to current gh repo.
  --remote <name>                   Git remote for deployment audit.
                                    Default: origin.
  --remote-ref <ref>                Override the deployment ref explicitly.
  --local-ref <ref>                 Local source ref for deployment audit.
                                    Default: WORKTREE. Special values
                                    `WORKTREE` and `INDEX`/`STAGED`
                                    pass through to the deployment
                                    verifier for worktree-vs-staged
                                    comparison.
  --allow-extra-staged             Pass through the explicit staged-index
                                    escape hatch when you intentionally
                                    audit a wider staged commit than the
                                    canonical release/distribution surface.
  --fetch                           Fetch the git remote before comparing.
  --release-version <X.Y.Z>         Published release version to verify.
                                    Default: contents of VERSION.
  --release-sha <commit-sha>        Trusted release commit for the current
                                    published release verifier.
  --history-limit <N>               Number of published releases to audit in
                                    the history phase. Default: 10.
  --current-attestations <mode>     skip|verify|wait for the current release.
                                    Default: verify.
  --history-attestations <mode>     skip|verify|wait for history audit.
                                    Default: skip.
  --trigger-attestations-if-missing If any attestation mode is wait,
                                    dispatch the signer workflow when absent.
  --attestation-poll-attempts <N>   Passed through to wait-mode attestation
                                    helpers.
  --attestation-poll-interval <N>   Passed through to wait-mode attestation
                                    helpers.
  --attestation-run-limit <N>       Passed through to wait-mode attestation
                                    helpers.
  --skip-deployment                 Skip the deployment audit surface and
                                    the linked local deployment-candidate
                                    audit surface.
  --skip-current-release            Skip the current published-release audit.
  --skip-history                    Skip the recent release-history audit.
  --json                            Emit a machine-readable JSON report
                                    instead of the human text summary.
EOF
}

err() { printf 'verify-distribution-readiness: %s\n' "$1" >&2; exit 1; }
note() { printf 'verify-distribution-readiness: %s\n' "$1"; }

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
      printf 'verify-distribution-readiness: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'verify-distribution-readiness: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "${HISTORY_LIMIT}" =~ ^[1-9][0-9]*$ ]] || err "--history-limit must be a positive integer, got: ${HISTORY_LIMIT}"
for mode_spec in \
  "current:${CURRENT_ATTESTATIONS_MODE}" \
  "history:${HISTORY_ATTESTATIONS_MODE}"; do
  surface="${mode_spec%%:*}"
  mode="${mode_spec#*:}"
  case "${mode}" in
    skip|verify|wait) ;;
    *) err "--${surface}-attestations must be one of: skip, verify, wait (got: ${mode})" ;;
  esac
done
if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 ]]; then
  if [[ "${CURRENT_ATTESTATIONS_MODE}" != "wait" && "${HISTORY_ATTESTATIONS_MODE}" != "wait" ]]; then
    err "--trigger-attestations-if-missing requires at least one attestation mode set to wait"
  fi
fi
for waiter_opt in \
  "--attestation-poll-attempts:${ATTESTATION_POLL_ATTEMPTS}" \
  "--attestation-poll-interval:${ATTESTATION_POLL_INTERVAL}" \
  "--attestation-run-limit:${ATTESTATION_RUN_LIMIT}"; do
  cli_name="${waiter_opt%%:*}"
  opt_value="${waiter_opt#*:}"
  if [[ -n "${opt_value}" ]]; then
    if [[ "${CURRENT_ATTESTATIONS_MODE}" != "wait" && "${HISTORY_ATTESTATIONS_MODE}" != "wait" ]]; then
      err "${cli_name} requires at least one attestation mode set to wait"
    fi
    [[ "${opt_value}" =~ ^[1-9][0-9]*$ ]] || err "${cli_name} must be a positive integer, got: ${opt_value}"
  fi
done

command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
if [[ "${JSON_MODE}" -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || err "jq is required for --json"
fi
[[ -x "${DEPLOYMENT_VERIFIER}" ]] || err "deployment verifier missing: ${DEPLOYMENT_VERIFIER}"
[[ -x "${DEPLOYMENT_CANDIDATE_HELPER}" ]] || err "deployment candidate helper missing: ${DEPLOYMENT_CANDIDATE_HELPER}"
[[ -x "${PUBLISHED_RELEASE_VERIFIER}" ]] || err "published release verifier missing: ${PUBLISHED_RELEASE_VERIFIER}"
[[ -x "${PUBLISHED_HISTORY_AUDITOR}" ]] || err "published history auditor missing: ${PUBLISHED_HISTORY_AUDITOR}"

if [[ -z "${RELEASE_VERSION}" ]]; then
  [[ -f VERSION ]] || err "VERSION file not found; pass --release-version <X.Y.Z>"
  RELEASE_VERSION="$(tr -d '[:space:]' < VERSION)"
fi
[[ "${RELEASE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "release version must be X.Y.Z, got: ${RELEASE_VERSION}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

declare -a FAILED_SURFACES=()
declare -a FAILED_OUTPUTS=()

ok_count=0
skip_count=0
fail_count=0
tmp_dir=""
surfaces_file=""
LAST_SURFACE_STATUS=""
LAST_SURFACE_SUMMARY=""
LAST_SURFACE_OUTPUT=""
deployment_surface_status="SKIP"
deployment_candidate_surface_status="SKIP"
current_release_surface_status="SKIP"
history_surface_status="SKIP"

if [[ "${JSON_MODE}" -eq 1 ]]; then
  tmp_dir="$(mktemp -d -t omc-distribution-readiness-XXXXXX)"
  surfaces_file="${tmp_dir}/surfaces.jsonl"
  cleanup() { rm -rf "${tmp_dir}"; }
  trap cleanup EXIT
fi

record_surface_text() {
  local label="$1"
  local status="$2"
  local summary="$3"
  printf '%s\t%s\t%s\n' "${status}" "${label}" "${summary}"
}

record_surface_json() {
  local label="$1"
  local status="$2"
  local summary="$3"
  local raw="$4"

  if [[ -n "${raw}" ]] && printf '%s' "${raw}" | jq -e . >/dev/null 2>&1; then
    jq -nc \
      --arg name "${label}" \
      --arg status "${status}" \
      --arg summary "${summary}" \
      --argjson details "${raw}" \
      '{name: $name, status: $status, summary: $summary, details: $details}' >> "${surfaces_file}"
  else
    jq -nc \
      --arg name "${label}" \
      --arg status "${status}" \
      --arg summary "${summary}" \
      --arg raw_output "${raw}" \
      '{name: $name, status: $status, summary: $summary, details: null, raw_output: (if $raw_output == "" then null else $raw_output end)}' >> "${surfaces_file}"
  fi
}

run_surface_text() {
  local label="$1"
  shift
  local out summary
  if out="$("$@" 2>&1)"; then
    summary="$(printf '%s\n' "${out}" | tail -1)"
    record_surface_text "${label}" "OK" "${summary}"
    ok_count=$((ok_count + 1))
    LAST_SURFACE_STATUS="OK"
  else
    summary="$(printf '%s\n' "${out}" | grep -F 'summary:' | tail -1 || true)"
    [[ -n "${summary}" ]] || summary="$(printf '%s\n' "${out}" | head -1)"
    record_surface_text "${label}" "FAIL" "${summary}" >&2
    FAILED_SURFACES+=("${label}")
    FAILED_OUTPUTS+=("${out}")
    fail_count=$((fail_count + 1))
    LAST_SURFACE_STATUS="FAIL"
  fi
  LAST_SURFACE_SUMMARY="${summary}"
  LAST_SURFACE_OUTPUT="${out}"
}

run_surface_json() {
  local label="$1"
  shift
  local out summary

  if out="$("$@")"; then
    summary="$(printf '%s' "${out}" | jq -r '.summary_text // .message // empty' 2>/dev/null || true)"
    [[ -n "${summary}" ]] || summary="${label}: ok"
    record_surface_json "${label}" "OK" "${summary}" "${out}"
    ok_count=$((ok_count + 1))
    LAST_SURFACE_STATUS="OK"
  else
    summary="$(printf '%s' "${out}" | jq -r '.summary_text // .message // empty' 2>/dev/null || true)"
    [[ -n "${summary}" ]] || summary="${label}: failed"
    record_surface_json "${label}" "FAIL" "${summary}" "${out}"
    fail_count=$((fail_count + 1))
    LAST_SURFACE_STATUS="FAIL"
  fi
  LAST_SURFACE_SUMMARY="${summary}"
  LAST_SURFACE_OUTPUT="${out}"
}

append_wait_args() {
  local array_name="$1"
  local mode="$2"
  if [[ "${mode}" != "wait" ]]; then
    return
  fi
  if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 ]]; then
    eval "${array_name}+=(\"--trigger-attestations-if-missing\")"
  fi
  if [[ -n "${ATTESTATION_POLL_ATTEMPTS}" ]]; then
    eval "${array_name}+=(\"--attestation-poll-attempts\" \"${ATTESTATION_POLL_ATTEMPTS}\")"
  fi
  if [[ -n "${ATTESTATION_POLL_INTERVAL}" ]]; then
    eval "${array_name}+=(\"--attestation-poll-interval\" \"${ATTESTATION_POLL_INTERVAL}\")"
  fi
  if [[ -n "${ATTESTATION_RUN_LIMIT}" ]]; then
    eval "${array_name}+=(\"--attestation-run-limit\" \"${ATTESTATION_RUN_LIMIT}\")"
  fi
}

current_wait_args=()
history_wait_args=()
append_wait_args current_wait_args "${CURRENT_ATTESTATIONS_MODE}"
append_wait_args history_wait_args "${HISTORY_ATTESTATIONS_MODE}"

if [[ "${SKIP_DEPLOYMENT}" -eq 1 ]]; then
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    record_surface_text "deployment" "SKIP" "verify-distribution-readiness: deployment audit skipped by caller"
    record_surface_text "deployment_candidate" "SKIP" "verify-distribution-readiness: deployment-candidate audit skipped because deployment was skipped by caller"
  else
    record_surface_json "deployment" "SKIP" "verify-distribution-readiness: deployment audit skipped by caller" ""
    record_surface_json "deployment_candidate" "SKIP" "verify-distribution-readiness: deployment-candidate audit skipped because deployment was skipped by caller" ""
  fi
  skip_count=$((skip_count + 2))
else
  deployment_args=("--remote" "${REMOTE_NAME}")
  if [[ -n "${REMOTE_REF}" ]]; then
    deployment_args+=("--remote-ref" "${REMOTE_REF}")
  fi
  if [[ -n "${LOCAL_REF}" ]]; then
    deployment_args+=("--local-ref" "${LOCAL_REF}")
  fi
  if [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]]; then
    deployment_args+=("--allow-extra-staged")
  fi
  if [[ "${FETCH_REMOTE}" -eq 1 ]]; then
    deployment_args+=("--fetch")
  fi
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    run_surface_text "deployment" bash "${DEPLOYMENT_VERIFIER}" "${deployment_args[@]}"
  else
    deployment_args+=("--json")
    run_surface_json "deployment" bash "${DEPLOYMENT_VERIFIER}" "${deployment_args[@]}"
  fi
  deployment_surface_status="${LAST_SURFACE_STATUS}"

  candidate_args=("--remote" "${REMOTE_NAME}" "--dry-run")
  if [[ -n "${REMOTE_REF}" ]]; then
    candidate_args+=("--remote-ref" "${REMOTE_REF}")
  fi
  if [[ "${FETCH_REMOTE}" -eq 1 ]]; then
    candidate_args+=("--fetch")
  fi
  if [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]]; then
    candidate_args+=("--allow-extra-staged")
  fi
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    run_surface_text "deployment_candidate" bash "${DEPLOYMENT_CANDIDATE_HELPER}" "${candidate_args[@]}"
  else
    candidate_args+=("--json")
    run_surface_json "deployment_candidate" bash "${DEPLOYMENT_CANDIDATE_HELPER}" "${candidate_args[@]}"
  fi
  deployment_candidate_surface_status="${LAST_SURFACE_STATUS}"
fi

if [[ "${SKIP_CURRENT_RELEASE}" -eq 1 ]]; then
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    record_surface_text "current_release" "SKIP" "verify-distribution-readiness: current release audit skipped by caller"
  else
    record_surface_json "current_release" "SKIP" "verify-distribution-readiness: current release audit skipped by caller" ""
  fi
  skip_count=$((skip_count + 1))
else
  release_args=("${RELEASE_VERSION}" "--repo" "${REPO_SLUG}" "--attestations" "${CURRENT_ATTESTATIONS_MODE}")
  if [[ -n "${RELEASE_SHA}" ]]; then
    release_args+=("--sha" "${RELEASE_SHA}")
  fi
  if [[ "${#current_wait_args[@]}" -gt 0 ]]; then
    release_args+=("${current_wait_args[@]}")
  fi
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    run_surface_text "current_release" bash "${PUBLISHED_RELEASE_VERIFIER}" "${release_args[@]}"
  else
    release_args+=("--json")
    run_surface_json "current_release" bash "${PUBLISHED_RELEASE_VERIFIER}" "${release_args[@]}"
  fi
  current_release_surface_status="${LAST_SURFACE_STATUS}"
fi

if [[ "${SKIP_HISTORY}" -eq 1 ]]; then
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    record_surface_text "history" "SKIP" "verify-distribution-readiness: release history audit skipped by caller"
  else
    record_surface_json "history" "SKIP" "verify-distribution-readiness: release history audit skipped by caller" ""
  fi
  skip_count=$((skip_count + 1))
else
  history_args=("--repo" "${REPO_SLUG}" "--limit" "${HISTORY_LIMIT}" "--attestations" "${HISTORY_ATTESTATIONS_MODE}")
  if [[ "${#history_wait_args[@]}" -gt 0 ]]; then
    history_args+=("${history_wait_args[@]}")
  fi
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    run_surface_text "history" bash "${PUBLISHED_HISTORY_AUDITOR}" "${history_args[@]}"
  else
    history_args+=("--json")
    run_surface_json "history" bash "${PUBLISHED_HISTORY_AUDITOR}" "${history_args[@]}"
  fi
  history_surface_status="${LAST_SURFACE_STATUS}"
fi

summary_text="verify-distribution-readiness: summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
message=""
if [[ "${fail_count}" -eq 0 ]]; then
  message="verify-distribution-readiness: distribution readiness is green for ${REPO_SLUG}"
elif [[ "${deployment_surface_status}" == "FAIL" && "${deployment_candidate_surface_status}" == "OK" && "${current_release_surface_status}" != "FAIL" && "${history_surface_status}" != "FAIL" ]]; then
  message="verify-distribution-readiness: remote deployment is behind, but the local deployment candidate is coherent for ${REPO_SLUG}"
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -n \
    --arg repo "${REPO_SLUG}" \
    --arg remote "${REMOTE_NAME}" \
    --arg remote_ref "${REMOTE_REF}" \
    --arg local_ref "${LOCAL_REF}" \
    --arg release_version "${RELEASE_VERSION}" \
    --arg release_sha "${RELEASE_SHA}" \
    --arg current_attestations_mode "${CURRENT_ATTESTATIONS_MODE}" \
    --arg history_attestations_mode "${HISTORY_ATTESTATIONS_MODE}" \
    --arg summary_text "${summary_text}" \
    --arg message "${message}" \
    --argjson allow_extra_staged "$( [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson fetched "$( [[ "${FETCH_REMOTE}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson history_limit "${HISTORY_LIMIT}" \
    --argjson trigger_attestations_if_missing "$( [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson ok_count "${ok_count}" \
    --argjson skip_count "${skip_count}" \
    --argjson fail_count "${fail_count}" \
    --slurpfile surfaces "${surfaces_file}" \
    '{
      tool: "verify-distribution-readiness",
      repo: $repo,
      remote: $remote,
      remote_ref: (if $remote_ref == "" then null else $remote_ref end),
      local_ref: $local_ref,
      allow_extra_staged: $allow_extra_staged,
      fetched: $fetched,
      release_version: $release_version,
      release_sha: (if $release_sha == "" then null else $release_sha end),
      history_limit: $history_limit,
      current_attestations_mode: $current_attestations_mode,
      history_attestations_mode: $history_attestations_mode,
      trigger_attestations_if_missing: $trigger_attestations_if_missing,
      result: (if $fail_count == 0 then "ok" else "fail" end),
      counts: {
        ok: $ok_count,
        skip: $skip_count,
        fail: $fail_count
      },
      summary_text: $summary_text,
      message: (if $message == "" then null else $message end),
      surfaces: $surfaces
    }'
  [[ "${fail_count}" -eq 0 ]]
  exit $?
fi

note "summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
if [[ -n "${message}" && "${fail_count}" -ne 0 ]]; then
  printf '%s\n' "${message}"
fi

if [[ "${fail_count}" -ne 0 ]]; then
  for i in "${!FAILED_SURFACES[@]}"; do
    printf '\n[%s]\n%s\n' "${FAILED_SURFACES[$i]}" "${FAILED_OUTPUTS[$i]}" >&2
  done
  exit 1
fi

note "distribution readiness is green for ${REPO_SLUG}"
