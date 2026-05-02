#!/usr/bin/env bash
# test-blindspot-inventory.sh — Wave 1 (v1.28.0) coverage for the
# project-surface scanner + intent-broadening directive.
#
# What this proves:
#   T1.  Scanner emits valid JSON with required schema fields.
#   T2.  Project-type detection — bash / web / python / polyglot.
#   T3.  Cache TTL — fresh cache short-circuits re-scan.
#   T4.  Force flag bypasses TTL.
#   T5.  Disabled flag turns scanner into a no-op.
#   T6.  Conf flag parsing — blindspot_inventory / intent_broadening.
#   T7.  Helper functions — path, summary, is_*_enabled.
#   T8.  Cap — surface arrays do not exceed SURFACE_CAP.
#   T9.  Excludes — vendored / build dirs are not walked.
#   T10. Subcommands — show / path / stale / summary all work.
#   T11. Empty-project fallback — unknown project type still produces JSON.

set -euo pipefail

TEST_NAME="test-blindspot-inventory.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCANNER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/blindspot-inventory.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

# Per-test state directory so tests don't pollute the user's real cache.
TEST_HOME="$(mktemp -d)"
mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts"
mkdir -p "${TEST_HOME}/.claude/quality-pack/blindspots"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state"

# Symlink the scripts the scanner needs into TEST_HOME so the scanner's
# `. "${HOME}/.claude/skills/autowork/scripts/common.sh"` source works.
ln -sf "${COMMON_SH}" "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
for libfile in "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/"*.sh; do
  ln -sf "${libfile}" "${TEST_HOME}/.claude/skills/autowork/scripts/lib/$(basename "${libfile}")"
done

run_scanner() {
  HOME="${TEST_HOME}" \
  STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash "${SCANNER}" "$@"
}

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "${msg}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "${msg}"
    printf '         expected: %s\n         actual:   %s\n' "${expected}" "${actual}"
  fi
}

assert_true() {
  local cond="$1" msg="$2"
  if eval "${cond}"; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "${msg}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "${msg}"
  fi
}

# Build a synthetic project for scanning ---------------------------------------

make_bash_project() {
  local dir="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/tests" "${dir}/scripts" "${dir}/.claude" "${dir}/docs"
  ( cd "${dir}" && git init -q 2>/dev/null ) || true
  cat > "${dir}/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "$HOME"
echo "$OMC_FOO"
EOF
  cat > "${dir}/scripts/build.sh" <<'EOF'
#!/usr/bin/env bash
echo "$BUILD_TARGET"
EOF
  cat > "${dir}/tests/test-foo.sh" <<'EOF'
#!/usr/bin/env bash
echo "test"
EOF
  cat > "${dir}/.claude/oh-my-claude.conf" <<'EOF'
gate_level=full
auto_memory=on
EOF
  cat > "${dir}/README.md" <<'EOF'
# Sample bash project
EOF
  cat > "${dir}/CHANGELOG.md" <<'EOF'
# Changelog
EOF
  cat > "${dir}/CLAUDE.md" <<'EOF'
# Release process

1. Bump VERSION
2. Tag the commit
3. Push tags
EOF
}

make_web_project() {
  local dir="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/src/app/api/users" "${dir}/src/components"
  ( cd "${dir}" && git init -q 2>/dev/null ) || true
  cat > "${dir}/package.json" <<'EOF'
{
  "name": "sample-web",
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "test": "vitest"
  }
}
EOF
  cat > "${dir}/src/app/api/users/route.ts" <<'EOF'
export async function GET() {
  return new Response(JSON.stringify({ users: [] }))
}
export async function POST(req: Request) {
  const body = await req.json()
  return new Response(JSON.stringify({ ok: true }))
}
EOF
  cat > "${dir}/src/components/Button.tsx" <<'EOF'
export function Button() {
  const apiKey = process.env.NEXT_PUBLIC_API_KEY
  return null
}
EOF
  cat > "${dir}/src/components/Login.test.tsx" <<'EOF'
import { test } from 'vitest'
test('renders', () => {})
EOF
  cat > "${dir}/.env.example" <<'EOF'
NEXT_PUBLIC_API_KEY=
DATABASE_URL=
EOF
}

# T1: scanner emits valid JSON --------------------------------------------------
test_t1_valid_json() {
  printf '\nT1: scanner emits valid JSON with required schema fields\n'
  local proj="${TEST_HOME}/proj_t1"
  make_bash_project "${proj}"

  ( cd "${proj}" && run_scanner scan --force ) >/dev/null 2>&1

  local cache
  cache="$(cd "${proj}" && run_scanner path)"
  assert_true "[[ -f '${cache}' ]]" "cache file created at ${cache##*/}"

  if [[ -f "${cache}" ]]; then
    assert_true "jq -e . '${cache}' >/dev/null" "cache is valid JSON"
    assert_true "[[ \"\$(jq -r '.schema_version' '${cache}')\" == '1' ]]" "schema_version=1"
    assert_true "[[ -n \"\$(jq -r '.project_key' '${cache}')\" ]]" "project_key set"
    assert_true "[[ -n \"\$(jq -r '.project_type' '${cache}')\" ]]" "project_type set"
    assert_true "[[ \"\$(jq -r '.scanned_at_ts' '${cache}')\" =~ ^[0-9]+$ ]]" "scanned_at_ts is epoch int"
    assert_true "jq -e '.surfaces.routes' '${cache}' >/dev/null" "surfaces.routes present"
    assert_true "jq -e '.surfaces.env_vars' '${cache}' >/dev/null" "surfaces.env_vars present"
    assert_true "jq -e '.surfaces.tests' '${cache}' >/dev/null" "surfaces.tests present"
    assert_true "jq -e '.surfaces.docs' '${cache}' >/dev/null" "surfaces.docs present"
    assert_true "jq -e '.surfaces.config_flags' '${cache}' >/dev/null" "surfaces.config_flags present"
    assert_true "jq -e '.surfaces.scripts' '${cache}' >/dev/null" "surfaces.scripts present"
  fi
}

# T2: project-type detection ----------------------------------------------------
test_t2_project_type() {
  printf '\nT2: project-type detection\n'
  local proj="${TEST_HOME}/proj_t2_bash"
  make_bash_project "${proj}"
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )
  local cache
  cache="$(HOME="${TEST_HOME}" bash "${SCANNER}" path)"
  # Wait — the cache path depends on cwd. Re-check inside proj.
  ( cd "${proj}" && local p; p="$(run_scanner path)"; assert_true "[[ \"\$(jq -r '.project_type' '${p}')\" == 'bash' ]]" "bash project detected" ) || true

  local proj2="${TEST_HOME}/proj_t2_web"
  make_web_project "${proj2}"
  ( cd "${proj2}" && run_scanner scan --force >/dev/null 2>&1 )
  ( cd "${proj2}" && local p; p="$(run_scanner path)"; assert_true "[[ \"\$(jq -r '.project_type' '${p}')\" == 'web' ]]" "web project detected" ) || true
}

# T3: TTL — fresh cache skips rescan -------------------------------------------
# Diagnostic build (post-v1.28.0 hotfix candidate): capture stderr from every
# subshell and print debug values so a Linux CI failure surfaces the actual
# error instead of silently exiting via set -e. The original shape used
# `( ... >/dev/null 2>&1 )` which suppressed all output — when a subshell
# exited non-zero on Linux bash 5 (passes on macOS bash 3.2), the parent's
# `set -e` killed the test with no FAIL line, no stderr, no diagnostic.
test_t3_ttl() {
  printf '\nT3: fresh cache skips rescan\n'
  local proj="${TEST_HOME}/proj_t3"
  make_bash_project "${proj}"

  local out1 rc1
  out1="$( ( cd "${proj}" && run_scanner scan --force ) 2>&1 )" && rc1=0 || rc1=$?
  if [[ "${rc1}" -ne 0 ]]; then
    printf '  FAIL: first scan rc=%d output:\n%s\n' "${rc1}" "${out1}"
    FAIL=$((FAIL + 1))
    return 0
  fi

  local p
  p="$(cd "${proj}" && run_scanner path)"
  printf '  [diag] T3: cache path=%s\n' "${p}"

  local before_mtime after_mtime
  before_mtime="$(stat -c %Y "${p}" 2>/dev/null || stat -f %m "${p}" 2>/dev/null || echo unknown)"
  printf '  [diag] T3: before_mtime=%s\n' "${before_mtime}"

  sleep 1

  local out2 rc2
  out2="$( ( cd "${proj}" && run_scanner scan ) 2>&1 )" && rc2=0 || rc2=$?
  if [[ "${rc2}" -ne 0 ]]; then
    printf '  FAIL: second (cached) scan rc=%d output:\n%s\n' "${rc2}" "${out2}"
    FAIL=$((FAIL + 1))
    return 0
  fi
  printf '  [diag] T3: second scan stderr/stdout: %s\n' "${out2}"

  after_mtime="$(stat -c %Y "${p}" 2>/dev/null || stat -f %m "${p}" 2>/dev/null || echo unknown)"
  printf '  [diag] T3: after_mtime=%s\n' "${after_mtime}"

  assert_eq "${after_mtime}" "${before_mtime}" "fresh cache not rewritten"
}

# T4: force bypasses TTL --------------------------------------------------------
test_t4_force() {
  printf '\nT4: --force bypasses TTL\n'
  local proj="${TEST_HOME}/proj_t4"
  make_bash_project "${proj}"
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )
  local p
  p="$(cd "${proj}" && run_scanner path)"
  local before_mtime after_mtime
  before_mtime="$(stat -c %Y "${p}" 2>/dev/null || stat -f %m "${p}" 2>/dev/null || echo unknown)"
  sleep 1
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )
  after_mtime="$(stat -c %Y "${p}" 2>/dev/null || stat -f %m "${p}" 2>/dev/null || echo unknown)"
  if [[ "${after_mtime}" -gt "${before_mtime}" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: --force rewrote the cache (%s -> %s)\n' "${before_mtime}" "${after_mtime}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: --force did not rewrite cache (%s == %s)\n' "${before_mtime}" "${after_mtime}"
  fi
}

# T5: disabled flag turns scanner into a no-op ---------------------------------
test_t5_disabled_flag() {
  printf '\nT5: blindspot_inventory=off → scanner no-op\n'
  local proj="${TEST_HOME}/proj_t5"
  make_bash_project "${proj}"
  rm -f "${TEST_HOME}/.claude/quality-pack/blindspots"/*.json
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
    OMC_BLINDSPOT_INVENTORY=off \
    bash -c "cd '${proj}' && bash '${SCANNER}' scan --force" >/dev/null 2>&1 || true
  local count
  count="$(find "${TEST_HOME}/.claude/quality-pack/blindspots" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "${count}" "0" "no cache files written when disabled"
}

# T6: conf flag parsing --------------------------------------------------------
test_t6_conf_parsing() {
  printf '\nT6: conf-file flag parsing for blindspot_inventory and intent_broadening\n'
  # Source common.sh with custom conf to verify parser picks up the flags.
  local conf="${TEST_HOME}/proj_t6/.claude/oh-my-claude.conf"
  mkdir -p "$(dirname "${conf}")"
  printf 'blindspot_inventory=off\nintent_broadening=off\nblindspot_ttl_seconds=12345\n' > "${conf}"
  local out
  out="$(HOME="${TEST_HOME}" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
    bash -c "cd '${TEST_HOME}/proj_t6' && . '${COMMON_SH}' && \
      printf 'inv=%s broad=%s ttl=%s\n' \"\${OMC_BLINDSPOT_INVENTORY}\" \"\${OMC_INTENT_BROADENING}\" \"\${OMC_BLINDSPOT_TTL_SECONDS}\"" 2>&1 | tail -1)"
  assert_eq "${out}" "inv=off broad=off ttl=12345" "all three flags parsed from conf"
}

# T7: helper functions ---------------------------------------------------------
test_t7_helpers() {
  printf '\nT7: helper functions (is_blindspot_inventory_enabled, blindspot_inventory_path, summary)\n'
  local proj="${TEST_HOME}/proj_t7"
  make_bash_project "${proj}"
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )

  # is_blindspot_inventory_enabled returns 0 (true) when on
  local ret
  HOME="${TEST_HOME}" \
    bash -c "cd '${proj}' && . '${COMMON_SH}' && is_blindspot_inventory_enabled" \
    && ret=0 || ret=$?
  assert_eq "${ret}" "0" "is_blindspot_inventory_enabled returns 0 when on"

  HOME="${TEST_HOME}" OMC_BLINDSPOT_INVENTORY=off \
    bash -c "cd '${proj}' && . '${COMMON_SH}' && is_blindspot_inventory_enabled" \
    && ret=0 || ret=$?
  assert_eq "${ret}" "1" "is_blindspot_inventory_enabled returns 1 when off"

  # blindspot_inventory_path returns the cache path
  local got_path
  got_path="$(HOME="${TEST_HOME}" \
    bash -c "cd '${proj}' && . '${COMMON_SH}' && blindspot_inventory_path")"
  assert_true "[[ '${got_path}' == *'.claude/quality-pack/blindspots/'*'.json' ]]" \
    "blindspot_inventory_path returns cache path"

  # blindspot_inventory_summary contains expected keys
  local summary
  summary="$(HOME="${TEST_HOME}" \
    bash -c "cd '${proj}' && . '${COMMON_SH}' && blindspot_inventory_summary")"
  assert_true "[[ '${summary}' == *'type='* ]]" "summary contains type="
  assert_true "[[ '${summary}' == *'total='* ]]" "summary contains total="
}

# T8: surface cap — arrays don't exceed SURFACE_CAP -----------------------------
test_t8_cap() {
  printf '\nT8: surface arrays cap at 50 entries\n'
  local proj="${TEST_HOME}/proj_t8"
  make_bash_project "${proj}"
  # Generate 80 doc files — should be capped at 50 in the docs surface.
  for i in $(seq 1 80); do
    printf '# doc %d\n' "${i}" > "${proj}/docs/doc-${i}.md"
  done
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )
  local p
  p="$(cd "${proj}" && run_scanner path)"
  local doc_count
  doc_count="$(jq '.surfaces.docs | length' "${p}")"
  if [[ "${doc_count}" -le 50 ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: docs count capped at %d (≤ 50)\n' "${doc_count}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: docs count not capped: %d > 50\n' "${doc_count}"
  fi
}

# T9: excludes — vendored dirs not walked --------------------------------------
test_t9_excludes() {
  printf '\nT9: node_modules / .git / vendor dirs excluded\n'
  local proj="${TEST_HOME}/proj_t9"
  make_web_project "${proj}"
  mkdir -p "${proj}/node_modules/foo"
  printf 'export const x = process.env.SECRET_NODE_MODULES_VAR\n' > "${proj}/node_modules/foo/leak.ts"
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )
  local p
  p="$(cd "${proj}" && run_scanner path)"
  local has_leak
  has_leak="$(jq -r '.surfaces.env_vars | map(.name) | index("SECRET_NODE_MODULES_VAR")' "${p}")"
  assert_eq "${has_leak}" "null" "node_modules env var not in inventory"
}

# T10: subcommands --------------------------------------------------------------
test_t10_subcommands() {
  printf '\nT10: subcommands\n'
  local proj="${TEST_HOME}/proj_t10"
  make_bash_project "${proj}"

  # path always returns something
  local p
  p="$(cd "${proj}" && run_scanner path)"
  assert_true "[[ -n '${p}' ]]" "path returns a value"

  # stale exits 0 when no cache
  rm -f "${TEST_HOME}/.claude/quality-pack/blindspots"/*.json
  ( cd "${proj}" && run_scanner stale ) && local stale_no_cache=0 || stale_no_cache=$?
  assert_eq "${stale_no_cache}" "0" "stale=0 when cache missing"

  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 )
  ( cd "${proj}" && run_scanner stale ) && local stale_fresh=0 || stale_fresh=$?
  assert_eq "${stale_fresh}" "1" "stale=1 when cache fresh"

  # show prints JSON
  local show_out
  show_out="$(cd "${proj}" && run_scanner show 2>/dev/null)"
  assert_true "echo '${show_out}' | jq -e . >/dev/null" "show emits valid JSON"

  # summary prints human-readable
  local summary_out
  summary_out="$(cd "${proj}" && run_scanner summary 2>/dev/null)"
  assert_true "[[ '${summary_out}' == *'Project type:'* ]]" "summary contains 'Project type:'"

  # Unknown subcommand returns 2
  ( cd "${proj}" && run_scanner bogus >/dev/null 2>&1 ) && local bad_rc=0 || bad_rc=$?
  assert_eq "${bad_rc}" "2" "unknown subcommand returns 2"
}

# T11: empty / unknown project ---------------------------------------------------
test_t11_unknown_project() {
  printf '\nT11: empty/unknown project still produces JSON\n'
  local proj="${TEST_HOME}/proj_t11"
  rm -rf "${proj}"
  mkdir -p "${proj}"
  ( cd "${proj}" && git init -q 2>/dev/null ) || true
  ( cd "${proj}" && run_scanner scan --force >/dev/null 2>&1 ) || true
  local p
  p="$(cd "${proj}" && run_scanner path)"
  if [[ -f "${p}" ]]; then
    assert_true "jq -e . '${p}' >/dev/null" "JSON produced for empty project"
    local pt
    pt="$(jq -r '.project_type' "${p}")"
    assert_true "[[ '${pt}' == 'unknown' || '${pt}' == 'bash' ]]" \
      "empty project_type is 'unknown' or 'bash' (got ${pt})"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: no cache produced for empty project\n'
  fi
}

# Run all tests ---------------------------------------------------------------

printf '%s\n' "================================================================================"
printf '%s\n' "${TEST_NAME}"
printf '%s\n' "================================================================================"

test_t1_valid_json
test_t2_project_type
test_t3_ttl
test_t4_force
test_t5_disabled_flag
test_t6_conf_parsing
test_t7_helpers
test_t8_cap
test_t9_excludes
test_t10_subcommands
test_t11_unknown_project

# Cleanup
rm -rf "${TEST_HOME}"

printf '\n%s\n' "--------------------------------------------------------------------------------"
printf 'Results: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '%s\n' "--------------------------------------------------------------------------------"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
