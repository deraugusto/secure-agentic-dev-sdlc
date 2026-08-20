#!/usr/bin/env bash
# bootstrap/tests/test_bootstrap.sh — negative probes for the bootstrap.
#
# Every check here asserts a REFUSAL. That is deliberate: the bootstrap's happy
# path is visible the first time anyone runs it, while the refusals are the part
# that decides whether a wrong answer produces a broken topology or a stop.
#
# Each case runs against a throwaway copy of the repository in a temp directory.
# Nothing here touches your working tree, your git server or your inventory.
#
#   ./bootstrap/tests/test_bootstrap.sh          run all
#   ./bootstrap/tests/test_bootstrap.sh -v       show the output of each case

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
VERBOSE=0
# macOS ships `shasum` instead of `sha256sum`. A baseline that claims to be
# portable should not require the recipient to install coreutils before it can
# verify its own integrity.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256="shasum -a 256"
else
  echo "neither sha256sum nor shasum found — cannot verify hashes" >&2
  exit 1
fi
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A pristine copy, made once. Cases that mutate get their own copy from it.
SANDBOX_SRC="$WORK/pristine"
mkdir -p "$SANDBOX_SRC"
( cd "$REPO_ROOT" && tar cf - \
    bootstrap layers lib docs example tools inventory.example.yaml 2>/dev/null ) \
  | ( cd "$SANDBOX_SRC" && tar xf - )

new_sandbox() {
  _dir="$WORK/case-$1"
  cp -R "$SANDBOX_SRC" "$_dir"
  printf '%s' "$_dir"
}

report() {
  _verdict="$1"; _name="$2"; _detail="$3"
  if [ "$_verdict" = "PASS" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %-32s %s\n' "$_name" "$_detail"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-32s %s\n' "$_name" "$_detail"
  fi
}

# run_case <name> <expect-exit: 0|nonzero> <expect-text|-> <answers-overrides...>
#
# Runs the bootstrap non-interactively in a fresh sandbox and asserts on the
# exit status and, optionally, on a phrase the refusal must contain. Asserting
# the phrase matters: a refusal that does not say what it refused is a wall,
# and a wall gets worked around.
run_case() {
  _name="$1"; _expect="$2"; _phrase="$3"; shift 3
  _dir="$(new_sandbox "$_name")"
  _answers="$_dir/answers"
  cp "$HERE/acceptance.answers" "$_answers"
  for _override in "$@"; do
    _key="${_override%%=*}"
    grep -v "^$_key=" "$_answers" > "$_answers.tmp" && mv "$_answers.tmp" "$_answers"
    printf '%s\n' "$_override" >> "$_answers"
  done

  _out="$( cd "$_dir" && ./bootstrap/init.sh --non-interactive \
             --answers "$_answers" --dry-run 2>&1 )"
  _rc=$?
  [ "$VERBOSE" = "1" ] && printf '%s\n' "$_out" | sed 's/^/      /'

  if [ "$_expect" = "0" ] && [ "$_rc" -ne 0 ]; then
    report FAIL "$_name" "expected success, got exit $_rc"
    return
  fi
  if [ "$_expect" != "0" ] && [ "$_rc" -eq 0 ]; then
    report FAIL "$_name" "expected a refusal, got exit 0"
    return
  fi
  if [ "$_phrase" != "-" ] && ! printf '%s' "$_out" | grep -qi -- "$_phrase"; then
    report FAIL "$_name" "refused, but never said '$_phrase'"
    return
  fi
  report PASS "$_name" "exit=$_rc"
}

printf '\n── separations · a collapsed one must stop the bootstrap ──\n\n'

run_case targets-eq-dev-refused nonzero "SEPARATION VIOLATED" \
  ANS_TARGET_ADDR=localhost

run_case git-eq-dev-refused nonzero "SEPARATION VIOLATED" \
  ANS_GIT_ADDR=localhost

run_case reviewer-family-collision-refused nonzero "shares" \
  ANS_REVIEWER_PROVIDER=ollama \
  ANS_REVIEWER_ADDR=model.example.internal \
  ANS_REVIEWER_MODEL=alpha-instruct-8b

# The same collision, spelled differently: family matching must survive a
# version suffix, which plain string comparison would miss.
run_case reviewer-family-versioned-refused nonzero "shares" \
  ANS_REVIEWER_PROVIDER=ollama \
  ANS_REVIEWER_ADDR=model.example.internal \
  ANS_AUTHOR_MODEL=qwen3-coder \
  ANS_REVIEWER_MODEL=qwen2.5-instruct

# A collapsed separation on a DISABLED layer is not an error: the layer that
# would have carried the guarantee is not claimed to be present.
run_case targets-eq-dev-ok-when-l5-off 0 "-" \
  ANS_TARGET_ADDR=localhost \
  ANS_L5=false

printf '\n── answers · the bootstrap must refuse to guess ──\n\n'

run_case missing-git-addr-refused nonzero "unanswered" \
  ANS_GIT_ADDR=

run_case unknown-git-type-refused nonzero "unknown git type" \
  ANS_GIT_TYPE=bitbucket

run_case unknown-provider-refused nonzero "unknown reviewer provider" \
  ANS_REVIEWER_PROVIDER=telepathy

printf '\n── profiles ──\n\n'

_dir="$(new_sandbox unknown-profile)"
_out="$( cd "$_dir" && ./bootstrap/init.sh --non-interactive --dry-run \
           --profile does-not-exist --answers "$HERE/acceptance.answers" 2>&1 )"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -q "unknown profile"; then
  report PASS unknown-profile-refused "exit non-zero"
else
  report FAIL unknown-profile-refused "accepted a profile that does not exist"
fi

# single-host ships with L5 off. If that default ever flips, the profile starts
# promising a separation it cannot keep, so the default itself is under test.
_out="$( . "$REPO_ROOT/bootstrap/profiles/single-host.profile"; \
         printf '%s' "$PROFILE_LAYERS_DEFAULT" )"
case "$_out" in
  *l5=false*) report PASS single-host-l5-off-by-default "l5=false" ;;
  *) report FAIL single-host-l5-off-by-default "l5 is not off: $_out" ;;
esac

printf '\n── dry run · must not touch anything ──\n\n'

_dir="$(new_sandbox dryrun-clean)"
_before="$( cd "$_dir" && find . -type f -exec $SHA256 {} \; | sort | $SHA256 )"
( cd "$_dir" && ./bootstrap/init.sh --non-interactive --dry-run \
    --answers "$HERE/acceptance.answers" >/dev/null 2>&1 )
_after="$( cd "$_dir" && find . -type f -exec $SHA256 {} \; | sort | $SHA256 )"
if [ "$_before" = "$_after" ]; then
  report PASS dry-run-changes-nothing "tree hash unchanged"
else
  report FAIL dry-run-changes-nothing "the tree changed during a dry run"
fi

if [ -f "$_dir/inventory.yaml" ]; then
  report FAIL dry-run-writes-no-inventory "inventory.yaml was created"
else
  report PASS dry-run-writes-no-inventory "no inventory.yaml"
fi

printf '\n── real run · applies, then is idempotent ──\n\n'

_dir="$(new_sandbox real-run)"
( cd "$_dir" && git init -q . 2>/dev/null )
_out1="$( cd "$_dir" && ./bootstrap/init.sh --non-interactive \
            --answers "$HERE/acceptance.answers" 2>&1 )"
_rc1=$?
[ "$VERBOSE" = "1" ] && printf '%s\n' "$_out1" | sed 's/^/      /'

if [ "$_rc1" -eq 0 ] && [ -f "$_dir/inventory.yaml" ]; then
  report PASS real-run-writes-inventory "exit=0"
else
  report FAIL real-run-writes-inventory "exit=$_rc1, inventory present: $( [ -f "$_dir/inventory.yaml" ] && echo yes || echo no )"
fi

_perm="$(ls -l "$_dir/inventory.yaml" 2>/dev/null | cut -c1-10)"
if [ "$_perm" = "-rw-------" ]; then
  report PASS inventory-is-0600 "$_perm"
else
  report FAIL inventory-is-0600 "mode is $_perm — addresses are world-readable"
fi

for _hook in commit-msg post-merge post-checkout post-rewrite pre-push; do
  if [ -x "$_dir/.git/hooks/$_hook" ]; then
    report PASS "hook-installed-$_hook" "executable"
  else
    report FAIL "hook-installed-$_hook" "missing"
  fi
done

if grep -qx 'inventory.yaml' "$_dir/.gitignore" 2>/dev/null; then
  report PASS inventory-gitignored "listed in .gitignore"
else
  report FAIL inventory-gitignored "an inventory full of addresses is committable"
fi

_out2="$( cd "$_dir" && ./bootstrap/init.sh --non-interactive \
            --answers "$HERE/acceptance.answers" 2>&1 )"
_rc2=$?
if [ "$_rc2" -eq 0 ] && printf '%s' "$_out2" | grep -q "already in place"; then
  report PASS second-run-is-idempotent "reports what was already in place"
else
  report FAIL second-run-is-idempotent "exit=$_rc2"
fi

if printf '%s' "$_out2" | grep -q "matches the answers"; then
  report PASS second-run-rewrites-nothing "inventory left untouched"
else
  report FAIL second-run-rewrites-nothing "inventory was rewritten on an unchanged run"
fi

printf '\n── refusing to overwrite a hook that is not ours ──\n\n'

_dir="$(new_sandbox foreign-hook)"
( cd "$_dir" && git init -q . 2>/dev/null )
mkdir -p "$_dir/.git/hooks"
printf '#!/bin/sh\n# someone else deploys from here\nexit 0\n' > "$_dir/.git/hooks/pre-push"
chmod +x "$_dir/.git/hooks/pre-push"
_out="$( cd "$_dir" && ./bootstrap/init.sh --non-interactive \
           --answers "$HERE/acceptance.answers" 2>&1 )"
if grep -q "someone else deploys from here" "$_dir/.git/hooks/pre-push"; then
  report PASS foreign-hook-preserved "left the existing hook alone"
else
  report FAIL foreign-hook-preserved "overwrote a hook it did not write"
fi
if printf '%s' "$_out" | grep -qi "refusing to overwrite"; then
  report PASS foreign-hook-warns "said so"
else
  report FAIL foreign-hook-warns "overwrote or skipped silently"
fi

printf '\n%s/%s PASS\n\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
