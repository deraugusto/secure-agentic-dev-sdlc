---
id: ADR-0001
title: "ADR-0001: Hello-world service as the lifecycle proof"
type: adr
status: accepted
implementation: deployed
date: 2026-08-20
author: baseline
tags: [adr, example, lifecycle-proof]
---

# ADR-0001: Hello-world service as the lifecycle proof

## Context

A security baseline that only documents its own machinery cannot be checked. A
reader has no way to tell an apparatus that works from one that merely
type-checks, and neither does the person who wrote it six months later.

So the repository carries one real service and drives it through the entire
lifecycle: a decision is recorded here, code is written for it, the input
sanitizer sees the working copy, the output gate assembles and reviews the
changeset, a token is issued and bound to the commit, the server-side hook
evaluates the push, the deploy script verifies and smoke-tests the result, and
the ledger records what happened. Every layer gets exercised by the same change.

The service itself must therefore be uninteresting. Anything the example does
beyond existing is surface area that distracts from the thing being
demonstrated, and dependencies would put a package registry between a stranger
and their first green run.

## Decision

The lifecycle proof is a single-file Node.js HTTP service at
`example/hello-world-node/server.js` with **no dependencies at all** — the Node
standard library only, `package.json` carrying no `dependencies` key.

It exposes exactly two routes:

| Route | Response |
|---|---|
| `GET /healthz` | `200` · `{"status":"ok","service":"hello-world","version":"<v>"}` |
| `GET /` | `200` · `Hello from the agentic SDLC baseline.` plus the version |

The listen port comes from `PORT`, defaulting to `3000`. The bind address comes
from `HOST`, defaulting to `127.0.0.1`. The deploy target's real address lives
in `inventory.yaml` and nowhere else.

`/healthz` is the smoke contract. The deploy sequence treats a non-200 or a
missing `status: ok` as a failed deploy and rolls back to the pre-deploy
snapshot.

### What this is not

- Not an application template. Copying this to start a project is a mistake;
  it exists to be pushed through a pipeline, not to be extended.
- Not a demonstration of Node.js practice. There is no router, no logging
  framework, no configuration layer, and that is the point.
- Not a claim that the pipeline understands JavaScript. Every layer here is
  language-agnostic; the example could be any language that can answer an HTTP
  request. Node was chosen because it is present on most developer machines and
  needs no build step.

## Consequences

### Accepted

- The example proves the *pipeline*, not the *service*. A green acceptance run
  says the lifecycle holds together. It says nothing about whether your own
  application is well built.
- Zero dependencies means the example never exercises the case that matters
  most in practice — a changeset that pulls in third-party code. That gap is
  real. It is left to the reviewer layer's `network-egress` and
  `trust-boundary-crossing` disciplines rather than being simulated here.
- Node.js becomes a soft prerequisite for the full acceptance run. Layers L0
  through L4 verify without it; only the L5 deploy proof needs a runtime.

### Rejected alternatives

- **A static file instead of a service.** Rejected: nothing to smoke-test. A
  deploy whose success criterion is "the file is on disk" cannot demonstrate
  rollback, which is the interesting half of L5.
- **A Python service, matching the rest of the repository.** Rejected on
  purpose. Every other runnable thing here is Python; making the example a
  different language keeps the pipeline honest about being language-agnostic
  and stops language-specific assumptions from creeping into the stages.
- **An Express service.** Rejected: it would put `npm install` between a
  stranger and their first green run, and a supply-chain fetch in the example
  contradicts the offline-first constraint the rest of the baseline holds.

## Acceptance

Run from the repository root.

| Probe | Command | Expected |
|---|---|---|
| POS-1 | `./layers/l0-governance/adr-lint.sh docs/adr` | exit 0, this ADR passes |
| POS-2 | `./example/hello-world-node/smoke.sh` | exit 0, `/healthz` returns `status: ok` |
| POS-3 | `./layers/l5-deploy-audit/deploy.sh --target hello-world --local` | exit 0, service live, ledger entry appended |
| NEG-1 | `SDLC_BREAK_SMOKE=1 ./layers/l5-deploy-audit/deploy.sh --target hello-world --local` | non-zero exit, rollback to the pre-deploy snapshot, ledger records `rolled-back` |
| NEG-2 | `node example/hello-world-node/server.js` then `curl -s localhost:3000/nope -o /dev/null -w '%{http_code}'` | `404` — the service answers only its two declared routes |

The full run, including every layer's negative probe, is
`./tools/run-acceptance.sh`.
