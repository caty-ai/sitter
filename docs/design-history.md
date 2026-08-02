# Design History

sitter's requirements and major design changes were decided through a series of
structured review rounds: independent blind proposals from multiple models,
anonymous cross-review, and a single integration ruling adjudicated by the
maintainer. This document preserves the durable outcome of each round. The raw
round transcripts (proposals, reviews, evidence packs) were internal working
material and are not part of the public tree; see the note at the end.

Rounds in chronological order:

1. [2026-07-20 — v0 requirements round](#2026-07-20--v0-requirements-round)
2. [2026-07-21 — Phase 2 assessment](#2026-07-21--phase-2-assessment)
3. [2026-07-21 — Windows root-cause audit + core audit](#2026-07-21--windows-root-cause-audit--core-audit)
4. [2026-07-23 — v0.2 ask/watch design round](#2026-07-23--v02-askwatch-design-round)

## 2026-07-20 — v0 requirements round

**Question.** Given a frozen scope (two verbs: `run` and `expect`/`ack` with an
externally scheduled `sweep`; five structural safety devices; zero
dependencies; exactly two integration points, `--ledger` and `--on-fail`),
decide the seven open requirements: ledger schema, stall-detection default,
restart/idempotency boundary, sweeper launch mechanism, notification channel,
naming, and test strategy.

**Process.** Four independent blind proposals (each model saw only the brief),
then four anonymous cross-reviews of the anonymized A–D set, then one
integration ruling. The full ruling is frozen as
[`requirements-v0.md`](./requirements-v0.md), which remains the v0 contract.

**Rulings (summary — `requirements-v0.md` is authoritative):**

- **Ledger schema**: a strict compatible superset of the operator's
  pre-existing run-ledger JSONL (inherited keys `ts`, `event`, `status`,
  `project`, `agent`, `task`, `attempt`, `detail`, ...; additive snake_case
  keys `schema:"sitter.v0"`, `event_id`, `run_id`, `exit_code`, expect-side
  keys). `detail`/`cmd` truncated to 512 bytes with `detail_truncated:true`;
  full argv and prompt text are never written to the ledger.
- **Stall default**: single default `--stall-after 900` (the empirically
  measured 15-minute pattern that caught both observed silent-death and
  alive-but-frozen worker failures). `--stall-after 0` disables mtime
  detection but then `--timeout` becomes mandatory — startup is refused with
  both disabled. Worker profiles live in the README as recommended flag
  bundles, never in code. A proposed generic `--probe` flag was rejected
  (later made permanent — see [ADR-0001](./adr/0001-no-probe-flag.md)).
- **Restart boundary**: default is non-idempotent, one attempt, notify-only.
  Restart requires a double gate: explicit `--idempotent NAME` declaration AND
  exact byte-match of the full wrapped command against an `--allowlist` file
  (no glob/regex — pattern matching was rejected as an injection surface).
  A hardcoded, non-bypassable denylist refuses to wrap push/deploy/publish/
  billing-class commands at all, judged on the argv token sequence to avoid
  false positives on prompt text. Retry budget and cooldown persist across
  invocations via a command-hash key.
- **Sweeper**: external scheduler only (launchd primary, cron mirror), single
  pass `sweep --once`, non-blocking flock with lock-directory fallback, pid
  files banned. Expect state is event-sourced replay of the single append-only
  ledger — no watermark cursor (late/out-of-order delivery on synced
  directories must not drop events), no rewrite-in-place, poison rows
  quarantined after 3 failures. `ack` is an absorbing state within an expect
  generation.
- **Notification**: one generic hook, `--on-fail`, made **mandatory** — the
  supervisor refuses to start without it, so "silently giving up" is
  structurally impossible even by omission. Payload is truncated on the
  sitter side (env vars + one JSON line on stdin); prompt/command/log bodies
  are never passed.
- **Naming**: `sitter`, decided by the maintainer from a collision-checked
  candidate table (the working name collided with existing research repos).
- **Tests**: no test framework — plain bash asserts, an env-driven stateful
  fake worker (`ok|slow|silent_death|hang|partial|flaky` modes), spy-file
  hooks, shrunken timers; no live workers or network in CI.

## 2026-07-21 — Phase 2 assessment

**Question.** Disposition of the three items `requirements-v0.md` had deferred
to "Phase 2": a generic `--probe` flag, LLM-based classification of ambiguous
exits, and expect submission via shared directories.

**Process.** Maintainer-side assessment memo, then cross-model review by two
independent reviewers. Both returned GO (agree / agree-with-conditions on all
three items). Net code change to sitter itself: zero — the v0.1.0 freeze held.

**Rulings:**

- **`--probe`: permanent won't-do.** The motivating non-streaming worker had
  gained a liveness probe in its own wrapper layer, which is the correct
  layer for worker-specific health knowledge; the residual need for a
  sitter-side probe went to zero. Condition attached by both reviewers: the
  rejection is only safe to publish together with a documented escape hatch —
  hence [ADR-0001](./adr/0001-no-probe-flag.md) and the generic
  `examples/probe-wrapper.sh` template.
- **Ambiguous-exit classification: direction accepted, placed outside core.**
  The ambiguous case is real ("exit 0 but did nothing" was observed in
  production on day one), but classification belongs in an operator-side
  post-gate wrapper, never in sitter core — the zero-dependency and
  two-contact-point freezes stay intact. Conditions adopted from review:
  start passive measurement immediately (exit code + log bytes recorded to a
  sidecar) so the later cutoff decision is data-driven rather than a
  guess; any future classifier must fail toward alerting, never silently
  swallow; a dated review checkpoint with a named owner.
- **Shared-directory expect submission: deferred, with the non-contract
  written down.** Both reviewers required an explicit statement that other
  writers of expect rows are unsupported in v0, plus a format audit proving
  the append-only single-writer design does not foreclose a second writer
  later. That audit and statement became
  [ADR-0002](./adr/0002-expect-single-writer.md).

## 2026-07-21 — Windows root-cause audit + core audit

**Question.** Why did the test suite fail on Git Bash / MSYS (12 canonical
failures), and — run in parallel as a general audit — what correctness,
concurrency, security, and coverage defects exist in the frozen v0.1.0 body?

**Process.** A measured evidence pack first: a per-primitive probe matrix and
full-suite runs captured in CI on `windows-latest`, every claim cited to a
file:line in the raw captures, inference explicitly labeled. Then five
independent single-blind proposals (five lanes, distinct models, one assigned
lens each: correctness, concurrency/signals, security, test coverage,
edge-cases/portability), four anonymous cross-reviews, and an integration
ruling.

**Ruling (verdict was unanimous across all five proposals and four reviews):**

- **Root cause: one missing tool, not process semantics.** `shasum` is absent
  on Git Bash, so command hashing died under `set -euo pipefail` with rc=127
  before the first ledger event (measured: 0-byte ledgers, xtrace). This one
  cause explained 11 of the 12 canonical failures; the 12th was test-side
  (the test's lock holder invoked `flock`/`lockf` directly, both absent on
  MSYS). `sha256sum` was measured present on the same runner and is a
  drop-in.
- **Fix shape: additive in-core tool detection** (`detect_hash_tool`, probing
  `shasum -a 256` then `sha256sum`, verified against a known answer, failing
  closed if neither) — the same detection idiom the script already used for
  stat, locking, and clocks. Digests and ledger bytes stay byte-identical on
  macOS/Linux because `shasum` still probes first; the new branch executes
  only where v0.1.0 crashed. Since `shasum` is a perl wrapper, this also
  hardened perl-less minimal Linux — a portability fix, not a Windows
  accommodation.
- **Second authorized fix: octal-argument normalization.** Zero-padded
  numeric options (`--timeout 08`) passed validation then exploded as octal
  in arithmetic, deterministically killing the supervisor mid-supervision
  with the child orphaned (independently repro-verified by two reviewers).
  The existing `10#` normalization idiom was applied to all numeric options.
- **Core-audit findings filed, not fixed.** The cross-reviews confirmed ten
  defect families in the frozen body (grandchild processes surviving
  `kill_group`, stall baseline not reset across restarts, event_id collision
  on same-second events, kill switch unobserved during cooldown sleeps,
  stale-lock stealing, cross-invocation budget semantics, and more). Per
  unanimous reviewer recommendation these were filed as individual issues,
  each requiring its own ruling — scope-creep protection for the freeze. One
  reported finding was refuted with measurement (hook stdin tempfile perms:
  mktemp creates 0600) and recorded to prevent resurfacing.
- **Outcome**: the two fixes shipped as v0.1.1; the full suite — including
  the process-supervision core — went green on `windows-latest`
  (Git Bash / MSYS2) in CI, 23/23 at the time (the canonical suite has since
  grown well beyond that count). Git Bash is documented as experimental,
  with WSL the primary supported Windows path.

## 2026-07-23 — v0.2 ask/watch design round

**Question.** Design `sitter ask` (register an expectation and run the exact
external send command as one atomic operation) and `sitter watch --once`
(detect a reply by observing a reply file, auto-`ack` on change) without
breaking the v0 freeze: no transport knowledge, no daemon loops, no third
contact point, `sweep` stays the only SLA engine.

**Process.** Five independent blind proposals (five lanes, distinct models),
anonymized cross-review, integration ruling. One reviewer seat returned no
usable review after its permitted retry and was recorded as unavailable
(4 of 5 reviews); same-lineage reviews of a lane's own proposal were counted
as reference-only, never as independent approval.

**Ruling: CONDITIONAL GO on a trimmed non-active prepare lifecycle.**

```text
validate/baseline
  -> ask_prepare (durable, non-active)
  -> exact external send argv
     -> expect/pending (active; SLA begins) on exit 0
     -> ask_send_failed (terminal, non-active) on nonzero
```

- Registering an **active** expectation before the send succeeds was rejected
  (the SLA could nudge a request that was never sent); send-first with no
  durable baseline was rejected as the inverse failure. The durable
  non-active prepare row survives a crash mid-send without starting the SLA.
- `watch --once` observes only active generations and appends the same
  absorbing ack row as manual `ack`. It gained no lock, no loop, no hooks —
  `sweep --once` remains the only nudge/awaiting-human caller.
- Adoption of an already-sent request requires an explicit `--already-sent`
  flag; omitting both the flag and `-- SEND argv` is a usage error (exit 2),
  so an expectation can never be created silently for an unsent request.
- Schema: new rows use `schema:"sitter.v1"` and add exactly three reply
  fields (`reply_file`, `reply_bytes`, `reply_sha256`); v0 transition rows
  are unchanged, and deterministic mixed-ledger (v1 start + v0 transitions)
  fixtures were made a release gate. Full send argv and reply contents are
  never stored (redaction rule: argv may contain secrets).
- Reply detection is one stable size+SHA-256 observation of the reply file;
  same-size rewrites are detected by hash; truncation does **not** ack
  (more likely rotation/conflict than reply); symlinked reply files are
  followed (content, not inode, defines a reply).
- The round closed CONDITIONAL: implementation was gated on real operational
  evidence of a full lifecycle. The gate was satisfied the same day by a
  recorded `registered -> reply detected -> auto-ack` lifecycle from live
  operation.

## Where the source material lives

The raw round records — blind proposals, anonymous cross-reviews, evidence
packs with raw probe/suite captures, and per-round model mappings — were
internal working documents. They have been removed from the public tree and
are preserved in a private archive. The durable outcomes are all public: the
frozen v0 contract in [`requirements-v0.md`](./requirements-v0.md), the
standing decisions in [`docs/adr/`](./adr/), and this history.
