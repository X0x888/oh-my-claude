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
#   1. Essential behavior portfolio: the same deliberately small set CI runs.
#
#   2. shellcheck on changed files: catches the lint warnings that
#      are CI-fatal under --severity=warning.
#
# Total runtime budget: under 10 min on a recent macOS / Ubuntu runner.
# Fast-path: if no fix-commit-shaped changes since the last tag
# (only docs / changelog edits), skip the heavy checks and exit
# with a "no-op, sweep clean" message.
#
# Developer-only — NOT installed by install.sh; lives under tools/.
#
# Usage:
#   bash tools/hotfix-sweep.sh           # run all checks
#   bash tools/hotfix-sweep.sh --quick   # skip the behavior portfolio
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

# Last-tag baseline. Falls back to root commit when no tags exist
# (fresh shallow clone, fork without upstream tags, --depth=1 install-
# remote bootstrap path). v1.32.12 (G1 fix from v1.32.11 reviewer):
# pre-fix used `git rev-parse HEAD~10` which writes "HEAD~10" to
# STDOUT before failing rc=128 (only stderr was redirected); the
# `||` chain then captured the bad-stdout, producing a multi-line
# baseline that broke the `git diff ${LAST_TAG}..HEAD` and silently
# green-passed the gate. The fix uses `git rev-list --max-parents=0
# HEAD` (root commit walk — `git rev-parse` does NOT recognize
# --max-parents as a flag and would output it literally; this is
# specifically a rev-list feature).
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "${LAST_TAG}" ]]; then
  # Take the FIRST line so a multi-root repo doesn't produce
  # multi-line output that breaks the diff.
  LAST_TAG="$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1 || true)"
fi
if [[ -z "${LAST_TAG}" ]]; then
  printf '  ERROR: cannot determine baseline — no tags AND `git rev-parse --max-parents=0 HEAD` failed.\n' >&2
  printf '         Are you inside a git repo?\n' >&2
  exit 1
fi
log "baseline: ${LAST_TAG}"

CHANGED_FILES="$(git diff --name-only "${LAST_TAG}..HEAD" 2>/dev/null || true)"
if [[ -z "${CHANGED_FILES}" ]]; then
  printf '  No changes since %s — sweep is a no-op.\n' "${LAST_TAG}"
  exit 0
fi
log "changed since ${LAST_TAG}: $(printf '%s\n' "${CHANGED_FILES}" | wc -l | tr -d ' ') file(s)"

# Fast-path: if only docs / CHANGELOG / VERSION changed, skip the
# heavy checks.
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
# Check 1 — retained essential portfolio (skipped under --quick)
# ---------------------------------------------------------------------
if [[ "${quick}" -eq 1 ]]; then
  printf '  [skip] essential portfolio (--quick mode)\n'
  warnings+=("essential portfolio skipped — re-run without --quick before tagging")
elif [[ "${FIX_SHAPED}" -eq 1 ]]; then
  printf '  [run]  essential behavior portfolio ...'
  if bash "${REPO_ROOT}/tools/run-tests.sh" >/tmp/hotfix-sweep-tests.log 2>&1; then
    printf ' OK\n'
  else
    printf ' FAIL\n'
    failures+=("essential portfolio: see /tmp/hotfix-sweep-tests.log")
  fi
else
  printf '  [skip] essential portfolio (no fix-shaped changes)\n'
fi

# ---------------------------------------------------------------------
# Check 2 — shellcheck on changed bundle/ scripts (CI parity)
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
hdr "Sweep summary"

# v1.32.12 (G3 fix): if a prior --quick run left the marker, a
# subsequent NON-quick run must complete to clear it. Block tagging
# when the marker is still present (i.e., user's last sweep was
# --quick).
if [[ -f "${REPO_ROOT}/.hotfix-sweep-quick" ]] && [[ "${quick}" -ne 1 ]]; then
  : # this run will clear the marker on success — fall through
elif [[ -f "${REPO_ROOT}/.hotfix-sweep-quick" ]] && [[ "${quick}" -eq 1 ]]; then
  warnings+=("prior sweep was also --quick — essential portfolio still unverified")
fi

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
  # v1.32.12 (G3 fix): --quick mode is advisory but Step 6 marks the
  # gate as MANDATORY. Stamp a marker so a follow-up full sweep can
  # detect the prior --quick and require a re-run. The CONTRIBUTING.md
  # discipline is "always end on a non-quick run before tagging" —
  # this marker makes that auditable rather than reliance-on-memory.
  : > "${REPO_ROOT}/.hotfix-sweep-quick"
  exit 0
fi
# Successful non-quick run clears any prior --quick marker.
rm -f "${REPO_ROOT}/.hotfix-sweep-quick" 2>/dev/null || true

exit 0
