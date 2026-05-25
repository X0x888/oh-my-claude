#!/usr/bin/env bash
#
# tools/list-release-automation-surfaces.sh — canonical release/distribution
# automation surface manifest.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tools/list-release-automation-surfaces.sh

Prints the canonical newline-delimited list of release/distribution
automation surfaces that must be deployed together for the published
release audit stack to be trustworthy.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  printf 'list-release-automation-surfaces: unexpected argument: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

cat <<'EOF'
.github/workflows/attest-release-assets.yml
.github/workflows/validate.yml
tools/local-ci.sh
tools/list-ci-pinned-tests.sh
tools/list-release-automation-surfaces.sh
tools/stage-release-automation-surfaces.sh
tools/prepare-release-automation-deployment.sh
tools/release.sh
tools/render-release-title.sh
tools/render-release-notes.sh
tools/build-release-assets.sh
tools/verify-release-automation-deployment.sh
tools/verify-distribution-readiness.sh
tools/verify-professional-readiness.sh
tools/verify-install-readiness.sh
tools/verify-project-readiness.sh
tools/verify-published-release.sh
tools/audit-published-releases.sh
tools/wait-for-release-attestations.sh
tools/verify-published-release-attestations.sh
tools/verify-published-release-title.sh
tools/verify-published-release-body.sh
tools/verify-published-release-state.sh
tools/verify-published-release-assets.sh
tools/audit-published-release-attestations.sh
tools/audit-published-release-titles.sh
tools/audit-published-release-bodies.sh
tools/audit-published-release-states.sh
tools/audit-published-release-assets.sh
EOF
