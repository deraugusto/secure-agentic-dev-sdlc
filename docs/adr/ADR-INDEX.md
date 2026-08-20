# ADR Index

Every architecture decision record in this repository, newest identifier last.
`adr-lint` fails an ADR that is not listed here, so this file cannot drift
silently out of sync.

| ID | Title | Status | Implementation | Last change |
|---|---|---|---|---|
| [ADR-0001](ADR-0001-hello-world-service.md) | Hello-world service as the lifecycle proof | accepted | deployed | 2026-08-20 |
| [ADR-0002](ADR-0002-role-model.md) | Six roles, three load-bearing separations | accepted | deployed | 2026-08-20 |
| [ADR-0003](ADR-0003-bootstrap-and-profiles.md) | A questionnaire, three profiles, and a declared gap | accepted | deployed | 2026-08-20 |

## Numbering

`ADR-NNNN`, four digits, allocated in order, never reused. The filename is
`ADR-NNNN-<slug>.md` and the `id:` field must match the number in the filename.

## Status lifecycle

| Status | Meaning |
|---|---|
| `proposed` | Written down, not decided |
| `accepted` | Decided and binding |
| `accepted-with-gaps` | Decided, with named parts knowingly unbuilt |
| `superseded` | Replaced; `superseded-by:` names the successor |
| `rejected` | Considered and declined — kept, because the reasoning is the value |

`status` and `implementation` are orthogonal. An `accepted` decision with
`implementation: pending` is a normal and honest state; conflating the two is
how a repository ends up claiming things that are not running.

## Amendment protocol

Accepted ADRs are append-only. A change appends

```
## Amendment YYYY-MM-DD · <one-line summary>
```

and sets `last-updated:` to that date. `adr-lint` enforces the coupling between
the two. Editing an accepted decision in place is the failure this protocol
exists to prevent: it erases the reasoning that produced the current state,
which is the only part of an ADR that has long-term value.
