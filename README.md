![agentic-sdlc-baseline — six layers, each one able to refuse independently](docs/assets/header.svg)

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

## How it fits together

Content enters from the left, code leaves to the right, and every box between
them can say no. The layers are the gates; each one refuses independently, and
none of them trusts that the previous one did its job.

```mermaid
flowchart LR
    subgraph untrusted["untrusted input"]
        PULL["git pull<br/>issues, docs, deps"]
    end

    subgraph dev["dev host"]
        L1["L1 · sanitize<br/>bidi, zero-width,<br/>homoglyphs, patterns"]
        AGENT["coding agent<br/>behind agent-safe"]
        L2["L2 · output gate<br/>S0 assembly → S1 hardlint<br/>S2 re-sanitize → S3 tripwire<br/>S4 review → S5 decision"]
        TOKEN{"GO token<br/>bound to commit<br/>+ content, TTL"}
        PP["pre-push hook<br/>spends the token"]
    end

    subgraph reviewer["reviewer role"]
        L3["L3 · reviewer service<br/>7 disciplines<br/>apparatus hash-verified"]
    end

    subgraph gitsrv["git role · not the dev host"]
        L4["L4 · pre-receive<br/>destructive-push guard<br/>fails closed"]
        REPO[("bare repository")]
    end

    subgraph target["targets role · not the dev host"]
        L5["L5 · deploy<br/>verify → snapshot → deploy<br/>→ smoke → rollback"]
        SVC["running service"]
    end

    LEDGER[("hash-chained<br/>ledger")]

    PULL -->|"post-merge<br/>post-checkout<br/>post-rewrite"| L1
    L1 -->|"pass"| AGENT
    L1 -.->|"reject"| STOP1(["refused"])
    AGENT --> L2
    L2 -->|"bundle"| L3
    L3 -->|"verdict"| L2
    L2 -->|"GO"| TOKEN
    L2 -.->|"NO-GO"| STOP2(["no token issued"])
    TOKEN --> PP
    PP -->|"git push"| L4
    L4 -->|"accept"| REPO
    L4 -.->|"refuse"| STOP3(["push rejected"])
    REPO --> L5
    L5 -->|"smoke ok"| SVC
    L5 -.->|"smoke fails"| ROLL(["rollback to snapshot"])
    L5 --> LEDGER
```

**L0 sits underneath all of it** and needs no infrastructure at all: the decision
records, the schema, the index, the append-only amendment protocol, and the
commit convention. It is the only layer that cannot be switched off, because it
is the one that leaves a trace of *why* the rest looks the way it does.

Three of the boundaries above carry the security property. The rest is
preference:

```mermaid
flowchart TB
    DEV["dev<br/>writes code<br/>author model"]
    GIT["git<br/>evaluates pushes"]
    REV["reviewer<br/>second opinion<br/>different model family"]
    TGT["targets<br/>runs the service"]
    SINK["sink<br/>audit trail"]
    PROV["provisioner<br/>creates hosts"]

    DEV ---|"must differ"| GIT
    DEV ---|"must differ"| TGT
    DEV ---|"weights must differ"| REV
    DEV -.-|"may co-locate"| SINK
    DEV -.-|"may co-locate"| PROV
```

- **git ≠ dev** — a dev host that owns the git server can remove the hook that
  is supposed to constrain it.
- **targets ≠ dev** — otherwise the hand that writes code reaches the running
  service directly.
- **reviewer model ≠ author model** — the same weights reviewing themselves is a
  self-check with correlated blind spots. This one is about the model, not the
  machine: a reviewer on the same host is still a second opinion.

`python3 lib/inventory.py --validate` refuses an inventory that collapses any of
the three, and the bootstrap will not proceed past a refusal. The reasoning —
including which separations turned out *not* to be load-bearing, and why the
reviewer one was originally got wrong — is in
[ADR-0002](docs/adr/ADR-0002-role-model.md).

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

## What you get, what you bring

![What the repository ships versus what you provide](docs/assets/what-you-bring.svg)

| You need | For | Notes |
|---|---|---|
| python3 + POSIX shell | everything | no packages, no virtualenv, no registry |
| git | L1, L2 | both install their guards as git hooks |
| a git server you control | L4 | **not github.com** — it cannot run pre-receive hooks |
| a model endpoint | L3 | ollama or OpenAI-compatible, in a different model family than the one writing your code |
| a deploy target ≠ dev host | L5 | the validator refuses a target pointing at localhost |
| node.js | the example only | nothing in the pipeline itself needs it |

Turn a layer off in `inventory.yaml` and its requirement disappears with it. L0
needs nothing at all, which is why it cannot be switched off.

**About the model.** L3 is the only layer that needs one, and it is the layer
where the requirement is a property rather than a product: the reviewer must not
share a model family with whatever wrote the code, because the same weights
reviewing themselves produce a self-check with correlated blind spots. A small
local model is enough and is the better choice for a second reason — your source
code never has to leave the building to be reviewed. `provider: offline` exists
so the acceptance run works before you have any model at all; it returns a canned
verdict, and the run says so rather than letting a green token imply a review
happened.

## How do we know it works?

Fair question, and the honest answer has two halves.

**What is demonstrated.** Run `./tools/run-probes.sh` and you get 99 cases across
all six layers plus the bootstrap. Most of them assert a *refusal*, which is the
half that matters: a collapsed separation, a token spent on the wrong commit, an
edited reviewer prompt, a push deleting decision records, a rewritten ledger
entry. They build throwaway repositories in a temp directory and touch nothing of
yours. The example service is driven through the full sequence — verify,
snapshot, deploy, smoke — and then through the failure path, where the smoke test
fails on purpose, the rollback restores the snapshot, and both events land in a
hash chain that `ledger.py verify` rejects if anyone edits it afterwards.

The reviewer's HTTP path is exercised too, against a protocol-accurate endpoint
that can be told to misbehave: both wire protocols, plus a 500, a 401, a
timeout, malformed JSON, prose wrapped around the answer, and a review that
covers four of the seven disciplines. Every one of those produces a refusal, and
an unusable review produces a NO-GO with no token — which matters more than the
happy path, because otherwise the easiest way past the gate would be a model
having a bad day.

**What is not.** The probes were written alongside the code they test, so they
prove internal consistency, not correctness against an adversary who did not
write them. Beyond that, three things remain unproven in the field:

- **Your model, on your changesets.** The pipeline has been driven end to end
  against a real local model — `qwen3:8b` over Ollama — which found a planted
  credential, classified it correctly and placed it on the right line, and the
  gate issued a GO. That run also produced the one substantive bug this
  repository has had so far: the prompt presented file content unnumbered while
  the output contract demanded exact line ranges, so a correct review was
  discarded over an off-by-two. Fixed by numbering the lines. What remains
  unknowable in advance is whether *your* model, on *your* code, produces
  reviews worth reading. Budget roughly a minute per review on an 8B model, and
  expect a smaller one to struggle with the strict output contract.
- **The pre-receive hook against a live forge.** Its 14 probes run against
  throwaway bare repositories. Installing it on a running git server is a step
  nobody has taken here yet.
- **Remote deploy.** `--remote` prints a plan and stops. Shipping a script that
  ssh-es into a host it has never seen, using a service manager it cannot know,
  and calls the result a deploy would be worse than shipping nothing.

None of that is hidden in a changelog. It is here, in the README, because a
baseline whose subject is where guarantees stop should be the last thing to
overstate its own.

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
./tools/run-probes.sh                                      # 99 cases, all layers
./layers/l5-deploy-audit/deploy.sh --target hello-world --local
SDLC_BREAK_SMOKE=1 ./layers/l5-deploy-audit/deploy.sh --target hello-world --local
python3 layers/l5-deploy-audit/ledger.py verify
```

`run-probes.sh` runs every layer's suite — 99 cases, and most of them assert a
**refusal**: a collapsed separation, a token spent on the wrong commit, an
edited reviewer prompt, a push that deletes decision records, a rewritten
ledger entry. Run one suite alone with `./tools/run-probes.sh l2`.

| Suite | Cases | Asserts |
|---|---|---|
| L0 | 9 | index drift, id mismatch, the amendment coupling |
| L1 | 11 | bidi, zero-width, homoglyphs, an audited bypass, fail-closed patterns |
| L2 | 14 | no token, stale token, edited seal, expired TTL, edited manifest, a reviewer that is unreachable *and* one that answers with garbage |
| L3 | 10 | edited apparatus, missing seal, the reviewer/author family check |
| L3 backends | 10 | the real HTTP path: both protocols, plus 500, 401, timeout, malformed JSON, half a review |
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
