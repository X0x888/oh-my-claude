#!/usr/bin/env bash
#
# test-archetype-memory.sh
#
# Verifies the wave-2 fix for "cross-session archetype memory":
#   - _omc_project_key normalizes git remotes (URL form, SCP form,
#     with/without auth, trailing .git) to the same 12-char key
#   - falls back to _omc_project_id when no git remote is available
#   - record-archetype.sh writes single-row + multi-row stdin to
#     ~/.claude/quality-pack/used-archetypes.jsonl with project_key
#   - exits 0 on missing SESSION_ID (hook-style guard)
#   - exits 2 on empty/invalid stdin
#   - recent_archetypes_for_project returns most-recent N unique
#     archetypes for the current project (dedup, newest-first)
#   - project_key filtering: rows from other projects do NOT bleed
#     into the current project's recent list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
RECORD_SCRIPT="${SCRIPTS_DIR}/record-archetype.sh"

pass=0
fail=0

TEST_HOME="$(mktemp -d)"
TEST_STATE_ROOT="${TEST_HOME}/state"
TEST_GIT_ROOT="${TEST_HOME}/repo"
mkdir -p "${TEST_STATE_ROOT}/archetype-test-session"
mkdir -p "${TEST_HOME}/.claude/quality-pack"
mkdir -p "${TEST_GIT_ROOT}"

# A real git repo with a known remote — used to exercise project_key.
(
  cd "${TEST_GIT_ROOT}"
  git init -q
  git config user.name "test"
  git config user.email "test@test.local"
  git remote add origin "https://github.com/example/oh-my-claude.git"
) >/dev/null 2>&1

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"
export SESSION_ID="archetype-test-session"

cleanup() {
  cd "${ORIG_PWD}"
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}"
}
trap cleanup EXIT

# Source common.sh AFTER setting HOME so any HOME-dependent paths
# resolve under the test fixture.
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=  %q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_ne() {
  local label="$1" forbidden="$2" actual="$3"
  if [[ "${actual}" != "${forbidden}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    forbidden=%q\n    actual=  %q\n' "${label}" "${forbidden}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %q\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected match: %q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_exit_code() {
  local label="$1" expected="$2"
  shift 2
  set +e
  "$@"
  local actual=$?
  set -e
  if [[ "${actual}" -eq "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected exit=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# _omc_project_key
# ---------------------------------------------------------------------------
echo "Testing _omc_project_key..."

# Inside the test git repo with a known remote.
cd "${TEST_GIT_ROOT}"
key_https="$(_omc_project_key)"
[[ -n "${key_https}" ]] && pass=$((pass + 1)) || { echo "  FAIL: HTTPS remote → empty key"; fail=$((fail + 1)); }
[[ "${#key_https}" -eq 12 ]] && pass=$((pass + 1)) || { echo "  FAIL: HTTPS key length != 12 (got ${#key_https})"; fail=$((fail + 1)); }

# Same repo, SCP-form remote should hash to the same key.
git remote set-url origin "git@github.com:example/oh-my-claude.git" 2>/dev/null
key_scp="$(_omc_project_key)"
assert_eq "SCP form == HTTPS form same key" "${key_https}" "${key_scp}"

# Same repo with credentials in URL.
git remote set-url origin "https://user:tok@github.com/example/oh-my-claude.git" 2>/dev/null
key_auth="$(_omc_project_key)"
assert_eq "credentials-in-URL → same key as bare HTTPS" "${key_https}" "${key_auth}"

# Same repo with trailing slash and uppercase variations.
git remote set-url origin "https://GitHub.com/Example/Oh-My-Claude.git/" 2>/dev/null
key_caps="$(_omc_project_key)"
assert_eq "caps + trailing slash → same key" "${key_https}" "${key_caps}"

# Different repo → different key.
git remote set-url origin "https://github.com/different/project.git" 2>/dev/null
key_other="$(_omc_project_key)"
assert_ne "different remote → different key" "${key_https}" "${key_other}"

# No git repo: cwd-hash fallback (matches _omc_project_id).
cd "${TEST_HOME}"
key_no_git="$(_omc_project_key)"
key_cwd="$(_omc_project_id)"
assert_eq "no git repo falls back to cwd hash" "${key_cwd}" "${key_no_git}"

# Regression: ssh:// URL with port must normalize to the same key as
# the SCP form for the same upstream. Quality-reviewer caught this —
# `ssh://git@github.com:2222/foo/bar` and `git@github.com:foo/bar`
# point at the same repo but the original normalization yielded
# different keys because the `:2222` was preserved as a literal.
cd "${TEST_GIT_ROOT}"
git remote set-url origin "ssh://git@github.com:2222/example/oh-my-claude.git" 2>/dev/null
key_ssh_port="$(_omc_project_key)"
git remote set-url origin "git@github.com:example/oh-my-claude.git" 2>/dev/null
key_scp_eq="$(_omc_project_key)"
assert_eq "ssh-port URL normalizes to same key as SCP form" "${key_ssh_port}" "${key_scp_eq}"

# HTTPS with explicit port should also normalize.
git remote set-url origin "https://github.com:443/example/oh-my-claude.git" 2>/dev/null
key_https_port="$(_omc_project_key)"
git remote set-url origin "https://github.com/example/oh-my-claude.git" 2>/dev/null
key_https_plain="$(_omc_project_key)"
assert_eq "https-port normalizes to same key as plain https" "${key_https_port}" "${key_https_plain}"

# GitLab subgroup paths must produce a stable 12-char key.
git remote set-url origin "https://gitlab.com/group/subgroup/repo.git" 2>/dev/null
key_subgroup="$(_omc_project_key)"
[[ -n "${key_subgroup}" && "${#key_subgroup}" -eq 12 ]] \
  && pass=$((pass + 1)) \
  || { echo "  FAIL: GitLab subgroup → not 12-char key"; fail=$((fail + 1)); }

# Two clones of the same gitlab subgroup repo at different cwds should
# yield the same key — the worktree-stable property the user asked for.
git remote set-url origin "https://gitlab.com/group/subgroup/repo.git" 2>/dev/null
key_subgroup_a="$(_omc_project_key)"
ALT_REPO="${TEST_HOME}/alt-clone"
mkdir -p "${ALT_REPO}"
(
  cd "${ALT_REPO}"
  git init -q
  git config user.name "test"
  git config user.email "test@test.local"
  git remote add origin "https://gitlab.com/group/subgroup/repo.git"
) >/dev/null 2>&1
cd "${ALT_REPO}"
key_subgroup_b="$(_omc_project_key)"
assert_eq "same upstream at different cwds → same key (worktree stable)" "${key_subgroup_a}" "${key_subgroup_b}"
cd "${TEST_GIT_ROOT}"

# Restore the canonical remote for the rest of the tests.
git remote set-url origin "https://github.com/example/oh-my-claude.git" 2>/dev/null

# ---------------------------------------------------------------------------
# record-archetype.sh: missing SESSION_ID exits 0 (hook-style guard)
# ---------------------------------------------------------------------------
echo "Testing record-archetype.sh hook-style guard..."

guard_out="$(SESSION_ID="" HOME="${TEST_HOME}" bash "${RECORD_SCRIPT}" </dev/null 2>&1)"
guard_code=$?
[[ "${guard_code}" -eq 0 ]] && pass=$((pass + 1)) || { echo "  FAIL: missing SESSION_ID should exit 0 (got ${guard_code})"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
# record-archetype.sh: empty/invalid stdin
# ---------------------------------------------------------------------------
echo "Testing record-archetype.sh input validation..."

# Empty stdin (no rows) → exit 2
set +e
HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" </dev/null >/dev/null 2>&1
empty_code=$?
set -e
[[ "${empty_code}" -eq 2 ]] && pass=$((pass + 1)) || { echo "  FAIL: empty stdin should exit 2 (got ${empty_code})"; fail=$((fail + 1)); }

# Invalid JSON → still exits 2 (no valid rows written)
set +e
HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" >/dev/null 2>&1 <<<'not-json garbage'
bad_code=$?
set -e
[[ "${bad_code}" -eq 2 ]] && pass=$((pass + 1)) || { echo "  FAIL: invalid JSON should exit 2 (got ${bad_code})"; fail=$((fail + 1)); }

# JSON object missing required `archetype` field → still exits 2
set +e
HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" >/dev/null 2>&1 <<<'{"platform":"web"}'
no_arch_code=$?
set -e
[[ "${no_arch_code}" -eq 2 ]] && pass=$((pass + 1)) || { echo "  FAIL: missing archetype should exit 2 (got ${no_arch_code})"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
# record-archetype.sh: single + multi-row writes
# ---------------------------------------------------------------------------
echo "Testing record-archetype.sh writes..."

cross_log="${TEST_HOME}/.claude/quality-pack/used-archetypes.jsonl"

# Single archetype write
HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" >/dev/null 2>&1 <<<'{"archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}'

[[ -f "${cross_log}" ]] && pass=$((pass + 1)) || { echo "  FAIL: cross-log not created"; fail=$((fail + 1)); }
single_lines="$(wc -l <"${cross_log}" | tr -d ' ')"
assert_eq "single write → 1 row" "1" "${single_lines}"

stripe_row="$(jq -r 'select(.archetype == "Stripe") | .archetype' "${cross_log}" 2>/dev/null)"
assert_eq "row archetype field" "Stripe" "${stripe_row}"
stripe_session="$(jq -r 'select(.archetype == "Stripe") | .session' "${cross_log}" 2>/dev/null)"
assert_eq "row session field" "${SESSION_ID}" "${stripe_session}"
stripe_pkey="$(jq -r 'select(.archetype == "Stripe") | .project_key' "${cross_log}" 2>/dev/null)"
[[ -n "${stripe_pkey}" && "${#stripe_pkey}" -eq 12 ]] && pass=$((pass + 1)) || { echo "  FAIL: project_key not 12-char hex"; fail=$((fail + 1)); }
stripe_platform="$(jq -r 'select(.archetype == "Stripe") | .platform' "${cross_log}" 2>/dev/null)"
assert_eq "row platform field" "web" "${stripe_platform}"
stripe_domain="$(jq -r 'select(.archetype == "Stripe") | .domain' "${cross_log}" 2>/dev/null)"
assert_eq "row domain field" "fintech" "${stripe_domain}"

# Multi-row stdin (one archetype per line)
multi_input='{"archetype":"Linear","platform":"web","domain":"devtool","agent":"frontend-developer"}
{"archetype":"Vercel","platform":"web","domain":"devtool","agent":"frontend-developer"}'

HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" >/dev/null 2>&1 <<<"${multi_input}"

multi_lines="$(wc -l <"${cross_log}" | tr -d ' ')"
assert_eq "multi write → 3 total rows" "3" "${multi_lines}"

# ---------------------------------------------------------------------------
# recent_archetypes_for_project
# ---------------------------------------------------------------------------
echo "Testing recent_archetypes_for_project..."

# Inside the test git repo (project_key = HTTPS form hash)
cd "${TEST_GIT_ROOT}"

# All three priors should be visible — Vercel newest, Stripe oldest.
recent_all="$(recent_archetypes_for_project 5)"
recent_lines="$(printf '%s\n' "${recent_all}" | grep -c .)"
assert_eq "3 priors visible" "3" "${recent_lines}"

first_recent="$(printf '%s\n' "${recent_all}" | head -1)"
assert_eq "newest first = Vercel" "Vercel" "${first_recent}"
last_recent="$(printf '%s\n' "${recent_all}" | tail -1)"
assert_eq "oldest last = Stripe" "Stripe" "${last_recent}"

# Cap at N=2
recent_cap="$(recent_archetypes_for_project 2)"
recent_cap_lines="$(printf '%s\n' "${recent_cap}" | grep -c .)"
assert_eq "cap at N=2" "2" "${recent_cap_lines}"

# Dedup: write Stripe again, then it should jump to newest and only
# appear once in the result.
HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" >/dev/null 2>&1 <<<'{"archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}'

recent_dedup="$(recent_archetypes_for_project 5)"
dedup_count="$(printf '%s\n' "${recent_dedup}" | grep -cw 'Stripe')"
assert_eq "Stripe deduped (still 1 row in output)" "1" "${dedup_count}"
new_first="$(printf '%s\n' "${recent_dedup}" | head -1)"
assert_eq "Stripe re-emission → newest" "Stripe" "${new_first}"

# Project filtering: write rows from a DIFFERENT project's git remote;
# they must not appear in the current project's recent list.
git remote set-url origin "https://github.com/other/different-project.git" 2>/dev/null
HOME="${TEST_HOME}" SESSION_ID="${SESSION_ID}" \
  bash "${RECORD_SCRIPT}" >/dev/null 2>&1 <<<'{"archetype":"Things 3","platform":"ios","domain":"creative","agent":"ios-ui-developer"}'

# Switch back to the original remote and check the recent list.
git remote set-url origin "https://github.com/example/oh-my-claude.git" 2>/dev/null
recent_filtered="$(recent_archetypes_for_project 10)"
assert_not_contains "other-project archetype filtered out" "Things 3" "${recent_filtered}"
assert_contains "current-project archetype still present" "Stripe" "${recent_filtered}"

# Empty for a project with no priors yet.
git remote set-url origin "https://github.com/empty/nothing-yet.git" 2>/dev/null
empty_recent="$(recent_archetypes_for_project 5)"
assert_eq "no priors → empty output" "" "${empty_recent}"

# Restore canonical remote.
git remote set-url origin "https://github.com/example/oh-my-claude.git" 2>/dev/null

# ---------------------------------------------------------------------------
# Missing log file: recent_archetypes_for_project returns empty
# ---------------------------------------------------------------------------
echo "Testing missing-log behavior..."

rm -f "${cross_log}"
no_log_recent="$(recent_archetypes_for_project 5)"
assert_eq "missing log → empty output" "" "${no_log_recent}"

# ---------------------------------------------------------------------------
echo
echo "PASS: ${pass}"
echo "FAIL: ${fail}"
[[ "${fail}" -eq 0 ]]
