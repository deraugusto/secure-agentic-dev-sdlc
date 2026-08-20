# agentic-sdlc-baseline

A complete lifecycle for code written by an agent: a decision is recorded, code
is written for it, the input scanner sees the working copy, an output gate
assembles and reviews the changeset, a token is bound to the commit, the git
server evaluates the push, the deploy verifies and smoke-tests the result, and
an append-only ledger records what happened.

Every layer is optional except the first. Every layer ships at least one probe
that proves it refuses what it claims to refuse, because a baseline that only
demonstrates the happy path teaches the wrong half.

> **If you are reading this on GitHub, one layer of this baseline is not
> available to you here.** L4 is a `pre-receive` hook, and github.com does not
> run pre-receive hooks — they exist only on GitHub Enterprise Server. On
> github.com the destructive-push guard degrades to branch protection plus a CI
> approximation, which is client-bypassable in ways the hook is not: a force
> push accepted by the API is already applied by the time CI sees it, and
> required checks gate merges rather than pushes. The installer refuses to
> pretend otherwise; see [Known limits](#known-limits). This repository's own
> home is a self-hosted forge for exactly that reason, and the GitHub copy is a
> published mirror.

## What this is not

It is not a framework, and there is nothing to import. It is not a CI template.
It does not assume your topology: the only file allowed to name a machine is
`inventory.yaml`, which the bootstrap writes from a questionnaire and which is
git-ignored, so nothing about your network is in what you clone or what you
share back.

It also does not claim that any of this makes an agent safe to run unattended.
What it does is make a specific set of failures loud: content that arrives
poisoned, output that carries something it should not, a review that never
happened, a push that destroys history, a deploy that broke and stayed broken.

## Sixty seconds, no infrastructure

The governance spine needs nothing but a shell:

```sh
./layers/l0-governance/adr-lint.sh
```

That checks every decision record against the schema, the index, and the
append-only amendment protocol. If you only want the workflow, you are done —
clone it and go.

## The full bootstrap

```sh
./bootstrap/init.sh --dry-run     # the complete plan, nothing touched
./bootstrap/init.sh               # questionnaire, then apply
```

The questionnaire asks only about layers you enabled, shows the full role
assignment, and makes you confirm it before anything is created. A dry run
prints the same steps the real run executes — the same code path, printed
instead of run, so the plan cannot drift away from the behaviour.

Profiles: `existing-infra` (default, provisions nothing), `single-host`,
`proxmox-full`. Each one states in the run which guarantee it does **not**
deliver. See [docs/bootstrap.md](docs/bootstrap.md).

## The layers

| | Layer | Needs | Refuses |
|---|---|---|---|
| L0 | Governance spine | nothing | an ADR that drifts from the index, an accepted decision edited in place |
| L1 | Input hardening | git | content that fails the scan, before an agent reads it |
| L2 | Output gate | L1 | a push without a valid GO token for exactly this commit |
| L3 | Independent review | a model | a review by the author's own weights; a tampered apparatus |
| L4 | Server enforcement | a git server you control | a push that deletes history or protected paths |
| L5 | Deploy + audit | a deploy target | a deploy whose smoke test fails — it rolls back |

Details, guarantees and the negative probe for each: [docs/layers.md](docs/layers.md).

## The three separations that carry the security property

Everything else in the topology is preference. These three are not:

- **git ≠ dev** — otherwise a compromised dev host removes the server-side hook
  that is supposed to constrain it.
- **targets ≠ dev** — otherwise the hand that writes code reaches the running
  service directly, and the deployment boundary is decorative.
- **reviewer model ≠ author model** — otherwise the review is a self-check with
  the author's own blind spots. This one is about weights, not hosts: a reviewer
  on the same machine is still a second opinion.

`python3 lib/inventory.py --validate` refuses an inventory that collapses any of
them, and the bootstrap will not proceed past a refusal. The reasoning is in
[ADR-0002](docs/adr/ADR-0002-role-model.md).

## Known limits

- **github.com does not run pre-receive hooks.** They exist only on GitHub
  Enterprise Server. Against github.com, L4 degrades to branch protection plus a
  CI approximation, which is client-bypassable in ways the hook is not: a force
  push accepted by the API is already applied by the time CI sees it. The
  installer refuses to pretend otherwise. See
  [branch-protection.md](layers/l4-server-enforcement/branch-protection.md).
- **`provider: offline` reviews nothing.** It returns a canned verdict so the
  acceptance run works before you have a model. The gate mechanics are real; the
  review is not.
- **The bootstrap cannot verify separation.** It checks what `inventory.yaml`
  claims. Two different addresses may still be one machine.
- **A canary is worth what its obscurity is worth.** L3's tripwire ships a
  mechanism and an example. Place your own.

## Acceptance run

Proves the machinery on a real service, end to end, with no dependencies beyond
Node.js for the example itself:

```sh
./tools/run-probes.sh                                      # 87 cases, all layers
./layers/l5-deploy-audit/deploy.sh --target hello-world --local
SDLC_BREAK_SMOKE=1 ./layers/l5-deploy-audit/deploy.sh --target hello-world --local
python3 layers/l5-deploy-audit/ledger.py verify
```

`run-probes.sh` runs every layer's suite — 87 cases, and most of them assert a
**refusal**: a collapsed separation, a token spent on the wrong commit, an
edited reviewer prompt, a push that deletes decision records, a rewritten
ledger entry. Run one suite alone with `./tools/run-probes.sh l2`.

| Suite | Cases | Asserts |
|---|---|---|
| L0 | 9 | index drift, id mismatch, the amendment coupling |
| L1 | 11 | bidi, zero-width, homoglyphs, an audited bypass, fail-closed patterns |
| L2 | 12 | no token, stale token, edited seal, expired TTL, edited manifest, unreachable reviewer |
| L3 | 10 | edited apparatus, missing seal, the reviewer/author family check |
| L4 | 14 | mass delete, protected paths and refs, a broken hook failing closed |
| L5 | 7 | edited, removed and re-hashed ledger entries; an undeclared target |
| bootstrap | 24 | every collapsed separation, refusal to guess, dry-run purity, idempotence |

The third line of the acceptance run is the one that matters: the smoke test
fails on purpose, the deploy rolls back to the pre-deploy snapshot, and the
ledger records both the failure and the rollback in a hash chain that `verify`
will not accept if anyone edits it afterwards.

## Before you share this

```sh
python3 tools/leak-sweep.py
```

Refuses to leave the repository carrying an address, an internal hostname, a
container id, a key or a token. Findings are either real, in which case they
belong in `inventory.yaml`, or declared with a written reason. There is no
option that lets one pass silently, because "review carefully before sharing" is
exactly the control that degrades under time pressure.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Apache rather than MIT for one reason that matters here: §3 grants patent rights
explicitly. This is infrastructure that organisations wire into their own
release path, and a permissive licence without a patent grant is the kind of
detail that stalls exactly that adoption. The warranty disclaimer is worth
reading rather than skimming, for a repository whose subject is the points at
which security properties stop holding.

No licence headers in source files. The licence covers the work; a header in
every file lengthens every diff and changes nothing legally.

## Repository layout

```
bootstrap/       questionnaire, profiles, the one hypervisor-coupled directory
layers/l0..l5/   one directory per layer, each independently removable
lib/             inventory accessor and a small YAML reader (stdlib only)
docs/            layer reference, bootstrap guide, decision records
example/         the hello-world service the acceptance run drives
tools/           the pre-handover leak sweep
```

Everything is Python standard library or POSIX shell. There is no dependency to
install, because a security baseline that needs a package registry before it can
check anything has a bootstrap problem of its own.
