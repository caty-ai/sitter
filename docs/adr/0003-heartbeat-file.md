# ADR-0003: `--heartbeat-file` — a stdout-independent liveness input for stall detection

- Status: Accepted
- Review: L1-9 design review 2026-09-04, seats GLM 5.3 / Kimi K3 / Grok 4.6 (record in #46)
- Date: 2026-09-04
- Related: ADR-0001 (`--probe` permanently rejected), #10 (two incidents 2026-08-12 / 2026-08-14), `examples/probe-wrapper.sh`

## Context

`sitter run` decides dead-or-alive with three worker-agnostic signals: exit code,
log-mtime stall (`--stall-after`, default 900 s), and an absolute wall-clock cap
(`--timeout`). The log-mtime signal structurally misfires on workers that are
**silent by design**: remote dispatches (`openclaw agent --json`, hermes
one-shot) keep the log at 0 bytes for the whole turn, so a healthy turn and a
hang look identical and the healthy one is killed at `stall_s`. #10 documented
the per-run opt-out (`--stall-after 0 --timeout <cap>`), but the opt-out trades
stall protection for none: a genuinely hung silent worker now runs to the cap.

ADR-0001 forbids the obvious fix (`--probe <cmd>` / `--health-cmd` /
`--liveness`): sitter must never execute worker-specific health knowledge.
That constraint is kept here.

## Decision

Add one opt-in flag to `sitter run`:

```
--heartbeat-file <path>        (default: unset; no environment input)
```

Semantics:

1. **Stall clock takes the freshest of two mtimes.** With the flag set, the
   stall age is `now - max(mtime(log), mtime(heartbeat_file))`. Without the
   flag, behavior is byte-for-byte unchanged (`now - mtime(log)`).
2. **sitter never pulses the file.** It never runs anything to produce the
   heartbeat. Whoever knows the worker is alive — the wrapper the caller
   already owns — `touch`es the file at its own cadence. The per-attempt touch
   is a baseline reset only (same reason as the log; see the cooldown-crossing
   test). This is the ADR-0001 layering: worker-specific knowledge stays in the
   wrapper, sitter stays worker-agnostic and testable with fake workers.
3. **Baseline reset per attempt is fail-closed.** At every attempt launch
   sitter rechecks that the path is not a symlink and `touch`es it, exactly as
   it already does for the log, so a restart after cooldown does not inherit a
   stale heartbeat. A failed recheck or touch aborts the attempt as an error,
   not as a stall.
4. **Path is exported only to the child launch.** The wrapped command runs with
   `SITTER_HEARTBEAT_FILE=<absolute-path>` in its environment so a wrapper can
   `touch "$SITTER_HEARTBEAT_FILE"` without the caller duplicating the path.
   The variable is applied with `env` to both launch paths; it is not exported
   by sitter and is not delivered to `--on-fail`. sitter never reads
   `SITTER_HEARTBEAT_FILE` as configuration: only the flag enables the feature.
5. **Refusals at startup (exit 2), fail-closed:**
   - an empty value is refused;
   - a relative path is first resolved against `$PWD`;
   - `--heartbeat-file` together with `--stall-after 0` is refused (a heartbeat
     with the stall signal disabled is a misconfiguration, ADR-0001 reason 4);
   - an existing directory, device, other non-regular file, or symlink is
     refused;
   - equality with `--ledger`, `${LEDGER}.lock`, `--kill-file`, or the explicit
     or default log path is refused;
   - the parent directory is created with `mkdir -p`, then sitter probe-touches
     the file and requires a regular, non-symlink result; no `chmod` is applied
     to a caller-owned path (unlike sitter's own log dir).

   Heartbeat symlinks are a new surface and are fail-closed by default. Log
   symlinks are deliberately followed, pinned by `symlink_log_path_is_followed`.
   The mid-run swap window is handled by the per-attempt and per-poll checks.
6. **Heartbeat unavailability never disables stall detection.** At every poll,
   the heartbeat contributes only if `[[ -f path && ! -L path ]]` and its stat
   succeeds. If it is missing, a directory, a device, a symlink, or cannot be
   statted, it contributes nothing and that poll uses the log mtime alone. A
   failed log stat retains the existing rule and skips the stall check for that
   poll. sitter always stats by path and never holds an fd, so recreation is
   observed.
7. **Ledger contract unchanged.** No new field; schema stays `sitter.v0`;
   `reason` stays `stall`. With a valid heartbeat, a stall `detail` is
   `pid alive, log mtime frozen <a>s, heartbeat frozen <b>s`. If the configured
   heartbeat is unavailable at detection time, the suffix is
   `heartbeat unavailable`. Without the flag, the existing detail remains
   exactly `pid alive, log mtime frozen <a>s`.
8. **One heartbeat file belongs to one supervised run.** It must never be
   shared between runs. A wrapper should touch it at least twice as often as
   `--stall-after`, accounting for second-granular mtimes and the unchanged
   15-second `SITTER_POLL_INTERVAL` granularity.
9. **Verb contracts remain narrow.** `expect`, `ack`, and `sweep` parse and
   ignore `--heartbeat-file`, exactly as they do `--stall-after`; only `ask`
   and `watch` refuse it as an option outside their contracts.

## When to use which

| Situation | Use |
| --- | --- |
| Job normally streams output, occasionally goes quiet longer than 15 min | raise `--stall-after` |
| Job is silent until done and **nothing** can vouch for it meanwhile | `--stall-after 0 --timeout <cap>` (#10) |
| Job is silent by design but **something cheap can vouch for it** (remote turn still active, backend answers) | `--heartbeat-file` + a wrapper that touches it while the vouch holds; keep `--stall-after` and `--timeout` |

The example wrapper touches only while both the worker is still alive and a
bounded vouch passes. A vouch that merely says “the backend is up” can keep a
hung turn alive until `--timeout`; that is the #10 trade, and sitter does not
police it.

## Alternatives rejected

- **Process-state / CPU-time liveness** (candidate in #46: "syscall-level
  progress"). Both incidents were a local `ssh` blocked in `read()` on a healthy
  remote turn: zero CPU, state `S`. A CPU/state signal would have killed them
  too, and it says "alive" for a spinning hang. It measures the wrong thing.
- **No flag: wrapper touches the log itself** (`--log <path>` + `touch`).
  Works today by accident, but conflates output capture with liveness, forces
  the caller to pass `--log` explicitly, and leaves no trace in the stall
  `detail`. Rejected in favor of an explicit, greppable input.
- **`--probe` / `--health-cmd`** — ADR-0001, not reopened.

## Files

`sitter` (launch_attempt stall clock; run() validation; arg parsing/usage;
ask/watch contract lists), `tests/run.sh` (+ fixture), `README*.md`
("Know what counts as frozen" gains the third option), `docs/reference*.md`,
`examples/heartbeat-wrapper.sh` (worker runs in background; every N s the
wrapper's own bounded vouch passes and the worker is still alive →
`touch "$SITTER_HEARTBEAT_FILE"`), this ADR, one see-also line in ADR-0001.

## Tests (planned)

1. silent worker + wrapper touching heartbeat every 1 s, `--stall-after 3` → no `stall` event, `end success`
2. silent worker, heartbeat touched once then stops, `--stall-after 3` → `stall` fires, `detail` contains `heartbeat frozen`
3. `--heartbeat-file` with `--stall-after 0 --timeout 10` → exit 2
4. heartbeat path is a symlink → exit 2
5. `ask` / `watch` given `--heartbeat-file` → exit 2
6. child sees `SITTER_HEARTBEAT_FILE` equal to the absolute flag value
7. idempotent failure → restart: second attempt gets a newer heartbeat baseline and does not stall immediately
8. flag unset → existing stall detail and suite behavior unchanged

Additional regression coverage pins heartbeat deletion and symlink replacement
mid-run, directory and unwritable-parent refusal, all four path collisions,
child-only environment scope, environment non-configuration, per-attempt touch
failure, the advancing-log/frozen-heartbeat half of `max()`, and parse-and-ignore
behavior for `expect`, `ack`, and `sweep`.

## Amendments after review

- **A1 — Fail-closed unavailability:** a missing, non-regular, symlinked, or
  unstattable heartbeat contributes nothing, so the log alone remains the
  stall clock for that poll.
- **A2 — Fail-closed creation and touch:** startup validates, creates the
  parent, and probe-touches the absolute path; each attempt rechecks and
  touches it, aborting as an error on failure.
- **A3 — Flag-only enablement:** sitter never reads `SITTER_HEARTBEAT_FILE` as
  configuration.
- **A4 — Path collisions:** equality with the ledger, ledger lock, kill file,
  or explicit/default log path is refused.
- **A5 — Child-scoped export:** `SITTER_HEARTBEAT_FILE` is applied only to the
  wrapped child launch, on both launch paths, and never to the failure hook.
- **A6 — Complete `max()` coverage:** tests pin both fresh-input halves, the
  both-frozen case, fail-closed paths, and the byte-identical unset detail.
- **A7 — Bounded wrapper vouch:** the example touches only after a bounded
  vouch succeeds while the worker is alive, and cleans up without an orphan
  heartbeat loop.
- **A8 — Operational guidance:** docs require one heartbeat per run, a cadence
  at least twice as frequent as `--stall-after`, and retain the narrow verb
  contracts.
- **A9 — Symlink and baseline wording:** the heartbeat is a fail-closed new
  surface, and sitter's per-attempt touch is only a baseline reset.
- **A10 — Path-based observation:** sitter holds no heartbeat file descriptor;
  every poll stats the configured path so recreation is observed.
