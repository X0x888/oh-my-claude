#!/usr/bin/env bash
# v1.40.x Wave 1 reliability hardening regression tests.
#
# Covers F-001 (derive_verification_contract_required guarded by
# _omc_load_classifier), F-002 (_omc_read_hook_stdin helper bounded by
# OMC_HOOK_STDIN_TIMEOUT_S; hooks source common.sh BEFORE calling the
# helper), F-003 (stop-guard exemplifying_scope jq parse failure routes
# to log_anomaly), F-004 (STATE_ROOT + ~/.claude/quality-pack get
# chmod 700 in ensure_session_dir and _write_hook_log), F-006 (Reviewer
# ROI table renders regardless of window agent_breakdown emptiness).

# Note: deliberately not using `set -e` — each assert handles its own
# failure path. set -u stays on to catch typos in fixture variables.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
STOP_GUARD="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"
STATE_IO="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/state-io.sh"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
export STATE_ROOT="${TEST_TMP}/quality-pack/state"
mkdir -p "${STATE_ROOT}"

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

assert() {
  local description="$1"
  local actual="$2"
  local expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    printf '  PASS  %s\n' "${description}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' \
      "${description}" "${expected}" "${actual}"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  PASS  %s\n' "${description}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n         expected to contain: %s\n' \
      "${description}" "${needle}"
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
# F-001: derive_verification_contract_required calls _omc_load_classifier.
# Sanity-check by sourcing common.sh and confirming the function body
# contains the loader call (static check — runtime test would need to
# unset is_ui_request and trigger reload, which is too fragile here).
printf '\n## F-001 — derive_verification_contract_required lazy-load guard\n'
if grep -A 6 '^derive_verification_contract_required()' "${COMMON_SH}" \
  | grep -q '_omc_load_classifier'; then
  printf '  PASS  derive_verification_contract_required guards is_ui_request\n'
  pass=$((pass + 1))
else
  printf '  FAIL  no _omc_load_classifier call inside derive_verification_contract_required\n'
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
# F-002: _omc_read_hook_stdin helper is defined and bounded by timeout.
printf '\n## F-002 — _omc_read_hook_stdin helper bounded read\n'
if grep -q '^_omc_read_hook_stdin()' "${COMMON_SH}"; then
  printf '  PASS  _omc_read_hook_stdin defined in common.sh\n'
  pass=$((pass + 1))
else
  printf '  FAIL  _omc_read_hook_stdin not defined in common.sh\n'
  fail=$((fail + 1))
fi

if grep -A 6 '^_omc_read_hook_stdin()' "${COMMON_SH}" \
  | grep -q 'OMC_HOOK_STDIN_TIMEOUT_S'; then
  printf '  PASS  helper honors OMC_HOOK_STDIN_TIMEOUT_S\n'
  pass=$((pass + 1))
else
  printf '  FAIL  helper does not reference OMC_HOOK_STDIN_TIMEOUT_S\n'
  fail=$((fail + 1))
fi

# Helper must exit cleanly when stdin is closed and timeout fires.
helper_output="$(bash -c "
  set -uo pipefail
  STATE_ROOT='${STATE_ROOT}' \
    OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
    OMC_HOOK_STDIN_TIMEOUT_S=1 \
    SESSION_ID='test-helper-stdin' \
    source '${COMMON_SH}' </dev/null
  _omc_read_hook_stdin </dev/null
")"
assert "helper returns empty on closed stdin" "${helper_output}" ""

# Helper must pass through stdin payload unchanged when small + immediate.
helper_payload="$(bash -c "
  set -uo pipefail
  STATE_ROOT='${STATE_ROOT}' \
    OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
    SESSION_ID='test-helper-passthrough' \
    source '${COMMON_SH}' </dev/null
  printf 'hello-world' | _omc_read_hook_stdin
")"
assert "helper passes small payload through" "${helper_payload}" "hello-world"

# Helper's small-payload path must not leak job-control 'Terminated'
# stderr noise (watchdog kill should be disowned).
helper_stderr="$(bash -c "
  set -uo pipefail
  STATE_ROOT='${STATE_ROOT}' \
    OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
    SESSION_ID='test-helper-stderr-clean' \
    source '${COMMON_SH}' </dev/null
  printf 'small' | _omc_read_hook_stdin >/dev/null
" 2>&1 >/dev/null)"
assert "helper emits no stderr noise on small payload" "${helper_stderr}" ""

# Helper must FIRE timeout when stdin hangs. Use a fifo with a writer that
# holds it open but never writes; the helper should return within
# OMC_HOOK_STDIN_TIMEOUT_S + a small buffer (~1s), not block forever.
# This is the actual F-002 failure mode (Claude Code host fails to close
# stdin); pre-fix hooks would have hung indefinitely.
hang_fifo="${TEST_TMP}/hang.fifo"
mkfifo "${hang_fifo}"
# Background writer holds the fifo's write end open but never writes.
# Detached: parent doesn't wait for it.
( exec 9>"${hang_fifo}"; sleep 30 ) &
hang_writer_pid=$!
sleep 0.2  # let writer open the fifo

start_ts="$(date +%s)"
hang_result="$(bash -c "
  set -uo pipefail
  export STATE_ROOT='${STATE_ROOT}'
  export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
  export OMC_HOOK_STDIN_TIMEOUT_S=1
  export SESSION_ID='test-helper-timeout'
  source '${COMMON_SH}' </dev/null
  _omc_read_hook_stdin <'${hang_fifo}'
" 2>/dev/null)"
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))
kill "${hang_writer_pid}" 2>/dev/null || true

# Allow up to 2s for OMC_HOOK_STDIN_TIMEOUT_S=1 + ~1s scheduling slop.
if [[ "${elapsed}" -le 2 ]]; then
  printf '  PASS  helper fires timeout on hung stdin (~%ds elapsed, <=2s)\n' "${elapsed}"
  pass=$((pass + 1))
else
  printf '  FAIL  helper did NOT fire timeout (elapsed=%ds, expected <=2s)\n' "${elapsed}"
  fail=$((fail + 1))
fi
assert "helper returns empty on timeout" "${hang_result}" ""

# All hot-path hooks must source common.sh BEFORE invoking the helper
# (regression net: the v1.40.x sweep had a bug where this order was
# inverted on the first attempt, silently emptying HOOK_JSON).
printf '\n## F-002 — hooks invoke helper AFTER sourcing common.sh\n'
hook_files=(
  "bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
  "bundle/dot-claude/quality-pack/scripts/pre-compact-snapshot.sh"
  "bundle/dot-claude/quality-pack/scripts/stop-failure-handler.sh"
  "bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh"
  "bundle/dot-claude/skills/autowork/scripts/posttool-timing.sh"
  "bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"
)
for hook in "${hook_files[@]}"; do
  full="${REPO_ROOT}/${hook}"
  if [[ ! -f "${full}" ]]; then
    printf '  FAIL  %s does not exist\n' "${hook}"
    fail=$((fail + 1))
    continue
  fi
  # Find line number of source line and helper call; source must come first.
  src_line="$(awk '/(\.|source) ".*common\.sh"/{print NR; exit}' "${full}")"
  helper_line="$(awk '/HOOK_JSON="\$\(_omc_read_hook_stdin\)"/{print NR; exit}' "${full}")"
  if [[ -z "${src_line}" || -z "${helper_line}" ]]; then
    printf '  SKIP  %s — pattern not present\n' "${hook}"
    continue
  fi
  if (( src_line < helper_line )); then
    printf '  PASS  %s sources common.sh before helper call (lines %s < %s)\n' \
      "${hook}" "${src_line}" "${helper_line}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s calls helper before sourcing common.sh (lines %s vs %s)\n' \
      "${hook}" "${helper_line}" "${src_line}"
    fail=$((fail + 1))
  fi
done

# No hook should still use the bare HOOK_JSON="$(cat)" pattern in
# executable code. Comments referencing the legacy pattern are allowed
# (the helper docstring explains what it replaced). awk skips lines
# beginning with '#' to avoid matching the docstring.
remaining="$(find "${REPO_ROOT}/bundle" -name '*.sh' -type f \
  -exec awk 'BEGIN{f=""} FILENAME!=f{f=FILENAME; nr=0} {nr++} /^[[:space:]]*#/{next} /HOOK_JSON="\$\(cat[ )]/{print FILENAME":"nr}' {} +)"
if [[ -z "${remaining}" ]]; then
  printf '  PASS  no bare HOOK_JSON="$(cat...)" remains in any hook\n'
  pass=$((pass + 1))
else
  printf '  FAIL  bare HOOK_JSON cat pattern still present:\n%s\n' "${remaining}"
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
# F-003: stop-guard.sh routes jq parse failure to log_anomaly instead of
# silently zeroing out (gate-not-firing failure mode).
printf '\n## F-003 — stop-guard jq parse-failure observability\n'
if grep -q 'log_anomaly "stop-guard" "exemplifying_scope jq parse failed' "${STOP_GUARD}"; then
  printf '  PASS  stop-guard logs anomaly on jq parse failure\n'
  pass=$((pass + 1))
else
  printf '  FAIL  stop-guard does not log_anomaly on jq parse failure\n'
  fail=$((fail + 1))
fi

# The legacy three-jq pattern with `|| printf '0'` must be gone.
if grep -E "jq -r '\.source_prompt_ts.*\|\| printf '0'" "${STOP_GUARD}" >/dev/null 2>&1; then
  printf '  FAIL  legacy silent-zero pattern still present\n'
  fail=$((fail + 1))
else
  printf '  PASS  legacy silent-zero pattern removed\n'
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
# F-004: STATE_ROOT and ~/.claude/quality-pack get chmod 700.
printf '\n## F-004 — STATE_ROOT defense-in-depth chmod 700\n'
if grep -q 'chmod 700 "\${STATE_ROOT}"' "${COMMON_SH}"; then
  printf '  PASS  common.sh hardens STATE_ROOT perms\n'
  pass=$((pass + 1))
else
  printf '  FAIL  common.sh missing STATE_ROOT chmod 700\n'
  fail=$((fail + 1))
fi

if grep -q '_qp_root="\${STATE_ROOT%/state}"' "${STATE_IO}"; then
  printf '  PASS  state-io.sh hardens quality-pack parent perms\n'
  pass=$((pass + 1))
else
  printf '  FAIL  state-io.sh missing quality-pack parent chmod\n'
  fail=$((fail + 1))
fi

# Runtime check: after ensure_session_dir runs, STATE_ROOT has 700 perms.
# Note: env-var prefix on `source` only applies to source; ensure_session_dir
# is called in the same shell so SESSION_ID must be exported.
runtime_perms="$(bash -c "
  set -uo pipefail
  rm -rf '${STATE_ROOT}'
  export STATE_ROOT='${STATE_ROOT}'
  export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
  export SESSION_ID='test-chmod-runtime'
  source '${COMMON_SH}' </dev/null
  ensure_session_dir
  stat -c '%a' '${STATE_ROOT}' 2>/dev/null \
    || stat -f '%Lp' '${STATE_ROOT}' 2>/dev/null \
    || echo unknown
" 2>/dev/null)"
assert "STATE_ROOT has mode 700 after ensure_session_dir" "${runtime_perms}" "700"

# ----------------------------------------------------------------------
# F-006: Reviewer ROI table renders unconditionally inside the
# reviewer-activity section, regardless of window agent_breakdown.
printf '\n## F-006 — Reviewer ROI no longer gated on window timing\n'
if grep -q 'do NOT gate on _roi_breakdown being non-empty' "${SHOW_REPORT}"; then
  printf '  PASS  show-report.sh has the v1.40 F-006 anti-gate comment\n'
  pass=$((pass + 1))
else
  printf '  FAIL  show-report.sh missing F-006 fix marker\n'
  fail=$((fail + 1))
fi

# Negative check: the dropped gate condition must be gone.
if grep -E 'if \[\[ "\$\{_roi_breakdown\}" != "\{\}" \]\] && \[\[ -n "\$\{_roi_breakdown\}" \]\]; then' \
  "${SHOW_REPORT}" >/dev/null 2>&1; then
  printf '  FAIL  legacy ROI gate condition still present\n'
  fail=$((fail + 1))
else
  printf '  PASS  legacy ROI gate condition removed\n'
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf '\n--- v1.40.x W1 reliability regression: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
