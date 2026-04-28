#!/usr/bin/env bash
# Build a list of commits and stash each build/pack under
# $BENCH_BUILDS_DIR/<short-sha>/.
#
# Usage: build-commits.sh [--list FILE | <sha> [<sha> ...]]
#
# Notes on git checkouts:
#   compiler-benchmark/ and sandbox/ live outside the tracked tree of the
#   commits we walk through (compiler-benchmark/ is untracked at HEAD or
#   sits in a later commit; sandbox/ is gitignored), so our benchmarking
#   scripts and outputs survive `git checkout` across the commit list.
#   The build is incremental against starr, and `sbt dist/mkPack` produces
#   build/pack with the full stage-1 distribution (jars + launcher).
#
# We do a `rm -rf build` between commits to defeat any cross-commit
# stale-class confusion.  Builds take ~2-3 min each, so plan for ~50 min
# for 17 commits.
set -euo pipefail

REPO=${REPO:-/home/stefan.zeiger/scala}
DEST=${BENCH_BUILDS_DIR:-/home/stefan.zeiger/bench-builds}
mkdir -p "$DEST"

if [[ "${1:-}" == "--list" ]]; then
  shift
  mapfile -t COMMITS < "$1"
elif [[ $# -gt 0 ]]; then
  COMMITS=( "$@" )
else
  echo "usage: $0 [--list FILE | <sha> ...]" >&2
  exit 2
fi

cd "$REPO"

# Capture the original ref to return to.  Prefer the symbolic ref (branch)
# if there is one, otherwise fall back to the SHA.
ORIG_REF=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
echo "[build] original ref: $ORIG_REF"
echo "[build] ${#COMMITS[@]} commits to build"
echo "[build] dest: $DEST"

START=$(date +%s)
trap 'cd "$REPO"; git checkout -q "$ORIG_REF" 2>/dev/null || true' EXIT

for sha in "${COMMITS[@]}"; do
  short=${sha:0:10}
  out="$DEST/$short"
  if [[ -f "$out/lib/scala-compiler.jar" && -f "$out/lib/scala-library.jar" ]]; then
    echo "[build] $short: already built ($(stat -c %y "$out/lib/scala-compiler.jar" | cut -d. -f1))"
    continue
  fi
  printf '\n========== building %s ==========\n' "$sha"
  git checkout -q "$sha"
  rm -rf build
  log=/tmp/build-$short.log
  if ! bash sbt-batch.sh -warn 'dist/mkPack' >"$log" 2>&1; then
    echo "[build] FAIL: $sha — see $log"
    tail -30 "$log"
    exit 1
  fi
  if [[ ! -f build/pack/lib/scala-compiler.jar ]]; then
    echo "[build] FAIL: $sha — build/pack/lib/scala-compiler.jar missing"
    tail -30 "$log"
    exit 1
  fi
  rm -rf "$out"
  cp -r build/pack "$out"
  echo "[build] $short -> $out: $(du -sh "$out" | awk '{print $1}')"
  echo "[build] elapsed so far: $(( ($(date +%s) - START) / 60 )) min"
done

cd "$REPO"
git checkout -q "$ORIG_REF"
echo
echo "[build] done in $(( ($(date +%s) - START) / 60 )) min"
echo "[build] returned to $ORIG_REF"
ls "$DEST"
