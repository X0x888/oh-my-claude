#!/usr/bin/env bash
# End-to-end contract test for the Definition of Excellent lifecycle.
#
# This deliberately drives the production hooks rather than restating the
# quality-contract library's unit predicates. It proves the cross-hook causal
# chain: router arming -> pre-mutation refusal -> native planner publication ->
# edit/verification -> native excellence evidence/frontier -> Stop/status ->
# post-edit staleness -> scope-expansion re-contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

TEST_HOME="$(mktemp -d -t definition-excellent-e2e-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
TEST_PROJECT="${TEST_HOME}/project"
ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"

mkdir -p \
  "${TEST_HOME}/.claude/quality-pack/state" \
  "${TEST_HOME}/.claude/quality-pack" \
  "${TEST_STATE_ROOT}" \
  "${TEST_PROJECT}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" \
  "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" \
  "${TEST_HOME}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" \
  "${TEST_HOME}/.claude/quality-pack/memory"
touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
touch "${TEST_PROJECT}/coherence-map.txt" "${TEST_PROJECT}/other-map.txt"

export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"
export OMC_AGENT_FIRST_GATE=off
export OMC_DEFINITION_OF_EXCELLENT=adaptive
export OMC_QUALITY_CONSTITUTION=off
export OMC_EXEMPLIFYING_SCOPE_GATE=on
export OMC_GATE_LEVEL=basic

pass=0
fail=0

cleanup() {
  cd "${ORIG_PWD}" 2>/dev/null || true
  export HOME="${ORIG_HOME}"
  if [[ "${OMC_KEEP_TEST_TMP:-0}" == "1" ]]; then
    printf 'Preserved fixture: %s\n' "${TEST_HOME}" >&2
    return
  fi
  rm -rf "${TEST_HOME}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing=%q\n    actual(first 500)=%q\n' \
      "${label}" "${needle}" "${haystack:0:500}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected=%q\n    actual(first 500)=%q\n' \
      "${label}" "${needle}" "${haystack:0:500}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_present() {
  local label="$1" path="$2"
  if [[ -f "${path}" && ! -L "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected regular file=%s\n' \
      "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected absent=%s\n' \
      "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

state_dir() {
  printf '%s/%s' "${TEST_STATE_ROOT}" "$1"
}

state_file() {
  printf '%s/session_state.json' "$(state_dir "$1")"
}

read_state_key() {
  local sid="$1" key="$2" file
  file="$(state_file "${sid}")"
  [[ -f "${file}" ]] || { printf ''; return; }
  jq -r --arg key "${key}" '.[$key] // empty' "${file}" 2>/dev/null || true
}

jsonl_count() {
  local file="$1"
  if [[ -s "${file}" ]]; then
    jq -s 'length' "${file}" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

artifact_fingerprint() {
  local path="$1"
  if [[ -L "${path}" ]]; then
    printf 'symlink:%s' "$(readlink "${path}")"
  elif [[ -f "${path}" ]]; then
    printf 'file:%s' "$(shasum -a 256 "${path}" | awk '{print $1}')"
  elif [[ -e "${path}" ]]; then
    printf 'other'
  else
    printf 'absent'
  fi
}

run_hook() {
  local script="$1" payload="$2"
  shift 2
  (
    cd "${TEST_PROJECT}" || exit 1
    env "$@" bash "${script}" <<<"${payload}" 2>/dev/null
  )
}

run_router() {
  local sid="$1" prompt="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg prompt "${prompt}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,prompt:$prompt,cwd:$cwd}')"
  run_hook "${ROUTER}" "${payload}"
}

run_stop() {
  local sid="$1" message="${2:-Done.}" payload
  payload="$(jq -nc --arg sid "${sid}" --arg message "${message}" \
    '{session_id:$sid,stop_hook_active:false,last_assistant_message:$message}')"
  run_hook "${HOOK_DIR}/stop-guard.sh" "${payload}"
}

run_pretool_write() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg path "${TEST_PROJECT}/experience.txt" --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"Write",tool_use_id:$id,cwd:$cwd,
      tool_input:{file_path:$path,content:"new experience"}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_opaque_bash() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"Bash",tool_use_id:$id,cwd:$cwd,
      tool_input:{command:"bash ./custom-release-driver.sh --apply"}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_mcp_write() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg path "${TEST_PROJECT}/mcp-output.txt" --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"mcp__filesystem__write_file",tool_use_id:$id,
      cwd:$cwd,tool_input:{path:$path,content:"mcp mutation"}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_mcp_read() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg path "${TEST_PROJECT}/mcp-output.txt" --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"mcp__filesystem__read_file",tool_use_id:$id,
      cwd:$cwd,tool_input:{path:$path}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_browser_mutation() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,
      tool_name:"mcp__plugin_playwright_playwright__browser_fill_form",
      tool_use_id:$id,cwd:$cwd,
      tool_input:{fields:[{name:"title",type:"textbox",value:"changed"}]}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_unknown_mcp_mutation() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"mcp__custom_store__update_record",
      tool_use_id:$id,cwd:$cwd,
      tool_input:{record_id:"R-1",values:{status:"changed"}}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_http_post() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"mcp__http__query",tool_use_id:$id,cwd:$cwd,
      tool_input:{method:"POST",url:"https://example.invalid/items",body:{status:"changed"}}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_ambiguous_sync_status() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"mcp__foo__sync_status",tool_use_id:$id,
      cwd:$cwd,tool_input:{}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_path_shim() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"Bash",tool_use_id:$id,cwd:$cwd,
      tool_input:{command:"PATH=./untrusted-bin:$PATH rg -n quality ."}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_substitution() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"Bash",tool_use_id:$id,cwd:$cwd,
      tool_input:{command:"printf %s $(./custom-release-driver.sh --apply)"}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_pretool_readonly_bash() {
  local sid="$1" tool_use_id="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,tool_name:"Bash",tool_use_id:$id,cwd:$cwd,
      tool_input:{command:"/usr/bin/grep -n quality README.md"}}')"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" "${payload}" \
    OMC_PRETOOL_INTENT_GUARD=false
}

run_mark_edit() {
  local sid="$1" tool_name="$2" path="$3" tool_use_id="$4" payload
  payload="$(jq -nc --arg sid "${sid}" --arg tool "${tool_name}" \
    --arg path "${path}" --arg id "${tool_use_id}" --arg cwd "${TEST_PROJECT}" '
      {session_id:$sid,tool_name:$tool,tool_use_id:$id,cwd:$cwd,
       hook_event_name:"PostToolUse",
       tool_input:(if ($tool | test("mcp__.*read_file$"))
         then {path:$path}
         elif ($tool | startswith("mcp__"))
         then {path:$path,content:"mcp mutation"}
         else {file_path:$path,content:"edit"} end)}')"
  run_hook "${HOOK_DIR}/mark-edit.sh" "${payload}" >/dev/null
}

dispatch_agent() {
  local sid="$1" agent="$2" description="$3" payload
  payload="$(jq -nc --arg sid "${sid}" --arg agent "${agent}" \
    --arg description "${description}" \
    '{session_id:$sid,tool_name:"Agent",
      tool_input:{subagent_type:$agent,description:$description,prompt:"Use the current objective and required structural contract."}}')"
  run_hook "${HOOK_DIR}/record-pending-agent.sh" "${payload}"
}

start_agent() {
  local sid="$1" agent="$2" native_id="$3" payload
  payload="$(jq -nc --arg sid "${sid}" --arg agent "${agent}" \
    --arg native_id "${native_id}" \
    '{session_id:$sid,agent_type:$agent,agent_id:$native_id}')"
  (
    cd "${TEST_PROJECT}" || exit 1
    bash "${HOOK_DIR}/record-pending-agent.sh" start \
      <<<"${payload}" 2>/dev/null
  ) >/dev/null
}

record_plan() {
  local sid="$1" native_id="$2" message="$3" payload
  payload="$(jq -nc --arg sid "${sid}" --arg native_id "${native_id}" \
    --arg message "${message}" \
    '{session_id:$sid,agent_type:"quality-planner",agent_id:$native_id,
      last_assistant_message:$message}')"
  run_hook "${HOOK_DIR}/record-plan.sh" "${payload}"
}

record_plan_exit_code() {
  local sid="$1" native_id="$2" message="$3" payload rc
  payload="$(jq -nc --arg sid "${sid}" --arg native_id "${native_id}" \
    --arg message "${message}" \
    '{session_id:$sid,agent_type:"quality-planner",agent_id:$native_id,
      last_assistant_message:$message}')"
  set +e
  (
    cd "${TEST_PROJECT}" || exit 1
    bash "${HOOK_DIR}/record-plan.sh" <<<"${payload}" \
      >/dev/null 2>/dev/null
  )
  rc=$?
  set -e
  printf '%s' "${rc}"
}

assert_recontract_refusal_preserves_authority() {
  local label="$1" sid="$2" native_id="$3" message="$4"
  local dir contract_file evidence_file frontier_file frontier_history_file
  local contract_before evidence_before frontier_before history_before
  local revision_before starts_before rc
  dir="$(state_dir "${sid}")"
  contract_file="${dir}/quality_contract.json"
  evidence_file="${dir}/quality_evidence.jsonl"
  frontier_file="${dir}/quality_frontier.json"
  frontier_history_file="${dir}/quality_frontier_history.jsonl"
  contract_before="$(artifact_fingerprint "${contract_file}")"
  evidence_before="$(artifact_fingerprint "${evidence_file}")"
  frontier_before="$(artifact_fingerprint "${frontier_file}")"
  history_before="$(artifact_fingerprint "${frontier_history_file}")"
  revision_before="$(read_state_key "${sid}" plan_revision)"
  starts_before="$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"

  rc="$(record_plan_exit_code "${sid}" "${native_id}" "${message}")"
  if [[ "${rc}" -ne 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s should make additive publication exit non-zero\n' \
      "${label}" >&2
    fail=$((fail + 1))
  fi
  assert_eq "${label}: contract is byte-stable" "${contract_before}" \
    "$(artifact_fingerprint "${contract_file}")"
  assert_eq "${label}: evidence is byte-stable" "${evidence_before}" \
    "$(artifact_fingerprint "${evidence_file}")"
  assert_eq "${label}: frontier is byte-stable" "${frontier_before}" \
    "$(artifact_fingerprint "${frontier_file}")"
  assert_eq "${label}: frontier history shape/bytes are stable" \
    "${history_before}" "$(artifact_fingerprint "${frontier_history_file}")"
  assert_eq "${label}: plan generation does not advance" "${revision_before}" \
    "$(read_state_key "${sid}" plan_revision)"
  assert_eq "${label}: exact planner call remains recoverable" "${starts_before}" \
    "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
}

record_review() {
  local sid="$1" native_id="$2" message="$3" payload
  payload="$(jq -nc --arg sid "${sid}" --arg native_id "${native_id}" \
    --arg message "${message}" \
    '{session_id:$sid,agent_type:"excellence-reviewer",agent_id:$native_id,
      last_assistant_message:$message}')"
  (
    cd "${TEST_PROJECT}" || exit 1
    bash "${HOOK_DIR}/record-reviewer.sh" excellence \
      <<<"${payload}" 2>/dev/null
  )
}

record_review_result() {
  local sid="$1" native_id="$2" message="$3" payload rc output
  payload="$(jq -nc --arg sid "${sid}" --arg native_id "${native_id}" \
    --arg message "${message}" \
    '{session_id:$sid,agent_type:"excellence-reviewer",agent_id:$native_id,
      last_assistant_message:$message}')"
  set +e
  output="$(
    cd "${TEST_PROJECT}" || exit 1
    bash "${HOOK_DIR}/record-reviewer.sh" excellence \
      <<<"${payload}" 2>/dev/null
  )"
  rc=$?
  set -e
  jq -nc --argjson rc "${rc}" --arg output "${output}" \
    '{rc:$rc,output:$output}'
}

record_summary() {
  local sid="$1" agent="$2" native_id="$3" message="$4" payload
  payload="$(jq -nc --arg sid "${sid}" --arg agent "${agent}" \
    --arg native_id "${native_id}" --arg message "${message}" \
    '{session_id:$sid,agent_type:$agent,agent_id:$native_id,
      stop_hook_active:false,last_assistant_message:$message}')"
  run_hook "${HOOK_DIR}/record-subagent-summary.sh" "${payload}"
}

run_verification() {
  local sid="$1" tool_use_id="$2" command="$3" result="$4"
  local timeout="${5:-}" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" --arg command "${command}" \
    --arg result "${result}" --arg timeout "${timeout}" \
    '{session_id:$sid,tool_name:"Bash",tool_use_id:$id,cwd:$cwd,
      tool_input:({command:$command}
        + (if $timeout == "" then {} else {timeout:$timeout} end)),
      tool_response:$result}')"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${payload}" >/dev/null
  run_hook "${HOOK_DIR}/record-verification.sh" "${payload}" >/dev/null
}

run_bash_verification_failure() {
  local sid="$1" tool_use_id="$2" command="$3" error="$4"
  local start_payload failure_payload
  start_payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" --arg command "${command}" '
      {session_id:$sid,tool_name:"Bash",tool_use_id:$id,cwd:$cwd,
       tool_input:{command:$command}}')"
  failure_payload="$(jq -c --arg error "${error}" \
    '. + {hook_event_name:"PostToolUseFailure",error:$error}' \
    <<<"${start_payload}")"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" \
    "${start_payload}" >/dev/null
  run_hook "${HOOK_DIR}/record-verification.sh" \
    "${failure_payload}" >/dev/null
}

run_grep_verification() {
  local sid="$1" tool_use_id="$2" path="$3" pattern="$4" result="$5" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" --arg path "${path}" \
    --arg pattern "${pattern}" --arg result "${result}" '
      {session_id:$sid,tool_name:"Grep",tool_use_id:$id,cwd:$cwd,
       tool_input:{path:$path,pattern:$pattern},tool_response:$result}')"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${payload}" >/dev/null
  run_hook "${HOOK_DIR}/record-verification.sh" "${payload}" >/dev/null
}

run_grep_verification_failure() {
  local sid="$1" tool_use_id="$2" path="$3" pattern="$4" error="$5"
  local start_payload failure_payload
  start_payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" --arg path "${path}" \
    --arg pattern "${pattern}" '
      {session_id:$sid,tool_name:"Grep",tool_use_id:$id,cwd:$cwd,
       tool_input:{path:$path,pattern:$pattern}}')"
  failure_payload="$(jq -c --arg error "${error}" \
    '. + {hook_event_name:"PostToolUseFailure",error:$error}' \
    <<<"${start_payload}")"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" \
    "${start_payload}" >/dev/null
  run_hook "${HOOK_DIR}/record-verification.sh" \
    "${failure_payload}" >/dev/null
}

run_mcp_verification() {
  local sid="$1" tool_use_id="$2" url="$3" selector="$4" result="$5" payload
  payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" --arg url "${url}" \
    --arg selector "${selector}" --arg result "${result}" '
      {session_id:$sid,
       tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
       tool_use_id:$id,cwd:$cwd,
       tool_input:{url:$url,selector:$selector},tool_response:$result}')"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${payload}" >/dev/null
  run_hook "${HOOK_DIR}/record-verification.sh" "${payload}" >/dev/null
}

run_mcp_verification_failure() {
  local sid="$1" tool_use_id="$2" url="$3" selector="$4" error="$5"
  local start_payload failure_payload
  start_payload="$(jq -nc --arg sid "${sid}" --arg id "${tool_use_id}" \
    --arg cwd "${TEST_PROJECT}" --arg url "${url}" \
    --arg selector "${selector}" '
      {session_id:$sid,
       tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
       tool_use_id:$id,cwd:$cwd,
       tool_input:{url:$url,selector:$selector}}')"
  failure_payload="$(jq -c --arg error "${error}" \
    '. + {hook_event_name:"PostToolUseFailure",error:$error}' \
    <<<"${start_payload}")"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${start_payload}" >/dev/null
  # These are separate matching platform hooks in production. Running the
  # edit observer first exercises the stricter order; causal revision checks
  # make the opposite parallel order safe as well.
  run_hook "${HOOK_DIR}/mark-edit.sh" "${failure_payload}" >/dev/null
  run_hook "${HOOK_DIR}/record-verification.sh" "${failure_payload}" >/dev/null
}

receipt_match_rc() {
  local sid="$1" receipt="$2" criterion="$3" rc
  set +e
  SESSION_ID="${sid}" bash -c '
    # shellcheck disable=SC1090
    source "$1/common.sh"
    _omc_load_quality_contract
    quality_contract_receipt_matches_criterion "$2" "$3"
  ' _ "${HOOK_DIR}" "${receipt}" "${criterion}" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

contract_v1() {
  jq -nc '
    {
      north_star:"Ship a command-line experience whose every choice communicates confidence and intent.",
      audience:"Developers adopting the command-line workflow for consequential daily work.",
      stakes:"A generic or incomplete result would undermine trust in the quality harness.",
      ambition_boundary:"Prefer a coherent product-level leap over decorative novelty or ungrounded scope.",
      axes:{
        deliberate:"Every behavior and word has a visible reason grounded in the user workflow.",
        distinctive:"The experience has a recognizable point of view beyond conventional CLI defaults.",
        coherent:"Interaction, language, errors, and documentation reinforce one consistent mental model.",
        visionary:"The result demonstrates a materially better future workflow, not merely parity.",
        complete:"All promised paths, edge cases, verification, and handoff details are finished."
      },
      standards:[{
        kind:"user",
        reference:"explicit whole-new-level mandate",
        rationale:"The user explicitly requires a visionary and perfectionist bar."
      }],
      anti_goals:[
        "Do not substitute decorative novelty for measurable workflow improvement."
      ],
      criteria:[
        {
          id:"Q-001",class:"must",axis:"deliberate",
          claim:"Every primary command path exposes intentional defaults and actionable recovery.",
          rationale:"Intentional behavior prevents hidden steering and avoidable ambiguity.",
          surfaces:["CLI primary flow"],
          evidence_policy:{allowed_kinds:["test","comparison"],minimum:1,requires_empirical:true,requires_independent_review:true},
          proof_method:"Compare every primary path against the prior workflow and inspect its recovery output.",
          proof_spec:{tool_names:["Bash"],receipt_kinds:["test"],command_contains:["--criterion Q-001"],artifact_contains:[]},
          failure_signal:"Any primary path has an unexplained default or a dead-end error.",
          tradeoff_boundary:"Extra ceremony is rejected unless it measurably improves clarity."
        },
        {
          id:"Q-002",class:"must",axis:"distinctive",
          claim:"The CLI presents a recognizable quality-first interaction signature.",
          rationale:"A memorable point of view distinguishes the tool from generic wrappers.",
          surfaces:["CLI language and interaction"],
          evidence_policy:{allowed_kinds:["test","comparison"],minimum:1,requires_empirical:true,requires_independent_review:true},
          proof_method:"Compare representative transcripts with conventional CLI patterns and identify concrete differentiators.",
          proof_spec:{tool_names:["Bash"],receipt_kinds:["test"],command_contains:["--criterion Q-002"],artifact_contains:[]},
          failure_signal:"Independent review cannot name a concrete differentiating behavior.",
          tradeoff_boundary:"Distinctiveness must never reduce comprehension or accessibility."
        },
        {
          id:"Q-003",class:"must",axis:"coherent",
          claim:"Commands, errors, status, and documentation express one consistent mental model.",
          rationale:"Cross-surface coherence makes the experience learnable and trustworthy.",
          surfaces:["commands","errors","status","documentation"],
          evidence_policy:{allowed_kinds:["inspection","comparison"],minimum:1,requires_empirical:true,requires_independent_review:true},
          proof_method:"Trace representative tasks across command, error, status, and documentation surfaces.",
          proof_spec:{tool_names:["Grep"],receipt_kinds:["inspection"],command_contains:["coherence-contract"],artifact_contains:["coherence-map.txt"]},
          failure_signal:"The same concept is named or behaves inconsistently across surfaces.",
          tradeoff_boundary:"Local cleverness yields to system-wide consistency."
        },
        {
          id:"Q-004",class:"must",axis:"visionary",
          claim:"At least one demonstrated workflow materially outperforms the current baseline.",
          rationale:"The requested leap requires evidence of a better future, not polished parity.",
          surfaces:["end-to-end workflow"],
          evidence_policy:{allowed_kinds:["test","comparison"],minimum:1,requires_empirical:true,requires_independent_review:true},
          proof_method:"Run a blind before-and-after workflow comparison using the same consequential task.",
          proof_spec:{tool_names:["Bash"],receipt_kinds:["comparison"],command_contains:["--criterion Q-004"],artifact_contains:[]},
          failure_signal:"The new path does not materially dominate the baseline on clarity or steering.",
          tradeoff_boundary:"Vision must remain feasible, testable, and connected to real user value."
        },
        {
          id:"Q-005",class:"must",axis:"complete",
          claim:"All promised flows and failure paths are implemented, verified, and documented.",
          rationale:"A perfectionist bar fails when edge cases or handoff details remain implicit.",
          surfaces:["happy paths","failure paths","tests","handoff"],
          evidence_policy:{allowed_kinds:["test","comparison"],minimum:1,requires_empirical:true,requires_independent_review:true},
          proof_method:"Enumerate the promise map and compare every item with implementation and verification receipts.",
          proof_spec:{tool_names:["Bash"],receipt_kinds:["test"],command_contains:["--criterion Q-005"],artifact_contains:[]},
          failure_signal:"Any promised path lacks implementation, current proof, or explicit disposition.",
          tradeoff_boundary:"Scope may be declined only with a concrete user-value rationale."
        }
      ]
    }'
}

contract_v2() {
  local base="$1"
  jq -c '
    .criteria += [{
        id:"Q-006",class:"must",axis:"complete",
        claim:"The added migration assistant covers discovery, preview, apply, rollback, and recovery.",
        rationale:"The scope addition is complete only when its consequential lifecycle is explicit.",
        surfaces:["migration discovery","preview","apply","rollback","recovery"],
        evidence_policy:{allowed_kinds:["test","comparison"],minimum:1,requires_empirical:true,requires_independent_review:true},
        proof_method:"Exercise the migration lifecycle end to end and compare every state with the promise map.",
        proof_spec:{tool_names:["Bash"],receipt_kinds:["test"],command_contains:["--criterion Q-006"],artifact_contains:[]},
        failure_signal:"Any migration state lacks behavior, rollback, recovery, or a current test receipt.",
        tradeoff_boundary:"Migration convenience must not weaken reversibility or explainability."
      }]' <<<"${base}"
}

plan_message() {
  local contract="$1"
  printf '1. Freeze the five-axis bar before mutation.\n2. Verify and independently review every criterion.\nQUALITY_CONTRACT_JSON: %s\nVERDICT: PLAN_READY' \
    "${contract}"
}

review_payload() {
  local contract="$1" receipts="$2"
  jq -nc --argjson contract "${contract}" --argjson receipts "${receipts}" '
    {
      criteria:[$contract.criteria[]
        | .id as $criterion_id
        | {
            id:$criterion_id,status:"met",
            evidence_kind:(if $criterion_id == "Q-003" then "inspection"
              elif $criterion_id == "Q-004" then "comparison" else "test" end),
            basis:($criterion_id + " passed its own proof command against the current settled artifact and verification generation."),
            refs:[$receipts[$criterion_id]]
          }],
      alternatives_searched:[
        "Compared a conventional command-first flow against the quality-contract flow.",
        "Compared decorative polish against a structurally simpler end-to-end workflow."
      ],
      limits:["The fixture proves gate causality, not a production user-study outcome."],
      frontier:{
        material:false,bar_quality:"strong",title:"No material dominating frontier",
        why:"Blind comparison found no evidenced move that materially dominates the current candidate.",
        recommended_move:"Preserve the current bar and monitor real-world outcome receipts.",
        criterion_ids:[],evidence:([$receipts[]] | unique),
        experiment:"Repeat the same blind comparison on the next materially different workflow."
      }
    }'
}

review_message() {
  local review="$1"
  printf 'Blind-first review completed against the settled artifact.\nQUALITY_REVIEW_JSON: %s\nVERDICT: CLEAN' \
    "${review}"
}

printf '=== Definition of Excellent end-to-end ===\n'

printf 'Test 0a: rolling legacy continuation waits for a fresh objective boundary\n'
legacy_sid="doe-rolling-legacy"
SESSION_ID="${legacy_sid}" bash -c '
  source "$1/common.sh"
  ensure_session_dir
  write_state_batch \
    "workflow_mode" "ultrawork" \
    "ulw_enforcement_active" "1" \
    "ulw_enforcement_generation" "4" \
    "current_objective" "Finish the migration already in progress" \
    "task_intent" "execution" \
    "review_cycle_broad_scope" "1" \
    "first_mutation_ts" "1700000000" \
    "edit_revision" "3"
' _ "${HOOK_DIR}"
legacy_continue_out="$(run_router "${legacy_sid}" 'continue')"
assert_eq "legacy continuation does not retroactively arm tracking" "" \
  "$(read_state_key "${legacy_sid}" quality_contract_tracking_version)"
assert_eq "legacy continuation does not manufacture a required contract" "" \
  "$(read_state_key "${legacy_sid}" quality_contract_required)"
assert_not_contains "legacy continuation receives no Definition directive" \
  "DEFINITION OF EXCELLENT REQUIRED" "${legacy_continue_out}"
assert_eq "legacy continuation records an auditable compatibility boundary" "1" \
  "$(jq -s '[.[] | select(.gate == "definition-of-excellent"
      and .event == "legacy-continuation")] | length' \
    "$(state_dir "${legacy_sid}")/gate_events.jsonl")"
run_router "${legacy_sid}" \
  'ulw build a fresh visionary migration workflow with complete rollback proof' \
  >/dev/null
assert_eq "fresh objective activates Definition tracking after legacy continuation" "1" \
  "$(read_state_key "${legacy_sid}" quality_contract_tracking_version)"
assert_eq "fresh explicit objective arms the Definition" "1" \
  "$(read_state_key "${legacy_sid}" quality_contract_required)"

printf 'Test 0: non-execution interludes preserve an armed Definition without blocking Stop\n'
interlude_sid="doe-interlude"
run_router "${interlude_sid}" \
  'ulw write an excellent, visionary one-paragraph product biography' >/dev/null
interlude_cycle="$(read_state_key "${interlude_sid}" review_cycle_id)"
interlude_objective="$(read_state_key "${interlude_sid}" current_objective)"
interlude_quality_before="$(jq -cS '
  with_entries(select(.key | startswith("quality_")))
' "$(state_file "${interlude_sid}")")"
interlude_status_out="$(run_router "${interlude_sid}" 'What is the current status?')"
interlude_quality_after="$(jq -cS '
  with_entries(select(.key | startswith("quality_")))
' "$(state_file "${interlude_sid}")")"
assert_eq "advisory interlude preserves every Definition state key" \
  "${interlude_quality_before}" "${interlude_quality_after}"
assert_eq "advisory interlude preserves review cycle" "${interlude_cycle}" \
  "$(read_state_key "${interlude_sid}" review_cycle_id)"
assert_eq "advisory interlude preserves objective" "${interlude_objective}" \
  "$(read_state_key "${interlude_sid}" current_objective)"
assert_not_contains "advisory interlude injects no execution Definition directive" \
  "DEFINITION OF EXCELLENT REQUIRED" "${interlude_status_out}"
assert_eq "advisory Stop remains inert while Definition is preserved" "" \
  "$(run_stop "${interlude_sid}" 'Current status reported.')"
run_router "${interlude_sid}" 'continue' >/dev/null
assert_eq "continuation remains armed after advisory interlude" "1" \
  "$(read_state_key "${interlude_sid}" quality_contract_required)"
assert_eq "continuation remains on the original review cycle" "${interlude_cycle}" \
  "$(read_state_key "${interlude_sid}" review_cycle_id)"
assert_eq "continuation records inherited frozen bar" "continued-frozen-contract" \
  "$(read_state_key "${interlude_sid}" quality_contract_reason)"
interlude_stop="$(run_stop "${interlude_sid}")"
assert_eq "continued execution is Definition-blocked" "block" \
  "$(jq -r '.decision // empty' <<<"${interlude_stop}")"
assert_contains "continued execution names missing Definition" \
  "Definition-of-Excellent certification is incomplete" "${interlude_stop}"
assert_eq "recovery planner dispatch admitted on continued objective" "" \
  "$(dispatch_agent "${interlude_sid}" quality-planner 'Recover the missing frozen Definition')"
start_agent "${interlude_sid}" quality-planner native-plan-interlude-recovery
interlude_start="$(jq -c 'select(.agent_type == "quality-planner")' \
  "$(state_dir "${interlude_sid}")/agent_dispatch_starts.jsonl")"
assert_eq "recovery planner binds the advanced contract prompt revision" \
  "$(read_state_key "${interlude_sid}" quality_contract_prompt_revision)" \
  "$(jq -r '.objective_prompt_revision' <<<"${interlude_start}")"
interlude_plan="$(plan_message "$(contract_v1)")"
record_plan "${interlude_sid}" native-plan-interlude-recovery \
  "${interlude_plan}" >/dev/null
record_summary "${interlude_sid}" quality-planner \
  native-plan-interlude-recovery "${interlude_plan}" >/dev/null
assert_file_present "continued-objective recovery publishes a contract" \
  "$(state_dir "${interlude_sid}")/quality_contract.json"
assert_eq "continued-objective recovery contract validates current" "0" \
  "$(SESSION_ID="${interlude_sid}" bash -c '
      source "$1/common.sh"
      _omc_load_quality_contract
      quality_contract_validate_current >/dev/null 2>&1
    ' _ "${HOOK_DIR}"; printf '%s' "$?")"

# Non-execution is a behavioral invariant. A read-only advisory/checkpoint
# above remains Stop-inert, but if a nominally advisory turn actually mutates,
# the edit hook binds that mutation to the exact prompt revision and Stop must
# run the Definition gate against the changed generation.
run_router "${interlude_sid}" \
  'Pause implementation and only summarize the current contract.' >/dev/null
assert_eq "explicit pause-plus-summary is a checkpoint, not a fresh objective" \
  "checkpoint" "$(read_state_key "${interlude_sid}" task_intent)"
assert_eq "valid armed contract admits a nominal-checkpoint mutation only through Definition preflight" \
  "" "$(run_pretool_write "${interlude_sid}" advisory-contract-write)"
run_mark_edit "${interlude_sid}" Write \
  "${TEST_PROJECT}/advisory-contract-mutation.txt" advisory-contract-write
assert_eq "observed advisory mutation is bound to its exact prompt revision" \
  "$(read_state_key "${interlude_sid}" prompt_revision)" \
  "$(read_state_key "${interlude_sid}" last_edit_prompt_revision)"
mutated_interlude_stop="$(run_stop "${interlude_sid}" \
  'Nominal checkpoint turn changed an artifact.')"
assert_eq "mutated checkpoint turn is promoted into Definition Stop enforcement" \
  "block" "$(jq -r '.decision // empty' <<<"${mutated_interlude_stop}")"
assert_contains "mutated checkpoint turn cannot release uncertified bytes" \
  "Definition-of-Excellent certification is incomplete" \
  "${mutated_interlude_stop}"

sid="doe-primary"
opening_prompt='ulw bring this CLI to a whole new level; make it visionary, deliberate, distinctive, coherent, and complete—for example, reshape status and recovery as needed.'

printf 'Test 1: explicit visionary prompt arms the five-axis contract and competing scope gate\n'
router_out="$(run_router "${sid}" "${opening_prompt}")"
primary_state="$(state_file "${sid}")"
primary_dir="$(state_dir "${sid}")"
assert_eq "router classifies execution" "execution" \
  "$(read_state_key "${sid}" task_intent)"
assert_eq "router arms Definition" "1" \
  "$(read_state_key "${sid}" quality_contract_required)"
assert_eq "router records explicit mandate" "explicit-excellence-mandate" \
  "$(read_state_key "${sid}" quality_contract_reason)"
assert_eq "example prompt arms exemplifying scope" "1" \
  "$(read_state_key "${sid}" exemplifying_scope_required)"
assert_contains "directive names visionary axis" \
  "deliberate, distinctive, coherent, visionary, and complete" "${router_out}"
assert_contains "directive requires structural contract" \
  "QUALITY_CONTRACT_JSON" "${router_out}"

printf 'Test 2: Definition Stop gate precedes no-edit and competing gates\n'
stop_out="$(run_stop "${sid}")"
assert_eq "no-edit Stop is blocked" "block" \
  "$(jq -r '.decision // empty' <<<"${stop_out}")"
assert_contains "Definition wins Stop precedence" \
  "Definition-of-Excellent certification is incomplete" "${stop_out}"
assert_not_contains "exemplifying gate does not preempt Definition" \
  "Exemplifying-scope gate" "${stop_out}"
assert_eq "one Definition block emits one Stop event" "1" \
  "$(jq -s '[.[] | select(.gate == "definition-of-excellent/stop" and .event == "block")] | length' \
    "${primary_dir}/gate_events.jsonl")"
assert_eq "Stop owns one Definition validator callsite" "1" \
  "$(rg -c 'quality_contract_gate_status_json 2>/dev/null' \
    "${HOOK_DIR}/stop-guard.sh")"

printf 'Test 3: pre-contract mutation is denied even with legacy guard disabled\n'
write_denial="$(run_pretool_write "${sid}" "write-before-contract")"
opaque_denial="$(run_pretool_opaque_bash "${sid}" "opaque-before-contract")"
mcp_denial="$(run_pretool_mcp_write "${sid}" "mcp-before-contract")"
substitution_denial="$(run_pretool_substitution "${sid}" "substitution-before-contract")"
path_shim_denial="$(run_pretool_path_shim "${sid}" "path-shim-before-contract")"
browser_denial="$(run_pretool_browser_mutation "${sid}" "browser-before-contract")"
unknown_mcp_denial="$(run_pretool_unknown_mcp_mutation "${sid}" "unknown-mcp-before-contract")"
http_post_denial="$(run_pretool_http_post "${sid}" "http-post-before-contract")"
ambiguous_sync_denial="$(run_pretool_ambiguous_sync_status "${sid}" "sync-status-before-contract")"
assert_eq "Write denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${write_denial}")"
assert_contains "Write denial names Definition" "Definition of Excellent" "${write_denial}"
assert_eq "opaque Bash denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${opaque_denial}")"
assert_eq "MCP write denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${mcp_denial}")"
assert_eq "opaque command substitution denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${substitution_denial}")"
assert_eq "PATH-shimmed read command denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${path_shim_denial}")"
assert_eq "browser mutator denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${browser_denial}")"
assert_eq "unknown update-shaped MCP denied" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${unknown_mcp_denial}")"
assert_eq "POST operation overrides observational MCP name" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${http_post_denial}")"
assert_eq "ambiguous sync-status MCP fails closed" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"${ambiguous_sync_denial}")"
assert_eq "provably read-only Bash remains allowed" "" \
  "$(run_pretool_readonly_bash "${sid}" readonly-before-contract)"
assert_eq "provably read-only MCP remains allowed" "" \
  "$(run_pretool_mcp_read "${sid}" mcp-read-before-contract)"
assert_file_absent "denied attempts publish no contract" \
  "${primary_dir}/quality_contract.json"

printf 'Test 4: malformed tracked planner return has no authoritative side effects\n'
assert_eq "planner dispatch admitted" "" \
  "$(dispatch_agent "${sid}" quality-planner 'Freeze the Definition of Excellent')"
start_agent "${sid}" quality-planner native-plan-primary
bad_plan_message=$'Narration is not a contract.\nQUALITY_CONTRACT_JSON: {}\nVERDICT: PLAN_READY'
record_plan "${sid}" native-plan-primary "${bad_plan_message}" >/dev/null
bad_plan_feedback="$(record_summary "${sid}" quality-planner \
  native-plan-primary "${bad_plan_message}")"
assert_file_absent "malformed planner publishes no plan" \
  "${primary_dir}/current_plan.md"
assert_file_absent "malformed planner publishes no contract" \
  "${primary_dir}/quality_contract.json"
assert_eq "malformed planner retains native causal start" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_contains "universal hook asks same call to correct contract" \
  "QUALITY_CONTRACT_JSON" "${bad_plan_feedback}"

printf 'Test 5: corrected same native planner call freezes the authoritative contract\n'
contract1="$(contract_v1)"
plan1="$(plan_message "${contract1}")"
record_plan "${sid}" native-plan-primary "${plan1}" >/dev/null
record_summary "${sid}" quality-planner native-plan-primary "${plan1}" >/dev/null
contract_file="${primary_dir}/quality_contract.json"
assert_file_present "planner publishes contract" "${contract_file}"
assert_file_present "planner publishes plan" "${primary_dir}/current_plan.md"
assert_eq "contract is planner/native bound" "native-plan-primary" \
  "$(jq -r '.planner.native_agent_id' "${contract_file}")"
assert_eq "contract is objective-cycle bound" \
  "$(read_state_key "${sid}" review_cycle_id)" \
  "$(jq -r '.review_cycle_id' "${contract_file}")"
assert_eq "contract is prompt-revision bound" \
  "$(read_state_key "${sid}" quality_contract_prompt_revision)" \
  "$(jq -r '.objective_prompt_revision' "${contract_file}")"
assert_eq "contract covers all five mandatory axes" "5" \
  "$(jq '[.definition.criteria[] | select(.class == "must") | .axis] | unique | length' "${contract_file}")"
assert_eq "contract includes visionary mandatory criterion" "1" \
  "$(jq '[.definition.criteria[] | select(.class == "must" and .axis == "visionary")] | length' "${contract_file}")"
assert_eq "first contract is frozen before mutation" "false" \
  "$(jq -r '.late' "${contract_file}")"
assert_eq "plan recorder consumes exact start" "0" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_eq "universal recorder clears pending row" "0" \
  "$(jsonl_count "${primary_dir}/pending_agents.jsonl")"

printf 'Test 5b: a valid contract survives a clean non-execution Stop and generation rollover\n'
contract_before_interlude="$(cat "${contract_file}")"
contract_generation="$(read_state_key "${sid}" quality_contract_enforcement_generation)"
live_generation_before="$(read_state_key "${sid}" ulw_enforcement_generation)"
assert_eq "contract mirror starts on its planner publication generation" \
  "${live_generation_before}" "${contract_generation}"
run_router "${sid}" 'Pause here and give me a checkpoint.' >/dev/null
assert_eq "checkpoint Stop remains inert with a valid preserved contract" "" \
  "$(run_stop "${sid}" 'Checkpoint reported.')"
assert_eq "checkpoint Stop closes only the per-turn interval" "0" \
  "$(read_state_key "${sid}" ulw_enforcement_active)"
run_router "${sid}" 'continue' >/dev/null
live_generation_after="$(read_state_key "${sid}" ulw_enforcement_generation)"
assert_eq "contract bytes survive the interlude" "${contract_before_interlude}" \
  "$(cat "${contract_file}")"
assert_eq "contract authority generation remains stable" "${contract_generation}" \
  "$(read_state_key "${sid}" quality_contract_enforcement_generation)"
if [[ "${live_generation_after}" =~ ^[0-9]+$ \
    && "${live_generation_before}" =~ ^[0-9]+$ \
    && "${live_generation_after}" -gt "${live_generation_before}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: bare continuation should open a newer per-turn generation\n    before=%s after=%s\n' \
    "${live_generation_before}" "${live_generation_after}" >&2
  fail=$((fail + 1))
fi

printf 'Test 6: current contract releases mutation and MCP completion advances the edit clock\n'
assert_eq "Write allowed after contract" "" \
  "$(run_pretool_write "${sid}" "write-after-contract")"
assert_eq "opaque Bash allowed after contract" "" \
  "$(run_pretool_opaque_bash "${sid}" "opaque-after-contract")"
assert_eq "MCP write allowed after contract" "" \
  "$(run_pretool_mcp_write "${sid}" "mcp-after-contract")"
assert_file_present "first post-interlude mutation freezes contract floor" \
  "${primary_dir}/quality_contract_floor.json"
assert_eq "frozen floor retains exact pre-interlude contract identity" \
  "${contract_before_interlude}" \
  "$(cat "${primary_dir}/quality_contract_floor.json")"
run_mark_edit "${sid}" "mcp__filesystem__write_file" \
  "${TEST_PROJECT}/mcp-output.txt" "mcp-after-contract"
assert_eq "MCP mutation advances edit revision" "1" \
  "$(read_state_key "${sid}" edit_revision)"
assert_eq "MCP mutation advances code revision" "1" \
  "$(read_state_key "${sid}" last_code_edit_revision)"

printf 'Test 7: hook-recorded, criterion-specific verification receipts ground review\n'
run_verification "${sid}" verify-fake-comparison \
  "pytest --version; printf '10 tests passed\\n' # comparison --criterion Q-004" \
  'pytest 9.9.9; 10 tests passed'
fake_receipt_eligible=0
if [[ -s "${primary_dir}/verification_receipts.jsonl" ]]; then
  fake_receipt_eligible="$(jq -sc \
    --arg id verify-fake-comparison \
    --arg contract_id "$(jq -r '.contract_id' "${contract_file}")" '
      [.[] | select(.tool_use_id == $id
        and .quality_contract_id == $contract_id
        and .outcome == "passed"
        and .confidence >= 40
        and .evidence_kind == "comparison")] | length
    ' "${primary_dir}/verification_receipts.jsonl")"
fi
assert_eq "synthetic --version/printf output is not Definition-eligible proof" \
  "0" "${fake_receipt_eligible}"

run_verification "${sid}" verify-q001 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-001' \
  'Q-001 deliberate behavior: 8 passed, 0 failed'
run_verification "${sid}" verify-q002 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-002' \
  'Q-002 distinctive transcript comparison: 6 passed, 0 failed'
run_grep_verification "${sid}" verify-wrong-target \
  "${TEST_PROJECT}/other-map.txt" 'coherence-contract baseline' \
  'coherence-contract found on the wrong artifact target'
run_grep_verification "${sid}" verify-q003 \
  "${TEST_PROJECT}/coherence-map.txt" 'coherence-contract baseline' \
  'coherence-contract found across commands, errors, status, and documentation'
run_verification "${sid}" verify-q004 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-004 --comparison' \
  'Q-004 blind before-and-after workflow comparison: 5 passed, 0 failed'
run_verification "${sid}" verify-q005 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-005' \
  'Q-005 promise-map completeness audit: 9 passed, 0 failed'
assert_eq "verification recorded passed" "passed" \
  "$(read_state_key "${sid}" last_verify_outcome)"
verify_confidence="$(read_state_key "${sid}" last_verify_confidence)"
if [[ "${verify_confidence}" =~ ^[0-9]+$ && "${verify_confidence}" -ge 40 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: verification confidence should be >=40 (actual=%q)\n' \
    "${verify_confidence}" >&2
  fail=$((fail + 1))
fi
receipt_file="${primary_dir}/verification_receipts.jsonl"
assert_file_present "verification receipt ledger exists" "${receipt_file}"
verification_receipts="$(jq -sc '
  reduce .[] as $row ({};
    if $row.tool_use_id == "verify-q001" then ."Q-001" = $row.receipt_id
    elif $row.tool_use_id == "verify-q002" then ."Q-002" = $row.receipt_id
    elif $row.tool_use_id == "verify-q003" then ."Q-003" = $row.receipt_id
    elif $row.tool_use_id == "verify-q004" then ."Q-004" = $row.receipt_id
    elif $row.tool_use_id == "verify-q005" then ."Q-005" = $row.receipt_id
    else . end)' "${receipt_file}")"
assert_eq "five criterion receipt bindings exist" "5" \
  "$(jq 'length' <<<"${verification_receipts}")"
assert_eq "all criterion receipts are authoritative IDs" "true" \
  "$(jq 'all(.[]; type == "string" and length >= 8)' <<<"${verification_receipts}")"
assert_eq "criterion receipt IDs are distinct" "5" \
  "$(jq '[.[]] | unique | length' <<<"${verification_receipts}")"

# A later verification must not silently sanitize malformed authority by
# dropping the bad row during bounded retention. It may consume its start
# snapshot, but the authoritative ledger remains byte-for-byte unchanged and
# no new receipt is advertised until the corruption is repaired explicitly.
verification_fault_anomalies_before="$(grep -c '\[anomaly\]' \
  "${TEST_STATE_ROOT}/hooks.log" 2>/dev/null || true)"
verification_fault_anomalies_before="${verification_fault_anomalies_before:-0}"
receipt_corruption_snapshot="${primary_dir}/.verification-receipts-corruption-snapshot"
cp "${receipt_file}" "${receipt_corruption_snapshot}"
printf '%s\n' 'not-json-authority' >>"${receipt_file}"
corrupt_ledger_digest_before="$(shasum -a 256 "${receipt_file}" | awk '{print $1}')"
run_verification "${sid}" verify-malformed-ledger-refused \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-005 --malformed-ledger' \
  'malformed ledger trigger: 1 passed, 0 failed'
assert_eq "malformed receipt authority is not silently rewritten" \
  "${corrupt_ledger_digest_before}" \
  "$(shasum -a 256 "${receipt_file}" | awk '{print $1}')"
assert_eq "malformed authority cannot advertise a new receipt" "0" \
  "$(grep -c 'verify-malformed-ledger-refused' "${receipt_file}" || true)"
mv -f "${receipt_corruption_snapshot}" "${receipt_file}"

cp "${receipt_file}" "${receipt_corruption_snapshot}"
head -1 "${receipt_file}" >>"${receipt_file}"
duplicate_ledger_digest_before="$(shasum -a 256 "${receipt_file}" | awk '{print $1}')"
run_verification "${sid}" verify-duplicate-ledger-refused \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-005 --duplicate-ledger' \
  'duplicate ledger trigger: 1 passed, 0 failed'
assert_eq "duplicate receipt IDs are not silently collapsed" \
  "${duplicate_ledger_digest_before}" \
  "$(shasum -a 256 "${receipt_file}" | awk '{print $1}')"
assert_eq "duplicate authority cannot advertise a new receipt" "0" \
  "$(grep -c 'verify-duplicate-ledger-refused' "${receipt_file}" || true)"
mv -f "${receipt_corruption_snapshot}" "${receipt_file}"
verification_fault_anomalies_after="$(grep -c '\[anomaly\]' \
  "${TEST_STATE_ROOT}/hooks.log" 2>/dev/null || true)"
verification_fault_anomalies_after="${verification_fault_anomalies_after:-0}"
injected_verification_anomalies=$((
  verification_fault_anomalies_after - verification_fault_anomalies_before
))
assert_eq "intentional corrupt-ledger refusals are anomaly-visible" "2" \
  "${injected_verification_anomalies}"

# Receipt retention is allowed to dedupe and cap, but it must preserve causal
# append order even when several outcomes share one epoch second and their
# opaque IDs sort in the opposite order. Negative-proof precedence consumes
# this ledger order; timestamp/ID sorting would let a later failure move before
# the approval it invalidates.
receipt_order_snapshot="${primary_dir}/.verification-receipts-order-snapshot"
cp "${receipt_file}" "${receipt_order_snapshot}"
order_base="$(jq -sc '[.[] | select(.tool_use_id == "verify-q003")][0]' \
  "${receipt_file}")"
jq -c '
  .receipt_id="vr-zzzz-order-pass" | .tool_use_id="tool-order-pass"
  | .input_digest="input-order-pass" | .command=(.command + " --order-pass")
  | .command_digest="command-order-pass" | .outcome="passed"
  | .result="1 passed" | .result_digest="result-order-pass"
  | .proof_identity="vp-order-pass-12345678" | .ts=777
' <<<"${order_base}" >>"${receipt_file}"
jq -c '
  .receipt_id="vr-aaaa-order-fail" | .tool_use_id="tool-order-fail"
  | .input_digest="input-order-fail" | .command=(.command + " --order-fail")
  | .command_digest="command-order-fail" | .outcome="failed"
  | .result="1 failed" | .result_digest="result-order-fail"
  | .proof_identity="vp-order-fail-12345678" | .ts=777
' <<<"${order_base}" >>"${receipt_file}"
jq -c '
  .receipt_id="vr-mmmm-order-pass" | .tool_use_id="tool-order-later-pass"
  | .input_digest="input-order-later" | .command=(.command + " --order-later")
  | .command_digest="command-order-later" | .outcome="passed"
  | .result="1 passed" | .result_digest="result-order-later"
  | .proof_identity="vp-order-later-12345678" | .ts=777
' <<<"${order_base}" >>"${receipt_file}"
run_verification "${sid}" verify-order-retention-trigger \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-004 --order-retention' \
  'order retention trigger: 1 passed, 0 failed'
assert_eq "same-second retention preserves causal append order" \
  "vr-zzzz-order-pass,vr-aaaa-order-fail,vr-mmmm-order-pass" \
  "$(jq -sr '[.[] | select(.receipt_id | test("^vr-(zzzz|aaaa|mmmm)-order")) | .receipt_id] | join(",")' \
    "${receipt_file}")"
mv -f "${receipt_order_snapshot}" "${receipt_file}"
wrong_target_receipt="$(jq -sc \
  '[.[] | select(.tool_use_id == "verify-wrong-target")][0]' \
  "${receipt_file}")"
coherence_receipt="$(jq -sc \
  '[.[] | select(.tool_use_id == "verify-q003")][0]' \
  "${receipt_file}")"
q003_criterion="$(jq -c \
  '.definition.criteria[] | select(.id == "Q-003")' "${contract_file}")"
assert_contains "Grep receipt binds the observed wrong target" "other-map.txt" \
  "$(jq -r '.artifact_target' <<<"${wrong_target_receipt}")"
assert_not_contains "wrong-target observation cannot claim coherence target" \
  "coherence-map.txt" \
  "$(jq -r '.artifact_target' <<<"${wrong_target_receipt}")"
if [[ "$(receipt_match_rc "${sid}" "${wrong_target_receipt}" \
    "${q003_criterion}")" -ne 0 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: wrong-target Grep receipt matched coherence proof spec\n' >&2
  fail=$((fail + 1))
fi
assert_contains "legitimate Grep receipt binds coherence target" \
  "coherence-map.txt" \
  "$(jq -r '.artifact_target' <<<"${coherence_receipt}")"
assert_eq "coherence-target Grep receipt matches coherence proof spec" "0" \
  "$(receipt_match_rc "${sid}" "${coherence_receipt}" "${q003_criterion}")"

# High-volume observations must not grow the authority ledger past the gate
# reader's bounds or evict one of the criterion receipts a paid reviewer still
# needs. Seed 520 valid but irrelevant source observations, then let one real
# PostTool completion run the production criterion-aware retention pass.
jq -cn --argjson base "${coherence_receipt}" '
  range(0;520) as $i
  | $base
  | .receipt_id = ("vr-noise-00000000-" + ($i|tostring))
  | .tool_use_id = ("tool-noise-" + ($i|tostring))
  | .tool_name = "Read"
  | .input_digest = ("input-noise-" + ($i|tostring))
  | .command = ("Read:/repo/noise-" + ($i|tostring))
  | .command_digest = ("command-noise-" + ($i|tostring))
  | .result_digest = ("result-noise-" + ($i|tostring))
  | .artifact_target = ("/repo/noise-" + ($i|tostring))
  | .artifact_digest = ("artifact-noise-" + ($i|tostring))
  | .proof_identity = ("vp-noise-00000000-" + ($i|tostring))
  | .method = "source_source"
  | .scope = "workspace_source"
  | .evidence_kind = "source"
  | .ts = (1000 + $i)
' >>"${receipt_file}"
run_verification "${sid}" verify-retention-trigger \
  'bash tests/test-definition-of-excellent-e2e.sh --retention-probe' \
  'retention probe: 1 passed, 0 failed'
assert_eq "criterion-aware receipt portfolio stays under 512 rows" "true" \
  "$(awk 'END { print (NR < 512 ? "true" : "false") }' "${receipt_file}")"
required_receipts="$(jq '[.[]]' <<<"${verification_receipts}")"
assert_eq "high-volume observations retain every criterion receipt" "5" \
  "$(jq -sc --argjson required "${required_receipts}" '
    [.[].receipt_id] as $have
    | [$required[] as $id | select(($have | index($id)) != null)] | length
  ' "${receipt_file}")"

printf 'Test 8: excellence dispatch is contract-bound and malformed review is inert\n'
assert_eq "excellence dispatch admitted" "" \
  "$(dispatch_agent "${sid}" excellence-reviewer 'Blind-first Definition frontier review')"
start_agent "${sid}" excellence-reviewer native-excellence-primary
excellence_start="$(jq -c 'select(.agent_type == "excellence-reviewer")' \
  "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_eq "review start binds contract id" \
  "$(jq -r '.contract_id' "${contract_file}")" \
  "$(jq -r '.quality_contract_id // empty' <<<"${excellence_start}")"
assert_eq "review start binds contract revision" \
  "$(jq -r '.contract_revision' "${contract_file}")" \
  "$(jq -r '.quality_contract_revision // empty' <<<"${excellence_start}")"
bad_review_message=$'Self-approval without structural evidence.\nVERDICT: CLEAN'
record_review "${sid}" native-excellence-primary "${bad_review_message}" >/dev/null
bad_review_feedback="$(record_summary "${sid}" excellence-reviewer \
  native-excellence-primary "${bad_review_message}")"
assert_file_absent "malformed review publishes no evidence" \
  "${primary_dir}/quality_evidence.jsonl"
assert_file_absent "malformed review publishes no frontier" \
  "${primary_dir}/quality_frontier.json"
assert_eq "malformed reviewer retains native causal start" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_contains "universal hook asks same reviewer to correct envelope" \
  "required reviewer contract" "${bad_review_feedback}"

# Existence alone is not proof. A single unrelated green test cannot be
# laundered across the deliberate/distinctive/coherent/visionary/complete bar.
first_receipt="$(jq -r '."Q-001"' <<<"${verification_receipts}")"
reused_receipts="$(jq --arg receipt "${first_receipt}" \
  'with_entries(.value = $receipt)' <<<"${verification_receipts}")"
reused_review="$(review_payload "${contract1}" "${reused_receipts}")"
reused_review_message="$(review_message "${reused_review}")"
reused_review_result="$(record_review_result "${sid}" \
  native-excellence-primary "${reused_review_message}")"
reused_review_rc="$(jq -r '.rc' <<<"${reused_review_result}")"
assert_eq "receipt laundering rejection is a handled hook outcome" "0" \
  "${reused_review_rc}"
assert_file_absent "one unrelated receipt cannot publish criterion evidence" \
  "${primary_dir}/quality_evidence.jsonl"
assert_file_absent "one unrelated receipt cannot clear the frontier" \
  "${primary_dir}/quality_frontier.json"
assert_eq "receipt laundering retains the exact reviewer for correction" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_contains "receipt laundering gets same-call correction feedback" \
  "receipt" \
  "$(jq -r '.output' <<<"${reused_review_result}")"

# A new tool_use_id or timeout is not a new normalized proof identity.
same_proof_command='bash tests/test-definition-of-excellent-e2e.sh --criterion Q-001'
run_verification "${sid}" verify-shared-proof-a "${same_proof_command}" \
  'shared proof identity: 10 passed, 0 failed in 1.01s' '30000'
run_verification "${sid}" verify-shared-proof-b \
  'bash   tests/test-definition-of-excellent-e2e.sh --criterion Q-001' \
  'shared proof identity: 10 passed, 0 failed in 1.37s' '90000'
shared_proof_receipts="$(jq -sc '
  [.[] | select(.tool_use_id == "verify-shared-proof-a"
      or .tool_use_id == "verify-shared-proof-b")]
  | sort_by(.tool_use_id)' "${receipt_file}")"
assert_eq "repeated proof run receives two receipt IDs" "2" \
  "$(jq '[.[].receipt_id] | unique | length' <<<"${shared_proof_receipts}")"
assert_eq "timeout-only metadata variance changes causal input digests" "2" \
  "$(jq '[.[].input_digest] | unique | length' <<<"${shared_proof_receipts}")"
assert_eq "repeated proof retains one underlying command identity" "1" \
  "$(jq '[.[].command_digest] | unique | length' <<<"${shared_proof_receipts}")"
assert_eq "timing-only output variance changes raw result digests" "2" \
  "$(jq '[.[].result_digest] | unique | length' <<<"${shared_proof_receipts}")"
assert_eq "repeated proof retains one harness proof identity" "1" \
  "$(jq '[.[].proof_identity] | unique | length' <<<"${shared_proof_receipts}")"

# Shell semantic equivalence is not decidable by a finite normalizer. The
# stronger gate invariant is that one receipt must match exactly one frozen
# proof_spec. A combined Q1+Q2 run is ambiguous under both ordinary and `./`
# path spelling, so distinct receipt/proof IDs still cannot manufacture 2/5.
ambiguous_command='bash tests/test-definition-of-excellent-e2e.sh --criterion Q-001 --criterion Q-002'
run_verification "${sid}" verify-ambiguous-proof-a "${ambiguous_command}" \
  'ambiguous combined proof: 10 passed, 0 failed'
run_verification "${sid}" verify-ambiguous-proof-b \
  'bash ./tests/test-definition-of-excellent-e2e.sh --criterion Q-001 --criterion Q-002' \
  'ambiguous alias proof: 10 passed, 0 failed'
ambiguous_receipts="$(jq -sc '
  [.[] | select(.tool_use_id == "verify-ambiguous-proof-a"
      or .tool_use_id == "verify-ambiguous-proof-b")]
  | sort_by(.tool_use_id)' "${receipt_file}")"
assert_eq "path aliases mint distinct command identities before criterion admission" "2" \
  "$(jq '[.[].proof_identity] | unique | length' <<<"${ambiguous_receipts}")"
ambiguous_receipt_map="$(jq \
  --arg q1 "$(jq -r '.[0].receipt_id' <<<"${ambiguous_receipts}")" \
  --arg q2 "$(jq -r '.[1].receipt_id' <<<"${ambiguous_receipts}")" \
  '."Q-001" = $q1 | ."Q-002" = $q2' <<<"${verification_receipts}")"
ambiguous_review="$(review_payload "${contract1}" "${ambiguous_receipt_map}")"
ambiguous_result="$(record_review_result "${sid}" \
  native-excellence-primary "$(review_message "${ambiguous_review}")")"
assert_eq "ambiguous alias laundering rejection is a handled hook outcome" "0" \
  "$(jq -r '.rc' <<<"${ambiguous_result}")"
assert_file_absent "multi-criterion aliases cannot publish partial evidence" \
  "${primary_dir}/quality_evidence.jsonl"
assert_file_absent "multi-criterion aliases cannot clear frontier" \
  "${primary_dir}/quality_frontier.json"
assert_eq "ambiguous alias rejection retains exact reviewer" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_contains "ambiguous alias rejection requests one unique receipt per criterion" \
  "exactly one" "$(jq -r '.output' <<<"${ambiguous_result}")"

# Reacquire narrow Q1/Q2 proof after the adversarial combined checks so the
# final accepted review is grounded in receipts that each match one criterion.
run_verification "${sid}" verify-q001-recovery \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-001' \
  'Q-001 recovery: 6 passed, 0 failed'
run_verification "${sid}" verify-q002-recovery \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-002' \
  'Q-002 recovery: 6 passed, 0 failed'
verification_receipts="$(jq \
  --arg q1 "$(jq -sr '[.[] | select(.tool_use_id == "verify-q001-recovery")][-1].receipt_id' "${receipt_file}")" \
  --arg q2 "$(jq -sr '[.[] | select(.tool_use_id == "verify-q002-recovery")][-1].receipt_id' "${receipt_file}")" \
  '."Q-001" = $q1 | ."Q-002" = $q2' <<<"${verification_receipts}")"

printf 'Test 9: corrected review publishes current criterion proof and clear frontier\n'
review1="$(review_payload "${contract1}" "${verification_receipts}")"
review1_message="$(review_message "${review1}")"
record_review "${sid}" native-excellence-primary "${review1_message}" >/dev/null
record_summary "${sid}" excellence-reviewer native-excellence-primary \
  "${review1_message}" >/dev/null
evidence_file="${primary_dir}/quality_evidence.jsonl"
frontier_file="${primary_dir}/quality_frontier.json"
assert_file_present "review publishes evidence" "${evidence_file}"
assert_file_present "review publishes frontier" "${frontier_file}"
assert_eq "one evidence row per mandatory criterion" "5" \
  "$(jsonl_count "${evidence_file}")"
assert_eq "each criterion cites its own verification receipt" "5" \
  "$(jq -s '[.[].reference] | unique | length' "${evidence_file}")"
assert_eq "evidence is current for edit revision" \
  "$(read_state_key "${sid}" edit_revision)" \
  "$(jq -s -r 'map(.edit_revision) | unique | if length == 1 then .[0] else "mixed" end' "${evidence_file}")"
assert_eq "frontier is clear" "clear" \
  "$(jq -r '.status' "${frontier_file}")"
assert_eq "frontier is independently native-bound" "native-excellence-primary" \
  "$(jq -r '.native_agent_id' "${frontier_file}")"

# Source the real library only for observing its integrated gate result. All
# producers above remain production hooks; this call avoids interpreting a
# later unrelated Stop gate as the Definition result.
export SESSION_ID="${sid}"
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${HOOK_DIR}/common.sh"
_omc_load_quality_contract
gate_after_review="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "Definition gate passes after current review" "pass" \
  "$(jq -r '.status // empty' <<<"${gate_after_review}")"
status_out="$(HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/show-status.sh" 2>/dev/null || true)"
assert_contains "status renders Definition section" \
  "--- Definition of Excellent ---" "${status_out}"
assert_contains "status renders pass" "Certification:       pass" "${status_out}"
assert_contains "status renders five-axis proof coverage" \
  "Axis coverage:       deliberate=1/1 · distinctive=1/1 · coherent=1/1 · visionary=1/1 · complete=1/1" \
  "${status_out}"
assert_contains "status names deterministic weakest tested axis after certification" \
  "Frontier / weakest:  clear / deliberate" "${status_out}"
assert_contains "status names no weak mandatory criterion after certification" \
  "Weakest criterion:   none (all mandatory criteria evidenced)" \
  "${status_out}"
assert_contains "status exposes active-versus-candidate taste distinction" \
  "Taste entries:       active-in-scope=" "${status_out}"
assert_contains "status exposes the immutable floor proof source" \
  "quality_contract_floor.json" "${status_out}"
assert_contains "status exposes the verification receipt proof source" \
  "verification_receipts.jsonl" "${status_out}"
assert_eq "accepted clear review emits frontier-clear taxonomy event" "1" \
  "$(jq -s '[.[] | select(.gate == "definition-of-excellent/frontier" and .event == "frontier-clear")] | length' \
    "${primary_dir}/gate_events.jsonl")"
stop_after_review="$(run_stop "${sid}")"
assert_not_contains "Stop no longer blocks on Definition" \
  "Definition-of-Excellent certification is incomplete" "${stop_after_review}"
assert_contains "older competing scope gate remains live" \
  "Exemplifying-scope gate" "${stop_after_review}"

read_revision_before="$(read_state_key "${sid}" edit_revision)"
assert_eq "read-only MCP remains allowed after certification" "" \
  "$(run_pretool_mcp_read "${sid}" mcp-read-after-review)"
run_mark_edit "${sid}" "mcp__filesystem__read_file" \
  "${TEST_PROJECT}/mcp-output.txt" mcp-read-after-review
assert_eq "read-only MCP completion does not advance edit clock" \
  "${read_revision_before}" "$(read_state_key "${sid}" edit_revision)"
gate_after_read="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "read-only MCP does not stale Definition proof" "pass" \
  "$(jq -r '.status // empty' <<<"${gate_after_read}")"

# Passing the frozen threshold is necessary but not sufficient. Exercise the
# production reviewer-to-frontier translation with a material, receipt-backed
# alternative that dominates the current candidate even though every criterion
# remains met. The Definition gate must preserve that finding as open work.
assert_eq "second excellence dispatch admitted for frontier challenge" "" \
  "$(dispatch_agent "${sid}" excellence-reviewer 'Challenge the settled candidate for a materially superior frontier')"
start_agent "${sid}" excellence-reviewer native-excellence-frontier
open_review="$(jq -c '
  .frontier.material = true
  | .frontier.bar_quality = "weak"
  | .frontier.title = "A materially clearer future workflow remains available"
  | .frontier.why = "The receipt-backed comparison exposes a simpler interaction model that dominates the current candidate."
  | .frontier.recommended_move = "Implement and compare the simplified workflow before closeout."
  | .frontier.criterion_ids = ["Q-003"]
  | .frontier.experiment = "Run a blind task-completion comparison between the settled and simplified workflows."
' <<<"$(review_payload "${contract1}" "${verification_receipts}")")"
open_review_message="$(printf 'Blind-first review found a material beyond-threshold alternative.\nQUALITY_REVIEW_JSON: %s\nVERDICT: FINDINGS (1)' "${open_review}")"
record_review "${sid}" native-excellence-frontier "${open_review_message}" >/dev/null
record_summary "${sid}" excellence-reviewer native-excellence-frontier \
  "${open_review_message}" >/dev/null
assert_eq "production reviewer publishes material frontier" "open" \
  "$(jq -r '.status' "${frontier_file}")"
assert_eq "material frontier emits discovery taxonomy event" "1" \
  "$(jq -s '[.[] | select(.gate == "definition-of-excellent/frontier" and .event == "material-frontier-discovered")] | length' \
    "${primary_dir}/gate_events.jsonl")"
assert_eq "material frontier keeps its passed threshold criterion" "passed" \
  "$(jq -r 'select(.criterion_id == "Q-003") | .result' "${evidence_file}")"
gate_after_frontier="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "material frontier blocks despite five passed threshold criteria" \
  "open_frontier" "$(jq -r '.status // empty' <<<"${gate_after_frontier}")"
open_status_out="$(HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/show-status.sh" 2>/dev/null || true)"
assert_contains "status names the frontier criterion ID and axis" \
  "Weakest criterion:   Q-003 · coherent · material frontier" \
  "${open_status_out}"
open_frontier_stop="$(run_stop "${sid}")"
assert_contains "open frontier precedes older competing Stop gates" \
  "Definition-of-Excellent certification is incomplete (open_frontier)" \
  "${open_frontier_stop}"
assert_not_contains "open frontier is not hidden by sibling-scope gate" \
  "Exemplifying-scope gate" "${open_frontier_stop}"

# A second reviewer cannot erase the open frontier by reinterpreting the
# exact same receipts. The failed publication must be transactional: current
# frontier/evidence/history remain byte-stable and the native reviewer call is
# retained for correction after a genuinely new counterexperiment.
assert_eq "counterevidence reviewer dispatch admitted" "" \
  "$(dispatch_agent "${sid}" excellence-reviewer 'Test the material frontier against new counterevidence')"
start_agent "${sid}" excellence-reviewer native-excellence-counterevidence
open_frontier_before_reuse="$(cat "${frontier_file}")"
open_evidence_before_reuse="$(cat "${evidence_file}")"
open_history_count_before_reuse="$(jsonl_count "${primary_dir}/quality_frontier_history.jsonl")"
reused_clear_review="$(review_payload "${contract1}" "${verification_receipts}")"
reused_clear_result="$(record_review_result "${sid}" \
  native-excellence-counterevidence "$(review_message "${reused_clear_review}")")"
assert_eq "same-proof clear rejection is a handled hook outcome" "0" \
  "$(jq -r '.rc' <<<"${reused_clear_result}")"
assert_contains "same-proof clear requests causally newer frontier proof" \
  "causally newer distinct proof" \
  "$(jq -r '.output' <<<"${reused_clear_result}")"
assert_eq "same-proof clear retains the open frontier byte-for-byte" \
  "${open_frontier_before_reuse}" "$(cat "${frontier_file}")"
assert_eq "same-proof clear retains accepted evidence byte-for-byte" \
  "${open_evidence_before_reuse}" "$(cat "${evidence_file}")"
assert_eq "same-proof clear appends no frontier history" \
  "${open_history_count_before_reuse}" \
  "$(jsonl_count "${primary_dir}/quality_frontier_history.jsonl")"
assert_eq "same-proof clear retains exact reviewer call for correction" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"

run_grep_verification "${sid}" verify-frontier-counter-q003 \
  "${TEST_PROJECT}/coherence-map.txt" 'coherence-contract frontier-counter' \
  'coherence-contract counter-observation disproved the proposed dominance'
counter_q003_receipt="$(jq -sr \
  '[.[] | select(.tool_use_id == "verify-frontier-counter-q003")][-1].receipt_id' \
  "${receipt_file}")"
counter_receipts="$(jq --arg receipt "${counter_q003_receipt}" \
  '."Q-003" = $receipt' <<<"${verification_receipts}")"
counter_review="$(review_payload "${contract1}" "${counter_receipts}")"
counter_review_message="$(review_message "${counter_review}")"
record_review "${sid}" native-excellence-counterevidence \
  "${counter_review_message}" >/dev/null
record_summary "${sid}" excellence-reviewer native-excellence-counterevidence \
  "${counter_review_message}" >/dev/null
assert_eq "same-artifact counterevidence clears material frontier" "clear" \
  "$(jq -r '.status' "${frontier_file}")"
assert_eq "frontier finding never poisons generic completeness verdict" "CLEAN" \
  "$(read_state_key "${sid}" dim_completeness_verdict)"
gate_after_counterevidence="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "same-revision counterevidence restores Definition certification" \
  "pass" "$(jq -r '.status // empty' <<<"${gate_after_counterevidence}")"
counterevidence_stop="$(run_stop "${sid}")"
assert_not_contains "counterevidence recovery is not trapped by stricter completeness" \
  "stricter-verdict-wins" "${counterevidence_stop}"
assert_contains "counterevidence recovery reaches the older sibling-scope gate" \
  "Exemplifying-scope gate" "${counterevidence_stop}"
assert_eq "clear-after-open emits remediation taxonomy event" "1" \
  "$(jq -s '[.[] | select(.gate == "definition-of-excellent/frontier" and .event == "material-frontier-remediated")] | length' \
    "${primary_dir}/gate_events.jsonl")"
frontier_history_summary="$(quality_frontier_history_summary \
  "${primary_dir}/quality_frontier_history.jsonl")"
assert_eq "history reducer counts one material discovery" "1" \
  "$(jq -r '.material_discoveries' <<<"${frontier_history_summary}")"
assert_eq "history reducer counts one remediation" "1" \
  "$(jq -r '.remediations' <<<"${frontier_history_summary}")"
assert_eq "history reducer leaves no unresolved frontier" "0" \
  "$(jq -r '.unresolved_frontiers' <<<"${frontier_history_summary}")"

# Re-open a material frontier immediately before the later additive scope
# revision. The ordered history row must be exact before publication, then the
# stale open evidence/frontier pair remains as redundant causal authority until
# a v2 clear review remediates it. Receipt compaction must preserve that five-row
# portfolio from the pair even if history disappears afterward.
assert_eq "pre-recontract frontier reviewer dispatch admitted" "" \
  "$(dispatch_agent "${sid}" excellence-reviewer \
    'Challenge the settled result before additive scope re-contracting')"
start_agent "${sid}" excellence-reviewer native-excellence-pre-recontract
pre_recontract_open_review="$(jq -c '
  .frontier.material = true
  | .frontier.bar_quality = "weak"
  | .frontier.title = "The migration expansion exposes a stronger coherent workflow"
  | .frontier.why = "The current receipt portfolio shows that migration can become one coherent reversible workflow rather than an adjacent command set."
  | .frontier.recommended_move = "Add and empirically compare the complete migration lifecycle under the frozen interaction model."
  | .frontier.criterion_ids = ["Q-003"]
  | .frontier.experiment = "Re-contract the additive lifecycle, prove every new generation criterion, and compare the resulting coherent workflow."
' <<<"$(review_payload "${contract1}" "${counter_receipts}")")"
pre_recontract_open_message="$(printf '%s\nQUALITY_REVIEW_JSON: %s\nVERDICT: FINDINGS (1)' \
  'Blind-first review found a material move coupled to the additive scope.' \
  "${pre_recontract_open_review}")"
record_review "${sid}" native-excellence-pre-recontract \
  "${pre_recontract_open_message}" >/dev/null
record_summary "${sid}" excellence-reviewer \
  native-excellence-pre-recontract "${pre_recontract_open_message}" >/dev/null
assert_eq "pre-recontract material frontier is authoritative" "open" \
  "$(jq -r '.status' "${frontier_file}")"
pre_recontract_frontier_receipts="$(jq -c '.evidence' "${frontier_file}")"
assert_eq "pre-recontract open frontier binds the complete five-axis receipt portfolio" \
  "5" "$(jq -r 'length' <<<"${pre_recontract_frontier_receipts}")"

run_bash_verification_failure "${sid}" verify-q002-negative-after-review \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-002 --negative-after-review' \
  'Q-002 distinctive assertion failed: generic transcript regression observed'
assert_eq "real PostToolUseFailure mints failed assertion proof" "failed" \
  "$(jq -sr '[.[] | select(.tool_use_id == "verify-q002-negative-after-review")][-1].outcome // empty' \
    "${receipt_file}")"
assert_eq "receipt retention preserves the pass cited by accepted review" "1" \
  "$(jq -sr --arg id "$(jq -r '."Q-002"' <<<"${verification_receipts}")" \
    '[.[] | select(.receipt_id == $id)] | length' "${receipt_file}")"
# Three later assertion passes cannot erase an assertion failure without a new
# reviewer. Three later successful observations likewise require reviewer
# interpretation before the older semantic Q-003 assessment remains current.
# An eight-receipt unrelated tail exercises both dedicated retention classes.
for retention_pass in 1 2 3; do
  run_verification "${sid}" "verify-q002-unreviewed-pass-${retention_pass}" \
    "bash tests/test-definition-of-excellent-e2e.sh --criterion Q-002 --unreviewed-pass-${retention_pass}" \
    "Q-002 unreviewed assertion ${retention_pass}: 6 passed, 0 failed"
  run_grep_verification "${sid}" "verify-q003-unreviewed-observation-${retention_pass}" \
    "${TEST_PROJECT}/coherence-map.txt" \
    "coherence-contract unreviewed-observation-${retention_pass}" \
    "unreviewed coherence observation ${retention_pass}: match found"
done
for retention_noise in 1 2 3 4 5 6 7 8; do
  run_verification "${sid}" "verify-q004-unrelated-${retention_noise}" \
    "bash tests/test-definition-of-excellent-e2e.sh --criterion Q-004 --comparison --noise-${retention_noise}" \
    "Q-004 unrelated visionary comparison ${retention_noise}: 6 passed, 0 failed"
done
assert_eq "post-accept assertion failure survives passes and unrelated tail" "1" \
  "$(jq -sr '[.[] | select(.tool_use_id == "verify-q002-negative-after-review")] | length' \
    "${receipt_file}")"
assert_eq "latest unreviewed observation survives unrelated receipt traffic" "1" \
  "$(jq -sr '[.[] | select(.tool_use_id == "verify-q003-unreviewed-observation-3")] | length' \
    "${receipt_file}")"
gate_after_negative="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "new assertion failure and observation both require review" \
  "stale_evidence" "$(jq -r '.status // empty' <<<"${gate_after_negative}")"
assert_eq "gate distinguishes assertion counterproof and unreviewed observation" \
  "Q-002,Q-003" \
  "$(jq -r '.stale_ids | join(",")' <<<"${gate_after_negative}")"

printf 'Test 10: any later edit makes proof stale before other Stop gates\n'
assert_eq "browser mutation is allowed after a current contract" "" \
  "$(run_pretool_browser_mutation "${sid}" browser-after-review)"
run_mark_edit "${sid}" \
  "mcp__plugin_playwright_playwright__browser_fill_form" \
  "browser://current-form" browser-after-review
assert_eq "post-review edit advances revision" "2" \
  "$(read_state_key "${sid}" edit_revision)"
stale_stop="$(run_stop "${sid}")"
assert_contains "post-edit Stop is Definition stale-evidence" \
  "Definition-of-Excellent certification is incomplete (stale_evidence)" \
  "${stale_stop}"
assert_not_contains "stale Definition still precedes scope gate" \
  "Exemplifying-scope gate" "${stale_stop}"

printf 'Test 11: scope-expanding continuation invalidates and re-contracts without lowering floor\n'
contract1_id="$(jq -r '.contract_id' "${contract_file}")"
contract1_frozen="$(jq -c '.definition' "${contract_file}")"
continuation_out="$(run_router "${sid}" \
  'continue and also add a complete interactive migration assistant with preview, rollback, and recovery')"
assert_eq "scope addition requires contract recheck" "1" \
  "$(read_state_key "${sid}" quality_contract_recheck_required)"
assert_eq "contract prompt revision follows continuation" \
  "$(read_state_key "${sid}" prompt_revision)" \
  "$(read_state_key "${sid}" quality_contract_prompt_revision)"
assert_contains "objective records scope addition" "Scope addition (authoritative):" \
  "$(read_state_key "${sid}" current_objective)"
scope_addition_objective_once="$(read_state_key "${sid}" current_objective)"
scope_addition_digest_once="$(read_state_key \
  "${sid}" quality_contract_scope_addition_digests)"
run_router "${sid}" \
  'continue and also add a complete interactive migration assistant with preview, rollback, and recovery' \
  >/dev/null
assert_eq "duplicate substantive continuation preserves objective byte-for-byte" \
  "${scope_addition_objective_once}" \
  "$(read_state_key "${sid}" current_objective)"
assert_eq "duplicate substantive continuation does not grow scope digest authority" \
  "${scope_addition_digest_once}" \
  "$(read_state_key "${sid}" quality_contract_scope_addition_digests)"
assert_eq "duplicate substantive continuation preserves the existing re-contract latch" "1" \
  "$(read_state_key "${sid}" quality_contract_recheck_required)"
assert_contains "continuation repeats Definition directive" \
  "DEFINITION OF EXCELLENT REQUIRED" "${continuation_out}"
assert_eq "mutation blocked until re-contract" "deny" \
  "$(run_pretool_write "${sid}" scope-addition-write \
    | jq -r '.hookSpecificOutput.permissionDecision // empty')"

expanded_objective_before_interlude="$(read_state_key "${sid}" current_objective)"
expanded_floor_before_interlude="$(cat "${primary_dir}/quality_contract_floor.json")"
run_router "${sid}" 'Pause the expanded scope and give me a checkpoint.' >/dev/null
assert_eq "scope-recheck checkpoint Stop stays non-execution-inert" "" \
  "$(run_stop "${sid}" 'Expanded-scope checkpoint reported.')"
run_router "${sid}" 'continue' >/dev/null
assert_eq "bare recovery preserves expanded objective byte-for-byte" \
  "${expanded_objective_before_interlude}" \
  "$(read_state_key "${sid}" current_objective)"
assert_eq "bare recovery preserves immutable contract floor byte-for-byte" \
  "${expanded_floor_before_interlude}" \
  "$(cat "${primary_dir}/quality_contract_floor.json")"
assert_eq "bare recovery keeps re-contract armed" "1" \
  "$(read_state_key "${sid}" quality_contract_recheck_required)"
assert_eq "bare recovery advances only the pending contract prompt binding" \
  "$(read_state_key "${sid}" prompt_revision)" \
  "$(read_state_key "${sid}" quality_contract_prompt_revision)"
assert_eq "mutation remains blocked after interlude until additive re-contract" "deny" \
  "$(run_pretool_write "${sid}" scope-addition-write-after-interlude \
    | jq -r '.hookSpecificOutput.permissionDecision // empty')"

assert_eq "replacement planner dispatch admitted" "" \
  "$(dispatch_agent "${sid}" quality-planner 'Re-contract the expanded migration scope without lowering the floor')"
start_agent "${sid}" quality-planner native-plan-expanded
contract2="$(contract_v2 "${contract1_frozen}")"
weakened_contract2="$(jq -c '
  .north_star = "Deliver an adequate command-line update with acceptable conventional behavior."
  | .axes.visionary = "Reach ordinary feature parity without requiring a materially better workflow."' \
  <<<"${contract2}")"
weakened_plan2="$(plan_message "${weakened_contract2}")"
record_plan "${sid}" native-plan-expanded "${weakened_plan2}" >/dev/null
weakened_feedback="$(record_summary "${sid}" quality-planner \
  native-plan-expanded "${weakened_plan2}")"
assert_eq "post-mutation planner cannot weaken north-star or visionary axis" \
  "${contract1_id}" "$(jq -r '.contract_id' "${contract_file}")"
assert_eq "weakened re-contract does not advance contract revision" "1" \
  "$(jq -r '.contract_revision' "${contract_file}")"
assert_file_present "weakened re-contract does not erase current evidence" \
  "${evidence_file}"
assert_file_present "weakened re-contract does not erase current frontier" \
  "${frontier_file}"
assert_eq "weakened re-contract retains exact planner start" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"
assert_contains "weakened planner receives same-call correction" \
  "frozen" "${weakened_feedback}"

plan2="$(plan_message "${contract2}")"
frontier_history_file="${primary_dir}/quality_frontier_history.jsonl"
authoritative_frontier_history="${primary_dir}/.authoritative-frontier-history"
cp "${frontier_history_file}" "${authoritative_frontier_history}"
fault_anomalies_before="$(grep -c '\[anomaly\]' \
  "${TEST_STATE_ROOT}/hooks.log" 2>/dev/null || true)"
fault_anomalies_before="${fault_anomalies_before:-0}"

# Additive publication is allowed to invalidate old certification, but it may
# not erase an unresolved finding. Exercise every state produced by a damaged
# third rename in reviewer publication: absent history, a valid row followed by
# malformed bytes, a nonregular target, and a stale-but-valid history whose last
# row predates the current open frontier. Each failure consumes planner state
# inside the transaction, then must restore all four authority artifacts and
# the exact causal planner call.
rm -f "${frontier_history_file}"
assert_recontract_refusal_preserves_authority \
  "missing open-frontier history" "${sid}" native-plan-expanded "${plan2}"
cp "${authoritative_frontier_history}" "${frontier_history_file}"

printf '%s\n' '{malformed-frontier-history' >>"${frontier_history_file}"
assert_recontract_refusal_preserves_authority \
  "malformed open-frontier history" "${sid}" native-plan-expanded "${plan2}"
cp "${authoritative_frontier_history}" "${frontier_history_file}"

external_frontier_history="${TEST_HOME}/outside-frontier-history.jsonl"
cp "${authoritative_frontier_history}" "${external_frontier_history}"
rm -f "${frontier_history_file}"
ln -s "${external_frontier_history}" "${frontier_history_file}"
assert_recontract_refusal_preserves_authority \
  "symlink open-frontier history" "${sid}" native-plan-expanded "${plan2}"
assert_eq "symlink refusal never rewrites its external target" \
  "$(artifact_fingerprint "${authoritative_frontier_history}")" \
  "$(artifact_fingerprint "${external_frontier_history}")"
rm -f "${frontier_history_file}"
cp "${authoritative_frontier_history}" "${frontier_history_file}"

# This is the recoverable SIGKILL window: evidence/frontier renames landed,
# while the history rename did not, so an older valid row remains last.
sed '$d' "${authoritative_frontier_history}" >"${frontier_history_file}"
assert_recontract_refusal_preserves_authority \
  "stale crash-window frontier history" "${sid}" \
  native-plan-expanded "${plan2}"
cp "${authoritative_frontier_history}" "${frontier_history_file}"

fault_anomalies_after="$(grep -c '\[anomaly\]' \
  "${TEST_STATE_ROOT}/hooks.log" 2>/dev/null || true)"
fault_anomalies_after="${fault_anomalies_after:-0}"
injected_plan_anomalies=$((fault_anomalies_after - fault_anomalies_before))
if [[ "${injected_plan_anomalies}" -ge 4 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: fail-closed plan faults should be anomaly-visible (delta=%s)\n' \
    "${injected_plan_anomalies}" >&2
  fail=$((fail + 1))
fi

record_plan "${sid}" native-plan-expanded "${plan2}" >/dev/null
record_summary "${sid}" quality-planner native-plan-expanded "${plan2}" >/dev/null
assert_eq "expanded contract increments revision" "2" \
  "$(jq -r '.contract_revision' "${contract_file}")"
assert_eq "expanded plan increments revision" "2" \
  "$(jq -r '.plan_revision' "${contract_file}")"
assert_eq "expanded contract changes identity" "0" \
  "$([[ "$(jq -r '.contract_id' "${contract_file}")" != "${contract1_id}" ]] && printf 0 || printf 1)"
assert_eq "expanded contract preserves original five must criteria" "5" \
  "$(jq --argjson old "${contract1_frozen}" '
      [$old.criteria[] as $old_criterion
       | select($old_criterion.class == "must")
       | select(any(.definition.criteria[]; . == $old_criterion))]
      | length' "${contract_file}")"
assert_eq "expanded contract adds migration criterion" "1" \
  "$(jq '[.definition.criteria[] | select(.id == "Q-006" and .class == "must")] | length' "${contract_file}")"
assert_eq "floor-preserving revision is not misclassified as a late first contract" \
  "false" "$(jq -r '.late' "${contract_file}")"
assert_eq "additive re-contract preserves every existing semantic field exactly" \
  "$(jq -cS 'del(.criteria)' <<<"${contract1_frozen}")" \
  "$(jq -cS '.definition | del(.criteria)' "${contract_file}")"
assert_eq "re-contract clears recheck marker" "" \
  "$(read_state_key "${sid}" quality_contract_recheck_required)"
assert_file_present "new contract retains unresolved evidence as stale carryover" \
  "${evidence_file}"
assert_eq "carried evidence remains bound to the superseded contract" "1" \
  "$(jq -r '.contract_revision' "${evidence_file}" | sort -u)"
assert_eq "new contract retains unresolved frontier as causal authority" "open" \
  "$(jq -r '.status' "${frontier_file}")"
assert_eq "carried frontier remains bound to the superseded contract" "1" \
  "$(jq -r '.contract_revision' "${frontier_file}")"
assert_eq "mutation releases after expanded contract" "" \
  "$(run_pretool_write "${sid}" after-recontract-write)"

# History is audit redundancy, not the sole memory of an unresolved finding.
# Remove it only after the additive plan has committed; the retained stale open
# pair must keep both causal enforcement and its old receipt portfolio alive.
post_plan_open_frontier_fingerprint="$(artifact_fingerprint "${frontier_file}")"
post_plan_open_evidence_fingerprint="$(artifact_fingerprint "${evidence_file}")"
rm -f "${frontier_history_file}"
assert_file_absent "post-plan history-loss fixture is active" \
  "${frontier_history_file}"

# Re-prove the complete additive contract. The first new receipt exercises the
# retention transition that previously kept only four historical rows. Every
# old frontier receipt must now survive from the carried open pair even when
# frontier history disappears after re-contracting.
run_verification "${sid}" verify-v2-q001 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-001 --contract-v2' \
  'Q-001 contract-v2 deliberate proof: 8 passed, 0 failed'
run_verification "${sid}" verify-v2-q002 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-002 --contract-v2' \
  'Q-002 contract-v2 distinctive proof: 8 passed, 0 failed'
run_grep_verification "${sid}" verify-v2-q003 \
  "${TEST_PROJECT}/coherence-map.txt" 'coherence-contract contract-v2' \
  'coherence-contract v2 observation found across the expanded workflow'
run_verification "${sid}" verify-v2-q004 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-004 --comparison --contract-v2' \
  'Q-004 contract-v2 visionary comparison: 8 passed, 0 failed'
run_verification "${sid}" verify-v2-q005 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-005 --contract-v2' \
  'Q-005 contract-v2 completeness proof: 8 passed, 0 failed'
run_verification "${sid}" verify-v2-q006 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-006 --contract-v2' \
  'Q-006 migration lifecycle proof: 8 passed, 0 failed'
assert_eq "open-frontier receipt portfolio survives additive-contract compaction" \
  "5" "$(jq -sc --argjson required "${pre_recontract_frontier_receipts}" '
    [.[].receipt_id] as $have
    | [$required[] as $id | select(($have | index($id)) != null)] | length
  ' "${receipt_file}")"

contract2_receipts="$(jq -n \
  --arg q1 "$(jq -sr '[.[] | select(.tool_use_id == "verify-v2-q001")][-1].receipt_id' "${receipt_file}")" \
  --arg q2 "$(jq -sr '[.[] | select(.tool_use_id == "verify-v2-q002")][-1].receipt_id' "${receipt_file}")" \
  --arg q3 "$(jq -sr '[.[] | select(.tool_use_id == "verify-v2-q003")][-1].receipt_id' "${receipt_file}")" \
  --arg q4 "$(jq -sr '[.[] | select(.tool_use_id == "verify-v2-q004")][-1].receipt_id' "${receipt_file}")" \
  --arg q5 "$(jq -sr '[.[] | select(.tool_use_id == "verify-v2-q005")][-1].receipt_id' "${receipt_file}")" \
  --arg q6 "$(jq -sr '[.[] | select(.tool_use_id == "verify-v2-q006")][-1].receipt_id' "${receipt_file}")" \
  '{"Q-001":$q1,"Q-002":$q2,"Q-003":$q3,"Q-004":$q4,"Q-005":$q5,"Q-006":$q6}')"
assert_eq "additive contract has six distinct current proof receipts" "6" \
  "$(jq '[.[]] | unique | length' <<<"${contract2_receipts}")"
assert_eq "cross-contract remediation reviewer dispatch admitted" "" \
  "$(dispatch_agent "${sid}" excellence-reviewer \
    'Clear the inherited material frontier only with additive-contract counterproof')"
start_agent "${sid}" excellence-reviewer native-excellence-contract-v2
contract2_clear_review="$(review_payload "${contract2}" "${contract2_receipts}")"
contract2_clear_message="$(review_message "${contract2_clear_review}")"

# Make the current Q-003 receipt claim the exact old proof identity. With the
# history sidecar absent, a history-only implementation would forget the open
# frontier and accept this clear. The retained pair must reject it, roll back
# reviewer publication, and preserve the native call for corrected proof.
receipt_ledger_before_same_proof="${primary_dir}/.receipt-ledger-before-same-proof"
cp "${receipt_file}" "${receipt_ledger_before_same_proof}"
old_q003_receipt="$(jq -r 'select(.criterion_id == "Q-003") | .receipt_id' \
  "${evidence_file}")"
old_q003_proof_identity="$(jq -r --arg id "${old_q003_receipt}" \
  'select(.receipt_id == $id) | .proof_identity' "${receipt_file}")"
new_q003_receipt="$(jq -r '."Q-003"' <<<"${contract2_receipts}")"
jq -c --arg id "${new_q003_receipt}" --arg proof "${old_q003_proof_identity}" \
  'if .receipt_id == $id then .proof_identity = $proof else . end' \
  "${receipt_file}" >"${receipt_file}.same-proof"
mv -f "${receipt_file}.same-proof" "${receipt_file}"
post_plan_missing_history_result="$(record_review_result "${sid}" \
  native-excellence-contract-v2 "${contract2_clear_message}")"
assert_eq "post-plan missing-history rejection is handled" "0" \
  "$(jq -r '.rc' <<<"${post_plan_missing_history_result}")"
assert_contains "post-plan history loss cannot forget open-frontier causality" \
  "causally newer distinct proof" \
  "$(jq -r '.output' <<<"${post_plan_missing_history_result}")"
assert_eq "post-plan rejection preserves carried frontier byte-for-byte" \
  "${post_plan_open_frontier_fingerprint}" \
  "$(artifact_fingerprint "${frontier_file}")"
assert_eq "post-plan rejection preserves carried evidence byte-for-byte" \
  "${post_plan_open_evidence_fingerprint}" \
  "$(artifact_fingerprint "${evidence_file}")"
assert_file_absent "post-plan rejection does not manufacture history" \
  "${frontier_history_file}"
assert_eq "post-plan rejection retains the exact reviewer call" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"

printf '%s\n' '{malformed-after-additive-publication' \
  >"${frontier_history_file}"
post_plan_malformed_history_fingerprint="$(artifact_fingerprint \
  "${frontier_history_file}")"
post_plan_malformed_history_result="$(record_review_result "${sid}" \
  native-excellence-contract-v2 "${contract2_clear_message}")"
assert_eq "post-plan malformed-history rejection is handled" "0" \
  "$(jq -r '.rc' <<<"${post_plan_malformed_history_result}")"
assert_contains "post-plan malformed history cannot forget open-frontier causality" \
  "causally newer distinct proof" \
  "$(jq -r '.output' <<<"${post_plan_malformed_history_result}")"
assert_eq "malformed-history rejection preserves carried frontier bytes" \
  "${post_plan_open_frontier_fingerprint}" \
  "$(artifact_fingerprint "${frontier_file}")"
assert_eq "malformed-history rejection preserves carried evidence bytes" \
  "${post_plan_open_evidence_fingerprint}" \
  "$(artifact_fingerprint "${evidence_file}")"
assert_eq "malformed post-plan history is not silently repaired or consumed" \
  "${post_plan_malformed_history_fingerprint}" \
  "$(artifact_fingerprint "${frontier_history_file}")"
assert_eq "malformed-history rejection retains the exact reviewer call" "1" \
  "$(jsonl_count "${primary_dir}/agent_dispatch_starts.jsonl")"

cp "${receipt_ledger_before_same_proof}" "${receipt_file}"
cp "${authoritative_frontier_history}" "${frontier_history_file}"
record_review "${sid}" native-excellence-contract-v2 \
  "${contract2_clear_message}" >/dev/null
record_summary "${sid}" excellence-reviewer native-excellence-contract-v2 \
  "${contract2_clear_message}" >/dev/null
assert_eq "distinct new-contract counterproof clears inherited open frontier" \
  "clear" "$(jq -r '.status' "${frontier_file}")"
assert_eq "cross-contract clear publishes current contract revision" "2" \
  "$(jq -r '.contract_revision' "${frontier_file}")"
gate_after_contract2_clear="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "additive contract certifies after inherited frontier remediation" \
  "pass" "$(jq -r '.status // empty' <<<"${gate_after_contract2_clear}")"
contract2_history_summary="$(quality_frontier_history_summary \
  "${primary_dir}/quality_frontier_history.jsonl")"
assert_eq "cross-contract history counts the second material discovery" "2" \
  "$(jq -r '.material_discoveries' <<<"${contract2_history_summary}")"
assert_eq "cross-contract history counts the additive remediation" "2" \
  "$(jq -r '.remediations' <<<"${contract2_history_summary}")"
assert_eq "cross-contract history leaves no unresolved frontier" "0" \
  "$(jq -r '.unresolved_frontiers' <<<"${contract2_history_summary}")"

printf 'Test 11b: long-objective continuation preserves and binds the new scope tail\n'
long_sid="doe-long-objective"
long_filler="$(awk 'BEGIN { for (i=0; i<4200; i++) printf "x" }')"
run_router "${long_sid}" \
  "ulw make this long-form workflow excellent and visionary ${long_filler}" \
  >/dev/null
long_scope_middle="$(awk 'BEGIN { for (i=0; i<2400; i++) printf "y" }')"
long_scope_secret='sk-ant-abcdefghijklmnopqrstuv'
long_scope_sentinel="UNIQUE_SCOPE_BEGIN ${long_scope_middle} ${long_scope_secret} UNIQUE_SCOPE_END rollback recovery"
run_router "${long_sid}" \
  "continue and also add ${long_scope_sentinel}" >/dev/null
long_objective="$(read_state_key "${long_sid}" current_objective)"
assert_contains "bounded merged objective preserves scope marker" \
  "Scope addition (authoritative)" "${long_objective}"
assert_contains "bounded merged objective preserves new-scope opening" \
  "UNIQUE_SCOPE_BEGIN" "${long_objective}"
assert_contains "bounded merged objective preserves new-scope ending" \
  "UNIQUE_SCOPE_END rollback recovery" "${long_objective}"
assert_not_contains "scope-addition persistence redacts provider secrets" \
  "${long_scope_secret}" "${long_objective}"
assert_contains "scope-addition persistence retains an explicit redaction marker" \
  "<redacted-secret>" "${long_objective}"
assert_eq "long scope addition requires contract recheck" "1" \
  "$(read_state_key "${long_sid}" quality_contract_recheck_required)"
if (( ${#long_objective} <= 4000 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: merged objective exceeded 4000 characters (actual=%s)\n' \
    "${#long_objective}" >&2
  fail=$((fail + 1))
fi
assert_eq "long-objective planner dispatch admitted" "" \
  "$(dispatch_agent "${long_sid}" quality-planner 'Bind the preserved scope addition')"
start_agent "${long_sid}" quality-planner native-plan-long-scope
long_plan="$(plan_message "$(contract_v2 "$(contract_v1)")")"
record_plan "${long_sid}" native-plan-long-scope "${long_plan}" >/dev/null
record_summary "${long_sid}" quality-planner native-plan-long-scope \
  "${long_plan}" >/dev/null
long_contract_file="$(state_dir "${long_sid}")/quality_contract.json"
assert_file_present "long-objective planner publishes current contract" \
  "${long_contract_file}"
long_objective_digest="$(SESSION_ID="${long_sid}" bash -c '
  source "$1/common.sh"
  _omc_load_quality_contract
  _quality_contract_digest "$(read_state current_objective)"
' _ "${HOOK_DIR}")"
assert_eq "published contract digest binds scope-tail-preserving objective" \
  "${long_objective_digest}" \
  "$(jq -r '.objective_digest' "${long_contract_file}")"

printf 'Test 11c: successful inspection can honestly support an unmet review finding\n'
observation_sid="doe-observation-outcome"
observation_target="${TEST_PROJECT}/inspection-target.md"
printf '%s\n' 'This settled artifact intentionally lacks the frozen observation marker.' \
  >"${observation_target}"
run_router "${observation_sid}" \
  'ulw make this inspected workflow visionary, deliberate, distinctive, coherent, and complete' \
  >/dev/null
observation_contract="$(contract_v1 | jq -c '
  (.criteria[] | select(.id == "Q-001") | .proof_method) =
    "Inspect the settled target for the frozen Q-001 observation marker."
  | (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {tool_names:["Grep"],receipt_kinds:["inspection"],
     command_contains:["Q-001-observation-missing"],
     artifact_contains:["inspection-target.md"]}
  | (.criteria[] | select(.id == "Q-001")
      | .evidence_policy.allowed_kinds) = ["inspection"]
  | (.criteria[] | select(.id == "Q-003") | .proof_method) =
    "Run the isolated coherent-workflow assertion for this observation session."
  | (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {tool_names:["Bash"],receipt_kinds:["test"],
     command_contains:["--criterion Q-003-observation-session"],
     artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-003")
      | .evidence_policy.allowed_kinds) = ["test"]
')"
assert_eq "observation planner dispatch admitted" "" \
  "$(dispatch_agent "${observation_sid}" quality-planner \
    'Freeze the observation-bearing Definition contract')"
start_agent "${observation_sid}" quality-planner native-plan-observation
observation_plan="$(plan_message "${observation_contract}")"
record_plan "${observation_sid}" native-plan-observation \
  "${observation_plan}" >/dev/null
record_summary "${observation_sid}" quality-planner native-plan-observation \
  "${observation_plan}" >/dev/null
observation_dir="$(state_dir "${observation_sid}")"
assert_file_present "observation contract publishes" \
  "${observation_dir}/quality_contract.json"

run_grep_verification_failure "${observation_sid}" verify-observation-q001-failed \
  "${observation_target}" 'Q-001-observation-missing' \
  'inspection transport failed before the settled artifact could be observed'
run_grep_verification "${observation_sid}" verify-observation-q001 \
  "${observation_target}" 'Q-001-observation-missing' 'No matches found'
run_verification "${observation_sid}" verify-observation-q002 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-002' \
  'Q-002 observation-session proof: 4 passed, 0 failed'
run_verification "${observation_sid}" verify-observation-q003 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-003-observation-session' \
  'Q-003 observation-session proof: 4 passed, 0 failed'
run_verification "${observation_sid}" verify-observation-q004 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-004 --comparison' \
  'Q-004 observation-session comparison: 4 passed, 0 failed'
run_verification "${observation_sid}" verify-observation-q005 \
  'bash tests/test-definition-of-excellent-e2e.sh --criterion Q-005' \
  'Q-005 observation-session proof: 4 passed, 0 failed'
observation_receipt_file="${observation_dir}/verification_receipts.jsonl"
observation_receipts="$(jq -n \
  --arg q1 "$(jq -sr '[.[] | select(.tool_use_id == "verify-observation-q001")][-1].receipt_id' "${observation_receipt_file}")" \
  --arg q2 "$(jq -sr '[.[] | select(.tool_use_id == "verify-observation-q002")][-1].receipt_id' "${observation_receipt_file}")" \
  --arg q3 "$(jq -sr '[.[] | select(.tool_use_id == "verify-observation-q003")][-1].receipt_id' "${observation_receipt_file}")" \
  --arg q4 "$(jq -sr '[.[] | select(.tool_use_id == "verify-observation-q004")][-1].receipt_id' "${observation_receipt_file}")" \
  --arg q5 "$(jq -sr '[.[] | select(.tool_use_id == "verify-observation-q005")][-1].receipt_id' "${observation_receipt_file}")" \
  '{"Q-001":$q1,"Q-002":$q2,"Q-003":$q3,"Q-004":$q4,"Q-005":$q5}')"
observation_failed_receipt="$(jq -sr \
  '[.[] | select(.tool_use_id == "verify-observation-q001-failed")][-1].receipt_id' \
  "${observation_receipt_file}")"
assert_eq "successful no-match Grep mints an observational pass" "passed" \
  "$(jq -r 'select(.tool_use_id == "verify-observation-q001") | .outcome' \
    "${observation_receipt_file}")"

observation_review="$(review_payload \
  "${observation_contract}" "${observation_receipts}" | jq -c '
    (.criteria[] | select(.id == "Q-001") | .status) = "unmet"
    | (.criteria[] | select(.id == "Q-001") | .evidence_kind) = "inspection"
    | (.criteria[] | select(.id == "Q-001") | .basis) =
      "The successful inspection observed that the frozen Q-001 marker is absent from the settled target."
    | (.criteria[] | select(.id == "Q-003") | .evidence_kind) = "test"
    | .frontier.material = true
    | .frontier.bar_quality = "weak"
    | .frontier.title = "The deliberate observation marker is missing"
    | .frontier.why = "Independent inspection found the frozen deliberate criterion unmet even though the Grep observation itself completed successfully."
    | .frontier.recommended_move = "Add the intentional marker, re-inspect the settled target, and rerun independent review."
    | .frontier.criterion_ids = ["Q-001"]
    | .frontier.experiment = "Add the marker and compare a causally newer inspection receipt against this missing-state observation."
  ')"
observation_review_message="$(printf '%s\nQUALITY_REVIEW_JSON: %s\nVERDICT: FINDINGS (1)' \
  'Blind-first review found one observation-backed mandatory gap.' \
  "${observation_review}")"
assert_eq "observation reviewer dispatch admitted" "" \
  "$(dispatch_agent "${observation_sid}" excellence-reviewer \
    'Review the successful observation without conflating tool success with criterion truth')"
start_agent "${observation_sid}" excellence-reviewer native-excellence-observation

failed_observation_review="$(jq -c --arg receipt "${observation_failed_receipt}" '
  (.criteria[] | select(.id == "Q-001") | .refs) = [$receipt]
' <<<"${observation_review}")"
failed_observation_message="$(printf '%s\nQUALITY_REVIEW_JSON: %s\nVERDICT: FINDINGS (1)' \
  'A failed inspection cannot establish the semantic finding.' \
  "${failed_observation_review}")"
failed_observation_result="$(record_review_result "${observation_sid}" \
  native-excellence-observation "${failed_observation_message}")"
assert_contains "failed observation cannot support a fresh unmet assessment" \
  "receipt" "$(jq -r '.output' <<<"${failed_observation_result}")"
assert_file_absent "failed observation publishes no criterion evidence" \
  "${observation_dir}/quality_evidence.jsonl"

assertion_mismatch_review="$(jq -c '
  (.criteria[] | select(.id == "Q-001") | .status) = "met"
  | (.criteria[] | select(.id == "Q-002") | .status) = "unmet"
  | (.criteria[] | select(.id == "Q-002") | .basis) =
    "This deliberately contradicts the successful assertion receipt."
  | .frontier.title = "Assertion-outcome mismatch"
  | .frontier.why = "A passed assertion cannot honestly support an unmet criterion."
  | .frontier.recommended_move = "Return an outcome-congruent assertion assessment."
  | .frontier.criterion_ids = ["Q-002"]
  | .frontier.experiment = "Run a genuinely failing Q-002 assertion before reporting it unmet."
' <<<"${observation_review}")"
assertion_mismatch_message="$(printf '%s\nQUALITY_REVIEW_JSON: %s\nVERDICT: FINDINGS (1)' \
  'Assertion-bearing evidence remains outcome-congruent.' \
  "${assertion_mismatch_review}")"
assertion_mismatch_result="$(record_review_result "${observation_sid}" \
  native-excellence-observation "${assertion_mismatch_message}")"
assert_contains "passed assertion receipt cannot support unmet" \
  "receipt" "$(jq -r '.output' <<<"${assertion_mismatch_result}")"
assert_file_absent "assertion mismatch publishes no criterion evidence" \
  "${observation_dir}/quality_evidence.jsonl"

observation_review_result="$(record_review_result "${observation_sid}" \
  native-excellence-observation "${observation_review_message}")"
assert_eq "observation-backed unmet review is a handled hook outcome" "0" \
  "$(jq -r '.rc' <<<"${observation_review_result}")"
assert_eq "successful observation plus honest unmet status is accepted" "" \
  "$(jq -r '.output' <<<"${observation_review_result}")"
record_summary "${observation_sid}" excellence-reviewer \
  native-excellence-observation "${observation_review_message}" >/dev/null
assert_eq "accepted observation evidence records reviewer-owned failure" "failed" \
  "$(jq -r 'select(.criterion_id == "Q-001") | .result' \
    "${observation_dir}/quality_evidence.jsonl")"
assert_eq "observation-backed mandatory finding keeps frontier open" "open" \
  "$(jq -r '.status' "${observation_dir}/quality_frontier.json")"

normal_anomalies=0
if [[ -f "${TEST_STATE_ROOT}/hooks.log" ]]; then
  normal_anomalies="$(grep -c '\[anomaly\]' \
    "${TEST_STATE_ROOT}/hooks.log" 2>/dev/null || true)"
  normal_anomalies="${normal_anomalies:-0}"
fi
normal_anomalies=$((
  normal_anomalies
  - ${injected_verification_anomalies:-0}
  - ${injected_plan_anomalies:-0}
))
assert_eq "critical happy/rejection paths emit no hook-crash anomaly" "0" \
  "${normal_anomalies}"

printf 'Test 12: a first contract arriving after mutation is refused\n'
late_sid="doe-late"
run_router "${late_sid}" \
  'ulw make this workflow visionary, deliberate, distinctive, coherent, and complete' \
  >/dev/null
late_dir="$(state_dir "${late_sid}")"
# Simulate a mutating integration that reached PostToolUse outside the normal
# PreToolUse matcher. The planner must not turn this into an authoritative
# after-the-fact definition of quality.
run_mark_edit "${late_sid}" Write "${TEST_PROJECT}/late.txt" late-write
assert_eq "late fixture has mutation before contract" "1" \
  "$(read_state_key "${late_sid}" edit_revision)"
dispatch_agent "${late_sid}" quality-planner \
  'Attempt to freeze the first contract after mutation' >/dev/null
start_agent "${late_sid}" quality-planner native-plan-late
late_record_rc="$(record_plan_exit_code "${late_sid}" \
  native-plan-late "${plan1}")"
assert_eq "late first-contract refusal is a handled hook outcome" "0" \
  "${late_record_rc}"
assert_file_absent "late first contract is not published" \
  "${late_dir}/quality_contract.json"
assert_file_absent "late first plan is not published" \
  "${late_dir}/current_plan.md"
assert_eq "late refusal preserves planner causal row for recovery" "1" \
  "$(jsonl_count "${late_dir}/agent_dispatch_starts.jsonl")"

printf 'Test 13: unsafe transaction target refuses publication without partial state\n'
txn_sid="doe-transaction"
run_router "${txn_sid}" \
  'ulw make this command experience visionary, deliberate, distinctive, coherent, and complete' \
  >/dev/null
txn_dir="$(state_dir "${txn_sid}")"
dispatch_agent "${txn_sid}" quality-planner \
  'Freeze the Definition against a hostile target shape' >/dev/null
start_agent "${txn_sid}" quality-planner native-plan-transaction
external_target="${TEST_HOME}/outside-contract.json"
printf '%s\n' '{"sentinel":"unchanged"}' >"${external_target}"
ln -s "${external_target}" "${txn_dir}/quality_contract.json"
txn_plan_revision_before="$(read_state_key "${txn_sid}" plan_revision)"
txn_record_rc="$(record_plan_exit_code "${txn_sid}" \
  native-plan-transaction "${plan1}")"
if [[ "${txn_record_rc}" -ne 0 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: unsafe transaction target should make record-plan exit non-zero\n' >&2
  fail=$((fail + 1))
fi
assert_eq "external target remains unchanged" "unchanged" \
  "$(jq -r '.sentinel' "${external_target}")"
assert_file_absent "transaction publishes no plan on unsafe target" \
  "${txn_dir}/current_plan.md"
assert_eq "transaction does not advance plan revision" \
  "${txn_plan_revision_before}" "$(read_state_key "${txn_sid}" plan_revision)"
assert_eq "transaction preserves exact causal start" "1" \
  "$(jsonl_count "${txn_dir}/agent_dispatch_starts.jsonl")"

printf '\nResult: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
