#!/usr/bin/env bash
# test-repo-lessons.sh — regression net for the opt-in `repo_lessons`
# conf flag + record-repo-lesson.sh helper (v1.48-pre).
#
# repo_lessons is oh-my-claude's one deliberate memory surface that
# writes INTO the target repo (.claude/lessons.md / .claude/backlog.md
# at the repo root) instead of under ~/.claude — team-shareable,
# git-committable, capped at 7 bullets per file, newest first. Because
# the write lands inside a directory the user may commit and push, the
# flag is off by default and deny-listed at project-conf scope (mirrors
# pretool_intent_guard / bg_spawn_gate / agent_first_gate /
# no_defer_mode / quality_policy — see common.sh `_parse_conf_file`'s
# `level == "project"` branch).
#
# Covers:
#   1. flag off (default), inside a git repo    -> no-op
#   2. flag on (env), inside a git repo          -> lessons.md +
#      backlog.md created with the bullet
#   3. cap enforcement                            -> 9 adds retain only
#      the newest 7, oldest dropped, newest-first order preserved
#   4. flag on (env), NON-git cwd                 -> no-op
#   5. project-conf repo_lessons=on               -> ignored
#      (deny-list); user-level conf repo_lessons=on -> works
#      (positive control)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-repo-lesson.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected match: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Track every temp HOME created below so the EXIT trap can clean up
# even if an assertion aborts the script early (set -e).
declare -a _cleanup_dirs=()
_cleanup() {
  local d
  for d in ${_cleanup_dirs[@]+"${_cleanup_dirs[@]}"}; do
    rm -rf "${d}"
  done
}
trap _cleanup EXIT

# Creates <home>/.claude (user-conf slot) and <home>/repo (a git work
# tree one level under home) so the load_conf project walk-up in
# common.sh never escapes into the real ~/.claude/oh-my-claude.conf —
# mirrors test-stop-guard-bypass-surface.sh F-013's setup shape.
new_git_repo() {
  local home="$1"
  mkdir -p "${home}/.claude" "${home}/repo/.claude"
  (cd "${home}/repo" && git init -q && git config user.email t@t.com && git config user.name t) >/dev/null 2>&1
}

# ---------------------------------------------------------------------
printf 'Test 1: flag off (default), inside a git repo -> no-op\n'
_h1="$(mktemp -d)"; _cleanup_dirs+=("${_h1}")
new_git_repo "${_h1}"
if (cd "${_h1}/repo" && env -u OMC_REPO_LESSONS HOME="${_h1}" SESSION_ID="t1" \
      bash "${HELPER}" add lesson "should not be written" >/dev/null 2>&1); then
  pass=$((pass + 1))
else
  printf '  FAIL: T1: helper must exit 0 even as a no-op\n' >&2
  fail=$((fail + 1))
fi
if [[ -f "${_h1}/repo/.claude/lessons.md" ]]; then
  printf '  FAIL: T1: lessons.md must not be created when repo_lessons is off (default)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 2: flag on (env), inside a git repo -> lessons.md + backlog.md created\n'
_h2="$(mktemp -d)"; _cleanup_dirs+=("${_h2}")
new_git_repo "${_h2}"
(cd "${_h2}/repo" && env HOME="${_h2}" SESSION_ID="t2" OMC_REPO_LESSONS=on \
    bash "${HELPER}" add lesson "first lesson" >/dev/null 2>&1)
(cd "${_h2}/repo" && env HOME="${_h2}" SESSION_ID="t2" OMC_REPO_LESSONS=on \
    bash "${HELPER}" add backlog "first backlog item" >/dev/null 2>&1)

_lessons_body="$(cat "${_h2}/repo/.claude/lessons.md" 2>/dev/null || true)"
_backlog_body="$(cat "${_h2}/repo/.claude/backlog.md" 2>/dev/null || true)"
assert_contains "T2: lessons.md has the bullet" "- first lesson" "${_lessons_body}"
assert_contains "T2: lessons.md has a header title line" "# Lessons" "${_lessons_body}"
assert_contains "T2: backlog.md has the bullet" "- first backlog item" "${_backlog_body}"
assert_contains "T2: backlog.md has a header title line" "# Backlog" "${_backlog_body}"

# ---------------------------------------------------------------------
printf 'Test 3: cap enforcement -> 9 adds retain only the newest 7\n'
_h3="$(mktemp -d)"; _cleanup_dirs+=("${_h3}")
new_git_repo "${_h3}"
for i in 1 2 3 4 5 6 7 8 9; do
  (cd "${_h3}/repo" && env HOME="${_h3}" SESSION_ID="t3" OMC_REPO_LESSONS=on \
      bash "${HELPER}" add lesson "lesson ${i}" >/dev/null 2>&1)
done
_cap_target="${_h3}/repo/.claude/lessons.md"
_cap_body="$(cat "${_cap_target}")"
_bullet_count="$(grep -c '^- ' "${_cap_target}")"
assert_eq "T3: exactly 7 bullets retained" "7" "${_bullet_count}"
assert_contains "T3: newest bullet (9) present" "- lesson 9" "${_cap_body}"
assert_contains "T3: 7th-newest bullet (3) present" "- lesson 3" "${_cap_body}"
assert_not_contains "T3: oldest bullet (1) dropped" "- lesson 1" "${_cap_body}"
assert_not_contains "T3: 2nd-oldest bullet (2) dropped" "- lesson 2" "${_cap_body}"
# Newest-first ordering: "- lesson 9" must appear earlier in the file
# than "- lesson 3". ${var%%pattern} strips the longest matching
# suffix, i.e. everything from the pattern's first occurrence onward —
# comparing the stripped lengths tells us which literal appears first.
_pos9="${_cap_body%%- lesson 9*}"
_pos3="${_cap_body%%- lesson 3*}"
if [[ "${#_pos9}" -lt "${#_pos3}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: newest-first ordering — "lesson 9" must precede "lesson 3"\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 4: flag on (env), non-git cwd -> no-op\n'
_h4="$(mktemp -d)"; _cleanup_dirs+=("${_h4}")
mkdir -p "${_h4}/.claude" "${_h4}/scratch"
if (cd "${_h4}/scratch" && env HOME="${_h4}" SESSION_ID="t4" OMC_REPO_LESSONS=on \
      bash "${HELPER}" add lesson "should not be written" >/dev/null 2>&1); then
  pass=$((pass + 1))
else
  printf '  FAIL: T4: helper must exit 0 even as a no-op\n' >&2
  fail=$((fail + 1))
fi
if [[ -f "${_h4}/scratch/.claude/lessons.md" ]]; then
  printf '  FAIL: T4: lessons.md must not be created outside a git work tree\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 5a: project-conf repo_lessons=on is ignored (deny-list)\n'
_h5="$(mktemp -d)"; _cleanup_dirs+=("${_h5}")
new_git_repo "${_h5}"
printf 'repo_lessons=on\n' > "${_h5}/repo/.claude/oh-my-claude.conf"
(cd "${_h5}/repo" && env -u OMC_REPO_LESSONS HOME="${_h5}" SESSION_ID="t5a" \
    bash "${HELPER}" add lesson "should NOT be written (project conf)" >/dev/null 2>&1)
if [[ -f "${_h5}/repo/.claude/lessons.md" ]]; then
  printf '  FAIL: T5a: project-conf repo_lessons=on must NOT enable the write (deny-list bypass)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf 'Test 5b: user-level conf repo_lessons=on works (positive control)\n'
rm -f "${_h5}/repo/.claude/oh-my-claude.conf"
printf 'repo_lessons=on\n' > "${_h5}/.claude/oh-my-claude.conf"
(cd "${_h5}/repo" && env -u OMC_REPO_LESSONS HOME="${_h5}" SESSION_ID="t5b" \
    bash "${HELPER}" add lesson "should be written (user conf)" >/dev/null 2>&1)
_h5_body="$(cat "${_h5}/repo/.claude/lessons.md" 2>/dev/null || true)"
assert_contains "T5b: user-level conf repo_lessons=on enables the write" \
  "- should be written (user conf)" "${_h5_body}"

# ---------------------------------------------------------------------
printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
