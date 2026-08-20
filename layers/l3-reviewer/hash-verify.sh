#!/usr/bin/env bash
# L3 · apparatus hash verification, standalone.
#
# The service verifies itself on every call. This exists for the cases where
# that is not enough: a scheduled check, a monitoring probe, or an operator who
# wants an answer without sending a review request.
#
#   ./hash-verify.sh            verify, exit 0 or 1
#   ./hash-verify.sh --seal     rewrite checksums.txt from the current files
#
# Fail-closed: a missing checksums file is a mismatch, never a skip. That is the
# whole point -- "no checksums, so nothing to check" is how integrity
# verification quietly stops happening.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUMS="$HERE/checksums.txt"
APPARATUS=(reviewer_service.py backends.py system-prompt.md bundle-schema.json)

if [[ "${1:-}" == "--seal" ]]; then
  : > "$CHECKSUMS.tmp"
  for file in "${APPARATUS[@]}"; do
    if [[ ! -f "$HERE/$file" ]]; then
      echo "seal: apparatus file missing: $file" >&2
      rm -f "$CHECKSUMS.tmp"
      exit 1
    fi
    ( cd "$HERE" && sha256sum "$file" ) >> "$CHECKSUMS.tmp"
  done
  mv "$CHECKSUMS.tmp" "$CHECKSUMS"
  echo "sealed $CHECKSUMS"
  exit 0
fi

if [[ ! -f "$CHECKSUMS" ]]; then
  echo "hash-verify: FAIL checksums-file-missing ($CHECKSUMS)" >&2
  echo "hash-verify: an unsealed apparatus is treated as a tampered one." >&2
  exit 1
fi

failed=0
for file in "${APPARATUS[@]}"; do
  expected="$(awk -v f="$file" '$2 == f { print $1 }' "$CHECKSUMS")"
  if [[ -z "$expected" ]]; then
    echo "hash-verify: FAIL unlisted-apparatus-file:$file" >&2
    failed=1
    continue
  fi
  if [[ ! -f "$HERE/$file" ]]; then
    echo "hash-verify: FAIL apparatus-file-missing:$file" >&2
    failed=1
    continue
  fi
  actual="$( cd "$HERE" && sha256sum "$file" | awk '{print $1}' )"
  if [[ "$actual" != "$expected" ]]; then
    echo "hash-verify: FAIL apparatus-hash-mismatch:$file" >&2
    failed=1
  fi
done

if (( failed )); then
  echo "hash-verify: apparatus NOT verified" >&2
  exit 1
fi

echo "hash-verify: ok · ${#APPARATUS[@]} files match"
exit 0
