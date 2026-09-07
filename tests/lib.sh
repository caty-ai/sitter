#!/usr/bin/env bash
# Shared, dependency-free helpers for the sitter integration suite.

set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SITTER="$TEST_ROOT/sitter"
# shellcheck disable=SC2034 # sourced by tests/run.sh
FIXTURE="$TEST_ROOT/tests/fixtures/fake-worker.sh"

assert_exit() {
  local expected=$1 actual
  shift
  set +e
  "$@"
  actual=$?
  set -e
  [[ $actual -eq $expected ]] || {
    printf 'expected exit %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
    return 1
  }
}

# Ledger records deliberately put event immediately before status.  Checking
# that fixed key order makes this a useful guard against accidental schema drift.
assert_event_seq() {
  local ledger=$1 event line found=0 after=0
  shift
  for event in "$@"; do
    while IFS=: read -r line _; do
      if ((line > after)); then found=$line; break; fi
    done < <(grep -nF "\"event\":\"$event\",\"status\":" "$ledger" || true)
    ((found > after)) || {
      printf 'missing ordered event %s in %s\n' "$event" "$ledger" >&2
      return 1
    }
    after=$found
    found=0
  done
}

assert_spy_count() {
  local expected=$1 spy=$2 actual=0
  [[ -f $spy ]] && actual=$(grep -c 'SITTER_REASON' "$spy" || true)
  [[ $actual -eq $expected ]] || {
    printf 'expected %s spy calls, got %s in %s\n' "$expected" "$actual" "$spy" >&2
    return 1
  }
}

assert_json_valid() {
  local ledger=$1
  if ! command -v python3 >/dev/null 2>&1; then
    if [[ ${CI:-} == true ]]; then
      printf 'assert_json_valid requires python3 in CI\n' >&2
      return 1
    fi
    if [[ ${ASSERT_JSON_VALID_PYTHON3_SKIP_REPORTED:-false} != true ]]; then
      printf 'SKIP assert_json_valid: python3 not found\n' >&2
      ASSERT_JSON_VALID_PYTHON3_SKIP_REPORTED=true
    fi
    return 0
  fi
  python3 - "$ledger" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as records:
    for record in records:
        json.loads(record)
PY
}

make_spy() {
  SPY="$CASE_DIR/spy.sh"
  cat >"$SPY" <<'EOF'
#!/usr/bin/env bash
cat >>"$SPY_FILE"
printf '\n' >>"$SPY_FILE"
EOF
  chmod +x "$SPY"
}

run_case() {
  local name=$1
  shift
  SITTER_HOME="$CASE_DIR/home-$name" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/$name.spy" \
    "$SITTER" run --ledger "$CASE_DIR/$name.jsonl" --on-fail "$SPY" \
    --stall-after 2 --timeout 20 --grace 0 "$@"
}

run_test() {
  local name=$1
  CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sitter-test.XXXXXX")
  make_spy
  local result
  set +e
  ( set -e; "$name" )
  result=$?
  set -e
  if ((result == 0)); then
    printf 'PASS %s\n' "$name"
    rm -rf "$CASE_DIR"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s (artifacts: %s)\n' "$name" "$CASE_DIR" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Frozen baseline: 77b3bd9 (pre-single-pass implementation).
load_reference_replay() {
  local definitions="$CASE_DIR/reference-functions.sh"
  awk '
    /^expect_replay_line\(\)/ {copy=1; sub(/expect_replay_line/, "reference_expect_replay_line")}
    /^valid_reply_path\(\)/ {copy=1; sub(/valid_reply_path/, "reference_valid_reply_path")}
    copy {gsub(/valid_reply_path /, "reference_valid_reply_path "); print}
    copy && /^}/ {copy=0}
  ' "$TEST_ROOT/tests/fixtures/sitter.baseline" >"$definitions"
  # shellcheck source=/dev/null
  source "$definitions"
}

# Load definitions without running the CLI dispatcher, in the caller's subshell.
load_sitter_functions() {
  local definitions="$CASE_DIR/sitter-functions.sh"
  awk '/^\[\[ \$# -ge 1 \]\]/ {exit} {print}' "$SITTER" >"$definitions"
  # shellcheck source=/dev/null
  source "$definitions"
  load_reference_replay
}

assert_replay_equivalent() {
  local line=$1 label=$2 field old_rc=0 new_rc=0 i=0
  local fields=(REPLAY_ID REPLAY_TS REPLAY_EVENT REPLAY_STATE REPLAY_TO REPLAY_TEXT REPLAY_SLA
    REPLAY_SCHEMA REPLAY_REPLY_FILE REPLAY_REPLY_BYTES REPLAY_REPLY_SHA)
  local old_values=()
  for field in "${fields[@]}"; do printf -v "$field" 'sentinel:%s' "$field"; done
  # Isolate the baseline's unexported LC_ALL leak from the production call.
  local value
  while IFS= read -r -d '' value; do old_values+=("$value"); done < <(
    reference_expect_replay_line "$line" 2>/dev/null || old_rc=$?
    printf '%s\0' "$old_rc"
    for field in "${fields[@]}"; do printf '%s\0' "${!field}"; done
  )
  old_rc=${old_values[0]}
  old_values=("${old_values[@]:1}")
  for field in "${fields[@]}"; do printf -v "$field" 'sentinel:%s' "$field"; done
  expect_replay_line "$line" || new_rc=$?
  [[ $old_rc -eq $new_rc ]] || { printf 'replay rc mismatch %s: %s / %s\n' "$label" "$old_rc" "$new_rc" >&2; return 1; }
  for field in "${fields[@]}"; do
    [[ ${old_values[i]} == "${!field}" ]] || {
      printf 'replay %s mismatch %s: %q / %q\n' "$field" "$label" "${old_values[i]}" "${!field}" >&2
      return 1
    }
    i=$((i + 1))
  done
}
