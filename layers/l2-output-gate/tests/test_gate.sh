#!/usr/bin/env bash
# L2 · negative probes for the output gate and the GO token.
#
# The gate's claim is narrow and worth stating exactly: a push is allowed only
# if the gate produced a GO for THIS commit, recently, and nobody edited the
# result. These cases attack each half of that sentence.
#
# Every case runs in a throwaway git repository under a temp directory. Your
# repository, your hooks and your token are never touched.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$LAYER/../.." && pwd)"

PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'stop_reviewer; rm -rf "$WORK"' EXIT

report() {
  if [ "$1" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  printf '%-5s %-36s %s\n' "$1" "$2" "$3"
}

command -v git >/dev/null 2>&1 || {
  echo "git is required for these probes" >&2; exit 2; }

# A repository with the baseline in it, one conforming commit, and no
# credentials involved. gpgsign is off because a signing prompt in a probe
# suite is a probe suite nobody runs.
new_repo() {
  _dir="$WORK/$1"
  mkdir -p "$_dir"
  ( cd "$REPO_ROOT" && tar cf - layers lib example inventory.example.yaml 2>/dev/null ) \
    | ( cd "$_dir" && tar xf - )
  cp "$_dir/inventory.example.yaml" "$_dir/inventory.yaml"
  (
    cd "$_dir"
    git init -q .
    git config user.email probe@example.invalid
    git config user.name  Probe
    git config commit.gpgsign false
    git add -A
    git commit -qm "meta(probe): seed the probe repository"
  ) >/dev/null 2>&1
  printf '%s' "$_dir"
}

# commit_change <repo> <message> — one small, harmless edit.
commit_change() {
  (
    cd "$1"
    printf 'const probe = %s;\n' "$RANDOM" > example/hello-world-node/probe.js
    git add -A
    git commit -qm "$2"
  ) >/dev/null 2>&1
}

run_gate() {
  _repo="$1"; shift
  ( cd "$_repo" && SDLC_REVIEWER_HOST=127.0.0.1 SDLC_REVIEWER_PORT="$REVIEWER_PORT" \
      python3 layers/l2-output-gate/pipeline.py "$@" 2>&1 )
}

# The reviewer runs with provider=offline: a canned verdict, real mechanics.
# That is the right shape for a probe suite -- the cases here are about the
# gate's plumbing, and a probe suite that needs a GPU is a probe suite nobody
# runs. Whether the review itself is worth anything is L3's question.
REVIEWER_PID=""
REVIEWER_PORT=""

start_reviewer() {
  REVIEWER_PORT="$(python3 -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()")"
  SDLC_REVIEWER_PROVIDER=offline SDLC_REVIEWER_MODEL=offline-canned \
  SDLC_REVIEWER_LISTEN=127.0.0.1 SDLC_REVIEWER_PORT="$REVIEWER_PORT" \
  SDLC_REVIEWER_AUDIT="$WORK/reviewer-audit.jsonl" \
    python3 "$LAYER/../l3-reviewer/reviewer_service.py" --serve \
    >"$WORK/reviewer.log" 2>&1 &
  REVIEWER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1', $REVIEWER_PORT)) == 0 else 1)" 2>/dev/null; then
      return 0
    fi
    sleep 0.3
  done
  echo "reviewer did not come up; see $WORK/reviewer.log" >&2
  return 1
}

stop_reviewer() {
  [ -n "$REVIEWER_PID" ] && kill "$REVIEWER_PID" 2>/dev/null
  REVIEWER_PID=""
}

run_prepush() {
  ( cd "$1" && bash layers/l2-output-gate/pre-push-hook.sh 2>&1 )
}

printf '\n── reviewer unreachable · the gate must fail closed ──\n\n'

# Before starting the reviewer: a gate that cannot reach its reviewer has not
# been reviewed, and the only honest answer is NO-GO. A gate that degrades to
# a pass here is a gate that stops meaning anything the first time a service
# is down -- which is exactly when someone would want it to.
REVIEWER_PORT=1     # nothing listens on port 1
R="$(new_repo noreviewer)"
commit_change "$R" "example(probe): add a probe file"
_out="$(run_gate "$R")"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -q "NO-GO"; then
  report PASS unreachable-reviewer-is-no-go "S4 unreachable → NO-GO"
else
  report FAIL unreachable-reviewer-is-no-go "the gate passed without a review"
fi
if [ ! -f "$R/.sdlc/current-go.token" ]; then
  report PASS unreachable-reviewer-issues-no-token "no token"
else
  report FAIL unreachable-reviewer-issues-no-token "a token was issued with no review"
fi

printf '\n── the happy path, so the refusals below mean something ──\n\n'

start_reviewer || { echo "cannot run the remaining probes without a reviewer" >&2; exit 2; }

R="$(new_repo happy)"
commit_change "$R" "example(probe): add a probe file"
_out="$(run_gate "$R")"
if [ -f "$R/.sdlc/current-go.token" ]; then
  report PASS gate-issues-token-on-go "token written"
else
  report FAIL gate-issues-token-on-go "no token; gate said: $(printf '%s' "$_out" | tail -3 | tr '\n' ' ')"
fi

_out="$(run_prepush "$R")"
if [ $? -eq 0 ]; then
  report PASS valid-token-allows-push "pre-push accepted"
else
  report FAIL valid-token-allows-push "$_out"
fi

printf '\n── no token, no push ──\n\n'

R="$(new_repo notoken)"
commit_change "$R" "example(probe): add a probe file"
_out="$(run_prepush "$R")"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -q "no GO token"; then
  report PASS missing-token-blocks-push "said which file it wanted"
else
  report FAIL missing-token-blocks-push "a push with no gate run was allowed"
fi

printf '\n── a token is about one commit, not about the branch ──\n\n'

R="$(new_repo stale)"
commit_change "$R" "example(probe): first change"
run_gate "$R" >/dev/null
commit_change "$R" "example(probe): second change, after the gate ran"
_out="$(run_prepush "$R")"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -qi "stale token"; then
  report PASS token-does-not-carry-forward "gate passed a different commit"
else
  report FAIL token-does-not-carry-forward "a token minted for an earlier commit was spent on a later one"
fi

printf '\n── a token is a claim about content, sealed against editing ──\n\n'

R="$(new_repo tampered)"
commit_change "$R" "example(probe): add a probe file"
run_gate "$R" >/dev/null
python3 - "$R/.sdlc/current-go.token" <<'PY'
import json, sys
path = sys.argv[1]
token = json.load(open(path))
token["ttl_s"] = 999999          # a longer life than the gate granted
json.dump(token, open(path, "w"))
PY
_out="$(run_prepush "$R")"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -qi "seal mismatch"; then
  report PASS edited-token-field-detected "seal caught the edit"
else
  report FAIL edited-token-field-detected "an edited token was accepted"
fi

R="$(new_repo forged)"
commit_change "$R" "example(probe): add a probe file"
run_gate "$R" >/dev/null
python3 - "$R/.sdlc/current-go.token" <<'PY'
import json, sys
path = sys.argv[1]
token = json.load(open(path))
token["decision"] = "GO"
token["run_id"] = "hand-written"
json.dump(token, open(path, "w"))
PY
_out="$(run_prepush "$R")"
if [ $? -ne 0 ]; then
  report PASS hand-written-token-rejected "refused"
else
  report FAIL hand-written-token-rejected "a hand-written token passed as a gate result"
fi

printf '\n── a token expires ──\n\n'

R="$(new_repo expired)"
commit_change "$R" "example(probe): add a probe file"
run_gate "$R" >/dev/null
# Re-seal an old timestamp properly, so this case tests the TTL and not the
# seal. A probe that trips an earlier check proves nothing about a later one.
python3 - "$R/.sdlc/current-go.token" <<'PY'
import hashlib, json, sys, time
path = sys.argv[1]
token = json.load(open(path))
token["issued_ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                   time.gmtime(time.time() - 10000))
fields = {
    "run_id": token["run_id"],
    "changeset_root_hash": token["changeset_root_hash"],
    "git_head": token["git_head"],
    "issued_ts": token["issued_ts"],
    "ttl_s": int(token["ttl_s"]),
    "decision": "GO",
}
token["seal"] = hashlib.sha256(
    json.dumps(fields, sort_keys=True).encode("utf-8")).hexdigest()
json.dump(token, open(path, "w"))
PY
_out="$(run_prepush "$R")"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -qi "expired"; then
  report PASS expired-token-blocks-push "TTL enforced with a valid seal"
else
  report FAIL expired-token-blocks-push "an old token was still spendable"
fi

printf '\n── stages that cannot be waived ──\n\n'

# S1 is deterministic and has no bypass. A commit message outside the
# convention must stop the gate even with --bypass-reviewer.
R="$(new_repo hardlint)"
commit_change "$R" "wip"
_out="$(run_gate "$R" --bypass-reviewer)"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -q "S1-HARDLINT FAIL"; then
  report PASS hardlint-not-waivable "bypass did not reach S1"
else
  report FAIL hardlint-not-waivable "a hard lint finding was waived"
fi
if [ ! -f "$R/.sdlc/current-go.token" ]; then
  report PASS no-token-on-no-go "NO-GO issued no token"
else
  report FAIL no-token-on-no-go "a token exists after a NO-GO"
fi

printf '\n── the manifests are sealed, and the gate checks its own seal ──\n\n'

R="$(new_repo manifest)"
commit_change "$R" "example(probe): add a probe file"
# Make S1 waivable by hand. If this were possible unnoticed, every "not
# waivable" claim in the manifests would be decoration.
sed -i.bak 's/^waivable: false/waivable: true/' \
  "$R/layers/l2-output-gate/manifests/s1-hardlint.yaml" && \
  rm -f "$R/layers/l2-output-gate/manifests/s1-hardlint.yaml.bak"
_out="$(run_gate "$R")"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -qi "manifest"; then
  report PASS edited-manifest-detected "gate refused to run on an edited manifest"
else
  report FAIL edited-manifest-detected "an edited stage manifest went unnoticed"
fi

printf '\n%s/%s PASS\n\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
