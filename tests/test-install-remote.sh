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
  chmod +x install.sh
  git add install.sh
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
out="$(env -i HOME="${HOME}" PATH="${SAFE_PATH}" bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: missing-git should exit non-zero (got %s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "missing-prereq message names git" "git" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: fresh clone runs install.sh and passes args\n'
CLONE_DIR="${WORK_DIR}/clone1"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  bash "${BOOTSTRAPPER}" --no-ios --model-tier=balanced 2>&1)"
[[ -d "${CLONE_DIR}/.git" ]] && pass=$((pass + 1)) || { printf '  FAIL: clone dir not created\n' >&2; fail=$((fail + 1)); }
assert_contains "stub install ran" "STUB-INSTALL-RAN" "${out}"
assert_contains "pass-through args reach stub" "args=[--no-ios --model-tier=balanced]" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: re-run on existing clone updates without re-cloning\n'
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "update path taken" "updating existing clone" "${out}"
assert_contains "stub install ran on update" "STUB-INSTALL-RAN" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: clone with local changes does not reset (preserves user state)\n'
echo "user-edit" >> "${CLONE_DIR}/install.sh"
out="$(OMC_SRC_DIR="${CLONE_DIR}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  bash "${BOOTSTRAPPER}" 2>&1)"
assert_contains "skips reset on dirty tree" "skipping reset" "${out}"
# User edit should still be present
grep -q "user-edit" "${CLONE_DIR}/install.sh" && pass=$((pass + 1)) || { printf '  FAIL: user-edit was clobbered\n' >&2; fail=$((fail + 1)); }

# Restore clean tree for subsequent tests
git -C "${CLONE_DIR}" checkout -- install.sh

# ----------------------------------------------------------------------
printf 'Test 7a: parallel-run guard rejects when lock dir already exists\n'
LOCK_TARGET="${WORK_DIR}/locked-clone"
LOCK_OWNED="${LOCK_TARGET}.bootstrap.lock"
mkdir -p "$(dirname "${LOCK_OWNED}")"
mkdir "${LOCK_OWNED}"
set +e
out="$(OMC_SRC_DIR="${LOCK_TARGET}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: locked dir should block (rc=%s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "lock-blocked message names lockdir" "bootstrap.lock" "${out}"
rmdir "${LOCK_OWNED}"

# ----------------------------------------------------------------------
printf 'Test 7b: lock dir is released after a successful run\n'
LOCK_TARGET2="${WORK_DIR}/lock-release-clone"
out="$(OMC_SRC_DIR="${LOCK_TARGET2}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  bash "${BOOTSTRAPPER}" 2>&1)"
[[ ! -d "${LOCK_TARGET2}.bootstrap.lock" ]] && pass=$((pass + 1)) || { printf '  FAIL: lock dir leaked after success\n' >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
printf 'Test 7c: custom OMC_REPO_URL prints a loud warning\n'
WARN_TARGET="${WORK_DIR}/warn-clone"
out="$(OMC_SRC_DIR="${WARN_TARGET}" OMC_REPO_URL="${BARE_REPO}" OMC_REF="main" \
  bash "${BOOTSTRAPPER}" 2>&1)"
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
  bash "${BOOTSTRAPPER}" 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: missing-installer should exit non-zero (got %s)\n' "${rc}" >&2; fail=$((fail + 1)); }
assert_contains "missing-installer message" "install.sh not found" "${out}"

# ----------------------------------------------------------------------
printf '\n=== Install-Remote Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
