---
id: ADR-0002
title: "ADR-0002: Six roles, three load-bearing separations"
type: adr
status: accepted
implementation: deployed
date: 2026-08-20
author: baseline
tags: [adr, architecture, roles, threat-model]
---

# ADR-0002: Six roles, three load-bearing separations

## Context

The system this baseline was extracted from runs on a specific topology:
several containers on one hypervisor, each with a fixed address, a firewall
between them, and a set of habits that grew around that arrangement. None of
that is transferable. A recipient has different hardware, a different git
server, and possibly one laptop.

Copying the topology would produce a baseline nobody can adopt. Dropping the
separations entirely would produce a baseline that documents a pipeline and
guarantees nothing. What has to transfer is the part that carries the security
property, and only that part.

Distinguishing the two required looking at each separation and asking what an
attacker gains when it collapses. Most of them turned out to be preference. Three
did not.

## Decision

The baseline defines **six roles**: `dev`, `git`, `reviewer`, `targets`,
`provisioner`, `sink`. Roles are assigned to hosts in `inventory.yaml`, which is
the only file in the repository permitted to contain an address. Roles may
co-locate freely except where a separation below forbids it.

**Three separations are load-bearing.** `lib/inventory.py --validate` refuses an
inventory that violates them, and the bootstrap will not proceed past a refusal.

| Separation | What collapses without it |
|---|---|
| `git` ≠ `dev` | The server-side pre-receive hook is the one control a client cannot bypass. If the dev host owns the git server, a compromised agent removes the hook and then pushes whatever it wants. The control becomes a suggestion. |
| `targets` ≠ `dev` | The deployment boundary is what stops agent-written code from reaching a running service without passing the gate. If the target is the dev host, the writing hand is already inside the boundary and the gate protects a copy. |
| reviewer model ≠ author model | Two instances of the same weights share failure modes by construction. The review reads as a second opinion and behaves as a self-check. This one was originally violated in the source system and found by inspection, not by a probe — which is itself the argument for encoding it. |

**Everything else is preference and is explicitly not required:** a dedicated
host for the reviewer, a separate audit sink, a hypervisor, container isolation,
a particular firewall product, or any specific address plan. A single machine
running `dev`, `reviewer`, `sink` and `provisioner` together is a supported
configuration. It declares fewer guarantees, and the bootstrap protocol says so
in writing.

### What this is not

- Not a claim that the non-load-bearing separations are worthless. A reviewer on
  its own host has a smaller blast radius. It is a claim that the *gate's*
  properties do not depend on it.
- Not a network policy. The baseline does not ship firewall rules. Where a
  profile provisions them (`proxmox-full`), they live isolated under
  `bootstrap/provision/` and are optional.
- Not a role-based access control model. These are deployment roles, not
  identities or permissions.

## Consequences

### Accepted

- The `reviewer model ≠ author model` check is a heuristic on model names. It
  catches `qwen3-coder` reviewing `qwen2.5-coder`; it cannot catch a renamed
  fine-tune of the same base. Declared, not solved.
- Because `inventory.yaml` holds every address, a leak of that one file leaks
  the whole topology. This concentrates rather than reduces the exposure, and it
  is the right trade: one git-ignored file is auditable, addresses scattered
  across forty scripts are not.
- Co-location being permitted means a stranger's first run is likely weaker than
  the reference. The bootstrap protocol prints exactly which guarantees a chosen
  profile does *not* deliver, so the weakening is visible rather than silent.

### Rejected alternatives

- **Ship the reference topology as the requirement.** Rejected: it makes the
  baseline un-adoptable by anyone without the same hardware, and it publishes
  the source system's layout, which the sanitization rules forbid outright.
- **Drop all separations, ship the mechanics only.** Rejected: the pipeline's
  guarantees are not properties of the code, they are properties of the code
  running in a particular arrangement. Mechanics without the arrangement is a
  demo.
- **Enforce all six roles on distinct hosts.** Rejected: three of the six
  separations buy blast-radius reduction, not gate integrity, and requiring them
  would push adopters toward faking the inventory — the worst outcome, because
  the file would then assert a separation that does not exist.

## Acceptance

| Probe | Command | Expected |
|---|---|---|
| POS-1 | `python3 lib/inventory.py --validate --inventory inventory.example.yaml` | exit 0 |
| NEG-1 | inventory with `roles.git.addr == roles.dev.addr`, L4 enabled | exit 1, `SEPARATION VIOLATED` naming the git/dev collapse |
| NEG-2 | inventory with `roles.targets[0].addr == roles.dev.addr`, L5 enabled | exit 1, `SEPARATION VIOLATED` naming the target/dev collapse |
| NEG-3 | `author_model: qwen3-coder` and `reviewer.model: qwen2.5-coder` | exit 1, `SEPARATION VIOLATED` naming the shared model family |

Covered by `layers/l0-governance/tests/test_inventory_separations.sh`.
