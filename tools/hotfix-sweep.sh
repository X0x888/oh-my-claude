#!/usr/bin/env bash
#
# tools/hotfix-sweep.sh — fast-feedback gate that runs after every
# fix commit during release prep, before bumping VERSION. Catches
# the "compound-fix tag-race" anti-pattern named in the v1.31.x
# release post-mortem (each hotfix is itself an opportunity for a
# new hotfix unless the post-fix regression net is enforced).
#
# v1.32.11 (R5 closure from the v1.32.0 release post-mortem). The
# v1.31.0→v1.31.3 cascade shipped 4 patches in one day; F-3's fix
# introduced its own regression that needed F-3-followup. Each step
# in this sweep would have caught that class:
#
#   1. Sterile-env CI-parity (R3, mandatory since v1.32.2):
#      catches "passes locally because dev has state X, fails in CI
#      because tmpfs has empty X" (v1.31.0 T7).
#
#   2. CHANGELOG-coupled tests (v1.32.7 step-8 fix, v1.32.8 grep-
#      based generalization): catches install-whats-new cap drift
#      (v1.31.1, v1.32.1, v1.32.3, v1.32.5, v1.32.6).
#
#   3. shellcheck on changed files: catches the lint warnings that
#      are CI-fatal under --severity=warning.
#
#   4. Lib-reachability check: every modified bundle/.../lib/*.sh
#      since the last tag must have a CI-pinned tests/test-${name}.sh
#      (test-coordination-rules.sh contract C3, regressed here as
#      a pre-tag check rather than a post-CI block).
#
# Total runtime budget: ~2 min on a recent macOS / Ubuntu runner.
# Fast-path: if no fix-commit-shaped changes since the last tag
# (only docs / changelog edits), skip the heavy checks and exit
# with a "no-op, sweep clean" message.
#
# Developer-only — NOT installed by install.sh; lives under tools/.
#
# Usage:
#   bash tools/hotfix-sweep.sh           # run all 4 checks
#   bash tools/hotfix-sweep.sh --quick   # skip sterile-env (1-min budget)
#   bash tools/hotfix-sweep.sh --verbose # print per-check progress

set -euo pipefail

quick=0
verbose=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)   quick=1; shift ;;
    --verbose) verbose=1; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

failures=()
warnings=()

log() { [[ "${verbose}" -eq 1 ]] && printf '  [hotfix-sweep] %s\n' "$1" >&2 ; return 0; }
hdr() { printf '── %s ───\n' "$1"; }

# ---------------------------------------------------------------------
hdr "Hotfix-sweep gate (v1.32.11 R5)"

# Last-tag baseline. Falls back to HEAD~10 when no tags exist (e.g.,
# fresh-clone test scenario).
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
if [[ -z "${LAST_TAG}" ]]; then
  LAST_TAG="$(git rev-parse HEAD~10 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")"
fi
log "baseline: ${LAST_TAG}"

CHANGED_FILES="$(git diff --name-only "${LAST_TAG}..HEAD" 2>/dev/null || true)"
if [[ -z "${CHANGED_FILES}" ]]; then
  printf '  No changes since %s — sweep is a no-op.\n' "${LAST_TAG}"
  exit 0
fi
log "changed since ${LAST_TAG}: $(printf '%s\n' "${CHANGED_FILES}" | wc -l | tr -d ' ') file(s)"

# Fast-path: if only docs / CHANGELOG / VERSION changed, skip the
# heavy checks. The CHANGELOG-coupled-tests check still runs because
# CHANGELOG edits CAN break extract_whats_new (the v1.31.1+ class).
FIX_SHAPED=0
while IFS= read -r f; do
  [[ -z "${f}" ]] && continue
  case "${f}" in
    *.md|VERSION|CHANGELOG*) ;;  # docs-only — skip
    *) FIX_SHAPED=1; break ;;
  esac
done <<<"${CHANGED_FILES}"
log "fix-shaped: ${FIX_SHAPED}"

# ---------------------------------------------------------------------
# Check 1 — Sterile-env CI-parity (skipped under --quick)
# ---------------------------------------------------------------------
if [[ "${quick}" -eq 1 ]]; then
  printf '  [skip] sterile-env (--quick mode)\n'
  warnings+=("sterile-env skipped — re-run without --quick before tagging")
elif [[ "${FIX_SHAPED}" -eq 1 ]] && [[ -x "${REPO_ROOT}/tests/run-sterile.sh" ]]; then
  printf '  [run]  sterile-env CI-parity ...'
  if bash "${REPO_ROOT}/tests/run-sterile.sh" >/tmp/hotfix-sweep-sterile.log 2>&1; then
    printf ' OK\n'
  else
    printf ' FAIL\n'
    failures+=("sterile-env: see /tmp/hotfix-sweep-sterile.log")
  fi
else
  printf '  [skip] sterile-env (no fix-shaped changes)\n'
fi

# ---------------------------------------------------------------------
# Check 2 — CHANGELOG-coupled tests (always runs — see v1.32.7/8
# process-gap fix; CHANGELOG edits invalidate test assertions even
# when no source code changed)
# ---------------------------------------------------------------------
printf '  [run]  CHANGELOG-coupled tests ...'
coupled_tests=()
while IFS= read -r t; do
  [[ -n "${t}" ]] && coupled_tests+=("${t}")
done < <(grep -lE 'CHANGELOG\.md|extract_whats_new' "${REPO_ROOT}"/tests/test-*.sh 2>/dev/null || true)

coupled_failures=0
for t in "${coupled_tests[@]+"${coupled_tests[@]}"}"; do
  if ! bash "${t}" >/dev/null 2>&1; then
    coupled_failures=$((coupled_failures + 1))
    failures+=("CHANGELOG-coupled: $(basename "${t}")")
  fi
done
if [[ "${coupled_failures}" -eq 0 ]]; then
  printf ' OK (%d test files)\n' "${#coupled_tests[@]}"
else
  printf ' FAIL (%d/%d)\n' "${coupled_failures}" "${#coupled_tests[@]}"
fi

# ---------------------------------------------------------------------
# Check 3 — shellcheck on changed bundle/ scripts (CI parity)
# ---------------------------------------------------------------------
if [[ "${FIX_SHAPED}" -eq 1 ]]; then
  printf '  [run]  shellcheck on changed bundle/*.sh ...'
  shellcheck_failed=0
  changed_sh=()
  while IFS= read -r f; do
    [[ -n "${f}" ]] && case "${f}" in bundle/*.sh) changed_sh+=("${f}") ;; esac
  done <<<"${CHANGED_FILES}"
  if [[ "${#changed_sh[@]}" -gt 0 ]]; then
    if shellcheck -x --severity=warning "${changed_sh[@]+"${changed_sh[@]}"}" >/tmp/hotfix-sweep-shellcheck.log 2>&1; then
      printf ' OK (%d files)\n' "${#changed_sh[@]}"
    else
      shellcheck_failed=1
      printf ' FAIL\n'
      failures+=("shellcheck: see /tmp/hotfix-sweep-shellcheck.log")
    fi
  else
    printf ' OK (no changed bundle/*.sh)\n'
  fi
fi

# ---------------------------------------------------------------------
# Check 4 — lib-reachability (every modified bundle/.../lib/*.sh has
# a CI-pinned test) — same contract as test-coordination-rules.sh:C3
# but checked here as a release-prep gate rather than a post-CI block.
# ---------------------------------------------------------------------
if [[ "${FIX_SHAPED}" -eq 1 ]]; then
  printf '  [run]  lib-reachability ...'
  lib_orphans=()
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    case "${f}" in
      */lib/*.sh)
        libname="$(basename "${f}" .sh)"
        # Codify the verification.sh exception (same as
        # test-coordination-rules.sh:C3).
        if [[ "${libname}" == "verification" ]]; then
          expected_test="${REPO_ROOT}/tests/test-verification-lib.sh"
        else
          expected_test="${REPO_ROOT}/tests/test-${libname}.sh"
        fi
        if [[ ! -f "${expected_test}" ]]; then
          lib_orphans+=("${f}")
        elif ! grep -qE "^\s+run:\s+bash tests/test-${libname}(-lib)?\.sh" \
              "${REPO_ROOT}/.github/workflows/validate.yml" 2>/dev/null; then
          lib_orphans+=("${f} (test exists but not CI-pinned)")
        fi
        ;;
    esac
  done <<<"${CHANGED_FILES}"
  if [[ "${#lib_orphans[@]}" -eq 0 ]]; then
    printf ' OK\n'
  else
    printf ' FAIL\n'
    for orphan in "${lib_orphans[@]}"; do
      failures+=("lib-reachability: ${orphan}")
    done
  fi
fi

# ---------------------------------------------------------------------
hdr "Sweep summary"

if [[ "${#failures[@]}" -gt 0 ]]; then
  printf '%d failure(s):\n' "${#failures[@]}"
  for f in "${failures[@]}"; do
    printf '  ✗ %s\n' "${f}"
  done
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    for w in "${warnings[@]}"; do
      printf '  ! %s\n' "${w}"
    done
  fi
  printf '\nFix the failures and re-run before bumping VERSION.\n'
  exit 1
fi

printf '✓ All checks passed.\n'
if [[ "${#warnings[@]}" -gt 0 ]]; then
  for w in "${warnings[@]}"; do
    printf '  ! %s\n' "${w}"
  done
  printf '\nWarnings present — re-run without --quick before tagging.\n'
fi

exit 0
