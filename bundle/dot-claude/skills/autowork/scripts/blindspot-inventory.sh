#!/usr/bin/env bash
# blindspot-inventory.sh — project surface inventory for /ulw intent-broadening.
#
# Generates `~/.claude/quality-pack/blindspots/<project_key>.json`, an
# enumeration of the project's known surfaces (routes, env vars, tests,
# docs, config flags, UI files, error states, release steps, auth paths,
# scripts) so the intent-broadening directive can give the model a
# concrete inventory to reconcile its task against — defending against
# the "user prompt is a limitation" failure mode where a complex request
# silently misses a surface the prompt didn't name.
#
# Subcommands:
#   scan [--force]   Regenerate the inventory (no-op when cached + fresh)
#   show             Print the cached inventory JSON to stdout
#   path             Print the cache path to stdout (always — even if missing)
#   stale            Exit 0 when cache is missing or older than TTL, else 1
#   summary          Print a one-paragraph human-readable summary
#
# Cache TTL: OMC_BLINDSPOT_TTL_SECONDS (default 86400 = 24h).
# Privacy: respects `blindspot_inventory=off` in oh-my-claude.conf — when
# disabled, scan/show/summary all exit 0 with no output (kill switch).
#
# Exit codes:
#   0 — success / cache valid / disabled-with-no-error
#   1 — runtime failure (jq missing, write error)
#   2 — invalid invocation
#
# Designed to be both model-invokable (when the intent-broadening directive
# fires) AND cron/CI-invokable (run in the background via /loop or similar).
# Generation is bounded — caps at 50 entries per surface, skips vendored
# directories — so a typical scan completes in under 2 seconds.

set -euo pipefail

. "${HOME}/.claude/skills/autowork/scripts/common.sh"

# Constants -------------------------------------------------------------------

BLINDSPOT_DIR="${HOME}/.claude/quality-pack/blindspots"
BLINDSPOT_TTL="${OMC_BLINDSPOT_TTL_SECONDS:-86400}"
SURFACE_CAP=50

# Vendor / build dirs we never scan (silent skip — these are not "the project")
EXCLUDE_DIRS=(
  '.git' 'node_modules' '.next' '.nuxt' 'dist' 'build' 'out' 'target'
  '.venv' 'venv' '.tox' '__pycache__' 'vendor' 'bower_components'
  'Pods' 'Carthage' 'DerivedData' '.build' '.gradle' '.idea'
  'coverage' '.cache' '.parcel-cache' '.turbo' '.svelte-kit'
)

# Helpers ---------------------------------------------------------------------

# Local alias for the canonical helper sourced from common.sh. Kept as a
# function (not a variable) so the rest of this script reads identically;
# delegates to the shared definition so the conf/env-flag semantics stay
# in one place.
is_blindspot_enabled() {
  is_blindspot_inventory_enabled
}

# project_key with stable fallback when not in a git repo or git missing.
# Mirrors _omc_project_key but accepts an explicit project root.
project_key_for_root() {
  local root="$1"
  if [[ -d "${root}/.git" ]] && command -v git >/dev/null 2>&1; then
    local remote_url
    remote_url="$(git -C "${root}" config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "${remote_url}" ]]; then
      local norm="${remote_url}"
      if [[ "${norm}" =~ ^[a-zA-Z][a-zA-Z+.-]*:// ]]; then
        norm="$(printf '%s' "${norm}" | sed -E 's|^[a-zA-Z][a-zA-Z+.-]*://([^/@]*@)?||; s|:[0-9]+(/\|$)|\1|')"
      else
        norm="$(printf '%s' "${norm}" | sed -E 's|^[^@]+@||; s|:|/|')"
      fi
      norm="$(printf '%s' "${norm}" | sed -E 's|\.git/?$||; s|/+$||' | tr '[:upper:]' '[:lower:]')"
      printf '%s' "${norm}" | shasum -a 256 2>/dev/null | cut -c1-12
      return 0
    fi
  fi
  printf '%s' "${root}" | shasum -a 256 2>/dev/null | cut -c1-12
}

# cache_path_for_root <project_root>
cache_path_for_root() {
  local root="$1" key
  key="$(project_key_for_root "${root}")"
  printf '%s/%s.json' "${BLINDSPOT_DIR}" "${key}"
}

# Build a `find` exclude expression from EXCLUDE_DIRS for use with `-prune`.
# Returns the expression as separate arguments via printf so the caller can
# expand it into a find invocation. Bash 3.2 compatible.
emit_find_excludes() {
  local d
  local first=1
  for d in "${EXCLUDE_DIRS[@]}"; do
    if [[ "${first}" -eq 1 ]]; then
      first=0
      printf -- '-name\n%s\n' "${d}"
    else
      printf -- '-o\n-name\n%s\n' "${d}"
    fi
  done
}

# Run grep across the project, scoped + bounded.
# Args: <pattern> <root> [include glob...] — emits "file:line:match"
scoped_grep() {
  local pattern="$1" root="$2"
  shift 2
  local include_args=()
  local g
  for g in "$@"; do
    include_args+=("--include=${g}")
  done
  local exclude_args=()
  for g in "${EXCLUDE_DIRS[@]}"; do
    exclude_args+=("--exclude-dir=${g}")
  done
  grep -rEn "${pattern}" "${root}" \
    "${include_args[@]}" \
    "${exclude_args[@]}" \
    2>/dev/null \
    | head -n "${SURFACE_CAP}" || true
}

# Detect project type so we run the right surface detectors. Returns one
# of: web, ios, macos, python, go, bash, polyglot, unknown.
detect_project_type() {
  local root="$1"
  local has_pkg=0 has_swift=0 has_python=0 has_go=0 has_bash=0 has_macos_marker=0

  [[ -f "${root}/package.json" ]] && has_pkg=1
  [[ -f "${root}/Package.swift" || -d "${root}/$(basename "${root}").xcodeproj" ]] && has_swift=1
  [[ -f "${root}/pyproject.toml" || -f "${root}/setup.py" || -f "${root}/requirements.txt" ]] && has_python=1
  [[ -f "${root}/go.mod" ]] && has_go=1

  # Bash project signal: any *.sh in top 2 levels OR install.sh-like marker.
  if find "${root}" -maxdepth 2 -name '*.sh' -type f 2>/dev/null | head -1 | grep -q .; then
    has_bash=1
  fi

  if [[ "${has_swift}" -eq 1 ]]; then
    if [[ -f "${root}/Package.swift" ]] && grep -qE '\.macOS\b|\.macCatalyst\b' "${root}/Package.swift" 2>/dev/null; then
      has_macos_marker=1
    fi
    if [[ "${has_macos_marker}" -eq 1 ]]; then
      printf 'macos'; return
    fi
    printf 'ios'; return
  fi

  local count=0
  (( has_pkg )) && count=$((count + 1))
  (( has_python )) && count=$((count + 1))
  (( has_go )) && count=$((count + 1))
  (( has_bash )) && count=$((count + 1))

  if (( count >= 2 )); then
    printf 'polyglot'; return
  fi
  if (( has_pkg )); then printf 'web'; return; fi
  if (( has_python )); then printf 'python'; return; fi
  if (( has_go )); then printf 'go'; return; fi
  if (( has_bash )); then printf 'bash'; return; fi
  printf 'unknown'
}

# Detect surfaces -------------------------------------------------------------

# Each detector emits NDJSON (one object per line) on stdout; an empty
# detector emits nothing. The aggregator collects them into a JSON array.

detect_routes() {
  local root="$1" type="$2"
  # Strip the project root from each emitted file path so route entries
  # match the relative-path convention every other detector follows. Also
  # trim leading whitespace from the match string (awk's `$1=$2=""` leaves
  # a leading separator artifact). Pass the root via -v so awk sees it.
  case "${type}" in
    web|polyglot)
      # Express / Hono / Koa / Fastify: app.METHOD('/path', ...)
      scoped_grep \
        "(app|router|server)\.(get|post|put|patch|delete|head|options)\s*\(['\"][^'\"]+['\"]" \
        "${root}" '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' \
        | awk -F: -v root="${root}/" '{
            file=$1; line=$2; $1=$2=""; sub(/^::/,""); sub(/^[ \t]+/,"");
            sub(root, "", file);
            printf "{\"file\":\"%s\",\"line\":%s,\"match\":\"%s\"}\n", file, line, substr($0,1,140)
          }' \
        | jq -c 'select(.file != null)' 2>/dev/null || true
      # Next.js: app/**/route.ts | pages/api/*.ts
      find "${root}" -type f \( -name 'route.ts' -o -name 'route.tsx' -o -name 'route.js' \) 2>/dev/null \
        | grep -E '/(app|pages)/' | head -n "${SURFACE_CAP}" \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"nextjs-route"}'
          done || true
      ;;
    python)
      # FastAPI / Flask: @app.METHOD or @router.METHOD
      scoped_grep \
        "@(app|router|api|bp)\.(get|post|put|patch|delete|route)\(" \
        "${root}" '*.py' \
        | awk -F: -v root="${root}/" '{
            file=$1; line=$2; $1=$2=""; sub(/^::/,""); sub(/^[ \t]+/,"");
            sub(root, "", file);
            printf "{\"file\":\"%s\",\"line\":%s,\"match\":\"%s\"}\n", file, line, substr($0,1,140)
          }' \
        | jq -c 'select(.file != null)' 2>/dev/null || true
      ;;
    go)
      # net/http and chi/gin: r.METHOD or http.HandleFunc
      scoped_grep \
        "(HandleFunc|\.(GET|POST|PUT|PATCH|DELETE|Get|Post|Put|Patch|Delete))\s*\(" \
        "${root}" '*.go' \
        | awk -F: -v root="${root}/" '{
            file=$1; line=$2; $1=$2=""; sub(/^::/,""); sub(/^[ \t]+/,"");
            sub(root, "", file);
            printf "{\"file\":\"%s\",\"line\":%s,\"match\":\"%s\"}\n", file, line, substr($0,1,140)
          }' \
        | jq -c 'select(.file != null)' 2>/dev/null || true
      ;;
  esac
}

detect_env_vars() {
  local root="$1" type="$2"

  # Node-style env vars — fires for web AND polyglot.
  if [[ "${type}" == "web" || "${type}" == "polyglot" ]]; then
    scoped_grep "process\.env\.[A-Z_][A-Z0-9_]*" "${root}" \
      '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' \
      | grep -oE 'process\.env\.[A-Z_][A-Z0-9_]*' | sort -u | head -n "${SURFACE_CAP}" \
      | while IFS= read -r v; do
          jq -nc --arg name "${v#process.env.}" '{name:$name,kind:"node-env"}'
        done || true
  fi

  # Python env vars — fires for python AND polyglot.
  if [[ "${type}" == "python" || "${type}" == "polyglot" ]]; then
    scoped_grep "(os\.environ\.get|os\.getenv)\s*\(\s*['\"][A-Z_][A-Z0-9_]*['\"]" \
      "${root}" '*.py' \
      | grep -oE "['\"][A-Z_][A-Z0-9_]+['\"]" | tr -d "'\"" | sort -u | head -n "${SURFACE_CAP}" \
      | while IFS= read -r v; do
          jq -nc --arg name "${v}" '{name:$name,kind:"python-env"}'
        done || true
  fi

  # Go env vars — fires for go AND polyglot.
  if [[ "${type}" == "go" || "${type}" == "polyglot" ]]; then
    scoped_grep "os\.Getenv\s*\(\s*\"[A-Z_][A-Z0-9_]*\"" "${root}" '*.go' \
      | grep -oE '"[A-Z_][A-Z0-9_]+"' | tr -d '"' | sort -u | head -n "${SURFACE_CAP}" \
      | while IFS= read -r v; do
          jq -nc --arg name "${v}" '{name:$name,kind:"go-env"}'
        done || true
  fi

  # Bash env vars — fires for bash AND polyglot. Multiple checks per type
  # are intentional (polyglot projects have multiple language surfaces).
  if [[ "${type}" == "bash" || "${type}" == "polyglot" ]]; then
    scoped_grep '\$\{[A-Z][A-Z0-9_]+\}|\$[A-Z][A-Z0-9_]+' \
      "${root}" '*.sh' \
      | grep -oE '\$\{?[A-Z][A-Z0-9_]+\}?' \
      | tr -d '${}' | sort -u | head -n "${SURFACE_CAP}" \
      | while IFS= read -r v; do
          case "${v}" in
            HOME|PATH|PWD|USER|SHELL|TERM|LANG|EDITOR|UID|GID|RANDOM|HOSTNAME|OSTYPE|BASH|BASH_VERSION|FUNCNAME|LINENO) continue ;;
          esac
          jq -nc --arg name "${v}" '{name:$name,kind:"bash-env"}'
        done || true
  fi

  # .env files — language-agnostic.
  find "${root}" -maxdepth 3 -type f \( -name '.env*' -o -name '*.env.example' \) 2>/dev/null \
    | grep -v node_modules | head -n 10 \
    | while IFS= read -r f; do
        jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"env-file"}'
      done || true
}

detect_tests() {
  local root="$1" type="$2"
  local count=0
  case "${type}" in
    web|polyglot)
      count=$(find "${root}" -type f \
        \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' \) \
        2>/dev/null | grep -vE '/(node_modules|dist|build)/' | wc -l | tr -d ' ')
      jq -nc --arg framework "jest-or-vitest" --arg count "${count}" '{framework:$framework,count:($count|tonumber)}'
      ;;
    python)
      count=$(find "${root}" -type f \
        \( -name 'test_*.py' -o -name '*_test.py' \) \
        2>/dev/null | grep -vE '/(\.venv|venv|__pycache__)/' | wc -l | tr -d ' ')
      jq -nc --arg framework "pytest" --arg count "${count}" '{framework:$framework,count:($count|tonumber)}'
      ;;
    go)
      count=$(find "${root}" -type f -name '*_test.go' 2>/dev/null | wc -l | tr -d ' ')
      jq -nc --arg framework "go-test" --arg count "${count}" '{framework:$framework,count:($count|tonumber)}'
      ;;
    bash)
      count=$(find "${root}" -type f \
        \( -name 'test-*.sh' -o -name '*_test.sh' -o -name 'test_*.sh' \) \
        2>/dev/null | wc -l | tr -d ' ')
      jq -nc --arg framework "bash" --arg count "${count}" '{framework:$framework,count:($count|tonumber)}'
      ;;
    ios|macos)
      count=$(find "${root}" -type f \( -name '*Tests.swift' -o -name 'Test*.swift' \) \
        2>/dev/null | grep -vE '/(\.build|DerivedData|Pods)/' | wc -l | tr -d ' ')
      jq -nc --arg framework "xctest" --arg count "${count}" '{framework:$framework,count:($count|tonumber)}'
      ;;
    *)
      jq -nc --arg framework "unknown" '{framework:$framework,count:0}'
      ;;
  esac
}

detect_docs() {
  local root="$1"
  # Top-level + docs/ markdown files
  find "${root}" -type f -name '*.md' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' \
    -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/vendor/*' \
    2>/dev/null | head -n "${SURFACE_CAP}" \
    | while IFS= read -r f; do
        local rel="${f#${root}/}"
        local kind="docs"
        case "${rel}" in
          README*) kind="readme" ;;
          CHANGELOG*) kind="changelog" ;;
          CLAUDE*) kind="claude-md" ;;
          AGENTS*) kind="agents-md" ;;
          CONTRIBUTING*) kind="contributing" ;;
          docs/*) kind="docs" ;;
        esac
        jq -nc --arg file "${rel}" --arg kind "${kind}" '{file:$file,kind:$kind}'
      done || true
}

detect_config_flags() {
  local root="$1"
  # oh-my-claude conf — check anywhere in the tree (canonical path is
  # ~/.claude/, but installers + project-mode vendor `bundle/dot-claude/
  # oh-my-claude.conf.example` for distribution).
  local conf
  conf="$(find "${root}" -maxdepth 5 -type f \
      \( -name 'oh-my-claude.conf' -o -name 'oh-my-claude.conf.example' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' \
      2>/dev/null | head -1)"
  if [[ -n "${conf}" && -f "${conf}" ]]; then
    # Match both `flag=value` (set) and `#flag=value` (documented in
    # the example template). The .example file ships every flag commented
    # so users can uncomment to opt in — we want both shapes captured.
    grep -E '^#?[a-z_][a-z0-9_]*=' "${conf}" 2>/dev/null \
      | head -n "${SURFACE_CAP}" \
      | while IFS= read -r line; do
          local key="${line%%=*}"
          key="${key#\#}"
          jq -nc --arg name "${key}" --arg file "${conf#${root}/}" '{name:$name,file:$file,kind:"omc-conf"}'
        done || true
  fi
  # YAML / JSON config files at top level
  find "${root}" -maxdepth 2 -type f \
    \( -name '*.config.js' -o -name '*.config.ts' -o -name 'config.*.json' -o -name 'tsconfig*.json' \) \
    -not -path '*/node_modules/*' \
    2>/dev/null | head -n 10 \
    | while IFS= read -r f; do
        jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"config-file"}'
      done || true
  # Bash project hook entry points — Claude Code settings.json + agent
  # frontmatter declarations are config-shaped surfaces too.
  find "${root}" -maxdepth 4 -type f \
    \( -name 'settings.json' -o -name 'settings.patch.json' \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' \
    2>/dev/null | head -n 5 \
    | while IFS= read -r f; do
        jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"hook-config"}'
      done || true
}

detect_ui_files() {
  local root="$1" type="$2"
  case "${type}" in
    web|polyglot)
      find "${root}" -type f \
        \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) \
        -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/.next/*' \
        2>/dev/null | head -n "${SURFACE_CAP}" \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file}'
          done || true
      ;;
    ios|macos)
      find "${root}" -type f \
        \( -name '*View.swift' -o -name '*Screen.swift' -o -name '*Cell.swift' \) \
        -not -path '*/.build/*' -not -path '*/Pods/*' -not -path '*/DerivedData/*' \
        2>/dev/null | head -n "${SURFACE_CAP}" \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file}'
          done || true
      ;;
  esac
}

detect_release_steps() {
  local root="$1"
  local found=""
  # Look for an explicit release checklist in CLAUDE.md / RELEASE.md / docs/
  for candidate in CLAUDE.md docs/RELEASE.md docs/RELEASING.md RELEASE.md RELEASING.md docs/release.md; do
    if [[ -f "${root}/${candidate}" ]]; then
      if grep -qiE 'release|version|bump|tag|changelog' "${root}/${candidate}" 2>/dev/null; then
        local lineno
        lineno="$(grep -niE '^#+ .*(release|version|tag|bump|changelog)' "${root}/${candidate}" 2>/dev/null | head -1 | cut -d: -f1)"
        jq -nc --arg file "${candidate}" --arg line "${lineno:-1}" \
          '{file:$file,line:($line|tonumber),kind:"release-checklist"}'
        found="${candidate}"
        break
      fi
    fi
  done
  if [[ -z "${found}" ]] && [[ -f "${root}/CHANGELOG.md" ]]; then
    jq -nc --arg file "CHANGELOG.md" '{file:$file,kind:"changelog-only"}'
  fi
}

detect_auth_paths() {
  local root="$1" type="$2"
  case "${type}" in
    web|polyglot|python|go)
      # Find files whose path or content suggests auth/session handling
      find "${root}" -type f \
        \( -path '*auth*' -o -path '*session*' -o -path '*middleware*' -o -path '*permission*' \) \
        -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/.git/*' \
        \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.py' -o -name '*.go' \) \
        2>/dev/null | head -n 10 \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"auth-or-session"}'
          done || true
      ;;
    ios|macos)
      find "${root}" -type f \
        \( -path '*Auth*' -o -path '*Session*' -o -path '*Keychain*' \) \
        -name '*.swift' \
        -not -path '*/.build/*' -not -path '*/Pods/*' \
        2>/dev/null | head -n 10 \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"auth-or-session"}'
          done || true
      ;;
  esac
}

detect_error_states() {
  local root="$1" type="$2"
  case "${type}" in
    web|polyglot)
      find "${root}" -type f \
        \( -name 'error.tsx' -o -name 'error.ts' -o -name 'error.jsx' -o -name 'not-found.tsx' -o -name '500.tsx' -o -name '404.tsx' -o -name 'ErrorBoundary*' \) \
        -not -path '*/node_modules/*' \
        2>/dev/null | head -n 10 \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"error-state"}'
          done || true
      ;;
    *)
      # Heuristic: files explicitly named "error" or "exception"
      find "${root}" -type f \
        \( -name '*[Ee]rror*' -o -name '*[Ee]xception*' \) \
        -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.venv/*' \
        2>/dev/null | head -n 10 \
        | while IFS= read -r f; do
            jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"error-state"}'
          done || true
      ;;
  esac
}

detect_scripts() {
  local root="$1" type="$2"
  if [[ -f "${root}/package.json" ]] && command -v jq >/dev/null 2>&1; then
    jq -c '.scripts // {} | to_entries | .[] | {name: .key, kind: "npm-script"}' \
      "${root}/package.json" 2>/dev/null | head -n "${SURFACE_CAP}" || true
  fi
  if [[ -f "${root}/Makefile" ]]; then
    grep -E '^[a-z_-]+:' "${root}/Makefile" 2>/dev/null | head -n 10 \
      | sed -E 's/:.*$//' \
      | while IFS= read -r target; do
          jq -nc --arg name "${target}" '{name:$name,kind:"make-target"}'
        done || true
  fi
  if [[ -f "${root}/justfile" ]] || [[ -f "${root}/Justfile" ]]; then
    local jf="${root}/justfile"
    [[ -f "${jf}" ]] || jf="${root}/Justfile"
    grep -E '^[a-z_-]+\s*:' "${jf}" 2>/dev/null | head -n 10 \
      | sed -E 's/[ :].*$//' \
      | while IFS= read -r target; do
          jq -nc --arg name "${target}" '{name:$name,kind:"just-target"}'
        done || true
  fi
  # For bash and polyglot projects: list top-level + bin/ + scripts/ shell
  # entry points the user would invoke directly. Filters by executable
  # bit (set by install scripts) so we don't catch every helper file.
  if [[ "${type}" == "bash" || "${type}" == "polyglot" ]]; then
    find "${root}" -maxdepth 3 -type f -name '*.sh' \
      \( -path "${root}/*.sh" -o -path "${root}/bin/*" -o -path "${root}/scripts/*" -o -path "${root}/tools/*" \) \
      2>/dev/null | head -n "${SURFACE_CAP}" \
      | while IFS= read -r f; do
          jq -nc --arg file "${f#${root}/}" '{file:$file,kind:"bash-script"}'
        done || true
  fi
}

# Aggregator ------------------------------------------------------------------

# Consume NDJSON on stdin and emit a JSON array. Empty input -> "[]".
ndjson_to_array() {
  jq -s -c '.' 2>/dev/null || echo '[]'
}

scan_project() {
  local root="$1"
  local now
  now="$(now_epoch)"
  local type
  type="$(detect_project_type "${root}")"
  local key
  key="$(project_key_for_root "${root}")"

  local routes envs tests docs cfgs uis errs auths releases scripts_arr

  routes="$(detect_routes "${root}" "${type}" | ndjson_to_array)"
  envs="$(detect_env_vars "${root}" "${type}" | ndjson_to_array)"
  tests="$(detect_tests "${root}" "${type}" | ndjson_to_array)"
  docs="$(detect_docs "${root}" | ndjson_to_array)"
  cfgs="$(detect_config_flags "${root}" | ndjson_to_array)"
  uis="$(detect_ui_files "${root}" "${type}" | ndjson_to_array)"
  errs="$(detect_error_states "${root}" "${type}" | ndjson_to_array)"
  auths="$(detect_auth_paths "${root}" "${type}" | ndjson_to_array)"
  releases="$(detect_release_steps "${root}" | ndjson_to_array)"
  scripts_arr="$(detect_scripts "${root}" "${type}" | ndjson_to_array)"

  local total
  total=$(( $(printf '%s' "${routes}" | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${envs}"   | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${docs}"   | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${cfgs}"   | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${uis}"    | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${errs}"   | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${auths}"  | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${releases}" | jq 'length' 2>/dev/null || echo 0) \
         + $(printf '%s' "${scripts_arr}" | jq 'length' 2>/dev/null || echo 0) ))

  jq -n \
    --arg key "${key}" \
    --arg root "${root}" \
    --arg type "${type}" \
    --argjson now "${now}" \
    --argjson routes "${routes}" \
    --argjson envs "${envs}" \
    --argjson tests "${tests}" \
    --argjson docs "${docs}" \
    --argjson cfgs "${cfgs}" \
    --argjson uis "${uis}" \
    --argjson errs "${errs}" \
    --argjson auths "${auths}" \
    --argjson releases "${releases}" \
    --argjson scripts "${scripts_arr}" \
    --argjson total "${total}" \
    '{
      schema_version: 1,
      project_key: $key,
      project_root: $root,
      project_type: $type,
      scanned_at_ts: $now,
      total_surfaces: $total,
      surfaces: {
        routes: $routes,
        env_vars: $envs,
        tests: $tests,
        docs: $docs,
        config_flags: $cfgs,
        ui_files: $uis,
        error_states: $errs,
        auth_paths: $auths,
        release_steps: $releases,
        scripts: $scripts
      }
    }'
}

# Subcommands -----------------------------------------------------------------

cmd_path() {
  local root
  root="$(_find_project_root "${PWD}")"
  cache_path_for_root "${root}"
  printf '\n'
}

cmd_stale() {
  is_blindspot_enabled || { return 0; }
  local root cache
  root="$(_find_project_root "${PWD}")"
  cache="$(cache_path_for_root "${root}")"
  if [[ ! -f "${cache}" ]]; then
    return 0  # missing -> stale
  fi
  local mtime now diff
  # Linux GNU `stat -c %Y` first; macOS BSD `stat -f %m` fallback.
  # The reverse order silently broke on Linux: `stat -f` is interpreted
  # as `--file-system`, `%m` is treated as another (missing) file, but
  # the named cache file IS valid → stdout gets the multi-line filesystem
  # block before the `||` runs `stat -c %Y` and appends the mtime. The
  # captured variable then contains literal `File:`, which downstream
  # arithmetic (diff=$((now - mtime))) parses as an unbound variable.
  mtime="$(stat -c %Y "${cache}" 2>/dev/null || stat -f %m "${cache}" 2>/dev/null || echo 0)"
  now="$(now_epoch)"
  diff=$((now - mtime))
  if [[ "${diff}" -gt "${BLINDSPOT_TTL}" ]]; then
    return 0  # stale
  fi
  return 1  # fresh
}

cmd_scan() {
  local force=0
  if [[ "${1:-}" == "--force" ]]; then force=1; fi

  if ! is_blindspot_enabled; then
    return 0
  fi

  local root cache
  root="$(_find_project_root "${PWD}")"
  cache="$(cache_path_for_root "${root}")"

  if [[ "${force}" -eq 0 ]] && ! cmd_stale; then
    return 0  # cache fresh; no-op
  fi

  mkdir -p "${BLINDSPOT_DIR}"
  local tmp="${cache}.tmp.$$.${RANDOM}"
  if scan_project "${root}" > "${tmp}" 2>/dev/null; then
    mv "${tmp}" "${cache}"
    printf 'blindspot-inventory: scanned %s -> %s\n' "${root}" "${cache}" >&2
  else
    rm -f "${tmp}"
    printf 'blindspot-inventory: scan failed for %s\n' "${root}" >&2
    return 1
  fi
}

cmd_show() {
  is_blindspot_enabled || { return 0; }
  local root cache
  root="$(_find_project_root "${PWD}")"
  cache="$(cache_path_for_root "${root}")"
  if [[ ! -f "${cache}" ]]; then
    printf 'blindspot-inventory: no inventory at %s — run `blindspot-inventory.sh scan`\n' "${cache}" >&2
    return 1
  fi
  cat "${cache}"
}

cmd_summary() {
  is_blindspot_enabled || { return 0; }
  local root cache
  root="$(_find_project_root "${PWD}")"
  cache="$(cache_path_for_root "${root}")"
  if [[ ! -f "${cache}" ]]; then
    printf 'No blindspot inventory yet. Run: bash %s scan\n' "$0"
    return 1
  fi
  jq -r '
    "Project type: \(.project_type)
Total surfaces: \(.total_surfaces)
  routes:        \(.surfaces.routes | length)
  env_vars:      \(.surfaces.env_vars | length)
  tests:         \(.surfaces.tests | map(.count // 0) | add // 0)
  docs:          \(.surfaces.docs | length)
  config_flags:  \(.surfaces.config_flags | length)
  ui_files:      \(.surfaces.ui_files | length)
  error_states:  \(.surfaces.error_states | length)
  auth_paths:    \(.surfaces.auth_paths | length)
  release_steps: \(.surfaces.release_steps | length)
  scripts:       \(.surfaces.scripts | length)"
  ' "${cache}" 2>/dev/null
}

# Find the project root by walking up from PWD looking for git or
# common project markers. Falls back to PWD.
_find_project_root() {
  local dir="${1:-${PWD}}" depth=0
  while [[ "${dir}" != "/" && "${depth}" -lt 12 ]]; do
    if [[ -d "${dir}/.git" ]] \
        || [[ -f "${dir}/package.json" ]] \
        || [[ -f "${dir}/Cargo.toml" ]] \
        || [[ -f "${dir}/go.mod" ]] \
        || [[ -f "${dir}/pyproject.toml" ]] \
        || [[ -f "${dir}/Package.swift" ]]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
    depth=$((depth + 1))
  done
  printf '%s' "${PWD}"
}

usage() {
  cat <<'EOF'
blindspot-inventory.sh — project surface inventory for /ulw intent-broadening.

Subcommands:
  scan [--force]   Regenerate the inventory (no-op when cached + fresh)
  show             Print the cached inventory JSON to stdout
  path             Print the cache path to stdout
  stale            Exit 0 when cache is missing or older than TTL, else 1
  summary          Print a one-paragraph human-readable summary

The inventory enumerates project surfaces (routes, env vars, tests, docs,
config flags, UI files, error states, auth paths, release steps, scripts)
so the intent-broadening directive can give the model a concrete picture
to reconcile against — defending against the failure mode where a complex
prompt silently misses a surface the user did not name.

Cache: ~/.claude/quality-pack/blindspots/<project_key>.json
TTL: OMC_BLINDSPOT_TTL_SECONDS (default 86400 = 24h)
Kill switch: blindspot_inventory=off in oh-my-claude.conf
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    scan)    cmd_scan "$@" ;;
    show)    cmd_show ;;
    path)    cmd_path ;;
    stale)   cmd_stale ;;
    summary) cmd_summary ;;
    ""|-h|--help) usage ;;
    *)
      printf 'blindspot-inventory: unknown subcommand: %s\n' "${cmd}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
