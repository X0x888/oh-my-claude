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
# Summary
# ===========================================================================

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
