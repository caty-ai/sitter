# Design — ledger compaction / bounded growth (#74)

Status: **REJECTED at upstream review r1 (2026-09-08, 3/3 NO-GO) — kept as a record, not a plan.**
Owner decision: #74 re-scoped to ask-ledger separation; the offset-guard fix moved to #76.
Blocking findings (see the #74 r1 result comment): D1 breaks `ask --already-sent`
because `ask_generation_state` never resets on v0 rows (§1's "only the latest
generation is observable" is false for C3); quarantine is not absorbing in C3/C6;
a once-per-pass prefix hash leaves a mid-loop hole; exact tier underspecified for
`run`/foreign rows; unlocked second writer and no-fsync are new loss modes.
Original status line: draft v0 for upstream review (L1-9; nothing here is implemented)
Lane/size: backend / **L** (persistence semantics, `component:ledger`); child of #71 (PR #73, v0.5.0)
Baseline: `origin/main` bc3030d, `SITTER_VERSION=0.5.0`, oracle `tests/fixtures/sitter.baseline`

Implementation note for the reviewers and the owner: the implementation (not
this document) deletes rows from a persistence file. Under the handbook's
high-risk definition ("irreversible operations: data deletion / migration")
the implementation lane needs **5 review seats and an owner checkpoint**, not
the 3 seats this design review uses. This document is written so that the
implementation can be a separate issue with its own Files-to-touch.

## 0. Problem and numbers

After #71 each `sweep --once` / `watch --once` pass is linear in ledger size,
but the ledger only ever grows. Measured on the synthetic history
(`tests/bench-ledger.sh`, macOS arm64, single observations, v0.5.0):

| lines | sweep | watch |
| ---: | ---: | ---: |
| 1,000 | 3.4 s | 0.3 s |
| 10,000 | 21.7 s | 2.5 s |
| 50,000 | 96.5 s | 12.3 s |

Two production facts change what "compaction" has to mean (measured
2026-09-08 on the maintainer's live ledger, `~/.claude/state/mission-control/runs.jsonl`):

| fact | value | consequence |
| --- | --- | --- |
| size | 13,884 lines / 8.0 MB | staged privately on every 5-minute sweep (launchd `StartInterval` 300) |
| rows with `expect_id` | 6 | the expect-family reducer state is tiny |
| `"schema":"sitter.v0"` rows without `expect_id` (`run` events) | 8,671 | never read by sitter itself |
| rows with no sitter schema at all (mission-control `mc-log`, appended without the ledger lock) | 5,213 | a second writer already exists in practice |
| sweep failure seen in the launchd log | `cp: ... fcopyfile failed: No space left on device` (once) | staging a whole-history copy is itself a failure surface |

So an expect-family-only reducer would shrink the benchmark ledger (3 reused
ids) to a handful of rows but would shrink the production ledger by ~0.05 %.
Bounded growth in production means a retention policy for `run` rows and
foreign rows too, and a lock/replace protocol that survives a writer that
does not take the lock. Both are in scope below; §8 asks the seats whether
the frame itself is wrong (e.g. whether the right fix is "asks get their own
ledger" rather than compaction).

## 1. Consumers — the replay-equivalence surface

"Replay equivalence" is defined per consumer: for every consumer C and every
ledger L, `C(compact(L)) == C(L)` for the observable outputs listed here.
Row *identity* is not observable; only these outputs are.

Internal (all in `sitter`, all keyed by `expect_id`, all replay the whole file):

| id | function | observable output | reads |
| --- | --- | --- | --- |
| C1 | `active_expect_id` (`expect` admission, `ask --already-sent` fallback) | active / not (return code) | live reducer R_live |
| C2 | `live_expect_state` (sweep recheck after the offset guard) | last live state string | R_live |
| C3 | `ask_generation_state` (`ask --already-sent` adoption) | `ASK_STATE` **plus** `ASK_TO/TEXT/SLA/REPLY_FILE/BYTES/SHA` of the last v1 generation row | v1-aware reducer |
| C4 | `ask_conflict_kind` (ask admission, once unlocked, once under the ledger lock) | reserved / active / quarantined / none | R_live via `admission_replay_line` |
| C5 | `sweep_locked` historical reducer | per id: `state`, `ts` (SLA base), `to`, `text`, `sla`, and the parallel live state | generation reducer (`expect` starts, `quarantine` burns) |
| C6 | `watch` | per id: state, and for v1 `expect` rows the reply baseline `path/bytes/sha` | v1 `expect` + v0 transitions |
| C7 | `record_poison` (sweep) | side state: `$SITTER_HOME/failcounts` / `quarantined`, keyed by `sha256("ledger:<path> line:<raw line>")`; a `quarantine` row is emitted at count 3 | every row for which `expect_replay_line` returns 2 |
| C8 | #71 staged-offset guard in `sweep_locked` | whether a candidate may trust the staged state without a full replay | `stage_bytes`, `tail -c`, `wc -c` on the live file — **assumes append-only** |

External (outside this repo, but real):

| id | consumer | reads | must keep |
| --- | --- | --- | --- |
| X1 | mission-control dashboard `server/agents.js` | last 500 lines, `JSON.parse` each, keyed by `run_id` / `expect_id` | recent history in original order; rows it cannot parse are skipped |
| X2 | mission-control `bin/mc-log` | **writes** its own JSON rows with `fs.appendFileSync`, no lock | its rows must not be lost, including a row appended during compaction |
| X3 | humans / `grep` / audits | everything | an archive of what was dropped |

The reducer facts the retention rules depend on (verified against
`sitter` v0.5.0 line by line):

- **Quarantine is a permanent tombstone in every reducer.** C1/C2/C4 `continue` once `last_state == quarantined`; C5 `next`s on `state[id]=="quarantined"` and guards `live[id] != "quarantined"`; C6 never leaves `quarantined` because only `ack` changes an established state and `ack` on quarantined is not in the v0 active set. A `quarantine` row **only** burns an id if an `expect` row for that id precedes it (all reducers require an established state). Poison quarantines (`expect_id` = a hash key, no preceding `expect`) therefore never burn anything; they are audit rows, and the suppression lives in the `quarantined` side file.
- **Only the latest generation of an id is observable.** Every reducer resets on `expect` (and, for v1, on `ask_prepare` / `refused`); earlier generations of the same id never influence any output once a later `expect` row exists. Exception: a quarantined generation, after which later rows are ignored — so for a quarantined id the "latest observable generation" is the quarantined one and everything after it is dead.
- **`''` (no rows) and `acked` are bisimilar in R_live (C1/C2/C4/C5-live/C6)** — both are non-active, and every event maps them to the same successor: `expect`→pending, v1 `ask_prepare`→prepared, `ask_send_failed`→unchanged (needs prepared), `refused` (v0 or v1)→acked, v0 `ack`/`nudge`/`awaiting_human`/`quarantine`→unchanged. Hence a fully acked generation can be dropped without changing C1/C2/C4/C6.
- **`''` and `acked` are *not* bisimilar in C3.** `ask --already-sent` dies on `acked` ("cannot adopt an acked or quarantined ask") but takes the fresh-adoption path (with the documented warning) on `''`. This is the one place where "acked" differs from "absent", and it decides the default tier below.
- **`run` events are never read by sitter.** Cooldown state lives in `$SITTER_HOME`, not in the ledger. Their only readers are X1 and X3.

## 2. Retention rules

Terminology: a *generation* of id X is the maximal run of expect-family rows
for X starting at an `expect` row (v0/v1), a v1 `ask_prepare` row, or a v1
`refused` row, up to the next such row. A generation is *live* if R_live ends
in `pending|nudged1|nudged2|awaiting_human|prepared|send_failed`, *burned*
if it ends in `quarantined`, *terminal* otherwise (`acked`).

Rules, in priority order (a row is kept if any keep-rule matches; drop-rules
apply only to rows no keep-rule claims):

| rule | rows | action | why (consumer) |
| --- | --- | --- | --- |
| K1 | every row of the latest generation of an id whose generation is **live** | keep verbatim | C5 needs `ts/to/text/sla` from the `expect` row and the nudge rows for the state; C6 needs the v1 baseline; C3 needs the v1 metadata; the nudge count is only recoverable from the rows |
| K2 | the `expect` row and the `quarantine` row of a **burned** generation | keep verbatim (2 rows) | the tombstone needs both rows in order to burn in C1–C6; id reuse must stay refused forever |
| K3 | of the latest **terminal** generation of an id: the last `expect` row (v0 or v1) before the terminal transition, if any, and the *terminal row* (the row at which R_live became `acked`: a v0 `ack` from an active state, or a v1 `refused`) | keep verbatim (≤ 2 rows) — *exact tier* | preserves C3's `acked` (die on adoption) and its metadata; C1/C2/C4/C5/C6 are indifferent (bisimilar). **Not** "first and last row": a v1 generation starts with `ask_prepare`, and `ack` only absorbs from `pending`-family states, so `ask_prepare`+`ack` alone would replay as `prepared` (reserved) in C1/C3/C4 — the v1 `expect` row is the one that must survive |
| K4 | rows for which `expect_replay_line` returns 2 (poison) whose key is **not** in the sweeper's `quarantined` file | keep verbatim | C7's fail counter would otherwise never reach 3; the row is the only carrier of its own key |
| K5 | any row with no parseable `ts` and no keep-rule (defensive) | keep verbatim | a row we cannot date cannot be expired |
| D1 | every row of a **superseded** generation (an older generation of an id that has a later `expect`/`ask_prepare`/`refused` row, or any row after a burned generation's `quarantine` row) | drop | unobservable by construction (§1, "only the latest generation") |
| D2 | rows of the latest terminal generation other than the two K3 keeps (`ask_prepare`, `ask_send_failed`, nudges, `awaiting_human`, earlier `expect` rows of the same generation) | drop | after the kept `expect` row every reducer is in `pending` with the same metadata; nudges only move within the active family, and the terminal row absorbs them all |

Assumption behind K2/D1: sitter verbs never append a row for an id after its
`quarantine` row (`expect` dies on `active_expect_id`, `ask` and
`ask --already-sent` die on `quarantined`). If a foreign writer appended a v1
`expect` there, C3 alone would read it as `pending` (its v1 branch does not
check the tombstone) while R_live ignores it; D1 drops such rows and C3 then
reads `quarantined`. That divergence exists only on out-of-contract input and
is accepted (ADR-0002 already makes any foreign writer undefined behaviour).
| D3 | poison rows whose key **is** in the sweeper's `quarantined` file | drop | C7 early-returns on quarantined keys; the emitted `quarantine` audit row (K5/K6) remains |
| D4 | quarantine audit rows (`expect_id` = hash key, no preceding `expect`) older than the expiry window | drop | inert for every reducer; audit only |
| E1 | *expiry tier (opt-in)*: `run` rows, foreign rows, quarantine audit rows, and **terminal generations** whose `ts` is older than `--expire <duration>` | drop | X1 reads only the last 500 lines; sitter never reads `run`; the single observable change is C3 (below) |

Two tiers, chosen by flag, never mixed silently:

- **Exact tier (default, no `--expire`)**: K1–K5, D1–D4. Every consumer C1–C8
  and X1–X3 is equivalent by the arguments in §1 (formal check in §5). Bound:
  ≤ (rows of one live generation) per live id, 2 rows per terminal or burned
  id, plus unquarantined poison rows. Growth is now proportional to the
  number of *distinct ids ever used*, not to history. On the benchmark shape
  (3 reused ids) this is ~10 rows. On the production shape it removes ~0
  rows, because the growth there is `run` and foreign rows — which the exact
  tier never touches.
- **Expiry tier (`--expire <duration>`)**: adds E1. Two consumers change
  observably and the change is documented as the contract of the flag:
  - C3: `ask --already-sent --id X` where X's terminal generation was
    expired now takes the fresh-adoption path (warning
    `fresh adoption cannot detect pre-adoption replies`) instead of dying.
    Reusing X through `expect` / plain `ask` was already permitted before
    compaction (C1/C4 treat acked as reusable), so this only widens
    adoption to match the other verbs after the window.
  - X1: history older than the window disappears from the dashboard; it
    reads the last 500 lines anyway.
  Live and burned generations are never expired (K1/K2 outrank E1), so no
  SLA clock, baseline, or tombstone can be lost by age.

Rows are never rewritten or synthesized: `compact(L)` is an ordered
subsequence of `L`. This is what makes the proof in §5 mechanical and keeps
the row shapes frozen (`docs/reference.md` "the v0 ledger schema is frozen").

What "the sweeper's `quarantined` file" means: compaction runs with the same
`$SITTER_HOME` as the sweep owner (ADR-0002: one sweep owner per ledger). If
`$SITTER_HOME/quarantined` is absent, K4 keeps all poison rows (fail-closed).

## 3. Verb and flags

`sitter compact --once --ledger <path> [--expire <duration>] [--archive <path>|--no-archive] [--dry-run] [--json]`

- `--once` for symmetry with sweep/watch (the verb is a single pass; no daemon).
- `--dry-run` prints the plan (rows kept / dropped per rule, before/after
  bytes) and exits 0 without touching the ledger. `--json` makes that plan
  machine-readable. The exit code of a real run is 0 on success or no-op,
  1 on any failure (ledger untouched).
- `--archive <path>` (default `<ledger>.compact-<UTC ts>.jsonl`, same
  directory, mode 600): the dropped rows, in original order, written and
  closed **before** the replace step. `--no-archive` is the only way to
  drop rows without a copy. Irreversible-operation posture: the default is
  reversible. Because the archive holds only the dropped rows, a plain
  concatenation of archive and ledger is not order-correct; the archive
  therefore carries a sidecar `<archive>.lines` with each dropped row's
  original line number, so the pre-image can be rebuilt exactly (reviewers:
  §8 Q4 asks whether this is overkill versus archiving the full pre-image).
- No automatic invocation from `sweep` in this design. Compaction is an
  explicit operator verb (Issue: "behind an explicit verb or flag"). A
  scheduled invocation is the operator's launchd/cron decision.
- `--expire` durations: `<n>d` / `<n>h` only; compared against the row's
  `ts` (`timestamp_epoch`), never against file mtime.

## 4. Lock / replace protocol and the #71 offset guard

Constraints: appends from sitter verbs go through `with_ledger_lock`
(`flock` / `lockf` / mkdir tiers). `reserve_ask_prepare_inner` appends by
path under the same lock. `mc-log` appends by path with no lock. Sweep holds
`sweep.lock` (not the ledger lock) while parsing a staged copy, then uses
`stage_bytes` + `tail -c` + `wc -c` to decide whether the staged state is
still trustworthy (#71). Watch stages under the ledger lock and works from
the stage only.

Protocol (single pass):

1. **Stage** exactly as sweep does: `copy_ledger_locked "$stage" "${stage}.bytes"` → `B` bytes, measured under the lock.
2. **Plan** offline from `$stage`: one linear pass producing the keep/drop
   decision per line number. Two sub-passes are needed because K1–K3 depend
   on the *latest* generation, which is only known at end of file: pass A
   records per id the line number of the last generation start and the
   R_live/C5 outcome; pass B emits decisions. Both passes are `awk`-driven
   over the same delimiter-safe replay rows sweep already builds (the
   `printf '%s\t...'` block in `sweep_locked`), so no new parser is
   introduced — the plan reuses `expect_replay_line` verbatim.
3. **Write** `$out` (mktemp in `$LEDGER_DIR`, mode 600) = kept rows from the
   stage, in order. Write the archive. If nothing is dropped, stop here:
   exit 0, no replace, so the file is never replaced by an equal-length copy
   (this is the #76 concern from our own side).
4. **Replace, under the ledger lock**, in one locked child:
   1. `wc -c` live → `L`. Require `L ≥ B` and `head -c B live | sha256` ==
      sha256(stage). Otherwise **abort** (exit 1, nothing replaced): the
      prefix changed under us, i.e. someone else replaced the ledger.
   2. `tail -c +$((B+1)) live >> $out` — the delta appended since staging,
      byte-exact, including a possibly unterminated last row.
   3. `mv -f $out $LEDGER` (same directory → atomic rename; symlink checks
      as in `append_locked`).
   The locked child is `sh -c` with positional arguments, like
   `copy_ledger_locked`, so that lock-tier timeouts keep cleanup in the
   parent.
5. Print the plan summary; exit 0.

Why the delta can be appended verbatim: the delta contains only rows
appended after `B`; none of them were considered by the plan, so appending
them unchanged is exactly the state a reader would have seen if compaction
had happened at time-of-staging and every later append had happened after
it. Order within the file is preserved, and the plan's keep-set is a superset
of what would be kept had those rows been visible (a later `expect` can only
make *more* earlier rows droppable, never fewer). So the result is a valid
(possibly slightly under-compacted) compaction of the live file.

**Unlocked writer (X2).** A row appended by `mc-log` between step 4.2 and
4.3 lands in the old inode and is lost. The window is one `mv`. The design
does not paper over this: (a) the contract states that writers of a
compacted ledger must take the ledger lock (`flock <ledger>.lock`), which
is the same duty ADR-0002 already assigns to a second writer; (b) the
follow-up for mission-control is to make `mc-log` take that lock (one
`flock` call around `appendFileSync`; issue to be opened in
`alpha-mission-control` before compaction is ever run on that ledger);
(c) `--dry-run` never has the window. Reviewers: §8 Q3 asks whether (a)+(b)
is acceptable or whether compaction must refuse to run when a foreign row
shape is detected unless `--allow-foreign` is given.

**Re-arming the #71 offset guard (C8).** Today sweep trusts
`live_bytes ≥ stage_bytes` as proof that the first `stage_bytes` bytes are
unchanged. After a compaction the live file can be shorter (guard fires,
full replay, correct) **or longer** than a stage measured before the
compaction (shrink by 200 bytes, then grow by 500: the guard is silent and
`tail -c` reads misaligned bytes). The failure mode is bounded — the raw
substring check can only miss an `ack` that moved *below* the offset, which
yields one extra nudge whose transition every reducer ignores — but the
guard is supposed to be a proof, not a heuristic. Re-arm it by replacing the
size comparison with a **prefix identity check**: sweep records
`sha256(stage)` when it stages (the hash tool is already detected for
failcount keys), and the guard becomes

    live_bytes ≥ stage_bytes AND sha256(head -c stage_bytes live) == staged_sha

computed once per pass before the candidate loop (the per-candidate `tail`
stays for rows appended during the loop, since appends cannot change the
prefix). Cost: one read of `stage_bytes` bytes per sweep pass (~8 MB today,
tens of milliseconds). This closes #76 as well, for *any* replacement,
equal-length or longer, external or ours, which is why #76 should be folded
into the implementation issue of this design rather than fixed separately.
Alternative considered: an inode check (`stat`) — cheaper, but inode reuse
after `mv` is possible and `detect_stat_mtime` shows how much portability
glue `stat` needs; the hash is portable and already available. Reviewers:
§8 Q2.

**Sweep and watch during compaction.** Both work from a private stage;
their appends (`emit_expect_event` → `append_locked`; `ack_transition`) open
by path under the lock and land in whichever inode is current — the new one
after step 4.3, the old one before it (and step 4.2 carries them over).
`ask_conflict_kind` outside the lock keeps its `exec 8<` on the old inode
and sees a consistent snapshot; the locked re-check in
`reserve_ask_prepare_inner` runs after compaction's lock is released and
opens the new file. No consumer can observe a torn file because the only
mutation is the rename.

**Crash safety.** Crash before 4.3 leaves `$out`/archive temp files (same
`.sitter-*.XXXXXX` convention as `append_locked`) and an intact ledger.
Crash during 4.3 is the rename's atomicity. No fsync is introduced because
sitter does not fsync appends either; the archive is written and closed
before the rename, so on a clean crash the archive is at worst an unused
copy. Reviewers: §8 Q5 on whether the archive should be fsynced.

## 5. Proving replay equivalence

Three layers, all against the frozen oracle `tests/fixtures/sitter.baseline`
(v0.5.0) plus the new binary:

1. **Structural (per rule).** For each keep/drop rule a hand-written 5–30
   row ledger fixture where the rule is the only thing that fires; assert
   (a) `compact(L)` is the expected subsequence, (b) for every consumer:
   - C1/C2/C4: run `expect --id X` and plain `ask --id X` against `L` and
     against `compact(L)` (copies), compare exit code and stderr.
   - C3: `ask --already-sent --id X` likewise (this is where the exact
     tier must match and the expiry tier must differ in the documented way,
     asserted directly). One fixture is the K3 trap: a v1 generation
     `ask_prepare → expect → nudge → ack`; a wrong "first+last" compaction
     must be shown to replay as `reserved` in `ask` admission, and the
     specified compaction as reusable.
   - C5: `sweep --once` on both with a no-op hook and a due candidate;
     compare the appended rows modulo `ts`/`event_id` (the fields the
     existing tests already mask), and the side files.
   - C6: `watch --once` on both with a changed reply file; compare output.
   - C7: a poison row below/at the quarantine threshold; compare
     `failcounts` and `quarantined` after one sweep.
   - C8: the shrink-then-grow scenario — stage a sweep with
     `SITTER_SWEEP_LOCKED=true` paused on the hook, compact, append rows
     until the file is longer than the stage, resume; assert exactly one
     transition and no nudge for an id acked in the delta. This test must
     **fail** on v0.5.0 (shows the guard was silent) and pass with the
     prefix check — probe the oracle first and assert both directions, the
     #71 r3c pattern.
2. **Generative (differential).** Extend `tests/fixtures/gen-ledger.sh`
   with a seed and random interleavings (v0/v1, poison, `run`, foreign
   rows, reused ids, quarantines, adoption). For N seeds, run every consumer
   verb on `L` and `compact(L)` and diff the observable outputs. The
   oracle for the *consumers* is the new binary itself (consumers are not
   changed by compaction), and the oracle for "the consumers did not
   change" is `sitter.baseline` run on `L` — the existing equivalence tests
   already cover that, so this layer only needs `new(L) == new(compact(L))`.
3. **Idempotence and archive round-trip.** `compact(compact(L)) ==
   compact(L)` (no-op, exit 0, no rename), and interleaving the archive back
   by line number reproduces `L` byte-exactly.

CI: Linux (`ubuntu`) and macOS both, as #71 showed; the `flock` tier and
the `lockf` tier are exercised by the respective platforms, and the mkdir
tier by the existing `PATH`-stripping test pattern.

## 6. Benchmark plan (50k)

`tests/bench-ledger.sh` gains a third column: `after+compact` = compact
once, then time `sweep`/`watch` on the compacted ledger. Report, per size
(1k/10k/50k), the three timings plus compaction time and bytes before/after.
Also add a second shape, `gen-ledger.sh --unique-ids`, where every ask has a
fresh id (the production shape), and report the exact tier vs
`--expire 7d`. Expected: benchmark shape ~10 rows after exact compaction
(sweep from 96 s to well under 1 s); production shape unchanged under the
exact tier and bounded by the window under expiry. Numbers go in the
implementation PR body, not here.

## 7. Contract text to add (docs/reference*.md, at implementation)

- The ledger is append-only **between compactions**; `sitter compact` is the
  only supported replacer, and any other replacement is out of contract.
  Writers of a compacted ledger must take the append lock.
- What survives a compaction (K1–K5), what does not (D1–D4), and the
  expiry tier's two documented observable changes.
- Sweep's staged-offset guard is a prefix-identity check from this version.

## 8. Questions for the seats (answer each; NO-GO needs a row and a reason)

- **Q0 — Is the frame wrong?** Production growth is `run` + foreign rows on a
  ledger that holds six expect rows. The alternative to compaction is
  *separation*: point `sitter-ask`/`sweep`/`watch` at a dedicated ask
  ledger (the launchd plists and the wrapper scripts already take
  `--ledger`), leave `runs.jsonl` to `logrotate`-style rotation, and never
  compact anything. That removes the replace protocol, the guard change and
  the second-writer problem entirely. Is compaction still worth building,
  or should this issue close as "ask ledger separation + rotation", with
  only the C8 prefix guard kept (it stands on its own for #76)?
- **Q1 — Retention rules.** Is any keep-rule missing a consumer? Is the
  `''`/`acked` bisimulation argument (§1) correct for every reducer branch,
  including v0 `refused` after a v1 generation?
- **Q2 — Guard.** Prefix hash vs inode vs a compaction-epoch marker row.
  The marker row was rejected because it is a new row shape read by X1's
  `JSON.parse` path; is that the right call?
- **Q3 — Unlocked second writer.** Accept "contract + mc-log fix" or require
  the verb to refuse foreign rows without `--allow-foreign`?
- **Q4 — Archive.** Default-on archive with a line-number sidecar, or plain
  dropped-rows archive, or no default archive (operator's backup problem)?
- **Q5 — fsync.** Introduce fsync for the archive and the rename, or stay
  consistent with the rest of sitter (no fsync anywhere)?
- **Q6 — Scope split.** Recommended implementation split: (i) C8 prefix
  guard + tests (closes #76, S/M, no data deletion, 3 seats); (ii) `compact`
  exact tier + archive + tests + bench (L, deletion, 5 seats + owner
  checkpoint); (iii) `--expire` (M, its own two documented divergences).
  Agree, or should (ii) and (iii) ship together so the production shape has
  a real path from day one?
