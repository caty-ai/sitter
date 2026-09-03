#!/usr/bin/env bash
# heartbeat-wrapper.sh — worker-owned liveness heartbeat (see ADR-0003).
#
# Supervise this wrapper when a worker is silent by design but a cheap,
# bounded check can vouch that its backend is still alive:
#
#   sitter run --ledger ~/.sitter/runs.jsonl --on-fail ./notify.sh \
#              --heartbeat-file ~/.sitter/heartbeats/quiet-worker \
#              --stall-after 900 --timeout 1500 \
#              -- ./examples/heartbeat-wrapper.sh --some-worker-flag ...
#
# Customize worker_cmd/vouch_cmd and the HB_* knobs below. A successful vouch
# means only "the backend is up." It can keep a hung turn alive until
# --timeout; that is the #10 trade, and sitter deliberately does not police it.
set -eu

# --- worker-specific knobs (edit these) -------------------------------------
worker_cmd() { your-worker "$@"; }

# Keep this a single process so the bounded kill below is reliable.
vouch_cmd() { exec your-worker --ping; }

HB_INTERVAL="${HB_INTERVAL:-60}"  # seconds between successful-vouch attempts
HB_TIMEOUT="${HB_TIMEOUT:-45}"   # seconds before the vouch itself times out
# ----------------------------------------------------------------------------

case "$HB_INTERVAL$HB_TIMEOUT" in
  *[!0-9]*) echo "heartbeat-wrapper: HB_INTERVAL/HB_TIMEOUT must be non-negative integers" >&2; exit 2 ;;
esac
[ "$HB_INTERVAL" -gt 0 ] || {
  echo "heartbeat-wrapper: HB_INTERVAL must be greater than zero" >&2
  exit 2
}
[ -n "${SITTER_HEARTBEAT_FILE:-}" ] || {
  echo "heartbeat-wrapper: SITTER_HEARTBEAT_FILE is required" >&2
  exit 2
}

worker_pid=''
heartbeat_pid=''

# shellcheck disable=SC2329 # invoked by EXIT/signal traps
cleanup() {
  if [ -n "$heartbeat_pid" ] && kill -0 "$heartbeat_pid" 2>/dev/null; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
  fi
  if [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null; then
    kill "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  fi
}

heartbeat_loop() {
  vouch_pid=''
  delay_pid=''

  # shellcheck disable=SC2329 # invoked by the heartbeat-loop signal trap
  stop_loop_children() {
    if [ -n "$vouch_pid" ] && kill -0 "$vouch_pid" 2>/dev/null; then
      kill "$vouch_pid" 2>/dev/null || true
      wait "$vouch_pid" 2>/dev/null || true
    fi
    if [ -n "$delay_pid" ] && kill -0 "$delay_pid" 2>/dev/null; then
      kill "$delay_pid" 2>/dev/null || true
      wait "$delay_pid" 2>/dev/null || true
    fi
  }
  trap 'stop_loop_children; exit 0' HUP INT TERM

  while kill -0 "$worker_pid" 2>/dev/null; do
    vouch_cmd >/dev/null 2>&1 &
    vouch_pid=$!
    waited=0
    vouch_timed_out=false
    while kill -0 "$vouch_pid" 2>/dev/null; do
      if [ "$waited" -ge "$HB_TIMEOUT" ]; then
        kill "$vouch_pid" 2>/dev/null || true
        wait "$vouch_pid" 2>/dev/null || true
        vouch_timed_out=true
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    if [ "$vouch_timed_out" = true ] || kill -0 "$vouch_pid" 2>/dev/null; then
      vouch_status=1
    elif wait "$vouch_pid"; then
      vouch_status=0
    else
      vouch_status=$?
    fi
    vouch_pid=''

    if [ "$vouch_status" -eq 0 ] && kill -0 "$worker_pid" 2>/dev/null; then
      if ! touch -- "$SITTER_HEARTBEAT_FILE"; then
        echo "heartbeat-wrapper: cannot touch heartbeat file" >&2
        kill "$worker_pid" 2>/dev/null || true
        return 1
      fi
    fi

    sleep "$HB_INTERVAL" &
    delay_pid=$!
    wait "$delay_pid" 2>/dev/null || true
    delay_pid=''
  done
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

worker_cmd "$@" &
worker_pid=$!
heartbeat_loop &
heartbeat_pid=$!

if wait "$worker_pid"; then
  worker_status=0
else
  worker_status=$?
fi
worker_pid=''

kill "$heartbeat_pid" 2>/dev/null || true
wait "$heartbeat_pid" 2>/dev/null || true
heartbeat_pid=''
trap - EXIT HUP INT TERM
exit "$worker_status"
