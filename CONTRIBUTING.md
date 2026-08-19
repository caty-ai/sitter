# Contributing to sitter

Thanks for your interest. sitter is small on purpose; contributions are
welcome within the frozen design boundaries.

## Prerequisites

- **bash 3.2+.** sitter targets the stock bash that ships on macOS.
- **git.** Use it for the normal issue/branch/PR workflow.
- **GNU make 3.81+.** `make test` and `make lint` are the canonical entry
  points (`make test` wraps `tests/run.sh`).
- **Standard macOS/Linux POSIX userland.** Runtime dependencies stay at zero:
  no third-party installs are required.
- **Optional `shellcheck`.** When installed, its findings fail `make lint`. If
  it is not installed, lint prints a skip notice and exits 0.
- **Optional `python3`.** The test suite uses it only for the JSON-validity
  assertion; local runs skip that assertion when `python3` is absent and
  report the skip once. In CI the assertion is required and its absence fails
  the run.
- **Platforms.** Ubuntu CI gates every pull request; macOS CI runs on pushes to
  main and on every pull request via the test-lint caller (reusable
  `test-macos`). The Windows lane (Git Bash) is continue-on-error, so Windows
  stays best-effort.

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
- **Tests are the spec's teeth.** Run `make test` locally (it wraps
  `tests/run.sh`); it must pass on macOS and Linux (Ubuntu CI gates every PR;
  macOS CI runs on pushes to main). New behavior needs a scenario in the
  fault-injection matrix, using the fake-worker fixtures and shrunk timers — no
  real workers, no network.

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
