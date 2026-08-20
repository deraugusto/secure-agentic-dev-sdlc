#!/usr/bin/env bash
# commit-lint · validates one commit message against CONVENTIONS.md section 1.
#
#   ./layers/l0-governance/commit-lint.sh <file-with-message>
#   git log -1 --format=%B | ./layers/l0-governance/commit-lint.sh -
#
# Installed as a commit-msg hook by ./bootstrap/init.sh when L0 is enabled.
#
# Subject : <type>(<scope>): <imperative summary>
#           lowercase, no trailing period, <= 72 chars
# Types   : adr index doc script config example meta
# Trailer : an autonomous, agent-produced commit carries a final
#           'Auto-Class: <class>' line naming what kind of change it is.
#           Two classes are never committed autonomously — see below.
#
# Exit 0 valid · 1 invalid · 2 usage error

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: commit-lint.sh <message-file>|-" >&2
  exit 2
fi

if [[ "$1" == "-" ]]; then
  message="$(cat)"
else
  [[ -f "$1" ]] || { echo "error: no such file: $1" >&2; exit 2; }
  message="$(cat "$1")"
fi

# Drop comment lines git puts in the editor template.
message="$(printf '%s\n' "$message" | grep -v '^#' || true)"

subject="$(printf '%s\n' "$message" | head -1)"
body="$(printf '%s\n' "$message" | tail -n +2)"

VALID_TYPES="adr index doc script config example meta"

# Classes an autonomous agent may commit on its own.
AUTO_CLASSES="governance-spine input-hardening output-gate reviewer server-enforcement deploy-audit example-service docs"
# Classes it may not. Output stays in the working tree; a human decides.
BLOCKED_CLASSES="secrets-handling out-of-scope"

errs=()

if [[ -z "${subject// }" ]]; then
  errs+=("subject: empty")
fi

if (( ${#subject} > 72 )); then
  errs+=("subject: ${#subject} chars, limit is 72")
fi

if [[ "$subject" =~ \.$ ]]; then
  errs+=("subject: remove the trailing period")
fi

if [[ ! "$subject" =~ ^[a-z]+(\([a-zA-Z0-9._/§-]+\))?:\ .+ ]]; then
  errs+=("subject: expected '<type>(<scope>): <summary>'")
else
  commit_type="${subject%%[(:]*}"
  if ! printf '%s\n' $VALID_TYPES | grep -qx "$commit_type"; then
    errs+=("type: '$commit_type' not in {$VALID_TYPES}")
  fi
  summary="${subject#*: }"
  if [[ "$summary" =~ ^[A-Z] ]]; then
    errs+=("summary: starts uppercase, keep it lowercase")
  fi
  first_word="${summary%% *}"
  case "$first_word" in
    *ed|*ing)
      errs+=("summary: '$first_word' is not imperative (use 'add', not 'added'/'adding')")
      ;;
  esac
fi

# Second line, if there is a body at all, must be blank.
second_line="$(printf '%s\n' "$message" | sed -n '2p')"
if [[ -n "$(printf '%s' "$body" | tr -d '[:space:]')" && -n "${second_line// }" ]]; then
  errs+=("body: leave a blank line between subject and body")
fi

auto_class="$(printf '%s\n' "$message" | grep -E '^Auto-Class:' | tail -1 \
  | sed -E 's/^Auto-Class:[[:space:]]*//')"

if [[ -n "$auto_class" ]]; then
  if printf '%s\n' $BLOCKED_CLASSES | grep -qx "$auto_class"; then
    errs+=("Auto-Class: '$auto_class' must not be committed autonomously — leave the change in the working tree and ask")
  elif ! printf '%s\n' $AUTO_CLASSES | grep -qx "$auto_class"; then
    errs+=("Auto-Class: '$auto_class' not in {$AUTO_CLASSES}")
  else
    last_nonempty="$(printf '%s\n' "$message" | grep -v '^[[:space:]]*$' | tail -1)"
    if [[ "$last_nonempty" != "Auto-Class:"* ]]; then
      errs+=("Auto-Class: must be the last line of the message")
    fi
  fi
fi

if [[ ${#errs[@]} -eq 0 ]]; then
  echo "commit-lint: ok"
  exit 0
fi

echo "commit-lint: rejected" >&2
printf '  subject: %s\n' "$subject" >&2
for err in "${errs[@]}"; do
  printf '    - %s\n' "$err" >&2
done
exit 1
