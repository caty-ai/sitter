#!/usr/bin/env bash
# Opt-in: bash tests/bench-ledger.sh [--production-shape [--repeat N] [--lines N]].
# Not part of make test. Production mode compares shared and dedicated ask ledgers.
# Three reused ids, one SLA-due: measures history growth at fixed active work.
# Each timing uses a fresh ledger and private home, with a successful no-op hook.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
usage() {
  printf 'usage: %s [--production-shape [--repeat N] [--lines N]]\n' "$0" >&2
  exit 2
}
production=false
repeat=3
lines=13884
if [[ $# -gt 0 ]]; then
  [[ $1 == --production-shape ]] || usage
  production=true
  shift
  seen_repeat=false
  seen_lines=false
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || usage
    case "$1" in
      --repeat)
        [[ $seen_repeat == false ]] || usage
        repeat=$2
        seen_repeat=true
        ;;
      --lines)
        [[ $seen_lines == false && $2 -ge 6 ]] || usage
        lines=$2
        seen_lines=true
        ;;
      *) usage ;;
    esac
    shift 2
  done
fi
BENCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sitter-bench.XXXXXX")
trap 'rm -rf "$BENCH_DIR"' EXIT

if [[ $production == true ]]; then
  printf 'shape\tlines\tverb'
  for ((run=1; run<=repeat; run++)); do printf '\trun_%s' "$run"; done
  printf '\tmedian_seconds\n'
  for shape in shared dedicated; do
    size=$lines
    [[ $shape != dedicated ]] || size=6
    source="$BENCH_DIR/$shape.jsonl"
    bash "$ROOT/tests/fixtures/gen-ledger.sh" --production-shape "$size" "$source"
    rows=$(wc -l <"$source" | tr -d '[:space:]')
    bytes=$(wc -c <"$source" | tr -d '[:space:]')
    expects=$(grep -c '"expect_id"' "$source" || true)
    printf '# %s: rows=%s bytes=%s expect_id=%s\n' "$shape" "$rows" "$bytes" "$expects"
    if [[ $expects != 6 ]]; then
      printf 'expected six expect-family rows in %s\n' "$shape" >&2
      exit 1
    fi
  done
  for shape in shared dedicated; do
    size=$lines
    [[ $shape != dedicated ]] || size=6
    for verb in sweep watch; do
      timings=()
      for ((run=1; run<=repeat; run++)); do
        case_dir="$BENCH_DIR/$shape-$verb-$run"
        mkdir -p "$case_dir"
        cp "$BENCH_DIR/$shape.jsonl" "$case_dir/ledger.jsonl"
        args=("$verb" --once --ledger "$case_dir/ledger.jsonl" --kill-file "$case_dir/STOP")
        [[ $verb != sweep ]] || args+=(--on-fail true)
        printf '# running %s %s %s\n' "$shape" "$verb" "$run" >&2
        TIMEFORMAT='%3R'
        if { time SITTER_SWEEP_LOCKED=true SITTER_HOME="$case_dir/home" bash "$ROOT/sitter" "${args[@]}" \
            >"$case_dir/stdout" 2>"$case_dir/stderr"; } 2>"$case_dir/time"; then
          timings+=("$(cat "$case_dir/time")")
        else
          cat "$case_dir/stderr" >&2
          exit 1
        fi
      done
      # For even repetition counts, select the lower-middle sorted timing.
      median=$(printf '%s\n' "${timings[@]}" | LC_ALL=C sort -n | sed -n "$(((repeat+1)/2))p")
      printf '%s\t%s\t%s' "$shape" "$size" "$verb"
      printf '\t%s' "${timings[@]}"
      printf '\t%s\n' "$median"
    done
  done
  exit 0
fi

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
