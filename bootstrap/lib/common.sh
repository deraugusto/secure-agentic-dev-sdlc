#!/usr/bin/env bash
# bootstrap/lib/common.sh — output, prompting and the plan/apply split.
#
# Sourced by init.sh. Nothing here touches the filesystem on its own: every
# mutation goes through `act`, which is the single place where --dry-run turns
# a change into a printed line. That is the only way a dry run can be trusted
# to be complete -- a second code path that "also does a bit of work" is how
# --dry-run starts lying.

# bash 3.2 compatible on purpose: a recipient on macOS should not have to
# install a newer shell before they can read their own bootstrap.

SDLC_DRY_RUN="${SDLC_DRY_RUN:-0}"
SDLC_ASSUME_YES="${SDLC_ASSUME_YES:-0}"
SDLC_PLAN_COUNT=0
SDLC_CHANGE_COUNT=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_WARN=$'\033[33m'
  C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_OFF=$'\033[0m'
else
  C_DIM=""; C_BOLD=""; C_WARN=""; C_ERR=""; C_OK=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s── %s %s\n' "$C_BOLD" "$*" "$C_OFF"; }
info() { printf '  %s\n' "$*"; }
dim()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '\n  %sERROR%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# ── act · the only mutation seam ───────────────────────────────────────────
# act "<human description>" <command...>
#
# Dry run prints the description and the command it would have run. A real run
# prints the description and executes. Both count, so the summary line at the
# end reports the same number either way and a divergence is visible.
act() {
  description="$1"; shift
  SDLC_PLAN_COUNT=$((SDLC_PLAN_COUNT + 1))
  if [ "$SDLC_DRY_RUN" = "1" ]; then
    printf '  %s[plan]%s %s\n' "$C_DIM" "$C_OFF" "$description"
    printf '         %s%s%s\n' "$C_DIM" "$*" "$C_OFF"
    return 0
  fi
  printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$description"
  if ! "$@"; then
    die "failed: $description
         command: $*"
  fi
  SDLC_CHANGE_COUNT=$((SDLC_CHANGE_COUNT + 1))
  return 0
}

# act_noop · a step that was already in the desired state. Idempotence is
# reported, not silently skipped, so a second run reads as a confirmation
# rather than as a run that did nothing for unclear reasons.
act_noop() {
  printf '  %s·%s %s %s(already in place)%s\n' "$C_DIM" "$C_OFF" "$1" "$C_DIM" "$C_OFF"
}

# ── prompting ──────────────────────────────────────────────────────────────
# ask <varname> <question> [default]
#
# In non-interactive mode the variable keeps whatever the answers file set, and
# an unset variable with no default is fatal: guessing an address is exactly
# the failure that puts someone's container on the wrong cluster.
ask() {
  _var="$1"; _question="$2"; _default="${3:-}"
  eval "_current=\${$_var:-}"
  if [ -n "$_current" ]; then
    dim "$_question → $_current (from answers)"
    return 0
  fi
  if [ "$SDLC_ASSUME_YES" = "1" ]; then
    if [ -z "$_default" ]; then
      die "non-interactive: '$_var' is unanswered and has no default.
         Add $_var=... to the answers file."
    fi
    eval "$_var=\$_default"
    dim "$_question → $_default (default)"
    return 0
  fi
  if [ -n "$_default" ]; then
    printf '  %s [%s]: ' "$_question" "$_default"
  else
    printf '  %s: ' "$_question"
  fi
  IFS= read -r _reply || _reply=""
  [ -z "$_reply" ] && _reply="$_default"
  [ -z "$_reply" ] && die "'$_question' needs an answer."
  eval "$_var=\$_reply"
}

# ask_yn <varname> <question> <yes|no default>
ask_yn() {
  _var="$1"; _question="$2"; _default="$3"
  eval "_current=\${$_var:-}"
  if [ -n "$_current" ]; then
    dim "$_question → $_current (from answers)"
    return 0
  fi
  if [ "$SDLC_ASSUME_YES" = "1" ]; then
    eval "$_var=\$_default"
    dim "$_question → $_default (default)"
    return 0
  fi
  printf '  %s [%s]: ' "$_question" "$_default"
  IFS= read -r _reply || _reply=""
  [ -z "$_reply" ] && _reply="$_default"
  case "$_reply" in
    y|Y|yes|YES|true|1)  eval "$_var=yes" ;;
    n|N|no|NO|false|0)   eval "$_var=no" ;;
    *) die "answer yes or no, got '$_reply'" ;;
  esac
}

# confirm <question> — a hard gate. Refusing aborts the bootstrap.
confirm() {
  if [ "$SDLC_ASSUME_YES" = "1" ]; then
    dim "$1 → yes (non-interactive)"
    return 0
  fi
  printf '\n  %s%s%s [yes/no]: ' "$C_BOLD" "$1" "$C_OFF"
  IFS= read -r _reply || _reply=""
  case "$_reply" in
    y|Y|yes|YES) return 0 ;;
    *) die "aborted at confirmation — nothing was changed." ;;
  esac
}
