#!/usr/bin/env bash
# Walk a list of commits, doing head-to-head (commit vs parent) runs of
# the compiler self-benchmark with both wall-time and a panel of perf
# hardware counters.  Designed to answer: "do hardware counters match
# wall-time signal on real optimization commits, and do they have lower
# noise?".
#
# Usage:
#   perf-walk.sh --commits FILE --builds DIR [--runs N] [--warmup W] [--iters I] [--out DIR]
#
# Inputs:
#   --commits FILE    list of commit SHAs in chronological order (parent
#                     first; one per line; can be short SHAs).  Pairs are
#                     formed as (commits[i-1], commits[i]) for i in 1..N.
#   --builds DIR      directory containing one subdir per short-SHA, each
#                     a build/pack tree (see build-commits.sh).
#   --runs N          JVM runs per side per commit (default: 8)
#   --warmup W        warmup iterations per JVM (default: 1)
#   --iters I         measurement iterations per JVM (default: 3)
#   --out DIR         output directory; default
#                     /home/stefan.zeiger/bench-output/perf-walk/<ts>
#
# Outputs (under $OUT):
#   runs.tsv          one row per JVM run with wall + perf
#   meta.env          environment / configuration snapshot
#
# Notes:
#   * BENCH_MODE=cgroup is forced — required for perf events to work
#     when bench.slice is in partition=root mode.
#   * BENCH_PERF=1 wraps each JVM with perf stat.  Counts cover the
#     entire JVM run (warmup+measurement+startup); we treat that as a
#     single point per JVM, since per-iteration perf carving requires
#     deeper integration into the harness.
#   * We do NOT clean cache or restart bench.slice between sides; the
#     workload is identical and we only care about the diff.
#   * Order is interleaved: P C P C ... so any drift across the run
#     averages out symmetrically.

set -euo pipefail

COMMITS=
BUILDS=
RUNS=8
WARMUP=1
ITERS=3
OUT=
NULL_PAIRS=0
PERF_MODE=whole-jvm

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commits)    COMMITS=$2; shift 2 ;;
    --builds)     BUILDS=$2;  shift 2 ;;
    --runs)       RUNS=$2;    shift 2 ;;
    --warmup)     WARMUP=$2;  shift 2 ;;
    --iters)      ITERS=$2;   shift 2 ;;
    --out)        OUT=$2;     shift 2 ;;
    # When set, every commit is paired with ITSELF instead of its parent.
    # Lets us measure the null distribution: ideal output = all deltas
    # near 0, CVs match the experiment's noise floor.
    --null-pairs) NULL_PAIRS=1; shift ;;
    # Perf measurement mode: `whole-jvm` (default) wraps the entire JVM
    # invocation; `measured-only` uses perf --control fifo to scope
    # counters to the measurement iterations.
    --perf-mode)  PERF_MODE=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$COMMITS" && -n "$BUILDS" ]] || { echo "missing --commits or --builds" >&2; exit 2; }
[[ -f "$COMMITS" ]] || { echo "commits file not found: $COMMITS" >&2; exit 2; }
[[ -d "$BUILDS"  ]] || { echo "builds dir not found: $BUILDS"   >&2; exit 2; }

if [[ -z "$OUT" ]]; then
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  OUT=/home/stefan.zeiger/bench-output/perf-walk/$ts
fi
mkdir -p "$OUT"
echo "[walk] output dir: $OUT"

# Snapshot the configuration for the run (so future readers can
# reproduce / interpret).
{
  echo "ts=$(date -u +%FT%TZ)"
  echo "host=$(hostname)"
  echo "kernel=$(uname -r)"
  echo "warmup=$WARMUP"
  echo "iters=$ITERS"
  echo "runs_per_side=$RUNS"
  echo "perf_mode=$PERF_MODE"
  echo "null_pairs=$NULL_PAIRS"
  echo "commits_file=$COMMITS"
  echo "builds_dir=$BUILDS"
  echo "perf_events=$(grep PERF_EVENTS_DEFAULT /home/stefan.zeiger/scala/compiler-benchmark/run-bench.sh | head -1 | cut -d= -f2- | tr -d \")"
  echo "intel_pstate_no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
  echo "intel_pstate_hwp_dyn_boost=$(cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 2>/dev/null)"
  echo "thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
  echo "ht_smt=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null)"
  echo "bench_cpus=$(cat /sys/fs/cgroup/bench.slice/cpuset.cpus 2>/dev/null)"
  echo "bench_partition=$(cat /sys/fs/cgroup/bench.slice/cpuset.cpus.partition 2>/dev/null)"
} > "$OUT/meta.env"
cat "$OUT/meta.env"

# Read commits, strip blanks/comments
mapfile -t SHAS < <(grep -v '^[[:space:]]*\(#\|$\)' "$COMMITS" | awk '{print $1}')
if (( ${#SHAS[@]} < 2 )); then
  echo "need at least 2 commits in $COMMITS" >&2; exit 2
fi
echo "[walk] ${#SHAS[@]} commits, ${#SHAS[@]}-1 pairs"

# Validate all builds exist before starting (fail fast).
for sha in "${SHAS[@]}"; do
  short=${sha:0:10}
  if [[ ! -f "$BUILDS/$short/lib/scala-compiler.jar" ]]; then
    echo "[walk] missing build for $short at $BUILDS/$short" >&2
    exit 3
  fi
done

# TSV header.  fields = setup + wall + 7 events
#   wall_ms          median of measurement iterations (steady state)
#   wall_total_ms    warmup_total + measured_total (perf scope in
#                    whole-jvm mode, modulo JVM startup).
#   wall_measured_ms sum of measurement iterations only (perf scope in
#                    measured-only mode).  Equivalent to wall_total_ms
#                    minus the warmup contribution.
RUNS_TSV=$OUT/runs.tsv
{
  echo -e "iso\tpair_idx\tparent_short\tchild_short\tside\tjvm_run\twall_ms\twall_total_ms\twall_measured_ms\tcycles\tinstructions\tbranches\tbranch_misses\tcache_misses\tcache_refs\tdtlb_load_misses"
} > "$RUNS_TSV"

# Helpers ---------------------------------------------------------------
# Run one bench and print one TSV row to stdout.
# args: pair_idx parent_short child_short side(P|C) jvm_run dist_dir
run_one() {
  local pair=$1 ps=$2 cs=$3 side=$4 jvm=$5 dist=$6
  local label="walk-p${pair}-${side}-j${jvm}"
  local outdir="/home/stefan.zeiger/scala/sandbox/bench/libout-${label}"
  # IMPORTANT: keep perf.csv OUTSIDE outdir.  CompilerBench cleans the
  # outdir between iterations and would unlink perf's open output file,
  # losing all counters when the writes hit the orphan inode.
  local perflog="$OUT/perf-p${pair}-${side}-j${jvm}.csv"
  rm -rf "$outdir"
  mkdir -p "$outdir"

  # Capture stdout (now: median<TAB>measured_total<TAB>warmup_total<TAB>n_warmup<TAB>n_iters)
  # and stderr (the perf wrapper writes the report ON TERMINATION, so
  # we just need to read perf.csv after).
  local stdout
  stdout=$(BENCH_PERF=1 BENCH_MODE=cgroup BENCH_PERF_MODE="$PERF_MODE" \
    PERF_LOG="$perflog" \
    PERF_FIFO_DIR="$OUT/.perfctl-p${pair}-${side}-j${jvm}" \
    bash /home/stefan.zeiger/scala/compiler-benchmark/run-bench.sh "$dist" \
         "$WARMUP" "$ITERS" "$label" 2>/dev/null | tail -1)

  local wall_med wall_meas wall_warm
  wall_med=$( awk -F'\t' '{print $1}' <<< "$stdout")
  wall_meas=$(awk -F'\t' '{print $2}' <<< "$stdout")
  wall_warm=$(awk -F'\t' '{print $3}' <<< "$stdout")
  : "${wall_med:=NaN}"
  : "${wall_meas:=NaN}"
  : "${wall_warm:=NaN}"
  # wall_total approximates the time perf was active (warmup + measured)
  local wall_total
  if [[ "$wall_meas" =~ ^[0-9]+$ && "$wall_warm" =~ ^[0-9]+$ ]]; then
    wall_total=$(( wall_meas + wall_warm ))
  else
    wall_total=NaN
  fi

  # Parse the perf CSV.  Expected layout (one per event):
  #   <count>,<unit>,<event>,<run-ns>,<frac-running>,<extras...>
  # We store counts as integers; a `<not counted>` would be NaN.
  local cyc inst br brm chm chr dtlb
  cyc=$(  awk -F, '$3=="cycles"          {print $1}' "$perflog" | head -1)
  inst=$( awk -F, '$3=="instructions"    {print $1}' "$perflog" | head -1)
  br=$(   awk -F, '$3=="branches"        {print $1}' "$perflog" | head -1)
  brm=$(  awk -F, '$3=="branch-misses"   {print $1}' "$perflog" | head -1)
  chm=$(  awk -F, '$3=="cache-misses"    {print $1}' "$perflog" | head -1)
  chr=$(  awk -F, '$3=="cache-references"{print $1}' "$perflog" | head -1)
  dtlb=$( awk -F, '$3=="dTLB-load-misses"{print $1}' "$perflog" | head -1)

  local iso; iso=$(date -u +%FT%TZ)
  # NB: wall_measured_ms = sum over measured iters only.  This is the
  # natural correlate for perf counters when BENCH_PERF_MODE=measured-only.
  printf '%s\t%d\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iso" "$pair" "$ps" "$cs" "$side" "$jvm" \
    "$wall_med" "$wall_total" "$wall_meas" \
    "${cyc:-NaN}" "${inst:-NaN}" "${br:-NaN}" \
    "${brm:-NaN}" "${chm:-NaN}" "${chr:-NaN}" "${dtlb:-NaN}"

  # Discard the compile output to keep disk usage flat across the
  # ~256 JVM runs of a full walk.  Also discard the per-run FIFO dir
  # in measured-only mode (FIFOs are recreated per run by run-bench.sh).
  rm -rf "$outdir" "$OUT/.perfctl-p${pair}-${side}-j${jvm}"
}
# -----------------------------------------------------------------------

START=$(date +%s)
TOTAL_PAIRS=$(( ${#SHAS[@]} - 1 ))
PAIR_IDX=0

if [[ "$NULL_PAIRS" == "1" ]]; then
  # Pair each commit with itself.  The first commit in the list is
  # included; output uses parent_short=child_short so downstream
  # tooling treats the row as a "no change expected" reference.
  PAIR_RANGE_START=0
  TOTAL_PAIRS=${#SHAS[@]}
else
  PAIR_RANGE_START=1
  TOTAL_PAIRS=$(( ${#SHAS[@]} - 1 ))
fi

for ((i=PAIR_RANGE_START; i<${#SHAS[@]}; i++)); do
  PAIR_IDX=$(( i - PAIR_RANGE_START + 1 ))
  if [[ "$NULL_PAIRS" == "1" ]]; then
    PARENT_SHA=${SHAS[$i]}
    CHILD_SHA=${SHAS[$i]}
  else
    PARENT_SHA=${SHAS[$((i-1))]}
    CHILD_SHA=${SHAS[$i]}
  fi
  PS=${PARENT_SHA:0:10}
  CS=${CHILD_SHA:0:10}

  P_DIST="$BUILDS/$PS"
  C_DIST="$BUILDS/$CS"

  printf '\n========== pair %d/%d : %s -> %s ==========\n' \
    "$PAIR_IDX" "$TOTAL_PAIRS" "$PS" "$CS"

  # Interleave: P C P C ... RUNS times.  For odd iterations on even
  # commits we mirror to balance any first-run JIT effects.
  for ((r=1; r<=RUNS; r++)); do
    if (( r % 2 == 1 )); then
      first_side=P; first_dist=$P_DIST
      second_side=C; second_dist=$C_DIST
    else
      first_side=C; first_dist=$C_DIST
      second_side=P; second_dist=$P_DIST
    fi
    row1=$(run_one "$PAIR_IDX" "$PS" "$CS" "$first_side"  "$r" "$first_dist")
    echo "$row1" | tee -a "$RUNS_TSV"
    row2=$(run_one "$PAIR_IDX" "$PS" "$CS" "$second_side" "$r" "$second_dist")
    echo "$row2" | tee -a "$RUNS_TSV"
  done

  ELAPSED=$(( ($(date +%s) - START) / 60 ))
  echo "[walk] elapsed: ${ELAPSED} min  ($PAIR_IDX/$TOTAL_PAIRS done)"
done

echo
echo "[walk] all done in $(( ($(date +%s) - START) / 60 )) min"
echo "[walk] results: $RUNS_TSV"
