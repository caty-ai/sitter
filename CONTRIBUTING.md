# Contributing to sitter

Thanks for your interest. sitter is small on purpose; contributions are
welcome within the frozen design boundaries.

## Ground rules

- **Issue first.** Open an issue describing the why and the "done when"
  before sending a PR, and list the files you expect to touch.
- **Releases pin the version constant.** Bump `SITTER_VERSION` in `sitter` in the
  same commit as a release; CI runs on every pushed tag and fails unless the tag
  equals `v$SITTER_VERSION`.
- **The v0 requirements are frozen.** `docs/requirements-v0.md` records the
  rulings and their rationale. Bug fixes against the documented behavior are
  always fair game; behavior *changes* need a requirements discussion in an
  issue first. Two shortcuts to save you a round-trip:
  - a `--probe`/health-check flag will not be added — see
    [ADR-0001](docs/adr/0001-no-probe-flag.md) and
    `examples/probe-wrapper.sh` for the supported alternative;
  - writing expect-family ledger rows from anything other than the sitter
    verbs is out of contract — see
    [ADR-0002](docs/adr/0002-expect-single-writer.md).
- **Zero dependencies stays zero.** bash + the standard macOS/Linux userland
  only, no third-party installs. Platform tools that differ (`flock` vs BSD
  `lockf`) get feature detection plus a portable fallback, as the ledger
  locking already does. The
  integration contract is the ledger path and `--on-fail`; PRs adding a third
  contract point will be declined.
- **Tests are the spec's teeth.** Run `bash tests/run.sh` locally; it must
  pass on macOS and Linux (CI enforces both). New behavior needs a scenario
  in the fault-injection matrix, using the fake-worker fixtures and shrunk
  timers — no real workers, no network.

## Workflow

1. Open (or claim) an issue.
2. Branch from `main`; keep branches short-lived and scoped to one issue.
3. Use Conventional Commits (`fix:`, `docs:`, `test:`…).
4. PR description: what changed, why, files touched, and test evidence.
5. One approving review, green CI, then merge.

## Reporting bugs

Include: OS (macOS/Linux), bash version, the exact sitter invocation, the
relevant ledger lines (redact your `project`/`agent`/`task` values if
sensitive), and what you expected. Never paste worker prompts or secrets —
ledger rows are designed not to contain them; bug reports shouldn't either.
