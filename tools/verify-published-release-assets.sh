#!/usr/bin/env bash
#
# tools/verify-published-release-assets.sh — verify that the live GitHub
# release for vX.Y.Z publishes canonical attached source bundles and the
# matching SHA256 manifest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSET_HELPER="${SCRIPT_DIR}/build-release-assets.sh"

VERSION_ARG=""
REPO_OVERRIDE=""
FIX=0

usage() {
  cat <<'EOF'
Usage: bash tools/verify-published-release-assets.sh X.Y.Z [--repo <owner/name>] [--fix]

Verifies that the published GitHub release for vX.Y.Z includes the canonical
attached source bundles and checksum manifest:
  - oh-my-claude-vX.Y.Z.tar.gz
  - oh-my-claude-vX.Y.Z.zip
  - oh-my-claude-vX.Y.Z.SHA256SUMS

The verifier downloads those assets, checks that the SHA256 manifest matches
the downloaded files, then checks that the published manifest matches a fresh
local build from the tagged commit.

Options:
  --repo <owner/name>  Override the GitHub repo slug. Defaults to the current
                       gh repo.
  --fix                Build and upload the canonical assets with --clobber,
                       then re-verify.
EOF
}

err() { printf 'verify-published-release-assets: %s\n' "$1" >&2; exit 1; }
ok()  { printf 'verify-published-release-assets: %s\n' "$1"; }

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
      printf 'verify-published-release-assets: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'verify-published-release-assets: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
[[ -x "${ASSET_HELPER}" ]] || err "asset helper missing: ${ASSET_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

sha256_of_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    err "neither sha256sum nor shasum found in PATH"
  fi
}

asset_stem="oh-my-claude-v${VERSION_ARG}"
tar_name="${asset_stem}.tar.gz"
zip_name="${asset_stem}.zip"
sums_name="${asset_stem}.SHA256SUMS"

EXPECTED_DIR="$(mktemp -d -t omc-release-assets-expected-XXXXXX)"
DOWNLOAD_DIR="$(mktemp -d -t omc-release-assets-download-XXXXXX)"
cleanup() { rm -rf "${EXPECTED_DIR}" "${DOWNLOAD_DIR}"; }
trap cleanup EXIT

bash "${ASSET_HELPER}" "${VERSION_ARG}" --out-dir "${EXPECTED_DIR}" >/dev/null

download_out=""
download_rc=0
if download_out="$(gh release download "v${VERSION_ARG}" --repo "${REPO_SLUG}" --dir "${DOWNLOAD_DIR}" \
  --pattern "${tar_name}" \
  --pattern "${zip_name}" \
  --pattern "${sums_name}" 2>&1)"; then
  :
else
  download_rc=$?
fi

ISSUES=()
if [[ "${download_rc}" -ne 0 ]]; then
  ISSUES+=("could not download required assets from ${REPO_SLUG} v${VERSION_ARG}: $(printf '%s' "${download_out}" | head -1)")
fi

downloaded_tar="${DOWNLOAD_DIR}/${tar_name}"
downloaded_zip="${DOWNLOAD_DIR}/${zip_name}"
downloaded_sums="${DOWNLOAD_DIR}/${sums_name}"
expected_sums="${EXPECTED_DIR}/${sums_name}"

[[ -f "${downloaded_tar}" ]] || ISSUES+=("missing attached asset ${tar_name}")
[[ -f "${downloaded_zip}" ]] || ISSUES+=("missing attached asset ${zip_name}")
[[ -f "${downloaded_sums}" ]] || ISSUES+=("missing attached asset ${sums_name}")

if [[ -f "${downloaded_tar}" && -f "${downloaded_zip}" && -f "${downloaded_sums}" ]]; then
  tar_hash="$(sha256_of_file "${downloaded_tar}")"
  zip_hash="$(sha256_of_file "${downloaded_zip}")"
  if ! grep -Fxq "${tar_hash}  ${tar_name}" "${downloaded_sums}"; then
    ISSUES+=("${sums_name} does not match downloaded ${tar_name}")
  fi
  if ! grep -Fxq "${zip_hash}  ${zip_name}" "${downloaded_sums}"; then
    ISSUES+=("${sums_name} does not match downloaded ${zip_name}")
  fi
  if ! cmp -s "${expected_sums}" "${downloaded_sums}"; then
    ISSUES+=("${sums_name} does not match a fresh local build from v${VERSION_ARG}")
  fi
fi

if [[ "${#ISSUES[@]}" -eq 0 ]]; then
  ok "published release assets are canonical for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

if [[ "${FIX}" -eq 1 ]]; then
  gh release upload "v${VERSION_ARG}" --repo "${REPO_SLUG}" --clobber \
    "${EXPECTED_DIR}/${tar_name}" \
    "${EXPECTED_DIR}/${zip_name}" \
    "${EXPECTED_DIR}/${sums_name}" >/dev/null
  rm -rf "${DOWNLOAD_DIR}"
  mkdir -p "${DOWNLOAD_DIR}"
  gh release download "v${VERSION_ARG}" --repo "${REPO_SLUG}" --dir "${DOWNLOAD_DIR}" \
    --pattern "${tar_name}" \
    --pattern "${zip_name}" \
    --pattern "${sums_name}" >/dev/null
  if ! cmp -s "${expected_sums}" "${DOWNLOAD_DIR}/${sums_name}"; then
    err "published release assets still mismatch after --fix for ${REPO_SLUG} v${VERSION_ARG}"
  fi
  tar_hash="$(sha256_of_file "${DOWNLOAD_DIR}/${tar_name}")"
  zip_hash="$(sha256_of_file "${DOWNLOAD_DIR}/${zip_name}")"
  grep -Fxq "${tar_hash}  ${tar_name}" "${DOWNLOAD_DIR}/${sums_name}" || err "uploaded ${sums_name} does not match ${tar_name} after --fix"
  grep -Fxq "${zip_hash}  ${zip_name}" "${DOWNLOAD_DIR}/${sums_name}" || err "uploaded ${sums_name} does not match ${zip_name} after --fix"
  ok "published release assets repaired and verified for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

printf 'verify-published-release-assets: published release assets mismatch for %s v%s\n' "${REPO_SLUG}" "${VERSION_ARG}" >&2
for issue in "${ISSUES[@]}"; do
  printf '  - %s\n' "${issue}" >&2
done
printf 'verify-published-release-assets: remediation:\n' >&2
printf '  ASSET_DIR="$(mktemp -d -t omc-release-assets-XXXXXX)"\n' >&2
printf '  bash tools/build-release-assets.sh %s --out-dir "$ASSET_DIR"\n' "${VERSION_ARG}" >&2
printf '  gh release upload v%s --repo %s --clobber \\\n' "${VERSION_ARG}" "${REPO_SLUG}" >&2
printf '    "$ASSET_DIR/%s" \\\n' "${tar_name}" >&2
printf '    "$ASSET_DIR/%s" \\\n' "${zip_name}" >&2
printf '    "$ASSET_DIR/%s"\n' "${sums_name}" >&2
printf '  then verify with: bash tools/verify-published-release-assets.sh %s --repo %s\n' "${VERSION_ARG}" "${REPO_SLUG}" >&2
exit 1
