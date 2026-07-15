#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
#
# tests/test-token-tracking.sh — v1.46-pre token-usage tracking.
#
# Covers the transcript-sourced token capture that rides the timing
# subsystem: timing_fmt_tokens (compact formatter), the incremental
# cursor-based capture (timing_capture_session_tokens), timing_aggregate's
# token_delta summation, and the timing_token_line renderer. The capture
# is the load-bearing piece — it must count every API request exactly once
# even when Claude Code repeats cumulative usage across thinking/text/tool
# rows, split main vs sub-agent (isSidechain), survive a compaction rewrite
# (shrink guard), and fail open.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
export SESSION_ID="tok-test"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
# common.sh resolves lib/ from its own dir via BASH_SOURCE; sourcing the
# repo bundle path directly works (mirrors test-prompt-router-synthetic.sh).
mkdir -p "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${TEST_HOME}/.claude/skills/autowork"

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

# shellcheck source=/dev/null
. "${COMMON_SH}"

pass=0
fail=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=  %q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

TRANSCRIPT="${TEST_HOME}/transcript.jsonl"
# Fresh session per scenario — distinct SESSION_ID gives each scenario a
# clean state file + timing log without deleting mid-session state (which
# is not a production path and trips write_state's read-existing jq).
_sc=0
LOG=""
new_session() {
  _sc=$((_sc + 1))
  SESSION_ID="tok-test-${_sc}"
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
  LOG="${STATE_ROOT}/${SESSION_ID}/timing.jsonl"
  # Reset the process-global state-validation cache. Production runs one
  # SESSION_ID per process; this test exercises several in one process, so
  # the `_state_validated` short-circuit in _ensure_valid_state must be
  # cleared or write_state skips creating the new session's state file.
  _state_validated=0
}
new_session

# --- timing_fmt_tokens ---------------------------------------------------
printf '\n--- timing_fmt_tokens ---\n'
assert_eq "fmt 1.2M"  "1.2M"  "$(timing_fmt_tokens 1234567)"
assert_eq "fmt 12.3K" "12.3K" "$(timing_fmt_tokens 12345)"
assert_eq "fmt exact 1M" "1.0M" "$(timing_fmt_tokens 1000000)"
assert_eq "fmt sub-1k" "920"   "$(timing_fmt_tokens 920)"
assert_eq "fmt zero"   "0"     "$(timing_fmt_tokens 0)"
assert_eq "fmt junk->0" "0"    "$(timing_fmt_tokens abc)"
assert_eq "normalize digit string avoids Bash octal" "8" \
  "$(timing_normalize_uint 08)"
assert_eq "fmt leading-zero digit string" "8" "$(timing_fmt_tokens 08)"
assert_eq "normalize oversized integer caps before arithmetic" \
  "999999999999999" "$(timing_normalize_uint 999999999999999999999999999999)"
assert_eq "formatter handles oversized integer without wrap" \
  "999999999.9M" "$(timing_fmt_tokens 999999999999999999999999999999)"
assert_eq "token line normalizes numeric JSON strings" \
  "tokens   in 8 (0% cached) · out 8" \
  "$(timing_token_line '{"tokens_main_in":"08","tokens_main_out":"08"}')"

# --- capture: first call on a FRESH session (seq 1, cursor 0 -> 5) --------
printf '\n--- timing_capture_session_tokens: first capture ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":20000,"cache_creation_input_tokens":3000}}}
{"type":"user","message":{"content":[{"type":"tool_result"}]}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":200,"output_tokens":800,"cache_read_input_tokens":21000,"cache_creation_input_tokens":0}}}
{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":5000,"output_tokens":1500,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000}}}
EOF
# Fresh session, first prompt (seq 1): count from row 0 so prompt 1's
# tokens are captured.
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "cursor advanced to 5" "5" "$(read_state token_transcript_rows)"
assert_eq "one token_delta row" "1" "$(grep -c token_delta "${LOG}" 2>/dev/null || echo 0)"

agg="$(timing_aggregate "${LOG}")"
assert_eq "main_in summed"  "1200"  "$(jq -r '.tokens_main_in' <<<"${agg}")"
assert_eq "main_out summed" "1300"  "$(jq -r '.tokens_main_out' <<<"${agg}")"
assert_eq "main_cache_read" "41000" "$(jq -r '.tokens_main_cache_read' <<<"${agg}")"
assert_eq "agent_in"        "5000"  "$(jq -r '.tokens_agent_in' <<<"${agg}")"
assert_eq "agent_out"       "1500"  "$(jq -r '.tokens_agent_out' <<<"${agg}")"
assert_eq "agent_cache_read" "40000" "$(jq -r '.tokens_agent_cache_read' <<<"${agg}")"

# token line: in=1200+41000+3000+5000+40000+2000=92200, out=2800,
# cached=81000/92200=87%, agent=48500/95000=51%
assert_eq "token line" "tokens   in 92.2K (87% cached) · out 2.8K · agents 51%" \
  "$(timing_token_line "${agg}")"
assert_eq "format_full contains token line" "1" \
  "$(timing_format_full "${agg}" "T" 2>/dev/null | grep -c 'in 92.2K (87% cached)' || echo 0)"

# --- incremental capture (cursor 5 -> 6) ---------------------------------
printf '\n--- incremental capture ---\n'
echo '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"output_tokens":2000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":0}}}' >> "${TRANSCRIPT}"
timing_capture_session_tokens "${TRANSCRIPT}" 4
assert_eq "cursor advanced to 6" "6" "$(read_state token_transcript_rows)"
assert_eq "two token_delta rows" "2" "$(grep -c token_delta "${LOG}")"
agg2="$(timing_aggregate "${LOG}")"
assert_eq "main_out now 3300"        "3300"  "$(jq -r '.tokens_main_out' <<<"${agg2}")"
assert_eq "main_cache_read now 91000" "91000" "$(jq -r '.tokens_main_cache_read' <<<"${agg2}")"

# --- no new rows: no new delta, cursor stable ----------------------------
printf '\n--- idempotent on no new rows ---\n'
timing_capture_session_tokens "${TRANSCRIPT}" 4
assert_eq "still two delta rows" "2" "$(grep -c token_delta "${LOG}")"
assert_eq "cursor stable at 6" "6" "$(read_state token_transcript_rows)"

# --- compaction guard: file shrinks below cursor -------------------------
printf '\n--- compaction (transcript rewrite) guard ---\n'
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":0}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 5
# shrank to 1 row < cursor 6 -> cursor reset to 0, the 1 row counted
assert_eq "cursor reset to 1 after shrink" "1" "$(read_state token_transcript_rows)"
assert_eq "three token_delta rows after compaction" "3" "$(grep -c token_delta "${LOG}")"

# --- all-zero slice writes no row but advances cursor --------------------
printf '\n--- usage-free slice ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"user","message":{"content":[{"type":"tool_result"}]}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "no delta row for usage-free slice" "0" "$(grep -c token_delta "${LOG}" 2>/dev/null || echo 0)"
assert_eq "cursor still advanced to 2" "2" "$(read_state token_transcript_rows)"

# Cursor/totals state is the durable side of capture. A failed state commit
# must not append a delta that would be counted again on retry.
printf '\n--- failed state commit appends no token detail ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
EOF
_saved_write_state_batch="$(declare -f write_state_batch)"
write_state_batch() { return 1; }
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "failed commit: no delta/checkpoint appended" "0" \
  "$(grep -Ec 'token_(delta|checkpoint)' "${LOG}" 2>/dev/null || echo 0)"
assert_eq "failed commit: cursor remains retryable" "" "$(read_state token_transcript_rows)"
eval "${_saved_write_state_batch}"

# A valid session-state object may still contain pre-schema or hand-edited
# nested token buckets. The merge boundary must repair those shapes while
# retaining the fresh slice exactly; otherwise the cursor would consume the
# transcript row and make its role/model/dispatch attribution unrecoverable.
printf '\n--- malformed persisted token totals self-heal ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":1,"cache_creation_input_tokens":0}}}
EOF
_poison_agent_dir="${TRANSCRIPT%.jsonl}/subagents"
mkdir -p "${_poison_agent_dir}"
cat > "${_poison_agent_dir}/poison-fresh.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"agentId":"poison-fresh","attributionAgent":"quality-reviewer","message":{"model":"session-model","usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}}
EOF
_poisoned_totals='{"main_in":"bad","main_out":-4,"agent_in":1.5,"usage_rows":"not-a-count","agent_by_role":42,"agent_by_model":{"old-model":{"input":"bad","output":-9,"cache_read":1.5}},"agent_by_id":[]}'
write_state_batch \
  "token_tracking_initialized" "1" \
  "token_transcript_cursors" "{}" \
  "token_totals" "${_poisoned_totals}"
timing_capture_session_tokens "${TRANSCRIPT}" 2
_healed_totals="$(read_state token_totals)"
assert_eq "poisoned totals: fresh aggregate survives numeric repair" \
  "5,2,7,3,2" \
  "$(jq -r '[.main_in,.main_out,.agent_in,.agent_out,.usage_rows] | join(",")' <<<"${_healed_totals}")"
assert_eq "poisoned totals: every attribution map heals to an object" "true" \
  "$(jq -r '[.agent_by_role,.agent_by_model,.agent_by_id] | all(.[]; type == "object")' <<<"${_healed_totals}")"
assert_eq "poisoned totals: fresh role attribution is not lost" "3" \
  "$(jq -r '.agent_by_role["quality-reviewer"].output' <<<"${_healed_totals}")"
assert_eq "poisoned totals: fresh model attribution is not lost" "7" \
  "$(jq -r '.agent_by_model["session-model"].input' <<<"${_healed_totals}")"
assert_eq "poisoned totals: fresh dispatch attribution is not lost" "1" \
  "$(jq -r '.agent_by_id["poison-fresh"].cache_creation' <<<"${_healed_totals}")"
assert_eq "poisoned totals: malformed nested numerics normalize" "0,0,0,0" \
  "$(jq -r '.agent_by_model["old-model"] | [.input,.output,.cache_read,.cache_creation] | join(",")' <<<"${_healed_totals}")"
assert_eq "poisoned totals: cursor advances only with retained attribution" "1" \
  "$(read_state token_transcript_rows)"

# A genuine jq/merge failure must leave both sides of the cursor+totals
# transaction untouched. The public hook remains fail-open, and the next Stop
# retries the same complete transcript slice after the local fault clears.
printf '\n--- token merge failure leaves cursor retryable ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":11,"output_tokens":13,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF
_saved_add_token_totals="$(declare -f _timing_add_token_totals)"
_timing_add_token_totals() { return 1; }
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "merge failure: cursor does not consume the slice" "" \
  "$(read_state token_transcript_rows)"
assert_eq "merge failure: totals do not commit without the slice" "" \
  "$(read_state token_totals)"
assert_eq "merge failure: no detail or checkpoint is appended" "0" \
  "$(grep -Ec 'token_(delta|checkpoint)' "${LOG}" 2>/dev/null || echo 0)"
eval "${_saved_add_token_totals}"
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "merge retry: cursor advances after the exact slice is retained" "1" \
  "$(read_state token_transcript_rows)"
assert_eq "merge retry: previously failed slice is counted once" "13" \
  "$(read_state token_totals | jq -r '.main_out')"

# --- gating: token_tracking=off skips capture ----------------------------
printf '\n--- token_tracking=off gate ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}
EOF
OMC_TOKEN_TRACKING=off timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "off: no log written" "0" "$(grep -c token_delta "${LOG}" 2>/dev/null || echo 0)"
assert_eq "off: cursor untouched" "" "$(read_state token_transcript_rows)"

# --- off->on mid-session: seq>1 + absent cursor seeds + skips backlog ----
printf '\n--- off->on mid-session backlog skip ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":9000,"output_tokens":9000,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0}}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":9000,"output_tokens":9000,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0}}}
EOF
# Tracking enabled at prompt 5 on a session that already ran: the pre-
# tracking backlog must NOT be attributed to one giant delta.
timing_capture_session_tokens "${TRANSCRIPT}" 5
assert_eq "off->on: backlog skipped (no delta)" "0" "$(grep -c token_delta "${LOG}" 2>/dev/null || echo 0)"
assert_eq "off->on: cursor seeded to 2" "2" "$(read_state token_transcript_rows)"
# The next prompt's tokens ARE counted (incremental from the seed).
echo '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":0}}}' >> "${TRANSCRIPT}"
timing_capture_session_tokens "${TRANSCRIPT}" 6
assert_eq "off->on: post-enable prompt counted" "1" "$(grep -c token_delta "${LOG}")"
assert_eq "off->on: counts only post-enable row (out=200)" "200" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"

# Recovery/rotation can leave checkpoint lines out of physical order. Whole-
# session aggregation selects the newest prompt/time checkpoint, not last line.
printf '\n--- chronological checkpoint selection ---\n'
new_session
cat > "${LOG}" <<'EOF'
{"kind":"token_checkpoint","ts":200,"prompt_seq":2,"main_out":20}
{"kind":"token_checkpoint","ts":100,"prompt_seq":1,"main_out":999}
EOF
assert_eq "newest checkpoint wins over last physical line" "20" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"

# A killed/non-atomic append can leave malformed JSON between later valid
# checkpoints. Parse each line independently so the next complete checkpoint
# heals the session. Typed-invalid and oversized values are ignored/capped
# rather than reaching Bash arithmetic or poisoning the whole aggregate.
printf '\n--- malformed timing rows recover line-by-line ---\n'
new_session
cat > "${LOG}" <<'EOF'
{"kind":"token_checkpoint","ts":100,"prompt_seq":1,"main_out":20}
{"kind":"token_checkpoint","ts":150,"prompt_seq":2,"main_out":
{"kind":"token_checkpoint","ts":200,"prompt_seq":3,"main_out":30}
{"kind":"token_checkpoint","ts":250
EOF
assert_eq "valid checkpoint after malformed middle row survives" "30" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
printf '%s\n' \
  '{"kind":"token_checkpoint","ts":300,"prompt_seq":4,"main_out":40}' \
  '{"kind":"token_checkpoint","ts":400,"prompt_seq":5,"main_out":"08"}' \
  >> "${LOG}"
assert_eq "typed-invalid newer checkpoint cannot replace valid total" "40" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
printf '%s\n' \
  '{"kind":"token_checkpoint","ts":500,"prompt_seq":6,"main_out":999999999999999999999999}' \
  >> "${LOG}"
assert_eq "oversized numeric checkpoint cannot replace valid total" "40" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"

# --- request-level dedupe, including a request spanning Stop cursors -----
# Real Claude Code transcripts repeat one request's cumulative usage on its
# thinking, text, and tool_use rows. requestId is preferred; message.id is the
# compatibility fallback. Component-wise maxima preserve a later cumulative
# output snapshot without multiplying unchanged input/cache usage.
printf '\n--- repeated request rows + cross-cursor dedupe ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"req-main-1","message":{"id":"msg-main-1","model":"claude-main","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}
{"type":"assistant","requestId":"req-main-1","message":{"id":"msg-main-1","model":"claude-main","usage":{"input_tokens":100,"output_tokens":25,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}
{"type":"assistant","requestId":"req-main-1","message":{"id":"msg-main-1","model":"claude-main","usage":{"input_tokens":100,"output_tokens":25,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}
EOF
AGENT_DIR="${TRANSCRIPT%.jsonl}/subagents"
rm -rf "${TRANSCRIPT%.jsonl}"
mkdir -p "${AGENT_DIR}"
cat > "${AGENT_DIR}/dedupe-agent.jsonl" <<'EOF'
{"type":"assistant","requestId":"req-agent-1","isSidechain":true,"attributionAgent":"quality-reviewer","message":{"id":"msg-agent-1","model":"claude-sonnet-test","usage":{"input_tokens":200,"output_tokens":30,"cache_read_input_tokens":2000,"cache_creation_input_tokens":75}}}
{"type":"assistant","requestId":"req-agent-1","isSidechain":true,"message":{"id":"msg-agent-1","usage":{"input_tokens":200,"output_tokens":45,"cache_read_input_tokens":2000,"cache_creation_input_tokens":75}}}
{"type":"assistant","requestId":"req-agent-1","isSidechain":true,"message":{"id":"msg-agent-1","usage":{"input_tokens":200,"output_tokens":45,"cache_read_input_tokens":2000,"cache_creation_input_tokens":75}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 1
dedupe_agg="$(timing_aggregate "${LOG}")"
assert_eq "dedupe: repeated main request input counted once" "100" \
  "$(jq -r '.tokens_main_in' <<<"${dedupe_agg}")"
assert_eq "dedupe: main request uses maximum cumulative output" "25" \
  "$(jq -r '.tokens_main_out' <<<"${dedupe_agg}")"
assert_eq "dedupe: repeated agent request cache counted once" "2000" \
  "$(jq -r '.tokens_agent_cache_read' <<<"${dedupe_agg}")"
assert_eq "dedupe: agent request uses maximum cumulative output" "45" \
  "$(jq -r '.tokens_agent_out' <<<"${dedupe_agg}")"
assert_eq "dedupe: usage rows represent two API requests" "2" \
  "$(jq -r '.token_usage_rows' <<<"${dedupe_agg}")"

# The next Stop sees another content-block snapshot for the same request.
# Only its positive cumulative output delta is new; input/cache and request
# count remain unchanged across the persisted cursor boundary.
cat >> "${AGENT_DIR}/dedupe-agent.jsonl" <<'EOF'
{"type":"assistant","requestId":"req-agent-1","isSidechain":true,"message":{"id":"msg-agent-1","usage":{"input_tokens":200,"output_tokens":55,"cache_read_input_tokens":2000,"cache_creation_input_tokens":75}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 2
dedupe_agg="$(timing_aggregate "${LOG}")"
assert_eq "dedupe: cross-cursor request adds only output growth" "55" \
  "$(jq -r '.tokens_agent_out' <<<"${dedupe_agg}")"
assert_eq "dedupe: cross-cursor request does not recount cache" "2000" \
  "$(jq -r '.tokens_agent_cache_read' <<<"${dedupe_agg}")"
assert_eq "dedupe: cross-cursor request count remains stable" "2" \
  "$(jq -r '.token_usage_rows' <<<"${dedupe_agg}")"
assert_eq "dedupe: cross-cursor omission retains prior role attribution" "55" \
  "$(jq -r '.agent_tokens_by_role["quality-reviewer"].output' <<<"${dedupe_agg}")"
assert_eq "dedupe: cross-cursor omission retains prior model attribution" "55" \
  "$(jq -r '.agent_tokens_by_model["claude-sonnet-test"].output' <<<"${dedupe_agg}")"
assert_eq "dedupe: cross-cursor omission creates no fallback buckets" "0" \
  "$(jq -r '([.agent_tokens_by_role["general-purpose"],.agent_tokens_by_model.unknown] | map(select(. != null)) | length)' <<<"${dedupe_agg}")"

# A partial/regressed cumulative row must not lower the durable request
# baseline. Otherwise a later value below the true high-water mark is charged
# as fresh growth (55 -> 40 -> 50 used to produce 65), and an omitted cache
# component can be charged a second time when it reappears.
cat >> "${AGENT_DIR}/dedupe-agent.jsonl" <<'EOF'
{"type":"assistant","requestId":"req-agent-1","isSidechain":true,"message":{"id":"msg-agent-1","usage":{"input_tokens":200,"output_tokens":40}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 3
cat >> "${AGENT_DIR}/dedupe-agent.jsonl" <<'EOF'
{"type":"assistant","requestId":"req-agent-1","isSidechain":true,"message":{"id":"msg-agent-1","usage":{"input_tokens":200,"output_tokens":50,"cache_read_input_tokens":2000,"cache_creation_input_tokens":75}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 4
dedupe_agg="$(timing_aggregate "${LOG}")"
assert_eq "dedupe: regressed-then-rising output stays at high-water mark" "55" \
  "$(jq -r '.tokens_agent_out' <<<"${dedupe_agg}")"
assert_eq "dedupe: omitted-then-restored cache is not double-counted" "2000" \
  "$(jq -r '.tokens_agent_cache_read' <<<"${dedupe_agg}")"
assert_eq "dedupe: regressed snapshots do not create API requests" "2" \
  "$(jq -r '.token_usage_rows' <<<"${dedupe_agg}")"

# message.id alone is a valid request identity on transcript variants that do
# not expose requestId.
cat >> "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"","message":{"id":"msg-main-2","model":"claude-main","usage":{"input_tokens":7,"output_tokens":5,"cache_read_input_tokens":11,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"","message":{"id":"msg-main-2","model":"claude-main","usage":{"input_tokens":7,"output_tokens":5,"cache_read_input_tokens":11,"cache_creation_input_tokens":0}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 5
dedupe_agg="$(timing_aggregate "${LOG}")"
assert_eq "dedupe: message.id fallback counts request once" "30" \
  "$(jq -r '.tokens_main_out' <<<"${dedupe_agg}")"
assert_eq "dedupe: message.id fallback increments request count once" "3" \
  "$(jq -r '.token_usage_rows' <<<"${dedupe_agg}")"

# Older transcript variants can carry sidechain rows in the parent file. A
# later content-block row for the same request may omit isSidechain as well as
# attribution metadata; once any row proves agent provenance, the complete
# request must stay in the agent bucket within and across Stop cursors.
printf '\n--- parent-sidechain classification retention ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"parent-agent-request","isSidechain":true,"attributionAgent":"oracle","message":{"id":"parent-agent-message","model":"session-model","usage":{"input_tokens":9,"output_tokens":10}}}
{"type":"assistant","requestId":"parent-agent-request","message":{"id":"parent-agent-message","usage":{"input_tokens":9,"output_tokens":20}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 1
_parent_agent_agg="$(timing_aggregate "${LOG}")"
assert_eq "parent sidechain: within-slice omission remains agent work" "20" \
  "$(jq -r '.tokens_agent_out' <<<"${_parent_agent_agg}")"
assert_eq "parent sidechain: within-slice omission creates no main work" "0" \
  "$(jq -r '.tokens_main_out' <<<"${_parent_agent_agg}")"
assert_eq "parent sidechain: within-slice role/model metadata survives" "20" \
  "$(jq -r '.agent_tokens_by_role.oracle.output' <<<"${_parent_agent_agg}")"
cat >> "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"parent-agent-request","message":{"id":"parent-agent-message","usage":{"input_tokens":9,"output_tokens":25}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 2
_parent_agent_agg="$(timing_aggregate "${LOG}")"
assert_eq "parent sidechain: cross-cursor omission remains agent work" "25" \
  "$(jq -r '.tokens_agent_out' <<<"${_parent_agent_agg}")"
assert_eq "parent sidechain: cross-cursor omission retains role bucket" "25" \
  "$(jq -r '.agent_tokens_by_role.oracle.output' <<<"${_parent_agent_agg}")"
assert_eq "parent sidechain: cross-cursor omission retains model bucket" "25" \
  "$(jq -r '.agent_tokens_by_model["session-model"].output' <<<"${_parent_agent_agg}")"

# Mid-session enable seeds both the row cursor and its trailing request. A
# duplicate snapshot appended after enable is not a giant false first delta.
printf '\n--- mid-enable trailing request seed ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"req-before-enable","message":{"id":"msg-before-enable","usage":{"input_tokens":900,"output_tokens":100,"cache_read_input_tokens":9000}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 5
cat >> "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"req-before-enable","message":{"id":"msg-before-enable","usage":{"input_tokens":900,"output_tokens":100,"cache_read_input_tokens":9000}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 6
assert_eq "mid-enable dedupe: identical trailing snapshot adds nothing" "0" \
  "$(grep -c token_delta "${LOG}" 2>/dev/null || echo 0)"
cat >> "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","requestId":"req-before-enable","message":{"id":"msg-before-enable","usage":{"input_tokens":900,"output_tokens":120,"cache_read_input_tokens":9000}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 7
assert_eq "mid-enable dedupe: later cumulative growth is counted" "20" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
assert_eq "mid-enable dedupe: pre-enable input is not backfilled" "0" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_in')"

# --- real nested sidechain layout + attribution -------------------------
printf '\n--- nested subagent transcripts + role/model attribution ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}
EOF
AGENT_DIR="${TRANSCRIPT%.jsonl}/subagents"
rm -rf "${TRANSCRIPT%.jsonl}"
mkdir -p "${AGENT_DIR}"
cat > "${AGENT_DIR}/agent-a.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"agentId":"a","attributionAgent":"quality-reviewer","message":{"model":"claude-sonnet-test","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":400}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 1
nested_agg="$(timing_aggregate "${LOG}")"
assert_eq "nested: main row counted as main" "10" "$(jq -r '.tokens_main_in' <<<"${nested_agg}")"
assert_eq "nested: agent input counted" "100" "$(jq -r '.tokens_agent_in' <<<"${nested_agg}")"
assert_eq "nested: role bucket retained" "200" \
  "$(jq -r '.agent_tokens_by_role["quality-reviewer"].output' <<<"${nested_agg}")"
assert_eq "nested: model bucket retained" "400" \
  "$(jq -r '.agent_tokens_by_model["claude-sonnet-test"].cache_creation' <<<"${nested_agg}")"
assert_eq "nested: native dispatch bucket retained" "200" \
  "$(jq -r '.agent_tokens_by_id.a.output' <<<"${nested_agg}")"

# Only the appended sidechain row is counted on the next capture.
cat >> "${AGENT_DIR}/agent-a.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"agentId":"a","attributionAgent":"quality-reviewer","message":{"model":"claude-sonnet-test","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 2
nested_agg="$(timing_aggregate "${LOG}")"
assert_eq "nested: per-file cursor prevents recount" "202" \
  "$(jq -r '.agent_tokens_by_role["quality-reviewer"].output' <<<"${nested_agg}")"
assert_eq "nested: native dispatch cursor prevents recount" "202" \
  "$(jq -r '.agent_tokens_by_id.a.output' <<<"${nested_agg}")"

# A sidechain file created after initialization starts at row zero even on a
# later prompt (unlike the mid-session-enable seed for pre-existing files).
cat > "${AGENT_DIR}/agent-b.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"agentId":"b","attributionAgent":"security-lens","message":{"model":"claude-opus-test","usage":{"input_tokens":7,"output_tokens":8,"cache_read_input_tokens":9,"cache_creation_input_tokens":10}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 3
nested_agg="$(timing_aggregate "${LOG}")"
assert_eq "nested: newly-created file counted from zero" "8" \
  "$(jq -r '.agent_tokens_by_role["security-lens"].output' <<<"${nested_agg}")"
assert_eq "nested: second native dispatch is isolated" "8" \
  "$(jq -r '.agent_tokens_by_id.b.output' <<<"${nested_agg}")"

# Cross-session economics namespaces native IDs by session before merging.
# This is the exact join key used by /ulw-report for stale-run waste.
timing_record_session_summary "${nested_agg}"
assert_eq "nested: cross-session native dispatch key is session-scoped" "202" \
  "$(timing_xs_aggregate 0 | jq -r --arg key "${SESSION_ID}::a" '.agent_tokens_by_dispatch[$key].output')"
_xs_log="$(timing_xs_log_path)"
jq -nc --arg sid "another-session" --argjson ts "$(date +%s)" '{
  _v:1,ts:$ts,session_id:$sid,agent_tokens_by_id:{a:{input:0,output:7,cache_read:0,cache_creation:0}}
}' >> "${_xs_log}"
_xs_ids="$(timing_xs_aggregate 0)"
assert_eq "nested: same native ID in first session remains isolated" "202" \
  "$(jq -r --arg key "${SESSION_ID}::a" '.agent_tokens_by_dispatch[$key].output' <<<"${_xs_ids}")"
assert_eq "nested: same native ID in second session has its own bucket" "7" \
  "$(jq -r '.agent_tokens_by_dispatch["another-session::a"].output' <<<"${_xs_ids}")"
assert_eq "nested: cross-session rollup never emits a bare native ID" "false" \
  "$(jq -r '.agent_tokens_by_dispatch | has("a")' <<<"${_xs_ids}")"

# Imported/legacy ledgers are an untrusted boundary. A malformed row or a
# correctly encoded JSON string in a numeric field must not collapse every
# otherwise valid session into `{}` or reach later Bash arithmetic.
_xs_poison_log="${TEST_HOME}/xs-poison.jsonl"
cat > "${_xs_poison_log}" <<'EOF'
{"ts":100,"session_id":"valid-one","walltime_s":5,"tokens_main_in":12,"agent_tokens_by_role":{"quality-reviewer":{"output":3}}}
{"ts":101,"session_id":"typed-poison","walltime_s":"08","tokens_main_in":"08","agent_breakdown":{"oracle":"08"},"agent_tokens_by_role":{"quality-reviewer":{"output":"08"}}}
{"ts":102,"session_id":"torn-row","tokens_main_in":
{"ts":103,"session_id":"valid-two","walltime_s":3,"tokens_main_in":8,"agent_tokens_by_role":{"quality-reviewer":{"output":2}}}
EOF
_xs_poison_agg="$(timing_xs_aggregate 0 "${_xs_poison_log}")"
assert_eq "cross-session poison: valid rows remain visible" "3" \
  "$(jq -r '.sessions' <<<"${_xs_poison_agg}")"
assert_eq "cross-session poison: string numerics normalize without collapse" "20" \
  "$(jq -r '.tokens_main_in' <<<"${_xs_poison_agg}")"
assert_eq "cross-session poison: walltime remains typed and additive" "8" \
  "$(jq -r '.walltime_s' <<<"${_xs_poison_agg}")"
assert_eq "cross-session poison: bucket values remain typed and additive" "5" \
  "$(jq -r '.agent_tokens_by_role["quality-reviewer"].output' <<<"${_xs_poison_agg}")"

_xs_targeted="$(timing_xs_aggregate 0 "${_xs_log}" "" \
  "$(jq -nc --arg key "${SESSION_ID}::a" '[$key]')")"
assert_eq "nested: targeted cross-session join retains requested key" "202" \
  "$(jq -r --arg key "${SESSION_ID}::a" '.agent_tokens_by_dispatch[$key].output' <<<"${_xs_targeted}")"
assert_eq "nested: targeted cross-session join omits unrelated ID" "false" \
  "$(jq -r '.agent_tokens_by_dispatch | has("another-session::a")' <<<"${_xs_targeted}")"
assert_eq "nested: targeted join preserves non-ID aggregate totals" "210" \
  "$(jq -r '.tokens_agent_out' <<<"${_xs_targeted}")"

# Diagnostic ID detail is recent-bounded without changing aggregate totals.
_id_batch="$(jq -nc '{agent_in:513,agent_by_id:(reduce range(1;514) as $i ({};
  .["id-\($i)"]={input:1,output:0,cache_read:0,cache_creation:0}))}')"
_id_merged="$(_timing_add_token_totals '{}' "${_id_batch}")"
assert_eq "native ID cap: retains exactly 512 recent buckets" "512" \
  "$(jq -r '.agent_by_id | length' <<<"${_id_merged}")"
assert_eq "native ID cap: evicts oldest ID" "false" \
  "$(jq -r '.agent_by_id | has("id-1")' <<<"${_id_merged}")"
assert_eq "native ID cap: retains newest ID" "true" \
  "$(jq -r '.agent_by_id | has("id-513")' <<<"${_id_merged}")"
assert_eq "native ID cap: aggregate token total is not evicted" "513" \
  "$(jq -r '.agent_in' <<<"${_id_merged}")"
_id_touch='{"agent_in":2,"agent_by_id":{"id-2":{"input":1},"id-514":{"input":1}}}'
_id_merged="$(_timing_add_token_totals "${_id_merged}" "${_id_touch}")"
assert_eq "native ID cap: re-touched ID survives next eviction" "true" \
  "$(jq -r '.agent_by_id | has("id-2")' <<<"${_id_merged}")"
assert_eq "native ID cap: least-recent untouched ID is evicted" "false" \
  "$(jq -r '.agent_by_id | has("id-3")' <<<"${_id_merged}")"
assert_eq "native ID cap: newest appended ID survives" "true" \
  "$(jq -r '.agent_by_id | has("id-514")' <<<"${_id_merged}")"

# The cumulative checkpoint is the source for whole-session totals after
# detail rotation. A subsequent delta adds to state, not to a truncated base.
_cap_per_session_jsonl "${LOG}" 1 1
assert_eq "checkpoint survives detail trim" "210" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_agent_out')"
cat >> "${AGENT_DIR}/agent-b.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"agentId":"b","attributionAgent":"security-lens","message":{"model":"claude-opus-test","usage":{"input_tokens":1,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 4
assert_eq "checkpoint remains monotonic after trim + delta" "215" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_agent_out')"

# Custom attribution strings are transcript-controlled. Bound and sanitize
# them before they become persistent JSON object keys / Markdown table cells.
_hostile_role="$(printf 'r%.0s' $(seq 1 140))|bad\`"$'\001'
_hostile_model="$(printf 'm%.0s' $(seq 1 140))|bad\`"$'\002'
jq -nc --arg role "${_hostile_role}" --arg model "${_hostile_model}" \
  '{type:"assistant",isSidechain:true,attributionAgent:$role,message:{model:$model,usage:{input_tokens:1,output_tokens:1,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
  > "${AGENT_DIR}/agent-hostile.jsonl"
timing_capture_session_tokens "${TRANSCRIPT}" 5
_hostile_agg="$(timing_aggregate "${LOG}")"
assert_eq "nested: role/model keys bounded to 96 chars" "true" \
  "$(jq -r '([.agent_tokens_by_role,.agent_tokens_by_model] | map(keys[]) | all(.[]; length <= 96))' <<<"${_hostile_agg}")"
assert_eq "nested: role/model keys strip table/control characters" "true" \
  "$(jq -r '([.agent_tokens_by_role,.agent_tokens_by_model] | map(keys[]) | all(.[]; (contains("|") or contains("`") or test("[\u0000-\u001f\u007f]")) | not))' <<<"${_hostile_agg}")"

# Replacing a transcript with the same row count changes its file identity,
# so the new content cannot inherit the old cursor and disappear.
printf '\n--- transcript replacement identity guard ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":10}}}
EOF
timing_capture_session_tokens "${TRANSCRIPT}" 1
replacement="${TRANSCRIPT}.replacement"
cat > "${replacement}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":2,"output_tokens":20}}}
EOF
mv "${replacement}" "${TRANSCRIPT}"
timing_capture_session_tokens "${TRANSCRIPT}" 2
assert_eq "replacement identity resets cursor" "30" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"

# --- e2e: stop-time-summary.sh wires capture end-to-end ------------------
# Makes the CHANGELOG's "end-to-end real-transcript hook check" claim true:
# drives the actual Stop hook (separate process, reads transcript_path from
# the payload) and asserts it both writes a token_delta row AND renders the
# token line in the card systemMessage.
printf '\n--- e2e: stop-time-summary.sh hook ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":500,"output_tokens":1500,"cache_read_input_tokens":80000,"cache_creation_input_tokens":4000}}}
{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":2000,"output_tokens":900,"cache_read_input_tokens":30000,"cache_creation_input_tokens":0}}}
EOF
_e2e_now="$(date +%s)"; _e2e_start=$((_e2e_now - 12))
printf '{"kind":"prompt_start","ts":%s,"prompt_seq":1}\n' "${_e2e_start}" > "${LOG}"
printf '{"prompt_seq":"1"}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
_e2e_payload="$(jq -nc --arg s "${SESSION_ID}" --arg t "${TRANSCRIPT}" '{session_id:$s, transcript_path:$t}')"
_e2e_card="$(printf '%s' "${_e2e_payload}" | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-time-summary.sh" 2>/dev/null || true)"
assert_eq "e2e: hook wrote a token_delta row" "1" "$(grep -c token_delta "${LOG}" 2>/dev/null || echo 0)"
assert_eq "e2e: card systemMessage carries the token line" "1" \
  "$(printf '%s' "${_e2e_card}" | jq -r '.systemMessage // ""' 2>/dev/null | grep -c 'tokens   in ' || echo 0)"

# --- blocked Stop attempts still capture economics ----------------------
printf '\n--- blocked Stop token capture ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":11,"output_tokens":22,"cache_read_input_tokens":33,"cache_creation_input_tokens":44}}}
EOF
_blocked_now="$(date +%s)"
printf '{"kind":"prompt_start","ts":%s,"prompt_seq":1}\n' "$((_blocked_now - 2))" > "${LOG}"
jq -nc --argjson ts "${_blocked_now}" '{
  prompt_seq:"1",
  stop_guard_attempt_seq:"1",
  last_stop_block_attempt_seq:"1",
  last_stop_block_ts:($ts|tostring)
}' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
printf '{"_v":1,"ts":%s,"gate":"quality","event":"block","details":{}}\n' "${_blocked_now}" \
  > "${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
rm -f "${HOME}/.claude/quality-pack/timing.jsonl"
_blocked_payload="$(jq -nc --arg s "${SESSION_ID}" --arg t "${TRANSCRIPT}" '{session_id:$s, transcript_path:$t}')"
_blocked_card="$(printf '%s' "${_blocked_payload}" | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-time-summary.sh" 2>/dev/null || true)"
assert_eq "blocked: user-facing card suppressed" "" "${_blocked_card}"
assert_eq "blocked: token delta captured" "22" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
assert_eq "blocked: token-bearing attempt reaches cross-session rollup" "22" \
  "$(timing_xs_aggregate 0 | jq -r '.tokens_main_out')"
assert_eq "blocked: prompt not falsely finalized" "0" \
  "$(timing_aggregate "${LOG}" | jq -r '.prompt_count')"

# A PreTool block uses the same generic gate-event vocabulary but did not block
# the current Stop. A later successful stop-guard attempt advances the causal
# attempt sequence; stop-time must finalize even if both events share a second.
printf '\n--- recent PreTool block does not suppress successful Stop ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":13,"output_tokens":17,"cache_read_input_tokens":19,"cache_creation_input_tokens":23}}}
EOF
_pretool_now="$(date +%s)"
printf '{"kind":"prompt_start","ts":%s,"prompt_seq":1}\n' "$((_pretool_now - 12))" > "${LOG}"
jq -nc --argjson ts "${_pretool_now}" '{
  prompt_seq:"1",
  stop_guard_attempt_seq:"2",
  last_stop_block_attempt_seq:"1",
  last_stop_block_ts:($ts|tostring)
}' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
printf '{"_v":1,"ts":%s,"gate":"model-routing","event":"block","details":{}}\n' "${_pretool_now}" \
  > "${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
_pretool_payload="$(jq -nc --arg s "${SESSION_ID}" --arg t "${TRANSCRIPT}" '{session_id:$s, transcript_path:$t}')"
_pretool_card="$(printf '%s' "${_pretool_payload}" | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-time-summary.sh" 2>/dev/null || true)"
assert_eq "pretool block: successful Stop is finalized" "1" \
  "$(timing_aggregate "${LOG}" | jq -r '.prompt_count')"
assert_eq "pretool block: completed Stop still renders its time card" "1" \
  "$(printf '%s' "${_pretool_card}" | jq -r '.systemMessage // ""' 2>/dev/null | grep -c 'tokens   in ' || echo 0)"

# The display's 5-second noise floor must not be an economics-data floor.
printf '\n--- token-bearing short session rollup ---\n'
new_session
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":5,"cache_creation_input_tokens":6}}}
EOF
_short_now="$(date +%s)"
printf '{"kind":"prompt_start","ts":%s,"prompt_seq":1}\n' "$((_short_now - 1))" > "${LOG}"
printf '{"prompt_seq":"1"}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
rm -f "${HOME}/.claude/quality-pack/timing.jsonl"
_short_payload="$(jq -nc --arg s "${SESSION_ID}" --arg t "${TRANSCRIPT}" '{session_id:$s, transcript_path:$t}')"
_short_card="$(printf '%s' "${_short_payload}" | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-time-summary.sh" 2>/dev/null || true)"
assert_eq "short: card remains below noise floor" "" "${_short_card}"
assert_eq "short: summary retained despite walltime <5s" "4" \
  "$(timing_xs_aggregate 0 | jq -r '.tokens_main_out')"

# A transcript may append after capture has stat'ed its size but before the
# parser opens it. The bounded byte slice must stop at that snapshot; otherwise
# the raced row is charged now while the older byte cursor makes it charge a
# second time on the next Stop.
printf '\n--- parent transcript snapshot race ---\n'
eval "$(declare -f _timing_sum_token_slice \
  | sed '1s/^_timing_sum_token_slice /_timing_sum_token_slice_snapshot_real /')"
_parent_race_marker="${TEST_HOME}/parent-race-fired"
_timing_sum_token_slice() {
  local _race_file="$1"
  if [[ ! -e "${_parent_race_marker}" ]]; then
    : > "${_parent_race_marker}"
    printf '%s\n' \
      '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":100}}}' \
      >> "${_race_file}"
  fi
  _timing_sum_token_slice_snapshot_real "$@"
}
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
printf '%s\n' \
  '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":10}}}' \
  > "${TRANSCRIPT}"
_parent_snapshot_bytes="$(_timing_file_size "${TRANSCRIPT}")"
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "snapshot race: first capture stops at stat'ed parent EOF" "10" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
assert_eq "snapshot race: cursor stops before raced suffix" "${_parent_snapshot_bytes}" \
  "$(read_state token_transcript_cursors | jq -r --arg f "${TRANSCRIPT}" '.[$f].bytes')"
timing_capture_session_tokens "${TRANSCRIPT}" 2
assert_eq "snapshot race: raced suffix counted exactly once next Stop" "110" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"

# The new-sidechain batch has the same concurrency boundary. Its temp snapshot
# is capped by each manifest entry even if a live agent appends before jq runs.
printf '\n--- batched sidechain snapshot race ---\n'
eval "$(declare -f _timing_sum_new_agent_files \
  | sed '1s/^_timing_sum_new_agent_files /_timing_sum_new_agent_files_snapshot_real /')"
_batch_race_marker="${TEST_HOME}/batch-race-fired"
_timing_sum_new_agent_files() {
  local _spec="${1:-}" _race_file="${1%%$'\t'*}"
  if [[ -n "${_spec}" && ! -e "${_batch_race_marker}" ]]; then
    : > "${_batch_race_marker}"
    printf '%s\n' \
      '{"type":"assistant","isSidechain":true,"attributionAgent":"race-role","message":{"model":"race-model","usage":{"input_tokens":0,"output_tokens":100}}}' \
      >> "${_race_file}"
  fi
  _timing_sum_new_agent_files_snapshot_real "$@"
}
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
printf '%s\n' \
  '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":1}}}' \
  > "${TRANSCRIPT}"
_batch_race_dir="${TRANSCRIPT%.jsonl}/subagents"
mkdir -p "${_batch_race_dir}"
printf '%s\n' \
  '{"type":"assistant","isSidechain":true,"attributionAgent":"race-role","message":{"model":"race-model","usage":{"input_tokens":0,"output_tokens":10}}}' \
  > "${_batch_race_dir}/race.jsonl"
_batch_snapshot_bytes="$(_timing_file_size "${_batch_race_dir}/race.jsonl")"
timing_capture_session_tokens "${TRANSCRIPT}" 1
assert_eq "batch race: first capture stops at manifest EOF" "10" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_agent_out')"
assert_eq "batch race: sidechain cursor stops before raced suffix" "${_batch_snapshot_bytes}" \
  "$(read_state token_transcript_cursors | jq -r --arg f "${_batch_race_dir}/race.jsonl" '.[$f].bytes')"
timing_capture_session_tokens "${TRANSCRIPT}" 2
assert_eq "batch race: raced sidechain suffix counted exactly once" "110" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_agent_out')"

# A legacy row cursor must never migrate its byte offset into an unfinished
# JSON object. It may charge complete rows before the fragment, then stays in
# row mode until the fragment completes.
printf '\n--- legacy cursor with partial trailing row ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
printf '%s\n' \
  '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":1}}}' \
  '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":10}}}' \
  > "${TRANSCRIPT}"
printf '%s' \
  '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":100' \
  >> "${TRANSCRIPT}"
_legacy_identity="$(_timing_file_identity "${TRANSCRIPT}")"
_legacy_cursors="$(jq -nc --arg f "${TRANSCRIPT}" --arg ident "${_legacy_identity}" \
  '{($f):{identity:$ident,rows:1}}')"
write_state_batch \
  "token_tracking_initialized" "1" \
  "token_transcript_rows" "1" \
  "token_transcript_cursors" "${_legacy_cursors}" \
  "token_totals" "{}"
timing_capture_session_tokens "${TRANSCRIPT}" 2
assert_eq "partial migration: complete row before fragment is counted" "10" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
assert_eq "partial migration: byte cursor is not persisted mid-object" "true" \
  "$(read_state token_transcript_cursors | jq -r --arg f "${TRANSCRIPT}" '.[$f] | has("bytes") | not')"
printf '%s\n' '}}}' \
  '{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":1000}}}' \
  >> "${TRANSCRIPT}"
timing_capture_session_tokens "${TRANSCRIPT}" 3
assert_eq "partial migration: completed fragment and successor are retained" "1110" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_main_out')"
assert_eq "partial migration: complete EOF upgrades to byte cursor" \
  "$(_timing_file_size "${TRANSCRIPT}")" \
  "$(read_state token_transcript_cursors | jq -r --arg f "${TRANSCRIPT}" '.[$f].bytes')"

# A completed agent fan-out must not turn every later Stop into an O(history)
# filesystem walk. The first capture batches all 100 new sidechains; the exact
# manifest lets the unchanged second capture touch only the live parent file.
printf '\n--- many completed sidechains fast path ---\n'
new_session
rm -rf "${TRANSCRIPT%.jsonl}"
printf '%s\n' \
  '{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":1}}}' \
  > "${TRANSCRIPT}"
_many_agent_dir="${TRANSCRIPT%.jsonl}/subagents"
mkdir -p "${_many_agent_dir}"
_many_i=1
while (( _many_i <= 100 )); do
  printf '%s\n' \
    '{"type":"assistant","isSidechain":true,"attributionAgent":"batch-role","message":{"model":"batch-model","usage":{"input_tokens":1,"output_tokens":1}}}' \
    > "${_many_agent_dir}/agent-${_many_i}.jsonl"
  _many_i=$((_many_i + 1))
done
timing_capture_session_tokens "${TRANSCRIPT}" 1
_many_agg="$(timing_aggregate "${LOG}")"
assert_eq "many sidechains: batched first scan counts every agent" "100" \
  "$(jq -r '.tokens_agent_out' <<<"${_many_agg}")"
assert_eq "many sidechains: every per-file cursor is durable" "101" \
  "$(read_state token_transcript_cursors | jq -r 'length')"
assert_eq "many sidechains: manifest is persisted" "1" \
  "$([[ -n "$(read_state token_agent_transcript_manifest)" ]] && printf '1' || printf '0')"

_identity_probe="${TEST_HOME}/identity-probe.log"
_timing_file_identity() {
  local _probe_file="${1:-}" _probe_identity=""
  printf '%s\n' "${_probe_file}" >> "${_identity_probe}"
  _probe_identity="$(stat -f '%d:%i' "${_probe_file}" 2>/dev/null || true)"
  [[ -n "${_probe_identity}" ]] \
    || _probe_identity="$(stat -c '%d:%i' "${_probe_file}" 2>/dev/null || true)"
  [[ -n "${_probe_identity}" ]] || _probe_identity="path:${_probe_file}"
  printf '%s' "${_probe_identity}"
}
timing_capture_session_tokens "${TRANSCRIPT}" 2
assert_eq "many sidechains: unchanged recapture stats only the parent" "1" \
  "$(wc -l < "${_identity_probe}" | tr -d ' ')"
assert_eq "many sidechains: unchanged recapture cannot duplicate totals" "100" \
  "$(timing_aggregate "${LOG}" | jq -r '.tokens_agent_out')"

# token line empty when no token data
assert_eq "empty token line on no data" "" "$(timing_token_line '{}')"

printf '\n=== test-token-tracking.sh: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
