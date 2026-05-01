#!/usr/bin/env bash
# Tests for the time-tracking subsystem (lib/timing.sh + pretool/posttool
# hooks + Stop epilogue + show-time). Cover the load-bearing behaviors:
# lock-free append correctness, FIFO/LIFO pairing, prompt-seq epoch
# isolation, opt-out fast-path, aggregator math, format helpers, Stop
# self-suppression on recent block, and show-time empty-state vs populated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

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
printf 'Test 2: simple Bash start+end pair aggregates correctly\n'
reset_log
# DEBUG: capture-path diagnostic for CI portability investigation
printf '  DEBUG: OMC_TIME_TRACKING=%s SESSION_ID=%s\n' "${OMC_TIME_TRACKING:-UNSET}" "${SESSION_ID:-UNSET}" >&2
printf '  DEBUG: STATE_ROOT=%s\n' "${STATE_ROOT:-UNSET}" >&2
printf '  DEBUG: timing_log_path=%s\n' "$(timing_log_path)" >&2
printf '  DEBUG: session_dir_exists=%s\n' "$([ -d "${STATE_ROOT}/${SESSION_ID}" ] && echo YES || echo NO)" >&2
printf '  DEBUG: jq_smoke=%s\n' "$(jq -nc '{ok:true}' 2>&1)" >&2
timing_append_prompt_start 1
timing_append_start "Bash" "" "" 1
printf '  DEBUG: log_after_start exists=%s lines=%s\n' \
  "$([ -f "$(timing_log_path)" ] && echo YES || echo NO)" \
  "$(wc -l < "$(timing_log_path)" 2>/dev/null || echo 0)" >&2
sleep 1
timing_append_end "Bash" "" 1
sleep 1
timing_append_prompt_end 1 2
printf '  DEBUG: log_after_all exists=%s lines=%s\n' \
  "$([ -f "$(timing_log_path)" ] && echo YES || echo NO)" \
  "$(wc -l < "$(timing_log_path)" 2>/dev/null || echo 0)" >&2
if [[ -f "$(timing_log_path)" ]]; then
  printf '  DEBUG: log_content=\n' >&2
  cat "$(timing_log_path)" >&2
fi

agg="$(timing_aggregate "$(timing_log_path)")"
printf '  DEBUG: agg=%s\n' "${agg}" >&2
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
sleep 1
# Ends arrive in REVERSE order (end-B before end-A) — tool_use_id must rescue
timing_append_end "Bash" "id-B" 2
sleep 1
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
sleep 1
timing_append_end "Agent" "ag-1" 3
timing_append_start "Agent" "ag-2" "metis" 3
sleep 1
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
sleep 1
timing_append_end "Bash" "" 10
timing_append_prompt_end 10 1
# Next prompt
timing_append_prompt_start 11
timing_append_start "Bash" "" "" 11
sleep 1
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
printf 'Test 7: oneline format renders bucket totals\n'
reset_log
timing_append_prompt_start 20
timing_append_start "Bash" "" "" 20
sleep 1
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
sleep 1
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

# ----------------------------------------------------------------------
printf 'Test 12: lock-free append survives 30 concurrent writers\n'
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
    prompt_count:1}' >> "${xs_log}"
jq -nc --arg session "s2" --argjson now "$(now_epoch)" \
  '{ts:$now,session:$session,project_key:"p1",walltime_s:120,agent_total_s:80,
    tool_total_s:30,idle_model_s:10,
    agent_breakdown:{"quality-reviewer":50,"metis":30},
    tool_breakdown:{"Bash":20,"Read":10},
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

# ----------------------------------------------------------------------
printf 'Test 14: Stop self-suppression detects recent block\n'
gates="$(session_file "gate_events.jsonl")"
rm -f "${gates}"
record_gate_event "quality" "block" "block_count=1" "block_cap=1"
# stop-time-summary.sh suppresses when last block ts is within 3s. Verify
# the heuristic on the file we just wrote by reading it the same way.
recent="$(tail -n 5 "${gates}" 2>/dev/null \
  | jq -rs '[.[] | select(.event=="block")] | sort_by(.ts // 0) | last | (.ts // 0)')"
now_ts="$(now_epoch)"
delta=$(( now_ts - recent ))
if (( delta <= 3 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: recent-block detection failed: delta=%s\n' "${delta}" >&2
  fail=$((fail + 1))
fi

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
session_rows="$(jq -sr --arg sid "${SESSION_ID}" \
  '[.[] | select((.session // "") == $sid)] | length' "${xs_log}" 2>/dev/null)"
assert_eq "single row per session after multi-Stop" "1" "${session_rows}"

# The surviving row must carry the LATEST walltime, not a stale earlier one.
final_walltime="$(jq -sr --arg sid "${SESSION_ID}" \
  '[.[] | select((.session // "") == $sid)] | first | .walltime_s' "${xs_log}" 2>/dev/null)"
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
surviving_session="$(jq -r '.session' "${xs_log}")"
assert_eq "fresh row survived real sweep" "fresh-session" "${surviving_session}"

# ----------------------------------------------------------------------
printf 'Test 19a: prompt_seq slice isolates a single prompt\n'
reset_log
SESSION_ID="timing-test-session"
# Prompt 100: 1 Bash call, 1s
timing_append_prompt_start 100
timing_append_start "Bash" "" "" 100
sleep 1
timing_append_end "Bash" "" 100
timing_append_prompt_end 100 1
# Prompt 101: 2 Read calls + 1 Agent call
timing_append_prompt_start 101
timing_append_start "Read" "" "" 101
timing_append_end "Read" "" 101
timing_append_start "Agent" "" "metis" 101
sleep 1
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

# ----------------------------------------------------------------------
printf 'Test 19b: aggregator emits call-count maps\n'
reset_log
timing_append_prompt_start 200
timing_append_start "Read" "" "" 200
timing_append_end "Read" "" 200
timing_append_start "Read" "" "" 200
timing_append_end "Read" "" 200
timing_append_start "Bash" "" "" 200
sleep 1
timing_append_end "Bash" "" 200
timing_append_prompt_end 200 1

agg="$(timing_aggregate "$(timing_log_path)")"
read_calls="$(jq -r '.tool_calls.Read // 0' <<<"${agg}")"
bash_calls="$(jq -r '.tool_calls.Bash // 0' <<<"${agg}")"
assert_eq "Read call count" "2" "${read_calls}"
assert_eq "Bash call count" "1" "${bash_calls}"

# ----------------------------------------------------------------------
printf 'Test 19: Stop self-suppression does NOT fire when block is stale\n'
# stop-time-summary.sh's heuristic must skip suppression when the most
# recent block in gate_events.jsonl is older than 3 seconds. Otherwise a
# session that blocked 30 minutes ago would silently lose every subsequent
# Stop's time summary.
gates="$(session_file "gate_events.jsonl")"
rm -f "${gates}"
old_block_ts=$(( $(now_epoch) - 60 ))
jq -nc --argjson ts "${old_block_ts}" \
  '{ts:$ts,gate:"quality",event:"block",block_count:1,block_cap:1,details:{}}' >> "${gates}"

recent_block_ts="$(tail -n 5 "${gates}" 2>/dev/null \
  | jq -rs '[.[] | select(.event=="block")] | sort_by(.ts // 0) | last | (.ts // 0)')"
delta=$(( $(now_epoch) - recent_block_ts ))
if (( delta > 3 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: stale block treated as recent: delta=%s\n' "${delta}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf '\n=== Timing Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
