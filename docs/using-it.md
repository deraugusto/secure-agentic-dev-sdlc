# Using it with your own agent

The bootstrap installs the machinery. This describes the loop you actually work
in afterwards — where your agent goes, what runs when, and what to do when
something refuses.

Read [layers.md](layers.md) for what each layer is worth; this file is about the
day.

---

## The loop, in one picture

```
  you edit / your agent edits
            │
            ▼
  git pull ──► L1 scans what arrived        (automatic, git hooks)
            │
            ▼
  agent-safe <your agent>                   (L1 scans, then execs the agent)
            │
            ▼
  git commit ──► L0 checks the message      (automatic, commit-msg hook)
            │
            ▼
  pipeline.py ──► S0…S5, GO token           (YOU RUN THIS)
            │
            ▼
  git push ──► pre-push spends the token    (automatic)
            │
            ▼
  server ──► L4 evaluates the push          (automatic, on the git server)
```

Everything marked automatic was installed by the bootstrap. The one manual step
is the gate, and that is deliberate: it talks to a model, it takes as long as
your model takes, and a hook that silently blocks a push for ninety seconds is a
hook people uninstall.

---

## 1 · Put your agent behind the wrapper

`agent-safe` scans the working copy and refuses to start the agent if the scan
rejects, so untrusted content is caught before anything reads it. It passes
every argument through, so it is invisible in use.

```sh
export SDLC_AGENT_BIN=/usr/local/bin/your-agent-real
/path/to/repo/layers/l1-input-hardening/agent-safe --whatever-flags-you-use
```

Typing that every time defeats the purpose. The intended installation renames
the real binary out of `PATH` and puts the wrapper under its name:

```sh
sudo mv "$(command -v your-agent)" /usr/local/bin/your-agent-real
sudo ln -s /path/to/repo/layers/l1-input-hardening/agent-safe /usr/local/bin/your-agent
echo 'export SDLC_AGENT_BIN=/usr/local/bin/your-agent-real' >> ~/.profile
```

Renaming matters. If the original name still resolves anywhere in `PATH`, the
wrapper is one shell alias away from being skipped, which is the same as not
having it.

The wrapper also unsets provider credentials it was not asked to pass on —
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and friends — so that a key belonging to
one provider does not travel into another provider's request. Override with
`SDLC_AGENT_UNSET` if your agent needs one of them.

**What this does not do:** it scans the working copy at invocation time. An
agent that fetches a web page an hour into a session has read something L1 never
saw. L1 covers the paths git controls.

---

### Installing the wrapper without doing it by hand

```sh
./layers/l1-input-hardening/install-wrapper.sh --agent your-agent --dry-run
./layers/l1-input-hardening/install-wrapper.sh --agent your-agent
./layers/l1-input-hardening/install-wrapper.sh --status
./layers/l1-input-hardening/install-wrapper.sh --agent your-agent --uninstall
```

It works on an agent you already have installed — it looks the binary up on
`PATH`, renames it to `<name>-real`, and puts a symlink to `agent-safe` under the
original name. It refuses if the target is already wrapped, if the `-real` name
is taken, or if the directory is not writable, and it verifies the result rather
than assuming it. The only thing it does not do is edit your shell profile; it
prints the `export SDLC_AGENT_BIN=…` line and leaves the decision to you.

For a fleet, pass the list instead of repeating yourself:

```sh
./layers/l1-input-hardening/install-wrapper.sh --agent claude --agent aider
./layers/l1-input-hardening/install-wrapper.sh --from-file ~/agents.txt --dry-run
./layers/l1-input-hardening/install-wrapper.sh --from-file ~/agents.txt
```

`--from-file` takes one name or path per line and ignores blanks and `#`
comments, so the list can come straight out of whatever inventory you already
keep. Each agent is installed independently: one failure does not abandon the
rest half-done, and the run ends with `N of M agents done` and a non-zero exit
if any failed. `--status` lists everything currently wrapped.

## Scaling to more than one project

**One installation of the baseline serves every project.** The wrapper resolves
its scanner next to itself, not next to the code being scanned — so the baseline
can live once at, say, `/opt/agentic-sdlc-baseline`, and every repository on the
machine is scanned by that one copy. Nothing has to be vendored into your
projects.

```sh
sudo git clone <baseline-url> /opt/agentic-sdlc-baseline
sudo /opt/agentic-sdlc-baseline/layers/l1-input-hardening/install-wrapper.sh --agent your-agent
```

What scales how:

| | Cost of adding one more |
|---|---|
| **another agent** | one `install-wrapper.sh` run |
| **another project** | one `bootstrap/init.sh` run in that repo — it installs the hooks; the layer code stays where it is |
| **another developer** | they bootstrap their own clone; L4 is central and already covers them |
| **another repository on the git server** | install the pre-receive hook there once |
| **throughput** | this is the real limit — see below |

### What it costs, measured

Everything except the review is negligible, and it is worth having the numbers
rather than an impression:

| Step | Cost | Notes |
|---|---|---|
| L1 full scan | **0.28 s** cold, **0.09 s** warm | 74 files; a 5-minute cache means repeated agent invocations mostly hit it |
| L2 stages S0–S3, S5 | **0.04 s** | deterministic, no network |
| L2 stage S4 · the review | **104 s** median | qwen3:8b over Ollama, and it serialises |

So the scanner and the gate disappear into the noise even at a hundred agents.
The review does not.

### A hundred agents

One reviewer at 104 seconds handles about **276 reviews per eight-hour day**,
serialised. Against that:

| Fleet | Reviews/day | Model time | Reviewers needed |
|---|---|---|---|
| 10 agents × 5 pushes | 50 | 1.4 h | 0.2 |
| 50 agents × 5 pushes | 250 | 7.2 h | 0.9 |
| 100 agents × 5 pushes | 500 | 14.4 h | **1.8** |
| 100 agents × 20 pushes | 2000 | 57.8 h | **7.2** |

The number that matters is **pushes**, not agents. The gate runs per push, so a
hundred agents that push twice a day are cheaper than five that push forty
times.

Two honest consequences at that size:

- **You need reviewer capacity, and this repository does not provide it.** The
  gate reads one endpoint from `inventory.yaml`. Several model hosts means a
  load balancer in front of them, which is infrastructure you run, not code you
  get here. That is a real gap for a fleet, and it is named rather than papered
  over.
- **Wrapper installation is per machine, not per agent.** A hundred agents on
  four build hosts is four `--from-file` runs under whatever configuration
  management you already use, not a hundred manual steps.

What does **not** need to scale: L4 is one hook per repository on the git server
and is indifferent to how many agents push through it. L0 has no runtime at all.
L5 runs per deploy, not per push.

If that becomes the constraint, in the order that costs least:

1. **A smaller or quantised model.** Review quality degrades gracefully; the
   strict output contract does not, so watch for a rise in `model-error`.
2. **A second reviewer instance** against a second model host. The gate reads
   one endpoint from `inventory.yaml`, so this means a load balancer in front
   rather than a change to the pipeline.
3. **Batching by convention.** The gate runs per push, not per commit. A team
   that pushes once per feature rather than once per commit pays the reviewer
   once.

What does **not** help is running the gate less often. A token is bound to one
commit and one content hash precisely so that it cannot be spread across a day's
work.

## 2 · Keep the reviewer running

L2 stage S4 calls the reviewer service over HTTP. If it is not listening, the
gate fails closed — `UNREACHABLE`, `NO-GO`, no token. That is correct behaviour
and also the most common reason for a refusal that confuses people, so run the
service as a service rather than in a terminal you will close.

```sh
python3 layers/l3-reviewer/reviewer_service.py --serve
```

It reads its configuration from the environment first and from `inventory.yaml`
otherwise, so on a bootstrapped repository it usually needs no arguments.

A systemd unit is included at
[`layers/l3-reviewer/reviewer.service.example`](../layers/l3-reviewer/reviewer.service.example).
Copy it, set the two paths, and:

```sh
sudo cp layers/l3-reviewer/reviewer.service.example /etc/systemd/system/sdlc-reviewer.service
sudo systemctl daemon-reload
sudo systemctl enable --now sdlc-reviewer
systemctl status sdlc-reviewer
```

**Declare your author model.** `roles.dev.author_model` in `inventory.yaml` is
what the reviewer/author separation is checked against. It is declared, not
detected — the validator compares the name you wrote against the reviewer's, and
a wrong declaration produces a green check and a self-review. If you switch the
model that writes your code, change this too.

---

## 3 · Commit as usual

The `commit-msg` hook runs `commit-lint` on every commit. The convention is
`<type>(<scope>): <summary>`, lowercase, imperative, no trailing period, 72
characters:

```
script(l2): add the token TTL check
```

Types: `adr` `index` `doc` `script` `config` `example` `meta`.

An agent-produced commit may carry a final `Auto-Class:` trailer naming what
kind of change it is. Two classes — `secrets-handling` and `out-of-scope` — are
refused outright, on the principle that an agent should leave those in the
working tree and ask.

---

## 4 · Run the gate, then push

```sh
python3 layers/l2-output-gate/pipeline.py
git push
```

The gate assembles the changeset, applies the deterministic lint, re-scans the
agent's own output, checks the tripwires, asks the reviewer, and on GO issues a
token bound to this commit and this content with a fifteen-minute TTL. The
`pre-push` hook does not re-run any of it; it checks that a token exists, says
GO, names this commit, has not expired, and was not edited.

Practical consequences:

- **Amend a commit and the token is dead.** It was minted for a different hash.
  Re-run the gate.
- **The TTL is short on purpose.** A token generated in a quiet moment cannot be
  spent later against different code.
- **`--bypass-reviewer` defers S4 and nothing else.** It cannot reach the hard
  lint, the re-scan or the tripwires, and it is recorded.

---

## 5 · When something refuses

The refusals are the product. Reading them correctly is the difference between
fixing a problem and reaching for the bypass.

| What you see | What it means | What to do |
|---|---|---|
| `[sanitize] REJECT` | incoming content carries something hostile | look at the file it names; it is quoting a real finding |
| `S1-HARDLINT FAIL` | a deterministic rule, not waivable | fix it; there is no flag |
| `S4 UNREACHABLE` | the reviewer is not answering | start the service; check `systemctl status sdlc-reviewer` |
| `verdict=model-error` | the model answered unusably | on a small model this is sometimes just a bad run — re-run once before investigating |
| `[L2] BLOCKED: stale token` | the gate passed a different commit | re-run the gate |
| `[L2] BLOCKED: token expired` | older than its TTL | re-run the gate |
| `pre-receive: refused` | the push destroys something protected | read the named trigger; if it is genuinely intended, use the bypass vocabulary |
| `smoke: FAILED` | the deploy did not come up healthy | it already rolled back; the ledger has both events |

The distinction that matters most is between `model-error` and a finding. The
first is the machinery having a bad day. The second is the machinery working.
`reason` in the audit log tells you which, and treating them the same is how a
team learns to bypass on reflex.

---

## 6 · Deploying

```sh
./layers/l5-deploy-audit/deploy.sh --target <name> --local
```

The target must be declared under `roles.targets` in `inventory.yaml`; deploying
a name nobody declared would put a fiction in the audit trail, so it is refused.
`--dry-run` prints the plan. `--require-signature` turns an unsigned HEAD from a
recorded fact into a stop.

Verify the trail at any time:

```sh
python3 layers/l5-deploy-audit/ledger.py verify
```

---

## What you have to decide for yourself

- **Which model reviews.** It must not share a family with the one writing your
  code. A small local model is enough and keeps source code inside the building.
- **Where the tripwires go.** L3 ships the mechanism and one example canary. A
  canary is worth exactly what its obscurity is worth, so place your own and do
  not commit their locations to a public branch.
- **What counts as destructive.** `pre-receive.conf` carries a deletion
  threshold and protected paths. The defaults fit a repository where decision
  records are append-only; tune them to your rhythm, because a threshold that
  fires on ordinary work makes the bypass routine, which is the failure mode this
  layer is most exposed to.
