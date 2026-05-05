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

pass=0
fail=0

TEST_DIR="$(mktemp -d)"
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
  # Test 3: Mixed-hook entry — an entry containing both an OMC hook and a
  # user hook must be PRESERVED (not all hooks are OMC, so the entry isn't
  # wholly removable without data loss).
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
  assert_json_eq "${impl}: mixed — entry preserved (not fully OMC)" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"
  assert_json_eq "${impl}: mixed — user-logger.sh still present" \
    "${SETTINGS}" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("my-user-logger.sh"))' \
    "true"

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
  cross_assert "valid-omc-hook" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"type":"command","command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh prose"}]}]}}'
  cross_assert "valid-user-hook" '{"hooks": {"SubagentStop": [{"matcher":"my-custom","hooks":[{"type":"command","command":"$HOME/.claude/user.sh"}]}]}}'
  cross_assert "mixed-omc-and-user" '{"hooks": {"SubagentStop": [{"matcher":"editor-critic","hooks":[{"command":"$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},{"command":"$HOME/.claude/user.sh"}]}]}}'

  printf '  Cross-implementation tests done.\n'
fi

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Uninstall merge tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
