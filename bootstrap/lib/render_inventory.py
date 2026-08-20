#!/usr/bin/env python3
"""Render inventory.yaml from the questionnaire's answers.

Reads answers from the environment (ANS_*), writes the one file in the
repository that is allowed to name a machine. Kept in Python rather than in
shell quoting because a mis-escaped address in this file is not a cosmetic
bug: every layer resolves its endpoints from here.

    render_inventory.py --out inventory.yaml
    render_inventory.py --print            emit to stdout, touch nothing

Round-trips through lib/miniyaml so the file this writes is provably a file
the baseline's own parser can read back. A bootstrap that emits config its
own tooling then rejects is worse than one that emits nothing.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))
import miniyaml  # noqa: E402
import inventory  # noqa: E402


def ans(key: str, default: str = "") -> str:
    return os.environ.get(f"ANS_{key}", default).strip()


def flag(key: str, default: bool = False) -> bool:
    raw = ans(key, "true" if default else "false").lower()
    return raw in ("1", "true", "yes", "on")


def quote(value: str) -> str:
    """Quote anything miniyaml would otherwise read as a non-string."""
    if value == "":
        return '""'
    if value.lower() in ("true", "false", "null", "yes", "no", "on", "off"):
        return f'"{value}"'
    if any(ch in value for ch in "#:'\"{}[],&*!|>%@`") or value != value.strip():
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def render() -> str:
    profile = ans("PROFILE", "existing-infra")
    lines: list[str] = []
    add = lines.append

    add("# inventory.yaml — the only file in this repository allowed to name a")
    add("# machine. Written by ./bootstrap/init.sh; safe to edit by hand.")
    add("#")
    add("# Re-validate after every edit:")
    add("#     python3 lib/inventory.py --validate")
    add("#")
    add("# This file is git-ignored. Your addresses are yours.")
    add("")
    add("roles:")
    add("  dev:")
    add(f"    addr: {quote(ans('DEV_ADDR', 'localhost'))}")
    add("    # The model that writes the code. Declared so the reviewer/author")
    add("    # separation can be checked rather than assumed. The check matches")
    add("    # on family, not on string equality.")
    add(f"    author_model: {quote(ans('AUTHOR_MODEL'))}")
    add("")
    add("  git:")
    add(f"    addr: {quote(ans('GIT_ADDR'))}")
    add(f"    type: {quote(ans('GIT_TYPE', 'gitea'))}")
    add(f"    user: {quote(ans('GIT_USER', 'git'))}")
    add(f"    repo_path: {quote(ans('GIT_REPO_PATH'))}")
    add(f"    ssh_port: {ans('GIT_SSH_PORT', '22')}")
    add("")
    add("  reviewer:")
    add(f"    addr: {quote(ans('REVIEWER_ADDR', '127.0.0.1'))}")
    add(f"    port: {ans('REVIEWER_PORT', '8080')}")
    add(f"    provider: {quote(ans('REVIEWER_PROVIDER', 'offline'))}")
    add(f"    model: {quote(ans('REVIEWER_MODEL', 'offline-canned'))}")
    add("    # Credentials never live here. Name an environment variable.")
    add(f"    api_key_env: {quote(ans('REVIEWER_API_KEY_ENV', 'SDLC_REVIEWER_API_KEY'))}")
    add("")
    add("  targets:")
    target_addr = ans("TARGET_ADDR")
    if target_addr:
        add(f"    - name: {quote(ans('TARGET_NAME', 'hello-world'))}")
        add(f"      addr: {quote(target_addr)}")
        add(f"      user: {quote(ans('TARGET_USER', 'deploy'))}")
        add(f"      path: {quote(ans('TARGET_PATH', '/srv/hello-world'))}")
        smoke = ans("TARGET_SMOKE_URL")
        if smoke:
            add(f"      smoke_url: {quote(smoke)}")
    else:
        add("    []")
    add("")
    add(f"  provisioner: {quote(ans('PROVISIONER', 'none'))}")
    add("")
    add("  sink:")
    add(f"    addr: {quote(ans('SINK_ADDR', 'localhost'))}")
    add(f"    path: {quote(ans('SINK_PATH', './.sdlc/audit'))}")
    add("")
    add("# Layers are individually selectable. l0 cannot be switched off — it is")
    add("# the governance spine and needs no infrastructure at all.")
    add("layers:")
    descriptions = {
        "l0": "governance spine: ADR schema, lint, conventions",
        "l1": "input hardening: sanitize + git hooks",
        "l2": "output gate: S0-S5, GO token, pre-push hook",
        "l3": "independent review: service, 7 disciplines",
        "l4": "server enforcement: pre-receive destructive guard",
        "l5": "deploy + audit: verified deploy, hash-chained ledger",
    }
    for layer, description in descriptions.items():
        value = "true" if (layer == "l0" or flag(layer.upper())) else "false"
        add(f"  {layer}: {value:<6}           # {description}")
    add("")
    add("# The profile this inventory was produced by. Informational, except")
    add("# that it determines which guarantees the bootstrap declares as NOT")
    add("# delivered — see docs/bootstrap.md.")
    add(f"profile: {quote(profile)}")
    add("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="render inventory.yaml")
    parser.add_argument("--out", default=None)
    parser.add_argument("--print", dest="to_stdout", action="store_true")
    args = parser.parse_args()

    text = render()

    # Prove the parser accepts what we just wrote, before it lands on disk.
    try:
        data = miniyaml.loads(text)
    except miniyaml.MiniYAMLError as exc:
        print(f"[render] refusing to write unparseable inventory: {exc}",
              file=sys.stderr)
        return 2
    if not isinstance(data, dict) or "roles" not in data:
        print("[render] rendered inventory has no roles mapping", file=sys.stderr)
        return 2
    # And that the separations were evaluated against the rendered shape, not
    # against the answers we think we collected.
    errors, _ = inventory.validate(data)
    if errors:
        for error in errors:
            print(f"[render] {error}", file=sys.stderr)
        return 1

    if args.to_stdout or not args.out:
        sys.stdout.write(text)
        return 0

    out = Path(args.out)
    if out.is_file() and out.read_text(encoding="utf-8") == text:
        print(f"[render] {out} already matches the answers — left untouched")
        return 0
    out.write_text(text, encoding="utf-8")
    try:
        out.chmod(0o600)
    except OSError:
        pass
    print(f"[render] wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
