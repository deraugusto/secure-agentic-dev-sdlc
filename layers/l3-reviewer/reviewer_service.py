#!/usr/bin/env python3
"""L3 · the reviewer service.

Two routes, and an order inside `/review` that is part of the contract: the
cheap integrity checks run before any backend call, so a tampered apparatus can
never produce a verdict.

    GET  /health   liveness, model identity, apparatus state
    POST /review   a verdict

The reviewer has no repository access, no filesystem writes outside its own
audit log, and no tools beyond model inference. If the model is compromised the
blast radius is wrong annotations — not modified code. That containment is why
the reviewer is allowed to be a model at all.

The service has no `block` verdict in its vocabulary. It cannot block by
construction, not by configuration. What makes the gate fail closed is the
*caller's* default when the reviewer says nothing useful — see l2-output-gate.

    python3 reviewer_service.py --serve
    python3 reviewer_service.py --seal          # write checksums.txt
    python3 reviewer_service.py --self-test
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = Path(os.environ.get("SDLC_REPO_ROOT", str(HERE.parent.parent)))
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO_ROOT / "lib"))

import backends  # noqa: E402

APPARATUS_FILES = [
    "reviewer_service.py",
    "backends.py",
    "system-prompt.md",
    "bundle-schema.json",
]

CHECKSUMS_FILE = HERE / "checksums.txt"
AUDIT_LOG = Path(os.environ.get(
    "SDLC_REVIEWER_AUDIT", str(REPO_ROOT / ".sdlc" / "audit" / "reviewer.jsonl")))

SOFT_TIMEOUT = float(os.environ.get("SDLC_REVIEWER_SOFT_TIMEOUT", "30"))
HARD_TIMEOUT = float(os.environ.get("SDLC_REVIEWER_HARD_TIMEOUT", "90"))

SEVERITIES = set(backends.SEVERITIES)


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── Configuration ──────────────────────────────────────────────────────────

def reviewer_config() -> dict:
    """Environment wins over inventory; inventory wins over nothing.

    The service often runs on a host that has no checkout of this repository,
    so it must be configurable without one.
    """
    config = {
        "provider": os.environ.get("SDLC_REVIEWER_PROVIDER", ""),
        "model": os.environ.get("SDLC_REVIEWER_MODEL", ""),
        "base_url": os.environ.get("SDLC_REVIEWER_BASE_URL", ""),
        "api_key_env": os.environ.get("SDLC_REVIEWER_API_KEY_ENV", ""),
        "listen_host": os.environ.get("SDLC_REVIEWER_LISTEN", "127.0.0.1"),
        "listen_port": int(os.environ.get("SDLC_REVIEWER_PORT", "8080")),
        "source": "environment",
    }
    if config["provider"] and (config["base_url"] or config["provider"] == "offline"):
        return config

    try:
        import inventory  # noqa: E402

        data = inventory.load()
        reviewer = inventory.get("reviewer", data) or {}
        config["provider"] = config["provider"] or reviewer.get("provider", "offline")
        config["model"] = config["model"] or str(reviewer.get("model", "offline-canned"))
        config["api_key_env"] = config["api_key_env"] or str(
            reviewer.get("api_key_env", "") or "")
        if not config["base_url"] and reviewer.get("addr"):
            config["base_url"] = (
                f"http://{reviewer['addr']}:{reviewer.get('backend_port', 11434)}"
            )
        config["listen_port"] = int(reviewer.get("port", config["listen_port"]))
        config["source"] = "inventory"
    except Exception:
        config["provider"] = config["provider"] or "offline"
        config["model"] = config["model"] or "offline-canned"
        config["source"] = "default"
    return config


def get_backend() -> backends.Backend:
    config = reviewer_config()
    return backends.build(config["provider"], config["base_url"],
                          config["model"], config["api_key_env"])


# ── Apparatus integrity ────────────────────────────────────────────────────

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def seal() -> Path:
    lines = []
    for name in APPARATUS_FILES:
        path = HERE / name
        if not path.is_file():
            raise SystemExit(f"apparatus file missing: {path}")
        lines.append(f"{sha256_file(path)}  {name}")
    CHECKSUMS_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return CHECKSUMS_FILE


def verify_apparatus() -> tuple[bool, str]:
    """Fail-closed. A missing checksums file is a mismatch, never a skip.

    Verified on every /review call rather than only at startup: tampering that
    happens while the service runs must be caught by the next call, not by the
    next restart.
    """
    if not CHECKSUMS_FILE.is_file():
        return False, "checksums-file-missing"

    expected: dict[str, str] = {}
    for line in CHECKSUMS_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            return False, "checksums-file-malformed"
        expected[parts[1].strip()] = parts[0].strip()

    for name in APPARATUS_FILES:
        if name not in expected:
            return False, f"unlisted-apparatus-file:{name}"
        path = HERE / name
        if not path.is_file():
            return False, f"apparatus-file-missing:{name}"
        if sha256_file(path) != expected[name]:
            return False, f"apparatus-hash-mismatch:{name}"
    return True, "ok"


# ── Bundle schema gate ─────────────────────────────────────────────────────

def load_schema() -> dict:
    return json.loads((HERE / "bundle-schema.json").read_text(encoding="utf-8"))


def validate_bundle(bundle, schema: dict) -> tuple[bool, str]:
    if not isinstance(bundle, dict):
        return False, "json-parse-error"
    for key in schema["required_top_level"]:
        if key not in bundle:
            return False, "missing-required-field"
    if bundle.get("bundle_version") not in schema["accepted_versions"]:
        return False, "schema-version-mismatch"

    changeset = bundle.get("changeset")
    if not isinstance(changeset, dict):
        return False, "missing-required-field"
    for key in schema["required_changeset"]:
        if key not in changeset:
            return False, "missing-required-field"

    files = changeset.get("files")
    if not isinstance(files, list) or not files:
        return False, "missing-required-field"
    for entry in files:
        if not isinstance(entry, dict):
            return False, "missing-required-field"
        for key in schema["required_file_entry"]:
            if key not in entry:
                return False, "missing-required-field"

    context = bundle.get("context")
    if not isinstance(context, dict):
        return False, "missing-required-field"
    for key in schema["required_context"]:
        if key not in context:
            return False, "missing-required-field"
    return True, "ok"


# ── Prompt ─────────────────────────────────────────────────────────────────

def build_prompt(bundle: dict) -> str:
    mandate = (HERE / "system-prompt.md").read_text(encoding="utf-8")
    intent = bundle.get("context", {}).get("intent_summary", "(none supplied)")
    parts = [mandate, "", "---", "", "# Changeset under review", "",
             f"Intent as stated by the author: {intent}", ""]
    for entry in bundle["changeset"]["files"]:
        content = entry.get("content", "")
        lines = content.splitlines()
        # Numbered, because the output contract demands a line range inside the
        # file and then rejects the whole review when one is wrong. Presenting
        # the content unnumbered asks the model to count, which it does badly
        # and which nothing in the answer reveals -- the review comes back
        # substantively correct and gets discarded over an off-by-two.
        width = len(str(len(lines))) if lines else 1
        numbered = "\n".join(f"{i:>{width}} | {line}"
                             for i, line in enumerate(lines, start=1))
        parts += [f"## {entry['path']}",
                  f"({len(lines)} lines; the numbers left of the pipe are line "
                  f"numbers and are not part of the file)", "",
                  "```", numbered, "```", ""]
    return "\n".join(parts)


# ── Output validation ──────────────────────────────────────────────────────

def validate_strict(raw: str, bundle: dict) -> tuple[list | None, str]:
    """The model is never trusted, only checked.

    A hallucinating model has to degrade into `model-error`, which the gate
    already refuses on. The one outcome that must be unreachable is a
    malformed answer becoming a pass.
    """
    text = (raw or "").strip()
    if text.startswith("```"):
        # Tolerate a fenced answer; do not tolerate prose around it.
        text = text.split("\n", 1)[-1]
        if text.rstrip().endswith("```"):
            text = text.rstrip()[:-3]
    try:
        parsed = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return None, "output-not-json"

    annotations = parsed.get("annotations") if isinstance(parsed, dict) else None
    if not isinstance(annotations, list):
        return None, "output-missing-annotations"
    if len(annotations) != len(backends.DISCIPLINE_SLUGS):
        return None, "output-wrong-annotation-count"

    known_paths = {f["path"] for f in bundle["changeset"]["files"]}
    line_counts = {f["path"]: f.get("content", "").count("\n") + 1
                   for f in bundle["changeset"]["files"]}
    seen: set[str] = set()

    for entry in annotations:
        if not isinstance(entry, dict):
            return None, "output-entry-not-object"
        slug = entry.get("discipline")
        if slug not in backends.DISCIPLINE_SLUGS:
            return None, "output-unknown-discipline"
        if slug in seen:
            return None, "output-duplicate-discipline"
        seen.add(slug)

        severity = entry.get("severity")
        if severity not in SEVERITIES:
            return None, "output-unknown-severity"
        if severity == "clear":
            continue

        path = entry.get("file")
        if path not in known_paths:
            return None, "output-file-not-in-changeset"
        line_range = entry.get("line_range")
        if (not isinstance(line_range, list) or len(line_range) != 2
                or not all(isinstance(n, int) for n in line_range)
                or line_range[0] < 1 or line_range[1] < line_range[0]
                or line_range[1] > line_counts[path]):
            return None, "output-bad-line-range"

    return annotations, "ok"


# ── Review ─────────────────────────────────────────────────────────────────

def audit(record: dict) -> None:
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        with AUDIT_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def do_review(raw_body: bytes) -> dict:
    started = utcnow()

    # 1 · Apparatus integrity. Cheap, and before anything can be produced.
    ok, reason = verify_apparatus()
    if not ok:
        result = {"verdict": "tampering", "reason": reason, "annotations": []}
        audit({"ts": started, "verdict": "tampering", "reason": reason})
        return result

    # 2 · Schema gate. Still no backend involved.
    try:
        bundle = json.loads(raw_body.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        audit({"ts": started, "verdict": "bundle-malformed",
               "reason": "json-parse-error"})
        return {"verdict": "bundle-malformed", "reason": "json-parse-error",
                "annotations": []}

    ok, reason = validate_bundle(bundle, load_schema())
    if not ok:
        audit({"ts": started, "verdict": "bundle-malformed", "reason": reason,
               "run_id": bundle.get("run_id") if isinstance(bundle, dict) else None})
        return {"verdict": "bundle-malformed", "reason": reason, "annotations": []}

    run_id = bundle.get("run_id")

    # 3 · Backend availability.
    try:
        backend = get_backend()
    except backends.BackendError as exc:
        audit({"ts": started, "run_id": run_id, "verdict": "model-error",
               "reason": str(exc)})
        return {"verdict": "model-error", "reason": str(exc), "annotations": []}

    if not backend.ready():
        audit({"ts": started, "run_id": run_id, "verdict": "backend-unavailable",
               "model": backend.model})
        return {"verdict": "backend-unavailable", "reason": "backend-not-ready",
                "annotations": []}

    # 4 · The call, with one retry on a soft timeout.
    prompt = build_prompt(bundle)
    try:
        raw = backend.complete(prompt, timeout=SOFT_TIMEOUT)
    except TimeoutError:
        try:
            raw = backend.complete(prompt, timeout=HARD_TIMEOUT)
        except Exception as exc:
            audit({"ts": started, "run_id": run_id, "verdict": "backend-timeout",
                   "reason": type(exc).__name__})
            return {"verdict": "backend-timeout", "reason": "hard-timeout",
                    "annotations": []}
    except Exception as exc:
        audit({"ts": started, "run_id": run_id, "verdict": "model-error",
               "reason": type(exc).__name__})
        return {"verdict": "model-error", "reason": type(exc).__name__,
                "annotations": []}

    # 5 · Deterministic validation, one retry, then defer.
    annotations, reason = validate_strict(raw, bundle)
    if annotations is None:
        try:
            raw = backend.complete(prompt, timeout=SOFT_TIMEOUT)
        except Exception as exc:
            audit({"ts": started, "run_id": run_id, "verdict": "model-error",
                   "reason": type(exc).__name__})
            return {"verdict": "model-error", "reason": type(exc).__name__,
                    "annotations": []}
        annotations, reason = validate_strict(raw, bundle)
        if annotations is None:
            audit({"ts": started, "run_id": run_id, "verdict": "model-error",
                   "reason": reason})
            return {"verdict": "model-error", "reason": reason, "annotations": []}

    audit({"ts": started, "run_id": run_id, "verdict": "annotations-only",
           "model": backend.model,
           "severities": {a["discipline"]: a["severity"] for a in annotations}})
    return {"verdict": "annotations-only", "reason": "ok",
            "annotations": annotations, "model": backend.model}


# ── HTTP ───────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = "sdlc-reviewer/1.0"

    def log_message(self, fmt, *args):
        if os.environ.get("SDLC_VERBOSE") == "1":
            sys.stderr.write("[reviewer] " + fmt % args + "\n")

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            self._send(404, {"error": "not-found"})
            return
        ok, reason = verify_apparatus()
        try:
            backend = get_backend()
            model, provider = backend.model, backend.name
        except backends.BackendError as exc:
            model, provider = "unavailable", str(exc)
        self._send(200, {
            "status": "ok",
            "model_id": model,
            "provider": provider,
            "apparatus_verified": ok,
            "apparatus_reason": reason,
            "ts": utcnow(),
        })

    def do_POST(self):
        if self.path != "/review":
            self._send(404, {"error": "not-found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self._send(200, do_review(raw))


def serve(host: str, port: int) -> int:
    ok, reason = verify_apparatus()
    if not ok:
        # Startup verification is advisory. The per-call check is the real gate,
        # and the tampering path has to be reachable without a restart.
        sys.stderr.write(f"[reviewer] WARNING apparatus unverified: {reason}\n")
    server = ThreadingHTTPServer((host, port), Handler)
    config = reviewer_config()
    sys.stderr.write(
        f"[reviewer] listening on {host}:{port} · provider={config['provider']} "
        f"model={config['model']} config-from={config['source']}\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="L3 reviewer service")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--seal", action="store_true",
                        help="write checksums.txt over the apparatus files")
    parser.add_argument("--self-test", action="store_true",
                        help="verify apparatus and print backend readiness")
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", type=int, default=None)
    args = parser.parse_args()

    if args.seal:
        print(f"sealed {seal()}")
        return 0

    if args.self_test:
        ok, reason = verify_apparatus()
        config = reviewer_config()
        try:
            backend = get_backend()
            ready = backend.ready()
        except backends.BackendError as exc:
            print(f"backend unusable: {exc}", file=sys.stderr)
            return 1
        print(json.dumps({"apparatus_verified": ok, "apparatus_reason": reason,
                          "provider": config["provider"], "model": backend.model,
                          "backend_ready": ready}, indent=2))
        return 0 if ok else 1

    config = reviewer_config()
    return serve(args.host or config["listen_host"],
                 args.port or config["listen_port"])


if __name__ == "__main__":
    raise SystemExit(main())
