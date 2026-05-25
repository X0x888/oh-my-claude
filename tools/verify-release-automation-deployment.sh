#!/usr/bin/env bash
#
# tools/verify-release-automation-deployment.sh — verify that the
# remote deployment ref contains the canonical release/distribution
# automation surfaces from a chosen local ref.

set -euo pipefail

REMOTE_NAME="origin"
REMOTE_REF=""
LOCAL_REF="WORKTREE"
FETCH_REMOTE=0
PATH_FILTERS=()
JSON_MODE=0
ALLOW_EXTRA_STAGED=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SURFACE_LIST_HELPER="${SCRIPT_DIR}/list-release-automation-surfaces.sh"

usage() {
  cat <<'EOF'
Usage: bash tools/verify-release-automation-deployment.sh [options]

Verifies that the deployment ref (default: the default branch of `origin`)
contains the canonical release/distribution automation surfaces from the
chosen local ref (default: `WORKTREE`).

This is the deployment-side companion to tools/verify-published-release.sh:
use it when local release tooling exists but live published-release audits are
still failing, so you can prove whether the remote default branch actually has
the necessary workflow/scripts deployed yet.

Options:
  --remote <name>      Git remote to compare against. Default: origin.
  --remote-ref <ref>   Override the deployment ref explicitly. When omitted,
                       the script resolves refs/remotes/<remote>/HEAD and
                       falls back to <remote>/main if needed.
  --local-ref <ref>    Local source ref to compare from. Default: WORKTREE.
                       Special values:
                         `WORKTREE` — compare checked-out files directly,
                                      including uncommitted changes.
                         `INDEX` or `STAGED` — compare the staged index only,
                                      ignoring unstaged worktree drift.
  --path <path>        Restrict comparison to specific path(s). Repeatable.
                       By default the script checks the full canonical
                       release/distribution automation surface.
  --allow-extra-staged Permit staged non-manifest paths to coexist with
                       INDEX/STAGED verification. By default the verifier
                       fails closed when the staged index contains files
                       outside the canonical release/distribution surface.
  --fetch              Fetch the remote before comparing.
  --json               Emit a machine-readable JSON report instead of the
                       human text summary.
EOF
}

err() { printf 'verify-release-automation-deployment: %s\n' "$1" >&2; exit 1; }
note() { printf 'verify-release-automation-deployment: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --path)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PATH_FILTERS+=("$2")
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
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'verify-release-automation-deployment: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'verify-release-automation-deployment: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v git >/dev/null 2>&1 || err "git not found in PATH"
git rev-parse --git-dir >/dev/null 2>&1 || err "not inside a git repository"
[[ -x "${SURFACE_LIST_HELPER}" ]] || err "surface list helper missing: ${SURFACE_LIST_HELPER}"
if [[ "${JSON_MODE}" -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || err "jq is required for --json"
fi

if [[ "${FETCH_REMOTE}" -eq 1 ]]; then
  git fetch "${REMOTE_NAME}" --prune --tags >/dev/null 2>&1 || err "git fetch ${REMOTE_NAME} failed"
fi

resolve_remote_ref() {
  local symbolic_ref candidate
  if [[ -n "${REMOTE_REF}" ]]; then
    printf '%s' "${REMOTE_REF}"
    return 0
  fi
  symbolic_ref="$(git symbolic-ref "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null || true)"
  if [[ -n "${symbolic_ref}" ]]; then
    candidate="${symbolic_ref#refs/remotes/}"
    printf '%s' "${candidate}"
    return 0
  fi
  printf '%s/main' "${REMOTE_NAME}"
}

path_exists_at_ref() {
  local ref="$1" path="$2"
  git rev-parse --verify "${ref}:${path}" >/dev/null 2>&1
}

blob_at_ref() {
  local ref="$1" path="$2"
  git rev-parse "${ref}:${path}" 2>/dev/null || true
}

path_exists_locally() {
  local path="$1"
  [[ -e "${path}" ]]
}

blob_locally() {
  local path="$1"
  git hash-object "${path}" 2>/dev/null || true
}

path_exists_in_index() {
  local path="$1"
  git rev-parse --verify ":${path}" >/dev/null 2>&1
}

blob_in_index() {
  local path="$1"
  git rev-parse ":${path}" 2>/dev/null || true
}

contains_path() {
  local needle="$1"
  shift || true
  local candidate
  for candidate in "$@"; do
    [[ "${candidate}" == "${needle}" ]] && return 0
  done
  return 1
}

REMOTE_COMPARE_REF="$(resolve_remote_ref)"
if [[ "${LOCAL_REF}" != "WORKTREE" && "${LOCAL_REF}" != "INDEX" && "${LOCAL_REF}" != "STAGED" ]]; then
  git rev-parse --verify "${LOCAL_REF}^{commit}" >/dev/null 2>&1 || err "local ref does not resolve to a commit: ${LOCAL_REF}"
fi
git rev-parse --verify "${REMOTE_COMPARE_REF}^{commit}" >/dev/null 2>&1 || err "remote ref does not resolve to a commit: ${REMOTE_COMPARE_REF} (run with --fetch if needed)"

if [[ "${#PATH_FILTERS[@]}" -eq 0 ]]; then
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    PATH_FILTERS+=("${path}")
  done < <(bash "${SURFACE_LIST_HELPER}")
fi

manifest_paths=()
while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  manifest_paths+=("${path}")
done < <(bash "${SURFACE_LIST_HELPER}")

match_count=0
drift_count=0
missing_remote_count=0
missing_local_count=0
extra_staged_non_manifest_count=0
extra_staged_non_manifest_paths=()
fetched_json="false"
items_file=""
tmp_dir=""

if [[ "${LOCAL_REF}" == "INDEX" || "${LOCAL_REF}" == "STAGED" ]]; then
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if ! contains_path "${path}" "${manifest_paths[@]}"; then
      extra_staged_non_manifest_paths+=("${path}")
    fi
  done < <(git diff --cached --name-only --diff-filter=ACDMRTUXB | LC_ALL=C sort -u)
  extra_staged_non_manifest_count="${#extra_staged_non_manifest_paths[@]}"
fi

if [[ "${FETCH_REMOTE}" -eq 1 ]]; then
  fetched_json="true"
fi
if [[ "${JSON_MODE}" -eq 1 ]]; then
  tmp_dir="$(mktemp -d -t omc-release-deployment-verify-XXXXXX)"
  items_file="${tmp_dir}/items.jsonl"
  cleanup() { rm -rf "${tmp_dir}"; }
  trap cleanup EXIT
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  note "comparing local ${LOCAL_REF} -> remote ${REMOTE_COMPARE_REF}"
fi

for path in "${PATH_FILTERS[@]}"; do
  local_exists=0
  remote_exists=0
  local_blob=""
  remote_blob=""
  status=""
  local_exists_json="false"
  remote_exists_json="false"

  if [[ "${LOCAL_REF}" == "WORKTREE" ]]; then
    if path_exists_locally "${path}"; then
      local_exists=1
      local_blob="$(blob_locally "${path}")"
      local_exists_json="true"
    fi
  elif [[ "${LOCAL_REF}" == "INDEX" || "${LOCAL_REF}" == "STAGED" ]]; then
    if path_exists_in_index "${path}"; then
      local_exists=1
      local_blob="$(blob_in_index "${path}")"
      local_exists_json="true"
    fi
  elif path_exists_at_ref "${LOCAL_REF}" "${path}"; then
    local_exists=1
    local_blob="$(blob_at_ref "${LOCAL_REF}" "${path}")"
    local_exists_json="true"
  fi
  if path_exists_at_ref "${REMOTE_COMPARE_REF}" "${path}"; then
    remote_exists=1
    remote_blob="$(blob_at_ref "${REMOTE_COMPARE_REF}" "${path}")"
    remote_exists_json="true"
  fi

  if [[ "${local_exists}" -eq 1 && "${remote_exists}" -eq 1 ]]; then
    if [[ "${local_blob}" == "${remote_blob}" ]]; then
      status="MATCH"
      match_count=$((match_count + 1))
    else
      status="DRIFT"
      drift_count=$((drift_count + 1))
    fi
  elif [[ "${local_exists}" -eq 1 ]]; then
    status="MISSING_REMOTE"
    missing_remote_count=$((missing_remote_count + 1))
  elif [[ "${remote_exists}" -eq 1 ]]; then
    status="MISSING_LOCAL"
    missing_local_count=$((missing_local_count + 1))
  else
    status="MISSING_BOTH"
    missing_local_count=$((missing_local_count + 1))
    missing_remote_count=$((missing_remote_count + 1))
  fi

  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\n' "${status}" "${path}"
  else
    jq -nc \
      --arg path "${path}" \
      --arg status "${status}" \
      --arg local_blob "${local_blob}" \
      --arg remote_blob "${remote_blob}" \
      --argjson local_exists "${local_exists_json}" \
      --argjson remote_exists "${remote_exists_json}" \
      '{
        path: $path,
        status: $status,
        local_exists: $local_exists,
        remote_exists: $remote_exists,
        local_blob: (if $local_blob == "" then null else $local_blob end),
        remote_blob: (if $remote_blob == "" then null else $remote_blob end)
      }' >> "${items_file}"
  fi
done

if [[ "${extra_staged_non_manifest_count}" -gt 0 ]]; then
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    for path in "${extra_staged_non_manifest_paths[@]}"; do
      printf 'EXTRA_STAGED_NON_MANIFEST\t%s\n' "${path}"
    done
  else
    for path in "${extra_staged_non_manifest_paths[@]}"; do
      jq -nc \
        --arg path "${path}" \
        '{
          path: $path,
          status: "EXTRA_STAGED_NON_MANIFEST",
          local_exists: true,
          remote_exists: false,
          local_blob: null,
          remote_blob: null
        }' >> "${items_file}"
    done
  fi
fi

summary_text="verify-release-automation-deployment: summary: ${match_count} MATCH, ${drift_count} DRIFT, ${missing_remote_count} MISSING_REMOTE, ${missing_local_count} MISSING_LOCAL, ${extra_staged_non_manifest_count} EXTRA_STAGED_NON_MANIFEST"
success_message=""

if [[ "${drift_count}" -eq 0 && "${missing_remote_count}" -eq 0 && "${missing_local_count}" -eq 0 && ( "${extra_staged_non_manifest_count}" -eq 0 || "${ALLOW_EXTRA_STAGED}" -eq 1 ) ]]; then
  success_message="verify-release-automation-deployment: release automation deployment is current at ${REMOTE_COMPARE_REF}"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    note "summary: ${match_count} MATCH, ${drift_count} DRIFT, ${missing_remote_count} MISSING_REMOTE, ${missing_local_count} MISSING_LOCAL"
    if [[ "${extra_staged_non_manifest_count}" -gt 0 ]]; then
      note "continuing despite ${extra_staged_non_manifest_count} extra staged non-manifest path(s) because --allow-extra-staged was supplied"
    fi
    note "release automation deployment is current at ${REMOTE_COMPARE_REF}"
  else
    path_filters_json="$(printf '%s\n' "${PATH_FILTERS[@]}" | jq -R . | jq -s .)"
    if [[ "${extra_staged_non_manifest_count}" -gt 0 ]]; then
      extra_staged_non_manifest_paths_json="$(printf '%s\n' "${extra_staged_non_manifest_paths[@]}" | jq -R . | jq -s .)"
    else
      extra_staged_non_manifest_paths_json='[]'
    fi
    jq -n \
      --arg remote "${REMOTE_NAME}" \
      --arg remote_ref "${REMOTE_COMPARE_REF}" \
      --arg local_ref "${LOCAL_REF}" \
      --arg summary_text "${summary_text}" \
      --arg message "${success_message}" \
      --argjson fetched "${fetched_json}" \
      --argjson allow_extra_staged "$( [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]] && printf 'true' || printf 'false' )" \
      --argjson path_filters "${path_filters_json}" \
      --argjson match_count "${match_count}" \
      --argjson drift_count "${drift_count}" \
      --argjson missing_remote_count "${missing_remote_count}" \
      --argjson missing_local_count "${missing_local_count}" \
      --argjson extra_staged_non_manifest_count "${extra_staged_non_manifest_count}" \
      --argjson extra_staged_non_manifest_paths "${extra_staged_non_manifest_paths_json}" \
      --slurpfile items "${items_file}" \
      '{
        tool: "verify-release-automation-deployment",
        remote: $remote,
        remote_ref: $remote_ref,
        local_ref: $local_ref,
        fetched: $fetched,
        allow_extra_staged: $allow_extra_staged,
        path_filters: $path_filters,
        result: "ok",
        counts: {
          match: $match_count,
          drift: $drift_count,
          missing_remote: $missing_remote_count,
          missing_local: $missing_local_count,
          extra_staged_non_manifest: $extra_staged_non_manifest_count
        },
        extra_staged_non_manifest_paths: $extra_staged_non_manifest_paths,
        summary_text: $summary_text,
        message: $message,
        items: $items,
        remediation: []
      }'
  fi
  exit 0
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  note "summary: ${match_count} MATCH, ${drift_count} DRIFT, ${missing_remote_count} MISSING_REMOTE, ${missing_local_count} MISSING_LOCAL"
  printf 'verify-release-automation-deployment: remediation:\n' >&2
  if [[ "${extra_staged_non_manifest_count}" -gt 0 ]]; then
    printf '  - clear unrelated staged non-manifest paths before trusting INDEX/STAGED deployment proof, or rerun with --allow-extra-staged if the wider staged set is intentional\n' >&2
  fi
  printf '  - prepare the deployment candidate safely with bash tools/prepare-release-automation-deployment.sh --dry-run --fetch && bash tools/prepare-release-automation-deployment.sh --fetch\n' >&2
  printf '  - or use the lower-level helpers directly: bash tools/stage-release-automation-surfaces.sh --dry-run && bash tools/stage-release-automation-surfaces.sh\n' >&2
  printf '  - inspect the staged deployment diff explicitly with bash tools/verify-release-automation-deployment.sh --local-ref INDEX --fetch\n' >&2
  printf '  - commit/push the missing or drifting automation surfaces from %s to %s\n' "${LOCAL_REF}" "${REMOTE_COMPARE_REF}" >&2
  printf '  - or rerun with --path <path> to narrow the comparison to a specific surface\n' >&2
  printf '  - after deployment, re-run tools/verify-published-release.sh or tools/audit-published-releases.sh against live GitHub state\n' >&2
else
  path_filters_json="$(printf '%s\n' "${PATH_FILTERS[@]}" | jq -R . | jq -s .)"
  if [[ "${extra_staged_non_manifest_count}" -gt 0 ]]; then
    extra_staged_non_manifest_paths_json="$(printf '%s\n' "${extra_staged_non_manifest_paths[@]}" | jq -R . | jq -s .)"
  else
    extra_staged_non_manifest_paths_json='[]'
  fi
  jq -n \
    --arg remote "${REMOTE_NAME}" \
    --arg remote_ref "${REMOTE_COMPARE_REF}" \
    --arg local_ref "${LOCAL_REF}" \
    --arg summary_text "${summary_text}" \
    --argjson fetched "${fetched_json}" \
    --argjson allow_extra_staged "$( [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson path_filters "${path_filters_json}" \
    --argjson match_count "${match_count}" \
    --argjson drift_count "${drift_count}" \
    --argjson missing_remote_count "${missing_remote_count}" \
    --argjson missing_local_count "${missing_local_count}" \
    --argjson extra_staged_non_manifest_count "${extra_staged_non_manifest_count}" \
    --argjson extra_staged_non_manifest_paths "${extra_staged_non_manifest_paths_json}" \
    --slurpfile items "${items_file}" \
    '{
      tool: "verify-release-automation-deployment",
      remote: $remote,
      remote_ref: $remote_ref,
      local_ref: $local_ref,
      fetched: $fetched,
      allow_extra_staged: $allow_extra_staged,
      path_filters: $path_filters,
      result: "fail",
      counts: {
        match: $match_count,
        drift: $drift_count,
        missing_remote: $missing_remote_count,
        missing_local: $missing_local_count,
        extra_staged_non_manifest: $extra_staged_non_manifest_count
      },
      extra_staged_non_manifest_paths: $extra_staged_non_manifest_paths,
      summary_text: $summary_text,
      message: null,
      items: $items,
      remediation: [
        "clear unrelated staged non-manifest paths before trusting INDEX/STAGED deployment proof, or rerun with --allow-extra-staged if the wider staged set is intentional",
        "prepare the deployment candidate safely with bash tools/prepare-release-automation-deployment.sh --dry-run --fetch && bash tools/prepare-release-automation-deployment.sh --fetch",
        "or use the lower-level helpers directly: bash tools/stage-release-automation-surfaces.sh --dry-run && bash tools/stage-release-automation-surfaces.sh",
        "inspect the staged deployment diff explicitly with bash tools/verify-release-automation-deployment.sh --local-ref INDEX --fetch",
        ("commit/push the missing or drifting automation surfaces from " + $local_ref + " to " + $remote_ref),
        "rerun with --path <path> to narrow the comparison to a specific surface",
        "after deployment, rerun tools/verify-published-release.sh or tools/audit-published-releases.sh against live GitHub state"
      ]
    }'
fi
exit 1
