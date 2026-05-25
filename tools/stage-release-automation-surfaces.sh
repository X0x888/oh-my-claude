#!/usr/bin/env bash
#
# tools/stage-release-automation-surfaces.sh — stage the canonical
# release/distribution automation surface as one coherent change-set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SURFACE_LIST_HELPER="${SCRIPT_DIR}/list-release-automation-surfaces.sh"
DRY_RUN=0
JSON_MODE=0
PATH_FILTERS=()
ALLOW_EXTRA_STAGED=0
ALLOW_PARTIAL_MANIFEST=0

usage() {
  cat <<'EOF'
Usage: bash tools/stage-release-automation-surfaces.sh [options]

Stages the canonical release/distribution automation surface listed by
tools/list-release-automation-surfaces.sh so the deployment verifier,
the staged change-set, and the published release audit stack stay in
lockstep.

Options:
  --dry-run        Show which manifest paths would be staged without
                   mutating the index.
  --path <path>    Restrict staging to specific manifest path(s).
                   Repeatable. Paths outside the canonical manifest are
                   rejected so the helper stays release-surface scoped.
  --allow-extra-staged
                   Permit already-staged non-manifest paths to remain in
                   the index. By default the helper fails closed when it
                   detects staged paths outside the selected manifest set.
  --allow-partial-manifest
                   Permit dirty manifest paths outside the selected
                   `--path` subset to remain unstaged. By default the
                   helper fails closed when a narrowed selection would
                   silently prepare a partial release/distribution commit.
  --json           Emit a machine-readable JSON report instead of the
                   human text summary.
EOF
}

err() { printf 'stage-release-automation-surfaces: %s\n' "$1" >&2; exit 1; }
note() { printf 'stage-release-automation-surfaces: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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
      printf 'stage-release-automation-surfaces: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'stage-release-automation-surfaces: unexpected positional arg: %s\n' "$1" >&2
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

manifest_paths=()
while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  manifest_paths+=("${path}")
done < <(bash "${SURFACE_LIST_HELPER}")

[[ "${#manifest_paths[@]}" -gt 0 ]] || err "canonical manifest is empty"

contains_path() {
  local needle="$1"
  shift || true
  local candidate
  for candidate in "$@"; do
    [[ "${candidate}" == "${needle}" ]] && return 0
  done
  return 1
}

selected_paths=()
if [[ "${#PATH_FILTERS[@]}" -eq 0 ]]; then
  selected_paths=("${manifest_paths[@]}")
else
  for path in "${PATH_FILTERS[@]}"; do
    if ! contains_path "${path}" "${manifest_paths[@]}"; then
      err "path is not in canonical release-automation surface manifest: ${path}"
    fi
    if [[ "${#selected_paths[@]}" -eq 0 ]] || ! contains_path "${path}" "${selected_paths[@]}"; then
      selected_paths+=("${path}")
    fi
  done
fi

selected_count="${#selected_paths[@]}"
clean_count=0
dirty_count=0
staged_count=0
missing_local_count=0
extra_staged_count=0
dirty_unselected_manifest_count=0
staging_blocked=0
tmp_dir=""
items_file=""

if [[ "${JSON_MODE}" -eq 1 ]]; then
  tmp_dir="$(mktemp -d -t omc-stage-release-automation-XXXXXX)"
  items_file="${tmp_dir}/items.jsonl"
  cleanup() { rm -rf "${tmp_dir}"; }
  trap cleanup EXIT
fi

extra_staged_paths=()
while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  if ! contains_path "${path}" "${selected_paths[@]}"; then
    extra_staged_paths+=("${path}")
  fi
done < <(git diff --cached --name-only --diff-filter=ACDMRTUXB | LC_ALL=C sort -u)
extra_staged_count="${#extra_staged_paths[@]}"
if [[ "${ALLOW_EXTRA_STAGED}" -eq 0 && "${extra_staged_count}" -gt 0 ]]; then
  staging_blocked=1
fi

dirty_unselected_manifest_paths=()
dirty_unselected_manifest_statuses=()
for path in "${manifest_paths[@]}"; do
  if contains_path "${path}" "${selected_paths[@]}"; then
    continue
  fi
  if [[ "${extra_staged_count}" -gt 0 ]] && contains_path "${path}" "${extra_staged_paths[@]}"; then
    continue
  fi
  git_status="$(git status --short --untracked-files=all -- "${path}" 2>/dev/null | tr '\n' ';' | sed 's/;$//')"
  if [[ -n "${git_status}" ]]; then
    dirty_unselected_manifest_paths+=("${path}")
    dirty_unselected_manifest_statuses+=("${git_status}")
  fi
done
dirty_unselected_manifest_count="${#dirty_unselected_manifest_paths[@]}"
if [[ "${ALLOW_PARTIAL_MANIFEST}" -eq 0 && "${dirty_unselected_manifest_count}" -gt 0 ]]; then
  staging_blocked=1
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    note "dry-run over ${selected_count} manifest path(s)"
  else
    note "staging ${selected_count} manifest path(s)"
  fi
fi

for path in "${selected_paths[@]}"; do
  exists_local_json="false"
  tracked_json="false"
  action=""
  git_status=""

  if [[ -e "${path}" ]]; then
    exists_local_json="true"
  fi
  if git ls-files --error-unmatch -- "${path}" >/dev/null 2>&1; then
    tracked_json="true"
  fi

  git_status="$(git status --short --untracked-files=all -- "${path}" 2>/dev/null | tr '\n' ';' | sed 's/;$//')"

  if [[ "${exists_local_json}" != "true" && "${tracked_json}" != "true" ]]; then
    action="MISSING_LOCAL"
    missing_local_count=$((missing_local_count + 1))
  else
    if [[ -n "${git_status}" ]]; then
      dirty_count=$((dirty_count + 1))
      if [[ "${DRY_RUN}" -eq 1 || "${staging_blocked}" -eq 1 ]]; then
        action="WOULD_STAGE"
      else
        git add -A -- "${path}"
        action="STAGED"
      fi
      staged_count=$((staged_count + 1))
    else
      clean_count=$((clean_count + 1))
      action="CLEAN"
    fi
  fi

  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "${action}" "${git_status:-clean}" "${path}"
  else
    jq -nc \
      --arg path "${path}" \
      --arg action "${action}" \
      --arg git_status "${git_status}" \
      --argjson exists_local "${exists_local_json}" \
      --argjson tracked "${tracked_json}" \
      '{
        path: $path,
        action: $action,
        scope: "selected",
        exists_local: $exists_local,
        tracked: $tracked,
        git_status: (if $git_status == "" then null else $git_status end)
      }' >> "${items_file}"
  fi
done

if [[ "${extra_staged_count}" -gt 0 ]]; then
  for path in "${extra_staged_paths[@]}"; do
    if [[ "${JSON_MODE}" -eq 0 ]]; then
      printf 'EXTRA_STAGED\tcached\t%s\n' "${path}"
    else
      jq -nc \
        --arg path "${path}" \
        '{
          path: $path,
          action: "EXTRA_STAGED",
          scope: "extra_staged",
          exists_local: true,
          tracked: true,
          git_status: "cached"
        }' >> "${items_file}"
    fi
  done
fi

if [[ "${dirty_unselected_manifest_count}" -gt 0 ]]; then
  for i in "${!dirty_unselected_manifest_paths[@]}"; do
    path="${dirty_unselected_manifest_paths[$i]}"
    git_status="${dirty_unselected_manifest_statuses[$i]}"
    if [[ "${JSON_MODE}" -eq 0 ]]; then
      printf 'DIRTY_UNSELECTED_MANIFEST\t%s\t%s\n' "${git_status}" "${path}"
    else
      jq -nc \
        --arg path "${path}" \
        --arg git_status "${git_status}" \
        '{
          path: $path,
          action: "DIRTY_UNSELECTED_MANIFEST",
          scope: "dirty_unselected_manifest",
          exists_local: true,
          tracked: true,
          git_status: $git_status
        }' >> "${items_file}"
    fi
  done
fi

if [[ "${DRY_RUN}" -eq 1 || "${staging_blocked}" -eq 1 ]]; then
  summary_text="stage-release-automation-surfaces: summary: ${selected_count} selected, ${clean_count} clean, ${staged_count} would-stage, ${missing_local_count} missing_local, ${extra_staged_count} extra_staged, ${dirty_unselected_manifest_count} dirty_unselected_manifest"
else
  summary_text="stage-release-automation-surfaces: summary: ${selected_count} selected, ${clean_count} clean, ${staged_count} staged, ${missing_local_count} missing_local, ${extra_staged_count} extra_staged, ${dirty_unselected_manifest_count} dirty_unselected_manifest"
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  path_filters_json="$(printf '%s\n' "${selected_paths[@]}" | jq -R . | jq -s .)"
  if [[ "${extra_staged_count}" -gt 0 ]]; then
    extra_staged_paths_json="$(printf '%s\n' "${extra_staged_paths[@]}" | jq -R . | jq -s .)"
  else
    extra_staged_paths_json='[]'
  fi
  if [[ "${dirty_unselected_manifest_count}" -gt 0 ]]; then
    dirty_unselected_manifest_paths_json="$(printf '%s\n' "${dirty_unselected_manifest_paths[@]}" | jq -R . | jq -s .)"
  else
    dirty_unselected_manifest_paths_json='[]'
  fi
  jq -n \
    --arg summary_text "${summary_text}" \
    --argjson dry_run "$( [[ "${DRY_RUN}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson allow_extra_staged "$( [[ "${ALLOW_EXTRA_STAGED}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson allow_partial_manifest "$( [[ "${ALLOW_PARTIAL_MANIFEST}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson staging_blocked "$( [[ "${staging_blocked}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson selected_count "${selected_count}" \
    --argjson clean_count "${clean_count}" \
    --argjson dirty_count "${dirty_count}" \
    --argjson staged_count "${staged_count}" \
    --argjson missing_local_count "${missing_local_count}" \
    --argjson extra_staged_count "${extra_staged_count}" \
    --argjson dirty_unselected_manifest_count "${dirty_unselected_manifest_count}" \
    --argjson path_filters "${path_filters_json}" \
    --argjson extra_staged_paths "${extra_staged_paths_json}" \
    --argjson dirty_unselected_manifest_paths "${dirty_unselected_manifest_paths_json}" \
    --slurpfile items "${items_file}" \
    '{
      tool: "stage-release-automation-surfaces",
      dry_run: $dry_run,
      allow_extra_staged: $allow_extra_staged,
      allow_partial_manifest: $allow_partial_manifest,
      staging_blocked: $staging_blocked,
      result: (if $missing_local_count == 0 and ($staging_blocked | not) then "ok" else "fail" end),
      counts: {
        selected: $selected_count,
        clean: $clean_count,
        dirty: $dirty_count,
        staged: $staged_count,
        missing_local: $missing_local_count,
        extra_staged: $extra_staged_count,
        dirty_unselected_manifest: $dirty_unselected_manifest_count
      },
      path_filters: $path_filters,
      extra_staged_paths: $extra_staged_paths,
      dirty_unselected_manifest_paths: $dirty_unselected_manifest_paths,
      summary_text: $summary_text,
      items: $items
    }'
else
  note "summary: ${selected_count} selected, ${clean_count} clean, ${staged_count} $( [[ "${DRY_RUN}" -eq 1 || "${staging_blocked}" -eq 1 ]] && printf 'would-stage' || printf 'staged' ), ${missing_local_count} missing_local, ${extra_staged_count} extra_staged, ${dirty_unselected_manifest_count} dirty_unselected_manifest"
  if [[ "${extra_staged_count}" -gt 0 && "${ALLOW_EXTRA_STAGED}" -eq 0 ]]; then
    printf 'stage-release-automation-surfaces: refusing to stage while unrelated staged paths are present; clear them or rerun with --allow-extra-staged if intentional\n' >&2
  fi
  if [[ "${dirty_unselected_manifest_count}" -gt 0 && "${ALLOW_PARTIAL_MANIFEST}" -eq 0 ]]; then
    printf 'stage-release-automation-surfaces: refusing to stage a narrowed manifest subset while other manifest paths are dirty; include them or rerun with --allow-partial-manifest if the partial deployment commit is intentional\n' >&2
  fi
fi

[[ "${missing_local_count}" -eq 0 && "${staging_blocked}" -eq 0 ]]
