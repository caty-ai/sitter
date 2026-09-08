#!/usr/bin/env bash
# Deterministic replay history; default mode deliberately includes invalid JSON.
# --production-shape uses valid run/foreign JSON before the same final six asks.
# Three reused ids keep the baseline's candidate count bounded. The last six
# records leave one due, one acked and one quarantined, at every size >= 30.
set -euo pipefail

usage() {
  printf 'usage: %s [--production-shape] <lines> <out>\n' "$0" >&2
  exit 2
}
production=0
if [[ ${1:-} == --production-shape ]]; then
  production=1
  shift
fi
[[ $# -eq 2 && $1 =~ ^[0-9]+$ ]] || usage
if [[ $production == 1 ]]; then
  LC_ALL=C awk -v count="$1" 'BEGIN { exit !(count >= 6) }' || usage
fi
LC_ALL=C awk -v count="$1" -v production="$production" '
function record(schema, id, event, state, extra, numeric, text) {
  if (numeric == "") numeric="\"sla_s\":1,\"nudges\":0"
  if (text == "") text="進捗確認 café"
  printf "{\"ts\":\"2000-01-01T00:00:00.000Z\",\"event\":\"%s\",\"state\":\"%s\",\"schema\":\"sitter.v%s\",\"expect_id\":\"%s\",\"to\":\"worker\",\"text\":\"%s\",%s", event,state,schema,id,text,numeric
  if (schema == 1) printf ",\"reply_file\":\"/sitter-benchmark-missing/reply.txt\",\"reply_bytes\":null,\"reply_sha256\":null"
  printf "%s}\n",extra
}
BEGIN {
  for (i=1; i<=count; i++) {
    if ((production || count>=30) && i>count-6) {
      final=i-(count-6)
      if (final==1) record(1,"due","expect","pending")
      if (final==2) record(0,"done","expect","pending")
      if (final==3) record(0,"done","ack","acked")
      if (final==4) record(0,"burned","expect","pending")
      if (final==5) record(0,"burned","quarantine","quarantined")
      if (final==6) record(0,"due","refused","pending")
      continue
    }
    if (production) {
      # Five run rows followed by three foreign rows per eight-row block.
      if ((i-1)%8 < 5) {
        event=(run_index%3==0 ? "start" : (run_index%3==1 ? "heartbeat" : "end"))
        run_index++
        status=(event=="end" ? "success" : "running")
        printf "{\"ts\":\"2000-01-01T00:00:00.000Z\",\"event\":\"%s\",\"status\":\"%s\",\"project\":\"collector\",\"agent\":\"benchmark-worker\",\"task\":\"Review scheduled collection and report completion\",\"attempt\":1,\"detail\":\"child progress recorded for deterministic replay benchmark\",\"sessionId\":\"\",\"cwd\":\"/workspace/collector\",\"schema\":\"sitter.v0\",\"event_id\":\"e-bench-%d\",\"run_id\":\"sitter-bench-%d\",\"exit_code\":0,\"log_path\":\"/workspace/logs/sitter-bench.log\",\"stall_s\":0,\"reason\":\"\",\"retries\":0,\"cooldown_s\":0,\"idempotent\":false,\"detail_truncated\":false,\"hook_exit_code\":null}\n",event,status,i,i
      } else {
        printf "{\"ts\":\"2000-01-01T00:00:00.000Z\",\"event\":\"end\",\"status\":\"completed\",\"detail\":\"{\\\"isAsync\\\":true,\\\"status\\\":\\\"async_launched\\\",\\\"agentId\\\":\\\"agent-bench-%d\\\",\\\"description\\\":\\\"録画の終盤を確認し、進捗と次の対応を整理する café\\\",\\\"resolvedModel\\\":\\\"benchmark-model\\\",\\\"prompt\\\":\\\"Review the final recording segment, summarize completed work and pending questions, and prepare a concise handoff. Keep the original observations separate from interpretation. 次の担当者へ確認事項と作業結果を引き継いでください。\\\"}\",\"sessionId\":\"session-bench-%d\",\"cwd\":\"/workspace/mission-control\",\"project\":\"mission-control\",\"agent\":\"foreign-writer\",\"task\":\"Summarize recording and prepare the next review\"}\n",i,i
      }
      continue
    }
    slot=(i-1)%24
    if (slot==0) record(0,"due","expect","pending")
    else if (slot==1) record(0,"due","nudge","nudged1")
    else if (slot==2) record(0,"due","nudge","nudged2")
    else if (slot==3) record(0,"done","expect","pending")
    else if (slot==4) record(0,"done","ack","acked")
    else if (slot==5) record(0,"burned","quarantine","quarantined")
    else if (slot==6) record(1,"due","ask_prepare","prepared")
    else if (slot==7) record(1,"due","ask_send_failed","send_failed")
    else if (slot==8) record(1,"due","expect","pending")
    else if (slot==9) record(1,"done","refused","acked")
    else if (slot==10) record(0,"ignored","expect","pending",",\"ts\":\"2000-01-02T00:00:00.000Z\",\"expect_id\":\"due\",\"sla_s\":2,\"nudges\":1","","escaped " sprintf("%c%c",92,34) "quote" sprintf("%c%c",92,34) " 日本語")
    else if (slot==11) record(0,"done","refused","acked","","\"sla_s\":12junk,\"nudges\":03junk")
    else if (slot==12) record(1,"due","expect","pending","","\"sla_s\":12junk,\"nudges\":0")
    else if (slot==13) record(1,"due","expect","unknown")
    else if (slot==15) record(0,"invalid-byte","expect","pending","","",sprintf("bad%c",255))
    else if (slot==14) print "{\"schema\":\"sitter.v1\",\"expect_id\":\"\"}"
    else printf "{\"ts\":\"2000-01-01T00:00:00.000Z\",\"event\":\"run\",\"status\":\"ok\",\"schema\":\"sitter.v0\",\"attempt\":%d,\"detail\":\"completed\"}\n",i
  }
}' >"$2"
