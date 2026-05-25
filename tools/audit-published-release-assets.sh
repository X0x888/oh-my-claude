#!/usr/bin/env bash
#
# tools/audit-published-release-assets.sh — batch-audit published GitHub
# release assets against the canonical source-bundle asset contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY_HELPER="${SCRIPT_DIR}/verify-published-release-assets.sh"

REPO_OVERRIDE=""
LIMIT=100
FIX=0
TAG_LIST=()

usage() {
  cat <<'EOF'
Usage: bash tools/audit-published-release-assets.sh [--repo <owner/name>] [--limit <N>] [--tag <vX.Y.Z>]... [--fix]

Audits published GitHub release assets in batch by calling
tools/verify-published-release-assets.sh for each selected tag.

Options:
  --repo <owner/name>  Override the GitHub repo slug. Defaults to the current
                       gh repo.
  --limit <N>          Number of published releases to inspect when no explicit
                       --tag filters are provided. Default: 100.
  --tag <vX.Y.Z>       Audit a specific published release tag. Repeatable.
  --fix                Repair drifting published release assets in place.
EOF
}

err() { printf 'audit-published-release-assets: %s\n' "$1" >&2; exit 1; }
note() { printf 'audit-published-release-assets: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      LIMIT="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      TAG_LIST+=("$2")
      shift 2
      ;;
    --fix)
      FIX=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'audit-published-release-assets: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'audit-published-release-assets: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "${LIMIT}" =~ ^[1-9][0-9]*$ ]] || err "--limit must be a positive integer, got: ${LIMIT}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
[[ -x "${VERIFY_HELPER}" ]] || err "verify helper missing: ${VERIFY_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

if [[ "${#TAG_LIST[@]}" -eq 0 ]]; then
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && TAG_LIST+=("${tag}")
  done < <(gh release list --repo "${REPO_SLUG}" --limit "${LIMIT}" --json tagName --jq '.[].tagName')
fi

[[ "${#TAG_LIST[@]}" -gt 0 ]] || err "no published release tags found for ${REPO_SLUG}"

pass_count=0
fixed_count=0
fail_count=0

for tag in "${TAG_LIST[@]}"; do
  [[ -z "${tag}" ]] && continue
  version="${tag#v}"
  if [[ "${FIX}" -eq 1 ]]; then
    if out="$(bash "${VERIFY_HELPER}" "${version}" --repo "${REPO_SLUG}" --fix 2>&1)"; then
      if [[ "${out}" == *"repaired and verified"* ]]; then
        printf 'FIXED\t%s\t%s\n' "${tag}" "${out}"
        fixed_count=$((fixed_count + 1))
      else
        printf 'OK\t%s\t%s\n' "${tag}" "${out}"
        pass_count=$((pass_count + 1))
      fi
    else
      printf 'FAIL\t%s\t%s\n' "${tag}" "$(printf '%s' "${out}" | head -1)"
      fail_count=$((fail_count + 1))
    fi
  else
    if out="$(bash "${VERIFY_HELPER}" "${version}" --repo "${REPO_SLUG}" 2>&1)"; then
      printf 'OK\t%s\t%s\n' "${tag}" "${out}"
      pass_count=$((pass_count + 1))
    else
      printf 'DRIFT\t%s\t%s\n' "${tag}" "$(printf '%s' "${out}" | head -1)"
      fail_count=$((fail_count + 1))
    fi
  fi
done

note "summary: ${pass_count} OK, ${fixed_count} FIXED, ${fail_count} FAIL"
[[ "${fail_count}" -eq 0 ]]
