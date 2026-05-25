#!/usr/bin/env bash
#
# tools/audit-published-releases.sh — batch-audit published GitHub
# releases end to end against the canonical title/body/state/assets/
# attestation contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY_HELPER="${SCRIPT_DIR}/verify-published-release.sh"

REPO_OVERRIDE=""
LIMIT=100
FIX=0
TAG_LIST=()
ATTESTATIONS_MODE="verify"
TRIGGER_ATTESTATIONS_IF_MISSING=0
ATTESTATION_POLL_ATTEMPTS=""
ATTESTATION_POLL_INTERVAL=""
ATTESTATION_RUN_LIMIT=""
JSON_MODE=0

usage() {
  cat <<'EOF'
Usage: bash tools/audit-published-releases.sh [options]

Audits published GitHub releases in batch by calling
tools/verify-published-release.sh for each selected tag.

Options:
  --repo <owner/name>               Override the GitHub repo slug. Defaults
                                    to the current gh repo.
  --limit <N>                       Number of published releases to inspect
                                    when no explicit --tag filters are
                                    provided. Default: 100.
  --tag <vX.Y.Z>                    Audit a specific published release tag.
                                    Repeatable.
  --fix                             Repair title/body/state/assets drift in
                                    place before re-verifying them.
  --attestations <skip|verify|wait> Passed through to
                                    tools/verify-published-release.sh.
                                    Default: verify.
  --trigger-attestations-if-missing Only valid with --attestations wait.
                                    Dispatch the attestation workflow if no
                                    matching run is registered yet.
  --attestation-poll-attempts <N>   Only valid with --attestations wait.
                                    Passed through to the waiter helper.
  --attestation-poll-interval <N>   Only valid with --attestations wait.
                                    Passed through to the waiter helper.
  --attestation-run-limit <N>       Only valid with --attestations wait.
                                    Passed through to the waiter helper.
  --json                            Emit a machine-readable JSON report
                                    instead of the human text summary.
EOF
}

err() { printf 'audit-published-releases: %s\n' "$1" >&2; exit 1; }
note() { printf 'audit-published-releases: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      LIMIT="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      TAG_LIST+=("$2")
      shift 2
      ;;
    --fix)
      FIX=1
      shift
      ;;
    --attestations)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATIONS_MODE="$2"
      shift 2
      ;;
    --trigger-attestations-if-missing)
      TRIGGER_ATTESTATIONS_IF_MISSING=1
      shift
      ;;
    --attestation-poll-attempts)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATION_POLL_ATTEMPTS="$2"
      shift 2
      ;;
    --attestation-poll-interval)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATION_POLL_INTERVAL="$2"
      shift 2
      ;;
    --attestation-run-limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ATTESTATION_RUN_LIMIT="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'audit-published-releases: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'audit-published-releases: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "${LIMIT}" =~ ^[1-9][0-9]*$ ]] || err "--limit must be a positive integer, got: ${LIMIT}"
case "${ATTESTATIONS_MODE}" in
  skip|verify|wait) ;;
  *) err "--attestations must be one of: skip, verify, wait (got: ${ATTESTATIONS_MODE})" ;;
esac
if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 && "${ATTESTATIONS_MODE}" != "wait" ]]; then
  err "--trigger-attestations-if-missing requires --attestations wait"
fi
for waiter_opt in \
  "--attestation-poll-attempts:${ATTESTATION_POLL_ATTEMPTS}" \
  "--attestation-poll-interval:${ATTESTATION_POLL_INTERVAL}" \
  "--attestation-run-limit:${ATTESTATION_RUN_LIMIT}"; do
  cli_name="${waiter_opt%%:*}"
  opt_value="${waiter_opt#*:}"
  if [[ -n "${opt_value}" ]]; then
    [[ "${ATTESTATIONS_MODE}" == "wait" ]] || err "${cli_name} requires --attestations wait"
    [[ "${opt_value}" =~ ^[1-9][0-9]*$ ]] || err "${cli_name} must be a positive integer, got: ${opt_value}"
  fi
done

command -v gh >/dev/null 2>&1 || err "gh CLI not found in PATH"
if [[ "${JSON_MODE}" -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || err "jq is required for --json"
fi
[[ -x "${VERIFY_HELPER}" ]] || err "verify helper missing: ${VERIFY_HELPER}"

REPO_SLUG="${REPO_OVERRIDE:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
[[ -n "${REPO_SLUG}" ]] || err "could not resolve repo slug (pass --repo <owner/name>)"

if [[ "${#TAG_LIST[@]}" -eq 0 ]]; then
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] && TAG_LIST+=("${tag}")
  done < <(gh release list --repo "${REPO_SLUG}" --limit "${LIMIT}" --json tagName --jq '.[].tagName')
fi

[[ "${#TAG_LIST[@]}" -gt 0 ]] || err "no published release tags found for ${REPO_SLUG}"

pass_count=0
fixed_count=0
fail_count=0
tmp_dir=""
releases_file=""

if [[ "${JSON_MODE}" -eq 1 ]]; then
  tmp_dir="$(mktemp -d -t omc-published-release-audit-XXXXXX)"
  releases_file="${tmp_dir}/releases.jsonl"
  cleanup() { rm -rf "${tmp_dir}"; }
  trap cleanup EXIT
fi

for tag in "${TAG_LIST[@]}"; do
  [[ -z "${tag}" ]] && continue
  version="${tag#v}"
  verify_args=("${version}" "--repo" "${REPO_SLUG}" "--attestations" "${ATTESTATIONS_MODE}")
  if [[ "${FIX}" -eq 1 ]]; then
    verify_args+=("--fix")
  fi
  if [[ "${TRIGGER_ATTESTATIONS_IF_MISSING}" -eq 1 ]]; then
    verify_args+=("--trigger-attestations-if-missing")
  fi
  if [[ -n "${ATTESTATION_POLL_ATTEMPTS}" ]]; then
    verify_args+=("--attestation-poll-attempts" "${ATTESTATION_POLL_ATTEMPTS}")
  fi
  if [[ -n "${ATTESTATION_POLL_INTERVAL}" ]]; then
    verify_args+=("--attestation-poll-interval" "${ATTESTATION_POLL_INTERVAL}")
  fi
  if [[ -n "${ATTESTATION_RUN_LIMIT}" ]]; then
    verify_args+=("--attestation-run-limit" "${ATTESTATION_RUN_LIMIT}")
  fi
  if [[ "${JSON_MODE}" -eq 1 ]]; then
    verify_args+=("--json")
  fi

  if out="$(bash "${VERIFY_HELPER}" "${verify_args[@]}" 2>&1)"; then
    if [[ "${JSON_MODE}" -eq 1 ]]; then
      summary_line="$(printf '%s' "${out}" | jq -r '.summary_text')"
      fixed_this="$(printf '%s' "${out}" | jq -r '.counts.fixed')"
    else
      summary_line="$(printf '%s\n' "${out}" | grep -F 'verify-published-release: summary:' | tail -1 || true)"
      [[ -n "${summary_line}" ]] || summary_line="$(printf '%s\n' "${out}" | tail -1)"
      if printf '%s\n' "${out}" | grep -q $'^FIXED\t'; then
        fixed_this="1"
      else
        fixed_this="0"
      fi
    fi
    if [[ "${fixed_this}" != "0" ]]; then
      if [[ "${JSON_MODE}" -eq 0 ]]; then
        printf 'FIXED\t%s\t%s\n' "${tag}" "${summary_line}"
      else
        jq -nc \
          --arg tag "${tag}" \
          --arg version "${version}" \
          --arg status "FIXED" \
          --arg summary "${summary_line}" \
          --argjson verification "${out}" \
          '{tag: $tag, version: $version, status: $status, summary: $summary, verification: $verification}' >> "${releases_file}"
      fi
      fixed_count=$((fixed_count + 1))
    else
      if [[ "${JSON_MODE}" -eq 0 ]]; then
        printf 'OK\t%s\t%s\n' "${tag}" "${summary_line}"
      else
        jq -nc \
          --arg tag "${tag}" \
          --arg version "${version}" \
          --arg status "OK" \
          --arg summary "${summary_line}" \
          --argjson verification "${out}" \
          '{tag: $tag, version: $version, status: $status, summary: $summary, verification: $verification}' >> "${releases_file}"
      fi
      pass_count=$((pass_count + 1))
    fi
  else
    if [[ "${JSON_MODE}" -eq 1 ]]; then
      summary_line="$(printf '%s' "${out}" | jq -r '.summary_text')"
      jq -nc \
        --arg tag "${tag}" \
        --arg version "${version}" \
        --arg status "DRIFT" \
        --arg summary "${summary_line}" \
        --argjson verification "${out}" \
        '{tag: $tag, version: $version, status: $status, summary: $summary, verification: $verification}' >> "${releases_file}"
    else
      summary_line="$(printf '%s\n' "${out}" | grep -F 'verify-published-release: summary:' | tail -1 || true)"
      [[ -n "${summary_line}" ]] || summary_line="$(printf '%s\n' "${out}" | head -1)"
      printf 'DRIFT\t%s\t%s\n' "${tag}" "${summary_line}"
    fi
    fail_count=$((fail_count + 1))
  fi
done

summary_text="audit-published-releases: summary: ${pass_count} OK, ${fixed_count} FIXED, ${fail_count} FAIL"
if [[ "${JSON_MODE}" -eq 1 ]]; then
  selected_tags_json="$(printf '%s\n' "${TAG_LIST[@]}" | jq -R . | jq -s .)"
  jq -n \
    --arg repo "${REPO_SLUG}" \
    --arg attestations_mode "${ATTESTATIONS_MODE}" \
    --arg summary_text "${summary_text}" \
    --argjson limit "${LIMIT}" \
    --argjson fix "$( [[ "${FIX}" -eq 1 ]] && printf 'true' || printf 'false' )" \
    --argjson selected_tags "${selected_tags_json}" \
    --argjson pass_count "${pass_count}" \
    --argjson fixed_count "${fixed_count}" \
    --argjson fail_count "${fail_count}" \
    --slurpfile releases "${releases_file}" \
    '{
      tool: "audit-published-releases",
      repo: $repo,
      limit: $limit,
      fix: $fix,
      attestations_mode: $attestations_mode,
      selected_tags: $selected_tags,
      result: (if $fail_count == 0 then "ok" else "fail" end),
      counts: {
        ok: $pass_count,
        fixed: $fixed_count,
        fail: $fail_count
      },
      summary_text: $summary_text,
      releases: $releases
    }'
  [[ "${fail_count}" -eq 0 ]]
  exit $?
fi

note "summary: ${pass_count} OK, ${fixed_count} FIXED, ${fail_count} FAIL"
[[ "${fail_count}" -eq 0 ]]
