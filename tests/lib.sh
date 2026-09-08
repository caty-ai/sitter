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
  (
    set -e
    case $name in
      ledger_replay_equivalence|ledger_sweep_equivalence|ledger_sweep_control_byte_equivalence|ledger_sweep_control_byte_equivalence_no_iconv)
        set -E
        trap 'printf "%s\n" "$name: assertion failed at line $LINENO: $BASH_COMMAND" >&2' ERR ;;
    esac
    "$name"
  )
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

# The fixtures identify the invalid-UTF-8 class with a raw 0xff byte.
replay_has_invalid_byte() {
  local LC_ALL=C
  [[ $1 == *$'\xff'* ]]
}

# Test-only override emulates skip/bytewise extraction/poison without editing
# the frozen fixture: rc 0 also removes invalid records from sweep input.
reference_replay() {
  if replay_has_invalid_byte "$1"; then
    case ${SITTER_TEST_ORACLE_INVALID_RC:-} in
      0|2) return "$SITTER_TEST_ORACLE_INVALID_RC" ;;
      1) local LC_ALL=C; export LC_ALL ;;
    esac
  fi
  reference_expect_replay_line "$1"
}

# Probe actual input order: the baseline can leak an unexported LC_ALL=C
# from a preceding v1 row, changing glibc's later glob match from skip to extract.
probe_reference_invalid_utf8() {
  case ${SITTER_TEST_ORACLE_INVALID_RC:-} in
    ''|0|1|2) ;;
    *) printf '%s\n' "oracle probe: unsupported override $SITTER_TEST_ORACLE_INVALID_RC" >&2; return 1 ;;
  esac
  ORACLE_INVALID_RC=$(
    load_sitter_functions
    local rc=0 line
    if [[ -n ${1:-} ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        rc=0; reference_replay "$line" 2>/dev/null || rc=$?
        if replay_has_invalid_byte "$line"; then break; fi
      done <"$1"
    else
      reference_replay '{"schema":"sitter.v0","expect_id":"invalid-byte","ts":"2000-01-01T00:00:00.000Z","event":"expect","state":"pending","text":"bad'$'\xff''","sla_s":0,"nudges":0}' 2>/dev/null || rc=$?
    fi
    printf '%s' "$rc"
  )
  case $ORACLE_INVALID_RC in
    0|1|2) ;;
    *) printf '%s\n' "oracle probe: unexpected extraction rc $ORACLE_INVALID_RC" >&2; return 1 ;;
  esac
}

prepare_reference_sweep() {
  local input=$1 ledger=$2 baseline="$TEST_ROOT/tests/fixtures/sitter.baseline"
  if [[ ${SITTER_TEST_ORACLE_INVALID_RC:-} == 0 ]]; then
    LC_ALL=C sed '/'$'\xff''/d' "$input" >"$ledger"
  else
    cp "$input" "$ledger"
  fi
  REFERENCE_SCRIPT=$baseline
  if [[ -n ${SITTER_TEST_ORACLE_INVALID_RC:-} ]]; then
    REFERENCE_SCRIPT="$CASE_DIR/reference-sweep.sh"
    awk '/^\[\[ \$# -ge 1 \]\]/ {exit}
      /^expect_replay_line\(\)/ {sub(/expect_replay_line/, "reference_expect_replay_line")}
      {print}' "$baseline" >"$REFERENCE_SCRIPT"
    declare -f replay_has_invalid_byte reference_replay >>"$REFERENCE_SCRIPT"
    printf '%s\n' 'expect_replay_line() { reference_replay "$@"; }' >>"$REFERENCE_SCRIPT"
    if [[ $SITTER_TEST_ORACLE_INVALID_RC == 1 ]]; then
      printf '%s\n' 'export LC_ALL=C' >>"$REFERENCE_SCRIPT"
    fi
    awk '/^\[\[ \$# -ge 1 \]\]/ {copy=1} copy' "$baseline" >>"$REFERENCE_SCRIPT"
  fi
}

# In the skip flavour, replaying without invalid records must leave exactly the
# same poison counters and quarantine state. No invalid-record digest is derived.
assert_reference_skip_state() {
  local input=$1 ledger=$2 home=$3 script=$4 state
  LC_ALL=C sed '/'$'\xff''/d' "$input" >"$ledger"
  SITTER_SWEEP_LOCKED=true SITTER_HOME="$CASE_DIR/skip-home" SPY_FILE="$CASE_DIR/skip.spy" \
    bash "$script" sweep --once --ledger "$ledger" --on-fail "$SPY" >"$CASE_DIR/skip.out" 2>"$CASE_DIR/skip.err"
  for state in failcounts quarantined; do
    if [[ -f $home/$state ]]; then cat "$home/$state"; fi >"$CASE_DIR/skip.actual"
    if [[ -f $CASE_DIR/skip-home/$state ]]; then cat "$CASE_DIR/skip-home/$state"; fi >"$CASE_DIR/skip.expected"
    cmp "$CASE_DIR/skip.expected" "$CASE_DIR/skip.actual" || {
      printf '%s\n' "oracle rc 0: invalid records changed $state" >&2; return 1;
    }
  done
  rm -rf "$CASE_DIR/skip-home"
}

# Assert the complete row independently: truncate_utf8 emits bad for bad + 0xff.
assert_invalid_byte_nudge() {
  local actual=$1 to=$2 sla=$3
  LC_ALL=C sed -n '/"expect_id":"invalid-byte"/p' "$actual" |
    LC_ALL=C sed -E 's/"cwd":"[^"]*"/"cwd":"CWD"/' >"$CASE_DIR/invalid.actual"
  printf '%s\n' '{"ts":"CLOCK","event":"nudge","status":"","project":"","agent":"","task":"","attempt":0,"detail":"","sessionId":"","cwd":"CWD","schema":"sitter.v0","event_id":"EVENT","run_id":"","exit_code":null,"log_path":"","stall_s":0,"reason":"","retries":0,"cooldown_s":0,"idempotent":false,"detail_truncated":false,"hook_exit_code":null,"expect_id":"invalid-byte","to":"'"$to"'","text":"bad","sla_s":'"$sla"',"nudges":1,"state":"nudged1"}' >"$CASE_DIR/invalid.expected"
  if replay_has_invalid_byte "$(cat "$CASE_DIR/invalid.actual")"; then
    printf 'emitted invalid-byte nudge contains raw 0xff\n' >&2
    return 1
  fi
  cmp "$CASE_DIR/invalid.expected" "$CASE_DIR/invalid.actual" || {
    printf '%s\n' 'invalid-byte nudge: expected exactly one full row, text bad, state nudged1' >&2
    return 1
  }
}

assert_sweep_tails_equivalent() {
  local label=$1
  if [[ $ORACLE_INVALID_RC == 1 ]]; then
    cmp "$CASE_DIR/ref.tail" "$CASE_DIR/new.tail"
  else
    if LC_ALL=C grep -q '"expect_id":"invalid-byte"' "$CASE_DIR/ref.tail"; then
      printf '%s\n' "oracle rc $ORACLE_INVALID_RC: unexpected invalid-id row" >&2; return 1
    fi
    LC_ALL=C sed '/"expect_id":"invalid-byte"/d' "$CASE_DIR/new.tail" >"$CASE_DIR/new.other.tail"
    cmp "$CASE_DIR/ref.tail" "$CASE_DIR/new.other.tail"
    printf '%s: known oracle divergence rc %s (0 skipped, 2 poisoned); full new nudge asserted\n' "$label" "$ORACLE_INVALID_RC"
  fi
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
    reference_replay "$line" 2>/dev/null || old_rc=$?
    printf '%s\0' "$old_rc"
    for field in "${fields[@]}"; do printf '%s\0' "${!field}"; done
  )
  old_rc=${old_values[0]}
  old_values=("${old_values[@]:1}")
  for field in "${fields[@]}"; do printf -v "$field" 'sentinel:%s' "$field"; done
  expect_replay_line "$line" || new_rc=$?
  if replay_has_invalid_byte "$line"; then
    [[ $new_rc -eq 1 && $REPLAY_TEXT == $'bad\xff' ]]
    case $old_rc in
      0|2)
        printf 'ledger_replay_equivalence %s: known oracle divergence rc %s (0 skipped, 2 poisoned); new rc 1 and raw text asserted\n' "$label" "$old_rc"
        return 0 ;;
      1) ;;
      *) printf '%s\n' "replay $label: unexpected oracle rc $old_rc" >&2; return 1 ;;
    esac
  fi
  [[ $old_rc -eq $new_rc ]] || { printf 'replay rc mismatch %s: %s / %s\n' "$label" "$old_rc" "$new_rc" >&2; return 1; }
  for field in "${fields[@]}"; do
    [[ ${old_values[i]} == "${!field}" ]] || {
      printf 'replay %s mismatch %s: %q / %q\n' "$field" "$label" "${old_values[i]}" "${!field}" >&2
      return 1
    }
    i=$((i + 1))
  done
}
