#!/usr/bin/env bash
# tests/test-self-audit-and-clusters.sh — regression net for the
# Bug B post-mortem long-term hardening:
#   • /council --self-audit mode (lens roster + protocol override)
#   • tools/cluster-unknown-defects.sh (defect clustering tool)
#   • /ulw-report unknown-bucket nudge in the Patterns footer
#
# These three surfaces exist to convert "self-exemption from our own
# tools" and "unbinned-signal-loss" into structured quarterly review.
# Without a regression net, a future SKILL.md refactor or a
# rename of the cluster-tool's flags can silently break the contract.
#
# Tests:
#   T1  — council/SKILL.md documents `--self-audit` flag
#   T2  — council/SKILL.md documents the fixed self-audit lens roster
#   T3  — council/SKILL.md notes Phase 8 is opt-in under self-audit
#   T4  — CONTRIBUTING.md has a "Quarterly self-audit cadence" section
#   T5  — cluster-unknown-defects.sh script is executable
#   T6  — cluster tool runs cleanly with --bucket unknown on real data
#   T7  — cluster tool --json mode emits parseable JSON
#   T8  — cluster tool exits cleanly on missing-bucket name
#   T9  — cluster tool surfaces total + last_seen + sampled count
#   T10 — show-report.sh has the unknown-bucket nudge heuristic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COUNCIL_SKILL="${REPO_ROOT}/bundle/dot-claude/skills/council/SKILL.md"
CONTRIBUTING="${REPO_ROOT}/CONTRIBUTING.md"
CLUSTER="${REPO_ROOT}/tools/cluster-unknown-defects.sh"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
printf 'T1: council/SKILL.md documents --self-audit flag\n'
council_md="$(cat "${COUNCIL_SKILL}")"
assert_contains "T1: --self-audit flag mentioned" "--self-audit" "${council_md}"
assert_contains "T1: Bug B post-mortem cited as motivator" "Bug B post-mortem" "${council_md}"

# ----------------------------------------------------------------------
printf 'T2: council/SKILL.md names the fixed self-audit lens roster\n'
assert_contains "T2: roster names abstraction-critic" "abstraction-critic" "${council_md}"
assert_contains "T2: roster names oracle"             "oracle"             "${council_md}"
assert_contains "T2: roster names sre-lens"           "sre-lens"           "${council_md}"
assert_contains "T2: roster names quality-researcher" "quality-researcher" "${council_md}"

# ----------------------------------------------------------------------
printf 'T3: council/SKILL.md notes Phase 8 opt-in under self-audit\n'
assert_contains "T3: Phase 8 opt-in language present" "Phase 8 is opt-in" "${council_md}"

# ----------------------------------------------------------------------
printf 'T4: CONTRIBUTING.md has Quarterly self-audit cadence section\n'
contributing_md="$(cat "${CONTRIBUTING}")"
assert_contains "T4: cadence section heading" "Quarterly self-audit cadence" "${contributing_md}"
assert_contains "T4: cadence cites cluster tool" "cluster-unknown-defects.sh" "${contributing_md}"
assert_contains "T4: cadence cites self-audit flag" "/council --self-audit" "${contributing_md}"

# ----------------------------------------------------------------------
printf 'T5: cluster tool is executable\n'
if [[ -x "${CLUSTER}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T5: tool is not executable: %q\n' "${CLUSTER}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'T6: cluster tool runs cleanly with default args (uses real data when present)\n'
# Build a synthetic defect-patterns.json so the test does not depend
# on the developer's real data state.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cat > "${TMP_DIR}/defect-patterns.json" <<'EOF'
{
  "_schema_version": 2,
  "unknown": {
    "count": 247,
    "last_seen_ts": 1777640000,
    "examples": [
      "1. **`tests/test-divergence-directive.sh` is untracked.** git status shows it under Untracked files.",
      "1. **R3 → R5.** R5 invokes the sterile-env runner R3 builds. Without R3, R5 cannot be implemented.",
      "1. **Reviewer-agent 6-step checklist is silently degraded.** New CLAUDE.md line 94 points to CONTRIBUTING.md.",
      "1. **`bytes` field is mislabeled — measures codepoints, not bytes, under UTF-8 locale.**",
      "1. **npm-global rotations.** `claude` from `@anthropic-ai/claude-code` lives at `~/.npm-global/bin/claude`."
    ],
    "last_project_id": "abc12345"
  }
}
EOF

rc=0
output="$(OMC_DEFECT_PATTERNS_FILE="${TMP_DIR}/defect-patterns.json" \
  bash "${CLUSTER}" --sample 5 2>&1 || true)"
OMC_DEFECT_PATTERNS_FILE="${TMP_DIR}/defect-patterns.json" \
  bash "${CLUSTER}" --sample 5 >/dev/null 2>&1 || rc=$?
assert_eq "T6: cluster tool exits 0" "0" "${rc}"
assert_contains "T6: header names bucket" "Defect-cluster review" "${output}"
assert_contains "T6: total defects surfaced" "247" "${output}"

# ----------------------------------------------------------------------
printf 'T7: cluster tool --json emits parseable JSON\n'
json_output="$(OMC_DEFECT_PATTERNS_FILE="${TMP_DIR}/defect-patterns.json" \
  bash "${CLUSTER}" --json --sample 3 2>&1)"
parsed_count="$(jq -r '.total_defects // empty' <<<"${json_output}" 2>&1)"
assert_eq "T7: JSON mode parses + total_defects field present" "247" "${parsed_count}"
parsed_bucket="$(jq -r '.bucket // empty' <<<"${json_output}" 2>&1)"
assert_eq "T7: JSON bucket field" "unknown" "${parsed_bucket}"
parsed_sample_n="$(jq -r '.sampled_examples | length' <<<"${json_output}" 2>&1)"
assert_eq "T7: JSON sample count" "3" "${parsed_sample_n}"

# ----------------------------------------------------------------------
printf 'T8: cluster tool exits cleanly on missing-bucket name\n'
rc=0
output="$(OMC_DEFECT_PATTERNS_FILE="${TMP_DIR}/defect-patterns.json" \
  bash "${CLUSTER}" --bucket nonexistent_bucket 2>&1 || true)"
OMC_DEFECT_PATTERNS_FILE="${TMP_DIR}/defect-patterns.json" \
  bash "${CLUSTER}" --bucket nonexistent_bucket >/dev/null 2>&1 || rc=$?
assert_eq "T8: exit 0 on missing bucket (graceful)" "0" "${rc}"
assert_contains "T8: missing-bucket message names available buckets" "Available buckets" "${output}"

# ----------------------------------------------------------------------
printf 'T9: cluster tool surfaces last_seen_iso, total, and sample count\n'
output="$(OMC_DEFECT_PATTERNS_FILE="${TMP_DIR}/defect-patterns.json" \
  bash "${CLUSTER}" --sample 5 2>&1 || true)"
assert_contains "T9: total row present" "Total defects in bucket" "${output}"
assert_contains "T9: last seen row present" "Last seen" "${output}"
assert_contains "T9: stored examples row present" "Stored examples" "${output}"
assert_contains "T9: sampled row present" "Sampled" "${output}"

# ----------------------------------------------------------------------
printf 'T10: show-report.sh has the unknown-bucket nudge heuristic\n'
show_report_text="$(cat "${SHOW_REPORT}")"
assert_contains "T10: heuristic 7 documented" "Unknown defect bucket" "${show_report_text}"
assert_contains "T10: heuristic cites cluster tool" "cluster-unknown-defects.sh" "${show_report_text}"
assert_contains "T10: threshold is documented (50)" "ge 50" "${show_report_text}"

# ----------------------------------------------------------------------
printf '\n=== Self-Audit & Cluster Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
