#!/usr/bin/env bash
# L5 · verified deploy.
#
#   verify -> snapshot -> deploy -> smoke -> (rollback)
#
# Five phases, in that order, and the order is the design. Verification happens
# before anything is touched. The snapshot happens before the deploy, not after
# the failure -- a rollback plan made after the fact is a hope. Smoke decides,
# and its failure path is a real code path that runs on every failed deploy, not
# a paragraph in a runbook.
#
#   ./deploy.sh --target hello-world --local
#   ./deploy.sh --target hello-world --dry-run
#   ./deploy.sh --target hello-world --rollback     restore the last snapshot
#
# Wave 1 ships the local path complete and the remote path as a printed plan:
# a remote deploy needs a target host, and a script that pretends to have one
# would be the wrong kind of skeleton.
#
# Every phase appends to the hash-chained ledger. Exit 0 only if the service is
# live and answering; a rollback exits non-zero even when the rollback itself
# succeeds, because the deploy did not.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
STATE_DIR="${SDLC_STATE_DIR:-$REPO_ROOT/.sdlc}"
DEPLOY_ROOT="$STATE_DIR/deploy"
SNAPSHOT_ROOT="$STATE_DIR/snapshots"
LEDGER="$REPO_ROOT/layers/l5-deploy-audit/ledger.py"
INVENTORY="$REPO_ROOT/lib/inventory.py"

TARGET=""
MODE=""
DRY_RUN=0
DO_ROLLBACK=0
REQUIRE_SIGNATURE=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)             TARGET="${2:-}"; shift 2 ;;
    --local)              MODE=local; shift ;;
    --remote)             MODE=remote; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --rollback)           DO_ROLLBACK=1; shift ;;
    --require-signature)  REQUIRE_SIGNATURE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "usage: deploy.sh --target <name> [--local|--remote|--dry-run|--rollback]" >&2; exit 2; }
[[ -n "$MODE" || $DRY_RUN -eq 1 || $DO_ROLLBACK -eq 1 ]] || MODE=local

# The target has to be one this repository knows about. Deploying a name that
# appears in no inventory produces a ledger entry describing a target nobody
# declared, which is worse than no entry: the audit trail gains a fiction.
#
# With no inventory.yaml at all, L5 has not been bootstrapped and there is
# nothing to check against; that is a warning, not a stop, so the layer stays
# usable on its own.
# SDLC_INVENTORY wins over the default location, the same way lib/inventory.py
# resolves it. Without this the script would read a different inventory than
# every other layer whenever that variable is set.
INVENTORY_FILE="${SDLC_INVENTORY:-$REPO_ROOT/inventory.yaml}"

if [[ -f "$INVENTORY_FILE" ]]; then
  if ! python3 - "$TARGET" "$REPO_ROOT" "$INVENTORY_FILE" <<'PYEOF'
import sys
from pathlib import Path

wanted, repo_root, inventory_file = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, str(Path(repo_root) / "lib"))
import inventory  # noqa: E402

targets = inventory.get("targets", inventory.load(inventory_file)) or []
names = [t.get("name") for t in targets if isinstance(t, dict) and t.get("name")]
if wanted in names:
    raise SystemExit(0)
print(f"[L5] target {wanted!r} is not declared in inventory.yaml", file=sys.stderr)
print(f"[L5] declared targets: {', '.join(names) if names else '(none)'}",
      file=sys.stderr)
print("[L5] add it under roles.targets, or re-run ./bootstrap/init.sh",
      file=sys.stderr)
raise SystemExit(1)
PYEOF
  then
    exit 2
  fi
else
  echo "[L5] no inventory.yaml — target '$TARGET' cannot be checked against a" >&2
  echo "[L5] declaration. Run ./bootstrap/init.sh to make this verifiable." >&2
fi

SOURCE_DIR="$REPO_ROOT/example/hello-world-node"
DEPLOY_DIR="$DEPLOY_ROOT/$TARGET"
PID_FILE="$STATE_DIR/run/$TARGET.pid"
LOG_FILE="$STATE_DIR/run/$TARGET.log"
PORT="${PORT:-3000}"
HOST="${HOST:-127.0.0.1}"
HEALTH_URL="http://$HOST:$PORT/healthz"

say()  { printf '[L5] %s\n' "$*"; }
fail() { printf '[L5] %s\n' "$*" >&2; }

ledger() {
  # phase, outcome, detail
  local phase="$1" outcome="$2" detail="${3:-}"
  (( DRY_RUN )) && return 0
  python3 "$LEDGER" append --kind deploy --data "$(printf '{"run_id":"%s","target":"%s","phase":"%s","outcome":"%s","detail":"%s"}' \
    "$RUN_ID" "$TARGET" "$phase" "$outcome" "${detail//\"/}")" >/dev/null || true
}

stop_service() {
  if [[ -f "$PID_FILE" ]]; then
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

port_in_use() {
  # /dev/tcp rather than ss or lsof: neither is guaranteed present, and a
  # missing tool must not silently turn this check into a pass.
  (exec 3<>"/dev/tcp/$HOST/$PORT") 2>/dev/null && exec 3<&- && return 0
  return 1
}

start_service() {
  mkdir -p "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")"
  # `( ... ) &` then `exec` inside: the subshell's pid becomes node's pid.
  # Backgrounding a `cd && nohup ...` list instead records the subshell and
  # leaves the real process unkillable by the pid file -- which produces a
  # stopped "old" service that is still holding the port, and a smoke test
  # that passes against the wrong process. That is a false green, and a false
  # green in a deploy gate is the failure this whole repository is about.
  (
    cd "$DEPLOY_DIR" || exit 1
    HOST="$HOST" PORT="$PORT" exec nohup node server.js >> "$LOG_FILE" 2>&1
  ) &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "start: the service exited immediately (pid $pid) — see $LOG_FILE"
    tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/[L5]        /' >&2
    return 1
  fi
  return 0
}

smoke() {
  if [[ "${SDLC_BREAK_SMOKE:-}" == "1" ]]; then
    # The negative probe. A rollback path that is never exercised is not a
    # rollback path, so there is a supported way to exercise it.
    fail "smoke: forced failure via SDLC_BREAK_SMOKE"
    return 1
  fi
  SDLC_SMOKE_TIMEOUT="${SDLC_SMOKE_TIMEOUT:-15}" \
    "$SOURCE_DIR/smoke.sh" --url "$HEALTH_URL"
}

latest_snapshot() {
  ls -1d "$SNAPSHOT_ROOT/$TARGET"/* 2>/dev/null | sort | tail -1
}

# ── Rollback-only invocation ───────────────────────────────────────────────
if (( DO_ROLLBACK )); then
  snapshot="$(latest_snapshot)"
  if [[ -z "$snapshot" ]]; then
    fail "no snapshot to roll back to under $SNAPSHOT_ROOT/$TARGET"
    ledger rollback failed "no-snapshot"
    exit 1
  fi
  say "rolling back to $(basename "$snapshot")"
  stop_service
  rm -rf "$DEPLOY_DIR"
  mkdir -p "$(dirname "$DEPLOY_DIR")"
  cp -a "$snapshot" "$DEPLOY_DIR"
  start_service
  if smoke; then
    say "rollback complete and healthy"
    ledger rollback ok "$(basename "$snapshot")"
    exit 0
  fi
  fail "rollback restored the snapshot but the service is not healthy"
  ledger rollback degraded "$(basename "$snapshot")"
  exit 1
fi

# ── Remote plan ────────────────────────────────────────────────────────────
if [[ "$MODE" == "remote" ]]; then
  addr="$(python3 "$INVENTORY" --get targets 2>/dev/null | sed -n 's/^ *addr: *//p' | head -1)"
  cat <<EOF
[L5] remote deploy · plan only in this wave

  target      $TARGET
  address     ${addr:-<not set in inventory.yaml>}
  sequence    verify -> snapshot -> rsync -> restart -> smoke -> rollback

  The five phases are identical to the local path; only the transport differs.
  What is deliberately not shipped is a script that ssh-es into a host it has
  never seen, using a service manager it cannot know, and calls the result a
  deploy. Wire the transport to your own conventions:

    1. copy $SOURCE_DIR to <target>:<path> (rsync, scp, a signed tarball)
    2. snapshot <path> on the target first, into a sibling directory
    3. restart via whatever supervises the service there
    4. run smoke.sh --url <target health url> FROM THE DEV HOST, not on
       the target -- a smoke test that only passes from localhost has not
       tested the path a user takes
    5. on failure restore the snapshot and restart, then smoke again

  The local path (--local) exercises all five and is what the acceptance run
  uses.
EOF
  ledger remote-plan printed "$TARGET"
  exit 0
fi

# ── Phase 1 · verify ───────────────────────────────────────────────────────
say "run $RUN_ID · target $TARGET · $( ((DRY_RUN)) && echo 'DRY RUN' || echo 'local' )"

if [[ ! -d "$SOURCE_DIR" ]]; then
  fail "verify: source directory missing: $SOURCE_DIR"
  ledger verify failed "source-missing"
  exit 1
fi

artifact_hash="$( cd "$SOURCE_DIR" && find . -type f ! -name '*.log' -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}' )"
say "verify: artifact sha256 ${artifact_hash:0:16}…"

signature_state="unverified"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" verify-commit HEAD >/dev/null 2>&1; then
    signature_state="verified"
    say "verify: HEAD commit signature verified"
  else
    signature_state="unsigned-or-unverifiable"
    if (( REQUIRE_SIGNATURE )); then
      fail "verify: HEAD is not a verifiable signed commit and --require-signature is set"
      ledger verify failed "unsigned"
      exit 1
    fi
    say "verify: HEAD signature $signature_state — proceeding, recorded as such"
    say "        (pass --require-signature to make this a stop)"
  fi
else
  signature_state="not-a-git-repo"
  say "verify: not a git repository — signature state recorded as $signature_state"
fi
ledger verify ok "artifact=${artifact_hash:0:16} signature=$signature_state"

command -v node >/dev/null 2>&1 || {
  fail "verify: node is not installed on this host"
  ledger verify failed "no-node"
  exit 1
}

# ── Phase 2 · snapshot ─────────────────────────────────────────────────────
snapshot_dir="$SNAPSHOT_ROOT/$TARGET/$RUN_ID"
if (( DRY_RUN )); then
  say "snapshot: would copy $DEPLOY_DIR → $snapshot_dir"
elif [[ -d "$DEPLOY_DIR" ]]; then
  mkdir -p "$(dirname "$snapshot_dir")"
  cp -a "$DEPLOY_DIR" "$snapshot_dir"
  say "snapshot: $DEPLOY_DIR → $(basename "$snapshot_dir")"
  ledger snapshot ok "$(basename "$snapshot_dir")"
else
  say "snapshot: nothing deployed yet — first deploy, no snapshot to take"
  ledger snapshot skipped "first-deploy"
  snapshot_dir=""
fi

# ── Phase 3 · deploy ───────────────────────────────────────────────────────
if (( DRY_RUN )); then
  say "deploy: would stop the service, copy $SOURCE_DIR → $DEPLOY_DIR, start it"
  say "smoke:  would probe $HEALTH_URL"
  say "DRY RUN complete — nothing was touched"
  exit 0
fi

stop_service

if port_in_use; then
  fail "deploy: $HOST:$PORT is still bound after stopping the managed process."
  fail "        Something this script does not own is holding the port. Deploying"
  fail "        now would leave a smoke test passing against the wrong process."
  ledger deploy failed "port-held-by-unmanaged-process"
  exit 1
fi

rm -rf "$DEPLOY_DIR"
mkdir -p "$(dirname "$DEPLOY_DIR")"
cp -a "$SOURCE_DIR" "$DEPLOY_DIR"
if ! start_service; then
  ledger deploy failed "start-failed"
  exit 1
fi
say "deploy: started from $DEPLOY_DIR (pid $(cat "$PID_FILE" 2>/dev/null || echo '?'))"
ledger deploy ok "pid=$(cat "$PID_FILE" 2>/dev/null || echo unknown)"

# ── Phase 4 · smoke ────────────────────────────────────────────────────────
if smoke; then
  say "smoke: healthy"
  ledger smoke ok "$HEALTH_URL"
  say "DEPLOY OK · $TARGET live at $HEALTH_URL"
  ledger deploy-complete ok "artifact=${artifact_hash:0:16}"
  exit 0
fi

# ── Phase 5 · rollback ─────────────────────────────────────────────────────
fail "smoke: FAILED — rolling back"
ledger smoke failed "$HEALTH_URL"

stop_service

if [[ -z "$snapshot_dir" || ! -d "$snapshot_dir" ]]; then
  rm -rf "$DEPLOY_DIR"
  fail "rollback: no previous version existed — the target is now stopped and empty"
  fail "          this is the correct outcome for a failed first deploy: a broken"
  fail "          service is worse than an absent one."
  ledger rollback ok "removed-failed-first-deploy"
  exit 1
fi

rm -rf "$DEPLOY_DIR"
cp -a "$snapshot_dir" "$DEPLOY_DIR"
start_service

if SDLC_BREAK_SMOKE= smoke; then
  fail "rollback: restored $(basename "$snapshot_dir") and the previous version is healthy"
  ledger rollback ok "$(basename "$snapshot_dir")"
  exit 1
fi

fail "rollback: restored $(basename "$snapshot_dir") but it is NOT healthy — manual intervention"
ledger rollback degraded "$(basename "$snapshot_dir")"
exit 1
