#!/usr/bin/env bash
# Tests for the v1.26.0 Wave 2 model-drift canary subsystem.
#
# Surfaces under test:
#   1. canary_extract_claim_count — prose parser (lib/canary.sh)
#   2. canary_count_verification_tools — timing.jsonl filter (lib/canary.sh)
#   3. canary_run_audit — full audit pipeline (lib/canary.sh)
#   4. canary_should_alert / canary_session_unverified_count — alert gating
#   5. canary-claim-audit.sh — Stop-hook integration (end-to-end)
#   6. is_model_drift_canary_enabled — opt-out (common.sh)
#   7. _parse_conf_file — model_drift_canary flag (common.sh)
#
# Mirrors the structure of test-bias-defense-classifier.sh and
# test-bias-defense-directives.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Sandbox STATE_ROOT and HOME before sourcing so the test never writes
# into the user's real ~/.claude/quality-pack/state. Cleanup runs in
# the trap below.
_test_state_root="$(mktemp -d -t canary-test-state-XXXXXX)"
_test_home="$(mktemp -d -t canary-test-home-XXXXXX)"
export STATE_ROOT="${_test_state_root}"
export HOME="${_test_home}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/lib/canary.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/canary.sh"

pass=0
fail=0
TEST_FINALIZER_CLAIM_ID="finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cleanup() {
  rm -rf "${_test_state_root}" "${_test_home}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

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

_setup_session() {
  local sid="$1" prompt_seq="$2" assistant_msg="$3"
  mkdir -p "${_test_state_root}/${sid}"
  jq -nc \
    --arg ps "${prompt_seq}" \
    --arg msg "${assistant_msg}" \
    '{prompt_seq: ($ps | tonumber), last_assistant_message: $msg}' \
    > "${_test_state_root}/${sid}/session_state.json"
}

_seed_finalizer_claim() {
  local sid="$1" claim_id="${2:-${TEST_FINALIZER_CLAIM_ID}}"
  local claimed_ts="${3:-$(date +%s)}"
  jq --arg claim "${claim_id}" --argjson claimed_ts "${claimed_ts}" '
    . + {review_cycle_id:"1",prompt_revision:"1",session_outcome:"completed",
      closeout_finalized_token:"1:1:completed",
      closeout_finalization_status:"claimed",
      closeout_finalization_claimed_ts:$claimed_ts,
      closeout_finalization_claim_id:$claim}
  ' "${_test_state_root}/${sid}/session_state.json" \
    >"${_test_state_root}/${sid}/session_state.json.tmp"
  mv "${_test_state_root}/${sid}/session_state.json.tmp" \
    "${_test_state_root}/${sid}/session_state.json"
}

_add_tool_call() {
  local sid="$1" prompt_seq="$2" tool="$3" tool_use_id="$4"
  printf '{"kind":"start","ts":1000,"tool":"%s","prompt_seq":%s,"tool_use_id":"%s"}\n' \
    "${tool}" "${prompt_seq}" "${tool_use_id}" \
    >> "${_test_state_root}/${sid}/timing.jsonl"
  printf '{"kind":"end","ts":1001,"tool":"%s","prompt_seq":%s,"tool_use_id":"%s"}\n' \
    "${tool}" "${prompt_seq}" "${tool_use_id}" \
    >> "${_test_state_root}/${sid}/timing.jsonl"
}

_add_tool_call_no_id() {
  local sid="$1" prompt_seq="$2" tool="$3"
  printf '{"kind":"start","ts":1000,"tool":"%s","prompt_seq":%s}\n' \
    "${tool}" "${prompt_seq}" \
    >> "${_test_state_root}/${sid}/timing.jsonl"
  printf '{"kind":"end","ts":1001,"tool":"%s","prompt_seq":%s}\n' \
    "${tool}" "${prompt_seq}" \
    >> "${_test_state_root}/${sid}/timing.jsonl"
}

_init_timing() {
  local sid="$1" prompt_seq="$2"
  mkdir -p "${_test_state_root}/${sid}"
  printf '{"kind":"prompt_start","ts":900,"prompt_seq":%s}\n' "${prompt_seq}" \
    > "${_test_state_root}/${sid}/timing.jsonl"
}

_run_audit_for() {
  local sid="$1"
  export SESSION_ID="${sid}"
  canary_run_audit "${sid}"
}

_read_canary_field() {
  local sid="$1" field="$2"
  local f="${_test_state_root}/${sid}/canary.jsonl"
  [[ ! -f "${f}" ]] && return
  jq -r --arg k "${field}" '.[$k]' "${f}" 2>/dev/null | tail -n 1
}

# ----------------------------------------------------------------------
printf 'Test 1: canary_extract_claim_count counts strong path-anchored claims\n'
prose1='I read /path/to/UserService.swift'
assert_eq "single absolute path"           "1" "$(canary_extract_claim_count "${prose1}")"
prose2='I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go.'
assert_eq "three sequential claims"        "3" "$(canary_extract_claim_count "${prose2}")"
prose3='I examined `lib/auth.ts` and confirmed the JWT validation.'
assert_eq "backtick-fenced span"           "1" "$(canary_extract_claim_count "${prose3}")"
prose4='I tested logHandler() in the alarm path'
assert_eq "function call shape"            "1" "$(canary_extract_claim_count "${prose4}")"
prose5='we have read /src/api/handlers.go thoroughly'
assert_eq 'we have read variant'           "1" "$(canary_extract_claim_count "${prose5}")"
prose6='I just ran tests/test-foo.sh and it passed'
assert_eq 'I just ran variant'             "1" "$(canary_extract_claim_count "${prose6}")"
# v1.26.0 Wave 2 excellence-reviewer F1 — multi-claim sentences MUST count
# correctly. The iOS-failure prose shape is "I X-ed A, B, and C" — without
# the continuation pattern this would score 1 instead of 3 and silently
# defeat the audit's primary signal.
assert_eq 'comma-joined 3 paths'           "3" "$(canary_extract_claim_count 'I read /path/A.swift, /path/B.ts, /path/C.go')"
assert_eq 'and-joined 3 verb-claims'       "3" "$(canary_extract_claim_count 'I checked support.html and verified privacy-policy.html and confirmed terms.html')"
assert_eq 'comma + and + period'           "3" "$(canary_extract_claim_count 'I read A.swift, B.ts, and C.go. Then I edited D.py')"
assert_eq 'iOS-mixed prose (1 anchored)'   "1" "$(canary_extract_claim_count 'I read /path/to/X.swift and verified the imports')"
assert_eq '5-file iOS sweep prose'         "5" "$(canary_extract_claim_count 'I checked support.html, privacy-policy.html, terms.html, eula.txt, and license.md')"
# Continuation pattern must NOT inflate when there's no active claim.
assert_eq 'paths after see-also (no verb)' "0" "$(canary_extract_claim_count 'see also /docs, /src/utils, /lib/auth.ts')"
assert_eq 'paths in markdown bullet list'  "0" "$(canary_extract_claim_count 'consider these: /a.swift, /b.ts, /c.go')"

# ----------------------------------------------------------------------
printf 'Test 2: canary_extract_claim_count returns 0 on weak / aspirational claims\n'
assert_eq "I might check"                  "0" "$(canary_extract_claim_count "I might check the imports later")"
assert_eq "we should verify"               "0" "$(canary_extract_claim_count "we should verify this approach")"
assert_eq "the docs say"                   "0" "$(canary_extract_claim_count "the docs say it works")"
assert_eq "no claim verbs"                 "0" "$(canary_extract_claim_count "the migration is done")"
assert_eq "empty"                          "0" "$(canary_extract_claim_count "")"
assert_eq "noun-only claim (no anchor)"    "0" "$(canary_extract_claim_count "I read the docs")"
assert_eq "verbs-without-anchor"           "0" "$(canary_extract_claim_count "I verified the imports are correct")"

# ----------------------------------------------------------------------
printf 'Test 3: canary_count_verification_tools filters to verification tools only\n'
sid="t3-$$"
_init_timing "${sid}" 3
_add_tool_call "${sid}" 3 Read r1
_add_tool_call "${sid}" 3 Read r2
_add_tool_call "${sid}" 3 Bash b1
_add_tool_call "${sid}" 3 Edit e1     # Edit must NOT count
_add_tool_call "${sid}" 3 Write w1    # Write must NOT count
_add_tool_call "${sid}" 3 Grep g1
_add_tool_call "${sid}" 3 TaskCreate tc1   # TaskCreate must NOT count
assert_eq "tools count for prompt_seq=3"   "4" "$(canary_count_verification_tools "${sid}" 3)"
_add_tool_call_no_id "${sid}" 3 Read
_add_tool_call_no_id "${sid}" 3 Grep
assert_eq "tools without tool_use_id still count" "6" "$(canary_count_verification_tools "${sid}" 3)"

# Different prompt_seq must not bleed into the count.
_add_tool_call "${sid}" 4 Read r3
assert_eq "prompt_seq=3 unaffected by ps=4" "6" "$(canary_count_verification_tools "${sid}" 3)"
assert_eq "prompt_seq=4 sees its own"       "1" "$(canary_count_verification_tools "${sid}" 4)"

printf '%s\n' \
  '{"kind":"start","tool":"Bash","prompt_seq":3,"tool_use_id":"missing-ts"}' \
  '{"kind":"start","ts":1002,"tool":"Bash","prompt_seq":"3","tool_use_id":"string-seq"}' \
  '{"kind":"start","ts":1002,"tool":"Bash","prompt_seq":3,"tool_use_id":42}' \
  '{torn' >>"${_test_state_root}/${sid}/timing.jsonl"
assert_eq "malformed/torn timing rows cannot fabricate verification calls" \
  "6" "$(canary_count_verification_tools "${sid}" 3)"

# Missing timing.jsonl must return 0, not error.
assert_eq "missing timing.jsonl"           "0" "$(canary_count_verification_tools "nonexistent-session" 1)"
assert_eq "empty prompt_seq"               "0" "$(canary_count_verification_tools "${sid}" "")"

# ----------------------------------------------------------------------
printf 'Test 4: full audit — verdict=unverified (claims >= 2, zero tools)\n'
sid="t4-$$"
_setup_session "${sid}" 5 "I read /path/A.swift. I read /path/B.ts. I read /path/C.go. I read /path/D.py."
_init_timing "${sid}" 5
_run_audit_for "${sid}"
assert_eq "T4: claim_count"      "4"           "$(_read_canary_field "${sid}" claim_count)"
assert_eq "T4: tool_count"       "0"           "$(_read_canary_field "${sid}" tool_count)"
assert_eq "T4: verdict"          "unverified"  "$(_read_canary_field "${sid}" verdict)"
# Gate event must also have landed.
if [[ -f "${_test_state_root}/${sid}/gate_events.jsonl" ]]; then
  ge_count="$(jq -c 'select(.gate=="canary" and .event=="unverified_claim")' \
    "${_test_state_root}/${sid}/gate_events.jsonl" 2>/dev/null | wc -l | tr -d ' ' || printf 0)"
else
  ge_count="0"
fi
assert_eq "T4: gate_events row landed" "1" "${ge_count}"

# ----------------------------------------------------------------------
printf 'Test 5: full audit — verdict=covered (tool_count >= claim_count)\n'
sid="t5-$$"
_setup_session "${sid}" 7 "I read /path/A.swift. I read /path/B.ts. I read /path/C.go. I read /path/D.py."
_init_timing "${sid}" 7
_add_tool_call "${sid}" 7 Read r1
_add_tool_call "${sid}" 7 Read r2
_add_tool_call "${sid}" 7 Bash b1
_add_tool_call "${sid}" 7 Grep g1
_run_audit_for "${sid}"
assert_eq "T5: claim_count"      "4"        "$(_read_canary_field "${sid}" claim_count)"
assert_eq "T5: tool_count"       "4"        "$(_read_canary_field "${sid}" tool_count)"
assert_eq "T5: verdict"          "covered"  "$(_read_canary_field "${sid}" verdict)"
if [[ -f "${_test_state_root}/${sid}/gate_events.jsonl" ]]; then
  ge_count="$(jq -c 'select(.gate=="canary" and .event=="unverified_claim")' \
    "${_test_state_root}/${sid}/gate_events.jsonl" 2>/dev/null | wc -l | tr -d ' ' || printf 0)"
else
  ge_count="0"
fi
assert_eq "T5: NO gate_events row on covered verdict" "0" "${ge_count}"

# ----------------------------------------------------------------------
printf 'Test 6: full audit — verdict=clean (claim_count < 2)\n'
sid="t6-$$"
_setup_session "${sid}" 9 "I read /path/A.swift and made some edits."
_init_timing "${sid}" 9
_run_audit_for "${sid}"
assert_eq "T6: claim_count"      "1"      "$(_read_canary_field "${sid}" claim_count)"
assert_eq "T6: verdict"          "clean"  "$(_read_canary_field "${sid}" verdict)"

# ----------------------------------------------------------------------
printf 'Test 7: full audit — verdict=low_coverage (tools < claims, but > 0)\n'
sid="t7-$$"
_setup_session "${sid}" 11 "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go. I examined /path/D.py."
_init_timing "${sid}" 11
_add_tool_call "${sid}" 11 Read r1
_run_audit_for "${sid}"
assert_eq "T7: claim_count"      "4"             "$(_read_canary_field "${sid}" claim_count)"
assert_eq "T7: tool_count"       "1"             "$(_read_canary_field "${sid}" tool_count)"
assert_eq "T7: verdict"          "low_coverage"  "$(_read_canary_field "${sid}" verdict)"
if [[ -f "${_test_state_root}/${sid}/gate_events.jsonl" ]]; then
  ge_count="$(jq -c 'select(.gate=="canary" and .event=="unverified_claim")' \
    "${_test_state_root}/${sid}/gate_events.jsonl" 2>/dev/null | wc -l | tr -d ' ' || printf 0)"
else
  ge_count="0"
fi
assert_eq "T7: NO gate_events row on low_coverage" "0" "${ge_count}"

# ----------------------------------------------------------------------
printf 'Test 8: audit skips when timing.jsonl is missing (graceful)\n'
sid="t8-$$"
_setup_session "${sid}" 13 "I read /path/A.swift. I read /path/B.ts."
# Note: deliberately NOT calling _init_timing here.
_run_audit_for "${sid}"
assert_false "T8: no canary.jsonl row"           '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# ----------------------------------------------------------------------
printf 'Test 9: audit skips when last_assistant_message is empty\n'
sid="t9-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '{"prompt_seq": 15, "last_assistant_message": ""}' > "${_test_state_root}/${sid}/session_state.json"
_init_timing "${sid}" 15
_run_audit_for "${sid}"
assert_false "T9: no canary.jsonl row when assistant msg empty" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# ----------------------------------------------------------------------
printf 'Test 10: cross-session aggregate accrues each audit\n'
xs="${HOME}/.claude/quality-pack/canary.jsonl"
[[ -f "${xs}" ]] && initial="$(wc -l < "${xs}" | tr -d ' ')" || initial=0
sid="t10-$$"
_setup_session "${sid}" 17 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 17
_run_audit_for "${sid}"
final="$(wc -l < "${xs}" 2>/dev/null | tr -d ' ' || printf 0)"
assert_eq "T10: cross-session row appended" "$((initial+1))" "${final}"
# Confirm the row carries project_key and session_id metadata.
last_row="$(tail -n 1 "${xs}")"
pk="$(printf '%s' "${last_row}" | jq -r '.project_key' 2>/dev/null)"
assert_true "T10: project_key non-empty"   '[[ -n "${pk}" ]]'
assert_eq   "T10: session_id matches"      "${sid}" "$(printf '%s' "${last_row}" | jq -r '.session_id')"

# ----------------------------------------------------------------------
printf 'Test 11: canary_session_unverified_count tracks unverified rows\n'
sid="t11-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '{"verdict":"clean"}\n' >> "${_test_state_root}/${sid}/canary.jsonl"
printf '{"verdict":"covered"}\n' >> "${_test_state_root}/${sid}/canary.jsonl"
printf '{"verdict":"unverified"}\n' >> "${_test_state_root}/${sid}/canary.jsonl"
printf '{"verdict":"unverified"}\n' >> "${_test_state_root}/${sid}/canary.jsonl"
printf '{"verdict":"low_coverage"}\n' >> "${_test_state_root}/${sid}/canary.jsonl"
assert_eq "T11: 2 unverified out of 5 rows" "2" "$(canary_session_unverified_count "${sid}")"

# ----------------------------------------------------------------------
printf 'Test 12: canary_should_alert fires once at threshold, then is silent (one-shot)\n'
sid="t12-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '{"verdict":"unverified"}\n{"verdict":"unverified"}\n' \
  > "${_test_state_root}/${sid}/canary.jsonl"
printf '{}\n' > "${_test_state_root}/${sid}/session_state.json"
export SESSION_ID="${sid}"
assert_true "T12: should_alert true at threshold (count=2)" 'canary_should_alert "${sid}"'
# Mark emitted, then re-check.
write_state "drift_warning_emitted" "1"
assert_false "T12: should_alert false after emission (one-shot)" 'canary_should_alert "${sid}"'

# Below threshold: should not alert even with no emission record.
sid="t12b-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '{"verdict":"unverified","claim_count":2}\n' > "${_test_state_root}/${sid}/canary.jsonl"
printf '{}\n' > "${_test_state_root}/${sid}/session_state.json"
export SESSION_ID="${sid}"
assert_false "T12b: should_alert false below threshold (count=1, claim_count=2)" 'canary_should_alert "${sid}"'

# ----------------------------------------------------------------------
printf 'Test 12c: loud-session alert fires on FIRST unverified verdict when claim_count >= 4 (v1.27.0 F-010)\n'
sid="t12c-$$"
mkdir -p "${_test_state_root}/${sid}"
# Single unverified event with 4 claims and 0 tools — loud session.
printf '{"verdict":"unverified","claim_count":4,"tool_count":0}\n' \
  > "${_test_state_root}/${sid}/canary.jsonl"
printf '{}\n' > "${_test_state_root}/${sid}/session_state.json"
export SESSION_ID="${sid}"
assert_true "T12c: should_alert true on loud single event (claim_count=4)" \
  'canary_should_alert "${sid}"'

# Five claims also fires; one event, no pattern.
sid="t12d-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '{"verdict":"unverified","claim_count":5,"tool_count":0}\n' \
  > "${_test_state_root}/${sid}/canary.jsonl"
printf '{}\n' > "${_test_state_root}/${sid}/session_state.json"
export SESSION_ID="${sid}"
assert_true "T12d: should_alert true on louder single event (claim_count=5)" \
  'canary_should_alert "${sid}"'

# Three claims is below loud threshold AND below pattern threshold.
sid="t12e-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '{"verdict":"unverified","claim_count":3,"tool_count":0}\n' \
  > "${_test_state_root}/${sid}/canary.jsonl"
printf '{}\n' > "${_test_state_root}/${sid}/session_state.json"
export SESSION_ID="${sid}"
assert_false "T12e: should_alert false at claim_count=3 (below loud threshold)" \
  'canary_should_alert "${sid}"'

# canary_session_max_unverified_claims helper returns the maximum.
sid="t12f-$$"
mkdir -p "${_test_state_root}/${sid}"
{
  printf '%s\n' '{"verdict":"unverified","claim_count":2,"tool_count":0}'
  printf '%s\n' '{"verdict":"clean","claim_count":1,"tool_count":0}'
  printf '%s\n' '{"verdict":"unverified","claim_count":7,"tool_count":0}'
  printf '%s\n' '{"verdict":"covered","claim_count":3,"tool_count":3}'
} > "${_test_state_root}/${sid}/canary.jsonl"
assert_eq "T12f: max returns 7 across mixed verdicts" "7" \
  "$(canary_session_max_unverified_claims "${sid}")"

# Empty canary file → max = 0.
sid="t12g-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '' > "${_test_state_root}/${sid}/canary.jsonl"
assert_eq "T12g: max returns 0 on empty canary" "0" \
  "$(canary_session_max_unverified_claims "${sid}")"

# Missing canary file → max = 0.
sid="t12h-$$"
mkdir -p "${_test_state_root}/${sid}"
assert_eq "T12h: max returns 0 when canary.jsonl absent" "0" \
  "$(canary_session_max_unverified_claims "${sid}")"

# ----------------------------------------------------------------------
printf 'Test 13: opt-out via OMC_MODEL_DRIFT_CANARY=off\n'
OMC_MODEL_DRIFT_CANARY=off
assert_false "T13: canary disabled when OMC_MODEL_DRIFT_CANARY=off" \
  'is_model_drift_canary_enabled'
unset OMC_MODEL_DRIFT_CANARY
OMC_MODEL_DRIFT_CANARY=on
assert_true "T13: canary enabled when OMC_MODEL_DRIFT_CANARY=on" \
  'is_model_drift_canary_enabled'
unset OMC_MODEL_DRIFT_CANARY
# Default is ON when unset.
assert_true "T13: canary default ON when env unset" \
  'is_model_drift_canary_enabled'

# ----------------------------------------------------------------------
printf 'Test 14: conf parser picks up model_drift_canary flag\n'
_test_conf="$(mktemp -t canary-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
model_drift_canary=off
EOF
unset OMC_MODEL_DRIFT_CANARY
_omc_env_model_drift_canary=""
_parse_conf_file "${_test_conf}"
assert_eq "T14: conf=off parsed"           "off" "${OMC_MODEL_DRIFT_CANARY}"
rm -f "${_test_conf}"

# Env var precedence — env wins over conf.
_test_conf="$(mktemp -t canary-conf-XXXXXX)"
cat > "${_test_conf}" <<EOF
model_drift_canary=off
EOF
_omc_env_model_drift_canary="on"
OMC_MODEL_DRIFT_CANARY="on"
_parse_conf_file "${_test_conf}"
assert_eq "T14: env wins over conf"        "on" "${OMC_MODEL_DRIFT_CANARY}"
rm -f "${_test_conf}"

# ----------------------------------------------------------------------
printf 'Test 15: Stop-hook script integration (canary-claim-audit.sh)\n'
sid="t15-$$"
_setup_session "${sid}" 19 "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go."
_init_timing "${sid}" 19
# Set ULW sentinel + workflow_mode so is_ultrawork_mode returns true.
mkdir -p "${STATE_ROOT}"
touch "${STATE_ROOT}/.ulw_active"
jq --arg msg "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go." \
   '. + {workflow_mode: "ultrawork", last_assistant_message: $msg}' \
   "${_test_state_root}/${sid}/session_state.json" \
   > "${_test_state_root}/${sid}/session_state.json.tmp" \
   && mv "${_test_state_root}/${sid}/session_state.json.tmp" \
         "${_test_state_root}/${sid}/session_state.json"

# Run the actual hook with a synthesized payload. Capture stdout (which
# may contain a systemMessage if the alert fires).
hook_payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
hook_out="$(STATE_ROOT="${_test_state_root}" \
  printf '%s' "${hook_payload}" \
  | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" 2>&1 || true)"
assert_true "T15: canary.jsonl row written by hook" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'
assert_eq "T15: hook produced unverified verdict" "unverified" \
  "$(_read_canary_field "${sid}" verdict)"

# Dispatcher ordering removes the live sentinel during guard acceptance before
# invoking the canary. Its explicit accepted-release disposition must preserve
# ULW attribution; otherwise every ordered canary run would silently skip.
sid="t15b-$$"
_setup_session "${sid}" 20 "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go."
_init_timing "${sid}" 20
_seed_finalizer_claim "${sid}"
rm -f "${STATE_ROOT}/.ulw_active"
hook_payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
printf '%s' "${hook_payload}" \
  | OMC_STOP_ACCEPTED=1 \
      OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" \
      >/dev/null 2>&1 || true
assert_true "T15b: accepted dispatcher handoff audits after sentinel removal" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# A decoded NUL must not alias an invalid Stop payload to a live session.
# canary-claim-audit uses the same envelope-wide json_get boundary as the
# publication hooks, so no per-session or cross-session evidence is emitted.
sid="t15c-$$"
_setup_session "${sid}" 22 "I read /path/A.swift."
_init_timing "${sid}" 22
jq '. + {workflow_mode:"ultrawork"}' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
touch "${STATE_ROOT}/.ulw_active"
hook_payload="$(jq -nc --arg sid "${sid}" \
  '{session_id:($sid + "\u0000")}')"
printf '%s' "${hook_payload}" \
  | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" \
    >/dev/null 2>&1 || true
assert_false "T15c: NUL-bearing Stop identity publishes no canary row" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# Persisted prompt identity is also authority: a decoded NUL must be rejected
# before it can alias prompt 24 and bind that prompt's timing rows.
sid="t15d-$$"
_setup_session "${sid}" 24 \
  "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go."
_init_timing "${sid}" 24
jq '. + {workflow_mode:"ultrawork", prompt_seq:("24" + "\u0000")}' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
hook_payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
printf '%s' "${hook_payload}" \
  | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" \
    >/dev/null 2>&1 || true
assert_false "T15d: NUL-bearing persisted prompt publishes no canary row" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# ----------------------------------------------------------------------
printf 'Test 16: Stop-hook short-circuits when OMC_MODEL_DRIFT_CANARY=off\n'
sid="t16-$$"
_setup_session "${sid}" 21 "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go."
_init_timing "${sid}" 21
hook_payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
OMC_MODEL_DRIFT_CANARY=off STATE_ROOT="${_test_state_root}" \
  printf '%s' "${hook_payload}" \
  | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" >/dev/null 2>&1 || true
assert_false "T16: opt-out suppresses canary.jsonl row" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# ----------------------------------------------------------------------
printf 'Test 17: Stop-hook soft alert fires after 2 unverified verdicts (one-shot)\n'
sid="t17-$$"
mkdir -p "${_test_state_root}/${sid}"
touch "${STATE_ROOT}/.ulw_active"
# Pre-stage an unverified row so the next audit pushes count to 2.
printf '{"verdict":"unverified"}\n' >> "${_test_state_root}/${sid}/canary.jsonl"
_setup_session "${sid}" 23 "I read /path/A.swift. I verified /path/B.ts. I checked /path/C.go."
jq '. + {workflow_mode: "ultrawork"}' \
  "${_test_state_root}/${sid}/session_state.json" \
  > "${_test_state_root}/${sid}/session_state.json.tmp" \
  && mv "${_test_state_root}/${sid}/session_state.json.tmp" \
        "${_test_state_root}/${sid}/session_state.json"
_init_timing "${sid}" 23

hook_payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
hook_out="$(STATE_ROOT="${_test_state_root}" \
  printf '%s' "${hook_payload}" \
  | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" 2>/dev/null || true)"
# Alert text must be present.
case "${hook_out}" in
  *"DRIFT WARNING"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T17 — alert NOT in output: %q\n' "${hook_out}" >&2; fail=$((fail + 1)) ;;
esac
# State flag must be set so the alert is one-shot.
emitted="$(jq -r '.drift_warning_emitted // ""' "${_test_state_root}/${sid}/session_state.json")"
assert_eq "T17: drift_warning_emitted state flag set" "1" "${emitted}"

# Re-fire: alert must NOT repeat (one-shot).
hook_out2="$(STATE_ROOT="${_test_state_root}" \
  printf '%s' "${hook_payload}" \
  | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" 2>/dev/null || true)"
case "${hook_out2}" in
  *"DRIFT WARNING"*) printf '  FAIL: T17 — alert RE-FIRED on second hook call (should be one-shot)\n' >&2; fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

# ----------------------------------------------------------------------
printf 'Test 18: stale-generation audit cannot publish after waiting for the state lock\n'
sid="t18-$$"
_setup_session "${sid}" 25 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 25
jq '. + {ulw_enforcement_generation:"1801"}' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
audit_ready="${_test_state_root}/t18.ready"
audit_release="${_test_state_root}/t18.release"
(
  export SESSION_ID="${sid}"
  export _OMC_ULW_CAPTURED_GENERATION="1801"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${audit_ready}"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${audit_release}"
  canary_run_audit "${sid}"
) &
audit_pid=$!
audit_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${audit_ready}" ]]; then
    audit_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "T18: audit reached deterministic pre-acquire barrier" "1" \
  "${audit_barrier_seen}"
jq '.ulw_enforcement_generation="1802"' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
: >"${audit_release}"
wait "${audit_pid}" || true
assert_false "T18: stale audit wrote no per-session row" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'
assert_eq "T18: stale audit wrote no cross-session row" "0" \
  "$(jq -sr --arg sid "${sid}" '[.[] | select(.session_id == $sid)] | length' \
      "${HOME}/.claude/quality-pack/canary.jsonl" 2>/dev/null || printf 0)"
assert_false "T18: stale audit emitted no gate event" \
  '[[ -f "${_test_state_root}/${sid}/gate_events.jsonl" ]]'

# ----------------------------------------------------------------------
printf 'Test 19: stale-generation alert cannot win the one-shot claim\n'
sid="t19-$$"
mkdir -p "${_test_state_root}/${sid}"
printf '%s\n' \
  '{"verdict":"unverified","claim_count":2}' \
  '{"verdict":"unverified","claim_count":2}' \
  >"${_test_state_root}/${sid}/canary.jsonl"
printf '%s\n' '{"ulw_enforcement_generation":"1901"}' \
  >"${_test_state_root}/${sid}/session_state.json"
claim_ready="${_test_state_root}/t19.ready"
claim_release="${_test_state_root}/t19.release"
claim_output="${_test_state_root}/t19.output"
(
  export SESSION_ID="${sid}"
  export _OMC_ULW_CAPTURED_GENERATION="1901"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${claim_ready}"
  export OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${claim_release}"
  canary_claim_alert "${sid}" >"${claim_output}"
) &
claim_pid=$!
claim_barrier_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${claim_ready}" ]]; then
    claim_barrier_seen=1
    break
  fi
  sleep 0.01
done
assert_eq "T19: claim reached deterministic pre-acquire barrier" "1" \
  "${claim_barrier_seen}"
jq '.ulw_enforcement_generation="1902"' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
: >"${claim_release}"
wait "${claim_pid}" || true
assert_eq "T19: stale claim emitted no alert count" "" \
  "$(<"${claim_output}")"
assert_eq "T19: stale claim did not set one-shot state" "" \
  "$(jq -r '.drift_warning_emitted // ""' \
      "${_test_state_root}/${sid}/session_state.json")"

# ----------------------------------------------------------------------
printf 'Test 20: accepted child propagates publish failure; standalone stays fail-open\n'
sid="t20-$$"
_setup_session "${sid}" 26 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 26
_seed_finalizer_claim "${sid}"
touch "${STATE_ROOT}/.ulw_active"
jq '. + {workflow_mode:"ultrawork"}' \
  "${_test_state_root}/${sid}/session_state.json" \
  >"${_test_state_root}/${sid}/session_state.json.tmp"
mv "${_test_state_root}/${sid}/session_state.json.tmp" \
  "${_test_state_root}/${sid}/session_state.json"
hook_payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
missing_claim_rc=0
printf '%s' "${hook_payload}" \
  | OMC_STOP_ACCEPTED=1 \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" \
      >/dev/null 2>&1 || missing_claim_rc=$?
assert_true "T20: accepted canary child requires an exact claimant ID" \
  '[[ "${missing_claim_rc}" -ne 0 ]]'
accepted_publish_rc=0
printf '%s' "${hook_payload}" \
  | OMC_STOP_ACCEPTED=1 OMC_TEST_CANARY_PUBLISH_FAIL=1 \
      OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" \
      >/dev/null 2>&1 || accepted_publish_rc=$?
assert_true "T20: accepted canary child reports locked publish failure" \
  '[[ "${accepted_publish_rc}" -ne 0 ]]'
standalone_publish_rc=0
printf '%s' "${hook_payload}" \
  | OMC_TEST_CANARY_PUBLISH_FAIL=1 \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/canary-claim-audit.sh" \
      >/dev/null 2>&1 || standalone_publish_rc=$?
assert_eq "T20: standalone canary remains fail-open" "0" \
  "${standalone_publish_rc}"
assert_false "T20: failed publications leave no per-session evidence" \
  '[[ -f "${_test_state_root}/${sid}/canary.jsonl" ]]'

# ----------------------------------------------------------------------
printf 'Test 21: global canary append and cap are one locked transaction\n'
sid_a="t21-a-$$"
sid_b="t21-b-$$"
_setup_session "${sid_a}" 27 "I read /path/A.swift. I verified /path/B.ts."
_setup_session "${sid_b}" 28 "I read /path/C.swift. I verified /path/D.ts."
_init_timing "${sid_a}" 27
_init_timing "${sid_b}" 28
_seed_finalizer_claim "${sid_a}"
_seed_finalizer_claim "${sid_b}"
global_canary="${HOME}/.claude/quality-pack/canary.jsonl"
rm -f "${global_canary}"
xs_ready="${_test_state_root}/t21.ready"
xs_release="${_test_state_root}/t21.release"
xs_b_done="${_test_state_root}/t21-b.done"
(
  export SESSION_ID="${sid_a}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  export OMC_TEST_CANARY_XS_READY_FILE="${xs_ready}"
  export OMC_TEST_CANARY_XS_RELEASE_FILE="${xs_release}"
  canary_run_audit "${sid_a}"
) &
xs_a_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${xs_ready}" ]] && break
  sleep 0.01
done
assert_true "T21: first writer reaches deterministic global publish barrier" \
  '[[ -e "${xs_ready}" ]]'
(
  export SESSION_ID="${sid_b}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  canary_run_audit "${sid_b}"
  : >"${xs_b_done}"
) &
xs_b_pid=$!
sleep 0.1
assert_false "T21: second writer waits for global canary mutex" \
  '[[ -e "${xs_b_done}" ]]'
: >"${xs_release}"
wait "${xs_a_pid}"
wait "${xs_b_pid}"
assert_eq "T21: both session rows survive global publication" "2" \
  "$(jq -s --arg a "${sid_a}" --arg b "${sid_b}" \
    '[.[] | select(.session_id == $a or .session_id == $b)] | length' \
    "${global_canary}")"

# ----------------------------------------------------------------------
printf 'Test 22: partial session publication is retryable across audit timestamps\n'
sid="t22-$$"
_setup_session "${sid}" 29 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 29
_seed_finalizer_claim "${sid}" "${TEST_FINALIZER_CLAIM_ID}" 1000
partial_rc=0
(
  now_epoch() { printf '1000'; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  export OMC_TEST_CANARY_FAIL_AFTER_SESSION_APPEND=1
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || partial_rc=$?
assert_true "T22: injected post-session failure propagates" \
  '[[ "${partial_rc}" -ne 0 ]]'
assert_eq "T22: partial attempt leaves exactly one semantic session row" "1" \
  "$(jq -s 'length' "${_test_state_root}/${sid}/canary.jsonl")"
retry_rc=0
(
  now_epoch() { printf '1001'; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  unset OMC_TEST_CANARY_FAIL_AFTER_SESSION_APPEND
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || retry_rc=$?
assert_eq "T22: retry with a fresh audit timestamp succeeds" "0" "${retry_rc}"
assert_eq "T22: retry does not duplicate per-session row" "1" \
  "$(jq -s 'length' "${_test_state_root}/${sid}/canary.jsonl")"
assert_eq "T22: retry publishes one cross-session row" "1" \
  "$(jq -s --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid and (.prompt_seq | tostring) == "29")] | length' \
    "${global_canary}")"
assert_eq "T22: retry reuses the durable session timestamp globally" "1000" \
  "$(jq -sr --arg sid "${sid}" '
      [.[] | select(.session_id == $sid
        and (.prompt_seq | tostring) == "29")][0].ts
    ' "${global_canary}")"

sid="t22b-$$"
_setup_session "${sid}" 291 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 291
_seed_finalizer_claim "${sid}" "${TEST_FINALIZER_CLAIM_ID}" 1100
global_partial_rc=0
(
  now_epoch() { printf '1100'; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  export OMC_TEST_CANARY_FAIL_AFTER_GLOBAL_APPEND=1
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || global_partial_rc=$?
assert_true "T22b: injected post-global failure propagates" \
  '[[ "${global_partial_rc}" -ne 0 ]]'
global_retry_rc=0
(
  now_epoch() { printf '1101'; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  unset OMC_TEST_CANARY_FAIL_AFTER_GLOBAL_APPEND
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || global_retry_rc=$?
assert_eq "T22b: retry after global boundary succeeds" "0" \
  "${global_retry_rc}"
assert_eq "T22b: global-boundary retry keeps one session row" "1" \
  "$(jq -s 'length' "${_test_state_root}/${sid}/canary.jsonl")"
assert_eq "T22b: global-boundary retry keeps one global row" "1" \
  "$(jq -s --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${global_canary}")"
assert_eq "T22b: global-boundary retry preserves first timestamp" "1100" \
  "$(jq -s -r --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)][0].ts' "${global_canary}")"

sid="t22c-$$"
_setup_session "${sid}" 292 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 292
_seed_finalizer_claim "${sid}" "${TEST_FINALIZER_CLAIM_ID}" 1200
gate_partial_rc=0
(
  now_epoch() { printf '1200'; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  export OMC_TEST_CANARY_FAIL_AFTER_GATE_EVENT=1
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || gate_partial_rc=$?
assert_true "T22c: injected post-gate failure propagates" \
  '[[ "${gate_partial_rc}" -ne 0 ]]'
gate_retry_rc=0
(
  now_epoch() { printf '1201'; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  unset OMC_TEST_CANARY_FAIL_AFTER_GATE_EVENT
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || gate_retry_rc=$?
assert_eq "T22c: retry after gate boundary succeeds" "0" \
  "${gate_retry_rc}"
assert_eq "T22c: gate-boundary retry keeps one session row" "1" \
  "$(jq -s 'length' "${_test_state_root}/${sid}/canary.jsonl")"
assert_eq "T22c: gate-boundary retry keeps one global row" "1" \
  "$(jq -s --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${global_canary}")"
assert_eq "T22c: gate-boundary retry keeps one gate event" "1" \
  "$(jq -s --arg ps "292" '
      [.[] | select(.gate == "canary" and .event == "unverified_claim"
        and ((.details.prompt_seq // "") | tostring) == $ps)] | length
    ' "${_test_state_root}/${sid}/gate_events.jsonl")"

# ----------------------------------------------------------------------
printf 'Test 23: malformed legacy global telemetry is skipped without blocking publication\n'
sid="t23-$$"
_setup_session "${sid}" 30 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 30
_seed_finalizer_claim "${sid}"
legacy_valid_row='{ "ts": 7, "project_key": "legacy", "session_id": "legacy-valid", "prompt_seq": "1", "claim_count": 0, "tool_count": 0, "ratio_pct": 100, "verdict": "clean" }'
printf '%s\n' \
  "${legacy_valid_row}" \
  '{malformed legacy telemetry' >"${global_canary}"
malformed_publish_rc=0
(
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${TEST_FINALIZER_CLAIM_ID}"
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || malformed_publish_rc=$?
assert_eq "T23: malformed legacy row does not block accepted publication" "0" \
  "${malformed_publish_rc}"
assert_eq "T23: valid legacy row is preserved exactly once" "1" \
  "$(jq -s '[.[] | select(.session_id == "legacy-valid")] | length' \
    "${global_canary}")"
assert_eq "T23: valid legacy row bytes are preserved" "1" \
  "$(grep -Fxc -- "${legacy_valid_row}" "${global_canary}")"
assert_eq "T23: accepted current row is published exactly once" "1" \
  "$(jq -s --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${global_canary}")"
assert_eq "T23: rewritten global ledger contains only valid objects" "true" \
  "$(jq -s 'all(.[]; type == "object")' "${global_canary}")"

# ----------------------------------------------------------------------
printf 'Test 24: expired claimant A cannot globally publish after replacement B\n'
sid="t24-$$"
claim_a="${TEST_FINALIZER_CLAIM_ID}"
_setup_session "${sid}" 31 "I read /path/A.swift. I verified /path/B.ts."
_init_timing "${sid}" 31
_seed_finalizer_claim "${sid}" "${claim_a}" 1000
xs_ready="${_test_state_root}/t24.ready"
xs_release="${_test_state_root}/t24.release"
xs_rc_file="${_test_state_root}/t24.rc"
xs_clock_file="${_test_state_root}/t24.clock"
printf '1000\n' >"${xs_clock_file}"
(
  xs_a_rc=0
  now_epoch() { tr -d '[:space:]' <"${xs_clock_file}"; }
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${claim_a}"
  export OMC_TEST_CANARY_XS_READY_FILE="${xs_ready}"
  export OMC_TEST_CANARY_XS_RELEASE_FILE="${xs_release}"
  canary_run_audit "${sid}" >/dev/null 2>&1 || xs_a_rc=$?
  printf '%s\n' "${xs_a_rc}" >"${xs_rc_file}"
) &
xs_a_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${xs_ready}" ]] && break
  sleep 0.01
done
assert_true "T24: claimant A reached global publication boundary" \
  '[[ -e "${xs_ready}" ]]'
printf '1121\n' >"${xs_clock_file}"
: >"${xs_release}"
wait "${xs_a_pid}" || true
assert_true "T24: expired claimant A reports publication failure" \
  '[[ "$(<"${xs_rc_file}")" -ne 0 ]]'
assert_eq "T24: claimant A leaves one reusable session row" "1" \
  "$(jq -s 'length' "${_test_state_root}/${sid}/canary.jsonl")"
assert_eq "T24: claimant A writes no global row after replacement" "0" \
  "$(jq -s --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${global_canary}")"
export SESSION_ID="${sid}"
claim_b="$(closeout_claim_finalization)"
assert_true "T24: expired claim is replaced by a fresh exact claimant" \
  '[[ "${claim_b}" =~ ^finalizer-[a-f0-9]{48}$ \
      && "${claim_b}" != "${claim_a}" ]]'
replacement_rc=0
(
  export SESSION_ID="${sid}"
  export OMC_STOP_ACCEPTED=1
  export OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${claim_b}"
  unset OMC_TEST_CANARY_XS_READY_FILE OMC_TEST_CANARY_XS_RELEASE_FILE
  canary_run_audit "${sid}"
) >/dev/null 2>&1 || replacement_rc=$?
assert_eq "T24: replacement claimant B publishes successfully" "0" \
  "${replacement_rc}"
assert_eq "T24: claimant B owns one global row" "1" \
  "$(jq -s --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)] | length' "${global_canary}")"
assert_eq "T24: claimant B reuses claimant A durable timestamp" \
  "$(jq -r '.ts' "${_test_state_root}/${sid}/canary.jsonl")" \
  "$(jq -s -r --arg sid "${sid}" \
    '[.[] | select(.session_id == $sid)][0].ts' "${global_canary}")"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
