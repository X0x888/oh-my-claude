# shellcheck shell=bash
# quality-constitution-authority.sh — causal user authority for durable taste.
#
# This library is sourced by the UserPromptSubmit router, the Constitution
# helper, and focused tests.  It intentionally keeps the authorization object
# in the per-session state directory while the durable Constitution stays in
# ~/.claude/omc-user/.  A grant is an exact-operation, one-use causal receipt;
# it is not a secret and is not an OS security boundary.

QC_AUTH_GRANT_FILE="quality_constitution_authorization.json"

qc_authority_hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1 "-" $2}'
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

qc_authority_project_key() {
  local root="${1:-${PWD}}" key=""
  if declare -F _omc_project_key >/dev/null 2>&1; then
    key="$(cd "${root}" 2>/dev/null && _omc_project_key 2>/dev/null || true)"
  fi
  if [[ -z "${key}" ]]; then
    key="$(printf '%s' "${root}" | qc_authority_hash_text | cut -c1-12)"
  fi
  printf '%s' "${key}"
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

qc_authority_validate_operation() {
  local operation="${1:-}"
  printf '%s' "${operation}" | jq -e '
    type == "object" and
    (keys == ["action","arguments"]) and
    (.action | IN("add-claim","accept","reject","add-reference","remove")) and
    (.arguments | type == "object") and
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
  ' >/dev/null 2>&1
}

qc_authority_canonical_operation() {
  local operation="${1:-}"
  qc_authority_validate_operation "${operation}" || return 1
  printf '%s' "${operation}" | jq -cS .
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
    printf '%s' "${encoded}" | base64 --decode
  else
    printf '%s' "${encoded}" | base64 -D
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
  payload="$(qc_authority_unquote "${payload}")"

  case "${verb}" in
    remember)
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "principle" "${statement}" "" "prefer" "advisory" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    must)
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "principle" "${statement}" "" "must" "blocking" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    must-not|must_not)
      statement="$(qc_authority_sanitize_text "${payload}" 600)"
      [[ -n "${statement}" ]] || return 1
      qc_authority_operation_add_claim \
        "anti_pattern" "${statement}" "" "must_not" "blocking" \
        "user_confirmed" "active" "" "" "" "" ""
      ;;
    avoid)
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
      reason="$(qc_authority_sanitize_text "${reason}" 300)"
      qc_authority_operation_reject "${id}" "${reason}"
      ;;
    remove)
      id="${payload%% *}"
      [[ "${id}" =~ ^(qc|qr)_[A-Za-z0-9._-]+$ ]] || return 1
      reason="$(trim_whitespace "${payload#"${id}"}")"
      [[ "${reason}" == because\ * ]] && reason="${reason#because }"
      reason="$(qc_authority_sanitize_text "${reason}" 300)"
      qc_authority_operation_remove "${id}" "${reason}"
      ;;
    reference|anti-reference)
      [[ "${verb}" == "anti-reference" ]] && polarity="anti_exemplar"
      [[ "${payload}" == *" because "* ]] || return 1
      locator="$(trim_whitespace "${payload%% because *}")"
      because="$(trim_whitespace "${payload#* because }")"
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
  grant="$(<"${path}")"
  if ! printf '%s' "${grant}" | jq -e '
      ._v == 1 and
      (.grant_id | type == "string" and startswith("qca_")) and
      (.session_id_digest | type == "string" and length > 0) and
      (.project_key | type == "string" and length > 0) and
      (.prompt_revision | type == "number" and floor == . and . > 0) and
      (.prompt_ts | type == "number" and floor == . and . > 0) and
      (.action | IN("add-claim","accept","reject","add-reference","remove")) and
      (.operation_digest | type == "string" and length > 0) and
      (.issued_at | type == "number" and floor == . and . > 0)
    ' >/dev/null 2>&1; then
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
