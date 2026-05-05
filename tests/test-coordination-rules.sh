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
# This broadened version enforces five lockstep contracts from
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
#   4. Repo-count lockstep. The live filesystem counts for agents,
#      skills, lifecycle hooks, autowork scripts, and tests MUST match
#      the user-facing counts in README.md, AGENTS.md, and CLAUDE.md.
#
#   5. Release-history lockstep. Every semver git tag `vX.Y.Z` MUST
#      have a matching `## [X.Y.Z]` heading in CHANGELOG.md.
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
# Contract 4 — Repo-count lockstep
# ----------------------------------------------------------------------
printf '\nContract 4: repo-count lockstep\n'

README_MD="${REPO_ROOT}/README.md"
AGENTS_MD="${REPO_ROOT}/AGENTS.md"
CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"
QP_SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts"
AUTOWORK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

agent_count="$(find "${REPO_ROOT}/bundle/dot-claude/agents" -maxdepth 1 -name '*.md' | wc -l | awk '{print $1}')"
skill_count="$(find "${REPO_ROOT}/bundle/dot-claude/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' | wc -l | awk '{print $1}')"
lifecycle_count="$(find "${QP_SCRIPTS_DIR}" -maxdepth 1 -name '*.sh' | wc -l | awk '{print $1}')"
autowork_count="$(find "${AUTOWORK_DIR}" -maxdepth 1 -name '*.sh' | wc -l | awk '{print $1}')"
test_sh_count="$(find "${REPO_ROOT}/tests" -maxdepth 1 -name 'test-*.sh' | wc -l | awk '{print $1}')"
test_py_count="$(find "${REPO_ROOT}/tests" -maxdepth 1 -name 'test_*.py' | wc -l | awk '{print $1}')"
ci_pinned_count="$(printf '%s\n' "${ci_pinned_tests}" | grep -c . || true)"

assert_doc_match() {
  local label="$1" pattern="$2" path="$3" detail="$4"
  if grep -qE "${pattern}" "${path}"; then
    assert_pass "${label}"
  else
    assert_fail "${label}" "${detail}"
  fi
}

assert_doc_match "C4: README agent headline count" \
  "^\\*\\*${agent_count} specialist agents — none can edit files;" \
  "${README_MD}" \
  "README.md should describe the live agent count (${agent_count}) in the Permissioned agents section"

assert_doc_match "C4: README repository agent count" \
  "^│   ├── agents/[[:space:]]+\\(${agent_count} agents\\)" \
  "${README_MD}" \
  "README.md repository tree should report ${agent_count} agents"

assert_doc_match "C4: README repository skill count" \
  "^│   ├── skills/[[:space:]]+\\(${skill_count} skills\\)" \
  "${README_MD}" \
  "README.md repository tree should report ${skill_count} skills"

assert_doc_match "C4: README repository test count" \
  "^├── tests/[[:space:]]+\\(${test_sh_count} bash \\+ ${test_py_count} py\\)" \
  "${README_MD}" \
  "README.md repository tree should report ${test_sh_count} bash + ${test_py_count} py tests"

assert_doc_match "C4: AGENTS architecture agent count" \
  "agents/[[:space:]]+# ${agent_count} specialist agent definitions \\(.md\\)" \
  "${AGENTS_MD}" \
  "AGENTS.md architecture diagram should report ${agent_count} agents"

assert_doc_match "C4: AGENTS lifecycle count" \
  "scripts/[[:space:]]+# ${lifecycle_count} lifecycle scripts" \
  "${AGENTS_MD}" \
  "AGENTS.md architecture diagram should report ${lifecycle_count} lifecycle scripts"

assert_doc_match "C4: AGENTS skill count" \
  "skills/[[:space:]]+# ${skill_count} skill definitions, each in <name>/SKILL.md" \
  "${AGENTS_MD}" \
  "AGENTS.md architecture diagram should report ${skill_count} skills"

assert_doc_match "C4: AGENTS autowork count" \
  "autowork/scripts/[[:space:]]+# ${autowork_count} autowork hook scripts and utilities" \
  "${AGENTS_MD}" \
  "AGENTS.md architecture diagram should report ${autowork_count} autowork scripts"

assert_doc_match "C4: AGENTS test count" \
  "tests/[[:space:]]+# ${test_sh_count} bash \\+ ${test_py_count} python test scripts" \
  "${AGENTS_MD}" \
  "AGENTS.md architecture diagram should report ${test_sh_count} bash + ${test_py_count} python tests"

assert_doc_match "C4: CLAUDE agent count" \
  "bundle/dot-claude/agents/.*— ${agent_count} specialist agent definitions" \
  "${CLAUDE_MD}" \
  "CLAUDE.md should report ${agent_count} agents in Key Directories"

assert_doc_match "C4: CLAUDE lifecycle count" \
  "bundle/dot-claude/quality-pack/scripts/.*— ${lifecycle_count} lifecycle hooks" \
  "${CLAUDE_MD}" \
  "CLAUDE.md should report ${lifecycle_count} lifecycle hooks in Key Directories"

assert_doc_match "C4: CLAUDE skill count" \
  "bundle/dot-claude/skills/.*— ${skill_count} skill definitions" \
  "${CLAUDE_MD}" \
  "CLAUDE.md should report ${skill_count} skills in Key Directories"

assert_doc_match "C4: CLAUDE autowork count" \
  "bundle/dot-claude/skills/autowork/scripts/.*— ${autowork_count} autowork hooks \\+ helpers;" \
  "${CLAUDE_MD}" \
  "CLAUDE.md should report ${autowork_count} autowork hooks + helpers in Key Directories"

assert_doc_match "C4: CLAUDE test count" \
  "tests/.*— ${test_sh_count} bash \\+ ${test_py_count} python test scripts \\(${ci_pinned_count} bash CI-pinned" \
  "${CLAUDE_MD}" \
  "CLAUDE.md should report ${test_sh_count} bash + ${test_py_count} python tests and ${ci_pinned_count} CI-pinned bash suites"

# ----------------------------------------------------------------------
# Contract 5 — Release-history lockstep
# ----------------------------------------------------------------------
printf '\nContract 5: release-history lockstep\n'

release_tags="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | LC_ALL=C sort -u)"
tag_count="$(printf '%s\n' "${release_tags}" | grep -c . || true)"
printf '  semver tags: %d\n' "${tag_count}"

if [[ "${tag_count}" -eq 0 ]]; then
  assert_fail "C5: no semver git tags available" \
    "release-history contract requires a tag-aware clone; fetch tags (CI should use fetch-depth: 0)"
else
  changelog_versions="$(grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "${REPO_ROOT}/CHANGELOG.md" \
    | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/v\1/' \
    | LC_ALL=C sort -u)"

  missing_in_changelog="$(comm -23 <(printf '%s\n' "${release_tags}") <(printf '%s\n' "${changelog_versions}"))"
  extra_in_changelog="$(comm -13 <(printf '%s\n' "${release_tags}") <(printf '%s\n' "${changelog_versions}"))"
  version_tag="v$(tr -d '\n' < "${REPO_ROOT}/VERSION")"

  if [[ -z "${missing_in_changelog}" ]]; then
    assert_pass "C5: every semver tag has a changelog heading"
  else
    assert_fail "C5: semver tags missing from CHANGELOG.md" \
      "missing headings for: $(printf '%s' "${missing_in_changelog}" | paste -sd ', ' -)"
  fi

  if [[ -z "${extra_in_changelog}" ]]; then
    assert_pass "C5: changelog headings have matching semver tags"
  else
    assert_fail "C5: CHANGELOG.md headings missing git tags" \
      "missing tags for: $(printf '%s' "${extra_in_changelog}" | paste -sd ', ' -)"
  fi

  if printf '%s\n' "${changelog_versions}" | grep -qx "${version_tag}"; then
    assert_pass "C5: VERSION file exists in changelog history"
  else
    assert_fail "C5: VERSION missing from changelog history" \
      "VERSION=$(tr -d '\n' < "${REPO_ROOT}/VERSION") has no matching changelog heading"
  fi
fi

# ----------------------------------------------------------------------
printf '\n=== coordination-rules tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
