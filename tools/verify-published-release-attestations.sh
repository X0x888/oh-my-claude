#!/usr/bin/env bash
#
# tools/verify-published-release-attestations.sh — verify that the
# published release assets for vX.Y.Z are covered by GitHub artifact
# attestations from the canonical signer workflow.

set -euo pipefail

VERSION_ARG=""
REPO_OVERRIDE=""
SIGNER_WORKFLOW_OVERRIDE=""
SOURCE_REF_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: bash tools/verify-published-release-attestations.sh X.Y.Z [--repo <owner/name>] [--signer-workflow <workflow-id>] [--source-ref <git-ref>]

Verifies that the attached source-bundle assets for vX.Y.Z have valid
GitHub artifact attestations issued by the canonical signer workflow.

Policy enforced by default:
  - repo: current gh repo (or --repo override)
  - signer workflow: <repo>/.github/workflows/attest-release-assets.yml
  - self-hosted runners are denied

Trust model — what this script actually verifies:
  An attestation matches when (a) gh attestation verify finds a Sigstore
  bundle for the published artifact's SHA-256, (b) the bundle's signing
  identity matches --signer-workflow, and (c) the runner was not
  self-hosted. The artifact bytes are bound to the signer workflow's
  identity, which transitively binds them to whatever commit the workflow
  archived AT BUILD TIME. The attestation does not include a free-form
  "this came from tag vX.Y.Z" claim — the binding is through the canonical
  rebuild step inside attest-release-assets.yml, which uses --ref
  refs/tags/vX.Y.Z^{commit}.

What --source-ref does NOT do here:
  The attestation is signed from the workflow's own ref (refs/heads/main),
  NOT from refs/tags/vX.Y.Z. Setting --source-ref=refs/tags/vX.Y.Z would
  cause gh attestation verify to fail because it compares against the
  workflow_ref. The build-time refs/tags/X^{commit} archive checkout is
  enforced by the workflow source itself, not by the attestation predicate.
  Use --source-ref ONLY when your signer workflow runs FROM the release
  tag (uncommon — would require workflows/<file>.yml to be present in the
  historical tag's source tree). For this project's workflow design,
  leaving --source-ref unset is the correct (and verified-equivalent)
  default.

Options:
  --repo <owner/name>            Override the GitHub repo slug.
  --signer-workflow <workflow>   Override the signer workflow identity used
                                 with gh attestation verify.
  --source-ref <git-ref>         Optionally enforce a SPECIFIC source ref in
                                 the attestation. See "Trust model" above —
                                 the right value here is the WORKFLOW ref
                                 (refs/heads/main), NOT the release tag. Most
                                 callers should leave this unset.
EOF
}

err() { printf 'verify-published-release-attestations: %s\n' "$1" >&2; exit 1; }
ok()  { printf 'verify-published-release-attestations: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --signer-workflow)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SIGNER_WORKFLOW_OVERRIDE="$2"
      shift 2
      ;;
    --source-ref)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SOURCE_REF_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'verify-published-release-attestations: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'verify-published-release-attestations: unexpected positional arg: %s\n' "$1" >&2
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

SIGNER_WORKFLOW="${SIGNER_WORKFLOW_OVERRIDE:-${REPO_SLUG}/.github/workflows/attest-release-assets.yml}"
SOURCE_REF="${SOURCE_REF_OVERRIDE:-}"
asset_stem="oh-my-claude-v${VERSION_ARG}"

TMP_DIR="$(mktemp -d -t omc-release-attestation-verify-XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

if ! gh release download "v${VERSION_ARG}" --repo "${REPO_SLUG}" --dir "${TMP_DIR}" \
  --pattern "${asset_stem}.tar.gz" \
  --pattern "${asset_stem}.zip" \
  --pattern "${asset_stem}.SHA256SUMS" >/dev/null 2>&1; then
  err "could not download canonical release assets for ${REPO_SLUG} v${VERSION_ARG}"
fi

assets=(
  "${TMP_DIR}/${asset_stem}.tar.gz"
  "${TMP_DIR}/${asset_stem}.zip"
  "${TMP_DIR}/${asset_stem}.SHA256SUMS"
)

for asset in "${assets[@]}"; do
  [[ -f "${asset}" ]] || err "missing downloaded asset: $(basename "${asset}")"
done

failures=()
for asset in "${assets[@]}"; do
  verify_args=(
    gh attestation verify "${asset}"
    --repo "${REPO_SLUG}"
    --signer-workflow "${SIGNER_WORKFLOW}"
    --deny-self-hosted-runners
  )
  if [[ -n "${SOURCE_REF}" ]]; then
    verify_args+=(--source-ref "${SOURCE_REF}")
  fi
  if ! out="$("${verify_args[@]}" 2>&1)"; then
    failures+=("$(basename "${asset}"): $(printf '%s' "${out}" | head -1)")
  fi
done

if [[ "${#failures[@]}" -eq 0 ]]; then
  ok "published release attestations are canonical for ${REPO_SLUG} v${VERSION_ARG}"
  exit 0
fi

printf 'verify-published-release-attestations: published release attestations mismatch for %s v%s\n' "${REPO_SLUG}" "${VERSION_ARG}" >&2
for failure in "${failures[@]}"; do
  printf '  - %s\n' "${failure}" >&2
done
printf 'verify-published-release-attestations: remediation:\n' >&2
printf '  Wait for or rerun the signer workflow:\n' >&2
printf '    gh workflow run attest-release-assets.yml -R %s -f tag=v%s\n' "${REPO_SLUG}" "${VERSION_ARG}" >&2
printf '  Then verify again with:\n' >&2
printf '    bash tools/verify-published-release-attestations.sh %s --repo %s\n' "${VERSION_ARG}" "${REPO_SLUG}" >&2
exit 1
