#!/usr/bin/env bash
# Compare baseline vs optimized compiler with multiple JVM runs (interleaved).
# Usage: compare.sh [RUNS] [WARMUP] [ITERS]
set -e
RUNS=${1:-5}
WARMUP=${2:-3}
ITERS=${3:-10}

BASE=/home/stefan.zeiger/baseline
NEW=/home/stefan.zeiger/scala/build/pack

BASE_LOG=/tmp/bench-base.tsv
NEW_LOG=/tmp/bench-new.tsv
: > "$BASE_LOG"
: > "$NEW_LOG"

for ((r=1; r<=RUNS; r++)); do
  echo "=== JVM run $r/$RUNS ==="
  echo "-- baseline --"
  bash /home/stefan.zeiger/scala/compiler-benchmark/run-bench.sh "$BASE" "$WARMUP" "$ITERS" "cmp-base-$r" 2>/tmp/bench.err | tail -1 | tee -a "$BASE_LOG"
  tail -1 /tmp/bench.err
  echo "-- optimized --"
  bash /home/stefan.zeiger/scala/compiler-benchmark/run-bench.sh "$NEW"  "$WARMUP" "$ITERS" "cmp-new-$r"  2>/tmp/bench.err | tail -1 | tee -a "$NEW_LOG"
  tail -1 /tmp/bench.err
done

echo "=== Summary (median of measured iterations, per JVM run; all ms) ==="
echo "baseline medians:   $(tr '\n' ' ' < "$BASE_LOG")"
echo "optimized medians:  $(tr '\n' ' ' < "$NEW_LOG")"

python3 - "$BASE_LOG" "$NEW_LOG" <<'PY'
import sys, statistics
def read(path):
    return [int(x.strip()) for x in open(path) if x.strip()]
b = read(sys.argv[1]); n = read(sys.argv[2])
def stat(label, xs):
    xs_sorted = sorted(xs)
    print(f"{label}: n={len(xs)} min={min(xs)} median={statistics.median(xs)} mean={statistics.mean(xs):.1f} max={max(xs)} stdev={statistics.pstdev(xs):.1f}")
stat("baseline  ", b)
stat("optimized ", n)
if b and n:
    mb = statistics.median(b); mn = statistics.median(n)
    print(f"delta median: {mn - mb} ms ({(mn/mb - 1)*100:+.2f}%)")
PY
