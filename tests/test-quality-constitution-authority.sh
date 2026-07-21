#!/usr/bin/env bash
# Causal-authority, compile-snapshot, and bypass regressions for the
# user-owned Quality Constitution.
# shellcheck disable=SC2016  # Adversarial command strings must remain literal.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd -P)"
HELPER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/quality-constitution.sh"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
AUTH_LIB="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-constitution-authority.sh"
GUARD="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/quality-constitution-authority-guard.sh"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
PRECOMPACT="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/pre-compact-snapshot.sh"
COMPACT_HANDOFF="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-compact-handoff.sh"
RESUME_HANDOFF="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-resume-handoff.sh"

TEST_ROOT="$(mktemp -d -t quality-constitution-authority-XXXXXX)"
TEST_HOME="${TEST_ROOT}/home"
STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
PROJECT="${TEST_ROOT}/project"
OTHER_PROJECT="${TEST_ROOT}/other-project"
mkdir -p "${STATE_ROOT}" "${PROJECT}" "${OTHER_PROJECT}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${TEST_HOME}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${TEST_HOME}/.claude/quality-pack/memory"
git -C "${PROJECT}" init -q
git -C "${OTHER_PROJECT}" init -q
printf 'Original exemplar bytes.\n' >"${PROJECT}/exemplar.md"
printf 'Quoted exemplar bytes.\n' >"${PROJECT}/exemplar file.md"
trap 'rm -rf "${TEST_ROOT}"' EXIT

pass=0
fail=0

ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
not_ok() { printf '  FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then ok "${label}"; else
    not_ok "${label} (expected=${expected} actual=${actual})"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then ok "${label}"; else
    not_ok "${label} (missing=${needle})"
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then ok "${label}"; else
    not_ok "${label} (still present=${path})"
  fi
}

write_marker_as_raw_nul() {
  local source="$1" target="$2" marker="$3" content=""
  content="$(<"${source}")"
  [[ "${content}" == *"${marker}"* ]] || return 1
  {
    printf '%s' "${content%%"${marker}"*}"
    printf '\000'
    printf '%s\n' "${content#*"${marker}"}"
  } >"${target}"
}

run_router() {
  local sid="$1" prompt="$2"
  shift 2
  local payload
  payload="$(jq -nc --arg sid "${sid}" --arg prompt "${prompt}" --arg cwd "${PROJECT}" \
    '{session_id:$sid,prompt:$prompt,cwd:$cwd}')"
  (
    cd "${PROJECT}"
    env HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
      OMC_QUALITY_CONSTITUTION=off "$@" bash "${ROUTER}" <<<"${payload}"
  )
}

router_context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"
}

grant_path() { printf '%s/%s/quality_constitution_authorization.json' "${STATE_ROOT}" "$1"; }

grant_id() { jq -r '.grant_id' "$(grant_path "$1")"; }

operation_b64() {
  local context="$1"
  printf '%s\n' "${context}" | sed -n 's/.*--operation-b64 "\([A-Za-z0-9+\/=]*\)".*/\1/p' | head -1
}

apply_authorized() {
  local project="$1" sid="$2" grant="$3" encoded="$4"
  (
    cd "${project}"
    HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
      bash "${HELPER}" apply-authorized \
        --session-id "${sid}" --grant "${grant}" --operation-b64 "${encoded}"
  )
}

apply_authorized_fault() {
  local project="$1" sid="$2" grant="$3" encoded="$4" point="$5"
  (
    cd "${project}"
    HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
      OMC_QC_TEST_MODE=1 OMC_QC_TEST_FAULT="${point}" \
      bash "${HELPER}" apply-authorized \
        --session-id "${sid}" --grant "${grant}" --operation-b64 "${encoded}"
  )
}

compile_json() {
  (cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" compile --json)
}

show_json() {
  (cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" show --json)
}

parse_prompt() {
  local prompt="$1"
  (
    cd "${PROJECT}"
    HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" SESSION_ID="parser-session" \
      bash -c '. "$1"; . "$2"; qc_authority_operation_from_prompt "$3"' \
        bash "${COMMON}" "${AUTH_LIB}" "${prompt}"
  )
}

guard_bash() {
  local command="$1" cwd="${2:-${PROJECT}}" payload
  payload="$(jq -nc --arg command "${command}" --arg cwd "${cwd}" \
    '{session_id:"guard-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command}}')"
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" bash "${GUARD}" <<<"${payload}"
}

guard_payload() {
  local payload="$1"
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" bash "${GUARD}" <<<"${payload}"
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "${value}"
}

printf 'Test 1: advertised slash grammar is exact and complete\n'
assert_eq "remember is advisory prefer" "prefer/advisory" \
  "$(parse_prompt '/quality-constitution remember Keep it crisp' | jq -r '.arguments | .polarity + "/" + .enforcement')"
assert_eq "must is blocking must" "must/blocking" \
  "$(parse_prompt '/quality-constitution must Preserve rollback' | jq -r '.arguments | .polarity + "/" + .enforcement')"
assert_eq "must-not is blocking must_not" "must_not/blocking" \
  "$(parse_prompt '/quality-constitution must-not Hide verification failures' | jq -r '.arguments | .polarity + "/" + .enforcement')"
assert_eq "avoid is advisory avoid" "avoid/advisory" \
  "$(parse_prompt '/quality-constitution avoid Generic defaults' | jq -r '.arguments | .polarity + "/" + .enforcement')"
assert_eq "accept blocking grammar" "accept/blocking" \
  "$(parse_prompt '/quality-constitution accept qk_example blocking' | jq -r '.action + "/" + .arguments.enforcement')"
assert_eq "reject because grammar" "reject/Too narrow" \
  "$(parse_prompt '/quality-constitution reject qk_example because Too narrow' | jq -r '.action + "/" + .arguments.reason')"
assert_eq "reference recognizes current repo artifact" "add-reference/repo_path/exemplar" \
  "$(parse_prompt '/quality-constitution reference exemplar.md because Preserve causal density' | jq -r '.action + "/" + .arguments.kind + "/" + .arguments.polarity')"
assert_eq "quoted reference operands remain independently balanced" \
  "repo_path/exemplar file.md/Preserve causal density" \
  "$(parse_prompt '/quality-constitution reference "exemplar file.md" because "Preserve causal density"' | jq -r '.arguments | .kind + "/" + .locator + "/" + .because')"
assert_eq "anti-reference grammar" "add-reference/anti_exemplar" \
  "$(parse_prompt '/quality-constitution anti-reference Generic modal because It erases product voice' | jq -r '.action + "/" + .arguments.polarity')"
assert_eq "remove grammar" "remove/qc_example" \
  "$(parse_prompt '/quality-constitution remove qc_example because Superseded' | jq -r '.action + "/" + .arguments.id')"

set +e
sha_required_out="$(PATH=/nonexistent /bin/bash -c \
  '. "$1"; _OMC_OBSERVER_SAFE_PATH=/nonexistent; printf x | qc_authority_hash_text' \
  bash "${AUTH_LIB}" 2>&1)"
sha_required_rc=$?
set -e
if (( sha_required_rc != 0 )); then ok "authority identity fails closed without SHA-256"; else not_ok "authority identity fell back to a weak checksum"; fi
assert_contains "missing SHA-256 failure is explicit" "SHA-256 is required" "${sha_required_out}"
authority_hash_expected="$(HOME="${TEST_HOME}" bash -c '
  . "$1"
  _verification_sha256_text authority-material
' bash "${COMMON}")"
authority_hash_actual="$(HOME="${TEST_HOME}" bash -c '
  . "$1"
  . "$2"
  printf %s authority-material | qc_authority_hash_text
' bash "${COMMON}" "${AUTH_LIB}")"
assert_eq "authority protocol delegates to common trusted SHA primitive" \
  "${authority_hash_expected}" "${authority_hash_actual}"
authority_hash_env="${TEST_ROOT}/authority-forged-hash-env.sh"
cat >"${authority_hash_env}" <<'AUTHORITY_HASH_ENV'
shasum() { printf '%064d  -\n' 0; }
sha256sum() { printf '%064d  -\n' 0; }
_verification_sha256_text() { printf '%064d' 0; }
export -f shasum sha256sum _verification_sha256_text
AUTHORITY_HASH_ENV
authority_hash_forged_actual="$(HOME="${TEST_HOME}" \
  BASH_ENV="${authority_hash_env}" bash -c '
    . "$1"
    . "$2"
    printf %s authority-material | qc_authority_hash_text
  ' bash "${COMMON}" "${AUTH_LIB}")"
assert_eq "authority protocol ignores inherited SHA helper/functions" \
  "${authority_hash_expected}" "${authority_hash_forged_actual}"

printf 'Test 2: router mints one exact current-prompt grant without raw prompt text\n'
SID="authority-main"
statement='Preserve migration reversibility'
router_out="$(run_router "${SID}" "/quality-constitution must ${statement}")"
context="$(router_context "${router_out}")"
grant_file="$(grant_path "${SID}")"
if [[ -f "${grant_file}" && ! -L "${grant_file}" ]]; then ok "regular grant sidecar created"; else not_ok "grant sidecar missing"; fi
assert_eq "grant mode is owner-only" "600" "$(stat -c '%a' "${grant_file}" 2>/dev/null || stat -f '%Lp' "${grant_file}")"
assert_eq "grant stores no raw statement" "0" "$(grep -F -c "${statement}" "${grant_file}" || true)"
assert_eq "grant binds prompt revision" "1" "$(jq -r '.prompt_revision' "${grant_file}")"
assert_contains "directive freezes literal session id" "--session-id \"${SID}\"" "${context}"
if [[ "${context}" != *'$CLAUDE_SESSION_ID'* ]]; then ok "directive does not depend on unsettable session env"; else not_ok "directive uses session env"; fi
GRANT="$(grant_id "${SID}")"
ENCODED="$(operation_b64 "${context}")"
if [[ -n "${ENCODED}" ]]; then ok "router emitted immutable encoded operation"; else not_ok "missing encoded operation"; fi

claim_id="$(apply_authorized "${PROJECT}" "${SID}" "${GRANT}" "${ENCODED}")"
assert_file_absent "successful apply consumes grant first" "${grant_file}"
shown="$(show_json)"
assert_eq "authorized claim persisted exactly once" "1" \
  "$(jq --arg statement "${statement}" '[.claims[] | select(.statement == $statement and .enforcement == "blocking" and .authority == "user_confirmed")] | length' <<<"${shown}")"
constitution_path="$(cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" resolve --json | jq -r '.path')"
audit_file="${constitution_path%/constitution.json}/audit.jsonl"
if HOME="${TEST_HOME}" bash -c \
    '. "$1"; . "$2"; qc_constitution_is_valid "$3" 500 200' \
    bash "${COMMON}" "${AUTH_LIB}" "${constitution_path}"; then
  ok "shared side-effect-free Constitution validator accepts canonical profile"
else
  not_ok "shared Constitution validator rejected canonical profile"
fi
cp "${constitution_path}" "${constitution_path}.profile-id-backup"
jq '.profile_id += "\u0000"' "${constitution_path}" \
  >"${constitution_path}.tmp"
mv "${constitution_path}.tmp" "${constitution_path}"
if HOME="${TEST_HOME}" bash -c \
    '. "$1"; . "$2"; ! qc_constitution_is_valid "$3" 500 200' \
    bash "${COMMON}" "${AUTH_LIB}" "${constitution_path}"; then
  ok "shared validator rejects NUL-tailed profile identity"
else
  not_ok "shared validator normalized NUL-tailed profile identity"
fi
mv "${constitution_path}.profile-id-backup" "${constitution_path}"
cp "${constitution_path}" "${constitution_path}.raw-nul-backup"
jq -c '.generation = "__RAW_NUL__"' "${constitution_path}" \
  >"${constitution_path}.raw-nul-marked"
write_marker_as_raw_nul \
  "${constitution_path}.raw-nul-marked" "${constitution_path}" \
  '"__RAW_NUL__"'
rm -f "${constitution_path}.raw-nul-marked"
if HOME="${TEST_HOME}" bash -c \
    '. "$1"; . "$2"; ! qc_constitution_is_valid "$3" 500 200' \
    bash "${COMMON}" "${AUTH_LIB}" "${constitution_path}"; then
  ok "shared validator rejects raw-NUL Constitution bytes before jq"
else
  not_ok "shared validator normalized raw-NUL Constitution generation"
fi
mv "${constitution_path}.raw-nul-backup" "${constitution_path}"
assert_eq "audit records causal grant id" "${GRANT}" "$(tail -1 "${audit_file}" | jq -r '.authority_grant_id')"
assert_eq "audit records prompt revision" "1" "$(tail -1 "${audit_file}" | jq -r '.authority_prompt_revision')"

printf 'Test 3: replay, substitution, project mismatch, and concurrent double-spend fail closed\n'
generation_before="$(jq -r '.generation' <<<"${shown}")"
set +e
replay_out="$(apply_authorized "${PROJECT}" "${SID}" "${GRANT}" "${ENCODED}" 2>&1)"
replay_rc=$?
set -e
if (( replay_rc != 0 )); then ok "spent grant cannot replay"; else not_ok "spent grant replayed"; fi
assert_contains "replay failure names authorization" "authorization" "${replay_out}"
assert_eq "replay cannot advance generation" "${generation_before}" "$(show_json | jq -r '.generation')"

router_out="$(run_router "${SID}" '/quality-constitution avoid Generic default chrome')"
context="$(router_context "${router_out}")"
GRANT="$(grant_id "${SID}")"
ENCODED="$(operation_b64 "${context}")"
decoded="$(printf '%s' "${ENCODED}" | (base64 --decode 2>/dev/null || base64 -D))"
wrong="$(jq -cS '.arguments.statement = "Different durable claim"' <<<"${decoded}")"
wrong_b64="$(printf '%s' "${wrong}" | base64 | tr -d '\r\n')"
set +e
wrong_out="$(apply_authorized "${PROJECT}" "${SID}" "${GRANT}" "${wrong_b64}" 2>&1)"
wrong_rc=$?
set -e
if (( wrong_rc != 0 )); then ok "operation substitution rejected"; else not_ok "operation substitution accepted"; fi
if [[ -f "$(grant_path "${SID}")" ]]; then ok "mismatch does not consume the exact grant"; else not_ok "mismatch consumed grant"; fi
set +e
project_out="$(apply_authorized "${OTHER_PROJECT}" "${SID}" "${GRANT}" "${ENCODED}" 2>&1)"
project_rc=$?
set -e
if (( project_rc != 0 )); then ok "grant is project-bound"; else not_ok "grant crossed projects"; fi
apply_authorized "${PROJECT}" "${SID}" "${GRANT}" "${ENCODED}" >/dev/null

router_out="$(run_router "${SID}" '/quality-constitution must Ship the concurrency invariant once')"
context="$(router_context "${router_out}")"
GRANT="$(grant_id "${SID}")"
ENCODED="$(operation_b64 "${context}")"
for worker in 1 2; do
  (
    set +e
    apply_authorized "${PROJECT}" "${SID}" "${GRANT}" "${ENCODED}" \
      >"${TEST_ROOT}/worker-${worker}.out" 2>"${TEST_ROOT}/worker-${worker}.err"
    printf '%s\n' "$?" >"${TEST_ROOT}/worker-${worker}.rc"
    exit 0
  ) &
done
wait
successes=0
for worker in 1 2; do
  [[ "$(<"${TEST_ROOT}/worker-${worker}.rc")" == "0" ]] && successes=$((successes + 1))
done
assert_eq "only one concurrent consumer succeeds" "1" "${successes}"
assert_eq "double-spend creates one claim" "1" \
  "$(show_json | jq '[.claims[] | select(.statement == "Ship the concurrency invariant once")] | length')"

printf 'Test 3a: operation and grant byte boundaries reject NUL/control normalization\n'
BOUNDARY_SID="authority-byte-boundary"
boundary_statement='Preserve exact authority bytes'
router_out="$(run_router "${BOUNDARY_SID}" \
  "/quality-constitution must ${boundary_statement}")"
context="$(router_context "${router_out}")"
BOUNDARY_GRANT="$(grant_id "${BOUNDARY_SID}")"
BOUNDARY_B64="$(operation_b64 "${context}")"
boundary_grant_file="$(grant_path "${BOUNDARY_SID}")"
boundary_operation="$(printf '%s' "${BOUNDARY_B64}" \
  | (base64 --decode 2>/dev/null || base64 -D))"
boundary_generation="$(show_json | jq -r '.generation')"

escaped_nul_operation="$(jq -cS \
  '.arguments.statement += "\u0000"' <<<"${boundary_operation}")"
escaped_nul_b64="$(printf '%s' "${escaped_nul_operation}" \
  | base64 | tr -d '\r\n')"
set +e
escaped_operation_out="$(apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${escaped_nul_b64}" 2>&1)"
escaped_operation_rc=$?
set -e
if (( escaped_operation_rc != 0 )); then
  ok "escaped-NUL operation string is rejected"
else
  not_ok "escaped-NUL operation string was accepted"
fi
assert_contains "escaped-NUL operation rejection names the operation" \
  "authorized operation" "${escaped_operation_out}"
if [[ -f "${boundary_grant_file}" ]]; then
  ok "escaped-NUL operation leaves the exact grant unspent"
else
  not_ok "escaped-NUL operation consumed the exact grant"
fi
assert_eq "escaped-NUL operation cannot mutate the profile" \
  "${boundary_generation}" "$(show_json | jq -r '.generation')"

control_operation="$(jq -cS \
  '.arguments.statement += "\u001f"' <<<"${boundary_operation}")"
control_b64="$(printf '%s' "${control_operation}" | base64 | tr -d '\r\n')"
set +e
apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${control_b64}" >/dev/null 2>&1
control_operation_rc=$?
set -e
if (( control_operation_rc != 0 )); then
  ok "escaped control-bearing operation string is rejected"
else
  not_ok "escaped control-bearing operation string was accepted"
fi
if [[ -f "${boundary_grant_file}" ]]; then
  ok "control-bearing operation leaves the exact grant unspent"
else
  not_ok "control-bearing operation consumed the exact grant"
fi

raw_operation_marker="$(jq -cS \
  '.arguments.statement += "__RAW_NUL__"' <<<"${boundary_operation}")"
raw_operation_file="${TEST_ROOT}/raw-nul-operation.json"
printf '%s' "${raw_operation_marker%%__RAW_NUL__*}" >"${raw_operation_file}"
printf '\000' >>"${raw_operation_file}"
printf '%s' "${raw_operation_marker#*__RAW_NUL__}" >>"${raw_operation_file}"
raw_nul_b64="$(base64 <"${raw_operation_file}" | tr -d '\r\n')"
set +e
apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${raw_nul_b64}" >/dev/null 2>&1
raw_operation_rc=$?
set -e
if (( raw_operation_rc != 0 )); then
  ok "raw-NUL operation bytes are rejected before Bash import"
else
  not_ok "raw-NUL operation bytes normalized into an accepted operation"
fi
if [[ -f "${boundary_grant_file}" ]]; then
  ok "raw-NUL operation leaves the exact grant unspent"
else
  not_ok "raw-NUL operation consumed the exact grant"
fi
assert_eq "raw-NUL operation cannot mutate the profile" \
  "${boundary_generation}" "$(show_json | jq -r '.generation')"

boundary_grant_backup="${TEST_ROOT}/authority-byte-boundary-grant.json"
cp "${boundary_grant_file}" "${boundary_grant_backup}"
jq -cS '.project_key += "\u0000"' \
  "${boundary_grant_backup}" >"${boundary_grant_file}"
set +e
apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${BOUNDARY_B64}" >/dev/null 2>&1
escaped_grant_rc=$?
set -e
if (( escaped_grant_rc != 0 )); then
  ok "escaped-NUL grant string is rejected before coordinate projection"
else
  not_ok "escaped-NUL grant string normalized into valid authority"
fi
if [[ -f "${boundary_grant_file}" ]]; then
  ok "escaped-NUL grant rejection preserves the sidecar"
else
  not_ok "escaped-NUL grant rejection consumed the sidecar"
fi
assert_eq "escaped-NUL grant cannot mutate the profile" \
  "${boundary_generation}" "$(show_json | jq -r '.generation')"

cp "${boundary_grant_backup}" "${boundary_grant_file}"
raw_grant_marker="$(jq -cS '.project_key += "__RAW_NUL__"' \
  "${boundary_grant_backup}")"
printf '%s' "${raw_grant_marker%%__RAW_NUL__*}" >"${boundary_grant_file}"
printf '\000' >>"${boundary_grant_file}"
printf '%s\n' "${raw_grant_marker#*__RAW_NUL__}" >>"${boundary_grant_file}"
set +e
apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${BOUNDARY_B64}" >/dev/null 2>&1
raw_grant_rc=$?
set -e
if (( raw_grant_rc != 0 )); then
  ok "raw-NUL grant bytes are rejected before Bash import"
else
  not_ok "raw-NUL grant bytes normalized into valid authority"
fi
if [[ -f "${boundary_grant_file}" ]]; then
  ok "raw-NUL grant rejection preserves the sidecar"
else
  not_ok "raw-NUL grant rejection consumed the sidecar"
fi
assert_eq "raw-NUL grant cannot mutate the profile" \
  "${boundary_generation}" "$(show_json | jq -r '.generation')"

cp "${boundary_grant_backup}" "${boundary_grant_file}"
awk 'BEGIN { for (i = 0; i < 4096; i++) printf " " }' \
  >>"${boundary_grant_file}"
set +e
apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${BOUNDARY_B64}" >/dev/null 2>&1
oversize_grant_rc=$?
set -e
if (( oversize_grant_rc != 0 )); then
  ok "oversize grant sidecar fails the byte cap closed"
else
  not_ok "oversize grant sidecar bypassed the byte cap"
fi
if [[ -f "${boundary_grant_file}" ]]; then
  ok "oversize grant rejection preserves the sidecar"
else
  not_ok "oversize grant rejection consumed the sidecar"
fi
assert_eq "oversize grant cannot mutate the profile" \
  "${boundary_generation}" "$(show_json | jq -r '.generation')"

cp "${boundary_grant_backup}" "${boundary_grant_file}"
apply_authorized "${PROJECT}" "${BOUNDARY_SID}" \
  "${BOUNDARY_GRANT}" "${BOUNDARY_B64}" >/dev/null
assert_file_absent "byte-exact clean retry consumes the restored grant" \
  "${boundary_grant_file}"
assert_eq "byte-exact clean retry applies exactly one mutation" \
  "$((boundary_generation + 1))" "$(show_json | jq -r '.generation')"

printf 'Test 3b: a consumed one-use grant is never recreated from a prepared journal\n'
JOURNAL_SID="authority-prepared-journal"
router_out="$(run_router "${JOURNAL_SID}" \
  "/quality-constitution remove ${claim_id} because Exercise prepared-only recovery")"
context="$(router_context "${router_out}")"
JOURNAL_GRANT="$(grant_id "${JOURNAL_SID}")"
JOURNAL_B64="$(operation_b64 "${context}")"
set +e
journal_fault_out="$(apply_authorized_fault \
  "${PROJECT}" "${JOURNAL_SID}" "${JOURNAL_GRANT}" "${JOURNAL_B64}" after_journal 2>&1)"
journal_fault_rc=$?
set -e
if (( journal_fault_rc != 0 )); then ok "prepared authorized mutation is interrupted"; else not_ok "prepared authorized mutation returned success"; fi
assert_contains "authorized fault identifies prepared boundary" "after_journal" "${journal_fault_out}"
assert_file_absent "prepared authorized fault still consumes one-use grant" "$(grant_path "${JOURNAL_SID}")"
operation_journal="${constitution_path%/constitution.json}/pending-operation.json"
prepared_operation_id="$(jq -r '.operation_id' "${operation_journal}")"
assert_eq "prepared authorized remove does not archive its claim" "active" \
  "$(show_json | jq -r --arg id "${claim_id}" '.claims[] | select(.id == $id) | .status')"

router_out="$(run_router "${JOURNAL_SID}" \
  '/quality-constitution remember Reconcile without replaying prepared removal')"
context="$(router_context "${router_out}")"
JOURNAL_GRANT="$(grant_id "${JOURNAL_SID}")"
JOURNAL_B64="$(operation_b64 "${context}")"
apply_authorized "${PROJECT}" "${JOURNAL_SID}" "${JOURNAL_GRANT}" "${JOURNAL_B64}" >/dev/null
assert_file_absent "next authorized mutation abandons prepared journal" "${operation_journal}"
assert_eq "prepared authorized profile mutation remains unreplayed" "active" \
  "$(show_json | jq -r --arg id "${claim_id}" '.claims[] | select(.id == $id) | .status')"
assert_eq "prepared-only authorization emits no false audit" "0" \
  "$(jq -s --arg id "${prepared_operation_id}" '[.[] | select(.operation_id? == $id)] | length' "${audit_file}")"

printf 'Test 4: privacy and lifecycle boundaries invalidate unused authority\n'
router_out="$(run_router "${SID}" '/quality-constitution remember An unused one-turn preference')"
if [[ -f "$(grant_path "${SID}")" ]]; then ok "unused grant exists in issuing turn"; else not_ok "issuing grant absent"; fi
run_router "${SID}" 'Explain the current profile without changing it' >/dev/null
assert_file_absent "next real prompt invalidates unused grant" "$(grant_path "${SID}")"

PRIVATE_SID="authority-private"
private_statement='Never persist this raw private statement in state'
run_router "${PRIVATE_SID}" "/quality-constitution must ${private_statement}" OMC_PROMPT_PERSIST=off >/dev/null
private_grant="$(grant_path "${PRIVATE_SID}")"
if rg -F -q "${private_statement}" "${STATE_ROOT}/${PRIVATE_SID}"; then
  private_raw_count=1
else
  private_raw_count=0
fi
assert_eq "prompt_persist=off state and grant contain no raw statement" "0" "${private_raw_count}"
precompact_payload="$(jq -nc --arg sid "${PRIVATE_SID}" --arg cwd "${PROJECT}" \
  '{session_id:$sid,trigger:"auto",custom_instructions:"",cwd:$cwd}')"
(cd "${PROJECT}" && HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
  bash "${PRECOMPACT}" <<<"${precompact_payload}" >/dev/null)
assert_file_absent "pre-compact invalidates unused grant" "${private_grant}"

printf 'Test 4b: compact/resume boundaries fail closed when grant invalidation cannot commit\n'
CLEAR_FAILURE_SID="authority-clear-failure"
clear_failure_dir="${STATE_ROOT}/${CLEAR_FAILURE_SID}"
clear_failure_grant="$(grant_path "${CLEAR_FAILURE_SID}")"
mkdir -p "${clear_failure_dir}"
printf '{}\n' >"${clear_failure_dir}/session_state.json"
mkdir "${clear_failure_grant}"
clear_failure_precompact_payload="$(jq -nc \
  --arg sid "${CLEAR_FAILURE_SID}" --arg cwd "${PROJECT}" \
  '{session_id:$sid,trigger:"auto",custom_instructions:"",cwd:$cwd}')"
set +e
(cd "${PROJECT}" \
  && HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
    bash "${PRECOMPACT}" <<<"${clear_failure_precompact_payload}" \
      >/dev/null 2>&1)
clear_failure_precompact_rc=$?
set -e
if (( clear_failure_precompact_rc != 0 )); then
  ok "pre-compact refuses a non-removable authorization node"
else
  not_ok "pre-compact continued after authorization removal failed"
fi
if [[ -d "${clear_failure_grant}" ]]; then
  ok "failed pre-compact does not launder the unsafe authorization node"
else
  not_ok "failed pre-compact unexpectedly changed the unsafe authorization node"
fi

clear_failure_compact_payload="$(jq -nc --arg sid "${CLEAR_FAILURE_SID}" \
  '{session_id:$sid,source:"compact"}')"
clear_failure_compact_out="$(HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
  bash "${COMPACT_HANDOFF}" <<<"${clear_failure_compact_payload}")"
assert_contains "compact handoff discloses authorization invalidation failure" \
  "authorization could not be invalidated safely" "${clear_failure_compact_out}"
if [[ -d "${clear_failure_grant}" ]]; then
  ok "compact handoff preserves fail-closed authorization evidence"
else
  not_ok "compact handoff removed an unsafe authorization directory"
fi

clear_failure_resume_payload="$(jq -nc --arg sid "${CLEAR_FAILURE_SID}" \
  '{session_id:$sid,source:"resume",transcript_path:""}')"
clear_failure_resume_out="$(HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
  bash "${RESUME_HANDOFF}" <<<"${clear_failure_resume_payload}")"
assert_contains "resume handoff discloses authorization invalidation failure" \
  "authorization could not be invalidated safely" "${clear_failure_resume_out}"
if [[ -d "${clear_failure_grant}" ]]; then
  ok "resume handoff preserves fail-closed authorization evidence"
else
  not_ok "resume handoff removed an unsafe authorization directory"
fi
rm -rf "${clear_failure_grant}"

# A live legacy lock is a deterministic lock-acquisition fault. Keep its
# holder PID alive in this parent test and cap the child to one poll.
printf '%s\n' '{"_v":1,"grant_id":"qca_lock_fault"}' \
  >"${clear_failure_grant}"
mkdir "${clear_failure_dir}/.state.lock"
printf '%s\n' "$$" >"${clear_failure_dir}/.state.lock/holder.pid"
set +e
(cd "${PROJECT}" \
  && HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
    OMC_STATE_LOCK_MAX_ATTEMPTS=1 OMC_STATE_LOCK_STALE_SECS=999 \
    bash "${PRECOMPACT}" <<<"${clear_failure_precompact_payload}" \
      >/dev/null 2>&1)
clear_failure_lock_rc=$?
set -e
if (( clear_failure_lock_rc != 0 )); then
  ok "pre-compact refuses to continue when authorization lock acquisition fails"
else
  not_ok "pre-compact ignored authorization lock acquisition failure"
fi
if [[ -f "${clear_failure_grant}" ]]; then
  ok "lock failure preserves the unspent authorization for explicit recovery"
else
  not_ok "lock-failed pre-compact removed authorization without ownership"
fi
rm -rf "${clear_failure_dir}/.state.lock"
rm -f "${clear_failure_grant}"

synthetic_payload="$(jq -nc --arg cwd "${PROJECT}" \
  '{session_id:"authority-synthetic",prompt:"<task-notification>done</task-notification>",cwd:$cwd}')"
(cd "${PROJECT}" && HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
  bash "${ROUTER}" <<<"${synthetic_payload}" >/dev/null)
assert_file_absent "synthetic prompt cannot mint authority" "$(grant_path authority-synthetic)"

for lifecycle in \
  bundle/dot-claude/quality-pack/scripts/pre-compact-snapshot.sh \
  bundle/dot-claude/quality-pack/scripts/session-start-compact-handoff.sh \
  bundle/dot-claude/quality-pack/scripts/session-start-resume-handoff.sh \
  bundle/dot-claude/skills/autowork/scripts/stop-dispatch.sh; do
  if rg -q 'omc_clear_quality_constitution_authorization_unlocked' \
      "${REPO_ROOT}/${lifecycle}"; then
    ok "lifecycle invalidation wired: ${lifecycle##*/}"
  else
    not_ok "lifecycle invalidation missing: ${lifecycle##*/}"
  fi
done
if rg -q 'quality_constitution_authorization\.json' "${COMMON}"; then
  ok "shared lifecycle invalidator owns the exact authorization sidecar"
else
  not_ok "shared lifecycle invalidator lost the authorization sidecar path"
fi

printf 'Test 5: helper and always-on guard reject raw, compound, split, connector, and PATH-shim bypasses\n'
set +e
raw_out="$(cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" \
  add-claim --statement Raw --authority user_confirmed 2>&1)"
raw_rc=$?
direct_out="$(cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" \
  direct add-claim --statement Raw --authority user_confirmed 2>&1)"
direct_rc=$?
set -e
if (( raw_rc != 0 )); then ok "raw helper mutator is closed"; else not_ok "raw helper mutator open"; fi
if (( direct_rc != 0 )); then ok "noninteractive direct entrance is closed"; else not_ok "noninteractive direct entrance open"; fi
assert_contains "direct failure requires human TTY" "interactive human terminal" "${direct_out}"

managed='bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" apply-authorized --session-id "guard-session" --grant "qca_example" --operation-b64 "e30="'
assert_eq "exact managed shape passes guard" "" "$(guard_bash "${managed}")"
nul_guard_router_out="$(run_router "guard-session" \
  '/quality-constitution must Preserve NUL boundary authority')"
nul_guard_grant="$(grant_id "guard-session")"
nul_guard_encoded="$(operation_b64 \
  "$(router_context "${nul_guard_router_out}")")"
nul_guard_managed="bash \"\$HOME/.claude/skills/autowork/scripts/quality-constitution.sh\" apply-authorized --session-id \"guard-session\" --grant \"${nul_guard_grant}\" --operation-b64 \"${nul_guard_encoded}\""
nul_guard_payload="$(jq -nc --arg command "${nul_guard_managed}" \
  --arg cwd "${PROJECT}" '
    {session_id:("guard-session" + "\u0000"),cwd:$cwd,tool_name:"Bash",
     tool_input:{command:($command + "\u0000")}}
  ')"
assert_contains "NUL-normalized managed apply is denied before allowlisting" \
  '"permissionDecision":"deny"' "$(guard_payload "${nul_guard_payload}")"
if [[ -f "$(grant_path "guard-session")" ]]; then
  ok "NUL-normalized managed apply preserves the victim grant"
else
  not_ok "NUL-normalized managed apply consumed the victim grant"
fi
fake_helper="${TEST_ROOT}/fake/.claude/skills/autowork/scripts/quality-constitution.sh"
mkdir -p "${fake_helper%/*}"
printf '#!/usr/bin/env bash\nexit 0\n' >"${fake_helper}"
chmod +x "${fake_helper}"
fake_managed="bash \"${fake_helper}\" apply-authorized --session-id \"guard-session\" --grant \"qca_example\" --operation-b64 \"e30=\""
assert_contains "managed apply rejects a lookalike helper outside the installed/source identity" \
  '"permissionDecision":"deny"' "$(guard_bash "${fake_managed}")"
wrong_session_managed='bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" apply-authorized --session-id "other-session" --grant "qca_example" --operation-b64 "e30="'
assert_contains "managed apply binds the current hook session" \
  '"permissionDecision":"deny"' "$(guard_bash "${wrong_session_managed}")"
assert_eq "ordinary quality/constitution prose inspection is not a false positive" "" \
  "$(guard_bash 'rg -n "quality constitution" README.md')"
assert_contains "raw Bash profile inspection fails closed" '"permissionDecision":"deny"' \
  "$(guard_bash 'jq . "$HOME/.claude/omc-user/quality-constitutions/profiles/x/constitution.json"')"
assert_eq "managed helper profile inspection remains available" "" \
  "$(guard_bash 'bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" show --json')"
multiline_propose='bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" propose \
  --session-id "guard-session" \
  --signal correction \
  --statement "Prefer exact helper grammars" \
  --quote "exact helper grammars" \
  --concept-key "workflow:exact-helper-grammar"'
assert_eq "strict multiline proposal grammar remains available" "" \
  "$(guard_bash "${multiline_propose}")"
helper_alias="${TEST_ROOT}/quality-helper-alias"
ln -s "${HELPER}" "${helper_alias}"
assert_eq "physical helper alias read uses the same strict grammar" "" \
  "$(guard_bash "bash \"${helper_alias}\" show --json")"
assert_contains "physical helper alias cannot bypass direct-mutation grammar" \
  '"permissionDecision":"deny"' \
  "$(guard_bash "bash \"${helper_alias}\" direct add-claim --statement Minted")"
assert_contains "physical helper alias compound cannot hide mutation" \
  '"permissionDecision":"deny"' \
  "$(guard_bash "bash \"${helper_alias}\" show; script -q /dev/null bash \"${helper_alias}\" direct add-claim --statement Minted")"
assert_eq "shellcheck may inspect helper source" "" \
  "$(guard_bash 'shellcheck -x "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh"')"
assert_eq "bash syntax check may inspect helper source" "" \
  "$(guard_bash 'bash -n "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh"')"
assert_eq "ripgrep may inspect helper source" "" \
  "$(guard_bash 'rg -n "acquire_lock" bundle/dot-claude/skills/autowork/scripts/quality-constitution.sh')"
assert_contains "executable rg preprocessor remains denied" '"permissionDecision":"deny"' \
  "$(guard_bash 'rg --pre malicious-helper quality-constitution.sh')"
assert_contains "git diff is denied because configured textconv can execute" '"permissionDecision":"deny"' \
  "$(guard_bash 'git diff -- bundle/dot-claude/skills/autowork/scripts/quality-constitution.sh')"
assert_contains "executable git external diff remains denied" '"permissionDecision":"deny"' \
  "$(guard_bash 'git diff --ext-diff -- quality-constitution.sh')"
assert_contains "configured git textconv driver spelling remains denied" '"permissionDecision":"deny"' \
  "$(guard_bash 'git -c diff.qc.textconv=/tmp/hostile-textconv diff -- quality-constitution.sh')"
assert_contains "configured git external driver spelling remains denied" '"permissionDecision":"deny"' \
  "$(guard_bash 'git -c diff.external=/tmp/hostile-diff diff -- quality-constitution.sh')"
assert_contains "external diff environment spelling remains denied" '"permissionDecision":"deny"' \
  "$(guard_bash 'env GIT_EXTERNAL_DIFF=/tmp/hostile-diff git diff -- quality-constitution.sh')"
assert_contains "safe-looking git diff flags do not override hostile config risk" '"permissionDecision":"deny"' \
  "$(guard_bash 'git diff --no-textconv --no-ext-diff -- quality-constitution.sh')"
variable_raw='A=add-claim; H="$HOME/.claude/skills/autowork/scripts/quality-constitution.sh"; env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID "$H" "$A" --statement Minted --authority user_confirmed --enforcement advisory'
assert_contains "variable/env-unset raw helper denied" '"permissionDecision":"deny"' "$(guard_bash "${variable_raw}")"
compound_read='/tmp/quality-constitution.sh show && /tmp/quality-constitution.sh direct remove qc_example'
assert_contains "allowlisted read cannot hide compound direct" '"permissionDecision":"deny"' "$(guard_bash "${compound_read}")"
compound_apply='bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" apply-authorized --session-id "s" --grant "qca_x" --operation-b64 "e30=" || true; bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" direct add-claim --statement x'
assert_contains "managed prefix cannot hide compound direct" '"permissionDecision":"deny"' "$(guard_bash "${compound_apply}")"
comment_laundered_direct='v=direct; script -q /dev/null bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" "$v" add-claim --statement Minted # quality-constitution.sh show'
assert_contains "comment cannot launder a variable-indirected TTY mutation" '"permissionDecision":"deny"' \
  "$(guard_bash "${comment_laundered_direct}")"
helper_then_alias_write='bash "$HOME/.claude/skills/autowork/scripts/quality-constitution.sh" show; dd if=/tmp/forged.json of=/tmp/qc-alias/constitution.json'
assert_contains "allowlisted helper read cannot prefix an alias write" '"permissionDecision":"deny"' \
  "$(guard_bash "${helper_then_alias_write}")"
split_helper='H=/tmp/quality-"constitution.sh"; "$H" direct add-claim --statement x'
assert_contains "split helper name denied" '"permissionDecision":"deny"' "$(guard_bash "${split_helper}")"
split_storage='R="$HOME/.claude/omc-user"; printf x > "$R/quality-constitutions/profiles/x/constitution.json"'
assert_contains "split canonical storage write denied" '"permissionDecision":"deny"' "$(guard_bash "${split_storage}")"
grant_write='printf "%s\n" forged > "$HOME/.claude/quality-pack/state/guard-session/quality_constitution_authorization.json"'
assert_contains "Bash cannot forge the authority receipt" '"permissionDecision":"deny"' "$(guard_bash "${grant_write}")"
grant_dd='dd if=/tmp/forged.json of="$HOME/.claude/quality-pack/state/guard-session/quality_constitution_authorization.json"'
assert_contains "unclassified Bash writer cannot forge the authority receipt" '"permissionDecision":"deny"' \
  "$(guard_bash "${grant_dd}")"
profile_dd='dd if=/tmp/forged.json of="$HOME/.claude/omc-user/quality-constitutions/profiles/x/constitution.json"'
assert_contains "unclassified Bash writer cannot replace canonical profile" '"permissionDecision":"deny"' \
  "$(guard_bash "${profile_dd}")"
profile_rsync='rsync /tmp/forged.json "$HOME/.claude/omc-user/profiles/../quality-constitutions/profiles/x/constitution.json"'
assert_contains "traversal-shaped Bash writer cannot replace canonical profile" '"permissionDecision":"deny"' \
  "$(guard_bash "${profile_rsync}")"
relative_profile_dd='dd if=/tmp/forged.json of="quality-constitutions/profiles/x/constitution.json"'
assert_contains "relative Bash writer from omc-user cwd is denied" '"permissionDecision":"deny"' \
  "$(guard_bash "${relative_profile_dd}" "${TEST_HOME}/.claude/omc-user")"
grant_editor="$(jq -nc '{session_id:"guard-session",tool_name:"Write",tool_input:{file_path:"/tmp/.claude/quality-pack/state/guard-session/quality_constitution_authorization.json",content:"{}"}}')"
assert_contains "editor cannot forge the authority receipt" '"permissionDecision":"deny"' "$(guard_payload "${grant_editor}")"
mkdir -p "${STATE_ROOT}/guard-session"
printf '%s\n' '{"_v":1,"grant_id":"qca_alias_target"}' \
  >"${STATE_ROOT}/guard-session/quality_constitution_authorization.json"
grant_alias="${TEST_ROOT}/quality-constitution-authorization-alias"
ln -s "${STATE_ROOT}/guard-session/quality_constitution_authorization.json" \
  "${grant_alias}"
grant_alias_editor="$(jq -nc --arg path "${grant_alias}" \
  '{session_id:"guard-session",tool_name:"Write",tool_input:{file_path:$path,content:"{}"}}')"
assert_contains "editor symlink alias cannot forge the authority receipt" \
  '"permissionDecision":"deny"' "$(guard_payload "${grant_alias_editor}")"
assert_contains "Bash symlink alias cannot forge the authority receipt" \
  '"permissionDecision":"deny"' "$(guard_bash "printf forged > '${grant_alias}'")"
editor_traversal="$(jq -nc --arg path "${TEST_HOME}/.claude/omc-user/profiles/../quality-constitutions/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"Write",tool_input:{file_path:$path,content:"{}"}}')"
assert_contains "editor traversal into canonical storage is denied" '"permissionDecision":"deny"' \
  "$(guard_payload "${editor_traversal}")"
editor_relative="$(jq -nc --arg cwd "${TEST_HOME}/.claude/omc-user" \
  '{session_id:"guard-session",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"quality-constitutions/profiles/x/constitution.json",old_string:"a",new_string:"b"}}')"
assert_contains "relative editor target from omc-user cwd is denied" '"permissionDecision":"deny"' \
  "$(guard_payload "${editor_relative}")"
qc_alias="${TEST_ROOT}/quality-constitution-alias"
ln -s "${TEST_HOME}/.claude/omc-user/quality-constitutions" "${qc_alias}"
editor_alias="$(jq -nc --arg path "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"Write",tool_input:{file_path:$path,content:"{}"}}')"
assert_contains "editor symlink alias into canonical storage is denied" '"permissionDecision":"deny"' \
  "$(guard_payload "${editor_alias}")"
alias_profile_dd="dd if=/tmp/forged.json of=\"${qc_alias}/profiles/x/constitution.json\""
assert_contains "Bash symlink alias into canonical storage is denied" '"permissionDecision":"deny"' \
  "$(guard_bash "${alias_profile_dd}")"
alias_archive_extract="tar -xf /tmp/forged.tar -C \"${qc_alias}\""
assert_contains "archive extraction through canonical symlink alias is denied" '"permissionDecision":"deny"' \
  "$(guard_bash "${alias_archive_extract}")"

mcp_write="$(jq -nc '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{path:"/tmp/.claude/omc-user/quality-constitutions/profiles/x/constitution.json",content:"x"}}')"
mcp_split="$(jq -nc '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{directory:"/tmp/.claude/omc-user",path:"quality-constitutions/profiles/x/constitution.json",content:"x"}}')"
mcp_unknown="$(jq -nc '{session_id:"guard-session",tool_name:"mcp__filesystem__mystery",tool_input:{path:"/tmp/.claude/omc-user/quality-constitutions/x"}}')"
mcp_read="$(jq -nc '{session_id:"guard-session",tool_name:"mcp__filesystem__read_text_file",tool_input:{path:"/tmp/.claude/omc-user/quality-constitutions/x"}}')"
mcp_grant="$(jq -nc '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{path:"/tmp/.claude/quality-pack/state/guard-session/quality_constitution_authorization.json",content:"{}"}}')"
mcp_grant_alias="$(jq -nc --arg path "${grant_alias}" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{path:$path,content:"{}"}}')"
mcp_alias="$(jq -nc --arg path "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{path:$path,content:"x"}}')"
mcp_alias_paths="$(jq -nc --arg path "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__delete_files",tool_input:{action:"delete",paths:[$path]}}')"
mcp_alias_camel_path="$(jq -nc --arg path "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__delete_file",tool_input:{action:"delete",filePath:$path}}')"
mcp_alias_source="$(jq -nc --arg source "${qc_alias}/profiles/x/constitution.json" \
  --arg destination "${TEST_ROOT}/moved-constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__move_file",tool_input:{action:"move",source:$source,destination:$destination}}')"
mcp_alias_read_paths="$(jq -nc --arg path "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_multiple_files",tool_input:{paths:[$path]}}')"
mcp_mixed_replace="$(jq -nc \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_and_replace",tool_input:{path:"/tmp/.claude/omc-user/quality-constitutions/profiles/x/constitution.json",content:"x"}}')"
mcp_alias_uri="$(jq -nc --arg uri "file://${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_and_replace",tool_input:{uri:$uri,content:"x"}}')"
mcp_alias_resource="$(jq -nc --arg uri "file://${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_then_rename",tool_input:{resource:{uri:$uri},destination:"/tmp/moved.json"}}')"
mcp_alias_filename="$(jq -nc --arg filename "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_append",tool_input:{filename:$filename,data:"x"}}')"
mcp_alias_object_key="$(jq -nc --arg key "${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_set",tool_input:{object_key:$key,value:"x"}}')"
mcp_alias_uri_read="$(jq -nc --arg uri "file://${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_file",tool_input:{uri:$uri}}')"
mcp_alias_single_slash_url="$(jq -nc --arg url "file:${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{url:$url,content:"x"}}')"
mcp_alias_uppercase_uri="$(jq -nc --arg uri "FILE://LOCALHOST${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_and_replace",tool_input:{fileUrl:$uri,content:"x"}}')"
mcp_alias_output_file="$(jq -nc --arg path "file:${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_file",tool_input:{options:{output_file:$path}}}')"
mcp_single_slash_uri_read="$(jq -nc --arg uri "file:${qc_alias}/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_file",tool_input:{url:$uri}}')"
mcp_encoded_uri_mutation="$(jq -nc \
  --arg uri "file://${TEST_HOME}/.claude/omc-user/%71uality-constitutions/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__read_and_replace",tool_input:{uri:$uri,content:"x"}}')"
mcp_encoded_uri_unknown="$(jq -nc \
  --arg uri "file://${TEST_HOME}/.claude/omc-user/%71uality-constitutions/profiles/x/constitution.json" \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__mystery",tool_input:{resource_uri:$uri}}')"
mcp_remote_file_uri_mutation="$(jq -nc \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{url:"file://127.0.0.1/tmp/output",content:"x"}}')"
mcp_ambiguous_slash_file_uri_mutation="$(jq -nc \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{url:"file:////tmp/output",content:"x"}}')"
mcp_relative_file_uri_unknown="$(jq -nc \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__mystery",tool_input:{outputFile:"file:relative-output"}}')"
mcp_prose_only="$(jq -nc \
  --arg content "Documentation mentions ${TEST_HOME}/.claude/omc-user/quality-constitutions but does not target it." \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{path:"/tmp/unrelated.txt",content:$content}}')"
mcp_nested_resource_prose_only="$(jq -nc \
  --arg content "Documentation mentions ${TEST_HOME}/.claude/omc-user/quality-constitutions but does not target it." \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",tool_input:{path:"/tmp/unrelated.txt",resource:{content:$content}}}')"
mcp_short_suffix_prose_only="$(jq -nc \
  --arg content "Documentation mentions ${TEST_HOME}/.claude/omc-user/quality-constitutions but does not target it." \
  '{session_id:"guard-session",tool_name:"mcp__filesystem__write_file",
    tool_input:{path:"/tmp/unrelated.txt",photo:$content,profile:$content,curl:$content}}')"
assert_contains "connector write denied" '"permissionDecision":"deny"' "$(guard_payload "${mcp_write}")"
assert_contains "split connector path denied" '"permissionDecision":"deny"' "$(guard_payload "${mcp_split}")"
assert_contains "unknown connector fails closed" '"permissionDecision":"deny"' "$(guard_payload "${mcp_unknown}")"
assert_contains "connector cannot forge the authority receipt" '"permissionDecision":"deny"' "$(guard_payload "${mcp_grant}")"
assert_contains "connector symlink alias cannot forge the authority receipt" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_grant_alias}")"
assert_contains "connector symlink alias mutation is denied" '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_alias}")"
assert_contains "connector plural path array cannot hide a symlink-alias mutation" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_paths}")"
assert_contains "connector camelCase path cannot hide a symlink-alias mutation" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_camel_path}")"
assert_contains "connector source path cannot move through a symlink alias" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_source}")"
assert_eq "classified connector read remains available" "" "$(guard_payload "${mcp_read}")"
assert_eq "classified connector read through plural path array remains available" \
  "" "$(guard_payload "${mcp_alias_read_paths}")"
assert_contains "mixed read-and-replace connector is denied" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_mixed_replace}")"
assert_contains "file URI symlink alias cannot hide mixed mutation" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_uri}")"
assert_contains "nested resource URI cannot hide rename mutation" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_resource}")"
assert_contains "filename alias cannot hide append mutation" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_filename}")"
assert_contains "object-key alias cannot hide set mutation" \
  '"permissionDecision":"deny"' "$(guard_payload "${mcp_alias_object_key}")"
assert_eq "explicit connector read through a file URI remains available" \
  "" "$(guard_payload "${mcp_alias_uri_read}")"
assert_contains "single-slash file URI in url key cannot hide mutation" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_alias_single_slash_url}")"
assert_contains "case-insensitive file URI scheme cannot hide mutation" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_alias_uppercase_uri}")"
assert_contains "output_file destination into protected storage is denied" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_alias_output_file}")"
assert_eq "explicit connector read through single-slash file URI remains available" \
  "" "$(guard_payload "${mcp_single_slash_uri_read}")"
assert_contains "percent-encoded local file URI mutation fails closed" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_encoded_uri_mutation}")"
assert_contains "percent-encoded local file URI unknown operation fails closed" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_encoded_uri_unknown}")"
assert_contains "remote-authority file URI mutation fails closed" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_remote_file_uri_mutation}")"
assert_contains "ambiguous four-slash file URI mutation fails closed" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_ambiguous_slash_file_uri_mutation}")"
assert_contains "relative opaque file URI unknown operation fails closed" \
  '"permissionDecision":"deny"' \
  "$(guard_payload "${mcp_relative_file_uri_unknown}")"
assert_eq "protected-path prose in non-path content is not a false target" \
  "" "$(guard_payload "${mcp_prose_only}")"
assert_eq "protected-path prose nested under a resource object is not a target" \
  "" "$(guard_payload "${mcp_nested_resource_prose_only}")"
assert_eq "photo/profile/curl prose is not mistaken for path or URL aliases" \
  "" "$(guard_payload "${mcp_short_suffix_prose_only}")"
for mixed_action in replace rename append set add apply; do
  mcp_action_payload="$(jq -nc --arg action "${mixed_action}" \
    '{session_id:"guard-session",tool_name:"mcp__filesystem__read_file",
      tool_input:{action:$action,path:"/tmp/.claude/omc-user/quality-constitutions/profiles/x/constitution.json"}}')"
  assert_contains "reader name cannot override mutating action ${mixed_action}" \
    '"permissionDecision":"deny"' "$(guard_payload "${mcp_action_payload}")"
done
assert_eq "settings matcher covers every MCP tool" "1" \
  "$(jq '[.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("quality-constitution-authority-guard.sh"))) | select(.matcher == "Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*")] | length' "${REPO_ROOT}/config/settings.patch.json")"

FAKE_BIN="${TEST_ROOT}/fake-bin"
SHIM_MARKER="${TEST_ROOT}/shim-ran"
mkdir -p "${FAKE_BIN}"
for shim in cat dirname jq grep shasum sha256sum; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >>"$OMC_SHIM_MARKER"\nexit 97\n' "${shim}" >"${FAKE_BIN}/${shim}"
  chmod +x "${FAKE_BIN}/${shim}"
done
guard_payload_json="$(jq -nc --arg command "${managed}" \
  '{session_id:"guard-session",tool_name:"Bash",tool_input:{command:$command}}')"
shim_out="$(HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" OMC_SHIM_MARKER="${SHIM_MARKER}" \
  PATH="${FAKE_BIN}:${PATH}" bash "${GUARD}" <<<"${guard_payload_json}")"
assert_eq "PATH-poisoned guard still recognizes managed command" "" "${shim_out}"
assert_file_absent "guard pins observers before cat/jq/grep" "${SHIM_MARKER}"
helper_shim_out="$(cd "${PROJECT}" && HOME="${TEST_HOME}" OMC_SHIM_MARKER="${SHIM_MARKER}" \
  PATH="${FAKE_BIN}:${PATH}" bash "${HELPER}" resolve --json)"
assert_eq "PATH-poisoned helper still resolves with trusted tools" "true" \
  "$(jq -r '.exists' <<<"${helper_shim_out}")"
assert_file_absent "helper pins PATH before dirname/jq/hash tools" "${SHIM_MARKER}"

printf 'Test 6: compile uses one generation snapshot and quarantines changed exemplars\n'
REF_SID="authority-reference"
router_out="$(run_router "${REF_SID}" '/quality-constitution reference exemplar.md because Preserve the causal density')"
context="$(router_context "${router_out}")"
REF_GRANT="$(grant_id "${REF_SID}")"
REF_B64="$(operation_b64 "${context}")"
reference_id="$(apply_authorized "${PROJECT}" "${REF_SID}" "${REF_GRANT}" "${REF_B64}")"
compiled="$(compile_json)"
assert_eq "unchanged repo exemplar is verified and included" "verified" \
  "$(jq -r --arg id "${reference_id}" '.references[] | select(.id == $id) | .integrity' <<<"${compiled}")"
pre_drift_digest="$(jq -r '.digest' <<<"${compiled}")"
pre_drift_profile_digest="$(jq -r '.profile_digest' <<<"${compiled}")"
pre_drift_reference_digest="$(jq -r '.reference_integrity_digest' <<<"${compiled}")"
printf 'Mutated exemplar bytes.\n' >"${PROJECT}/exemplar.md"
compiled="$(compile_json)"
assert_eq "drifted exemplar is excluded from trusted references" "0" \
  "$(jq --arg id "${reference_id}" '[.references[] | select(.id == $id)] | length' <<<"${compiled}")"
assert_eq "drifted exemplar is explicitly quarantined" "drifted" \
  "$(jq -r --arg id "${reference_id}" '.quarantined_references[] | select(.id == $id) | .integrity' <<<"${compiled}")"
assert_contains "rendered frame tells model not to use drifted exemplar" "do not use until the user reconfirms" \
  "$(jq -r '.rendered_context' <<<"${compiled}")"
assert_eq "reference drift does not masquerade as a profile write" "${pre_drift_profile_digest}" \
  "$(jq -r '.profile_digest' <<<"${compiled}")"
assert_eq "reference drift changes its integrity identity" "true" \
  "$([[ "${pre_drift_reference_digest}" != "$(jq -r '.reference_integrity_digest' <<<"${compiled}")" ]] && printf true || printf false)"
assert_eq "reference drift invalidates the contract-facing compiled digest" "true" \
  "$([[ "${pre_drift_digest}" != "$(jq -r '.digest' <<<"${compiled}")" ]] && printf true || printf false)"
compact_drift="$(cd "${PROJECT}" && HOME="${TEST_HOME}" bash "${HELPER}" compile --max-chars 512)"
assert_contains "compact frame also preserves quarantine warning" "quarantined exemplars: 1" "${compact_drift}"

COMPACT_SID="authority-compact-planner"
compact_router_out="$(run_router "${COMPACT_SID}" \
  '/ulw make the migration workflow visionary and complete' \
  OMC_QUALITY_CONSTITUTION=on OMC_DEFINITION_OF_EXCELLENT=always \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=512)"
compact_router_context="$(router_context "${compact_router_out}")"
compact_snapshot="${STATE_ROOT}/${COMPACT_SID}/quality_constitution_snapshot.json"
assert_contains "forced compact frame preserves blocking claim ID" \
  "${claim_id}" "${compact_router_context}"
assert_contains "planner directive names exact compiled snapshot path" \
  "${compact_snapshot}" "${compact_router_context}"
assert_contains "planner directive names exact blocker extraction" \
  ".blocking_claims[] | {id,statement}" "${compact_router_context}"
assert_eq "compiled snapshot preserves exact blocking statement" \
  "${statement}" \
  "$(jq -r --arg id "${claim_id}" '.blocking_claims[] | select(.id == $id) | .statement' \
    "${compact_snapshot}")"

router_out="$(run_router "${REF_SID}" "/quality-constitution remove ${reference_id} because The artifact changed")"
apply_authorized "${PROJECT}" "${REF_SID}" "$(grant_id "${REF_SID}")" \
  "$(operation_b64 "$(router_context "${router_out}")")" >/dev/null
assert_eq "advertised remove archives the reference" "archived" \
  "$(show_json | jq -r --arg id "${reference_id}" '.references[] | select(.id == $id) | .status')"

router_out="$(run_router "${REF_SID}" '/quality-constitution anti-reference Generic modal because It erases product voice')"
anti_id="$(apply_authorized "${PROJECT}" "${REF_SID}" "$(grant_id "${REF_SID}")" \
  "$(operation_b64 "$(router_context "${router_out}")")")"
assert_eq "advertised anti-reference persists exact polarity" "anti_exemplar" \
  "$(show_json | jq -r --arg id "${anti_id}" '.references[] | select(.id == $id) | .polarity')"

RACE_HOME="${TEST_ROOT}/race-home"
RACE_PROJECT="${TEST_ROOT}/race-project"
RACE_MAP="${TEST_ROOT}/race-map.txt"
RACE_OUTPUT="${TEST_ROOT}/race-compiles.jsonl"
mkdir -p "${RACE_HOME}" "${RACE_PROJECT}"
git -C "${RACE_PROJECT}" init -q
printf '0 none\n' >"${RACE_MAP}"
writer_command="cd $(shell_quote "${RACE_PROJECT}") && for i in 1 2 3 4 5 6; do HOME=$(shell_quote "${RACE_HOME}") bash $(shell_quote "${HELPER}") direct add-claim --statement \"race-\${i}\" --authority user_confirmed --enforcement advisory >/dev/null || exit 1; generation=\$(HOME=$(shell_quote "${RACE_HOME}") bash $(shell_quote "${HELPER}") show --json | jq -r .generation) || exit 1; digest=\$(HOME=$(shell_quote "${RACE_HOME}") bash $(shell_quote "${HELPER}") digest) || exit 1; printf '%s %s\\n' \"\${generation}\" \"\${digest}\" >>$(shell_quote "${RACE_MAP}"); sleep 0.02; done"
(
  set +e
  if [[ "$(uname -s)" == "Darwin" ]]; then
    script -q /dev/null /bin/bash -c "${writer_command}" >/dev/null 2>&1
  else
    script -q -e -c "${writer_command}" /dev/null >/dev/null 2>&1
  fi
  printf '%s\n' "$?" >"${TEST_ROOT}/race-writer.rc"
  exit 0
) &
writer_pid=$!
for _ in $(seq 1 30); do
  (cd "${RACE_PROJECT}" && HOME="${RACE_HOME}" bash "${HELPER}" compile --json) >>"${RACE_OUTPUT}"
done
wait "${writer_pid}"
assert_eq "concurrent standalone writer completed" "0" "$(<"${TEST_ROOT}/race-writer.rc")"
assert_eq "all concurrent compiles are valid single-generation snapshots" "true" \
  "$(jq -s 'all(.[]; .schema_version == 1 and (.rendered_context | type == "string") and (.generation == (.advisory_claims | length)))' "${RACE_OUTPUT}")"
mixed_pairs=0
while read -r generation digest; do
  if ! grep -Fqx "${generation} ${digest}" "${RACE_MAP}"; then
    mixed_pairs=$((mixed_pairs + 1))
  fi
done < <(jq -r '[.generation,.profile_digest] | @tsv' "${RACE_OUTPUT}")
assert_eq "profile digest and generation always come from one writer snapshot" "0" "${mixed_pairs}"
assert_eq "router calls compile exactly once in Constitution block" "1" \
  "$(grep -c '"${_quality_constitution_script}" compile' "${ROUTER}")"

printf '\n=== Quality Constitution Authority Tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
(( fail == 0 ))
