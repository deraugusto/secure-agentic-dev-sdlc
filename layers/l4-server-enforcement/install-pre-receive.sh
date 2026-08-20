#!/usr/bin/env bash
# L4 · install the pre-receive guard onto the git server.
#
# The hook has to live inside the bare repository on the server. There is no way
# around that and no client-side substitute -- a client-side check is advice,
# and this layer exists because advice is bypassable.
#
#   ./install-pre-receive.sh --local /srv/git/repo.git      install here
#   ./install-pre-receive.sh --remote                       install over ssh,
#                                                           using inventory.yaml
#   ./install-pre-receive.sh --remote --dry-run             print the plan only
#
# Idempotent: re-running replaces the hook and leaves an existing
# pre-receive.conf alone unless --force-conf is given.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
HOOK_SRC="$HERE/pre-receive"
CONF_SRC="$HERE/pre-receive.conf"

MODE=""
TARGET=""
DRY_RUN=0
FORCE_CONF=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)      MODE=local; TARGET="${2:-}"; shift 2 ;;
    --remote)     MODE=remote; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --force-conf) FORCE_CONF=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$HOOK_SRC" ]] || { echo "hook source missing: $HOOK_SRC" >&2; exit 2; }

say() { printf '[L4] %s\n' "$*"; }
run() {
  if (( DRY_RUN )); then
    printf '[L4] would run: %s\n' "$*"
  else
    eval "$@"
  fi
}

if [[ "$MODE" == "local" ]]; then
  [[ -n "$TARGET" ]] || { echo "--local needs a bare repository path" >&2; exit 2; }
  [[ -d "$TARGET/hooks" ]] || { echo "not a bare repository: $TARGET" >&2; exit 2; }

  say "target: $TARGET"
  run "install -m 0755 '$HOOK_SRC' '$TARGET/hooks/pre-receive'"
  if [[ -f "$TARGET/hooks/pre-receive.conf" && $FORCE_CONF -eq 0 ]]; then
    say "pre-receive.conf exists — left untouched (use --force-conf to replace)"
  else
    run "install -m 0644 '$CONF_SRC' '$TARGET/hooks/pre-receive.conf'"
  fi
  say "installed. verify with: ./tests/test_pre_receive.sh"
  exit 0
fi

if [[ "$MODE" != "remote" ]]; then
  echo "usage: install-pre-receive.sh --local <bare-repo> | --remote [--dry-run]" >&2
  exit 2
fi

# ── Remote install · every address comes from inventory.yaml ───────────────
GIT_ADDR="$(python3 "$REPO_ROOT/lib/inventory.py" --get git.addr)"
GIT_USER="$(python3 "$REPO_ROOT/lib/inventory.py" --get git.user || echo git)"
GIT_TYPE="$(python3 "$REPO_ROOT/lib/inventory.py" --get git.type)"
GIT_PATH="$(python3 "$REPO_ROOT/lib/inventory.py" --get git.repo_path)"
SSH_PORT="$(python3 "$REPO_ROOT/lib/inventory.py" --get git.ssh_port || echo 22)"

if [[ "$GIT_TYPE" == "github" ]]; then
  cat >&2 <<'EOF'
[L4] REFUSING to pretend.

github.com does not run pre-receive hooks. They exist only on GitHub
Enterprise Server. There is no way to install this guard against a
github.com remote, and any script claiming otherwise is installing
something weaker under the same name.

What you get instead, and what it costs:

  - branch protection rules + required status checks
  - a CI job running the same evaluation on push

That combination is client-bypassable in ways this hook is not: a force
push accepted by the API is already applied by the time CI sees it, and
required checks gate merges, not pushes to a branch.

See branch-protection.md for the closest achievable configuration and an
explicit statement of the gap.
EOF
  exit 1
fi

say "target: $GIT_USER@$GIT_ADDR:$SSH_PORT  repo=$GIT_PATH  type=$GIT_TYPE"

SSH="ssh -p $SSH_PORT $GIT_USER@$GIT_ADDR"

if (( DRY_RUN )); then
  say "plan:"
  printf '        scp -P %s %s %s@%s:%s/hooks/pre-receive\n' \
    "$SSH_PORT" "$HOOK_SRC" "$GIT_USER" "$GIT_ADDR" "$GIT_PATH"
  printf '        scp -P %s %s %s@%s:%s/hooks/pre-receive.conf\n' \
    "$SSH_PORT" "$CONF_SRC" "$GIT_USER" "$GIT_ADDR" "$GIT_PATH"
  printf '        %s "chmod 0755 %s/hooks/pre-receive"\n' "$SSH" "$GIT_PATH"
  exit 0
fi

scp -P "$SSH_PORT" "$HOOK_SRC" "$GIT_USER@$GIT_ADDR:$GIT_PATH/hooks/pre-receive"
if ! $SSH "test -f '$GIT_PATH/hooks/pre-receive.conf'" || (( FORCE_CONF )); then
  scp -P "$SSH_PORT" "$CONF_SRC" \
    "$GIT_USER@$GIT_ADDR:$GIT_PATH/hooks/pre-receive.conf"
else
  say "pre-receive.conf exists on the server — left untouched"
fi
$SSH "chmod 0755 '$GIT_PATH/hooks/pre-receive'"

say "installed. Confirm by attempting a push that deletes a decision record:"
say "  it must be refused, and the refusal must name the trigger."
