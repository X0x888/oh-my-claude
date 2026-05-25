#!/usr/bin/env bash
#
# tools/verify-published-release-title.sh — verify that the live GitHub
# release title for vX.Y.Z matches the canonical helper output exactly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TITLE_HELPER="${SCRIPT_DIR}/render-release-title.sh"

VERSION_ARG=""
REPO_OVERRIDE=""
FIX=0

usage() {
  cat <<'EOF'
Usage: bash tools/verify-published-release-title.sh X.Y.Z [--repo <owner/name>] [--fix]

Verifies that the published GitHub release title for vX.Y.Z matches the
canonical output of tools/render-release-title.sh exactly.

Options:
  --repo <owner/name>  Override the GitHub repo slug. Defaults to the
                       current gh repo.
  --fix                If the published release title mismatches, update it
                       in place via gh release edit and then re-verify.
EOF
}

err() { printf 'verify-published-release-title: %s\n' "$1" >&2; exit 1; }
ok()  { printf 'verify-published-release-title: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
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
      printf 'verify-published-release-title: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'verify-published-release-title: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
[[ -x "${TITLE_HELPER}" ]] || err "title helper missing: ${TITLE_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

EXPECTED_TITLE="$(bash "${TITLE_HELPER}" "${VERSION_ARG}")"
ACTUAL_TITLE="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json name --jq '.name' 2>/dev/null || true)"

if [[ "${ACTUAL_TITLE}" == "${EXPECTED_TITLE}" ]]; then
  ok "published release title matches canonical helper for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

if [[ "${FIX}" -eq 1 ]]; then
  gh release edit "v${VERSION_ARG}" --repo "${REPO_SLUG}" --title "${EXPECTED_TITLE}" >/dev/null
  ACTUAL_TITLE="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json name --jq '.name' 2>/dev/null || true)"
  [[ "${ACTUAL_TITLE}" == "${EXPECTED_TITLE}" ]] || err "published release title still mismatches after --fix for ${REPO_SLUG} v${VERSION_ARG}"
  ok "published release title repaired and verified for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

printf 'verify-published-release-title: published release title mismatch for %s v%s\n' "${REPO_SLUG}" "${VERSION_ARG}" >&2
printf 'verify-published-release-title: expected title: %s\n' "${EXPECTED_TITLE}" >&2
printf 'verify-published-release-title: actual title: %s\n' "${ACTUAL_TITLE}" >&2
printf 'verify-published-release-title: remediation:\n' >&2
printf '  gh release edit v%s --repo %s --title %q\n' "${VERSION_ARG}" "${REPO_SLUG}" "${EXPECTED_TITLE}" >&2
printf '  Or GitHub web UI: set the title to: %s\n' "${EXPECTED_TITLE}" >&2
exit 1
