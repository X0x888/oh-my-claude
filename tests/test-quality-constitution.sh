#!/usr/bin/env bash
# Regression coverage for the user-owned Quality Constitution subsystem.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd -P)"
HELPER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/quality-constitution.sh"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

TEST_ROOT="$(mktemp -d -t quality-constitution-test-XXXXXX)"
TEST_HOME="${TEST_ROOT}/home"
PROJECT="${TEST_ROOT}/project"
OUTSIDE="${TEST_ROOT}/outside.txt"
mkdir -p "${TEST_HOME}" "${PROJECT}"
trap 'rm -rf "${TEST_ROOT}"' EXIT

git -C "${PROJECT}" init -q
git -C "${PROJECT}" remote add origin https://example.invalid/acme/quality-project.git
printf 'A compact reference artifact.\n' > "${PROJECT}/example.md"
printf 'outside\n' > "${OUTSIDE}"
ln -s "${OUTSIDE}" "${PROJECT}/outside-link.md"
ln -s outside-link.md "${PROJECT}/outside-link-hop.md"

pass=0
fail=0

ok() {
  printf '  PASS: %s\n' "$1"
  pass=$((pass + 1))
}

not_ok() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then ok "${label}"; else
    not_ok "${label} (expected=${expected} actual=${actual})"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then ok "${label}"; else
    not_ok "${label} (missing: ${needle})"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then ok "${label}"; else
    not_ok "${label} (unexpected: ${needle})"
  fi
}

assert_true() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "${label}"; else not_ok "${label}"; fi
}

assert_prefix() {
  local label="$1" prefix="$2" actual="$3"
  if [[ "${actual}" == "${prefix}"* ]]; then ok "${label}"; else
    not_ok "${label} (expected prefix=${prefix} actual=${actual})"
  fi
}

assert_nonempty() {
  local label="$1" actual="$2"
  if [[ -n "${actual}" ]]; then ok "${label}"; else not_ok "${label} (empty)"; fi
}

shell_quote() {
  # POSIX-shell-safe single-quote encoding, including control bytes. This is
  # used only to drive the helper through a pseudo-terminal so this suite
  # exercises the real standalone-human boundary.
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "${value}"
}

qcc_direct_tty() {
  local command_text="" arg="" output="" rc=0
  command_text="cd $(shell_quote "${PROJECT}") && HOME=$(shell_quote "${TEST_HOME}") bash $(shell_quote "${HELPER}") direct"
  for arg in "$@"; do
    command_text="${command_text} $(shell_quote "${arg}")"
  done
  set +e
  if [[ "$(uname -s)" == "Darwin" ]]; then
    output="$(script -q /dev/null /bin/bash -c "${command_text}" 2>&1)"
    rc=$?
  else
    output="$(script -q -e -c "${command_text}" /dev/null 2>&1)"
    rc=$?
  fi
  set -e
  output="${output//$'\r'/}"
  # BSD script writes a visual EOF marker when its parent stdin is closed.
  output="${output#$'^D\b\b'}"
  printf '%s' "${output}"
  return "${rc}"
}

qcc() {
  local command="${1:-}"
  case "${command}" in
    add-claim|accept|reject|add-reference|remove)
      qcc_direct_tty "$@"
      ;;
    *)
      (cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" "$@")
      ;;
  esac
}

qcc_env() {
  local evidence_cap="$1" candidate_cap="$2" audit_cap="$3"
  shift 3
  (cd "${PROJECT}" && \
    HOME="${TEST_HOME}" \
    OMC_QC_EVIDENCE_CAP="${evidence_cap}" \
    OMC_QC_CANDIDATE_CAP="${candidate_cap}" \
    OMC_QC_AUDIT_CAP="${audit_cap}" \
    bash "${HELPER}" "$@")
}

qcc_taste() {
  local mode="$1"
  shift
  (cd "${PROJECT}" && \
    HOME="${TEST_HOME}" \
    OMC_TASTE_LEARNING="${mode}" \
    bash "${HELPER}" "$@")
}

write_session_state() {
  local sid="$1" prompt="$2" objective="${3:-Improve the deliverable}"
  HOME="${TEST_HOME}" SESSION_ID="${sid}" bash -c '
    set -euo pipefail
    . "$1"
    ensure_session_dir
    write_state "last_user_prompt" "$2"
    write_state "current_objective" "$3"
  ' bash "${COMMON}" "${prompt}" "${objective}"
}

printf 'Test 1: resolve is read-only before first profile mutation\n'
resolved="$(qcc resolve --json)"
assert_eq "profile does not exist initially" "false" "$(jq -r '.exists' <<<"${resolved}")"
profile_path="$(jq -r '.path' <<<"${resolved}")"
assert_contains "canonical path is user-owned omc-user" "/.claude/omc-user/quality-constitutions/" "${profile_path}"
if [[ ! -e "${profile_path}" ]]; then ok "resolve did not create a profile"; else not_ok "resolve created a profile"; fi

printf 'Test 2: no-profile compile still carries all five axes including visionary\n'
compiled_empty="$(qcc compile --json --role planner)"
assert_eq "five baseline axes" "5" "$(jq '.baseline_axes | length' <<<"${compiled_empty}")"
assert_eq "visionary baseline present" "1" "$(jq '[.baseline_axes[] | select(.axis == "visionary")] | length' <<<"${compiled_empty}")"
assert_contains "visionary is future-opening" "materially better future" "$(jq -r '.baseline_axes[] | select(.axis == "visionary") | .criterion' <<<"${compiled_empty}")"

printf 'Test 3: explicit claim creates a valid profile and redacts persisted text\n'
claim_id="$(qcc add-claim \
  --category vision \
  --polarity aspire \
  --authority user_confirmed \
  --statement $'Build a\033[31m visionary result; token=supersecretvalue12345' \
  --rationale 'Open a better future without novelty theater')"
assert_prefix "claim id has canonical prefix" "qc_" "${claim_id}"
shown="$(qcc show --json)"
statement="$(jq -r --arg id "${claim_id}" '.claims[] | select(.id == $id) | .statement' <<<"${shown}")"
assert_contains "secret shape was redacted" "token=<redacted>" "${statement}"
assert_not_contains "raw secret absent" "supersecretvalue12345" "${statement}"
if [[ "${statement}" != *$'\033'* ]]; then ok "control byte stripped"; else not_ok "control byte persisted"; fi
assert_eq "explicit authority retained" "user_confirmed" "$(jq -r --arg id "${claim_id}" '.claims[] | select(.id == $id) | .authority' <<<"${shown}")"

printf 'Test 4: inferred/user-selected claims cannot become blocking\n'
generation_before="$(jq -r '.generation' <<<"${shown}")"
set +e
blocked_out="$(qcc add-claim --statement 'Guessed rule' --authority inferred --enforcement blocking 2>&1)"
blocked_rc=$?
set -e
if (( blocked_rc != 0 )); then ok "blocking inferred claim rejected"; else not_ok "blocking inferred claim accepted"; fi
assert_contains "rejection explains authority boundary" "only user_pinned or user_confirmed" "${blocked_out}"
assert_eq "failed mutation did not advance generation" "${generation_before}" "$(qcc show --json | jq -r '.generation')"
set +e
weak_blocker_out="$(qcc add-claim \
  --statement 'A preference cannot silently become a hard gate' \
  --authority user_confirmed \
  --enforcement blocking \
  --polarity prefer 2>&1)"
weak_blocker_rc=$?
set -e
if (( weak_blocker_rc != 0 )); then ok "blocking preference polarity rejected"; else not_ok "blocking preference polarity accepted"; fi
assert_contains "blocking polarity failure is actionable" "must or must_not" "${weak_blocker_out}"

printf 'Test 5: inferred advisory claims render separately as tentative\n'
inferred_id="$(qcc add-claim \
  --statement 'Prefer compact evidence-dense prose' \
  --authority inferred \
  --status tentative \
  --domain writing)"
compiled_writing="$(qcc compile --json --domain writing --role reviewer)"
assert_eq "inferred claim is tentative" "1" "$(jq --arg id "${inferred_id}" '[.tentative_claims[] | select(.id == $id)] | length' <<<"${compiled_writing}")"
assert_eq "inferred claim is not explicit advisory" "0" "$(jq --arg id "${inferred_id}" '[.advisory_claims[] | select(.id == $id)] | length' <<<"${compiled_writing}")"
compiled_coding="$(qcc compile --json --domain coding)"
assert_eq "domain-scoped claim does not leak" "0" "$(jq --arg id "${inferred_id}" '[.tentative_claims[] | select(.id == $id)] | length' <<<"${compiled_coding}")"

printf 'Test 5a: compile scope matching never promotes a narrow blocker to global\n'
scoped_blocker="$(qcc add-claim \
  --statement 'Preserve a stable CLI migration path for maintainers' \
  --polarity must \
  --enforcement blocking \
  --domain coding \
  --task-type implementation \
  --surface cli \
  --audience maintainer \
  --path bundle)"
domain_only_compile="$(qcc compile --json --domain coding)"
assert_eq "domain-only router input defers narrower blocker" "0" "$(jq --arg id "${scoped_blocker}" '[.blocking_claims[] | select(.id == $id)] | length' <<<"${domain_only_compile}")"
assert_eq "scope deferral is explicit in JSON" "true" "$(jq '.omitted.scope_filtered_claims >= 1' <<<"${domain_only_compile}")"
partial_scope_compile="$(qcc compile --json --domain coding --task-type implementation --surface cli)"
assert_eq "partial selectors still defer blocker" "0" "$(jq --arg id "${scoped_blocker}" '[.blocking_claims[] | select(.id == $id)] | length' <<<"${partial_scope_compile}")"
matching_scope_compile="$(qcc compile --json \
  --domain coding \
  --task-type implementation \
  --surface cli \
  --audience maintainer \
  --path bundle/dot-claude/skills/autowork)"
assert_eq "all matching selectors admit blocker" "1" "$(jq --arg id "${scoped_blocker}" '[.blocking_claims[] | select(.id == $id)] | length' <<<"${matching_scope_compile}")"
assert_eq "path descendants match their scoped ancestor" "bundle/dot-claude/skills/autowork" "$(jq -r '.selectors.path' <<<"${matching_scope_compile}")"
wrong_path_compile="$(qcc compile --json \
  --domain coding \
  --task-type implementation \
  --surface cli \
  --audience maintainer \
  --path docs)"
assert_eq "wrong path excludes narrow blocker" "0" "$(jq --arg id "${scoped_blocker}" '[.blocking_claims[] | select(.id == $id)] | length' <<<"${wrong_path_compile}")"

printf 'Test 6: learned proposal requires an exact quote from the live user prompt\n'
sid="quality-constitution-session-001"
user_prompt='I prefer concise evidence, but do not hide the reasoning. token=sk-ant-abcdefghijklmnop1234567890'
write_session_state "${sid}" "${user_prompt}" "Improve the project output"
set +e
forged_out="$(SESSION_ID="${sid}" qcc propose \
  --statement 'Prefer unsupported style' \
  --quote 'the user never said this' \
  --signal correction 2>&1)"
forged_rc=$?
set -e
if (( forged_rc != 0 )); then ok "forged quote rejected"; else not_ok "forged quote accepted"; fi
assert_contains "forged quote failure is explicit" "not an exact substring" "${forged_out}"

candidate_id="$(SESSION_ID="${sid}" qcc propose \
  --statement 'Prefer concise, evidence-dense reasoning' \
  --quote 'I prefer concise evidence, but do not hide the reasoning. token=sk-ant-abcdefghijklmnop1234567890' \
  --signal correction \
  --category voice \
  --concept-key voice:evidence-dense-concision)"
assert_prefix "candidate id has canonical prefix" "qk_" "${candidate_id}"
profile_dir="$(dirname "${profile_path}")"
evidence_file="${profile_dir}/evidence.jsonl"
candidates_file="${profile_dir}/candidates.json"
assert_eq "one evidence row recorded" "1" "$(wc -l < "${evidence_file}" | tr -d '[:space:]')"
evidence_excerpt="$(jq -r '.excerpt' "${evidence_file}")"
assert_contains "evidence excerpt retains user meaning" "do not hide the reasoning" "${evidence_excerpt}"
assert_contains "evidence excerpt redacts provider key" "<redacted-secret>" "${evidence_excerpt}"
assert_not_contains "raw provider key absent" "sk-ant-abcdefghijklmnop1234567890" "${evidence_excerpt}"
assert_eq "candidate starts inferred" "inferred" "$(jq -r --arg id "${candidate_id}" '.items[] | select(.id == $id) | .claim.authority' "${candidates_file}")"
assert_eq "candidate starts non-blocking" "advisory" "$(jq -r --arg id "${candidate_id}" '.items[] | select(.id == $id) | .claim.enforcement' "${candidates_file}")"

printf 'Test 6a: taste_learning=off suppresses automatic proposals without mutation\n'
evidence_before_off="$(wc -l < "${evidence_file}" | tr -d '[:space:]')"
set +e
off_out="$(qcc_taste off propose \
  --session-id "${sid}" \
  --statement 'This proposal must remain disabled' \
  --quote 'I prefer concise evidence' 2>&1)"
off_rc=$?
set -e
assert_eq "disabled proposal is a non-failing no-op" "0" "${off_rc}"
assert_contains "disabled proposal explains suppression" "taste_learning=off" "${off_out}"
assert_eq "disabled proposal records no evidence" "${evidence_before_off}" "$(wc -l < "${evidence_file}" | tr -d '[:space:]')"

printf 'Test 6b: adaptive learning requires repeated independent evidence and never blocks\n'
adaptive_sid_one="quality-constitution-adaptive-001"
adaptive_sid_two="quality-constitution-adaptive-002"
adaptive_prompt='Make the interface feel hand-crafted, not assembled from defaults.'
write_session_state "${adaptive_sid_one}" "${adaptive_prompt}" "Polish the onboarding screen"
adaptive_candidate="$(qcc_taste adaptive propose \
  --session-id "${adaptive_sid_one}" \
  --statement 'Prefer hand-crafted interface choices over generic defaults' \
  --quote 'hand-crafted, not assembled from defaults' \
  --signal correction \
  --category signature \
  --concept-key 'visual:hand-crafted-not-generic')"
adaptive_score_one="$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .score' "${candidates_file}")"
assert_eq "one adaptive signal remains pending" "pending" "$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"

same_session_candidate="$(qcc_taste adaptive propose \
  --session-id "${adaptive_sid_one}" \
  --statement 'Prefer hand-crafted interface choices over generic defaults' \
  --quote 'hand-crafted, not assembled from defaults' \
  --signal correction \
  --category signature \
  --concept-key 'VISUAL:HAND-CRAFTED-NOT-GENERIC')"
assert_eq "same concept aggregates case-insensitively" "${adaptive_candidate}" "${same_session_candidate}"
assert_eq "same-session repetition cannot inflate confidence" "${adaptive_score_one}" "$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .score' "${candidates_file}")"
assert_eq "same-session repetition remains pending" "pending" "$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"

write_session_state "${adaptive_sid_two}" "${adaptive_prompt}" "Redesign the project dashboard"
independent_candidate="$(qcc_taste adaptive propose \
  --session-id "${adaptive_sid_two}" \
  --statement 'Prefer hand-crafted interface choices over generic defaults' \
  --quote 'hand-crafted, not assembled from defaults' \
  --signal correction \
  --category signature \
  --concept-key 'visual:hand-crafted-not-generic')"
assert_eq "independent evidence strengthens one candidate" "${adaptive_candidate}" "${independent_candidate}"
assert_eq "threshold-clearing candidate activates" "activated" "$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"
adaptive_claim="$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .activated_claim_id' "${candidates_file}")"
shown="$(qcc show --json)"
assert_eq "adaptive claim remains inferred" "inferred" "$(jq -r --arg id "${adaptive_claim}" '.claims[] | select(.id == $id) | .authority' <<<"${shown}")"
assert_eq "adaptive claim is advisory only" "advisory" "$(jq -r --arg id "${adaptive_claim}" '.claims[] | select(.id == $id) | .enforcement' <<<"${shown}")"
assert_eq "adaptive claim enters tentative compiled context" "1" "$(qcc compile --json | jq --arg id "${adaptive_claim}" '[.tentative_claims[] | select(.id == $id)] | length')"

adaptive_sid_three="quality-constitution-adaptive-003"
write_session_state "${adaptive_sid_three}" "${adaptive_prompt}" "Refine the account settings experience"
supported_candidate="$(qcc_taste adaptive propose \
  --session-id "${adaptive_sid_three}" \
  --statement 'Prefer hand-crafted interface choices over generic defaults' \
  --quote 'hand-crafted, not assembled from defaults' \
  --signal selection \
  --category principle \
  --concept-key 'visual:hand-crafted-not-generic')"
assert_eq "later support updates the activated candidate" "${adaptive_candidate}" "${supported_candidate}"
assert_eq "later support does not duplicate the adaptive claim" "1" "$(qcc show --json | jq --arg cid "${adaptive_candidate}" '[.claims[] | select(.source_candidate_id == $cid)] | length')"
assert_eq "independent support advances the evidence count" "3" "$(jq -r --arg id "${adaptive_candidate}" '.items[] | select(.id == $id) | .distinct_sessions' "${candidates_file}")"

adaptive_negative_prompt='Avoid the hand-crafted treatment here; use a generic default instead.'
adaptive_negative_sid_one="quality-constitution-adaptive-negative-001"
adaptive_negative_sid_two="quality-constitution-adaptive-negative-002"
write_session_state "${adaptive_negative_sid_one}" "${adaptive_negative_prompt}" "Reconsider the onboarding visual language"
negative_candidate="$(qcc_taste adaptive propose \
  --session-id "${adaptive_negative_sid_one}" \
  --statement 'Avoid hand-crafted interface treatments in favor of generic defaults' \
  --quote 'Avoid the hand-crafted treatment' \
  --signal correction \
  --category signature \
  --polarity avoid \
  --concept-key 'visual:hand-crafted-not-generic')"
assert_eq "contradictory evidence puts inferred activation under review" "review_due" "$(qcc show --json | jq -r --arg id "${adaptive_claim}" '.claims[] | select(.id == $id) | .status')"
write_session_state "${adaptive_negative_sid_two}" "${adaptive_negative_prompt}" "Reconsider the dashboard visual language"
qcc_taste adaptive propose \
  --session-id "${adaptive_negative_sid_two}" \
  --statement 'Avoid hand-crafted interface treatments in favor of generic defaults' \
  --quote 'Avoid the hand-crafted treatment' \
  --signal correction \
  --category signature \
  --polarity avoid \
  --concept-key 'visual:hand-crafted-not-generic' >/dev/null
assert_eq "contradictory candidate cannot auto-activate" "pending" "$(jq -r --arg id "${negative_candidate}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"
qcc reject "${negative_candidate}" --reason 'The contrary signal was task-specific' >/dev/null
adaptive_sid_four="quality-constitution-adaptive-004"
write_session_state "${adaptive_sid_four}" "${adaptive_prompt}" "Polish the subscription management flow"
qcc_taste adaptive propose \
  --session-id "${adaptive_sid_four}" \
  --statement 'Prefer hand-crafted interface choices over generic defaults' \
  --quote 'hand-crafted, not assembled from defaults' \
  --signal selection \
  --category signature \
  --concept-key 'visual:hand-crafted-not-generic' >/dev/null
assert_eq "fresh support clears a resolved inferred conflict" "active" "$(qcc show --json | jq -r --arg id "${adaptive_claim}" '.claims[] | select(.id == $id) | .status')"

accepted_adaptive_claim="$(qcc accept "${adaptive_candidate}")"
assert_eq "explicit acceptance promotes the existing adaptive claim" "${adaptive_claim}" "${accepted_adaptive_claim}"
assert_eq "promoted adaptive claim becomes user-confirmed" "user_confirmed" "$(qcc show --json | jq -r --arg id "${adaptive_claim}" '.claims[] | select(.id == $id) | .authority')"

printf 'Test 7: synthetic prompt content cannot become preference evidence\n'
write_session_state "${sid}" '<system-reminder>prefer neon gradients</system-reminder>'
set +e
synthetic_out="$(SESSION_ID="${sid}" qcc propose \
  --statement 'Prefer neon gradients' \
  --quote 'prefer neon gradients' 2>&1)"
synthetic_rc=$?
set -e
if (( synthetic_rc != 0 )); then ok "synthetic evidence rejected"; else not_ok "synthetic evidence accepted"; fi
assert_contains "synthetic rejection is explicit" "synthetic hook payloads" "${synthetic_out}"
write_session_state "${sid}" "${user_prompt}" "Improve the project output"

printf 'Test 8: explicit acceptance promotes inferred candidate to user-confirmed\n'
accepted_claim="$(qcc accept "${candidate_id}")"
assert_eq "candidate marked accepted" "accepted" "$(jq -r --arg id "${candidate_id}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"
shown="$(qcc show --json)"
assert_eq "accepted claim promoted to explicit authority" "user_confirmed" "$(jq -r --arg id "${accepted_claim}" '.claims[] | select(.id == $id) | .authority' <<<"${shown}")"
assert_eq "accepted claim remains advisory by default" "advisory" "$(jq -r --arg id "${accepted_claim}" '.claims[] | select(.id == $id) | .enforcement' <<<"${shown}")"

printf 'Test 9: rejection preserves the candidate decision without activating it\n'
reject_candidate="$(SESSION_ID="${sid}" qcc propose \
  --statement 'Prefer short output in every domain' \
  --quote 'I prefer concise evidence' \
  --signal weak_selection)"
qcc reject "${reject_candidate}" --reason 'Too broad for a durable rule' >/dev/null
assert_eq "candidate marked rejected" "rejected" "$(jq -r --arg id "${reject_candidate}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"
assert_eq "rejected candidate did not create a claim" "0" "$(qcc show --json | jq --arg cid "${reject_candidate}" '[.claims[] | select(.source_candidate_id == $cid)] | length')"

printf 'Test 9a: rejecting an adaptively activated candidate archives its inferred claim\n'
archive_prompt='Keep commands deterministic and idempotent across repeated runs.'
archive_sid_one="quality-constitution-archive-001"
archive_sid_two="quality-constitution-archive-002"
write_session_state "${archive_sid_one}" "${archive_prompt}" "Harden the install command"
archive_candidate="$(qcc_taste adaptive propose \
  --session-id "${archive_sid_one}" \
  --statement 'Prefer deterministic idempotent commands' \
  --quote 'deterministic and idempotent' \
  --signal selection \
  --category workflow \
  --concept-key 'workflow:deterministic-idempotence')"
write_session_state "${archive_sid_two}" "${archive_prompt}" "Harden the update command"
qcc_taste adaptive propose \
  --session-id "${archive_sid_two}" \
  --statement 'Prefer deterministic idempotent commands' \
  --quote 'deterministic and idempotent' \
  --signal selection \
  --category workflow \
  --concept-key 'workflow:deterministic-idempotence' >/dev/null
archive_claim="$(jq -r --arg id "${archive_candidate}" '.items[] | select(.id == $id) | .activated_claim_id' "${candidates_file}")"
qcc reject "${archive_candidate}" --reason 'Do not retain this as project-wide taste' >/dev/null
assert_eq "activated candidate records rejection" "rejected" "$(jq -r --arg id "${archive_candidate}" '.items[] | select(.id == $id) | .status' "${candidates_file}")"
assert_eq "rejected adaptive claim is archived" "archived" "$(qcc show --json | jq -r --arg id "${archive_claim}" '.claims[] | select(.id == $id) | .status')"

printf 'Test 10: repository and URL reference safety\n'
reference_id="$(qcc add-reference \
  --kind repo_path \
  --locator example.md \
  --polarity exemplar \
  --because 'Compact while retaining the argument' \
  --aspects 'clarity,information density' \
  --do-not-copy 'Typography')"
assert_prefix "reference id has canonical prefix" "qr_" "${reference_id}"
assert_nonempty "repo reference records content digest" "$(qcc show --json | jq -r --arg id "${reference_id}" '.references[] | select(.id == $id) | .content_digest')"

set +e
traversal_out="$(qcc add-reference --kind repo_path --locator ../outside.txt --because unsafe 2>&1)"
traversal_rc=$?
symlink_out="$(qcc add-reference --kind repo_path --locator outside-link.md --because unsafe 2>&1)"
symlink_rc=$?
symlink_hop_out="$(qcc add-reference --kind repo_path --locator outside-link-hop.md --because unsafe 2>&1)"
symlink_hop_rc=$?
credential_out="$(qcc add-reference --kind url --locator 'https://user:pass@example.com/reference' --because unsafe 2>&1)"
credential_rc=$?
set -e
if (( traversal_rc != 0 )); then ok "path traversal rejected"; else not_ok "path traversal accepted"; fi
if (( symlink_rc != 0 )); then ok "outside symlink rejected"; else not_ok "outside symlink accepted"; fi
if (( symlink_hop_rc != 0 )); then ok "multi-hop outside symlink rejected"; else not_ok "multi-hop outside symlink accepted"; fi
if (( credential_rc != 0 )); then ok "credential-bearing URL rejected"; else not_ok "credential-bearing URL accepted"; fi
assert_contains "traversal error is actionable" "unsafe or unavailable" "${traversal_out}"
assert_contains "symlink error is actionable" "unsafe or unavailable" "${symlink_out}"
assert_contains "multi-hop symlink error is actionable" "unsafe or unavailable" "${symlink_hop_out}"
assert_contains "URL error is actionable" "credential-free https" "${credential_out}"

url_reference="$(qcc add-reference \
  --kind url \
  --locator 'https://example.com/reference' \
  --polarity anti_exemplar \
  --because 'Generic visual defaults without a point of view')"
assert_eq "safe URL stored unchanged" "https://example.com/reference" "$(qcc show --json | jq -r --arg id "${url_reference}" '.references[] | select(.id == $id) | .locator')"
printf 'Changed reference artifact.\n' > "${PROJECT}/example.md"
drift_audit="$(qcc audit --json)"
assert_eq "changed exemplar is reported as drifted" "1" "$(jq '[.warnings[] | select(.code == "reference-drift")] | length' <<<"${drift_audit}")"
printf 'A compact reference artifact.\n' > "${PROJECT}/example.md"

printf 'Test 11: remove archives rather than erasing authority history\n'
digest_before_remove="$(qcc digest)"
qcc remove "${claim_id}" --reason 'Superseded by a sharper vision' >/dev/null
shown="$(qcc show --json)"
assert_eq "removed claim archived" "archived" "$(jq -r --arg id "${claim_id}" '.claims[] | select(.id == $id) | .status' <<<"${shown}")"
compiled_after_remove="$(qcc compile --json)"
assert_eq "archived claim omitted from compiled context" "0" "$(jq --arg id "${claim_id}" '[.blocking_claims[],.advisory_claims[],.tentative_claims[] | select(.id == $id)] | length' <<<"${compiled_after_remove}")"
digest_after_remove="$(qcc digest)"
if [[ "${digest_before_remove}" != "${digest_after_remove}" ]]; then ok "digest changes after mutation"; else not_ok "digest stayed stale"; fi

printf 'Test 12: compiled prose is bounded and preserves the five-axis contract\n'
compact_blocker_id="$(qcc add-claim \
  --statement 'Every shipped workflow must expose a reversible recovery path' \
  --category principle --polarity must --enforcement blocking \
  --authority user_confirmed)"
compiled_text="$(qcc compile --role planner --max-chars 512)"
if (( ${#compiled_text} <= 512 )); then ok "compiled context honors max chars"; else not_ok "compiled context exceeded max chars (${#compiled_text})"; fi
assert_contains "bounded context starts with constitution label" "QUALITY CONSTITUTION" "${compiled_text}"
assert_contains "bounded context preserves blocking claim ID" \
  "${compact_blocker_id}" "${compiled_text}"
for axis in deliberate distinctive coherent visionary complete; do
  assert_contains "bounded context preserves ${axis} axis" "${axis}" "${compiled_text}"
done

printf 'Test 13: ledgers and candidate set remain bounded\n'
for n in 1 2 3 4 5; do
  SESSION_ID="${sid}" qcc_env 3 3 5 propose \
    --statement "Preference candidate ${n}" \
    --quote 'I prefer concise evidence' \
    --signal praise \
    --concept-key "test:${n}" >/dev/null
done
evidence_count="$(wc -l < "${evidence_file}" | tr -d '[:space:]')"
candidate_count="$(jq '.items | length' "${candidates_file}")"
audit_count="$(wc -l < "${profile_dir}/audit.jsonl" | tr -d '[:space:]')"
if (( evidence_count <= 3 )); then ok "evidence ledger capped"; else not_ok "evidence ledger unbounded (${evidence_count})"; fi
if (( candidate_count <= 3 )); then ok "candidate set capped"; else not_ok "candidate set unbounded (${candidate_count})"; fi
if (( audit_count <= 5 )); then ok "audit ledger capped"; else not_ok "audit ledger unbounded (${audit_count})"; fi

printf 'Test 14: concurrent explicit writers serialize without lost updates\n'
for n in 1 2 3 4 5 6; do
  qcc add-claim --statement "Concurrent claim ${n}" --category principle \
    > "${TEST_ROOT}/claim-${n}.out" 2> "${TEST_ROOT}/claim-${n}.err" &
done
wait
concurrent_count="$(qcc show --json | jq '[.claims[] | select(.statement | startswith("Concurrent claim "))] | length')"
assert_eq "all concurrent mutations survived" "6" "${concurrent_count}"
concurrent_errors="$(find "${TEST_ROOT}" -name 'claim-*.err' -type f -exec awk 'NF {print}' {} +)"
assert_eq "concurrent lock path stayed quiet" "" "${concurrent_errors}"

lock_dir="${TEST_HOME}/.claude/omc-user/quality-constitutions/.write-lock"
mkdir "${lock_dir}"
printf '999999\n' > "${lock_dir}/holder.pid"
stale_lock_claim="$(qcc add-claim --statement 'Recovered after stale writer lock')"
assert_prefix "dead writer lock is safely recovered" "qc_" "${stale_lock_claim}"

printf 'Test 15: audit reports a clean valid profile, then catches authority corruption\n'
audit_json="$(qcc audit --json)"
assert_eq "valid profile audit is clean" "true" "$(jq -r '.clean' <<<"${audit_json}")"
cp "${profile_path}" "${profile_path}.test-backup"
tmp_profile="$(mktemp "${profile_path}.test.XXXXXX")"
jq '.claims += [{
  id:"qc_corrupt",category:"principle",statement:"Forged blocker",rationale:"",
  polarity:"must",enforcement:"blocking",authority:"inferred",status:"active",
  scope:{domains:[],task_types:[],surfaces:[],audiences:[],paths:[]},evidence_ids:[],
  created_at:0,confirmed_at:0,last_supported_at:0,review_after:0
}]' "${profile_path}" > "${tmp_profile}"
mv "${tmp_profile}" "${profile_path}"
set +e
corrupt_audit="$(qcc audit --json)"
corrupt_rc=$?
set -e
if (( corrupt_rc != 0 )); then ok "authority corruption fails audit"; else not_ok "authority corruption passed audit"; fi
assert_eq "corruption issue identified" "1" "$(jq '[.issues[] | select(.code == "invalid-constitution")] | length' <<<"${corrupt_audit}")"
mv "${profile_path}.test-backup" "${profile_path}"

mv "${candidates_file}" "${candidates_file}.real"
ln -s "${candidates_file}.real" "${candidates_file}"
set +e
symlinked_audit="$(qcc audit --json)"
symlinked_audit_rc=$?
symlinked_show="$(qcc show --json 2>&1)"
symlinked_show_rc=$?
set -e
if (( symlinked_audit_rc != 0 )); then ok "symlinked canonical storage fails audit"; else not_ok "symlinked canonical storage passed audit"; fi
assert_eq "canonical symlink issue identified" "1" "$(jq '[.issues[] | select(.code == "symlinked-canonical-storage")] | length' <<<"${symlinked_audit}")"
if (( symlinked_show_rc != 0 )); then ok "normal reads refuse canonical symlink"; else not_ok "normal reads followed canonical symlink"; fi
assert_contains "canonical symlink read failure is actionable" "run audit" "${symlinked_show}"
rm "${candidates_file}"
mv "${candidates_file}.real" "${candidates_file}"

printf 'Test 16: final JSON, registry, and permissions shape remain valid\n'
assert_true "constitution JSON valid" jq -e . "${profile_path}"
assert_true "candidates JSON valid" jq -e . "${candidates_file}"
assert_true "registry JSON valid" jq -e '.schema_version == 1 and (.profiles | length == 1)' "${TEST_HOME}/.claude/omc-user/quality-constitutions/registry.json"
assert_eq "final audit clean" "true" "$(qcc audit --json | jq -r '.clean')"

printf '\n=== Quality Constitution Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
