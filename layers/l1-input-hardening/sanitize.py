#!/usr/bin/env python3
"""L1 · Input hardening — scan the working copy before an agent reads it.

Repository content is not neutral data. A file that arrives by pull, checkout
or rebase can carry direction-override characters, zero-width sequences,
homoglyph substitutions, or plain prose engineered to read as an instruction
rather than as content. An agent has no reliable way to tell "text I am
reading" from "text telling me what to do", so the working copy has to be
treated as an attack surface rather than as a trusted input.

Seven stages, in order:

    1  file-type gate      extension and size; everything else is skipped
    2  unicode NFKC        normalise before comparing anything
    3  invisible strip     zero-width, tag block, C0 controls
    4  bidi scan           embedding, override and isolate controls
    5  homoglyph scan      mixed-script tokens above a ratio threshold
    6  pattern scan        the tunable library in patterns/
    7  audit + state       append a record, cache the file hash

Default mode is detect-and-refuse: nothing on disk is modified. `--fix` writes
the normalised content back, and is opt-in because silently rewriting a working
copy is a worse failure than refusing to run.

Exit 0  pass or warn
Exit 1  reject, or a pipeline error (fail-closed: an error is not a pass)

    python3 sanitize.py --trigger pre-agent-invoke --full
    python3 sanitize.py --trigger post-git-pull path/to/file.py ...
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────────

HERE = Path(__file__).resolve().parent
REPO_ROOT = Path(os.environ.get("SDLC_REPO_ROOT", str(HERE.parent.parent)))
STATE_DIR = Path(os.environ.get("SDLC_STATE_DIR", str(REPO_ROOT / ".sdlc")))
AUDIT_LOG = Path(os.environ.get("SDLC_SANITIZE_AUDIT",
                                str(STATE_DIR / "audit" / "sanitize.jsonl")))
STATE_FILE = STATE_DIR / "sanitize-state.json"
PATTERN_FILE = Path(os.environ.get("SDLC_PATTERNS",
                                   str(HERE / "patterns" / "baseline.json")))
ALLOWLIST_FILE = HERE / "allowlist.txt"

CACHE_TTL_SECONDS = int(os.environ.get("SDLC_SANITIZE_TTL", "300"))
SIZE_LIMIT_BYTES = int(os.environ.get("SDLC_SANITIZE_SIZE_LIMIT", str(1 << 20)))

SOURCE_EXTENSIONS = {".py", ".sh", ".js", ".mjs", ".ts", ".yaml", ".yml",
                     ".json", ".toml", ".ini", ".cfg", ".sql", ".rb", ".go"}
DOC_EXTENSIONS = {".md", ".txt", ".rst", ".adoc"}
ALL_EXTENSIONS = SOURCE_EXTENSIONS | DOC_EXTENSIONS

# Paths the scanner must not read as content.
#
# patterns/ holds the library itself: scanning it would match every pattern
# against its own definition. .git/ is git's business. The state directory is
# our own output.
EXCLUDE_PREFIXES = (
    "layers/l1-input-hardening/patterns/",
    "layers/l1-input-hardening/allowlist.txt",
    ".git/",
    ".sdlc/",
    "node_modules/",
)

# Character classes are built with chr() rather than written as literals. A
# literal zero-width character in this file would make the scanner reject its
# own source the first time it is scanned.
_ZERO_WIDTH = "".join(chr(c) for c in (0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF))
_TAG_BLOCK = "".join(chr(c) for c in range(0xE0000, 0xE0080))
_C0_CONTROLS = ("".join(chr(c) for c in range(0x00, 0x09))
                + chr(0x0B) + chr(0x0C)
                + "".join(chr(c) for c in range(0x0E, 0x20)))
_BIDI_OVERRIDE = "".join(chr(c) for c in range(0x202A, 0x202F))   # LRE..PDF
_BIDI_ISOLATE = "".join(chr(c) for c in range(0x2066, 0x206A))    # LRI..PDI

INVISIBLE_RE = re.compile("[" + _ZERO_WIDTH + _TAG_BLOCK + _C0_CONTROLS + "]")
BIDI_RE = re.compile("[" + _BIDI_OVERRIDE + _BIDI_ISOLATE + "]")
TOKEN_RE = re.compile(r"[^\W\d_]{4,}", re.UNICODE)

# Any minority script inside an identifier is suspicious, so the threshold is
# "more than none". A ratio threshold was the wrong shape for this check: the
# classic homoglyph substitution is ONE character, and one Cyrillic 'a' in a
# six-letter identifier is a ratio of 0.17 -- under any threshold worth setting,
# and exactly the attack the stage exists to catch. Length is what guards
# against false positives here, and TOKEN_RE already requires four characters.
MIXED_SCRIPT_MIN_RATIO = 0.0

VERDICT_ORDER = {"pass": 0, "warn": 1, "reject": 2}

NO_SANITIZE = os.environ.get("SDLC_NO_SANITIZE", "").strip() in ("1", "true", "yes")


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def worse(a: str, b: str) -> str:
    return a if VERDICT_ORDER[a] >= VERDICT_ORDER[b] else b


# ── Stage 1 · file-type gate ───────────────────────────────────────────────

def classify(path: Path) -> str | None:
    suffix = path.suffix.lower()
    if suffix in SOURCE_EXTENSIONS:
        return "source"
    if suffix in DOC_EXTENSIONS:
        return "doc"
    return None


def is_excluded(path: Path) -> bool:
    try:
        rel = path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return False
    return any(rel.startswith(prefix) or rel == prefix.rstrip("/")
               for prefix in EXCLUDE_PREFIXES)


# ── Stage 2 · normalise ────────────────────────────────────────────────────

def stage_nfkc(content: str) -> tuple[str, dict]:
    normalised = unicodedata.normalize("NFKC", content)
    return normalised, {"changed": normalised != content}


# ── Stage 3 · invisible characters ─────────────────────────────────────────

def stage_invisible(content: str) -> tuple[str, dict]:
    hits = INVISIBLE_RE.findall(content)
    cleaned = INVISIBLE_RE.sub("", content)
    return cleaned, {
        "count": len(hits),
        "codepoints": sorted({f"U+{ord(c):04X}" for c in hits}),
    }


# ── Stage 4 · bidi controls ────────────────────────────────────────────────

def stage_bidi(content: str, file_class: str) -> tuple[str, dict, str]:
    """Direction-override characters reorder rendered text without changing it.

    Source code that renders differently than it executes is the Trojan Source
    class. In code this is a refusal; in prose it is far more often a genuine
    right-to-left passage, so it warns.
    """
    hits = BIDI_RE.findall(content)
    if not hits:
        return content, {"count": 0}, "pass"
    verdict = "reject" if file_class == "source" else "warn"
    return (BIDI_RE.sub("", content),
            {"count": len(hits),
             "codepoints": sorted({f"U+{ord(c):04X}" for c in hits})},
            verdict)


# ── Stage 5 · homoglyphs ───────────────────────────────────────────────────

def _script_of(char: str) -> str:
    try:
        name = unicodedata.name(char)
    except ValueError:
        return "UNKNOWN"
    return name.split(" ")[0]


def _mixed_script_ratio(token: str) -> float:
    scripts = [_script_of(c) for c in token if c.isalpha()]
    if len(scripts) < 4:
        return 0.0
    counts: dict[str, int] = {}
    for script in scripts:
        counts[script] = counts.get(script, 0) + 1
    dominant = max(counts.values())
    return (len(scripts) - dominant) / len(scripts)


def stage_homoglyph(content: str, file_class: str) -> tuple[dict, str]:
    """Identifiers built from lookalikes across scripts.

    Cyrillic 'а' inside an otherwise Latin identifier renders as Latin 'a' and
    compares unequal. Detection is stdlib-only: any character outside the
    token's dominant script marks the token, and _mixed_script_ratio returns 0
    for tokens too short to judge.
    """
    suspicious = []
    for token in TOKEN_RE.findall(content):
        ratio = _mixed_script_ratio(token)
        if ratio > MIXED_SCRIPT_MIN_RATIO:
            suspicious.append({
                "token": "".join(f"U+{ord(c):04X}" for c in token[:24]),
                "ratio": round(ratio, 3),
            })
        if len(suspicious) >= 8:
            break
    if not suspicious:
        return {"count": 0}, "pass"
    verdict = "reject" if file_class == "source" else "warn"
    return {"count": len(suspicious), "tokens": suspicious}, verdict


# ── Stage 6 · pattern scan ─────────────────────────────────────────────────

_pattern_cache: list[dict] | None = None


def load_patterns(path: Path = PATTERN_FILE) -> list[dict]:
    global _pattern_cache
    if _pattern_cache is not None:
        return _pattern_cache
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != "sdlc-baseline-patterns/1":
        raise ValueError(f"{path}: unexpected schema {data.get('schema')!r}")
    compiled = []
    for category in data["categories"]:
        compiled.append({
            "name": category["name"],
            "applies_to": category.get("applies_to", ["source", "doc"]),
            "action_source": category.get("action_source", "warn"),
            "action_doc": category.get("action_doc", "warn"),
            "regexes": [re.compile(p) for p in category["patterns"]],
        })
    _pattern_cache = compiled
    return compiled


def stage_patterns(content: str, file_class: str,
                   categories: list[dict]) -> tuple[dict, str]:
    verdict = "pass"
    matches = []
    for category in categories:
        if file_class not in category["applies_to"]:
            continue
        action = category["action_source"] if file_class == "source" \
            else category["action_doc"]
        for regex in category["regexes"]:
            found = regex.search(content)
            if not found:
                continue
            line = content.count("\n", 0, found.start()) + 1
            matches.append({
                "category": category["name"],
                "line": line,
                "action": action,
                # The matched text is deliberately not recorded. An audit sink
                # that stores the payload it detected is a second copy of the
                # payload.
                "match_len": found.end() - found.start(),
            })
            verdict = worse(verdict, action)
            break
    return {"count": len(matches), "matches": matches}, verdict


# ── Stage 7 · audit + state ────────────────────────────────────────────────

def write_audit(entry: dict) -> None:
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        with AUDIT_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as exc:
        # Audit is forensic, not gating: a full disk must not become a bypass
        # in either direction. The verdict still stands on stdout.
        print(f"[sanitize] WARN audit write failed: {exc}", file=sys.stderr)


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_state() -> dict:
    if not STATE_FILE.is_file():
        return {}
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def save_state(state: dict) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")
    except OSError:
        pass


def cache_hit(state: dict, key: str, digest: str, now: float) -> bool:
    entry = state.get(key)
    if not entry or entry.get("sha256") != digest:
        return False
    if entry.get("verdict") != "pass":
        # Only clean results are cached. A previous reject is re-derived every
        # time, so a stale cache can never turn a refusal into a pass.
        return False
    return (now - float(entry.get("ts_epoch", 0))) < CACHE_TTL_SECONDS


# ── Allowlist ──────────────────────────────────────────────────────────────

def load_allowlist() -> list[str]:
    if not ALLOWLIST_FILE.is_file():
        return []
    entries = []
    for line in ALLOWLIST_FILE.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.append(line)
    return entries


def allowlisted(rel_path: str, allowlist: list[str]) -> bool:
    return any(rel_path == entry or rel_path.startswith(entry.rstrip("*"))
               for entry in allowlist)


# ── Per-file pipeline ──────────────────────────────────────────────────────

def process(path: Path, trigger: str, categories: list[dict],
            fix: bool) -> dict:
    rel = path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    file_class = classify(path)
    result = {
        "ts": utcnow(),
        "trigger": trigger,
        "path": rel,
        "class": file_class,
        "verdict": "pass",
        "stages": {},
    }

    if file_class is None:
        result["verdict"] = "skip"
        result["reason"] = "extension-not-in-scope"
        return result

    size = path.stat().st_size
    if size > SIZE_LIMIT_BYTES:
        result["verdict"] = "skip"
        result["reason"] = f"size-{size}-over-limit-{SIZE_LIMIT_BYTES}"
        return result

    try:
        original = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError) as exc:
        result["verdict"] = "skip"
        result["reason"] = f"unreadable:{type(exc).__name__}"
        return result

    content, nfkc_info = stage_nfkc(original)
    result["stages"]["nfkc"] = nfkc_info

    content, invisible_info = stage_invisible(content)
    result["stages"]["invisible"] = invisible_info
    if invisible_info["count"]:
        result["verdict"] = worse(
            result["verdict"], "reject" if file_class == "source" else "warn")

    content, bidi_info, bidi_verdict = stage_bidi(content, file_class)
    result["stages"]["bidi"] = bidi_info
    result["verdict"] = worse(result["verdict"], bidi_verdict)

    homoglyph_info, homoglyph_verdict = stage_homoglyph(content, file_class)
    result["stages"]["homoglyph"] = homoglyph_info
    result["verdict"] = worse(result["verdict"], homoglyph_verdict)

    pattern_info, pattern_verdict = stage_patterns(content, file_class, categories)
    result["stages"]["patterns"] = pattern_info
    result["verdict"] = worse(result["verdict"], pattern_verdict)

    if fix and content != original:
        path.write_text(content, encoding="utf-8")
        result["fixed"] = True

    return result


# ── File collection ────────────────────────────────────────────────────────

def collect(paths: list[str], full: bool) -> list[Path]:
    root = REPO_ROOT.resolve()
    if full or not paths:
        candidates = [p for p in root.rglob("*") if p.is_file()]
    else:
        candidates = []
        for raw in paths:
            candidate = Path(raw)
            if not candidate.is_absolute():
                candidate = root / candidate
            if candidate.is_file():
                candidates.append(candidate)
    out = []
    for candidate in candidates:
        if candidate.suffix.lower() not in ALL_EXTENSIONS:
            continue
        if is_excluded(candidate):
            continue
        out.append(candidate)
    return sorted(out)


# ── Driver ─────────────────────────────────────────────────────────────────

def run(paths: list[str], trigger: str, full: bool, fix: bool,
        quiet: bool) -> int:
    import time

    if NO_SANITIZE:
        # An escape hatch that leaves a record. Removing the record is the
        # attack; leaving the hatch undocumented is how it gets used casually.
        write_audit({"ts": utcnow(), "trigger": trigger,
                     "verdict": "bypassed", "reason": "SDLC_NO_SANITIZE set"})
        print("[sanitize] BYPASSED via SDLC_NO_SANITIZE — audited", file=sys.stderr)
        return 0

    try:
        categories = load_patterns()
    except (OSError, ValueError, re.error) as exc:
        print(f"[sanitize] ERROR pattern library unusable: {exc}", file=sys.stderr)
        return 1  # fail-closed

    allowlist = load_allowlist()
    state = load_state()
    now = time.time()

    files = collect(paths, full)
    overall = "pass"
    rejected: list[dict] = []
    warned: list[dict] = []
    scanned = 0
    cached = 0

    for path in files:
        rel = path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
        try:
            digest = file_hash(path)
        except OSError:
            continue

        if allowlisted(rel, allowlist):
            continue

        if cache_hit(state, rel, digest, now):
            cached += 1
            continue

        result = process(path, trigger, categories, fix)
        scanned += 1

        if result["verdict"] == "skip":
            continue

        state[rel] = {"sha256": digest, "verdict": result["verdict"],
                      "ts_epoch": now}

        write_audit(result)
        if result["verdict"] == "reject":
            rejected.append(result)
            overall = "reject"
        elif result["verdict"] == "warn":
            warned.append(result)
            overall = worse(overall, "warn")

    save_state(state)

    summary = {
        "ts": utcnow(), "trigger": trigger, "verdict": overall,
        "files_scanned": scanned, "files_cached": cached,
        "rejected": len(rejected), "warned": len(warned),
    }
    write_audit(summary)

    if not quiet:
        print(f"[sanitize] {trigger}: {scanned} scanned, {cached} cached, "
              f"{len(warned)} warn, {len(rejected)} reject → {overall.upper()}")
        for entry in warned:
            print(f"  WARN   {entry['path']}  {_reason(entry)}")
        for entry in rejected:
            print(f"  REJECT {entry['path']}  {_reason(entry)}", file=sys.stderr)

    if rejected:
        print("[sanitize] refusing to hand this working copy to an agent.",
              file=sys.stderr)
        return 1
    return 0


def _reason(entry: dict) -> str:
    bits = []
    stages = entry["stages"]
    if stages.get("invisible", {}).get("count"):
        bits.append(f"invisible×{stages['invisible']['count']}")
    if stages.get("bidi", {}).get("count"):
        bits.append(f"bidi×{stages['bidi']['count']}")
    if stages.get("homoglyph", {}).get("count"):
        bits.append(f"homoglyph×{stages['homoglyph']['count']}")
    for match in stages.get("patterns", {}).get("matches", []):
        bits.append(f"{match['category']}@{match['line']}")
    return " ".join(bits) or "unspecified"


def main() -> int:
    parser = argparse.ArgumentParser(description="L1 input hardening scan")
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--trigger", default="manual")
    parser.add_argument("--full", action="store_true",
                        help="scan the whole working copy")
    parser.add_argument("--fix", action="store_true",
                        help="write normalised content back (off by default)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    try:
        return run(args.paths, args.trigger, args.full, args.fix, args.quiet)
    except Exception as exc:  # fail-closed on anything unexpected
        print(f"[sanitize] ERROR {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
