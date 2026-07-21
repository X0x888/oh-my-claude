# shellcheck shell=bash
# quality-constitution-authority.sh — causal user authority for durable taste.
#
# This library is sourced by the UserPromptSubmit router, the Constitution
# helper, and focused tests.  It intentionally keeps the authorization object
# in the per-session state directory while the durable Constitution stays in
# ~/.claude/omc-user/.  A grant is an exact-operation, one-use causal receipt;
# it is not a secret and is not an OS security boundary.

QC_AUTH_GRANT_FILE="quality_constitution_authorization.json"
QC_AUTH_GRANT_MAX_BYTES=4096
QC_CONSTITUTION_MAX_BYTES=67108864

qc_authority_hash_text() {
  local value=""
  if IFS= read -r -d '' value; then
    printf 'quality-constitution: NUL bytes are not valid authority material\n' >&2
    return 1
  fi
  # common.sh owns and seals the one trusted SHA implementation. Keep this
  # protocol library usable as a standalone parser fixture, but make hashing
  # fail explicitly when that authority primitive has not been loaded.
  if ! declare -F _verification_sha256_text >/dev/null 2>&1 \
      || ! _verification_sha256_text "${value}"; then
    printf 'quality-constitution: SHA-256 is required for authority identities\n' >&2
    return 1
  fi
}

qc_authority_sanitize_text() {
  local value="${1:-}" limit="${2:-600}"
  value="$(printf '%s' "${value}" \
    | tr '\r\n\t' '   ' \
    | _omc_strip_render_unsafe \
    | omc_redact_secrets)"
  value="$(trim_whitespace "${value}")"
  truncate_chars "${limit}" "${value}"
}

qc_authority_unquote() {
  local value="${1:-}"
  if (( ${#value} >= 2 )); then
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] \
        || [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "${value}"
}

# Split the reference grammar on the first unquoted literal ` because `.
# Results are returned in globals because command substitution would erase
# them in a subshell. Backslash escapes are deliberately unsupported: this is
# a narrow authority grammar, not a shell parser.
qc_authority_split_reference_payload() {
  local value="${1:-}" quote="" char="" i=0 length=0
  length="${#value}"
  QC_AUTH_REFERENCE_LOCATOR=""
  QC_AUTH_REFERENCE_BECAUSE=""
  for (( i = 0; i < length; i++ )); do
    char="${value:i:1}"
    if [[ -n "${quote}" ]]; then
      [[ "${char}" == "${quote}" ]] && quote=""
      continue
    fi
    case "${char}" in
      \"|\') quote="${char}" ;;
      *)
        if [[ "${value:i:9}" == " because " ]]; then
          QC_AUTH_REFERENCE_LOCATOR="$(trim_whitespace "${value:0:i}")"
          QC_AUTH_REFERENCE_BECAUSE="$(trim_whitespace "${value:i+9}")"
          [[ -n "${QC_AUTH_REFERENCE_LOCATOR}" \
              && -n "${QC_AUTH_REFERENCE_BECAUSE}" ]]
          return
        fi
        ;;
    esac
  done
  return 1
}

qc_authority_project_key() (
  # Project identity selects durable user-owned authority. Resolve it in a
  # sanitized subshell so inherited BASH_ENV functions cannot redirect git
  # observation, remote normalization, or hashing to a different profile.
  POSIXLY_CORRECT=1 || \return 1
  \unset -f builtin command printf read local type declare unset cd pwd \
    return git sed tr shasum sha256sum awk cut || \return 1
  local root="${1:-${PWD}}" key=""
  if declare -F _omc_project_key >/dev/null 2>&1; then
    key="$(cd "${root}" 2>/dev/null && _omc_project_key 2>/dev/null || true)"
  fi
  if [[ -z "${key}" ]]; then
    key="$(_verification_sha256_text "${root}" 2>/dev/null)" || return 1
    [[ "${key}" =~ ^[0-9a-f]{64}$ ]] || return 1
    key="${key:0:12}"
  fi
  printf '%s' "${key}"
)

# Side-effect-free schema authority shared by the durable helper and consumers
# that bind an immutable Constitution snapshot. Caps are explicit parameters so
# a consumer cannot silently validate a truncated projection with a lower local
# limit. The caller remains responsible for checking that `path` is the exact
# derived profile path for its project key.
qc_constitution_is_valid() {
  local path="${1:-}" claim_cap="${2:-500}" reference_cap="${3:-200}"
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  [[ -n "${path}" && -f "${path}" && ! -L "${path}" ]] || return 1
  [[ "${claim_cap}" =~ ^[1-9][0-9]*$ && "${reference_cap}" =~ ^[1-9][0-9]*$ ]] \
    || return 1
  (( claim_cap <= 500 && reference_cap <= 200 )) || return 1
  # jq accepts some literal NUL placements adjacent to scalars and can parse
  # the resulting byte stream as different JSON authority. Reject raw NUL and
  # oversize storage at the regular-file boundary before schema projection.
  declare -F _omc_regular_file_has_no_raw_nul >/dev/null 2>&1 || return 1
  _omc_regular_file_has_no_raw_nul \
    "${path}" "${QC_CONSTITUTION_MAX_BYTES}" || return 1
  jq -e \
    --argjson claim_cap "${claim_cap}" \
    --argjson reference_cap "${reference_cap}" '
    .schema_version == 1 and
    all(.. | strings; index("\u0000") == null) and
    (.profile_id | type == "string"
      and test("^qcp_[A-Za-z0-9._-]{1,128}$")) and
    (.generation | type == "number" and floor == . and . >= 0) and
    (.claims | type == "array" and length <= $claim_cap) and
    (.references | type == "array" and length <= $reference_cap) and
    (([.claims[].id, .references[].id] | unique | length) ==
     ((.claims | length) + (.references | length))) and
    (([.claims[],.references[] | select(has("last_operation_id")) | .last_operation_id] |
      unique | length) ==
     ([.claims[],.references[] | select(has("last_operation_id"))] | length)) and
    all(.claims[];
      (.id | type == "string"
        and test("^qc_[A-Za-z0-9._:-]{1,128}$")) and
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
      (.evidence_ids | type == "array" and length <= 50 and
       all(.[]; type == "string"
         and test("^qe_[A-Za-z0-9._:-]{1,128}$"))) and
      (.created_at | type == "number" and floor == . and . >= 0) and
      (.last_supported_at | type == "number" and floor == . and . >= 0) and
      (.review_after | type == "number" and floor == . and . >= 0) and
      (if has("source_candidate_id") then
         (.source_candidate_id | type == "string"
           and test("^qk_[A-Za-z0-9._:-]{1,128}$"))
       else true end) and
      (if has("last_operation_id") then
         (.last_operation_id | type == "string" and test("^qco_[0-9a-f]{16}$"))
       else true end)) and
    all(.references[];
      (.id | type == "string"
        and test("^qr_[A-Za-z0-9._:-]{1,128}$")) and
      (.polarity | IN("exemplar","anti_exemplar")) and
      (.kind | IN("repo_path","url","description")) and
      (.locator | type == "string" and length > 0 and length <= 1000 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.because | type == "string" and length > 0 and length <= 600 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.aspects | type == "string" and length <= 300 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.do_not_copy | type == "string" and length <= 400 and ([explode[] | select(. < 32 or . == 127)] | length == 0)) and
      (.authority | IN("user_pinned","user_confirmed")) and
      (.status | IN("active","stale","archived")) and
      (.added_at | type == "number" and floor == . and . >= 0) and
      (if has("last_operation_id") then
         (.last_operation_id | type == "string" and test("^qco_[0-9a-f]{16}$"))
       else true end))
  ' "${path}" >/dev/null 2>&1
}

qc_authority_operation_add_claim() {
  local category="$1" statement="$2" rationale="$3" polarity="$4"
  local enforcement="$5" authority="$6" status="$7" domain="$8"
  local task_type="$9"
  shift 9
  local surface="$1" audience="$2" path_scope="$3"
  jq -cS -n \
    --arg category "${category}" \
    --arg statement "${statement}" \
    --arg rationale "${rationale}" \
    --arg polarity "${polarity}" \
    --arg enforcement "${enforcement}" \
    --arg authority "${authority}" \
    --arg status "${status}" \
    --arg domain "${domain}" \
    --arg task_type "${task_type}" \
    --arg surface "${surface}" \
    --arg audience "${audience}" \
    --arg path "${path_scope}" \
    '{action:"add-claim",arguments:{
      category:$category,statement:$statement,rationale:$rationale,
      polarity:$polarity,enforcement:$enforcement,authority:$authority,
      status:$status,domain:$domain,task_type:$task_type,surface:$surface,
      audience:$audience,path:$path
    }}'
}

qc_authority_operation_accept() {
  jq -cS -n --arg id "$1" --arg enforcement "$2" \
    '{action:"accept",arguments:{id:$id,enforcement:$enforcement}}'
}

qc_authority_operation_reject() {
  jq -cS -n --arg id "$1" --arg reason "$2" \
    '{action:"reject",arguments:{id:$id,reason:$reason}}'
}

qc_authority_operation_add_reference() {
  jq -cS -n \
    --arg kind "$1" --arg locator "$2" --arg polarity "$3" \
    --arg because "$4" --arg aspects "$5" --arg do_not_copy "$6" \
    '{action:"add-reference",arguments:{kind:$kind,locator:$locator,
      polarity:$polarity,because:$because,aspects:$aspects,
      do_not_copy:$do_not_copy}}'
}

qc_authority_operation_remove() {
  jq -cS -n --arg id "$1" --arg reason "$2" \
    '{action:"remove",arguments:{id:$id,reason:$reason}}'
}

_qc_authority_canonical_operation_stream() {
  jq -cS -e '
    def control_free_string:
      type == "string" and
      ([explode[] | select(. < 32 or (. >= 127 and . <= 159))] | length == 0);
    select(
    type == "object" and
    (keys == ["action","arguments"]) and
    (.action | IN("add-claim","accept","reject","add-reference","remove")) and
    (.arguments | type == "object") and
    all(.. | strings; control_free_string) and
    (if .action == "add-claim" then
       (.arguments | keys == ["audience","authority","category","domain","enforcement","path","polarity","rationale","statement","status","surface","task_type"]) and
       (.arguments.category | IN("mission","audience","outcome","quality_floor","principle","signature","voice","workflow","non_goal","anti_pattern","vision")) and
       (.arguments.statement | type == "string" and length > 0 and length <= 600) and
       (.arguments.rationale | type == "string" and length <= 600) and
       (.arguments.polarity | IN("must","must_not","prefer","avoid","aspire")) and
       (.arguments.enforcement | IN("blocking","advisory")) and
       (.arguments.authority | IN("user_confirmed","user_pinned")) and
       (.arguments.status == "active") and
       ((.arguments.enforcement != "blocking") or
        (.arguments.polarity | IN("must","must_not"))) and
       all([.arguments.domain,.arguments.task_type,.arguments.surface,
            .arguments.audience,.arguments.path][];
           type == "string" and length <= 240)
     elif .action == "accept" then
       (.arguments | keys == ["enforcement","id"]) and
       (.arguments.id | type == "string" and test("^qk_[A-Za-z0-9._-]+$")) and
       (.arguments.enforcement | IN("advisory","blocking"))
     elif .action == "reject" then
       (.arguments | keys == ["id","reason"]) and
       (.arguments.id | type == "string" and test("^qk_[A-Za-z0-9._-]+$")) and
       (.arguments.reason | type == "string" and length <= 300)
     elif .action == "add-reference" then
       (.arguments | keys == ["aspects","because","do_not_copy","kind","locator","polarity"]) and
       (.arguments.kind | IN("repo_path","url","description")) and
       (.arguments.locator | type == "string" and length > 0 and length <= 1000) and
       (.arguments.polarity | IN("exemplar","anti_exemplar")) and
       (.arguments.because | type == "string" and length > 0 and length <= 600) and
       (.arguments.aspects | type == "string" and length <= 300) and
       (.arguments.do_not_copy | type == "string" and length <= 400)
     else
       (.arguments | keys == ["id","reason"]) and
       (.arguments.id | type == "string" and test("^(qc|qr)_[A-Za-z0-9._-]+$")) and
       (.arguments.reason | type == "string" and length <= 300)
     end)
    )
  '
}

qc_authority_validate_operation() {
  local operation="${1:-}"
  printf '%s' "${operation}" \
    | _qc_authority_canonical_operation_stream >/dev/null 2>&1
}

qc_authority_canonical_operation() {
  local operation="${1:-}"
  printf '%s' "${operation}" | _qc_authority_canonical_operation_stream
}

qc_authority_operation_digest() {
  qc_authority_canonical_operation "$1" | qc_authority_hash_text
}

qc_authority_base64_encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

qc_authority_base64_decode() {
  local encoded="${1:-}"
  if printf '' | base64 --decode >/dev/null 2>&1; then
    printf '%s' "${encoded}" | base64 --decode \
      | _qc_authority_canonical_operation_stream
  else
    printf '%s' "${encoded}" | base64 -D \
      | _qc_authority_canonical_operation_stream
  fi
}

# Parse only the deliberately narrow, user-owned slash grammar.  Descriptive
# mentions and ambiguous natural language never mint durable authority.
# Output is canonical operation JSON; non-mutation/read commands return 1.
qc_authority_operation_from_prompt() {
  local prompt="${1:-}" rest="" verb="" payload="" statement=""
  local id="" enforcement="advisory" reason="" locator="" because=""
  local kind="" polarity="exemplar"
  prompt="$(qc_authority_sanitize_text "${prompt}" 4000)"
  case "${prompt}" in
    /quality-constitution|/quality-constitution\ *) ;;
    *) return 1 ;;
  esac
  rest="$(trim_whitespace "${prompt#/quality-constitution}")"
  [[ -n "${rest}" ]] || return 1
  verb="${rest%% *}"
  if [[ "${rest}" == "${verb}" ]]; then
    payload=""
  else
    payload="$(trim_whitespace "${rest#* }")"
  fi
  case "${verb}" in
    remember)
      payload="$(qc_authority_unquote "${payload}")"
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "principle" "${statement}" "" "prefer" "advisory" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    must)
      payload="$(qc_authority_unquote "${payload}")"
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "principle" "${statement}" "" "must" "blocking" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    must-not|must_not)
      payload="$(qc_authority_unquote "${payload}")"
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "anti_pattern" "${statement}" "" "must_not" "blocking" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    avoid)
      payload="$(qc_authority_unquote "${payload}")"
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "anti_pattern" "${statement}" "" "avoid" "advisory" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    accept)
      id="${payload%% *}"
      [[ "${id}" =~ ^qk_[A-Za-z0-9._-]+$ ]] || return 1
      case "$(trim_whitespace "${payload#"${id}"}")" in
        "") enforcement="advisory" ;;
        blocking|"as blocking") enforcement="blocking" ;;
        *) return 1 ;;
      esac
      qc_authority_operation_accept "${id}" "${enforcement}"
      ;;
    reject)
      id="${payload%% *}"
      [[ "${id}" =~ ^qk_[A-Za-z0-9._-]+$ ]] || return 1
      reason="$(trim_whitespace "${payload#"${id}"}")"
      [[ "${reason}" == because\ * ]] && reason="${reason#because }"
      reason="$(qc_authority_unquote "${reason}")"
      reason="$(qc_authority_sanitize_text "${reason}" 300)"
      qc_authority_operation_reject "${id}" "${reason}"
      ;;
    remove)
      id="${payload%% *}"
      [[ "${id}" =~ ^(qc|qr)_[A-Za-z0-9._-]+$ ]] || return 1
      reason="$(trim_whitespace "${payload#"${id}"}")"
      [[ "${reason}" == because\ * ]] && reason="${reason#because }"
      reason="$(qc_authority_unquote "${reason}")"
      reason="$(qc_authority_sanitize_text "${reason}" 300)"
      qc_authority_operation_remove "${id}" "${reason}"
      ;;
    reference|anti-reference)
      [[ "${verb}" == "anti-reference" ]] && polarity="anti_exemplar"
      qc_authority_split_reference_payload "${payload}" || return 1
      locator="${QC_AUTH_REFERENCE_LOCATOR}"
      because="${QC_AUTH_REFERENCE_BECAUSE}"
      locator="$(qc_authority_unquote "${locator}")"
      because="$(qc_authority_unquote "${because}")"
      locator="$(qc_authority_sanitize_text "${locator}" 1000)"
      because="$(qc_authority_sanitize_text "${because}" 600)"
      [[ -n "${locator}" && -n "${because}" ]] || return 1
      case "${locator}" in
        https://*) kind="url" ;;
        /*) kind="description" ;;
        *)
          if [[ -e "${PWD}/${locator}" ]]; then
            kind="repo_path"
          else
            kind="description"
          fi
          ;;
      esac
      qc_authority_operation_add_reference \
        "${kind}" "${locator}" "${polarity}" "${because}" "" ""
      ;;
    show|review|audit|compile|propose)
      return 1
      ;;
    *) return 1 ;;
  esac
}

qc_authority_grant_path() {
  session_file "${QC_AUTH_GRANT_FILE}"
}

qc_authority_clear_grant_unlocked() {
  local path
  path="$(qc_authority_grant_path)"
  rm -f "${path}" 2>/dev/null || return 1
}

qc_authority_issue_grant_unlocked() {
  local operation="$1" project_key="$2" prompt_revision="$3" prompt_ts="$4"
  local canonical digest action now grant_id session_digest path tmp grant
  canonical="$(qc_authority_canonical_operation "${operation}")" || return 1
  digest="$(printf '%s' "${canonical}" | qc_authority_hash_text)"
  action="$(printf '%s' "${canonical}" | jq -r '.action')"
  now="$(now_epoch)"
  session_digest="$(printf '%s' "${SESSION_ID}" | qc_authority_hash_text)"
  grant_id="qca_$(printf '%s' "${SESSION_ID}:${prompt_revision}:${digest}:$$:${RANDOM}:${now}" \
    | qc_authority_hash_text | cut -c1-20)"
  grant="$(jq -cS -n \
    --arg id "${grant_id}" \
    --arg session_digest "${session_digest}" \
    --arg project_key "${project_key}" \
    --arg action "${action}" \
    --arg operation_digest "${digest}" \
    --argjson prompt_revision "${prompt_revision}" \
    --argjson prompt_ts "${prompt_ts}" \
    --argjson issued_at "${now}" \
    '{_v:1,grant_id:$id,session_id_digest:$session_digest,
      project_key:$project_key,prompt_revision:$prompt_revision,
      prompt_ts:$prompt_ts,action:$action,operation_digest:$operation_digest,
      issued_at:$issued_at}')"
  path="$(qc_authority_grant_path)"
  qc_authority_clear_grant_unlocked || return 1
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "${grant}" >"${tmp}"; then
    rm -f "${tmp}" 2>/dev/null || true
    return 1
  fi
  chmod 600 "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${path}" || {
    rm -f "${tmp}" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "${grant}"
}

# Validate the bounded regular grant directly from the file before any bytes
# enter a Bash variable. Raw NUL is rejected byte-for-byte before jq, while
# escaped NUL/C0/C1 values fail the recursive string check. The canonical
# output is the only representation that may cross into Bash afterward.
qc_authority_read_grant_file() {
  local path="${1:-}"
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  [[ -n "${path}" && -f "${path}" && ! -L "${path}" ]] || return 1
  declare -F _omc_regular_file_has_no_raw_nul >/dev/null 2>&1 || return 1
  _omc_regular_file_has_no_raw_nul \
    "${path}" "${QC_AUTH_GRANT_MAX_BYTES}" || return 1
  jq -cS -e -s '
    def control_free_string:
      type == "string" and
      ([explode[] | select(. < 32 or (. >= 127 and . <= 159))] | length == 0);
    select(
      length == 1 and
      (.[0] |
        type == "object" and
        (keys == ["_v","action","grant_id","issued_at","operation_digest",
                  "project_key","prompt_revision","prompt_ts","session_id_digest"]) and
        ._v == 1 and
        (.grant_id | type == "string" and test("^qca_[0-9a-f]{20}$")) and
        (.session_id_digest | type == "string" and test("^[0-9a-f]{64}$")) and
        (.project_key | type == "string" and test("^[0-9a-f]{12}$")) and
        (.prompt_revision | type == "number" and floor == . and . > 0) and
        (.prompt_ts | type == "number" and floor == . and . > 0) and
        (.action | IN("add-claim","accept","reject","add-reference","remove")) and
        (.operation_digest | type == "string" and test("^[0-9a-f]{64}$")) and
        (.issued_at | type == "number" and floor == . and . > 0) and
        all(.. | strings; control_free_string)
      )
    )
    | .[0]
  ' "${path}" 2>/dev/null
}

qc_authority_consume_grant_unlocked() {
  local grant_id="$1" operation="$2" project_key="$3"
  local canonical digest action path grant current_revision current_prompt_ts
  canonical="$(qc_authority_canonical_operation "${operation}")" || {
    printf 'quality-constitution: authorized operation is malformed\n' >&2
    return 1
  }
  digest="$(printf '%s' "${canonical}" | qc_authority_hash_text)"
  action="$(printf '%s' "${canonical}" | jq -r '.action')"
  path="$(qc_authority_grant_path)"
  if [[ ! -f "${path}" || -L "${path}" ]]; then
    printf 'quality-constitution: no current regular-file user authorization grant\n' >&2
    return 1
  fi
  if ! grant="$(qc_authority_read_grant_file "${path}")"; then
    printf 'quality-constitution: malformed user authorization grant\n' >&2
    return 1
  fi
  current_revision="$(read_state "prompt_revision" 2>/dev/null || true)"
  current_prompt_ts="$(read_state "last_user_prompt_ts" 2>/dev/null || true)"
  if [[ "$(jq -r '.grant_id' <<<"${grant}")" != "${grant_id}" \
      || "$(jq -r '.session_id_digest' <<<"${grant}")" != "$(printf '%s' "${SESSION_ID}" | qc_authority_hash_text)" \
      || "$(jq -r '.project_key' <<<"${grant}")" != "${project_key}" \
      || "$(jq -r '.prompt_revision' <<<"${grant}")" != "${current_revision}" \
      || "$(jq -r '.prompt_ts' <<<"${grant}")" != "${current_prompt_ts}" \
      || "$(jq -r '.action' <<<"${grant}")" != "${action}" \
      || "$(jq -r '.operation_digest' <<<"${grant}")" != "${digest}" ]]; then
    printf 'quality-constitution: user authorization does not match this exact current operation\n' >&2
    return 1
  fi
  # Consume before the durable mutation. A crash may spend a grant without a
  # write, but can never produce a write that remains replayable.
  rm -f "${path}" || return 1
  QC_AUTH_CONSUMED_GRANT_ID="${grant_id}"
  QC_AUTH_CONSUMED_PROMPT_REVISION="${current_revision}"
  QC_AUTH_CONSUMED_PROMPT_TS="${current_prompt_ts}"
  return 0
}
