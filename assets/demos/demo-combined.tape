# Run from the repo root: vhs assets/demos/demo-combined.tape
# Requires: vhs, jq. Poll/grace are shortened so the demo fits in ~35s;
# production defaults are 15 min stall / 10 s grace.
Output assets/readme/demo.gif

Set Theme "Catppuccin Mocha"
Set FontSize 18
Set Width 1080
Set Height 560
Set Padding 24
Set TypingSpeed 35ms
Set PlaybackSpeed 1.25

Hide
Type `export SITTER_POLL_INTERVAL=2 SITTER_HOME=/tmp/demo/.sitter PATH="$PWD:$PATH" PS1='❯ '`
Enter
Type `mkdir -p /tmp/demo && cp assets/demos/agents/nightly-report assets/demos/agents/refactor-agent /tmp/demo/ && cd /tmp/demo && rm -rf runs.jsonl alerts.txt .sitter && touch alerts.txt && clear`
Enter
Sleep 500ms
Show

Type `# ── 1. the job finishes fine — sitter stays quiet ──`
Sleep 500ms
Enter
Type `sitter run --ledger runs.jsonl --on-fail 'cat >> alerts.txt' --stall-after 5 --grace 2 -- ./nightly-report`
Sleep 500ms
Enter

# nightly-report completes in ~2s; sitter exits 0
Sleep 6s

Type `wc -l alerts.txt`
Sleep 400ms
Enter
Sleep 1500ms

Type `clear`
Enter

Type `# ── 2. the job freezes — sitter catches it ──`
Sleep 500ms
Enter
Type `sitter run --ledger runs.jsonl --on-fail 'cat >> alerts.txt' --stall-after 5 --grace 2 -- ./refactor-agent`
Sleep 500ms
Enter

# refactor-agent goes silent; sitter detects the stall and stops it (~9-12s)
Sleep 14s

Type `# stopped, alerted, and written down — nothing disappears silently`
Sleep 500ms
Enter
Type `jq -c '{event, status, detail}' runs.jsonl`
Sleep 400ms
Enter
Sleep 6s
