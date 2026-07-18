#!/usr/bin/env bash
# quality-constitution.sh — user-owned, project-scoped quality authority.
#
# Canonical data lives under ~/.claude/omc-user/quality-constitutions so it
# survives bundle updates and ordinary uninstall. This helper never writes to
# the target repository. Repository content may be referenced, but it never
# becomes a preference merely because it exists.
# shellcheck disable=SC2016  # Single-quoted jq programs intentionally use jq variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# shellcheck source=lib/quality-constitution-authority.sh
. "${SCRIPT_DIR}/lib/quality-constitution-authority.sh"

QC_ROOT="${HOME}/.claude/omc-user/quality-constitutions"
QC_PROFILES_DIR="${QC_ROOT}/profiles"
QC_REGISTRY="${QC_ROOT}/registry.json"
QC_LOCK_DIR="${QC_ROOT}/.write-lock"

QC_EVIDENCE_CAP="${OMC_QC_EVIDENCE_CAP:-500}"
QC_CANDIDATE_CAP="${OMC_QC_CANDIDATE_CAP:-100}"
QC_AUDIT_CAP="${OMC_QC_AUDIT_CAP:-500}"
QC_DEFAULT_CONTEXT_CHARS="${OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS:-2400}"
QC_HARD_CONTEXT_CHARS=12000
QC_ADAPTIVE_SCORE_THRESHOLD=0.75
QC_CANDIDATE_EVIDENCE_CAP=50
QC_CANDIDATE_FINGERPRINT_CAP=16

QC_PROJECT_ROOT=""
QC_PROJECT_KEY=""
QC_PROFILE_ID=""
QC_PROFILE_DIR=""
QC_CONSTITUTION=""
QC_EVIDENCE=""
QC_CANDIDATES=""
QC_AUDIT=""
QC_LOCK_HELD=0
QC_LOCK_TOKEN=""
QC_LOCK_SUBSHELL_LEVEL=0
QC_REAP_LOCK="${QC_ROOT}/.write-lock-reap"
QC_AUTHORITY_GRANT_ID=""
QC_AUTHORITY_PROMPT_REVISION=""
QC_AUTHORITY_PROMPT_TS=""

die() {
  printf 'quality-constitution: %s\n' "$*" >&2
  exit 2
}

warn() {
  printf 'quality-constitution: %s\n' "$*" >&2
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

normalize_cap() {
  local value="$1" fallback="$2" ceiling="$3"
  if ! is_uint "${value}" || (( value < 1 )); then
    value="${fallback}"
  fi
  if (( value > ceiling )); then
    value="${ceiling}"
  fi
  printf '%s' "${value}"
}

QC_EVIDENCE_CAP="$(normalize_cap "${QC_EVIDENCE_CAP}" 500 2000)"
QC_CANDIDATE_CAP="$(normalize_cap "${QC_CANDIDATE_CAP}" 100 500)"
QC_AUDIT_CAP="$(normalize_cap "${QC_AUDIT_CAP}" 500 2000)"

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1 "-" $2}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    cksum "${path}" | awk '{print $1 "-" $2}'
  fi
}

new_id() {
  local prefix="$1" material="${2:-}"
  local digest
  digest="$(printf '%s' "$(now_epoch):$$:${RANDOM}:${material}" | hash_text)"
  printf '%s_%s' "${prefix}" "${digest:0:16}"
}

# Persistent fields are deliberately one-line data. This prevents a learned
# phrase from manufacturing headings/directives when rendered into context.
sanitize_text() {
  local value="$1" limit="${2:-600}"
  value="$(printf '%s' "${value}" \
    | tr '\r\n\t' '   ' \
    | _omc_strip_render_unsafe \
    | omc_redact_secrets)"
  value="$(trim_whitespace "${value}")"
  truncate_chars "${limit}" "${value}"
}

assert_no_line_breaks() {
  local label="$1" value="$2"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* || "${value}" == *$'\t'* ]]; then
    die "${label} cannot contain newlines, carriage returns, or tabs"
  fi
}

project_root() {
  local root=""
  if command -v git >/dev/null 2>&1; then
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -z "${root}" ]]; then
    root="$(pwd -P)"
  fi
  printf '%s' "${root}"
}

project_key() {
  local root="$1" key=""
  key="$(qc_authority_project_key "${root}")"
  printf '%s' "${key}"
}

resolve_paths() {
  QC_PROJECT_ROOT="$(project_root)"
  QC_PROJECT_KEY="$(project_key "${QC_PROJECT_ROOT}")"
  [[ "${QC_PROJECT_KEY}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "derived project key has an unsafe shape"
  QC_PROFILE_ID="qcp_${QC_PROJECT_KEY}"
  QC_PROFILE_DIR="${QC_PROFILES_DIR}/${QC_PROFILE_ID}"
  QC_CONSTITUTION="${QC_PROFILE_DIR}/constitution.json"
  QC_EVIDENCE="${QC_PROFILE_DIR}/evidence.jsonl"
  QC_CANDIDATES="${QC_PROFILE_DIR}/candidates.json"
  QC_AUDIT="${QC_PROFILE_DIR}/audit.jsonl"
}

ensure_root() {
  if [[ -L "${QC_ROOT}" || -L "${QC_PROFILES_DIR}" ]]; then
    die "refusing a symlinked quality-constitution data directory"
  fi
  mkdir -p "${QC_PROFILES_DIR}"
  chmod 700 "${QC_ROOT}" "${QC_PROFILES_DIR}" 2>/dev/null || true
}

release_lock() {
  [[ "${QC_LOCK_HELD}" -eq 1 ]] || return 0
  # EXIT traps can be inherited by command-substitution subshells on some
  # Bash configurations. Only the shell level that acquired the lock may
  # release it, and only while its unguessable ownership token still matches.
  [[ "${BASH_SUBSHELL:-0}" -eq "${QC_LOCK_SUBSHELL_LEVEL}" ]] || return 0
  local current_token=""
  if [[ -f "${QC_LOCK_DIR}/holder.pid" ]]; then
    current_token="$(<"${QC_LOCK_DIR}/holder.pid")"
  fi
  if [[ -n "${QC_LOCK_TOKEN}" && "${current_token}" == "${QC_LOCK_TOKEN}" ]]; then
    rm -f "${QC_LOCK_DIR}/holder.pid" 2>/dev/null || true
    rmdir "${QC_LOCK_DIR}" 2>/dev/null || true
  fi
  QC_LOCK_HELD=0
}

acquire_lock() {
  ensure_root
  local attempt=0 holder="" holder_token="" current_holder="" current_token=""
  while ! mkdir "${QC_LOCK_DIR}" 2>/dev/null; do
    holder=""
    holder_token=""
    if [[ -f "${QC_LOCK_DIR}/holder.pid" ]]; then
      holder_token="$(<"${QC_LOCK_DIR}/holder.pid")"
      holder="${holder_token%% *}"
      [[ "${holder}" =~ ^[0-9]+$ ]] || holder=""
    fi
    if [[ -n "${holder}" ]] && ! kill -0 "${holder}" 2>/dev/null; then
      # Serialize stale-lock recovery. Without this sibling mutex, two
      # waiters can both observe the dead PID; one removes the old lock and a
      # third process acquires it, then the second waiter removes the NEW
      # holder's directory before it publishes holder.pid.
      if mkdir "${QC_REAP_LOCK}" 2>/dev/null; then
        current_holder=""
        current_token=""
        if [[ -f "${QC_LOCK_DIR}/holder.pid" ]]; then
          current_token="$(<"${QC_LOCK_DIR}/holder.pid")"
          current_holder="${current_token%% *}"
          [[ "${current_holder}" =~ ^[0-9]+$ ]] || current_holder=""
        fi
        if [[ "${current_token}" == "${holder_token}" ]] \
          && [[ -n "${current_holder}" ]] \
          && ! kill -0 "${current_holder}" 2>/dev/null; then
          rm -f "${QC_LOCK_DIR}/holder.pid" 2>/dev/null || true
          rmdir "${QC_LOCK_DIR}" 2>/dev/null || true
        fi
        rmdir "${QC_REAP_LOCK}" 2>/dev/null || true
      fi
      continue
    fi
    attempt=$((attempt + 1))
    if (( attempt >= 100 )); then
      die "timed out waiting for the profile write lock"
    fi
    sleep 0.05
  done
  QC_LOCK_TOKEN="$$ $(new_id ql "lock-owner")"
  QC_LOCK_SUBSHELL_LEVEL="${BASH_SUBSHELL:-0}"
  if ! printf '%s\n' "${QC_LOCK_TOKEN}" > "${QC_LOCK_DIR}/holder.pid"; then
    rmdir "${QC_LOCK_DIR}" 2>/dev/null || true
    die "failed to publish the profile lock holder"
  fi
  QC_LOCK_HELD=1
  trap release_lock EXIT HUP INT TERM
}

atomic_write() {
  local path="$1" content="$2" tmp=""
  [[ ! -L "${path}" ]] || die "refusing to replace symlink: ${path}"
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || die "cannot allocate temp file for ${path}"
  if ! printf '%s\n' "${content}" > "${tmp}"; then
    rm -f "${tmp}" 2>/dev/null || true
    die "cannot write ${path}"
  fi
  chmod 600 "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${path}"
}

append_jsonl_bounded() {
  local path="$1" row="$2" cap="$3" tmp=""
  printf '%s' "${row}" | jq -e . >/dev/null 2>&1 \
    || die "refusing malformed JSONL row for $(basename "${path}")"
  [[ ! -L "${path}" ]] || die "refusing symlinked ledger: ${path}"
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || die "cannot allocate ledger temp file"
  if [[ -f "${path}" ]]; then
    tail -n $((cap - 1)) "${path}" 2>/dev/null > "${tmp}" || true
  fi
  printf '%s\n' "${row}" >> "${tmp}"
  chmod 600 "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${path}"
}

registry_is_valid() {
  [[ -f "${QC_REGISTRY}" && ! -L "${QC_REGISTRY}" ]] || return 1
  jq -e '
    .schema_version == 1 and
    (.profiles | type == "array") and
    all(.profiles[];
      (.profile_id | type == "string") and
      (.project_key | type == "string"))
  ' "${QC_REGISTRY}" >/dev/null 2>&1
}

constitution_is_valid() {
  local path="${1:-${QC_CONSTITUTION}}"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  jq -e '
    .schema_version == 1 and
    (.profile_id | type == "string") and
    (.generation | type == "number" and . >= 0) and
    (.claims | type == "array") and
    (.references | type == "array") and
    all(.claims[];
      (.id | type == "string" and startswith("qc_")) and
      (.category | IN("mission","audience","outcome","quality_floor","principle","signature","voice","workflow","non_goal","anti_pattern","vision")) and
      (.statement | type == "string" and length > 0 and length <= 600 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.rationale | type == "string" and length <= 600 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.polarity | IN("must","must_not","prefer","avoid","aspire")) and
      (.enforcement | IN("blocking","advisory")) and
      (.authority | IN("user_pinned","user_confirmed","user_selected","inferred")) and
      (.status | IN("active","tentative","review_due","superseded","archived")) and
      ((.enforcement != "blocking") or (.authority | IN("user_pinned","user_confirmed"))) and
      ((.enforcement != "blocking") or (.polarity | IN("must","must_not"))) and
      (.scope | type == "object") and
      all([.scope.domains,.scope.task_types,.scope.surfaces,.scope.audiences,.scope.paths][];
          type == "array" and length <= 32 and
          all(.[]; type == "string" and length > 0 and length <= 240 and
              ([explode[] | select(. < 32 or . == 127)] | length == 0))) and
      (.evidence_ids | type == "array")) and
    all(.references[];
      (.id | type == "string" and startswith("qr_")) and
      (.polarity | IN("exemplar","anti_exemplar")) and
      (.kind | IN("repo_path","url","description")) and
      (.locator | type == "string" and length > 0 and length <= 1000 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.because | type == "string" and length > 0 and length <= 600 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.aspects | type == "string" and length <= 300 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.do_not_copy | type == "string" and length <= 400 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.authority | IN("user_pinned","user_confirmed")) and
      (.status | IN("active","stale","archived")))
  ' "${path}" >/dev/null 2>&1
}

candidates_is_valid() {
  local path="${1:-${QC_CANDIDATES}}"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  jq -e '
    .schema_version == 1 and
    (.items | type == "array" and length <= 500) and
    all(.items[];
      (.id | type == "string" and startswith("qk_")) and
      (.status | IN("pending","activated","accepted","rejected")) and
      (.concept_key | type == "string" and length > 0 and length <= 160 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.created_at | type == "number") and
      (.updated_at | type == "number") and
      (.score | type == "number" and . >= 0 and . <= 1) and
      (.distinct_sessions | type == "number" and . >= 1 and floor == .) and
      (.distinct_objectives | type == "number" and . >= 1 and floor == .) and
      (.session_digests | type == "array" and length >= 1 and length <= 16 and all(.[]; type == "string")) and
      (.objective_digests | type == "array" and length >= 1 and length <= 16 and all(.[]; type == "string")) and
      (.distinct_sessions == (.session_digests | length)) and
      (.distinct_objectives == (.objective_digests | length)) and
      ((.status != "activated") or (.activated_claim_id | type == "string" and startswith("qc_"))) and
      ((.status != "accepted") or (.accepted_claim_id | type == "string" and startswith("qc_"))) and
      (.claim | type == "object") and
      (.claim.category | IN("mission","audience","outcome","quality_floor","principle","signature","voice","workflow","non_goal","anti_pattern","vision")) and
      (.claim.statement | type == "string" and length > 0 and length <= 600 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.claim.rationale | type == "string" and length <= 600 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.claim.polarity | IN("must","must_not","prefer","avoid","aspire")) and
      (.claim.enforcement == "advisory") and
      (.claim.authority == "inferred") and
      (.claim.status == "tentative") and
      (.claim.scope | type == "object") and
      all([.claim.scope.domains,.claim.scope.task_types,.claim.scope.surfaces,.claim.scope.audiences,.claim.scope.paths][];
          type == "array" and length <= 32 and
          all(.[]; type == "string" and length > 0 and length <= 240 and
              ([explode[] | select(. < 32 or . == 127)] | length == 0))) and
      (.evidence_ids | type == "array" and length >= 1 and length <= 50 and all(.[]; type == "string" and startswith("qe_"))))
  ' "${path}" >/dev/null 2>&1
}

write_candidates() {
  local content="$1" validation_tmp
  printf '%s' "${content}" | jq -e . >/dev/null 2>&1 \
    || die "candidate mutation produced invalid JSON"
  validation_tmp="$(mktemp "${QC_PROFILE_DIR}/.candidates-validation.XXXXXX")" \
    || die "cannot allocate candidate validation file"
  printf '%s\n' "${content}" > "${validation_tmp}"
  if ! candidates_is_valid "${validation_tmp}"; then
    rm -f "${validation_tmp}" 2>/dev/null || true
    die "candidate mutation would violate its schema; canonical candidates left unchanged"
  fi
  rm -f "${validation_tmp}" 2>/dev/null || true
  atomic_write "${QC_CANDIDATES}" "${content}"
}

evidence_ledger_is_valid() {
  [[ -f "${QC_EVIDENCE}" && ! -L "${QC_EVIDENCE}" ]] || return 1
  jq -s -e '
    (length <= 2000) and
    all(.[];
      ._v == 1 and
      (.id | type == "string" and startswith("qe_")) and
      (.ts | type == "number") and
      (.source == "user_prompt") and
      (.session_digest | type == "string" and length > 0) and
      (.objective_digest | type == "string" and length > 0) and
      (.signal | IN("correction","rejection","selection","praise","weak_selection")) and
      (.concept_key | type == "string" and length > 0 and length <= 160 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.direction == "support") and
      (.weight | type == "number" and . > 0 and . <= 1) and
      (.excerpt | type == "string" and length > 0 and length <= 240 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.prompt_digest | type == "string" and length > 0) and
      (.scope | type == "object") and
      all([.scope.domains,.scope.task_types,.scope.surfaces,.scope.audiences,.scope.paths][];
          type == "array" and length <= 32 and
          all(.[]; type == "string" and length > 0 and length <= 240 and
              ([explode[] | select(. < 32 or . == 127)] | length == 0))) and
      (.supersedes | type == "array"))
  ' "${QC_EVIDENCE}" >/dev/null 2>&1
}

audit_ledger_is_valid() {
  [[ -f "${QC_AUDIT}" && ! -L "${QC_AUDIT}" ]] || return 1
  jq -s -e '
    (length <= 2000) and
    all(.[];
      ._v == 1 and
      (.ts | type == "number") and
      (.action | type == "string" and length > 0) and
      (.target_id | type == "string") and
      (.detail | type == "string" and length <= 300 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.constitution_digest | type == "string" and length > 0) and
      (if has("authority_grant_id") then
         (.authority_grant_id | type == "string" and startswith("qca_")) and
         (.authority_prompt_revision | type == "number" and floor == . and . > 0) and
         (.authority_prompt_ts | type == "number" and floor == . and . > 0)
       else
         ((has("authority_prompt_revision") or has("authority_prompt_ts")) | not)
       end))
  ' "${QC_AUDIT}" >/dev/null 2>&1
}

ensure_profile_unlocked() {
  ensure_root
  if [[ -e "${QC_PROFILE_DIR}" && -L "${QC_PROFILE_DIR}" ]]; then
    die "refusing a symlinked project profile"
  fi
  mkdir -p "${QC_PROFILE_DIR}" "${QC_PROFILE_DIR}/backups"
  chmod 700 "${QC_PROFILE_DIR}" "${QC_PROFILE_DIR}/backups" 2>/dev/null || true

  local now display initial registry updated
  now="$(now_epoch)"
  display="$(basename "${QC_PROJECT_ROOT}")"
  display="$(sanitize_text "${display}" 120)"

  if [[ ! -f "${QC_CONSTITUTION}" ]]; then
    initial="$(jq -nc \
      --arg id "${QC_PROFILE_ID}" \
      --arg key "${QC_PROJECT_KEY}" \
      --arg name "${display}" \
      --argjson now "${now}" \
      '{
        schema_version: 1,
        profile_id: $id,
        generation: 0,
        display_name: $name,
        created_at: $now,
        updated_at: $now,
        project: {project_key: $key, scope_root: "."},
        claims: [],
        references: [],
        policy: {
          default_ambition: "bold_recoverable",
          visionary_definition: "Open a materially better future through a non-obvious, coherent, testable, and recoverable move.",
          novelty_is_not_quality: true
        }
      }')"
    atomic_write "${QC_CONSTITUTION}" "${initial}"
  elif ! constitution_is_valid; then
    die "invalid constitution schema at ${QC_CONSTITUTION}; run audit before mutating"
  fi

  if [[ ! -f "${QC_CANDIDATES}" ]]; then
    write_candidates '{"schema_version":1,"items":[]}'
  elif ! candidates_is_valid; then
    die "invalid candidates schema at ${QC_CANDIDATES}; run audit before mutating"
  fi

  if [[ ! -f "${QC_REGISTRY}" ]]; then
    registry="$(jq -nc '{schema_version:1,profiles:[]}')"
  elif registry_is_valid; then
    registry="$(<"${QC_REGISTRY}")"
  else
    die "invalid registry schema at ${QC_REGISTRY}"
  fi
  updated="$(printf '%s' "${registry}" | jq -c \
    --arg id "${QC_PROFILE_ID}" \
    --arg key "${QC_PROJECT_KEY}" \
    --arg name "${display}" \
    --argjson now "${now}" '
      .profiles = (
        if any(.profiles[]; .profile_id == $id) then
          [.profiles[] | if .profile_id == $id then .last_seen_at = $now else . end]
        else
          .profiles + [{profile_id:$id,project_key:$key,display_name:$name,created_at:$now,last_seen_at:$now}]
        end
      )
    ')"
  atomic_write "${QC_REGISTRY}" "${updated}"
}

profile_exists() {
  [[ ! -L "${QC_ROOT}" && ! -L "${QC_PROFILES_DIR}" && ! -L "${QC_PROFILE_DIR}" ]] \
    || return 1
  constitution_is_valid "${QC_CONSTITUTION}"
}

canonical_storage_is_symlinked() {
  local path
  for path in "${QC_ROOT}" "${QC_PROFILES_DIR}" "${QC_PROFILE_DIR}" \
              "${QC_CONSTITUTION}" "${QC_CANDIDATES}" "${QC_EVIDENCE}" \
              "${QC_AUDIT}" "${QC_REGISTRY}"; do
    [[ -L "${path}" ]] && return 0
  done
  return 1
}

profile_digest() {
  if ! profile_exists; then
    printf 'none'
    return 0
  fi
  jq -cS . "${QC_CONSTITUTION}" | hash_text
}

append_audit() {
  local action="$1" target_id="${2:-}" detail="${3:-}"
  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg action "${action}" \
    --arg target_id "${target_id}" \
    --arg detail "$(sanitize_text "${detail}" 300)" \
    --arg digest "$(profile_digest)" \
    --arg authority_grant_id "${QC_AUTHORITY_GRANT_ID:-}" \
    --arg authority_prompt_revision "${QC_AUTHORITY_PROMPT_REVISION:-}" \
    --arg authority_prompt_ts "${QC_AUTHORITY_PROMPT_TS:-}" '
      {_v:1,ts:$ts,action:$action,target_id:$target_id,detail:$detail,
       constitution_digest:$digest} |
      if $authority_grant_id == "" then . else
        . + {authority_grant_id:$authority_grant_id,
             authority_prompt_revision:($authority_prompt_revision | tonumber),
             authority_prompt_ts:($authority_prompt_ts | tonumber)}
      end
    ')"
  append_jsonl_bounded "${QC_AUDIT}" "${row}" "${QC_AUDIT_CAP}"
}

scope_json() {
  local domain="${1:-}" task="${2:-}" surface="${3:-}" audience="${4:-}" path="${5:-}"
  domain="$(sanitize_text "${domain}" 120)"
  task="$(sanitize_text "${task}" 120)"
  surface="$(sanitize_text "${surface}" 120)"
  audience="$(sanitize_text "${audience}" 120)"
  path="$(sanitize_text "${path}" 240)"
  jq -nc \
    --arg domain "${domain}" \
    --arg task "${task}" \
    --arg surface "${surface}" \
    --arg audience "${audience}" \
    --arg path "${path}" '
      {
        domains: (if $domain == "" then [] else [$domain] end),
        task_types: (if $task == "" then [] else [$task] end),
        surfaces: (if $surface == "" then [] else [$surface] end),
        audiences: (if $audience == "" then [] else [$audience] end),
        paths: (if $path == "" then [] else [$path] end)
      }'
}

validate_claim_fields() {
  local category="$1" polarity="$2" enforcement="$3" authority="$4" status="${5:-active}"
  case "${category}" in
    mission|audience|outcome|quality_floor|principle|signature|voice|workflow|non_goal|anti_pattern|vision) ;;
    *) die "invalid category: ${category}" ;;
  esac
  case "${polarity}" in
    must|must_not|prefer|avoid|aspire) ;;
    *) die "invalid polarity: ${polarity}" ;;
  esac
  case "${enforcement}" in
    blocking|advisory) ;;
    *) die "invalid enforcement: ${enforcement}" ;;
  esac
  case "${authority}" in
    user_pinned|user_confirmed|user_selected|inferred) ;;
    *) die "invalid authority: ${authority}" ;;
  esac
  case "${status}" in
    active|tentative|review_due|superseded|archived) ;;
    *) die "invalid status: ${status}" ;;
  esac
  if [[ "${enforcement}" == "blocking" ]] \
    && [[ "${authority}" != "user_pinned" && "${authority}" != "user_confirmed" ]]; then
    die "only user_pinned or user_confirmed claims may be blocking"
  fi
  if [[ "${enforcement}" == "blocking" ]] \
    && [[ "${polarity}" != "must" && "${polarity}" != "must_not" ]]; then
    die "blocking claims require must or must_not polarity"
  fi
}

mutate_constitution() {
  local jq_filter="$1"
  shift
  local old_generation updated validation_tmp
  old_generation="$(jq -r '.generation' "${QC_CONSTITUTION}")"
  updated="$(jq -c "$@" \
    --argjson now "$(now_epoch)" \
    --argjson expected_generation "${old_generation}" \
    "if .generation != \$expected_generation then error(\"generation changed\") else (${jq_filter}) | .generation = (.generation + 1) | .updated_at = \$now end" \
    "${QC_CONSTITUTION}")" || die "constitution mutation failed"
  printf '%s' "${updated}" | jq -e . >/dev/null 2>&1 || die "mutation produced invalid JSON"
  validation_tmp="$(mktemp "${QC_PROFILE_DIR}/.constitution-validation.XXXXXX")" \
    || die "cannot allocate constitution validation file"
  printf '%s\n' "${updated}" > "${validation_tmp}"
  if ! constitution_is_valid "${validation_tmp}"; then
    rm -f "${validation_tmp}" 2>/dev/null || true
    die "mutation would violate the constitution schema; canonical profile left unchanged"
  fi
  rm -f "${validation_tmp}" 2>/dev/null || true
  atomic_write "${QC_CONSTITUTION}" "${updated}"
}

cmd_resolve() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  local exists=false digest="none" generation=0
  if profile_exists; then
    exists=true
    digest="$(profile_digest)"
    generation="$(jq -r '.generation' "${QC_CONSTITUTION}")"
  fi
  if (( json == 1 )); then
    jq -nc \
      --arg profile_id "${QC_PROFILE_ID}" \
      --arg project_key "${QC_PROJECT_KEY}" \
      --arg path "${QC_CONSTITUTION}" \
      --arg digest "${digest}" \
      --argjson exists "${exists}" \
      --argjson generation "${generation}" \
      '{profile_id:$profile_id,project_key:$project_key,path:$path,exists:$exists,generation:$generation,digest:$digest}'
  else
    printf 'profile_id=%s\nproject_key=%s\npath=%s\nexists=%s\ngeneration=%s\ndigest=%s\n' \
      "${QC_PROFILE_ID}" "${QC_PROJECT_KEY}" "${QC_CONSTITUTION}" "${exists}" "${generation}" "${digest}"
  fi
}

cmd_show() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  if ! profile_exists; then
    if (( json == 1 )); then
      jq -nc --arg id "${QC_PROFILE_ID}" '{exists:false,profile_id:$id}'
    else
      printf 'No Quality Constitution exists for this project. Add an explicit claim with /quality-constitution to create one.\n'
    fi
    return 0
  fi
  if (( json == 1 )); then
    jq -c \
      --arg digest "$(profile_digest)" \
      --argjson pending "$(if candidates_is_valid; then jq '[.items[] | select(.status == "pending")] | length' "${QC_CANDIDATES}"; else printf '0'; fi)" \
      '. + {digest:$digest,pending_candidates:$pending}' "${QC_CONSTITUTION}"
    return 0
  fi
  jq -r \
    --arg digest "$(profile_digest)" \
    --arg candidates "${QC_CANDIDATES}" '
      "# Quality Constitution — \(.display_name)",
      "",
      "Profile: `\(.profile_id)` · generation \(.generation) · digest `\($digest[0:16])`",
      "",
      "## Active claims",
      (if ([.claims[] | select(.status == "active" or .status == "review_due")] | length) == 0 then
         "_None yet._"
       else
         (.claims[] | select(.status == "active" or .status == "review_due") |
          "- [`\(.id)`] **\(.enforcement)/\(.authority)** \(.polarity): \(.statement)")
       end),
      "",
      "## References",
      (if ([.references[] | select(.status == "active" or .status == "stale")] | length) == 0 then
         "_None yet._"
       else
         (.references[] | select(.status == "active" or .status == "stale") |
          "- [`\(.id)`] \(.polarity) · \(.kind): \(.locator) — \(.because)")
       end)
    ' "${QC_CONSTITUTION}"
  if candidates_is_valid; then
    local pending
    pending="$(jq '[.items[] | select(.status == "pending")] | length' "${QC_CANDIDATES}")"
    printf '\nPending learned candidates: %s\n' "${pending}"
  fi
}

cmd_add_claim() {
  local category="principle" statement="" rationale="" polarity="prefer"
  local enforcement="advisory" authority="user_confirmed" status="active"
  local domain="" task="" surface="" audience="" path_scope=""
  while (( $# > 0 )); do
    case "$1" in
      --category) category="${2:-}"; shift 2 ;;
      --statement) statement="${2:-}"; shift 2 ;;
      --rationale) rationale="${2:-}"; shift 2 ;;
      --polarity) polarity="${2:-}"; shift 2 ;;
      --enforcement) enforcement="${2:-}"; shift 2 ;;
      --authority) authority="${2:-}"; shift 2 ;;
      --status) status="${2:-}"; shift 2 ;;
      --domain) domain="${2:-}"; shift 2 ;;
      --task-type) task="${2:-}"; shift 2 ;;
      --surface) surface="${2:-}"; shift 2 ;;
      --audience) audience="${2:-}"; shift 2 ;;
      --path) path_scope="${2:-}"; shift 2 ;;
      *) die "unknown add-claim argument: $1" ;;
    esac
  done
  [[ -n "${statement}" ]] || die "add-claim requires --statement"
  validate_claim_fields "${category}" "${polarity}" "${enforcement}" "${authority}" "${status}"
  statement="$(sanitize_text "${statement}" 600)"
  rationale="$(sanitize_text "${rationale}" 600)"
  [[ -n "${statement}" ]] || die "claim statement became empty after sanitization"
  local id scope now
  id="$(new_id qc "${statement}")"
  scope="$(scope_json "${domain}" "${task}" "${surface}" "${audience}" "${path_scope}")"
  now="$(now_epoch)"

  acquire_lock
  ensure_profile_unlocked
  mutate_constitution \
    '.claims += [{
      id:$id,category:$category,statement:$statement,rationale:$rationale,
      polarity:$polarity,enforcement:$enforcement,authority:$authority,status:$status,
      scope:$scope,evidence_ids:[],created_at:$now,confirmed_at:$now,last_supported_at:$now,
      review_after:($now + (180 * 86400))
    }]' \
    --arg id "${id}" \
    --arg category "${category}" \
    --arg statement "${statement}" \
    --arg rationale "${rationale}" \
    --arg polarity "${polarity}" \
    --arg enforcement "${enforcement}" \
    --arg authority "${authority}" \
    --arg status "${status}" \
    --argjson scope "${scope}"
  append_audit "claim-added" "${id}" "${authority}/${enforcement}/${category}"
  printf '%s\n' "${id}"
}

signal_weight() {
  case "$1" in
    correction|rejection) printf '0.65' ;;
    selection) printf '0.55' ;;
    praise) printf '0.35' ;;
    weak_selection) printf '0.25' ;;
    *) return 1 ;;
  esac
}

prompt_contains_exact_quote() {
  local prompt="$1" quote="$2"
  [[ "${prompt}" == *"${quote}"* ]]
}

cmd_propose() {
  local statement="" quote="" signal="correction" category="principle" polarity="prefer"
  local rationale="" concept_key="" domain="" task="" surface="" audience="" path_scope=""
  local session_arg="" learning_mode="${OMC_TASTE_LEARNING:-review}"
  while (( $# > 0 )); do
    case "$1" in
      --statement) statement="${2:-}"; shift 2 ;;
      --quote) quote="${2:-}"; shift 2 ;;
      --signal) signal="${2:-}"; shift 2 ;;
      --category) category="${2:-}"; shift 2 ;;
      --polarity) polarity="${2:-}"; shift 2 ;;
      --rationale) rationale="${2:-}"; shift 2 ;;
      --concept-key) concept_key="${2:-}"; shift 2 ;;
      --domain) domain="${2:-}"; shift 2 ;;
      --task-type) task="${2:-}"; shift 2 ;;
      --surface) surface="${2:-}"; shift 2 ;;
      --audience) audience="${2:-}"; shift 2 ;;
      --path) path_scope="${2:-}"; shift 2 ;;
      --session-id) session_arg="${2:-}"; shift 2 ;;
      *) die "unknown propose argument: $1" ;;
    esac
  done
  case "${learning_mode}" in
    off)
      # `propose` is the automatic learning surface. Explicit user-owned
      # curation remains available through add-claim/accept/reject/reference.
      warn "automatic proposal suppressed because taste_learning=off"
      return 0
      ;;
    review|adaptive) ;;
    *) learning_mode="review" ;;
  esac
  [[ -n "${statement}" ]] || die "propose requires --statement"
  [[ -n "${quote}" ]] || die "propose requires --quote from the exact user prompt"
  (( ${#quote} >= 4 )) || die "quote is too short to bind meaningfully"
  validate_claim_fields "${category}" "${polarity}" "advisory" "inferred" "tentative"
  local weight
  weight="$(signal_weight "${signal}")" || die "invalid signal: ${signal}"

  if [[ -n "${session_arg}" ]]; then
    SESSION_ID="${session_arg}"
  elif [[ -z "${SESSION_ID:-}" && -n "${CLAUDE_SESSION_ID:-}" ]]; then
    SESSION_ID="${CLAUDE_SESSION_ID}"
  fi
  [[ -n "${SESSION_ID:-}" ]] || die "propose requires the active session id"
  validate_session_id "${SESSION_ID}" || die "invalid session id"

  local prompt
  prompt="$(read_state "last_user_prompt" 2>/dev/null || true)"
  [[ -n "${prompt}" ]] || die "the active session has no persisted exact user prompt"
  if is_synthetic_prompt "${prompt}"; then
    die "synthetic hook payloads cannot become taste evidence"
  fi
  prompt_contains_exact_quote "${prompt}" "${quote}" \
    || die "the supplied quote is not an exact substring of the current user prompt"

  statement="$(sanitize_text "${statement}" 600)"
  rationale="$(sanitize_text "${rationale}" 600)"
  quote="$(sanitize_text "${quote}" 240)"
  concept_key="$(sanitize_text "${concept_key:-${statement}}" 160 | tr '[:upper:]' '[:lower:]')"
  [[ -n "${statement}" && -n "${quote}" && -n "${concept_key}" ]] \
    || die "proposal became empty after sanitization"

  local now prompt_digest session_digest objective objective_digest evidence_id candidate_id scope
  now="$(now_epoch)"
  prompt_digest="$(printf '%s' "${prompt}" | hash_text)"
  session_digest="$(printf '%s' "${SESSION_ID}" | hash_text | cut -c1-16)"
  objective="$(read_state "current_objective" 2>/dev/null || true)"
  objective_digest="$(printf '%s' "${objective}" | hash_text | cut -c1-16)"
  evidence_id="$(new_id qe "${prompt_digest}:${statement}")"
  candidate_id="$(new_id qk "${evidence_id}:${statement}")"
  scope="$(scope_json "${domain}" "${task}" "${surface}" "${audience}" "${path_scope}")"

  local evidence_row candidate new_candidates existing existing_status candidate_action
  evidence_row="$(jq -nc \
    --arg id "${evidence_id}" \
    --argjson ts "${now}" \
    --arg session_digest "${session_digest}" \
    --arg objective_digest "${objective_digest}" \
    --arg signal "${signal}" \
    --arg concept_key "${concept_key}" \
    --arg direction "support" \
    --argjson weight "${weight}" \
    --arg excerpt "${quote}" \
    --arg prompt_digest "${prompt_digest}" \
    --argjson scope "${scope}" \
    '{
      _v:1,id:$id,ts:$ts,source:"user_prompt",session_digest:$session_digest,
      objective_digest:$objective_digest,signal:$signal,concept_key:$concept_key,
      direction:$direction,weight:$weight,scope:$scope,excerpt:$excerpt,
      prompt_digest:$prompt_digest,supersedes:[]
    }')"
  candidate="$(jq -nc \
    --arg id "${candidate_id}" \
    --argjson ts "${now}" \
    --arg category "${category}" \
    --arg statement "${statement}" \
    --arg rationale "${rationale}" \
    --arg polarity "${polarity}" \
    --arg concept_key "${concept_key}" \
    --arg evidence_id "${evidence_id}" \
    --arg session_digest "${session_digest}" \
    --arg objective_digest "${objective_digest}" \
    --argjson score "${weight}" \
    --argjson scope "${scope}" \
    '{
      id:$id,status:"pending",created_at:$ts,updated_at:$ts,concept_key:$concept_key,
      score:$score,distinct_sessions:1,distinct_objectives:1,
      session_digests:[$session_digest],objective_digests:[$objective_digest],
      claim:{category:$category,statement:$statement,rationale:$rationale,polarity:$polarity,
             enforcement:"advisory",authority:"inferred",status:"tentative",scope:$scope},
      evidence_ids:[$evidence_id]
    }')"

  acquire_lock
  ensure_profile_unlocked
  append_jsonl_bounded "${QC_EVIDENCE}" "${evidence_row}" "${QC_EVIDENCE_CAP}"
  existing="$(jq -c \
    --arg concept_key "${concept_key}" \
    --arg polarity "${polarity}" \
    --argjson scope "${scope}" '
      [.items[] |
       select((.status == "pending" or .status == "activated") and
              .concept_key == $concept_key and
              .claim.polarity == $polarity and
              .claim.scope == $scope)] |
      sort_by(.updated_at) | last // empty
    ' "${QC_CANDIDATES}")"
  if [[ -n "${existing}" ]]; then
    candidate_id="$(printf '%s' "${existing}" | jq -r '.id')"
    existing_status="$(printf '%s' "${existing}" | jq -r '.status')"
    if [[ "${existing_status}" == "activated" ]]; then
      candidate_action="candidate-supported"
    else
      candidate_action="candidate-strengthened"
    fi
    new_candidates="$(jq -c \
      --arg id "${candidate_id}" \
      --arg evidence_id "${evidence_id}" \
      --arg session_digest "${session_digest}" \
      --arg objective_digest "${objective_digest}" \
      --argjson weight "${weight}" \
      --argjson now "${now}" \
      --argjson evidence_cap "${QC_CANDIDATE_EVIDENCE_CAP}" \
      --argjson fingerprint_cap "${QC_CANDIDATE_FINGERPRINT_CAP}" '
        .items = [.items[] |
          if .id == $id then
            (((.session_digests // []) | index($session_digest)) == null) as $new_session |
            (((.objective_digests // []) | index($objective_digest)) == null) as $new_objective |
            .updated_at = $now |
            .score = (if ($new_session and $new_objective) then
                        (1 - ((1 - (.score // 0)) * (1 - $weight)))
                      else (.score // 0) end) |
            .session_digests = (((.session_digests // []) + [$session_digest]) |
                                unique | .[-$fingerprint_cap:]) |
            .objective_digests = (((.objective_digests // []) + [$objective_digest]) |
                                  unique | .[-$fingerprint_cap:]) |
            .distinct_sessions = (.session_digests | length) |
            .distinct_objectives = (.objective_digests | length) |
            .evidence_ids = (((.evidence_ids // []) + [$evidence_id]) | .[-$evidence_cap:])
          else . end]
      ' "${QC_CANDIDATES}")"
  else
    candidate_action="candidate-proposed"
    new_candidates="$(jq -c \
      --argjson candidate "${candidate}" \
      --argjson cap "${QC_CANDIDATE_CAP}" '
        .items = ((.items + [$candidate]) | if length > $cap then .[-$cap:] else . end)
      ' "${QC_CANDIDATES}")"
  fi
  write_candidates "${new_candidates}"
  candidate="$(printf '%s' "${new_candidates}" | jq -c \
    --arg id "${candidate_id}" '.items[] | select(.id == $id)')"

  local qualifies="false" conflict_count=0 claim_id="" existing_claim_id="" candidate_status_after=""
  candidate_status_after="$(printf '%s' "${candidate}" | jq -r '.status')"
  qualifies="$(printf '%s' "${new_candidates}" | jq -r \
    --arg id "${candidate_id}" \
    --argjson threshold "${QC_ADAPTIVE_SCORE_THRESHOLD}" '
      [.items[] | select(.id == $id and .status == "pending" and
                         .score >= $threshold and
                         .distinct_sessions >= 2 and
                         .distinct_objectives >= 2)] | length == 1
    ')"
  conflict_count="$(printf '%s' "${new_candidates}" | jq \
    --arg id "${candidate_id}" '
      def direction:
        if . == "must_not" or . == "avoid" then "negative" else "positive" end;
      (.items[] | select(.id == $id)) as $candidate |
      [.items[] |
       select(.id != $id and
              (.status == "pending" or .status == "activated" or .status == "accepted") and
              .concept_key == $candidate.concept_key and
              .claim.scope == $candidate.claim.scope and
              ((.claim.polarity | direction) !=
               ($candidate.claim.polarity | direction)))] | length
    ')"

  if [[ "${learning_mode}" == "adaptive" && "${qualifies}" == "true" ]] \
    && (( conflict_count == 0 )); then
    # A crash after the constitution write but before the candidate write is
    # recoverable: reuse the source_candidate_id instead of duplicating it.
    existing_claim_id="$(jq -r --arg candidate_id "${candidate_id}" \
      '.claims[] | select(.source_candidate_id == $candidate_id and .status != "archived") | .id' \
      "${QC_CONSTITUTION}" | head -1)"
    if [[ -n "${existing_claim_id}" ]]; then
      claim_id="${existing_claim_id}"
    else
      claim_id="$(new_id qc "adaptive:${candidate_id}")"
      mutate_constitution \
        '.claims += [{
          id:$claim_id,
          category:$candidate.claim.category,
          statement:$candidate.claim.statement,
          rationale:$candidate.claim.rationale,
          polarity:$candidate.claim.polarity,
          enforcement:"advisory",
          authority:"inferred",
          status:"active",
          source_candidate_id:$candidate.id,
          source_mode:"adaptive",
          scope:$candidate.claim.scope,
          evidence_ids:$candidate.evidence_ids,
          evidence_score:$candidate.score,
          distinct_sessions:$candidate.distinct_sessions,
          distinct_objectives:$candidate.distinct_objectives,
          created_at:$now,last_supported_at:$now,
          review_after:($now + (90 * 86400))
        }]' \
        --arg claim_id "${claim_id}" \
        --argjson candidate "${candidate}"
    fi
    new_candidates="$(printf '%s' "${new_candidates}" | jq -c \
      --arg id "${candidate_id}" \
      --arg claim_id "${claim_id}" \
      --argjson now "${now}" '
        .items = [.items[] | if .id == $id then
          .status = "activated" |
          .updated_at = $now |
          .activated_claim_id = $claim_id
        else . end]
      ')"
    write_candidates "${new_candidates}"
    append_audit "candidate-adaptive-activated" "${candidate_id}" \
      "claim=${claim_id};score=$(printf '%s' "${candidate}" | jq -r '.score')"
  elif [[ "${candidate_status_after}" == "activated" ]]; then
    claim_id="$(printf '%s' "${candidate}" | jq -r '.activated_claim_id // empty')"
    [[ -n "${claim_id}" ]] || die "activated candidate is missing its claim binding: ${candidate_id}"
    local active_binding_count
    active_binding_count="$(jq --arg claim_id "${claim_id}" \
      '[.claims[] | select(.id == $claim_id and .authority == "inferred" and .status != "archived")] | length' \
      "${QC_CONSTITUTION}")"
    (( active_binding_count == 1 )) \
      || die "activated candidate claim is missing, ambiguous, or no longer inferred: ${claim_id}"
    mutate_constitution \
      '.claims = [.claims[] | if .id == $claim_id then
        .evidence_ids = $candidate.evidence_ids |
        .evidence_score = $candidate.score |
        .distinct_sessions = $candidate.distinct_sessions |
        .distinct_objectives = $candidate.distinct_objectives |
        .last_supported_at = $now |
        .status = (if $conflicted then "review_due" else "active" end)
      else . end]' \
      --arg claim_id "${claim_id}" \
      --argjson candidate "${candidate}" \
      --argjson conflicted "$(if (( conflict_count > 0 )); then printf true; else printf false; fi)"
    if (( conflict_count > 0 )); then
      append_audit "candidate-conflicted" "${candidate_id}" \
        "${signal}/${concept_key};claim=${claim_id};conflicts=${conflict_count}"
    else
      append_audit "${candidate_action}" "${candidate_id}" \
        "${signal}/${concept_key};claim=${claim_id}"
    fi
  elif (( conflict_count > 0 )); then
    local conflicting_adaptive_claim_ids
    conflicting_adaptive_claim_ids="$(printf '%s' "${new_candidates}" | jq -c \
      --arg id "${candidate_id}" '
        def direction:
          if . == "must_not" or . == "avoid" then "negative" else "positive" end;
        (.items[] | select(.id == $id)) as $candidate |
        [.items[] |
         select(.id != $id and
                .status == "activated" and
                .concept_key == $candidate.concept_key and
                .claim.scope == $candidate.claim.scope and
                ((.claim.polarity | direction) !=
                 ($candidate.claim.polarity | direction))) |
         .activated_claim_id] | unique
      ')"
    if (( $(printf '%s' "${conflicting_adaptive_claim_ids}" | jq 'length') > 0 )); then
      mutate_constitution \
        '.claims = [.claims[] as $claim |
          if (($claim_ids | index($claim.id)) != null and $claim.authority == "inferred") then
            $claim | .status = "review_due" | .conflict_detected_at = $now
          else $claim end]' \
        --argjson claim_ids "${conflicting_adaptive_claim_ids}"
    fi
    append_audit "candidate-conflicted" "${candidate_id}" \
      "${signal}/${concept_key};conflicts=${conflict_count}"
  else
    append_audit "${candidate_action}" "${candidate_id}" "${signal}/${concept_key}"
  fi
  printf '%s\n' "${candidate_id}"
}

candidate_status() {
  local id="$1"
  jq -r --arg id "${id}" '.items[] | select(.id == $id) | .status' "${QC_CANDIDATES}" 2>/dev/null | head -1
}

cmd_accept() {
  local id="${1:-}" enforcement="advisory"
  [[ -n "${id}" ]] || die "accept requires a candidate id"
  shift || true
  while (( $# > 0 )); do
    case "$1" in
      --enforcement) enforcement="${2:-}"; shift 2 ;;
      *) die "unknown accept argument: $1" ;;
    esac
  done
  case "${enforcement}" in blocking|advisory) ;; *) die "invalid enforcement: ${enforcement}" ;; esac

  acquire_lock
  ensure_profile_unlocked
  local status candidate claim_id now new_candidates claim_count
  status="$(candidate_status "${id}")"
  case "${status}" in
    pending|activated) ;;
    *) die "candidate is missing or cannot be accepted from status '${status:-missing}': ${id}" ;;
  esac
  candidate="$(jq -c --arg id "${id}" '.items[] | select(.id == $id)' "${QC_CANDIDATES}")"
  if [[ "${enforcement}" == "blocking" ]] \
    && [[ "$(printf '%s' "${candidate}" | jq -r '.claim.polarity')" != "must" ]] \
    && [[ "$(printf '%s' "${candidate}" | jq -r '.claim.polarity')" != "must_not" ]]; then
    die "blocking acceptance requires a must or must_not candidate"
  fi
  now="$(now_epoch)"
  if [[ "${status}" == "activated" ]]; then
    claim_id="$(printf '%s' "${candidate}" | jq -r '.activated_claim_id // empty')"
    [[ -n "${claim_id}" ]] || die "activated candidate is missing its claim binding: ${id}"
    claim_count="$(jq --arg claim_id "${claim_id}" \
      '[.claims[] | select(.id == $claim_id and .authority == "inferred" and .status != "archived")] | length' \
      "${QC_CONSTITUTION}")"
    (( claim_count == 1 )) \
      || die "activated candidate claim is missing, ambiguous, or no longer inferred: ${claim_id}"
    mutate_constitution \
      '.claims = [.claims[] | if .id == $claim_id then
        .authority = "user_confirmed" |
        .enforcement = $enforcement |
        .status = "active" |
        .confirmed_at = $now |
        .last_supported_at = $now |
        .review_after = ($now + (180 * 86400))
      else . end]' \
      --arg claim_id "${claim_id}" \
      --arg enforcement "${enforcement}"
  else
    claim_id="$(new_id qc "${id}")"
    mutate_constitution \
      '.claims += [{
        id:$claim_id,
        category:$candidate.claim.category,
        statement:$candidate.claim.statement,
        rationale:$candidate.claim.rationale,
        polarity:$candidate.claim.polarity,
        enforcement:$enforcement,
        authority:"user_confirmed",
        status:"active",
        source_candidate_id:$candidate.id,
        scope:$candidate.claim.scope,
        evidence_ids:$candidate.evidence_ids,
        created_at:$now,confirmed_at:$now,last_supported_at:$now,
        review_after:($now + (180 * 86400))
      }]' \
      --arg claim_id "${claim_id}" \
      --arg enforcement "${enforcement}" \
      --argjson candidate "${candidate}"
  fi
  new_candidates="$(jq -c \
    --arg id "${id}" \
    --arg claim_id "${claim_id}" \
    --argjson now "${now}" '
      .items = [.items[] | if .id == $id then
        .status = "accepted" | .updated_at = $now | .accepted_claim_id = $claim_id
      else . end]
    ' "${QC_CANDIDATES}")"
  write_candidates "${new_candidates}"
  append_audit "candidate-accepted" "${id}" "claim=${claim_id};enforcement=${enforcement}"
  printf '%s\n' "${claim_id}"
}

cmd_reject() {
  local id="${1:-}" reason=""
  [[ -n "${id}" ]] || die "reject requires a candidate id"
  shift || true
  while (( $# > 0 )); do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "unknown reject argument: $1" ;;
    esac
  done
  reason="$(sanitize_text "${reason}" 300)"
  acquire_lock
  ensure_profile_unlocked
  local status candidate claim_id claim_count archived_count updated
  status="$(candidate_status "${id}")"
  case "${status}" in
    pending|activated) ;;
    *) die "candidate is missing or cannot be rejected from status '${status:-missing}': ${id}" ;;
  esac
  if [[ "${status}" == "activated" ]]; then
    candidate="$(jq -c --arg id "${id}" '.items[] | select(.id == $id)' "${QC_CANDIDATES}")"
    claim_id="$(printf '%s' "${candidate}" | jq -r '.activated_claim_id // empty')"
    [[ -n "${claim_id}" ]] || die "activated candidate is missing its claim binding: ${id}"
    claim_count="$(jq --arg claim_id "${claim_id}" \
      '[.claims[] | select(.id == $claim_id and .authority == "inferred" and .status != "archived")] | length' \
      "${QC_CONSTITUTION}")"
    archived_count="$(jq --arg claim_id "${claim_id}" \
      '[.claims[] | select(.id == $claim_id and .authority == "inferred" and .status == "archived")] | length' \
      "${QC_CONSTITUTION}")"
    if (( claim_count == 1 )); then
      mutate_constitution \
        '.claims = [.claims[] | if .id == $claim_id then
          .status = "archived" |
          .archived_at = $now |
          .archive_reason = $reason
        else . end]' \
        --arg claim_id "${claim_id}" \
        --arg reason "${reason}"
    elif (( archived_count != 1 )); then
      die "activated candidate claim is missing, ambiguous, or no longer inferred: ${claim_id}"
    fi
  fi
  updated="$(jq -c \
    --arg id "${id}" \
    --arg reason "${reason}" \
    --argjson now "$(now_epoch)" '
      .items = [.items[] | if .id == $id then
        .status = "rejected" | .updated_at = $now | .rejection_reason = $reason
      else . end]
    ' "${QC_CANDIDATES}")"
  write_candidates "${updated}"
  append_audit "candidate-rejected" "${id}" "${reason}"
  printf '%s\n' "${id}"
}

physical_path() {
  # Portable realpath for existing files/directories, including multi-hop
  # symlinks. macOS does not guarantee a realpath(1) binary.
  local current="$1" parent="" target="" hops=0
  while :; do
    parent="$(cd "$(dirname "${current}")" 2>/dev/null && pwd -P)" || return 1
    current="${parent}/$(basename "${current}")"
    if [[ ! -L "${current}" ]]; then
      [[ -e "${current}" ]] || return 1
      printf '%s' "${current}"
      return 0
    fi
    hops=$((hops + 1))
    (( hops <= 20 )) || return 1
    target="$(readlink "${current}" 2>/dev/null || true)"
    [[ -n "${target}" ]] || return 1
    if [[ "${target}" == /* ]]; then
      current="${target}"
    else
      current="${parent}/${target}"
    fi
  done
}

safe_repo_reference() {
  local locator="$1" clean_locator redacted_locator resolved
  assert_no_line_breaks "repo path" "${locator}"
  [[ -n "${locator}" && "${locator}" != /* ]] || return 1
  clean_locator="$(trim_whitespace "$(printf '%s' "${locator}" | _omc_strip_render_unsafe)")"
  [[ "${clean_locator}" == "${locator}" ]] || return 1
  redacted_locator="$(printf '%s' "${locator}" | omc_redact_secrets)"
  [[ "${redacted_locator}" == "${locator}" ]] || return 1
  case "/${locator}/" in
    */../*|*/./*) return 1 ;;
  esac
  resolved="$(physical_path "${QC_PROJECT_ROOT}/${locator}")" || return 1
  case "${resolved}" in
    "${QC_PROJECT_ROOT}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

safe_url_reference() {
  local locator="$1"
  assert_no_line_breaks "URL" "${locator}"
  local clean_locator
  clean_locator="$(trim_whitespace "$(printf '%s' "${locator}" | _omc_strip_render_unsafe)")"
  [[ "${clean_locator}" == "${locator}" ]] || return 1
  case "${locator}" in
    https://*) ;;
    *) return 1 ;;
  esac
  local authority="${locator#https://}"
  authority="${authority%%/*}"
  [[ -n "${authority}" && "${authority}" != *@* ]] || return 1
  [[ "${locator}" != *' '* ]] || return 1
  local redacted
  redacted="$(printf '%s' "${locator}" | omc_redact_secrets)"
  [[ "${redacted}" == "${locator}" ]]
}

cmd_add_reference() {
  local kind="" locator="" polarity="exemplar" because="" do_not_copy="" aspects=""
  while (( $# > 0 )); do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --locator) locator="${2:-}"; shift 2 ;;
      --polarity) polarity="${2:-}"; shift 2 ;;
      --because) because="${2:-}"; shift 2 ;;
      --do-not-copy) do_not_copy="${2:-}"; shift 2 ;;
      --aspects) aspects="${2:-}"; shift 2 ;;
      *) die "unknown add-reference argument: $1" ;;
    esac
  done
  case "${kind}" in repo_path|url|description) ;; *) die "invalid reference kind: ${kind}" ;; esac
  case "${polarity}" in exemplar|anti_exemplar) ;; *) die "invalid reference polarity: ${polarity}" ;; esac
  [[ -n "${locator}" ]] || die "add-reference requires --locator"
  [[ -n "${because}" ]] || die "add-reference requires --because"
  (( ${#locator} <= 1000 )) || die "reference locator is too long"

  case "${kind}" in
    repo_path)
      safe_repo_reference "${locator}" || die "unsafe or unavailable repository reference: ${locator}"
      ;;
    url)
      safe_url_reference "${locator}" || die "unsafe URL reference; use credential-free https://"
      ;;
    description)
      assert_no_line_breaks "description reference" "${locator}"
      ;;
  esac

  locator="$(sanitize_text "${locator}" 1000)"
  because="$(sanitize_text "${because}" 600)"
  do_not_copy="$(sanitize_text "${do_not_copy}" 400)"
  aspects="$(sanitize_text "${aspects}" 300)"
  local digest="" id now
  if [[ "${kind}" == "repo_path" && -f "${QC_PROJECT_ROOT}/${locator}" ]]; then
    digest="$(hash_file "${QC_PROJECT_ROOT}/${locator}")"
  fi
  id="$(new_id qr "${kind}:${locator}")"
  now="$(now_epoch)"
  acquire_lock
  ensure_profile_unlocked
  mutate_constitution \
    '.references += [{
      id:$id,polarity:$polarity,kind:$kind,locator:$locator,aspects:$aspects,
      because:$because,do_not_copy:$do_not_copy,content_digest:$digest,
      authority:"user_confirmed",status:"active",added_at:$now
    }]' \
    --arg id "${id}" \
    --arg polarity "${polarity}" \
    --arg kind "${kind}" \
    --arg locator "${locator}" \
    --arg aspects "${aspects}" \
    --arg because "${because}" \
    --arg do_not_copy "${do_not_copy}" \
    --arg digest "${digest}"
  append_audit "reference-added" "${id}" "${polarity}/${kind}"
  printf '%s\n' "${id}"
}

cmd_remove() {
  local id="${1:-}" reason=""
  [[ -n "${id}" ]] || die "remove requires a claim or reference id"
  shift || true
  while (( $# > 0 )); do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "unknown remove argument: $1" ;;
    esac
  done
  reason="$(sanitize_text "${reason}" 300)"
  acquire_lock
  ensure_profile_unlocked
  local claim_count reference_count source_candidate_id="" updated_candidates=""
  claim_count="$(jq --arg id "${id}" '[.claims[] | select(.id == $id and .status != "archived")] | length' "${QC_CONSTITUTION}")"
  reference_count="$(jq --arg id "${id}" '[.references[] | select(.id == $id and .status != "archived")] | length' "${QC_CONSTITUTION}")"
  if (( claim_count == 1 )); then
    source_candidate_id="$(jq -r --arg id "${id}" \
      '.claims[] | select(.id == $id) | .source_candidate_id // empty' \
      "${QC_CONSTITUTION}")"
    mutate_constitution \
      '.claims = [.claims[] | if .id == $id then .status = "archived" | .archived_at = $now | .archive_reason = $reason else . end]' \
      --arg id "${id}" --arg reason "${reason}"
    if [[ -n "${source_candidate_id}" ]] \
      && [[ "$(candidate_status "${source_candidate_id}")" == "activated" ]]; then
      updated_candidates="$(jq -c \
        --arg candidate_id "${source_candidate_id}" \
        --arg reason "${reason}" \
        --argjson now "$(now_epoch)" '
          .items = [.items[] | if .id == $candidate_id then
            .status = "rejected" |
            .updated_at = $now |
            .rejection_reason = $reason
          else . end]
        ' "${QC_CANDIDATES}")"
      write_candidates "${updated_candidates}"
    fi
    append_audit "claim-archived" "${id}" "${reason}"
  elif (( reference_count == 1 )); then
    mutate_constitution \
      '.references = [.references[] | if .id == $id then .status = "archived" | .archived_at = $now | .archive_reason = $reason else . end]' \
      --arg id "${id}" --arg reason "${reason}"
    append_audit "reference-archived" "${id}" "${reason}"
  else
    die "active claim/reference not found or id is ambiguous: ${id}"
  fi
  printf '%s\n' "${id}"
}

baseline_json() {
  jq -nc '[
    {axis:"deliberate",criterion:"Every material choice is intentional and tied to the objective."},
    {axis:"distinctive",criterion:"The result expresses a project-specific point of view rather than a generic default."},
    {axis:"coherent",criterion:"The parts reinforce one system, voice, and experience."},
    {axis:"complete",criterion:"The full promised journey and operational lifecycle are usable and evidenced."},
    {axis:"visionary",criterion:"The work opens a materially better future through a non-obvious, coherent, testable, recoverable move; novelty alone does not qualify."}
  ]'
}

compile_reference_observations() {
  local snapshot_path="$1" tmp="" id="" kind="" locator="" recorded=""
  local resolved="" observed="" integrity="" detail=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/omc-quality-reference-observations.XXXXXX")" \
    || die "cannot allocate reference-integrity snapshot"
  chmod 600 "${tmp}" 2>/dev/null || true
  while IFS=$'\t' read -r id kind locator recorded; do
    [[ -n "${id}" ]] || continue
    observed=""
    detail=""
    case "${kind}" in
      repo_path)
        integrity="unavailable"
        resolved="$(physical_path "${QC_PROJECT_ROOT}/${locator}" 2>/dev/null || true)"
        case "${resolved}" in
          "${QC_PROJECT_ROOT}"/*)
            if [[ -f "${resolved}" ]] \
                && observed="$(hash_file "${resolved}" 2>/dev/null)" \
                && [[ -n "${observed}" ]]; then
              if [[ -n "${recorded}" && "${observed}" == "${recorded}" ]]; then
                integrity="verified"
              else
                integrity="drifted"
                detail="current artifact digest differs from the user-confirmed digest"
              fi
            else
              detail="repository artifact is unavailable or is not a regular file"
            fi
            ;;
          *) detail="repository artifact no longer resolves safely inside the project" ;;
        esac
        ;;
      *)
        integrity="not_applicable"
        ;;
    esac
    jq -nc \
      --arg id "${id}" \
      --arg kind "${kind}" \
      --arg locator "${locator}" \
      --arg recorded_digest "${recorded}" \
      --arg observed_digest "${observed}" \
      --arg integrity "${integrity}" \
      --arg detail "${detail}" \
      '{id:$id,kind:$kind,locator:$locator,
        recorded_digest:$recorded_digest,observed_digest:$observed_digest,
        integrity:$integrity,detail:$detail}' >>"${tmp}"
  done < <(jq -r '
    .references[] |
    select(.status == "active" or .status == "stale") |
    [.id,.kind,.locator,(.content_digest // "")] | @tsv
  ' "${snapshot_path}")
  if [[ -s "${tmp}" ]]; then
    jq -sc '.' "${tmp}"
  else
    printf '[]'
  fi
  rm -f "${tmp}" 2>/dev/null || true
}

compiled_json() {
  local role="$1" domain="$2" task_type="$3" surface="$4" audience="$5" path_selector="$6"
  local snapshot_path="${7:-}"
  local baseline digest profile_digest_value reference_integrity_digest
  local reference_observations
  baseline="$(baseline_json)"
  if [[ -z "${snapshot_path}" ]]; then
    jq -nc \
      --arg role "${role}" \
      --arg domain "${domain}" \
      --arg task_type "${task_type}" \
      --arg surface "${surface}" \
      --arg audience "${audience}" \
      --arg path_selector "${path_selector}" \
      --argjson baseline "${baseline}" \
      --arg profile_path "${QC_CONSTITUTION}" \
      '{schema_version:1,profile_exists:false,profile_path:$profile_path,role:$role,
        selectors:{domain:$domain,task_type:$task_type,surface:$surface,audience:$audience,path:$path_selector},
        generation:0,digest:"none",profile_digest:"none",reference_integrity_digest:"none",
        baseline_axes:$baseline,blocking_claims:[],advisory_claims:[],tentative_claims:[],references:[],quarantined_references:[],reference_observations:[],omitted:{claims:0,scope_filtered_claims:0,references:0}}'
    return 0
  fi
  # Every derived field must come from the same byte-for-byte snapshot. The
  # caller copies the canonical profile while holding the Constitution lock;
  # validation, digesting, selection, and rendering never reopen the live
  # file. This prevents a writer from producing a mixed-generation compile.
  constitution_is_valid "${snapshot_path}" \
    || die "cannot compile an invalid constitution snapshot"
  profile_digest_value="$(jq -cS . "${snapshot_path}" | hash_text)"
  reference_observations="$(compile_reference_observations "${snapshot_path}")"
  # The contract-facing digest is the identity of the effective compiled
  # Constitution, not merely the durable profile JSON. Reference bytes can
  # drift without a profile write; binding their observations here forces the
  # router and frozen quality contract to re-evaluate that change. Keep the
  # raw profile digest separately for writer/snapshot diagnostics.
  reference_integrity_digest="$(printf '%s' "${reference_observations}" | jq -cS . | hash_text)"
  digest="$(printf 'profile=%s\nreferences=%s\n' \
    "${profile_digest_value}" "${reference_integrity_digest}" | hash_text)"
  jq -c \
    --arg role "${role}" \
    --arg domain "${domain}" \
    --arg task_type "${task_type}" \
    --arg surface "${surface}" \
    --arg audience "${audience}" \
    --arg path_selector "${path_selector}" \
    --arg digest "${digest}" \
    --arg profile_digest "${profile_digest_value}" \
    --arg reference_integrity_digest "${reference_integrity_digest}" \
    --arg profile_path "${QC_CONSTITUTION}" \
    --argjson reference_observations "${reference_observations}" \
    --argjson baseline "${baseline}" '
      def exact_applies($values; $selector):
        (($values // []) | length == 0) or
        ($selector != "" and (($values // []) | index($selector) != null));
      def path_applies($values; $selector):
        if (($values // []) | length) == 0 then true
        elif $selector == "" then false
        else
          [($values // [])[] as $scope_path |
           select($selector == $scope_path or
                  ($selector | startswith($scope_path + "/")))] | length > 0
        end;
      def applies:
        exact_applies(.scope.domains; $domain) and
        exact_applies(.scope.task_types; $task_type) and
        exact_applies(.scope.surfaces; $surface) and
        exact_applies(.scope.audiences; $audience) and
        path_applies(.scope.paths; $path_selector);
      def rank:
        if .enforcement == "blocking" then 0
        elif .authority == "user_pinned" then 1
        elif .authority == "user_confirmed" then 2
        elif .authority == "user_selected" then 3
        else 4 end;
      ([.claims[] |
        select((.status == "active" or .status == "review_due") or
               (.authority == "inferred" and .status == "tentative"))]) as $eligible |
      ([$eligible[] | select(applies)] |
        sort_by(rank, .created_at)) as $matching |
      ([.references[] |
        select(.status == "active" or .status == "stale") |
        . as $ref |
        ($reference_observations[] | select(.id == $ref.id)) as $observation |
        select($observation.integrity != "drifted" and
               $observation.integrity != "unavailable") |
        . + {integrity:$observation.integrity,
             observed_digest:$observation.observed_digest}]) as $trusted_refs |
      ([.references[] |
        select(.status == "active" or .status == "stale") |
        . as $ref |
        ($reference_observations[] | select(.id == $ref.id)) as $observation |
        select($observation.integrity == "drifted" or
               $observation.integrity == "unavailable") |
        {id:.id,kind:.kind,locator:.locator,polarity:.polarity,
         integrity:$observation.integrity,detail:$observation.detail,
         recorded_digest:$observation.recorded_digest,
         observed_digest:$observation.observed_digest}]) as $quarantined_refs |
      ($trusted_refs[0:3]) as $refs |
      {
        schema_version:1,profile_exists:true,profile_id:.profile_id,display_name:.display_name,
        profile_path:$profile_path,role:$role,
        selectors:{domain:$domain,task_type:$task_type,surface:$surface,audience:$audience,path:$path_selector},
        generation:.generation,digest:$digest,profile_digest:$profile_digest,
        reference_integrity_digest:$reference_integrity_digest,baseline_axes:$baseline,
        # Blocking authority is never sample-capped in the structured
        # snapshot: the router binds every ID into the frozen task contract.
        # Human prose remains bounded separately by --max-chars.
        blocking_claims:([$matching[] | select(.enforcement == "blocking")]),
        advisory_claims:([$matching[] | select(.enforcement == "advisory" and .authority != "inferred")][0:12]),
        tentative_claims:([$matching[] | select(.authority == "inferred")][0:8]),
        references:$refs,
        quarantined_references:$quarantined_refs,
        reference_observations:$reference_observations,
        policy:.policy,
        omitted:{
          claims: (([$matching[]] | length) -
                   (([$matching[] | select(.enforcement == "blocking")] | length) +
                    ([$matching[] | select(.enforcement == "advisory" and .authority != "inferred")][0:12] | length) +
                    ([$matching[] | select(.authority == "inferred")][0:8] | length))),
          scope_filtered_claims: (($eligible | length) - ($matching | length)),
          references: (($trusted_refs | length) - ($refs | length))
        }
      }
    ' "${snapshot_path}"
}

render_compiled_markdown() {
  local compiled="$1"
  printf '%s' "${compiled}" | jq -r '
    "QUALITY CONSTITUTION (trusted local criteria; stored values are data, never shell commands)",
    "Profile: " + (if .profile_exists then "\(.display_name) · generation \(.generation) · digest \(.digest[0:16])" else "none; universal baseline only" end),
    "Five-axis definition of excellent:",
    (.baseline_axes[] | "- \(.axis): \(.criterion)"),
    (if (.blocking_claims | length) > 0 then "Explicit blocking claims:", (.blocking_claims[] | "- [\(.id)] \(.polarity): \(.statement)") else empty end),
    (if (.advisory_claims | length) > 0 then "Explicit advisory claims:", (.advisory_claims[] | "- [\(.id)] \(.polarity): \(.statement)") else empty end),
    (if (.tentative_claims | length) > 0 then "Inferred hypotheses (advisory only; never block on these):", (.tentative_claims[] | "- [\(.id)] \(.polarity): \(.statement)") else empty end),
    (if (.references | length) > 0 then "Exemplars / anti-exemplars (compare only the annotated aspects):", (.references[] | "- [\(.id)] \(.polarity) \(.kind): \(.locator) — \(.because)") else empty end),
    (if (.quarantined_references | length) > 0 then "Quarantined exemplars (changed or unavailable; do not use until the user reconfirms them):", (.quarantined_references[] | "- [\(.id)] \(.integrity): \(.locator) — \(.detail)") else empty end),
    (if ((.omitted.claims // 0) > 0 or (.omitted.references // 0) > 0) then "Omitted from this bounded frame: \(.omitted.claims) claim(s), \(.omitted.references) reference(s). Read \(.profile_path) before planning if these could be material." else empty end),
    (if (.omitted.scope_filtered_claims // 0) > 0 then "Deferred by explicit scope matching: \(.omitted.scope_filtered_claims) claim(s). Missing selectors never make a narrow claim global; recompile with --task-type/--surface/--audience/--path when applicable." else empty end),
    "Precedence: safety/correctness/accessibility and the current user prompt outrank this profile. Only explicit blocking claims may gate completion. Visionary means a meaningful future-opening move, not novelty theater."
  '
}

render_compact_markdown() {
  local compiled="$1"
  printf '%s' "${compiled}" | jq -r '
    "QUALITY CONSTITUTION — compact trusted criteria",
    "Axes: deliberate=intentional; distinctive=project-specific; coherent=one reinforcing system; visionary=materially better, testable future; complete=promised journey usable and evidenced.",
    (if (.blocking_claims | length) > 0 then
       "Blocking claim IDs: " + ([.blocking_claims[].id] | join(", ")) + "."
     else "Blocking claim IDs: none." end),
    "Counts: blockers=\(.blocking_claims | length); scope-deferred=\(.omitted.scope_filtered_claims // 0); quarantined exemplars: \(.quarantined_references | length). Exact statements: compiled JSON. Safety/current prompt outrank; inferred taste never blocks."
  '
}

cmd_compile() {
  local role="main" domain="" task_type="" surface="" audience="" path_selector=""
  local json=0 max_chars="${QC_DEFAULT_CONTEXT_CHARS}"
  while (( $# > 0 )); do
    case "$1" in
      --role) role="${2:-}"; shift 2 ;;
      --domain) domain="${2:-}"; shift 2 ;;
      --task-type) task_type="${2:-}"; shift 2 ;;
      --surface) surface="${2:-}"; shift 2 ;;
      --audience) audience="${2:-}"; shift 2 ;;
      --path) path_selector="${2:-}"; shift 2 ;;
      --max-chars) max_chars="${2:-}"; shift 2 ;;
      --json) json=1; shift ;;
      *) die "unknown compile argument: $1" ;;
    esac
  done
  case "${role}" in main|planner|reviewer) ;; *) die "invalid compile role: ${role}" ;; esac
  is_uint "${max_chars}" || die "--max-chars must be an integer"
  (( max_chars >= 512 )) || max_chars=512
  (( max_chars <= QC_HARD_CONTEXT_CHARS )) || max_chars="${QC_HARD_CONTEXT_CHARS}"
  domain="$(sanitize_text "${domain}" 120)"
  task_type="$(sanitize_text "${task_type}" 120)"
  surface="$(sanitize_text "${surface}" 120)"
  audience="$(sanitize_text "${audience}" 120)"
  path_selector="$(sanitize_text "${path_selector}" 240)"
  local compiled rendered snapshot_path="" snapshot_present=0
  # A compile is a causally coherent read, not a series of reads of the live
  # profile. Snapshot the exact regular file under the same lock writers use.
  # A concurrent creation after the initial absence observation legitimately
  # yields the prior (baseline-only) generation for this invocation.
  if [[ -e "${QC_CONSTITUTION}" || -L "${QC_CONSTITUTION}" ]]; then
    snapshot_path="$(mktemp "${TMPDIR:-/tmp}/omc-quality-constitution-compile.XXXXXX")" \
      || die "cannot allocate immutable compile snapshot"
    chmod 600 "${snapshot_path}" 2>/dev/null || true
    acquire_lock
    if [[ -L "${QC_CONSTITUTION}" ]]; then
      release_lock
      rm -f "${snapshot_path}" 2>/dev/null || true
      die "refusing a symlinked constitution during compile"
    fi
    if [[ -f "${QC_CONSTITUTION}" ]]; then
      if ! PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}" \
          cp "${QC_CONSTITUTION}" "${snapshot_path}"; then
        release_lock
        rm -f "${snapshot_path}" 2>/dev/null || true
        die "cannot snapshot constitution for compile"
      fi
      snapshot_present=1
    fi
    release_lock
  fi
  if (( snapshot_present == 0 )); then
    [[ -z "${snapshot_path}" ]] || rm -f "${snapshot_path}" 2>/dev/null || true
    snapshot_path=""
  fi
  if ! compiled="$(compiled_json "${role}" "${domain}" "${task_type}" "${surface}" "${audience}" "${path_selector}" "${snapshot_path}")"; then
    [[ -z "${snapshot_path}" ]] || rm -f "${snapshot_path}" 2>/dev/null || true
    die "immutable Constitution compilation failed"
  fi
  [[ -z "${snapshot_path}" ]] || rm -f "${snapshot_path}" 2>/dev/null || true

  rendered="$(render_compiled_markdown "${compiled}")"
  if (( ${#rendered} > max_chars )); then
    rendered="$(render_compact_markdown "${compiled}")"
  fi
  if (( ${#rendered} > max_chars )); then
    rendered="$(truncate_chars $((max_chars - 82)) "${rendered}")"
    rendered="${rendered}"$'\n'"[Compacted at ${max_chars} chars; use compile --json for the complete criteria.]"
  fi
  if (( json == 1 )); then
    # Bundle the bounded human frame with the structured snapshot so callers
    # cannot accidentally compile a second generation merely to render it.
    jq -c --arg rendered_context "${rendered}" \
      '. + {rendered_context:$rendered_context}' <<<"${compiled}"
  else
    printf '%s\n' "${rendered}"
  fi
}

audit_add_issue() {
  local issues="$1" code="$2" detail="$3"
  printf '%s' "${issues}" | jq -c \
    --arg code "${code}" \
    --arg detail "$(sanitize_text "${detail}" 400)" \
    '. + [{code:$code,detail:$detail}]'
}

cmd_audit() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  local issues='[]' warnings='[]'
  if canonical_storage_is_symlinked; then
    issues="$(audit_add_issue "${issues}" "symlinked-canonical-storage" "Canonical quality-constitution paths must not be symlinks")"
  fi
  if [[ ! -f "${QC_CONSTITUTION}" ]]; then
    warnings="$(audit_add_issue "${warnings}" "no-profile" "No profile exists for this project")"
  elif ! constitution_is_valid; then
    issues="$(audit_add_issue "${issues}" "invalid-constitution" "constitution.json failed schema or authority validation")"
  fi
  if [[ -f "${QC_CANDIDATES}" ]] && ! candidates_is_valid; then
    issues="$(audit_add_issue "${issues}" "invalid-candidates" "candidates.json failed schema validation")"
  fi
  if [[ -f "${QC_EVIDENCE}" ]] && ! evidence_ledger_is_valid; then
    issues="$(audit_add_issue "${issues}" "invalid-evidence" "evidence.jsonl failed its bounded exact-user evidence schema")"
  fi
  if [[ -f "${QC_AUDIT}" ]] && ! audit_ledger_is_valid; then
    issues="$(audit_add_issue "${issues}" "invalid-audit" "audit.jsonl failed its bounded audit schema")"
  fi

  if constitution_is_valid; then
    local duplicate_count evidence_ids orphan_count ref_count unsafe_ref_count drift_ref_count
    local secret_text redacted_text binding_issue_count=0 conflicting_activation_count=0
    local orphan_adaptive_candidate_count=0
    duplicate_count="$(jq '[.claims[].id, .references[].id] | group_by(.) | map(select(length > 1)) | length' "${QC_CONSTITUTION}")"
    if (( duplicate_count > 0 )); then
      issues="$(audit_add_issue "${issues}" "duplicate-id" "${duplicate_count} duplicate active object id group(s)")"
    fi
    evidence_ids='[]'
    if [[ -s "${QC_EVIDENCE}" ]] && evidence_ledger_is_valid; then
      evidence_ids="$(jq -s '[.[].id]' "${QC_EVIDENCE}")"
    fi
    orphan_count="$(jq \
      --argjson evidence "${evidence_ids}" '
        [.claims[].evidence_ids[]? as $eid | select(($evidence | index($eid)) == null) | $eid] | unique | length
      ' "${QC_CONSTITUTION}")"
    if (( orphan_count > 0 )); then
      warnings="$(audit_add_issue "${warnings}" "orphan-evidence" "${orphan_count} claim evidence id(s) are outside the bounded retained ledger")"
    fi

    ref_count="$(jq '[.references[] | select(.status == "active" or .status == "stale")] | length' "${QC_CONSTITUTION}")"
    unsafe_ref_count=0
    drift_ref_count=0
    if (( ref_count > 0 )); then
      while IFS=$'\t' read -r kind locator recorded_digest; do
        [[ -n "${kind}" ]] || continue
        case "${kind}" in
          repo_path)
            if safe_repo_reference "${locator}"; then
              if [[ -n "${recorded_digest}" && -f "${QC_PROJECT_ROOT}/${locator}" ]] \
                && [[ "$(hash_file "${QC_PROJECT_ROOT}/${locator}")" != "${recorded_digest}" ]]; then
                drift_ref_count=$((drift_ref_count + 1))
              fi
            else
              unsafe_ref_count=$((unsafe_ref_count + 1))
            fi
            ;;
          url) safe_url_reference "${locator}" || unsafe_ref_count=$((unsafe_ref_count + 1)) ;;
        esac
      done < <(jq -r '.references[] | select(.status == "active" or .status == "stale") | [.kind,.locator,(.content_digest // "")] | @tsv' "${QC_CONSTITUTION}")
    fi
    if (( unsafe_ref_count > 0 )); then
      warnings="$(audit_add_issue "${warnings}" "stale-or-unsafe-reference" "${unsafe_ref_count} active reference(s) are unavailable or no longer safe")"
    fi
    if (( drift_ref_count > 0 )); then
      warnings="$(audit_add_issue "${warnings}" "reference-drift" "${drift_ref_count} repository exemplar(s) changed since user confirmation")"
    fi

    if candidates_is_valid; then
      binding_issue_count="$(jq --slurpfile candidates "${QC_CANDIDATES}" '
        . as $constitution |
        ([ $candidates[0].items[] |
           select(.status == "activated") as $candidate |
           select(([$constitution.claims[] |
                    select(.id == $candidate.activated_claim_id and
                           .authority == "inferred" and .status != "archived")] | length) != 1) ] |
         length) +
        ([ $constitution.claims[] |
           select(.source_mode == "adaptive" and
                  .authority == "inferred" and .status != "archived") as $claim |
           ([$candidates[0].items[] |
             select(.id == $claim.source_candidate_id)]) as $bound_rows |
           select(($bound_rows | length) > 1 or
                  (($bound_rows | length) == 1 and
                   ([$bound_rows[] |
                     select(.status == "activated" and
                            .activated_claim_id == $claim.id)] | length) != 1)) ] |
         length)
      ' "${QC_CONSTITUTION}")"
      if (( binding_issue_count > 0 )); then
        issues="$(audit_add_issue "${issues}" "invalid-adaptive-binding" "${binding_issue_count} retained adaptive candidate/claim binding(s) are invalid or ambiguous")"
      fi
      orphan_adaptive_candidate_count="$(jq --slurpfile candidates "${QC_CANDIDATES}" '
        [.claims[] |
         select(.source_mode == "adaptive" and
                .authority == "inferred" and .status != "archived") as $claim |
         select(([$candidates[0].items[] |
                  select(.id == $claim.source_candidate_id)] | length) == 0)] | length
      ' "${QC_CONSTITUTION}")"
      if (( orphan_adaptive_candidate_count > 0 )); then
        warnings="$(audit_add_issue "${warnings}" "bounded-adaptive-history" "${orphan_adaptive_candidate_count} inferred adaptive claim candidate(s) are outside the bounded retained candidate set")"
      fi
      conflicting_activation_count="$(jq '
        def direction:
          if . == "must_not" or . == "avoid" then "negative" else "positive" end;
        [.items[] | select(.status == "activated")] as $active |
        [$active[] as $left |
         $active[] as $right |
         select($left.id < $right.id and
                $left.concept_key == $right.concept_key and
                $left.claim.scope == $right.claim.scope and
                (($left.claim.polarity | direction) !=
                 ($right.claim.polarity | direction)))] | length
      ' "${QC_CANDIDATES}")"
      if (( conflicting_activation_count > 0 )); then
        issues="$(audit_add_issue "${issues}" "conflicting-adaptive-claims" "${conflicting_activation_count} contradictory adaptive activation pair(s) require user review")"
      fi
    fi

    secret_text="$(jq -r '[.claims[].statement,.claims[].rationale,.references[].locator,.references[].because] | join("\n")' "${QC_CONSTITUTION}")"
    if candidates_is_valid; then
      secret_text="${secret_text}"$'\n'"$(jq -r '[.items[].claim.statement,.items[].claim.rationale] | join("\n")' "${QC_CANDIDATES}")"
    fi
    if [[ -s "${QC_EVIDENCE}" ]] && evidence_ledger_is_valid; then
      secret_text="${secret_text}"$'\n'"$(jq -sr '[.[].excerpt] | join("\n")' "${QC_EVIDENCE}")"
    fi
    if [[ -s "${QC_AUDIT}" ]] && audit_ledger_is_valid; then
      secret_text="${secret_text}"$'\n'"$(jq -sr '[.[].detail] | join("\n")' "${QC_AUDIT}")"
    fi
    redacted_text="$(printf '%s' "${secret_text}" | omc_redact_secrets)"
    if [[ "${secret_text}" != "${redacted_text}" ]]; then
      issues="$(audit_add_issue "${issues}" "secret-shaped-content" "secret-shaped content remains in the canonical profile")"
    fi
  fi

  local issue_count warning_count result
  issue_count="$(printf '%s' "${issues}" | jq 'length')"
  warning_count="$(printf '%s' "${warnings}" | jq 'length')"
  result="$(jq -nc \
    --arg profile_id "${QC_PROFILE_ID}" \
    --arg path "${QC_CONSTITUTION}" \
    --argjson issues "${issues}" \
    --argjson warnings "${warnings}" \
    '{profile_id:$profile_id,path:$path,clean:($issues|length == 0),issues:$issues,warnings:$warnings}')"
  if (( json == 1 )); then
    printf '%s\n' "${result}"
  else
    printf 'Quality Constitution audit: %s issue(s), %s warning(s)\n' "${issue_count}" "${warning_count}"
    printf '%s' "${result}" | jq -r '(.issues[] | "  ERROR \(.code): \(.detail)"), (.warnings[] | "  WARN  \(.code): \(.detail)")'
  fi
  (( issue_count == 0 ))
}

cmd_apply_authorized() {
  local session_arg="" grant_id="" operation_b64="" operation="" canonical=""
  local active_session="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  while (( $# > 0 )); do
    case "$1" in
      --session-id) session_arg="${2:-}"; shift 2 ;;
      --grant) grant_id="${2:-}"; shift 2 ;;
      --operation-b64) operation_b64="${2:-}"; shift 2 ;;
      *) die "unknown apply-authorized argument: $1" ;;
    esac
  done
  [[ -n "${session_arg}" ]] || session_arg="${active_session}"
  [[ -n "${session_arg}" ]] || die "apply-authorized requires --session-id"
  validate_session_id "${session_arg}" || die "invalid authorization session id"
  if [[ -n "${active_session}" && "${session_arg}" != "${active_session}" ]]; then
    die "authorization session does not match the active Claude session"
  fi
  [[ "${grant_id}" =~ ^qca_[A-Za-z0-9._-]+$ ]] \
    || die "apply-authorized requires a valid --grant"
  [[ -n "${operation_b64}" ]] || die "apply-authorized requires --operation-b64"
  (( ${#operation_b64} <= 20000 )) || die "authorized operation is too large"
  if ! operation="$(qc_authority_base64_decode "${operation_b64}" 2>/dev/null)"; then
    die "authorized operation is not valid base64"
  fi
  (( ${#operation} <= 12000 )) || die "decoded authorized operation is too large"
  canonical="$(qc_authority_canonical_operation "${operation}" 2>/dev/null || true)"
  [[ -n "${canonical}" ]] || die "authorized operation failed its strict schema"

  SESSION_ID="${session_arg}"
  ensure_session_dir
  if ! with_state_lock qc_authority_consume_grant_unlocked \
      "${grant_id}" "${canonical}" "${QC_PROJECT_KEY}"; then
    die "no matching current one-use user authorization"
  fi
  QC_AUTHORITY_GRANT_ID="${grant_id}"
  QC_AUTHORITY_PROMPT_REVISION="${QC_AUTH_CONSUMED_PROMPT_REVISION:-$(read_state "prompt_revision" 2>/dev/null || true)}"
  QC_AUTHORITY_PROMPT_TS="${QC_AUTH_CONSUMED_PROMPT_TS:-$(read_state "last_user_prompt_ts" 2>/dev/null || true)}"

  local action
  action="$(jq -r '.action' <<<"${canonical}")"
  case "${action}" in
    add-claim)
      cmd_add_claim \
        --category "$(jq -r '.arguments.category' <<<"${canonical}")" \
        --statement "$(jq -r '.arguments.statement' <<<"${canonical}")" \
        --rationale "$(jq -r '.arguments.rationale' <<<"${canonical}")" \
        --polarity "$(jq -r '.arguments.polarity' <<<"${canonical}")" \
        --enforcement "$(jq -r '.arguments.enforcement' <<<"${canonical}")" \
        --authority "$(jq -r '.arguments.authority' <<<"${canonical}")" \
        --status "$(jq -r '.arguments.status' <<<"${canonical}")" \
        --domain "$(jq -r '.arguments.domain' <<<"${canonical}")" \
        --task-type "$(jq -r '.arguments.task_type' <<<"${canonical}")" \
        --surface "$(jq -r '.arguments.surface' <<<"${canonical}")" \
        --audience "$(jq -r '.arguments.audience' <<<"${canonical}")" \
        --path "$(jq -r '.arguments.path' <<<"${canonical}")"
      ;;
    accept)
      cmd_accept \
        "$(jq -r '.arguments.id' <<<"${canonical}")" \
        --enforcement "$(jq -r '.arguments.enforcement' <<<"${canonical}")"
      ;;
    reject)
      cmd_reject \
        "$(jq -r '.arguments.id' <<<"${canonical}")" \
        --reason "$(jq -r '.arguments.reason' <<<"${canonical}")"
      ;;
    add-reference)
      cmd_add_reference \
        --kind "$(jq -r '.arguments.kind' <<<"${canonical}")" \
        --locator "$(jq -r '.arguments.locator' <<<"${canonical}")" \
        --polarity "$(jq -r '.arguments.polarity' <<<"${canonical}")" \
        --because "$(jq -r '.arguments.because' <<<"${canonical}")" \
        --aspects "$(jq -r '.arguments.aspects' <<<"${canonical}")" \
        --do-not-copy "$(jq -r '.arguments.do_not_copy' <<<"${canonical}")"
      ;;
    remove)
      cmd_remove \
        "$(jq -r '.arguments.id' <<<"${canonical}")" \
        --reason "$(jq -r '.arguments.reason' <<<"${canonical}")"
      ;;
    *) die "authorized operation has an unsupported action" ;;
  esac
}

cmd_direct() {
  local nested="${1:-}"
  # This entrance is for a person deliberately curating the profile from a
  # standalone terminal. Environment variables are not evidence of humanity:
  # an assistant shell can unset or forge them. Requiring terminal-backed
  # stdin and stderr makes ordinary non-interactive tool execution fail at the
  # helper boundary even if a syntactic hook is bypassed. This remains a
  # cooperative same-user boundary, not authentication against a process that
  # deliberately manufactures a pseudo-terminal.
  if [[ ! -t 0 || ! -t 2 ]]; then
    die "direct mutations require an interactive human terminal (TTY on stdin and stderr); Claude/tool shells must use apply-authorized"
  fi
  [[ -n "${nested}" ]] || die "direct requires a mutation command"
  shift || true
  case "${nested}" in
    add-claim) cmd_add_claim "$@" ;;
    accept) cmd_accept "$@" ;;
    reject) cmd_reject "$@" ;;
    add-reference) cmd_add_reference "$@" ;;
    remove) cmd_remove "$@" ;;
    *) die "direct accepts only add-claim, accept, reject, add-reference, or remove" ;;
  esac
}

cmd_digest() {
  profile_digest
  printf '\n'
}

usage() {
  cat <<'USAGE'
quality-constitution.sh — user-owned project quality profile

Commands:
  resolve [--json]
  show [--json]
  apply-authorized --session-id ID --grant qca_ID --operation-b64 BASE64
  direct add-claim --statement TEXT [--category K] [--polarity P]
            [--enforcement advisory|blocking]
            [--authority user_confirmed|user_pinned|user_selected|inferred]
            [--rationale TEXT] [--domain D] [--task-type T] [--surface S]
  propose --statement TEXT --quote EXACT_USER_QUOTE --session-id ID
          [--signal correction|rejection|selection|praise|weak_selection]
          [--category K] [--polarity P] [--rationale TEXT] [--concept-key K]
  direct accept CANDIDATE_ID [--enforcement advisory|blocking]
  direct reject CANDIDATE_ID [--reason TEXT]
  direct add-reference --kind repo_path|url|description --locator VALUE
                --because TEXT [--polarity exemplar|anti_exemplar]
                [--aspects TEXT] [--do-not-copy TEXT]
  direct remove CLAIM_OR_REFERENCE_ID [--reason TEXT]
  compile [--role main|planner|reviewer] [--domain D]
          [--task-type T] [--surface S] [--audience A] [--path P]
          [--max-chars N] [--json]
  audit [--json]
  digest

Canonical data: ~/.claude/omc-user/quality-constitutions/
Taste learning: off suppresses propose; review keeps candidates pending;
adaptive may activate repeated independent evidence as inferred advisory only.
USAGE
}

main() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  resolve_paths
  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; return 0; }
  shift || true
  case "${command}" in
    audit|resolve|-h|--help|help) ;;
    *)
      canonical_storage_is_symlinked \
        && die "refusing symlinked canonical quality-constitution storage; run audit"
      ;;
  esac
  case "${command}" in
    add-claim|accept|reject|add-reference|remove)
      die "raw durable mutators are closed; a human terminal must use 'direct ${command}', while assistants must use apply-authorized"
      ;;
  esac
  case "${command}" in
    resolve) cmd_resolve "$@" ;;
    show) cmd_show "$@" ;;
    apply-authorized) cmd_apply_authorized "$@" ;;
    direct) cmd_direct "$@" ;;
    add-claim) cmd_add_claim "$@" ;;
    propose) cmd_propose "$@" ;;
    accept) cmd_accept "$@" ;;
    reject) cmd_reject "$@" ;;
    add-reference) cmd_add_reference "$@" ;;
    remove) cmd_remove "$@" ;;
    compile) cmd_compile "$@" ;;
    audit) cmd_audit "$@" ;;
    digest) cmd_digest "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown command: ${command}" ;;
  esac
}

main "$@"
