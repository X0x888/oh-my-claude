#!/usr/bin/env bash
# Regression tests for `model_overrides` — the per-agent model assignment
# that complements the all-or-nothing `model_tier` flag.
#
# The override logic lives in two lockstep copies: install.sh's
# apply_model_overrides() and switch-tier.sh's. We exercise the behavior
# end-to-end through switch-tier.sh (fast, isolated via a sandboxed HOME)
# and guard the install.sh copy with a static lockstep grep at the end.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWITCH_TIER="${REPO_ROOT}/bundle/dot-claude/switch-tier.sh"
INSTALL_SH="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# model_of <home> <agent> -> prints the agent's current `model:` value.
model_of() {
  grep -E '^model: ' "$1/.claude/agents/$2.md" 2>/dev/null | head -1 | sed 's/^model: //'
}

# seed_home <home> -> minimal agent files with known starting models.
seed_home() {
  local home="$1"
  mkdir -p "${home}/.claude/agents"
  printf -- '---\nname: oracle\nmodel: opus\n---\nbody\n'           > "${home}/.claude/agents/oracle.md"
  printf -- '---\nname: librarian\nmodel: sonnet\n---\nbody\n'      > "${home}/.claude/agents/librarian.md"
  printf -- '---\nname: quality-reviewer\nmodel: opus\n---\nbody\n' > "${home}/.claude/agents/quality-reviewer.md"
}

printf '\n## model_overrides — per-agent model assignment\n'

# ---------------------------------------------------------------------------
# Test 1: overrides win over the bulk tier rewrite; bad pairs skipped.
# economy rewrites opus->sonnet across the roster; overrides then re-pin.
# ---------------------------------------------------------------------------
H1="${TMP_ROOT}/h1"
seed_home "${H1}"
printf 'model_overrides=librarian:haiku,oracle:opus,quality-reviewer:badmodel,ghost-agent:opus\n' \
  > "${H1}/.claude/oh-my-claude.conf"
out1="$(HOME="${H1}" bash "${SWITCH_TIER}" economy 2>&1)" || true

if [[ "$(model_of "${H1}" librarian)" == "haiku" ]]; then
  ok "override wins over tier (librarian sonnet -> haiku)"
else
  bad "librarian expected haiku, got '$(model_of "${H1}" librarian)'"
fi

if [[ "$(model_of "${H1}" oracle)" == "opus" ]]; then
  ok "override re-lifts an agent the tier downgraded (oracle -> opus)"
else
  bad "oracle expected opus, got '$(model_of "${H1}" oracle)'"
fi

if [[ "$(model_of "${H1}" quality-reviewer)" == "sonnet" ]]; then
  ok "invalid model skipped, tier value kept (quality-reviewer sonnet)"
else
  bad "quality-reviewer expected sonnet, got '$(model_of "${H1}" quality-reviewer)'"
fi

if printf '%s' "${out1}" | grep -q 'skipping'; then
  ok "skip diagnostics emitted for bad model + missing agent"
else
  bad "expected skip diagnostics in output"
fi

# ---------------------------------------------------------------------------
# Test 2: OMC_MODEL_OVERRIDES env takes precedence over the conf value.
# ---------------------------------------------------------------------------
H2="${TMP_ROOT}/h2"
seed_home "${H2}"
printf 'model_overrides=librarian:haiku\n' > "${H2}/.claude/oh-my-claude.conf"
OMC_MODEL_OVERRIDES='librarian:opus' HOME="${H2}" bash "${SWITCH_TIER}" economy >/dev/null 2>&1 || true

if [[ "$(model_of "${H2}" librarian)" == "opus" ]]; then
  ok "env OMC_MODEL_OVERRIDES wins over conf (librarian opus, not haiku)"
else
  bad "env precedence failed: librarian = '$(model_of "${H2}" librarian)'"
fi

# ---------------------------------------------------------------------------
# Test 3: overrides survive a later tier switch (economy -> quality).
# ---------------------------------------------------------------------------
H3="${TMP_ROOT}/h3"
seed_home "${H3}"
printf 'model_overrides=librarian:haiku\n' > "${H3}/.claude/oh-my-claude.conf"
HOME="${H3}" bash "${SWITCH_TIER}" economy >/dev/null 2>&1 || true
HOME="${H3}" bash "${SWITCH_TIER}" quality >/dev/null 2>&1 || true

if [[ "$(model_of "${H3}" librarian)" == "haiku" ]]; then
  ok "override survives a tier switch (librarian stays haiku through economy->quality)"
else
  bad "override lost across tier switch: librarian = '$(model_of "${H3}" librarian)'"
fi

# ---------------------------------------------------------------------------
# Test 3b: override wins over the `balanced` restore path too. `balanced`
# restores bundle defaults from the repo copy (a different code path than
# the in-place sed used by economy/quality), then applies overrides on top.
# ---------------------------------------------------------------------------
H3B="${TMP_ROOT}/h3b"
seed_home "${H3B}"
printf 'repo_path=%s\nmodel_overrides=librarian:haiku\n' "${REPO_ROOT}" > "${H3B}/.claude/oh-my-claude.conf"
HOME="${H3B}" bash "${SWITCH_TIER}" balanced >/dev/null 2>&1 || true

if [[ "$(model_of "${H3B}" librarian)" == "haiku" ]]; then
  ok "override wins over the balanced restore path (librarian -> haiku)"
else
  bad "balanced restore lost the override: librarian = '$(model_of "${H3B}" librarian)'"
fi

# ---------------------------------------------------------------------------
# Test 4: no model_overrides => pure tier behavior, no override summary.
# ---------------------------------------------------------------------------
H4="${TMP_ROOT}/h4"
seed_home "${H4}"
printf 'model_tier=economy\n' > "${H4}/.claude/oh-my-claude.conf"
out4="$(HOME="${H4}" bash "${SWITCH_TIER}" economy 2>&1)" || true

if [[ "$(model_of "${H4}" oracle)" == "sonnet" ]]; then
  ok "no overrides: pure tier behavior (oracle opus -> sonnet)"
else
  bad "tier-only path broken: oracle = '$(model_of "${H4}" oracle)'"
fi

if printf '%s' "${out4}" | grep -q 'Model overrides'; then
  bad "empty model_overrides must not print an override summary"
else
  ok "no override summary when model_overrides is empty"
fi

# ---------------------------------------------------------------------------
# Test 4b: `inherit` tier semantics (v1.49). Deliberators ship with
# `model: inherit` (ride the session's main model). economy must demote
# inherit -> sonnet (cost tier stays cheap); quality must leave inherit
# untouched (already >= opus-grade); `inherit` is a valid override value.
# ---------------------------------------------------------------------------
H5="${TMP_ROOT}/h5"
seed_home "${H5}"
printf -- '---\nname: metis\nmodel: inherit\n---\nbody\n' > "${H5}/.claude/agents/metis.md"
HOME="${H5}" bash "${SWITCH_TIER}" economy >/dev/null 2>&1 || true

if [[ "$(model_of "${H5}" metis)" == "sonnet" ]]; then
  ok "economy demotes inherit -> sonnet (metis)"
else
  bad "economy left inherit behind: metis = '$(model_of "${H5}" metis)'"
fi

H6="${TMP_ROOT}/h6"
seed_home "${H6}"
printf -- '---\nname: metis\nmodel: inherit\n---\nbody\n' > "${H6}/.claude/agents/metis.md"
printf 'model_overrides=oracle:inherit\n' > "${H6}/.claude/oh-my-claude.conf"
HOME="${H6}" bash "${SWITCH_TIER}" quality >/dev/null 2>&1 || true

if [[ "$(model_of "${H6}" metis)" == "inherit" ]]; then
  ok "quality leaves inherit untouched (metis)"
else
  bad "quality rewrote inherit: metis = '$(model_of "${H6}" metis)'"
fi

if [[ "$(model_of "${H6}" librarian)" == "opus" ]]; then
  ok "quality still lifts sonnet -> opus (librarian)"
else
  bad "quality sonnet lift broken: librarian = '$(model_of "${H6}" librarian)'"
fi

if [[ "$(model_of "${H6}" oracle)" == "inherit" ]]; then
  ok "inherit accepted as an override value (oracle -> inherit)"
else
  bad "oracle:inherit override rejected: oracle = '$(model_of "${H6}" oracle)'"
fi

# Balanced restore brings the bundle's inherit default back after a tier
# flattened it (also pins the bundle default itself: metis IS inherit).
H7="${TMP_ROOT}/h7"
seed_home "${H7}"
printf -- '---\nname: metis\nmodel: opus\n---\nbody\n' > "${H7}/.claude/agents/metis.md"
printf 'repo_path=%s\n' "${REPO_ROOT}" > "${H7}/.claude/oh-my-claude.conf"
HOME="${H7}" bash "${SWITCH_TIER}" balanced >/dev/null 2>&1 || true

if [[ "$(model_of "${H7}" metis)" == "inherit" ]]; then
  ok "balanced restore recovers the bundle inherit default (metis)"
else
  bad "balanced restore did not recover inherit: metis = '$(model_of "${H7}" metis)'"
fi

# ---------------------------------------------------------------------------
# Test 5: lockstep — both copies of the logic define AND call the helper.
# ---------------------------------------------------------------------------
for f in "${INSTALL_SH}" "${SWITCH_TIER}"; do
  name="$(basename "${f}")"
  if grep -q 'apply_model_overrides()' "${f}"; then
    ok "${name} defines apply_model_overrides()"
  else
    bad "${name} is missing the apply_model_overrides() definition"
  fi
  if grep -qE 'apply_model_overrides "' "${f}"; then
    ok "${name} calls apply_model_overrides"
  else
    bad "${name} never calls apply_model_overrides"
  fi
done

printf '\n--- model_overrides: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
