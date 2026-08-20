---
id: ADR-0003
title: "ADR-0003: A questionnaire, three profiles, and a declared gap"
type: adr
status: accepted
implementation: deployed
date: 2026-08-20
author: baseline
tags: [adr, bootstrap, adoption, profiles]
---

# ADR-0003: A questionnaire, three profiles, and a declared gap

## Context

The layers were built before there was any way to install them. That order was
right — mechanics first, adoption second — but it left the recipient of this
repository with a set of scripts, six roles, and no path from a fresh clone to a
working configuration.

The obvious answer is a configuration file to copy and edit. It is also the
wrong one. An example configuration is filled in by pattern-matching: the reader
replaces the parts that look like addresses and leaves everything else at its
example value. What survives that process is the *shape* of the example, not a
decision about their own infrastructure — and two of the three separations this
baseline rests on are exactly the kind of thing nobody notices they have
collapsed. `targets: localhost` looks fine in a file. It means the hand that
writes the code reaches production directly.

The second problem is weaker variants. A recipient without a spare host, or
without a model, or on github.com, cannot have everything the documentation
describes. If the bootstrap quietly gives them a reduced version under the same
name, they believe they have a property they do not have — which is worse than
having nothing, because they will stop looking.

## Decision

**A questionnaire, not a template.** `./bootstrap/init.sh` asks, then writes
`inventory.yaml`. It asks only about layers that are enabled, and it refuses to
guess: an unanswered question with no sensible default stops the run rather than
picking something plausible. `--answers` pre-fills for automation, and
`--non-interactive` makes an unanswered question fatal instead of prompting.

**One mutation seam.** Every filesystem change goes through `act()`. `--dry-run`
is that function printing instead of executing. There is deliberately no second
code path, so the plan cannot describe something the run does not do; the probe
suite hashes the whole tree across a dry run and fails on a single changed byte,
including Python's bytecode cache.

**A confirmation gate before anything is created.** The run prints the complete
role assignment, the enabled layers, and the state of each of the three
separations, and then asks. The failure this prevents is quiet and expensive: a
mistyped node identifier creates containers on infrastructure that is not yours,
and nothing about the run looks wrong until somebody else finds them.

**Three profiles, each with a written gap statement.** `existing-infra`
(default, provisions nothing), `single-host`, `proxmox-full`. Every profile
prints, during the run, which guarantee it does *not* deliver. `single-host`
ships with L5 disabled, because on one machine the deploy target would be the
dev host — the profile declines the guarantee rather than appearing to offer it.

**The hypervisor stays in one directory.** `bootstrap/provision/proxmox/` is the
only place that knows what a container is. Deleting it removes proxmox support
and breaks nothing else, which is the test of whether the coupling is really
isolated rather than merely tidy.

**The bootstrap does not write to your git server, and does not pull a model.**
L4 prints two commands and stops. The model pull is the one egress in the whole
baseline and is confirmed separately. Both are cases where "helpful" and
"reaching into infrastructure it was not clearly invited into" are the same
action.

## Consequences

The first run is longer than copying a file, and that is the intended trade: the
questions are the part that does not survive being skipped.

Anything the questionnaire cannot check remains unchecked and is said out loud
rather than implied. The bootstrap validates what `inventory.yaml` *claims*; it
cannot confirm that two addresses are two machines, and it cannot confirm that
the declared author model is the one actually writing the code. Both are stated
in the profile gap statements, because a validation that is silent about its own
blind spots reads as broader than it is.

Adding a profile means writing a gap statement. That is a deliberate cost: a
profile that cannot name what it gives up has not been thought through.

`bootstrap/tests/test_bootstrap.sh` covers this decision with 24 cases, most of
them refusals — every collapsed separation, every unanswered question, dry-run
purity, idempotence, and the refusal to overwrite a git hook the baseline did
not write.
