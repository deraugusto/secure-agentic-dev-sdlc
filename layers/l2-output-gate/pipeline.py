#!/usr/bin/env python3
"""L2 · the output gate.

Six stages between an agent's changeset and a push. Three of them are
deterministic and cannot be waived by anyone; one of them calls a model and is
the only one a bypass flag reaches; the last one issues a token that binds the
result to this commit and this content.

    S0  assembly     collect the changeset, build the review bundle
    S1  hardlint     deterministic rules            not waivable
    S2  resanitize   agent output through the input scanner   not waivable
    S3  tripwire     canary integrity               not waivable
    S4  reviewer     the model, and its decision table        waivable, audited
    S5  gate         one decision; on GO, a sealed token

Before any stage runs, every manifest is hash-verified against the value sealed
inside it. Editing a manifest to widen a stage's capabilities or to make a
non-waivable stage waivable changes its hash, and the pipeline stops. That is
the property the "tampered apparatus" probe demonstrates.

    python3 pipeline.py                    the normal run
    python3 pipeline.py --bypass-reviewer  defer S4 only, audited
    python3 pipeline.py --dry-run          plan, touch nothing, issue nothing

Exit 0 on GO, 1 on NO-GO, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = Path(os.environ.get("SDLC_REPO_ROOT", str(HERE.parent.parent)))
sys.path.insert(0, str(REPO_ROOT / "lib"))

import miniyaml  # noqa: E402

MANIFEST_DIR = HERE / "manifests"
STATE_DIR = Path(os.environ.get("SDLC_STATE_DIR", str(REPO_ROOT / ".sdlc")))
AUDIT_DIR = STATE_DIR / "audit" / "gate"
WORK_DIR = STATE_DIR / "work"
CHANGESET_ROOT = WORK_DIR / "changeset"
BUNDLE_ROOT = WORK_DIR / "bundle"
TOKEN_FILE = STATE_DIR / "current-go.token"
TRIPWIRE_DIR = HERE / "tripwire"
TRIPWIRE_MANIFEST = HERE / "tripwire.sha256"

BUNDLE_VERSION = "1.0"
TOKEN_TTL_S = int(os.environ.get("SDLC_TOKEN_TTL", "900"))
MAX_INLINE_BYTES = int(os.environ.get("SDLC_MAX_INLINE_BYTES", "65536"))

STAGES = ["s0-assembly", "s1-hardlint", "s2-resanitize", "s3-tripwire",
          "s4-reviewer", "s5-gate"]

DEFER_VERDICTS = {"backend-unavailable", "backend-timeout", "model-error",
                  "no-response"}
ABORT_VERDICTS = {"tampering", "bundle-malformed"}


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    return sha256_bytes(text.encode("utf-8"))


class StageFailure(RuntimeError):
    def __init__(self, stage: str, reason: str, findings: list | None = None):
        super().__init__(f"{stage}: {reason}")
        self.stage = stage
        self.reason = reason
        self.findings = findings or []


# ── Audit ──────────────────────────────────────────────────────────────────

def audit(stage: str, record: dict, dry_run: bool = False) -> None:
    if dry_run:
        return
    target = AUDIT_DIR / stage / "audit.jsonl"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": utcnow(), **record},
                                ensure_ascii=False) + "\n")
    except OSError as exc:
        print(f"[gate] WARN audit write failed for {stage}: {exc}",
              file=sys.stderr)


# ── Manifest integrity ─────────────────────────────────────────────────────

def manifest_body_hash(path: Path) -> str:
    """Hash the manifest with its own self-hash line neutralised.

    Otherwise sealing a manifest changes the thing being sealed and the value
    can never be stable.
    """
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\s*manifest_self_hash:", line):
            lines.append("  manifest_self_hash: <SELF>")
        else:
            lines.append(line)
    return sha256_text("\n".join(lines) + "\n")


def seal_manifests() -> list[tuple[str, str]]:
    sealed = []
    for stage in STAGES:
        path = MANIFEST_DIR / f"{stage}.yaml"
        if stage == "s3-tripwire" and TRIPWIRE_MANIFEST.is_file():
            # Chain the canary list into the manifest before sealing it, so
            # rewriting the list requires re-sealing the manifest too.
            path.write_text(re.sub(
                r"^(\s*tripwire_manifest_hash:).*$",
                rf'\1 "{sha256_bytes(TRIPWIRE_MANIFEST.read_bytes())}"',
                path.read_text(encoding="utf-8"), flags=re.MULTILINE),
                encoding="utf-8")
        digest = manifest_body_hash(path)
        text = re.sub(r"^(\s*manifest_self_hash:).*$",
                      rf'\1 "{digest}"', path.read_text(encoding="utf-8"),
                      flags=re.MULTILINE)
        path.write_text(text, encoding="utf-8")
        sealed.append((stage, digest))
    return sealed


def verify_manifests() -> tuple[bool, str, dict]:
    manifests: dict[str, dict] = {}
    for stage in STAGES:
        path = MANIFEST_DIR / f"{stage}.yaml"
        if not path.is_file():
            return False, f"manifest-missing:{stage}", manifests
        try:
            data = miniyaml.load(path)
        except miniyaml.MiniYAMLError as exc:
            return False, f"manifest-unparseable:{stage}:{exc}", manifests
        sealed_value = ((data.get("hash_verify") or {}).get("manifest_self_hash"))
        if not sealed_value or sealed_value == "UNSEALED":
            return False, f"manifest-unsealed:{stage}", manifests
        if sealed_value != manifest_body_hash(path):
            return False, f"manifest-hash-mismatch:{stage}", manifests
        if data.get("deny_default") is not True:
            return False, f"manifest-deny-default-off:{stage}", manifests
        manifests[stage] = data
    # The waivability of each stage is read from the manifest, not hardcoded
    # here, so that flipping it is a hash-visible act.
    for stage in ("s0-assembly", "s1-hardlint", "s2-resanitize", "s3-tripwire",
                  "s5-gate"):
        if manifests[stage].get("waivable"):
            return False, f"manifest-waivable-widened:{stage}", manifests
    return True, "ok", manifests


# ── git helpers ────────────────────────────────────────────────────────────

def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(REPO_ROOT), *args],
                            capture_output=True, text=True)
    if check and result.returncode != 0:
        raise StageFailure("s0-assembly",
                           f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def resolve_base(explicit: str | None) -> tuple[str, str]:
    if explicit:
        return explicit, "explicit"
    upstream = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "--abbrev-ref", "@{u}"],
        capture_output=True, text=True)
    if upstream.returncode == 0 and upstream.stdout.strip():
        return upstream.stdout.strip(), "upstream"
    parent = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD~1"],
        capture_output=True, text=True)
    if parent.returncode == 0 and parent.stdout.strip():
        return parent.stdout.strip(), "head-parent"
    # An initial commit has no parent; compare against the empty tree.
    return git("hash-object", "-t", "tree", "/dev/null"), "empty-tree"


# ── S0 · assembly ──────────────────────────────────────────────────────────

def stage_s0(base: str | None, intent: str, dry_run: bool) -> dict:
    base_rev, base_source = resolve_base(base)
    head = git("rev-parse", "HEAD")

    names = git("diff", "--name-only", "--diff-filter=ACMRT", base_rev, "HEAD",
                check=False)
    changed = [n for n in names.splitlines() if n.strip()]

    if not changed:
        # A push with nothing new in it. The pipeline has nothing to review and
        # says so rather than issuing a token for an empty set.
        raise StageFailure("s0-assembly",
                           f"no changed files between {base_source}={base_rev[:12]} "
                           "and HEAD — nothing to gate")

    if not dry_run:
        if CHANGESET_ROOT.exists():
            shutil.rmtree(CHANGESET_ROOT)
        CHANGESET_ROOT.mkdir(parents=True, exist_ok=True)

    files = []
    for rel in sorted(changed):
        source = REPO_ROOT / rel
        if not source.is_file():
            continue
        raw = source.read_bytes()
        digest = sha256_bytes(raw)
        try:
            text = raw.decode("utf-8")
            truncated = len(raw) > MAX_INLINE_BYTES
            content = text[:MAX_INLINE_BYTES] if truncated else text
        except UnicodeDecodeError:
            truncated = True
            content = f"<binary · {len(raw)} bytes · sha256:{digest}>"
        files.append({"path": rel, "sha256": f"sha256:{digest}",
                      "bytes": len(raw), "truncated": truncated,
                      "content": content})
        if not dry_run:
            target = CHANGESET_ROOT / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)

    if not files:
        raise StageFailure("s0-assembly", "changed paths resolved to no readable files")

    root_hash = sha256_text(
        "\n".join(f"{f['path']}:{f['sha256']}" for f in files))

    bundle = {
        "bundle_version": BUNDLE_VERSION,
        "run_id": uuid.uuid4().hex[:12],
        "generated_at": utcnow(),
        "changeset": {"root_hash": f"sha256:{root_hash}", "files": files},
        "context": {
            "intent_summary": intent or _intent_from_commit(),
            "base_rev": base_rev,
            "base_source": base_source,
            "head": head,
        },
    }

    if not dry_run:
        BUNDLE_ROOT.mkdir(parents=True, exist_ok=True)
        (BUNDLE_ROOT / "bundle.json").write_text(
            json.dumps(bundle, indent=2, ensure_ascii=False), encoding="utf-8")

    audit("s0-assembly", {"run_id": bundle["run_id"], "files": len(files),
                          "root_hash": bundle["changeset"]["root_hash"],
                          "base": base_rev, "head": head}, dry_run)
    return bundle


def _intent_from_commit() -> str:
    subject = git("log", "-1", "--format=%s", check=False)
    return subject or "(no commit subject available)"


# ── S1 · hard lint ─────────────────────────────────────────────────────────

# Address ranges that may legitimately appear in code: loopback, the
# unspecified address, and the three ranges reserved for documentation.
_ADDRESS_OK = re.compile(
    r"^(?:127\.\d{1,3}\.\d{1,3}\.\d{1,3}|0\.0\.0\.0|255\.255\.255\.255"
    r"|192\.0\.2\.\d{1,3}|198\.51\.100\.\d{1,3}|203\.0\.113\.\d{1,3})$")
_IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
_VERSIONISH = re.compile(r"\d+\.\d+\.\d+\.\d+")

# Paths where an address is permitted, because that is where addresses live.
_ADDRESS_EXEMPT_PREFIXES = ("inventory.yaml", "inventory.example.yaml")

HARDLINT_RULES = [
    ("HL-ADDR-001", "address literal outside inventory.yaml"),
    ("HL-EXEC-002", "download piped into an interpreter"),
    ("HL-PERM-003", "world-writable or unrestricted permission bits"),
    ("HL-KEY-004", "private key material committed"),
    ("HL-EVAL-005", "eval or exec over assembled input"),
    ("HL-MSG-006", "commit subject does not match the convention"),
]

_RE_PIPE_TO_SHELL = re.compile(
    r"(?:curl|wget)\s+[^\n|]{1,200}\|\s*(?:sudo\s+)?(?:ba?sh|python3?|perl|ruby|node)\b")
_RE_PERM = re.compile(r"chmod\s+(?:-R\s+)?(?:0?777|a\+rwx)\b|0o777\b")
_RE_PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----")
_RE_EVAL = re.compile(r"\beval\s*\(\s*(?!['\"])|(?<![\w.])exec\s*\(\s*f['\"]")


def stage_s1(bundle: dict, dry_run: bool) -> dict:
    findings = []

    for entry in bundle["changeset"]["files"]:
        path, content = entry["path"], entry["content"]
        if any(path.startswith(prefix) for prefix in _ADDRESS_EXEMPT_PREFIXES):
            addresses_allowed = True
        else:
            addresses_allowed = False

        for lineno, line in enumerate(content.splitlines(), start=1):
            if not addresses_allowed:
                for candidate in _IPV4.findall(line):
                    if _ADDRESS_OK.match(candidate):
                        continue
                    if _VERSIONISH.fullmatch(candidate) and "." in candidate \
                            and not any(int(o) > 255 for o in candidate.split(".")):
                        # Ambiguous: 1.2.3.4 is both. Treated as an address,  # leak-sweep: allow prose about a shape, not an address
                        # because a false positive here costs one allowlist
                        # entry and a false negative costs the whole property.
                        pass
                    findings.append(_finding("HL-ADDR-001", path, lineno,
                                             "address literal — move it to inventory.yaml"))
            if _RE_PIPE_TO_SHELL.search(line):
                findings.append(_finding("HL-EXEC-002", path, lineno,
                                         "fetch piped straight into an interpreter"))
            if _RE_PERM.search(line):
                findings.append(_finding("HL-PERM-003", path, lineno,
                                         "unrestricted permission bits"))
            if _RE_PRIVATE_KEY.search(line):
                findings.append(_finding("HL-KEY-004", path, lineno,
                                         "private key block"))
            if _RE_EVAL.search(line):
                findings.append(_finding("HL-EVAL-005", path, lineno,
                                         "eval/exec over non-literal input"))

    # HL-MSG-006 · the commit message is part of the changeset's contract.
    commit_lint = REPO_ROOT / "layers" / "l0-governance" / "commit-lint.sh"
    if commit_lint.is_file():
        subject = git("log", "-1", "--format=%B", check=False)
        result = subprocess.run(["bash", str(commit_lint), "-"],
                                input=subject, capture_output=True, text=True)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip().splitlines()
            findings.append(_finding("HL-MSG-006", "<commit-message>", 1,
                                     "; ".join(detail[-3:]) or "rejected"))

    record = {"run_id": bundle["run_id"], "findings": len(findings),
              "rules": [rule for rule, _ in HARDLINT_RULES]}
    audit("s1-hardlint", {**record, "detail": findings[:20]}, dry_run)

    if findings:
        raise StageFailure("s1-hardlint",
                           f"{len(findings)} deterministic finding(s) — not waivable",
                           findings)
    return record


def _finding(rule: str, path: str, line: int, detail: str) -> dict:
    return {"rule": rule, "path": path, "line": line, "detail": detail}


# ── S2 · re-sanitize ───────────────────────────────────────────────────────

def stage_s2(bundle: dict, dry_run: bool) -> dict:
    scanner = REPO_ROOT / "layers" / "l1-input-hardening" / "sanitize.py"
    if not scanner.is_file():
        raise StageFailure("s2-resanitize",
                           "input scanner missing — cannot re-scan agent output")
    if dry_run:
        audit("s2-resanitize", {"run_id": bundle["run_id"], "skipped": "dry-run"}, True)
        return {"skipped": "dry-run"}

    env = dict(os.environ)
    env["SDLC_REPO_ROOT"] = str(CHANGESET_ROOT)
    env["SDLC_STATE_DIR"] = str(WORK_DIR / "s2-state")
    env["SDLC_SANITIZE_AUDIT"] = str(AUDIT_DIR / "s2-resanitize" / "sanitize.jsonl")
    env["SDLC_PATTERNS"] = str(
        REPO_ROOT / "layers" / "l1-input-hardening" / "patterns" / "baseline.json")
    env.pop("SDLC_NO_SANITIZE", None)  # the gate's copy is not opt-out-able

    (AUDIT_DIR / "s2-resanitize").mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [sys.executable, str(scanner), "--trigger", "gate-output-rescan", "--full"],
        capture_output=True, text=True, env=env)

    record = {"run_id": bundle["run_id"], "exit": result.returncode,
              "stdout": result.stdout.strip().splitlines()[-8:]}
    audit("s2-resanitize", record, dry_run)

    if result.returncode != 0:
        raise StageFailure(
            "s2-resanitize",
            "the agent's own output fails the scanner applied to incoming "
            "content — not waivable",
            [{"rule": "S2", "detail": line}
             for line in (result.stderr or result.stdout).strip().splitlines()[-6:]])
    return record


# ── S3 · tripwire ──────────────────────────────────────────────────────────

def stage_s3(bundle: dict, manifests: dict, dry_run: bool) -> dict:
    if not TRIPWIRE_MANIFEST.is_file():
        raise StageFailure(
            "s3-tripwire",
            f"no tripwire manifest at {TRIPWIRE_MANIFEST.name} — an unconfigured "
            "tripwire is treated as a broken one, never as an absent check")

    # The list of canaries is itself a target: rewriting it would let a modified
    # canary pass. Its hash is sealed inside the s3 manifest, which is sealed in
    # turn, so editing the list without re-sealing two files is caught here.
    expected_manifest_hash = ((manifests.get("s3-tripwire", {}).get("hash_verify")
                               or {}).get("tripwire_manifest_hash"))
    actual_manifest_hash = sha256_bytes(TRIPWIRE_MANIFEST.read_bytes())
    if expected_manifest_hash and expected_manifest_hash != actual_manifest_hash:
        raise StageFailure("s3-tripwire",
                           "tripwire manifest hash mismatch — the canary list itself "
                           "was modified", [{"rule": "TW-LIST-TAMPERED"}])

    expected: dict[str, str] = {}
    tokens: set[str] = set()
    for line in TRIPWIRE_MANIFEST.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("token:"):
            tokens.add(line.split(":", 1)[1].strip())
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            expected[parts[1].strip()] = parts[0].strip()

    findings = []

    for name, digest in expected.items():
        path = TRIPWIRE_DIR / name
        if not path.is_file():
            findings.append({"rule": "TW-MISSING", "path": name})
            continue
        if sha256_bytes(path.read_bytes()) != digest:
            findings.append({"rule": "TW-MODIFIED", "path": name})

    # A canary token appearing outside the tripwire directory means something
    # read that directory and carried its contents into the changeset.
    for entry in bundle["changeset"]["files"]:
        # The tripwire directory and its manifest are where the token belongs.
        if entry["path"].startswith("layers/l2-output-gate/tripwire"):
            continue
        for token in tokens:
            if token and token in entry["content"]:
                findings.append({"rule": "TW-TOKEN-LEAK", "path": entry["path"]})
                break

    record = {"run_id": bundle["run_id"], "canaries": len(expected),
              "tokens": len(tokens), "findings": len(findings)}
    audit("s3-tripwire", {**record, "detail": findings}, dry_run)

    if findings:
        raise StageFailure("s3-tripwire",
                           f"{len(findings)} tripwire finding(s) — not waivable",
                           findings)
    return record


# ── S4 · reviewer ──────────────────────────────────────────────────────────

def reviewer_endpoint() -> tuple[str, int]:
    host = os.environ.get("SDLC_REVIEWER_HOST")
    port = os.environ.get("SDLC_REVIEWER_PORT")
    if host and port:
        return host, int(port)
    try:
        import inventory  # noqa: E402

        data = inventory.load()
        reviewer = inventory.get("reviewer", data) or {}
        return (host or str(reviewer.get("addr", "127.0.0.1")),
                int(port or reviewer.get("port", 8080)))
    except Exception:
        return host or "127.0.0.1", int(port or 8080)


def _tcp_probe(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _health_probe(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/health",
                                    timeout=timeout) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _post_review(host: str, port: int, bundle: dict,
                 timeout: float = 180.0) -> tuple[str, str, list]:
    body = json.dumps(bundle, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        f"http://{host}:{port}/review", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError):
        return "no-response", "transport-failure", []
    except (json.JSONDecodeError, UnicodeDecodeError):
        return "no-response", "unparseable-response", []
    return (str(data.get("verdict", "model-error")),
            str(data.get("reason", "")), data.get("annotations") or [])


def _redact(annotations: list) -> list:
    """An audit sink that records the secret it detected is a second copy of it."""
    out = []
    for entry in annotations:
        entry = dict(entry)
        if entry.get("discipline") == "hardcoded-secret" \
                and entry.get("severity") != "clear":
            entry["rationale"] = "[REDACTED · secret-shaped literal]"
        out.append(entry)
    return out


def stage_s4(bundle: dict, bypass: bool, dry_run: bool) -> dict:
    host, port = reviewer_endpoint()
    base = {"run_id": bundle["run_id"], "bypass": bypass}

    if dry_run:
        reachable = _tcp_probe(host, port) and _health_probe(host, port)
        return {**base, "outcome": "DRY-RUN", "reachable": reachable,
                "decision": "GO" if reachable or bypass else "NO-GO"}

    if not (_tcp_probe(host, port) and _health_probe(host, port)):
        if bypass:
            record = {**base, "outcome": "DEFER", "reachable": False,
                      "verdict": None, "bypass_reason": "reviewer-unreachable",
                      "decision": "GO"}
            audit("s4-reviewer", record, dry_run)
            return record
        # Silence is not consent. No token is issued.
        record = {**base, "outcome": "UNREACHABLE", "reachable": False,
                  "verdict": None, "decision": "NO-GO"}
        audit("s4-reviewer", record, dry_run)
        return record

    verdict, reason, annotations = _post_review(host, port, bundle)

    if verdict == "annotations-only":
        record = {**base, "outcome": "PASS", "reachable": True,
                  "verdict": verdict, "decision": "GO",
                  "annotations": _redact(annotations)}
        audit("s4-reviewer", record, dry_run)
        return record

    if verdict in ABORT_VERDICTS:
        # An integrity defect, not an availability problem. The bypass flag does
        # not reach this branch, and waiving it would launder exactly the
        # condition the check exists to surface.
        record = {**base, "outcome": "FAIL", "reachable": True,
                  "verdict": verdict, "reason": reason,
                  "bypass_ignored": bypass, "decision": "NO-GO"}
        audit("s4-reviewer", record, dry_run)
        return record

    if verdict in DEFER_VERDICTS:
        record = {**base, "outcome": "DEFER", "reachable": True,
                  "verdict": verdict, "reason": reason,
                  "decision": "GO" if bypass else "NO-GO"}
        if bypass:
            record["bypass_reason"] = "reviewer-defer"
        audit("s4-reviewer", record, dry_run)
        return record

    record = {**base, "outcome": "FAIL", "reachable": True, "verdict": verdict,
              "reason": "unknown-verdict", "decision": "NO-GO"}
    audit("s4-reviewer", record, dry_run)
    return record


# ── S5 · gate ──────────────────────────────────────────────────────────────

def token_seal(fields: dict) -> str:
    return sha256_text(json.dumps(fields, sort_keys=True))


def issue_token(bundle: dict, head: str) -> dict:
    fields = {
        "run_id": bundle["run_id"],
        "changeset_root_hash": bundle["changeset"]["root_hash"],
        "git_head": head,
        "issued_ts": utcnow(),
        "ttl_s": TOKEN_TTL_S,
        "decision": "GO",
    }
    return {**fields, "seal": token_seal(fields)}


def stage_s5(bundle: dict, s4: dict, bypass: bool, dry_run: bool) -> dict:
    head = bundle["context"]["head"]
    decision = s4.get("decision", "NO-GO")

    record = {"run_id": bundle["run_id"], "decision": decision,
              "reviewer_outcome": s4.get("outcome"),
              "reviewer_verdict": s4.get("verdict"), "bypass": bypass,
              "git_head": head,
              "changeset_root_hash": bundle["changeset"]["root_hash"]}

    if dry_run:
        record["token"] = "not-issued-dry-run"
        return record

    if decision != "GO":
        # Any stale token is removed, so a NO-GO cannot be pushed through on a
        # token issued minutes earlier for the same commit.
        TOKEN_FILE.unlink(missing_ok=True)
        audit("s5-gate", record, dry_run)
        return record

    token = issue_token(bundle, head)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(json.dumps(token, indent=2), encoding="utf-8")
    TOKEN_FILE.chmod(0o600)
    record["token_path"] = str(TOKEN_FILE)
    record["ttl_s"] = TOKEN_TTL_S
    audit("s5-gate", record, dry_run)
    return record


# ── Driver ─────────────────────────────────────────────────────────────────

def run(args) -> int:
    print(f"[gate] {'DRY RUN · ' if args.dry_run else ''}output gate · "
          f"{len(STAGES)} stages")

    ok, reason, manifests = verify_manifests()
    if not ok:
        print(f"[gate] ABORT manifest verification failed: {reason}",
              file=sys.stderr)
        print("[gate] the apparatus describing this pipeline does not match its "
              "sealed hash. Re-seal deliberately with --seal-manifests, or find "
              "out who changed it.", file=sys.stderr)
        audit("s5-gate", {"decision": "NO-GO", "reason": reason}, args.dry_run)
        return 1
    print(f"[gate] manifests verified · {len(manifests)} stages sealed")

    try:
        bundle = stage_s0(args.base, args.intent, args.dry_run)
        print(f"[gate] S0 assembly    OK   run={bundle['run_id']} "
              f"files={len(bundle['changeset']['files'])}")

        stage_s1(bundle, args.dry_run)
        print("[gate] S1 hardlint    OK   no deterministic findings")

        stage_s2(bundle, args.dry_run)
        print("[gate] S2 resanitize  OK   agent output clean")

        stage_s3(bundle, manifests, args.dry_run)
        print("[gate] S3 tripwire    OK   canaries intact")

    except StageFailure as failure:
        print(f"[gate] {failure.stage.upper()} FAIL  {failure.reason}",
              file=sys.stderr)
        for finding in failure.findings[:12]:
            print(f"         {finding}", file=sys.stderr)
        if failure.stage in ("s1-hardlint", "s2-resanitize", "s3-tripwire"):
            print("[gate] this stage has no bypass. --bypass-reviewer defers S4 "
                  "and nothing else.", file=sys.stderr)
        TOKEN_FILE.unlink(missing_ok=True)
        audit("s5-gate", {"decision": "NO-GO", "failed_stage": failure.stage,
                          "reason": failure.reason}, args.dry_run)
        print("\n[gate] DECISION: NO-GO")
        return 1

    s4 = stage_s4(bundle, args.bypass_reviewer, args.dry_run)
    marker = {"PASS": "OK  ", "DEFER": "DEFER", "UNREACHABLE": "SILENT",
              "FAIL": "FAIL", "DRY-RUN": "PLAN"}.get(s4.get("outcome", ""), "?")
    print(f"[gate] S4 reviewer    {marker} outcome={s4.get('outcome')} "
          f"verdict={s4.get('verdict')}")

    if s4.get("outcome") == "PASS":
        for entry in s4.get("annotations", []):
            if entry.get("severity") != "clear":
                print(f"         {entry['severity']:<18} {entry['discipline']} "
                      f"{entry.get('file')}:{entry.get('line_range')}")
                print(f"           {entry.get('rationale', '')}")
    if s4.get("bypass_ignored"):
        print("[gate] --bypass-reviewer was set and IGNORED: an integrity defect "
              "is not an availability problem.", file=sys.stderr)

    s5 = stage_s5(bundle, s4, args.bypass_reviewer, args.dry_run)
    print(f"[gate] S5 gate        {s5['decision']}")

    if s5["decision"] == "GO" and not args.dry_run:
        print(f"[gate] token issued → {s5.get('token_path')} "
              f"(ttl {s5.get('ttl_s')}s, bound to {s5['git_head'][:12]})")
    elif s5["decision"] != "GO":
        print("[gate] no token issued. `git push` will be refused by the "
              "pre-push hook.", file=sys.stderr)

    print(f"\n[gate] DECISION: {s5['decision']}")
    return 0 if s5["decision"] == "GO" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="L2 output gate")
    parser.add_argument("--bypass-reviewer", action="store_true",
                        help="defer the S4 reviewer checkpoint only; the three "
                             "deterministic stages and the two integrity "
                             "verdicts are unaffected")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--base", default=None,
                        help="revision to diff against (default: upstream, else HEAD~1)")
    parser.add_argument("--intent", default="",
                        help="one line describing what the change is for")
    parser.add_argument("--seal-manifests", action="store_true",
                        help="write each manifest's self-hash into it")
    args = parser.parse_args()

    if args.seal_manifests:
        for stage, digest in seal_manifests():
            print(f"sealed {stage} {digest[:16]}…")
        return 0

    try:
        return run(args)
    except KeyboardInterrupt:
        return 1
    except Exception as exc:
        # Fail closed on anything unexpected: an error is never a pass.
        print(f"[gate] ERROR {type(exc).__name__}: {exc}", file=sys.stderr)
        TOKEN_FILE.unlink(missing_ok=True)
        print("\n[gate] DECISION: NO-GO")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
