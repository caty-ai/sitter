# Test specification — sitter v0.2 ask/watch

Status: frozen with PRD
Framework: existing plain Bash `tests/run.sh`
Network/external operations: none

## Proof goals

1. No external send happens before durable prepare.
2. No prepared/failed request enters SLA.
3. A sent-but-unactivated ask is recoverable without resending or losing the
   original baseline.
4. Reply observation never silently acks placeholder, deletion, truncation,
   unreadable content, or unchanged content.
5. v0 behavior and mixed-ledger safety remain intact.
6. Hook/nudge ownership remains exclusively in sweep.

## Test fixtures

- Fake send commands:
  - exit 0 and create a send marker;
  - exit N after creating or not creating a side-effect marker;
  - block until released;
  - mutate reply file during send;
  - make the ledger destination fail after prepare.
- Existing hook spy, JSON validity helpers, hash detection and temporary
  isolated `SITTER_HOME`.
- No production ledger, Stage 1 file, network, or scheduler is touched.

## CLI and validation cases

1. Normal ask requires ledger/to/sla/reply-file/`--`/argv.
2. `--already-sent` forbids argv and normal mode forbids command omission.
3. Watch requires `--once`; loop flags are rejected.
4. Invalid/empty/too-long IDs follow current rules.
5. `sla=0`, zero-padded decimal, and invalid numeric forms match current parser.
6. Relative reply path is rejected.
7. Control, quote, and backslash path are rejected; spaces, multibyte and shell
   metacharacters work end to end without evaluation.
8. Generated ID matches the documented pattern and validation.
9. New verbs reject transport-specific or unknown flags.

## Lifecycle/unit-style cases

10. Prepare row is visible to the fake send before its first side effect.
11. Prepare append failure means send marker is absent.
12. Prepared row is not selected by watch or sweep.
13. Successful send produces exactly one active v1 expect after prepare.
14. SLA timestamp is the active row timestamp, not prepare timestamp.
15. Send nonzero propagates the exact status and writes send_failed.
16. A side-effecting nonzero send is documented as ambiguous; same-ID normal
    resend is rejected.
17. Send failure plus failure-row append failure leaves prepared and prints the
    required diagnostic.
18. Send zero plus active append failure leaves prepared, prints
    `LIVE_UNWATCHED`, and returns 1.
19. Same-ID `--already-sent` activates from prepared without running the send
    fixture again and reuses the original bytes/SHA.
20. Reply written between send and recovery is detected on the next watch,
    proving it was not folded into a new baseline.
21. Process death after active append but before success stdout leaves pending;
    retry does not resend.
22. New out-of-band adoption captures current baseline, warns about pre-adoption
    replies, and becomes pending.
23. Adoption of an already pending matching ask is idempotent.
24. Adoption with conflicting metadata, acked generation, or quarantine fails.
25. Kill switch before prepare/refusal never runs send and records terminal
    refusal; kill switch after prepare/before send does the same.

## Schema and replay cases

26. V1 prepare/expect/fail/refused rows are valid JSON and fields/types/key order
    match the PRD.
27. Full argv and reply content do not occur in any emitted row or diagnostic.
28. V0 direct expect/ack rows remain byte-shape compatible.
29. Mixed ledger: v0 expect and v1 ask both escalate correctly under v0.2.
30. V1 prepare and send_failed do not open a generation.
31. V0 ack absorbs a live v1 ask.
32. V0 late nudge after v1 ask ack remains absorbed.
33. Old-v0 matcher ignores v1 starts without poison/quarantine.
34. Orphan v0 nudge/ack/awaiting-human after ignored v1 start does not open a
    generation, burn the ID, or suppress a later valid v0 expect.
35. Malformed recognized v1 rows follow failure-count/quarantine policy exactly
    once; unknown schemas remain ignored.
36. ID reuse after v1 ack starts a new generation; prepared/send_failed IDs are
    reserved until explicit adoption or a new ID is chosen.

## Reply truth-table cases

37. absent→absent: no ack.
38. absent→empty: no ack.
39. absent→nonempty: one effective ack.
40. empty present→growth: ack.
41. present→larger: ack.
42. present same bytes/same SHA: no ack.
43. present same bytes/different SHA: ack.
44. present→smaller/truncated: no ack, diagnostic.
45. present→absent: no ack, diagnostic.
46. unreadable regular file: no ack, error/exit 1.
47. directory/FIFO/non-regular: no ack, error/exit 1.
48. atomic replacement with different larger/same-size content follows rules.
49. atomic replacement with identical content: no ack.
50. symlink target content change: ack; broken symlink behaves absent/error per
    its baseline state.
51. Hash/read failure never acks and is retried next watch.
52. Dedicated-file warning is present in documentation.

## Concurrency and race cases

53. Two concurrent watches produce an acked final state; duplicate physical ack
    rows, if any, are replay-inert.
54. Manual ack racing watch is absorbing.
55. Sweep nudge committed before watch ack yields at most one already-committed
    hook call; later sweeps are quiet.
56. Watch ack committed before sweep prevents nudge.
57. Ack append failure leaves active; next watch retries and succeeds.
58. One bad ask does not prevent another replied ask from acking; watch exits 1
    after the best-effort pass.
59. Missing files are normal pending observations and do not make watch fail.

## Hook and SLA integration

60. Active v1 ask with SLA 0 reaches exactly `nudge`, `nudge`,
    `awaiting_human` across sweeps, with spy count 3.
61. Prepared/send_failed/refused never invoke hook.
62. Watch never invokes hook under success, reply, missing, unreadable, or ack
    failure paths.
63. Hook payload for active ask retains current `SITTER_EXPECT_ID`, text,
    ledger, event and reason contract.
64. Existing hook timeout, child containment, failure count and quarantine tests
    remain green.
65. Static check confirms new core branches contain no SSH/Hermes/Vault/
    Syncthing/probe/allowlist/routing/notification/delivery implementation.

## Regression and portability gates

66. Run the complete existing `bash tests/run.sh`; zero failures.
67. Run shellcheck on every changed shell file; zero findings.
68. Run macOS Bash 3.2-compatible lane and Linux lane.
69. Exercise `shasum` and `sha256sum` detection where available.
70. Exercise flock, lockf and mkdir fallback through the existing suite.
71. Validate all generated ledgers as JSON through existing optional validator;
    validator absence retains the existing single skip behavior.
72. Confirm source diff contains no dependency, sidecar, config, daemon loop,
    runtime library split, or unrelated refactor.

## Expanded verification plan

### Unit

CLI validation, fixed emitter fields, reply tuple comparison, lifecycle reducer,
and ID admission through isolated shell cases.

### Integration

Ask/send/ledger/watch/ack/sweep/hook flows with fake commands and isolated
ledgers.

### End-to-end

One deterministic simulated happy cycle and one SLA breach cycle in CI. The
separate real Stage 1 operational evidence gate must be satisfied outside this
test suite before implementation begins.

### Observability

Assert literal `LIVE_UNWATCHED`, external exit propagation, per-ID watch error,
success ID output, `acked <id>`, hook spy count, and absence of secrets/content.

## Completion evidence template

```text
Existing tests: <passed>/<failed>
New ask/watch tests: <passed>/<failed>
Shellcheck: <findings>
macOS/Bash lane: <result>
Linux lane: <result>
Forbidden coupling scan: <result>
Stage 1 real lifecycle evidence: <redacted reference>
Known gaps: <none or explicit>
```
