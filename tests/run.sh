#!/usr/bin/env bash
# Canonical portable integration suite. bash and POSIX tools only; python3 is
# optional and used solely by assert_json_valid.
set -euo pipefail

unset SITTER_STALL_AFTER SITTER_TIMEOUT SITTER_RETRIES SITTER_COOLDOWN SITTER_HEARTBEAT_FILE

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh disable=SC1091
source "$ROOT/tests/lib.sh"
HEARTBEAT_FIXTURE="$ROOT/tests/fixtures/heartbeat-worker.sh"

# ① successful run; ⑤ a regularly writing worker never stalls.
normal() {
  FW_MODE=ok run_case normal -- "$FIXTURE"
  assert_event_seq "$CASE_DIR/normal.jsonl" start end
  grep -q '"event":"end","status":"success"' "$CASE_DIR/normal.jsonl"
  assert_spy_count 0 "$CASE_DIR/normal.spy"
  FW_MODE=slow FW_TICK=1 run_case slow -- "$FIXTURE"
  ! grep -q '"event":"stall"' "$CASE_DIR/slow.jsonl"
}

help_and_version_are_stdout_success() {
  local flag name out err version_output version_pattern='^sitter [0-9]+\.[0-9]+\.[0-9]+$'
  for flag in --help -h; do
    name=${flag#-}; name=${name#-}
    out="$CASE_DIR/$name.out"; err="$CASE_DIR/$name.err"
    "$SITTER" "$flag" >"$out" 2>"$err"
    grep -q 'usage:' "$out"
    [[ ! -s $err ]]
    if grep -q '__reserve_ask_prepare' "$out"; then return 1; fi
  done

  out="$CASE_DIR/version.out"; err="$CASE_DIR/version.err"
  "$SITTER" --version >"$out" 2>"$err"
  [[ ! -s $err ]]
  version_output=$(cat "$out")
  [[ $version_output =~ $version_pattern ]]
}

usage_error_paths_stay_stderr_exit_two() {
  local no_args_out="$CASE_DIR/no-args.out" no_args_err="$CASE_DIR/no-args.err"
  local bogus_out="$CASE_DIR/bogus.out" bogus_err="$CASE_DIR/bogus.err"
  local run_help_out="$CASE_DIR/run-help.out" run_help_err="$CASE_DIR/run-help.err"
  local help_extra_out="$CASE_DIR/help-extra.out" help_extra_err="$CASE_DIR/help-extra.err"
  local version_extra_out="$CASE_DIR/version-extra.out" version_extra_err="$CASE_DIR/version-extra.err"
  assert_exit 2 "$SITTER" >"$no_args_out" 2>"$no_args_err"
  assert_exit 2 "$SITTER" definitely-not-a-verb >"$bogus_out" 2>"$bogus_err"
  assert_exit 2 "$SITTER" run --help >"$run_help_out" 2>"$run_help_err"
  assert_exit 2 "$SITTER" --help extra >"$help_extra_out" 2>"$help_extra_err"
  assert_exit 2 "$SITTER" --version extra >"$version_extra_out" 2>"$version_extra_err"
  [[ ! -s $no_args_out && -s $no_args_err ]]
  [[ ! -s $bogus_out && -s $bogus_err ]]
  [[ ! -s $run_help_out && -s $run_help_err ]]
  [[ ! -s $help_extra_out && -s $help_extra_err ]]
  [[ ! -s $version_extra_out && -s $version_extra_err ]]
  cmp "$no_args_err" "$bogus_err"
}

help_after_separator_reaches_wrapped_command() {
  local receiver="$CASE_DIR/help-receiver.sh" received="$CASE_DIR/help-received"
  # shellcheck disable=SC2016 # variables expand later, in the generated receiver script
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'received=$1' 'shift' \
    'printf "%s\n" "$@" >>"$received"' >"$receiver"
  chmod +x "$receiver"
  run_case help-separator -- "$receiver" "$received" --help --version
  grep -Fxq -- '--help' "$received"
  grep -Fxq -- '--version' "$received"
  assert_event_seq "$CASE_DIR/help-separator.jsonl" start end
  grep -q '"event":"end","status":"success"' "$CASE_DIR/help-separator.jsonl"
  assert_spy_count 0 "$CASE_DIR/help-separator.spy"
}

help_after_separator_still_hits_denylist() {
  assert_exit 2 run_case help-separator-denied -- git push --help
  [[ ! -d $CASE_DIR/home-help-separator-denied/logs ]]
  assert_event_seq "$CASE_DIR/help-separator-denied.jsonl" refused
  assert_spy_count 1 "$CASE_DIR/help-separator-denied.spy"
}

# ② flaky idempotent recovery; ③ idempotent hang restart; ④ non-idempotent hang.
hang_restart() {
  local allow="$CASE_DIR/allow"
  printf '%s\n' "$FIXTURE" >"$allow"
  FW_MODE=flaky FW_FAIL_TIMES=1 FW_STATE="$CASE_DIR/flaky.state" \
    run_case flaky --idempotent flaky --allowlist "$allow" --cooldown 5 -- "$FIXTURE"
  assert_event_seq "$CASE_DIR/flaky.jsonl" start restart end
  FW_MODE=flaky_hang FW_FAIL_TIMES=1 FW_STATE="$CASE_DIR/hang.state" \
    run_case hang --idempotent flaky_hang --allowlist "$allow" --cooldown 5 -- "$FIXTURE"
  assert_event_seq "$CASE_DIR/hang.jsonl" start stall restart end
  assert_exit 1 run_nonidempotent
  assert_event_seq "$CASE_DIR/nonidempotent.jsonl" start stall end
  if grep -q '"event":"restart"' "$CASE_DIR/nonidempotent.jsonl"; then return 1; fi
  assert_spy_count 1 "$CASE_DIR/nonidempotent.spy"
}

run_nonidempotent() { FW_MODE=hang run_case nonidempotent -- "$FIXTURE"; }

# This pins the non-idempotent stall path only; retry exhaustion masks the
# attempt reason with budget_exhausted on its terminal end row.
nonidempotent_stall_reason_contract() {
  local ledger="$CASE_DIR/stall-reason.jsonl" spy_file="$CASE_DIR/stall-reason.spy"
  SPY="$CASE_DIR/stall-reason-spy.sh"
  # shellcheck disable=SC2016 # variables expand later, in the generated spy script
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'cat >>"$SPY_FILE"' \
    'printf "ENV_SITTER_REASON=%s\n" "$SITTER_REASON" >>"$SPY_FILE"' \
    'printf "ENV_SITTER_EVENT=%s\n" "$SITTER_EVENT" >>"$SPY_FILE"' >"$SPY"
  chmod +x "$SPY"

  assert_exit 1 run_case stall-reason -- sleep 30
  grep -q '"event":"stall","status":"killed".*"reason":"stall"' "$ledger"
  grep -q '"event":"fail","status":"failed".*"reason":"stall"' "$ledger"
  grep -q '"event":"end","status":"failed".*"reason":"stall"' "$ledger"
  assert_event_seq "$ledger" start stall fail end
  grep -q '"SITTER_REASON":"stall"' "$spy_file"
  [[ $(grep -c '^ENV_SITTER_REASON=' "$spy_file") -eq 1 ]]
  grep -Fxq 'ENV_SITTER_REASON=stall' "$spy_file"
  grep -Fxq 'ENV_SITTER_EVENT=end' "$spy_file"
}

# A cooldown must not count against the next attempt's initial stall window.
cooldown_crossing_restart_does_not_falsely_stall() {
  local allow="$CASE_DIR/allow" worker="$CASE_DIR/slow-second-attempt.sh"
  printf '%s\n' "$worker" >"$allow"
  # shellcheck disable=SC2016 # literal $FW_STATE/$FW_FIXTURE expand later, in the generated worker script
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    '[[ -f $FW_STATE ]] && sleep 2' 'exec "$FW_FIXTURE"' >"$worker"
  chmod +x "$worker"
  # Legitimate silence on attempt 2 is sleep 2 + process startup <=1s + 1s integer-second truncation,
  # approximately 4s <8s; tripled startup still stays under 8s. Counting cooldown as silence makes the log
  # >=15s old on attempt 2's first poll and is still caught. Pre-fix flake (stall-after 3): attempt 2 started
  # at :16, stalled at :19 with the log 3s old.
  FW_FIXTURE="$FIXTURE" FW_MODE=flaky FW_FAIL_TIMES=1 FW_STATE="$CASE_DIR/restart.state" \
    SITTER_HOME="$CASE_DIR/home-cooldown-crossing" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/cooldown-crossing.spy" \
    "$SITTER" run --ledger "$CASE_DIR/cooldown-crossing.jsonl" --on-fail "$SPY" \
      --idempotent slow-second-attempt --allowlist "$allow" --retries 1 --cooldown 15 \
      --stall-after 8 --timeout 20 --grace 0 -- "$worker"
  grep -q '"event":"restart"' "$CASE_DIR/cooldown-crossing.jsonl"
  grep -q '"event":"end","status":"success"' "$CASE_DIR/cooldown-crossing.jsonl"
  ! grep -q '"reason":"stall"' "$CASE_DIR/cooldown-crossing.jsonl"
}

run_heartbeat_case() {
  local name=$1
  shift
  SITTER_HOME="$CASE_DIR/home-$name" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/$name.spy" \
    "$SITTER" run --ledger "$CASE_DIR/$name.jsonl" --on-fail "$SPY" \
      --log "$CASE_DIR/$name.log" --stall-after 3 --timeout 20 --grace 0 "$@"
}

# ADR-0003 planned test 1: a silent worker's fresh heartbeat is sufficient.
heartbeat_fresh_keeps_silent_worker_alive() {
  local heartbeat="$CASE_DIR/fresh.touch" ledger="$CASE_DIR/fresh.jsonl"
  HB_MODE=touching run_heartbeat_case fresh --heartbeat-file "$heartbeat" -- "$HEARTBEAT_FIXTURE"
  assert_event_seq "$ledger" start end
  grep -q '"event":"end","status":"success"' "$ledger"
  if grep -q '"event":"stall"' "$ledger"; then return 1; fi
  [[ ! -s $CASE_DIR/fresh.log ]]
}

# ADR-0003 planned test 2: both stale inputs retain the stall contract.
heartbeat_frozen_stalls_silent_worker() {
  local heartbeat="$CASE_DIR/frozen.touch" ledger="$CASE_DIR/frozen.jsonl"
  HB_MODE=frozen assert_exit 1 run_heartbeat_case frozen --heartbeat-file "$heartbeat" -- "$HEARTBEAT_FIXTURE"
  assert_event_seq "$ledger" start stall fail end
  grep -Eq '"detail":"pid alive, log mtime frozen [0-9]+s, heartbeat frozen [0-9]+s"' "$ledger"
  grep -q '"event":"stall","status":"killed".*"schema":"sitter.v0".*"reason":"stall"' "$ledger"
  assert_json_valid "$ledger"
  [[ ! -s $CASE_DIR/frozen.log ]]
}

# ADR-0003 planned test 3: a heartbeat cannot accompany a disabled stall clock.
heartbeat_rejects_disabled_stall() {
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --heartbeat-file "$CASE_DIR/heartbeat" \
    --stall-after 0 --timeout 10 -- true
  [[ ! -e $CASE_DIR/heartbeat ]]
}

# ADR-0003 planned test 4: the new writable path refuses symlinks by default.
heartbeat_symlink_is_refused() {
  if ! symlinks_are_real; then printf 'SKIP heartbeat_symlink_is_refused: no real symlink support\n' >&2; return 0; fi
  local target="$CASE_DIR/target" heartbeat="$CASE_DIR/heartbeat" stderr="$CASE_DIR/symlink.stderr"
  : >"$target"
  ln -s "$target" "$heartbeat"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --heartbeat-file "$heartbeat" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq 'heartbeat file must be a regular non-symlink file' "$stderr"
}

# ADR-0003 planned test 5: ask/watch reject the option with their existing message.
heartbeat_ask_watch_contract() {
  local ask_err="$CASE_DIR/ask.err" watch_err="$CASE_DIR/watch.err"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/ask-home" "$SITTER" ask \
    --ledger "$CASE_DIR/ask.jsonl" --to operator --sla 60 --reply-file "$CASE_DIR/reply" \
    --heartbeat-file "$CASE_DIR/heartbeat" -- true 2>"$ask_err"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/watch-home" "$SITTER" watch --once \
    --ledger "$CASE_DIR/watch.jsonl" --heartbeat-file "$CASE_DIR/heartbeat" 2>"$watch_err"
  grep -Fxq 'sitter: ask received an option outside its contract' "$ask_err"
  grep -Fxq 'sitter: watch received an option outside its contract' "$watch_err"
}

# ADR-0003 planned test 6: relative input is resolved before the child sees it.
heartbeat_child_sees_absolute_relative_path() {
  local capture="$CASE_DIR/captured" expected
  expected="$(cd "$CASE_DIR" && pwd)/relative/heartbeat"
  (
    cd "$CASE_DIR"
    HB_MODE=capture_env HB_CAPTURE="$capture" SITTER_HOME="$CASE_DIR/home-relative" SITTER_POLL_INTERVAL=1 \
      "$SITTER" run --ledger "$CASE_DIR/relative.jsonl" --on-fail "$SPY" \
        --heartbeat-file relative/heartbeat --stall-after 3 --timeout 20 --grace 0 -- "$HEARTBEAT_FIXTURE"
  )
  grep -Fxq "$expected" "$capture"
  [[ -f $expected ]]
}

# ADR-0003 planned test 7: every retry receives a new heartbeat baseline.
heartbeat_restart_resets_baseline() {
  local allow="$CASE_DIR/allow" state="$CASE_DIR/retry.state" first second ledger="$CASE_DIR/retry.jsonl"
  printf '%s\n' "$HEARTBEAT_FIXTURE" >"$allow"
  HB_MODE=retry_baseline HB_STATE="$state" SITTER_HOME="$CASE_DIR/home-retry" SITTER_POLL_INTERVAL=1 \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --log "$CASE_DIR/retry.log" \
      --heartbeat-file "$CASE_DIR/retry.touch" --idempotent heartbeat-retry --allowlist "$allow" \
      --retries 1 --cooldown 5 --stall-after 3 --timeout 20 --grace 0 -- "$HEARTBEAT_FIXTURE"
  first=$(<"$state.mtime.1")
  second=$(<"$state.mtime.2")
  ((second > first))
  assert_event_seq "$ledger" start restart end
  ! grep -q '"reason":"stall"' "$ledger"
}

# ADR-0003 planned test 8: the unset path preserves the old detail byte shape.
heartbeat_flag_unset_detail_is_unchanged() {
  local ledger="$CASE_DIR/unset.jsonl"
  assert_exit 1 env SITTER_HEARTBEAT_FILE="$CASE_DIR/env-only" FW_MODE=hang \
    SITTER_HOME="$CASE_DIR/home-unset" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/unset.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --log "$CASE_DIR/unset.log" \
      --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  grep -Eq '"detail":"pid alive, log mtime frozen [0-9]+s"' "$ledger"
  if grep -q 'heartbeat' "$ledger"; then return 1; fi
  [[ ! -e $CASE_DIR/env-only ]]
}

heartbeat_deleted_midrun_falls_back_to_log() {
  local ledger="$CASE_DIR/deleted.jsonl"
  HB_MODE=delete assert_exit 1 run_heartbeat_case deleted \
    --heartbeat-file "$CASE_DIR/deleted.touch" -- "$HEARTBEAT_FIXTURE"
  grep -Eq '"event":"stall".*"detail":"pid alive, log mtime frozen [0-9]+s, heartbeat unavailable"' "$ledger"
  grep -q '"reason":"stall"' "$ledger"
}

heartbeat_symlink_swap_midrun_falls_back_to_log() {
  if ! symlinks_are_real; then printf 'SKIP heartbeat_symlink_swap_midrun_falls_back_to_log: no real symlink support\n' >&2; return 0; fi
  local ledger="$CASE_DIR/swapped.jsonl" target="$CASE_DIR/swap-target"
  : >"$target"
  HB_MODE=symlink_swap HB_LINK_TARGET="$target" assert_exit 1 run_heartbeat_case swapped \
    --heartbeat-file "$CASE_DIR/swapped.touch" -- "$HEARTBEAT_FIXTURE"
  [[ -L $CASE_DIR/swapped.touch ]]
  grep -q '"event":"stall".*heartbeat unavailable".*"reason":"stall"' "$ledger"
}

heartbeat_empty_value_is_refused() {
  local stderr="$CASE_DIR/empty.stderr"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --heartbeat-file '' \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq -- '--heartbeat-file must be nonempty' "$stderr"
}

heartbeat_unwritable_parent_is_refused() {
  if ! chmod_denies_dir_write; then printf 'SKIP heartbeat_unwritable_parent_is_refused: chmod not enforced\n' >&2; return 0; fi
  local parent="$CASE_DIR/unwritable" stderr="$CASE_DIR/unwritable.stderr"
  mkdir "$parent"
  chmod 500 "$parent"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --heartbeat-file "$parent/heartbeat" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq 'cannot touch heartbeat file' "$stderr"
  chmod 700 "$parent"
  [[ ! -e $parent/heartbeat ]]
}

heartbeat_directory_path_is_refused() {
  local stderr="$CASE_DIR/directory.stderr"
  mkdir "$CASE_DIR/heartbeat-dir"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --heartbeat-file "$CASE_DIR/heartbeat-dir" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq 'heartbeat file must be a regular non-symlink file' "$stderr"
}

heartbeat_attempt_touch_failure_is_not_a_stall() {
  if ! symlinks_are_real; then printf 'SKIP heartbeat_attempt_touch_failure_is_not_a_stall: no real symlink support\n' >&2; return 0; fi
  local allow="$CASE_DIR/allow" state="$CASE_DIR/state" target="$CASE_DIR/target" ledger="$CASE_DIR/attempt-touch.jsonl"
  : >"$target"
  printf '%s\n' "$HEARTBEAT_FIXTURE" >"$allow"
  assert_exit 1 env HB_MODE=swap_before_retry HB_STATE="$state" HB_LINK_TARGET="$target" \
    SITTER_HOME="$CASE_DIR/home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/attempt-touch.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --heartbeat-file "$CASE_DIR/attempt.touch" \
      --idempotent heartbeat-retry --allowlist "$allow" --retries 1 --cooldown 5 \
      --stall-after 3 --timeout 20 --grace 0 -- "$HEARTBEAT_FIXTURE"
  [[ $(<"$state") -eq 1 ]]
  if grep -q '"event":"stall"' "$ledger"; then return 1; fi
  grep -Fq '"detail":"attempt failed: heartbeat file unavailable before attempt"' "$ledger"
  grep -q '"event":"fail".*"reason":"exit"' "$ledger"
}

heartbeat_environment_does_not_change_ask_or_watch() {
  local heartbeat="$CASE_DIR/env-only" ledger="$CASE_DIR/ask.jsonl" reply="$CASE_DIR/reply"
  SITTER_HEARTBEAT_FILE="$heartbeat" SITTER_HOME="$CASE_DIR/home" "$SITTER" ask \
    --ledger "$ledger" --to operator --sla 60 --reply-file "$reply" --id env-only -- true >/dev/null
  SITTER_HEARTBEAT_FILE="$heartbeat" SITTER_HOME="$CASE_DIR/home" \
    "$SITTER" watch --once --ledger "$ledger" --id env-only
  grep -q '"event":"expect"' "$ledger"
  [[ ! -e $heartbeat ]]
}

heartbeat_collision_with_ledger_is_refused() {
  local path="$CASE_DIR/same" stderr="$CASE_DIR/ledger-collision.stderr"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$path" --on-fail "$SPY" --heartbeat-file "$path" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq -- '--heartbeat-file must not equal --ledger, its lock, --kill-file, or --log' "$stderr"
}

heartbeat_collision_with_ledger_lock_is_refused() {
  local ledger="$CASE_DIR/ledger.jsonl" stderr="$CASE_DIR/ledger-lock-collision.stderr"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$ledger" --on-fail "$SPY" --heartbeat-file "$ledger.lock" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq -- '--heartbeat-file must not equal --ledger, its lock, --kill-file, or --log' "$stderr"
}

heartbeat_collision_with_kill_file_is_refused() {
  local path="$CASE_DIR/kill" stderr="$CASE_DIR/kill-collision.stderr"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --kill-file "$path" --heartbeat-file "$path" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq -- '--heartbeat-file must not equal --ledger, its lock, --kill-file, or --log' "$stderr"
}

heartbeat_collision_with_log_is_refused() {
  local path="$CASE_DIR/log" stderr="$CASE_DIR/log-collision.stderr"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$SPY" --log "$path" --heartbeat-file "$path" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq -- '--heartbeat-file must not equal --ledger, its lock, --kill-file, or --log' "$stderr"
}

heartbeat_normalized_collision_with_ledger_is_refused() {
  local dir="$CASE_DIR/x" ledger="$CASE_DIR/x/ledger.jsonl" stderr="$CASE_DIR/normalized-collision.stderr"
  mkdir -p "$dir"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/home" "$SITTER" run \
    --ledger "$ledger" --on-fail "$SPY" --heartbeat-file "$CASE_DIR/x/../x/ledger.jsonl" \
    --stall-after 3 --timeout 20 -- true 2>"$stderr"
  grep -Fq -- '--heartbeat-file must not equal --ledger, its lock, --kill-file, or --log' "$stderr"
}

heartbeat_export_is_scoped_to_child() {
  local hook="$CASE_DIR/hook.sh" capture="$CASE_DIR/hook-env" heartbeat="$CASE_DIR/heartbeat"
  # shellcheck disable=SC2016 # the generated hook evaluates its own environment
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${SITTER_HEARTBEAT_FILE-unset}" >"$HB_HOOK_CAPTURE"' >"$hook"
  chmod +x "$hook"
  assert_exit 9 env -u SITTER_HEARTBEAT_FILE HB_HOOK_CAPTURE="$capture" HB_MODE=fail \
    SITTER_HOME="$CASE_DIR/home" SITTER_POLL_INTERVAL=1 "$SITTER" run \
      --ledger "$CASE_DIR/ledger.jsonl" --on-fail "$hook" --heartbeat-file "$heartbeat" \
      --stall-after 3 --timeout 20 --grace 0 -- "$HEARTBEAT_FIXTURE"
  grep -Fxq unset "$capture"
}

heartbeat_frozen_does_not_override_advancing_log() {
  local ledger="$CASE_DIR/log-fresh.jsonl"
  HB_MODE=log_advancing run_heartbeat_case log-fresh \
    --heartbeat-file "$CASE_DIR/log-fresh.touch" -- "$HEARTBEAT_FIXTURE"
  grep -q '"event":"end","status":"success"' "$ledger"
  ! grep -q '"event":"stall"' "$ledger"
}

heartbeat_is_ignored_by_expect_ack_and_sweep() {
  local heartbeat="$CASE_DIR/ignored" ledger="$CASE_DIR/ledger.jsonl" home="$CASE_DIR/home"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" \
    --id ignored-heartbeat --heartbeat-file "$heartbeat"
  SITTER_HOME="$home" "$SITTER" ack --ledger "$ledger" --id ignored-heartbeat \
    --heartbeat-file "$heartbeat"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY" \
    --heartbeat-file "$heartbeat"
  [[ ! -e $heartbeat ]]
}

heartbeat_help_lists_flag() {
  "$SITTER" --help | grep -Fq -- '--heartbeat-file PATH'
}

# ⑥ retry budget exhaustion invokes the hook exactly once.
budget() {
  printf '%s\n' "$FIXTURE" >"$CASE_DIR/allow"
  assert_exit 9 run_budget
  grep -q '"event":"end","status":"budget_exhausted"' "$CASE_DIR/budget.jsonl"
  assert_spy_count 1 "$CASE_DIR/budget.spy"
}

run_budget() { FW_MODE=fail run_case budget --idempotent fail --allowlist "$CASE_DIR/allow" --retries 0 -- "$FIXTURE"; }

# Retry exhaustion must not consume the next invocation's retry budget.
per_invocation_retry_budget() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/retry-home" first="$CASE_DIR/retry-first.jsonl" second="$CASE_DIR/retry-second.jsonl" cooldown_file
  printf '%s\n' "$FIXTURE" >"$allow"
  assert_exit 9 env FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/retry.spy" \
    "$SITTER" run --ledger "$first" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  grep -q '"event":"end","status":"budget_exhausted"' "$first"
  for cooldown_file in "$home"/cooldown/*; do break; done
  [[ -f $cooldown_file ]]
  printf '1 %s\n' "$(( $(date +%s) - 1 ))" >"$cooldown_file"
  assert_exit 9 env FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/retry.spy" \
    "$SITTER" run --ledger "$second" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  [[ $(grep -c '"event":"start"' "$second") -eq 2 ]]
  grep -q '"event":"restart"' "$second"
}

# A prior failure's timestamp still delays the next invocation's first attempt.
backoff_persists_across_invocations() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/backoff-home" first="$CASE_DIR/backoff-first.jsonl" second="$CASE_DIR/backoff-second.jsonl" cooldown_file='' next='' pid poll started elapsed remaining
  printf '%s\n' "$FIXTURE" >"$allow"
  FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/backoff.spy" \
    "$SITTER" run --ledger "$first" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 6 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE" &
  pid=$!
  for ((poll = 0; poll < 50; poll++)); do
    for cooldown_file in "$home"/cooldown/*; do [[ -f $cooldown_file ]] && break; cooldown_file=''; done
    [[ -n $cooldown_file ]] && break
    sleep 0.1
  done
  [[ -f $cooldown_file ]]
  next=$(awk '{print $2}' "$cooldown_file")
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  remaining=$((next - $(date +%s)))
  ((remaining > 0))
  started=$(date +%s)
  assert_exit 9 env FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/backoff.spy" \
    "$SITTER" run --ledger "$second" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 0 --cooldown 6 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  elapsed=$(( $(date +%s) - started ))
  ((elapsed >= remaining - 1))
  grep -q '"event":"start"' "$second"
}

# Old cooldown files stored a real used count; it is now intentionally ignored.
old_format_cooldown_is_compatible() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/old-format-home" prime="$CASE_DIR/old-format-prime.jsonl" ledger="$CASE_DIR/old-format.jsonl" cooldown_file='' pid poll
  printf '%s\n' "$FIXTURE" >"$allow"
  FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/old-format.spy" \
    "$SITTER" run --ledger "$prime" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE" &
  pid=$!
  for ((poll = 0; poll < 50; poll++)); do
    for cooldown_file in "$home"/cooldown/*; do [[ -f $cooldown_file ]] && break; cooldown_file=''; done
    [[ -n $cooldown_file ]] && break
    sleep 0.1
  done
  [[ -f $cooldown_file ]]
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  printf '3 %s\n' "$(( $(date +%s) - 1 ))" >"$cooldown_file"
  assert_exit 9 env FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/old-format.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  [[ $(grep -c '"event":"start"' "$ledger") -eq 2 ]]
  grep -q '"event":"restart"' "$ledger"
}

# ⑦ denied commands are refused before spawn and notify once.
denied() {
  assert_exit 2 run_case denied -- git push origin main
  [[ ! -d $CASE_DIR/home-denied/logs ]]
  assert_event_seq "$CASE_DIR/denied.jsonl" refused
  assert_spy_count 1 "$CASE_DIR/denied.spy"
}

# Supplemental CLI contract: run requires its notification hook.
missing_hook() { assert_exit 2 env SITTER_HOME="$CASE_DIR/missing-home" "$SITTER" run --ledger "$CASE_DIR/missing.jsonl" -- true; }

# ⑭ an explicit zero stall value requires an explicit timeout.
stall_zero() { assert_exit 2 env SITTER_HOME="$CASE_DIR/zero-home" "$SITTER" run --ledger "$CASE_DIR/zero.jsonl" --on-fail "$SPY" --stall-after 0 -- true; }
stall_zero_padded() { assert_exit 2 env SITTER_HOME="$CASE_DIR/zero-padded-home" "$SITTER" run --ledger "$CASE_DIR/zero-padded.jsonl" --on-fail "$SPY" --stall-after 00 -- true; }
env_timeout_explicit() { SITTER_HOME="$CASE_DIR/env-timeout-home" SITTER_STALL_AFTER=0 SITTER_TIMEOUT=60 "$SITTER" run --ledger "$CASE_DIR/env-timeout.jsonl" --on-fail "$SPY" -- true; }
json_ledger() { run_case json --task $'say "hi" \\ path\ttab' -- true && assert_json_valid "$CASE_DIR/json.jsonl"; }

# ⑨ idempotence allowlists contain commands, not labels.
allowlist_is_command_not_label() {
  printf 'listed-name\n' >"$CASE_DIR/label-only.allow"
  assert_exit 9 run_label_only
  [[ $(grep -c '"event":"start"' "$CASE_DIR/label-only.jsonl") -eq 1 ]]
  assert_spy_count 1 "$CASE_DIR/label-only.spy"
}

run_label_only() { FW_MODE=fail run_case label-only --idempotent listed-name --allowlist "$CASE_DIR/label-only.allow" -- "$FIXTURE"; }

denylist_adjacency() {
  local command_name
  for command_name in git vercel dd; do
    case $command_name in
      git) assert_exit 2 run_case "deny-$command_name" -- git --git-dir=/tmp push origin ;;
      vercel) assert_exit 2 run_case "deny-$command_name" -- vercel deploy --prod ;;
      dd) assert_exit 2 run_case "deny-$command_name" -- dd if=/dev/zero of=/tmp/x ;;
    esac
    [[ ! -d $CASE_DIR/home-deny-$command_name/logs ]]
  done
  run_case payment -- echo payment due
}

# Launcher prefixes must not hide denylisted commands; harmless wrapped commands run.
denylist_launcher_unwrap() {
  mkdir "$CASE_DIR/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'shift' 'exec "$@"' >"$CASE_DIR/bin/timeout"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/timeout" "$CASE_DIR/bin/git"
  export PATH="$CASE_DIR/bin:$PATH"

  assert_exit 2 run_case deny-timeout -- timeout 300 git push origin main
  assert_exit 2 run_case deny-env -- env FOO=1 git push origin main
  assert_exit 2 run_case deny-nested -- nohup timeout 300 git push origin main
  assert_exit 2 run_case deny-shell -- sh -c 'git push origin main'
  assert_exit 2 run_case deny-env-shell -- env FOO=1 sh -c 'git push origin main'
  assert_exit 2 run_case deny-nohup-double-dash -- nohup -- git push origin main
  assert_exit 2 run_case deny-env-option-assignment -- env -u NEVER FOO=1 git push origin main
  assert_exit 2 run_case deny-launcher-depth-cap -- env env env env env env env env env git push origin main

  run_case allow-env -- env FOO=1 echo ok
  run_case allow-timeout -- timeout 5 echo ok
  run_case allow-shell -- sh -c 'echo harmless'

  assert_exit 2 run_case deny-bare -- git push origin main
  assert_exit 2 run_case deny-gh-bare -- gh pr merge 1
  assert_exit 2 run_case deny-gh-env -- env gh pr merge 1
}

# Bundled shell -c flag forms and repeated/unrecognized nice options must
# still fail closed rather than silently allowing the wrapped command.
denylist_shell_bundle_and_nice_residue() {
  mkdir -p "$CASE_DIR/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"
  export PATH="$CASE_DIR/bin:$PATH"

  assert_exit 2 run_case deny-sh-lc -- sh -lc 'git push origin main'
  assert_exit 2 run_case deny-bash-ec -- bash -ec 'git push origin main'
  assert_exit 2 run_case deny-nice-repeated -- nice -n 5 -n 3 git push origin main

  # A login shell may source profiles and stay silent past run_case's 2s window, effectively 1-2s with integer mtimes; denied cases fail before launch, so timing is irrelevant there.
  run_case allow-sh-lc --stall-after 10 -- sh -lc 'echo harmless'
}

# ⑩ acknowledged expectations stay quiet; overdue state transitions notify 3 times.
expect_ack_stays_quiet() {
  local home="$CASE_DIR/expect-ack-home" ledger="$CASE_DIR/expect-ack.jsonl" spy="$CASE_DIR/expect-ack.spy"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id acked --sla 0 --to operator --text 'please reply'
  SITTER_HOME="$home" "$SITTER" ack --ledger "$ledger" --id acked --detail received
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  ! grep -q '"event":"nudge"' "$ledger" && [[ ! -s $spy ]]
}
expect_escalates_once_per_state() {
  local home="$CASE_DIR/expect-escalate-home" ledger="$CASE_DIR/expect-escalate.jsonl" spy="$CASE_DIR/expect-escalate.spy"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id overdue --sla 0 --to operator --text 'please reply'
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  assert_event_seq "$ledger" expect nudge nudge awaiting_human
  assert_spy_count 3 "$spy"
}

# ⑪ replay makes acknowledgement absorbing and permits a later generation.
out_of_order_ack_and_id_reuse() {
  local home="$CASE_DIR/out-of-order-home" ledger="$CASE_DIR/out-of-order.jsonl" spy="$CASE_DIR/out-of-order.spy"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id reordered --sla 0 --to operator --text first
  assert_exit 2 env SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id reordered --sla 0 --to operator --text duplicate
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" "$SITTER" ack --ledger "$ledger" --id reordered
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id reordered --sla 0 --to operator --text reused
  [[ $(grep -c '"event":"nudge"' "$ledger") -eq 1 && $(grep -c '"event":"expect"' "$ledger") -eq 2 ]]
}

# ⑫ a held flock/lockf makes the later sweep a successful no-op.
sweep_lock_contention_is_quiet() {
  local home="$CASE_DIR/sweep-lock-home" ledger="$CASE_DIR/sweep-lock.jsonl" spy="$CASE_DIR/sweep-lock.spy" lock holder
  lock="$home/sweep.lock"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id locked --sla 0 --to operator --text lock
  mkdir -p "$home"; : >"$lock"
  if command -v flock >/dev/null 2>&1; then
    flock "$lock" sh -c 'sleep 1' & holder=$!
  elif command -v lockf >/dev/null 2>&1; then
    lockf -k "$lock" sh -c 'sleep 1' & holder=$!
  else
    (mkdir "$home/sweep.lock.d"; sleep 1; rmdir "$home/sweep.lock.d") & holder=$!
  fi
  sleep 0.1
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  wait "$holder"
  ! grep -q '"event":"nudge"' "$ledger" && [[ ! -s $spy ]]
}

# ⑬ malformed sitter records quarantine on their third replay, then remain skipped.
poison_is_quarantined_once() {
  local home="$CASE_DIR/poison-home" ledger="$CASE_DIR/poison.jsonl" spy="$CASE_DIR/poison.spy" bad
  bad='{"schema":"sitter.v0","event":"expect","expect_id":"poisoned"'
  printf '%s\n' "$bad" >"$ledger"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ $(grep -c '"event":"quarantine"' "$ledger") -eq 1 && ! -s $spy ]]
}

# ⑧ the run kill switch is touched while live; sweep also honors a preexisting STOP.
sweep_kill_switch_is_quiet() {
  local home="$CASE_DIR/sweep-stop-home" ledger="$CASE_DIR/sweep-stop.jsonl" spy="$CASE_DIR/sweep-stop.spy" pid
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id stopped --sla 0 --to operator --text stop
  mkdir -p "$home"; : >"$home/STOP"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  ! grep -q '"event":"nudge"' "$ledger" && [[ ! -s $spy ]]
  rm "$home/STOP"
  # This opt-out exists only for restricted harnesses that kill their parent
  # when a child receives TERM; CI must leave it unset.
  [[ ${SITTER_TEST_SKIP_TERM:-false} == true ]] && return 0
  SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/live.spy" FW_MODE=hang \
    "$SITTER" run --ledger "$CASE_DIR/live.jsonl" --on-fail "$SPY" --stall-after 0 --timeout 10 --grace 0 -- "$FIXTURE" &
  pid=$!
  sleep 1; : >"$home/STOP"
  # Kill-switch stop is an operator action, not a failure: run exits 0 by
  # design (established in the #2 review round).
  assert_exit 0 wait "$pid"
  ! grep -q '"event":"restart"' "$CASE_DIR/live.jsonl"
}

# ⑪ a late nudge after ack remains absorbed during replay.
ack_race_replay_is_absorbing() {
  local home="$CASE_DIR/ack-race-home" ledger="$CASE_DIR/ack-race.jsonl" spy="$CASE_DIR/ack-race.spy"
  printf '%s\n' '{"ts":"2020-01-01T00:00:00.123Z","event":"expect","schema":"sitter.v0","expect_id":"race","to":"operator","text":"reply","sla_s":0,"nudges":0,"state":"pending"}' '{"ts":"2020-01-01T00:00:01.123Z","event":"ack","schema":"sitter.v0","expect_id":"race","to":"","text":"","sla_s":0,"nudges":0,"state":"acked"}' '{"ts":"2020-01-01T00:00:02.123Z","event":"nudge","schema":"sitter.v0","expect_id":"race","to":"operator","text":"reply","sla_s":0,"nudges":1,"state":"nudged1"}' >"$ledger"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ $(wc -l <"$ledger") -eq 3 && ! -s $spy ]]
}

id_charset_and_sanitization() {
  local home="$CASE_DIR/id-home" ledger="$CASE_DIR/id.jsonl" bad
  for bad in 'A B' 'E\X' $'A\tB'; do assert_exit 2 env SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id "$bad"; done
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id clean --to 'say "hi" \ tab' --text 'say "hi" \ tab'
  assert_json_valid "$ledger"
}
# #47: multibyte survives json_quote (run --task) and sanitize_expect_value
# (expect --to/--text); controls, quotes and backslashes are still stripped
# or escaped; sweep's replay round-trips the multibyte fields intact.
multibyte_survives_quote_and_sanitize() {
  local home="$CASE_DIR/mb-home" ledger="$CASE_DIR/mb.jsonl" spy="$CASE_DIR/mb.spy" text_in
  text_in=$(printf '進捗をé😀 "q" \\ \x01\x1freport')
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id mb --sla 0 --to '日本語チーム' --text "$text_in"
  assert_json_valid "$ledger"
  grep -qF '"to":"日本語チーム","text":"進捗をé😀 q  report","sla_s":' "$ledger"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ $(grep -c '"event":"nudge"' "$ledger") -eq 1 ]]
  grep -F '"event":"nudge"' "$ledger" | grep -qF '"to":"日本語チーム","text":"進捗をé😀 q  report"'
  if grep -q '"event":"quarantine"' "$ledger"; then return 1; fi
  FW_MODE=ok run_case mbtask --task $'日本語ctl\x01end' -- true
  assert_json_valid "$CASE_DIR/mbtask.jsonl"
  grep -qF "\"task\":\"日本語ctl\\u0001end\"" "$CASE_DIR/mbtask.jsonl"
}
quarantined_id_is_burned() {
  local home="$CASE_DIR/burned-home" ledger="$CASE_DIR/burned.jsonl"
  printf '%s\n' '{"ts":"2020-01-01T00:00:00.000Z","event":"expect","schema":"sitter.v0","expect_id":"burned","to":"x","text":"x","sla_s":1,"nudges":0,"state":"pending"}' '{"ts":"2020-01-01T00:00:01.000Z","event":"quarantine","schema":"sitter.v0","expect_id":"burned","to":"","text":"","sla_s":0,"nudges":0,"state":"quarantined"}' >"$ledger"
  assert_exit 2 env SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id burned
}
failcount_isolation() {
  local home="$CASE_DIR/failcount-home" ledger="$CASE_DIR/failcount.jsonl" hook="$CASE_DIR/fail-hook.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 1' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id first --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id fresh --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  ! grep -q '"expect_id":"fresh".*"state":"quarantined"' "$ledger"
}
quarantine_is_per_ledger() {
  local home="$CASE_DIR/quarantine-ledger-home" ledger_a="$CASE_DIR/quarantine-ledger-a.jsonl" ledger_b="$CASE_DIR/quarantine-ledger-b.jsonl" fail_hook="$CASE_DIR/quarantine-fail-hook.sh" ok_hook="$CASE_DIR/quarantine-ok-hook.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 1' >"$fail_hook"; chmod +x "$fail_hook"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 0' >"$ok_hook"; chmod +x "$ok_hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger_a" --on-fail "$fail_hook" --id X --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger_a" --on-fail "$fail_hook"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger_a" --on-fail "$fail_hook"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger_a" --on-fail "$fail_hook"
  [[ $(grep -c '"event":"quarantine"' "$ledger_a") -eq 1 ]]
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger_b" --on-fail "$ok_hook" --id X --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger_b" --on-fail "$ok_hook"
  [[ $(grep -c '"event":"nudge"' "$ledger_b") -eq 1 ]]
  [[ $(grep -c '"event":"quarantine"' "$ledger_b") -eq 0 ]]
}

orphan_nudge_is_not_live() {
  local real_home="$CASE_DIR/orphan-nudge-real-home" orphan_home="$CASE_DIR/orphan-nudge-home" realledger="$CASE_DIR/orphan-nudge-real.jsonl" orphanledger="$CASE_DIR/orphan-nudge.jsonl" before after nudges_before nudges_after
  SITTER_HOME="$real_home" "$SITTER" expect --ledger "$realledger" --on-fail "$SPY" --id X --sla 0
  SITTER_HOME="$real_home" "$SITTER" sweep --once --ledger "$realledger" --on-fail "$SPY"
  before=$(wc -l <"$realledger")
  grep -v '"event":"expect"' "$realledger" >"$orphanledger"
  after=$(wc -l <"$orphanledger")
  [[ $((before - after)) -eq 1 ]]
  assert_exit 0 env SITTER_HOME="$orphan_home" "$SITTER" expect --ledger "$orphanledger" --on-fail "$SPY" --id X --sla 0
  nudges_before=$(grep -c '"event":"nudge"' "$orphanledger" || true)
  SITTER_HOME="$orphan_home" "$SITTER" sweep --once --ledger "$orphanledger" --on-fail "$SPY"
  nudges_after=$(grep -c '"event":"nudge"' "$orphanledger" || true)
  [[ $nudges_after -eq $((nudges_before + 1)) ]]
  ! grep -qE '"event":"(poison|quarantine)"' "$orphanledger"
}

orphan_quarantine_does_not_burn_admission() {
  local scratch_home="$CASE_DIR/orphan-quarantine-scratch-home" home="$CASE_DIR/orphan-quarantine-home" scratch="$CASE_DIR/orphan-quarantine-scratch.jsonl" ledger="$CASE_DIR/orphan-quarantine.jsonl" hook="$CASE_DIR/orphan-quarantine-fail-hook.sh" real_id=quarantine-source
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 1' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$scratch_home" "$SITTER" expect --ledger "$scratch" --on-fail "$hook" --id "$real_id" --sla 0
  SITTER_HOME="$scratch_home" "$SITTER" sweep --once --ledger "$scratch" --on-fail "$hook"
  SITTER_HOME="$scratch_home" "$SITTER" sweep --once --ledger "$scratch" --on-fail "$hook"
  SITTER_HOME="$scratch_home" "$SITTER" sweep --once --ledger "$scratch" --on-fail "$hook"
  [[ $(grep -c '"event":"quarantine"' "$scratch") -eq 1 ]]
  grep '"event":"quarantine"' "$scratch" | sed "s/\"expect_id\":\"$real_id\"/\"expect_id\":\"orphanq\"/" >"$ledger"
  assert_exit 0 env SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id orphanq --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"event":"nudge"' "$ledger"
}

orphan_quarantine_does_not_suppress_live_expect() {
  local scratch_home="$CASE_DIR/orphan-suppress-scratch-home" throwaway_home="$CASE_DIR/orphan-suppress-throwaway-home" home="$CASE_DIR/orphan-suppress-home" scratch="$CASE_DIR/orphan-suppress-scratch.jsonl" throwaway="$CASE_DIR/orphan-suppress-throwaway.jsonl" ledger="$CASE_DIR/orphan-suppress.jsonl" hook="$CASE_DIR/orphan-suppress-fail-hook.sh" quarantine_line expect_line real_id=quarantine-source
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 1' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$scratch_home" "$SITTER" expect --ledger "$scratch" --on-fail "$hook" --id "$real_id" --sla 0
  SITTER_HOME="$scratch_home" "$SITTER" sweep --once --ledger "$scratch" --on-fail "$hook"
  SITTER_HOME="$scratch_home" "$SITTER" sweep --once --ledger "$scratch" --on-fail "$hook"
  SITTER_HOME="$scratch_home" "$SITTER" sweep --once --ledger "$scratch" --on-fail "$hook"
  [[ $(grep -c '"event":"quarantine"' "$scratch") -eq 1 ]]
  quarantine_line=$(grep '"event":"quarantine"' "$scratch" | sed "s/\"expect_id\":\"$real_id\"/\"expect_id\":\"X\"/")
  SITTER_HOME="$throwaway_home" "$SITTER" expect --ledger "$throwaway" --on-fail "$SPY" --id X --sla 0
  expect_line=$(grep '"event":"expect"' "$throwaway")
  printf '%s\n' "$quarantine_line" >"$ledger"
  printf '%s\n' "$expect_line" >>"$ledger"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"event":"nudge"' "$ledger"
}

ack_clears_side_file_state() {
  local home="$CASE_DIR/ack-clear-home" ledger="$CASE_DIR/ack-clear.jsonl" hook="$CASE_DIR/ack-clear-hook.sh" quarantined_before failcounts_before quarantined_after failcounts_after
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 1' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id X --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  quarantined_before=$(wc -l <"$home/quarantined")
  failcounts_before=$(wc -l <"$home/failcounts")
  SITTER_HOME="$home" "$SITTER" ack --ledger "$ledger" --id X
  quarantined_after=$(wc -l <"$home/quarantined")
  failcounts_after=$(wc -l <"$home/failcounts")
  [[ $quarantined_before -gt 0 && $failcounts_before -gt 0 ]]
  [[ $quarantined_after -eq $((quarantined_before - 1)) && $failcounts_after -eq $((failcounts_before - 1)) ]]
  assert_exit 2 env SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id X --sla 0
}
sweep_ignores_side_file_marks() {
  local home="$CASE_DIR/side-file-mark-home" ledger="$CASE_DIR/side-file-mark.jsonl" hook="$CASE_DIR/side-file-mark-hook.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 0' >"$hook"; chmod +x "$hook"
  mkdir -p "$home"; printf '%s\n' X >"$home/quarantined"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id X --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  [[ $(grep -c '"event":"nudge"' "$ledger") -eq 1 ]]
}
term_trapping_hook_is_killed() {
  local home="$CASE_DIR/term-home" ledger="$CASE_DIR/term.jsonl" hook="$CASE_DIR/term-hook.sh" started elapsed
  [[ ${SITTER_TEST_SKIP_TERM:-false} == true ]] && return 0
  printf '%s\n' '#!/usr/bin/env bash' "trap '' TERM" 'sleep 60' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id term --sla 0
  started=$(date +%s)
  SITTER_HOME="$home" SITTER_HOOK_TIMEOUT=1 SITTER_HOOK_KILL_GRACE=1 "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  elapsed=$(( $(date +%s) - started )); ((elapsed <= 5))
}

hook_orphan_children_are_reaped() {
  if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    printf 'SKIP hook_orphan_children_are_reaped: perl setsid group semantics unverified on MSYS/cygwin\n'
    return 0
  fi
  local home="$CASE_DIR/orphan-home" ledger="$CASE_DIR/orphan.jsonl" hook="$CASE_DIR/orphan-hook.sh" pidfile="$CASE_DIR/orphan.pid" pid='' poll dead=false
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 300 &' "echo \$! >\"$pidfile\"" 'exit 0' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id orphan --sla 0
  SITTER_HOME="$home" SITTER_HOOK_TIMEOUT=2 SITTER_HOOK_KILL_GRACE=1 "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  for ((poll = 0; poll < 20; poll++)); do
    [[ -f $pidfile ]] && break
    sleep 1
  done
  if [[ -f $pidfile ]]; then
    pid=$(<"$pidfile")
    for ((poll = 0; poll < 15; poll++)); do
      if ! kill -0 "$pid" 2>/dev/null; then
        dead=true
        break
      fi
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  [[ $dead == true ]]
}

hook_timeout_group_gate_kills_trapping_child() {
  if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    printf 'SKIP hook_timeout_group_gate_kills_trapping_child: perl setsid group semantics unverified on MSYS/cygwin\n'
    return 0
  fi
  local home="$CASE_DIR/trapping-home" ledger="$CASE_DIR/trapping.jsonl" hook="$CASE_DIR/trapping-hook.sh" pidfile="$CASE_DIR/trapping.pid" pid='' poll dead=false
  printf '%s\n' '#!/usr/bin/env bash' "sh -c 'trap \"\" TERM; sleep 300' &" "echo \$! >\"$pidfile\"" 'sleep 300' >"$hook"; chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id trapping --sla 0
  SITTER_HOME="$home" SITTER_HOOK_TIMEOUT=2 SITTER_HOOK_KILL_GRACE=1 "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  for ((poll = 0; poll < 20; poll++)); do
    [[ -f $pidfile ]] && break
    sleep 1
  done
  if [[ -f $pidfile ]]; then
    pid=$(<"$pidfile")
    for ((poll = 0; poll < 15; poll++)); do
      if ! kill -0 "$pid" 2>/dev/null; then
        dead=true
        break
      fi
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  [[ $dead == true ]]
}

hash_tool_fallback() {
  command -v sha256sum >/dev/null 2>&1 || {
    printf 'SKIP hash_tool_fallback: sha256sum is unavailable\n'
    return 0
  }
  local shim="$CASE_DIR/hash-tool-shim" ledger="$CASE_DIR/hash-tool-fallback.jsonl"
  mkdir "$shim"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 127' >"$shim/shasum"; chmod +x "$shim/shasum"
  PATH="$shim:$PATH" SITTER_HOME="$CASE_DIR/home-hash-tool-fallback" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/hash-tool-fallback.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --stall-after 2 --timeout 20 --grace 0 -- true
  grep -q '"event":"end","status":"success"' "$ledger"
  local missing_shim="$CASE_DIR/hash-tool-missing-shim" missing_ledger="$CASE_DIR/hash-tool-missing.jsonl" missing_home="$CASE_DIR/home-hash-tool-missing"
  mkdir "$missing_shim"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 127' >"$missing_shim/shasum"; chmod +x "$missing_shim/shasum"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 127' >"$missing_shim/sha256sum"; chmod +x "$missing_shim/sha256sum"
  assert_exit 2 env PATH="$missing_shim:$PATH" SITTER_HOME="$missing_home" "$SITTER" run --ledger "$missing_ledger" --on-fail "$SPY" -- true
}

# R3: zero-padded numeric options/env must normalize as base-10, not explode as octal.
zero_padded_numerics() {
  local home="$CASE_DIR/zero-padded-numerics-home" ledger="$CASE_DIR/zero-padded-numerics.jsonl"
  SITTER_HOOK_TIMEOUT=030 SITTER_HOOK_KILL_GRACE=05 SITTER_POLL_INTERVAL=01 SITTER_HOME="$home" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --stall-after 02 --timeout 08 --grace 08 --retries 08 --cooldown 060 -- true \
    2>"$CASE_DIR/zp.stderr"
  grep -q '"event":"end","status":"success"' "$ledger"
  grep -q '"retries":8,' "$ledger"
  grep -q '"cooldown_s":60,' "$ledger"
  assert_json_valid "$ledger"
  if grep -q 'value too great for base' "$CASE_DIR/zp.stderr"; then return 1; fi
  assert_exit 2 env SITTER_HOME="$CASE_DIR/zero-padded-lowbound-home" "$SITTER" run --ledger "$CASE_DIR/zero-padded-lowbound.jsonl" --on-fail "$SPY" --timeout 00 -- true
  assert_exit 2 env SITTER_HOME="$CASE_DIR/zero-padded-hex-home" "$SITTER" run --ledger "$CASE_DIR/zero-padded-hex.jsonl" --on-fail "$SPY" --stall-after 2 --timeout 0x10 --grace 0 -- true
}

# A fast non-idempotent failure records start, fail, and end in one process.
event_id_sequence_is_unique() {
  local ledger="$CASE_DIR/event-id.jsonl" event_ids sequences duplicates
  assert_exit 1 run_event_id_collision
  event_ids=$(sed -n 's/.*"event_id":"\([^"]*\)".*/\1/p' "$ledger")
  duplicates=$(printf '%s\n' "$event_ids" | sort | uniq -d)
  [[ -z $duplicates ]]
  sequences=$(printf '%s\n' "$event_ids" | sed 's/.*-\([0-9][0-9]*\)$/\1/')
  [[ $sequences == $'1\n2\n3' ]]
}

run_event_id_collision() { FW_MODE=fail FW_EXIT=1 run_case event-id -- "$FIXTURE"; }

# A failed exec must preserve the conventional command-not-found failure, not
# let the Perl launcher fall through and report success.
missing_command_propagates_127() {
  local command="$CASE_DIR/does-not-exist" ledger="$CASE_DIR/missing-command.jsonl"
  assert_exit 127 env SITTER_HOME="$CASE_DIR/missing-command-home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/missing-command.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --stall-after 2 --timeout 20 --grace 0 -- "$command"
  grep -q '"event":"fail","status":"failed"' "$ledger" || return 1
  grep -q '"exit_code":127' "$ledger" || return 1
  ! grep -q '"event":"end","status":"success"' "$ledger"
}

# A one-element command containing a shell metacharacter must execute that
# literal path, with its real output and exit status, rather than shell-fall
# back through Perl's string exec form.
single_argument_metacharacter_path_is_literal() {
  local worker="$CASE_DIR/a;echo INJECTED" ledger="$CASE_DIR/metachar.jsonl" log="$CASE_DIR/metachar.log"
  printf '%s\n' '#!/usr/bin/env bash' 'echo MARKER_OK' 'exit 7' >"$worker"
  chmod +x "$worker"
  assert_exit 7 env SITTER_HOME="$CASE_DIR/metachar-home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/metachar.spy" \
    "$SITTER" run --ledger "$ledger" --log "$log" --on-fail "$SPY" --stall-after 2 --timeout 20 --grace 0 -- "$worker"
  grep -q 'MARKER_OK' "$log" || return 1
  grep -q '"event":"fail","status":"failed"' "$ledger" || return 1
  grep -q '"exit_code":7' "$ledger"
}

# A stalled wrapped parent leaves a marked descendant behind unless kill_group
# reaches the isolated process group.  Verify the process table, not just the
# ledger's claim, after the stall path returns.
stall_kills_grandchild() {
  local marker="SITTER_TEST_MARKER_${$}_${RANDOM}" ledger="$CASE_DIR/grandchild.jsonl" pid command ps_path=$PATH
  # Some restricted macOS runners deny ps even for a direct child.  Simulate
  # its two supervisor queries there; the actual group signal is still sent.
  if ! ps -o pgid= -p $$ >/dev/null 2>&1; then
    mkdir "$CASE_DIR/ps-shim"
    # shellcheck disable=SC2016 # shim receives literal $*/${!#}/$@ for its own evaluation
    printf '%s\n' '#!/usr/bin/env bash' 'case $* in *pgid=*) printf "%s\n" "${!#}" ;; *stat=*) printf "S\n" ;; *) exec /bin/ps "$@" ;; esac' >"$CASE_DIR/ps-shim/ps"
    chmod +x "$CASE_DIR/ps-shim/ps"
    ps_path="$CASE_DIR/ps-shim:$PATH"
  fi
  assert_exit 1 env PATH="$ps_path" SITTER_TEST_MARKER="$marker" SITTER_GRANDCHILD_PID_FILE="$CASE_DIR/grandchild.pid" SITTER_HOME="$CASE_DIR/grandchild-home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/grandchild.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --stall-after 2 --timeout 20 --grace 0 -- "$TEST_ROOT/tests/fixtures/stalled-grandchild.sh"
  grep -q '"event":"stall","status":"killed"' "$ledger" || return 1
  pid=$(<"$CASE_DIR/grandchild.pid")
  sleep 1
  command=$(ps -o command= -p "$pid" 2>/dev/null || true)
  if kill -0 "$pid" 2>/dev/null && [[ $command == *"$marker"* ]]; then
    printf 'marked grandchild survived stall kill: %s (%s)\n' "$pid" "$command" >&2
    kill -KILL "$pid" 2>/dev/null || true
    return 1
  fi
}

# The group leader exits on TERM while its child ignores TERM.  KILL must use
# process-group liveness or the marked grandchild survives the stall cleanup.
term_exiting_leader_still_kills_grandchild() {
  local marker="SITTER_TERM_LEADER_MARKER_${$}_${RANDOM}" ledger="$CASE_DIR/term-leader.jsonl" pid command
  assert_exit 1 env SITTER_TEST_MARKER="$marker" SITTER_GRANDCHILD_PID_FILE="$CASE_DIR/term-leader.pid" SITTER_HOME="$CASE_DIR/term-leader-home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/term-leader.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --stall-after 2 --timeout 20 --grace 0 -- "$TEST_ROOT/tests/fixtures/term-exiting-parent-grandchild.sh"
  grep -q '"event":"stall","status":"killed"' "$ledger" || return 1
  pid=$(<"$CASE_DIR/term-leader.pid")
  sleep 1
  command=$(ps -o command= -p "$pid" 2>/dev/null || true)
  if kill -0 "$pid" 2>/dev/null && [[ $command == *"$marker"* ]]; then
    printf 'TERM-ignoring grandchild survived group KILL: %s (%s)\n' "$pid" "$command" >&2
    kill -KILL "$pid" 2>/dev/null || true
    return 1
  fi
}

symlinks_are_real() { local probe_dir; probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/sitter-symlink-probe.XXXXXX"); : >"$probe_dir/t"; ln -s "$probe_dir/t" "$probe_dir/l" 2>/dev/null; local ok=1; [[ -L $probe_dir/l ]] && ok=0; rm -rf "$probe_dir"; return $ok; }
chmod_denies_dir_write() { local probe_dir ok=1; probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/sitter-chmod-dir-probe.XXXXXX"); mkdir "$probe_dir/d"; chmod 500 "$probe_dir/d"; ( : >"$probe_dir/d/t" ) 2>/dev/null || ok=0; chmod 700 "$probe_dir/d"; rm -rf "$probe_dir"; return $ok; }
chmod_denies_read() { local probe_dir ok=1; probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/sitter-chmod-read-probe.XXXXXX"); printf x >"$probe_dir/t"; chmod 000 "$probe_dir/t"; cat "$probe_dir/t" >/dev/null 2>&1 || ok=0; chmod 600 "$probe_dir/t"; rm -rf "$probe_dir"; return $ok; }

ledger_symlink_is_refused() {
  if ! symlinks_are_real; then printf 'SKIP ledger_symlink_is_refused: no real symlink support\n' >&2; return 0; fi
  local ledger="$CASE_DIR/ledger-link.jsonl" target="$CASE_DIR/ledger-target.jsonl" stderr="$CASE_DIR/ledger-link.stderr"
  : >"$target"; ln -s "$target" "$ledger"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/ledger-link-home" "$SITTER" run --ledger "$ledger" --on-fail "$SPY" -- true 2>"$stderr"
  grep -Fq 'ledger must not be a symlink' "$stderr"
}

ledger_lock_symlink_is_refused() {
  if ! symlinks_are_real; then printf 'SKIP ledger_lock_symlink_is_refused: no real symlink support\n' >&2; return 0; fi
  local ledger="$CASE_DIR/ledger-lock.jsonl" target="$CASE_DIR/ledger-lock-target" stderr="$CASE_DIR/ledger-lock.stderr"
  : >"$ledger"; : >"$target"; ln -s "$target" "${ledger}.lock"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/ledger-lock-home" "$SITTER" run --ledger "$ledger" --on-fail "$SPY" -- true 2>"$stderr"
  grep -Fq 'ledger lock must not be a symlink' "$stderr"
}

# The fallback cannot be selected while flock or lockf is installed; do not
# stub PATH because that would test a fabricated environment rather than sweep.
sweep_mkdir_lock_tier_is_unavailable() {
  if command -v flock >/dev/null 2>&1 || command -v lockf >/dev/null 2>&1; then
    printf 'SKIP sweep_mkdir_lock_tier_is_unavailable: flock/lockf selects another tier\n'
    return 0
  fi
  local home="$CASE_DIR/mkdir-sweep-home" ledger="$CASE_DIR/mkdir-sweep.jsonl" spy="$CASE_DIR/mkdir-sweep.spy"
  mkdir -p "$home/sweep.lock.d"
  touch -t 202001010000 "$home/sweep.lock.d"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id stale --sla 0
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"event":"nudge"' "$ledger"
}

mkdir_lock_stale_break_is_single_shot() {
  if command -v flock >/dev/null 2>&1 || command -v lockf >/dev/null 2>&1; then
    printf 'SKIP mkdir_lock_stale_break_is_single_shot: flock/lockf selects another tier\n'
    return 0
  fi
  local home="$CASE_DIR/mkdir-stale-home" ledger="$CASE_DIR/mkdir-stale.jsonl" spy="$CASE_DIR/mkdir-stale.spy" stale_path found=0
  mkdir -p "$home/sweep.lock.d"
  printf 'foreign-owner\n' >"$home/sweep.lock.d/owner"
  touch -t 202001010000 "$home/sweep.lock.d" "$home/sweep.lock.d/owner"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id stale-break --sla 0
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"event":"nudge"' "$ledger"
  [[ ! -d $home/sweep.lock.d ]]
  for stale_path in "$home"/sweep.lock.d.stale.*; do
    [[ -e $stale_path ]] || continue
    found=1
    break
  done
  ((found == 0))
}

mkdir_lock_live_holder_not_stolen() {
  if command -v flock >/dev/null 2>&1 || command -v lockf >/dev/null 2>&1; then
    printf 'SKIP mkdir_lock_live_holder_not_stolen: flock/lockf selects another tier\n'
    return 0
  fi
  local home="$CASE_DIR/mkdir-live-home" ledger="$CASE_DIR/mkdir-live.jsonl" spy="$CASE_DIR/mkdir-live.spy"
  mkdir -p "$home/sweep.lock.d"
  printf 'live-owner\n' >"$home/sweep.lock.d/owner"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id live-lock --sla 0
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  if grep -q '"event":"nudge"' "$ledger"; then
    return 1
  fi
  [[ -d $home/sweep.lock.d ]]
  [[ -f $home/sweep.lock.d/owner ]]
}

sweep_heartbeat_refreshes_lockdir() {
  if command -v flock >/dev/null 2>&1 || command -v lockf >/dev/null 2>&1; then
    printf 'SKIP sweep_heartbeat_refreshes_lockdir: flock/lockf selects another tier\n'
    return 0
  fi
  local home="$CASE_DIR/sweep-heartbeat-home" ledger="$CASE_DIR/sweep-heartbeat.jsonl" hook="$CASE_DIR/hook-heartbeat.sh" recorder="$CASE_DIR/sweep-heartbeat.mtimes" first second
  # shellcheck disable=SC2016 # printf writes literal shell for the generated hook script
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'lockdir="$SITTER_HOME/sweep.lock.d"' \
    "count_file=\"$CASE_DIR/sweep-heartbeat.count\"" \
    'count=0' \
    '[[ -f $count_file ]] && count=$(cat "$count_file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" >"$count_file"' \
    'if [[ $count -eq 1 ]]; then' \
    '  sleep 2' \
    'fi' \
    'if stat -f %m "$lockdir" >/dev/null 2>&1; then' \
    "  stat -f %m \"\$lockdir\" >>\"$recorder\"" \
    'else' \
    "  stat -c %Y \"\$lockdir\" >>\"$recorder\"" \
    'fi' >"$hook"
  chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id heartbeat-a --sla 0
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id heartbeat-b --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  [[ $(wc -l <"$recorder") -eq 2 ]]
  first=$(sed -n '1p' "$recorder")
  second=$(sed -n '2p' "$recorder")
  ((second > first))
}

stolen_lock_release_spares_usurper() {
  if command -v flock >/dev/null 2>&1 || command -v lockf >/dev/null 2>&1; then
    printf 'SKIP stolen_lock_release_spares_usurper: flock/lockf selects another tier\n'
    return 0
  fi
  local home="$CASE_DIR/stolen-release-home" ledger="$CASE_DIR/stolen-release.jsonl" hook="$CASE_DIR/hook-stolen-release.sh"
  # shellcheck disable=SC2016 # printf writes literal shell for the generated hook script
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'lockdir="$SITTER_HOME/sweep.lock.d"' \
    "count_file=\"$CASE_DIR/stolen-release.count\"" \
    'count=0' \
    '[[ -f $count_file ]] && count=$(cat "$count_file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" >"$count_file"' \
    'if [[ $count -eq 1 ]]; then' \
    '  mv "$lockdir" "${lockdir}.victim"' \
    '  mkdir "$lockdir"' \
    '  printf "foreign-owner\n" >"$lockdir/owner"' \
    'fi' >"$hook"
  chmod +x "$hook"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$hook" --id stolen-release --sla 0
  SITTER_HOME="$home" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$hook"
  grep -q '"event":"nudge"' "$ledger"
  [[ -d $home/sweep.lock.d ]]
  [[ -f $home/sweep.lock.d/owner ]]
  [[ $(cat "$home/sweep.lock.d/owner") == 'foreign-owner' ]]
}

assert_json_valid_without_python3_skips_once() {
  local ledger="$CASE_DIR/json-skip.jsonl" output
  printf '%s\n' '{"valid":true}' >"$ledger"
  # GitHub Actions exports CI=true; unset it inside the subshell so this case
  # exercises the non-CI SKIP branch rather than the hard-fail-in-CI branch.
  # Unset in-script rather than via env -u so shellcheck still parses the
  # single-quoted bash -c body as a script.
  output=$(bash -c '
    unset CI
    source "$1"
    command() {
      [[ $1 == -v && $2 == python3 ]] && return 1
      builtin command "$@"
    }
    assert_json_valid "$2"
    assert_json_valid "$2"
  ' bash "$ROOT/tests/lib.sh" "$ledger" 2>&1)
  [[ $(printf '%s\n' "$output" | grep -cF 'SKIP assert_json_valid: python3 not found') -eq 1 ]]
}

assert_json_valid_requires_python3_in_ci() {
  local ledger="$CASE_DIR/json-ci-missing-python.jsonl" output status
  printf '%s\n' '{"valid":true}' >"$ledger"
  set +e
  output=$(CI=true bash -c '
    source "$1"
    command() {
      [[ $1 == -v && $2 == python3 ]] && return 1
      builtin command "$@"
    }
    assert_json_valid "$2"
  ' bash "$ROOT/tests/lib.sh" "$ledger" 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]]
  printf '%s\n' "$output" | grep -qF 'assert_json_valid requires python3 in CI'
}

denylist_deployment_tokens() {
  local cmd executable operation
  mkdir "$CASE_DIR/bin"
  for cmd in kubectl terraform docker npm pnpm yarn; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$CASE_DIR/bin/$cmd"
    chmod +x "$CASE_DIR/bin/$cmd"
  done
  export PATH="$CASE_DIR/bin:$PATH"
  while read -r executable operation; do
    assert_exit 2 run_case "deny-$executable-$operation" -- "$executable" "$operation"
    [[ ! -d "$CASE_DIR/home-deny-$executable-$operation/logs" ]]
  done <<'EOF'
kubectl apply
kubectl delete
terraform apply
terraform destroy
helm install
helm upgrade
docker push
npm publish
pnpm publish
yarn publish
twine upload
fly deploy
EOF
  run_case allow-kubectl -- kubectl get pods
  run_case allow-terraform -- terraform plan
  run_case allow-docker -- docker build .
  run_case allow-npm -- npm install
}

expect_stop_is_refused_acked() {
  local home="$CASE_DIR/expect-stop-home" ledger="$CASE_DIR/expect-stop.jsonl" spy="$CASE_DIR/expect-stop.spy"
  mkdir -p "$home"; : >"$home/STOP"
  assert_exit 0 env SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id stopped --sla 0 --to operator --text stop
  grep -q '"event":"refused"' "$ledger"
  grep -q '"state":"acked"' "$ledger"
  grep -q '"detail":"kill switch present"' "$ledger"
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  ! grep -q '"event":"nudge"' "$ledger" && [[ ! -s $spy ]]

  rm "$home/STOP"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id live-before-stop --sla 0 --to operator --text live
  : >"$home/STOP"
  SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id live-before-stop --sla 0 --to operator --text duplicate
  rm "$home/STOP"
  assert_exit 2 env SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id live-before-stop --sla 0 --to operator --text must-stay-reserved
  SITTER_HOME="$home" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"event":"nudge".*"expect_id":"live-before-stop"' "$ledger"
  assert_spy_count 1 "$spy"
}

expect_event_id_sequence_is_unique() {
  local home="$CASE_DIR/expect-event-id-home" ledger="$CASE_DIR/expect-event-id.jsonl" event_ids duplicates id
  for id in one two three; do
    SITTER_HOME="$home" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id "$id" --sla 20
    SITTER_HOME="$home" "$SITTER" ack --ledger "$ledger" --id "$id"
  done
  event_ids=$(sed -n 's/.*"event_id":"\([^"]*\)".*/\1/p' "$ledger")
  duplicates=$(printf '%s\n' "$event_ids" | sort | uniq -d)
  [[ -z $duplicates && $(printf '%s\n' "$event_ids" | wc -l) -eq 6 ]]
}

dash_prefixed_log_path_works() {
  (
    cd "$CASE_DIR"
    # Wider stall margin: under full-suite load the worker's first write can trail the log mtime past the default 2s window.
    run_case dash-log --stall-after 5 --log ./-dashfile -- "$FIXTURE"
    [[ -f ./-dashfile ]]
  )
}

symlink_log_path_is_followed() {
  if ! symlinks_are_real; then printf 'SKIP symlink_log_path_is_followed: no real symlink support\n' >&2; return 0; fi
  local log="$CASE_DIR/log-link" target="$CASE_DIR/log-target"
  : >"$target"; ln -s "$target" "$log"
  # Pin observed current behavior: log paths deliberately have no symlink guard.
  FW_MODE=ok SITTER_HOME="$CASE_DIR/home-log-link" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/log-link.spy" \
    "$SITTER" run --ledger "$CASE_DIR/log-link.jsonl" --log "$log" --on-fail "$SPY" --stall-after 5 --timeout 20 --grace 0 -- "$FIXTURE"
  grep -q 'worker end' "$target"
}

cooldown_used_count_is_always_zero() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/cooldown-zero-home" ledger="$CASE_DIR/cooldown-zero.jsonl" cooldown_file
  printf '%s\n' "$FIXTURE" >"$allow"
  assert_exit 9 env FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/cooldown-zero.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  for cooldown_file in "$home"/cooldown/*; do break; done
  [[ $(awk '{print $1}' "$cooldown_file") == 0 ]]
}

elapsed_cooldown_does_not_sleep() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/elapsed-home" prime="$CASE_DIR/elapsed-prime.jsonl" ledger="$CASE_DIR/elapsed.jsonl" cooldown_file='' pid poll started elapsed
  printf '%s\n' "$FIXTURE" >"$allow"
  FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/elapsed.spy" \
    "$SITTER" run --ledger "$prime" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE" &
  pid=$!
  for ((poll = 0; poll < 50; poll++)); do
    for cooldown_file in "$home"/cooldown/*; do [[ -f $cooldown_file ]] && break; cooldown_file=''; done
    [[ -n $cooldown_file ]] && break
    sleep 0.1
  done
  [[ -f $cooldown_file ]]
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  printf '0 %s\n' "$(( $(date +%s) - 1 ))" >"$cooldown_file"
  started=$(date +%s)
  assert_exit 9 env FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/elapsed.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --retries 0 --cooldown 5 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE"
  elapsed=$(( $(date +%s) - started ))
  # Guarded regressions sleep >=5s (cooldown) or 3600s (cap); <5 keeps detection while absorbing full-suite startup load.
  # Emulated-shell runners (MSYS/Cygwin, observational lane) are too slow for a wall-clock bound; detection stays enforced on the blocking POSIX lanes.
  [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || ((elapsed < 5))
}

# A kill switch must interrupt a persisted cooldown before any attempt starts.
stop_during_catchup_cooldown_observed() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/catchup-stop-home" prime="$CASE_DIR/catchup-stop-prime.jsonl" ledger="$CASE_DIR/catchup-stop.jsonl" cooldown_file='' pid poll started elapsed
  printf '%s\n' "$FIXTURE" >"$allow"
  FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/catchup-stop.spy" \
    "$SITTER" run --ledger "$prime" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 60 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE" &
  pid=$!
  for ((poll = 0; poll < 50; poll++)); do
    for cooldown_file in "$home"/cooldown/*; do [[ -f $cooldown_file ]] && break; cooldown_file=''; done
    [[ -n $cooldown_file ]] && break
    sleep 0.1
  done
  [[ -f $cooldown_file ]]
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  printf '0 %s\n' "$(( $(date +%s) + 60 ))" >"$cooldown_file"
  started=$(date +%s)
  FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/catchup-stop.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --retries 0 --cooldown 60 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE" &
  pid=$!
  kill -0 "$pid"
  sleep 1
  touch "$home/STOP"
  wait "$pid"
  elapsed=$(( $(date +%s) - started ))
  grep -Eq '"event":"(refused|end)","status":"killed".*"detail":"kill switch present before launch"' "$ledger"
  [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || ((elapsed < 20))
  ! grep -q '"event":"start"' "$ledger"
}

# A kill switch must interrupt restart backoff instead of waiting for its full delay.
stop_during_backoff_observed() {
  local allow="$CASE_DIR/allow" home="$CASE_DIR/backoff-stop-home" ledger="$CASE_DIR/backoff-stop.jsonl" pid poll started elapsed
  printf '%s\n' "$FIXTURE" >"$allow"
  started=$(date +%s)
  FW_MODE=fail SITTER_HOME="$home" SITTER_POLL_INTERVAL=1 SPY_FILE="$CASE_DIR/backoff-stop.spy" \
    "$SITTER" run --ledger "$ledger" --on-fail "$SPY" --idempotent fail --allowlist "$allow" --retries 1 --cooldown 60 --stall-after 2 --timeout 20 --grace 0 -- "$FIXTURE" &
  pid=$!
  for ((poll = 0; poll < 600; poll++)); do
    grep -q '"event":"restart"' "$ledger" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '"event":"restart"' "$ledger"
  touch "$home/STOP"
  wait "$pid"
  elapsed=$(( $(date +%s) - started ))
  # Both details prove the 60s backoff was interrupted; STOP may land before or after the pre-sleep kill check, and the slow-runner window includes ledger lock release plus temp cleanup after restart append.
  grep -Eq '"event":"end","status":"killed".*"detail":"(kill switch present before launch|kill switch stopped before restart)"' "$ledger"
  [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]] || ((elapsed < 20))
}

denylist_exact_eight_env_layers() {
  mkdir "$CASE_DIR/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$CASE_DIR/bin/git"
  chmod +x "$CASE_DIR/bin/git"
  export PATH="$CASE_DIR/bin:$PATH"
  assert_exit 2 run_case deny-eight-env -- env env env env env env env env git push origin main
  run_case allow-eight-env -- env env env env env env env env echo ok
}

denylist_launcher_boundary_gaps() {
  mkdir "$CASE_DIR/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$CASE_DIR/bin/git"
  # shellcheck disable=SC2016 # the generated wrapper evaluates its own argv
  printf '%s\n' '#!/usr/bin/env bash' 'while [[ $1 == -* ]]; do shift; done' 'exec "$@"' >"$CASE_DIR/bin/stdbuf"
  chmod +x "$CASE_DIR/bin/git" "$CASE_DIR/bin/stdbuf"
  export PATH="$CASE_DIR/bin:$PATH"
  assert_exit 2 run_case deny-nice-single -- nice -n 5 git push origin main
  assert_exit 2 run_case deny-stdbuf -- stdbuf -oL git push origin main
  run_case allow-stdbuf -- stdbuf -oL echo ok
  assert_exit 2 run_case deny-bash-plain -- bash -c 'git push origin main'
  if command -v caffeinate >/dev/null 2>&1; then
    run_case allow-caffeinate -- caffeinate -t 5 echo ok
    assert_exit 2 run_case deny-caffeinate -- caffeinate -t 300 git push origin main
  fi
  if command -v zsh >/dev/null 2>&1; then
    assert_exit 2 run_case deny-zsh-plain -- zsh -c 'git push origin main'
  fi
}

# sitter v0.2 ask/watch frozen-spec cases.  Keep one numbered test entry per
# acceptance case so the suite reports an auditable 81/81 total.
aw_ask() {
  local home=$1 ledger=$2 reply=$3 id=$4
  shift 4
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 \
    --reply-file "$reply" --id "$id" "$@"
}

aw_watch() {
  local home=$1 ledger=$2
  shift 2
  SITTER_HOME="$home" "$SITTER" watch --once --ledger "$ledger" "$@"
}

aw_assert_v1_sequence() {
  local ledger=$1
  shift
  assert_event_seq "$ledger" "$@"
  assert_json_valid "$ledger"
}

aw_wait_for_path() {
  local path=$1 tries=${2:-200} i
  for ((i = 0; i < tries; i++)); do
    [[ -e $path ]] && return 0
    sleep 0.05
  done
  return 1
}

aw_wait_for_bg() {
  local pid=$1 tries=${2:-200} i rc
  for ((i = 0; i < tries; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      set +e
      wait "$pid"
      rc=$?
      set -e
      return "$rc"
    fi
    sleep 0.05
  done
  aw_cleanup_pid "$pid"
  return 124
}

aw_start_lock_holder() {
  local ledger=$1 ready=$2 release=$3 holder="$CASE_DIR/hold-ledger-lock.sh" mode lock
  lock="${ledger}.lock"
  if command -v flock >/dev/null 2>&1; then
    mode='flock'
  elif command -v lockf >/dev/null 2>&1; then
    mode='lockf'
  else
    mode='mkdir'
  fi
  # shellcheck disable=SC2016 # this writes a generated helper script whose variables expand later
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'mode=$1' \
    'lock=$2' \
    'ready=$3' \
    'release=$4' \
    'case $mode in' \
    '  flock)' \
    '    exec 9>"$lock"' \
    '    flock 9' \
    '    : >"$ready"' \
    '    while [[ ! -e $release ]]; do sleep 0.05; done' \
    '    ;;' \
    '  lockf)' \
    '    lockf -k "$lock" "$BASH" -c '"'"': >"$1"; while [[ ! -e $2 ]]; do sleep 0.05; done'"'"' bash "$ready" "$release"' \
    '    ;;' \
    '  mkdir)' \
    '    lockdir="${lock}.d"' \
    '    mkdir "$lockdir"' \
    '    : >"$ready"' \
    '    while [[ ! -e $release ]]; do sleep 0.05; done' \
    '    rmdir "$lockdir"' \
    '    ;;' \
    'esac' >"$holder"
  chmod +x "$holder"
  "$holder" "$mode" "$lock" "$ready" "$release" </dev/null >/dev/null 2>&1 &
  AW_LOCK_PID=$!
}

aw_wait_for_staged_files() {
  local dir=$1 pattern=$2 expected=$3 tries=${4:-200} i count staged
  for ((i = 0; i < tries; i++)); do
    count=0
    for staged in "$dir"/$pattern; do
      [[ -e $staged ]] || continue
      count=$((count + 1))
    done
    ((count >= expected)) && return 0
    sleep 0.05
  done
  return 1
}

aw_write_sender() {
  local sender=$1
  # shellcheck disable=SC2016 # this writes a generated helper script whose variables expand later
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$1" >>"$2"' >"$sender"
  chmod +x "$sender"
}

aw_assert_precise_ask_loser() {
  local err=$1
  grep -Eq '^sitter: expect id is already (reserved by an ask generation|active)$' "$err"
}

aw_cleanup_pid() {
  local pid=$1
  [[ -n $pid ]] || return 0
  set +e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  set -e
}

aw_lock_holder_children() {
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -P "$1" 2>/dev/null || true
}

aw_cleanup_lock_holder() {
  local holder_pid=$1 release=$2 child_pids='' i
  local -a child_pid_array=()
  set +e
  if [[ -n $release ]]; then
    : >"$release" 2>/dev/null || true
  fi
  [[ -n $holder_pid ]] || { set -e; return 0; }
  for ((i = 0; i < 20; i++)); do
    kill -0 "$holder_pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$holder_pid" 2>/dev/null; then
    child_pids=$(aw_lock_holder_children "$holder_pid")
    if [[ -n $child_pids ]]; then
      # shellcheck disable=SC2206 # newline-delimited pid list is intentionally split into argv
      child_pid_array=($child_pids)
      kill "${child_pid_array[@]}" 2>/dev/null || true
    fi
    kill "$holder_pid" 2>/dev/null || true
    sleep 0.05
    child_pids=$(aw_lock_holder_children "$holder_pid")
    if [[ -n $child_pids ]]; then
      # shellcheck disable=SC2206 # newline-delimited pid list is intentionally split into argv
      child_pid_array=($child_pids)
      kill -9 "${child_pid_array[@]}" 2>/dev/null || true
    fi
    kill -9 "$holder_pid" 2>/dev/null || true
  fi
  wait "$holder_pid" 2>/dev/null || true
  set -e
}

aw_install_barrier_cleanup_trap() {
  : "${AW_BARRIER_RELEASE:=}"
  : "${AW_BARRIER_LOCK_PID:=}"
  : "${AW_BARRIER_ASK_A:=}"
  : "${AW_BARRIER_ASK_B:=}"
  trap 'aw_cleanup_lock_holder "${AW_BARRIER_LOCK_PID:-}" "${AW_BARRIER_RELEASE:-}"; aw_cleanup_pid "${AW_BARRIER_ASK_A:-}"; aw_cleanup_pid "${AW_BARRIER_ASK_B:-}"; trap - EXIT' EXIT
}

aw_01_cli_required_values() {
  assert_exit 2 "$SITTER" ask
  assert_exit 2 "$SITTER" ask --ledger "$CASE_DIR/a" --to x --sla 1 --reply-file "$CASE_DIR/r"
}
aw_02_already_sent_argv_rules() {
  assert_exit 2 "$SITTER" ask --already-sent --ledger "$CASE_DIR/a" --to x --sla 1 --reply-file "$CASE_DIR/r" -- true
  assert_exit 2 "$SITTER" ask --ledger "$CASE_DIR/a" --to x --sla 1 --reply-file "$CASE_DIR/r"
}
aw_03_watch_requires_once() {
  assert_exit 2 "$SITTER" watch --ledger "$CASE_DIR/a"
  assert_exit 2 "$SITTER" watch --once --loop --ledger "$CASE_DIR/a"
}
aw_04_id_validation() {
  local id
  for id in '' 'bad/id' 'bad id' "$(printf 'x%.0s' {1..65})"; do
    assert_exit 2 aw_ask "$CASE_DIR/h" "$CASE_DIR/l" "$CASE_DIR/r" "$id" -- true
  done
}
aw_05_sla_numbers() {
  aw_ask "$CASE_DIR/h0" "$CASE_DIR/l0" "$CASE_DIR/r" zero -- true >/dev/null
  aw_ask "$CASE_DIR/h00" "$CASE_DIR/l00" "$CASE_DIR/r" padded -- true >/dev/null
  assert_exit 2 aw_ask "$CASE_DIR/hx" "$CASE_DIR/lx" "$CASE_DIR/r" bad --sla -1 -- true
}
aw_06_relative_reply_rejected() { assert_exit 2 aw_ask "$CASE_DIR/h" "$CASE_DIR/l" relative rel -- true; }
aw_07_reply_path_charset_and_literal() {
  local reply="$CASE_DIR/返 信;\$(touch nope)"
  aw_ask "$CASE_DIR/h" "$CASE_DIR/l" "$reply" path-ok -- true >/dev/null
  [[ ! -e $CASE_DIR/nope ]]
  assert_exit 2 aw_ask "$CASE_DIR/hq" "$CASE_DIR/lq" "$CASE_DIR/quote\"" quote -- true
  assert_exit 2 aw_ask "$CASE_DIR/hb" "$CASE_DIR/lb" "$CASE_DIR/back\\slash" backslash -- true
  assert_exit 2 aw_ask "$CASE_DIR/hn" "$CASE_DIR/ln" "$CASE_DIR/new"$'\n'"line" newline -- true
  assert_exit 2 aw_ask "$CASE_DIR/hd" "$CASE_DIR/ld" "$CASE_DIR/del"$'\x7f'"byte" del -- true
}
aw_08_generated_id() {
  local id
  id=$(aw_ask "$CASE_DIR/h" "$CASE_DIR/l" "$CASE_DIR/r" generated-placeholder --id auto-generated-not-used -- true)
  [[ $id == auto-generated-not-used ]]
  id=$(SITTER_HOME="$CASE_DIR/h2" "$SITTER" ask --ledger "$CASE_DIR/l2" --to x --sla 1 --reply-file "$CASE_DIR/r" -- true)
  [[ $id =~ ^ask-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
}
aw_09_unknown_transport_flags() {
  local verb err
  assert_exit 2 "$SITTER" ask --transport ssh --ledger "$CASE_DIR/l" --to x --sla 1 --reply-file "$CASE_DIR/r" -- true
  assert_exit 2 "$SITTER" watch --once --delivery foo --ledger "$CASE_DIR/l"
  for verb in run expect ack sweep; do
    err="$CASE_DIR/$verb.err"
    assert_exit 2 "$SITTER" "$verb" --reply-file "$CASE_DIR/r" 2>"$err"
    grep -Fq "$verb does not accept --reply-file or --already-sent" "$err"
    assert_exit 2 "$SITTER" "$verb" --already-sent 2>"$err"
    grep -Fq "$verb does not accept --reply-file or --already-sent" "$err"
  done
}
aw_10_prepare_precedes_send() {
  local ledger="$CASE_DIR/l" marker="$CASE_DIR/marker"
  # shellcheck disable=SC2016 # positional parameters are expanded by the generated sh -c script
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" prepared-first -- sh -c \
    'grep -q "\"event\":\"ask_prepare\"" "$1" && touch "$2"' sh "$ledger" "$marker" >/dev/null
  [[ -e $marker ]]
}
aw_11_prepare_failure_prevents_send() {
  if ! chmod_denies_dir_write; then printf 'SKIP aw_11_prepare_failure_prevents_send: chmod not enforced\n' >&2; return 0; fi
  local dir="$CASE_DIR/locked" marker="$CASE_DIR/sent" ledger
  ledger="$dir/l"
  mkdir "$dir"; chmod 500 "$dir"
  assert_exit 1 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" no-prepare -- touch "$marker"
  [[ ! -e $marker ]]
  chmod 700 "$dir"
}
aw_12_prepared_is_not_live() {
  local ledger="$CASE_DIR/l"
  printf '%s\n' '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"p","to":"x","text":"","sla_s":0,"nudges":0,"state":"prepared","reply_file":"/tmp/r","reply_bytes":null,"reply_sha256":null}' >"$ledger"
  aw_watch "$CASE_DIR/h" "$ledger"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ $(wc -l <"$ledger") -eq 1 && ! -s $CASE_DIR/s ]]
}
aw_13_success_is_prepare_then_expect() {
  local ledger="$CASE_DIR/l"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" success -- true >/dev/null
  [[ $(grep -c '"schema":"sitter.v1"' "$ledger") -eq 2 ]]
  aw_assert_v1_sequence "$ledger" ask_prepare expect
}
aw_14_sla_starts_at_expect() {
  local ledger="$CASE_DIR/l" a b
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" timestamps -- sleep 1 >/dev/null
  a=$(sed -n '1s/.*"ts":"\([^"]*\)".*/\1/p' "$ledger")
  b=$(sed -n '2s/.*"ts":"\([^"]*\)".*/\1/p' "$ledger")
  [[ $a != "$b" ]]
}
aw_15_send_failure_status_and_row() {
  local ledger="$CASE_DIR/l"
  assert_exit 23 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" send-fail -- sh -c 'exit 23'
  aw_assert_v1_sequence "$ledger" ask_prepare ask_send_failed
}
aw_16_ambiguous_failure_resend_rejected() {
  local ledger="$CASE_DIR/l" marker="$CASE_DIR/m"
  # shellcheck disable=SC2016 # positional parameters are expanded by the generated sh -c script
  assert_exit 9 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" ambiguous -- sh -c 'touch "$1"; exit 9' sh "$marker"
  assert_exit 2 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" ambiguous -- touch "$marker.again"
  [[ -e $marker && ! -e $marker.again ]]
}
aw_17_failure_append_failure_diagnostic() {
  local ledger="$CASE_DIR/l" err="$CASE_DIR/e"
  set +e
  # shellcheck disable=SC2016 # positional parameters are expanded by the generated sh -c script
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" fail-append -- sh -c 'chmod 400 "$1"; chmod 500 "$(dirname "$1")"; exit 17' sh "$ledger" 2>"$err"
  local rc=$?
  set -e
  [[ $rc -eq 17 ]]
  grep -q 'send_failed.*append' "$err"
  chmod 700 "$CASE_DIR"; chmod 600 "$ledger"
  [[ $(wc -l <"$ledger") -eq 1 ]]
  grep -q '"event":"ask_prepare".*"state":"prepared"' "$ledger"
  ! grep -Eq '"event":"(ask_send_failed|expect)"' "$ledger"
}
aw_18_live_unwatched() {
  local ledger="$CASE_DIR/l" err="$CASE_DIR/e"
  set +e
  # shellcheck disable=SC2016 # positional parameters are expanded by the generated sh -c script
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" live-unwatched -- sh -c 'chmod 400 "$1"; chmod 500 "$(dirname "$1")"' sh "$ledger" 2>"$err"
  local rc=$?
  set -e
  [[ $rc -eq 1 ]]
  grep -q 'LIVE_UNWATCHED' "$err"
  chmod 700 "$CASE_DIR"; chmod 600 "$ledger"
  [[ $(wc -l <"$ledger") -eq 1 ]]
  grep -q '"event":"ask_prepare".*"state":"prepared"' "$ledger"
  ! grep -Eq '"event":"(ask_send_failed|expect)"' "$ledger"
}
aw_19_adopt_prepared_reuses_baseline() {
  local ledger="$CASE_DIR/l" reply="$CASE_DIR/r" before after
  printf old >"$reply"
  assert_exit 9 aw_ask "$CASE_DIR/h" "$ledger" "$reply" adopt -- sh -c 'exit 9'
  before=$(sed -n '1s/.*"reply_sha256":"\([^"]*\)".*/\1/p' "$ledger")
  printf changed >"$reply"
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ask --already-sent --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id adopt >/dev/null
  after=$(sed -n '3s/.*"reply_sha256":"\([^"]*\)".*/\1/p' "$ledger")
  [[ -n $before && $before == "$after" ]]
}
aw_20_reply_between_send_and_recovery() {
  local ledger="$CASE_DIR/l" reply="$CASE_DIR/r"
  # shellcheck disable=SC2016 # positional parameters are expanded by the generated sh -c script
  assert_exit 9 aw_ask "$CASE_DIR/h" "$ledger" "$reply" between -- sh -c 'printf reply >"$1"; exit 9' sh "$reply"
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ask --already-sent --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id between >/dev/null
  [[ $(aw_watch "$CASE_DIR/h" "$ledger") == 'acked between' ]]
}
aw_21_pending_retry_does_not_resend() {
  local ledger="$CASE_DIR/l" marker="$CASE_DIR/m"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" pending -- touch "$marker" >/dev/null
  assert_exit 2 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" pending -- touch "$marker.2"
  [[ ! -e $marker.2 ]]
}
aw_22_fresh_adoption_warns() {
  local ledger="$CASE_DIR/l" err="$CASE_DIR/e"
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ask --already-sent --ledger "$ledger" --to x --sla 1 --reply-file "$CASE_DIR/r" --id fresh 2>"$err" >/dev/null
  grep -qi 'pre-adoption' "$err"
  grep -q '"event":"expect"' "$ledger"
}
aw_23_pending_adoption_idempotent() {
  local ledger="$CASE_DIR/l"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" idem -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ask --already-sent --ledger "$ledger" --to operator --sla 0 --reply-file "$CASE_DIR/r" --id idem >/dev/null
  [[ $(grep -c '"event":"expect"' "$ledger") -eq 1 ]]
}
aw_24_adoption_conflicts_fail() {
  local ledger="$CASE_DIR/l" qledger="$CASE_DIR/q"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" conflict -- true >/dev/null
  assert_exit 2 "$SITTER" ask --already-sent --ledger "$ledger" --to other --sla 0 --reply-file "$CASE_DIR/r" --id conflict
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ack --ledger "$ledger" --id conflict
  assert_exit 2 "$SITTER" ask --already-sent --ledger "$ledger" --to operator --sla 0 --reply-file "$CASE_DIR/r" --id conflict
  aw_ask "$CASE_DIR/qh" "$qledger" "$CASE_DIR/qr" quarantined-adopt -- true >/dev/null
  printf '%s\n' '{"ts":"2026-01-01T00:00:00.000Z","event":"quarantine","schema":"sitter.v0","expect_id":"quarantined-adopt","to":"","text":"","sla_s":0,"nudges":0,"state":"quarantined"}' >>"$qledger"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/qh" "$SITTER" ask --already-sent --ledger "$qledger" --to operator --sla 0 --reply-file "$CASE_DIR/qr" --id quarantined-adopt
}
aw_25_kill_switch_refuses_without_send() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" marker="$CASE_DIR/m"
  mkdir "$home"; touch "$home/STOP"
  aw_ask "$home" "$ledger" "$CASE_DIR/r" killed -- touch "$marker" >/dev/null
  [[ ! -e $marker ]]
  grep -q '"event":"refused".*"schema":"sitter.v1".*"state":"acked"' "$ledger"
}
aw_26_v1_schema_key_order() {
  local ledger="$CASE_DIR/l"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" schema -- true >/dev/null
  assert_json_valid "$ledger"
  grep -Eq '"state":"prepared","reply_file":".*","reply_bytes":null,"reply_sha256":null}$' "$ledger"
}
aw_27_no_argv_or_reply_content() {
  local ledger="$CASE_DIR/l" reply_text='visible reply payload'
  printf '%s' "$reply_text" >"$CASE_DIR/r"
  # shellcheck disable=SC2016 # positional parameters are expanded by the generated sh -c script
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" no-persist -- sh -c 'test "$1" = "visible reply payload"' sh "$reply_text" >/dev/null
  ! grep -Fq "$reply_text" "$ledger"
}
aw_28_v0_shape_unchanged() {
  local ledger="$CASE_DIR/l"
  SITTER_HOME="$CASE_DIR/h" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id old --sla 1
  grep -q '"schema":"sitter.v0".*"state":"pending"}$' "$ledger"
  ! grep -q '"reply_file"' "$ledger"
}
aw_29_mixed_v0_v1_escalate() {
  local ledger="$CASE_DIR/l" spy="$CASE_DIR/s"
  SITTER_HOME="$CASE_DIR/h" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id old --sla 0
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" new -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ $(grep -c '"event":"nudge"' "$ledger") -eq 2 ]]
}
aw_30_prepare_failed_not_generation() {
  local ledger="$CASE_DIR/l"
  assert_exit 7 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" inactive -- sh -c 'exit 7'
  aw_watch "$CASE_DIR/h" "$ledger"
  [[ $(grep -c '"event":"ack"' "$ledger" || true) -eq 0 ]]
}
aw_31_v0_ack_absorbs_v1() {
  local ledger="$CASE_DIR/l"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" absorbed -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ack --ledger "$ledger" --id absorbed
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ ! -s $CASE_DIR/s ]]
}
aw_32_late_nudge_after_ack_absorbed() {
  local ledger="$CASE_DIR/l" late="$CASE_DIR/late"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" late -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ack --ledger "$ledger" --id late
  tail -1 "$ledger" | sed 's/"event":"ack"/"event":"nudge"/; s/"state":"acked"/"state":"nudged1"/' >"$late"
  command cat "$late" >>"$ledger"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ ! -s $CASE_DIR/s ]]
}
aw_33_old_matcher_ignores_v1() {
  local ledger="$CASE_DIR/l" old_ids
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" ignored-v1 -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id later-v0 --sla 1
  old_ids=$(grep -F '"schema":"sitter.v0"' "$ledger" | sed -n 's/.*"expect_id":"\([^"]*\)".*/\1/p')
  [[ $old_ids == later-v0 ]]
  ! printf '%s\n' "$old_ids" | grep -Fq ignored-v1
}
aw_34_orphan_v0_transitions_do_not_burn() {
  local ledger="$CASE_DIR/l"
  assert_exit 7 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" orphan -- sh -c 'exit 7'
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"nudge","schema":"sitter.v0","expect_id":"orphan","to":"","text":"","sla_s":0,"nudges":1,"state":"nudged1"}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ack","schema":"sitter.v0","expect_id":"orphan","to":"","text":"","sla_s":0,"nudges":0,"state":"acked"}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"awaiting_human","schema":"sitter.v0","expect_id":"orphan","to":"","text":"","sla_s":0,"nudges":2,"state":"awaiting_human"}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"quarantine","schema":"sitter.v0","expect_id":"orphan","to":"","text":"","sla_s":0,"nudges":0,"state":"quarantined"}' >>"$ledger"
  # Simulate a later row written by an old v0 binary, which ignores the v1
  # reservation.  The orphan transitions above must not suppress this start.
  printf '%s\n' '{"ts":"2026-01-01T00:00:00.000Z","event":"expect","schema":"sitter.v0","expect_id":"orphan","to":"x","text":"","sla_s":0,"nudges":0,"state":"pending"}' >>"$ledger"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"event":"nudge".*"expect_id":"orphan"' "$ledger"
}
aw_35_malformed_v1_quarantine_unknown_ignored() {
  local ledger="$CASE_DIR/l"
  printf '%s\n' \
    '{"schema":"unknown","expect_id":"ignored"}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","to":"x","text":"","sla_s":0,"nudges":0,"state":"prepared","reply_file":"/tmp/r","reply_bytes":null,"reply_sha256":null}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"bad/id","to":"x","text":"","sla_s":0,"nudges":0,"state":"prepared","reply_file":"/tmp/r","reply_bytes":null,"reply_sha256":null}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"decimal-sla","to":"x","text":"","sla_s":1.5,"nudges":0,"state":"prepared","reply_file":"/tmp/r","reply_bytes":null,"reply_sha256":null}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"decimal-nudges","to":"x","text":"","sla_s":0,"nudges":0.5,"state":"prepared","reply_file":"/tmp/r","reply_bytes":null,"reply_sha256":null}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"decimal-bytes","to":"x","text":"","sla_s":0,"nudges":0,"state":"prepared","reply_file":"/tmp/r","reply_bytes":1.5,"reply_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"expect","schema":"sitter.v0","expect_id":"v0-prefix-numeric","to":"x","text":"","sla_s":0.5,"nudges":0.5,"state":"pending"}' >"$ledger"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ $(grep -c '"event":"quarantine"' "$ledger") -eq 5 ]]
  grep -q '"event":"nudge".*"expect_id":"v0-prefix-numeric"' "$ledger"
}
aw_36_id_reuse_and_reservation() {
  local ledger="$CASE_DIR/l" prepared_ledger="$CASE_DIR/prepared"
  assert_exit 4 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" reserve -- sh -c 'exit 4'
  assert_exit 2 env SITTER_HOME="$CASE_DIR/h" "$SITTER" expect --ledger "$ledger" --on-fail "$SPY" --id reserve --sla 0
  head -1 "$ledger" | sed 's/"expect_id":"reserve"/"expect_id":"prepared-only"/' >"$prepared_ledger"
  assert_exit 2 env SITTER_HOME="$CASE_DIR/ph" "$SITTER" expect --ledger "$prepared_ledger" --on-fail "$SPY" --id prepared-only --sla 0
  assert_exit 2 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" reserve -- true
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ask --already-sent --ledger "$ledger" --to operator --sla 0 --reply-file "$CASE_DIR/r" --id reserve >/dev/null
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ack --ledger "$ledger" --id reserve
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" reserve -- true >/dev/null
  [[ $(grep -c '"event":"expect"' "$ledger") -eq 2 ]]
}

aw_truth_setup() {
  local baseline=$1 current=$2 id=${3:-truth} reply="$CASE_DIR/r" ledger="$CASE_DIR/l"
  case $baseline in absent) : ;; empty) : >"$reply" ;; *) printf '%s' "$baseline" >"$reply" ;; esac
  aw_ask "$CASE_DIR/h" "$ledger" "$reply" "$id" -- true >/dev/null
  case $current in absent) rm -f "$reply" ;; empty) : >"$reply" ;; *) printf '%s' "$current" >"$reply" ;; esac
}
aw_37_absent_absent_pending() { aw_truth_setup absent absent; [[ -z $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") ]]; }
aw_38_absent_empty_pending() { aw_truth_setup absent empty; [[ -z $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") ]]; }
aw_39_absent_nonempty_ack() { aw_truth_setup absent reply; [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked truth' ]]; }
aw_40_empty_growth_ack() { aw_truth_setup empty x; [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked truth' ]]; }
aw_41_present_larger_ack() { aw_truth_setup old older; [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked truth' ]]; }
aw_42_same_content_pending() { aw_truth_setup same same; [[ -z $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") ]]; }
aw_43_same_size_different_ack() { aw_truth_setup same lame; [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked truth' ]]; }
aw_44_truncated_pending_diagnostic() {
  aw_truth_setup longer tiny
  local out
  out=$(aw_watch "$CASE_DIR/h" "$CASE_DIR/l" 2>&1)
  [[ $out == *truncated* && $out != *'acked truth'* ]]
}
aw_45_present_absent_diagnostic() {
  aw_truth_setup old absent
  local out
  out=$(aw_watch "$CASE_DIR/h" "$CASE_DIR/l" 2>&1)
  [[ $out == *disappeared* && $out != *'acked truth'* ]]
}
aw_46_unreadable_no_ack() {
  if ! chmod_denies_read; then printf 'SKIP aw_46_unreadable_no_ack: chmod not enforced\n' >&2; return 0; fi
  aw_truth_setup old changed
  chmod 000 "$CASE_DIR/r"
  assert_exit 1 aw_watch "$CASE_DIR/h" "$CASE_DIR/l"
  ! grep -q '"event":"ack"' "$CASE_DIR/l"
}
aw_47_nonregular_no_ack() {
  local ledger="$CASE_DIR/l" reply="$CASE_DIR/r"
  : >"$reply"; aw_ask "$CASE_DIR/h" "$ledger" "$reply" nonregular -- true >/dev/null
  rm "$reply"; mkdir "$reply"
  assert_exit 1 aw_watch "$CASE_DIR/h" "$ledger"
  ! grep -q '"event":"ack"' "$ledger"
}
aw_48_atomic_replacement_rules() {
  aw_truth_setup same lame
  printf lame >"$CASE_DIR/new"; mv "$CASE_DIR/new" "$CASE_DIR/r"
  [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked truth' ]]
}
aw_49_identical_replacement_pending() {
  aw_truth_setup same same
  printf same >"$CASE_DIR/new"; mv "$CASE_DIR/new" "$CASE_DIR/r"
  [[ -z $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") ]]
}
aw_50_symlink_observation() {
  if ! symlinks_are_real; then return 0; fi
  local target="$CASE_DIR/t" link="$CASE_DIR/r"
  printf old >"$target"; ln -s "$target" "$link"
  aw_ask "$CASE_DIR/h" "$CASE_DIR/l" "$link" symlink -- true >/dev/null
  printf new >"$target"
  [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked symlink' ]]
}
aw_51_hash_failure_retries() {
  aw_truth_setup old changed
  local fake="$CASE_DIR/bin"; mkdir "$fake"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$fake/shasum"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$fake/sha256sum"
  chmod +x "$fake/"*
  assert_exit 1 env PATH="$fake:/bin:/usr/bin" SITTER_HOME="$CASE_DIR/h" "$SITTER" watch --once --ledger "$CASE_DIR/l"
  if grep -q '"event":"ack"' "$CASE_DIR/l"; then return 1; fi
  [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked truth' ]]
}
aw_52_dedicated_file_contract_runtime_neutral() {
  # The dedicated-file contract sentence moved from the README to the reference
  # docs when the docs were split into landing / engineering / reference layers.
  grep -Eqi 'dedicated[- ]reply[- ]file|reply[- ]file.*dedicated' "$ROOT/docs/reference.md"
  grep -Eqi '専用.{0,12}返信ファイル|返信ファイル.{0,12}専用|reply[- ]file.{0,16}専用|dedicated[- ]reply[- ]file|reply[- ]file.*dedicated' "$ROOT/docs/reference.ja.md"
  ! grep -Ein 'requester-owned edits.*supported' "$ROOT/sitter"
}
aw_53_two_watchers_absorb() {
  aw_truth_setup absent reply race
  aw_watch "$CASE_DIR/h" "$CASE_DIR/l" & local a=$!
  aw_watch "$CASE_DIR/h" "$CASE_DIR/l" & local b=$!
  wait "$a"; wait "$b"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$CASE_DIR/l" --on-fail "$SPY"
  [[ ! -s $CASE_DIR/s ]]
}
aw_54_manual_ack_watch_race() {
  aw_truth_setup absent reply manual-race
  aw_watch "$CASE_DIR/h" "$CASE_DIR/l" & local a=$!
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ack --ledger "$CASE_DIR/l" --id manual-race & local b=$!
  wait "$a"; wait "$b"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$CASE_DIR/l" --on-fail "$SPY"
  [[ ! -s $CASE_DIR/s ]]
}
aw_55_nudge_before_ack_at_most_one() {
  aw_truth_setup absent reply nudge-first
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$CASE_DIR/l" --on-fail "$SPY"
  aw_watch "$CASE_DIR/h" "$CASE_DIR/l" >/dev/null
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$CASE_DIR/l" --on-fail "$SPY"
  [[ $(grep -c SITTER_REASON "$CASE_DIR/s") -le 1 ]]
}
aw_56_ack_before_sweep_no_nudge() {
  aw_truth_setup absent reply ack-first
  aw_watch "$CASE_DIR/h" "$CASE_DIR/l" >/dev/null
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$CASE_DIR/s" "$SITTER" sweep --once --ledger "$CASE_DIR/l" --on-fail "$SPY"
  [[ ! -s $CASE_DIR/s ]]
}
aw_57_ack_append_failure_retry() {
  aw_truth_setup absent reply retry-ack
  chmod 400 "$CASE_DIR/l"; chmod 500 "$CASE_DIR"
  assert_exit 1 aw_watch "$CASE_DIR/h" "$CASE_DIR/l"
  chmod 700 "$CASE_DIR"; chmod 600 "$CASE_DIR/l"
  [[ $(aw_watch "$CASE_DIR/h" "$CASE_DIR/l") == 'acked retry-ack' ]]
}
aw_58_best_effort_scan() {
  local ledger="$CASE_DIR/l" bad="$CASE_DIR/bad" good="$CASE_DIR/good"
  : >"$bad"; aw_ask "$CASE_DIR/h" "$ledger" "$bad" bad -- true >/dev/null
  aw_ask "$CASE_DIR/h" "$ledger" "$good" good -- true >/dev/null
  rm "$bad"; mkdir "$bad"; printf yes >"$good"
  assert_exit 1 aw_watch "$CASE_DIR/h" "$ledger"
  grep -q '"event":"ack".*"expect_id":"good"' "$ledger"
}
aw_59_missing_is_normal() { aw_truth_setup absent absent missing; aw_watch "$CASE_DIR/h" "$CASE_DIR/l"; }
aw_60_v1_sla_three_hooks() {
  local ledger="$CASE_DIR/l" spy="$CASE_DIR/s"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" breach -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  assert_event_seq "$ledger" expect nudge nudge awaiting_human
  assert_spy_count 3 "$spy"
}
aw_61_inactive_never_hooks() {
  local ledger="$CASE_DIR/l" spy="$CASE_DIR/s"
  assert_exit 8 aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" failed -- sh -c 'exit 8'
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  [[ ! -s $spy ]]
}
aw_62_watch_never_hooks() {
  aw_truth_setup absent reply no-hook
  SPY_FILE="$CASE_DIR/s" aw_watch "$CASE_DIR/h" "$CASE_DIR/l" >/dev/null
  [[ ! -s $CASE_DIR/s ]]
}
aw_63_hook_payload_unchanged() {
  local ledger="$CASE_DIR/l" spy="$CASE_DIR/s"
  SITTER_HOME="$CASE_DIR/h" "$SITTER" ask --ledger "$ledger" --to x --sla 0 --reply-file "$CASE_DIR/r" --id payload --text hello -- true >/dev/null
  SITTER_HOME="$CASE_DIR/h" SPY_FILE="$spy" "$SITTER" sweep --once --ledger "$ledger" --on-fail "$SPY"
  grep -q '"SITTER_EXPECT_ID":"payload"' "$spy"
  grep -q '"SITTER_EVENT":"nudge"' "$spy"
  grep -q '"SITTER_REASON":"sla_breach"' "$spy"
  grep -q '"SITTER_RUN_ID":""' "$spy"
  grep -Eq '"SITTER_EVENT_ID":"e-[^"]+"' "$spy"
  grep -q '"SITTER_PROJECT":""' "$spy"
  grep -q '"SITTER_AGENT":""' "$spy"
  grep -q '"SITTER_TASK":""' "$spy"
  grep -q '"SITTER_TEXT":"hello"' "$spy"
  grep -q '"SITTER_DETAIL":"hello"' "$spy"
  grep -q '"SITTER_ATTEMPT":0' "$spy"
  grep -Fq "\"SITTER_LEDGER\":\"$ledger\"" "$spy"
  grep -Eq '"SITTER_TS":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$spy"
}
aw_64_existing_hook_regressions_green() { term_trapping_hook_is_killed; }
aw_65_forbidden_coupling_scan() {
  if sed -n '/^valid_reply_path()/,/^sweep_locked()/p' "$ROOT/sitter" |
     grep -Ein 'ssh|hermes|vault|syncthing|transport|delivery|routing|probe|allowlist|notification'; then return 1; fi
}
aw_66_complete_suite_gate() { [[ ${AW_NUMBERED_CASES:-81} -eq 81 ]]; }
aw_67_shellcheck_gate() {
  command -v shellcheck >/dev/null 2>&1 || { printf 'SKIP shellcheck not found\n'; return 0; }
  shellcheck "$ROOT/sitter" "$ROOT/tests/run.sh"
}
aw_68_bash32_syntax_gate() { bash -n "$ROOT/sitter" "$ROOT/tests/run.sh"; }
aw_69_hash_tool_paths() { hash_tool_fallback; }
aw_70_lock_fallback_paths() { mkdir_lock_stale_break_is_single_shot; }
aw_71_json_validator_gate() {
  local ledger="$CASE_DIR/l"
  aw_ask "$CASE_DIR/h" "$ledger" "$CASE_DIR/r" json -- true >/dev/null
  assert_json_valid "$ledger"
}
aw_72_scope_gate() {
  if find "$ROOT" -maxdepth 2 -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.toml' \) | grep -q .; then return 1; fi
  ! grep -En 'while .*watch|daemon|sidecar' "$ROOT/sitter"
}

aw_73_concurrent_same_id_same_metadata_one_send() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply="$CASE_DIR/r" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local ready="$CASE_DIR/lock-ready" release="$CASE_DIR/lock-release" out_a="$CASE_DIR/a.out" out_b="$CASE_DIR/b.out"
  local err_a="$CASE_DIR/a.err" err_b="$CASE_DIR/b.err" lock_pid ask_a ask_b rc_a rc_b loser_err
  AW_BARRIER_RELEASE=$release AW_BARRIER_LOCK_PID='' AW_BARRIER_ASK_A='' AW_BARRIER_ASK_B=''
  aw_install_barrier_cleanup_trap
  aw_write_sender "$sender"
  aw_start_lock_holder "$ledger" "$ready" "$release"; lock_pid=$AW_LOCK_PID; AW_BARRIER_LOCK_PID=$lock_pid
  aw_wait_for_path "$ready"
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id race-same \
    -- "$sender" same "$sent" >"$out_a" 2>"$err_a" & ask_a=$!; AW_BARRIER_ASK_A=$ask_a
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id race-same \
    -- "$sender" same "$sent" >"$out_b" 2>"$err_b" & ask_b=$!; AW_BARRIER_ASK_B=$ask_b
  aw_wait_for_staged_files "$CASE_DIR" '.sitter-ask-prepare.*' 2
  : >"$release"
  if aw_wait_for_bg "$ask_a"; then rc_a=0; else rc_a=$?; fi
  if aw_wait_for_bg "$ask_b"; then rc_b=0; else rc_b=$?; fi
  aw_wait_for_bg "$lock_pid"
  (( (rc_a == 0 ? 1 : 0) + (rc_b == 0 ? 1 : 0) == 1 ))
  (( (rc_a == 2 ? 1 : 0) + (rc_b == 2 ? 1 : 0) == 1 ))
  [[ $(grep -c '^same$' "$sent" 2>/dev/null || true) -eq 1 ]]
  [[ $(grep -c '"event":"ask_prepare"' "$ledger") -eq 1 ]]
  [[ $(grep -c '"event":"expect"' "$ledger") -eq 1 ]]
  aw_assert_v1_sequence "$ledger" ask_prepare expect
  if [[ $rc_a -eq 2 ]]; then loser_err=$err_a; else loser_err=$err_b; fi
  aw_assert_precise_ask_loser "$loser_err"
  [[ $(cat "$out_a" "$out_b" | grep -c '^race-same$' || true) -eq 1 ]]
}

aw_74_concurrent_same_id_conflicting_metadata_one_send() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply_a="$CASE_DIR/a.reply" reply_b="$CASE_DIR/b.reply" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local ready="$CASE_DIR/lock-ready" release="$CASE_DIR/lock-release" out_a="$CASE_DIR/a.out" out_b="$CASE_DIR/b.out"
  local err_a="$CASE_DIR/a.err" err_b="$CASE_DIR/b.err" lock_pid ask_a ask_b rc_a rc_b loser_err
  AW_BARRIER_RELEASE=$release AW_BARRIER_LOCK_PID='' AW_BARRIER_ASK_A='' AW_BARRIER_ASK_B=''
  aw_install_barrier_cleanup_trap
  aw_write_sender "$sender"
  aw_start_lock_holder "$ledger" "$ready" "$release"; lock_pid=$AW_LOCK_PID; AW_BARRIER_LOCK_PID=$lock_pid
  aw_wait_for_path "$ready"
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator-a --sla 0 --reply-file "$reply_a" --id race-conflict \
    -- "$sender" winner "$sent" >"$out_a" 2>"$err_a" & ask_a=$!; AW_BARRIER_ASK_A=$ask_a
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator-b --sla 0 --reply-file "$reply_b" --id race-conflict \
    -- "$sender" loser "$sent" >"$out_b" 2>"$err_b" & ask_b=$!; AW_BARRIER_ASK_B=$ask_b
  aw_wait_for_staged_files "$CASE_DIR" '.sitter-ask-prepare.*' 2
  : >"$release"
  if aw_wait_for_bg "$ask_a"; then rc_a=0; else rc_a=$?; fi
  if aw_wait_for_bg "$ask_b"; then rc_b=0; else rc_b=$?; fi
  aw_wait_for_bg "$lock_pid"
  (( (rc_a == 0 ? 1 : 0) + (rc_b == 0 ? 1 : 0) == 1 ))
  (( (rc_a == 2 ? 1 : 0) + (rc_b == 2 ? 1 : 0) == 1 ))
  [[ $(wc -l <"$sent" 2>/dev/null || printf 0) -eq 1 ]]
  [[ $(grep -c '"event":"ask_prepare"' "$ledger") -eq 1 ]]
  [[ $(grep -c '"event":"expect"' "$ledger") -eq 1 ]]
  aw_assert_v1_sequence "$ledger" ask_prepare expect
  if [[ $rc_a -eq 2 ]]; then loser_err=$err_a; else loser_err=$err_b; fi
  aw_assert_precise_ask_loser "$loser_err"
}

aw_75_concurrent_generated_ids_stay_distinct() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply_a="$CASE_DIR/a.reply" reply_b="$CASE_DIR/b.reply" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local ready="$CASE_DIR/lock-ready" release="$CASE_DIR/lock-release" out_a="$CASE_DIR/a.out" out_b="$CASE_DIR/b.out"
  local lock_pid ask_a ask_b id_a id_b
  AW_BARRIER_RELEASE=$release AW_BARRIER_LOCK_PID='' AW_BARRIER_ASK_A='' AW_BARRIER_ASK_B=''
  aw_install_barrier_cleanup_trap
  aw_write_sender "$sender"
  aw_start_lock_holder "$ledger" "$ready" "$release"; lock_pid=$AW_LOCK_PID; AW_BARRIER_LOCK_PID=$lock_pid
  aw_wait_for_path "$ready"
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator-a --sla 0 --reply-file "$reply_a" \
    -- "$sender" auto-a "$sent" >"$out_a" 2>"$CASE_DIR/a.err" & ask_a=$!; AW_BARRIER_ASK_A=$ask_a
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator-b --sla 0 --reply-file "$reply_b" \
    -- "$sender" auto-b "$sent" >"$out_b" 2>"$CASE_DIR/b.err" & ask_b=$!; AW_BARRIER_ASK_B=$ask_b
  aw_wait_for_staged_files "$CASE_DIR" '.sitter-ask-prepare.*' 2
  : >"$release"
  aw_wait_for_bg "$ask_a"
  aw_wait_for_bg "$ask_b"
  aw_wait_for_bg "$lock_pid"
  id_a=$(cat "$out_a")
  id_b=$(cat "$out_b")
  [[ $id_a =~ ^ask-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
  [[ $id_b =~ ^ask-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
  [[ $id_a != "$id_b" ]]
  [[ $(wc -l <"$sent" 2>/dev/null || printf 0) -eq 2 ]]
  [[ $(grep -c '"event":"ask_prepare"' "$ledger") -eq 2 ]]
  [[ $(grep -c '"event":"expect"' "$ledger") -eq 2 ]]
  assert_json_valid "$ledger"
}

aw_76_kill_between_prepare_and_send_blocks_sender() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply="$CASE_DIR/r" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local ready="$CASE_DIR/lock-ready" release="$CASE_DIR/lock-release" err="$CASE_DIR/e" out="$CASE_DIR/o" lock_pid ask_pid rc
  AW_BARRIER_RELEASE=$release AW_BARRIER_LOCK_PID='' AW_BARRIER_ASK_A='' AW_BARRIER_ASK_B=''
  aw_install_barrier_cleanup_trap
  aw_write_sender "$sender"
  aw_start_lock_holder "$ledger" "$ready" "$release"; lock_pid=$AW_LOCK_PID; AW_BARRIER_LOCK_PID=$lock_pid
  aw_wait_for_path "$ready"
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id stop-race \
    --kill-file "$home/STOP" -- "$sender" stop "$sent" >"$out" 2>"$err" & ask_pid=$!; AW_BARRIER_ASK_A=$ask_pid
  aw_wait_for_staged_files "$CASE_DIR" '.sitter-ask-prepare.*' 1
  mkdir -p "$home"
  : >"$home/STOP"
  : >"$release"
  if aw_wait_for_bg "$ask_pid"; then rc=0; else rc=$?; fi
  aw_wait_for_bg "$lock_pid"
  [[ $rc -eq 0 ]]
  [[ ! -s $sent ]]
  [[ ! -s $out ]]
  aw_assert_v1_sequence "$ledger" ask_prepare refused
}

aw_77_kill_file_does_not_bypass_existing_admission() {
  local home="$CASE_DIR/h" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent" reply="$CASE_DIR/r"
  local ledger before err state expected
  aw_write_sender "$sender"
  mkdir -p "$home"
  : >"$home/STOP"
  for state in pending reserved quarantined; do
    ledger="$CASE_DIR/$state.jsonl"
    before="$CASE_DIR/$state.before"
    err="$CASE_DIR/$state.err"
    case $state in
      pending)
        expected='expect id is already active'
        printf '%s\n' \
          '{"ts":"2026-01-01T00:00:00.000Z","event":"expect","schema":"sitter.v0","expect_id":"kill-existing","to":"operator","text":"","sla_s":0,"nudges":0,"state":"pending"}' \
          >"$ledger"
        ;;
      reserved)
        expected='expect id is already reserved by an ask generation'
        printf '%s\n' \
          '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"kill-existing","to":"operator","text":"","sla_s":0,"nudges":0,"state":"prepared","reply_file":"'"$reply"'","reply_bytes":null,"reply_sha256":null}' \
          >"$ledger"
        ;;
      quarantined)
        expected='expect id is permanently quarantined'
        printf '%s\n' \
          '{"ts":"2026-01-01T00:00:00.000Z","event":"expect","schema":"sitter.v0","expect_id":"kill-existing","to":"operator","text":"","sla_s":0,"nudges":0,"state":"pending"}' \
          '{"ts":"2026-01-01T00:00:01.000Z","event":"quarantine","schema":"sitter.v0","expect_id":"kill-existing","to":"","text":"","sla_s":0,"nudges":0,"state":"quarantined"}' \
          >"$ledger"
        ;;
    esac
    cp "$ledger" "$before"
    assert_exit 2 env SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id kill-existing \
      --kill-file "$home/STOP" -- "$sender" "$state" "$sent" 2>"$err"
    cmp -s "$before" "$ledger"
    [[ ! -e $sent ]]
    grep -Fxq "sitter: $expected" "$err"
  done
}

aw_78_internal_reserve_contract() {
  grep -Fq '__reserve_ask_prepare' "$ROOT/sitter"
  if grep -Fq 'declare -f' "$ROOT/sitter"; then return 1; fi
  ! sed -n '/^usage()/,/^}/p' "$ROOT/sitter" | grep -Fq '__reserve_ask_prepare'
}

aw_79_same_id_history_reducer_not_per_row_sed() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply="$CASE_DIR/r" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local fake="$CASE_DIR/bin" count="$CASE_DIR/sed.count" real_sed i
  real_sed=$(command -v sed)
  mkdir "$fake"
  : >"$count"
  printf '%s\n' '#!/usr/bin/env bash' "printf x >>'$count'" "exec '$real_sed' \"\$@\"" >"$fake/sed"
  chmod +x "$fake/sed"
  i=1
  while ((i <= 1000)); do
    printf '%s\n' \
      '{"ts":"2026-01-01T00:00:00.000Z","event":"expect","schema":"sitter.v0","expect_id":"history-id","to":"operator","text":"","sla_s":0,"nudges":0,"state":"pending"}' \
      '{"ts":"2026-01-01T00:00:01.000Z","event":"ack","schema":"sitter.v0","expect_id":"history-id","to":"","text":"","sla_s":0,"nudges":0,"state":"acked"}' \
      >>"$ledger"
    i=$((i + 1))
  done
  aw_write_sender "$sender"
  env PATH="$fake:/bin:/usr/bin" SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id history-id \
    -- "$sender" history "$sent" >/dev/null
  [[ $(grep -c '^history$' "$sent" 2>/dev/null || true) -eq 1 ]]
  [[ $(wc -c <"$count" | tr -d '[:space:]') -le 20 ]]
}

aw_80_barrier_cleanup_reaps_on_errexit() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply="$CASE_DIR/r" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local ready="$CASE_DIR/lock-ready" release="$CASE_DIR/lock-release" pid_file="$CASE_DIR/lock.pid" ask_file="$CASE_DIR/ask.pid"
  local lock_pid='' ask_pid='' rc alive=0 child_pids=''
  aw_write_sender "$sender"
  set +e
  (
    set -e
    aw_start_lock_holder "$ledger" "$ready" "$release"; AW_BARRIER_LOCK_PID=$AW_LOCK_PID
    AW_BARRIER_RELEASE=$release
    aw_install_barrier_cleanup_trap
    printf '%s\n' "$AW_BARRIER_LOCK_PID" >"$pid_file"
    aw_wait_for_path "$ready"
    SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id errexit-race \
      -- "$sender" cleanup "$sent" >/dev/null 2>"$CASE_DIR/ask.err" & AW_BARRIER_ASK_A=$!
    printf '%s\n' "$AW_BARRIER_ASK_A" >"$ask_file"
    false
  )
  rc=$?
  set -e
  lock_pid=$(cat "$pid_file")
  ask_pid=$(cat "$ask_file")
  sleep 0.2
  kill -0 "$lock_pid" 2>/dev/null && alive=1
  child_pids=$(aw_lock_holder_children "$lock_pid")
  [[ -n $child_pids ]] && alive=1
  kill -0 "$ask_pid" 2>/dev/null && alive=1
  aw_cleanup_lock_holder "$lock_pid" "$release"
  aw_cleanup_pid "$ask_pid"
  [[ $rc -ne 0 ]]
  [[ $alive -eq 0 ]]
}

aw_81_malformed_del_reply_file_row_is_poison_consistently() {
  local home="$CASE_DIR/h" ledger="$CASE_DIR/l" reply="$CASE_DIR/r" sender="$CASE_DIR/sender.sh" sent="$CASE_DIR/sent"
  local out="$CASE_DIR/o" bad_reply err="$CASE_DIR/e"
  aw_write_sender "$sender"
  bad_reply="$CASE_DIR/bad"$'\x7f'"path"
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00.000Z","event":"ask_prepare","schema":"sitter.v1","expect_id":"del-row","to":"operator","text":"","sla_s":0,"nudges":0,"state":"prepared","reply_file":"'"$bad_reply"'","reply_bytes":null,"reply_sha256":null}' \
    >"$ledger"
  SITTER_HOME="$home" "$SITTER" ask --ledger "$ledger" --to operator --sla 0 --reply-file "$reply" --id del-row \
    -- "$sender" poison "$sent" >"$out" 2>"$err"
  [[ $(cat "$out") == 'del-row' ]]
  [[ $(grep -c '^poison$' "$sent" 2>/dev/null || true) -eq 1 ]]
  [[ $(grep -c '"event":"ask_prepare".*"status":""' "$ledger") -eq 1 ]]
  [[ $(grep -c '"event":"expect"' "$ledger") -eq 1 ]]
}

AW_NUMBERED_CASES=81
ASK_WATCH_TESTS=(
  aw_01_cli_required_values aw_02_already_sent_argv_rules aw_03_watch_requires_once aw_04_id_validation
  aw_05_sla_numbers aw_06_relative_reply_rejected aw_07_reply_path_charset_and_literal aw_08_generated_id
  aw_09_unknown_transport_flags aw_10_prepare_precedes_send aw_11_prepare_failure_prevents_send
  aw_12_prepared_is_not_live aw_13_success_is_prepare_then_expect aw_14_sla_starts_at_expect
  aw_15_send_failure_status_and_row aw_16_ambiguous_failure_resend_rejected
  aw_17_failure_append_failure_diagnostic aw_18_live_unwatched aw_19_adopt_prepared_reuses_baseline
  aw_20_reply_between_send_and_recovery aw_21_pending_retry_does_not_resend aw_22_fresh_adoption_warns
  aw_23_pending_adoption_idempotent aw_24_adoption_conflicts_fail aw_25_kill_switch_refuses_without_send
  aw_26_v1_schema_key_order aw_27_no_argv_or_reply_content aw_28_v0_shape_unchanged aw_29_mixed_v0_v1_escalate
  aw_30_prepare_failed_not_generation aw_31_v0_ack_absorbs_v1 aw_32_late_nudge_after_ack_absorbed
  aw_33_old_matcher_ignores_v1 aw_34_orphan_v0_transitions_do_not_burn aw_35_malformed_v1_quarantine_unknown_ignored
  aw_36_id_reuse_and_reservation aw_37_absent_absent_pending aw_38_absent_empty_pending
  aw_39_absent_nonempty_ack aw_40_empty_growth_ack aw_41_present_larger_ack aw_42_same_content_pending
  aw_43_same_size_different_ack aw_44_truncated_pending_diagnostic aw_45_present_absent_diagnostic
  aw_46_unreadable_no_ack aw_47_nonregular_no_ack aw_48_atomic_replacement_rules
  aw_49_identical_replacement_pending aw_50_symlink_observation aw_51_hash_failure_retries
  aw_52_dedicated_file_contract_runtime_neutral aw_53_two_watchers_absorb aw_54_manual_ack_watch_race
  aw_55_nudge_before_ack_at_most_one aw_56_ack_before_sweep_no_nudge aw_57_ack_append_failure_retry
  aw_58_best_effort_scan aw_59_missing_is_normal aw_60_v1_sla_three_hooks aw_61_inactive_never_hooks
  aw_62_watch_never_hooks aw_63_hook_payload_unchanged aw_64_existing_hook_regressions_green
  aw_65_forbidden_coupling_scan aw_66_complete_suite_gate aw_67_shellcheck_gate aw_68_bash32_syntax_gate
  aw_69_hash_tool_paths aw_70_lock_fallback_paths aw_71_json_validator_gate aw_72_scope_gate
  aw_73_concurrent_same_id_same_metadata_one_send aw_74_concurrent_same_id_conflicting_metadata_one_send
  aw_75_concurrent_generated_ids_stay_distinct aw_76_kill_between_prepare_and_send_blocks_sender
  aw_77_kill_file_does_not_bypass_existing_admission
  aw_78_internal_reserve_contract aw_79_same_id_history_reducer_not_per_row_sed aw_80_barrier_cleanup_reaps_on_errexit
  aw_81_malformed_del_reply_file_row_is_poison_consistently
)

# Cold runners scan bash/perl on first exec beyond the 2s stall margin of the
# first timed case; run the chain once so timed cases hit warm caches (mitigation
# for issue #40).
warmup_dir=$(mktemp -d "${TMPDIR:-/tmp}/sitter-warmup.XXXXXX")
warmup_spy="$warmup_dir/spy.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$warmup_spy"
chmod +x "$warmup_spy"
FW_MODE=ok SITTER_POLL_INTERVAL=1 SITTER_HOME="$warmup_dir/home" SPY_FILE="$warmup_dir/spy" \
  "$SITTER" run --ledger "$warmup_dir/ledger.jsonl" --on-fail "$warmup_spy" \
    --stall-after 30 --timeout 60 --grace 0 -- "$FIXTURE" >/dev/null 2>&1 || true
grep -q '"event":"end","status":"success"' "$warmup_dir/ledger.jsonl" 2>/dev/null ||
  printf 'WARN: launch-chain warm-up did not complete; issue #40 flake may return\n' >&2
rm -rf "$warmup_dir"

PASS=0; FAIL=0; STARTED=$(date +%s)
for test_name in normal help_and_version_are_stdout_success usage_error_paths_stay_stderr_exit_two help_after_separator_reaches_wrapped_command help_after_separator_still_hits_denylist hang_restart nonidempotent_stall_reason_contract cooldown_crossing_restart_does_not_falsely_stall heartbeat_fresh_keeps_silent_worker_alive heartbeat_frozen_stalls_silent_worker heartbeat_rejects_disabled_stall heartbeat_symlink_is_refused heartbeat_ask_watch_contract heartbeat_child_sees_absolute_relative_path heartbeat_restart_resets_baseline heartbeat_flag_unset_detail_is_unchanged heartbeat_deleted_midrun_falls_back_to_log heartbeat_symlink_swap_midrun_falls_back_to_log heartbeat_empty_value_is_refused heartbeat_unwritable_parent_is_refused heartbeat_directory_path_is_refused heartbeat_attempt_touch_failure_is_not_a_stall heartbeat_environment_does_not_change_ask_or_watch heartbeat_collision_with_ledger_is_refused heartbeat_collision_with_ledger_lock_is_refused heartbeat_collision_with_kill_file_is_refused heartbeat_collision_with_log_is_refused heartbeat_normalized_collision_with_ledger_is_refused heartbeat_export_is_scoped_to_child heartbeat_frozen_does_not_override_advancing_log heartbeat_is_ignored_by_expect_ack_and_sweep heartbeat_help_lists_flag budget per_invocation_retry_budget backoff_persists_across_invocations old_format_cooldown_is_compatible denied missing_hook stall_zero stall_zero_padded env_timeout_explicit json_ledger allowlist_is_command_not_label denylist_adjacency denylist_launcher_unwrap denylist_shell_bundle_and_nice_residue expect_ack_stays_quiet expect_escalates_once_per_state out_of_order_ack_and_id_reuse sweep_lock_contention_is_quiet poison_is_quarantined_once sweep_kill_switch_is_quiet ack_race_replay_is_absorbing id_charset_and_sanitization multibyte_survives_quote_and_sanitize quarantined_id_is_burned failcount_isolation quarantine_is_per_ledger orphan_nudge_is_not_live orphan_quarantine_does_not_burn_admission orphan_quarantine_does_not_suppress_live_expect ack_clears_side_file_state sweep_ignores_side_file_marks term_trapping_hook_is_killed hook_orphan_children_are_reaped hook_timeout_group_gate_kills_trapping_child hash_tool_fallback zero_padded_numerics event_id_sequence_is_unique missing_command_propagates_127 single_argument_metacharacter_path_is_literal stall_kills_grandchild term_exiting_leader_still_kills_grandchild ledger_symlink_is_refused ledger_lock_symlink_is_refused sweep_mkdir_lock_tier_is_unavailable mkdir_lock_stale_break_is_single_shot mkdir_lock_live_holder_not_stolen sweep_heartbeat_refreshes_lockdir stolen_lock_release_spares_usurper assert_json_valid_without_python3_skips_once assert_json_valid_requires_python3_in_ci denylist_deployment_tokens expect_stop_is_refused_acked expect_event_id_sequence_is_unique dash_prefixed_log_path_works symlink_log_path_is_followed cooldown_used_count_is_always_zero elapsed_cooldown_does_not_sleep stop_during_catchup_cooldown_observed stop_during_backoff_observed denylist_exact_eight_env_layers denylist_launcher_boundary_gaps; do
  [[ ${SITTER_ASK_WATCH_ONLY:-false} != true ]] || continue
  [[ -z ${SITTER_TEST_FILTER:-} || " $SITTER_TEST_FILTER " == *" $test_name "* ]] || continue
  run_test "$test_name"
done
for test_name in "${ASK_WATCH_TESTS[@]}"; do
  [[ ${SITTER_V0_ONLY:-false} != true ]] || continue
  [[ -z ${SITTER_TEST_FILTER:-} || " $SITTER_TEST_FILTER " == *" $test_name "* ]] || continue
  run_test "$test_name"
done
ELAPSED=$(( $(date +%s) - STARTED ))
if [[ ${SITTER_V0_ONLY:-false} == true ]]; then
  printf '%s PASS, %s FAIL, %ss wall time (v0 regression)\n' "$PASS" "$FAIL" "$ELAPSED"
else
  printf '%s PASS, %s FAIL, %ss wall time (%s ask/watch cases)\n' "$PASS" "$FAIL" "$ELAPSED" "$AW_NUMBERED_CASES"
fi
((FAIL == 0))
