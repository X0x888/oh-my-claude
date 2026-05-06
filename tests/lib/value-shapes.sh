# shellcheck shell=bash
#
# tests/lib/value-shapes.sh — adversarial value-shape fixtures for
# state-I/O tests, plus an `assert_value_shape_invariants` runner.
#
# Why this exists (Bug B post-mortem, v1.34.x). The original Bug B
# (read_state_keys positional misalignment under multi-line values)
# survived from v1.27.0 → v1.34.0 across:
#   • the per-PR review of the bulk-read helper itself,
#   • the v1.29.0 extension to 7 keys with consequence-bearing markers
#     at positions 5-6,
#   • a full state-I/O test (test-state-io.sh) covering bulk reads,
#   • the dedicated state-fuzz suite (test-state-fuzz.sh) covering
#     11 classes of JSON malformation,
#   • multiple quality-reviewer + excellence-reviewer dispatches.
# Every fixture in those tests used identifier-shaped values like
# "alpha", "one", "value-1". The bug class — values containing a
# newline / tab / RS / control byte — was never represented. Tests
# proved the implementation matched the author's imagination of what
# values look like, not what consumers (multi-line objectives, prompt
# bodies, task-notification payloads) actually pass.
#
# This lib closes the fixture-realism gap. The contract:
#
#   ANY new positional-decode test, bulk-read test, batch-write test,
#   or any helper that round-trips arbitrary user-controlled strings
#   through state.json MUST exercise it against `omc_adversarial_values`.
#
# Adding a non-adversarial test on a positional API is now considered
# incomplete — the rule lives in CONTRIBUTING.md "Fixture realism rule"
# so the agent reviewer pass can flag the gap.
#
# Public API:
#   omc_adversarial_values        — emits an array of adversarial fixtures.
#   omc_adversarial_value_count   — number of fixtures (callers can iterate).
#   omc_adversarial_value_label   — human-readable label for a given idx.
#   assert_value_shape_invariants — runs a write-then-read round-trip
#                                   for every adversarial value, asserts
#                                   byte-exact equality, increments
#                                   parent-scope `pass` / `fail` vars.
#
# Adversarial set covers the failure-mode classes that have actually
# bitten oh-my-claude in production:
#
#   1. Single-line ASCII             — control: trivial round-trip baseline
#   2. Multi-line newline-bearing    — Bug B (v1.27.0 → v1.34.0)
#   3. Tab + mixed whitespace        — JSON encoding edge
#   4. ASCII RS (0x1e) inside value  — collides with the read_state_keys
#                                      delimiter post-fix; jq keeps it but
#                                      a naive consumer's read -d would split
#   5. Other low-control bytes       — would-be ANSI-injection vectors
#                                      (record-archetype A3-MED-2)
#   6. Trailing newline              — easy off-by-one in line-truncation
#   7. Very long string              — 4KB body; PIPE_BUF / value-cap edges
#   8. Empty string                  — semantically distinct from absent
#   9. Single space + leading space  — strip-eaten by IFS reads
#  10. Quote-heavy mixed punctuation — jq --arg escaping edges
#  11. Unicode multi-byte            — locale & UTF-8 byte-count edges
#  12. CRLF line endings             — Windows-clipboard prompt paste
#
# NUL is intentionally excluded: jq -j strips it from output and bash
# variables cannot hold NUL anyway. The state-fuzz suite's NUL coverage
# tests jq parser robustness — a different surface from value-content.

# Emit each adversarial value, one per line, with each line itself
# being a literal printf-decoded fixture. Producers and consumers
# should iterate via the count; the labels exist for failure messages.
omc_adversarial_value_count=12

# Label lookup. Keep ordering aligned with omc_adversarial_value(idx).
omc_adversarial_value_label() {
  local idx="$1"
  case "${idx}" in
    0)  printf 'single-line ASCII (control)' ;;
    1)  printf 'multi-line newline-bearing (Bug B class)' ;;
    2)  printf 'tab + mixed whitespace' ;;
    3)  printf 'embedded ASCII RS (0x1e)' ;;
    4)  printf 'low control bytes (BEL, BS, ESC)' ;;
    5)  printf 'trailing newline' ;;
    6)  printf 'very long (4096 chars)' ;;
    7)  printf 'empty string' ;;
    8)  printf 'leading and trailing spaces' ;;
    9)  printf 'quote-heavy mixed punctuation' ;;
    10) printf 'Unicode multi-byte' ;;
    11) printf 'CRLF line endings' ;;
    *)  printf 'unknown' ;;
  esac
}

# Emit the i-th adversarial value verbatim on stdout (no trailing
# newline added by the helper itself; printf format strings produce
# whatever the value contains). Callers should capture into a variable
# via $(omc_adversarial_value <idx>) — bash command substitution
# strips ONLY trailing-newline runs, which the round-trip already
# normalizes against on the consumer side.
omc_adversarial_value() {
  local idx="$1"
  case "${idx}" in
    0)  printf 'plain-ascii-token' ;;
    1)  printf 'line one\nline two\nline three\nline four\nline five\nline six\nline seven' ;;
    2)  printf 'col_a\tcol_b\tcol_c\nrow2_a\trow2_b\trow2_c' ;;
    3)  printf 'before_rs\036after_rs' ;;
    4)  printf 'bel<\a>esc<\033>bs<\b>' ;;
    5)  printf 'value with trailing newline\n' ;;
    6)  printf 'A%.0s' {1..4096} ;;
    7)  printf '' ;;
    8)  printf '   leading and trailing   ' ;;
    9)  printf "v\$alue \`backticks\` and 'quotes' and \"doubles\" and \\backslash" ;;
    10) printf 'résumé — naïve façade — 中文 — 😀 emoji' ;;
    11) printf 'crlf line one\r\ncrlf line two\r\n' ;;
    *)  printf '' ;;
  esac
}

# assert_value_shape_invariants <label-prefix> <writer-fn> <reader-fn>
#
# For every adversarial value, calls:
#   <writer-fn> "${test_key}" "${adversarial_value}"
#   actual="$( <reader-fn> "${test_key}" )"
# and asserts byte-for-byte equality with the adversarial value.
#
# The runner expects three things from the surrounding test file:
#   • `pass` and `fail` integer variables in scope (the standard
#     test-state-io.sh / test-common-utilities.sh convention).
#   • Writer and reader functions that take (key, value) / (key)
#     respectively and behave like write_state / read_state.
#   • Each iteration uses a unique test key (`<prefix>_${idx}`) so
#     concurrent / interleaved invariants do not stomp on each other.
#
# Failure prints a label, the index, the human-readable shape label,
# the expected (byte-quoted) and actual values. The %q format gives
# a shell-safe rendition that surfaces newlines, tabs, and control
# bytes literally so failures are diagnosable without re-running.
assert_value_shape_invariants() {
  local label_prefix="$1"
  local writer_fn="$2"
  local reader_fn="$3"
  local idx
  for ((idx = 0; idx < omc_adversarial_value_count; idx++)); do
    local val
    val="$(omc_adversarial_value "${idx}")"
    local key="value_shape_${label_prefix//[^a-zA-Z0-9_]/_}_${idx}"
    "${writer_fn}" "${key}" "${val}"
    local actual
    actual="$( "${reader_fn}" "${key}" )"
    if [[ "${actual}" == "${val}" ]]; then
      pass=$((pass + 1))
    else
      printf '  FAIL: %s [shape %d: %s]\n    expected=%q\n    actual=  %q\n' \
        "${label_prefix}" "${idx}" \
        "$(omc_adversarial_value_label "${idx}")" \
        "${val}" "${actual}" >&2
      fail=$((fail + 1))
    fi
  done
}

# omc_value_bulk_expected — return what the bulk reader is contractually
# allowed to emit for a given input value. The Consumer contract on
# read_state_keys (lib/state-io.sh) strips embedded ASCII RS (0x1e)
# from values to defend positional alignment; for every other byte the
# round-trip is exact.
#
# Test code that asserts a bulk-read invariant should compare against
# `omc_value_bulk_expected "${val}"`, not the raw value. This keeps
# the test honest about what the API guarantees vs what it does not.
omc_value_bulk_expected() {
  local val="$1"
  printf '%s' "${val//$'\x1e'/}"
}

# assert_bulk_value_shape_invariants <label> <bulk-writer-fn> <bulk-reader-fn>
#
# Adversarial coverage for *bulk* (positional) APIs. Writes a 7-key
# state with adversarial values at every position, then bulk-reads
# them back and asserts each position matches the contractually-allowed
# expected form (omc_value_bulk_expected — which strips embedded RS
# bytes per the read_state_keys Consumer contract).
#
# Concretely catches the Bug B failure mode: a multi-line value at
# position 0 spilling into positions 1-6. The shape-7 layout matches
# read_state_keys's canonical caller (prompt-intent-router.sh).
#
# bulk-writer-fn signature: <fn> k1 v1 k2 v2 ...
# bulk-reader-fn signature: <fn> k1 k2 ... — emits N RS-delimited records.
assert_bulk_value_shape_invariants() {
  local label="$1"
  local bulk_writer="$2"
  local bulk_reader="$3"

  # Walk the 12 adversarial values as positional payloads. The 7-key
  # frame matches read_state_keys's hottest caller; we test multiple
  # frames by rotating the offending value through positions 0/3/5
  # so a positional bug at any slot surfaces.
  local offending_position
  for offending_position in 0 3 5; do
    local idx
    for ((idx = 0; idx < omc_adversarial_value_count; idx++)); do
      local val
      val="$(omc_adversarial_value "${idx}")"
      local label_str
      label_str="$(omc_adversarial_value_label "${idx}")"

      # Build the 7-key frame: 6 plain-token slots + the adversarial
      # value parked at offending_position.
      local k0="bulk_k0_${label}_${idx}_${offending_position}" v0="alpha"
      local k1="bulk_k1_${label}_${idx}_${offending_position}" v1="beta"
      local k2="bulk_k2_${label}_${idx}_${offending_position}" v2="gamma"
      local k3="bulk_k3_${label}_${idx}_${offending_position}" v3="delta"
      local k4="bulk_k4_${label}_${idx}_${offending_position}" v4="epsilon"
      local k5="bulk_k5_${label}_${idx}_${offending_position}" v5="zeta"
      local k6="bulk_k6_${label}_${idx}_${offending_position}" v6="eta"
      case "${offending_position}" in
        0) v0="${val}" ;;
        3) v3="${val}" ;;
        5) v5="${val}" ;;
      esac

      "${bulk_writer}" "${k0}" "${v0}" "${k1}" "${v1}" "${k2}" "${v2}" \
                       "${k3}" "${v3}" "${k4}" "${v4}" "${k5}" "${v5}" \
                       "${k6}" "${v6}"

      # Read back via the bulk reader (which emits RS-delimited records).
      # Decoder pattern matches the canonical consumer in router /
      # stop-guard so the test exercises the same code path as production.
      local got=()
      local _capture
      _capture="$(mktemp)"
      "${bulk_reader}" "${k0}" "${k1}" "${k2}" "${k3}" "${k4}" "${k5}" "${k6}" >"${_capture}"
      local _line
      while IFS= read -r -d $'\x1e' _line; do
        got[${#got[@]}]="${_line}"
      done <"${_capture}"
      rm -f "${_capture}"

      if [[ "${#got[@]}" -ne 7 ]]; then
        printf '  FAIL: %s [shape %d %s; offending pos %d]\n    expected 7 records, got %d\n' \
          "${label}" "${idx}" "${label_str}" "${offending_position}" "${#got[@]}" >&2
        fail=$((fail + 1))
        continue
      fi

      local _all_ok=1
      for slot in 0 1 2 3 4 5 6; do
        local raw_v expected_v
        case "${slot}" in
          0) raw_v="${v0}" ;;
          1) raw_v="${v1}" ;;
          2) raw_v="${v2}" ;;
          3) raw_v="${v3}" ;;
          4) raw_v="${v4}" ;;
          5) raw_v="${v5}" ;;
          6) raw_v="${v6}" ;;
        esac
        # Bulk reader strips embedded RS per the read_state_keys
        # Consumer contract; compare against the contractually-allowed
        # expected form, not the raw input.
        expected_v="$(omc_value_bulk_expected "${raw_v}")"
        if [[ "${got[$slot]}" != "${expected_v}" ]]; then
          printf '  FAIL: %s [shape %d %s; offending pos %d; slot %d]\n    expected=%q\n    actual=  %q\n' \
            "${label}" "${idx}" "${label_str}" "${offending_position}" "${slot}" \
            "${expected_v}" "${got[$slot]}" >&2
          fail=$((fail + 1))
          _all_ok=0
          break
        fi
      done
      [[ "${_all_ok}" -eq 1 ]] && pass=$((pass + 1))
    done
  done
}
