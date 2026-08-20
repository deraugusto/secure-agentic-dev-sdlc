#!/usr/bin/env bash
# L1 · negative probes for the input scanner.
#
# The scanner's job is to reject, so these cases are the specification. Each one
# runs in a throwaway working copy under a temp directory, with its own state
# and audit paths, so nothing here touches your repository or your audit trail.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$LAYER/../.." && pwd)"
SCANNER="$LAYER/sanitize.py"

PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
  if [ "$1" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  printf '%-5s %-32s %s\n' "$1" "$2" "$3"
}

CASE_N=0
# scan <case-name> <expect: accept|reject> <phrase|-> <python-expression>
#
# The content is a Python EXPRESSION, and hostile characters in it are built
# with chr() rather than written as literals. That is the same discipline
# sanitize.py applies to its own character classes, and for the same reason: a
# file full of literal bidi overrides is a file the scanner rejects on its next
# full scan -- so the probe suite would break the thing it is probing.
scan() {
  _name="$1"; _expect="$2"; _phrase="$3"; _content="$4"
  CASE_N=$((CASE_N+1))
  _dir="$WORK/case$CASE_N"
  mkdir -p "$_dir"
  python3 -c "import sys; open(sys.argv[1],'w',encoding='utf-8').write($_content)" \
    "$_dir/subject.js"

  _out="$( cd "$_dir" && SDLC_REPO_ROOT="$_dir" \
             SDLC_STATE_DIR="$_dir/.state" \
             SDLC_SANITIZE_AUDIT="$_dir/.state/sanitize.jsonl" \
             SDLC_PATTERNS="$LAYER/patterns/baseline.json" \
             python3 "$SCANNER" --trigger probe subject.js 2>&1 )"
  _rc=$?

  if [ "$_expect" = "accept" ] && [ "$_rc" -ne 0 ]; then
    report FAIL "$_name" "expected accept, got exit $_rc"
    printf '%s\n' "$_out" | sed 's/^/        /'
    return
  fi
  if [ "$_expect" = "reject" ] && [ "$_rc" -eq 0 ]; then
    report FAIL "$_name" "expected reject, got exit 0"
    return
  fi
  if [ "$_phrase" != "-" ] && ! printf '%s' "$_out" | grep -qi -- "$_phrase"; then
    report FAIL "$_name" "verdict right, but never named '$_phrase'"
    printf '%s\n' "$_out" | sed 's/^/        /'
    return
  fi
  report PASS "$_name" "exit=$_rc"
  LAST_DIR="$_dir"
}

printf '\n── ordinary content must pass, or every rejection below is noise ──\n\n'

scan clean-file-accepted accept - \
  "'const answer = 42;' + chr(10) + '// a perfectly ordinary comment' + chr(10)"

printf '\n── hostile text an agent would read differently than a human ──\n\n'

# U+202E flips the visual order of what follows. What a reviewer reads and what
# the parser sees are then two different programs.
scan bidi-override-rejected reject "bidi" \
  "'const admin = false; //' + chr(0x202E) + 'eslaf = nimda' + chr(0x202C) + chr(10)"

# A zero-width space inside an identifier makes two different identifiers look
# like one.
scan zero-width-rejected reject "-" \
  "'const to' + chr(0x200B) + 'ken = secret;' + chr(10)"

# Cyrillic 'а' in an otherwise Latin identifier.
scan mixed-script-rejected reject "homoglyph" \
  "'function upd' + chr(0x430) + 'te() { return 1; }' + chr(10)"

printf '\n── the bypass must be loud and audited, never silent ──\n\n'

_dir="$WORK/bypass"
mkdir -p "$_dir/.state"
python3 -c "import sys; open(sys.argv[1],'w',encoding='utf-8').write('const x = 1; //' + chr(0x202E) + 'dehcuotednu' + chr(0x202C) + chr(10))" \
  "$_dir/subject.js"
_out="$( cd "$_dir" && SDLC_REPO_ROOT="$_dir" SDLC_STATE_DIR="$_dir/.state" \
           SDLC_SANITIZE_AUDIT="$_dir/.state/sanitize.jsonl" \
           SDLC_PATTERNS="$LAYER/patterns/baseline.json" \
           SDLC_NO_SANITIZE=1 python3 "$SCANNER" --trigger probe subject.js 2>&1 )"
_rc=$?

if [ "$_rc" -eq 0 ]; then
  report PASS bypass-lets-content-through "exit=0"
else
  report FAIL bypass-lets-content-through "the bypass did not bypass (exit $_rc)"
fi

if printf '%s' "$_out" | grep -qi "bypassed"; then
  report PASS bypass-announces-itself "said BYPASSED on stderr"
else
  report FAIL bypass-announces-itself "bypassed silently"
fi

if grep -q '"verdict": *"bypassed"' "$_dir/.state/sanitize.jsonl" 2>/dev/null; then
  report PASS bypass-is-audited "recorded as bypassed, not as a pass"
else
  report FAIL bypass-is-audited "no bypass entry in the audit log"
fi

printf '\n── fail closed · a scanner that cannot scan must not report success ──\n\n'

_dir="$WORK/nopatterns"
mkdir -p "$_dir/.state"
printf 'const x = 1;\n' > "$_dir/subject.js"
_out="$( cd "$_dir" && SDLC_REPO_ROOT="$_dir" SDLC_STATE_DIR="$_dir/.state" \
           SDLC_SANITIZE_AUDIT="$_dir/.state/sanitize.jsonl" \
           SDLC_PATTERNS="$_dir/does-not-exist.json" \
           python3 "$SCANNER" --trigger probe subject.js 2>&1 )"
if [ $? -ne 0 ]; then
  report PASS missing-pattern-file-fails-closed "refused to scan without patterns"
else
  report FAIL missing-pattern-file-fails-closed "reported success with no pattern library"
fi

_dir="$WORK/badpatterns"
mkdir -p "$_dir/.state"
printf 'const x = 1;\n' > "$_dir/subject.js"
printf '{"schema": "something-else/9", "patterns": []}\n' > "$_dir/patterns.json"
_out="$( cd "$_dir" && SDLC_REPO_ROOT="$_dir" SDLC_STATE_DIR="$_dir/.state" \
           SDLC_SANITIZE_AUDIT="$_dir/.state/sanitize.jsonl" \
           SDLC_PATTERNS="$_dir/patterns.json" \
           python3 "$SCANNER" --trigger probe subject.js 2>&1 )"
if [ $? -ne 0 ]; then
  report PASS wrong-pattern-schema-fails-closed "refused an unrecognised schema"
else
  report FAIL wrong-pattern-schema-fails-closed "accepted a pattern file it cannot understand"
fi

printf '\n── the wrapper seam ──\n\n'

_out="$( SDLC_AGENT_BIN= "$LAYER/agent-safe" 2>&1 )"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -qi "refusing to guess"; then
  report PASS wrapper-without-agent-refuses "will not guess a binary"
else
  report FAIL wrapper-without-agent-refuses "guessed, or failed silently"
fi

# The wrapper resolves its scanner next to itself, so the way to lose it is to
# copy agent-safe out of the baseline instead of symlinking it. That must fail
# closed: a wrapper that execs the agent because it cannot find its own scanner
# is worse than no wrapper, since it still looks like protection.
_dir="$WORK/noscanner"
mkdir -p "$_dir"
cp "$LAYER/agent-safe" "$_dir/agent-safe"
chmod +x "$_dir/agent-safe"
printf '#!/bin/sh\necho ran\n' > "$_dir/fake-agent"
chmod +x "$_dir/fake-agent"
_out="$( SDLC_AGENT_BIN="$_dir/fake-agent" "$_dir/agent-safe" 2>&1 )"
if [ $? -ne 0 ] && ! printf '%s' "$_out" | grep -q "^ran$"; then
  report PASS wrapper-without-scanner-refuses "a copied-out wrapper refuses"
else
  report FAIL wrapper-without-scanner-refuses "ran the agent with no scanner present"
fi
if printf '%s' "$_out" | grep -q "symlink it instead"; then
  report PASS wrapper-explains-the-fix "told the operator to symlink instead of copy"
else
  report FAIL wrapper-explains-the-fix "refused without saying how to fix it"
fi

printf '\n── one baseline, many projects ──\n\n'

# The wrapper has to resolve its scanner next to itself and scan the project it
# is pointed at. Getting that backwards means one copy of the baseline per
# project -- and worse, a version that scans the baseline instead of the target
# reports clean and runs the agent anyway. That failure is silent.
_proj="$WORK/foreign-project"
mkdir -p "$_proj"
( cd "$_proj" && git init -q . ) 2>/dev/null
python3 -c "import sys; open(sys.argv[1],'w',encoding='utf-8').write('const a = 1; //' + chr(0x202E) + 'nedloh' + chr(0x202C) + chr(10))" \
  "$_proj/hostile.js"

_bin="$WORK/bin"
mkdir -p "$_bin"
printf '#!/bin/sh\necho AGENT-RAN\n' > "$_bin/fake-agent-real"
chmod +x "$_bin/fake-agent-real"
# Reached through a symlink, the way the installer sets it up.
ln -sf "$LAYER/agent-safe" "$_bin/fake-agent"

_out="$( cd "$_proj" && SDLC_AGENT_BIN="$_bin/fake-agent-real" \
         "$_bin/fake-agent" 2>&1 )"
_rc=$?
if [ "$_rc" -ne 0 ] && ! printf '%s' "$_out" | grep -q "AGENT-RAN"; then
  report PASS wrapper-scans-the-target "hostile file in another project blocked it"
else
  report FAIL wrapper-scans-the-target "the agent ran; the scan looked at the wrong tree"
fi

if printf '%s' "$_out" | grep -q "hostile.js"; then
  report PASS wrapper-names-the-target-file "named the file in the project"
else
  report FAIL wrapper-names-the-target-file "rejected, but not because of the target"
fi

rm -f "$_proj/hostile.js"
_out="$( cd "$_proj" && SDLC_AGENT_BIN="$_bin/fake-agent-real" \
         "$_bin/fake-agent" 2>&1 )"
if printf '%s' "$_out" | grep -q "AGENT-RAN"; then
  report PASS wrapper-runs-on-clean-target "a clean project starts the agent"
else
  report FAIL wrapper-runs-on-clean-target "refused a clean project"
fi

printf '\n%s/%s PASS\n\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
