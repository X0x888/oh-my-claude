#!/usr/bin/env bash
#
# test-repro-redaction.sh — regression test for the classifier_telemetry
# prompt-leak bug shipped in v1.9.0.
#
# Background: omc-repro.sh bundles session state for bug reports and
# advertises that prompt fields are truncated to REDACT_CHARS (default 80).
# In v1.9.0 the writer in common.sh and the redactor in omc-repro.sh
# disagreed on the field name (`prompt` vs `prompt_preview`), so the
# redactor's `has($field)` short-circuit passed every telemetry row through
# unredacted — leaking full 200-char prompt snippets into bundles that
# users shared with maintainers.
#
# This test exercises the end-to-end contract: write a row via the real
# record_classifier_telemetry, bundle the session via the real omc-repro.sh,
# extract the tarball, and assert the bundled classifier_telemetry.jsonl
# has the prompt truncated. Will fail against the 1.9.0 code and pass
# after the field-name alignment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_le() {
  local label="$1"
  local max="$2"
  local actual="$3"
  if [[ "${actual}" -le "${max}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected<=%s actual=%s\n' "${label}" "${max}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test isolation: point STATE_ROOT and HOME at a sandbox so the real
# omc-repro.sh writes its tarball into our temp dir instead of the user's
# home. Restore originals in cleanup even if a test asserts and exits.
# ---------------------------------------------------------------------------
TEST_TMP="$(mktemp -d)"
SANDBOX_STATE="${TEST_TMP}/state"
SANDBOX_HOME="${TEST_TMP}/home"
mkdir -p "${SANDBOX_STATE}" "${SANDBOX_HOME}/.claude"

# omc-repro.sh reads ${HOME}/.claude/VERSION for the manifest; provide one
# so the bundle generation doesn't silently stamp "unknown".
printf 'test-regression\n' > "${SANDBOX_HOME}/.claude/VERSION"

cleanup() {
  rm -rf "${TEST_TMP}"
}
trap cleanup EXIT

# Source common.sh with the sandbox STATE_ROOT already exported so
# session_file() and ensure_session_dir() write into the sandbox.
export STATE_ROOT="${SANDBOX_STATE}"
export OMC_CLASSIFIER_TELEMETRY="on"
export SESSION_ID="repro-redaction-test"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

ensure_session_dir

# ---------------------------------------------------------------------------
# Case 1: the writer emits prompt_preview — not the old `prompt` key — and
# the redactor in omc-repro.sh targets the same key. The test catches the
# 1.9.0 drift where the writer wrote `prompt` but the redactor looked for
# `prompt_preview`, so has($field) returned false and the row passed
# through unredacted.
# ---------------------------------------------------------------------------
printf 'classifier_telemetry redaction:\n'

# Build a 200-char prompt so the 80-char truncation is observable.
LONG_PROMPT="$(printf 'A%.0s' {1..200})"
assert_eq "fixture prompt is 200 chars" "200" "${#LONG_PROMPT}"

# Write via the real writer function.
record_classifier_telemetry "advisory" "coding" "${LONG_PROMPT}" "0"

TEL_FILE="${SANDBOX_STATE}/${SESSION_ID}/classifier_telemetry.jsonl"
assert_eq "writer produced a telemetry row" "1" \
  "$([[ -s "${TEL_FILE}" ]] && echo 1 || echo 0)"

# The writer-side field name must match what omc-repro.sh redacts.
# The jq filter prints 1 if `.prompt_preview` is a string, 0 otherwise.
WRITER_FIELD="$(jq -r 'if (.prompt_preview | type) == "string" then "1" else "0" end' \
  < "${TEL_FILE}")"
assert_eq "writer key is prompt_preview" "1" "${WRITER_FIELD}"

# Writer truncates at 200 chars (design — see record_classifier_telemetry).
WRITER_LEN="$(jq -r '.prompt_preview | length' < "${TEL_FILE}")"
assert_eq "writer truncates at 200 chars" "200" "${WRITER_LEN}"

# ---------------------------------------------------------------------------
# Case 2: run the real omc-repro.sh and inspect the bundled tarball. The
# prompt_preview field must be truncated to REDACT_CHARS (80) — this is
# the contract advertised in the closing message of omc-repro.sh and the
# header docstring.
# ---------------------------------------------------------------------------
REPRO_SCRIPT="${REPO_ROOT}/bundle/dot-claude/omc-repro.sh"

# Redirect HOME so the tarball lands inside our sandbox. omc-repro.sh
# derives BUNDLE_DIR from HOME, so this also controls the VERSION lookup.
# Capture exit via `|| REPRO_EXIT=$?` so a non-zero exit surfaces as an
# assertion failure instead of aborting the whole test under `set -e`
# (a plain `$?` after a command-substitution assignment would always be 0).
REPRO_EXIT=0
REPRO_OUT="$(HOME="${SANDBOX_HOME}" bash "${REPRO_SCRIPT}" "${SESSION_ID}" 2>&1)" \
  || REPRO_EXIT=$?
assert_eq "omc-repro.sh exits 0" "0" "${REPRO_EXIT}"

# Find the tarball by pattern — omc-repro.sh encodes a timestamp we can't
# predict, so glob for it.
shopt -s nullglob
TARBALLS=("${SANDBOX_HOME}"/omc-repro-"${SESSION_ID}"-*.tar.gz)
shopt -u nullglob
assert_eq "exactly one tarball produced" "1" "${#TARBALLS[@]}"

if [[ "${#TARBALLS[@]}" -ne 1 ]]; then
  printf 'bundler output was:\n%s\n' "${REPRO_OUT}" >&2
  printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
  exit 1
fi

TARBALL="${TARBALLS[0]}"

# Extract into an isolated dir and inspect the redacted telemetry file.
EXTRACT_DIR="${TEST_TMP}/extracted"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${TARBALL}" -C "${EXTRACT_DIR}"

BUNDLED_TEL="$(find "${EXTRACT_DIR}" -name 'classifier_telemetry.jsonl' -print -quit)"
assert_eq "bundled tarball contains classifier_telemetry.jsonl" "1" \
  "$([[ -n "${BUNDLED_TEL}" && -s "${BUNDLED_TEL}" ]] && echo 1 || echo 0)"

# The actual regression assertion: prompt_preview in the bundled file
# must be <=80 chars. Before the fix this was 200 (unredacted) because
# has($field) short-circuited on a missing key.
BUNDLED_LEN="$(jq -r '.prompt_preview | length' < "${BUNDLED_TEL}")"
assert_le "bundled prompt_preview is redacted to <=80 chars" "80" "${BUNDLED_LEN}"
assert_eq "bundled prompt_preview is exactly 80 chars" "80" "${BUNDLED_LEN}"

# Sanity check: the bundled row is still valid JSON and carries the other
# schema fields — redaction should not drop the row entirely.
BUNDLED_INTENT="$(jq -r '.intent' < "${BUNDLED_TEL}")"
assert_eq "bundled row preserves intent" "advisory" "${BUNDLED_INTENT}"

# ---------------------------------------------------------------------------
# Case 3 (v1.40.0 F-008): the fallback path must FAIL-CLOSED, not silently
# cat-passthrough. Prior behavior: if common.sh couldn't be sourced, the
# script installed a no-op omc_redact_secrets and bundled secrets verbatim.
# The hardened behavior is to abort with a stderr warning naming the failure
# mode, and require OMC_REPRO_ALLOW_UNREDACTED=1 to opt back into the
# legacy unredacted-bundle path.
#
# To exercise the fallback we copy omc-repro.sh into an isolated directory
# without the skills/autowork/scripts/common.sh sibling, so the source path
# resolves to a missing file and omc_redact_secrets stays undefined.
# ---------------------------------------------------------------------------
printf '\nomc-repro fallback path (F-008):\n'

ISO_DIR="${TEST_TMP}/iso"
mkdir -p "${ISO_DIR}"
cp "${REPRO_SCRIPT}" "${ISO_DIR}/omc-repro.sh"

# Sub-case 3a: default mode — must abort with exit 2 and stderr message.
ISO_EXIT=0
ISO_STDERR_FILE="${TEST_TMP}/iso-stderr.txt"
HOME="${SANDBOX_HOME}" bash "${ISO_DIR}/omc-repro.sh" "${SESSION_ID}" \
  >/dev/null 2>"${ISO_STDERR_FILE}" || ISO_EXIT=$?
assert_eq "fallback default aborts with exit 2" "2" "${ISO_EXIT}"

if grep -Fq 'omc_redact_secrets is unavailable' "${ISO_STDERR_FILE}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: fallback default emits stderr error naming omc_redact_secrets\n' >&2
  printf '    stderr was: %s\n' "$(cat "${ISO_STDERR_FILE}")" >&2
  fail=$((fail + 1))
fi

# The fallback must NOT write any tarball when it aborts.
shopt -s nullglob
ISO_TARBALLS=("${SANDBOX_HOME}"/omc-repro-*-iso-*.tar.gz)
shopt -u nullglob
assert_eq "fallback default writes no tarball" "0" "${#ISO_TARBALLS[@]}"

# Sub-case 3b: opt-in mode (OMC_REPRO_ALLOW_UNREDACTED=1) — must emit the
# WARNING line and proceed (exit 0). We don't assert the tarball contents
# here — the contract is "agent opted out of redaction; secrets may flow
# through". Just confirm the path is reachable and emits the warning.
OPT_EXIT=0
OPT_STDERR_FILE="${TEST_TMP}/opt-stderr.txt"
HOME="${SANDBOX_HOME}" OMC_REPRO_ALLOW_UNREDACTED=1 \
  bash "${ISO_DIR}/omc-repro.sh" "${SESSION_ID}" \
  >/dev/null 2>"${OPT_STDERR_FILE}" || OPT_EXIT=$?
assert_eq "fallback opt-in exits 0" "0" "${OPT_EXIT}"

if grep -Fq 'OMC_REPRO_ALLOW_UNREDACTED=1 set; bundling without' "${OPT_STDERR_FILE}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: fallback opt-in emits stderr WARNING line\n' >&2
  printf '    stderr was: %s\n' "$(cat "${OPT_STDERR_FILE}")" >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
