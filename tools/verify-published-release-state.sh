#!/usr/bin/env bash
#
# tools/verify-published-release-state.sh — verify that the live GitHub
# release state for vX.Y.Z is published, stable, and tag-addressable.

set -euo pipefail

VERSION_ARG=""
REPO_OVERRIDE=""
FIX=0

usage() {
  cat <<'EOF'
Usage: bash tools/verify-published-release-state.sh X.Y.Z [--repo <owner/name>] [--fix]

Verifies that the published GitHub release for vX.Y.Z is:
  - attached to tag vX.Y.Z
  - not a draft
  - not a prerelease
  - published (publishedAt present)
  - resolvable via the canonical /releases/tags/vX.Y.Z API route

Options:
  --repo <owner/name>  Override the GitHub repo slug. Defaults to the
                       current gh repo.
  --fix                Repair drifting published release state in place via
                       gh release edit and then re-verify.
EOF
}

err() { printf 'verify-published-release-state: %s\n' "$1" >&2; exit 1; }
ok()  { printf 'verify-published-release-state: %s\n' "$1"; }

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
      printf 'verify-published-release-state: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'verify-published-release-state: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

expected_release_url() {
  local host repo_path
  if [[ "${REPO_SLUG}" == */*/* ]]; then
    host="${REPO_SLUG%%/*}"
    repo_path="${REPO_SLUG#*/}"
  else
    host="github.com"
    repo_path="${REPO_SLUG}"
  fi
  printf 'https://%s/%s/releases/tag/v%s' "${host}" "${repo_path}" "${VERSION_ARG}"
}

load_release_state() {
  TAG_NAME="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json tagName --jq '.tagName' 2>/dev/null || true)"
  IS_DRAFT="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json isDraft --jq '.isDraft' 2>/dev/null || true)"
  IS_PRERELEASE="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json isPrerelease --jq '.isPrerelease' 2>/dev/null || true)"
  PUBLISHED_AT="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json publishedAt --jq '.publishedAt' 2>/dev/null || true)"
  RELEASE_URL="$(gh release view "v${VERSION_ARG}" --repo "${REPO_SLUG}" --json url --jq '.url' 2>/dev/null || true)"
  TAG_ENDPOINT_TAG_NAME="$(gh api "repos/${REPO_SLUG}/releases/tags/v${VERSION_ARG}" --jq '.tag_name' 2>/dev/null || true)"
  TAG_ENDPOINT_URL="$(gh api "repos/${REPO_SLUG}/releases/tags/v${VERSION_ARG}" --jq '.html_url' 2>/dev/null || true)"
}

EXPECTED_TAG="v${VERSION_ARG}"
EXPECTED_URL="$(expected_release_url)"

ISSUES=()
assess_release_state() {
  ISSUES=()

  [[ -n "${TAG_NAME}" ]] || ISSUES+=("gh release view could not resolve tagName for ${REPO_SLUG} v${VERSION_ARG}")
  [[ "${TAG_NAME}" == "${EXPECTED_TAG}" ]] || ISSUES+=("tagName is ${TAG_NAME:-<empty>} (expected ${EXPECTED_TAG})")
  [[ "${IS_DRAFT}" == "false" ]] || ISSUES+=("isDraft is ${IS_DRAFT:-<empty>} (expected false)")
  [[ "${IS_PRERELEASE}" == "false" ]] || ISSUES+=("isPrerelease is ${IS_PRERELEASE:-<empty>} (expected false)")

  if [[ -z "${PUBLISHED_AT}" ]] || [[ "${PUBLISHED_AT}" == "0001-01-01T00:00:00Z" ]]; then
    ISSUES+=("publishedAt is ${PUBLISHED_AT:-<empty>} (expected a real publish timestamp)")
  fi

  if [[ -z "${RELEASE_URL}" ]]; then
    ISSUES+=("release url is empty")
  elif [[ "${RELEASE_URL}" != "${EXPECTED_URL}" ]]; then
    ISSUES+=("release url is ${RELEASE_URL} (expected ${EXPECTED_URL})")
  fi

  if [[ -z "${TAG_ENDPOINT_URL}" ]] || [[ -z "${TAG_ENDPOINT_TAG_NAME}" ]]; then
    ISSUES+=("REST tag endpoint repos/${REPO_SLUG}/releases/tags/${EXPECTED_TAG} did not resolve")
  else
    [[ "${TAG_ENDPOINT_TAG_NAME}" == "${EXPECTED_TAG}" ]] || ISSUES+=("REST tag endpoint tag_name is ${TAG_ENDPOINT_TAG_NAME} (expected ${EXPECTED_TAG})")
    [[ "${TAG_ENDPOINT_URL}" == "${EXPECTED_URL}" ]] || ISSUES+=("REST tag endpoint html_url is ${TAG_ENDPOINT_URL} (expected ${EXPECTED_URL})")
  fi
}

load_release_state
assess_release_state

if [[ "${#ISSUES[@]}" -eq 0 ]]; then
  ok "published release state is canonical for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

if [[ "${FIX}" -eq 1 ]]; then
  gh release edit "v${VERSION_ARG}" --repo "${REPO_SLUG}" --draft=false --prerelease=false --tag "${EXPECTED_TAG}" >/dev/null
  load_release_state
  assess_release_state
  [[ "${#ISSUES[@]}" -eq 0 ]] || err "published release state still mismatches after --fix for ${REPO_SLUG} v${VERSION_ARG}"
  ok "published release state repaired and verified for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

printf 'verify-published-release-state: published release state mismatch for %s v%s\n' "${REPO_SLUG}" "${VERSION_ARG}" >&2
for issue in "${ISSUES[@]}"; do
  printf '  - %s\n' "${issue}" >&2
done
printf 'verify-published-release-state: remediation:\n' >&2
printf '  gh release edit v%s --repo %s --draft=false --prerelease=false --tag %s\n' "${VERSION_ARG}" "${REPO_SLUG}" "${EXPECTED_TAG}" >&2
printf '  then verify with: bash tools/verify-published-release-state.sh %s --repo %s\n' "${VERSION_ARG}" "${REPO_SLUG}" >&2
printf '  Or GitHub web UI: publish the draft, clear prerelease, and ensure the canonical release URL resolves as %s\n' "${EXPECTED_URL}" >&2
exit 1
