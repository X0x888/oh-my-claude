#!/usr/bin/env bash
#
# tools/build-release-assets.sh — build canonical source-bundle release
# assets plus a SHA256 manifest for vX.Y.Z.

set -euo pipefail

VERSION_ARG=""
OUT_DIR=""
REF_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: bash tools/build-release-assets.sh X.Y.Z [--out-dir <dir>] [--ref <git-ref>]

Builds the canonical attached release assets for vX.Y.Z:
  - oh-my-claude-vX.Y.Z.tar.gz
  - oh-my-claude-vX.Y.Z.zip
  - oh-my-claude-vX.Y.Z.SHA256SUMS

Options:
  --out-dir <dir>  Destination directory. When omitted, a temp dir is
                   created and the script prints the resulting file paths.
  --ref <git-ref>  Override the git ref to archive. Defaults to
                   vX.Y.Z^{commit}.
EOF
}

err() { printf 'build-release-assets: %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REF_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'build-release-assets: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'build-release-assets: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version must be X.Y.Z, got: ${VERSION_ARG}"
command -v git >/dev/null 2>&1 || err "git not found in PATH"
command -v gzip >/dev/null 2>&1 || err "gzip not found in PATH"

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

REF_TO_ARCHIVE="${REF_OVERRIDE:-v${VERSION_ARG}^{commit}}"
if ! git rev-parse "${REF_TO_ARCHIVE}" >/dev/null 2>&1; then
  err "could not resolve archive ref: ${REF_TO_ARCHIVE}"
fi

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(mktemp -d -t omc-release-assets-XXXXXX)"
fi
mkdir -p "${OUT_DIR}"

asset_stem="oh-my-claude-v${VERSION_ARG}"
prefix="${asset_stem}/"
tar_path="${OUT_DIR}/${asset_stem}.tar.gz"
zip_path="${OUT_DIR}/${asset_stem}.zip"
sums_path="${OUT_DIR}/${asset_stem}.SHA256SUMS"

git archive --format=tar --prefix="${prefix}" "${REF_TO_ARCHIVE}" | gzip -n > "${tar_path}"
git archive --format=zip --prefix="${prefix}" -o "${zip_path}" "${REF_TO_ARCHIVE}"

(
  cd "${OUT_DIR}" || exit 1
  tar_hash="$(sha256_of_file "${asset_stem}.tar.gz")"
  zip_hash="$(sha256_of_file "${asset_stem}.zip")"
  {
    printf '%s  %s\n' "${tar_hash}" "${asset_stem}.tar.gz"
    printf '%s  %s\n' "${zip_hash}" "${asset_stem}.zip"
  } > "${asset_stem}.SHA256SUMS"
)

printf '%s\n%s\n%s\n' "${tar_path}" "${zip_path}" "${sums_path}"
