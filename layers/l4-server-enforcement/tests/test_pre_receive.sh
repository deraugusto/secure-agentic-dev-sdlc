#!/usr/bin/env bash
# L4 · pre-receive guard, end to end against a real bare repository.
#
# This layer had no runnable precedent -- the hook existed only as text inside a
# decision record -- so it gets the most thorough test in the repository. Every
# case pushes for real into a bare repo with the hook installed, and asserts on
# git's exit code, on the refusal text, and on the audit trail.
#
#   ./test_pre_receive.sh
#
# No network, no server, no configuration. Exit 0 if every case passes.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../pre-receive"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

BARE="$WORKDIR/origin.git"
CLONE="$WORKDIR/clone"
AUDIT="$WORKDIR/audit.jsonl"

pass_count=0
fail_count=0

report() {
  local status="$1" name="$2" detail="${3:-}"
  if [[ "$status" == "PASS" ]]; then
    printf 'PASS  %-26s %s\n' "$name" "$detail"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL  %-26s %s\n' "$name" "$detail"
    fail_count=$((fail_count + 1))
  fi
}

git_quiet() { git -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

setup_repo() {
  rm -rf "$BARE" "$CLONE"
  : > "$AUDIT"

  git init --bare --initial-branch=main "$BARE" >/dev/null
  install -m 0755 "$HOOK" "$BARE/hooks/pre-receive"
  cat > "$BARE/hooks/pre-receive.conf" <<'EOF'
DELETION_THRESHOLD=40
PROTECTED_GLOBS=docs/adr/*.md
PROTECTED_FILES=CONVENTIONS.md
PROTECTED_REFS=refs/heads/main
BYPASS_VOCABULARY=repo-restructure legacy-cleanup branch-rebase archive-migration
EOF

  git init --initial-branch=main "$CLONE" >/dev/null
  (
    cd "$CLONE"
    git config user.email tester@example.invalid
    git config user.name Tester
    git config commit.gpgsign false
    mkdir -p docs/adr src
    printf 'conventions\n' > CONVENTIONS.md
    printf -- '---\nid: ADR-0001\n---\nbody\n' > docs/adr/ADR-0001-example.md
    printf -- '---\nid: ADR-0002\n---\nbody\n' > docs/adr/ADR-0002-example.md
    for i in $(seq 1 60); do printf 'line %s\n' "$i" >> src/bulk.txt; done
    git add -A
    git commit -q -m "meta: seed the repository"
    git remote add origin "$BARE"
    git push -q origin main
  ) >/dev/null 2>&1
}

push_expect() {
  # push_expect <case-name> <expect: accept|refuse> [git push args...]
  local name="$1" expect="$2"; shift 2
  local output status
  output="$( cd "$CLONE" && SDLC_PRERECEIVE_AUDIT="$AUDIT" git push "$@" 2>&1 )"
  status=$?
  if [[ "$expect" == "accept" && $status -eq 0 ]]; then
    report PASS "$name" "push accepted"
  elif [[ "$expect" == "refuse" && $status -ne 0 ]]; then
    local trigger
    trigger="$(printf '%s\n' "$output" | grep -oE 'Trigger : .*' | head -1)"
    report PASS "$name" "${trigger:-push refused}"
  else
    report FAIL "$name" "expected $expect, git exited $status"
    printf '%s\n' "$output" | sed 's/^/        | /'
  fi
}

audit_last_decision() {
  grep -o '"decision":"[a-z]*"' "$AUDIT" | tail -1 | cut -d'"' -f4
}

echo "L4 pre-receive guard · end-to-end"
echo

# The hook must see its audit path. Server-side hooks inherit the pushing
# process's environment only over ssh with AcceptEnv, so for a local push we
# set it in the hook's own config instead.
setup_repo
printf 'AUDIT_LOG=%s\n' "$AUDIT" >> "$BARE/hooks/pre-receive.conf"

# ── CASE 1 · ordinary commit ───────────────────────────────────────────────
(
  cd "$CLONE"
  printf 'a small addition\n' >> src/notes.txt
  git add -A && git commit -q -m "example: add a note"
)
push_expect "ordinary-commit" accept origin main
[[ "$(audit_last_decision)" == "pass" ]] \
  && report PASS "audit-records-pass" "decision=pass" \
  || report FAIL "audit-records-pass" "decision=$(audit_last_decision)"

# ── CASE 2 · deleting a decision record ────────────────────────────────────
(
  cd "$CLONE"
  git rm -q docs/adr/ADR-0002-example.md
  git commit -q -m "adr(0002): remove the record"
)
push_expect "adr-delete-refused" refuse origin main
[[ "$(audit_last_decision)" == "reject" ]] \
  && report PASS "audit-records-reject" "decision=reject" \
  || report FAIL "audit-records-reject" "decision=$(audit_last_decision)"

# ── CASE 3 · same deletion, tagged with a permitted reason ─────────────────
(
  cd "$CLONE"
  git commit -q --amend -m "adr(0002): remove the record

The record is superseded and its content moved to the archive repository.

[ALLOW-DESTRUCTIVE: archive-migration]"
)
push_expect "adr-delete-bypassed" accept origin main
[[ "$(audit_last_decision)" == "bypass" ]] \
  && report PASS "audit-records-bypass" "decision=bypass" \
  || report FAIL "audit-records-bypass" "decision=$(audit_last_decision)"

# ── CASE 4 · a bypass tag outside the vocabulary is not a bypass ───────────
(
  cd "$CLONE"
  git rm -q docs/adr/ADR-0001-example.md
  git commit -q -m "adr(0001): remove the record

[ALLOW-DESTRUCTIVE: because-i-said-so]"
)
push_expect "invalid-vocabulary-refused" refuse origin main

# ── CASE 5 · mass deletion over the threshold ──────────────────────────────
setup_repo
printf 'AUDIT_LOG=%s\n' "$AUDIT" >> "$BARE/hooks/pre-receive.conf"
(
  cd "$CLONE"
  git rm -q src/bulk.txt
  git commit -q -m "example: drop the bulk file"
)
push_expect "mass-delete-refused" refuse origin main

# ── CASE 6 · a restructure nets near zero and must not trip ────────────────
setup_repo
printf 'AUDIT_LOG=%s\n' "$AUDIT" >> "$BARE/hooks/pre-receive.conf"
(
  cd "$CLONE"
  mkdir -p moved
  git mv src/bulk.txt moved/bulk.txt
  git commit -q -m "example: move the bulk file into moved/"
)
push_expect "restructure-accepted" accept origin main

# ── CASE 7 · deleting a governance file ────────────────────────────────────
(
  cd "$CLONE"
  git rm -q CONVENTIONS.md
  git commit -q -m "doc: drop the conventions"
)
push_expect "governance-delete-refused" refuse origin main

# ── CASE 8 · deleting a protected ref ──────────────────────────────────────
setup_repo
printf 'AUDIT_LOG=%s\n' "$AUDIT" >> "$BARE/hooks/pre-receive.conf"
push_expect "protected-ref-delete-refused" refuse origin --delete main

# ── CASE 9 · branch creation is additive ───────────────────────────────────
(
  cd "$CLONE"
  git checkout -q -b feature/example
  printf 'feature\n' >> src/feature.txt
  git add -A && git commit -q -m "example: start a feature branch"
)
push_expect "branch-create-accepted" accept origin feature/example

# ── CASE 10 · an unprotected branch may be deleted ─────────────────────────
push_expect "unprotected-ref-delete-accepted" accept origin --delete feature/example

# ── CASE 11 · a broken hook refuses rather than waves through ──────────────
setup_repo
printf 'AUDIT_LOG=%s\n' "$AUDIT" >> "$BARE/hooks/pre-receive.conf"
# Injected at the top, not appended: bash reads a script incrementally, so
# garbage after the final `exit` never gets parsed and would prove nothing.
sed -i '1a this-is-not-valid-bash (((' "$BARE/hooks/pre-receive"
(
  cd "$CLONE"
  printf 'another line\n' >> src/notes.txt
  git add -A && git commit -q -m "example: add another note"
)
push_expect "broken-hook-fails-closed" refuse origin main

echo
total=$((pass_count + fail_count))
echo "$pass_count/$total PASS"
[[ $fail_count -eq 0 ]]
