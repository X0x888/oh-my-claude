#!/usr/bin/env bash
# test-posttool-dispatch.sh — focused regression for posttool-dispatch.sh
# (v1.48 W3.1 hook consolidation) and the common.sh re-source guard it
# depends on.
#
# The consolidation's contract, pinned here:
#   1. One dispatcher process replaces the four per-call processes, with
#      byte-identical handler scripts sourced in pipeline subshells.
#   2. Bash calls run edit tracking plus the four folded handlers; non-Bash
#      calls run timing only.
#   3. Every non-circuit handler stays silent; circuit-breaker's hook JSON passes
#      through the dispatcher stdout unmodified.
#   4. One handler's early `exit` (or failure) cannot starve the others.
#   5. settings.patch.json wires exactly one universal PostToolUse entry to
#      the dispatcher and none to the three folded Bash-matcher scripts —
#      while the mcp__.* record-verification matcher survives (that path
#      still invokes the script standalone).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISPATCH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/posttool-dispatch.sh"
PRETOOL="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh"
VERIFY_START="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-tool-start-revision.sh"
MARK_EDIT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
PATCH_JSON="${REPO_ROOT}/config/settings.patch.json"

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

ORIG_HOME="${HOME}"
setup_session() {
  local sid="$1"
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state/${sid}"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
  jq -nc --arg ts "$(date +%s)" '{
    workflow_mode: "ultrawork",
    task_domain: "coding",
    task_intent: "execution",
    current_objective: "test",
    last_user_prompt_ts: $ts
  }' > "${TEST_HOME}/.claude/quality-pack/state/${sid}/session_state.json"
}

teardown_session() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}" 2>/dev/null || true
}

run_dispatch() {
  local payload="$1"
  printf '%s' "${payload}" | bash "${DISPATCH}" 2>/dev/null || true
}

run_pretool() {
  local payload="$1"
  printf '%s' "${payload}" | bash "${PRETOOL}" 2>/dev/null || true
  printf '%s' "${payload}" | bash "${VERIFY_START}" 2>/dev/null || true
}

run_mark_edit() {
  local payload="$1"
  printf '%s' "${payload}" | bash "${MARK_EDIT}" 2>/dev/null || true
}

init_git_worktree() {
  local work="$1"
  mkdir -p "${work}"
  git -C "${work}" init --quiet --initial-branch=main 2>/dev/null || git -C "${work}" init --quiet
  git -C "${work}" config user.email test@example.com
  git -C "${work}" config user.name Test
  printf 'baseline\n' > "${work}/tracked.txt"
  git -C "${work}" add tracked.txt
  git -C "${work}" commit --quiet -m baseline
}

bash_payload() {
  local sid="$1" cmd="$2" resp="$3"
  jq -nc --arg s "${sid}" --arg c "${cmd}" --arg r "${resp}" \
    '{session_id: $s, tool_name: "Bash", tool_use_id: "tu-1",
      tool_input: {command: $c}, tool_response: $r, cwd: "/tmp"}'
}

fail_payload() {
  local sid="$1" cmd="$2"
  jq -nc --arg s "${sid}" --arg c "${cmd}" \
    '{session_id: $s, tool_name: "Bash", tool_use_id: "tu-f",
      tool_input: {command: $c},
      tool_response: {exit_code: 1, stdout: "boom"}, cwd: "/tmp"}'
}

# ----------------------------------------------------------------------
printf 'T1: Bash call runs timing AND verification recorder in one process\n'
setup_session "d1"
payload_t1="$(bash_payload d1 'bash tests/test-sample.sh' '12 passed, 0 failed')"
run_pretool "${payload_t1}" >/dev/null
out_t1="$(run_dispatch "${payload_t1}")"
assert_eq "T1: recorders stay silent on stdout" "" "${out_t1}"
timing_file="${TEST_HOME}/.claude/quality-pack/state/d1/timing.jsonl"
rc=0; [[ -f "${timing_file}" ]] && grep -q '"kind":"end"' "${timing_file}" || rc=1
assert_true "T1: timing end row written" "${rc}"
state="${TEST_HOME}/.claude/quality-pack/state/d1/session_state.json"
assert_eq "T1: verification outcome recorded" "passed" \
  "$(jq -r '.last_verify_outcome // ""' "${state}")"
rc=0; [[ -n "$(jq -r '.last_verify_ts // ""' "${state}")" ]] || rc=1
assert_true "T1: verification timestamp recorded" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T2: non-Bash call runs timing only\n'
setup_session "d2"
payload_t2="$(jq -nc '{session_id: "d2", tool_name: "Read", tool_use_id: "tu-2",
  tool_input: {file_path: "/tmp/x"}, tool_response: "content"}')"
out_t2="$(run_dispatch "${payload_t2}")"
assert_eq "T2: silent stdout" "" "${out_t2}"
timing_file="${TEST_HOME}/.claude/quality-pack/state/d2/timing.jsonl"
rc=0; [[ -f "${timing_file}" ]] && grep -q '"kind":"end"' "${timing_file}" || rc=1
assert_true "T2: timing end row written for non-Bash tool" "${rc}"
assert_eq "T2: no verification state for non-Bash tool" "" \
  "$(jq -r '.last_verify_ts // ""' "${TEST_HOME}/.claude/quality-pack/state/d2/session_state.json")"
teardown_session

# ----------------------------------------------------------------------
printf 'T3: circuit-breaker output passes through; timing still records\n'
setup_session "d3"
p="$(fail_payload d3 'flaky-build --retry')"
out_a="$(run_dispatch "${p}")"
out_b="$(run_dispatch "${p}")"
out_c="$(run_dispatch "${p}")"
assert_eq "T3: first failure silent" "" "${out_a}"
assert_eq "T3: second failure silent" "" "${out_b}"
assert_contains "T3: third failure fires the breaker" "CIRCUIT BROKEN" "${out_c}"
rc=0; jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 <<<"${out_c}" || rc=$?
assert_true "T3: breaker JSON passes through intact" "${rc}"
timing_file="${TEST_HOME}/.claude/quality-pack/state/d3/timing.jsonl"
assert_eq "T3: all three calls produced timing rows" "3" \
  "$(grep -c '"kind":"end"' "${timing_file}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T4: a handler early-exit cannot starve later handlers\n'
# Payload with NO session_id: posttool-timing exits 0 immediately (its
# subshell), record-verification exits too — but the dispatcher itself
# must still exit 0 and stay silent, not abort under set -e.
setup_session "d4"
out_t4="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":"hi"}' \
  | bash "${DISPATCH}" 2>/dev/null)"; rc=$?
assert_eq "T4: dispatcher exit 0 despite handler early-exits" "0" "${rc}"
assert_eq "T4: silent" "" "${out_t4}"
teardown_session

# ----------------------------------------------------------------------
printf 'T5: common.sh re-source guard short-circuits and tops up lazy libs\n'
rc=0
bash -c "
  set -euo pipefail
  export OMC_LAZY_CLASSIFIER=1
  . '${COMMON}'
  [[ -n \"\${_OMC_COMMON_SOURCED}\" ]] || exit 1
  # Re-source with classifier wanted eagerly: guard must load it.
  unset OMC_LAZY_CLASSIFIER
  . '${COMMON}'
  # classifier symbol must now exist
  declare -F is_imperative_request >/dev/null || exit 2
" 2>/dev/null || rc=$?
assert_eq "T5: guarded re-source loads missing lib and returns" "0" "${rc}"

# ----------------------------------------------------------------------
printf 'T6: settings.patch.json wiring matches the consolidation\n'
assert_eq "T6: exactly one universal PostToolUse entry" "1" \
  "$(jq -r '[.hooks.PostToolUse[] | select(has("matcher") | not)] | length' "${PATCH_JSON}")"
assert_contains "T6: universal entry is the dispatcher" "posttool-dispatch.sh" \
  "$(jq -r '[.hooks.PostToolUse[] | select(has("matcher") | not)][0].hooks[0].command' "${PATCH_JSON}")"
assert_eq "T6: no Bash-matcher entries remain" "0" \
  "$(jq -r '[.hooks.PostToolUse[] | select(.matcher == "Bash")] | length' "${PATCH_JSON}")"
assert_eq "T6: mcp record-verification matcher survives" "1" \
  "$(jq -r '[.hooks.PostToolUse[] | select(.matcher == "mcp__.*")] | length' "${PATCH_JSON}")"
rc=0; grep -q 'posttool-timing.sh' "${PATCH_JSON}" && rc=1
assert_true "T6: no direct posttool-timing wiring remains" "${rc}"
assert_eq "T6: failed Bash calls are wired to the edit-clock writer" "1" \
  "$(jq -r '[.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("mark-edit.sh"))] | length' "${PATCH_JSON}")"
assert_eq "T6: complete mutation matcher reaches the pretool guard" "1" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash|Edit|Write|MultiEdit|NotebookEdit") | .hooks[] | select(.command | contains("pretool-intent-guard.sh"))] | length' "${PATCH_JSON}")"
assert_eq "T6: Bash/MCP dispatch revisions have a dedicated PreToolUse recorder" "1" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash|mcp__.*") | .hooks[] | select(.command | contains("record-tool-start-revision.sh"))] | length' "${PATCH_JSON}")"
assert_eq "T6: complete direct-edit matcher reaches the clock writer" "1" \
  "$(jq -r '[.hooks.PostToolUse[] | select(.matcher == "Edit|Write|MultiEdit|NotebookEdit") | .hooks[] | select(.command | contains("mark-edit.sh"))] | length' "${PATCH_JSON}")"
assert_eq "T6: successful Bash dispatcher remains universal" "1" \
  "$(jq -r '[.hooks.PostToolUse[] | select((.matcher // "") == "") | .hooks[] | select(.command | contains("posttool-dispatch.sh"))] | length' "${PATCH_JSON}")"

# ----------------------------------------------------------------------
printf 'T7: mutation-capable Bash advances edit clocks through dispatcher\n'
setup_session "d7"
mkdir -p "${TEST_HOME}/work"
printf 'changed\n' > "${TEST_HOME}/work/app.js"
payload_t7="$(jq -nc --arg cwd "${TEST_HOME}/work" '{
  session_id:"d7",tool_name:"Bash",tool_use_id:"tu-edit-fallback",cwd:$cwd,
  tool_input:{command:"printf changed > app.js"},tool_response:{exit_code:0}
}')"
assert_eq "T7: edit recorder stays silent" "" "$(run_dispatch "${payload_t7}")"
state="${TEST_HOME}/.claude/quality-pack/state/d7/session_state.json"
rc=0; [[ -n "$(jq -r '.last_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T7: last_edit_ts recorded" "${rc}"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T7: last_code_edit_ts recorded" "${rc}"
assert_eq "T7: unknown Bash scope does not fabricate an exact file count" "0" \
  "$(jq -r '.code_edit_count // 0' "${state}")"
assert_eq "T7: unknown Bash scope is recorded separately" "1" \
  "$(jq -r '.bash_unknown_edit_scope // 0' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T8: read-only and delivery-only Bash do not stale edit clocks\n'
setup_session "d8"
run_dispatch "$(bash_payload d8 'git status --short' '')" >/dev/null
run_dispatch "$(bash_payload d8 'git commit -m "fix touch handling"' '')" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d8/session_state.json"
assert_eq "T8: read/delivery commands leave last_edit_ts empty" "" \
  "$(jq -r '.last_edit_ts // ""' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T9: git baseline suppresses scratch-file false positives\n'
setup_session "d9"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
scratch="${TEST_HOME}/scratch.tmp"
payload_t9="$(jq -nc --arg cwd "${work}" --arg scratch "${scratch}" '{
  session_id:"d9",tool_name:"Bash",cwd:$cwd,
  tool_input:{command:("touch " + $scratch)},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t9}" >/dev/null
touch "${scratch}"
run_dispatch "${payload_t9}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d9/session_state.json"
assert_eq "T9: out-of-worktree scratch mutation leaves edit clock empty" "" \
  "$(jq -r '.last_edit_ts // ""' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T10: git baseline detects a real worktree mutation\n'
setup_session "d10"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t10="$(jq -nc --arg cwd "${work}" '{
  session_id:"d10",tool_name:"Bash",tool_use_id:"tu-worktree",cwd:$cwd,
  tool_input:{command:"printf changed > app.js"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t10}" >/dev/null
printf 'changed\n' > "${work}/app.js"
run_dispatch "${payload_t10}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d10/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T10: changed worktree advances code clock" "${rc}"
assert_eq "T10: consumed baseline is removed" "0" \
  "$(find "${TEST_HOME}/.claude/quality-pack/state/d10/.bash-mutation-baselines" -type f 2>/dev/null | wc -l | tr -d ' ')"
teardown_session

# ----------------------------------------------------------------------
printf 'T11: failed Bash that changed the worktree still advances clocks\n'
setup_session "d11"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t11="$(jq -nc --arg cwd "${work}" '{
  session_id:"d11",hook_event_name:"PostToolUseFailure",tool_name:"Bash",
  tool_use_id:"tu-partial",cwd:$cwd,
  tool_input:{command:"printf partial > partial.js; false"},
  tool_response:{exit_code:1,stderr:"failed after write"}
}')"
run_pretool "${payload_t11}" >/dev/null
printf 'partial\n' > "${work}/partial.js"
run_mark_edit "${payload_t11}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d11/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T11: partial failure cannot hide its worktree edit" "${rc}"
assert_eq "T11: failed Bash leaves no success-only edit-outcome marker" "0" \
  "$(find "${TEST_HOME}/.claude/quality-pack/state/d11/.bash-edit-outcomes" -type f 2>/dev/null | wc -l | tr -d ' ')"
teardown_session

# ----------------------------------------------------------------------
printf 'T12: NotebookEdit uses notebook_path and advances code clocks\n'
setup_session "d12"
payload_t12="$(jq -nc '{
  session_id:"d12",tool_name:"NotebookEdit",
  tool_input:{notebook_path:"/project/analysis.ipynb"}
}')"
run_mark_edit "${payload_t12}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d12/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T12: NotebookEdit advances code clock" "${rc}"
assert_eq "T12: notebook path participates in unique edit count" "1" \
  "$(jq -r '.code_edit_count // 0' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T13: commands that redirect their working root fail closed\n'
setup_session "d13"
work_a="${TEST_HOME}/repo-a"
work_b="${TEST_HOME}/repo-b"
init_git_worktree "${work_a}"
init_git_worktree "${work_b}"
git -C "${work_b}" checkout --quiet -b changed
printf 'changed elsewhere\n' > "${work_b}/tracked.txt"
git -C "${work_b}" commit --quiet -am changed
git -C "${work_b}" checkout --quiet main
payload_t13="$(jq -nc --arg cwd "${work_a}" --arg other "${work_b}" '{
  session_id:"d13",tool_name:"Bash",tool_use_id:"tu-git-c",cwd:$cwd,
  tool_input:{command:("git -C " + $other + " checkout changed")},
  tool_response:{exit_code:0}
}')"
run_pretool "${payload_t13}" >/dev/null
git -C "${work_b}" checkout --quiet changed
run_dispatch "${payload_t13}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d13/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T13: git -C cannot hide an edit behind the hook cwd baseline" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T14: shared mutation predicate covers claimed families without prose false positives\n'
predicate_matches() {
  local command="$1"
  OMC_PREDICATE_COMMAND="${command}" HOME="${ORIG_HOME}" bash -c '
    set -euo pipefail
    export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
    . "'"${COMMON}"'"
    bash_command_may_edit_worktree "${OMC_PREDICATE_COMMAND}"
  ' 2>/dev/null
}
signature_matches() {
  local command="$1"
  OMC_PREDICATE_COMMAND="${command}" HOME="${ORIG_HOME}" bash -c '
    set -euo pipefail
    export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
    . "'"${COMMON}"'"
    bash_command_has_mutation_signature "${OMC_PREDICATE_COMMAND}"
  ' 2>/dev/null
}
for command in \
  'printf x > app.js' \
  'printf x > "app.js"' \
  'printf x > "$target"' \
  'command 2> errors.log' \
  'sed -i s/x/y/ app.js' \
  'sed -E -i s/x/y/ app.js' \
  "bash -c 'printf x > app.js'" \
  'prettier --write app.js' \
  'npm install' \
  'git checkout other' \
  'git stash' \
  'git checkout-index -f app.js' \
  './cat tracked.txt' \
  'git diff --output=report.patch' \
  'git -c diff.external=./mutator diff -- tracked.txt' \
  'git --paginate status' \
  'git fetch --upload-pack=./mutator .' \
  'git status --short' \
  'git apply --check fix.patch' \
  'black --check .' \
  'isort --check-only .' \
  'rustfmt --check src.rs' \
  'swiftformat --lint .' \
  './generate.sh' \
  'python tools/rewrite.py' \
  'make format' \
  'echo "$(touch app.js)"' \
  'find . -delete' \
  'printf x >| app.js' \
  "bash -c \$'printf x > .env'" \
  'bash -c "$script"' \
  "python -c 'Path(\"x\").write_text(\"y\")'"; do
  rc=0; predicate_matches "${command}" || rc=$?
  assert_true "T14 positive: ${command}" "${rc}"
done
for command in \
  'git commit -m "fix touch handling"' \
  'git push origin main' \
  'echo "a > b"' \
  'printf x > /dev/null'; do
  rc=0; predicate_matches "${command}" && rc=1 || rc=0
  assert_true "T14 negative: ${command}" "${rc}"
done
for command in \
  "bash --noprofile -c 'printf > .env'" \
  "sh -eu -c 'printf x > .env'" \
  "env bash -c 'printf x > .env'" \
  "sudo bash -c 'printf x > .env'" \
  "command bash -c 'printf x > .env'" \
  "timeout 5 bash -c 'printf x > .env'" \
  "FOO='a b' bash -c 'printf x > .env'" \
  "exec bash -c 'printf x > .env'" \
  "time -p bash -c 'printf x > .env'" \
  'bash -c "printf \"x\" > .env"'; do
  rc=0; signature_matches "${command}" || rc=$?
  assert_true "T14 literal shell -c signature: ${command}" "${rc}"
done
for command in \
  "eval 'printf x > .env'" \
  "printf 'printf x > .env' | xargs -I{} sh -c '{}'" \
  "python3 -c 'open(\".env\", \"w\").write(\"x\")'" \
  "python3 -c 'open(\".env\", mode=\"w\").write(\"x\")'" \
  "python3 -c 'open(file=\".env\", mode=\"w\").write(\"x\")'" \
  "python3 -c 'open(mode=\"w\", file=\".env\").write(\"x\")'" \
  "python3 -c 'open(str(\".env\"), mode=\"w\").write(\"x\")'" \
  "python3 -c 'open(os.path.join(\".\", \".env\"), mode=\"w\").write(\"x\")'" \
  "python3 -c 'open(\".env\", mode=\"r\" if False else \"w\")'" \
  "python3 -c 'open(\".env\", \"r\" if False else \"w\")'" \
  "python3 -c 'open(\".env\", mode=\"r\" + \"+\")'" \
  'python3 -c '\''open(".env", mode="\x77")'\''' \
  'python3 -c '\''open(".env", mode="r\x2b")'\''' \
  "env python3 -c 'open(\".env\", \"w\")'" \
  "command python3 -c 'open(\".env\", \"w\")'" \
  "command -- python3 -c 'open(\".env\", \"w\")'" \
  "timeout 5 python3 -c 'open(\".env\", \"w\")'" \
  "python3 -X dev -c 'open(\".env\", \"w\")'" \
  "python3 -W ignore -c 'open(\".env\", \"w\")'" \
  "PYTHONUTF8=1 python3 -c 'open(\".env\", \"w\")'" \
  "FOO=1 command python3 -c 'open(\".env\", \"w\")'" \
  "FOO='a b' python3 -c 'open(\".env\", \"w\")'" \
  "env FOO='a b' python3 -c 'open(\".env\", \"w\")'" \
  "exec python3 -c 'open(\".env\", \"w\")'" \
  "time -p python3 -c 'open(\".env\", \"w\")'" \
  'python3 -c "open(\".env\", mode=\"w\").write(\"x\")"'; do
  rc=0; signature_matches "${command}" || rc=$?
  assert_true "T14 executor/write-mode signature: ${command}" "${rc}"
done
for command in \
  "printf \"example: bash -c 'rm x'\"" \
  "echo \"example: env bash -c 'rm x'\"" \
  "printf 'example; bash -c \"rm x\"'" \
  "bash -c \$'printf x > .env'" \
  'bash -c "$script"'; do
  rc=0; signature_matches "${command}" && rc=1 || rc=0
  assert_true "T14 non-literal/non-executable shell -c text: ${command}" "${rc}"
done
for command in \
  "eval 'printf hello'" \
  "python3 -c 'print(open(\"tracked.txt\").read())'" \
  "python3 -c 'print(\"open(\")'" \
  "python3 -c 'def open(file, mode): pass'" \
  "python3 -c 'async def open(file, mode): pass'" \
  "python3 -c 'print(open(\"mode=read.txt\").read())'" \
  "python3 -c 'print(open(\"some-mode=w\").read())'" \
  'python3 -c "print(open(\"tracked.txt\").read())"'; do
  rc=0; signature_matches "${command}" && rc=1 || rc=0
  assert_true "T14 read-only executor body: ${command}" "${rc}"
done
rc=0
HOME="${ORIG_HOME}" OMC_PREDICATE_COMMAND='python3 -c "print(\"a & b\")"' bash -c '
  set -euo pipefail
  export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
  . "'"${COMMON}"'"
  _omc_bash_command_is_async "${OMC_PREDICATE_COMMAND}"
' 2>/dev/null && rc=1 || rc=0
assert_true "T14 escaped ampersand inside quotes is synchronous" "${rc}"
nix_home="$(mktemp -d)"
mkdir -p "${nix_home}/fake/bin"
rc=0
HOME="${nix_home}" PATH="/usr/bin:/bin" bash -c '
  set -euo pipefail
  export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
  . "'"${COMMON}"'"
  _omc_nix_observer_dir_is_trusted "/nix/store/abc-tool/bin"
' 2>/dev/null || rc=$?
assert_true "T14 immutable Nix store bin shape is trusted" "${rc}"
rc=0
HOME="${nix_home}" PATH="${nix_home}/.local/state/nix/profiles/../../../../fake/bin:/usr/bin:/bin" bash -c '
  set -euo pipefail
  export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
  . "'"${COMMON}"'"
  [[ ":${_OMC_OBSERVER_SAFE_PATH}:" != *":${HOME}/fake/bin:"* ]]
' 2>/dev/null || rc=$?
assert_true "T14 traversal cannot smuggle a writable Nix profile bin" "${rc}"
rm -rf "${nix_home}"

# ----------------------------------------------------------------------
printf 'T15: quoted redirect target advances clocks end-to-end\n'
setup_session "d15"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t15="$(jq -nc --arg cwd "${work}" '{
  session_id:"d15",tool_name:"Bash",tool_use_id:"tu-quoted",cwd:$cwd,
  tool_input:{command:"target=app.js; printf changed > \"$target\""},
  tool_response:{exit_code:0}
}')"
run_pretool "${payload_t15}" >/dev/null
printf 'changed\n' > "${work}/app.js"
run_dispatch "${payload_t15}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d15/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T15: quoted/variable redirect cannot bypass clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T16: clean branch switch changes the snapshot via HEAD identity\n'
setup_session "d16"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
git -C "${work}" checkout --quiet -b other
printf 'other\n' > "${work}/tracked.txt"
git -C "${work}" commit --quiet -am other
git -C "${work}" checkout --quiet main
payload_t16="$(jq -nc --arg cwd "${work}" '{
  session_id:"d16",tool_name:"Bash",tool_use_id:"tu-checkout",cwd:$cwd,
  tool_input:{command:"git checkout other"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t16}" >/dev/null
git -C "${work}" checkout --quiet other
run_dispatch "${payload_t16}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d16/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T16: clean-to-clean checkout advances clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T17: background mutation is marked at launch, before delayed write\n'
setup_session "d17"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t17="$(jq -nc --arg cwd "${work}" '{
  session_id:"d17",tool_name:"Bash",tool_use_id:"tu-bg",cwd:$cwd,
  tool_input:{command:"sleep 2; printf changed > app.js",run_in_background:true},
  tool_response:"Command running in background with ID: bg-1"
}')"
run_pretool "${payload_t17}" >/dev/null
run_dispatch "${payload_t17}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d17/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T17: background launch cannot consume an unchanged baseline and disappear" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T18: mutation-bearing Bash call cannot self-verify\n'
setup_session "d18"
work="${TEST_HOME}/work"
mkdir -p "${work}"
printf 'changed\n' > "${work}/app.py"
payload_t18="$(jq -nc --arg cwd "${work}" '{
  session_id:"d18",tool_name:"Bash",tool_use_id:"tu-test-edit",cwd:$cwd,
  tool_input:{command:"pytest -q; printf changed > app.py"},
  tool_response:"1 passed in 0.1s"
}')"
run_dispatch "${payload_t18}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d18/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T18: compound call records edit" "${rc}"
assert_eq "T18: same compound call is not accepted as verification" "" \
  "$(jq -r '.last_verify_ts // ""' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T19: unknown Bash scope does not inflate exact unique-file count\n'
setup_session "d19"
work="${TEST_HOME}/work"
mkdir -p "${work}"
payload_t19="$(jq -nc --arg cwd "${work}" '{
  session_id:"d19",tool_name:"Bash",tool_use_id:"tu-count",cwd:$cwd,
  tool_input:{command:"printf changed > app.js"},tool_response:{exit_code:0}
}')"
run_dispatch "${payload_t19}" >/dev/null
run_mark_edit "$(jq -nc '{
  session_id:"d19",tool_name:"Edit",tool_input:{file_path:"/work/app.js"}
}')" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d19/session_state.json"
assert_eq "T19: one exact Edit remains count=1 after unknown Bash scope" "1" \
  "$(jq -r '.code_edit_count // 0' "${state}")"
assert_eq "T19: uncertainty remains separately visible" "1" \
  "$(jq -r '.bash_unknown_edit_scope // 0' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T20: opaque executable mutation is detected by default snapshotting\n'
setup_session "d20"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '#!/usr/bin/env bash\nprintf generated > tracked.txt\n' > "${work}/generate.sh"
chmod +x "${work}/generate.sh"
git -C "${work}" add generate.sh
git -C "${work}" commit --quiet -m generator
payload_t20="$(jq -nc --arg cwd "${work}" '{
  session_id:"d20",tool_name:"Bash",tool_use_id:"tu-opaque",cwd:$cwd,
  tool_input:{command:"./generate.sh"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t20}" >/dev/null
(cd "${work}" && ./generate.sh)
run_dispatch "${payload_t20}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d20/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T20: opaque generator cannot bypass the code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T21: recognized writes to ignored files fail closed\n'
setup_session "d21"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '.env\n' > "${work}/.gitignore"
git -C "${work}" add .gitignore
git -C "${work}" commit --quiet -m ignore-env
payload_t21="$(jq -nc --arg cwd "${work}" '{
  session_id:"d21",tool_name:"Bash",tool_use_id:"tu-ignored",cwd:$cwd,
  tool_input:{command:"printf secret > .env"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t21}" >/dev/null
printf 'secret\n' > "${work}/.env"
run_dispatch "${payload_t21}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d21/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T21: ignored target still advances the code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T22: non-trailing detached mutation is marked at launch\n'
setup_session "d22"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t22="$(jq -nc --arg cwd "${work}" '{
  session_id:"d22",tool_name:"Bash",tool_use_id:"tu-detached",cwd:$cwd,
  tool_input:{command:"(sleep 2; printf changed > tracked.txt) & disown"},
  tool_response:"launched"
}')"
run_pretool "${payload_t22}" >/dev/null
run_dispatch "${payload_t22}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d22/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T22: detached non-trailing ampersand cannot consume and disappear" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T23: verification-only Bash remains verification when snapshot is unchanged\n'
setup_session "d23"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t23="$(jq -nc --arg cwd "${work}" '{
  session_id:"d23",tool_name:"Bash",tool_use_id:"tu-verify-only",cwd:$cwd,
  tool_input:{command:"pytest -q"},tool_response:"1 passed in 0.1s"
}')"
run_pretool "${payload_t23}" >/dev/null
run_dispatch "${payload_t23}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d23/session_state.json"
assert_eq "T23: unchanged verification does not fabricate an edit" "" \
  "$(jq -r '.last_code_edit_ts // ""' "${state}")"
rc=0; [[ -n "$(jq -r '.last_verify_ts // ""' "${state}")" ]] || rc=1
assert_true "T23: separate unchanged test is accepted as verification" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T24: opaque mutation after an in-worktree cd remains observable\n'
setup_session "d24"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
mkdir -p "${work}/sub"
printf '#!/usr/bin/env bash\nprintf nested > ../tracked.txt\n' > "${work}/sub/generate.sh"
chmod +x "${work}/sub/generate.sh"
git -C "${work}" add sub/generate.sh
git -C "${work}" commit --quiet -m nested-generator
payload_t24="$(jq -nc --arg cwd "${work}" '{
  session_id:"d24",tool_name:"Bash",tool_use_id:"tu-cd-opaque",cwd:$cwd,
  tool_input:{command:"cd sub && ./generate.sh"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t24}" >/dev/null
(cd "${work}/sub" && ./generate.sh)
run_dispatch "${payload_t24}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d24/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T24: in-repo cd does not make opaque mutation unobservable" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T25: literal shell -c writes to ignored files still veto same-call verification\n'
setup_session "d25"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '.env\n' > "${work}/.gitignore"
git -C "${work}" add .gitignore
git -C "${work}" commit --quiet -m ignore-env
printf 'before\n' > "${work}/.env"
payload_t25="$(jq -nc --arg cwd "${work}" '{
  session_id:"d25",tool_name:"Bash",tool_use_id:"tu-shell-c-ignored",cwd:$cwd,
  tool_input:{command:"pytest -q; bash -c '\''printf changed > .env'\''"},
  tool_response:"1 passed in 0.1s"
}')"
run_pretool "${payload_t25}" >/dev/null
(cd "${work}" && bash -c 'printf changed > .env')
run_dispatch "${payload_t25}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d25/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T25: shell -c ignored-file write advances clock" "${rc}"
assert_eq "T25: edit-bearing test compound cannot self-verify" "" \
  "$(jq -r '.last_verify_ts // ""' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T26: absolute outside-root test redirect neither edits nor vetoes verification\n'
setup_session "d26"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
scratch="${TEST_HOME}/pytest.log"
payload_t26="$(jq -nc --arg cwd "${work}" --arg scratch "${scratch}" '{
  session_id:"d26",tool_name:"Bash",tool_use_id:"tu-external-log",cwd:$cwd,
  tool_input:{command:("pytest -q > " + $scratch)},tool_response:"1 passed in 0.1s"
}')"
run_pretool "${payload_t26}" >/dev/null
printf '1 passed in 0.1s\n' > "${scratch}"
run_dispatch "${payload_t26}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d26/session_state.json"
assert_eq "T26: external log redirect leaves code clock empty" "" \
  "$(jq -r '.last_code_edit_ts // ""' "${state}")"
rc=0; [[ -n "$(jq -r '.last_verify_ts // ""' "${state}")" ]] || rc=1
assert_true "T26: redirected test is still accepted as verification" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T27: synchronous stderr pipeline is not mistaken for background mutation\n'
setup_session "d27"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t27="$(jq -nc --arg cwd "${work}" '{
  session_id:"d27",tool_name:"Bash",tool_use_id:"tu-pipe-stderr",cwd:$cwd,
  tool_input:{command:"pytest -q |& grep passed"},tool_response:"1 passed in 0.1s"
}')"
run_pretool "${payload_t27}" >/dev/null
run_dispatch "${payload_t27}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d27/session_state.json"
assert_eq "T27: |& pipeline leaves code clock empty" "" \
  "$(jq -r '.last_code_edit_ts // ""' "${state}")"
rc=0; [[ -n "$(jq -r '.last_verify_ts // ""' "${state}")" ]] || rc=1
assert_true "T27: |& test pipeline remains verification" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T28: repo-local executable cannot impersonate a trusted read command\n'
setup_session "d28"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '#!/usr/bin/env bash\nprintf local-mutator > tracked.txt\n' > "${work}/cat"
chmod +x "${work}/cat"
git -C "${work}" add cat
git -C "${work}" commit --quiet -m local-cat
payload_t28="$(jq -nc --arg cwd "${work}" '{
  session_id:"d28",tool_name:"Bash",tool_use_id:"tu-local-cat",cwd:$cwd,
  tool_input:{command:"./cat tracked.txt"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t28}" >/dev/null
(cd "${work}" && ./cat tracked.txt)
run_dispatch "${payload_t28}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d28/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T28: local cat mutator advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T29: git inspection output option is treated as a write\n'
setup_session "d29"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'report.patch\n' > "${work}/.gitignore"
git -C "${work}" add .gitignore
git -C "${work}" commit --quiet -m ignore-report
printf 'dirty\n' > "${work}/tracked.txt"
payload_t29="$(jq -nc --arg cwd "${work}" '{
  session_id:"d29",tool_name:"Bash",tool_use_id:"tu-git-output",cwd:$cwd,
  tool_input:{command:"git diff --output=report.patch"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t29}" >/dev/null
git -C "${work}" diff --output=report.patch
run_dispatch "${payload_t29}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d29/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T29: ignored git --output target advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T30: expected git add/commit delivery transitions do not reopen review\n'
setup_session "d30"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'reviewed bytes\n' > "${work}/tracked.txt"
payload_t30="$(jq -nc --arg cwd "${work}" '{
  session_id:"d30",tool_name:"Bash",tool_use_id:"tu-add-commit",cwd:$cwd,
  tool_input:{command:"git add tracked.txt && git commit -m reviewed"},
  tool_response:"committed"
}')"
run_pretool "${payload_t30}" >/dev/null
git -C "${work}" add tracked.txt
git -C "${work}" commit --quiet -m reviewed
run_dispatch "${payload_t30}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d30/session_state.json"
assert_eq "T30: index/HEAD-only delivery leaves code clock empty" "" \
  "$(jq -r '.last_code_edit_ts // ""' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T31: intent-guard kill switch does not disable mutation observation\n'
setup_session "d31"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
payload_t31="$(jq -nc --arg cwd "${work}" '{
  session_id:"d31",tool_name:"Bash",tool_use_id:"tu-guard-off",cwd:$cwd,
  tool_input:{command:"printf changed > tracked.txt"},tool_response:{exit_code:0}
}')"
printf '%s' "${payload_t31}" | OMC_PRETOOL_INTENT_GUARD=false bash "${PRETOOL}" 2>/dev/null || true
printf 'changed\n' > "${work}/tracked.txt"
run_dispatch "${payload_t31}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d31/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T31: disabled denial policy still captures Bash baseline" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T32: snapshot fingerprints format-sensitive and repeated dirty states\n'
snapshot_of() {
  local repo="$1"
  OMC_SNAPSHOT_ROOT="${repo}" HOME="${ORIG_HOME}" bash -c '
    set -euo pipefail
    export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
    . "'"${COMMON}"'"
    _omc_git_worktree_snapshot "${OMC_SNAPSHOT_ROOT}"
  '
}
work="$(mktemp -d)"
init_git_worktree "${work}"
printf 'one\n' > "${work}/tracked.txt"
snap_a="$(snapshot_of "${work}")"
printf 'two\n' > "${work}/tracked.txt"
snap_b="$(snapshot_of "${work}")"
rc=0; [[ "${snap_a}" != "${snap_b}" ]] || rc=1
assert_true "T32: same-status repeated dirty edit changes snapshot" "${rc}"

git -C "${work}" reset --hard --quiet HEAD
printf 'space\n' > "${work}/space name.txt"
snap_space="$(snapshot_of "${work}")"
mv "${work}/space name.txt" "${work}/"$'line\nbreak.txt'
snap_newline="$(snapshot_of "${work}")"
rc=0; [[ "${snap_space}" != "${snap_newline}" ]] || rc=1
assert_true "T32: NUL-delimited untracked names remain distinct" "${rc}"

rm -f "${work}/"$'line\nbreak.txt'
printf 'rename-source\n' > "${work}/? fake"
git -C "${work}" add '? fake'
git -C "${work}" commit --quiet -m rename-source
git -C "${work}" mv '? fake' renamed.txt
snap_rename="$(snapshot_of "${work}")"
assert_contains "T32: type-2 rename produces a normalized exact tree" "exact:" "${snap_rename}"

git -C "${work}" commit --quiet -m renamed
ln -s first-target "${work}/tracked-link"
git -C "${work}" add tracked-link
git -C "${work}" commit --quiet -m symlink
rm "${work}/tracked-link"
ln -s second-target "${work}/tracked-link"
snap_link_a="$(snapshot_of "${work}")"
rm "${work}/tracked-link"
ln -s third-target "${work}/tracked-link"
snap_link_b="$(snapshot_of "${work}")"
rc=0; [[ "${snap_link_a}" != "${snap_link_b}" ]] || rc=1
assert_true "T32: repeated dangling-symlink edit changes snapshot" "${rc}"
rm -rf "${work}"

# ----------------------------------------------------------------------
printf 'T33: Git config override cannot smuggle an external mutator onto read-only skip\n'
setup_session "d33"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'sentinel-before\n' > "${work}/sentinel.txt"
printf '#!/usr/bin/env bash\nprintf external-mutator > sentinel.txt\n' > "${work}/external-diff.sh"
chmod +x "${work}/external-diff.sh"
git -C "${work}" add sentinel.txt external-diff.sh
git -C "${work}" commit --quiet -m external-diff-fixture
printf 'dirty\n' > "${work}/tracked.txt"
payload_t33="$(jq -nc --arg cwd "${work}" '{
  session_id:"d33",tool_name:"Bash",tool_use_id:"tu-external-diff",cwd:$cwd,
  tool_input:{command:"git -c diff.external=./external-diff.sh diff -- tracked.txt"},
  tool_response:{exit_code:0}
}')"
run_pretool "${payload_t33}" >/dev/null
(cd "${work}" && git -c diff.external=./external-diff.sh diff -- tracked.txt >/dev/null)
run_dispatch "${payload_t33}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d33/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T33: configured external diff mutation advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T34: Git fetch transport executor cannot bypass the snapshot path\n'
setup_session "d34"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'sentinel-before\n' > "${work}/sentinel.txt"
printf '#!/usr/bin/env bash\nprintf upload-mutator > sentinel.txt\nexec git upload-pack "$@"\n' > "${work}/upload-mutator.sh"
chmod +x "${work}/upload-mutator.sh"
git -C "${work}" add sentinel.txt upload-mutator.sh
git -C "${work}" commit --quiet -m upload-pack-fixture
payload_t34="$(jq -nc --arg cwd "${work}" '{
  session_id:"d34",tool_name:"Bash",tool_use_id:"tu-upload-pack",cwd:$cwd,
  tool_input:{command:"git fetch --upload-pack=./upload-mutator.sh ."},
  tool_response:{exit_code:0}
}')"
run_pretool "${payload_t34}" >/dev/null
(cd "${work}" && git fetch --upload-pack=./upload-mutator.sh . >/dev/null 2>&1)
run_dispatch "${payload_t34}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d34/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T34: custom upload-pack mutation advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T35: ambient Git executors cannot mutate behind a read-only skip\n'
setup_session "d35"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'sentinel-before\n' > "${work}/sentinel.txt"
printf '#!/usr/bin/env bash\nprintf ambient-diff > sentinel.txt\n' > "${work}/external-diff.sh"
chmod +x "${work}/external-diff.sh"
git -C "${work}" add sentinel.txt external-diff.sh
git -C "${work}" commit --quiet -m ambient-diff-fixture
printf 'dirty\n' > "${work}/tracked.txt"
git -C "${work}" config diff.external ./external-diff.sh
payload_t35="$(jq -nc --arg cwd "${work}" '{
  session_id:"d35",tool_name:"Bash",tool_use_id:"tu-ambient-diff",cwd:$cwd,
  tool_input:{command:"git diff -- tracked.txt"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t35}" >/dev/null
assert_eq "T35: inert before-snapshot does not execute diff.external" "sentinel-before" \
  "$(tr -d '\n' < "${work}/sentinel.txt")"
(cd "${work}" && git diff -- tracked.txt >/dev/null)
run_dispatch "${payload_t35}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d35/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T35: ambient external diff mutation advances code clock" "${rc}"
teardown_session

setup_session "d35b"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '#!/usr/bin/env bash\nprintf fsmonitor-mutated > tracked.txt\nprintf "\\n"\n' > "${work}/fsmon.sh"
chmod +x "${work}/fsmon.sh"
git -C "${work}" add fsmon.sh
git -C "${work}" commit --quiet -m fsmonitor-fixture
git -C "${work}" config core.fsmonitor ./fsmon.sh
payload_t35b="$(jq -nc --arg cwd "${work}" '{
  session_id:"d35b",tool_name:"Bash",tool_use_id:"tu-fsmonitor",cwd:$cwd,
  tool_input:{command:"git status --short"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t35b}" >/dev/null
assert_eq "T35: inert before-snapshot does not execute core.fsmonitor" "baseline" \
  "$(tr -d '\n' < "${work}/tracked.txt")"
(cd "${work}" && git status --short >/dev/null)
run_dispatch "${payload_t35b}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d35b/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T35: fsmonitor mutation advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T36: delivery hooks are observed without flagging ordinary commits\n'
setup_session "d36"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'reviewed\n' > "${work}/tracked.txt"
git -C "${work}" add tracked.txt
printf '#!/usr/bin/env bash\nprintf hook-mutated > tracked.txt\n' > "${work}/.git/hooks/pre-commit"
chmod +x "${work}/.git/hooks/pre-commit"
payload_t36="$(jq -nc --arg cwd "${work}" '{
  session_id:"d36",tool_name:"Bash",tool_use_id:"tu-hooked-commit",cwd:$cwd,
  tool_input:{command:"git commit -m reviewed"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t36}" >/dev/null
git -C "${work}" commit --quiet -m reviewed
run_dispatch "${payload_t36}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d36/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T36: pre-commit worktree rewrite advances code clock" "${rc}"
teardown_session

setup_session "d36b"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'reviewed\n' > "${work}/reviewed.txt"
git -C "${work}" add reviewed.txt
printf '#!/usr/bin/env bash\nprintf hook-staged > tracked.txt\ngit add tracked.txt\n' > "${work}/.git/hooks/pre-commit"
chmod +x "${work}/.git/hooks/pre-commit"
payload_t36b="$(jq -nc --arg cwd "${work}" '{
  session_id:"d36b",tool_name:"Bash",tool_use_id:"tu-hooked-staged-commit",cwd:$cwd,
  tool_input:{command:"git commit -m reviewed"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t36b}" >/dev/null
git -C "${work}" commit --quiet -m reviewed
run_dispatch "${payload_t36b}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d36b/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T36: hook-staged clean-path rewrite advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T37: oversized dirty snapshots fail closed before hashing bytes\n'
setup_session "d37"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf 'already-dirty\n' > "${work}/tracked.txt"
payload_t37="$(jq -nc --arg cwd "${work}" '{
  session_id:"d37",tool_name:"Bash",tool_use_id:"tu-capped",cwd:$cwd,
  tool_input:{command:"pytest -q"},tool_response:"1 passed"
}')"
printf '%s' "${payload_t37}" \
  | _OMC_BASH_SNAPSHOT_MAX_BYTES=1 bash "${PRETOOL}" 2>/dev/null || true
run_dispatch "${payload_t37}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d37/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T37: byte-cap overflow conservatively advances code clock" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf 'T38: PATH-shadowed bare reader cannot impersonate a trusted binary\n'
setup_session "d38"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '#!/usr/bin/env bash\nprintf shadow-mutated > tracked.txt\n' > "${work}/cat"
chmod +x "${work}/cat"
git -C "${work}" add cat
git -C "${work}" commit --quiet -m shadow-cat
payload_t38="$(jq -nc --arg cwd "${work}" '{
  session_id:"d38",tool_name:"Bash",tool_use_id:"tu-shadow-cat",cwd:$cwd,
  tool_input:{command:"cat tracked.txt"},tool_response:{exit_code:0}
}')"
printf '%s' "${payload_t38}" | PATH="${work}:${PATH}" bash "${PRETOOL}" 2>/dev/null || true
(cd "${work}" && "${work}/cat" tracked.txt)
run_dispatch "${payload_t38}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d38/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T38: PATH-shadowed reader mutation advances code clock" "${rc}"
teardown_session

setup_session "d38c"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
printf '#!/usr/bin/env bash\nprintf shadow-sink-mutated > tracked.txt\n' > "${work}/cat"
chmod +x "${work}/cat"
git -C "${work}" add cat
git -C "${work}" commit --quiet -m shadow-sink-cat
payload_t38c="$(jq -nc --arg cwd "${work}" '{
  session_id:"d38c",tool_name:"Bash",tool_use_id:"tu-shadow-sink-cat",cwd:$cwd,
  tool_input:{command:"cat tracked.txt > /dev/null"},tool_response:{exit_code:0}
}')"
printf '%s' "${payload_t38c}" | PATH="${work}:${PATH}" bash "${PRETOOL}" 2>/dev/null || true
(cd "${work}" && "${work}/cat" tracked.txt > /dev/null)
run_dispatch "${payload_t38c}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d38c/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T38: PATH-shadowed reader with dev-null sink advances code clock" "${rc}"
teardown_session

setup_session "d38b"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
mkdir -p "${work}/fake-bin"
printf '#!/usr/bin/env bash\nprintf observer-mutated > "%s/tracked.txt"\nexec /usr/bin/shasum "$@"\n' \
  "${work}" > "${work}/fake-bin/shasum"
printf '#!/usr/bin/env bash\nprintf observer-mutated > "%s/tracked.txt"\nexec /usr/bin/sed "$@"\n' \
  "${work}" > "${work}/fake-bin/sed"
chmod +x "${work}/fake-bin/shasum" "${work}/fake-bin/sed"
payload_t38b="$(jq -nc --arg cwd "${work}" '{
  session_id:"d38b",tool_name:"Bash",tool_use_id:"tu-path-observer",cwd:$cwd,
  tool_input:{command:"pytest -q"},tool_response:"1 passed"
}')"
printf '%s' "${payload_t38b}" | PATH="${work}/fake-bin:${PATH}" bash "${PRETOOL}" 2>/dev/null || true
assert_eq "T38: baseline observer ignores PATH-shadowed helpers" "baseline" \
  "$(tr -d '\n' < "${work}/tracked.txt")"
printf '%s' "${payload_t38b}" | PATH="${work}/fake-bin:${PATH}" bash "${DISPATCH}" 2>/dev/null || true
state="${TEST_HOME}/.claude/quality-pack/state/d38b/session_state.json"
assert_eq "T38: inert observer does not fabricate an edit" "" \
  "$(jq -r '.last_code_edit_ts // ""' "${state}")"
teardown_session

# ----------------------------------------------------------------------
printf 'T39: literal eval and xargs shell writes retain ignored-file fallback\n'
for executor_case in eval xargs python_kw python_expr python_env python_assign python_assign_quoted python_exec; do
  setup_session "d39-${executor_case}"
  work="${TEST_HOME}/repo"
  init_git_worktree "${work}"
  printf '.env\n' > "${work}/.gitignore"
  git -C "${work}" add .gitignore
  git -C "${work}" commit --quiet -m ignored-env
  if [[ "${executor_case}" == "eval" ]]; then
    command_t39="eval 'printf changed > .env'"
  elif [[ "${executor_case}" == "xargs" ]]; then
    command_t39="printf 'printf changed > .env' | xargs -I{} sh -c '{}'"
  elif [[ "${executor_case}" == "python_kw" ]]; then
    command_t39="python3 -c 'open(file=\".env\", mode=\"w\").write(\"changed\")'"
  elif [[ "${executor_case}" == "python_expr" ]]; then
    command_t39="python3 -c 'open(\".env\", mode=\"r\" if False else \"w\").write(\"changed\")'"
  elif [[ "${executor_case}" == "python_assign" ]]; then
    command_t39="PYTHONUTF8=1 python3 -c 'open(\".env\", mode=\"w\").write(\"changed\")'"
  elif [[ "${executor_case}" == "python_assign_quoted" ]]; then
    command_t39="FOO='a b' python3 -c 'open(\".env\", mode=\"w\").write(\"changed\")'"
  elif [[ "${executor_case}" == "python_exec" ]]; then
    command_t39="exec python3 -c 'open(\".env\", mode=\"w\").write(\"changed\")'"
  else
    command_t39="env python3 -c 'open(\".env\", mode=\"w\").write(\"changed\")'"
  fi
  payload_t39="$(jq -nc --arg sid "d39-${executor_case}" --arg cwd "${work}" --arg cmd "${command_t39}" '{
    session_id:$sid,tool_name:"Bash",tool_use_id:("tu-" + $sid),cwd:$cwd,
    tool_input:{command:$cmd},tool_response:{exit_code:0}
  }')"
  run_pretool "${payload_t39}" >/dev/null
  (cd "${work}" && eval "${command_t39}")
  run_dispatch "${payload_t39}" >/dev/null
  state="${TEST_HOME}/.claude/quality-pack/state/d39-${executor_case}/session_state.json"
  rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
  assert_true "T39: ${executor_case} ignored-file write advances code clock" "${rc}"
  teardown_session
done

# ----------------------------------------------------------------------
printf 'T40: materialized skip-worktree paths remain observable\n'
setup_session "d40"
work="${TEST_HOME}/repo"
init_git_worktree "${work}"
git -C "${work}" update-index --skip-worktree tracked.txt
payload_t40="$(jq -nc --arg cwd "${work}" '{
  session_id:"d40",tool_name:"Bash",tool_use_id:"tu-skip-worktree",cwd:$cwd,
  tool_input:{command:"./generate.sh"},tool_response:{exit_code:0}
}')"
run_pretool "${payload_t40}" >/dev/null
printf 'skip-worktree-mutated\n' > "${work}/tracked.txt"
run_dispatch "${payload_t40}" >/dev/null
state="${TEST_HOME}/.claude/quality-pack/state/d40/session_state.json"
rc=0; [[ -n "$(jq -r '.last_code_edit_ts // ""' "${state}")" ]] || rc=1
assert_true "T40: hidden index flag cannot suppress worktree mutation" "${rc}"
teardown_session

# ----------------------------------------------------------------------
printf '\n=== posttool-dispatch tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
