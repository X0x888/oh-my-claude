#!/usr/bin/env bash
#
# tools/render-release-notes.sh — canonical GitHub release body renderer.
#
# Emits the verified-bootstrap metadata block plus the matching
# CHANGELOG.md section for a release version. This is the single source
# of truth for the public release body consumed by tools/release.sh and
# referenced by CONTRIBUTING.md.

set -euo pipefail

VERSION_ARG=""
SHA_OVERRIDE=""
RAW_BOOTSTRAP_URL="${OMC_RELEASE_BOOTSTRAP_URL:-https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh}"
CHANGELOG_PATH="${OMC_RELEASE_CHANGELOG_PATH:-CHANGELOG.md}"

usage() {
  cat <<'EOF'
Usage: bash tools/render-release-notes.sh X.Y.Z [--sha <commit-sha>]

Renders the canonical GitHub release body for vX.Y.Z:
  - Verified bootstrap install block
  - Trusted release commit
  - CHANGELOG.md notes for that version

Options:
  --sha <commit-sha>  Override the trusted release commit. When omitted,
                      the helper resolves vX.Y.Z^{commit} and falls back to
                      HEAD when the tag does not exist yet.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SHA_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'render-release-notes: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'render-release-notes: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'render-release-notes: version must be X.Y.Z, got: %s\n' "${VERSION_ARG}" >&2
  exit 2
}

if [[ -z "${SHA_OVERRIDE}" ]]; then
  SHA_OVERRIDE="$(git rev-parse "v${VERSION_ARG}^{commit}" 2>/dev/null || git rev-parse HEAD 2>/dev/null || true)"
fi

[[ -n "${SHA_OVERRIDE}" ]] || {
  printf 'render-release-notes: could not resolve a trusted release commit for v%s\n' "${VERSION_ARG}" >&2
  exit 1
}

if [[ ! -f "${CHANGELOG_PATH}" ]]; then
  printf 'render-release-notes: CHANGELOG not found at %s\n' "${CHANGELOG_PATH}" >&2
  exit 1
fi

release_notes="$(awk "/^## \\[${VERSION_ARG}\\]/{found=1;next} /^## \\[/{if(found)exit} found" "${CHANGELOG_PATH}")"

printf 'Verified bootstrap install:\n\n'
printf '```bash\n'
printf 'OMC_REF=v%s \\\n' "${VERSION_ARG}"
printf 'OMC_EXPECTED_SHA=%s \\\n' "${SHA_OVERRIDE}"
printf 'bash -c "$(curl -fsSL %s)"\n' "${RAW_BOOTSTRAP_URL}"
printf '```\n\n'
printf 'Trusted release commit:\n`%s`\n' "${SHA_OVERRIDE}"

if [[ -n "${release_notes}" ]]; then
  printf '\n%s' "${release_notes}"
else
  printf 'warn: no CHANGELOG section found for v%s — release body will contain only bootstrap metadata\n' "${VERSION_ARG}" >&2
fi
