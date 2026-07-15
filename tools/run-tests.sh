#!/usr/bin/env bash
#
# Change-aware Bash test runner and test-portfolio audit.
#
# Iteration is intentionally selective; release validation remains exhaustive:
#
#   bash tools/run-tests.sh                       # impacted working-tree tests
#   bash tools/run-tests.sh --base origin/main    # impacted branch tests
#   bash tools/run-tests.sh --full                # every tests/test-*.sh
#   bash tools/run-tests.sh --full --shard 2/4    # deterministic balanced CI shard
#   bash tools/run-tests.sh --audit               # evidence for keep/merge/retire review
#   bash tools/run-tests.sh --list                # explain without running
#
# Selection is inferred from changed paths, literal producer references, matching
# filenames, and a small set of coordination contracts. An unmapped production
# path fails closed to the full suite. Runtime receipts live under .git/ and are
# never committed. This tool chooses when to run tests; it never declares a test
# obsolete automatically. Retirement needs semantic or mutation-equivalence
# evidence, not age or slowness alone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mode="changed"
base_ref=""
list_only=0
shard_index=1
shard_total=1
record_timings=1
verbose=0

usage() {
  printf '%s\n' \
    'Usage: bash tools/run-tests.sh [MODE] [OPTIONS]' \
    '' \
    'Modes (default: --changed):' \
    '  --changed          Select tests affected by the working tree or --base' \
    '  --full             Select every tests/test-*.sh suite' \
    '  --audit            Review portfolio ownership, cost, and retirement signals' \
    '' \
    'Options:' \
    '  --base REF         Include changes since REF...HEAD' \
    '  --list             Explain the selection without executing it' \
    '  --shard N/TOTAL    Run one deterministic shard of the selection' \
    '  --verbose          Stream complete output from passing tests' \
    '  --no-record        Do not update the uncommitted runtime receipt' \
    '  -h, --help         Show this help'
}

die() {
  printf 'run-tests: %s\n' "$1" >&2
  exit "${2:-2}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed) mode="changed"; shift ;;
    --full) mode="full"; shift ;;
    --audit) mode="audit"; shift ;;
    --base)
      [[ $# -ge 2 ]] || die "--base requires a git ref"
      base_ref="$2"
      shift 2
      ;;
    --list) list_only=1; shift ;;
    --verbose) verbose=1; shift ;;
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
    --no-record) record_timings=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "${REPO_ROOT}"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/omc-run-tests.XXXXXX")"
timing_lockdir_owned=""
timing_lock_token=""

release_owned_timing_lock() {
  local recorded_token=""
  [[ -n "${timing_lockdir_owned}" ]] || return 0
  if [[ -f "${timing_lockdir_owned}/owner" ]]; then
    recorded_token="$(awk -F '\t' 'NR == 1 { print $2 }' \
      "${timing_lockdir_owned}/owner" 2>/dev/null || true)"
  fi
  if [[ -n "${timing_lock_token}" && "${recorded_token}" == "${timing_lock_token}" ]]; then
    rm -f "${timing_lockdir_owned}/owner" 2>/dev/null || true
    rmdir "${timing_lockdir_owned}" 2>/dev/null || true
  fi
  timing_lockdir_owned=""
  timing_lock_token=""
}

cleanup_runner() {
  release_owned_timing_lock
  rm -rf "${tmp_root}"
}

trap cleanup_runner EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
all_file="${tmp_root}/all"
changed_file="${tmp_root}/changed"
reason_file="${tmp_root}/reasons"
selected_file="${tmp_root}/selected"
sharded_file="${tmp_root}/sharded"
weights_file="${tmp_root}/weights"

for test_path in tests/test-*.sh; do
  [[ -f "${test_path}" ]] && printf '%s\n' "${test_path}"
done | LC_ALL=C sort > "${all_file}"
all_count="$(wc -l < "${all_file}" | tr -d '[:space:]')"
(( all_count > 0 )) || die "no tests/test-*.sh files found" 1

select_test() {
  local test_path="$1" reason="$2"
  [[ -f "${test_path}" ]] || return 0
  printf '%s\t%s\n' "${test_path}" "${reason}" >> "${reason_file}"
}

select_all() {
  local reason="$1" test_path
  while IFS= read -r test_path; do
    [[ -n "${test_path}" ]] || continue
    select_test "${test_path}" "${reason}"
  done < "${all_file}"
}

collect_worktree_changes() {
  {
    git -c core.quotepath=false diff --name-only --diff-filter=ACDMRTUXB 2>/dev/null || true
    git -c core.quotepath=false diff --cached --name-only --diff-filter=ACDMRTUXB 2>/dev/null || true
    git -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^$/d' | LC_ALL=C sort -u
}

collect_changed_paths() {
  local worktree_changes base_changes
  worktree_changes="$(collect_worktree_changes)"
  if [[ -n "${base_ref}" ]]; then
    git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1 \
      || die "base ref does not resolve to a commit: ${base_ref}"
    if ! base_changes="$(git -c core.quotepath=false diff --name-only \
      --diff-filter=ACDMRTUXB "${base_ref}...HEAD" 2>/dev/null)"; then
      die "cannot compute changes from ${base_ref}...HEAD (the commits may have no merge base)"
    fi
    {
      printf '%s\n' "${base_changes}"
      printf '%s\n' "${worktree_changes}"
    } | sed '/^$/d' | LC_ALL=C sort -u
  elif [[ -n "${worktree_changes}" ]]; then
    printf '%s\n' "${worktree_changes}"
  elif git rev-parse --verify HEAD^ >/dev/null 2>&1; then
    git -c core.quotepath=false diff-tree --no-commit-id --name-only -r HEAD \
      | sed '/^$/d' | LC_ALL=C sort -u
  else
    git -c core.quotepath=false ls-files | sed '/^$/d' | LC_ALL=C sort -u
  fi
}

reason_line_count() {
  [[ -s "${reason_file}" ]] || { printf '0'; return 0; }
  wc -l < "${reason_file}" | tr -d '[:space:]'
}

select_references_to_path() {
  local changed_path="$1" changed_base test_path
  changed_base="$(basename "${changed_path}")"

  while IFS= read -r test_path; do
    [[ -n "${test_path}" ]] || continue
    select_test "${test_path}" "references ${changed_path}"
  done < <(grep -lF -- "${changed_path}" tests/test-*.sh 2>/dev/null || true)

  # Basename matching catches the repo's common `SCRIPT=.../foo.sh` fixture
  # shape when the full source path is assembled from variables. Avoid generic
  # Markdown/JSON names whose basenames appear throughout historical prose.
  case "${changed_base}" in
    *.sh|*.py)
      while IFS= read -r test_path; do
        [[ -n "${test_path}" ]] || continue
        select_test "${test_path}" "references ${changed_base}"
      done < <(grep -lF -- "${changed_base}" tests/test-*.sh 2>/dev/null || true)
      ;;
  esac
}

select_matching_owner_test() {
  local changed_path="$1" stem parent candidate
  stem="$(basename "${changed_path}")"
  stem="${stem%.*}"
  candidate="tests/test-${stem}.sh"
  [[ -f "${candidate}" ]] && select_test "${candidate}" "matches ${changed_path}"

  case "${changed_path}" in
    bundle/dot-claude/skills/*/SKILL.md)
      parent="$(basename "$(dirname "${changed_path}")")"
      candidate="tests/test-${parent}-skill.sh"
      [[ -f "${candidate}" ]] && select_test "${candidate}" "owns skill ${parent}"
      ;;
    bundle/dot-claude/skills/autowork/scripts/lib/verification.sh)
      select_test "tests/test-verification-lib.sh" "owns verification library"
      ;;
  esac
  return 0
}

select_meta_contracts() {
  select_test "tests/test-coordination-rules.sh" "always-on repository coordination"
  select_test "tests/test-consumer-contracts.sh" "always-on producer/consumer contract lint"
}

if [[ "${mode}" == "full" ]]; then
  select_all "explicit full suite"
elif [[ "${mode}" == "changed" ]]; then
  collect_changed_paths > "${changed_file}"
  changed_count="$(wc -l < "${changed_file}" | tr -d '[:space:]')"
  if (( changed_count > 64 )); then
    select_all "more than 64 changed paths; conservative full fallback"
  else
    select_meta_contracts
    unmapped_production=0
    while IFS= read -r changed_path; do
      [[ -n "${changed_path}" ]] || continue
      # Count reason rows, not unique tests. A changed producer may map to a
      # test that is already selected by an earlier path; that is still a real
      # mapping and must not trigger the conservative full-suite fallback.
      before_count="$(reason_line_count)"

      case "${changed_path}" in
        tests/test-*.sh)
          [[ -f "${changed_path}" ]] && select_test "${changed_path}" "test file changed"
          ;;
        tests/lib/*)
          select_references_to_path "${changed_path}"
          ;;
        *)
          select_matching_owner_test "${changed_path}"
          select_references_to_path "${changed_path}"
          ;;
      esac

      case "${changed_path}" in
        .github/workflows/validate.yml|tools/run-tests.sh|tools/list-ci-pinned-tests.sh|tests/run-sterile.sh)
          select_test "tests/test-local-ci.sh" "CI orchestration changed"
          select_test "tests/test-release.sh" "release test discovery changed"
          ;;
        bundle/dot-claude/quality-pack/memory/*)
          select_test "tests/test-memory-audit.sh" "always-loaded memory changed"
          select_test "tests/test-model-robustness-doctrine.sh" "quality doctrine changed"
          ;;
        bundle/dot-claude/agents/test-automation-engineer.md|bundle/dot-claude/agents/quality-planner.md|bundle/dot-claude/agents/quality-reviewer.md)
          select_test "tests/test-agent-verdict-contract.sh" "agent contract changed"
          ;;
      esac

      after_count="$(reason_line_count)"
      if [[ "${after_count}" == "${before_count}" ]]; then
        case "${changed_path}" in
          *.md)
            select_test "tests/test-coordination-rules.sh" "unmapped documentation; coordination fallback"
            ;;
          tests/*)
            select_test "tests/test-local-ci.sh" "unmapped test support; runner fallback"
            ;;
          .gitignore|.gitattributes|.shellcheckrc|LICENSE)
            select_test "tests/test-coordination-rules.sh" "repository metadata changed"
            ;;
          *)
            unmapped_production=1
            ;;
        esac
      fi
    done < "${changed_file}"

    if (( unmapped_production == 1 )); then
      : > "${reason_file}"
      select_all "unmapped production path; conservative full fallback"
    fi
  fi
fi

timing_file_default=""
if git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
  case "${git_dir}" in
    /*) timing_file_default="${git_dir}/omc-test-times.tsv" ;;
    *) timing_file_default="${REPO_ROOT}/${git_dir}/omc-test-times.tsv" ;;
  esac
fi
timing_file="${OMC_TEST_TIMING_FILE:-${timing_file_default}}"
failure_tail_lines="${OMC_TEST_FAILURE_TAIL_LINES:-120}"
[[ "${failure_tail_lines}" =~ ^[1-9][0-9]*$ ]] \
  || die "OMC_TEST_FAILURE_TAIL_LINES must be a positive integer"
OMC_TEST_TIMING_LOCK_STALE_SECS="${OMC_TEST_TIMING_LOCK_STALE_SECS:-120}"
[[ "${OMC_TEST_TIMING_LOCK_STALE_SECS}" =~ ^[1-9][0-9]*$ ]] \
  || die "OMC_TEST_TIMING_LOCK_STALE_SECS must be a positive integer"
if [[ -n "${timing_file_default}" ]]; then
  failure_log_root="$(dirname "${timing_file_default}")/omc-test-failures"
else
  failure_log_root="${TMPDIR:-/tmp}/omc-test-failures"
fi

latest_timing_for() {
  local test_path="$1"
  [[ -n "${timing_file}" && -f "${timing_file}" ]] || { printf ''; return 0; }
  awk -F '\t' -v test_path="${test_path}" '$1 == test_path { value=$2 } END { print value }' \
    "${timing_file}" 2>/dev/null || true
}

audit_portfolio() {
  local test_path runtime last_changed literal_refs live_refs status signal
  local review_count=0 release_named_count=0 slow_count=0
  printf 'Test portfolio audit\n'
  printf '  tests: %s\n' "${all_count}"
  printf '  principle: age and slowness are review signals, never deletion proof\n\n'
  printf 'Decision\tTest\tRuntime\tEvidence\n'

  while IFS= read -r test_path; do
    [[ -n "${test_path}" ]] || continue
    runtime="$(latest_timing_for "${test_path}")"
    runtime="${runtime:-unknown}"
    last_changed="$(git log -1 --format=%cs -- "${test_path}" 2>/dev/null || true)"
    last_changed="${last_changed:-untracked}"
    literal_refs="$(grep -Eo '(bundle|tools|config|evals|tests)/[A-Za-z0-9_./-]+|(^|[[:space:]"'\''])(install|uninstall|verify)\.sh' \
      "${test_path}" 2>/dev/null \
      | sed -E 's/^[[:space:]"'\'']+//' \
      | sed -E 's/[),;:"'\'']+$//' \
      | LC_ALL=C sort -u || true)"
    live_refs=0
    if [[ -n "${literal_refs}" ]]; then
      while IFS= read -r ref; do
        [[ -e "${ref}" ]] && live_refs=$((live_refs + 1))
      done <<< "${literal_refs}"
    fi

    status="KEEP"
    signal="${live_refs} live owner reference(s); last changed ${last_changed}"
    case "$(basename "${test_path}")" in
      test-v[0-9]*|test-w[0-9]*|*followup*)
        status="REVIEW"
        signal="release-era name; prove unique contract before retaining as a separate file"
        release_named_count=$((release_named_count + 1))
        ;;
    esac
    if [[ "${live_refs}" -eq 0 ]]; then
      status="REVIEW"
      signal="no literal live owner found; inspect dynamic ownership before merge/retire"
    fi
    if [[ "${runtime}" =~ ^[0-9]+$ ]] && (( runtime >= 120 )); then
      slow_count=$((slow_count + 1))
      status="REVIEW"
      signal="${signal}; ${runtime}s latest runtime"
    fi
    [[ "${status}" == "REVIEW" ]] && review_count=$((review_count + 1))
    printf '%s\t%s\t%s\t%s\n' "${status}" "${test_path}" "${runtime}" "${signal}"
  done < "${all_file}"

  printf '\nSummary: %d keep, %d review candidate(s), %d release-era name(s), %d known slow test(s).\n' \
    "$((all_count - review_count))" "${review_count}" "${release_named_count}" "${slow_count}"
  printf 'Retire/merge only after proving the behavior is gone or an existing cheaper test kills the same regression/mutation.\n'
}

if [[ "${mode}" == "audit" ]]; then
  audit_portfolio
  exit 0
fi

LC_ALL=C sort -u "${reason_file}" > "${reason_file}.sorted"
cut -f1 "${reason_file}.sorted" | LC_ALL=C sort -u > "${selected_file}"
selected_count="$(wc -l < "${selected_file}" | tr -d '[:space:]')"
(( selected_count > 0 )) || die "selection produced zero tests" 1
if (( shard_total > selected_count )); then
  die "shard count ${shard_total} exceeds selected test count ${selected_count}; refusing empty shard(s)" 1
fi

# Greedy longest-first assignment keeps the four CI shards close in test LOC,
# a stable proxy available in a fresh checkout. Alphabetic round-robin left a
# 24k-line shard next to a 14k-line shard in this suite, so the nominal
# parallelism still waited on one straggler. Runtime receipts are intentionally
# not used here: concurrent shards must compute the same ownership even while
# those receipts are being updated.
while IFS= read -r test_path; do
  [[ -n "${test_path}" ]] || continue
  test_lines="$(wc -l < "${test_path}" | tr -d '[:space:]')"
  printf '%s\t%s\n' "${test_lines:-1}" "${test_path}"
done < "${selected_file}" \
  | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 > "${weights_file}"

awk -F '\t' -v shard_index="${shard_index}" -v shard_total="${shard_total}" '
  {
    owner = 1
    for (i = 2; i <= shard_total; i++) {
      if (load[i] < load[owner]) owner = i
    }
    load[owner] += $1
    if (owner == shard_index) print $2
  }
' "${weights_file}" | LC_ALL=C sort > "${sharded_file}"
sharded_count="$(wc -l < "${sharded_file}" | tr -d '[:space:]')"
(( sharded_count > 0 )) \
  || die "shard ${shard_index}/${shard_total} selected zero tests; refusing a false-green shard" 1

printf 'Test selection: %s/%s Bash tests' "${selected_count}" "${all_count}"
if (( shard_total > 1 )); then
  printf ' · shard %s/%s (%s tests)' "${shard_index}" "${shard_total}" "${sharded_count}"
fi
printf '\n'
if [[ "${mode}" == "changed" ]]; then
  printf 'Basis: %s\n' "${base_ref:-working tree (or HEAD when clean)}"
fi
printf 'Full suite remains mandatory before release.\n\n'

if (( list_only == 1 )); then
  while IFS= read -r test_path; do
    [[ -n "${test_path}" ]] || continue
    reason="$(awk -F '\t' -v test_path="${test_path}" '$1 == test_path { print $2; exit }' \
      "${reason_file}.sorted")"
    estimate="$(latest_timing_for "${test_path}")"
    if [[ -n "${estimate}" ]]; then
      printf '  %s  [%ss; %s]\n' "${test_path}" "${estimate}" "${reason}"
    else
      printf '  %s  [%s]\n' "${test_path}" "${reason}"
    fi
  done < "${sharded_file}"
  exit 0
fi

timing_lock_mtime() {
  local path="$1" value=""
  value="$(stat -f '%m' "${path}" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+$ ]] \
    || value="$(stat -c '%Y' "${path}" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "${value}"
}

timing_lock_is_stale() {
  local lockdir="$1" observed_owner="$2" owner_pid="" now mtime age
  owner_pid="${observed_owner%%$'\t'*}"
  if [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]] \
      && ! kill -0 "${owner_pid}" 2>/dev/null; then
    return 0
  fi
  now="$(date +%s)"
  mtime="$(timing_lock_mtime "${lockdir}")"
  age=$((now - mtime))
  (( mtime > 0 && age >= OMC_TEST_TIMING_LOCK_STALE_SECS ))
}

acquire_timing_lock() {
  local lockdir="$1" attempts=0 now owner_tmp observed_owner current_owner
  local reaper stale_dir
  while ! mkdir "${lockdir}" 2>/dev/null; do
    observed_owner="$(cat "${lockdir}/owner" 2>/dev/null || true)"
    if timing_lock_is_stale "${lockdir}" "${observed_owner}"; then
      # Serialize reclamation itself. After the old directory moves away a new
      # writer may acquire the canonical path immediately; contenders cannot
      # act on their cached old owner until this reaper mutex is released.
      reaper="${lockdir}.reaper"
      if mkdir "${reaper}" 2>/dev/null; then
        current_owner="$(cat "${lockdir}/owner" 2>/dev/null || true)"
        if [[ "${current_owner}" == "${observed_owner}" ]] \
            && timing_lock_is_stale "${lockdir}" "${current_owner}"; then
          stale_dir="${lockdir}.stale.$$.$RANDOM"
          if mv "${lockdir}" "${stale_dir}" 2>/dev/null; then
            rm -f "${stale_dir}/owner" "${stale_dir}"/owner.tmp.* 2>/dev/null || true
            rmdir "${stale_dir}" 2>/dev/null || true
          fi
        fi
        rmdir "${reaper}" 2>/dev/null || true
        continue
      fi
    fi
    attempts=$((attempts + 1))
    (( attempts < 80 )) || return 1
    sleep 0.05 2>/dev/null || sleep 1
  done

  now="$(date +%s)"
  timing_lock_token="$$-${now}-${RANDOM}"
  owner_tmp="${lockdir}/owner.tmp.$$"
  if ! printf '%s\t%s\t%s\n' "$$" "${timing_lock_token}" "${now}" \
      > "${owner_tmp}" 2>/dev/null \
      || ! mv -f "${owner_tmp}" "${lockdir}/owner" 2>/dev/null; then
    rm -f "${owner_tmp}" 2>/dev/null || true
    rmdir "${lockdir}" 2>/dev/null || true
    timing_lock_token=""
    return 1
  fi
  timing_lockdir_owned="${lockdir}"
  return 0
}

record_timing() {
  local test_path="$1" elapsed="$2" result="$3" now cache_tmp lockdir
  (( record_timings == 1 )) || return 0
  [[ -n "${timing_file}" ]] || return 0
  mkdir -p "$(dirname "${timing_file}")" 2>/dev/null || return 0
  lockdir="${timing_file}.lock"
  acquire_timing_lock "${lockdir}" || return 0
  cache_tmp="${timing_file}.tmp.$$"
  if [[ -f "${timing_file}" ]]; then
    awk -F '\t' -v test_path="${test_path}" '$1 != test_path' \
      "${timing_file}" > "${cache_tmp}" 2>/dev/null || : > "${cache_tmp}"
  else
    : > "${cache_tmp}"
  fi
  now="$(date +%s)"
  printf '%s\t%s\t%s\t%s\n' "${test_path}" "${elapsed}" "${now}" "${result}" \
    >> "${cache_tmp}"
  mv -f "${cache_tmp}" "${timing_file}" 2>/dev/null || rm -f "${cache_tmp}" 2>/dev/null || true
  release_owned_timing_lock
}

printf '\n'
passed=0
started_suite="$(date +%s)"
while IFS= read -r test_path; do
  [[ -n "${test_path}" ]] || continue
  printf 'RUN %s\n' "${test_path}"
  started="$(date +%s)"
  test_log="${tmp_root}/$(basename "${test_path}").log"
  if (( verbose == 1 )); then
    test_rc=0
    bash "${test_path}" || test_rc=$?
  else
    test_rc=0
    bash "${test_path}" > "${test_log}" 2>&1 || test_rc=$?
  fi
  if (( test_rc == 0 )); then
    ended="$(date +%s)"
    elapsed=$((ended - started))
    record_timing "${test_path}" "${elapsed}" "pass"
    passed=$((passed + 1))
  else
    ended="$(date +%s)"
    elapsed=$((ended - started))
    record_timing "${test_path}" "${elapsed}" "fail"
    printf 'FAIL %s (%ss, exit %s)\n' "${test_path}" "${elapsed}" "${test_rc}" >&2
    if (( verbose == 0 )); then
      mkdir -p "${failure_log_root}"
      failure_log="${failure_log_root}/$(basename "${test_path}" .sh).log"
      cp "${test_log}" "${failure_log}"
      printf '\nLast %s log lines:\n' "${failure_tail_lines}" >&2
      tail -n "${failure_tail_lines}" "${test_log}" >&2 || true
      printf '\nFull failure log: %s\n' "${failure_log}" >&2
    fi
    exit "${test_rc}"
  fi
done < "${sharded_file}"
ended_suite="$(date +%s)"
printf '\nTest run passed: %s/%s in %ss\n' "${passed}" "${sharded_count}" "$((ended_suite - started_suite))"
