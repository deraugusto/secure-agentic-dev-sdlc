#!/usr/bin/env python3
"""A protocol-accurate stand-in for a model endpoint.

The reviewer's HTTP backends are the one part of L3 that cannot be exercised by
running the service with provider=offline: that path never opens a socket. This
server speaks both wire protocols the backends support and can be told to
misbehave in the specific ways a real endpoint misbehaves, which is the half
that matters -- a happy path against a real model proves the request is
well-formed, but says nothing about what happens when the model returns a 500
in the middle of a release.

    mock_model.py --port 8099 --mode valid

Modes:
    valid           a well-formed review, all seven disciplines clear
    findings        a well-formed review carrying a block-recommended finding
    prose           a model that wraps its JSON in prose and a code fence
    malformed       invalid JSON in the content field
    short           only three disciplines instead of seven
    bad-shape       HTTP 200, but not the response envelope the API defines
    http-500        server error
    slow            responds after --delay seconds, to trip the timeout
    unauthorized    HTTP 401, the shape a wrong API key produces

Both protocols are served at once; the backend under test picks its own path.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = "valid"
DELAY = 0.0
SEEN: list[dict] = []

SLUGS = [
    "output-sanitize-drift", "hardcoded-secret", "shell-injection",
    "auth-logic-change", "privilege-escalation", "network-egress",
    "trust-boundary-crossing",
]


def review_all_clear() -> str:
    return json.dumps({"annotations": [
        {"discipline": slug, "severity": "clear", "file": None,
         "line_range": None, "rationale": ""} for slug in SLUGS]})


def review_with_finding() -> str:
    annotations = [
        {"discipline": slug, "severity": "clear", "file": None,
         "line_range": None, "rationale": ""} for slug in SLUGS]
    annotations[1] = {
        "discipline": "hardcoded-secret",
        "severity": "block-recommended",
        "file": "example/hello-world-node/server.js",
        "line_range": [1, 2],
        "rationale": "A literal bound to a name suggesting a credential. "
                     "Reported without quoting the value.",
    }
    return json.dumps({"annotations": annotations})


def review_short() -> str:
    return json.dumps({"annotations": [
        {"discipline": slug, "severity": "clear", "file": None,
         "line_range": None, "rationale": ""} for slug in SLUGS[:3]]})


def content_for_mode() -> str:
    if MODE == "findings":
        return review_with_finding()
    if MODE == "prose":
        return ("Here is my assessment of the changeset:\n\n```json\n"
                + review_all_clear() + "\n```\n\nLet me know if you need more.")
    if MODE == "malformed":
        return '{"annotations": [ {"discipline": "hardcoded-secret",, ]'
    if MODE == "short":
        return review_short()
    return review_all_clear()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the probe output readable
        pass

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Readiness probes: /v1/models and /api/tags
        if MODE == "http-500":
            self._send(500, {"error": "internal"})
            return
        if MODE == "unauthorized":
            self._send(401, {"error": "invalid api key"})
            return
        if self.path.startswith("/v1/models"):
            self._send(200, {"object": "list", "data": [{"id": "mock-model"}]})
        elif self.path.startswith("/api/tags"):
            self._send(200, {"models": [{"name": "mock-model"}]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            request = json.loads(raw.decode("utf-8"))
        except Exception:
            request = {"unparseable": True}
        SEEN.append({
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "body": request,
        })

        if DELAY:
            time.sleep(DELAY)

        if MODE == "http-500":
            self._send(500, {"error": "internal"})
            return
        if MODE == "unauthorized":
            self._send(401, {"error": "invalid api key"})
            return
        if MODE == "bad-shape":
            self._send(200, {"result": "ok", "no": "envelope here"})
            return

        content = content_for_mode()
        if self.path.startswith("/v1/chat/completions"):
            self._send(200, {
                "id": "mock", "object": "chat.completion",
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": content}}],
            })
        elif self.path.startswith("/api/chat"):
            self._send(200, {
                "model": request.get("model", "mock-model"), "done": True,
                "message": {"role": "assistant", "content": content},
            })
        else:
            self._send(404, {"error": "not found"})


def main() -> int:
    global MODE, DELAY
    parser = argparse.ArgumentParser(description="protocol-accurate model stand-in")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--mode", default="valid")
    parser.add_argument("--delay", type=float, default=0.0)
    parser.add_argument("--dump-requests", default="")
    args = parser.parse_args()
    MODE, DELAY = args.mode, args.delay

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write(f"[mock] listening on 127.0.0.1:{args.port} mode={MODE}\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if args.dump_requests:
            with open(args.dump_requests, "w", encoding="utf-8") as fh:
                json.dump(SEEN, fh, indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
