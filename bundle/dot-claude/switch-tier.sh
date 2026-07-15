#!/usr/bin/env bash
#
# switch-tier.sh — Switch oh-my-claude model tier without a full reinstall.
#
# Usage:
#   bash ~/.claude/switch-tier.sh quality    # execution agents on Opus; deliberators keep `inherit`
#   bash ~/.claude/switch-tier.sh balanced   # default split (inherit for planning/review, Sonnet for execution)
#   bash ~/.claude/switch-tier.sh economy    # inherit deliberators; Sonnet specialists; live risk escalation
#   bash ~/.claude/switch-tier.sh quality --force-reconstruct  # reset stale materialized overrides first
#   bash ~/.claude/switch-tier.sh            # show current tier
#
# Reconstructs the 37 shipped `model:` declarations from the embedded
# declaration rosters, applies the tier, and persists it to
# ~/.claude/oh-my-claude.conf. The switch works after the source clone moves;
# custom/plugin agent definitions are never rewritten.
# Per-agent `model_overrides` from the conf are re-applied after the tier
# rewrite so a user's pinned agents survive a tier switch.

set -euo pipefail

CLAUDE_HOME="${HOME}/.claude"
CONF_PATH="${CLAUDE_HOME}/oh-my-claude.conf"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

get_conf() {
  local key="$1"
  [[ -f "${CONF_PATH}" ]] || return 1
  # Last occurrence wins everywhere else in the harness (install.sh,
  # common.sh, and omc-config). Honor the same migration-safe semantics here
  # so a hand-edited duplicate cannot make reconstruction decisions from a
  # stale first row.
  grep -E "^${key}=" "${CONF_PATH}" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Standalone switcher copies of the two shipped declaration rosters. Keep them
# lockstep with common.sh:omc_agent_declared_model; test-model-overrides.sh
# compares them with the bundle frontmatter. We need the rosters here because an
# installed switcher must be able to prove a source-less Balanced → Quality
# transition is safe without sourcing the much larger runtime hook library.
SHIPPED_INHERIT_AGENTS='abstraction-critic chief-of-staff divergent-framer draft-writer editor-critic excellence-reviewer metis oracle prometheus quality-planner quality-reviewer release-reviewer rigor-reviewer writing-architect'
SHIPPED_FIXED_AGENTS='atlas backend-api-developer briefing-analyst data-lens design-lens design-reviewer devops-infrastructure-engineer frontend-developer fullstack-feature-builder growth-lens ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer librarian literature-scout product-lens quality-researcher research-data-analyst security-lens sre-lens test-automation-engineer visual-craft-lens'
SHIPPED_OPTIONAL_IOS_AGENTS='ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer'
OPTIONAL_IOS_DISABLED=0

_shipped_agent_is_known() {
  local wanted="$1" agent
  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    [[ "${wanted}" == "${agent}" ]] && return 0
  done
  return 1
}

_shipped_agent_is_active() {
  local agent="$1" optional
  if [[ "${OPTIONAL_IOS_DISABLED}" -eq 1 ]]; then
    for optional in ${SHIPPED_OPTIONAL_IOS_AGENTS}; do
      [[ "${agent}" == "${optional}" ]] && return 1
    done
  fi
  return 0
}

_agent_has_exact_valid_model() {
  local agent_file="${AGENTS_DIR}/$1.md" model_count model_value
  [[ -f "${agent_file}" ]] || return 1
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  [[ "${model_count}" == "1" \
      && "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]
}

_agent_has_exact_inherit_model() {
  local agent_file="${AGENTS_DIR}/$1.md"
  [[ -f "${agent_file}" ]] || return 1
  [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" \
      && "$(grep -cE '^model: inherit$' "${agent_file}" 2>/dev/null || true)" == "1" ]]
}

_preflight_shipped_roster() {
  local agent agent_file model_count model_value ios_present=0 failures=0
  for agent in ${SHIPPED_OPTIONAL_IOS_AGENTS}; do
    [[ -f "${AGENTS_DIR}/${agent}.md" ]] && ios_present=$((ios_present + 1))
  done
  if [[ "${ios_present}" -eq 0 ]]; then
    # `install.sh --no-ios` intentionally removes this complete optional pack.
    OPTIONAL_IOS_DISABLED=1
  elif [[ "${ios_present}" -ne 4 ]]; then
    printf 'Error: incomplete optional iOS agent pack (%d/4 present); reinstall before switching tiers.\n' \
      "${ios_present}" >&2
    return 1
  fi

  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    _shipped_agent_is_active "${agent}" || continue
    agent_file="${AGENTS_DIR}/${agent}.md"
    if [[ ! -f "${agent_file}" ]]; then
      printf 'Error: missing shipped agent definition: %s\n' "${agent_file}" >&2
      failures=$((failures + 1))
      continue
    fi
    model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
    model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
    if [[ "${model_count}" != "1" ]] \
        || [[ ! "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]; then
      printf 'Error: malformed shipped agent model frontmatter: %s (expected exactly one valid model: line).\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

_set_shipped_agent_model() {
  local agent="$1" model="$2" agent_file tmp
  agent_file="${AGENTS_DIR}/${agent}.md"
  _shipped_agent_is_active "${agent}" || return 0
  [[ -f "${agent_file}" ]] || return 1
  [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" ]] \
    || return 1
  grep -qE "^model: ${model}$" "${agent_file}" && return 0
  tmp="${agent_file}.tmp"
  sed "s/^model: .*$/model: ${model}/" "${agent_file}" > "${tmp}"
  mv "${tmp}" "${agent_file}"
}

_apply_shipped_tier() {
  local tier="$1" agent inherit_model fixed_model
  case "${tier}" in
    quality)  inherit_model="inherit"; fixed_model="opus" ;;
    balanced) inherit_model="inherit"; fixed_model="sonnet" ;;
    # Keep the inherited half of the composition explicit in installed
    # frontmatter. Runtime Economy may omit the Agent model for a
    # medium/high-risk deliberator; that omission must land on `inherit`, not
    # on a stale flattened definition that silently defeats the escalation.
    economy)  inherit_model="inherit"; fixed_model="sonnet" ;;
    *) return 1 ;;
  esac
  for agent in ${SHIPPED_INHERIT_AGENTS}; do
    _set_shipped_agent_model "${agent}" "${inherit_model}"
  done
  for agent in ${SHIPPED_FIXED_AGENTS}; do
    _set_shipped_agent_model "${agent}" "${fixed_model}"
  done
}

# ---------------------------------------------------------------------------
# Show current tier if no argument
# ---------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  current="$(get_conf model_tier 2>/dev/null || true)"
  case "${current}" in
    quality|balanced|economy)
      printf 'Current model tier: %s\n' "${current}"
      ;;
    "")
      printf 'Current model tier: balanced (default)\n'
      ;;
    *)
      printf 'Current model tier: balanced (invalid saved value %q ignored)\n' "${current}"
      ;;
  esac
  printf '\nUsage: bash %s <quality|balanced|economy>\n' "$0"
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate tier argument
# ---------------------------------------------------------------------------

TIER="$1"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    # Compatibility flag: reconstruction is now roster-based, source-less,
    # and safe enough to run on every switch.
    --force-reconstruct) ;;
    *) die "Unknown argument '$1'." ;;
  esac
  shift
done

case "${TIER}" in
  quality|balanced|economy) ;;
  *) die "Invalid tier '${TIER}'. Must be one of: quality, balanced, economy." ;;
esac

# ---------------------------------------------------------------------------
# Locate installed agent definitions
# ---------------------------------------------------------------------------

AGENTS_DIR="${CLAUDE_HOME}/agents"

if [[ ! -d "${AGENTS_DIR}" ]]; then
  die "No agents directory at ${AGENTS_DIR}. Run the full installer first."
fi

# ---------------------------------------------------------------------------
# Persist tier choice
# ---------------------------------------------------------------------------

set_conf() {
  local key="$1" value="$2"
  local tmp="${CONF_PATH}.tmp"
  if [[ -f "${CONF_PATH}" ]]; then
    grep -v "^${key}=" "${CONF_PATH}" > "${tmp}" 2>/dev/null || true
  else
    : > "${tmp}"
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${CONF_PATH}"
}

# Apply per-agent model overrides on top of the tier rewrite. Mirrors
# install.sh's apply_model_overrides (kept in lockstep — see the matching
# function there). Format: model_overrides=agent:model,agent:model where
# model is opus|sonnet|haiku|inherit. Bad pairs are skipped, never fatal.
apply_model_overrides() {
  local agents_dir="$1"
  local conf_path="$2"
  local env_raw="${OMC_MODEL_OVERRIDES:-}" raw="${OMC_MODEL_OVERRIDES:-}"

  # Environment precedence is earned by at least one resolver-valid pin. A
  # wholly malformed environment value must not shadow valid saved pins. A
  # valid explicit-model namespaced pin still establishes environment
  # precedence, but remains runtime-only because there is no safe one-file
  # materialization for plugin identities in ~/.claude/agents. Namespaced
  # inherit is not valid authority: omission cannot change a plugin definition.
  if [[ -n "${env_raw}" ]]; then
    local env_pair env_agent env_model env_has_valid=0
    local -a env_pairs=()
    IFS=',' read -ra env_pairs <<< "${env_raw}"
    for env_pair in "${env_pairs[@]}"; do
      env_pair="${env_pair//[[:space:]]/}"
      [[ "${env_pair}" == *:* ]] || continue
      env_agent="${env_pair%:*}"
      env_model="${env_pair##*:}"
      [[ "${env_agent}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] \
        || continue
      case "${env_model}" in
        opus|sonnet|haiku) env_has_valid=1; break ;;
        inherit)
          if [[ "${env_agent}" != *:* ]] \
              && { { _shipped_agent_is_known "${env_agent}" \
                    && _shipped_agent_is_active "${env_agent}" \
                    && _agent_has_exact_valid_model "${env_agent}"; } \
                || { ! _shipped_agent_is_known "${env_agent}" \
                    && _agent_has_exact_inherit_model "${env_agent}"; }; }; then
            env_has_valid=1
            break
          fi
          ;;
      esac
    done
    if [[ "${env_has_valid}" -eq 0 ]]; then
      printf '  model_overrides: OMC_MODEL_OVERRIDES has no valid pins; falling back to saved overrides\n' >&2
      raw=""
    fi
  fi
  if [[ -z "${raw}" && -f "${conf_path}" ]]; then
    raw="$(grep -E '^model_overrides=' "${conf_path}" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
  fi
  [[ -z "${raw}" ]] && return 0

  local -a pairs=()
  IFS=',' read -ra pairs <<< "${raw}"
  [[ "${#pairs[@]}" -eq 0 ]] && return 0

  local applied=0 runtime_only=0 definition_backed=0 skipped=0
  local pair agent model agent_file tmp model_count model_value
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ -z "${pair}" ]] && continue
    agent="${pair%:*}"
    model="${pair##*:}"
    if [[ -z "${agent}" || -z "${model}" || "${agent}" == "${pair}" ]]; then
      printf '  model_overrides: skipping %q — expected agent:model\n' "${pair}" >&2
      skipped=$((skipped + 1)); continue
    fi
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *)
        printf '  model_overrides: skipping %s — invalid model %q (use opus|sonnet|haiku|inherit)\n' "${agent}" "${model}" >&2
        skipped=$((skipped + 1)); continue ;;
    esac
    if [[ ! "${agent}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      if [[ "${agent}" =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]]; then
        if [[ "${model}" == "inherit" ]]; then
          printf '  model_overrides: skipping %s — namespaced inherit is unenforceable because Agent model omission uses the plugin definition\n' "${agent}" >&2
          skipped=$((skipped + 1))
        else
          printf '  model_overrides: runtime-only %s — namespaced pin is enforced at dispatch; plugin definitions are never rewritten\n' "${agent}" >&2
          runtime_only=$((runtime_only + 1))
        fi
      else
        printf '  model_overrides: skipping %q — invalid bare agent id\n' "${agent}" >&2
        skipped=$((skipped + 1))
      fi
      continue
    fi
    if ! _shipped_agent_is_known "${agent}"; then
      if [[ "${model}" == "inherit" ]]; then
        if _agent_has_exact_inherit_model "${agent}"; then
          printf '  model_overrides: definition-backed %s — custom file already declares inherit and remains untouched\n' \
            "${agent}" >&2
          definition_backed=$((definition_backed + 1))
        else
          printf '  model_overrides: skipping %s — custom inherit is definition-backed only; the custom file must already contain exactly one model: inherit line\n' \
            "${agent}" >&2
          skipped=$((skipped + 1))
        fi
      else
        printf '  model_overrides: runtime-only %s — custom bare pin is enforced at dispatch; custom definitions are never rewritten\n' \
          "${agent}" >&2
        runtime_only=$((runtime_only + 1))
      fi
      continue
    fi
    agent_file="${agents_dir}/${agent}.md"
    if [[ ! -f "${agent_file}" ]]; then
      printf '  model_overrides: skipping %s — no agent file at %s\n' "${agent}" "${agent_file}" >&2
      skipped=$((skipped + 1)); continue
    fi
    model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
    model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
    if [[ "${model_count}" != "1" ]] \
        || [[ ! "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]; then
      printf '  model_overrides: skipping %s — agent definition must contain exactly one valid model: line\n' \
        "${agent}" >&2
      skipped=$((skipped + 1)); continue
    fi
    tmp="${agent_file}.tmp"
    sed "s/^model: .*$/model: ${model}/" "${agent_file}" > "${tmp}"
    mv "${tmp}" "${agent_file}"
    if [[ -n "${MODEL_OVERRIDE_EXPECTATIONS:-}" ]]; then
      printf '%s\t%s\n' "${agent}" "${model}" \
        >> "${MODEL_OVERRIDE_EXPECTATIONS}"
    fi
    applied=$((applied + 1))
  done

  if [[ "${applied}" -gt 0 || "${runtime_only}" -gt 0 \
      || "${definition_backed}" -gt 0 || "${skipped}" -gt 0 ]]; then
    printf '  Model overrides: %d materialized, %d runtime-only, %d definition-backed, %d skipped\n' \
      "${applied}" "${runtime_only}" "${definition_backed}" "${skipped}"
  fi
}

_last_override_expectation() {
  local agent="$1"
  [[ -n "${MODEL_OVERRIDE_EXPECTATIONS:-}" \
      && -f "${MODEL_OVERRIDE_EXPECTATIONS}" ]] || return 0
  awk -F '\t' -v wanted="${agent}" \
    '$1 == wanted { expected=$2 } END { print expected }' \
    "${MODEL_OVERRIDE_EXPECTATIONS}"
}

_verify_one_agent_model() {
  local agent="$1" expected="$2" agent_file model_count actual
  agent_file="${AGENTS_DIR}/${agent}.md"
  if [[ ! -f "${agent_file}" ]]; then
    printf 'Error: tier verification lost agent definition: %s\n' \
      "${agent_file}" >&2
    return 1
  fi
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  actual="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  if [[ "${model_count}" != "1" || "${actual}" != "${expected}" ]]; then
    printf 'Error: tier verification mismatch for %s (expected %s, found %s).\n' \
      "${agent}" "${expected}" "${actual:-missing/malformed}" >&2
    return 1
  fi
  return 0
}

_verify_materialized_tier() {
  local agent expected override failures=0
  local inherit_expected="inherit" fixed_expected="sonnet"
  [[ "${TIER}" == "quality" ]] && fixed_expected="opus"

  for agent in ${SHIPPED_INHERIT_AGENTS}; do
    _shipped_agent_is_active "${agent}" || continue
    expected="${inherit_expected}"
    override="$(_last_override_expectation "${agent}")"
    [[ -n "${override}" ]] && expected="${override}"
    _verify_one_agent_model "${agent}" "${expected}" \
      || failures=$((failures + 1))
  done
  for agent in ${SHIPPED_FIXED_AGENTS}; do
    _shipped_agent_is_active "${agent}" || continue
    expected="${fixed_expected}"
    override="$(_last_override_expectation "${agent}")"
    [[ -n "${override}" ]] && expected="${override}"
    _verify_one_agent_model "${agent}" "${expected}" \
      || failures=$((failures + 1))
  done

  [[ "${failures}" -eq 0 ]]
}

_restore_entry_models() {
  local agent_name entry_model agent_file tmp
  [[ -f "${ENTRY_MODELS:-}" ]] || return 0
  while IFS=$'\t' read -r agent_name entry_model; do
    [[ -n "${agent_name}" && -n "${entry_model}" ]] || continue
    agent_file="${AGENTS_DIR}/${agent_name}"
    [[ -f "${agent_file}" ]] || continue
    [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" ]] \
      || continue
    tmp="${agent_file}.tmp"
    sed "s/^model: .*$/model: ${entry_model}/" "${agent_file}" > "${tmp}"
    mv "${tmp}" "${agent_file}"
  done < "${ENTRY_MODELS}"
}

# ---------------------------------------------------------------------------
# Apply tier
# ---------------------------------------------------------------------------

if ! _preflight_shipped_roster; then
  die "Tier switch aborted before changing files; reinstall oh-my-claude to repair the shipped agent roster."
fi

printf 'Switching to model tier: %s\n' "${TIER}"

# Snapshot entry models so the final summary counts unique files whose
# effective declaration changed, not intermediate reconstruction/rewrite
# operations. The latter can touch one file twice and then an override can put
# it exactly back where it started.
ENTRY_MODELS="$(mktemp "${TMPDIR:-/tmp}/omc-switch-tier-models.XXXXXX")" \
  || die "Cannot create temporary model snapshot."
if ! MODEL_OVERRIDE_EXPECTATIONS="$(mktemp \
    "${TMPDIR:-/tmp}/omc-switch-tier-overrides.XXXXXX")"; then
  rm -f "${ENTRY_MODELS}"
  die "Cannot create temporary override snapshot."
fi
SWITCH_COMMITTED=0
_switch_cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 && "${SWITCH_COMMITTED}" -eq 0 ]]; then
    _restore_entry_models || true
  fi
  rm -f "${ENTRY_MODELS:-}" "${MODEL_OVERRIDE_EXPECTATIONS:-}"
  return "${rc}"
}
trap '_switch_cleanup' EXIT
for agent_file in "${AGENTS_DIR}/"*.md; do
  [[ -f "${agent_file}" ]] || continue
  agent_name="$(basename "${agent_file}")"
  entry_model="$(grep -E '^model: ' "${agent_file}" | head -1 | sed 's/^model: //' || true)"
  printf '%s\t%s\n' "${agent_name}" "${entry_model}" >> "${ENTRY_MODELS}"
done

# The embedded rosters are the canonical declaration source. Rebuild only
# shipped filenames on every transition: this clears removed pins and repairs
# Economy/unknown materialization without a clone, while custom/plugin agents
# retain their author-selected model declaration.
_apply_shipped_tier "${TIER}"

apply_model_overrides "${AGENTS_DIR}" "${CONF_PATH}"

if ! _verify_materialized_tier; then
  die "Tier switch verification failed; restored prior model declarations and left the saved tier unchanged."
fi

# Persist only after every active shipped declaration and materialized bare pin
# matches the composed target. A missing or malformed file can no longer leave
# a false successful tier row behind.
set_conf "model_tier" "${TIER}"
SWITCH_COMMITTED=1

changed=0
while IFS=$'\t' read -r agent_name entry_model; do
  [[ -n "${agent_name}" ]] || continue
  final_model="$(grep -E '^model: ' "${AGENTS_DIR}/${agent_name}" 2>/dev/null \
    | head -1 | sed 's/^model: //' || true)"
  [[ "${final_model}" != "${entry_model}" ]] && changed=$((changed + 1))
done < "${ENTRY_MODELS}"
printf 'Done. %d agent(s) updated to %s tier.\n' "${changed}" "${TIER}"
