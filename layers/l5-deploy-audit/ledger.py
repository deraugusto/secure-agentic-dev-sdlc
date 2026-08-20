#!/usr/bin/env python3
"""L5 · append-only, hash-chained build ledger.

Every entry carries the hash of the entry before it. Removing or editing a line
breaks the chain from that point forward, so the ledger cannot be quietly
rewritten — only obviously rewritten, which is the achievable property. It is a
tamper-*evident* record, not a tamper-proof one, and the difference matters:
whoever owns the file can still destroy it.

That is why the role model has a `sink` role at all, and why putting the sink on
the host it audits is flagged as a weakening rather than accepted silently.

    python3 ledger.py append --kind deploy --data '{"target":"hello-world"}'
    python3 ledger.py verify
    python3 ledger.py tail 5

Single writer assumed; an exclusive lock makes concurrent appends safe anyway.
Standard library only.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(os.environ.get(
    "SDLC_REPO_ROOT", str(Path(__file__).resolve().parent.parent.parent)))
LEDGER_PATH = Path(os.environ.get(
    "SDLC_LEDGER", str(REPO_ROOT / ".sdlc" / "ledger" / "ledger.jsonl")))

GENESIS = "sha256:" + "0" * 64
SCHEMA_VERSION = 1


class LedgerCorrupted(RuntimeError):
    pass


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical(entry: dict) -> str:
    return json.dumps(entry, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


def entry_hash(entry: dict) -> str:
    without = {k: v for k, v in entry.items() if k != "entry_hash"}
    return "sha256:" + hashlib.sha256(
        canonical(without).encode("utf-8")).hexdigest()


def _tail_hash(path: Path) -> str:
    if not path.exists() or path.stat().st_size == 0:
        return GENESIS
    last = None
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            if not raw.endswith("\n"):
                raise LedgerCorrupted(
                    f"partial write: trailing line of {path} lacks a newline")
            if raw.strip():
                last = raw.rstrip("\n")
    if last is None:
        return GENESIS
    try:
        entry = json.loads(last)
    except json.JSONDecodeError as exc:
        raise LedgerCorrupted(f"last line is not valid JSON: {exc}") from exc
    if "entry_hash" not in entry:
        raise LedgerCorrupted("last line carries no entry_hash")
    return entry["entry_hash"]


def append(kind: str, data: dict, path: Path = LEDGER_PATH) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            entry = {
                "ts": utcnow(),
                "schema_version": SCHEMA_VERSION,
                "kind": kind,
                "data": data,
                "prev_hash": _tail_hash(path),
            }
            entry["entry_hash"] = entry_hash(entry)
            os.write(fd, (canonical(entry) + "\n").encode("utf-8"))
            os.fsync(fd)
            return entry
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def verify(path: Path = LEDGER_PATH) -> tuple[bool, list[str], int]:
    problems: list[str] = []
    if not path.exists():
        return False, [f"no ledger at {path}"], 0
    expected_prev = GENESIS
    count = 0
    with path.open("r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            if not raw.strip():
                continue
            if not raw.endswith("\n"):
                problems.append(f"line {lineno}: partial write, no newline")
                break
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError as exc:
                problems.append(f"line {lineno}: invalid JSON ({exc})")
                break
            count += 1
            if entry.get("prev_hash") != expected_prev:
                problems.append(
                    f"line {lineno}: chain break — prev_hash "
                    f"{str(entry.get('prev_hash'))[:20]}… expected "
                    f"{expected_prev[:20]}…")
                break
            recomputed = entry_hash(entry)
            if recomputed != entry.get("entry_hash"):
                problems.append(
                    f"line {lineno}: entry_hash mismatch — content was edited")
                break
            expected_prev = entry["entry_hash"]
    return (not problems), problems, count


def tail(count: int, path: Path = LEDGER_PATH) -> list[dict]:
    if not path.exists():
        return []
    lines = [line for line in path.read_text(encoding="utf-8").splitlines()
             if line.strip()]
    out = []
    for line in lines[-count:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            out.append({"_unparseable": line[:120]})
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="L5 build ledger")
    sub = parser.add_subparsers(dest="command", required=True)

    append_cmd = sub.add_parser("append")
    append_cmd.add_argument("--kind", required=True)
    append_cmd.add_argument("--data", default="{}")

    sub.add_parser("verify")

    tail_cmd = sub.add_parser("tail")
    tail_cmd.add_argument("count", nargs="?", type=int, default=10)

    parser.add_argument("--ledger", default=None)
    args = parser.parse_args()
    path = Path(args.ledger) if args.ledger else LEDGER_PATH

    if args.command == "append":
        try:
            data = json.loads(args.data)
        except json.JSONDecodeError as exc:
            print(f"--data is not valid JSON: {exc}", file=sys.stderr)
            return 2
        entry = append(args.kind, data, path)
        print(entry["entry_hash"])
        return 0

    if args.command == "verify":
        ok, problems, count = verify(path)
        if ok:
            print(f"ledger: ok · {count} entries · chain intact")
            return 0
        print(f"ledger: BROKEN · {count} entries verified before the break",
              file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    for entry in tail(args.count, path):
        print(json.dumps(entry, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
