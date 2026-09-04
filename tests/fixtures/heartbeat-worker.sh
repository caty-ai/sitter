#!/usr/bin/env bash
set -euo pipefail

mode=${HB_MODE:-touching}
heartbeat=${SITTER_HEARTBEAT_FILE:-}

file_mtime() {
  local value
  if value=$(stat -f %m "$1" 2>/dev/null); then
    printf '%s\n' "$value"
  else
    stat -c %Y "$1"
  fi
}

case $mode in
  touching)
    count=0
    while ((count < 6)); do
      touch -- "$heartbeat"
      sleep 1
      count=$((count + 1))
    done
    ;;
  frozen)
    sleep 10
    ;;
  delete)
    count=0
    while ((count < 4)); do
      touch -- "$heartbeat"
      sleep 1
      count=$((count + 1))
    done
    rm -- "$heartbeat"
    sleep 10
    ;;
  symlink_swap)
    count=0
    while ((count < 4)); do
      touch -- "$heartbeat"
      sleep 1
      count=$((count + 1))
    done
    rm -- "$heartbeat"
    ln -s "$HB_LINK_TARGET" "$heartbeat"
    sleep 10
    ;;
  capture_env)
    printf '%s\n' "$heartbeat" >"$HB_CAPTURE"
    ;;
  log_advancing)
    count=0
    while ((count < 6)); do
      printf 'tick %s\n' "$count"
      sleep 1
      count=$((count + 1))
    done
    ;;
  retry_baseline)
    count=0
    [[ -f $HB_STATE ]] && count=$(<"$HB_STATE")
    count=$((count + 1))
    printf '%s\n' "$count" >"$HB_STATE"
    file_mtime "$heartbeat" >"$HB_STATE.mtime.$count"
    if ((count == 1)); then
      exit 7
    fi
    sleep 2
    ;;
  swap_before_retry)
    count=0
    [[ -f $HB_STATE ]] && count=$(<"$HB_STATE")
    count=$((count + 1))
    printf '%s\n' "$count" >"$HB_STATE"
    if ((count == 1)); then
      rm -- "$heartbeat"
      ln -s "$HB_LINK_TARGET" "$heartbeat"
      exit 7
    fi
    ;;
  fail)
    exit 9
    ;;
  *)
    exit 64
    ;;
esac
