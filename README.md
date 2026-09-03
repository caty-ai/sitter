# sitter

<div align="center">

**🇺🇸 English** ｜ [🇯🇵 日本語](README.ja.md) ｜ [🇨🇳 简体中文](README.zh.md) ｜ [🇹🇭 ไทย](README.th.md)

![Sitter brand hero: “SITTER — A WATCH POST FOR DELEGATED AI WORK”. A black cat sits at a night window, watching a constellation of linked job nodes with one glowing alert-red; an open ledger and an alarm lamp sit beside it. The scene is a metaphor for watching delegated work without owning the runtime; the image does not encode dependencies.](assets/readme/hero.png)

<h4>A free tool that watches over the long-running work you hand to an AI or to your computer.</h4>

[![CI](https://github.com/caty-ai/sitter/actions/workflows/ci.yml/badge.svg)](https://github.com/caty-ai/sitter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![npm](https://img.shields.io/npm/v/%40caty-ai%2Fsitter?logo=npm&label=npm)](https://www.npmjs.com/package/@caty-ai/sitter)
![bash](https://img.shields.io/badge/runtime-bash%203.2%2B-lightgrey?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(WSL)-lightgrey)
![deps](https://img.shields.io/badge/dependencies-none-lightgrey)

[What it does](#what) ｜ [What you need](#requirements) ｜ [Get started](#start) ｜ [Why it's safe](#safety) ｜ [Learn more](#more)

It checks whether the work really finished, whether it quietly stopped halfway,<br>
and whether a reply you are waiting for has been forgotten — and it always tells you.

**No more work that disappears without a word.**

🔧 [Engineering documentation](docs/engineering.md) ｜ 📘 [Full reference](docs/reference.md)

</div>
<!-- repo-state:begin (generated; do not edit) -->
<p align="center"><sub>generation: <code>31a8843</code> (2026-08-29T18:26:24Z) · verify: <a href="https://api.github.com/repos/caty-ai/sitter/commits/main">API HEAD</a> · <a href="./status.json">status.json</a></sub></p>
<!-- repo-state:end -->

---

<div align="center">

![35-second terminal demo. Scene 1: a job handed to sitter finishes normally and the alert file stays empty. Scene 2: a second job goes silent mid-run; sitter detects the stall, stops it, and the ledger lists every event of both runs — the success and the failure side by side.](assets/readme/demo.gif)

[More demos](docs/engineering.md#demos) — stall detection in detail, a zero-dependency variant, and reply tracking.

</div>

---

## Does any of this sound familiar?

If even one of these rings true, sitter is for you.

- The work you asked an AI to do had stopped, and you only noticed hours later
- You sent a question, no answer came, and you forgot you were even waiting
- An overnight job looked fine, but by morning it had not moved an inch
- So many things are running that you cannot tell which ones are still alive

The cause is always the same: **nobody is watching**.
sitter takes that job over completely.

One thing to know up front: sitter watches **work you run in a terminal**. If you only use the ChatGPT or Claude apps, it is not for you.

---

<a id="what"></a>

## What sitter does for you

Four things, in this order.

```mermaid
flowchart LR
    A["1. Hand it over<br/>give sitter your job"] --> B["2. Watch<br/>notice the moment it stalls"]
    B --> C["3. Record<br/>write everything to one notebook"]
    C --> D["4. Tell you<br/>reach out only when it matters"]
```

- 👀 **Watch**

  It stays with the job and keeps checking whether it finished or froze along the way.

- 📝 **Record**

  Everything that happens — started, failed, succeeded — goes into one notebook. It is a plain text file, so you can always go back and see what happened.

- 🔔 **Tell you**

  When something happens that a human should know about, it reaches you the way you chose. By default it appends a line to a memo file; if you would rather get a Slack message or a desktop alert, you say so.

- ⏰ **Chase replies**

  It stops you from asking someone a question and then forgetting about it. Once the deadline passes it reminds you automatically, and in the end it says "this needs a human now".

---

<a id="requirements"></a>

## What you need

Nothing new to buy. Just these three things.

- **A computer**

  Mac, Linux, or Windows (WSL). Your everyday machine is fine.

- **Work you run from a terminal**

  sitter watches jobs you start from a terminal. AI agents such as Claude Code and Codex CLI, tests, builds, data processing — **anything you can launch with a command** qualifies. If you only use the ChatGPT or Claude apps, it is not for you.

- **Dependencies and costs**

  None. No extra software to install, no account to create. (What you pay for the tool being watched — Claude Code, say — is separate.)

For the full table, see [supported environments](docs/engineering.md#compatibility).

---

<a id="start"></a>

## Get started

There are two ways in. If you use an **AI agent that runs in your terminal** (Claude Code, Codex CLI, and the like), asking it is by far the fastest.

> **Note:** Claude Code here means the developer tool that runs in a terminal, not the Claude app. If you only have the app, skip to "Install it yourself" below.

### Let your AI install it

Hand your AI agent the URL of this page and ask:

```text
https://github.com/caty-ai/sitter
Install this with: npm install -g @caty-ai/sitter — then show me how to use it.
(If npm is not available, follow the install steps in the README instead.)
```

Naming the exact command keeps your agent from inventing its own install route: what goes in is the one official npm package, published with provenance, and `npm update -g @caty-ai/sitter` keeps it current. If that does not work, run the steps below yourself.

### Install it yourself

Three steps. Open a terminal first — on a Mac it is in Applications → Utilities → Terminal. On Windows, read [Windows support](docs/engineering.md#windows-support) first. Copy each command, paste it, press Enter.

Inside sitter there is exactly one readable text script. It never asks for your admin password and never changes your system settings.

**The short way (if you have Node.js)**

```sh
npm install -g @caty-ai/sitter
```

If that finishes without an error, skip straight to step 2. It installs the same single script, and `npm update -g @caty-ai/sitter` keeps it up to date. No `npm`? Use the three steps below.

**1. Download it**

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/caty-ai/sitter/main/sitter -o ~/.local/bin/sitter
chmod +x ~/.local/bin/sitter
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc    # zsh — the macOS default
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc   # bash — the Linux and WSL2 default
```

The last three lines let you call the tool by typing `sitter`: the `export` line works in the terminal you have open, and the two `echo` lines make it stick for every terminal after that — one for zsh (what a Mac uses), one for bash (what Linux and WSL2 use). Pasting both is harmless; the one for the shell you don't use is simply never read.

**2. Check that it works**

```sh
sitter run --ledger /tmp/sitter-test.jsonl --on-fail 'cat >&2' -- sh -c 'sleep 3; echo test'
grep -o '"status":"success"' /tmp/sitter-test.jsonl
```

Wait about three seconds; if `"status":"success"` appears, you are installed. It means "the job was watched, and its completion was recorded".

One thing that surprises people: sitter captures the watched job's screen output into `~/.sitter/logs/` instead of your terminal. Silence is normal. To read it, list the files with `ls ~/.sitter/logs/` and open one with `cat ~/.sitter/logs/<filename>`.

**3. Have it watch your own work**

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' -- sh -c 'sleep 30; echo done'
```

Replace everything after `--` with **the command you normally type**. Whenever that work fails or freezes, a note is appended to `~/sitter-alerts.txt`. The record of what happened stays in `~/.sitter/runs.jsonl`. (Both are machine-readable formats, so each line looks like one long string.)

This example only **writes to files** — nothing pops up on screen. To get a desktop notification or a Slack message instead, you change what `--on-fail` runs. If you are not sure how, ask your AI agent for "a sitter notification that shows up in the macOS notification centre" — or, on Linux and WSL2, "a sitter notification through `notify-send`" (on WSL2 without a Linux desktop, ask for a Windows toast instead, e.g. through PowerShell's BurntToast).

**Know what counts as "frozen"**

sitter treats a job as frozen when it produces **no output at all — screen or log — for 15 minutes**, and it stops the job (with a hard limit of four hours). If you are watching work that stays silent until it finishes, tell sitter to use the time limit only. The exact ledger fields and hook values for these outcomes are defined in the [ledger reason contract](docs/reference.md#ledger-reason-contract-run-family).

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' --stall-after 0 --timeout 3600 -- sh -c 'sleep 30; echo done'
```

If the job is silent but a wrapper can cheaply vouch that it is still healthy, keep stall protection with `--heartbeat-file`. Use one heartbeat file per supervised run, never share it between runs, and have the wrapper touch it at least twice as often as `--stall-after` (mtimes are second-granular and sitter polls every 15 seconds).

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' --heartbeat-file ~/.sitter/heartbeats/quiet-worker --stall-after 900 --timeout 3600 -- ./examples/heartbeat-wrapper.sh
```

| Situation | Use |
| --- | --- |
| The job normally streams output but sometimes stays quiet for longer | raise `--stall-after` |
| The job is silent until done and nothing can vouch for it | `--stall-after 0 --timeout <cap>` |
| The job is silent, but something cheap can vouch for it | `--heartbeat-file` with a wrapper; keep both `--stall-after` and `--timeout` |

<details>
<summary>If something goes wrong</summary>

<br>

**It says `sitter: command not found`**

The last three lines of step 1 may not have taken effect. Run this one line, then try again.

```sh
export PATH="$HOME/.local/bin:$PATH"
```

If it still happens, close the terminal and open it again.

**The download says `404`**

Right after a release it can take a moment to propagate. Wait a little and run it again.

</details>

---

<a id="safety"></a>

## Why it is safe to use

"Never act on its own" is the pillar sitter is designed around.

- **It never retries on its own**

  A failed job is retried only when you have explicitly declared it safe to retry. Everything else is reported, not repeated.

- **There is a guard against slips**

  Commands that publish or cost money — `git push`, `npm publish`, `kubectl delete` and the like — are refused before they are ever watched. Be clear about what this is, though: it is **a simple guard against accidents**, not a wall against every dangerous operation (`rm`, for instance, is not covered).

- **Everything is written down**

  Whatever happened, you can trace it in the notebook whenever you want.

- **One line stops all of it**

  This single line stops the watching and any retries.

  ```sh
  touch ~/.sitter/STOP
  ```

---

<a id="more"></a>

## Learn more

Entry points by purpose.

| What you want | Where to look |
| --- | --- |
| How it works, the commands, the design (for engineers) | [docs/engineering.md](docs/engineering.md) |
| The exact contract (every flag, every internal rule) | [docs/reference.md](docs/reference.md) |
| How the design came about | [docs/design-history.md](docs/design-history.md) |
| I want to contribute | [CONTRIBUTING.md](CONTRIBUTING.md) |
| I found a bug or a vulnerability | [SECURITY.md](SECURITY.md) |

<!-- family:generated:family-footer:start -->

---

Part of the **Caty AI family** — open tools for running a family of AI agents. The full map, including modules still being prepared for release, lives in [Family OS](https://github.com/caty-ai/family-os).

| Axis | Module | What it does | State |
| --- | --- | --- | --- |
| Map | [Family OS](https://github.com/caty-ai/family-os) | The map of the whole family — every module, its state, and how they fit | published, MIT |
| Rules | [Family Dev Handbook](https://github.com/caty-ai/family-dev-handbook) | The rules of the road — issues, PRs, worktrees, handoffs, parallel development | published, MIT |
| Vertical · foundation | [Caty Agent Harness](https://github.com/caty-ai/caty-agent-harness) | Task backbone for AI agents — retries, checkpoints, and honest completion | published, MIT |
| Vertical | [context-kit](https://github.com/caty-ai/context-kit) | Six-piece context hygiene kit for one agent — bounded output, delegation briefs, safety guards, recall, worktree snapshots | published, MIT |
| Vertical | [Persona Engine](https://github.com/caty-ai/persona-engine) | Layers relationship and emotion onto an agent's existing persona | published, MIT |
| Vertical | [Persona Growth Loop](https://github.com/caty-ai/persona-growth-loop) | Grows the persona itself — minimal, idempotent proposals | published, MIT |
| Vertical | [X Collector](https://github.com/caty-ai/x-collector) | Turns X and the web into one daily digest — for people and agents | published, MIT |
| Vertical | [Self Growth Loop](https://github.com/caty-ai/self-growth-loop) | Lets an agent grow its own abilities — proposals, governance, adoption records | published, MIT |
| Horizontal · foundation | [Family Memory Architecture](https://github.com/caty-ai/family-memory-architecture) | The memory bus — how the family shares what it knows | published, MIT |
| Horizontal | **Sitter** | Babysits delegated agent runs — watches, keeps evidence, restarts only within declared bounds | published, MIT |
| Horizontal | [Alpha Nightshift](https://github.com/caty-ai/alpha-nightshift) | Nightly autonomous maintenance loop — isolated night lanes behind a deny-by-default guard; humans cherry-pick in the morning | published, MIT |

<!-- family:generated:family-footer:end -->

---

## Project status

[![CI](https://github.com/caty-ai/sitter/actions/workflows/ci.yml/badge.svg)](https://github.com/caty-ai/sitter/actions/workflows/ci.yml)

- **CI** — the badge above is live: every push to main and every pull request runs the full fault-injection suite (the case count is machine-reported by `make test`)
- **Verified environments** — Ubuntu gates every pull request; macOS runs on every push to main; Windows (Git Bash) is a best-effort lane
- **Maturity** — v0.3.1; the four v0 verbs (`run` / `expect` / `ack` / `sweep`) are spec-frozen in docs/requirements-v0.md, and `ask` / `watch` are pinned by docs/specs/prd-v0.2-ask-watch.md (audited in v0.2.0)
- **Known limitations** — the denylist is an accident guard, not a security wall; retries happen only for jobs you explicitly declared idempotent

---

## License

[MIT](LICENSE) © 2026 Sho Jikumaru

We want anyone to use it, change it, and build it into their own tools and services, so it is MIT. Keep the copyright notice and nothing else is restricted — commercial use included, modified copies included.

---

<div align="center">

**One bash file** ｜ **Any CLI agent** ｜ **Zero dependencies, free**

</div>
