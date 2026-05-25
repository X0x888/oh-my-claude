#!/usr/bin/env bash
#
# tools/verify-published-release.sh — verify a published GitHub release
# end to end against the canonical title/body/state/assets/attestation
# contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TITLE_VERIFIER="${SCRIPT_DIR}/verify-published-release-title.sh"
BODY_VERIFIER="${SCRIPT_DIR}/verify-published-release-body.sh"
STATE_VERIFIER="${SCRIPT_DIR}/verify-published-release-state.sh"
ASSET_VERIFIER="${SCRIPT_DIR}/verify-published-release-assets.sh"
ATTESTATION_VERIFIER="${SCRIPT_DIR}/verify-published-release-attestations.sh"
ATTESTATION_WAITER="${SCRIPT_DIR}/wait-for-release-attestations.sh"

VERSION_ARG=""
REPO_OVERRIDE=""
SHA_OVERRIDE=""
FIX=0
ATTESTATIONS_MODE="verify"
TRIGGER_ATTESTATIONS_IF_MISSING=0
ATTESTATION_POLL_ATTEMPTS=""
ATTESTATION_POLL_INTERVAL=""
ATTESTATION_RUN_LIMIT=""
JSON_MODE=0

usage() {
  cat <<'EOF'
Usage: bash tools/verify-published-release.sh X.Y.Z [options]

Verifies a published GitHub release end to end against the canonical
release contract:
  - title
  - body
  - published state
  - attached source bundles + checksum manifest
  - asset attestations

Options:
  --repo <owner/name>               Override the GitHub repo slug. Defaults
                                    to the current gh repo.
  --sha <commit-sha>                Override the trusted release commit used
                                    by the body verifier.
  --fix                             Repair title/body/state/assets drift in
                                    place before re-verifying them.
  --attestations <skip|verify|wait> Control the attestation phase:
                                      skip   = do not inspect attestations
                                      verify = require live attestations now
                                      wait   = wait for or dispatch the signer
                                               workflow, then verify
                                    Default: verify
  --trigger-attestations-if-missing Only valid with --attestations wait.
                                    Dispatch the attestation workflow if no
                                    matching run is registered yet.
  --attestation-poll-attempts <N>   Only valid with --attestations wait.
                                    Passed through to
                                    wait-for-release-attestations.sh.
  --attestation-poll-interval <N>   Only valid with --attestations wait.
                                    Passed through to
                                    wait-for-release-attestations.sh.
  --attestation-run-limit <N>       Only valid with --attestations wait.
                                    Passed through to
                                    wait-for-release-attestations.sh.
  --json                            Emit a machine-readable JSON report
                                    instead of the human text summary.
EOF
}

err() { printf 'verify-published-release: %s\n' "$1" >&2; exit 1; }
note() { printf 'verify-published-release: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --sha)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SHA_OVERRIDE="$2"
      shift 2
      ;;
    --fix)
      FIX=1
      shift
      ;;
    --attestations)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATIONS_MODE="$2"
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
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'verify-published-release: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'verify-published-release: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
case "${ATTESTATIONS_MODE}" in
  skip|verify|wait) ;;
  *) err "--attestations must be one of: skip, verify, wait (got: ${ATTESTATIONS_MODE})" ;;
esac
if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 && "${ATTESTATIONS_MODE}" != "wait" ]]; then
  err "--trigger-attestations-if-missing requires --attestations wait"
fi
for waiter_opt in \
  "ATTESTATION_POLL_ATTEMPTS:--attestation-poll-attempts:${ATTESTATION_POLL_ATTEMPTS}" \
  "ATTESTATION_POLL_INTERVAL:--attestation-poll-interval:${ATTESTATION_POLL_INTERVAL}" \
  "ATTESTATION_RUN_LIMIT:--attestation-run-limit:${ATTESTATION_RUN_LIMIT}"; do
  opt_name="${waiter_opt%%:*}"
  rest="${waiter_opt#*:}"
  cli_name="${rest%%:*}"
  opt_value="${rest#*:}"
  if [[ -n "${opt_value}" ]]; then
    [[ "${ATTESTATIONS_MODE}" == "wait" ]] || err "${cli_name} requires --attestations wait"
    [[ "${opt_value}" =~ ^[1-9][0-9]*$ ]] || err "${cli_name} must be a positive integer, got: ${opt_value}"
  fi
done

command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
if [[ "${JSON_MODE}" -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || err "jq is required for --json"
fi
[[ -x "${TITLE_VERIFIER}" ]] || err "title verifier missing: ${TITLE_VERIFIER}"
[[ -x "${BODY_VERIFIER}" ]] || err "body verifier missing: ${BODY_VERIFIER}"
[[ -x "${STATE_VERIFIER}" ]] || err "state verifier missing: ${STATE_VERIFIER}"
[[ -x "${ASSET_VERIFIER}" ]] || err "asset verifier missing: ${ASSET_VERIFIER}"
if [[ "${ATTESTATIONS_MODE}" == "verify" ]]; then
  [[ -x "${ATTESTATION_VERIFIER}" ]] || err "attestation verifier missing: ${ATTESTATION_VERIFIER}"
fi
if [[ "${ATTESTATIONS_MODE}" == "wait" ]]; then
  [[ -x "${ATTESTATION_WAITER}" ]] || err "attestation waiter missing: ${ATTESTATION_WAITER}"
fi

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

TMP_DIR="$(mktemp -d -t omc-published-release-verify-XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT
SURFACES_FILE="${TMP_DIR}/surfaces.jsonl"

declare -a FAILED_SURFACES=()
declare -a FAILED_OUTPUTS=()

ok_count=0
fixed_count=0
skipped_count=0
fail_count=0

run_surface() {
  local surface="$1"
  shift
  local out status="OK" summary=""

  if out="$("$@" 2>&1)"; then
    if [[ "${FIX}" -eq 1 && "${out}" == *"repaired and verified"* ]]; then
      status="FIXED"
      fixed_count=$((fixed_count + 1))
    else
      ok_count=$((ok_count + 1))
    fi
    summary="$(printf '%s\n' "${out}" | tail -1)"
    if [[ "${JSON_MODE}" -eq 0 ]]; then
      printf '%s\t%s\t%s\n' "${status}" "${surface}" "${out}"
    else
      jq -nc \
        --arg name "${surface}" \
        --arg status "${status}" \
        --arg summary "${summary}" \
        --arg output "${out}" \
        '{name: $name, status: $status, summary: $summary, output: $output}' >> "${SURFACES_FILE}"
    fi
  else
    FAILED_SURFACES+=("${surface}")
    FAILED_OUTPUTS+=("${out}")
    fail_count=$((fail_count + 1))
    summary="$(printf '%s\n' "${out}" | grep -F 'summary:' | tail -1 || true)"
    [[ -n "${summary}" ]] || summary="$(printf '%s\n' "${out}" | head -1)"
    if [[ "${JSON_MODE}" -eq 0 ]]; then
      printf 'FAIL\t%s\t%s\n' "${surface}" "${summary}" >&2
    else
      jq -nc \
        --arg name "${surface}" \
        --arg status "FAIL" \
        --arg summary "${summary}" \
        --arg output "${out}" \
        '{name: $name, status: $status, summary: $summary, output: $output}' >> "${SURFACES_FILE}"
    fi
  fi
}

title_args=("${VERSION_ARG}" "--repo" "${REPO_SLUG}")
body_args=("${VERSION_ARG}" "--repo" "${REPO_SLUG}")
state_args=("${VERSION_ARG}" "--repo" "${REPO_SLUG}")
asset_args=("${VERSION_ARG}" "--repo" "${REPO_SLUG}")

if [[ -n "${SHA_OVERRIDE}" ]]; then
  body_args+=("--sha" "${SHA_OVERRIDE}")
fi
if [[ "${FIX}" -eq 1 ]]; then
  title_args+=("--fix")
  body_args+=("--fix")
  state_args+=("--fix")
  asset_args+=("--fix")
fi

run_surface "title" bash "${TITLE_VERIFIER}" "${title_args[@]}"
run_surface "body" bash "${BODY_VERIFIER}" "${body_args[@]}"
run_surface "state" bash "${STATE_VERIFIER}" "${state_args[@]}"
run_surface "assets" bash "${ASSET_VERIFIER}" "${asset_args[@]}"

case "${ATTESTATIONS_MODE}" in
  skip)
    skipped_count=$((skipped_count + 1))
    if [[ "${JSON_MODE}" -eq 0 ]]; then
      printf 'SKIP\tattestations\tverify-published-release: attestations skipped by caller\n'
    else
      jq -nc \
        --arg name "attestations" \
        --arg status "SKIP" \
        --arg summary "verify-published-release: attestations skipped by caller" \
        --arg output "verify-published-release: attestations skipped by caller" \
        '{name: $name, status: $status, summary: $summary, output: $output}' >> "${SURFACES_FILE}"
    fi
    ;;
  verify)
    run_surface "attestations" bash "${ATTESTATION_VERIFIER}" "${VERSION_ARG}" --repo "${REPO_SLUG}"
    ;;
  wait)
    wait_args=("${VERSION_ARG}" "--repo" "${REPO_SLUG}")
    if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 ]]; then
      wait_args+=("--trigger-if-missing")
    fi
    if [[ -n "${ATTESTATION_POLL_ATTEMPTS}" ]]; then
      wait_args+=("--poll-attempts" "${ATTESTATION_POLL_ATTEMPTS}")
    fi
    if [[ -n "${ATTESTATION_POLL_INTERVAL}" ]]; then
      wait_args+=("--poll-interval" "${ATTESTATION_POLL_INTERVAL}")
    fi
    if [[ -n "${ATTESTATION_RUN_LIMIT}" ]]; then
      wait_args+=("--run-limit" "${ATTESTATION_RUN_LIMIT}")
    fi
    run_surface "attestations" bash "${ATTESTATION_WAITER}" "${wait_args[@]}"
    ;;
esac

summary_text="verify-published-release: summary: ${ok_count} OK, ${fixed_count} FIXED, ${skipped_count} SKIPPED, ${fail_count} FAIL"
success_message=""

if [[ "${fail_count}" -eq 0 ]]; then
  case "${ATTESTATIONS_MODE}" in
    skip)
      success_message="verify-published-release: published release synchronous surfaces are canonical for ${REPO_SLUG} v${VERSION_ARG} (attestations skipped)"
      ;;
    verify)
      success_message="verify-published-release: published release is canonical for ${REPO_SLUG} v${VERSION_ARG}"
      ;;
    wait)
      success_message="verify-published-release: published release is canonical for ${REPO_SLUG} v${VERSION_ARG} after attestation wait"
      ;;
  esac
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -n \
    --arg version "${VERSION_ARG}" \
    --arg repo "${REPO_SLUG}" \
    --arg sha_override "${SHA_OVERRIDE}" \
    --arg attestations_mode "${ATTESTATIONS_MODE}" \
    --arg summary_text "${summary_text}" \
    --arg message "${success_message}" \
    --argjson fix "$( [[ "${FIX}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson ok_count "${ok_count}" \
    --argjson fixed_count "${fixed_count}" \
    --argjson skipped_count "${skipped_count}" \
    --argjson fail_count "${fail_count}" \
    --slurpfile surfaces "${SURFACES_FILE}" \
    '{
      tool: "verify-published-release",
      version: $version,
      repo: $repo,
      sha_override: (if $sha_override == "" then null else $sha_override end),
      fix: $fix,
      attestations_mode: $attestations_mode,
      result: (if $fail_count == 0 then "ok" else "fail" end),
      counts: {
        ok: $ok_count,
        fixed: $fixed_count,
        skipped: $skipped_count,
        fail: $fail_count
      },
      summary_text: $summary_text,
      message: (if $message == "" then null else $message end),
      surfaces: $surfaces
    }'
  if [[ "${fail_count}" -ne 0 ]]; then
    exit 1
  fi
  exit 0
fi

note "summary: ${ok_count} OK, ${fixed_count} FIXED, ${skipped_count} SKIPPED, ${fail_count} FAIL"

if [[ "${fail_count}" -ne 0 ]]; then
  for i in "${!FAILED_SURFACES[@]}"; do
    printf '\n[%s]\n%s\n' "${FAILED_SURFACES[$i]}" "${FAILED_OUTPUTS[$i]}" >&2
  done
  exit 1
fi

note "${success_message#verify-published-release: }"
