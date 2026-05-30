#!/usr/bin/env bash
# test-no-out-of-scope-contract.sh — regression net for the v1.44
# No-Out-of-Scope contract.
#
# Sibling to test-no-defer-contract.sh. Where no-defer governs FINDINGS,
# No-Out-of-Scope governs SURFACES (intent-broadening) and BARE PROMPTS
# (single-word imperative → god-scope scan). The contract itself runs as
# load-bearing prose in core.md and as routing/directives in
# prompt-intent-router.sh + lib/classifier.sh. This test net protects
# the documentation surface AND the wiring so a future "doc cleanup"
# or "consolidate directives" wave cannot silently delete it.
#
# Coverage:
#   T1  — core.md contains the No-Out-of-Scope contract section header
#   T2  — core.md FORBIDDEN list cross-references No-Out-of-Scope
#         softening proposals
#   T3  — core.md "ASK do not announce" carve-out is REPLACED by the
#         fresh-context sub-dispatch directive (the v1.43 escape hatch
#         is closed)
#   T4  — classifier.sh exports is_bare_imperative_prompt
#   T5  — is_bare_imperative_prompt matches verb-only prompts ("fix",
#         "audit", "ship.", "POLISH")
#   T6  — is_bare_imperative_prompt rejects prompts with code anchors
#   T7  — is_bare_imperative_prompt rejects prompts above 30 chars
#   T8  — common.sh exports is_god_scope_enabled
#   T9  — god_scope_on_bare_prompt default in common.sh is "on"
#   T10 — oh-my-claude.conf.example documents the flag with default "on"
#   T11 — omc-config.sh emit_known_flags lists god_scope_on_bare_prompt
#   T12 — prompt-intent-router.sh injects the GOD-SCOPE-SCAN directive
#   T13 — intent-broadening directives say "ship or wave-append" — NOT
#         "ship or defer with a one-line WHY"
#   T14 — exemplifying-scope workflow forbids "declined" as a generic
#         escape — only false-sibling/already-shipped/obsolete pass
#   T15 — bias-defense intent-verify directive no longer names a
#         pause case (the (a) low-confidence (b) hard-to-reverse hold)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE_MD="${REPO_DIR}/bundle/dot-claude/quality-pack/memory/core.md"
CLASSIFIER="${REPO_DIR}/bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh"
COMMON_SH="${REPO_DIR}/bundle/dot-claude/skills/autowork/scripts/common.sh"
ROUTER="${REPO_DIR}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
CONF_EXAMPLE="${REPO_DIR}/bundle/dot-claude/oh-my-claude.conf.example"
OMC_CONFIG="${REPO_DIR}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"

passed=0
failed=0

run_test() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf 'PASS %s\n' "${name}"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n' "${name}" >&2
  fi
}

echo "== test-no-out-of-scope-contract =="
echo

# --- T1: core.md contract section header
run_test "T1 core.md has v1.44 No-Out-of-Scope contract header" \
  grep -Fq "## The v1.44 No-Out-of-Scope contract (load-bearing — do NOT optimize this away)" "${CORE_MD}"

# --- T2: core.md FORBIDDEN list cross-references the contract
run_test "T2 core.md FORBIDDEN list names No-Out-of-Scope softening" \
  grep -Fq "FORBIDDEN: Softening the v1.44 No-Out-of-Scope contract" "${CORE_MD}"

# --- T3: ASK-don't-announce escape closed — text now points at sub-dispatch
run_test "T3 core.md drift-degraded carve-out routes to sub-dispatch (not user-ask)" \
  bash -c "grep -Fq 'dispatch a fresh-context sub-agent, do NOT announce a session boundary' '${CORE_MD}'"

# --- T4: classifier exports is_bare_imperative_prompt
run_test "T4 classifier.sh exports is_bare_imperative_prompt" \
  grep -Eq '^is_bare_imperative_prompt\(\)' "${CLASSIFIER}"

# --- T5/6/7: behavior of is_bare_imperative_prompt
_bare_check() {
  local prompt="$1"
  local expect="$2"  # 0 or 1
  (
    set +e
    export OMC_LAZY_CLASSIFIER=0
    # shellcheck source=/dev/null
    . "${COMMON_SH}"
    if is_bare_imperative_prompt "${prompt}"; then
      [[ "${expect}" == "0" ]]
    else
      [[ "${expect}" == "1" ]]
    fi
  )
}

run_test "T5a 'fix' matches" _bare_check "fix" 0
run_test "T5b 'audit' matches" _bare_check "audit" 0
run_test "T5c 'ship.' matches (trailing punctuation)" _bare_check "ship." 0
run_test "T5d 'POLISH' matches (case-insensitive)" _bare_check "POLISH" 0
run_test "T5e 'fix it' matches (verb + bare object)" _bare_check "fix it" 0
run_test "T5f 'audit everything' matches" _bare_check "audit everything" 0
run_test "T5g 'audit everything please' matches (multi-token trail)" _bare_check "audit everything please" 0
run_test "T5h 'fix it now please' matches (3-token trail)" _bare_check "fix it now please" 0

run_test "T6a 'fix lib/foo.sh' rejected (code anchor)" _bare_check "fix lib/foo.sh" 1
run_test "T6b 'fix the bug in classify_task_intent' rejected (function anchor)" _bare_check "fix the bug in classify_task_intent" 1

run_test "T7a 'fix all the bugs in the classifier please' rejected (>30 chars)" _bare_check "fix all the bugs in the classifier please" 1
run_test "T7b empty prompt rejected" _bare_check "" 1

# --- T8: common.sh exports is_god_scope_enabled
run_test "T8 common.sh exports is_god_scope_enabled" \
  grep -Eq '^is_god_scope_enabled\(\)' "${COMMON_SH}"

# --- T9: default ON
run_test "T9 god_scope_on_bare_prompt default is on" \
  grep -q 'OMC_GOD_SCOPE_ON_BARE_PROMPT:-on' "${COMMON_SH}"

# --- T10: conf.example documents the flag
run_test "T10 conf.example documents god_scope_on_bare_prompt" \
  grep -q '^#god_scope_on_bare_prompt=on' "${CONF_EXAMPLE}"

# --- T11: omc-config emit_known_flags lists it
run_test "T11 omc-config emit_known_flags lists god_scope_on_bare_prompt" \
  grep -q '^god_scope_on_bare_prompt|bool|on|' "${OMC_CONFIG}"

# --- T12: router injects GOD-SCOPE-SCAN directive
run_test "T12 prompt-intent-router has GOD-SCOPE-SCAN directive injection" \
  grep -Fq 'GOD-SCOPE SCAN DIRECTIVE' "${ROUTER}"

run_test "T12b directive references is_bare_imperative_prompt and god_scope_required state" \
  bash -c "grep -Fq 'is_bare_imperative_prompt' '${ROUTER}' && grep -Fq 'god_scope_required' '${ROUTER}'"

# --- T13: intent-broadening directives say ship-or-wave-append, NOT
# "defer with WHY"
run_test "T13a intent-broadening (with-inventory) names ship-or-wave-append" \
  grep -Fq 'There is no out-of-scope' "${ROUTER}"

run_test "T13b intent-broadening (no-inventory) names wave-append, refuses defer" \
  bash -c "grep -Fq 'There is no out-of-scope under ULW' '${ROUTER}'"

# Negative — the "ship them or defer each with a one-line concrete WHY"
# phrasing must NOT survive in either intent-broadening directive
# (the silent-defer legitimation path the v1.44 contract closes).
run_test "T13c old 'defer each with one-line WHY' phrasing is removed" \
  bash -c "! grep -Fq 'ship them or defer each with a one-line concrete WHY' '${ROUTER}' \
        && ! grep -Fq 'ship the gap or defer with a one-line concrete WHY' '${ROUTER}'"

# --- T14: exemplifying-scope workflow restricts declined to genuine
# non-class items
run_test "T14 exemplifying-scope workflow restricts declined to genuine non-class items" \
  bash -c "grep -Fq 'genuine non-class items (false sibling, already-shipped, obsolete)' '${ROUTER}'"

# --- T15: bias-defense intent-verify no longer carries the "hard to
# reverse" hold paragraph
run_test "T15 intent-verify directive removes (b) hard-to-reverse pause clause" \
  bash -c "! grep -Fq '(b) the wrong call would be hard to reverse' '${ROUTER}'"

# --- T16-T22: v1.46 open-mandate / innovation-generation directive ---
# Sibling to god-scope (T8-T12) for PROSE open mandates that exceed the
# 30-char bare-imperative cap. Closes the mandate-narrowing gap where a
# prompt like "implement all improvements" never reached god-scope and the
# model narrowed the open mandate into a closeable defect-audit.

run_test "T16 classifier exports is_exhaustive_authorization_request" \
  grep -Eq '^is_exhaustive_authorization_request\(\)' "${CLASSIFIER}"

run_test "T17 common.sh exports is_exhaustive_auth_directive_enabled" \
  grep -Eq '^is_exhaustive_auth_directive_enabled\(\)' "${COMMON_SH}"

run_test "T18 exhaustive_auth_directive default is on" \
  grep -q 'OMC_EXHAUSTIVE_AUTH_DIRECTIVE:-on' "${COMMON_SH}"

run_test "T19 conf.example documents exhaustive_auth_directive" \
  grep -q '^#exhaustive_auth_directive=on' "${CONF_EXAMPLE}"

run_test "T20 omc-config emit_known_flags lists exhaustive_auth_directive" \
  grep -q '^exhaustive_auth_directive|bool|on|' "${OMC_CONFIG}"

run_test "T21a router injects OPEN-MANDATE / INNOVATION-GENERATION directive" \
  grep -Fq 'OPEN-MANDATE / INNOVATION-GENERATION DIRECTIVE' "${ROUTER}"

run_test "T21b open-mandate block gates on the flag + the exhaustive-auth predicate + god-scope MUTEX" \
  bash -c "grep -Fq 'is_exhaustive_auth_directive_enabled' '${ROUTER}' && grep -Fq 'is_exhaustive_authorization_request' '${ROUTER}' && grep -Fq 'god_scope_required' '${ROUTER}'"

# T21c: recoverability-gated ambition (MuleScore adaptation) — the directive
# rewards bold RECOVERABLE work but BOUNDS it to the five pause cases so
# "Explore" can never green-light an irreversible action.
run_test "T21c open-mandate directive rewards recoverable ambition + bounds it to the five pause cases" \
  bash -c "grep -Fq 'CALIBRATED TO RECOVERABILITY' '${ROUTER}' && grep -Fq 'irreversibility wins and the pause case governs' '${ROUTER}'"

# Behavioral: the gating predicate fires on the canonical open-mandate
# prompt (the one that narrowed this session) and stays silent on a narrow
# code-anchored prompt — proving the directive routes correctly. Mirrors
# the _bare_check pattern (T5-T7).
_exhaustive_check() {
  local prompt="$1"
  local expect="$2"  # 0 = fires, 1 = silent
  (
    set +e
    export OMC_LAZY_CLASSIFIER=0
    # shellcheck source=/dev/null
    . "${COMMON_SH}"
    if is_exhaustive_authorization_request "${prompt}"; then
      [[ "${expect}" == "0" ]]
    else
      [[ "${expect}" == "1" ]]
    fi
  )
}

run_test "T22a fires on the session's narrowed open mandate" \
  _exhaustive_check "comprehensively evaluate this project and implement all improvements" 0
run_test "T22b fires on bare 'implement all improvements'" \
  _exhaustive_check "implement all improvements" 0
run_test "T22c silent on narrow 'fix the typo in README.md'" \
  _exhaustive_check "fix the typo in README.md" 1

echo
echo "Results: ${passed} passed, ${failed} failed"
[[ "${failed}" -eq 0 ]] || exit 1
