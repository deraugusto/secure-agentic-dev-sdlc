#!/usr/bin/env bash
# L0 · negative probes for adr-lint.
#
# The lint's happy path is visible every time anyone runs it. These cases cover
# the refusals, which is the half that decides whether the governance spine is
# a convention or a rule.
#
# Every case builds a throwaway ADR directory in a temp dir and points the lint
# at it with ADR_DIR. Your decision records are never touched.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "$HERE/.." && pwd)"
LINT="$LAYER/adr-lint.sh"

PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
  if [ "$1" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  printf '%-5s %-34s %s\n' "$1" "$2" "$3"
}

# write_adr <dir> <file> <frontmatter-block> <body>
write_adr() {
  mkdir -p "$1"
  { printf -- '---\n%s\n---\n\n' "$3"; printf '%s\n' "$4"; } > "$1/$2"
}

write_index() {
  _dir="$1"; shift
  {
    printf '# ADR Index\n\n| ID | Title | Status | Implementation | Last change |\n'
    printf -- '|---|---|---|---|---|\n'
    for _entry in "$@"; do printf '%s\n' "$_entry"; done
  } > "$_dir/ADR-INDEX.md"
}

# A well-formed record, used as the base every case then breaks in one way.
good_frontmatter() {
  cat <<'TXT'
id: ADR-0001
title: "ADR-0001: A decision"
type: adr
status: accepted
implementation: deployed
date: 2026-01-01
author: probe
tags: [adr]
TXT
}

# run_lint <case-dir> → prints output, returns the lint's exit status.
# The directory is a positional argument; only the index path is environment.
run_lint() {
  ADR_INDEX_FILE="$1/ADR-INDEX.md" bash "$LINT" "$1" 2>&1
}

expect() {
  _name="$1"; _dir="$2"; _want="$3"; _phrase="$4"
  _out="$(run_lint "$_dir")"; _rc=$?
  if [ "$_want" = "pass" ] && [ "$_rc" -ne 0 ]; then
    report FAIL "$_name" "expected pass, got exit $_rc"; return
  fi
  if [ "$_want" = "fail" ] && [ "$_rc" -eq 0 ]; then
    report FAIL "$_name" "expected a refusal, got exit 0"; return
  fi
  if [ "$_phrase" != "-" ] && ! printf '%s' "$_out" | grep -qi -- "$_phrase"; then
    report FAIL "$_name" "refused without naming '$_phrase'"; return
  fi
  report PASS "$_name" "exit=$_rc"
}

printf '\n── the baseline case must pass, or nothing below means anything ──\n\n'

D="$WORK/ok"; write_adr "$D" "ADR-0001-a-decision.md" "$(good_frontmatter)" "# ADR-0001: A decision

## Context
Something had to be decided.

## Decision
It was."
write_index "$D" "| [ADR-0001](ADR-0001-a-decision.md) | A decision | accepted | deployed | 2026-01-01 |"
expect well-formed-adr-passes "$D" pass -

printf '\n── index sync · a record that is not listed cannot pass ──\n\n'

D="$WORK/unlisted"; cp -R "$WORK/ok" "$D"
write_index "$D"    # an index with no rows at all
expect unlisted-adr-refused "$D" fail "index"

D="$WORK/index-drift"; cp -R "$WORK/ok" "$D"
write_adr "$D" "ADR-0002-second.md" "$(good_frontmatter | sed 's/ADR-0001/ADR-0002/g')" "# ADR-0002: Second

## Context
c

## Decision
d"
expect second-adr-not-in-index-refused "$D" fail "index"

printf '\n── identity · the id and the filename must agree ──\n\n'

D="$WORK/id-mismatch"; cp -R "$WORK/ok" "$D"
mv "$D/ADR-0001-a-decision.md" "$D/ADR-0007-a-decision.md"
write_index "$D" "| [ADR-0007](ADR-0007-a-decision.md) | A decision | accepted | deployed | 2026-01-01 |"
expect id-filename-mismatch-refused "$D" fail "-"

printf '\n── amendment protocol · the coupling that keeps history honest ──\n\n'

# An accepted decision changed in place: the body carries an amendment header
# but last-updated was not moved. This is the exact failure the protocol
# exists to catch -- the reasoning that produced the current state is gone.
D="$WORK/amendment-uncoupled"
write_adr "$D" "ADR-0001-a-decision.md" "$(good_frontmatter)" "# ADR-0001: A decision

## Context
c

## Decision
d

## Amendment 2026-06-01 · changed something"
write_index "$D" "| [ADR-0001](ADR-0001-a-decision.md) | A decision | accepted | deployed | 2026-01-01 |"
expect amendment-without-last-updated-refused "$D" fail "last-updated"

# last-updated present but pointing at the wrong amendment.
D="$WORK/amendment-stale"
write_adr "$D" "ADR-0001-a-decision.md" "$(good_frontmatter; printf 'last-updated: 2026-03-01\n')" "# ADR-0001: A decision

## Context
c

## Decision
d

## Amendment 2026-06-01 · changed something"
write_index "$D" "| [ADR-0001](ADR-0001-a-decision.md) | A decision | accepted | deployed | 2026-06-01 |"
expect last-updated-not-newest-amendment-refused "$D" fail "last-updated"

# And the correct version of the same record must pass, so the case above is
# testing the coupling and not merely the presence of an amendment.
D="$WORK/amendment-ok"
write_adr "$D" "ADR-0001-a-decision.md" "$(good_frontmatter; printf 'last-updated: 2026-06-01\n')" "# ADR-0001: A decision

## Context
c

## Decision
d

## Amendment 2026-06-01 · changed something"
write_index "$D" "| [ADR-0001](ADR-0001-a-decision.md) | A decision | accepted | deployed | 2026-06-01 |"
expect properly-amended-adr-passes "$D" pass -

printf '\n── frontmatter schema ──\n\n'

D="$WORK/bad-status"
write_adr "$D" "ADR-0001-a-decision.md" "$(good_frontmatter | sed 's/^status: accepted/status: probably/')" "# ADR-0001: A decision

## Context
c

## Decision
d"
write_index "$D" "| [ADR-0001](ADR-0001-a-decision.md) | A decision | probably | deployed | 2026-01-01 |"
expect unknown-status-refused "$D" fail "status"

D="$WORK/no-frontmatter"
mkdir -p "$D"
printf '# ADR-0001: A decision\n\nNo frontmatter at all.\n' > "$D/ADR-0001-a-decision.md"
write_index "$D" "| [ADR-0001](ADR-0001-a-decision.md) | A decision | accepted | deployed | 2026-01-01 |"
expect missing-frontmatter-refused "$D" fail "-"

printf '\n%s/%s PASS\n\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
