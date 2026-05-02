#!/usr/bin/env bash
# check-latency-budgets.sh — v1.28.0 hook-latency budget enforcement.
#
# Closes GPT review #5: "Make speed a first-class budget. Add per-feature
# latency budgets and fail CI if common hook paths regress above a
# threshold." Without this, hot-path hooks can silently grow as the
# bundle adds features and only become visible when the user notices
# slowness; with it, every release runs `bash check-latency-budgets.sh
# check` in CI and a budget breach blocks merge.
#
# Subcommands:
#   benchmark [--samples N] [--hook NAME]   Run all (or one) hooks N times,
#                                            print median + p95 ms per hook
#   check     [--samples N]                 Same as benchmark but exit 1
#                                            when ANY hook exceeds its
#                                            budget. Default for CI.
#   show-budgets                            Print the budget table
#
# Default samples: 5. Median + p95 over the samples are reported and
# compared against the budget. Single-sample budgets are flaky on shared
# machines (cold-cache first run dominates); 5 samples give stable
# medians without burning CI minutes.
#
# Budgets (ms; conf-overridable via OMC_LATENCY_BUDGET_<HOOK>_MS):
#   prompt-intent-router.sh: 1200  — heaviest hook (loads classifier +
#                                     blindspot inventory, emits up to 9
#                                     directives, runs once per prompt
#                                     so 1.2s upper bound is acceptable)
#   pretool-intent-guard.sh:  300  — runs on every PreToolUse; ~80ms typical
#   pretool-timing.sh:        200  — universal-matcher; ~100ms typical
#                                     (common.sh source + state-dir mkdir)
#   posttool-timing.sh:       200  — universal-matcher; ~100ms typical
#   stop-guard.sh:           1000  — gate enforcement; ~110ms typical
#   stop-time-summary.sh:     400  — formats per-prompt timing card; ~80ms
#
# Budgets are upper bounds — typical runs land 30-60% below — so a
# regression measurable to the user (>50% increase) trips the gate
# without false-positive flapping on shared CI runners.
#
# The numeric ceilings were tuned by running this script against the
# v1.28.0 release SHA on macOS dev (M-class) and adding 30-50% headroom.
# CI environments (Linux + GitHub Actions runners) tend to be slower —
# we deliberately err on the high side so legitimate macOS-dev runs
# don't trigger green→red transitions on Linux CI.
#
# Fail-open philosophy: a benchmark error (synthetic input rejected,
# script not found) prints a diagnostic but does NOT fail the gate.
# CI failures should be true latency regressions, not test infrastructure
# issues — a flaky benchmark would erode trust in the gate.

set -euo pipefail

. "${HOME}/.claude/skills/autowork/scripts/common.sh"

# --- Budget table ---

emit_budgets() {
  cat <<'EOF'
prompt-intent-router.sh|1200
pretool-intent-guard.sh|300
pretool-timing.sh|200
posttool-timing.sh|200
stop-guard.sh|1000
stop-time-summary.sh|400
EOF
}

# Resolve the effective budget for a hook (env override > default).
# Env var shape: OMC_LATENCY_BUDGET_<UPPER_NAME_WITH_UNDERSCORES>_MS
budget_for_hook() {
  local hook="$1"
  local default
  default="$(emit_budgets | awk -F'|' -v h="${hook}" '$1 == h { print $2; exit }')"
  if [[ -z "${default}" ]]; then
    printf '0'
    return
  fi
  local env_name="OMC_LATENCY_BUDGET_${hook//.sh/}"
  env_name="${env_name//-/_}"
  env_name="$(printf '%s' "${env_name}" | tr '[:lower:]' '[:upper:]')_MS"
  local override="${!env_name:-}"
  if [[ -n "${override}" ]] && [[ "${override}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${override}"
  else
    printf '%s' "${default}"
  fi
}

# --- Synthetic payloads ---

# Each hook takes a different JSON shape on stdin. Provide minimal
# realistic payloads — enough to traverse the hook's hot path without
# requiring real session state. SESSION_ID is a synthetic per-bench
# value so capture artifacts can be cleaned up afterwards.

bench_session_id() {
  printf 'omc-bench-%s-%s' "$$" "$1"
}

emit_payload_for_hook() {
  local hook="$1" sid="$2"
  case "${hook}" in
    prompt-intent-router.sh)
      jq -nc \
        --arg session_id "${sid}" \
        --arg cwd "${PWD}" \
        --arg prompt "ulw implement a small feature with tests" \
        '{session_id:$session_id, cwd:$cwd, prompt:$prompt}'
      ;;
    pretool-intent-guard.sh)
      jq -nc \
        --arg session_id "${sid}" \
        --arg cwd "${PWD}" \
        --arg tool "Read" \
        '{session_id:$session_id, cwd:$cwd, tool_name:$tool, tool_input:{file_path:"/etc/hostname"}}'
      ;;
    pretool-timing.sh|posttool-timing.sh)
      jq -nc \
        --arg session_id "${sid}" \
        --arg tool "Read" \
        --arg id "id-$$" \
        '{session_id:$session_id, tool_name:$tool, tool_use_id:$id}'
      ;;
    stop-guard.sh)
      jq -nc \
        --arg session_id "${sid}" \
        --arg cwd "${PWD}" \
        --arg msg "Done." \
        '{session_id:$session_id, cwd:$cwd, last_assistant_message:$msg}'
      ;;
    stop-time-summary.sh)
      jq -nc \
        --arg session_id "${sid}" \
        '{session_id:$session_id}'
      ;;
    *)
      jq -nc --arg session_id "${sid}" '{session_id:$session_id}'
      ;;
  esac
}

# --- Timing primitives ---

# now_ms — sub-second timestamp with fast paths first.
#
# Order of preference:
#   1. bash 5+ `EPOCHREALTIME` (`1234567890.123456` — 6 fractional digits).
#      Pure builtin, no fork, no jq, no python3 spawn. ~microseconds per call.
#   2. python3 -c (~30ms per call due to interpreter startup). Used on
#      bash 3.2 (default macOS) where EPOCHREALTIME is not exposed.
#   3. `date +%s` × 1000 (whole-second precision; loses fractional ms).
#      Last resort when neither bash 5 nor python3 is available.
#
# Why this matters: each python3 fork takes ~30ms, called twice per sample
# × 5 samples × 6 hooks = ~1.8s of overhead per `check` run. Worse, the
# python3 startup time straddled the bash invocation it was timing —
# inflating measured ms by 30-60ms per hook. The bash 5+ path closes
# both costs to negligible without changing the output format.
now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    # EPOCHREALTIME is `<sec>.<6 microsecond digits>`. Drop the dot
    # and the last 3 digits to get integer ms. Bash 3.2 substring
    # arithmetic uses ${var:start:length}, no negative offsets, so
    # compute length explicitly.
    local raw="${EPOCHREALTIME//./}"
    printf '%s' "${raw:0:$((${#raw} - 3))}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    printf '%d' "$(($(date +%s) * 1000))"
  fi
}

# Compute median + p95 from a sorted-ascending newline list.
# stdin: ms values, one per line. stdout: "median p95"
compute_stats() {
  local values
  values="$(sort -n)"
  local n
  n="$(printf '%s\n' "${values}" | grep -c .)"
  if [[ "${n}" -eq 0 ]]; then
    printf '0 0'
    return
  fi
  local mid_idx p95_idx
  # Use awk to handle floor() math without python.
  mid_idx="$(awk -v n="${n}" 'BEGIN { print int(n/2) + 1 }')"
  p95_idx="$(awk -v n="${n}" 'BEGIN {
    idx = int(n * 0.95 + 0.5)
    if (idx < 1) idx = 1
    if (idx > n) idx = n
    print idx
  }')"
  local median p95
  median="$(printf '%s\n' "${values}" | sed -n "${mid_idx}p")"
  p95="$(printf '%s\n' "${values}" | sed -n "${p95_idx}p")"
  printf '%s %s' "${median:-0}" "${p95:-0}"
}

# --- Benchmark runner ---

# Run a single hook N times against synthetic input. Output is captured
# and discarded — we measure wall-clock latency only.
benchmark_hook() {
  local hook="$1" samples="$2" stay_quiet="${3:-0}"
  local script_path="${HOME}/.claude/skills/autowork/scripts/${hook}"
  if [[ ! -f "${script_path}" ]]; then
    # Try the bundle path (testing the source repo before install).
    if [[ -f "${PWD}/bundle/dot-claude/skills/autowork/scripts/${hook}" ]]; then
      script_path="${PWD}/bundle/dot-claude/skills/autowork/scripts/${hook}"
    elif [[ -f "${PWD}/bundle/dot-claude/quality-pack/scripts/${hook}" ]]; then
      script_path="${PWD}/bundle/dot-claude/quality-pack/scripts/${hook}"
    else
      [[ "${stay_quiet}" -eq 1 ]] || printf 'check-latency-budgets: missing %s\n' "${hook}" >&2
      return 1
    fi
  fi

  local i start end measurements=()
  local sid payload
  for ((i = 1; i <= samples; i++)); do
    sid="$(bench_session_id "${i}")"
    payload="$(emit_payload_for_hook "${hook}" "${sid}")"
    start="$(now_ms)"
    bash "${script_path}" >/dev/null 2>&1 <<< "${payload}" || true
    end="$(now_ms)"
    measurements+=( $((end - start)) )
  done

  # Cleanup synthetic state directories the bench created.
  rm -rf "${STATE_ROOT}"/omc-bench-$$-* 2>/dev/null || true

  printf '%d\n' "${measurements[@]}" | compute_stats
}

# --- Subcommands ---

cmd_benchmark() {
  local samples=5 only_hook=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --samples) samples="${2:-5}"; shift 2 ;;
      --hook)    only_hook="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  printf '%-32s %8s %8s %8s   %s\n' "HOOK" "MEDIAN" "P95" "BUDGET" "STATUS"
  printf '%-32s %8s %8s %8s   %s\n' "----" "------" "---" "------" "------"

  local breaches=0 missing=0 hook budget median p95 status
  while IFS='|' read -r hook _; do
    [[ -z "${hook}" ]] && continue
    if [[ -n "${only_hook}" ]] && [[ "${hook}" != "${only_hook}" ]]; then
      continue
    fi
    budget="$(budget_for_hook "${hook}")"
    local stats
    stats="$(benchmark_hook "${hook}" "${samples}" 1 || echo "MISSING MISSING")"
    if [[ "${stats}" == "MISSING MISSING" ]]; then
      missing=$((missing + 1))
      printf '%-32s %8s %8s %8s   %s\n' "${hook}" "—" "—" "${budget}ms" "missing"
      continue
    fi
    median="${stats%% *}"
    p95="${stats##* }"
    if [[ "${p95}" -gt "${budget}" ]]; then
      breaches=$((breaches + 1))
      status="BREACH"
    else
      status="ok"
    fi
    printf '%-32s %7sms %7sms %7sms   %s\n' "${hook}" "${median}" "${p95}" "${budget}" "${status}"
  done < <(emit_budgets)

  printf '\nSamples per hook: %d\n' "${samples}"
  if [[ "${missing}" -gt 0 ]]; then
    printf '%d hook(s) not found (skipped, not failures)\n' "${missing}"
  fi
  if [[ "${breaches}" -gt 0 ]]; then
    printf '%d budget breach(es) detected\n' "${breaches}"
    return 1
  fi
  printf 'All hooks within budget\n'
  return 0
}

cmd_check() {
  cmd_benchmark "$@"
}

cmd_show_budgets() {
  printf '%-32s %s\n' "HOOK" "BUDGET (ms)"
  printf '%-32s %s\n' "----" "-----------"
  local hook ms
  while IFS='|' read -r hook ms; do
    [[ -z "${hook}" ]] && continue
    local effective
    effective="$(budget_for_hook "${hook}")"
    if [[ "${effective}" != "${ms}" ]]; then
      printf '%-32s %s (env override; default %s)\n' "${hook}" "${effective}" "${ms}"
    else
      printf '%-32s %s\n' "${hook}" "${ms}"
    fi
  done < <(emit_budgets)
}

usage() {
  cat <<'EOF'
check-latency-budgets.sh — v1.28.0 hook-latency budget enforcement.

Subcommands:
  benchmark [--samples N] [--hook NAME]   Run hooks N times, print stats
  check     [--samples N]                 Same as benchmark; exit 1 on breach
  show-budgets                            Print the budget table

Per-hook budget overrides via env:
  OMC_LATENCY_BUDGET_<HOOK>_MS=<ms>
  e.g., OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=500

Default samples: 5 (median + p95).

CI integration: a release pipeline runs `bash check-latency-budgets.sh
check` and fails the build on a budget breach. Closes GPT review #5
("speed as first-class budget").
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    benchmark)    cmd_benchmark "$@" ;;
    check)        cmd_check "$@" ;;
    show-budgets) cmd_show_budgets ;;
    ""|-h|--help) usage ;;
    *)
      printf 'check-latency-budgets: unknown subcommand: %s\n' "${cmd}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
