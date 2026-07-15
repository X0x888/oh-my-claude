#!/usr/bin/env bash
# Regression net for the fresh-install handoff contract.
#
# Proves the user-visible first-run flow end to end across:
#   1. Manual install.sh + verify.sh
#   2. install-remote.sh bootstrap installs
#   3. AI-assisted install docs (README + AGENTS.md)
#
# The individual pieces already had coverage, but this file closes the
# remaining distribution gap: a professional first-time install must
# end with verifier success, restart guidance, and the exact "What
# next?" handoff instead of only proving those pieces in isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

EXPECTED_WHAT_NEXT="$(cat <<'EOF'
What next?
  /omc-config                             -- inspect/change settings (auto-detects mode)
  /ulw-demo                               -- see quality gates in action (recommended first step)
  /ulw fix the failing test and add regression coverage
                                          -- start real work with full quality enforcement
EOF
)"

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
    printf '  FAIL: %s — needle %q not in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1"
  if eval "$2"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

printf '1. Manual install flow ends with restart + What next handoff\n'

manual_home="${WORK_DIR}/manual-home"
mkdir -p "${manual_home}"

manual_install_output="$(TARGET_HOME="${manual_home}" bash "${REPO_ROOT}/install.sh" 2>&1)"
set +e
manual_verify_output="$(TARGET_HOME="${manual_home}" bash "${REPO_ROOT}/verify.sh" 2>&1)"
manual_verify_rc=$?
set -e

assert_contains "manual install prints canonical restart guidance" \
  "Restart Claude Code (or open a new session) before testing." "${manual_install_output}"
assert_contains "manual install prints single /ulw-demo CTA" \
  "Then run /ulw-demo in the new Claude Code session" "${manual_install_output}"
assert_eq "manual verify exits 0" "0" "${manual_verify_rc}"
assert_contains "manual verify reports Errors: 0" "Errors:        0" "${manual_verify_output}"
assert_contains "manual verify repeats restart guidance" \
  "Restart Claude Code (or open a new session) before testing." "${manual_verify_output}"
assert_contains "manual verify prints What next footer verbatim" \
  "${EXPECTED_WHAT_NEXT}" "${manual_verify_output}"

printf '\n'
printf '2. Bootstrap install surfaces the same first-run handoff\n'

bootstrap_source="${WORK_DIR}/bootstrap-source"
bootstrap_remote="${WORK_DIR}/bootstrap-remote.git"
bootstrap_home="${WORK_DIR}/bootstrap-home"
bootstrap_clone="${bootstrap_home}/.local/share/oh-my-claude"
mkdir -p "${bootstrap_source}" "${bootstrap_home}"

rsync -a --exclude '.git' "${REPO_ROOT}/" "${bootstrap_source}/" >/dev/null
(
  cd "${bootstrap_source}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  git add -A
  git commit --quiet -m "bootstrap handoff fixture"
)
git clone --quiet --bare "${bootstrap_source}" "${bootstrap_remote}"

set +e
bootstrap_output="$(
  HOME="${bootstrap_home}" \
  OMC_SRC_DIR="${bootstrap_clone}" \
  OMC_REPO_URL="${bootstrap_remote}" \
  OMC_REF="main" \
  bash "${REPO_ROOT}/install-remote.sh" 2>&1
)"
bootstrap_rc=$?
set -e

assert_eq "bootstrap fresh install exits 0" "0" "${bootstrap_rc}"
assert_true "bootstrap clone created at canonical path override" \
  "[[ -d '${bootstrap_clone}/.git' ]]"
assert_contains "bootstrap output includes verifier success" \
  "Errors:        0" "${bootstrap_output}"
assert_contains "bootstrap output includes canonical restart guidance" \
  "Restart Claude Code (or open a new session) before testing." "${bootstrap_output}"
assert_contains "bootstrap output includes single /ulw-demo CTA" \
  "Then run /ulw-demo in the new Claude Code session" "${bootstrap_output}"
assert_contains "bootstrap output includes What next footer verbatim" \
  "${EXPECTED_WHAT_NEXT}" "${bootstrap_output}"

printf '\n'
printf '3. AI-assisted install docs preserve the same handoff\n'

readme="$(<"${REPO_ROOT}/README.md")"
agents_md="$(<"${REPO_ROOT}/AGENTS.md")"

assert_contains "README install prompt requires quoting What next verbatim" \
  "quote its \"What next?\" footer back to me verbatim" "${readme}"
assert_contains "README install prompt requires restart + /ulw-demo" \
  "Tell me explicitly to restart Claude Code and run \`/ulw-demo\` in the new session." "${readme}"
assert_contains "AGENTS protocol embeds the canonical What next footer" \
  "${EXPECTED_WHAT_NEXT}" "${agents_md}"
assert_contains "AGENTS protocol embeds the canonical restart instruction" \
  "Restart Claude Code (or open a new session) before testing. Already-running sessions keep the previous hook wiring, so \`/ulw\` will silently no-op until you restart." \
  "${agents_md}"

printf '\n'
printf '4. Invalid saved model tier is reported and repaired without demotion\n'

# Last-row semantics matter for append-updated config files: an invalid newest
# value must not expose an older valid row as though it were still effective.
cat >> "${manual_home}/.claude/oh-my-claude.conf" <<'EOF'
model_tier=quality
model_tier=qualtiy
EOF

set +e
invalid_verify_output="$(TARGET_HOME="${manual_home}" bash "${REPO_ROOT}/verify.sh" 2>&1)"
invalid_verify_rc=$?
set -e

assert_eq "verify accepts invalid saved tier as informational" "0" "${invalid_verify_rc}"
assert_contains "verify warns about invalid last saved tier" \
  "Invalid saved model tier 'qualtiy' ignored; using default: balanced" "${invalid_verify_output}"
assert_contains "verify reports balanced as the effective tier" \
  "Active model tier: balanced (default)" "${invalid_verify_output}"

invalid_install_output="$(TARGET_HOME="${manual_home}" bash "${REPO_ROOT}/install.sh" 2>&1)"
assert_contains "install warns while repairing invalid saved tier" \
  'Invalid saved model tier "qualtiy"; using balanced and repairing oh-my-claude.conf.' \
  "${invalid_install_output}"
assert_eq "install persists one normalized balanced tier" \
  "model_tier=balanced" \
  "$(grep -E '^model_tier=' "${manual_home}/.claude/oh-my-claude.conf" || true)"
assert_eq "invalid saved tier never demotes inherit quality reviewer" \
  "inherit" \
  "$(sed -n 's/^model:[[:space:]]*//p' "${manual_home}/.claude/agents/quality-reviewer.md" | head -1)"

printf '\n'
printf '5. Economy install and reinstall preserve inherited composition\n'

economy_home="${WORK_DIR}/economy-home"
mkdir -p "${economy_home}"
economy_install_output="$(TARGET_HOME="${economy_home}" \
  bash "${REPO_ROOT}/install.sh" --model-tier=economy 2>&1)"
economy_inherit_count="$({ grep -h '^model: inherit$' \
  "${economy_home}/.claude/agents/"*.md || true; } | wc -l | tr -d '[:space:]')"
economy_sonnet_count="$({ grep -h '^model: sonnet$' \
  "${economy_home}/.claude/agents/"*.md || true; } | wc -l | tr -d '[:space:]')"
assert_eq "economy fresh install keeps inherited deliberators" \
  "14" "${economy_inherit_count}"
assert_eq "economy fresh install keeps Sonnet specialists" \
  "23" "${economy_sonnet_count}"
assert_contains "economy install summary describes composed fallback" \
  "economy (inherit deliberators, sonnet specialists; adaptive live escalation" \
  "${economy_install_output}"

# Simulate a legacy flattened declaration, add a user custom definition, and
# persist a valid bare inherit pin. Reinstall reads the saved Economy tier,
# repairs the shipped roster, materializes the shipped pin, and leaves custom
# files outside the embedded rosters untouched even when explicitly pinned.
sed 's/^model: inherit$/model: sonnet/' \
  "${economy_home}/.claude/agents/quality-reviewer.md" \
  > "${economy_home}/.claude/agents/quality-reviewer.md.tmp"
mv "${economy_home}/.claude/agents/quality-reviewer.md.tmp" \
  "${economy_home}/.claude/agents/quality-reviewer.md"
cat >> "${economy_home}/.claude/oh-my-claude.conf" <<'EOF'
model_overrides=librarian:inherit,duplicate-custom:opus
EOF
printf -- '---\nname: custom-economy\nmodel: haiku\n---\nbody\n' \
  > "${economy_home}/.claude/agents/custom-economy.md"
printf -- '---\nname: duplicate-custom\nmodel: sonnet\nmodel: haiku\n---\nbody\n' \
  > "${economy_home}/.claude/agents/duplicate-custom.md"
economy_reinstall_output="$(TARGET_HOME="${economy_home}" \
  bash "${REPO_ROOT}/install.sh" 2>&1)"
assert_eq "economy reinstall repairs flattened reviewer" "inherit" \
  "$(sed -n 's/^model:[[:space:]]*//p' \
    "${economy_home}/.claude/agents/quality-reviewer.md" | head -1)"
assert_eq "economy reinstall materializes bare inherit override" "inherit" \
  "$(sed -n 's/^model:[[:space:]]*//p' \
    "${economy_home}/.claude/agents/librarian.md" | head -1)"
assert_eq "economy reinstall preserves custom agent model" "haiku" \
  "$(sed -n 's/^model:[[:space:]]*//p' \
    "${economy_home}/.claude/agents/custom-economy.md" | head -1)"
assert_contains "economy reinstall keeps custom pins runtime-only" \
  "runtime-only duplicate-custom — custom bare pin is enforced at dispatch; custom definitions are never rewritten" \
  "${economy_reinstall_output}"
assert_eq "runtime-only duplicate custom definition remains unmodified" "2" \
  "$(grep -c '^model: ' \
    "${economy_home}/.claude/agents/duplicate-custom.md")"
economy_verify_output="$(TARGET_HOME="${economy_home}" \
  bash "${REPO_ROOT}/verify.sh" 2>&1)"
assert_contains "verify census includes Haiku and invalid/other models" \
  "Agent models: 15 inherit (session model), 0 opus, 22 sonnet, 1 haiku, 1 invalid/other (total 39)" \
  "${economy_verify_output}"

printf '\n=== Install handoff tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
