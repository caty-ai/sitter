# Spec — a dedicated ledger for the reply deadman, and the run-ledger rotation contract (#74)

Status: **adopted 2026-09-08** (owner decision after the upstream review r1 of the
compaction draft; that draft is kept on branch `design/74-compaction` as a
rejected record and is not a plan). Lane: docs + bench, size **M**, `component:ledger`.
Shipped as **v0.5.5** (a norm operators follow; no `sitter` behaviour change).
Origin: #71 (linear replay, v0.5.0) → #74 (this document) → #76 (prefix-identity
guard, v0.5.4).

This page records three things: the measured problem, why compaction was
rejected on evidence, and the two contracts that replace it — *run the
expect family against its own ledger* and *rotate run ledgers by rename*.
The normative sentences are repeated in [reference.md](../reference.md)
(“Ledger placement and rotation”); this page carries the reasoning.

## 0. The measured problem

After #71 each `sweep --once` / `watch --once` pass is linear in ledger
size, but the ledger only grows. The synthetic history
(`tests/bench-ledger.sh`, default mode: three reused ids, mixed v0/v1,
poison and `run` rows; macOS arm64, v0.5.0, single observations):

| lines | sweep | watch |
| ---: | ---: | ---: |
| 1,000 | 3.4 s | 0.3 s |
| 10,000 | 21.7 s | 2.5 s |
| 50,000 | 96.5 s | 12.3 s |

What the maintainer's production ledger actually contains (measured
2026-09-08, `~/.claude/state/mission-control/runs.jsonl`, the file that a
launchd job hands to `sweep --once` every 300 s):

| fact | value (disjoint buckets) |
| --- | ---: |
| rows / bytes | 14,170 / 8.15 MB |
| rows carrying `"expect_id"` (the expect family: `expect` / `ack` / `nudge` / `awaiting_human`) | **6** |
| `"schema":"sitter.v0"` rows without `expect_id` (`run` family: `start` / `heartbeat` / `end`) | 8,857 |
| `"schema":"sitter.v1"` rows | 0 |
| rows with no sitter schema at all (mission-control `mc-log`, appended without the ledger lock) | 5,307 |

The buckets sum exactly (6 + 8,857 + 0 + 5,307 = 14,170). An earlier
snapshot the same day, taken for the issue and the bench, counted 13,884
rows with the same six expect rows (its component counts, 8,671 and 5,213,
over-counted by six and are not repeated here); the bench (§5) keeps that
13,884-row total and the same ≈ 5:3 run:foreign mix. So more than 99.9 % of
the bytes that every sweep copies to its private stage and
pushes through the replay loop belong to rows the replay filter discards on
sight (`expect_replay_line` returns without parsing unless a line carries
`"schema":"sitter.v1"`, or `"schema":"sitter.v0"` together with
`"expect_id":`). The reply deadman is paying for the run supervisor's
history and for a foreign writer's history.

## 1. Why compaction was rejected (r1, 2026-09-08, 3/3 NO-GO)

The compaction draft proposed an in-place reducer that keeps only the rows
each consumer still needs. Three blind, read-only seats (Kimi K3, Gemini
3.8 Flash, Codex) rejected it on reproduced evidence; the full record is in
the #74 r1 result comment. The findings that matter for this document:

- **Retention cannot be derived from a shared “generation” notion.**
  `ask --already-sent` observes v0 rows that a v1 generation is supposed to
  supersede (`ask_generation_state` resets only on v1 rows), so dropping the
  “superseded” generation turns a refused adoption (exit 2) into a fresh one
  (exit 0) and loses the pre-adoption reply protection. Quarantine is not
  absorbing in every reducer either (a later v1 `expect` resets it).
  Every safe design therefore has to prove replay equivalence per consumer,
  per row shape, forever.
- **An expect-only reducer would shrink the production file by ≈ 0.05 %.**
  Bounded growth in production means a retention policy for `run` rows and
  for a foreign writer's rows — neither of which sitter reads.
- **Replacing a live ledger in place is a new loss surface**, not an
  inherited one: a writer that does not take the lock, no fsync on the
  replacement, and a staged-offset guard that has to be re-armed at a
  lock-coupled boundary (that last point was fixed generically in #76 /
  v0.5.4, independent of compaction).

All three seats answered the frame question (“is compaction the wrong
tool?”) the same way: **separate, don't compact.** Every verb already takes
`--ledger`; nothing in sitter requires the expect family and the run family
to share a file. The zero-deletion fix is to stop sharing.

## 2. Contract A — the expect family gets its own ledger

Terms: the **expect family** is `expect`, `ack`, `ask`, `watch`, `sweep`
(everything keyed by `expect_id`). The **run family** is `sitter run`
(`start` / `heartbeat` / `end` and their `fail` / `stall` / `restart` rows).

**A1 — Recommendation.** Run the expect family against a ledger to which
no `run` invocation and no foreign writer appends. Give `sitter-ask`-style
wrappers, `watch --once` and the scheduled `sweep --once` the same
dedicated `--ledger`; give `sitter run` a different one.

**A2 — Sharing stays in contract.** A ledger that mixes both families
replays exactly as before; nothing in this release changes the format, the
append-only contract (v0.5.4), the replay semantics, the lock (`<ledger>.lock`)
or the side state under `$SITTER_HOME`. What A1 changes is the cost model:
each sweep or watch pass copies the whole file to its private stage under
the ledger lock and replays every line, so **the per-pass cost of the
expect family is proportional to the whole file, not to the live asks**.
With a dedicated ledger it is proportional to the ask history alone, which
grows by a handful of rows per ask.

**A3 — Why foreign writers matter twice.** A writer that appends without
the ledger lock is outside sitter's contract (`docs/adr/0002`). On a shared
expect ledger its rows are pure replay cost, and any row of its that happens
to carry sitter's markers unescaped (`"schema":"sitter.v1"`, or
`"schema":"sitter.v0"` with `"expect_id":`) is parsed as sitter's own — a
malformed one is a poison line, counted per ledger and quarantined after
three failures. A foreign writer is also the party most likely to truncate
or rotate the file it owns, which on a ledger that carries expect rows is
the B4 hazard below. On a dedicated expect ledger none of this can happen;
on a run ledger the foreign rows are harmless to sitter — nothing replays
them — but they can still break the file for its other consumers.

**A4 — Moving the live asks (one-time placement).** The hazard is a row of
the expect family landing in the old file after the copy was taken: that
ask (or that `ack`) is then in a file nothing sweeps, and it loses its
deadman protection with no signal. So the placement has to quiesce **every
writer of the family**, not just the scheduler. The kill file is not enough:
`watch` and `sweep` return without touching the ledger when it is present,
`expect` and `ask` still append a `refused` row (which carries an
`expect_id`, so the copy and the checks below do see it), and **`ack`
ignores it entirely** (it always appends); ad-hoc or dashboard-driven
invocations do not go through the scheduler at all.

The success condition of the whole procedure is a single, checkable
invariant, taken under the ledger lock: **the new ledger is byte-for-byte
the expect-family projection of the old one** (`grep '"expect_id"' old |
cmp - new`). Every step below either establishes that invariant or
re-checks it; counts are only a convenience on top of it. A copy that
failed, stopped short, ended in a torn row, or was overtaken by a late
writer all show up as a `cmp` mismatch, and the remedy is always the same:
regenerate the copy (nothing writes to the new ledger until the restart in
step 4, so regenerating is safe and idempotent).

1. Stop everything that can invoke `expect` / `ack` / `ask` / `watch` /
   `sweep` against `old.jsonl`: unload the scheduled sweep and watch jobs,
   stop the ask pipeline (the wrapper scripts, the dashboard or agent that
   calls them), and tell anyone who runs the verbs by hand. Then **drain**.
   The condition that matters is *every caller has stopped and has no job
   in flight*: a wrapper that was launched before you stopped its caller
   may not have reached its `sitter` call yet, and a verb that has reached
   it replays the whole ledger *before* it appends (`expect` / `ask`: about
   1–2 s on the production shape, longer under load), so its row can land
   after any check you take now. The authoritative evidence is the callers'
   own state — the scheduler shows the jobs unloaded, the ask pipeline's
   supervisor reports nothing in flight (for `sitter-run`-style launchers,
   no `run` without its `end` row in the run ledger), nobody is mid-command.
   Process probes are necessary but not sufficient, and both must be empty
   together: `lsof -- old.jsonl old.jsonl.lock` **and**
   `pgrep -f 'sitter[- ](expect|ack|ask|watch|sweep)'` (the hyphen
   alternative catches wrappers named `sitter-ask` / `sitter-ask-watch`;
   add your own wrapper and job names to the pattern — a wrapper that has
   not called sitter yet holds no file descriptor and does not match the
   bare verb). If you cannot get the callers' state, also wait at least as
   long as one full pass takes on that ledger (the scheduled sweep's wall
   time in its log, or `time watch --once` on a private *copy* of the file
   under a private `$SITTER_HOME` — a kill file would make either verb
   return before staging, so it cannot be used to time a pass).
2. **Copy under the ledger lock, then prove the copy.** Use the lock
   primitive sitter uses on this host — `flock` where it exists, otherwise
   `lockf -k` (macOS has no `flock`), otherwise the `mkdir <lock>.d` tier —
   and put the redirection *inside* the locked command so that a missing
   or failing primitive creates nothing:

   ```sh
   old=/path/to/runs.jsonl; new=/path/to/asks.jsonl
   with_lock() {  # same exclusion as sitter's with_ledger_lock (it spins up to 60 s; this fails fast): with_lock <lock> <cmd...>
     l=$1; shift
     if command -v flock >/dev/null 2>&1; then flock "$l" "$@"
     elif command -v lockf >/dev/null 2>&1; then lockf -k "$l" "$@"
     else mkdir "$l.d" || return 1; "$@"; rc=$?; rmdir "$l.d" 2>/dev/null || true; return $rc; fi  # keep the hold short: sitter evicts a lock dir older than 300 s and then owns it
   }
   [ ! -s "$new" ] || { echo "$new exists and is not empty: refusing to overwrite a ledger" >&2; exit 1; }
   ( umask 077; with_lock "$old.lock" sh -c 'grep "\"expect_id\"" "$1" > "$2"' sh "$old" "$new" ) || exit 1
   with_lock "$old.lock" sh -c 'grep "\"expect_id\"" "$1" | cmp - "$2"' sh "$old" "$new" || exit 1
   n=$(grep -c '"expect_id"' "$new" || true); [ "$n" -gt 0 ] || echo "note: $old held no asks; the new ledger starts empty" >&2
   ```

   The destination must be new or empty: the copy truncates it, and the
   `cmp` invariant compares against what was just written, so it cannot
   notice an active ask that already lived there — the guard on the first
   line is what protects a re-run of this runbook, or a mistaken target.
   The copy line **copies, never moves or edits in place**; holding
   `<ledger>.lock` means no sitter append can interleave with the copy, so
   it cannot end in a torn row, and `umask 077` gives the new file mode
   0600 now rather than at sitter's next touch. The second line is the
   invariant: the projection and the copy are byte-identical *under the
   same lock*, so a copy that failed or stopped short, and a row that
   landed after the copy, both fail here. On a mismatch, find the writer,
   then rerun both lines — the copy is regenerated from scratch. The
   projection carries every expect-family row sitter itself writes (v0 rows
   have `"schema":"sitter.v0"` + `expect_id`; v1 `ask_*` / `refused` rows
   are emitted by the same template and always carry `expect_id`) in
   original order, which is all the replay needs: active generations,
   acknowledgements and quarantine tombstones replay identically from the
   copy. The one replayable row the marker cannot see is a *foreign* line
   carrying `"schema":"sitter.v1"` without an `expect_id` — the A3 hazard;
   sitter never writes one, and it is a poison line wherever it sits, so
   it is not something to carry over.
3. Point every expect-family invocation at `new.jsonl` (wrappers, plists,
   dashboard configuration), and record `n` beside the old ledger:
   `printf '%s\n' "$n" > "$old.expect-count"`. That file is what Contract
   B's pre-rotation check reads, possibly months later and by a different
   tool; it must never be re-derived from the old file's current contents,
   which would turn the check into a tautology.
4. Immediately before restarting the jobs and the ask pipeline, run the
   `cmp` line of step 2 once more. It still holds because nothing has
   written to either file since step 2 — if it does not, a writer is still
   alive: find it and go back to step 2 (regenerate; the new ledger has
   received nothing yet, so this is safe — but delete `$new` first, or the
   non-empty guard refuses). Then, **before** restarting the scheduled
   jobs, run `sweep --once` on `new.jsonl` once: any ask whose SLA elapsed
   during the placement fires now rather than on the next scheduled pass.
   (Order matters: the sweep lock is non-blocking, so a manual sweep that
   collides with a scheduled one returns 0 having done nothing.) Then
   restart.

The old rows stay in the old file and are inert once nothing sweeps it. Do
not truncate or rewrite the old file: it is still the run ledger, and it
stays append-only. Note that failure counters and quarantine keys under
`$SITTER_HOME` include the ledger path (`ledger:<path> …`): a poison line's
count and a failing hook's count both restart at zero on the new path (so
quarantine of a repeatedly failing hook can take up to three more failures),
while an id that was quarantined stays burned because its `quarantine` row
was copied and is replayed.

**A5 — One `$SITTER_HOME` per expect ledger.** The sweep lock is
`$SITTER_HOME/sweep.lock` and it is non-blocking on every tier: when two
sweeps share a home, the second one exits successfully without doing any
work. Two different ledgers swept under one home therefore skip each
other's passes. If the old shared file is still swept for any reason, give
it a different home or, better, stop sweeping it.

## 3. Contract B — run ledgers are rotated by rename

Facts this contract rests on (all in `sitter`, unchanged by this release):

- `sitter run` appends every event by **reopening the ledger path** under
  `<ledger>.lock` (`append_locked`: write the row to a private temp file, then
  `cat temp >> ledger` under the lock). It creates the file if it is missing
  and never keeps a descriptor open between appends.
- `sitter run` **reads nothing back** from the ledger. Neither does any
  other verb read run-family rows: the replay filter skips every line that
  lacks `"schema":"sitter.v1"` or `"schema":"sitter.v0"` + `"expect_id":`.
- The lock lives beside the ledger (`<ledger>.lock`; on the mkdir tier also
  `<ledger>.lock.d`), not inside it.

**B1 — Rotation is rename + fresh file, and the precondition is about
references, not contents.** A ledger may be rotated only when **no
expect-family invocation and no scheduled job names its path** — nothing
runs `expect` / `ack` / `ask` / `watch` / `sweep` with that `--ledger`. That
is the property that makes the file's history disposable: the run family
never reads it, foreign rows are never replayed, and expect rows can only
be inert copies left behind by A4. (The file *containing* expect rows is
therefore not, by itself, the disqualifier; the file being *read* by the
family is.) Before every rotation the owner checks, in this order:

1. No wrapper script, scheduler entry or dashboard configuration passes this
   path to an expect-family verb (on the maintainer's machine: the two
   launchd plists and the `sitter-ask*` scripts), and no operator or agent
   invokes a verb against it by hand.
2. `grep -c '"expect_id"' <ledger>` equals the value recorded at placement
   (A4's `n`, read from `<ledger>.expect-count`), or `0` for a file that
   never held asks or was created after a rotation (no count file). **Take
   this count under `<ledger>.lock` and keep the lock through the rename**
   (B2): a count taken outside the lock leaves a window between the check
   and the `mv` in which a writer that check 1 missed could still land an
   ask in what becomes the archive. Never re-derive the expected value
   from the file's current contents (a missing count file on a file that
   once held asks means the record was lost — restore it from the A4
   record, do not recreate it from the count). A larger count means
   something still writes asks here — release the lock, stop and find it;
   do not rotate. The excess rows are stranded asks that have had no
   deadman since they landed: **rescue them before anything else**. Take
   the excess rows from the projection under the run ledger's lock into a
   private file, then append that file to the ask ledger **under the ask
   ledger's own lock** (every sitter append to it takes that lock, so the
   rows land whole and in order; the run ledger's lock says nothing about
   the ask ledger):

   ```sh
   with_lock "$ledger.lock" sh -c 'grep "\"expect_id\"" "$1" | tail -n +$(($2 + 1)) > "$3"' sh "$ledger" "$n" "$tmp"
   with_lock "$asks.lock"   sh -c 'cat "$1" >> "$2"' sh "$tmp" "$asks"
   ```

   Then run `sweep --once` on the ask ledger once, at a moment the
   scheduled sweep is not in flight (the sweep lock is non-blocking, so a
   collision silently does nothing — the next scheduled pass fires it
   anyway), and write the new count to `<ledger>.expect-count`; only then
   fix the writer and rotate. After a
   rotation, remove the count file: the fresh file starts at `0`. (The
   count sees every row sitter
   writes; it cannot see a foreign `"schema":"sitter.v1"` line without an
   `expect_id` — the A3 hazard — which is a reason to keep foreign writers
   off expect ledgers, not a reason to rotate.)

Then the owner (the supervisor that chose the path — in the maintainer's
deployment, mission-control) renames the file to an archive name. The next
append from any live `sitter run` recreates the path (mode 0600, umask 077).
Do not truncate, copy-then-truncate, or rewrite the file in place —
in-place replacement is out of contract for every ledger (v0.5.4).

**B2 — Take the ledger lock for the count and the rename.** Renaming is
safe against sitter's own appends even without the lock (each row is one
`>>` write into whichever file the path names at the instant it is opened),
but holding `<ledger>.lock` with the same primitive sitter uses on that host
— across B1's count *and* the `mv`, as one critical section — makes the
rotation a clean boundary: the count and the rename see the same file,
every row appended before the rename is in the archive, every row after is
in the fresh file, and a foreign writer that also takes the lock cannot
straddle it. For example (`lockf -k` in place of `flock` on macOS):

```sh
# count and rename under one hold of the ledger lock
flock "$ledger.lock" sh -c '
  expected=$(cat "$1.expect-count" 2>/dev/null || echo 0)
  actual=$(grep -c "\"expect_id\"" "$1" || true)
  [ "$actual" = "$expected" ] || { echo "asks still land in $1 ($actual > $expected)" >&2; exit 1; }
  [ ! -e "$1.$2" ] || { echo "archive $1.$2 already exists; not rotating" >&2; exit 1; }
  mv "$1" "$1.$2" && rm -f "$1.expect-count"
' sh "$ledger" "$(date -u +%Y%m%dT%H%M%SZ)"
```

(The explicit existence test matters: `mv -n` would skip a same-second
collision *with exit 0*, and the `&&` would then delete the count record
without rotating anything. Use the `with_lock` helper from A4 step 2 where
`flock` is absent.)

The primitive is `flock` where available, otherwise `lockf -k` (macOS); on a
host with neither, sitter uses the `mkdir <ledger>.lock.d` tier — take it
the same way (`mkdir` the directory, count, rename, `rmdir` it; if the
`rmdir` fails, leave it alone — sitter has taken it over, and it evicts any
lock directory older than 300 s, so keep the hold short) or rename without
the lock.

**B3 — Leave the lock alone.** `<ledger>.lock` is not part of the rotation.
Do not rename or delete it, and never remove a `<ledger>.lock.d` directory —
that is an in-progress append on the mkdir tier.

**B4 — Never rotate a ledger the expect family reads.** The expect family
replays its whole history: a rotated (shorter) file is seen by the v0.5.4
guard as a replacement and replayed from scratch, so every active
expectation, prepared ask and quarantine tombstone simply disappears — no
nudge, no `awaiting_human`, no error, exit 0 (reproduced at review with
`expect` → `run` → rename under the lock → `run` → `sweep --once`). This is
precisely why Contract A exists: the run ledger becomes rotatable
**because** nothing sweeps it any more, not because it is clean. A shared
ledger (A2) must not be rotated; after A4 the old `runs.jsonl` is rotatable
only once step 3 of A4 has been verified and B1's two checks pass.

**B5 — Archives belong to the owner.** sitter never reads a rotated file;
retention, compression and deletion of archives are the owner's policy and
are not sitter's concern. Heartbeat files, `--log` files and kill files are
unaffected by rotation.

## 4. Operator wiring (acceptance check; outside this repository)

Tracked as separate issues in the operator repositories; this lane links
them rather than doing them, so that the docs and bench here can be reviewed
on their own:

- `~/.claude/scripts/sitter-ask` and `sitter-ask-watch`: read the ledger
  path from a dedicated variable (e.g. `SITTER_ASK_LEDGER`) instead of
  `MC_LEDGER`, default `~/.claude/state/sitter/asks.jsonl`.
- launchd `ai.caty.sitter.sweep` (`sweep --once --ledger …`) and
  `ai.caty.sitter.askwatch` (runs `sitter-ask-watch`): point at the same
  dedicated ledger; one-time placement per A4.
- mission-control `server/agents.js`: tail both files (run ledger for runs,
  ask ledger for asks); rotation of `runs.jsonl` per Contract B is
  mission-control's issue. After A4, `runs.jsonl` still holds the six inert
  expect rows that were copied out; it becomes rotatable because no
  expect-family job names it any more (B1's checks: no reference, and
  `grep -c '"expect_id"'` still equals A4's `n`), not because those rows are
  gone.

Tracking issues: host wiring —
https://github.com/shojikumaru/alpha-mission-control/issues/52; dashboard
dual tail + rotation tool — https://github.com/shojikumaru/alpha-mission-control/issues/53.

Acceptance (the #74 Done-when item this lane cannot close by itself): the
sweep launchd log shows the new ledger path, and `watch --once` acks a test
ask on it.

## 5. Bench — what separation buys, measured

`tests/bench-ledger.sh --production-shape` (added in this lane) generates a
ledger with the production shape of §0 — `tests/fixtures/gen-ledger.sh
--production-shape 13884`: 13,878 run-family and foreign rows in the
production's ≈ 5:3 ratio (8,675 run / 5,203 foreign in the fixture; the
production counts differ slightly), then the same six expect-family rows
the default fixture ends with (one due, one acked, one quarantined) — and a
six-row ledger holding only those six rows. Each shape × verb is timed on a fresh
copy with a private `$SITTER_HOME`, three repetitions, median reported.
Like the default bench loop, sweep runs with `SITTER_SWEEP_LOCKED=true`, so
the sweep numbers exclude sweep-lock acquisition; both shapes are timed the
same way, so the comparison is unaffected.

Results (macOS arm64, Apple Silicon, `sitter` 0.5.5, 2026-09-08,
`--repeat 3`, wall seconds, median of three; per-run values in the PR body):

| ledger | rows | bytes | `sweep --once` median | `watch --once` median |
| --- | ---: | ---: | ---: | ---: |
| shared, production shape | 13,884 | 8,691,181 | 2.627 | 1.412 |
| dedicated ask ledger | 6 | 1,128 | 1.212 | 0.076 |

The six expect rows are byte-identical in both ledgers; the difference is
entirely the 13,878 rows the replay filter discards: about 1.4 s per pass
for either verb on this machine. `sweep` keeps a fixed cost of about 1.2 s
on the six-row ledger (one due candidate: the live-tail recheck, the nudge
append and the hook round trip), which is why its relative gain is smaller
than `watch`'s. On the maintainer's 300-second sweep schedule the shared
shape spends roughly 0.5 % of wall time replaying discarded rows — the
motivation is not that number but that it grows without bound with the run
supervisor's history, while the dedicated ledger's cost grows only with
asks.

## 6. Non-goals

- No `sitter compact` verb, no deletion or rewriting of ledger rows by
  sitter, now or as a follow-up of this lane (reopen only as a new issue,
  with the `ask --already-sent` reducer fixed first and a production shape
  that still needs it after separation).
- No change to `sitter`'s behaviour, format or flags. The version moves to
  0.5.5 because the docs now carry a norm operators are expected to follow,
  which is ship-equivalent under the handbook's release rule.
- No wiring changes in this repository (§4 lives in the operator repos).
