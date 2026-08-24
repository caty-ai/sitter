# sitter full reference

This page holds the technical detail that used to live in the README. The
engineering documentation is there to get you running; this page is there to
state the contract precisely. The complete ledger schema and the reasoning
behind each design decision live in [requirements-v0.md](requirements-v0.md)
(Japanese).

- [Every command and flag](#every-command-and-flag)
- [Reply tracking in detail](#reply-tracking-in-detail)
- [Ask / watch contract in detail](#ask--watch-contract-in-detail)
- [Sweep operational detail](#sweep-operational-detail)
- [Hook reasons and payload](#hook-reasons-and-payload)
- [Git Bash / MSYS2 background](#git-bash--msys2-background)

## Every command and flag

```
sitter run --ledger <path> --on-fail <cmd> [--log <path>]
           [--stall-after <s, default 900; 0=disabled>] [--timeout <s, default 14400>]
           [--grace <s, default 10>]
           [--idempotent NAME --allowlist <path>]
           [--retries <n 0..10, default 3>] [--cooldown <s, default 60, minimum 5>]
           [--kill-file <path, default $SITTER_HOME/STOP>]
           [--project <s>] [--agent <s>] [--task <s>] [--session-id <s>]
           -- <cmd> [args...]

sitter expect --ledger <path> --on-fail <cmd> --id <expect_id>
              [--sla <sec, default 86400>] [--to <name>] [--text <message>]
              [--project <s>] [--agent <s>] [--task <s>]

sitter ack --ledger <path> --id <expect_id> [--detail <s>]

sitter ask --ledger <path> --to <name> --sla <sec> --reply-file <abs_path>
           [--id <expect_id>] [--text <message>] [--kill-file <path>]
           -- <cmd> [args...]

sitter ask --already-sent --ledger <path> --to <name> --sla <sec> --reply-file <abs_path>
           [--id <expect_id>] [--text <message>] [--kill-file <path>]

sitter watch --once --ledger <path> [--id <expect_id>] [--kill-file <path>]

sitter sweep --once --ledger <path> --on-fail <cmd>

sitter --help | -h | --version
```

Stall detection is evaluated at 15-second granularity; timeout polling uses
the remaining timeout when it is shorter, so short timeouts are still honored.
`--stall-after 0` without `--timeout` is refused at startup.

## Reply tracking in detail

`expect` appends a pending reply expectation to the ledger. IDs must match
`^[A-Za-z0-9._-]{1,64}$`; quotes, backslashes, and control characters are
removed from `--to` and `--text` before writing. Text is UTF-8-byte-truncated
to 140 bytes. An active id cannot be registered twice, and a quarantined id is
permanently burned. `ack` is idempotent: it always appends an acknowledgement,
including when the matching expectation arrives late or out of order.

`sweep --once` replays the ledger and exits; it does not run a daemon or
schedule itself. Schedule that command externally. Each active expectation
advances once per elapsed SLA window: `pending` → nudge 1 → nudge 2 →
`awaiting_human`. Every transition is appended to the ledger before its hook
is invoked, so hook delivery is at-most-once: a crash can lose at most one
delivery and cannot duplicate a transition. Within an expectation generation,
an acknowledgement is absorbing: later nudge rows are ignored during replay,
and sweeps recheck the live ledger immediately before appending a transition.

## Ask / watch contract in detail

`ask` is the reply-file side of the contract. The reply file is a dedicated
evidence file, not a transport. In normal mode, `sitter ask ... -- <cmd>
[args...]` hashes the current reply baseline, atomically reserves the
generation by appending exactly one `ask_prepare`, runs the sender command,
and appends `expect pending` if the command exits 0. If the send fails, it
appends `ask_send_failed`. If the send succeeds but the active `expect`
append fails, sitter prints a `LIVE_UNWATCHED` recovery hint and leaves the
reply file as the durable source of truth; rerun the same generation with
`ask --already-sent` instead of re-sending. `ask` prints the expect id only
after the generation is active; if admission loses to an existing reservation,
active generation, or quarantine, it exits 2 without running the sender.

`ask --already-sent` is the recovery path for replies that already exist on
disk or for a generation that was observed but not yet tracked. It does not
accept `--` or command argv. A live v1 ask generation reserves its id while it
is `prepared`, `send_failed`, `pending`, `nudged1`, `nudged2`, or
`awaiting_human`, so legacy `expect` rows cannot reuse the same id until that
generation is retired. Reuse the same id with `--already-sent` only when you
are recovering that same prepared / send_failed / live generation with matching
metadata. If the metadata changed, or the earlier generation is already acked
or quarantined, start a new id instead. Concurrent normal `ask` calls with the
same explicit `--id` race for one reservation: the winner appends the lone
`ask_prepare`, and the loser gets a precise `reserved`, `active`, or
`permanently quarantined` diagnostic. Do not downgrade to a v0-only sitter
binary while any v1 ask generation is active.

`watch --once` is the read-only scanner. It replays the ledger, follows reply
file symlinks for observation, and appends `ack` only when the reply file
grows or its contents change. Unreadable, non-regular, truncated, or
disappearing reply files stay pending. `watch` never drives transport or
delivery; it only observes the reply file and the ledger. When it newly
observes a reply, it prints `acked <expect_id>` and exits 0. When nothing
changed, it prints nothing and exits 0. Observation failures return 1 after
best-effort scanning, and `sweep --once` remains the SLA escalator and
`--on-fail` hook runner.

**Out of contract in v0:** submitting expectations from other users, other
machines, or shared/synced directories. The supported writers of expect-family
rows are the sitter verbs themselves, run as the user that owns the sweep.
The append-only format was audited not to foreclose a future second writer —
see [ADR-0002](adr/0002-expect-single-writer.md) — but nothing outside
that contract is stable today.

## Sweep operational detail

The sweep lock lives under `$SITTER_HOME`, so overlapping scheduler
invocations normally exit successfully without doing work. A kill-switch file
also makes a sweep exit without nudging. Ledger lines are replayed rather than
cursor-based; the shared ledger is staged privately under the ledger append
lock before parsing. Repeated malformed sitter-claiming lines and failed hooks
are quarantined after three failures. Shared-ledger paths are trusted private
directories in v0; they do not receive full symlink/TOCTOU hardening.

## Hook reasons and payload

`--on-fail` is the single notification integration point. It receives the
event payload in `SITTER_*` environment variables and as one JSON line on
standard input. The hook is fired for these reasons:

| `SITTER_EVENT` | `SITTER_REASON` | When |
| --- | --- | --- |
| `refused` | `denied` | `run` rejected a dangerous command before starting it. |
| `end` | `timeout` / `stall` / `exit` | A non-idempotent run failed terminally and will not be restarted. |
| `end` | `budget_exhausted` | An idempotent run exhausted its retry budget. |
| `nudge` | `sla_breach` | The first or second SLA window elapsed without an ack. |
| `awaiting_human` | `awaiting_human` | A third elapsed SLA window requires human action. |

Other rows reach the ledger without invoking the hook: the per-attempt `fail`
event that precedes a restart, every `end killed` produced by the kill switch,
and `end success`. Filter on `SITTER_REASON` rather than on `SITTER_EVENT` —
terminal failure and budget exhaustion both arrive as `end`.

### Ledger reason contract (run family)

The run-family `reason` field is an open string vocabulary. Consumers must not
whitelist a closed set: currently emitted values are `exit`, `stall`,
`timeout`, `killed`, `budget_exhausted`, `success`, `denied`, and `""` on
`start` rows. The ask/sweep hook paths additionally use `sla_breach` and
`awaiting_human`.

The `event` field names the row family; discriminate the kill kind on `reason`,
never on `event` — an `event:"stall"` row can carry `reason:"timeout"`.

| Path | Ledger rows | Hook delivery |
| --- | --- | --- |
| Non-idempotent attempt failure (`stall`, `timeout`, or `exit`) | `fail` has status `failed` and the attempt reason, followed by terminal `end` with status `failed` and the same reason. | Fires on `end` with `SITTER_REASON` set to that reason. |
| Retry budget exhausted (idempotent) | Per-attempt `fail` rows retain their attempt reasons, but terminal `end` has both status and reason `budget_exhausted`. The per-attempt stall/timeout truth lives only in the `fail` rows. | Fires on `end` with `SITTER_REASON=budget_exhausted`, not the last attempt reason. |
| Kill switch | Terminal `end` has status and reason `killed`, but carries no hook reason. | No hook fires for that `end`. |
| Any `fail` row | Ledger-only, including the `fail` that precedes a terminal non-idempotent `end`. | Never invokes the hook. |

Within one poll tick, detection precedence is kill switch, then timeout, then
stall. A same-tick stall and kill therefore records `killed` with no `stall`
row.

Future detection mechanisms may add reason values. Such additions are
additive; consumers must treat unknown values as opaque.

See [the drop-file hook example](../examples/on-fail-dropfile.sh) for a
deliberately tiny adapter that appends escalations to a monitored inbox file.
It is only a hook example: sitter itself has no knowledge of any notifier.

Hook authors must treat every `SITTER_*` value as untrusted data: quote values
when using them and never pass them through `eval`.

## Git Bash / MSYS2 background

The v0 failures measured there (12 of 22 scenarios) turned out to be a single
missing tool, not process semantics: Git Bash ships no `shasum`, and sitter
died before its first ledger event. A follow-up evidence round (see
[design-history.md](design-history.md)) measured every suspect primitive,
shipped an additive `shasum` → `sha256sum` fallback, and the complete suite —
including the process-supervision core — went green on `windows-latest`
Git Bash (23/23 at the time; the suite has since grown).

As the suite grew it added cases that Git Bash cannot satisfy, and three fail
there today. `aw_11_prepare_failure_prevents_send` makes a ledger directory
non-writable with `chmod 500` and expects the prepare step to fail;
`aw_46_unreadable_no_ack` makes a reply file unreadable with `chmod 000` and
expects the observation to fail. Git Bash does not enforce either denial, so
both operations succeed and the assertions see exit 0 instead of 1 — the
tests are measuring POSIX permission semantics that MSYS2 does not provide,
not a defect in sitter. The third, `aw_64_existing_hook_regressions_green`,
covers killing a hook that traps `TERM`, and Git Bash runs the suite about
three times slower (829 s against 266 s on the development machine), which
makes signal-timing cases fragile.

CI therefore runs Git Bash as a non-blocking job, and WSL remains the
supported path.
