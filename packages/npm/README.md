# sitter

A babysitter for long-running commands: watch AI agents and batch jobs, restart them safely within declared bounds, and always escalate to a human. Zero-dependency bash.

sitter wraps one command, records everything it observes into an append-only JSONL ledger, and runs your `--on-fail` command when the job fails, stalls, or runs past its time limit — so unattended work never dies silently.

## Install

```sh
npm install -g @caty-ai/sitter
```

Requires macOS or Linux with bash 3.2+ (on Windows, use [WSL](https://learn.microsoft.com/windows/wsl/)). The package installs a single readable bash script and nothing else — no dependencies, no daemon, no account.

## Check that it works

```sh
sitter run --ledger /tmp/sitter-test.jsonl --on-fail 'cat >&2' -- sh -c 'sleep 3; echo test'
grep -o '"status":"success"' /tmp/sitter-test.jsonl
```

Wait about three seconds; if `"status":"success"` appears, you are installed.

## Use it on your own work

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' -- sh -c 'sleep 30; echo done'
```

Replace everything after `--` with the command you normally type. Whenever that work fails or freezes, a note is appended to `~/sitter-alerts.txt`, and the full record stays in `~/.sitter/runs.jsonl`.

## Documentation

- [Full README](https://github.com/caty-ai/sitter#readme) — also in [日本語](https://github.com/caty-ai/sitter/blob/main/README.ja.md), [中文](https://github.com/caty-ai/sitter/blob/main/README.zh.md), [ไทย](https://github.com/caty-ai/sitter/blob/main/README.th.md)
- [Engineering guide](https://github.com/caty-ai/sitter/blob/main/docs/engineering.md)
- [Command reference](https://github.com/caty-ai/sitter/blob/main/docs/reference.md)
- [Issues](https://github.com/caty-ai/sitter/issues)

## License

[MIT](https://github.com/caty-ai/sitter/blob/main/LICENSE)
