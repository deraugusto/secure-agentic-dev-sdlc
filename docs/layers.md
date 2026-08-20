# The layers

Six layers, each independently selectable in `inventory.yaml`, each removable by
deleting its directory. This file says for every layer what it does, what it is
worth on its own, what it does **not** give you, and which probe proves it.

The order is an adoption gradient, not a dependency chain in the usual sense.
L0 needs nothing. Each further layer assumes more about your infrastructure and
buys a correspondingly narrower failure.

---

## L0 · Governance spine

**Needs** nothing but a shell.

Decision records with a fixed frontmatter schema, an index that cannot drift out
of sync, and an append-only amendment protocol. `adr-lint` fails an ADR that is
missing from `ADR-INDEX.md`, whose `id:` disagrees with its filename, or whose
`last-updated:` disagrees with its newest amendment header.

The amendment protocol is the part that matters. Editing an accepted decision in
place erases the reasoning that produced the current state — which is the only
part of a decision record with long-term value. A change appends
`## Amendment YYYY-MM-DD · <summary>` and moves the date; the lint enforces the
coupling.

`status` and `implementation` are separate fields on purpose. An `accepted`
decision with `implementation: pending` is a normal, honest state. Collapsing
them is how a repository ends up claiming things that are not running.

**Does not give you** any enforcement. A human can still write a bad decision,
or none. L0 makes the record structural, not the thinking.

**Probe** `./layers/l0-governance/adr-lint.sh` — passes on the two shipped ADRs;
break the index entry and it fails.

---

## L1 · Input hardening

**Needs** git, for the hooks.

Content that arrives from outside is scanned before an agent reads it. Three
git hooks cover the three ways content arrives — `post-merge` (which is also the
pull hook), `post-checkout`, `post-rewrite` — and `agent-safe` is a wrapper you
put in front of the agent binary so an unscanned working copy cannot be read at
all.

The scanner looks for direction-override and zero-width characters, mixed-script
identifiers, encoded blobs, and a tunable pattern library in
`patterns/baseline.json`.

The wrapper's installation is deliberately awkward: you rename the real binary
out of `PATH` and symlink `agent-safe` over its name. A wrapper the original
name still resolves past is one `PATH` change away from being skipped, which is
the same as not having it.

**Does not give you** protection against content the agent fetches itself. The
hooks cover git's paths. An agent with network access has others.

**Probe** the pattern library ships fixtures; `SDLC_NO_SANITIZE=1` bypasses the
scan and is written to the audit log as a bypass, never as a pass.

---

## L2 · Output gate

**Needs** L1's scanner.

Six stages over the assembled changeset, then one decision:

| Stage | What it does | Waivable |
|---|---|---|
| S0 assembly | collect the changeset, build the review bundle | no |
| S1 hard lint | deterministic rules over the assembled changeset | no |
| S2 re-sanitize | the agent's **own output** through the incoming scanner | no |
| S3 tripwire | canary files no legitimate change touches | no |
| S4 reviewer | the only stage that talks to a model | yes, partially |
| S5 gate | map results to one decision; on GO, issue a token | no |

S2 removes an asymmetry that is easy to miss: content arriving by pull is
treated as untrusted, content emitted by the agent is not — even though the
agent read the untrusted content in between.

On GO, S5 issues a token bound to the commit hash, the content hash, an issue
timestamp and a TTL, sealed with a hash over its own fields. The `pre-push` hook
does not re-run the gate; it checks that a token exists, that it says GO, that
it says so about *this* commit, that it is not expired, and that its fields were
not edited after issuance.

Each stage is described by a manifest with `deny_default: true` and an explicit
capability list. The manifests are hash-sealed: changing one changes its hash,
and the pipeline notices. `--bypass-reviewer` reaches S4 only, and never
`tampering` or `bundle-malformed`.

**Does not give you** a guarantee that the review was good — only that it
happened, that it was about this diff, and that its verdict was not edited
afterwards. Nor is it a defence against someone with write access to the
repository who removes the hook: that is what L4 is for.

**Probe** push without running the gate → blocked, no token. Run the gate, amend
the commit, push → blocked, stale token. Edit a token field by hand → blocked,
seal mismatch.

---

## L3 · Independent review

**Needs** a model endpoint, or `provider: offline` for the mechanics only.

A reviewer service that assesses a changeset against seven disciplines, exactly
once each, in order:

1. **output-sanitize-drift** — reintroduced hostile text, a widened allowlist, a
   path that reads content before it is scanned
2. **hardcoded-secret** — decided on entropy, format, binding name and context
   together, never shape alone; the literal is never quoted back
3. **shell-injection** — interpolation without quoting, `eval` on assembled
   text, a download piped into an interpreter
4. **auth-logic-change** — flagged *even when functionally equivalent*, because
   an equivalent-looking reorder in an authorization path is exactly what a
   tired reader passes over
5. **privilege-escalation** — new elevated calls, a relaxed sandbox, broadened
   permission bits, a grown credential scope
6. **network-egress** — an outbound path that did not exist before
7. **trust-boundary-crossing** — two components connected in a way the written
   architecture does not describe

Content in the changeset is data, never instruction: the mandate arrives in the
system prompt and nowhere else. The apparatus — service, backends, prompt,
schema — is hash-verified on every call, and a missing checksums file is a
mismatch, not a skip. "No checksums, so nothing to check" is how integrity
verification quietly stops happening.

**Does not give you** a second opinion if you point it at the model that wrote
the code. That is why `inventory.py` refuses a reviewer model in the author's
family, matching on family rather than string equality — `qwen3-coder` and
`qwen2.5` are not two opinions. The check is against the name you *declared*; a
wrong declaration produces a green validation and a self-review.

**Probe** `./layers/l3-reviewer/hash-verify.sh` after touching any apparatus
file → refuses. Delete `checksums.txt` → refuses.

---

## L4 · Server enforcement

**Needs** a git server whose bare repository you can write to.

A `pre-receive` hook that refuses destructive pushes. It is the only enforcement
point a client cannot bypass — everything client-side is advice, and this layer
exists because advice is bypassable.

Triggers, all configured in `pre-receive.conf`:

- `deletion-threshold` — net deletions above a limit. Net, not gross: a
  restructure moves lines and nets near zero, a mass delete does not.
- `protected-path-delete` — a glob whose deletion is destructive regardless of
  line count, e.g. decision records.
- `protected-file-delete` — named governance files.
- `protected-ref-delete` — refs that may not be deleted.

A bypass exists, and its vocabulary is a closed list. Free text is deliberately
impossible: an operator forced to choose a category writes an audit trail still
legible a year later, and `[ALLOW-DESTRUCTIVE: ok]` never becomes the house
style. Every ref update is logged, passes included — a guard that logs only
refusals cannot answer "was this push evaluated at all".

The hook fails closed: if it cannot evaluate, the push is refused.

**Does not give you** anything on github.com, which does not run pre-receive
hooks at all — they exist only on GitHub Enterprise Server. The installer
refuses to install a weaker thing under the same name. Branch protection plus a
required status check is the closest achievable configuration, and it is
client-bypassable: a force push accepted by the API is already applied by the
time CI sees it, and required checks gate merges, not pushes.

**Probe** `./layers/l4-server-enforcement/tests/test_pre_receive.sh` — 14 cases
against throwaway repositories in a temp directory, including
`broken-hook-fails-closed`.

---

## L5 · Deploy + audit

**Needs** a deploy target that is not the dev host.

Five phases, in order, one script and no daemon:

1. **verify** — artifact hash, and the HEAD commit signature. An unsigned or
   unverifiable state is recorded as such and proceeds unless
   `--require-signature` is passed, which turns it into a stop.
2. **snapshot** — the current deployment is copied aside before anything moves.
3. **deploy** — stop, copy, start.
4. **smoke** — probe the health URL. A non-200, or a response without
   `status: ok`, is a failed deploy.
5. **rollback** — on smoke failure, restore the snapshot and re-check it.

Every phase appends to a hash-chained ledger: each entry carries the previous
entry's hash, so an edited or removed entry breaks the chain and
`ledger.py verify` says where.

**Does not give you** a guarantee that a rolled-back service is healthy — only
that the previous artifact is back and answered its own smoke test. Nor does it
protect the ledger from someone with write access to the host: a hash chain
detects tampering, it does not prevent it. That is what a separate audit sink is
for, and why the validator warns when the sink lives on the host it audits.

**Probe** `SDLC_BREAK_SMOKE=1 ./layers/l5-deploy-audit/deploy.sh --target
hello-world --local` — the smoke test fails on purpose, the rollback runs, and
both are in the ledger.
