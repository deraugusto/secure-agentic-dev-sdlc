#!/usr/bin/env bash
# Smoke test for the hello-world service.
#
# Two modes:
#   ./smoke.sh                     start the service here, probe it, stop it
#   ./smoke.sh --url <health-url>  probe a service someone else started
#
# The contract is narrow on purpose: HTTP 200 on /healthz with a JSON body
# whose `status` is `ok`. The deploy sequence calls this, and a failure here is
# what triggers a rollback -- so "smoke passed" has to mean something specific.
#
# Exit 0 healthy, 1 unhealthy.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
URL=""
TIMEOUT_S="${SDLC_SMOKE_TIMEOUT:-15}"
SERVER_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -z "$URL" ]]; then
  command -v node >/dev/null 2>&1 || {
    echo "[smoke] node is not installed — cannot start the service" >&2
    exit 1
  }
  HOST="$HOST" PORT="$PORT" node "$HERE/server.js" >/dev/null 2>&1 &
  SERVER_PID=$!
  URL="http://$HOST:$PORT/healthz"
fi

# Wait for the port rather than sleeping a fixed amount: a fixed sleep is
# either slow or flaky, and usually manages both.
deadline=$(( $(date +%s) + TIMEOUT_S ))
body=""
code=""
while (( $(date +%s) < deadline )); do
  if response="$(curl -fsS -m 3 -w '\n%{http_code}' "$URL" 2>/dev/null)"; then
    code="$(printf '%s' "$response" | tail -1)"
    body="$(printf '%s' "$response" | sed '$d')"
    [[ "$code" == "200" ]] && break
  fi
  if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[smoke] FAIL the service exited before answering" >&2
    exit 1
  fi
  sleep 0.3
done

if [[ "$code" != "200" ]]; then
  echo "[smoke] FAIL no HTTP 200 from $URL within ${TIMEOUT_S}s (last code: ${code:-none})" >&2
  exit 1
fi

if ! printf '%s' "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  echo "[smoke] FAIL /healthz answered 200 but not with status ok" >&2
  printf '[smoke] body: %s\n' "$body" >&2
  exit 1
fi

version="$(printf '%s' "$body" | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
echo "[smoke] PASS $URL → 200 status=ok version=${version:-unknown}"
exit 0
