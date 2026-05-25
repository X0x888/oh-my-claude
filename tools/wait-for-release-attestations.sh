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
# Hard upper bound on `gh run watch` wall-clock. Default 1800s (30 min) is well
# above the workflow's normal completion time (~3-5 min for build+verify+attest).
# Closes the failure mode where a hung GH Actions run otherwise blocks the
# maintainer's terminal indefinitely with no diagnostic. 0 disables.
WATCH_TIMEOUT=1800

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
  --watch-timeout <seconds>   Hard upper bound on `gh run watch`. Default 1800
                              (30 min). 0 disables the timeout wrapper.
                              Requires `timeout(1)` or `gtimeout` in PATH; on
                              hosts without either, the wrapper is skipped and
                              a warning is logged.
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
    --watch-timeout)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      WATCH_TIMEOUT="$2"
      shift 2
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
[[ "${WATCH_TIMEOUT}" =~ ^[0-9]+$ ]] || err "--watch-timeout must be a non-negative integer, got: ${WATCH_TIMEOUT}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
[[ -x "${VERIFY_HELPER}" ]] || err "verify helper missing: ${VERIFY_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

resolve_default_branch() {
  local branch
  branch="$(gh repo view -R "${REPO_SLUG}" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  if [[ -z "${branch}" ]]; then
    branch="$(gh api "repos/${REPO_SLUG}" --jq '.default_branch' 2>/dev/null || true)"
  fi
  [[ -n "${branch}" ]] || err "could not resolve default branch for ${REPO_SLUG}"
  printf '%s' "${branch}"
}

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

resolve_branch_head_sha() {
  local branch="$1" sha
  sha="$(gh api "repos/${REPO_SLUG}/branches/${branch}" --jq '.commit.sha' 2>/dev/null || true)"
  [[ -n "${sha}" ]] || err "could not resolve branch head sha for ${REPO_SLUG}:${branch}"
  printf '%s' "${sha}"
}

workflow_exists() {
  gh workflow view "${WORKFLOW_FILE}" -R "${REPO_SLUG}" >/dev/null 2>&1
}

# Best-effort viability check: returns 0 if the run is either in-progress,
# queued, or completed with a success conclusion. Returns 1 only when a
# completed run carries a terminal-failure conclusion (failure, cancelled,
# timed_out, action_required, startup_failure, neutral, skipped, stale).
#
# Closes the stale-failure failure mode where the SHA-anchored poll picks
# up a prior failed attestation run and `gh run watch --exit-status` then
# errors immediately, leaving the user without auto-redispatch.
#
# Falls through to "viable" when `gh api` lookup fails — preserves existing
# stub-based test behavior (the gh stub does not implement actions/runs/{id}
# lookups, so the call exits non-zero and conclusion stays empty).
run_is_viable() {
  local run_id="$1"
  local status="" conclusion="" run_json=""
  run_json="$(gh api "repos/${REPO_SLUG}/actions/runs/${run_id}" --jq '{status: (.status // empty), conclusion: (.conclusion // empty)}' 2>/dev/null || true)"
  if [[ -n "${run_json}" ]]; then
    status="$(printf '%s' "${run_json}" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)"
    conclusion="$(printf '%s' "${run_json}" | grep -o '"conclusion":"[^"]*"' | cut -d'"' -f4 || true)"
  fi
  case "${conclusion}" in
    failure|cancelled|timed_out|action_required|startup_failure|stale|neutral|skipped)
      return 1
      ;;
  esac
  case "${status}" in
    in_progress|queued|requested|waiting|pending|completed|"")
      return 0
      ;;
  esac
  return 0
}

find_run_id_for_commit() {
  local commit="$1"
  local event_filter="${2:-}"
  local branch_filter="${3:-}"
  local -a args
  args=(
    gh run list
    --repo "${REPO_SLUG}"
    --workflow "${WORKFLOW_FILE}"
    --commit "${commit}"
    --limit "${RUN_LIMIT}"
    --json databaseId
  )
  if [[ -n "${event_filter}" ]]; then
    args+=(--event "${event_filter}")
  fi
  if [[ -n "${branch_filter}" ]]; then
    args+=(--branch "${branch_filter}")
  fi
  "${args[@]}" --jq '.[0].databaseId' 2>/dev/null || true
}

find_new_run_id_for_commit() {
  local commit="$1"
  local event_filter="$2"
  local branch_filter="$3"
  local baseline_run_id="$4"
  local run_id=""

  run_id="$(find_run_id_for_commit "${commit}" "${event_filter}" "${branch_filter}")"
  [[ "${run_id}" != "null" ]] || run_id=""
  if [[ -z "${baseline_run_id}" ]]; then
    printf '%s' "${run_id}"
    return 0
  fi
  if [[ -n "${run_id}" && "${run_id}" != "${baseline_run_id}" ]]; then
    printf '%s' "${run_id}"
  fi
}

TARGET_SHA="$(resolve_target_sha)"
[[ -n "${TARGET_SHA}" ]] || err "could not resolve target commit for v${VERSION_ARG}"

if ! workflow_exists; then
  err "workflow ${WORKFLOW_FILE} not found on the default branch of ${REPO_SLUG}"
fi

RUN_ID=""
TARGET_SHA_SHORT="${TARGET_SHA:0:12}"
for _attempt in $(seq 1 "${POLL_ATTEMPTS}"); do
  ok "poll ${_attempt}/${POLL_ATTEMPTS} for ${WORKFLOW_FILE} run on ${TARGET_SHA_SHORT}"
  candidate_id="$(find_run_id_for_commit "${TARGET_SHA}")"
  if [[ -n "${candidate_id}" && "${candidate_id}" != "null" ]]; then
    if run_is_viable "${candidate_id}"; then
      RUN_ID="${candidate_id}"
      break
    fi
    ok "skipping stale terminal-failure run ${candidate_id} on ${TARGET_SHA_SHORT}"
  fi
  sleep "${POLL_INTERVAL}"
done

if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
  if [[ "${TRIGGER_IF_MISSING}" -eq 1 ]]; then
    BASELINE_RUN_ID=""
    DEFAULT_BRANCH="$(resolve_default_branch)"
    DISPATCH_SHA="$(resolve_branch_head_sha "${DEFAULT_BRANCH}")"
    BASELINE_RUN_ID="$(find_run_id_for_commit "${DISPATCH_SHA}" "workflow_dispatch" "${DEFAULT_BRANCH}")"
    [[ "${BASELINE_RUN_ID}" != "null" ]] || BASELINE_RUN_ID=""
    ok "dispatching ${WORKFLOW_FILE} for v${VERSION_ARG} on ${DEFAULT_BRANCH}"
    gh workflow run "${WORKFLOW_FILE}" -R "${REPO_SLUG}" -r "${DEFAULT_BRANCH}" -f "tag=v${VERSION_ARG}" >/dev/null
    for _attempt in $(seq 1 "${POLL_ATTEMPTS}"); do
      ok "dispatch-poll ${_attempt}/${POLL_ATTEMPTS} for new workflow_dispatch run (baseline=${BASELINE_RUN_ID:-none})"
      RUN_ID="$(find_new_run_id_for_commit "${DISPATCH_SHA}" "workflow_dispatch" "${DEFAULT_BRANCH}" "${BASELINE_RUN_ID}")"
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

# Wrap `gh run watch` in a timeout when one is available so a hung Actions
# run doesn't block the caller indefinitely. timeout(1) is GNU-coreutils
# (Ubuntu CI); macOS dev hosts may have gtimeout via brew install
# coreutils. When neither is present, fall through with a logged warning
# so the user knows the wrapper was skipped.
_run_watch_cmd=(gh run watch --repo "${REPO_SLUG}" --exit-status "${RUN_ID}")
_watch_rc=0
if [[ "${WATCH_TIMEOUT}" -gt 0 ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout "${WATCH_TIMEOUT}" "${_run_watch_cmd[@]}" >/dev/null || _watch_rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${WATCH_TIMEOUT}" "${_run_watch_cmd[@]}" >/dev/null || _watch_rc=$?
  else
    ok "warning: timeout(1)/gtimeout not available; gh run watch will not be time-bounded"
    "${_run_watch_cmd[@]}" >/dev/null || _watch_rc=$?
  fi
else
  "${_run_watch_cmd[@]}" >/dev/null || _watch_rc=$?
fi
if [[ "${_watch_rc}" -eq 124 ]]; then
  err "gh run watch timed out after ${WATCH_TIMEOUT}s for run ${RUN_ID}. The workflow may still be running — check https://github.com/${REPO_SLUG}/actions/runs/${RUN_ID}"
elif [[ "${_watch_rc}" -ne 0 ]]; then
  err "gh run watch exited ${_watch_rc} for run ${RUN_ID}. The workflow run likely failed — check https://github.com/${REPO_SLUG}/actions/runs/${RUN_ID}"
fi
ok "workflow run ${RUN_ID} completed successfully for ${REPO_SLUG} v${VERSION_ARG}"

if [[ "${NO_VERIFY}" -eq 0 ]]; then
  bash "${VERIFY_HELPER}" "${VERSION_ARG}" --repo "${REPO_SLUG}"
fi
