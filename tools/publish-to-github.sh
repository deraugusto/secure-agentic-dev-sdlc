#!/usr/bin/env bash
# Publish the current branch to GitHub as an anonymised, separately signed copy.
#
#   ./tools/publish-to-github.sh --dry-run    show what would be pushed
#   ./tools/publish-to-github.sh              rewrite, sign, push
#
# Why this exists: the GitHub copy is a publication, not a second home. It
# carries the same content under a different identity -- GitHub's noreply
# address and a signing key that exists only for this purpose -- so that a
# public repository does not hand out the author's real address to every
# crawler that walks the commit log.
#
# The two histories therefore have different commit hashes on purpose. This
# script rebuilds the published one from scratch every time, in a throwaway
# clone, and force-pushes it. Your working tree and your primary remote are
# never touched.
#
# Configuration lives in the environment, not in this file:
#
#   GITHUB_TOKEN     fine-grained PAT with Contents: Read and write. Required.
#   GITHUB_REPO      owner/name. Default: deraugusto/secure-agentic-dev-sdlc
#   GITHUB_NOREPLY   the address commits are rewritten to.
#   GITHUB_SIGNKEY   the key they are signed with.
#   GITHUB_BRANCH    branch on the remote. Default: main

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

GITHUB_REPO="${GITHUB_REPO:-deraugusto/secure-agentic-dev-sdlc}"
GITHUB_NOREPLY="${GITHUB_NOREPLY:-172887225+deraugusto@users.noreply.github.com}"
GITHUB_SIGNKEY="${GITHUB_SIGNKEY:-8398A584BA9D1433}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_NAME="${GITHUB_NAME:-Augusto}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say() { printf '[publish] %s\n' "$*"; }

SOURCE_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
[ -n "$SOURCE_BRANCH" ] || { echo "[publish] detached HEAD — checkout a branch first" >&2; exit 1; }

if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  echo "[publish] working tree is dirty. Commit or stash first: a published copy" >&2
  echo "          must correspond to a commit, not to a moment." >&2
  exit 1
fi

gpg --list-secret-keys "$GITHUB_SIGNKEY" >/dev/null 2>&1 \
  || { echo "[publish] signing key $GITHUB_SIGNKEY not in the keyring" >&2; exit 1; }

# The published copy must have passed the same gate as the primary remote.
#
# It would not otherwise: this script pushes from a throwaway clone, and a clone
# carries no hooks, so the pre-push check that guards `git push` simply is not
# there. That turns the publication path into the shortest way around the gate --
# push what the gate refused, to the one remote that is public. Running the hook
# ourselves closes it, and reusing the hook rather than reimplementing its four
# assertions means the two cannot drift apart.
if [ "$DRY_RUN" != "1" ]; then
  if ! bash "$REPO_ROOT/layers/l2-output-gate/pre-push-hook.sh"; then
    echo "[publish] REFUSING: no valid GO token for $(git -C "$REPO_ROOT" rev-parse --short HEAD)." >&2
    echo "          Publishing is a push like any other. Run the gate first:" >&2
    echo "            python3 layers/l2-output-gate/pipeline.py" >&2
    exit 1
  fi
fi

say "source   $SOURCE_BRANCH ($(git -C "$REPO_ROOT" rev-parse --short HEAD))"
say "target   $GITHUB_REPO ($GITHUB_BRANCH)"
say "identity $GITHUB_NOREPLY"
say "key      $GITHUB_SIGNKEY"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q --branch "$SOURCE_BRANCH" "$REPO_ROOT" "$WORK/copy"
cd "$WORK/copy"

export FILTER_BRANCH_SQUELCH_WARNING=1
git filter-branch -f --env-filter "
  export GIT_AUTHOR_NAME='$GITHUB_NAME'
  export GIT_AUTHOR_EMAIL='$GITHUB_NOREPLY'
  export GIT_COMMITTER_NAME='$GITHUB_NAME'
  export GIT_COMMITTER_EMAIL='$GITHUB_NOREPLY'
" --commit-filter "
  git commit-tree -S$GITHUB_SIGNKEY \"\$@\"
" -- "$SOURCE_BRANCH" >/dev/null 2>&1

# Refuse to publish a copy whose content differs from the source. The rewrite
# must change identity and nothing else; a differing tree means something went
# wrong, and a public push is not the place to find that out.
SRC_TREE="$(git -C "$REPO_ROOT" rev-parse "$SOURCE_BRANCH^{tree}")"
DST_TREE="$(git rev-parse "$SOURCE_BRANCH^{tree}")"
if [ "$SRC_TREE" != "$DST_TREE" ]; then
  echo "[publish] REFUSING: rewritten tree differs from the source tree." >&2
  echo "          source $SRC_TREE" >&2
  echo "          copy   $DST_TREE" >&2
  exit 1
fi
say "tree     $DST_TREE (identical to source)"

leaked="$(git log --format='%ae %ce' | tr ' ' '\n' | sort -u | grep -v "^$GITHUB_NOREPLY$" || true)"
if [ -n "$leaked" ]; then
  echo "[publish] REFUSING: addresses other than the noreply one survived:" >&2
  printf '          %s\n' $leaked >&2
  exit 1
fi
say "identity clean · $(git log --oneline | wc -l | tr -d ' ') commits, all rewritten"

unsigned="$(git log --format='%G?' | grep -cv '^G$' || true)"
if [ "$unsigned" != "0" ]; then
  echo "[publish] REFUSING: $unsigned commit(s) carry no good signature" >&2
  exit 1
fi
say "signatures good on every commit"

if [ "$DRY_RUN" = "1" ]; then
  say "dry run — nothing pushed"
  # -5 rather than a pipe into head: the pipe closes early and leaves the
  # script exiting 141, which reads as a failure to anything checking it.
  git log -5 --format='  %h %ae %s'
  exit 0
fi

[ -n "${GITHUB_TOKEN:-}" ] || {
  echo "[publish] GITHUB_TOKEN is unset. Export a fine-grained PAT with" >&2
  echo "          Contents: Read and write, then re-run." >&2
  exit 1
}

OWNER="${GITHUB_REPO%%/*}"
REMOTE_URL="https://${OWNER}:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

git push --force "$REMOTE_URL" \
  "$SOURCE_BRANCH:$GITHUB_BRANCH" 2>&1 | sed "s/${GITHUB_TOKEN}/<token>/g"

# Tags need re-creating rather than copying. The published history is rewritten,
# so a tag from the source points at a commit that does not exist here; pushing
# it would leave a dangling reference. Any tag on the source HEAD is recreated
# on the rewritten HEAD instead, signed with the publishing key.
SOURCE_TAGS="$(git -C "$REPO_ROOT" tag --points-at HEAD 2>/dev/null || true)"
for _tag in $SOURCE_TAGS; do
  _msg="$(git -C "$REPO_ROOT" for-each-ref --format='%(contents:subject)' \
          "refs/tags/$_tag" 2>/dev/null)"
  [ -n "$_msg" ] || _msg="$_tag"
  git -c user.name="$GITHUB_NAME" -c user.email="$GITHUB_NOREPLY" \
      -c user.signingkey="$GITHUB_SIGNKEY" \
      tag -f -s "$_tag" -m "$_msg" >/dev/null 2>&1 \
    || git tag -f "$_tag" >/dev/null 2>&1
  git push --force "$REMOTE_URL" "refs/tags/$_tag" 2>&1 \
    | sed "s/${GITHUB_TOKEN}/<token>/g"
  say "tag $_tag published"
done

say "published → https://github.com/$GITHUB_REPO"
