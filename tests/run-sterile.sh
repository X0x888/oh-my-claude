#!/usr/bin/env bash
#
# tests/run-sterile.sh — sterile-env CI-parity local runner.
#
# v1.32.0 R3 (release post-mortem remediation): runs the CI-pinned
# bash tests under env scrubbed to look like Ubuntu CI's tmpfs.
# Catches the v1.31.0-class defect (T7 sterile-CI miss) before tag
# rather than after.
#
# Mode: STRICT by default (v1.32.2 promotion) — exits non-zero on any
# sterile-only failure. Override to ADVISORY by passing --advisory or
# setting OMC_STERILE_ADVISORY=1.
#
# Phase 1 (v1.32.0) — ADVISORY mode for one release cycle, observed
#   7 env-leak susceptibilities (test-e2e-hook-sequence,
#   test-phase8-integration, test-gate-events, test-stop-failure-handler,
#   test-session-start-resume-hint, test-claim-resume-request,
#   test-resume-watchdog).
# Phase 2 (v1.32.2) — closed all 7 by removing pre-set STATE_ROOT and
#   SESSION_ID from build_sterile_env (they collided with the harness's
#   ${HOME}/.claude/quality-pack/state derivation) and adding /sbin
#   to the sterile PATH (macOS md5 lives at /sbin/md5). Promoted to
#   STRICT default for CONTRIBUTING.md Step 3.
#
# Usage:
#   bash tests/run-sterile.sh                    # strict, exit non-zero on any sterile-only failure
#   bash tests/run-sterile.sh --advisory         # report-only
#   OMC_STERILE_ADVISORY=1 bash tests/run-sterile.sh
#   bash tests/run-sterile.sh --only test-show-status.sh    # single test
#
# Output: one line per test
#   PASS   test-foo.sh         (passes both env-scrubbed and dev env)
#   STERILE-FAIL test-bar.sh   (passes dev env, fails sterile — leaks env)
#   FAIL   test-baz.sh         (fails both — pre-existing breakage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/sterile-env.sh"

# Args
mode="strict"  # v1.32.2: strict by default
only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) mode="strict"; shift ;;
    --advisory) mode="advisory"; shift ;;
    --only) only="$2"; shift 2 ;;
    -h|--help) sed -n '/^#/p' "$0" | sed 's/^#//' ; exit 0 ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done
# Backward-compat: pre-1.32.2 used OMC_STERILE_STRICT=1 to turn on
# strict mode. Now strict is default; OMC_STERILE_ADVISORY=1 is the
# new opt-out. Honor both for compatibility.
[[ "${OMC_STERILE_STRICT:-0}" == "1" ]] && mode="strict"
[[ "${OMC_STERILE_ADVISORY:-0}" == "1" ]] && mode="advisory"

# Extract CI-pinned test list LIVE from validate.yml so this can't
# drift. Mirrors the CONTRIBUTING.md Step 2 grep extraction.
ci_pinned=()
while IFS= read -r line; do
  ci_pinned+=("${line}")
done < <(
  grep -E '^\s+run:\s+bash tests/test-' "${REPO_ROOT}/.github/workflows/validate.yml" 2>/dev/null \
    | awk '{print $NF}' \
    | sed 's|^tests/||'
)

if [[ ${#ci_pinned[@]} -eq 0 ]]; then
  printf 'No CI-pinned tests found — check workflow path.\n' >&2
  exit 2
fi

# Filter
if [[ -n "${only}" ]]; then
  filtered=()
  for t in "${ci_pinned[@]}"; do
    [[ "${t}" == "${only}" ]] && filtered+=("${t}")
  done
  ci_pinned=("${filtered[@]}")
fi

# Run each pinned test under sterile env. Compare with dev-env run
# only when sterile fails, so we can distinguish "pre-existing
# breakage" from "env-leak regression".
sterile_env="$(build_sterile_env)"
sterile_env_array=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && sterile_env_array+=("${line}")
done <<<"${sterile_env}"

pass=0
sterile_fail=0
double_fail=0
fail_list=()

printf '── sterile-env CI-parity run (mode: %s) ───\n' "${mode}"
printf 'Tests: %d  PATH preview: %s\n\n' "${#ci_pinned[@]}" "$(printf '%s\n' "${sterile_env}" | grep '^PATH=' | head -1)"

for t in "${ci_pinned[@]}"; do
  test_path="${REPO_ROOT}/tests/${t}"
  if [[ ! -f "${test_path}" ]]; then
    printf '  SKIP  %s  (file missing)\n' "${t}"
    continue
  fi

  # Run under sterile env. Suppress output (test summary at end is
  # what we care about); a per-test rerun in dev-env happens only
  # when sterile fails.
  if env -i "${sterile_env_array[@]}" bash "${test_path}" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "${t}"
    pass=$((pass + 1))
  else
    # Sterile failed. Re-run under dev env to classify.
    if bash "${test_path}" >/dev/null 2>&1; then
      printf '  STERILE-FAIL  %s  (passes dev env — env-leak regression)\n' "${t}"
      sterile_fail=$((sterile_fail + 1))
      fail_list+=("STERILE-FAIL: ${t}")
    else
      printf '  FAIL  %s  (also fails dev env — pre-existing breakage)\n' "${t}"
      double_fail=$((double_fail + 1))
      fail_list+=("FAIL: ${t}")
    fi
  fi
done

printf '\n── Summary ───\n'
printf '  Passed under sterile + dev:  %d\n' "${pass}"
printf '  Sterile-only failures:       %d\n' "${sterile_fail}"
printf '  Pre-existing failures:       %d\n' "${double_fail}"
total=$((pass + sterile_fail + double_fail))
printf '  Total:                       %d\n' "${total}"

if [[ ${#fail_list[@]} -gt 0 ]]; then
  printf '\n── Failures ───\n'
  for f in "${fail_list[@]}"; do
    printf '  %s\n' "${f}"
  done
fi

# Exit code semantics:
#   advisory mode (default) — always exit 0, report only
#   strict mode             — exit 1 on any sterile-only failure
if [[ "${mode}" == "strict" && ${sterile_fail} -gt 0 ]]; then
  printf '\n[strict] %d sterile-only failure(s) — release blocked.\n' "${sterile_fail}" >&2
  exit 1
fi

if [[ ${sterile_fail} -gt 0 ]]; then
  printf '\n[advisory] %d sterile-only failure(s) — review before promoting to mandatory.\n' "${sterile_fail}"
fi

exit 0
