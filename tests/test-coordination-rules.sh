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
# This broadened version enforces seven lockstep contracts from
# CLAUDE.md:
#
#   1. Conf-flag 3-site lockstep (most-violated). Every flag that
#      appears in `common.sh:_parse_conf_file` MUST also appear in
#      `oh-my-claude.conf.example` AND `omc-config.sh:emit_known_flags`.
#
#   2. Test-pin discipline. Every `tests/test-*.sh` MUST be either
#      CI-pinned in `.github/workflows/validate.yml` OR carry a top-
#      comment `# UNPINNED: <reason>` token. Maintainer docs that tell
#      humans how to extract the CI-pinned set MUST use the shared
#      `tools/list-ci-pinned-tests.sh` helper, not a hand-rolled
#      `grep | awk` snippet that misses env-prefixed or compound
#      workflow lines. The discipline is mechanical: a new test or doc
#      change added without explicit pin-or-helper usage blocks merge.
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
#   6. Memory-file lockstep. Every `*.md` in
#      `bundle/dot-claude/quality-pack/memory/` MUST appear in
#      `bundle/dot-claude/CLAUDE.md` `@-include` list AND in
#      `verify.sh` `required_paths`. Missing either → silent failure
#      (file present but never loaded, or install verification passes
#      a broken install).
#
#   7. AGENTS tools-inventory lockstep. Every file under `tools/`
#      (depth <= 2, including nested fixture files) MUST be listed in
#      the `AGENTS.md` architecture tree `tools/` block. Missing or
#      extra entries create the wrong contributor mental model for the
#      repo's developer tooling surface.
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
CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"
CONTRIBUTING_MD="${REPO_ROOT}/CONTRIBUTING.md"
CI_PIN_HELPER_SNIPPET='bash tools/list-ci-pinned-tests.sh .github/workflows/validate.yml'
LEGACY_CI_PIN_SNIPPET="grep -E '^\\s+run:\\s+bash tests/test-' .github/workflows/validate.yml | awk '{print \$NF}'"

# CI-pinned test list (live extraction via the shared helper).
ci_pinned_tests="$(bash "${REPO_ROOT}/tools/list-ci-pinned-tests.sh" "${VALIDATE_YML}" \
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

if grep -Fq "${CI_PIN_HELPER_SNIPPET}" "${CLAUDE_MD}"; then
  assert_pass "C2: CLAUDE.md uses shared CI-pin helper"
else
  assert_fail "C2: CLAUDE.md missing shared CI-pin helper" \
    "document CI-pinned test extraction with ${CI_PIN_HELPER_SNIPPET}"
fi

if grep -Fq "${CI_PIN_HELPER_SNIPPET}" "${CONTRIBUTING_MD}"; then
  assert_pass "C2: CONTRIBUTING.md uses shared CI-pin helper"
else
  assert_fail "C2: CONTRIBUTING.md missing shared CI-pin helper" \
    "document CI-pinned test extraction with ${CI_PIN_HELPER_SNIPPET}"
fi

if grep -Fq "${LEGACY_CI_PIN_SNIPPET}" "${CLAUDE_MD}"; then
  assert_fail "C2: CLAUDE.md still uses legacy grep|awk CI-pin extraction" \
    "replace the stale regex scrape with ${CI_PIN_HELPER_SNIPPET}"
else
  assert_pass "C2: CLAUDE.md no longer uses legacy grep|awk extraction"
fi

if grep -Fq "${LEGACY_CI_PIN_SNIPPET}" "${CONTRIBUTING_MD}"; then
  assert_fail "C2: CONTRIBUTING.md still uses legacy grep|awk CI-pin extraction" \
    "replace the stale regex scrape with ${CI_PIN_HELPER_SNIPPET}"
else
  assert_pass "C2: CONTRIBUTING.md no longer uses legacy grep|awk extraction"
fi

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

# v1.36.0 (item #11) — replace the hardcoded "${test_sh_count} bash +
# ${test_py_count} python test scripts" enumeration with a
# grep-from-source pattern. The previous regex required the literal
# count, which created the same drift surface CONTRIBUTING.md already
# avoided. The new pattern validates the grep guidance is documented
# (the user runs the find/grep and gets the live count) — not the
# count itself, which now lives only on disk.
assert_doc_match "C4: CLAUDE test count uses grep-from-source pattern (v1.36.0 #11)" \
  "tests/.*find tests/.*test-\\*\\.sh.*wc -l.*find tests/.*test_\\*\\.py" \
  "${CLAUDE_MD}" \
  "CLAUDE.md should reference the find/grep pattern for live test counts (closes the hardcoded-count drift surface)"

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

  # In-flight release allowance: tools/release.sh promotes CHANGELOG (step 9)
  # before creating the tag (step 11) and re-runs CHANGELOG-coupled tests in
  # between. A single extra heading that matches the current VERSION file is
  # the expected transient state — accept it. Anything beyond that (or a
  # mismatch) still fails. The post-flight CI watch on the tagged commit
  # closes the loop after the tag exists.
  extra_count="$(printf '%s\n' "${extra_in_changelog}" | grep -c . || true)"
  if [[ -z "${extra_in_changelog}" ]]; then
    assert_pass "C5: changelog headings have matching semver tags"
  elif [[ "${extra_count}" -eq 1 && "${extra_in_changelog}" == "${version_tag}" ]]; then
    assert_pass "C5: changelog headings have matching semver tags (in-flight: ${version_tag} pending tag)"
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
# Contract 6 — Memory-file lockstep
# ----------------------------------------------------------------------
printf '\nContract 6: memory-file lockstep\n'

MEMORY_DIR="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory"
BUNDLE_CLAUDE_MD="${REPO_ROOT}/bundle/dot-claude/CLAUDE.md"
VERIFY_SH="${REPO_ROOT}/verify.sh"

if [[ ! -d "${MEMORY_DIR}" ]]; then
  assert_fail "C6: memory directory missing" \
    "${MEMORY_DIR} should exist; if you renamed it, update this contract and all @-include / required_paths sites"
else
  memory_count=0
  for memory_file in "${MEMORY_DIR}"/*.md; do
    [[ -e "${memory_file}" ]] || continue
    memory_count=$((memory_count + 1))
    name="$(basename "${memory_file}")"

    if grep -Fq "@~/.claude/quality-pack/memory/${name}" "${BUNDLE_CLAUDE_MD}"; then
      assert_pass "C6: ${name} @-included in bundle CLAUDE.md"
    else
      assert_fail "C6: ${name} missing @-include in bundle CLAUDE.md" \
        "add '@~/.claude/quality-pack/memory/${name}' to ${BUNDLE_CLAUDE_MD} or the memory file will never load on session start"
    fi

    if grep -Fq "/quality-pack/memory/${name}" "${VERIFY_SH}"; then
      assert_pass "C6: ${name} in verify.sh required_paths"
    else
      assert_fail "C6: ${name} missing from verify.sh required_paths" \
        "add \"\${CLAUDE_HOME}/quality-pack/memory/${name}\" to required_paths in ${VERIFY_SH} so post-install verification catches a broken install"
    fi
  done

# Empty-directory guard: zero iterations is indistinguishable from
  # all-pass without this assertion. If the memory dir ever ends up
  # empty (refactor moved files away, etc.) Contract 6 must fail loud.
  if [[ "${memory_count}" -eq 0 ]]; then
    assert_fail "C6: memory directory contains zero *.md files" \
      "${MEMORY_DIR} exists but has no *.md files — the @-include and required_paths surfaces are silently uncovered. If memory is being relocated, update Contract 6 to point at the new directory"
  fi
fi

# ----------------------------------------------------------------------
# Contract 7 — AGENTS tools-inventory lockstep
# ----------------------------------------------------------------------
printf '\nContract 7: AGENTS tools-inventory lockstep\n'

TOOLS_DIR="${REPO_ROOT}/tools"

documented_tools_inventory() {
  awk '
    /^  tools\// { in_tools = 1; next }
    in_tools && /^  docs\// { in_tools = 0; exit }
    in_tools && /^    [[:alnum:]_.-]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      print line
    }
  ' "${AGENTS_MD}" | LC_ALL=C sort -u
}

live_tools_inventory() {
  find "${TOOLS_DIR}" -mindepth 1 -maxdepth 2 -type f \
    | sed "s#^${TOOLS_DIR}/##" \
    | LC_ALL=C sort -u
}

if [[ ! -d "${TOOLS_DIR}" ]]; then
  assert_fail "C7: tools directory missing" \
    "${TOOLS_DIR} should exist; if you renamed or relocated it, update Contract 7 and the AGENTS.md architecture tree"
else
  documented_tools="$(documented_tools_inventory)"
  live_tools="$(live_tools_inventory)"
  documented_tool_count="$(printf '%s\n' "${documented_tools}" | grep -c . || true)"
  live_tool_count="$(printf '%s\n' "${live_tools}" | grep -c . || true)"
  printf '  documented: %d  live: %d\n' "${documented_tool_count}" "${live_tool_count}"

  if [[ "${documented_tool_count}" -eq 0 ]]; then
    assert_fail "C7: AGENTS.md tools inventory is empty" \
      "the architecture tree tools/ block should enumerate the live tools/ surface"
  fi

  if [[ "${live_tool_count}" -eq 0 ]]; then
    assert_fail "C7: tools directory contains zero files" \
      "${TOOLS_DIR} exists but has no files within depth <= 2 — update Contract 7 if the repo layout changed"
  fi

  missing_in_agents="$(comm -23 <(printf '%s\n' "${live_tools}") <(printf '%s\n' "${documented_tools}"))"
  extra_in_agents="$(comm -13 <(printf '%s\n' "${live_tools}") <(printf '%s\n' "${documented_tools}"))"

  if [[ -z "${missing_in_agents}" ]]; then
    assert_pass "C7: every live tools/ file is documented in AGENTS.md"
  else
    assert_fail "C7: AGENTS.md missing live tools/ entries" \
      "add these tools/ paths to the AGENTS.md architecture tree: $(printf '%s' "${missing_in_agents}" | paste -sd ', ' -)"
  fi

  if [[ -z "${extra_in_agents}" ]]; then
    assert_pass "C7: AGENTS.md tools inventory has no stale entries"
  else
    assert_fail "C7: AGENTS.md tools inventory has stale entries" \
      "remove these non-existent tools/ paths from the AGENTS.md architecture tree: $(printf '%s' "${extra_in_agents}" | paste -sd ', ' -)"
  fi
fi

# ----------------------------------------------------------------------
# Contract 8 — install/uninstall surface parity (test-automation-engineer P2)
#
# CLAUDE.md "Adding or removing a skill directory or agent file" requires
# verify.sh AND uninstall.sh to stay parallel with the live bundle, else
# uninstall silently leaks files or verify passes a broken install. No
# prior contract enforced membership: Contract 4 checks doc COUNTS, not
# the uninstall/verify LISTS. This contract closes that gap.
printf '\nContract 8: install/uninstall surface parity\n'

C8_AGENTS_DIR="${REPO_ROOT}/bundle/dot-claude/agents"
C8_SKILLS_DIR="${REPO_ROOT}/bundle/dot-claude/skills"
C8_UNINSTALL="${REPO_ROOT}/uninstall.sh"
C8_VERIFY="${REPO_ROOT}/verify.sh"

# SKILL_DIRS entries intentionally present in uninstall.sh with no matching
# bundle skill dir: the /ulw classifier aliases install.sh copies in.
C8_SKILL_ALIAS_ALLOWLIST="ultrawork sisyphus"

# (a) every bundle agent .md must appear in uninstall.sh AGENT_FILES.
c8_missing_agents=""
for _af in "${C8_AGENTS_DIR}"/*.md; do
  [[ -f "${_af}" ]] || continue
  _base="$(basename "${_af}")"
  grep -q "/agents/${_base}\"" "${C8_UNINSTALL}" || c8_missing_agents="${c8_missing_agents} ${_base}"
done
if [[ -z "${c8_missing_agents# }" ]]; then
  assert_pass "C8: every bundle agent is in uninstall.sh AGENT_FILES"
else
  assert_fail "C8: uninstall.sh AGENT_FILES missing bundle agents" \
    "add to uninstall.sh AGENT_FILES:${c8_missing_agents}"
fi

# (b) every bundle skill dir must appear in uninstall.sh SKILL_DIRS.
c8_missing_skills=""
for _sd in "${C8_SKILLS_DIR}"/*/; do
  [[ -d "${_sd}" ]] || continue
  _name="$(basename "${_sd}")"
  grep -q "/skills/${_name}\"" "${C8_UNINSTALL}" || c8_missing_skills="${c8_missing_skills} ${_name}"
done
if [[ -z "${c8_missing_skills# }" ]]; then
  assert_pass "C8: every bundle skill dir is in uninstall.sh SKILL_DIRS"
else
  assert_fail "C8: uninstall.sh SKILL_DIRS missing bundle skill dirs" \
    "add to uninstall.sh SKILL_DIRS:${c8_missing_skills}"
fi

# (c) every uninstall.sh SKILL_DIRS entry must be a real bundle skill dir
#     OR an allowlisted classifier alias — else it is a stale orphan.
c8_orphan_skills=""
while IFS= read -r _name; do
  [[ -n "${_name}" ]] || continue
  [[ -d "${C8_SKILLS_DIR}/${_name}" ]] && continue
  case " ${C8_SKILL_ALIAS_ALLOWLIST} " in
    *" ${_name} "*) continue ;;
  esac
  c8_orphan_skills="${c8_orphan_skills} ${_name}"
done < <(grep -oE '/skills/[a-z0-9-]+"' "${C8_UNINSTALL}" | sed -E 's#/skills/##; s#"##' | LC_ALL=C sort -u)
if [[ -z "${c8_orphan_skills# }" ]]; then
  assert_pass "C8: uninstall.sh SKILL_DIRS has no stale orphan entries"
else
  assert_fail "C8: uninstall.sh SKILL_DIRS references non-existent skill dirs" \
    "remove (or allowlist as an alias):${c8_orphan_skills}"
fi

# (d) verify.sh must do a bundle-vs-install agent completeness check, not
#     just spot-check a handful of sentinel agents in required_paths.
if grep -q 'C8: bundle agent completeness' "${C8_VERIFY}"; then
  assert_pass "C8: verify.sh performs a bundle-vs-install agent completeness check"
else
  assert_fail "C8: verify.sh has no agent-completeness check" \
    "verify.sh required_paths only spot-checks a few agents; add the C8 bundle-vs-install loop"
fi

# (e) verify.sh must ALSO do a bundle-vs-install SKILL completeness check
#     (mirror of 8d for skill dirs — a partial install missing a skill dir
#     would otherwise pass verify).
if grep -q 'C8: bundle skill completeness' "${C8_VERIFY}"; then
  assert_pass "C8: verify.sh performs a bundle-vs-install skill completeness check"
else
  assert_fail "C8: verify.sh has no skill-completeness check" \
    "verify.sh spot-checks only some skill dirs; add the C8 bundle-vs-install skill loop"
fi

# ----------------------------------------------------------------------
printf '\n=== coordination-rules tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
