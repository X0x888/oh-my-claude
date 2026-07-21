#!/usr/bin/env bash
set -euo pipefail

# Tests for uninstall.sh's settings-cleanup logic (clean_settings_python
# and clean_settings_jq). Focus is null-safety parity with install.sh's
# merger — an explicit `null` at any of hooks/<event>/entries/hook/
# command must not crash Python and must produce byte-identical output
# across both implementations.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_PATCH="${REPO_ROOT}/config/settings.patch.json"
# Extracted cleaner functions consume the install-time private snapshot path.
# Unit-level calls use the immutable repository fixture directly; full-script
# races below exercise snapshot creation/sealing/cleanup.
SETTINGS_PATCH_SNAPSHOT="${SETTINGS_PATCH}"

pass=0
fail=0

TEST_DIR_RAW="$(mktemp -d)"
TEST_DIR="$(cd "${TEST_DIR_RAW}" && pwd -P)"
cleanup() { rm -rf "${TEST_DIR}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_json_eq() {
  local label="$1"
  local file="$2"
  local query="$3"
  local expected="$4"
  local actual
  actual="$(jq -r "${query}" "${file}" 2>/dev/null || echo "__JQ_ERROR__")"
  assert_eq "${label}" "${expected}" "${actual}"
}

sha256_path() {
  local path="${1:-}"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "${path}" | awk '{print $1}'
  else
    sha256sum -- "${path}" | awk '{print $1}'
  fi
}

node_identity_path() {
  local path="${1:-}"
  if stat -c '%d:%i' "${path}" >/dev/null 2>&1; then
    stat -c '%d:%i' "${path}"
  else
    stat -f '%d:%i' "${path}"
  fi
}

mode_path() {
  local path="${1:-}"
  if stat -c '%a' "${path}" >/dev/null 2>&1; then
    stat -c '%a' "${path}"
  else
    stat -f '%Lp' "${path}"
  fi
}

# ---------------------------------------------------------------------------
# Extract clean functions from uninstall.sh and merger from install.sh
# (the merger is used to build realistic pre-uninstall fixtures).
# ---------------------------------------------------------------------------

eval "$(sed -n '/^clean_settings_python()/,/^}$/p' "${REPO_ROOT}/uninstall.sh")"
eval "$(sed -n '/^clean_settings_jq()/,/^}$/p' "${REPO_ROOT}/uninstall.sh")"
eval "$(sed -n '/^merge_settings_python()/,/^}$/p' "${REPO_ROOT}/install.sh")"
eval "$(sed -n '/^merge_settings_jq()/,/^}$/p' "${REPO_ROOT}/install.sh")"

declare -f clean_settings_python >/dev/null || { echo "ERROR: clean_settings_python extraction failed" >&2; exit 1; }
declare -f clean_settings_jq >/dev/null || { echo "ERROR: clean_settings_jq extraction failed" >&2; exit 1; }
declare -f merge_settings_python >/dev/null || { echo "ERROR: merge_settings_python extraction failed" >&2; exit 1; }

implementations=()
if command -v python3 >/dev/null 2>&1; then implementations+=("python"); fi
if command -v jq >/dev/null 2>&1; then implementations+=("jq"); fi
if [[ ${#implementations[@]} -eq 0 ]]; then
  printf 'ERROR: Need python3 or jq to run uninstall tests.\n' >&2
  exit 1
fi

run_clean() {
  local impl="$1"
  SETTINGS="$2"
  if [[ "${impl}" == "python" ]]; then
    clean_settings_python
  else
    clean_settings_jq
  fi
}

# ===========================================================================
# Test suite — run once per available implementation
# ===========================================================================

for impl in "${implementations[@]}"; do
  printf 'Testing %s implementation...\n' "${impl}"

  # -------------------------------------------------------------------------
  # Test 1: Valid uninstall — a fully-installed fresh state cleans out all
  # oh-my-claude hooks, statusLine, outputStyle, etc. Built by running the
  # install merger against an empty base, then uninstalling.
  # -------------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-fresh"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  printf '{}' > "${SETTINGS}"
  merge_settings_python "${SETTINGS}" "${SETTINGS_PATCH}" "false"
  # Confirm the install landed
  assert_json_eq "${impl}: fresh install — SubagentStop count is 12" \
    "${SETTINGS}" '.hooks.SubagentStop | length' "12"
  assert_json_eq "${impl}: fresh install — native SubagentStart binder count is 1" \
    "${SETTINGS}" '.hooks.SubagentStart | length' "1"
  assert_json_eq "${impl}: fresh install — native binder command is present" \
    "${SETTINGS}" \
    '[.hooks.SubagentStart[].hooks[].command | select(contains("record-pending-agent.sh start"))] | length' \
    "1"
  assert_json_eq "${impl}: fresh install — one closeout display hook" \
    "${SETTINGS}" '.hooks.MessageDisplay | length' "1"
  assert_json_eq "${impl}: fresh install — one closeout preflight hook" \
    "${SETTINGS}" '.hooks.PostToolBatch | length' "1"
  assert_json_eq "${impl}: fresh install — one ordered Stop dispatcher" \
    "${SETTINGS}" \
    '[.hooks.Stop[].hooks[].command | select(contains("stop-dispatch.sh"))] | length' \
    "1"

  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: valid uninstall — hooks removed" \
    "${SETTINGS}" '.hooks // "absent"' "absent"
  assert_json_eq "${impl}: valid uninstall — statusLine removed" \
    "${SETTINGS}" '.statusLine // "absent"' "absent"
  assert_json_eq "${impl}: valid uninstall — outputStyle removed" \
    "${SETTINGS}" '.outputStyle // "absent"' "absent"

  # -------------------------------------------------------------------------
  # Test 2: User customization preserved — a user matcher pointing to a
  # non-OMC script survives the uninstall cleanly.
  # -------------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-user-custom"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "my-custom-matcher",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/my-custom-hook.sh"}
        ]
      },
      {
        "matcher": "editor-critic",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose"}
        ]
      }
    ]
  }
}
JSON
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: user custom — my-custom-matcher preserved" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "my-custom-matcher")] | length' \
    "1"
  assert_json_eq "${impl}: user custom — editor-critic OMC entry removed" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "0"

  # -------------------------------------------------------------------------
  # Test 3: Mixed-hook entry — remove the managed hook at hook granularity
  # while preserving the entry, matcher, and foreign hook.
  # -------------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-mixed"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},
          {"type": "command", "command": "$HOME/.claude/my-user-logger.sh"}
        ]
      }
    ]
  }
}
JSON
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: mixed — entry preserved for foreign hook" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"
  assert_json_eq "${impl}: mixed — managed reviewer removed individually" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | select((.command // "") | contains("record-reviewer.sh"))] | length' \
    "0"
  assert_json_eq "${impl}: mixed — user-logger.sh still present" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("my-user-logger.sh"))' \
    "true"

  # Every current patch command is owned byte-for-byte. Alternate roots,
  # suffix lookalikes, and managed-looking later argv are foreign and survive.
  work="${TEST_DIR}/${impl}-exact-identity"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "hooks": {
    "SubagentStop": [{
      "matcher": "editor-critic",
      "hooks": [
        {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose"},
        {"type":"command","command":"/opt/acme/record-reviewer.sh prose"},
        {"type":"command","command":"/tmp/alternate/.claude/skills/autowork/scripts/record-reviewer.sh prose"},
        {"type":"command","command":"bash /tmp/evil.sh $HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose"},
        {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose --custom"}
      ]
    }],
    "PostToolBatch": [{"hooks": [
      {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/closeout-preflight.sh --posttool-batch"},
      {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/closeout-preflight.sh"}
    ]}]
  },
  "statusLine": {"type":"command","command":"/opt/acme/statusline.py","padding":0}
}
JSON
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: exact identity removes only canonical managed reviewer" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[].hooks[] | select((.command // "") == "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose")] | length' \
    "0"
  assert_json_eq "${impl}: exact identity preserves spoof/decoy/extra-argv hooks" \
    "${SETTINGS}" '.hooks.SubagentStop[0].hooks | length' "4"
  assert_json_eq "${impl}: exact identity removes flagged preflight but preserves omitted-arg invocation" \
    "${SETTINGS}" '.hooks.PostToolBatch[0].hooks[0].command' \
    '$HOME/.claude/skills/autowork/scripts/closeout-preflight.sh'
  assert_json_eq "${impl}: foreign same-basename statusLine survives" \
    "${SETTINGS}" '.statusLine.command' "/opt/acme/statusline.py"

  work="${TEST_DIR}/${impl}-statusline-object"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.py",
    "padding": 7
  }
}
JSON
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: customized statusLine object is not claimed" \
    "${SETTINGS}" '.statusLine.padding' "7"

  work="${TEST_DIR}/${impl}-historical-exact"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [
      {"type":"command","command":"bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-resume.sh"},
      {"type":"command","command":"bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh"},
      {"type":"command","command":"sh $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh"}
    ]}]
  }
}
JSON
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: exact historical cleanup commands are removed" \
    "${SETTINGS}" \
    '[.hooks.SessionStart[].hooks[] | select((.command // "") | startswith("bash $HOME/.claude/quality-pack/scripts/cleanup-orphan"))] | length' \
    "0"
  assert_json_eq "${impl}: never-emitted sh cleanup wrapper survives" \
    "${SETTINGS}" '.hooks.SessionStart[0].hooks[0].command' \
    'sh $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh'

  # -------------------------------------------------------------------------
  # Test 4: Null-safety at every position — Python must not crash. Uninstall
  # parity fix. Matches install.sh's Test 11/Test 12 coverage for symmetry.
  # -------------------------------------------------------------------------
  for fixture in 'null_hooks' 'null_event' 'null_entry' 'null_hook_in_entry' 'null_command' 'null_matcher'; do
    work="${TEST_DIR}/${impl}-${fixture}"
    mkdir -p "${work}"
    SETTINGS="${work}/settings.json"
    case "${fixture}" in
      null_hooks)
        printf '%s' '{"hooks": null}' > "${SETTINGS}"
        ;;
      null_event)
        printf '%s' '{"hooks": {"SubagentStop": null}}' > "${SETTINGS}"
        ;;
      null_entry)
        printf '%s' '{"hooks": {"SubagentStop": [null]}}' > "${SETTINGS}"
        ;;
      null_hook_in_entry)
        printf '%s' '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[null]}]}}' > "${SETTINGS}"
        ;;
      null_command)
        printf '%s' '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"command":null}]}]}}' > "${SETTINGS}"
        ;;
      null_matcher)
        printf '%s' '{"hooks": {"SubagentStop": [{"matcher":null,"hooks":[{"command":"$HOME/.claude/x.sh"}]}]}}' > "${SETTINGS}"
        ;;
    esac
    if run_clean "${impl}" "${SETTINGS}" 2>/dev/null; then
      pass=$((pass + 1))
    else
      printf '  FAIL: %s: %s — clean crashed\n' "${impl}" "${fixture}" >&2
      fail=$((fail + 1))
    fi
  done

  # -------------------------------------------------------------------------
  # F-010: in-place customized outputStyle name. The user followed the
  # docs/customization.md L373 advice and edited the bundled file's
  # frontmatter `name:` to "oh-my-claude v2", then updated their
  # settings.json to match. uninstall.sh captures the actual frontmatter
  # name BEFORE removing the file and exports OMC_BUNDLED_STYLE_NAME.
  # The cleanup must use that captured name for value-gating, otherwise
  # the file is removed but the orphaned outputStyle entry is left
  # pointing at a missing style.
  # -------------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-customized-name"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "outputStyle": "oh-my-claude v2"
}
JSON
  OMC_BUNDLED_STYLE_NAME="oh-my-claude v2" run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: F-010 — customized name removed via captured frontmatter" \
    "${SETTINGS}" '.outputStyle // "absent"' "absent"

  # -------------------------------------------------------------------------
  # F-010 negative: a user with a totally separate outputStyle (e.g.
  # "Learning") must NOT have their setting removed when our captured
  # name does not match. Confirms value-gating still preserves user data.
  # -------------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-separate-style"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "outputStyle": "Learning"
}
JSON
  OMC_BUNDLED_STYLE_NAME="oh-my-claude" run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: F-010 — non-matching user style preserved" \
    "${SETTINGS}" '.outputStyle' "Learning"

  # -------------------------------------------------------------------------
  # F-010b: Legacy "OpenCode Compact" in settings.json is cleaned up by
  # uninstall even though the bundled file now says "oh-my-claude".
  # Covers the upgrade path where a user never re-ran install.sh after
  # the rename but later runs uninstall.
  # -------------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-legacy-name-cleanup"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  cat > "${SETTINGS}" <<'JSON'
{
  "outputStyle": "OpenCode Compact"
}
JSON
  OMC_BUNDLED_STYLE_NAME="oh-my-claude" run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: F-010b — legacy OpenCode Compact removed by uninstall" \
    "${SETTINGS}" '.outputStyle // "absent"' "absent"

  # Bypass mode is harness-owned only at its exact values. Removing the gates
  # while leaving Claude Code globally bypassed would be an unsafe uninstall.
  work="${TEST_DIR}/${impl}-bypass-cleanup"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  printf '%s\n' \
    '{"permissions":{"defaultMode":"bypassPermissions","allow":["Read"]},"skipDangerousModePermissionPrompt":true}' \
    > "${SETTINGS}"
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: bypass defaultMode is removed" \
    "${SETTINGS}" '.permissions.defaultMode // "absent"' "absent"
  assert_json_eq "${impl}: bypass permission siblings survive" \
    "${SETTINGS}" '.permissions.allow[0]' "Read"
  assert_json_eq "${impl}: dangerous-mode skip is removed" \
    "${SETTINGS}" '.skipDangerousModePermissionPrompt // "absent"' "absent"

  work="${TEST_DIR}/${impl}-foreign-permission-mode"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  printf '%s\n' \
    '{"permissions":{"defaultMode":"acceptEdits"},"skipDangerousModePermissionPrompt":false}' \
    > "${SETTINGS}"
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: foreign permission mode survives" \
    "${SETTINGS}" '.permissions.defaultMode' "acceptEdits"
  assert_json_eq "${impl}: foreign dangerous-mode false survives" \
    "${SETTINGS}" '.skipDangerousModePermissionPrompt' "false"

  # Exact spinner ownership preserves user arrays that merely collapse to the
  # same set. Python formerly removed duplicates while jq preserved them.
  work="${TEST_DIR}/${impl}-duplicate-spinner-verbs"
  mkdir -p "${work}"
  SETTINGS="${work}/settings.json"
  printf '%s\n' \
    '{"spinnerVerbs":{"mode":"replace","verbs":["Inspecting","Sketching","Refining","Verifying","Inspecting"]}}' \
    > "${SETTINGS}"
  run_clean "${impl}" "${SETTINGS}"
  assert_json_eq "${impl}: duplicate spinner customization survives" \
    "${SETTINGS}" '.spinnerVerbs.verbs | length' "5"

  printf '  %s implementation done.\n' "${impl}"
done

# ===========================================================================
# Cross-implementation parity
# ===========================================================================

if [[ ${#implementations[@]} -eq 2 ]]; then
  printf 'Testing cross-implementation consistency...\n'

  cross_assert() {
    local label="$1"
    local fixture_json="$2"
    local py_path="${TEST_DIR}/cross-py-${label//[^a-zA-Z0-9]/-}"
    local jq_path="${TEST_DIR}/cross-jq-${label//[^a-zA-Z0-9]/-}"
    printf '%s\n' "${fixture_json}" > "${py_path}"
    printf '%s\n' "${fixture_json}" > "${jq_path}"
    SETTINGS="${py_path}"; clean_settings_python 2>/dev/null || true
    SETTINGS="${jq_path}"; clean_settings_jq 2>/dev/null || true
    if diff <(jq -S . "${py_path}" 2>/dev/null) <(jq -S . "${jq_path}" 2>/dev/null) >/dev/null 2>&1; then
      pass=$((pass + 1))
    else
      printf '  FAIL: cross: %s — python and jq diverge\n' "${label}" >&2
      diff <(jq -S . "${py_path}" 2>/dev/null) <(jq -S . "${jq_path}" 2>/dev/null) >&2 || true
      fail=$((fail + 1))
    fi
  }

  cross_assert "hooks-null" '{"hooks": null}'
  cross_assert "event-null" '{"hooks": {"SubagentStop": null}}'
  cross_assert "null-entry" '{"hooks": {"SubagentStop": [null]}}'
  cross_assert "null-hook-in-entry" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[null]}]}}'
  cross_assert "null-command" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"command":null}]}]}}'
  cross_assert "numeric-command" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"command":42}]}]}}'
  cross_assert "valid-omc-hook" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"type":"command","command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose"}]}]}}'
  cross_assert "valid-user-hook" '{"hooks": {"SubagentStop": [{"matcher":"my-custom","hooks":[{"type":"command","command":"$HOME/.claude/user.sh"}]}]}}'
  cross_assert "mixed-omc-and-user" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},{"command":"$HOME/.claude/user.sh"}]}]}}'
  cross_assert "managed-entry-with-empty-foreign-sibling" '{"hooks":{"SubagentStop":[{"matcher":"editor-critic","hooks":[{"command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose"}]},{"matcher":"foreign-empty","hooks":[]}]}}'
  cross_assert "foreign-wrapper-and-extra-argv" '{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"command":"exec -a decoy.sh bash $HOME/.claude/skills/autowork/scripts/posttool-dispatch.sh"},{"command":"$HOME/.claude/skills/autowork/scripts/posttool-dispatch.sh --custom"}]}]}}'
  cross_assert "foreign-statusline-same-basename" '{"statusLine":{"type":"command","command":"/opt/acme/statusline.py","padding":0}}'
  cross_assert "bypass-cleanup-with-sibling" '{"permissions":{"defaultMode":"bypassPermissions","allow":["Read"]},"skipDangerousModePermissionPrompt":true}'
  cross_assert "foreign-permission-mode" '{"permissions":{"defaultMode":"acceptEdits"},"skipDangerousModePermissionPrompt":false}'
  cross_assert "duplicate-spinner-verbs" '{"spinnerVerbs":{"mode":"replace","verbs":["Inspecting","Sketching","Refining","Verifying","Inspecting"]}}'

  printf '  Cross-implementation tests done.\n'
fi

# ===========================================================================
# User-owned Quality Constitution lifecycle
# ===========================================================================

printf 'Testing Quality Constitution preservation and explicit purge...\n'
constitution_home="${TEST_DIR}/constitution-lifecycle"
constitution_file="${constitution_home}/.claude/omc-user/quality-constitutions/profiles/default/constitution.json"
mkdir -p "$(dirname "${constitution_file}")" \
  "${constitution_home}/.claude/quality-pack"
printf '%s\n' '{"schema_version":1,"profile":"default"}' > "${constitution_file}"

ordinary_out="$(HOME="${constitution_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)"
assert_eq "ordinary uninstall removes managed quality-pack" "false" \
  "$([[ -e "${constitution_home}/.claude/quality-pack" ]] && printf true || printf false)"
assert_eq "ordinary uninstall preserves user-owned Constitution" "true" \
  "$([[ -f "${constitution_file}" ]] && printf true || printf false)"
assert_eq "ordinary uninstall summary tells the truth" "1" \
  "$(grep -c 'Quality Constitution data was preserved' <<<"${ordinary_out}" || true)"

# The managed harness is now gone. A later explicit purge must still work as
# a first-class operation rather than returning the generic Nothing-to-do path.
purge_out="$(HOME="${constitution_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes --purge-quality-constitutions 2>&1)"
assert_eq "purge-only after uninstall removes Constitution root" "false" \
  "$([[ -e "${constitution_home}/.claude/omc-user/quality-constitutions" ]] && printf true || printf false)"
assert_eq "purge-only summary tells the truth" "1" \
  "$(grep -c 'Quality Constitution data was explicitly purged' <<<"${purge_out}" || true)"
assert_eq "purge-only path does not claim Nothing to do" "0" \
  "$(grep -c 'Nothing to do' <<<"${purge_out}" || true)"

# Purge refusal must happen before any managed uninstall mutation, and no
# ancestor symlink may redirect the recursive delete outside ~/.claude.
ancestor_home="${TEST_DIR}/constitution-ancestor-symlink"
ancestor_external="${TEST_DIR}/constitution-ancestor-external"
mkdir -p "${ancestor_home}/.claude/quality-pack" \
  "${ancestor_external}/quality-constitutions/profiles/default"
printf 'managed\n' >"${ancestor_home}/.claude/quality-pack/marker"
printf 'external\n' \
  >"${ancestor_external}/quality-constitutions/profiles/default/constitution.json"
ln -s "${ancestor_external}" "${ancestor_home}/.claude/omc-user"
ancestor_rc=0
ancestor_out="$(HOME="${ancestor_home}" bash "${REPO_ROOT}/uninstall.sh" \
  --yes --purge-quality-constitutions 2>&1)" || ancestor_rc=$?
assert_eq "ancestor symlink purge is refused" "1" "${ancestor_rc}"
assert_eq "ancestor symlink cannot delete external Constitution" "true" \
  "$([[ -f "${ancestor_external}/quality-constitutions/profiles/default/constitution.json" ]] \
    && printf true || printf false)"
assert_eq "ancestor refusal leaves managed harness untouched" "true" \
  "$([[ -f "${ancestor_home}/.claude/quality-pack/marker" ]] && printf true || printf false)"
assert_eq "ancestor refusal names unsafe component" "1" \
  "$(grep -c 'symlinked path component' <<<"${ancestor_out}" || true)"

target_alias="${TEST_DIR}/constitution-target-home-alias"
target_external="${TEST_DIR}/constitution-target-home-external"
mkdir -p "${target_external}/.claude/omc-user/quality-constitutions/profiles/default" \
  "${target_external}/.claude/quality-pack"
printf 'external\n' \
  >"${target_external}/.claude/omc-user/quality-constitutions/profiles/default/constitution.json"
printf 'managed\n' >"${target_external}/.claude/quality-pack/marker"
ln -s "${target_external}" "${target_alias}"
target_alias_rc=0
target_alias_out="$(TARGET_HOME="${target_alias}" HOME="${TEST_DIR}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes --purge-quality-constitutions 2>&1)" \
  || target_alias_rc=$?
assert_eq "TARGET_HOME symlink ancestor purge is refused" "1" "${target_alias_rc}"
assert_eq "TARGET_HOME symlink cannot delete external Constitution" "true" \
  "$([[ -f "${target_external}/.claude/omc-user/quality-constitutions/profiles/default/constitution.json" ]] \
    && printf true || printf false)"
assert_eq "TARGET_HOME refusal leaves managed harness untouched" "true" \
  "$([[ -f "${target_external}/.claude/quality-pack/marker" ]] && printf true || printf false)"
assert_eq "TARGET_HOME refusal names unsafe component" "1" \
  "$(grep -c 'symlinked path component' <<<"${target_alias_out}" || true)"

leaf_home="${TEST_DIR}/constitution-leaf-symlink"
leaf_external="${TEST_DIR}/constitution-leaf-external"
mkdir -p "${leaf_home}/.claude/omc-user" "${leaf_home}/.claude/quality-pack" \
  "${leaf_external}/profiles/default"
printf 'managed\n' >"${leaf_home}/.claude/quality-pack/marker"
printf 'external\n' >"${leaf_external}/profiles/default/constitution.json"
ln -s "${leaf_external}" "${leaf_home}/.claude/omc-user/quality-constitutions"
leaf_rc=0
leaf_out="$(HOME="${leaf_home}" bash "${REPO_ROOT}/uninstall.sh" \
  --yes --purge-quality-constitutions 2>&1)" || leaf_rc=$?
assert_eq "leaf symlink purge is refused" "1" "${leaf_rc}"
assert_eq "leaf symlink cannot delete external Constitution" "true" \
  "$([[ -f "${leaf_external}/profiles/default/constitution.json" ]] && printf true || printf false)"
assert_eq "leaf refusal leaves managed harness untouched" "true" \
  "$([[ -f "${leaf_home}/.claude/quality-pack/marker" ]] && printf true || printf false)"
assert_eq "leaf refusal names unsafe component" "1" \
  "$(grep -c 'symlinked path component' <<<"${leaf_out}" || true)"

nondir_home="${TEST_DIR}/constitution-leaf-file"
mkdir -p "${nondir_home}/.claude/omc-user" "${nondir_home}/.claude/quality-pack"
printf 'managed\n' >"${nondir_home}/.claude/quality-pack/marker"
printf 'not a directory\n' >"${nondir_home}/.claude/omc-user/quality-constitutions"
nondir_rc=0
nondir_out="$(HOME="${nondir_home}" bash "${REPO_ROOT}/uninstall.sh" \
  --yes --purge-quality-constitutions 2>&1)" || nondir_rc=$?
assert_eq "non-directory purge is refused" "1" "${nondir_rc}"
assert_eq "non-directory refusal leaves managed harness untouched" "true" \
  "$([[ -f "${nondir_home}/.claude/quality-pack/marker" ]] && printf true || printf false)"
assert_eq "non-directory refusal names unsafe component" "1" \
  "$(grep -c 'non-directory path component' <<<"${nondir_out}" || true)"

purge_race_home="${TEST_DIR}/constitution-descendant-race"
purge_race_root="${purge_race_home}/.claude/omc-user/quality-constitutions"
purge_race_ready="${TEST_DIR}/constitution-descendant.ready"
purge_race_release="${TEST_DIR}/constitution-descendant.release"
mkdir -p "${purge_race_root}/profiles/default" \
  "${purge_race_home}/.claude/quality-pack"
printf 'managed\n' > "${purge_race_home}/.claude/quality-pack/marker"
printf 'original\n' > "${purge_race_root}/profiles/default/constitution.json"
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_REMOVE_MATCH="${purge_race_root}" \
  OMC_TEST_UNINSTALL_REMOVE_READY_FILE="${purge_race_ready}" \
  OMC_TEST_UNINSTALL_REMOVE_RELEASE_FILE="${purge_race_release}" \
  HOME="${purge_race_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
    --purge-quality-constitutions >/dev/null 2>&1
) &
purge_race_pid=$!
purge_race_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${purge_race_ready}" ]] \
    && { purge_race_seen=1; break; }
  sleep 0.01
done
assert_eq "Constitution purge reaches exact-tree barrier" "1" \
  "${purge_race_seen}"
if [[ "${purge_race_seen}" -eq 1 ]]; then
  printf 'new-user-evidence\n' > "${purge_race_root}/concurrent-evidence"
fi
: > "${purge_race_release}"
purge_race_rc=0
wait "${purge_race_pid}" || purge_race_rc=$?
assert_eq "new Constitution descendant aborts purge" "1" "${purge_race_rc}"
assert_eq "concurrent Constitution evidence survives refused purge" \
  "new-user-evidence" \
  "$(cat "${purge_race_root}/concurrent-evidence" 2>/dev/null || true)"
assert_eq "purge race leaves managed harness untouched" "true" \
  "$([[ -f "${purge_race_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"

# settings.patch.json is now the exact ownership authority for managed hooks.
# Missing or malformed authority must fail before any harness file is removed,
# rather than producing a half-uninstalled tree and only then exiting nonzero.
for patch_case in missing malformed invalid-command; do
  preflight_home="${TEST_DIR}/settings-patch-preflight-${patch_case}"
  preflight_patch="${TEST_DIR}/${patch_case}-settings.patch.json"
  mkdir -p "${preflight_home}/.claude/quality-pack"
  printf 'managed\n' >"${preflight_home}/.claude/quality-pack/marker"
  printf '%s\n' '{}' >"${preflight_home}/.claude/settings.json"
  case "${patch_case}" in
    malformed)
      printf '%s\n' '{"hooks":42}' >"${preflight_patch}"
      ;;
    invalid-command)
      printf '%s\n' \
        '{"statusLine":{},"spinnerVerbs":{},"spinnerTipsEnabled":true,"effortLevel":"high","hooks":{"Stop":[{"hooks":[{"type":"command","command":null}]}]}}' \
        >"${preflight_patch}"
      ;;
  esac
  patch_preflight_rc=0
  patch_preflight_out="$(HOME="${preflight_home}" \
    OMC_TEST_UNINSTALL_ALLOW_SETTINGS_PATCH=1 \
    OMC_TEST_UNINSTALL_SETTINGS_PATCH="${preflight_patch}" \
    bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || patch_preflight_rc=$?
  assert_eq "${patch_case} settings patch is refused before uninstall" "1" \
    "${patch_preflight_rc}"
  assert_eq "${patch_case} settings patch leaves managed harness untouched" "true" \
    "$([[ -f "${preflight_home}/.claude/quality-pack/marker" ]] \
      && printf true || printf false)"
  assert_eq "${patch_case} settings patch reports atomic refusal" "1" \
    "$(grep -c 'No managed files were removed' <<<"${patch_preflight_out}" || true)"
done

# Production callers cannot redirect hook-ownership authority with an ambient
# SETTINGS_PATCH variable. Only the explicit test seam above is honored.
ambient_patch_home="${TEST_DIR}/ambient-settings-patch-ignored"
ambient_patch="${TEST_DIR}/ambient-malformed-settings.patch.json"
mkdir -p "${ambient_patch_home}/.claude/quality-pack"
printf 'managed\n' > "${ambient_patch_home}/.claude/quality-pack/marker"
printf '{}\n' > "${ambient_patch_home}/.claude/settings.json"
printf '{malformed\n' > "${ambient_patch}"
ambient_patch_rc=0
HOME="${ambient_patch_home}" SETTINGS_PATCH="${ambient_patch}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes >/dev/null 2>&1 \
  || ambient_patch_rc=$?
assert_eq "ambient SETTINGS_PATCH cannot redirect production authority" \
  "0" "${ambient_patch_rc}"
assert_eq "ambient SETTINGS_PATCH does not block managed removal" "false" \
  "$([[ -e "${ambient_patch_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"

malformed_settings_home="${TEST_DIR}/malformed-settings-preflight"
mkdir -p "${malformed_settings_home}/.claude/quality-pack"
printf 'managed\n' >"${malformed_settings_home}/.claude/quality-pack/marker"
printf '%s\n' '{not-json' >"${malformed_settings_home}/.claude/settings.json"
malformed_settings_rc=0
malformed_settings_out="$(HOME="${malformed_settings_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || malformed_settings_rc=$?
assert_eq "malformed settings are refused before uninstall" "1" \
  "${malformed_settings_rc}"
assert_eq "malformed settings leave managed harness untouched" "true" \
  "$([[ -f "${malformed_settings_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "malformed settings report atomic refusal" "1" \
  "$(grep -c 'No managed files were removed' <<<"${malformed_settings_out}" || true)"

malformed_shape_home="${TEST_DIR}/malformed-settings-shape-preflight"
mkdir -p "${malformed_shape_home}/.claude/quality-pack"
printf 'managed\n' >"${malformed_shape_home}/.claude/quality-pack/marker"
printf '%s\n' '{"hooks":{"Stop":42}}' \
  >"${malformed_shape_home}/.claude/settings.json"
malformed_shape_rc=0
malformed_shape_out="$(HOME="${malformed_shape_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || malformed_shape_rc=$?
assert_eq "malformed settings shape is refused before uninstall" "1" \
  "${malformed_shape_rc}"
assert_eq "malformed settings shape leaves managed harness untouched" "true" \
  "$([[ -f "${malformed_shape_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "malformed settings shape reports atomic refusal" "1" \
  "$(grep -c 'No managed files were removed' <<<"${malformed_shape_out}" || true)"

malformed_spinner_home="${TEST_DIR}/malformed-spinner-preflight"
mkdir -p "${malformed_spinner_home}/.claude/quality-pack"
printf 'managed\n' >"${malformed_spinner_home}/.claude/quality-pack/marker"
printf '%s\n' '{"spinnerVerbs":{"mode":"replace","verbs":"not-an-array"}}' \
  >"${malformed_spinner_home}/.claude/settings.json"
malformed_spinner_rc=0
malformed_spinner_out="$(HOME="${malformed_spinner_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || malformed_spinner_rc=$?
assert_eq "malformed replacement spinner is refused before uninstall" "1" \
  "${malformed_spinner_rc}"
assert_eq "malformed replacement spinner leaves harness untouched" "true" \
  "$([[ -f "${malformed_spinner_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "malformed replacement spinner reports atomic refusal" "1" \
  "$(grep -c 'No managed files were removed' <<<"${malformed_spinner_out}" || true)"

# Existing settings nodes are classified before open(): special/dangling nodes
# must fail without blocking and without removing a single harness file.
for unsafe_kind in fifo directory dangling-symlink; do
  unsafe_home="${TEST_DIR}/unsafe-settings-${unsafe_kind}"
  mkdir -p "${unsafe_home}/.claude/quality-pack"
  printf 'managed\n' > "${unsafe_home}/.claude/quality-pack/marker"
  case "${unsafe_kind}" in
    fifo) mkfifo "${unsafe_home}/.claude/settings.json" ;;
    directory) mkdir "${unsafe_home}/.claude/settings.json" ;;
    dangling-symlink)
      ln -s "${unsafe_home}/missing-settings-target.json" \
        "${unsafe_home}/.claude/settings.json"
      ;;
  esac
  unsafe_rc=0
  unsafe_out="$(HOME="${unsafe_home}" bash "${REPO_ROOT}/uninstall.sh" \
    --yes 2>&1)" || unsafe_rc=$?
  assert_eq "${unsafe_kind} settings node is refused" "1" "${unsafe_rc}"
  assert_eq "${unsafe_kind} settings node leaves harness untouched" "true" \
    "$([[ -f "${unsafe_home}/.claude/quality-pack/marker" ]] \
      && printf true || printf false)"
  assert_eq "${unsafe_kind} settings node is named" "1" \
    "$(grep -c 'dangling or not a regular file' <<<"${unsafe_out}" || true)"
done

# A common dotfiles layout symlinks settings.json to a regular file. Cleanup
# publishes to that physical target and never replaces the lexical link.
linked_home="${TEST_DIR}/linked-settings-home"
linked_target_dir="${TEST_DIR}/linked-settings-target"
mkdir -p "${linked_home}/.claude/quality-pack" "${linked_target_dir}"
printf 'managed\n' > "${linked_home}/.claude/quality-pack/marker"
printf '%s\n' \
  '{"userKey":"keep","hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/skills/autowork/scripts/stop-dispatch.sh"}]}]}}' \
  > "${linked_target_dir}/settings.json"
ln -s "${linked_target_dir}/settings.json" \
  "${linked_home}/.claude/settings.json"
linked_out="$(HOME="${linked_home}" bash "${REPO_ROOT}/uninstall.sh" \
  --yes 2>&1)"
assert_eq "regular settings symlink survives uninstall" "true" \
  "$([[ -L "${linked_home}/.claude/settings.json" ]] && printf true || printf false)"
assert_eq "physical settings target is cleaned" "0" \
  "$(jq -r '[.hooks.Stop[]?.hooks[]?.command // empty] | length' \
    "${linked_target_dir}/settings.json")"
assert_eq "physical settings target preserves foreign keys" "keep" \
  "$(jq -r '.userKey' "${linked_target_dir}/settings.json")"
assert_eq "linked-settings uninstall completes" "1" \
  "$(grep -c 'uninstall complete' <<<"${linked_out}" || true)"

# If settings exists, absence of both JSON implementations is a hard atomic
# refusal rather than a partial uninstall with dangling hook commands.
no_json_home="${TEST_DIR}/no-json-tool"
no_json_bin="${TEST_DIR}/no-json-bin"
mkdir -p "${no_json_home}/.claude/quality-pack" "${no_json_bin}"
printf 'managed\n' > "${no_json_home}/.claude/quality-pack/marker"
printf '%s\n' '{}' > "${no_json_home}/.claude/settings.json"
ln -s "$(command -v dirname)" "${no_json_bin}/dirname"
no_json_rc=0
no_json_out="$(PATH="${no_json_bin}" HOME="${no_json_home}" \
  /bin/bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || no_json_rc=$?
assert_eq "missing JSON tools refuse uninstall" "1" "${no_json_rc}"
assert_eq "missing JSON tools leave harness untouched" "true" \
  "$([[ -f "${no_json_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "missing JSON tool failure is explicit" "1" \
  "$(grep -c 'python3 or jq is required' <<<"${no_json_out}" || true)"

# Recoverable partial installs must remain discoverable. In particular, a
# failed older uninstall may leave only settings hooks; returning "Nothing to
# do" in that state strands commands pointing at deleted scripts.
settings_only_home="${TEST_DIR}/partial-settings-only"
mkdir -p "${settings_only_home}/.claude"
printf '%s\n' \
  '{"userKey":"keep","hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/skills/autowork/scripts/stop-dispatch.sh"}]}]}}' \
  > "${settings_only_home}/.claude/settings.json"
settings_only_out="$(HOME="${settings_only_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)"
assert_eq "settings-only partial uninstall removes managed residue" "0" \
  "$(jq -r '[.hooks.Stop[]?.hooks[]?.command // empty] | length' \
    "${settings_only_home}/.claude/settings.json")"
assert_eq "settings-only partial uninstall preserves foreign settings" "keep" \
  "$(jq -r '.userKey' "${settings_only_home}/.claude/settings.json")"
assert_eq "settings-only partial install is not reported absent" "0" \
  "$(grep -c 'Nothing to do' <<<"${settings_only_out}" || true)"

# Command text alone is not ownership. Wrong-event, wrong-envelope, and
# extra-field lookalikes must be truthful in preview and survive cleanup.
foreign_tuple_home="${TEST_DIR}/foreign-hook-tuples-only"
mkdir -p "${foreign_tuple_home}/.claude"
cat > "${foreign_tuple_home}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "ForeignEvent": [{"hooks":[
      {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/stop-dispatch.sh"}
    ]}],
    "Stop": [
      {"matcher":"foreign","hooks":[
        {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/stop-dispatch.sh"}
      ]},
      {"hooks":[
        {"type":"command","command":"$HOME/.claude/skills/autowork/scripts/stop-dispatch.sh","timeout":9}
      ]}
    ]
  }
}
JSON
cp "${foreign_tuple_home}/.claude/settings.json" \
  "${foreign_tuple_home}/settings.before.json"
foreign_tuple_out="$(HOME="${foreign_tuple_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)"
assert_eq "foreign tuple-only settings are reported as not installed" "1" \
  "$(grep -c 'Nothing to do' <<<"${foreign_tuple_out}" || true)"
assert_eq "foreign tuple-only settings are byte-preserved" "true" \
  "$(cmp -s "${foreign_tuple_home}/settings.before.json" \
      "${foreign_tuple_home}/.claude/settings.json" && printf true || printf false)"

agent_only_home="${TEST_DIR}/partial-agent-only"
mkdir -p "${agent_only_home}/.claude/agents"
printf 'managed\n' > "${agent_only_home}/.claude/agents/quality-reviewer.md"
agent_only_out="$(HOME="${agent_only_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)"
assert_eq "agent-only partial install is removed" "false" \
  "$([[ -e "${agent_only_home}/.claude/agents/quality-reviewer.md" ]] \
    && printf true || printf false)"
assert_eq "agent-only partial install is not reported absent" "0" \
  "$(grep -c 'Nothing to do' <<<"${agent_only_out}" || true)"

watchdog_only_home="${TEST_DIR}/partial-watchdog-dir-only"
mkdir -p "${watchdog_only_home}/.claude/launchd"
printf 'managed\n' \
  > "${watchdog_only_home}/.claude/launchd/dev.ohmyclaude.resume-watchdog.plist"
watchdog_only_out="$(HOME="${watchdog_only_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)"
assert_eq "watchdog-template-only partial install is removed" "false" \
  "$([[ -e "${watchdog_only_home}/.claude/launchd" ]] \
    && printf true || printf false)"
assert_eq "watchdog-template partial install is not reported absent" "0" \
  "$(grep -c 'Nothing to do' <<<"${watchdog_only_out}" || true)"

cli_only_home="${TEST_DIR}/partial-cli-only"
mkdir -p "${cli_only_home}/.local/bin"
ln -s "${cli_only_home}/.claude/bin/omc" \
  "${cli_only_home}/.local/bin/omc"
cli_only_out="$(HOME="${cli_only_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)"
assert_eq "owned CLI-link-only partial install is removed" "false" \
  "$([[ -L "${cli_only_home}/.local/bin/omc" ]] \
    && printf true || printf false)"
assert_eq "CLI-link partial install is not reported absent" "0" \
  "$(grep -c 'Nothing to do' <<<"${cli_only_out}" || true)"

# Ordinary managed removals receive the same ancestor-symlink protection as
# the explicit Constitution purge. This covers both recursive and rm -f paths.
for unsafe_parent in skills agents; do
  managed_alias_home="${TEST_DIR}/managed-${unsafe_parent}-alias"
  managed_alias_external="${TEST_DIR}/managed-${unsafe_parent}-external"
  mkdir -p "${managed_alias_home}/.claude/quality-pack" \
    "${managed_alias_external}"
  printf 'managed\n' > "${managed_alias_home}/.claude/quality-pack/marker"
  if [[ "${unsafe_parent}" == "skills" ]]; then
    mkdir -p "${managed_alias_external}/autowork"
    printf 'external\n' > "${managed_alias_external}/autowork/marker"
  else
    printf 'external\n' > "${managed_alias_external}/quality-reviewer.md"
  fi
  ln -s "${managed_alias_external}" \
    "${managed_alias_home}/.claude/${unsafe_parent}"
  managed_alias_rc=0
  managed_alias_out="$(HOME="${managed_alias_home}" \
    bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || managed_alias_rc=$?
  assert_eq "${unsafe_parent} ancestor symlink is refused" "1" \
    "${managed_alias_rc}"
  assert_eq "${unsafe_parent} ancestor refusal leaves harness untouched" "true" \
    "$([[ -f "${managed_alias_home}/.claude/quality-pack/marker" ]] \
      && printf true || printf false)"
  assert_eq "${unsafe_parent} external tree survives" "true" \
    "$(find "${managed_alias_external}" -type f -name marker \
      -o -name quality-reviewer.md | grep -q . && printf true || printf false)"
  assert_eq "${unsafe_parent} unsafe component is named" "1" \
    "$(grep -c 'symlinked path component' <<<"${managed_alias_out}" || true)"
done

# Exact removal authority binds real directory/file generations too. A
# same-type replacement after the final preflight is a concurrent winner and
# must survive rather than inheriting permission from path/type alone.
for replacement_kind in directory file; do
  replacement_home="${TEST_DIR}/managed-${replacement_kind}-replacement"
  replacement_ready="${TEST_DIR}/managed-${replacement_kind}.ready"
  replacement_release="${TEST_DIR}/managed-${replacement_kind}.release"
  replacement_out="${TEST_DIR}/managed-${replacement_kind}.out"
  if [[ "${replacement_kind}" == "directory" ]]; then
    replacement_path="${replacement_home}/.claude/skills/autowork"
    mkdir -p "${replacement_path}"
    printf 'managed-original\n' > "${replacement_path}/marker"
  else
    replacement_path="${replacement_home}/.claude/agents/quality-reviewer.md"
    mkdir -p "${replacement_path%/*}"
    printf 'managed-original\n' > "${replacement_path}"
  fi
  (
    OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
    OMC_TEST_UNINSTALL_REMOVE_MATCH="${replacement_path}" \
    OMC_TEST_UNINSTALL_REMOVE_READY_FILE="${replacement_ready}" \
    OMC_TEST_UNINSTALL_REMOVE_RELEASE_FILE="${replacement_release}" \
    HOME="${replacement_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
      >"${replacement_out}" 2>&1
  ) &
  replacement_pid=$!
  replacement_seen=0
  for _wait in $(seq 1 500); do
    [[ -e "${replacement_ready}" ]] \
      && { replacement_seen=1; break; }
    sleep 0.01
  done
  assert_eq "${replacement_kind} replacement reaches delete barrier" "1" \
    "${replacement_seen}"
  if [[ "${replacement_seen}" -eq 1 ]]; then
    if [[ "${replacement_kind}" == "directory" ]]; then
      mv "${replacement_path}" "${replacement_path}.held"
      mkdir "${replacement_path}"
      printf 'foreign-winner\n' > "${replacement_path}/marker"
    else
      mv "${replacement_path}" "${replacement_path}.held"
      printf 'foreign-winner\n' > "${replacement_path}"
    fi
  fi
  : > "${replacement_release}"
  replacement_rc=0
  wait "${replacement_pid}" || replacement_rc=$?
  assert_eq "same-type ${replacement_kind} replacement aborts deletion" "1" \
    "${replacement_rc}"
  if [[ "${replacement_kind}" == "directory" ]]; then
    replacement_bytes="$(cat "${replacement_path}/marker" \
      2>/dev/null || true)"
  else
    replacement_bytes="$(cat "${replacement_path}" 2>/dev/null || true)"
  fi
  assert_eq "foreign ${replacement_kind} replacement survives" \
    "foreign-winner" "${replacement_bytes}"
done

# A directory inode alone is not a deletion generation. Adding a descendant
# after sealing must invalidate the recursive tree and preserve the newcomer.
descendant_home="${TEST_DIR}/managed-descendant-injection"
descendant_path="${descendant_home}/.claude/skills/autowork"
descendant_ready="${TEST_DIR}/managed-descendant.ready"
descendant_release="${TEST_DIR}/managed-descendant.release"
mkdir -p "${descendant_path}"
printf 'managed-original\n' > "${descendant_path}/original"
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_REMOVE_MATCH="${descendant_path}" \
  OMC_TEST_UNINSTALL_REMOVE_READY_FILE="${descendant_ready}" \
  OMC_TEST_UNINSTALL_REMOVE_RELEASE_FILE="${descendant_release}" \
  HOME="${descendant_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
    >/dev/null 2>&1
) &
descendant_pid=$!
descendant_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${descendant_ready}" ]] \
    && { descendant_seen=1; break; }
  sleep 0.01
done
assert_eq "descendant injection reaches recursive delete barrier" "1" \
  "${descendant_seen}"
if [[ "${descendant_seen}" -eq 1 ]]; then
  printf 'foreign-descendant\n' > "${descendant_path}/foreign"
fi
: > "${descendant_release}"
descendant_rc=0
wait "${descendant_pid}" || descendant_rc=$?
assert_eq "new descendant invalidates recursive removal generation" "1" \
  "${descendant_rc}"
assert_eq "new descendant survives refused recursive deletion" \
  "foreign-descendant" \
  "$(cat "${descendant_path}/foreign" 2>/dev/null || true)"
assert_eq "original managed tree survives descendant race" \
  "managed-original" \
  "$(cat "${descendant_path}/original" 2>/dev/null || true)"

# Uninstall must settle durable tier generations while it owns the shared
# operation lock, before it snapshots settings or any deletion target. Exercise
# both rollback (pre-commit death) and committed-metadata retirement.
for wal_case in uncommitted committed; do
  wal_home="${TEST_DIR}/tier-wal-${wal_case}"
  wal_switch_ready="${TEST_DIR}/tier-wal-${wal_case}.switch-ready"
  wal_settled_ready="${TEST_DIR}/tier-wal-${wal_case}.settled-ready"
  wal_settled_release="${TEST_DIR}/tier-wal-${wal_case}.settled-release"
  wal_switch_out="${TEST_DIR}/tier-wal-${wal_case}.switch.out"
  wal_uninstall_out="${TEST_DIR}/tier-wal-${wal_case}.uninstall.out"
  mkdir -p "${wal_home}/.claude/quality-pack"
  cp -R "${REPO_ROOT}/bundle/dot-claude/agents" \
    "${wal_home}/.claude/agents"
  printf 'managed\n' > "${wal_home}/.claude/quality-pack/marker"
  printf 'model_tier=balanced\n' \
    > "${wal_home}/.claude/oh-my-claude.conf"
  chmod 600 "${wal_home}/.claude/oh-my-claude.conf"
  printf '{}\n' > "${wal_home}/.claude/settings.json"
  if [[ "${wal_case}" == "uncommitted" ]]; then
    (
      OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
      OMC_TEST_SWITCH_POST_CONF_READY_FILE="${wal_switch_ready}" \
      OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${wal_switch_ready}.release" \
      HOME="${wal_home}" \
        bash "${REPO_ROOT}/bundle/dot-claude/switch-tier.sh" quality \
        >"${wal_switch_out}" 2>&1
    ) &
  else
    (
      OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
      OMC_TEST_SWITCH_RETIRE_READY_FILE="${wal_switch_ready}" \
      OMC_TEST_SWITCH_RETIRE_RELEASE_FILE="${wal_switch_ready}.release" \
      HOME="${wal_home}" \
        bash "${REPO_ROOT}/bundle/dot-claude/switch-tier.sh" quality \
        >"${wal_switch_out}" 2>&1
    ) &
  fi
  wal_switch_pid=$!
  wal_switch_seen=0
  for _wait in $(seq 1 1000); do
    [[ -e "${wal_switch_ready}" ]] \
      && { wal_switch_seen=1; break; }
    kill -0 "${wal_switch_pid}" 2>/dev/null || break
    sleep 0.01
  done
  assert_eq "${wal_case} tier writer reaches durable interruption barrier" \
    "1" "${wal_switch_seen}"
  if kill -0 "${wal_switch_pid}" 2>/dev/null; then
    kill -9 "${wal_switch_pid}" 2>/dev/null || true
  fi
  wait "${wal_switch_pid}" 2>/dev/null || true
  rm -f -- "${wal_home}/.claude/.install.lock/pid" \
    "${wal_home}/.claude/.install.lock/token" 2>/dev/null || true
  rmdir "${wal_home}/.claude/.install.lock" 2>/dev/null || true

  (
    OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
    OMC_TEST_UNINSTALL_TX_SETTLED_READY_FILE="${wal_settled_ready}" \
    OMC_TEST_UNINSTALL_TX_SETTLED_RELEASE_FILE="${wal_settled_release}" \
    HOME="${wal_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
      >"${wal_uninstall_out}" 2>&1
  ) &
  wal_uninstall_pid=$!
  wal_settled_seen=0
  for _wait in $(seq 1 1000); do
    [[ -e "${wal_settled_ready}" ]] \
      && { wal_settled_seen=1; break; }
    kill -0 "${wal_uninstall_pid}" 2>/dev/null || break
    sleep 0.01
  done
  assert_eq "uninstall settles ${wal_case} tier WAL before removal sealing" \
    "1" "${wal_settled_seen}"
  if [[ "${wal_case}" == "uncommitted" ]]; then
    expected_settled_tier="balanced"
  else
    expected_settled_tier="quality"
  fi
  assert_eq "${wal_case} tier generation has correct settled config" \
    "model_tier=${expected_settled_tier}" \
    "$(grep '^model_tier=' \
      "${wal_home}/.claude/oh-my-claude.conf" 2>/dev/null || true)"
  remaining_wal_count="$(find "${wal_home}/.claude" -maxdepth 1 \
    \( -name '.switch-tier-transaction*' \
      -o -name '.switch-tier-retired.*' \) -print 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  assert_eq "${wal_case} tier metadata is fully retired" "0" \
    "${remaining_wal_count}"
  : > "${wal_settled_release}"
  wal_uninstall_rc=0
  wait "${wal_uninstall_pid}" || wal_uninstall_rc=$?
  assert_eq "uninstall completes after ${wal_case} tier settlement" "0" \
    "${wal_uninstall_rc}"
done

# Recovery code is itself snapshotted before execution. A mutable checkout
# replacement after that copy must fail closed without running either the new
# bytes or the old recovery authority against a now-unattested source.
tx_helper_repo="${TEST_DIR}/tx-helper-race-repo"
tx_helper_home="${TEST_DIR}/tx-helper-race-home"
tx_helper_ready="${TEST_DIR}/tx-helper-race.ready"
tx_helper_release="${TEST_DIR}/tx-helper-race.release"
tx_helper_out="${TEST_DIR}/tx-helper-race.out"
tx_helper_sentinel="${TEST_DIR}/tx-helper-race.executed"
mkdir -p "${tx_helper_repo}" \
  "${tx_helper_home}/.claude/quality-pack" \
  "${tx_helper_home}/.claude/agents" \
  "${tx_helper_home}/.claude/.switch-tier-transaction.stage.ABC123"
chmod 700 \
  "${tx_helper_home}/.claude/.switch-tier-transaction.stage.ABC123"
printf 'managed\n' > "${tx_helper_home}/.claude/quality-pack/marker"
printf '{}\n' > "${tx_helper_home}/.claude/settings.json"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${tx_helper_repo}/" \
  >/dev/null
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_TX_HELPERS_READY_FILE="${tx_helper_ready}" \
  OMC_TEST_UNINSTALL_TX_HELPERS_RELEASE_FILE="${tx_helper_release}" \
  HOME="${tx_helper_home}" bash "${tx_helper_repo}/uninstall.sh" --yes \
    >"${tx_helper_out}" 2>&1
) &
tx_helper_pid=$!
tx_helper_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${tx_helper_ready}" ]] \
    && { tx_helper_seen=1; break; }
  kill -0 "${tx_helper_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "transaction helper race reaches sealed-copy barrier" "1" \
  "${tx_helper_seen}"
if [[ "${tx_helper_seen}" -eq 1 ]]; then
  printf '\nprintf "attacker" > %q\n' "${tx_helper_sentinel}" \
    >> "${tx_helper_repo}/bundle/dot-claude/switch-tier.sh"
fi
: > "${tx_helper_release}"
tx_helper_rc=0
wait "${tx_helper_pid}" || tx_helper_rc=$?
assert_eq "drifted transaction recovery source aborts uninstall" "1" \
  "${tx_helper_rc}"
assert_eq "drifted recovery source executes no replacement bytes" "false" \
  "$([[ -e "${tx_helper_sentinel}" ]] && printf true || printf false)"
assert_eq "drifted recovery source leaves WAL metadata intact" "true" \
  "$([[ -d "${tx_helper_home}/.claude/.switch-tier-transaction.stage.ABC123" ]] \
    && printf true || printf false)"
assert_eq "drifted recovery source leaves harness intact" "true" \
  "$([[ -f "${tx_helper_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "transaction helper snapshots are exactly cleaned on refusal" \
  "false" \
  "$([[ -e "${tx_helper_home}/.claude/.install.lock" \
      || -L "${tx_helper_home}/.claude/.install.lock" ]] \
    && printf true || printf false)"

# Scheduler cleanup runs before harness deletion and a cleanup failure leaves
# both the harness and staged settings untouched.
for scheduler_case in success failure; do
  scheduler_home="${TEST_DIR}/scheduler-${scheduler_case}"
  scheduler_bin="${scheduler_home}/bin"
  mkdir -p "${scheduler_home}/.claude/quality-pack/scripts" \
    "${scheduler_bin}"
  printf 'managed\n' > "${scheduler_home}/.claude/quality-pack/marker"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    > "${scheduler_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
  chmod 700 \
    "${scheduler_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
  if [[ "${scheduler_case}" == "success" ]]; then
    scheduler_systemd_dir="${scheduler_home}/.config/systemd/user"
    mkdir -p "${scheduler_systemd_dir}"
    printf 'managed-service\n' \
      > "${scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service"
    printf 'managed-timer\n' \
      > "${scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer"
    chmod 600 \
      "${scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
      "${scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer"
    printf '%s\n' 'resume_watchdog=off' 'resume_watchdog= on ' \
      'resume_watchdog=invalid-later-row' \
      'resume_watchdog_scheduler=systemd' \
      "resume_watchdog_systemd_service_sha256=$(sha256_path \
        "${scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service")" \
      "resume_watchdog_systemd_timer_sha256=$(sha256_path \
        "${scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer")" \
      > "${scheduler_home}/.claude/oh-my-claude.conf"
    printf 'enabled\n' > "${scheduler_home}/systemctl.state"
  else
    printf '%s\n' 'resume_watchdog=on' 'resume_watchdog_scheduler=cron' \
      > "${scheduler_home}/.claude/oh-my-claude.conf"
    printf 'disabled\n' > "${scheduler_home}/systemctl.state"
  fi
  printf '%s\n' '{}' > "${scheduler_home}/.claude/settings.json"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "Linux\\n"' \
    > "${scheduler_bin}/uname"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" >> "${HOME}/systemctl.calls"' \
    'case "$*" in' \
    '  *" is-enabled "*)' \
    '    if [[ "$(cat "${HOME}/systemctl.state")" == "enabled" ]]; then printf "enabled\\n"; exit 0; fi' \
    '    printf "disabled\\n"; exit 1 ;;' \
    '  *" is-active "*)' \
    '    if [[ "$(cat "${HOME}/systemctl.state")" == "enabled" ]]; then printf "active\\n"; exit 0; fi' \
    '    printf "inactive\\n"; exit 1 ;;' \
    '  *" disable --now "*) printf "disabled\\n" > "${HOME}/systemctl.state"; exit 0 ;;' \
    '  *" daemon-reload"*) exit 0 ;;' \
    'esac' \
    'exit 0' \
    > "${scheduler_bin}/systemctl"
  if [[ "${scheduler_case}" == "failure" ]]; then
    printf '%s\n' '#!/usr/bin/env bash' \
      'case "${1:-}" in' \
      '  -l) printf "%s\n" "# oh-my-claude resume-watchdog" "* * * * * $HOME/.claude/quality-pack/scripts/resume-watchdog.sh --tick"; exit 0 ;;' \
      '  -) cat >/dev/null; exit 42 ;;' \
      'esac' \
      > "${scheduler_bin}/crontab"
  else
    printf '%s\n' '#!/usr/bin/env bash' \
      'case "${1:-}" in -l) exit 1 ;; -) cat >/dev/null; exit 0 ;; esac' \
      > "${scheduler_bin}/crontab"
  fi
  chmod +x "${scheduler_bin}/uname" "${scheduler_bin}/systemctl" \
    "${scheduler_bin}/crontab"
  scheduler_rc=0
  scheduler_out="$(PATH="${scheduler_bin}:${PATH}" HOME="${scheduler_home}" \
    bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || scheduler_rc=$?
  if [[ "${scheduler_case}" == "success" ]]; then
    assert_eq "scheduler cleanup succeeds" "0" "${scheduler_rc}"
    assert_eq "scheduler cleanup precedes harness removal" "false" \
      "$([[ -e "${scheduler_home}/.claude/quality-pack" ]] \
        && printf true || printf false)"
    assert_eq "scheduler disable command was issued" "1" \
      "$(grep -c 'disable --now oh-my-claude-resume-watchdog.timer' \
        "${scheduler_home}/systemctl.calls" 2>/dev/null || true)"
    assert_eq "trimmed last-valid watchdog row survives malformed duplicate" \
      "1" \
      "$(grep -c 'Removed resume-watchdog platform scheduler' \
        <<<"${scheduler_out}" || true)"
  else
    assert_eq "scheduler cleanup failure aborts uninstall" "1" "${scheduler_rc}"
    assert_eq "scheduler failure leaves harness untouched" "true" \
      "$([[ -f "${scheduler_home}/.claude/quality-pack/marker" ]] \
        && printf true || printf false)"
    assert_eq "scheduler failure leaves original settings" "{}" \
      "$(tr -d '[:space:]' < "${scheduler_home}/.claude/settings.json")"
    assert_eq "scheduler failure is explicit" "1" \
      "$(grep -c 'watchdog scheduler cleanup failed' <<<"${scheduler_out}" || true)"
  fi
done

# Scheduler cleanup is an inner transaction, but uninstall still performs
# target re-attestations after that helper commits. Force one of those checks
# to fail and require the enclosing uninstall to restore exact scheduler and
# config bytes plus the prior enabled/active runtime state.
late_scheduler_home="${TEST_DIR}/scheduler-late-reattest"
late_scheduler_bin="${late_scheduler_home}/bin"
late_scheduler_systemd_dir="${late_scheduler_home}/.config/systemd/user"
late_scheduler_ready="${TEST_DIR}/scheduler-late-reattest.ready"
late_scheduler_release="${TEST_DIR}/scheduler-late-reattest.release"
late_scheduler_out="${TEST_DIR}/scheduler-late-reattest.out"
mkdir -p "${late_scheduler_home}/.claude/quality-pack/scripts" \
  "${late_scheduler_systemd_dir}" "${late_scheduler_bin}"
printf 'sealed-managed-generation\n' \
  > "${late_scheduler_home}/.claude/quality-pack/marker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${late_scheduler_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
chmod 700 \
  "${late_scheduler_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
printf 'historical-owned-service\n' \
  > "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service"
printf 'historical-owned-timer\n' \
  > "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer"
chmod 600 \
  "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
  "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer"
cp "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
  "${late_scheduler_home}/service.before"
cp "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
  "${late_scheduler_home}/timer.before"
printf '%s\n' \
  'user_setting=preserve-exactly' \
  'resume_watchdog=on' \
  'resume_watchdog_scheduler=systemd' \
  "resume_watchdog_systemd_service_sha256=$(sha256_path \
    "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service")" \
  "resume_watchdog_systemd_timer_sha256=$(sha256_path \
    "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer")" \
  > "${late_scheduler_home}/.claude/oh-my-claude.conf"
cp "${late_scheduler_home}/.claude/oh-my-claude.conf" \
  "${late_scheduler_home}/conf.before"
printf '%s\n' '{}' > "${late_scheduler_home}/.claude/settings.json"
printf 'enabled\n' > "${late_scheduler_home}/systemctl.enabled"
printf 'active\n' > "${late_scheduler_home}/systemctl.active"
printf '%s\n' '#!/usr/bin/env bash' 'printf "Linux\\n"' \
  > "${late_scheduler_bin}/uname"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${HOME}/systemctl.calls"' \
  'case "$*" in' \
  '  *" show-environment"*) exit 0 ;;' \
  '  *" is-enabled "*)' \
  '    [[ "$(cat "${HOME}/systemctl.enabled")" == "enabled" ]] ;;' \
  '  *" is-active "*)' \
  '    [[ "$(cat "${HOME}/systemctl.active")" == "active" ]] ;;' \
  '  *" disable --now "*)' \
  '    printf "disabled\n" > "${HOME}/systemctl.enabled"' \
  '    printf "inactive\n" > "${HOME}/systemctl.active" ;;' \
  '  *" daemon-reload"*) exit 0 ;;' \
  '  *" enable "*) printf "enabled\n" > "${HOME}/systemctl.enabled" ;;' \
  '  *" start "*) printf "active\n" > "${HOME}/systemctl.active" ;;' \
  'esac' \
  'exit 0' \
  > "${late_scheduler_bin}/systemctl"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in -l) exit 1 ;; -) cat >/dev/null; exit 0 ;; -r) exit 0 ;; esac' \
  > "${late_scheduler_bin}/crontab"
chmod +x "${late_scheduler_bin}/uname" \
  "${late_scheduler_bin}/systemctl" "${late_scheduler_bin}/crontab"
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_WATCHDOG_CLEANED_READY_FILE="${late_scheduler_ready}" \
OMC_TEST_UNINSTALL_WATCHDOG_CLEANED_RELEASE_FILE="${late_scheduler_release}" \
PATH="${late_scheduler_bin}:${PATH}" HOME="${late_scheduler_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${late_scheduler_out}" 2>&1 &
late_scheduler_pid=$!
late_scheduler_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${late_scheduler_ready}" ]] \
    && { late_scheduler_seen=1; break; }
  kill -0 "${late_scheduler_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "late scheduler abort reaches post-cleanup barrier" "1" \
  "${late_scheduler_seen}"
if [[ "${late_scheduler_seen}" -eq 1 ]]; then
  printf 'concurrent-user-winner\n' \
    >> "${late_scheduler_home}/.claude/quality-pack/marker"
fi
: > "${late_scheduler_release}"
late_scheduler_rc=0
wait "${late_scheduler_pid}" || late_scheduler_rc=$?
assert_eq "late scheduler target change aborts uninstall" "1" \
  "${late_scheduler_rc}"
assert_eq "late scheduler abort preserves harness winner" \
  $'sealed-managed-generation\nconcurrent-user-winner' \
  "$(cat "${late_scheduler_home}/.claude/quality-pack/marker")"
assert_eq "late scheduler abort restores exact service bytes" "true" \
  "$(cmp -s "${late_scheduler_home}/service.before" \
      "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
    && printf true || printf false)"
assert_eq "late scheduler abort restores exact timer bytes" "true" \
  "$(cmp -s "${late_scheduler_home}/timer.before" \
      "${late_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
    && printf true || printf false)"
assert_eq "late scheduler abort restores exact config bytes" "true" \
  "$(cmp -s "${late_scheduler_home}/conf.before" \
      "${late_scheduler_home}/.claude/oh-my-claude.conf" \
    && printf true || printf false)"
assert_eq "late scheduler abort restores enabled state" "enabled" \
  "$(cat "${late_scheduler_home}/systemctl.enabled")"
assert_eq "late scheduler abort restores active state" "active" \
  "$(cat "${late_scheduler_home}/systemctl.active")"
assert_eq "late scheduler abort keeps original settings" "{}" \
  "$(tr -d '[:space:]' \
    < "${late_scheduler_home}/.claude/settings.json")"
assert_eq "late scheduler abort reports enclosing rollback" "1" \
  "$(grep -c 'Uninstall scheduler rollback complete' \
    "${late_scheduler_out}" 2>/dev/null || true)"
assert_eq "late scheduler rollback releases exact operation lock" "false" \
  "$([[ -e "${late_scheduler_home}/.claude/.install.lock" \
      || -L "${late_scheduler_home}/.claude/.install.lock" ]] \
    && printf true || printf false)"

# The settings cleanup stage exists before the scheduler WAL is prepared.
# Kill after the preparing receipt is sealed but before its private directory
# is atomically published. Recovery must discover and promote that one exact
# generation, remove its recorded settings stage, and reject metadata that
# redirects the deletion to a same-shaped file outside the settings parent.
wal_stage_home="${TEST_DIR}/scheduler-wal-stage-sigkill"
wal_stage_bin="${wal_stage_home}/bin"
wal_stage_systemd_dir="${wal_stage_home}/.config/systemd/user"
wal_stage_ready="${TEST_DIR}/scheduler-wal-stage.ready"
wal_stage_release="${TEST_DIR}/scheduler-wal-stage.release"
wal_stage_recovered_ready="${TEST_DIR}/scheduler-wal-stage-recovered.ready"
wal_stage_recovered_release="${TEST_DIR}/scheduler-wal-stage-recovered.release"
wal_stage_first_out="${TEST_DIR}/scheduler-wal-stage-first.out"
wal_stage_malformed_out="${TEST_DIR}/scheduler-wal-stage-malformed.out"
wal_stage_replace_ready="${TEST_DIR}/scheduler-wal-stage-replace.ready"
wal_stage_replace_release="${TEST_DIR}/scheduler-wal-stage-replace.release"
wal_stage_replace_out="${TEST_DIR}/scheduler-wal-stage-replace.out"
wal_stage_source_checked_ready="${TEST_DIR}/scheduler-wal-stage-source-checked.ready"
wal_stage_source_checked_release="${TEST_DIR}/scheduler-wal-stage-source-checked.release"
wal_stage_source_checked_out="${TEST_DIR}/scheduler-wal-stage-source-checked.out"
wal_stage_destination_ready="${TEST_DIR}/scheduler-wal-stage-destination.ready"
wal_stage_destination_release="${TEST_DIR}/scheduler-wal-stage-destination.release"
wal_stage_destination_out="${TEST_DIR}/scheduler-wal-stage-destination.out"
wal_stage_final_unlink_ready="${TEST_DIR}/scheduler-wal-stage-final-unlink.ready"
wal_stage_final_unlink_release="${TEST_DIR}/scheduler-wal-stage-final-unlink.release"
wal_stage_final_unlink_out="${TEST_DIR}/scheduler-wal-stage-final-unlink.out"
wal_stage_retired_kill_ready="${TEST_DIR}/scheduler-wal-stage-retired-kill.ready"
wal_stage_retired_kill_release="${TEST_DIR}/scheduler-wal-stage-retired-kill.release"
wal_stage_retired_kill_out="${TEST_DIR}/scheduler-wal-stage-retired-kill.out"
wal_stage_quarantine_ready="${TEST_DIR}/scheduler-wal-stage-quarantine.ready"
wal_stage_quarantine_release="${TEST_DIR}/scheduler-wal-stage-quarantine.release"
wal_stage_quarantine_out="${TEST_DIR}/scheduler-wal-stage-quarantine.out"
wal_stage_retry_out="${TEST_DIR}/scheduler-wal-stage-retry.out"
wal_stage_external_dir="${TEST_DIR}/scheduler-wal-external"
mkdir -p "${wal_stage_home}/.claude/quality-pack/scripts" \
  "${wal_stage_systemd_dir}" "${wal_stage_bin}" \
  "${wal_stage_external_dir}"
printf 'managed-before-wal-stage-sigkill\n' \
  > "${wal_stage_home}/.claude/quality-pack/marker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${wal_stage_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
chmod 700 \
  "${wal_stage_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
printf 'wal-stage-owned-service\n' \
  > "${wal_stage_systemd_dir}/oh-my-claude-resume-watchdog.service"
printf 'wal-stage-owned-timer\n' \
  > "${wal_stage_systemd_dir}/oh-my-claude-resume-watchdog.timer"
chmod 600 \
  "${wal_stage_systemd_dir}/oh-my-claude-resume-watchdog.service" \
  "${wal_stage_systemd_dir}/oh-my-claude-resume-watchdog.timer"
printf '%s\n' \
  'user_setting=preserve-through-wal-stage-recovery' \
  'resume_watchdog=on' \
  'resume_watchdog_scheduler=systemd' \
  "resume_watchdog_systemd_service_sha256=$(sha256_path \
    "${wal_stage_systemd_dir}/oh-my-claude-resume-watchdog.service")" \
  "resume_watchdog_systemd_timer_sha256=$(sha256_path \
    "${wal_stage_systemd_dir}/oh-my-claude-resume-watchdog.timer")" \
  > "${wal_stage_home}/.claude/oh-my-claude.conf"
printf '%s\n' '{}' > "${wal_stage_home}/.claude/settings.json"
printf 'enabled\n' > "${wal_stage_home}/systemctl.enabled"
printf 'active\n' > "${wal_stage_home}/systemctl.active"
cp "${late_scheduler_bin}/uname" "${wal_stage_bin}/uname"
cp "${late_scheduler_bin}/systemctl" "${wal_stage_bin}/systemctl"
cp "${late_scheduler_bin}/crontab" "${wal_stage_bin}/crontab"
chmod +x "${wal_stage_bin}/uname" "${wal_stage_bin}/systemctl" \
  "${wal_stage_bin}/crontab"
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_WATCHDOG_WAL_STAGED_READY_FILE="${wal_stage_ready}" \
OMC_TEST_UNINSTALL_WATCHDOG_WAL_STAGED_RELEASE_FILE="${wal_stage_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_first_out}" 2>&1 &
wal_stage_pid=$!
wal_stage_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_ready}" ]] && { wal_stage_seen=1; break; }
  kill -0 "${wal_stage_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "staged WAL SIGKILL case reaches sealed private-WAL gap" "1" \
  "${wal_stage_seen}"
if [[ "${wal_stage_seen}" -eq 1 ]]; then
  kill -KILL "${wal_stage_pid}"
fi
wal_stage_rc=0
wait "${wal_stage_pid}" 2>/dev/null || wal_stage_rc=$?
assert_eq "staged WAL case terminates with signal status" "137" \
  "${wal_stage_rc}"
wal_stage_dir=""
if [[ -f "${wal_stage_ready}" ]]; then
  wal_stage_dir="$(head -n 1 "${wal_stage_ready}")"
fi
assert_eq "SIGKILL leaves one exact private watchdog WAL" "true" \
  "$([[ -n "${wal_stage_dir}" && -d "${wal_stage_dir}" \
      && ! -L "${wal_stage_dir}" \
      && "${wal_stage_dir}" \
        == "${wal_stage_home}/.claude/.install.lock/".watchdog-outer-rollback.stage.* ]] \
    && printf true || printf false)"
assert_eq "SIGKILL leaves exactly one private watchdog WAL candidate" "1" \
  "$(find "${wal_stage_home}/.claude/.install.lock" -mindepth 1 \
      -maxdepth 1 -name '.watchdog-outer-rollback.stage.*' -print \
    | wc -l | tr -d '[:space:]')"
assert_eq "private watchdog WAL has a preparing receipt" "preparing" \
  "$(cut -f2 "${wal_stage_dir}/meta.tsv" 2>/dev/null || true)"
assert_eq "fixed WAL is absent before atomic publication" "false" \
  "$([[ -e "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" \
      || -L "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" ]] \
    && printf true || printf false)"
wal_stage_settings_stage="$(cut -f11 \
  "${wal_stage_dir}/meta.tsv" 2>/dev/null || true)"
assert_eq "sealed private WAL retains the exact settings stage" "true" \
  "$([[ -n "${wal_stage_settings_stage}" \
      && -f "${wal_stage_settings_stage}" \
      && ! -L "${wal_stage_settings_stage}" ]] \
    && printf true || printf false)"
assert_eq "pre-publication SIGKILL leaves live settings untouched" "{}" \
  "$(tr -d '[:space:]' \
    < "${wal_stage_home}/.claude/settings.json")"

wal_stage_meta_backup="${TEST_DIR}/scheduler-wal-stage-meta.original"
wal_stage_meta_tampered="${TEST_DIR}/scheduler-wal-stage-meta.tampered"
wal_stage_external="${wal_stage_external_dir}/.settings.json.oh-my-claude-uninstall.EXTERNAL1"
cp "${wal_stage_dir}/meta.tsv" "${wal_stage_meta_backup}"
cp "${wal_stage_settings_stage}" "${wal_stage_external}"
wal_stage_external_id="$(node_identity_path "${wal_stage_external}")"
wal_stage_external_parent_id="$(node_identity_path \
  "${wal_stage_external_dir}")"
wal_stage_external_hash="$(sha256_path "${wal_stage_external}")"
wal_stage_external_mode="$(mode_path "${wal_stage_external}")"
awk -F '\t' -v OFS='\t' \
  -v stage_path="${wal_stage_external}" \
  -v stage_id="${wal_stage_external_id}" \
  -v parent_id="${wal_stage_external_parent_id}" \
  -v stage_hash="${wal_stage_external_hash}" \
  -v stage_mode="${wal_stage_external_mode}" \
  'NR == 1 {
     $11 = stage_path
     $12 = stage_id
     $13 = parent_id
     $14 = stage_id
     $15 = stage_hash
     $16 = stage_mode
   }
   { print }' \
  "${wal_stage_meta_backup}" > "${wal_stage_meta_tampered}"
chmod 600 "${wal_stage_meta_tampered}"
mv -f "${wal_stage_meta_tampered}" "${wal_stage_dir}/meta.tsv"
wal_stage_malformed_rc=0
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_malformed_out}" 2>&1 || wal_stage_malformed_rc=$?
assert_eq "external-parent WAL metadata fails closed" "1" \
  "${wal_stage_malformed_rc}"
assert_eq "external same-shaped settings stage remains untouched" \
  "${wal_stage_external_hash}" "$(sha256_path "${wal_stage_external}")"
assert_eq "malformed WAL refusal preserves its private generation" "true" \
  "$([[ -d "${wal_stage_dir}" && ! -L "${wal_stage_dir}" ]] \
    && printf true || printf false)"
assert_eq "malformed private WAL is not promoted" "false" \
  "$([[ -e "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" \
      || -L "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" ]] \
    && printf true || printf false)"
assert_eq "malformed WAL reports exact-generation refusal" "1" \
  "$(grep -c \
    'exact durable watchdog rollback generation could not be validated' \
    "${wal_stage_malformed_out}" 2>/dev/null || true)"

cp "${wal_stage_meta_backup}" "${wal_stage_dir}/meta.tsv"
chmod 600 "${wal_stage_dir}/meta.tsv"

# Recovery first validates the recorded stage, then atomically moves that
# generation to its durable same-filesystem quarantine. Replace the public
# pathname in that deterministic gap: the replacement must remain present and
# the old inode authority must not authorize unlinking it.
wal_stage_original_saved="${wal_stage_settings_stage}.original-saved"
wal_stage_replacement_tmp="${wal_stage_settings_stage}.replacement"
wal_stage_replacement_hash=""
wal_stage_quarantine="$(cut -f17 \
  "${wal_stage_dir}/meta.tsv" 2>/dev/null || true)"
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_READY_FILE="${wal_stage_replace_ready}" \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_RELEASE_FILE="${wal_stage_replace_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_replace_out}" 2>&1 &
wal_stage_replace_pid=$!
wal_stage_replace_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_replace_ready}" ]] \
    && { wal_stage_replace_seen=1; break; }
  kill -0 "${wal_stage_replace_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "stage-retirement race reaches exact-generation barrier" "1" \
  "${wal_stage_replace_seen}"
if [[ "${wal_stage_replace_seen}" -eq 1 ]]; then
  mv -- "${wal_stage_settings_stage}" "${wal_stage_original_saved}"
  printf '%s\n' '{"concurrent":"replacement-must-survive"}' \
    > "${wal_stage_replacement_tmp}"
  chmod "${wal_stage_external_mode}" "${wal_stage_replacement_tmp}"
  wal_stage_replacement_hash="$(sha256_path \
    "${wal_stage_replacement_tmp}")"
  mv -- "${wal_stage_replacement_tmp}" "${wal_stage_settings_stage}"
fi
: > "${wal_stage_replace_release}"
wal_stage_replace_rc=0
wait "${wal_stage_replace_pid}" || wal_stage_replace_rc=$?
assert_eq "replacement race fails closed during stage retirement" "1" \
  "${wal_stage_replace_rc}"
assert_eq "replacement generation is not deleted by old inode authority" \
  "${wal_stage_replacement_hash}" \
  "$(sha256_path "${wal_stage_settings_stage}" 2>/dev/null || true)"
assert_eq "failed replacement race publishes no quarantine residue" "false" \
  "$([[ -n "${wal_stage_quarantine}" \
      && ( -e "${wal_stage_quarantine}" \
        || -L "${wal_stage_quarantine}" ) ]] \
    && printf true || printf false)"
assert_eq "replacement-race recovery preserves fixed WAL for retry" "true" \
  "$([[ -d "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" \
      && ! -L "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" ]] \
    && printf true || printf false)"
if [[ -f "${wal_stage_settings_stage}" \
    && ! -L "${wal_stage_settings_stage}" \
    && -f "${wal_stage_original_saved}" \
    && ! -L "${wal_stage_original_saved}" ]]; then
  mv -- "${wal_stage_settings_stage}" "${wal_stage_external}.replacement"
  mv -- "${wal_stage_original_saved}" "${wal_stage_settings_stage}"
fi

# Replace the source only after its final pre-rename generation check. The
# no-clobber rename may capture that newer inode, but the recovery must move it
# back to the public stage pathname and retain the WAL for an exact retry.
wal_stage_postcheck_saved="${wal_stage_settings_stage}.postcheck-saved"
wal_stage_postcheck_tmp="${wal_stage_settings_stage}.postcheck-replacement"
wal_stage_postcheck_hash=""
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_SOURCE_CHECKED_READY_FILE="${wal_stage_source_checked_ready}" \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_SOURCE_CHECKED_RELEASE_FILE="${wal_stage_source_checked_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_source_checked_out}" 2>&1 &
wal_stage_source_checked_pid=$!
wal_stage_source_checked_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_source_checked_ready}" ]] \
    && { wal_stage_source_checked_seen=1; break; }
  kill -0 "${wal_stage_source_checked_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "post-check source race reaches final-generation seam" "1" \
  "${wal_stage_source_checked_seen}"
if [[ "${wal_stage_source_checked_seen}" -eq 1 ]]; then
  mv -- "${wal_stage_settings_stage}" "${wal_stage_postcheck_saved}"
  printf '%s\n' '{"post_check":"replacement-must-be-restored"}' \
    > "${wal_stage_postcheck_tmp}"
  chmod "${wal_stage_external_mode}" "${wal_stage_postcheck_tmp}"
  wal_stage_postcheck_hash="$(sha256_path "${wal_stage_postcheck_tmp}")"
  mv -- "${wal_stage_postcheck_tmp}" "${wal_stage_settings_stage}"
fi
: > "${wal_stage_source_checked_release}"
wal_stage_source_checked_rc=0
wait "${wal_stage_source_checked_pid}" || wal_stage_source_checked_rc=$?
assert_eq "post-check source replacement fails retirement closed" "1" \
  "${wal_stage_source_checked_rc}"
assert_eq "post-check source replacement is restored durably" \
  "${wal_stage_postcheck_hash}" \
  "$(sha256_path "${wal_stage_settings_stage}" 2>/dev/null || true)"
assert_eq "post-check source race leaves no quarantine" "false" \
  "$([[ -e "${wal_stage_quarantine}" || -L "${wal_stage_quarantine}" ]] \
    && printf true || printf false)"
mv -- "${wal_stage_settings_stage}" \
  "${wal_stage_external}.postcheck-replacement"
mv -- "${wal_stage_postcheck_saved}" "${wal_stage_settings_stage}"

# Create the quarantine destination after the last absence check. mv -n must
# neither overwrite that concurrent file nor move the recorded source.
wal_stage_destination_hash=""
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_DESTINATION_READY_FILE="${wal_stage_destination_ready}" \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_DESTINATION_RELEASE_FILE="${wal_stage_destination_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_destination_out}" 2>&1 &
wal_stage_destination_pid=$!
wal_stage_destination_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_destination_ready}" ]] \
    && { wal_stage_destination_seen=1; break; }
  kill -0 "${wal_stage_destination_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "stage quarantine collision reaches no-clobber seam" "1" \
  "${wal_stage_destination_seen}"
if [[ "${wal_stage_destination_seen}" -eq 1 ]]; then
  printf '%s\n' '{"quarantine":"collision-must-survive"}' \
    > "${wal_stage_quarantine}"
  chmod "${wal_stage_external_mode}" "${wal_stage_quarantine}"
  wal_stage_destination_hash="$(sha256_path "${wal_stage_quarantine}")"
fi
: > "${wal_stage_destination_release}"
wal_stage_destination_rc=0
wait "${wal_stage_destination_pid}" || wal_stage_destination_rc=$?
assert_eq "stage quarantine collision fails retirement closed" "1" \
  "${wal_stage_destination_rc}"
assert_eq "quarantine collision is never overwritten" \
  "${wal_stage_destination_hash}" \
  "$(sha256_path "${wal_stage_quarantine}" 2>/dev/null || true)"
assert_eq "quarantine collision leaves recorded source in place" \
  "${wal_stage_external_hash}" \
  "$(sha256_path "${wal_stage_settings_stage}" 2>/dev/null || true)"
mv -- "${wal_stage_quarantine}" \
  "${wal_stage_external}.quarantine-collision"

# The public quarantine is first moved into the WAL-owned retired slot. Swap
# that final pathname after its last check: the replacement must be restored
# to the public source instead of being unlinked under stale inode authority.
wal_stage_retired=""
wal_stage_retired_saved="${TEST_DIR}/scheduler-wal-stage-retired.expected"
wal_stage_final_replacement_hash=""
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_FINAL_UNLINK_READY_FILE="${wal_stage_final_unlink_ready}" \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_FINAL_UNLINK_RELEASE_FILE="${wal_stage_final_unlink_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_final_unlink_out}" 2>&1 &
wal_stage_final_unlink_pid=$!
wal_stage_final_unlink_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_final_unlink_ready}" ]] \
    && { wal_stage_final_unlink_seen=1; break; }
  kill -0 "${wal_stage_final_unlink_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "final settings retirement reaches pre-unlink seam" "1" \
  "${wal_stage_final_unlink_seen}"
if [[ "${wal_stage_final_unlink_seen}" -eq 1 ]]; then
  wal_stage_retired="$(head -n 1 "${wal_stage_final_unlink_ready}")"
  mv -- "${wal_stage_retired}" "${wal_stage_retired_saved}"
  printf '%s\n' '{"final_unlink":"replacement-must-survive"}' \
    > "${wal_stage_retired}"
  chmod "${wal_stage_external_mode}" "${wal_stage_retired}"
  wal_stage_final_replacement_hash="$(sha256_path "${wal_stage_retired}")"
fi
: > "${wal_stage_final_unlink_release}"
wal_stage_final_unlink_rc=0
wait "${wal_stage_final_unlink_pid}" || wal_stage_final_unlink_rc=$?
assert_eq "final-unlink replacement fails retirement closed" "1" \
  "${wal_stage_final_unlink_rc}"
assert_eq "final-unlink replacement is restored to public source" \
  "${wal_stage_final_replacement_hash}" \
  "$(sha256_path "${wal_stage_settings_stage}" 2>/dev/null || true)"
assert_eq "final-unlink race does not delete the replacement pathname" \
  "false" \
  "$([[ -n "${wal_stage_retired}" \
      && ( -e "${wal_stage_retired}" || -L "${wal_stage_retired}" ) ]] \
    && printf true || printf false)"
mv -- "${wal_stage_settings_stage}" \
  "${wal_stage_external}.final-unlink-replacement"
mv -- "${wal_stage_retired_saved}" "${wal_stage_settings_stage}"

# Kill after the exact stage inode has moved to its predeclared quarantine.
# The following recovery must consume that durable intermediate state without
# reopening or deleting whatever later occupies the original pathname.
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_SETTINGS_QUARANTINED_READY_FILE="${wal_stage_quarantine_ready}" \
OMC_TEST_UNINSTALL_SETTINGS_QUARANTINED_RELEASE_FILE="${wal_stage_quarantine_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_quarantine_out}" 2>&1 &
wal_stage_quarantine_pid=$!
wal_stage_quarantine_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_quarantine_ready}" ]] \
    && { wal_stage_quarantine_seen=1; break; }
  kill -0 "${wal_stage_quarantine_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "stage retirement reaches durable quarantine barrier" "1" \
  "${wal_stage_quarantine_seen}"
if [[ "${wal_stage_quarantine_seen}" -eq 1 ]]; then
  kill -KILL "${wal_stage_quarantine_pid}"
fi
wal_stage_quarantine_rc=0
wait "${wal_stage_quarantine_pid}" 2>/dev/null \
  || wal_stage_quarantine_rc=$?
assert_eq "quarantine interruption terminates with signal status" "137" \
  "${wal_stage_quarantine_rc}"
assert_eq "quarantine interruption moved the public stage pathname" "false" \
  "$([[ -e "${wal_stage_settings_stage}" \
      || -L "${wal_stage_settings_stage}" ]] \
    && printf true || printf false)"
assert_eq "quarantine interruption preserves the exact staged bytes" \
  "${wal_stage_external_hash}" \
  "$(sha256_path "${wal_stage_quarantine}" 2>/dev/null || true)"

# Resume once, advance the exact quarantine into the WAL-owned retired slot,
# and kill there. The next retry must recognize and consume that generation
# without reopening either public pathname.
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_FINAL_UNLINK_READY_FILE="${wal_stage_retired_kill_ready}" \
OMC_TEST_UNINSTALL_SETTINGS_RETIRE_FINAL_UNLINK_RELEASE_FILE="${wal_stage_retired_kill_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_retired_kill_out}" 2>&1 &
wal_stage_retired_kill_pid=$!
wal_stage_retired_kill_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_retired_kill_ready}" ]] \
    && { wal_stage_retired_kill_seen=1; break; }
  kill -0 "${wal_stage_retired_kill_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "quarantine recovery reaches WAL-local retired seam" "1" \
  "${wal_stage_retired_kill_seen}"
if [[ "${wal_stage_retired_kill_seen}" -eq 1 ]]; then
  wal_stage_retired_kill_path="$(head -n 1 \
    "${wal_stage_retired_kill_ready}")"
  kill -KILL "${wal_stage_retired_kill_pid}"
else
  wal_stage_retired_kill_path=""
fi
wal_stage_retired_kill_rc=0
wait "${wal_stage_retired_kill_pid}" 2>/dev/null \
  || wal_stage_retired_kill_rc=$?
assert_eq "WAL-local retirement interruption has signal status" "137" \
  "${wal_stage_retired_kill_rc}"
assert_eq "WAL-local retirement consumes external quarantine" "false" \
  "$([[ -e "${wal_stage_quarantine}" || -L "${wal_stage_quarantine}" ]] \
    && printf true || printf false)"
assert_eq "WAL-local retirement preserves exact staged bytes" \
  "${wal_stage_external_hash}" \
  "$(sha256_path "${wal_stage_retired_kill_path}" 2>/dev/null || true)"

OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_READY_FILE="${wal_stage_recovered_ready}" \
OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_RELEASE_FILE="${wal_stage_recovered_release}" \
PATH="${wal_stage_bin}:${PATH}" HOME="${wal_stage_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${wal_stage_retry_out}" 2>&1 &
wal_stage_retry_pid=$!
wal_stage_recovery_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${wal_stage_recovered_ready}" ]] \
    && { wal_stage_recovery_seen=1; break; }
  kill -0 "${wal_stage_retry_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "private WAL recovery reaches exact-generation barrier" "1" \
  "${wal_stage_recovery_seen}"
assert_eq "recovery retains the promoted private WAL at its fixed name" "true" \
  "$([[ -d "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" \
      && ! -L "${wal_stage_home}/.claude/.install.lock/watchdog-outer-rollback" \
      && ! -e "${wal_stage_dir}" && ! -L "${wal_stage_dir}" ]] \
    && printf true || printf false)"
assert_eq "recovery removes the exact original settings stage" "false" \
  "$([[ -e "${wal_stage_settings_stage}" \
      || -L "${wal_stage_settings_stage}" ]] \
    && printf true || printf false)"
assert_eq "recovery consumes the exact quarantine generation" "false" \
  "$([[ -e "${wal_stage_quarantine}" \
      || -L "${wal_stage_quarantine}" ]] \
    && printf true || printf false)"
assert_eq "valid recovery still leaves external same-shaped file untouched" \
  "${wal_stage_external_hash}" "$(sha256_path "${wal_stage_external}")"
: > "${wal_stage_recovered_release}"
wal_stage_retry_rc=0
wait "${wal_stage_retry_pid}" || wal_stage_retry_rc=$?
assert_eq "promoted private-WAL recovery completes uninstall" "0" \
  "${wal_stage_retry_rc}"
assert_eq "promoted private-WAL recovery releases operation lock" "false" \
  "$([[ -e "${wal_stage_home}/.claude/.install.lock" \
      || -L "${wal_stage_home}/.claude/.install.lock" ]] \
    && printf true || printf false)"
assert_eq "promoted recovery leaves no private WAL residue" "0" \
  "$(find "${wal_stage_home}/.claude" -name \
      '.watchdog-outer-rollback.stage.*' -print \
    | wc -l | tr -d '[:space:]')"

# SIGKILL cannot run the outer EXIT trap. Kill the uninstall after the nested
# helper has committed but before its post-state is captured, then require the
# next invocation to reconstruct that exact cleanup generation from the fixed
# WAL, restore it under the stranded lock generation, and safely continue.
kill_scheduler_home="${TEST_DIR}/scheduler-sigkill-recovery"
kill_scheduler_bin="${kill_scheduler_home}/bin"
kill_scheduler_systemd_dir="${kill_scheduler_home}/.config/systemd/user"
kill_scheduler_helper_ready="${TEST_DIR}/scheduler-sigkill-helper.ready"
kill_scheduler_helper_release="${TEST_DIR}/scheduler-sigkill-helper.release"
kill_scheduler_recovered_ready="${TEST_DIR}/scheduler-sigkill-recovered.ready"
kill_scheduler_recovered_release="${TEST_DIR}/scheduler-sigkill-recovered.release"
kill_scheduler_first_out="${TEST_DIR}/scheduler-sigkill-first.out"
kill_scheduler_retry_out="${TEST_DIR}/scheduler-sigkill-retry.out"
mkdir -p "${kill_scheduler_home}/.claude/quality-pack/scripts" \
  "${kill_scheduler_systemd_dir}" "${kill_scheduler_bin}"
printf 'managed-before-sigkill\n' \
  > "${kill_scheduler_home}/.claude/quality-pack/marker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${kill_scheduler_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
chmod 700 \
  "${kill_scheduler_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
printf 'sigkill-owned-service\n' \
  > "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service"
printf 'sigkill-owned-timer\n' \
  > "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer"
chmod 600 \
  "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
  "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer"
cp "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
  "${kill_scheduler_home}/service.before"
cp "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
  "${kill_scheduler_home}/timer.before"
printf '%s\n' \
  'user_setting=preserve-through-recovery' \
  'resume_watchdog=on' \
  'resume_watchdog_scheduler=systemd' \
  "resume_watchdog_systemd_service_sha256=$(sha256_path \
    "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service")" \
  "resume_watchdog_systemd_timer_sha256=$(sha256_path \
    "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer")" \
  > "${kill_scheduler_home}/.claude/oh-my-claude.conf"
cp "${kill_scheduler_home}/.claude/oh-my-claude.conf" \
  "${kill_scheduler_home}/conf.before"
printf '%s\n' '{}' > "${kill_scheduler_home}/.claude/settings.json"
printf 'enabled\n' > "${kill_scheduler_home}/systemctl.enabled"
printf 'active\n' > "${kill_scheduler_home}/systemctl.active"
printf '%s\n' '#!/usr/bin/env bash' 'printf "Linux\\n"' \
  > "${kill_scheduler_bin}/uname"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${HOME}/systemctl.calls"' \
  'case "$*" in' \
  '  *" show-environment"*) exit 0 ;;' \
  '  *" is-enabled "*)' \
  '    [[ "$(cat "${HOME}/systemctl.enabled")" == "enabled" ]] ;;' \
  '  *" is-active "*)' \
  '    [[ "$(cat "${HOME}/systemctl.active")" == "active" ]] ;;' \
  '  *" disable --now "*)' \
  '    printf "disabled\n" > "${HOME}/systemctl.enabled"' \
  '    printf "inactive\n" > "${HOME}/systemctl.active" ;;' \
  '  *" daemon-reload"*) exit 0 ;;' \
  '  *" enable "*) printf "enabled\n" > "${HOME}/systemctl.enabled" ;;' \
  '  *" start "*) printf "active\n" > "${HOME}/systemctl.active" ;;' \
  'esac' \
  'exit 0' \
  > "${kill_scheduler_bin}/systemctl"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in -l) exit 1 ;; -) cat >/dev/null; exit 0 ;; -r) exit 0 ;; esac' \
  > "${kill_scheduler_bin}/crontab"
chmod +x "${kill_scheduler_bin}/uname" \
  "${kill_scheduler_bin}/systemctl" "${kill_scheduler_bin}/crontab"
OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_WATCHDOG_HELPER_RETURNED_READY_FILE="${kill_scheduler_helper_ready}" \
OMC_TEST_UNINSTALL_WATCHDOG_HELPER_RETURNED_RELEASE_FILE="${kill_scheduler_helper_release}" \
PATH="${kill_scheduler_bin}:${PATH}" HOME="${kill_scheduler_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${kill_scheduler_first_out}" 2>&1 &
kill_scheduler_pid=$!
kill_scheduler_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${kill_scheduler_helper_ready}" ]] \
    && { kill_scheduler_seen=1; break; }
  kill -0 "${kill_scheduler_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "SIGKILL scheduler case reaches child-return gap" "1" \
  "${kill_scheduler_seen}"
if [[ "${kill_scheduler_seen}" -eq 1 ]]; then
  kill -KILL "${kill_scheduler_pid}"
fi
kill_scheduler_rc=0
wait "${kill_scheduler_pid}" 2>/dev/null || kill_scheduler_rc=$?
assert_eq "SIGKILL scheduler case terminates with signal status" "137" \
  "${kill_scheduler_rc}"
assert_eq "SIGKILL leaves exact operation lock for recovery" "true" \
  "$([[ -d "${kill_scheduler_home}/.claude/.install.lock" \
      && ! -L "${kill_scheduler_home}/.claude/.install.lock" ]] \
    && printf true || printf false)"
assert_eq "SIGKILL leaves durable outer watchdog WAL" "true" \
  "$([[ -f "${kill_scheduler_home}/.claude/.install.lock/watchdog-outer-rollback/meta.tsv" \
      && ! -L "${kill_scheduler_home}/.claude/.install.lock/watchdog-outer-rollback/meta.tsv" ]] \
    && printf true || printf false)"
assert_eq "SIGKILL gap records cleanup-started phase" "cleanup-started" \
  "$(cut -f2 \
    < "${kill_scheduler_home}/.claude/.install.lock/watchdog-outer-rollback/meta.tsv")"
assert_eq "nested helper committed before SIGKILL" "false" \
  "$([[ -e "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
      || -e "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer" ]] \
    && printf true || printf false)"
assert_eq "SIGKILL gap leaves harness bytes untouched" \
  "managed-before-sigkill" \
  "$(cat "${kill_scheduler_home}/.claude/quality-pack/marker")"
assert_eq "SIGKILL gap does not publish staged settings" "{}" \
  "$(tr -d '[:space:]' \
    < "${kill_scheduler_home}/.claude/settings.json")"

OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_READY_FILE="${kill_scheduler_recovered_ready}" \
OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_RELEASE_FILE="${kill_scheduler_recovered_release}" \
PATH="${kill_scheduler_bin}:${PATH}" HOME="${kill_scheduler_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${kill_scheduler_retry_out}" 2>&1 &
kill_scheduler_retry_pid=$!
kill_scheduler_recovery_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${kill_scheduler_recovered_ready}" ]] \
    && { kill_scheduler_recovery_seen=1; break; }
  kill -0 "${kill_scheduler_retry_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "next uninstall reaches durable recovery barrier" "1" \
  "${kill_scheduler_recovery_seen}"
assert_eq "durable recovery restores exact service bytes" "true" \
  "$(cmp -s "${kill_scheduler_home}/service.before" \
      "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.service" \
    && printf true || printf false)"
assert_eq "durable recovery restores exact timer bytes" "true" \
  "$(cmp -s "${kill_scheduler_home}/timer.before" \
      "${kill_scheduler_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
    && printf true || printf false)"
assert_eq "durable recovery restores exact config bytes" "true" \
  "$(cmp -s "${kill_scheduler_home}/conf.before" \
      "${kill_scheduler_home}/.claude/oh-my-claude.conf" \
    && printf true || printf false)"
assert_eq "durable recovery restores enabled state" "enabled" \
  "$(cat "${kill_scheduler_home}/systemctl.enabled")"
assert_eq "durable recovery restores active state" "active" \
  "$(cat "${kill_scheduler_home}/systemctl.active")"
: > "${kill_scheduler_recovered_release}"
kill_scheduler_retry_rc=0
wait "${kill_scheduler_retry_pid}" || kill_scheduler_retry_rc=$?
assert_eq "recovered uninstall safely completes on retry" "0" \
  "${kill_scheduler_retry_rc}"
assert_eq "recovered retry removes harness" "false" \
  "$([[ -e "${kill_scheduler_home}/.claude/quality-pack" \
      || -L "${kill_scheduler_home}/.claude/quality-pack" ]] \
    && printf true || printf false)"
assert_eq "recovered retry releases operation lock" "false" \
  "$([[ -e "${kill_scheduler_home}/.claude/.install.lock" \
      || -L "${kill_scheduler_home}/.claude/.install.lock" ]] \
    && printf true || printf false)"
assert_eq "recovered retry leaves no retired-lock residue" "0" \
  "$(find "${kill_scheduler_home}/.claude" -maxdepth 1 \
      -name '.install-lock-watchdog-recovered.*' -print \
    | wc -l | tr -d '[:space:]')"
assert_eq "recovered retry leaves no private helper residue" "0" \
  "$(find "${kill_scheduler_home}/.claude" -maxdepth 1 \
      -name '.uninstall-watchdog-source.*' -print \
    | wc -l | tr -d '[:space:]')"
assert_eq "recovered retry reports durable recovery" "1" \
  "$(grep -c 'Recovering the exact scheduler/config generation' \
    "${kill_scheduler_retry_out}" 2>/dev/null || true)"

# Exercise every remaining durable outer-WAL recovery branch. Pre-commit
# phases must restore scheduler/config/settings before the retry continues;
# the committed phase must retain the cleaned generation and roll forward.
setup_watchdog_phase_fixture() {
  local fixture_home="${1:-}" fixture_bin="${2:-}"
  local fixture_systemd_dir="${3:-}"
  mkdir -p "${fixture_home}/.claude/quality-pack/scripts" \
    "${fixture_systemd_dir}" "${fixture_bin}"
  printf 'managed-phase-fixture\n' \
    > "${fixture_home}/.claude/quality-pack/marker"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    > "${fixture_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
  chmod 700 \
    "${fixture_home}/.claude/quality-pack/scripts/resume-watchdog.sh"
  printf 'phase-owned-service\n' \
    > "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.service"
  printf 'phase-owned-timer\n' \
    > "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.timer"
  chmod 600 \
    "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.service" \
    "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.timer"
  cp "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.service" \
    "${fixture_home}/service.before"
  cp "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
    "${fixture_home}/timer.before"
  printf '%s\n' \
    'user_setting=phase-preserved' \
    'resume_watchdog=on' \
    'resume_watchdog_scheduler=systemd' \
    "resume_watchdog_systemd_service_sha256=$(sha256_path \
      "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.service")" \
    "resume_watchdog_systemd_timer_sha256=$(sha256_path \
      "${fixture_systemd_dir}/oh-my-claude-resume-watchdog.timer")" \
    > "${fixture_home}/.claude/oh-my-claude.conf"
  cp "${fixture_home}/.claude/oh-my-claude.conf" \
    "${fixture_home}/conf.before"
  printf '%s\n' '{"userKey":"phase-preserved"}' \
    > "${fixture_home}/.claude/settings.json"
  if command -v python3 >/dev/null 2>&1; then
    merge_settings_python "${fixture_home}/.claude/settings.json" \
      "${SETTINGS_PATCH}" false
  else
    merge_settings_jq "${fixture_home}/.claude/settings.json" \
      "${SETTINGS_PATCH}" false
  fi
  cp "${fixture_home}/.claude/settings.json" \
    "${fixture_home}/settings.before"
  printf 'enabled\n' > "${fixture_home}/systemctl.enabled"
  printf 'active\n' > "${fixture_home}/systemctl.active"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "Linux\\n"' \
    > "${fixture_bin}/uname"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${HOME}/systemctl.calls"' \
    'case "$*" in' \
    '  *" show-environment"*) exit 0 ;;' \
    '  *" is-enabled "*)' \
    '    [[ "$(cat "${HOME}/systemctl.enabled")" == "enabled" ]] ;;' \
    '  *" is-active "*)' \
    '    [[ "$(cat "${HOME}/systemctl.active")" == "active" ]] ;;' \
    '  *" disable --now "*)' \
    '    printf "disabled\n" > "${HOME}/systemctl.enabled"' \
    '    printf "inactive\n" > "${HOME}/systemctl.active" ;;' \
    '  *" daemon-reload"*) exit 0 ;;' \
    '  *" enable "*) printf "enabled\n" > "${HOME}/systemctl.enabled" ;;' \
    '  *" start "*) printf "active\n" > "${HOME}/systemctl.active" ;;' \
    'esac' \
    'exit 0' \
    > "${fixture_bin}/systemctl"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "${1:-}" in -l) exit 1 ;; -) cat >/dev/null; exit 0 ;; -r) exit 0 ;; esac' \
    > "${fixture_bin}/crontab"
  chmod +x "${fixture_bin}/uname" "${fixture_bin}/systemctl" \
    "${fixture_bin}/crontab"
}

for recovery_phase in post-captured settings-published-unrecorded \
    settings-published committed; do
  phase_home="${TEST_DIR}/watchdog-phase-${recovery_phase}"
  phase_bin="${phase_home}/bin"
  phase_systemd_dir="${phase_home}/.config/systemd/user"
  phase_ready="${TEST_DIR}/watchdog-phase-${recovery_phase}.ready"
  phase_recovered_ready="${TEST_DIR}/watchdog-phase-${recovery_phase}.recovered-ready"
  phase_recovered_release="${TEST_DIR}/watchdog-phase-${recovery_phase}.recovered-release"
  phase_first_out="${TEST_DIR}/watchdog-phase-${recovery_phase}.first.out"
  phase_retry_out="${TEST_DIR}/watchdog-phase-${recovery_phase}.retry.out"
  setup_watchdog_phase_fixture "${phase_home}" "${phase_bin}" \
    "${phase_systemd_dir}"
  phase_expected_wal_phase="${recovery_phase}"
  case "${recovery_phase}" in
    post-captured)
      phase_ready_variable="OMC_TEST_UNINSTALL_WATCHDOG_POST_CAPTURED_READY_FILE"
      phase_release_variable="OMC_TEST_UNINSTALL_WATCHDOG_POST_CAPTURED_RELEASE_FILE"
      ;;
    settings-published-unrecorded)
      phase_ready_variable="OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_UNRECORDED_READY_FILE"
      phase_release_variable="OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_UNRECORDED_RELEASE_FILE"
      phase_expected_wal_phase="post-captured"
      ;;
    settings-published)
      phase_ready_variable="OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_READY_FILE"
      phase_release_variable="OMC_TEST_UNINSTALL_WATCHDOG_SETTINGS_PUBLISHED_RELEASE_FILE"
      ;;
    committed)
      phase_ready_variable="OMC_TEST_UNINSTALL_WATCHDOG_COMMITTED_READY_FILE"
      phase_release_variable="OMC_TEST_UNINSTALL_WATCHDOG_COMMITTED_RELEASE_FILE"
      ;;
  esac
  env OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
    "${phase_ready_variable}=${phase_ready}" \
    "${phase_release_variable}=${phase_ready}.release" \
    PATH="${phase_bin}:${PATH}" HOME="${phase_home}" \
    bash "${REPO_ROOT}/uninstall.sh" --yes \
    >"${phase_first_out}" 2>&1 &
  phase_pid=$!
  phase_seen=0
  for _wait in $(seq 1 1500); do
    [[ -e "${phase_ready}" ]] && { phase_seen=1; break; }
    kill -0 "${phase_pid}" 2>/dev/null || break
    sleep 0.01
  done
  assert_eq "${recovery_phase} SIGKILL reaches its durable phase barrier" \
    "1" "${phase_seen}"
  if [[ "${phase_seen}" -eq 1 ]]; then
    kill -KILL "${phase_pid}"
  fi
  phase_first_rc=0
  wait "${phase_pid}" 2>/dev/null || phase_first_rc=$?
  assert_eq "${recovery_phase} interruption has signal status" "137" \
    "${phase_first_rc}"
  phase_wal="${phase_home}/.claude/.install.lock/watchdog-outer-rollback"
  assert_eq "${recovery_phase} interruption persists exact WAL phase" \
    "${phase_expected_wal_phase}" \
    "$(cut -f2 "${phase_wal}/meta.tsv" 2>/dev/null || true)"
  phase_path_count="$(cut -f7 \
    "${phase_wal}/meta.tsv" 2>/dev/null || true)"
  phase_parent_rows="$(awk -F '\t' \
    'NF == 12 && $3 ~ /^\// && $4 ~ /^[0-9]+:[0-9]+$/ { n++ }
     END { print n + 0 }' \
    "${phase_wal}/paths.initial.tsv" 2>/dev/null || true)"
  assert_eq "${recovery_phase} WAL binds every target parent path and inode" \
    "${phase_path_count}" "${phase_parent_rows}"
  assert_eq "${recovery_phase} interruption precedes harness deletion" \
    "managed-phase-fixture" \
    "$(cat "${phase_home}/.claude/quality-pack/marker")"
  if [[ "${recovery_phase}" == "settings-published-unrecorded" ]]; then
    assert_eq "unrecorded settings publication is visible before recovery" \
      "false" \
      "$(jq -e '.hooks | type == "object" and length > 0' \
          "${phase_home}/.claude/settings.json" >/dev/null 2>&1 \
        && printf true || printf false)"
    assert_eq "unrecorded settings publication preserves foreign values" \
      "phase-preserved" \
      "$(jq -r '.userKey' "${phase_home}/.claude/settings.json")"
  fi

  # A pathname-preserving replacement of the systemd parent must not inherit
  # the old directory inode's rollback authority.
  if [[ "${recovery_phase}" == "post-captured" ]]; then
    phase_original_parent="${phase_systemd_dir}.original"
    mv -- "${phase_systemd_dir}" "${phase_original_parent}"
    mkdir "${phase_systemd_dir}"
    phase_retarget_out="${TEST_DIR}/watchdog-phase-parent-retarget.out"
    phase_retarget_rc=0
    PATH="${phase_bin}:${PATH}" HOME="${phase_home}" \
      bash "${REPO_ROOT}/uninstall.sh" --yes \
      >"${phase_retarget_out}" 2>&1 || phase_retarget_rc=$?
    assert_eq "retargeted scheduler parent fails recovery closed" "1" \
      "${phase_retarget_rc}"
    assert_eq "retargeted parent receives no restored scheduler files" \
      "0" \
      "$(find "${phase_systemd_dir}" -mindepth 1 -maxdepth 1 -print \
        | wc -l | tr -d '[:space:]')"
    assert_eq "parent-retarget refusal preserves the exact WAL" "true" \
      "$([[ -d "${phase_wal}" && ! -L "${phase_wal}" ]] \
        && printf true || printf false)"
    rmdir "${phase_systemd_dir}"
    mv -- "${phase_original_parent}" "${phase_systemd_dir}"
  fi

  phase_parent_env=()
  if [[ "${recovery_phase}" == "post-captured" ]]; then
    phase_parent_pinned_ready="${TEST_DIR}/watchdog-parent-pinned.ready"
    phase_parent_pinned_release="${TEST_DIR}/watchdog-parent-pinned.release"
    phase_parent_mutated_ready="${TEST_DIR}/watchdog-parent-mutated.ready"
    phase_parent_mutated_release="${TEST_DIR}/watchdog-parent-mutated.release"
    phase_parent_env+=(
      "OMC_TEST_UNINSTALL_WATCHDOG_PARENT_PINNED_READY_FILE=${phase_parent_pinned_ready}"
      "OMC_TEST_UNINSTALL_WATCHDOG_PARENT_PINNED_RELEASE_FILE=${phase_parent_pinned_release}"
      "OMC_TEST_UNINSTALL_WATCHDOG_PARENT_MUTATED_READY_FILE=${phase_parent_mutated_ready}"
      "OMC_TEST_UNINSTALL_WATCHDOG_PARENT_MUTATED_RELEASE_FILE=${phase_parent_mutated_release}"
    )
  fi
  env OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
    OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_READY_FILE="${phase_recovered_ready}" \
    OMC_TEST_UNINSTALL_WATCHDOG_RECOVERED_RELEASE_FILE="${phase_recovered_release}" \
    "${phase_parent_env[@]}" \
    PATH="${phase_bin}:${PATH}" HOME="${phase_home}" \
      bash "${REPO_ROOT}/uninstall.sh" --yes \
      >"${phase_retry_out}" 2>&1 &
  phase_retry_pid=$!
  if [[ "${recovery_phase}" == "post-captured" ]]; then
    phase_parent_pinned_seen=0
    for _wait in $(seq 1 1500); do
      [[ -e "${phase_parent_pinned_ready}" ]] \
        && { phase_parent_pinned_seen=1; break; }
      kill -0 "${phase_retry_pid}" 2>/dev/null || break
      sleep 0.01
    done
    assert_eq "rollback reaches post-pin parent-retarget seam" "1" \
      "${phase_parent_pinned_seen}"
    phase_pinned_original="${phase_systemd_dir}.pinned-original"
    phase_concurrent_parent="${phase_systemd_dir}.concurrent"
    if [[ "${phase_parent_pinned_seen}" -eq 1 ]]; then
      mv -- "${phase_systemd_dir}" "${phase_pinned_original}"
      mkdir "${phase_systemd_dir}"
      printf 'concurrent-parent-must-survive\n' \
        > "${phase_systemd_dir}/sentinel"
    fi
    : > "${phase_parent_pinned_release}"
    phase_parent_mutated_seen=0
    for _wait in $(seq 1 1500); do
      [[ -e "${phase_parent_mutated_ready}" ]] \
        && { phase_parent_mutated_seen=1; break; }
      kill -0 "${phase_retry_pid}" 2>/dev/null || break
      sleep 0.01
    done
    assert_eq "inode-pinned rollback reaches post-mutation seam" "1" \
      "${phase_parent_mutated_seen}"
    assert_eq "inode-pinned rollback restores the recorded parent" "true" \
      "$(cmp -s "${phase_home}/service.before" \
          "${phase_pinned_original}/oh-my-claude-resume-watchdog.service" \
        && printf true || printf false)"
    assert_eq "post-pin replacement parent receives no rollback file" "false" \
      "$([[ -e "${phase_systemd_dir}/oh-my-claude-resume-watchdog.service" \
          || -L "${phase_systemd_dir}/oh-my-claude-resume-watchdog.service" ]] \
        && printf true || printf false)"
    mv -- "${phase_systemd_dir}" "${phase_concurrent_parent}"
    mv -- "${phase_pinned_original}" "${phase_systemd_dir}"
    : > "${phase_parent_mutated_release}"
  fi
  phase_recovery_seen=0
  for _wait in $(seq 1 1500); do
    [[ -e "${phase_recovered_ready}" ]] \
      && { phase_recovery_seen=1; break; }
    kill -0 "${phase_retry_pid}" 2>/dev/null || break
    sleep 0.01
  done
  assert_eq "${recovery_phase} retry reaches recovery inspection barrier" \
    "1" "${phase_recovery_seen}"
  if [[ "${recovery_phase}" == "committed" ]]; then
    assert_eq "committed recovery keeps service removal" "false" \
      "$([[ -e "${phase_systemd_dir}/oh-my-claude-resume-watchdog.service" \
          || -L "${phase_systemd_dir}/oh-my-claude-resume-watchdog.service" ]] \
        && printf true || printf false)"
    assert_eq "committed recovery keeps timer removal" "false" \
      "$([[ -e "${phase_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
          || -L "${phase_systemd_dir}/oh-my-claude-resume-watchdog.timer" ]] \
        && printf true || printf false)"
    assert_eq "committed recovery keeps scheduler disabled" "disabled" \
      "$(cat "${phase_home}/systemctl.enabled")"
    assert_eq "committed recovery keeps scheduler inactive" "inactive" \
      "$(cat "${phase_home}/systemctl.active")"
    assert_eq "committed recovery keeps config roll-forward" "2" \
      "$(grep -Ec \
        '^resume_watchdog(_scheduler)?=off$' \
        "${phase_home}/.claude/oh-my-claude.conf" 2>/dev/null || true)"
    assert_eq "committed recovery keeps cleaned settings generation" \
      "false" \
      "$(jq -e '.hooks | type == "object" and length > 0' \
          "${phase_home}/.claude/settings.json" >/dev/null 2>&1 \
        && printf true || printf false)"
    assert_eq "committed recovery preserves foreign settings" \
      "phase-preserved" \
      "$(jq -r '.userKey' "${phase_home}/.claude/settings.json")"
  else
    assert_eq "${recovery_phase} recovery restores service bytes" "true" \
      "$(cmp -s "${phase_home}/service.before" \
          "${phase_systemd_dir}/oh-my-claude-resume-watchdog.service" \
        && printf true || printf false)"
    assert_eq "${recovery_phase} recovery restores timer bytes" "true" \
      "$(cmp -s "${phase_home}/timer.before" \
          "${phase_systemd_dir}/oh-my-claude-resume-watchdog.timer" \
        && printf true || printf false)"
    assert_eq "${recovery_phase} recovery restores config bytes" "true" \
      "$(cmp -s "${phase_home}/conf.before" \
          "${phase_home}/.claude/oh-my-claude.conf" \
        && printf true || printf false)"
    assert_eq "${recovery_phase} recovery restores settings bytes" "true" \
      "$(cmp -s "${phase_home}/settings.before" \
          "${phase_home}/.claude/settings.json" \
        && printf true || printf false)"
    assert_eq "${recovery_phase} recovery restores enabled state" \
      "enabled" "$(cat "${phase_home}/systemctl.enabled")"
    assert_eq "${recovery_phase} recovery restores active state" \
      "active" "$(cat "${phase_home}/systemctl.active")"
  fi
  : > "${phase_recovered_release}"
  phase_retry_rc=0
  wait "${phase_retry_pid}" || phase_retry_rc=$?
  assert_eq "${recovery_phase} retry completes after recovery" "0" \
    "${phase_retry_rc}"
  assert_eq "${recovery_phase} retry removes harness" "false" \
    "$([[ -e "${phase_home}/.claude/quality-pack" \
        || -L "${phase_home}/.claude/quality-pack" ]] \
      && printf true || printf false)"
  assert_eq "${recovery_phase} retry retires operation lock" "false" \
    "$([[ -e "${phase_home}/.claude/.install.lock" \
        || -L "${phase_home}/.claude/.install.lock" ]] \
      && printf true || printf false)"
  if [[ "${recovery_phase}" == "post-captured" ]]; then
    assert_eq "post-pin replacement parent survives outside rollback" \
      "concurrent-parent-must-survive" \
      "$(cat "${phase_concurrent_parent}/sentinel")"
  fi
done

# Recovery ledgers are exact authority. A raw NUL in the fixed meta row or an
# additional blank path-ledger row must stop before rollback/deletion and leave
# the stranded generation available for inspection.
malformed_wal_home="${TEST_DIR}/watchdog-malformed-wal-home"
malformed_wal_bin="${malformed_wal_home}/bin"
malformed_wal_systemd="${malformed_wal_home}/.config/systemd/user"
malformed_wal_ready="${TEST_DIR}/watchdog-malformed-wal.ready"
malformed_wal_first_out="${TEST_DIR}/watchdog-malformed-wal.first.out"
setup_watchdog_phase_fixture "${malformed_wal_home}" \
  "${malformed_wal_bin}" "${malformed_wal_systemd}"
env OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_WATCHDOG_POST_CAPTURED_READY_FILE="${malformed_wal_ready}" \
  OMC_TEST_UNINSTALL_WATCHDOG_POST_CAPTURED_RELEASE_FILE="${malformed_wal_ready}.release" \
  PATH="${malformed_wal_bin}:${PATH}" HOME="${malformed_wal_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${malformed_wal_first_out}" 2>&1 &
malformed_wal_pid=$!
malformed_wal_seen=0
for _wait in $(seq 1 1500); do
  [[ -e "${malformed_wal_ready}" ]] \
    && { malformed_wal_seen=1; break; }
  kill -0 "${malformed_wal_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "malformed-WAL fixture reaches durable post-capture" "1" \
  "${malformed_wal_seen}"
if [[ "${malformed_wal_seen}" -eq 1 ]]; then
  kill -KILL "${malformed_wal_pid}" 2>/dev/null || true
fi
wait "${malformed_wal_pid}" 2>/dev/null || true
malformed_wal_dir="${malformed_wal_home}/.claude/.install.lock/watchdog-outer-rollback"
cp "${malformed_wal_dir}/meta.tsv" \
  "${malformed_wal_home}/meta.clean"
malformed_meta_line="$(< "${malformed_wal_home}/meta.clean")"
printf '%s\000\n' "${malformed_meta_line}" \
  > "${malformed_wal_dir}/meta.tsv"
malformed_meta_rc=0
PATH="${malformed_wal_bin}:${PATH}" HOME="${malformed_wal_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${malformed_wal_home}/nul-retry.out" 2>&1 || malformed_meta_rc=$?
assert_eq "raw-NUL watchdog WAL metadata fails recovery closed" "1" \
  "${malformed_meta_rc}"
assert_eq "raw-NUL WAL refusal precedes harness deletion" \
  "managed-phase-fixture" \
  "$(cat "${malformed_wal_home}/.claude/quality-pack/marker")"
assert_eq "raw-NUL WAL generation remains inspectable" "true" \
  "$([[ -d "${malformed_wal_dir}" && ! -L "${malformed_wal_dir}" ]] \
    && printf true || printf false)"
cp "${malformed_wal_home}/meta.clean" "${malformed_wal_dir}/meta.tsv"
chmod 600 "${malformed_wal_dir}/meta.tsv"
chmod 600 "${malformed_wal_dir}/paths.initial.tsv"
printf '\n' >> "${malformed_wal_dir}/paths.initial.tsv"
chmod 400 "${malformed_wal_dir}/paths.initial.tsv"
malformed_paths_rc=0
PATH="${malformed_wal_bin}:${PATH}" HOME="${malformed_wal_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
  >"${malformed_wal_home}/blank-retry.out" 2>&1 || malformed_paths_rc=$?
assert_eq "trailing blank watchdog path ledger fails recovery closed" "1" \
  "${malformed_paths_rc}"
assert_eq "blank-row WAL refusal preserves rollback authority" "true" \
  "$([[ -d "${malformed_wal_dir}" && ! -L "${malformed_wal_dir}" ]] \
    && printf true || printf false)"

# The scheduler helper executes after an unbounded confirmation/staging window.
# Seal it into a private generation before that window; a live checkout swap at
# the cleanup barrier must abort without executing replacement code or deleting
# the harness.
watchdog_source_repo="${TEST_DIR}/watchdog-source-race-repo"
watchdog_source_home="${TEST_DIR}/watchdog-source-race-home"
watchdog_source_ready="${TEST_DIR}/watchdog-source-race.ready"
watchdog_source_release="${TEST_DIR}/watchdog-source-race.release"
watchdog_source_out="${TEST_DIR}/watchdog-source-race.out"
watchdog_source_sentinel="${TEST_DIR}/watchdog-source-race.executed"
mkdir -p "${watchdog_source_repo}" \
  "${watchdog_source_home}/.claude/quality-pack"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${watchdog_source_repo}/" \
  >/dev/null
printf 'managed\n' \
  > "${watchdog_source_home}/.claude/quality-pack/marker"
printf '%s\n' 'resume_watchdog=on' \
  > "${watchdog_source_home}/.claude/oh-my-claude.conf"
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_WATCHDOG_SOURCE_READY_FILE="${watchdog_source_ready}" \
  OMC_TEST_UNINSTALL_WATCHDOG_SOURCE_RELEASE_FILE="${watchdog_source_release}" \
  HOME="${watchdog_source_home}" \
    bash "${watchdog_source_repo}/uninstall.sh" --yes \
    >"${watchdog_source_out}" 2>&1
) &
watchdog_source_pid=$!
watchdog_source_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${watchdog_source_ready}" ]] \
    && { watchdog_source_seen=1; break; }
  sleep 0.01
done
assert_eq "watchdog helper race reaches private-source barrier" "1" \
  "${watchdog_source_seen}"
watchdog_private_path=""
if [[ "${watchdog_source_seen}" -eq 1 ]]; then
  watchdog_private_path="$(head -1 "${watchdog_source_ready}" \
    2>/dev/null || true)"
  printf '#!/usr/bin/env bash\nprintf "executed\\n" > %q\n' \
    "${watchdog_source_sentinel}" \
    > "${watchdog_source_repo}/bundle/dot-claude/install-resume-watchdog.sh"
fi
: > "${watchdog_source_release}"
watchdog_source_rc=0
wait "${watchdog_source_pid}" || watchdog_source_rc=$?
assert_eq "live watchdog-helper replacement aborts uninstall" "1" \
  "${watchdog_source_rc}"
assert_eq "replacement watchdog helper is never executed" "false" \
  "$([[ -e "${watchdog_source_sentinel}" ]] && printf true || printf false)"
assert_eq "watchdog helper race preserves harness" "true" \
  "$([[ -f "${watchdog_source_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "private watchdog helper is cleaned on abort" "false" \
  "$([[ -n "${watchdog_private_path}" \
      && ( -e "${watchdog_private_path}" \
        || -L "${watchdog_private_path}" ) ]] \
    && printf true || printf false)"

# A settings-patch parser must consume one verified private snapshot, not
# repeatedly reopen the live repository path. Pause after the snapshot, make
# the live patch malformed, and require validation to reach its second barrier
# using the still-valid snapshot. The EXIT trap must remove that snapshot.
snapshot_race_home="${TEST_DIR}/patch-snapshot-race-home"
snapshot_race_patch="${TEST_DIR}/patch-snapshot-race.json"
snapshot_race_saved="${TEST_DIR}/patch-snapshot-race.saved.json"
snapshot_ready="${TEST_DIR}/patch-snapshot.ready"
snapshot_release="${TEST_DIR}/patch-snapshot.release"
validated_ready="${TEST_DIR}/patch-validated.ready"
validated_release="${TEST_DIR}/patch-validated.release"
snapshot_race_out="${TEST_DIR}/patch-snapshot-race.out"
mkdir -p "${snapshot_race_home}/.claude/quality-pack"
cp "${SETTINGS_PATCH}" "${snapshot_race_patch}"
cp "${SETTINGS_PATCH}" "${snapshot_race_saved}"
printf '%s\n' '{}' >"${snapshot_race_home}/.claude/settings.json"
merge_settings_jq "${snapshot_race_home}/.claude/settings.json" \
  "${SETTINGS_PATCH}" false
printf 'managed\n' >"${snapshot_race_home}/.claude/quality-pack/marker"
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_PATCH_SNAPSHOT_READY_FILE="${snapshot_ready}" \
  OMC_TEST_UNINSTALL_PATCH_SNAPSHOT_RELEASE_FILE="${snapshot_release}" \
  OMC_TEST_UNINSTALL_PATCH_VALIDATED_READY_FILE="${validated_ready}" \
  OMC_TEST_UNINSTALL_PATCH_VALIDATED_RELEASE_FILE="${validated_release}" \
  OMC_TEST_UNINSTALL_ALLOW_SETTINGS_PATCH=1 \
  OMC_TEST_UNINSTALL_SETTINGS_PATCH="${snapshot_race_patch}" \
  HOME="${snapshot_race_home}" \
    bash "${REPO_ROOT}/uninstall.sh" --yes \
    >"${snapshot_race_out}" 2>&1
) &
snapshot_race_pid=$!
snapshot_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${snapshot_ready}" ]] && { snapshot_seen=1; break; }
  sleep 0.01
done
assert_eq "patch snapshot race reaches snapshot barrier" "1" "${snapshot_seen}"
snapshot_private_path="${TEST_DIR}/missing-uninstall-patch-snapshot"
if [[ "${snapshot_seen}" -eq 1 ]]; then
  snapshot_private_path="$(head -1 \
    "${snapshot_ready}" 2>/dev/null || true)"
  [[ -n "${snapshot_private_path}" ]] \
    || snapshot_private_path="${TEST_DIR}/missing-uninstall-patch-snapshot"
  printf '%s\n' '{"hooks":42}' >"${snapshot_race_patch}"
fi
: >"${snapshot_release}"
validated_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${validated_ready}" ]] && { validated_seen=1; break; }
  sleep 0.01
done
assert_eq "live malformed swap cannot feed patch validation" "1" \
  "${validated_seen}"
assert_eq "private snapshot retained original patch bytes" "high" \
  "$(jq -r '.effortLevel' "${snapshot_private_path}" 2>/dev/null || true)"
cp "${snapshot_race_saved}" "${snapshot_race_patch}"
: >"${validated_release}"
wait "${snapshot_race_pid}" || true
assert_eq "uninstall EXIT trap removes private patch snapshot" "false" \
  "$([[ -e "${snapshot_private_path}" || -L "${snapshot_private_path}" ]] \
    && printf true || printf false)"

# The rendered cleanup stage is sealed after validation. Replacing it during
# the deterministic pre-publication barrier must preserve both the user's
# original settings and every managed harness file, and cleanup must remove
# the rejected stage.
stage_race_home="${TEST_DIR}/cleanup-stage-race-home"
stage_ready="${TEST_DIR}/cleanup-stage.ready"
stage_release="${TEST_DIR}/cleanup-stage.release"
stage_race_out="${TEST_DIR}/cleanup-stage-race.out"
mkdir -p "${stage_race_home}/.claude/quality-pack"
printf '%s\n' '{}' >"${stage_race_home}/.claude/settings.json"
merge_settings_jq "${stage_race_home}/.claude/settings.json" \
  "${SETTINGS_PATCH}" false
printf 'managed\n' >"${stage_race_home}/.claude/quality-pack/marker"
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_SETTINGS_STAGE_READY_FILE="${stage_ready}" \
  OMC_TEST_UNINSTALL_SETTINGS_STAGE_RELEASE_FILE="${stage_release}" \
  HOME="${stage_race_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
    >"${stage_race_out}" 2>&1
) &
stage_race_pid=$!
stage_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${stage_ready}" ]] && { stage_seen=1; break; }
  sleep 0.01
done
assert_eq "cleanup stage race reaches publication barrier" "1" "${stage_seen}"
replaced_stage_path="${TEST_DIR}/missing-uninstall-settings-stage"
if [[ "${stage_seen}" -eq 1 ]]; then
  replaced_stage_path="$(head -1 \
    "${stage_ready}" 2>/dev/null || true)"
fi
cleanup_stage_payload_safe=false
if [[ -n "${replaced_stage_path}" \
    && -f "${replaced_stage_path}" \
    && ! -L "${replaced_stage_path}" ]]; then
  cleanup_stage_payload_safe=true
  printf '%s\n' '{"attacker":true}' >"${replaced_stage_path}"
fi
assert_eq "cleanup stage barrier identifies a regular stage" "true" \
  "${cleanup_stage_payload_safe}"
: >"${stage_release}"
stage_race_rc=0
wait "${stage_race_pid}" || stage_race_rc=$?
assert_eq "replaced cleanup stage is refused" "1" "${stage_race_rc}"
assert_eq "replaced cleanup stage never publishes attacker bytes" "false" \
  "$(jq -r '.attacker // false' \
      "${stage_race_home}/.claude/settings.json" 2>/dev/null || true)"
assert_eq "replaced cleanup stage leaves harness untouched" "true" \
  "$([[ -f "${stage_race_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "uninstall EXIT trap removes rejected cleanup stage" "false" \
  "$([[ -e "${replaced_stage_path}" || -L "${replaced_stage_path}" ]] \
    && printf true || printf false)"
assert_eq "cleanup-stage refusal is explicit" "1" \
  "$(grep -c 'rendered cleanup stage was replaced or modified' \
      "${stage_race_out}" 2>/dev/null || true)"

# A supported settings symlink is part of the sealed lexical generation. A
# new symlink inode with identical target text must not inherit the old link's
# publication authority.
link_race_home="${TEST_DIR}/cleanup-link-race-home"
link_race_target="${TEST_DIR}/cleanup-link-race-settings.json"
link_race_ready="${TEST_DIR}/cleanup-link-race.ready"
link_race_release="${TEST_DIR}/cleanup-link-race.release"
link_race_out="${TEST_DIR}/cleanup-link-race.out"
mkdir -p "${link_race_home}/.claude/quality-pack"
printf '%s\n' '{}' > "${link_race_target}"
merge_settings_jq "${link_race_target}" "${SETTINGS_PATCH}" false
ln -s "${link_race_target}" "${link_race_home}/.claude/settings.json"
printf 'managed\n' > "${link_race_home}/.claude/quality-pack/marker"
(
  OMC_TEST_UNINSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_UNINSTALL_SETTINGS_STAGE_READY_FILE="${link_race_ready}" \
  OMC_TEST_UNINSTALL_SETTINGS_STAGE_RELEASE_FILE="${link_race_release}" \
  HOME="${link_race_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
    >"${link_race_out}" 2>&1
) &
link_race_pid=$!
link_race_seen=0
for _wait in $(seq 1 500); do
  [[ -e "${link_race_ready}" ]] && { link_race_seen=1; break; }
  sleep 0.01
done
assert_eq "cleanup symlink race reaches publication barrier" "1" \
  "${link_race_seen}"
if [[ "${link_race_seen}" -eq 1 ]]; then
  rm -f -- "${link_race_home}/.claude/settings.json"
  ln -s "${link_race_target}" "${link_race_home}/.claude/settings.json"
fi
: > "${link_race_release}"
link_race_rc=0
wait "${link_race_pid}" || link_race_rc=$?
assert_eq "same-target replacement cleanup symlink is refused" "1" \
  "${link_race_rc}"
assert_eq "same-target cleanup race leaves harness untouched" "true" \
  "$([[ -f "${link_race_home}/.claude/quality-pack/marker" ]] \
    && printf true || printf false)"
assert_eq "same-target cleanup race preserves managed settings" "true" \
  "$(jq -e '.hooks | type == "object" and length > 0' \
      "${link_race_target}" >/dev/null 2>&1 && printf true || printf false)"

# repo_path is a pathname, not shell text. Exact-key last-row selection trims
# only edge whitespace and preserves interior spaces, apostrophes, and
# backslashes when resolving the owned post-merge hook.
spaced_repo="${TEST_DIR}/repo  two's\\backslash"
repo_path_home="${TEST_DIR}/repo-path-home"
mkdir -p "${spaced_repo}" "${repo_path_home}/.claude/quality-pack"
git -C "${spaced_repo}" init -q
spaced_hook_dir="$(git -C "${spaced_repo}" rev-parse --git-path hooks)"
[[ "${spaced_hook_dir}" == /* ]] \
  || spaced_hook_dir="${spaced_repo}/${spaced_hook_dir}"
mkdir -p "${spaced_hook_dir}"
cp "${REPO_ROOT}/config/post-merge.hook" "${spaced_hook_dir}/post-merge"
printf 'managed\n' > "${repo_path_home}/.claude/quality-pack/marker"
printf 'repo_path=/discarded/first/value\nrepo_path=   %s   \n' \
  "${spaced_repo}" > "${repo_path_home}/.claude/oh-my-claude.conf"
HOME="${repo_path_home}" bash "${REPO_ROOT}/uninstall.sh" --yes \
  >/dev/null 2>&1
assert_eq "last padded repo_path preserves literal pathname bytes" "false" \
  "$([[ -e "${spaced_hook_dir}/post-merge" \
      || -L "${spaced_hook_dir}/post-merge" ]] \
    && printf true || printf false)"

# The two top-level operation-lock implementations are standalone and cannot
# rely on state-io.sh. Exercise their shipped readers directly so raw NUL and
# extra-line credentials never regress to command-substitution normalization.
eval "$(sed -n \
  '/^install_metadata_file_is_canonical()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
eval "$(sed -n \
  '/^install_read_canonical_metadata_snapshot()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
eval "$(sed -n \
  '/^install_read_canonical_metadata_line()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
eval "$(sed -n \
  '/^uninstall_metadata_file_is_canonical()/,/^}/p' \
  "${REPO_ROOT}/uninstall.sh")"
eval "$(sed -n \
  '/^uninstall_read_canonical_metadata_snapshot()/,/^}/p' \
  "${REPO_ROOT}/uninstall.sh")"
eval "$(sed -n \
  '/^uninstall_read_canonical_metadata_line()/,/^}/p' \
  "${REPO_ROOT}/uninstall.sh")"
operation_metadata_probe="${TEST_DIR}/operation-lock-metadata.probe"
printf '424242\n' > "${operation_metadata_probe}"
assert_eq "install lock reader accepts one canonical PID row" "424242" \
  "$(install_read_canonical_metadata_line "${operation_metadata_probe}" 32)"
assert_eq "uninstall lock reader accepts one canonical PID row" "424242" \
  "$(uninstall_read_canonical_metadata_line "${operation_metadata_probe}" 32)"
printf '424242\000\n' > "${operation_metadata_probe}"
assert_eq "install lock reader rejects a raw-NUL PID" "rejected" \
  "$(if install_read_canonical_metadata_line \
      "${operation_metadata_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
assert_eq "uninstall lock reader rejects a raw-NUL PID" "rejected" \
  "$(if uninstall_read_canonical_metadata_line \
      "${operation_metadata_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf '424242\n\n' > "${operation_metadata_probe}"
assert_eq "install lock reader rejects a trailing blank row" "rejected" \
  "$(if install_read_canonical_metadata_line \
      "${operation_metadata_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
assert_eq "uninstall lock reader rejects a trailing blank row" "rejected" \
  "$(if uninstall_read_canonical_metadata_line \
      "${operation_metadata_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"

# Install and uninstall serialize on one operation mutex. Neither side may
# reclaim a pidless/dead-looking lock automatically because the owner may be
# paused between mkdir and metadata publication.
install_lock_block="$(sed -n '/^acquire_install_lock()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
uninstall_lock_block="$(sed -n '/^acquire_uninstall_lock()/,/^}/p' \
  "${REPO_ROOT}/uninstall.sh")"
install_unlock_block="$(sed -n '/^release_install_lock()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
uninstall_unlock_block="$(sed -n '/^release_uninstall_lock()/,/^}/p' \
  "${REPO_ROOT}/uninstall.sh")"
assert_eq "install and uninstall use the same operation lock name" "2" \
  "$({ grep -F '="${CLAUDE_HOME}/.install.lock"' "${REPO_ROOT}/install.sh"; \
       grep -F '="${CLAUDE_HOME}/.install.lock"' "${REPO_ROOT}/uninstall.sh"; } \
      | wc -l | tr -d '[:space:]')"
assert_eq "install lock acquisition never kill-probes/reclaims" "0" \
  "$(grep -Ec 'kill -0|rm -rf' <<<"${install_lock_block}" || true)"
assert_eq "uninstall lock acquisition never kill-probes/reclaims" "0" \
  "$(grep -Ec 'kill -0|rm -rf' <<<"${uninstall_lock_block}" || true)"
assert_eq "install owner publishes release before participant settlement" "1" \
  "$(grep -c 'install_lock_publish_release_marker' \
      <<<"${install_unlock_block}" || true)"
assert_eq "uninstall owner publishes release before participant settlement" "1" \
  "$(grep -c 'uninstall_lock_publish_release_marker' \
      <<<"${uninstall_unlock_block}" || true)"
assert_eq "install last-borrower handoff scans exact participants" "1" \
  "$(grep -c 'participant\.\*' \
      < <(sed -n '/^install_lock_retire_released_generation()/,/^}/p' \
        "${REPO_ROOT}/install.sh") || true)"
assert_eq "uninstall last-borrower handoff scans exact participants" "1" \
  "$(grep -c 'participant\.\*' \
      < <(sed -n '/^uninstall_lock_retire_released_generation()/,/^}/p' \
        "${REPO_ROOT}/uninstall.sh") || true)"

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Uninstall merge tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
