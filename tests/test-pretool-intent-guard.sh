#!/usr/bin/env bash
# test-pretool-intent-guard.sh — focused regression for pretool-intent-guard.sh.
#
# Coverage (19 cases / 42 assertions):
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
# T1 (control): execution intent + `git commit` → allow (silent exit 0)
setup_test
init_session "t1" "execution"
out_t1="$(run_guard "t1" "git commit -m 'real work'")"
assert_eq "T1: execution + commit allowed silently" "" "${out_t1}"
teardown_test

# ----------------------------------------------------------------------
# T2 (control): continuation intent + `git push` → allow
setup_test
init_session "t2" "continuation"
out_t2="$(run_guard "t2" "git push origin main")"
assert_eq "T2: continuation + push allowed silently" "" "${out_t2}"
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
# T8: advisory + active wave plan + non-Bash tool → silent allow. The
# guard already short-circuits on non-Bash tools at line 46-48; this test
# is a regression check that the wave-override logic does not perturb the
# tool-name short-circuit.
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
# T10 (text contract, positive side): the deny reason DOES include the
# corrective guidance — propose a concrete imperative the user can paste
# back verbatim, instead of soliciting a confirmation.
setup_test
init_session "t10" "advisory"
out_t10="$(run_guard "t10" "git commit -m 'x'")"
assert_contains "T10: reason includes 'concrete imperative' guidance" \
  "concrete imperative" "${out_t10}"
assert_contains "T10: reason includes 'reply with:' template" \
  "reply with:" "${out_t10}"
assert_contains "T10: reason cites core.md FORBIDDEN rule" \
  "FORBIDDEN" "${out_t10}"
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
# default 30-minute TTL must NOT trigger the override. This protects
# against stale findings.json leaking the per-wave authorization into
# unrelated later work in the same session.
setup_test
init_session "t16" "advisory"
# Set updated_ts to 2 hours ago — well outside the default 1800s TTL.
stale_ts=$(( $(date +%s) - 7200 ))
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
printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
