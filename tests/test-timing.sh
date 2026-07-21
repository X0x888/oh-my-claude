#!/usr/bin/env bash
# Tests for the time-tracking subsystem (lib/timing.sh + pretool/posttool
# hooks + Stop epilogue + show-time). Cover the load-bearing behaviors:
# serialized append correctness, FIFO/LIFO pairing, prompt-seq epoch
# isolation, opt-out fast-path, aggregator math, format helpers, Stop
# self-suppression on the exact blocked Stop attempt, and show-time
# empty-state vs populated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

# Timing contracts need ordered whole-second timestamps, not wall-clock
# waiting. Override the sourced helper in this test process so every former
# one-second sleep becomes a deterministic logical-clock advance. Hook-level
# integration still exercises the production clock in the dedicated hook
# suites.
TEST_NOW_EPOCH="$(date +%s)"
now_epoch() {
  printf '%s' "${TEST_NOW_EPOCH}"
}
advance_test_epoch() {
  TEST_NOW_EPOCH=$((TEST_NOW_EPOCH + ${1:-1}))
}

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
HOME="${TEST_STATE_ROOT}/home"
mkdir -p "${HOME}/.claude/quality-pack"
SESSION_ID="timing-test-session"
ensure_session_dir

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_ge() {
  local label="$1" floor="$2" actual="$3"
  if [[ "${actual}" =~ ^[0-9]+$ ]] && (( actual >= floor )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected >= %s actual=%q\n' "${label}" "${floor}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

reset_log() {
  rm -f "$(timing_log_path)"
}

# ----------------------------------------------------------------------
printf 'Test 1: opt-out fast-path produces no log file\n'
reset_log
OMC_TIME_TRACKING="off"
timing_append_start "Bash"
timing_append_end "Bash"
if [[ -f "$(timing_log_path)" ]]; then
  printf '  FAIL: opt-out wrote a log file\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
OMC_TIME_TRACKING="on"

# ----------------------------------------------------------------------
printf 'Test 1b: unavailable clock is a non-throwing telemetry no-op\n'
reset_log
clock_xs_log="$(timing_xs_log_path)"
rm -f "${clock_xs_log}"
clock_writer_rc=0
(
  # Indirectly consumed by the timing writers under test.
  # shellcheck disable=SC2329
  now_epoch() { return 1; }
  timing_append_start "Bash" "clock-start" "" 1
  timing_append_end "Bash" "clock-end" 1
  timing_append_prompt_start 1
  timing_append_directive "clock_failure" 10 1
  timing_append_prompt_end 1 5
  timing_record_session_summary \
    '{"walltime_s":5,"tokens_main_in":0,"stale_reviewer_count":0}'
) >/dev/null 2>&1 || clock_writer_rc=$?
assert_eq "clock failure never escapes timing writers" "0" "${clock_writer_rc}"
assert_eq "clock failure emits no per-session timing row" "0" \
  "$([[ -s "$(timing_log_path)" ]] && printf 1 || printf 0)"
assert_eq "clock failure emits no cross-session summary" "0" \
  "$([[ -s "${clock_xs_log}" ]] && printf 1 || printf 0)"

stop_clock_root="${TEST_STATE_ROOT}/stop-clock-failure"
stop_clock_session="stop-clock-failure"
stop_clock_dir="${stop_clock_root}/${stop_clock_session}"
mkdir -p "${stop_clock_dir}"
printf '%s\n' \
  '{"prompt_seq":"1","session_id":"stop-clock-failure"}' \
  >"${stop_clock_dir}/session_state.json"
printf '%s\n' \
  '{"kind":"prompt_start","ts":100,"prompt_seq":1}' \
  >"${stop_clock_dir}/timing.jsonl"
stop_clock_payload='{"session_id":"stop-clock-failure"}'
stop_clock_rc=0
_stop_clock_failure_probe() {
  local STATE_ROOT="${stop_clock_root}"
  local HOME="${TEST_STATE_ROOT}/stop-clock-home"
  mkdir -p "${HOME}/.claude/quality-pack"
  # Indirectly consumed by the sourced Stop timing hook.
  # shellcheck disable=SC2329
  now_epoch() { return 1; }
  . "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${stop_clock_payload}"
}
( _stop_clock_failure_probe ) >/dev/null 2>&1 || stop_clock_rc=$?
assert_eq "clock failure never escapes Stop timing finalization" \
  "0" "${stop_clock_rc}"
assert_eq "clock failure cannot fabricate a prompt-end timestamp" "0" \
  "$(jq -s '[.[] | select(.kind == "prompt_end")] | length' \
    "${stop_clock_dir}/timing.jsonl")"

# ----------------------------------------------------------------------
printf 'Test 2: simple Bash start+end pair aggregates correctly\n'
reset_log
timing_append_prompt_start 1
timing_append_start "Bash" "" "" 1
advance_test_epoch
timing_append_end "Bash" "" 1
advance_test_epoch
timing_append_prompt_end 1 2

agg="$(timing_aggregate "$(timing_log_path)")"
assert_eq "tool_total_s present" "true" \
  "$(jq -r 'has("tool_total_s")' <<<"${agg}")"
bash_total="$(jq -r '.tool_breakdown.Bash // 0' <<<"${agg}")"
assert_ge "Bash duration captured" "1" "${bash_total}"
walltime="$(jq -r '.walltime_s // 0' <<<"${agg}")"
assert_eq "walltime taken from prompt_end" "2" "${walltime}"

# ----------------------------------------------------------------------
printf 'Test 3: tool_use_id matches across permuted end order\n'
reset_log
timing_append_prompt_start 2
timing_append_start "Bash" "id-A" "" 2
timing_append_start "Bash" "id-B" "" 2
advance_test_epoch
# Ends arrive in REVERSE order (end-B before end-A) — tool_use_id must rescue
timing_append_end "Bash" "id-B" 2
advance_test_epoch
timing_append_end "Bash" "id-A" 2
timing_append_prompt_end 2 2

agg="$(timing_aggregate "$(timing_log_path)")"
bash_total="$(jq -r '.tool_breakdown.Bash // 0' <<<"${agg}")"
# id-B duration ~1s, id-A duration ~2s. With tool_use_id matching, sum == 3.
# With FIFO mismatch and no IDs, sum would still equal the same total
# (durations are commutative for sums). Either way: total >= 2.
assert_ge "tool_use_id matched pair sum" "2" "${bash_total}"
orphans="$(jq -r '.orphan_end_count // 0' <<<"${agg}")"
assert_eq "no orphan ends with tool_use_id" "0" "${orphans}"

# ----------------------------------------------------------------------
printf 'Test 4: Agent subagent attribution buckets correctly\n'
reset_log
timing_append_prompt_start 3
timing_append_start "Agent" "ag-1" "quality-reviewer" 3
advance_test_epoch
timing_append_end "Agent" "ag-1" 3
timing_append_start "Agent" "ag-2" "metis" 3
advance_test_epoch
timing_append_end "Agent" "ag-2" 3
timing_append_prompt_end 3 2

agg="$(timing_aggregate "$(timing_log_path)")"
qr="$(jq -r '.agent_breakdown."quality-reviewer" // 0' <<<"${agg}")"
metis="$(jq -r '.agent_breakdown.metis // 0' <<<"${agg}")"
assert_ge "quality-reviewer time captured" "1" "${qr}"
assert_ge "metis time captured" "1" "${metis}"
agent_count="$(jq -r '.agent_breakdown | length' <<<"${agg}")"
assert_eq "two distinct subagent buckets" "2" "${agent_count}"

# ----------------------------------------------------------------------
printf 'Test 5: prompt_seq isolates calls across epochs\n'
reset_log
timing_append_prompt_start 10
timing_append_start "Bash" "" "" 10
advance_test_epoch
timing_append_end "Bash" "" 10
timing_append_prompt_end 10 1
# Next prompt
timing_append_prompt_start 11
timing_append_start "Bash" "" "" 11
advance_test_epoch
timing_append_end "Bash" "" 11
timing_append_prompt_end 11 1

agg="$(timing_aggregate "$(timing_log_path)")"
prompt_count="$(jq -r '.prompt_count // 0' <<<"${agg}")"
assert_eq "two prompts finalized" "2" "${prompt_count}"
walltime="$(jq -r '.walltime_s // 0' <<<"${agg}")"
assert_eq "summed walltime across prompts" "2" "${walltime}"

# ----------------------------------------------------------------------
printf 'Test 6: cross-epoch starts do NOT match unrelated end\n'
# Start in seq 5 — never ends. End in seq 6 — no matching start.
# Aggregator should record one active_pending and one orphan_end.
reset_log
timing_append_start "Bash" "" "" 5
timing_append_end "Bash" "" 6

agg="$(timing_aggregate "$(timing_log_path)")"
active_pending="$(jq -r '.active_pending // 0' <<<"${agg}")"
orphan_end="$(jq -r '.orphan_end_count // 0' <<<"${agg}")"
assert_eq "cross-epoch start stays pending" "1" "${active_pending}"
assert_eq "cross-epoch end is orphan" "1" "${orphan_end}"

# ----------------------------------------------------------------------
printf 'Test 6b: directive_emitted rows aggregate into directive footprint fields\n'
reset_log
timing_append_directive "domain_routing" 120 9
timing_append_directive "domain_routing" 80 9
timing_append_directive "intent_classification" 40 9

agg="$(timing_aggregate "$(timing_log_path)")"
directive_total="$(jq -r '.directive_total_chars // 0' <<<"${agg}")"
directive_count="$(jq -r '.directive_count // 0' <<<"${agg}")"
domain_chars="$(jq -r '.directive_breakdown.domain_routing // 0' <<<"${agg}")"
domain_fires="$(jq -r '.directive_counts.domain_routing // 0' <<<"${agg}")"
intent_chars="$(jq -r '.directive_breakdown.intent_classification // 0' <<<"${agg}")"
assert_eq "directive chars summed" "240" "${directive_total}"
assert_eq "directive fire count summed" "3" "${directive_count}"
assert_eq "domain_routing chars summed" "200" "${domain_chars}"
assert_eq "domain_routing fire count summed" "2" "${domain_fires}"
assert_eq "intent_classification chars recorded" "40" "${intent_chars}"

# ----------------------------------------------------------------------
printf 'Test 6c: aggregate rejects fractional numeric rows\n'
reset_log
printf '%s\n' \
  '{"kind":"prompt_start","ts":10,"prompt_seq":1}' \
  '{"kind":"prompt_end","ts":20,"prompt_seq":1,"duration_s":10}' \
  '{"kind":"prompt_start","ts":30.5,"prompt_seq":2}' \
  '{"kind":"prompt_end","ts":40,"prompt_seq":2,"duration_s":9}' \
  '{"kind":"directive_emitted","ts":11,"prompt_seq":1,"name":"fractional","chars":1.5}' \
  '{"kind":"token_delta","ts":11,"prompt_seq":1,"main_in":1.5}' \
  '{"kind":"token_delta","ts":12,"prompt_seq":1,"main_in":7,"agent_by_role":{"reviewer":{"input":1.5}}}' \
  '{"kind":"token_delta","ts":13,"prompt_seq":1,"main_in":8,"agent_by_model":{"model":{"output":1000000000000000}}}' \
  '{"kind":"prompt_end","prompt_seq":3,"duration_s":99}' \
  '{"kind":"start","ts":50,"prompt_seq":3}' \
  '{"kind":"token_delta","ts":51,"prompt_seq":3}' \
  >"$(timing_log_path)"
agg="$(timing_aggregate "$(timing_log_path)")"
assert_eq "fractional prompt row is not rounded into authority" "10" \
  "$(jq -r '.walltime_s' <<<"${agg}")"
assert_eq "fractional directive row is dropped" "0" \
  "$(jq -r '.directive_total_chars' <<<"${agg}")"
assert_eq "fractional token row is dropped" "0" \
  "$(jq -r '.tokens_main_in' <<<"${agg}")"
assert_eq "malformed nested token buckets reject their complete rows" "0" \
  "$(jq -r '[.agent_tokens_by_role[],.agent_tokens_by_model[]] | length' \
    <<<"${agg}")"
assert_eq "recognized rows missing kind-required provenance are rejected" "0" \
  "$(jq -r '.active_pending + .orphan_end_count' <<<"${agg}")"

# ----------------------------------------------------------------------
printf 'Test 6d: aggregate saturates repeated bounded integers exactly\n'
reset_log
timing_uint_ceiling=999999999999999
printf '%s\n' \
  '{"kind":"prompt_start","ts":1,"prompt_seq":1}' \
  '{"kind":"prompt_end","ts":2,"prompt_seq":1,"duration_s":999999999999999}' \
  '{"kind":"prompt_start","ts":3,"prompt_seq":2}' \
  '{"kind":"prompt_end","ts":4,"prompt_seq":2,"duration_s":999999999999999}' \
  '{"kind":"start","ts":1,"tool":"Agent","tool_use_id":"a1","subagent":"reviewer","prompt_seq":1}' \
  '{"kind":"end","ts":999999999999999,"tool":"Agent","tool_use_id":"a1","prompt_seq":1}' \
  '{"kind":"start","ts":1,"tool":"Agent","tool_use_id":"a2","subagent":"reviewer","prompt_seq":1}' \
  '{"kind":"end","ts":999999999999999,"tool":"Agent","tool_use_id":"a2","prompt_seq":1}' \
  '{"kind":"start","ts":1,"tool":"Bash","tool_use_id":"b1","prompt_seq":1}' \
  '{"kind":"end","ts":999999999999999,"tool":"Bash","tool_use_id":"b1","prompt_seq":1}' \
  '{"kind":"start","ts":1,"tool":"Bash","tool_use_id":"b2","prompt_seq":1}' \
  '{"kind":"end","ts":999999999999999,"tool":"Bash","tool_use_id":"b2","prompt_seq":1}' \
  '{"kind":"directive_emitted","ts":2,"prompt_seq":1,"name":"large","chars":999999999999999}' \
  '{"kind":"directive_emitted","ts":3,"prompt_seq":1,"name":"large","chars":999999999999999}' \
  '{"kind":"token_delta","ts":2,"prompt_seq":1,"main_in":999999999999999,"usage_rows":999999999999999,"agent_by_role":{"reviewer":{"input":999999999999999}}}' \
  '{"kind":"token_delta","ts":3,"prompt_seq":1,"main_in":999999999999999,"usage_rows":999999999999999,"agent_by_role":{"reviewer":{"input":999999999999999}}}' \
  >"$(timing_log_path)"
agg="$(timing_aggregate "$(timing_log_path)")"
for saturated_path in \
    '.walltime_s' '.agent_total_s' '.agent_breakdown.reviewer' \
    '.tool_total_s' '.tool_breakdown.Bash' \
    '.directive_total_chars' '.directive_breakdown.large' \
    '.tokens_main_in' '.token_usage_rows' \
    '.agent_tokens_by_role.reviewer.input' '.concurrent_overhead_s'; do
  assert_eq "${saturated_path} stays at the exact integer ceiling" \
    "${timing_uint_ceiling}" "$(jq -r "${saturated_path}" <<<"${agg}")"
done

# Derived overlap can be larger than one stored field even though every input
# is canonical. It must clamp after the exact arithmetic, not be rejected as
# though the derived value itself came from an untrusted row.
reset_log
printf '%s\n' \
  '{"kind":"prompt_start","ts":1,"prompt_seq":1}' \
  '{"kind":"prompt_end","ts":2,"prompt_seq":1,"duration_s":1}' \
  '{"kind":"start","ts":1,"tool":"Agent","tool_use_id":"overlap-agent","subagent":"reviewer","prompt_seq":1}' \
  '{"kind":"end","ts":999999999999999,"tool":"Agent","tool_use_id":"overlap-agent","prompt_seq":1}' \
  '{"kind":"start","ts":1,"tool":"Bash","tool_use_id":"overlap-tool","prompt_seq":1}' \
  '{"kind":"end","ts":999999999999999,"tool":"Bash","tool_use_id":"overlap-tool","prompt_seq":1}' \
  >"$(timing_log_path)"
agg="$(timing_aggregate "$(timing_log_path)")"
assert_eq "derived overlap above the field ceiling saturates instead of zeroing" \
  "${timing_uint_ceiling}" "$(jq -r '.concurrent_overhead_s' <<<"${agg}")"

max_token_agg='{"tokens_main_in":999999999999999,"tokens_main_out":999999999999999,"tokens_main_cache_read":999999999999999,"tokens_main_cache_creation":999999999999999,"tokens_agent_in":999999999999999,"tokens_agent_out":999999999999999,"tokens_agent_cache_read":999999999999999,"tokens_agent_cache_creation":999999999999999}'
assert_eq "multi-component token rendering preserves the full bounded sum" \
  "tokens   in 5999999999.9M (33% cached) · out 1999999999.9M · agents 50%" \
  "$(timing_token_line "${max_token_agg}")"

# Same-prompt checkpoints can share a wall-clock second on a fast Stop retry.
# Their eight-component total is a comparison key and legitimately exceeds
# the per-field ceiling; selecting through a saturated key retained the older
# cumulative checkpoint even when every component grew.
reset_log
printf '%s\n' \
  '{"kind":"token_checkpoint","ts":9,"prompt_seq":9,"main_in":999999999999998,"main_out":999999999999998,"main_cache_read":999999999999998,"main_cache_creation":999999999999998,"agent_in":999999999999998,"agent_out":999999999999998,"agent_cache_read":999999999999998,"agent_cache_creation":999999999999998}' \
  '{"kind":"token_checkpoint","ts":9,"prompt_seq":9,"main_in":999999999999999,"main_out":999999999999999,"main_cache_read":999999999999999,"main_cache_creation":999999999999999,"agent_in":999999999999999,"agent_out":999999999999999,"agent_cache_read":999999999999999,"agent_cache_creation":999999999999999}' \
  >"$(timing_log_path)"
agg="$(timing_aggregate "$(timing_log_path)")"
assert_eq "same-second max-envelope checkpoint selects the larger cumulative total" \
  "999999999999999" "$(jq -r '.tokens_main_in' <<<"${agg}")"

# ----------------------------------------------------------------------
printf 'Test 7: oneline format renders bucket totals\n'
reset_log
timing_append_prompt_start 20
timing_append_start "Bash" "" "" 20
advance_test_epoch
timing_append_end "Bash" "" 20
timing_append_prompt_end 20 10

agg="$(timing_aggregate "$(timing_log_path)")"
oneline="$(timing_format_oneline "${agg}")"
case "${oneline}" in
  *"Time:"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: oneline missing Time prefix: %q\n' "${oneline}" >&2
    fail=$((fail + 1))
    ;;
esac
case "${oneline}" in
  *"tools"*"Bash"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: oneline missing tools breakdown: %q\n' "${oneline}" >&2
    fail=$((fail + 1))
    ;;
esac

# ----------------------------------------------------------------------
printf 'Test 7b: oneline format surfaces directive footprint totals\n'
reset_log
timing_append_prompt_start 21
timing_append_directive "ui_design_contract" 160 21
timing_append_directive "intent_classification" 80 21
timing_append_prompt_end 21 6

agg="$(timing_aggregate "$(timing_log_path)")"
oneline="$(timing_format_oneline "${agg}")"
case "${oneline}" in
  *"directive surface 240 chars (2 fires)"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: oneline missing directive footprint: %q\n' "${oneline}" >&2
    fail=$((fail + 1))
    ;;
esac

# ----------------------------------------------------------------------
printf 'Test 8: oneline suppressed below noise floor\n'
reset_log
timing_append_prompt_start 30
timing_append_prompt_end 30 2  # 2s walltime — below 5s floor

agg="$(timing_aggregate "$(timing_log_path)")"
oneline="$(timing_format_oneline "${agg}")"
assert_eq "noise-floor suppression" "" "${oneline}"

# ----------------------------------------------------------------------
printf 'Test 9: full format renders bar chart with %% breakdown\n'
reset_log
timing_append_prompt_start 40
timing_append_start "Agent" "" "quality-reviewer" 40
advance_test_epoch
timing_append_end "Agent" "" 40
timing_append_prompt_end 40 10

agg="$(timing_aggregate "$(timing_log_path)")"
full="$(timing_format_full "${agg}" "Test")"
case "${full}" in
  *"agents"*"quality-reviewer"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: full format missing agent rows\n%s\n' "${full}" >&2
    fail=$((fail + 1))
    ;;
esac

# ----------------------------------------------------------------------
printf 'Test 10: timing_fmt_secs human-readable output\n'
assert_eq "0s" "0s" "$(timing_fmt_secs 0)"
assert_eq "59s" "59s" "$(timing_fmt_secs 59)"
assert_eq "1m 00s" "1m 00s" "$(timing_fmt_secs 60)"
assert_eq "3m 25s" "3m 25s" "$(timing_fmt_secs 205)"
assert_eq "1h 01m" "1h 01m" "$(timing_fmt_secs 3660)"

# ----------------------------------------------------------------------
printf 'Test 11: prompt_seq increments and persists across calls\n'
write_state "prompt_seq" "0"
seq1="$(timing_next_prompt_seq)"
seq2="$(timing_next_prompt_seq)"
seq3="$(timing_next_prompt_seq)"
assert_eq "prompt_seq #1" "1" "${seq1}"
assert_eq "prompt_seq #2" "2" "${seq2}"
assert_eq "prompt_seq #3" "3" "${seq3}"
assert_eq "current matches latest" "3" "$(timing_current_prompt_seq)"

printf 'Test 11a: prompt_seq allocation is atomic and rejects poisoned arithmetic\n'
write_state "prompt_seq" "0"
seq_out_dir="${TEST_STATE_ROOT}/prompt-seq-results"
mkdir -p "${seq_out_dir}"
for i in $(seq 1 24); do
  (timing_next_prompt_seq >"${seq_out_dir}/${i}") &
done
wait
seq_values="$(sort -n "${seq_out_dir}"/* | paste -sd, -)"
seq_expected="$(seq 1 24 | paste -sd, -)"
assert_eq "concurrent prompt_seq callers receive unique contiguous epochs" \
  "${seq_expected}" "${seq_values}"
assert_eq "concurrent prompt_seq state reaches the exact caller count" \
  "24" "$(timing_current_prompt_seq)"

prompt_seq_marker="${TEST_STATE_ROOT}/prompt-seq-arithmetic-executed"
write_state "prompt_seq" "x[\$(touch ${prompt_seq_marker})]"
assert_eq "poisoned prompt_seq is not evaluated" "0" \
  "$(timing_next_prompt_seq)"
assert_eq "poisoned prompt_seq remains quarantined instead of being reset" \
  "x[\$(touch ${prompt_seq_marker})]" "$(read_state "prompt_seq")"
assert_eq "poisoned prompt_seq did not execute a command" "0" \
  "$([[ -e "${prompt_seq_marker}" ]] && printf 1 || printf 0)"
prompt_state_file="$(session_file "${STATE_JSON}")"
jq '.prompt_seq = ("1" + "\u0000")' "${prompt_state_file}" \
  >"${prompt_state_file}.tmp"
mv "${prompt_state_file}.tmp" "${prompt_state_file}"
assert_eq "NUL-bearing prompt_seq cannot be normalized before increment" "0" \
  "$(timing_next_prompt_seq)"
assert_eq "NUL-bearing prompt_seq cannot become current authority" "0" \
  "$(timing_current_prompt_seq)"
assert_eq "rejected NUL-bearing prompt_seq remains quarantined" "true" \
  "$(jq -r '.prompt_seq == ("1" + "\u0000")' "${prompt_state_file}")"
write_state "prompt_seq" "999999999999999"
assert_eq "exhausted prompt_seq cannot wrap" "0" \
  "$(timing_next_prompt_seq)"
assert_eq "exhausted prompt_seq state is preserved" "999999999999999" \
  "$(read_state "prompt_seq")"

# ----------------------------------------------------------------------
printf 'Test 12: serialized append survives 30 concurrent writers\n'
reset_log
target="$(timing_log_path)"
n=30
for i in $(seq 1 "${n}"); do
  (
    row="$(jq -nc \
      --argjson ts "$(now_epoch)" \
      --arg tool "Bash" \
      --argjson seq "${i}" \
      '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$seq}')"
    printf '%s\n' "${row}" >> "${target}"
  ) &
done
wait
written="$(wc -l < "${target}" | tr -d '[:space:]')"
assert_eq "all rows written under concurrency" "${n}" "${written}"
# Every row must parse as JSON (no torn lines).
unparsable=0
while IFS= read -r line; do
  jq empty <<<"${line}" 2>/dev/null || unparsable=$((unparsable + 1))
done < "${target}"
assert_eq "every row parses as JSON" "0" "${unparsable}"

# ----------------------------------------------------------------------
printf 'Test 13: cross-session aggregate sums two sessions\n'
xs_log="${HOME}/.claude/quality-pack/timing.jsonl"
mkdir -p "$(dirname "${xs_log}")"
rm -f "${xs_log}"
jq -nc --arg session "s1" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$session,project_key:"p1",walltime_s:60,agent_total_s:30,
    tool_total_s:20,idle_model_s:10,
    agent_breakdown:{"quality-reviewer":30},
    tool_breakdown:{"Bash":20},
    directive_total_chars:180,directive_count:2,
    directive_breakdown:{"domain_routing":120,"intent_classification":60},
    directive_counts:{"domain_routing":1,"intent_classification":1},
    prompt_count:1}' >> "${xs_log}"
jq -nc --arg session "s2" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$session,project_key:"p1",walltime_s:120,agent_total_s:80,
    tool_total_s:30,idle_model_s:10,
    agent_breakdown:{"quality-reviewer":50,"metis":30},
    tool_breakdown:{"Bash":20,"Read":10},
    directive_total_chars:220,directive_count:3,
    directive_breakdown:{"domain_routing":100,"bias_defense_completeness":120},
    directive_counts:{"domain_routing":1,"bias_defense_completeness":2},
    prompt_count:1}' >> "${xs_log}"

rollup="$(timing_xs_aggregate 0)"
sessions="$(jq -r '.sessions // 0' <<<"${rollup}")"
assert_eq "rollup counts both sessions" "2" "${sessions}"
walltime="$(jq -r '.walltime_s // 0' <<<"${rollup}")"
assert_eq "summed walltime" "180" "${walltime}"
qr="$(jq -r '.agent_breakdown."quality-reviewer" // 0' <<<"${rollup}")"
assert_eq "merged quality-reviewer total" "80" "${qr}"
bash_total="$(jq -r '.tool_breakdown.Bash // 0' <<<"${rollup}")"
assert_eq "merged Bash total" "40" "${bash_total}"
directive_total="$(jq -r '.directive_total_chars // 0' <<<"${rollup}")"
assert_eq "merged directive chars total" "400" "${directive_total}"
domain_chars="$(jq -r '.directive_breakdown.domain_routing // 0' <<<"${rollup}")"
assert_eq "merged domain_routing chars" "220" "${domain_chars}"
completeness_fires="$(jq -r '.directive_counts.bias_defense_completeness // 0' <<<"${rollup}")"
assert_eq "merged completeness directive fires" "2" "${completeness_fires}"

# Cross-session ledgers are durable imported state, so malformed numeric rows
# must not gain authority through rounding/clamping and repeated valid maxima
# must saturate without first overflowing jq's exact-integer envelope.
printf 'Test 13b: cross-session aggregate rejects malformed rows and saturates\n'
rm -f "${xs_log}"
timing_uint_ceiling=999999999999999
printf '%s\n' \
  '{"ts":1,"session_id":"max-a","walltime_s":999999999999999,"agent_breakdown":{"reviewer":999999999999999},"agent_tokens_by_role":{"reviewer":{"input":999999999999999}},"prompt_count":999999999999999}' \
  '{"ts":2,"session_id":"max-b","walltime_s":999999999999999,"agent_breakdown":{"reviewer":999999999999999},"agent_tokens_by_role":{"reviewer":{"input":999999999999999}},"prompt_count":999999999999999}' \
  '{"ts":3,"session_id":"fractional-top","walltime_s":1.5,"prompt_count":1}' \
  '{"ts":4,"session_id":"fractional-map","walltime_s":7,"agent_breakdown":{"reviewer":1.5},"prompt_count":1}' \
  '{"ts":5,"session_id":"oversized-bucket","walltime_s":8,"agent_tokens_by_role":{"reviewer":{"input":1000000000000000}},"prompt_count":1}' \
  '{"ts":6,"session_id":"filtered-malformed-id","walltime_s":9,"agent_tokens_by_id":{"hidden":{"input":1.5}},"prompt_count":1}' \
  '{"ts":7,"session_id":"filtered-nonobject-id","walltime_s":9,"agent_tokens_by_id":42,"prompt_count":1}' \
  '{}' \
  '{"tokens_main_in":7}' \
  '{"ts":8,"tokens_main_in":9}' \
  >"${xs_log}"
rollup="$(timing_xs_aggregate 0)"
assert_eq "cross-session malformed rows are rejected completely" "2" \
  "$(jq -r '.sessions' <<<"${rollup}")"
for saturated_path in \
    '.walltime_s' '.agent_breakdown.reviewer' \
    '.agent_tokens_by_role.reviewer.input' '.prompts'; do
  assert_eq "cross-session ${saturated_path} saturates exactly" \
    "${timing_uint_ceiling}" "$(jq -r "${saturated_path}" <<<"${rollup}")"
done
filtered_rollup="$(timing_xs_aggregate \
  0 "${xs_log}" "" '["max-a::selected-only"]')"
assert_eq "dispatch prefilter cannot hide a malformed unselected bucket" "2" \
  "$(jq -r '.sessions' <<<"${filtered_rollup}")"

# ----------------------------------------------------------------------
printf 'Test 14: Stop self-suppression matches the exact blocked attempt\n'
block_root="$(mktemp -d)"
block_session="exact-block-session"
block_dir="${block_root}/${block_session}"
mkdir -p "${block_dir}"
# This timestamp is consumed by a fresh hook process, which intentionally uses
# the production wall clock rather than this test process's logical clock.
now_ts="$(date +%s)"
jq -nc --argjson ts "$(( now_ts - 12 ))" --argjson seq 1 \
  '{kind:"prompt_start",ts:$ts,prompt_seq:$seq}' > "${block_dir}/timing.jsonl"
jq -nc --arg sid "${block_session}" --argjson now "${now_ts}" \
  '{session_id:$sid,prompt_seq:"1",stop_guard_attempt_seq:"7",last_stop_block_attempt_seq:"7",last_stop_block_ts:($now|tostring)}' \
  > "${block_dir}/session_state.json"
block_payload="$(jq -nc --arg sid "${block_session}" '{session_id:$sid}')"
block_out="$(STATE_ROOT="${block_root}" HOME="${HOME}" OMC_TIME_CARD_MIN_SECONDS=0 \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${block_payload}" 2>&1 || true)"
assert_eq "exact blocked attempt suppresses the card" "" "${block_out}"

# ----------------------------------------------------------------------
printf 'Test 15: show-time.sh empty state for fresh session\n'
empty_root="$(mktemp -d)"
empty_session="empty-session"
mkdir -p "${empty_root}/${empty_session}"
out="$(STATE_ROOT="${empty_root}" SESSION_ID="${empty_session}" \
  HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/show-time.sh" current 2>&1 || true)"
case "${out}" in
  *"No timing data"*|*"No active or recent ULW session"*|*"No finalized prompts yet"*)
    pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: show-time current empty-state unexpected:\n%s\n' "${out}" >&2
    fail=$((fail + 1))
    ;;
esac
rm -rf "${empty_root}"

# ----------------------------------------------------------------------
printf 'Test 16: show-time.sh disabled-flag short-circuit\n'
out="$(OMC_TIME_TRACKING=off STATE_ROOT="${STATE_ROOT}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/show-time.sh" current 2>&1 || true)"
case "${out}" in
  *"Time tracking is disabled"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: opt-out path missing message:\n%s\n' "${out}" >&2
    fail=$((fail + 1))
    ;;
esac

# ----------------------------------------------------------------------
printf 'Test 17: timing_record_session_summary dedups by session_id\n'
# Regression net for the cross-session double-count bug: every Stop fires
# this with a fresh whole-session aggregate; without dedup, a 4-prompt
# session would write 4 rows whose walltime_s grows monotonically and the
# aggregator would sum them. The fix keeps only the latest aggregate per
# session.
xs_log="${HOME}/.claude/quality-pack/timing.jsonl"
mkdir -p "$(dirname "${xs_log}")"
rm -f "${xs_log}"

# Aggregate data is payload, never publication authority. Reserved writer
# fields must remain bound to the current session/clock/project/schema.
SESSION_ID="summary-authority-session"
timing_record_session_summary \
  '{"_v":999,"ts":1,"session_id":"forged-session","project_key":"forged-project","walltime_s":5,"prompt_count":1}'
assert_eq "summary payload cannot replace writer session identity" \
  "summary-authority-session" "$(jq -r '.session_id' "${xs_log}")"
assert_eq "summary payload cannot replace writer timestamp" \
  "${TEST_NOW_EPOCH}" "$(jq -r '.ts' "${xs_log}")"
assert_eq "summary payload cannot replace writer schema" "1" \
  "$(jq -r '._v' "${xs_log}")"
assert_eq "summary payload cannot replace writer project identity" "false" \
  "$(jq -r '.project_key == "forged-project"' "${xs_log}")"
rm -f "${xs_log}"

# Simulate three sequential Stop events in the same session — each with
# the running whole-session aggregate.
SESSION_ID="dedup-test-session"
agg_v1='{"walltime_s":10,"agent_total_s":5,"agent_breakdown":{"qr":5},"tool_total_s":3,"tool_breakdown":{"Bash":3},"idle_model_s":2,"prompt_count":1}'
agg_v2='{"walltime_s":25,"agent_total_s":12,"agent_breakdown":{"qr":12},"tool_total_s":8,"tool_breakdown":{"Bash":8},"idle_model_s":5,"prompt_count":2}'
agg_v3='{"walltime_s":42,"agent_total_s":20,"agent_breakdown":{"qr":20},"tool_total_s":15,"tool_breakdown":{"Bash":15},"idle_model_s":7,"prompt_count":3}'

timing_record_session_summary "${agg_v1}"
timing_record_session_summary "${agg_v2}"
timing_record_session_summary "${agg_v3}"

# After three Stops, only ONE row should exist for this session (the latest).
# v1.31.0 Wave 4: timing.jsonl uses .session_id (was .session). Match
# both for backwards compat with rows written before the rename.
session_rows="$(jq -sr --arg sid "${SESSION_ID}" \
  '[.[] | select(((.session_id // .session) // "") == $sid)] | length' "${xs_log}" 2>/dev/null)"
assert_eq "single row per session after multi-Stop" "1" "${session_rows}"

# The surviving row must carry the LATEST walltime, not a stale earlier one.
final_walltime="$(jq -sr --arg sid "${SESSION_ID}" \
  '[.[] | select(((.session_id // .session) // "") == $sid)] | first | .walltime_s' "${xs_log}" 2>/dev/null)"
assert_eq "surviving row has latest walltime" "42" "${final_walltime}"

# Aggregating across all sessions must report the correct walltime —
# bug-before would yield 10+25+42=77, bug-fix yields 42.
rollup="$(timing_xs_aggregate 0)"
xs_walltime="$(jq -r '.walltime_s // 0' <<<"${rollup}")"
assert_eq "xs aggregate not double-counting" "42" "${xs_walltime}"

# A second session adds a row but does not affect the first session's row.
SESSION_ID="dedup-test-session-2"
agg_other='{"walltime_s":60,"agent_total_s":30,"agent_breakdown":{"metis":30},"tool_total_s":20,"tool_breakdown":{"Read":20},"idle_model_s":10,"prompt_count":2}'
timing_record_session_summary "${agg_other}"

total_rows="$(wc -l < "${xs_log}" | tr -d '[:space:]')"
assert_eq "two sessions yield two rows" "2" "${total_rows}"

rollup="$(timing_xs_aggregate 0)"
xs_walltime="$(jq -r '.walltime_s // 0' <<<"${rollup}")"
assert_eq "xs sum across distinct sessions" "102" "${xs_walltime}"

# The dedup rewrite and append must be one lock transaction. Distinct
# concurrent Stop hooks previously could both rewrite from the same snapshot
# and lose a peer's row even though the later cap itself was locked.
for _cw in $(seq 1 20); do
  (
    SESSION_ID="concurrent-summary-${_cw}"
    timing_record_session_summary '{"walltime_s":5,"prompt_count":1,"tokens_main_out":1}'
  ) &
done
wait
assert_eq "concurrent summary transactions lose no rows" "22" \
  "$(wc -l < "${xs_log}" | tr -d '[:space:]')"
assert_eq "concurrent summary ledger remains valid JSONL" "22" \
  "$(jq -c . "${xs_log}" 2>/dev/null | wc -l | tr -d '[:space:]')"

# A resumed target carries a cumulative checkpoint.  Its locked replacement
# must remove every validated source-chain row in the same transaction or
# inherited tokens are counted once under an ancestor and again inside the
# final owner.  This block covers both normal multi-hop replacement and an
# intermediate that dies before it ever writes a global summary.
SESSION_ID="resume-source-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":10,"prompt_count":1,"tokens_main_out":100,"stale_reviewer_count":2}'
printf '{"resume_transferred_to":"resume-target-summary"}\n' \
  > "${STATE_ROOT}/resume-source-summary/session_state.json"
# A late Stop from the now-dormant source cannot republish a newer checkpoint
# after the transfer fence lands.  The target's cumulative row will replace
# the original source checkpoint below.
timing_record_session_summary \
  '{"walltime_s":99,"prompt_count":9,"tokens_main_out":999,"stale_reviewer_count":9}'
assert_eq "transferred source cannot republish a checkpoint" "100" \
  "$(jq -sr '[.[] | select(.session_id == "resume-source-summary") | .tokens_main_out] | first // 0' "${xs_log}")"
SESSION_ID="resume-target-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{"resume_source_session_id":"resume-source-summary"}\n' \
  > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":15,"prompt_count":2,"tokens_main_out":150,"stale_reviewer_count":3}'
assert_eq "resume summary removes immediate source row" "0" \
  "$(jq -sr '[.[] | select(.session_id == "resume-source-summary")] | length' "${xs_log}")"
assert_eq "resume summary retains one cumulative target row" "1" \
  "$(jq -sr '[.[] | select(.session_id == "resume-target-summary" and .tokens_main_out == 150 and .stale_reviewer_count == 3)] | length' "${xs_log}")"
assert_eq "resume source tokens counted exactly once under target" "150" \
  "$(jq -sr '[.[] | select(.session_id == "resume-source-summary" or .session_id == "resume-target-summary") | (.tokens_main_out // 0)] | add // 0' "${xs_log}")"

tmp_resume_state="${STATE_ROOT}/resume-target-summary/session_state.json.tmp"
jq '.resume_transferred_to = "resume-third-summary"' \
  "${STATE_ROOT}/resume-target-summary/session_state.json" > "${tmp_resume_state}"
mv "${tmp_resume_state}" "${STATE_ROOT}/resume-target-summary/session_state.json"
SESSION_ID="resume-third-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{"resume_source_session_id":"resume-target-summary"}\n' \
  > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":20,"prompt_count":3,"tokens_main_out":175,"stale_reviewer_count":4}'
assert_eq "multi-hop resume removes immediate prior owner" "0" \
  "$(jq -sr '[.[] | select(.session_id == "resume-target-summary")] | length' "${xs_log}")"
assert_eq "multi-hop resume has one cumulative chain owner" "1" \
  "$(jq -sr '[.[] | select(.session_id == "resume-third-summary" and .tokens_main_out == 175)] | length' "${xs_log}")"

# Intermediate B may be killed by StopFailure before it ever records a global
# timing row.  C still has to remove A through the validated A→B→C state chain.
SESSION_ID="nointermediate-source-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":8,"prompt_count":1,"tokens_main_out":80}'
printf '{"resume_transferred_to":"nointermediate-middle-summary"}\n' \
  > "${STATE_ROOT}/nointermediate-source-summary/session_state.json"
mkdir -p "${STATE_ROOT}/nointermediate-middle-summary"
printf '%s\n' \
  '{"resume_source_session_id":"nointermediate-source-summary","resume_transferred_to":"nointermediate-final-summary"}' \
  > "${STATE_ROOT}/nointermediate-middle-summary/session_state.json"
SESSION_ID="nointermediate-final-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{"resume_source_session_id":"nointermediate-middle-summary"}\n' \
  > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":12,"prompt_count":2,"tokens_main_out":120}'
assert_eq "multi-hop without intermediate summary removes oldest owner" "0" \
  "$(jq -sr '[.[] | select(.session_id == "nointermediate-source-summary")] | length' "${xs_log}")"
assert_eq "multi-hop without intermediate summary leaves one cumulative row" "1" \
  "$(jq -sr '[.[] | select(.session_id == "nointermediate-final-summary" and .tokens_main_out == 120)] | length' "${xs_log}")"

# State TTL can delete A before C publishes its cumulative summary. Durable
# versioned ancestry on C must still retire A's older global row even though
# no source directory remains available for the live fence walk.
SESSION_ID="expired-ancestor-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":7,"prompt_count":1,"tokens_main_out":70}'
rm -rf "${STATE_ROOT}/expired-ancestor-summary"
SESSION_ID="ttl-surviving-final-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '%s\n' \
  '{"resume_ancestry_version":1,"resume_ancestor_session_ids":["expired-ancestor-summary","expired-ancestor-summary","../invalid"],"resume_source_session_id":"missing-middle-summary"}' \
  > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":11,"prompt_count":2,"tokens_main_out":110}'
assert_eq "durable ancestry removes summary after source-state TTL" "0" \
  "$(jq -sr '[.[] | select(.session_id == "expired-ancestor-summary")] | length' "${xs_log}")"
assert_eq "TTL resume chain leaves exactly one cumulative owner" "1" \
  "$(jq -sr '[.[] | select(.session_id == "ttl-surviving-final-summary" and .tokens_main_out == 110)] | length' "${xs_log}")"

SESSION_ID="protected-unrelated-summary"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":20}'
SESSION_ID="forged-resume-target"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{"resume_source_session_id":"protected-unrelated-summary","resume_ancestor_session_ids":["protected-unrelated-summary"]}\n' \
  > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":30}'
assert_eq "unfenced resume provenance cannot erase unrelated timing row" "1" \
  "$(jq -sr '[.[] | select(.session_id == "protected-unrelated-summary")] | length' "${xs_log}")"

# A causality-rejected review is economically meaningful even if token
# tracking is disabled or no usage-bearing transcript rows were available.
# It must therefore survive the same short-session presentation floor.
SESSION_ID="stale-review-short-session"
timing_record_session_summary '{"walltime_s":1,"prompt_count":0,"stale_reviewer_count":1}'
assert_eq "stale-review-only short session retained" "1" \
  "$(jq -sr --arg sid "${SESSION_ID}" '[.[] | select(.session_id == $sid and .stale_reviewer_count == 1)] | length' "${xs_log}" 2>/dev/null)"
SESSION_ID="timing-test-session"  # restore

# ----------------------------------------------------------------------
printf 'Test 18: TTL prune drops rows older than retain_days (real sweep path)\n'
# Exercise the actual TTL block inside common.sh's sweep_stale_sessions
# function. Earlier rev re-implemented the prune logic inline; that left
# silent-drift risk if common.sh's filter expression changed. This rev
# clears the daily-marker so the sweep runs, populates the cross-session
# log with one fresh + one stale row, sets the retention env var, and
# asserts the real code path drops the stale row.
rm -f "${xs_log}"
rm -f "${STATE_ROOT}/.last_sweep"  # force the daily-gated sweep to run
now_ts="$(now_epoch)"
fresh_ts=$(( now_ts - 5 * 86400 ))
stale_ts=$(( now_ts - 31 * 86400 ))
jq -nc --argjson ts "${fresh_ts}" --arg sid "fresh-session" \
  '{ts:$ts,session:$sid,project_key:"p",walltime_s:50}' >> "${xs_log}"
jq -nc --argjson ts "${stale_ts}" --arg sid "stale-session" \
  '{ts:$ts,session:$sid,project_key:"p",walltime_s:99}' >> "${xs_log}"

OMC_TIME_TRACKING_XS_RETAIN_DAYS=30
sweep_stale_sessions

remaining="$(wc -l < "${xs_log}" | tr -d '[:space:]')"
assert_eq "stale row pruned by real sweep" "1" "${remaining}"
# v1.31.0 Wave 4: tolerate both old `.session` and new `.session_id`
# field names (the test seed line 402-404 still writes `.session` for
# this particular fixture; the helper itself writes `.session_id`).
surviving_session="$(jq -r '(.session_id // .session)' "${xs_log}")"
assert_eq "fresh row survived real sweep" "fresh-session" "${surviving_session}"

# ----------------------------------------------------------------------
printf 'Test 19a: prompt_seq slice isolates a single prompt\n'
reset_log
SESSION_ID="timing-test-session"
# Prompt 100: 1 Bash call, 1s
timing_append_prompt_start 100
timing_append_start "Bash" "" "" 100
advance_test_epoch
timing_append_end "Bash" "" 100
timing_append_prompt_end 100 1
# Prompt 101: 2 Read calls + 1 Agent call
timing_append_prompt_start 101
timing_append_start "Read" "" "" 101
timing_append_end "Read" "" 101
timing_append_start "Agent" "" "metis" 101
advance_test_epoch
timing_append_end "Agent" "" 101
timing_append_prompt_end 101 2

# Whole-session aggregate sees both prompts
agg_all="$(timing_aggregate "$(timing_log_path)")"
prompt_count_all="$(jq -r '.prompt_count // 0' <<<"${agg_all}")"
assert_eq "whole-session sees both prompts" "2" "${prompt_count_all}"

# Slice for prompt 101 sees only its calls
agg_101="$(timing_aggregate "$(timing_log_path)" "101")"
prompt_count_101="$(jq -r '.prompt_count // 0' <<<"${agg_101}")"
assert_eq "slice sees one prompt" "1" "${prompt_count_101}"
bash_in_slice="$(jq -r '.tool_breakdown.Bash // "missing"' <<<"${agg_101}")"
assert_eq "slice excludes other-prompt Bash" "missing" "${bash_in_slice}"
metis_in_slice="$(jq -r '.agent_breakdown.metis // 0' <<<"${agg_101}")"
assert_ge "slice includes own Agent" "1" "${metis_in_slice}"

# timing_latest_finalized_prompt_seq returns the highest finalized seq
latest="$(timing_latest_finalized_prompt_seq "$(timing_log_path)")"
assert_eq "latest finalized prompt detected" "101" "${latest}"
printf '%s\n' \
  '{"kind":"prompt_end","ts":999,"prompt_seq":9999,"duration_s":"bad"}' \
  '{"kind":"prompt_end","prompt_seq":10000,"duration_s":1}' \
  '{"kind":"prompt_end","ts":999,"prompt_seq":10001,"duration_s":1}' \
  '{"kind":"prompt_end","ts":999,"prompt_seq":10002,"duration_s":1}' \
  '{"kind":"prompt_start","ts":1000,"prompt_seq":10002}' \
  >>"$(timing_log_path)"
assert_eq "malformed, orphaned, or end-before-start boundaries cannot replace the latest finalized prompt" \
  "101" "$(timing_latest_finalized_prompt_seq "$(timing_log_path)")"

# ----------------------------------------------------------------------
printf 'Test 19b: aggregator emits call-count maps\n'
reset_log
timing_append_prompt_start 200
timing_append_start "Read" "" "" 200
timing_append_end "Read" "" 200
timing_append_start "Read" "" "" 200
timing_append_end "Read" "" 200
timing_append_start "Bash" "" "" 200
advance_test_epoch
timing_append_end "Bash" "" 200
timing_append_prompt_end 200 1

agg="$(timing_aggregate "$(timing_log_path)")"
read_calls="$(jq -r '.tool_calls.Read // 0' <<<"${agg}")"
bash_calls="$(jq -r '.tool_calls.Bash // 0' <<<"${agg}")"
assert_eq "Read call count" "2" "${read_calls}"
assert_eq "Bash call count" "1" "${bash_calls}"

# ----------------------------------------------------------------------
printf 'Test 19: unrelated or expired blocks do NOT suppress a successful Stop\n'
# A current timestamp is insufficient: the attempt identity must match.
now_ts="$(date +%s)"
jq -nc --arg sid "${block_session}" --argjson now "${now_ts}" \
  '{session_id:$sid,prompt_seq:"1",stop_guard_attempt_seq:"8",last_stop_block_attempt_seq:"7",last_stop_block_ts:($now|tostring)}' \
  > "${block_dir}/session_state.json"
unrelated_out="$(STATE_ROOT="${block_root}" HOME="${HOME}" OMC_TIME_CARD_MIN_SECONDS=0 \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${block_payload}" 2>&1 || true)"
case "${unrelated_out}" in
  *"Time breakdown"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: unrelated recent block suppressed the card:\n%s\n' "${unrelated_out}" >&2; fail=$((fail + 1)) ;;
esac

# Even an exact sequence is rejected after the 300-second compatibility bound.
jq -nc --arg sid "${block_session}" --argjson old "$(( now_ts - 301 ))" \
  '{session_id:$sid,prompt_seq:"1",stop_guard_attempt_seq:"9",last_stop_block_attempt_seq:"9",last_stop_block_ts:($old|tostring)}' \
  > "${block_dir}/session_state.json"
expired_out="$(STATE_ROOT="${block_root}" HOME="${HOME}" OMC_TIME_CARD_MIN_SECONDS=0 \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${block_payload}" 2>&1 || true)"
case "${expired_out}" in
  *"Time breakdown"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: expired exact block suppressed the card:\n%s\n' "${expired_out}" >&2; fail=$((fail + 1)) ;;
esac
rm -rf "${block_root}"

# ----------------------------------------------------------------------
printf 'Test 20: timing_format_full renders polished epilogue scaffold\n'
# Polished epilogue must include: ─── title rule, stacked-bar legend with
# pct breakdown, per-bucket rows, residual note, and closing insight when
# any rule fires. Substring-grade so cosmetic char tweaks don't churn tests.
reset_log
timing_append_prompt_start 300
timing_append_start "Agent" "" "excellence-reviewer" 300
advance_test_epoch
timing_append_end "Agent" "" 300
timing_append_start "Bash" "" "" 300
advance_test_epoch
timing_append_end "Bash" "" 300
timing_append_prompt_end 300 60
agg="$(timing_aggregate "$(timing_log_path)")"
out="$(timing_format_full "${agg}" "Time breakdown")"

case "${out}" in
  *"─── Time breakdown ───"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: title rule missing\n%s\n' "${out}" >&2; fail=$((fail + 1)) ;;
esac
case "${out}" in
  *"agents "*"%"*"tools "*"%"*"idle "*"%"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: stacked-bar legend missing\n%s\n' "${out}" >&2; fail=$((fail + 1)) ;;
esac
case "${out}" in
  *"agents"*"excellence-reviewer"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: per-bucket agent row missing\n%s\n' "${out}" >&2; fail=$((fail + 1)) ;;
esac
case "${out}" in
  *"residual: model thinking"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: residual hint missing\n%s\n' "${out}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 21: stacked bar uses three distinct fill chars\n'
# Visual sanity — the three segment glyphs (█ ▒ ░) must each appear when
# all three buckets carry weight, otherwise the bar collapses into a
# single-band hard-to-read strip.
case "${out}" in
  *█*▒*░*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: stacked bar missing one or more segment chars\n%s\n' "${out}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 22: insight engine — anomaly outranks every other rule\n'
# Orphan/active_pending takes priority over every other signal so a
# user staring at incomplete aggregates always sees the anomaly first.
# Even on a turn where excellence-reviewer would otherwise trigger the
# dominance rule (80% of walltime), the in-flight signal must surface.
agg_anomaly='{"walltime_s":120,"agent_total_s":80,"tool_total_s":20,"idle_model_s":20,"agent_breakdown":{"excellence-reviewer":80},"tool_breakdown":{"Bash":20},"tool_calls":{"Bash":3},"agent_calls":{"excellence-reviewer":1},"prompt_count":1,"active_pending":1,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_anomaly}")"
case "${insight}" in
  *"Heads up"*"in-flight"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: anomaly insight expected, got: %q\n' "${insight}" >&2; fail=$((fail + 1)) ;;
esac
# Dominance message must NOT have fired despite excellence-reviewer hitting 67%.
case "${insight}" in
  *"deep specialist run"*) printf '  FAIL: dominance leaked despite anomaly\n' >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 23: insight engine — single-agent dominance\n'
agg_dom='{"walltime_s":100,"agent_total_s":80,"tool_total_s":10,"idle_model_s":10,"agent_breakdown":{"excellence-reviewer":80},"tool_breakdown":{"Bash":10},"tool_calls":{"Bash":1},"agent_calls":{"excellence-reviewer":1},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_dom}")"
case "${insight}" in
  *"excellence-reviewer carried 80%"*"deep specialist run"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: dominance insight expected, got: %q\n' "${insight}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 24: insight engine — idle-heavy reassurance\n'
# Idle-heavy on a long turn should reassure ("depth, not stalling"), not
# alarm. Triggers only when walltime >= 30 so quick clarifications aren'\''t
# given a hollow reassurance.
agg_idle='{"walltime_s":120,"agent_total_s":10,"tool_total_s":10,"idle_model_s":100,"agent_breakdown":{"oracle":10},"tool_breakdown":{"Read":10},"tool_calls":{"Read":1},"agent_calls":{"oracle":1},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_idle}")"
case "${insight}" in
  *"thinking"*"depth, not stalling"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: idle-heavy insight expected, got: %q\n' "${insight}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 25: insight engine — tool-churn parallelization hint\n'
agg_churn='{"walltime_s":120,"agent_total_s":0,"tool_total_s":50,"idle_model_s":70,"agent_breakdown":{},"tool_breakdown":{"Read":30,"Grep":20},"tool_calls":{"Read":25,"Grep":10},"agent_calls":{},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_churn}")"
case "${insight}" in
  *"Heavy tool"*"35 total calls"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: churn insight expected, got: %q\n' "${insight}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 26: insight engine — diversity fun fact\n'
agg_div='{"walltime_s":40,"agent_total_s":30,"tool_total_s":5,"idle_model_s":5,"agent_breakdown":{"metis":10,"oracle":8,"excellence-reviewer":7,"quality-planner":5},"tool_breakdown":{"Bash":5},"tool_calls":{"Bash":1},"agent_calls":{"metis":1,"oracle":1,"excellence-reviewer":1,"quality-planner":1},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_div}")"
case "${insight}" in
  *"Diverse turn"*"4 distinct subagents"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: diversity insight expected, got: %q\n' "${insight}" >&2; fail=$((fail + 1)) ;;
esac

# Same data, scope=window — wording must shift.
insight_w="$(timing_generate_insight "${agg_div}" "window")"
case "${insight_w}" in
  *"Diverse window"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: window-scoped insight expected, got: %q\n' "${insight_w}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 27: insight engine — clean-run reassurance for substantive turns\n'
# Substantive turn (>=60s) where no other rule fires must still surface
# something positive so the user doesn'\''t see a silent epilogue.
agg_clean='{"walltime_s":80,"agent_total_s":30,"tool_total_s":20,"idle_model_s":30,"agent_breakdown":{"a":15,"b":15},"tool_breakdown":{"Bash":15,"Read":5},"tool_calls":{"Bash":3,"Read":4},"agent_calls":{"a":1,"b":1},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_clean}")"
case "${insight}" in
  *"Clean run"*"no orphans"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: reassurance insight expected, got: %q\n' "${insight}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 28: insight engine — silent on trivial turn\n'
# A 4-second nothing-burger must produce no insight (no rule fires under
# the noise floor). The Stop hook'\''s 5s gate keeps this offscreen anyway,
# but the formatter contract is "empty insight → no line printed".
agg_trivial='{"walltime_s":4,"agent_total_s":0,"tool_total_s":1,"idle_model_s":3,"agent_breakdown":{},"tool_breakdown":{"Read":1},"tool_calls":{"Read":1},"agent_calls":{},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
insight="$(timing_generate_insight "${agg_trivial}")"
assert_eq "trivial turn yields no insight" "" "${insight}"

# ----------------------------------------------------------------------
printf 'Test 29: stop-time-summary emits multi-line epilogue above 5s floor\n'
# End-to-end: real Stop hook script must produce JSON with multi-line
# `systemMessage` when walltime >= 5s. Below 5s, no JSON. This is the
# always-show contract — every meaningful turn surfaces the polished card.
#
# Visible-card schema regression net: the time card must use top-level
# `systemMessage` on every supported client. Modern Stop additionalContext is
# model-only continuation feedback owned by stop-dispatch.sh, not the card
# transport. Both the positive `systemMessage` assertion and the negative
# `hookSpecificOutput` assertion remain required for this script.
hook_root="$(mktemp -d)"
hook_session="hook-test-session"
hook_session_dir="${hook_root}/${hook_session}"
mkdir -p "${hook_session_dir}"
hook_log="${hook_session_dir}/timing.jsonl"

# Synthesize a 12s, agent+tool aggregate via direct row append (no live
# wall-clock dependency — sleep would slow tests, hand-crafted rows match
# what the live capture writes).
now_ts="$(now_epoch)"
jq -nc --argjson ts "${now_ts}" --argjson seq 1 \
  '{kind:"prompt_start",ts:$ts,prompt_seq:$seq}' >> "${hook_log}"
jq -nc --argjson ts "${now_ts}" --arg tool "Agent" --arg sub "metis" --argjson seq 1 \
  '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$seq,subagent:$sub}' >> "${hook_log}"
jq -nc --argjson ts "$(( now_ts + 8 ))" --arg tool "Agent" --argjson seq 1 \
  '{kind:"end",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook_log}"
jq -nc --argjson ts "$(( now_ts + 8 ))" --arg tool "Bash" --argjson seq 1 \
  '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --arg tool "Bash" --argjson seq 1 \
  '{kind:"end",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --argjson seq 1 --argjson dur 12 \
  '{kind:"prompt_end",ts:$ts,prompt_seq:$seq,duration_s:$dur}' >> "${hook_log}"

# Persist prompt_seq state so the hook script doesn't try to finalize again.
jq -nc --arg sid "${hook_session}" '{prompt_seq:"1",session_id:$sid}' \
  > "${hook_session_dir}/session_state.json"

# Pipe in the hook payload.
hook_payload="$(jq -nc --arg sid "${hook_session}" '{session_id:$sid}')"
hook_out="$(STATE_ROOT="${hook_root}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${hook_payload}" 2>&1 || true)"
# Use python to parse the multi-line JSON value (jq 1.7's read of JSON
# with embedded newlines on stdin can be brittle on some platforms).
ctx="$(printf '%s' "${hook_out}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("systemMessage",""))' \
  2>/dev/null || printf '')"
case "${ctx}" in
  *"─── Time breakdown ───"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: hook epilogue missing title rule:\n%s\n' "${hook_out}" >&2; fail=$((fail + 1)) ;;
esac
case "${ctx}" in
  *"agents"*"%"*"tools"*"%"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: hook epilogue missing stacked-bar legend:\n%s\n' "${hook_out}" >&2; fail=$((fail + 1)) ;;
esac
# Multi-line content carries newlines — must be encoded in the JSON
case "${ctx}" in
  *$'\n'*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: epilogue not multi-line:\n%s\n' "${ctx}" >&2; fail=$((fail + 1)) ;;
esac
# Schema regression net: hookSpecificOutput is silently dropped on Stop.
# Asserting its absence catches a future revert that would re-ship the
# v1.24.0 / v1.25.0 silent-drop bug.
case "${hook_out}" in
  *'"hookSpecificOutput"'*)
    printf '  FAIL: Stop hook output uses hookSpecificOutput (silently dropped); use systemMessage:\n%s\n' "${hook_out}" >&2
    fail=$((fail + 1))
    ;;
  *)
    pass=$((pass + 1))
    ;;
esac

# ----------------------------------------------------------------------
printf 'Test 30: stop-time-summary suppressed under 5s floor\n'
# Build a fresh 3s aggregate — no hook output should be produced.
sub_root="$(mktemp -d)"
sub_session="sub5-session"
sub_dir="${sub_root}/${sub_session}"
mkdir -p "${sub_dir}"
sub_log="${sub_dir}/timing.jsonl"
now_ts="$(now_epoch)"
jq -nc --argjson ts "${now_ts}" --argjson seq 1 \
  '{kind:"prompt_start",ts:$ts,prompt_seq:$seq}' >> "${sub_log}"
jq -nc --argjson ts "$(( now_ts + 3 ))" --argjson seq 1 --argjson dur 3 \
  '{kind:"prompt_end",ts:$ts,prompt_seq:$seq,duration_s:$dur}' >> "${sub_log}"
jq -nc --arg sid "${sub_session}" '{prompt_seq:"1",session_id:$sid}' \
  > "${sub_dir}/session_state.json"

sub_payload="$(jq -nc --arg sid "${sub_session}" '{session_id:$sid}')"
sub_out="$(STATE_ROOT="${sub_root}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${sub_payload}" 2>&1 || true)"
assert_eq "no output under noise floor" "" "${sub_out}"
rm -rf "${sub_root}"
rm -rf "${hook_root}"

# ----------------------------------------------------------------------
printf 'Test 31: bucket renders when total==0 but call counts > 0\n'
# Regression net for the "sub-second tools vanish" defect: when a turn
# has only Read/Grep/Edit calls (each <1s, all rounding to 0s), the
# tools row must still appear in the epilogue because the call counts
# are useful exploration-heavy signal. Without this contract a 30-call
# Read-heavy exploration turn would silently print no tool data.
agg_subsec='{"walltime_s":60,"agent_total_s":0,"tool_total_s":0,"idle_model_s":60,"agent_breakdown":{},"tool_breakdown":{"Read":0,"Grep":0,"Edit":0},"tool_calls":{"Read":12,"Grep":5,"Edit":2},"agent_calls":{},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
out_subsec="$(timing_format_full "${agg_subsec}" "Time breakdown")"
case "${out_subsec}" in
  *"tools"*"Read"*"(12)"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: tools row collapsed despite 12 Read calls\n%s\n' "${out_subsec}" >&2; fail=$((fail + 1)) ;;
esac
case "${out_subsec}" in
  *"Grep"*"(5)"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: Grep sub-row missing\n%s\n' "${out_subsec}" >&2; fail=$((fail + 1)) ;;
esac

# Inverse — when both total==0 AND call counts are missing/zero, the
# row stays suppressed (no spurious "tools 0s (0%)" line under an
# all-idle turn). The bucket row begins with two-space indent + label,
# so check the row-shape pattern directly (substring matching against
# bare "tools" would false-trigger on the legend line "tools 0%").
agg_idle_only='{"walltime_s":30,"agent_total_s":0,"tool_total_s":0,"idle_model_s":30,"agent_breakdown":{},"tool_breakdown":{},"tool_calls":{},"agent_calls":{},"prompt_count":1,"active_pending":0,"orphan_end_count":0}'
out_idle_only="$(timing_format_full "${agg_idle_only}" "Time breakdown")"
# Bucket rows use a 13-char left-padded label, so a "tools" row begins
# with `  tools` followed by trailing spaces, never the legend pattern
# `tools 0%` (which appears mid-line).
if grep -qE '^  tools +' <<<"${out_idle_only}"; then
  printf '  FAIL: tools bucket row leaked with zero calls\n%s\n' "${out_idle_only}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 32: anomaly wording distinguishes killed vs in-flight\n'
# orphan_end_count alone → "killed mid-flight"; active_pending alone
# → "still in-flight" (don'\''t accuse rate-limiter of killing a call
# that may genuinely still be running). Both → split sentence.
agg_killed='{"walltime_s":10,"agent_total_s":0,"tool_total_s":1,"idle_model_s":9,"agent_breakdown":{},"tool_breakdown":{"Bash":1},"tool_calls":{"Bash":1},"agent_calls":{},"prompt_count":1,"active_pending":0,"orphan_end_count":1}'
ins_killed="$(timing_generate_insight "${agg_killed}")"
case "${ins_killed}" in
  *"killed mid-flight"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: killed wording missing: %q\n' "${ins_killed}" >&2; fail=$((fail + 1)) ;;
esac

agg_inflight='{"walltime_s":10,"agent_total_s":0,"tool_total_s":1,"idle_model_s":9,"agent_breakdown":{},"tool_breakdown":{"Bash":1},"tool_calls":{"Bash":1},"agent_calls":{},"prompt_count":1,"active_pending":1,"orphan_end_count":0}'
ins_inflight="$(timing_generate_insight "${agg_inflight}")"
case "${ins_inflight}" in
  *"still in-flight"*"next epilogue"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: in-flight wording missing: %q\n' "${ins_inflight}" >&2; fail=$((fail + 1)) ;;
esac
case "${ins_inflight}" in
  *"killed"*) printf '  FAIL: in-flight insight wrongly says "killed": %q\n' "${ins_inflight}" >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

agg_both='{"walltime_s":10,"agent_total_s":0,"tool_total_s":1,"idle_model_s":9,"agent_breakdown":{},"tool_breakdown":{"Bash":1},"tool_calls":{"Bash":1},"agent_calls":{},"prompt_count":1,"active_pending":2,"orphan_end_count":3}'
ins_both="$(timing_generate_insight "${agg_both}")"
case "${ins_both}" in
  *"3 tool calls killed"*"2 still in-flight"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: split-anomaly wording missing: %q\n' "${ins_both}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 33: orphan-only fall-through renders when walltime == 0\n'
# A session killed before any prompt finalized has walltime_s==0. Manual
# /ulw-time must still surface the in-flight signal — empty output is
# unhelpful exactly when feedback would be most useful.
agg_orphan_only='{"walltime_s":0,"agent_total_s":0,"tool_total_s":0,"idle_model_s":0,"agent_breakdown":{},"tool_breakdown":{},"tool_calls":{},"agent_calls":{},"prompt_count":0,"active_pending":2,"orphan_end_count":0}'
out_oo="$(timing_format_full "${agg_oo:-${agg_orphan_only}}" "Time breakdown")"
case "${out_oo}" in
  *"no finalized prompts yet"*"unfinished"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: orphan-only render expected; got:\n%s\n' "${out_oo}" >&2; fail=$((fail + 1)) ;;
esac

# Inverse — walltime==0 AND no orphans/active = clean empty session
# (newly created, no work yet). Must produce no output.
agg_clean_empty='{"walltime_s":0,"agent_total_s":0,"tool_total_s":0,"idle_model_s":0,"agent_breakdown":{},"tool_breakdown":{},"tool_calls":{},"agent_calls":{},"prompt_count":0,"active_pending":0,"orphan_end_count":0}'
out_ce="$(timing_format_full "${agg_clean_empty}" "Time breakdown")"
assert_eq "clean empty session yields no output" "" "${out_ce}"

# ----------------------------------------------------------------------
printf 'Test 34: cross-session header pluralizes single session/prompt\n'
# Single-session, single-prompt window must read "1 session · 1 prompt",
# not the awkward "1 sessions · 1 prompts".
xs_log_t34="${HOME}/.claude/quality-pack/timing.jsonl"
mkdir -p "$(dirname "${xs_log_t34}")"
rm -f "${xs_log_t34}"
jq -nc --arg sid "solo-session" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$sid,project_key:"p",walltime_s:120,agent_total_s:60,
    tool_total_s:30,idle_model_s:30,
    agent_breakdown:{"oracle":60},
    tool_breakdown:{"Bash":30},
    prompt_count:1}' >> "${xs_log_t34}"

solo_out="$(STATE_ROOT="${STATE_ROOT}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/show-time.sh" week 2>&1 || true)"
case "${solo_out}" in
  *"1 session · 1 prompt"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: singular header pluralization wrong:\n%s\n' "${solo_out}" >&2; fail=$((fail + 1)) ;;
esac

# Multi-session must still pluralize correctly.
jq -nc --arg sid "second-session" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$sid,project_key:"p",walltime_s:60,agent_total_s:30,
    tool_total_s:15,idle_model_s:15,
    agent_breakdown:{"metis":30},
    tool_breakdown:{"Read":15},
    prompt_count:3}' >> "${xs_log_t34}"

multi_out="$(STATE_ROOT="${STATE_ROOT}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/show-time.sh" week 2>&1 || true)"
case "${multi_out}" in
  *"2 sessions · 4 prompts"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: plural header wrong:\n%s\n' "${multi_out}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 35: cross-session "Top agents/tools" sections suppressed when empty\n'
# An idle-only cross-session row has empty agent_breakdown and
# tool_breakdown. The section headings must not print as orphan headers
# above zero rows — that is worse UX than printing nothing.
xs_idle_log="${HOME}/.claude/quality-pack/timing.jsonl"
rm -f "${xs_idle_log}"
jq -nc --arg sid "idle-session" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$sid,project_key:"p",walltime_s:30,agent_total_s:0,
    tool_total_s:0,idle_model_s:30,
    agent_breakdown:{},tool_breakdown:{},
    prompt_count:1}' >> "${xs_idle_log}"

idle_out="$(STATE_ROOT="${STATE_ROOT}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/show-time.sh" week 2>&1 || true)"
case "${idle_out}" in
  *"Top agents by time"*) printf '  FAIL: empty agents section header leaked\n%s\n' "${idle_out}" >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac
case "${idle_out}" in
  *"Top tools by time"*) printf '  FAIL: empty tools section header leaked\n%s\n' "${idle_out}" >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 36: aggregator exposes per-prompt durations as prompts_seq\n'
# Per-prompt sparkline needs the per-prompt walltime list; the
# aggregate must expose it. Without this, downstream sparkline
# rendering has nothing to read.
reset_log
for ps in 50 51 52; do
  case "$ps" in
    50) dur=2;;
    51) dur=8;;
    52) dur=3;;
  esac
  timing_append_prompt_start "$ps"
  timing_append_start "Read" "" "" "$ps"
  timing_append_end "Read" "" "$ps"
  timing_append_prompt_end "$ps" "$dur"
done
agg36="$(timing_aggregate "$(timing_log_path)")"
seq_len="$(jq -r '.prompts_seq | length' <<<"${agg36}" 2>/dev/null)"
assert_eq "prompts_seq has 3 entries" "3" "${seq_len}"
durs="$(jq -r '[.prompts_seq[].dur] | join(",")' <<<"${agg36}" 2>/dev/null)"
assert_eq "per-prompt durations preserved" "2,8,3" "${durs}"

# ----------------------------------------------------------------------
printf 'Test 37: sparkline renders for multi-prompt session\n'
# Multi-prompt session must produce a sparkline line; single-prompt
# session must NOT (nothing to compare against).
out_multi="$(timing_format_full "${agg36}" "Time breakdown")"
case "${out_multi}" in
  *"prompts: "*"  (one cell per prompt"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: sparkline missing for multi-prompt session\n%s\n' "${out_multi}" >&2; fail=$((fail + 1)) ;;
esac

# Verify the sparkline string contains exactly 3 cells (one per prompt).
# v1.31.0 Wave 3: pin LC_ALL=en_US.UTF-8 so `wc -m` returns char count
# uniformly across BSD coreutils (macOS) and GNU coreutils (Linux). On
# environments where the default locale is C, `wc -m` returns BYTE
# count and a 3-cell UTF-8 sparkline `▁▂▃` reports as 9, breaking the
# assertion. The locale pin is also documented as the canonical
# pattern in lib/timing.sh `timing_display_width`.
spark_line="$(grep -E '^  prompts: ' <<<"${out_multi}" | head -1)"
spark_chars="$(printf '%s' "${spark_line}" | sed -E 's/^  prompts: ([▁▂▃▄▅▆▇█]+).*/\1/' | LC_ALL=en_US.UTF-8 wc -m | tr -d '[:space:]')"
# wc -m on 3 multi-byte chars + trailing newline = 4. Allow either 3 or 4.
case "${spark_chars}" in
  3|4) pass=$((pass + 1)) ;;
  *) printf '  FAIL: expected 3-char sparkline, got %s chars in: %q\n' "${spark_chars}" "${spark_line}" >&2; fail=$((fail + 1)) ;;
esac

# Single-prompt session must NOT show sparkline (nothing meaningful to plot).
agg_single='{"walltime_s":30,"agent_total_s":0,"tool_total_s":1,"idle_model_s":29,"agent_breakdown":{},"tool_breakdown":{"Bash":1},"tool_calls":{"Bash":1},"agent_calls":{},"prompt_count":1,"prompts_seq":[{"ps":1,"dur":30}],"active_pending":0,"orphan_end_count":0}'
out_single="$(timing_format_full "${agg_single}" "Time breakdown")"
case "${out_single}" in
  *"prompts: "*) printf '  FAIL: sparkline leaked into single-prompt view\n%s\n' "${out_single}" >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 38: sparkline normalizes by max — heaviest prompt gets full block\n'
# 4 prompts: 10s, 100s, 5s, 50s. Max = 100. The 100s prompt MUST be U+2588 (█).
agg_norm='{"walltime_s":165,"agent_total_s":0,"tool_total_s":4,"idle_model_s":161,"agent_breakdown":{},"tool_breakdown":{"Bash":4},"tool_calls":{"Bash":4},"agent_calls":{},"prompt_count":4,"prompts_seq":[{"ps":1,"dur":10},{"ps":2,"dur":100},{"ps":3,"dur":5},{"ps":4,"dur":50}],"active_pending":0,"orphan_end_count":0}'
spark_norm="$(_timing_sparkline "${agg_norm}")"
case "${spark_norm}" in
  *█*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: heaviest prompt did not render as U+2588: %q\n' "${spark_norm}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 39: long subagent name truncated with U+2026 ellipsis\n'
# Real subagent names like `excellence-reviewer` (19 chars) fit within
# 22; long custom subagent types or hyphenated MCP tool names would
# overflow and shift the bar column rightward, breaking alignment.
# Truncate at 21 chars + … so the column stays locked.
agg_long='{"walltime_s":30,"agent_total_s":2,"tool_total_s":0,"idle_model_s":28,"agent_breakdown":{"very-long-subagent-name-overflows-column":2},"tool_breakdown":{},"tool_calls":{},"agent_calls":{"very-long-subagent-name-overflows-column":1},"prompt_count":1,"prompts_seq":[{"ps":1,"dur":30}],"active_pending":0,"orphan_end_count":0}'
out_long="$(timing_format_full "${agg_long}" "Time breakdown")"
case "${out_long}" in
  *"very-long-subagent-na…"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: long name not truncated with U+2026: \n%s\n' "${out_long}" >&2; fail=$((fail + 1)) ;;
esac

# Original full name MUST NOT appear (the truncation is in-place).
case "${out_long}" in
  *"very-long-subagent-name-overflows-column"*) printf '  FAIL: full long name leaked into sub-row\n%s\n' "${out_long}" >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

# Names exactly 22 chars or shorter must NOT be truncated.
agg_short='{"walltime_s":30,"agent_total_s":2,"tool_total_s":0,"idle_model_s":28,"agent_breakdown":{"excellence-reviewer":2},"tool_breakdown":{},"tool_calls":{},"agent_calls":{"excellence-reviewer":1},"prompt_count":1,"prompts_seq":[{"ps":1,"dur":30}],"active_pending":0,"orphan_end_count":0}'
out_short="$(timing_format_full "${agg_short}" "Time breakdown")"
case "${out_short}" in
  *"excellence-reviewer"*"…"*) printf '  FAIL: short name wrongly truncated\n%s\n' "${out_short}" >&2; fail=$((fail + 1)) ;;
  *"excellence-reviewer"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: short name missing entirely\n%s\n' "${out_short}" >&2; fail=$((fail + 1)) ;;
esac

# Test 40: timing_display_width — column-cell-aware width helper
# (v1.31.0 Wave 3 visual-craft F-5 / metis Item 6 portability fix).
printf 'Test 40: timing_display_width returns char count not byte count\n'
# Pure ASCII: 1 byte per char, width should equal char count.
case "$(timing_display_width 'hello')" in
  5) pass=$((pass + 1)) ;;
  *) printf '  FAIL: ASCII width: expected 5, got %s\n' "$(timing_display_width 'hello')" >&2; fail=$((fail + 1)) ;;
esac
# Empty string returns 0.
case "$(timing_display_width '')" in
  0) pass=$((pass + 1)) ;;
  *) printf '  FAIL: empty width: expected 0, got %s\n' "$(timing_display_width '')" >&2; fail=$((fail + 1)) ;;
esac
# 3-char UTF-8 sparkline (9 bytes) returns 3 char-cells. This is the
# canonical T37/byte-vs-char regression net.
spark="▁▂▃"
case "$(timing_display_width "${spark}")" in
  3) pass=$((pass + 1)) ;;
  *) printf '  FAIL: UTF-8 sparkline width: expected 3, got %s on %d-byte input\n' "$(timing_display_width "${spark}")" "${#spark}" >&2; fail=$((fail + 1)) ;;
esac
# Mixed ASCII + multi-byte: 'mcp__测试' is 7 chars (5 ASCII + 2 CJK,
# each CJK = 3 bytes UTF-8). Byte count would be 11.
mixed="mcp__测试"
case "$(timing_display_width "${mixed}")" in
  7) pass=$((pass + 1)) ;;
  *) printf '  FAIL: mixed width: expected 7, got %s on %d-byte input\n' "$(timing_display_width "${mixed}")" "${#mixed}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
# T46 (v1.34.1+ data-lens D-002 follow-up): under parallelism (overhead
# > 0), the per-bucket rendering MUST use the same work-time denominator
# as the top bar. Pre-fix the top bar said "agents 72%" but the per-
# bucket row still showed "1m 20s (133%)" using walltime as divisor —
# directly visible inconsistency. T46 renders the format and asserts
# the per-bucket percentage tracks the top bar's value, NOT walltime.
printf 'Test 46: under parallelism, per-bucket pct uses work-time denom not walltime\n'
agg_par='{"walltime_s":60,"agent_total_s":80,"tool_total_s":30,"idle_model_s":0,"concurrent_overhead_s":50,"prompt_count":1,"agent_breakdown":{"reviewer":80},"tool_breakdown":{"Bash":30},"agent_calls":{"reviewer":1},"tool_calls":{"Bash":1},"active_pending":0,"orphan_end_count":0}'
out_par="$(timing_format_full "${agg_par}" 'Time breakdown')"
# Top bar should show agents 72% (80/110 ≈ 72%). Per-bucket row should
# also show 72%, NOT 133% (which is 80/60).
case "${out_par}" in
  *"agents 72%"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T46 — top bar should show "agents 72%%" under parallelism\n%s\n' "${out_par}" >&2; fail=$((fail + 1)) ;;
esac
case "${out_par}" in
  *"1m 20s (72%)"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T46 — per-bucket row should show "1m 20s (72%%)" not (133%%)\n%s\n' "${out_par}" >&2; fail=$((fail + 1)) ;;
esac
# Insight line should also use the same denom.
case "${out_par}" in
  *"reviewer carried 72%"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T46 — insight line should say "reviewer carried 72%%" not (133%%)\n%s\n' "${out_par}" >&2; fail=$((fail + 1)) ;;
esac
case "${out_par}" in
  *"parallelism saved ~50s"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T46 — overlap disclosure missing\n' >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
# T47 (v1.34.2+ release-reviewer F-1 / F-2): when stop_guard_blocks > 0
# AND session_outcome=skip-released (user explicitly invoked /ulw-skip
# to bypass the gates), the outcome card MUST NOT claim "gates caught
# + resolved" — the gates fired but the user bypassed them, NOT the
# model resolved them. Pre-fix v1.34.1 wrote `released` on the gate-
# skip path, and the outcome-card logic counted both `completed` and
# `released` as positive, producing trust-claim overcounts.
printf 'Test 47: outcome card excludes blocks when session_outcome=skip-released\n'
hook47_root="$(mktemp -d)"
hook47_session="hook-test-47"
hook47_dir="${hook47_root}/${hook47_session}"
mkdir -p "${hook47_dir}"
hook47_log="${hook47_dir}/timing.jsonl"
now_ts="$(now_epoch)"
jq -nc --argjson ts "${now_ts}" --argjson seq 1 '{kind:"prompt_start",ts:$ts,prompt_seq:$seq}' >> "${hook47_log}"
jq -nc --argjson ts "${now_ts}" --arg tool "Bash" --argjson seq 1 '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook47_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --arg tool "Bash" --argjson seq 1 '{kind:"end",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook47_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --argjson seq 1 --argjson dur 12 '{kind:"prompt_end",ts:$ts,prompt_seq:$seq,duration_s:$dur}' >> "${hook47_log}"
# State: 3 stop_guard_blocks fired AND user invoked /ulw-skip to bypass
# (session_outcome=skip-released is the v1.34.2 marker).
jq -nc --arg sid "${hook47_session}" '{prompt_seq:"1",session_id:$sid,stop_guard_blocks:"3",session_outcome:"skip-released"}' > "${hook47_dir}/session_state.json"
hook47_payload="$(jq -nc --arg sid "${hook47_session}" '{session_id:$sid}')"
hook47_out="$(STATE_ROOT="${hook47_root}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${hook47_payload}" 2>&1 || true)"
ctx47="$(printf '%s' "${hook47_out}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("systemMessage",""))' \
  2>/dev/null || printf '')"
case "${ctx47}" in
  *"gates caught + resolved"*|*"gate caught + resolved"*)
    printf '  FAIL: T47 — outcome card claimed "caught + resolved" for skip-released session (overcount defect F-1):\n%s\n' "${ctx47}" >&2
    fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac
# Also positive control: when outcome=completed AND blocks > 0, the
# outcome card SHOULD render the count.
jq -nc --arg sid "${hook47_session}" '{prompt_seq:"1",session_id:$sid,stop_guard_blocks:"2",session_outcome:"completed"}' > "${hook47_dir}/session_state.json"
hook47_out2="$(STATE_ROOT="${hook47_root}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${hook47_payload}" 2>&1 || true)"
ctx47_2="$(printf '%s' "${hook47_out2}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("systemMessage",""))' \
  2>/dev/null || printf '')"
case "${ctx47_2}" in
  *"2 gates caught + resolved"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T47 control — outcome=completed should render "2 gates caught + resolved":\n%s\n' "${ctx47_2}" >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
# T44 (v1.34.1+ product-lens P-004 / trust-accrual): when the session
# state has serendipity_count > 0 OR (resolved gate blocks AND outcome ==
# completed/released), stop-time-summary prepends an "─── Outcome ───"
# line above the time card. When NO signal exists, the line is silent
# (silence is honest when nothing was caught).
printf 'Test 44: stop-time-summary prepends Outcome line when serendipity > 0\n'
hook44_root="$(mktemp -d)"
hook44_session="hook-test-44"
hook44_dir="${hook44_root}/${hook44_session}"
mkdir -p "${hook44_dir}"
hook44_log="${hook44_dir}/timing.jsonl"
now_ts="$(now_epoch)"
# Manufacture a 12s session shape (re-use the T29 pattern).
jq -nc --argjson ts "${now_ts}" --argjson seq 1 '{kind:"prompt_start",ts:$ts,prompt_seq:$seq}' >> "${hook44_log}"
jq -nc --argjson ts "${now_ts}" --arg tool "Bash" --argjson seq 1 '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook44_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --arg tool "Bash" --argjson seq 1 '{kind:"end",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook44_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --argjson seq 1 --argjson dur 12 '{kind:"prompt_end",ts:$ts,prompt_seq:$seq,duration_s:$dur}' >> "${hook44_log}"
# State carries serendipity_count=2 — should produce an Outcome line.
jq -nc --arg sid "${hook44_session}" '{prompt_seq:"1",session_id:$sid,serendipity_count:"2"}' > "${hook44_dir}/session_state.json"
hook44_payload="$(jq -nc --arg sid "${hook44_session}" '{session_id:$sid}')"
hook44_out="$(STATE_ROOT="${hook44_root}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${hook44_payload}" 2>&1 || true)"
ctx44="$(printf '%s' "${hook44_out}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("systemMessage",""))' \
  2>/dev/null || printf '')"
case "${ctx44}" in
  *"─── Outcome ───"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T44 — Outcome line missing when serendipity_count=2\n%s\n' "${ctx44}" >&2; fail=$((fail + 1)) ;;
esac
case "${ctx44}" in
  *"adjacent fix"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T44 — Outcome line did not name "adjacent fix"\n' >&2; fail=$((fail + 1)) ;;
esac

printf 'Test 45: stop-time-summary outcome line is silent when no signal\n'
hook45_root="$(mktemp -d)"
hook45_session="hook-test-45"
hook45_dir="${hook45_root}/${hook45_session}"
mkdir -p "${hook45_dir}"
hook45_log="${hook45_dir}/timing.jsonl"
now_ts="$(now_epoch)"
jq -nc --argjson ts "${now_ts}" --argjson seq 1 '{kind:"prompt_start",ts:$ts,prompt_seq:$seq}' >> "${hook45_log}"
jq -nc --argjson ts "${now_ts}" --arg tool "Bash" --argjson seq 1 '{kind:"start",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook45_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --arg tool "Bash" --argjson seq 1 '{kind:"end",ts:$ts,tool:$tool,prompt_seq:$seq}' >> "${hook45_log}"
jq -nc --argjson ts "$(( now_ts + 12 ))" --argjson seq 1 --argjson dur 12 '{kind:"prompt_end",ts:$ts,prompt_seq:$seq,duration_s:$dur}' >> "${hook45_log}"
# State has zero signal — Outcome line must be silent.
jq -nc --arg sid "${hook45_session}" '{prompt_seq:"1",session_id:$sid}' > "${hook45_dir}/session_state.json"
hook45_payload="$(jq -nc --arg sid "${hook45_session}" '{session_id:$sid}')"
hook45_out="$(STATE_ROOT="${hook45_root}" HOME="${HOME}" \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" <<<"${hook45_payload}" 2>&1 || true)"
ctx45="$(printf '%s' "${hook45_out}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("systemMessage",""))' \
  2>/dev/null || printf '')"
case "${ctx45}" in
  *"─── Outcome ───"*) printf '  FAIL: T45 — Outcome line emitted with no signal\n%s\n' "${ctx45}" >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac
case "${ctx45}" in
  *"─── Time breakdown ───"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T45 — Time breakdown still required even when no Outcome\n' >&2; fail=$((fail + 1)) ;;
esac

# ----------------------------------------------------------------------
# v1.34.1+ (data-lens D-002 / design-lens X-002): aggregator must surface
# `concurrent_overhead_s` as a positive quantity when parallel agent/tool
# work outran walltime. Prevents the broken "agents 32% + tools 58% +
# idle 27% = 117%" math the renderer would otherwise display.
printf 'Test 41: aggregator emits concurrent_overhead_s when parallel work overruns walltime\n'
reset_log
log="$(timing_log_path)"
mkdir -p "$(dirname "${log}")"
# Synthesize two parallel agents that each took 30s but in 20s walltime —
# 40s of agent work in 20s wall = 20s of parallelism overhead.
ts0=$(now_epoch)
ts_end=$(( ts0 + 20 ))
{
  printf '{"kind":"prompt_start","ts":%d,"prompt_seq":1}\n' "${ts0}"
  printf '{"kind":"start","ts":%d,"tool":"Agent","subagent":"reviewer-a","tool_use_id":"a","prompt_seq":1}\n' "${ts0}"
  printf '{"kind":"start","ts":%d,"tool":"Agent","subagent":"reviewer-b","tool_use_id":"b","prompt_seq":1}\n' "${ts0}"
  printf '{"kind":"end","ts":%d,"tool":"Agent","tool_use_id":"a","prompt_seq":1}\n' "$(( ts0 + 30 ))"
  printf '{"kind":"end","ts":%d,"tool":"Agent","tool_use_id":"b","prompt_seq":1}\n' "$(( ts0 + 30 ))"
  printf '{"kind":"prompt_end","ts":%d,"prompt_seq":1,"duration_s":20}\n' "${ts_end}"
} > "${log}"
agg_overhead="$(timing_aggregate "${log}")"
overhead="$(jq -r '.concurrent_overhead_s // -1' <<<"${agg_overhead}")"
assert_ge "concurrent_overhead_s present and positive when work > walltime" 30 "${overhead}"
idle="$(jq -r '.idle_model_s // -1' <<<"${agg_overhead}")"
assert_eq "idle_model_s clamped to 0 when overhead > 0" "0" "${idle}"
agent_total="$(jq -r '.agent_total_s // 0' <<<"${agg_overhead}")"
assert_eq "agent_total_s sums both parallel agents (60s)" "60" "${agent_total}"

# When work fits inside walltime (no overhead), the field is 0.
printf 'Test 42: aggregator emits concurrent_overhead_s=0 when work fits inside walltime\n'
reset_log
ts0=$(now_epoch)
ts_end=$(( ts0 + 60 ))
{
  printf '{"kind":"prompt_start","ts":%d,"prompt_seq":1}\n' "${ts0}"
  printf '{"kind":"start","ts":%d,"tool":"Bash","tool_use_id":"c","prompt_seq":1}\n' "${ts0}"
  printf '{"kind":"end","ts":%d,"tool":"Bash","tool_use_id":"c","prompt_seq":1}\n' "$(( ts0 + 10 ))"
  printf '{"kind":"prompt_end","ts":%d,"prompt_seq":1,"duration_s":60}\n' "${ts_end}"
} > "${log}"
agg_no_overhead="$(timing_aggregate "${log}")"
no_overhead="$(jq -r '.concurrent_overhead_s // -1' <<<"${agg_no_overhead}")"
assert_eq "concurrent_overhead_s is 0 when work fits inside walltime" "0" "${no_overhead}"

# Cross-session aggregator must propagate the field.
printf 'Test 43: cross-session aggregator surfaces concurrent_overhead_s\n'
xs_log="${HOME}/.claude/quality-pack/timing.jsonl"
mkdir -p "$(dirname "${xs_log}")"
rm -f "${xs_log}"
jq -nc --arg session "s1" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$session,project_key:"p1",walltime_s:60,agent_total_s:80,
    tool_total_s:30,idle_model_s:0,concurrent_overhead_s:50,
    agent_breakdown:{"reviewer":80},tool_breakdown:{"Bash":30},
    prompt_count:1}' > "${xs_log}"
xs_overhead="$(timing_xs_aggregate 0 | jq -r '.concurrent_overhead_s // -1')"
assert_eq "cross-session rollup propagates concurrent_overhead_s" "50" "${xs_overhead}"

# ----------------------------------------------------------------------
# TTL ownership: a resume-transferred source must not export its copied
# summary/findings/gates, but its classifier telemetry is source-only (the
# handoff deliberately does not copy it) and must be exported before cleanup.
printf 'Test 44: TTL sweep honors resume ownership without losing source-only classifier telemetry\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/resume-sweep-state"
OMC_STATE_TTL_DAYS=-1
source_sid="resume-sweep-source"
target_sid="resume-sweep-target"
mkdir -p "${STATE_ROOT}/${source_sid}" "${STATE_ROOT}/${target_sid}"
cat > "${STATE_ROOT}/${source_sid}/session_state.json" <<EOF
{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution","subagent_dispatch_count":"9","project_key":"p-resume","resume_transferred_to":"${target_sid}"}
EOF
cat > "${STATE_ROOT}/${target_sid}/session_state.json" <<EOF
{"session_start_ts":"100","last_user_prompt_ts":"120","task_domain":"coding","task_intent":"execution","subagent_dispatch_count":"9","project_key":"p-resume","resume_source_session_id":"${source_sid}"}
EOF
printf '{"misfire":true,"intent":"advisory"}\n' \
  > "${STATE_ROOT}/${source_sid}/classifier_telemetry.jsonl"
printf '{"ts":101,"gate":"source-gate","event":"block"}\n' \
  > "${STATE_ROOT}/${source_sid}/gate_events.jsonl"
printf '{"ts":111,"gate":"target-gate","event":"block"}\n' \
  > "${STATE_ROOT}/${target_sid}/gate_events.jsonl"
printf '{"findings":[{"id":"F-source","status":"pending"}]}\n' \
  > "${STATE_ROOT}/${source_sid}/findings.json"
printf '{"findings":[{"id":"F-target","status":"pending"}]}\n' \
  > "${STATE_ROOT}/${target_sid}/findings.json"

summary44="${HOME}/.claude/quality-pack/session_summary.jsonl"
gates44="${HOME}/.claude/quality-pack/gate_events.jsonl"
misfires44="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"
rm -f "${summary44}" "${gates44}" "${misfires44}" "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked

assert_eq "TTL transferred source summary suppressed" "0" \
  "$(jq -sr --arg sid "${source_sid}" '[.[] | select(.session_id == $sid)] | length' "${summary44}" 2>/dev/null || printf 0)"
assert_eq "TTL target summary exported once" "1" \
  "$(jq -sr --arg sid "${target_sid}" '[.[] | select(.session_id == $sid)] | length' "${summary44}" 2>/dev/null || printf 0)"
assert_eq "TTL transferred source gate suppressed" "0" \
  "$(jq -sr --arg sid "${source_sid}" '[.[] | select(.session_id == $sid)] | length' "${gates44}" 2>/dev/null || printf 0)"
assert_eq "TTL target gate exported once" "1" \
  "$(jq -sr --arg sid "${target_sid}" '[.[] | select(.session_id == $sid)] | length' "${gates44}" 2>/dev/null || printf 0)"
assert_eq "TTL source-only classifier telemetry preserved" "1" \
  "$(jq -sr --arg sid "${source_sid}" '[.[] | select(.session_id == $sid and .misfire == true)] | length' "${misfires44}" 2>/dev/null || printf 0)"
assert_eq "TTL source directory claimed after export" "0" \
  "$([[ -d "${STATE_ROOT}/${source_sid}" ]] && printf 1 || printf 0)"

STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# A NUL-bearing ownership marker must fail open before jq emits raw bytes.
# Otherwise Bash strips the NUL and the sweep silently suppresses source-owned
# summary/gate evidence as if a valid handoff had occurred.
printf 'Test 44a: TTL sweep rejects normalized transfer ownership\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/resume-sweep-nul-state"
OMC_STATE_TTL_DAYS=-1
nul_sweep_sid="resume-sweep-nul-source"
nul_sweep_target="resume-sweep-nul-target"
mkdir -p "${STATE_ROOT}/${nul_sweep_sid}"
jq -nc --arg sid "${nul_sweep_sid}" --arg target "${nul_sweep_target}" '
  {session_start_ts:"100",last_user_prompt_ts:"110",task_domain:"coding",
   task_intent:"execution",subagent_dispatch_count:"9",project_key:"p-resume",
   resume_transferred_to:($target + "\u0000"),session_id:$sid}
' >"${STATE_ROOT}/${nul_sweep_sid}/session_state.json"
printf '%s\n' \
  '{"ts":101,"gate":"nul-source-gate","event":"block"}' \
  >"${STATE_ROOT}/${nul_sweep_sid}/gate_events.jsonl"
summary44a="${HOME}/.claude/quality-pack/session_summary.jsonl"
gates44a="${HOME}/.claude/quality-pack/gate_events.jsonl"
rm -f "${summary44a}" "${gates44a}" "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL NUL transfer marker preserves source summary" "1" \
  "$(jq -sr --arg sid "${nul_sweep_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${summary44a}" 2>/dev/null || printf 0)"
assert_eq "TTL NUL transfer marker preserves source gate" "1" \
  "$(jq -sr --arg sid "${nul_sweep_sid}" \
    '[.[] | select(.session_id == $sid and .gate == "nul-source-gate")]
      | length' "${gates44a}" 2>/dev/null || printf 0)"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# A malformed source must not partially change the global gate ledger or be
# deleted. Once repaired, immediate retry is lossless and the summary's
# occurrence-aware publication remains exactly-once.
printf 'Test 44b: TTL sweep retains failed exports and retries idempotently\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/failed-sweep-state"
OMC_STATE_TTL_DAYS=-1
failed_sid="failed-sweep-session"
mkdir -p "${STATE_ROOT}/${failed_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution","project_key":"p-failed"}' \
  > "${STATE_ROOT}/${failed_sid}/session_state.json"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:failed-sweep-session:1","ts":101,"gate":"test","event":"block","details":{}}' \
  > "${STATE_ROOT}/${failed_sid}/gate_events.jsonl"
printf '{"broken":' >> "${STATE_ROOT}/${failed_sid}/gate_events.jsonl"
summary44b="${HOME}/.claude/quality-pack/session_summary.jsonl"
gates44b="${HOME}/.claude/quality-pack/gate_events.jsonl"
rm -f "${summary44b}" "${gates44b}" "${STATE_ROOT}/.last_sweep"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:sentinel:1","ts":1,"gate":"sentinel","event":"block","details":{},"session_id":"sentinel"}' \
  > "${gates44b}"
gates44b_before="$(cksum < "${gates44b}")"
_sweep_stale_sessions_locked
assert_eq "TTL malformed gate source leaves destination byte-identical" \
  "${gates44b_before}" "$(cksum < "${gates44b}")"
assert_eq "TTL malformed gate source directory is retained" "1" \
  "$([[ -d "${STATE_ROOT}/${failed_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL failed export does not advance the daily marker" "0" \
  "$([[ -e "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"

printf '%s\n' \
  '{"_v":1,"event_id":"ge:failed-sweep-session:1","ts":101,"gate":"test","event":"block","details":{}}' \
  > "${STATE_ROOT}/${failed_sid}/gate_events.jsonl"
_sweep_stale_sessions_locked
assert_eq "TTL repaired source is removed after complete export" "0" \
  "$([[ -d "${STATE_ROOT}/${failed_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL retry publishes the gate row once" "1" \
  "$(jq -sr --arg sid "${failed_sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${gates44b}")"
assert_eq "TTL retry keeps one exact session summary" "1" \
  "$(jq -sr --arg sid "${failed_sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${summary44b}")"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Marker publication is no-follow and canonical. Invalid/future values must
# trigger a real pass, then be replaced atomically without touching a symlink
# target.
printf 'Test 44c: TTL marker validation and no-follow publication\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/marker-sweep-state"
OMC_STATE_TTL_DAYS=1
mkdir -p "${STATE_ROOT}"
marker_target="${TEST_STATE_ROOT}/marker-target"
printf '%s\n' 'do-not-touch' >"${marker_target}"
ln -s "${marker_target}" "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL marker symlink target remains unchanged" "do-not-touch" \
  "$(cat "${marker_target}")"
assert_eq "TTL marker symlink is atomically replaced" "0" \
  "$([[ -L "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
assert_eq "TTL replacement marker is canonical current epoch" \
  "${TEST_NOW_EPOCH}" "$(cat "${STATE_ROOT}/.last_sweep")"
marker_dir_target="${TEST_STATE_ROOT}/marker-dir-target"
mkdir -p "${marker_dir_target}"
printf '%s\n' 'keep-directory' >"${marker_dir_target}/sentinel"
rm -f "${STATE_ROOT}/.last_sweep"
ln -s "${marker_dir_target}" "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL directory-symlink marker target remains unchanged" "keep-directory" \
  "$(cat "${marker_dir_target}/sentinel")"
assert_eq "TTL directory-symlink marker is replaced without traversal" "0" \
  "$([[ -L "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
assert_eq "TTL directory-symlink replacement is canonical" \
  "${TEST_NOW_EPOCH}" "$(cat "${STATE_ROOT}/.last_sweep")"
printf '0%s\n' "${TEST_NOW_EPOCH}" >"${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL leading-zero marker is rejected and replaced" \
  "${TEST_NOW_EPOCH}" "$(cat "${STATE_ROOT}/.last_sweep")"
printf '%s\n' "$((TEST_NOW_EPOCH + 86400))" >"${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL future marker is rejected and replaced" \
  "${TEST_NOW_EPOCH}" "$(cat "${STATE_ROOT}/.last_sweep")"
printf '%040d\n' 1 >"${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL oversized marker is rejected and replaced" \
  "${TEST_NOW_EPOCH}" "$(cat "${STATE_ROOT}/.last_sweep")"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# A generation changed after the pre-lock snapshot must remain live. The next
# pass claims the new exact generation and emits one stable summary.
printf 'Test 44d: TTL claim rechecks the generation under writer locks\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/changed-sweep-state"
OMC_STATE_TTL_DAYS=-1
changed_sid="changed-sweep-session"
mkdir -p "${STATE_ROOT}/${changed_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${changed_sid}/session_state.json"
changed_ready="${TEST_STATE_ROOT}/changed-sweep.ready"
changed_release="${TEST_STATE_ROOT}/changed-sweep.release"
OMC_TEST_SWEEP_PRECLAIM_READY_FILE="${changed_ready}"
OMC_TEST_SWEEP_PRECLAIM_RELEASE_FILE="${changed_release}"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked &
changed_sweep_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${changed_ready}" ]] && break
  sleep 0.01
done
assert_eq "TTL changed-generation race reaches preclaim barrier" "1" \
  "$([[ -e "${changed_ready}" ]] && printf 1 || printf 0)"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"120","task_domain":"research","task_intent":"execution"}' \
  >"${STATE_ROOT}/${changed_sid}/session_state.json.next"
mv "${STATE_ROOT}/${changed_sid}/session_state.json.next" \
  "${STATE_ROOT}/${changed_sid}/session_state.json"
: >"${changed_release}"
wait "${changed_sweep_pid}"
unset OMC_TEST_SWEEP_PRECLAIM_READY_FILE OMC_TEST_SWEEP_PRECLAIM_RELEASE_FILE
assert_eq "TTL changed generation remains visible" "research" \
  "$(jq -r '.task_domain' "${STATE_ROOT}/${changed_sid}/session_state.json")"
assert_eq "TTL changed-generation failure leaves no marker" "0" \
  "$([[ -e "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
_sweep_stale_sessions_locked
assert_eq "TTL retry removes the newly claimed generation" "0" \
  "$([[ -d "${STATE_ROOT}/${changed_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL changed retry publishes one stable summary" "1" \
  "$(jq -sr --arg sid "${changed_sid}" \
    '[.[] | select(.session_id == $sid and .domain == "research")] | length' \
    "${HOME}/.claude/quality-pack/session_summary.jsonl")"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Publication may finish while the same session ID is revived. The old claim
# retires, but the new visible generation is never deleted.
printf 'Test 44e: TTL exported claim preserves a revived session generation\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/revived-sweep-state"
OMC_STATE_TTL_DAYS=-1
revived_sid="revived-sweep-session"
mkdir -p "${STATE_ROOT}/${revived_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${revived_sid}/session_state.json"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:revived-sweep-session:1","ts":101,"gate":"old","event":"block","details":{}}' \
  >"${STATE_ROOT}/${revived_sid}/gate_events.jsonl"
revived_ready="${TEST_STATE_ROOT}/revived-sweep.ready"
revived_release="${TEST_STATE_ROOT}/revived-sweep.release"
OMC_TEST_SWEEP_EXPORTED_READY_FILE="${revived_ready}"
OMC_TEST_SWEEP_EXPORTED_RELEASE_FILE="${revived_release}"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked &
revived_sweep_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${revived_ready}" ]] && break
  sleep 0.01
done
assert_eq "TTL revival race reaches exported-receipt barrier" "1" \
  "$([[ -e "${revived_ready}" ]] && printf 1 || printf 0)"
printf '%s\n' \
  '{"session_start_ts":"200","last_user_prompt_ts":"210","task_domain":"writing","task_intent":"execution"}' \
  >"${STATE_ROOT}/${revived_sid}/session_state.json"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:revived-sweep-session:2","ts":201,"gate":"new","event":"block","details":{}}' \
  >"${STATE_ROOT}/${revived_sid}/gate_events.jsonl"
: >"${revived_release}"
wait "${revived_sweep_pid}"
unset OMC_TEST_SWEEP_EXPORTED_READY_FILE OMC_TEST_SWEEP_EXPORTED_RELEASE_FILE
assert_eq "TTL revival preserves the new state generation" "writing" \
  "$(jq -r '.task_domain' "${STATE_ROOT}/${revived_sid}/session_state.json")"
assert_eq "TTL revival publishes only the claimed old gate" "1" \
  "$(jq -sr --arg sid "${revived_sid}" \
    '[.[] | select(.session_id == $sid and .gate == "old")] | length' \
    "${HOME}/.claude/quality-pack/gate_events.jsonl")"
assert_eq "TTL revival does not publish the new live gate" "0" \
  "$(jq -sr --arg sid "${revived_sid}" \
    '[.[] | select(.session_id == $sid and .gate == "new")] | length' \
    "${HOME}/.claude/quality-pack/gate_events.jsonl")"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# An exported receipt survives cleanup failure. Recovery consumes it without
# duplicating summary/gate rows and a retired cleanup residue never wedges.
printf 'Test 44f: TTL exported receipts recover cleanup idempotently\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/cleanup-sweep-state"
OMC_STATE_TTL_DAYS=-1
cleanup_sid="cleanup-sweep-session"
mkdir -p "${STATE_ROOT}/${cleanup_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${cleanup_sid}/session_state.json"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:cleanup-sweep-session:1","ts":101,"gate":"cleanup","event":"block","details":{}}' \
  >"${STATE_ROOT}/${cleanup_sid}/gate_events.jsonl"
OMC_TEST_SWEEP_FAIL_BEFORE_SOURCE_RMDIR=1
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
unset OMC_TEST_SWEEP_FAIL_BEFORE_SOURCE_RMDIR
assert_eq "TTL cleanup failure retains exported claim" "1" \
  "$(find "${STATE_ROOT}/.sweep-cleanup" -maxdepth 1 -type d \
    -name 'claim.*' | wc -l | tr -d '[:space:]')"
assert_eq "TTL cleanup failure leaves marker untouched" "0" \
  "$([[ -e "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
_sweep_stale_sessions_locked
assert_eq "TTL cleanup recovery removes source" "0" \
  "$([[ -d "${STATE_ROOT}/${cleanup_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL cleanup recovery keeps one summary" "1" \
  "$(jq -sr --arg sid "${cleanup_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${HOME}/.claude/quality-pack/session_summary.jsonl")"
assert_eq "TTL cleanup recovery keeps one gate" "1" \
  "$(jq -sr --arg sid "${cleanup_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${HOME}/.claude/quality-pack/gate_events.jsonl")"
partial_sid="partial-claim-session"
mkdir -p "${STATE_ROOT}/${partial_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${partial_sid}/session_state.json"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:partial-claim-session:1","ts":101,"gate":"partial","event":"block","details":{}}' \
  >"${STATE_ROOT}/${partial_sid}/gate_events.jsonl"
rm -f "${STATE_ROOT}/.last_sweep"
OMC_TEST_SWEEP_FAIL_AFTER_MOVE_COUNT=1
_sweep_stale_sessions_locked
unset OMC_TEST_SWEEP_FAIL_AFTER_MOVE_COUNT
assert_eq "TTL interrupted claim retains a prepared receipt" "prepared" \
  "$(find "${STATE_ROOT}/.sweep-cleanup" -mindepth 2 -maxdepth 2 \
    -name receipt.json -type f -exec jq -r \
      'select(.session_id == "partial-claim-session") | .phase' {} \;)"
_sweep_stale_sessions_locked
assert_eq "TTL interrupted claim recovery removes source" "0" \
  "$([[ -d "${STATE_ROOT}/${partial_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL interrupted claim recovery publishes one gate" "1" \
  "$(jq -sr --arg sid "${partial_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${HOME}/.claude/quality-pack/gate_events.jsonl")"
retired_sid="retired-cleanup-session"
mkdir -p "${STATE_ROOT}/${retired_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${retired_sid}/session_state.json"
rm -f "${STATE_ROOT}/.last_sweep"
OMC_TEST_SWEEP_FAIL_AFTER_RETIRE_RENAME=1
_sweep_stale_sessions_locked
unset OMC_TEST_SWEEP_FAIL_AFTER_RETIRE_RENAME
assert_eq "TTL interrupted retirement removes the claimed source" "0" \
  "$([[ -d "${STATE_ROOT}/${retired_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL interrupted retirement leaves a recognizable residue" "1" \
  "$(find "${STATE_ROOT}/.sweep-cleanup" -maxdepth 1 -type d \
    -name '.retired.*' | wc -l | tr -d '[:space:]')"
_sweep_stale_sessions_locked
assert_eq "TTL retired residue is pruned without wedging retry" "0" \
  "$(find "${STATE_ROOT}/.sweep-cleanup" -maxdepth 1 -type d \
    -name '.retired.*' | wc -l | tr -d '[:space:]')"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Unsafe control inputs and a destination symlink fail closed. Already-large
# aggregates are not capped while any deletion-authoritative export failed.
printf 'Test 44g: TTL rejects unsafe inputs/destinations before cleanup or caps\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/unsafe-sweep-state"
OMC_STATE_TTL_DAYS=-1
mkdir -p "${STATE_ROOT}/unsafe-edits" "${STATE_ROOT}/unsafe-findings" \
  "${STATE_ROOT}/unsafe-frontier" "${STATE_ROOT}/unsafe-destination" \
  "${STATE_ROOT}/unsafe-lock"
for unsafe_sid in unsafe-edits unsafe-findings unsafe-frontier \
    unsafe-destination unsafe-lock; do
  printf '%s\n' \
    '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
    >"${STATE_ROOT}/${unsafe_sid}/session_state.json"
done
unsafe_target="${TEST_STATE_ROOT}/unsafe-edits-target"
printf '%s\n' 'path' >"${unsafe_target}"
ln -s "${unsafe_target}" "${STATE_ROOT}/unsafe-edits/edited_files.log"
printf '%s\n' '[]' >"${STATE_ROOT}/unsafe-findings/findings.json"
dd if=/dev/zero \
  of="${STATE_ROOT}/unsafe-frontier/quality_frontier_history.jsonl" \
  bs=1048576 count=9 2>/dev/null
printf '%s\n' \
  '{"_v":1,"event_id":"ge:unsafe-destination:1","ts":101,"gate":"unsafe","event":"block","details":{}}' \
  >"${STATE_ROOT}/unsafe-destination/gate_events.jsonl"
misfires_cap_file="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"
rm -f "${misfires_cap_file}" "${STATE_ROOT}/.last_sweep"
for _row in $(seq 1 1001); do printf '{"row":%s}\n' "${_row}"; done \
  >"${misfires_cap_file}"
misfires_before="$(cksum <"${misfires_cap_file}")"
gate_symlink_target="${TEST_STATE_ROOT}/gate-symlink-target"
printf '%s\n' '{"sentinel":true}' >"${gate_symlink_target}"
rm -f "${HOME}/.claude/quality-pack/gate_events.jsonl"
ln -s "${gate_symlink_target}" \
  "${HOME}/.claude/quality-pack/gate_events.jsonl"
OMC_TEST_SWEEP_CLAIM_LOCK_FAIL_SID="unsafe-lock"
_sweep_stale_sessions_locked
unset OMC_TEST_SWEEP_CLAIM_LOCK_FAIL_SID
assert_eq "TTL symlinked edited-files input is retained" "1" \
  "$([[ -d "${STATE_ROOT}/unsafe-edits" ]] && printf 1 || printf 0)"
assert_eq "TTL malformed findings input is retained" "1" \
  "$([[ -d "${STATE_ROOT}/unsafe-findings" ]] && printf 1 || printf 0)"
assert_eq "TTL oversized frontier input is retained" "1" \
  "$([[ -d "${STATE_ROOT}/unsafe-frontier" ]] && printf 1 || printf 0)"
assert_eq "TTL forced claim-lock failure preserves source" "1" \
  "$([[ -f "${STATE_ROOT}/unsafe-lock/session_state.json" ]] \
    && printf 1 || printf 0)"
assert_eq "TTL destination-symlink failure retains a durable claim" "1" \
  "$(find "${STATE_ROOT}/.sweep-cleanup" -mindepth 2 -maxdepth 2 \
    -name receipt.json -type f -exec jq -r \
      'select(.session_id == "unsafe-destination") | 1' {} \; \
    | wc -l | tr -d '[:space:]')"
assert_eq "TTL export failure skips aggregate caps" \
  "${misfires_before}" "$(cksum <"${misfires_cap_file}")"
assert_eq "TTL destination symlink target remains unchanged" \
  '{"sentinel":true}' "$(cat "${gate_symlink_target}")"
assert_eq "TTL destination symlink is not replaced on failed export" "1" \
  "$([[ -L "${HOME}/.claude/quality-pack/gate_events.jsonl" ]] \
    && printf 1 || printf 0)"
assert_eq "TTL unsafe batch leaves marker untouched" "0" \
  "$([[ -e "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
rm -f "${HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Recovery receipts and frozen payload numerics are deletion authority. Their
# internal identities must agree exactly, and every numeric spelling must stay
# inside the shared exact-integer persistence range before a source path or
# cross-session summary can be authorized.
printf 'Test 44g2: TTL receipt identity and numeric authority fail closed\n'
receipt_cases="${TEST_STATE_ROOT}/sweep-receipt-authority"
mkdir -p "${receipt_cases}"
valid_receipt="${receipt_cases}/valid.json"
printf '%s\n' \
  '{"_v":1,"claim_id":"claim.receipt-session.ABC123","created_at":101,"host":"host-a","phase":"claimed","session_id":"receipt-session","source_identity":"1:2","source_mtime":100,"summary_id":"ss:host-a:receipt-session:deadbeef"}' \
  >"${valid_receipt}"
_sweep_receipt_status() {
  local receipt="$1" rc=0
  _sweep_claim_receipt_valid "${receipt}" >/dev/null 2>&1 || rc=$?
  printf '%s' "${rc}"
}
_sweep_generation_status() {
  local source="$1" rc=0
  _sweep_validate_generation_inputs "${source}" >/dev/null 2>&1 || rc=$?
  printf '%s' "${rc}"
}
assert_eq "TTL canonical relational receipt is accepted" "0" \
  "$(_sweep_receipt_status "${valid_receipt}")"
assert_eq "TTL path identity comes from the exact claim-bound receipt" \
  "receipt-session" \
  "$(_sweep_claim_session_id_for_path \
    "${valid_receipt}" "claim.receipt-session.ABC123")"
wrong_claim_rc=0
_sweep_claim_session_id_for_path \
  "${valid_receipt}" "claim.other-session.ABC123" \
  >/dev/null 2>&1 || wrong_claim_rc=$?
assert_eq "TTL path identity rejects a different claim basename" "1" \
  "${wrong_claim_rc}"

jq '.claim_id="claim.other-session.ABC123"' "${valid_receipt}" \
  >"${receipt_cases}/claim-mismatch.json"
assert_eq "TTL receipt rejects claim/session disagreement" "1" \
  "$(_sweep_receipt_status "${receipt_cases}/claim-mismatch.json")"
jq '.summary_id="ss:host-a:other-session:deadbeef"' "${valid_receipt}" \
  >"${receipt_cases}/summary-session-mismatch.json"
assert_eq "TTL receipt rejects summary/session disagreement" "1" \
  "$(_sweep_receipt_status \
    "${receipt_cases}/summary-session-mismatch.json")"
jq '.summary_id="ss:other-host:receipt-session:deadbeef"' \
  "${valid_receipt}" >"${receipt_cases}/summary-host-mismatch.json"
assert_eq "TTL receipt rejects summary/host disagreement" "1" \
  "$(_sweep_receipt_status "${receipt_cases}/summary-host-mismatch.json")"
for unsafe_sid in '..' '.sweep-cleanup' '_watchdog'; do
  safe_label="${unsafe_sid//./dot}"
  jq --arg sid "${unsafe_sid}" '
    .session_id=$sid
    | .claim_id=("claim."+$sid+".ABC123")
    | .summary_id=("ss:"+.host+":"+$sid+":deadbeef")
  ' "${valid_receipt}" >"${receipt_cases}/${safe_label}.json"
  assert_eq "TTL receipt rejects unsafe relational session ${unsafe_sid}" "1" \
    "$(_sweep_receipt_status "${receipt_cases}/${safe_label}.json")"
done
jq '.source_mtime=1000000000000000' "${valid_receipt}" \
  >"${receipt_cases}/mtime-overflow.json"
assert_eq "TTL receipt rejects oversized source mtime" "1" \
  "$(_sweep_receipt_status "${receipt_cases}/mtime-overflow.json")"
jq '.created_at=1e100' "${valid_receipt}" \
  >"${receipt_cases}/created-at-overflow.json"
assert_eq "TTL receipt rejects exponent timestamp overflow" "1" \
  "$(_sweep_receipt_status "${receipt_cases}/created-at-overflow.json")"

numeric_source="${receipt_cases}/numeric-source"
mkdir -p "${numeric_source}"
printf '%s\n' '{"code_edit_count":999999999999999}' \
  >"${numeric_source}/session_state.json"
assert_eq "TTL generation accepts the exact numeric ceiling" "0" \
  "$(_sweep_generation_status "${numeric_source}")"
printf '%s\n' '{"code_edit_count":"999999999999999"}' \
  >"${numeric_source}/session_state.json"
assert_eq "TTL generation accepts the canonical string ceiling" "0" \
  "$(_sweep_generation_status "${numeric_source}")"
printf '%s\n' '{"code_edit_count":1000000000000000}' \
  >"${numeric_source}/session_state.json"
assert_eq "TTL generation rejects an oversized JSON number" "1" \
  "$(_sweep_generation_status "${numeric_source}")"
printf '%s\n' '{"code_edit_count":1e100}' \
  >"${numeric_source}/session_state.json"
assert_eq "TTL generation rejects an exponent overflow" "1" \
  "$(_sweep_generation_status "${numeric_source}")"
printf '%s\n' '{"code_edit_count":"1000000000000000"}' \
  >"${numeric_source}/session_state.json"
assert_eq "TTL generation rejects an oversized numeric string" "1" \
  "$(_sweep_generation_status "${numeric_source}")"

recovered_claim="${receipt_cases}/claim.receipt-session.ABC123"
mkdir -p "${recovered_claim}/payload"
cp "${valid_receipt}" "${recovered_claim}/receipt.json"
cp "${numeric_source}/session_state.json" \
  "${recovered_claim}/payload/session_state.json"
recovered_summary_rc=0
_sweep_build_claim_summary "${recovered_claim}" \
  >/dev/null 2>&1 || recovered_summary_rc=$?
assert_eq "TTL recovered summary revalidates its frozen numeric payload" "1" \
  "${recovered_summary_rc}"

# ----------------------------------------------------------------------
# Legitimate identical legacy rows retain their occurrence count, while a
# post-gate crash retries the same claim without manufacturing duplicates.
printf 'Test 44h: TTL occurrence merge preserves legacy duplicates across retry\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/legacy-duplicate-sweep-state"
OMC_STATE_TTL_DAYS=-1
legacy_sid="legacy-duplicate-session"
mkdir -p "${STATE_ROOT}/${legacy_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${legacy_sid}/session_state.json"
printf '%s\n%s\n' \
  '{"ts":101,"gate":"legacy-duplicate","event":"block","details":{}}' \
  '{"ts":101,"gate":"legacy-duplicate","event":"block","details":{}}' \
  >"${STATE_ROOT}/${legacy_sid}/gate_events.jsonl"
rm -f "${HOME}/.claude/quality-pack/gate_events.jsonl" \
  "${STATE_ROOT}/.last_sweep"
OMC_TEST_SWEEP_FAIL_AFTER_EXPORT=gates
_sweep_stale_sessions_locked
unset OMC_TEST_SWEEP_FAIL_AFTER_EXPORT
_sweep_stale_sessions_locked
assert_eq "TTL legacy duplicate occurrences survive retry exactly" "2" \
  "$(jq -sr --arg sid "${legacy_sid}" \
    '[.[] | select(.session_id == $sid and .gate == "legacy-duplicate")]
      | length' "${HOME}/.claude/quality-pack/gate_events.jsonl")"
assert_eq "TTL partial-export retry keeps one summary identity" "1" \
  "$(jq -sr --arg sid "${legacy_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${HOME}/.claude/quality-pack/session_summary.jsonl")"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Timing has its own per-file mutex. A writer that lands after the sweep's
# unlocked snapshot but before its locked recheck must survive and abort claim.
printf 'Test 44i: TTL claim serializes with the independent timing writer\n'
_test_hold_timing_writer() {
  local file="$1" ready="$2" go="$3" wrote="$4" release="$5"
  : >"${ready}"
  while [[ ! -e "${go}" ]]; do sleep 0.01; done
  printf '%s\n' \
    '{"kind":"start","ts":999,"tool":"Bash","tool_use_id":"ttl-race"}' \
    >>"${file}"
  : >"${wrote}"
  while [[ ! -e "${release}" ]]; do sleep 0.01; done
}
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/timing-writer-sweep-state"
OMC_STATE_TTL_DAYS=-1
timing_sweep_sid="timing-writer-sweep"
mkdir -p "${STATE_ROOT}/${timing_sweep_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${timing_sweep_sid}/session_state.json"
printf '%s\n' \
  '{"kind":"prompt_start","ts":100,"prompt_seq":1}' \
  >"${STATE_ROOT}/${timing_sweep_sid}/timing.jsonl"
timing_preclaim_ready="${TEST_STATE_ROOT}/timing-preclaim.ready"
timing_preclaim_release="${TEST_STATE_ROOT}/timing-preclaim.release"
timing_holder_ready="${TEST_STATE_ROOT}/timing-holder.ready"
timing_writer_go="${TEST_STATE_ROOT}/timing-writer.go"
timing_writer_wrote="${TEST_STATE_ROOT}/timing-writer.wrote"
timing_holder_release="${TEST_STATE_ROOT}/timing-holder.release"
OMC_TEST_SWEEP_PRECLAIM_READY_FILE="${timing_preclaim_ready}"
OMC_TEST_SWEEP_PRECLAIM_RELEASE_FILE="${timing_preclaim_release}"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked &
timing_sweep_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${timing_preclaim_ready}" ]] && break
  sleep 0.01
done
_with_lockdir "${STATE_ROOT}/${timing_sweep_sid}/timing.jsonl.lock" \
  "test-ttl-timing-writer" _test_hold_timing_writer \
    "${STATE_ROOT}/${timing_sweep_sid}/timing.jsonl" \
    "${timing_holder_ready}" "${timing_writer_go}" \
    "${timing_writer_wrote}" "${timing_holder_release}" &
timing_holder_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${timing_holder_ready}" ]] && break
  sleep 0.01
done
: >"${timing_preclaim_release}"
: >"${timing_writer_go}"
for _wait in $(seq 1 500); do
  [[ -e "${timing_writer_wrote}" ]] && break
  sleep 0.01
done
: >"${timing_holder_release}"
wait "${timing_holder_pid}"
wait "${timing_sweep_pid}"
unset OMC_TEST_SWEEP_PRECLAIM_READY_FILE OMC_TEST_SWEEP_PRECLAIM_RELEASE_FILE
assert_eq "TTL timing race preserves the writer row" "1" \
  "$(jq -s '[.[] | select(.tool_use_id == "ttl-race")] | length' \
    "${STATE_ROOT}/${timing_sweep_sid}/timing.jsonl")"
assert_eq "TTL timing race retains the changed source generation" "1" \
  "$([[ -d "${STATE_ROOT}/${timing_sweep_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL timing race leaves marker untouched" "0" \
  "$([[ -e "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Ordinary sessions retain bounded managed subdirectories. They are claimed
# as exact flat trees; nested/symlink-bearing trees remain live and fail closed.
printf 'Test 44j: TTL claims managed flat directories without recursive trust\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/managed-directory-sweep-state"
OMC_STATE_TTL_DAYS=-1
managed_dir_sid="managed-directory-session"
mkdir -p "${STATE_ROOT}/${managed_dir_sid}/.verification-starts" \
  "${STATE_ROOT}/${managed_dir_sid}/.closeout-material-generations" \
  "${STATE_ROOT}/${managed_dir_sid}/.plan-txn.committed.crash"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${managed_dir_sid}/session_state.json"
printf '%s\n' '{"tool_use_id":"tool-1"}' \
  >"${STATE_ROOT}/${managed_dir_sid}/.verification-starts/tool-1.json"
printf '%s\n' 'generation|nonce' \
  >"${STATE_ROOT}/${managed_dir_sid}/.closeout-material-generations/1.nonce"
printf '%s\n' '{"status":"committed"}' \
  >"${STATE_ROOT}/${managed_dir_sid}/.plan-txn.committed.crash/.ready"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL ordinary managed-directory session is removed" "0" \
  "$([[ -d "${STATE_ROOT}/${managed_dir_sid}" ]] && printf 1 || printf 0)"
assert_eq "TTL managed-directory session publishes one summary" "1" \
  "$(jq -sr --arg sid "${managed_dir_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${HOME}/.claude/quality-pack/session_summary.jsonl")"

unsafe_tree_sid="unsafe-managed-tree-session"
mkdir -p "${STATE_ROOT}/${unsafe_tree_sid}/.verification-starts/nested"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${unsafe_tree_sid}/session_state.json"
printf '%s\n' 'retain' \
  >"${STATE_ROOT}/${unsafe_tree_sid}/.verification-starts/nested/sentinel"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL nested managed tree is retained fail-closed" "retain" \
  "$(cat "${STATE_ROOT}/${unsafe_tree_sid}/.verification-starts/nested/sentinel")"
assert_eq "TTL nested-tree failure withholds marker" "0" \
  "$([[ -e "${STATE_ROOT}/.last_sweep" ]] && printf 1 || printf 0)"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# STATE_ROOT itself is deletion authority. A symlink must be rejected before
# quarantine pruning or sweep-lock acquisition can traverse its target.
printf 'Test 44k: TTL rejects a symlinked state root before traversal\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
foreign_state_root="${TEST_STATE_ROOT}/foreign-state-root"
STATE_ROOT="${TEST_STATE_ROOT}/symlink-state-root"
OMC_STATE_TTL_DAYS=-1
mkdir -p "${foreign_state_root}/.resume-quarantine/stale-slot"
printf '%s\n' 'must-survive' \
  >"${foreign_state_root}/.resume-quarantine/stale-slot/sentinel"
ln -s "${foreign_state_root}" "${STATE_ROOT}"
sweep_stale_sessions
assert_eq "TTL symlinked root does not prune foreign quarantine" \
  "must-survive" \
  "$(cat "${foreign_state_root}/.resume-quarantine/stale-slot/sentinel")"
assert_eq "TTL symlinked root does not create a foreign sweep lock" "0" \
  "$([[ -e "${foreign_state_root}/.sweep.lock" \
      || -L "${foreign_state_root}/.sweep.lock" ]] && printf 1 || printf 0)"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# A reused native session ID denotes a new deletion generation. Summary
# retries dedupe one claim, but a later inode/claim generation remains distinct.
printf 'Test 44l: TTL summary identity distinguishes reused session IDs\n'
saved_state_root="${STATE_ROOT}"
saved_ttl_days="${OMC_STATE_TTL_DAYS}"
STATE_ROOT="${TEST_STATE_ROOT}/reused-id-sweep-state"
OMC_STATE_TTL_DAYS=-1
reused_sid="reused-summary-session"
mkdir -p "${STATE_ROOT}/${reused_sid}"
printf '%s\n' \
  '{"session_start_ts":"100","last_user_prompt_ts":"110","task_domain":"coding","task_intent":"execution"}' \
  >"${STATE_ROOT}/${reused_sid}/session_state.json"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
mkdir -p "${STATE_ROOT}/${reused_sid}"
printf '%s\n' \
  '{"session_start_ts":"200","last_user_prompt_ts":"210","task_domain":"writing","task_intent":"execution"}' \
  >"${STATE_ROOT}/${reused_sid}/session_state.json"
rm -f "${STATE_ROOT}/.last_sweep"
_sweep_stale_sessions_locked
assert_eq "TTL reused session ID retains both generation summaries" "2" \
  "$(jq -sr --arg sid "${reused_sid}" \
    '[.[] | select(.session_id == $sid)] | length' \
    "${HOME}/.claude/quality-pack/session_summary.jsonl")"
assert_eq "TTL reused session summaries have distinct ownership IDs" "2" \
  "$(jq -sr --arg sid "${reused_sid}" \
    '[.[] | select(.session_id == $sid) | ._sweep_id] | unique | length' \
    "${HOME}/.claude/quality-pack/session_summary.jsonl")"
STATE_ROOT="${saved_state_root}"
OMC_STATE_TTL_DAYS="${saved_ttl_days}"

# ----------------------------------------------------------------------
# Resume copies preserve durable gate event IDs while changing aggregation
# attribution. The global merge keeps one producer event, preserves ID-less
# occurrence semantics, and refuses a conflicting payload for the same ID.
printf 'Test 44m: gate-event merge deduplicates resume attribution copies\n'
gate_merge_destination="${TEST_STATE_ROOT}/gate-resume-merge.jsonl"
gate_source_rows="${TEST_STATE_ROOT}/gate-resume-source.jsonl"
gate_target_rows="${TEST_STATE_ROOT}/gate-resume-target.jsonl"
gate_conflict_rows="${TEST_STATE_ROOT}/gate-resume-conflict.jsonl"
gate_oversized_rows="${TEST_STATE_ROOT}/gate-resume-oversized.jsonl"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:resume-source:1","ts":101,"host":"host-a","gate":"quality","event":"block","details":{"reason":"same"}}' \
  >"${gate_source_rows}"
cp "${gate_source_rows}" "${gate_target_rows}"
_sweep_append_gate_events \
  "${gate_source_rows}" resume-source "${gate_merge_destination}" aaaaaaaaaaaa
_sweep_append_gate_events \
  "${gate_target_rows}" resume-target "${gate_merge_destination}" bbbbbbbbbbbb
assert_eq "gate resume copy contributes one durable event ID" "1" \
  "$(jq -s '[.[] | select(.event_id == "ge:resume-source:1")] | length' \
    "${gate_merge_destination}")"
assert_eq "gate resume copy keeps first stable attribution" "resume-source" \
  "$(jq -r 'select(.event_id == "ge:resume-source:1") | .session_id' \
    "${gate_merge_destination}")"
gate_merge_before="$(cksum <"${gate_merge_destination}")"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:resume-source:1","ts":101,"host":"host-a","gate":"different","event":"block","details":{"reason":"conflict"}}' \
  >"${gate_conflict_rows}"
gate_conflict_rc=0
_sweep_append_gate_events \
  "${gate_conflict_rows}" resume-target "${gate_merge_destination}" bbbbbbbbbbbb \
  || gate_conflict_rc=$?
assert_eq "conflicting producer payload for one gate ID fails closed" "1" \
  "${gate_conflict_rc}"
assert_eq "gate conflict leaves destination generation unchanged" \
  "${gate_merge_before}" "$(cksum <"${gate_merge_destination}")"
printf '%s\n' \
  '{"_v":1,"event_id":"ge:resume-source:1000000000000000","ts":102,"host":"host-a","gate":"quality","event":"block","details":{}}' \
  >"${gate_oversized_rows}"
gate_oversized_rc=0
_sweep_append_gate_events \
  "${gate_oversized_rows}" resume-target "${gate_merge_destination}" bbbbbbbbbbbb \
  || gate_oversized_rc=$?
assert_eq "oversized gate sequence fails the durable merge envelope" "1" \
  "${gate_oversized_rc}"
assert_eq "oversized gate sequence leaves destination unchanged" \
  "${gate_merge_before}" "$(cksum <"${gate_merge_destination}")"

# ----------------------------------------------------------------------
printf 'Test 48: stale prompt-end cannot append after waiting for state lock\n'
saved_session_id="${SESSION_ID}"
SESSION_ID="timing-generation-race"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '%s\n' '{"ulw_enforcement_generation":"4801"}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
prompt_end_log="$(timing_log_path)"
prompt_end_ready="${TEST_STATE_ROOT}/prompt-end-generation.ready"
prompt_end_release="${TEST_STATE_ROOT}/prompt-end-generation.release"
(
  export SESSION_ID
  export _OMC_ULW_CAPTURED_GENERATION="4801"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${prompt_end_ready}"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${prompt_end_release}"
  timing_append_prompt_end 480 9
) &
prompt_end_pid=$!
prompt_end_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${prompt_end_ready}" ]]; then
    prompt_end_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "prompt-end reached deterministic pre-acquire barrier" "1" \
  "${prompt_end_barrier_seen}"
jq '.ulw_enforcement_generation="4802"' \
  "${STATE_ROOT}/${SESSION_ID}/session_state.json" \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json.tmp"
mv "${STATE_ROOT}/${SESSION_ID}/session_state.json.tmp" \
  "${STATE_ROOT}/${SESSION_ID}/session_state.json"
: >"${prompt_end_release}"
wait "${prompt_end_pid}" || true
assert_eq "stale prompt-end appended no timing row" "0" \
  "$(grep -c '"kind":"prompt_end"' "${prompt_end_log}" \
      2>/dev/null || echo 0)"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 49: stale session summary cannot publish after waiting for state lock\n'
saved_session_id="${SESSION_ID}"
SESSION_ID="timing-summary-generation-race"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '%s\n' '{"ulw_enforcement_generation":"4901"}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
summary_generation_log="$(timing_xs_log_path)"
summary_generation_ready="${TEST_STATE_ROOT}/summary-generation.ready"
summary_generation_release="${TEST_STATE_ROOT}/summary-generation.release"
(
  export SESSION_ID
  export _OMC_ULW_CAPTURED_GENERATION="4901"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${summary_generation_ready}"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${summary_generation_release}"
  timing_record_session_summary \
    '{"walltime_s":5,"prompt_count":1,"tokens_main_out":1}'
) &
summary_generation_pid=$!
summary_generation_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${summary_generation_ready}" ]]; then
    summary_generation_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "session summary reached deterministic pre-acquire barrier" "1" \
  "${summary_generation_barrier_seen}"
jq '.ulw_enforcement_generation="4902"' \
  "${STATE_ROOT}/${SESSION_ID}/session_state.json" \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json.tmp"
mv "${STATE_ROOT}/${SESSION_ID}/session_state.json.tmp" \
  "${STATE_ROOT}/${SESSION_ID}/session_state.json"
: >"${summary_generation_release}"
wait "${summary_generation_pid}" || true
assert_eq "stale session summary published no cross-session row" "0" \
  "$(jq -Rr --arg sid "${SESSION_ID}" \
      'fromjson? | select((.session_id // .session // "") == $sid) | 1' \
      "${summary_generation_log}" 2>/dev/null | wc -l | tr -d ' ')"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 50: same-generation source transfer suppresses a waiting summary\n'
saved_session_id="${SESSION_ID}"
SESSION_ID="timing-summary-source-transfer-race"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '%s\n' '{"ulw_enforcement_generation":"5001"}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
source_transfer_log="$(timing_xs_log_path)"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":5}'
source_transfer_ready="${TEST_STATE_ROOT}/summary-source-transfer.ready"
source_transfer_release="${TEST_STATE_ROOT}/summary-source-transfer.release"
(
  export SESSION_ID
  export _OMC_ULW_CAPTURED_GENERATION="5001"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${source_transfer_ready}"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${source_transfer_release}"
  timing_record_session_summary \
    '{"walltime_s":50,"prompt_count":5,"tokens_main_out":500}'
) &
source_transfer_pid=$!
source_transfer_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${source_transfer_ready}" ]]; then
    source_transfer_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "source transfer reached deterministic pre-acquire barrier" "1" \
  "${source_transfer_barrier_seen}"
jq '.resume_transferred_to="timing-summary-transfer-owner"' \
  "${STATE_ROOT}/${SESSION_ID}/session_state.json" \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json.tmp"
mv "${STATE_ROOT}/${SESSION_ID}/session_state.json.tmp" \
  "${STATE_ROOT}/${SESSION_ID}/session_state.json"
: >"${source_transfer_release}"
wait "${source_transfer_pid}" || true
assert_eq "same-generation transferred source retained only its old checkpoint" \
  "5" \
  "$(jq -sr --arg sid "${SESSION_ID}" \
      '[.[] | select(.session_id == $sid) | .tokens_main_out] | first // 0' \
      "${source_transfer_log}" 2>/dev/null)"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 51: same-generation target handoff refreshes summary ancestry\n'
saved_session_id="${SESSION_ID}"
summary_ancestor_sid="timing-summary-late-ancestor"
summary_target_sid="timing-summary-late-target"
SESSION_ID="${summary_ancestor_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":51}'
SESSION_ID="${summary_target_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '%s\n' '{"ulw_enforcement_generation":"5101"}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
target_transfer_ready="${TEST_STATE_ROOT}/summary-target-transfer.ready"
target_transfer_release="${TEST_STATE_ROOT}/summary-target-transfer.release"
(
  export SESSION_ID
  export _OMC_ULW_CAPTURED_GENERATION="5101"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${target_transfer_ready}"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${target_transfer_release}"
  timing_record_session_summary \
    '{"walltime_s":8,"prompt_count":2,"tokens_main_out":81}'
) &
target_transfer_pid=$!
target_transfer_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${target_transfer_ready}" ]]; then
    target_transfer_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "target handoff reached deterministic pre-acquire barrier" "1" \
  "${target_transfer_barrier_seen}"
jq --arg target "${summary_target_sid}" \
  '.resume_transferred_to=$target' \
  "${STATE_ROOT}/${summary_ancestor_sid}/session_state.json" \
  >"${STATE_ROOT}/${summary_ancestor_sid}/session_state.json.tmp"
mv "${STATE_ROOT}/${summary_ancestor_sid}/session_state.json.tmp" \
  "${STATE_ROOT}/${summary_ancestor_sid}/session_state.json"
jq --arg source "${summary_ancestor_sid}" \
  '.resume_source_session_id=$source
    | .resume_ancestry_version=1
    | .resume_ancestor_session_ids=[$source]' \
  "${STATE_ROOT}/${summary_target_sid}/session_state.json" \
  >"${STATE_ROOT}/${summary_target_sid}/session_state.json.tmp"
mv "${STATE_ROOT}/${summary_target_sid}/session_state.json.tmp" \
  "${STATE_ROOT}/${summary_target_sid}/session_state.json"
: >"${target_transfer_release}"
wait "${target_transfer_pid}" || true
assert_eq "same-generation target retired the newly bound ancestor row" "0" \
  "$(jq -sr --arg sid "${summary_ancestor_sid}" \
      '[.[] | select(.session_id == $sid)] | length' \
      "$(timing_xs_log_path)" 2>/dev/null)"
assert_eq "same-generation target published one cumulative checkpoint" "1" \
  "$(jq -sr --arg sid "${summary_target_sid}" \
      '[.[] | select(.session_id == $sid and .tokens_main_out == 81)] | length' \
      "$(timing_xs_log_path)" 2>/dev/null)"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 51b: NUL-bearing resume ownership cannot normalize into authority\n'
saved_session_id="${SESSION_ID}"
nul_fence_sid="timing-summary-nul-fence"
SESSION_ID="${nul_fence_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
jq -nc --arg sid "${nul_fence_sid}" \
  '{session_id:$sid,resume_transferred_to:("another-owner" + "\u0000")}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":511}'
assert_eq "NUL-bearing transfer fence cannot suppress its source summary" "1" \
  "$(jq -sr --arg sid "${nul_fence_sid}" \
      '[.[] | select(.session_id == $sid and .tokens_main_out == 511)] | length' \
      "$(timing_xs_log_path)" 2>/dev/null)"

nul_ancestor_sid="timing-summary-nul-ancestor"
nul_target_sid="timing-summary-nul-target"
SESSION_ID="${nul_ancestor_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":512}'
jq -nc --arg target "${nul_target_sid}" \
  '{resume_transferred_to:($target + "\u0000")}' \
  >"${STATE_ROOT}/${nul_ancestor_sid}/session_state.json"
SESSION_ID="${nul_target_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
jq -nc --arg source "${nul_ancestor_sid}" \
  '{resume_source_session_id:$source}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":6,"prompt_count":1,"tokens_main_out":513}'
assert_eq "NUL-bearing ancestor owner cannot authorize source-row deletion" "1" \
  "$(jq -sr --arg sid "${nul_ancestor_sid}" \
      '[.[] | select(.session_id == $sid and .tokens_main_out == 512)] | length' \
      "$(timing_xs_log_path)" 2>/dev/null)"

nul_source_sid="timing-summary-nul-source-id"
nul_source_target_sid="timing-summary-nul-source-target"
SESSION_ID="${nul_source_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":5,"prompt_count":1,"tokens_main_out":514}'
jq -nc --arg target "${nul_source_target_sid}" \
  '{resume_transferred_to:$target}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
SESSION_ID="${nul_source_target_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
jq -nc --arg source "${nul_source_sid}" \
  '{resume_source_session_id:($source + "\u0000")}' \
  >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
timing_record_session_summary \
  '{"walltime_s":6,"prompt_count":1,"tokens_main_out":515}'
assert_eq "NUL-bearing target source ID cannot authorize source-row deletion" "1" \
  "$(jq -sr --arg sid "${nul_source_sid}" \
      '[.[] | select(.session_id == $sid and .tokens_main_out == 514)] | length' \
      "$(timing_xs_log_path)" 2>/dev/null)"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 52: prompt-end publication is unique under its timing-log lock\n'
saved_session_id="${SESSION_ID}"
SESSION_ID="timing-prompt-end-unique"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
rm -f "$(timing_log_path)"
printf '%s\n' \
  '{"kind":"prompt_start","ts":1,"prompt_seq":5200}' \
  '{"kind":"prompt_end","ts":1,"prompt_seq":5200,"duration_s":"bad"}' \
  >"$(timing_log_path)"
timing_append_prompt_end 5200 6
assert_eq "malformed prompt-end cannot suppress its valid replacement" "1" \
  "$(jq -s '[.[] | select(.kind == "prompt_end"
      and .prompt_seq == 5200 and (.duration_s | type) == "number")] | length' \
    "$(timing_log_path)")"

rm -f "$(timing_log_path)"
printf '%s\n' \
  '{"kind":"prompt_end","ts":1,"prompt_seq":5205,"duration_s":1}' \
  >"$(timing_log_path)"
timing_append_prompt_end 5205 2
assert_eq "orphan end without a start does not accumulate duplicates" "1" \
  "$(jq -s '[.[] | select(.kind == "prompt_end" and .prompt_seq == 5205)]
      | length' "$(timing_log_path)")"

summary_poison_sid="timing-prompt-end-poison-summary"
summary_poison_dir="${STATE_ROOT}/${summary_poison_sid}"
mkdir -p "${summary_poison_dir}"
summary_poison_start=$(( $(date +%s) - 6 ))
printf '{"prompt_seq":"5202"}\n' >"${summary_poison_dir}/session_state.json"
printf '%s\n' \
  "{\"kind\":\"prompt_start\",\"ts\":${summary_poison_start},\"prompt_seq\":5202}" \
  '{"kind":"prompt_end","ts":1,"prompt_seq":5202,"duration_s":"bad"}' \
  '{torn' >"${summary_poison_dir}/timing.jsonl"
summary_poison_payload="$(jq -nc --arg sid "${summary_poison_sid}" \
  '{session_id:$sid}')"
STATE_ROOT="${STATE_ROOT}" HOME="${HOME}" OMC_TIME_CARD_MIN_SECONDS=0 \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" \
    <<<"${summary_poison_payload}" >/dev/null 2>&1 || true
assert_eq "Stop finalizer ignores malformed/torn prompt-end authority" "1" \
  "$(jq -Rsr '[split("\n")[] | fromjson?
      | select(.kind == "prompt_end" and .prompt_seq == 5202
        and (.duration_s | type) == "number")] | length' \
    "${summary_poison_dir}/timing.jsonl")"

rm -f "$(timing_log_path)"
printf '%s\n' \
  '{"kind":"prompt_end","ts":1,"prompt_seq":5203,"duration_s":1}' \
  '{"kind":"prompt_start","ts":2,"prompt_seq":5203}' \
  >"$(timing_log_path)"
timing_append_prompt_end 5203 2
assert_eq "end-before-start cannot suppress the ordered prompt end" "2" \
  "$(jq -s '[.[] | select(.kind == "prompt_end" and .prompt_seq == 5203)]
      | length' "$(timing_log_path)")"

summary_order_sid="timing-prompt-end-order-summary"
summary_order_dir="${STATE_ROOT}/${summary_order_sid}"
mkdir -p "${summary_order_dir}"
printf '{"prompt_seq":"5204"}\n' >"${summary_order_dir}/session_state.json"
summary_order_start=$(( $(date +%s) - 2 ))
printf '%s\n' \
  '{"kind":"prompt_end","ts":1,"prompt_seq":5204,"duration_s":1}' \
  "{\"kind\":\"prompt_start\",\"ts\":${summary_order_start},\"prompt_seq\":5204}" \
  >"${summary_order_dir}/timing.jsonl"
summary_order_payload="$(jq -nc --arg sid "${summary_order_sid}" \
  '{session_id:$sid}')"
STATE_ROOT="${STATE_ROOT}" HOME="${HOME}" OMC_TIME_CARD_MIN_SECONDS=0 \
  bash "${SCRIPTS_DIR}/stop-time-summary.sh" \
    <<<"${summary_order_payload}" >/dev/null 2>&1 || true
assert_eq "Stop finalizer repairs an orphan end that precedes its start" "2" \
  "$(jq -s '[.[] | select(.kind == "prompt_end" and .prompt_seq == 5204)]
      | length' "${summary_order_dir}/timing.jsonl")"

rm -f "$(timing_log_path)"
printf '%s\n' \
  '{"kind":"prompt_start","ts":1,"prompt_seq":5201}' \
  >"$(timing_log_path)"
( timing_append_prompt_end 5201 7 ) &
prompt_unique_a=$!
( timing_append_prompt_end 5201 9 ) &
prompt_unique_b=$!
wait "${prompt_unique_a}"
wait "${prompt_unique_b}"
assert_eq "concurrent prompt-end callbacks publish one row" "1" \
  "$(jq -s '[.[] | select(.kind == "prompt_end" and .prompt_seq == 5201)] | length' \
    "$(timing_log_path)")"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 53: per-session rotation cannot lose a waiting hot-path append\n'
saved_session_id="${SESSION_ID}"
SESSION_ID="timing-cap-writer-race"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
cap_race_log="$(timing_log_path)"
rm -f "${cap_race_log}"
for cap_row in 1 2 3 4 5 6; do
  printf '{"kind":"start","ts":1,"tool":"seed","prompt_seq":%s}\n' \
    "${cap_row}" >>"${cap_race_log}"
done
cap_race_ready="${TEST_STATE_ROOT}/timing-cap.ready"
cap_race_release="${TEST_STATE_ROOT}/timing-cap.release"
cap_writer_done="${TEST_STATE_ROOT}/timing-cap-writer.done"
(
  export OMC_TIMING_PER_SESSION_CAP=5
  export OMC_TIMING_PER_SESSION_RETAIN=3
  export OMC_TEST_TIMING_CAP_READY_FILE="${cap_race_ready}"
  export OMC_TEST_TIMING_CAP_RELEASE_FILE="${cap_race_release}"
  timing_append_prompt_end 5301 3
) &
cap_owner_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${cap_race_ready}" ]] && break
  sleep 0.01
done
assert_eq "rotation reaches deterministic pre-rename barrier" "1" \
  "$([[ -e "${cap_race_ready}" ]] && printf 1 || printf 0)"
(
  timing_append_start "Bash" "cap-waiting-writer" "" 5301
  : >"${cap_writer_done}"
) &
cap_writer_pid=$!
sleep 0.1
assert_eq "hot writer waits behind the rotation mutex" "0" \
  "$([[ -e "${cap_writer_done}" ]] && printf 1 || printf 0)"
: >"${cap_race_release}"
wait "${cap_owner_pid}"
wait "${cap_writer_pid}"
assert_eq "waiting append survives rotation rename" "1" \
  "$(jq -s '[.[] | select(.tool_use_id == "cap-waiting-writer")] | length' \
    "${cap_race_log}")"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf 'Test 54: timing TTL filtering cannot overwrite a fresh summary\n'
saved_session_id="${SESSION_ID}"
SESSION_ID="timing-ttl-writer-race"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}\n' >"${STATE_ROOT}/${SESSION_ID}/session_state.json"
ttl_race_log="$(timing_xs_log_path)"
ttl_cutoff=$(( TEST_NOW_EPOCH - 100 ))
printf '{"ts":%s,"session_id":"ttl-stale","walltime_s":5}\n' \
  "$(( ttl_cutoff - 1 ))" >"${ttl_race_log}"
printf '{"ts":%s,"session_id":"ttl-fresh","walltime_s":5}\n' \
  "${TEST_NOW_EPOCH}" >>"${ttl_race_log}"
ttl_race_ready="${TEST_STATE_ROOT}/timing-ttl.ready"
ttl_race_release="${TEST_STATE_ROOT}/timing-ttl.release"
ttl_writer_done="${TEST_STATE_ROOT}/timing-ttl-writer.done"
(
  export OMC_TEST_TIMING_TTL_READY_FILE="${ttl_race_ready}"
  export OMC_TEST_TIMING_TTL_RELEASE_FILE="${ttl_race_release}"
  with_cross_session_log_lock "${ttl_race_log}" \
    _sweep_retain_timing_locked "${ttl_race_log}" "${ttl_cutoff}" 10000 8000
) &
ttl_owner_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${ttl_race_ready}" ]] && break
  sleep 0.01
done
assert_eq "TTL filter reaches deterministic pre-rename barrier" "1" \
  "$([[ -e "${ttl_race_ready}" ]] && printf 1 || printf 0)"
(
  timing_record_session_summary \
    '{"walltime_s":5,"prompt_count":1,"tokens_main_out":54}'
  : >"${ttl_writer_done}"
) &
ttl_writer_pid=$!
sleep 0.1
assert_eq "summary writer waits behind TTL transaction" "0" \
  "$([[ -e "${ttl_writer_done}" ]] && printf 1 || printf 0)"
: >"${ttl_race_release}"
wait "${ttl_owner_pid}"
wait "${ttl_writer_pid}"
assert_eq "TTL transaction removes only the stale row" "0" \
  "$(jq -s '[.[] | select(.session_id == "ttl-stale")] | length' \
    "${ttl_race_log}")"
assert_eq "TTL transaction retains the pre-existing fresh row" "1" \
  "$(jq -s '[.[] | select(.session_id == "ttl-fresh")] | length' \
    "${ttl_race_log}")"
assert_eq "post-filter summary append survives" "1" \
  "$(jq -s --arg sid "${SESSION_ID}" \
    '[.[] | select(.session_id == $sid and .tokens_main_out == 54)] | length' \
    "${ttl_race_log}")"
SESSION_ID="${saved_session_id}"

# ----------------------------------------------------------------------
printf '\n=== Timing Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
