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
#   - kill-switch (OMC_PRETOOL_INTENT_GUARD=false) bypasses the guard entirely
#
# This file complements the broader e2e Gap 8 coverage in
# test-e2e-hook-sequence.sh; it isolates the gate so failures point at the
# gate itself, not at compact-handoff plumbing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh"

ORIG_HOME="${HOME}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
}

teardown_test() {
  export HOME="${ORIG_HOME}"
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

# T0c11 (quality-reviewer F2 MEDIUM): `git tag --column always v1.0`
# is the documented-limitation class shared with the advisory matcher.
# `--column` is a list-mode flag, but a trailing positional tag name
# would create. The regex stops at the flag without checking for the
# positional, so this currently ALLOWS. Locking the known shape
# prevents silent regression in either direction. The mitigation
# (Stop-hook mark-edit tracker + quality-reviewer pass) catches the
# mutation downstream even when the floor lets it through.
setup_test
init_session "t0c11" "execution"
out_t0c11="$(run_guard "t0c11" "git tag --column always v1.0")"
assert_eq "T0c11: --column flag-then-positional allowed (documented limit)" "" "${out_t0c11}"
teardown_test

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
# T11 (kill switch): OMC_PRETOOL_INTENT_GUARD=false bypasses the guard.
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

# ----------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
