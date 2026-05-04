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
# Test 11 (v1.23.0): is_exemplifying_request positive cases
#
# Detects when the user has phrased scope using example markers — the
# example is one item from a class, not the literal scope. Symmetric
# to is_product_shaped_request / is_ambiguous_execution_request: those
# defend against over-commitment; this defends against under-commitment.
printf 'Test 11: is_exemplifying_request positive cases (v1.23.0)\n'
assert_true "user verbatim — for instance"   'is_exemplifying_request "/ulw can the status line be enhanced for better ux? For instance, adding the information when will the limits be reset."'
assert_true "for instance, ..."              'is_exemplifying_request "improve dashboards, for instance the search filters"'
assert_true "e.g."                           'is_exemplifying_request "expand error states, e.g. 404 and 500"'
assert_true "i.e."                           'is_exemplifying_request "fix the off-by-one, i.e. the parser bug"'
assert_true "for example"                    'is_exemplifying_request "support more locales, for example fr-CA"'
assert_true "such as"                        'is_exemplifying_request "ship error states such as 404 and 500"'
assert_true "as needed (user verbatim)"      'is_exemplifying_request "Implement and commit as needed"'
assert_true "as appropriate"                 'is_exemplifying_request "Polish the inputs as appropriate"'
assert_true "similar to"                     'is_exemplifying_request "Build a tracker similar to Linear"'
assert_true "including but not limited to"   'is_exemplifying_request "Add features including but not limited to search"'
assert_true "things like"                    'is_exemplifying_request "things like search and filter"'
assert_true "stuff like"                     'is_exemplifying_request "stuff like the toast and the modal"'
assert_true "examples include"               'is_exemplifying_request "ship error states. examples include 404 and 500"'
assert_true "examples are"                   'is_exemplifying_request "examples are the dashboard and the toast"'
assert_true "examples of"                    'is_exemplifying_request "examples of class items: badges, indicators"'

# ----------------------------------------------------------------------
# Test 12: is_exemplifying_request negative cases
#
# Critical anti-false-positive: the standalone "like X" pattern was
# considered but rejected because "things I like about this code" has
# `like` as a verb. The negatives below lock in that trade-off.
printf 'Test 12: is_exemplifying_request negative cases\n'
assert_false "things I like (verb usage)"    'is_exemplifying_request "Things I like about this codebase: the naming"'
assert_false "I likewise (false-friend)"     'is_exemplifying_request "I likewise prefer the existing format"'
assert_false "no example markers"            'is_exemplifying_request "Fix the auth bug in login.tsx"'
assert_false "no example markers (long)"     'is_exemplifying_request "Refactor the database layer to use Prisma instead of raw SQL"'
assert_false "make a panel like the dash"    'is_exemplifying_request "make a panel like the dashboard"'
assert_false "empty string"                  'is_exemplifying_request ""'

# ----------------------------------------------------------------------
# Test 13: conf parser wires v1.23.0+ exemplifying / prompt-text flags
printf 'Test 13: conf parser wires exemplifying / prompt-text / defer flags\n'
_test_conf="$(mktemp -t bias-defense-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
exemplifying_directive=off
exemplifying_scope_gate=off
prompt_text_override=off
mark_deferred_strict=off
EOF
_omc_env_exemplifying_directive=""
_omc_env_exemplifying_scope_gate=""
_omc_env_prompt_text_override=""
_omc_env_mark_deferred_strict=""
OMC_EXEMPLIFYING_DIRECTIVE="on"
OMC_EXEMPLIFYING_SCOPE_GATE="on"
OMC_PROMPT_TEXT_OVERRIDE="on"
OMC_MARK_DEFERRED_STRICT="on"
_parse_conf_file "${_test_conf}"
assert_eq "exemplifying_directive parsed" "off" "${OMC_EXEMPLIFYING_DIRECTIVE}"
assert_eq "exemplifying_scope_gate parsed" "off" "${OMC_EXEMPLIFYING_SCOPE_GATE}"
assert_eq "prompt_text_override parsed"   "off" "${OMC_PROMPT_TEXT_OVERRIDE}"
assert_eq "mark_deferred_strict parsed"   "off" "${OMC_MARK_DEFERRED_STRICT}"
rm -f "${_test_conf}"

# Env var precedence — env wins over conf.
_test_conf="$(mktemp -t bias-defense-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
exemplifying_directive=off
exemplifying_scope_gate=off
prompt_text_override=off
mark_deferred_strict=off
EOF
_omc_env_exemplifying_directive="on"
_omc_env_exemplifying_scope_gate="on"
_omc_env_prompt_text_override="on"
_omc_env_mark_deferred_strict="on"
OMC_EXEMPLIFYING_DIRECTIVE="on"
OMC_EXEMPLIFYING_SCOPE_GATE="on"
OMC_PROMPT_TEXT_OVERRIDE="on"
OMC_MARK_DEFERRED_STRICT="on"
_parse_conf_file "${_test_conf}"
assert_eq "env wins over conf — exemplifying" "on" "${OMC_EXEMPLIFYING_DIRECTIVE}"
assert_eq "env wins over conf — scope gate"   "on" "${OMC_EXEMPLIFYING_SCOPE_GATE}"
assert_eq "env wins over conf — prompt-text"  "on" "${OMC_PROMPT_TEXT_OVERRIDE}"
assert_eq "env wins over conf — mark-defer"   "on" "${OMC_MARK_DEFERRED_STRICT}"
rm -f "${_test_conf}"

# ----------------------------------------------------------------------
# v1.26.0 — is_completeness_request positive cases
#
# The broader trigger that addresses the iOS-orphan-files failure pattern:
# the model declares "clean" from absence of known-bads instead of
# enumerating the search universe and verifying each candidate. This
# predicate generalizes is_exemplifying_request to fire on completeness
# vocabulary even without an example marker — the failure shape that
# "anything else to clean up?" (sans 'for instance') exhibits today.
printf 'Test 14: is_completeness_request positive cases (completeness verbs)\n'
assert_true "anything else"               'is_completeness_request "Anything else that we need to clean up?"'
assert_true "anything missing"            'is_completeness_request "Is anything missing from the migration?"'
assert_true "anything left"               'is_completeness_request "anything left to wire up before we ship?"'
assert_true "any other surfaces"          'is_completeness_request "are there any other surfaces affected by this change?"'
assert_true "any other orphan files"      'is_completeness_request "Are there any other orphan files in the repo?"'
assert_true "any other consumers"         'is_completeness_request "any other consumers of UserService still in tree?"'
assert_true "any other references"        'is_completeness_request "any other references to support.html still around?"'
assert_true "find all unused"             'is_completeness_request "Find all unused exports"'
assert_true "all the orphan paths"        'is_completeness_request "list all the orphan paths in the bundle"'
assert_true "all the unused"              'is_completeness_request "kill all the unused tests"'
assert_true "is it clean"                 'is_completeness_request "Is everything clean?"'
assert_true "is it complete"              'is_completeness_request "is the migration complete?"'
assert_true "is it ready"                 'is_completeness_request "is the deployment ready?"'
assert_true "is it safe"                  'is_completeness_request "is the bundle safe to ship?"'
assert_true "did you cover"               'is_completeness_request "Did you cover all the edge cases?"'
assert_true "did you check"               'is_completeness_request "did you check the rollback path?"'
assert_true "did you verify"              'is_completeness_request "did you verify the fixture loaded?"'
assert_true "did you miss"                'is_completeness_request "did we miss any callers?"'
assert_true "exhaustive audit"            'is_completeness_request "run an exhaustive audit of the privacy surfaces"'
assert_true "exhaustive sweep"            'is_completeness_request "do an exhaustive sweep of the bundle"'
assert_true "full inventory"              'is_completeness_request "give me a full inventory of the assets"'
assert_true "enumerate every"             'is_completeness_request "enumerate every consumer of this hook"'
assert_true "every reference"             'is_completeness_request "walk every reference to AuthClient in the codebase"'
assert_true "orphan files"                'is_completeness_request "are there orphan files left after the cleanup?"'
assert_true "orphaned references"         'is_completeness_request "any orphaned references after the rename?"'

# Excellence-reviewer F-1: sibling phrasings the iOS-prompt-tuned regex
# initially missed. The veteran-realistic set the user would expect to
# fire under the same failure mode but with naturally-different syntax.
# Each pattern below was added to the alternation explicitly to close
# that gap and locks in the broader trigger surface so future edits
# cannot accidentally re-narrow it.
assert_true "are we good to ship"         'is_completeness_request "are we good to ship?"'
assert_true "are we good to merge"        'is_completeness_request "are we ready to merge?"'
assert_true "good to deploy"              'is_completeness_request "good to deploy now?"'
assert_true "have we got everything"      'is_completeness_request "have we got everything?"'
assert_true "have we got coverage"        'is_completeness_request "have we got enough coverage?"'
assert_true "have we covered all cases"   'is_completeness_request "have we covered all cases?"'
assert_true "have we missed anything"     'is_completeness_request "have we missed anything important?"'
assert_true "have we forgotten any"       'is_completeness_request "have we forgotten any consumer?"'
assert_true "should anything be removed"  'is_completeness_request "should anything be removed?"'
assert_true "should anything else"        'is_completeness_request "should anything else be cleaned up?"'
assert_true "verify nothing is left"      'is_completeness_request "verify nothing is left over"'
assert_true "is everything wired up"      'is_completeness_request "is everything wired up?"'
assert_true "is everything hooked up"     'is_completeness_request "is everything hooked up?"'
assert_true "is everything accounted"     'is_completeness_request "is everything accounted for?"'
assert_true "is the system sorted"        'is_completeness_request "is the system sorted?"'
assert_true "is the system finalized"     'is_completeness_request "is the migration finalized?"'
assert_true "do you have full coverage"   'is_completeness_request "do you have full coverage of edge cases?"'
assert_true "does it have full inventory" 'is_completeness_request "does it have a full inventory of consumers?"'
assert_true "we have full tests"          'is_completeness_request "do we have complete tests?"'
assert_true "any leftover files"          'is_completeness_request "are there any leftover files?"'
assert_true "any dangling references"     'is_completeness_request "any dangling references?"'
assert_true "any stray paths"             'is_completeness_request "any stray paths in the bundle?"'
assert_true "any orphan entries"          'is_completeness_request "any orphan entries left in the manifest?"'
assert_true "any unused exports"          'is_completeness_request "any unused exports remaining?"'
assert_true "any callers we forgot"       'is_completeness_request "any callers we forgot?"'
assert_true "any tests we skipped"        'is_completeness_request "any tests we skipped?"'
assert_true "nothing else"                'is_completeness_request "nothing else to do?"'
assert_true "nothing left over"           'is_completeness_request "nothing left over after the cleanup?"'
assert_true "nothing remaining"           'is_completeness_request "nothing remaining to address?"'
assert_true "nothing outstanding"         'is_completeness_request "nothing outstanding for the release?"'
assert_true "did anything slip"           'is_completeness_request "did anything slip through?"'
assert_true "did anything fall through"   'is_completeness_request "did anything fall through the cracks?"'
assert_true "did you skip"                'is_completeness_request "did you skip any callers?"'
assert_true "did you overlook"            'is_completeness_request "did you overlook the rollback path?"'
assert_true "did you forget"              'is_completeness_request "did you forget anything important?"'
assert_true "full cleanup"                'is_completeness_request "do a full cleanup of the assets directory"'
assert_true "slipped through"             'is_completeness_request "anything that slipped through the cracks?"'

# v1.26.0 — exemplifying subset still matches (backward compat)
printf 'Test 15: is_completeness_request preserves is_exemplifying_request matches\n'
assert_true "for instance"                'is_completeness_request "enhance the statusline, for instance adding reset countdown"'
assert_true "e.g."                        'is_completeness_request "add admin tooling, e.g. user impersonation"'
assert_true "such as"                     'is_completeness_request "polish the docs such as the install section"'
assert_true "things like"                 'is_completeness_request "fix things like the broken links"'
assert_true "ios session prompt"          'is_completeness_request "Anything else that we need to clean up or set up before embarking on actually improving the app? for instance, shouldn'\''t the support.html be cleaned up as well?"'

# v1.26.0 — casual / unrelated phrasings should NOT match
printf 'Test 16: is_completeness_request negative cases (casual / unrelated)\n'
assert_false "casual: latest on build"    'is_completeness_request "what'\''s the latest on the build?"'
assert_false "casual: status going on"    'is_completeness_request "what'\''s going on with the deploy?"'
assert_false "casual: anything I should"  'is_completeness_request "anything I should know about this codebase?"'
assert_false "casual: any thoughts"       'is_completeness_request "any thoughts on this approach?"'
assert_false "casual: how is it going"    'is_completeness_request "how is it going with the migration?"'
assert_false "casual: quick question"     'is_completeness_request "quick question about the migration"'
assert_false "code anchor: parse.ts"      'is_completeness_request "fix the off-by-one in parse.ts:42"'
assert_false "feature: build app"         'is_completeness_request "build a habit tracker app"'
assert_false "general: how to structure"  'is_completeness_request "how should I structure this?"'
assert_false "empty"                      'is_completeness_request ""'
assert_false "single word"                'is_completeness_request "yes"'
# Negative cases that share words but lack the specific tail.
assert_false "any (no specific noun)"     'is_completeness_request "any chance you can look at this?"'
assert_false "all (no completeness adj)" 'is_completeness_request "all the kids love it"'
# "is it good" not in the cleanliness adjective set
assert_false "is it good"                 'is_completeness_request "is it good?"'
# F-1 negative cases — locked in to make sure the broader regex did not
# over-fire on near-neighbor casual phrasings.
assert_false "have we got time"           'is_completeness_request "have we got time for this?"'
assert_false "have we eaten"              'is_completeness_request "have we eaten lunch yet?"'
assert_false "are we good (bare)"         'is_completeness_request "are we good?"'
assert_false "are we ok"                  'is_completeness_request "are we ok with this approach?"'
assert_false "nothing matters"            'is_completeness_request "nothing matters here"'
assert_false "have you tried"             'is_completeness_request "have you tried restarting?"'
assert_false "do you have time"           'is_completeness_request "do you have time for a quick call?"'
assert_false "did you sleep"              'is_completeness_request "did you sleep well?"'
assert_false "any reason"                 'is_completeness_request "any reason to keep this?"'
assert_false "should I add"               'is_completeness_request "should I add a test for this?"'
assert_false "verify the connection"      'is_completeness_request "verify the connection works"'

# ----------------------------------------------------------------------
# v1.32.0 — is_paradigm_ambiguous_request positive cases
#
# Detects when the prompt names a paradigm-shape decision the model is
# at risk of anchoring on the first-paradigm-that-surfaces. Symmetric to
# is_completeness_request but on a third axis (paradigm enumeration vs
# scope-width or scope-narrowness).
printf 'Test 17: is_paradigm_ambiguous_request positive cases (v1.32.0)\n'
# Signal A — explicit X vs Y / X-or-Y choice.
assert_true "X vs Y"                       'is_paradigm_ambiguous_request "websockets vs polling for the live status feed"'
assert_true "X versus Y"                   'is_paradigm_ambiguous_request "monolith versus microservices for this team"'
assert_true "should I use X or Y"          'is_paradigm_ambiguous_request "should I use Redux or Context for the global state"'
assert_true "should we pick X or Y"        'is_paradigm_ambiguous_request "should we pick GraphQL or REST for the API"'
assert_true "backticked X vs Y"            'is_paradigm_ambiguous_request "should I use \`Redux\` or \`Context\` for state management"'
# Signal B — open-ended shape question.
assert_true "how should we"                'is_paradigm_ambiguous_request "how should we handle rate limit retries"'
assert_true "how do we"                    'is_paradigm_ambiguous_request "how do we model the auth state machine"'
assert_true "how can we"                   'is_paradigm_ambiguous_request "how can we structure the bootstrap pipeline"'
assert_true "how might we"                 'is_paradigm_ambiguous_request "how might we approach the resume-watchdog daemon"'
assert_true "how would you"                'is_paradigm_ambiguous_request "how would you architect this caching layer"'
# Signal C — superlative + paradigm noun.
assert_true "best way to model"            'is_paradigm_ambiguous_request "what is the best way to model auth state"'
assert_true "right approach"               'is_paradigm_ambiguous_request "what is the right approach for retrying API calls"'
assert_true "cleanest pattern"             'is_paradigm_ambiguous_request "what is the cleanest pattern for the cache layer"'
assert_true "optimal architecture"         'is_paradigm_ambiguous_request "what is the optimal architecture for multi-tenant data"'
assert_true "simplest design"              'is_paradigm_ambiguous_request "what is the simplest design for the wizard"'
# Signal D — paradigm-decision verb + abstract noun.
assert_true "design the strategy"          'is_paradigm_ambiguous_request "design the auth strategy for a multi-tenant rollout"'
assert_true "architect the system"         'is_paradigm_ambiguous_request "architect the resume system end to end"'
assert_true "model the state machine"      'is_paradigm_ambiguous_request "model the wizard state machine"'
assert_true "design the pattern"           'is_paradigm_ambiguous_request "design the retry pattern for outbound webhooks"'
assert_true "structure the data flow"      'is_paradigm_ambiguous_request "structure the data flow between the ingestion services"'
# Signal E — explicit retrospective.
assert_true "is there a better way"        'is_paradigm_ambiguous_request "is there a better way to handle this caching"'
# Signal F — paradigm-shift / adoption decisions (post-excellence-reviewer F-3).
# Senior-engineer paradigm shapes the v1.32.0-pre regex silently missed.
assert_true "thinking about migrating from X to Y" \
                                           'is_paradigm_ambiguous_request "thinking about migrating from Postgres to DynamoDB"'
assert_true "should I migrate from X to Y" \
                                           'is_paradigm_ambiguous_request "should I migrate from monolith to microservices"'
assert_true "consider switching to X"      'is_paradigm_ambiguous_request "consider switching to event sourcing"'
assert_true "should we move from X to Y"   'is_paradigm_ambiguous_request "should we move from REST to GraphQL"'
assert_true "thinking about adopting X"    'is_paradigm_ambiguous_request "thinking about adopting CQRS for the orders module"'
assert_true "considering moving to X"      'is_paradigm_ambiguous_request "considering moving to a CRDT-backed store"'
assert_true "what pattern fits X"          'is_paradigm_ambiguous_request "What pattern fits this state propagation?"'
assert_true "which pattern fits X"         'is_paradigm_ambiguous_request "which pattern fits the multi-tenant case best"'

# ----------------------------------------------------------------------
# v1.32.0 — is_paradigm_ambiguous_request negative cases
printf 'Test 18: is_paradigm_ambiguous_request negative cases (v1.32.0)\n'
# Disqualifier 1 — bug-fix vocabulary.
assert_false "fix the bug"                 'is_paradigm_ambiguous_request "fix the off-by-one bug in the parser"'
assert_false "hotfix"                      'is_paradigm_ambiguous_request "hotfix the auth flow before the release"'
assert_false "patch the issue"             'is_paradigm_ambiguous_request "patch the dashboard scrollbar issue"'
assert_false "broken"                      'is_paradigm_ambiguous_request "the rate limit handler is broken on retries"'
assert_false "failing test"                'is_paradigm_ambiguous_request "the failing test in lib/auth needs investigation"'
assert_false "crash"                       'is_paradigm_ambiguous_request "the resume watchdog crashes on null artifact"'
# Disqualifier 2 — code anchor without X-vs-Y.
assert_false "file path anchor"            'is_paradigm_ambiguous_request "edit lib/parse.ts to add logging"'
assert_false "function anchor"             'is_paradigm_ambiguous_request "rewrite the foo() helper for performance"'
assert_false "extensionless multi-path"    'is_paradigm_ambiguous_request "refactor src/services/auth using the existing helpers"'
assert_false "backtick non-vs prompt"      'is_paradigm_ambiguous_request "edit \`bar.sh\` to add the new flag"'
# Negative — no positive signals at all.
assert_false "build a chat app"            'is_paradigm_ambiguous_request "build a chat app for my team"'
assert_false "rename function"             'is_paradigm_ambiguous_request "rename getUser to fetchUser everywhere"'
assert_false "add a button"                'is_paradigm_ambiguous_request "add a logout button to the dashboard"'
assert_false "implement using named pat"   'is_paradigm_ambiguous_request "implement caching using LRU pattern in src/cache.ts"'
assert_false "ship the commit"             'is_paradigm_ambiguous_request "ship the commit on main"'
assert_false "empty string"                'is_paradigm_ambiguous_request ""'
# Negative — false-friend "design" with concrete object (not abstract noun).
assert_false "design a button"             'is_paradigm_ambiguous_request "design a logout button for the header"'

# v1.32.0 quality-reviewer regression net (F-1, F-2, F-3).
# Each assertion locks in a fix for a confirmed false-positive shape so
# a future regex tweak that re-introduces the false-positive breaks CI
# before the noisy directive injection ships.
assert_false "F-1: bare vs with proper noun" \
                                           'is_paradigm_ambiguous_request "Tom vs Jerry compare them"'
assert_false "F-1: git CLI shape vs"       'is_paradigm_ambiguous_request "git rebase main vs feature"'
assert_false "F-1: compare X vs Y casually" \
                                           'is_paradigm_ambiguous_request "compare apples vs oranges in the demo"'
assert_false "F-2: issue + how should we"  'is_paradigm_ambiguous_request "the auth issue keeps surfacing how should we model retries"'
assert_false "F-2: bare issue keyword"     'is_paradigm_ambiguous_request "track this issue and how should we approach it"'
assert_false "F-3: design build pipeline"  'is_paradigm_ambiguous_request "design the build pipeline for the new monorepo"'
assert_false "F-3: design release workflow" \
                                           'is_paradigm_ambiguous_request "design the release workflow for our team"'
assert_false "F-3: structure data lifecycle" \
                                           'is_paradigm_ambiguous_request "structure the data lifecycle in the worker"'
# Signal F discriminator regression net (post-excellence-reviewer F-3):
# Verbs in Signal F (migrate / switch / move / adopt) match paradigm
# decisions only when "from X to Y" or "consider/thinking-about" framing
# is present. Bare "should I migrate" without from/to is a timing
# question, not a paradigm choice.
assert_false "Signal F: migrate without from/to (timing question)" \
                                           'is_paradigm_ambiguous_request "should I migrate the database now"'
assert_false "Signal F: consider adding (verb not in adoption set)" \
                                           'is_paradigm_ambiguous_request "consider adding logging to the worker"'
assert_false "Signal F: thinking about non-adoption noun" \
                                           'is_paradigm_ambiguous_request "thinking about a beach vacation"'
assert_false "Signal F: what pattern works (not fits)" \
                                           'is_paradigm_ambiguous_request "what pattern works for everyone"'
assert_false "Signal F: bare move without from/to" \
                                           'is_paradigm_ambiguous_request "let me move the file to the new directory"'

# ----------------------------------------------------------------------
# v1.32.0 — divergence_directive conf parser wiring
printf 'Test 19: conf parser wires divergence_directive flag\n'
_test_conf="$(mktemp -t divergence-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
divergence_directive=off
EOF
_omc_env_divergence_directive=""
OMC_DIVERGENCE_DIRECTIVE="on"
_parse_conf_file "${_test_conf}"
assert_eq "divergence_directive parsed from conf" "off" "${OMC_DIVERGENCE_DIRECTIVE}"
rm -f "${_test_conf}"

# Env var precedence — env wins over conf.
_test_conf="$(mktemp -t divergence-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
divergence_directive=off
EOF
_omc_env_divergence_directive="on"
OMC_DIVERGENCE_DIRECTIVE="on"
_parse_conf_file "${_test_conf}"
assert_eq "env wins over conf — divergence" "on" "${OMC_DIVERGENCE_DIRECTIVE}"
rm -f "${_test_conf}"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
