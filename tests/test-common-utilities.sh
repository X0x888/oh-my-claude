#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common.sh for utility functions
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

# Override STATE_ROOT for test isolation
TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="test-session"
ensure_session_dir

cleanup() {
  rm -rf "${TEST_STATE_ROOT}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_exit() {
  local label="$1"
  local expected_code="$2"
  shift 2
  local actual_code=0
  "$@" >/dev/null 2>&1 || actual_code=$?
  assert_eq "${label}" "${expected_code}" "${actual_code}"
}

# ===========================================================================
# normalize_task_prompt
# ===========================================================================
printf 'normalize_task_prompt:\n'

assert_eq "strip /ulw prefix" \
  "fix the bug" \
  "$(normalize_task_prompt "/ulw fix the bug")"

assert_eq "strip bare ulw" \
  "fix the bug" \
  "$(normalize_task_prompt "ulw fix the bug")"

assert_eq "strip /autowork prefix" \
  "implement feature" \
  "$(normalize_task_prompt "/autowork implement feature")"

assert_eq "strip /ultrawork prefix" \
  "refactor auth" \
  "$(normalize_task_prompt "/ultrawork refactor auth")"

assert_eq "strip /sisyphus prefix" \
  "deploy services" \
  "$(normalize_task_prompt "/sisyphus deploy services")"

assert_eq "strip ultrathink" \
  "analyze the code" \
  "$(normalize_task_prompt "ultrathink analyze the code")"

assert_eq "strip chained: /ulw ultrathink" \
  "do the work" \
  "$(normalize_task_prompt "/ulw ultrathink do the work")"

assert_eq "strip chained: ultrathink /ulw" \
  "do the work" \
  "$(normalize_task_prompt "ultrathink ulw do the work")"

assert_eq "case insensitive: /ULW" \
  "fix it" \
  "$(normalize_task_prompt "/ULW fix it")"

assert_eq "case insensitive: ULTRAWORK" \
  "build it" \
  "$(normalize_task_prompt "ULTRAWORK build it")"

assert_eq "passthrough: no prefix" \
  "just a normal prompt" \
  "$(normalize_task_prompt "just a normal prompt")"

assert_eq "passthrough: empty string" \
  "" \
  "$(normalize_task_prompt "")"

assert_eq "strip with leading whitespace" \
  "fix bug" \
  "$(normalize_task_prompt "  /ulw fix bug")"

# ===========================================================================
# truncate_chars
# ===========================================================================
printf 'truncate_chars:\n'

assert_eq "under limit: passthrough" \
  "hello" \
  "$(truncate_chars 10 "hello")"

assert_eq "at limit: passthrough" \
  "1234567890" \
  "$(truncate_chars 10 "1234567890")"

assert_eq "over limit: truncated with ellipsis" \
  "1234567890..." \
  "$(truncate_chars 10 "12345678901234")"

assert_eq "limit 0: just ellipsis" \
  "..." \
  "$(truncate_chars 0 "hello")"

assert_eq "empty string: passthrough" \
  "" \
  "$(truncate_chars 5 "")"

# ===========================================================================
# trim_whitespace
# ===========================================================================
printf 'trim_whitespace:\n'

assert_eq "trim leading spaces" \
  "hello" \
  "$(trim_whitespace "   hello")"

assert_eq "trim trailing spaces" \
  "hello" \
  "$(trim_whitespace "hello   ")"

assert_eq "trim both sides" \
  "hello world" \
  "$(trim_whitespace "  hello world  ")"

assert_eq "trim tabs and newlines" \
  "hello" \
  "$(trim_whitespace "$(printf '\t hello \t')")"

assert_eq "already trimmed: passthrough" \
  "hello" \
  "$(trim_whitespace "hello")"

assert_eq "empty string" \
  "" \
  "$(trim_whitespace "")"

assert_eq "whitespace only" \
  "" \
  "$(trim_whitespace "   ")"

# ===========================================================================
# is_internal_claude_path
# ===========================================================================
printf 'is_internal_claude_path:\n'

assert_exit "projects dir: internal" "0" \
  is_internal_claude_path "${HOME}/.claude/projects/foo/bar"

assert_exit "state dir: internal" "0" \
  is_internal_claude_path "${HOME}/.claude/quality-pack/state/abc123/session_state.json"

assert_exit "tasks dir: internal" "0" \
  is_internal_claude_path "${HOME}/.claude/tasks/some-task"

assert_exit "todos dir: internal" "0" \
  is_internal_claude_path "${HOME}/.claude/todos/list.json"

assert_exit "transcripts dir: internal" "0" \
  is_internal_claude_path "${HOME}/.claude/transcripts/log"

assert_exit "debug dir: internal" "0" \
  is_internal_claude_path "${HOME}/.claude/debug/trace"

assert_exit "user source file: external" "1" \
  is_internal_claude_path "/Users/dev/project/src/app.ts"

assert_exit "claude agents dir: external" "1" \
  is_internal_claude_path "${HOME}/.claude/agents/quality-reviewer.md"

assert_exit "claude skills dir: external" "1" \
  is_internal_claude_path "${HOME}/.claude/skills/autowork/SKILL.md"

assert_exit "empty path: external" "1" \
  is_internal_claude_path ""

# ===========================================================================
# is_maintenance_prompt
# ===========================================================================
printf 'is_maintenance_prompt:\n'

assert_exit "/compact: maintenance" "0" is_maintenance_prompt "/compact"
assert_exit "/clear: maintenance" "0" is_maintenance_prompt "/clear"
assert_exit "/resume: maintenance" "0" is_maintenance_prompt "/resume"
assert_exit "/memory: maintenance" "0" is_maintenance_prompt "/memory"
assert_exit "/hooks: maintenance" "0" is_maintenance_prompt "/hooks"
assert_exit "/config: maintenance" "0" is_maintenance_prompt "/config"
assert_exit "/help: maintenance" "0" is_maintenance_prompt "/help"
assert_exit "/permissions: maintenance" "0" is_maintenance_prompt "/permissions"
assert_exit "/model: maintenance" "0" is_maintenance_prompt "/model"
assert_exit "/doctor: maintenance" "0" is_maintenance_prompt "/doctor"
assert_exit "/status: maintenance" "0" is_maintenance_prompt "/status"
assert_exit "/compact with args: maintenance" "0" is_maintenance_prompt "/compact now"
assert_exit "  /model with leading space" "0" is_maintenance_prompt "  /model opus"
assert_exit "fix the bug: not maintenance" "1" is_maintenance_prompt "fix the bug"
assert_exit "/ulw: not maintenance" "1" is_maintenance_prompt "/ulw do work"
assert_exit "empty: not maintenance" "1" is_maintenance_prompt ""
assert_exit "compact without slash: not maintenance" "1" is_maintenance_prompt "compact the context"

# ===========================================================================
# has_unfinished_session_handoff
# ===========================================================================
printf 'has_unfinished_session_handoff:\n'

assert_exit "ready for a new session" "0" \
  has_unfinished_session_handoff "I'm ready for a new session to continue."

assert_exit "next wave" "0" \
  has_unfinished_session_handoff "That completes wave 1. The next wave will handle auth."

assert_exit "next phase" "0" \
  has_unfinished_session_handoff "Moving to the next phase in a follow-up."

assert_exit "continue later" "0" \
  has_unfinished_session_handoff "We can continue this later."

assert_exit "remaining work" "0" \
  has_unfinished_session_handoff "The remaining work covers testing."

assert_exit "clean completion: no match" "1" \
  has_unfinished_session_handoff "All tasks complete. Tests passing."

assert_exit "normal discussion: no match" "1" \
  has_unfinished_session_handoff "The implementation looks good."

# ===========================================================================
# is_execution_intent_value
# ===========================================================================
printf 'is_execution_intent_value:\n'

assert_exit "execution: yes" "0" is_execution_intent_value "execution"
assert_exit "continuation: yes" "0" is_execution_intent_value "continuation"
assert_exit "advisory: no" "1" is_execution_intent_value "advisory"
assert_exit "checkpoint: no" "1" is_execution_intent_value "checkpoint"
assert_exit "session_management: no" "1" is_execution_intent_value "session_management"
assert_exit "empty: no" "1" is_execution_intent_value ""

# ===========================================================================
# is_checkpoint_request
# ===========================================================================
printf 'is_checkpoint_request:\n'

assert_exit "checkpoint" "0" is_checkpoint_request "checkpoint"
assert_exit "pause here" "0" is_checkpoint_request "please pause here"
assert_exit "stop here" "0" is_checkpoint_request "stop here for now"
assert_exit "wave 1 only" "0" is_checkpoint_request "wave 1 only"
assert_exit "first phase only" "0" is_checkpoint_request "first phase only"
assert_exit "for now" "0" is_checkpoint_request "that's enough for now"
assert_exit "normal prompt: no" "1" is_checkpoint_request "implement the auth system"

# ===========================================================================
# is_session_management_request
# ===========================================================================
printf 'is_session_management_request:\n'

assert_exit "should I start a new session?" "0" \
  is_session_management_request "should I start a new session?"

assert_exit "is the context budget okay?" "0" \
  is_session_management_request "is the context budget okay?"

assert_exit "would it be better to continue in this session?" "0" \
  is_session_management_request "would it be better to continue in this session?"

assert_exit "imperative about sessions: no" "1" \
  is_session_management_request "start a new session"

assert_exit "normal question: no" "1" \
  is_session_management_request "should we use React?"

# ===========================================================================
# is_advisory_request
# ===========================================================================
printf 'is_advisory_request:\n'

assert_exit "should we use React?" "0" \
  is_advisory_request "should we use React for this?"

assert_exit "what do you think about..." "0" \
  is_advisory_request "what do you think about the architecture?"

assert_exit "pros and cons" "0" \
  is_advisory_request "what are the pros and cons of this approach?"

assert_exit "question mark" "0" \
  is_advisory_request "is this the right approach?"

assert_exit "recommend" "0" \
  is_advisory_request "what would you recommend?"

assert_exit "bare imperative: no" "1" \
  is_advisory_request "fix the authentication bug"

# ===========================================================================
# load_conf — configurable thresholds
# ===========================================================================
printf 'load_conf:\n'

# Test 1: defaults when no conf file exists
_omc_conf_loaded=0
OMC_STALL_THRESHOLD=12
OMC_EXCELLENCE_FILE_COUNT=3
OMC_STATE_TTL_DAYS=7
load_conf
assert_eq "default stall_threshold" "12" "${OMC_STALL_THRESHOLD}"
assert_eq "default excellence_file_count" "3" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "default state_ttl_days" "7" "${OMC_STATE_TTL_DAYS}"

# Test 2: conf file overrides specific values
FAKE_HOME_DIR="$(mktemp -d)"
conf_file="${FAKE_HOME_DIR}/.claude/oh-my-claude.conf"
mkdir -p "${FAKE_HOME_DIR}/.claude"
cat > "${conf_file}" <<'CONF'
# Test configuration
model_tier=balanced
stall_threshold=20
excellence_file_count=5
state_ttl_days=14
hook_debug=true
CONF

# Reset loader state, sentinels, and HOME, then reload
_omc_conf_loaded=0
_omc_env_stall=""
_omc_env_excellence=""
_omc_env_ttl=""
OMC_STALL_THRESHOLD=12
OMC_EXCELLENCE_FILE_COUNT=3
OMC_STATE_TTL_DAYS=7
OLD_HOME="${HOME}"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"

assert_eq "conf stall_threshold=20" "20" "${OMC_STALL_THRESHOLD}"
assert_eq "conf excellence_file_count=5" "5" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "conf state_ttl_days=14" "14" "${OMC_STATE_TTL_DAYS}"

# Test 3: partial conf only overrides specified keys
_omc_conf_loaded=0
_omc_env_stall=""
_omc_env_excellence=""
_omc_env_ttl=""
OMC_STALL_THRESHOLD=12
OMC_EXCELLENCE_FILE_COUNT=3
OMC_STATE_TTL_DAYS=7
cat > "${conf_file}" <<'CONF'
stall_threshold=8
CONF
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"

assert_eq "partial conf stall_threshold=8" "8" "${OMC_STALL_THRESHOLD}"
assert_eq "partial conf excellence_file_count unchanged" "3" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "partial conf state_ttl_days unchanged" "7" "${OMC_STATE_TTL_DAYS}"

# Test 4: env var overrides take precedence over defaults (no conf)
_omc_conf_loaded=0
rm -f "${conf_file}"
OMC_STALL_THRESHOLD=25
OMC_EXCELLENCE_FILE_COUNT=10
OMC_STATE_TTL_DAYS=30
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"

assert_eq "env override stall_threshold" "25" "${OMC_STALL_THRESHOLD}"
assert_eq "env override excellence_file_count" "10" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "env override state_ttl_days" "30" "${OMC_STATE_TTL_DAYS}"

# Test 5: env var wins over conf file (env > conf > default)
cat > "${conf_file}" <<'CONF'
stall_threshold=99
excellence_file_count=99
state_ttl_days=99
CONF
_omc_conf_loaded=0
_omc_env_stall="25"
_omc_env_excellence="10"
_omc_env_ttl="30"
OMC_STALL_THRESHOLD=25
OMC_EXCELLENCE_FILE_COUNT=10
OMC_STATE_TTL_DAYS=30
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"

assert_eq "env beats conf stall_threshold" "25" "${OMC_STALL_THRESHOLD}"
assert_eq "env beats conf excellence_file_count" "10" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "env beats conf state_ttl_days" "30" "${OMC_STATE_TTL_DAYS}"

# Test 6: non-numeric and zero conf values are ignored
cat > "${conf_file}" <<'CONF'
stall_threshold=high
excellence_file_count=0
state_ttl_days=-5
CONF
_omc_conf_loaded=0
_omc_env_stall=""
_omc_env_excellence=""
_omc_env_ttl=""
OMC_STALL_THRESHOLD=12
OMC_EXCELLENCE_FILE_COUNT=3
OMC_STATE_TTL_DAYS=7
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"

assert_eq "non-numeric stall_threshold ignored" "12" "${OMC_STALL_THRESHOLD}"
assert_eq "zero excellence_file_count ignored" "3" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "negative state_ttl_days ignored" "7" "${OMC_STATE_TTL_DAYS}"

rm -rf "${FAKE_HOME_DIR}"

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
