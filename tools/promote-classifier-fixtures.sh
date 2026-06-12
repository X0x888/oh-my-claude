#!/usr/bin/env bash
# tools/promote-classifier-fixtures.sh — one-command promotion of
# /ulw-correct fixture candidates into the repo's classifier regression
# corpus (v1.47 data-lens #3: the misfire→fixture loop's last manual hop).
#
# /ulw-correct records every user-labeled classification correction as a
# promotion-shaped row in ~/.claude/quality-pack/classifier_fixture_candidates.jsonl
# ({prompt_preview, intent, domain, note, _source, _session_id, _ts}).
# Pre-v1.47 the closing step was a hand-rolled cat|jq dance documented in
# /ulw-report prose. This helper makes it one command:
#
#   bash tools/promote-classifier-fixtures.sh            # dry-run preview
#   bash tools/promote-classifier-fixtures.sh --apply    # append to corpus
#   bash tools/promote-classifier-fixtures.sh --apply --consume
#                                                        # ...and truncate the
#                                                        # candidates file
#
# Behavior:
#   - strips the _source/_session_id/_ts metadata fields
#   - dedupes against rows already in the corpus (by prompt_preview) AND
#     within the candidate set itself
#   - dry-run by default — prints what WOULD be appended; --apply writes
#   - --consume (only with --apply) truncates the candidates file so the
#     /ulw-report "ready to promote" counter resets; without it the file
#     is left intact (re-runs are idempotent thanks to the dedupe)
#
# The maintainer still vets: the dry-run output IS the vetting surface.
# Auto-applying corrections to live thresholds remains deliberately
# unbuilt (tighten-vs-loosen asymmetry must be designed first — see the
# v1.47 CHANGELOG honest-limits note).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CANDIDATES="${OMC_FIXTURE_CANDIDATES_FILE:-${HOME}/.claude/quality-pack/classifier_fixture_candidates.jsonl}"
CORPUS="${OMC_FIXTURE_CORPUS_FILE:-${REPO_ROOT}/tools/classifier-fixtures/regression.jsonl}"

APPLY=0
CONSUME=0
for arg in "$@"; do
  case "${arg}" in
    --apply) APPLY=1 ;;
    --consume) CONSUME=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'promote-classifier-fixtures: unknown argument: %s (expected --apply / --consume / --help)\n' "${arg}" >&2
      exit 2
      ;;
  esac
done

if [[ "${CONSUME}" -eq 1 && "${APPLY}" -ne 1 ]]; then
  printf 'promote-classifier-fixtures: --consume requires --apply (refusing to discard unvetted candidates).\n' >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { printf 'promote-classifier-fixtures: jq not found in PATH\n' >&2; exit 1; }

if [[ ! -f "${CANDIDATES}" ]] || [[ ! -s "${CANDIDATES}" ]]; then
  printf 'promote-classifier-fixtures: no candidates at %s — nothing to promote.\n' "${CANDIDATES}"
  exit 0
fi

[[ -f "${CORPUS}" ]] || { printf 'promote-classifier-fixtures: corpus not found: %s (run from the repo root?)\n' "${CORPUS}" >&2; exit 1; }

# Strip metadata, require complete labels, dedupe within candidates and
# against the existing corpus by prompt_preview. jq -s over both files:
# first input = corpus (existing previews), second = candidates.
new_rows="$(jq -sc \
  '(.[0] | map(.prompt_preview)) as $existing
   | .[1]
   | map(select((.prompt_preview // "") != "" and (.intent // "") != "" and (.domain // "") != ""))
   | map({prompt_preview, intent, domain, note: (.note // "promoted from /ulw-correct")})
   | unique_by(.prompt_preview)
   | map(select(.prompt_preview as $p | ($existing | index($p)) | not))
   | .[]' \
  <(jq -sc '.' "${CORPUS}") <(jq -sc '.' "${CANDIDATES}") 2>/dev/null || true)"

total_candidates="$(wc -l < "${CANDIDATES}" | tr -d '[:space:]')"
new_count="$(printf '%s' "${new_rows}" | grep -c . 2>/dev/null || true)"
new_count="${new_count:-0}"

printf 'promote-classifier-fixtures: %s candidate row(s); %s new after dedupe (vs %s).\n' \
  "${total_candidates}" "${new_count}" "${CORPUS}"

if [[ "${new_count}" -eq 0 ]]; then
  printf 'Nothing new to promote.\n'
  if [[ "${CONSUME}" -eq 1 ]]; then
    : > "${CANDIDATES}"
    printf 'Candidates file truncated (--consume).\n'
  fi
  exit 0
fi

printf -- '--- rows to append ---\n%s\n----------------------\n' "${new_rows}"

if [[ "${APPLY}" -ne 1 ]]; then
  printf 'Dry-run (vetting surface). Re-run with --apply to append; add --consume to also truncate the candidates file.\n'
  exit 0
fi

printf '%s\n' "${new_rows}" >> "${CORPUS}"
printf 'Appended %s row(s) to %s.\n' "${new_count}" "${CORPUS}"
printf 'Next: bash tools/replay-classifier-telemetry.sh to pin the corrected routing.\n'

if [[ "${CONSUME}" -eq 1 ]]; then
  : > "${CANDIDATES}"
  printf 'Candidates file truncated (--consume).\n'
fi
