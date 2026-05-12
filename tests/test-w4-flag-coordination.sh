#!/usr/bin/env bash
# v1.40.x Wave 4 flag-coordination validator regression tests.
#
# Covers F-014 — tools/check-flag-coordination.sh audits the three
# SoT sites for the flag rule (parser case, conf.example, omc-config
# table) and exits non-zero on drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${REPO_ROOT}/tools/check-flag-coordination.sh"

pass=0
fail=0

if [[ ! -f "${VALIDATOR}" ]]; then
  printf '  FAIL  validator script missing: %s\n' "${VALIDATOR}"
  exit 1
fi

# ----------------------------------------------------------------------
# Test 1: validator exits 0 on the current repo (no drift)
printf '\n## F-014 — flag coordination validator\n'
if bash "${VALIDATOR}" >/dev/null 2>&1; then
  printf '  PASS  current repo: validator exits 0\n'
  pass=$((pass + 1))
else
  printf '  FAIL  validator says drift exists in the committed tree — fix the lockstep BEFORE landing this test\n'
  bash "${VALIDATOR}" 2>&1 | sed 's/^/    /'
  fail=$((fail + 1))
fi

# Test 2: validator exits 1 when a fixture has drift.
# Create a synthetic temp repo skeleton that mimics the SoT shape but
# omits a flag in one site.
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

mkdir -p "${TEST_TMP}/bundle/dot-claude/skills/autowork/scripts"
mkdir -p "${TEST_TMP}/bundle/dot-claude"
mkdir -p "${TEST_TMP}/tools"

# Parser with two flags (drift_test_flag and stable_flag).
cat > "${TEST_TMP}/bundle/dot-claude/skills/autowork/scripts/common.sh" <<'SH'
_parse_conf_file() {
  while IFS= read -r line; do
    case "${line%%=*}" in
      drift_test_flag) FAKE=1 ;;
      stable_flag) FAKE=1 ;;
    esac
  done
}
SH

# Example mentions only stable_flag — drift_test_flag is missing.
cat > "${TEST_TMP}/bundle/dot-claude/oh-my-claude.conf.example" <<'EOF'
# fixture template
#stable_flag=on
EOF

# omc-config mentions only stable_flag too.
cat > "${TEST_TMP}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh" <<'SH'
emit_known_flags() {
  cat <<'EOF'
stable_flag|bool|on|gates|test row
EOF
}
SH

# Copy the validator to the fixture so it resolves the fixture's paths.
cp "${VALIDATOR}" "${TEST_TMP}/tools/check-flag-coordination.sh"
chmod +x "${TEST_TMP}/tools/check-flag-coordination.sh"

(
  cd "${TEST_TMP}" || exit 1
  if ! bash tools/check-flag-coordination.sh >/tmp/check-fixture.out 2>&1; then
    printf 'fixture-exit: 1\n'
  else
    printf 'fixture-exit: 0\n'
  fi
) > "${TEST_TMP}/result.txt"

if grep -q 'fixture-exit: 1' "${TEST_TMP}/result.txt"; then
  printf '  PASS  validator exits 1 on synthetic drift fixture\n'
  pass=$((pass + 1))
else
  printf '  FAIL  validator did not detect drift in fixture\n'
  cat /tmp/check-fixture.out | sed 's/^/    /'
  fail=$((fail + 1))
fi

# Verify the fixture report names the missing flag.
if grep -q 'drift_test_flag' /tmp/check-fixture.out 2>/dev/null; then
  printf '  PASS  fixture report names the drifted flag\n'
  pass=$((pass + 1))
else
  printf '  FAIL  fixture report did not name drift_test_flag\n'
  fail=$((fail + 1))
fi

# Test 3: validator handles the parser-exempt set correctly.
# `installation_drift_check` and `model_tier` are in the
# PARSER_EXEMPT_FLAGS list; they're documented in conf.example and
# omc-config but NOT in the canonical parser. Validator must NOT
# report them as drift.
real_out="$(bash "${VALIDATOR}" 2>&1)" || true
if [[ "${real_out}" == *"flag coordination OK"* ]] && [[ "${real_out}" != *"installation_drift_check"* ]] && [[ "${real_out}" != *"model_tier"* ]]; then
  printf '  PASS  parser-exempt flags not reported as drift\n'
  pass=$((pass + 1))
else
  printf '  FAIL  validator unexpectedly named exempt flags or reported drift\n'
  printf '%s\n' "${real_out}" | sed 's/^/    /'
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf '\n--- v1.40.x W4 flag coordination: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
