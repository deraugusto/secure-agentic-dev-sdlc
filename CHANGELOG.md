# Changelog

Versions are `0.x` on purpose. Two things have to be true before this claims a
`1.0`, and neither is yet: the pre-receive guard has never been installed on a
running git server, and the output gate is enforced by a client-side hook that
anything with write access to `.git/hooks` can remove.

## v0.3.0 — 2026-08-20

The layers were complete before this release. What it adds is the part that
decides whether somebody else can use them.

### Added

- **Bootstrap** — a questionnaire rather than a config file to copy, three
  profiles, and a `--dry-run` that is the same code path printed instead of
  executed. Each profile states during the run which guarantee it does *not*
  deliver.
- **`docs/using-it.md`** — the loop you work in after installation: the wrapper
  seam, keeping the reviewer up, when the gate runs, and a table of every
  refusal with what it means and what to do about it.
- **`install-wrapper.sh`** — puts an already-installed agent behind the scanner
  in one command, with `--from-file` for a fleet, plus `--status`, `--dry-run`
  and `--uninstall`.
- **Architecture diagrams** and a header banner, in mermaid and SVG so they stay
  diffable.
- **Apache-2.0** licence and a NOTICE that states the limits of its own
  attribution.
- **`tools/leak-sweep.py`** — refuses to let the repository leave carrying an
  address, hostname, container id, key or token. Exceptions need a written
  reason.
- **113 probes** across all six layers plus the bootstrap, most of them
  asserting a refusal.

### Fixed

Every one of these was found by running the thing rather than reading it.

- **Homoglyph detection missed its own headline case.** The threshold was a
  ratio, but the classic substitution is *one* character — a single Cyrillic
  'a' in a six-letter identifier scored 0.17 against a 0.34 threshold. Any
  minority script in an identifier now counts.
- **The reviewer's prompt asked the model to count lines.** File content was
  presented unnumbered while the output contract demanded exact line ranges, so
  a substantively correct review from a real model was discarded over an
  off-by-two. Found on the first run against qwen3:8b.
- **The wrapper resolved its scanner inside the tree being scanned**, which
  meant one copy of the baseline per project — and, briefly, a version that
  scanned the baseline instead of the target and reported it clean.
- **The L4 installer would have overwritten a forge's own pre-receive hook.**
  Gitea and GitLab generate one there for branch protection, push options and
  LFS; replacing it removes those silently. It now installs into
  `pre-receive.d` beside it, and refuses rather than guessing.
- **`install-wrapper.sh` would have wrapped a system binary.** `--agent bash`
  with sudo would have renamed the shell needed to undo it. Refused now.
- **`deploy.sh` accepted any target name**, putting a fiction into the audit
  trail. It checks the inventory, and honours `SDLC_INVENTORY` the way every
  other layer does.
- **macOS could not run the integrity checks at all** — no `sha256sum`. All
  four call sites fall back to `shasum -a 256`, producing byte-identical seals.
- **Publishing bypassed the gate.** The GitHub publication path pushes from a
  clone, a clone carries no hooks, so `pre-push` never ran. It runs the hook
  itself now.

### Known limits

- The gate is enforced client-side; L4 does not require a GO token. Teaching it
  to would move the gate from advisory to enforced, for local and cloud-hosted
  agents alike. This is the single highest-value next change.
- The pre-receive hook has never run on a live forge — only against throwaway
  bare repositories.
- Remote deploy prints a plan and stops.
- Verified on Linux with Python 3.11 and bash 5. Python 3.8 and bash 3.2 are
  supported by construction and checked statically, not executed.
- A cloud-hosted agent loses L1 entirely and L2's enforcement. L0, L3, L4 and
  L5 are unaffected.
