#!/usr/bin/env bash

# Contract tests for the single quality-first model resolver shared by router,
# Council helper, and Agent PreTool enforcement.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
CLI="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/resolve-agent-model.sh"
PENDING="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh"

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${STATE_ROOT}" "${TEST_HOME}/.claude"
cp -R "${REPO_ROOT}/bundle/dot-claude/agents" \
  "${TEST_HOME}/.claude/agents"

pass=0
fail=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# Repository root is resolved dynamically.
# shellcheck disable=SC1090
. "${COMMON}"

printf '\n## Runtime model resolver matrix\n'

assert_eq "effective tier accepts quality" "quality" \
  "$(omc_effective_model_tier quality)"
assert_eq "invalid effective tier normalizes to balanced" "balanced" \
  "$(omc_effective_model_tier not-a-model)"

# The hard-coded declaration classifier is a runtime copy of a bundle contract;
# pin every agent so a newly added/changed frontmatter line cannot drift silently.
for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
  agent="$(basename "${agent_file}" .md)"
  declared="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  assert_eq "declaration parity: ${agent}" "${declared}" "$(omc_agent_declared_model "${agent}")"
done

# Quality keeps deliberation on the current session and lifts shipped Sonnet.
assert_eq "quality reviewer inherits" "inherit" \
  "$(resolve_agent_model quality-reviewer standard 0 low quality '')"
assert_eq "quality builder uses opus" "opus" \
  "$(resolve_agent_model frontend-developer standard 0 low quality '')"

# Balanced normal Council must not accidentally become deep-priced merely
# because broad evaluations classify high risk.
assert_eq "balanced normal Council lens stays sonnet" "sonnet" \
  "$(resolve_agent_model product-lens council 0 high balanced '')"
assert_eq "balanced deep Council lens escalates" "opus" \
  "$(resolve_agent_model product-lens council 1 high balanced '')"
assert_eq "balanced deep inherit deliberator still inherits" "inherit" \
  "$(resolve_agent_model oracle council 1 high balanced '')"
assert_eq "balanced high-risk standard builder escalates" "opus" \
  "$(resolve_agent_model backend-api-developer standard 0 high balanced '')"

# Economy live routing is progressive: low-risk calls use Sonnet, medium-risk
# judgment inherits, and high-risk work uses the quality posture. Installed
# frontmatter separately preserves the inherit/Sonnet declaration split.
assert_eq "economy low reviewer stays sonnet" "sonnet" \
  "$(resolve_agent_model quality-reviewer standard 0 low economy '')"
assert_eq "economy medium reviewer inherits" "inherit" \
  "$(resolve_agent_model quality-reviewer standard 0 medium economy '')"
assert_eq "economy medium builder stays sonnet" "sonnet" \
  "$(resolve_agent_model frontend-developer standard 0 medium economy '')"
assert_eq "economy high inherit deliberator returns one inherit token" "inherit" \
  "$(resolve_agent_model quality-reviewer standard 0 high economy '')"
assert_eq "economy high builder escalates to opus" "opus" \
  "$(resolve_agent_model frontend-developer standard 0 high economy '')"
assert_eq "economy high normal Council lens stays sonnet" "sonnet" \
  "$(resolve_agent_model security-lens council 0 high economy '')"
assert_eq "economy deep Council lens uses opus" "opus" \
  "$(resolve_agent_model security-lens council 1 high economy '')"

# Explicit user pins are the absolute top precedence, including cheaper pins
# and inherit omission. Within equal specificity, the last valid duplicate
# matches install-time semantics.
assert_eq "haiku override beats high-risk economy" "haiku" \
  "$(resolve_agent_model librarian standard 0 high economy 'librarian:haiku')"
assert_eq "sonnet override beats Council deep" "sonnet" \
  "$(resolve_agent_model product-lens council 1 high balanced 'product-lens:sonnet')"
assert_eq "unmaterialized fixed-role inherit pin is ignored" "opus" \
  "$(resolve_agent_model librarian standard 0 high quality 'librarian:inherit')"
sed 's/^model: sonnet$/model: inherit/' \
  "${TEST_HOME}/.claude/agents/librarian.md" \
  > "${TEST_HOME}/.claude/agents/librarian.md.tmp"
mv "${TEST_HOME}/.claude/agents/librarian.md.tmp" \
  "${TEST_HOME}/.claude/agents/librarian.md"
assert_eq "materialized bare inherit override beats quality opus" "inherit" \
  "$(resolve_agent_model librarian standard 0 high quality 'librarian:inherit')"
sed 's/^model: inherit$/model: sonnet/' \
  "${TEST_HOME}/.claude/agents/librarian.md" \
  > "${TEST_HOME}/.claude/agents/librarian.md.tmp"
mv "${TEST_HOME}/.claude/agents/librarian.md.tmp" \
  "${TEST_HOME}/.claude/agents/librarian.md"
assert_eq "last duplicate wins" "opus" \
  "$(resolve_agent_model oracle standard 0 low economy 'oracle:haiku,oracle:opus')"
assert_eq "unknown custom agent uses definition" "definition" \
  "$(resolve_agent_model plugin:custom-auditor standard 0 high quality '')"
assert_eq "namespaced oracle collision uses plugin definition" "definition" \
  "$(resolve_agent_model plugin:oracle standard 0 high quality '')"
assert_eq "namespaced builder collision uses plugin definition" "definition" \
  "$(resolve_agent_model plugin:frontend-developer standard 0 high quality '')"
assert_eq "unknown custom explicit override works" "opus" \
  "$(resolve_agent_model plugin:custom-auditor standard 0 low economy 'plugin:custom-auditor:opus')"
assert_eq "bare custom explicit named-model override works at runtime" "haiku" \
  "$(resolve_agent_model custom-auditor standard 0 high quality 'custom-auditor:haiku')"
assert_eq "exact namespaced override beats later bare pin" "opus" \
  "$(resolve_agent_model plugin:oracle standard 0 high economy 'plugin:oracle:opus,oracle:haiku')"
assert_eq "bare pin applies when no exact plugin pin exists" "haiku" \
  "$(resolve_agent_model plugin:oracle standard 0 high economy 'oracle:haiku')"
assert_eq "bare inherit pin never leaks onto namespaced plugin collision" "definition" \
  "$(resolve_agent_model plugin:oracle standard 0 high economy 'oracle:inherit')"
assert_eq "exact namespaced inherit pin is unenforceable" "definition" \
  "$(resolve_agent_model plugin:oracle standard 0 high economy 'plugin:oracle:inherit')"
printf -- '---\nname: custom-inherited\nmodel: inherit\n---\nbody\n' \
  > "${TEST_HOME}/.claude/agents/custom-inherited.md"
assert_eq "already-inherited custom definition supports bare inherit" "inherit" \
  "$(resolve_agent_model custom-inherited standard 0 high economy \
    'custom-inherited:inherit')"
printf -- '---\nname: custom-fixed\nmodel: sonnet\n---\nbody\n' \
  > "${TEST_HOME}/.claude/agents/custom-fixed.md"
assert_eq "fixed custom definition cannot claim bare inherit" "definition" \
  "$(resolve_agent_model custom-fixed standard 0 high economy \
    'custom-fixed:inherit')"
printf -- '---\nname: duplicate-inherit\nmodel: inherit\nmodel: opus\n---\nbody\n' \
  > "${TEST_HOME}/.claude/agents/duplicate-inherit.md"
assert_eq "duplicate model keys cannot prove a live inherit override" "definition" \
  "$(resolve_agent_model duplicate-inherit standard 0 high economy \
    'duplicate-inherit:inherit')"

assert_eq "tricky signal raises reasoning risk" "high" \
  "$(classify_model_routing_risk_tier low 'This is a tricky intermittent failure')"
assert_eq "risk classifier never demotes" "high" \
  "$(classify_model_routing_risk_tier high 'simple docs edit')"
assert_eq "positive ambiguity raises routing risk" "high" \
  "$(classify_model_routing_risk_tier low 'The requirements are ambiguous')"
assert_eq "positive novel failure raises routing risk" "high" \
  "$(classify_model_routing_risk_tier low 'Investigate this novel failure')"
assert_eq "positive race condition raises routing risk" "high" \
  "$(classify_model_routing_risk_tier low 'There may be a race condition')"
assert_eq "positive hard debugging raises routing risk" "high" \
  "$(classify_model_routing_risk_tier low 'This needs hard debugging')"
assert_eq "positive difficult debugging raises routing risk" "high" \
  "$(classify_model_routing_risk_tier low 'Expect difficult debugging')"
assert_eq "negated ambiguity and ruled-out race stay at base risk" "medium" \
  "$(classify_model_routing_risk_tier medium \
    'The requirements are not ambiguous and the race condition is ruled out')"
assert_eq "negated novelty and hard debugging stay low" "low" \
  "$(classify_model_routing_risk_tier low \
    'This is not a novel failure and debugging is not hard')"
assert_eq "absent ambiguity/race/difficult debugging stay low" "low" \
  "$(classify_model_routing_risk_tier low \
    'There is no ambiguity, no race condition, and no difficult debugging')"
assert_eq "neither-nor coordinated negation stays low" "low" \
  "$(classify_model_routing_risk_tier low \
    'This is neither ambiguous nor a race condition')"
assert_eq "remaining positive phrase survives local negation" "high" \
  "$(classify_model_routing_risk_tier low \
    'The requirements are not ambiguous, but there is a race condition')"
assert_eq "positive phrase survives neither-nor redaction" "high" \
  "$(classify_model_routing_risk_tier low \
    'This is neither ambiguous nor a race condition, but it is a novel failure')"
assert_eq "explicit uncertainty predicate matches unstable unknown cause" "yes" \
  "$(is_explicit_model_uncertainty_request 'tricky intermittent failure with an unknown root cause' && printf yes || printf no)"
assert_eq "not-known root cause is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'The root cause is not known' && printf yes || printf no)"
assert_eq "no-known root cause is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'There is no known root cause' && printf yes || printf no)"
assert_eq "do-not-know root cause is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'We do not know the root cause' && printf yes || printf no)"
assert_eq "hard-to-reproduce is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'The failure is hard to reproduce' && printf yes || printf no)"
assert_eq "difficult-to-reproduce is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'This behavior is difficult-to-reproduce' && printf yes || printf no)"
assert_eq "flakiness is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'The suite still has flakiness' && printf yes || printf no)"
assert_eq "sporadic failure is explicit uncertainty" "yes" \
  "$(is_explicit_model_uncertainty_request 'Investigate this sporadic failure' && printf yes || printf no)"
assert_eq "generic breadth/high risk is not explicit uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'large high-risk migration across every service' && printf yes || printf no)"
assert_eq "negated tricky and known cause do not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'This is not tricky; the root cause is known' && printf yes || printf no)"
assert_eq "negated uncertainty and intermittence do not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'There is no uncertainty and the failure is not intermittent' && printf yes || printf no)"
assert_eq "not-unknown root cause does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'The root cause is not unknown' && printf yes || printf no)"
assert_eq "now-known root cause does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'The root cause is now known' && printf yes || printf no)"
assert_eq "we-now-know root cause does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'We now know the root cause' && printf yes || printf no)"
assert_eq "not-hard-to-reproduce does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'The failure is not hard to reproduce' && printf yes || printf no)"
assert_eq "resolved flakiness does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'The flakiness has been resolved' && printf yes || printf no)"
assert_eq "no sporadic failure does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'There are no sporadic failures' && printf yes || printf no)"
assert_eq "not sporadic does not escalate" "no" \
  "$(is_explicit_model_uncertainty_request 'The failure is not sporadic' && printf yes || printf no)"
assert_eq "remaining positive signal survives local negation" "yes" \
  "$(is_explicit_model_uncertainty_request 'It is not tricky, but the logs contain conflicting evidence' && printf yes || printf no)"
assert_eq "neither tricky nor intermittent is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'This is neither tricky nor intermittent' && printf yes || printf no)"
assert_eq "neither uncertain nor flaky is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'The issue is neither uncertain nor flaky' && printf yes || printf no)"
assert_eq "no tricky issue is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'There is no tricky issue here' && printf yes || printf no)"
assert_eq "not an intermittent failure is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'This is not an intermittent failure' && printf yes || printf no)"
assert_eq "resolved uncertainty is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'The uncertainty has been resolved' && printf yes || printf no)"
assert_eq "resolved architectural uncertainty is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'Architectural uncertainty has been resolved' && printf yes || printf no)"
assert_eq "uncertainty no longer present is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'The uncertainty is no longer present' && printf yes || printf no)"
assert_eq "architectural uncertainty absent is not uncertainty" "no" \
  "$(is_explicit_model_uncertainty_request 'Architectural uncertainty is absent' && printf yes || printf no)"
assert_eq "mixed negation retains remaining flaky signal" "yes" \
  "$(is_explicit_model_uncertainty_request 'It is not tricky but it is flaky' && printf yes || printf no)"
assert_eq "mixed absent uncertainty retains remaining flaky signal" "yes" \
  "$(is_explicit_model_uncertainty_request 'Uncertainty is no longer present, but the failure is flaky' && printf yes || printf no)"
assert_eq "mixed known cause retains hard reproduction signal" "yes" \
  "$(is_explicit_model_uncertainty_request 'The root cause is now known, but it is hard to reproduce' && printf yes || printf no)"
assert_eq "mixed resolved flakiness retains unknown cause signal" "yes" \
  "$(is_explicit_model_uncertainty_request 'Flakiness is resolved, but we do not know the root cause' && printf yes || printf no)"
assert_eq "fixed implementer role is recognized" "yes" \
  "$(omc_agent_is_fixed_implementation frontend-developer && printf yes || printf no)"
assert_eq "Council lens is not misclassified as implementer" "no" \
  "$(omc_agent_is_fixed_implementation security-lens && printf yes || printf no)"
assert_eq "namespaced implementer collision remains custom" "no" \
  "$(omc_agent_is_fixed_implementation plugin:frontend-developer && printf yes || printf no)"
assert_eq "nested namespaced implementer collision remains custom" "no" \
  "$(omc_agent_is_fixed_implementation marketplace:plugin:backend-api-developer && printf yes || printf no)"

# Guidance and enforcement must agree on what "shipped inherit" means. Scan
# the load-bearing uncertainty guidance for every bundled agent identity it
# names and prove each example actually declares inherit; otherwise the user
# would pay for a dispatch that cannot satisfy the deliberation gate.
_uncertainty_guidance="$(grep -E \
  'model_uncertainty_deliberation|_council_uncertainty_hint|Automatic explicit-uncertainty mode|When `UNCERTAINTY_MODE` is active' \
  "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
  "${REPO_ROOT}/bundle/dot-claude/skills/council/SKILL.md")"
_uncertainty_named_agents=0
for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
  agent="$(basename "${agent_file}" .md)"
  if [[ "${_uncertainty_guidance}" =~ (^|[^A-Za-z0-9_-])${agent}([^A-Za-z0-9_-]|$) ]]; then
    _uncertainty_named_agents=$((_uncertainty_named_agents + 1))
    assert_eq "uncertainty guidance names only inherit role: ${agent}" "inherit" \
      "$(omc_agent_declared_model "${agent}")"
  fi
done
assert_eq "uncertainty guidance exposes concrete role examples" "yes" \
  "$([[ "${_uncertainty_named_agents}" -ge 3 ]] && printf yes || printf no)"

printf '\n## Resolver CLI\n'
if bash "${CLI}" --help >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: CLI --help should exit successfully\n' >&2
  fail=$((fail + 1))
fi
printf 'model_tier=balanced\nmodel_overrides=librarian:haiku\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
cli_json="$(bash "${CLI}" --context council --risk high --json product-lens oracle librarian)"
assert_eq "CLI balanced normal Council lens" "sonnet" \
  "$(jq -r '.routes[] | select(.agent == "product-lens") | .tool_model' <<<"${cli_json}")"
assert_eq "CLI inherit uses omit action" "omit" \
  "$(jq -r '.routes[] | select(.agent == "oracle") | .action' <<<"${cli_json}")"
assert_eq "CLI live override" "haiku" \
  "$(jq -r '.routes[] | select(.agent == "librarian") | .tool_model' <<<"${cli_json}")"
printf 'model_tier=economy\nmodel_overrides=\n' \
  > "${TEST_HOME}/.claude/oh-my-claude.conf"
economy_composed_cli="$(bash "${CLI}" --context standard --risk medium \
  --json quality-reviewer)"
assert_eq "Economy composition keeps installed deliberator inherit" "inherit" \
  "$(sed -n 's/^model: //p' \
    "${TEST_HOME}/.claude/agents/quality-reviewer.md" | head -1)"
assert_eq "Economy inherited runtime route omits Agent model" "omit" \
  "$(jq -r '.routes[0].action' <<<"${economy_composed_cli}")"
assert_eq "Economy inherited runtime route passes no enum value" "" \
  "$(jq -r '.routes[0].tool_model' <<<"${economy_composed_cli}")"
printf 'model_tier=quality\nmodel_overrides=\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
invalid_cli_json="$(OMC_MODEL_TIER=not-a-model bash "${CLI}" \
  --context standard --risk low --json frontend-developer)"
assert_eq "CLI invalid env preserves saved quality tier" "quality" \
  "$(jq -r '.tier' <<<"${invalid_cli_json}")"
assert_eq "CLI invalid env route matches saved quality" "opus" \
  "$(jq -r '.routes[0].tool_model' <<<"${invalid_cli_json}")"
rm -f "${TEST_HOME}/.claude/oh-my-claude.conf"
invalid_cli_default="$(OMC_MODEL_TIER=still-not-a-model bash "${CLI}" \
  --context standard --risk low --json frontend-developer)"
assert_eq "CLI invalid env without a valid source defaults balanced" "balanced" \
  "$(jq -r '.tier' <<<"${invalid_cli_default}")"
assert_eq "CLI invalid env default route is balanced" "sonnet" \
  "$(jq -r '.routes[0].tool_model' <<<"${invalid_cli_default}")"
printf 'model_tier=balanced\nmodel_overrides=librarian:haiku\n' \
  > "${TEST_HOME}/.claude/oh-my-claude.conf"
invalid_all_override_cli="$(OMC_MODEL_OVERRIDES='broken,librarian:not-a-model,../victim:opus' \
  bash "${CLI}" --context standard --risk low --json librarian)"
assert_eq "CLI wholly invalid env overrides fall back to saved pins" "haiku" \
  "$(jq -r '.routes[0].tool_model' <<<"${invalid_all_override_cli}")"
mixed_override_cli="$(OMC_MODEL_OVERRIDES='broken,librarian:opus,../victim:haiku' \
  bash "${CLI}" --context standard --risk low --json librarian)"
assert_eq "CLI mixed env overrides keep valid subset precedence" "opus" \
  "$(jq -r '.routes[0].tool_model' <<<"${mixed_override_cli}")"
rm -f "${TEST_HOME}/.claude/oh-my-claude.conf"
unenforceable_inherit_cli="$(OMC_MODEL_TIER=quality \
  OMC_MODEL_OVERRIDES='librarian:inherit' \
  bash "${CLI}" --context standard --risk low --json librarian)"
assert_eq "CLI never labels unmaterialized inherit as a live override" "opus" \
  "$(jq -r '.routes[0].resolved' <<<"${unenforceable_inherit_cli}")"
namespaced_inherit_cli="$(OMC_MODEL_OVERRIDES='plugin:oracle:inherit' \
  bash "${CLI}" --context standard --risk high --json plugin:oracle)"
assert_eq "CLI never labels namespaced inherit as a live override" "definition" \
  "$(jq -r '.routes[0].resolved' <<<"${namespaced_inherit_cli}")"

printf '\n## Agent PreTool enforcement\n'
touch "${STATE_ROOT}/.ulw_active"
sid="model-route-pretool"
mkdir -p "${STATE_ROOT}/${sid}"
jq -nc '{
  workflow_mode:"ultrawork",
  model_routing_resolver_version:"2",
  model_routing_context:"standard",
  model_routing_deep:"0",
  model_routing_risk_tier:"high",
  model_routing_tier:"balanced",
  model_routing_overrides:""
}' > "${STATE_ROOT}/${sid}/session_state.json"

payload() {
  jq -nc --arg sid "${sid}" --arg agent "$1" --arg model "${2:-}" \
    --arg description "${3:-focused task}" '
    {session_id:$sid,tool_name:"Agent",tool_input:{subagent_type:$agent,description:$description}}
    | if $model == "" then . else .tool_input.model=$model end'
}

denied="$(payload frontend-developer '' \
  | OMC_MODEL_TIER=balanced bash "${PENDING}" 2>/dev/null || true)"
assert_contains "PreTool denies omitted required model" "[Model routing]" "${denied}"
assert_contains "PreTool names resolved opus" "resolved to opus" "${denied}"

accepted="$(payload frontend-developer opus \
  | OMC_MODEL_TIER=balanced bash "${PENDING}" 2>/dev/null || true)"
assert_eq "PreTool accepts resolved model" "" "${accepted}"

denied_inherit="$(payload quality-reviewer opus \
  | OMC_MODEL_TIER=balanced bash "${PENDING}" 2>/dev/null || true)"
assert_contains "PreTool enforces inherit omission" "omit the model parameter" "${denied_inherit}"

snapshotted_config="$(payload backend-api-developer opus \
  | OMC_MODEL_TIER=economy \
    OMC_MODEL_OVERRIDES=backend-api-developer:haiku \
    bash "${PENDING}" 2>/dev/null || true)"
if [[ "${snapshotted_config}" != *"[Model routing]"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: v2 PreTool must ignore tier/override changes made after the prompt snapshot\n' >&2
  fail=$((fail + 1))
fi

# A valid router-stamped context outranks the description marker. This is what
# makes the prompt directive and PreTool reproduce one decision; the marker is
# only a compatibility fallback when a partially migrated v1 state lacks the
# new context field.
stored_standard="$(payload backend-api-developer opus '[council:primary] compatibility probe' \
  | OMC_MODEL_TIER=balanced bash "${PENDING}" 2>/dev/null || true)"
if [[ "${stored_standard}" != *"[Model routing]"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: stored standard context should outrank Council marker\n' >&2
  fail=$((fail + 1))
fi

state_file="${STATE_ROOT}/${sid}/session_state.json"
jq 'del(.model_routing_context)' "${state_file}" > "${state_file}.tmp" \
  && mv "${state_file}.tmp" "${state_file}"
fallback_council="$(payload backend-api-developer sonnet '[council:primary] compatibility probe' \
  | OMC_MODEL_TIER=balanced bash "${PENDING}" 2>/dev/null || true)"
if [[ "${fallback_council}" != *"[Model routing]"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: missing context should safely fall back to Council marker\n' >&2
  fail=$((fail + 1))
fi

# Malformed stored v2 state is normalized through the same helper as direct
# resolution and CLI metadata; denial text must never advertise the raw value.
jq '.model_routing_resolver_version="2"
    | .model_routing_context="standard"
    | .model_routing_risk_tier="low"
    | .model_routing_tier="not-a-model"' \
  "${state_file}" > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"
invalid_state_denial="$(payload ios-core-engineer opus \
  | OMC_MODEL_TIER=quality bash "${PENDING}" 2>/dev/null || true)"
assert_contains "PreTool invalid snapshot reports balanced" \
  "tier=balanced" "${invalid_state_denial}"
if [[ "${invalid_state_denial}" != *"not-a-model"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: PreTool leaked malformed stored tier into denial metadata\n' >&2
  fail=$((fail + 1))
fi
invalid_state_accepted="$(payload ios-core-engineer sonnet \
  | OMC_MODEL_TIER=quality bash "${PENDING}" 2>/dev/null || true)"
assert_eq "PreTool invalid snapshot enforces balanced route" "" \
  "${invalid_state_accepted}"

# Pin the Economy/high output cardinality through the actual PreTool consumer,
# not only direct resolver calls. A duplicated printf would make both exact
# routes fail this contract (inherit must omit; a fixed implementer must pass
# exactly one opus token).
sid="model-route-economy-high"
mkdir -p "${STATE_ROOT}/${sid}"
jq -nc '{
  workflow_mode:"ultrawork",
  model_routing_resolver_version:"2",
  model_routing_context:"standard",
  model_routing_deep:"0",
  model_routing_risk_tier:"high",
  model_routing_tier:"economy",
  model_routing_overrides:""
}' > "${STATE_ROOT}/${sid}/session_state.json"

economy_inherit_denied="$(payload quality-reviewer opus \
  | bash "${PENDING}" 2>/dev/null || true)"
assert_contains "Economy high PreTool requires inherit omission" \
  "omit the model parameter" "${economy_inherit_denied}"
economy_inherit_accepted="$(payload quality-reviewer '' \
  | bash "${PENDING}" 2>/dev/null || true)"
assert_eq "Economy high PreTool accepts inherit omission" "" \
  "${economy_inherit_accepted}"

economy_builder_denied="$(payload fullstack-feature-builder sonnet \
  | bash "${PENDING}" 2>/dev/null || true)"
assert_contains "Economy high PreTool requires one opus route" \
  "resolved to opus" "${economy_builder_denied}"
economy_builder_accepted="$(payload fullstack-feature-builder opus \
  | bash "${PENDING}" 2>/dev/null || true)"
assert_eq "Economy high PreTool accepts exact opus route" "" \
  "${economy_builder_accepted}"

printf '\n=== Model resolver: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
