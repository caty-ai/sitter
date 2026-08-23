# Run from the repo root: vhs assets/demos/demo-nodeps.tape
# Requires: vhs only (the demo itself uses cat/grep — no jq).
# Poll/grace are shortened so the demo fits in ~30s;
# production defaults are 15 min stall / 10 s grace.
Output assets/demos/demo-nodeps.gif

Set Theme "Catppuccin Mocha"
Set FontSize 18
Set Width 1080
Set Height 560
Set Padding 24
Set TypingSpeed 40ms

Hide
Type `export SITTER_POLL_INTERVAL=2 SITTER_HOME=/tmp/demo/.sitter PATH="$PWD:$PATH" PS1='❯ '`
Enter
Type `mkdir -p /tmp/demo && cp assets/demos/agents/my-agent /tmp/demo/ && cd /tmp/demo && rm -rf runs.jsonl alerts.txt .sitter && touch alerts.txt && clear`
Enter
Sleep 500ms
Show

Type `# hand a long-running job to sitter — it watches for stalls`
Sleep 600ms
Enter
Type `sitter run --ledger runs.jsonl --on-fail 'cat >> alerts.txt' --stall-after 5 --grace 2 -- ./my-agent`
Sleep 800ms
Enter

# my-agent goes silent after ~1s; sitter detects the stall and stops it (~9-12s)
Sleep 14s

Type `# the job froze — the alert is plain text, no extra tools needed`
Sleep 600ms
Enter
Type `cat alerts.txt`
Sleep 500ms
Enter
Sleep 2s

Type `# the ledger keeps every event — grep is enough`
Sleep 600ms
Enter
Type `grep --color '"status":"killed"' runs.jsonl`
Sleep 500ms
Enter
Sleep 5s
