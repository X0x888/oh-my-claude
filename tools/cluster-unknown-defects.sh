#!/usr/bin/env bash
# tools/cluster-unknown-defects.sh — sample the `unknown` bucket of
# `~/.claude/quality-pack/defect-patterns.json` and surface candidate
# clusters by token frequency so a human can spot missing classifier
# categories.
#
# Why this exists. The Bug B post-mortem identified "unbinned-signal-
# loss" as a structural failure: 247 defects were classified as
# `unknown` across prior sessions and dropped without review. Bug B
# itself MIGHT have appeared in that bucket as a category if anyone
# had run a clustering pass. This tool makes that pass cheap to run
# (5 seconds) and turns it into a quarterly habit instead of a
# defects-going-into-the-void status quo.
#
# Output: a markdown report listing
#   1. Total `unknown` count + last-seen timestamp
#   2. Top frequent leading words across the sample (single-token frequency)
#   3. Top frequent bigrams (likely category candidates)
#   4. File-path / module mentions clustered (when the example text
#      cites a path, that path may indicate a missing per-module category)
#   5. The full sample of N example texts, numbered, so the user can
#      eyeball them
#
# Read-only. NEVER mutates `defect-patterns.json` and NEVER edits
# `lib/classifier.sh`. Surfaces candidates; the human decides which
# clusters become new classifier categories.
#
# Usage:
#   tools/cluster-unknown-defects.sh                    # default 5 examples (per-bucket cap)
#   tools/cluster-unknown-defects.sh --sample 10        # sample 10 examples
#   tools/cluster-unknown-defects.sh --bucket security  # cluster a different bucket
#   tools/cluster-unknown-defects.sh --json             # machine-readable JSON output
#
# Exit codes:
#   0 — success
#   1 — no defect-patterns.json found
#   2 — usage error

set -euo pipefail

DEFECT_FILE="${OMC_DEFECT_PATTERNS_FILE:-${HOME}/.claude/quality-pack/defect-patterns.json}"
BUCKET="unknown"
SAMPLE_LIMIT=5
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample)
      [[ -z "${2:-}" ]] && { printf '--sample requires an integer arg\n' >&2; exit 2; }
      SAMPLE_LIMIT="$2"
      shift 2
      ;;
    --bucket)
      [[ -z "${2:-}" ]] && { printf '--bucket requires a category name\n' >&2; exit 2; }
      BUCKET="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: cluster-unknown-defects.sh [--sample N] [--bucket NAME] [--json]

Sample the named defect-pattern bucket and surface candidate clusters
by token frequency. Default bucket is `unknown` — the canonical
target since `unknown` defects bypass the classifier and are
otherwise lost to history.

Read-only. Surfaces candidates; the human decides which clusters
become new classifier categories in lib/classifier.sh.
USAGE
      exit 0
      ;;
    *)
      printf 'Unknown arg: %q\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "${DEFECT_FILE}" ]]; then
  printf 'No defect-patterns.json at %q\n' "${DEFECT_FILE}" >&2
  exit 1
fi

[[ "${SAMPLE_LIMIT}" =~ ^[0-9]+$ ]] || {
  printf '--sample must be a non-negative integer\n' >&2
  exit 2
}

# Pull the bucket. If it's missing, surface that explicitly.
bucket_json="$(jq --arg b "${BUCKET}" '.[$b] // empty' "${DEFECT_FILE}" 2>/dev/null || true)"
if [[ -z "${bucket_json}" ]]; then
  printf '_Bucket %q is not present in %s. Available buckets:_\n' "${BUCKET}" "${DEFECT_FILE}"
  jq -r 'keys[] | select(. != "_schema_version")' "${DEFECT_FILE}" 2>/dev/null | sed 's/^/  • /'
  exit 0
fi

count="$(jq -r '.count // 0' <<<"${bucket_json}")"
last_seen_ts="$(jq -r '.last_seen_ts // 0' <<<"${bucket_json}")"
last_project_id="$(jq -r '.last_project_id // ""' <<<"${bucket_json}")"
examples_json="$(jq '.examples // []' <<<"${bucket_json}")"
example_count="$(jq 'length' <<<"${examples_json}")"

# Sample-cap. The defect aggregator caps stored examples at a small
# number per bucket already (5 in v1.34.x). If --sample asks for more
# than what's stored, we use everything available; the report calls
# out the available vs requested counts.
sample_n="${SAMPLE_LIMIT}"
[[ "${sample_n}" -gt "${example_count}" ]] && sample_n="${example_count}"

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -n --arg bucket "${BUCKET}" \
        --argjson total "${count}" \
        --argjson last_seen "${last_seen_ts}" \
        --arg last_project "${last_project_id}" \
        --argjson sample_n "${sample_n}" \
        --argjson examples "${examples_json}" \
    '{
      bucket: $bucket,
      total_defects: $total,
      last_seen_ts: $last_seen,
      last_project_id: $last_project,
      sampled_examples: ($examples[0:$sample_n])
    }'
  exit 0
fi

# ── Markdown report ──────────────────────────────────────────────────
last_seen_iso=""
if [[ "${last_seen_ts}" -gt 0 ]]; then
  last_seen_iso="$(date -r "${last_seen_ts}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@${last_seen_ts}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "${last_seen_ts}")"
else
  last_seen_iso="never"
fi

printf '# Defect-cluster review — bucket: `%s`\n\n' "${BUCKET}"
printf '_Source: `%s`_\n\n' "${DEFECT_FILE}"
printf '| Metric | Value |\n|---|---|\n'
printf '| Total defects in bucket | %s |\n' "${count}"
printf '| Last seen | %s |\n' "${last_seen_iso}"
printf '| Last project_id | %s |\n' "${last_project_id:-—}"
printf '| Stored examples | %s |\n' "${example_count}"
printf '| Sampled (this run) | %s |\n' "${sample_n}"
printf '\n'

if [[ "${sample_n}" -eq 0 ]]; then
  printf '_No examples stored for this bucket — clustering not possible. Bucket may be empty or examples were never appended._\n'
  exit 0
fi

# Concatenate sampled examples into a single corpus for token analysis.
# We extract the first N examples; the aggregator stores them in
# insertion order, so this is "most recent N" by capture sequence.
corpus="$(jq -r --argjson n "${sample_n}" '.[0:$n][]' <<<"${examples_json}")"

# Section: top single-token frequencies. Lowercase, strip punctuation,
# drop stopwords + numerics + very short tokens. The remaining
# distribution surfaces the words a categorizer would notice first.
printf '## Top single-token frequencies (sampled)\n\n'
printf '_Bag-of-words across %d sampled examples. Stopwords + short tokens dropped. Words that recur across multiple examples are clustering candidates._\n\n' "${sample_n}"

# Stopword set — common English + boilerplate review-prose tokens.
stopwords='the a an and or but to of in on at for from with as is are be was were has have had not no than then this that these those it its their there you we they will would should could may can do does did then so if while when where what which who whom whose how because however moreover therefore'

# Build a set-comparison filter inline so awk doesn't need GNU-isms.
printf '%s' "${corpus}" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c '[:alnum:]' '\n' \
  | awk -v stop="${stopwords}" '
      BEGIN {
        n = split(stop, sw, " ")
        for (i = 1; i <= n; i++) drop[sw[i]] = 1
      }
      length($0) >= 4 && !($0 ~ /^[0-9]+$/) && !($0 in drop) {
        c[$0]++
      }
      END {
        for (k in c) printf "%d\t%s\n", c[k], k
      }
    ' \
  | sort -rn -k1,1 \
  | head -20 \
  | while IFS=$'\t' read -r n w; do
      printf -- '- `%s` × %s\n' "${w}" "${n}"
    done

printf '\n'

# Section: top bigrams. Adjacent token pairs are the cheapest signal
# for "this is a category, not noise". e.g. "missing test", "stale path",
# "broken link", "wrong path".
printf '## Top bigrams (sampled)\n\n'
printf '_Adjacent token pairs surfacing across multiple examples. Recurring bigrams are the strongest single signal for missing classifier categories._\n\n'

printf '%s' "${corpus}" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c '[:alnum:]\n' ' ' \
  | awk '
      {
        for (i = 1; i < NF; i++) {
          a = $i
          b = $(i+1)
          if (length(a) >= 4 && length(b) >= 4 && !(a ~ /^[0-9]+$/) && !(b ~ /^[0-9]+$/)) {
            pair = a " " b
            c[pair]++
          }
        }
      }
      END {
        for (k in c) if (c[k] >= 2) printf "%d\t%s\n", c[k], k
      }
    ' \
  | sort -rn -k1,1 \
  | head -15 \
  | while IFS=$'\t' read -r n bigram; do
      printf -- '- `%s` × %s\n' "${bigram}" "${n}"
    done

printf '\n'

# Section: file/path mentions. When an example references a specific
# path (e.g. `lib/state-io.sh`, `tests/test-state-fuzz.sh`), the
# referenced module may itself be a missing classifier category.
printf '## File / path mentions (sampled)\n\n'
printf '_Concrete paths cited inside the example texts. Recurring path mentions suggest a per-module classifier category may be missing._\n\n'

# Match unix-style paths (slash-bearing tokens with a typical extension)
# in the corpus. Conservative regex to avoid false positives.
path_hits="$(printf '%s' "${corpus}" \
  | grep -oE '[a-zA-Z_./-]+\.(sh|md|json|yml|yaml|py|ts|tsx|js|jsx|swift|m|h|hpp|cpp|toml|lock)' 2>/dev/null \
  | sort | uniq -c | sort -rn | head -10)"
if [[ -z "${path_hits}" ]]; then
  printf '_No path-shaped tokens found in the sampled examples._\n\n'
else
  printf '%s\n' "${path_hits}" | while read -r n p; do
    [[ -z "${p}" ]] && continue
    printf -- '- `%s` × %s\n' "${p}" "${n}"
  done
  printf '\n'
fi

# Section: full sample texts. The numeric clusters above are
# heuristics; the human ultimately decides which patterns are real
# clusters by reading the actual texts.
printf '## Sampled example texts (newest first)\n\n'
i=0
jq -r --argjson n "${sample_n}" '.[0:$n][]' <<<"${examples_json}" | while IFS= read -r ex; do
  i=$((i + 1))
  # Truncate at 280 chars for screen-readability; the full text lives
  # in defect-patterns.json. Strip control bytes that could ANSI-inject.
  ex_safe="$(printf '%s' "${ex}" | tr -d '\000-\010\013-\014\016-\037' | head -c 280)"
  printf '%d. %s\n\n' "${i}" "${ex_safe}"
done

printf '%s\n' '---'
printf '_To act on a cluster: pick the recurring bigram or path, draft a new classifier category in `bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh`, add a regression net in `tests/test-classifier.sh`, and update `AGENTS.md` "Defect categories"._\n'
printf '_To re-run with a wider sample: `cluster-unknown-defects.sh --sample 20`. To inspect another bucket: `cluster-unknown-defects.sh --bucket missing_test`._\n'
