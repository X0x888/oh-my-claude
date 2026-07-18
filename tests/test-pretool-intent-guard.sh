#!/usr/bin/env bash
# test-pretool-intent-guard.sh — focused regression for pretool-intent-guard.sh.
#
# Coverage:
#   - intent classification × destructive-command outcome (control + regression)
#   - wave-execution override (the v1.21.0 fix for the "single yes reauthorizes
#     commit" anti-pattern: when a council Phase 8 wave plan is active, a
#     system-injected advisory frame must not block the user's already-
#     authorized per-wave commits)
#   - freshness gate (stale findings.json does NOT trigger the override; TTL=0
#     is a true kill-switch that handles the age=0 same-second edge case)
#   - configurable TTL via env AND via oh-my-claude.conf (the conf path is
#     wired through common.sh's parser)
#   - block-reason text never contains the disturbing rephrasings the user
#     reported ("say yes", "single yes", "reauthorize", "confirm with yes")
#     and DOES include the corrective guidance ("propose a concrete imperative")
#   - kill-switch (OMC_PRETOOL_INTENT_GUARD=false) disables intent denial while
#     leaving the independent mutation-baseline producer active
#
# This file complements the broader e2e Gap 8 coverage in
# test-e2e-hook-sequence.sh; it isolates the gate so failures point at the
# gate itself, not at compact-handoff plumbing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

ORIG_HOME="${HOME}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
  # v1.43+: the agent-first gate's BLOCK is opt-in (default off). The
  # T0a-T0c8 cases (and any other test that expects pre-specialist
  # mutation to be denied) need the gate explicitly ON to preserve
  # their original semantics. Tests that exercise the new default-off
  # behavior (T_aff_off_*) override this with `unset OMC_AGENT_FIRST_GATE`
  # before calling run_guard.
  export OMC_AGENT_FIRST_GATE=on
}

teardown_test() {
  export HOME="${ORIG_HOME}"
  unset OMC_AGENT_FIRST_GATE
  rm -rf "${TEST_HOME}" 2>/dev/null || true
}

cleanup() { teardown_test; }
trap cleanup EXIT

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
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %q\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains_ci() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qiF -- "${needle}" <<<"${haystack}"; then
    printf '  FAIL: %s\n    expected NOT to contain (case-insensitive): %q\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

# Initialize a session with a given task_intent. Mirrors the e2e harness so
# tests can be cross-read against test-e2e-hook-sequence.sh Gap 8.
init_session() {
  local sid="$1" intent="$2"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${state_dir}"
  jq -nc --arg intent "${intent}" --arg ts "$(date +%s)" '{
    workflow_mode: "ultrawork",
    task_domain: "coding",
    task_intent: $intent,
    current_objective: "test",
    last_user_prompt_ts: $ts
  }' > "${state_dir}/session_state.json"
}

set_commit_mode() {
  local sid="$1" mode="$2"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq --arg mode "${mode}" '. + {done_contract_commit_mode:$mode}' \
    "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
    && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
}

# v1.34.0 (Bug C): push-side contract is independent of commit-side.
set_push_mode() {
  local sid="$1" mode="$2"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq --arg mode "${mode}" '. + {done_contract_push_mode:$mode}' \
    "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
    && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
}

set_agent_first_satisfied() {
  local sid="$1" agent="${2:-quality-planner}"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq --arg agent "${agent}" --arg ts "$(date +%s)" \
    '. + {agent_first_specialist_ts:$ts, agent_first_specialist_type:$agent}' \
    "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
    && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
}

read_state_key() {
  local sid="$1" key="$2"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq -r --arg key "${key}" '.[$key] // ""' "${state_dir}/session_state.json" 2>/dev/null || true
}

# Seed findings.json with the given waves[] payload. Each call replaces the
# whole document — tests describe the wave-state they care about explicitly.
# Optional 3rd arg overrides updated_ts so tests can simulate a stale plan.
seed_findings() {
  local sid="$1" waves_json="$2" override_ts="${3:-}"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  local ts="${override_ts:-$(date +%s)}"
  jq -n --argjson waves "${waves_json}" --arg ts "${ts}" '{
    version: 1,
    created_ts: ($ts | tonumber),
    updated_ts: ($ts | tonumber),
    findings: [],
    waves: $waves
  }' > "${state_dir}/findings.json"
}

# Seed the recent_prompts.jsonl file with a single prompt entry. The
# Wave 2 prompt-text trust override reads `tail -n 1` of this file as
# the most recent user prompt and decides whether the prompt text
# unambiguously authorizes the destructive verb being attempted.
seed_recent_prompt() {
  local sid="$1" text="$2"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq -nc --arg ts "$(date +%s)" --arg t "${text}" \
    '{ts: $ts, text: $t}' > "${state_dir}/recent_prompts.jsonl"
}

run_guard() {
  local sid="$1" cmd="$2" tool="${3:-Bash}"
  local payload
  if [[ "${tool}" == "Bash" ]]; then
    payload="$(jq -nc --arg s "${sid}" --arg c "${cmd}" '{
      session_id: $s,
      tool_name: "Bash",
      tool_input: {command: $c},
      hook_event_name: "PreToolUse"
    }')"
  else
    payload="$(jq -nc --arg s "${sid}" --arg t "${tool}" '{
      session_id: $s,
      tool_name: $t,
      tool_input: {},
      hook_event_name: "PreToolUse"
    }')"
  fi
  printf '%s' "${payload}" | bash "${HOOK_SCRIPT}" 2>/dev/null || true
}

denied() {
  local out="$1"
  [[ -n "${out}" ]] && grep -q '"permissionDecision":"deny"' <<<"${out}"
}

# ----------------------------------------------------------------------
# T0a: execution intent + Edit before any specialist → agent-first deny
setup_test
init_session "t0a" "execution"
out_t0a="$(run_guard "t0a" "" "Edit")"
if denied "${out_t0a}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0a: execution + Edit before specialist must be denied (got: %s)\n' "${out_t0a}" >&2
  fail=$((fail + 1))
fi
assert_contains "T0a: deny reason names agent-first gate" "Agent-first gate" "${out_t0a}"
teardown_test

# ----------------------------------------------------------------------
# T0b: execution intent + mutating Bash before any specialist → agent-first deny
setup_test
init_session "t0b" "execution"
out_t0b="$(run_guard "t0b" "touch /tmp/omc-agent-first-test")"
if denied "${out_t0b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0b: execution + mutating Bash before specialist must be denied (got: %s)\n' "${out_t0b}" >&2
  fail=$((fail + 1))
fi
assert_contains "T0b: deny reason includes attempted Bash mutation" "Attempted mutation: Bash:" "${out_t0b}"
teardown_test

# ----------------------------------------------------------------------
# T0c: execution intent + read-only Bash before any specialist → allow
setup_test
init_session "t0c" "execution"
out_t0c="$(run_guard "t0c" "git status 2>/dev/null")"
assert_eq "T0c: read-only Bash allowed before specialist" "" "${out_t0c}"
teardown_test

# ----------------------------------------------------------------------
# T0c1..T0c8 (v1.41.x harness-improvement wave): `git tag` list-mode
# inspection must pass the agent-first floor. Mirrors the advisory
# matcher's allow-list at _cmd_is_allowed_variant (:311). Reported
# false-positive: `git tag --sort=-creatordate | head -5 && git status
# --short` was blocked on a session-start inspection burst even though
# every segment is read-only. Closes the v1.41.0 "Read-only inspection
# still passes" contract gap for the tag verb.
#
# Lock the allowed list-mode forms in (T0c1-T0c5) AND lock the still-
# denied create/mutation forms (T0c6-T0c8) so the narrowed regex
# doesn't drift back into letting `git tag <name>` through.
setup_test
init_session "t0c1" "execution"
out_t0c1="$(run_guard "t0c1" "git tag --sort=-creatordate | head -5")"
assert_eq "T0c1: git tag --sort allowed (original false-positive)" "" "${out_t0c1}"
teardown_test

setup_test
init_session "t0c2" "execution"
out_t0c2="$(run_guard "t0c2" "git tag --list 'v*'")"
assert_eq "T0c2: git tag --list allowed" "" "${out_t0c2}"
teardown_test

setup_test
init_session "t0c3" "execution"
out_t0c3="$(run_guard "t0c3" "git tag --contains HEAD")"
assert_eq "T0c3: git tag --contains allowed" "" "${out_t0c3}"
teardown_test

setup_test
init_session "t0c4" "execution"
out_t0c4="$(run_guard "t0c4" "git tag -n5")"
assert_eq "T0c4: git tag -n5 allowed (list with annotations)" "" "${out_t0c4}"
teardown_test

setup_test
init_session "t0c5" "execution"
out_t0c5="$(run_guard "t0c5" "git tag -v v1.41.0")"
assert_eq "T0c5: git tag -v allowed (signature verify, read-only)" "" "${out_t0c5}"
teardown_test

setup_test
init_session "t0c6" "execution"
out_t0c6="$(run_guard "t0c6" "git tag v9.9.9")"
if denied "${out_t0c6}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c6: git tag <name> must still deny before specialist (got: %s)\n' "${out_t0c6}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t0c7" "execution"
out_t0c7="$(run_guard "t0c7" "git tag -a v1.0.0 -m 'release'")"
if denied "${out_t0c7}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c7: git tag -a (annotate-create) must still deny (got: %s)\n' "${out_t0c7}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t0c8" "execution"
out_t0c8="$(run_guard "t0c8" "git tag --delete v1.0.0")"
if denied "${out_t0c8}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c8: git tag --delete must still deny (got: %s)\n' "${out_t0c8}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T0c9 (quality-reviewer F1 HIGH): top-level git flag must not bypass
# the floor. Without _normalize_git_flags on the floor path,
# `git --no-pager tag v1.0` slipped through because the outer regex
# requires `tag` immediately after `git`. The fix normalizes the
# command first (sharing the same pass the advisory matcher at :366
# uses), so this and `git -c user.email=x commit` correctly deny.
setup_test
init_session "t0c9" "execution"
out_t0c9="$(run_guard "t0c9" "git --no-pager tag v1.0.0")"
if denied "${out_t0c9}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c9: git --no-pager tag <name> must deny (top-level-flag bypass) (got: %s)\n' "${out_t0c9}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t0c10" "execution"
out_t0c10="$(run_guard "t0c10" "git -c commit.gpgsign=false commit -m 'x'")"
if denied "${out_t0c10}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c10: git -c <override> commit must deny (config-override bypass) (got: %s)\n' "${out_t0c10}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T0c11: a display flag followed by a positional name can create a tag.
# The old first-token regex called this read-only and the ref-only mutation
# never reached edit clocks. The narrow tag parser must deny it at PreTool.
setup_test
init_session "t0c11" "execution"
out_t0c11="$(run_guard "t0c11" "git tag --column always v1.0")"
if denied "${out_t0c11}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c11: --column flag-then-positional tag create must deny (got: %s)\n' "${out_t0c11}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T0c12..T0c17 (v1.48 advisory-path parity): the ADVISORY matcher's
# `_cmd_is_allowed_variant` never inherited the floor's tag
# discrimination — bare `git tag` (pure list form) and `git tag -v`
# (signature verify) required a list-mode flag token and bounced off
# the advisory gate. Observed live: a read-only tag/log inspection
# burst in an advisory-intent session was denied as a "destructive git
# op". Lock the allowed read-only forms under advisory intent AND the
# still-denied create forms, plus the floor's bare-list arm (previously
# untested).
setup_test
init_session "t0c12" "advisory"
out_t0c12="$(run_guard "t0c12" "git tag")"
assert_eq "T0c12: bare git tag allowed under advisory (live false-positive)" "" "${out_t0c12}"
teardown_test

setup_test
init_session "t0c13" "advisory"
out_t0c13="$(run_guard "t0c13" "git tag --sort=-creatordate | head -5 && git status --short")"
assert_eq "T0c13: compound tag-list inspection allowed under advisory" "" "${out_t0c13}"
teardown_test

setup_test
init_session "t0c14" "advisory"
out_t0c14="$(run_guard "t0c14" "git tag -v v1.41.0")"
assert_eq "T0c14: git tag -v allowed under advisory (verify is read-only)" "" "${out_t0c14}"
teardown_test

setup_test
init_session "t0c15" "advisory"
out_t0c15="$(run_guard "t0c15" "git log --tags --simplify-by-decoration --pretty='%d'")"
assert_eq "T0c15: git log --tags allowed under advisory (control)" "" "${out_t0c15}"
teardown_test

setup_test
init_session "t0c16" "advisory"
out_t0c16="$(run_guard "t0c16" "git tag v9.9.9")"
if denied "${out_t0c16}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c16: git tag <name> (create) must still deny under advisory (got: %s)\n' "${out_t0c16}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t0c17" "execution"
out_t0c17="$(run_guard "t0c17" "git tag")"
assert_eq "T0c17: bare git tag allowed at agent-first floor" "" "${out_t0c17}"
teardown_test

setup_test
init_session "t0c18" "advisory"
out_t0c18="$(run_guard "t0c18" "git tag --sort=-creatordate v9.9.9")"
if denied "${out_t0c18}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c18: --sort flag-then-positional tag create must deny under advisory (got: %s)\n' "${out_t0c18}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t0c19" "execution"
out_t0c19="$(run_guard "t0c19" "git tag --ignore-case --force v9.9.9")"
if denied "${out_t0c19}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c19: --ignore-case must not hide forced tag creation (got: %s)\n' "${out_t0c19}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t0c20" "advisory"
out_t0c20="$(run_guard "t0c20" "git tag -i -d v9.9.9")"
if denied "${out_t0c20}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T0c20: -i must not hide tag deletion under advisory intent (got: %s)\n' "${out_t0c20}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T0c21..T0c24: shell separators inside a quoted --format value are data,
# not compound-command boundaries. The pre-v1.50 sed splitter cut the tag
# segment at those bytes, let the truncated display form through, and hid a
# following positional tag name. Keep the pure display form friction-free,
# but deny every quoted-separator create form.
setup_test
init_session "t0c21" "advisory"
out_t0c21="$(run_guard "t0c21" "git tag --format='foo|bar;baz&&qux'")"
assert_eq "T0c21: quoted separators in display-only tag format stay read-only" "" "${out_t0c21}"
teardown_test

for tag_case in pipe semicolon andand; do
  setup_test
  init_session "t0c-${tag_case}" "advisory"
  case "${tag_case}" in
    pipe) tag_command="git tag --format='foo|bar' newtag" ;;
    semicolon) tag_command="git tag --format='foo;bar' newtag" ;;
    andand) tag_command="git tag --format='foo&&bar' newtag" ;;
  esac
  tag_out="$(run_guard "t0c-${tag_case}" "${tag_command}")"
  if denied "${tag_out}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T0c quoted-%s format cannot hide positional tag creation (got: %s)\n' \
      "${tag_case}" "${tag_out}" >&2
    fail=$((fail + 1))
  fi
  teardown_test
done

for intent_case in advisory execution; do
  setup_test
  init_session "t0c-background-${intent_case}" "${intent_case}"
  background_out="$(run_guard "t0c-background-${intent_case}" "git tag --list & git tag newtag")"
  if denied "${background_out}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T0c top-level &: background tag creation must deny under %s (got: %s)\n' \
      "${intent_case}" "${background_out}" >&2
    fail=$((fail + 1))
  fi
  teardown_test
done

# Command-like prose is not execution evidence. Pin quoted, unquoted, and
# embedded-newline arguments so matcher regexes cannot drift back to scanning
# arbitrary argv positions.
for fake_case in quoted_tag quoted_commit unquoted_tag unquoted_commit newline_tag; do
  setup_test
  init_session "t0c-fake-${fake_case}" "advisory"
  case "${fake_case}" in
    quoted_tag) fake_command='echo "prefix git tag v1"' ;;
    quoted_commit) fake_command="printf '%s' ' git commit -m x'" ;;
    unquoted_tag) fake_command='echo prefix git tag v1' ;;
    unquoted_commit) fake_command='printf %s git commit -m x' ;;
    newline_tag) fake_command=$'printf "%s" "hello\n git tag v1"' ;;
  esac
  fake_out="$(run_guard "t0c-fake-${fake_case}" "${fake_command}")"
  assert_eq "T0c executable-position negative: ${fake_case}" "" "${fake_out}"
  teardown_test
done

# Read-only/list/dry-run outer commands cannot bless nested executable
# substitutions. The nested program may mutate even though the outer option
# is safe, so advisory and agent-first paths both fail closed.
for substitution_case in dollar_quoted dollar_plain backtick process push_dry; do
  case "${substitution_case}" in
    dollar_quoted) substitution_command='git tag --list "$(git tag newtag)"' ;;
    dollar_plain) substitution_command='git tag --list $(git tag newtag)' ;;
    backtick) substitution_command='git tag --list `git tag newtag`' ;;
    process) substitution_command='git tag --list <(git tag newtag)' ;;
    push_dry) substitution_command='git push --dry-run "$(git push --force)"' ;;
  esac
  for intent_case in advisory execution; do
    setup_test
    init_session "t0c-sub-${substitution_case}-${intent_case}" "${intent_case}"
    substitution_out="$(run_guard "t0c-sub-${substitution_case}-${intent_case}" "${substitution_command}")"
    if denied "${substitution_out}"; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T0c %s substitution must deny under %s (got: %s)\n' \
        "${substitution_case}" "${intent_case}" "${substitution_out}" >&2
      fail=$((fail + 1))
    fi
    teardown_test
  done
done

for wrapper_case in sudo_list env_list sudo_create env_create env_unset env_chdir command_path sudo_noninteractive sudo_end sudo_user_long sudo_login sudo_prompt quoted_path quoted_assignment env_quoted_assignment env_split; do
  setup_test
  init_session "t0c-wrapper-${wrapper_case}" "advisory"
  case "${wrapper_case}" in
    sudo_list) wrapper_command='sudo git tag --list'; wrapper_expect=allow ;;
    env_list) wrapper_command="env git tag --format='foo|bar'"; wrapper_expect=allow ;;
    sudo_create) wrapper_command='sudo git tag wrapped-new'; wrapper_expect=deny ;;
    env_create) wrapper_command="env git tag --format='foo|bar' wrapped-new"; wrapper_expect=deny ;;
    env_unset) wrapper_command='env -u FOO git tag wrapped-new'; wrapper_expect=deny ;;
    env_chdir) wrapper_command='env -C /tmp git tag wrapped-new'; wrapper_expect=deny ;;
    command_path) wrapper_command='command -p git tag wrapped-new'; wrapper_expect=deny ;;
    sudo_noninteractive) wrapper_command='sudo -n git tag wrapped-new'; wrapper_expect=deny ;;
    sudo_end) wrapper_command='sudo -- git tag wrapped-new'; wrapper_expect=deny ;;
    sudo_user_long) wrapper_command='sudo --user root git tag wrapped-new'; wrapper_expect=deny ;;
    sudo_login) wrapper_command='sudo -i git tag wrapped-new'; wrapper_expect=deny ;;
    sudo_prompt) wrapper_command='sudo -p prompt git tag wrapped-new'; wrapper_expect=deny ;;
    quoted_path) wrapper_command="'/usr/bin/git' tag wrapped-new"; wrapper_expect=deny ;;
    quoted_assignment) wrapper_command="FOO='a b' git tag wrapped-new"; wrapper_expect=deny ;;
    env_quoted_assignment) wrapper_command="env 'FOO=a b' git tag wrapped-new"; wrapper_expect=deny ;;
    env_split) wrapper_command="env -S 'git tag wrapped-new'"; wrapper_expect=deny ;;
  esac
  wrapper_out="$(run_guard "t0c-wrapper-${wrapper_case}" "${wrapper_command}")"
  if [[ "${wrapper_expect}" == "allow" ]]; then
    assert_eq "T0c wrapped read-only tag remains allowed: ${wrapper_case}" "" "${wrapper_out}"
  elif denied "${wrapper_out}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T0c wrapped tag creation must deny: %s (got: %s)\n' \
      "${wrapper_case}" "${wrapper_out}" >&2
    fail=$((fail + 1))
  fi
  teardown_test
done

for nested_case in echo_sub printf_sub shell_c eval_body; do
  case "${nested_case}" in
    echo_sub) nested_command='echo "$(git tag nested-tag)"' ;;
    printf_sub) nested_command='printf %s "$(git push --force)"' ;;
    shell_c) nested_command="sh -c 'git tag shell-tag'" ;;
    eval_body) nested_command="eval 'git tag eval-tag'" ;;
  esac
  for intent_case in advisory execution; do
    setup_test
    init_session "t0c-nested-${nested_case}-${intent_case}" "${intent_case}"
    nested_out="$(run_guard "t0c-nested-${nested_case}-${intent_case}" "${nested_command}")"
    if denied "${nested_out}"; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T0c nested %s action must deny under %s (got: %s)\n' \
        "${nested_case}" "${intent_case}" "${nested_out}" >&2
      fail=$((fail + 1))
    fi
    teardown_test
  done
done

# Nested delivery actions must be recognized after ordinary launch wrappers,
# combined shell options, Git top-level options, and env's split-string
# executor. Exercise advisory intent and the independent agent-first floor:
# the execution cases intentionally omit a specialist so their denial must
# name the agent-first gate.
for nested_variant_case in git_option_sub shell_git_option eval_git_option shell_combined timeout_shell wrapped_env_split assigned_env_split quoted_path_sub; do
  case "${nested_variant_case}" in
    git_option_sub) nested_variant_command='echo "$(git -c foo.bar=baz tag nested-tag)"' ;;
    shell_git_option) nested_variant_command="sh -c 'git -c foo.bar=baz tag shell-tag'" ;;
    eval_git_option) nested_variant_command="eval 'git -c foo.bar=baz tag eval-tag'" ;;
    shell_combined) nested_variant_command="bash -lc 'git tag shell-tag'" ;;
    timeout_shell) nested_variant_command="timeout 5 sh -c 'git tag shell-tag'" ;;
    wrapped_env_split) nested_variant_command="command env -S 'git tag split-tag'" ;;
    assigned_env_split) nested_variant_command="FOO=bar env -S 'git tag split-tag'" ;;
    quoted_path_sub) nested_variant_command="echo \"\$('/usr/bin/git' tag quoted-path-tag)\"" ;;
  esac
  for intent_case in advisory execution; do
    setup_test
    init_session "t0c-nested-variant-${nested_variant_case}-${intent_case}" "${intent_case}"
    nested_variant_out="$(run_guard "t0c-nested-variant-${nested_variant_case}-${intent_case}" "${nested_variant_command}")"
    if denied "${nested_variant_out}"; then
      pass=$((pass + 1))
    else
      printf '  FAIL: T0c nested variant %s must deny under %s (got: %s)\n' \
        "${nested_variant_case}" "${intent_case}" "${nested_variant_out}" >&2
      fail=$((fail + 1))
    fi
    if [[ "${intent_case}" == "execution" ]]; then
      assert_contains "T0c nested variant ${nested_variant_case} reaches agent-first gate" \
        "Agent-first gate" "${nested_variant_out}"
    fi
    teardown_test
  done
done

# Literal shell text is data, even when it resembles a command substitution,
# process substitution, or nested delivery action. Safe executor bodies that
# merely print command-like prose are read-only too. Pin both advisory and
# agent-first paths so quote handling cannot regress into scanning argv data.
for literal_case in single_dollar single_process escaped_dollar escaped_backtick eval_prose shell_prose safe_substitution; do
  case "${literal_case}" in
    single_dollar) literal_command="echo '\$(git tag literal-tag)'" ;;
    single_process) literal_command="echo '<(git tag literal-tag)'" ;;
    escaped_dollar) literal_command='echo "\$(git tag literal-tag)"' ;;
    escaped_backtick) literal_command='echo "\`git tag literal-tag\`"' ;;
    eval_prose) literal_command="eval 'echo git tag literal-tag'" ;;
    shell_prose) literal_command="sh -c 'printf %s \"git tag literal-tag\"'" ;;
    safe_substitution) literal_command="echo \"\$(printf '%s' 'git tag literal-tag')\"" ;;
  esac
  for intent_case in advisory execution; do
    setup_test
    init_session "t0c-literal-${literal_case}-${intent_case}" "${intent_case}"
    literal_out="$(run_guard "t0c-literal-${literal_case}-${intent_case}" "${literal_command}")"
    assert_eq "T0c quoted/executor literal remains allowed: ${literal_case}/${intent_case}" "" "${literal_out}"
    teardown_test
  done
done

# Keep the structural parser's adversarial surface in one sourced process.
# The representative advisory/execution cases above prove hook integration;
# this matrix pins the larger grammar without paying one hook startup per
# spelling. Every `yes` form is executable mutation syntax (or an opaque
# executable/verb slot that must fail closed); every `no` form is proven
# literal/read-only syntax.
nested_parser_failures="$(
  . "${COMMON_SH}"

  _matrix_has_action() {
    _omc_shell_text_has_action_recursive "$1" any 0
  }

  _matrix_probe() {
    local expected="$1" label="$2" matrix_command="$3" actual="no"
    _matrix_has_action "${matrix_command}" && actual="yes"
    if [[ "${actual}" != "${expected}" ]]; then
      printf '%s: expected=%s actual=%s command=%q\n' \
        "${label}" "${expected}" "${actual}" "${matrix_command}"
    fi
  }

  # Nested substitution parsing, comments, legacy backticks, and controls.
  _matrix_probe yes branch_sub 'echo "$(git branch -D victim)"'
  _matrix_probe yes switch_sub 'echo "$(git switch -C victim)"'
  _matrix_probe yes checkout_sub 'echo "$(git checkout -B victim)"'
  _matrix_probe yes legacy_nested 'echo `echo \`git tag nested\``'
  _matrix_probe yes comment_depth $'echo "$(\n # ) parser trap\n git tag nested\n)"'
  _matrix_probe yes bang_control 'echo "$(! git tag nested)"'
  _matrix_probe yes if_control 'echo "$(if true; then git tag nested; fi)"'
  _matrix_probe yes brace_control 'echo "$({ git tag nested; })"'
  _matrix_probe yes case_control 'case x in x) git tag nested;; esac'

  # Literal and opaque shell/eval/split-string executors.
  _matrix_probe yes nice_shell "nice sh -c 'git tag nested'"
  _matrix_probe yes nohup_shell "nohup sh -c 'git tag nested'"
  _matrix_probe yes shell_option_value "bash -O extglob -c 'git tag nested'"
  _matrix_probe yes shell_rcfile "bash --rcfile /dev/null -c 'git tag nested'"
  _matrix_probe yes ansi_shell "sh -c \$'git tag nested'"
  _matrix_probe yes escaped_shell $'sh -c git\\ tag\\ nested'
  _matrix_probe yes dynamic_shell 'sh -c "$PAYLOAD"'
  _matrix_probe yes builtin_eval "builtin eval 'git tag nested'"
  _matrix_probe yes bare_eval 'eval git tag nested'
  _matrix_probe yes multi_eval "eval 'git' 'tag nested'"
  _matrix_probe yes dynamic_eval 'eval "$PAYLOAD"'
  _matrix_probe yes env_split_attached "command env -S'git tag nested'"
  _matrix_probe yes env_split_escape "command env -S 'git\\_tag\\_nested'"
  _matrix_probe yes env_split_cluster "command env -iS'git tag nested'"
  _matrix_probe yes env_split_tail "command env -S 'git' tag nested"
  _matrix_probe yes env_split_dynamic 'command env -S "$PAYLOAD"'

  # Static/dynamic shell-word construction in executable and verb slots.
  _matrix_probe yes escaped_executable 'g\it tag nested'
  _matrix_probe yes escaped_verb 'git t\ag nested'
  _matrix_probe yes ansi_executable "\$'g\\x69t' tag nested"
  _matrix_probe yes ansi_verb "git \$'t\\x61g' nested"
  _matrix_probe yes substitution_executable '$(printf git) tag nested'
  _matrix_probe yes substitution_verb 'git $(printf tag) nested'
  _matrix_probe yes substitution_join 'g$(printf it) tag nested'
  _matrix_probe yes backtick_executable '`printf git` tag nested'
  _matrix_probe yes escaped_assignment 'FOO=a\ b git tag nested'
  _matrix_probe yes escaped_env_assignment 'env FOO=a\ b git tag nested'
  _matrix_probe yes line_continuation $'echo "$(git \\\ntag nested)"'

  # Common wrapper option clusters and attached operands.
  _matrix_probe yes env_cluster 'env -iuFOO git tag nested'
  _matrix_probe yes env_altpath 'env -P/usr/bin git tag nested'
  _matrix_probe yes sudo_cluster 'sudo -EHu s git tag nested'
  _matrix_probe yes sudo_attached_cluster 'sudo -EHus git tag nested'
  _matrix_probe yes exec_cluster 'exec -cla PROBE git tag nested'
  _matrix_probe yes exec_attached_cluster 'exec -claPROBE git tag nested'
  _matrix_probe yes time_cluster '/usr/bin/time -po /tmp/out git tag nested'
  _matrix_probe yes timeout_option 'timeout -sKILL 5 git tag nested'
  _matrix_probe yes nice_option 'nice -n5 git tag nested'

  # A safe-looking flag used as an option value must not launder mutation.
  _matrix_probe yes commit_message_value 'git commit -m --dry-run --allow-empty'
  _matrix_probe yes commit_cluster_value 'git commit -am --dry-run --allow-empty'
  _matrix_probe yes push_option_value 'git push -o -n origin main'
  _matrix_probe yes push_cluster_value 'git push -fo -n origin main'

  # Genuine read-only/recovery modes and command-query wrappers stay allowed.
  _matrix_probe no command_query "command -v sh -c 'git tag literal'"
  _matrix_probe no command_query_verbose "command -V eval 'git tag literal'"
  _matrix_probe no apply_check "sh -c 'git apply --check patch.diff'"
  _matrix_probe no clean_dry 'echo "$(git clean -n)"'
  _matrix_probe no recovery "bash -lc 'git rebase --abort'"
  _matrix_probe no commit_dry_later 'git commit -a --dry-run'
  _matrix_probe no commit_sign_dry 'git commit -S --dry-run'
  _matrix_probe no commit_gpg_dry 'git commit --gpg-sign --dry-run'
  _matrix_probe no push_dry_later 'git push origin main -n'
  _matrix_probe no push_sign_dry 'git push --signed --dry-run origin main'
  _matrix_probe no push_recurse_dry 'git push --recurse-submodules --dry-run origin main'

  # The cheap marker tripwire must leave ordinary sibling substitutions and
  # quoted prose to the quote-aware walker. A quoted heredoc body is the named
  # conservative intent boundary: it is inert at runtime but still denied.
  _matrix_probe no sibling_markers 'echo "$(date)" "$(date)" "$(date)" "$(date)" "$(date)"'
  _matrix_probe no quoted_markers "printf '%s\\n' '\$(one) \$(two) \$(three) \$(four) \$(five)'"
  matrix_quoted_heredoc="$(printf '%s\n' "cat <<'EOF'" '$(git tag literal)' 'EOF')"
  _matrix_probe yes quoted_heredoc_boundary "${matrix_quoted_heredoc}"

  # Four ordinary nesting layers remain classifiable; pathological depth
  # terminates through the fail-closed operation budget.
  matrix_deep='printf safe'
  for _matrix_i in 1 2 3 4; do
    matrix_deep="echo \"\$(${matrix_deep})\""
  done
  _matrix_probe no depth_four "${matrix_deep}"

  # Size is an independent fail-closed cap: even marker-free input must not
  # reach the character-copying continuation normalizer once it is oversized.
  matrix_oversized="$(printf '%05000d' 0)"$'\\\n''printf safe'
  matrix_oversized_started="${SECONDS}"
  _matrix_probe yes oversized_continuation_budget "${matrix_oversized}"
  matrix_oversized_elapsed=$((SECONDS - matrix_oversized_started))
  if [[ "${matrix_oversized_elapsed}" -gt 2 ]]; then
    printf 'oversized_continuation_latency: expected <=2s actual=%ss\n' \
      "${matrix_oversized_elapsed}"
  fi

  _matrix_i=0
  while [[ "${_matrix_i}" -lt 500 ]]; do
    matrix_deep="echo \"\$(${matrix_deep})\""
    _matrix_i=$((_matrix_i + 1))
  done
  matrix_depth_started="${SECONDS}"
  _matrix_probe yes depth_budget "${matrix_deep}"
  matrix_depth_elapsed=$((SECONDS - matrix_depth_started))
  if [[ "${matrix_depth_elapsed}" -gt 2 ]]; then
    printf 'depth_budget_latency: expected <=2s actual=%ss\n' "${matrix_depth_elapsed}"
  fi

  # Known nested bodies preserve commit-vs-publish contract separation.
  omc_shell_nested_delivery_action_present 'echo "$(git commit -m nested)"' commit \
    || printf 'kind_commit: expected commit match\n'
  if omc_shell_nested_delivery_action_present 'echo "$(git commit -m nested)"' publish; then
    printf 'kind_commit: unexpected publish match\n'
  fi
  omc_shell_nested_delivery_action_present 'echo "$(git tag nested)"' publish \
    || printf 'kind_publish: expected publish match\n'
  if omc_shell_nested_delivery_action_present 'echo "$(git tag nested)"' commit; then
    printf 'kind_publish: unexpected commit match\n'
  fi
)"
assert_eq "T0c structural nested-action parser matrix" "" "${nested_parser_failures}"

# ----------------------------------------------------------------------
# T0d: execution intent + qualifying specialist completed → Edit allowed and
# first mutation is recorded for the Stop-hook backstop.
setup_test
init_session "t0d" "execution"
set_agent_first_satisfied "t0d" "quality-planner"
out_t0d="$(run_guard "t0d" "" "Edit")"
assert_eq "T0d: Edit allowed after qualifying specialist" "" "${out_t0d}"
assert_eq "T0d: first mutation tool recorded" "Edit" "$(read_state_key "t0d" "first_mutation_tool")"
teardown_test

# ----------------------------------------------------------------------
# T1 (control): execution intent + `git commit` → allow (silent exit 0)
setup_test
init_session "t1" "execution"
set_agent_first_satisfied "t1"
out_t1="$(run_guard "t1" "git commit -m 'real work'")"
assert_eq "T1: execution + commit allowed silently" "" "${out_t1}"
teardown_test

# ----------------------------------------------------------------------
# T2 (control): continuation intent + `git push` → allow
setup_test
init_session "t2" "continuation"
set_agent_first_satisfied "t2"
out_t2="$(run_guard "t2" "git push origin main")"
assert_eq "T2: continuation + push allowed silently" "" "${out_t2}"
teardown_test

# ----------------------------------------------------------------------
# T2b: execution intent + explicit do-not-commit contract → deny publish ops
setup_test
init_session "t2b" "execution"
set_agent_first_satisfied "t2b"
set_commit_mode "t2b" "forbidden"
out_t2b="$(run_guard "t2b" "git commit -m 'forbidden by contract'")"
if denied "${out_t2b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2b: forbidden commit contract must deny commit even under execution intent (got: %s)\n' "${out_t2b}" >&2
  fail=$((fail + 1))
fi
assert_contains "T2b: deny reason names commit contract" "Commit-contract gate" "${out_t2b}"
teardown_test

# Git reuses `-n` with different meanings: push `-n` is `--dry-run`, while
# commit `-n` is `--no-verify` and still creates a commit. Keep the mutating
# commit form denied without regressing the two genuine dry-run forms.
setup_test
init_session "t2c-commit-no-verify-advisory" "advisory"
out_t2c="$(run_guard "t2c-commit-no-verify-advisory" "git commit -n -m x")"
if denied "${out_t2c}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2c: git commit -n is --no-verify and must deny under advisory intent (got: %s)\n' "${out_t2c}" >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "t2c-commit-no-verify-contract" "execution"
set_agent_first_satisfied "t2c-commit-no-verify-contract"
set_commit_mode "t2c-commit-no-verify-contract" "forbidden"
out_t2c="$(run_guard "t2c-commit-no-verify-contract" "git commit -n -m x")"
if denied "${out_t2c}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2c: forbidden commit contract must deny git commit -n (got: %s)\n' "${out_t2c}" >&2
  fail=$((fail + 1))
fi
assert_contains "T2c: git commit -n denial names commit contract" "Commit-contract gate" "${out_t2c}"
teardown_test

for dry_run_case in push_short commit_long; do
  case "${dry_run_case}" in
    push_short) dry_run_command="git push -n"; dry_run_contract="push" ;;
    commit_long) dry_run_command="git commit --dry-run"; dry_run_contract="commit" ;;
  esac

  setup_test
  init_session "t2c-${dry_run_case}-advisory" "advisory"
  dry_run_out="$(run_guard "t2c-${dry_run_case}-advisory" "${dry_run_command}")"
  assert_eq "T2c: genuine dry-run remains allowed under advisory: ${dry_run_case}" "" "${dry_run_out}"
  teardown_test

  setup_test
  init_session "t2c-${dry_run_case}-contract" "execution"
  set_agent_first_satisfied "t2c-${dry_run_case}-contract"
  if [[ "${dry_run_contract}" == "push" ]]; then
    set_push_mode "t2c-${dry_run_case}-contract" "forbidden"
  else
    set_commit_mode "t2c-${dry_run_case}-contract" "forbidden"
  fi
  dry_run_out="$(run_guard "t2c-${dry_run_case}-contract" "${dry_run_command}")"
  assert_eq "T2c: genuine dry-run remains allowed under forbidden contract: ${dry_run_case}" "" "${dry_run_out}"
  teardown_test
done

# ----------------------------------------------------------------------
# T3 (regression): advisory intent + `git commit` → deny
setup_test
init_session "t3" "advisory"
out_t3="$(run_guard "t3" "git commit -m 'unauthorized'")"
if denied "${out_t3}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3: advisory + commit must be denied (got: %s)\n' "${out_t3}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T4 (regression): session_management intent + `git commit` → deny
setup_test
init_session "t4" "session_management"
out_t4="$(run_guard "t4" "git commit -m 'unauthorized'")"
if denied "${out_t4}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4: session_management + commit must be denied (got: %s)\n' "${out_t4}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T5 (NEW — wave-active override): advisory + active Phase 8 wave plan +
# `git commit` → allow. This is the v1.21.0 fix: a system-injected frame
# (resume / wakeup / compact handoff) can mis-flip task_intent to advisory
# while a wave plan is in flight; the persisted plan IS the user's standing
# authorization, and per-wave confirmation is the forbidden anti-pattern.
setup_test
init_session "t5" "advisory"
seed_findings "t5" '[
  {"index":1,"total":3,"surface":"auth","finding_ids":["F-001"],"status":"completed","commit_sha":"abc"},
  {"index":2,"total":3,"surface":"checkout","finding_ids":["F-002"],"status":"in_progress","commit_sha":""},
  {"index":3,"total":3,"surface":"search","finding_ids":["F-003"],"status":"pending","commit_sha":""}
]'
out_t5="$(run_guard "t5" "git commit -m 'Wave 2/3: checkout (F-002)'")"
assert_eq "T5: wave-active override allows commit silently" "" "${out_t5}"
teardown_test

# ----------------------------------------------------------------------
# T6: advisory + ALL waves completed → deny (override only applies while
# waves are pending or in_progress; once the plan is done, advisory means
# advisory again).
setup_test
init_session "t6" "advisory"
seed_findings "t6" '[
  {"index":1,"total":2,"surface":"auth","finding_ids":["F-001"],"status":"completed","commit_sha":"abc"},
  {"index":2,"total":2,"surface":"checkout","finding_ids":["F-002"],"status":"completed","commit_sha":"def"}
]'
out_t6="$(run_guard "t6" "git commit -m 'sneaky post-wave commit'")"
if denied "${out_t6}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: completed wave plan must NOT keep override active (got: %s)\n' "${out_t6}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T7: advisory + findings.json with empty waves[] → deny. A finding list
# without a wave plan is just a council snapshot, not an authorization to
# execute.
setup_test
init_session "t7" "advisory"
seed_findings "t7" '[]'
out_t7="$(run_guard "t7" "git commit -m 'no wave plan, no override'")"
if denied "${out_t7}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T7: empty waves[] must not trigger override (got: %s)\n' "${out_t7}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T8: advisory + active wave plan + non-Bash tool → silent allow. Edit tools
# are only gated for execution/continuation agent-first mutations; advisory
# edit-tool payloads still pass through this hook.
setup_test
init_session "t8" "advisory"
seed_findings "t8" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]'
out_t8="$(run_guard "t8" "" "Edit")"
assert_eq "T8: non-Bash tool passes through silently" "" "${out_t8}"
teardown_test

# ----------------------------------------------------------------------
# T9 (text contract): the deny reason text MUST NOT contain the disturbing
# rephrasings the user reported. Each substring is checked case-
# insensitively because the model's natural-language interpretation can
# capitalize freely. core.md 'FORBIDDEN: Asking "Should I proceed?"' is
# the canonical anti-pattern; these four are the surface forms we have
# observed in the wild.
setup_test
init_session "t9" "advisory"
out_t9="$(run_guard "t9" "git commit -m 'x'")"
# Confirm we have a deny first, otherwise the substring checks are vacuous.
if denied "${out_t9}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T9 prerequisite: expected a deny output (got: %s)\n' "${out_t9}" >&2
  fail=$((fail + 1))
fi
assert_not_contains_ci "T9: no 'say yes' phrasing"        "say yes"        "${out_t9}"
assert_not_contains_ci "T9: no 'single yes' phrasing"     "single yes"     "${out_t9}"
assert_not_contains_ci "T9: no 'reauthorize' phrasing"    "reauthorize"    "${out_t9}"
assert_not_contains_ci "T9: no 'confirm with yes'"        "confirm with yes" "${out_t9}"
teardown_test

# ----------------------------------------------------------------------
# T10 (text contract — v1.23.0 anti-puppeteering rewrite). The deny
# reason MUST cite the FORBIDDEN rule, name the "concrete imperative"
# anti-pattern, AND tell the model to ask the user to clarify in their
# own words. It MUST NOT contain the legacy "reply with: <X>" coaching
# substring — that was the literal prose v1.22.x model parroted back to
# the user as "reply with: ship the statusline reset-countdown commit
# on main", which is the puppeteering anti-pattern this rewrite
# eliminates. Locks in the new contract: no paste-back templates ever.
setup_test
init_session "t10" "advisory"
out_t10="$(run_guard "t10" "git commit -m 'x'")"
assert_contains "T10: reason cites 'concrete imperative' anti-pattern" \
  "concrete imperative" "${out_t10}"
assert_contains "T10: reason cites core.md FORBIDDEN rule" \
  "FORBIDDEN" "${out_t10}"
assert_contains "T10: reason instructs to ask user 'in their own words'" \
  "in their own words" "${out_t10}"
assert_contains "T10: reason calls out the puppeteering anti-pattern" \
  "puppeteering" "${out_t10}"
assert_not_contains_ci "T10: reason MUST NOT contain 'reply with:' paste-back coaching" \
  "reply with:" "${out_t10}"
assert_not_contains_ci "T10: reason MUST NOT teach the model to invent paste-back text" \
  "paste back verbatim" "${out_t10}"
teardown_test

# ----------------------------------------------------------------------
# T11 (kill switch): OMC_PRETOOL_INTENT_GUARD=false suppresses denial output.
# Mutation observation is intentionally independent and has an end-to-end
# regression in test-posttool-dispatch.sh T31.
setup_test
init_session "t11" "advisory"
out_t11="$(OMC_PRETOOL_INTENT_GUARD=false run_guard "t11" "git commit -m 'x'")"
assert_eq "T11: kill switch suppresses guard output" "" "${out_t11}"
teardown_test

# ----------------------------------------------------------------------
# T13 (override scope): wave-active does NOT extend to non-commit
# destructive ops. Phase 8 authorizes per-wave commits, not arbitrary
# repo manipulation. Force-push, reset --hard, tag, etc. still need
# fresh execution intent.
setup_test
init_session "t13" "advisory"
seed_findings "t13" '[
  {"index":1,"total":2,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]'
for forbidden_cmd in \
  "git push --force origin main" \
  "git reset --hard HEAD~5" \
  "git tag v9.9.9" \
  "git rebase main" \
  "git branch -D feature/x" \
  "git update-ref refs/heads/main HEAD~1" \
  "gh pr create --title sneaky" \
  "gh release create v9.9.9"; do
  out_t13="$(run_guard "t13" "${forbidden_cmd}")"
  if denied "${out_t13}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T13: wave-active must NOT override [%s] (got: %s)\n' \
      "${forbidden_cmd}" "${out_t13}" >&2
    fail=$((fail + 1))
  fi
done
teardown_test

# ----------------------------------------------------------------------
# T14 (override compound-segment safety): wave-active + a compound
# command containing a forbidden destructive segment must still deny on
# the destructive segment, even though one of the segments is `git
# commit`. Walking compound commands segment-by-segment is a contract
# of the destructive-matcher; the override must not weaken it.
setup_test
init_session "t14" "advisory"
seed_findings "t14" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]'
out_t14="$(run_guard "t14" "git commit -m wave && git push --force origin main")"
if denied "${out_t14}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T14: compound (commit && force-push) must deny on the force-push segment (got: %s)\n' "${out_t14}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T15 (override: absolute-path / flag-injection forms still recognized):
# the override reuses the same _GUARD_PRE prefix and the already-
# normalized denied_segment, so `/usr/bin/git commit`, `sudo git commit`,
# and `git -c foo=bar commit` all qualify when waves are active.
setup_test
init_session "t15" "advisory"
seed_findings "t15" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]'
for cmd in \
  "/usr/bin/git commit -m 'Wave 1/1: auth (F-001)'" \
  "sudo git commit -m wave" \
  "git -c user.email=x commit -m wave"; do
  out_t15="$(run_guard "t15" "${cmd}")"
  if [[ -z "${out_t15}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T15: wave-active commit override should accept [%s] (got: %s)\n' \
      "${cmd}" "${out_t15}" >&2
    fail=$((fail + 1))
  fi
done
teardown_test

# ----------------------------------------------------------------------
# T16 (freshness gate): a wave plan whose updated_ts is older than the
# default 2-hour TTL must NOT trigger the override. This protects
# against stale findings.json leaking the per-wave authorization into
# unrelated later work in the same session.
setup_test
init_session "t16" "advisory"
# Set updated_ts to 3 hours ago — outside the default 7200s TTL.
stale_ts=$(( $(date +%s) - 10800 ))
seed_findings "t16" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]' "${stale_ts}"
out_t16="$(run_guard "t16" "git commit -m 'Wave 1/1: stale plan'")"
if denied "${out_t16}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T16: stale wave plan must NOT trigger override (got: %s)\n' "${out_t16}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T17 (freshness gate, configurable TTL via env): OMC_WAVE_OVERRIDE_TTL_SECONDS
# must be honored. Set it to 60s and seed an updated_ts 5 minutes back —
# override should be suppressed even though the default would allow it.
setup_test
init_session "t17" "advisory"
stale_ts=$(( $(date +%s) - 300 ))  # 5 minutes ago
seed_findings "t17" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]' "${stale_ts}"
out_t17="$(OMC_WAVE_OVERRIDE_TTL_SECONDS=60 run_guard "t17" "git commit -m 'Wave 1/1'")"
if denied "${out_t17}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T17: configurable TTL must shorten the freshness window (got: %s)\n' "${out_t17}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T17b (freshness gate, configurable TTL via oh-my-claude.conf): the
# parser entry in common.sh wires `wave_override_ttl_seconds=N` from
# `~/.claude/oh-my-claude.conf` to OMC_WAVE_OVERRIDE_TTL_SECONDS. Without
# this path wired, users who follow the documented advice in
# docs/customization.md silently fall back to the default. Regression
# guard for the v1.21.0 review finding (parser entry was missing on
# initial implementation).
setup_test
init_session "t17b" "advisory"
stale_ts=$(( $(date +%s) - 300 ))  # 5 minutes ago
seed_findings "t17b" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]' "${stale_ts}"
# Write the conf file at the user-level path. common.sh's load_conf reads
# ${HOME}/.claude/oh-my-claude.conf, and the test sets HOME=${TEST_HOME}.
printf 'wave_override_ttl_seconds=60\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
# Explicitly unset the env var so the conf parser actually runs
# (parser is `[[ -z "${_omc_env_wave_override_ttl}" ... ]]`).
out_t17b="$(unset OMC_WAVE_OVERRIDE_TTL_SECONDS; run_guard "t17b" "git commit -m 'Wave 1/1'")"
if denied "${out_t17b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T17b: oh-my-claude.conf wave_override_ttl_seconds path must wire through (got: %s)\n' "${out_t17b}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T17c (TTL=0 kill-switch): setting OMC_WAVE_OVERRIDE_TTL_SECONDS=0 must
# disable the override entirely, even when updated_ts equals now_ts (the
# strict-zero-window edge case where a naive `age > max_age` comparison
# would let same-second writes through). Locks in the kill-switch
# semantics the CHANGELOG migration block promises.
setup_test
init_session "t17c" "advisory"
# Use exactly now_ts so age=0 — without the kill-switch special case,
# `0 -gt 0` is false and the override would fire.
seed_findings "t17c" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]' "$(date +%s)"
out_t17c="$(OMC_WAVE_OVERRIDE_TTL_SECONDS=0 run_guard "t17c" "git commit -m 'Wave 1/1 same-second'")"
if denied "${out_t17c}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T17c: TTL=0 must be a true kill-switch even at age=0 (got: %s)\n' "${out_t17c}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T18 (regex anti-false-match): `git push --force origin commit-msg-fix`
# contains the substring `commit` (in the branch name) but is NOT a
# `git commit` invocation. The override must NOT fire on it. Locks in
# the _GUARD_PRE anchoring that requires `commit` to follow `git`
# directly with whitespace, not appear anywhere downstream as a free
# substring.
setup_test
init_session "t18" "advisory"
seed_findings "t18" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]'
for cmd in \
  "git push --force origin commit-msg-fix" \
  "git push origin feature/commit-cleanup" \
  "git tag commit-checkpoint-1" \
  "git branch -D pending-commit"; do
  out_t18="$(run_guard "t18" "${cmd}")"
  if denied "${out_t18}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T18: regex must NOT false-match [%s] as git commit (got: %s)\n' \
      "${cmd}" "${out_t18}" >&2
    fail=$((fail + 1))
  fi
done
teardown_test

# ----------------------------------------------------------------------
# T12 (block-reason consistency on second block): the second-block
# message uses a shorter form. Confirm it ALSO avoids the forbidden
# phrasings — a user who hits the gate twice in a row is most at risk
# of the model reaching for the disturbing pattern.
setup_test
init_session "t12" "advisory"
# Fire once to advance pretool_intent_blocks past 1.
_=$(run_guard "t12" "git commit -m 'first'")
out_t12="$(run_guard "t12" "git commit -m 'second'")"
if denied "${out_t12}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T12 prerequisite: expected a deny output (got: %s)\n' "${out_t12}" >&2
  fail=$((fail + 1))
fi
assert_not_contains_ci "T12: 2nd block has no 'say yes'"       "say yes"        "${out_t12}"
assert_not_contains_ci "T12: 2nd block has no 'single yes'"    "single yes"     "${out_t12}"
assert_not_contains_ci "T12: 2nd block has no 'reauthorize'"   "reauthorize"    "${out_t12}"
assert_not_contains_ci "T12: 2nd block has no 'confirm with yes'" "confirm with yes" "${out_t12}"
assert_not_contains_ci "T12: 2nd block has no 'reply with:' paste-back coaching" "reply with:" "${out_t12}"
assert_contains "T12: 2nd block instructs 'ask user in their own words'" "in their own words" "${out_t12}"
teardown_test

# ----------------------------------------------------------------------
# T19 (FORBIDDEN-text drift guard): both deny-reason emitters cite the
# same canonical core.md FORBIDDEN snippet ('Asking "Should I proceed?"
# or "Would you like me to…"'). If one drifts, the two scripts give
# subtly different framings of the same rule and the model can paper
# over the gap. Lock the snippet's substring presence in BOTH scripts —
# this catches partial drift (e.g., quotes flipped, ellipsis dropped)
# without trying to enforce byte-for-byte equality which would over-fit.
SCRIPT_PRETOOL="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh"
SCRIPT_HANDOFF="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-compact-handoff.sh"
forbidden_snippet='Should I proceed'
for src in "${SCRIPT_PRETOOL}" "${SCRIPT_HANDOFF}"; do
  if grep -qF -- "${forbidden_snippet}" "${src}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T19: %s lost the canonical FORBIDDEN snippet (%q)\n' "${src}" "${forbidden_snippet}" >&2
    fail=$((fail + 1))
  fi
done
# Both scripts should also cite Would you like me to … (ellipsis form),
# the second canonical FORBIDDEN clause from core.md. A drift in one
# clause and not the other is the realistic failure mode.
forbidden_snippet2='Would you like me to'
for src in "${SCRIPT_PRETOOL}" "${SCRIPT_HANDOFF}"; do
  if grep -qF -- "${forbidden_snippet2}" "${src}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T19: %s lost the canonical FORBIDDEN snippet (%q)\n' "${src}" "${forbidden_snippet2}" >&2
    fail=$((fail + 1))
  fi
done

# ----------------------------------------------------------------------
# T20 (env-over-conf precedence): OMC_WAVE_OVERRIDE_TTL_SECONDS env var
# must override the conf file's wave_override_ttl_seconds. Without this,
# users who set the env in their shell would silently fall back to the
# conf value, which contradicts the documented precedence in
# customization.md ("Environment variables take precedence over the
# conf file"). Wires the same scenario as T17b (5-min-old plan) but
# sets BOTH a permissive conf (3600s) and a tight env (60s); the env
# must win and the override must be denied.
setup_test
init_session "t20" "advisory"
stale_ts=$(( $(date +%s) - 300 ))  # 5 min ago
seed_findings "t20" '[
  {"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]' "${stale_ts}"
# Conf says 3600s — would normally allow a 300s-old plan.
printf 'wave_override_ttl_seconds=3600\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
# Env says 60s — should win and disqualify the override.
out_t20="$(OMC_WAVE_OVERRIDE_TTL_SECONDS=60 run_guard "t20" "git commit -m 'Wave 1/1'")"
if denied "${out_t20}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T20: env OMC_WAVE_OVERRIDE_TTL_SECONDS must override conf wave_override_ttl_seconds (got: %s)\n' "${out_t20}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T21 (fail-closed on missing updated_ts): a findings.json that lacks
# the updated_ts field entirely (older format, malformed write) must NOT
# trigger the override — `jq // 0` defaults the field to 0, age becomes
# very large, and the freshness gate disqualifies the override. Locks
# in the fail-closed comment in pretool-intent-guard.sh:269.
setup_test
init_session "t21" "advisory"
state_dir="${TEST_HOME}/.claude/quality-pack/state/t21"
# Hand-write a findings.json without `updated_ts` so we know the field
# is genuinely absent (seed_findings always sets it).
jq -n '{
  version: 1,
  findings: [],
  waves: [{"index":1,"total":1,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}]
}' > "${state_dir}/findings.json"
out_t21="$(run_guard "t21" "git commit -m 'no updated_ts in plan'")"
if denied "${out_t21}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T21: missing updated_ts must fail-closed on freshness check (got: %s)\n' "${out_t21}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T22 (gate-event enrichment): when the override fires, the recorded
# gate_events.jsonl row must carry wave_index, wave_total, wave_surface,
# AND denied_segment. Without these, /ulw-report's per-gate Overrides
# column shows counts but cannot attribute each override to a specific
# wave — the v1.21.0 review finding excellence-reviewer flagged.
setup_test
init_session "t22" "advisory"
seed_findings "t22" '[
  {"index":2,"total":4,"surface":"checkout","finding_ids":["F-002"],"status":"in_progress","commit_sha":""}
]'
out_t22="$(run_guard "t22" "git commit -m 'Wave 2/4: checkout (F-002)'")"
# Override should fire silently (no deny, no output).
assert_eq "T22: override fires silently for valid wave commit" "" "${out_t22}"
# Now check the per-session gate_events.jsonl row. record_gate_event
# writes via append_limited_state, which lands the row in the session
# state dir; a separate sweep (session-stop / session-start) propagates
# rows to the cross-session ~/.claude/quality-pack/gate_events.jsonl.
gate_events_file="${TEST_HOME}/.claude/quality-pack/state/t22/gate_events.jsonl"
if [[ -f "${gate_events_file}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T22: gate_events.jsonl not written\n' >&2
  fail=$((fail + 1))
fi
last_row="$(tail -1 "${gate_events_file}" 2>/dev/null || printf '{}')"
assert_eq "T22: row event is wave_override" \
  "wave_override" \
  "$(jq -r '.event // ""' <<<"${last_row}")"
assert_eq "T22: row gate is pretool-intent" \
  "pretool-intent" \
  "$(jq -r '.gate // ""' <<<"${last_row}")"
assert_eq "T22: row carries wave_index=2" \
  "2" \
  "$(jq -r '.details.wave_index // ""' <<<"${last_row}")"
assert_eq "T22: row carries wave_total=4" \
  "4" \
  "$(jq -r '.details.wave_total // ""' <<<"${last_row}")"
assert_eq "T22: row carries wave_surface=checkout" \
  "checkout" \
  "$(jq -r '.details.wave_surface // ""' <<<"${last_row}")"
teardown_test

# ----------------------------------------------------------------------
# Wave 2 (v1.23.0) — prompt-text trust override tests.
#
# When the classifier mis-routes a prompt as advisory (an inevitable
# long-tail of natural-language imperative shapes that the regex
# layer cannot fully cover), but the raw user prompt unambiguously
# authorizes the destructive verb being attempted, the prompt itself
# IS the authorization. This override is defense-in-depth that closes
# the "reply with: ship the commit" UX failure observed in session
# cf10ddd2 (commit cff1ee5) where the user explicitly wrote "Implement
# and then commit as needed." but the classifier said advisory and the
# guard blocked the user's own authorized commit.
#
# Safety: requires (a) the raw prompt passes is_imperative_request, AND
# (b) every destructive non-allowed segment has its verb mentioned in
# the prompt with an imperative-tail object marker (or at end-of-prompt).
# A compound `git commit && git push --force` only passes when BOTH
# verbs are authorized.

# ----------------------------------------------------------------------
# T23 (the user's actual offending prompt): advisory + prompt that
# explicitly authorizes commit → override fires.
setup_test
init_session "t23" "advisory"
seed_recent_prompt "t23" \
  "/ulw can the status line be further enhanced for better ux? For instance, adding the information when will the limits be reset. Implement and then commit as needed."
out_t23="$(run_guard "t23" "git commit -m 'wave 1 of statusline UX'")"
assert_eq "T23: prompt-text override allows the user's verbatim authorized commit" \
  "" "${out_t23}"
teardown_test

# ----------------------------------------------------------------------
# T24 (noun-only mention): advisory + prompt where `commit` appears
# only as a noun ("review the commit hooks") → no override, must deny.
# This is the load-bearing safety check — a discussion prompt that
# happens to mention `commit` as a noun must NOT be misread as
# authorization.
setup_test
init_session "t24" "advisory"
seed_recent_prompt "t24" "review the commit hooks for quality and explain commit-message conventions"
out_t24="$(run_guard "t24" "git commit -m 'unauthorized'")"
if denied "${out_t24}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T24: noun-only mention of commit must NOT trigger override (got: %s)\n' "${out_t24}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T25 (polite imperative): advisory + prompt "Please commit the
# changes." → override fires. The polite "Please <verb> ..." form is
# the canonical phrasing the existing is_imperative_request branch
# handles, and the prompt-text override should accept it as
# authorization for `git commit`.
setup_test
init_session "t25" "advisory"
seed_recent_prompt "t25" "Please commit the changes."
out_t25="$(run_guard "t25" "git commit -m 'staged work'")"
assert_eq "T25: polite imperative prompt fires override" "" "${out_t25}"
teardown_test

# ----------------------------------------------------------------------
# T25b (safety rail — bare destructive word does NOT trigger override):
# advisory + prompt is just "commit" with no surrounding imperative
# context → is_imperative_request returns false (no verb head, no
# imperative tail), so the override's safety rail (a) refuses to fire.
# Note: in real flow, the classifier defaults intent to execution for
# bare ambiguous prompts (see classifier.sh:536), so this exact path
# rarely fires in practice. The test exists to lock the safety rail
# behavior — a stale advisory intent + bare destructive verb prompt
# must NOT slip past the gate via the override.
setup_test
init_session "t25b" "advisory"
seed_recent_prompt "t25b" "commit"
out_t25b="$(run_guard "t25b" "git commit -m 'manipulated state'")"
if denied "${out_t25b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T25b: bare destructive word + advisory must NOT trigger override (got: %s)\n' "${out_t25b}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T26 (compound — both verbs authorized): advisory + prompt authorizes
# both commit AND push → override fires for `git commit && git push`.
setup_test
init_session "t26" "advisory"
seed_recent_prompt "t26" "Apply the fix and commit when tests pass, then push to origin"
out_t26="$(run_guard "t26" "git commit -m wave && git push origin main")"
assert_eq "T26: compound with both verbs authorized passes override" "" "${out_t26}"
teardown_test

# ----------------------------------------------------------------------
# T27 (compound — only one verb authorized, smuggle attempt): advisory
# + prompt only authorizes `commit` → compound `git commit && git push
# --force` must DENY. Prevents the shape where an authorized commit is
# used to smuggle an unauthorized force-push past the gate.
setup_test
init_session "t27" "advisory"
seed_recent_prompt "t27" "Implement and commit as needed."
out_t27="$(run_guard "t27" "git commit -m wave && git push --force origin main")"
if denied "${out_t27}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T27: compound with only one authorized verb must deny (got: %s)\n' "${out_t27}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T28 (missing recent_prompts.jsonl): advisory + no prompt log → no
# override (cannot authorize without the source). Must deny.
setup_test
init_session "t28" "advisory"
# Deliberately do NOT call seed_recent_prompt.
out_t28="$(run_guard "t28" "git commit -m 'no prompt source'")"
if denied "${out_t28}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T28: missing recent_prompts.jsonl must NOT permit override (got: %s)\n' "${out_t28}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T29 (kill switch): OMC_PROMPT_TEXT_OVERRIDE=off disables the override
# entirely, even when the prompt would clearly authorize. Symmetric to
# the OMC_PRETOOL_INTENT_GUARD kill switch.
setup_test
init_session "t29" "advisory"
seed_recent_prompt "t29" "Implement and commit as needed"
out_t29="$(OMC_PROMPT_TEXT_OVERRIDE=off run_guard "t29" "git commit -m 'x'")"
if denied "${out_t29}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T29: OMC_PROMPT_TEXT_OVERRIDE=off must disable override (got: %s)\n' "${out_t29}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T30 (telemetry): when the override fires, gate_events.jsonl carries
# event=prompt_text_override with the denied_segment + prompt_preview
# fields enriched. /ulw-report uses this to attribute each override to
# the user's exact authorizing prompt for cross-session audit.
setup_test
init_session "t30" "advisory"
seed_recent_prompt "t30" "Implement and commit as needed."
_=$(run_guard "t30" "git commit -m 'wave A'")
gate_events_file="${TEST_HOME}/.claude/quality-pack/state/t30/gate_events.jsonl"
last_row="$(tail -1 "${gate_events_file}" 2>/dev/null || printf '{}')"
assert_eq "T30: gate row event is prompt_text_override" \
  "prompt_text_override" \
  "$(jq -r '.event // ""' <<<"${last_row}")"
assert_eq "T30: gate row gate is pretool-intent" \
  "pretool-intent" \
  "$(jq -r '.gate // ""' <<<"${last_row}")"
prompt_preview="$(jq -r '.details.prompt_preview // ""' <<<"${last_row}")"
if [[ "${prompt_preview}" == *"Implement and commit"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T30: gate row missing prompt_preview substring (got: %s)\n' "${prompt_preview}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T31 (verb-mismatch): prompt authorizes `push` but command attempts
# `git tag` → must deny. The verb in the prompt and the verb in the
# command must align — authorizing one destructive op does not authorize
# others. Closes the "any imperative authorizes any destructive verb"
# misread of the override.
setup_test
init_session "t31" "advisory"
seed_recent_prompt "t31" "push the changes to origin when ready"
out_t31="$(run_guard "t31" "git tag v9.9.9")"
if denied "${out_t31}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T31: prompt authorizing push must NOT authorize tag (got: %s)\n' "${out_t31}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T32 (wave-active takes precedence): advisory + active wave plan +
# prompt that authorizes commit → wave-active fires first (its gate
# event is wave_override, not prompt_text_override). The two paths are
# evaluated in order; wave-active is preferred because it carries
# tighter audit metadata.
setup_test
init_session "t32" "advisory"
seed_findings "t32" '[
  {"index":1,"total":2,"surface":"auth","finding_ids":["F-001"],"status":"in_progress","commit_sha":""}
]'
seed_recent_prompt "t32" "Implement and commit as needed"
_=$(run_guard "t32" "git commit -m 'Wave 1/2: auth (F-001)'")
gate_events_file="${TEST_HOME}/.claude/quality-pack/state/t32/gate_events.jsonl"
last_row="$(tail -1 "${gate_events_file}" 2>/dev/null || printf '{}')"
assert_eq "T32: wave-active takes precedence over prompt-text" \
  "wave_override" \
  "$(jq -r '.event // ""' <<<"${last_row}")"
teardown_test

# ----------------------------------------------------------------------
# T33 (negative imperative — past tense): advisory + prompt is past-
# tense ("we tested and committed yesterday") → not imperative, no
# override, must deny. Locks in the is_imperative_request safety rail.
setup_test
init_session "t33" "advisory"
seed_recent_prompt "t33" "we tested the change and committed yesterday but the build failed"
out_t33="$(run_guard "t33" "git commit -m 'redo'")"
if denied "${out_t33}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T33: past-tense narrative must NOT trigger override (got: %s)\n' "${out_t33}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T34 (positive — tag verb segment): advisory + prompt authorizes `tag`
# → `git tag v9.9.9` must allow. Existing T31 covers the negative case
# (push authorized, tag attempted → deny); T34 closes the positive
# coverage gap for the tag segment specifically. Closes F-006 from the
# v1.23.x follow-up wave (compound-segment safety beyond commit/push).
setup_test
init_session "t34" "advisory"
seed_recent_prompt "t34" "Please tag v2.0.0 once the release branch is green."
out_t34="$(run_guard "t34" "git tag v2.0.0")"
assert_eq "T34: prompt authorizes tag → git tag allowed" "" "${out_t34}"
teardown_test

# ----------------------------------------------------------------------
# T35 (positive — merge verb segment): advisory + prompt authorizes
# `merge` → `git merge feature-branch` must allow.
setup_test
init_session "t35" "advisory"
seed_recent_prompt "t35" "Could you merge the feature branch into main when CI passes?"
out_t35="$(run_guard "t35" "git merge feature-branch")"
assert_eq "T35: prompt authorizes merge → git merge allowed" "" "${out_t35}"
teardown_test

# ----------------------------------------------------------------------
# T36 (positive — gh-publish via release verb): advisory + prompt
# authorizes `release` → `gh release create v1.0.0` must allow. The
# `gh-publish` verb-class accepts any of open/create/publish/release/
# ship/merge/close/edit followed by a NOUN-shaped object marker
# (a|an|the|this|new|pr|release|tag|issue/...). Using "publish the
# release" satisfies the noun-marker rule (an object literal "v1.0.0"
# alone does NOT — see _verb_appears_in_imperative_position's gh-publish
# branch which is stricter than the single-verb branch).
setup_test
init_session "t36" "advisory"
seed_recent_prompt "t36" "Please publish the release to production tonight."
out_t36="$(run_guard "t36" "gh release create v1.0.0 --notes 'Wave 2 ship'")"
assert_eq "T36: prompt authorizes release → gh release create allowed" "" "${out_t36}"
teardown_test

# ----------------------------------------------------------------------
# T37 (compound — tag + push --tags both authorized): the canonical
# release-tag-and-push compound. Both segments must be authorized.
# Polite-please head form so is_imperative_request matches reliably
# (the bare "Tag v..." head form does not match the head-imperative
# verb list because `tag` is omitted there; only the polite/tail
# branches accept it).
setup_test
init_session "t37" "advisory"
seed_recent_prompt "t37" "Please tag v2.0.0 and push the tags to origin."
out_t37="$(run_guard "t37" "git tag v2.0.0 && git push --tags")"
assert_eq "T37: compound tag + push --tags with both authorized passes" "" "${out_t37}"
teardown_test

# ----------------------------------------------------------------------
# T38 (compound — only tag authorized, push --tags smuggled): advisory
# + prompt authorizes only `tag` → `git tag v2.0.0 && git push --tags`
# must DENY because the push segment is unauthorized. Symmetric to T27
# (commit && push --force smuggle) but for the tag/push pair. Closes
# the gap where the existing T27 only verified the commit/push pair.
setup_test
init_session "t38" "advisory"
seed_recent_prompt "t38" "Please tag v2.0.0 once the release branch is green."
out_t38="$(run_guard "t38" "git tag v2.0.0 && git push --tags")"
if denied "${out_t38}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T38: tag-authorized but push-unauthorized compound must deny (got: %s)\n' "${out_t38}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# T39 (compound — merge authorized but reset --hard smuggled): advisory
# + prompt authorizes only `merge` → `git merge feature && git reset
# --hard origin/main` must DENY. The merge/reset pair is the failure
# mode where a merge-conflict resolution is reframed as a hard reset.
setup_test
init_session "t39" "advisory"
seed_recent_prompt "t39" "Could you merge the feature branch into main when CI passes?"
out_t39="$(run_guard "t39" "git merge feature-branch && git reset --hard origin/main")"
if denied "${out_t39}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T39: merge-authorized but reset-unauthorized compound must deny (got: %s)\n' "${out_t39}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# v1.34.0 (Bug C end-to-end): push_mode=forbidden blocks publishing-class
# verbs without forbidding commit. Validates the matcher-split between
# `_commit_segment_forbidden` (git commit only) and
# `_push_segment_forbidden` (git push|tag, gh pr/release/issue).
# The fixture mirrors the user's reported case: prompt authorized
# commit but explicitly forbade the push half.
# ----------------------------------------------------------------------

# T40 (Bug C): push_mode=forbidden + git commit → ALLOW. The
# whole point of splitting from a single mode: commit must remain
# authorized when only push was forbidden.
setup_test
init_session "t40" "execution"
set_agent_first_satisfied "t40"
set_push_mode "t40" "forbidden"
out_t40="$(run_guard "t40" "git commit -m 'auth fix'")"
if denied "${out_t40}"; then
  printf '  FAIL: T40: push_mode=forbidden must NOT deny git commit (got: %s)\n' "${out_t40}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T41 (Bug C): push_mode=forbidden + git push → DENY.
setup_test
init_session "t41" "execution"
set_agent_first_satisfied "t41"
set_push_mode "t41" "forbidden"
out_t41="$(run_guard "t41" "git push origin main")"
if denied "${out_t41}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T41: push_mode=forbidden must deny git push (got: %s)\n' "${out_t41}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T42 (Bug C): push_mode=forbidden + git tag → DENY.
setup_test
init_session "t42" "execution"
set_agent_first_satisfied "t42"
set_push_mode "t42" "forbidden"
out_t42="$(run_guard "t42" "git tag v1.0.0")"
if denied "${out_t42}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T42: push_mode=forbidden must deny git tag (got: %s)\n' "${out_t42}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T43 (Bug C): push_mode=forbidden + gh pr create → DENY.
setup_test
init_session "t43" "execution"
set_agent_first_satisfied "t43"
set_push_mode "t43" "forbidden"
out_t43="$(run_guard "t43" "gh pr create --title 'feat' --body 'x'")"
if denied "${out_t43}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T43: push_mode=forbidden must deny gh pr create (got: %s)\n' "${out_t43}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T44 (Bug C): push_mode=forbidden + git status → ALLOW. Read-only
# git ops must not trigger the publish-class block.
setup_test
init_session "t44" "execution"
set_push_mode "t44" "forbidden"
out_t44="$(run_guard "t44" "git status")"
if denied "${out_t44}"; then
  printf '  FAIL: T44: push_mode=forbidden must NOT deny git status (got: %s)\n' "${out_t44}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T45 (Bug C compound): commit_mode=required, push_mode=forbidden +
# `git commit && git push` → DENY (the push segment fails). The
# commit-half being authorized is the whole point of the split, but
# concatenating the forbidden push must still trip the gate.
setup_test
init_session "t45" "execution"
set_agent_first_satisfied "t45"
set_commit_mode "t45" "required"
set_push_mode "t45" "forbidden"
out_t45="$(run_guard "t45" "git commit -m 'x' && git push")"
if denied "${out_t45}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T45: commit-allowed + push-forbidden compound must deny (got: %s)\n' "${out_t45}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T46 (Bug C): both modes unspecified + git push → ALLOW. No contract,
# no block (subject to other gates that don't apply at execution intent).
setup_test
init_session "t46" "execution"
set_agent_first_satisfied "t46"
out_t46="$(run_guard "t46" "git push")"
if denied "${out_t46}"; then
  printf '  FAIL: T46: no contract should not deny under execution intent (got: %s)\n' "${out_t46}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# Nested delivery actions obey the same split commit/publish contract as
# direct commands. A fresh specialist is recorded so these assertions prove
# the explicit contract gate fired rather than passing accidentally through
# the earlier agent-first gate.
for nested_contract_case in commit_sub commit_eval push_sub tag_shell push_bash_lc push_env_split; do
  setup_test
  init_session "t-contract-nested-${nested_contract_case}" "execution"
  set_agent_first_satisfied "t-contract-nested-${nested_contract_case}"
  case "${nested_contract_case}" in
    commit_sub)
      set_commit_mode "t-contract-nested-${nested_contract_case}" "forbidden"
      nested_contract_label="Commit"
      nested_contract_command='echo "$(git commit -m nested)"'
      ;;
    commit_eval)
      set_commit_mode "t-contract-nested-${nested_contract_case}" "forbidden"
      nested_contract_label="Commit"
      nested_contract_command="eval 'git commit -m nested'"
      ;;
    push_sub)
      set_push_mode "t-contract-nested-${nested_contract_case}" "forbidden"
      nested_contract_label="Push"
      nested_contract_command='echo "$(git push --force)"'
      ;;
    tag_shell)
      set_push_mode "t-contract-nested-${nested_contract_case}" "forbidden"
      nested_contract_label="Push"
      nested_contract_command="sh -c 'git tag nested-tag'"
      ;;
    push_bash_lc)
      set_push_mode "t-contract-nested-${nested_contract_case}" "forbidden"
      nested_contract_label="Push"
      nested_contract_command="bash -lc 'git push --force'"
      ;;
    push_env_split)
      set_push_mode "t-contract-nested-${nested_contract_case}" "forbidden"
      nested_contract_label="Push"
      nested_contract_command="command env -S 'git tag split-tag'"
      ;;
  esac
  nested_contract_out="$(run_guard "t-contract-nested-${nested_contract_case}" "${nested_contract_command}")"
  if denied "${nested_contract_out}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: nested %s action must obey its forbidden contract (got: %s)\n' \
      "${nested_contract_case}" "${nested_contract_out}" >&2
    fail=$((fail + 1))
  fi
  assert_contains "nested ${nested_contract_case} denial names the correct contract" \
    "${nested_contract_label}-contract gate" "${nested_contract_out}"
  teardown_test
done

# Kind separation is load-bearing: forbidding publish must not also forbid a
# nested commit, and forbidding commit must not forbid a nested publish.
setup_test
init_session "t-contract-nested-kind-push" "execution"
set_agent_first_satisfied "t-contract-nested-kind-push"
set_push_mode "t-contract-nested-kind-push" "forbidden"
kind_separation_out="$(run_guard "t-contract-nested-kind-push" 'echo "$(git commit -m nested)"')"
assert_eq "nested commit remains allowed when only publish is forbidden" "" "${kind_separation_out}"
teardown_test

setup_test
init_session "t-contract-nested-kind-commit" "execution"
set_agent_first_satisfied "t-contract-nested-kind-commit"
set_commit_mode "t-contract-nested-kind-commit" "forbidden"
kind_separation_out="$(run_guard "t-contract-nested-kind-commit" 'echo "$(git push --force)"')"
assert_eq "nested publish remains allowed when only commit is forbidden" "" "${kind_separation_out}"
teardown_test

# ----------------------------------------------------------------------
# T47 (v1.42.x security): when the prompt_text_override fires and
# is_prompt_persist_enabled is true, the gate_events row's
# prompt_preview MUST redact secret-shaped tokens. Without this the
# cross-session sweep aggregates raw prompts containing API keys into
# ~/.claude/quality-pack/gate_events.jsonl — a less-guarded surface
# than the per-session dir and the exact passive-leak case the
# security audit flagged.
setup_test
init_session "t47" "advisory"
_SECRET='sk-ant-deadbeefcafebabe1234567ABCDEFG'
seed_recent_prompt "t47" "Implement and commit as needed. token=${_SECRET}"
_=$(OMC_PROMPT_PERSIST=on run_guard "t47" "git commit -m 'wave A'")
gate_events_file="${TEST_HOME}/.claude/quality-pack/state/t47/gate_events.jsonl"
last_row="$(tail -1 "${gate_events_file}" 2>/dev/null || printf '{}')"
prompt_preview_t47="$(jq -r '.details.prompt_preview // ""' <<<"${last_row}")"
case "${prompt_preview_t47}" in
  *"${_SECRET}"*)
    printf '  FAIL: T47: pretool gate prompt_preview leaked sk-ant- token\n    preview=%s\n' "${prompt_preview_t47}" >&2
    fail=$((fail + 1))
    ;;
  *"<redacted-secret>"*)
    pass=$((pass + 1))
    ;;
  *)
    # Override may not have fired (e.g. classifier reread); only fail
    # if prompt_preview is non-empty AND contains no redaction marker
    # AND contains the secret literally — already covered by the first
    # branch. An empty preview is acceptable (means override didn't
    # fire on this command shape).
    if [[ -n "${prompt_preview_t47}" ]]; then
      printf '  FAIL: T47: gate preview present but no redaction marker\n    preview=%s\n' "${prompt_preview_t47}" >&2
      fail=$((fail + 1))
    else
      pass=$((pass + 1))
    fi
    ;;
esac
teardown_test

# ----------------------------------------------------------------------
# v1.43.x bg-spawn hygiene gate. Closes the recurring orphan-loop failure
# mode the user reported (until ... ; do sleep N ; done with
# run_in_background:true → process orphans when the conversation moves
# on). Tests cover:
#   T48 — poll loop + run_in_background:true → BLOCK
#   T49 — poll loop + trailing & → BLOCK (subshell detach)
#   T50 — poll loop without background → ALLOW (foreground wait is legit)
#   T51 — nohup → BLOCK regardless of run_in_background
#   T52 — setsid → BLOCK regardless of run_in_background
#   T53 — non-Bash tool → ALLOW (gate is Bash-only)
#   T54 — kill switch OMC_BG_SPAWN_GATE=false → ALLOW even on offending pattern
#   T55 — recovery message names the harness mechanism (run_in_background + notification)
#   T56 — read-only inspection with sleep but no loop → ALLOW (no FP on `sleep 1; ls`)
#   T57  — while-read-from-file (no sleep) → ALLOW (no FP on data-driven loops)
#   T58  — gate event recorded with `bg-spawn` reason on block
#   T58b — quoted-prose containing `until`/`while` → ALLOW (F1 strip-quotes regression)
#   T59  — compound poll-loop + extra commands → BLOCK (F4 segment-scope regression)
#   T60  — `2>&1 &` redirect without loop → ALLOW (F5 conjunction sibling)
#   T61  — loop + sleep + `2>&1 &` → BLOCK (F5 conjunction sibling)
#   T62  — until-in-quotes + sleep + & → ALLOW (do-token predicate regression)

# Wrapper that lets a test set tool_input.run_in_background. The existing
# run_guard helper hard-codes Bash payload without that field; this
# wrapper extends it minimally so we don't fork run_guard's signature for
# every caller in the file.
run_guard_bg() {
  local sid="$1" cmd="$2" rib="$3"
  local payload
  payload="$(jq -nc --arg s "${sid}" --arg c "${cmd}" --argjson r "${rib}" '{
    session_id: $s,
    tool_name: "Bash",
    tool_input: {command: $c, run_in_background: $r},
    hook_event_name: "PreToolUse"
  }')"
  printf '%s' "${payload}" | bash "${HOOK_SCRIPT}" 2>/dev/null || true
}

# T48: classic orphan pattern — until-grep-sleep loop with run_in_background:true.
setup_test
init_session "t48" "execution"
out_t48="$(run_guard_bg "t48" 'until grep -q "done" /tmp/out; do sleep 5; done' true)"
assert_contains "T48: bg-spawn block on poll-loop + run_in_background:true" \
  '"permissionDecision":"deny"' "${out_t48}"
assert_contains "T48: block reason names the hygiene gate" \
  '[Hygiene gate · bg-spawn]' "${out_t48}"
teardown_test

# T49: poll loop with trailing & (subshell-background) — same orphan class.
setup_test
init_session "t49" "execution"
out_t49="$(run_guard_bg "t49" 'until test -f /tmp/x; do sleep 2; done &' false)"
assert_contains "T49: bg-spawn block on poll-loop + trailing &" \
  '"permissionDecision":"deny"' "${out_t49}"
teardown_test

# T50: foreground poll loop (no &, no run_in_background) — ALLOWED. Brief
# foreground waits don't orphan and are sometimes legitimately useful
# (waiting on a service to be ready before the next step in a script).
setup_test
init_session "t50" "execution"
out_t50="$(run_guard_bg "t50" 'until curl -s localhost:8080/ready; do sleep 1; done' false)"
if [[ "${out_t50}" == *'"permissionDecision":"deny"'* ]] && [[ "${out_t50}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T50: foreground poll loop should NOT trigger hygiene gate\n    output=%s\n' "${out_t50}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T51: nohup → always orphans, blocked regardless of run_in_background.
setup_test
init_session "t51" "execution"
out_t51="$(run_guard_bg "t51" 'nohup bash run-thing.sh > out.log 2>&1' false)"
assert_contains "T51: bg-spawn block on nohup" \
  '"permissionDecision":"deny"' "${out_t51}"
teardown_test

# T52: setsid → same class as nohup, blocked.
setup_test
init_session "t52" "execution"
out_t52="$(run_guard_bg "t52" 'setsid sh -c "long-running"' false)"
assert_contains "T52: bg-spawn block on setsid" \
  '"permissionDecision":"deny"' "${out_t52}"
teardown_test

# T53: non-Bash tool input → gate ignores. Defensive: tool_input.command
# from a non-Bash tool would never contain a shell construct, but the
# function early-returns on missing command_str anyway.
setup_test
init_session "t53" "execution"
out_t53="$(printf '%s' "$(jq -nc '{
  session_id: "t53",
  tool_name: "Edit",
  tool_input: {file_path: "/tmp/x"},
  hook_event_name: "PreToolUse"
}')" | bash "${HOOK_SCRIPT}" 2>/dev/null || true)"
if [[ "${out_t53}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T53: gate fired on non-Bash tool\n    output=%s\n' "${out_t53}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T54: kill switch — OMC_BG_SPAWN_GATE=false disables the gate entirely.
# The orphan pattern from T48 should pass through silently.
setup_test
init_session "t54" "execution"
out_t54="$(OMC_BG_SPAWN_GATE=false run_guard_bg "t54" 'until grep -q "done" /tmp/out; do sleep 5; done' true)"
if [[ "${out_t54}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T54: kill switch did not disable hygiene gate\n    output=%s\n' "${out_t54}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T55: recovery message points to the harness mechanism the agent was
# supposed to use instead. Without this, a model hitting the block would
# learn "this Bash form is forbidden" without learning what to do
# instead — defeating the educational purpose of the gate.
setup_test
init_session "t55" "execution"
out_t55="$(run_guard_bg "t55" 'until grep -q "x" /tmp/y; do sleep 3; done' true)"
assert_contains "T55: recovery names run_in_background:true mechanism" \
  'run_in_background:true' "${out_t55}"
assert_contains "T55: recovery names harness notification" \
  'completion notification' "${out_t55}"
assert_contains "T55: recovery names /ulw-skip escape" \
  '/ulw-skip' "${out_t55}"
teardown_test

# T56: read-only command with `sleep` but no loop construct — ALLOW. The
# anti-pattern is the COMBINATION; an isolated `sleep 1` between two
# commands is a legitimate pause (e.g., debounce between operations).
setup_test
init_session "t56" "execution"
out_t56="$(run_guard_bg "t56" 'ls -la && sleep 1 && ls -la' true)"
if [[ "${out_t56}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T56: standalone sleep should not trigger gate\n    output=%s\n' "${out_t56}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T57: while-read loop over a file — no sleep, no orphan. ALLOW.
# Data-driven loops are common in shell scripts; the gate must not
# false-positive on them.
setup_test
init_session "t57" "execution"
out_t57="$(run_guard_bg "t57" 'while IFS= read -r line; do echo "$line"; done < /tmp/in' true)"
if [[ "${out_t57}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T57: while-read loop without sleep should not trigger gate\n    output=%s\n' "${out_t57}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T58b (v1.43.x reviewer F1 regression): quoted-prose containing
# `until` MUST NOT trigger the hygiene gate. grep has no shell-quoting
# awareness, so without a strip-quotes pass the `(until|while)` predicate
# matches inside `echo "wait until ready"` and the trailing `&` predicate
# completes the conjunction. End-to-end: `echo "wait until ready"; sleep 1;
# npm test &` was a false-positive on the initial implementation.
setup_test
init_session "t58b" "execution"
out_t58b="$(run_guard_bg "t58b" 'echo "wait until ready"; sleep 1; npm test &' false)"
if [[ "${out_t58b}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T58b: quoted-prose FP — hygiene gate fired on echoed "until"\n    output=%s\n' "${out_t58b}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
out_t58b2="$(run_guard_bg "t58b" "echo 'running while ok'; sleep 2; cmd &" false)"
if [[ "${out_t58b2}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T58b: single-quoted FP — hygiene gate fired on echoed "while"\n    output=%s\n' "${out_t58b2}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T59 (v1.43.x reviewer F4): compound poll-loop followed by additional
# commands in the same Bash call still orphans under run_in_background:true.
# Without this test, a future refactor tightening segment boundaries
# could silently allow `until X; do sleep N; done; ls` to pass.
setup_test
init_session "t59" "execution"
out_t59="$(run_guard_bg "t59" 'until grep -q done out; do sleep 2; done; echo finished' true)"
assert_contains "T59: compound poll-loop + extra commands still blocks under rib:true" \
  '"permissionDecision":"deny"' "${out_t59}"
assert_contains "T59: block reason names hygiene gate" \
  '[Hygiene gate · bg-spawn]' "${out_t59}"
teardown_test

# T60 (v1.43.x reviewer F5): trailing `2>&1 &` without loop+sleep MUST NOT
# trigger the gate. The trailing-`&` predicate matches `2>&1 &` literally,
# but the conjunction with loop+sleep is what makes it an orphan.
setup_test
init_session "t60" "execution"
out_t60="$(run_guard_bg "t60" 'npm run dev 2>&1 &' false)"
if [[ "${out_t60}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T60: trailing 2>&1 & without loop should not trigger gate\n    output=%s\n' "${out_t60}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T61 (v1.43.x reviewer F5): loop + sleep + `2>&1 &` IS the orphan shape —
# blocked. Sibling to T60 ensuring the redirect doesn't accidentally
# defuse the trailing-`&` check.
setup_test
init_session "t61" "execution"
out_t61="$(run_guard_bg "t61" 'while true; do sleep 1; done 2>&1 &' false)"
assert_contains "T61: while-true loop with sleep + 2>&1 & still blocks" \
  '"permissionDecision":"deny"' "${out_t61}"
teardown_test

# T62: regression for the `do`-token requirement. A command containing
# `until` (in stripped prose) and `sleep` but no `do` token must NOT
# trigger the gate.
setup_test
init_session "t62" "execution"
out_t62="$(run_guard_bg "t62" 'echo "use until-then form"; sleep 1; cmd2 &' false)"
if [[ "${out_t62}" == *'[Hygiene gate · bg-spawn]'* ]]; then
  printf '  FAIL: T62: until in quoted prose + sleep + & should not trigger gate\n    output=%s\n' "${out_t62}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# T58: gate_events.jsonl row gets a `bg-spawn` event with `block` status
# and run_in_background detail captured. Without this, /ulw-report and
# the cross-session ledger have no signal that the gate fired.
setup_test
init_session "t58" "execution"
_=$(run_guard_bg "t58" 'until grep -q done out; do sleep 2; done' true)
gate_events_file="${TEST_HOME}/.claude/quality-pack/state/t58/gate_events.jsonl"
if [[ -f "${gate_events_file}" ]]; then
  last_row="$(tail -1 "${gate_events_file}" 2>/dev/null || printf '{}')"
  gate_name="$(jq -r '.gate // ""' <<<"${last_row}")"
  gate_event="$(jq -r '.event // ""' <<<"${last_row}")"
  rib_detail="$(jq -r '.details.run_in_background // ""' <<<"${last_row}")"
  assert_eq "T58: gate name is bg-spawn" "bg-spawn" "${gate_name}"
  assert_eq "T58: event is block" "block" "${gate_event}"
  assert_eq "T58: run_in_background detail captured" "true" "${rib_detail}"
else
  printf '  FAIL: T58: gate_events.jsonl not written\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# ======================================================================
# v1.43+ agent-first gate opt-in tests. The gate's BLOCK is now opt-in
# (default off) because the mandate fired ~2.2x/session under the
# canonical /ulw user without paying for itself — depth-on-every-prompt
# + sub-dispatch-as-tool carry the actual concern. These tests pin both
# directions: default-off must allow pre-specialist mutation; explicit
# opt-in must restore the legacy block; telemetry runs unconditionally.
# Also pins the Serendipity quote-strip fix for the redirect matcher.
# ======================================================================

# ----------------------------------------------------------------------
# T_aff_off_a: default gate (off) + Edit before specialist → ALLOW.
# Counter-regression for T0a (which keeps OMC_AGENT_FIRST_GATE=on via
# setup_test). When the flag is off, the main thread can mutate
# directly without dispatching a specialist first.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_a" "execution"
out_aff_off_a="$(run_guard "t_aff_off_a" "" "Edit")"
assert_eq "T_aff_off_a: default-off allows pre-specialist Edit (no deny)" "" "${out_aff_off_a}"
teardown_test

# T_aff_off_b: default gate (off) + mutating Bash before specialist → ALLOW.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_b" "execution"
out_aff_off_b="$(run_guard "t_aff_off_b" "touch /tmp/omc-aff-off-test")"
assert_eq "T_aff_off_b: default-off allows pre-specialist mutating Bash (no deny)" "" "${out_aff_off_b}"
teardown_test

# T_aff_off_c: default gate (off) + Edit → first_mutation_ts STILL recorded.
# Telemetry must run regardless of the flag so cross-session reporting
# can compare opt-in vs opt-out outcomes. Note: when the gate's block is
# bypassed (flag off), the script records first_mutation_ts via
# _record_first_mutation_attempt; the value must be a positive epoch.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_c" "execution"
_=$(run_guard "t_aff_off_c" "" "Edit")
fmt_off="$(read_state_key "t_aff_off_c" "first_mutation_ts")"
if [[ "${fmt_off}" =~ ^[1-9][0-9]+$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_off_c: first_mutation_ts not recorded under default-off (got: %q)\n' "${fmt_off}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_off_d: default gate (off) + continuation intent + Edit → ALLOW.
# The gate's block surface covered both execution and continuation;
# the opt-out must lift both.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_d" "continuation"
out_aff_off_d="$(run_guard "t_aff_off_d" "" "Edit")"
assert_eq "T_aff_off_d: default-off allows pre-specialist Edit on continuation intent" "" "${out_aff_off_d}"
teardown_test

# T_aff_off_e (quality-reviewer F5): mark-edit.sh (PostToolUse) records
# first_mutation_ts even under gate=off. mark-edit.sh's
# _record_first_mutation_from_edit is a PARALLEL writer to the PreTool
# path; the Stop backstop reads first_mutation_ts from EITHER source.
# Without this test, a refactor that conditionally skips the PostTool
# writer would silently break the opt-in → on transition (when a user
# flips the flag mid-session, the backstop wouldn't fire even if the
# session had mutated).
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_e" "execution"
MARK_EDIT_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh"
printf '%s' "$(jq -nc --arg s "t_aff_off_e" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/src/foo.ts"}}')" \
  | bash "${MARK_EDIT_SCRIPT}" 2>/dev/null || true
fmt_off_e="$(read_state_key "t_aff_off_e" "first_mutation_ts")"
if [[ "${fmt_off_e}" =~ ^[1-9][0-9]+$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_off_e: mark-edit.sh did not record first_mutation_ts under gate=off (got: %q)\n' "${fmt_off_e}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_precedence (quality-reviewer F6): env var precedence over conf.
# common.sh's _parse_conf_file honors env-first via _omc_env_agent_first_gate.
# A future refactor that flipped the order would silently change behavior;
# this regression net catches the flip.
setup_test
init_session "t_aff_prec" "execution"
mkdir -p "${TEST_HOME}/.claude"
printf 'agent_first_gate=on\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
# Env says OFF; conf says ON. Env must win → mutation ALLOWED.
export OMC_AGENT_FIRST_GATE=off
out_aff_prec="$(run_guard "t_aff_prec" "" "Edit")"
assert_eq "T_aff_precedence: OMC_AGENT_FIRST_GATE=off env wins over conf=on (mutation allowed)" "" "${out_aff_prec}"
teardown_test

# T_aff_on_explicit: explicit OMC_AGENT_FIRST_GATE=on still denies.
# Mirror of T0a but with the env explicitly set (rather than via the
# setup_test default), so a future refactor of setup_test does not
# silently change the contract.
setup_test
export OMC_AGENT_FIRST_GATE=on
init_session "t_aff_on" "execution"
out_aff_on="$(run_guard "t_aff_on" "" "Edit")"
if denied "${out_aff_on}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_on: explicit gate=on must deny pre-specialist Edit (got: %s)\n' "${out_aff_on}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
# Serendipity quote-strip regression (_bash_command_may_mutate_workspace).
# The redirect regex `(^|[^0-9])>>?[[:space:]]*[^[:space:]&|;]+` matched
# literal `<unset>` inside a double-quoted printf arg because the `>` is
# followed by `"`. Fix: strip "..." and '...' content before the redirect
# check. These tests pin both directions: prose-`<X>` no longer denies,
# real redirects still deny.
#
# Tests run with gate=on (setup_test default) so the false-positive
# would actually FIRE without the fix.

# T_aff_qfix_a: printf with literal `<unset>` in quoted arg → ALLOW
# (the bug that bit a real /ulw session and prompted the v1.43 redesign).
setup_test
init_session "t_aff_qfix_a" "execution"
out_qfa="$(run_guard "t_aff_qfix_a" 'printf "%s\n" "${var:-<unset>}"')"
assert_eq "T_aff_qfix_a: printf with <unset> in quoted arg must not false-positive as redirect" "" "${out_qfa}"
teardown_test

# T_aff_qfix_b: literal `>` inside double-quoted string → ALLOW.
setup_test
init_session "t_aff_qfix_b" "execution"
out_qfb="$(run_guard "t_aff_qfix_b" 'echo "hello > world"')"
assert_eq "T_aff_qfix_b: literal > inside double quotes must not match redirect" "" "${out_qfb}"
teardown_test

# T_aff_qfix_c: literal `>` inside single-quoted string → ALLOW.
setup_test
init_session "t_aff_qfix_c" "execution"
out_qfc="$(run_guard "t_aff_qfix_c" "echo 'a > b'")"
assert_eq "T_aff_qfix_c: literal > inside single quotes must not match redirect" "" "${out_qfc}"
teardown_test

# T_aff_qfix_d: REAL redirect to file still denies (regression
# protection — quote-stripping must not lose coverage of actual writes).
setup_test
init_session "t_aff_qfix_d" "execution"
out_qfd="$(run_guard "t_aff_qfix_d" "echo hello > /tmp/omc-real-redirect.txt")"
if denied "${out_qfd}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_qfix_d: real `> file` redirect must still deny (got: %s)\n' "${out_qfd}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ======================================================================
# v1.43+ Wave 2 (review-cycle follow-up) — additional pinning:
#  * T_aff_off_e_tool: T_aff_off_e didn't verify first_mutation_tool;
#    a refactor that dropped the tool name would still pass the prior
#    assertion. (quality-reviewer F3)
#  * T_aff_off_e_state: gate state must be stamped on first_mutation_ts
#    capture so /ulw-report and stop-guard can join opt-in vs opt-out
#    outcomes per-row. (data-lens P0)
#  * T_aff_precedence_b: env-empty + conf=on must opt in. The original
#    T_aff_precedence only covered env-wins-over-conf; this asserts
#    the conf-only opt-in path doesn't silently fail. (quality-reviewer F2)
#  * T_aff_case_*: case-insensitive flag parsing. ON / On / OFF / off
#    must all normalize. (quality-reviewer F1)
#  * T_aff_project_conf_security: a project-level
#    .claude/oh-my-claude.conf must NOT be able to flip security flags
#    (pretool_intent_guard, bg_spawn_gate, agent_first_gate,
#    no_defer_mode) — only the user-level conf and env can. (security-lens P1)
# ======================================================================

# T_aff_off_e_tool: also assert tool name was recorded.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_e_tool" "execution"
MARK_EDIT_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh"
printf '%s' "$(jq -nc --arg s "t_aff_off_e_tool" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/src/foo.ts"}}')" \
  | bash "${MARK_EDIT_SCRIPT}" 2>/dev/null || true
fmt_tool="$(read_state_key "t_aff_off_e_tool" "first_mutation_tool")"
assert_eq "T_aff_off_e_tool: first_mutation_tool stamped as Edit by mark-edit.sh" "Edit" "${fmt_tool}"
teardown_test

# T_aff_off_e_state: gate state must be stamped (data-lens P0 closure).
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_off_e_state" "execution"
MARK_EDIT_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh"
printf '%s' "$(jq -nc --arg s "t_aff_off_e_state" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/src/bar.ts"}}')" \
  | bash "${MARK_EDIT_SCRIPT}" 2>/dev/null || true
fmt_state="$(read_state_key "t_aff_off_e_state" "agent_first_gate_state")"
assert_eq "T_aff_off_e_state: agent_first_gate_state=off stamped on mutation under default-off" "off" "${fmt_state}"
teardown_test

# T_aff_on_state: same stamp under gate=on must record "on".
setup_test
export OMC_AGENT_FIRST_GATE=on
init_session "t_aff_on_state" "execution"
MARK_EDIT_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-edit.sh"
printf '%s' "$(jq -nc --arg s "t_aff_on_state" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/src/baz.ts"}}')" \
  | bash "${MARK_EDIT_SCRIPT}" 2>/dev/null || true
fmt_state_on="$(read_state_key "t_aff_on_state" "agent_first_gate_state")"
assert_eq "T_aff_on_state: agent_first_gate_state=on stamped on mutation under gate=on" "on" "${fmt_state_on}"
teardown_test

# T_aff_precedence_b: env-empty + conf-set=on → mutation DENIED.
# Mirror of T_aff_precedence in the other direction. If
# _omc_env_agent_first_gate capture regressed, the conf-only opt-in
# path would silently fall to default-off and this test would catch.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_prec_b" "execution"
mkdir -p "${TEST_HOME}/.claude"
printf 'agent_first_gate=on\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
out_aff_prec_b="$(run_guard "t_aff_prec_b" "" "Edit")"
if denied "${out_aff_prec_b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_precedence_b: env-empty + conf=on must deny pre-specialist Edit (got: %s)\n' "${out_aff_prec_b}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_case_env_upper: OMC_AGENT_FIRST_GATE=ON must opt-in.
setup_test
export OMC_AGENT_FIRST_GATE=ON
init_session "t_aff_case_env_upper" "execution"
out_case_eu="$(run_guard "t_aff_case_env_upper" "" "Edit")"
if denied "${out_case_eu}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_case_env_upper: OMC_AGENT_FIRST_GATE=ON must deny (got: %s)\n' "${out_case_eu}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_case_env_mixed: OMC_AGENT_FIRST_GATE=On (mixed case) must opt-in.
setup_test
export OMC_AGENT_FIRST_GATE=On
init_session "t_aff_case_env_mixed" "execution"
out_case_em="$(run_guard "t_aff_case_env_mixed" "" "Edit")"
if denied "${out_case_em}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_case_env_mixed: OMC_AGENT_FIRST_GATE=On must deny (got: %s)\n' "${out_case_em}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_case_conf_upper: conf agent_first_gate=ON must opt-in (env empty).
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_case_conf_upper" "execution"
mkdir -p "${TEST_HOME}/.claude"
printf 'agent_first_gate=ON\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
out_case_cu="$(run_guard "t_aff_case_conf_upper" "" "Edit")"
if denied "${out_case_cu}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_case_conf_upper: conf agent_first_gate=ON must deny (got: %s)\n' "${out_case_cu}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_case_env_off_upper: OMC_AGENT_FIRST_GATE=OFF must opt-out (default-off explicit).
setup_test
export OMC_AGENT_FIRST_GATE=OFF
init_session "t_aff_case_env_off_upper" "execution"
out_case_eou="$(run_guard "t_aff_case_env_off_upper" "" "Edit")"
assert_eq "T_aff_case_env_off_upper: OMC_AGENT_FIRST_GATE=OFF must allow (default opt-out semantics)" "" "${out_case_eou}"
teardown_test

# T_aff_project_conf_security: project-level conf cannot disable security flags.
# A user at ~/.claude has agent_first_gate=on. A project's .claude/oh-my-claude.conf
# sets agent_first_gate=off (malicious-repo simulation). The user-level value MUST
# win — the project-level setting is rejected with a stderr log.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_proj_sec" "execution"
mkdir -p "${TEST_HOME}/.claude"
printf 'agent_first_gate=on\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
# Create a fake project dir with a .claude/oh-my-claude.conf disabling the gate.
PROJ_DIR="${TEST_HOME}/proj"
mkdir -p "${PROJ_DIR}/.claude"
printf 'agent_first_gate=off\n' > "${PROJ_DIR}/.claude/oh-my-claude.conf"
# Run the guard from inside the project dir; user-level should still apply.
out_proj_sec="$(cd "${PROJ_DIR}" && run_guard "t_aff_proj_sec" "" "Edit")"
if denied "${out_proj_sec}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_aff_project_conf_security: project conf must NOT be able to flip agent_first_gate off (got: %s)\n' "${out_proj_sec}" >&2
  fail=$((fail + 1))
fi
teardown_test

# T_aff_project_conf_allowed_flag: project-level conf CAN still override
# non-security flags (e.g. classifier_telemetry, council_deep_default).
# Pin that the deny-list is narrow — only the 4 security-load-bearing
# flags are restricted. Otherwise we'd silently break legitimate
# project customization.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "t_aff_proj_allowed" "execution"
mkdir -p "${TEST_HOME}/.claude"
PROJ_DIR2="${TEST_HOME}/proj-allowed"
mkdir -p "${PROJ_DIR2}/.claude"
printf 'classifier_telemetry=off\n' > "${PROJ_DIR2}/.claude/oh-my-claude.conf"
# Source common.sh from inside PROJ_DIR2 in a subshell and read OMC_CLASSIFIER_TELEMETRY.
out_allowed="$(cd "${PROJ_DIR2}" && bash -c '. "'"${REPO_ROOT}"'/bundle/dot-claude/skills/autowork/scripts/common.sh" >/dev/null 2>&1; printf "%s" "${OMC_CLASSIFIER_TELEMETRY:-}"')"
assert_eq "T_aff_project_conf_allowed_flag: project conf classifier_telemetry=off must apply (non-security flag)" "off" "${out_allowed}"
teardown_test

# ----------------------------------------------------------------------
# Review-batch stability: distinct reviewer roles are intentionally allowed to
# run in parallel, but a workspace mutation while any is in flight would make
# their generation-stamped results stale. The guard freezes mutation only;
# read-only work remains available and ordinary builder agents do not trigger it.
setup_test
export OMC_AGENT_FIRST_GATE=off
init_session "t_review_freeze" "execution"
set_agent_first_satisfied "t_review_freeze"
review_pending_dir="${TEST_HOME}/.claude/quality-pack/state/t_review_freeze"
review_pending_now="$(date +%s)"
printf '%s\n' \
  "{\"ts\":${review_pending_now},\"agent_type\":\"quality-reviewer\",\"review_dispatch_causality_version\":1,\"review_revision\":1}" \
  '{malformed-json' \
  "{\"ts\":${review_pending_now},\"agent_type\":\"excellence-reviewer\",\"review_dispatch_causality_version\":1,\"review_revision\":1}" \
  >"${review_pending_dir}/pending_agents.jsonl"
out_review_edit="$(run_guard "t_review_freeze" "" "Edit")"
if denied "${out_review_edit}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_review_freeze: Edit during reviewer batch must be denied (got: %s)\n' "${out_review_edit}" >&2
  fail=$((fail + 1))
fi
assert_contains "T_review_freeze: reason names both active gate roles" \
  "excellence-reviewer,quality-reviewer" "${out_review_edit}"
assert_contains "T_review_freeze: reason explains token-preserving wait" \
  "same review work must be paid for again" "${out_review_edit}"
out_review_read="$(run_guard "t_review_freeze" "git status --short")"
assert_eq "T_review_freeze: read-only Bash remains allowed" "" "${out_review_read}"

rm -f "${review_pending_dir}/pending_agents.jsonl"
out_review_settled="$(run_guard "t_review_freeze" "" "Edit")"
assert_eq "T_review_freeze: mutation resumes after reviewers settle" "" "${out_review_settled}"
teardown_test

# Council Phase 8's explicit marker has a real producer: record-pending-agent
# stamps every marked role with the same deterministic objective+revision ID.
# Quality may return before a slower namespaced semantic specialist; cleanup of
# that one row must not release mutation until the final marked role settles.
setup_test
export OMC_AGENT_FIRST_GATE=off
init_session "t_phase8_batch_producer" "execution"
set_agent_first_satisfied "t_phase8_batch_producer"
phase8_batch_dir="${TEST_HOME}/.claude/quality-pack/state/t_phase8_batch_producer"
jq '. + {
      council_phase8_active:"1",
      review_cycle_prompt_ts:"12345",
      last_user_prompt_ts:"12345",
      prompt_revision:"9",
      edit_revision:"7",
      last_code_edit_revision:"7"
    }' "${phase8_batch_dir}/session_state.json" \
  >"${phase8_batch_dir}/session_state.json.tmp"
mv "${phase8_batch_dir}/session_state.json.tmp" \
  "${phase8_batch_dir}/session_state.json"

_dispatch_phase8_batch_role() {
  local agent="$1" description="$2"
  jq -nc --arg sid "t_phase8_batch_producer" --arg agent "${agent}" \
    --arg description "${description}" \
    '{session_id:$sid,tool_name:"Agent",tool_input:{subagent_type:$agent,description:$description}}' \
    | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh" \
      2>/dev/null
}

_return_phase8_batch_role() {
  local agent="$1" dispatch_id="${2:-}" message
  message="Review complete."
  if [[ -n "${dispatch_id}" ]]; then
    message="${message}"$'\n'"REVIEW_DISPATCH_ID: ${dispatch_id}"
  fi
  message="${message}"$'\n'"VERDICT: CLEAN"
  jq -nc --arg sid "t_phase8_batch_producer" --arg agent "${agent}" \
    --arg message "${message}" \
    '{session_id:$sid,agent_type:$agent,last_assistant_message:$message}' \
    | OMC_DISCOVERED_SCOPE=off \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
      >/dev/null
  if [[ "${agent##*:}" == "quality-reviewer" ]]; then
    jq -nc --arg sid "t_phase8_batch_producer" --arg agent "${agent}" \
      --arg message "${message}" \
      '{session_id:$sid,agent_type:$agent,last_assistant_message:$message}' \
      | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-reviewer.sh" \
        standard >/dev/null 2>&1 || true
  fi
}

_dispatch_phase8_batch_role "quality-reviewer" \
  "[review-batch] REVIEW MODE: defects-only; inspect the settled wave"
_dispatch_phase8_batch_role "acme:security-lens" \
  "[review-batch] inspect the settled wave's authentication risk"
phase8_pending_file="${phase8_batch_dir}/pending_agents.jsonl"
assert_eq "T_phase8_batch: producer stamps both marked dispatches" "2" \
  "$(jq -s 'length' "${phase8_pending_file}")"
assert_eq "T_phase8_batch: deterministic objective+revision ID is shared" \
  "phase8-12345-p9-e7" \
  "$(jq -s -r 'map(.review_batch_id) | unique | if length == 1 then .[0] else "mismatch" end' \
    "${phase8_pending_file}")"
assert_eq "T_phase8_batch: namespaced semantic identity is preserved" \
  "acme:security-lens" \
  "$(jq -s -r 'map(select(.agent_type == "acme:security-lens"))[0].agent_type // ""' \
    "${phase8_pending_file}")"

_return_phase8_batch_role "quality-reviewer"
assert_eq "T_phase8_batch: quality return clears only its own pending row" \
  "acme:security-lens" \
  "$(jq -s -r 'map(.agent_type) | join(",")' "${phase8_pending_file}")"
out_phase8_semantic_pending="$(run_guard "t_phase8_batch_producer" "" "Edit")"
if denied "${out_phase8_semantic_pending}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T_phase8_batch: Edit after quality returned but semantic review remained must be denied (got: %s)\n' \
    "${out_phase8_semantic_pending}" >&2
  fail=$((fail + 1))
fi
assert_contains "T_phase8_batch: remaining namespaced semantic role keeps freeze active" \
  "acme:security-lens" "${out_phase8_semantic_pending}"

_return_phase8_batch_role "acme:security-lens"
out_phase8_settled="$(run_guard "t_phase8_batch_producer" "" "Edit")"
assert_eq "T_phase8_batch: final marked return releases mutation" "" \
  "${out_phase8_settled}"

# Re-dispatch and age the real producer row past the abandoned-call TTL. A
# killed semantic review must not trap the user forever.
_dispatch_phase8_batch_role "acme:security-lens" \
  "[review-batch] inspect a retried settled wave"
phase8_stale_ts="$(( $(date +%s) - 7201 ))"
jq -c --argjson stale "${phase8_stale_ts}" '.ts=$stale' \
  "${phase8_pending_file}" >"${phase8_pending_file}.tmp"
mv "${phase8_pending_file}.tmp" "${phase8_pending_file}"
out_phase8_stale="$(run_guard "t_phase8_batch_producer" "" "Edit")"
assert_eq "T_phase8_batch: abandoned marked semantic row expires" "" \
  "${out_phase8_stale}"
unbound_semantic_retry="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] inspect the retried settled wave')"
assert_contains "T_phase8_batch: stale semantic retry requires explicit binding" \
  '[review-rebind:' "${unbound_semantic_retry}"
bound_semantic_retry="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:semantic-retry] inspect the retried wave; emit REVIEW_DISPATCH_ID: semantic-retry immediately before VERDICT')"
assert_eq "T_phase8_batch: explicitly bound semantic retry is allowed" "" \
  "${bound_semantic_retry}"
assert_eq "T_phase8_batch: abandoned semantic row is preserved for a late return" \
  "true" "$(head -n 1 "${phase8_pending_file}" | jq -r '.review_dispatch_abandoned')"
assert_eq "T_phase8_batch: bound semantic retry carries its unique ID" \
  "semantic-retry" "$(tail -n 1 "${phase8_pending_file}" | jq -r '.review_dispatch_id')"
_return_phase8_batch_role "acme:security-lens" "semantic-retry"
assert_eq "T_phase8_batch: bound return clears only the bound retry" "1" \
  "$(jq -s 'length' "${phase8_pending_file}")"
out_phase8_abandoned_only="$(run_guard "t_phase8_batch_producer" "" "Edit")"
assert_eq "T_phase8_batch: abandoned old tombstone does not freeze mutation after replacement" "" \
  "${out_phase8_abandoned_only}"
_return_phase8_batch_role "acme:security-lens"
assert_eq "T_phase8_batch: late old return clears only the abandoned row" "0" \
  "$(jq -s 'length' "${phase8_pending_file}")"

# Confirmed interruption can rebind immediately; TTL is only the automatic
# mutation-freeze expiry. Exercise old-first completion order for the semantic
# queue (the stale fixture above exercised new-first).
semantic_active_dispatch="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:semantic-active] inspect an active semantic wave')"
assert_eq "T_phase8_batch: explicitly bound active semantic call is admitted" \
  "" "${semantic_active_dispatch}"
# Reserve the same-second base and -2 candidates in both bounded ledgers. The
# denial must scan both and allocate -3 (or later), never hand out a colliding
# recovery ID merely because two requests landed in one second.
suggestion_epoch="$(date +%s)"
suggestion_starts="${phase8_batch_dir}/agent_dispatch_starts.jsonl"
suggestion_ts=$((suggestion_epoch - 2))
while (( suggestion_ts <= suggestion_epoch + 60 )); do
  printf '%s\n' \
    "{\"agent_type\":\"suggestion-reservation\",\"review_dispatch_id\":\"rebind-${suggestion_ts}-r0-2\"}" \
    >>"${suggestion_starts}"
  printf '%s\n' \
    "{\"agent_type\":\"suggestion-reservation\",\"review_dispatch_id\":\"rebind-${suggestion_ts}-r0\"}" \
    >>"${phase8_pending_file}"
  suggestion_ts=$((suggestion_ts + 1))
done
active_semantic_duplicate="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] ordinary duplicate semantic wave')"
assert_contains "T_phase8_batch: active semantic denial offers killed-call recovery" \
  '[review-rebind:' "${active_semantic_duplicate}"
assert_contains "T_phase8_batch: same-second suggestion skips pending/start collisions" \
  '-3]' "${active_semantic_duplicate}"
jq -c 'select(.agent_type != "suggestion-reservation")' \
  "${phase8_pending_file}" >"${phase8_pending_file}.tmp"
mv "${phase8_pending_file}.tmp" "${phase8_pending_file}"
jq -c 'select(.agent_type != "suggestion-reservation")' \
  "${suggestion_starts}" >"${suggestion_starts}.tmp"
mv "${suggestion_starts}.tmp" "${suggestion_starts}"
immediate_semantic_retry="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:semantic-immediate] confirmed interrupted; emit REVIEW_DISPATCH_ID: semantic-immediate immediately before VERDICT')"
assert_eq "T_phase8_batch: confirmed semantic interruption rebinds before TTL" "" \
  "${immediate_semantic_retry}"
_return_phase8_batch_role "acme:security-lens" "semantic-active"
assert_eq "T_phase8_batch: old-first semantic return leaves bound retry" \
  "semantic-immediate" \
  "$(jq -s -r '.[0].review_dispatch_id // ""' "${phase8_pending_file}")"
_return_phase8_batch_role "acme:security-lens" "semantic-immediate"
assert_eq "T_phase8_batch: new-after-old semantic return clears its own row" "0" \
  "$(jq -s 'length' "${phase8_pending_file}")"

# Forced bind/effects interleaving: once SubagentStop owns a durable completion
# claim, even an explicit killed-call rebind must wait instead of abandoning a
# result whose authoritative side effects are already being committed.
claim_target_dispatch="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:claim-target] claim interleaving target')"
assert_eq "T_phase8_claim: explicitly bound claim target is admitted" \
  "" "${claim_target_dispatch}"
claim_ready="${TEST_HOME}/claim-ready"
claim_release="${TEST_HOME}/claim-release"
rm -f "${claim_ready}" "${claim_release}"
claim_payload="$(jq -nc --arg sid "t_phase8_batch_producer" \
  --arg agent "acme:security-lens" \
  --arg message $'Claimed result.\nREVIEW_DISPATCH_ID: claim-target\nVERDICT: CLEAN' \
  '{session_id:$sid,agent_type:$agent,last_assistant_message:$message}')"
OMC_TEST_SUMMARY_CLAIM_READY_FILE="${claim_ready}" \
OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${claim_release}" \
OMC_DISCOVERED_SCOPE=off \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${claim_payload}" >/dev/null 2>&1 &
claim_pid=$!
for _claim_wait in $(seq 1 100); do
  [[ -f "${claim_ready}" ]] && break
  sleep 0.05
done
assert_eq "T_phase8_claim: completion claim reaches deterministic barrier" "yes" \
  "$([[ -f "${claim_ready}" ]] && printf yes || printf no)"
claim_race_retry="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:claim-race] confirmed interrupted race')"
assert_contains "T_phase8_claim: rebind waits for in-progress completion claim" \
  'completion is being recorded' "${claim_race_retry}"
assert_eq "T_phase8_claim: racing rebind cannot abandon claimed row" "false" \
  "$(jq -r '.review_dispatch_abandoned // false' "${phase8_pending_file}")"
touch "${claim_release}"
wait "${claim_pid}"
assert_eq "T_phase8_claim: accepted claimed completion consumes pending row" "0" \
  "$(jq -s 'length' "${phase8_pending_file}")"
assert_eq "T_phase8_claim: mutation resumes after atomic claim finalizes" "" \
  "$(run_guard "t_phase8_batch_producer" "" "Edit")"

# Claim-owner crash recovery: kill at the barrier before any side effect, age
# the lease past its bounded 120s window, then explicitly rebind. The crashed
# owner cannot have appended a summary, and the old claim becomes a suppression
# tombstone while the replacement proceeds.
claim_crash_dispatch="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:claim-crash-target] crash-recovery target')"
assert_eq "T_phase8_claim: explicitly bound crash target is admitted" \
  "" "${claim_crash_dispatch}"
crash_ready="${TEST_HOME}/crash-ready"
crash_release="${TEST_HOME}/crash-release"
rm -f "${crash_ready}" "${crash_release}"
crash_summary_before="$(jq -s 'length' "${phase8_batch_dir}/subagent_summaries.jsonl")"
crash_claim_payload="$(jq -nc --arg sid "t_phase8_batch_producer" \
  --arg agent "acme:security-lens" \
  --arg message $'Claimed result.\nREVIEW_DISPATCH_ID: claim-crash-target\nVERDICT: CLEAN' \
  '{session_id:$sid,agent_type:$agent,last_assistant_message:$message}')"
OMC_TEST_SUMMARY_CLAIM_READY_FILE="${crash_ready}" \
OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${crash_release}" \
OMC_DISCOVERED_SCOPE=off \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${crash_claim_payload}" >/dev/null 2>&1 &
crash_pid=$!
for _crash_wait in $(seq 1 100); do
  [[ -f "${crash_ready}" ]] && break
  sleep 0.05
done
kill -9 "${crash_pid}" 2>/dev/null || true
wait "${crash_pid}" 2>/dev/null || true
assert_eq "T_phase8_claim: barrier kill occurs before summary side effects" \
  "${crash_summary_before}" \
  "$(jq -s 'length' "${phase8_batch_dir}/subagent_summaries.jsonl")"
expired_claim_ts="$(( $(date +%s) - 121 ))"
jq -c --argjson expired "${expired_claim_ts}" '.completion_claim_ts=$expired' \
  "${phase8_pending_file}" >"${phase8_pending_file}.tmp"
mv "${phase8_pending_file}.tmp" "${phase8_pending_file}"
expired_claim_denied="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] recover expired completion claim')"
assert_contains "T_phase8_claim: expired claim still requires explicit binding" \
  '[review-rebind:' "${expired_claim_denied}"
expired_claim_retry="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[review-batch] [review-rebind:claim-recovery] recover expired completion claim; emit REVIEW_DISPATCH_ID: claim-recovery immediately before VERDICT')"
assert_eq "T_phase8_claim: explicit retry recovers expired claim lease" "" \
  "${expired_claim_retry}"
_return_phase8_batch_role "acme:security-lens" "claim-recovery"
assert_eq "T_phase8_claim: old crashed claim tombstone no longer freezes edits" "" \
  "$(run_guard "t_phase8_batch_producer" "" "Edit")"
_return_phase8_batch_role "acme:security-lens" "claim-crash-target"

# A Council-tagged Phase-8 role uses the same safe recovery path. Preparation
# must mark the confirmed-killed row before Council's same-identity ambiguity
# check, while the late abandoned return must not create Council provenance.
jq -n '{
  objective_prompt_ts:12345,
  objective_prompt_revision:9,
  generation:1,
  lifecycle:"primary",
  selections:[{agent:"acme:security-lens",phase:"primary"}]
}' >"${phase8_batch_dir}/council_coverage.json"
council_active_dispatch="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[council:primary] [review-batch] [review-rebind:council-active] active Council semantic review')"
assert_eq "T_phase8_batch: explicitly bound Council target is admitted" \
  "" "${council_active_dispatch}"
council_retry="$(_dispatch_phase8_batch_role "acme:security-lens" \
  '[council:primary] [review-batch] [review-rebind:council-immediate] confirmed interrupted; emit REVIEW_DISPATCH_ID: council-immediate immediately before VERDICT')"
assert_eq "T_phase8_batch: tagged Council role rebinds before TTL" "" \
  "${council_retry}"
council_summary_before=0
if [[ -f "${phase8_batch_dir}/subagent_summaries.jsonl" ]]; then
  council_summary_before="$(jq -s 'length' "${phase8_batch_dir}/subagent_summaries.jsonl")"
fi
_return_phase8_batch_role "acme:security-lens" "council-active"
assert_eq "T_phase8_batch: abandoned Council return adds no summary" \
  "${council_summary_before}" \
  "$(jq -s 'length' "${phase8_batch_dir}/subagent_summaries.jsonl")"
_return_phase8_batch_role "acme:security-lens" "council-immediate"
assert_eq "T_phase8_batch: only bound retry records Council return" "1" \
  "$(jq -s 'length' "${phase8_batch_dir}/council_returns.jsonl")"
assert_eq "T_phase8_batch: Council return is bound to replacement identity" \
  "acme:security-lens" \
  "$(tail -n 1 "${phase8_batch_dir}/council_returns.jsonl" | jq -r '.actual_agent')"
teardown_test

setup_test
export OMC_AGENT_FIRST_GATE=off
init_session "t_stale_review_freeze" "execution"
set_agent_first_satisfied "t_stale_review_freeze"
stale_pending_dir="${TEST_HOME}/.claude/quality-pack/state/t_stale_review_freeze"
stale_pending_ts="$(( $(date +%s) - 7201 ))"
printf '%s\n' \
  "{\"ts\":${stale_pending_ts},\"agent_type\":\"quality-reviewer\",\"review_dispatch_causality_version\":1,\"review_revision\":1}" \
  >"${stale_pending_dir}/pending_agents.jsonl"
out_stale_review_edit="$(run_guard "t_stale_review_freeze" "" "Edit")"
assert_eq "T_stale_review_freeze: abandoned reviewer row cannot freeze edits forever" "" "${out_stale_review_edit}"
teardown_test

setup_test
export OMC_AGENT_FIRST_GATE=off
init_session "t_builder_no_freeze" "execution"
set_agent_first_satisfied "t_builder_no_freeze"
builder_pending_dir="${TEST_HOME}/.claude/quality-pack/state/t_builder_no_freeze"
printf '%s\n' \
  '{"agent_type":"frontend-developer","edit_revision":1}' \
  >"${builder_pending_dir}/pending_agents.jsonl"
out_builder_edit="$(run_guard "t_builder_no_freeze" "" "Edit")"
assert_eq "T_builder_no_freeze: ordinary specialist does not freeze mutation" "" "${out_builder_edit}"
teardown_test

# ----------------------------------------------------------------------
# Definition session-authority boundary. The main model may inspect causal
# ledgers, but it cannot invoke their publisher hooks or write receipt/contract
# state through Bash, direct file tools, or connectors.
setup_test
export OMC_AGENT_FIRST_GATE=off
init_session "t_definition_authority" "execution"
definition_authority_dir="${TEST_HOME}/.claude/quality-pack/state/t_definition_authority"
jq '. + {quality_contract_required:"1"}' \
  "${definition_authority_dir}/session_state.json" \
  >"${definition_authority_dir}/session_state.json.tmp"
mv "${definition_authority_dir}/session_state.json.tmp" \
  "${definition_authority_dir}/session_state.json"

out_authority_hook="$(run_guard "t_definition_authority" \
  "bash ${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-verification.sh")"
assert_contains "T_definition_authority: direct recorder invocation is denied" \
  '"permissionDecision":"deny"' "${out_authority_hook}"
assert_contains "T_definition_authority: denial names harness-owned causal state" \
  'authority boundary' "${out_authority_hook}"

out_authority_redirect="$(run_guard "t_definition_authority" \
  "printf forged > ${definition_authority_dir}/verification_receipts.jsonl")"
assert_contains "T_definition_authority: Bash write into session state is denied" \
  '"permissionDecision":"deny"' "${out_authority_redirect}"

write_payload="$(jq -nc --arg sid "t_definition_authority" \
  --arg path "${definition_authority_dir}/quality_contract.json" '{
    session_id:$sid,tool_name:"Write",hook_event_name:"PreToolUse",
    tool_input:{file_path:$path,content:"{}"}
  }')"
out_authority_write="$(printf '%s' "${write_payload}" \
  | bash "${HOOK_SCRIPT}" 2>/dev/null || true)"
assert_contains "T_definition_authority: direct Write into session state is denied" \
  '"permissionDecision":"deny"' "${out_authority_write}"

mcp_payload="$(jq -nc --arg sid "t_definition_authority" \
  --arg path "${definition_authority_dir}/quality_frontier.json" '{
    session_id:$sid,tool_name:"mcp__filesystem__write_file",
    hook_event_name:"PreToolUse",tool_input:{path:$path,content:"{}"}
  }')"
out_authority_mcp="$(printf '%s' "${mcp_payload}" \
  | bash "${HOOK_SCRIPT}" 2>/dev/null || true)"
assert_contains "T_definition_authority: connector write into session state is denied" \
  '"permissionDecision":"deny"' "${out_authority_mcp}"

out_authority_read="$(run_guard "t_definition_authority" \
  "jq . ${definition_authority_dir}/session_state.json")"
assert_eq "T_definition_authority: read-only inspection remains allowed" \
  "" "${out_authority_read}"
teardown_test

# A non-execution label is valid only while the turn is actually read-only.
# Once an objective has an armed Definition, every recognized mutation surface
# must pass the same frozen-contract gate; otherwise an advisory Write could
# create bytes that its inert Stop path never certifies.
setup_test
export OMC_AGENT_FIRST_GATE=off
init_session "t_definition_advisory_mutation" "advisory"
definition_advisory_dir="${TEST_HOME}/.claude/quality-pack/state/t_definition_advisory_mutation"
jq '. + {quality_contract_required:"1",prompt_classified_intent:"advisory",prompt_revision:1}' \
  "${definition_advisory_dir}/session_state.json" \
  >"${definition_advisory_dir}/session_state.json.tmp"
mv "${definition_advisory_dir}/session_state.json.tmp" \
  "${definition_advisory_dir}/session_state.json"
out_definition_advisory_write="$(run_guard \
  "t_definition_advisory_mutation" "" "Write")"
assert_contains "T_definition_advisory_mutation: advisory Write cannot bypass missing frozen contract" \
  '"permissionDecision":"deny"' "${out_definition_advisory_write}"
assert_contains "T_definition_advisory_mutation: denial names pre-mutation Definition gate" \
  'pre-mutation block' "${out_definition_advisory_write}"
out_definition_advisory_read="$(run_guard \
  "t_definition_advisory_mutation" "jq . README.md")"
assert_eq "T_definition_advisory_mutation: genuinely read-only advisory inspection stays inert" \
  "" "${out_definition_advisory_read}"
teardown_test

# ----------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
