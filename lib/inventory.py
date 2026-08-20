#!/usr/bin/env python3
"""inventory.yaml — the one place an address is allowed to appear.

Every layer reads its endpoints from here. No script in this repository may
carry a host, an address or a port as a literal. That single rule is what makes
the baseline both shareable (nothing about the author's network leaks) and
portable (nothing about the author's network has to be true for you).

Six roles: dev, git, reviewer, targets, provisioner, sink. They may co-locate.
Three separations are load-bearing and are checked here:

    git      != dev   a compromised dev host must not be able to switch the
                      server-side hook off
    targets  != dev   the hand that writes code never reaches the deployment
                      target directly
    reviewer model != author model
                      a reviewer sharing the author's weights is a self-check
                      with correlated blind spots, not a second opinion

Everything else — a dedicated reviewer host, a separate audit sink, a
hypervisor — is topology preference, not a security property.

CLI:
    python3 lib/inventory.py --validate
    python3 lib/inventory.py --get reviewer.addr
    python3 lib/inventory.py --layers
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import miniyaml  # noqa: E402

REPO_ROOT = Path(
    os.environ.get("SDLC_REPO_ROOT", str(Path(__file__).resolve().parent.parent))
)
INVENTORY_PATH = Path(
    os.environ.get("SDLC_INVENTORY", str(REPO_ROOT / "inventory.yaml"))
)

ROLES = ("dev", "git", "reviewer", "targets", "provisioner", "sink")
LAYERS = ("l0", "l1", "l2", "l3", "l4", "l5")

GIT_TYPES = ("gitea", "gitlab", "github", "plain-ssh")
REVIEWER_PROVIDERS = ("ollama", "openai-compat", "offline")
PROVISIONERS = ("proxmox", "docker", "none")


class InventoryError(RuntimeError):
    pass


# ── Load ───────────────────────────────────────────────────────────────────


def load(path: Path | str | None = None) -> dict:
    target = Path(path) if path else INVENTORY_PATH
    if not target.is_file():
        raise InventoryError(
            f"no inventory at {target}\n"
            f"run ./bootstrap/init.sh (or copy inventory.example.yaml)"
        )
    data = miniyaml.load(target)
    if not isinstance(data, dict):
        raise InventoryError(f"{target}: top level must be a mapping")
    return data


def get(dotted: str, data: dict | None = None, default=None):
    """inventory.get('reviewer.addr') — roles are addressed without the prefix."""
    data = data if data is not None else load()
    node = data.get("roles", {}) if dotted.split(".")[0] in ROLES else data
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node


def layer_enabled(layer: str, data: dict | None = None) -> bool:
    data = data if data is not None else load()
    layers = data.get("layers") or {}
    value = layers.get(layer)
    if value is None:
        return False
    return bool(value)


def enabled_layers(data: dict | None = None) -> list[str]:
    data = data if data is not None else load()
    return [name for name in LAYERS if layer_enabled(name, data)]


# ── Validate ───────────────────────────────────────────────────────────────


def _as_mapping(value, label: str, errors: list) -> dict:
    if value is None:
        return {}
    if not isinstance(value, dict):
        errors.append(f"{label}: expected a mapping, got {type(value).__name__}")
        return {}
    return value


def validate(data: dict) -> tuple[list[str], list[str]]:
    """Returns (errors, warnings). Errors are fatal; warnings are declared gaps."""
    errors: list[str] = []
    warnings: list[str] = []

    roles = _as_mapping(data.get("roles"), "roles", errors)
    if not roles:
        errors.append("roles: missing — inventory carries no role assignment")
        return errors, warnings

    for role in ROLES:
        if role not in roles:
            errors.append(f"roles.{role}: missing")

    layers = _as_mapping(data.get("layers"), "layers", errors)
    for layer in LAYERS:
        if layer not in layers:
            warnings.append(f"layers.{layer}: not declared — treated as disabled")
    if not layers.get("l0"):
        errors.append("layers.l0: the governance spine cannot be switched off")

    dev = _as_mapping(roles.get("dev"), "roles.dev", errors)
    git = _as_mapping(roles.get("git"), "roles.git", errors)
    reviewer = _as_mapping(roles.get("reviewer"), "roles.reviewer", errors)
    targets = roles.get("targets") or []
    provisioner = roles.get("provisioner")

    dev_addr = dev.get("addr")
    if not dev_addr:
        errors.append("roles.dev.addr: missing")

    # ── git role ──
    if layers.get("l4"):
        if git.get("type") not in GIT_TYPES:
            errors.append(
                f"roles.git.type: {git.get('type')!r} not in {list(GIT_TYPES)}"
            )
        if not git.get("addr"):
            errors.append("roles.git.addr: missing")
        # Separation 1 · load-bearing
        if git.get("addr") and git.get("addr") == dev_addr:
            errors.append(
                "SEPARATION VIOLATED · roles.git.addr == roles.dev.addr — a dev host "
                "that owns the git server can remove the pre-receive hook, which is "
                "the only enforcement point a client cannot bypass. Either move the "
                "git role or disable L4 and accept the weaker guarantee explicitly."
            )
        if git.get("type") == "github":
            warnings.append(
                "roles.git.type=github: github.com does not run pre-receive hooks. "
                "L4 degrades to branch protection plus a CI approximation, which is "
                "client-bypassable. See docs/layers.md, L4 · known limits."
            )

    # ── reviewer role ──
    if layers.get("l3"):
        provider = reviewer.get("provider")
        if provider not in REVIEWER_PROVIDERS:
            errors.append(
                f"roles.reviewer.provider: {provider!r} not in {list(REVIEWER_PROVIDERS)}"
            )
        if provider != "offline" and not reviewer.get("addr"):
            errors.append("roles.reviewer.addr: missing (required unless provider=offline)")
        if not reviewer.get("model"):
            errors.append("roles.reviewer.model: missing")

        # Separation 3 · load-bearing, and the one that was originally wrong.
        author_model = (dev.get("author_model") or "").strip().lower()
        review_model = str(reviewer.get("model") or "").strip().lower()
        if author_model and review_model:
            if _same_model_family(author_model, review_model):
                errors.append(
                    f"SEPARATION VIOLATED · reviewer model {reviewer.get('model')!r} shares "
                    f"a family with the author model {dev.get('author_model')!r}. A review "
                    "by the same weights is a self-check with correlated blind spots. "
                    "Pick a different family."
                )
        elif not author_model:
            warnings.append(
                "roles.dev.author_model: not declared — the reviewer/author model "
                "separation cannot be checked, only asserted."
            )
        if provider == "offline":
            warnings.append(
                "roles.reviewer.provider=offline: the reviewer returns a canned verdict. "
                "The gate mechanics are real; the review is not. Suitable for "
                "acceptance runs, not for production review."
            )

    # ── targets role ──
    if layers.get("l5"):
        if not isinstance(targets, list) or not targets:
            errors.append("roles.targets: expected a non-empty list")
        else:
            for i, entry in enumerate(targets):
                entry = _as_mapping(entry, f"roles.targets[{i}]", errors)
                if not entry.get("addr"):
                    errors.append(f"roles.targets[{i}].addr: missing")
                # Separation 2 · load-bearing
                if entry.get("addr") and entry.get("addr") == dev_addr:
                    errors.append(
                        f"SEPARATION VIOLATED · roles.targets[{i}].addr == roles.dev.addr "
                        "— the deploy target is the dev host, so the writing hand reaches "
                        "production directly and the deployment boundary is decorative."
                    )

    if provisioner not in PROVISIONERS:
        errors.append(
            f"roles.provisioner: {provisioner!r} not in {list(PROVISIONERS)}"
        )

    sink = roles.get("sink")
    if isinstance(sink, dict) and sink.get("addr") == dev_addr and dev_addr:
        warnings.append(
            "roles.sink.addr == roles.dev.addr: the audit sink lives on the host it "
            "audits. Not load-bearing, but a host that can rewrite its own audit trail "
            "gives you a log, not evidence."
        )

    return errors, warnings


_FAMILY_HINTS = (
    "qwen", "llama", "mistral", "gemma", "phi", "granite", "deepseek",
    "codestral", "starcoder", "claude", "gpt", "yi", "command-r", "olmo",
)


def _same_model_family(a: str, b: str) -> bool:
    """Family match, not string equality — 'qwen3-coder' and 'qwen2.5' collide."""
    if a == b:
        return True
    fam_a = {hint for hint in _FAMILY_HINTS if hint in a}
    fam_b = {hint for hint in _FAMILY_HINTS if hint in b}
    if fam_a and fam_b:
        return bool(fam_a & fam_b)
    # Neither name is recognisable: fall back to the leading token.
    return a.split(":")[0].split("-")[0] == b.split(":")[0].split("-")[0]


# ── CLI ────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(description="inventory.yaml accessor")
    parser.add_argument("--inventory", default=None)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--get", metavar="DOTTED")
    parser.add_argument("--layers", action="store_true")
    parser.add_argument("--layer-enabled", metavar="LAYER")
    args = parser.parse_args()

    try:
        data = load(args.inventory)
    except (InventoryError, miniyaml.MiniYAMLError) as exc:
        print(f"[inventory] {exc}", file=sys.stderr)
        return 2

    if args.get:
        value = get(args.get, data)
        if value is None:
            return 1
        print(value if not isinstance(value, (list, dict)) else miniyaml.dumps(value))
        return 0

    if args.layers:
        print(" ".join(enabled_layers(data)))
        return 0

    if args.layer_enabled:
        return 0 if layer_enabled(args.layer_enabled, data) else 1

    if args.validate:
        errors, warnings = validate(data)
        for warning in warnings:
            print(f"[inventory] WARN  {warning}")
        for error in errors:
            print(f"[inventory] ERROR {error}", file=sys.stderr)
        if errors:
            print(f"\n[inventory] {len(errors)} error(s) — inventory rejected",
                  file=sys.stderr)
            return 1
        print(f"[inventory] ok · roles assigned · layers: "
              f"{' '.join(enabled_layers(data)) or '(none beyond l0)'}")
        return 0

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
