#!/usr/bin/env bash
# test-realwork-arms.sh — focused regression for evals/realwork/arms.sh.
#
# Mock-mode only: OMC_ARMS_CLAUDE_BIN points at a stub binary, so the whole
# pipeline (probe validation → arm building → sandboxed run → ground-truth
# checks → aggregation/claims report) is exercised with zero network and
# zero spend. The one real-artifact piece is the full-arm build, which runs
# the repo's actual install.sh into a sandbox TARGET_HOME — asserting the
# shipped install path produces the arm, not a hand-approximated copy.
#
# The load-bearing cases are T6/T7: they prove the no-defer probe's checks
# DISCRIMINATE — a simulated stop-short run (bugs fixed, deprecated flag
# left in place) scores tests_pass=true / flag_fully_removed=false, while
# a simulated completing run scores both true. Without that discrimination
# the probe could not measure the will-contract's effect.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARMS_SH="${REPO_ROOT}/evals/realwork/arms.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1" rc="$2"
  if [[ "${rc}" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

WORK="$(mktemp -d)"
export OMC_ARMS_ROOT="${WORK}/arms"
export OMC_ARMS_RUNS_ROOT="${WORK}/runs"
export MOCK_ENV_LOG="${WORK}/mock-env.log"
: > "${MOCK_ENV_LOG}"

cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# Stub claude binary: records the sandbox env it was invoked with, applies
# an optional behavior script to the workspace (cwd), and emits a canned
# result JSON in the CLI's --output-format json shape.
cat > "${WORK}/mock-claude" <<'MOCKEOF'
#!/usr/bin/env bash
{
  printf 'HOME=%s\n' "${HOME}"
  printf 'CONFIG=%s\n' "${CLAUDE_CONFIG_DIR:-}"
  printf 'CWD=%s\n' "$(pwd)"
  printf 'ARGS=%s\n' "$*"
} >> "${MOCK_ENV_LOG:?}"
if [[ -n "${MOCK_BEHAVIOR_SCRIPT:-}" ]]; then
  bash "${MOCK_BEHAVIOR_SCRIPT}"
fi
printf '{"type":"result","is_error":false,"total_cost_usd":0.0123,"num_turns":4,"duration_ms":1500,"session_id":"mock-run"}\n'
MOCKEOF
chmod +x "${WORK}/mock-claude"
export OMC_ARMS_CLAUDE_BIN="${WORK}/mock-claude"

# ----------------------------------------------------------------------
printf 'T1: probe validation\n'
out_t1="$(bash "${ARMS_SH}" validate)"
assert_contains "T1: three probes validate" "Validated 3 probe(s)" "${out_t1}"

# ----------------------------------------------------------------------
printf 'T2: bare arm build\n'
bash "${ARMS_SH}" build --probe no-defer-contract --arm bare 2>/dev/null
bare_root="${OMC_ARMS_ROOT}/no-defer-contract-bare"
assert_eq "T2: bare settings.json is empty object" "{}" "$(cat "${bare_root}/.claude/settings.json")"
if [[ -f "${bare_root}/.claude/CLAUDE.md" ]]; then
  assert_true "T2: bare arm has no CLAUDE.md" 1
else
  assert_true "T2: bare arm has no CLAUDE.md" 0
fi
assert_eq "T2: arm-meta base recorded" "bare" "$(jq -r '.base' "${bare_root}/arm-meta.json")"

# ----------------------------------------------------------------------
printf 'T3: full arm build (real install.sh into sandbox TARGET_HOME)\n'
bash "${ARMS_SH}" build --probe depth-scaffold --arm full 2>/dev/null
full_root="${OMC_ARMS_ROOT}/depth-scaffold-full"
if [[ -f "${full_root}/.claude/CLAUDE.md" ]]; then
  assert_true "T3: full arm has CLAUDE.md" 0
else
  assert_true "T3: full arm has CLAUDE.md" 1
fi
rc=0; jq -e '.hooks | type == "object"' "${full_root}/.claude/settings.json" >/dev/null 2>&1 || rc=$?
assert_true "T3: full arm settings.json carries hooks" "${rc}"
rc=0; grep -q 'quality-pack/memory/core.md' "${full_root}/.claude/CLAUDE.md" || rc=$?
assert_true "T3: full arm CLAUDE.md includes core.md" "${rc}"

# ----------------------------------------------------------------------
printf 'T4: trimmed arm build drops exactly the named includes\n'
bash "${ARMS_SH}" build --probe depth-scaffold --arm trimmed-scaffold 2>/dev/null
trim_root="${OMC_ARMS_ROOT}/depth-scaffold-trimmed-scaffold"
rc=0; grep -q 'intellectual-craft.md' "${trim_root}/.claude/CLAUDE.md" && rc=1
assert_true "T4: intellectual-craft include removed" "${rc}"
rc=0; grep -q 'model-robustness.md' "${trim_root}/.claude/CLAUDE.md" && rc=1
assert_true "T4: model-robustness include removed" "${rc}"
rc=0; grep -q 'quality-pack/memory/core.md' "${trim_root}/.claude/CLAUDE.md" || rc=$?
assert_true "T4: core.md include preserved" "${rc}"
assert_eq "T4: arm-meta records removed includes" \
  '["intellectual-craft.md","model-robustness.md"]' \
  "$(jq -c '.removed_includes' "${trim_root}/arm-meta.json")"

# ----------------------------------------------------------------------
printf 'T5: mock run in bare arm — sandbox isolation + metrics + failing checks\n'
unset MOCK_BEHAVIOR_SCRIPT || true
summary_t5="$(bash "${ARMS_SH}" run --probe no-defer-contract --arm bare --runs 1 2>/dev/null)"
rc=0; [[ -f "${summary_t5}" ]] || rc=1
assert_true "T5: summary.json produced" "${rc}"
assert_eq "T5: cost parsed from CLI json" "0.0123" "$(jq -r '.cost_usd' "${summary_t5}")"
assert_eq "T5: num_turns parsed" "4" "$(jq -r '.num_turns' "${summary_t5}")"
assert_eq "T5: untouched fixture fails its suite" "false" "$(jq -r '.checks.tests_pass' "${summary_t5}")"
assert_eq "T5: flag not removed on untouched fixture" "false" "$(jq -r '.checks.flag_fully_removed' "${summary_t5}")"
env_log="$(cat "${MOCK_ENV_LOG}")"
assert_contains "T5: HOME isolated to arm root" "HOME=${bare_root}" "${env_log}"
assert_contains "T5: CLAUDE_CONFIG_DIR isolated to arm root" "CONFIG=${bare_root}/.claude" "${env_log}"
assert_contains "T5: workspace cwd under runs root" "CWD=${OMC_ARMS_RUNS_ROOT}" "${env_log}"
assert_contains "T5: permissions skipped for sandboxed headless run" "--dangerously-skip-permissions" "${env_log}"
assert_contains "T5: probe prompt passed through" "legacy-mode" "${env_log}"

# ----------------------------------------------------------------------
printf 'T6: stop-short behavior — probe checks DISCRIMINATE (bugs fixed, flag left)\n'
cat > "${WORK}/behave-stop-short.sh" <<'BEHEOF'
#!/usr/bin/env bash
# Simulated early stop: fix both seeded bugs, leave the deprecated flag.
perl -pi -e 's/PARSED_FORMAT="\$1"/PARSED_FORMAT="\$2"/' lib/parse.sh
perl -pi -e 's/\(%s\)/[%s]/' lib/render.sh
BEHEOF
export MOCK_BEHAVIOR_SCRIPT="${WORK}/behave-stop-short.sh"
summary_t6="$(bash "${ARMS_SH}" run --probe no-defer-contract --arm bare --runs 1 2>/dev/null)"
assert_eq "T6: suite green after bug fixes" "true" "$(jq -r '.checks.tests_pass' "${summary_t6}")"
assert_eq "T6: format bug fixed" "true" "$(jq -r '.checks.format_bug_fixed' "${summary_t6}")"
assert_eq "T6: render bug fixed" "true" "$(jq -r '.checks.render_bug_fixed' "${summary_t6}")"
assert_eq "T6: flag removal still incomplete (stop-short detected)" "false" "$(jq -r '.checks.flag_fully_removed' "${summary_t6}")"

# ----------------------------------------------------------------------
printf 'T7: fix-all behavior — completing run scores every check true\n'
cat > "${WORK}/behave-fix-all.sh" <<'BEHEOF'
#!/usr/bin/env bash
# Simulated completing run: fix both bugs AND remove the deprecated flag
# across code, CLI help, docs, and tests.
cat > lib/parse.sh <<'PEOF'
#!/usr/bin/env bash
# parse_args — fills PARSED_* globals from CLI args.

parse_args() {
  PARSED_FORMAT="plain"
  PARSED_INPUT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        PARSED_FORMAT="$2"
        shift 2
        ;;
      *)
        PARSED_INPUT="$1"
        shift
        ;;
    esac
  done
}
PEOF
cat > lib/render.sh <<'REOF'
#!/usr/bin/env bash
# render_line — renders one log line in the requested format.

render_line() {
  local format="$1" line="$2"
  case "${format}" in
    plain) printf '%s\n' "${line}" ;;
    boxed) printf '[%s]\n' "${line}" ;;
    *)     printf '%s\n' "${line}" ;;
  esac
}
REOF
perl -ni -e 'print unless /legacy/i' bin/logship docs/usage.md
rm -f tests/test-legacy.sh
BEHEOF
export MOCK_BEHAVIOR_SCRIPT="${WORK}/behave-fix-all.sh"
summary_t7="$(bash "${ARMS_SH}" run --probe no-defer-contract --arm bare --runs 1 2>/dev/null)"
assert_eq "T7: suite green" "true" "$(jq -r '.checks.tests_pass' "${summary_t7}")"
assert_eq "T7: flag fully removed" "true" "$(jq -r '.checks.flag_fully_removed' "${summary_t7}")"
assert_eq "T7: format bug fixed" "true" "$(jq -r '.checks.format_bug_fixed' "${summary_t7}")"
assert_eq "T7: render bug fixed" "true" "$(jq -r '.checks.render_bug_fixed' "${summary_t7}")"
rc=0; [[ "$(jq -r '.changed_files' "${summary_t7}")" -ge 4 ]] || rc=1
assert_true "T7: workspace diff recorded (>=4 changed files)" "${rc}"
unset MOCK_BEHAVIOR_SCRIPT || true

# ----------------------------------------------------------------------
printf 'T8: report aggregates the three bare runs with correct rates\n'
report_t8="$(bash "${ARMS_SH}" report --probe no-defer-contract 2>/dev/null)"
rc=0; jq -e '.[0].arms | length == 1' >/dev/null 2>&1 <<<"${report_t8}" || rc=$?
assert_true "T8: one arm aggregated" "${rc}"
rc=0; jq -e '.[0].arms[0].runs == 3' >/dev/null 2>&1 <<<"${report_t8}" || rc=$?
assert_true "T8: three runs counted" "${rc}"
rc=0; jq -e '(.[0].arms[0].check_rates.flag_fully_removed * 3 | round) == 1' >/dev/null 2>&1 <<<"${report_t8}" || rc=$?
assert_true "T8: flag-removal rate is 1/3" "${rc}"
rc=0; jq -e '(.[0].arms[0].check_rates.tests_pass * 3 | round) == 2' >/dev/null 2>&1 <<<"${report_t8}" || rc=$?
assert_true "T8: tests-pass rate is 2/3" "${rc}"
rc=0; jq -e '.[0].arms[0].median_cost_usd == 0.0123' >/dev/null 2>&1 <<<"${report_t8}" || rc=$?
assert_true "T8: median cost carried" "${rc}"

# ----------------------------------------------------------------------
printf 'T9: claims mode emits a ledger-ready row\n'
claims_t9="$(bash "${ARMS_SH}" report --probe no-defer-contract --claims 2>/dev/null)"
assert_contains "T9: claims row present" '| no-defer-contract |' "${claims_t9}"

# ----------------------------------------------------------------------
printf 'T10: doctor runs clean in mock mode\n'
rc=0; doctor_out="$(bash "${ARMS_SH}" doctor 2>&1)" || rc=$?
assert_true "T10: doctor exits 0" "${rc}"
assert_contains "T10: doctor counts probes" "probes: 3" "${doctor_out}"
assert_contains "T10: doctor reports mock override" "mock override" "${doctor_out}"

# ----------------------------------------------------------------------
printf '\n=== realwork-arms tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
