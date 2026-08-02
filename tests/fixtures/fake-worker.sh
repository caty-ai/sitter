#!/usr/bin/env bash
set -euo pipefail
mode=${FW_MODE:-ok}
state=${FW_STATE:-}
tick=${FW_TICK:-1}
case $mode in
  ok) printf 'worker start\n'; sleep "$tick"; printf 'worker end\n' ;;
  slow) printf 'worker start\n'; sleep "$tick"; printf 'worker tick\n'; sleep "$tick"; printf 'worker end\n' ;;
  hang) printf 'worker start\n'; while :; do sleep 1; done ;;
  flaky)
    count=0; [[ -f $state ]] && count=$(cat "$state")
    [[ $count =~ ^[0-9]+$ ]] || { printf 'invalid FW_STATE counter\n' >&2; exit 65; }
    count=$((count + 1)); printf '%s\n' "$count" >"$state"
    printf 'worker attempt %s\n' "$count"
    if ((count <= ${FW_FAIL_TIMES:-1})); then exit 7; fi
    printf 'worker end\n'
    ;;
  flaky_hang)
    count=0; [[ -f $state ]] && count=$(cat "$state")
    [[ $count =~ ^[0-9]+$ ]] || { printf 'invalid FW_STATE counter\n' >&2; exit 65; }
    count=$((count + 1)); printf '%s\n' "$count" >"$state"
    printf 'worker attempt %s\n' "$count"
    if ((count <= ${FW_FAIL_TIMES:-1})); then while :; do sleep 1; done; fi
    printf 'worker end\n'
    ;;
  fail) printf 'worker failed\n'; exit "${FW_EXIT:-9}" ;;
  silent_death) printf 'worker start\n'; kill -9 $$ ;;
  *) exit 64 ;;
esac
