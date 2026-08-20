#!/usr/bin/env bash
# L2 · pre-push — the GO token consumer.
#
# Installed by ./bootstrap/init.sh as .git/hooks/pre-push when L2 is enabled.
# It does not re-run the gate. It checks that the gate ran, that it said GO,
# that it said so about *this* commit, and that it said so recently.
#
# Four assertions, in the order that fails cheapest first:
#
#   decision == GO      a token exists for another decision only if something
#                       wrote it by hand
#   git_head == HEAD     a token minted for an earlier commit does not carry
#                        forward to a later one
#   age <= ttl           a token generated in a quiet moment cannot be spent
#                        later against different code
#   seal matches         the fields were not edited after issuance
#
# On block: run the gate.
#     python3 layers/l2-output-gate/pipeline.py [--bypass-reviewer]

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
STATE_DIR="${SDLC_STATE_DIR:-$REPO/.sdlc}"
TOKEN_FILE="$STATE_DIR/current-go.token"
PIPELINE="$REPO/layers/l2-output-gate/pipeline.py"
HEAD_SHA="$(git rev-parse HEAD)"
NOW="$(date +%s)"

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "[L2] BLOCKED: no GO token at $TOKEN_FILE" >&2
  echo "[L2] the gate has not run for this commit, or it refused." >&2
  echo "[L2] run: python3 $PIPELINE" >&2
  exit 1
fi

python3 - "$TOKEN_FILE" "$HEAD_SHA" "$NOW" <<'PYEOF'
import calendar
import hashlib
import json
import sys
import time

token_file, head, now_s = sys.argv[1], sys.argv[2], int(sys.argv[3])


def block(message: str) -> None:
    print(f"[L2] BLOCKED: {message}", file=sys.stderr)
    sys.exit(1)


try:
    with open(token_file, encoding="utf-8") as fh:
        token = json.load(fh)
except Exception as exc:
    block(f"cannot read the GO token: {exc}")

if token.get("decision") != "GO":
    block(f"token decision is {token.get('decision')!r}, expected 'GO'")

token_head = token.get("git_head", "")
if token_head != head:
    block(f"stale token · issued for {token_head[:12]}…, HEAD is {head[:12]}… "
          "— the gate passed a different commit")

issued_ts = token.get("issued_ts", "")
ttl_s = int(token.get("ttl_s", 900))
try:
    # timegm, not mktime: the token's timestamp is UTC and the pushing host's
    # local zone must not shift a TTL.
    issued = calendar.timegm(time.strptime(issued_ts, "%Y-%m-%dT%H:%M:%SZ"))
    age = now_s - issued
except Exception as exc:
    block(f"unreadable issue timestamp: {exc}")

if age > ttl_s:
    block(f"token expired · age {age}s exceeds ttl {ttl_s}s")

fields = {
    "run_id": token.get("run_id", ""),
    "changeset_root_hash": token.get("changeset_root_hash", ""),
    "git_head": token_head,
    "issued_ts": issued_ts,
    "ttl_s": ttl_s,
    "decision": "GO",
}
expected_seal = hashlib.sha256(
    json.dumps(fields, sort_keys=True).encode("utf-8")).hexdigest()
if token.get("seal", "") != expected_seal:
    block("seal mismatch — the token's fields were edited after it was issued")

print(f"[L2] GO token valid · run={fields['run_id']} head={head[:12]} age={age}s",
      file=sys.stderr)
PYEOF
