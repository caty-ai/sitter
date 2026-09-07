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

# Frozen sed-based oracle from origin/main (77b3bd9), kept verbatim except its name.
# shellcheck disable=SC2034 # REPLAY globals are inspected indirectly and by tests/run.sh
reference_expect_replay_line() {
  local line=$1 id ts state event to text_value sla nudges schema reply_file reply_bytes reply_sha reply_sha_field
  if [[ $line == *'"schema":"sitter.v0"'* && $line == *'"expect_id":'* ]]; then
    schema=sitter.v0
  elif [[ $line == *'"schema":"sitter.v1"'* ]]; then
    schema=sitter.v1
  else
    return 0
  fi
  id=$(printf '%s\n' "$line" | sed -n 's/.*"expect_id":"\([^"]*\)".*/\1/p')
  [[ -n $id ]] || return 2
  if ! valid_expect_id "$id"; then
    [[ $schema == sitter.v1 ]] && return 2
    return 0
  fi
  ts=$(printf '%s\n' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
  event=$(printf '%s\n' "$line" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
  state=$(printf '%s\n' "$line" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
  [[ -n $ts && -n $state && -n $event ]] || return 2
  if [[ $schema == sitter.v0 ]]; then
    case $state in pending|nudged1|nudged2|awaiting_human|acked|quarantined) ;; *) return 2 ;; esac
  else
    case $state in pending|acked|prepared|send_failed) ;; *) return 2 ;; esac
  fi
  to=$(printf '%s\n' "$line" | sed -n 's/.*"to":"\([^"]*\)".*/\1/p')
  text_value=$(printf '%s\n' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  if [[ $schema == sitter.v1 ]]; then
    sla=$(printf '%s\n' "$line" | sed -n 's/.*"sla_s":\([^,}]*\).*/\1/p')
    nudges=$(printf '%s\n' "$line" | sed -n 's/.*"nudges":\([^,}]*\).*/\1/p')
  else
    sla=$(printf '%s\n' "$line" | sed -n 's/.*"sla_s":\([0-9][0-9]*\).*/\1/p')
    nudges=$(printf '%s\n' "$line" | sed -n 's/.*"nudges":\([0-9][0-9]*\).*/\1/p')
  fi
  is_uint "$sla" && is_uint "$nudges" || return 2
  reply_file='' reply_bytes=null reply_sha=null
  if [[ $schema == sitter.v1 ]]; then
    case "$event:$state" in
      ask_prepare:prepared|expect:pending|ask_send_failed:send_failed|refused:acked) ;;
      *) return 2 ;;
    esac
    reply_file=$(printf '%s\n' "$line" | sed -n 's/.*"reply_file":"\([^"]*\)".*/\1/p')
    [[ -n $reply_file ]] && valid_reply_path "$reply_file" || return 2
    reply_bytes=$(printf '%s\n' "$line" | sed -n 's/.*"reply_bytes":\([^,}]*\).*/\1/p')
    [[ $reply_bytes == null ]] || is_uint "$reply_bytes" || return 2
    reply_sha_field=$(printf '%s\n' "$line" | sed -n 's/.*"reply_sha256":\([^,}]*\).*/\1/p')
    if [[ $reply_sha_field == null ]]; then
      reply_sha=null
    else
      [[ $reply_sha_field =~ ^\"[0-9a-f]{64}\"$ ]] || return 2
      reply_sha=${reply_sha_field:1:${#reply_sha_field}-2}
    fi
    if [[ $reply_bytes == null && $reply_sha != null ]] || [[ $reply_bytes != null && $reply_sha == null ]]; then return 2; fi
  fi
  REPLAY_ID=$id REPLAY_TS=$ts REPLAY_EVENT=$event REPLAY_STATE=$state REPLAY_TO=$to REPLAY_TEXT=$text_value REPLAY_SLA=$sla
  REPLAY_SCHEMA=$schema REPLAY_REPLY_FILE=$reply_file REPLAY_REPLY_BYTES=$reply_bytes REPLAY_REPLY_SHA=$reply_sha
  return 1
}

# Load definitions without running the CLI dispatcher, in the caller's subshell.
load_sitter_functions() {
  local definitions="$CASE_DIR/sitter-functions.sh"
  awk '/^\[\[ \$# -ge 1 \]\]/ {exit} {print}' "$SITTER" >"$definitions"
  # shellcheck source=/dev/null
  source "$definitions"
}

assert_replay_equivalent() {
  local line=$1 label=$2 field old_rc=0 new_rc=0 i=0
  local fields=(REPLAY_ID REPLAY_TS REPLAY_EVENT REPLAY_STATE REPLAY_TO REPLAY_TEXT REPLAY_SLA
    REPLAY_SCHEMA REPLAY_REPLY_FILE REPLAY_REPLY_BYTES REPLAY_REPLY_SHA)
  local old_values=()
  for field in "${fields[@]}"; do printf -v "$field" 'sentinel:%s' "$field"; done
  reference_expect_replay_line "$line" || old_rc=$?
  for field in "${fields[@]}"; do old_values+=("${!field}"); done
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
