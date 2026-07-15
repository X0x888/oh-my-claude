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
# test failure. Override to ADVISORY by passing --advisory or
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
#   bash tests/run-sterile.sh                    # strict, exit non-zero on any test failure
#   bash tests/run-sterile.sh --advisory         # report-only
#   OMC_STERILE_ADVISORY=1 bash tests/run-sterile.sh
#   bash tests/run-sterile.sh --only test-show-status.sh    # single test
#   bash tests/run-sterile.sh --changed --base origin/main  # impacted PR tests only
#   bash tests/run-sterile.sh --plan --changed --base origin/main  # list, do not execute
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
selection="full"
base_ref=""
plan_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) mode="strict"; shift ;;
    --advisory) mode="advisory"; shift ;;
    --full) selection="full"; base_ref=""; shift ;;
    --changed) selection="changed"; shift ;;
    --base)
      [[ $# -ge 2 ]] || { printf '%s\n' '--base requires a git ref' >&2; exit 2; }
      selection="changed"
      base_ref="$2"
      shift 2
      ;;
    --plan) plan_only=1; shift ;;
    --only)
      [[ $# -ge 2 ]] || { printf '%s\n' '--only requires a test filename' >&2; exit 2; }
      only="$2"
      shift 2
      ;;
    -h|--help) sed -n '/^#/p' "$0" | sed 's/^#//' ; exit 0 ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done
# Env-var precedence (v1.32.3 fix): mutually-exclusive checks with a
# loud warning when both are set. Pre-1.32.3 the order
#   [[ STRICT ]] && mode="strict"
#   [[ ADVISORY ]] && mode="advisory"
# meant the second check unconditionally overwrote the first — strict
# silently degraded to advisory if a user had STRICT=1 in their shell
# rc and a teammate set ADVISORY=1 elsewhere. Now: ADVISORY wins
# (matches CLI flag --advisory which the user explicitly typed),
# STRICT is the legacy backward-compat path, the warning makes the
# resolution auditable.
if [[ "${OMC_STERILE_ADVISORY:-0}" == "1" ]] && [[ "${OMC_STERILE_STRICT:-0}" == "1" ]]; then
  printf 'warn: both OMC_STERILE_ADVISORY=1 and OMC_STERILE_STRICT=1 are set; picking advisory\n' >&2
  mode="advisory"
elif [[ "${OMC_STERILE_ADVISORY:-0}" == "1" ]]; then
  mode="advisory"
elif [[ "${OMC_STERILE_STRICT:-0}" == "1" ]]; then
  mode="strict"
fi

# Extract CI-pinned test list LIVE from validate.yml via the shared
# helper so sterile parity stays in lockstep with release.sh and the
# coordination audit.
ci_pinned=()
while IFS= read -r line; do
  ci_pinned+=("${line}")
done < <(
  bash "${REPO_ROOT}/tools/list-ci-pinned-tests.sh" "${REPO_ROOT}/.github/workflows/validate.yml" 2>/dev/null \
    | sed 's|^tests/||'
)

if [[ ${#ci_pinned[@]} -eq 0 ]]; then
  printf 'No CI-pinned tests found — check workflow path.\n' >&2
  exit 2
fi

# Pull-request sterile coverage is change-proportional: reuse the authoritative
# change-aware selector in tools/run-tests.sh, but execute the selected tests
# under the scrubbed environment here. A broad or unmapped production change
# makes that selector fail closed to the full suite; a narrow PR pays only for
# its impacted tests. The default remains full so release and local workflows
# retain exhaustive sterile coverage.
if [[ "${selection}" == "changed" ]]; then
  runner_args=(--changed --list --no-record)
  [[ -n "${base_ref}" ]] && runner_args+=(--base "${base_ref}")
  set +e
  changed_plan="$(bash "${REPO_ROOT}/tools/run-tests.sh" "${runner_args[@]}" 2>&1)"
  changed_plan_rc=$?
  set -e
  if [[ "${changed_plan_rc}" -ne 0 ]]; then
    printf 'Could not plan change-aware sterile tests:\n%s\n' "${changed_plan}" >&2
    exit 2
  fi

  changed_selected=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && changed_selected+=("${line}")
  done < <(
    printf '%s\n' "${changed_plan}" \
      | sed -n 's|^[[:space:]]*tests/\(test-[A-Za-z0-9._-]*\.sh\).*|\1|p' \
      | LC_ALL=C sort -u
  )

  proportional=()
  if [[ ${#changed_selected[@]} -gt 0 ]]; then
    for selected_test in "${changed_selected[@]}"; do
      for pinned_test in "${ci_pinned[@]}"; do
        if [[ "${selected_test}" == "${pinned_test}" ]]; then
          proportional+=("${selected_test}")
          break
        fi
      done
    done
  fi
  if [[ ${#proportional[@]} -gt 0 ]]; then
    ci_pinned=("${proportional[@]}")
  else
    ci_pinned=()
  fi
fi

# Filter
if [[ -n "${only}" ]]; then
  filtered=()
  if [[ ${#ci_pinned[@]} -gt 0 ]]; then
    for t in "${ci_pinned[@]}"; do
      [[ "${t}" == "${only}" ]] && filtered+=("${t}")
    done
  fi
  if [[ ${#filtered[@]} -gt 0 ]]; then
    ci_pinned=("${filtered[@]}")
  else
    ci_pinned=()
  fi
fi

if [[ ${#ci_pinned[@]} -eq 0 ]]; then
  printf 'No sterile tests selected (selection=%s%s).\n' \
    "${selection}" "${only:+, only=${only}}" >&2
  exit 2
fi

if [[ "${plan_only}" -eq 1 ]]; then
  printf '── sterile-env plan (mode: %s; selection: %s) ───\n' \
    "${mode}" "${selection}"
  [[ -n "${base_ref}" ]] && printf 'Base: %s\n' "${base_ref}"
  printf 'Tests: %d\n' "${#ci_pinned[@]}"
  for t in "${ci_pinned[@]}"; do
    printf '  tests/%s\n' "${t}"
  done
  printf 'Planning only; no tests executed.\n'
  exit 0
fi

# Run each pinned test under sterile env. Compare with dev-env run
# only when sterile fails, so we can distinguish "pre-existing
# breakage" from "env-leak regression".
sterile_env="$(build_sterile_env)"
sterile_env_array=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && sterile_env_array+=("${line}")
done <<<"${sterile_env}"

# v1.40.x: register EXIT trap to clean the sterile HOME + TMPDIR that
# build_sterile_env just created. Pre-fix the script captured both
# paths inside the printed env lines but never cleaned either —
# every `run-sterile.sh` invocation leaked `/tmp/omc-sterile-tmp-XXX`
# (56 such orphans accumulated on a dev host over 4 days before the
# leak was noticed). The cleanup-orphan-tmp.sh SessionStart sweep is
# the safety net; this trap is the source-side fix.
_sterile_home_path="$(extract_sterile_path HOME "${sterile_env}")"
_sterile_tmp_path="$(extract_sterile_path TMPDIR "${sterile_env}")"
trap 'cleanup_sterile_env "${_sterile_home_path}" "${_sterile_tmp_path}"' EXIT

pass=0
sterile_fail=0
double_fail=0
fail_list=()

printf '── sterile-env CI-parity run (mode: %s; selection: %s) ───\n' \
  "${mode}" "${selection}"
printf 'Tests: %d  PATH preview: %s\n\n' "${#ci_pinned[@]}" "$(printf '%s\n' "${sterile_env}" | grep '^PATH=' | head -1)"

for t in "${ci_pinned[@]}"; do
  test_path="${REPO_ROOT}/tests/${t}"
  if [[ ! -f "${test_path}" ]]; then
    printf '  SKIP  %s  (file missing)\n' "${t}"
    continue
  fi

  # Run under sterile env. Output is captured per test and printed ONLY
  # on failure (v1.47): the pre-fix `>/dev/null 2>&1` discarded the
  # failing test's assertions entirely, so a STERILE-FAIL in CI was a
  # release blocker with zero diagnostic detail — the v1.44.0→v1.47.0
  # CI redness sat undiagnosable for 17 days because of exactly this.
  _sterile_out="$(mktemp)"
  if env -i "${sterile_env_array[@]}" bash "${test_path}" >"${_sterile_out}" 2>&1; then
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
    printf '  ── failing output (last 40 lines, sterile run) ───\n'
    tail -40 "${_sterile_out}" | sed 's/^/  │ /'
    printf '  ── end failing output ───\n'
  fi
  rm -f "${_sterile_out}"
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
#   advisory mode — always exit 0, report only
#   strict mode   — exit 1 on any sterile-only or ordinary test failure
failure_total=$((sterile_fail + double_fail))
if [[ "${mode}" == "strict" && ${failure_total} -gt 0 ]]; then
  printf '\n[strict] %d test failure(s) (%d sterile-only, %d in both environments) — release blocked.\n' \
    "${failure_total}" "${sterile_fail}" "${double_fail}" >&2
  exit 1
fi

if [[ ${failure_total} -gt 0 ]]; then
  printf '\n[advisory] %d test failure(s) (%d sterile-only, %d in both environments) — review before release.\n' \
    "${failure_total}" "${sterile_fail}" "${double_fail}"
fi

exit 0
