#!/usr/bin/env bash
# audit-memory.sh — classify MEMORY.md entries and propose rollup moves.
#
# Backs the /memory-audit skill. Walks the user-scope auto-memory
# directory for the current project (or one passed explicitly via
# --memory-dir <path>) and classifies every entry indexed in MEMORY.md
# as load-bearing, archival, superseded, or drifted. Output is a
# markdown table plus a list of suggested mv commands the user can
# copy. Read-only — never moves, modifies, or deletes any file.
#
# Usage:
#   audit-memory.sh
#   audit-memory.sh --memory-dir /absolute/path/to/memory
#
# Exit codes:
#   0 — audit completed (including the no-directory and empty-index cases)
#   2 — bad invocation (unknown flag, missing value)

set -euo pipefail

# ---------------------------------------------------------------------
# Argument parsing

memory_dir=""
while (( $# > 0 )); do
  case "$1" in
    --memory-dir)
      memory_dir="${2:-}"
      if [[ -z "${memory_dir}" ]]; then
        printf 'audit-memory: --memory-dir requires a path\n' >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
audit-memory.sh — classify MEMORY.md entries and propose rollup moves.

usage:
  audit-memory.sh                              # auto-detect from CWD
  audit-memory.sh --memory-dir <absolute-path> # audit a specific dir

The script is read-only. It prints a markdown table and a list of
suggested mv commands; it never executes them.
EOF
      exit 0
      ;;
    *)
      printf 'audit-memory: unknown argument: %s\n' "$1" >&2
      printf 'usage: audit-memory.sh [--memory-dir <path>]\n' >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------
# Resolve the memory directory

if [[ -z "${memory_dir}" ]]; then
  pwd_abs="$(pwd)"
  encoded_cwd="$(printf '%s' "${pwd_abs}" | tr '/' '-')"
  memory_dir="${HOME}/.claude/projects/${encoded_cwd}/memory"
fi

# Always print the resolved dir as line 1 so the user can confirm the
# audit ran against the right project. Print BEFORE the existence check
# so a "no such directory" message still gets context.
printf '## Memory audit\n\n'
printf '**Memory directory:** `%s`\n\n' "${memory_dir}"

if [[ ! -d "${memory_dir}" ]]; then
  printf '_No memory directory exists at this path — nothing to audit. The directory is created the first time auto-memory writes a file for the project._\n'
  exit 0
fi

memory_index="${memory_dir}/MEMORY.md"
if [[ ! -f "${memory_index}" ]]; then
  printf '_No MEMORY.md found at `%s`. Listing the files present in the directory instead._\n\n' "${memory_index}"
  printf '| File | Size | Modified |\n'
  printf '|------|-----:|----------|\n'
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    # Linux GNU stat first; macOS BSD fallback. See blindspot-inventory.sh:616
    # for the rationale — the reverse order silently dumps the filesystem info
    # block on Linux because GNU stat -f means --file-system, not "format".
    size_bytes="$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null || printf '0')"
    mtime_iso="$( { stat -c '%y' "${f}" 2>/dev/null | cut -c1-10; } || stat -f '%Sm' -t '%Y-%m-%d' "${f}" 2>/dev/null || printf '?')"
    printf '| `%s` | %s | %s |\n' "$(basename "${f}")" "${size_bytes}" "${mtime_iso}"
  done < <(find "${memory_dir}" -maxdepth 1 -type f -name '*.md' -not -name 'MEMORY.md' 2>/dev/null | sort)
  exit 0
fi

# ---------------------------------------------------------------------
# Helpers

# Cross-platform file mtime in epoch seconds. macOS uses BSD stat; Linux
# uses GNU stat. Both branches return 0 on missing file rather than
# erroring so the calling loop can carry on with the entry classified
# as drifted (the existence check happens at the call site).
file_mtime_epoch() {
  local f="$1"
  if [[ ! -e "${f}" ]]; then
    printf '0'
    return 0
  fi
  # Linux GNU first; macOS BSD fallback. See blindspot-inventory.sh:616.
  stat -c '%Y' "${f}" 2>/dev/null \
    || stat -f '%m' "${f}" 2>/dev/null \
    || printf '0'
}

# Days since file mtime; returns 0 for missing files.
days_since_mtime() {
  local f="$1"
  local now_epoch mtime
  now_epoch="$(date +%s)"
  mtime="$(file_mtime_epoch "${f}")"
  if [[ "${mtime}" -eq 0 ]]; then
    printf '0'
    return 0
  fi
  printf '%s' $(( (now_epoch - mtime) / 86400 ))
}

# YYYY-MM-DD form for display.
file_mtime_iso() {
  local f="$1"
  if [[ ! -e "${f}" ]]; then
    printf '?'
    return 0
  fi
  # Linux GNU first; macOS BSD fallback. See blindspot-inventory.sh:616.
  { stat -c '%y' "${f}" 2>/dev/null | cut -c1-10; } \
    || stat -f '%Sm' -t '%Y-%m-%d' "${f}" 2>/dev/null \
    || printf '?'
}

# Strip strikethrough markers from text so the unwrapped form is usable
# for further matching (e.g. linked-file capture).
strip_strikethrough() {
  printf '%s' "$1" | sed 's/~~//g'
}

# ---------------------------------------------------------------------
# Walk MEMORY.md

# Counters
total=0
load_bearing=0
archival=0
superseded=0
drifted=0

# Buffers — markdown table rows accumulate here; suggested moves
# accumulate in moves_text. Both are flushed at the bottom in the order
# the audit expects to render.
table_rows=""
moves_text=""

# Cache the set of files referenced by the index so we can compute
# "orphaned files" (present in the dir, not referenced by MEMORY.md).
referenced_files=""

# Each MEMORY.md row is in one of these shapes:
#   - [Title](file.md) — description
#   - ~~[Title](file.md)~~ — closed in vX.Y.Z (description)
#
# We do not require strict adherence; any line containing a markdown
# link `[...](*.md)` is treated as an entry. Lines without a link are
# skipped (e.g. headings, blank lines, prose paragraphs).
# Portable bash regex patterns. Inline backslash-escaped patterns
# inside `[[ ... =~ ... ]]` work on bash 3.2 (macOS) but bash 5+
# (Linux) strips backslash escapes during word-splitting, breaking
# the regex engine. The variable form is the documented portable
# pattern: assignment preserves literal backslashes, and `=~ $var`
# bypasses word-splitting on the right side.
_md_link_re='\[[^]]+\]\([^)]+\.md\)'

while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
  # Skip lines without a markdown link to a *.md file.
  if [[ ! "${raw_line}" =~ $_md_link_re ]]; then
    continue
  fi

  total=$((total + 1))

  # Detect strikethrough: ~~[Title](file)~~ or ~~entire row~~.
  is_strikethrough=0
  if [[ "${raw_line}" =~ ~~ ]]; then
    is_strikethrough=1
  fi

  # Strip strikethrough for further parsing.
  cleaned="$(strip_strikethrough "${raw_line}")"

  # Extract title and file.
  title="$(printf '%s' "${cleaned}" | sed -nE 's/.*\[([^]]+)\]\([^)]+\).*/\1/p' | head -1)"
  file_ref="$(printf '%s' "${cleaned}" | sed -nE 's/.*\[[^]]+\]\(([^)]+\.md)\).*/\1/p' | head -1)"

  # Trailing description: everything after the link's closing paren,
  # stripped of leading separator punctuation/whitespace. Handled in two
  # steps because BSD sed's character classes do not accept em-dash and
  # other multi-byte UTF-8 separators reliably; awk handles the cut at
  # the closing paren and a follow-up pure-ASCII trim removes leading
  # separators (`—`, `-`, `:`, en-dash) plus surrounding whitespace.
  description="$(printf '%s' "${cleaned}" | awk -F '\\.md\\)' 'NF>1 {print $2}' | head -1)"
  # Trim leading whitespace and the most common separators.
  while [[ "${description}" =~ ^[[:space:]] || \
           "${description}" =~ ^- || \
           "${description}" =~ ^: ]]; do
    description="${description# }"
    description="${description#-}"
    description="${description#:}"
  done
  # Em-dash and en-dash trimming: the multi-byte sequences resist shell
  # globs, so use sed with literal bytes via printf-rendered patterns.
  description="$(printf '%s' "${description}" | sed -e 's/^—[[:space:]]*//' -e 's/^–[[:space:]]*//')"
  description="${description# }"

  # Capture every *.md link target on this line for the orphaned-files
  # post-pass. A row with multiple `[Title](file.md)` links should not
  # leave non-primary files looking orphaned. The classification below
  # still uses the primary (first) link's file — multi-link rows are
  # rare and the primary link drives the row's identity.
  while IFS= read -r referenced_md; do
    [[ -z "${referenced_md}" ]] && continue
    referenced_files+=$'\n'"${referenced_md}"
  done < <(printf '%s\n' "${cleaned}" \
    | grep -oE '\([^)]+\.md\)' \
    | sed -e 's/^(//' -e 's/)$//' \
    || true)

  # Determine whether the linked file actually exists in this directory.
  # MEMORY.md links are relative to the memory dir.
  abs_file="${memory_dir}/${file_ref}"
  exists=0
  [[ -f "${abs_file}" ]] && exists=1

  # Classify.
  status=""
  action=""
  case "${file_ref}" in
    project_v*_shipped.md|project_v*_shipped*.md)
      # Release-snapshot pattern — always archival per the v1.20.0 rule
      # rewrite (auto-memory.md "Reject these patterns").
      status="archival"
      action="move → \`project_release_history.md\` rollup"
      archival=$((archival + 1))
      ;;
  esac

  # If not classified yet, layer the other rules.
  if [[ -z "${status}" ]]; then
    if [[ "${exists}" -eq 0 ]]; then
      status="drifted"
      action="MEMORY.md references a file that does not exist — fix the index or remove the row"
      drifted=$((drifted + 1))
    elif [[ "${is_strikethrough}" -eq 1 ]]; then
      status="superseded"
      action="strikethrough in MEMORY.md — safe to remove file and row"
      superseded=$((superseded + 1))
    else
      # Description-based supersession heuristics. Require an
      # adjacent version marker (`v<digit>`) so legitimate prose like
      # "describes how to handle 'closed in' style markers" is not
      # auto-classified as a closure. Project convention always cites
      # the closing version next to the phrase: "closed in v1.10.0",
      # "superseded by v1.16.0", etc. Without this anchor the heuristic
      # was a foot-gun — any entry whose subject is the closure
      # mechanism itself would be flagged for archival.
      desc_lower="$(printf '%s' "${description}" | tr '[:upper:]' '[:lower:]')"
      # Variable-form regex for bash 3.2/5+ portability; see _md_link_re note above.
      _closed_in_re='closed[[:space:]]+in[[:space:]]+v[0-9]'
      _supersede_v_re='superseded[[:space:]]+by[[:space:]]+v[0-9]'
      _replace_v_re='replaced[[:space:]]+by[[:space:]]+v[0-9]'
      _supersede_link_re='superseded[[:space:]]+by[[:space:]]+\['
      _replace_link_re='replaced[[:space:]]+by[[:space:]]+\['
      if [[ "${desc_lower}" =~ $_closed_in_re ]] \
          || [[ "${desc_lower}" =~ $_supersede_v_re ]] \
          || [[ "${desc_lower}" =~ $_replace_v_re ]] \
          || [[ "${desc_lower}" =~ $_supersede_link_re ]] \
          || [[ "${desc_lower}" =~ $_replace_link_re ]]; then
        status="superseded"
        action="description marks this as closed / superseded — review and remove"
        superseded=$((superseded + 1))
      else
        days_old="$(days_since_mtime "${abs_file}")"
        if [[ "${days_old}" -gt 30 ]]; then
          status="archival"
          action="stale (>30 days) — verify still relevant; consider rolling up"
          archival=$((archival + 1))
        else
          status="load-bearing"
          action="keep"
          load_bearing=$((load_bearing + 1))
        fi
      fi
    fi
  fi

  # Compose markdown row. Show mtime so the user can spot-check.
  if [[ "${exists}" -eq 1 ]]; then
    mtime_iso="$(file_mtime_iso "${abs_file}")"
  else
    mtime_iso="missing"
  fi

  table_rows+="| **${status}** | \`${file_ref}\` | ${mtime_iso} | ${title} | ${action} |"$'\n'

  # Compose suggested move for archival/superseded entries with an
  # existing file. The user reviews and runs themselves.
  #
  # CRITICAL: paths are shell-quoted so the suggested command stays
  # safe to copy-paste even if memory_dir contains spaces or shell
  # metacharacters (`;`, `&`, backticks). Without quoting, a hostile
  # or merely awkward path would either break or, worse, splice extra
  # commands. printf '%q' produces a bash-safe quoted form.
  if [[ "${exists}" -eq 1 && ( "${status}" == "archival" || "${status}" == "superseded" ) ]]; then
    src_quoted="$(printf '%q' "${memory_dir}/${file_ref}")"
    dst_quoted="$(printf '%q' "${memory_dir}/_archive/${file_ref}")"
    moves_text+="mv ${src_quoted} ${dst_quoted}"$'\n'
  fi
done < "${memory_index}"

# ---------------------------------------------------------------------
# Orphaned-files post-pass: files in the directory not referenced by
# MEMORY.md. Often happens when a memory file is written but the index
# was not updated, or when a file was supposed to be removed but only
# the index row was struck through.

orphaned_rows=""
orphaned_count=0
while IFS= read -r f; do
  [[ -z "${f}" ]] && continue
  bname="$(basename "${f}")"
  if ! printf '%s' "${referenced_files}" | grep -qxF "${bname}"; then
    orphaned_count=$((orphaned_count + 1))
    mtime_iso="$(file_mtime_iso "${f}")"
    orphaned_rows+="| \`${bname}\` | ${mtime_iso} | not referenced from MEMORY.md — index it or archive it |"$'\n'
  fi
done < <(find "${memory_dir}" -maxdepth 1 -type f -name '*.md' -not -name 'MEMORY.md' 2>/dev/null | sort)

# ---------------------------------------------------------------------
# Render output

printf '**Indexed entries:** %d (load-bearing %d, archival %d, superseded %d, drifted %d)\n' \
  "${total}" "${load_bearing}" "${archival}" "${superseded}" "${drifted}"
if [[ "${orphaned_count}" -gt 0 ]]; then
  printf '\n**Orphaned files** (present in dir, not referenced by MEMORY.md): %d\n' "${orphaned_count}"
fi
printf '\n'

if [[ "${total}" -eq 0 ]]; then
  printf '_MEMORY.md exists but contains no markdown link entries to audit._\n'
  exit 0
fi

printf '| Status | File | Modified | Title | Suggested action |\n'
printf '|--------|------|----------|-------|------------------|\n'
printf '%s' "${table_rows}"

if [[ -n "${orphaned_rows}" ]]; then
  printf '\n### Orphaned files\n\n'
  printf '| File | Modified | Suggested action |\n'
  printf '|------|----------|------------------|\n'
  printf '%s' "${orphaned_rows}"
fi

if [[ -n "${moves_text}" ]]; then
  archive_quoted="$(printf '%q' "${memory_dir}/_archive")"
  printf '\n### Suggested moves (review and run yourself — the audit never executes these)\n\n'
  printf '```bash\n'
  printf 'mkdir -p %s\n' "${archive_quoted}"
  printf '%s' "${moves_text}"
  printf '```\n'
fi

# Rollup hint when version snapshots cluster.
if [[ "${archival}" -ge 5 ]]; then
  printf '\n### Rollup recommendation\n\n'
  printf 'You have %d archival entries. If most are `project_v*_shipped.md` files, the recommended sequence is:\n\n' "${archival}"
  printf '1. **Write `project_release_history.md` first.** Read each archival file, extract the *non-derivable* signal (decision rationale, deferred risks, lessons that won''t appear in `git log` / `CHANGELOG.md`), and consolidate into one per-release summary. CHANGELOG and git tags are authoritative for version/SHA/test-count details — do not duplicate them.\n'
  printf '2. **Then run the suggested moves above** to archive the originals into `_archive/`. The moves only relocate the files; they do *not* extract content. Running them before step 1 leaves you with archived source material and no rollup.\n'
  printf '3. **Update `MEMORY.md`** by replacing the per-version index rows with a single one-line entry pointing at the new rollup file.\n\n'
  printf 'The v1.20.0 auto-memory rule (auto-memory.md → "Reject these patterns") forbids creating new `project_v*_shipped.md` files going forward; consolidating the existing ones brings the directory in line with the rule.\n'
fi

exit 0
