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

# seed_home <home> -> full shipped roster with three deliberately noncanonical
# starting models. The switcher now preflights the complete active roster
# before changing or persisting anything.
seed_home() {
  local home="$1"
  mkdir -p "${home}/.claude"
  cp -R "${REPO_ROOT}/bundle/dot-claude/agents" "${home}/.claude/agents"
  printf -- '---\nname: oracle\nmodel: opus\n---\nbody\n'           > "${home}/.claude/agents/oracle.md"
  printf -- '---\nname: librarian\nmodel: sonnet\n---\nbody\n'      > "${home}/.claude/agents/librarian.md"
  printf -- '---\nname: quality-reviewer\nmodel: opus\n---\nbody\n' > "${home}/.claude/agents/quality-reviewer.md"
}

seed_full_home() {
  local home="$1"
  mkdir -p "${home}/.claude"
  cp -R "${REPO_ROOT}/bundle/dot-claude/agents" "${home}/.claude/agents"
  cp "${SWITCH_TIER}" "${home}/.claude/switch-tier.sh"
  chmod +x "${home}/.claude/switch-tier.sh"
}

count_model() {
  local home="$1" model="$2"
  { grep -hE "^model: ${model}$" "${home}/.claude/agents/"*.md 2>/dev/null || true; } \
    | wc -l | tr -d '[:space:]'
}

file_mode() {
  local path="$1"
  stat -f '%Lp' "${path}" 2>/dev/null \
    || stat -c '%a' "${path}" 2>/dev/null
}

agent_tree_digest() {
  local home="$1"
  find "${home}/.claude/agents" -type f -name '*.md' -print \
    | sort \
    | while IFS= read -r agent_file; do
        printf '%s  %s\n' "$(cksum < "${agent_file}")" \
          "${agent_file#"${home}/.claude/agents/"}"
      done \
    | cksum
}

wait_for_file() {
  local path="$1" attempt=0
  while [[ ! -e "${path}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 1000 ]] || return 1
    sleep 0.01
  done
}

remove_killed_owner_lock() {
  local home="$1" expected_pid="$2" lock=""
  lock="${home}/.claude/.install.lock"
  [[ -d "${lock}" && ! -L "${lock}" \
      && "$(cat "${lock}/pid" 2>/dev/null || true)" == "${expected_pid}" ]] \
    || return 1
  local participant=""
  for participant in "${lock}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 1
  done
  rm -f -- "${lock}/pid" "${lock}/token" || return 1
  rmdir "${lock}"
}

printf '\n## model_overrides — per-agent model assignment\n'

# ---------------------------------------------------------------------------
# Test 1: overrides win over the bulk tier rewrite; bad pairs skipped.
# Economy reconstructs the inherited/Sonnet split; overrides then re-pin.
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

if [[ "$(model_of "${H1}" quality-reviewer)" == "inherit" ]]; then
  ok "invalid model skipped, tier value kept (quality-reviewer inherit)"
else
  bad "quality-reviewer expected inherit, got '$(model_of "${H1}" quality-reviewer)'"
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

# A wholly invalid environment value has no authority. It must fall back to
# the saved pins, and a traversal-shaped agent id must never rewrite a sibling
# file outside ~/.claude/agents.
H2B="${TMP_ROOT}/h2b"
seed_home "${H2B}"
printf -- '---\nname: victim\nmodel: sonnet\n---\nbody\n' \
  > "${H2B}/.claude/victim.md"
printf 'model_overrides=librarian:haiku\n' \
  > "${H2B}/.claude/oh-my-claude.conf"
out2b="$(OMC_MODEL_OVERRIDES='../victim:opus,librarian:not-a-model,broken' \
  HOME="${H2B}" bash "${SWITCH_TIER}" economy 2>&1)" || true
if [[ "$(model_of "${H2B}" librarian)" == "haiku" ]]; then
  ok "invalid-all env override falls back to the saved pin"
else
  bad "invalid-all env shadowed saved librarian pin: $(model_of "${H2B}" librarian)"
fi
if [[ "$(sed -n 's/^model: //p' "${H2B}/.claude/victim.md")" == "sonnet" ]]; then
  ok "path-traversal override cannot rewrite a sibling file"
else
  bad "path-traversal override modified the outside victim"
fi
if printf '%s' "${out2b}" | grep -q 'has no valid pins; falling back to saved overrides'; then
  ok "invalid-all materializer fallback is explained"
else
  bad "invalid-all materializer fallback warning missing: ${out2b}"
fi

# Mixed environment input keeps only its valid resolver subset at higher
# precedence. Bare custom named-model pins are runtime-only; traversal and
# extra-colon shapes are rejected before any path is constructed.
H2C="${TMP_ROOT}/h2c"
seed_home "${H2C}"
printf -- '---\nname: custom-agent\nmodel: sonnet\n---\nbody\n' \
  > "${H2C}/.claude/agents/custom-agent.md"
printf -- '---\nname: victim\nmodel: sonnet\n---\nbody\n' \
  > "${H2C}/.claude/victim.md"
printf 'model_overrides=librarian:haiku\n' \
  > "${H2C}/.claude/oh-my-claude.conf"
out2c="$(OMC_MODEL_OVERRIDES='broken,librarian:opus,custom-agent:haiku,../victim:opus,too:many:colons:opus' \
  HOME="${H2C}" bash "${SWITCH_TIER}" economy 2>&1)" || true
if [[ "$(model_of "${H2C}" librarian)" == "opus" ]]; then
  ok "mixed env valid subset keeps precedence over saved pins"
else
  bad "mixed env valid librarian pin did not win: $(model_of "${H2C}" librarian)"
fi
if [[ "$(model_of "${H2C}" custom-agent)" == "sonnet" ]]; then
  ok "bare custom-agent named-model pin stays runtime-only"
else
  bad "bare custom-agent pin rewrote user-owned frontmatter: $(model_of "${H2C}" custom-agent)"
fi
if printf '%s' "${out2c}" | grep -q 'runtime-only custom-agent'; then
  ok "custom runtime-only materialization boundary is explained"
else
  bad "custom runtime-only diagnostic missing: ${out2c}"
fi
if [[ "$(sed -n 's/^model: //p' "${H2C}/.claude/victim.md")" == "sonnet" ]]; then
  ok "mixed traversal input cannot modify the outside victim"
else
  bad "mixed traversal input modified the outside victim"
fi
if printf '%s' "${out2c}" | grep -q 'invalid bare agent id'; then
  ok "traversal and extra-colon materializer entries are rejected explicitly"
else
  bad "invalid bare-id diagnostics missing: ${out2c}"
fi

# A namespaced pin is resolver-valid and therefore establishes environment
# precedence, but it is runtime-only and cannot be mapped onto a bare file.
H2D="${TMP_ROOT}/h2d"
seed_home "${H2D}"
printf 'model_overrides=librarian:haiku\n' \
  > "${H2D}/.claude/oh-my-claude.conf"
out2d="$(OMC_MODEL_OVERRIDES='plugin:oracle:opus' \
  HOME="${H2D}" bash "${SWITCH_TIER}" economy 2>&1)" || true
if [[ "$(model_of "${H2D}" librarian)" == "sonnet" ]]; then
  ok "runtime-only namespaced env pin suppresses lower-precedence saved pins"
else
  bad "namespaced env pin incorrectly fell back to saved librarian pin"
fi
if printf '%s' "${out2d}" | grep -q 'runtime-only plugin:oracle'; then
  ok "namespaced runtime-only handling is explained"
else
  bad "namespaced runtime-only diagnostic missing: ${out2d}"
fi

# `inherit` is encoded as Agent-model omission, so a namespaced pin cannot
# change an opaque plugin definition. It is not valid environment authority;
# the saved materializable bare pin must remain effective instead.
H2E="${TMP_ROOT}/h2e"
seed_home "${H2E}"
printf 'model_overrides=librarian:haiku\n' \
  > "${H2E}/.claude/oh-my-claude.conf"
out2e="$(OMC_MODEL_OVERRIDES='plugin:oracle:inherit' \
  HOME="${H2E}" bash "${SWITCH_TIER}" economy 2>&1)" || true
if [[ "$(model_of "${H2E}" librarian)" == "haiku" ]]; then
  ok "unenforceable namespaced inherit falls back to saved bare pins"
else
  bad "namespaced inherit incorrectly shadowed saved materialized pins"
fi
if printf '%s' "${out2e}" | grep -q 'has no valid pins; falling back'; then
  ok "unenforceable namespaced inherit rejection is explicit"
else
  bad "namespaced inherit rejection diagnostic missing: ${out2e}"
fi

# A missing/non-shipped bare inherit entry is no more enforceable than a
# namespaced one. It must not gain environment precedence and hide saved pins.
H2F="${TMP_ROOT}/h2f"
seed_home "${H2F}"
printf 'model_overrides=librarian:haiku\n' \
  > "${H2F}/.claude/oh-my-claude.conf"
out2f="$(OMC_MODEL_OVERRIDES='ghost:inherit' \
  HOME="${H2F}" bash "${SWITCH_TIER}" economy 2>&1)" || true
if [[ "$(model_of "${H2F}" librarian)" == "haiku" ]]; then
  ok "missing custom inherit cannot shadow saved pins"
else
  bad "missing custom inherit incorrectly gained environment authority"
fi
if printf '%s' "${out2f}" | grep -q 'has no valid pins; falling back'; then
  ok "missing custom inherit fallback is explicit"
else
  bad "missing custom inherit fallback diagnostic missing: ${out2f}"
fi

# Saved duplicate rows use the runtime's last-valid rule. A wholly malformed
# later row cannot erase an earlier materializable pin.
H2G="${TMP_ROOT}/h2g"
seed_home "${H2G}"
printf 'model_overrides= librarian:haiku \nmodel_overrides=broken,ghost:inherit\n' \
  > "${H2G}/.claude/oh-my-claude.conf"
HOME="${H2G}" bash "${SWITCH_TIER}" economy >/dev/null 2>&1 || true
if [[ "$(model_of "${H2G}" librarian)" == "haiku" ]]; then
  ok "invalid later saved override row cannot erase the last valid pins"
else
  bad "invalid later saved override erased librarian:haiku"
fi

# ---------------------------------------------------------------------------
# Test 3: overrides survive a later tier switch (economy -> quality).
# ---------------------------------------------------------------------------
H3="${TMP_ROOT}/h3"
seed_home "${H3}"
printf 'model_overrides=librarian:haiku\n' > "${H3}/.claude/oh-my-claude.conf"
HOME="${H3}" bash "${SWITCH_TIER}" economy >/dev/null 2>&1 || true
out3_quality="$(HOME="${H3}" bash "${SWITCH_TIER}" quality 2>&1)" || true

if [[ "$(model_of "${H3}" librarian)" == "haiku" ]]; then
  ok "override survives a tier switch (librarian stays haiku through economy->quality)"
else
  bad "override lost across tier switch: librarian = '$(model_of "${H3}" librarian)'"
fi

if [[ "$(model_of "${H3}" quality-reviewer)" == "inherit" ]]; then
  ok "direct economy->quality reconstructs the shipped inherit split"
else
  bad "economy->quality flattened quality-reviewer instead of restoring inherit: '$(model_of "${H3}" quality-reviewer)'"
fi

if printf '%s' "${out3_quality}" | grep -q 'Done\. 22 agent(s) updated to quality tier\.'; then
  ok "tier summary counts unique final model changes, not intermediate rewrites"
else
  bad "economy->quality summary should report 22 final changes: ${out3_quality}"
fi

# ---------------------------------------------------------------------------
# Test 3b: override wins over the `balanced` restore path too. `balanced`
# reconstructs bundled defaults from the embedded shipped rosters, then applies
# overrides on top without requiring the source repository to remain present.
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

if [[ "$(model_of "${H4}" oracle)" == "inherit" ]]; then
  ok "no overrides: Economy preserves inherited deliberation (oracle -> inherit)"
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
# `model: inherit` rides the session's current model. Economy and Quality both
# preserve it; `inherit` is a valid materialized bare override value.
# ---------------------------------------------------------------------------
H5="${TMP_ROOT}/h5"
seed_home "${H5}"
printf -- '---\nname: metis\nmodel: inherit\n---\nbody\n' > "${H5}/.claude/agents/metis.md"
HOME="${H5}" bash "${SWITCH_TIER}" economy >/dev/null 2>&1 || true

if [[ "$(model_of "${H5}" metis)" == "inherit" ]]; then
  ok "economy preserves inherit for deliberators (metis)"
else
  bad "economy flattened inherited deliberation: metis = '$(model_of "${H5}" metis)'"
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
# Test 4c: an installed quality -> economy switch does not need the source
# clone. Quality still materializes the inherit/Sonnet split, while economy can
# safely materialize the shipped roster and reapply overrides in place. The
# embedded rosters also make the reverse transition source-independent.
# ---------------------------------------------------------------------------
H8="${TMP_ROOT}/h8"
seed_home "${H8}"
sed 's/^model: opus$/model: inherit/' "${H8}/.claude/agents/oracle.md" \
  > "${H8}/.claude/agents/oracle.md.tmp" \
  && mv "${H8}/.claude/agents/oracle.md.tmp" "${H8}/.claude/agents/oracle.md"
sed 's/^model: opus$/model: inherit/' "${H8}/.claude/agents/quality-reviewer.md" \
  > "${H8}/.claude/agents/quality-reviewer.md.tmp" \
  && mv "${H8}/.claude/agents/quality-reviewer.md.tmp" "${H8}/.claude/agents/quality-reviewer.md"
sed 's/^model: sonnet$/model: opus/' "${H8}/.claude/agents/librarian.md" \
  > "${H8}/.claude/agents/librarian.md.tmp" \
  && mv "${H8}/.claude/agents/librarian.md.tmp" "${H8}/.claude/agents/librarian.md"
printf 'model_tier=quality\nrepo_path=%s\n' "${TMP_ROOT}/moved-repo" \
  > "${H8}/.claude/oh-my-claude.conf"
cp "${SWITCH_TIER}" "${H8}/.claude/switch-tier.sh"
out8="$(HOME="${H8}" bash "${H8}/.claude/switch-tier.sh" economy 2>&1)"
status8=$?

if [[ "${status8}" -eq 0 ]] \
    && [[ "$(model_of "${H8}" oracle)" == "inherit" ]] \
    && [[ "$(model_of "${H8}" librarian)" == "sonnet" ]] \
    && [[ "$(model_of "${H8}" quality-reviewer)" == "inherit" ]]; then
  ok "quality->economy succeeds after the source repo moved"
else
  bad "quality->economy incorrectly required source repo: status=${status8} output=${out8}"
fi

if printf '%s' "${out8}" | grep -q 'Done\. 1 agent(s) updated to economy tier\.'; then
  ok "missing-repo economy summary reports one unique fixed-role change"
else
  bad "missing-repo economy summary count inaccurate: ${out8}"
fi

if HOME="${H8}" bash "${H8}/.claude/switch-tier.sh" quality >/dev/null 2>&1 \
    && [[ "$(model_of "${H8}" oracle)" == "inherit" ]] \
    && [[ "$(model_of "${H8}" librarian)" == "opus" ]] \
    && [[ "$(model_of "${H8}" quality-reviewer)" == "inherit" ]]; then
  ok "economy->quality reconstructs shipped declarations without a source repo"
else
  bad "source-less economy->quality did not restore the shipped split"
fi

# ---------------------------------------------------------------------------
# Test 4d: replacing or clearing overrides under quality restores canonical
# declarations first. Without the explicit reconstruction an old oracle:opus
# or librarian:haiku pin is indistinguishable from a tier rewrite and lingers
# after the conf row is gone.
# ---------------------------------------------------------------------------
H9="${TMP_ROOT}/h9"
seed_home "${H9}"
printf 'repo_path=%s\nmodel_tier=quality\nmodel_overrides=oracle:opus,librarian:haiku\n' \
  "${REPO_ROOT}" > "${H9}/.claude/oh-my-claude.conf"
HOME="${H9}" bash "${SWITCH_TIER}" quality --force-reconstruct >/dev/null 2>&1 || true

if [[ "$(model_of "${H9}" oracle)" == "opus" ]] \
    && [[ "$(model_of "${H9}" librarian)" == "haiku" ]]; then
  ok "quality setup materializes the old override set"
else
  bad "quality setup did not materialize old pins before clear test"
fi

printf 'repo_path=%s\nmodel_tier=quality\nmodel_overrides=\n' \
  "${REPO_ROOT}" > "${H9}/.claude/oh-my-claude.conf"
out9="$(HOME="${H9}" bash "${SWITCH_TIER}" quality --force-reconstruct 2>&1)" || true

if [[ "$(model_of "${H9}" oracle)" == "inherit" ]]; then
  ok "forced quality refresh removes stale oracle:opus pin"
else
  bad "cleared oracle override lingered as '$(model_of "${H9}" oracle)'"
fi

if [[ "$(model_of "${H9}" librarian)" == "opus" ]]; then
  ok "forced quality refresh removes stale librarian:haiku pin"
else
  bad "cleared librarian override lingered as '$(model_of "${H9}" librarian)'"
fi

if printf '%s' "${out9}" | grep -q 'Done\. 2 agent(s) updated to quality tier\.'; then
  ok "forced quality refresh summary counts final stale-pin removals"
else
  bad "forced quality refresh summary was inaccurate: ${out9}"
fi

# Force uses the embedded shipped rosters, so a moved clone cannot strand a
# user who needs to clear stale materialized pins.
H10="${TMP_ROOT}/h10"
seed_home "${H10}"
printf 'repo_path=%s\nmodel_tier=quality\nmodel_overrides=\n' \
  "${TMP_ROOT}/missing-source" > "${H10}/.claude/oh-my-claude.conf"
cp "${SWITCH_TIER}" "${H10}/.claude/switch-tier.sh"
if HOME="${H10}" bash "${H10}/.claude/switch-tier.sh" quality --force-reconstruct >/dev/null 2>&1 \
    && [[ "$(model_of "${H10}" oracle)" == "inherit" ]] \
    && [[ "$(model_of "${H10}" librarian)" == "opus" ]] \
    && [[ "$(model_of "${H10}" quality-reviewer)" == "inherit" ]]; then
  ok "forced reconstruction succeeds source-less from embedded shipped rosters"
else
  bad "source-less forced reconstruction failed to restore canonical declarations"
fi

# Duplicate keys can survive hand edits or old migrations. The config stack is
# last-valid-row-wins; the switcher must neither read a stale first row nor let
# malformed later text erase the most recent valid authority.
H11="${TMP_ROOT}/h11"
seed_home "${H11}"
printf 'model_tier=economy\nmodel_tier=quality\n' \
  > "${H11}/.claude/oh-my-claude.conf"
out11="$(HOME="${H11}" bash "${SWITCH_TIER}" 2>&1)"
if printf '%s' "${out11}" | grep -q 'Saved/materialized model tier: quality'; then
  ok "switch-tier config reads use last-valid-occurrence semantics"
else
  bad "switch-tier read stale first duplicate tier: ${out11}"
fi

H11B="${TMP_ROOT}/h11b"
seed_home "${H11B}"
printf 'model_tier=typo\n' > "${H11B}/.claude/oh-my-claude.conf"
out11b="$(HOME="${H11B}" bash "${SWITCH_TIER}" 2>&1)"
if printf '%s' "${out11b}" \
    | grep -q 'Saved/materialized model tier: balanced (invalid saved value .* ignored)'; then
  ok "switch-tier display normalizes an invalid saved tier to balanced"
else
  bad "switch-tier display leaked an invalid effective tier: ${out11b}"
fi

H11C="${TMP_ROOT}/h11c"
seed_home "${H11C}"
printf 'model_tier= economy \nmodel_tier=qualtiy\n' \
  > "${H11C}/.claude/oh-my-claude.conf"
out11c="$(HOME="${H11C}" bash "${SWITCH_TIER}" 2>&1)"
if printf '%s' "${out11c}" | grep -q 'Saved/materialized model tier: economy'; then
  ok "switch-tier retains a trimmed last-valid tier across malformed duplicates"
else
  bad "switch-tier let a malformed later tier erase valid economy: ${out11c}"
fi

out11d="$(OMC_MODEL_TIER=quality HOME="${H11C}" \
  bash "${SWITCH_TIER}" 2>&1)"
if [[ "${out11d}" == *"Saved/materialized model tier: economy"* \
    && "${out11d}" == *"Active runtime environment override: quality"* ]]; then
  ok "switch-tier distinguishes persistent materialization from live env routing"
else
  bad "switch-tier conflated saved and environment model tiers: ${out11d}"
fi

# A manual conf edit happens before the switcher starts, so current_tier can
# already say Quality while the installed files are still Economy. One
# explicit inherit pin must not be mistaken for the full canonical split.
H12="${TMP_ROOT}/h12"
seed_full_home "${H12}"
printf 'repo_path=%s\nmodel_tier=balanced\nmodel_overrides=oracle:inherit\n' \
  "${REPO_ROOT}" > "${H12}/.claude/oh-my-claude.conf"
HOME="${H12}" bash "${H12}/.claude/switch-tier.sh" economy >/dev/null 2>&1 || true
printf 'repo_path=%s\nmodel_tier=quality\nmodel_overrides=oracle:inherit\n' \
  "${REPO_ROOT}" > "${H12}/.claude/oh-my-claude.conf"
HOME="${H12}" bash "${H12}/.claude/switch-tier.sh" quality >/dev/null 2>&1 || true
if [[ "$(count_model "${H12}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H12}" opus)" == "23" ]] \
    && [[ "$(model_of "${H12}" quality-reviewer)" == "inherit" ]]; then
  ok "manual economy->quality edit cannot hide behind one inherit override"
else
  bad "manual economy->quality failed to restore 14 inherit / 23 opus"
fi

# A genuinely intact Balanced split is sufficient evidence for a direct
# source-less lift: only shipped Sonnet declarations change to Opus.
H13="${TMP_ROOT}/h13"
seed_full_home "${H13}"
printf 'repo_path=%s\nmodel_tier=balanced\n' \
  "${TMP_ROOT}/missing-source" > "${H13}/.claude/oh-my-claude.conf"
if HOME="${H13}" bash "${H13}/.claude/switch-tier.sh" quality >/dev/null 2>&1 \
    && [[ "$(count_model "${H13}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H13}" opus)" == "23" ]]; then
  ok "sound balanced->quality remains convenient without the source repo"
else
  bad "sound source-less balanced->quality was rejected or mis-materialized"
fi

# Full-set validation also catches a stale fixed-role pin after a user removes
# it manually from conf. The inherit roster alone still looks perfect here.
H14="${TMP_ROOT}/h14"
seed_full_home "${H14}"
printf 'repo_path=%s\nmodel_tier=quality\nmodel_overrides=librarian:haiku\n' \
  "${REPO_ROOT}" > "${H14}/.claude/oh-my-claude.conf"
HOME="${H14}" bash "${H14}/.claude/switch-tier.sh" quality \
  --force-reconstruct >/dev/null 2>&1 || true
printf 'repo_path=%s\nmodel_tier=quality\nmodel_overrides=\n' \
  "${REPO_ROOT}" > "${H14}/.claude/oh-my-claude.conf"
HOME="${H14}" bash "${H14}/.claude/switch-tier.sh" quality >/dev/null 2>&1 || true
if [[ "$(model_of "${H14}" librarian)" == "opus" ]] \
    && [[ "$(count_model "${H14}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H14}" opus)" == "23" ]]; then
  ok "plain quality refresh removes a manually cleared fixed-role pin"
else
  bad "full declaration proof missed stale librarian:haiku"
fi

# Economy's installed composition is deliberately the same inherited/Sonnet
# split as Balanced. This makes a medium/high-risk runtime `inherit` result
# composable with Agent-model omission instead of falling back to a flattened
# Sonnet definition.
H14B="${TMP_ROOT}/h14b"
seed_full_home "${H14B}"
printf 'model_tier=balanced\n' > "${H14B}/.claude/oh-my-claude.conf"
HOME="${H14B}" bash "${H14B}/.claude/switch-tier.sh" quality >/dev/null 2>&1
HOME="${H14B}" bash "${H14B}/.claude/switch-tier.sh" economy >/dev/null 2>&1
if [[ "$(count_model "${H14B}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H14B}" sonnet)" == "23" ]] \
    && [[ "$(model_of "${H14B}" quality-reviewer)" == "inherit" ]]; then
  ok "quality->economy restores the composable 14 inherit / 23 Sonnet split"
else
  bad "quality->economy flattened the inherited declaration class"
fi

H14C="${TMP_ROOT}/h14c"
seed_full_home "${H14C}"
printf 'model_tier=balanced\n' > "${H14C}/.claude/oh-my-claude.conf"
HOME="${H14C}" bash "${H14C}/.claude/switch-tier.sh" economy >/dev/null 2>&1
if [[ "$(count_model "${H14C}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H14C}" sonnet)" == "23" ]]; then
  ok "balanced->economy preserves the composable declaration split"
else
  bad "balanced->economy changed the declaration classes"
fi

# A legacy Economy install may have flattened the inherited class to Sonnet.
# Reapplying Economy must repair every stale shipped declaration without the
# source repo before live routing claims inherited deliberation.
H14D="${TMP_ROOT}/h14d"
seed_full_home "${H14D}"
for stale_agent in ${switch_inherit_roster:-abstraction-critic chief-of-staff divergent-framer draft-writer editor-critic excellence-reviewer metis oracle prometheus quality-planner quality-reviewer release-reviewer rigor-reviewer writing-architect}; do
  sed 's/^model: inherit$/model: sonnet/' \
    "${H14D}/.claude/agents/${stale_agent}.md" \
    > "${H14D}/.claude/agents/${stale_agent}.md.tmp"
  mv "${H14D}/.claude/agents/${stale_agent}.md.tmp" \
    "${H14D}/.claude/agents/${stale_agent}.md"
done
printf 'repo_path=%s\nmodel_tier=economy\n' "${TMP_ROOT}/missing-source" \
  > "${H14D}/.claude/oh-my-claude.conf"
out14d="$(HOME="${H14D}" bash "${H14D}/.claude/switch-tier.sh" economy 2>&1)"
if [[ "$(count_model "${H14D}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H14D}" sonnet)" == "23" ]] \
    && printf '%s' "${out14d}" | grep -q 'Done\. 14 agent(s) updated'; then
  ok "economy reapply repairs a source-less legacy flattened install"
else
  bad "economy reapply did not repair all stale inherited declarations: ${out14d}"
fi

# Integrity failures are detected before any rewrite or tier persistence.
H14E="${TMP_ROOT}/h14e"
seed_full_home "${H14E}"
printf 'model_tier=quality\n' > "${H14E}/.claude/oh-my-claude.conf"
rm "${H14E}/.claude/agents/librarian.md"
out14e="$(HOME="${H14E}" bash "${H14E}/.claude/switch-tier.sh" economy 2>&1)"
rc14e=$?
if [[ "${rc14e}" -ne 0 ]] \
    && grep -q '^model_tier=quality$' "${H14E}/.claude/oh-my-claude.conf" \
    && [[ "${out14e}" == *"missing shipped agent definition"* ]] \
    && [[ "${out14e}" != *"Done."* ]]; then
  ok "missing shipped file aborts without persisting a false tier"
else
  bad "missing shipped file did not fail closed: rc=${rc14e} output=${out14e}"
fi

H14F="${TMP_ROOT}/h14f"
seed_full_home "${H14F}"
printf 'model_tier=quality\n' > "${H14F}/.claude/oh-my-claude.conf"
sed '/^model: /d' "${H14F}/.claude/agents/quality-reviewer.md" \
  > "${H14F}/.claude/agents/quality-reviewer.md.tmp"
mv "${H14F}/.claude/agents/quality-reviewer.md.tmp" \
  "${H14F}/.claude/agents/quality-reviewer.md"
out14f="$(HOME="${H14F}" bash "${H14F}/.claude/switch-tier.sh" economy 2>&1)"
rc14f=$?
if [[ "${rc14f}" -ne 0 ]] \
    && grep -q '^model_tier=quality$' "${H14F}/.claude/oh-my-claude.conf" \
    && [[ "${out14f}" == *"malformed shipped agent model frontmatter"* ]] \
    && [[ "${out14f}" != *"Done."* ]]; then
  ok "malformed shipped frontmatter aborts without persisting a false tier"
else
  bad "malformed shipped frontmatter did not fail closed: rc=${rc14f} output=${out14f}"
fi

# --no-ios removes the whole optional pack. The integrity proof distinguishes
# that supported shape from a partial/corrupt pack.
H14G="${TMP_ROOT}/h14g"
seed_full_home "${H14G}"
rm "${H14G}/.claude/agents/ios-"*.md
printf 'model_tier=balanced\n' > "${H14G}/.claude/oh-my-claude.conf"
if HOME="${H14G}" bash "${H14G}/.claude/switch-tier.sh" economy >/dev/null 2>&1 \
    && [[ "$(count_model "${H14G}" inherit)" == "14" ]] \
    && [[ "$(count_model "${H14G}" sonnet)" == "19" ]]; then
  ok "complete --no-ios roster remains a valid tier-switch target"
else
  bad "tier integrity check rejected the supported --no-ios shape"
fi

# Installer source integrity is proved before any destination mutation. A
# missing source file must not be masked by a same-named stale installed file,
# malformed iOS source remains fatal even when --no-ios was requested, and an
# unclassified new bundled definition cannot bypass tier reconstruction.
INSTALL_FIXTURE="${TMP_ROOT}/install-source-fixture"
INSTALL_FIXTURE_HOME="${TMP_ROOT}/install-source-home"
mkdir -p "${INSTALL_FIXTURE}/bundle/dot-claude" \
  "${INSTALL_FIXTURE}/config" \
  "${INSTALL_FIXTURE_HOME}/.claude/agents"
cp "${INSTALL_SH}" "${INSTALL_FIXTURE}/install.sh"
cp "${REPO_ROOT}/bundle/dot-claude/statusline.py" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/statusline.py"
cp -R "${REPO_ROOT}/bundle/dot-claude/agents" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/agents"
mkdir -p "${INSTALL_FIXTURE}/bundle/dot-claude/quality-pack" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/skills/autowork"
cp -R "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/quality-pack/scripts"
cp -R "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/skills/autowork/scripts"
cp "${REPO_ROOT}/config/settings.patch.json" \
  "${INSTALL_FIXTURE}/config/settings.patch.json"
printf 'installed sentinel\n' \
  > "${INSTALL_FIXTURE_HOME}/.claude/agents/librarian.md"
printf 'destination must remain byte-identical\n' \
  > "${INSTALL_FIXTURE_HOME}/.claude/destination-sentinel"
install_sentinel_before="$(cksum \
  "${INSTALL_FIXTURE_HOME}/.claude/destination-sentinel" \
  "${INSTALL_FIXTURE_HOME}/.claude/agents/librarian.md")"

rm "${INSTALL_FIXTURE}/bundle/dot-claude/agents/librarian.md"
out14h="$(TARGET_HOME="${INSTALL_FIXTURE_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" 2>&1)"
rc14h=$?
install_sentinel_after="$(cksum \
  "${INSTALL_FIXTURE_HOME}/.claude/destination-sentinel" \
  "${INSTALL_FIXTURE_HOME}/.claude/agents/librarian.md")"
if [[ "${rc14h}" -ne 0 ]] \
    && [[ "${out14h}" == *"Missing bundled shipped agent definition"* ]] \
    && [[ "${out14h}" == *"installed files were not changed"* ]] \
    && [[ "${install_sentinel_after}" == "${install_sentinel_before}" ]] \
    && [[ ! -e "${INSTALL_FIXTURE_HOME}/.claude/backups" ]] \
    && [[ ! -e "${INSTALL_FIXTURE_HOME}/.claude/.install.lock" ]]; then
  ok "missing source agent cannot hide behind a stale installed orphan or mutate the destination"
else
  bad "missing source agent did not fail before destination mutation: rc=${rc14h} output=${out14h}"
fi

cp "${REPO_ROOT}/bundle/dot-claude/agents/librarian.md" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/agents/librarian.md"
sed '/^model: /d' \
  "${INSTALL_FIXTURE}/bundle/dot-claude/agents/ios-ui-developer.md" \
  > "${INSTALL_FIXTURE}/bundle/dot-claude/agents/ios-ui-developer.md.tmp"
mv "${INSTALL_FIXTURE}/bundle/dot-claude/agents/ios-ui-developer.md.tmp" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/agents/ios-ui-developer.md"
FRESH_NO_IOS_HOME="${TMP_ROOT}/fresh-no-ios-source-home"
out14i="$(TARGET_HOME="${FRESH_NO_IOS_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" --no-ios 2>&1)"
rc14i=$?
if [[ "${rc14i}" -ne 0 ]] \
    && [[ "${out14i}" == *"Malformed bundled agent model frontmatter"* ]] \
    && [[ ! -e "${FRESH_NO_IOS_HOME}/.claude" ]]; then
  ok "--no-ios still requires a coherent complete source release before creating the destination"
else
  bad "--no-ios allowed malformed optional source or created destination state: rc=${rc14i} output=${out14i}"
fi

cp "${REPO_ROOT}/bundle/dot-claude/agents/ios-ui-developer.md" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/agents/ios-ui-developer.md"
printf -- '---\nname: unclassified-agent\nmodel: sonnet\n---\nbody\n' \
  > "${INSTALL_FIXTURE}/bundle/dot-claude/agents/unclassified-agent.md"
out14j="$(TARGET_HOME="${FRESH_NO_IOS_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" 2>&1)"
rc14j=$?
if [[ "${rc14j}" -ne 0 ]] \
    && [[ "${out14j}" == *"Unexpected bundled agent definition outside the shipped roster"* ]] \
    && [[ ! -e "${FRESH_NO_IOS_HOME}/.claude" ]]; then
  ok "unclassified bundled agents fail closed before escaping model-tier policy"
else
  bad "unclassified bundled agent bypassed source-roster preflight: rc=${rc14j} output=${out14j}"
fi

# The post-copy proof remains a separate defense against I/O races. Inject a
# one-shot destination fault after the bundle rsync, then prove the installer
# restores the exact pre-install shipped shape instead of leaving a demoted or
# partial roster. The user's unrelated destination sentinel stays untouched.
rm "${INSTALL_FIXTURE}/bundle/dot-claude/agents/unclassified-agent.md"

printf '%s\n' '{"hooks":42}' \
  > "${INSTALL_FIXTURE}/config/settings.patch.json"
MALFORMED_PATCH_HOME="${TMP_ROOT}/malformed-settings-patch-home"
out14patch="$(TARGET_HOME="${MALFORMED_PATCH_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" 2>&1)"
rc14patch=$?
if [[ "${rc14patch}" -ne 0 ]] \
    && [[ "${out14patch}" == *"Malformed settings patch"* ]] \
    && [[ "${out14patch}" == *"installed files were not changed"* ]] \
    && [[ ! -e "${MALFORMED_PATCH_HOME}/.claude" ]]; then
  ok "malformed settings ownership authority fails before destination mutation"
else
  bad "malformed settings patch did not fail atomically: rc=${rc14patch} output=${out14patch}"
fi
cp "${REPO_ROOT}/config/settings.patch.json" \
  "${INSTALL_FIXTURE}/config/settings.patch.json"

missing_hook_path="${INSTALL_FIXTURE}/bundle/dot-claude/skills/autowork/scripts/dispatch-recovery-guard.sh"
missing_hook_backup="${TMP_ROOT}/dispatch-recovery-guard.sh"
cp "${missing_hook_path}" "${missing_hook_backup}"
rm "${missing_hook_path}"
MISSING_HOOK_HOME="${TMP_ROOT}/missing-settings-hook-home"
out14hook="$(TARGET_HOME="${MISSING_HOOK_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" 2>&1)"
rc14hook=$?
if [[ "${rc14hook}" -ne 0 ]] \
    && [[ "${out14hook}" == *"missing or non-regular bundled hook"* ]] \
    && [[ "${out14hook}" == *"installed files were not changed"* ]] \
    && [[ ! -e "${MISSING_HOOK_HOME}/.claude" ]]; then
  ok "dangling settings hook authority fails before destination mutation"
else
  bad "missing settings hook did not fail atomically: rc=${rc14hook} output=${out14hook}"
fi
mv "${missing_hook_backup}" "${missing_hook_path}"

FAULT_BIN="${TMP_ROOT}/fault-bin"
mkdir -p "${FAULT_BIN}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '"${OMC_REAL_RSYNC}" "$@"' \
  'last_arg="${@: -1}"' \
  'if [[ "${last_arg}" == "${OMC_FAULT_TARGET_HOME}/.claude/" ]]; then' \
  '  rm -f "${OMC_FAULT_TARGET_HOME}/.claude/agents/quality-reviewer.md"' \
  'fi' \
  > "${FAULT_BIN}/rsync"
chmod +x "${FAULT_BIN}/rsync"
REAL_RSYNC_PATH="$(command -v rsync)"
out14k="$(PATH="${FAULT_BIN}:${PATH}" \
  OMC_REAL_RSYNC="${REAL_RSYNC_PATH}" \
  OMC_FAULT_TARGET_HOME="${INSTALL_FIXTURE_HOME}" \
  TARGET_HOME="${INSTALL_FIXTURE_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" 2>&1)"
rc14k=$?
post_rollback_agent_count="$(find \
  "${INSTALL_FIXTURE_HOME}/.claude/agents" -maxdepth 1 -type f -name '*.md' \
  | wc -l | tr -d '[:space:]')"
install_sentinel_after_rollback="$(cksum \
  "${INSTALL_FIXTURE_HOME}/.claude/destination-sentinel" \
  "${INSTALL_FIXTURE_HOME}/.claude/agents/librarian.md")"
if [[ "${rc14k}" -ne 0 ]] \
    && [[ "${out14k}" == *"restoring the prior shipped agent roster"* ]] \
    && [[ "${install_sentinel_after_rollback}" == "${install_sentinel_before}" ]] \
    && [[ "${post_rollback_agent_count}" == "1" ]] \
    && [[ ! -e "${INSTALL_FIXTURE_HOME}/.claude/agents/quality-reviewer.md" ]] \
    && [[ ! -e "${INSTALL_FIXTURE_HOME}/.claude/.install.lock" ]]; then
  ok "post-copy roster failure rolls shipped agents back to the exact prior shape"
else
  bad "post-copy roster failure left a partial destination: rc=${rc14k} agents=${post_rollback_agent_count} output=${out14k}"
fi

# Keep rollback armed after the post-copy proof: tier reconstruction,
# overrides, and provenance config writes are one transaction. Interrupt the
# installed_version config replacement (after quality + librarian override
# materialization) and require the exact prior roster/config bytes back. The
# custom definition is deliberately in the same directory to prove rollback
# ownership remains restricted to shipped identities.
seed_model_transaction_fixture() {
  local fixture_home="$1"
  mkdir -p "${fixture_home}/.claude/agents"
  printf -- '---\nname: librarian\nmodel: sonnet\n---\nprior librarian body\n' \
    > "${fixture_home}/.claude/agents/librarian.md"
  printf -- '---\nname: quality-reviewer\nmodel: haiku\n---\nprior reviewer body\n' \
    > "${fixture_home}/.claude/agents/quality-reviewer.md"
  printf -- '---\nname: custom-agent\nmodel: haiku\n---\ncustom body\n' \
    > "${fixture_home}/.claude/agents/custom-agent.md"
  printf 'model_tier=economy\nmodel_overrides=librarian:haiku\ncustom_setting=keep\n' \
    > "${fixture_home}/.claude/oh-my-claude.conf"
}

LATE_FAILURE_HOME="${TMP_ROOT}/late-model-config-home"
LATE_FAULT_BIN="${TMP_ROOT}/late-model-config-bin"
seed_model_transaction_fixture "${LATE_FAILURE_HOME}"
mkdir -p "${LATE_FAULT_BIN}"
late_roster_before="$(cksum \
  "${LATE_FAILURE_HOME}/.claude/agents/librarian.md" \
  "${LATE_FAILURE_HOME}/.claude/agents/quality-reviewer.md" \
  "${LATE_FAILURE_HOME}/.claude/agents/custom-agent.md")"
late_conf_before="$(cksum \
  "${LATE_FAILURE_HOME}/.claude/oh-my-claude.conf")"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$#" -eq 2 && "$2" == "${OMC_TXN_CONF}" && -f "$1" ]] \
      && grep -q "^repo_path=" "$1"; then' \
  '  kill -TERM "$PPID"' \
  '  exit 143' \
  'fi' \
  'exec "${OMC_REAL_MV}" "$@"' \
  > "${LATE_FAULT_BIN}/mv"
chmod +x "${LATE_FAULT_BIN}/mv"
REAL_MV_PATH="$(command -v mv)"
out14l="$(PATH="${LATE_FAULT_BIN}:${PATH}" \
  OMC_REAL_MV="${REAL_MV_PATH}" \
  OMC_TXN_CONF="${LATE_FAILURE_HOME}/.claude/oh-my-claude.conf" \
  TARGET_HOME="${LATE_FAILURE_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" --model-tier=quality 2>&1)"
rc14l=$?
late_roster_after="$(cksum \
  "${LATE_FAILURE_HOME}/.claude/agents/librarian.md" \
  "${LATE_FAILURE_HOME}/.claude/agents/quality-reviewer.md" \
  "${LATE_FAILURE_HOME}/.claude/agents/custom-agent.md")"
late_conf_after="$(cksum \
  "${LATE_FAILURE_HOME}/.claude/oh-my-claude.conf")"
late_agent_count="$(find "${LATE_FAILURE_HOME}/.claude/agents" \
  -maxdepth 1 -type f -name '*.md' | wc -l | tr -d '[:space:]')"
late_backup_dir="$(find "${LATE_FAILURE_HOME}/.claude/backups" \
  -mindepth 1 -maxdepth 1 -type d -name 'oh-my-claude-*' \
  | LC_ALL=C sort | tail -1)"
if [[ "${rc14l}" -ne 0 ]] \
    && [[ "${out14l}" == *"Model overrides: 1 materialized"* ]] \
    && [[ "${out14l}" == *"Model/config install transaction failed"* ]] \
    && [[ "${out14l}" == *"Model/config rollback complete"* ]] \
    && [[ "${late_roster_after}" == "${late_roster_before}" ]] \
    && [[ "${late_conf_after}" == "${late_conf_before}" ]] \
    && [[ "${late_agent_count}" == "3" ]] \
    && [[ -n "${late_backup_dir}" ]] \
    && cmp -s "${late_backup_dir}/oh-my-claude.conf" \
      "${LATE_FAILURE_HOME}/.claude/oh-my-claude.conf" \
    && [[ ! -e "${LATE_FAILURE_HOME}/.claude/.install.lock" ]] \
    && [[ ! -e "${LATE_FAILURE_HOME}/.claude/oh-my-claude.conf.tmp" ]]; then
  ok "late model/config interrupt restores the exact prior shipped roster and config"
else
  bad "late model/config interrupt escaped transactional rollback: rc=${rc14l} agents=${late_agent_count} output=${out14l}"
fi

# A successful writer can still produce structurally invalid frontmatter
# (short/corrupt filesystem or tool output). Corrupt only atlas's name while
# leaving its requested Opus model valid, so the checked writer succeeds and
# the post-materialization verification is what must reject and roll back it.
# Use an independent destination so this contract cannot borrow state from the
# signal test above. A fixed-date collision below proves the installer allocates
# a new backup rather than trusting a stale same-second rsync quick check.
VERIFY_FAILURE_HOME="${TMP_ROOT}/post-model-verify-home"
VERIFY_FAULT_BIN="${TMP_ROOT}/post-model-verify-bin"
seed_model_transaction_fixture "${VERIFY_FAILURE_HOME}"
mkdir -p "${VERIFY_FAULT_BIN}"
verify_roster_before="$(cksum \
  "${VERIFY_FAILURE_HOME}/.claude/agents/librarian.md" \
  "${VERIFY_FAILURE_HOME}/.claude/agents/quality-reviewer.md" \
  "${VERIFY_FAILURE_HOME}/.claude/agents/custom-agent.md")"
verify_conf_before="$(cksum \
  "${VERIFY_FAILURE_HOME}/.claude/oh-my-claude.conf")"
verify_conf_text_before="$(cat \
  "${VERIFY_FAILURE_HOME}/.claude/oh-my-claude.conf")"
VERIFY_FIXED_STAMP="20990101-010101"
VERIFY_COLLISION_BACKUP="${VERIFY_FAILURE_HOME}/.claude/backups/oh-my-claude-${VERIFY_FIXED_STAMP}"
mkdir -p "${VERIFY_COLLISION_BACKUP}"
printf 'model_overrides=librarian:haiku\ncustom_setting=keep\nmodel_tier=quality\n' \
  > "${VERIFY_COLLISION_BACKUP}/oh-my-claude.conf"
# Equal size + mtime makes direct `rsync -a source existing-target` skip the
# differing bytes on macOS openrsync. A unique invocation directory must make
# the stale file irrelevant.
touch -r "${VERIFY_FAILURE_HOME}/.claude/oh-my-claude.conf" \
  "${VERIFY_COLLISION_BACKUP}/oh-my-claude.conf"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'last_arg="${@: -1}"' \
  'if [[ "${last_arg}" == "${OMC_VERIFY_AGENT}" \
      && "$1" == "s/^model: .*$/model: opus/" ]]; then' \
  '  "${OMC_REAL_SED}" "$@" | "${OMC_REAL_SED}" "s/^name: atlas$/name: corrupt-atlas/"' \
  '  exit 0' \
  'fi' \
  'exec "${OMC_REAL_SED}" "$@"' \
  > "${VERIFY_FAULT_BIN}/sed"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "+%Y%m%d-%H%M%S" ]]; then' \
  '  printf "20990101-010101\\n"' \
  '  exit 0' \
  'fi' \
  'exec "${OMC_REAL_DATE}" "$@"' \
  > "${VERIFY_FAULT_BIN}/date"
chmod +x "${VERIFY_FAULT_BIN}/sed" "${VERIFY_FAULT_BIN}/date"
REAL_SED_PATH="$(command -v sed)"
REAL_DATE_PATH="$(command -v date)"
out14m="$(PATH="${VERIFY_FAULT_BIN}:${PATH}" \
  OMC_REAL_SED="${REAL_SED_PATH}" \
  OMC_REAL_DATE="${REAL_DATE_PATH}" \
  OMC_VERIFY_AGENT="${VERIFY_FAILURE_HOME}/.claude/agents/atlas.md" \
  TARGET_HOME="${VERIFY_FAILURE_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" --model-tier=quality 2>&1)"
rc14m=$?
verify_roster_after="$(cksum \
  "${VERIFY_FAILURE_HOME}/.claude/agents/librarian.md" \
  "${VERIFY_FAILURE_HOME}/.claude/agents/quality-reviewer.md" \
  "${VERIFY_FAILURE_HOME}/.claude/agents/custom-agent.md")"
verify_conf_after="$(cksum \
  "${VERIFY_FAILURE_HOME}/.claude/oh-my-claude.conf")"
verify_conf_text_after="$(cat \
  "${VERIFY_FAILURE_HOME}/.claude/oh-my-claude.conf")"
verify_agent_count="$(find "${VERIFY_FAILURE_HOME}/.claude/agents" \
  -maxdepth 1 -type f -name '*.md' | wc -l | tr -d '[:space:]')"
verify_backup_conf_path="${VERIFY_FAILURE_HOME}/.claude/backups/oh-my-claude-${VERIFY_FIXED_STAMP}-0001/oh-my-claude.conf"
verify_backup_conf_text=""
if [[ -f "${verify_backup_conf_path}" ]]; then
  verify_backup_conf_text="$(cat "${verify_backup_conf_path}")"
fi
verify_backup_count="$(find "${VERIFY_FAILURE_HOME}/.claude/backups" \
  -mindepth 1 -maxdepth 1 -type d -name 'oh-my-claude-*' \
  | wc -l | tr -d '[:space:]')"
if [[ "${rc14m}" -ne 0 ]] \
    && [[ "${out14m}" == *"Malformed installed shipped agent name frontmatter"* ]] \
    && [[ "${out14m}" == *"Model setup verification failed after tier/override materialization"* ]] \
    && [[ "${out14m}" == *"Model/config rollback complete"* ]] \
    && [[ "${verify_roster_after}" == "${verify_roster_before}" ]] \
    && [[ "${verify_conf_after}" == "${verify_conf_before}" ]] \
    && [[ "${verify_agent_count}" == "3" ]] \
    && [[ "${verify_backup_count}" == "2" ]] \
    && [[ "${verify_backup_conf_path}" == *"oh-my-claude-${VERIFY_FIXED_STAMP}-0001/oh-my-claude.conf" ]] \
    && [[ "${verify_backup_conf_text}" == "${verify_conf_text_before}" ]] \
    && [[ ! -e "${VERIFY_FAILURE_HOME}/.claude/agents/atlas.md" ]] \
    && [[ ! -e "${VERIFY_FAILURE_HOME}/.claude/.install.lock" ]]; then
  ok "post-materialization verification failure restores the exact prior model/config state"
else
  bad "post-materialization verification failure escaped rollback: rc=${rc14m} agents=${verify_agent_count} conf-before=$(printf '%q' "${verify_conf_text_before}") conf-after=$(printf '%q' "${verify_conf_text_after}") backup-conf=$(printf '%q' "${verify_backup_conf_text}") output=${out14m}"
fi

# A target that changes from a file into a directory during installation must
# never make `mv restore target` report a false-success by nesting the restore
# file inside that directory. Preserve the directory for diagnosis, restore
# every unaffected transaction-owned path, and report rollback incomplete.
DIR_RACE_HOME="${TMP_ROOT}/model-rollback-dir-race-home"
DIR_RACE_BIN="${TMP_ROOT}/model-rollback-dir-race-bin"
seed_model_transaction_fixture "${DIR_RACE_HOME}"
mkdir -p "${DIR_RACE_BIN}"
dir_race_survivors_before="$(cksum \
  "${DIR_RACE_HOME}/.claude/agents/librarian.md" \
  "${DIR_RACE_HOME}/.claude/agents/custom-agent.md")"
dir_race_conf_before="$(cksum \
  "${DIR_RACE_HOME}/.claude/oh-my-claude.conf")"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'last_arg="${@: -1}"' \
  'if [[ "${last_arg}" == "${OMC_DIR_RACE_AGENT}" \
      && "$1" == "s/^model: .*$/model: opus/" ]]; then' \
  '  rm -f "${OMC_DIR_RACE_TARGET}"' \
  '  mkdir -p "${OMC_DIR_RACE_TARGET}"' \
  '  "${OMC_REAL_SED}" "$@" | "${OMC_REAL_SED}" "s/^name: atlas$/name: corrupt-atlas/"' \
  '  exit 0' \
  'fi' \
  'exec "${OMC_REAL_SED}" "$@"' \
  > "${DIR_RACE_BIN}/sed"
chmod +x "${DIR_RACE_BIN}/sed"
out14n="$(PATH="${DIR_RACE_BIN}:${PATH}" \
  OMC_REAL_SED="${REAL_SED_PATH}" \
  OMC_DIR_RACE_AGENT="${DIR_RACE_HOME}/.claude/agents/atlas.md" \
  OMC_DIR_RACE_TARGET="${DIR_RACE_HOME}/.claude/agents/quality-reviewer.md" \
  TARGET_HOME="${DIR_RACE_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" --model-tier=quality 2>&1)"
rc14n=$?
dir_race_survivors_after="$(cksum \
  "${DIR_RACE_HOME}/.claude/agents/librarian.md" \
  "${DIR_RACE_HOME}/.claude/agents/custom-agent.md")"
dir_race_conf_after="$(cksum \
  "${DIR_RACE_HOME}/.claude/oh-my-claude.conf")"
dir_race_nested_count="$(find \
  "${DIR_RACE_HOME}/.claude/agents/quality-reviewer.md" \
  -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${rc14n}" -ne 0 ]] \
    && [[ "${out14n}" == *"Model/config rollback was incomplete"* ]] \
    && [[ "${dir_race_survivors_after}" == "${dir_race_survivors_before}" ]] \
    && [[ "${dir_race_conf_after}" == "${dir_race_conf_before}" ]] \
    && [[ -d "${DIR_RACE_HOME}/.claude/agents/quality-reviewer.md" ]] \
    && [[ ! -L "${DIR_RACE_HOME}/.claude/agents/quality-reviewer.md" ]] \
    && [[ "${dir_race_nested_count}" == "0" ]] \
    && [[ ! -e "${DIR_RACE_HOME}/.claude/.install.lock" ]]; then
  ok "rollback rejects a directory race without nesting or deleting the unexpected directory"
else
  bad "rollback directory-race defense failed: rc=${rc14n} nested=${dir_race_nested_count} output=${out14n}"
fi

# BSD/macOS mv follows a destination symlink-to-directory. Replacing a shipped
# file that becomes such a link must unlink the link itself, restore the file,
# and leave the link referent untouched.
SYMLINK_RACE_HOME="${TMP_ROOT}/model-rollback-symlink-race-home"
SYMLINK_RACE_BIN="${TMP_ROOT}/model-rollback-symlink-race-bin"
SYMLINK_RACE_REFERENT="${TMP_ROOT}/model-rollback-symlink-referent"
seed_model_transaction_fixture "${SYMLINK_RACE_HOME}"
mkdir -p "${SYMLINK_RACE_BIN}" "${SYMLINK_RACE_REFERENT}"
symlink_race_roster_before="$(cksum \
  "${SYMLINK_RACE_HOME}/.claude/agents/librarian.md" \
  "${SYMLINK_RACE_HOME}/.claude/agents/quality-reviewer.md" \
  "${SYMLINK_RACE_HOME}/.claude/agents/custom-agent.md")"
symlink_race_conf_before="$(cksum \
  "${SYMLINK_RACE_HOME}/.claude/oh-my-claude.conf")"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'last_arg="${@: -1}"' \
  'if [[ "${last_arg}" == "${OMC_SYMLINK_RACE_AGENT}" \
      && "$1" == "s/^model: .*$/model: opus/" ]]; then' \
  '  rm -f "${OMC_SYMLINK_RACE_TARGET}"' \
  '  ln -s "${OMC_SYMLINK_RACE_REFERENT}" "${OMC_SYMLINK_RACE_TARGET}"' \
  '  "${OMC_REAL_SED}" "$@" | "${OMC_REAL_SED}" "s/^name: atlas$/name: corrupt-atlas/"' \
  '  exit 0' \
  'fi' \
  'exec "${OMC_REAL_SED}" "$@"' \
  > "${SYMLINK_RACE_BIN}/sed"
chmod +x "${SYMLINK_RACE_BIN}/sed"
out14o="$(PATH="${SYMLINK_RACE_BIN}:${PATH}" \
  OMC_REAL_SED="${REAL_SED_PATH}" \
  OMC_SYMLINK_RACE_AGENT="${SYMLINK_RACE_HOME}/.claude/agents/atlas.md" \
  OMC_SYMLINK_RACE_TARGET="${SYMLINK_RACE_HOME}/.claude/agents/quality-reviewer.md" \
  OMC_SYMLINK_RACE_REFERENT="${SYMLINK_RACE_REFERENT}" \
  TARGET_HOME="${SYMLINK_RACE_HOME}" \
  bash "${INSTALL_FIXTURE}/install.sh" --model-tier=quality 2>&1)"
rc14o=$?
symlink_race_roster_after="$(cksum \
  "${SYMLINK_RACE_HOME}/.claude/agents/librarian.md" \
  "${SYMLINK_RACE_HOME}/.claude/agents/quality-reviewer.md" \
  "${SYMLINK_RACE_HOME}/.claude/agents/custom-agent.md")"
symlink_race_conf_after="$(cksum \
  "${SYMLINK_RACE_HOME}/.claude/oh-my-claude.conf")"
symlink_race_referent_count="$(find "${SYMLINK_RACE_REFERENT}" \
  -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')"
if [[ "${rc14o}" -ne 0 ]] \
    && [[ "${out14o}" == *"Model/config rollback complete"* ]] \
    && [[ "${symlink_race_roster_after}" == "${symlink_race_roster_before}" ]] \
    && [[ "${symlink_race_conf_after}" == "${symlink_race_conf_before}" ]] \
    && [[ -f "${SYMLINK_RACE_HOME}/.claude/agents/quality-reviewer.md" ]] \
    && [[ ! -L "${SYMLINK_RACE_HOME}/.claude/agents/quality-reviewer.md" ]] \
    && [[ "${symlink_race_referent_count}" == "0" ]] \
    && [[ ! -e "${SYMLINK_RACE_HOME}/.claude/.install.lock" ]]; then
  ok "rollback replaces a symlink-to-directory without mutating its referent"
else
  bad "rollback symlink-directory defense failed: rc=${rc14o} referent=${symlink_race_referent_count} output=${out14o}"
fi

# Tiers and override materialization own only the 37 shipped files. A user's
# custom/plugin definitions stay untouched even when explicitly pinned; named
# models are runtime-only, and custom inherit is definition-backed.
H15="${TMP_ROOT}/h15"
seed_full_home "${H15}"
printf -- '---\nname: custom-inherit\nmodel: inherit\n---\nbody\n' \
  > "${H15}/.claude/agents/custom-inherit.md"
printf -- '---\nname: custom-sonnet\nmodel: sonnet\n---\nbody\n' \
  > "${H15}/.claude/agents/custom-sonnet.md"
printf 'model_tier=balanced\nmodel_overrides=custom-inherit:inherit,custom-sonnet:haiku\n' \
  > "${H15}/.claude/oh-my-claude.conf"
out15="$(HOME="${H15}" bash "${H15}/.claude/switch-tier.sh" economy 2>&1)" || true
HOME="${H15}" bash "${H15}/.claude/switch-tier.sh" quality >/dev/null 2>&1 || true
if [[ "$(model_of "${H15}" custom-inherit)" == "inherit" ]] \
    && [[ "$(model_of "${H15}" custom-sonnet)" == "sonnet" ]]; then
  ok "tier switches and explicit pins preserve custom model declarations"
else
  bad "tier switch or explicit pin mutated a custom agent declaration"
fi
if [[ "${out15}" == *"definition-backed custom-inherit"* ]] \
    && [[ "${out15}" == *"runtime-only custom-sonnet"* ]]; then
  ok "custom inherit and named-model policies are both explicit"
else
  bad "custom override diagnostics are incomplete: ${out15}"
fi
printf 'model_tier=quality\nmodel_overrides=\n' \
  > "${H15}/.claude/oh-my-claude.conf"
HOME="${H15}" bash "${H15}/.claude/switch-tier.sh" balanced >/dev/null 2>&1 || true
if [[ "$(model_of "${H15}" custom-inherit)" == "inherit" ]] \
    && [[ "$(model_of "${H15}" custom-sonnet)" == "sonnet" ]]; then
  ok "clearing custom pins reconstructs shipped files without touching custom files"
else
  bad "clearing overrides mutated a custom agent declaration"
fi

# Hand-edited config remains fail-soft. Custom named-model pins are runtime-only
# regardless of frontmatter shape, so duplicate model keys stay untouched and
# are excluded from the shipped post-apply expectations proof.
H15B="${TMP_ROOT}/h15b"
seed_full_home "${H15B}"
printf -- '---\nname: duplicate-custom\nmodel: sonnet\nmodel: haiku\n---\nbody\n' \
  > "${H15B}/.claude/agents/duplicate-custom.md"
printf 'model_tier=balanced\nmodel_overrides=duplicate-custom:opus\n' \
  > "${H15B}/.claude/oh-my-claude.conf"
out15b="$(HOME="${H15B}" bash "${H15B}/.claude/switch-tier.sh" economy 2>&1)"
if [[ "$(grep -c '^model: ' \
      "${H15B}/.claude/agents/duplicate-custom.md")" == "2" ]] \
    && [[ "${out15b}" == *"runtime-only duplicate-custom"* ]] \
    && grep -q '^model_tier=economy$' \
      "${H15B}/.claude/oh-my-claude.conf"; then
  ok "switcher keeps malformed custom definitions untouched for runtime-only pins"
else
  bad "switcher rewrote or overclaimed a malformed custom override target"
fi

if grep -Fq 'for agent in ${SHIPPED_INHERIT_AGENTS}' "${INSTALL_SH}" \
    && grep -Fq 'for agent in ${SHIPPED_FIXED_AGENTS}' "${INSTALL_SH}"; then
  ok "installer tier rewrite iterates embedded shipped rosters only"
else
  bad "installer tier rewrite is not visibly restricted to shipped rosters"
fi

# ---------------------------------------------------------------------------
# Writer integrity: the standalone switcher shares the installer operation
# lock, preserves modes, and refuses config/managed-agent aliases.
# ---------------------------------------------------------------------------
H16="${TMP_ROOT}/h16-conf-link"
seed_full_home "${H16}"
printf 'model_tier=balanced\n' > "${H16}/conf-target"
ln -s "${H16}/conf-target" "${H16}/.claude/oh-my-claude.conf"
before_oracle="$(model_of "${H16}" oracle)"
if HOME="${H16}" bash "${SWITCH_TIER}" quality >/dev/null 2>&1; then
  bad "switcher accepted a symlinked config leaf"
elif [[ -L "${H16}/.claude/oh-my-claude.conf" \
    && "$(model_of "${H16}" oracle)" == "${before_oracle}" ]] \
    && grep -q '^model_tier=balanced$' "${H16}/conf-target"; then
  ok "switcher rejects config aliases before changing agents"
else
  bad "switcher severed config alias or changed agents before rejection"
fi

H17="${TMP_ROOT}/h17-agent-link"
seed_full_home "${H17}"
cp "${H17}/.claude/agents/oracle.md" "${H17}/oracle-target.md"
rm "${H17}/.claude/agents/oracle.md"
ln -s "${H17}/oracle-target.md" "${H17}/.claude/agents/oracle.md"
oracle_target_before="$(cksum < "${H17}/oracle-target.md")"
if HOME="${H17}" bash "${SWITCH_TIER}" quality >/dev/null 2>&1; then
  bad "switcher accepted a symlinked shipped-agent leaf"
elif [[ -L "${H17}/.claude/agents/oracle.md" \
    && "$(cksum < "${H17}/oracle-target.md")" == "${oracle_target_before}" ]]; then
  ok "switcher refuses managed-agent aliases without severing them"
else
  bad "switcher changed or severed a symlinked managed-agent target"
fi

H18="${TMP_ROOT}/h18-modes"
seed_full_home "${H18}"
printf 'model_tier=balanced\n' > "${H18}/.claude/oh-my-claude.conf"
chmod 640 "${H18}/.claude/oh-my-claude.conf"
chmod 640 "${H18}/.claude/agents/librarian.md"
if HOME="${H18}" bash "${SWITCH_TIER}" quality >/dev/null 2>&1 \
    && [[ "$(file_mode "${H18}/.claude/oh-my-claude.conf")" == "640" ]] \
    && [[ "$(file_mode "${H18}/.claude/agents/librarian.md")" == "640" ]]; then
  ok "switcher preserves existing config and agent modes"
else
  bad "switcher changed config or agent mode bits"
fi

H19="${TMP_ROOT}/h19-lock"
seed_full_home "${H19}"
mkdir "${H19}/.claude/.install.lock"
printf '424242\n' > "${H19}/.claude/.install.lock/pid"
printf 'foreign-token\n' > "${H19}/.claude/.install.lock/token"
before_oracle="$(model_of "${H19}" oracle)"
if HOME="${H19}" OMC_TEST_SWITCH_TIER_LOCK_ATTEMPTS=1 \
    bash "${SWITCH_TIER}" quality >/dev/null 2>&1; then
  bad "switcher ignored the shared operation lock"
elif [[ "$(model_of "${H19}" oracle)" == "${before_oracle}" \
    && "$(cat "${H19}/.claude/.install.lock/token")" == "foreign-token" ]]; then
  ok "switcher fails closed on lock contention without removing foreign ownership"
else
  bad "switcher mutated agents or removed a foreign operation lock"
fi

H19B="${TMP_ROOT}/h19b-nul-borrowed-lock"
seed_full_home "${H19B}"
mkdir "${H19B}/.claude/.install.lock"
printf '424242\0\n' > "${H19B}/.claude/.install.lock/pid"
printf '424242.1.2.3\n' > "${H19B}/.claude/.install.lock/token"
h19b_pid_before="$(cksum < "${H19B}/.claude/.install.lock/pid")"
h19b_token_before="$(cksum < "${H19B}/.claude/.install.lock/token")"
if HOME="${H19B}" OMC_TEST_SWITCH_TIER_LOCK_ATTEMPTS=1 \
    OMC_PARENT_OPERATION_LOCK_PID=424242 \
    OMC_PARENT_OPERATION_LOCK_TOKEN=424242.1.2.3 \
    bash "${H19B}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
  bad "switcher admitted a borrowed lock through a NUL-normalized PID"
elif [[ -d "${H19B}/.claude/.install.lock" \
    && "$(LC_ALL=C wc -c < "${H19B}/.claude/.install.lock/pid" \
      | tr -d '[:space:]')" == "8" \
    && "$(cksum < "${H19B}/.claude/.install.lock/pid")" \
      == "${h19b_pid_before}" \
    && "$(cksum < "${H19B}/.claude/.install.lock/token")" \
      == "${h19b_token_before}" \
    && -z "$(find "${H19B}/.claude/.install.lock" -maxdepth 1 \
      -name 'participant.*' -print -quit)" ]]; then
  ok "switcher rejects NUL-normalized borrowed-lock authority"
else
  bad "switcher changed malformed borrowed-lock ownership metadata"
fi

H19C="${TMP_ROOT}/h19c-nul-release-marker"
seed_full_home "${H19C}"
h19c_lock="${H19C}/.claude/.install.lock"
mkdir "${h19c_lock}"
printf '424242\n' > "${h19c_lock}/pid"
printf '424242.1.2\n' > "${h19c_lock}/token"
h19c_lock_id="$(stat -f '%d:%i' "${h19c_lock}" 2>/dev/null \
  || stat -c '%d:%i' "${h19c_lock}" 2>/dev/null)"
printf 'v1\t%s\t424242\t424242.1.2\0\n' "${h19c_lock_id}" \
  > "${h19c_lock}/owner-released"
chmod 600 "${h19c_lock}/owner-released"
h19c_marker_before="$(cksum < "${h19c_lock}/owner-released")"
if HOME="${H19C}" OMC_TEST_SWITCH_TIER_LOCK_ATTEMPTS=1 \
    bash "${H19C}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
  bad "switcher reaped a released lock through a NUL-normalized marker"
elif [[ -f "${h19c_lock}/pid" && -f "${h19c_lock}/token" \
    && -f "${h19c_lock}/owner-released" \
    && "$(cksum < "${h19c_lock}/owner-released")" \
      == "${h19c_marker_before}" ]]; then
  ok "switcher rejects NUL-normalized release-marker authority"
else
  bad "switcher removed malformed released-lock metadata"
fi

# ---------------------------------------------------------------------------
# Durable tier transaction: rollback, crash recovery, commit retirement,
# schema corruption, and exact final-generation fencing.
# ---------------------------------------------------------------------------
H20="${TMP_ROOT}/h20-graceful-rollback"
seed_full_home "${H20}"
printf 'model_tier=balanced\ncustom_row=keep\n' \
  > "${H20}/.claude/oh-my-claude.conf"
chmod 640 "${H20}/.claude/oh-my-claude.conf"
h20_agents_before="$(agent_tree_digest "${H20}")"
h20_conf_before="$(cksum < "${H20}/.claude/oh-my-claude.conf")"
if HOME="${H20}" OMC_TEST_SWITCH_FAIL_AFTER_CONF=1 \
    bash "${H20}/.claude/switch-tier.sh" quality >/dev/null 2>&1; then
  bad "injected post-conf failure unexpectedly committed"
elif [[ "$(agent_tree_digest "${H20}")" == "${h20_agents_before}" \
    && "$(cksum < "${H20}/.claude/oh-my-claude.conf")" \
      == "${h20_conf_before}" \
    && "$(file_mode "${H20}/.claude/oh-my-claude.conf")" == "640" \
    && ! -e "${H20}/.claude/.switch-tier-transaction" \
    && ! -e "${H20}/.claude/.install.lock" ]]; then
  ok "post-conf failure restores exact agent/config bytes and modes"
else
  bad "post-conf failure left a partial tier generation or transaction"
fi

H21="${TMP_ROOT}/h21-kill-recover"
seed_full_home "${H21}"
printf 'model_tier=balanced\ncustom_row=keep\n' \
  > "${H21}/.claude/oh-my-claude.conf"
h21_agents_before="$(agent_tree_digest "${H21}")"
h21_conf_before="$(cksum < "${H21}/.claude/oh-my-claude.conf")"
h21_ready="${H21}/post-conf.ready"
h21_release="${H21}/post-conf.release"
HOME="${H21}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_POST_CONF_READY_FILE="${h21_ready}" \
  OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${h21_release}" \
  bash "${H21}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h21_pid=$!
if wait_for_file "${h21_ready}"; then
  kill -9 "${h21_pid}" 2>/dev/null || true
  wait "${h21_pid}" 2>/dev/null || true
  if remove_killed_owner_lock "${H21}" "${h21_pid}" \
      && HOME="${H21}" OMC_SWITCH_SKIP_CONF_PERSIST=1 \
        OMC_SWITCH_PARENT_TX_CAPABILITY=poisoned \
        bash "${H21}/.claude/switch-tier.sh" --recover-only \
          >/dev/null 2>&1 \
      && [[ "$(agent_tree_digest "${H21}")" == "${h21_agents_before}" \
        && "$(cksum < "${H21}/.claude/oh-my-claude.conf")" \
          == "${h21_conf_before}" \
        && ! -e "${H21}/.claude/.switch-tier-transaction" ]]; then
    ok "SIGKILL recovery ignores poisoned internal env and restores entry generation"
  else
    bad "SIGKILL recovery failed to restore the durable tier transaction"
  fi
else
  kill -9 "${h21_pid}" 2>/dev/null || true
  wait "${h21_pid}" 2>/dev/null || true
  bad "post-conf crash barrier was never reached"
fi

H22="${TMP_ROOT}/h22-stage-orphan"
seed_full_home "${H22}"
printf 'model_tier=balanced\n' > "${H22}/.claude/oh-my-claude.conf"
h22_agents_before="$(agent_tree_digest "${H22}")"
h22_conf_before="$(cksum < "${H22}/.claude/oh-my-claude.conf")"
h22_ready="${H22}/wal-stage.ready"
h22_release="${H22}/wal-stage.release"
HOME="${H22}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_WAL_STAGE_READY_FILE="${h22_ready}" \
  OMC_TEST_SWITCH_WAL_STAGE_RELEASE_FILE="${h22_release}" \
  bash "${H22}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h22_pid=$!
if wait_for_file "${h22_ready}"; then
  kill -9 "${h22_pid}" 2>/dev/null || true
  wait "${h22_pid}" 2>/dev/null || true
  if remove_killed_owner_lock "${H22}" "${h22_pid}" \
      && HOME="${H22}" bash "${H22}/.claude/switch-tier.sh" --recover-only \
        >/dev/null 2>&1 \
      && [[ "$(agent_tree_digest "${H22}")" == "${h22_agents_before}" \
        && "$(cksum < "${H22}/.claude/oh-my-claude.conf")" \
          == "${h22_conf_before}" \
        && -z "$(find "${H22}/.claude" -maxdepth 1 \
          -name '.switch-tier-transaction.stage.*' -print -quit)" ]]; then
    ok "unpublished SIGKILL stage is swept without changing managed files"
  else
    bad "unpublished tier stage was not safely swept"
  fi
else
  kill -9 "${h22_pid}" 2>/dev/null || true
  wait "${h22_pid}" 2>/dev/null || true
  bad "tier WAL-stage crash barrier was never reached"
fi

H23="${TMP_ROOT}/h23-committed-recovery"
seed_full_home "${H23}"
printf 'model_tier=balanced\n' > "${H23}/.claude/oh-my-claude.conf"
h23_ready="${H23}/commit-link.ready"
h23_release="${H23}/commit-link.release"
HOME="${H23}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_COMMIT_LINK_READY_FILE="${h23_ready}" \
  OMC_TEST_SWITCH_COMMIT_LINK_RELEASE_FILE="${h23_release}" \
  bash "${H23}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h23_pid=$!
if wait_for_file "${h23_ready}"; then
  kill -9 "${h23_pid}" 2>/dev/null || true
  wait "${h23_pid}" 2>/dev/null || true
  if remove_killed_owner_lock "${H23}" "${h23_pid}" \
      && HOME="${H23}" bash "${H23}/.claude/switch-tier.sh" --recover-only \
        >/dev/null 2>&1 \
      && grep -q '^model_tier=quality$' \
        "${H23}/.claude/oh-my-claude.conf" \
      && [[ "$(model_of "${H23}" librarian)" == "opus" \
        && ! -e "${H23}/.claude/.switch-tier-transaction" ]]; then
    ok "committed crash keeps the final tier and retires leftover metadata"
  else
    bad "committed tier recovery rolled back or retained metadata"
  fi
else
  kill -9 "${h23_pid}" 2>/dev/null || true
  wait "${h23_pid}" 2>/dev/null || true
  bad "tier commit-link crash barrier was never reached"
fi

H24="${TMP_ROOT}/h24-retired-orphans"
seed_full_home "${H24}"
printf 'model_tier=balanced\n' > "${H24}/.claude/oh-my-claude.conf"
h24_ready="${H24}/retire-moved.ready"
h24_release="${H24}/retire-moved.release"
HOME="${H24}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_RETIRE_MOVED_READY_FILE="${h24_ready}" \
  OMC_TEST_SWITCH_RETIRE_MOVED_RELEASE_FILE="${h24_release}" \
  bash "${H24}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h24_pid=$!
if wait_for_file "${h24_ready}"; then
  kill -9 "${h24_pid}" 2>/dev/null || true
  wait "${h24_pid}" 2>/dev/null || true
  if remove_killed_owner_lock "${H24}" "${h24_pid}" \
      && HOME="${H24}" bash "${H24}/.claude/switch-tier.sh" --recover-only \
        >/dev/null 2>&1 \
      && grep -q '^model_tier=quality$' \
        "${H24}/.claude/oh-my-claude.conf" \
      && [[ -z "$(find "${H24}/.claude" -maxdepth 1 \
        -name '.switch-tier-retired.*' -print -quit)" ]]; then
    ok "unmarked retired transaction is structurally recovered and swept"
  else
    bad "unmarked retired tier transaction wedged recovery"
  fi
else
  kill -9 "${h24_pid}" 2>/dev/null || true
  wait "${h24_pid}" 2>/dev/null || true
  bad "tier retirement-move crash barrier was never reached"
fi
mkdir -m 700 "${H24}/.claude/.switch-tier-retired.EMPTY01"
if HOME="${H24}" bash "${H24}/.claude/switch-tier.sh" --recover-only \
    >/dev/null 2>&1 \
    && [[ ! -e "${H24}/.claude/.switch-tier-retired.EMPTY01" ]]; then
  ok "empty retired crash-window directory is safely removed"
else
  bad "empty retired crash-window directory permanently blocked recovery"
fi

H25="${TMP_ROOT}/h25-corrupt-wal"
seed_full_home "${H25}"
printf 'model_tier=balanced\n' > "${H25}/.claude/oh-my-claude.conf"
h25_ready="${H25}/post-conf.ready"
h25_release="${H25}/post-conf.release"
HOME="${H25}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_POST_CONF_READY_FILE="${h25_ready}" \
  OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${h25_release}" \
  bash "${H25}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h25_pid=$!
if wait_for_file "${h25_ready}"; then
  kill -9 "${h25_pid}" 2>/dev/null || true
  wait "${h25_pid}" 2>/dev/null || true
  remove_killed_owner_lock "${H25}" "${h25_pid}" || true
  h25_agents_current="$(agent_tree_digest "${H25}")"
  h25_conf_current="$(cksum < "${H25}/.claude/oh-my-claude.conf")"
  cp -p "${H25}/.claude/.switch-tier-transaction/version" \
    "${H25}/version.saved"
  printf '1\0\n' > "${H25}/.claude/.switch-tier-transaction/version"
  if HOME="${H25}" bash "${H25}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
    bad "raw-NUL tier WAL authority was normalized and accepted"
  elif [[ "$(agent_tree_digest "${H25}")" == "${h25_agents_current}" \
      && "$(cksum < "${H25}/.claude/oh-my-claude.conf")" \
        == "${h25_conf_current}" \
      && -d "${H25}/.claude/.switch-tier-transaction" ]]; then
    ok "raw-NUL tier WAL authority fails closed and remains retained"
  else
    bad "raw-NUL tier WAL changed live generations or was discarded"
  fi
  cp -p "${H25}/version.saved" \
    "${H25}/.claude/.switch-tier-transaction/version"
  printf '1\\u0000\n' > "${H25}/.claude/.switch-tier-transaction/version"
  if HOME="${H25}" bash "${H25}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
    bad "escaped-NUL tier WAL authority was accepted"
  elif [[ "$(agent_tree_digest "${H25}")" == "${h25_agents_current}" \
      && "$(cksum < "${H25}/.claude/oh-my-claude.conf")" \
        == "${h25_conf_current}" \
      && -d "${H25}/.claude/.switch-tier-transaction" ]]; then
    ok "escaped-NUL tier WAL authority fails closed and remains retained"
  else
    bad "escaped-NUL tier WAL changed live generations or was discarded"
  fi
  cp -p "${H25}/version.saved" \
    "${H25}/.claude/.switch-tier-transaction/version"
  printf '1\n\n' > "${H25}/.claude/.switch-tier-transaction/version"
  if HOME="${H25}" bash "${H25}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
    bad "extra tier WAL version record was normalized and accepted"
  elif [[ "$(agent_tree_digest "${H25}")" == "${h25_agents_current}" \
      && "$(cksum < "${H25}/.claude/oh-my-claude.conf")" \
        == "${h25_conf_current}" \
      && -d "${H25}/.claude/.switch-tier-transaction" ]]; then
    ok "extra tier WAL version record fails closed and remains retained"
  else
    bad "extra tier WAL version record changed live generations or was discarded"
  fi
  cp -p "${H25}/version.saved" \
    "${H25}/.claude/.switch-tier-transaction/version"
  cp -p "${H25}/.claude/.switch-tier-transaction/entry-models.tsv" \
    "${H25}/entry-models.saved"
  printf '\n' >> "${H25}/.claude/.switch-tier-transaction/entry-models.tsv"
  if HOME="${H25}" bash "${H25}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
    bad "trailing blank tier WAL record was accepted"
  elif [[ "$(agent_tree_digest "${H25}")" == "${h25_agents_current}" \
      && "$(cksum < "${H25}/.claude/oh-my-claude.conf")" \
        == "${h25_conf_current}" \
      && -d "${H25}/.claude/.switch-tier-transaction" ]]; then
    ok "trailing blank tier WAL record fails closed before recovery"
  else
    bad "trailing blank tier WAL record changed live generations or was discarded"
  fi
  cp -p "${H25}/entry-models.saved" \
    "${H25}/.claude/.switch-tier-transaction/entry-models.tsv"
  head -n 1 "${H25}/.claude/.switch-tier-transaction/entry-models.tsv" \
    >> "${H25}/.claude/.switch-tier-transaction/entry-models.tsv"
  if HOME="${H25}" bash "${H25}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1; then
    bad "duplicate manifest row was accepted during tier recovery"
  elif [[ "$(agent_tree_digest "${H25}")" == "${h25_agents_current}" \
      && -d "${H25}/.claude/.switch-tier-transaction" ]]; then
    ok "malformed tier WAL fails closed before mutating live generations"
  else
    bad "malformed tier WAL changed files or was discarded"
  fi
else
  kill -9 "${h25_pid}" 2>/dev/null || true
  wait "${h25_pid}" 2>/dev/null || true
  bad "corrupt-WAL setup barrier was never reached"
fi

H26="${TMP_ROOT}/h26-final-race"
seed_full_home "${H26}"
printf 'model_tier=balanced\n' > "${H26}/.claude/oh-my-claude.conf"
h26_ready="${H26}/post-conf.ready"
h26_release="${H26}/post-conf.release"
HOME="${H26}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_POST_CONF_READY_FILE="${h26_ready}" \
  OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${h26_release}" \
  bash "${H26}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h26_pid=$!
if wait_for_file "${h26_ready}"; then
  printf '\n# foreign final-generation edit\n' \
    >> "${H26}/.claude/agents/librarian.md"
  : > "${h26_release}"
  wait "${h26_pid}" 2>/dev/null
  h26_rc=$?
  if [[ "${h26_rc}" -ne 0 \
      && -d "${H26}/.claude/.switch-tier-transaction" ]] \
      && grep -q 'foreign final-generation edit' \
        "${H26}/.claude/agents/librarian.md"; then
    ok "final-generation race blocks commit and preserves the foreign file for inspection"
  else
    bad "final-generation race was committed or foreign bytes were erased"
  fi
else
  kill -9 "${h26_pid}" 2>/dev/null || true
  wait "${h26_pid}" 2>/dev/null || true
  bad "final-generation race barrier was never reached"
fi

H27="${TMP_ROOT}/h27-agents-parent-link"
seed_full_home "${H27}"
mv "${H27}/.claude/agents" "${H27}/outside-agents"
ln -s "${H27}/outside-agents" "${H27}/.claude/agents"
h27_before="$(cksum < "${H27}/outside-agents/librarian.md")"
if HOME="${H27}" bash "${H27}/.claude/switch-tier.sh" quality \
    >/dev/null 2>&1; then
  bad "switcher traversed a symlinked agents directory"
elif [[ "$(cksum < "${H27}/outside-agents/librarian.md")" \
    == "${h27_before}" ]]; then
  ok "switcher rejects a symlinked agents directory before materialization"
else
  bad "switcher modified the symlinked agents-directory referent"
fi

H28="${TMP_ROOT}/h28-public-skip"
seed_full_home "${H28}"
printf 'model_tier=balanced\n' > "${H28}/.claude/oh-my-claude.conf"
h28_before="$(agent_tree_digest "${H28}")"
if HOME="${H28}" OMC_SWITCH_SKIP_CONF_PERSIST=1 \
    OMC_SWITCH_PARENT_TX_CAPABILITY=forged \
    bash "${H28}/.claude/switch-tier.sh" quality >/dev/null 2>&1; then
  bad "standalone caller entered the internal no-persist tier mode"
elif [[ "$(agent_tree_digest "${H28}")" == "${h28_before}" ]]; then
  ok "internal no-persist mode requires a live parent transaction capability"
else
  bad "rejected internal no-persist invocation changed agent files"
fi

H29="${TMP_ROOT}/h29-recover-without-agents"
seed_full_home "${H29}"
mv "${H29}/.claude/agents" "${H29}/agents-held-aside"
mkdir -m 700 "${H29}/.claude/.switch-tier-transaction.stage.MANUAL1"
if HOME="${H29}" bash "${H29}/.claude/switch-tier.sh" --recover-only \
    >/dev/null 2>&1 \
    && [[ ! -e "${H29}/.claude/.switch-tier-transaction.stage.MANUAL1" ]]; then
  ok "recover-only sweeps safe orphan metadata without an agents directory"
else
  bad "recover-only unnecessarily required an agents directory for orphan cleanup"
fi

H30="${TMP_ROOT}/h30-parent-fence"
seed_full_home "${H30}"
printf 'model_tier=balanced\n' > "${H30}/.claude/oh-my-claude.conf"
mkdir -m 700 "${H30}/.claude/.omc-config-transaction"
h30_before="$(agent_tree_digest "${H30}")"
if HOME="${H30}" bash "${H30}/.claude/switch-tier.sh" quality \
    >/dev/null 2>&1; then
  bad "standalone tier switch ignored pending parent transaction metadata"
elif [[ "$(agent_tree_digest "${H30}")" == "${h30_before}" ]] \
    && grep -q '^model_tier=balanced$' \
      "${H30}/.claude/oh-my-claude.conf"; then
  ok "standalone tier switch refuses parent metadata before mutation"
else
  bad "parent-metadata fence changed the live tier generation"
fi

H31="${TMP_ROOT}/h31-recovery-final-race"
seed_full_home "${H31}"
printf 'model_tier=balanced\n' > "${H31}/.claude/oh-my-claude.conf"
h31_crash_ready="${H31}/crash.ready"
h31_crash_release="${H31}/crash.release"
HOME="${H31}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_POST_CONF_READY_FILE="${h31_crash_ready}" \
  OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${h31_crash_release}" \
  bash "${H31}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h31_crash_pid=$!
if wait_for_file "${h31_crash_ready}"; then
  kill -9 "${h31_crash_pid}" 2>/dev/null || true
  wait "${h31_crash_pid}" 2>/dev/null || true
  remove_killed_owner_lock "${H31}" "${h31_crash_pid}" || true
  h31_recover_ready="${H31}/recover.ready"
  h31_recover_release="${H31}/recover.release"
  HOME="${H31}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
    OMC_TEST_SWITCH_RECOVERY_READY_FILE="${h31_recover_ready}" \
    OMC_TEST_SWITCH_RECOVERY_RELEASE_FILE="${h31_recover_release}" \
    bash "${H31}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1 &
  h31_recover_pid=$!
  if wait_for_file "${h31_recover_ready}"; then
    printf '\n# foreign recovery-generation edit\n' \
      >> "${H31}/.claude/agents/librarian.md"
    : > "${h31_recover_release}"
    wait "${h31_recover_pid}" 2>/dev/null
    h31_rc=$?
    if [[ "${h31_rc}" -ne 0 \
        && -d "${H31}/.claude/.switch-tier-transaction" ]] \
        && grep -q 'foreign recovery-generation edit' \
          "${H31}/.claude/agents/librarian.md"; then
      ok "rollback re-verifies every restored tier generation before WAL retirement"
    else
      bad "rollback retired the tier WAL after a post-restore foreign edit"
    fi
  else
    kill -9 "${h31_recover_pid}" 2>/dev/null || true
    wait "${h31_recover_pid}" 2>/dev/null || true
    bad "tier recovery final-verification barrier was never reached"
  fi
else
  kill -9 "${h31_crash_pid}" 2>/dev/null || true
  wait "${h31_crash_pid}" 2>/dev/null || true
  bad "tier recovery-race setup barrier was never reached"
fi

H32="${TMP_ROOT}/h32-recovery-parent-swap"
seed_full_home "${H32}"
printf 'model_tier=balanced\n' > "${H32}/.claude/oh-my-claude.conf"
h32_crash_ready="${H32}/crash.ready"
h32_crash_release="${H32}/crash.release"
HOME="${H32}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_POST_CONF_READY_FILE="${h32_crash_ready}" \
  OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${h32_crash_release}" \
  bash "${H32}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h32_crash_pid=$!
if wait_for_file "${h32_crash_ready}"; then
  kill -9 "${h32_crash_pid}" 2>/dev/null || true
  wait "${h32_crash_pid}" 2>/dev/null || true
  remove_killed_owner_lock "${H32}" "${h32_crash_pid}" || true
  h32_recover_ready="${H32}/recover.ready"
  h32_recover_release="${H32}/recover.release"
  HOME="${H32}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
    OMC_TEST_SWITCH_RECOVERY_READY_FILE="${h32_recover_ready}" \
    OMC_TEST_SWITCH_RECOVERY_RELEASE_FILE="${h32_recover_release}" \
    bash "${H32}/.claude/switch-tier.sh" --recover-only \
      >/dev/null 2>&1 &
  h32_recover_pid=$!
  if wait_for_file "${h32_recover_ready}"; then
    mv "${H32}/.claude/agents" "${H32}/agents-original-generation"
    cp -R "${H32}/agents-original-generation" "${H32}/.claude/agents"
    : > "${h32_recover_release}"
    wait "${h32_recover_pid}" 2>/dev/null
    h32_rc=$?
    if [[ "${h32_rc}" -ne 0 \
        && -d "${H32}/.claude/.switch-tier-transaction" ]]; then
      ok "rollback rejects a matching-content agents-directory replacement"
    else
      bad "rollback accepted a replacement agents-directory identity"
    fi
  else
    kill -9 "${h32_recover_pid}" 2>/dev/null || true
    wait "${h32_recover_pid}" 2>/dev/null || true
    bad "tier recovery parent-swap barrier was never reached"
  fi
else
  kill -9 "${h32_crash_pid}" 2>/dev/null || true
  wait "${h32_crash_pid}" 2>/dev/null || true
  bad "tier parent-swap setup barrier was never reached"
fi

H33="${TMP_ROOT}/h33-retirement-replacement"
seed_full_home "${H33}"
printf 'model_tier=balanced\n' > "${H33}/.claude/oh-my-claude.conf"
h33_ready="${H33}/retire.ready"
h33_release="${H33}/retire.release"
HOME="${H33}" OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_RETIRE_READY_FILE="${h33_ready}" \
  OMC_TEST_SWITCH_RETIRE_RELEASE_FILE="${h33_release}" \
  bash "${H33}/.claude/switch-tier.sh" quality >/dev/null 2>&1 &
h33_pid=$!
if wait_for_file "${h33_ready}"; then
  h33_parent="$(cat "${h33_ready}")"
  mv "${h33_parent}/transaction" "${h33_parent}/original-transaction"
  mkdir -m 700 "${h33_parent}/transaction"
  printf 'do-not-delete\n' > "${h33_parent}/transaction/sentinel"
  : > "${h33_release}"
  wait "${h33_pid}" 2>/dev/null
  h33_rc=$?
  if [[ "${h33_rc}" -ne 0 \
      && -f "${h33_parent}/transaction/sentinel" \
      && -d "${h33_parent}/original-transaction" ]]; then
    ok "retirement revalidates transaction identity before recursive deletion"
  else
    bad "retirement deleted or accepted a replacement transaction directory"
  fi
else
  kill -9 "${h33_pid}" 2>/dev/null || true
  wait "${h33_pid}" 2>/dev/null || true
  bad "tier retirement replacement barrier was never reached"
fi

# Lock both standalone rosters—and their union—to bundle declarations so
# adding or reclassifying any shipped agent cannot weaken the soundness proof.
bundle_inherit_roster="$({
  for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
    [[ "$(sed -n 's/^model: //p' "${agent_file}" | head -1)" == "inherit" ]] \
      && basename "${agent_file}" .md
  done
} | sort | tr '\n' ' ' | sed 's/ $//')"
switch_inherit_roster="$(sed -n \
  "s/^SHIPPED_INHERIT_AGENTS='\\(.*\\)'$/\\1/p" "${SWITCH_TIER}" \
  | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "${switch_inherit_roster}" == "${bundle_inherit_roster}" ]]; then
  ok "switch-tier canonical inherit roster matches bundle frontmatter"
else
  bad "switch-tier inherit roster drifted from bundle declarations"
fi
install_inherit_roster="$(sed -n \
  "s/^SHIPPED_INHERIT_AGENTS='\\(.*\\)'$/\\1/p" "${INSTALL_SH}" \
  | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "${install_inherit_roster}" == "${bundle_inherit_roster}" ]]; then
  ok "installer canonical inherit roster matches bundle frontmatter"
else
  bad "installer inherit roster drifted from bundle declarations"
fi
bundle_fixed_roster="$({
  for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
    [[ "$(sed -n 's/^model: //p' "${agent_file}" | head -1)" == "sonnet" ]] \
      && basename "${agent_file}" .md
  done
} | sort | tr '\n' ' ' | sed 's/ $//')"
switch_fixed_roster="$(sed -n \
  "s/^SHIPPED_FIXED_AGENTS='\\(.*\\)'$/\\1/p" "${SWITCH_TIER}" \
  | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "${switch_fixed_roster}" == "${bundle_fixed_roster}" ]]; then
  ok "switch-tier fixed roster matches bundle frontmatter"
else
  bad "switch-tier fixed roster drifted from bundle declarations"
fi
install_fixed_roster="$(sed -n \
  "s/^SHIPPED_FIXED_AGENTS='\\(.*\\)'$/\\1/p" "${INSTALL_SH}" \
  | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "${install_fixed_roster}" == "${bundle_fixed_roster}" ]]; then
  ok "installer fixed roster matches bundle frontmatter"
else
  bad "installer fixed roster drifted from bundle declarations"
fi
bundle_all_roster="$({
  for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
    basename "${agent_file}" .md
  done
} | sort | tr '\n' ' ' | sed 's/ $//')"
switch_all_roster="$(printf '%s\n%s\n' \
  "${switch_inherit_roster}" "${switch_fixed_roster}" \
  | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "${switch_all_roster}" == "${bundle_all_roster}" ]]; then
  ok "switch-tier declaration rosters cover the full shipped agent set"
else
  bad "switch-tier declaration rosters do not cover all shipped agents"
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
  if grep -Fq '[[ ! "${agent}" =~ ^[A-Za-z0-9_.-]+$ ]]' "${f}"; then
    ok "${name} validates bare agent ids before materialization"
  else
    bad "${name} lacks bare agent-id path validation"
  fi
  if grep -q 'has no valid pins; falling back to saved overrides' "${f}"; then
    ok "${name} falls back when env overrides are wholly invalid"
  else
    bad "${name} lacks invalid-all env fallback"
  fi
done

printf '\n--- model_overrides: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
