#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="${SCRIPT_DIR}/scenarios"

usage() {
  cat <<'EOF'
realwork eval harness

Usage:
  bash evals/realwork/run.sh list
  bash evals/realwork/run.sh validate
  bash evals/realwork/run.sh score <result.json>

Result JSON shape for `score`:
  {
    "scenario_id": "targeted-bugfix",
    "tokens": 12345,
    "tool_calls": 42,
    "elapsed_seconds": 300,
    "outcomes": {
      "tests_passed": true,
      "targeted_verification": true
    }
  }
EOF
}

scenario_files() {
  find "${SCENARIO_DIR}" -maxdepth 1 -name '*.json' -type f | LC_ALL=C sort
}

validate_scenario() {
  local file="$1"
  jq -e '
    (.id | type == "string" and length > 0) and
    ((.risk == "low") or (.risk == "medium") or (.risk == "high")) and
    (.fixture | type == "string" and length > 0) and
    (.prompt | type == "string" and length > 0) and
    (.required_outcomes | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.budgets.max_tokens | type == "number") and
    (.budgets.max_tool_calls | type == "number") and
    (.budgets.max_elapsed_seconds | type == "number")
  ' "${file}" >/dev/null
}

cmd_list() {
  scenario_files | while IFS= read -r file; do
    jq -r '"\(.id)\t\(.risk)\t\(.prompt)"' "${file}"
  done
}

cmd_validate() {
  local count=0
  while IFS= read -r file; do
    validate_scenario "${file}"
    count=$((count + 1))
  done < <(scenario_files)
  printf 'Validated %d real-work scenario(s)\n' "${count}"
}

find_scenario_by_id() {
  local id="$1"
  local file
  while IFS= read -r file; do
    if [[ "$(jq -r '.id' "${file}")" == "${id}" ]]; then
      printf '%s\n' "${file}"
      return 0
    fi
  done < <(scenario_files)
  return 1
}

cmd_score() {
  local result_file="${1:-}"
  [[ -n "${result_file}" && -f "${result_file}" ]] || {
    printf 'score requires a result JSON file\n' >&2
    return 2
  }

  local scenario_id scenario_file
  scenario_id="$(jq -r '.scenario_id // empty' "${result_file}")"
  [[ -n "${scenario_id}" ]] || {
    printf 'result missing scenario_id\n' >&2
    return 2
  }
  scenario_file="$(find_scenario_by_id "${scenario_id}")" || {
    printf 'unknown scenario_id: %s\n' "${scenario_id}" >&2
    return 2
  }

  local missing budget_failures score
  missing="$(jq -rn \
    --slurpfile s "${scenario_file}" \
    --slurpfile r "${result_file}" '
      ($s[0].required_outcomes // [])
      | map(select(($r[0].outcomes[.] // false) != true))
      | .[]
    ')"

  budget_failures="$(jq -rn \
    --slurpfile s "${scenario_file}" \
    --slurpfile r "${result_file}" '
      [
        (if (($r[0].tokens // 0) > $s[0].budgets.max_tokens) then "tokens" else empty end),
        (if (($r[0].tool_calls // 0) > $s[0].budgets.max_tool_calls) then "tool_calls" else empty end),
        (if (($r[0].elapsed_seconds // 0) > $s[0].budgets.max_elapsed_seconds) then "elapsed_seconds" else empty end)
      ] | .[]
    ')"

  score=100
  if [[ -n "${missing}" ]]; then
    missing_count="$(printf '%s\n' "${missing}" | grep -c .)"
    score=$((score - missing_count * 12))
  fi
  if [[ -n "${budget_failures}" ]]; then
    budget_count="$(printf '%s\n' "${budget_failures}" | grep -c .)"
    score=$((score - budget_count * 8))
  fi
  (( score < 0 )) && score=0

  jq -nc \
    --arg scenario_id "${scenario_id}" \
    --argjson score "${score}" \
    --arg missing "${missing}" \
    --arg budget_failures "${budget_failures}" '
      {
        scenario_id: $scenario_id,
        score: $score,
        missing_outcomes: ($missing | split("\n") | map(select(length > 0))),
        budget_failures: ($budget_failures | split("\n") | map(select(length > 0))),
        pass: ($score == 100)
      }
    '
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    list) cmd_list ;;
    validate) cmd_validate ;;
    score) cmd_score "$@" ;;
    ""|-h|--help) usage ;;
    *)
      printf 'unknown command: %s\n' "${cmd}" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
