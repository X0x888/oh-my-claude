#!/usr/bin/env bash
# replay-classifier-telemetry.sh — replay captured prompts against the
# current classifier and flag drift.
#
# Closes the feedback loop on `classifier_telemetry.jsonl` (collected
# since v1.9.0): the data accumulates whether anyone reads it. This
# tool surfaces drift so a new classifier rule can be regression-tested
# against the prompts that previously classified correctly.
#
# Usage:
#   tools/replay-classifier-telemetry.sh                    # replay default fixtures
#   tools/replay-classifier-telemetry.sh path/to/file.jsonl # replay a specific file
#   tools/replay-classifier-telemetry.sh --live             # replay live ~/.claude state
#   tools/replay-classifier-telemetry.sh --known            # report known-misclassified
#                                                           # rows that NOW classify
#                                                           # correctly (promotion check)
#   tools/replay-classifier-telemetry.sh --help
#
# Exit codes:
#   0 — every row matched the recorded classification (no drift)
#       OR (in --known mode) zero rows have been promoted to correct
#   1 — at least one row drifted (regression suspected)
#       OR (in --known mode) one or more rows now classify correctly and
#       should be promoted from known_misclassified.jsonl into regression.jsonl
#   2 — usage error or fixtures file missing
#
# The --known mode loads tools/classifier-fixtures/known_misclassified.jsonl,
# which records prompts whose stored classification is suspected to be wrong
# (the regression net deliberately does NOT pin them, so the classifier is
# free to evolve). Each row in this mode is reported with the inverse
# semantic: a "drift" — meaning the actual classification now differs from
# the stored "wrong" classification — is a *promotion candidate* that should
# move to regression.jsonl. The default replay against regression.jsonl is
# unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_FIXTURES="${REPO_ROOT}/tools/classifier-fixtures/regression.jsonl"
KNOWN_FIXTURES="${REPO_ROOT}/tools/classifier-fixtures/known_misclassified.jsonl"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

mode="fixtures"
fixtures_file="${DEFAULT_FIXTURES}"
verbose=0
# When 1, drift output is inverted: a row that NO LONGER matches the
# stored classification is reported as a promotion candidate (the stored
# classification was suspected wrong, and the classifier has evolved past
# it). Used by --known mode.
inverted=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)     mode="live"; shift ;;
    --known)
      mode="fixtures"
      fixtures_file="${KNOWN_FIXTURES}"
      inverted=1
      shift
      ;;
    --fixtures)
      mode="fixtures"; shift
      if [[ $# -eq 0 ]]; then
        printf 'replay-classifier-telemetry: --fixtures requires a FILE argument\n' >&2
        exit 2
      fi
      fixtures_file="$1"; shift
      ;;
    --verbose|-v) verbose=1; shift ;;
    -h|--help)
      cat <<USAGE
Usage: replay-classifier-telemetry.sh [OPTIONS] [FIXTURES_FILE]

OPTIONS:
  --fixtures FILE   Replay against a specific JSONL fixtures file.
                    Default: tools/classifier-fixtures/regression.jsonl
  --known           Replay against tools/classifier-fixtures/known_misclassified.jsonl;
                    drift is reported as a *promotion candidate* (the row
                    NOW classifies differently from the stored 'suspected
                    wrong' value, suggesting the classifier evolved past
                    the historical bug).
  --live            Replay against live ~/.claude/quality-pack/state/*/classifier_telemetry.jsonl files.
  -v, --verbose     Print one line per row processed.
  -h, --help        Print this help and exit.

Each input row is a JSON object with at minimum:
  prompt_preview   — the prompt text to re-classify (truncated to 200 chars in live data)
  intent           — recorded intent classification
  domain           — recorded domain classification

The replay runs each prompt through classify_task_intent and infer_domain
in the current bundle's common.sh, then compares against the recorded values.

Exit codes:
  0 — no drift (every row classifier-stable)
  1 — at least one drift
  2 — usage error
USAGE
      exit 0
      ;;
    -*)
      printf 'replay-classifier-telemetry: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      fixtures_file="$1"
      mode="fixtures"
      shift
      ;;
  esac
done

# Source the classifier in a synthetic session.
SESSION_ID="replay-tool"
STATE_ROOT="$(mktemp -d)"
trap 'rm -rf "${STATE_ROOT}"' EXIT
# shellcheck disable=SC1090
. "${COMMON_SH}"

declare -i total=0 drift=0 skipped=0
mismatches=()

run_replay_file() {
  local file="$1"
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    # Skip non-object rows (e.g. trailing newlines, accidental edits).
    if ! jq -e 'type == "object"' <<<"${row}" >/dev/null 2>&1; then
      skipped=$((skipped + 1))
      continue
    fi

    local prompt expected_intent expected_domain note
    prompt="$(jq -r '.prompt_preview // .prompt // empty' <<<"${row}")"
    expected_intent="$(jq -r '.intent // empty' <<<"${row}")"
    expected_domain="$(jq -r '.domain // empty' <<<"${row}")"
    note="$(jq -r '.note // empty' <<<"${row}")"

    if [[ -z "${prompt}" || -z "${expected_intent}" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    total=$((total + 1))

    local actual_intent actual_domain
    actual_intent="$(classify_task_intent "${prompt}" 2>/dev/null || echo "<error>")"
    actual_domain="$(infer_domain "${prompt}" 2>/dev/null || echo "<error>")"

    local matched_intent=true
    local matched_domain=true
    [[ "${actual_intent}" != "${expected_intent}" ]] && matched_intent=false
    # Domain comparison is only meaningful when the row has a domain.
    if [[ -n "${expected_domain}" && "${actual_domain}" != "${expected_domain}" ]]; then
      matched_domain=false
    fi

    if [[ "${matched_intent}" == "true" && "${matched_domain}" == "true" ]]; then
      [[ "${verbose}" -eq 1 ]] && printf 'OK    %s | %s | %.60s\n' "${actual_intent}" "${actual_domain}" "${prompt}"
      continue
    fi

    drift=$((drift + 1))
    local detail
    if [[ "${inverted}" -eq 1 ]]; then
      detail="PROMOTION"
    else
      detail="DRIFT"
    fi
    [[ "${matched_intent}" != "true" ]] && detail="${detail} intent ${expected_intent}→${actual_intent}"
    [[ "${matched_domain}" != "true" ]] && detail="${detail} domain ${expected_domain}→${actual_domain}"
    mismatches+=("${detail}")
    mismatches+=("  prompt: $(printf '%.120s' "${prompt}")")
    [[ -n "${note}" ]] && mismatches+=("  note:   ${note}")
  done < "${file}"
}

if [[ "${mode}" == "live" ]]; then
  shopt -s nullglob
  files=("${HOME}/.claude/quality-pack/state"/*/classifier_telemetry.jsonl)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'replay-classifier-telemetry: no live telemetry files found under %s\n' \
      "${HOME}/.claude/quality-pack/state" >&2
    printf 'Hint: this is a usage condition, not a passing run. Run a session under /ulw to populate telemetry, then retry --live.\n' >&2
    exit 2
  fi
  for f in "${files[@]}"; do
    run_replay_file "${f}"
  done
else
  if [[ ! -f "${fixtures_file}" ]]; then
    printf 'replay-classifier-telemetry: fixtures file not found: %s\n' "${fixtures_file}" >&2
    exit 2
  fi
  run_replay_file "${fixtures_file}"
fi

printf '\n--- Replay summary ---\n'
if [[ "${inverted}" -eq 1 ]]; then
  printf 'Mode:    known-misclassified (promotion-check)\n'
else
  printf 'Mode:    %s\n' "${mode}"
fi
printf 'Source:  %s\n' "${fixtures_file:-${HOME}/.claude/quality-pack/state/*/classifier_telemetry.jsonl}"
printf 'Rows:    %d  (skipped: %d)\n' "${total}" "${skipped}"
if [[ "${inverted}" -eq 1 ]]; then
  printf 'Promotions: %d\n' "${drift}"
else
  printf 'Drift:   %d\n' "${drift}"
fi

if [[ "${drift}" -gt 0 ]]; then
  if [[ "${inverted}" -eq 1 ]]; then
    printf '\n--- Promotion candidates ---\n'
    printf '(stored classification %s -- now %s; consider promoting to regression.jsonl)\n' \
      "(suspected-wrong)" "(actual)"
  else
    printf '\n--- Drift details ---\n'
  fi
  for line in "${mismatches[@]}"; do
    printf '%s\n' "${line}"
  done
  exit 1
fi

if [[ "${inverted}" -eq 1 ]]; then
  printf 'No promotion candidates: known-misclassified rows still classify as recorded.\n'
else
  printf 'No drift detected.\n'
fi
exit 0
