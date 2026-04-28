#!/usr/bin/env bash
# corpus-bench.sh - run our CompilerBench driver against a compiler-benchmark
# corpus instead of the local library sources.  Useful to sanity-check whether
# an optimization is stable across workloads (scalap, better-files, re2s, ...).
#
# Usage:
#   corpus-bench.sh CORPUS [WARMUP] [ITERS] [LABEL] [DIST]
#
# CORPUS    Name under ../compiler-benchmark/corpus/ (e.g., scalap, re2s, vector, better-files)
# WARMUP    default 3
# ITERS     default 10
# LABEL     default CORPUS
# DIST      default /home/stefan.zeiger/scala/build/pack
set -e

CORPUS=${1:?Usage: corpus-bench.sh CORPUS [WARMUP] [ITERS] [LABEL] [DIST]}
WARMUP=${2:-3}
ITERS=${3:-10}
LABEL=${4:-$CORPUS}
DIST=${5:-/home/stefan.zeiger/scala/build/pack}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
CB_ROOT="${CB_ROOT:-/home/stefan.zeiger/compiler-benchmark}"
CORPUS_DIR="$CB_ROOT/corpus/$CORPUS/latest"
CACHE_DIR="${BENCH_CORPUS_CACHE:-$REPO_ROOT/sandbox/bench}"

if [[ ! -d "$CORPUS_DIR" ]]; then
  echo "corpus not found or missing 'latest' symlink: $CORPUS_DIR" >&2
  exit 2
fi

# Build a sources list (handles the symlink in corpora).  Cached output, so
# write it under sandbox/ rather than the (canonical) compiler-benchmark dir.
mkdir -p "$CACHE_DIR"
SRC_LIST="$CACHE_DIR/corpus-${CORPUS}-srcs.txt"
find -L "$CORPUS_DIR" \( -name '*.scala' -o -name '*.java' \) | sort > "$SRC_LIST"
nsrc=$(wc -l < "$SRC_LIST")
if [[ "$nsrc" -eq 0 ]]; then
  echo "empty corpus '$CORPUS' (check that content is checked in or fetched)" >&2
  exit 2
fi
echo "corpus=$CORPUS files=$nsrc dist=$DIST"

# If deps.txt exists, download to ~/.compilerBenchmark/deps/ and extend the
# compile classpath so the corpus can resolve its external imports.
DEPS_FILE="$CORPUS_DIR/deps.txt"
DEPS_DIR="$HOME/.compilerBenchmark/deps"
DEP_CP=""
if [[ -s "$DEPS_FILE" ]]; then
  mkdir -p "$DEPS_DIR"
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    fname=$(basename "${url%%\?*}")
    out="$DEPS_DIR/$fname"
    if [[ ! -s "$out" ]]; then
      echo "downloading dep: $url"
      curl -fsSL "$url" -o "$out"
    fi
    DEP_CP="${DEP_CP:+$DEP_CP:}$out"
  done < "$DEPS_FILE"
fi

if [[ -n "$DEP_CP" ]]; then
  echo "DEP_CP=$DEP_CP"
fi

export SRC_LIST
export DEP_CP
# run-bench.sh honors SRC_LIST and appends DEP_CP to the compile classpath.
exec bash "$SCRIPT_DIR/run-bench.sh" "$DIST" "$WARMUP" "$ITERS" "$LABEL"
