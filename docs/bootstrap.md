# Bootstrap

```sh
./bootstrap/init.sh --dry-run     # the complete plan, nothing touched
./bootstrap/init.sh               # questionnaire, confirmation, apply
./bootstrap/init.sh --help
```

The bootstrap assigns the six roles to your machines, writes `inventory.yaml`,
installs the hooks for the layers you enabled, and seals the hashes. It does not
know your topology and does not guess at it: an unanswered question with no
sensible default is a stop, not a default.

## The one guarantee about `--dry-run`

Every filesystem mutation in `init.sh` goes through a single function, `act`.
`--dry-run` is that function printing instead of executing. There is no second
code path that "also does a bit of work", which is the usual reason a dry run
turns out to have been incomplete. `bootstrap/tests/test_bootstrap.sh` hashes
the whole tree before and after a dry run and fails if a single byte moved —
including the `.pyc` files Python would otherwise leave behind.

## Options

| Flag | Effect |
|---|---|
| `--profile <name>` | `existing-infra` (default), `single-host`, `proxmox-full` |
| `--dry-run` | print the plan, change nothing |
| `--answers <file>` | pre-fill answers; anything unanswered is still asked |
| `--non-interactive` | never prompt; an unanswered question with no default is fatal |
| `--force` | rewrite `inventory.yaml` even if it matches the answers |

An answers file is plain `KEY=value` shell, sourced before the questionnaire.
`bootstrap/tests/acceptance.answers` is the one the acceptance run uses; every
value in it is a placeholder.

## What it asks, and what it skips

Questions are asked only for layers that are on. Nobody should have to invent a
git server address to use the governance spine, and asking anyway is how a
layered baseline stops being layered.

- **dev** — address, and the model that writes your code. The author model is
  *declared*, not detected, and it is what the reviewer/author separation is
  checked against.
- **git** — only if L4 is on. Type, address, ssh user, bare repository path,
  port.
- **reviewer** — only if L3 is on. `offline` skips the endpoint questions and
  ships a canned verdict.
- **targets** — only if L5 is on. Name, address, deploy user, path, smoke URL.
- **provisioner and sink** — always.

## The confirmation gate

Before anything is written, the run prints the full role assignment, the enabled
layers, the state of each of the three separations, and the profile's statement
of what it does **not** deliver. Then it asks.

That gate exists because the failure it prevents is expensive and quiet: a
mistyped node identifier in a provisioning profile creates containers on
infrastructure that is not yours, and nothing about the run looks wrong until
somebody else finds them. `--non-interactive` implies the confirmation, which is
why it is appropriate for tests and for a machine you already own, and not for
the first run against a cluster.

Refusing at the gate exits without changing anything.

## Profiles, and what each one declines to promise

Every profile prints its own gap statement during the run. Shipping a weaker
variant under the same name is how a baseline becomes a false sense of security:
the recipient believes they have the property the documentation describes.

### `existing-infra` — the default

Provisions nothing. Installs hooks, writes configs, seals hashes.

Not delivered: the reviewer model is yours to run; the git server's hook
directory needs ssh access the bootstrap does not assume it has; and host
separation is verified against what the inventory *claims*, never against
reality.

### `single-host`

Everything on one box except git. Two of the three separations survive, and the
difference is worth being precise about:

- **git ≠ dev survives** — git stays remote, so the server-side hook remains
  outside a compromised dev host's reach.
- **reviewer ≠ author survives** — it is a property of weights, not hardware.
- **targets ≠ dev does not survive** if you deploy to the same machine. That is
  why L5 defaults to **off** in this profile. Turn it on and point it at
  localhost and the validator refuses — deliberately, and no flag overrides it.

### `proxmox-full`

The reference topology: a container per role, firewalled. Offered as one profile
among three, not as the recommendation — the security properties live in the
three separations, not in the hypervisor.

It is the only profile that creates infrastructure, so it is the only one that
can create it in the wrong place. `bootstrap/provision/proxmox/` is the only
hypervisor-coupled directory in the repository; deleting it removes proxmox
support and breaks nothing else, which is the test of whether the coupling is
really isolated. It reads a `provision:` block from `inventory.yaml` and refuses
to run without one rather than picking a plausible node name, and it refuses to
run anywhere but on the hypervisor itself — a provisioning path that silently
reaches across a network is one that can reach the wrong network.

## Idempotence

A second run reports what is already in place and changes only what drifted. An
`inventory.yaml` that matches the answers is left untouched, including its
mtime. Hooks are compared byte for byte before being replaced.

A `.git/hooks/` file the baseline did not write is never overwritten. The run
warns and leaves it, because the alternative is destroying somebody's existing
deployment hook on a tool's first run.

## What it deliberately does not do

- **It does not install the pre-receive hook for you.** L4 lives on the git
  server, and this bootstrap does not assume it may write there. It prints the
  two commands and stops.
- **It does not pull a model.** The model pull is the one egress in the whole
  baseline and it is confirmed separately, in the profile that provisions.
- **It does not commit anything.** Sealing hashes changes files; what happens to
  those changes is yours to decide.

## After it finishes

The summary prints the acceptance sequence in order. Run it — particularly the
last step, where the smoke test fails on purpose and the deploy has to roll
back. A layer nobody has watched refuse anything is a layer nobody knows works.

## Files

```
bootstrap/init.sh                   the run
bootstrap/lib/common.sh             output, prompting, the act() seam
bootstrap/lib/questionnaire.sh      the questions and the role table
bootstrap/lib/render_inventory.py   answers → inventory.yaml, validated first
bootstrap/profiles/*.profile        defaults plus the gap statement
bootstrap/provision/proxmox/        the only hypervisor-coupled directory
bootstrap/tests/test_bootstrap.sh   24 probes, most of them refusals
```
