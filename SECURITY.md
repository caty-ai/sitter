# Security Policy

## Supported versions

Only the latest release on `main` is supported with security fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security-sensitive reports.
Instead, use GitHub's private vulnerability reporting on this repository
(Security tab → "Report a vulnerability"). You can expect an initial
response within a week.

When reporting, please include the sitter version (or commit), your OS and
bash version, and a minimal reproduction.

## Scope and threat model

sitter is a single-file bash supervisor that runs with the invoking user's
privileges. Its security posture is documented in
`docs/engineering.md`, `docs/reference.md`, and `docs/requirements-v0.md`;
the highlights that matter for reports:

- The restart denylist/allowlist is a **best-effort accident guard, not a
  security boundary** (see `docs/engineering.md`, "Features"). Bypassing it
  with copied or renamed binaries is out of scope; making it misjudge a
  *declared* command is in scope.
- `$SITTER_HOME` (default `~/.sitter`, mode 0700) and ledger paths are
  assumed to be trusted private directories in v0. Shared/synced-directory
  hardening beyond what `docs/reference.md` documents is out of contract
  (see `docs/adr/0002-expect-single-writer.md`).
- Hook payloads (`SITTER_*` values) are untrusted data for hook authors;
  vulnerabilities in example hooks are in scope.

Reports that break the documented contract — e.g. supervision that can be
made to fail silently, ledger corruption, command execution beyond the
declared sender/hook surfaces — are very welcome.
