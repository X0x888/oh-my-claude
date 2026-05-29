#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
#
# tests/test-token-tracking.sh — v1.46-pre token-usage tracking.
#
# Covers the transcript-sourced token capture that rides the timing
# subsystem: timing_fmt_tokens (compact formatter), the incremental
# cursor-based capture (timing_capture_session_tokens), timing_aggregate's
# token_delta summation, and the timing_token_line renderer. The capture
# is the load-bearing piece — it must count every transcript usage row
# exactly once across Stops (cursor), split main vs sub-agent (isSidechain),
# survive a compaction rewrite (shrink guard), and fail open.

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

# token line empty when no token data
assert_eq "empty token line on no data" "" "$(timing_token_line '{}')"

printf '\n=== test-token-tracking.sh: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
