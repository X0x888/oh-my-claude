#!/usr/bin/env bash
# test-omc-goal.sh — focused regression for bundle/dot-claude/bin/omc.
#
# Mock-mode only (OMC_CLAUDE_BIN stub): exercises the whole goal loop —
# framing → work passes → ground-truth verification → judgment critic →
# final review → run record — with zero network and zero spend.
#
# The four fairlead-defect fixes are each pinned:
#   #1 cost accounting: T3 asserts the run total equals the SUM of every
#      call's cost (framing + work + critic + review), not just work passes.
#   #2 cap validation: T1/T2 assert malformed --max-cost/--max-iterations
#      die loudly instead of silently coercing.
#   #3 read-only phases: T3 asserts framing/critic/review calls carry
#      --permission-mode plan while the work pass carries acceptEdits.
#   #4 headless critic: T3's judgment criterion is settled by a dedicated
#      critic call, visible in the args log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMC_BIN="${REPO_ROOT}/bundle/dot-claude/bin/omc"

pass=0
fail=0

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
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    expected NOT to contain: %q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_true() {
  local label="$1" rc="$2"
  if [[ "${rc}" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# Stub claude: numbered responses + optional numbered behavior scripts,
# invocation args logged for permission-mode / --resume assertions.
cat > "${WORK}/mock-claude" <<'MOCKEOF'
#!/usr/bin/env bash
n=0
[[ -f "${MOCK_DIR:?}/counter" ]] && n="$(cat "${MOCK_DIR}/counter")"
n=$((n + 1))
printf '%s' "${n}" > "${MOCK_DIR}/counter"
# Newline-fold the argv: prompts are multiline, and per-call grep
# assertions need every flag on the same "CALL N:" line.
printf 'CALL %s: %s\n' "${n}" "$(printf '%s ' "$@" | tr '\n' ' ')" >> "${MOCK_DIR}/args.log"
[[ -f "${MOCK_DIR}/behave.${n}.sh" ]] && bash "${MOCK_DIR}/behave.${n}.sh"
if [[ -f "${MOCK_DIR}/response.${n}.json" ]]; then
  cat "${MOCK_DIR}/response.${n}.json"
else
  printf '{"type":"result","is_error":false,"total_cost_usd":0.5,"num_turns":2,"duration_ms":900,"session_id":"mock-sid-%s","result":"ok"}\n' "${n}"
fi
MOCKEOF
chmod +x "${WORK}/mock-claude"
export OMC_CLAUDE_BIN="${WORK}/mock-claude"
export OMC_GOAL_BACKOFF_BASE=0

new_repo() {
  local d="$1"
  mkdir -p "${d}"
  ( cd "${d}" && git init -q \
    && printf 'seed\n' > seed.txt \
    && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm seed )
}

new_mock() {
  export MOCK_DIR="$1"
  mkdir -p "${MOCK_DIR}"
  : > "${MOCK_DIR}/args.log"
  rm -f "${MOCK_DIR}/counter"
}

# result-wrapping helper: embed a JSON payload as the .result STRING of a
# CLI result envelope, with an explicit cost and session id.
mk_response() {
  local out="$1" cost="$2" sid="$3" payload="$4"
  jq -n --arg r "${payload}" --argjson c "${cost}" --arg s "${sid}" \
    '{type:"result", is_error:false, total_cost_usd:$c, num_turns:3, duration_ms:1200, session_id:$s, result:$r}' \
    > "${out}"
}

# ----------------------------------------------------------------------
printf 'T1: malformed --max-cost dies loudly (defect #2)\n'
rc=0; out_t1="$(cd "${WORK}" && bash "${OMC_BIN}" goal "x" --max-cost abc 2>&1)" || rc=$?
assert_eq "T1: exit 2" "2" "${rc}"
assert_contains "T1: names the bad cap" "--max-cost must be numeric" "${out_t1}"

# ----------------------------------------------------------------------
printf 'T2: malformed --max-iterations dies loudly (defect #2)\n'
rc=0; out_t2="$(cd "${WORK}" && bash "${OMC_BIN}" goal "x" --max-iterations 3.5 2>&1)" || rc=$?
assert_eq "T2: exit 2" "2" "${rc}"
assert_contains "T2: names the bad cap" "--max-iterations must be an integer" "${out_t2}"

# ----------------------------------------------------------------------
printf 'T3: happy path — full loop, cost accounting, permission modes\n'
new_repo "${WORK}/repo3"
new_mock "${WORK}/mock3"
export OMC_GOAL_RUNS_DIR="${WORK}/runs"

mk_response "${MOCK_DIR}/response.1.json" 1.5 "sid-frame" \
  '{"criteria":[{"id":"c1","kind":"mechanical","text":"marker file exists","cmd":"test -f done.txt"},{"id":"c2","kind":"judgment","text":"change is coherent"}]}'
cat > "${MOCK_DIR}/behave.2.sh" <<'BEOF'
#!/usr/bin/env bash
printf 'done\n' > done.txt
BEOF
mk_response "${MOCK_DIR}/response.2.json" 2.0 "sid-work" 'worked on it'
mk_response "${MOCK_DIR}/response.3.json" 0.25 "sid-critic" \
  '{"verdicts":[{"id":"c2","met":true,"reason":"coherent and complete"}]}'
mk_response "${MOCK_DIR}/response.4.json" 0.25 "sid-review" '{"findings":[]}'

rc=0
out_t3="$(cd "${WORK}/repo3" && bash "${OMC_BIN}" goal "create the marker" 2>&1)" || rc=$?
assert_eq "T3: exit 0 on done" "0" "${rc}"
assert_contains "T3: goal achieved close" "Goal achieved" "${out_t3}"
assert_contains "T3: mechanical criterion checked ✅" "✅ c1" "${out_t3}"
assert_contains "T3: judgment criterion checked ✅" "✅ c2" "${out_t3}"

run_json="$(find "${OMC_GOAL_RUNS_DIR}" -name 'run.json' | head -1)"
assert_eq "T3: outcome recorded done" "done" "$(jq -r '.outcome' "${run_json}")"
# Numeric comparison, not string-equal on jq's rendering: jq 1.7
# (ubuntu-latest) preserves the "4.0000" literal that awk's %.4f
# produced, while jq 1.6 (macOS) prints "4" — string-equal flaked
# ubuntu-only on the v1.48.0 tag run.
assert_eq "T3: total cost sums ALL four calls (defect #1)" "true" \
  "$(jq -r '.total_cost_usd == 4' "${run_json}")"
assert_eq "T3: one work pass recorded" "1" "$(jq -r '.passes | length' "${run_json}")"
assert_eq "T3: pass progressed" "true" "$(jq -r '.passes[0].progressed' "${run_json}")"

args_t3="$(cat "${MOCK_DIR}/args.log")"
assert_contains "T3: framing in plan mode (defect #3)" \
  "CALL 1: -p You are framing" "${args_t3}"
assert_true "T3: framing call carries plan mode" \
  "$(grep -c 'CALL 1: .*--permission-mode plan' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"
assert_true "T3: work pass carries acceptEdits" \
  "$(grep -c 'CALL 2: .*--permission-mode acceptEdits' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"
assert_true "T3: judgment critic in plan mode (defect #4)" \
  "$(grep -c 'CALL 3: .*--permission-mode plan' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"
assert_true "T3: final review in plan mode" \
  "$(grep -c 'CALL 4: .*--permission-mode plan' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"
assert_true "T3: first work pass is a fresh session (no --resume)" \
  "$(grep 'CALL 2: ' "${MOCK_DIR}/args.log" | grep -c -- '--resume' | awk '{print ($1==0)?0:1}')"

# ----------------------------------------------------------------------
printf 'T4: cost cap trips mid-run\n'
new_repo "${WORK}/repo4"
new_mock "${WORK}/mock4"
mk_response "${MOCK_DIR}/response.1.json" 6.0 "sid-frame" \
  '{"criteria":[{"id":"c1","kind":"mechanical","text":"never satisfied","cmd":"test -f nope.txt"}]}'
mk_response "${MOCK_DIR}/response.2.json" 6.0 "sid-work" 'expensive pass'

rc=0
out_t4="$(cd "${WORK}/repo4" && bash "${OMC_BIN}" goal "expensive goal" --max-cost 10 2>&1)" || rc=$?
assert_eq "T4: exit 1 on capped run" "1" "${rc}"
assert_contains "T4: cap named in close" "cost cap" "${out_t4}"
run_json_t4="$(find "${OMC_GOAL_RUNS_DIR}" -name 'run.json' -newer "${run_json}" | head -1)"
assert_eq "T4: outcome capped-cost" "capped-cost" "$(jq -r '.outcome' "${run_json_t4}")"
assert_eq "T4: only two calls happened" "2" "$(cat "${MOCK_DIR}/counter")"

# ----------------------------------------------------------------------
printf 'T5a: continuation pass resumes the same session\n'
new_repo "${WORK}/repo5a"
new_mock "${WORK}/mock5a"
mk_response "${MOCK_DIR}/response.1.json" 0.5 "sid-frame" \
  '{"criteria":[{"id":"c1","kind":"mechanical","text":"marker exists","cmd":"test -f done.txt"}]}'
cat > "${MOCK_DIR}/behave.2.sh" <<'BEOF'
#!/usr/bin/env bash
printf 'unrelated\n' > misc.txt
BEOF
mk_response "${MOCK_DIR}/response.2.json" 0.5 "sid-work-1" 'did something else'
cat > "${MOCK_DIR}/behave.3.sh" <<'BEOF'
#!/usr/bin/env bash
printf 'done\n' > done.txt
BEOF
mk_response "${MOCK_DIR}/response.3.json" 0.5 "sid-work-1" 'finished it'
mk_response "${MOCK_DIR}/response.4.json" 0.5 "sid-review" '{"findings":[]}'

rc=0
out_t5a="$(cd "${WORK}/repo5a" && bash "${OMC_BIN}" goal "finish the marker" 2>&1)" || rc=$?
assert_eq "T5a: exit 0" "0" "${rc}"
assert_true "T5a: second pass resumes prior session" \
  "$(grep -c 'CALL 3: .*--resume sid-work-1' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"
assert_true "T5a: first pass has no --resume" \
  "$(grep 'CALL 2: ' "${MOCK_DIR}/args.log" | grep -cv -- '--resume' | awk '{print ($1==1)?0:1}')"

# ----------------------------------------------------------------------
printf 'T5b: stuck-wall — no progress, one fresh re-plan, honest stop\n'
new_repo "${WORK}/repo5b"
new_mock "${WORK}/mock5b"
mk_response "${MOCK_DIR}/response.1.json" 0.5 "sid-frame" \
  '{"criteria":[{"id":"c1","kind":"mechanical","text":"never appears","cmd":"test -f never.txt"}]}'
mk_response "${MOCK_DIR}/response.2.json" 0.5 "sid-w1" 'no changes made'
mk_response "${MOCK_DIR}/response.3.json" 0.5 "sid-w2" 'still nothing'

rc=0
out_t5b="$(cd "${WORK}/repo5b" && bash "${OMC_BIN}" goal "impossible ask" 2>&1)" || rc=$?
assert_eq "T5b: exit 1 on stuck" "1" "${rc}"
assert_contains "T5b: honest stuck close" "no progress after a fresh re-plan" "${out_t5b}"
assert_contains "T5b: unmet criterion shown ❌" "❌ c1" "${out_t5b}"
assert_true "T5b: re-planned pass is a fresh session (no --resume)" \
  "$(grep 'CALL 3: ' "${MOCK_DIR}/args.log" | grep -cv -- '--resume' | awk '{print ($1==1)?0:1}')"
run_json_t5b="$(find "${OMC_GOAL_RUNS_DIR}" -name 'run.json' -newer "${run_json_t4}" | while IFS= read -r f; do jq -r 'select(.outcome == "stuck") | input_filename' "$f" 2>/dev/null; done | head -1)"
if [[ -n "${run_json_t5b}" ]]; then
  assert_eq "T5b: two passes recorded" "2" "$(jq -r '.passes | length' "${run_json_t5b}")"
  assert_eq "T5b: second pass did not progress" "false" "$(jq -r '.passes[1].progressed' "${run_json_t5b}")"
else
  assert_true "T5b: stuck run record found" 1
fi

# ----------------------------------------------------------------------
printf 'T6: runs list + inspect\n'
out_t6="$(bash "${OMC_BIN}" runs 2>&1)"
assert_contains "T6: list header" "OUTCOME" "${out_t6}"
assert_contains "T6: done run listed" "done" "${out_t6}"
assert_contains "T6: stuck run listed" "stuck" "${out_t6}"
out_t6b="$(bash "${OMC_BIN}" runs latest 2>&1)"
assert_contains "T6: inspect shows criteria section" "criteria:" "${out_t6b}"
assert_contains "T6: inspect shows passes section" "passes:" "${out_t6b}"

# ----------------------------------------------------------------------
printf 'T7: --full-auto switches work-pass permission mode only\n'
new_repo "${WORK}/repo7"
new_mock "${WORK}/mock7"
mk_response "${MOCK_DIR}/response.1.json" 0.5 "sid-frame" \
  '{"criteria":[{"id":"c1","kind":"mechanical","text":"marker exists","cmd":"test -f done.txt"}]}'
cat > "${MOCK_DIR}/behave.2.sh" <<'BEOF'
#!/usr/bin/env bash
printf 'done\n' > done.txt
BEOF
mk_response "${MOCK_DIR}/response.2.json" 0.5 "sid-work" 'ok'
mk_response "${MOCK_DIR}/response.3.json" 0.5 "sid-review" '{"findings":[]}'
rc=0
( cd "${WORK}/repo7" && bash "${OMC_BIN}" goal "marker" --full-auto >/dev/null 2>&1 ) || rc=$?
assert_eq "T7: exit 0" "0" "${rc}"
assert_true "T7: work pass uses bypassPermissions" \
  "$(grep -c 'CALL 2: .*--permission-mode bypassPermissions' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"
assert_true "T7: framing stays in plan mode" \
  "$(grep -c 'CALL 1: .*--permission-mode plan' "${MOCK_DIR}/args.log" | awk '{print ($1==1)?0:1}')"

# ----------------------------------------------------------------------
printf 'T8: refuses to run outside a git repo without --force\n'
mkdir -p "${WORK}/nogit"
rc=0; out_t8="$(cd "${WORK}/nogit" && bash "${OMC_BIN}" goal "anything" 2>&1)" || rc=$?
assert_eq "T8: exit 2" "2" "${rc}"
assert_contains "T8: names the git requirement" "not a git repository" "${out_t8}"

# ----------------------------------------------------------------------
printf 'T9: unparseable framing dies cleanly after two attempts\n'
new_mock "${WORK}/mock9"
printf '{"type":"result","is_error":false,"total_cost_usd":0.5,"session_id":"s","result":"no json here at all"}\n' > "${MOCK_DIR}/response.1.json"
printf '{"type":"result","is_error":false,"total_cost_usd":0.5,"session_id":"s","result":"still prose"}\n' > "${MOCK_DIR}/response.2.json"
rc=0; out_t9="$(cd "${WORK}/nogit" && bash "${OMC_BIN}" goal "anything" --force 2>&1)" || rc=$?
assert_eq "T9: exit 2" "2" "${rc}"
assert_contains "T9: framing failure named" "could not derive acceptance criteria" "${out_t9}"
assert_eq "T9: both framing attempts were made" "2" "$(cat "${MOCK_DIR}/counter")"

# ----------------------------------------------------------------------
printf '\n=== omc-goal tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
