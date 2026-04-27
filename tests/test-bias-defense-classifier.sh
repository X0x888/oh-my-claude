#!/usr/bin/env bash
# Tests for the v1.19.0 bias-defense prompt-shape classifiers in
# lib/classifier.sh and the plan-complexity extraction in record-plan.sh.
#
# Two surfaces under test:
#   1. is_product_shaped_request, is_ambiguous_execution_request — pure
#      string predicates over the raw prompt.
#   2. _compute_plan_complexity — invoked indirectly via record-plan.sh
#      against synthetic plan bodies; verifies the four orthogonal legs
#      (steps, files, waves, keywords) and the high/low boundary.
#
# Mirrors the structure of test-classifier.sh and test-state-io.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Sandbox STATE_ROOT before sourcing so the test never writes into the
# user's real ~/.claude/quality-pack/state. Cleanup runs in the trap below.
_test_state_root="$(mktemp -d -t bias-defense-classifier-XXXXXX)"
export STATE_ROOT="${_test_state_root}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_true() {
  local label="$1" cmd="$2"
  if eval "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    cmd=%s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

assert_false() {
  local label="$1" cmd="$2"
  if eval "${cmd}"; then
    printf '  FAIL: %s\n    expected false but cmd succeeded: %s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
printf 'Test 1: is_product_shaped_request positive cases\n'
assert_true "build a habit tracker app"          'is_product_shaped_request "build me a habit tracker app"'
assert_true "create a dashboard"                 'is_product_shaped_request "create a dashboard for my team"'
assert_true "design an onboarding flow"          'is_product_shaped_request "design an onboarding flow for new users"'
assert_true "implement a CLI tool"               'is_product_shaped_request "implement a CLI tool for log search"'
assert_true "make a landing page"                'is_product_shaped_request "make a landing page for the launch"'
assert_true "build an MVP"                       'is_product_shaped_request "build an MVP for the new product"'
assert_true "ship a chatbot"                     'is_product_shaped_request "ship a chatbot for support"'
assert_true "spin up a SaaS"                     'is_product_shaped_request "spin up a SaaS billing service"'

# ----------------------------------------------------------------------
printf 'Test 2: is_product_shaped_request negative cases (code anchors)\n'
assert_false "fix specific file"                 'is_product_shaped_request "fix the off-by-one in parse.ts:42"'
assert_false "function call ref"                 'is_product_shaped_request "create a wrapper for foo()"'
assert_false "error name"                        'is_product_shaped_request "build the handler for ValidationError"'
assert_false "specific path"                     'is_product_shaped_request "design the new src/services/auth.ts module"'

# ----------------------------------------------------------------------
printf 'Test 3: is_product_shaped_request negative cases (wrong verb/noun)\n'
assert_false "fix is not product-shape verb"     'is_product_shaped_request "fix the dashboard scrollbar"'
assert_false "refactor is not product verb"      'is_product_shaped_request "refactor the dashboard layout"'
assert_false "function noun is not product"      'is_product_shaped_request "build a function for sorting"'
assert_false "empty string"                      'is_product_shaped_request ""'
assert_false "no verb"                           'is_product_shaped_request "the dashboard needs work"'

# Targeted-change keywords disqualify even with a build-class verb (F-3
# from quality-reviewer). "Ship a fix" / "make extension changes" looked
# product-shaped under the v1.19.0-pre regex; these assertions lock in
# the tighter behavior.
assert_false "ship a fix to a service"           'is_product_shaped_request "ship a fix to the auth service"'
assert_false "make a tweak to the integration"   'is_product_shaped_request "make a tweak to the Stripe integration"'
assert_false "build a hotfix"                    'is_product_shaped_request "build a hotfix for the auth flow"'
# Multi-component path disqualifier (F-1).
assert_false "extensionless path"                'is_product_shaped_request "build a flow for src/utils/auth"'
# Backtick-fenced span disqualifier (F-1).
assert_false "backtick code span"                'is_product_shaped_request "build a feature around \`some_function\`"'

# ----------------------------------------------------------------------
printf 'Test 4: is_ambiguous_execution_request positive cases\n'
assert_true "short imperative"                   'is_ambiguous_execution_request "build a dashboard"'
assert_true "fix off-by-one"                     'is_ambiguous_execution_request "fix the off-by-one bug"'
assert_true "implement validation"               'is_ambiguous_execution_request "implement validation for the form"'
assert_true "polish the UI"                      'is_ambiguous_execution_request "polish the user interface"'

# ----------------------------------------------------------------------
printf 'Test 5: is_ambiguous_execution_request negative cases (length)\n'
assert_false "too short"                         'is_ambiguous_execution_request "yes"'
assert_false "empty"                             'is_ambiguous_execution_request ""'
# Construct a 250-char prompt: too long to be ambiguous
_long_prompt="implement the user authentication system with email and password login, password reset via email tokens, session management using JWT, role-based access control with admin and user roles, and a fully tested signup flow."
assert_false "long detailed brief"               'is_ambiguous_execution_request "${_long_prompt}"'

# ----------------------------------------------------------------------
printf 'Test 6: is_ambiguous_execution_request negative cases (anchors)\n'
assert_false "file path"                         'is_ambiguous_execution_request "fix the bug in parse.ts:42"'
assert_false "function call"                     'is_ambiguous_execution_request "rewrite handleClick() in the button"'
assert_false "error class"                       'is_ambiguous_execution_request "handle the ValidationError properly"'
assert_false "specific path"                     'is_ambiguous_execution_request "update the src/auth.py module"'
# Multi-component path disqualifier (F-1) — extensionless paths now
# count as concrete code anchors.
assert_false "multi-component path"              'is_ambiguous_execution_request "edit the bundle/dot-claude/skills layout"'
assert_false "backtick code span"                'is_ambiguous_execution_request "tighten the \`is_ulw_trigger\` check"'

# ----------------------------------------------------------------------
printf 'Test 7: _compute_plan_complexity legs (via record-plan.sh)\n'
#
# Drive record-plan.sh end-to-end with synthetic plan bodies and read
# back the persisted state keys. This exercises the full integration:
# function definition + state writes + signal CSV rendering.

_orig_pwd="$(pwd)"
trap '_cleanup_test_state' EXIT
_cleanup_test_state() {
  rm -rf "${_test_state_root}"
  cd "${_orig_pwd}"
}

_run_record_plan() {
  local session_id="$1"
  local plan_body="$2"

  # record-plan.sh reads JSON from stdin and reads SESSION_ID from
  # `.session_id`. Synthesize the hook payload. Pass STATE_ROOT through
  # to the child shell so it writes into the sandboxed root.
  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg agent "quality-planner" \
    --arg msg "${plan_body}" \
    '{session_id:$sid, agent_type:$agent, last_assistant_message:$msg}')"

  STATE_ROOT="${_test_state_root}" printf '%s' "${hook_json}" \
    | STATE_ROOT="${_test_state_root}" bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-plan.sh" \
        >/dev/null 2>&1 || true
}

_read_session_state() {
  local session_id="$1"
  local key="$2"
  local state_file="${_test_state_root}/${session_id}/session_state.json"
  [[ -f "${state_file}" ]] || { printf ''; return; }
  jq -r --arg k "${key}" '.[$k] // ""' "${state_file}" 2>/dev/null || true
}

# ------ Leg 1: step_count > 5 → high
sid_steps="t1-steps-${RANDOM}"
plan_high_steps="$(printf '1. Step one\n2. Step two\n3. Step three\n4. Step four\n5. Step five\n6. Step six\n')"
_run_record_plan "${sid_steps}" "${plan_high_steps}"
assert_eq "leg-steps high"            "1"        "$(_read_session_state "${sid_steps}" "plan_complexity_high")"

# ------ Leg 2: file_count > 3 → high
sid_files="t1-files-${RANDOM}"
plan_high_files="The plan touches src/a.ts, src/b.ts, src/c.ts, src/d.ts, and the docs at README.md."
_run_record_plan "${sid_files}" "${plan_high_files}"
assert_eq "leg-files high"            "1"        "$(_read_session_state "${sid_files}" "plan_complexity_high")"

# ------ Leg 3: wave_count >= 2 → high
sid_waves="t1-waves-${RANDOM}"
plan_high_waves="$(printf '## Wave 1/3: foundation\n## Wave 2/3: directives\n## Wave 3/3: gate\n')"
_run_record_plan "${sid_waves}" "${plan_high_waves}"
assert_eq "leg-waves high"            "1"        "$(_read_session_state "${sid_waves}" "plan_complexity_high")"

# ------ Leg 4: keyword + scope → high
sid_kw_scope="t1-kw-${RANDOM}"
# 4 numbered steps + the 'migration' keyword → high
plan_high_kw="$(printf 'This is a database migration plan.\n1. Backup\n2. Apply schema\n3. Run script\n4. Verify\n')"
_run_record_plan "${sid_kw_scope}" "${plan_high_kw}"
assert_eq "leg-keyword+scope high"    "1"        "$(_read_session_state "${sid_kw_scope}" "plan_complexity_high")"

# ------ Negative: keyword alone is NOT enough
sid_kw_only="t1-kwonly-${RANDOM}"
plan_kw_only="Just refactor the comment."
_run_record_plan "${sid_kw_only}" "${plan_kw_only}"
assert_eq "keyword without scope is low"  ""    "$(_read_session_state "${sid_kw_only}" "plan_complexity_high")"

# ------ Leg 4 alt: keyword + file_count branch (F-5 from reviewer)
sid_kw_files="t1-kw-files-${RANDOM}"
# 3 file refs + 'schema' keyword → high (file_count branch of the
# keyword-AND-scope leg, distinct from the steps branch above).
plan_high_kw_files="A small schema change touches src/a.ts, src/b.py, and src/c.go."
_run_record_plan "${sid_kw_files}" "${plan_high_kw_files}"
assert_eq "leg-keyword+files high"    "1"        "$(_read_session_state "${sid_kw_files}" "plan_complexity_high")"

# ------ Negative: simple plan → low
sid_simple="t1-simple-${RANDOM}"
plan_simple="$(printf '1. Add a flag\n2. Wire it up\n')"
_run_record_plan "${sid_simple}" "${plan_simple}"
assert_eq "simple plan is low"        ""        "$(_read_session_state "${sid_simple}" "plan_complexity_high")"

# ----------------------------------------------------------------------
printf 'Test 8: plan_complexity_signals CSV format\n'
# Reuse the high-steps fixture; the signal string should contain all
# four leg labels with the correct counts.
signals="$(_read_session_state "${sid_steps}" "plan_complexity_signals")"
assert_true "signals has steps="          "[[ '${signals}' == *steps=* ]]"
assert_true "signals has files="          "[[ '${signals}' == *files=* ]]"
assert_true "signals has waves="          "[[ '${signals}' == *waves=* ]]"

signals_kw="$(_read_session_state "${sid_kw_scope}" "plan_complexity_signals")"
assert_true "signals has keywords= when kw present" "[[ '${signals_kw}' == *keywords=migration* ]]"

# ----------------------------------------------------------------------
printf 'Test 9: conf parser accepts new bias-defense keys\n'
# Confirm the three new conf keys parse correctly via _parse_conf_file.
_test_conf="$(mktemp -t bias-defense-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
metis_on_plan_gate=on
prometheus_suggest=on
intent_verify_directive=on
EOF
# Reset env-var snapshots so the conf values take effect.
unset OMC_METIS_ON_PLAN_GATE OMC_PROMETHEUS_SUGGEST OMC_INTENT_VERIFY_DIRECTIVE
_omc_env_metis_on_plan_gate=""
_omc_env_prometheus_suggest=""
_omc_env_intent_verify_directive=""
OMC_METIS_ON_PLAN_GATE="off"
OMC_PROMETHEUS_SUGGEST="off"
OMC_INTENT_VERIFY_DIRECTIVE="off"
_parse_conf_file "${_test_conf}"
assert_eq "metis_on_plan_gate parsed" "on" "${OMC_METIS_ON_PLAN_GATE}"
assert_eq "prometheus_suggest parsed" "on" "${OMC_PROMETHEUS_SUGGEST}"
assert_eq "intent_verify_directive parsed" "on" "${OMC_INTENT_VERIFY_DIRECTIVE}"
rm -f "${_test_conf}"

# Invalid value rejection — should keep the previous value.
_test_conf="$(mktemp -t bias-defense-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
metis_on_plan_gate=garbage
EOF
_omc_env_metis_on_plan_gate=""
OMC_METIS_ON_PLAN_GATE="off"
_parse_conf_file "${_test_conf}"
assert_eq "garbage value rejected" "off" "${OMC_METIS_ON_PLAN_GATE}"
rm -f "${_test_conf}"

# ----------------------------------------------------------------------
printf 'Test 10: env var precedence over conf for new bias-defense keys\n'
# The _omc_env_* guards should make env-var values stick even when the
# conf file specifies a different value (F-6 from reviewer).
_test_conf="$(mktemp -t bias-defense-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
metis_on_plan_gate=off
prometheus_suggest=off
intent_verify_directive=off
EOF
# Simulate "env var was set" by populating the snapshot guards before
# parse. With the guard non-empty, _parse_conf_file must NOT overwrite
# OMC_*.
_omc_env_metis_on_plan_gate="on"
_omc_env_prometheus_suggest="on"
_omc_env_intent_verify_directive="on"
OMC_METIS_ON_PLAN_GATE="on"
OMC_PROMETHEUS_SUGGEST="on"
OMC_INTENT_VERIFY_DIRECTIVE="on"
_parse_conf_file "${_test_conf}"
assert_eq "env wins over conf metis"     "on" "${OMC_METIS_ON_PLAN_GATE}"
assert_eq "env wins over conf prometheus" "on" "${OMC_PROMETHEUS_SUGGEST}"
assert_eq "env wins over conf intent"    "on" "${OMC_INTENT_VERIFY_DIRECTIVE}"
rm -f "${_test_conf}"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
