#!/usr/bin/env bash
# noise-measure.sh - repeatedly benchmark the *same* compiler to measure
# run-to-run noise.  Writes per-run medians to a tsv and prints stats.
#
# Usage:
#   noise-measure.sh RUNS WARMUP ITERS LABEL [SLEEP_SEC] [DIST_DIR]
#   RUNS        number of JVM runs (default 8)
#   WARMUP      warmup iters per JVM (default 2)
#   ITERS       measured iters per JVM (default 6)
#   LABEL       label (default "noise")
#   SLEEP_SEC   sleep between runs, seconds (default 0)
#   DIST_DIR    path to Scala dist (default build/pack)
#
# Env:
#   BENCH_USE_CGROUP=1   run each JVM via bench-env.sh run (strips taskset)
#   DROP_CACHES=0/1      for cgroup mode, whether to drop page caches each run
set -e

RUNS=${1:-8}
WARMUP=${2:-2}
ITERS=${3:-6}
LABEL=${4:-noise}
SLEEP_SEC=${5:-0}
DIST=${6:-/home/stefan.zeiger/scala/build/pack}
BENCH_USE_CGROUP=${BENCH_USE_CGROUP:-0}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# noise-results is benchmark output: write into sandbox/ (gitignored, ephemeral)
# rather than compiler-benchmark/ (the script lives there).
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
RESULTS_DIR="${BENCH_RESULTS_DIR:-$REPO_ROOT/sandbox/bench/noise-results}"
mkdir -p "$RESULTS_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG="${RESULTS_DIR}/${LABEL}-${STAMP}.tsv"
: > "$LOG"

echo "=== noise: $RUNS runs, warmup=$WARMUP, iters=$ITERS, sleep=${SLEEP_SEC}s, cgroup=$BENCH_USE_CGROUP ==="
echo "log: $LOG"

for ((r=1; r<=RUNS; r++)); do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  label_r="${LABEL}-${r}"
  if [ "$BENCH_USE_CGROUP" = "1" ]; then
    out=$(BENCH_MODE=cgroup bash "$SCRIPT_DIR/run-bench.sh" "$DIST" "$WARMUP" "$ITERS" "$label_r" 2>/tmp/bench.err | tail -1)
  else
    out=$(BENCH_MODE=taskset bash "$SCRIPT_DIR/run-bench.sh" "$DIST" "$WARMUP" "$ITERS" "$label_r" 2>/tmp/bench.err | tail -1)
  fi
  printf '%s\t%s\n' "$ts" "$out" >> "$LOG"
  printf "run %2d/%d  ts=%s  median=%s\n" "$r" "$RUNS" "$ts" "$out"
  if [ "$SLEEP_SEC" -gt 0 ] && [ "$r" -lt "$RUNS" ]; then
    sleep "$SLEEP_SEC"
  fi
done

python3 - "$LOG" "$LABEL" <<'PY'
import sys, statistics
path, label = sys.argv[1], sys.argv[2]
rows = [line.strip().split('\t') for line in open(path) if line.strip()]
# TSV columns: ts \t per_iter_median \t wall_measured \t wall_warm \t warmup \t iters
def col(i):
    out = []
    for r in rows:
        try: out.append(int(r[i]))
        except Exception: pass
    return out
metrics = [
    ("per_iter_median",   col(1)),
    ("wall_measured_ms",  col(2)),
    ("wall_total_ms",     [a + b for a, b in zip(col(2), col(3))] if col(3) else []),
]
print(f"=== {label} ({len(rows)} runs) ===")
for name, vals in metrics:
    if not vals:
        continue
    n = len(vals)
    mn, mx = min(vals), max(vals)
    md, mean = statistics.median(vals), statistics.mean(vals)
    sd = statistics.pstdev(vals) if n > 1 else 0.0
    cv = sd / mean * 100 if mean else 0.0
    print(f"  --- {name} (n={n}) ---")
    print(f"    values : {vals}")
    print(f"    min={mn}  median={md}  mean={mean:.1f}  max={mx}")
    extra = ""
    if n >= 10:
        s = sorted(vals)
        def q(p): return s[min(len(s)-1, max(0, int(round(p*(len(s)-1)))))]
        extra = f"  p50..p90..p99={q(0.5)}..{q(0.9)}..{q(0.99)}"
    print(f"    stdev={sd:.1f}  cv%={cv:.2f}  spread(max-min)={mx-mn}{extra}")
PY
