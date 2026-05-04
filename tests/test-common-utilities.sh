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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain=%s\n    actual=%s\n' "${label}" "${needle}" "${haystack}" >&2
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

# v1.27.0 (F-009): "continue later" and "remaining work" deliberately
# DROPPED from has_unfinished_session_handoff because they match
# legitimate scoping language ("implementing the rest now",
# "remaining work tracked in F-042"). The retained patterns explicitly
# encode session-boundary handoff: new session, another session, next
# wave, next phase, wave/phase N is next.
assert_exit "continue later — no longer matches (v1.27.0)" "1" \
  has_unfinished_session_handoff "We can continue this later."

assert_exit "remaining work — no longer matches (v1.27.0)" "1" \
  has_unfinished_session_handoff "The remaining work covers testing."

assert_exit "another session: matches" "0" \
  has_unfinished_session_handoff "We can pick this up in another session."

assert_exit "wave N is next: matches" "0" \
  has_unfinished_session_handoff "Wave 3 is next; ready to continue when you are."

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

# Test 6: council_deep_default flag (off by default, on/off accepted, env wins)
# The load_conf walk-up from $PWD can find the REAL user conf (e.g.,
# ~/.claude/oh-my-claude.conf) even when HOME is faked. Isolate by
# cd'ing to the fake HOME dir during these tests so the walk-up starts
# from a path with no .claude/oh-my-claude.conf in its ancestry.
OLD_PWD_CONF="${PWD}"
cd "${FAKE_HOME_DIR}"

_omc_conf_loaded=0
_omc_env_council_deep_default=""
OMC_COUNCIL_DEEP_DEFAULT="off"
rm -f "${conf_file}"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "council_deep_default default off" "off" "${OMC_COUNCIL_DEEP_DEFAULT}"

cat > "${conf_file}" <<'CONF'
council_deep_default=on
CONF
_omc_conf_loaded=0
_omc_env_council_deep_default=""
OMC_COUNCIL_DEEP_DEFAULT="off"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "council_deep_default conf=on" "on" "${OMC_COUNCIL_DEEP_DEFAULT}"

# Invalid value rejected
cat > "${conf_file}" <<'CONF'
council_deep_default=yes
CONF
_omc_conf_loaded=0
_omc_env_council_deep_default=""
OMC_COUNCIL_DEEP_DEFAULT="off"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "council_deep_default invalid=yes rejected" "off" "${OMC_COUNCIL_DEEP_DEFAULT}"

# Env beats conf
cat > "${conf_file}" <<'CONF'
council_deep_default=on
CONF
_omc_conf_loaded=0
_omc_env_council_deep_default="off"
OMC_COUNCIL_DEEP_DEFAULT="off"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "env council_deep_default beats conf" "off" "${OMC_COUNCIL_DEEP_DEFAULT}"

# Test 6b: auto_memory flag (on by default, on/off accepted, env wins)
# Same isolation pattern as council_deep_default — fake HOME so the
# walk-up doesn't hit the real user conf.
_omc_conf_loaded=0
_omc_env_auto_memory=""
OMC_AUTO_MEMORY="on"
rm -f "${conf_file}"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "auto_memory default on" "on" "${OMC_AUTO_MEMORY}"
assert_eq "is_auto_memory_enabled true at default" "0" "$(is_auto_memory_enabled && echo 0 || echo 1)"

cat > "${conf_file}" <<'CONF'
auto_memory=off
CONF
_omc_conf_loaded=0
_omc_env_auto_memory=""
OMC_AUTO_MEMORY="on"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "auto_memory conf=off" "off" "${OMC_AUTO_MEMORY}"
assert_eq "is_auto_memory_enabled false when off" "1" "$(is_auto_memory_enabled && echo 0 || echo 1)"

# Invalid value rejected (default preserved)
cat > "${conf_file}" <<'CONF'
auto_memory=disabled
CONF
_omc_conf_loaded=0
_omc_env_auto_memory=""
OMC_AUTO_MEMORY="on"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "auto_memory invalid=disabled rejected" "on" "${OMC_AUTO_MEMORY}"

# Env beats conf
cat > "${conf_file}" <<'CONF'
auto_memory=off
CONF
_omc_conf_loaded=0
_omc_env_auto_memory="on"
OMC_AUTO_MEMORY="on"
HOME="${FAKE_HOME_DIR}"
load_conf
HOME="${OLD_HOME}"
assert_eq "env auto_memory beats conf" "on" "${OMC_AUTO_MEMORY}"

cd "${OLD_PWD_CONF}"

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
# is_doc_path
# ===========================================================================
printf '\nis_doc_path:\n'

assert_doc() {
  local path="$1"
  if is_doc_path "${path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: expected doc: %s\n' "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_doc() {
  local path="$1"
  if is_doc_path "${path}"; then
    printf '  FAIL: expected NOT doc: %s\n' "${path}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# Extensions
assert_doc "/path/to/README.md"
assert_doc "/path/to/file.markdown"
assert_doc "/path/to/guide.mdx"
assert_doc "/path/to/notes.rst"
assert_doc "/path/to/spec.adoc"
assert_doc "/path/to/plain.txt"

# Well-known basenames (case insensitive)
assert_doc "CHANGELOG"
assert_doc "changelog"
assert_doc "CHANGELOG.txt"
assert_doc "README"
assert_doc "readme"
assert_doc "RELEASE"
assert_doc "release.md"
assert_doc "CONTRIBUTING"
assert_doc "LICENSE"
assert_doc "NOTICE"
assert_doc "COPYING"
assert_doc "AUTHORS"

# Path-component docs/ and doc/
assert_doc "docs/architecture.md"
assert_doc "/repo/docs/guide.html"
assert_doc "doc/api.html"
assert_doc "/project/doc/notes"

# Negative cases
assert_not_doc "/src/foo.ts"
assert_not_doc "/src/docs-examples/foo.ts"  # substring not component
assert_not_doc "/bin/mydoc"                  # no extension, not known basename
assert_not_doc "bundle/dot-claude/skills/autowork/scripts/common.sh"
assert_not_doc "config/settings.patch.json"
assert_not_doc ""

# ===========================================================================
# is_ui_path
# ===========================================================================
printf '\nis_ui_path:\n'

assert_ui() {
  local path="$1"
  if is_ui_path "${path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: expected UI: %s\n' "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_ui() {
  local path="$1"
  if is_ui_path "${path}"; then
    printf '  FAIL: expected NOT UI: %s\n' "${path}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# Component files
assert_ui "/src/components/Button.tsx"
assert_ui "/src/pages/Home.jsx"
assert_ui "/src/App.vue"
assert_ui "/src/Counter.svelte"
assert_ui "/src/pages/index.astro"

# Stylesheets
assert_ui "/src/styles/main.css"
assert_ui "/src/styles/theme.scss"
assert_ui "/src/styles/vars.sass"
assert_ui "/src/styles/base.less"
assert_ui "/src/styles/mixins.styl"

# HTML
assert_ui "/public/index.html"
assert_ui "/templates/page.htm"

# Case insensitivity
assert_ui "/src/App.TSX"
assert_ui "/src/style.CSS"

# Double extensions (e.g., test files)
assert_ui "/src/Button.test.tsx"
assert_ui "/src/Button.stories.jsx"

# Negative cases
assert_not_ui "/src/utils.ts"
assert_not_ui "/src/server.js"
assert_not_ui "/config/webpack.config.js"
assert_not_ui "/package.json"
assert_not_ui "README.md"
assert_not_ui "/src/api/handler.py"
assert_not_ui ""
assert_not_ui "/src/styles/index.ts"  # TS is not UI even in styles dir

# ===========================================================================
# is_ui_request
# ===========================================================================
printf '\nis_ui_request:\n'

assert_ui_request() {
  local text="$1"
  if is_ui_request "${text}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: expected UI request: %s\n' "${text}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_ui_request() {
  local text="$1"
  if is_ui_request "${text}"; then
    printf '  FAIL: expected NOT UI request: %s\n' "${text}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# Common UI prompts
assert_ui_request "Create a login page for onboarding"
assert_ui_request "Build a pricing page for the marketing site"
assert_ui_request "Please style an empty state"
assert_ui_request "Can you design an onboarding screen?"
assert_ui_request "Build a responsive form"
assert_ui_request "Redesign our navbar"
assert_ui_request "Create a dashboard with charts and filters"
assert_ui_request "Add animation to the hero section"

# Negative cases
assert_not_ui_request "Implement the REST API form parser"
assert_not_ui_request "Add CSS loading to webpack"
assert_not_ui_request "Research responsive design principles"
assert_not_ui_request "Analyze dashboard adoption trends"
assert_not_ui_request "Write about animation in film"
assert_not_ui_request ""

# ===========================================================================
# Dimension helpers
# ===========================================================================
printf '\nDimension helpers:\n'

# reviewer_for_dimension
assert_eq "reviewer_for_dimension bug_hunt" "quality-reviewer" "$(reviewer_for_dimension bug_hunt)"
assert_eq "reviewer_for_dimension code_quality" "quality-reviewer" "$(reviewer_for_dimension code_quality)"
assert_eq "reviewer_for_dimension stress_test" "metis" "$(reviewer_for_dimension stress_test)"
assert_eq "reviewer_for_dimension prose" "editor-critic" "$(reviewer_for_dimension prose)"
assert_eq "reviewer_for_dimension completeness" "excellence-reviewer" "$(reviewer_for_dimension completeness)"
assert_eq "reviewer_for_dimension traceability" "briefing-analyst" "$(reviewer_for_dimension traceability)"
assert_eq "reviewer_for_dimension design_quality" "design-reviewer" "$(reviewer_for_dimension design_quality)"
assert_eq "reviewer_for_dimension unknown fallback" "quality-reviewer" "$(reviewer_for_dimension foo_bar)"

# _dim_key
assert_eq "_dim_key bug_hunt" "dim_bug_hunt_ts" "$(_dim_key bug_hunt)"
assert_eq "_dim_key traceability" "dim_traceability_ts" "$(_dim_key traceability)"

# Fresh session for tick/read tests
reset_dim_state() {
  rm -f "$(session_file "${STATE_JSON}")"
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
}

# tick_dimension stores value, is_dimension_valid reads it back
reset_dim_state
write_state "last_code_edit_ts" "1000"
tick_dimension "bug_hunt" "1500"
assert_eq "tick_dimension stores ts" "1500" "$(read_state "dim_bug_hunt_ts")"
if is_dimension_valid "bug_hunt"; then pass=$((pass + 1)); else
  printf '  FAIL: is_dimension_valid bug_hunt (1500 > 1000)\n' >&2
  fail=$((fail + 1))
fi

# After a later code edit, the tick becomes stale
write_state "last_code_edit_ts" "2000"
if is_dimension_valid "bug_hunt"; then
  printf '  FAIL: is_dimension_valid bug_hunt should be stale after edit\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# prose dimension keys off last_doc_edit_ts separately
reset_dim_state
write_state "last_doc_edit_ts" "1000"
write_state "last_code_edit_ts" "2000"  # code edit happened later
tick_dimension "prose" "1500"
if is_dimension_valid "prose"; then pass=$((pass + 1)); else
  printf '  FAIL: prose should be valid (1500 > last_doc_edit_ts 1000); code edit at 2000 does not invalidate prose\n' >&2
  fail=$((fail + 1))
fi

# code dimensions are still invalidated by the code edit at 2000
tick_dimension "code_quality" "1500"
if is_dimension_valid "code_quality"; then
  printf '  FAIL: code_quality should be stale (1500 < last_code_edit_ts 2000)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# missing_dimensions returns csv of invalid dims
reset_dim_state
write_state "last_code_edit_ts" "1000"
tick_dimension "bug_hunt" "1500"
tick_dimension "code_quality" "1500"
# stress_test and completeness are missing
missing="$(missing_dimensions "bug_hunt,code_quality,stress_test,completeness")"
assert_eq "missing_dimensions subset" "stress_test,completeness" "${missing}"

missing="$(missing_dimensions "bug_hunt,code_quality")"
assert_eq "missing_dimensions all ticked = empty" "" "${missing}"

missing="$(missing_dimensions "")"
assert_eq "missing_dimensions empty required = empty" "" "${missing}"

# get_required_dimensions honors thresholds
reset_dim_state
write_state "code_edit_count" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 1 file < threshold 3 = empty" "" "${dims}"

reset_dim_state
write_state "code_edit_count" "3"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 3 code files = full code set" "bug_hunt,code_quality,stress_test,completeness" "${dims}"

reset_dim_state
write_state "code_edit_count" "2"
write_state "doc_edit_count" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions code+doc = code set + prose" "bug_hunt,code_quality,stress_test,completeness,prose" "${dims}"

reset_dim_state
write_state "code_edit_count" "6"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 6 files = code set + traceability" "bug_hunt,code_quality,stress_test,completeness,traceability" "${dims}"

reset_dim_state
write_state "doc_edit_count" "3"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 3 docs only = prose + completeness" "prose,completeness" "${dims}"

# Legacy fallback: resumed session with counters cleared but log rehydrated.
# Must classify log contents, not just count them.
reset_dim_state
edited_log="$(session_file "edited_files.log")"
cat > "${edited_log}" <<'LOG'
/project/docs/a.md
/project/docs/b.md
/project/README.md
LOG
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions fallback: resumed doc-only" "prose,completeness" "${dims}"

reset_dim_state
cat > "${edited_log}" <<'LOG'
/project/src/a.ts
/project/src/b.ts
/project/src/c.ts
LOG
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions fallback: resumed code-only" "bug_hunt,code_quality,stress_test,completeness" "${dims}"

reset_dim_state
cat > "${edited_log}" <<'LOG'
/project/src/a.ts
/project/src/b.ts
/project/docs/c.md
LOG
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions fallback: resumed mixed" "bug_hunt,code_quality,stress_test,completeness,prose" "${dims}"

rm -f "${edited_log}"

# order_dimensions_by_risk respects project profile
ordered="$(order_dimensions_by_risk "traceability,design_quality,prose" "node,react,ui")"
assert_eq "order_dimensions_by_risk ui promotes design_quality" "design_quality,prose,traceability" "${ordered}"

ordered="$(order_dimensions_by_risk "traceability,design_quality,prose" "shell,docs")"
assert_eq "order_dimensions_by_risk non-ui leaves prose ahead of design" "prose,design_quality,traceability" "${ordered}"

# ===========================================================================
# Verification helpers
# ===========================================================================
printf '\nVerification helpers:\n'

assert_eq "detect_verification_method project test command" \
  "project_test_command" \
  "$(detect_verification_method "npm test -- --runInBand" "PASS auth\nTests: 10 passed" "npm test")"

assert_eq "detect_verification_method framework keyword" \
  "framework_keyword" \
  "$(detect_verification_method "pytest -q" "12 passed" "")"

assert_eq "detect_verification_method output signal" \
  "output_signal" \
  "$(detect_verification_method "./validate.sh" "test result: ok. 5 passed" "")"

assert_eq "score_verification_confidence all signals = 100" \
  "100" \
  "$(score_verification_confidence "npm test -- --runInBand" "PASS auth\nTests: 10 passed, 0 failed" "npm test")"

assert_eq "score_verification_confidence command keyword only = 30" \
  "30" \
  "$(score_verification_confidence "shellcheck script.sh" "" "")"

# ===========================================================================
# Quality scorecard
# ===========================================================================
printf '\nQuality scorecard:\n'

reset_dim_state
write_state "code_edit_count" "3"
write_state "last_code_edit_ts" "100"
write_state "last_review_ts" "120"
write_state "review_had_findings" "false"
write_state "last_verify_ts" "130"
write_state "last_verify_outcome" "passed"
write_state "last_verify_cmd" "npm test"
write_state "last_verify_confidence" "60"
with_state_lock_batch \
  "dim_code_quality_ts" "150" \
  "dim_code_quality_verdict" "CLEAN" \
  "dim_stress_test_ts" "90" \
  "dim_stress_test_verdict" "CLEAN" \
  "dim_bug_hunt_verdict" "FINDINGS"
scorecard="$(build_quality_scorecard)"
assert_contains "scorecard reports findings verdict" "bug hunt (correctness, regressions, edge cases): findings reported" "${scorecard}"
assert_contains "scorecard reports stale dimension" "stress-test (hidden assumptions, unsafe paths): stale after subsequent edits" "${scorecard}"
assert_contains "scorecard reports clean dimension" "code quality (conventions, dead code, comments)" "${scorecard}"
assert_contains "scorecard reports skipped dimension" "completeness (fresh-eyes holistic review): skipped" "${scorecard}"

# ===========================================================================
# Project profile detection
# ===========================================================================
printf '\nProject profile detection:\n'

profile_dir="$(mktemp -d)"
mkdir -p "${profile_dir}/src/components" "${profile_dir}/docs"
cat > "${profile_dir}/package.json" <<'JSON'
{"dependencies":{"react":"18.0.0"}}
JSON
touch "${profile_dir}/tsconfig.json"
assert_eq "detect_project_profile node/react/ui/docs" \
  "node,typescript,react,docs,ui" \
  "$(detect_project_profile "${profile_dir}")"
rm -rf "${profile_dir}"

# Regression: operator precedence — first alternative must trigger tag
profile_dir2="$(mktemp -d)"
touch "${profile_dir2}/Dockerfile"
assert_contains "detect_project_profile Dockerfile-only tags docker" \
  "docker" \
  "$(detect_project_profile "${profile_dir2}" 2>/dev/null)"
rm -rf "${profile_dir2}"

profile_dir3="$(mktemp -d)"
mkdir -p "${profile_dir3}/terraform"
assert_contains "detect_project_profile terraform-dir-only tags terraform" \
  "terraform" \
  "$(detect_project_profile "${profile_dir3}" 2>/dev/null)"
rm -rf "${profile_dir3}"

profile_dir4="$(mktemp -d)"
touch "${profile_dir4}/ansible.cfg"
assert_contains "detect_project_profile ansible.cfg-only tags ansible" \
  "ansible" \
  "$(detect_project_profile "${profile_dir4}" 2>/dev/null)"
rm -rf "${profile_dir4}"

profile_dir5="$(mktemp -d)"
touch "${profile_dir5}/docker-compose.yml"
assert_contains "detect_project_profile docker-compose.yml-only tags docker" \
  "docker" \
  "$(detect_project_profile "${profile_dir5}" 2>/dev/null)"
rm -rf "${profile_dir5}"

profile_dir6="$(mktemp -d)"
touch "${profile_dir6}/main.tf"
assert_contains "detect_project_profile main.tf-only tags terraform" \
  "terraform" \
  "$(detect_project_profile "${profile_dir6}" 2>/dev/null)"
rm -rf "${profile_dir6}"

profile_dir7="$(mktemp -d)"
mkdir -p "${profile_dir7}/playbooks"
assert_contains "detect_project_profile playbooks-dir-only tags ansible" \
  "ansible" \
  "$(detect_project_profile "${profile_dir7}" 2>/dev/null)"
rm -rf "${profile_dir7}"

# v1.18.0 — Swift target-platform subtype tagging. A bare Swift project
# (Package.swift / *.xcodeproj) emits the "swift" tag plus a "swift-ios"
# or "swift-macos" subtype based on imports in *.swift files. This is the
# load-bearing signal for infer_ui_platform's profile fallback so a
# macOS SwiftUI app does not default-route to web archetypes.
profile_dir_swift_macos="$(mktemp -d)"
touch "${profile_dir_swift_macos}/Package.swift"
mkdir -p "${profile_dir_swift_macos}/Sources/App"
cat > "${profile_dir_swift_macos}/Sources/App/main.swift" <<'SWIFT'
import AppKit
import SwiftUI

@main
struct MyMacApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
SWIFT
profile_swift_macos="$(detect_project_profile "${profile_dir_swift_macos}" 2>/dev/null)"
assert_contains "detect_project_profile macOS Swift app tags swift" \
  "swift" "${profile_swift_macos}"
assert_contains "detect_project_profile macOS Swift app tags swift-macos" \
  "swift-macos" "${profile_swift_macos}"
rm -rf "${profile_dir_swift_macos}"

profile_dir_swift_ios="$(mktemp -d)"
touch "${profile_dir_swift_ios}/Package.swift"
mkdir -p "${profile_dir_swift_ios}/Sources/App"
cat > "${profile_dir_swift_ios}/Sources/App/main.swift" <<'SWIFT'
import UIKit
import SwiftUI

@main
struct MyIOSApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
SWIFT
profile_swift_ios="$(detect_project_profile "${profile_dir_swift_ios}" 2>/dev/null)"
assert_contains "detect_project_profile iOS Swift app tags swift" \
  "swift" "${profile_swift_ios}"
assert_contains "detect_project_profile iOS Swift app tags swift-ios" \
  "swift-ios" "${profile_swift_ios}"
rm -rf "${profile_dir_swift_ios}"

# Pure-SwiftUI macOS project (no UIKit/AppKit imports, but uses MenuBarExtra)
profile_dir_swift_pure_macos="$(mktemp -d)"
touch "${profile_dir_swift_pure_macos}/Package.swift"
mkdir -p "${profile_dir_swift_pure_macos}/Sources/App"
cat > "${profile_dir_swift_pure_macos}/Sources/App/main.swift" <<'SWIFT'
import SwiftUI

@main
struct MenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("Tack", systemImage: "circle.fill") { ContentView() }
    }
}
SWIFT
profile_swift_pure_macos="$(detect_project_profile "${profile_dir_swift_pure_macos}" 2>/dev/null)"
assert_contains "detect_project_profile pure-SwiftUI macOS app tags swift-macos" \
  "swift-macos" "${profile_swift_pure_macos}"
rm -rf "${profile_dir_swift_pure_macos}"

# Bare Swift project (no source files yet) emits only "swift" — no subtype
profile_dir_swift_bare="$(mktemp -d)"
touch "${profile_dir_swift_bare}/Package.swift"
profile_swift_bare="$(detect_project_profile "${profile_dir_swift_bare}" 2>/dev/null)"
assert_contains "detect_project_profile bare Swift project tags swift" \
  "swift" "${profile_swift_bare}"
# A bare project should NOT have a swift-{ios,macos} tag — caller falls back
if [[ "${profile_swift_bare}" == *"swift-ios"* || "${profile_swift_bare}" == *"swift-macos"* ]]; then
  printf '  FAIL: bare Swift project unexpectedly emitted subtype tag (got %q)\n' \
    "${profile_swift_bare}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -rf "${profile_dir_swift_bare}"

# Multi-target Swift project (both AppKit and UIKit sources) tags as
# swift-macos. AppKit wins because the macOS routing block carries
# macOS-specific guidance and Catalyst-style patterns; iOS-only routing
# would lose those signals. Lock the precedence so a future refactor
# can't silently flip the ordering. (Quality-reviewer F2, v1.18.0.)
profile_dir_swift_multi="$(mktemp -d)"
touch "${profile_dir_swift_multi}/Package.swift"
mkdir -p "${profile_dir_swift_multi}/Sources/Mac" "${profile_dir_swift_multi}/Sources/iOS"
cat > "${profile_dir_swift_multi}/Sources/Mac/MacView.swift" <<'SWIFT'
import AppKit
class MacView: NSView {}
SWIFT
cat > "${profile_dir_swift_multi}/Sources/iOS/IOSView.swift" <<'SWIFT'
import UIKit
class IOSView: UIView {}
SWIFT
profile_swift_multi="$(detect_project_profile "${profile_dir_swift_multi}" 2>/dev/null)"
assert_contains "detect_project_profile multi-target Swift (AppKit+UIKit) tags swift-macos" \
  "swift-macos" "${profile_swift_multi}"
# Only one subtype tag should be emitted — never both swift-macos AND swift-ios
if [[ "${profile_swift_multi}" == *"swift-ios"* ]]; then
  printf '  FAIL: multi-target Swift project tagged BOTH swift-macos and swift-ios (got %q)\n' \
    "${profile_swift_multi}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -rf "${profile_dir_swift_multi}"

# Mac Catalyst — Info.plist with UIApplicationSupportsMacCatalyst routes
# to swift-macos despite UIKit imports. Catalyst ships on macOS even
# though its API surface is UIKit. (Serendipity fix during Wave 1 review.)
profile_dir_catalyst="$(mktemp -d)"
touch "${profile_dir_catalyst}/Package.swift"
mkdir -p "${profile_dir_catalyst}/Sources/App"
cat > "${profile_dir_catalyst}/Sources/App/AppDelegate.swift" <<'SWIFT'
import UIKit
class AppDelegate: UIResponder, UIApplicationDelegate {}
SWIFT
cat > "${profile_dir_catalyst}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>UIApplicationSupportsMacCatalyst</key>
    <true/>
</dict>
</plist>
PLIST
profile_catalyst="$(detect_project_profile "${profile_dir_catalyst}" 2>/dev/null)"
assert_contains "detect_project_profile Mac Catalyst (Info.plist) tags swift-macos despite UIKit" \
  "swift-macos" "${profile_catalyst}"
if [[ "${profile_catalyst}" == *"swift-ios"* ]]; then
  printf '  FAIL: Catalyst project tagged swift-ios (Info.plist override missed)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -rf "${profile_dir_catalyst}"

# Mac Catalyst — Package.swift with .macCatalyst platform routes to swift-macos
profile_dir_catalyst2="$(mktemp -d)"
cat > "${profile_dir_catalyst2}/Package.swift" <<'SWIFT'
// swift-tools-version:5.5
import PackageDescription
let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v15), .macCatalyst(.v15)],
    targets: [.executableTarget(name: "App", path: "Sources/App")]
)
SWIFT
mkdir -p "${profile_dir_catalyst2}/Sources/App"
cat > "${profile_dir_catalyst2}/Sources/App/main.swift" <<'SWIFT'
import UIKit
@main struct App {}
SWIFT
profile_catalyst2="$(detect_project_profile "${profile_dir_catalyst2}" 2>/dev/null)"
assert_contains "detect_project_profile Mac Catalyst (Package.swift) tags swift-macos" \
  "swift-macos" "${profile_catalyst2}"
rm -rf "${profile_dir_catalyst2}"

# ===========================================================================
# v1.18.0 — Project maturity classification
# ===========================================================================
printf '\nProject maturity classification (v1.18.0):\n'

# Helper: build a fake git repo with N synthetic commits.
_make_repo_with_commits() {
  local dir="$1" commits="$2"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email "test@example.com"
  git -C "${dir}" config user.name "Test"
  git -C "${dir}" config commit.gpgsign false
  local i
  for ((i = 0; i < commits; i++)); do
    printf 'commit %d\n' "${i}" > "${dir}/file.txt"
    git -C "${dir}" add file.txt
    git -C "${dir}" commit -q -m "commit ${i}" --no-verify --no-gpg-sign
  done
}

# Empty / non-git directory → unknown
maturity_dir_unknown="$(mktemp -d)"
maturity="$(classify_project_maturity "${maturity_dir_unknown}" 2>/dev/null)"
assert_eq "classify_project_maturity non-git → unknown" "unknown" "${maturity}"
rm -rf "${maturity_dir_unknown}"

# Tiny repo (1 commit) → prototype
maturity_dir_proto="$(mktemp -d)"
_make_repo_with_commits "${maturity_dir_proto}" 1
maturity="$(classify_project_maturity "${maturity_dir_proto}" 2>/dev/null)"
assert_eq "classify_project_maturity 1 commit → prototype" "prototype" "${maturity}"
rm -rf "${maturity_dir_proto}"

# Mid-range repo (40 commits) → shipping
maturity_dir_ship="$(mktemp -d)"
_make_repo_with_commits "${maturity_dir_ship}" 40
maturity="$(classify_project_maturity "${maturity_dir_ship}" 2>/dev/null)"
assert_eq "classify_project_maturity 40 commits → shipping" "shipping" "${maturity}"
rm -rf "${maturity_dir_ship}"

# Mature: 200+ commits + 100+ tests
maturity_dir_mature="$(mktemp -d)"
_make_repo_with_commits "${maturity_dir_mature}" 200
mkdir -p "${maturity_dir_mature}/tests"
for i in $(seq 1 105); do
  touch "${maturity_dir_mature}/tests/test-${i}.sh"
done
maturity="$(classify_project_maturity "${maturity_dir_mature}" 2>/dev/null)"
assert_eq "classify_project_maturity 200 commits + 105 tests → mature" "mature" "${maturity}"
rm -rf "${maturity_dir_mature}"

# Polish-saturated requires ALL of: 300 commits + 300 tests + 10 MEMORY.md
# lines. Test only the commits/tests dimensions here; the memory dimension
# is hard to fake without polluting ~/.claude/projects. Instead assert that
# 300 commits + 300 tests + no memory file → mature (NOT polish-saturated).
maturity_dir_almost="$(mktemp -d)"
_make_repo_with_commits "${maturity_dir_almost}" 300
mkdir -p "${maturity_dir_almost}/tests"
for i in $(seq 1 305); do
  touch "${maturity_dir_almost}/tests/test-${i}.sh"
done
maturity="$(classify_project_maturity "${maturity_dir_almost}" 2>/dev/null)"
assert_eq "classify_project_maturity 300/300/no-memory → mature (not polish-saturated)" \
  "mature" "${maturity}"
rm -rf "${maturity_dir_almost}"

# Outlier guard: 5 commits + 200 test files → still prototype, NOT mature.
# Combined-signal threshold prevents test-stub spam from inflating maturity.
maturity_dir_outlier="$(mktemp -d)"
_make_repo_with_commits "${maturity_dir_outlier}" 5
mkdir -p "${maturity_dir_outlier}/tests"
for i in $(seq 1 200); do
  touch "${maturity_dir_outlier}/tests/test-${i}.sh"
done
maturity="$(classify_project_maturity "${maturity_dir_outlier}" 2>/dev/null)"
assert_eq "classify_project_maturity 5 commits + 200 tests → prototype (outlier guard)" \
  "prototype" "${maturity}"
rm -rf "${maturity_dir_outlier}"

# Function symbol presence — both classify and cached wrapper must exist.
if declare -F classify_project_maturity >/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: classify_project_maturity not defined\n' >&2
  fail=$((fail + 1))
fi
if declare -F get_project_maturity >/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: get_project_maturity not defined\n' >&2
  fail=$((fail + 1))
fi

# Empty git repo (init but no commits) → unknown. Verifies that
# `git rev-list --count HEAD` returning non-zero (no HEAD ref yet) is
# silenced and falls through correctly. Reviewer F4.
maturity_dir_empty_git="$(mktemp -d)"
git -C "${maturity_dir_empty_git}" init -q 2>/dev/null
git -C "${maturity_dir_empty_git}" config commit.gpgsign false 2>/dev/null
maturity="$(classify_project_maturity "${maturity_dir_empty_git}" 2>/dev/null)"
assert_eq "classify_project_maturity empty git repo (no commits) → unknown" \
  "unknown" "${maturity}"
rm -rf "${maturity_dir_empty_git}"

# polish-saturated true-branch: 300 commits + 300 tests + 11 MEMORY.md
# lines. Stubs $HOME to a temp dir so we don't pollute the real
# ~/.claude/projects. Reviewer F3 — without this, the polish-saturated
# branch is reachable in code but never exercised in tests, so a
# regression in the threshold expression would stay green.
maturity_dir_polish="$(mktemp -d)"
_make_repo_with_commits "${maturity_dir_polish}" 300
mkdir -p "${maturity_dir_polish}/tests"
for i in $(seq 1 305); do
  touch "${maturity_dir_polish}/tests/test-${i}.sh"
done
maturity_fake_home="$(mktemp -d)"
maturity_encoded_cwd="$(printf '%s' "${maturity_dir_polish}" | tr '/' '-')"
mkdir -p "${maturity_fake_home}/.claude/projects/${maturity_encoded_cwd}/memory"
for i in $(seq 1 11); do
  printf -- '- entry %d\n' "${i}" >> \
    "${maturity_fake_home}/.claude/projects/${maturity_encoded_cwd}/memory/MEMORY.md"
done
maturity="$(HOME="${maturity_fake_home}" classify_project_maturity "${maturity_dir_polish}" 2>/dev/null)"
assert_eq "classify_project_maturity 300/300/11-mem → polish-saturated" \
  "polish-saturated" "${maturity}"
# Boundary: same project with only 9 MEMORY.md lines stays at mature
truncate -s 0 "${maturity_fake_home}/.claude/projects/${maturity_encoded_cwd}/memory/MEMORY.md"
for i in $(seq 1 9); do
  printf -- '- entry %d\n' "${i}" >> \
    "${maturity_fake_home}/.claude/projects/${maturity_encoded_cwd}/memory/MEMORY.md"
done
maturity="$(HOME="${maturity_fake_home}" classify_project_maturity "${maturity_dir_polish}" 2>/dev/null)"
assert_eq "classify_project_maturity 300/300/9-mem → mature (memory under threshold)" \
  "mature" "${maturity}"
rm -rf "${maturity_dir_polish}" "${maturity_fake_home}"

# ===========================================================================
# record_agent_metric and integer sanitization
# ===========================================================================
printf '\nrecord_agent_metric:\n'

_ORIG_METRICS_FILE="${_AGENT_METRICS_FILE}"
TEST_METRICS_DIR="$(mktemp -d)"
_AGENT_METRICS_FILE="${TEST_METRICS_DIR}/agent-metrics.json"
_AGENT_METRICS_LOCK="${TEST_METRICS_DIR}/.agent-metrics.lock"
printf '{}' > "${_AGENT_METRICS_FILE}"

# Basic recording
record_agent_metric "test-reviewer" "clean" 80
metric="$(cat "${_AGENT_METRICS_FILE}")"
assert_eq "record_agent_metric invocations" "1" "$(jq -r '.["test-reviewer"].invocations' <<<"${metric}")"
assert_eq "record_agent_metric clean_verdicts" "1" "$(jq -r '.["test-reviewer"].clean_verdicts' <<<"${metric}")"
assert_eq "record_agent_metric avg_confidence" "80" "$(jq -r '.["test-reviewer"].avg_confidence' <<<"${metric}")"

# Second recording with findings
record_agent_metric "test-reviewer" "findings" 60
metric="$(cat "${_AGENT_METRICS_FILE}")"
assert_eq "record_agent_metric second invocation" "2" "$(jq -r '.["test-reviewer"].invocations' <<<"${metric}")"
assert_eq "record_agent_metric finding_verdicts" "1" "$(jq -r '.["test-reviewer"].finding_verdicts' <<<"${metric}")"

# Regression: float/null values in existing metrics should not crash
printf '{"float-agent":{"invocations":3.7,"clean_verdicts":2.5,"finding_verdicts":1.2,"last_used_ts":100,"avg_confidence":4.5}}' > "${_AGENT_METRICS_FILE}"
record_agent_metric "float-agent" "clean" 50
metric="$(cat "${_AGENT_METRICS_FILE}")"
inv="$(jq -r '.["float-agent"].invocations' <<<"${metric}")"
assert_eq "record_agent_metric survives float values" "4" "${inv}"

rm -rf "${TEST_METRICS_DIR}"
_AGENT_METRICS_FILE="${_ORIG_METRICS_FILE}"

# ===========================================================================
# with_state_lock
# ===========================================================================
printf '\nwith_state_lock:\n'

# Basic acquire/release
noop() { return 0; }
if with_state_lock noop; then pass=$((pass + 1)); else
  printf '  FAIL: with_state_lock noop should succeed\n' >&2
  fail=$((fail + 1))
fi

# Lock dir is released after call
lockdir="$(session_file ".state.lock")"
if [[ ! -d "${lockdir}" ]]; then pass=$((pass + 1)); else
  printf '  FAIL: lockdir should be released after call\n' >&2
  fail=$((fail + 1))
fi

# Wrapped function's exit code propagates
returns_seven() { return 7; }
rc=0
with_state_lock returns_seven || rc=$?
assert_eq "with_state_lock propagates non-zero exit" "7" "${rc}"

# Stale-lock recovery: pre-create the lock dir with an old mtime
mkdir -p "${lockdir}"
# Touch to ~10 seconds ago
past_ts=$(( $(date +%s) - 10 ))
touch -t "$(date -r "${past_ts}" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@${past_ts}" +%Y%m%d%H%M.%S 2>/dev/null)" "${lockdir}" 2>/dev/null || true
# with_state_lock should force-release and succeed
if with_state_lock noop; then pass=$((pass + 1)); else
  printf '  FAIL: with_state_lock should recover from stale lock\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# validate_session_id
# ===========================================================================
printf '\nvalidate_session_id:\n'

assert_exit "accept UUID" 0 validate_session_id "01234567-89ab-cdef-0123-456789abcdef"
assert_exit "accept short id" 0 validate_session_id "sh"
assert_exit "accept single char" 0 validate_session_id "a"
assert_exit "accept alphanumeric" 0 validate_session_id "test-session-123"
assert_exit "accept underscores" 0 validate_session_id "test_session_123"
assert_exit "accept dots" 0 validate_session_id "test.session"
assert_exit "reject empty" 1 validate_session_id ""
assert_exit "reject slash" 1 validate_session_id "../../etc/passwd"
assert_exit "reject dot-dot" 1 validate_session_id "foo..bar"
assert_exit "reject spaces" 1 validate_session_id "foo bar"
assert_exit "reject newlines" 1 validate_session_id "foo
bar"
assert_exit "reject backtick" 1 validate_session_id 'foo`id`'
assert_exit "reject dollar" 1 validate_session_id 'foo$HOME'

# ===========================================================================
# _ensure_valid_state (state corruption recovery)
# ===========================================================================
printf '\n_ensure_valid_state:\n'

# Set up a fresh session for corruption tests
_corruption_sid="corruption-test"
_orig_sid="${SESSION_ID}"
SESSION_ID="${_corruption_sid}"
ensure_session_dir

# Test 1: missing state file gets created
_state_validated=0  # reset per-process cache for test isolation
rm -f "$(session_file "${STATE_JSON}")"
_ensure_valid_state
_state_file="$(session_file "${STATE_JSON}")"
assert_eq "creates missing state file" "true" "$(if [[ -f "${_state_file}" ]]; then echo true; else echo false; fi)"
assert_eq "created file is valid JSON" "0" "$(jq empty "${_state_file}" 2>/dev/null && echo 0 || echo 1)"

# Test 2: corrupt state gets archived and reset
_state_validated=0  # reset per-process cache for test isolation
printf 'NOT VALID JSON{{{' > "${_state_file}"
_ensure_valid_state
assert_eq "corrupt state recovered to valid JSON" "0" "$(jq empty "${_state_file}" 2>/dev/null && echo 0 || echo 1)"
_archive_count="$(ls "$(session_file "")"session_state.json.corrupt.* 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "corrupt file was archived" "true" "$(if [[ "${_archive_count}" -gt 0 ]]; then echo true; else echo false; fi)"

# Test 3: valid state file is left alone
_state_validated=0  # reset per-process cache for test isolation
write_state "test_key" "test_value"
_state_validated=0  # reset again to force re-validation
_ensure_valid_state
assert_eq "valid state preserved" "test_value" "$(read_state "test_key")"

SESSION_ID="${_orig_sid}"

# ===========================================================================
# classify_finding_category
# ===========================================================================
printf '\nclassify_finding_category:\n'

assert_eq "race condition" \
  "race_condition" \
  "$(classify_finding_category "potential race condition in concurrent map access")"

assert_eq "deadlock" \
  "race_condition" \
  "$(classify_finding_category "possible deadlock between lock A and lock B")"

assert_eq "missing test" \
  "missing_test" \
  "$(classify_finding_category "no unit tests for the new parser module")"

assert_eq "test coverage" \
  "missing_test" \
  "$(classify_finding_category "coverage is below threshold for utils.ts")"

assert_eq "type error" \
  "type_error" \
  "$(classify_finding_category "TypeScript type error: cannot assign string to number")"

assert_eq "null check" \
  "null_check" \
  "$(classify_finding_category "optional chaining not used — response.data could be undefined")"

assert_eq "edge case" \
  "edge_case" \
  "$(classify_finding_category "boundary check: off-by-one in array indexing")"

assert_eq "API contract" \
  "api_contract" \
  "$(classify_finding_category "API endpoint returns wrong payload schema")"

assert_eq "error handling" \
  "error_handling" \
  "$(classify_finding_category "uncaught exception in the promise chain")"

assert_eq "security" \
  "security" \
  "$(classify_finding_category "user input not sanitized before SQL query")"

assert_eq "performance" \
  "performance" \
  "$(classify_finding_category "O(n^2) loop causes slow rendering on large datasets")"

assert_eq "design issues" \
  "design_issues" \
  "$(classify_finding_category "generic gradient background with default color palette")"

assert_eq "design visual" \
  "design_issues" \
  "$(classify_finding_category "visual design lacks typography hierarchy")"

assert_eq "design aesthetic" \
  "design_issues" \
  "$(classify_finding_category "cookie-cutter aesthetic with default spacing")"

assert_eq "database design: not design_issues" \
  "unknown" \
  "$(classify_finding_category "the database design needs a migration")"

# Design-reviewer rubric phrases (from design-reviewer.md anti-patterns)
assert_eq "rubric: feature cards symmetrical row" \
  "design_issues" \
  "$(classify_finding_category "three feature cards in a symmetrical row")"

assert_eq "rubric: no typographic treatment" \
  "design_issues" \
  "$(classify_finding_category "Inter with no typographic treatment")"

assert_eq "rubric: uniform section padding" \
  "design_issues" \
  "$(classify_finding_category "uniform section padding with identical spacing")"

assert_eq "rubric: no visual signature" \
  "design_issues" \
  "$(classify_finding_category "no distinctive visual signature in the design")"

assert_eq "rubric: perfectly symmetrical NOT performance" \
  "design_issues" \
  "$(classify_finding_category "perfectly symmetrical layouts with no visual tension")"

assert_eq "rubric: stock illustration" \
  "design_issues" \
  "$(classify_finding_category "stock-illustration-style decorative elements")"

assert_eq "rubric: framework default colors" \
  "design_issues" \
  "$(classify_finding_category "framework default colors with no customization")"

assert_eq "rubric: hero with CTA" \
  "design_issues" \
  "$(classify_finding_category "centered hero section with CTA button over gradient")"

assert_eq "rubric: templated look" \
  "design_issues" \
  "$(classify_finding_category "the whole page reads as templated")"

assert_eq "go template: not design_issues" \
  "unknown" \
  "$(classify_finding_category "use a Go template for rendering")"

assert_eq "django template: not design_issues" \
  "unknown" \
  "$(classify_finding_category "django template tag is broken")"

# Performance false-positive guard
assert_eq "performance: real perf issue" \
  "performance" \
  "$(classify_finding_category "perf regression in hot path")"

assert_eq "performance: performance word" \
  "performance" \
  "$(classify_finding_category "performance degradation after migration")"

assert_eq "docs stale" \
  "docs_stale" \
  "$(classify_finding_category "README is outdated and references removed functions")"

assert_eq "style" \
  "style" \
  "$(classify_finding_category "inconsistent naming convention: camelCase vs snake_case")"

assert_eq "accessibility aria" \
  "accessibility" \
  "$(classify_finding_category "missing aria labels on interactive buttons")"

assert_eq "accessibility wcag" \
  "accessibility" \
  "$(classify_finding_category "low contrast ratio does not meet wcag AA")"

assert_eq "unknown fallback" \
  "unknown" \
  "$(classify_finding_category "something completely unrelated to any category")"

assert_eq "empty input" \
  "unknown" \
  "$(classify_finding_category "")"

# ===========================================================================
# is_ui_path
# ===========================================================================
printf '\nis_ui_path:\n'

assert_exit "tsx file" "0" is_ui_path "/src/components/Button.tsx"
assert_exit "jsx file" "0" is_ui_path "/src/App.jsx"
assert_exit "vue file" "0" is_ui_path "/components/Header.vue"
assert_exit "svelte file" "0" is_ui_path "/routes/Page.svelte"
assert_exit "css file" "0" is_ui_path "/styles/main.css"
assert_exit "scss file" "0" is_ui_path "/styles/theme.scss"
assert_exit "html file" "0" is_ui_path "/public/index.html"
assert_exit "astro file" "0" is_ui_path "/pages/index.astro"
assert_exit "ts file: not UI" "1" is_ui_path "/src/utils/parser.ts"
assert_exit "py file: not UI" "1" is_ui_path "/server/app.py"
assert_exit "go file: not UI" "1" is_ui_path "/cmd/main.go"
assert_exit "json file: not UI" "1" is_ui_path "/config/settings.json"
assert_exit "sh file: not UI" "1" is_ui_path "/scripts/build.sh"
assert_exit "empty: not UI" "1" is_ui_path ""

# ===========================================================================
# is_ui_request
# ===========================================================================
printf '\nis_ui_request:\n'

assert_exit "build a login form" "0" is_ui_request "build a login form"
assert_exit "create a dashboard page" "0" is_ui_request "create a dashboard page"
assert_exit "add a modal component" "0" is_ui_request "add a modal component"
assert_exit "style the navigation bar" "0" is_ui_request "style the navigation bar"
assert_exit "implement a dropdown menu" "0" is_ui_request "implement a dropdown menu"
assert_exit "add animation to the cards" "0" is_ui_request "add animation to the cards"
assert_exit "add an animation to the card" "0" is_ui_request "add an animation to the card"
assert_exit "fix the CSS layout" "0" is_ui_request "fix the CSS layout"
assert_exit "backend API: not UI" "1" is_ui_request "implement the REST API endpoint"
assert_exit "database query: not UI" "1" is_ui_request "optimize the database query"
assert_exit "fix the auth middleware: not UI" "1" is_ui_request "fix the auth middleware"

# ===========================================================================
# record_defect_pattern and get_defect_watch_list
# ===========================================================================
printf '\nrecord_defect_pattern / get_defect_watch_list:\n'

# Use an isolated defect patterns file for testing
_ORIG_DEFECT_FILE="${_DEFECT_PATTERNS_FILE}"
_ORIG_DEFECT_LOCK="${_DEFECT_PATTERNS_LOCK}"
TEST_DEFECT_DIR="$(mktemp -d)"
_DEFECT_PATTERNS_FILE="${TEST_DEFECT_DIR}/defect-patterns.json"
_DEFECT_PATTERNS_LOCK="${TEST_DEFECT_DIR}/.defect-patterns.lock"

# Test 1: recording creates the file and stores category
record_defect_pattern "missing_test" "no tests for parser"
assert_exit "defect file created" "0" test -f "${_DEFECT_PATTERNS_FILE}"

count="$(jq -r '.missing_test.count' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "missing_test count=1" "1" "${count}"

example="$(jq -r '.missing_test.examples[0]' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "missing_test example stored" "no tests for parser" "${example}"

# Test 2: recording increments count and appends examples
record_defect_pattern "missing_test" "no coverage for auth module"
count="$(jq -r '.missing_test.count' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "missing_test count=2" "2" "${count}"

num_examples="$(jq -r '.missing_test.examples | length' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "missing_test 2 examples" "2" "${num_examples}"

# Test 3: different categories are tracked independently
record_defect_pattern "null_check" "optional chaining missing"
record_defect_pattern "null_check" "null dereference in handler"
record_defect_pattern "null_check" "undefined access on response"

mt_count="$(jq -r '.missing_test.count' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
nc_count="$(jq -r '.null_check.count' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "missing_test still 2" "2" "${mt_count}"
assert_eq "null_check count=3" "3" "${nc_count}"

# Test 4: get_defect_watch_list returns formatted output
watch="$(get_defect_watch_list 2)"
assert_contains "watch list has null_check" "null_check" "${watch}"
assert_contains "watch list has missing_test" "missing_test" "${watch}"
assert_contains "watch list starts with Watch for:" "Watch for:" "${watch}"
assert_contains "watch list includes example" 'e.g.' "${watch}"

# Test 5: get_top_defect_patterns returns top N
top="$(get_top_defect_patterns 1)"
assert_contains "top pattern is null_check (highest count)" "null_check" "${top}"

# Test 6: examples capped at 5
for i in 1 2 3 4 5 6 7; do
  record_defect_pattern "edge_case" "edge case example ${i}"
done
num_examples="$(jq -r '.edge_case.examples | length' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "examples capped at 5" "5" "${num_examples}"

# Verify most recent example is last
last_example="$(jq -r '.edge_case.examples[-1]' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "most recent example is last" "edge case example 7" "${last_example}"

# Cleanup
rm -rf "${TEST_DEFECT_DIR}"
_DEFECT_PATTERNS_FILE="${_ORIG_DEFECT_FILE}"
_DEFECT_PATTERNS_LOCK="${_ORIG_DEFECT_LOCK}"

# ===========================================================================
# _ensure_valid_defect_patterns (with archive and read-path recovery)
# ===========================================================================
printf '\n_ensure_valid_defect_patterns:\n'

TEST_DEFECT_DIR2="$(mktemp -d)"
_DEFECT_PATTERNS_FILE="${TEST_DEFECT_DIR2}/defect-patterns.json"
_DEFECT_PATTERNS_LOCK="${TEST_DEFECT_DIR2}/.defect-patterns.lock"

# Test 1: non-existent file is a no-op
_defect_patterns_validated=0
_ensure_valid_defect_patterns
assert_exit "no file: no-op" "1" test -f "${_DEFECT_PATTERNS_FILE}"

# Test 2: valid file left alone
mkdir -p "${TEST_DEFECT_DIR2}"
printf '{"test":{"count":1,"last_seen_ts":100,"examples":[]}}' > "${_DEFECT_PATTERNS_FILE}"
_defect_patterns_validated=0
_ensure_valid_defect_patterns
val="$(jq -r '.test.count' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "valid file preserved" "1" "${val}"

# Test 3: corrupted file gets archived and reset
printf 'not json at all{{{' > "${_DEFECT_PATTERNS_FILE}"
_defect_patterns_validated=0
_ensure_valid_defect_patterns
val="$(jq -r 'type' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "corrupted file reset to object" "object" "${val}"

# Verify archive was created
archive_count="$(find "${TEST_DEFECT_DIR2}" -name '*.corrupt.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "corrupt archive created" "1" "${archive_count}"

# Test 4: read-path recovery — get_defect_watch_list heals corrupt file
printf '{"valid":{"count":3,"last_seen_ts":9999999999,"examples":["test"]}}' > "${_DEFECT_PATTERNS_FILE}"
_defect_patterns_validated=0
watch="$(get_defect_watch_list 1)"
assert_contains "read-path: watch list works after valid data" "valid" "${watch}"

# Now corrupt it and verify read-path heals
printf 'CORRUPT DATA' > "${_DEFECT_PATTERNS_FILE}"
_defect_patterns_validated=0
watch="$(get_defect_watch_list 1)"
# After healing, file should be valid JSON (empty object, so no watch list)
val="$(jq -r 'type' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null)"
assert_eq "read-path: corrupt file healed" "object" "${val}"

rm -rf "${TEST_DEFECT_DIR2}"
_DEFECT_PATTERNS_FILE="${_ORIG_DEFECT_FILE}"
_DEFECT_PATTERNS_LOCK="${_ORIG_DEFECT_LOCK}"
_defect_patterns_validated=0

# ===========================================================================
# build_quality_scorecard
# ===========================================================================
printf '\nbuild_quality_scorecard:\n'

# Save and isolate session state
_orig_sid2="${SESSION_ID}"
SESSION_ID="test-scorecard-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"

# Test 1: empty state shows not-run marks
sc="$(build_quality_scorecard)"
assert_contains "verification not run" "Verification: not run" "${sc}"
assert_contains "code review not run" "Code review: not run" "${sc}"

# Test 2: after verification passes
write_state "last_verify_ts" "$(now_epoch)"
write_state "last_verify_outcome" "passed"
write_state "last_verify_cmd" "npm test"
write_state "last_verify_confidence" "85"
sc="$(build_quality_scorecard)"
assert_contains "verification passed" "Verification: passed" "${sc}"
assert_contains "verify cmd shown" "npm test" "${sc}"

# Test 3: after review with findings
write_state "last_review_ts" "$(now_epoch)"
write_state "review_had_findings" "true"
sc="$(build_quality_scorecard)"
assert_contains "review findings" "Code review: findings reported" "${sc}"

# Test 4: clean review
write_state "review_had_findings" "false"
sc="$(build_quality_scorecard)"
assert_contains "review clean" "Code review: clean" "${sc}"

SESSION_ID="${_orig_sid2}"

# ===========================================================================
# detect_project_test_command — new tiers (justfile, Taskfile, bash tests/)
# ===========================================================================
printf '\ndetect_project_test_command (new tiers):\n'

# Justfile with test recipe
_tp_just="$(mktemp -d)"
printf 'default:\n\techo hi\ntest:\n\techo testing\n' > "${_tp_just}/justfile"
assert_eq "justfile with test recipe -> just test" \
  "just test" \
  "$(detect_project_test_command "${_tp_just}")"
rm -rf "${_tp_just}"

# Justfile without test recipe
_tp_just2="$(mktemp -d)"
printf 'default:\n\techo hi\n' > "${_tp_just2}/justfile"
assert_eq "justfile without test recipe -> empty" \
  "" \
  "$(detect_project_test_command "${_tp_just2}")"
rm -rf "${_tp_just2}"

# Taskfile.yml with test task
_tp_task="$(mktemp -d)"
cat > "${_tp_task}/Taskfile.yml" <<'TASKYAML'
version: '3'
tasks:
  test:
    cmds:
      - echo testing
TASKYAML
assert_eq "Taskfile.yml with test task -> task test" \
  "task test" \
  "$(detect_project_test_command "${_tp_task}")"
rm -rf "${_tp_task}"

# Taskfile false-positive guard: `test:` inside vars:/deps: must NOT match.
# Reviewer finding HIGH #3.
_tp_task_vars="$(mktemp -d)"
cat > "${_tp_task_vars}/Taskfile.yml" <<'TASKYAML'
version: '3'
vars:
  test: false
tasks:
  build:
    cmds:
      - go build ./...
TASKYAML
assert_eq "Taskfile with vars:test (no test task) -> empty" \
  "" \
  "$(detect_project_test_command "${_tp_task_vars}")"
rm -rf "${_tp_task_vars}"

_tp_task_deps="$(mktemp -d)"
cat > "${_tp_task_deps}/Taskfile.yml" <<'TASKYAML'
version: '3'
tasks:
  build:
    deps:
      - test
    cmds:
      - go build ./...
TASKYAML
assert_eq "Taskfile with deps mentioning test (no test task) -> empty" \
  "" \
  "$(detect_project_test_command "${_tp_task_deps}")"
rm -rf "${_tp_task_deps}"

# Bash-project orchestrator at repo root
_tp_bash1="$(mktemp -d)"
touch "${_tp_bash1}/run-tests.sh"
assert_eq "repo-root run-tests.sh -> bash run-tests.sh" \
  "bash run-tests.sh" \
  "$(detect_project_test_command "${_tp_bash1}")"
rm -rf "${_tp_bash1}"

# Bash-project orchestrator inside tests/
_tp_bash2="$(mktemp -d)"
mkdir -p "${_tp_bash2}/tests"
touch "${_tp_bash2}/tests/run-all.sh"
assert_eq "tests/run-all.sh -> bash tests/run-all.sh" \
  "bash tests/run-all.sh" \
  "$(detect_project_test_command "${_tp_bash2}")"
rm -rf "${_tp_bash2}"

# tests/test-*.sh alphabetical fallback
_tp_bash3="$(mktemp -d)"
mkdir -p "${_tp_bash3}/tests"
touch "${_tp_bash3}/tests/test-zebra.sh" "${_tp_bash3}/tests/test-alpha.sh"
assert_eq "tests/test-*.sh -> alphabetically first" \
  "bash tests/test-alpha.sh" \
  "$(detect_project_test_command "${_tp_bash3}")"
rm -rf "${_tp_bash3}"

# Language manifests still take precedence over bash fallback
_tp_pkg="$(mktemp -d)"
mkdir -p "${_tp_pkg}/tests"
touch "${_tp_pkg}/tests/test-alpha.sh"
cat > "${_tp_pkg}/package.json" <<'PKG'
{"scripts": {"test": "jest"}}
PKG
assert_eq "package.json beats tests/ fallback" \
  "npm test" \
  "$(detect_project_test_command "${_tp_pkg}")"
rm -rf "${_tp_pkg}"

# ===========================================================================
# verification_matches_project_test_command — bash-family match
# ===========================================================================
printf '\nverification_matches_project_test_command (bash family):\n'

assert_exit "same file matches" 0 \
  verification_matches_project_test_command \
    "bash tests/test-alpha.sh" "bash tests/test-alpha.sh"

assert_exit "different file in same tests/ dir matches" 0 \
  verification_matches_project_test_command \
    "bash tests/test-beta.sh" "bash tests/test-alpha.sh"

assert_exit "unrelated bash script does not match" 1 \
  verification_matches_project_test_command \
    "bash scripts/foo.sh" "bash tests/test-alpha.sh"

assert_exit "different directory does not match" 1 \
  verification_matches_project_test_command \
    "bash other/foo.sh" "bash tests/test-alpha.sh"

# Regex-injection guard: a `.` in the ptc dir must not let unrelated
# dir names match via regex interpretation. Reviewer finding HIGH #2.
assert_exit "dot in ptc dir does not over-match" 1 \
  verification_matches_project_test_command \
    "bash txsts/other.sh" "bash t.sts/foo.sh"

# Literal dot match still works (same ptc dir, different file).
assert_exit "literal dot match still matches sibling" 0 \
  verification_matches_project_test_command \
    "bash t.sts/bar.sh" "bash t.sts/foo.sh"

# Path-traversal dir is rejected when cmds differ.
assert_exit "path-traversal ptc with different cmd is rejected" 1 \
  verification_matches_project_test_command \
    "bash other/x.sh" "bash tests/../other/y.sh"

# ===========================================================================
# Classifier telemetry
# ===========================================================================
printf '\nClassifier telemetry:\n'

_tel_sid="classifier-tel-$$"
_orig_sid3="${SESSION_ID}"
SESSION_ID="${_tel_sid}"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
printf '{}' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"

# Helper: count misfire rows, always returning a single integer.
# grep -c exits 1 on no-match but still prints "0", so chaining `|| printf 0`
# double-emits. Wrapping in a subshell that catches the exit code is the
# cleanest pattern that works under `set -e`.
_count_misfires() {
  local f="$1"
  local n
  if [[ ! -f "${f}" ]]; then
    printf '0'
    return
  fi
  n="$(grep -c '"misfire":true' "${f}" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# Record an advisory row
record_classifier_telemetry "advisory" "coding" "what do you think?" "0"
_tel_file="${STATE_ROOT}/${SESSION_ID}/classifier_telemetry.jsonl"
assert_eq "telemetry file created" "1" "$([[ -f "${_tel_file}" ]] && echo 1 || echo 0)"

# Simulate a PreTool block and detection
write_state "pretool_intent_blocks" "1"
detect_classifier_misfire "do it" "1"

# Should have logged a misfire row
assert_eq "misfire recorded" "1" "$(_count_misfires "${_tel_file}")"
assert_contains "affirmation reason captured" \
  "affirmation" \
  "$(grep '"misfire":true' "${_tel_file}" 2>/dev/null || true)"

# Negation should NOT log a misfire
rm -f "${_tel_file}"
record_classifier_telemetry "advisory" "coding" "should I do X?" "0"
write_state "pretool_intent_blocks" "2"
detect_classifier_misfire "no thanks" "2"
assert_eq "negation does not log misfire" "0" "$(_count_misfires "${_tel_file}")"

# No PreTool block increment → no misfire
rm -f "${_tel_file}"
record_classifier_telemetry "advisory" "coding" "what do you think?" "5"
detect_classifier_misfire "do it" "5"
assert_eq "no block increment = no misfire" "0" "$(_count_misfires "${_tel_file}")"

# Execution intent followed by execution — no false positive
rm -f "${_tel_file}"
record_classifier_telemetry "execution" "coding" "implement X" "0"
write_state "pretool_intent_blocks" "1"
detect_classifier_misfire "also do Y" "1"
assert_eq "prior execution intent = no misfire" "0" "$(_count_misfires "${_tel_file}")"

# Stale prior row — excellence-reviewer finding: if prior_ts is > 15min
# old, the block count delta is likely from a session the user has
# abandoned. Do not log as misfire.
rm -f "${_tel_file}"
_fake_ts="$(( $(now_epoch) - 1000 ))"
# Hand-craft a stale telemetry row
printf '{"ts":"%s","intent":"advisory","domain":"coding","prompt":"old","pretool_blocks_observed":0}\n' \
  "${_fake_ts}" > "${_tel_file}"
write_state "pretool_intent_blocks" "1"
detect_classifier_misfire "do it" "1"
assert_eq "stale prior row (>15min) does not log misfire" \
  "0" "$(_count_misfires "${_tel_file}")"

# Opt-out: classifier_telemetry=off disables recording and detection.
rm -f "${_tel_file}"
_saved_tel="${OMC_CLASSIFIER_TELEMETRY}"
OMC_CLASSIFIER_TELEMETRY="off"
record_classifier_telemetry "advisory" "coding" "should I?" "0"
assert_eq "opt-out: no file created when OMC_CLASSIFIER_TELEMETRY=off" \
  "0" "$([[ -f "${_tel_file}" ]] && echo 1 || echo 0)"
# Detection is also a no-op under opt-out (even if file exists from before).
printf '{"ts":"%s","intent":"advisory","domain":"coding","prompt":"x","pretool_blocks_observed":0}\n' \
  "$(now_epoch)" > "${_tel_file}"
write_state "pretool_intent_blocks" "1"
detect_classifier_misfire "do it" "1"
assert_eq "opt-out: detect_classifier_misfire is a no-op" \
  "0" "$(_count_misfires "${_tel_file}")"
OMC_CLASSIFIER_TELEMETRY="${_saved_tel}"

SESSION_ID="${_orig_sid3}"

# ===========================================================================
# format_gate_recovery_line (v1.17.0)
# ===========================================================================
printf '\nformat_gate_recovery_line: standardized recovery hint for gate blocks:\n'

# Empty input → no output (no-op safe).
assert_eq "empty action → empty output" "" "$(format_gate_recovery_line "")"

# Action surfaces with the canonical "→ Next: <action>" shape, prefixed
# by a newline so it can be appended directly to a multi-line reason.
out="$(format_gate_recovery_line "run /ulw-skip with a reason")"
assert_eq "non-empty action → newline + arrow + Next: + action" \
  $'\n→ Next: run /ulw-skip with a reason' \
  "${out}"

# The exact arrow is U+2192 — the renderer should emit one canonical
# glyph, not a faux-ASCII "->" which would break visual scanning across
# gates.
arrow_count=$(printf '%s' "${out}" | grep -cF '→' || true)
assert_eq "→ glyph present exactly once" "1" "${arrow_count}"

# All four gate sites in stop-guard.sh must be calling the helper —
# regression guard for the v1.17.0 standardization. Without this, a
# future contributor hand-rolling a new gate-block message could miss
# the recovery line and the inconsistency would only surface to users
# at gate-fire time.
guard_file="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"
recovery_call_count=$(grep -c 'format_gate_recovery_line "' "${guard_file}" || true)
# 5 sites: advisory, session-handoff, discovered-scope, excellence, quality.
# (review-coverage emits its own narrative format with embedded "Next step:"
# language that's gate-specific — not routed through the helper by design.)
if [[ "${recovery_call_count}" -ge 5 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: stop-guard.sh has %s format_gate_recovery_line calls; expected >= 5\n' \
    "${recovery_call_count}" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Summary
# ===========================================================================

# ===========================================================================
# emit_stop_message + emit_stop_block helpers (v1.30.0 Wave 6)
# ===========================================================================
# These primitives encode the Stop-hook output contract. v1.24/v1.25 shipped
# the bug where `hookSpecificOutput.additionalContext` was used at Stop and
# silently dropped. Locking the schema in helpers (and asserting hand-rolled
# emits stay extinct in the stop-* / canary scripts) prevents the future-author
# regression.
printf '\n--- emit_stop_message + emit_stop_block ---\n'

emsg_out="$(emit_stop_message "card body")"
assert_eq "emit_stop_message produces systemMessage body" "card body" \
  "$(printf '%s' "${emsg_out}" | jq -r '.systemMessage // empty')"

# Negative assertion — must NOT have hookSpecificOutput.
if [[ "$(printf '%s' "${emsg_out}" | jq -r 'has("hookSpecificOutput")')" == "false" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: emit_stop_message included hookSpecificOutput (forbidden at Stop)\n' >&2
  fail=$((fail + 1))
fi

eblk_out="$(emit_stop_block "block reason")"
assert_eq "emit_stop_block produces decision=block" "block" \
  "$(printf '%s' "${eblk_out}" | jq -r '.decision // empty')"
assert_eq "emit_stop_block produces reason=block reason" "block reason" \
  "$(printf '%s' "${eblk_out}" | jq -r '.reason // empty')"

# Multi-line body preservation (time-card uses real newlines).
nl_body="$(printf 'line1\nline2\nline3')"
nl_out="$(emit_stop_message "${nl_body}")"
assert_eq "emit_stop_message preserves embedded newlines" \
  "${nl_body}" "$(printf '%s' "${nl_out}" | jq -r '.systemMessage')"

# Schema regression net: stop-guard, stop-time-summary, canary-claim-audit
# must NOT contain hand-rolled jq emits with `{systemMessage:` or
# `{"decision":"block"`. Future sites should always route through the helpers.
hand_rolled_total=0
for hook in stop-guard.sh stop-time-summary.sh canary-claim-audit.sh; do
  _hr_count="$(grep -c 'jq -nc --arg.*systemMessage\|jq -nc --arg.*"decision":"block"' \
    "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/${hook}" 2>/dev/null || true)"
  hand_rolled_total=$((hand_rolled_total + ${_hr_count:-0}))
done
if [[ "${hand_rolled_total}" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: %s hand-rolled Stop-output jq emit(s) remain in stop-* / canary scripts (expected 0; route via emit_stop_message / emit_stop_block)\n' \
    "${hand_rolled_total}" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
