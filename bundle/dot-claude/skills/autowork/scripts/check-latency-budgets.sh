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
#                                            print first + median + p95 ms
#                                            per hook
#   check     [--samples N]                 Same as benchmark but exit 1
#                                            when ANY hook exceeds its
#                                            budget. Default for CI.
#   show-budgets                            Print the budget table
#
# Default samples: 5. First-sample + median + p95 over the remaining warm
# samples are reported. P95 is compared against the warm budget; first-sample is
# compared against a cold budget (default 150% of warm). This keeps the
# common-path p95 tight while still surfacing cold/warm skew explicitly.
#
# Budgets (ms; conf-overridable via OMC_LATENCY_BUDGET_<HOOK>_MS):
#   prompt-intent-router.sh: 1500  — heaviest hook (loads classifier +
#                                     blindspot inventory, emits up to 9
#                                     directives, runs once per prompt
#                                     so 1.5s upper bound is acceptable)
#   dispatch-recovery-guard.sh: 200 — universal causal-fence fast path
#   pretool-intent-guard.sh:  300  — runs on every PreToolUse; benchmark uses
#                                     a real opaque Bash snapshot candidate
#   quality-constitution-authority-guard.sh: 300 — always-on mutation authority
#   pretool-timing.sh:        200  — universal-matcher; ~100ms typical
#                                     (common.sh source + state-dir mkdir)
#   posttool-timing.sh:       200  — universal-matcher; ~100ms typical
#   stop-guard.sh:           1000  — gate enforcement; ~110ms typical
#   stop-time-summary.sh:     400  — formats per-prompt timing card; ~80ms
#   closeout-display.sh:      600  — ordinary material MessageDisplay batch
#   closeout-preflight.sh:    600  — non-terminal PostToolBatch fast path
#   stop-dispatch.sh:        1800  — guard dispatch + compact continuation
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
# Benchmark-integrity errors fail the gate. A missing script, rejected
# synthetic payload, or source/dependency mismatch is not a latency pass;
# treating a 14ms source failure as green previously hid real regressions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
  . "${SCRIPT_DIR}/common.sh"
else
  . "${HOME}/.claude/skills/autowork/scripts/common.sh"
fi

# --- Budget table ---

emit_budgets() {
  cat <<'EOF'
prompt-intent-router.sh|1500
dispatch-recovery-guard.sh|200
pretool-intent-guard.sh|300
quality-constitution-authority-guard.sh|300
pretool-timing.sh|200
posttool-timing.sh|200
stop-guard.sh|1000
stop-time-summary.sh|400
closeout-display.sh|600
closeout-preflight.sh|600
stop-dispatch.sh|1800
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

cold_budget_for_hook() {
  local hook="$1"
  local warm
  warm="$(budget_for_hook "${hook}")"
  local env_name="OMC_LATENCY_COLD_BUDGET_${hook//.sh/}"
  env_name="${env_name//-/_}"
  env_name="$(printf '%s' "${env_name}" | tr '[:lower:]' '[:upper:]')_MS"
  local override="${!env_name:-}"
  if [[ -n "${override}" ]] && [[ "${override}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${override}"
  else
    awk -v w="${warm}" 'BEGIN { printf "%d", int((w * 1.5) + 0.5) }'
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
    dispatch-recovery-guard.sh|pretool-intent-guard.sh|quality-constitution-authority-guard.sh)
      jq -nc \
        --arg session_id "${sid}" \
        --arg cwd "${PWD}" \
        --arg id "bench-${sid}" \
        '{session_id:$session_id, cwd:$cwd, tool_name:"Bash", tool_use_id:$id,
          tool_input:{command:"pytest -q",run_in_background:false}}'
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
    closeout-display.sh)
      jq -nc \
        --arg session_id "${sid}" \
        '{session_id:$session_id,hook_event_name:"MessageDisplay",
          message_id:"bench-message",index:0,final:true,
          delta:"I am continuing the implementation and checking the remaining evidence."}'
      ;;
    closeout-preflight.sh)
      jq -nc \
        --arg session_id "${sid}" \
        '{session_id:$session_id,hook_event_name:"PostToolBatch",
          tool_calls:[{tool_name:"Read",tool_input:{file_path:"README.md"},tool_response:"ok"}]}'
      ;;
    stop-dispatch.sh)
      jq -nc \
        --arg session_id "${sid}" \
        --arg cwd "${PWD}" \
        '{session_id:$session_id,cwd:$cwd,hook_event_name:"Stop",
          stop_hook_active:false,last_assistant_message:"Still working.",
          background_tasks:[],session_crons:[]}'
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
  local script_path=""
  # Benchmark the same artifact tree as this script. Preferring ~/.claude
  # made source-tree checks silently time a stale installed hook whenever the
  # developer had an older harness installed.
  if [[ -f "${SCRIPT_DIR}/${hook}" ]]; then
    script_path="${SCRIPT_DIR}/${hook}"
  elif [[ -f "${SCRIPT_DIR}/../../../quality-pack/scripts/${hook}" ]]; then
    script_path="${SCRIPT_DIR}/../../../quality-pack/scripts/${hook}"
  elif [[ -f "${HOME}/.claude/skills/autowork/scripts/${hook}" ]]; then
    script_path="${HOME}/.claude/skills/autowork/scripts/${hook}"
  else
    [[ "${stay_quiet}" -eq 1 ]] || printf 'check-latency-budgets: missing %s\n' "${hook}" >&2
    return 1
  fi

  local i start end measurements=()
  local sid payload created_ulw_sentinel=0 hook_failed=0
  local artifact_root="" bench_home="" hook_home="${HOME}"
  local -a hook_args=()
  artifact_root="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd -P || true)"
  if [[ -n "${artifact_root}" ]] \
      && [[ -d "${artifact_root}/skills" ]] \
      && [[ -d "${artifact_root}/quality-pack" ]]; then
    bench_home="$(mktemp -d "${TMPDIR:-/tmp}/omc-latency-home.XXXXXX" 2>/dev/null || true)"
    [[ -n "${bench_home}" ]] || return 1
    mkdir -p "${bench_home}/.claude/quality-pack/blindspots" "${STATE_ROOT}" || {
      rm -rf "${bench_home}"
      return 1
    }
    ln -s "${artifact_root}/skills" "${bench_home}/.claude/skills" || {
      rm -rf "${bench_home}"
      return 1
    }
    for i in scripts memory design-craft research-craft; do
      if [[ -e "${artifact_root}/quality-pack/${i}" ]]; then
        ln -s "${artifact_root}/quality-pack/${i}" \
          "${bench_home}/.claude/quality-pack/${i}" || {
          rm -rf "${bench_home}"
          return 1
        }
      fi
    done
    ln -s "${STATE_ROOT}" "${bench_home}/.claude/quality-pack/state" || {
      rm -rf "${bench_home}"
      return 1
    }
    hook_home="${bench_home}"
  fi
  if [[ "${hook}" == "dispatch-recovery-guard.sh" \
      || "${hook}" == "pretool-intent-guard.sh" \
      || "${hook}" == "closeout-display.sh" \
      || "${hook}" == "closeout-preflight.sh" \
      || "${hook}" == "stop-dispatch.sh" ]] \
      && [[ ! -f "${STATE_ROOT}/.ulw_active" ]]; then
    mkdir -p "${STATE_ROOT}"
    touch "${STATE_ROOT}/.ulw_active"
    created_ulw_sentinel=1
  fi
  for ((i = 1; i <= samples; i++)); do
    sid="$(bench_session_id "${i}")"
    if [[ "${hook}" == "pretool-intent-guard.sh" ]]; then
      mkdir -p "${STATE_ROOT}/${sid}"
      jq -nc '{workflow_mode:"ultrawork",task_intent:"execution",task_domain:"coding"}' \
        >"${STATE_ROOT}/${sid}/session_state.json"
    elif [[ "${hook}" == "closeout-display.sh" \
        || "${hook}" == "closeout-preflight.sh" \
        || "${hook}" == "stop-dispatch.sh" ]]; then
      mkdir -p "${STATE_ROOT}/${sid}"
      jq -nc --arg cwd "${PWD}" '{
        workflow_mode:"ultrawork",task_intent:"execution",task_domain:"coding",
        cwd:$cwd,current_objective:"Latency benchmark closeout",
        closeout_preflight_required:"1",closeout_material_activity:"1",
        review_cycle_id:"1",prompt_revision:"1"
      }' >"${STATE_ROOT}/${sid}/session_state.json"
    fi
    payload="$(emit_payload_for_hook "${hook}" "${sid}")"
    start="$(now_ms)"
    if [[ "${hook}" == "pretool-intent-guard.sh" ]]; then
      HOME="${hook_home}" STATE_ROOT="${STATE_ROOT}" OMC_AGENT_FIRST_GATE=off \
        bash "${script_path}" >/dev/null 2>&1 <<< "${payload}" || hook_failed=1
    elif [[ "${hook}" == "stop-dispatch.sh" || "${hook}" == "closeout-preflight.sh" ]]; then
      hook_args=()
      [[ "${hook}" == "closeout-preflight.sh" ]] && hook_args=(--posttool-batch)
      # Bash 3.2 treats an empty array expansion as an unbound variable under
      # `set -u`. The + form expands to nothing when stop-dispatch has no
      # positional arguments, while still forwarding --posttool-batch for
      # closeout-preflight.
      HOME="${hook_home}" STATE_ROOT="${STATE_ROOT}" \
        OMC_INFERRED_CONTRACT=off OMC_OBJECTIVE_CONTRACT_GATE=off \
        OMC_AGENT_FIRST_GATE=off OMC_NO_DEFER_MODE=off OMC_TIME_TRACKING=off \
        OMC_MODEL_DRIFT_CANARY=off OMC_STOP_FEEDBACK_MODE=legacy \
        bash "${script_path}" ${hook_args[@]+"${hook_args[@]}"} \
        >/dev/null 2>&1 <<< "${payload}" || hook_failed=1
    else
      HOME="${hook_home}" STATE_ROOT="${STATE_ROOT}" \
        bash "${script_path}" >/dev/null 2>&1 <<< "${payload}" || hook_failed=1
    fi
    end="$(now_ms)"
    measurements+=( $((end - start)) )
    [[ "${hook_failed}" -eq 0 ]] || break
  done

  # Cleanup synthetic state directories the bench created.
  rm -rf "${STATE_ROOT}"/omc-bench-$$-* 2>/dev/null || true
  if [[ "${created_ulw_sentinel}" -eq 1 ]]; then
    rm -f "${STATE_ROOT}/.ulw_active"
  fi
  [[ -z "${bench_home}" ]] || rm -rf "${bench_home}"
  [[ "${hook_failed}" -eq 0 ]] || return 1

  local first
  first="${measurements[0]:-0}"
  local stats
  if [[ "${#measurements[@]}" -gt 1 ]]; then
    # The first sample has its own cold-start ceiling. Excluding it from warm
    # median/p95 is required for the two-budget contract to mean what the
    # output says; including it made p95 equal FIRST for the default five
    # samples and rendered the larger cold budget ineffective.
    stats="$(printf '%d\n' "${measurements[@]:1}" | compute_stats)"
  else
    stats="$(printf '%d\n' "${measurements[@]}" | compute_stats)"
  fi
  printf '%s %s' "${first}" "${stats}"
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

  printf '%-32s %8s %8s %8s %8s %8s   %s\n' "HOOK" "FIRST" "MEDIAN" "P95" "BUDGET" "COLD" "STATUS"
  printf '%-32s %8s %8s %8s %8s %8s   %s\n' "----" "-----" "------" "---" "------" "----" "------"

  local breaches=0 missing=0 hook budget cold_budget first median p95 status
  while IFS='|' read -r hook _; do
    [[ -z "${hook}" ]] && continue
    if [[ -n "${only_hook}" ]] && [[ "${hook}" != "${only_hook}" ]]; then
      continue
    fi
    budget="$(budget_for_hook "${hook}")"
    cold_budget="$(cold_budget_for_hook "${hook}")"
    local stats
    stats="$(benchmark_hook "${hook}" "${samples}" 1 || echo "MISSING MISSING")"
    if [[ "${stats}" == "MISSING MISSING" ]]; then
      missing=$((missing + 1))
      printf '%-32s %8s %8s %8s %8s %8s   %s\n' "${hook}" "—" "—" "—" "${budget}ms" "${cold_budget}ms" "missing/error"
      continue
    fi
    first="$(printf '%s' "${stats}" | awk '{print $1}')"
    median="$(printf '%s' "${stats}" | awk '{print $2}')"
    p95="$(printf '%s' "${stats}" | awk '{print $3}')"
    if [[ "${p95}" -gt "${budget}" ]]; then
      breaches=$((breaches + 1))
      status="BREACH"
    elif [[ "${first}" -gt "${cold_budget}" ]]; then
      breaches=$((breaches + 1))
      status="COLD_BREACH"
    else
      status="ok"
    fi
    printf '%-32s %7sms %7sms %7sms %7sms %7sms   %s\n' "${hook}" "${first}" "${median}" "${p95}" "${budget}" "${cold_budget}" "${status}"
  done < <(emit_budgets)

  printf '\nSamples per hook: %d\n' "${samples}"
  if [[ "${missing}" -gt 0 ]]; then
    breaches=$((breaches + missing))
    printf '%d hook(s) missing or failed during benchmark\n' "${missing}"
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
  OMC_LATENCY_COLD_BUDGET_<HOOK>_MS=<ms>
  e.g., OMC_LATENCY_COLD_BUDGET_PROMPT_INTENT_ROUTER_MS=2250

Default samples: 5 (first + median + p95). P95 uses the warm budget;
first uses a cold budget (default 150% of warm).

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
