#!/usr/bin/env bash
#
# tools/prepare-release-automation-deployment.sh — safely prepare and
# audit a pending release/distribution deployment candidate before push.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_HELPER="${SCRIPT_DIR}/stage-release-automation-surfaces.sh"
DEPLOYMENT_VERIFIER="${SCRIPT_DIR}/verify-release-automation-deployment.sh"

DRY_RUN=0
JSON_MODE=0
REMOTE_NAME="origin"
REMOTE_REF=""
FETCH_REMOTE=0
ALLOW_EXTRA_STAGED=0
ALLOW_PARTIAL_MANIFEST=0
PATH_FILTERS=()

usage() {
  cat <<'EOF'
Usage: bash tools/prepare-release-automation-deployment.sh [options]

Stages the canonical release/distribution automation surface (or a
narrowed manifest subset), then audits the resulting deployment
candidate against the remote deployment ref with pre-push semantics.

Unlike tools/verify-release-automation-deployment.sh, this helper
does NOT treat "remote is behind the candidate" as a failure. A
candidate is considered coherent when the staged/selected surface only
differs from the remote by MATCH / DRIFT / MISSING_REMOTE states and
has no stage-safety violations.

Options:
  --dry-run                 Preview the candidate without mutating the
                            index. The deployment comparison uses
                            WORKTREE in this mode.
  --remote <name>           Git remote for deployment comparison.
                            Default: origin.
  --remote-ref <ref>        Override the remote deployment ref.
  --fetch                   Fetch the remote before comparing.
  --path <path>             Restrict the candidate to specific manifest
                            path(s). Repeatable.
  --allow-extra-staged      Permit already-staged non-manifest paths to
                            coexist with the candidate.
  --allow-partial-manifest  Permit dirty manifest paths outside the
                            narrowed `--path` subset to remain unstaged.
  --json                    Emit a machine-readable JSON report.
EOF
}

err() { printf 'prepare-release-automation-deployment: %s\n' "$1" >&2; exit 1; }
note() { printf 'prepare-release-automation-deployment: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
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
    --fetch)
      FETCH_REMOTE=1
      shift
      ;;
    --path)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PATH_FILTERS+=("$2")
      shift 2
      ;;
    --allow-extra-staged)
      ALLOW_EXTRA_STAGED=1
      shift
      ;;
    --allow-partial-manifest)
      ALLOW_PARTIAL_MANIFEST=1
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
      printf 'prepare-release-automation-deployment: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'prepare-release-automation-deployment: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || err "jq not found in PATH"
command -v git >/dev/null 2>&1 || err "git not found in PATH"
git rev-parse --git-dir >/dev/null 2>&1 || err "not inside a git repository"
[[ -x "${STAGE_HELPER}" ]] || err "stage helper missing: ${STAGE_HELPER}"
[[ -x "${DEPLOYMENT_VERIFIER}" ]] || err "deployment verifier missing: ${DEPLOYMENT_VERIFIER}"

build_stage_command() {
  local cmd
  cmd="bash $(printf '%q' "${STAGE_HELPER}") --json"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    cmd+=" --dry-run"
  fi
  if [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]]; then
    cmd+=" --allow-extra-staged"
  fi
  if [[ "${ALLOW_PARTIAL_MANIFEST}" -eq 1 ]]; then
    cmd+=" --allow-partial-manifest"
  fi
  local path
  if [[ "${#PATH_FILTERS[@]}" -gt 0 ]]; then
    for path in "${PATH_FILTERS[@]}"; do
      cmd+=" --path $(printf '%q' "${path}")"
    done
  fi
  printf '%s' "${cmd}"
}

build_deployment_command() {
  local local_ref="$1"
  local cmd
  cmd="bash $(printf '%q' "${DEPLOYMENT_VERIFIER}") --json --remote $(printf '%q' "${REMOTE_NAME}") --local-ref $(printf '%q' "${local_ref}")"
  if [[ -n "${REMOTE_REF}" ]]; then
    cmd+=" --remote-ref $(printf '%q' "${REMOTE_REF}")"
  fi
  if [[ "${FETCH_REMOTE}" -eq 1 ]]; then
    cmd+=" --fetch"
  fi
  if [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]]; then
    cmd+=" --allow-extra-staged"
  fi
  local path
  if [[ "${#PATH_FILTERS[@]}" -gt 0 ]]; then
    for path in "${PATH_FILTERS[@]}"; do
      cmd+=" --path $(printf '%q' "${path}")"
    done
  fi
  printf '%s' "${cmd}"
}

path_filters_json() {
  if [[ "${#PATH_FILTERS[@]}" -gt 0 ]]; then
    printf '%s\n' "${PATH_FILTERS[@]}" | jq -R . | jq -s .
  else
    printf '[]'
  fi
}

run_json_command() {
  local command="$1"
  local output=""
  local rc=0
  if output="$(bash -lc "${command}" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n%d' "${output}" "${rc}"
}

parse_json_or_fail() {
  local label="$1"
  local payload="$2"
  if ! printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
    err "${label} did not return valid JSON"
  fi
}

json_bool() {
  [[ "$1" -eq 1 ]] && printf 'true' || printf 'false'
}

stage_cmd="$(build_stage_command)"
stage_blob="$(run_json_command "${stage_cmd}")"
stage_rc="${stage_blob##*$'\n'}"
stage_output="${stage_blob%$'\n'*}"
parse_json_or_fail "stage helper" "${stage_output}"

stage_result="$(printf '%s' "${stage_output}" | jq -r '.result')"
stage_summary="$(printf '%s' "${stage_output}" | jq -r '.summary_text')"

candidate_local_ref="INDEX"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  candidate_local_ref="WORKTREE"
fi

deployment_output=""
deployment_rc=0
deployment_status_text="SKIP"
deployable_paths_json='[]'
unexpected_items_json='[]'
pending_remote_count=0
drift_count=0
missing_remote_count=0
missing_local_count=0
extra_staged_non_manifest_count=0
deployment_summary="deployment comparison skipped because staging failed"
deployment_message=""

if [[ "${stage_result}" == "ok" && "${stage_rc}" -eq 0 ]]; then
  deployment_cmd="$(build_deployment_command "${candidate_local_ref}")"
  deployment_blob="$(run_json_command "${deployment_cmd}")"
  deployment_rc="${deployment_blob##*$'\n'}"
  deployment_output="${deployment_blob%$'\n'*}"
  parse_json_or_fail "deployment verifier" "${deployment_output}"

  deployment_summary="$(printf '%s' "${deployment_output}" | jq -r '.summary_text')"
  deployment_message="$(printf '%s' "${deployment_output}" | jq -r '.message // empty')"
  drift_count="$(printf '%s' "${deployment_output}" | jq -r '.counts.drift')"
  missing_remote_count="$(printf '%s' "${deployment_output}" | jq -r '.counts.missing_remote')"
  missing_local_count="$(printf '%s' "${deployment_output}" | jq -r '.counts.missing_local')"
  extra_staged_non_manifest_count="$(printf '%s' "${deployment_output}" | jq -r '.counts.extra_staged_non_manifest')"
  pending_remote_count=$((drift_count + missing_remote_count))
  deployable_paths_json="$(
    printf '%s' "${deployment_output}" | jq -c '
      [
        .items[]
        | select(.status == "DRIFT" or .status == "MISSING_REMOTE")
        | {path, status}
      ]'
  )"
  unexpected_items_json="$(
    printf '%s' "${deployment_output}" | jq -c '
      [
        .items[]
        | select(
            .status != "MATCH"
            and .status != "DRIFT"
            and .status != "MISSING_REMOTE"
            and .status != "EXTRA_STAGED_NON_MANIFEST"
          )
        | {path, status}
      ]'
  )"
  if [[ "${ALLOW_EXTRA_STAGED}" -eq 0 ]]; then
    unexpected_items_json="$(
      jq -nc \
        --argjson base "${unexpected_items_json}" \
        --argjson deploy "${deployment_output}" '
        $base + [
          $deploy.items[]
          | select(.status == "EXTRA_STAGED_NON_MANIFEST")
          | {path, status}
        ]'
    )"
  fi

  unexpected_count="$(printf '%s' "${unexpected_items_json}" | jq 'length')"
  if [[ "${unexpected_count}" -eq 0 ]]; then
    if [[ "${pending_remote_count}" -gt 0 ]]; then
      deployment_status_text="PENDING_REMOTE"
    else
      deployment_status_text="OK"
    fi
  else
    deployment_status_text="FAIL"
  fi
fi

stage_selected_count="$(printf '%s' "${stage_output}" | jq -r '.counts.selected')"
stage_clean_count="$(printf '%s' "${stage_output}" | jq -r '.counts.clean')"
stage_staged_count="$(printf '%s' "${stage_output}" | jq -r '.counts.staged')"
stage_missing_local_count="$(printf '%s' "${stage_output}" | jq -r '.counts.missing_local')"
stage_extra_staged_count="$(printf '%s' "${stage_output}" | jq -r '.counts.extra_staged')"
stage_dirty_unselected_manifest_count="$(printf '%s' "${stage_output}" | jq -r '.counts.dirty_unselected_manifest')"

candidate_status="BLOCKED"
result="fail"
summary_text=""
message=""
remediation_json='[]'

if [[ "${stage_result}" != "ok" || "${stage_rc}" -ne 0 ]]; then
  summary_text="prepare-release-automation-deployment: summary: ${stage_selected_count} selected, ${stage_clean_count} clean, ${stage_staged_count} would-stage, ${stage_missing_local_count} missing_local, ${stage_extra_staged_count} extra_staged, ${stage_dirty_unselected_manifest_count} dirty_unselected_manifest, stage_blocked"
  message="prepare-release-automation-deployment: candidate blocked before deployment audit"
  remediation_json="$(
    jq -nc \
      --arg allow_extra "--allow-extra-staged" \
      --arg allow_partial "--allow-partial-manifest" \
      '[
        "resolve the stage-safety issues reported by tools/stage-release-automation-surfaces.sh before preparing a deployment candidate",
        ("if unrelated staged paths are intentional, rerun with " + $allow_extra),
        ("if a narrowed selection intentionally leaves other manifest paths dirty, rerun with " + $allow_partial),
        "rerun with --path <path> to narrow the candidate to a specific manifest surface"
      ]'
  )"
elif [[ "$(printf '%s' "${unexpected_items_json}" | jq 'length')" -eq 0 ]]; then
  result="ok"
  if [[ "${pending_remote_count}" -gt 0 ]]; then
    candidate_status="READY_TO_COMMIT"
    summary_text="prepare-release-automation-deployment: summary: ${stage_selected_count} selected, ${stage_clean_count} clean, ${pending_remote_count} pending_remote (${drift_count} DRIFT, ${missing_remote_count} MISSING_REMOTE), ${missing_local_count} missing_local, ${extra_staged_non_manifest_count} extra_staged_non_manifest, ${stage_dirty_unselected_manifest_count} dirty_unselected_manifest"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      message="prepare-release-automation-deployment: preview is coherent; rerun without --dry-run to stage, commit/push the candidate, then rerun tools/verify-distribution-readiness.sh"
      remediation_json="$(
        jq -nc '
          [
            "rerun without --dry-run to stage the coherent deployment candidate",
            "commit/push the staged candidate to the remote deployment branch",
            "rerun tools/verify-distribution-readiness.sh --fetch after deployment"
          ]'
      )"
    else
      message="prepare-release-automation-deployment: staged deployment candidate is coherent; commit/push the candidate, then rerun tools/verify-distribution-readiness.sh"
      remediation_json="$(
        jq -nc '
          [
            "commit/push the staged candidate to the remote deployment branch",
            "rerun tools/verify-distribution-readiness.sh --fetch after deployment"
          ]'
      )"
    fi
  else
    candidate_status="CURRENT"
    summary_text="prepare-release-automation-deployment: summary: ${stage_selected_count} selected, ${stage_clean_count} clean, 0 pending_remote, ${missing_local_count} missing_local, ${extra_staged_non_manifest_count} extra_staged_non_manifest, ${stage_dirty_unselected_manifest_count} dirty_unselected_manifest"
    message="prepare-release-automation-deployment: selected release/distribution surface already matches the remote deployment ref"
    remediation_json='[]'
  fi
else
  summary_text="prepare-release-automation-deployment: summary: ${stage_selected_count} selected, ${stage_clean_count} clean, ${pending_remote_count} pending_remote (${drift_count} DRIFT, ${missing_remote_count} MISSING_REMOTE), ${missing_local_count} missing_local, ${extra_staged_non_manifest_count} extra_staged_non_manifest, ${stage_dirty_unselected_manifest_count} dirty_unselected_manifest, candidate_blocked"
  message="prepare-release-automation-deployment: candidate is not coherent; inspect unexpected deployment states before commit/push"
  remediation_json="$(
    jq -nc '
      [
        "inspect the unexpected deployment states in unexpected_items and resolve them before commit/push",
        "rerun tools/stage-release-automation-surfaces.sh directly if you need lower-level stage diagnostics",
        "rerun tools/verify-release-automation-deployment.sh with --path <path> for a narrower deployment diff"
      ]'
  )"
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -n \
    --arg remote "${REMOTE_NAME}" \
    --arg remote_ref "${REMOTE_REF}" \
    --arg candidate_local_ref "${candidate_local_ref}" \
    --arg candidate_status "${candidate_status}" \
    --arg result "${result}" \
    --arg summary_text "${summary_text}" \
    --arg message "${message}" \
    --argjson dry_run "$(json_bool "${DRY_RUN}")" \
    --argjson fetch_remote "$(json_bool "${FETCH_REMOTE}")" \
    --argjson allow_extra_staged "$(json_bool "${ALLOW_EXTRA_STAGED}")" \
    --argjson allow_partial_manifest "$(json_bool "${ALLOW_PARTIAL_MANIFEST}")" \
    --argjson path_filters "$(path_filters_json)" \
    --argjson selected_count "${stage_selected_count}" \
    --argjson clean_count "${stage_clean_count}" \
    --argjson staged_count "${stage_staged_count}" \
    --argjson pending_remote_count "${pending_remote_count}" \
    --argjson drift_count "${drift_count}" \
    --argjson missing_remote_count "${missing_remote_count}" \
    --argjson missing_local_count "${missing_local_count}" \
    --argjson extra_staged_non_manifest_count "${extra_staged_non_manifest_count}" \
    --argjson dirty_unselected_manifest_count "${stage_dirty_unselected_manifest_count}" \
    --argjson deployable_paths "${deployable_paths_json}" \
    --argjson unexpected_items "${unexpected_items_json}" \
    --argjson remediation "${remediation_json}" \
    --argjson stage "${stage_output}" \
    --argjson deployment "$(if [[ -n "${deployment_output}" ]]; then printf '%s' "${deployment_output}"; else printf 'null'; fi)" \
    '{
      tool: "prepare-release-automation-deployment",
      dry_run: $dry_run,
      remote: $remote,
      remote_ref_override: (if $remote_ref == "" then null else $remote_ref end),
      candidate_local_ref: $candidate_local_ref,
      allow_extra_staged: $allow_extra_staged,
      allow_partial_manifest: $allow_partial_manifest,
      fetch_remote: $fetch_remote,
      path_filters: $path_filters,
      candidate_status: $candidate_status,
      result: $result,
      counts: {
        selected: $selected_count,
        clean: $clean_count,
        staged_or_would_stage: $staged_count,
        pending_remote: $pending_remote_count,
        drift: $drift_count,
        missing_remote: $missing_remote_count,
        missing_local: $missing_local_count,
        extra_staged_non_manifest: $extra_staged_non_manifest_count,
        dirty_unselected_manifest: $dirty_unselected_manifest_count
      },
      deployable_paths: $deployable_paths,
      unexpected_items: $unexpected_items,
      summary_text: $summary_text,
      message: $message,
      stage: $stage,
      deployment: $deployment,
      remediation: $remediation
    }'
else
  printf 'OK\tstage\t%s\n' "${stage_summary}"
  if [[ -n "${deployment_output}" ]]; then
    printf '%s\tdeployment\t%s\n' "${deployment_status_text}" "${deployment_summary}"
  else
    printf 'SKIP\tdeployment\t%s\n' "${deployment_summary}"
  fi
  if [[ "$(printf '%s' "${remediation_json}" | jq 'length')" -gt 0 ]]; then
    note "remediation:"
    printf '%s' "${remediation_json}" | jq -r '.[]' | while IFS= read -r line; do
      printf '  - %s\n' "${line}"
    done
  fi
  printf '%s\n' "${message}"
fi

[[ "${result}" == "ok" ]]
