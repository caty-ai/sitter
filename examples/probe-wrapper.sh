#!/usr/bin/env bash
# probe-wrapper.sh — generic worker-owned health probe (see docs/adr/0001).
#
# sitter deliberately has no --probe flag: worker-specific health knowledge
# belongs in the wrapper that owns the worker, not in the supervisor. This
# template shows the supported pattern for workers that can be "alive but
# silent" (non-streaming CLIs that print nothing until completion), where
# log-mtime stall detection would misfire.
#
# Supervise the wrapper, not the raw worker, and disable the mtime signal in
# favor of an absolute cap:
#
#   sitter run --ledger ~/.sitter/runs.jsonl --on-fail ./notify.sh \
#              --stall-after 0 --timeout 1500 \
#              -- ./examples/probe-wrapper.sh --some-worker-flag ...
#
# Customize worker_cmd/probe_cmd and the PROBE_* knobs for your worker. The
# probe must be cheap, read-only, and answer one question: is the backend
# alive enough that retrying is worthwhile?
set -eu

# --- worker-specific knobs (edit these) -------------------------------------
# The real worker invocation. "$@" passes through whatever sitter was given.
worker_cmd() { your-worker "$@"; }

# A cheap liveness probe for the same backend the worker talks to.
# Examples: `your-worker --version`, `curl -fsS --max-time 45 "$API/health"`.
# Keep it a single process; `exec` makes the timeout kill below reliable.
probe_cmd() { exec your-worker --ping; }

PROBE_TIMEOUT="${PROBE_TIMEOUT:-45}"   # seconds before the probe itself counts as dead
PROBE_RETRY="${PROBE_RETRY:-1}"        # bounded worker retries when the probe says alive
PROBE_COOLDOWN="${PROBE_COOLDOWN:-5}"  # seconds between worker retries
# ----------------------------------------------------------------------------

case "$PROBE_TIMEOUT$PROBE_RETRY$PROBE_COOLDOWN" in
  *[!0-9]*) echo "probe-wrapper: PROBE_TIMEOUT/PROBE_RETRY/PROBE_COOLDOWN must be non-negative integers" >&2; exit 2 ;;
esac

run_probe() {
  # Bound the probe so a hanging health endpoint cannot hang the wrapper.
  # Note: the timeout kill below targets the probe process only. If your
  # probe_cmd spawns children (pipelines, curl via a helper script), run it
  # under `setsid` and kill the process group instead, or keep it to a
  # single process as in the examples above.
  probe_cmd 2>/dev/null &
  probe_pid=$!
  waited=0
  while kill -0 "$probe_pid" 2>/dev/null; do
    if [ "$waited" -ge "$PROBE_TIMEOUT" ]; then
      kill "$probe_pid" 2>/dev/null || true
      wait "$probe_pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$probe_pid"
}

attempt=0
while :; do
  attempt=$((attempt + 1))
  status=0
  worker_cmd "$@" || status=$?
  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  if [ "$attempt" -gt "$PROBE_RETRY" ]; then
    echo "probe-wrapper: worker failed (exit $status), retry budget spent" >&2
    exit "$status"
  fi

  # Worker failed: ask the backend whether retrying is worthwhile.
  if run_probe; then
    echo "probe-wrapper: worker failed (exit $status) but backend answers; retrying in ${PROBE_COOLDOWN}s ($attempt/$PROBE_RETRY)" >&2
    sleep "$PROBE_COOLDOWN"
    continue
  fi

  # Backend is dead — fail fast so sitter records a terminal failure now
  # instead of burning the whole --timeout window.
  echo "probe-wrapper: backend probe dead after worker exit $status; failing fast" >&2
  exit "$status"
done
