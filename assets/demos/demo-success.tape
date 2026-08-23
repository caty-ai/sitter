# Run from the repo root: vhs assets/demos/demo-success.tape
# Requires: vhs, jq. Poll/grace are shortened so the demo fits in ~20s;
# production defaults are 15 min stall / 10 s grace.
Output assets/demos/demo-success.gif

Set Theme "Catppuccin Mocha"
Set FontSize 18
Set Width 1080
Set Height 560
Set Padding 24
Set TypingSpeed 40ms

Hide
Type `export SITTER_POLL_INTERVAL=2 SITTER_HOME=/tmp/demo/.sitter PATH="$PWD:$PATH" PS1='❯ '`
Enter
Type `mkdir -p /tmp/demo && cp assets/demos/agents/my-agent-ok /tmp/demo/my-agent && cd /tmp/demo && rm -rf runs.jsonl alerts.txt .sitter && touch alerts.txt && clear`
Enter
Sleep 500ms
Show

Type `# when the job finishes fine, sitter stays quiet`
Sleep 600ms
Enter
Type `sitter run --ledger runs.jsonl --on-fail 'cat >> alerts.txt' --stall-after 5 --grace 2 -- ./my-agent`
Sleep 800ms
Enter

# my-agent completes normally in ~2s; sitter exits 0 (~5s)
Sleep 7s

Type `# no alert — nothing needed your attention`
Sleep 600ms
Enter
Type `wc -l alerts.txt`
Sleep 500ms
Enter
Sleep 1500ms

Type `# but the ledger still remembers it went well`
Sleep 600ms
Enter
Type `jq -c '{event, status, reason}' runs.jsonl`
Sleep 500ms
Enter
Sleep 5s
