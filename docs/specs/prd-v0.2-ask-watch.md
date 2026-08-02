# PRD — sitter v0.2 ask/watch

Status: approved design (implemented and audited in v0.2.0)
Lane/size: backend / H

## Requirements summary

Promote Stage 1 request/reply deadman semantics into core without promoting any
transport or delivery policy. `ask` durably records a pre-send reply baseline,
executes arbitrary exact argv, and activates the existing SLA state machine
only after successful send. `watch --once` detects local reply-file content
change and appends ack. `sweep --once` remains the only SLA/hook engine.

## Design rationale summary

### Principles

1. One local ledger is the only authority.
2. External uncertainty must be visible, not described as atomic.
3. Watch observes and acks; sweep escalates; hook delivers.
4. Preserve v0 rows and safety behavior.
5. Prefer the smallest schema that closes the real failure window.

### Decision drivers

1. No missed reply or silent live-unwatched ask after a known partial failure.
2. No SLA/hook activity before send success is known.
3. Bash 3.2+, zero dependency, small reviewable diff.

### Viable options

- **Send-first, one active row:** smallest, but sent+append failure loses the
  original baseline and cannot be recovered without a reply-miss window.
- **Active-before-send:** makes the baseline durable but can escalate an unsent
  request.
- **Non-active prepare then active expect (chosen):** one extra lifecycle row,
  preserves baseline and starts SLA only after send success.

### Pre-mortem

1. Send succeeds, activation append fails, reply arrives before recovery.
   Mitigation: durable pre-send prepare baseline + same-ID `--already-sent`.
2. Watch false-acks a file rotation/truncation.
   Mitigation: truncation/disappearance never ack; dedicated reply-file
   contract; full truth-table tests.
3. Old v0 binary is restored and silently stops v1 asks.
   Mitigation: documented no-downgrade-with-active-asks rule and mixed/orphan
   replay fixtures.

## Users and workflows

- Requester: `sitter ask ... -- external transport argv`.
- Adopter/recoverer: `sitter ask --already-sent ...`.
- Scheduler: `sitter watch --once` and existing `sitter sweep --once`.
- Hook owner: unchanged `--on-fail` contract on sweep.
- Ledger consumer: mixed v0/v1 JSONL.

## Exact CLI contract

```text
sitter ask --ledger PATH --to NAME --sla SEC --reply-file ABS_PATH
           [--id EXPECT_ID] [--text TEXT] [--kill-file PATH]
           -- SEND [ARGS...]

sitter ask --already-sent --ledger PATH --to NAME --sla SEC
           --reply-file ABS_PATH [--id EXPECT_ID] [--text TEXT]
           [--kill-file PATH]

sitter watch --once --ledger PATH [--id EXPECT_ID] [--kill-file PATH]
```

Validation:

- Required values must be present and nonempty.
- `SEC` uses the current unsigned base-10 parser; 0 is valid.
- Supplied ID uses the current `^[A-Za-z0-9._-]{1,64}$`.
- Generated ID is `ask-<UTC-basic>-<pid>-<sequence>` and obeys the same rule.
- Reply path is absolute and must not contain control bytes, `"` or `\`.
  Spaces, multibyte UTF-8 and shell metacharacters are valid.
- Normal ask requires `--` plus one argv; exact argv is executed without eval.
- `--already-sent` forbids `--` and argv.
- `watch` requires `--once`; no loop/daemon mode.
- `ask` and `watch` do not accept or invoke `--on-fail`.

Streams/exits:

- Usage/validation: exit 2, stderr.
- Internal ledger/observation failure: exit 1, stderr.
- External send failure: propagate its nonzero status after best-effort durable
  failure append.
- Successful active registration prints the expect ID on stdout after the
  active row is durable.
- No-op watch is silent and exits 0.
- Watch prints `acked <id>` per newly appended ack.

## Lifecycle

### Normal ask

1. Parse/validate and reject an active/quarantined ID.
2. Observe baseline. Absent is valid; existing-but-unreadable is pre-send error.
3. If kill switch is present, append v1 `refused`/`acked`, do not send, exit 0.
4. Append v1 `ask_prepare`/`prepared` with baseline under current ledger lock.
5. Recheck kill switch. If present, append v1 `refused`/`acked`, do not send.
6. Execute exact external argv, inheriting caller streams.
7. Exit zero: append v1 `expect`/`pending`; SLA timestamp begins here.
8. Nonzero: append v1 `ask_send_failed`/`send_failed`; return external code.

### Explicit already-sent/adoption

- With a matching prepared/send-failed generation, reuse its original baseline
  and append v1 `expect`/`pending`; never rerun send.
- With no prior lifecycle, capture a current baseline and append active pending.
  This cannot detect a reply that predates adoption; emit a warning.
- With pending/nudged/awaiting-human, same metadata is idempotent success.
- With acked, conflicting metadata, active different generation, or quarantine,
  exit 2.

### Partial failures

| Window | Durable state | Recovery |
|---|---|---|
| Baseline/prepare fails | none; no send | fix and retry |
| Death after prepare, before result | prepared | inspect transport; adopt if possibly sent, otherwise use new ID |
| Send nonzero + failure append succeeds | send_failed | adopt if side effect may have occurred; otherwise new ID |
| Send nonzero + failure append fails | prepared + stderr | same explicit operator decision |
| Send zero + active append fails | prepared + `LIVE_UNWATCHED` stderr | same-ID `--already-sent`; never resend |
| Active append succeeds, output lost | pending | ledger is authority; retry cannot resend |
| Reply observed, ack append fails | still active | next watch retries |

Normal same-ID send retry is rejected for prepared/send-failed/pending states.

## Ledger schema v1

Row identifier: `"schema":"sitter.v1"`.

V1 lifecycle rows retain the full v0 base block and expect extension block in
fixed order. Existing field rules remain unless stated:

- `event`: `ask_prepare`, `expect`, `ask_send_failed`, or `refused`.
- `state`: `prepared`, `pending`, `send_failed`, or `acked`.
- `expect_id`, `to`, `text`, `sla_s`, `nudges` retain current meanings.
- Existing `exit_code` records external failure on `ask_send_failed`; otherwise
  null.
- Append exactly:
  - `reply_file` string, required.
  - `reply_bytes` uint or null.
  - `reply_sha256` lowercase 64-hex or null.

Baseline rules:

- Absent: bytes null, SHA null.
- Present empty: bytes 0, SHA of empty content.
- Present nonempty: byte count and SHA-256.
- Never store full argv, reply content, transport type, recipient route,
  probe/delivery result, allowlist, or sync metadata.

Transition compatibility:

- Current v0 `ack`, `nudge`, `awaiting_human`, and `quarantine` rows apply to
  the current v1 generation by `expect_id`.
- V0.2 replay starts an ask generation only from a valid v1 `expect`, not from
  `ask_prepare`/`send_failed`.
- Prepared/failed rows reserve the ID but are not live for watch/sweep.
- A v0 ack is absorbing for a live v1 ask.
- Old v0 binaries ignore v1 start rows. Orphan v0 transitions must neither open
  a generation nor burn/suppress a later valid generation.

## Reply observation

Dedicated-file contract: after baseline, requester-owned edits are unsupported;
the file is dedicated to the expected reply.

| Baseline | Current | Result |
|---|---|---|
| absent | absent | pending |
| absent | empty | pending |
| absent | nonempty | ack |
| present | absent | pending + observation diagnostic |
| present | unreadable/non-regular | pending + error |
| present | larger | ack |
| present | same bytes, same SHA | pending |
| present | same bytes, different SHA | ack |
| present | smaller/truncated | pending + observation diagnostic |
| either | different atomic replacement | use size/SHA rules |
| either | identical replacement | pending |

Symlinks are followed for read-only observation. Paths are always quoted and
never evaluated. Hash/read failure never acks.

## Concurrency

- Every ledger append uses the existing append lock.
- No new watcher lock in v0.2.
- Two watchers may append duplicate physical ack rows; replay treats ack as
  absorbing, so the effective transition is one-way.
- Manual ack/watch and sweep/watch races preserve the current at-most-one
  already-committed nudge before ack.
- Watch scans best-effort: missing file is normal; per-ID hard errors are
  reported and the final exit is 1 after other IDs are processed.

## Module boundaries

Single `sitter` file:

- ask parser/lifecycle;
- fixed v1 ask emitter/replayer;
- reply observation helper;
- shared internal ack transition;
- watch one-shot branch.

Reuse current append lock, hash detection, timestamp/event ID, JSON quoting,
expect state reducer, poison/quarantine, kill switch and hook containment.
Do not create runtime libraries, config files, sidecars or transport modules.

## Acceptance criteria

1. Exact CLI/exit contracts are implemented.
2. Prepare exists before external command starts; it is never watch/sweep live.
3. SLA begins only at active `expect`.
4. Same-ID adoption reuses the durable original baseline.
5. Reply truth table is exact and deterministic.
6. Watch never invokes a hook; sweep remains the sole SLA/hook owner.
7. Mixed v0/v1 and downgrade/orphan behavior is proven.
8. All v0 tests remain green and existing row shapes are unchanged.
9. No transport/delivery/argv/content enters core or ledger.
10. Bash 3.2/macOS and Linux verification plus shellcheck are green.

## ADR

### Decision

Use a minimal non-active v1 prepare row, explicit adoption, v1 lifecycle starts
plus existing v0 transitions, one-shot watch, and sweep-only SLA.

### Drivers

Durable original baseline, no premature SLA, single writer/engine, v0
compatibility, dependency-free simplicity.

### Alternatives considered

Send-first only; active-before-send; full Proposal C generation schema; watcher
SLA engine; sidecar; transport plugins.

### Why chosen

It closes the reply-miss failure window with one additional state while
avoiding both premature SLA and Proposal C's extra generation/parser machinery.

### Consequences

One extra ledger row on normal ask; prepared ambiguity requires explicit human
adoption; old binaries pause v1 asks; supported reply paths are a documented
safe subset.

### Follow-ups

Evaluate stronger path encoding or stable double observation only if real
failures demonstrate need. Do not add them speculatively.

## Implementation staffing notes

- One implementer owns `sitter` and `tests/run.sh`; an independent verifier
  checks the gates; docs are updated only after behavior is green. Do not
  split `sitter` and `tests/run.sh` across writers.
- Shutdown proof: full test spec, shellcheck, no forbidden coupling, exact
  git diff scope. A final verifier replays the evidence after implementation.

## Changelog from review

- Replaced D-style re-baseline recovery with durable prepare/adoption.
- Rejected active-before-send and watcher-owned SLA.
- Reduced C's schema to three reply fields; removed generation/path-hex/double
  observation.
- Made adoption explicit.
- Made truncation/disappearance non-ack.
