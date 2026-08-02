#!/usr/bin/env bash
# Example only: a deliberately tiny --on-fail adapter that appends escalation
# events to a drop file watched by some other notifier. Replace the path (and
# the line format) with whatever your inbox/notifier expects.
set -eu
: "${DROP_FILE:=/path/to/notifier-inbox.drop}"

case "${SITTER_EVENT:-}:${SITTER_REASON:-}" in
  nudge:sla_breach|awaiting_human:awaiting_human)
    printf 'event=%s reason=%s text=%s\n' \
      "${SITTER_EVENT:-}" "${SITTER_REASON:-}" "${SITTER_TEXT:-}" >>"$DROP_FILE"
    ;;
esac
