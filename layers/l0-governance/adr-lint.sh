#!/usr/bin/env bash
# adr-lint · frontmatter, amendment protocol and index-sync validator for ADRs.
#
# L0 is the layer that must run on a bare clone with nothing installed, so this
# is bash and coreutils only — no python, no yaml library, no network.
#
#   ./layers/l0-governance/adr-lint.sh [adr-dir]
#
# Default adr-dir: docs/adr/
#
# Exit 0  every ADR valid
# Exit 1  at least one ADR invalid
# Exit 2  argument or path error
#
# Required frontmatter : id title type status implementation date author tags
# Optional             : last-updated supersedes superseded-by references
#
#   type            adr
#   status          proposed | accepted | accepted-with-gaps | superseded | rejected
#   implementation  pending | partial | deployed | superseded
#   date            YYYY-MM-DD
#   last-updated    YYYY-MM-DD, >= date, and == the newest amendment header date
#   tags            non-empty inline list [a, b, ...]
#   id              must match the filename: ADR-0001 <-> ADR-0001-*.md
#
# Amendment protocol (append-only): an accepted ADR is never edited in place.
# Changes append a section '## Amendment YYYY-MM-DD · <summary>' and bump
# last-updated to that date. This lint enforces the mechanical half of that
# rule; the discipline half is yours.

set -uo pipefail

ADR_DIR="${1:-docs/adr}"
INDEX_FILE="${ADR_INDEX_FILE:-$ADR_DIR/ADR-INDEX.md}"

if [[ ! -d "$ADR_DIR" ]]; then
  echo "error: ADR directory not found: $ADR_DIR" >&2
  exit 2
fi

shopt -s nullglob
files=("$ADR_DIR"/ADR-[0-9][0-9][0-9][0-9]-*.md)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "error: no ADR files in $ADR_DIR (expected ADR-NNNN-<slug>.md)" >&2
  exit 2
fi

valid_status=(proposed accepted accepted-with-gaps superseded rejected)
valid_impl=(pending partial deployed superseded)

in_set() {
  local needle="$1"; shift
  local candidate
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

extract_frontmatter() {
  awk '
    BEGIN { fences = 0 }
    /^---[[:space:]]*$/ { fences++; if (fences == 2) exit; next }
    fences == 1 { print }
  ' "$1"
}

extract_body() {
  awk '
    BEGIN { fences = 0 }
    /^---[[:space:]]*$/ { fences++; next }
    fences >= 2 { print }
  ' "$1"
}

field() {
  local name="$1" frontmatter="$2"
  printf '%s\n' "$frontmatter" \
    | grep -E "^${name}:" \
    | head -1 \
    | sed -E "s/^${name}:[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//'
}

is_iso_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

fail_count=0
pass_count=0

for file in "${files[@]}"; do
  base="$(basename "$file" .md)"
  expected_id="ADR-$(printf '%s' "$base" | sed -E 's/^ADR-([0-9]{4}).*/\1/')"
  frontmatter="$(extract_frontmatter "$file")"
  body="$(extract_body "$file")"
  errs=()

  if [[ -z "$frontmatter" ]]; then
    errs+=("frontmatter: missing or unterminated '---' fences")
  fi

  id="$(field id "$frontmatter")"
  if [[ -z "$id" ]]; then
    errs+=("id: missing")
  elif [[ "$id" != "$expected_id" ]]; then
    errs+=("id: '$id' does not match filename (expected '$expected_id')")
  fi

  title="$(field title "$frontmatter")"
  [[ -z "$title" ]] && errs+=("title: missing")

  adr_type="$(field type "$frontmatter")"
  if [[ -z "$adr_type" ]]; then
    errs+=("type: missing")
  elif [[ "$adr_type" != "adr" ]]; then
    errs+=("type: '$adr_type' must be 'adr'")
  fi

  status="$(field status "$frontmatter")"
  if [[ -z "$status" ]]; then
    errs+=("status: missing")
  elif ! in_set "$status" "${valid_status[@]}"; then
    errs+=("status: '$status' not in {${valid_status[*]}}")
  fi

  implementation="$(field implementation "$frontmatter")"
  if [[ -z "$implementation" ]]; then
    errs+=("implementation: missing")
  elif ! in_set "$implementation" "${valid_impl[@]}"; then
    errs+=("implementation: '$implementation' not in {${valid_impl[*]}}")
  fi

  date_field="$(field date "$frontmatter")"
  if [[ -z "$date_field" ]]; then
    errs+=("date: missing")
  elif ! is_iso_date "$date_field"; then
    errs+=("date: '$date_field' is not ISO YYYY-MM-DD")
  fi

  author="$(field author "$frontmatter")"
  [[ -z "$author" ]] && errs+=("author: missing")

  tags="$(field tags "$frontmatter")"
  if [[ -z "$tags" ]]; then
    errs+=("tags: missing")
  elif [[ ! "$tags" =~ ^\[.*\]$ ]]; then
    errs+=("tags: must be an inline list '[a, b, ...]'")
  else
    inner="$(printf '%s' "$tags" | sed -E 's/^\[[[:space:]]*//; s/[[:space:]]*\]$//')"
    [[ -z "$inner" ]] && errs+=("tags: empty list")
  fi

  # ── superseded coupling ──
  superseded_by="$(field superseded-by "$frontmatter")"
  if [[ "$status" == "superseded" && -z "$superseded_by" ]]; then
    errs+=("superseded-by: required when status=superseded")
  fi
  if [[ -n "$superseded_by" && "$status" != "superseded" ]]; then
    errs+=("superseded-by: set but status is '$status' (expected 'superseded')")
  fi

  # ── amendment protocol ──
  last_updated="$(field last-updated "$frontmatter")"
  newest_amendment="$(printf '%s\n' "$body" \
    | grep -oE '^## Amendment [0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | sort \
    | tail -1)"

  if [[ -n "$last_updated" ]]; then
    if ! is_iso_date "$last_updated"; then
      errs+=("last-updated: '$last_updated' is not ISO YYYY-MM-DD")
    elif [[ -n "$date_field" ]] && is_iso_date "$date_field" \
         && [[ "$last_updated" < "$date_field" ]]; then
      errs+=("last-updated: '$last_updated' predates date '$date_field'")
    fi
  fi

  if [[ -n "$newest_amendment" ]]; then
    if [[ -z "$last_updated" ]]; then
      errs+=("last-updated: missing but the body carries an amendment dated $newest_amendment")
    elif [[ "$last_updated" != "$newest_amendment" ]]; then
      errs+=("last-updated: '$last_updated' != newest amendment header '$newest_amendment'")
    fi
  fi

  malformed_amendments="$(printf '%s\n' "$body" \
    | grep -cE '^## Amendment( |$)' || true)"
  wellformed_amendments="$(printf '%s\n' "$body" \
    | grep -cE '^## Amendment [0-9]{4}-[0-9]{2}-[0-9]{2} · .+' || true)"
  if (( malformed_amendments > wellformed_amendments )); then
    errs+=("amendment: header must read '## Amendment YYYY-MM-DD · <summary>'")
  fi

  # ── index sync ──
  if [[ -f "$INDEX_FILE" ]]; then
    if ! grep -qF "$base" "$INDEX_FILE"; then
      errs+=("index: '$base' is not referenced in $(basename "$INDEX_FILE")")
    fi
  fi

  if [[ ${#errs[@]} -eq 0 ]]; then
    printf 'PASS  %s\n' "$base.md"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL  %s\n' "$base.md"
    for err in "${errs[@]}"; do
      printf '        - %s\n' "$err"
    done
    fail_count=$((fail_count + 1))
  fi
done

total=$((pass_count + fail_count))
echo
echo "adr-lint: $pass_count/$total pass, $fail_count fail"

[[ $fail_count -eq 0 ]]
