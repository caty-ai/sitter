#!/usr/bin/env bash
set -euo pipefail

# The parent retains bash's default TERM behaviour while its descendant
# deliberately ignores TERM.  This isolates the group-KILL escalation case.
perl -e '$SIG{TERM} = "IGNORE"; sleep 300' "${SITTER_TEST_MARKER:?missing marker}" &
pid=$!
printf '%s\n' "$pid" >"${SITTER_GRANDCHILD_PID_FILE:?missing pid file}"
wait "$pid"
