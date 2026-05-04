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
timing_append_prompt_start 1
timing_append_start "Bash" "" "" 1
sleep 1
timing_append_end "Bash" "" 1
sleep 1
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
printf 'Test 20: timing_format_full renders polished epilogue scaffold\n'
# Polished epilogue must include: ─── title rule, stacked-bar legend with
# pct breakdown, per-bucket rows, residual note, and closing insight when
# any rule fires. Substring-grade so cosmetic char tweaks don't churn tests.
reset_log
timing_append_prompt_start 300
timing_append_start "Agent" "" "excellence-reviewer" 300
sleep 1
timing_append_end "Agent" "" 300
timing_append_start "Bash" "" "" 300
sleep 1
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
# Schema regression net: Stop hooks do NOT support
# `hookSpecificOutput.additionalContext` (silently dropped by Claude Code).
# The documented user-visible Stop output field is `systemMessage`. v1.24.0
# and v1.25.0 shipped using the wrong field; the bug surfaced when a
# user noticed the polished card never appeared. Both the positive
# `systemMessage` assertion and the negative `hookSpecificOutput` assertion
# are required to catch a future regression.
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
jq -nc --arg sid "${hook_session}" '{prompt_seq:1,session_id:$sid}' \
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
jq -nc --arg sid "${sub_session}" '{prompt_seq:1,session_id:$sid}' \
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
printf '\n=== Timing Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
