#!/usr/bin/env bash
# Opt-in: bash tests/bench-ledger.sh. Not part of make test.
# Three reused ids, one SLA-due: measures history growth at fixed active work.
# Each timing uses a fresh ledger and private home, with a successful no-op hook.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BENCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sitter-bench.XXXXXX")
trap 'rm -rf "$BENCH_DIR"' EXIT

cp "$ROOT/tests/fixtures/sitter.baseline" "$BENCH_DIR/sitter.before"
cp "$ROOT/sitter" "$BENCH_DIR/sitter.after"
chmod 644 "$BENCH_DIR/sitter.before" "$BENCH_DIR/sitter.after"
printf '# seconds; 3 reused ids, 1 SLA-due; mixed v0/v1, poison and run records\n'
printf 'lines\tversion\tsweep_seconds\twatch_seconds\n'
for size in 1000 10000 50000; do
  bash "$ROOT/tests/fixtures/gen-ledger.sh" "$size" "$BENCH_DIR/source.jsonl"
  for version in before after; do
    timings=()
    for verb in sweep watch; do
      case_dir="$BENCH_DIR/$size-$version-$verb"
      mkdir -p "$case_dir"
      cp "$BENCH_DIR/source.jsonl" "$case_dir/ledger.jsonl"
      args=("$verb" --once --ledger "$case_dir/ledger.jsonl" --kill-file "$case_dir/STOP")
      [[ $verb != sweep ]] || args+=(--on-fail true)
      printf '# running %s %s %s\n' "$size" "$version" "$verb" >&2
      TIMEFORMAT='%3R'
      if { time SITTER_SWEEP_LOCKED=true SITTER_HOME="$case_dir/home" bash "$BENCH_DIR/sitter.$version" "${args[@]}" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"; } 2>"$case_dir/time"; then
        :
      else
        cat "$case_dir/stderr" >&2
        exit 1
      fi
      timings+=("$(cat "$case_dir/time")")
    done
    printf '%s\t%s\t%s\t%s\n' "$size" "$version" "${timings[0]}" "${timings[1]}"
  done
done
