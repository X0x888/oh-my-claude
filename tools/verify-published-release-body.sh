#!/usr/bin/env bash
#
# tools/verify-published-release-body.sh — verify that the live GitHub
# release body for vX.Y.Z matches the canonical helper output exactly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_HELPER="${SCRIPT_DIR}/render-release-notes.sh"

VERSION_ARG=""
REPO_OVERRIDE=""
SHA_OVERRIDE=""
FIX=0

usage() {
  cat <<'EOF'
Usage: bash tools/verify-published-release-body.sh X.Y.Z [--repo <owner/name>] [--sha <commit-sha>] [--fix]

Verifies that the published GitHub release body for vX.Y.Z matches the
canonical output of tools/render-release-notes.sh exactly.

Options:
  --repo <owner/name>  Override the GitHub repo slug. Defaults to the
                       current gh repo.
  --sha <commit-sha>   Override the trusted release commit. When omitted,
                       the verifier resolves the local tag first and then
                       falls back to the remote tag object via gh api.
  --fix                If the published release body mismatches, update it
                       in place via gh release edit and then re-verify.
EOF
}

err() { printf 'verify-published-release-body: %s\n' "$1" >&2; exit 1; }
ok()  { printf 'verify-published-release-body: %s\n' "$1"; }

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
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'verify-published-release-body: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'verify-published-release-body: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
[[ -x "${RENDER_HELPER}" ]] || err "render helper missing: ${RENDER_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

resolve_remote_tag_commit() {
  local ref_type ref_sha
  ref_type="$(gh api "repos/${REPO_SLUG}/git/ref/tags/v${VERSION_ARG}" --jq '.object.type' 2>/dev/null || true)"
  [[ -n "${ref_type}" ]] || err "could not resolve remote tag v${VERSION_ARG} in ${REPO_SLUG}"
  ref_sha="$(gh api "repos/${REPO_SLUG}/git/ref/tags/v${VERSION_ARG}" --jq '.object.sha' 2>/dev/null || true)"
  [[ -n "${ref_sha}" ]] || err "remote tag v${VERSION_ARG} in ${REPO_SLUG} did not expose an object sha"
  case "${ref_type}" in
    commit)
      printf '%s' "${ref_sha}"
      ;;
    tag)
      gh api "repos/${REPO_SLUG}/git/tags/${ref_sha}" --jq '.object.sha'
      ;;
    *)
      err "unsupported remote tag object type for v${VERSION_ARG}: ${ref_type}"
      ;;
  esac
}

resolve_expected_sha() {
  if [[ -n "${SHA_OVERRIDE}" ]]; then
    printf '%s' "${SHA_OVERRIDE}"
    return 0
  fi
  if git rev-parse "v${VERSION_ARG}^{commit}" >/dev/null 2>&1; then
    git rev-parse "v${VERSION_ARG}^{commit}"
    return 0
  fi
  resolve_remote_tag_commit
}

EXPECTED_SHA="$(resolve_expected_sha)"
[[ -n "${EXPECTED_SHA}" ]] || err "could not resolve trusted release commit for v${VERSION_ARG}"

EXPECTED_BODY="$(bash "${RENDER_HELPER}" "${VERSION_ARG}" --sha "${EXPECTED_SHA}")"
ACTUAL_BODY="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json body --jq '.body' 2>/dev/null || true)"
[[ -n "${ACTUAL_BODY}" ]] || err "could not read published release body for v${VERSION_ARG} from ${REPO_SLUG}"

EXP_FILE="$(mktemp -t release-body-expected-XXXXXX)"
ACT_FILE="$(mktemp -t release-body-actual-XXXXXX)"
cleanup() { rm -f "${EXP_FILE}" "${ACT_FILE}"; }
trap cleanup EXIT
printf '%s' "${EXPECTED_BODY}" > "${EXP_FILE}"
printf '%s' "${ACTUAL_BODY}" > "${ACT_FILE}"

if [[ "${ACTUAL_BODY}" == "${EXPECTED_BODY}" ]]; then
  ok "published release body matches canonical helper for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

if [[ "${FIX}" -eq 1 ]]; then
  gh release edit "v${VERSION_ARG}" --repo "${REPO_SLUG}" --notes-file "${EXP_FILE}" >/dev/null
  ACTUAL_BODY="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json body --jq '.body' 2>/dev/null || true)"
  [[ "${ACTUAL_BODY}" == "${EXPECTED_BODY}" ]] || err "published release body still mismatches after --fix for ${REPO_SLUG} v${VERSION_ARG}"
  ok "published release body repaired and verified for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

printf 'verify-published-release-body: published release body mismatch for %s v%s\n' "${REPO_SLUG}" "${VERSION_ARG}" >&2
printf 'verify-published-release-body: trusted release commit: %s\n' "${EXPECTED_SHA}" >&2
printf 'verify-published-release-body: diff (expected vs actual):\n' >&2
diff -u "${EXP_FILE}" "${ACT_FILE}" >&2 || true
printf 'verify-published-release-body: remediation:\n' >&2
printf '  bash tools/render-release-notes.sh %s --sha %s > /tmp/oh-my-claude-release-notes.md\n' "${VERSION_ARG}" "${EXPECTED_SHA}" >&2
printf '  gh release edit v%s --repo %s --notes-file /tmp/oh-my-claude-release-notes.md\n' "${VERSION_ARG}" "${REPO_SLUG}" >&2
printf '  Or GitHub web UI: paste the output of `bash tools/render-release-notes.sh %s --sha %s`\n' "${VERSION_ARG}" "${EXPECTED_SHA}" >&2
exit 1
