#!/usr/bin/env bash
# Focused tests for install-remote.sh — the curl-pipe-bash bootstrapper.
#
# Avoids hitting the network: stands up a local bare-git "remote" and a
# minimal install.sh stub inside the source tree, then exercises clone,
# update, prereq-check, and pass-through-args paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAPPER="${REPO_ROOT}/install-remote.sh"

pass=0
fail=0

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
TEST_HOME="${WORK_DIR}/home"
mkdir -p "${TEST_HOME}"

# --- Build a local bare repo to use as OMC_REPO_URL --------------------
SOURCE_REPO="${WORK_DIR}/source"
BARE_REPO="${WORK_DIR}/oh-my-claude.git"
mkdir -p "${SOURCE_REPO}"
(
  cd "${SOURCE_REPO}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name "test"
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
# Test stub: prints args and exits 0
printf 'STUB-INSTALL-RAN args=[%s]\n' "$*"
exit 0
STUB
  cat > verify.sh <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
verify_count_file="${OMC_TEST_VERIFY_COUNT_FILE:-}"
verify_rc="${OMC_TEST_VERIFY_RC:-0}"
verify_invocation=1

if [[ -n "${verify_count_file}" ]]; then
  verify_invocation="$(cat "${verify_count_file}" 2>/dev/null || echo 0)"
  verify_invocation=$((verify_invocation + 1))
  printf '%s\n' "${verify_invocation}" > "${verify_count_file}"
fi

if [[ "${OMC_TEST_VERIFY_FAIL_ONCE:-}" == "1" ]] && [[ "${verify_invocation}" -eq 1 ]]; then
  verify_rc=1
fi

printf 'STUB-VERIFY-RAN rc=[%s]\n' "${verify_rc}"
printf '=== Verification complete ===\n'
if [[ "${verify_rc}" -eq 0 ]]; then
  printf '  Errors:        0\n'
else
  printf '  Errors:        1\n'
fi
exit "${verify_rc}"
STUB
  mkdir -p tools
  cat > tools/install-state-report.sh <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

state_count_file="${OMC_TEST_INSTALL_STATE_COUNT_FILE:-}"
state_invocation=1

if [[ -n "${state_count_file}" ]]; then
  state_invocation="$(cat "${state_count_file}" 2>/dev/null || echo 0)"
  state_invocation=$((state_invocation + 1))
  printf '%s\n' "${state_invocation}" > "${state_count_file}"
fi

if [[ "${1:-}" == "--json" ]]; then
  if [[ "${state_invocation}" -eq 1 ]] && [[ -n "${OMC_TEST_INSTALL_STATE_JSON_PRE:-}" ]]; then
    printf '%s\n' "${OMC_TEST_INSTALL_STATE_JSON_PRE}"
  elif [[ "${state_invocation}" -gt 1 ]] && [[ -n "${OMC_TEST_INSTALL_STATE_JSON_POST:-}" ]]; then
    printf '%s\n' "${OMC_TEST_INSTALL_STATE_JSON_POST}"
  elif [[ -n "${OMC_TEST_INSTALL_STATE_JSON:-}" ]]; then
    printf '%s\n' "${OMC_TEST_INSTALL_STATE_JSON}"
  else
    printf '%s\n' '{"install_status":"not-installed","currentness":"not-applicable"}'
  fi
  exit 0
fi

if [[ "${1:-}" == "--last-update-summary" ]]; then
  printf '%s' "${OMC_TEST_INSTALL_STATE_SUMMARY:-}"
  exit 0
fi

if [[ "${1:-}" == "--already-current-summary" ]]; then
  printf '%s' "${OMC_TEST_INSTALL_STATE_CURRENTNESS_SUMMARY:-}"
  exit 0
fi

printf 'stub install-state-report\n'
STUB
  chmod +x install.sh
  chmod +x verify.sh
  chmod +x tools/install-state-report.sh
  git add install.sh verify.sh tools/install-state-report.sh
  git commit --quiet -m "init"
  # Ensure branch name is 'main' — git init may default to 'master' on older versions
  git branch -m main 2>/dev/null || true
)
git clone --quiet --bare "${SOURCE_REPO}" "${BARE_REPO}"

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
    printf '  FAIL: %s — needle %q not in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
printf 'Test 1: bootstrapper exists and is executable\n'
[[ -x "${BOOTSTRAPPER}" ]] && pass=$((pass + 1)) || { printf '  FAIL: %s not executable\n' "${BOOTSTRAPPER}" >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
printf 'Test 2: bash -n parses cleanly\n'
if bash -n "${BOOTSTRAPPER}"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

# ----------------------------------------------------------------------
printf 'Test 3: missing prereq exits non-zero with actionable message\n'
# Provide a PATH that omits git so need_cmd fires.
SAFE_PATH="$(mktemp -d)"
ln -s "$(command -v bash)" "${SAFE_PATH}/bash"
ln -s "$(command -v jq)"   "${SAFE_PATH}/jq"
ln -s "$(command -v rsync)" "${SAFE_PATH}/rsync"
# git intentionally missing
set +e
out="$(env -i HOME="${TEST_HOME}" PATH="${SAFE_PATH}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: missing-git should exit non-zero (got %s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "missing-prereq message names git" "git" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: fresh clone runs install.sh and passes args\n'
CLONE_DIR="${WORK_DIR}/clone1"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" --no-ios --model-tier=balanced 2>&1)"
[[ -d "${CLONE_DIR}/.git" ]] && pass=$((pass + 1)) || { printf '  FAIL: clone dir not created\n' >&2; fail=$((fail + 1)); }
assert_contains "stub install ran" "STUB-INSTALL-RAN" "${out}"
assert_contains "stub verify ran" "STUB-VERIFY-RAN" "${out}"
assert_contains "pass-through args reach stub" "args=[--no-ios --model-tier=balanced]" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: re-run on existing clone updates without re-cloning\n'
initial_sha="$(git -C "${CLONE_DIR}" rev-parse HEAD)"
(
  cd "${SOURCE_REPO}"
  printf 'updated installer docs\n' > NOTES.md
  git add NOTES.md
  git commit --quiet -m "ship update summary test fixture"
  git push --quiet "${BARE_REPO}" main
)
updated_sha="$(git -C "${SOURCE_REPO}" rev-parse HEAD)"
state_count_file="${WORK_DIR}/install-state-update.count"
rm -f "${state_count_file}"
pre_update_json="$(jq -cn \
  --arg repo_path "${CLONE_DIR}" \
  --arg installed_version "1.2.3" \
  --arg installed_sha "${initial_sha}" \
  '{install_status:"installed",currentness:"update-available",installed_version:$installed_version,installed_sha:$installed_sha,repo_path:$repo_path}')"
post_update_json="$(jq -cn \
  --arg repo_path "${CLONE_DIR}" \
  --arg installed_version "1.2.4" \
  --arg installed_sha "${updated_sha}" \
  --arg previous_sha "${initial_sha}" \
  --arg last_install_at "2026-05-25 13:00:00 +0000" \
  '{install_status:"installed",currentness:"already-current",installed_version:$installed_version,installed_sha:$installed_sha,repo_path:$repo_path,last_install_at:$last_install_at,last_install:{kind:"update",restart_required:true,managed_changes_total:5,settings_changed:false,reason:"5 managed installed path(s) changed.",previous:{installed_version:"1.2.3",installed_sha:$previous_sha},current:{installed_version:$installed_version,installed_sha:$installed_sha},change_summary:{available:true,reason:"Computed from previous_install.installed_sha..HEAD.",commit_count:1,truncated_count:0,commits:[{sha:$installed_sha,subject:"ship update summary test fixture"}]}}}')"
post_update_summary="$(cat <<EOF
  Update summary:
    Previous install: v1.2.3 @ ${initial_sha:0:12}
    Current install:  v1.2.4 @ ${updated_sha:0:12}
    Restart needed:  yes
    Reason:          5 managed installed path(s) changed.
    Commits since prior install (1):
      ${updated_sha:0:12} ship update summary test fixture
EOF
)"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  OMC_TEST_INSTALL_STATE_COUNT_FILE="${state_count_file}" \
  OMC_TEST_INSTALL_STATE_JSON_PRE="${pre_update_json}" \
  OMC_TEST_INSTALL_STATE_JSON_POST="${post_update_json}" \
  OMC_TEST_INSTALL_STATE_SUMMARY="${post_update_summary}" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "update path taken" "updating existing clone" "${out}"
assert_contains "stub install ran on update" "STUB-INSTALL-RAN" "${out}"
assert_contains "stub verify ran on update" "STUB-VERIFY-RAN rc=[0]" "${out}"
assert_contains "update summary header emitted" "Update summary:" "${out}"
assert_contains "update summary shows previous install ref" "Previous install: v1.2.3 @ ${initial_sha:0:12}" "${out}"
assert_contains "update summary shows current install ref" "Current install:  v1.2.4 @ ${updated_sha:0:12}" "${out}"
assert_contains "update summary shows restart decision" "Restart needed:  yes" "${out}"
assert_contains "update summary lists new commit" "ship update summary test fixture" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5b: already-current canonical install verifies and skips reinstall\n'
already_current_json="$(jq -cn \
  --arg repo_path "${CLONE_DIR}" \
  --arg installed_version "1.2.3" \
  --arg last_install_at "2026-05-25 12:00:00 +0000" \
  '{install_status:"installed",currentness:"already-current",installed_version:$installed_version,repo_path:$repo_path,last_install_at:$last_install_at}')"
already_current_summary="Already current: v1.2.3 (last install: 2026-05-25 12:00:00 +0000)"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  OMC_TEST_INSTALL_STATE_JSON="${already_current_json}" \
  OMC_TEST_INSTALL_STATE_CURRENTNESS_SUMMARY="${already_current_summary}" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "already-current path reports currentness" "Already current: v1.2.3" "${out}"
assert_contains "already-current path still verifies" "STUB-VERIFY-RAN rc=[0]" "${out}"
if [[ "${out}" == *"STUB-INSTALL-RAN"* ]]; then
  printf '  FAIL: already-current path should skip install.sh\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 5c: OMC_FORCE_REINSTALL bypasses already-current fast path\n'
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  OMC_TEST_INSTALL_STATE_JSON="${already_current_json}" \
  OMC_FORCE_REINSTALL=1 \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "force reinstall still runs installer" "STUB-INSTALL-RAN" "${out}"
assert_contains "force reinstall still verifies" "STUB-VERIFY-RAN rc=[0]" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5d: already-current verify failure falls through to repair install\n'
VERIFY_COUNT_FILE="${WORK_DIR}/verify-fail-once.count"
rm -f "${VERIFY_COUNT_FILE}"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  OMC_TEST_INSTALL_STATE_JSON="${already_current_json}" \
  OMC_TEST_VERIFY_FAIL_ONCE=1 \
  OMC_TEST_VERIFY_COUNT_FILE="${VERIFY_COUNT_FILE}" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "repair note is surfaced" "Continuing into install.sh to repair the on-disk harness" "${out}"
assert_contains "repair path still runs installer" "STUB-INSTALL-RAN" "${out}"
assert_eq "repair path runs verify twice" "2" \
  "$(printf '%s' "${out}" | grep -c 'STUB-VERIFY-RAN rc=')"

# ----------------------------------------------------------------------
printf 'Test 6: clone with local changes does not reset (preserves user state)\n'
echo "user-edit" >> "${CLONE_DIR}/install.sh"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "skips reset on dirty tree" "skipping reset" "${out}"
# User edit should still be present
grep -q "user-edit" "${CLONE_DIR}/install.sh" && pass=$((pass + 1)) || { printf '  FAIL: user-edit was clobbered\n' >&2; fail=$((fail + 1)); }

# Restore clean tree for subsequent tests
git -C "${CLONE_DIR}" checkout -- install.sh

# ----------------------------------------------------------------------
printf 'Test 6b: existing clone from a different remote is rejected before install.sh runs\n'
FOREIGN_SRC="${WORK_DIR}/foreign-source"
FOREIGN_BARE="${WORK_DIR}/foreign.git"
FOREIGN_CLONE="${WORK_DIR}/foreign-clone"
mkdir -p "${FOREIGN_SRC}"
(
  cd "${FOREIGN_SRC}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name "test"
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'FOREIGN-INSTALL-RAN args=[%s]\n' "$*"
exit 0
STUB
  chmod +x install.sh
  git add install.sh
  git commit --quiet -m "init"
  git branch -m main 2>/dev/null || true
)
git clone --quiet --bare "${FOREIGN_SRC}" "${FOREIGN_BARE}"
git clone --quiet "${FOREIGN_BARE}" "${FOREIGN_CLONE}"
set +e
out="$(OMC_SRC_DIR="${FOREIGN_CLONE}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: foreign existing clone should exit non-zero (rc=%s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "foreign remote mismatch is named" "points at ${FOREIGN_BARE}, expected ${BARE_REPO}" "${out}"
if [[ "${out}" == *"FOREIGN-INSTALL-RAN"* ]]; then
  printf '  FAIL: foreign install.sh should not run on remote mismatch\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 6c: pre-existing non-git clone path is rejected loudly\n'
NONGIT_TARGET="${WORK_DIR}/not-a-repo"
mkdir -p "${NONGIT_TARGET}"
printf 'placeholder\n' > "${NONGIT_TARGET}/README.md"
set +e
out="$(OMC_SRC_DIR="${NONGIT_TARGET}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: non-git clone path should exit non-zero (rc=%s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "non-git clone path message is actionable" "exists but is not a git repo" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6d: equivalent remotes with trailing-slash spelling are accepted\n'
SLASH_CLONE="${WORK_DIR}/slash-clone"
git clone --quiet "${BARE_REPO}" "${SLASH_CLONE}"
out="$(OMC_SRC_DIR="${SLASH_CLONE}" OMC_REPO_URL="${BARE_REPO}/" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "trailing-slash remote still updates in place" "updating existing clone" "${out}"
assert_contains "trailing-slash remote still runs installer" "STUB-INSTALL-RAN" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6e: existing git worktree checkout is accepted\n'
WORKTREE_CLONE="${WORK_DIR}/worktree-clone"
git -C "${CLONE_DIR}" worktree add --quiet -b bootstrapper-worktree "${WORKTREE_CLONE}" origin/main
out="$(OMC_SRC_DIR="${WORKTREE_CLONE}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "worktree path is treated as existing checkout" "updating existing clone" "${out}"
assert_contains "worktree path still runs installer" "STUB-INSTALL-RAN" "${out}"

# ----------------------------------------------------------------------
printf 'Test 7a: parallel-run guard rejects when lock dir already exists\n'
LOCK_TARGET="${WORK_DIR}/locked-clone"
LOCK_OWNED="${LOCK_TARGET}.bootstrap.lock"
mkdir -p "$(dirname "${LOCK_OWNED}")"
mkdir "${LOCK_OWNED}"
set +e
out="$(OMC_SRC_DIR="${LOCK_TARGET}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: locked dir should block (rc=%s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "lock-blocked message names lockdir" "bootstrap.lock" "${out}"
rmdir "${LOCK_OWNED}"

# ----------------------------------------------------------------------
printf 'Test 7b: lock dir is released after a successful run\n'
LOCK_TARGET2="${WORK_DIR}/lock-release-clone"
out="$(OMC_SRC_DIR="${LOCK_TARGET2}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
[[ ! -d "${LOCK_TARGET2}.bootstrap.lock" ]] && pass=$((pass + 1)) || { printf '  FAIL: lock dir leaked after success\n' >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
printf 'Test 7c: custom OMC_REPO_URL prints a loud warning\n'
WARN_TARGET="${WORK_DIR}/warn-clone"
out="$(OMC_SRC_DIR="${WARN_TARGET}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "warning fires for custom URL" "OMC_REPO_URL is OVERRIDDEN" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: missing install.sh in cloned repo exits non-zero\n'
EMPTY_REPO_SRC="${WORK_DIR}/empty-source"
EMPTY_BARE="${WORK_DIR}/empty.git"
mkdir -p "${EMPTY_REPO_SRC}"
(
  cd "${EMPTY_REPO_SRC}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email t@t
  git config user.name t
  echo "no installer here" > README.md
  git add README.md
  git commit --quiet -m "init"
  git branch -m main 2>/dev/null || true
)
git clone --quiet --bare "${EMPTY_REPO_SRC}" "${EMPTY_BARE}"
EMPTY_CLONE="${WORK_DIR}/empty-clone"
set +e
out="$(OMC_SRC_DIR="${EMPTY_CLONE}" OMC_REPO_URL="${EMPTY_BARE}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: missing-installer should exit non-zero (got %s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "missing-installer message" "install.sh not found" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8b: missing verify.sh in cloned repo exits non-zero\n'
NOVFY_SRC="${WORK_DIR}/novfy-source"
NOVFY_BARE="${WORK_DIR}/novfy.git"
mkdir -p "${NOVFY_SRC}"
(
  cd "${NOVFY_SRC}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email t@t
  git config user.name t
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'NOVFY-INSTALL-RAN\n'
exit 0
STUB
  chmod +x install.sh
  git add install.sh
  git commit --quiet -m "init"
  git branch -m main 2>/dev/null || true
)
git clone --quiet --bare "${NOVFY_SRC}" "${NOVFY_BARE}"
NOVFY_CLONE="${WORK_DIR}/novfy-clone"
set +e
out="$(OMC_SRC_DIR="${NOVFY_CLONE}" OMC_REPO_URL="${NOVFY_BARE}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: missing-verifier should exit non-zero (got %s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "missing-verifier message" "verify.sh not found" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8c: failing verify.sh aborts bootstrapper after install\n'
BADVFY_SRC="${WORK_DIR}/badvfy-source"
BADVFY_BARE="${WORK_DIR}/badvfy.git"
mkdir -p "${BADVFY_SRC}"
(
  cd "${BADVFY_SRC}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email t@t
  git config user.name t
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'BADVFY-INSTALL-RAN\n'
exit 0
STUB
  cat > verify.sh <<'STUB'
#!/usr/bin/env bash
printf 'BADVFY-VERIFY-RAN\n'
printf '=== Verification complete ===\n'
printf '  Errors:        1\n'
exit 1
STUB
  chmod +x install.sh verify.sh
  git add install.sh verify.sh
  git commit --quiet -m "init"
  git branch -m main 2>/dev/null || true
)
git clone --quiet --bare "${BADVFY_SRC}" "${BADVFY_BARE}"
BADVFY_CLONE="${WORK_DIR}/badvfy-clone"
set +e
out="$(OMC_SRC_DIR="${BADVFY_CLONE}" OMC_REPO_URL="${BADVFY_BARE}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: failing-verifier should exit non-zero (got %s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "failing-verifier still ran install" "BADVFY-INSTALL-RAN" "${out}"
assert_contains "failing-verifier ran verify" "BADVFY-VERIFY-RAN" "${out}"
assert_contains "failing-verifier emits bootstrapper summary" "post-install verification failed" "${out}"

# ----------------------------------------------------------------------
# T9-Z001 (v1.34.1+, security-lens Z-001): when OMC_REPO_URL is overridden
# from default, the latest-tag pin tip must point at OMC_DEFAULT_REPO_URL,
# NEVER at the (potentially attacker-controlled) override URL. Pre-fix
# the helpful "tip: OMC_REF=v9.9.9 bash install-remote.sh" line told the
# user to pin to whatever tag the override URL had at the top — i.e.,
# attacker-chosen.
printf 'T9-Z001: tag-pin tip never recommends overridden URL forks\n'

# Build a "hostile fork" bare repo with a high-semver tag that the
# canonical default does NOT have.
HOSTILE_SRC="${WORK_DIR}/hostile-source"
HOSTILE_BARE="${WORK_DIR}/hostile.git"
mkdir -p "${HOSTILE_SRC}"
(
  cd "${HOSTILE_SRC}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email a@a
  git config user.name a
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'HOSTILE-FORK-RAN args=[%s]\n' "$*"
exit 0
STUB
  chmod +x install.sh
  git add install.sh
  git commit --quiet -m "init"
  git branch -m main 2>/dev/null || true
  # The attacker plants a v9.9.99 tag — would have been the "tip" target
  # under the pre-fix probe-against-OMC_REPO_URL code.
  git tag v9.9.99
)
git clone --quiet --bare "${HOSTILE_SRC}" "${HOSTILE_BARE}"

set +e
HOSTILE_CLONE="${WORK_DIR}/hostile-clone"
out="$(OMC_SRC_DIR="${HOSTILE_CLONE}" \
       OMC_REPO_URL="${HOSTILE_BARE}" \
       OMC_REF="main" \
       HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
set -e
# v9.9.99 is the attacker tag. It MUST NOT appear in the recommended
# pin command (the tip should reference upstream's tag list, never the
# override URL's). Both the warning AND the absence of the attacker tag
# inside any "tip:" line are required.
assert_contains "T9-Z001: warning fires for hostile URL" \
  "OMC_REPO_URL is OVERRIDDEN" "${out}"
# Extract the tip line — if there's no canonical tag yet (probe failed),
# the tip is silent and that's acceptable. When present, it must NOT
# parrot the attacker's tag back at the user.
if printf '%s' "${out}" | grep -q "v9.9.99"; then
  printf '  FAIL: T9-Z001: attacker tag v9.9.99 leaked into install-remote output\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# T10-Z002 (v1.34.1+, security-lens Z-002): OMC_EXPECTED_SHA verification.
# When set, the cloned tree's HEAD SHA must match the expected prefix or
# install.sh refuses to run. Closes the curl|bash zero-defense supply-
# chain risk.
printf 'T10-Z002: OMC_EXPECTED_SHA refuses run on mismatch\n'

CLONE_SHA_DIR="${WORK_DIR}/sha-clone"
set +e
out="$(OMC_SRC_DIR="${CLONE_SHA_DIR}" \
       OMC_REPO_URL="${BARE_REPO}" \
       OMC_REF="main" \
       OMC_EXPECTED_SHA="0000000000000000000000000000000000000000" \
       HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: T10-Z002: SHA mismatch should exit non-zero (rc=%s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "T10-Z002: error names SHA verification failure" "SHA verification FAILED" "${out}"
assert_contains "T10-Z002: error refuses to run install.sh" "Refusing to run install.sh" "${out}"

# T11-Z002: OMC_EXPECTED_SHA matching the actual HEAD passes through.
printf 'T11-Z002: OMC_EXPECTED_SHA matching HEAD lets install run\n'

CLONE_SHA_OK="${WORK_DIR}/sha-clone-ok"
# Discover the actual HEAD SHA in the bare repo by cloning fresh.
ACTUAL_SHA="$(git --git-dir="${BARE_REPO}" rev-parse HEAD 2>/dev/null || echo "missing")"
SHA_PREFIX="${ACTUAL_SHA:0:12}"

set +e
out="$(OMC_SRC_DIR="${CLONE_SHA_OK}" \
       OMC_REPO_URL="${BARE_REPO}" \
       OMC_REF="main" \
       OMC_EXPECTED_SHA="${SHA_PREFIX}" \
       HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -eq 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: T11-Z002: matching SHA should exit 0 (rc=%s)\n  out=%s\n' "${rc}" "${out}" >&2; fail=$((fail + 1)); }
assert_contains "T11-Z002: ok line names verification" "SHA verified" "${out}"
assert_contains "T11-Z002: install.sh ran after verification" "STUB-INSTALL-RAN" "${out}"

# T12-Z002: malformed OMC_EXPECTED_SHA is rejected loudly.
printf 'T12-Z002: malformed OMC_EXPECTED_SHA rejected with usage\n'

set +e
out="$(OMC_SRC_DIR="${WORK_DIR}/sha-bad" \
       OMC_REPO_URL="${BARE_REPO}" \
       OMC_REF="main" \
       OMC_EXPECTED_SHA="not-hex-and-too-short" \
       HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: T12-Z002: malformed SHA should exit non-zero (rc=%s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "T12-Z002: error names valid SHA shape" "7-40 char hex" "${out}"

# ----------------------------------------------------------------------
printf '\n=== Install-Remote Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
