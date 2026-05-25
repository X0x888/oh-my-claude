#!/usr/bin/env bash
#
# tests/test-release.sh — regression net for tools/release.sh
# (v1.32.14 R4 closure from the v1.32.0 release post-mortem).
#
# The release tool wraps CONTRIBUTING.md steps 7-14 into a single
# command. This test exercises the validation paths, dry-run mode,
# and a local-origin real release against a fixture git repo.
# GitHub-hosted destructive flows (gh release create, Actions watch)
# are intentionally NOT exercised.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL_REAL="${REPO_ROOT}/tools/release.sh"
RELEASE_AUTOMATION_SURFACE_LIST_HELPER_REAL="${REPO_ROOT}/tools/list-release-automation-surfaces.sh"
ATTEST_WORKFLOW_REAL="${REPO_ROOT}/.github/workflows/attest-release-assets.yml"
CONTRIBUTING_REAL="${REPO_ROOT}/CONTRIBUTING.md"
AGENTS_REAL="${REPO_ROOT}/AGENTS.md"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_jq_eq() {
  local label="$1" query="$2" expected="$3" json="$4"
  local actual=""
  actual="$(printf '%s' "${json}" | jq -r "${query}")"
  assert_eq "${label}" "${expected}" "${actual}"
}

assert_true() {
  local label="$1" expr="$2"
  if eval "${expr}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expression=%s\n' "${label}" "${expr}" >&2
    fail=$((fail + 1))
  fi
}

assert_git_ref_exists() {
  local label="$1" repo="$2" ref="$3"
  if git -C "${repo}" rev-parse --verify "${ref}" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing git ref: %s\n    repo: %s\n' "${label}" "${ref}" "${repo}" >&2
    fail=$((fail + 1))
  fi
}

assert_git_dir_ref_exists() {
  local label="$1" git_dir="$2" ref="$3"
  if git --git-dir="${git_dir}" rev-parse --verify "${ref}" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing git ref: %s\n    git_dir: %s\n' "${label}" "${ref}" "${git_dir}" >&2
    fail=$((fail + 1))
  fi
}

mk_release_fixture() {
  local repo
  repo="$(mktemp -d -t release-test-XXXXXX)"
  (
    cd "${repo}" || exit 1
    git init -q -b main
    git config user.email "test@example.test"
    git config user.name "Test"
    mkdir -p tools tests
    while IFS= read -r relpath; do
      [[ -n "${relpath}" ]] || continue
      mkdir -p "$(dirname "${relpath}")"
      cp "${REPO_ROOT}/${relpath}" "${relpath}"
    done < <(bash "${RELEASE_AUTOMATION_SURFACE_LIST_HELPER_REAL}")
    while IFS= read -r relpath; do
      [[ "${relpath}" == tools/* ]] || continue
      chmod +x "${relpath}"
    done < <(bash "${RELEASE_AUTOMATION_SURFACE_LIST_HELPER_REAL}")
    cat > .github/workflows/validate.yml <<'YML'
name: Validate
on:
  push:
  pull_request:
jobs:
  fixture:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: fixture smoke
        run: bash tests/test-fixture-smoke.sh
YML
    cat > tests/test-fixture-smoke.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'fixture smoke ok\n' >/dev/null
SH
    chmod +x tests/test-fixture-smoke.sh
    printf '1.0.0\n' > VERSION
    cat > README.md <<'MD'
# Test
[![Version](https://img.shields.io/badge/Version-1.0.0-blue.svg)]

OMC_REF=v1.0.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh)"

OMC_REF=v1.0.0 \
OMC_EXPECTED_SHA=<release-commit-sha-or-prefix> \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh)"

git clone --branch v1.0.0 https://github.com/X0x888/oh-my-claude.git ~/.local/share/oh-my-claude
MD
    cat > CHANGELOG.md <<'CL'
# Changelog

## [Unreleased]

### Added

- placeholder for next release

## [1.0.0] - 2026-01-01

initial.
CL
    # gitignore the hotfix-sweep marker so its presence doesn't
    # trip the dirty-tree check before release.sh detects it.
    printf '.hotfix-sweep-quick\n' > .gitignore
    git add -A
    git commit -q -m "initial"
  ) || return 1
  printf '%s' "${repo}"
}

cleanup_fixture() {
  local repo="$1"
  [[ -n "${repo}" && -d "${repo}" && "${repo}" == */release-test-* ]] && rm -rf "${repo}"
}

mk_path_without_jq() {
  local bindir cmd real
  bindir="$(mktemp -d -t release-path-XXXXXX)"
  # Strip jq while keeping the core CLI surface that release.sh and its
  # helper scripts legitimately exercise during real runs.
  for cmd in dirname git cat tr sort head grep date awk perl bash sh env mktemp rm wc find xargs tail; do
    real="$(command -v "${cmd}" 2>/dev/null || true)"
    if [[ -z "${real}" ]]; then
      rm -rf "${bindir}"
      return 1
    fi
    ln -sf "${real}" "${bindir}/${cmd}"
  done
  printf '%s' "${bindir}"
}

cleanup_path_fixture() {
  local bindir="$1"
  [[ -n "${bindir}" && -d "${bindir}" && "${bindir}" == */release-path-* ]] && rm -rf "${bindir}"
}

mk_gh_stub() {
  local bindir
  bindir="$(mktemp -d -t gh-stub-XXXXXX)"
  cat > "${bindir}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

canonical_release_url() {
  local tag="$1" repo host repo_path
  repo="${GH_STUB_REPO_NAME_WITH_OWNER:-example/fixture}"
  if [[ "${repo}" == */*/* ]]; then
    host="${repo%%/*}"
    repo_path="${repo#*/}"
  else
    host="github.com"
    repo_path="${repo}"
  fi
  printf 'https://%s/%s/releases/tag/%s' "${host}" "${repo_path}" "${tag}"
}

resolve_release_path() {
  local file_var_name="$1" dir_var_name="$2" tag="$3" suffix="$4"
  local direct="${!file_var_name:-}" dir="${!dir_var_name:-}"
  if [[ -n "${direct}" ]]; then
    printf '%s' "${direct}"
    return 0
  fi
  if [[ -n "${dir}" ]]; then
    printf '%s/%s%s' "${dir}" "${tag}" "${suffix}"
    return 0
  fi
  return 1
}

read_release_value() {
  local file_var_name="$1" dir_var_name="$2" tag="$3" suffix="$4" default_value="$5"
  local path
  path="$(resolve_release_path "${file_var_name}" "${dir_var_name}" "${tag}" "${suffix}" || true)"
  if [[ -n "${path}" && -f "${path}" ]]; then
    cat "${path}"
  else
    printf '%s' "${default_value}"
  fi
}

write_release_value() {
  local file_var_name="$1" dir_var_name="$2" tag="$3" suffix="$4" value="$5"
  local path
  path="$(resolve_release_path "${file_var_name}" "${dir_var_name}" "${tag}" "${suffix}" || true)"
  [[ -n "${path}" ]] || return 1
  mkdir -p "$(dirname "${path}")"
  printf '%s' "${value}" > "${path}"
}

workflow_exists_stub() {
  local workflow="$1"
  if [[ -n "${GH_STUB_WORKFLOW_LIST_FILE:-}" && -f "${GH_STUB_WORKFLOW_LIST_FILE}" ]]; then
    grep -Fq "$(printf '%s\t' "${workflow}")" "${GH_STUB_WORKFLOW_LIST_FILE}"
  elif [[ -n "${GH_STUB_WORKFLOW_LIST_TSV:-}" ]]; then
    printf '%s\n' "${GH_STUB_WORKFLOW_LIST_TSV}" | grep -Fq "$(printf '%s\t' "${workflow}")"
  else
    [[ "${workflow}" == "attest-release-assets.yml" ]]
  fi
}

print_workflow_stub() {
  local workflow="$1"
  if [[ -n "${GH_STUB_WORKFLOW_LIST_FILE:-}" && -f "${GH_STUB_WORKFLOW_LIST_FILE}" ]]; then
    grep -F "$(printf '%s\t' "${workflow}")" "${GH_STUB_WORKFLOW_LIST_FILE}" | head -1 | awk -F '\t' '{print $1 "\t" $2 "\t" $3 "\t" $4}'
  elif [[ -n "${GH_STUB_WORKFLOW_LIST_TSV:-}" ]]; then
    printf '%s\n' "${GH_STUB_WORKFLOW_LIST_TSV}" | grep -F "$(printf '%s\t' "${workflow}")" | head -1
  else
    printf 'Attest Release Assets\tactive\t1001\t.github/workflows/attest-release-assets.yml\n'
  fi
}

run_registry_file() {
  [[ -n "${GH_STUB_RUN_REGISTRY_FILE:-}" ]] || return 1
  printf '%s' "${GH_STUB_RUN_REGISTRY_FILE}"
}

ensure_run_registry() {
  local file
  file="$(run_registry_file)" || return 1
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
}

next_run_id() {
  local file max_id
  file="$(run_registry_file)" || return 1
  if [[ ! -s "${file}" ]]; then
    printf '%s' "${GH_STUB_RUN_START_ID:-9001}"
    return 0
  fi
  max_id="$(awk -F '\t' 'BEGIN{max=0} NF{if ($1+0>max) max=$1+0} END{print max+1}' "${file}")"
  printf '%s' "${max_id}"
}

append_run_record() {
  local id="$1" workflow="$2" commit="$3" tag="$4" status="$5" conclusion="$6"
  local file
  file="$(run_registry_file)" || return 1
  ensure_run_registry || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${workflow}" "${commit}" "${tag}" "${status}" "${conclusion}" >> "${file}"
}

find_run_record_by_id() {
  local id="$1" file
  file="$(run_registry_file)" || return 1
  [[ -f "${file}" ]] || return 1
  awk -F '\t' -v id="${id}" '$1 == id {print; found=1; exit} END {if (!found) exit 1}' "${file}"
}

find_run_id_for_commit() {
  local workflow="$1" commit="$2" file
  file="$(run_registry_file)" || return 1
  [[ -f "${file}" ]] || return 1
  awk -F '\t' -v wf="${workflow}" -v sha="${commit}" '$2 == wf && $3 == sha {id=$1} END {if (id != "") print id}' "${file}"
}

append_attested_tag() {
  local tag="$1"
  local file
  [[ -n "${GH_STUB_ATTESTED_TAGS_FILE:-}" ]] || return 0
  file="${GH_STUB_ATTESTED_TAGS_FILE}"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  if ! grep -Fxq "${tag}" "${file}"; then
    printf '%s\n' "${tag}" >> "${file}"
  fi
}

release_asset_dir() {
  local tag="$1"
  [[ -n "${GH_STUB_RELEASE_ASSET_ROOT:-}" ]] || return 1
  printf '%s/%s' "${GH_STUB_RELEASE_ASSET_ROOT}" "${tag}"
}

store_release_asset() {
  local tag="$1" src="$2" asset_dir base
  asset_dir="$(release_asset_dir "${tag}" || true)"
  [[ -n "${asset_dir}" ]] || return 1
  mkdir -p "${asset_dir}"
  base="$(basename "${src}")"
  cp "${src}" "${asset_dir}/${base}"
}

download_release_assets() {
  local tag="$1" dest_dir="$2"
  shift 2
  local asset_dir matched_any pattern file base
  asset_dir="$(release_asset_dir "${tag}" || true)"
  [[ -n "${asset_dir}" && -d "${asset_dir}" ]] || return 1
  mkdir -p "${dest_dir}"
  for pattern in "$@"; do
    matched_any=0
    while IFS= read -r -d '' file; do
      base="$(basename "${file}")"
      if [[ "${base}" == ${pattern} ]]; then
        cp "${file}" "${dest_dir}/${base}"
        matched_any=1
      fi
    done < <(find "${asset_dir}" -maxdepth 1 -type f -print0)
    [[ "${matched_any}" -eq 1 ]] || return 1
  done
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  attestation)
    sub="${1:-}"
    shift || true
    case "${sub}" in
      verify)
        artifact="${1:-}"
        shift || true
        signer_workflow=""
        source_ref=""
        repo_slug=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) repo_slug="$2"; shift 2 ;;
            --signer-workflow) signer_workflow="$2"; shift 2 ;;
            --source-ref) source_ref="$2"; shift 2 ;;
            --format) shift 2 ;;
            --deny-self-hosted-runners) shift ;;
            *) shift ;;
          esac
        done
        [[ -f "${artifact}" ]] || { printf 'gh stub: missing artifact for attestation verify: %s\n' "${artifact}" >&2; exit 1; }
        base="$(basename "${artifact}")"
        if [[ "${base}" =~ ^oh-my-claude-v([0-9]+\.[0-9]+\.[0-9]+)\.(tar\.gz|zip|SHA256SUMS)$ ]]; then
          version="${BASH_REMATCH[1]}"
        else
          printf 'gh stub: unsupported attestation artifact name: %s\n' "${base}" >&2
          exit 1
        fi
        tag="v${version}"
        expected_repo="${GH_STUB_REPO_NAME_WITH_OWNER:-example/fixture}"
        expected_signer="${GH_STUB_ATTESTATION_SIGNER_WORKFLOW:-${expected_repo}/.github/workflows/attest-release-assets.yml}"
        expected_source_ref="${GH_STUB_ATTESTATION_SOURCE_REF_PREFIX:-refs/tags/}${tag}"
        if [[ -n "${repo_slug}" && "${repo_slug}" != "${expected_repo}" ]]; then
          printf 'gh stub: attestation repo mismatch\n' >&2
          exit 1
        fi
        if [[ -n "${signer_workflow}" && "${signer_workflow}" != "${expected_signer}" ]]; then
          printf 'gh stub: attestation signer workflow mismatch\n' >&2
          exit 1
        fi
        if [[ -n "${source_ref}" && "${source_ref}" != "${expected_source_ref}" ]]; then
          printf 'gh stub: attestation source ref mismatch\n' >&2
          exit 1
        fi
        attested="false"
        if [[ -n "${GH_STUB_ATTESTED_TAGS_FILE:-}" && -f "${GH_STUB_ATTESTED_TAGS_FILE}" ]]; then
          if grep -Fxq "${tag}" "${GH_STUB_ATTESTED_TAGS_FILE}"; then
            attested="true"
          fi
        elif [[ -n "${GH_STUB_ATTESTED_TAGS:-}" ]]; then
          if printf '%s\n' "${GH_STUB_ATTESTED_TAGS}" | grep -Fxq "${tag}"; then
            attested="true"
          fi
        fi
        if [[ "${attested}" != "true" ]]; then
          printf 'gh stub: no matching attestations found for %s\n' "${tag}" >&2
          exit 1
        fi
        printf 'verified\n'
        ;;
      *)
        printf 'gh stub: unsupported attestation subcommand: %s\n' "${sub}" >&2
        exit 1
        ;;
    esac
    ;;
  workflow)
    sub="${1:-}"
    shift || true
    case "${sub}" in
      view)
        workflow="${1:-}"
        shift || true
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --ref|--repo) shift 2 ;;
            --yaml|--web) shift ;;
            *) shift ;;
          esac
        done
        workflow_exists_stub "${workflow}" || { printf 'HTTP 404: workflow %s not found on the default branch\n' "${workflow}" >&2; exit 1; }
        print_workflow_stub "${workflow}"
        ;;
      list)
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo|-R|--limit|-L|--json|--jq|-a|--all) shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ -n "${GH_STUB_WORKFLOW_LIST_FILE:-}" && -f "${GH_STUB_WORKFLOW_LIST_FILE}" ]]; then
          cut -f1-4 "${GH_STUB_WORKFLOW_LIST_FILE}"
        elif [[ -n "${GH_STUB_WORKFLOW_LIST_TSV:-}" ]]; then
          printf '%s\n' "${GH_STUB_WORKFLOW_LIST_TSV}"
        else
          printf 'Attest Release Assets\tactive\t1001\t.github/workflows/attest-release-assets.yml\n'
        fi
        ;;
      run)
        workflow="${1:-}"
        shift || true
        workflow_exists_stub "${workflow}" || { printf 'HTTP 404: workflow %s not found on the default branch\n' "${workflow}" >&2; exit 1; }
        ref=""
        tag_input=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo|-R) shift 2 ;;
            --ref|-r) ref="$2"; shift 2 ;;
            -f|--raw-field|-F|--field)
              if [[ "$2" == tag=* ]]; then
                tag_input="${2#tag=}"
              fi
              shift 2
              ;;
            *) shift ;;
          esac
        done
        tag="${tag_input:-${ref}}"
        [[ -n "${tag}" ]] || { printf 'gh stub: workflow run requires tag/ref\n' >&2; exit 1; }
        commit="$(read_release_value "GH_STUB_WORKFLOW_DISPATCH_SHA_FILE" "GH_STUB_WORKFLOW_DISPATCH_SHA_DIR" "${tag}" ".txt" "${GH_STUB_TAG_OBJECT_SHA:-1111111111111111111111111111111111111111}")"
        id="$(next_run_id)"
        append_run_record "${id}" "${workflow}" "${commit}" "${tag}" "completed" "success" || { printf 'gh stub: run registry not configured\n' >&2; exit 1; }
        printf 'created workflow run %s\n' "${id}"
        ;;
      *)
        printf 'gh stub: unsupported workflow subcommand: %s\n' "${sub}" >&2
        exit 1
        ;;
    esac
    ;;
  repo)
    sub="${1:-}"
    shift || true
    [[ "${sub}" == "view" ]] || { printf 'gh stub: unsupported repo subcommand: %s\n' "${sub}" >&2; exit 1; }
    printf '%s\n' "${GH_STUB_REPO_NAME_WITH_OWNER:-example/fixture}"
    ;;
  api)
    endpoint="${1:-}"
    shift || true
    jq_expr=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --jq) jq_expr="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "${endpoint}" in
      repos/*/git/ref/tags/*)
        case "${jq_expr}" in
          .object.type) printf '%s\n' "${GH_STUB_TAG_OBJECT_TYPE:-commit}" ;;
          .object.sha) printf '%s\n' "${GH_STUB_TAG_OBJECT_SHA:-1111111111111111111111111111111111111111}" ;;
          *) printf 'gh stub: unsupported ref jq: %s\n' "${jq_expr}" >&2; exit 1 ;;
        esac
        ;;
      repos/*/git/tags/*)
        [[ "${jq_expr}" == ".object.sha" ]] || { printf 'gh stub: unsupported annotated-tag jq: %s\n' "${jq_expr}" >&2; exit 1; }
        printf '%s\n' "${GH_STUB_ANNOTATED_TAG_TARGET_SHA:-2222222222222222222222222222222222222222}"
        ;;
      repos/*/releases/tags/*)
        tag="${endpoint##*/}"
        if [[ "$(read_release_value "GH_STUB_RELEASE_BY_TAG_FILE" "GH_STUB_RELEASE_BY_TAG_DIR" "${tag}" ".txt" "true")" != "true" ]]; then
          printf 'gh: Not Found (HTTP 404)\n' >&2
          exit 1
        fi
        case "${jq_expr}" in
          .html_url)
            read_release_value "GH_STUB_RELEASE_URL_FILE" "GH_STUB_RELEASE_URL_DIR" "${tag}" ".txt" "$(canonical_release_url "${tag}")"
            ;;
          .tag_name)
            printf '%s\n' "${tag}"
            ;;
          *)
            printf 'gh stub: unsupported releases-by-tag jq: %s\n' "${jq_expr}" >&2
            exit 1
            ;;
        esac
        ;;
      *)
        printf 'gh stub: unsupported api endpoint: %s\n' "${endpoint}" >&2
        exit 1
        ;;
    esac
    ;;
  release)
    sub="${1:-}"
    shift || true
    case "${sub}" in
      list)
        if [[ -n "${GH_STUB_RELEASE_LIST_TAGS_FILE:-}" && -f "${GH_STUB_RELEASE_LIST_TAGS_FILE}" ]]; then
          cat "${GH_STUB_RELEASE_LIST_TAGS_FILE}"
        else
          printf '%s' "${GH_STUB_RELEASE_LIST_TAGS:-}"
        fi
        ;;
      view)
        tag="${1:-}"
        shift || true
        jq_expr=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --json) shift 2 ;;
            --jq) jq_expr="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "${jq_expr}" in
          .name)
            read_release_value "GH_STUB_RELEASE_NAME_FILE" "GH_STUB_RELEASE_NAME_DIR" "${tag}" ".txt" "${GH_STUB_RELEASE_NAME:-}"
            ;;
          .body)
            read_release_value "GH_STUB_RELEASE_BODY_FILE" "GH_STUB_RELEASE_BODY_DIR" "${tag}" ".txt" "${GH_STUB_RELEASE_BODY:-}"
            ;;
          .tagName)
            printf '%s\n' "${tag}"
            ;;
          .isDraft)
            read_release_value "GH_STUB_RELEASE_DRAFT_FILE" "GH_STUB_RELEASE_DRAFT_DIR" "${tag}" ".txt" "false"
            ;;
          .isPrerelease)
            read_release_value "GH_STUB_RELEASE_PRERELEASE_FILE" "GH_STUB_RELEASE_PRERELEASE_DIR" "${tag}" ".txt" "false"
            ;;
          .publishedAt)
            read_release_value "GH_STUB_RELEASE_PUBLISHED_AT_FILE" "GH_STUB_RELEASE_PUBLISHED_AT_DIR" "${tag}" ".txt" "2026-01-01T00:00:00Z"
            ;;
          .url)
            read_release_value "GH_STUB_RELEASE_URL_FILE" "GH_STUB_RELEASE_URL_DIR" "${tag}" ".txt" "$(canonical_release_url "${tag}")"
            ;;
          .databaseId)
            read_release_value "GH_STUB_RELEASE_DATABASE_ID_FILE" "GH_STUB_RELEASE_DATABASE_ID_DIR" "${tag}" ".txt" "123456"
            ;;
          .targetCommitish)
            read_release_value "GH_STUB_RELEASE_TARGET_FILE" "GH_STUB_RELEASE_TARGET_DIR" "${tag}" ".txt" "main"
            ;;
          *)
            printf 'gh stub: unsupported release view jq: %s\n' "${jq_expr}" >&2
            exit 1
            ;;
        esac
        ;;
      create)
        title=""
        notes_from_stdin=0
        tag=""
        asset_files=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --notes-file) notes_from_stdin=1; shift 2 ;;
            *)
              if [[ -z "${tag}" ]]; then
                tag="$1"
              else
                asset_files+=("$1")
              fi
              shift
              ;;
          esac
        done
        write_release_value "GH_STUB_RELEASE_NAME_FILE" "GH_STUB_RELEASE_NAME_DIR" "${tag}" ".txt" "${title}"
        if [[ "${notes_from_stdin}" -eq 1 ]]; then
          body_path="$(resolve_release_path "GH_STUB_RELEASE_BODY_FILE" "GH_STUB_RELEASE_BODY_DIR" "${tag}" ".txt" || true)"
          if [[ -n "${body_path}" ]]; then
            mkdir -p "$(dirname "${body_path}")"
            cat > "${body_path}"
          else
            cat >/dev/null
          fi
        fi
        write_release_value "GH_STUB_RELEASE_DRAFT_FILE" "GH_STUB_RELEASE_DRAFT_DIR" "${tag}" ".txt" "false"
        write_release_value "GH_STUB_RELEASE_PRERELEASE_FILE" "GH_STUB_RELEASE_PRERELEASE_DIR" "${tag}" ".txt" "false"
        write_release_value "GH_STUB_RELEASE_PUBLISHED_AT_FILE" "GH_STUB_RELEASE_PUBLISHED_AT_DIR" "${tag}" ".txt" "2026-01-01T00:00:00Z"
        write_release_value "GH_STUB_RELEASE_URL_FILE" "GH_STUB_RELEASE_URL_DIR" "${tag}" ".txt" "$(canonical_release_url "${tag}")"
        write_release_value "GH_STUB_RELEASE_BY_TAG_FILE" "GH_STUB_RELEASE_BY_TAG_DIR" "${tag}" ".txt" "true"
        for asset in "${asset_files[@]}"; do
          store_release_asset "${tag}" "${asset}" || true
        done
        printf 'created\n'
        ;;
      upload)
        tag="${1:-}"
        shift || true
        clobber=0
        upload_files=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --clobber) clobber=1; shift ;;
            *) upload_files+=("$1"); shift ;;
          esac
        done
        asset_dir="$(release_asset_dir "${tag}" || true)"
        if [[ -z "${asset_dir}" ]]; then
          printf 'gh stub: GH_STUB_RELEASE_ASSET_ROOT not set for release upload\n' >&2
          exit 1
        fi
        mkdir -p "${asset_dir}"
        if [[ "${clobber}" -eq 1 ]]; then
          for asset in "${upload_files[@]}"; do
            rm -f "${asset_dir}/$(basename "${asset}")"
          done
        fi
        for asset in "${upload_files[@]}"; do
          store_release_asset "${tag}" "${asset}" || {
            printf 'gh stub: failed to store asset for %s\n' "${tag}" >&2
            exit 1
          }
        done
        printf 'uploaded\n'
        ;;
      download)
        tag=""
        dest_dir="."
        patterns=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --dir) dest_dir="$2"; shift 2 ;;
            --pattern) patterns+=("$2"); shift 2 ;;
            --clobber|--skip-existing) shift ;;
            --archive=*) shift ;;
            *)
              if [[ -z "${tag}" ]]; then
                tag="$1"
                shift
              else
                shift
              fi
              ;;
          esac
        done
        [[ -n "${tag}" ]] || { printf 'gh stub: release download requires a tag\n' >&2; exit 1; }
        [[ "${#patterns[@]}" -gt 0 ]] || { printf 'gh stub: release download requires patterns in this test stub\n' >&2; exit 1; }
        if ! download_release_assets "${tag}" "${dest_dir}" "${patterns[@]}"; then
          printf 'gh stub: release assets not found for %s\n' "${tag}" >&2
          exit 1
        fi
        ;;
      edit)
        tag="${1:-}"
        shift || true
        notes_file=""
        title=""
        draft_state=""
        prerelease_state=""
        requested_tag=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --notes-file) notes_file="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            --draft=*) draft_state="${1#*=}"; shift ;;
            --prerelease=*) prerelease_state="${1#*=}"; shift ;;
            --tag) requested_tag="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        effective_tag="${requested_tag:-${tag}}"
        if [[ -n "${notes_file}" ]]; then
          body_path="$(resolve_release_path "GH_STUB_RELEASE_BODY_FILE" "GH_STUB_RELEASE_BODY_DIR" "${tag}" ".txt" || true)"
          if [[ -n "${body_path}" ]]; then
            mkdir -p "$(dirname "${body_path}")"
            cat "${notes_file}" > "${body_path}"
          else
            printf 'gh stub: GH_STUB_RELEASE_BODY_FILE or GH_STUB_RELEASE_BODY_DIR not set for release edit\n' >&2
            exit 1
          fi
        fi
        if [[ -n "${title}" ]]; then
          if ! write_release_value "GH_STUB_RELEASE_NAME_FILE" "GH_STUB_RELEASE_NAME_DIR" "${tag}" ".txt" "${title}"; then
            printf 'gh stub: GH_STUB_RELEASE_NAME_FILE or GH_STUB_RELEASE_NAME_DIR not set for release edit\n' >&2
            exit 1
          fi
        fi
        if [[ -n "${draft_state}" ]]; then
          write_release_value "GH_STUB_RELEASE_DRAFT_FILE" "GH_STUB_RELEASE_DRAFT_DIR" "${tag}" ".txt" "${draft_state}"
        fi
        if [[ -n "${prerelease_state}" ]]; then
          write_release_value "GH_STUB_RELEASE_PRERELEASE_FILE" "GH_STUB_RELEASE_PRERELEASE_DIR" "${tag}" ".txt" "${prerelease_state}"
        fi
        if [[ -n "${requested_tag}" || "${draft_state}" == "false" ]]; then
          write_release_value "GH_STUB_RELEASE_URL_FILE" "GH_STUB_RELEASE_URL_DIR" "${tag}" ".txt" "$(canonical_release_url "${effective_tag}")"
          write_release_value "GH_STUB_RELEASE_PUBLISHED_AT_FILE" "GH_STUB_RELEASE_PUBLISHED_AT_DIR" "${tag}" ".txt" "2026-01-01T00:00:00Z"
          write_release_value "GH_STUB_RELEASE_BY_TAG_FILE" "GH_STUB_RELEASE_BY_TAG_DIR" "${tag}" ".txt" "true"
        fi
        printf 'edited\n'
        ;;
      *)
        printf 'gh stub: unsupported release subcommand: %s\n' "${sub}" >&2
        exit 1
        ;;
    esac
    ;;
  run)
    sub="${1:-}"
    shift || true
    case "${sub}" in
      list)
        workflow=""
        commit=""
        jq_expr=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo|-R) shift 2 ;;
            --workflow|-w) workflow="$2"; shift 2 ;;
            --commit|-c) commit="$2"; shift 2 ;;
            --limit|-L|--json) shift 2 ;;
            --jq|-q) jq_expr="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        id="$(find_run_id_for_commit "${workflow}" "${commit}" || true)"
        if [[ "${jq_expr}" == ".[0].databaseId" ]]; then
          [[ -n "${id}" ]] && printf '%s\n' "${id}"
        elif [[ -n "${id}" ]]; then
          find_run_record_by_id "${id}" | awk -F '\t' '{printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, $6}'
        fi
        ;;
      watch)
        run_id=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo|-R|--interval|-i) shift 2 ;;
            --exit-status|--compact) shift ;;
            *)
              if [[ -z "${run_id}" ]]; then
                run_id="$1"
              fi
              shift
              ;;
          esac
        done
        [[ -n "${run_id}" ]] || { printf 'gh stub: run watch requires a run id\n' >&2; exit 1; }
        record="$(find_run_record_by_id "${run_id}" || true)"
        [[ -n "${record}" ]] || { printf 'gh stub: run %s not found\n' "${run_id}" >&2; exit 1; }
        tag="$(printf '%s' "${record}" | awk -F '\t' '{print $4}')"
        conclusion="$(printf '%s' "${record}" | awk -F '\t' '{print $6}')"
        if [[ "${conclusion}" == "success" || -z "${conclusion}" ]]; then
          append_attested_tag "${tag}"
          printf 'run %s succeeded\n' "${run_id}"
        else
          printf 'run %s failed\n' "${run_id}" >&2
          exit 1
        fi
        ;;
      *)
        printf 'gh stub: unsupported run subcommand: %s\n' "${sub}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'gh stub: unsupported command: %s\n' "${cmd}" >&2
    exit 1
    ;;
esac
GH
  chmod +x "${bindir}/gh"
  printf '%s' "${bindir}"
}

cleanup_gh_stub() {
  local bindir="$1"
  [[ -n "${bindir}" && -d "${bindir}" && "${bindir}" == */gh-stub-* ]] && rm -rf "${bindir}"
}

# ---------------------------------------------------------------------
printf 'Test 1: missing version arg → fails with usage\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh 2>&1)"
rc=$?
set -e
assert_eq "T1: missing arg exits non-zero" "1" "${rc}"
assert_contains "T1: prints usage hint" "missing version argument" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 2: invalid semver → fails\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "v1.2.3" 2>&1)"
rc=$?
set -e
assert_eq "T2: leading-v rejected" "1" "${rc}"
assert_contains "T2: names semver requirement" "X.Y.Z" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 3: dirty working tree → fails\n'
repo="$(mk_release_fixture)"
echo "dirt" > "${repo}/dirty-file"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T3: dirty tree rejected" "1" "${rc}"
assert_contains "T3: names dirty-tree blocker" "working tree is not clean" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 4: not on main → fails\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git checkout -q -b feature)
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T4: non-main rejected" "1" "${rc}"
assert_contains "T4: names branch" "must be on main" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 5: version not above current → fails\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.0" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T5: same-version rejected" "1" "${rc}"
assert_contains "T5: names not-above" "not above current" "${out}"

set +e
out_lower="$(cd "${repo}" && bash tools/release.sh "0.9.0" --dry-run 2>&1)"
rc_lower=$?
set -e
assert_eq "T5: lower-version rejected" "1" "${rc_lower}"
assert_contains "T5: lower also names not-above" "not above current" "${out_lower}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 6: tag already exists → fails\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag v1.0.1)
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T6: existing tag rejected" "1" "${rc}"
assert_contains "T6: names tag conflict" "already exists" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 7: hotfix-sweep --quick marker → fails\n'
repo="$(mk_release_fixture)"
: > "${repo}/.hotfix-sweep-quick"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T7: quick-marker rejected" "1" "${rc}"
assert_contains "T7: names hotfix-sweep" "hotfix-sweep" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 8: dry-run prints all steps without executing\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --no-watch 2>&1)"
rc=$?
set -e
assert_eq "T8: dry-run exits 0 on valid path" "0" "${rc}"
assert_contains "T8: announces step 7" "Step 7" "${out}"
assert_contains "T8: announces step 9" "Step 9" "${out}"
assert_contains "T8: announces step 10-12" "Step 10-12" "${out}"
assert_contains "T8: dry-run marker present" "[dry-run]" "${out}"
# Verify VERSION not changed
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T8: VERSION unchanged in dry-run" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# T9 (v1.32.15 G1 fix): trailing whitespace on [Unreleased] heading
# detected and rejected pre-1.32.15 the perl regex silent-no-op'd.
# ---------------------------------------------------------------------
printf 'Test 9: [Unreleased] heading with trailing whitespace → fails\n'
repo="$(mk_release_fixture)"
# Replace clean [Unreleased] with one carrying trailing spaces.
perl -i -pe 's|^## \[Unreleased\]$|## [Unreleased]   |' "${repo}/CHANGELOG.md"
(cd "${repo}" && git add -A && git commit -q -m "introduce trailing whitespace")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T9: trailing-ws heading rejected" "1" "${rc}"
assert_contains "T9: names trailing whitespace" "trailing whitespace" "${out}"
# Verify CHANGELOG was NOT mutated (the bug pre-1.32.15 was a
# silent perl no-op; we should fail BEFORE the perl substitution).
if grep -qE '^## \[1\.0\.1\]' "${repo}/CHANGELOG.md"; then
  printf '  FAIL: T9: trailing-ws case wrote a release heading anyway\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T10 (v1.32.15 G1 fix): CRLF line endings on [Unreleased] detected.
# ---------------------------------------------------------------------
printf 'Test 10: CRLF line endings on [Unreleased] → fails\n'
repo="$(mk_release_fixture)"
# Convert just the CHANGELOG to CRLF endings to simulate a Windows
# editor save.
awk 'BEGIN{ORS="\r\n"} {print}' "${repo}/CHANGELOG.md" > "${repo}/CHANGELOG.md.crlf"
mv "${repo}/CHANGELOG.md.crlf" "${repo}/CHANGELOG.md"
(cd "${repo}" && git add -A && git commit -q -m "introduce CRLF")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T10: CRLF heading rejected" "1" "${rc}"
assert_contains "T10: names CRLF" "CRLF" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T11 (v1.32.15 G2 fix): empty [Unreleased] section refuses to ship.
# ---------------------------------------------------------------------
printf 'Test 11: empty [Unreleased] section → fails\n'
repo="$(mk_release_fixture)"
# Replace the populated [Unreleased] with an empty one.
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

initial.
CL
(cd "${repo}" && git add -A && git commit -q -m "empty unreleased")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T11: empty Unreleased rejected" "1" "${rc}"
assert_contains "T11: names empty Unreleased" "[Unreleased] section is empty" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T12 (v1.33.x): --tag-on-green and --no-watch are mutually exclusive.
# tag-on-green REQUIRES the watch to know whether to tag, so combining
# them silently degrades to the eager-tag flow without warning unless
# the script rejects the combo loudly. Regression net for that.
printf 'Test 12: --tag-on-green + --no-watch → mutually exclusive\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --tag-on-green --no-watch 2>&1)"
rc=$?
set -e
assert_eq "T12: combo rejected" "2" "${rc}"
assert_contains "T12: names mutual exclusion" "mutually exclusive" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T13 (v1.33.x): legacy eager-tag dry-run announces tag-on-commit shape.
# Smoke check that the unflagged path still reaches "Step 10-12: commit
# + tag + push" and emits the [dry-run] tag command — guards against
# accidental refactor regressions in the eager-tag branch.
printf 'Test 13: eager-tag dry-run still emits tag step\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --no-watch 2>&1)"
rc=$?
set -e
assert_eq "T13: dry-run exits 0" "0" "${rc}"
assert_contains "T13: tag step present" "git tag v1.0.1" "${out}"
assert_contains "T13: tagged-and-pushed announcement" "tagged v1.0.1 and pushed" "${out}"
assert_contains "T13: dry-run announces README release pins step" "README release pins → 1.0.1" "${out}"
assert_contains "T13: dry-run release preview mentions shared helper" "render-release-notes.sh" "${out}"
assert_contains "T13: dry-run release preview mentions verified bootstrap block" "verified bootstrap block" "${out}"
assert_contains "T13: dry-run release preview mentions trusted release commit" "trusted release commit:" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T14 (v1.33.x): --tag-on-green dry-run defers the tag and the GH release
# until after CI watch. Smoke check that the new branch is wired and
# emits the deferred-tag announcement instead of "tagged v...".
printf 'Test 14: --tag-on-green dry-run defers tag until CI green\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --tag-on-green 2>&1)"
rc=$?
set -e
assert_eq "T14: dry-run exits 0" "0" "${rc}"
assert_contains "T14: announces deferred tag" "tag deferred until CI green" "${out}"
assert_contains "T14: defers GH release" "GitHub release (deferred" "${out}"
assert_contains "T14: deferred flow still references shared helper" "render-release-notes.sh" "${out}"
# In dry-run we should NOT see the eager "tagged v1.0.1 and pushed" line.
if printf '%s' "${out}" | grep -q "tagged v1.0.1 and pushed"; then
  printf '  FAIL: T14: --tag-on-green leaked into eager-tag flow (saw "tagged ... and pushed")\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T15 (v1.33.x): unknown args still reject loudly even with the new flag
# in the parser.
printf 'Test 15: unknown arg still rejected after --tag-on-green added\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --bogus-flag 2>&1)"
rc=$?
set -e
assert_eq "T15: unknown arg rejects with rc=2" "2" "${rc}"
assert_contains "T15: names the bad flag" "unknown arg" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T16 (v1.34.1): --ci-preflight and --tag-on-green are mutually
# exclusive. Both gate the tag — picking both is a config bug.
printf 'Test 16: --ci-preflight + --tag-on-green mutually exclusive (v1.34.1)\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --ci-preflight --tag-on-green 2>&1)"
rc=$?
set -e
assert_eq "T16: combo rejects with rc=2" "2" "${rc}"
assert_contains "T16: names the conflict" "mutually exclusive" "${out}"
assert_contains "T16: explains gate-overlap" "both gate the tag" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T17 (v1.34.1): --ci-preflight dry-run announces Step 6.5 and
# implies the post-flight watch is skipped (no Step 14 watch).
printf 'Test 17: --ci-preflight dry-run announces Step 6.5 and skips watch (v1.34.1)\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --ci-preflight 2>&1)"
rc=$?
set -e
assert_eq "T17: dry-run exits 0" "0" "${rc}"
assert_contains "T17: announces Step 6.5" "Step 6.5" "${out}"
assert_contains "T17: dry-runs local-ci.sh" "[dry-run] bash tools/local-ci.sh" "${out}"
assert_contains "T17: skips post-flight watch with ci-preflight wording" "ci-preflight already validated" "${out}"
# v1.34.1 reviewer fix: `Step 14: watch CI$` end-anchor can never match
# because `say` decorates output as `── Step 14: watch CI (dry-run) ───`,
# making the negative-watch half a structural no-op. Use the dry-run
# Step 14 wording (`watch CI (dry-run)`) and the live-watch wording
# (`watching run`) directly — both are unambiguous and unanchored.
if printf '%s' "${out}" | grep -q "watching run\|watch CI (dry-run)"; then
  printf '  FAIL: T17: --ci-preflight should skip the watch but watch fired\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_contains "T17: tag stays eager (no defer)" "Step 10-12: commit + tag + push" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T18 (v1.34.1): --ci-preflight parsed regardless of arg order.
printf 'Test 18: --dry-run --ci-preflight order-independent (v1.34.1)\n'
repo="$(mk_release_fixture)"
set +e
out_a="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --ci-preflight 2>&1)"
rc_a=$?
set -e
set +e
out_b="$(cd "${repo}" && bash tools/release.sh "1.0.1" --ci-preflight --dry-run 2>&1)"
rc_b=$?
set -e
assert_eq "T18: order A rc=0" "0" "${rc_a}"
assert_eq "T18: order B rc=0" "0" "${rc_b}"
assert_contains "T18: order A announces Step 6.5" "Step 6.5" "${out_a}"
assert_contains "T18: order B announces Step 6.5" "Step 6.5" "${out_b}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T19 (v1.40.x): local-sweep gate skips with notice when validate.yml
# is missing. The fixture now carries a minimal validate.yml via the
# canonical release-automation surface manifest, so this test removes
# it explicitly and asserts the skip path still behaves cleanly.
# ---------------------------------------------------------------------
printf 'Test 19: local-sweep gate skip-with-notice on missing validate.yml (v1.40.x)\n'
repo="$(mk_release_fixture)"
rm -f "${repo}/.github/workflows/validate.yml"
(cd "${repo}" && git add -A && git commit -q -m "remove fixture validate workflow")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T19: dry-run with missing validate.yml exits 0" "0" "${rc}"
assert_contains "T19: announces Step 6.7" "Step 6.7" "${out}"
assert_contains "T19: notice on missing workflow" "validate.yml not present" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T20 (v1.40.x): --skip-local-sweep bypasses the gate explicitly.
# Even with validate.yml present, the flag must cleanly skip and
# announce the skip rather than silently running the sweep.
# ---------------------------------------------------------------------
printf 'Test 20: --skip-local-sweep bypass (v1.40.x)\n'
repo="$(mk_release_fixture)"
# Plant a non-empty validate.yml so the gate WOULD run without the
# skip flag. Use a content shape that the gate's grep recognizes.
mkdir -p "${repo}/.github/workflows"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run a test
        run: bash tests/test-nonexistent.sh
YML
(cd "${repo}" && git add -A && git commit -q -m "add fixture validate.yml")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --skip-local-sweep 2>&1)"
rc=$?
set -e
assert_eq "T20: --skip-local-sweep dry-run exits 0" "0" "${rc}"
assert_contains "T20: announces gate skipped" "local-sweep gate skipped" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T21 (v1.40.x): OMC_RELEASE_SKIP_LOCAL_SWEEP=1 bypasses the gate.
# Env-var-based skip is useful for nested CI contexts where a parent
# wrapper has already verified the bash suite.
# ---------------------------------------------------------------------
printf 'Test 21: OMC_RELEASE_SKIP_LOCAL_SWEEP env bypass (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - run: bash tests/test-nonexistent.sh
YML
(cd "${repo}" && git add -A && git commit -q -m "add fixture validate.yml")
set +e
out="$(cd "${repo}" && OMC_RELEASE_SKIP_LOCAL_SWEEP=1 bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T21: env-skip dry-run exits 0" "0" "${rc}"
assert_contains "T21: env-skip announces gate skipped" "local-sweep gate skipped" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T22 (v1.40.x): the gate ABORTS the release when a CI-pinned test
# fails. This is the load-bearing assertion — without it, a future
# refactor that turns the gate into "warn but continue" would silently
# regress and v1.40.0-class CI-red tags would ship again.
#
# Build a fixture that:
#   1) Has a validate.yml pinning a failing test
#   2) Has the failing test on disk (so the gate runs it, vs. the
#      "file not present" sub-failure path)
#   3) Drives a NON-dry-run invocation (dry-run bypasses the gate
#      body, so testing the abort requires a real run)
# ---------------------------------------------------------------------
printf 'Test 22: local-sweep gate aborts on test failure (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows" "${repo}/tests"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run failing test
        run: bash tests/test-deliberate-fail.sh
YML
cat > "${repo}/tests/test-deliberate-fail.sh" <<'TEST'
#!/usr/bin/env bash
printf 'this test deliberately fails for T22 coverage\n' >&2
exit 1
TEST
chmod +x "${repo}/tests/test-deliberate-fail.sh"
(cd "${repo}" && git add -A && git commit -q -m "add failing fixture test")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T22: gate-failure exits non-zero" "1" "${rc}"
assert_contains "T22: names local-sweep gate failure" "local sweep gate failed" "${out}"
assert_contains "T22: lists the failing test" "test-deliberate-fail.sh" "${out}"
# Verify the gate aborted BEFORE Step 7 (VERSION bump). If Step 7 ran,
# the failing test fixture would have been promoted to a release.
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T22: VERSION unchanged after gate-failure" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T23 (v1.40.x follow-up to c7714d8 + fbf957e): lint sub-stage aborts
# on bash -n syntax error in bundle/. The original Step 6.7 gate only
# ran the test job's bash tests; lint regressions (shellcheck warnings,
# broken JSON, flag-coord drift, syntax errors) shipped CI-red despite
# the gate "passing" locally. T23-T25 lock the lint sub-stage in.
# ---------------------------------------------------------------------
printf 'Test 23: lint sub-stage aborts on bash -n syntax error (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows" "${repo}/bundle/dot-claude/skills/autowork/scripts"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run a passing test
        run: bash tests/test-noop.sh
YML
# A bash file in bundle/ with deliberate syntax error (unclosed quote).
cat > "${repo}/bundle/dot-claude/skills/autowork/scripts/broken.sh" <<'BAD'
#!/usr/bin/env bash
echo "unterminated string
BAD
# Provide a passing test so if the lint sub-stage were skipped, the
# test sub-stage would not error — keeps the assertion focused on lint.
cat > "${repo}/tests/test-noop.sh" <<'TEST'
#!/usr/bin/env bash
exit 0
TEST
chmod +x "${repo}/tests/test-noop.sh"
(cd "${repo}" && git add -A && git commit -q -m "add broken bundle file + noop test")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T23: gate-failure exits non-zero" "1" "${rc}"
assert_contains "T23: names lint-sweep failure" "lint-sweep failed" "${out}"
assert_contains "T23: names bash -n category" "bash -n syntax" "${out}"
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T23: VERSION unchanged after lint-failure" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T24 (v1.40.x follow-up): lint sub-stage aborts on JSON validation
# failure. Catches the failure mode where invalid JSON in settings.json
# / config/*.json gets committed and only surfaces on CI's
# `python3 -m json.tool` step.
# ---------------------------------------------------------------------
printf 'Test 24: lint sub-stage aborts on JSON validation failure (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Noop
        run: bash tests/test-noop.sh
YML
cat > "${repo}/broken-config.json" <<'BAD'
{ "foo": "bar"   <-- missing closing brace and quote
BAD
cat > "${repo}/tests/test-noop.sh" <<'TEST'
#!/usr/bin/env bash
exit 0
TEST
chmod +x "${repo}/tests/test-noop.sh"
(cd "${repo}" && git add -A && git commit -q -m "add broken JSON + noop test")
# Skip the test if python3 isn't on PATH — the lint stage would skip
# JSON validation in that case, so T24 has nothing to assert.
if command -v python3 >/dev/null 2>&1; then
  set +e
  out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
  rc=$?
  set -e
  assert_eq "T24: gate-failure exits non-zero" "1" "${rc}"
  assert_contains "T24: names lint-sweep failure" "lint-sweep failed" "${out}"
  assert_contains "T24: names JSON category" "JSON validation" "${out}"
  ver_after="$(cat "${repo}/VERSION")"
  assert_eq "T24: VERSION unchanged after JSON-failure" "1.0.0" "${ver_after}"
else
  printf '  SKIP T24: python3 not in PATH\n'
fi
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T25 (v1.40.x follow-up): lint sub-stage aborts on flag-coordination
# drift. tools/check-flag-coordination.sh exits non-zero when the
# 3-site SoT trio (parser/example/omc-config) is out of sync. Fixture
# provides a stub that exits 1 so the gate exercises the failure path
# without recreating the entire SoT trio.
# ---------------------------------------------------------------------
printf 'Test 25: lint sub-stage aborts on flag-coord failure (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows" "${repo}/tools"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Noop
        run: bash tests/test-noop.sh
YML
cat > "${repo}/tools/check-flag-coordination.sh" <<'STUB'
#!/usr/bin/env bash
printf 'flag drift detected: example flag missing from parser\n' >&2
exit 1
STUB
chmod +x "${repo}/tools/check-flag-coordination.sh"
cat > "${repo}/tests/test-noop.sh" <<'TEST'
#!/usr/bin/env bash
exit 0
TEST
chmod +x "${repo}/tests/test-noop.sh"
(cd "${repo}" && git add -A && git commit -q -m "add failing flag-coord stub + noop test")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T25: gate-failure exits non-zero" "1" "${rc}"
assert_contains "T25: names lint-sweep failure" "lint-sweep failed" "${out}"
assert_contains "T25: names flag-coord category" "flag-coord" "${out}"
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T25: VERSION unchanged after flag-coord-failure" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T26: local-sweep extractor must honor env-prefixed validate.yml
# invocations (`OMC_X=y bash tests/test-foo.sh`), not just bare
# `bash tests/test-foo.sh`. Pre-fix the grep shape skipped these
# lines entirely, so the gate could report green while missing a
# CI-pinned test.
# ---------------------------------------------------------------------
printf 'Test 26: local-sweep extractor honors env-prefixed test invocations\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows" "${repo}/tests"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run env-prefixed failing test
        run: OMC_FIXTURE=1 bash tests/test-env-prefixed-fail.sh
YML
cat > "${repo}/tests/test-env-prefixed-fail.sh" <<'TEST'
#!/usr/bin/env bash
printf 'env-prefixed test executed\n' >&2
exit 1
TEST
chmod +x "${repo}/tests/test-env-prefixed-fail.sh"
(cd "${repo}" && git add -A && git commit -q -m "add env-prefixed failing fixture test")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T26: env-prefixed gate-failure exits non-zero" "1" "${rc}"
assert_contains "T26: names local-sweep gate failure" "local sweep gate failed" "${out}"
assert_contains "T26: names env-prefixed failing test" "test-env-prefixed-fail.sh" "${out}"
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T26: VERSION unchanged after env-prefixed gate-failure" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T27: jq is not a real runtime dependency. `gh --jq` uses GitHub
# CLI's embedded jq evaluator, and release.sh never invokes the jq
# binary directly. Pre-fix the unconditional `command -v jq` check
# blocked otherwise-valid dry-runs on hosts without jq installed.
# ---------------------------------------------------------------------
printf 'Test 27: release dry-run succeeds without jq on PATH\n'
repo="$(mk_release_fixture)"
path_without_jq="$(mk_path_without_jq)"
if [[ -n "${path_without_jq:-}" ]]; then
  set +e
  out="$(cd "${repo}" && PATH="${path_without_jq}" "${BASH}" tools/release.sh "1.0.1" --dry-run --no-watch 2>&1)"
  rc=$?
  set -e
  assert_eq "T27: no-jq dry-run exits 0" "0" "${rc}"
  assert_contains "T27: no-jq dry-run reaches release steps" "Step 7" "${out}"
else
  printf '  SKIP T27: could not construct minimal PATH fixture\n'
fi
cleanup_fixture "${repo}"
cleanup_path_fixture "${path_without_jq:-}"

# ---------------------------------------------------------------------
# T28: extractor must capture MULTIPLE test paths from one validate.yml
# run line. Pre-fix the token scan stopped after the first match, so a
# compound line like `bash tests/test-a.sh && bash tests/test-b.sh`
# silently skipped the second test.
# ---------------------------------------------------------------------
printf 'Test 28: local-sweep extractor captures multiple tests on one run line\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows" "${repo}/tests"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run two tests on one line
        run: OMC_FIXTURE=1 bash tests/test-first-pass.sh && bash tests/test-second-fail.sh
YML
cat > "${repo}/tests/test-first-pass.sh" <<'TEST'
#!/usr/bin/env bash
exit 0
TEST
cat > "${repo}/tests/test-second-fail.sh" <<'TEST'
#!/usr/bin/env bash
printf 'second test executed\n' >&2
exit 1
TEST
chmod +x "${repo}/tests/test-first-pass.sh" "${repo}/tests/test-second-fail.sh"
(cd "${repo}" && git add -A && git commit -q -m "add compound-line fixture tests")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T28: compound-line gate-failure exits non-zero" "1" "${rc}"
assert_contains "T28: names local-sweep gate failure" "local sweep gate failed" "${out}"
assert_contains "T28: names second failing test" "test-second-fail.sh" "${out}"
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T28: VERSION unchanged after compound-line gate-failure" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T29: render-release-notes helper is the single source of truth for the
# public release body. It must render the verified bootstrap block, the
# trusted release commit, and the matching CHANGELOG section together.
# ---------------------------------------------------------------------
printf 'Test 29: render-release-notes helper emits canonical release body\n'
repo="$(mk_release_fixture)"
helper_sha="1234567890abcdef1234567890abcdef12345678"
set +e
out="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${helper_sha}" 2>&1)"
rc=$?
set -e
assert_eq "T29: helper exits 0" "0" "${rc}"
assert_contains "T29: helper prints verified bootstrap header" "Verified bootstrap install:" "${out}"
assert_contains "T29: helper prints pinned version" "OMC_REF=v1.0.0" "${out}"
assert_contains "T29: helper prints trusted SHA" "OMC_EXPECTED_SHA=${helper_sha}" "${out}"
assert_contains "T29: helper prints trusted release commit block" "Trusted release commit:" "${out}"
assert_contains "T29: helper includes changelog notes" "initial." "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 30: real no-gh release updates README pins and pushes tag\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main)
path_without_jq="$(mk_path_without_jq)"
if [[ -n "${path_without_jq:-}" ]]; then
  set +e
  out="$(cd "${repo}" && PATH="${path_without_jq}" "${BASH}" tools/release.sh "1.0.1" --no-watch 2>&1)"
  rc=$?
  set -e
  assert_eq "T30: real release exits 0" "0" "${rc}"
  assert_contains "T30: announces README release pin update" "README release pins → 1.0.1" "${out}"
  assert_contains "T30: warns gh missing but continues" "gh CLI not found — skipping release create" "${out}"
  assert_contains "T30: gh-missing path offers web UI fallback" "Use GitHub web UI now:" "${out}"
  assert_contains "T30: gh-missing path prints helper with explicit SHA" "paste the output of: bash tools/render-release-notes.sh 1.0.1 --sha" "${out}"
  ver_after="$(tr -d '[:space:]' < "${repo}/VERSION")"
  readme_after="$(cat "${repo}/README.md")"
  pin_count="$(grep -o "OMC_REF=v1.0.1" "${repo}/README.md" | wc -l | tr -d ' ')"
  assert_eq "T30: VERSION bumped" "1.0.1" "${ver_after}"
  assert_contains "T30: README badge bumped" "Version-1.0.1-blue" "${readme_after}"
  assert_eq "T30: both OMC_REF pins bumped" "2" "${pin_count}"
  assert_contains "T30: README manual clone pin bumped" "--branch v1.0.1 https://github.com/X0x888/oh-my-claude.git" "${readme_after}"
  assert_git_ref_exists "T30: local tag created" "${repo}" "refs/tags/v1.0.1"
  assert_git_dir_ref_exists "T30: remote tag pushed" "${origin_repo}" "refs/tags/v1.0.1"
else
  printf '  SKIP T30: could not construct minimal PATH fixture\n'
fi
cleanup_path_fixture "${path_without_jq:-}"
rm -rf "${origin_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 31: manual release docs and recovery stay locked to helper + SHA\n'
tool_contents="$(cat "${TOOL_REAL}")"
contributing_contents="$(cat "${CONTRIBUTING_REAL}")"
agents_contents="$(cat "${AGENTS_REAL}")"
attest_workflow_contents="$(cat "${ATTEST_WORKFLOW_REAL}")"
readme_contents="$(cat "${REPO_ROOT}/README.md")"
# Keep the executable-bit and contributor-inventory contract anchored to
# the canonical release-automation surface manifest rather than a stale
# hand-maintained subset inside this test.
while IFS= read -r relpath; do
  [[ "${relpath}" == tools/* ]] || continue
  tool_name="$(basename "${relpath}")"
  if [[ -x "${REPO_ROOT}/${relpath}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T31: %s must be executable in the repo\n' "${tool_name}" >&2
    fail=$((fail + 1))
  fi
  assert_contains "T31: AGENTS inventory includes ${tool_name}" "${tool_name}" "${agents_contents}"
done < <(bash "${RELEASE_AUTOMATION_SURFACE_LIST_HELPER_REAL}")

assert_contains "T31: CONTRIBUTING records tagged SHA before rendering release notes" 'SHA=$(git rev-parse "v$VER^{commit}")' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING computes release title from helper" 'TITLE=$(bash tools/render-release-title.sh "$VER")' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING builds release assets from helper" 'bash tools/build-release-assets.sh "$VER" --out-dir "$ASSET_DIR"' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING release command uses helper with explicit SHA" 'bash tools/render-release-notes.sh "$VER" --sha "$SHA" \' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING release command uploads tarball asset" '"$ASSET_DIR/oh-my-claude-v$VER.tar.gz" \' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING release command uploads checksum asset" '"$ASSET_DIR/oh-my-claude-v$VER.SHA256SUMS" \' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING release command starts gh release create" 'gh release create "v$VER" \' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING release command uses helper title" '--title "$TITLE" --notes-file -' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING web UI fallback uses title helper" 'set the title to `bash tools/render-release-title.sh "$VER"`' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING web UI fallback uploads attached source bundles" 'upload `oh-my-claude-v$VER.tar.gz`, `oh-my-claude-v$VER.zip`, and `oh-my-claude-v$VER.SHA256SUMS`' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING web UI fallback uses helper with explicit SHA" 'paste the output of `bash tools/render-release-notes.sh "$VER" --sha "$SHA"`' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING proves published release with the unified verifier" 'bash tools/verify-published-release.sh "$VER" --sha "$SHA" --attestations wait --trigger-attestations-if-missing' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents synchronous-only verifier mode" 'bash tools/verify-published-release.sh "$VER" --sha "$SHA" --attestations skip' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents top-level distribution readiness tool" 'bash tools/verify-distribution-readiness.sh --release-sha "$SHA"' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING explains distribution readiness composition" 'That top-level readiness check composes `verify-release-automation-deployment.sh`, `prepare-release-automation-deployment.sh`, `verify-published-release.sh`, and `audit-published-releases.sh`.' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING explains local-candidate vs remote-deployment distinction" 'surfaces the local deployment-candidate proof separately from the remote deployment proof' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents machine-readable distribution readiness mode" 'Add `--json` when you want the same audit as a machine-readable artifact for CI, dashboards, or scripted release gates.' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents install/onboarding readiness tool" 'bash tools/verify-install-readiness.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING explains install/onboarding readiness composition" 'That helper proves the bootstrapper/update path, fresh-install handoff, recovery-path transcript, and AI-assisted onboarding/install prompts as one professional-distribution contract.' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents top-level project readiness tool" 'bash tools/verify-project-readiness.sh --release-sha "$SHA"' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING explains project readiness composition" 'That wrapper composes `tools/verify-professional-readiness.sh`, `tools/verify-install-readiness.sh`, and `tools/verify-distribution-readiness.sh` into one maintainer-facing release-candidate verdict' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents widened product/install-proof scope" 'classification + routing + UI design contracts + benchmark + realwork + install/onboarding' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted attestation verifier available" 'tools/verify-published-release-attestations.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted asset verifier available" 'tools/verify-published-release-assets.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted title verifier available" 'tools/verify-published-release-title.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted body verifier available" 'tools/verify-published-release-body.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted state verifier available" 'tools/verify-published-release-state.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps attestation waiter available" 'tools/wait-for-release-attestations.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents unified historical published-release audit tool" 'bash tools/audit-published-releases.sh --limit 100' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents synchronous-only historical audit mode" 'bash tools/audit-published-releases.sh --limit 100 --attestations skip' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents release-automation deployment audit tool" 'bash tools/verify-release-automation-deployment.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents release-automation staging helper dry-run" 'bash tools/stage-release-automation-surfaces.sh --dry-run' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents release-automation staging helper live mode" 'bash tools/stage-release-automation-surfaces.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents deployment-candidate helper dry-run" 'bash tools/prepare-release-automation-deployment.sh --dry-run --fetch' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents deployment-candidate helper live mode" 'bash tools/prepare-release-automation-deployment.sh --fetch' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents fail-closed extra-staged behavior" 'The staging helper now fails closed if unrelated files are already staged' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents fail-closed partial-manifest behavior" 'When you narrow with `--path`, it also fails closed if other manifest entries are still dirty in the worktree' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents staged-index deployment verification" 'bash tools/verify-release-automation-deployment.sh --local-ref INDEX --fetch' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING explains deployment-candidate helper semantics" 'succeeds when the candidate is coherent even though the remote is still behind' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING names the canonical release-automation surface manifest" 'The audited path set comes from `tools/list-release-automation-surfaces.sh`' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING explains staging helper consumes the same manifest" 'The staging helper consumes that same manifest, which keeps the deployment audit and the staged publish set in lockstep' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents allow-extra-staged escape hatch" '`--allow-extra-staged` when extra staged paths are intentional' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents allow-partial-manifest escape hatch" '`--allow-partial-manifest` when a narrowed selection intentionally leaves other manifest entries dirty in the worktree' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents INDEX alias for staged deployment audit" 'The deployment verifier accepts `--local-ref INDEX` (alias `STAGED`)' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents fail-closed staged-index verifier behavior" 'That staged-index verifier now also fails closed if unrelated non-manifest files are already staged' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents allow-extra-staged override for staged-index verifier" 'rerun with `--allow-extra-staged` only when the wider staged commit is intentional' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents top-level readiness allow-extra-staged pass-through" 'The top-level `tools/verify-distribution-readiness.sh` wrapper passes through that same `--allow-extra-staged` escape hatch when you pair it with `--local-ref INDEX`.' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted historical release attestation auditor available" 'tools/audit-published-release-attestations.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted historical release asset auditor available" 'tools/audit-published-release-assets.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted historical release title auditor available" 'tools/audit-published-release-titles.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted historical release body auditor available" 'tools/audit-published-release-bodies.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING keeps targeted historical release state auditor available" 'tools/audit-published-release-states.sh' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING documents workflow_dispatch fallback for attestations" 'gh workflow run attest-release-assets.yml -f tag="v$VER"' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING names release regression net without brittle fixed count" 'Regression net: `tests/test-release.sh` (CI-pinned; use the live suite output if you need the current assertion count).' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING names hotfix-sweep regression net without brittle fixed count" 'Regression net: `tests/test-hotfix-sweep.sh` (CI-pinned; use the live suite output if you need the current assertion count).' "${contributing_contents}"
assert_contains "T31: CONTRIBUTING names local-ci regression net without brittle fixed count" 'Regression net: `tests/test-local-ci.sh` (CI-pinned; use the live suite output if you need the current assertion count).' "${contributing_contents}"
assert_not_contains "T31: CONTRIBUTING no longer hardcodes stale release assertion count" 'tests/test-release.sh` (53 assertions, CI-pinned)' "${contributing_contents}"
assert_not_contains "T31: CONTRIBUTING no longer hardcodes stale hotfix-sweep assertion count" 'tests/test-hotfix-sweep.sh` (12 assertions, CI-pinned)' "${contributing_contents}"
assert_not_contains "T31: CONTRIBUTING no longer hardcodes brittle local-ci assertion count" 'tests/test-local-ci.sh` (14 assertions, CI-pinned)' "${contributing_contents}"
assert_contains "T31: README names release-automation deployment verifier helper" 'tools/verify-release-automation-deployment.sh' "${readme_contents}"
assert_contains "T31: README names release-automation staging helper" 'tools/stage-release-automation-surfaces.sh' "${readme_contents}"
assert_contains "T31: README names deployment-candidate helper" 'tools/prepare-release-automation-deployment.sh' "${readme_contents}"
assert_contains "T31: README names staged-index deployment verification" 'tools/verify-release-automation-deployment.sh --local-ref INDEX' "${readme_contents}"
assert_contains "T31: README documents fail-closed extra-staged behavior" 'fails closed when unrelated files are already staged' "${readme_contents}"
assert_contains "T31: README documents allow-extra-staged escape hatch" '--allow-extra-staged' "${readme_contents}"
assert_contains "T31: README documents fail-closed partial-manifest behavior" 'when you narrow it with `--path`, it also fails closed if other manifest entries are still dirty unless you explicitly pass `--allow-partial-manifest`' "${readme_contents}"
assert_contains "T31: README explains deployment-candidate helper semantics" 'succeeds when that pending staged candidate is coherent even though the remote is still behind' "${readme_contents}"
assert_contains "T31: README documents fail-closed staged-index verifier behavior" 'The staged-index deployment verifier now applies the same fail-closed posture to unrelated non-manifest staged paths' "${readme_contents}"
assert_contains "T31: README documents top-level readiness allow-extra-staged pass-through" 'tools/verify-distribution-readiness.sh` passes that same override through when you audit the staged index via `--local-ref INDEX`' "${readme_contents}"
assert_contains "T31: README names top-level distribution readiness helper" 'tools/verify-distribution-readiness.sh' "${readme_contents}"
assert_contains "T31: README explains local-candidate vs remote-deployment distinction" 'separates the live remote deployment proof from the local deployment-candidate proof' "${readme_contents}"
assert_contains "T31: README names top-level install readiness helper" 'tools/verify-install-readiness.sh' "${readme_contents}"
assert_contains "T31: README names top-level project readiness helper" 'tools/verify-project-readiness.sh' "${readme_contents}"
assert_contains "T31: README names top-level professional readiness helper" 'tools/verify-professional-readiness.sh' "${readme_contents}"
assert_contains "T31: README documents widened project-readiness wrapper scope" 'classification + routing + UI design contracts + benchmark + realwork + install/onboarding' "${readme_contents}"
assert_contains "T31: release.sh requires release asset helper" 'release asset helper missing' "${tool_contents}"
assert_contains "T31: release.sh requires published release auditor" 'published release auditor missing' "${tool_contents}"
assert_contains "T31: release.sh requires release title helper" 'release title helper missing' "${tool_contents}"
assert_contains "T31: deployment verifier remediation names candidate helper" 'prepare the deployment candidate safely with bash tools/prepare-release-automation-deployment.sh --dry-run --fetch && bash tools/prepare-release-automation-deployment.sh --fetch' "${REPO_ROOT:+$(cat "${REPO_ROOT}/tools/verify-release-automation-deployment.sh")}"
assert_contains "T31: release.sh gh-missing fallback names asset helper" 'ASSET_DIR="$(mktemp -d -t omc-release-assets-XXXXXX)"' "${tool_contents}"
assert_contains "T31: release.sh gh-missing fallback names title helper" 'TITLE="$(bash tools/render-release-title.sh %s)"' "${tool_contents}"
assert_contains "T31: release.sh gh-missing fallback names unified published-release verifier" 'then prove the full published release with: bash tools/verify-published-release.sh %s --sha %s --attestations wait --trigger-attestations-if-missing' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery uses helper with tag SHA" 'bash tools/render-release-notes.sh %s --sha "$(git rev-parse v%s^{commit})" | \' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery builds release assets" 'bash tools/build-release-assets.sh %s --out-dir "$ASSET_DIR" && \' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery uses title helper" 'TITLE="$(bash tools/render-release-title.sh %s)" && \' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery names web UI title helper" 'title: bash tools/render-release-title.sh %s' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery names web UI fallback" 'Or via GitHub web UI, paste:' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery names synchronous verifier" 'bash tools/verify-published-release.sh %s --sha "$(git rev-parse v%s^{commit})" --attestations skip' "${tool_contents}"
assert_contains "T31: release.sh CI-red recovery names full verifier" 'then prove it with: bash tools/verify-published-release.sh %s --sha "$(git rev-parse v%s^{commit})" --attestations wait --trigger-attestations-if-missing' "${tool_contents}"
assert_contains "T31: release.sh dry-run previews release asset build helper" '[dry-run] bash tools/build-release-assets.sh %s --out-dir "$ASSET_DIR"' "${tool_contents}"
assert_contains "T31: release.sh dry-run previews synchronous published-release verification" '[dry-run] bash tools/verify-published-release.sh %s --sha %s --attestations skip' "${tool_contents}"
assert_contains "T31: release.sh dry-run previews attestation wait+verification" '[dry-run] bash tools/verify-published-release.sh %s --sha %s --attestations wait --trigger-attestations-if-missing' "${tool_contents}"
assert_contains "T31: attestation workflow has release trigger" 'types: [published]' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow has workflow_dispatch trigger" 'workflow_dispatch:' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow requests id-token write" 'id-token: write' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow requests attestations write" 'attestations: write' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow downloads release assets" 'gh release download' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow compares published assets against rebuild" 'cmp -s' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow uses actions/attest" 'uses: actions/attest@v4' "${attest_workflow_contents}"
assert_contains "T31: attestation workflow attests all three release assets" 'dist/published/${{ steps.tag.outputs.asset_stem }}.SHA256SUMS' "${attest_workflow_contents}"

# ---------------------------------------------------------------------
printf 'Test 32: published-release verifier detects drift and prints remediation\n'
repo="$(mk_release_fixture)"
gh_stub_dir="$(mk_gh_stub)"
release_body_file="${repo}/published-release-body.txt"
printf 'Release v1.0.0' > "${release_body_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-body.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T32: drift exits non-zero" "1" "${rc}"
assert_contains "T32: drift names mismatch" "published release body mismatch" "${out}"
assert_contains "T32: drift prints diff header" "diff (expected vs actual):" "${out}"
assert_contains "T32: drift prints gh remediation" "gh release edit v1.0.0 --repo example/fixture --notes-file /tmp/oh-my-claude-release-notes.md" "${out}"
assert_contains "T32: drift prints web UI remediation" 'Or GitHub web UI: paste the output of `bash tools/render-release-notes.sh 1.0.0 --sha' "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 33: published-release verifier --fix repairs drift\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_body_file="${repo}/published-release-body.txt"
printf 'Release v1.0.0' > "${release_body_file}"
expected_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
expected_body="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${expected_sha}")"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-body.sh "1.0.0" --repo "example/fixture" --fix 2>&1)"
rc=$?
set -e
actual_body="$(cat "${release_body_file}")"
assert_eq "T33: --fix exits 0" "0" "${rc}"
assert_contains "T33: --fix reports repair" "published release body repaired and verified" "${out}"
assert_eq "T33: --fix writes canonical body" "${expected_body}" "${actual_body}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 34: published-release verifier resolves remote tag commit without local tag\n'
repo="$(mk_release_fixture)"
gh_stub_dir="$(mk_gh_stub)"
remote_sha="3333333333333333333333333333333333333333"
release_body_file="${repo}/published-release-body.txt"
expected_body="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${remote_sha}")"
printf '%s' "${expected_body}" > "${release_body_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" GH_STUB_TAG_OBJECT_TYPE="commit" GH_STUB_TAG_OBJECT_SHA="${remote_sha}" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-body.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T34: remote-tag verification exits 0" "0" "${rc}"
assert_contains "T34: remote-tag verification reports success" "published release body matches canonical helper" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 35: real release with gh uploads canonical assets and verifies all release surfaces\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main)
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_body_file="${repo}/published-release-body.txt"
release_name_file="${repo}/published-release-name.txt"
release_draft_file="${repo}/published-release-draft.txt"
release_prerelease_file="${repo}/published-release-prerelease.txt"
release_published_at_file="${repo}/published-release-published-at.txt"
release_url_file="${repo}/published-release-url.txt"
release_by_tag_file="${repo}/published-release-by-tag.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_DRAFT_FILE="${release_draft_file}" GH_STUB_RELEASE_PRERELEASE_FILE="${release_prerelease_file}" GH_STUB_RELEASE_PUBLISHED_AT_FILE="${release_published_at_file}" GH_STUB_RELEASE_URL_FILE="${release_url_file}" GH_STUB_RELEASE_BY_TAG_FILE="${release_by_tag_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/release.sh "1.0.1" --no-watch 2>&1)"
rc=$?
set -e
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.1")"
actual_title="$(cat "${release_name_file}")"
actual_release_draft="$(cat "${release_draft_file}")"
actual_release_prerelease="$(cat "${release_prerelease_file}")"
actual_release_url="$(cat "${release_url_file}")"
actual_release_by_tag="$(cat "${release_by_tag_file}")"
assert_true "T35: gh-backed release uploads tarball asset" "[[ -f '${release_asset_root}/v1.0.1/oh-my-claude-v1.0.1.tar.gz' ]]"
assert_true "T35: gh-backed release uploads zip asset" "[[ -f '${release_asset_root}/v1.0.1/oh-my-claude-v1.0.1.zip' ]]"
assert_true "T35: gh-backed release uploads checksum asset" "[[ -f '${release_asset_root}/v1.0.1/oh-my-claude-v1.0.1.SHA256SUMS' ]]"
assert_eq "T35: gh-backed release exits 0" "0" "${rc}"
assert_eq "T35: gh-backed release writes canonical title" "${expected_title}" "${actual_title}"
assert_eq "T35: gh-backed release clears draft state" "false" "${actual_release_draft}"
assert_eq "T35: gh-backed release clears prerelease state" "false" "${actual_release_prerelease}"
assert_eq "T35: gh-backed release writes canonical release URL" "https://github.com/example/fixture/releases/tag/v1.0.1" "${actual_release_url}"
assert_eq "T35: gh-backed release keeps REST tag route resolvable" "true" "${actual_release_by_tag}"
assert_contains "T35: release path invokes published-asset verifier" "published release assets are canonical" "${out}"
assert_contains "T35: release path invokes published-title verifier" "published release title matches canonical helper" "${out}"
assert_contains "T35: release path invokes published-body verifier" "published release body matches canonical helper" "${out}"
assert_contains "T35: release path invokes published-state verifier" "published release state is canonical" "${out}"
assert_contains "T35: release path still announces GitHub release created" "GitHub release created" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
rm -rf "${origin_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 36: batch auditor reports mixed historical release state\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

second.

## [1.0.0] - 2026-01-01

initial.
CL
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION CHANGELOG.md && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_body_dir="${repo}/release-bodies"
mkdir -p "${release_body_dir}"
release_list_file="${repo}/release-tags.txt"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
body_v101="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.1" --sha "$(git -C "${repo}" rev-parse "v1.0.1^{commit}")")"
printf '%s' "${body_v101}" > "${release_body_dir}/v1.0.1.txt"
printf 'Release v1.0.0' > "${release_body_dir}/v1.0.0.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_BODY_DIR="${release_body_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-bodies.sh --repo example/fixture 2>&1)"
rc=$?
set -e
assert_eq "T36: mixed audit exits non-zero" "1" "${rc}"
assert_contains "T36: mixed audit reports ok tag" $'OK\tv1.0.1\tverify-published-release-body: published release body matches canonical helper' "${out}"
assert_contains "T36: mixed audit reports drift tag" $'DRIFT\tv1.0.0\tverify-published-release-body: published release body mismatch' "${out}"
assert_contains "T36: mixed audit prints summary" "summary: 1 OK, 0 FIXED, 1 FAIL" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 37: batch auditor --fix repairs historical release drift\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

second.

## [1.0.0] - 2026-01-01

initial.
CL
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION CHANGELOG.md && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_body_dir="${repo}/release-bodies"
mkdir -p "${release_body_dir}"
release_list_file="${repo}/release-tags.txt"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
body_v100="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "$(git -C "${repo}" rev-parse "v1.0.0^{commit}")")"
body_v101="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.1" --sha "$(git -C "${repo}" rev-parse "v1.0.1^{commit}")")"
printf '%s' "${body_v101}" > "${release_body_dir}/v1.0.1.txt"
printf 'Release v1.0.0' > "${release_body_dir}/v1.0.0.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_BODY_DIR="${release_body_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-bodies.sh --repo example/fixture --fix 2>&1)"
rc=$?
set -e
fixed_v100="$(cat "${release_body_dir}/v1.0.0.txt")"
fixed_v101="$(cat "${release_body_dir}/v1.0.1.txt")"
assert_eq "T37: batch fix exits 0" "0" "${rc}"
assert_contains "T37: batch fix reports fixed tag" $'FIXED\tv1.0.0\tverify-published-release-body: published release body repaired and verified' "${out}"
assert_contains "T37: batch fix reports ok tag" $'OK\tv1.0.1\tverify-published-release-body: published release body matches canonical helper' "${out}"
assert_contains "T37: batch fix prints summary" "summary: 1 OK, 1 FIXED, 0 FAIL" "${out}"
assert_eq "T37: batch fix rewrites drifting release" "${body_v100}" "${fixed_v100}"
assert_eq "T37: batch fix leaves clean release canonical" "${body_v101}" "${fixed_v101}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 38: render-release-title helper normalizes headings and file-path bullets\n'
repo="$(mk_release_fixture)"
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

### Added

- **docs/ulw-version-assessment.md** — comprehensive ULW version-line audit from v0.9.0 through v1.0.0, with historical comparison and design-debt follow-up.

## [1.0.0] - 2026-01-01

### v1.0.0 candidate set — 12 of 19 review items shipped

initial.
CL
title_v100="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
title_v101="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.1")"
assert_eq "T38: candidate-set heading trimmed" "v1.0.0 — 12 of 19 review items shipped" "${title_v100}"
assert_eq "T38: generic heading skips to human summary" "v1.0.1 — Comprehensive ULW version-line audit from v0.9.0 through v1.0.0" "${title_v101}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 39: published-release title verifier detects drift and prints remediation\n'
repo="$(mk_release_fixture)"
gh_stub_dir="$(mk_gh_stub)"
release_name_file="${repo}/published-release-name.txt"
printf 'Release v1.0.0' > "${release_name_file}"
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-title.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T39: title drift exits non-zero" "1" "${rc}"
assert_contains "T39: title drift names mismatch" "published release title mismatch" "${out}"
assert_contains "T39: title drift prints expected title" "expected title: ${expected_title}" "${out}"
assert_contains "T39: title drift prints gh remediation" "gh release edit v1.0.0 --repo example/fixture --title" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 40: published-release title verifier --fix repairs drift\n'
repo="$(mk_release_fixture)"
gh_stub_dir="$(mk_gh_stub)"
release_name_file="${repo}/published-release-name.txt"
printf 'Release v1.0.0' > "${release_name_file}"
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-title.sh "1.0.0" --repo "example/fixture" --fix 2>&1)"
rc=$?
set -e
actual_title="$(cat "${release_name_file}")"
assert_eq "T40: title --fix exits 0" "0" "${rc}"
assert_contains "T40: title --fix reports repair" "published release title repaired and verified" "${out}"
assert_eq "T40: title --fix writes canonical title" "${expected_title}" "${actual_title}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 41: batch title auditor reports and repairs historical drift\n'
repo="$(mk_release_fixture)"
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

### Added

- **docs/ulw-version-assessment.md** — comprehensive ULW version-line audit from v0.9.0 through v1.0.0, with historical comparison and design-debt follow-up.

## [1.0.0] - 2026-01-01

### v1.0.0 candidate set — 12 of 19 review items shipped

initial.
CL
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION CHANGELOG.md && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_name_dir="${repo}/release-names"
mkdir -p "${release_name_dir}"
release_list_file="${repo}/release-tags.txt"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
expected_title_v100="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
expected_title_v101="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.1")"
printf '%s' "${expected_title_v101}" > "${release_name_dir}/v1.0.1.txt"
printf 'Release v1.0.0' > "${release_name_dir}/v1.0.0.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_NAME_DIR="${release_name_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-titles.sh --repo example/fixture 2>&1)"
rc=$?
set -e
assert_eq "T41: mixed title audit exits non-zero" "1" "${rc}"
assert_contains "T41: mixed title audit reports ok tag" $'OK\tv1.0.1\tverify-published-release-title: published release title matches canonical helper' "${out}"
assert_contains "T41: mixed title audit reports drift tag" $'DRIFT\tv1.0.0\tverify-published-release-title: published release title mismatch' "${out}"
assert_contains "T41: mixed title audit prints summary" "summary: 1 OK, 0 FIXED, 1 FAIL" "${out}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_NAME_DIR="${release_name_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-titles.sh --repo example/fixture --fix 2>&1)"
rc=$?
set -e
fixed_title_v100="$(cat "${release_name_dir}/v1.0.0.txt")"
fixed_title_v101="$(cat "${release_name_dir}/v1.0.1.txt")"
assert_eq "T41: title batch fix exits 0" "0" "${rc}"
assert_contains "T41: title batch fix reports fixed tag" $'FIXED\tv1.0.0\tverify-published-release-title: published release title repaired and verified' "${out}"
assert_contains "T41: title batch fix reports ok tag" $'OK\tv1.0.1\tverify-published-release-title: published release title matches canonical helper' "${out}"
assert_contains "T41: title batch fix prints summary" "summary: 1 OK, 1 FIXED, 0 FAIL" "${out}"
assert_eq "T41: title batch fix rewrites drifting title" "${expected_title_v100}" "${fixed_title_v100}"
assert_eq "T41: title batch fix leaves clean title canonical" "${expected_title_v101}" "${fixed_title_v101}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 42: published-release state verifier detects draft/untagged drift\n'
repo="$(mk_release_fixture)"
gh_stub_dir="$(mk_gh_stub)"
release_draft_file="${repo}/published-release-draft.txt"
release_prerelease_file="${repo}/published-release-prerelease.txt"
release_published_at_file="${repo}/published-release-published-at.txt"
release_url_file="${repo}/published-release-url.txt"
release_by_tag_file="${repo}/published-release-by-tag.txt"
printf 'true' > "${release_draft_file}"
printf 'false' > "${release_prerelease_file}"
printf '2026-05-01T00:08:37Z' > "${release_published_at_file}"
printf 'https://github.com/example/fixture/releases/tag/untagged-2662d91ad3ad034f32f6' > "${release_url_file}"
printf 'false' > "${release_by_tag_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_DRAFT_FILE="${release_draft_file}" GH_STUB_RELEASE_PRERELEASE_FILE="${release_prerelease_file}" GH_STUB_RELEASE_PUBLISHED_AT_FILE="${release_published_at_file}" GH_STUB_RELEASE_URL_FILE="${release_url_file}" GH_STUB_RELEASE_BY_TAG_FILE="${release_by_tag_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-state.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T42: state drift exits non-zero" "1" "${rc}"
assert_contains "T42: state drift names mismatch" "published release state mismatch" "${out}"
assert_contains "T42: state drift reports draft=true" "isDraft is true (expected false)" "${out}"
assert_contains "T42: state drift reports untagged URL" "releases/tag/untagged-2662d91ad3ad034f32f6" "${out}"
assert_contains "T42: state drift reports missing REST tag route" "REST tag endpoint repos/example/fixture/releases/tags/v1.0.0 did not resolve" "${out}"
assert_contains "T42: state drift prints gh remediation" "gh release edit v1.0.0 --repo example/fixture --draft=false --prerelease=false --tag v1.0.0" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 43: published-release state verifier --fix repairs drift\n'
repo="$(mk_release_fixture)"
gh_stub_dir="$(mk_gh_stub)"
release_draft_file="${repo}/published-release-draft.txt"
release_prerelease_file="${repo}/published-release-prerelease.txt"
release_published_at_file="${repo}/published-release-published-at.txt"
release_url_file="${repo}/published-release-url.txt"
release_by_tag_file="${repo}/published-release-by-tag.txt"
printf 'true' > "${release_draft_file}"
printf 'false' > "${release_prerelease_file}"
printf '2026-05-01T00:08:37Z' > "${release_published_at_file}"
printf 'https://github.com/example/fixture/releases/tag/untagged-2662d91ad3ad034f32f6' > "${release_url_file}"
printf 'false' > "${release_by_tag_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_DRAFT_FILE="${release_draft_file}" GH_STUB_RELEASE_PRERELEASE_FILE="${release_prerelease_file}" GH_STUB_RELEASE_PUBLISHED_AT_FILE="${release_published_at_file}" GH_STUB_RELEASE_URL_FILE="${release_url_file}" GH_STUB_RELEASE_BY_TAG_FILE="${release_by_tag_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-state.sh "1.0.0" --repo "example/fixture" --fix 2>&1)"
rc=$?
set -e
actual_release_draft="$(cat "${release_draft_file}")"
actual_release_prerelease="$(cat "${release_prerelease_file}")"
actual_release_url="$(cat "${release_url_file}")"
actual_release_by_tag="$(cat "${release_by_tag_file}")"
assert_eq "T43: state --fix exits 0" "0" "${rc}"
assert_contains "T43: state --fix reports repair" "published release state repaired and verified" "${out}"
assert_eq "T43: state --fix clears draft" "false" "${actual_release_draft}"
assert_eq "T43: state --fix clears prerelease" "false" "${actual_release_prerelease}"
assert_eq "T43: state --fix restores canonical URL" "https://github.com/example/fixture/releases/tag/v1.0.0" "${actual_release_url}"
assert_eq "T43: state --fix restores REST tag route" "true" "${actual_release_by_tag}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 44: batch state auditor reports and repairs historical drift\n'
repo="$(mk_release_fixture)"
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_draft_dir="${repo}/release-drafts"
release_prerelease_dir="${repo}/release-prereleases"
release_published_at_dir="${repo}/release-published-at"
release_url_dir="${repo}/release-urls"
release_by_tag_dir="${repo}/release-by-tag"
mkdir -p "${release_draft_dir}" "${release_prerelease_dir}" "${release_published_at_dir}" "${release_url_dir}" "${release_by_tag_dir}"
release_list_file="${repo}/release-tags.txt"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
printf 'true' > "${release_draft_dir}/v1.0.0.txt"
printf 'false' > "${release_prerelease_dir}/v1.0.0.txt"
printf '2026-05-01T00:08:37Z' > "${release_published_at_dir}/v1.0.0.txt"
printf 'https://github.com/example/fixture/releases/tag/untagged-2662d91ad3ad034f32f6' > "${release_url_dir}/v1.0.0.txt"
printf 'false' > "${release_by_tag_dir}/v1.0.0.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_DRAFT_DIR="${release_draft_dir}" GH_STUB_RELEASE_PRERELEASE_DIR="${release_prerelease_dir}" GH_STUB_RELEASE_PUBLISHED_AT_DIR="${release_published_at_dir}" GH_STUB_RELEASE_URL_DIR="${release_url_dir}" GH_STUB_RELEASE_BY_TAG_DIR="${release_by_tag_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-states.sh --repo example/fixture 2>&1)"
rc=$?
set -e
assert_eq "T44: mixed state audit exits non-zero" "1" "${rc}"
assert_contains "T44: mixed state audit reports ok tag" $'OK\tv1.0.1\tverify-published-release-state: published release state is canonical' "${out}"
assert_contains "T44: mixed state audit reports drift tag" $'DRIFT\tv1.0.0\tverify-published-release-state: published release state mismatch' "${out}"
assert_contains "T44: mixed state audit prints summary" "summary: 1 OK, 0 FIXED, 1 FAIL" "${out}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_DRAFT_DIR="${release_draft_dir}" GH_STUB_RELEASE_PRERELEASE_DIR="${release_prerelease_dir}" GH_STUB_RELEASE_PUBLISHED_AT_DIR="${release_published_at_dir}" GH_STUB_RELEASE_URL_DIR="${release_url_dir}" GH_STUB_RELEASE_BY_TAG_DIR="${release_by_tag_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-states.sh --repo example/fixture --fix 2>&1)"
rc=$?
set -e
fixed_release_draft_v100="$(cat "${release_draft_dir}/v1.0.0.txt")"
fixed_release_prerelease_v100="$(cat "${release_prerelease_dir}/v1.0.0.txt")"
fixed_release_url_v100="$(cat "${release_url_dir}/v1.0.0.txt")"
fixed_release_by_tag_v100="$(cat "${release_by_tag_dir}/v1.0.0.txt")"
assert_eq "T44: state batch fix exits 0" "0" "${rc}"
assert_contains "T44: state batch fix reports fixed tag" $'FIXED\tv1.0.0\tverify-published-release-state: published release state repaired and verified' "${out}"
assert_contains "T44: state batch fix reports ok tag" $'OK\tv1.0.1\tverify-published-release-state: published release state is canonical' "${out}"
assert_contains "T44: state batch fix prints summary" "summary: 1 OK, 1 FIXED, 0 FAIL" "${out}"
assert_eq "T44: state batch fix clears draft" "false" "${fixed_release_draft_v100}"
assert_eq "T44: state batch fix clears prerelease" "false" "${fixed_release_prerelease_v100}"
assert_eq "T44: state batch fix restores canonical URL" "https://github.com/example/fixture/releases/tag/v1.0.0" "${fixed_release_url_v100}"
assert_eq "T44: state batch fix restores REST tag route" "true" "${fixed_release_by_tag_v100}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 45: build-release-assets helper emits deterministic source bundles and checksum manifest\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
asset_dir_one="$(mktemp -d -t release-assets-one-XXXXXX)"
asset_dir_two="$(mktemp -d -t release-assets-two-XXXXXX)"
set +e
out_one="$(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${asset_dir_one}" 2>&1)"
rc_one=$?
out_two="$(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${asset_dir_two}" 2>&1)"
rc_two=$?
set -e
assert_eq "T45: first asset build exits 0" "0" "${rc_one}"
assert_eq "T45: second asset build exits 0" "0" "${rc_two}"
assert_true "T45: tarball created" "[[ -f '${asset_dir_one}/oh-my-claude-v1.0.0.tar.gz' ]]"
assert_true "T45: zip created" "[[ -f '${asset_dir_one}/oh-my-claude-v1.0.0.zip' ]]"
assert_true "T45: checksum manifest created" "[[ -f '${asset_dir_one}/oh-my-claude-v1.0.0.SHA256SUMS' ]]"
assert_contains "T45: checksum manifest mentions tarball" "oh-my-claude-v1.0.0.tar.gz" "$(cat "${asset_dir_one}/oh-my-claude-v1.0.0.SHA256SUMS")"
assert_contains "T45: checksum manifest mentions zip" "oh-my-claude-v1.0.0.zip" "$(cat "${asset_dir_one}/oh-my-claude-v1.0.0.SHA256SUMS")"
if cmp -s "${asset_dir_one}/oh-my-claude-v1.0.0.tar.gz" "${asset_dir_two}/oh-my-claude-v1.0.0.tar.gz"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T45: tarball build is not deterministic\n' >&2
  fail=$((fail + 1))
fi
if cmp -s "${asset_dir_one}/oh-my-claude-v1.0.0.zip" "${asset_dir_two}/oh-my-claude-v1.0.0.zip"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T45: zip build is not deterministic\n' >&2
  fail=$((fail + 1))
fi
if cmp -s "${asset_dir_one}/oh-my-claude-v1.0.0.SHA256SUMS" "${asset_dir_two}/oh-my-claude-v1.0.0.SHA256SUMS"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T45: checksum manifest build is not deterministic\n' >&2
  fail=$((fail + 1))
fi
rm -rf "${asset_dir_one}" "${asset_dir_two}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 46: published-release asset verifier detects missing attached assets\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
mkdir -p "${release_asset_root}/v1.0.0"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-assets.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T46: asset drift exits non-zero" "1" "${rc}"
assert_contains "T46: asset drift names mismatch" "published release assets mismatch" "${out}"
assert_contains "T46: asset drift reports missing tarball" "missing attached asset oh-my-claude-v1.0.0.tar.gz" "${out}"
assert_contains "T46: asset drift prints upload remediation" 'gh release upload v1.0.0 --repo example/fixture --clobber' "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 47: published-release asset verifier --fix repairs missing assets\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
mkdir -p "${release_asset_root}/v1.0.0"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-assets.sh "1.0.0" --repo "example/fixture" --fix 2>&1)"
rc=$?
set -e
assert_eq "T47: asset --fix exits 0" "0" "${rc}"
assert_contains "T47: asset --fix reports repair" "published release assets repaired and verified" "${out}"
assert_true "T47: asset --fix uploads tarball" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.tar.gz' ]]"
assert_true "T47: asset --fix uploads zip" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.zip' ]]"
assert_true "T47: asset --fix uploads checksum manifest" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.SHA256SUMS' ]]"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 48: batch asset auditor reports and repairs historical drift\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_list_file="${repo}/release-tags.txt"
mkdir -p "${release_asset_root}"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
mkdir -p "${release_asset_root}/v1.0.1"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.1" --out-dir "${release_asset_root}/v1.0.1" >/dev/null)
mkdir -p "${release_asset_root}/v1.0.0"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-assets.sh --repo example/fixture 2>&1)"
rc=$?
set -e
assert_eq "T48: mixed asset audit exits non-zero" "1" "${rc}"
assert_contains "T48: mixed asset audit reports ok tag" $'OK\tv1.0.1\tverify-published-release-assets: published release assets are canonical' "${out}"
assert_contains "T48: mixed asset audit reports drift tag" $'DRIFT\tv1.0.0\tverify-published-release-assets: published release assets mismatch' "${out}"
assert_contains "T48: mixed asset audit prints summary" "summary: 1 OK, 0 FIXED, 1 FAIL" "${out}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-assets.sh --repo example/fixture --fix 2>&1)"
rc=$?
set -e
assert_eq "T48: asset batch fix exits 0" "0" "${rc}"
assert_contains "T48: asset batch fix reports fixed tag" $'FIXED\tv1.0.0\tverify-published-release-assets: published release assets repaired and verified' "${out}"
assert_contains "T48: asset batch fix reports ok tag" $'OK\tv1.0.1\tverify-published-release-assets: published release assets are canonical' "${out}"
assert_contains "T48: asset batch fix prints summary" "summary: 1 OK, 1 FIXED, 0 FAIL" "${out}"
assert_true "T48: asset batch fix uploads missing tarball" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.tar.gz' ]]"
assert_true "T48: asset batch fix uploads missing zip" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.zip' ]]"
assert_true "T48: asset batch fix uploads missing checksum manifest" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.SHA256SUMS' ]]"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 49: published-release attestation verifier detects missing attestations\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
mkdir -p "${release_asset_root}/v1.0.0"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-attestations.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T49: attestation drift exits non-zero" "1" "${rc}"
assert_contains "T49: attestation drift names mismatch" "published release attestations mismatch" "${out}"
assert_contains "T49: attestation drift reports missing attestation" "no matching attestations found" "${out}"
assert_contains "T49: attestation drift prints workflow rerun remediation" 'gh workflow run attest-release-assets.yml -R example/fixture -f tag=v1.0.0' "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 50: published-release attestation verifier accepts canonical signer workflow\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
attested_tags_file="${repo}/attested-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
printf 'v1.0.0\n' > "${attested_tags_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release-attestations.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T50: attestation verification exits 0" "0" "${rc}"
assert_contains "T50: attestation verification reports success" "published release attestations are canonical" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 51: batch attestation auditor reports mixed historical provenance\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
attested_tags_file="${repo}/attested-tags.txt"
release_list_file="${repo}/release-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0" "${release_asset_root}/v1.0.1"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.1" --out-dir "${release_asset_root}/v1.0.1" >/dev/null)
printf 'v1.0.1\n' > "${attested_tags_file}"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-release-attestations.sh --repo example/fixture 2>&1)"
rc=$?
set -e
assert_eq "T51: mixed attestation audit exits non-zero" "1" "${rc}"
assert_contains "T51: mixed attestation audit reports ok tag" $'OK\tv1.0.1\tverify-published-release-attestations: published release attestations are canonical' "${out}"
assert_contains "T51: mixed attestation audit reports drift tag" $'DRIFT\tv1.0.0\tverify-published-release-attestations: published release attestations mismatch' "${out}"
assert_contains "T51: mixed attestation audit prints summary" "summary: 1 OK, 1 FAIL" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 52: attestation waiter fails clearly when workflow is absent on remote\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
workflow_list_file="${repo}/workflow-list.tsv"
mkdir -p "${release_asset_root}/v1.0.0"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
printf 'Validate\tactive\t257094321\t.github/workflows/validate.yml\n' > "${workflow_list_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/wait-for-release-attestations.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T52: waiter exits non-zero when workflow missing" "1" "${rc}"
assert_contains "T52: waiter names missing workflow" "workflow attest-release-assets.yml not found on the default branch" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 53: attestation waiter watches existing run and verifies provenance\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
target_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
printf '7001\tattest-release-assets.yml\t%s\tv1.0.0\tcompleted\tsuccess\n' "${target_sha}" > "${run_registry_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/wait-for-release-attestations.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T53: waiter exits 0 on existing successful run" "0" "${rc}"
assert_contains "T53: waiter announces watched run" "watching workflow run 7001" "${out}"
assert_contains "T53: waiter reports attestation verification success" "published release attestations are canonical" "${out}"
assert_contains "T53: waiter marks tag attested after watch" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 54: attestation waiter dispatches workflow when missing and then verifies provenance\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
dispatch_sha_dir="${repo}/dispatch-shas"
mkdir -p "${release_asset_root}/v1.0.0" "${dispatch_sha_dir}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
target_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
printf '%s' "${target_sha}" > "${dispatch_sha_dir}/v1.0.0.txt"
: > "${run_registry_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_WORKFLOW_DISPATCH_SHA_DIR="${dispatch_sha_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/wait-for-release-attestations.sh "1.0.0" --repo "example/fixture" --trigger-if-missing --poll-attempts 1 --poll-interval 1 2>&1)"
rc=$?
set -e
assert_eq "T54: waiter exits 0 after workflow dispatch" "0" "${rc}"
assert_contains "T54: waiter reports watched dispatched run" "watching workflow run" "${out}"
assert_contains "T54: waiter reports attestation verification success" "published release attestations are canonical" "${out}"
assert_true "T54: workflow dispatch created run record" "[[ -s '${run_registry_file}' ]]"
assert_contains "T54: dispatched wait marks tag attested" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 55: unified published-release verifier proves the full release contract\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_body_file="${repo}/published-release-body.txt"
release_name_file="${repo}/published-release-name.txt"
attested_tags_file="${repo}/attested-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0"
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
expected_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
expected_body="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${expected_sha}")"
printf '%s' "${expected_title}" > "${release_name_file}"
printf '%s' "${expected_body}" > "${release_body_file}"
printf 'v1.0.0\n' > "${attested_tags_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release.sh "1.0.0" --repo "example/fixture" 2>&1)"
rc=$?
set -e
assert_eq "T55: unified verifier exits 0 on canonical release" "0" "${rc}"
assert_contains "T55: unified verifier reports title success" $'OK\ttitle\tverify-published-release-title: published release title matches canonical helper' "${out}"
assert_contains "T55: unified verifier reports body success" $'OK\tbody\tverify-published-release-body: published release body matches canonical helper' "${out}"
assert_contains "T55: unified verifier reports state success" $'OK\tstate\tverify-published-release-state: published release state is canonical' "${out}"
assert_contains "T55: unified verifier reports assets success" $'OK\tassets\tverify-published-release-assets: published release assets are canonical' "${out}"
assert_contains "T55: unified verifier reports attestation success" $'OK\tattestations\tverify-published-release-attestations: published release attestations are canonical' "${out}"
assert_contains "T55: unified verifier prints all-green summary" "summary: 5 OK, 0 FIXED, 0 SKIPPED, 0 FAIL" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 56: unified published-release verifier repairs sync surfaces under --fix\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_body_file="${repo}/published-release-body.txt"
release_name_file="${repo}/published-release-name.txt"
release_draft_file="${repo}/published-release-draft.txt"
release_prerelease_file="${repo}/published-release-prerelease.txt"
release_published_at_file="${repo}/published-release-published-at.txt"
release_url_file="${repo}/published-release-url.txt"
release_by_tag_file="${repo}/published-release-by-tag.txt"
printf 'Draft title' > "${release_name_file}"
printf 'Draft body' > "${release_body_file}"
printf 'true' > "${release_draft_file}"
printf 'true' > "${release_prerelease_file}"
printf '0001-01-01T00:00:00Z' > "${release_published_at_file}"
printf 'https://github.com/example/fixture/releases/tag/untagged-bad' > "${release_url_file}"
printf 'false' > "${release_by_tag_file}"
mkdir -p "${release_asset_root}/v1.0.0"
printf 'garbage\n' > "${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.SHA256SUMS"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_DRAFT_FILE="${release_draft_file}" GH_STUB_RELEASE_PRERELEASE_FILE="${release_prerelease_file}" GH_STUB_RELEASE_PUBLISHED_AT_FILE="${release_published_at_file}" GH_STUB_RELEASE_URL_FILE="${release_url_file}" GH_STUB_RELEASE_BY_TAG_FILE="${release_by_tag_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release.sh "1.0.0" --repo "example/fixture" --fix --attestations skip 2>&1)"
rc=$?
set -e
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
expected_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
expected_body="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${expected_sha}")"
assert_eq "T56: unified verifier exits 0 after repairing sync surfaces" "0" "${rc}"
assert_contains "T56: unified verifier reports fixed title" $'FIXED\ttitle\tverify-published-release-title: published release title repaired and verified' "${out}"
assert_contains "T56: unified verifier reports fixed body" $'FIXED\tbody\tverify-published-release-body: published release body repaired and verified' "${out}"
assert_contains "T56: unified verifier reports fixed state" $'FIXED\tstate\tverify-published-release-state: published release state repaired and verified' "${out}"
assert_contains "T56: unified verifier reports fixed assets" $'FIXED\tassets\tverify-published-release-assets: published release assets repaired and verified' "${out}"
assert_contains "T56: unified verifier reports skipped attestations" $'SKIP\tattestations\tverify-published-release: attestations skipped by caller' "${out}"
assert_contains "T56: unified verifier prints repair summary" "summary: 0 OK, 4 FIXED, 1 SKIPPED, 0 FAIL" "${out}"
assert_eq "T56: --fix restores canonical title" "${expected_title}" "$(cat "${release_name_file}")"
assert_eq "T56: --fix restores canonical body" "${expected_body}" "$(cat "${release_body_file}")"
assert_eq "T56: --fix clears draft state" "false" "$(cat "${release_draft_file}")"
assert_eq "T56: --fix clears prerelease state" "false" "$(cat "${release_prerelease_file}")"
assert_eq "T56: --fix restores canonical release URL" "https://github.com/example/fixture/releases/tag/v1.0.0" "$(cat "${release_url_file}")"
assert_eq "T56: --fix restores REST tag route" "true" "$(cat "${release_by_tag_file}")"
assert_true "T56: --fix uploads canonical tarball asset" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.tar.gz' ]]"
assert_true "T56: --fix uploads canonical zip asset" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.zip' ]]"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 57: unified published-release verifier can wait for and trigger attestations\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_body_file="${repo}/published-release-body.txt"
release_name_file="${repo}/published-release-name.txt"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
dispatch_sha_dir="${repo}/dispatch-shas"
mkdir -p "${release_asset_root}/v1.0.0" "${dispatch_sha_dir}"
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
expected_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
expected_body="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${expected_sha}")"
printf '%s' "${expected_title}" > "${release_name_file}"
printf '%s' "${expected_body}" > "${release_body_file}"
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
printf '%s' "${expected_sha}" > "${dispatch_sha_dir}/v1.0.0.txt"
: > "${run_registry_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_WORKFLOW_DISPATCH_SHA_DIR="${dispatch_sha_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release.sh "1.0.0" --repo "example/fixture" --attestations wait --trigger-attestations-if-missing --attestation-poll-attempts 1 --attestation-poll-interval 1 2>&1)"
rc=$?
set -e
assert_eq "T57: unified verifier exits 0 after attestation wait" "0" "${rc}"
assert_contains "T57: unified verifier reports all-green summary after wait" "summary: 5 OK, 0 FIXED, 0 SKIPPED, 0 FAIL" "${out}"
assert_contains "T57: wait path reports attestation surface success" $'OK\tattestations\twait-for-release-attestations: watching workflow run' "${out}"
assert_true "T57: attestation wait dispatches a workflow run" "[[ -s '${run_registry_file}' ]]"
assert_contains "T57: attestation wait marks tag attested" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 58: unified historical published-release audit reports mixed release state\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

second.

## [1.0.0] - 2026-01-01

initial.
CL
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION CHANGELOG.md && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_dir="${repo}/release-names"
release_body_dir="${repo}/release-bodies"
release_list_file="${repo}/release-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0" "${release_asset_root}/v1.0.1" "${release_name_dir}" "${release_body_dir}"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.1" --out-dir "${release_asset_root}/v1.0.1" >/dev/null)
title_v100="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
title_v101="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.1")"
body_v101="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.1" --sha "$(git -C "${repo}" rev-parse "v1.0.1^{commit}")")"
printf '%s' "${title_v100}" > "${release_name_dir}/v1.0.0.txt"
printf '%s' "${title_v101}" > "${release_name_dir}/v1.0.1.txt"
printf 'Release v1.0.0' > "${release_body_dir}/v1.0.0.txt"
printf '%s' "${body_v101}" > "${release_body_dir}/v1.0.1.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_DIR="${release_name_dir}" GH_STUB_RELEASE_BODY_DIR="${release_body_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-releases.sh --repo example/fixture --attestations skip 2>&1)"
rc=$?
set -e
assert_eq "T58: unified historical audit exits non-zero on drift" "1" "${rc}"
assert_contains "T58: unified historical audit reports clean tag" $'OK\tv1.0.1\tverify-published-release: summary: 4 OK, 0 FIXED, 1 SKIPPED, 0 FAIL' "${out}"
assert_contains "T58: unified historical audit reports drifting tag" $'DRIFT\tv1.0.0\tverify-published-release: summary: 3 OK, 0 FIXED, 1 SKIPPED, 1 FAIL' "${out}"
assert_contains "T58: unified historical audit prints summary" "summary: 1 OK, 0 FIXED, 1 FAIL" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 59: unified historical published-release audit repairs sync-surface drift\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

second.

## [1.0.0] - 2026-01-01

initial.
CL
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION CHANGELOG.md && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_dir="${repo}/release-names"
release_body_dir="${repo}/release-bodies"
release_draft_dir="${repo}/release-drafts"
release_prerelease_dir="${repo}/release-prereleases"
release_published_at_dir="${repo}/release-published-at"
release_url_dir="${repo}/release-urls"
release_by_tag_dir="${repo}/release-by-tag"
release_list_file="${repo}/release-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0" "${release_asset_root}/v1.0.1" \
  "${release_name_dir}" "${release_body_dir}" "${release_draft_dir}" \
  "${release_prerelease_dir}" "${release_published_at_dir}" \
  "${release_url_dir}" "${release_by_tag_dir}"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.1" --out-dir "${release_asset_root}/v1.0.1" >/dev/null)
printf 'garbage\n' > "${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.SHA256SUMS"
title_v100="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
title_v101="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.1")"
body_v100="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "$(git -C "${repo}" rev-parse "v1.0.0^{commit}")")"
body_v101="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.1" --sha "$(git -C "${repo}" rev-parse "v1.0.1^{commit}")")"
printf 'Draft title' > "${release_name_dir}/v1.0.0.txt"
printf '%s' "${title_v101}" > "${release_name_dir}/v1.0.1.txt"
printf 'Draft body' > "${release_body_dir}/v1.0.0.txt"
printf '%s' "${body_v101}" > "${release_body_dir}/v1.0.1.txt"
printf 'true' > "${release_draft_dir}/v1.0.0.txt"
printf 'true' > "${release_prerelease_dir}/v1.0.0.txt"
printf '0001-01-01T00:00:00Z' > "${release_published_at_dir}/v1.0.0.txt"
printf 'https://github.com/example/fixture/releases/tag/untagged-bad' > "${release_url_dir}/v1.0.0.txt"
printf 'false' > "${release_by_tag_dir}/v1.0.0.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_DIR="${release_name_dir}" GH_STUB_RELEASE_BODY_DIR="${release_body_dir}" GH_STUB_RELEASE_DRAFT_DIR="${release_draft_dir}" GH_STUB_RELEASE_PRERELEASE_DIR="${release_prerelease_dir}" GH_STUB_RELEASE_PUBLISHED_AT_DIR="${release_published_at_dir}" GH_STUB_RELEASE_URL_DIR="${release_url_dir}" GH_STUB_RELEASE_BY_TAG_DIR="${release_by_tag_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-releases.sh --repo example/fixture --fix --attestations skip 2>&1)"
rc=$?
set -e
assert_eq "T59: unified historical audit --fix exits 0" "0" "${rc}"
assert_contains "T59: unified historical audit --fix reports clean tag" $'OK\tv1.0.1\tverify-published-release: summary: 4 OK, 0 FIXED, 1 SKIPPED, 0 FAIL' "${out}"
assert_contains "T59: unified historical audit --fix reports fixed tag" $'FIXED\tv1.0.0\tverify-published-release: summary: 0 OK, 4 FIXED, 1 SKIPPED, 0 FAIL' "${out}"
assert_contains "T59: unified historical audit --fix prints summary" "summary: 1 OK, 1 FIXED, 0 FAIL" "${out}"
assert_eq "T59: unified historical audit --fix restores canonical title" "${title_v100}" "$(cat "${release_name_dir}/v1.0.0.txt")"
assert_eq "T59: unified historical audit --fix restores canonical body" "${body_v100}" "$(cat "${release_body_dir}/v1.0.0.txt")"
assert_eq "T59: unified historical audit --fix clears draft state" "false" "$(cat "${release_draft_dir}/v1.0.0.txt")"
assert_eq "T59: unified historical audit --fix clears prerelease state" "false" "$(cat "${release_prerelease_dir}/v1.0.0.txt")"
assert_eq "T59: unified historical audit --fix restores canonical release URL" "https://github.com/example/fixture/releases/tag/v1.0.0" "$(cat "${release_url_dir}/v1.0.0.txt")"
assert_eq "T59: unified historical audit --fix restores REST tag route" "true" "$(cat "${release_by_tag_dir}/v1.0.0.txt")"
assert_true "T59: unified historical audit --fix uploads canonical tarball asset" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.tar.gz' ]]"
assert_true "T59: unified historical audit --fix uploads canonical zip asset" "[[ -f '${release_asset_root}/v1.0.0/oh-my-claude-v1.0.0.zip' ]]"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 60: unified historical published-release audit can wait for and trigger attestations\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_file="${repo}/published-release-name.txt"
release_body_file="${repo}/published-release-body.txt"
release_list_file="${repo}/release-tags.txt"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
dispatch_sha_dir="${repo}/dispatch-shas"
mkdir -p "${release_asset_root}/v1.0.0" "${dispatch_sha_dir}"
printf 'v1.0.0\n' > "${release_list_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
tag_sha_v100="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
printf '%s' "$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")" > "${release_name_file}"
printf '%s' "$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${tag_sha_v100}")" > "${release_body_file}"
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
printf '%s' "${tag_sha_v100}" > "${dispatch_sha_dir}/v1.0.0.txt"
: > "${run_registry_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_WORKFLOW_DISPATCH_SHA_DIR="${dispatch_sha_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-releases.sh --repo example/fixture --attestations wait --trigger-attestations-if-missing --attestation-poll-attempts 1 --attestation-poll-interval 1 2>&1)"
rc=$?
set -e
assert_eq "T60: unified historical audit with attestation wait exits 0" "0" "${rc}"
assert_contains "T60: unified historical audit with attestation wait reports clean tag" $'OK\tv1.0.0\tverify-published-release: summary: 5 OK, 0 FIXED, 0 SKIPPED, 0 FAIL' "${out}"
assert_contains "T60: unified historical audit with attestation wait prints summary" "summary: 1 OK, 0 FIXED, 0 FAIL" "${out}"
assert_true "T60: unified historical audit wait dispatches a workflow run" "[[ -s '${run_registry_file}' ]]"
assert_contains "T60: unified historical audit wait marks tag attested" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 61: release-automation deployment verifier reports match, drift, and missing-remote surfaces\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows"
printf '\n# local drift for deployment audit\n' >> "${repo}/tools/release.sh"
printf 'name: deploy-proof\n' > "${repo}/.github/workflows/deploy-proof.yml"
(cd "${repo}" && git add tools/release.sh .github/workflows/deploy-proof.yml && git commit -q -m "local release automation drift")
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --local-ref HEAD --remote-ref HEAD~1 --path README.md --path tools/release.sh --path .github/workflows/deploy-proof.yml 2>&1)"
rc=$?
set -e
assert_eq "T61: deployment verifier exits non-zero on remote drift" "1" "${rc}"
assert_contains "T61: deployment verifier reports unchanged surface" $'MATCH\tREADME.md' "${out}"
assert_contains "T61: deployment verifier reports drifting surface" $'DRIFT\ttools/release.sh' "${out}"
assert_contains "T61: deployment verifier reports missing remote surface" $'MISSING_REMOTE\t.github/workflows/deploy-proof.yml' "${out}"
assert_contains "T61: deployment verifier prints mixed summary" "summary: 1 MATCH, 1 DRIFT, 1 MISSING_REMOTE, 0 MISSING_LOCAL" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 62: release-automation deployment verifier resolves origin default branch and passes when deployed\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --path README.md --path tools/release.sh --path .github/workflows/attest-release-assets.yml 2>&1)"
rc=$?
set -e
assert_eq "T62: deployment verifier exits 0 when remote default branch matches" "0" "${rc}"
assert_contains "T62: deployment verifier reports README match" $'MATCH\tREADME.md' "${out}"
assert_contains "T62: deployment verifier reports release tool match" $'MATCH\ttools/release.sh' "${out}"
assert_contains "T62: deployment verifier reports workflow match" $'MATCH\t.github/workflows/attest-release-assets.yml' "${out}"
assert_contains "T62: deployment verifier prints all-match summary" "summary: 3 MATCH, 0 DRIFT, 0 MISSING_REMOTE, 0 MISSING_LOCAL" "${out}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 63: release-automation deployment verifier defaults to WORKTREE and catches uncommitted local drift\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
mkdir -p "${repo}/.github/workflows"
printf '\n# uncommitted local drift for deployment audit\n' >> "${repo}/tools/release.sh"
printf 'name: deploy-proof\n' > "${repo}/.github/workflows/deploy-proof.yml"
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --path README.md --path tools/release.sh --path .github/workflows/deploy-proof.yml 2>&1)"
rc=$?
set -e
assert_eq "T63: deployment verifier exits non-zero on uncommitted worktree drift" "1" "${rc}"
assert_contains "T63: deployment verifier reports unchanged surface from worktree" $'MATCH\tREADME.md' "${out}"
assert_contains "T63: deployment verifier reports drifting tracked surface from worktree" $'DRIFT\ttools/release.sh' "${out}"
assert_contains "T63: deployment verifier reports missing remote for uncommitted workflow" $'MISSING_REMOTE\t.github/workflows/deploy-proof.yml' "${out}"
assert_contains "T63: deployment verifier worktree summary avoids false missing-local" "summary: 1 MATCH, 1 DRIFT, 1 MISSING_REMOTE, 0 MISSING_LOCAL" "${out}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 64: top-level distribution readiness passes on deployed canonical release state\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
origin_dir="$(mktemp -d -t release-distribution-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_file="${repo}/published-release-name.txt"
release_body_file="${repo}/published-release-body.txt"
release_list_file="${repo}/release-tags.txt"
attested_tags_file="${repo}/attested-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
printf '%s' "$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")" > "${release_name_file}"
printf '%s' "$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "$(git -C "${repo}" rev-parse "v1.0.0^{commit}")")" > "${release_body_file}"
printf 'v1.0.0\n' > "${release_list_file}"
printf 'v1.0.0\n' > "${attested_tags_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-distribution-readiness.sh --fetch --repo example/fixture --release-version 1.0.0 --history-limit 1 2>&1)"
rc=$?
set -e
assert_eq "T64: distribution readiness exits 0 on green state" "0" "${rc}"
assert_contains "T64: distribution readiness reports deployment ok" $'OK\tdeployment\tverify-release-automation-deployment: release automation deployment is current at origin/main' "${out}"
assert_contains "T64: distribution readiness reports local deployment candidate ok" $'OK\tdeployment_candidate\tprepare-release-automation-deployment: selected release/distribution surface already matches the remote deployment ref' "${out}"
assert_contains "T64: distribution readiness reports current release ok" $'OK\tcurrent_release\tverify-published-release: published release is canonical for example/fixture v1.0.0' "${out}"
assert_contains "T64: distribution readiness reports history ok" $'OK\thistory\taudit-published-releases: summary: 1 OK, 0 FIXED, 0 FAIL' "${out}"
assert_contains "T64: distribution readiness prints all-green summary" "summary: 4 OK, 0 SKIP, 0 FAIL" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 65: top-level distribution readiness isolates deployment drift from published-release health\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
origin_dir="$(mktemp -d -t release-distribution-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_file="${repo}/published-release-name.txt"
release_body_file="${repo}/published-release-body.txt"
release_list_file="${repo}/release-tags.txt"
attested_tags_file="${repo}/attested-tags.txt"
mkdir -p "${repo}/.github/workflows" "${release_asset_root}/v1.0.0"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
printf '%s' "$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")" > "${release_name_file}"
printf '%s' "$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "$(git -C "${repo}" rev-parse "v1.0.0^{commit}")")" > "${release_body_file}"
printf 'v1.0.0\n' > "${release_list_file}"
printf 'v1.0.0\n' > "${attested_tags_file}"
printf '\n# local deployment drift\n' >> "${repo}/tools/release.sh"
printf 'name: local-only-workflow\n' > "${repo}/.github/workflows/local-only-workflow.yml"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-distribution-readiness.sh --fetch --repo example/fixture --release-version 1.0.0 --history-limit 1 2>&1)"
rc=$?
set -e
assert_eq "T65: distribution readiness exits non-zero on deployment drift" "1" "${rc}"
assert_contains "T65: distribution readiness reports deployment failure summary" $'FAIL\tdeployment\tverify-release-automation-deployment: summary: ' "${out}"
assert_contains "T65: distribution readiness keeps local deployment candidate green" $'OK\tdeployment_candidate\tprepare-release-automation-deployment: preview is coherent; rerun without --dry-run to stage, commit/push the candidate, then rerun tools/verify-distribution-readiness.sh' "${out}"
assert_contains "T65: distribution readiness keeps current release green" $'OK\tcurrent_release\tverify-published-release: published release is canonical for example/fixture v1.0.0' "${out}"
assert_contains "T65: distribution readiness keeps history green" $'OK\thistory\taudit-published-releases: summary: 1 OK, 0 FIXED, 0 FAIL' "${out}"
assert_contains "T65: distribution readiness prints mixed summary" "summary: 3 OK, 0 SKIP, 1 FAIL" "${out}"
assert_contains "T65: distribution readiness names remote deployment as the remaining blocker" 'verify-distribution-readiness: remote deployment is behind, but the local deployment candidate is coherent for example/fixture' "${out}"
assert_contains "T65: distribution readiness includes deployment detail block" $'[deployment]\nverify-release-automation-deployment: comparing local WORKTREE -> remote origin/main' "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 66: top-level distribution readiness scopes wait-only attestation args to wait surfaces\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
origin_dir="$(mktemp -d -t release-distribution-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_file="${repo}/published-release-name.txt"
release_body_file="${repo}/published-release-body.txt"
release_list_file="${repo}/release-tags.txt"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
dispatch_sha_dir="${repo}/dispatch-shas"
mkdir -p "${release_asset_root}/v1.0.0" "${dispatch_sha_dir}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
tag_sha_v100="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
printf '%s' "$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")" > "${release_name_file}"
printf '%s' "$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${tag_sha_v100}")" > "${release_body_file}"
printf 'v1.0.0\n' > "${release_list_file}"
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
printf '%s' "${tag_sha_v100}" > "${dispatch_sha_dir}/v1.0.0.txt"
: > "${run_registry_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_WORKFLOW_DISPATCH_SHA_DIR="${dispatch_sha_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-distribution-readiness.sh --fetch --repo example/fixture --release-version 1.0.0 --history-limit 1 --current-attestations wait --history-attestations skip --trigger-attestations-if-missing --attestation-poll-attempts 1 --attestation-poll-interval 1 2>&1)"
rc=$?
set -e
assert_eq "T66: distribution readiness exits 0 when only current release waits for attestations" "0" "${rc}"
assert_contains "T66: distribution readiness keeps deployment green" $'OK\tdeployment\tverify-release-automation-deployment: release automation deployment is current at origin/main' "${out}"
assert_contains "T66: distribution readiness reports local deployment candidate ok" $'OK\tdeployment_candidate\tprepare-release-automation-deployment: selected release/distribution surface already matches the remote deployment ref' "${out}"
assert_contains "T66: distribution readiness reports waited current release ok" $'OK\tcurrent_release\tverify-published-release: published release is canonical for example/fixture v1.0.0 after attestation wait' "${out}"
assert_contains "T66: distribution readiness keeps history green under skip mode" $'OK\thistory\taudit-published-releases: summary: 1 OK, 0 FIXED, 0 FAIL' "${out}"
assert_contains "T66: distribution readiness prints all-green summary after selective wait" "summary: 4 OK, 0 SKIP, 0 FAIL" "${out}"
assert_true "T66: distribution readiness selective wait dispatches a workflow run" "[[ -s '${run_registry_file}' ]]"
assert_contains "T66: distribution readiness selective wait marks tag attested" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 67: release-automation deployment verifier emits machine-readable JSON\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows"
printf '\n# local drift for deployment JSON audit\n' >> "${repo}/tools/release.sh"
printf 'name: deploy-proof\n' > "${repo}/.github/workflows/deploy-proof.yml"
(cd "${repo}" && git add tools/release.sh .github/workflows/deploy-proof.yml && git commit -q -m "local release automation drift")
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --local-ref HEAD --remote-ref HEAD~1 --path README.md --path tools/release.sh --path .github/workflows/deploy-proof.yml --json 2>&1)"
rc=$?
set -e
assert_eq "T67: deployment JSON exits non-zero on drift" "1" "${rc}"
assert_jq_eq "T67: deployment JSON result is fail" '.result' "fail" "${out}"
assert_jq_eq "T67: deployment JSON match count" '.counts.match' "1" "${out}"
assert_jq_eq "T67: deployment JSON drift count" '.counts.drift' "1" "${out}"
assert_jq_eq "T67: deployment JSON missing-remote count" '.counts.missing_remote' "1" "${out}"
assert_jq_eq "T67: deployment JSON README item is MATCH" '.items[] | select(.path=="README.md") | .status' "MATCH" "${out}"
assert_jq_eq "T67: deployment JSON release tool item is DRIFT" '.items[] | select(.path=="tools/release.sh") | .status' "DRIFT" "${out}"
assert_jq_eq "T67: deployment JSON local-only workflow item is MISSING_REMOTE" '.items[] | select(.path==".github/workflows/deploy-proof.yml") | .status' "MISSING_REMOTE" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 68: unified published-release verifier emits machine-readable JSON\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_file="${repo}/published-release-name.txt"
release_body_file="${repo}/published-release-body.txt"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
dispatch_sha_dir="${repo}/dispatch-shas"
mkdir -p "${release_asset_root}/v1.0.0" "${dispatch_sha_dir}"
expected_title="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
expected_sha="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
expected_body="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${expected_sha}")"
printf '%s' "${expected_title}" > "${release_name_file}"
printf '%s' "${expected_body}" > "${release_body_file}"
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
printf '%s' "${expected_sha}" > "${dispatch_sha_dir}/v1.0.0.txt"
: > "${run_registry_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_WORKFLOW_DISPATCH_SHA_DIR="${dispatch_sha_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-published-release.sh "1.0.0" --repo "example/fixture" --attestations wait --trigger-attestations-if-missing --attestation-poll-attempts 1 --attestation-poll-interval 1 --json 2>&1)"
rc=$?
set -e
assert_eq "T68: published-release JSON exits 0 after attestation wait" "0" "${rc}"
assert_jq_eq "T68: published-release JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T68: published-release JSON ok count" '.counts.ok' "5" "${out}"
assert_jq_eq "T68: published-release JSON attestation mode is wait" '.attestations_mode' "wait" "${out}"
assert_jq_eq "T68: published-release JSON attestation surface is OK" '.surfaces[] | select(.name=="attestations") | .status' "OK" "${out}"
assert_jq_eq "T68: published-release JSON success message mentions attestation wait" '.message' "verify-published-release: published release is canonical for example/fixture v1.0.0 after attestation wait" "${out}"
assert_true "T68: published-release JSON wait dispatches a workflow run" "[[ -s '${run_registry_file}' ]]"
assert_contains "T68: published-release JSON wait marks tag attested" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 69: unified historical published-release audit emits machine-readable JSON\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.1] - 2026-01-02

second.

## [1.0.0] - 2026-01-01

initial.
CL
printf '1.0.1\n' > "${repo}/VERSION"
(cd "${repo}" && git add VERSION CHANGELOG.md && git commit -q -m "prepare v1.0.1" && git tag "v1.0.1")
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_dir="${repo}/release-names"
release_body_dir="${repo}/release-bodies"
release_list_file="${repo}/release-tags.txt"
mkdir -p "${release_asset_root}/v1.0.0" "${release_asset_root}/v1.0.1" "${release_name_dir}" "${release_body_dir}"
printf 'v1.0.1\nv1.0.0\n' > "${release_list_file}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.1" --out-dir "${release_asset_root}/v1.0.1" >/dev/null)
title_v100="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")"
title_v101="$(cd "${repo}" && bash tools/render-release-title.sh "1.0.1")"
body_v101="$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.1" --sha "$(git -C "${repo}" rev-parse "v1.0.1^{commit}")")"
printf '%s' "${title_v100}" > "${release_name_dir}/v1.0.0.txt"
printf '%s' "${title_v101}" > "${release_name_dir}/v1.0.1.txt"
printf 'Release v1.0.0' > "${release_body_dir}/v1.0.0.txt"
printf '%s' "${body_v101}" > "${release_body_dir}/v1.0.1.txt"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_DIR="${release_name_dir}" GH_STUB_RELEASE_BODY_DIR="${release_body_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/audit-published-releases.sh --repo example/fixture --attestations skip --json 2>&1)"
rc=$?
set -e
assert_eq "T69: historical audit JSON exits non-zero on drift" "1" "${rc}"
assert_jq_eq "T69: historical audit JSON result is fail" '.result' "fail" "${out}"
assert_jq_eq "T69: historical audit JSON ok count" '.counts.ok' "1" "${out}"
assert_jq_eq "T69: historical audit JSON fail count" '.counts.fail' "1" "${out}"
assert_jq_eq "T69: historical audit JSON clean tag is OK" '.releases[] | select(.tag=="v1.0.1") | .status' "OK" "${out}"
assert_jq_eq "T69: historical audit JSON drifting tag is DRIFT" '.releases[] | select(.tag=="v1.0.0") | .status' "DRIFT" "${out}"
assert_jq_eq "T69: historical audit JSON nested drifting verification failed" '.releases[] | select(.tag=="v1.0.0") | .verification.result' "fail" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 70: top-level distribution readiness emits machine-readable JSON\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag "v1.0.0")
origin_dir="$(mktemp -d -t release-distribution-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
gh_stub_dir="$(mk_gh_stub)"
release_asset_root="${repo}/release-assets"
release_name_file="${repo}/published-release-name.txt"
release_body_file="${repo}/published-release-body.txt"
release_list_file="${repo}/release-tags.txt"
workflow_list_file="${repo}/workflow-list.tsv"
run_registry_file="${repo}/run-registry.tsv"
attested_tags_file="${repo}/attested-tags.txt"
dispatch_sha_dir="${repo}/dispatch-shas"
mkdir -p "${release_asset_root}/v1.0.0" "${dispatch_sha_dir}"
(cd "${repo}" && bash tools/build-release-assets.sh "1.0.0" --out-dir "${release_asset_root}/v1.0.0" >/dev/null)
tag_sha_v100="$(git -C "${repo}" rev-parse "v1.0.0^{commit}")"
printf '%s' "$(cd "${repo}" && bash tools/render-release-title.sh "1.0.0")" > "${release_name_file}"
printf '%s' "$(cd "${repo}" && bash tools/render-release-notes.sh "1.0.0" --sha "${tag_sha_v100}")" > "${release_body_file}"
printf 'v1.0.0\n' > "${release_list_file}"
printf 'attest-release-assets.yml\tactive\t1001\t.github/workflows/attest-release-assets.yml\n' > "${workflow_list_file}"
printf '%s' "${tag_sha_v100}" > "${dispatch_sha_dir}/v1.0.0.txt"
: > "${run_registry_file}"
set +e
out="$(cd "${repo}" && GH_STUB_RELEASE_ASSET_ROOT="${release_asset_root}" GH_STUB_RELEASE_NAME_FILE="${release_name_file}" GH_STUB_RELEASE_BODY_FILE="${release_body_file}" GH_STUB_RELEASE_LIST_TAGS_FILE="${release_list_file}" GH_STUB_WORKFLOW_LIST_FILE="${workflow_list_file}" GH_STUB_RUN_REGISTRY_FILE="${run_registry_file}" GH_STUB_ATTESTED_TAGS_FILE="${attested_tags_file}" GH_STUB_WORKFLOW_DISPATCH_SHA_DIR="${dispatch_sha_dir}" GH_STUB_REPO_NAME_WITH_OWNER="example/fixture" PATH="${gh_stub_dir}:${PATH}" bash tools/verify-distribution-readiness.sh --fetch --repo example/fixture --release-version 1.0.0 --history-limit 1 --current-attestations wait --history-attestations skip --trigger-attestations-if-missing --attestation-poll-attempts 1 --attestation-poll-interval 1 --json 2>&1)"
rc=$?
set -e
assert_eq "T70: distribution readiness JSON exits 0 on selective-wait green state" "0" "${rc}"
assert_jq_eq "T70: distribution readiness JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T70: distribution readiness JSON ok count" '.counts.ok' "4" "${out}"
assert_jq_eq "T70: distribution readiness JSON fail count" '.counts.fail' "0" "${out}"
assert_jq_eq "T70: distribution readiness JSON deployment-candidate surface is OK" '.surfaces[] | select(.name=="deployment_candidate") | .status' "OK" "${out}"
assert_jq_eq "T70: distribution readiness JSON nested deployment-candidate status is CURRENT" '.surfaces[] | select(.name=="deployment_candidate") | .details.candidate_status' "CURRENT" "${out}"
assert_jq_eq "T70: distribution readiness JSON current-release surface is OK" '.surfaces[] | select(.name=="current_release") | .status' "OK" "${out}"
assert_jq_eq "T70: distribution readiness JSON nested current-release mode is wait" '.surfaces[] | select(.name=="current_release") | .details.attestations_mode' "wait" "${out}"
assert_jq_eq "T70: distribution readiness JSON nested history mode stays skip" '.surfaces[] | select(.name=="history") | .details.attestations_mode' "skip" "${out}"
assert_jq_eq "T70: distribution readiness JSON nested current-release message mentions attestation wait" '.surfaces[] | select(.name=="current_release") | .details.message' "verify-published-release: published release is canonical for example/fixture v1.0.0 after attestation wait" "${out}"
assert_true "T70: distribution readiness JSON selective wait dispatches a workflow run" "[[ -s '${run_registry_file}' ]]"
assert_contains "T70: distribution readiness JSON selective wait marks tag attested" "v1.0.0" "$(cat "${attested_tags_file}")"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 71: deployment verifier default surface includes the manifest, workflows, and self-audit tools\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --json 2>&1)"
rc=$?
set -e
assert_eq "T71: default deployment JSON exits 0 when all canonical surfaces are deployed" "0" "${rc}"
assert_jq_eq "T71: default deployment JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T71: default deployment JSON validate workflow is included" '.items[] | select(.path==".github/workflows/validate.yml") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON local-ci helper is included" '.items[] | select(.path=="tools/local-ci.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON CI-pin helper is included" '.items[] | select(.path=="tools/list-ci-pinned-tests.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON manifest helper is included" '.items[] | select(.path=="tools/list-release-automation-surfaces.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON staging helper is included" '.items[] | select(.path=="tools/stage-release-automation-surfaces.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON deployment-candidate helper is included" '.items[] | select(.path=="tools/prepare-release-automation-deployment.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON self-audit deployment verifier is included" '.items[] | select(.path=="tools/verify-release-automation-deployment.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON top-level readiness verifier is included" '.items[] | select(.path=="tools/verify-distribution-readiness.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON professional readiness verifier is included" '.items[] | select(.path=="tools/verify-professional-readiness.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON install readiness verifier is included" '.items[] | select(.path=="tools/verify-install-readiness.sh") | .status' "MATCH" "${out}"
assert_jq_eq "T71: default deployment JSON project readiness verifier is included" '.items[] | select(.path=="tools/verify-project-readiness.sh") | .status' "MATCH" "${out}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 72: staging helper dry-run and live mode stage the canonical manifest subset\n'
repo="$(mk_release_fixture)"
printf '\n# drift\n' >> "${repo}/tools/release.sh"
printf '\n# drift\n' >> "${repo}/.github/workflows/validate.yml"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --dry-run --path tools/release.sh --path .github/workflows/validate.yml 2>&1)"
rc=$?
set -e
assert_eq "T72: staging helper dry-run exits 0" "0" "${rc}"
assert_contains "T72: staging helper dry-run reports release.sh would stage" $'WOULD_STAGE\t M tools/release.sh\ttools/release.sh' "${out}"
assert_contains "T72: staging helper dry-run reports validate.yml would stage" $'WOULD_STAGE\t M .github/workflows/validate.yml\t.github/workflows/validate.yml' "${out}"
assert_contains "T72: staging helper dry-run summary counts actionable paths" "summary: 2 selected, 0 clean, 2 would-stage, 0 missing_local, 0 extra_staged, 0 dirty_unselected_manifest" "${out}"
assert_true "T72: staging helper dry-run leaves index untouched" "[[ -z \"\$(git -C \"${repo}\" diff --cached --name-only)\" ]]"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --path tools/release.sh --path .github/workflows/validate.yml 2>&1)"
rc=$?
set -e
assert_eq "T72: staging helper live mode exits 0" "0" "${rc}"
assert_contains "T72: staging helper live mode stages release.sh" $'STAGED\t M tools/release.sh\ttools/release.sh' "${out}"
assert_contains "T72: staging helper live mode stages validate.yml" $'STAGED\t M .github/workflows/validate.yml\t.github/workflows/validate.yml' "${out}"
assert_contains "T72: staging helper live mode summary counts staged paths" "summary: 2 selected, 0 clean, 2 staged, 0 missing_local, 0 extra_staged, 0 dirty_unselected_manifest" "${out}"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_contains "T72: staging helper live mode stages release.sh in index" "tools/release.sh" "${cached}"
assert_contains "T72: staging helper live mode stages validate.yml in index" ".github/workflows/validate.yml" "${cached}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 73: staging helper rejects non-manifest paths and emits machine-readable JSON\n'
repo="$(mk_release_fixture)"
printf '\n# drift\n' >> "${repo}/tools/release.sh"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --dry-run --path tools/release.sh --json 2>&1)"
rc=$?
set -e
assert_eq "T73: staging helper JSON dry-run exits 0" "0" "${rc}"
assert_jq_eq "T73: staging helper JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T73: staging helper JSON dry_run true" '.dry_run' "true" "${out}"
assert_jq_eq "T73: staging helper JSON selected count" '.counts.selected' "1" "${out}"
assert_jq_eq "T73: staging helper JSON staged count counts would-stage paths" '.counts.staged' "1" "${out}"
assert_jq_eq "T73: staging helper JSON item action is WOULD_STAGE" '.items[] | select(.path=="tools/release.sh") | .action' "WOULD_STAGE" "${out}"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --path README.md 2>&1)"
rc=$?
set -e
assert_eq "T73: staging helper rejects non-manifest paths with exit 1" "1" "${rc}"
assert_contains "T73: staging helper rejection names manifest contract" "path is not in canonical release-automation surface manifest: README.md" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 74: deployment verifier can compare the staged index independently of the dirty worktree\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
printf '\n# staged drift\n' >> "${repo}/tools/release.sh"
printf '\n# unstaged drift\n' >> "${repo}/.github/workflows/validate.yml"
(cd "${repo}" && git add tools/release.sh)
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --local-ref INDEX --path tools/release.sh --path .github/workflows/validate.yml --json 2>&1)"
rc=$?
set -e
assert_eq "T74: INDEX-mode deployment verifier exits non-zero on staged-only drift" "1" "${rc}"
assert_jq_eq "T74: INDEX-mode JSON result is fail" '.result' "fail" "${out}"
assert_jq_eq "T74: INDEX-mode JSON local_ref reports INDEX" '.local_ref' "INDEX" "${out}"
assert_jq_eq "T74: INDEX-mode JSON tracked staged path drifts" '.items[] | select(.path=="tools/release.sh") | .status' "DRIFT" "${out}"
assert_jq_eq "T74: INDEX-mode JSON unstaged path still matches remote" '.items[] | select(.path==".github/workflows/validate.yml") | .status' "MATCH" "${out}"
assert_jq_eq "T74: INDEX-mode JSON counts exactly one drift" '.counts.drift' "1" "${out}"
assert_jq_eq "T74: INDEX-mode JSON counts exactly one match" '.counts.match' "1" "${out}"
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --path tools/release.sh --path .github/workflows/validate.yml 2>&1)"
rc=$?
set -e
assert_eq "T74: WORKTREE deployment verifier still sees both dirty paths" "1" "${rc}"
assert_contains "T74: WORKTREE verifier reports release tool drift" $'DRIFT\ttools/release.sh' "${out}"
assert_contains "T74: WORKTREE verifier reports unstaged validate workflow drift" $'DRIFT\t.github/workflows/validate.yml' "${out}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 75: staging helper fails closed on unrelated staged files unless explicitly allowed\n'
repo="$(mk_release_fixture)"
printf '\n# manifest drift\n' >> "${repo}/tools/release.sh"
printf '\nextra staged file\n' >> "${repo}/README.md"
(cd "${repo}" && git add README.md)
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --path tools/release.sh 2>&1)"
rc=$?
set -e
assert_eq "T75: staging helper fails when unrelated files are already staged" "1" "${rc}"
assert_contains "T75: staging helper reports selected path would stage under block" $'WOULD_STAGE\t M tools/release.sh\ttools/release.sh' "${out}"
assert_contains "T75: staging helper reports unrelated staged README" $'EXTRA_STAGED\tcached\tREADME.md' "${out}"
assert_contains "T75: staging helper explains fail-closed extra-staged block" 'refusing to stage while unrelated staged paths are present' "${out}"
assert_contains "T75: staging helper suggests allow-extra-staged escape hatch" '--allow-extra-staged' "${out}"
assert_contains "T75: staging helper summary counts extra staged paths" "summary: 1 selected, 0 clean, 1 would-stage, 0 missing_local, 1 extra_staged, 0 dirty_unselected_manifest" "${out}"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_contains "T75: blocked staging leaves pre-staged README intact" "README.md" "${cached}"
assert_not_contains "T75: blocked staging does not stage manifest path" "tools/release.sh" "${cached}"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --allow-extra-staged --path tools/release.sh --json 2>&1)"
rc=$?
set -e
assert_eq "T75: allow-extra-staged JSON exits 0" "0" "${rc}"
assert_jq_eq "T75: allow-extra-staged JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T75: allow-extra-staged JSON flag is true" '.allow_extra_staged' "true" "${out}"
assert_jq_eq "T75: allow-extra-staged JSON extra staged count preserved" '.counts.extra_staged' "1" "${out}"
assert_jq_eq "T75: allow-extra-staged JSON names README extra staged path" '.extra_staged_paths[]' "README.md" "${out}"
assert_jq_eq "T75: allow-extra-staged JSON stages selected manifest path" '.items[] | select(.path=="tools/release.sh") | .action' "STAGED" "${out}"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_contains "T75: allow-extra-staged stages manifest path in index" "tools/release.sh" "${cached}"
assert_contains "T75: allow-extra-staged keeps README staged in index" "README.md" "${cached}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 76: INDEX/STAGED deployment verifier fails closed on unrelated staged non-manifest files unless explicitly allowed\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
printf '\n# unrelated staged drift\n' >> "${repo}/README.md"
(cd "${repo}" && git add README.md)
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --local-ref INDEX --path tools/release.sh --json 2>&1)"
rc=$?
set -e
assert_eq "T76: INDEX-mode verifier fails when unrelated staged non-manifest files exist" "1" "${rc}"
assert_jq_eq "T76: INDEX-mode JSON result is fail on extra staged non-manifest" '.result' "fail" "${out}"
assert_jq_eq "T76: INDEX-mode JSON extra staged non-manifest count" '.counts.extra_staged_non_manifest' "1" "${out}"
assert_jq_eq "T76: INDEX-mode JSON names README extra staged non-manifest path" '.extra_staged_non_manifest_paths[]' "README.md" "${out}"
assert_jq_eq "T76: INDEX-mode JSON emits explicit extra staged non-manifest item" '.items[] | select(.path=="README.md") | .status' "EXTRA_STAGED_NON_MANIFEST" "${out}"
assert_jq_eq "T76: INDEX-mode JSON remediation mentions allow-extra-staged override" '.remediation[0]' "clear unrelated staged non-manifest paths before trusting INDEX/STAGED deployment proof, or rerun with --allow-extra-staged if the wider staged set is intentional" "${out}"
assert_jq_eq "T76: INDEX-mode JSON selected manifest path still matches remote" '.items[] | select(.path=="tools/release.sh") | .status' "MATCH" "${out}"
set +e
out="$(cd "${repo}" && bash tools/verify-release-automation-deployment.sh --fetch --local-ref INDEX --allow-extra-staged --path tools/release.sh --json 2>&1)"
rc=$?
set -e
assert_eq "T76: INDEX-mode verifier allow-extra-staged exits 0" "0" "${rc}"
assert_jq_eq "T76: INDEX-mode allow-extra-staged JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T76: INDEX-mode allow-extra-staged JSON flag is true" '.allow_extra_staged' "true" "${out}"
assert_jq_eq "T76: INDEX-mode allow-extra-staged keeps extra staged count" '.counts.extra_staged_non_manifest' "1" "${out}"
assert_jq_eq "T76: INDEX-mode allow-extra-staged still names README extra path" '.extra_staged_non_manifest_paths[]' "README.md" "${out}"
assert_jq_eq "T76: INDEX-mode allow-extra-staged keeps selected manifest path matched" '.items[] | select(.path=="tools/release.sh") | .status' "MATCH" "${out}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 77: top-level distribution readiness passes through allow-extra-staged for staged-index deployment audits\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-distribution-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
gh_stub_dir="$(mk_gh_stub)"
printf '\n# unrelated staged drift\n' >> "${repo}/README.md"
(cd "${repo}" && git add README.md)
set +e
out="$(cd "${repo}" && PATH="${gh_stub_dir}:${PATH}" bash tools/verify-distribution-readiness.sh --fetch --repo example/fixture --skip-current-release --skip-history --local-ref INDEX --json 2>&1)"
rc=$?
set -e
assert_eq "T77: top-level readiness fails when staged-index deployment audit sees unrelated staged non-manifest files" "1" "${rc}"
assert_jq_eq "T77: top-level readiness JSON result is fail without allow-extra-staged" '.result' "fail" "${out}"
assert_jq_eq "T77: top-level readiness JSON top-level allow_extra_staged defaults false" '.allow_extra_staged' "false" "${out}"
assert_jq_eq "T77: top-level readiness JSON deployment surface fails" '.surfaces[] | select(.name=="deployment") | .status' "FAIL" "${out}"
assert_jq_eq "T77: top-level readiness JSON nested deployment sees extra staged non-manifest count" '.surfaces[] | select(.name=="deployment") | .details.counts.extra_staged_non_manifest' "1" "${out}"
assert_jq_eq "T77: top-level readiness JSON nested deployment names README extra path" '.surfaces[] | select(.name=="deployment") | .details.extra_staged_non_manifest_paths[]' "README.md" "${out}"
assert_jq_eq "T77: top-level readiness JSON skip count reflects skipped release surfaces" '.counts.skip' "2" "${out}"
set +e
out="$(cd "${repo}" && PATH="${gh_stub_dir}:${PATH}" bash tools/verify-distribution-readiness.sh --fetch --repo example/fixture --skip-current-release --skip-history --local-ref INDEX --allow-extra-staged --json 2>&1)"
rc=$?
set -e
assert_eq "T77: top-level readiness allow-extra-staged exits 0" "0" "${rc}"
assert_jq_eq "T77: top-level readiness JSON result is ok with allow-extra-staged" '.result' "ok" "${out}"
assert_jq_eq "T77: top-level readiness JSON top-level allow_extra_staged reports true" '.allow_extra_staged' "true" "${out}"
assert_jq_eq "T77: top-level readiness JSON deployment surface becomes OK" '.surfaces[] | select(.name=="deployment") | .status' "OK" "${out}"
assert_jq_eq "T77: top-level readiness JSON deployment-candidate surface becomes OK" '.surfaces[] | select(.name=="deployment_candidate") | .status' "OK" "${out}"
assert_jq_eq "T77: top-level readiness JSON nested deployment allow_extra_staged reports true" '.surfaces[] | select(.name=="deployment") | .details.allow_extra_staged' "true" "${out}"
assert_jq_eq "T77: top-level readiness JSON nested deployment keeps extra staged non-manifest count" '.surfaces[] | select(.name=="deployment") | .details.counts.extra_staged_non_manifest' "1" "${out}"
assert_jq_eq "T77: top-level readiness JSON nested deployment still names README extra path" '.surfaces[] | select(.name=="deployment") | .details.extra_staged_non_manifest_paths[]' "README.md" "${out}"
assert_jq_eq "T77: top-level readiness JSON ok count reflects deployment plus candidate success" '.counts.ok' "2" "${out}"
assert_jq_eq "T77: top-level readiness JSON skip count remains 2" '.counts.skip' "2" "${out}"
cleanup_gh_stub "${gh_stub_dir}"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 78: staging helper fails closed on dirty unselected manifest paths unless explicitly allowed\n'
repo="$(mk_release_fixture)"
printf '\n# selected manifest drift\n' >> "${repo}/tools/release.sh"
printf '\n# unselected manifest drift\n' >> "${repo}/.github/workflows/validate.yml"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --path tools/release.sh 2>&1)"
rc=$?
set -e
assert_eq "T78: staging helper fails when narrowed selection leaves dirty manifest paths outside the subset" "1" "${rc}"
assert_contains "T78: staging helper reports selected path would stage under partial-manifest block" $'WOULD_STAGE\t M tools/release.sh\ttools/release.sh' "${out}"
assert_contains "T78: staging helper reports dirty unselected manifest path" $'DIRTY_UNSELECTED_MANIFEST\t M .github/workflows/validate.yml\t.github/workflows/validate.yml' "${out}"
assert_contains "T78: staging helper explains fail-closed partial-manifest block" 'refusing to stage a narrowed manifest subset while other manifest paths are dirty' "${out}"
assert_contains "T78: staging helper suggests allow-partial-manifest escape hatch" '--allow-partial-manifest' "${out}"
assert_contains "T78: staging helper summary counts dirty unselected manifest paths" "summary: 1 selected, 0 clean, 1 would-stage, 0 missing_local, 0 extra_staged, 1 dirty_unselected_manifest" "${out}"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_not_contains "T78: blocked staging does not stage selected manifest path" "tools/release.sh" "${cached}"
assert_not_contains "T78: blocked staging does not stage dirty unselected manifest path" ".github/workflows/validate.yml" "${cached}"
set +e
out="$(cd "${repo}" && bash tools/stage-release-automation-surfaces.sh --allow-partial-manifest --path tools/release.sh --json 2>&1)"
rc=$?
set -e
assert_eq "T78: allow-partial-manifest JSON exits 0" "0" "${rc}"
assert_jq_eq "T78: allow-partial-manifest JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T78: allow-partial-manifest JSON flag is true" '.allow_partial_manifest' "true" "${out}"
assert_jq_eq "T78: allow-partial-manifest JSON dirty-unselected-manifest count preserved" '.counts.dirty_unselected_manifest' "1" "${out}"
assert_jq_eq "T78: allow-partial-manifest JSON names dirty unselected manifest path" '.dirty_unselected_manifest_paths[]' ".github/workflows/validate.yml" "${out}"
assert_jq_eq "T78: allow-partial-manifest JSON selected manifest path stages" '.items[] | select(.path=="tools/release.sh") | .action' "STAGED" "${out}"
assert_jq_eq "T78: allow-partial-manifest JSON unselected dirty manifest item is explicit" '.items[] | select(.path==".github/workflows/validate.yml") | .action' "DIRTY_UNSELECTED_MANIFEST" "${out}"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_contains "T78: allow-partial-manifest stages selected manifest path in index" "tools/release.sh" "${cached}"
assert_not_contains "T78: allow-partial-manifest leaves unselected dirty manifest path unstaged" ".github/workflows/validate.yml" "${cached}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 79: deployment-candidate helper dry-run succeeds on a coherent pre-push subset\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
printf '\n# drift\n' >> "${repo}/tools/release.sh"
printf '\n# drift\n' >> "${repo}/.github/workflows/validate.yml"
set +e
out="$(cd "${repo}" && bash tools/prepare-release-automation-deployment.sh --dry-run --fetch --path tools/release.sh --path .github/workflows/validate.yml --json 2>&1)"
rc=$?
set -e
assert_eq "T79: deployment-candidate dry-run exits 0" "0" "${rc}"
assert_jq_eq "T79: deployment-candidate dry-run JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run status is ready-to-commit" '.candidate_status' "READY_TO_COMMIT" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run local ref is WORKTREE" '.candidate_local_ref' "WORKTREE" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run stage stays dry-run" '.stage.dry_run' "true" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run pending remote count is 2" '.counts.pending_remote' "2" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run deployment local ref is WORKTREE" '.deployment.local_ref' "WORKTREE" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run deployable release.sh drift is explicit" '.deployable_paths[] | select(.path=="tools/release.sh") | .status' "DRIFT" "${out}"
assert_jq_eq "T79: deployment-candidate dry-run deployable validate drift is explicit" '.deployable_paths[] | select(.path==".github/workflows/validate.yml") | .status' "DRIFT" "${out}"
assert_contains "T79: deployment-candidate dry-run message tells maintainer to rerun live" 'rerun without --dry-run to stage' "$(printf '%s' "${out}" | jq -r '.message')"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 80: deployment-candidate helper live mode stages and audits a coherent candidate\n'
repo="$(mk_release_fixture)"
origin_dir="$(mktemp -d -t release-deploy-origin-XXXXXX)"
origin_repo="${origin_dir}/origin.git"
git init -q --bare "${origin_repo}"
(cd "${repo}" && git remote add origin "${origin_repo}" && git push -q -u origin main && git remote set-head origin --auto >/dev/null 2>&1 || true)
printf '\n# drift\n' >> "${repo}/tools/release.sh"
printf '\n# drift\n' >> "${repo}/.github/workflows/validate.yml"
set +e
out="$(cd "${repo}" && bash tools/prepare-release-automation-deployment.sh --fetch --path tools/release.sh --path .github/workflows/validate.yml --json 2>&1)"
rc=$?
set -e
assert_eq "T80: deployment-candidate live exits 0" "0" "${rc}"
assert_jq_eq "T80: deployment-candidate live JSON result is ok" '.result' "ok" "${out}"
assert_jq_eq "T80: deployment-candidate live status is ready-to-commit" '.candidate_status' "READY_TO_COMMIT" "${out}"
assert_jq_eq "T80: deployment-candidate live local ref is INDEX" '.candidate_local_ref' "INDEX" "${out}"
assert_jq_eq "T80: deployment-candidate live stage is not dry-run" '.stage.dry_run' "false" "${out}"
assert_jq_eq "T80: deployment-candidate live deployment local ref is INDEX" '.deployment.local_ref' "INDEX" "${out}"
assert_jq_eq "T80: deployment-candidate live pending remote count is 2" '.counts.pending_remote' "2" "${out}"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_contains "T80: deployment-candidate live stages release.sh" "tools/release.sh" "${cached}"
assert_contains "T80: deployment-candidate live stages validate workflow" ".github/workflows/validate.yml" "${cached}"
assert_contains "T80: deployment-candidate live message tells maintainer to commit/push" 'commit/push the candidate' "$(printf '%s' "${out}" | jq -r '.message')"
cleanup_fixture "${repo}"
rm -rf "${origin_dir}"

# ---------------------------------------------------------------------
printf 'Test 81: deployment-candidate helper fails when narrowed selection leaves dirty manifest paths outside the subset\n'
repo="$(mk_release_fixture)"
printf '\n# selected drift\n' >> "${repo}/tools/release.sh"
printf '\n# unselected drift\n' >> "${repo}/.github/workflows/validate.yml"
set +e
out="$(cd "${repo}" && bash tools/prepare-release-automation-deployment.sh --path tools/release.sh --json 2>&1)"
rc=$?
set -e
assert_eq "T81: deployment-candidate blocked partial-manifest exits non-zero" "1" "${rc}"
assert_jq_eq "T81: deployment-candidate blocked partial-manifest JSON result is fail" '.result' "fail" "${out}"
assert_jq_eq "T81: deployment-candidate blocked status is blocked" '.candidate_status' "BLOCKED" "${out}"
assert_jq_eq "T81: deployment-candidate blocked stage result is fail" '.stage.result' "fail" "${out}"
assert_jq_eq "T81: deployment-candidate blocked skips deployment details" '.deployment' "null" "${out}"
assert_jq_eq "T81: deployment-candidate blocked dirty-unselected-manifest count is preserved" '.counts.dirty_unselected_manifest' "1" "${out}"
assert_contains "T81: deployment-candidate blocked remediation mentions allow-partial-manifest" '--allow-partial-manifest' "$(printf '%s' "${out}" | jq -r '.remediation[]')"
cached="$(git -C "${repo}" diff --cached --name-only)"
assert_not_contains "T81: blocked deployment-candidate does not stage release.sh" "tools/release.sh" "${cached}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf '\n=== release tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
