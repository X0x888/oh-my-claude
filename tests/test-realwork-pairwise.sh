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
MINIMAL_PROBE="${REPO_ROOT}/evals/realwork/quality-probes/quality-minimal-change-control.json"
export OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=1

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

producer_task_hash() {
  local probe="$1" contract prompt
  contract="$(jq -cS '{
    schema_version:1,
    task:.prompt,
    audience:.rubric.audience,
    constraints:.rubric.constraints,
    non_goals:.rubric.non_goals,
    quality_anchors:.rubric.task_specific_anchors,
    quality_dimensions:[.rubric.dimensions[] | .id],
    deliverables:.candidate_artifacts,
    acceptance_diagnostics:[.hard_checks[] | {id,description,critical}]
  }' "${probe}")"
  prompt="$(
    printf '%s\n\n' "$(jq -r '.prompt' "${probe}")"
    printf '%s\n' 'EVALUATOR-OWNED DELIVERABLE CONTRACT (identical for both arms):'
    printf '%s\n' 'Work only in the supplied fixture workspace. Produce at least one regular file for every declared non-git package; when git_diff is declared, make a real tracked workspace change. Do not create .pairwise; that namespace and its managed files are evaluator-owned. Do not create symlinks or special filesystem nodes.'
    printf '%s\n' "${contract}" | jq .
  )"
  sha_text "${prompt}"
}

WORK="$(mktemp -d -t omc-pairwise-XXXXXX)"
WORK="$(cd "${WORK}" && pwd -P)"
cleanup() {
  if [[ "${OMC_KEEP_PAIRWISE_TEST_WORK:-0}" == "1" ]]; then
    printf 'kept pairwise test workspace: %s\n' "${WORK}" >&2
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

mkdir -p "${WORK}/artifacts/generic" "${WORK}/artifacts/crafted" \
  "${WORK}/artifacts/broken" "${WORK}/artifacts/identical" "${WORK}/artifacts/identical-b" "${WORK}/artifacts/empty" \
  "${WORK}/artifacts/minimal-ok/src" "${WORK}/artifacts/minimal-broken/src" \
  "${WORK}/artifacts/minimal-overreach/src"
printf 'A correct but generic diagnostic. source provenance environment:APP_PORT. CLI compatible; exit code 2.\n' > "${WORK}/artifacts/generic/work.txt"
printf 'CRAFTED: diagnostic with source provenance environment:APP_PORT plus a concrete recovery action. CLI compatible; exit code 2.\n' > "${WORK}/artifacts/crafted/work.txt"
printf 'Flashy diagnostic without the hidden layered-source behavior. CLI compatible; exit code 2.\n' > "${WORK}/artifacts/broken/work.txt"
printf '%s\n' '{"status":"invalid_configuration","exit_code":2,"source":"environment:APP_PORT","raw_value":"eightythree","command":"config validate","stdout":""}' > "${WORK}/artifacts/generic/diagnostic.json"
cp "${WORK}/artifacts/generic/diagnostic.json" "${WORK}/artifacts/crafted/diagnostic.json"
printf '%s\n' '{"status":"invalid_configuration","exit_code":2,"source":"project-file","raw_value":"eightythree","command":"config validate","stdout":""}' > "${WORK}/artifacts/broken/diagnostic.json"
cp "${WORK}/artifacts/generic/work.txt" "${WORK}/artifacts/identical/work.txt"
cp "${WORK}/artifacts/generic/diagnostic.json" "${WORK}/artifacts/identical/diagnostic.json"
cp "${WORK}/artifacts/generic/work.txt" "${WORK}/artifacts/identical-b/work.txt"
cp "${WORK}/artifacts/generic/diagnostic.json" "${WORK}/artifacts/identical-b/diagnostic.json"
printf 'Pending\n' > "${WORK}/artifacts/minimal-ok/src/status.txt"
printf 'Pending\n' > "${WORK}/artifacts/minimal-broken/src/status.txt"
printf 'Pending\n' > "${WORK}/artifacts/minimal-overreach/src/status.txt"
cp "${REPO_ROOT}/evals/realwork/fixtures/quality/minimal-change-control/source/src/protocol.txt" \
  "${WORK}/artifacts/minimal-ok/src/protocol.txt"
cp "${REPO_ROOT}/evals/realwork/fixtures/quality/minimal-change-control/source/src/protocol.txt" \
  "${WORK}/artifacts/minimal-overreach/src/protocol.txt"
printf 'status_code=99\ntransition=unrelated_rewrite\n' \
  > "${WORK}/artifacts/minimal-broken/src/protocol.txt"
for artifact_dir in generic crafted broken identical identical-b; do
  mkdir -p "${WORK}/artifacts/${artifact_dir}/.pairwise"
  printf 'diff --git a/work.txt b/work.txt\n' > "${WORK}/artifacts/${artifact_dir}/.pairwise/git.diff"
  printf '%s\n' '{"paths":["work.txt"],"schema_version":1}' \
    > "${WORK}/artifacts/${artifact_dir}/.pairwise/changed-paths.json"
done
for artifact_dir in minimal-ok minimal-broken minimal-overreach; do
  mkdir -p "${WORK}/artifacts/${artifact_dir}/.pairwise"
  printf 'diff --git a/src/status.txt b/src/status.txt\n' > "${WORK}/artifacts/${artifact_dir}/.pairwise/git.diff"
  printf '%s\n' '{"paths":["src/status.txt"],"schema_version":1}' \
    > "${WORK}/artifacts/${artifact_dir}/.pairwise/changed-paths.json"
done
printf '%s\n' '{"paths":["src/status.txt","unrelated.txt"],"schema_version":1}' \
  > "${WORK}/artifacts/minimal-overreach/.pairwise/changed-paths.json"
printf '%s\n' 'diff --git a/unrelated.txt b/unrelated.txt' \
  >> "${WORK}/artifacts/minimal-overreach/.pairwise/git.diff"

PROMPT_HASH="$(sha_text "$(jq -r '.prompt' "${PROBE}")")"
FIXTURE_DIR="${REPO_ROOT}/evals/realwork/fixtures/quality/config-diagnostics"
tree_hash() {
  local root="$1"
  (
    cd "${root}"
    find . -print | LC_ALL=C sort | while IFS= read -r rel; do
      if [[ -d "${rel}" ]]; then
        printf '%s\tdirectory\n' "${rel}"
      elif [[ -x "${rel}" ]]; then
        printf '%s\texecutable\t' "${rel}"
        shasum -a 256 "${rel}" | awk '{print $1}'
      else
        printf '%s\tregular\t' "${rel}"
        shasum -a 256 "${rel}" | awk '{print $1}'
      fi
    done
  ) | shasum -a 256 | awk '{print $1}'
}
FIXTURE_HASH="$(tree_hash "${FIXTURE_DIR}")"
SOURCE_HASH="$(tree_hash "${FIXTURE_DIR}/source")"
MINIMAL_PROMPT_HASH="$(sha_text "$(jq -r '.prompt' "${MINIMAL_PROBE}")")"
MINIMAL_FIXTURE_DIR="${REPO_ROOT}/evals/realwork/fixtures/quality/minimal-change-control"
MINIMAL_FIXTURE_HASH="$(tree_hash "${MINIMAL_FIXTURE_DIR}")"
MINIMAL_SOURCE_HASH="$(tree_hash "${MINIMAL_FIXTURE_DIR}/source")"

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
cat > "${IDENTITY_SOURCE}/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
case "${MOCK_HARNESS_INSTALL_MODE:-valid}" in
  hang)
    while :; do sleep 30; done
    ;;
  spam)
    awk 'BEGIN {for (i = 0; i < 200000; i++) printf "x"}'
    ;;
  precreate-install-symlink)
    ln -s "${TARGET_HOME}" "${TARGET_HOME}/../install.log"
    ;;
  precreate-install-hardlink)
    printf 'attacker-owned install log\n' > "${TARGET_HOME}/attacker.log"
    ln "${TARGET_HOME}/attacker.log" "${TARGET_HOME}/../install.log"
    ;;
  precreate-install-fifo)
    mkfifo "${TARGET_HOME}/../install.log"
    ;;
  unexpected-root)
    printf 'unexpected installer node\n' > "${TARGET_HOME}/../unexpected-installer-node"
    ;;
  valid)
    mkdir -p "${TARGET_HOME}/.claude"
    printf '{}\n' > "${TARGET_HOME}/.claude/settings.json"
    ;;
esac
INSTALL
chmod +x "${IDENTITY_SOURCE}/install.sh"
git -C "${IDENTITY_SOURCE}" add harness.txt install.sh
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
IDENTITY_MANIFEST_HASH="$(jq -cS . "${IDENTITY_MANIFEST}" | shasum -a 256 | awk '{print $1}')"
PAIRWISE_COMPARE=(bash "${PAIRWISE}" compare
  --identity-manifest "${IDENTITY_MANIFEST}"
  --baseline-harness "${BASELINE_HARNESS}"
  --challenger-harness "${CHALLENGER_HARNESS}"
  --campaign-run "dev-run-win"
  --judge-model "judge-test-model-1")

candidate_package_manifest() {
  local probe="$1" artifact="$2" rows matches spec kind rel glob matched sha
  rows='[]'
  while IFS= read -r spec; do
    kind="$(jq -r '.kind' <<<"${spec}")"
    matches='[]'
    if [[ "${kind}" == "git_diff" ]]; then
      if [[ -s "${artifact}/.pairwise/git.diff" \
          && -s "${artifact}/.pairwise/changed-paths.json" ]]; then
        matches='[]'
        for rel in .pairwise/changed-paths.json .pairwise/git.diff; do
          sha="$(shasum -a 256 "${artifact}/${rel}" | awk '{print $1}')"
          matches="$(jq -cnS --argjson rows "${matches}" --arg path "${rel}" \
            --arg sha "${sha}" '$rows + [{path:$path,sha256:$sha}] | sort_by(.path)')"
        done
      fi
    else
      while IFS= read -r rel; do
        [[ -n "${rel}" ]] || continue
        rel="${rel#./}"
        [[ -f "${artifact}/${rel}" && ! -L "${artifact}/${rel}" && ! -p "${artifact}/${rel}" ]] || continue
        case "${rel}" in
          .pairwise/changed-paths.json|.pairwise/git.diff) continue ;;
          .pairwise|.pairwise/*) return 1 ;;
        esac
        matched=0
        while IFS= read -r glob; do
          # Mirror the production matcher against a probe-supplied glob.
          # shellcheck disable=SC2053
          [[ "${rel}" == ${glob} ]] && { matched=1; break; }
        done < <(jq -r '.globs[]' <<<"${spec}")
        [[ "${matched}" -eq 1 ]] || continue
        if [[ "${kind}" == "rendered_images" ]]; then
          case "${rel}" in *.png|*.jpg|*.jpeg|*.webp|*.gif) ;; *) continue ;; esac
        fi
        sha="$(shasum -a 256 "${artifact}/${rel}" | awk '{print $1}')"
        matches="$(jq -cnS --argjson rows "${matches}" --arg path "${rel}" --arg sha "${sha}" \
          '$rows + [{path:$path,sha256:$sha}] | sort_by(.path)')"
      done < <(cd "${artifact}" 2>/dev/null && find . -path './.git' -prune -o -type f -print | LC_ALL=C sort)
    fi
    rows="$(jq -cnS --argjson rows "${rows}" --arg kind "${kind}" \
      --argjson globs "$(jq -cS '.globs // []' <<<"${spec}")" --argjson matches "${matches}" \
      '$rows + [{kind:$kind,globs:$globs,matches:$matches}] | sort_by(.kind)')"
  done < <(jq -c '.candidate_artifacts[]' "${probe}")
  printf '%s\n' "${rows}"
}

write_generation_summary() {
  local output="$1" probe_file="$2" prompt_hash="$3" fixture_hash="$4" source_hash="$5"
  local artifact="$6" harness_hash="$7" cost="$8" wall="$9" input="${10}" output_tokens="${11}"
  local run_id="${SUMMARY_RUN_ID:-dev-run-win}" run_seed="${SUMMARY_SEED:-stable-seed}"
  local identity_manifest_hash="${SUMMARY_IDENTITY_MANIFEST_HASH:-${IDENTITY_MANIFEST_HASH}}"
  local probe_id probe_hash probe_authority bundled_probe_hash role commit tree policy
  local artifact_rel receipt_rel telemetry_rel receipt telemetry
  local session_id telemetry_hash artifact_hash packages generation_material generation_id receipt_hash
  local task_hash
  probe_id="$(jq -r '.id' "${probe_file}")"
  probe_hash="$(jq -cS . "${probe_file}" | shasum -a 256 | awk '{print $1}')"
  probe_authority="custom"
  if [[ -f "${REPO_ROOT}/evals/realwork/quality-probes/${probe_id}.json" ]]; then
    bundled_probe_hash="$(jq -cS . "${REPO_ROOT}/evals/realwork/quality-probes/${probe_id}.json" \
      | shasum -a 256 | awk '{print $1}')"
    [[ "${probe_hash}" != "${bundled_probe_hash}" ]] || probe_authority="canonical"
  fi
  role="challenger"; commit="${CHALLENGER_COMMIT}"; tree="${CHALLENGER_TREE}"; policy="explicit-checkout-descendant"
  if [[ "${harness_hash}" == "${BASELINE_HARNESS_HASH}" ]]; then
    role="baseline"; commit="${BASELINE_COMMIT}"; tree="${BASELINE_TREE}"; policy="manifest-pinned-commit-tree"
  fi
  artifact_rel="${artifact#${WORK}/}"
  receipt_rel="$(basename "${output}").generation.json"
  telemetry_rel="$(basename "${output}").telemetry.json"
  receipt="$(dirname "${output}")/${receipt_rel}"
  telemetry="$(dirname "${output}")/${telemetry_rel}"
  session_id="${SUMMARY_SESSION_ID:-session-$(basename "${output}" | tr -cd 'A-Za-z0-9')}"
  jq -nS --arg session "${session_id}" --arg model "claude-test-model-1" \
    --argjson cost "${cost}" --argjson input "${input}" --argjson output "${output_tokens}" '
      {type:"result",is_error:false,session_id:$session,model:$model,total_cost_usd:$cost,duration_ms:10,
       usage:{input_tokens:$input,output_tokens:$output,cache_read_input_tokens:500,cache_creation_input_tokens:50}}
    ' > "${telemetry}"
  telemetry_hash="$(jq -cS . "${telemetry}" | shasum -a 256 | awk '{print $1}')"
  if find "${artifact}" ! -type f ! -type d -print -quit 2>/dev/null | grep -q .; then
    artifact_hash="$(sha_text "unsafe-${artifact_rel}")"
  else
    artifact_hash="$(tree_hash "${artifact}" 2>/dev/null || sha_text "unsafe-${artifact_rel}")"
  fi
  packages="$(candidate_package_manifest "${probe_file}" "${artifact}" 2>/dev/null || printf '[]')"
  task_hash="$(producer_task_hash "${probe_file}")"
  generation_material="$(jq -nr --arg run "${run_id}" --arg role "${role}" --arg session "${session_id}" \
    --arg telemetry "${telemetry_hash}" --arg artifact "${artifact_hash}" --arg prompt "${prompt_hash}" \
    --arg probe_hash "${probe_hash}" --arg probe_authority "${probe_authority}" \
    --arg producer_task "${task_hash}" \
    --arg fixture "${fixture_hash}" --arg source "${source_hash}" --arg harness "${harness_hash}" \
    '[$run,$role,$session,$telemetry,$artifact,$probe_hash,$probe_authority,$prompt,$producer_task,"","",$fixture,$source,$harness,"claude-test-model-1","balanced"] | join("|")')"
  generation_id="$(sha_text "${generation_material}")"
  jq -nS --arg generation_id "${generation_id}" --arg probe_id "${probe_id}" --arg role "${role}" \
    --arg run_id "${run_id}" --arg seed "${run_seed}" --arg prompt "${prompt_hash}" \
    --arg producer_task "${task_hash}" \
    --arg probe_hash "${probe_hash}" --arg probe_authority "${probe_authority}" \
    --arg fixture "${fixture_hash}" --arg source "${source_hash}" --arg harness_hash "${harness_hash}" \
    --arg identity_manifest_hash "${identity_manifest_hash}" --arg identity_slug "${IDENTITY_SLUG}" \
    --arg producer_hash "$(sha_text mock-producer)" \
    --arg commit "${commit}" --arg tree "${tree}" --arg policy "${policy}" \
    --arg telemetry_rel "${telemetry_rel}" --arg telemetry_hash "${telemetry_hash}" \
    --arg session "${session_id}" --arg artifact_rel "${artifact_rel}" --arg artifact_hash "${artifact_hash}" \
    --argjson packages "${packages}" --argjson cost "${cost}" --argjson wall "${wall}" \
    --argjson input "${input}" --argjson output "${output_tokens}" '
      {
        schema_version:1,generation_id:$generation_id,receipt_hash:"",probe_id:$probe_id,harness_role:$role,
        campaign_run:{id:$run_id,probe_id:$probe_id,model_tier:"balanced",run_index:1,
          comparison_seed:$seed,candidate_model_id:"claude-test-model-1"},
        provenance:{probe_hash:$probe_hash,probe_authority:$probe_authority,
          prompt_hash:$prompt,producer_task_hash:$producer_task,
          campaign_policy_hash:null,campaign_instance_id:null,
          fixture_hash:$fixture,source_hash:$source,model:"claude-test-model-1",
          model_tier:"balanced",identity_authority:"custom",identity_manifest_hash:$identity_manifest_hash,
          harness_identity:{role:$role,repository_slug:$identity_slug,git_commit:$commit,git_tree:$tree,
            identity_hash:$harness_hash,checkout_policy:$policy}},
        producer:{authority:"custom",binary_name:"mock-producer",binary_sha256:$producer_hash,
          binary_version:"unattested",binary_location:"custom",requested_model:"claude-test-model-1",
          actual_model:"claude-test-model-1",session_id:$session,telemetry_path:$telemetry_rel,
          telemetry_hash:$telemetry_hash,exit_code:0,started_at_epoch:100,ended_at_epoch:(100+$wall),wall_seconds:$wall},
        economics:{cost_usd:$cost,wall_seconds:$wall,
          tokens:{input:$input,output:$output,cache_read:500,cache_creation:50},
          tokens_total:($input+$output+550)},
        artifact:{path:$artifact_rel,hash:$artifact_hash,packages:$packages}
      }
    ' > "${receipt}"
  receipt_hash="$(jq -cS 'del(.receipt_hash)' "${receipt}" | shasum -a 256 | awk '{print $1}')"
  jq --arg hash "${receipt_hash}" '.receipt_hash=$hash' "${receipt}" > "${receipt}.sealed"
  mv "${receipt}.sealed" "${receipt}"
  jq -nS --arg probe_id "${probe_id}" --arg receipt "${receipt_rel}" \
    --arg hash "${receipt_hash}" --arg artifact "${artifact_rel}" '
      {schema_version:4,probe_id:$probe_id,generation_receipt:$receipt,
       generation_receipt_hash:$hash,artifact_dir:$artifact}
    ' > "${output}"
}

make_summary() {
  local output="$1" artifact="$2" harness_hash="$3" fixture_hash="$4"
  local layered_ok="$5" cost="$6" wall="$7" input="$8" output_tokens="$9"
  write_generation_summary "${output}" "${PROBE}" "${PROMPT_HASH}" "${fixture_hash}" "${SOURCE_HASH}" \
    "${artifact}" "${harness_hash}" "${cost}" "${wall}" "${input}" "${output_tokens}"
}

make_probe_summary() {
  local output="$1" probe_id="$2" prompt_hash="$3" fixture_hash="$4" source_hash="$5"
  local artifact="$6" harness_hash="$7" cost="$8" wall="$9" probe_file
  probe_file="${REPO_ROOT}/evals/realwork/quality-probes/${probe_id}.json"
  write_generation_summary "${output}" "${probe_file}" "${prompt_hash}" "${fixture_hash}" "${source_hash}" \
    "${artifact}" "${harness_hash}" "${cost}" "${wall}" 100 50
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
printf '' > "${MOCK_LOG_DIR}/hang-pids.log"

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
if [[ ! -d INPUT ]] \
    || ! find INPUT -type f -print -quit 2>/dev/null | grep -q . \
    || [[ -e INPUT/manifest.json ]] \
    || [[ "${prompt}" != *"SOURCE_INPUT_HASH:"* ]]; then
  printf 'judge workspace lacks sealed neutral source input or leaks fixture authority\n' >&2
  exit 89
fi
expected_input_hash="$(printf '%s\n' "${prompt}" \
  | awk '/^SOURCE_INPUT_HASH:/ {print $2; exit}')"
observed_input_hash="$(
  cd INPUT || exit 1
  find . -print | LC_ALL=C sort | while IFS= read -r rel; do
    if [[ -d "${rel}" ]]; then
      printf '%s\tdirectory\n' "${rel}"
    elif [[ -x "${rel}" ]]; then
      printf '%s\texecutable\t' "${rel}"
      shasum -a 256 "${rel}" | awk '{print $1}'
    else
      printf '%s\tregular\t' "${rel}"
      shasum -a 256 "${rel}" | awk '{print $1}'
    fi
  done
)"
observed_input_hash="$(printf '%s\n' "${observed_input_hash}" \
  | shasum -a 256 | awk '{print $1}')"
if [[ "${observed_input_hash}" != "${expected_input_hash}" ]]; then
  printf 'judge workspace neutral source hash mismatch\n' >&2
  exit 90
fi

if [[ "${MOCK_MODE:-artifact}" == "mutate-isolated-view" ]]; then
  printf '\njudge mutation\n' >> A/work.txt
fi
if [[ "${MOCK_MODE:-artifact}" == "swap-durable-child" ]]; then
  [[ -n "${MOCK_PAIR_OUTPUT:-}" ]] || exit 91
  mv "${MOCK_PAIR_OUTPUT}/views/reverse" \
    "${MOCK_PAIR_OUTPUT}/views/reverse.displaced"
  ln -s "${MOCK_PAIR_OUTPUT}/candidates" \
    "${MOCK_PAIR_OUTPUT}/views/reverse"
fi
if [[ "${MOCK_MODE:-artifact}" == precreate-receipt-* ]]; then
  [[ -n "${MOCK_PAIR_OUTPUT:-}" ]] || exit 92
  case "${MOCK_MODE}" in
    precreate-receipt-symlink)
      ln -s "${MOCK_PAIR_OUTPUT}" "${MOCK_PAIR_OUTPUT}/receipt.json"
      ;;
    precreate-receipt-hardlink)
      ln "${MOCK_PAIR_OUTPUT}/probe.json" "${MOCK_PAIR_OUTPUT}/receipt.json"
      ;;
    precreate-receipt-fifo)
      mkfifo "${MOCK_PAIR_OUTPUT}/receipt.json"
      ;;
  esac
fi
if [[ "${MOCK_MODE:-artifact}" == "replace-pair-manifest" ]]; then
  [[ -n "${MOCK_PAIR_OUTPUT:-}" ]] || exit 93
  jq '.seed="judge-mutated-seed"' "${MOCK_PAIR_OUTPUT}/pair.json" \
    > "${MOCK_PAIR_OUTPUT}/pair.json.replacement"
  mv "${MOCK_PAIR_OUTPUT}/pair.json.replacement" "${MOCK_PAIR_OUTPUT}/pair.json"
fi
if [[ "${MOCK_MODE:-artifact}" == "replace-probe-manifest" ]]; then
  [[ -n "${MOCK_PAIR_OUTPUT:-}" ]] || exit 94
  cp "${MOCK_PAIR_OUTPUT}/probe.json" \
    "${MOCK_PAIR_OUTPUT}/probe.json.replacement"
  mv "${MOCK_PAIR_OUTPUT}/probe.json.replacement" \
    "${MOCK_PAIR_OUTPUT}/probe.json"
fi
if [[ "${MOCK_MODE:-artifact}" == "mutate-judge-binary" ]]; then
  printf '\n# judge self-mutation\n' >> "$0"
fi

if [[ "${MOCK_MODE:-artifact}" == "hang" ]]; then
  # Exit the wrapper immediately on TERM while leaving a child that only a
  # process-group timeout can reliably reap. A parent-then-pkill sequence races
  # with this trap and can orphan the child after reparenting.
  trap 'exit 143' TERM
  # The descendant deliberately ignores TERM. The timeout wrapper must not
  # stop its watchdog merely because this group leader exits on TERM; it must
  # finish the grace period and KILL the whole process group.
  bash -c 'trap "" TERM; while :; do sleep 30; done' &
  hang_pid=$!
  printf '%s\n' "${hang_pid}" >> "${MOCK_LOG_DIR}/hang-pids.log"
  wait "${hang_pid}"
fi
if [[ "${MOCK_MODE:-artifact}" == "oversized" ]]; then
  printf '%4096s' ''
  exit 0
fi

hash_a="$(printf '%s\n' "${prompt}" | awk '/^A_ARTIFACT_HASH:/ {print $2; exit}')"
hash_b="$(printf '%s\n' "${prompt}" | awk '/^B_ARTIFACT_HASH:/ {print $2; exit}')"
rubric="$(printf '%s\n' "${prompt}" | awk '/^RUBRIC_VERSION:/ {print $2; exit}')"

if [[ "${MOCK_MODE:-artifact}" == "large-valid" ]]; then
  large_workspace="$(mktemp -d -t omc-pairwise-large-judge-XXXXXX)"
  trap 'rm -rf "${large_workspace}"' EXIT
  awk 'BEGIN { for (i = 0; i < 230000; i++) printf "%c", 92 }' \
    > "${large_workspace}/reason.txt"
  if grep -q 'CRAFTED:' A/work.txt; then large_winner=A; else large_winner=B; fi
  jq -nc --rawfile reason "${large_workspace}/reason.txt" \
    --arg r "${rubric}" --arg a "${hash_a}" --arg b "${hash_b}" \
    --arg w "${large_winner}" '
      def d:{winner:$w,confidence:0.9,
        evidence:[{artifact:$w,path:"work.txt",observation:"concrete artifact evidence"}]};
      {rubric_version:$r,artifact_hashes:{A:$a,B:$b},
       dimensions:{deliberate:d,distinctive:d,coherent:d,visionary:d,complete:d},
       overall:{winner:$w,material:true,confidence:0.9,reason:$reason},
       scope_creep:{A:false,B:false},hard_quality_warning:[]}
    ' > "${large_workspace}/payload.json"
  jq -nc --rawfile result "${large_workspace}/payload.json" \
    --arg model "${MOCK_ACTUAL_MODEL:-judge-test-model-1}" \
    '{type:"result",is_error:false,total_cost_usd:0.01,duration_ms:10,
      model:$model,result:$result}'
  exit 0
fi

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
  mutate-isolated-view|swap-durable-child|precreate-receipt-*|replace-pair-manifest|replace-probe-manifest|mutate-judge-binary)
    winner=A; creep_a=false; creep_b=false
    ;;
  invalid)
    payload="$(jq -nc --arg r "${rubric}" --arg a "${hash_a}" --arg b "${hash_b}" '
      {rubric_version:$r, artifact_hashes:{A:$a,B:$b},
       dimensions:{
         deliberate:{winner:"A",confidence:0.8,evidence:[{artifact:"A",path:"work.txt",observation:"present"}]},
         distinctive:{winner:"A",confidence:0.8,evidence:[{artifact:"A",path:"work.txt",observation:"present"}]},
         coherent:{winner:"A",confidence:0.8,evidence:[{artifact:"A",path:"work.txt",observation:"present"}]},
         complete:{winner:"A",confidence:0.8,evidence:[{artifact:"A",path:"work.txt",observation:"present"}]}},
       overall:{winner:"A",material:true,confidence:0.8,reason:"missing visionary on purpose"},
       scope_creep:{A:false,B:false},hard_quality_warning:[]}'
    )"
    jq -nc --arg result "${payload}" --arg model "${MOCK_ACTUAL_MODEL:-judge-test-model-1}" \
      '{type:"result",is_error:false,total_cost_usd:0.01,duration_ms:10,model:$model,result:$result}'
    exit 0
    ;;
  *) winner=tie; creep_a=false; creep_b=false ;;
esac

evidence_artifact="${winner}"
[[ "${winner}" == "tie" ]] && evidence_artifact="both"
warnings='[]'
if [[ "${MOCK_WARNING:-}" == "blocking" ]]; then
  warnings="$(jq -nc --arg candidate "${evidence_artifact}" \
    '[{candidate:$candidate,severity:"blocking",path:"work.txt",reason:"specific blocking defect"}]')"
fi
payload="$(jq -nc \
  --arg r "${rubric}" --arg a "${hash_a}" --arg b "${hash_b}" --arg w "${winner}" \
  --arg evidence_artifact "${evidence_artifact}" \
  --argjson warnings "${warnings}" \
  --argjson creep_a "${creep_a}" --argjson creep_b "${creep_b}" '
  def d:{winner:$w,confidence:0.9,evidence:[{artifact:$evidence_artifact,path:"work.txt",observation:"concrete artifact evidence"}]};
  {rubric_version:$r,artifact_hashes:{A:$a,B:$b},
   dimensions:{deliberate:d,distinctive:d,coherent:d,visionary:d,complete:d},
   overall:{winner:$w,material:($w != "tie"),confidence:0.9,reason:"artifact-grounded preference"},
   scope_creep:{A:$creep_a,B:$creep_b},hard_quality_warning:$warnings}'
)"
jq -nc --arg result "${payload}" --arg model "${MOCK_ACTUAL_MODEL:-judge-test-model-1}" \
  '{type:"result",is_error:false,total_cost_usd:0.01,duration_ms:10,model:$model,result:$result}'
MOCK
chmod +x "${WORK}/mock-judge"

cat > "${WORK}/mock-producer" <<'PRODUCER'
#!/usr/bin/env bash
set -euo pipefail
model="" prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "${MOCK_PRODUCER_PROMPTS:-}" ]]; then
  printf '%s\n<<<END-PRODUCER-PROMPT>>>\n' "${prompt}" >> "${MOCK_PRODUCER_PROMPTS}"
fi
case "${MOCK_PRODUCER_MODE:-valid}" in
  valid|no-usage|ignored-untracked-empty|git-head-mutation|git-index-mutation|git-config-mutation|child-dir-swap|reserved-pairwise|unexpected-root|precreate-generation-symlink|precreate-generation-hardlink|precreate-generation-fifo|mutate-install-log|replace-producer-task|mutate-producer-binary)
    printf '%s\n' "${MOCK_PRODUCER_STYLE:-generated diagnostic} source provenance environment:APP_PORT; CLI compatible; exit code 2." > work.txt
    printf '%s\n' '{"status":"invalid_configuration","exit_code":2,"source":"environment:APP_PORT","raw_value":"eightythree","command":"config validate","stdout":""}' > diagnostic.json
    ;;
  missing-package)
    printf '\nchanged outside every declared output package\n' >> config-layers.txt
    ;;
esac
case "${MOCK_PRODUCER_MODE:-valid}" in
  ignored-untracked-empty)
    printf '%s\n' 'ignored-output.txt' > .gitignore
    printf '%s\n' 'ignored but evaluator-visible' > ignored-output.txt
    : > empty-output.txt
    ;;
  git-head-mutation)
    git config user.name "Producer Mutation"
    git config user.email producer@example.invalid
    git add -A
    git commit -qm producer-rebased-baseline
    ;;
  git-index-mutation)
    git add work.txt
    ;;
  git-config-mutation)
    git config pairwise.producer-mutated true
    ;;
  child-dir-swap)
    mv ../telemetry ../telemetry.displaced
    ln -s "${PWD}" ../telemetry
    ;;
  reserved-pairwise)
    mkdir -p .pairwise/nested
    printf '%s\n' 'candidate-authored patch must never be published' > .pairwise/git.diff
    printf '%s\n' '{"schema_version":1,"paths":["work.txt"]}' \
      > .pairwise/changed-paths.json
    printf '%s\n' 'candidate-authored reserved payload' > .pairwise/nested/producer.txt
    ;;
  unexpected-root)
    printf 'unexpected producer node\n' > ../unexpected-producer-node
    ;;
  precreate-generation-symlink)
    ln -s "${PWD}" ../generation.json
    ;;
  precreate-generation-hardlink)
    ln work.txt ../generation.json
    ;;
  precreate-generation-fifo)
    mkfifo ../generation.json
    ;;
  mutate-install-log)
    printf 'producer-mutated install audit\n' >> ../install.log
    ;;
  replace-producer-task)
    cp ../producer-task.prompt.txt ../producer-task.prompt.txt.replacement
    mv ../producer-task.prompt.txt.replacement ../producer-task.prompt.txt
    ;;
  mutate-producer-binary)
    printf '\n# producer self-mutation\n' >> "$0"
    ;;
esac
sleep "${MOCK_PRODUCER_SLEEP:-0}"
if [[ "${MOCK_PRODUCER_MODE:-valid}" == "no-usage" ]]; then
  jq -nS --arg session "${MOCK_PRODUCER_SESSION}" --arg model "${model}" \
    '{type:"result",is_error:false,session_id:$session,model:$model,total_cost_usd:1,duration_ms:10}'
else
  jq -nS --arg session "${MOCK_PRODUCER_SESSION}" --arg model "${model}" \
    --argjson cost "${MOCK_PRODUCER_COST:-1}" '
      {type:"result",is_error:false,session_id:$session,model:$model,total_cost_usd:$cost,duration_ms:10,
       usage:{input_tokens:100,output_tokens:50,cache_read_input_tokens:20,cache_creation_input_tokens:10}}
    '
fi
PRODUCER
chmod +x "${WORK}/mock-producer"

printf 'T1: shipped schemas and quality probes validate\n'
out="$(bash "${PAIRWISE}" validate)"
assert_contains "T1: six-domain quality portfolio" "Validated 6 quality probe(s)" "${out}"
assert_eq "T1: judge schema requires visionary" "true" \
  "$(jq -r '.properties.dimensions.required | index("visionary") != null' "${REPO_ROOT}/evals/realwork/judge-schema.json")"
assert_eq "T1: candidate schema requires evaluator-owned causal generation" "true" \
  "$(jq -r '
    .properties.schema_version.const == 2
    and .properties.campaign.properties.candidate_summary_contract.properties.schema_version.const == 4
    and .properties.rubric.properties.dimensions.items.properties.weight.const == 1
    and (.properties.campaign.properties.candidate_summary_contract.properties.required_top_level.const
      == ["schema_version","probe_id","generation_receipt","generation_receipt_hash","artifact_dir"])
    and .properties.campaign.properties.candidate_summary_contract.properties.generation_authority.const
      == "evaluator-owned-cli-telemetry-v1"
  ' "${REPO_ROOT}/evals/realwork/quality-schema.json")"
assert_eq "T1: canonical manifest seals judge location, version, and pinned model" "true" \
  "$(jq -r '
    .judge.binary_name == "claude"
    and (.judge.binary_sha256 | test("^[0-9a-f]{64}$"))
    and .judge.install_location == "user-local-bin"
    and (.judge.cli_version | test("^[0-9]+[.][0-9]+[.][0-9]+$"))
    and .judge.model_id == "claude-opus-4-8"
    and (.judge.calibration_manifest_sha256 | test("^[0-9a-f]{64}$"))
  ' "${REPO_ROOT}/evals/realwork/harness-identities.json")"
calibration_hash="$(jq -cS . "${REPO_ROOT}/evals/realwork/judge-calibration/cases.json" \
  | shasum -a 256 | awk '{print $1}')"
assert_eq "T1: judge identity binds the exact calibration contract" \
  "${calibration_hash}" \
  "$(jq -r '.judge.calibration_manifest_sha256' \
    "${REPO_ROOT}/evals/realwork/harness-identities.json")"
assert_eq "T1: calibration contract freezes all four expected controls" "true" \
  "$(jq -r '
    (.cases | length) == 4
    and ([.cases[].id] | sort) == [
      "broken-but-flashy","identical-artifacts",
      "material-quality-gain","visionary-overreach"]
    and any(.cases[]; .id == "identical-artifacts"
      and .expected == {basis:"identical-artifact",winner:"tie",judge_calls:0})
    and any(.cases[]; .id == "broken-but-flashy"
      and .expected == {basis:"hard-check-veto",winner:"baseline",judge_calls:0})
    and any(.cases[]; .id == "visionary-overreach"
      and .expected == {basis:"judge",winner:"baseline",scope_creep:{challenger:true}})
    and any(.cases[]; .id == "material-quality-gain"
      and .expected == {basis:"judge",winner:"challenger",position_consistent:true})
  ' "${REPO_ROOT}/evals/realwork/judge-calibration/cases.json")"
assert_eq "T1: canonical campaign commits the exact candidate model and 36-run roster" "true" \
  "$(jq -r '
    .schema_version == 2
    and .portfolio.candidate_model_id == "claude-opus-4-8"
    and (.portfolio.runs | length) == 36
    and ([.portfolio.runs[].id] | unique | length) == 36
    and ([.portfolio.runs[].comparison_seed] | unique | length) == 36
    and ([.portfolio.runs[] | [.probe_id,.model_tier,.run_index]] | unique | length) == 36
    and ([.portfolio.runs[] | select(.model_tier == "balanced")] | length) == 18
    and ([.portfolio.runs[] | select(.model_tier == "economy")] | length) == 18
    and all(.portfolio.runs[]; .run_index >= 1 and .run_index <= 3)
  ' "${REPO_ROOT}/evals/realwork/harness-identities.json")"
schema_validator="portable live validator"
if python3 -c 'from jsonschema import Draft202012Validator' >/dev/null 2>&1; then
  schema_validator="real Draft 2020-12 schema"
  schema_validation="$(python3 - "${REPO_ROOT}/evals/realwork" <<'PY'
import json
import pathlib
import sys
from jsonschema import Draft202012Validator, ValidationError

root = pathlib.Path(sys.argv[1])
schema = json.loads((root / "quality-schema.json").read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
validated = 0
for probe in sorted((root / "quality-probes").glob("*.json")):
    validator.validate(json.loads(probe.read_text()))
    validated += 1
sample_probe = json.loads((root / "quality-probes" / "quality-config-diagnostics.json").read_text())
sample_probe["candidate_artifacts"][1]["globs"][0] = "work\x7f.txt"
try:
    validator.validate(sample_probe)
except ValidationError:
    pass
else:
    raise SystemExit("quality schema accepted a DEL byte in an artifact glob")
for reserved_path in (".pairwise", ".pairwise/*", ".pairwise/nested/**"):
    sample_probe = json.loads((root / "quality-probes" / "quality-config-diagnostics.json").read_text())
    sample_probe["candidate_artifacts"][1]["globs"][0] = reserved_path
    try:
        validator.validate(sample_probe)
    except ValidationError:
        pass
    else:
        raise SystemExit(f"quality schema accepted evaluator-reserved artifact glob {reserved_path!r}")
for overlapping_glob in (".pairwis?/*", ".pairwise*/*", "*/*", "**/*"):
    sample_probe = json.loads((root / "quality-probes" / "quality-config-diagnostics.json").read_text())
    sample_probe["candidate_artifacts"][1]["globs"][0] = overlapping_glob
    validator.validate(sample_probe)
judge_schema = json.loads((root / "judge-schema.json").read_text())
Draft202012Validator.check_schema(judge_schema)
for definition, payload in (
    ("evidence", {"artifact": "A", "path": "work\x7f.txt", "observation": "bad path"}),
    ("hard_quality_warning", {"candidate": "A", "severity": "blocking", "path": "work\x7f.txt", "reason": "bad path"}),
):
    try:
        Draft202012Validator(judge_schema["$defs"][definition]).validate(payload)
    except ValidationError:
        pass
    else:
        raise SystemExit(f"judge schema accepted a DEL byte in {definition}")
print(validated)
PY
)"
else
  # The evaluator's jq validator already accepted each probe above. CI also
  # runs the standards validator after installing python3-jsonschema, while
  # this offline test remains runnable on minimal developer machines.
  schema_validation="$(find "${REPO_ROOT}/evals/realwork/quality-probes" \
    -maxdepth 1 -type f -name '*.json' | wc -l | tr -d '[:space:]')"
fi
assert_eq "T1: ${schema_validator} accepts every shipped probe" "6" "${schema_validation}"
assert_eq "T1: schema path contracts reject controls and the reserved namespace" "true" \
  "$(jq -n --slurpfile quality "${REPO_ROOT}/evals/realwork/quality-schema.json" \
    --slurpfile judge "${REPO_ROOT}/evals/realwork/judge-schema.json" '
      ($quality[0].properties.candidate_artifacts.items.properties.globs.items.pattern
        | contains("\\u0000-\\u001f\\u007f"))
      and ($quality[0].properties.candidate_artifacts.items.properties.globs.items.pattern
        | contains("(?!\\.pairwise(?:/|$))"))
      and ($judge[0]["$defs"].evidence.properties.path.pattern
        | contains("\\u0000-\\u001f\\u007f"))
      and ($judge[0]["$defs"].hard_quality_warning.properties.path.pattern
        | contains("\\u0000-\\u001f\\u007f"))
  ')"
DEL_PROBE="${WORK}/probe-del-control.json"
jq --arg path "work"$'\177'".txt" \
  '.candidate_artifacts[1].globs[0] = $path' "${PROBE}" > "${DEL_PROBE}"
rc=0; del_probe_out="$(bash "${PAIRWISE}" validate "${DEL_PROBE}" 2>&1)" || rc=$?
assert_eq "T1: live probe validator rejects DEL in artifact paths" "2" "${rc}"
assert_contains "T1: live and schema path contracts fail closed together" \
  "invalid quality probe" "${del_probe_out}"
NUL_PROBE="${WORK}/probe-nul-nested-string.json"
jq '.rubric.task_specific_anchors[0] += "\u0000normalized-suffix"' \
  "${PROBE}" > "${NUL_PROBE}"
rc=0; nul_probe_out="$(bash "${PAIRWISE}" validate "${NUL_PROBE}" 2>&1)" || rc=$?
assert_eq "T1: live probe validator rejects decoded NUL recursively" "2" "${rc}"
assert_contains "T1: nested NUL fails before rubric projection" \
  "invalid quality probe" "${nul_probe_out}"
NUL_SUMMARY="${WORK}/summary-nul-probe-id.json"
jq -n '
  {schema_version:4,probe_id:("quality-config-diagnostics" + "\u0000"),
   generation_receipt:"generation.json",
   generation_receipt_hash:("a" * 64),artifact_dir:"artifact"}
' > "${NUL_SUMMARY}"
rc=0; bash -c '
  source "$1"
  candidate_summary_is_valid "$2"
' pairwise-nul-summary "${PAIRWISE}" "${NUL_SUMMARY}" || rc=$?
assert_eq "T1: candidate wrapper rejects NUL-bearing probe identity" "1" "${rc}"

NUL_FIXTURE="${WORK}/fixture-control-manifest"
cp -R "${REPO_ROOT}/evals/realwork/$(jq -r '.fixture' "${PROBE}")" \
  "${NUL_FIXTURE}"
jq '.checks[0].rules += [{
      type:"file_contains_all",
      path:"diagnostic.json",
      values:["first-projected-rule\nsecond-projected-rule"]
    }]' \
  "${NUL_FIXTURE}/manifest.json" > "${NUL_FIXTURE}/manifest.json.tmp"
mv "${NUL_FIXTURE}/manifest.json.tmp" "${NUL_FIXTURE}/manifest.json"
rc=0; bash -c '
  source "$1"
  fixture_manifest_is_valid "$2" "$3"
' pairwise-control-fixture "${PAIRWISE}" "${PROBE}" "${NUL_FIXTURE}" || rc=$?
assert_eq "T1: fixture values reject line-splitting controls" "1" "${rc}"

PRODUCER_NUL_SESSION="${WORK}/producer-nul-session.json"
jq -n '{is_error:false,session_id:("producer-valid" + "\u0000"),
  model:"claude-test-model-1"}' > "${PRODUCER_NUL_SESSION}"
rc=0; bash -c '
  source "$1"
  producer_telemetry_identity_is_valid "$2" claude-test-model-1
' pairwise-producer-nul-session "${PAIRWISE}" "${PRODUCER_NUL_SESSION}" || rc=$?
assert_eq "T1: producer telemetry rejects NUL-bearing session identity" "1" "${rc}"
PRODUCER_NUL_MODEL="${WORK}/producer-nul-model.json"
jq -n '{is_error:false,session_id:"producer-valid",
  model:("claude-test-model-1" + "\u0000")}' > "${PRODUCER_NUL_MODEL}"
rc=0; bash -c '
  source "$1"
  producer_telemetry_identity_is_valid "$2" claude-test-model-1
' pairwise-producer-nul-model "${PAIRWISE}" "${PRODUCER_NUL_MODEL}" || rc=$?
assert_eq "T1: producer telemetry rejects NUL-bearing model identity" "1" "${rc}"
JUDGE_NUL_MODEL="${WORK}/judge-nul-model.json"
jq -n '{is_error:false,model:("judge-test-model-1" + "\u0000")}' \
  > "${JUDGE_NUL_MODEL}"
rc=0; bash -c '
  source "$1"
  judge_telemetry_identity_is_valid "$2" judge-test-model-1
' pairwise-judge-nul-model "${PAIRWISE}" "${JUDGE_NUL_MODEL}" || rc=$?
assert_eq "T1: judge telemetry rejects NUL-bearing model identity" "1" "${rc}"
reserved_probe_index=0
for reserved_path in '.pairwise' '.pairwise/*' '.pairwise/nested/**'; do
  reserved_probe_index=$((reserved_probe_index + 1))
  reserved_probe="${WORK}/probe-reserved-${reserved_probe_index}.json"
  jq --arg path "${reserved_path}" \
    '(.candidate_artifacts[] | select(.kind == "files") | .globs[0]) = $path' \
    "${PROBE}" > "${reserved_probe}"
  rc=0; reserved_probe_out="$(bash "${PAIRWISE}" validate "${reserved_probe}" 2>&1)" || rc=$?
  assert_eq "T1: live probe validator rejects reserved glob ${reserved_path}" "2" "${rc}"
  assert_contains "T1: reserved glob ${reserved_path} fails as an invalid probe" \
    "invalid quality probe" "${reserved_probe_out}"
done
overlapping_probe_index=0
for overlapping_glob in '.pairwis?/*' '.pairwise*/*' '*/*' '**/*'; do
  overlapping_probe_index=$((overlapping_probe_index + 1))
  overlapping_probe="${WORK}/probe-overlapping-${overlapping_probe_index}.json"
  jq --arg path "${overlapping_glob}" \
    '(.candidate_artifacts[] | select(.kind == "files") | .globs[0]) = $path' \
    "${PROBE}" > "${overlapping_probe}"
  rc=0; bash "${PAIRWISE}" validate "${overlapping_probe}" >/dev/null 2>&1 || rc=$?
  assert_eq "T1: validator preserves legitimate broad glob ${overlapping_glob}" "0" "${rc}"
done
assert_eq "T1: only deterministic structural checks retain veto authority" "true" \
  "$(jq -s -r '
    ([.[] | .hard_checks[] | select(.critical == true) | .id] | sort)
      == ["behavior_unchanged", "scope_bounded"]
  ' "${REPO_ROOT}"/evals/realwork/quality-probes/*.json)"
assert_eq "T1: canonical campaign pins one exact pre-feature commit and tree" "true" \
  "$(jq -r '
    .campaign_id == "definition-of-excellent-v1"
    and (.baseline.git_commit | test("^[0-9a-f]{40}$"))
    and (.baseline.git_tree | test("^[0-9a-f]{40}$"))
    and .baseline.boundary == "committed task-start source before Definition-of-Excellent implementation"
    and (.baseline.absent_paths == .challenger.required_paths)
    and .challenger.policy == "evaluator-checkout-descendant"
  ' "${REPO_ROOT}/evals/realwork/harness-identities.json")"
campaign_docs="$(cat "${REPO_ROOT}/evals/realwork/README.md")"
assert_contains "T1: documented campaign root is external temporary storage" \
  'CAMPAIGN_ROOT="$(mktemp -d /tmp/omc-quality-campaign.XXXXXX)"' "${campaign_docs}"
assert_not_contains "T1: documented compare output is not inside challenger checkout" \
  '--out campaign/' "${campaign_docs}"
workflow="$(cat "${REPO_ROOT}/.github/workflows/validate.yml")"
assert_contains "T1: CI syntax-checks the top-level evaluator" \
  'bash -n evals/realwork/pairwise.sh' "${workflow}"
assert_contains "T1: CI shellchecks the top-level evaluator" \
  'shellcheck -x --severity=warning evals/realwork/pairwise.sh' "${workflow}"
assert_contains "T1: CI runs canonical campaign/schema validation" \
  'bash evals/realwork/pairwise.sh validate' "${workflow}"

source_trap_marker="${WORK}/source-trap-marker"
source_trap_result="$(bash -c '
  marker="$2"
  trap '\''printf "caller trap preserved\\n" > "${marker}"'\'' EXIT
  before="$(trap -p EXIT INT TERM HUP)"
  source "$1"
  after="$(trap -p EXIT INT TERM HUP)"
  [[ "${before}" == "${after}" ]] && printf true || printf false
' pairwise-source-trap "${PAIRWISE}" "${source_trap_marker}")"
assert_eq "T1: sourcing the CLI preserves the caller EXIT trap" "true" \
  "${source_trap_result}"
assert_eq "T1: the preserved caller EXIT trap still executes" \
  "caller trap preserved" "$(tr -d '\n' < "${source_trap_marker}")"

TAMPERED_CALIBRATION_IDENTITY="${WORK}/tampered-calibration-identity.json"
jq '.judge.calibration_manifest_sha256 = ("0" * 64)' \
  "${REPO_ROOT}/evals/realwork/harness-identities.json" \
  > "${TAMPERED_CALIBRATION_IDENTITY}"
rc=0
bash -c 'source "$1"; identity_manifest_is_valid "$2"' \
  pairwise-calibration-binding "${PAIRWISE}" "${TAMPERED_CALIBRATION_IDENTITY}" \
  >/dev/null 2>&1 || rc=$?
assert_eq "T1: identity validation rejects a substituted calibration digest" "1" "${rc}"

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

printf 'T2a: decorative non-unit rubric weights are rejected\n'
jq '.rubric.dimensions[0].weight = 2' "${PROBE}" > "${WORK}/nonunit-weight-probe.json"
rc=0; invalid_out="$(bash "${PAIRWISE}" validate "${WORK}/nonunit-weight-probe.json" 2>&1)" || rc=$?
assert_eq "T2a: non-unit weight exits 2" "2" "${rc}"
assert_contains "T2a: non-unit weight is an invalid probe" "invalid quality probe" "${invalid_out}"

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

printf 'T2c2: canonical evidence rejects a same-ID substituted full probe rubric\n'
jq '.rubric.task_specific_anchors[0] += " Substituted after policy sealing."' \
  "${PROBE}" > "${WORK}/same-id-substituted-probe.json"
assert_eq "T2c2: substitution preserves ID, task prompt, rubric version, and budgets" "true" \
  "$(jq -n --slurpfile canonical "${PROBE}" \
    --slurpfile substituted "${WORK}/same-id-substituted-probe.json" '
      $canonical[0].id == $substituted[0].id
      and $canonical[0].prompt == $substituted[0].prompt
      and $canonical[0].rubric.version == $substituted[0].rubric.version
      and $canonical[0].campaign == $substituted[0].campaign
      and $canonical[0].rubric.task_specific_anchors != $substituted[0].rubric.task_specific_anchors
    ')"
assert_eq "T2c2: full canonical probe hashes distinguish the substitution" "false" \
  "$([[ "$(jq -cS . "${PROBE}" | shasum -a 256 | awk '{print $1}')" \
        == "$(jq -cS . "${WORK}/same-id-substituted-probe.json" | shasum -a 256 | awk '{print $1}')" ]] \
      && printf true || printf false)"
rc=0; substituted_probe_out="$(bash "${PAIRWISE}" generate \
  --identity-manifest "${REPO_ROOT}/evals/realwork/harness-identities.json" \
  --probe "${WORK}/same-id-substituted-probe.json" \
  --harness-role baseline --harness "${BASELINE_HARNESS}" \
  --campaign-run quality-config-diagnostics-balanced-01 \
  --out "${WORK}/canonical-substituted-generation" 2>&1)" || rc=$?
assert_eq "T2c2: canonical substituted generation exits 2" "2" "${rc}"
assert_contains "T2c2: exact bundled full-probe authority is explicit" \
  "canonical generation requires the exact bundled quality probe" "${substituted_probe_out}"
SUMMARY_RUN_ID=dev-substituted-probe SUMMARY_SEED=substituted-seed \
  SUMMARY_SESSION_ID=substituted-probe-baseline \
  write_generation_summary "${WORK}/substituted-baseline.json" \
    "${WORK}/same-id-substituted-probe.json" "${PROMPT_HASH}" "${FIXTURE_HASH}" "${SOURCE_HASH}" \
    "${WORK}/artifacts/generic" "${BASELINE_HARNESS_HASH}" 1 100 100 50
SUMMARY_RUN_ID=dev-substituted-probe SUMMARY_SEED=substituted-seed \
  SUMMARY_SESSION_ID=substituted-probe-challenger \
  write_generation_summary "${WORK}/substituted-challenger.json" \
    "${WORK}/same-id-substituted-probe.json" "${PROMPT_HASH}" "${FIXTURE_HASH}" "${SOURCE_HASH}" \
    "${WORK}/artifacts/crafted" "${CHALLENGER_HARNESS_HASH}" 1.5 120 180 110
substituted_development_receipt="$(bash "${PAIRWISE}" compare \
  --identity-manifest "${IDENTITY_MANIFEST}" \
  --baseline-harness "${BASELINE_HARNESS}" --challenger-harness "${CHALLENGER_HARNESS}" \
  --campaign-run dev-substituted-probe --judge-model judge-test-model-1 \
  --probe "${WORK}/same-id-substituted-probe.json" \
  --baseline "${WORK}/substituted-baseline.json" \
  --challenger "${WORK}/substituted-challenger.json" \
  --out "${WORK}/pair-substituted-development" --judge-bin "${WORK}/mock-judge")"
substituted_development_report="$(bash "${PAIRWISE}" report "${substituted_development_receipt}")"
assert_eq "T2c2: substituted probes remain explicit custom development evidence" "true" \
  "$(jq -r '
    .probe_identity.authorities == ["custom"]
    and .probe_identity.bindings[0].probe_id == "quality-config-diagnostics"
    and .probe_identity.bindings[0].authority == "custom"
  ' <<<"${substituted_development_report}")"
rc=0; substituted_claim_out="$(bash "${PAIRWISE}" claim-check \
  "${substituted_development_receipt}" 2>&1)" || rc=$?
assert_eq "T2c2: substituted development evidence cannot satisfy release claims" "1" "${rc}"
assert_contains "T2c2: release claim rejects custom full-probe authority" \
  "canonical_probe_authority" "${substituted_claim_out}"

printf 'T2d: evaluator-owned generation seals run, session, telemetry, packages, and economics\n'
: > "${WORK}/producer-prompts.log"
ln -s "${WORK}/mock-producer" "${WORK}/mock-producer-link"
rc=0; symlink_producer_out="$(bash "${PAIRWISE}" generate \
  --identity-manifest "${IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
  --harness-role baseline --harness "${BASELINE_HARNESS}" \
  --campaign-run symlink-producer-run --candidate-model claude-test-model-1 \
  --model-tier balanced --seed symlink-producer-seed --skip-harness-install \
  --producer-bin "${WORK}/mock-producer-link" \
  --out "${WORK}/generated-symlink-producer" 2>&1)" || rc=$?
assert_eq "T2d: symlinked producer binary exits 2" "2" "${rc}"
assert_contains "T2d: producer requires one regular executable identity" \
  "producer binary not found or not a regular executable" "${symlink_producer_out}"
generated_baseline="$(MOCK_PRODUCER_SESSION=producer-baseline-001 MOCK_PRODUCER_COST=1 \
  MOCK_PRODUCER_PROMPTS="${WORK}/producer-prompts.log" \
  MOCK_PRODUCER_STYLE=baseline MOCK_PRODUCER_SLEEP=1 \
  bash "${PAIRWISE}" generate \
    --identity-manifest "${IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
    --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run generated-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed generated-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer" --out "${WORK}/generated-baseline")"
generated_challenger="$(MOCK_PRODUCER_SESSION=producer-challenger-001 MOCK_PRODUCER_COST=1.2 \
  MOCK_PRODUCER_PROMPTS="${WORK}/producer-prompts.log" \
  MOCK_PRODUCER_STYLE=challenger MOCK_PRODUCER_SLEEP=1 \
  bash "${PAIRWISE}" generate \
    --identity-manifest "${IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
    --harness-role challenger --harness "${CHALLENGER_HARNESS}" \
    --campaign-run generated-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed generated-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer" --out "${WORK}/generated-challenger")"
assert_eq "T2d: summary is pointer-only schema v4" "true" \
  "$(jq -r '.schema_version == 4 and (keys | sort) == ["artifact_dir","generation_receipt","generation_receipt_hash","probe_id","schema_version"]' "${generated_baseline}")"
assert_eq "T2d: receipt binds exact producer session and raw-derived economics" "true" \
  "$(jq -r '
    .campaign_run.id == "generated-run"
    and .producer.session_id == "producer-baseline-001"
    and .producer.authority == "custom"
    and .economics.cost_usd == 1
    and .economics.tokens == {input:100,output:50,cache_read:20,cache_creation:10}
    and .economics.tokens_total == 180
    and (.producer.telemetry_hash | test("^[0-9a-f]{64}$"))
    and ([.artifact.packages[].kind] | sort) == ["files","git_diff"]
    and ([.artifact.packages[] | select(.kind == "git_diff") | .matches[].path]
      == [".pairwise/changed-paths.json", ".pairwise/git.diff"])
    and (.provenance.producer_task_hash | test("^[0-9a-f]{64}$"))
  ' "${WORK}/generated-baseline/generation.json")"
RESERVED_RECEIPT_GLOB="${WORK}/generation-reserved-glob.json"
jq '(.artifact.packages[] | select(.kind == "files") | .globs[0]) = ".pairwise/*"' \
  "${WORK}/generated-baseline/generation.json" > "${RESERVED_RECEIPT_GLOB}"
rc=0; bash -c '
  source "$1"
  embedded_generation_receipt_is_valid "$2"
' pairwise-reserved-receipt-glob "${PAIRWISE}" "${RESERVED_RECEIPT_GLOB}" || rc=$?
assert_eq "T2d: embedded generation receipts reject reserved non-git globs" "1" "${rc}"
RESERVED_RECEIPT_MATCH="${WORK}/generation-reserved-match.json"
jq '(.artifact.packages[] | select(.kind == "files") | .matches[0].path) = ".pairwise/producer.txt"' \
  "${WORK}/generated-baseline/generation.json" > "${RESERVED_RECEIPT_MATCH}"
rc=0; bash -c '
  source "$1"
  embedded_generation_receipt_is_valid "$2"
' pairwise-reserved-receipt-match "${PAIRWISE}" "${RESERVED_RECEIPT_MATCH}" || rc=$?
assert_eq "T2d: embedded generation receipts reject reserved non-git matches" "1" "${rc}"
assert_contains "T2d: both arms see declared filenames" '"globs": [' \
  "$(cat "${WORK}/producer-prompts.log")"
assert_contains "T2d: both arms see evaluator-owned diagnostics" \
  'acceptance_diagnostics' "$(cat "${WORK}/producer-prompts.log")"
assert_eq "T2d: baseline and challenger bind the identical visible task contract" \
  "$(jq -r '.provenance.producer_task_hash' "${WORK}/generated-baseline/generation.json")" \
  "$(jq -r '.provenance.producer_task_hash' "${WORK}/generated-challenger/generation.json")"
generated_scope="$(MOCK_PRODUCER_SESSION=producer-scope-001 \
  MOCK_PRODUCER_MODE=ignored-untracked-empty \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run scope-capture-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed scope-capture-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer" --out "${WORK}/generated-scope-capture")"
assert_eq "T2d: evaluator index includes ignored, untracked, and empty changed files" "true" \
  "$(jq -r '
    .schema_version == 1
    and .paths == ([".gitignore","diagnostic.json","empty-output.txt","ignored-output.txt","work.txt"] | sort)
  ' "${WORK}/generated-scope-capture/artifact/.pairwise/changed-paths.json")"
assert_contains "T2d: ignored file bytes are retained in evaluator-owned patch" \
  "ignored but evaluator-visible" \
  "$(cat "${WORK}/generated-scope-capture/artifact/.pairwise/git.diff")"
for mutation_mode in git-head-mutation git-index-mutation git-config-mutation; do
  rc=0
  mutation_out="$(MOCK_PRODUCER_SESSION="producer-${mutation_mode}" \
    MOCK_PRODUCER_MODE="${mutation_mode}" \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
      --campaign-run "${mutation_mode}-run" --candidate-model claude-test-model-1 \
      --model-tier balanced --seed "${mutation_mode}-seed" --skip-harness-install \
      --producer-bin "${WORK}/mock-producer" \
      --out "${WORK}/generated-${mutation_mode}" 2>&1)" || rc=$?
  assert_eq "T2d: ${mutation_mode} exits 2" "2" "${rc}"
  assert_contains "T2d: ${mutation_mode} cannot redefine evaluator Git identity" \
    "producer modified the evaluator-owned Git" "${mutation_out}"
done
RESERVED_GENERATION_OUT="${WORK}/generated-reserved-pairwise"
rc=0; reserved_generation_out="$(MOCK_PRODUCER_SESSION=producer-reserved-pairwise \
  MOCK_PRODUCER_MODE=reserved-pairwise \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run reserved-pairwise-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed reserved-pairwise-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer" \
    --out "${RESERVED_GENERATION_OUT}" 2>&1)" || rc=$?
assert_eq "T2d: producer-authored reserved namespace exits 2" "2" "${rc}"
assert_contains "T2d: reserved producer paths are rejected before packaging" \
  "evaluator-reserved .pairwise namespace" "${reserved_generation_out}"
assert_eq "T2d: candidate-authored managed files are never overwritten or published" "false" \
  "$([[ -e "${RESERVED_GENERATION_OUT}/artifact/.pairwise" \
        || -L "${RESERVED_GENERATION_OUT}/artifact/.pairwise" ]] \
      && printf true || printf false)"
rc=0; generation_child_swap_out="$(MOCK_PRODUCER_SESSION=producer-child-swap \
  MOCK_PRODUCER_MODE=child-dir-swap \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run child-swap-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed child-swap-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer" \
    --out "${WORK}/generated-child-swap" 2>&1)" || rc=$?
assert_eq "T2d: producer child-directory swap exits 2" "2" "${rc}"
assert_contains "T2d: stable output-root inode cannot hide a swapped telemetry child" \
  "replaced an evaluator-owned generation child directory" \
  "${generation_child_swap_out}"
for producer_boundary_mode in unexpected-root precreate-generation-symlink \
    precreate-generation-hardlink precreate-generation-fifo; do
  producer_boundary_out_dir="${WORK}/generated-${producer_boundary_mode}"
  rc=0; producer_boundary_out="$(MOCK_PRODUCER_SESSION="producer-${producer_boundary_mode}" \
    MOCK_PRODUCER_MODE="${producer_boundary_mode}" \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
      --campaign-run "${producer_boundary_mode}-run" --candidate-model claude-test-model-1 \
      --model-tier balanced --seed "${producer_boundary_mode}-seed" --skip-harness-install \
      --producer-bin "${WORK}/mock-producer" --out "${producer_boundary_out_dir}" \
      2>&1)" || rc=$?
  assert_eq "T2d: producer ${producer_boundary_mode} package mutation exits 2" "2" "${rc}"
  assert_contains "T2d: producer ${producer_boundary_mode} violates exact root inventory" \
    "unexpected evaluator-package node" "${producer_boundary_out}"
  assert_eq "T2d: producer ${producer_boundary_mode} cannot publish a summary" "false" \
    "$([[ -e "${producer_boundary_out_dir}/summary.json" ]] && printf true || printf false)"
done
for producer_file_mutation in mutate-install-log replace-producer-task; do
  rc=0; producer_file_mutation_out="$(MOCK_PRODUCER_SESSION="producer-${producer_file_mutation}" \
    MOCK_PRODUCER_MODE="${producer_file_mutation}" \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
      --campaign-run "${producer_file_mutation}-run" --candidate-model claude-test-model-1 \
      --model-tier balanced --seed "${producer_file_mutation}-seed" --skip-harness-install \
      --producer-bin "${WORK}/mock-producer" \
      --out "${WORK}/generated-${producer_file_mutation}" 2>&1)" || rc=$?
  assert_eq "T2d: producer ${producer_file_mutation} exits 2" "2" "${rc}"
  assert_contains "T2d: producer ${producer_file_mutation} cannot change a sealed evaluator file" \
    "changed during execution" "${producer_file_mutation_out}"
  assert_eq "T2d: producer ${producer_file_mutation} cannot publish a summary" "false" \
    "$([[ -e "${WORK}/generated-${producer_file_mutation}/summary.json" ]] \
      && printf true || printf false)"
done
cp "${WORK}/mock-producer" "${WORK}/mock-producer-self-mutating"
chmod +x "${WORK}/mock-producer-self-mutating"
rc=0; producer_binary_mutation_out="$(MOCK_PRODUCER_SESSION=producer-binary-mutation \
  MOCK_PRODUCER_MODE=mutate-producer-binary \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run producer-binary-mutation-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed producer-binary-mutation-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer-self-mutating" \
    --out "${WORK}/generated-producer-binary-mutation" 2>&1)" || rc=$?
assert_eq "T2d: producer executable mutation exits 2" "2" "${rc}"
assert_contains "T2d: producer executable is re-attested immediately after execution" \
  "producer executable or harness checkout changed during execution" \
  "${producer_binary_mutation_out}"
GENERATION_RACE_OUT="${WORK}/generated-same-output-race"
run_generation_race() (
  local worker="$1" rc=0
  set +e
  MOCK_PRODUCER_SESSION="producer-race-${worker}" MOCK_PRODUCER_SLEEP=1 \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline \
      --harness "${BASELINE_HARNESS}" --campaign-run generate-race-run \
      --candidate-model claude-test-model-1 --model-tier balanced \
      --seed generate-race-seed --skip-harness-install \
      --producer-bin "${WORK}/mock-producer" --out "${GENERATION_RACE_OUT}" \
      > "${WORK}/generate-race-${worker}.out" \
      2> "${WORK}/generate-race-${worker}.err"
  rc=$?
  printf '%s\n' "${rc}" > "${WORK}/generate-race-${worker}.rc"
)
run_generation_race first & generation_race_first_pid=$!
run_generation_race second & generation_race_second_pid=$!
wait "${generation_race_first_pid}"
wait "${generation_race_second_pid}"
assert_eq "T2d: concurrent generation has one atomic output owner" "0 2" \
  "$(LC_ALL=C sort -n "${WORK}/generate-race-first.rc" \
    "${WORK}/generate-race-second.rc" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "T2d: winning same-output generation remains valid" "true" \
  "$(jq -r '.schema_version == 4 and .generation_receipt == "generation.json"' \
    "${GENERATION_RACE_OUT}/summary.json" 2>/dev/null || printf false)"
receipt_generated="$("${PAIRWISE_COMPARE[@]}" \
  --campaign-run generated-run --probe quality-config-diagnostics \
  --baseline "${generated_baseline}" --challenger "${generated_challenger}" \
  --out "${WORK}/pair-generated" --judge-bin "${WORK}/mock-judge" --seed generated-seed)"
assert_eq "T2d: pair embeds independently verifiable generation telemetry" "true" \
  "$(jq -r '
    .schema_version == 7
    and .pair_manifest.candidates.baseline.generation.telemetry.total_cost_usd == 1
    and .pair_manifest.candidates.challenger.generation.telemetry.total_cost_usd == 1.2
    and .pair_manifest.candidates.baseline.generation.receipt.producer.session_id == "producer-baseline-001"
    and .pair_manifest.candidates.challenger.generation.receipt.producer.session_id == "producer-challenger-001"
  ' "${receipt_generated}")"

COMPARE_RACE_OUT="${WORK}/pair-same-output-race"
run_compare_race() (
  local worker="$1" rc=0
  set +e
  "${PAIRWISE_COMPARE[@]}" --probe quality-config-diagnostics \
    --baseline "${WORK}/baseline.json" --challenger "${WORK}/challenger.json" \
    --out "${COMPARE_RACE_OUT}" --judge-bin "${WORK}/mock-judge" \
    --seed stable-seed > "${WORK}/compare-race-${worker}.out" \
    2> "${WORK}/compare-race-${worker}.err"
  rc=$?
  printf '%s\n' "${rc}" > "${WORK}/compare-race-${worker}.rc"
)
run_compare_race first & compare_race_first_pid=$!
run_compare_race second & compare_race_second_pid=$!
wait "${compare_race_first_pid}"
wait "${compare_race_second_pid}"
assert_eq "T2d: concurrent comparison has one atomic output owner" "0 2" \
  "$(LC_ALL=C sort -n "${WORK}/compare-race-first.rc" \
    "${WORK}/compare-race-second.rc" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "T2d: winning same-output comparison remains sealed" "true" \
  "$(jq -r '.schema_version == 7 and (.receipt_hash | test("^[0-9a-f]{64}$"))' \
    "${COMPARE_RACE_OUT}/receipt.json" 2>/dev/null || printf false)"

printf 'T2e: generation fails closed on missing telemetry economics and required packages\n'
rc=0; generation_failure="$(MOCK_PRODUCER_SESSION=producer-no-usage MOCK_PRODUCER_MODE=no-usage \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run no-usage-run --candidate-model claude-test-model-1 --model-tier balanced \
    --seed no-usage-seed --skip-harness-install --producer-bin "${WORK}/mock-producer" \
    --out "${WORK}/generated-no-usage" 2>&1)" || rc=$?
assert_eq "T2e: missing raw usage buckets exit 2" "2" "${rc}"
assert_contains "T2e: missing usage failure is explicit" "lacks exact cost and token usage buckets" "${generation_failure}"
rc=0; generation_failure="$(MOCK_PRODUCER_SESSION=producer-no-package MOCK_PRODUCER_MODE=missing-package \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run no-package-run --candidate-model claude-test-model-1 --model-tier balanced \
    --seed no-package-seed --skip-harness-install --producer-bin "${WORK}/mock-producer" \
    --out "${WORK}/generated-no-package" 2>&1)" || rc=$?
assert_eq "T2e: missing declared files package exits 2" "2" "${rc}"
assert_contains "T2e: missing package failure is explicit" "does not satisfy every declared candidate artifact package" "${generation_failure}"

for cap_case in files entries bytes; do
  cap_env=()
  case "${cap_case}" in
    files) cap_env=(OMC_PAIRWISE_MAX_ARTIFACT_FILES=2) ;;
    entries) cap_env=(OMC_PAIRWISE_MAX_ARTIFACT_ENTRIES=3) ;;
    bytes) cap_env=(OMC_PAIRWISE_MAX_ARTIFACT_BYTES=128) ;;
  esac
  rc=0
  generation_failure="$(env "${cap_env[@]}" MOCK_PRODUCER_SESSION="producer-cap-${cap_case}" \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
      --campaign-run "cap-${cap_case}-run" --candidate-model claude-test-model-1 \
      --model-tier balanced --seed "cap-${cap_case}-seed" --skip-harness-install \
      --producer-bin "${WORK}/mock-producer" --out "${WORK}/generated-cap-${cap_case}" 2>&1)" || rc=$?
  assert_eq "T2e: generation ${cap_case} cap exits 2" "2" "${rc}"
  assert_contains "T2e: generation ${cap_case} cap is enforced before artifact copy" \
    "configured file, entry, or byte limit before copy" "${generation_failure}"
done

RAW_ENUM_WORKSPACE="${WORK}/raw-enumeration-workspace"
RAW_ENUM_DEST="${WORK}/raw-enumeration-artifact"
RAW_ENUM_PROBE="${WORK}/raw-enumeration-probe.json"
mkdir "${RAW_ENUM_WORKSPACE}"
git -C "${RAW_ENUM_WORKSPACE}" init -q
git -C "${RAW_ENUM_WORKSPACE}" config user.name "Pairwise Test"
git -C "${RAW_ENUM_WORKSPACE}" config user.email pairwise@example.invalid
printf 'baseline\n' > "${RAW_ENUM_WORKSPACE}/base.txt"
git -C "${RAW_ENUM_WORKSPACE}" add base.txt
git -C "${RAW_ENUM_WORKSPACE}" commit -qm baseline
printf 'one\n' > "${RAW_ENUM_WORKSPACE}/work.txt"
printf 'two\n' > "${RAW_ENUM_WORKSPACE}/diagnostic.json"
jq '(.candidate_artifacts[] | select(.kind == "files") | .globs) = ["*","work.txt"]' \
  "${PROBE}" > "${RAW_ENUM_PROBE}"
rc=0; raw_enum_out="$(bash -c '
  source "$1"
  DEFAULT_MAX_ARTIFACT_ENTRIES=2
  baseline="$(git -C "$2" rev-parse HEAD)"
  copy_declared_candidate_artifacts "$3" "$2" "$4" "${baseline}"
' pairwise-raw-enumeration "${PAIRWISE}" "${RAW_ENUM_WORKSPACE}" \
  "${RAW_ENUM_PROBE}" "${RAW_ENUM_DEST}" 2>&1)" || rc=$?
assert_eq "T2e: raw Git path enumeration is capped before sort/dedup" "1" "${rc}"
assert_contains "T2e: pre-sort enumeration failure is explicit" \
  "pre-sort entry limit" "${raw_enum_out}"

RESERVED_DECLARED_PROBE="${WORK}/reserved-declared-probe.json"
RESERVED_DECLARED_DEST="${WORK}/reserved-declared-artifact"
jq '(.candidate_artifacts[] | select(.kind == "files") | .globs) = [".pairwise/*"]' \
  "${PROBE}" > "${RESERVED_DECLARED_PROBE}"
rc=0; reserved_declared_out="$(bash -c '
  source "$1"
  baseline="$(git -C "$2" rev-parse HEAD)"
  copy_declared_candidate_artifacts "$3" "$2" "$4" "${baseline}"
' pairwise-reserved-declaration "${PAIRWISE}" "${RAW_ENUM_WORKSPACE}" \
  "${RESERVED_DECLARED_PROBE}" "${RESERVED_DECLARED_DEST}" 2>&1)" || rc=$?
assert_eq "T2e: copy rejects a bypassed reserved package declaration" "1" "${rc}"
assert_contains "T2e: copy declaration rejection names the reserved namespace" \
  "evaluator-reserved .pairwise namespace" "${reserved_declared_out}"

mkdir -p "${RAW_ENUM_WORKSPACE}/.pairwise"
printf '%s\n' 'reserved producer payload' \
  > "${RAW_ENUM_WORKSPACE}/.pairwise/producer.txt"
overlapping_glob_index=0
for overlapping_glob in '.pairwis?/*' '.pairwise*/*' '*/*' '**/*'; do
  overlapping_glob_index=$((overlapping_glob_index + 1))
  overlapping_copy_probe="${WORK}/overlapping-copy-probe-${overlapping_glob_index}.json"
  overlapping_copy_dest="${WORK}/overlapping-copy-artifact-${overlapping_glob_index}"
  jq --arg pattern "${overlapping_glob}" \
    '(.candidate_artifacts[] | select(.kind == "files") | .globs) = [$pattern]' \
    "${PROBE}" > "${overlapping_copy_probe}"
  rc=0; overlapping_copy_out="$(bash -c '
    source "$1"
    baseline="$(git -C "$2" rev-parse HEAD)"
    copy_declared_candidate_artifacts "$3" "$2" "$4" "${baseline}"
  ' pairwise-overlapping-reserved "${PAIRWISE}" "${RAW_ENUM_WORKSPACE}" \
    "${overlapping_copy_probe}" "${overlapping_copy_dest}" 2>&1)" || rc=$?
  assert_eq "T2e: resolved reserved path fails broad glob ${overlapping_glob}" "1" "${rc}"
  assert_contains "T2e: broad glob ${overlapping_glob} cannot claim evaluator metadata" \
    "producer output uses the evaluator-reserved .pairwise namespace" \
    "${overlapping_copy_out}"
done

RESERVED_CHANGED_PATH_DEST="${WORK}/reserved-changed-path-artifact"
rc=0; bash -c '
  source "$1"
  baseline="$(git -C "$2" rev-parse HEAD)"
  copy_declared_candidate_artifacts "$3" "$2" "$4" "${baseline}"
' pairwise-reserved-changed-path "${PAIRWISE}" "${RAW_ENUM_WORKSPACE}" \
  "${PROBE}" "${RESERVED_CHANGED_PATH_DEST}" || rc=$?
assert_eq "T2e: git_diff rejects reserved changes omitted by non-git globs" "1" "${rc}"
assert_eq "T2e: rejected reserved changes never create evaluator metadata" "false" \
  "$([[ -e "${RESERVED_CHANGED_PATH_DEST}/.pairwise" \
        || -L "${RESERVED_CHANGED_PATH_DEST}/.pairwise" ]] \
      && printf true || printf false)"

RESERVED_MANIFEST_ARTIFACT="${WORK}/reserved-manifest-artifact"
cp -R "${WORK}/artifacts/generic" "${RESERVED_MANIFEST_ARTIFACT}"
printf '%s\n' 'rogue evaluator metadata' \
  > "${RESERVED_MANIFEST_ARTIFACT}/.pairwise/producer.txt"
rc=0; bash -c '
  source "$1"
  artifact_package_manifest "$2" "$3" >/dev/null
' pairwise-reserved-manifest "${PAIRWISE}" "${PROBE}" \
  "${RESERVED_MANIFEST_ARTIFACT}" || rc=$?
assert_eq "T2e: package manifest rejects extra reserved-namespace files" "1" "${rc}"
rm -f "${RESERVED_MANIFEST_ARTIFACT}/.pairwise/producer.txt"
mkdir "${RESERVED_MANIFEST_ARTIFACT}/.pairwise/empty-producer-directory"
rc=0; bash -c '
  source "$1"
  artifact_package_manifest "$2" "$3" >/dev/null
' pairwise-reserved-manifest-directory "${PAIRWISE}" "${PROBE}" \
  "${RESERVED_MANIFEST_ARTIFACT}" || rc=$?
assert_eq "T2e: package manifest rejects extra reserved-namespace directories" "1" "${rc}"

FILE_COUNT_ARTIFACT="${WORK}/file-count-artifact"
mkdir -p "${FILE_COUNT_ARTIFACT}/.pairwise"
printf '%s\n' ordinary > "${FILE_COUNT_ARTIFACT}/ordinary.txt"
printf '%s\n' managed > "${FILE_COUNT_ARTIFACT}/.pairwise/git.diff"
printf '%s\n' managed > "${FILE_COUNT_ARTIFACT}/.pairwise/changed-paths.json"
FILE_COUNT_RULE='{"type":"file_count_at_most","value":1}'
rc=0; bash -c '
  source "$1"
  fixture_rule_passes "$2" "$3" "$4"
' pairwise-file-count-managed "${PAIRWISE}" "${FILE_COUNT_RULE}" \
  "${FILE_COUNT_ARTIFACT}" "${WORK}" || rc=$?
assert_eq "T2e: file count excludes the two exact evaluator-owned files" "0" "${rc}"
printf '%s\n' rogue > "${FILE_COUNT_ARTIFACT}/.pairwise/producer.txt"
rc=0; bash -c '
  source "$1"
  fixture_rule_passes "$2" "$3" "$4"
' pairwise-file-count-rogue "${PAIRWISE}" "${FILE_COUNT_RULE}" \
  "${FILE_COUNT_ARTIFACT}" "${WORK}" || rc=$?
assert_eq "T2e: file count includes every other reserved-subtree file" "1" "${rc}"

for install_mode in hang spam; do
  rc=0
  install_failure="$(OMC_PAIRWISE_HARNESS_INSTALL_TIMEOUT_SECONDS=1 \
    OMC_PAIRWISE_MAX_INSTALL_LOG_BYTES=1024 \
    MOCK_HARNESS_INSTALL_MODE="${install_mode}" \
    MOCK_PRODUCER_SESSION="producer-install-${install_mode}" \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
      --campaign-run "install-${install_mode}-run" --candidate-model claude-test-model-1 \
      --model-tier balanced --seed "install-${install_mode}-seed" \
      --producer-bin "${WORK}/mock-producer" \
      --out "${WORK}/generated-install-${install_mode}" 2>&1)" || rc=$?
  assert_eq "T2e: ${install_mode} harness install exits 2" "2" "${rc}"
  if [[ "${install_mode}" == "spam" ]]; then
    assert_contains "T2e: ${install_mode} harness install is time/log bounded" \
      "exceeded its log byte limit" "${install_failure}"
  else
    assert_contains "T2e: ${install_mode} harness install is time/log bounded" \
      "failed, timed out, or exceeded its log limit" "${install_failure}"
  fi
done
for install_mode in unexpected-root precreate-install-symlink \
    precreate-install-hardlink precreate-install-fifo; do
  rc=0
  install_failure="$(MOCK_HARNESS_INSTALL_MODE="${install_mode}" \
    MOCK_PRODUCER_SESSION="producer-install-${install_mode}" \
    bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
      --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
      --campaign-run "install-${install_mode}-run" --candidate-model claude-test-model-1 \
      --model-tier balanced --seed "install-${install_mode}-seed" \
      --producer-bin "${WORK}/mock-producer" \
      --out "${WORK}/generated-install-${install_mode}" 2>&1)" || rc=$?
  assert_eq "T2e: ${install_mode} installer boundary mutation exits 2" "2" "${rc}"
  assert_contains "T2e: ${install_mode} violates exact generation inventory" \
    "unexpected evaluator-package node" "${install_failure}"
  assert_eq "T2e: ${install_mode} cannot publish generation authority" "false" \
    "$([[ -e "${WORK}/generated-install-${install_mode}/summary.json" ]] \
      && printf true || printf false)"
done

overflow_uint=18446744073709551617
for overflow_setting in \
    OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS \
    OMC_PAIRWISE_JUDGE_TIMEOUT_SECONDS \
    OMC_PAIRWISE_PRODUCER_TIMEOUT_SECONDS \
    OMC_PAIRWISE_HARNESS_INSTALL_TIMEOUT_SECONDS \
    OMC_PAIRWISE_ARTIFACT_COPY_TIMEOUT_SECONDS \
    OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS \
    OMC_PAIRWISE_MAX_ARTIFACT_FILES \
    OMC_PAIRWISE_MAX_ARTIFACT_ENTRIES \
    OMC_PAIRWISE_MAX_ARTIFACT_BYTES \
    OMC_PAIRWISE_MAX_JUDGE_RESPONSE_BYTES \
    OMC_PAIRWISE_MAX_INSTALL_LOG_BYTES; do
  rc=0; overflow_out="$(env "${overflow_setting}=${overflow_uint}" \
    bash "${PAIRWISE}" validate 2>&1)" || rc=$?
  assert_eq "T2e: ${overflow_setting} signed-overflow input exits 2" "2" "${rc}"
  assert_contains "T2e: ${overflow_setting} is rejected before Bash arithmetic" \
    "must be an integer from 1 to" "${overflow_out}"
done

for overflow_flag in \
    --judge-timeout \
    --max-artifact-files \
    --max-artifact-entries \
    --max-artifact-bytes \
    --max-judge-response-bytes \
    --artifact-copy-timeout; do
  overflow_label="${overflow_flag#--}"
  rc=0; overflow_out="$("${PAIRWISE_COMPARE[@]}" \
    --probe quality-config-diagnostics \
    --baseline "${generated_baseline}" --challenger "${generated_challenger}" \
    --out "${WORK}/pair-overflow-${overflow_label}" \
    --judge-bin "${WORK}/mock-judge" "${overflow_flag}" "${overflow_uint}" \
    2>&1)" || rc=$?
  assert_eq "T2e: ${overflow_flag} signed-overflow input exits 2" "2" "${rc}"
  assert_contains "T2e: ${overflow_flag} is rejected before Bash arithmetic" \
    "must be an integer from 1 to" "${overflow_out}"
done

rc=0; overflow_out="$(MOCK_PRODUCER_SESSION=producer-overflow-timeout \
  bash "${PAIRWISE}" generate --identity-manifest "${IDENTITY_MANIFEST}" \
    --probe quality-config-diagnostics --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run overflow-timeout-run --candidate-model claude-test-model-1 \
    --model-tier balanced --seed overflow-timeout-seed --skip-harness-install \
    --producer-bin "${WORK}/mock-producer" --producer-timeout "${overflow_uint}" \
    --out "${WORK}/generated-overflow-timeout" 2>&1)" || rc=$?
assert_eq "T2e: --producer-timeout signed-overflow input exits 2" "2" "${rc}"
assert_contains "T2e: --producer-timeout is rejected before Bash arithmetic" \
  "must be an integer from 1 to" "${overflow_out}"

printf 'T2f: post-hoc run rebinding and raw telemetry mutation fail before judging\n'
rc=0; generation_failure="$("${PAIRWISE_COMPARE[@]}" --campaign-run rebound-run \
  --probe quality-config-diagnostics --baseline "${generated_baseline}" --challenger "${generated_challenger}" \
  --out "${WORK}/pair-rebound-generation" --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T2f: post-hoc campaign run exits 2" "2" "${rc}"
assert_contains "T2f: generation-bound run mismatch is explicit" "campaign binding does not match" "${generation_failure}"
cp -R "${WORK}/generated-challenger" "${WORK}/generated-challenger-tampered"
jq '.total_cost_usd = 0.01' "${WORK}/generated-challenger-tampered/telemetry/cli.json" \
  > "${WORK}/generated-challenger-tampered/telemetry/cli.next"
mv "${WORK}/generated-challenger-tampered/telemetry/cli.next" \
  "${WORK}/generated-challenger-tampered/telemetry/cli.json"
rc=0; generation_failure="$("${PAIRWISE_COMPARE[@]}" --campaign-run generated-run \
  --probe quality-config-diagnostics --baseline "${generated_baseline}" \
  --challenger "${WORK}/generated-challenger-tampered/summary.json" \
  --out "${WORK}/pair-tampered-telemetry" --judge-bin "${WORK}/mock-judge" --seed generated-seed 2>&1)" || rc=$?
assert_eq "T2f: mutated raw telemetry exits 2" "2" "${rc}"
assert_contains "T2f: telemetry mutation invalidates generation" \
  "summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${generation_failure}"

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
assert_eq "T3: receipt retains and hashes both exact raw judge responses" "true" \
  "$([[ "$(jq -j '.judge_execution.forward.raw_response' "${receipt_win}" \
          | shasum -a 256 | awk '{print $1}')" \
        == "$(jq -r '.judge_execution.forward.raw_response_hash' "${receipt_win}")" \
      && "$(jq -j '.judge_execution.reverse.raw_response' "${receipt_win}" \
          | shasum -a 256 | awk '{print $1}')" \
        == "$(jq -r '.judge_execution.reverse.raw_response_hash' "${receipt_win}")" ]] \
    && printf true || printf false)"
assert_eq "T3: receipt carries the evaluator-verified exact checkout identities" "true" \
  "$(jq -r \
    --arg baseline_hash "${BASELINE_HARNESS_HASH}" \
    --arg challenger_hash "${CHALLENGER_HARNESS_HASH}" '
      .schema_version == 7
      and .provenance.harness_identity.authority == "custom"
      and .provenance.harness_identity.baseline.identity_hash == $baseline_hash
      and .provenance.harness_identity.challenger.identity_hash == $challenger_hash
      and .provenance.harness_identity.baseline.checkout_policy == "manifest-pinned-commit-tree"
      and .provenance.harness_identity.challenger.checkout_policy == "explicit-checkout-descendant"
    ' "${receipt_win}")"
assert_eq "T3: receipt freezes run identity and probe campaign limits" "true" \
  "$(jq -r '
    .campaign_run.id == .pair_manifest.campaign_run.id
    and .campaign_run.probe_id == .probe_id
    and .campaign_run.model_tier == .model_tier
    and .campaign_run.candidate_model_id == .model
    and .campaign_run.comparison_seed == .pair_manifest.seed
    and .probe_campaign == {
      runs_per_arm:3,
      model_tiers:["balanced","economy"],
      max_candidate_cost_ratio:1.75,
      max_candidate_wall_ratio:1.75
    }
    and .economics.probe_budget_pass == {cost:true,wall:true}
  ' "${receipt_win}")"
canonical_probe_hash="$(jq -cS . "${PROBE}" | shasum -a 256 | awk '{print $1}')"
assert_eq "T3: portable receipt seals the complete bundled probe and both generations" "true" \
  "$(jq -r --arg probe_hash "${canonical_probe_hash}" --slurpfile probe "${PROBE}" '
    .pair_manifest.probe_snapshot == $probe[0]
    and .pair_manifest.provenance.probe_hash == $probe_hash
    and .pair_manifest.provenance.probe_authority == "canonical"
    and all(.pair_manifest.candidates[];
      .generation.receipt.provenance.probe_hash == $probe_hash
      and .generation.receipt.provenance.probe_authority == "canonical")
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
assert_contains "T3: deterministic non-veto diagnostics are visible to the judge" \
  "BLINDED FIXTURE DIAGNOSTICS" "${prompt_log}"
assert_contains "T3: judge is told to verify both candidates against neutral source input" \
  "Inspect the identical neutral task inputs under ./INPUT" "${prompt_log}"
assert_contains "T3: forward judge order binds the sealed source hash" \
  "SOURCE_INPUT_HASH: ${SOURCE_HASH}" \
  "$(cat "${WORK}/pair win/judge-forward.prompt.txt")"
assert_contains "T3: reverse judge order binds the sealed source hash" \
  "SOURCE_INPUT_HASH: ${SOURCE_HASH}" \
  "$(cat "${WORK}/pair win/judge-reverse.prompt.txt")"
assert_not_contains "T3: judge workspace is outside the durable audit package" "${WORK}" \
  "$(cat "${MOCK_LOG_DIR}/cwd.log")"
args_log="$(cat "${MOCK_LOG_DIR}/args.log")"
assert_contains "T3: judge runs safe mode" "--safe-mode" "${args_log}"
assert_contains "T3: judge receives strict schema" "--json-schema" "${args_log}"

calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
rc=0; isolated_mutation_out="$(MOCK_MODE=mutate-isolated-view \
  "${PAIRWISE_COMPARE[@]}" --probe quality-config-diagnostics \
    --baseline "${WORK}/baseline.json" --challenger "${WORK}/challenger.json" \
    --out "${WORK}/pair-judge-mutates-isolated" \
    --judge-bin "${WORK}/mock-judge" --seed stable-seed 2>&1)" || rc=$?
assert_eq "T3: judge mutation of isolated A/B fails the comparison" "2" "${rc}"
assert_eq "T3: mutated isolated input is not reused for a retry or reverse order" \
  "$((calls_before + 1))" "$(cat "${MOCK_LOG_DIR}/counter")"
assert_contains "T3: isolated mutation closes through strict judge validation" \
  "forward judge failed strict validation twice" "${isolated_mutation_out}"

durable_swap_out_dir="${WORK}/pair-judge-swaps-durable-child"
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
rc=0; durable_swap_out="$(MOCK_MODE=swap-durable-child \
  MOCK_PAIR_OUTPUT="${durable_swap_out_dir}" \
  "${PAIRWISE_COMPARE[@]}" --probe quality-config-diagnostics \
    --baseline "${WORK}/baseline.json" --challenger "${WORK}/challenger.json" \
    --out "${durable_swap_out_dir}" --judge-bin "${WORK}/mock-judge" \
    --seed stable-seed 2>&1)" || rc=$?
assert_eq "T3: judge replacement of a durable comparison child fails" "2" "${rc}"
assert_eq "T3: durable child swap prevents reverse-order execution" \
  "$((calls_before + 1))" "$(cat "${MOCK_LOG_DIR}/counter")"
assert_contains "T3: stable pair-root inode cannot hide a swapped views child" \
  "forward judge failed strict validation twice" "${durable_swap_out}"

cp "${WORK}/mock-judge" "${WORK}/mock-judge-self-mutating"
chmod +x "${WORK}/mock-judge-self-mutating"
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
rc=0; judge_binary_mutation_out="$(MOCK_MODE=mutate-judge-binary \
  "${PAIRWISE_COMPARE[@]}" --probe quality-config-diagnostics \
    --baseline "${WORK}/baseline.json" --challenger "${WORK}/challenger.json" \
    --out "${WORK}/pair-judge-binary-mutation" \
    --judge-bin "${WORK}/mock-judge-self-mutating" \
    --seed stable-seed 2>&1)" || rc=$?
assert_eq "T3: judge executable mutation exits 2" "2" "${rc}"
assert_eq "T3: changed judge executable prevents retry/reverse execution" \
  "$((calls_before + 1))" "$(cat "${MOCK_LOG_DIR}/counter")"
assert_contains "T3: judge executable re-attestation fails closed" \
  "forward judge failed strict validation twice" "${judge_binary_mutation_out}"

printf 'T3a: zero-denominator economics distinguish parity from unbounded growth\n'
SUMMARY_RUN_ID=dev-run-zero SUMMARY_SEED=zero-seed \
  make_summary "${WORK}/zero-baseline.json" "${WORK}/artifacts/generic" \
    "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 0 100 50
SUMMARY_RUN_ID=dev-run-zero SUMMARY_SEED=zero-seed \
  make_summary "${WORK}/zero-challenger.json" "${WORK}/artifacts/crafted" \
    "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 0 100 50
zero_parity_receipt="$("${PAIRWISE_COMPARE[@]}" \
  --campaign-run dev-run-zero --probe quality-config-diagnostics \
  --baseline "${WORK}/zero-baseline.json" --challenger "${WORK}/zero-challenger.json" \
  --out "${WORK}/pair-zero-parity" --judge-bin "${WORK}/mock-judge" --seed zero-seed)"
assert_eq "T3a: equal zero wall measurements are parity" "true" \
  "$(jq -r '.economics.ratios.wall == 1 and .economics.probe_budget_pass.wall == true' \
    "${zero_parity_receipt}")"

SUMMARY_RUN_ID=dev-run-zero-growth SUMMARY_SEED=zero-growth-seed \
  make_summary "${WORK}/zero-growth-baseline.json" "${WORK}/artifacts/identical" \
    "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 0 100 50
SUMMARY_RUN_ID=dev-run-zero-growth SUMMARY_SEED=zero-growth-seed \
  make_summary "${WORK}/zero-growth-challenger.json" "${WORK}/artifacts/identical-b" \
    "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 1 100 50
zero_growth_receipt="$("${PAIRWISE_COMPARE[@]}" \
  --campaign-run dev-run-zero-growth --probe quality-config-diagnostics \
  --baseline "${WORK}/zero-growth-baseline.json" \
  --challenger "${WORK}/zero-growth-challenger.json" \
  --out "${WORK}/pair-zero-growth" --judge-bin "${WORK}/mock-judge" \
  --seed zero-growth-seed)"
assert_eq "T3a: positive wall over zero baseline remains unbounded" "true" \
  "$(jq -r '.economics.ratios.wall == null and .economics.probe_budget_pass.wall == false' \
    "${zero_growth_receipt}")"

assert_eq "T3: receipt seals custom judge identity for development evidence" "true" \
  "$(jq -r '
    .pair_manifest.judge_plan.authority == "custom"
    and .pair_manifest.judge_plan.binary_location == "custom"
    and .pair_manifest.judge_plan.binary_version == "unattested"
    and .pair_manifest.judge_plan.policy_hash == null
    and .pair_manifest.judge_plan.requested_model == "judge-test-model-1"
    and (.pair_manifest.judge_plan.binary_sha256 | test("^[0-9a-f]{64}$"))
    and (.pair_manifest.judge_plan.schema_hash | test("^[0-9a-f]{64}$"))
    and .pair_manifest.judge_plan.max_response_bytes == 1048576
    and all(.pair_manifest.judge_plan.prompt_hashes[]; test("^[0-9a-f]{64}$"))
    and .judge_execution.authority == "cli-json"
    and .judge_execution.forward.actual_model == "judge-test-model-1"
    and .judge_execution.reverse.actual_model == "judge-test-model-1"
    and ((.judge_execution.forward.raw_response | fromjson | .result | fromjson)
      | .overall.winner != null)
    and ((.judge_execution.reverse.raw_response | fromjson | .result | fromjson)
      | .overall.winner != null)
  ' "${receipt_win}")"
assert_eq "T3: structured evidence is mapped back to candidate role" "challenger" \
  "$(jq -r '.dimension_evidence.visionary.forward[0].candidate' "${receipt_win}")"

printf 'T3a2: re-sealed judge prompt identities are rederived from the portable probe\n'
jq '
  .pair_manifest.judge_plan.prompt_hashes.forward = ("0" * 64)
  | del(.pair_manifest.manifest_hash, .pair_manifest_hash, .receipt_hash)
' "${receipt_win}" > "${WORK}/forged-prompt-hash.stage-1.json"
forged_pair_hash="$(jq -cS '.pair_manifest' "${WORK}/forged-prompt-hash.stage-1.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${forged_pair_hash}" '
  .pair_manifest.manifest_hash = $hash | .pair_manifest_hash = $hash
' "${WORK}/forged-prompt-hash.stage-1.json" > "${WORK}/forged-prompt-hash.stage-2.json"
forged_prompt_receipt_hash="$(jq -cS 'del(.receipt_hash)' \
  "${WORK}/forged-prompt-hash.stage-2.json" | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${forged_prompt_receipt_hash}" '.receipt_hash = $hash' \
  "${WORK}/forged-prompt-hash.stage-2.json" > "${WORK}/forged-prompt-hash.json"
rc=0; forged_prompt_out="$(bash "${PAIRWISE}" report \
  "${WORK}/forged-prompt-hash.json" 2>&1)" || rc=$?
assert_eq "T3a2: coherently re-sealed substituted prompt hash exits 2" "2" "${rc}"
assert_contains "T3a2: portable prompt identity is independently invalid" \
  "invalid, unsealed, or stale pairwise receipt" "${forged_prompt_out}"

printf 'T3b: coherently re-sealed judge-derived outcomes cannot diverge from embedded responses\n'
jq '
  .winner = "baseline"
  | .dimensions |= with_entries(.value = "baseline")
  | .order_verdicts = {forward:"baseline",reverse:"baseline"}
  | .position_consistent = true
  | .overall.material = true
  | del(.receipt_hash)
' "${receipt_win}" > "${WORK}/forged-judge-outcome.unsealed.json"
forged_judge_hash="$(jq -cS . "${WORK}/forged-judge-outcome.unsealed.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${forged_judge_hash}" '.receipt_hash = $hash' \
  "${WORK}/forged-judge-outcome.unsealed.json" > "${WORK}/forged-judge-outcome.json"
rc=0; forged_judge_out="$(bash "${PAIRWISE}" report \
  "${WORK}/forged-judge-outcome.json" 2>&1)" || rc=$?
assert_eq "T3b: re-sealed divergent judge outcome exits 2" "2" "${rc}"
assert_contains "T3b: re-sealed divergent judge outcome is invalid" \
  "invalid, unsealed, or stale pairwise receipt" "${forged_judge_out}"

printf 'T3c: report recomputes each raw judge byte hash from the retained response\n'
jq '.judge_execution.forward.raw_response += " " | del(.receipt_hash)' \
  "${receipt_win}" > "${WORK}/forged-raw-bytes.unsealed.json"
forged_raw_bytes_hash="$(jq -cS . "${WORK}/forged-raw-bytes.unsealed.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${forged_raw_bytes_hash}" '.receipt_hash = $hash' \
  "${WORK}/forged-raw-bytes.unsealed.json" > "${WORK}/forged-raw-bytes.json"
rc=0; forged_raw_bytes_out="$(bash "${PAIRWISE}" report \
  "${WORK}/forged-raw-bytes.json" 2>&1)" || rc=$?
assert_eq "T3c: outer-resealed raw byte mutation exits 2" "2" "${rc}"
assert_contains "T3c: retained raw byte hash mismatch is invalid" \
  "invalid, unsealed, or stale pairwise receipt" "${forged_raw_bytes_out}"

printf 'T3d: report reparses retained raw judge bytes before trusting derived fields\n'
jq '
  .judge_execution.forward.raw_response |= (
    fromjson
    | .result |= (fromjson | .overall.reason += " altered" | tojson)
    | tojson)
  | del(.receipt_hash)
' "${receipt_win}" > "${WORK}/forged-raw-response.stage-1.json"
forged_forward_raw_hash="$(jq -j '.judge_execution.forward.raw_response' \
  "${WORK}/forged-raw-response.stage-1.json" | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${forged_forward_raw_hash}" \
  '.judge_execution.forward.raw_response_hash = $hash' \
  "${WORK}/forged-raw-response.stage-1.json" > "${WORK}/forged-raw-response.stage-2.json"
forged_raw_response_hash="$(jq -cS . "${WORK}/forged-raw-response.stage-2.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${forged_raw_response_hash}" '.receipt_hash = $hash' \
  "${WORK}/forged-raw-response.stage-2.json" > "${WORK}/forged-raw-response.json"
rc=0; forged_raw_response_out="$(bash "${PAIRWISE}" report \
  "${WORK}/forged-raw-response.json" 2>&1)" || rc=$?
assert_eq "T3d: raw-and-hash-resealed derived mismatch exits 2" "2" "${rc}"
assert_contains "T3d: reparsed raw judge response mismatch is invalid" \
  "invalid, unsealed, or stale pairwise receipt" "${forged_raw_response_out}"

# Preserve every derived field and both integrity layers while introducing a
# decoded NUL into one retained judge response. Portable validation must apply
# the live recursive string contract to the decoded response itself.
jq '
  .judge_execution.forward.raw_response |= (
    fromjson
    | .result |= (fromjson | .overall.reason += "\u0000poison" | tojson)
    | tojson)
  | (.judge_execution.forward.raw_response | fromjson | .result | fromjson
      | .overall.reason) as $forward_reason
  | (.judge_execution.reverse.raw_response | fromjson | .result | fromjson
      | .overall.reason) as $reverse_reason
  | .overall.reason = ("forward: " + $forward_reason
      + " | reverse: " + $reverse_reason)
  | del(.receipt_hash)
' "${receipt_win}" > "${WORK}/nul-judge-response.stage-1.json"
nul_judge_raw_hash="$(jq -j '.judge_execution.forward.raw_response' \
  "${WORK}/nul-judge-response.stage-1.json" | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${nul_judge_raw_hash}" \
  '.judge_execution.forward.raw_response_hash = $hash' \
  "${WORK}/nul-judge-response.stage-1.json" \
  > "${WORK}/nul-judge-response.stage-2.json"
nul_judge_receipt_hash="$(jq -cS . "${WORK}/nul-judge-response.stage-2.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${nul_judge_receipt_hash}" '.receipt_hash = $hash' \
  "${WORK}/nul-judge-response.stage-2.json" > "${WORK}/nul-judge-response.json"
rc=0; nul_judge_response_out="$(bash "${PAIRWISE}" report \
  "${WORK}/nul-judge-response.json" 2>&1)" || rc=$?
assert_eq "T3d: coherently re-sealed decoded judge NUL exits 2" "2" "${rc}"
assert_contains "T3d: portable decoded judge validation rejects NUL recursively" \
  "invalid, unsealed, or stale pairwise receipt" "${nul_judge_response_out}"

printf 'T4: constant-position judge disagreement collapses to tie\n'
export MOCK_MODE=always-a
receipt_position="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-position" \
  --judge-bin "${WORK}/mock-judge" \
  --seed stable-seed)"
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
  --seed stable-seed)"
assert_eq "T4b: restrained baseline wins" "baseline" "$(jq -r '.winner' "${receipt_overreach}")"
assert_eq "T4b: challenger scope creep mapped" "true" "$(jq -r '.scope_creep.challenger' "${receipt_overreach}")"
assert_eq "T4b: baseline not falsely flagged" "false" "$(jq -r '.scope_creep.baseline' "${receipt_overreach}")"
unset MOCK_MODE

printf 'T5: byte-identical artifacts auto-tie without a judge call\n'
SUMMARY_RUN_ID=dev-run-same SUMMARY_SEED=same-seed make_summary "${WORK}/same-a.json" "${WORK}/artifacts/identical" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-same SUMMARY_SEED=same-seed make_summary "${WORK}/same-b.json" "${WORK}/artifacts/identical-b" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_same="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/same-a.json" \
  --challenger "${WORK}/same-b.json" \
  --out "${WORK}/pair-identical" \
  --campaign-run dev-run-same --judge-bin "${WORK}/mock-judge" --seed same-seed)"
assert_eq "T5: identical basis" "identical-artifact" "$(jq -r '.basis' "${receipt_same}")"
assert_eq "T5: identical winner tie" "tie" "$(jq -r '.winner' "${receipt_same}")"
assert_eq "T5: identical artifacts do not impersonate a five-axis judgment" "false" \
  "$(jq -r '.dimensions_evaluated' "${receipt_same}")"
assert_eq "T5: no judge invocation" "${calls_before}" "$(cat "${MOCK_LOG_DIR}/counter")"

receipt_bytes="$(wc -c < "${receipt_same}" | awk '{print $1}')"
receipt_cap=$((receipt_bytes - 1))
rc=0; receipt_cap_out="$(OMC_PAIRWISE_MAX_RECEIPT_BYTES="${receipt_cap}" \
  "${PAIRWISE_COMPARE[@]}" --probe quality-config-diagnostics \
  --baseline "${WORK}/same-a.json" --challenger "${WORK}/same-b.json" \
  --out "${WORK}/pair-identical-over-receipt-cap" \
  --campaign-run dev-run-same --judge-bin "${WORK}/mock-judge" \
  --seed same-seed 2>&1)" || rc=$?
assert_eq "T5: comparison cannot publish evidence larger than report accepts" "2" "${rc}"
assert_contains "T5: final receipt cap failure is explicit" \
  "runner pair receipt exceeds the report byte limit" "${receipt_cap_out}"

printf 'T5a: physical arm separation rejects one root or hard-linked files shared across roles\n'
SUMMARY_RUN_ID=dev-run-shared-root SUMMARY_SEED=shared-root-seed make_summary \
  "${WORK}/shared-root-a.json" "${WORK}/artifacts/identical" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-shared-root SUMMARY_SEED=shared-root-seed make_summary \
  "${WORK}/shared-root-b.json" "${WORK}/artifacts/identical" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; disjoint_out="$("${PAIRWISE_COMPARE[@]}" --campaign-run dev-run-shared-root \
  --probe quality-config-diagnostics --baseline "${WORK}/shared-root-a.json" \
  --challenger "${WORK}/shared-root-b.json" --out "${WORK}/pair-shared-root" \
  --judge-bin "${WORK}/mock-judge" --seed shared-root-seed 2>&1)" || rc=$?
assert_eq "T5a: one artifact root for both roles exits 2" "2" "${rc}"
assert_contains "T5a: root separation failure is explicit" "artifact roots must be physically disjoint" "${disjoint_out}"

cp -R "${WORK}/artifacts/generic" "${WORK}/artifacts/hardlink-a"
cp -R "${WORK}/artifacts/crafted" "${WORK}/artifacts/hardlink-b"
rm -f "${WORK}/artifacts/hardlink-b/work.txt"
ln "${WORK}/artifacts/hardlink-a/work.txt" "${WORK}/artifacts/hardlink-b/work.txt"
SUMMARY_RUN_ID=dev-run-hardlink SUMMARY_SEED=hardlink-seed make_summary \
  "${WORK}/hardlink-a.json" "${WORK}/artifacts/hardlink-a" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-hardlink SUMMARY_SEED=hardlink-seed make_summary \
  "${WORK}/hardlink-b.json" "${WORK}/artifacts/hardlink-b" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; disjoint_out="$("${PAIRWISE_COMPARE[@]}" --campaign-run dev-run-hardlink \
  --probe quality-config-diagnostics --baseline "${WORK}/hardlink-a.json" \
  --challenger "${WORK}/hardlink-b.json" --out "${WORK}/pair-hardlink" \
  --judge-bin "${WORK}/mock-judge" --seed hardlink-seed 2>&1)" || rc=$?
assert_eq "T5a: cross-role hard link exits 2" "2" "${rc}"
assert_contains "T5a: hard-link role leakage is explicit" "must not share hard-linked file identities" "${disjoint_out}"

inode_failure_result="$(bash -c '
  source "$1"
  eval "$(declare -f file_inode_identity \
    | sed "1s/file_inode_identity/real_file_inode_identity/")"
  file_inode_identity() { return 1; }
  share_rc=0
  artifact_trees_share_inode "$2" "$3" || share_rc=$?
  file_inode_identity() { real_file_inode_identity "$@"; }
  find() { return 1; }
  alias_rc=0
  artifact_tree_aliases_file "$2" "$4" || alias_rc=$?
  unset -f find
  comm() { return 1; }
  comm_rc=0
  artifact_trees_share_inode "$2" "$3" || comm_rc=$?
  jq -nc --argjson share_rc "${share_rc}" --argjson alias_rc "${alias_rc}" \
    --argjson comm_rc "${comm_rc}" \
    '\''{share_rc:$share_rc,alias_rc:$alias_rc,comm_rc:$comm_rc}'\''
' pairwise-inode-failure "${PAIRWISE}" \
  "${WORK}/artifacts/hardlink-a" "${WORK}/artifacts/hardlink-b" \
  "${FIXTURE_DIR}/source/config-layers.txt")"
assert_eq "T5a: inode stat failure is distinct from a verified disjoint tree" "2" \
  "$(jq -r '.share_rc' <<<"${inode_failure_result}")"
assert_eq "T5a: inode enumeration failure is fail-closed for protected files" "2" \
  "$(jq -r '.alias_rc' <<<"${inode_failure_result}")"
assert_eq "T5a: inode intersection failure is not treated as verified separation" "2" \
  "$(jq -r '.comm_rc' <<<"${inode_failure_result}")"

cp -R "${WORK}/artifacts/generic" "${WORK}/artifacts/fixture-alias"
cp -R "${WORK}/artifacts/crafted" "${WORK}/artifacts/fixture-alias-peer"
rm -f "${WORK}/artifacts/fixture-alias/work.txt"
ln "${FIXTURE_DIR}/source/config-layers.txt" "${WORK}/artifacts/fixture-alias/work.txt"
SUMMARY_RUN_ID=dev-run-fixture-alias SUMMARY_SEED=fixture-alias-seed make_summary \
  "${WORK}/fixture-alias.json" "${WORK}/artifacts/fixture-alias" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-fixture-alias SUMMARY_SEED=fixture-alias-seed make_summary \
  "${WORK}/fixture-alias-peer.json" "${WORK}/artifacts/fixture-alias-peer" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; disjoint_out="$("${PAIRWISE_COMPARE[@]}" --campaign-run dev-run-fixture-alias \
  --probe quality-config-diagnostics --baseline "${WORK}/fixture-alias.json" \
  --challenger "${WORK}/fixture-alias-peer.json" --out "${WORK}/pair-fixture-alias" \
  --judge-bin "${WORK}/mock-judge" --seed fixture-alias-seed 2>&1)" || rc=$?
assert_eq "T5a: fixture hard link exits 2" "2" "${rc}"
assert_contains "T5a: fixture hard link is rejected" \
  "hard-links evaluator metadata or another protected input" "${disjoint_out}"

cp -R "${WORK}/artifacts/generic" "${WORK}/artifacts/harness-alias"
cp -R "${WORK}/artifacts/crafted" "${WORK}/artifacts/harness-alias-peer"
rm -f "${WORK}/artifacts/harness-alias/work.txt"
ln "${BASELINE_HARNESS}/harness.txt" "${WORK}/artifacts/harness-alias/work.txt"
SUMMARY_RUN_ID=dev-run-harness-alias SUMMARY_SEED=harness-alias-seed make_summary \
  "${WORK}/harness-alias.json" "${WORK}/artifacts/harness-alias" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-harness-alias SUMMARY_SEED=harness-alias-seed make_summary \
  "${WORK}/harness-alias-peer.json" "${WORK}/artifacts/harness-alias-peer" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; disjoint_out="$("${PAIRWISE_COMPARE[@]}" --campaign-run dev-run-harness-alias \
  --probe quality-config-diagnostics --baseline "${WORK}/harness-alias.json" \
  --challenger "${WORK}/harness-alias-peer.json" --out "${WORK}/pair-harness-alias" \
  --judge-bin "${WORK}/mock-judge" --seed harness-alias-seed 2>&1)" || rc=$?
assert_eq "T5a: harness hard link exits 2" "2" "${rc}"
assert_contains "T5a: harness hard link is rejected" \
  "hard-links evaluator metadata or another protected input" "${disjoint_out}"

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
assert_contains "T5b: empty package cannot forge a generation" \
  "summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${empty_out}"

mkdir -p "${WORK}/artifacts/git-metadata-only"
printf 'gitdir: elsewhere\n' > "${WORK}/artifacts/git-metadata-only/.git"
make_summary "${WORK}/git-metadata-only.json" "${WORK}/artifacts/git-metadata-only" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; empty_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/git-metadata-only.json" \
  --out "${WORK}/pair-git-metadata-only" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T5b: root .git metadata alone is not an artifact" "2" "${rc}"
assert_contains "T5b: metadata-only package cannot forge a generation" \
  "summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${empty_out}"

printf 'T5c: empty directories are part of artifact identity\n'
cp -R "${WORK}/artifacts/identical" "${WORK}/artifacts/with-empty-dir"
mkdir -p "${WORK}/artifacts/with-empty-dir/intentional-empty"
SUMMARY_RUN_ID=dev-run-same SUMMARY_SEED=same-seed make_summary "${WORK}/with-empty-dir.json" "${WORK}/artifacts/with-empty-dir" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_empty_dir="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/same-a.json" \
  --challenger "${WORK}/with-empty-dir.json" \
  --out "${WORK}/pair-empty-directory" \
  --campaign-run dev-run-same --judge-bin "${WORK}/mock-judge" --seed same-seed)"
assert_eq "T5c: directory-only difference does not auto-tie" "judge" \
  "$(jq -r '.basis' "${receipt_empty_dir}")"
assert_eq "T5c: directory changes the tree digest" "true" \
  "$(jq -r '.artifact_hashes.baseline != .artifact_hashes.challenger' "${receipt_empty_dir}")"
assert_eq "T5c: directory-only difference invokes both judge orders" "$((calls_before + 2))" \
  "$(cat "${MOCK_LOG_DIR}/counter")"

printf 'T5d: special filesystem nodes are rejected before copy or judge\n'
cp -R "${WORK}/artifacts/crafted" "${WORK}/artifacts/with-fifo"
mkfifo "${WORK}/artifacts/with-fifo/host-stream"
make_summary "${WORK}/with-fifo.json" "${WORK}/artifacts/with-fifo" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; fifo_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/with-fifo.json" \
  --out "${WORK}/pair-fifo" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T5d: FIFO package exits 2" "2" "${rc}"
assert_contains "T5d: special-node package cannot forge a generation" \
  "artifact package contains a symlink or special filesystem node" "${fifo_out}"

printf 'T5e: artifact file, entry, and byte budgets fail before packaging\n'
rc=0; limit_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-file-limit" \
  --judge-bin "${WORK}/mock-judge" --max-artifact-files 1 2>&1)" || rc=$?
assert_eq "T5e: file limit exits 2" "2" "${rc}"
assert_contains "T5e: file limit is explicit" "configured file limit" "${limit_out}"
rc=0; limit_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-byte-limit" \
  --judge-bin "${WORK}/mock-judge" --max-artifact-bytes 1 2>&1)" || rc=$?
assert_eq "T5e: byte limit exits 2" "2" "${rc}"
assert_contains "T5e: byte limit is explicit" "configured byte limit" "${limit_out}"
rc=0; limit_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/same-a.json" \
  --challenger "${WORK}/with-empty-dir.json" \
  --out "${WORK}/pair-entry-limit" \
  --campaign-run dev-run-same --judge-bin "${WORK}/mock-judge" --max-artifact-entries 2 2>&1)" || rc=$?
assert_eq "T5e: directory-entry limit exits 2" "2" "${rc}"
assert_contains "T5e: entry limit is explicit" \
  "configured entry limit" "${limit_out}"

mkdir -p "${WORK}/artifacts/inode-cap/nested"
printf 'one\n' > "${WORK}/artifacts/inode-cap/one.txt"
printf 'two\n' > "${WORK}/artifacts/inode-cap/nested/two.txt"
inode_cap_result="$(bash -c '
  source "$1"
  manifest="$(mktemp -t omc-inode-cap-test-XXXXXX)"
  if artifact_tree_inode_manifest "$2" "${manifest}" 1; then
    printf unbounded
  else
    printf bounded
  fi
  rm -f "${manifest}"
' pairwise-inode-cap "${PAIRWISE}" "${WORK}/artifacts/inode-cap")"
assert_eq "T5e: inode-alias traversal stops at its independent entry cap" \
  "bounded" "${inode_cap_result}"

printf 'T5f: compare freezes candidate authority before output/campaign admission\n'
cp -R "${WORK}/artifacts/crafted" "${WORK}/artifacts/mutating-after-preflight"
make_summary "${WORK}/mutating-after-preflight.json" \
  "${WORK}/artifacts/mutating-after-preflight" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
(
  while [[ ! -d "${WORK}/pair-mutating-after-preflight/candidates" ]]; do :; done
  mkdir -p "${WORK}/artifacts/mutating-after-preflight/late-empty-directory"
) &
mutator_pid=$!
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
rc=0; mutation_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/mutating-after-preflight.json" \
  --out "${WORK}/pair-mutating-after-preflight" \
  --judge-bin "${WORK}/mock-judge" --max-artifact-entries 20 \
  --seed stable-seed 2>&1)" || rc=$?
kill "${mutator_pid}" 2>/dev/null || true
wait "${mutator_pid}" 2>/dev/null || true
assert_eq "T5f: post-freeze live entry growth cannot change comparison" "0" "${rc}"
assert_contains "T5f: frozen comparison still publishes its receipt" \
  "${WORK}/pair-mutating-after-preflight/receipt.json" "${mutation_out}"
assert_eq "T5f: both judge orders consume the frozen artifact snapshot" \
  "$((calls_before + 2))" "$(cat "${MOCK_LOG_DIR}/counter")"

IDENTITY_FREEZE_MANIFEST="${WORK}/identity-freeze-manifest.json"
cp "${IDENTITY_MANIFEST}" "${IDENTITY_FREEZE_MANIFEST}"
IDENTITY_FREEZE_OUT="${WORK}/pair-identity-freeze"
(
  while [[ ! -d "${IDENTITY_FREEZE_OUT}" ]]; do :; done
  jq '.campaign_id="post-freeze-mutated-campaign"' "${IDENTITY_FREEZE_MANIFEST}" \
    > "${IDENTITY_FREEZE_MANIFEST}.replacement"
  mv "${IDENTITY_FREEZE_MANIFEST}.replacement" "${IDENTITY_FREEZE_MANIFEST}"
) &
identity_mutator_pid=$!
rc=0; identity_freeze_out="$(bash "${PAIRWISE}" compare \
  --identity-manifest "${IDENTITY_FREEZE_MANIFEST}" \
  --baseline-harness "${BASELINE_HARNESS}" --challenger-harness "${CHALLENGER_HARNESS}" \
  --campaign-run dev-run-win --judge-model judge-test-model-1 \
  --probe quality-config-diagnostics --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" --out "${IDENTITY_FREEZE_OUT}" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed 2>&1)" || rc=$?
wait "${identity_mutator_pid}" 2>/dev/null || true
assert_eq "T5f: post-freeze identity-manifest replacement cannot mix authority" "0" "${rc}"
assert_contains "T5f: frozen identity comparison publishes its receipt" \
  "${IDENTITY_FREEZE_OUT}/receipt.json" "${identity_freeze_out}"
assert_eq "T5f: pair embeds the pre-replacement identity manifest" "pairwise-test-v1" \
  "$(jq -r '.pair_manifest.provenance.harness_identity.manifest.campaign_id' \
    "${IDENTITY_FREEZE_OUT}/receipt.json")"

printf 'T5f2: evaluator authority freezes schema, probes, calibration, and fixtures as one generation\n'
EVALUATOR_AUTHORITY_LIVE="${WORK}/evaluator-authority-live"
EVALUATOR_AUTHORITY_SNAPSHOT="${WORK}/evaluator-authority-snapshot"
mkdir -p "${EVALUATOR_AUTHORITY_LIVE}/judge-calibration"
cp "${REPO_ROOT}/evals/realwork/judge-schema.json" \
  "${EVALUATOR_AUTHORITY_LIVE}/judge-schema.json"
cp "${REPO_ROOT}/evals/realwork/judge-calibration/cases.json" \
  "${EVALUATOR_AUTHORITY_LIVE}/judge-calibration/cases.json"
cp -R "${REPO_ROOT}/evals/realwork/quality-probes" \
  "${EVALUATOR_AUTHORITY_LIVE}/quality-probes"
cp -R "${REPO_ROOT}/evals/realwork/fixtures" \
  "${EVALUATOR_AUTHORITY_LIVE}/fixtures"
authority_freeze_result="$(bash -c '
  source "$1"
  live_root="$2"
  snapshot_root="$3"
  JUDGE_SCHEMA="${live_root}/judge-schema.json"
  CALIBRATION_MANIFEST="${live_root}/judge-calibration/cases.json"
  PROBE_DIR="${live_root}/quality-probes"
  FIXTURE_ROOT="${live_root}"
  live_seal="$(evaluator_authority_seal_json)"
  live_schema_hash="$(canonical_json_hash "${JUDGE_SCHEMA}")"
  mkdir "${snapshot_root}"
  freeze_evaluator_authority_to "${live_seal}" "${snapshot_root}"
  JUDGE_SCHEMA="${snapshot_root}/judge-schema.json"
  CALIBRATION_MANIFEST="${snapshot_root}/judge-calibration.json"
  PROBE_DIR="${snapshot_root}/quality-probes"
  FIXTURE_ROOT="${snapshot_root}"
  snapshot_seal="$(evaluator_authority_seal_json)"
  printf "\n" >> "${live_root}/judge-schema.json"
  printf "\nlate fixture mutation\n" \
    >> "${live_root}/fixtures/quality/config-diagnostics/source/config-layers.txt"
  snapshot_ok=false
  live_stale=false
  schema_same=false
  evaluator_authority_matches_seal "${snapshot_seal}" && snapshot_ok=true
  evaluator_authority_matches_seal "${live_seal}" || live_stale=true
  [[ "$(canonical_json_hash "${JUDGE_SCHEMA}")" == "${live_schema_hash}" ]] \
    && schema_same=true
  jq -cn --argjson snapshot_ok "${snapshot_ok}" \
    --argjson live_stale "${live_stale}" --argjson schema_same "${schema_same}" \
    "{snapshot_ok:\$snapshot_ok,live_stale:\$live_stale,schema_same:\$schema_same}"
' pairwise-evaluator-authority-freeze "${PAIRWISE}" \
  "${EVALUATOR_AUTHORITY_LIVE}" "${EVALUATOR_AUTHORITY_SNAPSHOT}")"
assert_eq "T5f2: private authority remains exact while live schema/fixture drift" \
  "true" "$(jq -r '.snapshot_ok and .live_stale and .schema_same' \
    <<<"${authority_freeze_result}")"

judge_cleanup_result="$(bash -c '
  source "$1"
  root="$2"
  ACTIVE_COMPARE_SNAPSHOT_DIR="${root}/command"
  ACTIVE_JUDGE_WORKSPACE="${root}/judge"
  ACTIVE_JUDGE_CAPTURE="${root}/capture"
  ACTIVE_IDENTITY_MANIFEST_SNAPSHOT="${root}/identity.json"
  COMPARISON_PROBE_SEAL="sealed-probe-generation"
  mkdir -p "${ACTIVE_COMPARE_SNAPSHOT_DIR}" "${ACTIVE_JUDGE_WORKSPACE}" \
    "${ACTIVE_JUDGE_CAPTURE}"
  printf "{}\n" > "${ACTIVE_IDENTITY_MANIFEST_SNAPSHOT}"
  cleanup_active_judge_workspace
  jq -cn --argjson judge_gone \
      "$([[ ! -e "${root}/judge" && ! -e "${root}/capture" ]] \
        && printf true || printf false)" \
    --argjson command_alive \
      "$([[ -d "${root}/command" && -f "${root}/identity.json" ]] \
        && printf true || printf false)" \
    --arg probe_seal "${COMPARISON_PROBE_SEAL}" \
    "{judge_gone:\$judge_gone,command_alive:\$command_alive,probe_seal:\$probe_seal}"
' pairwise-judge-cleanup-boundary "${PAIRWISE}" \
  "${WORK}/judge-cleanup-boundary")"
assert_eq "T5f2: per-order cleanup preserves command authority for reverse order" \
  "true" "$(jq -r '
    .judge_gone and .command_alive and .probe_seal == "sealed-probe-generation"
  ' <<<"${judge_cleanup_result}")"

REPORT_AUTHORITY_LIVE="${WORK}/report-authority-live"
mkdir -p "${REPORT_AUTHORITY_LIVE}/judge-calibration"
cp "${REPO_ROOT}/evals/realwork/judge-schema.json" \
  "${REPORT_AUTHORITY_LIVE}/judge-schema.json"
cp "${REPO_ROOT}/evals/realwork/judge-calibration/cases.json" \
  "${REPORT_AUTHORITY_LIVE}/judge-calibration/cases.json"
cp -R "${REPO_ROOT}/evals/realwork/quality-probes" \
  "${REPORT_AUTHORITY_LIVE}/quality-probes"
cp -R "${REPO_ROOT}/evals/realwork/fixtures" \
  "${REPORT_AUTHORITY_LIVE}/fixtures"
rc=0; report_authority_out="$(bash -c '
  source "$1"
  trap cleanup_active_command_snapshots EXIT
  live_root="$2"
  MUTATION_LIVE_FIXTURE="${live_root}/fixtures/quality/config-diagnostics/source/config-layers.txt"
  MUTATION_MARKER="$4"
  JUDGE_SCHEMA="${live_root}/judge-schema.json"
  CALIBRATION_MANIFEST="${live_root}/judge-calibration/cases.json"
  PROBE_DIR="${live_root}/quality-probes"
  FIXTURE_ROOT="${live_root}"
  eval "$(declare -f receipt_is_valid \
    | sed "1s/receipt_is_valid/real_receipt_is_valid/")"
  receipt_is_valid() {
    local rc=0
    real_receipt_is_valid "$1" || rc=$?
    if [[ "${rc}" -eq 0 && ! -e "${MUTATION_MARKER}" ]]; then
      printf "\nlate report fixture mutation\n" >> "${MUTATION_LIVE_FIXTURE}"
      : > "${MUTATION_MARKER}"
    fi
    return "${rc}"
  }
  cmd_report "$3"
' pairwise-report-authority-race "${PAIRWISE}" \
  "${REPORT_AUTHORITY_LIVE}" "${IDENTITY_FREEZE_OUT}/receipt.json" \
  "${WORK}/report-authority-mutation-fired" 2>&1)" || rc=$?
assert_eq "T5f2: report refuses live fixture drift after frozen validation" "2" "${rc}"
assert_contains "T5f2: report fixture drift failure is explicit" \
  "report evaluator authority changed before result publication" \
  "${report_authority_out}"
assert_eq "T5f2: report authority mutation shim was exercised" "true" \
  "$([[ -f "${WORK}/report-authority-mutation-fired" ]] \
    && printf true || printf false)"

printf 'T5g: a regular-file-to-FIFO swap during copy is bounded and rejected\n'
mkdir -p "${WORK}/artifacts/copy-race" "${WORK}/copy-race-snapshot"
printf 'regular before the size check\n' > "${WORK}/artifacts/copy-race/work.txt"
# The CLI is explicitly source-safe so deterministic race tests exercise the
# real implementation and retain its canonical asset directory.
PAIRWISE_LIBRARY="${PAIRWISE}"
copy_started_at="$(date +%s)"
rc=0; copy_race_out="$(bash -c '
  source "$1"
  race_source="$2"
  race_file="${race_source}"
  regular_file_size() {
    local file="$1" size=""
    size="$(stat -f "%z" "${file}" 2>/dev/null || true)"
    if ! is_uint "${size}"; then
      size="$(stat -c "%s" "${file}" 2>/dev/null || true)"
    fi
    is_uint "${size}" || return 1
    if [[ "${file}" == "${race_file}" && -f "${file}" ]]; then
      rm -f "${file}"
      mkfifo "${file}"
    fi
    printf "%s\n" "${size}"
  }
  copy_artifact "$(dirname "${race_source}")" "$3" "" 10 10 4096 1
' pairwise-copy-race "${PAIRWISE_LIBRARY}" \
  "${WORK}/artifacts/copy-race/work.txt" "${WORK}/copy-race-snapshot" 2>&1)" || rc=$?
copy_elapsed=$(( $(date +%s) - copy_started_at ))
assert_eq "T5g: swapped FIFO exits 2" "2" "${rc}"
assert_contains "T5g: bounded snapshot failure is explicit" \
  "artifact file changed, blocked, or exceeded the configured copy limits" "${copy_race_out}"
assert_eq "T5g: FIFO copy cannot hang the evaluator" "true" \
  "$([[ "${copy_elapsed}" -le 5 ]] && printf true || printf false)"

printf 'T5g1: copy deadlines apply per blocking I/O rather than cumulatively\n'
mkdir "${WORK}/copy-per-io-deadline"
printf 'stable payload on a deliberately slow host\n' \
  > "${WORK}/copy-per-io-deadline/source.txt"
mkdir "${WORK}/copy-per-io-deadline/out"
per_io_started_at="$(date +%s)"
rc=0; bash -c '
  source "$1"
  shasum() {
    sleep 0.2
    command shasum "$@"
  }
  _copy_regular_file_bounded "$2/source.txt" "$2/out/result.txt" 8 0 1
' pairwise-copy-per-io-deadline "${PAIRWISE_LIBRARY}" \
  "${WORK}/copy-per-io-deadline" >/dev/null 2>&1 || rc=$?
per_io_elapsed=$(( $(date +%s) - per_io_started_at ))
assert_eq "T5g1: individually bounded slow reads still publish" "0" "${rc}"
assert_eq "T5g1: slow-read copy preserves exact bytes" \
  "stable payload on a deliberately slow host" \
  "$(tr -d '\n' < "${WORK}/copy-per-io-deadline/out/result.txt")"
assert_eq "T5g1: regression transaction exceeds one cumulative deadline" "true" \
  "$([[ "${per_io_elapsed}" -ge 1 && "${per_io_elapsed}" -le 15 ]] \
    && printf true || printf false)"

mkdir "${WORK}/copy-destination-external"
ln -s "${WORK}/copy-destination-external" "${WORK}/copy-destination-symlink"
rc=0; destination_symlink_out="$(bash -c '
  source "$1"
  copy_artifact "$2" "$3" "" 10 10 4096 1
' pairwise-copy-destination "${PAIRWISE_LIBRARY}" \
  "${WORK}/artifacts/generic" "${WORK}/copy-destination-symlink" 2>&1)" || rc=$?
assert_eq "T5g: symlinked artifact destination root exits 2" "2" "${rc}"
assert_contains "T5g: copy refuses a non-physical destination root" \
  "unsafe or missing parent" "${destination_symlink_out}"
assert_eq "T5g: rejected destination symlink writes nothing outside the snapshot" \
  "0" "$(find "${WORK}/copy-destination-external" -mindepth 1 | wc -l | tr -d '[:space:]')"

printf 'T5h: final-file publication refuses every pre-existing node type without opening it\n'
mkdir "${WORK}/copy-final-nodes"
printf 'bounded evaluator source\n' > "${WORK}/copy-final-nodes/source.txt"
for destination_kind in symlink hardlink fifo; do
  destination_root="${WORK}/copy-final-${destination_kind}"
  mkdir "${destination_root}"
  sentinel="${WORK}/copy-final-nodes/${destination_kind}-sentinel.txt"
  printf 'sentinel-%s\n' "${destination_kind}" > "${sentinel}"
  case "${destination_kind}" in
    symlink) ln -s "${sentinel}" "${destination_root}/result.txt" ;;
    hardlink) ln "${sentinel}" "${destination_root}/result.txt" ;;
    fifo) mkfifo "${destination_root}/result.txt" ;;
  esac
  sentinel_before="$(shasum -a 256 "${sentinel}" | awk '{print $1}')"
  rc=0; bash -c '
    source "$1"
    _copy_regular_file_bounded "$2" "$3" 8
  ' pairwise-copy-final-node "${PAIRWISE_LIBRARY}" \
    "${WORK}/copy-final-nodes/source.txt" "${destination_root}/result.txt" \
    >/dev/null 2>&1 || rc=$?
  assert_eq "T5h: pre-existing ${destination_kind} final node is rejected" "1" "${rc}"
  assert_eq "T5h: ${destination_kind} target is never opened or changed" \
    "${sentinel_before}" "$(shasum -a 256 "${sentinel}" | awk '{print $1}')"
  case "${destination_kind}" in
    symlink) assert_eq "T5h: rejected symlink remains a symlink" "true" \
      "$([[ -L "${destination_root}/result.txt" ]] && printf true || printf false)" ;;
    hardlink) assert_eq "T5h: rejected hardlink retains shared identity" "true" \
      "$([[ "${sentinel}" -ef "${destination_root}/result.txt" ]] && printf true || printf false)" ;;
    fifo) assert_eq "T5h: rejected FIFO remains a FIFO" "true" \
      "$([[ -p "${destination_root}/result.txt" ]] && printf true || printf false)" ;;
  esac
done

printf 'T5h2: a post-link seal failure leaves a fail-closed publication fence\n'
mkdir "${WORK}/copy-final-seal-failure"
printf 'staged evaluator bytes\n' > "${WORK}/copy-final-seal-failure/.stage"
rc=0; bash -c '
  source "$1"
  target="$3"
  eval "$(declare -f regular_file_seal_json \
    | sed "1s/regular_file_seal_json/real_regular_file_seal_json/")"
  regular_file_seal_json() {
    [[ "$1" != "${target}" ]] || return 1
    real_regular_file_seal_json "$1"
  }
  parent_inode="$(file_inode_identity "$2")"
  publish_new_regular_file_no_follow "$2/.stage" "${target}" "${parent_inode}"
' pairwise-post-link-seal-failure "${PAIRWISE_LIBRARY}" \
  "${WORK}/copy-final-seal-failure" \
  "${WORK}/copy-final-seal-failure/result.txt" >/dev/null 2>&1 || rc=$?
assert_eq "T5h2: injected final-seal failure is rejected" "1" "${rc}"
assert_eq "T5h2: failed publication retains its exact regular fence" "true" \
  "$([[ -f "${WORK}/copy-final-seal-failure/result.txt" \
        && ! -L "${WORK}/copy-final-seal-failure/result.txt" ]] \
      && printf true || printf false)"
assert_eq "T5h2: retained publication fence preserves evaluator bytes" \
  "staged evaluator bytes" \
  "$(tr -d '\n' <"${WORK}/copy-final-seal-failure/result.txt")"

printf 'T5h2: raced foreign replacement nodes are never deleted by pathname\n'
for raced_kind in wrong-inode symlink fifo nonempty-dir; do
  raced_root="${WORK}/copy-final-raced-${raced_kind}"
  mkdir "${raced_root}"
  printf 'sealed staged bytes\n' > "${raced_root}/.stage"
  printf 'external sentinel\n' > "${raced_root}/sentinel.txt"
  rc=0; bash -c '
    source "$1"
    raced_kind="$2"
    root="$3"
    target="${root}/result.txt"
    ln() {
      local source="$1" destination="$2"
      case "${raced_kind}" in
        wrong-inode)
          rm -f "${source}"
          printf "substituted staged bytes\n" > "${source}"
          command ln "${source}" "${destination}"
          ;;
        symlink)
          command ln "${source}" "${destination}"
          rm -f "${destination}"
          command ln -s "${root}/sentinel.txt" "${destination}"
          ;;
        fifo)
          command ln "${source}" "${destination}"
          rm -f "${destination}"
          mkfifo "${destination}"
          ;;
        nonempty-dir)
          command ln "${source}" "${destination}"
          rm -f "${destination}"
          mkdir "${destination}"
          printf "attacker payload\n" > "${destination}/payload.txt"
          ;;
      esac
    }
    parent_inode="$(file_inode_identity "${root}")"
    publish_new_regular_file_no_follow "${root}/.stage" \
      "${target}" "${parent_inode}"
  ' pairwise-raced-final-node "${PAIRWISE_LIBRARY}" "${raced_kind}" \
    "${raced_root}" >/dev/null 2>&1 || rc=$?
  assert_eq "T5h2: raced ${raced_kind} publication is rejected" "1" "${rc}"
  assert_eq "T5h2: raced ${raced_kind} foreign node remains untouched" "true" \
    "$([[ -e "${raced_root}/result.txt" || -L "${raced_root}/result.txt" ]] \
      && printf true || printf false)"
  case "${raced_kind}" in
    wrong-inode)
      assert_eq "T5h2: wrong-inode replacement remains a regular file" "true" \
        "$([[ -f "${raced_root}/result.txt" \
              && ! -L "${raced_root}/result.txt" ]] \
          && printf true || printf false)"
      assert_eq "T5h2: wrong-inode replacement payload is exact" \
        "substituted staged bytes" \
        "$(tr -d '\n' <"${raced_root}/result.txt")"
      ;;
    symlink)
      assert_eq "T5h2: raced symlink retains its exact type" "true" \
        "$([[ -L "${raced_root}/result.txt" ]] \
          && printf true || printf false)"
      assert_eq "T5h2: raced symlink retains its exact target" \
        "${raced_root}/sentinel.txt" "$(readlink "${raced_root}/result.txt")"
      assert_eq "T5h2: raced symlink target payload is intact" \
        "external sentinel" "$(tr -d '\n' <"${raced_root}/sentinel.txt")"
      ;;
    fifo)
      assert_eq "T5h2: raced FIFO retains its exact type" "true" \
        "$([[ -p "${raced_root}/result.txt" ]] \
          && printf true || printf false)"
      ;;
    nonempty-dir)
      assert_eq "T5h2: raced directory retains its exact type" "true" \
        "$([[ -d "${raced_root}/result.txt" \
              && ! -L "${raced_root}/result.txt" ]] \
          && printf true || printf false)"
      ;;
  esac
done
assert_eq "T5h2: foreign non-empty directory payload remains intact" \
  "attacker payload" \
  "$(tr -d '\n' <"${WORK}/copy-final-raced-nonempty-dir/result.txt/payload.txt")"

printf 'T5h2a: cleanup boundary never unlinks a late foreign replacement\n'
cleanup_race_root="${WORK}/copy-final-cleanup-boundary"
mkdir "${cleanup_race_root}"
printf 'cleanup staged bytes\n' >"${cleanup_race_root}/.stage"
printf 'cleanup foreign payload\n' >"${cleanup_race_root}/sentinel.txt"
cleanup_ready="${cleanup_race_root}/cleanup-ready"
cleanup_release="${cleanup_race_root}/cleanup-release"
(
  OMC_TEST_PAIRWISE_CLEANUP_READY_FILE="${cleanup_ready}" \
  OMC_TEST_PAIRWISE_CLEANUP_RELEASE_FILE="${cleanup_release}" \
  bash -c '
    source "$1"
    target="$3"
    eval "$(declare -f regular_file_seal_json \
      | sed "1s/regular_file_seal_json/real_regular_file_seal_json/")"
    regular_file_seal_json() {
      [[ "$1" != "${target}" ]] || return 1
      real_regular_file_seal_json "$1"
    }
    publish_new_regular_file_no_follow "$2/.stage" "${target}" \
      "$(file_inode_identity "$2")"
  ' pairwise-cleanup-boundary "${PAIRWISE_LIBRARY}" \
    "${cleanup_race_root}" "${cleanup_race_root}/result.txt" \
    >/dev/null 2>&1
) &
cleanup_race_pid=$!
cleanup_ready_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${cleanup_ready}" ]]; then
    cleanup_ready_seen=1
    break
  fi
  kill -0 "${cleanup_race_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T5h2a: publication reaches cleanup boundary" "1" \
  "${cleanup_ready_seen}"
rm -f "${cleanup_race_root}/result.txt"
mkdir "${cleanup_race_root}/result.txt"
printf 'late foreign directory payload\n' \
  >"${cleanup_race_root}/result.txt/payload.txt"
: >"${cleanup_release}"
rc=0; wait "${cleanup_race_pid}" || rc=$?
assert_eq "T5h2a: injected cleanup-boundary publication is rejected" "1" \
  "${rc}"
assert_eq "T5h2a: late replacement retains directory type" "true" \
  "$([[ -d "${cleanup_race_root}/result.txt" \
        && ! -L "${cleanup_race_root}/result.txt" ]] \
    && printf true || printf false)"
assert_eq "T5h2a: late replacement payload survives cleanup" \
  "late foreign directory payload" \
  "$(tr -d '\n' <"${cleanup_race_root}/result.txt/payload.txt")"

printf 'T5h2b: an output-specific reconcile claim excludes a competing valid publisher\n'
reconcile_claim_root="${WORK}/reconcile-output-claim"
mkdir "${reconcile_claim_root}"
reconcile_claim_output="${reconcile_claim_root}/receipt.json"
reconcile_claim_ready="${reconcile_claim_root}/owner-ready"
reconcile_claim_release="${reconcile_claim_root}/owner-release"
bash -c '
  source "$1"
  output="$2"
  acquire_reconcile_output_claim "${output}"
  : >"$3"
  while [[ ! -e "$4" ]]; do sleep 0.01; done
  staged="$(stage_file_in_parent "$(dirname "${output}")" \
    "$(file_inode_identity "$(dirname "${output}")")" .claim-owner)"
  printf "owner evidence\n" >"${staged}"
  publish_new_regular_file_no_follow "${staged}" "${output}" \
    "$(file_inode_identity "$(dirname "${output}")")"
  release_reconcile_output_claim
' pairwise-reconcile-claim-owner "${PAIRWISE_LIBRARY}" \
  "${reconcile_claim_output}" "${reconcile_claim_ready}" \
  "${reconcile_claim_release}" &
reconcile_claim_owner_pid=$!
reconcile_claim_ready_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${reconcile_claim_ready}" ]]; then
    reconcile_claim_ready_seen=1
    break
  fi
  kill -0 "${reconcile_claim_owner_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T5h2b: output claimant publishes its owner record" "1" \
  "${reconcile_claim_ready_seen}"
rc=0; bash -c '
  source "$1"
  acquire_reconcile_output_claim "$2"
' pairwise-reconcile-claim-contender "${PAIRWISE_LIBRARY}" \
  "${reconcile_claim_output}" >/dev/null 2>&1 || rc=$?
assert_eq "T5h2b: competing reconciler cannot acquire the same output" "1" "${rc}"
assert_eq "T5h2b: rejected contender cannot publish or retire owner evidence" "false" \
  "$([[ -e "${reconcile_claim_output}" || -L "${reconcile_claim_output}" ]] \
    && printf true || printf false)"
: >"${reconcile_claim_release}"
rc=0; wait "${reconcile_claim_owner_pid}" || rc=$?
assert_eq "T5h2b: output claimant publishes successfully" "0" "${rc}"
assert_eq "T5h2b: exact claimant bytes survive" "owner evidence" \
  "$(tr -d '\n' <"${reconcile_claim_output}")"
assert_eq "T5h2b: successful owner removes its exact claim" "0" \
  "$(find "${reconcile_claim_root}" -maxdepth 1 -type d \
    -name '.pairwise-reconcile-claim.*' | wc -l | tr -d '[:space:]')"

printf 'T5h2c: a SIGKILLed reconcile claimant is recovered by its successor\n'
reconcile_kill_root="${WORK}/reconcile-output-killed-owner"
mkdir "${reconcile_kill_root}"
reconcile_kill_output="${reconcile_kill_root}/receipt.json"
reconcile_kill_ready="${reconcile_kill_root}/owner-ready"
bash -c '
  source "$1"
  acquire_reconcile_output_claim "$2"
  : >"$3"
  while :; do sleep 1; done
' pairwise-reconcile-killed-owner "${PAIRWISE_LIBRARY}" \
  "${reconcile_kill_output}" "${reconcile_kill_ready}" &
reconcile_kill_pid=$!
reconcile_kill_ready_seen=0
for _wait in $(seq 1 500); do
  if [[ -e "${reconcile_kill_ready}" ]]; then
    reconcile_kill_ready_seen=1
    break
  fi
  kill -0 "${reconcile_kill_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T5h2c: first claimant publishes its owner record" "1" \
  "${reconcile_kill_ready_seen}"
reconcile_kill_claim="$(find "${reconcile_kill_root}" -maxdepth 1 \
  -type d -name '.pairwise-reconcile-claim.*' -print | head -n 1)"
assert_eq "T5h2c: claim binds PID, birth identity, token, and lease" "true" \
  "$(jq -r --argjson pid "${reconcile_kill_pid}" '
      .schema_version == 1 and .pid == $pid
      and (.process_identity | test("^[0-9a-f]{64}$"))
      and (.owner_token | test("^reconcile-owner-[0-9a-f]{64}$"))
      and (.claimed_at | type == "number")
      and (.lease_expires_at > .claimed_at)
    ' "${reconcile_kill_claim}/owner.json" 2>/dev/null || printf false)"
if kill -0 "${reconcile_kill_pid}" 2>/dev/null; then
  kill -KILL "${reconcile_kill_pid}"
fi
wait "${reconcile_kill_pid}" 2>/dev/null || true
assert_eq "T5h2c: killed owner leaves one recoverable claim" "1" \
  "$(find "${reconcile_kill_root}" -maxdepth 1 -type d \
    -name '.pairwise-reconcile-claim.*' | wc -l | tr -d '[:space:]')"
rc=0; bash -c '
  source "$1"
  output="$2"
  parent="$(dirname "${output}")"
  acquire_reconcile_output_claim "${output}"
  staged="$(stage_file_in_parent "${parent}" \
    "$(file_inode_identity "${parent}")" .claim-successor)"
  printf "successor evidence\n" >"${staged}"
  publish_new_regular_file_no_follow "${staged}" "${output}" \
    "$(file_inode_identity "${parent}")"
  release_reconcile_output_claim
' pairwise-reconcile-successor "${PAIRWISE_LIBRARY}" \
  "${reconcile_kill_output}" >/dev/null 2>&1 || rc=$?
assert_eq "T5h2c: successor recovers and publishes" "0" "${rc}"
assert_eq "T5h2c: successor evidence survives" "successor evidence" \
  "$(tr -d '\n' <"${reconcile_kill_output}")"
assert_eq "T5h2c: successor removes recovered fixed claim" "0" \
  "$(find "${reconcile_kill_root}" -maxdepth 1 -type d \
    -name '.pairwise-reconcile-claim.*' | wc -l | tr -d '[:space:]')"

printf 'T5h3: a replacement final-seal failure retains the exact new fence\n'
mkdir "${WORK}/replace-final-seal-failure"
printf 'old evidence\n' > "${WORK}/replace-final-seal-failure/result.txt"
printf 'new evidence\n' > "${WORK}/replace-final-seal-failure/.stage"
rc=0; bash -c '
  source "$1"
  target="$3"
  staged="$2/.stage"
  new_inode="$(file_inode_identity "${staged}")"
  old_seal="$(regular_file_seal_json "${target}")"
  eval "$(declare -f regular_file_seal_json \
    | sed "1s/regular_file_seal_json/real_regular_file_seal_json/")"
  regular_file_seal_json() {
    if [[ "$1" == "${target}" \
        && "$(file_inode_identity "$1" 2>/dev/null || true)" == "${new_inode}" ]]; then
      return 1
    fi
    real_regular_file_seal_json "$1"
  }
  parent_inode="$(file_inode_identity "$2")"
  replace_regular_file_no_follow "${staged}" "${target}" \
    "${parent_inode}" "${old_seal}"
' pairwise-replace-seal-failure "${PAIRWISE_LIBRARY}" \
  "${WORK}/replace-final-seal-failure" \
  "${WORK}/replace-final-seal-failure/result.txt" >/dev/null 2>&1 || rc=$?
assert_eq "T5h3: injected replacement seal failure is rejected" "1" "${rc}"
assert_eq "T5h3: failed replacement leaves its new regular fence" "true" \
  "$([[ -f "${WORK}/replace-final-seal-failure/result.txt" \
        && ! -L "${WORK}/replace-final-seal-failure/result.txt" ]] \
      && printf true || printf false)"
assert_eq "T5h3: failed replacement preserves exact new bytes" \
  "new evidence" \
  "$(tr -d '\n' <"${WORK}/replace-final-seal-failure/result.txt")"

printf 'T5h4: judge audit publication records the exact copied inode, not a late replacement\n'
mkdir "${WORK}/judge-record-race"
printf 'captured judge bytes\n' > "${WORK}/judge-record-race/source.json"
rc=0; judge_record_race_state="$(bash -c '
  source "$1"
  root="$2"
  eval "$(declare -f _copy_regular_file_bounded \
    | sed "1s/_copy_regular_file_bounded/real_copy_regular_file_bounded/")"
  _copy_regular_file_bounded() {
    local seal
    seal="$(real_copy_regular_file_bounded "$1" "$2" "$3" 1)" || return 1
    cp -pP "$2" "$2.replacement"
    mv "$2.replacement" "$2"
    printf "%s\n" "${seal}"
  }
  COMPARISON_PUBLISHED_JUDGE_FILES=""
  COMPARISON_PUBLISHED_JUDGE_SEALS="[]"
  root_inode="$(file_inode_identity "${root}")"
  inner_rc=0
  copy_and_record_comparison_file "${root}" "${root_inode}" \
    "${root}/source.json" "judge-forward.attempt-1.json" 8 || inner_rc=$?
  printf "files=%s seals=%s\n" "${COMPARISON_PUBLISHED_JUDGE_FILES}" \
    "${COMPARISON_PUBLISHED_JUDGE_SEALS}"
  exit "${inner_rc}"
' pairwise-judge-record-race "${PAIRWISE_LIBRARY}" \
  "${WORK}/judge-record-race" 2>&1)" || rc=$?
assert_eq "T5h4: same-byte late inode replacement is rejected" "1" "${rc}"
assert_eq "T5h4: rejected late foreign replacement remains untouched" \
  "true" "$([[ -e "${WORK}/judge-record-race/judge-forward.attempt-1.json" \
      || -L "${WORK}/judge-record-race/judge-forward.attempt-1.json" ]] \
    && printf true || printf false)"
assert_not_contains "T5h4: rejected late replacement is never added to judge inventory" \
  "files=judge-forward" "${judge_record_race_state}"

printf 'T6: candidate-authored diagnostics cannot exercise critical veto authority\n'
make_summary "${WORK}/broken-flashy.json" "${WORK}/artifacts/broken" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" false 1.5 120 180 110
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_nonveto="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/broken-flashy.json" \
  --out "${WORK}/pair-veto" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed)"
assert_eq "T6: semantic/self-attested failure reaches judge" "judge" "$(jq -r '.basis' "${receipt_nonveto}")"
assert_eq "T6: noncritical failure is retained diagnostically" "false" \
  "$(jq -r '.pair_manifest.candidates.challenger.check_results[] | select(.id=="layered_source_case") | .pass' "${receipt_nonveto}")"
assert_eq "T6: noncritical failure cannot populate critical failures" "[]" \
  "$(jq -c '.critical_failures.challenger' "${receipt_nonveto}")"
assert_eq "T6: judge is called twice" "$((calls_before + 2))" "$(cat "${MOCK_LOG_DIR}/counter")"
nonveto_prompt="$(cat "${WORK}/pair-veto/judge-forward.prompt.txt")"
assert_contains "T6: failing deterministic diagnostic is exposed without veto" \
  "layered_source_case: FAIL" "${nonveto_prompt}"
assert_not_contains "T6: diagnostic prompt remains role blind (baseline)" \
  "baseline" "${nonveto_prompt}"
assert_not_contains "T6: diagnostic prompt remains role blind (challenger)" \
  "challenger" "${nonveto_prompt}"
nonveto_report="$(bash "${PAIRWISE}" report "${receipt_nonveto}")"
assert_eq "T6: report identifies the baseline-pass/challenger-fail hard-check regression" "true" \
  "$(jq -r '
    .hard_checks.regression_count == 1
    and .hard_checks.regressions[0].check_id == "layered_source_case"
    and .hard_checks.regressions[0].critical == false
    and .hard_checks.challenger_passes < .hard_checks.baseline_passes
  ' <<<"${nonveto_report}")"
rc=0; nonveto_claim="$(bash "${PAIRWISE}" claim-check "${receipt_nonveto}" \
  --allow-custom-portfolio --min-pairs 0 --min-domains 0 --min-tiers 0 \
  --min-axis-pairs 0 --max-challenger-scope-creep 1 --min-win-rate 0 \
  --max-loss-rate 1 --min-positive-axes 0 --min-visionary-margin 0 \
  --max-sign-p-value 1 --max-median-cost-ratio 10 --max-median-wall-ratio 10 \
  --max-p95-cost-ratio 10 --max-p95-wall-ratio 10 2>&1)" || rc=$?
assert_eq "T6: a noncritical hard-check regression still blocks the quality claim" "1" "${rc}"
assert_eq "T6: hard-check noninferiority is an explicit claim gate" "true" \
  "$(jq -r '.failures | index("hard_check_noninferiority") != null' <<<"${nonveto_claim}")"

printf 'T6a: exact fixture equality remains valid critical veto authority\n'
SUMMARY_RUN_ID=dev-run-control SUMMARY_SEED=control-seed make_probe_summary "${WORK}/minimal-baseline.json" "quality-minimal-change-control" \
  "${MINIMAL_PROMPT_HASH}" "${MINIMAL_FIXTURE_HASH}" "${MINIMAL_SOURCE_HASH}" \
  "${WORK}/artifacts/minimal-ok" "${BASELINE_HARNESS_HASH}" 1 100
SUMMARY_RUN_ID=dev-run-control SUMMARY_SEED=control-seed make_probe_summary "${WORK}/minimal-challenger.json" "quality-minimal-change-control" \
  "${MINIMAL_PROMPT_HASH}" "${MINIMAL_FIXTURE_HASH}" "${MINIMAL_SOURCE_HASH}" \
  "${WORK}/artifacts/minimal-broken" "${CHALLENGER_HARNESS_HASH}" 1.3 100
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_veto="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-minimal-change-control \
  --baseline "${WORK}/minimal-baseline.json" \
  --challenger "${WORK}/minimal-challenger.json" \
  --out "${WORK}/pair-structural-veto" \
  --campaign-run dev-run-control --judge-bin "${WORK}/mock-judge" --seed control-seed)"
assert_eq "T6a: baseline wins structural veto" "baseline" "$(jq -r '.winner' "${receipt_veto}")"
assert_eq "T6a: structural veto basis" "hard-check-veto" "$(jq -r '.basis' "${receipt_veto}")"
assert_contains "T6a: exact fixture mismatch retained" "behavior_unchanged" \
  "$(jq -c '.critical_failures.challenger' "${receipt_veto}")"
assert_eq "T6a: structural veto makes no judge call" "${calls_before}" "$(cat "${MOCK_LOG_DIR}/counter")"
SUMMARY_RUN_ID=dev-run-scope-control SUMMARY_SEED=scope-control-seed \
  make_probe_summary "${WORK}/minimal-scope-baseline.json" "quality-minimal-change-control" \
    "${MINIMAL_PROMPT_HASH}" "${MINIMAL_FIXTURE_HASH}" "${MINIMAL_SOURCE_HASH}" \
    "${WORK}/artifacts/minimal-ok" "${BASELINE_HARNESS_HASH}" 1 100
SUMMARY_RUN_ID=dev-run-scope-control SUMMARY_SEED=scope-control-seed \
  make_probe_summary "${WORK}/minimal-scope-overreach.json" "quality-minimal-change-control" \
    "${MINIMAL_PROMPT_HASH}" "${MINIMAL_FIXTURE_HASH}" "${MINIMAL_SOURCE_HASH}" \
    "${WORK}/artifacts/minimal-overreach" "${CHALLENGER_HARNESS_HASH}" 1 100
calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
receipt_scope_veto="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-minimal-change-control \
  --baseline "${WORK}/minimal-scope-baseline.json" \
  --challenger "${WORK}/minimal-scope-overreach.json" \
  --out "${WORK}/pair-scope-veto" \
  --campaign-run dev-run-scope-control --judge-bin "${WORK}/mock-judge" \
  --seed scope-control-seed)"
assert_eq "T6a: evaluator-owned unrelated changed path fails exact scope check" "false" \
  "$(jq -r '.pair_manifest.candidates.challenger.check_results[]
    | select(.id == "scope_bounded") | .pass' "${receipt_scope_veto}")"
assert_contains "T6a: unrelated changed path is a critical veto" "scope_bounded" \
  "$(jq -c '.critical_failures.challenger' "${receipt_scope_veto}")"
assert_eq "T6a: scope-path structural veto makes no judge call" \
  "${calls_before}" "$(cat "${MOCK_LOG_DIR}/counter")"
assert_eq "T6a: minimal-change probe freezes its stricter 1.25x cost budget" "true" \
  "$(jq -r '
    .probe_campaign.max_candidate_cost_ratio == 1.25
    and .economics.ratios.cost == 1.3
    and .economics.probe_budget_pass.cost == false
  ' "${receipt_veto}")"
rc=0; minimal_budget_claim="$(bash "${PAIRWISE}" claim-check "${receipt_veto}" \
  --allow-custom-portfolio --min-pairs 0 --min-domains 0 --min-tiers 0 \
  --min-axis-pairs 0 --max-challenger-scope-creep 1 \
  --min-win-rate 0 --max-loss-rate 1 --min-positive-axes 0 \
  --min-visionary-margin 0 --max-sign-p-value 1 \
  --max-median-cost-ratio 2 --max-median-wall-ratio 2 \
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2 2>&1)" || rc=$?
assert_eq "T6a: per-probe budget claim exits nonzero" "1" "${rc}"
assert_contains "T6a: per-probe cost limit is an explicit claim blocker" \
  "probe_cost_ratio" "${minimal_budget_claim}"

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
assert_contains "T6b: strict candidate contract rejects checks" \
  "challenger summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${self_attested_out}"

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
assert_contains "T7: fixture mismatch invalidates the causal generation" "generation receipt is invalid" "${mismatch_out}"

printf 'T7b: token economics must be exact integer usage buckets\n'
jq '.economics.tokens.cache_read = 1.5' "${WORK}/challenger.json" > "${WORK}/fractional-tokens.json"
rc=0; token_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/fractional-tokens.json" \
  --out "${WORK}/pair-fractional-tokens" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7b: fractional tokens exit 2" "2" "${rc}"
assert_contains "T7b: invalid candidate summary named" \
  "challenger summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${token_out}"

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
assert_contains "T7c: caller-authored harness provenance is forbidden" \
  "challenger summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${harness_out}"

printf 'T7d: legacy probe aliases cannot bypass the manifest contract\n'
jq '.probe = .probe_id | del(.probe_id)' "${WORK}/challenger.json" > "${WORK}/probe-alias.json"
rc=0; alias_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/probe-alias.json" \
  --out "${WORK}/pair-probe-alias" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7d: missing canonical probe_id exits 2" "2" "${rc}"
assert_contains "T7d: candidate summary contract is enforced" \
  "challenger summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${alias_out}"

printf 'T7f: candidate model IDs must be full and tiers must be probe-sealed\n'
jq '.provenance.model = "sonnet"' "${WORK}/baseline.json" > "${WORK}/alias-model-baseline.json"
jq '.provenance.model = "sonnet"' "${WORK}/challenger.json" > "${WORK}/alias-model-challenger.json"
rc=0; candidate_model_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/alias-model-baseline.json" \
  --challenger "${WORK}/alias-model-challenger.json" \
  --out "${WORK}/pair-candidate-model-alias" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7f: candidate model alias exits 2" "2" "${rc}"
assert_contains "T7f: invalid full candidate model is rejected before judging" \
  "baseline summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${candidate_model_out}"

jq '.provenance.model_tier = "quality"' "${WORK}/baseline.json" > "${WORK}/wrong-tier-baseline.json"
jq '.provenance.model_tier = "quality"' "${WORK}/challenger.json" > "${WORK}/wrong-tier-challenger.json"
rc=0; candidate_tier_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/wrong-tier-baseline.json" \
  --challenger "${WORK}/wrong-tier-challenger.json" \
  --out "${WORK}/pair-candidate-tier" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7f: unregistered candidate tier exits 2" "2" "${rc}"
assert_contains "T7f: selected probe tier contract is explicit" \
  "baseline summary, generation, telemetry, or artifact authority could not be frozen safely" \
  "${candidate_tier_out}"

printf 'T7g: schema-v2 manifests enforce their run/model/tier/seed roster even when custom\n'
SCHEMA2_IDENTITY_MANIFEST="${WORK}/harness-identities-v2.json"
jq '
  .schema_version = 2
  | .judge = {
      binary_name:"claude",
      binary_sha256:("0" * 64),
      calibration_manifest_sha256:"e23994a88b549a2de3356a6b1babff2a9d0a7371cab772febd97d43c2403071d",
      install_location:"user-local-bin",
      cli_version:"1.2.3",
      model_id:"claude-judge-test-1"
    }
  | .portfolio = {
      candidate_model_id:"claude-test-model-1",
      runs:[{
        id:"custom-v2-config-balanced-01",
        probe_id:"quality-config-diagnostics",
        model_tier:"balanced",
        run_index:1,
        comparison_seed:"custom-v2-seed-01"
      }]
    }
' "${IDENTITY_MANIFEST}" > "${SCHEMA2_IDENTITY_MANIFEST}"
SCHEMA2_COMPARE=(bash "${PAIRWISE}" compare
  --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}"
  --baseline-harness "${BASELINE_HARNESS}"
  --challenger-harness "${CHALLENGER_HARNESS}"
  --judge-model "judge-test-model-1")
SCHEMA2_MANIFEST_HASH="$(jq -cS . "${SCHEMA2_IDENTITY_MANIFEST}" | shasum -a 256 | awk '{print $1}')"
SUMMARY_RUN_ID=custom-v2-config-balanced-01 SUMMARY_SEED=custom-v2-seed-01 \
  SUMMARY_IDENTITY_MANIFEST_HASH="${SCHEMA2_MANIFEST_HASH}" \
  make_summary "${WORK}/v2-a.json" "${WORK}/artifacts/identical" \
    "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=custom-v2-config-balanced-01 SUMMARY_SEED=custom-v2-seed-01 \
  SUMMARY_IDENTITY_MANIFEST_HASH="${SCHEMA2_MANIFEST_HASH}" \
  make_summary "${WORK}/v2-b.json" "${WORK}/artifacts/identical-b" \
    "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
rc=0; campaign_run_out="$("${SCHEMA2_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/v2-a.json" \
  --challenger "${WORK}/v2-b.json" \
  --out "${WORK}/pair-v2-missing-run" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7g: schema-v2 comparison without run exits 2" "2" "${rc}"
assert_contains "T7g: schema-v2 run requirement is explicit" \
  "requires the campaign run" "${campaign_run_out}"

rc=0; campaign_seed_out="$("${SCHEMA2_COMPARE[@]}" \
  --campaign-run custom-v2-config-balanced-01 \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/v2-a.json" \
  --challenger "${WORK}/v2-b.json" \
  --out "${WORK}/pair-v2-wrong-seed" \
  --judge-bin "${WORK}/mock-judge" --seed substituted-seed 2>&1)" || rc=$?
assert_eq "T7g: substituted schema-v2 seed exits 2" "2" "${rc}"
assert_contains "T7g: committed seed requirement is explicit" \
  "seed must match the sealed campaign run" "${campaign_seed_out}"

receipt_schema2="$("${SCHEMA2_COMPARE[@]}" \
  --campaign-run custom-v2-config-balanced-01 \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/v2-a.json" \
  --challenger "${WORK}/v2-b.json" \
  --out "${WORK}/pair-v2-bound" \
  --judge-bin "${WORK}/mock-judge")"
assert_eq "T7g: schema-v2 run binding seals exact candidate model and seed" "true" \
  "$(jq -r '
    .campaign_run.id == "custom-v2-config-balanced-01"
    and .campaign_run.candidate_model_id == "claude-test-model-1"
    and .campaign_run.comparison_seed == "custom-v2-seed-01"
    and .pair_manifest.seed == "custom-v2-seed-01"
  ' "${receipt_schema2}")"

printf 'T7h: sealed campaigns bind first producer attempts and exact comparison outputs\n'
CAMPAIGN_UNIQUENESS_ROOT="${WORK}/campaign-uniqueness"
mkdir -p "${CAMPAIGN_UNIQUENESS_ROOT}"
campaign_uniqueness="$(bash -c '
  source "$1"
  uniqueness_root="$2"
  identity_manifest="$3"
  baseline_harness="$4"
  challenger_harness="$5"
  date() { printf "1700000000\n"; }
  target="${uniqueness_root}/campaign"
  cmd_campaign_init --identity-manifest "${identity_manifest}" \
    --baseline-harness "${baseline_harness}" \
    --challenger-harness "${challenger_harness}" --out "${target}" \
    >/dev/null 2>/dev/null
  first_instance="$(jq -r ".policy.campaign_instance_id" "${target}/campaign.json")"
  first_policy="$(jq -r ".policy_hash" "${target}/campaign.json")"
  mv "${target}" "${uniqueness_root}/first"
  cmd_campaign_init --identity-manifest "${identity_manifest}" \
    --baseline-harness "${baseline_harness}" \
    --challenger-harness "${challenger_harness}" --out "${target}" \
    >/dev/null 2>/dev/null
  second_instance="$(jq -r ".policy.campaign_instance_id" "${target}/campaign.json")"
  second_policy="$(jq -r ".policy_hash" "${target}/campaign.json")"
  jq -nc --arg first_instance "${first_instance}" --arg second_instance "${second_instance}" \
    --arg first_policy "${first_policy}" --arg second_policy "${second_policy}" \
    "{instance_unique:(\$first_instance != \$second_instance),policy_unique:(\$first_policy != \$second_policy)}"
' pairwise-campaign-uniqueness "${PAIRWISE_LIBRARY}" \
  "${CAMPAIGN_UNIQUENESS_ROOT}" "${SCHEMA2_IDENTITY_MANIFEST}" \
  "${BASELINE_HARNESS}" "${CHALLENGER_HARNESS}")"
assert_eq "T7h: repeated identical campaign initialization has fresh entropy" "true" \
  "$(jq -r '.instance_unique and .policy_unique' <<<"${campaign_uniqueness}")"

CAMPAIGN_INIT_RACE_ROOT="${WORK}/campaign-init-race"
mkdir -p "${CAMPAIGN_INIT_RACE_ROOT}/barrier"
campaign_init_race="$(bash -c '
  source "$1"
  race_root="$2"
  identity_manifest="$3"
  baseline_harness="$4"
  challenger_harness="$5"
  target="${race_root}/campaign"
  barrier="${race_root}/barrier"
  claim="${target}/.campaign-init-claim"

  run_init() (
    local worker="$1"
    mkdir() {
      if [[ "$#" -eq 1 && "$1" == "${claim}" ]]; then
        : > "${barrier}/${worker}.ready"
        local attempt
        for ((attempt = 0; attempt < 1000; attempt++)); do
          [[ -f "${barrier}/release" ]] && break
          sleep 0.01
        done
        [[ -f "${barrier}/release" ]] || return 70
      fi
      command mkdir "$@"
    }
    cmd_campaign_init --identity-manifest "${identity_manifest}" \
      --baseline-harness "${baseline_harness}" \
      --challenger-harness "${challenger_harness}" --out "${target}"
  )

  run_init first > "${barrier}/first.out" 2> "${barrier}/first.err" &
  first_pid=$!
  run_init second > "${barrier}/second.out" 2> "${barrier}/second.err" &
  second_pid=$!
  barrier_ready=false
  for ((attempt = 0; attempt < 1000; attempt++)); do
    if [[ -f "${barrier}/first.ready" && -f "${barrier}/second.ready" ]]; then
      barrier_ready=true
      break
    fi
    sleep 0.01
  done
  : > "${barrier}/release"
  first_rc=0
  wait "${first_pid}" || first_rc=$?
  second_rc=0
  wait "${second_pid}" || second_rc=$?
  campaign_valid=false
  campaign_file_is_valid "${target}/campaign.json" && campaign_valid=true
  claim_retired=false
  [[ ! -e "${claim}" && ! -L "${claim}" ]] && claim_retired=true
  jq -nc --argjson barrier_ready "${barrier_ready}" \
    --argjson first_rc "${first_rc}" --argjson second_rc "${second_rc}" \
    --argjson campaign_valid "${campaign_valid}" \
    --argjson claim_retired "${claim_retired}" '\''
      {barrier_ready:$barrier_ready,first_rc:$first_rc,second_rc:$second_rc,
       campaign_valid:$campaign_valid,claim_retired:$claim_retired,
       one_winner:(([$first_rc,$second_rc] | sort) == [0,2])}
    '\''
' pairwise-campaign-init-race "${PAIRWISE_LIBRARY}" \
  "${CAMPAIGN_INIT_RACE_ROOT}" "${SCHEMA2_IDENTITY_MANIFEST}" \
  "${BASELINE_HARNESS}" "${CHALLENGER_HARNESS}")"
assert_eq "T7h: synchronized same-output campaign init has one atomic winner" "true" \
  "$(jq -r '
    .barrier_ready and .one_winner and .campaign_valid and .claim_retired
  ' <<<"${campaign_init_race}" 2>/dev/null || printf false)"

SEALED_CAMPAIGN="${WORK}/sealed-campaign"
campaign_policy_path="$(bash "${PAIRWISE}" campaign-init \
  --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" \
  --baseline-harness "${BASELINE_HARNESS}" \
  --challenger-harness "${CHALLENGER_HARNESS}" \
  --out "${SEALED_CAMPAIGN}")"
assert_eq "T7h: campaign policy is sealed before execution" "true" \
  "$(jq -r '
    .status == "sealed-before-execution"
    and (.policy.campaign_instance_id | test("^[0-9a-f]{64}$"))
    and (.policy.probe_bindings[0].producer_task_hash | test("^[0-9a-f]{64}$"))
    and .policy.thresholds.min_pairs == 30
  ' "${campaign_policy_path}")"

# Force both workers past the absent-parent check before either mkdir can run.
# This reproduces the baseline/challenger first-admission race without relying
# on scheduler timing: the mkdir wrappers publish readiness and wait for the
# parent process to release both calls together.
CAMPAIGN_STAGE_PARENT_RACE="${WORK}/campaign-stage-parent-race"
cp -R "${SEALED_CAMPAIGN}" "${CAMPAIGN_STAGE_PARENT_RACE}"
rm -rf \
  "${CAMPAIGN_STAGE_PARENT_RACE}/stages/custom-v2-config-balanced-01"
mkdir -p "${WORK}/campaign-stage-parent-race-barrier"
rc=0; campaign_stage_parent_race="$(bash -c '
  source "$1"
  trap cleanup_active_command_snapshots EXIT
  campaign_dir="$2"
  barrier="$3"
  run_id="custom-v2-config-balanced-01"
  stage_parent="${campaign_dir}/stages/${run_id}"
  freeze_campaign_input "${campaign_dir}" || exit 80
  campaign_snapshot="${ACTIVE_CAMPAIGN_SNAPSHOT}"

  run_stage() (
    trap - EXIT INT TERM HUP
    local stage="$1"
    mkdir() {
      if [[ "$#" -eq 1 && "$1" == "${stage_parent}" ]]; then
        : > "${barrier}/${stage}.ready"
        local attempt
        for ((attempt = 0; attempt < 1000; attempt++)); do
          [[ -f "${barrier}/release" ]] && break
          sleep 0.01
        done
        [[ -f "${barrier}/release" ]] || return 70
      fi
      command mkdir "$@"
    }
    campaign_stage_begin "${campaign_dir}" "${campaign_snapshot}" \
      "${run_id}" "${stage}"
  )

  run_stage baseline > "${barrier}/baseline.out" \
    2> "${barrier}/baseline.err" &
  baseline_pid=$!
  run_stage challenger > "${barrier}/challenger.out" \
    2> "${barrier}/challenger.err" &
  challenger_pid=$!
  barrier_ready=false
  for ((attempt = 0; attempt < 1000; attempt++)); do
    if [[ -f "${barrier}/baseline.ready" \
        && -f "${barrier}/challenger.ready" ]]; then
      barrier_ready=true
      break
    fi
    sleep 0.01
  done
  : > "${barrier}/release"
  baseline_rc=0
  wait "${baseline_pid}" || baseline_rc=$?
  challenger_rc=0
  wait "${challenger_pid}" || challenger_rc=$?

  baseline_claim="${stage_parent}/baseline/claim.json"
  challenger_claim="${stage_parent}/challenger/claim.json"
  baseline_valid=false
  challenger_valid=false
  if campaign_stage_receipt_is_valid "${baseline_claim}" \
      && [[ "$(jq -r ".status" "${baseline_claim}")" == "started" ]]; then
    baseline_valid=true
  fi
  if campaign_stage_receipt_is_valid "${challenger_claim}" \
      && [[ "$(jq -r ".status" "${challenger_claim}")" == "started" ]]; then
    challenger_valid=true
  fi
  baseline_hash="$(jq -r ".receipt_hash // empty" \
    "${baseline_claim}" 2>/dev/null || true)"
  challenger_hash="$(jq -r ".receipt_hash // empty" \
    "${challenger_claim}" 2>/dev/null || true)"
  jq -nc --argjson barrier_ready "${barrier_ready}" \
    --argjson baseline_rc "${baseline_rc}" \
    --argjson challenger_rc "${challenger_rc}" \
    --argjson baseline_valid "${baseline_valid}" \
    --argjson challenger_valid "${challenger_valid}" \
    --arg baseline_hash "${baseline_hash}" \
    --arg challenger_hash "${challenger_hash}" "
      {
        barrier_ready:\$barrier_ready,
        baseline_rc:\$baseline_rc,
        challenger_rc:\$challenger_rc,
        baseline_valid:\$baseline_valid,
        challenger_valid:\$challenger_valid,
        distinct_claims:(\$baseline_hash != \"\" and \$challenger_hash != \"\"
          and \$baseline_hash != \$challenger_hash)
      }
    "
' pairwise-campaign-stage-parent-race "${PAIRWISE_LIBRARY}" \
  "${CAMPAIGN_STAGE_PARENT_RACE}" \
  "${WORK}/campaign-stage-parent-race-barrier" 2>&1)" || rc=$?
assert_eq "T7h: synchronized campaign stage-parent race exits cleanly" "0" "${rc}"
assert_eq "T7h: racing baseline and challenger claims are distinct valid starts" \
  "true" "$(jq -r '
    .barrier_ready
    and .baseline_rc == 0
    and .challenger_rc == 0
    and .baseline_valid
    and .challenger_valid
    and .distinct_claims
  ' <<<"${campaign_stage_parent_race}" 2>/dev/null || printf false)"
sealed_baseline="$(MOCK_PRODUCER_SESSION=sealed-baseline-001 MOCK_PRODUCER_COST=1 \
  MOCK_PRODUCER_SLEEP=2 \
  MOCK_PRODUCER_STYLE=baseline bash "${PAIRWISE}" generate \
    --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
    --harness-role baseline --harness "${BASELINE_HARNESS}" \
    --campaign-run custom-v2-config-balanced-01 --campaign "${SEALED_CAMPAIGN}" \
    --skip-harness-install --producer-bin "${WORK}/mock-producer" \
    --out "${WORK}/sealed-generated-baseline")"
sealed_challenger="$(MOCK_PRODUCER_SESSION=sealed-challenger-001 MOCK_PRODUCER_COST=1.2 \
  MOCK_PRODUCER_SLEEP=2 \
  MOCK_PRODUCER_STYLE='CRAFTED:' bash "${PAIRWISE}" generate \
    --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
    --harness-role challenger --harness "${CHALLENGER_HARNESS}" \
    --campaign-run custom-v2-config-balanced-01 --campaign "${SEALED_CAMPAIGN}" \
    --skip-harness-install --producer-bin "${WORK}/mock-producer" \
    --out "${WORK}/sealed-generated-challenger")"
sealed_pair_receipt="$("${SCHEMA2_COMPARE[@]}" \
  --campaign-run custom-v2-config-balanced-01 --campaign "${SEALED_CAMPAIGN}" \
  --probe quality-config-diagnostics --baseline "${sealed_baseline}" \
  --challenger "${sealed_challenger}" --out "${WORK}/sealed-pair" \
  --judge-bin "${WORK}/mock-judge")"
sealed_campaign_receipt="${WORK}/sealed-campaign-receipt.json"
bash "${PAIRWISE}" campaign-seal --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" \
  --campaign "${SEALED_CAMPAIGN}" --out "${sealed_campaign_receipt}" >/dev/null
assert_eq "T7h: campaign receipt binds all three first-attempt outputs" "true" \
  "$(jq -r --arg generation_a "$(jq -r '.generation_receipt_hash' "${sealed_baseline}")" \
    --arg generation_b "$(jq -r '.generation_receipt_hash' "${sealed_challenger}")" \
    --arg comparison "$(jq -r '.receipt_hash' "${sealed_pair_receipt}")" '
      (.stages | length) == 3
      and ([.stages[] | .output_hash] | sort) == ([$generation_a,$generation_b,$comparison] | sort)
    ' "${sealed_campaign_receipt}")"

for campaign_extra_scope in root stages run stage; do
  campaign_extra="${WORK}/campaign-extra-${campaign_extra_scope}"
  cp -R "${SEALED_CAMPAIGN}" "${campaign_extra}"
  case "${campaign_extra_scope}" in
    root) printf 'unexpected\n' > "${campaign_extra}/unexpected-root" ;;
    stages) mkdir "${campaign_extra}/stages/unsealed-run" ;;
    run) mkdir "${campaign_extra}/stages/custom-v2-config-balanced-01/unsealed-stage" ;;
    stage) printf 'unexpected\n' \
      > "${campaign_extra}/stages/custom-v2-config-balanced-01/baseline/unexpected-node" ;;
  esac
  rc=0; campaign_extra_out="$(bash "${PAIRWISE}" campaign-seal \
    --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" \
    --campaign "${campaign_extra}" \
    --out "${WORK}/campaign-extra-${campaign_extra_scope}-receipt.json" 2>&1)" || rc=$?
  assert_eq "T7h: campaign ${campaign_extra_scope} extra node exits 2" "2" "${rc}"
  assert_contains "T7h: campaign ${campaign_extra_scope} inventory fails closed" \
    "unexpected, pre-created, or unsafe stage nodes" "${campaign_extra_out}"
done

# Mutate a copied campaign's live baseline claim before the bounded copy
# command returns. The source seal is authoritative across that whole copy, so
# campaign-seal must fail closed rather than bless either generation.
CAMPAIGN_SEAL_SNAPSHOT="${WORK}/campaign-seal-stage-snapshot"
cp -R "${SEALED_CAMPAIGN}" "${CAMPAIGN_SEAL_SNAPSHOT}"
campaign_seal_live_claim="${CAMPAIGN_SEAL_SNAPSHOT}/stages/custom-v2-config-balanced-01/baseline/claim.json"
campaign_seal_original_claim="${SEALED_CAMPAIGN}/stages/custom-v2-config-balanced-01/baseline/claim.json"
campaign_seal_original_output="$(jq -r '.output_hash' \
  "${campaign_seal_live_claim}")"
mkdir -p "${WORK}/campaign-seal-copy-bin"
PAIRWISE_SEAL_REAL_CP="$(command -v cp)"
PAIRWISE_SEAL_REAL_JQ="$(command -v jq)"
PAIRWISE_SEAL_REAL_SHASUM="$(command -v shasum)"
cat > "${WORK}/campaign-seal-copy-bin/cp" <<'CAMPAIGN_SEAL_COPY'
#!/usr/bin/env bash
set -euo pipefail

"${PAIRWISE_SEAL_REAL_CP}" "$@"
previous=""
source_arg=""
for arg in "$@"; do
  source_arg="${previous}"
  previous="${arg}"
done
target_arg="${previous}"
if [[ "${source_arg}" == "${PAIRWISE_CAMPAIGN_SEAL_MUTATION_SOURCE}" \
    && "${target_arg}" != "${source_arg}" \
    && -f "${target_arg}" && ! -L "${target_arg}" \
    && ! -e "${PAIRWISE_CAMPAIGN_SEAL_MUTATION_MARKER}" ]]; then
  mutation_tmp="${source_arg}.mutation.$$"
  mutation_sealed="${source_arg}.mutation-sealed.$$"
  "${PAIRWISE_SEAL_REAL_JQ}" \
    '.output_hash = ("0" * 64) | .receipt_hash = ""' \
    "${source_arg}" > "${mutation_tmp}"
  mutation_hash="$("${PAIRWISE_SEAL_REAL_JQ}" -cS \
    'del(.receipt_hash)' "${mutation_tmp}" \
    | "${PAIRWISE_SEAL_REAL_SHASUM}" -a 256 | awk '{print $1}')"
  "${PAIRWISE_SEAL_REAL_JQ}" --arg hash "${mutation_hash}" \
    '.receipt_hash = $hash' "${mutation_tmp}" > "${mutation_sealed}"
  mv "${mutation_sealed}" "${source_arg}"
  rm -f "${mutation_tmp}"
  : > "${PAIRWISE_CAMPAIGN_SEAL_MUTATION_MARKER}"
fi
CAMPAIGN_SEAL_COPY
chmod +x "${WORK}/campaign-seal-copy-bin/cp"
rc=0; campaign_seal_snapshot_out="$(PATH="${WORK}/campaign-seal-copy-bin:${PATH}" \
  PAIRWISE_SEAL_REAL_CP="${PAIRWISE_SEAL_REAL_CP}" \
  PAIRWISE_SEAL_REAL_JQ="${PAIRWISE_SEAL_REAL_JQ}" \
  PAIRWISE_SEAL_REAL_SHASUM="${PAIRWISE_SEAL_REAL_SHASUM}" \
  PAIRWISE_CAMPAIGN_SEAL_MUTATION_SOURCE="${campaign_seal_live_claim}" \
  PAIRWISE_CAMPAIGN_SEAL_MUTATION_MARKER="${WORK}/campaign-seal-copy-fired" \
  bash "${PAIRWISE}" campaign-seal \
    --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" \
    --campaign "${CAMPAIGN_SEAL_SNAPSHOT}" \
    --out "${WORK}/campaign-seal-stage-snapshot-receipt.json" 2>&1)" || rc=$?
assert_eq "T7h: campaign seal rejects a source replacement before copy returns" "2" "${rc}"
assert_eq "T7h: campaign seal stage-claim snapshot shim was exercised" "true" \
  "$([[ -f "${WORK}/campaign-seal-copy-fired" ]] && printf true || printf false)"
assert_contains "T7h: unstable campaign claim failure is explicit" \
  "campaign stage is oversized, unstable, or unreadable" \
  "${campaign_seal_snapshot_out}"
assert_eq "T7h: unstable campaign claim publishes no accepted receipt" "false" \
  "$([[ -e "${WORK}/campaign-seal-stage-snapshot-receipt.json" \
      || -L "${WORK}/campaign-seal-stage-snapshot-receipt.json" ]] \
    && printf true || printf false)"
assert_eq "T7h: copied campaign live claim moved to a different valid generation" \
  "true" "$(bash -c '
    source "$1"
    campaign_stage_receipt_is_valid "$2"
    [[ "$(jq -r ".output_hash" "$2")" == "$(printf "0%.0s" {1..64})" ]]
  ' pairwise-campaign-seal-live-valid "${PAIRWISE_LIBRARY}" \
    "${campaign_seal_live_claim}" && printf true || printf false)"
assert_eq "T7h: canonical campaign stage claim remains unchanged" \
  "${campaign_seal_original_output}" \
  "$(jq -r '.output_hash' "${campaign_seal_original_claim}")"

# Change a live claim only after campaign_stage_output_matches has frozen and
# sealed its private snapshot. The final live-generation re-attestation must
# reject the stale lookup even though the captured claim itself was valid.
LATE_STAGE_MATCH_CAMPAIGN="${WORK}/late-stage-match-campaign"
cp -R "${SEALED_CAMPAIGN}" "${LATE_STAGE_MATCH_CAMPAIGN}"
late_stage_match_claim="${LATE_STAGE_MATCH_CAMPAIGN}/stages/custom-v2-config-balanced-01/baseline/claim.json"
late_stage_match_policy="$(jq -r '.policy_hash' \
  "${LATE_STAGE_MATCH_CAMPAIGN}/campaign.json")"
late_stage_match_output="$(jq -r '.output_hash' \
  "${late_stage_match_claim}")"
late_stage_match_result="$(bash -c '
  source "$1"
  claim="$2"
  campaign="$3"
  policy_hash="$4"
  output_hash="$5"
  mutated=0
  eval "$(declare -f campaign_stage_receipt_is_valid \
    | sed "1s/campaign_stage_receipt_is_valid/original_campaign_stage_receipt_is_valid/")"
  mutate_live_claim() {
    local tmp sealed hash replacement
    replacement="$(printf "1%.0s" {1..64})"
    tmp="$(mktemp -t omc-late-stage-match-XXXXXX)" || return 1
    sealed="$(mktemp -t omc-late-stage-match-sealed-XXXXXX)" \
      || { rm -f "${tmp}"; return 1; }
    jq --arg replacement "${replacement}" \
      ".output_hash=\$replacement | .receipt_hash=\"\"" \
      "${claim}" >"${tmp}" || return 1
    hash="$(json_hash_without_field "${tmp}" receipt_hash)" || return 1
    jq --arg hash "${hash}" ".receipt_hash=\$hash" \
      "${tmp}" >"${sealed}" || return 1
    mv -f "${sealed}" "${claim}" || return 1
    rm -f "${tmp}"
  }
  campaign_stage_receipt_is_valid() {
    local validator_rc=0
    original_campaign_stage_receipt_is_valid "$@" || validator_rc=$?
    if [[ "${validator_rc}" -eq 0 && "${mutated}" -eq 0 ]]; then
      mutate_live_claim || return 1
      mutated=1
    fi
    return "${validator_rc}"
  }
  matched=false
  if campaign_stage_output_matches "${campaign}" "${policy_hash}" \
      custom-v2-config-balanced-01 baseline "${output_hash}"; then
    matched=true
  fi
  jq -nc --argjson matched "${matched}" --argjson mutated "${mutated}" \
    --argjson live_valid "$(campaign_stage_receipt_is_valid "${claim}" \
      >/dev/null 2>&1 && printf true || printf false)" \
    "{matched:\$matched,mutated:(\$mutated == 1),live_valid:\$live_valid}"
' pairwise-late-stage-match "${PAIRWISE_LIBRARY}" \
  "${late_stage_match_claim}" "${LATE_STAGE_MATCH_CAMPAIGN}" \
  "${late_stage_match_policy}" "${late_stage_match_output}")"
assert_eq "T7h: late live-claim mutation invalidates stage lookup" "true" \
  "$(jq -r '(.matched == false) and .mutated and .live_valid' \
    <<<"${late_stage_match_result}" 2>/dev/null || printf false)"

# Mutate a claim after campaign-seal's first complete claim-portfolio check.
# The post-publication portfolio check must fail the command rather than
# returning a success path for a receipt whose live authority changed.
LATE_CAMPAIGN_SEAL="${WORK}/late-campaign-seal"
cp -R "${SEALED_CAMPAIGN}" "${LATE_CAMPAIGN_SEAL}"
late_campaign_seal_claim="${LATE_CAMPAIGN_SEAL}/stages/custom-v2-config-balanced-01/baseline/claim.json"
late_campaign_seal_marker="${WORK}/late-campaign-seal-mutated"
late_campaign_seal_receipt="${WORK}/late-campaign-seal-receipt.json"
late_campaign_seal_rc=0
late_campaign_seal_out="$(bash -c '
  source "$1"
  trap cleanup_active_command_snapshots EXIT
  claim="$2"
  marker="$3"
  calls=0
  eval "$(declare -f campaign_claim_seals_match \
    | sed "1s/campaign_claim_seals_match/original_campaign_claim_seals_match/")"
  mutate_live_claim() {
    local tmp sealed hash replacement
    replacement="$(printf "2%.0s" {1..64})"
    tmp="$(mktemp -t omc-late-campaign-seal-XXXXXX)" || return 1
    sealed="$(mktemp -t omc-late-campaign-seal-done-XXXXXX)" \
      || { rm -f "${tmp}"; return 1; }
    jq --arg replacement "${replacement}" \
      ".output_hash=\$replacement | .receipt_hash=\"\"" \
      "${claim}" >"${tmp}" || return 1
    hash="$(json_hash_without_field "${tmp}" receipt_hash)" || return 1
    jq --arg hash "${hash}" ".receipt_hash=\$hash" \
      "${tmp}" >"${sealed}" || return 1
    mv -f "${sealed}" "${claim}" || return 1
    rm -f "${tmp}"
    : >"${marker}"
  }
  campaign_claim_seals_match() {
    local match_rc=0
    original_campaign_claim_seals_match "$@" || match_rc=$?
    calls=$((calls + 1))
    if [[ "${match_rc}" -eq 0 && "${calls}" -eq 1 ]]; then
      mutate_live_claim || return 1
    fi
    return "${match_rc}"
  }
  cmd_campaign_seal --identity-manifest "$4" --campaign "$5" --out "$6"
' pairwise-late-campaign-seal "${PAIRWISE_LIBRARY}" \
  "${late_campaign_seal_claim}" "${late_campaign_seal_marker}" \
  "${SCHEMA2_IDENTITY_MANIFEST}" "${LATE_CAMPAIGN_SEAL}" \
  "${late_campaign_seal_receipt}" 2>&1)" || late_campaign_seal_rc=$?
assert_eq "T7h: late campaign-claim mutation fails sealing" "2" \
  "${late_campaign_seal_rc}"
assert_eq "T7h: late campaign-claim mutation seam was exercised" "true" \
  "$([[ -f "${late_campaign_seal_marker}" ]] && printf true || printf false)"
assert_contains "T7h: late campaign mutation is rejected explicitly" \
  "published campaign receipt is invalid" "${late_campaign_seal_out}"
rc=0; retry_out="$(MOCK_PRODUCER_SESSION=sealed-baseline-retry bash "${PAIRWISE}" generate \
  --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
  --harness-role baseline --harness "${BASELINE_HARNESS}" \
  --campaign-run custom-v2-config-balanced-01 --campaign "${SEALED_CAMPAIGN}" \
  --skip-harness-install --producer-bin "${WORK}/mock-producer" \
  --out "${WORK}/sealed-generated-baseline-retry" 2>&1)" || rc=$?
assert_eq "T7h: second producer attempt exits 2" "2" "${rc}"
assert_contains "T7h: second producer attempt is explicitly noncanonical" \
  "first-attempt slot already exists" "${retry_out}"
rc=0; sealed_claim="$(bash "${PAIRWISE}" claim-check "${sealed_pair_receipt}" \
  --campaign-receipt "${sealed_campaign_receipt}" --allow-custom-portfolio \
  --min-pairs 1 --min-domains 1 --min-tiers 1 --min-axis-pairs 1 \
  --max-challenger-scope-creep 0 --min-win-rate 0.5 --max-loss-rate 0 \
  --min-positive-axes 5 --min-visionary-margin 0.5 --max-sign-p-value 1 \
  --max-median-cost-ratio 2 --max-median-wall-ratio 2 \
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2 2>&1)" || rc=$?
assert_eq "T7h: development claim accepts a valid sealed campaign receipt" "0" "${rc}"
assert_eq "T7h: claim exposes the exact campaign receipt hash" \
  "$(jq -r '.campaign_receipt_hash' "${sealed_campaign_receipt}")" \
  "$(jq -r '.observed.campaign_receipt_hash' <<<"${sealed_claim}")"

DEV_CLAIM_THRESHOLDS=(
  --allow-custom-portfolio
  --min-pairs 1 --min-domains 1 --min-tiers 1 --min-axis-pairs 1
  --max-challenger-scope-creep 0 --min-win-rate 0.5 --max-loss-rate 0
  --min-positive-axes 5 --min-visionary-margin 0.5 --max-sign-p-value 1
  --max-median-cost-ratio 2 --max-median-wall-ratio 2
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2
)

# The bounded cp receives a whole-KiB ulimit, so a source can grow past a
# non-KiB policy cap while remaining below that rounded kernel boundary. Keep
# the sealed fixture immutable, grow only its private destination via a local
# cp shim, and require the authoritative post-copy byte check to reject it.
campaign_growth_source="${WORK}/campaign-receipt-copy-growth-source.json"
cp "${sealed_campaign_receipt}" "${campaign_growth_source}"
campaign_growth_source_hash="$(shasum -a 256 "${campaign_growth_source}" \
  | awk '{print $1}')"
campaign_growth_source_size="$(wc -c < "${campaign_growth_source}" \
  | awk '{print $1}')"
pair_receipt_size="$(wc -c < "${sealed_pair_receipt}" | awk '{print $1}')"
campaign_growth_largest_size="${campaign_growth_source_size}"
if [[ "${pair_receipt_size}" -gt "${campaign_growth_largest_size}" ]]; then
  campaign_growth_largest_size="${pair_receipt_size}"
fi
campaign_growth_ceil_blocks=$(((campaign_growth_largest_size + 1023) / 1024))
campaign_growth_cap=$(((campaign_growth_ceil_blocks + 1) * 1024 - 512))
assert_eq "T7h: campaign receipt growth cap is non-KiB and above all inputs" \
  "true" "$([[ $((campaign_growth_cap % 1024)) -ne 0 \
      && "${campaign_growth_cap}" -gt "${campaign_growth_largest_size}" ]] \
    && printf true || printf false)"
mkdir -p "${WORK}/campaign-copy-growth-bin"
PAIRWISE_REAL_CP="$(command -v cp)"
cat > "${WORK}/campaign-copy-growth-bin/cp" <<'CAMPAIGN_COPY_GROWTH'
#!/usr/bin/env bash
set -euo pipefail

"${PAIRWISE_REAL_CP}" "$@"
previous=""
source_arg=""
for arg in "$@"; do
  source_arg="${previous}"
  previous="${arg}"
done
target_arg="${previous}"
if [[ "${source_arg}" == "${PAIRWISE_CAMPAIGN_COPY_GROWTH_SOURCE}" \
    && "${target_arg}" != "${source_arg}" \
    && -f "${target_arg}" && ! -L "${target_arg}" ]]; then
  copied_size="$(wc -c < "${target_arg}" | awk '{print $1}')"
  growth=$((PAIRWISE_CAMPAIGN_COPY_GROWTH_CAP + 1 - copied_size))
  if [[ "${growth}" -gt 0 ]]; then
    printf '%*s' "${growth}" '' >> "${target_arg}"
  fi
  : > "${PAIRWISE_CAMPAIGN_COPY_GROWTH_MARKER}"
fi
CAMPAIGN_COPY_GROWTH
chmod +x "${WORK}/campaign-copy-growth-bin/cp"
rc=0; campaign_copy_growth_out="$(PATH="${WORK}/campaign-copy-growth-bin:${PATH}" \
  PAIRWISE_REAL_CP="${PAIRWISE_REAL_CP}" \
  PAIRWISE_CAMPAIGN_COPY_GROWTH_SOURCE="${campaign_growth_source}" \
  PAIRWISE_CAMPAIGN_COPY_GROWTH_CAP="${campaign_growth_cap}" \
  PAIRWISE_CAMPAIGN_COPY_GROWTH_MARKER="${WORK}/campaign-copy-growth-fired" \
  OMC_PAIRWISE_MAX_RECEIPT_BYTES="${campaign_growth_cap}" \
  bash "${PAIRWISE}" claim-check "${sealed_pair_receipt}" \
    --campaign-receipt "${campaign_growth_source}" \
    "${DEV_CLAIM_THRESHOLDS[@]}" 2>&1)" || rc=$?
assert_eq "T7h: non-KiB campaign receipt copy growth exits 2" "2" "${rc}"
assert_contains "T7h: post-copy campaign receipt byte cap is authoritative" \
  "campaign receipt changed, blocked, or exceeded copy limits" \
  "${campaign_copy_growth_out}"
assert_eq "T7h: campaign receipt copy-growth shim exercised the private snapshot" \
  "true" "$([[ -f "${WORK}/campaign-copy-growth-fired" ]] \
    && printf true || printf false)"
assert_eq "T7h: campaign receipt copy-growth fixture remains unchanged" \
  "${campaign_growth_source_hash}" \
  "$(shasum -a 256 "${campaign_growth_source}" | awk '{print $1}')"
assert_eq "T7h: canonical sealed campaign receipt remains unchanged" "true" \
  "$(cmp -s "${sealed_campaign_receipt}" "${campaign_growth_source}" \
    && printf true || printf false)"

printf '{}\n' > "${WORK}/malformed-campaign-receipt.json"
rc=0; malformed_campaign_claim="$(bash "${PAIRWISE}" claim-check \
  "${sealed_pair_receipt}" --campaign-receipt "${WORK}/malformed-campaign-receipt.json" \
  "${DEV_CLAIM_THRESHOLDS[@]}" 2>&1)" || rc=$?
assert_eq "T7h: explicit malformed custom campaign receipt exits 2" "2" "${rc}"
assert_contains "T7h: malformed campaign receipt is not silently ignored" \
  "explicit campaign receipt is malformed" "${malformed_campaign_claim}"

jq '(.stages[] | select(.stage == "compare")) |=
    (.output_hash = ("0" * 64) | .receipt_hash = "")' \
  "${sealed_campaign_receipt}" > "${WORK}/unrelated-campaign-receipt.stage-1.json"
jq -cS '.stages[] | select(.stage == "compare") | del(.receipt_hash)' \
  "${WORK}/unrelated-campaign-receipt.stage-1.json" \
  | shasum -a 256 | awk '{print $1}' > "${WORK}/unrelated-stage-hash"
unrelated_stage_hash="$(cat "${WORK}/unrelated-stage-hash")"
jq --arg hash "${unrelated_stage_hash}" \
  '(.stages[] | select(.stage == "compare")).receipt_hash = $hash
   | .campaign_receipt_hash = ""' \
  "${WORK}/unrelated-campaign-receipt.stage-1.json" \
  > "${WORK}/unrelated-campaign-receipt.stage-2.json"
unrelated_campaign_hash="$(jq -cS 'del(.campaign_receipt_hash)' \
  "${WORK}/unrelated-campaign-receipt.stage-2.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${unrelated_campaign_hash}" '.campaign_receipt_hash = $hash' \
  "${WORK}/unrelated-campaign-receipt.stage-2.json" \
  > "${WORK}/unrelated-campaign-receipt.json"
assert_eq "T7h: unrelated campaign fixture remains structurally sealed" "true" \
  "$(bash -c 'source "$1"; campaign_receipt_is_valid "$2" && printf true || printf false' \
    pairwise-campaign-validity "${PAIRWISE_LIBRARY}" \
    "${WORK}/unrelated-campaign-receipt.json")"
rc=0; unrelated_campaign_claim="$(bash "${PAIRWISE}" claim-check \
  "${sealed_pair_receipt}" --campaign-receipt "${WORK}/unrelated-campaign-receipt.json" \
  "${DEV_CLAIM_THRESHOLDS[@]}" 2>&1)" || rc=$?
assert_eq "T7h: unrelated sealed custom campaign receipt exits 2" "2" "${rc}"
assert_contains "T7h: custom campaign receipt must bind exact supplied outputs" \
  "does not bind the supplied pair receipts and exact stage outputs" \
  "${unrelated_campaign_claim}"

SNAPSHOT_CAMPAIGN="${WORK}/snapshot-campaign"
cp -R "${SEALED_CAMPAIGN}" "${SNAPSHOT_CAMPAIGN}"
rm -rf "${SNAPSHOT_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
rc=0; snapshot_campaign_out="$(bash -c '
  source "$1"
  trap cleanup_active_command_snapshots EXIT
  campaign_dir="$2"
  freeze_campaign_input "${campaign_dir}" || exit 90
  printf "\n" >> "${campaign_dir}/campaign.json"
  campaign_stage_begin "${campaign_dir}" "${ACTIVE_CAMPAIGN_SNAPSHOT}" \
    custom-v2-config-balanced-01 compare
' pairwise-campaign-snapshot "${PAIRWISE_LIBRARY}" \
  "${SNAPSHOT_CAMPAIGN}" 2>&1)" || rc=$?
assert_eq "T7h: campaign mutation after the command snapshot exits 2" "2" "${rc}"
assert_contains "T7h: campaign mutation is rejected before stage admission" \
  "campaign policy changed after its command snapshot" "${snapshot_campaign_out}"
assert_eq "T7h: changed campaign policy cannot burn the compare slot" "false" \
  "$([[ -d "${SNAPSHOT_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare" ]] \
    && printf true || printf false)"

BOUNDED_CAMPAIGN="${WORK}/bounded-campaign-snapshot"
cp -R "${SEALED_CAMPAIGN}" "${BOUNDED_CAMPAIGN}"
rm -rf "${BOUNDED_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
bounded_campaign_started_at="$(date +%s)"
rc=0; bounded_campaign_out="$( \
  OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS=1 \
  OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=1 \
  bash -c '
    source "$1"
    trap cleanup_active_command_snapshots EXIT
    campaign_dir="$2"
    live_campaign="${campaign_dir}/campaign.json"
    freeze_campaign_input "${campaign_dir}" || exit 91
    regular_file_size() {
      local file="$1" size=""
      size="$(stat -f "%z" "${file}" 2>/dev/null || true)"
      if ! is_uint "${size}"; then
        size="$(stat -c "%s" "${file}" 2>/dev/null || true)"
      fi
      is_uint "${size}" || return 1
      if [[ "${file}" == "${live_campaign}" && -f "${file}" ]]; then
        rm -f "${file}"
        mkfifo "${file}"
      fi
      printf "%s\n" "${size}"
    }
    campaign_stage_begin "${campaign_dir}" "${ACTIVE_CAMPAIGN_SNAPSHOT}" \
      custom-v2-config-balanced-01 compare
  ' pairwise-bounded-campaign "${PAIRWISE_LIBRARY}" \
    "${BOUNDED_CAMPAIGN}" 2>&1
)" || rc=$?
bounded_campaign_elapsed=$(( $(date +%s) - bounded_campaign_started_at ))
assert_eq "T7h: campaign regular-file-to-FIFO admission swap exits 2" "2" "${rc}"
assert_contains "T7h: bounded live-campaign snapshot failure is explicit" \
  "campaign policy changed, blocked, or became unsafe" "${bounded_campaign_out}"
assert_eq "T7h: campaign FIFO swap cannot hang first-attempt admission" "true" \
  "$([[ "${bounded_campaign_elapsed}" -le 8 ]] && printf true || printf false)"
assert_eq "T7h: unsafe live campaign cannot burn the compare slot" "false" \
  "$([[ -d "${BOUNDED_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare" ]] \
    && printf true || printf false)"

# Cross the exact post-snapshot boundary: campaign_stage_begin has already
# copied and compared the live campaign, then the first hash open swaps that
# regular file to a FIFO. The live seal must time out before mkdir consumes the
# first-attempt slot.
POST_SNAPSHOT_SEAL_CAMPAIGN="${WORK}/post-snapshot-seal-campaign"
cp -R "${SEALED_CAMPAIGN}" "${POST_SNAPSHOT_SEAL_CAMPAIGN}"
rm -rf "${POST_SNAPSHOT_SEAL_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
post_snapshot_seal_started_at="$(date +%s)"
rc=0; post_snapshot_seal_out="$( \
  OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS=1 \
  OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=1 \
  bash -c '
    source "$1"
    trap cleanup_active_command_snapshots EXIT
    campaign_dir="$2"
    live_campaign="${campaign_dir}/campaign.json"
    freeze_campaign_input "${campaign_dir}" || exit 92
    eval "$(declare -f regular_file_seal_json_bounded \
      | sed "1s/regular_file_seal_json_bounded/real_regular_file_seal_json_bounded/")"
    shasum() {
      local target="${!#}"
      if [[ "${OMC_TEST_POST_SNAPSHOT_CAMPAIGN_SEAL:-0}" == "1" \
          && "${target}" == "${live_campaign}" && -f "${target}" ]]; then
        rm -f "${target}"
        mkfifo "${target}"
      fi
      command shasum "$@"
    }
    regular_file_seal_json_bounded() {
      OMC_TEST_POST_SNAPSHOT_CAMPAIGN_SEAL=1 \
        real_regular_file_seal_json_bounded "$@"
    }
    campaign_stage_begin "${campaign_dir}" "${ACTIVE_CAMPAIGN_SNAPSHOT}" \
      custom-v2-config-balanced-01 compare
  ' pairwise-post-snapshot-campaign-seal "${PAIRWISE_LIBRARY}" \
    "${POST_SNAPSHOT_SEAL_CAMPAIGN}" 2>&1
)" || rc=$?
post_snapshot_seal_elapsed=$(( $(date +%s) - post_snapshot_seal_started_at ))
assert_eq "T7h: post-snapshot live campaign seal swap exits 2" "2" "${rc}"
assert_contains "T7h: post-snapshot bounded seal failure is explicit" \
  "could not seal live campaign policy identity" "${post_snapshot_seal_out}"
assert_eq "T7h: post-snapshot campaign seal swap cannot hang" "true" \
  "$([[ "${post_snapshot_seal_elapsed}" -le 8 ]] && printf true || printf false)"
assert_eq "T7h: post-snapshot seal failure cannot burn the compare slot" "false" \
  "$([[ -d "${POST_SNAPSHOT_SEAL_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare" ]] \
    && printf true || printf false)"

CLAIM_SEAL_CAMPAIGN="${WORK}/bounded-active-claim-seal-campaign"
cp -R "${SEALED_CAMPAIGN}" "${CLAIM_SEAL_CAMPAIGN}"
rm -rf "${CLAIM_SEAL_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
claim_seal_started_at="$(date +%s)"
rc=0; claim_seal_out="$( \
  OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS=1 \
  OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=1 \
  bash -c '
    source "$1"
    trap cleanup_all_on_exit EXIT
    campaign_dir="$2"
    freeze_campaign_input "${campaign_dir}" || exit 93
    campaign_stage_begin "${campaign_dir}" "${ACTIVE_CAMPAIGN_SNAPSHOT}" \
      custom-v2-config-balanced-01 compare
    TEST_ACTIVE_CLAIM_SEAL_PATH="${ACTIVE_CAMPAIGN_STAGE_DIR}/claim.json"
    eval "$(declare -f regular_file_seal_json_bounded \
      | sed "1s/regular_file_seal_json_bounded/real_regular_file_seal_json_bounded/")"
    shasum() {
      local target="${!#}"
      if [[ "${OMC_TEST_ACTIVE_CLAIM_SEAL:-0}" == "1" \
          && "${target}" == "${TEST_ACTIVE_CLAIM_SEAL_PATH}" \
          && -f "${target}" ]]; then
        rm -f "${target}"
        mkfifo "${target}"
      fi
      command shasum "$@"
    }
    regular_file_seal_json_bounded() {
      if [[ "$1" == "${TEST_ACTIVE_CLAIM_SEAL_PATH}" ]]; then
        OMC_TEST_ACTIVE_CLAIM_SEAL=1 \
          real_regular_file_seal_json_bounded "$@"
      else
        real_regular_file_seal_json_bounded "$@"
      fi
    }
    campaign_stage_complete \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  ' pairwise-active-claim-seal "${PAIRWISE_LIBRARY}" \
    "${CLAIM_SEAL_CAMPAIGN}" 2>&1
)" || rc=$?
claim_seal_elapsed=$(( $(date +%s) - claim_seal_started_at ))
assert_eq "T7h: active claim post-snapshot seal swap exits 2" "2" "${rc}"
assert_contains "T7h: active claim bounded seal failure is explicit" \
  "could not seal the active campaign claim identity" "${claim_seal_out}"
assert_eq "T7h: active claim seal swap cannot hang" "true" \
  "$([[ "${claim_seal_elapsed}" -le 8 ]] && printf true || printf false)"
assert_eq "T7h: unsafe active claim is never promoted to success" "true" \
  "$([[ -p "${CLAIM_SEAL_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json" ]] \
    && printf true || printf false)"

CLAIM_REPLACE_CAMPAIGN="${WORK}/bounded-active-claim-replace-campaign"
cp -R "${SEALED_CAMPAIGN}" "${CLAIM_REPLACE_CAMPAIGN}"
rm -rf "${CLAIM_REPLACE_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
claim_replace_started_at="$(date +%s)"
rc=0; claim_replace_out="$( \
  OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS=1 \
  OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=1 \
  bash -c '
    source "$1"
    trap cleanup_all_on_exit EXIT
    campaign_dir="$2"
    freeze_campaign_input "${campaign_dir}" || exit 94
    campaign_stage_begin "${campaign_dir}" "${ACTIVE_CAMPAIGN_SNAPSHOT}" \
      custom-v2-config-balanced-01 compare
    TEST_ACTIVE_CLAIM_REPLACE_PATH="${ACTIVE_CAMPAIGN_STAGE_DIR}/claim.json"
    eval "$(declare -f replace_regular_file_no_follow_bounded \
      | sed "1s/replace_regular_file_no_follow_bounded/real_replace_regular_file_no_follow_bounded/")"
    shasum() {
      local target="${!#}"
      if [[ "${OMC_TEST_ACTIVE_CLAIM_REPLACE:-0}" == "1" \
          && "${target}" == "${TEST_ACTIVE_CLAIM_REPLACE_PATH}" \
          && -f "${target}" ]]; then
        rm -f "${target}"
        mkfifo "${target}"
      fi
      command shasum "$@"
    }
    replace_regular_file_no_follow_bounded() {
      OMC_TEST_ACTIVE_CLAIM_REPLACE=1 \
        real_replace_regular_file_no_follow_bounded "$@"
    }
    campaign_stage_complete \
      bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ' pairwise-active-claim-replace "${PAIRWISE_LIBRARY}" \
    "${CLAIM_REPLACE_CAMPAIGN}" 2>&1
)" || rc=$?
claim_replace_elapsed=$(( $(date +%s) - claim_replace_started_at ))
assert_eq "T7h: active claim replacement-open swap exits 2" "2" "${rc}"
assert_contains "T7h: bounded claim replacement failure is explicit" \
  "could not publish campaign success safely" "${claim_replace_out}"
assert_eq "T7h: active claim replacement swap cannot hang" "true" \
  "$([[ "${claim_replace_elapsed}" -le 8 ]] && printf true || printf false)"
assert_eq "T7h: replacement race cannot forge a successful claim" "true" \
  "$([[ -p "${CLAIM_REPLACE_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json" ]] \
    && printf true || printf false)"

# Historical validate-then-replace shims below targeted the former fixed-name
# cp/mv publication implementation. Keep them as readable regression context,
# but the active contract now publishes a validated private candidate via
# no-clobber hard-link creation and is exercised by the deterministic actor
# pre-creation mutants immediately after this block.
if false; then
VALIDATION_CAMPAIGN="${WORK}/receipt-validation-campaign"
cp -R "${SEALED_CAMPAIGN}" "${VALIDATION_CAMPAIGN}"
rm -rf "${VALIDATION_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
mkdir -p "${WORK}/receipt-validation-jq-bin"
PAIRWISE_REAL_JQ="$(command -v jq)"
cat > "${WORK}/receipt-validation-jq-bin/jq" <<'JQ_RECEIPT_VALIDATION'
#!/usr/bin/env bash
set -euo pipefail
target_seen=false
validation_call=false
fault_target=""
for arg in "$@"; do
  [[ "${arg}" == "-e" ]] && validation_call=true
  if [[ "${arg}" == "${PAIRWISE_RECEIPT_FAULT_TARGET}" \
      || "${arg}" == "${PAIRWISE_RECEIPT_FAULT_TARGET%/*}"/.pairwise-publish-* ]]; then
    target_seen=true
    fault_target="${arg}"
  fi
done
if [[ "${target_seen}" == "true" && "${validation_call}" == "true" \
    && ! -e "${PAIRWISE_RECEIPT_FAULT_MARKER}" ]]; then
  "${PAIRWISE_REAL_JQ}" '.winner = "invalid-injected-winner"' \
    "${fault_target}" > "${fault_target}.fault"
  mv "${fault_target}.fault" "${fault_target}"
  : > "${PAIRWISE_RECEIPT_FAULT_MARKER}"
fi
exec "${PAIRWISE_REAL_JQ}" "$@"
JQ_RECEIPT_VALIDATION
chmod +x "${WORK}/receipt-validation-jq-bin/jq"
export PAIRWISE_REAL_JQ
export PAIRWISE_RECEIPT_FAULT_TARGET="${WORK}/invalid-final-pair/receipt.json"
export PAIRWISE_RECEIPT_FAULT_MARKER="${WORK}/receipt-validation-fired"
rc=0; invalid_final_receipt_out="$(PATH="${WORK}/receipt-validation-jq-bin:${PATH}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${VALIDATION_CAMPAIGN}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${WORK}/invalid-final-pair" --judge-bin "${WORK}/mock-judge" \
  2>&1)" || rc=$?
unset PAIRWISE_REAL_JQ PAIRWISE_RECEIPT_FAULT_TARGET PAIRWISE_RECEIPT_FAULT_MARKER
assert_eq "T7h: internally invalid final pair receipt exits 2" "2" "${rc}"
assert_eq "T7h: final pair receipt validation was exercised" "true" \
  "$([[ -f "${WORK}/receipt-validation-fired" ]] && printf true || printf false)"
assert_contains "T7h: invalid final receipt is rejected before campaign success" \
  "runner produced an invalid or internally inconsistent pair receipt" \
  "${invalid_final_receipt_out}"
assert_eq "T7h: invalid final receipt seals the first compare attempt failed" "failed" \
  "$(jq -r '.status' \
    "${VALIDATION_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json")"

HASH_REUSE_CAMPAIGN="${WORK}/receipt-hash-reuse-campaign"
cp -R "${SEALED_CAMPAIGN}" "${HASH_REUSE_CAMPAIGN}"
rm -rf "${HASH_REUSE_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
mkdir -p "${WORK}/receipt-hash-reuse-jq-bin"
PAIRWISE_REAL_JQ="$(command -v jq)"
cat > "${WORK}/receipt-hash-reuse-jq-bin/jq" <<'JQ_RECEIPT_HASH_REUSE'
#!/usr/bin/env bash
set -euo pipefail
target_seen=false
producer_task_filter=false
receipt_hash_filter=false
for arg in "$@"; do
  if [[ "${arg}" == "${PAIRWISE_HASH_REUSE_TARGET}" \
      || "${arg}" == "${PAIRWISE_HASH_REUSE_TARGET%/*}"/.pairwise-publish-* ]]; then
    target_seen=true
  fi
  [[ "${arg}" == ".provenance.producer_task_hash" ]] && producer_task_filter=true
  [[ "${arg}" == ".receipt_hash" ]] && receipt_hash_filter=true
done
if [[ "${target_seen}" == "true" && "${producer_task_filter}" == "true" ]]; then
  "${PAIRWISE_REAL_JQ}" "$@"
  : > "${PAIRWISE_HASH_REUSE_VALIDATED_MARKER}"
  exit 0
fi
if [[ "${target_seen}" == "true" && "${receipt_hash_filter}" == "true" \
    && -e "${PAIRWISE_HASH_REUSE_VALIDATED_MARKER}" ]]; then
  : > "${PAIRWISE_HASH_REUSE_EXTRA_READ_MARKER}"
  printf '0%.0s' {1..64}
  printf '\n'
  exit 0
fi
exec "${PAIRWISE_REAL_JQ}" "$@"
JQ_RECEIPT_HASH_REUSE
chmod +x "${WORK}/receipt-hash-reuse-jq-bin/jq"
export PAIRWISE_REAL_JQ
export PAIRWISE_HASH_REUSE_TARGET="${WORK}/receipt-hash-reuse-pair/receipt.json"
export PAIRWISE_HASH_REUSE_VALIDATED_MARKER="${WORK}/receipt-hash-validation-complete"
export PAIRWISE_HASH_REUSE_EXTRA_READ_MARKER="${WORK}/receipt-hash-extra-read"
rc=0; hash_reuse_receipt="$(PATH="${WORK}/receipt-hash-reuse-jq-bin:${PATH}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${HASH_REUSE_CAMPAIGN}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${WORK}/receipt-hash-reuse-pair" --judge-bin "${WORK}/mock-judge" \
  2>&1)" || rc=$?
unset PAIRWISE_REAL_JQ PAIRWISE_HASH_REUSE_TARGET \
  PAIRWISE_HASH_REUSE_VALIDATED_MARKER PAIRWISE_HASH_REUSE_EXTRA_READ_MARKER
assert_eq "T7h: exact validated receipt hash is published successfully" "0" "${rc}"
assert_eq "T7h: receipt validator reached its final provenance read" "true" \
  "$([[ -f "${WORK}/receipt-hash-validation-complete" ]] \
    && printf true || printf false)"
assert_eq "T7h: campaign success does not re-read receipt identity after validation" \
  "false" "$([[ -f "${WORK}/receipt-hash-extra-read" ]] \
    && printf true || printf false)"
assert_eq "T7h: campaign success binds the exact validated receipt hash" \
  "$(jq -r '.receipt_hash' "${hash_reuse_receipt}")" \
  "$(jq -r '.output_hash' \
    "${HASH_REUSE_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json")"

PUBLICATION_RACE_CAMPAIGN="${WORK}/receipt-publication-race-campaign"
cp -R "${SEALED_CAMPAIGN}" "${PUBLICATION_RACE_CAMPAIGN}"
rm -rf "${PUBLICATION_RACE_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
mkdir -p "${WORK}/receipt-publication-race-jq-bin"
PAIRWISE_REAL_JQ="$(command -v jq)"
cat > "${WORK}/receipt-publication-race-jq-bin/jq" <<'JQ_RECEIPT_PUBLICATION_RACE'
#!/usr/bin/env bash
set -euo pipefail
target_seen=false
producer_task_filter=false
for arg in "$@"; do
  if [[ "${arg}" == "${PAIRWISE_PUBLICATION_RACE_TARGET}" \
      || "${arg}" == "${PAIRWISE_PUBLICATION_RACE_TARGET%/*}"/.pairwise-publish-* ]]; then
    target_seen=true
  fi
  [[ "${arg}" == ".provenance.producer_task_hash" ]] && producer_task_filter=true
done
if [[ "${target_seen}" == "true" && "${producer_task_filter}" == "true" \
    && ! -e "${PAIRWISE_PUBLICATION_RACE_MARKER}" ]]; then
  "${PAIRWISE_REAL_JQ}" "$@"
  "${PAIRWISE_REAL_JQ}" '.winner = "post-validation-replacement"' \
    "${PAIRWISE_PUBLICATION_RACE_TARGET}" \
    > "${PAIRWISE_PUBLICATION_RACE_TARGET}.replacement"
  mv "${PAIRWISE_PUBLICATION_RACE_TARGET}.replacement" \
    "${PAIRWISE_PUBLICATION_RACE_TARGET}"
  : > "${PAIRWISE_PUBLICATION_RACE_MARKER}"
  exit 0
fi
exec "${PAIRWISE_REAL_JQ}" "$@"
JQ_RECEIPT_PUBLICATION_RACE
chmod +x "${WORK}/receipt-publication-race-jq-bin/jq"
export PAIRWISE_REAL_JQ
export PAIRWISE_PUBLICATION_RACE_TARGET="${WORK}/receipt-publication-race-pair/receipt.json"
export PAIRWISE_PUBLICATION_RACE_MARKER="${WORK}/receipt-publication-race-fired"
rc=0; publication_race_out="$(PATH="${WORK}/receipt-publication-race-jq-bin:${PATH}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${PUBLICATION_RACE_CAMPAIGN}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${WORK}/receipt-publication-race-pair" --judge-bin "${WORK}/mock-judge" \
  2>&1)" || rc=$?
unset PAIRWISE_REAL_JQ PAIRWISE_PUBLICATION_RACE_TARGET \
  PAIRWISE_PUBLICATION_RACE_MARKER
assert_eq "T7h: receipt replacement at the validation/publication boundary exits 2" "2" "${rc}"
assert_eq "T7h: validation/publication replacement fixture fired" "true" \
  "$([[ -f "${WORK}/receipt-publication-race-fired" ]] && printf true || printf false)"
assert_contains "T7h: changed receipt is rejected before campaign success" \
  "changed during final validation" "${publication_race_out}"
assert_eq "T7h: changed receipt seals the first compare attempt failed" "failed" \
  "$(jq -r '.status' \
    "${PUBLICATION_RACE_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json")"
assert_eq "T7h: failed publication removes its private validation snapshot" "false" \
  "$(find "${WORK}/receipt-publication-race-pair" -maxdepth 1 -type f \
    -name '.pairwise-publish-*' -print -quit | grep -q . \
    && printf true || printf false)"

FIFO_PUBLICATION_CAMPAIGN="${WORK}/receipt-publication-fifo-campaign"
cp -R "${SEALED_CAMPAIGN}" "${FIFO_PUBLICATION_CAMPAIGN}"
rm -rf "${FIFO_PUBLICATION_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
mkdir -p "${WORK}/receipt-publication-fifo-bin"
PAIRWISE_REAL_CP="$(command -v cp)"
printf '0' > "${WORK}/receipt-publication-fifo-count"
cat > "${WORK}/receipt-publication-fifo-bin/cp" <<'CP_RECEIPT_PUBLICATION_FIFO'
#!/usr/bin/env bash
set -euo pipefail
target_seen=false
for arg in "$@"; do
  [[ "${arg}" == "${PAIRWISE_PUBLICATION_FIFO_TARGET}" ]] && target_seen=true
done
if [[ "${target_seen}" == "true" ]]; then
  count="$(cat "${PAIRWISE_PUBLICATION_FIFO_COUNT}")"
  count=$((count + 1))
  printf '%s' "${count}" > "${PAIRWISE_PUBLICATION_FIFO_COUNT}"
  if [[ "${count}" -eq 2 && ! -e "${PAIRWISE_PUBLICATION_FIFO_MARKER}" ]]; then
    rm -f "${PAIRWISE_PUBLICATION_FIFO_TARGET}"
    mkfifo "${PAIRWISE_PUBLICATION_FIFO_TARGET}"
    date +%s > "${PAIRWISE_PUBLICATION_FIFO_MARKER}"
  fi
fi
exec "${PAIRWISE_REAL_CP}" "$@"
CP_RECEIPT_PUBLICATION_FIFO
chmod +x "${WORK}/receipt-publication-fifo-bin/cp"
export PAIRWISE_REAL_CP
export PAIRWISE_PUBLICATION_FIFO_TARGET="${WORK}/receipt-publication-fifo-pair/receipt.json"
export PAIRWISE_PUBLICATION_FIFO_COUNT="${WORK}/receipt-publication-fifo-count"
export PAIRWISE_PUBLICATION_FIFO_MARKER="${WORK}/receipt-publication-fifo-fired"
rc=0; publication_fifo_out="$(OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS=1 \
  PATH="${WORK}/receipt-publication-fifo-bin:${PATH}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${FIFO_PUBLICATION_CAMPAIGN}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${WORK}/receipt-publication-fifo-pair" --judge-bin "${WORK}/mock-judge" \
  2>&1)" || rc=$?
publication_fifo_elapsed=$(( $(date +%s) \
  - $(cat "${WORK}/receipt-publication-fifo-fired" 2>/dev/null || printf '0') ))
unset PAIRWISE_REAL_CP PAIRWISE_PUBLICATION_FIFO_TARGET \
  PAIRWISE_PUBLICATION_FIFO_COUNT PAIRWISE_PUBLICATION_FIFO_MARKER
assert_eq "T7h: receipt-to-FIFO swap at final publication check exits 2" "2" "${rc}"
assert_eq "T7h: final publication FIFO fixture fired" "true" \
  "$([[ -f "${WORK}/receipt-publication-fifo-fired" ]] && printf true || printf false)"
assert_contains "T7h: bounded live resnapshot rejects the FIFO" \
  "changed, blocked, or became unsafe during final validation" "${publication_fifo_out}"
assert_eq "T7h: final publication FIFO cannot hang comparison" "true" \
  "$([[ "${publication_fifo_elapsed}" -le 8 ]] && printf true || printf false)"
assert_eq "T7h: final publication FIFO seals the compare attempt failed" "failed" \
  "$(jq -r '.status' \
    "${FIFO_PUBLICATION_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json")"
assert_eq "T7h: FIFO failure removes both private publication snapshots" "false" \
  "$(find "${WORK}/receipt-publication-fifo-pair" -maxdepth 1 -type f \
    \( -name '.pairwise-publish-*' -o -name '.pairwise-live-*' \) \
    -print -quit | grep -q . && printf true || printf false)"
rm -f "${WORK}/receipt-publication-fifo-pair/receipt.json"

SYMLINK_PUBLICATION_CAMPAIGN="${WORK}/receipt-publication-symlink-campaign"
cp -R "${SEALED_CAMPAIGN}" "${SYMLINK_PUBLICATION_CAMPAIGN}"
rm -rf "${SYMLINK_PUBLICATION_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare"
mkdir -p "${WORK}/receipt-publication-symlink-bin" \
  "${WORK}/receipt-publication-symlink-target"
PAIRWISE_REAL_MV="$(command -v mv)"
cat > "${WORK}/receipt-publication-symlink-bin/mv" <<'MV_RECEIPT_PUBLICATION_SYMLINK'
#!/usr/bin/env bash
set -euo pipefail
source_seen=false
target_seen=false
for arg in "$@"; do
  [[ "${arg}" == "${PAIRWISE_PUBLICATION_SYMLINK_TARGET%/*}"/.pairwise-publish-* ]] \
    && source_seen=true
  [[ "${arg}" == "${PAIRWISE_PUBLICATION_SYMLINK_TARGET}" ]] && target_seen=true
done
if [[ "${source_seen}" == "true" && "${target_seen}" == "true" \
    && ! -e "${PAIRWISE_PUBLICATION_SYMLINK_MARKER}" ]]; then
  rm -f "${PAIRWISE_PUBLICATION_SYMLINK_TARGET}"
  ln -s "${PAIRWISE_PUBLICATION_SYMLINK_DIRECTORY}" \
    "${PAIRWISE_PUBLICATION_SYMLINK_TARGET}"
  : > "${PAIRWISE_PUBLICATION_SYMLINK_MARKER}"
fi
exec "${PAIRWISE_REAL_MV}" "$@"
MV_RECEIPT_PUBLICATION_SYMLINK
chmod +x "${WORK}/receipt-publication-symlink-bin/mv"
export PAIRWISE_REAL_MV
export PAIRWISE_PUBLICATION_SYMLINK_TARGET="${WORK}/receipt-publication-symlink-pair/receipt.json"
export PAIRWISE_PUBLICATION_SYMLINK_DIRECTORY="${WORK}/receipt-publication-symlink-target"
export PAIRWISE_PUBLICATION_SYMLINK_MARKER="${WORK}/receipt-publication-symlink-fired"
rc=0; symlink_publication_out="$(PATH="${WORK}/receipt-publication-symlink-bin:${PATH}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${SYMLINK_PUBLICATION_CAMPAIGN}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${WORK}/receipt-publication-symlink-pair" --judge-bin "${WORK}/mock-judge" \
  2>&1)" || rc=$?
symlink_publication_receipt="${WORK}/receipt-publication-symlink-pair/receipt.json"
unset PAIRWISE_REAL_MV PAIRWISE_PUBLICATION_SYMLINK_TARGET \
  PAIRWISE_PUBLICATION_SYMLINK_DIRECTORY PAIRWISE_PUBLICATION_SYMLINK_MARKER
assert_eq "T7h: directory-symlink swap at atomic receipt publication succeeds safely" "0" "${rc}"
assert_contains "T7h: safe publication returns the intended receipt path" \
  "${symlink_publication_receipt}" "${symlink_publication_out}"
assert_eq "T7h: directory-symlink publication fixture fired" "true" \
  "$([[ -f "${WORK}/receipt-publication-symlink-fired" ]] && printf true || printf false)"
assert_eq "T7h: validated receipt replaces rather than follows the directory symlink" "true" \
  "$([[ -f "${symlink_publication_receipt}" && ! -L "${symlink_publication_receipt}" ]] \
    && printf true || printf false)"
assert_eq "T7h: no receipt is moved inside the symlink target directory" "false" \
  "$(find "${WORK}/receipt-publication-symlink-target" -mindepth 1 -print -quit \
    | grep -q . && printf true || printf false)"
assert_eq "T7h: no-follow publication still seals the validated receipt hash" \
  "$(jq -r '.receipt_hash' "${symlink_publication_receipt}")" \
  "$(jq -r '.output_hash' \
    "${SYMLINK_PUBLICATION_CAMPAIGN}/stages/custom-v2-config-balanced-01/compare/claim.json")"
fi

printf 'T7i: judge actors cannot pre-create any final receipt node type\n'
for destination_kind in symlink hardlink fifo; do
  receipt_precreate_campaign="${WORK}/receipt-precreate-${destination_kind}-campaign"
  cp -R "${SEALED_CAMPAIGN}" "${receipt_precreate_campaign}"
  rm -rf "${receipt_precreate_campaign}/stages/custom-v2-config-balanced-01/compare"
  receipt_precreate_out_dir="${WORK}/receipt-precreate-${destination_kind}-pair"
  calls_before="$(cat "${MOCK_LOG_DIR}/counter")"
  rc=0; receipt_precreate_out="$(MOCK_MODE="precreate-receipt-${destination_kind}" \
    MOCK_PAIR_OUTPUT="${receipt_precreate_out_dir}" \
    "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
    --campaign "${receipt_precreate_campaign}" --probe quality-config-diagnostics \
    --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
    --out "${receipt_precreate_out_dir}" --judge-bin "${WORK}/mock-judge" \
    2>&1)" || rc=$?
  assert_eq "T7i: judge-precreated ${destination_kind} receipt exits 2" "2" "${rc}"
  assert_eq "T7i: ${destination_kind} precreation stops before reverse judge" \
    "$((calls_before + 1))" "$(cat "${MOCK_LOG_DIR}/counter")"
  assert_contains "T7i: ${destination_kind} precreation fails strict actor validation" \
    "forward judge failed strict validation twice" "${receipt_precreate_out}"
  assert_eq "T7i: ${destination_kind} precreation seals compare attempt failed" "failed" \
    "$(jq -r '.status' \
      "${receipt_precreate_campaign}/stages/custom-v2-config-balanced-01/compare/claim.json")"
done

pair_replace_campaign="${WORK}/pair-replace-campaign"
cp -R "${SEALED_CAMPAIGN}" "${pair_replace_campaign}"
rm -rf "${pair_replace_campaign}/stages/custom-v2-config-balanced-01/compare"
pair_replace_out_dir="${WORK}/pair-replace-output"
rc=0; pair_replace_out="$(MOCK_MODE=replace-pair-manifest \
  MOCK_PAIR_OUTPUT="${pair_replace_out_dir}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${pair_replace_campaign}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${pair_replace_out_dir}" --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7i: judge replacement of pair.json exits 2" "2" "${rc}"
assert_contains "T7i: pair inode/hash replacement fails closed" \
  "forward judge failed strict validation twice" "${pair_replace_out}"

probe_replace_campaign="${WORK}/probe-replace-campaign"
cp -R "${SEALED_CAMPAIGN}" "${probe_replace_campaign}"
rm -rf "${probe_replace_campaign}/stages/custom-v2-config-balanced-01/compare"
probe_replace_out_dir="${WORK}/probe-replace-output"
rc=0; probe_replace_out="$(MOCK_MODE=replace-probe-manifest \
  MOCK_PAIR_OUTPUT="${probe_replace_out_dir}" \
  "${SCHEMA2_COMPARE[@]}" --campaign-run custom-v2-config-balanced-01 \
  --campaign "${probe_replace_campaign}" --probe quality-config-diagnostics \
  --baseline "${sealed_baseline}" --challenger "${sealed_challenger}" \
  --out "${probe_replace_out_dir}" --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7i: judge replacement of probe.json exits 2" "2" "${rc}"
assert_contains "T7i: probe inode/hash replacement fails closed" \
  "forward judge failed strict validation twice" "${probe_replace_out}"

FAILED_CAMPAIGN="${WORK}/failed-campaign"
bash "${PAIRWISE}" campaign-init --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" \
  --baseline-harness "${BASELINE_HARNESS}" --challenger-harness "${CHALLENGER_HARNESS}" \
  --out "${FAILED_CAMPAIGN}" >/dev/null
rc=0; failed_attempt="$(MOCK_PRODUCER_SESSION=sealed-failed-001 \
  MOCK_PRODUCER_MODE=missing-package bash "${PAIRWISE}" generate \
  --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
  --harness-role baseline --harness "${BASELINE_HARNESS}" \
  --campaign-run custom-v2-config-balanced-01 --campaign "${FAILED_CAMPAIGN}" \
  --skip-harness-install --producer-bin "${WORK}/mock-producer" \
  --out "${WORK}/failed-campaign-generation" 2>&1)" || rc=$?
assert_eq "T7h: failed first producer attempt exits 2" "2" "${rc}"
assert_eq "T7h: failed first producer attempt is durably sealed" "failed" \
  "$(jq -r '.status' "${FAILED_CAMPAIGN}/stages/custom-v2-config-balanced-01/baseline/claim.json")"
rc=0; retry_out="$(MOCK_PRODUCER_SESSION=sealed-failed-retry bash "${PAIRWISE}" generate \
  --identity-manifest "${SCHEMA2_IDENTITY_MANIFEST}" --probe quality-config-diagnostics \
  --harness-role baseline --harness "${BASELINE_HARNESS}" \
  --campaign-run custom-v2-config-balanced-01 --campaign "${FAILED_CAMPAIGN}" \
  --skip-harness-install --producer-bin "${WORK}/mock-producer" \
  --out "${WORK}/failed-campaign-retry" 2>&1)" || rc=$?
assert_eq "T7h: failed first attempt cannot be retried into canonical evidence" "2" "${rc}"
assert_contains "T7h: failed slot remains occupied" "first-attempt slot already exists" "${retry_out}"

printf 'T7e: compare output cannot alias, contain, or sit inside trusted inputs\n'
mkdir -p "${WORK}/output-target"
ln -s "${WORK}/output-target" "${WORK}/output-symlink"
rc=0; output_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/output-symlink" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7e: symlink output exits 2" "2" "${rc}"
assert_contains "T7e: symlink output policy is explicit" "must not be a symlink" "${output_out}"

rc=0; output_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/artifacts/generic/nested-pair" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7e: artifact-contained output exits 2" "2" "${rc}"
assert_contains "T7e: artifact containment is explicit" "must be disjoint" "${output_out}"
assert_eq "T7e: artifact-contained output was never created" "false" \
  "$([[ -e "${WORK}/artifacts/generic/nested-pair" ]] && printf true || printf false)"

rc=0; output_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${CHALLENGER_HARNESS}/nested-pair" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7e: challenger-contained output exits 2" "2" "${rc}"
assert_contains "T7e: harness containment is explicit" "output directory must be external" "${output_out}"
assert_eq "T7e: challenger checkout remains clean" "" \
  "$(git -C "${CHALLENGER_HARNESS}" status --porcelain --untracked-files=all)"

ln -s "${WORK}/baseline.json" "${WORK}/baseline-summary-link.json"
rc=0; output_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline-summary-link.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-summary-link" \
  --judge-bin "${WORK}/mock-judge" 2>&1)" || rc=$?
assert_eq "T7e: symlinked summary exits 2" "2" "${rc}"
assert_contains "T7e: summary symlink policy is explicit" \
  "regular non-symlink file" "${output_out}"

printf 'T8: strict judge output missing visionary fails after bounded retry\n'
export MOCK_MODE=invalid
rc=0; invalid_judge_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-invalid-judge" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed 2>&1)" || rc=$?
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

printf 'T8c: judge evidence must be structured and point to an existing artifact path\n'
jq '.dimensions.deliberate.evidence = ["good"]' \
  "${WORK}/pair win/judge-forward.response.json" > "${WORK}/unstructured-evidence.json"
rc=0; evidence_out="$(bash "${PAIRWISE}" reconcile \
  --pair "${WORK}/pair win/pair.json" \
  --forward "${WORK}/unstructured-evidence.json" \
  --reverse "${WORK}/pair win/judge-reverse.response.json" \
  --out "${WORK}/unstructured-evidence-receipt.json" 2>&1)" || rc=$?
assert_eq "T8c: unstructured evidence exits 2" "2" "${rc}"
assert_contains "T8c: unstructured evidence names response" "invalid forward judge response" "${evidence_out}"

jq '.dimensions.deliberate.evidence[0].path = "invented.txt"' \
  "${WORK}/pair win/judge-forward.response.json" > "${WORK}/invented-evidence.json"
rc=0; evidence_out="$(bash "${PAIRWISE}" reconcile \
  --pair "${WORK}/pair win/pair.json" \
  --forward "${WORK}/invented-evidence.json" \
  --reverse "${WORK}/pair win/judge-reverse.response.json" \
  --out "${WORK}/invented-evidence-receipt.json" 2>&1)" || rc=$?
assert_eq "T8c: invented path exits 2" "2" "${rc}"
assert_contains "T8c: invented path names response" "invalid forward judge response" "${evidence_out}"

printf 'T8d: reconcile refuses to clobber an input evidence file\n'
forward_before="$(shasum -a 256 "${WORK}/pair win/judge-forward.response.json" | awk '{print $1}')"
rc=0; alias_out="$(bash "${PAIRWISE}" reconcile \
  --pair "${WORK}/pair win/pair.json" \
  --forward "${WORK}/pair win/judge-forward.response.json" \
  --reverse "${WORK}/pair win/judge-reverse.response.json" \
  --out "${WORK}/pair win/judge-forward.response.json" 2>&1)" || rc=$?
assert_eq "T8d: aliased reconcile output exits 2" "2" "${rc}"
assert_contains "T8d: alias policy is explicit" "must not alias an input evidence file" "${alias_out}"
assert_eq "T8d: forward evidence remains byte-identical" "${forward_before}" \
  "$(shasum -a 256 "${WORK}/pair win/judge-forward.response.json" | awk '{print $1}')"

manual_reconcile_fifo_out="${WORK}/manual-reconcile-fifo-receipt.json"
manual_reconcile_fifo_started_at="$(date +%s)"
rc=0; manual_reconcile_fifo_log="$( \
  OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS=1 \
  OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=1 \
  bash -c '
    source "$1"
    trap cleanup_all_on_exit EXIT
    forward_source="$3"
    eval "$(declare -f regular_file_seal_json_bounded \
      | sed "1s/regular_file_seal_json_bounded/real_regular_file_seal_json_bounded/")"
    shasum() {
      local target="${!#}"
      if [[ "${OMC_TEST_RECONCILE_LIVE_SEAL:-0}" == "1" \
          && "${target}" == "${forward_source}" && -f "${target}" ]]; then
        rm -f "${target}"
        mkfifo "${target}"
      fi
      command shasum "$@"
    }
    regular_file_seal_json_bounded() {
      if [[ "$1" == "${forward_source}" ]]; then
        OMC_TEST_RECONCILE_LIVE_SEAL=1 \
          real_regular_file_seal_json_bounded "$@"
      else
        real_regular_file_seal_json_bounded "$@"
      fi
    }
    cmd_reconcile --pair "$2" --forward "${forward_source}" \
      --reverse "$4" --out "$5"
  ' pairwise-manual-reconcile-fifo "${PAIRWISE_LIBRARY}" \
    "${WORK}/pair win/pair.json" \
    "${WORK}/pair win/judge-forward.response.json" \
    "${WORK}/pair win/judge-reverse.response.json" \
    "${manual_reconcile_fifo_out}" 2>&1
)" || rc=$?
manual_reconcile_fifo_elapsed=$(( $(date +%s) - manual_reconcile_fifo_started_at ))
assert_eq "T8d: post-snapshot manual-reconcile input swap exits 2" "2" "${rc}"
assert_contains "T8d: bounded manual-reconcile seal failure is explicit" \
  "could not safely seal live manual forward identity" "${manual_reconcile_fifo_log}"
assert_eq "T8d: manual-reconcile live input swap cannot hang" "true" \
  "$([[ "${manual_reconcile_fifo_elapsed}" -le 15 ]] && printf true || printf false)"
assert_eq "T8d: unsafe manual input cannot publish a receipt" "false" \
  "$([[ -e "${manual_reconcile_fifo_out}" || -L "${manual_reconcile_fifo_out}" ]] \
    && printf true || printf false)"

printf 'T8e: requested and returned judge model IDs must agree\n'
ln -s "${WORK}/mock-judge" "${WORK}/claude"
rc=0; model_out="$(PATH="${WORK}:${PATH}" "${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-alias-model" \
  --judge-bin claude --judge-model sonnet --seed stable-seed 2>&1)" || rc=$?
assert_eq "T8e: convenience model alias exits 2" "2" "${rc}"
assert_contains "T8e: full pinned model contract is explicit" \
  "full pinned Claude model ID" "${model_out}"

rc=0; symlink_judge_out="$(PATH="${WORK}:${PATH}" "${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-symlink-judge" \
  --judge-bin claude --judge-model claude-judge-test-1 \
  --seed stable-seed 2>&1)" || rc=$?
assert_eq "T8e: symlinked judge binary exits 2" "2" "${rc}"
assert_contains "T8e: judge requires one regular executable identity" \
  "judge binary not found or is not a regular executable" "${symlink_judge_out}"

export MOCK_ACTUAL_MODEL="judge-other-model"
rc=0; model_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-model-mismatch" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed 2>&1)" || rc=$?
unset MOCK_ACTUAL_MODEL
assert_eq "T8e: judge model mismatch exits 2" "2" "${rc}"
assert_contains "T8e: mismatch exhausts bounded validation" "failed strict validation twice" "${model_out}"

printf 'T8f: a hanging judge is bounded and its isolated workspaces are removed\n'
cwd_lines_before="$(wc -l < "${MOCK_LOG_DIR}/cwd.log" | awk '{print $1}')"
export MOCK_MODE=hang
rc=0; timeout_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-timeout" \
  --judge-bin "${WORK}/mock-judge" --judge-timeout 1 --seed stable-seed 2>&1)" || rc=$?
unset MOCK_MODE
assert_eq "T8f: timed-out judge exits 2" "2" "${rc}"
assert_contains "T8f: bounded retry failure is explicit" "failed strict validation twice" "${timeout_out}"
leaked_workspace=false
while IFS= read -r judge_cwd; do
  [[ -n "${judge_cwd}" ]] || continue
  if [[ -d "${judge_cwd}" ]]; then leaked_workspace=true; fi
done < <(tail -n "+$((cwd_lines_before + 1))" "${MOCK_LOG_DIR}/cwd.log")
assert_eq "T8f: timed-out isolated workspaces are removed" "false" "${leaked_workspace}"
orphaned_judge_child=false
while IFS= read -r hang_pid; do
  [[ -n "${hang_pid}" ]] || continue
  hang_state="$(ps -o stat= -p "${hang_pid}" 2>/dev/null | tr -d '[:space:]' || true)"
  case "${hang_state}" in
    ""|Z*) ;;
    *)
      orphaned_judge_child=true
      kill -KILL "${hang_pid}" 2>/dev/null || true
      ;;
  esac
done < "${MOCK_LOG_DIR}/hang-pids.log"
assert_eq "T8f: TERM-ignoring descendants are KILLed after wrapper exit" "false" "${orphaned_judge_child}"

rc=0; invalid_grace_out="$(OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS=invalid \
  bash "${PAIRWISE}" report "${receipt_win}" 2>&1)" || rc=$?
assert_eq "T8f: invalid timeout kill grace exits 2" "2" "${rc}"
assert_contains "T8f: timeout kill grace contract is explicit" \
  "OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS must be an integer from 1 to 60" \
  "${invalid_grace_out}"

legacy_timeout_marker="${WORK}/legacy-timeout-marker"
timeout_sentinel="${WORK}/timeout-sentinel"
printf 'reserved marker\n' > "${legacy_timeout_marker}"
printf 'sentinel intact\n' > "${timeout_sentinel}"
rc=0; marker_race_out="$(bash -c '
  source "$1"
  legacy_marker="$2"
  sentinel="$3"
  mktemp() {
    if [[ "$*" == "-t omc-pairwise-timeout-XXXXXX" ]]; then
      printf "%s\n" "${legacy_marker}"
    else
      command mktemp "$@"
    fi
  }
  run_with_timeout 1 bash -c '\''
    marker="$1"
    sentinel="$2"
    while [[ -e "${marker}" ]]; do :; done
    ln -s "${sentinel}" "${marker}"
    sleep 5
  '\'' timeout-marker-child "${legacy_marker}" "${sentinel}"
' pairwise-timeout-marker "${PAIRWISE_LIBRARY}" \
  "${legacy_timeout_marker}" "${timeout_sentinel}" 2>&1)" || rc=$?
assert_eq "T8f: private timeout marker still returns the timeout status" "124" "${rc}"
assert_eq "T8f: timeout marker cannot be replaced with a sentinel symlink" \
  "sentinel intact" "$(tr -d '\n' < "${timeout_sentinel}")"

printf 'T8g: judge output is byte-bounded during capture\n'
export MOCK_MODE=oversized
rc=0; oversized_out="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-oversized-judge" \
  --judge-bin "${WORK}/mock-judge" --max-judge-response-bytes 512 \
  --seed stable-seed 2>&1)" || rc=$?
unset MOCK_MODE
assert_eq "T8g: oversized judge exits 2" "2" "${rc}"
assert_contains "T8g: oversized response exhausts bounded validation" \
  "failed strict validation twice" "${oversized_out}"
max_raw_bytes="$(wc -c "${WORK}"/pair-oversized-judge/judge-forward.attempt-*.json \
  | awk 'NR <= 2 && $1 > max {max=$1} END {print max + 0}')"
assert_eq "T8g: OS file limit bounds each raw attempt to at most one KiB block" "true" \
  "$([[ "${max_raw_bytes}" -le 1024 ]] && printf true || printf false)"

printf 'T8h: default response and receipt caps form one closed evidence contract\n'
export MOCK_MODE=large-valid
large_receipt="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" --out "${WORK}/pair-large-valid" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed)"
unset MOCK_MODE
large_receipt_bytes="$(wc -c < "${large_receipt}" | awk '{print $1}')"
assert_eq "T8h: valid default pair can exceed the former four-MiB report cap" "true" \
  "$([[ "${large_receipt_bytes}" -gt 4194304 ]] && printf true || printf false)"
assert_eq "T8h: valid default pair stays within the unified sixteen-MiB cap" "true" \
  "$([[ "${large_receipt_bytes}" -le 16777216 ]] && printf true || printf false)"
assert_eq "T8h: report accepts the largest default-valid receipt class" "1" \
  "$(bash "${PAIRWISE}" report "${large_receipt}" | jq -r '.pair_count')"
rc=0; large_claim="$(bash "${PAIRWISE}" claim-check "${large_receipt}" \
  "${DEV_CLAIM_THRESHOLDS[@]}" 2>&1)" || rc=$?
assert_eq "T8h: claim-check accepts the same default-valid receipt class" "0" "${rc}"

printf 'T9: report carries pair outcomes and candidate/judge economics\n'
report_file="${WORK}/report.json"
bash "${PAIRWISE}" report "${receipt_win}" "${receipt_same}" > "${report_file}"
assert_eq "T9: two pairs" "2" "$(jq -r '.pair_count' "${report_file}")"
assert_eq "T9: one challenger win" "1" "$(jq -r '.outcomes.challenger_wins' "${report_file}")"
assert_eq "T9: one tie" "1" "$(jq -r '.outcomes.ties' "${report_file}")"
assert_eq "T9: win rate includes tie denominator" "0.5" "$(jq -r '.outcomes.win_rate' "${report_file}")"
assert_eq "T9: report inventories probe identities" '["quality-config-diagnostics"]' \
  "$(jq -c '.probe_ids' "${report_file}")"
assert_eq "T9: report binds the canonical full-probe digest" "true" \
  "$(jq -r --arg probe_hash "${canonical_probe_hash}" '
    .probe_identity == {
      authorities:["canonical"],
      bindings:[{probe_id:"quality-config-diagnostics",probe_hash:$probe_hash,authority:"canonical"}]
    }
  ' "${report_file}")"
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
  "$(jq -r '.schema_version == 6 and (.report_hash | test("^[0-9a-f]{64}$")) and (.receipt_hashes | length == 2)' "${report_file}")"
assert_eq "T9: report inventories exact campaign runs, models, and probe budgets" "true" \
  "$(jq -r '
    (.campaign.run_ids | length) == .pair_count
    and .campaign.candidate_models == ["claude-test-model-1"]
    and .campaign.probe_campaigns == [{
      probe_id:"quality-config-diagnostics",
      runs_per_arm:3,
      model_tiers:["balanced","economy"],
      max_candidate_cost_ratio:1.75,
      max_candidate_wall_ratio:1.75
    }]
    and .economics.probe_budget_failures == {cost:0,wall:0,pairs:0}
  ' "${report_file}")"
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
assert_eq "T9: report exposes one coherent sealed judge identity" "true" \
  "$(jq -r '
    .judge_identity.plan_authorities == ["custom"]
    and .judge_identity.requested_models == ["judge-test-model-1"]
    and .judge_identity.actual_models == ["judge-test-model-1"]
    and .judge_identity.execution_authorities == ["cli-json"]
    and .judge_identity.binary_versions == ["unattested"]
    and .judge_identity.binary_locations == ["custom"]
    and .judge_identity.policy_hashes == [null]
    and (.judge_identity.binary_hashes | length) == 1
    and (.judge_identity.schema_hashes | length) == 1
    and .judge_identity.prompt_identity_pairs == .pair_count
  ' "${report_file}")"
assert_eq "T9: report inventories unique evaluator-owned generation evidence" "true" \
  "$(jq -r '
    .generation_identity.authorities == ["custom"]
    and .generation_identity.probe_authorities == ["canonical"]
    and (.generation_identity.probe_hashes | length) == 4
    and (.generation_identity.generation_ids | length) == 4
    and (.generation_identity.generation_ids | unique | length) == 4
    and (.generation_identity.producer_sessions | unique | length) == 4
    and (.generation_identity.telemetry_hashes | unique | length) == 4
    and (.generation_identity.receipt_hashes | unique | length) == 4
  ' "${report_file}")"
reverse_report_hash="$(bash "${PAIRWISE}" report "${receipt_same}" "${receipt_win}" | jq -r '.report_hash')"
assert_eq "T9: report seal is independent of argument order" "$(jq -r '.report_hash' "${report_file}")" \
  "${reverse_report_hash}"

printf 'T9a: report and claim consume one bounded private receipt snapshot\n'
mkdir -p "${WORK}/receipt-snapshot-tmp"
ln -s "${receipt_win}" "${WORK}/receipt-link.json"
rc=0; snapshot_limit_out="$(TMPDIR="${WORK}/receipt-snapshot-tmp" bash "${PAIRWISE}" report \
  "${WORK}/receipt-link.json" 2>&1)" || rc=$?
assert_eq "T9a: symlinked receipt exits 2" "2" "${rc}"
assert_contains "T9a: regular non-symlink receipt contract is explicit" \
  "regular non-symlink file" "${snapshot_limit_out}"
assert_eq "T9a: error exit removes its private receipt directory" "false" \
  "$(find "${WORK}/receipt-snapshot-tmp" -maxdepth 1 -type d \
    -name 'omc-pairwise-receipts-*' -print -quit | grep -q . && printf true || printf false)"

rc=0; snapshot_limit_out="$(OMC_PAIRWISE_MAX_RECEIPTS=1 bash "${PAIRWISE}" report \
  "${receipt_win}" "${receipt_same}" 2>&1)" || rc=$?
assert_eq "T9a: receipt count overflow exits 2" "2" "${rc}"
assert_contains "T9a: receipt count bound is explicit" \
  "receipt count limit" "${snapshot_limit_out}"

rc=0; snapshot_limit_out="$(OMC_PAIRWISE_MAX_RECEIPT_BYTES=10 bash "${PAIRWISE}" report \
  "${receipt_win}" 2>&1)" || rc=$?
assert_eq "T9a: receipt byte overflow exits 2" "2" "${rc}"
assert_contains "T9a: receipt byte bound is explicit" \
  "receipt exceeds the configured byte limit" "${snapshot_limit_out}"

receipt_total_cap=$(( $(wc -c < "${receipt_win}") \
  + $(wc -c < "${receipt_same}") - 1 ))
rc=0; snapshot_total_limit_out="$(OMC_PAIRWISE_MAX_RECEIPT_TOTAL_BYTES="${receipt_total_cap}" \
  bash "${PAIRWISE}" report "${receipt_win}" "${receipt_same}" 2>&1)" || rc=$?
assert_eq "T9a: cumulative receipt byte overflow exits 2" "2" "${rc}"
assert_contains "T9a: cumulative receipt byte bound is explicit" \
  "cumulative receipt byte limit" "${snapshot_total_limit_out}"

for receipt_limit_name in OMC_PAIRWISE_MAX_RECEIPTS \
    OMC_PAIRWISE_MAX_RECEIPT_BYTES OMC_PAIRWISE_MAX_RECEIPT_TOTAL_BYTES; do
  rc=0; unsafe_limit_out="$(env \
    "${receipt_limit_name}=999999999999999999999999999999999999" \
    bash "${PAIRWISE}" report "${receipt_win}" 2>&1)" || rc=$?
  assert_eq "T9a: ${receipt_limit_name} signed-overflow input exits 2" "2" "${rc}"
  assert_contains "T9a: ${receipt_limit_name} overflow is rejected before arithmetic" \
    "must be an integer from 1 to" "${unsafe_limit_out}"
done

mkdir -p "${WORK}/receipt-jq-bin"
cp "${receipt_win}" "${WORK}/live-receipt.json"
REAL_JQ="$(command -v jq)"
printf '0' > "${WORK}/receipt-jq-count"
cat > "${WORK}/receipt-jq-bin/jq" <<'JQ_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
target_seen=false
for arg in "$@"; do
  if [[ "${arg}" == "${SWAP_LIVE_RECEIPT}" \
      || "${arg}" == *omc-pairwise-receipts-*/000001.json ]]; then
    target_seen=true
    if [[ "${arg}" == *omc-pairwise-receipts-*/000001.json \
        && ! -e "${SWAP_SNAPSHOT_PATH_FILE}" ]]; then
      printf '%s\n' "${arg}" > "${SWAP_SNAPSHOT_PATH_FILE}"
    fi
    break
  fi
done
if [[ "${target_seen}" == "true" ]]; then
  count="$(cat "${SWAP_JQ_COUNT}")"
  count=$((count + 1))
  printf '%s' "${count}" > "${SWAP_JQ_COUNT}"
  if [[ "${count}" -eq 2 && ! -e "${SWAP_MARKER}" ]]; then
    cp "${SWAP_REPLACEMENT_RECEIPT}" "${SWAP_LIVE_RECEIPT}.next"
    mv "${SWAP_LIVE_RECEIPT}.next" "${SWAP_LIVE_RECEIPT}"
    : > "${SWAP_MARKER}"
  fi
fi
exec "${REAL_JQ}" "$@"
JQ_WRAPPER
chmod +x "${WORK}/receipt-jq-bin/jq"
rc=0; frozen_claim="$(PATH="${WORK}/receipt-jq-bin:${PATH}" \
  REAL_JQ="${REAL_JQ}" \
  SWAP_LIVE_RECEIPT="${WORK}/live-receipt.json" \
  SWAP_REPLACEMENT_RECEIPT="${receipt_same}" \
  SWAP_JQ_COUNT="${WORK}/receipt-jq-count" \
  SWAP_MARKER="${WORK}/receipt-swap-fired" \
  SWAP_SNAPSHOT_PATH_FILE="${WORK}/receipt-snapshot-path" \
  bash "${PAIRWISE}" claim-check \
  "${WORK}/live-receipt.json" --allow-custom-portfolio \
  --min-pairs 1 --min-domains 1 --min-tiers 1 \
  --min-axis-pairs 1 --max-challenger-scope-creep 0 \
  --min-win-rate 0.5 --max-loss-rate 0 \
  --min-positive-axes 5 --min-visionary-margin 0.5 \
  --max-sign-p-value 1 \
  --max-median-cost-ratio 2 --max-median-wall-ratio 2 \
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2 2>&1)" || rc=$?
assert_eq "T9a: controlled receipt replacement fired during validation" "true" \
  "$([[ -e "${WORK}/receipt-swap-fired" ]] && printf true || printf false)"
assert_eq "T9a: claim over frozen receipt bytes still passes" "0" "${rc}"
assert_eq "T9a: frozen claim retains the initially snapshotted challenger win" "true" \
  "$(jq -r '.pass and .observed.win_rate == 1' <<<"${frozen_claim}")"
assert_eq "T9a: live path was concurrently replaced with the tie receipt" "tie" \
  "$(jq -r '.winner' "${WORK}/live-receipt.json")"
receipt_snapshot_path="$(cat "${WORK}/receipt-snapshot-path")"
assert_eq "T9a: successful claim removes its exact private receipt directory" "false" \
  "$([[ -e "$(dirname "${receipt_snapshot_path}")" ]] && printf true || printf false)"

printf 'T9b: duplicate pair receipts cannot inflate campaign size\n'
rc=0; duplicate_out="$(bash "${PAIRWISE}" report "${receipt_win}" "${receipt_win}" 2>&1)" || rc=$?
assert_eq "T9b: duplicate pair exits 2" "2" "${rc}"
assert_contains "T9b: duplicate causal campaign run is named" "duplicate campaign run" "${duplicate_out}"

cp -R "${WORK}/artifacts/identical" "${WORK}/artifacts/collision-a"
cp -R "${WORK}/artifacts/identical-b" "${WORK}/artifacts/collision-b"
SUMMARY_RUN_ID=dev-run-win SUMMARY_SEED=stable-seed make_summary \
  "${WORK}/collision-a.json" "${WORK}/artifacts/collision-a" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-win SUMMARY_SEED=stable-seed make_summary \
  "${WORK}/collision-b.json" "${WORK}/artifacts/collision-b" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
receipt_run_collision="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/collision-a.json" \
  --challenger "${WORK}/collision-b.json" \
  --out "${WORK}/pair-run-collision" \
  --campaign-run "$(jq -r '.campaign_run.id' "${receipt_win}")" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed)"
rc=0; duplicate_run_out="$(bash "${PAIRWISE}" report \
  "${receipt_win}" "${receipt_run_collision}" 2>&1)" || rc=$?
assert_eq "T9b: duplicate campaign run exits 2" "2" "${rc}"
assert_contains "T9b: duplicate campaign run is named" \
  "duplicate campaign run" "${duplicate_run_out}"

cp -R "${WORK}/artifacts/identical" "${WORK}/artifacts/session-collision-a"
cp -R "${WORK}/artifacts/identical-b" "${WORK}/artifacts/session-collision-b"
SUMMARY_RUN_ID=dev-run-session-collision SUMMARY_SEED=session-collision-seed \
  SUMMARY_SESSION_ID="$(jq -r '.pair_manifest.candidates.baseline.generation.producer_session_id' "${receipt_win}")" \
  make_summary "${WORK}/session-collision-a.json" "${WORK}/artifacts/session-collision-a" \
    "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-session-collision SUMMARY_SEED=session-collision-seed \
  make_summary "${WORK}/session-collision-b.json" "${WORK}/artifacts/session-collision-b" \
    "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
receipt_session_collision="$("${PAIRWISE_COMPARE[@]}" --campaign-run dev-run-session-collision \
  --probe quality-config-diagnostics --baseline "${WORK}/session-collision-a.json" \
  --challenger "${WORK}/session-collision-b.json" --out "${WORK}/pair-session-collision" \
  --judge-bin "${WORK}/mock-judge" --seed session-collision-seed)"
rc=0; duplicate_session_out="$(bash "${PAIRWISE}" report \
  "${receipt_win}" "${receipt_session_collision}" 2>&1)" || rc=$?
assert_eq "T9b: reused producer session exits 2" "2" "${rc}"
assert_contains "T9b: reused producer session is named" \
  "reused producer session identity" "${duplicate_session_out}"

printf 'T9c: aggregate reports are never accepted as claim evidence\n'
rc=0; aggregate_claim="$(bash "${PAIRWISE}" claim-check "${report_file}" 2>&1)" || rc=$?
assert_eq "T9c: aggregate input exits 2" "2" "${rc}"
assert_contains "T9c: aggregate is rejected as an invalid raw receipt" "invalid, unsealed, or stale pairwise receipt" "${aggregate_claim}"

printf 'T9d: malformed receipt fields fail before aggregation\n'
jq 'del(.scope_creep.challenger)' "${receipt_win}" > "${WORK}/malformed-receipt.json"
rc=0; malformed_out="$(bash "${PAIRWISE}" report "${WORK}/malformed-receipt.json" 2>&1)" || rc=$?
assert_eq "T9d: malformed receipt exits 2" "2" "${rc}"
assert_contains "T9d: malformed receipt is named" "invalid, unsealed, or stale pairwise receipt" "${malformed_out}"

# Recompute every local integrity hash after stripping a required producer
# field. Portable report validation must enforce the embedded generation
# contract itself, not merely trust that compare once saw a valid sibling.
jq 'del(.pair_manifest.candidates.baseline.generation.receipt.producer.binary_name)
  | del(.pair_manifest.candidates.baseline.generation.receipt.receipt_hash)
  | del(.pair_manifest.manifest_hash, .pair_manifest_hash, .receipt_hash)' \
  "${receipt_win}" > "${WORK}/malformed-generation.stage-1.json"
malformed_generation_hash="$(jq -cS '.pair_manifest.candidates.baseline.generation.receipt' \
  "${WORK}/malformed-generation.stage-1.json" | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${malformed_generation_hash}" '
  .pair_manifest.candidates.baseline.generation.receipt.receipt_hash = $hash
  | .pair_manifest.candidates.baseline.generation.receipt_hash = $hash
' "${WORK}/malformed-generation.stage-1.json" > "${WORK}/malformed-generation.stage-2.json"
malformed_pair_hash="$(jq -cS '.pair_manifest' "${WORK}/malformed-generation.stage-2.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${malformed_pair_hash}" '
  .pair_manifest.manifest_hash = $hash | .pair_manifest_hash = $hash
' "${WORK}/malformed-generation.stage-2.json" > "${WORK}/malformed-generation.stage-3.json"
malformed_receipt_hash="$(jq -cS . "${WORK}/malformed-generation.stage-3.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${malformed_receipt_hash}" '.receipt_hash = $hash' \
  "${WORK}/malformed-generation.stage-3.json" > "${WORK}/malformed-generation.json"
rc=0; malformed_out="$(bash "${PAIRWISE}" report \
  "${WORK}/malformed-generation.json" 2>&1)" || rc=$?
assert_eq "T9d: coherently resealed malformed generation exits 2" "2" "${rc}"
assert_contains "T9d: embedded generation contract fails closed" \
  "invalid, unsealed, or stale pairwise receipt" "${malformed_out}"

# Receipt schema v7 adds retained raw judge bytes and portable re-derivation.
# A coherently re-sealed schema-v6 receipt must not silently receive that new
# meaning merely because its pair manifest already has causal generation data.
jq '.schema_version = 6 | del(.receipt_hash)' \
  "${receipt_win}" > "${WORK}/legacy-v6-receipt.unsealed.json"
legacy_v6_receipt_hash="$(jq -cS . "${WORK}/legacy-v6-receipt.unsealed.json" \
  | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${legacy_v6_receipt_hash}" '.receipt_hash = $hash' \
  "${WORK}/legacy-v6-receipt.unsealed.json" > "${WORK}/legacy-v6-receipt.json"
rc=0; legacy_v6_claim_out="$(bash "${PAIRWISE}" report \
  "${WORK}/legacy-v6-receipt.json" 2>&1)" || rc=$?
assert_eq "T9d: coherently sealed schema-v6 receipt exits 2" "2" "${rc}"
assert_contains "T9d: schema-v6 receipt does not inherit v7 judge authority" \
  "invalid, unsealed, or stale pairwise receipt" "${legacy_v6_claim_out}"

# Even a coherently re-sealed legacy receipt/pair cannot enter the claim path:
# pair-manifest schema v6 is the first format with causal generation receipts
# and raw producer telemetry, so accepting a v5 pair would restore
# caller-selected data.
jq '.schema_version = 5 | del(.manifest_hash)' \
  "${WORK}/pair win/pair.json" > "${WORK}/legacy-v5-pair.unsealed.json"
legacy_pair_hash="$(jq -cS . "${WORK}/legacy-v5-pair.unsealed.json" | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${legacy_pair_hash}" '.manifest_hash = $hash' \
  "${WORK}/legacy-v5-pair.unsealed.json" > "${WORK}/legacy-v5-pair.json"
jq --slurpfile pair "${WORK}/legacy-v5-pair.json" '
  .schema_version = 5
  | .pair_manifest = $pair[0]
  | .pair_manifest_hash = $pair[0].manifest_hash
  | del(.receipt_hash)
' "${receipt_win}" > "${WORK}/legacy-v5-receipt.unsealed.json"
legacy_receipt_hash="$(jq -cS . "${WORK}/legacy-v5-receipt.unsealed.json" | shasum -a 256 | awk '{print $1}')"
jq --arg hash "${legacy_receipt_hash}" '.receipt_hash = $hash' \
  "${WORK}/legacy-v5-receipt.unsealed.json" > "${WORK}/legacy-v5-receipt.json"
rc=0; legacy_claim_out="$(bash "${PAIRWISE}" claim-check \
  "${WORK}/legacy-v5-receipt.json" --allow-custom-portfolio 2>&1)" || rc=$?
assert_eq "T9d: coherently sealed schema-v5 receipt exits 2" "2" "${rc}"
assert_contains "T9d: schema-v5 evidence fails closed before claim aggregation" \
  "invalid, unsealed, or stale pairwise receipt" "${legacy_claim_out}"

printf 'T9e: exact reruns are rejected while independent repeated artifact outcomes aggregate\n'
receipt_replay="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-replay" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed)"
assert_eq "T9e: pair identity ignores seed" "$(jq -r '.pair_identity' "${receipt_win}")" \
  "$(jq -r '.pair_identity' "${receipt_replay}")"
rc=0; replay_out="$(bash "${PAIRWISE}" report "${receipt_win}" "${receipt_replay}" 2>&1)" || rc=$?
assert_eq "T9e: replayed pair exits 2" "2" "${rc}"
assert_contains "T9e: replayed campaign run is named" "duplicate campaign run" "${replay_out}"

cp -R "${WORK}/artifacts/generic" "${WORK}/artifacts/replay-run-a"
cp -R "${WORK}/artifacts/crafted" "${WORK}/artifacts/replay-run-b"
SUMMARY_RUN_ID=dev-run-replay SUMMARY_SEED=replay-seed make_summary \
  "${WORK}/replay-run-a.json" "${WORK}/artifacts/replay-run-a" \
  "${BASELINE_HARNESS_HASH}" "${FIXTURE_HASH}" true 1 100 100 50
SUMMARY_RUN_ID=dev-run-replay SUMMARY_SEED=replay-seed make_summary \
  "${WORK}/replay-run-b.json" "${WORK}/artifacts/replay-run-b" \
  "${CHALLENGER_HARNESS_HASH}" "${FIXTURE_HASH}" true 1.5 120 180 110
receipt_other_run="$("${PAIRWISE_COMPARE[@]}" --campaign-run dev-run-replay \
  --probe quality-config-diagnostics --baseline "${WORK}/replay-run-a.json" \
  --challenger "${WORK}/replay-run-b.json" --out "${WORK}/pair-replay-other-run" \
  --judge-bin "${WORK}/mock-judge" --seed replay-seed)"
assert_eq "T9e: artifact-pair identity excludes caller-selected run id" \
  "$(jq -r '.pair_identity' "${receipt_win}")" "$(jq -r '.pair_identity' "${receipt_other_run}")"
assert_eq "T9e: causal pair id still distinguishes the two generated runs" "true" \
  "$(jq -r --slurpfile other "${receipt_other_run}" '.pair_id != $other[0].pair_id' "${receipt_win}")"
repeated_artifact_report="$(bash "${PAIRWISE}" report "${receipt_win}" "${receipt_other_run}")"
assert_eq "T9e: independent repeated artifact observations aggregate" "true" \
  "$(jq -r '
    .pair_count == 2
    and (.pair_identities | unique | length) == 1
    and (.pair_ids | unique | length) == 2
    and (.campaign.run_ids | unique | length) == 2
    and (.generation_identity.generation_ids | unique | length) == 4
  ' <<<"${repeated_artifact_report}")"

printf 'T9f: blocking hard-quality warnings survive role mapping and block claims\n'
export MOCK_WARNING=blocking
receipt_warning="$("${PAIRWISE_COMPARE[@]}" \
  --probe quality-config-diagnostics \
  --baseline "${WORK}/baseline.json" \
  --challenger "${WORK}/challenger.json" \
  --out "${WORK}/pair-warning" \
  --judge-bin "${WORK}/mock-judge" --seed stable-seed)"
unset MOCK_WARNING
assert_eq "T9f: warning maps to challenger" "challenger" \
  "$(jq -r '.hard_quality_warning[0].candidate' "${receipt_warning}")"
assert_eq "T9f: warning remains blocking" "blocking" \
  "$(jq -r '.hard_quality_warning[0].severity' "${receipt_warning}")"
bash "${PAIRWISE}" report "${receipt_warning}" > "${WORK}/warning-report.json"
assert_eq "T9f: report counts challenger blocking warning" "1" \
  "$(jq -r '.hard_quality_warnings.challenger_blocking' "${WORK}/warning-report.json")"
rc=0; warning_claim="$(bash "${PAIRWISE}" claim-check "${receipt_warning}" \
  --allow-custom-portfolio \
  --min-pairs 1 --min-domains 1 --min-tiers 1 \
  --min-axis-pairs 1 --max-challenger-scope-creep 0 \
  --min-win-rate 0.5 --max-loss-rate 0 \
  --min-positive-axes 5 --min-visionary-margin 0.5 \
  --max-sign-p-value 1 \
  --max-median-cost-ratio 2 --max-median-wall-ratio 2 \
  --max-p95-cost-ratio 2 --max-p95-wall-ratio 2 2>&1)" || rc=$?
assert_eq "T9f: blocking warning claim exits nonzero" "1" "${rc}"
assert_eq "T9f: warning is the explicit claim blocker" '["challenger_hard_quality_warning"]' \
  "$(jq -c '.failures' <<<"${warning_claim}")"

printf 'T10: sealed release threshold refuses an undersized campaign\n'
rc=0; threshold_override_out="$(bash "${PAIRWISE}" claim-check "${receipt_win}" \
  --min-pairs 1 2>&1)" || rc=$?
assert_eq "T10: canonical threshold override exits 2" "2" "${rc}"
assert_contains "T10: canonical thresholds cannot be weakened by CLI flags" \
  "canonical claim thresholds are sealed and cannot be overridden" "${threshold_override_out}"
rc=0; claim_fail="$(bash "${PAIRWISE}" claim-check "${receipt_win}" "${receipt_same}" 2>&1)" || rc=$?
assert_eq "T10: claim gate exits nonzero" "1" "${rc}"
assert_eq "T10: pass=false" "false" "$(jq -r '.pass' <<<"${claim_fail}")"
assert_contains "T10: pair-count failure explicit" "pair_count" "${claim_fail}"
assert_contains "T10: custom evidence cannot make a release claim" \
  "canonical_harness_authority" "${claim_fail}"
assert_contains "T10: partial or custom evidence cannot claim the canonical probe portfolio" \
  "canonical_probe_authority" "${claim_fail}"
assert_contains "T10: release claim binds the receipt to the current canonical checkout" \
  "canonical_challenger_checkout" "${claim_fail}"
assert_contains "T10: custom judge evidence cannot satisfy canonical release policy" \
  "canonical_judge_identity" "${claim_fail}"
assert_contains "T10: caller-selected receipts cannot satisfy the exact release roster" \
  "sealed_campaign_roster" "${claim_fail}"
assert_contains "T10: release evidence is bound to the committed candidate model" \
  "canonical_candidate_model" "${claim_fail}"
assert_contains "T10: release evidence requires complete first-attempt campaign authority" \
  "canonical_first_attempt_campaign" "${claim_fail}"
assert_eq "T10: claim output advertises the causal-generation roster schema" "3" \
  "$(jq -r '.schema_version' <<<"${claim_fail}")"

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
assert_eq "T11: passing claim uses schema v3" "3" "$(jq -r '.schema_version' <<<"${claim_pass}")"
assert_eq "T11: no failures" "0" "$(jq -r '.failures | length' <<<"${claim_pass}")"

printf '\n=== realwork-pairwise tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
