# ADR-0001: No `--probe` flag — worker health checks belong to worker wrappers

- Status: **Accepted (permanent won't-do)**
- Date: 2026-07-21
- Deciders: maintainer adjudication, backed by two review rounds — the v0
  requirements round (4 independent drafts, anonymized cross-review) that
  first rejected the flag, and the Phase 2 cross-model review (2 independent
  reviewers, both GO) that made the rejection permanent
- Related: `docs/requirements-v0.md` item 2, `docs/design-history.md` (2026-07-21 Phase 2 assessment); see also ADR-0003 (`--heartbeat-file`)

## Context

`sitter run` decides dead-or-alive with three deterministic, worker-agnostic
signals: exit code, log-mtime stall (`--stall-after`), and an absolute
wall-clock cap (`--timeout`). During the v0 design round, one proposal added a
generic `--probe <cmd>` flag: when a stall is suspected, run a caller-supplied
health check first and grant a grace period if the worker answers.

The motivating case was real. Some workers are non-streaming — they produce
zero output bytes until completion — so "slow" and "dead" are indistinguishable
from the outside, and mtime-based stall detection structurally misfires on
them.

## Decision

`--probe` is **permanently rejected**, not deferred. The two-layer split is:

| Layer | Owns | Signals |
| --- | --- | --- |
| worker wrapper (yours) | worker-specific health knowledge | API pings, version checks, partial-output heuristics, retry-with-probe |
| `sitter run` | worker-agnostic boundedness | exit code, log mtime, absolute timeout, retry budget |

Reasons:

1. **Boundary violation.** A probe command encodes worker-specific health
   knowledge ("what does *this* worker look like when it is alive?"). sitter's
   contract is deliberately worker-agnostic — it knows nothing about the
   command it wraps beyond process liveness and log activity. Both v0
   reviewers flagged the probe as a boundary violation; nothing since has
   weakened that.
2. **The need is served one layer down.** The wrapper that launches a
   probe-able worker can run the probe itself — before launch, on failure, or
   on both — with full knowledge of that worker's endpoints and failure modes.
   (This is not probe-on-stall: while a silent worker is still running, the
   bound comes from `--timeout`, not from probing; the wrapper's probe decides
   fail-fast-vs-retry once the worker exits.)
   The wrapper for the non-streaming worker that motivated the proposal
   grew exactly this: a cheap liveness probe on
   failure, fail-fast when the probe dies, one bounded retry when it answers.
   The residual need for a sitter-side probe went to zero.
3. **Non-streaming workers are already bounded without probing.** The honest
   sitter-side answer for a zero-bytes-until-done worker is
   `--stall-after 0 --timeout <cap>`: disable the misfiring signal, keep the
   absolute cap. (sitter refuses to start with both disabled.)
4. **Flag surface is contract.** Every flag added to `sitter run` is a
   permanent compatibility promise. A flag whose correct value requires
   worker-specific knowledge invites misconfiguration (probing the wrong
   thing, and then trusting the answer).

## The supported escape hatch

If your worker can be "alive but silent", write the probe **into the wrapper
you already own** and let sitter supervise the wrapper. See
[`examples/probe-wrapper.sh`](../../examples/probe-wrapper.sh) for a complete,
generic template:

```
sitter run --stall-after 0 --timeout 1500 ... -- ./examples/probe-wrapper.sh <worker args>
```

The wrapper probes, fails fast (or retries once) using worker-specific
knowledge; sitter guarantees the whole thing stays bounded and that a human
hears about terminal failure. Neither layer needs to know the other's rules.

## Consequences

- Requests to add `--probe` (or `--health-cmd`, `--liveness`, etc.) should be
  answered with this ADR and the example wrapper, not reopened, unless the
  layering argument itself is shown to be wrong.
- sitter's supervision surface stays deterministic and testable with fake
  workers; no test needs a live worker endpoint.
- Wrapper authors carry the (small) cost of writing their own probe logic —
  accepted, because they are the only party that can write it correctly.
