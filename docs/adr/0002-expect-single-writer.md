# ADR-0002: Shared-directory expect submission is out of contract (v0); the format does not foreclose it

- Status: **Accepted** (deferred feature, explicit non-contract; format audited)
- Date: 2026-07-21
- Deciders: maintainer adjudication of the Phase 2 cross-model review
  (2 independent reviewers, both GO; both required this non-contract to be
  written down before publication)
- Related: `docs/requirements-v0.md` items 4–5, `docs/design-history.md` (2026-07-21 Phase 2 assessment)

## Context

`sitter expect` / `sitter ack` / `sitter sweep` implement a reply deadman:
expectations and acknowledgements are appended to the same JSONL ledger and
the externally scheduled sweep replays it to drive the
`pending → nudge → nudge → awaiting_human` state machine.

Today all expect-family rows are written by one operator on one machine.
A foreseeable future is other agents (or other machines, e.g. via a synced
shared directory) registering expectations against the same deadman. Before
publishing the repo we audited whether the current append-only, single-writer
format would structurally lock that future out.

## Decision

1. **Non-contract, stated loudly:** submitting expectations from other users,
   other machines, or shared/synced directories is **not supported in v0**.
   The supported writers of expect-family rows are the `sitter expect` /
   `sitter ack` / `sitter sweep` verbs running as the same user that owns the
   sweep. Anything else is undefined behavior today — not a stable interface
   to build on.
2. **No redesign now.** The feature is deferred until a concrete consumer
   exists (per the Phase 2 adjudication). We change nothing in v0.1.0.

## Format audit: does single-writer-today foreclose a second writer tomorrow?

**Verdict: no.** The append-only replay design is already the multi-writer-
friendly shape; what is missing is contract, not format. Findings:

- **Appends are already lock-serialized.** Every ledger append stages the row
  privately and appends under `flock` (Linux) or `lockf` (BSD/macOS) on
  `<ledger>.lock`, with a lock-directory fallback when neither tool exists —
  no third-party dependency involved. Interleaved appends from a second
  process would not tear or reorder rows in a way replay cares about.
- **Replay is order-tolerant and cursor-free.** Sweep replays the whole
  ledger, scoped per `expect_id`, with no watermark. Late or interleaved rows
  from another writer degrade to at-most-one extra nudge (the same bound the
  design already accepts for sweep/ack races); nothing is lost or duplicated.
- **Row shape is order-independent for readers.** Replay matches on
  `"schema":"sitter.v0"` + `"expect_id":` and extracts named keys; it does
  not depend on a writer's key order.
- **Two writer-side duties are currently informal.** These become the writer
  contract if a second writer is ever admitted:
  - *Sanitization is the writer's job.* Replay's extraction assumes the
    compact JSON subset that `sitter expect` enforces (id matching
    `^[A-Za-z0-9._-]{1,64}$`; quotes, backslashes, and control characters
    stripped from `to`/`text`; 140-byte text cap). A writer emitting raw
    values would produce rows replay misreads or skips.
  - *Duplicate-registration guard is check-then-append.* `sitter expect`
    checks "id already active?" by reading the ledger, then appends under the
    lock — adequate for one writer, racy for two concurrent registrations of
    the same id. A multi-writer future must move that check under the append
    lock (or accept last-generation-wins, which replay already handles by
    treating a new `expect` row as a new generation).
- **Quarantine state is sweeper-local, and that is correct.** Poison-row and
  hook-failure counters live in the sweeping user's `$SITTER_HOME`, not in
  the ledger. Multiple sweepers over one ledger remain out of scope
  regardless of writer count; one sweep owner per ledger stays the rule.
- **Shared-directory ledgers get only the documented v0 hardening** (private
  staging copy under the lock, refusal of a ledger path that is itself a
  symlink, per-row format validation) — they are treated as trusted private
  directories, not hostile input, and receive no full TOCTOU hardening (as
  the README states). That boundary predates this audit and is unchanged.

## Consequences

- README states the non-contract; external users should not script other
  writers against the ledger and expect stability.
- When a concrete second-writer need arrives, the work is: write down the
  writer contract above, move the duplicate-id check under the append lock,
  and decide the sweep-ownership story — no schema or replay redesign is
  expected.
