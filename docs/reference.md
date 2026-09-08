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
- [Ledger placement and rotation](#ledger-placement-and-rotation)
- [Hook reasons and payload](#hook-reasons-and-payload)
- [Git Bash / MSYS2 background](#git-bash--msys2-background)

## Every command and flag

```
sitter run --ledger <path> --on-fail <cmd> [--log <path>]
           [--stall-after <s, default 900; 0=disabled>] [--timeout <s, default 14400>]
           [--heartbeat-file <path>]
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
With `--heartbeat-file`, stall age uses the freshest of the log and heartbeat
mtimes; an unavailable or non-regular heartbeat contributes nothing, while a
failed log stat retains the existing skip-for-that-poll behavior. The option
has no environment-variable input: sitter resolves a relative path against
`$PWD`, refuses empty values, symlinks, non-regular files, touch failures,
`--stall-after 0`, and equality with the ledger, ledger lock, kill file, or log,
then passes the absolute path to the child only as `SITTER_HEARTBEAT_FILE`.
That equality check compares strings after making each relative path absolute
against `$PWD`, then resolving each path's parent directory to its physical
path. The ledger (and lock) parent and the heartbeat parent are created before
the comparison, so those sides are always resolved; a kill-file or log path
whose parent does not yet exist retains its spelling after absolutization, so
`..` on that side is not collapsed.
Use one heartbeat file per supervised run, never share it between runs, and
touch it at least twice as often as `--stall-after` because mtimes are
second-granular and polling is every 15 seconds. Inside the wrapper, keep
the worker a single process (`exec` it) or forward `TERM` to its children;
otherwise the wrapper's own kill paths leave grandchildren behind. `expect`,
`ack`, and `sweep` parse and ignore the option like `--stall-after`; `ask` and
`watch` refuse it.

The default log (`$SITTER_HOME/logs/${RUN_ID}.log`) contains only one run's output. A fixed `--log` path grows across runs and must be rotated by the operator between runs, never during a run. The child keeps its log descriptor open, so rotation during a run can separate its output from the path's mtime used as the stall clock or discard output.

## Reply tracking in detail

`expect` appends a pending reply expectation to the ledger. IDs must match
`^[A-Za-z0-9._-]{1,64}$`; quotes, backslashes, and control characters are
removed from `--to` and `--text` before writing. Text is UTF-8-byte-truncated
to 140 bytes. An active id cannot be registered twice, and a quarantined id is
permanently burned. `ack` is idempotent: it always appends an acknowledgement,
including when the matching expectation arrives late or out of order.

Since v0.5.0, ledger lines are replayed bytewise on every platform: bytes that are not valid UTF-8 no longer poison a line (previously platform-dependent). Emitted text is truncated to a prefix its UTF-8 validator accepts, whether or not `iconv` is available (since v0.5.2): without `iconv`, the longest prefix that is well-formed per RFC 3629; with `iconv`, the longest prefix the platform `iconv` accepts (glibc is RFC-strict; macOS libiconv additionally passes forms above U+10FFFF and obsolete 5/6-byte sequences). Before v0.5.2 the no-`iconv` fallback only trimmed an incomplete trailing sequence. Since v0.5.3, `--on-fail` hooks and the wrapped command inherit the operator's `LC_ALL`/`LANG` unchanged. Sitter's internal string-handling helpers and their own subprocesses still run under `LC_ALL=C`, as do its explicitly scoped replay pipelines. Before v0.5.3, a hook could observe `LC_ALL=C` when the operator had exported `LC_ALL`.

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

Sweeps serialize and hold the lock while waiting for hooks. Each due expectation's hook is allowed up to `SITTER_HOOK_TIMEOUT` (default 30 seconds). Hung hooks delay the next sweep's opportunity to run by that wait per due expectation, plus hook termination/reaping grace and sweep processing overhead.

The sweep lock lives under `$SITTER_HOME`, so overlapping scheduler
invocations normally exit successfully without doing work. A kill-switch file
also makes a sweep exit without nudging. Ledger lines are replayed rather than
cursor-based; the shared ledger is staged privately under the ledger append
lock before parsing. Repeated malformed sitter-claiming lines and failed hooks
are quarantined after three failures. Shared-ledger paths are trusted private
directories in v0; they do not receive full symlink/TOCTOU hardening.

The live ledger is append-only: supported writers only append, and replacing it
in place (for example, hand compaction or restoring a backup over it) is out of
contract. Since v0.5.4, a sweep verifies that the first `stage_bytes` bytes of the
live ledger match its private stage before trusting the staged replay, falling
back to a full replay for affected candidates if the ledger was replaced or
truncated. Before v0.5.4, an equal-or-longer replacement could produce a spurious
nudge.

## Ledger placement and rotation

Since v0.5.5 the recommended layout is **one ledger per family**. The
*expect family* — `expect`, `ack`, `ask`, `watch`, `sweep`, everything keyed
by `expect_id` — should run against a ledger that no `run` invocation and no
foreign writer appends to. Every verb takes `--ledger`; nothing in sitter
requires the families to share a path. Sharing a ledger is still supported and
replays exactly as before, but its cost is proportional to the *whole* file:
each sweep or watch pass copies the entire ledger to its private stage under
the ledger lock and replays every line, and lines from the run family and
from foreign writers are discarded only after they have been staged and read.
On the maintainer's production ledger that meant 13,884 rows replayed for
6 expect-family rows on every 5-minute sweep. With a dedicated ledger the
cost grows with the ask history alone. The reasoning, the measured numbers,
and the one-time procedure for moving live asks to a new ledger (stop every
expect-family writer — the kill file does not stop `ack` — and wait until
every caller reports nothing in flight, since a wrapper may not have called
sitter yet and `expect` / `ask` replay the whole ledger before they append;
process probes alone are not sufficient; copy the `"expect_id"` rows in order into a
**new or empty** file under `umask 077` and `<ledger>.lock`, and prove the copy — under the same lock,
the projection and the new file must compare byte-identical — before
repointing and again just before restarting; record the count beside the
old ledger; never move or edit the old file in place)
are in [docs/specs/ledger-separation.md](specs/ledger-separation.md).

A ledger that **no expect-family invocation reads or appends to** — in
practice the run ledger, which may also hold foreign rows and, after a
migration, inert copies of old expect rows — may be **rotated by its
owner**: rotation is *rename + fresh file*. Before rotating, the owner
checks that no wrapper, scheduler entry, dashboard, operator or agent passes
the path to `expect` / `ack` / `ask` / `watch` / `sweep`, and — under
`<ledger>.lock`, held through the rename — that `grep -c '"expect_id"'` on
the file still equals the count recorded beside it when the asks were moved
out (`<ledger>.expect-count`; `0` for a file that never held asks or was
created after a rotation; never re-derived from the file's current
contents); a larger count means something still writes asks there — the
excess rows are stranded asks: append them to the ask ledger under *that*
ledger's lock and sweep it once before anything else — and the file must
not be rotated.
`sitter run` appends each event by reopening the ledger path under
`<ledger>.lock` and creates the file if it is missing, so the next append
after a rename lands in a fresh file at the same path; it never reads the
ledger back, and no verb replays run-family rows. Hold `<ledger>.lock` for
the rename with the primitive sitter uses on that host (`flock`; `lockf -k`
on macOS; on a host with neither, sitter's `mkdir <ledger>.lock.d` tier —
take it the same way or rename without the lock) so the rotation is a clean
boundary; otherwise leave the lock file and any `<ledger>.lock.d` directory
alone. **Never rotate a ledger the expect family reads**: it replays its
whole history, a shortened file is treated as a replacement and replayed
from scratch, and every active expectation, prepared ask and quarantine
tombstone silently disappears (exit 0, no nudge, no `awaiting_human`).
In-place replacement (truncate, rewrite, restore over) stays out of
contract for every ledger. Rotated files are the owner's to keep or delete;
sitter never reads them.

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

No other run-family row invokes the hook: `start`, `stall`, `restart`, every
`fail` row, `refused` with reason `killed` (a kill switch observed at
admission), every `end killed`, and `end success` are all ledger-only. Filter
on `SITTER_REASON` rather than on `SITTER_EVENT` — terminal failure and budget
exhaustion both arrive as `end`.

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
| Retry budget exhausted (idempotent) | Per-attempt `fail` rows retain their attempt reasons, but terminal `end` has both status and reason `budget_exhausted`, masking the last attempt reason there. Detection `stall` rows and per-attempt `fail` rows retain the underlying attempt reason. | Fires on `end` with `SITTER_REASON=budget_exhausted`, not the last attempt reason. |
| Kill switch | Observed at initial admission: a single `refused` row with reason `killed`, no `end` row. Observed between attempts (at the loop top — including after a persisted cooldown — or right after a `restart` row): a terminal `end` with status and reason `killed`, no `fail` row. Observed mid-attempt: `fail` with reason `killed`, then the terminal `end killed`. | None of these rows invoke the hook. |
| Any `stall` or `restart` row | Ledger-only. | Never invokes the hook. |
| Any `fail` row | Ledger-only, including the `fail` that precedes a restart, the `fail` that precedes a terminal non-idempotent `end`, and the mid-run `fail` with reason `killed`. | Never invokes the hook. |

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

`sweep --once` stops with a nonzero status if its ledger snapshot or live-tail read fails; no candidate is emitted from an unreadable snapshot or tail.
