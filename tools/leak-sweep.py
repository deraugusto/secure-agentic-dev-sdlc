#!/usr/bin/env python3
"""Refuse to hand over a repository that still names someone's infrastructure.

This baseline is meant to be given away. The moment it carries a real address,
an internal hostname or a container id, it stops being a baseline and becomes a
description of the network it came from -- and that disclosure is not
retractable once the repository is out.

So the rule is not "review carefully before sharing". The rule is a sweep that
fails the commit, because careful review is exactly the control that degrades
when someone is in a hurry.

    python3 tools/leak-sweep.py                 sweep the working tree
    python3 tools/leak-sweep.py --staged        sweep what is about to commit
    python3 tools/leak-sweep.py path [path...]  sweep specific paths

Exit 0 clean, 1 on findings, 2 on a usage error.

What is deliberately allowed:

    localhost, 127.0.0.1, 0.0.0.0, ::1        loopback names no network
    *.example.com / .net / .org / .internal   reserved for documentation
    192.0.2.x, 198.51.100.x, 203.0.113.x      RFC 5737 documentation ranges
    version numbers, sha hashes, ports        not addresses

A finding is not automatically a leak -- but it is automatically a stop, and
somebody has to look at it and say so out loud. There are two ways to say so:

    # leak-sweep: allow <reason>     on the offending line, for source files
    tools/leak-sweep.allow           for files that must not be edited,
                                     such as hash-sealed tripwire content

Both require a written reason. Neither is a way to switch the sweep off: an
allowlist entry names one exact value in one exact file, so a second leak in
the same file still stops the commit.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The sweep must not flag its own pattern library: a file whose job is to
# contain examples of what a leak looks like will contain examples of what a
# leak looks like.
SKIP_PATHS = (
    "tools/leak-sweep.py",
    # The allowlist necessarily quotes the values it exempts, so sweeping it
    # would re-report every declared exception. That does mean a secret hidden
    # in this file is invisible to the sweep -- which is why every entry needs a
    # written reason and the file is small enough to read in full.
    "tools/leak-sweep.allow",
    "layers/l1-input-hardening/patterns/",
    ".git/",
    ".sdlc/",
    "__pycache__/",
    "inventory.yaml",          # git-ignored; it is where addresses belong
)

SKIP_SUFFIXES = (".pyc", ".png", ".jpg", ".gif", ".pdf", ".tar", ".gz", ".zip")

ALLOWLIST_FILE = REPO_ROOT / "tools" / "leak-sweep.allow"

ALLOWED_IPS = {"127.0.0.1", "0.0.0.0", "255.255.255.255", "::1"}
ALLOWED_DOC_PREFIXES = ("192.0.2.", "198.51.100.", "203.0.113.")
ALLOWED_HOST_SUFFIXES = (
    ".example.com", ".example.net", ".example.org", ".example.internal",
    ".example", ".invalid", ".test", ".localhost",
)

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
HOSTNAME = re.compile(
    r"\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"(?:internal|local|lan|home|intern|corp|prod|staging)\b",
    re.IGNORECASE,
)
# Container / VM identifiers of the shape a hypervisor hands out. Written to
# catch the habit ("CT 123", "vmid=456"), not every three-digit number.
CONTAINER_ID = re.compile(
    r"\b(?:CT|LXC|VM|VMID|ctid|vmid|pct\s+\w+)\s*[:=#]?\s*\d{2,5}\b",
    re.IGNORECASE)
SSH_KEYISH = re.compile(
    r"(BEGIN (?:RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY|ssh-(?:rsa|ed25519) AAAA)")
TOKENISH = re.compile(
    r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|glpat-[A-Za-z0-9_-]{16,}|"
    r"sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})")
# A password or token assigned inline. `api_key_env: NAME` is the sanctioned
# shape and must not match: it names a variable, it does not carry a secret.
INLINE_SECRET = re.compile(
    r"\b(?:password|passwd|secret|api[_-]?key|token|auth)\s*[:=]\s*"
    r"[\"']?(?!\s*$)(?!.*_ENV\b)[A-Za-z0-9/+_-]{12,}[\"']?", re.IGNORECASE)


def allowed_ip(value: str) -> bool:
    if value in ALLOWED_IPS:
        return True
    if any(value.startswith(prefix) for prefix in ALLOWED_DOC_PREFIXES):
        return True
    octets = value.split(".")
    if len(octets) != 4:
        return True
    try:
        numbers = [int(part) for part in octets]
    except ValueError:
        return True
    if any(number > 255 for number in numbers):
        return True          # a version string, not an address
    return False


def allowed_host(value: str) -> bool:
    lowered = value.lower()
    return any(lowered.endswith(suffix) for suffix in ALLOWED_HOST_SUFFIXES)


CHECKS = (
    ("ipv4-literal",   IPV4,          allowed_ip),
    ("internal-host",  HOSTNAME,      allowed_host),
    ("container-id",   CONTAINER_ID,  None),
    ("private-key",    SSH_KEYISH,    None),
    ("provider-token", TOKENISH,      None),
    ("inline-secret",  INLINE_SECRET, None),
)


def load_allowlist() -> set[tuple[str, str, str]]:
    """path:label:value triples, each with a reason. Line numbers deliberately
    play no part -- an allowlist keyed on line numbers silently re-arms itself
    every time someone inserts a line above the entry."""
    entries: set[tuple[str, str, str]] = set()
    if not ALLOWLIST_FILE.is_file():
        return entries
    for raw in ALLOWLIST_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(":", 2)
        if len(parts) != 3:
            print(f"[leak-sweep] malformed allowlist entry: {raw.strip()!r}",
                  file=sys.stderr)
            continue
        entries.add((parts[0].strip(), parts[1].strip(), parts[2].strip()))
    return entries


def should_skip(path: Path) -> bool:
    try:
        rel = path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        rel = path.as_posix()
    if any(rel.startswith(skip) or f"/{skip}" in f"/{rel}" for skip in SKIP_PATHS):
        return True
    return path.suffix in SKIP_SUFFIXES


def sweep_file(path: Path, allowlist: set[tuple[str, str, str]]
               ) -> list[tuple[int, str, str, str]]:
    findings: list[tuple[int, str, str, str]] = []
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return findings
    try:
        rel = path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        rel = path.as_posix()
    for lineno, line in enumerate(text.splitlines(), start=1):
        if "leak-sweep: allow" in line:
            continue
        for label, pattern, allow in CHECKS:
            for match in pattern.finditer(line):
                value = match.group(0)
                if allow and allow(value):
                    continue
                if (rel, label, value) in allowlist:
                    continue
                findings.append((lineno, label, value, line.strip()[:120]))
    return findings


def collect(paths: list[str]) -> list[Path]:
    if paths:
        out: list[Path] = []
        for raw in paths:
            path = Path(raw)
            if path.is_dir():
                out.extend(p for p in path.rglob("*") if p.is_file())
            elif path.is_file():
                out.append(path)
        return out
    return [p for p in REPO_ROOT.rglob("*") if p.is_file()]


def staged_paths() -> list[Path]:
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("[leak-sweep] not a git repository, or git unavailable",
              file=sys.stderr)
        return []
    return [REPO_ROOT / line for line in result.stdout.split("\n") if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description="pre-handover leak sweep")
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--staged", action="store_true",
                        help="sweep the staged changeset instead of the tree")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    files = staged_paths() if args.staged else collect(args.paths)
    files = [f for f in files if f.is_file() and not should_skip(f)]

    allowlist = load_allowlist()

    total = 0
    for path in sorted(files):
        for lineno, label, value, line in sweep_file(path, allowlist):
            total += 1
            try:
                shown = path.relative_to(REPO_ROOT)
            except ValueError:
                shown = path
            print(f"{shown}:{lineno}: {label}: {value}")
            if not args.quiet:
                print(f"    {line}")

    if total:
        print(f"\n[leak-sweep] {total} finding(s) in {len(files)} file(s) — STOP.",
              file=sys.stderr)
        print("[leak-sweep] Each one is either a real address that must move into",
              file=sys.stderr)
        print("             inventory.yaml, or a false positive that must be",
              file=sys.stderr)
        print("             declared -- '# leak-sweep: allow <reason>' on the line,",
              file=sys.stderr)
        print("             or an entry in tools/leak-sweep.allow for files that",
              file=sys.stderr)
        print("             must not be edited. Silence is not one of the options.",
              file=sys.stderr)
        return 1

    if not args.quiet:
        suffix = f", {len(allowlist)} declared exception(s)" if allowlist else ""
        print(f"[leak-sweep] clean · {len(files)} file(s) swept{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
