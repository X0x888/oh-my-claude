#!/usr/bin/env bash
# Tests for the v1.20.0 /memory-audit skill (audit-memory.sh).
#
# Drives the script against a fixture memory directory and asserts:
#   - prints the resolved memory dir as line ~1
#   - classifies version-snapshot files as archival
#   - classifies recent feedback/user files as load-bearing
#   - classifies strikethrough-with-existing-file as superseded
#   - classifies missing-file references as drifted
#   - emits suggested mv commands for archival/superseded entries
#   - never modifies the input directory (read-only)
#   - handles absent memory dir, absent MEMORY.md, empty MEMORY.md
#   - rejects unknown args with exit 2
#   - --help exits 0 with usage text

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/audit-memory.sh"

if [[ ! -x "${AUDIT}" ]]; then
  printf 'audit-memory.sh not executable at %s\n' "${AUDIT}" >&2
  exit 1
fi

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s (unexpected needle present)\n    needle=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" -eq "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — expected exit %d, got %d\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# Build a fixture memory dir with all four classifications represented.
_make_fixture() {
  local d
  d="$(mktemp -d -t audit-fixture-XXXXXX)"

  # mtimes: BSD `date -v` and GNU `date -d` differ; one of the two must
  # match the host. Tests run on macOS (BSD) and Linux CI (GNU).
  local old_ts recent_ts
  old_ts="$(date -v-60d +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d '60 days ago' +%Y%m%d%H%M 2>/dev/null \
    || date +%Y%m%d%H%M)"
  recent_ts="$(date +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M)"

  # Archival pattern (filename match, mtime old):
  touch -t "${old_ts}" "${d}/project_v1_7_0_shipped.md"
  touch -t "${old_ts}" "${d}/project_v1_8_0_shipped.md"
  # Archival via stale-mtime (does not match version pattern):
  touch -t "${old_ts}" "${d}/project_old_decision.md"
  # Load-bearing (recent, not version pattern):
  touch -t "${recent_ts}" "${d}/feedback_active_rule.md"
  touch -t "${recent_ts}" "${d}/user_profile.md"
  # Superseded (strikethrough in MEMORY.md, file exists so it lands as superseded):
  touch -t "${recent_ts}" "${d}/project_old_thing.md"

  cat > "${d}/MEMORY.md" <<'EOF'
- [v1.7.0 shipped](project_v1_7_0_shipped.md) — initial release
- [v1.8.0 shipped](project_v1_8_0_shipped.md) — second release
- [Old decision](project_old_decision.md) — stale rationale
- [Active rule](feedback_active_rule.md) — current behavioral guidance
- [Developer profile](user_profile.md) — role and tooling
- ~~[Old thing](project_old_thing.md)~~ — closed in v1.10.0
- [Drifted reference](project_missing_file.md) — points at missing file
EOF

  printf '%s' "${d}"
}

# ----------------------------------------------------------------------
printf 'Test 1: prints resolved memory directory as the header\n'
fixture="$(_make_fixture)"
out="$(bash "${AUDIT}" --memory-dir "${fixture}" 2>&1)"
assert_contains "header names memory dir" "**Memory directory:** \`${fixture}\`" "${out}"
assert_contains "header is the audit title" "## Memory audit"                      "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: version-snapshot files classify as archival\n'
assert_contains "v1.7.0 archival"            "**archival** | \`project_v1_7_0_shipped.md\`" "${out}"
assert_contains "v1.8.0 archival"            "**archival** | \`project_v1_8_0_shipped.md\`" "${out}"
assert_contains "archival recommends rollup" "release_history.md" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: stale-mtime non-version files classify as archival\n'
assert_contains "old_decision archival" "**archival** | \`project_old_decision.md\`" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: recent feedback / user files classify as load-bearing\n'
assert_contains "active_rule load-bearing"  "**load-bearing** | \`feedback_active_rule.md\`" "${out}"
assert_contains "user_profile load-bearing" "**load-bearing** | \`user_profile.md\`"         "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: strikethrough entry with existing file classifies as superseded\n'
assert_contains "old_thing superseded" "**superseded** | \`project_old_thing.md\`" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: missing-file reference classifies as drifted\n'
assert_contains "missing_file drifted" "**drifted** | \`project_missing_file.md\`"  "${out}"
assert_contains "drifted action"       "does not exist"                              "${out}"

# ----------------------------------------------------------------------
printf 'Test 7: emits suggested mv commands for archival/superseded\n'
assert_contains "moves header"     "Suggested moves"                          "${out}"
assert_contains "mkdir _archive"   "mkdir -p ${fixture}/_archive"             "${out}"
assert_contains "v1.7.0 mv line"   "mv ${fixture}/project_v1_7_0_shipped.md"  "${out}"
assert_contains "old_thing mv line" "mv ${fixture}/project_old_thing.md"      "${out}"
assert_not_contains "no mv for load-bearing" "mv ${fixture}/user_profile.md"  "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: read-only — does not modify the fixture directory\n'
# Capture mtime of every file before and after; assert no change.
before="$(find "${fixture}" -type f -exec stat -f '%N %m' {} \; 2>/dev/null \
  || find "${fixture}" -type f -exec stat -c '%n %Y' {} \; 2>/dev/null \
  || true)"
bash "${AUDIT}" --memory-dir "${fixture}" >/dev/null 2>&1
after="$(find "${fixture}" -type f -exec stat -f '%N %m' {} \; 2>/dev/null \
  || find "${fixture}" -type f -exec stat -c '%n %Y' {} \; 2>/dev/null \
  || true)"
if [[ "${before}" == "${after}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: fixture mtimes changed after audit — script is not read-only\n' >&2
  fail=$((fail + 1))
fi
# Also assert no _archive dir was created.
if [[ ! -e "${fixture}/_archive" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: script created _archive dir — should be advisory only\n' >&2
  fail=$((fail + 1))
fi

rm -rf "${fixture}"

# ----------------------------------------------------------------------
printf 'Test 9: absent memory directory — clean exit with note\n'
absent_dir="$(mktemp -d -t audit-absent-XXXXXX)/does_not_exist"
# Wrap in set +e/set -e so the exit-code capture is real instead of
# tautological under the file-level set -e.
set +e
out="$(bash "${AUDIT}" --memory-dir "${absent_dir}")"
ec=$?
set -e
assert_contains "absent dir note"      "No memory directory exists" "${out}"
assert_contains "absent dir path shown" "${absent_dir}"              "${out}"
assert_exit_code "absent dir exit 0" 0 "${ec}"
rm -rf "${absent_dir%/*}"

# ----------------------------------------------------------------------
printf 'Test 10: absent MEMORY.md — lists files anyway\n'
no_index_dir="$(mktemp -d -t audit-noindex-XXXXXX)"
touch "${no_index_dir}/feedback_orphan.md"
touch "${no_index_dir}/project_solo.md"
out="$(bash "${AUDIT}" --memory-dir "${no_index_dir}")"
assert_contains "no-index note"     "No MEMORY.md found" "${out}"
assert_contains "lists orphan file" "feedback_orphan.md" "${out}"
assert_contains "lists solo file"   "project_solo.md"    "${out}"
rm -rf "${no_index_dir}"

# ----------------------------------------------------------------------
printf 'Test 11: empty MEMORY.md — clean output, zero entries\n'
empty_dir="$(mktemp -d -t audit-empty-XXXXXX)"
touch "${empty_dir}/MEMORY.md"
out="$(bash "${AUDIT}" --memory-dir "${empty_dir}")"
assert_contains "zero entries note"        "Indexed entries:** 0"  "${out}"
assert_contains "no-link-entries fallback" "no markdown link entries" "${out}"
rm -rf "${empty_dir}"

# ----------------------------------------------------------------------
printf 'Test 12: --help exits 0 with usage\n'
out="$(bash "${AUDIT}" --help 2>&1)"
ec=$?
assert_contains "help shows usage" "audit-memory.sh — classify MEMORY.md entries" "${out}"
assert_contains "help shows arg"   "--memory-dir"                                  "${out}"
assert_exit_code "help exit 0" 0 "${ec}"

# ----------------------------------------------------------------------
printf 'Test 13: unknown arg exits 2\n'
set +e
out="$(bash "${AUDIT}" --bogus 2>&1)"
ec=$?
set -e
assert_contains "unknown arg msg" "unknown argument" "${out}"
assert_exit_code "unknown arg exit 2" 2 "${ec}"

# ----------------------------------------------------------------------
printf 'Test 14: missing --memory-dir value exits 2\n'
set +e
out="$(bash "${AUDIT}" --memory-dir 2>&1)"
ec=$?
set -e
assert_contains "missing value msg" "requires a path" "${out}"
assert_exit_code "missing value exit 2" 2 "${ec}"

# ----------------------------------------------------------------------
printf 'Test 15: rollup hint fires when archival count >= 5\n'
big_dir="$(mktemp -d -t audit-rollup-XXXXXX)"
old_ts="$(date -v-60d +%Y%m%d%H%M.%S 2>/dev/null || date -d '60 days ago' +%Y%m%d%H%M 2>/dev/null)"
cat > "${big_dir}/MEMORY.md" <<'EOF'
- [v1.7.0 shipped](project_v1_7_0_shipped.md) — release
- [v1.8.0 shipped](project_v1_8_0_shipped.md) — release
- [v1.9.0 shipped](project_v1_9_0_shipped.md) — release
- [v1.10.0 shipped](project_v1_10_0_shipped.md) — release
- [v1.11.0 shipped](project_v1_11_0_shipped.md) — release
EOF
for v in 7 8 9 10 11; do
  touch -t "${old_ts}" "${big_dir}/project_v1_${v}_0_shipped.md"
done
out="$(bash "${AUDIT}" --memory-dir "${big_dir}")"
assert_contains "rollup hint header"      "Rollup recommendation" "${out}"
assert_contains "rollup hint count fires" "5 archival entries"    "${out}"
rm -rf "${big_dir}"

# ----------------------------------------------------------------------
printf 'Test 16: orphaned files post-pass detects unindexed file\n'
orph_dir="$(mktemp -d -t audit-orphan-XXXXXX)"
touch "${orph_dir}/project_indexed.md"
touch "${orph_dir}/project_orphaned.md"
cat > "${orph_dir}/MEMORY.md" <<'EOF'
- [Indexed entry](project_indexed.md) — referenced from index
EOF
out="$(bash "${AUDIT}" --memory-dir "${orph_dir}")"
assert_contains "orphan section header" "Orphaned files"         "${out}"
assert_contains "orphan file listed"    "project_orphaned.md"    "${out}"
assert_not_contains "indexed file not orphan" "\`project_indexed.md\` |" "$(printf '%s' "${out}" | sed -n '/^### Orphaned files/,$p')"
rm -rf "${orph_dir}"

# ----------------------------------------------------------------------
printf 'Test 17: paths with spaces are shell-quoted in suggested moves\n'
# Re-creates the F1 fix scenario from review: a memory dir whose path
# contains spaces. Without printf %q quoting, the suggested mv command
# would treat the space as an argument separator and fail or move the
# wrong file.
space_parent="$(mktemp -d -t 'audit space test XXXXXX')"
space_dir="${space_parent}/with spaces"
mkdir -p "${space_dir}"
old_ts="$(date -v-60d +%Y%m%d%H%M.%S 2>/dev/null || date -d '60 days ago' +%Y%m%d%H%M 2>/dev/null)"
touch -t "${old_ts}" "${space_dir}/project_v1_99_0_shipped.md"
cat > "${space_dir}/MEMORY.md" <<'EOF'
- [v1.99.0 shipped](project_v1_99_0_shipped.md) — release
EOF
out="$(bash "${AUDIT}" --memory-dir "${space_dir}")"
# printf %q quotes spaces with backslash-escapes (preferred form on bash).
# The exact output form is bash-version-dependent; assert that the move
# command does NOT contain the unquoted-space form which would break.
unquoted_form="mv ${space_dir}/project_v1_99_0_shipped.md ${space_dir}/_archive/project_v1_99_0_shipped.md"
assert_not_contains "no unquoted space in mv line" "${unquoted_form}" "${out}"
# Confirm the file is still referenced (i.e. line was generated, not just dropped).
assert_contains "shipped file in mv lines" "project_v1_99_0_shipped.md" "${out}"
rm -rf "${space_parent}"

# ----------------------------------------------------------------------
printf 'Test 18: version-marker requirement on closure heuristic\n'
# Description says "closed in" but lacks a v<digit> marker — must NOT
# auto-classify as superseded (was the F2 false-positive case).
herr_dir="$(mktemp -d -t audit-herr-XXXXXX)"
recent_ts="$(date +%Y%m%d%H%M.%S)"
touch -t "${recent_ts}" "${herr_dir}/feedback_meta_phrase.md"
cat > "${herr_dir}/MEMORY.md" <<'EOF'
- [Phrase usage notes](feedback_meta_phrase.md) — describes how to use the phrase "closed in" properly
EOF
out="$(bash "${AUDIT}" --memory-dir "${herr_dir}")"
assert_not_contains "no false-positive superseded" "**superseded**" "${out}"
assert_contains "still load-bearing" "**load-bearing** | \`feedback_meta_phrase.md\`" "${out}"
rm -rf "${herr_dir}"

# Inverse: a real closure marker WITH version → still classified as superseded.
real_dir="$(mktemp -d -t audit-real-XXXXXX)"
touch -t "${recent_ts}" "${real_dir}/project_thing.md"
cat > "${real_dir}/MEMORY.md" <<'EOF'
- [Old thing](project_thing.md) — closed in v1.10.0 cleanup
EOF
out="$(bash "${AUDIT}" --memory-dir "${real_dir}")"
assert_contains "version-marker triggers superseded" "**superseded** | \`project_thing.md\`" "${out}"
rm -rf "${real_dir}"

# ----------------------------------------------------------------------
printf 'Test 19: multi-link rows do not produce orphan false-positives\n'
# A row with two [Title](file.md) links should leave both files indexed
# (not flag the second as orphan).
multi_dir="$(mktemp -d -t audit-multi-XXXXXX)"
touch -t "${recent_ts}" "${multi_dir}/feedback_a.md"
touch -t "${recent_ts}" "${multi_dir}/feedback_b.md"
cat > "${multi_dir}/MEMORY.md" <<'EOF'
- [Rule A](feedback_a.md) and [Rule B](feedback_b.md) — both rules are load-bearing
EOF
out="$(bash "${AUDIT}" --memory-dir "${multi_dir}")"
# Orphans section either absent or does not list feedback_b.md.
orphan_section="$(printf '%s' "${out}" | sed -n '/^### Orphaned files/,$p')"
assert_not_contains "feedback_b not orphan" "feedback_b.md" "${orphan_section}"
rm -rf "${multi_dir}"

# ----------------------------------------------------------------------
if (( fail > 0 )); then
  printf '\n%d/%d failed\n' "${fail}" "$((pass + fail))" >&2
  exit 1
fi

printf '\nAll %d memory-audit assertions passed\n' "${pass}"
