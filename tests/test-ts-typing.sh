#!/usr/bin/env bash
# tests/test-ts-typing.sh — regression net for the cross-ledger `ts`
# typing convention (v1.42.x F-010).
#
# Background. v1.31.0 Wave 4 introduced the convention that timestamp
# fields in JSONL ledgers are integers (`--argjson ts`), not strings
# (`--arg ts`). record-serendipity.sh:108 documents the convention;
# data-lens F-010 found it had drifted on five other record-*.sh sites:
#
#   - record-pending-agent.sh
#   - record-archetype.sh
#   - record-subagent-summary.sh
#   - ulw-correct-record.sh (×2)
#
# Cross-ledger joins (`select(.ts >= $cutoff)` etc.) silently drop
# string-typed rows unless every consumer wraps with `tonumber?`.
# This test grep-asserts that no `record-*.sh` re-introduces
# `--arg ts ` outside the documentation comment.
#
# This script exits non-zero on any violation. CI-pinned in
# .github/workflows/validate.yml.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

if [[ ! -d "${SCRIPTS_DIR}" ]]; then
  printf >&2 'FAIL: scripts dir not found at %s\n' "${SCRIPTS_DIR}"
  exit 2
fi

# Scan every script that writes JSONL/JSON rows with timestamps:
# record-*.sh ledger writers + common.sh (the findings.json + alert
# row writers at common.sh:6086 / 6173) + lib/canary.sh (canary
# event rows) + lib/classifier.sh (classifier telemetry rows). The
# v1.42.x post-Wave-2 review found the original scope was too narrow:
# fixing only record-*.sh missed 6 sibling sites that emitted string
# `ts` and broke cross-ledger numeric joins on shipped data.
RECORD_SCRIPTS=()
while IFS= read -r _f; do
  RECORD_SCRIPTS+=("${_f}")
done < <(find "${SCRIPTS_DIR}" -maxdepth 1 -name 'record-*.sh' -type f | sort)
if [[ -f "${SCRIPTS_DIR}/common.sh" ]]; then
  RECORD_SCRIPTS+=("${SCRIPTS_DIR}/common.sh")
fi
if [[ -d "${SCRIPTS_DIR}/lib" ]]; then
  while IFS= read -r _f; do
    RECORD_SCRIPTS+=("${_f}")
  done < <(find "${SCRIPTS_DIR}/lib" -maxdepth 1 -name '*.sh' -type f | sort)
fi

if [[ ${#RECORD_SCRIPTS[@]} -eq 0 ]]; then
  printf >&2 'FAIL: no record-*.sh / common.sh / lib scripts found — test premise wrong\n'
  exit 2
fi

# Grep for `--arg ts ` (with trailing space — the jq invocation form,
# not a substring match like `--arg ts_human`). Strip out lines that
# are bash/awk comments to avoid false positives in convention notes.
violations=0
violation_report=""
for f in "${RECORD_SCRIPTS[@]}"; do
  # awk: skip lines whose first non-whitespace char is `#` (comment).
  # Match `--arg ts ` (space-terminated to avoid `ts_*` false positives).
  bad="$(awk '
    /^[[:space:]]*#/ { next }
    /--arg ts / { print FILENAME ":" NR ": " $0 }
  ' "${f}" || true)"

  if [[ -n "${bad}" ]]; then
    violation_report+="${bad}"$'\n'
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      violations=$(( violations + 1 ))
    done <<<"${bad}"
  fi
done

if [[ ${violations} -gt 0 ]]; then
  printf >&2 'FAIL: %d --arg ts site(s) in record-*.sh (must be --argjson ts; ts is integer everywhere per v1.31.0 W4 convention; see record-serendipity.sh:108 for the documented note)\n\n%s\n' \
    "${violations}" "${violation_report}"
  exit 1
fi

# Positive assertion: at least one --argjson ts must exist (otherwise
# the test is trivially passing because no record-*.sh writes ts at all).
argjson_count="$(grep -l -- '--argjson ts' "${RECORD_SCRIPTS[@]}" 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${argjson_count}" -eq 0 ]]; then
  printf >&2 'FAIL: no record-*.sh uses --argjson ts — convention not adopted anywhere; check that record-serendipity.sh and the other ledger-writers still write timestamps\n'
  exit 1
fi

printf 'PASS: 0 --arg ts violations in %d record-*.sh script(s); %d use --argjson ts.\n' \
  "${#RECORD_SCRIPTS[@]}" "${argjson_count}"
exit 0
