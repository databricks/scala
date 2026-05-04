#!/usr/bin/env bash
# Compare baseline vs optimized compiler with multiple JVM runs (interleaved).
# Usage: compare.sh [RUNS] [WARMUP] [ITERS]
#
# Env vars:
#   BASE  baseline build/pack directory
#         (default: /home/stefan.zeiger/baseline)
#   NEW   optimized build/pack directory
#         (default: /home/stefan.zeiger/scala/build/pack)
#
# Output: three side-by-side comparisons computed from the per-JVM
# tab-separated tail line of CompilerBench:
#   - median (per-iter)              : single-iter median, classic metric
#   - wall_measured_ms               : sum of measured iters in the JVM
#   - wall_total_ms (lowest CV)      : warmup+measured wall, recommended
#                                      for small (<0.5%) deltas (see README §13)
set -e
RUNS=${1:-5}
WARMUP=${2:-3}
ITERS=${3:-10}

BASE=${BASE:-/home/stefan.zeiger/baseline}
NEW=${NEW:-/home/stefan.zeiger/scala/build/pack}

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

echo "=== Summary (per JVM run: median_ms / measured_total_ms / warmup_total_ms) ==="

python3 - "$BASE_LOG" "$NEW_LOG" <<'PY'
import sys, statistics
def read(path):
    rows = []
    for line in open(path):
        cols = line.strip().split('\t')
        if len(cols) >= 3 and cols[0].lstrip('-').isdigit():
            rows.append((int(cols[0]), int(cols[1]), int(cols[2])))
    return rows
b = read(sys.argv[1]); n = read(sys.argv[2])
def col(rows, i): return [r[i] for r in rows]
def stat(label, xs):
    print(f"{label}: n={len(xs)} min={min(xs)} median={statistics.median(xs):.1f} mean={statistics.mean(xs):.1f} max={max(xs)} stdev={statistics.pstdev(xs):.1f}")
def cmp(label, b, n):
    print(f"-- {label} --")
    stat("baseline  ", b)
    stat("optimized ", n)
    if b and n:
        mb = statistics.median(b); mn = statistics.median(n)
        print(f"delta median: {mn - mb:+.1f} ms ({(mn/mb - 1)*100:+.2f}%)")
cmp("median (per-iter)", col(b,0), col(n,0))
cmp("wall_measured_ms",  col(b,1), col(n,1))
cmp("wall_total_ms (warmup+measured; lowest CV)", [r[1]+r[2] for r in b], [r[1]+r[2] for r in n])
PY
