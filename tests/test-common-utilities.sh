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
# JSON-to-shell boundary
# ===========================================================================
printf 'json_get JSON-to-shell boundary:\n'
HOOK_JSON='{"plain":"safe","count":7}'
assert_eq "json_get preserves ordinary strings" "safe" \
  "$(json_get '.plain')"
assert_eq "json_get preserves non-string scalar behavior" "7" \
  "$(json_get '.count')"
HOOK_JSON='{"plain":"safe","poison":"safe\u0000suffix","count":7}'
assert_eq "json_get rejects decoded NUL before Bash normalization" "" \
  "$(json_get '.poison')"
assert_eq "json_get rejects the complete poisoned hook envelope" "" \
  "$(json_get '.plain')"
HOOK_JSON=''

# The stock-macOS fallback must cancel its timer process after a successful
# finite stdin read. The former synchronous `sleep` watchdog made every hook
# pay the complete timeout even though the reader had already reached EOF.
_stdin_fast_started="$(now_epoch)"
_stdin_fast_payload="$({
  printf '%s\n' '{"session_id":"stdin-fast-path"}'
} | OMC_TEST_FORCE_HOOK_STDIN_FALLBACK=1 \
    OMC_HOOK_STDIN_TIMEOUT_S=5 _omc_read_hook_stdin)"
_stdin_fast_finished="$(now_epoch)"
assert_eq "native stdin fallback preserves a finite payload" \
  '{"session_id":"stdin-fast-path"}' "${_stdin_fast_payload}"
if [[ "${_stdin_fast_started}" =~ ^[0-9]+$ \
    && "${_stdin_fast_finished}" =~ ^[0-9]+$ \
    && $((_stdin_fast_finished - _stdin_fast_started)) -le 2 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: native stdin fallback retained its five-second timer (elapsed=%s)\n' \
    "$((_stdin_fast_finished - _stdin_fast_started))" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# now_epoch observer authority
# ===========================================================================
printf 'now_epoch observer authority:\n'
_clock_poison_dir="${TEST_STATE_ROOT}/clock-poison-bin"
_clock_poison_marker="${TEST_STATE_ROOT}/clock-poison-ran"
mkdir -p "${_clock_poison_dir}"
printf '%s\n' '#!/usr/bin/env bash' \
  ': >"${OMC_TEST_CLOCK_POISON_MARKER}"' \
  "printf '999999999999999999999999'" \
  >"${_clock_poison_dir}/date"
chmod +x "${_clock_poison_dir}/date"
_trusted_now="$(PATH="${_clock_poison_dir}:${PATH}" \
  OMC_TEST_CLOCK_POISON_MARKER="${_clock_poison_marker}" now_epoch)"
if _omc_canonical_uint_in_range \
    "${_trusted_now}" 1 999999999999999; then
  pass=$((pass + 1))
else
  printf '  FAIL: trusted now_epoch returned malformed authority: %q\n' \
    "${_trusted_now}" >&2
  fail=$((fail + 1))
fi
assert_eq "hostile PATH date shim is not executed" "0" \
  "$([[ -e "${_clock_poison_marker}" ]] && printf 1 || printf 0)"
_clock_bash_env="${TEST_STATE_ROOT}/clock-bash-env.sh"
_clock_command_marker="${TEST_STATE_ROOT}/clock-command-function-ran"
_clock_date_marker="${TEST_STATE_ROOT}/clock-date-function-ran"
printf '%s\n' \
  'command() { : >"${OMC_TEST_CLOCK_COMMAND_MARKER}"; "$@"; }' \
  'date() { : >"${OMC_TEST_CLOCK_DATE_MARKER}"; printf "999999999999999999999999"; }' \
  >"${_clock_bash_env}"
_fresh_trusted_now="$(
  OMC_TEST_CLOCK_COMMAND_MARKER="${_clock_command_marker}" \
  OMC_TEST_CLOCK_DATE_MARKER="${_clock_date_marker}" \
  BASH_ENV="${_clock_bash_env}" \
    bash -c '. "$1"; now_epoch' -- \
      "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
)"
if _omc_canonical_uint_in_range \
    "${_fresh_trusted_now}" 1 999999999999999; then
  pass=$((pass + 1))
else
  printf '  FAIL: fresh-shell trusted clock returned malformed authority: %q\n' \
    "${_fresh_trusted_now}" >&2
  fail=$((fail + 1))
fi
assert_eq "BASH_ENV command function cannot intercept the clock" "0" \
  "$([[ -e "${_clock_command_marker}" ]] && printf 1 || printf 0)"
assert_eq "BASH_ENV date function cannot intercept the clock" "0" \
  "$([[ -e "${_clock_date_marker}" ]] && printf 1 || printf 0)"

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

assert_eq "over limit: hard cap includes ellipsis" \
  "1234567..." \
  "$(truncate_chars 10 "12345678901234")"

assert_eq "limit 0: hard cap is empty" \
  "" \
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

# v1.40.x cross-session-handoff regression: the v1.27.0 tightening
# accidentally created an asymmetry — intra-session boundaries ("next
# wave", "next phase") were caught but the most explicit cross-session
# boundary phrasings ("next session", "future session", "later
# session", "separate session") were not. A reported failure had the
# model close a session at ~33% context with "Both candidates for next
# session." — the gate did not fire because the regex literally never
# tested for "next session". These cases lock the gap closed.
#
# Quality-reviewer FP audit drove two design refinements during the
# same change: (1) `fresh session\b` was dropped — ambient phrasing in
# session-start-compact-handoff.sh ("do not treat … as a fresh
# session"), session-start-welcome.sh ("this fresh session"), and
# router directive text would false-positive when echoed by the model.
# (2) Preposition `for|to|in|until` is REQUIRED before the
# adjective+session pair — rejects descriptive contexts ("as a fresh
# session", "on the next session start", "per fresh session start")
# and quoted anti-patterns ("I will not say wave 2 next session"). The
# residual known FP is "tracks to a future session" (validator's own
# effort-excuse example) — probability low, /ulw-skip is the recovery.

# Preposition-shaped TP cases (the v1.40.x additions catch these via
# `(for|to|in|until)\s+(a|the|another)?\s+(next|future|later|separate)
# \s+session`).
assert_exit "for next session: matches (the reported failure)" "0" \
  has_unfinished_session_handoff "Both candidates for next session."

assert_exit "for next session (scheduled): matches" "0" \
  has_unfinished_session_handoff "Remaining work scheduled for next session."

assert_exit "in a future session: matches" "0" \
  has_unfinished_session_handoff "Better handled in a future session."

assert_exit "for a later session: matches" "0" \
  has_unfinished_session_handoff "Queue this for a later session."

assert_exit "for a future session (save): matches" "0" \
  has_unfinished_session_handoff "Save the heavy refactor for a future session."

assert_exit "to next session (defer): matches" "0" \
  has_unfinished_session_handoff "Defer this to next session."

# The reported defer text in full — must match end-to-end via the
# trailing "Both candidates for next session." sentence.
assert_exit "v1.40.x reported defer text: matches" "0" \
  has_unfinished_session_handoff "Remaining heavy refactors queued from the original v12 plan. These are multi-hour each with UI-render verification requirements. A fresh /council pass on the current branch would also surface post-v12 findings cleanly. Both candidates for next session."

# False-positive guards — must NOT match. These are real phrasings
# present in the harness's own scripts and docs that the model might
# echo in a stop summary; without these guards the regex would create
# block-storms when the model quotes its own context.
assert_exit "as a fresh session (compact directive echo): no match" "1" \
  has_unfinished_session_handoff "Do not treat this compact boundary as a fresh session."

assert_exit "fresh session start (install banner echo): no match" "1" \
  has_unfinished_session_handoff "The install banner shows once per fresh session start."

assert_exit "on the next session start (hook descriptive): no match" "1" \
  has_unfinished_session_handoff "On the next session start, the hook will rehydrate state."

assert_exit "anti-pattern quote: no match" "1" \
  has_unfinished_session_handoff "I will not say wave 2 next session — that is the anti-pattern."

assert_exit "future sessions inherit (atlas description): no match" "1" \
  has_unfinished_session_handoff "Future sessions should look at memory/MEMORY.md."

assert_exit "within this session — no match" "1" \
  has_unfinished_session_handoff "Within this session we shipped everything."

assert_exit "session-handoff (compound noun) — no match" "1" \
  has_unfinished_session_handoff "The session-handoff gate fires correctly."

# v1.40.x-newer cross-session-handoff regression: the v1.40.x regex
# caught "next session" / "future session" / "later session" but not
# "next prompt" — slipping past on TWO axes. A real reported failure
# had the model stop a mid-wave council session at W6/16 with the
# literal phrase: "Continue from there in your next prompt." The
# regex missed because:
#   (1) article slot `(a |the |another )?` excluded possessive
#       pronouns (your / my / our were ungrammatical to the gate)
#   (2) noun was hardcoded `session`; the model's handoff phrasings
#       also use prompt / turn / message / response (all
#       future-invocation-context tokens with the same semantic
#       shape).
# These cases lock the gap closed.

# Positive cases — must MATCH (gate fires)
assert_exit "v1.40.x-newer: 'in your next prompt' (reported failure)" "0" \
  has_unfinished_session_handoff "Continue from there in your next prompt."

assert_exit "v1.40.x-newer: 'in your next turn' (sibling shape)" "0" \
  has_unfinished_session_handoff "Pick this up in your next turn."

assert_exit "v1.40.x-newer: 'for your next message' (alternate possessive)" "0" \
  has_unfinished_session_handoff "Save the rest for your next message."

assert_exit "v1.40.x-newer: 'in the next response' (article=the, noun=response)" "0" \
  has_unfinished_session_handoff "I'll address W7 in the next response."

assert_exit "v1.40.x-newer: 'in our next prompt' (article=our)" "0" \
  has_unfinished_session_handoff "Deferred to our next prompt — too much for now."

# Full reported failure phrasing — must MATCH end-to-end
assert_exit "v1.40.x-newer: reported failure full text matches" "0" \
  has_unfinished_session_handoff "Next. W7 (PortfolioPerformanceMetrics — TWR/MWR/drawdown + benchmark overlay) is the highest-impact remaining wave per the user's core-feature recapitulation. Continue from there in your next prompt."

# False-positive guards — must NOT match. Bare "next prompt" / "next
# turn" without preposition-anchor are legitimate non-handoff prose
# in the harness's own corpus (e.g., classifier debug discussion,
# docs explaining inter-turn behavior). Without preposition guards
# these phrases would block-storm.
assert_exit "bare 'next prompt' (no preposition): no match" "1" \
  has_unfinished_session_handoff "Will check the next prompt for context."

assert_exit "'into the next turn' (preposition=into, not in list): no match" "1" \
  has_unfinished_session_handoff "Emits a one-line summary into the next turn's context."

assert_exit "'on the next turn' (preposition=on, not in list): no match" "1" \
  has_unfinished_session_handoff "Records misfires on the next turn when patterns appear."

assert_exit "'this prompt' (no next/future adjective): no match" "1" \
  has_unfinished_session_handoff "I'll handle that in this prompt itself."

# v1.42.x stop-guard bypass closure (Bypass-Surface F-001 / abstraction-
# critic): the regex was a fixed-set match against an open vocabulary.
# Three new pattern classes added — noun-slot expansion (work-cadence
# nouns), adjective-slot expansion (subsequent/dedicated/follow-on/up),
# and three preposition-anchored follow-up idioms.

# (A) NOUN SLOT EXPANSION — new boundary nouns
assert_exit "v1.42.x: 'in the next pass' (noun=pass)" "0" \
  has_unfinished_session_handoff "Leave the broader refactor for the next pass."

assert_exit "v1.42.x: 'for a future iteration' (noun=iteration)" "0" \
  has_unfinished_session_handoff "Additional polish remains for a future iteration."

assert_exit "v1.42.x: 'in a subsequent cycle' (noun=cycle)" "0" \
  has_unfinished_session_handoff "Deferring to a subsequent cycle."

assert_exit "v1.42.x: 'for the next sprint' (noun=sprint)" "0" \
  has_unfinished_session_handoff "Flagging these for the next sprint."

# (B) ADJECTIVE SLOT EXPANSION — new adjectives
assert_exit "v1.42.x: 'for a dedicated pass' (adj=dedicated)" "0" \
  has_unfinished_session_handoff "Leave the broader refactor for a dedicated pass."

assert_exit "v1.42.x: 'for a follow-up commit' (adj=follow-up)" "0" \
  has_unfinished_session_handoff "Save the rest for a follow-up commit."

assert_exit "v1.42.x: 'for follow-on work' (adj=follow-on)" "0" \
  has_unfinished_session_handoff "Earmarked for follow-on work."

# (C) FOLLOW-UP IDIOMS — preposition-anchored
assert_exit "v1.42.x: 'as a known follow-up' (idiom)" "0" \
  has_unfinished_session_handoff "Documented as a known follow-up."

assert_exit "v1.42.x: 'as a known limitation' (idiom)" "0" \
  has_unfinished_session_handoff "Leaving as a known limitation."

assert_exit "v1.42.x: 'queued for later' (deferral verb idiom)" "0" \
  has_unfinished_session_handoff "The deeper architectural work is queued for later."

assert_exit "v1.42.x: 'parked for follow-up' (deferral verb idiom)" "0" \
  has_unfinished_session_handoff "Parking this for follow-up — too complex this turn."

assert_exit "v1.42.x: 'earmarked for the future' (idiom)" "0" \
  has_unfinished_session_handoff "Earmarked for the future."

assert_exit "v1.42.x: 'noted for later' (lightweight idiom)" "0" \
  has_unfinished_session_handoff "Noted for later attention."

assert_exit "v1.42.x: 'flagged for follow-up' (idiom)" "0" \
  has_unfinished_session_handoff "These are flagged for follow-up review."

# (D) PERMISSION-CODED CONTINUATION ASK — remaining work hidden behind
# "say keep going" / "if you want me to continue" rather than explicit
# "next session" wording.
assert_exit "v1.42.x follow-up: conditional wave continuation ask matches" "0" \
  has_unfinished_session_handoff 'Next. If you want Wave 7-9 shipped in this session, I can continue -- say "keep going" and name which of the above to prioritize. Otherwise this is a clean stopping point for v33 with a documented v34 entry plan.'

assert_exit "v1.42.x follow-up: say keep going with remaining work matches" "0" \
  has_unfinished_session_handoff 'Say "keep going" and I will handle the remaining waves.'

assert_exit "v1.42.x follow-up: clean stopping point with entry plan matches" "0" \
  has_unfinished_session_handoff "Otherwise this is a clean stopping point for v33 with a documented v34 entry plan."

# FALSE-POSITIVE GUARDS for v1.42.x additions
assert_exit "v1.42.x FP: 'the next pass through the loop': no match" "1" \
  has_unfinished_session_handoff "The next pass through the loop normalizes the data."

assert_exit "v1.42.x FP: 'a follow-up question' (descriptive): no match" "1" \
  has_unfinished_session_handoff "I have a follow-up question about that."

assert_exit "v1.42.x FP: 'queued behind the request' (no for/as later/future): no match" "1" \
  has_unfinished_session_handoff "The job is queued behind the request."

assert_exit "v1.42.x FP: 'this iteration' (no preposition+adj): no match" "1" \
  has_unfinished_session_handoff "We addressed all findings this iteration."

assert_exit "v1.42.x FP: classifier docs mention keep going: no match" "1" \
  has_unfinished_session_handoff "The continuation classifier treats keep going as a continuation prompt."

assert_exit "v1.42.x FP: optional explanation without unfinished scope: no match" "1" \
  has_unfinished_session_handoff "If you want, I can continue explaining the tradeoffs."

# ===========================================================================
# is_checkpoint_request — iterate-N-times prompt locks no-bypass invariant
# ===========================================================================
printf 'is_checkpoint_request (iterate-N-times regression):\n'

# v1.40.x-newer regression: the reported failure session was started
# with "Iterate the above request 8 times and each time with a fresh
# eye (clear the context with /new if you can)" — this is a council
# multi-wave execution prompt with a META permission for the agent
# to /new BETWEEN iterations. It is NOT a checkpoint request; the
# imperative verb "Iterate" must trigger Phase 3's imperative guard
# in is_checkpoint_request and short-circuit any Phase 5 keyword
# matching on "/new" / "clear the context".
# Without this guard, the gate would treat the entire session as
# checkpoint-authorized and bypass session-handoff blocking even on
# mid-iteration stops.
assert_exit "iterate N times with /new — NOT a checkpoint (imperative wins)" "1" \
  is_checkpoint_request "Iterate the above request 8 times and each time with a fresh eye (clear the context with /new if you can)"

assert_exit "iterate 8x — NOT a checkpoint (no checkpoint keyword)" "1" \
  is_checkpoint_request "Iterate 8 times with fresh context between iterations."

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
_omc_env_model_tier=""
OMC_STALL_THRESHOLD=12
OMC_EXCELLENCE_FILE_COUNT=3
OMC_STATE_TTL_DAYS=7
OMC_MODEL_TIER=""
OLD_HOME="${HOME}"
OLD_PWD="${PWD}"
HOME="${FAKE_HOME_DIR}"
cd "${FAKE_HOME_DIR}"
load_conf
cd "${OLD_PWD}"
HOME="${OLD_HOME}"

assert_eq "conf stall_threshold=20" "20" "${OMC_STALL_THRESHOLD}"
assert_eq "conf excellence_file_count=5" "5" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "conf state_ttl_days=14" "14" "${OMC_STATE_TTL_DAYS}"
assert_eq "conf model_tier=balanced" "balanced" "${OMC_MODEL_TIER:-}"

# The legacy debug reader bypasses load_conf, but must still honor the public
# exact-key/edge-trim/last-valid contract instead of enabling on any earlier
# true row forever.
cat >> "${conf_file}" <<'CONF'
hook_debug=maybe
CONF
printf 'hook_debug=  false  \n' >> "${conf_file}"
HOME="${FAKE_HOME_DIR}"
_hook_debug_checked=0
_hook_debug_enabled=""
if is_hook_debug; then hook_debug_actual=on; else hook_debug_actual=off; fi
assert_eq "hook_debug last valid padded false wins" "off" "${hook_debug_actual}"
printf 'hook_debug=  true  \n' >> "${conf_file}"
_hook_debug_checked=0
_hook_debug_enabled=""
if is_hook_debug; then hook_debug_actual=on; else hook_debug_actual=off; fi
assert_eq "hook_debug later padded true wins" "on" "${hook_debug_actual}"
HOME="${OLD_HOME}"

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
stall_threshold=12abc
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

assert_eq "suffixed-numeric stall_threshold ignored" "12" "${OMC_STALL_THRESHOLD}"
assert_eq "zero excellence_file_count ignored" "3" "${OMC_EXCELLENCE_FILE_COUNT}"
assert_eq "negative state_ttl_days ignored" "7" "${OMC_STATE_TTL_DAYS}"

# The generic lexical comparator must admit every canonical single digit and
# reject digit-prefixed junk. This catches accidental regex-style use of a
# shell glob (`[0-9]*`), whose `*` matches arbitrary characters.
while IFS='|' read -r uint_value uint_expected uint_label; do
  [[ -n "${uint_value}" ]] || continue
  if _omc_canonical_uint_in_range "${uint_value}" 1 2147483647; then
    uint_actual=valid
  else
    uint_actual=invalid
  fi
  assert_eq "canonical uint helper ${uint_label}" \
    "${uint_expected}" "${uint_actual}"
done <<'CANONICAL_UINT_CASES'
1|valid|accepts 1
5|valid|accepts 5
9|valid|accepts 9
12abc|invalid|rejects digit-prefixed junk
CANONICAL_UINT_CASES

# record_gate_skip performs a state-backed read/modify/write. Durable state can
# be malformed after a manual edit or interrupted migration, so the counter
# must never feed Bash arithmetic until it passes the canonical uint guard.
saved_gate_skips_file="${_GATE_SKIPS_FILE}"
saved_gate_skips_lock="${_GATE_SKIPS_LOCK}"
_GATE_SKIPS_FILE="${TEST_STATE_ROOT}/gate-skips.jsonl"
_GATE_SKIPS_LOCK="${TEST_STATE_ROOT}/.gate-skips.lock"
write_state "skip_count" '7*7'
record_gate_skip "malformed-counter-regression"
assert_eq "gate skip rejects arithmetic-expression state" \
  "1" "$(read_state "skip_count")"
write_state "skip_count" "7"
record_gate_skip "canonical-counter-regression"
assert_eq "gate skip increments canonical counter" \
  "8" "$(read_state "skip_count")"
write_state "skip_count" "999999999999999999"
record_gate_skip "overflow-counter-regression"
assert_eq "gate skip resets counter outside safe increment range" \
  "1" "$(read_state "skip_count")"
_GATE_SKIPS_FILE="${saved_gate_skips_file}"
_GATE_SKIPS_LOCK="${saved_gate_skips_lock}"

single_digit_env_actual="$(HOME="${FAKE_HOME_DIR}" \
  OMC_STALL_THRESHOLD=5 BASH_ENV=/dev/null bash -c '
    cd "$1" || exit 1
    . "$2"
    printf "%s" "${OMC_STALL_THRESHOLD}"
  ' bash "${FAKE_HOME_DIR}" \
    "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh")"
assert_eq "single-digit numeric environment override accepted" \
  "5" "${single_digit_env_actual}"

suffixed_env_actual="$(HOME="${FAKE_HOME_DIR}" \
  OMC_STALL_THRESHOLD=12abc BASH_ENV=/dev/null bash -c '
    cd "$1" || exit 1
    . "$2"
    printf "%s" "${OMC_STALL_THRESHOLD}"
  ' bash "${FAKE_HOME_DIR}" \
    "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh")"
assert_eq "suffixed numeric environment override ignored" \
  "12" "${suffixed_env_actual}"

control_char_bin="${FAKE_HOME_DIR}/claude"$'\033'"shim"
printf '#!/usr/bin/env bash\nexit 0\n' > "${control_char_bin}"
chmod +x "${control_char_bin}"
if _omc_claude_bin_value_is_valid "${control_char_bin}"; then
  assert_eq "claude_bin validator rejects control-character path" \
    "invalid" "valid"
else
  assert_eq "claude_bin validator rejects control-character path" \
    "invalid" "invalid"
fi
rm -f "${control_char_bin}"

for control_key in custom_verify_mcp_tools custom_verify_patterns; do
  if _omc_normalize_config_value "${control_key}" \
      "trusted"$'\t'"matcher" >/dev/null 2>&1; then
    control_actual=valid
  else
    control_actual=invalid
  fi
  assert_eq "${control_key} rejects non-newline control bytes" \
    "invalid" "${control_actual}"
done

# Constitution context bounds are compared lexically, never as attacker-sized
# Bash integers (which can wrap or interpret leading zeroes as octal).
while IFS='|' read -r cap_value cap_expected cap_label; do
  [[ -n "${cap_value}" ]] || continue
  if _omc_quality_constitution_context_cap_is_valid "${cap_value}"; then
    cap_actual=valid
  else
    cap_actual=invalid
  fi
  assert_eq "context cap helper ${cap_label}" "${cap_expected}" "${cap_actual}"
done <<'CONTEXT_CAP_CASES'
511|invalid|rejects 511
512|valid|accepts 512
12000|valid|accepts 12000
12001|invalid|rejects 12001
99999999999999999999999999999999999999999999999999|invalid|rejects huge decimal
0512|invalid|rejects leading-zero 512
08|invalid|rejects octal-looking decimal
CONTEXT_CAP_CASES

rm -f "${conf_file}"
while IFS='|' read -r cap_value cap_expected cap_label; do
  [[ -n "${cap_value}" ]] || continue
  cap_actual="$(HOME="${FAKE_HOME_DIR}" \
    OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS="${cap_value}" \
    BASH_ENV=/dev/null bash -c '
      cd "$1" || exit 1
      . "$2"
      printf "%s" "${OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS}"
    ' bash "${FAKE_HOME_DIR}" \
      "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh")"
  assert_eq "context cap environment ${cap_label}" \
    "${cap_expected}" "${cap_actual}"
done <<'CONTEXT_CAP_ENV_CASES'
511|2400|rejects 511
512|512|accepts 512
12000|12000|accepts 12000
12001|2400|rejects 12001
99999999999999999999999999999999999999999999999999|2400|rejects huge decimal
0512|2400|rejects leading-zero 512
08|2400|rejects octal-looking decimal
CONTEXT_CAP_ENV_CASES

OLD_PWD_CONTEXT_CAP="${PWD}"
cd "${FAKE_HOME_DIR}"
while IFS='|' read -r cap_value cap_expected cap_label; do
  [[ -n "${cap_value}" ]] || continue
  printf 'quality_constitution_max_context_chars=%s\n' \
    "${cap_value}" >"${conf_file}"
  _omc_conf_loaded=0
  _omc_env_quality_constitution_max_context_chars=""
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=2400
  HOME="${FAKE_HOME_DIR}"
  load_conf
  HOME="${OLD_HOME}"
  assert_eq "context cap config ${cap_label}" \
    "${cap_expected}" "${OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS}"
done <<'CONTEXT_CAP_CONF_CASES'
511|2400|rejects 511
512|512|accepts 512
12000|12000|accepts 12000
12001|2400|rejects 12001
99999999999999999999999999999999999999999999999999|2400|rejects huge decimal
0512|2400|rejects leading-zero 512
08|2400|rejects octal-looking decimal
CONTEXT_CAP_CONF_CASES
cd "${OLD_PWD_CONTEXT_CAP}"

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
assert_doc "/paper/main.tex"
assert_doc "/paper/references.bib"
assert_doc "/paper/article.typ"
assert_doc "/analysis/report.qmd"
assert_doc "/analysis/report.Rmd"

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
assert_ui "/src/Button.stories.jsx"

# High-confidence native UI surfaces (without treating every Swift/Kotlin file
# as visual work).
assert_ui "/ios/Sources/ProfileView.swift"
assert_ui "/ios/Sources/LoginViewController.swift"
assert_ui "/ios/Views/Profile.swift"
assert_ui "/ios/Base.lproj/Main.storyboard"
assert_ui "/ios/Components/Avatar.xib"
assert_ui "/android/app/src/main/res/layout/activity_main.xml"
assert_ui "/android/ui/Checkout.kt"
assert_ui "/android/screens/CheckoutScreen.kt"

# Negative cases
assert_not_ui "/src/utils.ts"
assert_not_ui "/src/server.js"
assert_not_ui "/config/webpack.config.js"
assert_not_ui "/package.json"
assert_not_ui "README.md"
assert_not_ui "/src/api/handler.py"
assert_not_ui ""
assert_not_ui "/src/styles/index.ts"  # TS is not UI even in styles dir
assert_not_ui "/src/Widget.test.tsx"
assert_not_ui "/src/theme.generated.css"
assert_not_ui "/ios/Sources/NetworkClient.swift"
assert_not_ui "/ios/Models/User.swift"
assert_not_ui "/android/data/UserRepository.kt"

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
  rm -f "$(session_file "edited_files.log")"
  rm -f "$(session_file "findings.json")"
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

# Unknown-scope Bash may have edited prose. Its Bash clock must invalidate a
# prose review that predates the mutation, while a fresh re-review clears it.
reset_dim_state
write_state "last_doc_edit_ts" "1000"
write_state "last_bash_edit_ts" "2000"
write_state "bash_unknown_edit_scope" "1"
tick_dimension "prose" "1500"
if is_dimension_valid "prose"; then
  printf '  FAIL: prose should be stale after unknown-scope Bash mutation\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
tick_dimension "prose" "2500"
if is_dimension_valid "prose"; then
  pass=$((pass + 1))
else
  printf '  FAIL: fresh prose review should clear unknown-scope Bash staleness\n' >&2
  fail=$((fail + 1))
fi

# code dimensions are still invalidated by the code edit at 2000
write_state "last_code_edit_ts" "2000"
tick_dimension "code_quality" "1500"
if is_dimension_valid "code_quality"; then
  printf '  FAIL: code_quality should be stale (1500 < last_code_edit_ts 2000)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# Aggregate dimensions follow last_edit_ts, so a document fix invalidates
# completeness and traceability even when the implementation files are stable.
reset_dim_state
write_state "last_edit_ts" "2000"
tick_dimension "completeness" "1500"
tick_dimension "traceability" "1500"
if is_dimension_valid "completeness" || is_dimension_valid "traceability"; then
  printf '  FAIL: aggregate dimensions should be stale after a later doc/any-surface edit\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
tick_dimension "completeness" "2500"
tick_dimension "traceability" "2500"
if is_dimension_valid "completeness" && is_dimension_valid "traceability"; then
  pass=$((pass + 1))
else
  printf '  FAIL: fresh aggregate reviews should clear last_edit_ts staleness\n' >&2
  fail=$((fail + 1))
fi

# Stress-test reviews inspect plans. Implementation edits do not invalidate a
# completed plan review, but a newer plan does.
reset_dim_state
write_state "plan_ts" "1000"
tick_dimension "stress_test" "1500"
write_state "last_code_edit_ts" "2000"
write_state "last_edit_ts" "2000"
if is_dimension_valid "stress_test"; then
  pass=$((pass + 1))
else
  printf '  FAIL: implementation edit should not invalidate stress_test\n' >&2
  fail=$((fail + 1))
fi
write_state "plan_ts" "2500"
if is_dimension_valid "stress_test"; then
  printf '  FAIL: a newer plan should invalidate stress_test\n' >&2
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

# get_required_dimensions derives coverage from actual surfaces and breadth.
reset_dim_state
write_state "code_edit_count" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 1 code file = generic quality" "bug_hunt,code_quality" "${dims}"

reset_dim_state
write_state "code_edit_count" "3"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 3 same-surface code files do not summon a panel" "bug_hunt,code_quality" "${dims}"

reset_dim_state
write_state "code_edit_count" "2"
write_state "doc_edit_count" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 3 mixed files add prose + completeness" \
  "bug_hunt,code_quality,prose,completeness" "${dims}"

reset_dim_state
write_state "code_edit_count" "6"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 6 same-surface code files still use generic quality" \
  "bug_hunt,code_quality" "${dims}"

reset_dim_state
write_state "doc_edit_count" "3"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 3 docs only = prose" "prose" "${dims}"

reset_dim_state
write_state "code_edit_count" "1"
write_state "ui_edit_count" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 1 UI file requires design review" \
  "bug_hunt,code_quality,design_quality" "${dims}"

reset_dim_state
write_state "review_cycle_prompt_ts" "1000"
write_state "review_cycle_ui_semantic" "0"
write_state "code_edit_count" "1"
write_state "ui_edit_count" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions logic-only UI-path edit skips fixed design tax" \
  "bug_hunt,code_quality" "${dims}"

write_state "review_cycle_ui_semantic" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions UI-semantic objective requires design review" \
  "bug_hunt,code_quality,design_quality" "${dims}"

reset_dim_state
write_state "bash_unknown_edit_scope" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions unknown Bash uses generic quality + completeness only" \
  "bug_hunt,code_quality,completeness" "${dims}"

reset_dim_state
write_state "bash_unknown_edit_scope" "1"
write_state "review_cycle_ui_semantic" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions UI-semantic unknown Bash adds design" \
  "bug_hunt,code_quality,design_quality,completeness" "${dims}"

reset_dim_state
write_state "bash_unknown_edit_scope" "1"
write_state "review_cycle_prose_semantic" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions prose-semantic unknown Bash adds prose" \
  "bug_hunt,code_quality,prose,completeness" "${dims}"

# Broad intent and a current complex plan can require completeness without a
# fabricated post-edit Metis dimension. A stale pre-objective plan cannot.
reset_dim_state
write_state "code_edit_count" "1"
write_state "review_cycle_broad_scope" "1"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions broad one-file objective adds completeness" \
  "bug_hunt,code_quality,completeness" "${dims}"

reset_dim_state
write_state "code_edit_count" "3"
write_state "review_cycle_prompt_ts" "1000"
write_state "review_cycle_edit_log_offset" "0"
printf '%s\n' /src/a.ts /src/b.ts /src/c.ts >"$(session_file "edited_files.log")"
write_state "plan_complexity_high" "1"
write_state "plan_ts" "1100"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions current complex plan adds completeness, not stress_test" \
  "bug_hunt,code_quality,completeness" "${dims}"

write_state "plan_ts" "900"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions stale complex plan does not widen current objective" \
  "bug_hunt,code_quality" "${dims}"

# A live Council wave is also breadth evidence, but only while it is pending or
# in progress, inside the authorization TTL, and not older than this objective.
reset_dim_state
wave_now="$(now_epoch)"
printf '{"updated_ts":%s,"waves":[{"status":"pending"}]}\n' "${wave_now}" \
  >"$(session_file "findings.json")"
write_state "code_edit_count" "3"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions active wave adds completeness" \
  "bug_hunt,code_quality,completeness" "${dims}"

write_state "code_edit_count" "6"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions active wave adds traceability at its file threshold" \
  "bug_hunt,code_quality,completeness,traceability" "${dims}"

printf '{"updated_ts":%s,"waves":[{"status":"complete"}]}\n' "${wave_now}" \
  >"$(session_file "findings.json")"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions completed wave does not widen same-surface work" \
  "bug_hunt,code_quality" "${dims}"

printf '{"updated_ts":%s,"waves":[{"status":"in_progress"}]}\n' "${wave_now}" \
  >"$(session_file "findings.json")"
write_state "review_cycle_prompt_ts" "$((wave_now + 1))"
write_state "review_cycle_edit_log_offset" "0"
printf '%s\n' /src/a.ts /src/b.ts /src/c.ts >"$(session_file "edited_files.log")"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions prior-objective wave does not leak forward" \
  "bug_hunt,code_quality" "${dims}"

write_state "review_cycle_prompt_ts" ""
write_state "review_cycle_edit_log_offset" ""
export OMC_WAVE_OVERRIDE_TTL_SECONDS=10
printf '{"updated_ts":%s,"waves":[{"status":"pending"}]}\n' "$((wave_now - 11))" \
  >"$(session_file "findings.json")"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions expired wave does not widen same-surface work" \
  "bug_hunt,code_quality" "${dims}"
unset OMC_WAVE_OVERRIDE_TTL_SECONDS

# Objective boundaries use monotonic events/signatures rather than timestamps,
# so mutations that happen in the same epoch second cannot leak across turns.
reset_dim_state
write_state "review_cycle_prompt_ts" "1000"
write_state "review_cycle_edit_log_offset" "0"
write_state "bash_unknown_edit_scope" "1"
write_state "last_bash_edit_ts" "1000"
write_state "bash_edit_event_count" "7"
write_state "review_cycle_bash_event_base" "7"
assert_eq "review cycle baseline excludes prior same-second unknown Bash" \
  "stale" "$(review_cycle_unknown_bash_current && printf current || printf stale)"
write_state "bash_edit_event_count" "8"
assert_eq "review cycle event delta includes current same-second unknown Bash" \
  "current" "$(review_cycle_unknown_bash_current && printf current || printf stale)"

# Pathless connector events use an independent per-surface portfolio. They
# select adaptive reviewers without contaminating Bash uncertainty or
# fabricating unique local files.
reset_dim_state
write_state "review_cycle_prompt_ts" "1050"
write_state "review_cycle_edit_log_offset" "0"
write_state "review_cycle_external_event_base" "0"
write_state "review_cycle_external_doc_event_base" "0"
write_state "review_cycle_external_ui_event_base" "0"
write_state "review_cycle_external_native_event_base" "0"
write_state "review_cycle_external_unknown_event_base" "0"
assert_eq "fresh zero connector baselines accept absent legacy counters" \
  "0,0,0,0,0" "$(_review_cycle_external_edit_snapshot 1 | paste -sd, -)"
write_state "last_external_edit_ts" "1050"
write_state "external_edit_scope" "doc"
assert_eq "absent legacy counters retain current-cycle timestamp fallback" \
  "1,0,0,0,1" "$(_review_cycle_external_edit_snapshot 1 | paste -sd, -)"

reset_dim_state
write_state "review_cycle_prompt_ts" "1100"
write_state "review_cycle_edit_log_offset" "0"
write_state "review_cycle_external_event_base" "4"
write_state "review_cycle_external_doc_event_base" "2"
write_state "review_cycle_external_ui_event_base" "1"
write_state "review_cycle_external_native_event_base" "1"
write_state "review_cycle_external_unknown_event_base" "0"
write_state "external_edit_event_count" "4"
write_state "external_doc_edit_event_count" "2"
write_state "external_ui_edit_event_count" "1"
write_state "external_native_edit_event_count" "1"
write_state "external_unknown_edit_event_count" "0"
assert_eq "review cycle connector baseline excludes prior remote edits" \
  "0,0,0,0,0,0" "$(review_cycle_edit_snapshot | paste -sd, -)"
write_state "external_edit_event_count" "18446744073709551616"
assert_eq "oversized connector counters fail conservative without signed wrap" \
  "0,0,0,1,1" "$(_review_cycle_external_edit_snapshot 1 | paste -sd, -)"
write_state "external_edit_event_count" "4"
write_state "review_cycle_external_event_base" "04"
assert_eq "non-canonical connector baselines cannot enter Bash arithmetic" \
  "0,0,0,1,1" "$(_review_cycle_external_edit_snapshot 1 | paste -sd, -)"
write_state "review_cycle_external_event_base" "4"
write_state "external_edit_event_count" "5"
write_state "external_doc_edit_event_count" "3"
assert_eq "review cycle connector delta maps document surface without unique path" \
  "0,1,0,0,0,1" "$(review_cycle_edit_snapshot | paste -sd, -)"
assert_eq "document connector selects prose only at narrow scope" \
  "prose" "$(get_required_dimensions)"
# A known pathless remote surface is still material work. The closeout
# fallback must not require either a fabricated local path or an "unknown"
# connector classification before it arms the seal.
write_state "closeout_preflight_required" "1"
write_state "task_intent" "execution"
assert_eq "document connector requires closeout seal without a local path" \
  "required" \
  "$(closeout_seal_is_required && printf required || printf skipped)"
write_state "review_cycle_broad_scope" "1"
assert_eq "broad document connector also selects completeness" \
  "prose,completeness" "$(get_required_dimensions)"

reset_dim_state
write_state "review_cycle_prompt_ts" "1200"
write_state "review_cycle_edit_log_offset" "0"
write_state "review_cycle_external_event_base" "0"
write_state "review_cycle_external_doc_event_base" "0"
write_state "review_cycle_external_ui_event_base" "0"
write_state "review_cycle_external_native_event_base" "0"
write_state "review_cycle_external_unknown_event_base" "0"
write_state "external_edit_event_count" "1"
write_state "external_doc_edit_event_count" "0"
write_state "external_ui_edit_event_count" "1"
write_state "external_native_edit_event_count" "0"
write_state "external_unknown_edit_event_count" "0"
write_state "review_cycle_ui_semantic" "1"
assert_eq "UI connector maps code/UI surfaces without unique path" \
  "1,0,1,0,0,1" "$(review_cycle_edit_snapshot | paste -sd, -)"
assert_eq "UI connector selects code and design reviewers" \
  "bug_hunt,code_quality,design_quality" "$(get_required_dimensions)"

reset_dim_state
write_state "review_cycle_prompt_ts" "1300"
write_state "review_cycle_edit_log_offset" "0"
write_state "review_cycle_external_event_base" "0"
write_state "review_cycle_external_doc_event_base" "0"
write_state "review_cycle_external_ui_event_base" "0"
write_state "review_cycle_external_native_event_base" "0"
write_state "review_cycle_external_unknown_event_base" "0"
write_state "external_edit_event_count" "1"
write_state "external_doc_edit_event_count" "0"
write_state "external_ui_edit_event_count" "0"
write_state "external_native_edit_event_count" "1"
write_state "external_unknown_edit_event_count" "0"
write_state "review_cycle_broad_scope" "1"
assert_eq "native connector maps document and UI surfaces without unique path" \
  "1,1,1,0,0,2" "$(review_cycle_edit_snapshot | paste -sd, -)"
assert_eq "broad native connector selects cross-surface coverage" \
  "bug_hunt,code_quality,prose,design_quality,completeness" \
  "$(get_required_dimensions)"

reset_dim_state
write_state "review_cycle_prompt_ts" "1400"
write_state "review_cycle_edit_log_offset" "0"
write_state "review_cycle_external_event_base" "0"
write_state "review_cycle_external_doc_event_base" "0"
write_state "review_cycle_external_ui_event_base" "0"
write_state "review_cycle_external_native_event_base" "0"
write_state "review_cycle_external_unknown_event_base" "0"
write_state "external_edit_event_count" "1"
write_state "external_doc_edit_event_count" "0"
write_state "external_ui_edit_event_count" "0"
write_state "external_native_edit_event_count" "0"
write_state "external_unknown_edit_event_count" "1"
write_state "review_cycle_ui_semantic" "1"
write_state "review_cycle_prose_semantic" "1"
assert_eq "unknown connector remains pathless and conservative" \
  "1,0,0,0,1,1" "$(review_cycle_edit_snapshot | paste -sd, -)"
assert_eq "unknown connector selects semantic reviewers plus completeness" \
  "bug_hunt,code_quality,prose,design_quality,completeness" \
  "$(get_required_dimensions)"

reset_dim_state
write_state "review_cycle_prompt_ts" "2000"
write_state "review_cycle_edit_log_offset" "0"
write_state "plan_complexity_high" "1"
write_state "plan_ts" "2000"
write_state "plan_revision" "4"
write_state "review_cycle_plan_revision_base" "4"
assert_eq "review cycle baseline excludes prior same-second complex plan" \
  "stale" "$(review_cycle_has_current_complex_plan && printf current || printf stale)"
write_state "plan_revision" "5"
assert_eq "review cycle revision delta includes current same-second complex plan" \
  "current" "$(review_cycle_has_current_complex_plan && printf current || printf stale)"

reset_dim_state
wave_now="$(now_epoch)"
printf '{"updated_ts":%s,"waves":[{"status":"pending"}]}\n' "${wave_now}" \
  >"$(session_file "findings.json")"
wave_signature="$(_review_cycle_file_signature "$(session_file "findings.json")")"
write_state "review_cycle_prompt_ts" "${wave_now}"
write_state "review_cycle_edit_log_offset" "0"
write_state "review_cycle_findings_signature_base" "${wave_signature}"
assert_eq "review cycle signature excludes unchanged same-second prior wave" \
  "stale" "$(review_cycle_has_active_wave_plan && printf current || printf stale)"
printf '{"updated_ts":%s,"generation":2,"waves":[{"status":"pending"}]}\n' "${wave_now}" \
  >"$(session_file "findings.json")"
assert_eq "review cycle signature delta includes current same-second wave" \
  "current" "$(review_cycle_has_active_wave_plan && printf current || printf stale)"
printf '%s\0%s\n' \
  '{"updated_ts":'"${wave_now}" \
  ',"generation":3,"waves":[{"status":"pending"}]}' \
  >"$(session_file "findings.json")"
assert_eq "raw-NUL wave timestamp cannot become current plan authority" \
  "stale" "$(review_cycle_has_active_wave_plan && printf current || printf stale)"

# Six cross-surface paths require traceability; file count alone above did not.
reset_dim_state
printf '%s\n' \
  /project/src/a.ts /project/src/b.ts /project/src/c.ts /project/src/d.ts \
  /project/docs/a.md /project/docs/b.md >"$(session_file "edited_files.log")"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions 6 mixed paths add completeness + traceability" \
  "bug_hunt,code_quality,prose,completeness,traceability" "${dims}"

# A fresh objective scopes review routing by log offset, not cumulative session
# counters. Re-editing an old path after the offset still counts as current work,
# while duplicate edits inside this objective count once for breadth.
reset_dim_state
printf '%s\n' /project/src/old.ts /project/docs/old.md >"$(session_file "edited_files.log")"
write_state "code_edit_count" "25"
write_state "doc_edit_count" "25"
write_state "review_cycle_prompt_ts" "2000"
write_state "review_cycle_edit_log_offset" "2"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions current objective ignores earlier session edits" "" "${dims}"

printf '%s\n' /project/src/old.ts /project/src/old.ts >>"$(session_file "edited_files.log")"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions repeat old path after baseline counts as current code" \
  "bug_hunt,code_quality" "${dims}"

printf '%s\n' /project/src/new.ts /project/docs/current.md >>"$(session_file "edited_files.log")"
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions current-objective dedup still detects 3-path mixed breadth" \
  "bug_hunt,code_quality,prose,completeness" "${dims}"

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
assert_eq "get_required_dimensions fallback: resumed doc-only" "prose" "${dims}"

reset_dim_state
cat > "${edited_log}" <<'LOG'
/project/src/a.ts
/project/src/b.ts
/project/src/c.ts
LOG
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions fallback: resumed code-only" "bug_hunt,code_quality" "${dims}"

reset_dim_state
cat > "${edited_log}" <<'LOG'
/project/src/a.ts
/project/src/b.ts
/project/docs/c.md
LOG
dims="$(get_required_dimensions)"
assert_eq "get_required_dimensions fallback: resumed mixed" "bug_hunt,code_quality,prose,completeness" "${dims}"

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

assert_eq "detect_verification_method named verifier" \
  "framework_keyword" \
  "$(detect_verification_method "./validate.sh" "test result: ok. 5 passed" "")"

assert_eq "score_verification_confidence all signals = 100" \
  "100" \
  "$(score_verification_confidence "npm test -- --runInBand" "PASS auth\nTests: 10 passed, 0 failed" "npm test")"

assert_eq "score_verification_confidence executed verifier reaches floor = 40" \
  "40" \
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
assert_contains "scorecard reports clean dimension" "code quality (conventions, dead code, comments)" "${scorecard}"
if [[ "${scorecard}" == *"stress-test"* || "${scorecard}" == *"completeness"* ]]; then
  printf '  FAIL: scorecard should omit dimensions not selected for same-surface code work\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

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
  # v1.47 (second CI flake of this fixture's class — the v1.42.0 fix cut
  # 3 git invocations/commit to 1, but 300 sequential porcelain commits
  # on a loaded runner still partially failed: the loop had no error
  # handling under `set -uo pipefail` (no -e), so silently-skipped
  # commits left the count short and the maturity thresholds
  # misclassified — 300/300/11-mem landed "shipping"/"mature" instead of
  # "polish-saturated", flaking run-to-run). ONE `git fast-import`
  # stream now builds all N commits in a single process — no porcelain,
  # no hooks, no per-commit forks — and the count is verified loudly so
  # a short fixture can never silently misclassify again.
  local i
  {
    for ((i = 0; i < commits; i++)); do
      printf 'commit refs/heads/master\ncommitter Test <test@example.com> %d +0000\ndata 2\nm\n\n' "$((1600000000 + i))"
    done
  } | git -C "${dir}" fast-import --quiet >/dev/null 2>&1
  git -C "${dir}" symbolic-ref HEAD refs/heads/master
  local _built
  _built="$(git -C "${dir}" rev-list --count HEAD 2>/dev/null || echo 0)"
  if [[ "${_built}" != "${commits}" ]]; then
    printf '  FATAL: _make_repo_with_commits built %s/%s commits in %s\n' \
      "${_built}" "${commits}" "${dir}" >&2
    return 1
  fi
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
record_agent_metric "test-reviewer" "clean"
metric="$(cat "${_AGENT_METRICS_FILE}")"
assert_eq "record_agent_metric canonical schema v3" "3" "$(jq -r '._schema_version' <<<"${metric}")"
assert_eq "record_agent_metric invocations" "1" "$(jq -r '.agents["test-reviewer"].invocations' <<<"${metric}")"
assert_eq "record_agent_metric clean_verdicts" "1" "$(jq -r '.agents["test-reviewer"].clean_verdicts' <<<"${metric}")"
# v1.48 W3.5: avg_confidence was fabricated (writers passed constants) and
# is no longer written. A legacy extra argument must be ignored, and the
# field must NOT reappear.
assert_eq "record_agent_metric writes no avg_confidence" "false" \
  "$(jq -r '.agents["test-reviewer"] | has("avg_confidence")' <<<"${metric}")"

# Second recording with findings (legacy 3rd arg tolerated, ignored)
record_agent_metric "test-reviewer" "findings" 60
metric="$(cat "${_AGENT_METRICS_FILE}")"
assert_eq "record_agent_metric second invocation" "2" "$(jq -r '.agents["test-reviewer"].invocations' <<<"${metric}")"
assert_eq "record_agent_metric finding_verdicts" "1" "$(jq -r '.agents["test-reviewer"].finding_verdicts' <<<"${metric}")"
assert_eq "record_agent_metric legacy arg leaves no avg_confidence" "false" \
  "$(jq -r '.agents["test-reviewer"] | has("avg_confidence")' <<<"${metric}")"

# Regression: float/null values in existing metrics should not crash;
# stale avg_confidence keys on old entries are dropped on upsert.
printf '{"float-agent":{"invocations":3.7,"clean_verdicts":2.5,"finding_verdicts":1.2,"last_used_ts":100,"avg_confidence":4.5}}' > "${_AGENT_METRICS_FILE}"
record_agent_metric "float-agent" "clean"
metric="$(cat "${_AGENT_METRICS_FILE}")"
inv="$(jq -r '.agents["float-agent"].invocations' <<<"${metric}")"
assert_eq "record_agent_metric survives float values" "4" "${inv}"
assert_eq "legacy flat metric migrated away" "false" "$(jq -r 'has("float-agent")' <<<"${metric}")"
assert_eq "read_agent_metric reads migrated canonical entry" "4" \
  "$(read_agent_metric "float-agent" | jq -r '.invocations')"

# Reader compatibility before the next writer migration.
printf '{"legacy-reader":{"invocations":7,"clean_verdicts":6,"finding_verdicts":1}}' > "${_AGENT_METRICS_FILE}"
assert_eq "read_agent_metric reads legacy flat entry" "7" \
  "$(read_agent_metric "legacy-reader" | jq -r '.invocations')"
assert_eq "get_all_agent_metrics normalizes legacy flat entry" "7" \
  "$(get_all_agent_metrics | jq -r '.agents["legacy-reader"].invocations')"

# A literal NUL in an otherwise parseable numeric token must not be normalized
# and folded into lifetime metrics by jq.
printf '{"legacy-reader":{"invocations":7\0,"clean_verdicts":6,"finding_verdicts":1}}\n' \
  >"${_AGENT_METRICS_FILE}"
metrics_corrupt_before="$(cksum <"${_AGENT_METRICS_FILE}")"
record_agent_metric "legacy-reader" "clean"
assert_eq "raw-NUL metrics are not mutated" \
  "${metrics_corrupt_before}" "$(cksum <"${_AGENT_METRICS_FILE}")"
assert_eq "raw-NUL metrics are not projected to readers" "" \
  "$(read_agent_metric "legacy-reader")"

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
# v1.31.0 Wave 3 (security-lens): reject dots-only IDs that would
# resolve session_file() paths back to STATE_ROOT or its ancestors.
assert_exit "reject single dot" 1 validate_session_id "."
assert_exit "reject double dot" 1 validate_session_id ".."
assert_exit "reject triple dot" 1 validate_session_id "..."
assert_exit "reject 5 dots" 1 validate_session_id "....."
# Mixed dots-and-other content stays accepted (dots are legitimate
# in semver-like IDs; only dots-only is rejected).
assert_exit "accept '1.0-rc.1' (dots with non-dot chars)" 0 validate_session_id "1.0-rc.1"
assert_exit "accept 'a.b'" 0 validate_session_id "a.b"

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
assert_exit "SwiftUI view file" "0" is_ui_path "/ios/ProfileView.swift"
assert_exit "storyboard file" "0" is_ui_path "/ios/Main.storyboard"
assert_exit "Swift core file: not UI" "1" is_ui_path "/ios/NetworkClient.swift"
assert_exit "Android layout XML" "0" is_ui_path "/android/res/layout/main.xml"
assert_exit "Kotlin core file: not UI" "1" is_ui_path "/android/data/Repository.kt"
assert_exit "ts file: not UI" "1" is_ui_path "/src/utils/parser.ts"
assert_exit "py file: not UI" "1" is_ui_path "/server/app.py"
assert_exit "go file: not UI" "1" is_ui_path "/cmd/main.go"
assert_exit "json file: not UI" "1" is_ui_path "/config/settings.json"
assert_exit "sh file: not UI" "1" is_ui_path "/scripts/build.sh"
assert_exit "empty: not UI" "1" is_ui_path ""

# ===========================================================================
# delivery-contract surface classifiers
# ===========================================================================
printf '\ndelivery-contract surface classifiers:\n'

assert_exit "test path: __tests__" "0" is_test_path "/src/__tests__/auth.test.ts"
assert_exit "test path: suffix" "0" is_test_path "/pkg/parser_spec.rb"
assert_exit "test path: non-test source" "1" is_test_path "/src/auth/service.ts"

assert_exit "config path: workflow" "0" is_config_path "/project/.github/workflows/validate.yml"
assert_exit "config path: package.json" "0" is_config_path "/project/package.json"
assert_exit "config path: non-config source" "1" is_config_path "/project/src/app.ts"

assert_exit "release path: CHANGELOG" "0" is_release_path "/project/CHANGELOG.md"
assert_exit "release path: VERSION" "0" is_release_path "/project/VERSION"
assert_exit "release path: regular doc" "1" is_release_path "/project/docs/guide.md"

assert_exit "migration path: migrations dir" "0" is_migration_path "/project/db/migrate/20260505_add_users.sql"
assert_exit "migration path: schema.sql" "0" is_migration_path "/project/schema.sql"
assert_exit "migration path: ordinary sql" "1" is_migration_path "/project/queries/report.sql"

# ===========================================================================
# delivery-contract prompt derivation
# ===========================================================================
printf '\ndelivery-contract prompt derivation:\n'

assert_eq "commit intent: required" \
  "required" \
  "$(detect_commit_intent_from_prompt "fix the bug and commit the changes")"

assert_eq "commit intent: if needed" \
  "if_needed" \
  "$(detect_commit_intent_from_prompt "finish the fix and commit if needed")"

assert_eq "commit intent: forbidden (commit-specific negation)" \
  "forbidden" \
  "$(detect_commit_intent_from_prompt "fix the bug but do not commit or push anything")"

# v1.34.0 (Bug C): forbidden detection is COMMIT-specific. A
# compound directive like "commit X. don't push Y." classifies the
# commit as required (since commit was explicitly authorized) and
# the push side gets its own classifier (`detect_push_intent_from_prompt`).
assert_eq "commit intent: 'commit but don't push' → required (Bug C fix)" \
  "required" \
  "$(detect_commit_intent_from_prompt "commit but don't push")"

assert_eq "commit intent: 'commit X. Don't push Y.' → required" \
  "required" \
  "$(detect_commit_intent_from_prompt "commit the changes first. Don't push it.")"

assert_eq "commit intent: bare 'don't push' → unspecified for commit" \
  "unspecified" \
  "$(detect_commit_intent_from_prompt "don't push")"

# v1.47 (Bug C, sentence-boundary variant — reproduced live in a real
# session): the negation gap window must NOT span a sentence terminator.
# "Don't stop until all done. Commit the changes when needed." sat don't
# and Commit 21 chars apart ACROSS the period and derived FORBIDDEN from
# a prompt that explicitly authorizes commits — which then blocked the
# session's own wave commits at the commit-contract gate.
assert_eq "commit intent: negation must not cross sentence boundary (live repro)" \
  "if_needed" \
  "$(detect_commit_intent_from_prompt "Don't stop until all done. Commit the changes when needed.")"

assert_eq "commit intent: 'Don't stop until done. Commit it.' → required" \
  "required" \
  "$(detect_commit_intent_from_prompt "Don't stop until done. Commit it.")"

# Within-sentence negation still forbids (the fix must not loosen this).
assert_eq "commit intent: within-sentence negation still forbidden" \
  "forbidden" \
  "$(detect_commit_intent_from_prompt "avoid committing until I say so")"

# Push side: the directive is read from ITS sentence — a prior sentence's
# "when needed" qualifier must not downgrade an unconditional later push.
assert_eq "push intent: qualifier must not cross sentence boundary" \
  "required" \
  "$(detect_push_intent_from_prompt "Commit the changes when needed. In the end, push and release.")"

assert_eq "push intent: within-sentence negation still forbidden" \
  "forbidden" \
  "$(detect_push_intent_from_prompt "ship it locally but do not push or release anything")"

# ----------------------------------------------------------------------
# v1.47 (data-lens #1): generic block→reprompt pairing. record_gate_event
# stamps last_any_gate_block_{ts,name} for block-shaped events on gates
# OUTSIDE the two dedicated ones; any_gate_check_post_block_reprompt pairs
# it on the next prompt and emits the reprompt row under the originating
# gate's own name.
printf '\ngeneric block-reprompt pairing:\n'

_ag_sid="agp-$$"
_orig_ag_sid="${SESSION_ID}"
SESSION_ID="${_ag_sid}"
mkdir -p "${STATE_ROOT}/${_ag_sid}"
printf '{}' > "${STATE_ROOT}/${_ag_sid}/session_state.json"

# (a) a non-dedicated gate's block stamps the generic keys.
record_gate_event "review-coverage" "block" "block_count=1"
assert_eq "generic stamp: gate name recorded" \
  "review-coverage" "$(read_state "last_any_gate_block_name")"
_ag_ts="$(read_state "last_any_gate_block_ts")"
if [[ "${_ag_ts}" =~ ^[0-9]+$ ]]; then pass=$((pass+1)); else
  printf '  FAIL: generic stamp ts not numeric (got %s)\n' "${_ag_ts}" >&2; fail=$((fail+1)); fi

# (b) pairing within the window emits post-block-reprompt under the gate's
# name and clears both keys (single-use).
any_gate_check_post_block_reprompt
if grep -q '"gate":"review-coverage","event":"post-block-reprompt"' "${STATE_ROOT}/${_ag_sid}/gate_events.jsonl" 2>/dev/null; then
  pass=$((pass+1))
else
  printf '  FAIL: generic pairing did not emit post-block-reprompt row\n' >&2; fail=$((fail+1))
fi
assert_eq "generic pairing: ts key cleared (single-use)" "" "$(read_state "last_any_gate_block_ts")"
assert_eq "generic pairing: name key cleared (single-use)" "" "$(read_state "last_any_gate_block_name")"

# (c) the two dedicated gates are EXCLUDED from the generic stamp — their
# tuned machinery owns them; double-counting would inflate their rates.
record_gate_event "no-defer-mode" "stop-block" "block_count=1"
assert_eq "dedicated gate excluded from generic stamp (no-defer-mode)" \
  "" "$(read_state "last_any_gate_block_name")"
record_gate_event "objective-contract" "block" "block_count=1"
assert_eq "dedicated gate excluded from generic stamp (objective-contract)" \
  "" "$(read_state "last_any_gate_block_name")"

# (d) non-block events never stamp.
record_gate_event "review-coverage" "audited"
assert_eq "non-block event does not stamp" \
  "" "$(read_state "last_any_gate_block_name")"

rm -rf "${STATE_ROOT:?}/${_ag_sid}"
SESSION_ID="${_orig_ag_sid}"

assert_eq "commit intent: 'do not commit' → forbidden" \
  "forbidden" \
  "$(detect_commit_intent_from_prompt "do not commit")"

assert_eq "commit intent: 'without committing' → forbidden" \
  "forbidden" \
  "$(detect_commit_intent_from_prompt "fix the bug without committing")"

# detect_push_intent_from_prompt — independent push-side classifier.
assert_eq "push intent: 'don't push' → forbidden" \
  "forbidden" \
  "$(detect_push_intent_from_prompt "commit but don't push")"

assert_eq "push intent: 'don't release' → forbidden" \
  "forbidden" \
  "$(detect_push_intent_from_prompt "merge it but don't release")"

assert_eq "push intent: 'don't tag' → forbidden" \
  "forbidden" \
  "$(detect_push_intent_from_prompt "ship the commit, but don't tag yet")"

assert_eq "push intent: 'push when ready' → required" \
  "required" \
  "$(detect_push_intent_from_prompt "push when ready")"

assert_eq "push intent: 'release v2.0' → required" \
  "required" \
  "$(detect_push_intent_from_prompt "release v2.0 to production")"

assert_eq "push intent: 'fix the bug' → unspecified" \
  "unspecified" \
  "$(detect_push_intent_from_prompt "fix the bug")"

assert_eq "push intent: 'commit the changes' → unspecified for push" \
  "unspecified" \
  "$(detect_push_intent_from_prompt "commit the changes")"

assert_eq "prompt surfaces: docs + tests + release" \
  "tests,docs,release" \
  "$(derive_done_contract_prompt_surfaces "fix the bug, add regression coverage, update the README and changelog")"

assert_eq "prompt surfaces: config + migration" \
  "config,migration" \
  "$(derive_done_contract_prompt_surfaces "update the CI workflow and add the migration for the new column")"

assert_eq "test expectation: explicit tests" \
  "add_or_update_tests" \
  "$(derive_done_contract_test_expectation "fix the bug and add regression coverage" "coding")"

assert_eq "test expectation: coding fallback" \
  "verify" \
  "$(derive_done_contract_test_expectation "refactor the auth parser" "coding")"

assert_eq "verification contract: coding + docs + commit" \
  "code_review,code_verify,prose_review,test_surface,release_surface,commit_record" \
  "$(derive_verification_contract_required \
      "fix the bug, add regression coverage, update the changelog, and commit it" \
      "coding" \
      "tests,docs,release" \
      "add_or_update_tests" \
      "required")"

assert_eq "verification contract: publish requested" \
  "code_review,code_verify,commit_record,publish_record" \
  "$(derive_verification_contract_required \
      "fix the bug, commit it, and push to origin" \
      "coding" \
      "" \
      "verify" \
      "required" \
      "required")"

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

# Count text crosses into Bash arithmetic. Invalid stored text must become the
# zero baseline without being evaluated as an arithmetic expression.
defect_arithmetic_marker="${TEST_DEFECT_DIR}/arithmetic-poison-ran"
printf '%s\n' \
  '{"poison":{"count":"x[$(touch '"${defect_arithmetic_marker}"')]","last_seen_ts":1,"examples":[]}}' \
  >"${_DEFECT_PATTERNS_FILE}"
record_defect_pattern "poison" "safe increment"
assert_eq "defect count arithmetic text is never evaluated" "0" \
  "$([[ -e "${defect_arithmetic_marker}" ]] && printf 1 || printf 0)"
assert_eq "invalid defect count restarts canonically" "1" \
  "$(jq -r '.poison.count' "${_DEFECT_PATTERNS_FILE}")"

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

# jq may accept a literal NUL embedded in a numeric token. The byte envelope,
# not jq's recovery behavior, decides whether persistent learning is valid.
printf '{"test":{"count":1\0,"last_seen_ts":100,"examples":[]}}\n' \
  >"${_DEFECT_PATTERNS_FILE}"
_defect_patterns_validated=0
_ensure_valid_defect_patterns
assert_eq "raw-NUL defect patterns reset to empty object" "0" \
  "$(jq -r 'length' "${_DEFECT_PATTERNS_FILE}")"

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

# Numeric state is untrusted text until it passes the shared canonical-decimal
# validator. Shell arithmetic must never interpret expressions from a restored
# or hand-edited telemetry row/counter.
rm -f "${_tel_file}"
record_classifier_telemetry "advisory" "coding" "what do you think?" "0"
detect_classifier_misfire "do it" "1+1" 2>/dev/null || true
assert_eq "non-canonical current block counter cannot drive arithmetic" \
  "0" "$(_count_misfires "${_tel_file}")"
printf '{"ts":"%s","intent":"advisory","domain":"coding","prompt":"x","pretool_blocks_observed":"1+1"}\n' \
  "$(now_epoch)" > "${_tel_file}"
detect_classifier_misfire "do it" "2" 2>/dev/null || true
assert_eq "non-canonical stored block counter cannot drive arithmetic" \
  "0" "$(_count_misfires "${_tel_file}")"

# A sparse oversized leaf is rejected before grep/tail scans it. This keeps a
# corrupted session artifact from turning prompt routing into an unbounded read.
dd if=/dev/null of="${_tel_file}" bs=1 seek=8388609 2>/dev/null
oversized_detect_rc=0
detect_classifier_misfire "do it" "2" 2>/dev/null \
  || oversized_detect_rc=$?
assert_eq "oversized classifier telemetry fails closed" "1" \
  "$([[ "${oversized_detect_rc}" -ne 0 ]] && printf 1 || printf 0)"

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
# v1.32.0 Wave B — _classify_surface + classify_finding_pair
# ===========================================================================
printf '\n_classify_surface (v1.32.0 Wave B):\n'

assert_eq "common.sh → common-lib" \
  "common-lib" \
  "$(_classify_surface "bundle/dot-claude/skills/autowork/scripts/common.sh")"

assert_eq "lib/state-io.sh → common-lib" \
  "common-lib" \
  "$(_classify_surface "bundle/dot-claude/skills/autowork/scripts/lib/state-io.sh")"

assert_eq "quality-pack/scripts/* → hooks" \
  "hooks" \
  "$(_classify_surface "bundle/dot-claude/quality-pack/scripts/stop-failure-handler.sh")"

assert_eq "prompt-intent-router → router" \
  "router" \
  "$(_classify_surface "bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh")"

assert_eq "show-report → telemetry" \
  "telemetry" \
  "$(_classify_surface "bundle/dot-claude/skills/autowork/scripts/show-report.sh")"

assert_eq "install.sh → install" \
  "install" \
  "$(_classify_surface "install.sh")"

assert_eq "uninstall.sh → install (not double-counted)" \
  "install" \
  "$(_classify_surface "uninstall.sh")"

assert_eq "agents/quality-reviewer.md → agents" \
  "agents" \
  "$(_classify_surface "bundle/dot-claude/agents/quality-reviewer.md")"

assert_eq "tests/test-foo.sh → tests" \
  "tests" \
  "$(_classify_surface "tests/test-foo.sh")"

assert_eq "README.md → docs" \
  "docs" \
  "$(_classify_surface "README.md")"

assert_eq "CLAUDE.md → docs" \
  "docs" \
  "$(_classify_surface "CLAUDE.md")"

assert_eq ".github/workflows/validate.yml → ci" \
  "ci" \
  "$(_classify_surface ".github/workflows/validate.yml")"

assert_eq "tools/install-upgrade-sim.sh → tooling" \
  "tooling" \
  "$(_classify_surface "tools/install-upgrade-sim.sh")"

assert_eq "settings.patch.json → config" \
  "config" \
  "$(_classify_surface "config/settings.patch.json")"

assert_eq "empty file → other" \
  "other" \
  "$(_classify_surface "")"

assert_eq "unrecognized path → other" \
  "other" \
  "$(_classify_surface "some/random/path.txt")"

printf '\nclassify_finding_pair (v1.32.0 Wave B):\n'

# Honors agent-emitted category when present
assert_eq "honors agent category bug" \
  "common-lib:bug" \
  "$(classify_finding_pair "bundle/dot-claude/skills/autowork/scripts/common.sh" "bug" "claim text")"

assert_eq "honors agent category security" \
  "router:security" \
  "$(classify_finding_pair "bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" "security" "")"

assert_eq "honors agent integration" \
  "install:integration" \
  "$(classify_finding_pair "install.sh" "integration" "")"

# Falls back to regex classifier when category hint is empty
# Use record-reviewer.sh — autowork dir, not the show-*/timing telemetry surface
assert_eq "falls back: missing test in autowork" \
  "autowork:missing_test" \
  "$(classify_finding_pair "bundle/dot-claude/skills/autowork/scripts/record-reviewer.sh" "" "no unit tests for the new parser module")"

# Falls back to "other" when both empty
assert_eq "double empty → other:other" \
  "other:other" \
  "$(classify_finding_pair "" "" "")"

# Rejects out-of-enum agent categories, falls back to regex
# "slow" triggers the perf regex (lowercase via tr in classify_finding_category)
assert_eq "rejects bogus agent category, falls back" \
  "telemetry:performance" \
  "$(classify_finding_pair "bundle/dot-claude/skills/autowork/scripts/show-report.sh" "BOGUS_CATEGORY" "loop is slow on large datasets")"

# v1.32.0 Wave B: tighter missing_test regex
printf '\nmissing_test regex narrowing (v1.32.0 Wave B):\n'

assert_eq "incidental 'tests pass' is NOT missing_test" \
  "unknown" \
  "$(classify_finding_category "the tests pass correctly")"

assert_eq "incidental 'test runner is slow' → performance, not missing_test" \
  "performance" \
  "$(classify_finding_category "the test runner is slow on large fixtures")"

assert_eq "still: 'no tests' → missing_test" \
  "missing_test" \
  "$(classify_finding_category "no tests for the parser")"

assert_eq "still: 'coverage below threshold' → missing_test" \
  "missing_test" \
  "$(classify_finding_category "coverage is below threshold for utils.ts")"

assert_eq "still: 'lacks coverage' → missing_test" \
  "missing_test" \
  "$(classify_finding_category "the new module lacks coverage")"

# ===========================================================================
# _omc_strip_render_unsafe (v1.32.16, 4-attacker security review A3-MED-*)
# ===========================================================================

# T-strip-1: ASCII text passes through unchanged.
assert_eq "strip preserves plain ASCII" \
  "hello world" \
  "$(printf 'hello world' | _omc_strip_render_unsafe)"

# T-strip-2: tabs and newlines are preserved (legitimate whitespace).
assert_eq "strip preserves \\t and \\n" \
  "$(printf 'a\tb\nc')" \
  "$(printf 'a\tb\nc' | _omc_strip_render_unsafe)"

# T-strip-3: ESC (0x1b) — the high-leverage byte for ANSI cursor /
# color escape sequences — is removed. A hostile model that encoded
# `[2J[H` (clear screen) into a state field would otherwise
# get those bytes piped to the user's tty when /ulw-report renders.
stripped="$(printf '\x1b[31mRED\x1b[0m' | _omc_strip_render_unsafe)"
assert_eq "strip removes ESC byte (0x1b) from ANSI sequence" \
  "[31mRED[0m" \
  "${stripped}"

# T-strip-4: NUL byte stripped.
assert_eq "strip removes NUL byte" \
  "ab" \
  "$(printf 'a\x00b' | _omc_strip_render_unsafe)"

# T-strip-5: BEL (0x07) stripped — would otherwise drive an audible
# beep + xterm title escape (`\x1b]0;TITLE\x07`).
assert_eq "strip removes BEL (0x07)" \
  "ab" \
  "$(printf 'a\x07b' | _omc_strip_render_unsafe)"

# T-strip-6: DEL (0x7f) stripped — used in some legacy backspace
# attacks against tty rendering.
assert_eq "strip removes DEL (0x7f)" \
  "ab" \
  "$(printf 'a\x7fb' | _omc_strip_render_unsafe)"

# T-strip-7: UTF-8 multi-byte sequences (start byte 0x80-0xff) pass
# through unchanged. Without this guarantee, the helper would corrupt
# legitimate non-ASCII content.
utf8_in="$(printf 'café — π — 你好')"
assert_eq "strip preserves UTF-8 multi-byte content" \
  "${utf8_in}" \
  "$(printf '%s' "${utf8_in}" | _omc_strip_render_unsafe)"

# T-strip-8: full ANSI clear-screen + cursor-home sequence (the
# canonical model-injection attack from A3) is neutralized.
malicious_in="$(printf 'safe-prefix\x1b[2J\x1b[Hattacker-content')"
malicious_out="$(printf '%s' "${malicious_in}" | _omc_strip_render_unsafe)"
# Result still contains the trailing `[2J[H` literal text (the [
# is 0x5b, a printable bracket — the *escape sequence* is broken
# because ESC was stripped). The attacker no longer drives the cursor.
assert_eq "strip neutralizes ANSI clear-screen sequence" \
  "safe-prefix[2J[Hattacker-content" \
  "${malicious_out}"

# T-strip-9: CR (0x0d) is preserved (DOS line endings, in-place
# progress emit). Confirms the strip range deliberately leaves \r.
cr_in="$(printf 'line1\r\nline2')"
assert_eq "strip preserves CR (0x0d) for DOS / progress" \
  "${cr_in}" \
  "$(printf '%s' "${cr_in}" | _omc_strip_render_unsafe)"

# ===========================================================================
# OMC_CLAUDE_BIN post-load validation (v1.32.16, A1-MED-2)
# ===========================================================================

# These tests run common.sh in a subshell with a manipulated env so the
# source-time post-load_conf validation sees the test value. They
# assert that a hostile value is cleared (fall back to live lookup)
# while a legitimate value passes through.

_run_with_env() {
  # Run common.sh in a subshell with OMC_CLAUDE_BIN set, then echo
  # the post-validation value. The 2>/dev/null suppresses the
  # rejection warning that the validator prints to stderr (we
  # exercise the warning separately via 2>&1 in the warning-text
  # assertions below).
  OMC_CLAUDE_BIN="$1" bash -c "
    set +e
    source '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh' 2>/dev/null
    printf '%s' \"\${OMC_CLAUDE_BIN}\"
  "
}

# T-cb-1: /tmp/-shaped path is cleared.
assert_eq "claude_bin under /tmp/ rejected" "" \
  "$(_run_with_env "/tmp/evil-claude")"

# T-cb-2: /var/tmp/-shaped path is cleared.
assert_eq "claude_bin under /var/tmp/ rejected" "" \
  "$(_run_with_env "/var/tmp/evil-claude")"

# T-cb-3: /Users/Shared/-shaped path is cleared.
assert_eq "claude_bin under /Users/Shared/ rejected" "" \
  "$(_run_with_env "/Users/Shared/evil-claude")"

# T-cb-4: /private/tmp/-shaped path is cleared (macOS /tmp resolution).
assert_eq "claude_bin under /private/tmp/ rejected" "" \
  "$(_run_with_env "/private/tmp/evil-claude")"

# T-cb-5: /dev/shm/-shaped path is cleared (Linux tmpfs).
assert_eq "claude_bin under /dev/shm/ rejected" "" \
  "$(_run_with_env "/dev/shm/evil-claude")"

# T-cb-6: a legitimate non-blacklisted path that exists + is executable
# passes through. We use /bin/sh as the universally-available real
# binary (not /bin/bash because Linux containers may use /bin/dash).
if [[ -x /bin/sh ]]; then
  assert_eq "claude_bin = /bin/sh preserved (legit absolute exec)" \
    "/bin/sh" \
    "$(_run_with_env "/bin/sh")"
fi

# T-cb-7: non-executable path is cleared (config bug, not a security
# boundary, but the validator catches it as a quality signal).
non_exec_path="${TEST_STATE_ROOT}/not-executable"
touch "${non_exec_path}"
chmod 644 "${non_exec_path}"
assert_eq "claude_bin to non-executable file rejected" "" \
  "$(_run_with_env "${non_exec_path}")"

# T-cb-8: missing file is cleared.
assert_eq "claude_bin to missing file rejected" "" \
  "$(_run_with_env "/this/path/does/not/exist/at/all")"

# T-cb-9: rejection emits a warning to stderr the user can grep.
warning_text="$(OMC_CLAUDE_BIN="/tmp/evil" bash -c "
  set +e
  source '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh' 2>&1 >/dev/null
")"
assert_contains "rejection warning surfaces on stderr" \
  "rejecting OMC_CLAUDE_BIN" "${warning_text}"
warning_text="$(OMC_CLAUDE_BIN="/bad"$'\033'"[31m-path" bash -c "
  set +e
  source '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh' 2>&1 >/dev/null
")"
if [[ "${warning_text}" != *$'\033'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: rejected claude_bin warning emitted a literal terminal ESC\n' >&2
  fail=$((fail + 1))
fi
assert_contains "escaped claude_bin warning remains diagnosable" \
  "rejecting OMC_CLAUDE_BIN=" "${warning_text}"

# ===========================================================================
# omc_redact_secrets (v1.34.1+, security-lens Z-003)
# ===========================================================================
#
# Strips common secret patterns from a bash command string before it lands
# in last_verify_cmd / state files / repro tarballs. Patterns covered:
# token=/password=/secret=/key=/auth=/api[_-]?key=, --token/--password,
# Bearer, sk-/ghp_/xoxb-/AKIA-prefixed/glpat- provider keys.

printf '\nomc_redact_secrets:\n'

# Local helper — test-common-utilities.sh doesn't define a generic
# negative-substring assertion (assert_not_doc / assert_not_ui are
# specific). Inline a generic one for these new redaction assertions.
_assert_no_substring() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# (a) plain key=value forms are redacted, value is replaced.
out="$(printf '%s' 'pytest --auth-token=abc123def456 tests/' | omc_redact_secrets)"
assert_contains "key=value: redacts the value" "auth-token=<redacted>" "${out}"
_assert_no_substring "key=value: original token gone" "abc123def456" "${out}"

# (b) Bearer tokens get their value replaced.
out="$(printf '%s' 'curl -H "Authorization: Bearer abcdef0123456789" url' | omc_redact_secrets)"
assert_contains "Bearer redacted" "Bearer <redacted>" "${out}"
_assert_no_substring "Bearer: token gone" "abcdef0123456789" "${out}"

# (c) Provider-shaped keys are caught even when not in key=value position.
out="$(printf '%s' 'echo sk-1234567890abcdef foo' | omc_redact_secrets)"
assert_contains "sk-* prefix redacted" "<redacted-secret>" "${out}"
out="$(printf '%s' 'gh auth login --with-token ghp_1234567890ABCDEFghij' | omc_redact_secrets)"
assert_contains "ghp_ token redacted" "<redacted-secret>" "${out}"
out="$(printf '%s' 'AKIAIOSFODNN7EXAMPLE foo' | omc_redact_secrets)"
assert_contains "AKIA prefix redacted" "<redacted-secret>" "${out}"

# (d) clean commands pass through unchanged.
out="$(printf '%s' 'pytest tests/ -v --no-cov' | omc_redact_secrets)"
assert_eq "clean command passes through" "pytest tests/ -v --no-cov" "${out}"

# (e) idempotent: re-running on already-redacted input is stable.
once="$(printf '%s' 'pytest --auth-token=secret123 tests/' | omc_redact_secrets)"
twice="$(printf '%s' "${once}" | omc_redact_secrets)"
assert_eq "idempotent: redaction is stable across passes" "${once}" "${twice}"

# ===========================================================================
# omc_host — machine identity for cross-session rows (v1.48-pre)
# ===========================================================================

printf 'omc_host:\n'
_oh1="$(omc_host)"
_oh2="$(omc_host)"
if [[ -n "${_oh1}" ]]; then pass=$((pass+1)); else printf '  FAIL: omc_host returned empty\n' >&2; fail=$((fail+1)); fi
assert_eq "omc_host stable across calls (cached)" "${_oh1}" "${_oh2}"
if [[ "${_oh1}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  pass=$((pass+1))
else
  printf '  FAIL: omc_host not sanitized to [A-Za-z0-9._-]: %q\n' "${_oh1}" >&2; fail=$((fail+1))
fi

# ===========================================================================
# publication recovery ledger schema
# ===========================================================================

printf 'publication recovery ledger schema:\n'
publication_dir="${STATE_ROOT}/${SESSION_ID}"
plan_waiters="${publication_dir}/plan_summary_waiters.jsonl"
plan_receipts="${publication_dir}/plan_publication_outcomes.jsonl"
reviewer_waiters="${publication_dir}/reviewer_summary_waiters.jsonl"
reviewer_receipts="${publication_dir}/reviewer_publication_outcomes.jsonl"
rm -f "${plan_waiters}" "${plan_receipts}" \
  "${reviewer_waiters}" "${reviewer_receipts}"

dispatch_stage="${publication_dir}/.dispatch-txn.inert"
mkdir "${dispatch_stage}"
assert_exit "retained pre-ready dispatch intent requires recovery" 0 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
touch "${dispatch_stage}/.ready"
assert_exit "ready dispatch transaction requires recovery" 0 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
rm -f "${dispatch_stage}/.ready"
rmdir "${dispatch_stage}"
printf '%s\n' 'malformed-node' \
  >"${publication_dir}/.dispatch-txn.malformed"
assert_exit "malformed dispatch authority fails closed" 0 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
rm -f "${publication_dir}/.dispatch-txn.malformed"

# The exact reset quarantines journals before committing inactive state. A
# crash in that window must remain fenced, while a successfully committed or
# prior-generation quarantine is inert after reactivation.
dispatch_state_before="$(<"${publication_dir}/session_state.json")"
deactivate_stage="${publication_dir}/.deactivate-txn.staged"
mkdir -p \
  "${deactivate_stage}/journals/.dispatch-txn.interrupted"
touch "${deactivate_stage}/journals/.dispatch-txn.interrupted/.ready"
printf '%s\n' '11' >"${deactivate_stage}/.enforcement-generation"
jq '.workflow_mode="ultrawork"
    | .ulw_enforcement_active="1"
    | .ulw_enforcement_generation="11"' \
  "${publication_dir}/session_state.json" \
  >"${publication_dir}/session_state.json.tmp"
mv "${publication_dir}/session_state.json.tmp" \
  "${publication_dir}/session_state.json"
assert_exit "mid-reset staged dispatch remains fail-closed" 0 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"

# Generation markers are an exact byte-level protocol. Malformed spellings
# must never compare as an old generation and make staged authority inert.
for malformed_generation in leading-zero embedded-space missing-newline \
    extra-newline embedded-nul; do
  case "${malformed_generation}" in
    leading-zero)
      printf '011\n' >"${deactivate_stage}/.enforcement-generation"
      ;;
    embedded-space)
      printf '11 12\n' >"${deactivate_stage}/.enforcement-generation"
      ;;
    missing-newline)
      printf '11' >"${deactivate_stage}/.enforcement-generation"
      ;;
    extra-newline)
      printf '11\n\n' >"${deactivate_stage}/.enforcement-generation"
      ;;
    embedded-nul)
      printf '11\0\n' >"${deactivate_stage}/.enforcement-generation"
      ;;
  esac
  assert_exit "malformed ${malformed_generation} generation fails closed" 0 \
    omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
done
printf '%s\n' '11' >"${deactivate_stage}/.enforcement-generation"
mv "${deactivate_stage}/journals/.dispatch-txn.interrupted" \
  "${publication_dir}/dispatch-quarantine-fixture"
printf '%s\n' '{"agent_type":"quality-reviewer"}' \
  >"${deactivate_stage}/pending_agents.jsonl"
assert_exit "mid-reset staged transient authority remains fail-closed" 0 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
rm -f "${deactivate_stage}/pending_agents.jsonl"
mv "${publication_dir}/dispatch-quarantine-fixture" \
  "${deactivate_stage}/journals/.dispatch-txn.interrupted"
jq '.workflow_mode="" | .ulw_enforcement_active="0"' \
  "${publication_dir}/session_state.json" \
  >"${publication_dir}/session_state.json.tmp"
mv "${publication_dir}/session_state.json.tmp" \
  "${publication_dir}/session_state.json"
assert_exit "committed inactive reset quarantine is inert" 1 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
jq '.workflow_mode="ultrawork"
    | .ulw_enforcement_active="1"
    | .ulw_enforcement_generation="12"' \
  "${publication_dir}/session_state.json" \
  >"${publication_dir}/session_state.json.tmp"
mv "${publication_dir}/session_state.json.tmp" \
  "${publication_dir}/session_state.json"
assert_exit "prior-generation reset quarantine is inert" 1 \
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}"
rm -rf "${deactivate_stage}"
printf '%s\n' "${dispatch_state_before}" \
  >"${publication_dir}/session_state.json"

# Versioned ignored outcomes are mutation authority for two causal ledgers.
# Every journal field must validate as JSON before Bash sees a projection:
# escaped NUL suffixes must not normalize into a valid enum, fingerprint, or
# immutable lifecycle identity and retire the named rows.
cleanup_pending="${publication_dir}/pending_agents.jsonl"
cleanup_starts="${publication_dir}/agent_dispatch_starts.jsonl"
cleanup_outcomes="${publication_dir}/agent_completion_outcomes.jsonl"
cleanup_line="$(jq -nc '{
  ts:100,agent_type:"quality-reviewer",description:"cleanup schema target",
  lifecycle_dispatch_id:"dispatch-cleanup-schema-target",
  edit_revision:1,code_revision:1,doc_revision:0,bash_revision:0,
  ui_revision:0,plan_revision:0,review_revision:1,
  objective_prompt_ts:100,objective_prompt_revision:1,
  objective_cycle_id:1,ulw_enforcement_generation:"1",
  native_agent_id:"native-cleanup-schema-target"
}')"
cleanup_fingerprint="$(_omc_token_digest "${cleanup_line}")"
cleanup_valid_outcome="$(jq -nc --arg fp "${cleanup_fingerprint}" '{
  ts:101,agent_type:"quality-reviewer",status:"ignored",
  reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",objective_cycle_id:1,
  objective_prompt_ts:100,review_revision:1,
  ulw_enforcement_generation:"1",cleanup_journal_version:2,
  lifecycle_dispatch_id:"dispatch-cleanup-schema-target",
  cleanup_lifecycle_dispatch_id:"dispatch-cleanup-schema-target",
  cleanup_pending_fingerprint:$fp,cleanup_start_fingerprint:$fp
}')"
for cleanup_corruption in status reason identity fingerprint; do
  printf '%s\n' "${cleanup_line}" >"${cleanup_pending}"
  printf '%s\n' "${cleanup_line}" >"${cleanup_starts}"
  case "${cleanup_corruption}" in
    status)
      cleanup_malformed_outcome="$(jq -c \
        '.status += "\u0000"' <<<"${cleanup_valid_outcome}")"
      ;;
    reason)
      cleanup_malformed_outcome="$(jq -c \
        '.reason += "\u0000"' <<<"${cleanup_valid_outcome}")"
      ;;
    identity)
      cleanup_malformed_outcome="$(jq -c \
        '.cleanup_lifecycle_dispatch_id += "\u0000"' \
        <<<"${cleanup_valid_outcome}")"
      ;;
    fingerprint)
      cleanup_malformed_outcome="$(jq -c \
        '.cleanup_pending_fingerprint += "\u0000"' \
        <<<"${cleanup_valid_outcome}")"
      ;;
  esac
  printf '%s\n' "${cleanup_malformed_outcome}" >"${cleanup_outcomes}"
  cleanup_pending_before="$(<"${cleanup_pending}")"
  cleanup_starts_before="$(<"${cleanup_starts}")"
  cleanup_outcomes_before="$(<"${cleanup_outcomes}")"
  assert_exit "NUL-tailed cleanup ${cleanup_corruption} fails closed" 1 \
    omc_reconcile_all_ignored_completion_cleanups_unlocked
  assert_eq "NUL-tailed cleanup ${cleanup_corruption} preserves pending" \
    "${cleanup_pending_before}" "$(<"${cleanup_pending}")"
  assert_eq "NUL-tailed cleanup ${cleanup_corruption} preserves start" \
    "${cleanup_starts_before}" "$(<"${cleanup_starts}")"
  assert_eq "NUL-tailed cleanup ${cleanup_corruption} preserves outcome" \
    "${cleanup_outcomes_before}" "$(<"${cleanup_outcomes}")"
done

# The cleanup outcome may itself be valid while the exact pending/start source
# is corrupt. A raw NUL in that deletion ledger must be rejected before Bash
# read can erase it and match the immutable lifecycle fallback.
cleanup_line_prefix="${cleanup_line%%\"ts\":100*}"
cleanup_line_suffix="${cleanup_line#*\"ts\":100}"
printf '%s"ts":100\0%s\n' \
  "${cleanup_line_prefix}" "${cleanup_line_suffix}" >"${cleanup_pending}"
printf '%s\n' "${cleanup_line}" >"${cleanup_starts}"
printf '%s\n' "${cleanup_valid_outcome}" >"${cleanup_outcomes}"
cleanup_pending_before="$(cksum <"${cleanup_pending}")"
cleanup_starts_before="$(cksum <"${cleanup_starts}")"
cleanup_outcomes_before="$(cksum <"${cleanup_outcomes}")"
assert_exit "raw-NUL pending cleanup target fails closed" 1 \
  omc_reconcile_all_ignored_completion_cleanups_unlocked
assert_eq "raw-NUL pending cleanup target preserves pending bytes" \
  "${cleanup_pending_before}" "$(cksum <"${cleanup_pending}")"
assert_eq "raw-NUL pending cleanup target preserves start bytes" \
  "${cleanup_starts_before}" "$(cksum <"${cleanup_starts}")"
assert_eq "raw-NUL pending cleanup target preserves outcome bytes" \
  "${cleanup_outcomes_before}" "$(cksum <"${cleanup_outcomes}")"
rm -f "${cleanup_pending}" "${cleanup_starts}" "${cleanup_outcomes}"

schema_summary_digest="$(_omc_token_digest "summary")"
schema_review_digest="$(_omc_token_digest "review summary")"
jq -nc --arg digest "${schema_summary_digest}" '
  {schema_version:1,created_at:1,
   lifecycle_dispatch_id:"dispatch-schema-plan-1",
   agent_type:"quality-planner",native_agent_id:"native-schema-plan",
   completion_digest:$digest,message:"summary"}
' >"${plan_waiters}"
assert_exit "waiter without receipt is ordinary live rendezvous" 1 \
  omc_publication_recovery_needed "${SESSION_ID}"
assert_exit "complete waiter schema protects its lifecycle" 0 \
  omc_completion_receipt_protected_lifecycle_ids_unlocked

jq 'del(.message)' "${plan_waiters}" >"${plan_waiters}.malformed"
mv -f "${plan_waiters}.malformed" "${plan_waiters}"
assert_exit "malformed waiter-only authority fences publication" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
assert_exit "malformed waiter cannot protect receipt history" 1 \
  omc_completion_receipt_protected_lifecycle_ids_unlocked

jq -nc --arg digest "${schema_summary_digest}" '
  {schema_version:1,created_at:1,
   lifecycle_dispatch_id:"dispatch-schema-plan-duplicate",
   agent_type:"quality-planner",native_agent_id:"native-schema-plan",
   completion_digest:$digest,message:"summary"}
' >"${plan_waiters}"
cat "${plan_waiters}" >>"${plan_waiters}.duplicate"
cat "${plan_waiters}" >>"${plan_waiters}.duplicate"
mv -f "${plan_waiters}.duplicate" "${plan_waiters}"
assert_exit "duplicate waiter-only lifecycle fences publication" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
assert_exit "duplicate waiter cannot be deduped into protection" 1 \
  omc_completion_receipt_protected_lifecycle_ids_unlocked
rm -f "${plan_waiters}"

# Receipt-only corruption must be validated too; it cannot hide behind the
# absence of a waiter and later become mutable delivery authority.
printf '%s\n' '{"schema_version":1}' >"${plan_receipts}"
assert_exit "malformed receipt-only authority fences publication" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
rm -f "${plan_receipts}"

jq -nc --arg digest "${schema_summary_digest}" '
  {schema_version:1,created_at:1,
   lifecycle_dispatch_id:"dispatch-schema-plan-1",
   agent_type:"quality-planner",native_agent_id:"native-schema-plan",
   completion_digest:$digest,message:"summary"}
' >"${plan_waiters}"

# A non-matching object is not a valid receipt. It must still fence mutation as
# malformed paired authority; treating it as merely absent lets newer state
# advance around a corrupt transaction ledger.
printf '%s\n' '{"schema_version":1}' >"${plan_receipts}"
assert_exit "malformed paired planner receipt fails closed" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
rm -f "${plan_waiters}" "${plan_receipts}"

# Reviewer migration waiters/receipts legitimately have no native ID. The
# stricter schema fence must preserve that rolling-upgrade compatibility, but
# an exact pair with neither live pending authority nor a settled parent
# outcome is protected correlation history rather than unrelated recovery
# work (the reviewer transaction suite exercises that sibling-admission path).
jq -nc --arg digest "${schema_review_digest}" '
  {schema_version:1,created_at:1,
   lifecycle_dispatch_id:"dispatch-schema-review-1",
   agent_type:"quality-reviewer",native_agent_id:"",
   completion_digest:$digest,message:"review summary"}
' >"${reviewer_waiters}"
jq -nc --arg digest "${schema_review_digest}" '
  {schema_version:1,decided_at:1,
   lifecycle_dispatch_id:"dispatch-schema-review-1",
   agent_type:"quality-reviewer",reviewer_type:"standard",
   native_agent_id:"",completion_digest:$digest,
   status:"accepted",reason:"",verdict:"CLEAN",
   start_review_revision:0,result_review_revision:0}
' >"${reviewer_receipts}"
assert_exit "pre-native reviewer receipt pair stays protected without fencing" 1 \
  omc_publication_recovery_needed "${SESSION_ID}"
rm -f "${reviewer_waiters}" "${reviewer_receipts}"

pending_agents="${publication_dir}/pending_agents.jsonl"
_publication_stop_wait_oversized_check() {
  OMC_PUBLICATION_STOP_WAIT_INTERNAL=1 \
    omc_publication_recovery_needed "${SESSION_ID}"
}
_publication_oversized_owner_check() {
  OMC_PUBLICATION_RECOVERY_CLAIM_ID=oversized-owner \
    omc_publication_recovery_needed "${SESSION_ID}"
}
printf '%s\n' \
  '{"agent_type":"general-purpose","completion_claim_id":"oversized-lease","completion_claim_ts":1000000000000000,"completion_claim_effects_complete":false}' \
  >"${pending_agents}"
assert_exit "oversized completion lease remains fenced for Stop WAIT" 0 \
  _publication_stop_wait_oversized_check
rm -f "${pending_agents}"

publication_state_before="$(<"${publication_dir}/session_state.json")"
jq --arg huge '1000000000000000000000000' \
  '(.review_cycle_prompt_ts,.prompt_revision,.review_cycle_id) = $huge' \
  "${publication_dir}/session_state.json" \
  >"${publication_dir}/session_state.json.tmp"
mv "${publication_dir}/session_state.json.tmp" \
  "${publication_dir}/session_state.json"
claim_now="$(date +%s)"
jq -nc --argjson now "${claim_now}" '
  {agent_type:"general-purpose",completion_claim_id:"oversized-owner",
   completion_claim_ts:$now,completion_claim_effects_complete:false,
   objective_prompt_ts:1000000000000000000000000,
   objective_prompt_revision:1000000000000000000000000,
   objective_cycle_id:1000000000000000000000000}
' >"${pending_agents}"
assert_exit "oversized objective coordinates cannot authorize claim owner" 0 \
  _publication_oversized_owner_check
printf '%s\n' "${publication_state_before}" \
  >"${publication_dir}/session_state.json"
rm -f "${pending_agents}"

for malformed_claim_kind in nonstring empty missing-id missing-effects \
    string-effects missing-digest nonstring-digest bad-digest missing-message \
    nonstring-message empty-message oversized-message digest-mismatch; do
  case "${malformed_claim_kind}" in
    nonstring)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":123,"completion_claim_ts":1,"completion_claim_effects_complete":false}'
      ;;
    empty)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"","completion_claim_ts":1,"completion_claim_effects_complete":false}'
      ;;
    missing-id)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_ts":1,"completion_claim_effects_complete":false}'
      ;;
    missing-effects)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-missing-effects","completion_claim_ts":1}'
      ;;
    string-effects)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-string-effects","completion_claim_ts":1,"completion_claim_effects_complete":"false"}'
      ;;
    missing-digest)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-missing-digest","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_message":"message"}'
      ;;
    nonstring-digest)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-nonstring-digest","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_digest":123,"completion_claim_message":"message"}'
      ;;
    bad-digest)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-bad-digest","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_digest":"not-a-digest","completion_claim_message":"message"}'
      ;;
    missing-message)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-missing-message","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_digest":"aaaaaaaaaaaaaaaa"}'
      ;;
    nonstring-message)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-nonstring-message","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_digest":"aaaaaaaaaaaaaaaa","completion_claim_message":123}'
      ;;
    empty-message)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-empty-message","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_digest":"aaaaaaaaaaaaaaaa","completion_claim_message":""}'
      ;;
    oversized-message)
      malformed_claim_row="$(jq -nc --arg message "$(awk 'BEGIN {
          for (i=0; i<131073; i++) printf "x"
        }')" '
        {agent_type:"general-purpose",
         completion_claim_id:"claim-oversized-message",completion_claim_ts:1,
         completion_claim_effects_complete:false,
         completion_claim_digest:"aaaaaaaaaaaaaaaa",
         completion_claim_message:$message}')"
      ;;
    digest-mismatch)
      malformed_claim_row='{"agent_type":"general-purpose","completion_claim_id":"claim-digest-mismatch","completion_claim_ts":1,"completion_claim_effects_complete":false,"completion_claim_digest":"aaaaaaaaaaaaaaaa","completion_claim_message":"message"}'
      ;;
  esac
  printf '%s\n' "${malformed_claim_row}" >"${pending_agents}"
  assert_exit "${malformed_claim_kind} claim identity fences publication" 0 \
    omc_publication_recovery_needed "${SESSION_ID}"
  assert_exit "${malformed_claim_kind} claim fences Stop WAIT too" 0 \
    _publication_stop_wait_oversized_check
  assert_exit "${malformed_claim_kind} claim cannot enter mutating recovery" 1 \
    _omc_publication_claim_timestamps_valid_unlocked "${pending_agents}"
done
rm -f "${pending_agents}"

future_publication_claim="$(( $(date +%s) + 86400 ))"
future_publication_message="future claim message"
future_publication_digest="$(_omc_token_digest \
  "${future_publication_message}")"
jq -nc --argjson ts "${future_publication_claim}" \
  --arg message "${future_publication_message}" \
  --arg digest "${future_publication_digest}" '
  {agent_type:"general-purpose",completion_claim_id:"claim-future-clock",
   completion_claim_ts:$ts,completion_claim_effects_complete:false,
   completion_claim_digest:$digest,completion_claim_message:$message}
' >"${pending_agents}"
assert_exit "future-dated claim fences publication after clock rollback" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
assert_exit "future-dated claim also fences Stop WAIT" 0 \
  _publication_stop_wait_oversized_check
rm -f "${pending_agents}"

jq -nc --arg digest "${schema_summary_digest}" '
  {schema_version:1,created_at:1000000000000000,
   lifecycle_dispatch_id:"dispatch-schema-plan-oversized",
   agent_type:"quality-planner",native_agent_id:"native-schema-plan",
   completion_digest:$digest,message:"summary"}
' >"${plan_waiters}"
assert_exit "oversized waiter timestamp fences publication" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
rm -f "${plan_waiters}"

jq -nc --arg digest "${schema_summary_digest}" '
  {schema_version:1,decided_at:1000000000000000,
   lifecycle_dispatch_id:"dispatch-schema-plan-oversized",
   agent_type:"quality-planner",native_agent_id:"native-schema-plan",
   completion_digest:$digest,status:"accepted",reason:"",
   verdict:"PLAN_READY",start_plan_revision:0,result_plan_revision:0}
' >"${plan_receipts}"
assert_exit "oversized receipt timestamp fences publication" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
rm -f "${plan_receipts}"

# Publication recovery is a mutating roll-forward path, so it applies a
# stricter contract than the read-only recovery-needed predicate: every object
# that asserts a live completion claim must carry a bounded integer timestamp
# before the clock is read, a cutoff is calculated, or a row is extracted into
# Bash arithmetic.
_publication_recovery_clock_probe() {
  local clock_marker="${1:-}"
  (
    # Indirectly consumed by the recovery function under test.
    # shellcheck disable=SC2329
    now_epoch() {
      : >"${clock_marker}"
      printf '1700000000'
    }
    omc_recover_active_publication_transactions "${SESSION_ID}"
  )
}
while IFS='|' read -r claim_label claim_row; do
  [[ -n "${claim_label}" ]] || continue
  printf '%s\n' "${claim_row}" >"${pending_agents}"
  claim_clock_marker="${publication_dir}/claim-clock-${claim_label}"
  rm -f "${claim_clock_marker}"
  assert_exit "${claim_label} claim timestamp fails recovery closed" 1 \
    _publication_recovery_clock_probe "${claim_clock_marker}"
  assert_eq "${claim_label} claim is rejected before clock arithmetic" \
    "0" "$([[ -e "${claim_clock_marker}" ]] && printf 1 || printf 0)"
done <<'MALFORMED_PUBLICATION_CLAIMS'
string|{"agent_type":"general-purpose","completion_claim_id":"completion-bad-string","completion_claim_ts":"7*7","completion_claim_effects_complete":true}
fractional|{"agent_type":"general-purpose","completion_claim_id":"completion-bad-fraction","completion_claim_ts":1.5,"completion_claim_effects_complete":false}
negative|{"agent_type":"quality-planner","completion_claim_id":"completion-bad-negative","completion_claim_ts":-1,"completion_claim_effects_complete":true}
oversized|{"agent_type":"quality-reviewer","completion_claim_id":"completion-bad-oversized","completion_claim_ts":1000000000000000,"completion_claim_effects_complete":true}
MALFORMED_PUBLICATION_CLAIMS
rm -f "${pending_agents}"

# Literal NUL must be rejected while each publication artifact is still a raw
# byte stream. jq accepts some NUL placements in numeric tokens as zero, so a
# schema check after fromjson is not an authority boundary.
raw_waiter_digest="$(_omc_token_digest "raw waiter")"
printf '%s\0%s\n' \
  '{"schema_version":1,"created_at":1' \
  ',"lifecycle_dispatch_id":"dispatch-raw-waiter-1","agent_type":"quality-planner","native_agent_id":"native-raw-waiter","completion_digest":"'"${raw_waiter_digest}"'","message":"raw waiter"}' \
  >"${plan_waiters}"
assert_exit "raw-NUL waiter is not replay authority" 1 \
  omc_summary_waiter_ledger_json_unlocked plan "${plan_waiters}"
rm -f "${plan_waiters}"

# A valid receipt without a waiter is inert history. The same logical row with
# a raw NUL in its timestamp is malformed transaction authority and must fence.
printf '%s\0%s\n' \
  '{"schema_version":1,"decided_at":1' \
  ',"lifecycle_dispatch_id":"dispatch-raw-receipt-1","agent_type":"quality-planner","native_agent_id":"native-raw-receipt","completion_digest":"'"${raw_waiter_digest}"'","status":"accepted","reason":"","verdict":"PLAN_READY","start_plan_revision":0,"result_plan_revision":0}' \
  >"${plan_receipts}"
assert_exit "raw-NUL receipt-only authority keeps recovery fence set" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
LC_ALL=C tr -d '\000' <"${plan_receipts}" >"${plan_receipts}.valid"
publication_receipt_row="$(<"${plan_receipts}.valid")"
printf '%s' "${publication_receipt_row}" >"${plan_receipts}"
assert_exit "torn publication receipt keeps recovery fence set" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
rm -f "${plan_receipts}" "${plan_receipts}.valid"

# Non-authority migration noise remains tolerated, but raw NUL anywhere in the
# tolerant pending ledger is ambiguous because Bash/fromjson can erase it into
# an authority-shaped row.
printf '{"note":1\0}\n' >"${pending_agents}"
assert_exit "raw-NUL pending ledger keeps recovery fence set" 0 \
  omc_publication_recovery_needed "${SESSION_ID}"
assert_exit "raw-NUL pending ledger cannot enter mutating recovery" 1 \
  _omc_publication_claim_timestamps_valid_unlocked "${pending_agents}"
rm -f "${pending_agents}"

raw_outcomes="${publication_dir}/agent_completion_outcomes.jsonl"
printf '%s\0%s\n' \
  '{"ts":1' \
  ',"agent_type":"quality-reviewer","status":"ignored","reason":"terminal-contract-retry-exhausted","verdict":"UNREPORTED","findings_count":0,"finding_ids":"none","objective_cycle_id":1,"objective_prompt_ts":1,"review_revision":1,"ulw_enforcement_generation":"1"}' \
  >"${raw_outcomes}"
assert_exit "raw-NUL causal outcome cannot mint notification authority" 1 \
  omc_notification_receipt_claim_unlocked \
    "${raw_outcomes}" missing-key agent-posttool quality-reviewer "" "" ""
rm -f "${raw_outcomes}"

# A public path can change type after an ordinary `-f` check. Interpose the
# hard-link operation so the exact regular source inode is pinned first, then
# replace the public name with a FIFO before either read descriptor opens. The
# capture must reject promptly rather than blocking on the FIFO.
snapshot_fifo_source="${publication_dir}/snapshot-fifo-source.jsonl"
snapshot_fifo_copy="${publication_dir}/snapshot-fifo-copy.jsonl"
printf '{}\n' >"${snapshot_fifo_source}"
: >"${snapshot_fifo_copy}"
ln() {
  command ln "$@" || return 1
  rm -f "${snapshot_fifo_source}"
  mkfifo "${snapshot_fifo_source}"
}
snapshot_fifo_rc=0
_omc_capture_regular_file_snapshot \
  "${snapshot_fifo_source}" "${snapshot_fifo_copy}" 4096 \
  >/dev/null 2>&1 &
snapshot_fifo_pid=$!
snapshot_fifo_finished=0
for _snapshot_fifo_wait in $(seq 1 200); do
  if ! kill -0 "${snapshot_fifo_pid}" 2>/dev/null; then
    snapshot_fifo_finished=1
    break
  fi
  sleep 0.01
done
if [[ "${snapshot_fifo_finished}" -eq 0 ]]; then
  kill "${snapshot_fifo_pid}" 2>/dev/null || true
  wait "${snapshot_fifo_pid}" 2>/dev/null || true
  snapshot_fifo_rc=124
else
  wait "${snapshot_fifo_pid}" || snapshot_fifo_rc=$?
fi
unset -f ln
if [[ "${snapshot_fifo_finished}" -eq 1 \
    && "${snapshot_fifo_rc}" -ne 0 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: regular-to-FIFO snapshot race did not fail promptly (rc=%s)\n' \
    "${snapshot_fifo_rc}" >&2
  fail=$((fail + 1))
fi
rm -f "${snapshot_fifo_source}" "${snapshot_fifo_copy}"

raw_frontier_history="${publication_dir}/quality_frontier_history.jsonl"
printf '%s\0%s\n' \
  '{"_v":1,"alternatives_searched":["Alternative one","Alternative two"],"contract_id":"qc-abcdefgh","contract_revision":1,"criterion_ids":[],"dominates_current":false,"edit_revision":0,"evidence":["vr-abcdefgh"],"evidence_ids":["qe-abc"],"experiment":"Run another experiment","lifecycle_dispatch_id":"dispatch-abcdefgh","limits":["Known limit"],"materiality":"none","native_agent_id":"native-1","plan_revision":1,"recommended_move":"Keep current implementation","review_cycle_id":1' \
  ',"reviewed_at":1,"reviewer":"excellence-reviewer","status":"clear","title":"No material frontier","why":"Current work dominates alternatives"}' \
  >"${raw_frontier_history}"
raw_frontier_rc=0
_quality_frontier_history_parse "${raw_frontier_history}" \
  >/dev/null 2>&1 || raw_frontier_rc=$?
if [[ "${raw_frontier_rc}" -ne 0 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: raw-NUL frontier history became review authority\n' >&2
  fail=$((fail + 1))
fi
LC_ALL=C tr -d '\000' <"${raw_frontier_history}" \
  >"${raw_frontier_history}.valid"
frontier_valid_row="$(<"${raw_frontier_history}.valid")"
printf '%s' "${frontier_valid_row}" >"${raw_frontier_history}"
assert_exit "frontier history torn tail is rejected by direct parser" 1 \
  _quality_frontier_history_parse "${raw_frontier_history}"
: >"${raw_frontier_history}"
for _frontier_row in $(seq 1 65); do
  printf '%s\n' "${frontier_valid_row}" >>"${raw_frontier_history}"
done
assert_exit "frontier history direct parser owns the 64-row cap" 1 \
  _quality_frontier_history_parse "${raw_frontier_history}"
assert_contains "frontier history parser owns its byte and row envelope" \
  '_omc_strict_jsonl_file_is_bounded "${snapshot}" 2097152 64' \
  "$(declare -f _quality_frontier_history_parse)"
assert_contains "frontier history parser reattests its public source" \
  '_omc_regular_file_snapshot_is_current "${history_file}" "${snapshot}" 2097152' \
  "$(declare -f _quality_frontier_history_parse)"
rm -f "${raw_frontier_history}" "${raw_frontier_history}.valid"

# Strict append authority must not depend on a caller having validated its
# physical framing first. Exercise the two direct parser entrypoints with a
# schema-valid but torn final row.
printf '%s' \
  '{"schema_version":1,"created_at":1,"lifecycle_dispatch_id":"dispatch-torn-waiter-1","agent_type":"quality-planner","native_agent_id":"native-torn-waiter","completion_digest":"'"${raw_waiter_digest}"'","message":"raw waiter"}' \
  >"${plan_waiters}"
assert_exit "summary waiter parser rejects a missing terminal newline" 1 \
  omc_summary_waiter_ledger_json_unlocked plan "${plan_waiters}"
printf '%s' \
  '{"ts":1,"agent_type":"quality-reviewer","status":"ignored","reason":"terminal-contract-retry-exhausted","verdict":"UNREPORTED","findings_count":0,"finding_ids":"none","objective_cycle_id":1,"objective_prompt_ts":1,"review_revision":1,"ulw_enforcement_generation":"1"}' \
  >"${raw_outcomes}"
assert_exit "notification parser rejects a missing terminal newline" 1 \
  omc_notification_receipt_claim_unlocked \
    "${raw_outcomes}" missing-key agent-posttool quality-reviewer "" "" ""
assert_contains "waiter parser owns its byte and row envelope" \
  '"${snapshot}" 33554432 128' \
  "$(declare -f omc_summary_waiter_ledger_json_unlocked)"
assert_contains "notification parser owns its byte and row envelope" \
  '"${snapshot}" 67108864 16384' \
  "$(declare -f omc_notification_receipt_claim_unlocked)"
assert_contains "publication recovery owns its receipt envelope" \
  '"${receipts}" 4194304 128' \
  "$(declare -f omc_publication_recovery_needed)"
rm -f "${plan_waiters}" "${raw_outcomes}"

# The recovery clock itself crosses both Bash arithmetic and jq --argjson.
# Canonical upper-bound input remains accepted, while leading-zero, oversized,
# and expression-shaped outputs fail without evaluating attacker text.
printf '%s\n' '{}' >"${pending_agents}"
_publication_recovery_with_clock() {
  local injected_now="${1:-}"
  (
    # Indirectly consumed by the recovery function under test.
    # shellcheck disable=SC2329
    now_epoch() { printf '%s' "${injected_now}"; }
    omc_recover_active_publication_transactions "${SESSION_ID}"
  )
}
assert_exit "bounded recovery clock remains accepted" 0 \
  _publication_recovery_with_clock 999999999999999
assert_exit "leading-zero recovery clock fails closed" 1 \
  _publication_recovery_with_clock 08
assert_exit "oversized recovery clock fails closed" 1 \
  _publication_recovery_with_clock 1000000000000000
publication_clock_poison="${publication_dir}/publication-clock-poison"
rm -f "${publication_clock_poison}"
assert_exit "expression-shaped recovery clock fails closed" 1 \
  _publication_recovery_with_clock \
    "x[\$(touch ${publication_clock_poison})]"
assert_eq "recovery clock poison is never evaluated" "0" \
  "$([[ -e "${publication_clock_poison}" ]] && printf 1 || printf 0)"
rm -f "${pending_agents}"

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
