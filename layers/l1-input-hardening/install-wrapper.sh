#!/usr/bin/env bash
# L1 · put an agent behind the scanner, reversibly.
#
#   ./install-wrapper.sh --agent claude --dry-run
#   ./install-wrapper.sh --agent claude
#   ./install-wrapper.sh --agent claude --uninstall
#   ./install-wrapper.sh --status
#
# The manual instructions in agent-safe describe three steps: rename the real
# binary out of PATH, symlink the wrapper over its name, and export
# SDLC_AGENT_BIN. Doing that by hand for one agent is fine. Doing it for four
# agents on three machines is where someone skips the rename, leaves the
# original name resolvable, and ends up with a wrapper that any PATH change
# walks around.
#
# So this automates it, with two rules it does not bend:
#
#   * The real binary is RENAMED, never copied. A copy left under the original
#     name is a bypass with a shorter path than the wrapper.
#   * Nothing is written to your shell profile unless you ask. The export line
#     is printed; where it belongs is your decision, not this script's.
#
# Every step is reversible with --uninstall, which is why the rename target is
# derived rather than random: <name>-real, next to the original.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/agent-safe"

AGENTS=""
FROM_FILE=""
PREFIX=""
DRY_RUN=0
UNINSTALL=0
STATUS=0

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)     AGENTS="$AGENTS ${2:?--agent needs a name or path}"; shift 2 ;;
    --from-file) FROM_FILE="${2:?--from-file needs a path}"; shift 2 ;;
    --prefix)    PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --status)    STATUS=1; shift ;;
    -h|--help)   usage ;;
    *) echo "unknown argument: $1  (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '[L1] %s\n' "$*"; }
die()  { printf '[L1] %s\n' "$*" >&2; exit 1; }
plan() { if [ "$DRY_RUN" = "1" ]; then printf '[L1] would: %s\n' "$*"; else eval "$@"; fi; }

[ -f "$WRAPPER" ] || die "wrapper not found: $WRAPPER"

# ── status ─────────────────────────────────────────────────────────────────
if [ "$STATUS" = "1" ]; then
  say "wrapper: $WRAPPER"
  say "SDLC_AGENT_BIN: ${SDLC_AGENT_BIN:-<unset>}"
  found=0
  IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for candidate in "$dir"/*; do
      [ -L "$candidate" ] || continue
      target="$(readlink "$candidate" 2>/dev/null || true)"
      case "$target" in
        */agent-safe)
          say "wrapped: $candidate -> $target"
          found=1
          ;;
      esac
    done
  done
  unset IFS
  [ "$found" = "0" ] && say "no wrapped agents found on PATH"
  exit 0
fi

# A fleet is installed the same way one agent is, just repeatedly. --from-file
# takes one name or path per line, '#' comments and blank lines ignored, so the
# list can come out of whatever inventory you already keep.
if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] || die "no such file: $FROM_FILE"
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%%#*}"
    _line="$(printf '%s' "$_line" | tr -d '[:space:]')"
    [ -n "$_line" ] && AGENTS="$AGENTS $_line"
  done < "$FROM_FILE"
fi

AGENTS="$(printf '%s' "$AGENTS" | sed 's/^ *//')"
[ -n "$AGENTS" ] || die "which agent? pass --agent <name-or-path>, --from-file <list>,
     or --status"

# More than one: recurse per agent so that a single failure does not abandon the
# rest half-done, and report a summary. Exit non-zero if any of them failed.
_count="$(printf '%s\n' $AGENTS | wc -l | tr -d ' ')"
if [ "$_count" -gt 1 ]; then
  _ok=0; _failed=""
  for _one in $AGENTS; do
    printf '\n'
    if "$0" --agent "$_one" ${PREFIX:+--prefix "$PREFIX"} \
         $([ "$DRY_RUN" = "1" ] && echo --dry-run) \
         $([ "$UNINSTALL" = "1" ] && echo --uninstall); then
      _ok=$((_ok + 1))
    else
      _failed="$_failed $_one"
    fi
  done
  printf '\n[L1] %s of %s agents done\n' "$_ok" "$_count"
  [ -n "$_failed" ] && { printf '[L1] failed:%s\n' "$_failed" >&2; exit 1; }
  exit 0
fi

AGENT="$AGENTS"

# Resolve the agent to an absolute path. A bare name is looked up on PATH, but
# never through the wrapper itself -- otherwise a second run would wrap the
# wrapper and lose the real binary.
if [ -x "$AGENT" ] && [ "${AGENT#/}" != "$AGENT" ]; then
  AGENT_PATH="$AGENT"
else
  AGENT_PATH="$(command -v "$AGENT" 2>/dev/null || true)"
fi
[ -n "$AGENT_PATH" ] || die "cannot find '$AGENT' on PATH and it is not an executable path"

AGENT_NAME="$(basename "$AGENT_PATH")"
AGENT_DIR="$(dirname "$AGENT_PATH")"
[ -n "$PREFIX" ] || PREFIX="$AGENT_DIR"
REAL="$PREFIX/${AGENT_NAME}-real"
LINK="$PREFIX/$AGENT_NAME"

# ── uninstall ──────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "1" ]; then
  if [ ! -e "$REAL" ]; then
    die "nothing to restore: $REAL does not exist"
  fi
  if [ -L "$LINK" ]; then
    plan "rm -f '$LINK'"
  elif [ -e "$LINK" ]; then
    die "$LINK exists and is not a symlink — refusing to remove something this
     script did not create. Move it aside and re-run."
  fi
  plan "mv '$REAL' '$LINK'"
  say "restored $LINK"
  say "you can now unset SDLC_AGENT_BIN"
  exit 0
fi

# ── already installed? ─────────────────────────────────────────────────────
if [ -L "$AGENT_PATH" ]; then
  target="$(readlink "$AGENT_PATH")"
  case "$target" in
    */agent-safe)
      say "$AGENT_PATH is already wrapped -> $target"
      if [ -x "$REAL" ]; then
        say "real binary: $REAL"
        say "export SDLC_AGENT_BIN=$REAL"
        exit 0
      fi
      die "wrapped, but $REAL is missing. The real binary is gone; restore it
     from your package manager before relying on this."
      ;;
  esac
fi

if [ -e "$REAL" ]; then
  die "$REAL already exists. Either a previous run was interrupted, or that
     name is taken. Inspect it before continuing."
fi

# ── install ────────────────────────────────────────────────────────────────
say "agent      $AGENT_PATH"
say "rename to  $REAL"
say "wrapper    $LINK -> $WRAPPER"

if [ ! -w "$PREFIX" ] && [ "$DRY_RUN" != "1" ]; then
  die "$PREFIX is not writable by you. Re-run with sudo, or use --prefix with a
     directory you own that comes EARLIER on PATH than $AGENT_DIR.
     Be aware that the second option is weaker: the original name still
     resolves, so a PATH change walks around the wrapper."
fi

plan "mv '$AGENT_PATH' '$REAL'"
plan "ln -s '$WRAPPER' '$LINK'"

if [ "$DRY_RUN" = "1" ]; then
  say "dry run — nothing changed"
  exit 0
fi

# Verify rather than assume: a wrapper that is not actually in front of the
# agent is worse than none, because it looks like protection.
[ -L "$LINK" ] || die "post-check failed: $LINK is not a symlink"
[ -x "$REAL" ] || die "post-check failed: $REAL is not executable"
say "installed and verified"

cat <<TXT

  One step is left, and it is yours because it belongs in your shell:

      export SDLC_AGENT_BIN=$REAL

  Add it to ~/.profile, ~/.bashrc or ~/.zshenv. Without it the wrapper refuses
  to run rather than guessing which binary you meant.

  Check anytime with:  $0 --status
  Undo with:           $0 --agent $AGENT_NAME --uninstall
TXT
