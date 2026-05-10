#!/usr/bin/env bash
#
# v1.37.x Wave 4 follow-up regression tests.
#
# Covers the three low-priority items from the 10-item review:
#
#   Item 6 — shortcut_ratio_gate weighting catch-quality logging.
#            ulw-skip-register.sh now captures which gate was being
#            skipped (joins ulw-skip:registered events to the most
#            recent block via gate_events.jsonl tail-scan).
#            show-report.sh surfaces a per-gate skip-rate sub-table.
#   Item 7 — Cross-session schema migration playbook in
#            CONTRIBUTING.md (worked v1→v2 example).
#   Item 10 — Backup pruning preview in install.sh: pre-prune list of
#            to-be-deleted backups + 5-second Ctrl-C window in
#            interactive mode.

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
    fail_msg "${label}: expected to contain '${needle}', got first 300 chars: ${haystack:0:300}"
  fi
}

# ----------------------------------------------------------------------
# Item 6 — ulw-skip-register.sh records skipped_gate for catch-quality.
# ----------------------------------------------------------------------
printf '\n--- Item 6: skip-register captures which gate was skipped ---\n'

REGISTER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/ulw-skip-register.sh"

# Static-source check: the script tail-scans gate_events.jsonl for the
# most recent block and emits an ulw-skip:registered event with
# skipped_gate detail.
if grep -q "skipped_gate=" "${REGISTER}"; then
  ok
else
  fail_msg "Item 6: ulw-skip-register.sh missing skipped_gate= emission"
fi

if grep -q "select(.event == \"block\")" "${REGISTER}"; then
  ok
else
  fail_msg "Item 6: ulw-skip-register.sh missing 'select(.event == block)' tail-scan"
fi

# Runtime check: invoke the register script with a fixture session
# that has a recent wave-shape block, assert the registered ulw-skip
# event references wave-shape.
i6_home="${TEST_TMP}/i6-home"
mkdir -p "${i6_home}/.claude/quality-pack/state"
ln -sf "${REPO_ROOT}/bundle/dot-claude/skills" "${i6_home}/.claude/skills"

i6_sid="aaaaaaaa-bbbb-cccc-dddd-000000000006"
i6_state="${i6_home}/.claude/quality-pack/state/${i6_sid}"
mkdir -p "${i6_state}"
printf '%s\n' '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_edit_ts":"100"}' > "${i6_state}/session_state.json"

# Seed a recent wave-shape block event.
i6_now="$(date +%s)"
printf '{"_v":1,"ts":%s,"gate":"wave-shape","event":"block","details":{"block_count":1}}\n' \
  "${i6_now}" > "${i6_state}/gate_events.jsonl"

HOME="${i6_home}" \
  STATE_ROOT="${i6_home}/.claude/quality-pack/state" \
  bash "${REGISTER}" "test skip — wave-shape was wrong here" >/dev/null 2>&1 || true

# Read the events file back, find the ulw-skip:registered row, assert
# skipped_gate=wave-shape.
i6_skip_row="$(grep '"gate":"ulw-skip"' "${i6_state}/gate_events.jsonl" | tail -1)"
if [[ -n "${i6_skip_row}" ]] && [[ "${i6_skip_row}" == *'"skipped_gate":"wave-shape"'* ]]; then
  ok
else
  fail_msg "Item 6: ulw-skip-register.sh did not emit skipped_gate=wave-shape (got: ${i6_skip_row})"
fi

# Test the show-report sub-table renders when ulw-skip events present.
# Seed a small cross-session ledger and run show-report.
i6_qp="${i6_home}/.claude/quality-pack"
i6_now_minus_minute=$((i6_now - 60))
cat > "${i6_qp}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${i6_now_minus_minute},"gate":"wave-shape","event":"block","details":{"block_count":1}}
{"_v":1,"ts":${i6_now_minus_minute},"gate":"wave-shape","event":"block","details":{"block_count":1}}
{"_v":1,"ts":${i6_now},"gate":"ulw-skip","event":"registered","details":{"skipped_gate":"wave-shape","reason":"test"}}
{"_v":1,"ts":${i6_now_minus_minute},"gate":"discovered-scope","event":"block","details":{"block_count":1}}
EOF
# Ensure session_summary.jsonl exists so the report doesn't bail.
cat > "${i6_qp}/session_summary.jsonl" <<EOF
{"_v":1,"start_ts":"${i6_now_minus_minute}","session_id":"${i6_sid}","skip_count":1}
EOF

i6_report_out="$(HOME="${i6_home}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh" all 2>/dev/null || true)"

if [[ "${i6_report_out}" == *"Per-gate skip rate"* ]]; then
  ok
else
  fail_msg "Item 6: show-report 'Per-gate skip rate' sub-table missing (snippet: ${i6_report_out:0:500})"
fi

# 2 wave-shape blocks + 1 wave-shape skip = 50% skip rate.
if [[ "${i6_report_out}" == *"\`wave-shape\` | 2 | 1 | 50%"* ]]; then
  ok
else
  fail_msg "Item 6: show-report should show wave-shape with 2 blocks / 1 skip / 50% (snippet: $(printf '%s' "${i6_report_out}" | grep -A 5 'Per-gate skip rate'))"
fi

# ----------------------------------------------------------------------
# Item 7 — CONTRIBUTING.md schema migration playbook (worked example).
# ----------------------------------------------------------------------
printf '\n--- Item 7: CONTRIBUTING.md cross-session schema migration playbook ---\n'

CONTRIBUTING="${REPO_ROOT}/CONTRIBUTING.md"

if grep -q "Worked example: bumping a row schema from \`_v:1\` to \`_v:2\`" "${CONTRIBUTING}"; then
  ok
else
  fail_msg "Item 7: CONTRIBUTING.md missing worked-example heading"
fi

# The playbook must walk all 4 steps the comment names:
# (a) write new writer with _v:2; (b) write reader supporting both;
# (c) sweep job to upgrade old rows OR strict cutoff;
# (d) document in CHANGELOG.
for step_marker in \
  "Step 1 — Add the v2 writer alongside v1" \
  "Step 2 — Make the reader version-aware" \
  "Step 3 — Sweep job OR strict cutoff" \
  "Step 4 — Document in CHANGELOG"; do
  if grep -qF "${step_marker}" "${CONTRIBUTING}"; then
    ok
  else
    fail_msg "Item 7: CONTRIBUTING.md missing '${step_marker}'"
  fi
done

# Common pitfalls section is the audit-trail safety net.
if grep -q "Common pitfalls:" "${CONTRIBUTING}"; then
  ok
else
  fail_msg "Item 7: CONTRIBUTING.md missing 'Common pitfalls' section under the playbook"
fi

# ----------------------------------------------------------------------
# Item 10 — Backup pruning preview in install.sh.
# ----------------------------------------------------------------------
printf '\n--- Item 10: backup pruning preview + interactive Ctrl-C window ---\n'

INSTALL_SH="${REPO_ROOT}/install.sh"

# Source-level checks: pre-prune list, interactive sleep.
if grep -q "Backup retention: keeping" "${INSTALL_SH}"; then
  ok
else
  fail_msg "Item 10: install.sh missing 'Backup retention: keeping' pre-prune line"
fi

if grep -q "will prune.*older:" "${INSTALL_SH}"; then
  ok
else
  fail_msg "Item 10: install.sh missing 'will prune N older:' preview line"
fi

if grep -q "Continuing prune in 5 seconds" "${INSTALL_SH}"; then
  ok
else
  fail_msg "Item 10: install.sh missing 5-second Ctrl-C window message"
fi

# The interactive gate must mirror the existing memory-overwrite shape:
# `[[ -t 0 ]] && [[ -z "${CI:-}" ]]`.
if grep -A 2 "Continuing prune in 5 seconds" "${INSTALL_SH}" | grep -q "sleep 5"; then
  ok
else
  fail_msg "Item 10: install.sh interactive prune missing 'sleep 5' after the warning"
fi

# Runtime: source install.sh's prune_old_backups in a fixture and
# assert the preview is emitted. Build 3 fake backup dirs, set
# KEEP_BACKUPS=1, run prune; expect the preview to name the 2 older.
i10_home="${TEST_TMP}/i10-home"
i10_backups="${i10_home}/.claude/backups"
mkdir -p "${i10_backups}/oh-my-claude-2026-01-01-100000"
mkdir -p "${i10_backups}/oh-my-claude-2026-02-01-100000"
mkdir -p "${i10_backups}/oh-my-claude-2026-03-01-100000"
echo "test" > "${i10_backups}/oh-my-claude-2026-01-01-100000/marker"
echo "test" > "${i10_backups}/oh-my-claude-2026-02-01-100000/marker"
echo "test" > "${i10_backups}/oh-my-claude-2026-03-01-100000/marker"

# Source the function and invoke. Use CI=1 to skip the 5s sleep —
# we still get the preview line + non-interactive "proceeding" line.
# CLAUDE_HOME / BACKUP_DIR / KEEP_BACKUPS are env contract for the fn.
i10_out="$(CLAUDE_HOME="${i10_home}/.claude" \
  BACKUP_DIR="${i10_backups}/oh-my-claude-2026-03-01-100000" \
  KEEP_BACKUPS=1 \
  CI=1 \
  bash -c "
    set -uo pipefail
    # Source the function definition from install.sh without running
    # the full installer. The function lives at top level so a single
    # eval-of-source works.
    eval \"\$(awk '/^prune_old_backups\(\)/,/^}\$/' \"${INSTALL_SH}\")\"
    prune_old_backups
  " 2>&1 || true)"

if [[ "${i10_out}" == *"will prune 2 older:"* ]]; then
  ok
else
  fail_msg "Item 10 runtime: prune preview should say 'will prune 2 older:' (got: ${i10_out:0:400})"
fi

if [[ "${i10_out}" == *"oh-my-claude-2026-01-01-100000"* ]] \
  && [[ "${i10_out}" == *"oh-my-claude-2026-02-01-100000"* ]]; then
  ok
else
  fail_msg "Item 10 runtime: prune preview should name the older dirs (got: ${i10_out:0:400})"
fi

# Most-recent backup (the BACKUP_DIR-equivalent) should NOT be in the
# to-prune list.
if [[ "${i10_out}" != *"will prune"*"oh-my-claude-2026-03-01"* ]] \
   || [[ "${i10_out}" == *"oh-my-claude-2026-03-01-100000"*"will prune"* ]]; then
  # The test is "the to-prune list should not include the newest". A
  # crude grep: is "oh-my-claude-2026-03-01" mentioned BEFORE the
  # "Continuing prune" / "Non-interactive" line? It should NOT be
  # listed as a candidate.
  if printf '%s\n' "${i10_out}" | awk '/will prune/{f=1;next} /Continuing|Non-interactive/{exit} f && /oh-my-claude-2026-03-01/' | grep -q .; then
    fail_msg "Item 10 runtime: newest backup (BACKUP_DIR) appears in prune list"
  else
    ok
  fi
else
  ok
fi

# CI=1 path emits the "Non-interactive" line.
if [[ "${i10_out}" == *"Non-interactive install — proceeding immediately"* ]]; then
  ok
else
  fail_msg "Item 10 runtime: CI=1 should emit 'Non-interactive install' line (got: ${i10_out:0:500})"
fi

# After the prune, only the newest dir remains.
remaining_count=$(find "${i10_backups}" -maxdepth 1 -type d -name 'oh-my-claude-*' | wc -l | tr -d '[:space:]')
if [[ "${remaining_count}" == "1" ]]; then
  ok
else
  fail_msg "Item 10 runtime: expected 1 dir remaining after prune (got: ${remaining_count})"
fi

# ----------------------------------------------------------------------
printf '\n=== v1.37.x W4 follow-up tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
