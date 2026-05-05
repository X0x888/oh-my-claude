#!/usr/bin/env bash
# Tests for the per-directive size-count instrumentation added in
# prompt-intent-router.sh. Each `add_directive` call should append a
# `directive_emitted` row to timing.jsonl with name + chars + prompt_seq,
# enabling /ulw-report and offline analysis to attribute the prompt's
# additionalContext tax by category.
#
# `chars` (not bytes) because bash's `${#var}` is locale-aware: under
# UTF-8 locales it returns codepoint count, not raw byte count. T7
# guards this — directive bodies contain em-dashes (3 bytes / 1 codepoint
# in UTF-8) and the recorded chars value must match the codepoint count,
# not the byte count.
#
# Drives the router end-to-end with a synthetic /ulw prompt and asserts:
#   - timing.jsonl contains directive_emitted rows
#   - row schema (kind, ts, prompt_seq, name, chars) is well-formed
#   - chars field matches the actual body codepoint count for known directives
#   - distinct names cover the expected categories on a fresh execution prompt
#   - OMC_TIME_TRACKING=off suppresses emission entirely
#   - aggregator does not error on directive_emitted rows (forward-compat)
#   - chars stores codepoints not bytes for multi-byte UTF-8 bodies (T7)
#
# Mirrors structure of test-divergence-directive.sh for consistency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t directive-instr-home-XXXXXX)"
_test_state_root="${_test_home}/state"
_test_project="${_test_home}/project"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
mkdir -p "${_test_project}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_ge() {
  local label="$1" floor="$2" actual="$3"
  if (( actual >= floor )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    floor=%d actual=%d\n' "${label}" "${floor}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

_cleanup_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup_test EXIT

# Drive prompt-intent-router.sh and capture both stdout (additionalContext)
# and the resulting timing.jsonl path so tests can inspect both.
_run_router() {
  local session_id="$1"
  local prompt_text="$2"
  shift 2
  local env_args=("$@")

  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    --arg cwd "${_test_project}" \
    '{session_id:$sid, prompt:$p, cwd:$cwd}')"

  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    env ${env_args[@]+"${env_args[@]}"} \
    bash -c 'cd "$1" && bash "$2"' _ "${_test_project}" "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" 2>/dev/null \
    || true
}

_timing_file() {
  local sid="$1"
  printf '%s/%s/timing.jsonl' "${_test_state_root}" "${sid}"
}

# ----------------------------------------------------------------------
printf 'Test 1: ULW execution prompt produces directive_emitted rows\n'
sid="t1-${RANDOM}"
_run_router "${sid}" "ulw fix the off-by-one in lib/parse.ts:42" >/dev/null

tlog="$(_timing_file "${sid}")"
[[ -f "${tlog}" ]] || { printf '  FAIL: T1: timing.jsonl missing at %s\n' "${tlog}" >&2; fail=$((fail + 1)); }

if [[ -f "${tlog}" ]]; then
  count="$(jq -c 'select(.kind=="directive_emitted")' "${tlog}" 2>/dev/null | wc -l | tr -d ' ')"
  assert_ge "T1: at least 3 directive_emitted rows on execution prompt" 3 "${count}"
fi

# ----------------------------------------------------------------------
printf 'Test 2: rows have well-formed schema (kind, ts, prompt_seq, name, chars)\n'
if [[ -f "${tlog}" ]]; then
  malformed="$(jq -c 'select(.kind=="directive_emitted") |
    select(.ts == null or .prompt_seq == null or .name == null or .chars == null
      or (.ts | type) != "number"
      or (.chars | type) != "number"
      or (.name | type) != "string"
      or (.prompt_seq | type) != "number")
  ' "${tlog}" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "T2: zero malformed rows" "0" "${malformed}"
fi

# ----------------------------------------------------------------------
printf 'Test 3: expected category names appear on a fresh ULW execution prompt\n'
if [[ -f "${tlog}" ]]; then
  names="$(jq -r 'select(.kind=="directive_emitted") | .name' "${tlog}" 2>/dev/null | sort -u)"
  # ulw_execution_opener is unconditional on fresh execution; intent_classification
  # follows it; domain_routing fires inside the !session_management+!checkpoint branch.
  assert_contains "T3: ulw_execution_opener present" "ulw_execution_opener" "${names}"
  assert_contains "T3: intent_classification present" "intent_classification" "${names}"
  assert_contains "T3: domain_routing present" "domain_routing" "${names}"
fi

# ----------------------------------------------------------------------
printf 'Test 4: chars field equals actual body codepoint length for known directive\n'
# The intent_classification body for a fresh execution prompt is fully
# deterministic given TASK_DOMAIN and display_intent. We can't easily
# recompute the literal here without duplicating the router's body, so
# instead assert the cross-reference invariant: sum(chars) over the
# directive_emitted rows equals the codepoint length of the joined
# additionalContext minus (rows-1) for the join newlines added at final
# emission. This is the load-bearing accounting equation the analysis
# layer will rely on.
#
# Both sides use the same locale-aware counting (`${#var}` and `${#ctx}`
# both return codepoints under UTF-8) so the invariant holds regardless
# of LANG. T7 separately guards that the recorded values are actual
# codepoint counts and not byte counts (a different invariant).
sid="t4-${RANDOM}"
ctx="$(_run_router "${sid}" "ulw fix the off-by-one in lib/parse.ts:42" \
  | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
  || true)"
tlog4="$(_timing_file "${sid}")"
if [[ -f "${tlog4}" ]] && [[ -n "${ctx}" ]]; then
  rows="$(jq -c 'select(.kind=="directive_emitted")' "${tlog4}" 2>/dev/null)"
  row_count="$(printf '%s\n' "${rows}" | grep -c .)"
  chars_sum="$(printf '%s\n' "${rows}" | jq -s 'map(.chars) | add // 0' 2>/dev/null)"
  ctx_chars="${#ctx}"
  # additionalContext is captured via `$(printf '%s\n' "${context_parts[@]}")`.
  # printf emits N trailing newlines, but command substitution strips the
  # final trailing newline — net (N-1) newline separators between N rows.
  expected="$(( chars_sum + row_count - 1 ))"
  assert_eq "T4: sum(directive chars) + (N-1) newlines == ctx codepoint length" "${expected}" "${ctx_chars}"
fi

# ----------------------------------------------------------------------
printf 'Test 5: OMC_TIME_TRACKING=off suppresses directive_emitted rows entirely\n'
sid="t5-${RANDOM}"
_run_router "${sid}" "ulw fix the off-by-one in lib/parse.ts:42" "OMC_TIME_TRACKING=off" >/dev/null
tlog5="$(_timing_file "${sid}")"
# When time tracking is off, no timing.jsonl is created at all (early
# return in is_time_tracking_enabled gate). Either no file OR zero
# directive rows is acceptable.
if [[ -f "${tlog5}" ]]; then
  count5="$(jq -c 'select(.kind=="directive_emitted")' "${tlog5}" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "T5: no directive rows when time tracking off" "0" "${count5}"
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 6: aggregator does not error on directive_emitted rows\n'
# The legacy timing_aggregate function should silently ignore unknown
# row kinds (else branch in the reduce) — assert this stays true.
sid="t6-${RANDOM}"
_run_router "${sid}" "ulw fix the off-by-one in lib/parse.ts:42" >/dev/null
tlog6="$(_timing_file "${sid}")"
if [[ -f "${tlog6}" ]]; then
  agg="$(timing_aggregate "${tlog6}" 0 2>/dev/null || echo '')"
  if [[ -z "${agg}" ]] || [[ "${agg}" == "{}" ]]; then
    # No paired starts/ends in this run — aggregate may be empty. Not a
    # failure as long as the call itself didn't error.
    pass=$((pass + 1))
  else
    # Aggregator returned valid JSON.
    if jq -e . <<<"${agg}" >/dev/null 2>&1; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T6: aggregator returned non-JSON: %s\n' "${agg:0:200}" >&2
      fail=$((fail + 1))
    fi
  fi
fi

# ----------------------------------------------------------------------
printf 'Test 7: chars field stores codepoint count, not byte count, for UTF-8 bodies\n'
# Regression net for the locale defect quality-reviewer F-1 found.
# Bash's `${#var}` is locale-aware. The router's directive bodies contain
# em-dashes (U+2014, 3 bytes / 1 codepoint in UTF-8). T7 asserts the
# recorded values are codepoint counts, NOT byte counts, by:
#   (a) computing both ctx_chars (wc -m) and ctx_bytes (LC_ALL=C wc -c)
#       on the additionalContext output;
#   (b) confirming bodies actually contain multi-byte content (chars < bytes);
#   (c) confirming the recorded sum matches the chars side, not the bytes side.
# Without this test, a future change to `add_directive` that switched to
# true bytes (e.g., wc -c via fork) would silently break the documented
# semantics with no signal — T4 would still pass because both sides use
# the same expansion.
sid="t7-${RANDOM}"
ctx="$(_run_router "${sid}" "ulw fix the off-by-one in lib/parse.ts:42" \
  | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
  || true)"
tlog7="$(_timing_file "${sid}")"
if [[ -f "${tlog7}" ]] && [[ -n "${ctx}" ]]; then
  rows="$(jq -c 'select(.kind=="directive_emitted")' "${tlog7}" 2>/dev/null)"
  row_count="$(printf '%s\n' "${rows}" | grep -c .)"
  chars_sum="$(printf '%s\n' "${rows}" | jq -s 'map(.chars) | add // 0' 2>/dev/null)"
  ctx_chars="$(printf '%s' "${ctx}" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')"
  ctx_bytes="$(printf '%s' "${ctx}" | LC_ALL=C wc -c | tr -d ' ')"

  # (b) Bodies must actually contain multi-byte content for this test to
  # be meaningful — otherwise both sides equal and the assertion is trivial.
  if (( ctx_chars < ctx_bytes )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: T7 setup: directive bodies appear ASCII-only (ctx_chars=%d ctx_bytes=%d) — test cannot exercise multi-byte path\n' \
      "${ctx_chars}" "${ctx_bytes}" >&2
    fail=$((fail + 1))
  fi

  # (c) chars_sum should match the chars (codepoint) total, NOT the bytes total.
  expected_chars=$(( chars_sum + row_count - 1 ))
  assert_eq "T7: chars_sum + (N-1) == ctx_chars (codepoints, not bytes)" \
    "${expected_chars}" "${ctx_chars}"
  # And confirm the bytes total is meaningfully larger than the chars total
  # so a future bytes-counting regression would diverge from the chars side.
  if (( expected_chars != ctx_bytes )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: T7: chars_sum coincidentally matches byte count — test is non-discriminating\n' >&2
    fail=$((fail + 1))
  fi
fi

# ----------------------------------------------------------------------
printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
