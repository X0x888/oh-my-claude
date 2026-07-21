#!/usr/bin/env bash
#
# evals/realwork/arms.sh — counterfactual arm runner for the realwork evals.
#
# v1.48 W1: the scoring layer (run.sh) could only answer "did a ULW session
# hit its own targets?" — never "did ULW *beat* no-ULW?". This script adds
# the missing dimension: run the SAME task through real headless `claude -p`
# sessions under different harness configurations ("arms") and compare
# outcomes measured on WORKSPACE GROUND TRUTH (tests pass, deferred work
# remaining, artifact exists) — never on harness telemetry, which a bare
# arm does not produce. This is the subtraction criterion the v1 post-mortem
# named as missing ("addition was cheap; subtraction was impossible"):
# every doctrine/gate mechanism can now carry a measured receipt, recorded
# in claims.md.
#
# Arms:
#   full            — the complete harness, installed fresh from this repo
#                     into a sandbox HOME via install.sh (TARGET_HOME=...)
#   trimmed-*       — full, minus the @-include doctrine files a probe
#                     names in its arm spec (remove_includes)
#   bare            — no harness at all: empty settings.json, no CLAUDE.md
#
# Isolation: each arm is a self-contained root directory. At run time BOTH
# HOME and CLAUDE_CONFIG_DIR point into the arm root, so hook commands that
# reference $HOME/.claude/... resolve inside the sandbox and never touch the
# live install's state or telemetry ledgers.
#
# Auth: sandboxed HOMEs never inherit interactive OAuth (verified on
# Claude Code 2.1.201 — a fresh config dir reports "Not logged in" even
# with .claude.json seeded). Headless arms authenticate via environment:
#   CLAUDE_CODE_OAUTH_TOKEN   (one-time: `claude setup-token`)
#   ANTHROPIC_API_KEY         (direct API billing)
# `arms.sh doctor` reports which is available.
#
# Mock mode: set OMC_ARMS_CLAUDE_BIN to a stub binary for an explicitly scoped
# zero-spend exercise. The retained eval suite covers schema/scoring, not arms.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROBES_DIR="${SCRIPT_DIR}/probes"
ARMS_ROOT="${OMC_ARMS_ROOT:-${SCRIPT_DIR}/.arms}"
RUNS_ROOT="${OMC_ARMS_RUNS_ROOT:-${SCRIPT_DIR}/runs}"
CLAUDE_BIN="${OMC_ARMS_CLAUDE_BIN:-claude}"

usage() {
  cat <<'EOF'
realwork counterfactual arm runner

Usage:
  bash evals/realwork/arms.sh doctor
  bash evals/realwork/arms.sh list-probes
  bash evals/realwork/arms.sh validate
  bash evals/realwork/arms.sh build --probe <id> [--arm <name>]
  bash evals/realwork/arms.sh run --probe <id> --arm <name> [--runs N] [--model M] [--timeout SECS]
  bash evals/realwork/arms.sh campaign --probe <id> [--runs N] [--model M] [--timeout SECS]
  bash evals/realwork/arms.sh report [--probe <id>] [--claims]

Concepts:
  probe    probes/<id>.json — a question about one harness mechanism:
           task prompt + fixture + arms + ground-truth checks + metrics.
  arm      a sandboxed harness configuration (full / trimmed-* / bare).
  run      one headless `claude -p` execution of the probe's prompt in a
           fresh fixture workspace under one arm, followed by the probe's
           checks executed against the workspace.
  report   aggregates runs/<...>/summary.json into per-arm outcome rates
           and cost medians; --claims emits a claims.md-ready row.

Auth for real runs (sandboxes never inherit interactive login):
  claude setup-token          # one-time, then:
  export CLAUDE_CODE_OAUTH_TOKEN=...
  # or: export ANTHROPIC_API_KEY=...
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { printf 'arms.sh: %s\n' "$*" >&2; exit 2; }

require_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

# ---------------------------------------------------------------------------
# Probe resolution + validation
# ---------------------------------------------------------------------------

probe_files() {
  find "${PROBES_DIR}" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort
}

resolve_probe() {
  local ref="$1"
  if [[ -f "${ref}" ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi
  local candidate="${PROBES_DIR}/${ref}.json"
  [[ -f "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  return 1
}

validate_probe() {
  local file="$1"
  jq -e '
    (.id | type == "string" and length > 0) and
    (.question | type == "string" and length > 0) and
    (.prompt | type == "string" and length > 0) and
    (.fixture | type == "string" and length > 0) and
    (.arms | type == "array" and length >= 2 and all(.[];
      (.name | type == "string" and length > 0) and
      ((.base == "full") or (.base == "bare")) and
      ((.remove_includes // []) | type == "array")
    )) and
    (.checks | type == "array" and all(.[];
      (.id | type == "string" and length > 0) and
      (.cmd | type == "string" and length > 0)
    )) and
    (.runs_default | type == "number")
  ' "${file}" >/dev/null
}

cmd_list_probes() {
  require_jq
  local file
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    jq -r '"\(.id)\t\(.arms | map(.name) | join(","))\t\(.question)"' "${file}"
  done < <(probe_files)
}

cmd_validate() {
  require_jq
  local count=0 file
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    validate_probe "${file}" || die "invalid probe: ${file}"
    local fixture
    fixture="$(jq -r '.fixture' "${file}")"
    [[ -d "${SCRIPT_DIR}/${fixture}" ]] || die "probe fixture missing: ${fixture} (${file})"
    count=$((count + 1))
  done < <(probe_files)
  printf 'Validated %d probe(s)\n' "${count}"
}

# ---------------------------------------------------------------------------
# Arm building
# ---------------------------------------------------------------------------

arm_root_for() {
  # Arm roots are namespaced by probe so two probes' trims never collide.
  local probe_id="$1" arm_name="$2"
  printf '%s/%s-%s\n' "${ARMS_ROOT}" "${probe_id}" "${arm_name}"
}

build_arm() {
  local probe_file="$1" arm_name="$2"
  local probe_id arm_spec base
  probe_id="$(jq -r '.id' "${probe_file}")"
  arm_spec="$(jq -c --arg n "${arm_name}" '.arms[] | select(.name == $n)' "${probe_file}")"
  [[ -n "${arm_spec}" ]] || die "arm '${arm_name}' not defined in probe '${probe_id}'"
  base="$(jq -r '.base' <<<"${arm_spec}")"

  local root
  root="$(arm_root_for "${probe_id}" "${arm_name}")"
  rm -rf "${root}"
  mkdir -p "${root}"

  case "${base}" in
    bare)
      mkdir -p "${root}/.claude"
      printf '{}\n' > "${root}/.claude/settings.json"
      ;;
    full)
      # Fresh install of THIS repo's bundle into the sandbox HOME. This is
      # the same path a real user's install takes (settings patch merge,
      # skills, agents, quality-pack), so the full arm measures the shipped
      # harness — not a hand-approximated copy of it.
      log "installing harness into arm sandbox (${arm_name})..."
      if ! TARGET_HOME="${root}" bash "${REPO_ROOT}/install.sh" \
          > "${root}/install.log" 2>&1; then
        die "install.sh failed for arm '${arm_name}' — see ${root}/install.log"
      fi
      # Trim: drop the @-include lines a probe names. File-level trims are
      # the honest v1 granularity — a probe that wants finer cuts should
      # ship a patched memory file instead of a sed program.
      local inc tmp
      while IFS= read -r inc; do
        [[ -n "${inc}" ]] || continue
        [[ -f "${root}/.claude/CLAUDE.md" ]] || break
        tmp="${root}/.claude/CLAUDE.md.tmp"
        grep -vF "quality-pack/memory/${inc}" "${root}/.claude/CLAUDE.md" > "${tmp}" \
          || true
        mv "${tmp}" "${root}/.claude/CLAUDE.md"
      done < <(jq -r '(.remove_includes // [])[]' <<<"${arm_spec}")
      ;;
    *)
      die "unknown arm base: ${base}"
      ;;
  esac

  jq -nc \
    --arg probe "${probe_id}" \
    --arg name "${arm_name}" \
    --arg base "${base}" \
    --argjson removed "$(jq -c '(.remove_includes // [])' <<<"${arm_spec}")" \
    '{probe: $probe, name: $name, base: $base, removed_includes: $removed}' \
    > "${root}/arm-meta.json"
  log "arm ready: ${root}"
}

cmd_build() {
  require_jq
  local probe_ref="" arm_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --probe) probe_ref="$2"; shift 2 ;;
      --arm)   arm_name="$2";  shift 2 ;;
      *) die "unknown build arg: $1" ;;
    esac
  done
  [[ -n "${probe_ref}" ]] || die "build requires --probe"
  local probe_file
  probe_file="$(resolve_probe "${probe_ref}")" || die "unknown probe: ${probe_ref}"
  validate_probe "${probe_file}" || die "invalid probe: ${probe_file}"

  if [[ -n "${arm_name}" ]]; then
    build_arm "${probe_file}" "${arm_name}"
  else
    local name
    while IFS= read -r name; do
      build_arm "${probe_file}" "${name}"
    done < <(jq -r '.arms[].name' "${probe_file}")
  fi
}

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

# Portable timeout (macOS ships no coreutils `timeout`). Returns the
# command's exit code (143 after a TERM timeout-kill, 137 after the KILL
# escalation). The watcher escalates TERM → 5s grace → KILL and also
# signals the child's direct children, so a signal-trapping `claude` (or
# its subprocess tree's first tier) cannot outlive the promised cap.
# Deeper grandchildren may survive a stubborn tree — documented limit of
# the no-setsid portable approach. The killer's own sleep children are
# reaped explicitly so completed calls never orphan long-lived sleeps.
# Kept in deliberate lockstep with the copy in bundle/dot-claude/bin/omc.
_run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  (
    sleep "${secs}"
    kill -TERM "${pid}" 2>/dev/null
    pkill -TERM -P "${pid}" 2>/dev/null
    sleep 5
    kill -KILL "${pid}" 2>/dev/null
    pkill -KILL -P "${pid}" 2>/dev/null
  ) &
  local killer=$!
  local rc=0
  wait "${pid}" 2>/dev/null || rc=$?
  pkill -P "${killer}" 2>/dev/null || true
  kill -TERM "${killer}" 2>/dev/null || true
  wait "${killer}" 2>/dev/null || true
  return "${rc}"
}

run_one() {
  local probe_file="$1" arm_name="$2" run_index="$3" model="$4" timeout_secs="$5"
  local probe_id prompt fixture
  probe_id="$(jq -r '.id' "${probe_file}")"
  prompt="$(jq -r '.prompt' "${probe_file}")"
  fixture="$(jq -r '.fixture' "${probe_file}")"

  local arm_root
  arm_root="$(arm_root_for "${probe_id}" "${arm_name}")"
  [[ -d "${arm_root}/.claude" ]] || build_arm "${probe_file}" "${arm_name}"

  local stamp run_id run_dir ws
  stamp="$(date +%Y%m%d-%H%M%S)"
  # PID suffix: separate invocations in the same second (e.g. a test
  # driving single runs back-to-back) must never collide on run_id.
  run_id="${stamp}-${probe_id}-${arm_name}-r${run_index}-p$$"
  run_dir="${RUNS_ROOT}/${run_id}"
  ws="${run_dir}/workspace"
  mkdir -p "${ws}"

  cp -R "${SCRIPT_DIR}/${fixture}/." "${ws}/"
  ( cd "${ws}" \
    && git init -q \
    && git add -A \
    && git -c user.email=arms@omc -c user.name=arms commit -qm baseline )

  local started ended rc=0
  started="$(date +%s)"
  # HOME + CLAUDE_CONFIG_DIR both point into the arm root: hook commands
  # written as $HOME/.claude/... resolve inside the sandbox; state and
  # telemetry land there too, never in the live install. Auth comes from
  # the environment (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY), which
  # survives the HOME override.
  ( cd "${ws}" \
    && HOME="${arm_root}" CLAUDE_CONFIG_DIR="${arm_root}/.claude" \
       _run_with_timeout "${timeout_secs}" \
       "${CLAUDE_BIN}" -p "${prompt}" \
         --output-format json \
         --dangerously-skip-permissions \
         ${model:+--model "${model}"} \
         > "${run_dir}/cli.json" 2> "${run_dir}/cli.err" ) || rc=$?
  ended="$(date +%s)"

  local cost_usd num_turns duration_ms is_error session_id
  if [[ -s "${run_dir}/cli.json" ]]; then
    cost_usd="$(jq -r '.total_cost_usd // .cost_usd // 0' "${run_dir}/cli.json" 2>/dev/null || echo 0)"
    num_turns="$(jq -r '.num_turns // 0' "${run_dir}/cli.json" 2>/dev/null || echo 0)"
    duration_ms="$(jq -r '.duration_ms // 0' "${run_dir}/cli.json" 2>/dev/null || echo 0)"
    is_error="$(jq -r '.is_error // false' "${run_dir}/cli.json" 2>/dev/null || echo true)"
    session_id="$(jq -r '.session_id // ""' "${run_dir}/cli.json" 2>/dev/null || echo "")"
  else
    cost_usd=0; num_turns=0; duration_ms=0; is_error=true; session_id=""
  fi

  # Ground-truth checks: executed with cwd = workspace, AFTER the run.
  # Check commands live in the probe JSON (invisible to the model), so a
  # probe can discriminate outcomes the fixture's own tests do not cover.
  local checks_json="{}"
  local check_id check_cmd check_rc
  while IFS=$'\t' read -r check_id check_cmd; do
    [[ -n "${check_id}" ]] || continue
    check_rc=0
    ( cd "${ws}" && bash -c "${check_cmd}" ) >/dev/null 2>&1 || check_rc=$?
    checks_json="$(jq -c --arg id "${check_id}" \
      --argjson ok "$([[ "${check_rc}" -eq 0 ]] && echo true || echo false)" \
      '. + {($id): $ok}' <<<"${checks_json}")"
  done < <(jq -r '.checks[] | [.id, .cmd] | @tsv' "${probe_file}")

  local changed_files
  # status --porcelain (not diff --name-only): a run that completes by
  # ADDING files must not report 0 changed.
  changed_files="$(cd "${ws}" && git status --porcelain 2>/dev/null | grep -c . || true)"
  [[ "${changed_files}" =~ ^[0-9]+$ ]] || changed_files=0

  jq -nc \
    --arg probe "${probe_id}" \
    --arg arm "${arm_name}" \
    --arg run_id "${run_id}" \
    --arg model "${model:-default}" \
    --arg session_id "${session_id}" \
    --argjson run_index "${run_index}" \
    --argjson exit_code "${rc}" \
    --argjson cost_usd "${cost_usd:-0}" \
    --argjson num_turns "${num_turns:-0}" \
    --argjson duration_ms "${duration_ms:-0}" \
    --argjson wall_seconds "$(( ended - started ))" \
    --argjson is_error "${is_error:-true}" \
    --argjson changed_files "${changed_files}" \
    --argjson checks "${checks_json}" \
    '{
      probe: $probe, arm: $arm, run_id: $run_id, run_index: $run_index,
      model: $model, session_id: $session_id,
      exit_code: $exit_code, is_error: $is_error,
      cost_usd: $cost_usd, num_turns: $num_turns,
      duration_ms: $duration_ms, wall_seconds: $wall_seconds,
      changed_files: $changed_files,
      checks: $checks
    }' > "${run_dir}/summary.json"

  log "run ${run_id}: exit=${rc} cost=\$${cost_usd} checks=$(jq -c '.checks' "${run_dir}/summary.json")"
  printf '%s\n' "${run_dir}/summary.json"
}

cmd_run() {
  require_jq
  local probe_ref="" arm_name="" runs="" model="" timeout_secs="1800"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --probe)   probe_ref="$2";    shift 2 ;;
      --arm)     arm_name="$2";     shift 2 ;;
      --runs)    runs="$2";         shift 2 ;;
      --model)   model="$2";        shift 2 ;;
      --timeout) timeout_secs="$2"; shift 2 ;;
      *) die "unknown run arg: $1" ;;
    esac
  done
  [[ -n "${probe_ref}" && -n "${arm_name}" ]] || die "run requires --probe and --arm"
  case "${runs:-}" in ''|*[!0-9]*) [[ -z "${runs}" ]] || die "--runs must be an integer" ;; esac
  case "${timeout_secs}" in ''|*[!0-9]*) die "--timeout must be an integer (seconds)" ;; esac

  local probe_file
  probe_file="$(resolve_probe "${probe_ref}")" || die "unknown probe: ${probe_ref}"
  validate_probe "${probe_file}" || die "invalid probe: ${probe_file}"
  [[ -n "${runs}" ]] || runs="$(jq -r '.runs_default' "${probe_file}")"

  local i
  for (( i = 1; i <= runs; i++ )); do
    run_one "${probe_file}" "${arm_name}" "${i}" "${model}" "${timeout_secs}"
  done
}

cmd_campaign() {
  require_jq
  local probe_ref="" runs="" model="" timeout_secs="1800"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --probe)   probe_ref="$2";    shift 2 ;;
      --runs)    runs="$2";         shift 2 ;;
      --model)   model="$2";        shift 2 ;;
      --timeout) timeout_secs="$2"; shift 2 ;;
      *) die "unknown campaign arg: $1" ;;
    esac
  done
  [[ -n "${probe_ref}" ]] || die "campaign requires --probe"
  local probe_file
  probe_file="$(resolve_probe "${probe_ref}")" || die "unknown probe: ${probe_ref}"

  local arm
  while IFS= read -r arm; do
    log "=== campaign: probe=$(jq -r '.id' "${probe_file}") arm=${arm} ==="
    cmd_run --probe "${probe_ref}" --arm "${arm}" \
      ${runs:+--runs "${runs}"} ${model:+--model "${model}"} --timeout "${timeout_secs}"
  done < <(jq -r '.arms[].name' "${probe_file}")
  cmd_report --probe "$(jq -r '.id' "${probe_file}")"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

cmd_report() {
  require_jq
  local probe_filter="" claims=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --probe)  probe_filter="$2"; shift 2 ;;
      --claims) claims=1; shift ;;
      *) die "unknown report arg: $1" ;;
    esac
  done

  local summaries
  summaries="$(find "${RUNS_ROOT}" -mindepth 2 -maxdepth 2 -name 'summary.json' 2>/dev/null | LC_ALL=C sort)"
  [[ -n "${summaries}" ]] || die "no run summaries under ${RUNS_ROOT} — run a probe first"

  # NUL-safe concatenation: the repo path contains spaces, so summary paths
  # must never be word-split into jq argv.
  find "${RUNS_ROOT}" -mindepth 2 -maxdepth 2 -name 'summary.json' -print0 2>/dev/null \
    | xargs -0 cat \
    | jq -s \
    --arg probe "${probe_filter}" \
    --argjson claims "${claims}" '
    def median: sort | if length == 0 then 0
      elif (length % 2) == 1 then .[(length - 1) / 2]
      else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    [ .[] | select(($probe == "") or (.probe == $probe)) ]
    | group_by(.probe)
    | map({
        probe: .[0].probe,
        arms: (group_by(.arm) | map({
          arm: .[0].arm,
          runs: length,
          errors: ([.[] | select(.is_error == true or .exit_code != 0)] | length),
          check_rates: (
            (map(.checks | to_entries) | add // [])
            | group_by(.key)
            | map({key: .[0].key,
                   value: (([.[] | select(.value == true)] | length) / length)})
            | from_entries
          ),
          median_cost_usd: ([.[] | .cost_usd] | median),
          median_turns: ([.[] | .num_turns] | median),
          median_wall_seconds: ([.[] | .wall_seconds] | median)
        }))
      })
    | if $claims == 1 then
        map(
          "| " + .probe + " | " +
          (.arms | map(.arm + ": " +
            (.check_rates | to_entries | map(.key + "=" +
              ((.value * 100) | floor | tostring) + "%") | join(" ")) +
            " ($" + (.median_cost_usd | tostring) + ", " +
            (.median_turns | tostring) + " turns)") | join(" vs ")) +
          " | " + (.arms | map(.runs) | add | tostring) + " runs |"
        ) | .[]
      else . end
  '
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------

cmd_doctor() {
  local ok=1
  if command -v jq >/dev/null 2>&1; then
    log "ok    jq: $(jq --version 2>/dev/null)"
  else
    log "FAIL  jq: not found"; ok=0
  fi
  if [[ -n "${OMC_ARMS_CLAUDE_BIN:-}" ]]; then
    log "ok    claude: mock override (${OMC_ARMS_CLAUDE_BIN})"
  elif command -v claude >/dev/null 2>&1; then
    log "ok    claude: $(claude --version 2>/dev/null | head -1)"
  else
    log "FAIL  claude: not found on PATH"; ok=0
  fi
  [[ -f "${REPO_ROOT}/install.sh" ]] \
    && log "ok    install.sh: ${REPO_ROOT}/install.sh" \
    || { log "FAIL  install.sh: not found (full arms cannot build)"; ok=0; }
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    log "ok    auth: CLAUDE_CODE_OAUTH_TOKEN present"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    log "ok    auth: ANTHROPIC_API_KEY present"
  else
    log "warn  auth: no headless credential in env."
    log "      Sandboxed arms never inherit interactive login. One-time setup:"
    log "        claude setup-token       # then export CLAUDE_CODE_OAUTH_TOKEN=..."
    log "      (or export ANTHROPIC_API_KEY). Mock runs need neither."
  fi
  local probe_count
  probe_count="$(probe_files | grep -c . || true)"
  log "ok    probes: ${probe_count} defined"
  [[ "${ok}" -eq 1 ]] || return 1
}

# ---------------------------------------------------------------------------

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    doctor)       cmd_doctor ;;
    list-probes)  cmd_list_probes ;;
    validate)     cmd_validate ;;
    build)        cmd_build "$@" ;;
    run)          cmd_run "$@" ;;
    campaign)     cmd_campaign "$@" ;;
    report)       cmd_report "$@" ;;
    ""|-h|--help) usage ;;
    *)
      printf 'unknown command: %s\n' "${cmd}" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
