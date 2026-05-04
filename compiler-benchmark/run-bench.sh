#!/usr/bin/env bash
# Usage: run-bench.sh [SCALA_DIST_DIR] [WARMUP] [ITERS] [LABEL]
# SCALA_DIST_DIR: Directory containing lib/scala-compiler.jar (default: /home/stefan.zeiger/scala/build/pack)
# WARMUP: number of warmup iterations (default: 3)
# ITERS:  number of measurement iterations (default: 10)
# LABEL:  optional label for output
#
# Env vars:
#   BENCH_MODE=taskset|cgroup|none  CPU isolation (default: taskset)
#   TASKSET=0                       legacy alias for BENCH_MODE=none
#   SRC_LIST                        override list of sources to compile
#   DEP_CP                          extra classpath entries for compile classpath
#   JAVA_BIN                        java binary to use (default: java)
#   BENCH_PERF=1                    wrap the JVM in `perf stat -e <events>`
#                                   and write the CSV alongside stdout output
#                                   to $PERF_LOG (default: $OUTDIR/perf.csv).
#   BENCH_PERF_MODE=whole-jvm|measured-only
#                                   whole-jvm  (default): perf counts from
#                                              JVM start to JVM exit.  Easy
#                                              but warmup/JIT contaminates
#                                              the totals.
#                                   measured-only: perf starts disabled
#                                              (-D -1) and is toggled by
#                                              CompilerBench via two named
#                                              FIFOs (--control fifo:..),
#                                              so the totals cover only the
#                                              measurement iterations.
#   PERF_EVENTS                     events to pass to perf stat (CSV).  The
#                                   default panel covers the dimensions that
#                                   typically matter for compiler workloads:
#                                   instructions, cycles, IPC (derived),
#                                   branch behaviour, and cache pressure.
#   PERF_LOG                        path to write the perf CSV (default
#                                   $OUTDIR/perf.csv)
#   PERF_FIFO_DIR                   only used when BENCH_PERF_MODE=measured-only;
#                                   directory for the perf-control FIFO pair
#                                   (default: $OUTDIR-perfctl)
#   EXTRA_JVM_OPTS                  appended to the java command line before
#                                   `-cp`.  Use for ad-hoc JFR / GC / JIT flags
#                                   (e.g. for profiling runs, see README §6).
#                                   Quote multi-token values via the env, e.g.:
#                                     EXTRA_JVM_OPTS="-XX:+FlightRecorder \
#                                       -XX:StartFlightRecording=filename=/tmp/r.jfr,settings=profile"
set -e
DIST=${1:-/home/stefan.zeiger/scala/build/pack}
WARMUP=${2:-3}
ITERS=${3:-10}
LABEL=${4:-run}
OUTDIR=/home/stefan.zeiger/scala/sandbox/bench/libout-$LABEL
mkdir -p "$OUTDIR"

CP="/home/stefan.zeiger/scala/sandbox/bench/out:$DIST/lib/scala-library.jar:$DIST/lib/scala-reflect.jar:$DIST/lib/scala-compiler.jar:$DIST/lib/jline.jar"

# Compiler classpath used *during* compilation (the compiler's classpath for user code).
# Optional DEP_CP is appended for corpora that need external jars (e.g. scala-asm).
COMPILE_CP="$DIST/lib/scala-library.jar:$DIST/lib/scala-reflect.jar${DEP_CP:+:$DEP_CP}"

cd /home/stefan.zeiger/scala

SRC_LIST=${SRC_LIST:-/home/stefan.zeiger/scala/compiler-benchmark/baseline-lib-srcs.txt}

# CPU isolation mode:
#   BENCH_MODE=taskset   (default): taskset -c 0-3 java ...
#   BENCH_MODE=cgroup    join the bench.slice cpuset (via bench-env.sh run)
#   BENCH_MODE=none      no pinning (good for profiling)
# Legacy: TASKSET=0 is an alias for BENCH_MODE=none.
BENCH_MODE=${BENCH_MODE:-taskset}
if [ "${TASKSET:-1}" = "0" ] && [ "$BENCH_MODE" = "taskset" ]; then
  BENCH_MODE=none
fi

JAVA_BIN=${JAVA_BIN:-java}

# Default perf event panel.  Overridable via PERF_EVENTS.
# Notes:
#  - 7 events; only ~4 PMU counters can be active simultaneously on Ice Lake,
#    so perf will multiplex.  For a 60+ s run that's fine, totals are scaled.
#  - We use task-level counters (default scope of `perf stat -- <cmd>`), so
#    even when BENCH_MODE=cgroup the counts cover the JVM and not the whole
#    cpuset (perf is invoked as a child of run-bench.sh, before the cgroup
#    move via bench-env.sh run).
PERF_EVENTS_DEFAULT="cycles,instructions,branches,branch-misses,cache-misses,cache-references,dTLB-load-misses"
PERF_EVENTS=${PERF_EVENTS:-$PERF_EVENTS_DEFAULT}
PERF_LOG=${PERF_LOG:-$OUTDIR/perf.csv}
PERF_MODE=${BENCH_PERF_MODE:-whole-jvm}
PERF_FIFO_DIR=${PERF_FIFO_DIR:-${OUTDIR}-perfctl}

# Build the inner command (java ... CompilerBench ...) once; perf wraps it
# without changing the cgroup/taskset semantics around it.
JAVA_CMD=( "$JAVA_BIN" -Xms2g -Xmx2g -XX:+UseParallelGC ${EXTRA_JVM_OPTS:-} -cp "$CP"
  benchmark.CompilerBench "$SRC_LIST" "$COMPILE_CP" "$OUTDIR" "$WARMUP" "$ITERS" )

PERF_PREFIX=()
if [ "${BENCH_PERF:-0}" = "1" ]; then
  case "$PERF_MODE" in
    whole-jvm)
      PERF_PREFIX=( perf stat -e "$PERF_EVENTS" -x , -o "$PERF_LOG" -- )
      ;;
    measured-only)
      # Set up control FIFOs.  perf opens ctl for read and ack for write
      # before forking java; the JVM (CompilerBench) opens ctl for write
      # and ack for read once it's up.
      rm -rf "$PERF_FIFO_DIR"
      mkdir -p "$PERF_FIFO_DIR"
      CTL_FIFO="$PERF_FIFO_DIR/ctl"
      ACK_FIFO="$PERF_FIFO_DIR/ack"
      mkfifo "$CTL_FIFO" "$ACK_FIFO"
      export BENCH_CTL_FIFO="$CTL_FIFO" BENCH_ACK_FIFO="$ACK_FIFO"
      # `-D -1` = events disabled at start; CompilerBench enables them
      # around each measurement iteration via the FIFO bridge.
      PERF_PREFIX=( perf stat -e "$PERF_EVENTS" -x , -o "$PERF_LOG"
        -D -1 --control "fifo:$CTL_FIFO,$ACK_FIFO" -- )
      ;;
    *) echo "unknown BENCH_PERF_MODE: $PERF_MODE" >&2; exit 2 ;;
  esac
fi

case "$BENCH_MODE" in
  taskset)
    exec taskset -c 0-3 "${PERF_PREFIX[@]}" "${JAVA_CMD[@]}"
    ;;
  cgroup)
    exec bash "$(dirname "$0")/bench-env.sh" run -- \
      "${PERF_PREFIX[@]}" "${JAVA_CMD[@]}"
    ;;
  none|"")
    exec "${PERF_PREFIX[@]}" "${JAVA_CMD[@]}"
    ;;
  *)
    echo "unknown BENCH_MODE: $BENCH_MODE" >&2; exit 2 ;;
esac
