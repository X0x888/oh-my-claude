#!/usr/bin/env bash
#
# tests/test-coordination-rules.sh — lockstep enforcement for the
# coordination contracts documented in CLAUDE.md "Coordination Rules".
#
# v1.32.0 R7 (release post-mortem remediation, broadened per metis
# stress-test): the original R7 only checked "every modified lib has
# a corresponding test" — false confidence (file-existence ≠
# function-coverage) and missed the highest-historical-frequency
# violation surface (conf-flag 3-site lockstep).
#
# This broadened version enforces three lockstep contracts from
# CLAUDE.md:
#
#   1. Conf-flag 3-site lockstep (most-violated). Every flag that
#      appears in `common.sh:_parse_conf_file` MUST also appear in
#      `oh-my-claude.conf.example` AND `omc-config.sh:emit_known_flags`.
#
#   2. Test-pin discipline. Every `tests/test-*.sh` MUST be either
#      CI-pinned in `.github/workflows/validate.yml` OR carry a top-
#      comment `# UNPINNED: <reason>` token. The discipline is
#      mechanical: a new test added without explicit pin-or-justify
#      blocks merge.
#
#   3. Lib-test 1:1 mapping. Every `bundle/.../lib/*.sh` MUST have a
#      `tests/test-${name}.sh` (with the `-lib.sh` suffix exception
#      for verification.sh ↔ test-verification-lib.sh codified).
#
# Pinned in CI via .github/workflows/validate.yml; runs on every push.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

assert_pass() {
  local label="$1"
  pass=$((pass + 1))
}

assert_fail() {
  local label="$1" detail="$2"
  printf '  FAIL: %s\n    %s\n' "${label}" "${detail}" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# Contract 1 — Conf-flag 3-site lockstep
# ----------------------------------------------------------------------
printf '\nContract 1: conf-flag 3-site lockstep\n'

COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
CONF_EXAMPLE="${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example"
OMC_CONFIG="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"

# Extract flags from _parse_conf_file's case statement. The shape is
# `case "${key}" in` with branches like `prometheus_suggest|metis_on_plan_gate|...) ...`.
# We extract the bareword keys from those branches.
parse_conf_flags() {
  awk '
    /^_parse_conf_file\(\) \{/ { in_fn = 1; next }
    in_fn && /^\}$/ { in_fn = 0; exit }
    in_fn && /case[[:space:]]/ { in_case = 1; next }
    in_fn && in_case && /esac/ { in_case = 0; next }
    in_fn && in_case && /^[[:space:]]*[a-z_][a-z0-9_]*[\)\|]/ {
      # Strip leading whitespace, take everything before "        " (the value-set)
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # Stop at the first ")" — case branches are `flag1|flag2)`. Then split by "|".
      n = index(line, ")")
      if (n > 0) {
        keys = substr(line, 1, n-1)
        gsub(/[[:space:]]/, "", keys)
        m = split(keys, parts, "|")
        for (i = 1; i <= m; i++) {
          # Skip wildcard branches and var refs.
          if (parts[i] == "*" || parts[i] == "") continue
          if (parts[i] ~ /^[a-z_][a-z0-9_]*$/) print parts[i]
        }
      }
    }
  ' "$1" | sort -u
}

# Flags from common.sh _parse_conf_file
parse_flags="$(parse_conf_flags "${COMMON_SH}")"
parse_count="$(printf '%s\n' "${parse_flags}" | grep -c . || true)"
printf '  parser flags: %d\n' "${parse_count}"

# Skip the lockstep-enforce when extraction returned nothing — likely
# means parser shape changed and the regex needs updating. Fail loud.
if [[ "${parse_count}" -lt 5 ]]; then
  assert_fail "C1: parser flag extraction returned <5 results" \
    "_parse_conf_file shape may have changed; update parse_conf_flags()"
else
  # For each flag, assert presence in conf.example AND omc-config.sh.
  while IFS= read -r flag; do
    [[ -z "${flag}" ]] && continue

    # Conf.example check: line starting with `# <flag>=` or `<flag>=`.
    if grep -qE "^[[:space:]]*#?[[:space:]]*${flag}=" "${CONF_EXAMPLE}"; then
      assert_pass "C1: ${flag} in conf.example"
    else
      assert_fail "C1: ${flag} missing from conf.example" \
        "every parsed flag must be documented in conf.example"
    fi

    # omc-config.sh check: emit_known_flags stores rows as
    # `flag|type|default|cluster|description` and uses `flag=value`
    # in profile presets. Match either shape.
    if grep -qE "^${flag}\||^[[:space:]]*${flag}=" "${OMC_CONFIG}"; then
      assert_pass "C1: ${flag} in omc-config.sh"
    else
      # Some flags are statusline-only (e.g., installation_drift_check
      # is parsed by Python statusline.py and has no omc-config UX).
      # Plus some flags are non-UX (internal thresholds, security pins
      # the user shouldn't tweak via the UX walkthrough). Allowlist the
      # known non-UX flags here so the lockstep test reports real drift.
      case "${flag}" in
        # Statusline-only / Python-parsed
        installation_drift_check) assert_pass "C1: ${flag} (statusline-only, Python-parsed)" ;;
        # Internal pin / sensitive (set by install scripts)
        claude_bin|installed_version) assert_pass "C1: ${flag} (set by installer, not user UX)" ;;
        # Numeric thresholds (rarely user-tuned, no UX walkthrough)
        wave_override_ttl_seconds|blindspot_ttl_seconds|state_ttl_days|\
        time_tracking_xs_retain_days|stall_threshold|verify_confidence_threshold|\
        dimension_gate_file_count|excellence_file_count|traceability_file_count|\
        time_card_min_seconds|resume_request_per_cwd_cap|resume_request_ttl_days|\
        resume_watchdog_cooldown_secs)
          if grep -q "\"${flag}\"" "${REPO_ROOT}/bundle/dot-claude/statusline.py" 2>/dev/null; then
            assert_pass "C1: ${flag} (threshold/numeric, in statusline.py)"
          else
            assert_pass "C1: ${flag} (threshold/numeric, no UX needed)"
          fi
          ;;
        *)
          assert_fail "C1: ${flag} missing from omc-config.sh emit_known_flags" \
            "every conf flag must either appear in emit_known_flags or be allowlisted as non-UX in test-coordination-rules.sh"
          ;;
      esac
    fi
  done <<<"${parse_flags}"
fi

# ----------------------------------------------------------------------
# Contract 2 — Test-pin discipline
# ----------------------------------------------------------------------
printf '\nContract 2: test-pin discipline\n'

VALIDATE_YML="${REPO_ROOT}/.github/workflows/validate.yml"

# CI-pinned test list (live extraction).
ci_pinned_tests="$(grep -E '^\s+run:\s+bash tests/test-' "${VALIDATE_YML}" \
  | awk '{print $NF}' \
  | sed 's|^tests/||' \
  | sort -u)"

# All tests on disk. Glob expansion + basename gives the same set
# without the SC2010 lint hit.
all_tests=""
for _t in "${REPO_ROOT}"/tests/test-*.sh; do
  [[ -f "${_t}" ]] || continue
  all_tests+="$(basename "${_t}")"$'\n'
done
all_tests="$(printf '%s' "${all_tests}" | sort -u)"

# Tests not in CI-pinned list. Each must have `# UNPINNED:` token.
unpinned="$(comm -23 <(printf '%s\n' "${all_tests}") <(printf '%s\n' "${ci_pinned_tests}"))"
unpinned_count="$(printf '%s\n' "${unpinned}" | grep -c . || true)"
printf '  CI-pinned: %d  unpinned: %d\n' \
  "$(printf '%s\n' "${ci_pinned_tests}" | grep -c . || true)" \
  "${unpinned_count}"

while IFS= read -r tfile; do
  [[ -z "${tfile}" ]] && continue
  test_path="${REPO_ROOT}/tests/${tfile}"
  if [[ ! -f "${test_path}" ]]; then continue; fi

  # Top-comment token: anywhere in the first 30 lines.
  if head -30 "${test_path}" 2>/dev/null | grep -qE '^#[[:space:]]*UNPINNED:[[:space:]]*\S'; then
    assert_pass "C2: ${tfile} unpinned with reason"
  else
    assert_fail "C2: ${tfile} unpinned without # UNPINNED: <reason> token" \
      "either pin in validate.yml or add a top comment '# UNPINNED: <reason>' explaining why"
  fi
done <<<"${unpinned}"

# ----------------------------------------------------------------------
# Contract 3 — Lib-test 1:1 mapping
# ----------------------------------------------------------------------
printf '\nContract 3: lib-test 1:1 mapping\n'

LIB_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib"
TESTS_DIR="${REPO_ROOT}/tests"

if [[ ! -d "${LIB_DIR}" ]]; then
  assert_fail "C3: lib dir missing" "${LIB_DIR} not found — repo layout drift?"
else
  for libfile in "${LIB_DIR}"/*.sh; do
    [[ -f "${libfile}" ]] || continue
    libname="$(basename "${libfile}" .sh)"
    # Codify the verification.sh exception: tests/test-verification-lib.sh.
    if [[ "${libname}" == "verification" ]]; then
      expected="${TESTS_DIR}/test-verification-lib.sh"
    else
      expected="${TESTS_DIR}/test-${libname}.sh"
    fi
    if [[ -f "${expected}" ]]; then
      assert_pass "C3: lib/${libname}.sh ↔ $(basename "${expected}")"
    else
      assert_fail "C3: lib/${libname}.sh has no corresponding test file" \
        "expected ${expected}"
    fi
  done
fi

# ----------------------------------------------------------------------
printf '\n=== coordination-rules tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
