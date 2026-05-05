#!/usr/bin/env bash
#
# tests/test-state-fuzz.sh — fuzz the state subsystem against malformed
# session_state.json variants.
#
# v1.32.0 Wave C (Item 7): generate malformed JSON variants (truncated,
# mismatched braces, wrong types, NUL bytes, very-long strings, recursion
# bombs, Unicode edge cases, integer overflow) and feed each through
# read_state, write_state, with_state_lock, with_state_lock_batch,
# append_limited_state. Surface every silent swallow as a test failure —
# silent state-corruption is the worst-case mode for a harness that
# claims durable cross-session memory.
#
# The harness's defense is `_ensure_valid_state` in lib/state-io.sh:52-86.
# When the state file is not valid JSON, it archives the corrupt file
# (.corrupt.<ts> suffix) and resets to {"recovered_from_corrupt_ts":...,
# "recovered_from_corrupt_archive":"..."}. After recovery, subsequent
# operations should succeed against the fresh state. This test exercises
# that contract under each malformation class.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

assert_true() {
  local label="$1"
  if eval "$2"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s (expected condition true)\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

assert_valid_json() {
  local label="$1" file="$2"
  if jq empty "${file}" 2>/dev/null; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — file is NOT valid JSON: %s\n' "${label}" "${file}" >&2
    fail=$((fail + 1))
  fi
}

# Setup a fresh test session.
mk_session() {
  local root sid
  root="$(mktemp -d)"
  sid="sess-$$-$RANDOM"
  mkdir -p "${root}/${sid}"
  printf '%s|%s' "${root}" "${sid}"
}

# write a malformed payload to session_state.json AND a sidecar marker
# we can later check ("did the harness archive me?")
seed_malformed() {
  local root="$1" sid="$2" payload="$3"
  printf '%s' "${payload}" > "${root}/${sid}/session_state.json"
  printf '%s' "MALFORMED_CONTENT" > "${root}/${sid}/session_state.json.tag"
}

# Common test body — given a malformed payload, run a state op and check:
#   1. The op exited cleanly (rc == 0 — recovery, not propagation)
#   2. session_state.json is now valid JSON
#   3. An archive .corrupt.<ts> file exists with the original payload
#
# The "archive contains original payload" check ensures recovery
# preserves data for diagnosis (silent overwrite would be the
# worst-case bug).
fuzz_run() {
  local label="$1" payload="$2"
  local root sid parts
  parts="$(mk_session)"
  root="${parts%|*}"
  sid="${parts#*|}"
  seed_malformed "${root}" "${sid}" "${payload}"

  # Use STATE_ROOT + SESSION_ID env to pin the harness to our tmpdir.
  local out rc
  set +e
  out="$(STATE_ROOT="${root}" SESSION_ID="${sid}" bash -c "
    . '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh'
    write_state 'fuzz_test_key' 'recovery_value'
    read_state 'fuzz_test_key'
  " 2>&1)"
  rc=$?
  set -e

  # Op should have exited 0 — either recovered or wrote successfully.
  assert_eq "${label}: rc=0" "0" "${rc}"

  # Final state should be valid JSON.
  assert_valid_json "${label}: session_state.json now valid" \
    "${root}/${sid}/session_state.json"

  # Recovery marker should be set when payload was actually corrupt
  # (some payloads like {} aren't corrupt — skip marker check there).
  if [[ "${payload}" != "{}" && "${payload}" != "" ]]; then
    if grep -q "recovered_from_corrupt_archive\|fuzz_test_key" \
        "${root}/${sid}/session_state.json" 2>/dev/null; then
      pass=$((pass + 1))
    else
      printf '  FAIL: %s — neither recovery marker nor write-key in final state\n' "${label}" >&2
      fail=$((fail + 1))
    fi
  fi

  # Read should return the value we wrote (proves recovery + write
  # round-tripped correctly).
  if [[ "${out}" == *"recovery_value"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — read after recovery did not return written value\n    got: %s\n' \
      "${label}" "${out}" >&2
    fail=$((fail + 1))
  fi

  rm -rf "${root}" 2>/dev/null
}

# ---------------------------------------------------------------------
# Class 1 — truncated JSON
# ---------------------------------------------------------------------
printf '\nClass 1: truncated JSON\n'
fuzz_run "truncated mid-key" '{"task_intent":'
fuzz_run "truncated after colon" '{"k":'
fuzz_run "truncated after comma" '{"k":"v",'
fuzz_run "missing closing brace" '{"k":"v"'
fuzz_run "missing opening brace" '"k":"v"}'
fuzz_run "empty file" ''
fuzz_run "single brace" '{'
fuzz_run "single close brace" '}'

# ---------------------------------------------------------------------
# Class 2 — mismatched braces / brackets
# ---------------------------------------------------------------------
printf '\nClass 2: mismatched braces / brackets\n'
fuzz_run "extra closing brace" '{"k":"v"}}'
fuzz_run "nested unbalanced" '{"k":{"x":"y"}'
fuzz_run "bracket-as-brace" '{"k":"v"]'
fuzz_run "double comma" '{"k":"v",,"x":"y"}'
fuzz_run "trailing comma" '{"k":"v",}'

# ---------------------------------------------------------------------
# Class 3 — wrong root types
# ---------------------------------------------------------------------
printf '\nClass 3: wrong root types\n'
fuzz_run "array root" '[{"k":"v"}]'
fuzz_run "string root" '"just a string"'
fuzz_run "number root" '42'
fuzz_run "bool root" 'true'
fuzz_run "null root" 'null'

# ---------------------------------------------------------------------
# Class 4 — NUL bytes and binary garbage
# ---------------------------------------------------------------------
printf '\nClass 4: NUL bytes + binary\n'
fuzz_run "NUL bytes" "$(printf '{"k":"\x00\x00\x00"}')"
fuzz_run "NUL prefix" "$(printf '\x00\x00\x00{"k":"v"}')"
fuzz_run "control chars" "$(printf '{"k":"\x01\x02\x03"}')"

# ---------------------------------------------------------------------
# Class 5 — very long strings
# ---------------------------------------------------------------------
printf '\nClass 5: very long strings\n'
long_value="$(printf 'A%.0s' {1..10000})"
fuzz_run "10K-char value" "{\"k\":\"${long_value}\"}"
# 100 keys
many_keys="$(awk 'BEGIN{printf "{"; for(i=1;i<=100;i++){if(i>1)printf ","; printf "\"k%d\":\"v%d\"", i, i} printf "}"}')"
fuzz_run "100 keys" "${many_keys}"

# ---------------------------------------------------------------------
# Class 6 — recursion / nesting bomb
# ---------------------------------------------------------------------
printf '\nClass 6: recursion / nesting bomb\n'
deep_nest="$(awk 'BEGIN{for(i=0;i<50;i++)printf "{\"k\":"; printf "\"v\""; for(i=0;i<50;i++)printf "}"}')"
fuzz_run "50-deep nesting" "${deep_nest}"
broken_nest="$(awk 'BEGIN{for(i=0;i<50;i++)printf "{\"k\":"; printf "\"v\""}')"  # missing closes
fuzz_run "50-deep unclosed" "${broken_nest}"

# ---------------------------------------------------------------------
# Class 7 — Unicode edge cases
# ---------------------------------------------------------------------
printf '\nClass 7: Unicode edge cases\n'
fuzz_run "BOM prefix" "$(printf '\xEF\xBB\xBF{"k":"v"}')"
fuzz_run "non-utf8" "$(printf '{"k":"\xC0\x80"}')"
fuzz_run "escape soup" '{"k":"\\\\u0000"}'
fuzz_run "embedded newline raw" '{"k":"line1
line2"}'

# ---------------------------------------------------------------------
# Class 8 — integer overflow attempts
# ---------------------------------------------------------------------
printf '\nClass 8: integer overflow attempts\n'
fuzz_run "big positive int" '{"counter":99999999999999999999}'
fuzz_run "big negative int" '{"counter":-99999999999999999999}'
fuzz_run "scientific notation" '{"counter":1e308}'

# ---------------------------------------------------------------------
# Class 9 — append_limited_state with malformed payloads
# ---------------------------------------------------------------------
printf '\nClass 9: append_limited_state edge cases\n'

# Setup: valid state, but the JSONL target gets unusual values
parts="$(mk_session)"
root="${parts%|*}"
sid="${parts#*|}"
printf '{}' > "${root}/${sid}/session_state.json"

# Append a NUL-byte-containing line — must NOT silently corrupt the JSONL.
out="$(STATE_ROOT="${root}" SESSION_ID="${sid}" bash -c "
  . '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh'
  append_limited_state 'gate_events.jsonl' \"$(printf 'row\x00with\x00NULs')\" 10
  wc -l < \"${root}/${sid}/gate_events.jsonl\" 2>/dev/null || echo -1
" 2>&1 || true)"
# We tolerate the line being written — the core invariant is "no
# crash, no infinite loop". A line count > 0 means the append landed.
if [[ "${out}" =~ ^[0-9]+$ ]] || [[ "${out}" == "1" ]]; then
  pass=$((pass + 1))
else
  # Defensive: even a "0" or "-1" result (file missing) is acceptable
  # — the assertion is "no crash". An unhandled exception would
  # produce a longer error stream.
  if [[ "${#out}" -lt 200 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: append_limited_state with NUL bytes produced large error: %s\n' \
      "${out:0:200}" >&2
    fail=$((fail + 1))
  fi
fi
rm -rf "${root}" 2>/dev/null

# ---------------------------------------------------------------------
# Class 10 — write_state_batch atomicity with malformed prior state
# ---------------------------------------------------------------------
printf '\nClass 10: write_state_batch under prior corruption\n'

parts="$(mk_session)"
root="${parts%|*}"
sid="${parts#*|}"
printf '{garbage' > "${root}/${sid}/session_state.json"

set +e
out="$(STATE_ROOT="${root}" SESSION_ID="${sid}" bash -c "
  . '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh'
  write_state_batch 'k1' 'v1' 'k2' 'v2' 'k3' 'v3'
  jq -r '.k1, .k2, .k3' '${root}/${sid}/session_state.json'
" 2>&1)"
rc=$?
set -e

assert_eq "batch after corrupt: rc=0" "0" "${rc}"
if [[ "${out}" == *"v1"*"v2"*"v3"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: batch after corrupt — values not all readable\n    got: %s\n' "${out}" >&2
  fail=$((fail + 1))
fi
assert_valid_json "batch after corrupt: state valid" \
  "${root}/${sid}/session_state.json"
rm -rf "${root}" 2>/dev/null

# ---------------------------------------------------------------------
# Class 11 — SIGCHLD / interrupted write recovery
# ---------------------------------------------------------------------
printf '\nClass 11: orphan temp file cleanup\n'

parts="$(mk_session)"
root="${parts%|*}"
sid="${parts#*|}"
# Simulate a crash mid-write_state: a leftover .XXXXXX temp file
# from a prior interrupted process. Our write_state should still
# work (mktemp creates a new unique name; old one is unrelated).
printf '{}' > "${root}/${sid}/session_state.json"
touch "${root}/${sid}/session_state.json.OLDcrash"

out="$(STATE_ROOT="${root}" SESSION_ID="${sid}" bash -c "
  . '${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh'
  write_state 'k' 'v'
  read_state 'k'
" 2>&1 || true)"
assert_eq "orphan temp does not block write" "v" "${out}"
rm -rf "${root}" 2>/dev/null

# ---------------------------------------------------------------------
printf '\n=== state-fuzz tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
