#!/usr/bin/env bash
# v1.40.x Wave 2 privacy + supply chain + release safety regression tests.
#
# Covers F-007 (omc_redact_secrets wired into prompt-intent-router,
# pre-compact-snapshot, and omc-repro tarball), F-008 (README pins the
# install line to a tagged version), F-009 (tools/release.sh defaults
# to --tag-on-green; --legacy-eager-tag opts back into the pre-v1.40
# flow).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
PRECOMPACT="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/pre-compact-snapshot.sh"
OMC_REPRO="${REPO_ROOT}/bundle/dot-claude/omc-repro.sh"
RELEASE_SH="${REPO_ROOT}/tools/release.sh"
README="${REPO_ROOT}/README.md"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
export STATE_ROOT="${TEST_TMP}/state"
mkdir -p "${STATE_ROOT}"

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  PASS  %s\n' "${description}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n         expected to contain: %s\n' \
      "${description}" "${needle}"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf '  PASS  %s\n' "${description}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n         must NOT contain: %s\n' "${description}" "${needle}"
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
# F-007: prompt redaction across persistence paths.
printf '\n## F-007 — prompt redaction wired into persistence\n'

# Router persistence path uses PROMPT_TEXT_SAFE (the redacted variant)
if grep -q 'PROMPT_TEXT_SAFE="\$(printf' "${ROUTER}"; then
  printf '  PASS  prompt-intent-router defines PROMPT_TEXT_SAFE via omc_redact_secrets\n'
  pass=$((pass + 1))
else
  printf '  FAIL  PROMPT_TEXT_SAFE not defined in prompt-intent-router\n'
  fail=$((fail + 1))
fi

if grep -q 'last_user_prompt" "\${_omc_persisted_prompt_safe}"' "${ROUTER}"; then
  printf '  PASS  last_user_prompt write uses redacted value\n'
  pass=$((pass + 1))
else
  printf '  FAIL  last_user_prompt does not use redacted persist value\n'
  fail=$((fail + 1))
fi

# pre-compact-snapshot pipes meta/last/recent through omc_redact_secrets
if grep -q 'omc_redact_secrets' "${PRECOMPACT}"; then
  printf '  PASS  pre-compact-snapshot.sh wires omc_redact_secrets\n'
  pass=$((pass + 1))
else
  printf '  FAIL  pre-compact-snapshot.sh missing omc_redact_secrets call\n'
  fail=$((fail + 1))
fi

# omc-repro.sh sources common.sh and post-processes truncated fields
if grep -q 'omc_redact_secrets' "${OMC_REPRO}"; then
  printf '  PASS  omc-repro.sh applies omc_redact_secrets post-truncation\n'
  pass=$((pass + 1))
else
  printf '  FAIL  omc-repro.sh missing omc_redact_secrets call\n'
  fail=$((fail + 1))
fi

# Runtime check: plant a `sk-ant-` secret in a router input, then
# assert the state-tree files do NOT contain the verbatim secret.
sid="test-redact-sid"
sid_dir="${STATE_ROOT}/${sid}"
mkdir -p "${sid_dir}"
canary="sk-ant-CANARY1234567890abcdefghij"
hook_json="$(printf '{"session_id":"%s","prompt":"/ulw fix auth, key=%s","timestamp":"2026-01-01T00:00:00Z"}' "${sid}" "${canary}")"
# Set up a transient HOME so the router resolves common.sh from the repo.
test_home="${TEST_TMP}/home"
mkdir -p "${test_home}/.claude/quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${test_home}/.claude/quality-pack/memory"

HOME="${test_home}" STATE_ROOT="${STATE_ROOT}" \
  bash "${ROUTER}" <<<"${hook_json}" >/dev/null 2>&1 || true

# Now scan every file under sid_dir for the canary token.
canary_leaks=""
if [[ -d "${sid_dir}" ]]; then
  canary_leaks="$(find "${sid_dir}" -type f -exec grep -l "${canary}" {} \; 2>/dev/null || true)"
fi
if [[ -z "${canary_leaks}" ]]; then
  printf '  PASS  router does not persist sk-ant-* canary verbatim under %s\n' "${sid}"
  pass=$((pass + 1))
else
  printf '  FAIL  canary leaked to: %s\n' "${canary_leaks}"
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
# F-008: README pins install line to a tagged version.
printf '\n## F-008 — README install pin\n'
readme_contents="$(cat "${README}")"
assert_contains "README documents a pinned install line" "${readme_contents}" "OMC_REF=v1."
assert_contains "README still mentions the rolling-main option" "${readme_contents}" "Rolling install"

# ----------------------------------------------------------------------
# F-009: tools/release.sh defaults to tag-on-green; legacy-eager-tag
# is opt-in.
printf '\n## F-009 — release.sh default is tag-on-green\n'

# Static check: TAG_ON_GREEN=1 is the initial value.
if grep -E '^TAG_ON_GREEN=1$' "${RELEASE_SH}" >/dev/null; then
  printf '  PASS  TAG_ON_GREEN defaults to 1 in release.sh\n'
  pass=$((pass + 1))
else
  printf '  FAIL  TAG_ON_GREEN does not default to 1\n'
  fail=$((fail + 1))
fi

# Static check: --legacy-eager-tag flag accepted.
if grep -E -- '--legacy-eager-tag\) LEGACY_EAGER_TAG=1' "${RELEASE_SH}" >/dev/null; then
  printf '  PASS  --legacy-eager-tag flag is wired\n'
  pass=$((pass + 1))
else
  printf '  FAIL  --legacy-eager-tag flag missing\n'
  fail=$((fail + 1))
fi

# Behavioral: bare `bash release.sh X.Y.Z --dry-run` should announce
# tag-deferred-until-CI-green by default.
# Use existing test-release fixture helpers if available; otherwise
# build a minimal fixture inline.
fixture="${TEST_TMP}/release-fixture"
mkdir -p "${fixture}"
cp -r "${REPO_ROOT}/.github" "${fixture}/" 2>/dev/null || true
cp -r "${REPO_ROOT}/tools" "${fixture}/"
cp -r "${REPO_ROOT}/bundle" "${fixture}/" 2>/dev/null || true
# v1.40.x F-009 hotfix: pin the fixture VERSION to 1.39.0 so the test
# always exercises a forward 1.39.0 -> 1.40.0 bump regardless of the
# live project VERSION. Previously this copied REPO_ROOT/VERSION,
# which made the test break the moment the live project moved past
# v1.40.0 (the dry-run target hardcoded in the assertions below) —
# release.sh refuses to bump backwards.
echo "1.39.0" > "${fixture}/VERSION"
# Minimal README + CHANGELOG with an [Unreleased] section that has content.
mkdir -p "${fixture}"
printf 'placeholder for [![Version](https://img.shields.io/badge/Version-1.39.0-blue.svg)](CHANGELOG.md)\n' > "${fixture}/README.md"
printf '# Changelog\n\n## [Unreleased]\n\nA fixture-only release note line.\n\n## [1.39.0] - 2026-05-12\nfoo\n' > "${fixture}/CHANGELOG.md"
( cd "${fixture}" && git init -q && git config user.email t@t.com && git config user.name t && \
  git add -A && git commit -q -m init && git checkout -q -b main 2>/dev/null || true ) >/dev/null 2>&1

dry_out="$(cd "${fixture}" && bash tools/release.sh "1.40.0" --dry-run 2>&1)" || true
assert_contains "default --dry-run announces tag-deferred (tag-on-green)" "${dry_out}" "tag deferred until CI green"
assert_not_contains "default --dry-run does NOT eager-tag" "${dry_out}" "tagged v1.40.0 and pushed"

# Behavioral: --legacy-eager-tag dry-run still emits the eager-tag flow.
legacy_out="$(cd "${fixture}" && bash tools/release.sh "1.40.0" --dry-run --legacy-eager-tag 2>&1)" || true
assert_contains "--legacy-eager-tag dry-run emits eager tag step" "${legacy_out}" "git tag v1.40.0"
assert_contains "--legacy-eager-tag dry-run announces tagged-and-pushed" "${legacy_out}" "tagged v1.40.0 and pushed"

# Behavioral: --no-watch alone falls back to legacy-eager-tag with a notice.
nowatch_out="$(cd "${fixture}" && bash tools/release.sh "1.40.0" --dry-run --no-watch 2>&1)" || true
assert_contains "--no-watch falls back to legacy-eager-tag notice" "${nowatch_out}" "falling back to --legacy-eager-tag"

# ----------------------------------------------------------------------
printf '\n--- v1.40.x W2 privacy + supply chain + release safety: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
