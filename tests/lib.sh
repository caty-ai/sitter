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
