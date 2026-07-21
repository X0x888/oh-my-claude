#!/usr/bin/env bash
# Focused tests for show-status.sh — covers the v1.27.0 (Wave 5)
# defensive parse + canary-empty fixes that were caught by quality
# reviewer findings 1 and 2.
#
# These are end-to-end runs (script-level), not unit tests of helper
# functions, because the bugs lived in the show-status script body
# (parameter expansion + grep-c fallback) — not in a library function.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SHOW_STATUS="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"

pass=0
fail=0

assert_zero_exit() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    rc=$?
    printf '  FAIL: %s (rc=%d)\n' "${label}" "${rc}" >&2
    "$@" 2>&1 | tail -10 >&2
    fail=$((fail + 1))
  fi
}

assert_output_contains() {
  local label="$1" needle="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "${out}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    output(first 400)=%q\n' "${label}" "${needle}" "${out:0:400}" >&2
    fail=$((fail + 1))
  fi
}

assert_output_NOT_contains() {
  local label="$1" needle="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "${out}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected_needle=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_text_contains() {
  local label="$1" needle="$2" out="$3"
  if [[ "${out}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    output(first 600)=%q\n' \
      "${label}" "${needle}" "${out:0:600}" >&2
    fail=$((fail + 1))
  fi
}

# Build a synthetic STATE_ROOT + SESSION_ID for each test.
mk_session() {
  local _root _sid
  _root="$(mktemp -d -t show-status-test-XXXXXX)"
  _sid="ut-$$-$RANDOM"
  mkdir -p "${_root}/${_sid}"
  printf '%s|%s' "${_root}" "${_sid}"
}

teardown_session() {
  rm -rf "$1"
}

# ----------------------------------------------------------------------
printf 'Test 1: defensive parse on malformed last_verify_factors does NOT crash (Wave-5 review #1)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_verify_confidence":"30","last_verify_factors":"framework:30|total:30","last_verify_method":"shellcheck","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"

# Even with malformed factors (missing test_match: segment), show-status
# should exit 0 and render a sane breakdown (zero-falling-back).
assert_zero_exit "T1: malformed factors does not crash" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

assert_output_contains "T1: breakdown line still rendered" \
  "Breakdown:" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

# The malformed test_match segment should fall back to 0/40, not bleed
# the framework string into the output.
assert_output_contains "T1: malformed test_match falls back to 0/40" \
  "test-cmd-match=0/40" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

assert_output_NOT_contains "T1: malformed parse does NOT leak verbatim" \
  "test-cmd-match=framework" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 2: empty canary.jsonl does NOT crash and suppresses zero-row panel (Wave-5 review #2)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
: > "${ROOT}/${SID}/canary.jsonl"

assert_zero_exit "T2: empty canary.jsonl does not crash" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

# Total=0 → suppress the panel entirely (per Wave-5 polish).
assert_output_NOT_contains "T2: zero-total panel suppressed" \
  "total=0" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_NOT_contains "T2: no model-drift header on empty file" \
  "Model-drift canary" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 2b: pending specialist count excludes abandoned tombstones\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
{
  printf '%s\n' '{"agent_type":"live-specialist"}'
  printf '%s\n' '{"agent_type":"abandoned-old","review_dispatch_abandoned":true}'
} >"${ROOT}/${SID}/pending_agents.jsonl"
assert_output_contains "T2b: status counts only live pending specialists" \
  "Pending specialists:       1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_NOT_contains "T2b: status does not count tombstone as second live specialist" \
  "Pending specialists:       2" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 3: populated canary.jsonl renders the verdict-distribution panel\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
{
  printf '%s\n' '{"verdict":"clean","claim_count":1}'
  printf '%s\n' '{"verdict":"unverified","claim_count":4}'
  printf '%s\n' '{"verdict":"covered","claim_count":3}'
} > "${ROOT}/${SID}/canary.jsonl"

assert_output_contains "T3: total reflects 3 rows" \
  "total=3" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T3: clean=1" \
  "clean=1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T3: unverified=1" \
  "unverified=1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T3: alert mentions claim_count threshold" \
  "claim_count" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 4: MCP-path verification renders the "no breakdown" fallback line (Wave-5 review #4)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_verify_confidence":"30","last_verify_method":"mcp_browser_console_check","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
# Note: no last_verify_factors key — simulating MCP path that doesn't set it.

assert_output_contains "T4: MCP fallback line renders" \
  "MCP-path verification" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T4: still shows confidence + method" \
  "Method: mcp_browser_console_check" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 5: hint logic — when threshold gap > largest single factor, emit combine-hint\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
# Confidence 0/100 with all factors at 0. Default threshold is 40. The
# single-factor branches cover need<=40, so gap=40 still triggers the
# test-cmd hint. To force the combine branch, use a custom threshold.
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_verify_confidence":"0","last_verify_factors":"test_match:0|framework:0|output_counts:0|clear_outcome:0|total:0","last_verify_method":"unknown","project_test_cmd":"npm test","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"

# threshold=70 forces gap=70, which exceeds any single factor's max (40).
assert_output_contains "T5: combine-hint when threshold gap > 40" \
  "combine" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" OMC_VERIFY_CONFIDENCE_THRESHOLD=70 bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 5b: live status surfaces directive prompt-surface totals in timing line\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
cat > "${ROOT}/${SID}/timing.jsonl" <<'EOF'
{"kind":"prompt_start","ts":100,"prompt_seq":1}
{"kind":"directive_emitted","ts":101,"prompt_seq":1,"name":"ui_design_contract","chars":160}
{"kind":"directive_emitted","ts":102,"prompt_seq":1,"name":"intent_classification","chars":80}
{"kind":"prompt_end","ts":106,"prompt_seq":1,"duration_s":6}
EOF

assert_output_contains "T5b: directive surface totals rendered in status timing line" \
  "directive surface 240 chars (2 fires)" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 5c: token drivers and canonical agent-metrics schema surface\n'
STATUS_HOME="$(mktemp -d -t show-status-home-XXXXXX)"
ROOT="${STATUS_HOME}/.claude/quality-pack/state"
SID="status-economics"
mkdir -p "${ROOT}/${SID}" "${STATUS_HOME}/.claude/quality-pack"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
cat > "${ROOT}/${SID}/timing.jsonl" <<'EOF'
{"kind":"prompt_start","ts":100,"prompt_seq":1}
{"kind":"prompt_end","ts":106,"prompt_seq":1,"duration_s":6}
{"kind":"token_checkpoint","ts":106,"prompt_seq":1,"agent_in":30,"agent_out":50,"agent_cache_read":100030,"agent_cache_creation":50,"agent_by_role":{"cache-heavy":{"input":1,"output":1,"cache_read":100000,"cache_creation":1},"quality-reviewer\u001b[31m":{"input":29,"output":49,"cache_read":30,"cache_creation":49}},"agent_by_model":{"cached-model":{"input":1,"output":1,"cache_read":100000,"cache_creation":1},"claude-sonnet-test\u0007":{"input":29,"output":49,"cache_read":30,"cache_creation":49}}}
EOF
cat > "${STATUS_HOME}/.claude/quality-pack/agent-metrics.json" <<'EOF'
{"_schema_version":3,"agents":{"quality-reviewer":{"invocations":2,"clean_verdicts":1,"finding_verdicts":1}}}
EOF
assert_output_contains "T5c: top token role surfaced" \
  "fresh-token drivers: role quality-reviewer" \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T5c: top token model surfaced" \
  "model claude-sonnet-test" \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_NOT_contains "T5c: legacy token labels cannot emit terminal ESC" \
  $'\033' \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_NOT_contains "T5c: legacy token labels cannot emit bell controls" \
  $'\a' \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_NOT_contains "T5c: cheap cache volume is not mislabeled as cost driver" \
  "fresh-token drivers: role cache-heavy" \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T5c: canonical nested metrics visible" \
  "quality-reviewer: 2 runs, 1 clean, 1 findings" \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
rm -rf "${STATUS_HOME}"

# ----------------------------------------------------------------------
printf 'Test 5d: cache-only agent buckets are not labeled fresh-token drivers\n'
STATUS_HOME="$(mktemp -d -t show-status-cache-only-XXXXXX)"
ROOT="${STATUS_HOME}/.claude/quality-pack/state"
SID="status-cache-only"
mkdir -p "${ROOT}/${SID}" "${STATUS_HOME}/.claude/quality-pack"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
cat > "${ROOT}/${SID}/timing.jsonl" <<'EOF'
{"kind":"prompt_start","ts":100,"prompt_seq":1}
{"kind":"prompt_end","ts":106,"prompt_seq":1,"duration_s":6}
{"kind":"token_checkpoint","ts":106,"prompt_seq":1,"agent_cache_read":100000,"agent_by_role":{"cache-only":{"input":0,"output":0,"cache_read":100000,"cache_creation":0}},"agent_by_model":{"cached-model":{"input":0,"output":0,"cache_read":100000,"cache_creation":0}}}
EOF
assert_output_NOT_contains "T5d: cache-only buckets emit no fresh-driver label" \
  "fresh-token drivers:" \
  env HOME="${STATUS_HOME}" STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
rm -rf "${STATUS_HOME}"

# ----------------------------------------------------------------------
printf 'Test 6: --explain renders per-flag rationale (v1.30.0 Wave 7)\n'
# Closes the v1.29.0 product-lens P2-10 deferred item: users wanting to
# disable a flag previously had to read the 422-line conf-example file
# to learn what each flag does.
out_explain="$(bash "${SHOW_STATUS}" --explain 2>&1 || true)"
if [[ "${out_explain}" == *"flag rationale"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain header missing; got first 300 chars:\n%s\n' \
    "${out_explain:0:300}" >&2
  fail=$((fail + 1))
fi

# Must list at least one known flag with its description.
if [[ "${out_explain}" == *"prompt_persist"* ]] \
    && [[ "${out_explain}" == *"In-session prompt"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain did not surface prompt_persist + description\n' >&2
  fail=$((fail + 1))
fi

# Must group by cluster (at least one cluster header is present).
if [[ "${out_explain}" == *"── gates ──"* ]] \
    || [[ "${out_explain}" == *"── memory ──"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain missing cluster grouping headers\n' >&2
  fail=$((fail + 1))
fi

# --explain is session-independent: must succeed even with no session state.
_no_state_root="$(mktemp -d)"
out_no_session="$(STATE_ROOT="${_no_state_root}" bash "${SHOW_STATUS}" --explain 2>&1 || true)"
rm -rf "${_no_state_root}"
if [[ "${out_no_session}" == *"flag rationale"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain failed when no session state was present\n' >&2
  fail=$((fail + 1))
fi

# Help mode lists --explain.
out_help="$(bash "${SHOW_STATUS}" --help 2>&1 || true)"
if [[ "${out_help}" == *"--explain"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --help does not document --explain\n' >&2
  fail=$((fail + 1))
fi

# Explain must report what common.sh actually enforces, not whichever raw
# row happens to be closest to the renderer. In particular, the Definition
# and Constitution controls are user-authority only: project rows cannot
# weaken them, malformed environment/config values are ignored, and a valid
# environment override wins. A permitted project flag also proves that the
# status surface follows common.sh's capped walk-up rather than checking only
# ${PWD}/.claude.
printf 'Test 6b: --explain reports validated runtime precedence and project authority\n'
EXPLAIN_HOME="$(mktemp -d -t show-status-explain-home-XXXXXX)"
EXPLAIN_PROJECT="${EXPLAIN_HOME}/work/project"
EXPLAIN_NESTED="${EXPLAIN_PROJECT}/nested/deeper"
mkdir -p "${EXPLAIN_HOME}/.claude" "${EXPLAIN_PROJECT}/.claude" "${EXPLAIN_NESTED}"
cat > "${EXPLAIN_HOME}/.claude/oh-my-claude.conf" <<'EOF'
definition_of_excellent=always
quality_constitution=off
taste_learning=adaptive
quality_constitution_max_context_chars=4000
metis_on_plan_gate=off
gate_level=full
installation_drift_check=off
statusline_retention=NO
statusline_width=false
EOF
cat > "${EXPLAIN_PROJECT}/.claude/oh-my-claude.conf" <<'EOF'
definition_of_excellent=off
quality_constitution=on
taste_learning=off
quality_constitution_max_context_chars=9999
metis_on_plan_gate=on
gate_level=standard
gate_level=invalid
installation_drift_check=true
statusline_retention=on
statusline_width=on
EOF

out_effective="$(
  cd "${EXPLAIN_NESTED}"
  env -u OMC_DEFINITION_OF_EXCELLENT \
      -u OMC_QUALITY_CONSTITUTION \
      -u OMC_TASTE_LEARNING \
      -u OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS \
      -u OMC_METIS_ON_PLAN_GATE \
      HOME="${EXPLAIN_HOME}" bash "${SHOW_STATUS}" --explain 2>&1
)"
assert_text_contains "T6b: denied project Definition row cannot weaken user value" \
  "definition_of_excellent=always (default=adaptive)" "${out_effective}"
assert_text_contains "T6b: denied project Constitution row cannot override user value" \
  "quality_constitution=off (default=on)" "${out_effective}"
assert_text_contains "T6b: denied project taste row cannot override user value" \
  "taste_learning=adaptive (default=review)" "${out_effective}"
assert_text_contains "T6b: denied project context cap cannot override user value" \
  "quality_constitution_max_context_chars=4000 (default=2400)" "${out_effective}"
assert_text_contains "T6b: allowed project row is discovered by walk-up" \
  "metis_on_plan_gate=on (default=off)" "${out_effective}"
assert_text_contains "T6b: malformed later project duplicate retains last valid row" \
  "gate_level=standard (default=full)" "${out_effective}"
assert_text_contains "T6b: drift control is user-conf-only" \
  "installation_drift_check=false (default=true)" "${out_effective}"
assert_text_contains "T6b: retention control is user-conf-only and canonical" \
  "statusline_retention=off (default=on)" "${out_effective}"
assert_text_contains "T6b: width control is user-conf-only and canonical" \
  "statusline_width=off (default=on)" "${out_effective}"

out_env_effective="$(
  cd "${EXPLAIN_NESTED}"
  HOME="${EXPLAIN_HOME}" \
    OMC_DEFINITION_OF_EXCELLENT=off \
    OMC_QUALITY_CONSTITUTION=on \
    OMC_TASTE_LEARNING=review \
    OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=512 \
    OMC_GATE_LEVEL=basic \
    OMC_INSTALLATION_DRIFT_CHECK=YES \
    OMC_STATUSLINE_RETENTION=1 \
    OMC_STATUSLINE_WIDTH=TRUE \
    bash "${SHOW_STATUS}" --explain 2>&1
)"
assert_text_contains "T6b: valid environment Definition value wins" \
  "definition_of_excellent=off (default=adaptive)" "${out_env_effective}"
assert_text_contains "T6b: valid environment Constitution value wins" \
  "quality_constitution=on (default=on)" "${out_env_effective}"
assert_text_contains "T6b: valid environment taste value wins" \
  "taste_learning=review (default=review)" "${out_env_effective}"
assert_text_contains "T6b: valid environment context cap wins" \
  "quality_constitution_max_context_chars=512 (default=2400)" "${out_env_effective}"
assert_text_contains "T6b: valid generic environment value wins" \
  "gate_level=basic (default=full)" "${out_env_effective}"
assert_text_contains "T6b: statusline drift env alias canonicalizes" \
  "installation_drift_check=true (default=true)" "${out_env_effective}"
assert_text_contains "T6b: statusline retention env alias canonicalizes" \
  "statusline_retention=on (default=on)" "${out_env_effective}"
assert_text_contains "T6b: statusline width env alias canonicalizes" \
  "statusline_width=on (default=on)" "${out_env_effective}"

out_invalid_env="$(
  cd "${EXPLAIN_NESTED}"
  HOME="${EXPLAIN_HOME}" \
    OMC_DEFINITION_OF_EXCELLENT=invalid \
    OMC_QUALITY_CONSTITUTION=invalid \
    OMC_TASTE_LEARNING=invalid \
    OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=0512 \
    OMC_GATE_LEVEL=invalid \
    OMC_INSTALLATION_DRIFT_CHECK=invalid \
    OMC_STATUSLINE_RETENTION=invalid \
    OMC_STATUSLINE_WIDTH=invalid \
    bash "${SHOW_STATUS}" --explain 2>&1
)"
assert_text_contains "T6b: malformed environment Definition falls through to user" \
  "definition_of_excellent=always (default=adaptive)" "${out_invalid_env}"
assert_text_contains "T6b: malformed environment Constitution falls through to user" \
  "quality_constitution=off (default=on)" "${out_invalid_env}"
assert_text_contains "T6b: malformed environment taste falls through to user" \
  "taste_learning=adaptive (default=review)" "${out_invalid_env}"
assert_text_contains "T6b: malformed environment context cap falls through to user" \
  "quality_constitution_max_context_chars=4000 (default=2400)" "${out_invalid_env}"
assert_text_contains "T6b: malformed generic environment falls through to project" \
  "gate_level=standard (default=full)" "${out_invalid_env}"
assert_text_contains "T6b: malformed drift env falls through to user" \
  "installation_drift_check=false (default=true)" "${out_invalid_env}"
assert_text_contains "T6b: malformed retention env falls through to user" \
  "statusline_retention=off (default=on)" "${out_invalid_env}"
assert_text_contains "T6b: malformed width env falls through to user" \
  "statusline_width=off (default=on)" "${out_invalid_env}"

cat > "${EXPLAIN_HOME}/.claude/oh-my-claude.conf" <<'EOF'
definition_of_excellent=best
quality_constitution=maybe
taste_learning=eager
quality_constitution_max_context_chars=12001
EOF
out_invalid_user="$(
  cd "${EXPLAIN_NESTED}"
  env -u OMC_DEFINITION_OF_EXCELLENT \
      -u OMC_QUALITY_CONSTITUTION \
      -u OMC_TASTE_LEARNING \
      -u OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS \
      HOME="${EXPLAIN_HOME}" bash "${SHOW_STATUS}" --explain 2>&1
)"
assert_text_contains "T6b: malformed user Definition value reports runtime default" \
  "definition_of_excellent=adaptive (default=adaptive)" "${out_invalid_user}"
assert_text_contains "T6b: malformed user Constitution value reports runtime default" \
  "quality_constitution=on (default=on)" "${out_invalid_user}"
assert_text_contains "T6b: malformed user taste value reports runtime default" \
  "taste_learning=review (default=review)" "${out_invalid_user}"
assert_text_contains "T6b: out-of-range user context cap reports runtime default" \
  "quality_constitution_max_context_chars=2400 (default=2400)" "${out_invalid_user}"
rm -rf "${EXPLAIN_HOME}"

# v1.31.0 Wave 6 (design-lens F-027): bare-positional argument forms
# accepted in addition to --double-dash.
printf '\nT7: bare-positional argument forms (v1.31.0 grammar normalization)\n'
# Use a fresh STATE_ROOT for each so the CI environment (no real
# session) and local dev (a real session present) both produce the
# "No active ULW session found." empty-state path. The assertion is
# specifically that the BARE form does NOT exit with 'Unknown argument'
# — that's the regression net for v1.31.0 grammar normalization.
out_summary_pos="$(STATE_ROOT="$(mktemp -d)" bash "${SHOW_STATUS}" summary 2>&1 || true)"
if [[ "${out_summary_pos}" == *"Unknown argument"* ]]; then
  printf '  FAIL: bare `summary` rejected as Unknown argument\n%s\n' "${out_summary_pos}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
  printf '  PASS: bare `summary` accepted\n'
fi
out_explain_pos="$(STATE_ROOT="$(mktemp -d)" bash "${SHOW_STATUS}" explain 2>&1 || true)"
if [[ "${out_explain_pos}" == *"flag rationale"* ]]; then
  pass=$((pass + 1))
  printf '  PASS: bare `explain` works\n'
else
  printf '  FAIL: bare `explain` failed\n' >&2
  fail=$((fail + 1))
fi
out_classifier_pos="$(STATE_ROOT="$(mktemp -d)" bash "${SHOW_STATUS}" classifier 2>&1 || true)"
if [[ "${out_classifier_pos}" == *"Unknown argument"* ]]; then
  printf '  FAIL: bare `classifier` rejected as Unknown argument\n%s\n' "${out_classifier_pos}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
  printf '  PASS: bare `classifier` accepted\n'
fi
# --help shows BOTH grammar forms.
out_help_full="$(bash "${SHOW_STATUS}" --help 2>&1 || true)"
if [[ "${out_help_full}" == *"[summary | classifier | explain]"* ]] \
   && [[ "${out_help_full}" == *"--summary"* ]]; then
  pass=$((pass + 1))
  printf '  PASS: --help documents both positional and --flag forms\n'
else
  printf '  FAIL: --help missing one of the grammar forms\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 8: delivery-contract section surfaces prompt contract and remaining obligations\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
ts_now="$(date +%s)"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","current_objective":"Ship the auth fix","done_contract_primary":"Ship the auth fix","done_contract_commit_mode":"required","done_contract_prompt_surfaces":"tests,docs,release","done_contract_test_expectation":"add_or_update_tests","verification_contract_required":"code_review,code_verify,prose_review,test_surface,release_surface,commit_record","last_code_edit_ts":"%s","last_doc_edit_ts":"%s","last_review_ts":"%s","last_doc_review_ts":"%s","last_verify_ts":"%s","last_verify_outcome":"passed","last_verify_confidence":"80","session_start_ts":"%s"}' \
  "${ts_now}" "${ts_now}" "${ts_now}" "${ts_now}" "${ts_now}" "${ts_now}" > "${ROOT}/${SID}/session_state.json"
cat > "${ROOT}/${SID}/edited_files.log" <<'EOF'
/project/src/auth.ts
/project/tests/auth.test.ts
/project/README.md
/project/CHANGELOG.md
EOF

assert_output_contains "T8: full status renders delivery-contract header" \
  "--- Delivery Contract ---" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: commit intent rendered" \
  "Commit intent:       required" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: prompt surfaces humanized" \
  "Prompt surfaces:     tests · docs · release" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: touched surfaces rendered" \
  "Touched surfaces:    code=2 · docs=2 · tests=1 · release=1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: remaining commit obligation rendered" \
  "create the requested commit before stopping" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: summary mode surfaces contract" \
  "Contract:   commit=required · prompt surfaces=tests · docs · release" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}" --summary
teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 9: force-override counters surfaced only when nonzero (v1.42.x audit symmetry)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"

# Baseline: no force overrides → row suppressed (steady-state quietness).
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
assert_output_NOT_contains "T9: zero counters suppress the row" \
  "Force overrides:" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

# Set one counter (skip=2) → row appears with all three values.
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s","ulw_skip_force_count":"2"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
assert_output_contains "T9: nonzero counter surfaces the row" \
  "Force overrides:" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T9: skip count rendered" \
  "skip=2" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T9: pause defaults to 0 when only skip set" \
  "pause=0" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T9: correct defaults to 0 when only skip set" \
  "correct=0" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

# All three counters set → all three render with their values.
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s","ulw_skip_force_count":"1","ulw_pause_force_count":"3","ulw_correct_force_count":"2"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
assert_output_contains "T9: all three counters render together" \
  "skip=1 pause=3 correct=2" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 10: unknown Bash edit scope is visible without fabricating a file count\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","code_edit_count":"0","bash_unknown_edit_scope":"1","last_bash_edit_ts":"%s","last_code_edit_ts":"%s","session_start_ts":"%s"}' \
  "$(date +%s)" "$(date +%s)" "$(date +%s)" > "${ROOT}/${SID}/session_state.json"

assert_output_contains "T10: full status names unknown Bash scope" \
  "Bash edit scope:    unknown" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T10: summary distinguishes exact count from unknown scope" \
  "0 exact + unknown Bash scope code edits" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}" --summary
teardown_session "${ROOT}"

printf '\n=== Show-Status Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
