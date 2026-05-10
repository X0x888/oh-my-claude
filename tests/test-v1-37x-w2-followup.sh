#!/usr/bin/env bash
#
# v1.37.x Wave 2 follow-up regression tests.
#
# Covers the five UX surface improvements landed in Wave 2 of the
# 10-item commenter review:
#
#   F-002 — drift-check CWD-aware downgrade. When CWD == repo_path
#           (or under it), the drift notice gets calmer copy ("working
#           in source repo — drift is expected during dev") instead of
#           the urgent fix-now framing meant for non-dev projects.
#   F-007 — session-start-whats-new.sh SessionStart hook. Symmetric
#           counterpart to drift-check: when installed_version differs
#           from .last_session_seen_version, emit a one-shot upgrade
#           notice naming /whats-new.
#   F-009 — off_mode_char_cap user-facing surface. When directive_budget=
#           off and the 12000-char hard ceiling fires, append a one-line
#           additionalContext naming the cap so the user knows WHY they
#           saw fewer directives than expected.
#   Item 4 — delivery-contract gate names commit_mode=forbidden + inferred-
#           blocker shape explicitly ("you said don't commit, but edits
#           imply tests/docs are needed").
#   Item 8 — discovered-scope FOR YOU explicitly says "wave-append
#           preferred over defer for same-surface findings".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
ORIG_HOME="${HOME}"
trap 'rm -rf "${TEST_TMP}" 2>/dev/null || true; export HOME="${ORIG_HOME}"' EXIT INT TERM

ok() { pass=$((pass + 1)); }
fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    ok
  else
    fail_msg "${label}: expected to contain '${needle}', got: ${haystack:0:300}"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    ok
  else
    fail_msg "${label}: expected NOT to contain '${needle}', got: ${haystack:0:300}"
  fi
}

# ----------------------------------------------------------------------
# F-002 — drift-check CWD-aware downgrade.
# ----------------------------------------------------------------------
printf '\n--- F-002: drift-check downgrades message when CWD is in repo_path ---\n'

f002_repo="${TEST_TMP}/f002-repo"
mkdir -p "${f002_repo}"
echo '1.99.0' > "${f002_repo}/VERSION"

f002_home="${TEST_TMP}/f002-home"
mkdir -p "${f002_home}/.claude"
ln -sf "${REPO_ROOT}/bundle/dot-claude/skills" "${f002_home}/.claude/skills"
ln -sf "${REPO_ROOT}/bundle/dot-claude/quality-pack" "${f002_home}/.claude/quality-pack"
cat > "${f002_home}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.36.0
repo_path=${f002_repo}
EOF

f002_state="${TEST_TMP}/f002-state"
mkdir -p "${f002_state}/sid-002"
echo '{}' > "${f002_state}/sid-002/session_state.json"

hook_stdin="$(jq -nc --arg sid sid-002 --arg src startup '{session_id:$sid,source:$src}')"

# Case A: PWD is under repo_path → downgraded message.
out_in_repo="$(cd "${f002_repo}" && \
  HOME="${f002_home}" \
  STATE_ROOT="${f002_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-drift-check.sh" <<<"${hook_stdin}" 2>/dev/null || true)"
in_repo_msg="$(printf '%s' "${out_in_repo}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
assert_contains "F-002: in-source-repo emits 'working in source repo'" \
  "working in source repo" "${in_repo_msg}"
assert_contains "F-002: in-source-repo emits 'drift is expected during dev'" \
  "drift is expected during dev" "${in_repo_msg}"
assert_not_contains "F-002: in-source-repo does NOT use urgent 'before relying' framing" \
  "before relying on new gate behavior" "${in_repo_msg}"

# Case B: PWD is unrelated → original urgent message kept.
mkdir -p "${f002_state}/sid-002b"
echo '{}' > "${f002_state}/sid-002b/session_state.json"
hook_stdin_b="$(jq -nc --arg sid sid-002b --arg src startup '{session_id:$sid,source:$src}')"
unrelated_dir="${TEST_TMP}/unrelated-project"
mkdir -p "${unrelated_dir}"
out_outside="$(cd "${unrelated_dir}" && \
  HOME="${f002_home}" \
  STATE_ROOT="${f002_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-drift-check.sh" <<<"${hook_stdin_b}" 2>/dev/null || true)"
outside_msg="$(printf '%s' "${out_outside}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
assert_contains "F-002: outside repo keeps urgent 'Bundle drift detected' framing" \
  "Bundle drift detected" "${outside_msg}"
assert_not_contains "F-002: outside repo does NOT use 'working in source repo'" \
  "working in source repo" "${outside_msg}"

# Case C: gate event records in_source_repo flag (stored as numeric 1
# by record_gate_event when the value is digits; check both shapes for
# safety against future serialization changes).
events_file="${f002_state}/sid-002/gate_events.jsonl"
if [[ -f "${events_file}" ]]; then
  in_repo_event="$(grep '"event":"drift-detected"' "${events_file}" | tail -1)"
  if [[ "${in_repo_event}" == *'"in_source_repo":1'* ]] \
    || [[ "${in_repo_event}" == *'"in_source_repo":"1"'* ]]; then
    ok
  else
    fail_msg "F-002: gate event missing in_source_repo=1 (got: ${in_repo_event})"
  fi
else
  fail_msg "F-002: gate_events.jsonl not written for in-repo drift"
fi

# ----------------------------------------------------------------------
# F-007 — session-start-whats-new.sh emits version-transition notice.
# ----------------------------------------------------------------------
printf '\n--- F-007: whats-new SessionStart hook surfaces version transition ---\n'

f007_home="${TEST_TMP}/f007-home"
mkdir -p "${f007_home}/.claude/quality-pack"
ln -sf "${REPO_ROOT}/bundle/dot-claude/skills" "${f007_home}/.claude/skills"
# Don't symlink quality-pack — we need the DIR to exist for the stamp file.
mkdir -p "${f007_home}/.claude/quality-pack/scripts"
ln -sf "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-whats-new.sh" \
  "${f007_home}/.claude/quality-pack/scripts/session-start-whats-new.sh"
ln -sf "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${f007_home}/.claude/quality-pack/memory" 2>/dev/null || true
cat > "${f007_home}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.99.0
EOF

f007_state="${TEST_TMP}/f007-state"
mkdir -p "${f007_state}/sid-007"
echo '{}' > "${f007_state}/sid-007/session_state.json"

# Case A: stamp file empty (fresh install) → emits the upgrade notice.
hook_stdin_007="$(jq -nc --arg sid sid-007 --arg src startup '{session_id:$sid,source:$src}')"
out_007a="$(HOME="${f007_home}" \
  STATE_ROOT="${f007_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-whats-new.sh" <<<"${hook_stdin_007}" 2>/dev/null || true)"
msg_007a="$(printf '%s' "${out_007a}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
assert_contains "F-007: fresh-install message contains '/whats-new'" \
  "/whats-new" "${msg_007a}"
assert_contains "F-007: fresh-install message names the version" \
  "v1.99.0" "${msg_007a}"
assert_contains "F-007: fresh-install message names /skills index" \
  "/skills" "${msg_007a}"

# Verify stamp written.
stamp_value="$(cat "${f007_home}/.claude/quality-pack/.last_session_seen_version" 2>/dev/null | tr -d '[:space:]')"
if [[ "${stamp_value}" == "1.99.0" ]]; then
  ok
else
  fail_msg "F-007: stamp file should hold '1.99.0', got: ${stamp_value}"
fi

# Case B: same version on next session → no-op.
mkdir -p "${f007_state}/sid-007b"
echo '{}' > "${f007_state}/sid-007b/session_state.json"
hook_stdin_007b="$(jq -nc --arg sid sid-007b --arg src startup '{session_id:$sid,source:$src}')"
out_007b="$(HOME="${f007_home}" \
  STATE_ROOT="${f007_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-whats-new.sh" <<<"${hook_stdin_007b}" 2>/dev/null || true)"
if [[ -z "${out_007b}" ]]; then
  ok
else
  fail_msg "F-007: same-version invocation should no-op (got: ${out_007b:0:200})"
fi

# Case C: simulate upgrade → stamp file holds older version, conf has newer.
printf '1.36.0\n' > "${f007_home}/.claude/quality-pack/.last_session_seen_version"
mkdir -p "${f007_state}/sid-007c"
echo '{}' > "${f007_state}/sid-007c/session_state.json"
hook_stdin_007c="$(jq -nc --arg sid sid-007c --arg src startup '{session_id:$sid,source:$src}')"
out_007c="$(HOME="${f007_home}" \
  STATE_ROOT="${f007_state}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-whats-new.sh" <<<"${hook_stdin_007c}" 2>/dev/null || true)"
msg_007c="$(printf '%s' "${out_007c}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
assert_contains "F-007: upgrade message names old → new transition" \
  "1.36.0" "${msg_007c}"
assert_contains "F-007: upgrade message names new version" \
  "1.99.0" "${msg_007c}"
assert_contains "F-007: upgrade message says 'oh-my-claude updated'" \
  "oh-my-claude updated" "${msg_007c}"

# Case D: disable flag suppresses emission.
mkdir -p "${f007_state}/sid-007d"
echo '{}' > "${f007_state}/sid-007d/session_state.json"
printf '1.36.0\n' > "${f007_home}/.claude/quality-pack/.last_session_seen_version"
hook_stdin_007d="$(jq -nc --arg sid sid-007d --arg src startup '{session_id:$sid,source:$src}')"
out_007d="$(HOME="${f007_home}" \
  STATE_ROOT="${f007_state}" \
  OMC_WHATS_NEW_SESSION_HINT=false \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-whats-new.sh" <<<"${hook_stdin_007d}" 2>/dev/null || true)"
if [[ -z "${out_007d}" ]]; then
  ok
else
  fail_msg "F-007: OMC_WHATS_NEW_SESSION_HINT=false should suppress (got: ${out_007d:0:200})"
fi

# ----------------------------------------------------------------------
# F-009 — off_mode_char_cap user-facing surface.
# ----------------------------------------------------------------------
printf '\n--- F-009: off-mode hard-ceiling user notice ---\n'

ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

# Source-level checks: the surfacing logic is wired.
if grep -q "off_mode_suppression_count" "${ROUTER}"; then
  ok
else
  fail_msg "F-009: prompt-intent-router.sh missing off_mode_suppression_count tracker"
fi

if grep -q "hard-ceiling fired" "${ROUTER}"; then
  ok
else
  fail_msg "F-009: prompt-intent-router.sh missing 'hard-ceiling fired' user notice"
fi

if grep -q "off_mode_first_suppressed" "${ROUTER}"; then
  ok
else
  fail_msg "F-009: prompt-intent-router.sh missing first-suppressed name capture"
fi

# ----------------------------------------------------------------------
# Item 4 — delivery-contract gate names commit_mode=forbidden + inferred shape.
# ----------------------------------------------------------------------
printf '\n--- Item 4: delivery-contract surfaces "you said don\047t commit" shape ---\n'

GUARD="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"

if grep -q "You asked me not to commit" "${GUARD}"; then
  ok
else
  fail_msg "Item 4: stop-guard.sh missing 'You asked me not to commit' surfacing"
fi

if grep -q "commit_mode_state.*forbidden" "${GUARD}"; then
  ok
else
  fail_msg "Item 4: stop-guard.sh missing commit_mode_state == forbidden detection"
fi

if grep -q "inferred_surface_categories" "${GUARD}"; then
  ok
else
  fail_msg "Item 4: stop-guard.sh missing inferred_surface_categories naming"
fi

# Inferred-rule-tag → human-name mapping must include all R-tags currently
# emitted by inferred_contract_blocking_items.
for tag in R1 R2 R3a R3b R4 R5; do
  if grep -qE "\"${tag}\"" "${GUARD}"; then
    ok
  else
    fail_msg "Item 4: stop-guard.sh missing inferred-rule tag mapping for ${tag}"
  fi
done

# ----------------------------------------------------------------------
# Item 8 — discovered-scope FOR YOU explicitly states wave-append preference.
# ----------------------------------------------------------------------
printf '\n--- Item 8: discovered-scope FOR YOU prefers wave-append over defer ---\n'

if grep -q "Preference order:" "${GUARD}"; then
  ok
else
  fail_msg "Item 8: discovered-scope FOR YOU missing 'Preference order:' framing"
fi

if grep -q "preferred over defer when the finding lives in code you're already touching" "${GUARD}"; then
  ok
else
  fail_msg "Item 8: discovered-scope FOR YOU missing wave-append preference rationale"
fi

# Verify it lives inside the discovered-scope dual block. The FOR YOU
# string sits in the format_gate_block_dual call where the FOR MODEL
# arg references "[Discovered-scope gate". Match the full preceding
# format_gate_block_dual line + a few lines after as the bounded
# context window.
discovered_block_lines="$(grep -B 2 -A 6 'Discovered-scope gate' "${GUARD}")"
if [[ "${discovered_block_lines}" == *"Preference order"* ]]; then
  ok
else
  fail_msg "Item 8: 'Preference order' should appear in lines adjacent to '[Discovered-scope gate'"
fi

# ----------------------------------------------------------------------
printf '\n=== v1.37.x W2 follow-up tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
