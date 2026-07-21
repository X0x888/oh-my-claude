#!/usr/bin/env bash
# Focused release-visible observability tests for Definition of Excellent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
TEST_HOME="$(mktemp -d -t omc-definition-observability-XXXXXX)"
trap 'rm -rf "${TEST_HOME}"' EXIT

export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
export OMC_LAZY_TIMING=1
mkdir -p "${STATE_ROOT}" "${TEST_HOME}/.claude/quality-pack"

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

printf 'Test 1: /ulw-status distinguishes active in-scope taste from pending candidates\n'
sid="definition-observability-status"
session_dir="${STATE_ROOT}/${sid}"
profile_id="qcp_observability"
profile_dir="${TEST_HOME}/.claude/omc-user/quality-constitutions/profiles/${profile_id}"
mkdir -p "${session_dir}" "${profile_dir}"
cat >"${session_dir}/session_state.json" <<'JSON'
{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding",
 "session_start_ts":"9999999999","quality_contract_required":"1",
 "quality_contract_status":"missing","quality_contract_tier":"adaptive",
 "quality_contract_reason":"test","quality_constitution_status":"current",
 "quality_constitution_generation":"3","quality_constitution_digest":"digest-test",
 "quality_constitution_blocking_ids":"qc_blocking_1,qc_blocking_2"}
JSON
cat >"${session_dir}/quality_constitution_snapshot.json" <<JSON
{"profile_exists":true,"profile_id":"${profile_id}",
 "blocking_claims":[{"id":"qc_blocking_1"},{"id":"qc_blocking_2"}],
 "advisory_claims":[{"id":"qc_advisory_1"}],
 "tentative_claims":[{"id":"qc_inferred_active_1"}]}
JSON
cat >"${profile_dir}/candidates.json" <<'JSON'
{"schema_version":1,"items":[
  {"id":"qk_pending_1","status":"pending"},
  {"id":"qk_pending_2","status":"pending"},
  {"id":"qk_activated_1","status":"activated"}]}
JSON
status_out="$(STATE_ROOT="${STATE_ROOT}" SESSION_ID="${sid}" \
  bash "${HOOK_DIR}/show-status.sh" 2>&1 || true)"
assert_contains "status separates active and pending candidate counts" \
  "Taste entries:       active-in-scope=4 · pending-candidates=2 · current compiled scope" \
  "${status_out}"
assert_contains "status retains blocking taste IDs" \
  "Blocking taste IDs:  qc_blocking_1,qc_blocking_2" "${status_out}"

mv "${profile_dir}/candidates.json" "${profile_dir}/candidates.real.json"
ln -s "${profile_dir}/candidates.real.json" "${profile_dir}/candidates.json"
status_symlink_out="$(STATE_ROOT="${STATE_ROOT}" SESSION_ID="${sid}" \
  bash "${HOOK_DIR}/show-status.sh" 2>&1 || true)"
assert_contains "untrusted candidate source remains unavailable, not zero" \
  "pending-candidates=unavailable" "${status_symlink_out}"
assert_not_contains "untrusted candidate source cannot claim zero candidates" \
  "pending-candidates=0" "${status_symlink_out}"

printf 'Test 2: frontier reducer preserves objective-cycle continuity and rejects false relations\n'
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${HOOK_DIR}/common.sh"
history_file="${TEST_HOME}/frontier-history.jsonl"
frontier_row() {
  local contract_id="$1" cycle="$2" status="$3" materiality="$4"
  local dominates="$5" reviewed_at="$6" contract_revision="${7:-1}"
  jq -cnS \
    --arg contract_id "${contract_id}" \
    --argjson cycle "${cycle}" \
    --argjson contract_revision "${contract_revision}" \
    --arg status "${status}" \
    --arg materiality "${materiality}" \
    --argjson dominates "${dominates}" \
    --argjson reviewed_at "${reviewed_at}" '
      {_v:1,contract_id:$contract_id,contract_revision:$contract_revision,
       review_cycle_id:$cycle,edit_revision:1,plan_revision:$contract_revision,
       status:$status,materiality:$materiality,dominates_current:$dominates,
       criterion_ids:["Q-001"],evidence_ids:["qe-proof-001"],
       evidence:["vr-proof-00000001"],title:"Frontier result",
       why:"Receipt-backed frontier result.",
       recommended_move:"Apply or disprove the move.",
       experiment:"Run the bounded comparison again.",
       alternatives_searched:["Alternative alpha","Alternative beta"],
       limits:["Bounded evidence only"],reviewed_at:$reviewed_at,
       reviewer:"excellence-reviewer",native_agent_id:"native-observer",
       lifecycle_dispatch_id:"dispatch-observability-0001"}'
}
{
  frontier_row qc-observe-0001 1 clear none false 1
  frontier_row qc-observe-0001 1 open medium true 2
  frontier_row qc-observe-0001 1 open high true 3
  frontier_row qc-observe-0001 1 clear none false 4
  # Exact-key row with a contradictory open relation: invalid, and must not
  # seed a later remediation.
  frontier_row qc-invalid-0001 2 open none false 5
  # An additive re-contract changes contract identity/revision without
  # changing the objective review cycle. Its clear review resolves the open
  # episode instead of stranding the superseded contract as unresolved.
  frontier_row qc-observe-0002 2 open medium true 6
  frontier_row qc-observe-0003 2 clear none false 7 2
  # A genuinely different objective cycle remains independently unresolved.
  frontier_row qc-observe-0004 3 open medium true 8
  # A malformed same-cycle tail must not change the recorder's transition
  # status when the shared parser rejects it.
  printf '%s\n' '{"review_cycle_id":3,"status":"clear"}'
  # Every persisted revision/timestamp field shares the exact-integer ceiling.
  # Oversized or exponent-shaped JSON numbers remain invalid observations and
  # cannot become grouping keys or chronology authority in the reducer.
  frontier_row qc-overflow-0001 4 clear none false 9 \
    | jq -c '.contract_revision=1000000000000000'
  frontier_row qc-overflow-0002 4 clear none false 10 \
    | jq -c '.review_cycle_id=1e100'
  frontier_row qc-overflow-0003 4 clear none false 11 \
    | jq -c '.edit_revision=1000000000000000'
  frontier_row qc-overflow-0004 4 clear none false 12 \
    | jq -c '.plan_revision=1000000000000000'
  frontier_row qc-overflow-0005 4 clear none false 13 \
    | jq -c '.reviewed_at=1e100'
} >"${history_file}"
history_summary="$(quality_frontier_history_summary "${history_file}")"
assert_eq "seven authoritative reviews counted" "7" \
  "$(jq -r '.accepted_reviews' <<<"${history_summary}")"
assert_eq "repeated open row stays one discovery episode" "3" \
  "$(jq -r '.material_discoveries' <<<"${history_summary}")"
assert_eq "cross-contract clear in one objective cycle counts remediation" "2" \
  "$(jq -r '.remediations' <<<"${history_summary}")"
assert_eq "superseded contract is not left unresolved" "1" \
  "$(jq -r '.unresolved_frontiers' <<<"${history_summary}")"
assert_eq "contradictory, malformed, and oversized rows are invalid" "7" \
  "$(jq -r '.invalid_rows' <<<"${history_summary}")"
assert_eq "malformed same-cycle tail cannot seed recorder transition state" "open" \
  "$(quality_frontier_history_last_status_for_cycle "${history_file}" 3)"
overflow_cycle_rc=0
quality_frontier_history_last_status_for_cycle \
  "${history_file}" 1000000000000000 >/dev/null 2>&1 \
  || overflow_cycle_rc=$?
assert_eq "frontier lookup rejects an oversized cycle selector" "1" \
  "${overflow_cycle_rc}"

printf 'Test 3: /ulw-report exposes history-backed rates and actual event taxonomy\n'
unset OMC_LAZY_TIMING
qp="${TEST_HOME}/.claude/quality-pack"
now="$(date +%s)"
jq -cn \
  --argjson now "${now}" \
  --argjson frontiers "${history_summary}" '
    {session_id:"definition-report",start_ts:$now,end_ts:$now,
     domain:"coding",intent:"execution",edit_count:1,verified:true,
     reviewed:true,guard_blocks:0,dim_blocks:0,exhausted:false,
     dispatches:1,outcome:"shipped",skip_count:0,serendipity_count:0,
     quality_frontiers:$frontiers}' \
  >"${qp}/session_summary.jsonl"
cat >"${qp}/gate_events.jsonl" <<EOF
{"ts":${now},"gate":"definition-of-excellent","event":"armed","details":{}}
{"ts":${now},"gate":"definition-of-excellent/contract","event":"frozen","details":{}}
{"ts":${now},"gate":"definition-of-excellent/frontier","event":"material-frontier-discovered","details":{}}
{"ts":${now},"gate":"definition-of-excellent/frontier","event":"material-frontier-remediated","details":{}}
{"ts":${now},"gate":"definition-of-excellent/stop","event":"block","details":{}}
EOF
report_out="$(bash "${HOOK_DIR}/show-report.sh" all 2>&1)"
assert_contains "report renders Definition quality-loop section" \
  "## Definition of Excellent quality loop" "${report_out}"
assert_contains "report renders discovery count and denominator" \
  "| Material-frontier discovery rate | 3/7 (42%) |" "${report_out}"
assert_contains "report renders remediation count and denominator" \
  "| Material-frontier remediation rate | 2/3 (66%) |" "${report_out}"
assert_contains "report retains unresolved frontier count" \
  "| Material frontiers unresolved at session snapshot | 1 |" "${report_out}"
assert_contains "report discloses excluded malformed relation" \
  "7 malformed/unrecognized frontier-history row(s) were excluded" "${report_out}"
assert_contains "report renders root arming taxonomy" \
  '| `definition-of-excellent` | `armed` | 1 |' "${report_out}"
assert_contains "report renders frontier discovery taxonomy" \
  '| `definition-of-excellent/frontier` | `material-frontier-discovered` | 1 |' \
  "${report_out}"
assert_contains "report renders Stop block taxonomy" \
  '| `definition-of-excellent/stop` | `block` | 1 |' "${report_out}"

printf 'Test 4: zero denominators and unavailable history are never fabricated as rates\n'
cat >"${qp}/session_summary.jsonl" <<EOF
{"session_id":"no-history","start_ts":${now},"end_ts":${now},"outcome":"shipped","quality_frontiers":null}
EOF
: >"${qp}/gate_events.jsonl"
unavailable_report="$(bash "${HOOK_DIR}/show-report.sh" all 2>&1)"
assert_contains "unavailable history is named" \
  "No Definition gate events or available frontier-history summaries" \
  "${unavailable_report}"
assert_not_contains "unavailable history does not manufacture a 0% rate" \
  "Material-frontier discovery rate | 0/" "${unavailable_report}"

printf '\nResult: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
