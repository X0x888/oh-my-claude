#!/usr/bin/env bash
# Run the deliberately small essential Bash test portfolio.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mode="run"
list_only=0
verbose=0
shard_index=1
shard_total=1

usage() {
  printf '%s\n' \
    'Usage: bash tools/run-tests.sh [OPTIONS]' \
    '' \
    'The repository keeps one small essential portfolio, so --changed and' \
    '--full intentionally select the same set.' \
    '' \
    'Options:' \
    '  --changed          Run the essential portfolio (default)' \
    '  --full             Run the essential portfolio' \
    '  --audit            List retained suites and line counts' \
    '  --list             List selected suites without running them' \
    '  --shard N/TOTAL    Run one deterministic shard' \
    '  --verbose          Stream output from passing suites' \
    '  --base REF         Compatibility option; portfolio remains unchanged' \
    '  --no-record        Compatibility option; timing receipts were retired' \
    '  -h, --help         Show this help'
}

die() {
  printf 'run-tests: %s\n' "$1" >&2
  exit "${2:-2}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed|--full) shift ;;
    --audit) mode="audit"; shift ;;
    --list) list_only=1; shift ;;
    --verbose) verbose=1; shift ;;
    --base)
      [[ $# -ge 2 ]] || die "--base requires a git ref"
      shift 2
      ;;
    --shard)
      [[ $# -ge 2 ]] || die "--shard requires N/TOTAL"
      case "$2" in
        [1-9]*'/'[1-9]*)
          shard_index="${2%%/*}"
          shard_total="${2##*/}"
          ;;
        *) die "invalid shard '$2' (expected N/TOTAL)" ;;
      esac
      [[ "${shard_index}" =~ ^[0-9]+$ && "${shard_total}" =~ ^[0-9]+$ ]] \
        || die "invalid shard '$2' (expected positive integers)"
      (( shard_index >= 1 && shard_index <= shard_total )) \
        || die "shard index must be between 1 and ${shard_total}"
      shift 2
      ;;
    --no-record) shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "${REPO_ROOT}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/omc-essential-tests.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT
all_file="${tmp_root}/all"
selected_file="${tmp_root}/selected"

for test_path in tests/test-*.sh; do
  [[ -f "${test_path}" ]] && printf '%s\n' "${test_path}"
done | LC_ALL=C sort > "${all_file}"

test_count="$(wc -l < "${all_file}" | tr -d '[:space:]')"
(( test_count > 0 )) || die "no essential Bash suites found" 1
(( shard_total <= test_count )) \
  || die "shard count ${shard_total} exceeds suite count ${test_count}"

awk -v shard_idx="${shard_index}" -v total="${shard_total}" \
  '((NR - 1) % total) + 1 == shard_idx' "${all_file}" > "${selected_file}"

if [[ "${mode}" == "audit" ]]; then
  printf 'Essential test portfolio: %s Bash suite(s)\n\n' "${test_count}"
  while IFS= read -r test_path; do
    [[ -n "${test_path}" ]] || continue
    printf '%6d  %s\n' "$(wc -l < "${test_path}" | tr -d '[:space:]')" \
      "${test_path}"
  done < "${all_file}"
  printf '\nPolicy: extend a retained owner; add a new suite only for a distinct critical surface.\n'
  exit 0
fi

if (( list_only == 1 )); then
  printf 'Essential Bash suites (shard %s/%s):\n' "${shard_index}" "${shard_total}"
  sed 's/^/  /' "${selected_file}"
  exit 0
fi

pass=0
fail=0
printf 'Running essential Bash suites (shard %s/%s)\n\n' \
  "${shard_index}" "${shard_total}"

while IFS= read -r test_path; do
  [[ -n "${test_path}" ]] || continue
  output_file="${tmp_root}/$(basename "${test_path}").out"
  started="$(date +%s)"
  if bash "${test_path}" </dev/null >"${output_file}" 2>&1; then
    elapsed=$(( $(date +%s) - started ))
    printf 'PASS  %4ss  %s\n' "${elapsed}" "${test_path}"
    (( verbose == 1 )) && cat "${output_file}"
    pass=$((pass + 1))
  else
    elapsed=$(( $(date +%s) - started ))
    printf 'FAIL  %4ss  %s\n' "${elapsed}" "${test_path}" >&2
    tail -120 "${output_file}" >&2
    fail=$((fail + 1))
  fi
done < "${selected_file}"

printf '\nEssential suites: %d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
