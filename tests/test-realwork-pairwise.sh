#!/usr/bin/env bash
# Offline regression net for evals/realwork/pairwise.sh.
#
# A mock judge exercises the complete artifact packaging → anonymous A/B and
# B/A calls → strict parsing → identity reconciliation → aggregate/report path
# without network access or model spend.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAIRWISE="${REPO_ROOT}/evals/realwork/pairwise.sh"
PROBE="${REPO_ROOT}/evals/realwork/quality-probes/quality-config-diagnostics.json"

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
    printf '  FAIL: %s\n    expected to contain=%q\n    actual=%s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    unexpectedly contained=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_true() {
  local label="$1" rc="$2"
  if [[ "${rc}" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

sha_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

WORK="$(mktemp -d -t omc-pairwise-XXXXXX)"
cleanup() {
  if [[ "${OMC_KEEP_PAIRWISE_TEST_WORK:-0}" == "1" ]]; then
    printf 'kept pairwise test workspace: %s\n' "${WORK}" >&2
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

mkdir -p "${WORK}/artifacts/generic" "${WORK}/artifacts/crafted" \
  "${WORK}/artifacts/broken" "${WORK}/artifacts/identical" "${WORK}/artifacts/empty"
printf 'A correct but generic diagnostic. source provenance environment:APP_PORT. CLI compatible; exit code 2.\n' > "${WORK}/artifacts/generic/work.txt"
printf 'CRAFTED: diagnostic with source provenance environment:APP_PORT plus a concrete recovery action. CLI compatible; exit code 2.\n' > "${WORK}/artifacts/crafted/work.txt"
printf 'Flashy diagnostic without the hidden layered-source behavior. CLI compatible; exit code 2.\n' > "${WORK}/artifacts/broken/work.txt"
printf '%s\n' '{"status":"invalid_configuration","exit_code":2,"source":"environment:APP_PORT","raw_value":"eightythree","command":"config validate","stdout":""}' > "${WORK}/artifacts/generic/diagnostic.json"
cp "${WORK}/artifacts/generic/diagnostic.json" "${WORK}/artifacts/crafted/diagnostic.json"
printf '%s\n' '{"status":"invalid_configuration","exit_code":2,"source":"project-file","raw_value":"eightythree","command":"config validate","stdout":""}' > "${WORK}/artifacts/broken/diagnostic.json"
cp "${WORK}/artifacts/generic/work.txt" "${WORK}/artifacts/identical/work.txt"
cp "${WORK}/artifacts/generic/diagnostic.json" "${WORK}/artifacts/identical/diagnostic.json"

PROMPT_HASH="$(sha_text "$(jq -r '.prompt' "${PROBE}")")"
FIXTURE_DIR="${REPO_ROOT}/evals/realwork/fixtures/quality/config-diagnostics"
tree_hash() {
  local root="$1"
  (
    cd "${root}"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r rel; do
      if [[ -x "${rel}" ]]; then printf '%s\texecutable\t' "${rel}"; else printf '%s\tregular\t' "${rel}"; fi
      shasum -a 256 "${rel}" | awk '{print $1}'
    done
  ) | shasum -a 256 | awk '{print $1}'
}
FIXTURE_HASH="$(tree_hash "${FIXTURE_DIR}")"
SOURCE_HASH="$(tree_hash "${FIXTURE_DIR}/source")"

# Build two real, clean checkouts with one ancestry chain. The custom manifest
# is evaluator-development authority only: compare must bind both checkouts to
# it, while the default release claim gate must continue to reject its receipts.
IDENTITY_SOURCE="${WORK}/identity-source"
BASELINE_HARNESS="${WORK}/identity-baseline"
CHALLENGER_HARNESS="${IDENTITY_SOURCE}"
UNRELATED_CHALLENGER_HARNESS="${WORK}/identity-unrelated"
IDENTITY_MANIFEST="${WORK}/harness-identities.json"
IDENTITY_SLUG="example/pairwise-fixture"
git init -q "${IDENTITY_SOURCE}"
git -C "${IDENTITY_SOURCE}" config user.name "Pairwise Test"
git -C "${IDENTITY_SOURCE}" config user.email "pairwise@example.invalid"
git -C "${IDENTITY_SOURCE}" remote add origin \
  "https://github.com/${IDENTITY_SLUG}.git"
printf 'pre-feature harness\n' > "${IDENTITY_SOURCE}/harness.txt"
git -C "${IDENTITY_SOURCE}" add harness.txt
git -C "${IDENTITY_SOURCE}" commit -q -m baseline
BASELINE_COMMIT="$(git -C "${IDENTITY_SOURCE}" rev-parse HEAD)"
BASELINE_TREE="$(git -C "${IDENTITY_SOURCE}" rev-parse 'HEAD^{tree}')"
printf 'definition-of-excellent feature\n' > "${IDENTITY_SOURCE}/feature.marker"
git -C "${IDENTITY_SOURCE}" add feature.marker
git -C "${IDENTITY_SOURCE}" commit -q -m challenger
CHALLENGER_COMMIT="$(git -C "${IDENTITY_SOURCE}" rev-parse HEAD)"
CHALLENGER_TREE="$(git -C "${IDENTITY_SOURCE}" rev-parse 'HEAD^{tree}')"
git -C "${IDENTITY_SOURCE}" worktree add -q --detach \
  "${BASELINE_HARNESS}" "${BASELINE_COMMIT}"
git init -q "${UNRELATED_CHALLENGER_HARNESS}"
git -C "${UNRELATED_CHALLENGER_HARNESS}" config user.name "Pairwise Test"
git -C "${UNRELATED_CHALLENGER_HARNESS}" config user.email "pairwise@example.invalid"
git -C "${UNRELATED_CHALLENGER_HARNESS}" remote add origin \
  "https://github.com/${IDENTITY_SLUG}.git"
printf 'feature from an unrelated history\n' > "${UNRELATED_CHALLENGER_HARNESS}/feature.marker"
git -C "${UNRELATED_CHALLENGER_HARNESS}" add feature.marker
git -C "${UNRELATED_CHALLENGER_HARNESS}" commit -q -m unrelated
jq -n \
  --arg slug "${IDENTITY_SLUG}" \
  --arg baseline_commit "${BASELINE_COMMIT}" \
  --arg baseline_tree "${BASELINE_TREE}" '
    {
      schema_version:1,
      campaign_id:"pairwise-test-v1",
      repository:{slug:$slug},
      baseline:{
        label:"test baseline",
        boundary:"committed fixture source before test feature",
        git_commit:$baseline_commit,
        git_tree:$baseline_tree,
        absent_paths:["feature.marker"]
      },
      challenger:{label:"test challenger",policy:"explicit-checkout-descendant",required_paths:["feature.marker"]}
    }
  ' > "${IDENTITY_MANIFEST}"
BASELINE_HARNESS_HASH="$(sha_text "${IDENTITY_SLUG}|${BASELINE_COMMIT}|${BASELINE_TREE}")"
CHALLENGER_HARNESS_HASH="$(sha_text "${IDENTITY_SLUG}|${CHALLENGER_COMMIT}|${CHALLENGER_TREE}")"
PAIRWISE_COMPARE=(bash "${PAIRWISE}" compare
  --identity-manifest "${IDENTITY_MANIFEST}"
  --baseline-harness "${BASELINE_HARNESS}"
  --challenger-harness "${CHALLENGER_HARNESS}")

make_summary() {
  local output="$1" artifact="$2" harness_hash="$3" fixture_hash="$4"
  local layered_ok="$5" cost="$6" wall="$7" input="$8" output_tokens="$9"
  local harness_role="challenger"
  [[ "${harness_hash}" == "${BASELINE_HARNESS_HASH}" ]] && harness_role="baseline"
  jq -n \
    --arg probe_id "quality-config-diagnostics" \
    --arg prompt_hash "${PROMPT_HASH}" \
    --arg fixture_hash "${fixture_hash}" \
    --arg source_hash "${SOURCE_HASH}" \
    --arg harness_role "${harness_role}" \
    --arg harness_hash "${harness_hash}" \
    --arg artifact_dir "${artifact}" \
    --argjson layered_ok "${layered_ok}" \
    --argjson cost "${cost}" \
    --argjson wall "${wall}" \
    --argjson input "${input}" \
    --argjson output_tokens "${output_tokens}" '
      {
        probe_id:$probe_id,
        provenance:{
          prompt_hash:$prompt_hash,
          fixture_hash:$fixture_hash,
          source_hash:$source_hash,
          model:"claude-test-model-1",
          model_tier:"balanced",
          harness_role:$harness_role,
          harness_hash:$harness_hash
        },
        artifact_dir:$artifact_dir,
        economics:{
          cost_usd:$cost,
          wall_seconds:$wall,
          tokens:{input:$input, output:$output_tokens, cache_read:500, cache_creation:50}
        }
      }
    ' > "${output}"
}

make_summary "${WORK}/baseline.json" "${WORK}/artifacts/generic" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
make_summary "${WORK}/challenger.json" "${WORK}/artifacts/crafted" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1.5 120 180 110

export MOCK_LOG_DIR="${WORK}/mock-log"
mkdir -p "${MOCK_LOG_DIR}"
printf '0' > "${MOCK_LOG_DIR}/counter"
printf '' > "${MOCK_LOG_DIR}/prompts.log"
printf '' > "${MOCK_LOG_DIR}/args.log"
printf '' > "${MOCK_LOG_DIR}/cwd.log"

cat > "${WORK}/mock-judge" <<'MOCK'
#!/usr/bin/env bash
prompt=""
args="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
n="$(cat "${MOCK_LOG_DIR}/counter")"
n=$((n + 1))
printf '%s' "${n}" > "${MOCK_LOG_DIR}/counter"
printf '%s\n' "${args}" >> "${MOCK_LOG_DIR}/args.log"
printf '%s\n<<<END-PROMPT>>>\n' "${prompt}" >> "${MOCK_LOG_DIR}/prompts.log"
printf '%s\n' "${PWD}" >> "${MOCK_LOG_DIR}/cwd.log"

# A judge workspace must not expose the durable pair manifest or sibling
# presentation order through an easy relative traversal.
if [[ -f ../../pair.json || -d ../forward || -d ../reverse ]]; then
  printf 'judge workspace leaks comparison metadata\n' >&2
  exit 88
fi

hash_a="$(printf '%s\n' "${prompt}" | awk '/^A_ARTIFACT_HASH:/ {print $2; exit}')"
hash_b="$(printf '%s\n' "${prompt}" | awk '/^B_ARTIFACT_HASH:/ {print $2; exit}')"
rubric="$(printf '%s\n' "${prompt}" | awk '/^RUBRIC_VERSION:/ {print $2; exit}')"

case "${MOCK_MODE:-artifact}" in
  artifact)
    if grep -q 'CRAFTED:' A/work.txt; then winner=A; else winner=B; fi
    creep_a=false; creep_b=false
    ;;
  always-a) winner=A; creep_a=false; creep_b=false ;;
  overreach)
    if grep -q 'CRAFTED:' A/work.txt; then
      winner=B; creep_a=true; creep_b=false
    else
      winner=A; creep_a=false; creep_b=true
    fi
    ;;
  invalid)
    payload="$(jq -nc --arg r "${rubric}" --arg a "${hash_a}" --arg b "${hash_b}" '
      {rubric_version:$r, artifact_hashes:{A:$a,B:$b},
       dimensions:{
         deliberate:{winner:"A",confidence:0.8,evidence:["A/work.txt"]},
         distinctive:{winner:"A",confidence:0.8,evidence:["A/work.txt"]},
         coherent:{winner:"A",confidence:0.8,evidence:["A/work.txt"]},
         complete:{winner:"A",confidence:0.8,evidence:["A/work.txt"]}},
       overall:{winner:"A",material:true,confidence:0.8,reason:"missing visionary on purpose"},
       scope_creep:{A:false,B:false},hard_quality_warning:[]}'
    )"
    jq -nc --arg result "${payload}" \
      '{type:"result",is_error:false,total_cost_usd:0.01,duration_ms:10,result:$result}'
    exit 0
    ;;
  *) winner=tie; creep_a=false; creep_b=false ;;
esac

payload="$(jq -nc \
  --arg r "${rubric}" --arg a "${hash_a}" --arg b "${hash_b}" --arg w "${winner}" \
  --argjson creep_a "${creep_a}" --argjson creep_b "${creep_b}" '
  def d:{winner:$w,confidence:0.9,evidence:[($w + "/work.txt: concrete artifact evidence")]};
  {rubric_version:$r,artifact_hashes:{A:$a,B:$b},
   dimensions:{deliberate:d,distinctive:d,coherent:d,visionary:d,complete:d},
   overall:{winner:$w,material:($w != "tie"),confidence:0.9,reason:"artifact-grounded preference"},
   scope_creep:{A:$creep_a,B:$creep_b},hard_quality_warning:[]}'
)"
jq -nc --arg result "${payload}" \
  '{type:"result",is_error:false,total_cost_usd:0.01,duration_ms:10,result:$result}'
MOCK
chmod +x "${WORK}/mock-judge"

printf 'T1: shipped schemas and quality probes validate\n'
out="$(bash "${PAIRWISE}" validate)"
assert_contains "T1: six-domain quality portfolio" "Validated 6 quality probe(s)" "${out}"
assert_eq "T1: judge schema requires visionary" "true" \
  "$(jq -r '.properties.dimensions.required | index("visionary") != null' "${REPO_ROOT}/evals/realwork/judge-schema.json")"
assert_eq "T1: candidate schema requires evaluator-bound role and hash" "true" \
  "$(jq -r '
    .properties.campaign.properties.candidate_summary_contract.properties.schema_version.const == 3
    and (.properties.campaign.properties.candidate_summary_contract.properties.required_provenance.const
      == ["prompt_hash","fixture_hash","source_hash","model","model_tier","harness_role","harness_hash"])
  ' "${REPO_ROOT}/evals/realwork/quality-schema.json")"
assert_eq "T1: canonical campaign pins one exact pre-feature commit and tree" "true" \
  "$(jq -r '
    .campaign_id == "definition-of-excellent-v1"
    and (.baseline.git_commit | test("^[0-9a-f]{40}$"))
    and (.baseline.git_tree | test("^[0-9a-f]{40}$"))
    and .baseline.boundary == "committed task-start source before Definition-of-Excellent implementation"
    and (.baseline.absent_paths == .challenger.required_paths)
    and .challenger.policy == "evaluator-checkout-descendant"
  ' "${REPO_ROOT}/evals/realwork/harness-identities.json")"

printf 'T1b: compare refuses producer summaries without evaluator-owned checkout bindings\n'
rc=0; missing_checkout_out="$(bash "${PAIRWISE}" compare \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-missing-checkouts" 2>&1)" || rc=$?
assert_eq "T1b: missing checkout bindings exit 2" "2" "${rc}"
assert_contains "T1b: required checkout flags are named" \
  "--baseline-harness, --challenger-harness" "${missing_checkout_out}"

printf 'T1c: the baseline checkout must be the manifest-pinned commit and tree\n'
rc=0; wrong_baseline_out="$(bash "${PAIRWISE}" compare \
  --identity-manifest "${IDENTITY_MANIFEST}" \
  --baseline-harness "${CHALLENGER_HARNESS}" \
  --challenger-harness "${BASELINE_HARNESS}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-wrong-baseline" 2>&1)" || rc=$?
assert_eq "T1c: wrong baseline exits 2" "2" "${rc}"
assert_contains "T1c: pinned baseline failure is explicit" \
  "manifest-pinned pre-feature commit/tree" "${wrong_baseline_out}"

printf 'T1d: a dirty challenger checkout cannot be represented as an exact identity\n'
printf 'uncommitted evaluator drift\n' > "${CHALLENGER_HARNESS}/dirty.tmp"
rc=0; dirty_challenger_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-dirty-challenger" 2>&1)" || rc=$?
rm -f "${CHALLENGER_HARNESS}/dirty.tmp"
assert_eq "T1d: dirty challenger exits 2" "2" "${rc}"
assert_contains "T1d: clean-worktree contract is named" \
  "clean-worktree contract" "${dirty_challenger_out}"

printf 'T1e: a same-name repository from unrelated history is not a challenger\n'
rc=0; unrelated_challenger_out="$(bash "${PAIRWISE}" compare \
  --identity-manifest "${IDENTITY_MANIFEST}" \
  --baseline-harness "${BASELINE_HARNESS}" \
  --challenger-harness "${UNRELATED_CHALLENGER_HARNESS}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-unrelated-challenger" 2>&1)" || rc=$?
assert_eq "T1e: unrelated challenger exits 2" "2" "${rc}"
assert_contains "T1e: descendant contract is named" \
  "manifest policy, descendant" "${unrelated_challenger_out}"

printf 'T2: malformed probe missing visionary is rejected\n'
jq '.rubric.dimensions |= map(select(.id != "visionary"))' "${PROBE}" > "${WORK}/invalid-probe.json"
rc=0; invalid_out="$(bash "${PAIRWISE}" validate "${WORK}/invalid-probe.json" 2>&1)" || rc=$?
assert_eq "T2: invalid probe exits 2" "2" "${rc}"
assert_contains "T2: error names invalid probe" "invalid quality probe" "${invalid_out}"

printf 'T2b: campaign cannot omit the candidate-summary contract\n'
jq 'del(.campaign.candidate_summary_contract)' "${PROBE}" > "${WORK}/missing-summary-contract.json"
rc=0; invalid_out="$(bash "${PAIRWISE}" validate "${WORK}/missing-summary-contract.json" 2>&1)" || rc=$?
assert_eq "T2b: missing summary contract exits 2" "2" "${rc}"
assert_contains "T2b: missing contract is an invalid probe" "invalid quality probe" "${invalid_out}"

printf 'T2c: a probe cannot validate against a merely described missing fixture\n'
jq '.fixture = "fixtures/quality/not-actually-shipped"' "${PROBE}" > "${WORK}/missing-fixture.json"
rc=0; fixture_out="$(bash "${PAIRWISE}" validate "${WORK}/missing-fixture.json" 2>&1)" || rc=$?
assert_eq "T2c: missing fixture exits 2" "2" "${rc}"
assert_contains "T2c: missing fixture is named" "missing or unsafe fixture" "${fixture_out}"

printf 'T3: blind two-order comparison maps both judgments to challenger\n'
before_generic="$(shasum -a 256 "${WORK}/artifacts/generic/work.txt" | awk '{print $1}')"
before_crafted="$(shasum -a 256 "${WORK}/artifacts/crafted/work.txt" | awk '{print $1}')"
receipt_win="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair win" \
  --judge-bin "${WORK}/mock-judge" \
  --seed stable-seed)"
assert_eq "T3: challenger wins" "challenger" "$(jq -r '.winner' "${receipt_win}")"
assert_eq "T3: basis is judge" "judge" "$(jq -r '.basis' "${receipt_win}")"
assert_eq "T3: order results consistent" "true" "$(jq -r '.position_consistent' "${receipt_win}")"
assert_eq "T3: visionary maps to challenger" "challenger" "$(jq -r '.dimensions.visionary' "${receipt_win}")"
assert_eq "T3: exactly two paid-shaped calls" "2" "$(jq -r '.economics.judge.calls' "${receipt_win}")"
assert_eq "T3: judge cost kept separate" "0.02" "$(jq -r '.economics.judge.cost_usd' "${receipt_win}")"
assert_eq "T3: harness seals the pair manifest" "true" \
  "$(jq -r '.pair_manifest_hash == .pair_manifest.manifest_hash and (.pair_manifest_hash | test("^[0-9a-f]{64}$"))' "${receipt_win}")"
assert_eq "T3: harness seals the raw receipt" "true" \
  "$(jq -r '.receipt_hash | test("^[0-9a-f]{64}$")' "${receipt_win}")"
assert_eq "T3: receipt carries the evaluator-verified exact checkout identities" "true" \
  "$(jq -r \
    --arg baseline_hash "${BASELINE_HARNESS_HASH}" \
    --arg challenger_hash "${CHALLENGER_HARNESS_HASH}" '
      .schema_version == 3
      and .provenance.harness_identity.authority == "custom"
      and .provenance.harness_identity.baseline.identity_hash == $baseline_hash
      and .provenance.harness_identity.challenger.identity_hash == $challenger_hash
      and .provenance.harness_identity.baseline.checkout_policy == "manifest-pinned-commit-tree"
      and .provenance.harness_identity.challenger.checkout_policy == "explicit-checkout-descendant"
    ' "${receipt_win}")"
assert_eq "T3: hard checks came from fixture rules" "true" \
  "$(jq -r '[.pair_manifest.candidates.challenger.check_results[].pass] | all' "${receipt_win}")"
assert_eq "T3: source baseline unchanged" "${before_generic}" \
  "$(shasum -a 256 "${WORK}/artifacts/generic/work.txt" | awk '{print $1}')"
assert_eq "T3: source challenger unchanged" "${before_crafted}" \
  "$(shasum -a 256 "${WORK}/artifacts/crafted/work.txt" | awk '{print $1}')"
prompt_log="$(cat "${MOCK_LOG_DIR}/prompts.log")"
assert_not_contains "T3: prompt hides baseline role" "baseline" "${prompt_log}"
assert_not_contains "T3: prompt hides challenger role" "challenger" "${prompt_log}"
assert_not_contains "T3: judge is not told presentation order" "COMPARISON_ORDER" "${prompt_log}"
assert_not_contains "T3: judge workspace is outside the durable audit package" "${WORK}" \
  "$(cat "${MOCK_LOG_DIR}/cwd.log")"
args_log="$(cat "${MOCK_LOG_DIR}/args.log")"
assert_contains "T3: judge runs safe mode" "--safe-mode" "${args_log}"
assert_contains "T3: judge receives strict schema" "--json-schema" "${args_log}"

printf 'T4: constant-position judge disagreement collapses to tie\n'
export MOCK_MODE=always-a
receipt_position="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-position" \
  --judge-bin "${WORK}/mock-judge" \
  --seed another-seed)"
assert_eq "T4: overall becomes tie" "tie" "$(jq -r '.winner' "${receipt_position}")"
assert_eq "T4: inconsistency recorded" "false" "$(jq -r '.position_consistent' "${receipt_position}")"
assert_eq "T4: visionary also becomes tie" "tie" "$(jq -r '.dimensions.visionary' "${receipt_position}")"

printf 'T4b: scope-creep judgment follows artifact identity across both orders\n'
export MOCK_MODE=overreach
receipt_overreach="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-overreach" \
  --judge-bin "${WORK}/mock-judge" \
  --seed overreach-seed)"
assert_eq "T4b: restrained baseline wins" "baseline" "$(jq -r '.winner' "${receipt_overreach}")"
assert_eq "T4b: challenger scope creep mapped" "true" "$(jq -r '.scope_creep.challenger' "${receipt_overreach}")"
assert_eq "T4b: baseline not falsely flagged" "false" "$(jq -r '.scope_creep.baseline' "${receipt_overreach}")"
unset MOCK_MODE

printf 'T5: byte-identical artifacts auto-tie without a judge call\n'
make_summary "${WORK}/same-a.json" "${WORK}/artifacts/identical" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
make_summary "${WORK}/same-b.json" "${WORK}/artifacts/identical" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_same="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/same-a.json" \
  --challenger "${WORK}/same-b.json" \
  --out "${WORK}/pair-identical" \
  --judge-bin "${WORK}/mock-judge" --seed same-seed)"
assert_eq "T5: identical basis" "identical-artifact" "$(jq -r '.basis' "${receipt_same}")"
assert_eq "T5: identical winner tie" "tie" "$(jq -r '.winner' "${receipt_same}")"
assert_eq "T5: identical artifacts do not impersonate a five-axis judgment" "false" \
  "$(jq -r '.dimensions_evaluated' "${receipt_same}")"
assert_eq "T5: no judge invocation" "${calls_before}" "$(cat "${MOCK_LOG_DIR}/counter")"

printf 'T5b: an empty artifact package cannot enter the judge\n'
make_summary "${WORK}/empty.json" "${WORK}/artifacts/empty" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; empty_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/empty.json" \
  --out "${WORK}/pair-empty" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T5b: empty package exits 2" "2" "${rc}"
assert_contains "T5b: empty package is named" "artifact package contains no files" "${empty_out}"

printf 'T6: critical fixture-check failure vetoes a flashy candidate\n'
make_summary "${WORK}/broken-flashy.json" "${WORK}/artifacts/broken" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" false 1.5 120 180 110
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_veto="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/broken-flashy.json" \
  --out "${WORK}/pair-veto" \
  --judge-bin "${WORK}/mock-judge" --seed veto-seed)"
assert_eq "T6: baseline wins veto" "baseline" "$(jq -r '.winner' "${receipt_veto}")"
assert_eq "T6: veto basis" "hard-check-veto" "$(jq -r '.basis' "${receipt_veto}")"
assert_contains "T6: failing check retained" "layered_source_case" \
  "$(jq -c '.critical_failures.challenger' "${receipt_veto}")"
assert_eq "T6: veto makes no judge call" "${calls_before}" "$(cat "${MOCK_LOG_DIR}/counter")"

printf 'T6b: candidate-supplied check booleans are forbidden rather than trusted\n'
jq '.checks = {diagnostic_contract:true, layered_source_case:true, cli_compatibility:true}' \
  "${WORK}/challenger.json" > "${WORK}/self-attested.json"
rc=0; self_attested_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/self-attested.json" \
  --out "${WORK}/pair-self-attested" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T6b: self-attested candidate exits 2" "2" "${rc}"
assert_contains "T6b: strict candidate contract rejects checks" "invalid challenger candidate summary" "${self_attested_out}"

printf 'T7: matched-provenance enforcement rejects a fixture mismatch\n'
make_summary "${WORK}/mismatch.json" "${WORK}/artifacts/crafted" \
  "${CHALLENGER_HARNESS_HASH}" "$(sha_text wrong-fixture)" true 1.5 120 180 110
rc=0; mismatch_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/mismatch.json" \
  --out "${WORK}/pair-mismatch" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7: mismatch exits 2" "2" "${rc}"
assert_contains "T7: fixture mismatch named" "fixture_hash" "${mismatch_out}"

printf 'T7b: token economics must be exact integer usage buckets\n'
jq '.economics.tokens.cache_read = 1.5' "${WORK}/challenger.json" > "${WORK}/fractional-tokens.json"
rc=0; token_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/fractional-tokens.json" \
  --out "${WORK}/pair-fractional-tokens" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7b: fractional tokens exit 2" "2" "${rc}"
assert_contains "T7b: invalid candidate summary named" "invalid challenger candidate summary" "${token_out}"

printf 'T7c: a counterfactual pair must identify distinct harness builds\n'
jq --arg hash "${BASELINE_HARNESS_HASH}" '.provenance.harness_hash = $hash' \
  "${WORK}/challenger.json" > "${WORK}/same-harness.json"
rc=0; harness_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/same-harness.json" \
  --out "${WORK}/pair-same-harness" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7c: same harness exits 2" "2" "${rc}"
assert_contains "T7c: harness mismatch contract named" \
  "harness_hash does not match the independently verified challenger checkout" "${harness_out}"

printf 'T7d: legacy probe aliases cannot bypass the manifest contract\n'
jq '.probe = .probe_id | del(.probe_id)' "${WORK}/challenger.json" > "${WORK}/probe-alias.json"
rc=0; alias_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/probe-alias.json" \
  --out "${WORK}/pair-probe-alias" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7d: missing canonical probe_id exits 2" "2" "${rc}"
assert_contains "T7d: candidate summary contract is enforced" "invalid challenger candidate summary" "${alias_out}"

printf 'T8: strict judge output missing visionary fails after bounded retry\n'
export MOCK_MODE=invalid
rc=0; invalid_judge_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-invalid-judge" \
  --judge-bin "${WORK}/mock-judge" --seed invalid-seed 2>&1)" || rc=$?
assert_eq "T8: strict failure exits 2" "2" "${rc}"
assert_contains "T8: bounded validation failure named" "failed strict validation twice" "${invalid_judge_out}"
unset MOCK_MODE

printf 'T8b: winner/material contradictions fail strict reconciliation\n'
jq '.overall.winner = "tie" | .overall.material = true' \
  "${WORK}/pair win/judge-forward.response.json" > "${WORK}/invalid-material.json"
rc=0; material_out="$(bash "${PAIRWISE}" reconcile \
  --pair "${WORK}/pair win/pair.json" \
  --forward "${WORK}/invalid-material.json" \
  --reverse "${WORK}/pair win/judge-reverse.response.json" \
  --out "${WORK}/invalid-material-receipt.json" 2>&1)" || rc=$?
assert_eq "T8b: contradictory material flag exits 2" "2" "${rc}"
assert_contains "T8b: invalid forward response named" "invalid forward judge response" "${material_out}"

printf 'T9: report carries pair outcomes and candidate/judge economics\n'
report_file="${WORK}/report.json"
bash "${PAIRWISE}" report "${receipt_win}" "${receipt_same}" > "${report_file}"
assert_eq "T9: two pairs" "2" "$(jq -r '.pair_count' "${report_file}")"
assert_eq "T9: one challenger win" "1" "$(jq -r '.outcomes.challenger_wins' "${report_file}")"
assert_eq "T9: one tie" "1" "$(jq -r '.outcomes.ties' "${report_file}")"
assert_eq "T9: win rate includes tie denominator" "0.5" "$(jq -r '.outcomes.win_rate' "${report_file}")"
assert_eq "T9: report inventories probe identities" '["quality-config-diagnostics"]' \
  "$(jq -c '.probe_ids' "${report_file}")"
assert_eq "T9: report inventories probe-tier strata" "2" \
  "$(jq -r '.strata[0].pairs' "${report_file}")"
assert_eq "T9: median candidate cost ratio" "1.25" "$(jq -r '.economics.median_ratios.cost' "${report_file}")"
assert_eq "T9: token ratio reported" "true" \
  "$(jq -r '.economics.median_ratios.tokens > 1' "${report_file}")"
assert_eq "T9: judge cost only from judged pair" "0.02" "$(jq -r '.economics.judge.cost_usd' "${report_file}")"
assert_eq "T9: exact paired sign test excludes ties" '{"method":"exact-two-sided-binomial","ties_excluded":true,"wins":1,"losses":0,"n":1,"p_value":1}' \
  "$(jq -c '.sign_test' "${report_file}")"
assert_eq "T9: per-domain margin is recomputed" "0.5" \
  "$(jq -r '.domain_outcomes[] | select(.domain=="coding") | .margin' "${report_file}")"
assert_eq "T9: report is derived and sealed" "true" \
  "$(jq -r '.schema_version == 3 and (.report_hash | test("^[0-9a-f]{64}$")) and (.receipt_hashes | length == 2)' "${report_file}")"
assert_eq "T9: report exposes one coherent harness campaign identity" "true" \
  "$(jq -r \
    --arg baseline_hash "${BASELINE_HARNESS_HASH}" \
    --arg challenger_hash "${CHALLENGER_HARNESS_HASH}" \
    --arg baseline_tree "${BASELINE_TREE}" \
    --arg challenger_tree "${CHALLENGER_TREE}" '
      .harness_identity.authorities == ["custom"]
      and .harness_identity.campaign_ids == ["pairwise-test-v1"]
      and .harness_identity.repository_slugs == ["example/pairwise-fixture"]
      and .harness_identity.baseline_hashes == [$baseline_hash]
      and .harness_identity.challenger_hashes == [$challenger_hash]
      and .harness_identity.baseline_trees == [$baseline_tree]
      and .harness_identity.challenger_trees == [$challenger_tree]
      and (.harness_identity.manifest_hashes | length) == 1
    ' "${report_file}")"
reverse_report_hash="$(bash "${PAIRWISE}" report "${receipt_same}" "${receipt_win}" | jq -r '.report_hash')"
assert_eq "T9: report seal is independent of argument order" "$(jq -r '.report_hash' "${report_file}")" \
  "${reverse_report_hash}"

printf 'T9b: duplicate pair receipts cannot inflate campaign size\n'
rc=0; duplicate_out="$(bash "${PAIRWISE}" report "${receipt_win}" "${receipt_win}" 2>&1)" || rc=$?
assert_eq "T9b: duplicate pair exits 2" "2" "${rc}"
assert_contains "T9b: duplicate pair identity is named" "duplicate pair identity" "${duplicate_out}"

printf 'T9c: aggregate reports are never accepted as claim evidence\n'
rc=0; aggregate_claim="$(bash "${PAIRWISE}" claim-check "${report_file}" 2>&1)" || rc=$?
assert_eq "T9c: aggregate input exits 2" "2" "${rc}"
assert_contains "T9c: aggregate is rejected as an invalid raw receipt" "invalid, unsealed, or stale pairwise receipt" "${aggregate_claim}"

printf 'T9d: malformed receipt fields fail before aggregation\n'
jq 'del(.scope_creep.challenger)' "${receipt_win}" > "${WORK}/malformed-receipt.json"
rc=0; malformed_out="$(bash "${PAIRWISE}" report "${WORK}/malformed-receipt.json" 2>&1)" || rc=$?
assert_eq "T9d: malformed receipt exits 2" "2" "${rc}"
assert_contains "T9d: malformed receipt is named" "invalid, unsealed, or stale pairwise receipt" "${malformed_out}"

printf 'T9e: changing the random seed cannot replay the same artifact pair\n'
receipt_replay="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-replay" \
  --judge-bin "${WORK}/mock-judge" --seed replay-only-seed)"
assert_eq "T9e: pair identity ignores seed" "$(jq -r '.pair_identity' "${receipt_win}")" \
  "$(jq -r '.pair_identity' "${receipt_replay}")"
rc=0; replay_out="$(bash "${PAIRWISE}" report "${receipt_win}" "${receipt_replay}" 2>&1)" || rc=$?
assert_eq "T9e: replayed pair exits 2" "2" "${rc}"
assert_contains "T9e: replay identity is named" "duplicate pair identity" "${replay_out}"

printf 'T10: preregistered release threshold refuses an undersized campaign\n'
rc=0; claim_fail="$(bash "${PAIRWISE}" claim-check "${receipt_win}" "${receipt_same}" 2>&1)" || rc=$?
assert_eq "T10: claim gate exits nonzero" "1" "${rc}"
assert_eq "T10: pass=false" "false" "$(jq -r '.pass' <<<"${claim_fail}")"
assert_contains "T10: pair-count failure explicit" "pair_count" "${claim_fail}"
assert_contains "T10: custom evidence cannot make a release claim" \
  "canonical_harness_authority" "${claim_fail}"
assert_contains "T10: release claim binds the receipt to the current canonical checkout" \
  "canonical_challenger_checkout" "${claim_fail}"

printf 'T10b: a losing domain and non-positive sign result are release blockers\n'
rc=0; direction_fail="$(bash "${PAIRWISE}" claim-check "${receipt_overreach}" \
  --allow-custom-portfolio --min-pairs 1 --min-domains 1 --min-tiers 1 \
  --min-axis-pairs 1 --max-challenger-scope-creep 1 \
  --min-win-rate 0 --max-loss-rate 1 --min-positive-axes 0 \
  --min-visionary-margin 0 --max-sign-p-value 1 \
  --max-median-cost-ratio 2 --max-median-wall-ratio 2 \
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2 2>&1)" || rc=$?
assert_eq "T10b: adverse domain exits nonzero" "1" "${rc}"
assert_contains "T10b: negative domain is explicit" "negative_domain" "${direction_fail}"
assert_contains "T10b: sign direction is explicit" "paired_sign_test" "${direction_fail}"

printf 'T11: explicit low test thresholds exercise the passing claim path\n'
claim_pass="$(bash "${PAIRWISE}" claim-check "${receipt_win}" "${receipt_same}" \
  --allow-custom-portfolio \
  --min-pairs 2 --min-domains 1 --min-tiers 1 \
  --min-axis-pairs 1 --max-challenger-scope-creep 0 \
  --min-win-rate 0.5 --max-loss-rate 0 \
  --min-positive-axes 5 --min-visionary-margin 0.5 \
  --max-sign-p-value 1 \
  --max-median-cost-ratio 2 --max-median-wall-ratio 2 \
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2)"
assert_eq "T11: passing path" "true" "$(jq -r '.pass' <<<"${claim_pass}")"
assert_eq "T11: no failures" "0" "$(jq -r '.failures | length' <<<"${claim_pass}")"

printf '\n=== realwork-pairwise tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
