---
id: ADR-NNNN
title: "ADR-NNNN: <short decision title>"
type: adr
status: proposed
implementation: pending
date: YYYY-MM-DD
author: <name>
tags: [adr, <strand>]
---

# ADR-NNNN: <short decision title>

## Context

What forced a decision. State the constraint, not the solution. If there is a
threat being answered, name it and name what it can actually reach.

## Decision

One paragraph, present tense, stated as a fact about the system.

### What this is not

The boundaries. This section earns its place: an ADR without it gets read as a
mandate for everything adjacent to it.

## Consequences

### Accepted

What gets worse, in exchange. If nothing gets worse, the decision was free and
probably did not need a record.

### Rejected alternatives

Each with the reason it lost. "We did not think of it" is a legitimate entry
and is more useful than a rationalisation invented afterwards.

## Acceptance

How anyone — including a stranger — verifies this is actually true of the
running system. Commands, expected output, and at least one negative probe:
something that must fail, and the way it must fail.

| Probe | Command | Expected |
|---|---|---|
| POS-1 | | |
| NEG-1 | | |

<!--
Amendment protocol · append-only.

An accepted ADR is never edited in place. Corrections and extensions append:

    ## Amendment YYYY-MM-DD · <one-line summary>

and set `last-updated:` in the frontmatter to that same date. adr-lint enforces
the coupling. The point is that the history of a decision stays legible,
including the parts that turned out wrong.
-->
