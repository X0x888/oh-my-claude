#!/usr/bin/env bash
#
# tools/wait-for-release-attestations.sh — wait for the release-asset
# attestation workflow run for vX.Y.Z, optionally trigger it if missing,
# then verify the published attestations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY_HELPER="${SCRIPT_DIR}/verify-published-release-attestations.sh"

VERSION_ARG=""
REPO_OVERRIDE=""
WORKFLOW_FILE="attest-release-assets.yml"
POLL_ATTEMPTS=12
POLL_INTERVAL=5
RUN_LIMIT=20
TRIGGER_IF_MISSING=0
NO_VERIFY=0

usage() {
  cat <<'EOF'
Usage: bash tools/wait-for-release-attestations.sh X.Y.Z [options]

Waits for the GitHub Actions release-attestation workflow run associated with
vX.Y.Z, optionally dispatches it if no matching run is found, then verifies the
published release attestations.

Options:
  --repo <owner/name>         Override the GitHub repo slug. Defaults to the
                              current gh repo.
  --workflow <filename>       Workflow file to watch. Default:
                              attest-release-assets.yml
  --poll-attempts <N>         Number of registration polls before giving up or
                              triggering. Default: 12
  --poll-interval <seconds>   Seconds between registration polls. Default: 5
  --run-limit <N>             Number of workflow runs to inspect while polling.
                              Default: 20
  --trigger-if-missing        If no matching workflow run is found after the
                              polling window, dispatch the workflow via
                              workflow_dispatch and keep waiting.
  --no-verify                 Only wait/watch. Skip the final attestation
                              verification step.
EOF
}

err() { printf 'wait-for-release-attestations: %s\n' "$1" >&2; exit 1; }
ok()  { printf 'wait-for-release-attestations: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --workflow)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      WORKFLOW_FILE="$2"
      shift 2
      ;;
    --poll-attempts)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      POLL_ATTEMPTS="$2"
      shift 2
      ;;
    --poll-interval)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --run-limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      RUN_LIMIT="$2"
      shift 2
      ;;
    --trigger-if-missing)
      TRIGGER_IF_MISSING=1
      shift
      ;;
    --no-verify)
      NO_VERIFY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'wait-for-release-attestations: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'wait-for-release-attestations: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
[[ "${POLL_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] || err "--poll-attempts must be a positive integer, got: ${POLL_ATTEMPTS}"
[[ "${POLL_INTERVAL}" =~ ^[1-9][0-9]*$ ]] || err "--poll-interval must be a positive integer, got: ${POLL_INTERVAL}"
[[ "${RUN_LIMIT}" =~ ^[1-9][0-9]*$ ]] || err "--run-limit must be a positive integer, got: ${RUN_LIMIT}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
[[ -x "${VERIFY_HELPER}" ]] || err "verify helper missing: ${VERIFY_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

resolve_remote_tag_commit() {
  local ref_type ref_sha
  ref_type="$(gh api "repos/${REPO_SLUG}/git/ref/tags/v${VERSION_ARG}" --jq '.object.type' 2>/dev/null || true)"
  [[ -n "${ref_type}" ]] || err "could not resolve remote tag v${VERSION_ARG} in ${REPO_SLUG}"
  ref_sha="$(gh api "repos/${REPO_SLUG}/git/ref/tags/v${VERSION_ARG}" --jq '.object.sha' 2>/dev/null || true)"
  [[ -n "${ref_sha}" ]] || err "remote tag v${VERSION_ARG} in ${REPO_SLUG} did not expose an object sha"
  case "${ref_type}" in
    commit) printf '%s' "${ref_sha}" ;;
    tag) gh api "repos/${REPO_SLUG}/git/tags/${ref_sha}" --jq '.object.sha' ;;
    *) err "unsupported remote tag object type for v${VERSION_ARG}: ${ref_type}" ;;
  esac
}

resolve_target_sha() {
  if git rev-parse "v${VERSION_ARG}^{commit}" >/dev/null 2>&1; then
    git rev-parse "v${VERSION_ARG}^{commit}"
  else
    resolve_remote_tag_commit
  fi
}

workflow_exists() {
  gh workflow view "${WORKFLOW_FILE}" -R "${REPO_SLUG}" >/dev/null 2>&1
}

find_run_id() {
  gh run list \
    --repo "${REPO_SLUG}" \
    --workflow "${WORKFLOW_FILE}" \
    --commit "${TARGET_SHA}" \
    --limit "${RUN_LIMIT}" \
    --json databaseId \
    --jq '.[0].databaseId' 2>/dev/null || true
}

TARGET_SHA="$(resolve_target_sha)"
[[ -n "${TARGET_SHA}" ]] || err "could not resolve target commit for v${VERSION_ARG}"

if ! workflow_exists; then
  err "workflow ${WORKFLOW_FILE} not found on the default branch of ${REPO_SLUG}"
fi

RUN_ID=""
for _attempt in $(seq 1 "${POLL_ATTEMPTS}"); do
  RUN_ID="$(find_run_id)"
  [[ -n "${RUN_ID}" && "${RUN_ID}" != "null" ]] && break
  sleep "${POLL_INTERVAL}"
done

if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
  if [[ "${TRIGGER_IF_MISSING}" -eq 1 ]]; then
    gh workflow run "${WORKFLOW_FILE}" -R "${REPO_SLUG}" -r "v${VERSION_ARG}" -f "tag=v${VERSION_ARG}" >/dev/null
    for _attempt in $(seq 1 "${POLL_ATTEMPTS}"); do
      RUN_ID="$(find_run_id)"
      [[ -n "${RUN_ID}" && "${RUN_ID}" != "null" ]] && break
      sleep "${POLL_INTERVAL}"
    done
  fi
fi

if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
  if [[ "${TRIGGER_IF_MISSING}" -eq 1 ]]; then
    err "no ${WORKFLOW_FILE} run registered for v${VERSION_ARG} (${TARGET_SHA}) even after workflow_dispatch"
  fi
  err "no ${WORKFLOW_FILE} run registered for v${VERSION_ARG} (${TARGET_SHA}); rerun with --trigger-if-missing to dispatch it"
fi

ok "watching workflow run ${RUN_ID} for ${REPO_SLUG} v${VERSION_ARG}"
gh run watch --repo "${REPO_SLUG}" --exit-status "${RUN_ID}" >/dev/null
ok "workflow run ${RUN_ID} completed successfully for ${REPO_SLUG} v${VERSION_ARG}"

if [[ "${NO_VERIFY}" -eq 0 ]]; then
  bash "${VERIFY_HELPER}" "${VERSION_ARG}" --repo "${REPO_SLUG}"
fi
