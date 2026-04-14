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
# Summary
# ===========================================================================

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
