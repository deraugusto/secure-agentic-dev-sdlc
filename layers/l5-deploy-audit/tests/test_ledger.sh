#!/usr/bin/env bash
# L5 · negative probes for the audit ledger and the deploy sequence.
#
# The ledger's value is entirely in what it refuses to accept after the fact. A
# log anyone can edit is a log; a chain that breaks visibly is evidence. These
# cases run against ledgers in a temp directory -- your real one is never
# written to.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$LAYER/../.." && pwd)"
LEDGER="$LAYER/ledger.py"
DEPLOY="$LAYER/deploy.sh"

PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
  if [ "$1" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  printf '%-5s %-34s %s\n' "$1" "$2" "$3"
}

# build_ledger <path> — three entries, appended through the real code path.
build_ledger() {
  _path="$1"
  mkdir -p "$(dirname "$_path")"
  : > "$_path"
  for _phase in verify deploy smoke; do
    python3 "$LEDGER" --ledger "$_path" append --kind deploy \
      --data "{\"phase\":\"$_phase\",\"outcome\":\"ok\",\"target\":\"probe\"}" \
      >/dev/null
  done
}

verify_ledger() { python3 "$LEDGER" --ledger "$1" verify >/dev/null 2>&1; }

printf '\n── the chain ──\n\n'

L="$WORK/clean/ledger.jsonl"
build_ledger "$L"
if verify_ledger "$L"; then
  report PASS intact-chain-verifies "baseline case"
else
  report FAIL intact-chain-verifies "a freshly written ledger did not verify"
fi

# The failure this whole construction exists to catch: a recorded failure
# rewritten into a success after the fact.
L="$WORK/edited/ledger.jsonl"
build_ledger "$L"
python3 - "$L" <<'PY'
import json, sys
path = sys.argv[1]
rows = [json.loads(line) for line in open(path) if line.strip()]
rows[2]["data"]["outcome"] = "failed-but-rewritten-as-ok"
with open(path, "w") as fh:
    fh.write("\n".join(json.dumps(r, sort_keys=True) for r in rows) + "\n")
PY
_out="$(python3 "$LEDGER" --ledger "$L" verify 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -q "entry_hash mismatch"; then
  report PASS edited-entry-detected "named the line"
else
  report FAIL edited-entry-detected "an edited entry verified"
fi

# Removing an entry breaks the chain at the join, not at the deletion.
L="$WORK/removed/ledger.jsonl"
build_ledger "$L"
sed -i.bak '2d' "$L" && rm -f "$L.bak"
_out="$(python3 "$LEDGER" --ledger "$L" verify 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$_out" | grep -qi "chain break"; then
  report PASS removed-entry-detected "chain break reported"
else
  report FAIL removed-entry-detected "a removed entry went unnoticed"
fi

# Re-hashing the edited entry is the sophisticated version of the same attack.
# It is caught one link later: the following entry still carries the old hash.
L="$WORK/rehashed/ledger.jsonl"
build_ledger "$L"
python3 - "$L" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
rows = [json.loads(line) for line in open(path) if line.strip()]
rows[1]["data"]["outcome"] = "quietly-changed"
without = {k: v for k, v in rows[1].items() if k != "entry_hash"}
rows[1]["entry_hash"] = "sha256:" + hashlib.sha256(
    json.dumps(without, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
with open(path, "w") as fh:
    fh.write("\n".join(json.dumps(r, sort_keys=True) for r in rows) + "\n")
PY
if ! verify_ledger "$L"; then
  report PASS rehashed-entry-detected "the next entry still names the old hash"
else
  report FAIL rehashed-entry-detected "re-hashing an edited entry defeated verify"
fi

# Truncating from the end leaves a shorter but internally consistent chain.
# That is a real limit of a hash chain and the probe records it as such rather
# than pretending otherwise.
L="$WORK/truncated/ledger.jsonl"
build_ledger "$L"
python3 - "$L" <<'PY'
import sys
path = sys.argv[1]
lines = [l for l in open(path) if l.strip()]
open(path, "w").write("".join(lines[:-1]))
PY
if verify_ledger "$L"; then
  report PASS truncation-is-a-known-limit "tail truncation still verifies — see docs/layers.md, L5"
else
  report FAIL truncation-is-a-known-limit "behaviour changed; the documented limit is now wrong"
fi

printf '\n── the deploy sequence ──\n\n'

# A dry run must not start a service, take a snapshot or write to the ledger.
D="$WORK/dryrun"
mkdir -p "$D"
_before="$(find "$D" -type f | wc -l)"
SDLC_STATE_DIR="$D/.sdlc" SDLC_LEDGER="$D/.sdlc/ledger/ledger.jsonl" \
  "$DEPLOY" --target hello-world --dry-run >/dev/null 2>&1
_after="$(find "$D" -type f | wc -l)"
if [ "$_before" -eq "$_after" ]; then
  report PASS deploy-dry-run-writes-nothing "no files created"
else
  report FAIL deploy-dry-run-writes-nothing "the dry run wrote $((_after - _before)) file(s)"
fi

# The target check needs an inventory to check against, and inventory.yaml is
# git-ignored -- so this case has to bring its own. Relying on whichever file
# happens to sit in the working tree is how a suite passes here and fails in a
# fresh clone, which is exactly what it did before this was written.
INV="$WORK/inventory.yaml"
cat > "$INV" <<'TXT'
roles:
  dev:
    addr: localhost
    author_model: alpha-coder-7b
  git:
    addr: git.example.internal
    type: gitea
    user: git
    repo_path: /srv/git/x.git
    ssh_port: 22
  reviewer:
    addr: 127.0.0.1
    port: 8080
    provider: offline
    model: beta-instruct-8b
    api_key_env: SDLC_REVIEWER_API_KEY
  targets:
    - name: hello-world
      addr: app.example.internal
      user: deploy
      path: /srv/hello-world
  provisioner: none
  sink:
    addr: localhost
    path: ./.sdlc/audit
layers:
  l0: true
  l1: true
  l2: true
  l3: true
  l4: false
  l5: true
profile: existing-infra
TXT

if ! SDLC_INVENTORY="$INV" "$DEPLOY" --target does-not-exist --dry-run >/dev/null 2>&1; then
  report PASS unknown-target-refused "refused a target the inventory does not declare"
else
  report FAIL unknown-target-refused "accepted a target it knows nothing about"
fi

if SDLC_INVENTORY="$INV" "$DEPLOY" --target hello-world --dry-run >/dev/null 2>&1; then
  report PASS declared-target-accepted "the declared one still works"
else
  report FAIL declared-target-accepted "refused a target the inventory declares"
fi

# Without an inventory the check cannot run. That is a warning and not a stop,
# so that L5 stays usable before the bootstrap has been run -- but it must say
# so rather than implying the target was verified.
_out="$(SDLC_INVENTORY="$WORK/does-not-exist.yaml" \
        "$DEPLOY" --target anything --dry-run 2>&1)"
if printf '%s' "$_out" | grep -qi "no inventory.yaml"; then
  report PASS missing-inventory-is-declared "says the target could not be checked"
else
  report FAIL missing-inventory-is-declared "silently skipped the target check"
fi

printf '\n%s/%s PASS\n\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
