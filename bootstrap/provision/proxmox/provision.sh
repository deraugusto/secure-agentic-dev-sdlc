#!/usr/bin/env bash
# Proxmox provisioning — the reference topology, isolated behind one directory.
#
#   ./provision.sh --plan     print what would be created, touch nothing
#   ./provision.sh --apply    create it
#
# This is the only hypervisor-coupled code in the repository, and it lives here
# so that the rest stays host-agnostic. Nothing outside this directory knows
# what a container is. Deleting this directory removes proxmox support and
# breaks nothing else -- which is the test of whether the coupling is really
# isolated.
#
# Every identifier comes from inventory.yaml. There is no address, node name or
# container id in this file, and there must never be one: this repository is
# meant to be handed to someone whose infrastructure is not yours.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
INV="python3 $REPO_ROOT/lib/inventory.py"

MODE=""
case "${1:-}" in
  --plan)  MODE=plan ;;
  --apply) MODE=apply ;;
  *) echo "usage: provision.sh --plan | --apply" >&2; exit 2 ;;
esac

say() { printf '[proxmox] %s\n' "$*"; }

# ── the provisioning block is optional, and its absence is not a default ───
#
# Guessing a node name is how containers end up on someone else's cluster. If
# the block is missing the answer is to write it, not for this script to pick
# something plausible.
NODE="$($INV --get provision.node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  cat >&2 <<'TXT'
[proxmox] inventory.yaml has no `provision:` block, so there is nothing to
          provision against. This script will not guess a node name.

          Add a block like this and re-run:

            provision:
              node: <hypervisor node name>
              bridge: <network bridge>
              template: <lxc template reference>
              storage: <storage id>
              gateway: <gateway address>
              containers:
                - role: reviewer
                  ctid: <numeric id>
                  cores: 4
                  memory: 8192
                  disk: 32

          Every value is yours and none of them have a sensible default.
TXT
  exit 2
fi

BRIDGE="$($INV --get provision.bridge 2>/dev/null || echo "")"
TEMPLATE="$($INV --get provision.template 2>/dev/null || echo "")"
STORAGE="$($INV --get provision.storage 2>/dev/null || echo "")"
GATEWAY="$($INV --get provision.gateway 2>/dev/null || echo "")"

for pair in "bridge:$BRIDGE" "template:$TEMPLATE" "storage:$STORAGE"; do
  if [ -z "${pair#*:}" ]; then
    echo "[proxmox] provision.${pair%%:*} is missing from inventory.yaml" >&2
    exit 2
  fi
done

say "node=$NODE bridge=$BRIDGE storage=$STORAGE"

if [ "$MODE" = "apply" ] && ! command -v pct >/dev/null 2>&1; then
  cat >&2 <<'TXT'
[proxmox] `pct` not found. This script has to run ON the hypervisor; it does
          not shell out to one over the network, because a provisioning path
          that silently reaches across a network is a provisioning path that
          can reach the wrong network.

          Stopping here rather than building half a topology.
TXT
  exit 2
fi

# ── containers ─────────────────────────────────────────────────────────────
CONTAINERS="$($INV --get provision.containers 2>/dev/null || echo "")"
if [ -z "$CONTAINERS" ]; then
  echo "[proxmox] provision.containers is empty — nothing to create." >&2
  exit 2
fi

SDLC_REPO_ROOT="$REPO_ROOT" python3 - "$MODE" "$NODE" "$BRIDGE" "$TEMPLATE" "$STORAGE" "$GATEWAY" <<'PYEOF'
import os
import subprocess
import sys
from pathlib import Path

mode, node, bridge, template, storage, gateway = sys.argv[1:7]
sys.path.insert(0, str(Path(os.environ["SDLC_REPO_ROOT"]) / "lib"))
import inventory  # noqa: E402

data = inventory.load()
provision = data.get("provision") or {}
containers = provision.get("containers") or []
roles = data.get("roles") or {}


def addr_for(role: str) -> str:
    entry = roles.get(role)
    if isinstance(entry, dict):
        return str(entry.get("addr", ""))
    if isinstance(entry, list) and entry:
        first = entry[0]
        if isinstance(first, dict):
            return str(first.get("addr", ""))
    return ""


def run(argv: list[str]) -> None:
    if mode == "plan":
        print("  would run: " + " ".join(argv))
        return
    subprocess.run(argv, check=True)


for entry in containers:
    if not isinstance(entry, dict):
        print(f"[proxmox] containers entry is not a mapping: {entry!r}", file=sys.stderr)
        raise SystemExit(2)
    role = str(entry.get("role", ""))
    ctid = str(entry.get("ctid", ""))
    if not role or not ctid:
        print(f"[proxmox] container needs both role and ctid: {entry!r}", file=sys.stderr)
        raise SystemExit(2)
    addr = addr_for(role)
    if not addr:
        print(f"[proxmox] role {role!r} has no address in roles — refusing to "
              "invent one", file=sys.stderr)
        raise SystemExit(2)

    net = f"name=eth0,bridge={bridge},ip={addr}/24"
    if gateway:
        net += f",gw={gateway}"

    print(f"[proxmox] container {ctid} · role={role} · {addr}")
    run([
        "pct", "create", ctid, template,
        "--hostname", f"sdlc-{role}",
        "--cores", str(entry.get("cores", 2)),
        "--memory", str(entry.get("memory", 2048)),
        "--rootfs", f"{storage}:{entry.get('disk', 16)}",
        "--net0", net,
        "--unprivileged", "1",
        "--onboot", "1",
    ])

    # Default-deny egress, then the paths this baseline actually uses. A
    # container that can reach everything is not a separated role; it is a
    # role with extra steps.
    run(["pct", "set", ctid, "--firewall", "1"])
    print(f"[proxmox]   firewall: default-deny out, allowlist for role={role}")

print(f"[proxmox] {len(containers)} container(s) {'planned' if mode == 'plan' else 'created'}")
PYEOF
