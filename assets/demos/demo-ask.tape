# Run from the repo root: vhs assets/demos/demo-ask.tape
# Requires: vhs, jq. The 5-second SLA is demo tuning; pick your own in real use.
# alpha and cero are two AI agents of the caty-ai family, playing themselves.
Output assets/demos/demo-ask.gif

Set Theme "Catppuccin Mocha"
Set FontSize 18
Set Width 1080
Set Height 560
Set Padding 24
Set TypingSpeed 35ms
Set PlaybackSpeed 1.25

Hide
Type `export PATH="$PWD:$PATH" PS1='alpha❯ '`
Enter
Type `mkdir -p /tmp/demo-ask && cp assets/demos/agents/send-to-cero /tmp/demo-ask/ && cd /tmp/demo-ask && rm -rf runs.jsonl alerts.txt reply.txt && touch alerts.txt && chmod +x send-to-cero && clear`
Enter
Sleep 500ms
Show

Type `# alpha asks cero a question — sitter tracks the reply from the moment it is sent`
Sleep 500ms
Enter
Type `sitter ask --ledger runs.jsonl --to cero --sla 5 --id pr-42-review \`
Enter
Type `  --reply-file /tmp/demo-ask/reply.txt --text "cero, can you review PR #42?" \`
Enter
Type `  -- ./send-to-cero`
Sleep 500ms
Enter
Sleep 4s

Type `# the deadline passes with no answer — the periodic sweep nudges for you`
Sleep 500ms
Enter
Type `sitter sweep --once --ledger runs.jsonl --on-fail 'cat >> alerts.txt'`
Sleep 400ms
Enter
Sleep 3s
Type `jq -c '{SITTER_EVENT, SITTER_REASON, SITTER_TEXT}' alerts.txt`
Sleep 400ms
Enter
Sleep 2s

Type `# cero answers into the agreed reply file, from his own machine`
Sleep 500ms
Enter
Type `echo "LGTM — approved. merging now  (cero)" > /tmp/demo-ask/reply.txt`
Sleep 400ms
Enter

Type `# watch notices the reply and clears the pending entry by itself`
Sleep 500ms
Enter
Type `sitter watch --once --ledger runs.jsonl`
Sleep 400ms
Enter
Sleep 1s

Type `jq -c '{event, to, state}' runs.jsonl`
Sleep 400ms
Enter
Sleep 6s
