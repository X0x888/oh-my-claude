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

# Duplicate keys can survive hand edits or old migrations. The entire config
# stack is last-write-wins; the switcher must not make tier decisions from a
# stale first row.
H11="${TMP_ROOT}/h11"
seed_home "${H11}"
printf 'model_tier=economy\nmodel_tier=quality\n' \
  > "${H11}/.claude/oh-my-claude.conf"
out11="$(HOME="${H11}" bash "${SWITCH_TIER}" 2>&1)"
if printf '%s' "${out11}" | grep -q 'Current model tier: quality'; then
  ok "switch-tier config reads use last-occurrence-wins semantics"
else
  bad "switch-tier read stale first duplicate tier: ${out11}"
fi

H11B="${TMP_ROOT}/h11b"
seed_home "${H11B}"
printf 'model_tier=typo\n' > "${H11B}/.claude/oh-my-claude.conf"
out11b="$(HOME="${H11B}" bash "${SWITCH_TIER}" 2>&1)"
if printf '%s' "${out11b}" \
    | grep -q 'Current model tier: balanced (invalid saved value .* ignored)'; then
  ok "switch-tier display normalizes an invalid saved tier to balanced"
else
  bad "switch-tier display leaked an invalid effective tier: ${out11b}"
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
cp -R "${REPO_ROOT}/bundle/dot-claude/agents" \
  "${INSTALL_FIXTURE}/bundle/dot-claude/agents"
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
