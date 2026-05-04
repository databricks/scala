# Benchmarking the Scala 2.12 compiler

Notes from an optimization round on our internal fork (spring 2026). Captures
the workflow, the environment-specific tweaks, and the Scala-2.12 performance
traps that kept reappearing. Aimed at the next person who needs to measure or
optimize the compiler itself (not the library - for library microbenchmarks
see `test/benchmarks/README.md`).

## 1. Goal and constraints

- Measure end-to-end compiler throughput on a realistic workload.
- Preserve **bytecode identity** against the baseline compiler for unchanged
  input sources.
- Preserve **binary compatibility** (MiMa) for `scala-library` and
  `scala-reflect`.
- Run on EC2 with Zulu JDK 17; keep code Java-17 compatible.

If any of those constraints aren't yours, the rest of this doc still applies
but some of the specific guardrails can be relaxed.

## 2. One-time setup

### JDK

We used Zulu 17.0.18 via sdkman. Any recent OpenJDK 17 distribution works.
Avoid commercial-feature-era JFR incantations; see §6.

### sbt proxy

On machines behind the corporate proxy, `sbt` can't reach Maven Central
directly. Put this in `~/.sbt/repositories`:

```
[repositories]
  local
  maven-central: https://<internal-maven-proxy>/maven-central/
  typesafe-ivy: https://<internal-ivy-proxy>/typesafe-ivy/, [organization]/[module]/[revision]/[type]s/[artifact](-[classifier]).[ext]
```

### CPU pinning (optional but strongly recommended on shared hosts)

`taskset -c 0-3` in front of the benchmark JVM cut per-JVM stdev from
~200ms to 70-120ms on EC2. The `run-bench.sh` driver below has this
plumbed through a `BENCH_MODE=taskset|cgroup|none` env var (`taskset` is
the default; `TASKSET=0` is a legacy alias for `BENCH_MODE=none`).

For multi-hour benchmark campaigns on a shared host, pair `taskset` with
a one-off environment-tuning step via `compiler-benchmark/bench-env.sh` (see
§11). That script offlines the hyper-thread siblings of the bench CPUs,
turns off transparent hugepages, stops chatty systemd units (including
vendor monitoring agents like Falcon and Kolide, which otherwise
consume ~6% CPU continuously on our fleet), pins IRQs off the bench
CPUs, and creates a cgroup-v2 cpuset partition. On our EC2 VM it shaved
~1.4% off the *median* compile time and ~28% off *stdev* for 60-second-
gap spread runs.

## 3. The workload and driver

### Workload

**Compiling the Scala distribution's own sources** (library + reflect +
compiler) is a good workload:

- Large enough to amortize JVM warmup.
- Exercises typer, erasure, backend, the whole pipeline.
- The baseline compiler output is a perfect ground truth for bytecode
  identity checks.

The source list lives in `compiler-benchmark/baseline-lib-srcs.txt` (705 `.scala`
files in our setup); generate it once from a clean checkout with `find
src/{library,reflect,compiler} -name '*.scala'`.

### Driver: custom, not JMH

We use a small custom driver (`CompilerBench.scala`) rather than JMH. JMH's
setup/teardown model doesn't fit the compiler well, and for second-scale
operations the JMH overhead doesn't buy you anything. The driver:

- Takes a file list, a classpath, an output dir, warmup and iteration counts.
- Runs `new Global(...).Run().compile(srcs)` in a fresh `Global` per iteration.
- Cleans the output dir between iterations.
- Prints per-iteration wall time and a final `min / median / avg / max`.

See the full script in the appendix (§9).

### Fresh JVM per measurement

`compare.sh` launches a **new JVM** for every measurement (both baseline
and optimized). Do not reuse a single JVM across both compilers — JIT
code cache and inline cache state will contaminate the measurement.

### Warmup and iteration counts

On our setup 3 warmup iterations was enough to reach steady state (iter 0
runs ~2x slower than iter 1, iter 2 matches iter 1). 10-15 measurement
iterations per JVM gave stable medians. 5-8 JVM runs, interleaved, is the
detection floor described in §4.

## 4. Getting initial numbers

### Build the compiler you want to test

```bash
sbt 'dist/mkQuick'
# build/pack/lib/{scala-library,scala-reflect,scala-compiler}.jar
```

Keep a separately-built **baseline** distribution somewhere outside the git
checkout so you can switch branches without rebuilding the baseline:

```bash
git worktree add /home/you/baseline <baseline-commit>
(cd /home/you/baseline && sbt 'dist/mkQuick')
```

### Single run

```bash
bash compiler-benchmark/run-bench.sh /home/you/scala/build/pack 3 10 my-label
# or with taskset off (e.g. during profiling):
TASKSET=0 bash compiler-benchmark/run-bench.sh /home/you/scala/build/pack 3 10 my-label
```

Output:

```
Benchmarking 705 source files, 3 warmup + 10 measurement iterations
iter  0 (  warmup): 18805 ms
iter  1 (  warmup):  9412 ms
iter  2 (  warmup):  9155 ms
iter  3 (measured):  9034 ms
...
min=8932 ms median=9044 ms avg=9058 ms max=9221 ms
9044
```

### Interleaved baseline vs optimized comparison

```bash
bash compiler-benchmark/compare.sh 8 3 15    # 8 JVM runs, 3 warmup, 15 iters each
```

This runs baseline and optimized **alternating**, so thermal or background-
process drift affects both sides equally. It dumps medians to
`/tmp/bench-{base,new}.tsv` and computes stdev + median delta + percent at
the end.

### Noise levels (observed on our EC2 instance)

Headline numbers (compiling the Scala library as our ~8.5 s workload):

| scenario (taskset)                       |  n | median |  stdev | CV%  |
| ---------------------------------------- | -: | -----: | -----: | ---: |
| untuned env, adjacent runs               |  8 |   8658 |   92.4 | 1.07 |
| untuned env, 60 s gaps                   |  8 |   8608 |  101.3 | 1.18 |
| tuned env (conservative), adjacent runs  |  8 |   8614 |   77.2 | 0.90 |
| tuned env (conservative), 60 s gaps      |  8 |   8500 |  114.8 | 1.35 |
| tuned env (aggressive kills), adjacent   | 16 |   8494 |   83.2 | 0.98 |
| tuned env (aggressive kills), 60 s gaps  | 10 |   8479 |   83.1 | 0.98 |

"Conservative" kills: chatty-but-nonessential services (cron, apt-daily,
collectd, livepatch, etc.) + HT offlining + THP off + IRQ pinning +
cgroup cpuset partition. See §11.

"Aggressive" kills add the vendor monitoring agents (Kolide, CrowdStrike
Falcon userspace daemon, osquery metric forwarder, AWS SSM), plus
chrony, auditd, rsyslog, snapd, polkit, and the Databricks
termination-watcher/devbox_daemon. See §11.

Key takeaways:

- **Adjacent runs**: conservative and aggressive modes produce
  statistically indistinguishable stdev at n≤16 (~77-83 ms). The
  aggressive kills *do* drop the median by ~120 ms (~1.4%) -- real
  throughput improvement, but not variance improvement.
- **Spread runs** (multi-hour campaigns): aggressive kills matter a
  lot. Stdev drops from 115 -> 83 ms (~28% reduction), spread from
  395 -> 240 ms (~40%), CV from 1.35% -> 0.98%. Over long durations
  the background daemons' polling work accumulates into visible drift;
  killing them removes it.
- Reliable detection floor (approximately the same across modes -- the
  environment tuning shifts the noise but doesn't change the detection
  calculus):
  - 5 JVM runs: ~1.8% (≥150 ms at our ~8.5s baseline)
  - 8 JVM runs: ~1.2% (≥100 ms)
  - 16 JVM runs: ~0.8% (≥70 ms)
  - Below that: track absolute-median trends across many rounds rather
    than trusting any single comparison's p-value.

The dominant remaining source of variance on a shared EC2 node is
cross-VM contention ("noisy neighbours") plus Falcon's in-kernel BPF
hooks that we can't uninstall from inside the guest (see §11).

A companion campaign on a dual-socket bare-metal instance (Xeon
8468H, full `bench-env.sh` tuning, turbo off, NUMA isolation) did
**not** produce a meaningfully tighter wall-time CV — it measured
1.06% adjacent / 1.59% spread vs our EC2 VM's 0.98% / 0.98%. The
plausible culprit is that the 128-thread host has much more ambient
syscall traffic for Falcon's in-kernel BPF programs to piggy-back on,
so "the Falcon tax" is larger per bench CPU than on the 32-vCPU VM.
Details plus a research-backed answer to "is it worth building a
Falcon-free EC2 image?" are under §11's
*"How close is this to the theoretical floor?"* and
*"Is it worth getting rid of Falcon?"* subsections.

## 5. Correctness: what to run after every change

### Bytecode identity (primary)

**The pitfall:** it's tempting to compare "modified library compiled with
modified compiler" vs "baseline library compiled with baseline compiler".
That's tautologically broken and will always diff.

**The correct protocol:** compile the **same** baseline sources with both
compilers and `diff -r` the output.

```bash
# Produce baseline output once
bash compiler-benchmark/run-bench.sh /home/you/baseline 1 1 sanity-base

# Produce optimized output
bash compiler-benchmark/run-bench.sh /home/you/scala/build/pack 1 1 sanity-new

diff -r sandbox/bench/libout-sanity-base sandbox/bench/libout-sanity-new | wc -l
# expect: 0
```

Run this after **every** change that touches code generation or that you
think might affect bytecode. It's much cheaper than the test suite and
catches the most common correctness regressions.

### MiMa (scala-library / scala-reflect)

Any change in `src/library/**` or `src/reflect/**` that affects the public
API must pass MiMa in both directions:

```bash
sbt 'library/mimaReportBinaryIssues' 'reflect/mimaReportBinaryIssues'
```

We hit this during the `Nil.equals` change - overriding `equals` on a
singleton `case object` required an explicit `Boolean` return type and
careful attention to the override's source signature.

### Core JUnit suites

The core-ish tests run quickly and catch semantic regressions in compiler
internals:

```bash
sbt 'junit/test'
```

716 tests, around 2 minutes on our box. Worth running after each round
rather than only at the end.

### A note on Scala 2.12's two test frameworks

Scala 2.12 uses **two** test frameworks in parallel for historical reasons:

- **partest** ("parallel test") is the original test framework for the
  Scala distribution. Each test is a `.scala` file; partest spawns a
  **fresh JVM per test** by default, which gives strong isolation but
  is expensive.
- **JUnit** was added later. Since JUnit runs all tests in a single JVM
  it's much cheaper, so over time new tests are preferentially added to
  JUnit, and existing partest tests are migrated when feasible.

In 2.12 we see the intermediate state of that migration: many compiler
tests still live in partest, some have moved to JUnit, and library tests
are a mix too. Neither framework alone is authoritative. The implication
for an optimization round is: run **both**, and pick the relevant subset
of each based on what you touched.

### Selective test runs: which suite covers what

Knowing which tests exercise the compiler vs. the standard library lets
you run a meaningful subset quickly during iteration, reserving the full
suite for pre-merge.

**JUnit: by package.** The `test/junit/` tree is organized by Scala
package, which maps cleanly onto a compiler/reflect/library split:

| SBT filter                                                  | Covers                                   | Count (files) |
| ----------------------------------------------------------- | ---------------------------------------- | ------------- |
| `junit/testOnly scala.tools.*`                              | Compiler internals (`scala.tools.nsc.*`) | 80            |
| `junit/testOnly scala.reflect.*`                            | Reflect internals + macros + runtime     | 21            |
| `junit/testOnly scala.collection.* scala.concurrent.* scala.io.* scala.math.* scala.sys.* scala.util.* scala.runtime.*` | Library   | ~100          |
| `junit/test`                                                | Everything (~716 `@Test` methods)        | 203 files     |

For compiler-optimization work, `junit/testOnly scala.tools.* scala.reflect.*`
is a fast (~1 min), focused sanity check.

**partest: by category.** partest test categories live under `test/files/`
and each directory enforces its own contract. Categories are the knob for
selective runs:

| Category                  | Contract                                    | Primary target      | Tests |
| ------------------------- | ------------------------------------------- | ------------------- | ----- |
| `test/files/pos`          | must compile cleanly                        | **Compiler only**   | 1519  |
| `test/files/neg`          | must fail with a specific `.check` error    | **Compiler only** (error messages) | 1059 |
| `test/files/run`          | compile + execute + diff stdout/stderr      | Compiler + library  | 1966  |
| `test/files/jvm`          | like `run/`, JVM-specific codegen           | Compiler (backend)  | 84    |
| `test/files/res`          | resident-compiler (REPL-style incremental)  | Compiler            | 13    |
| `test/files/presentation` | IDE presentation compiler                   | Compiler            | 46    |
| `test/files/positions`    | source-position checking                    | Compiler            | 29    |
| `test/files/specialized`  | `@specialized` expansion                    | Compiler + library  | 23    |
| `test/files/instrumented` | instrumented `BoxesRunTime`/`ScalaRunTime`  | Library (boxing)    | 7     |
| `test/files/scalap`       | `scalap` classfile decompiler               | `scalap` tool       | 22    |

Counts are "tests" as partest reports them (a single test may be a
directory with several `.scala`/`.java` files). Exact numbers drift as
tests are added/removed.

For a compiler-focused optimization round, `pos + neg` is the pure-
compilation safety net: no user code is executed, everything runs inside
the compiler. `run + jvm + specialized` add end-to-end coverage (compiler
output + library runtime together), which is where things like
`LazyTreeCopier` equality relaxations and `Nil.equals` changes would
actually manifest as behaviour regressions.

### partest — running it

**What it is.** partest's test cases live under `test/files/` as `.scala`
files. A test dir optionally contains a `.check` file with the expected
output and a `.flags` file with extra compiler flags. A diff anywhere
means failure.

**How to run it.** From sbt:

```
# Full compiler-relevant subset (recommended per round during optimization work):
sbt 'partest pos neg run jvm specialized instrumented'

# Pure compilation tests only (~5-10 min, zero user-code execution):
sbt 'partest pos neg'

# Full suite, matching the `testAll` task in build.sbt:
sbt 'partest run'
sbt 'partest pos neg jvm'
sbt 'partest res scalap specialized'
sbt 'partest instrumented presentation'
sbt 'partest --srcpath scaladoc'
sbt 'partest --srcpath async'

# Or via the IntegrationTest config (what CI uses):
sbt 'test/IntegrationTest/test'

# A single file (for debugging a specific failure):
sbt 'partest test/files/run/t1234.scala'
sbt 'partest --help'
```

**How long does it take?** Partest parallelises heavily (one JVM per
test, tests scheduled across cores). On our EC2 box:

- `partest pos neg`: ~2 min.
- `partest pos neg run jvm specialized instrumented`: ~5 min (4658 tests).
- Full `testAll`: ~15-25 min depending on load, dominated by OSGi and
  scaladoc.

Expect these to scale roughly linearly with core count. The per-JVM
spawning overhead is real but well-hidden by parallelism on machines
with many cores.

**Typical JVM count.** Each test is a new JVM launch, so `partest pos
neg run` is ~4500 JVM starts over the course of the run. Don't be
alarmed when `ps` lights up with `java` processes or when `sar` shows
thousands of context switches per second.

### When to run which, recommended cadence

| Check                                             | After every change | Per round | Before merge |
| ------------------------------------------------- | :----------------: | :-------: | :----------: |
| build (`dist/mkQuick`)                            | x                  |           |              |
| bytecode identity                                 | x                  |           |              |
| `junit/testOnly scala.tools.* scala.reflect.*`    | x (if non-trivial) | x         | x            |
| `junit/test` (full)                               |                    | x         | x            |
| `library/mimaReportBinaryIssues` + `reflect/mimaReportBinaryIssues` | x (if library/reflect touched) | x | x |
| `partest pos neg`                                 |                    | x         | x            |
| `partest pos neg run jvm specialized`             |                    |           | x            |
| full partest + OSGi (`testAll`)                   |                    |           | x (final)    |

The "per round" column is after a batch of 2-5 related changes that
haven't yet produced a visible partest failure; "before merge" is before
pushing to the shared branch. For cross-cutting changes (anything
touching `Types`, `Symbols`, `Trees`, type substitution, `LazyTreeCopier`,
or the backend) run at least `partest pos neg run` immediately — those
three together catch ~95% of real regressions without waiting for the
full suite.

**Gotchas.**

- partest is flaky on machines with heavy background load; prefer
  `TASKSET=0` (no CPU pinning, let it use all cores) and a quiet
  machine. Transient failures in `presentation/` or `jvm/` should be
  re-run before being treated as real regressions.
- The `testAll` task in `build.sbt` also runs `osgiTestFelix/test` and
  `osgiTestEclipse/test`; you probably don't need those unless you're
  touching classpath / module handling.
- First-ever partest run in a fresh checkout has to compile the
  partest framework itself; allow a few extra minutes.
- partest can leave stale `.obj/` dirs under `test/files/` — they're
  git-ignored per `test/files/.gitignore`.
- sbt arguments to `partest` can be combined in one invocation
  (`sbt 'partest pos neg run'`) — don't launch four separate sbt JVMs
  when you can launch one.

## 6. Profiling with JFR on OpenJDK 17

### Command line

```bash
$PREFIX java \
  -XX:+FlightRecorder \
  -XX:FlightRecorderOptions=stackdepth=128 \
  -XX:StartFlightRecording=filename=/tmp/run.jfr,settings=profile \
  -Xms2g -Xmx2g -XX:+UseParallelGC \
  -cp "$CP" benchmark.CompilerBench "$SRC_LIST" "$COMPILE_CP" "$OUT" 3 10
```

Then dump a text profile:

```bash
jfr print --events ExecutionSample --stack-depth 128 /tmp/run.jfr > /tmp/run.txt
python3 compiler-benchmark/parse-jfr.py /tmp/run.txt
```

### Traps to avoid

- **Don't use `-XX:+UnlockCommercialFeatures`**. It's gone in OpenJDK 17 and
  fails with "Unrecognized VM option".
- **Don't pass `duration=0`** to `StartFlightRecording`. Use the default
  `dumponexit=true` (which is already implied by `filename=...`) for a
  single-run profile.
- **Set `stackdepth=128`**. Default is 5, which truncates most Scala
  compiler stacks to the outermost dispatchers (`Global.Run`, `Typer.typed`,
  ...) and hides all the actual hotspots.
- **Pass `--stack-depth 128` to `jfr print` too** — it defaults to 5 as
  well, independently of the recording setting.
- **Disable taskset for profiling runs** (`TASKSET=0`). Pinning to 4 cores
  distorts the JIT's tiered-compilation decisions vs. the benchmark run.
- The `.jfr` file is binary - don't try to grep it directly; always go
  through `jfr print`.

### Parsing

`parse-jfr.py` (§9) aggregates samples by method and prints two tables:

- **Self time** (sample's top frame): where code is actually executing.
- **Inclusive time** (any frame in stack): how much total wall clock a
  method is responsible for.

Both matter: self time tells you where to optimize locally, inclusive time
tells you which dispatchers are funnelling work. A method that appears in
only one column is a useful signal:

- **High self, low inclusive** → pure leaf hotspot, optimize in place.
- **Low self, high inclusive** → big dispatcher; optimize its callees or
  reduce the number of calls.

### Reading Scala names in JFR output

- `List.loop$1` is the inner loop of `mapConserve`, not a user method.
- `$anonfun$foo$1` is a closure; the `1` is a compiler-assigned ordinal.
- `Types$TypeRef$class.equals` is the trait dispatcher for an abstract
  case-class `equals`. If you see time there, it usually means the `@inline
  final` wasn't applied to a trait method.
- `scala.runtime.BoxesRunTime.equalsNumObject` appearing for a Tree/Symbol
  comparison is a red flag — see §7.
- `Trees$$Lambda$NNNN/0xHEX` (or any `*$$Lambda$...`) frames in
  *allocation* dumps are the JIT-generated implementation classes for
  `Function0/1/2`. Their owning source frame is the *next* one above
  in the stack — `find-jfr-alloc-callers.py` finds it for you (see
  "Allocation profiling" below).

### Allocation profiling

Execution sampling shows where the JVM spends CPU; **allocation
sampling** shows where it spends GC time and where escape analysis is
failing. Both are needed: most of the round-2 optimizations (§10.2)
came from allocation-only signals — per-call lambda allocations on hot
paths that didn't surface as obvious self/inclusive hotspots in
execution samples but appeared as multi-hundred-MB entries in the
allocation dump.

JDK 16+ has a low-overhead `ObjectAllocationSample` event that's
enabled by `settings=profile` (the same setting that enables
`ExecutionSample`). One recording captures both:

```bash
$PREFIX java \
  -XX:+FlightRecorder \
  -XX:FlightRecorderOptions=stackdepth=128 \
  -XX:StartFlightRecording=filename=/tmp/run.jfr,settings=profile \
  -Xms2g -Xmx2g -XX:+UseParallelGC \
  -cp "$CP" benchmark.CompilerBench "$SRC_LIST" "$COMPILE_CP" "$OUT" 3 10
```

`run-bench.sh` accepts these flags via `EXTRA_JVM_OPTS`:

```bash
EXTRA_JVM_OPTS="-XX:+FlightRecorder \
  -XX:FlightRecorderOptions=stackdepth=128 \
  -XX:StartFlightRecording=filename=/tmp/run.jfr,settings=profile" \
TASKSET=0 bash compiler-benchmark/run-bench.sh build/pack 3 10 prof
```

Dump and aggregate the allocation events:

```bash
jfr print --events jdk.ObjectAllocationSample --stack-depth 128 \
  /tmp/run.jfr > /tmp/alloc.txt
python3 compiler-benchmark/parse-jfr-alloc.py /tmp/alloc.txt
```

The output has two tables:

- **By `objectClass`** — which type was allocated. Useful to spot
  fundamental data-structure pressure (`$colon$colon`,
  `Types$ClassArgsTypeRef`, `Symbols$TypeHistory`, etc.).
- **By top frame** — where the allocation occurred. `*$$Lambda$NNNN/0xHEX`
  frames are the JIT-generated `Function0/1/2` impls; their owning
  source frame is one frame above (use `find-jfr-alloc-callers.py`).

Once a hotspot is identified, drill into callers:

```bash
# Who's calling the WeakHashSet.findEntry allocation site?
python3 compiler-benchmark/find-jfr-alloc-callers.py /tmp/alloc.txt \
  "WeakHashSet.findEntry" 1
# `depth` of 2..3 peels through `<init>` chains or thin wrappers
# (e.g. a Function1.apply forwarder).
```

For execution samples the symmetric tool is `find-jfr-callers.py`
(top callers of a sampled method); use it when `parse-jfr.py` shows a
hot leaf concentrated in a single frame and you want to know which of
the dozens of call sites is responsible (e.g. `mapConserve.loop$1`).

#### How allocation pressure relates to wall time

Allocation rate isn't the same as wall time, but the correspondence
is real on this workload:

- The compiler runs with `-XX:+UseParallelGC -Xms2g -Xmx2g`, which
  makes minor GCs cheap. Killing 200-500 MB of allocations per bench
  run typically buys 0.3-1.0% wall improvement, mostly from reduced
  eden churn.
- Per-call `Function1`/`Function0` allocations on the type-map and
  tree-transformer hot paths are the easiest wins: a single closure
  removal often translates into a hot-loop body shape the JIT inlines
  more aggressively, helping wall time beyond the GC saving.
- Allocation cuts that *don't* show up in wall time are the warning
  sign covered in §8 ("when source-level lambda elimination doesn't
  help").

## 7. Scala-2.12 performance traps (the hard-won ones)

These are the gotchas that surfaced repeatedly during profiling and that
are worth knowing before you start writing "clever" code.

### `==` on AnyRef routes through BoxesRunTime

Even for `Tree`, `Symbol`, `Name` (whose `.equals` is reference equality
or fully subsumed by interning), `a == b` compiles to
`BoxesRunTime.equals(a, b)`, which does:

1. `a == null` check
2. `a instanceof Number`
3. `a instanceof Character`
4. virtual dispatch to `a.equals(b)`

`a eq b` compiles to a single `if_acmpeq` bytecode. In hot paths like
`LazyTreeCopier` this is easily 1% of total compile time.

Use `eq` wherever the operands are AnyRef and their `equals` reduces to
reference equality. Where structural fallback is needed (e.g. `List[Tree]`
where different list instances with the same elements should compare
equal), a `(a eq b) || (a == b)` helper is the standard pattern.

### `List.isEmpty` is a virtual call; `xs eq Nil` is not

Both are correct, but `xs eq Nil` compiles to a single bytecode instead of
an `invokevirtual` through the `List` vtable. In very hot fast paths
(`TypeMap.mapOver`, `SubstMap.apply`) this matters.

### `case x :: xs` has dispatch overhead

```scala
// Slower:
@tailrec def loop(xs: List[Symbol]): Int = xs match {
  case x :: tl => ...
  case _       => -1
}

// Faster:
var xs = origSyms
while (xs ne Nil) {
  val x = xs.head
  ...
  xs = xs.tail
}
```

The `::` extractor goes through `List.unapply`, which has its own dispatch
and null-check overhead. For >10-element lists the direct `head`/`tail`
loop wins clearly.

### `@inline` is advisory without `-opt:l:inline`

The Scala 2.12 compiler honours `@inline` **only** when running with
`-opt:l:inline` (and only for methods whose owners are on the
`-opt-inline-from` classpath). We can't turn that on because it changes
user bytecode. So `@inline` in the compiler's own source code is a
suggestion to HotSpot, nothing more.

Corollary: **a helper method may be worse than the inlined code.** During
round 10 a `sameMods` helper caused a measurable regression vs. manually
inlining `(mods0 eq mods) || (mods0 == mods)` at every call site, because
HotSpot didn't inline `sameMods` during the early warmup iterations.

Plan for HotSpot inlining:
- Tiny body (< 35 bytecodes is a good rule of thumb).
- No try/finally, no closures.
- `private` methods compile to `invokespecial` which HotSpot inlines more
  aggressively than `invokevirtual`.

### `@tailrec` can't traverse changing receivers

```scala
// Does NOT tail-call optimize:
@tailrec def nextFrom(from: Int): InfoTransformer =
  if (from < pid) prev.nextFrom(from)   // receiver changes!
  else            next.nextFrom(from)
```

`@tailrec` requires the recursive call to be on the *same* receiver. For
linked-list traversal the fix is a manual `while` loop advancing a `var
cur: InfoTransformer`.

### `List.foreach { ... }` allocates a Function1 per call

Fine in cold code. Visible in profiles when the call is in a per-call
constructor (like `SubstMap.<init>`) that itself runs on a hot path.
Replacement pattern:

```scala
// Before:
xs.foreach { x => ... }

// After (no Function1 allocation):
var cur = xs
while (cur ne Nil) {
  val x = cur.head
  ...
  cur = cur.tail
}
```

### Pattern-matched case classes can allocate

Pattern matching against case classes **usually** compiles to direct field
access, but for abstract case classes (like `TypeRef`) with a manually-
overridden `unapply` the generated code can call `unapply` and allocate an
`Option`/`Some` tuple. If you see time in `$unapply$1` type frames, the
fix is to replace the pattern match with direct `isInstanceOf` +
field access, or arrange for the case class to be concrete.

### By-name parameters allocate Function0

Each call to a method that takes a by-name (`=> A`) parameter wraps the
argument expression in a fresh `Function0` instance — even when the
parameter ends up unused at runtime. Three common offenders:

- `Map.getOrElse(k, default)` — `default` is by-name; on a cache hit
  the closure was allocated for nothing.
- `xs.fold(zero)(op)` and similar — `zero` is by-name in some
  signatures (e.g. `ConstantFolder.fold`).
- `debuglog(msg)` / `debuglogResultIf(msg) { ... }` — the message is
  by-name, and the `Function0` is allocated *before* the level check
  short-circuits.

Mitigations:

```scala
// Before -- closure allocated unconditionally:
map.getOrElse(k, classBTypeFromSymbol(sym))

// After -- check the cache first; only fall back when missing:
val cached = map.get(k)
if (cached.isDefined) cached.get
else classBTypeFromSymbol(sym)
```

Symmetrically for `debuglog`-style sites:

```scala
// Before -- the s"..." interpolation runs and Function0 allocates
//           even when isDebug is false:
debuglog(s"adding synthetic ${sym.fullLocationString}")

// After:
if (isDebug) debuglog(s"adding synthetic ${sym.fullLocationString}")
```

These trace cleanly in `parse-jfr-alloc.py`'s output as
`*$$Lambda$NNNN/0xHEX` entries owned by the call site.

### Eager init lambdas in cache constructors

A common idiom in the backend looks like:

```scala
// ClassBType.apply caches by name; the trailing { res => ... }
// init lambda only runs when the cache misses.
ClassBType(internalName, fromSymbol = true) { res =>
  if (completeSilentlyAndCheckErroneous(classSym))
    Left(NoClassBTypeInfoClassSymbolInfoFailedSI9111(classSym.fullName))
  else computeClassInfo(classSym, res)
}
```

The closure captures `classSym` and `this`, so it's instantiated at the
call site **on every call** — including cache hits. In a code-gen hot
path (`classBTypeFromSymbol`) the cache hit rate is very high, so the
lambda allocation is mostly waste (~340 MB / bench run in our profile).

Fix: pre-check the cache and only construct the lambda on miss:

```scala
val cached = classBTypeCache.get(internalName)
if (cached ne null) cached
else
  ClassBType(internalName, fromSymbol = true) { res => ... }
```

This is the same pattern as the by-name parameter trap above; the
difference is that here the closure is *intentional* (cache constructor
argument), but its cost-of-allocation profile is the same.

### `case class .copy` on no-op changes

`case class Modifiers(...)` provides an autogenerated `.copy` that
allocates a fresh instance unconditionally, even when every "changed"
argument is structurally equal to the existing field. Hot example:

```scala
// Before -- allocates a new Modifiers even when annotations is already Nil:
def typedModifiers(mods: Modifiers): Modifiers =
  mods.copy(annotations = Nil) setPositions mods.positions

// After:
def typedModifiers(mods: Modifiers): Modifiers =
  if (mods.annotations eq Nil) mods
  else mods.copy(annotations = Nil) setPositions mods.positions
```

The most common source members carry no annotations on the parse tree,
so the guarded version skips an allocation in the bulk of typer
ValDef/DefDef/ClassDef/ModuleDef/TypeDef calls (~233 MB / bench run).

### `for (i <- 0 until n) ...` boxes Int through PartialFunction

```scala
for (i <- 0 until length if isAtEndOfLine(i)) buf += i + 1
```

desugars to a `withFilter` + `foreach` chain that goes through
`RangeIterator.next` (returning boxed `Integer`) and a `PartialFunction`,
**not** the specialized `Int` fast-path of `Range.foreach`. In
`BatchSourceFile.lineIndices` this contributed ~1.5 GB of `Integer`
allocations per bench run. The standard fix is the explicit `while`
loop with the predicate inlined:

```scala
val buf = ListBuffer.empty[Int]
buf += 0
var i = 0
while (i < length) {
  val ch = content(i)
  if (ch == CR || ch == LF || ch == FF) {
    if (ch == CR && i + 1 < length && content(i + 1) == LF) i += 1
    buf += i + 1
  }
  i += 1
}
```

### Caching map instances on hot paths

`AsSeenFromMap` and `SubstSymMap` are immutable after construction and
are heavily allocated on the type-substitution hot path (`Type.substSym`
allocated ~1.8 GB / bench run before optimization). A 1-slot cache
(`var lastFrom; var lastTo; var lastMap`) keyed on the from/to
list pair covers the bulk of repeated calls — the same pair is reused
for a whole class's worth of substitution under a single owner change.

We tried a 2-slot LRU and it regressed: the second slot's check +
bookkeeping cost more than the extra hit-rate gained. **More slots
aren't always better; benchmark the actual distribution before
adding capacity.**

## 8. The optimization loop

The rhythm that worked for us:

1. **Profile** a fresh run with `settings=profile` so you get *both*
   `ExecutionSample` and `ObjectAllocationSample` events
   (`TASKSET=0 ... -XX:StartFlightRecording=...`; see §6).
2. **Identify** the top 2-3 self-time and top 2-3 inclusive-time methods
   in `parse-jfr.py`; **and** the top objectClass/top-frame entries in
   `parse-jfr-alloc.py` (§6 "Allocation profiling"). Round 2 of our
   work (§10.2) was driven mostly by the allocation table — many
   wins didn't surface as obvious self/inclusive hotspots.
3. **Make one small change**. Really one. Bundling made bisection painful
   later. The two profiling tables often suggest different fixes; pick
   one and follow it through, don't combine.
4. **Build**: `sbt 'dist/mkQuick'` for compile-only changes;
   `sbt 'dist/mkPack'` if you'll feed `build/pack` to `compare.sh`
   (the latter rebuilds the JARs that `run-bench.sh` consumes; the
   former leaves `build/pack/lib/*.jar` stale).
5. **Bytecode identity**: `diff -r libout-sanity-base libout-sanity-new | wc -l`.
6. **MiMa** (if library/reflect changed).
7. **JUnit core suite** (`sbt junit/test`) if anything non-trivial.
8. **Benchmark**: `bash compare.sh 5 3 10` first; if it looks like a real
   win, confirm with `compare.sh 8 3 15`. Read all three of the new
   compare.sh tables (§9): the median can land on noise where
   `wall_total_ms` (lowest CV per §13) shows the real signal.
9. **Commit** with JFR numbers in the message — both wall delta and
   the allocation impact in MB / bench run if applicable.
10. **Re-profile every 2-3 rounds** — the hotspot landscape shifts faster
    than you'd expect. Methods you didn't touch can *grow* in percentage
    because they held constant while others shrank.
11. **partest pos neg** per round (not per change — it's slower); add
    `run jvm specialized` before merging. See §5 for the rationale — I
    skipped this early and it's the one correctness gap I'd flag for
    next time.

### When source-level lambda elimination doesn't help

Several round-2 attempts looked great on paper — a 200-500 MB lambda
entry in `parse-jfr-alloc.py`, an obvious `foreach`/by-name closure to
remove — and then regressed in `compare.sh`:

| Site                                                   | Approach                                        | Result    |
| ------------------------------------------------------ | ----------------------------------------------- | --------- |
| `Typers.addSynthetics` for-comprehension               | Manual `Option` checks + early `isEmpty` return | ~ -1%     |
| `AsSeenFromMap.correspondingTypeArgument` `indexWhere` | Hand-rolled `while` loop                        | ~ -0.4%   |
| `Scopes.lookupEntry` `phase.flatClasses` re-read       | New cached `nameWhenFlat` accessor              | ~ -0.8%   |
| `Infer.checkAccessible` `Symbol.filter`                | Inlined filter into call site                   | regression|
| `Infer.isCompatibleArgs` `corresponds`                 | Inlined as `while` loop                         | regression|
| `Symbols.cloneSymbolsAndModify` `foreach`              | Hand-rolled `while` over `foreach`              | regression|
| `Trees.itransform` `atOwner` calls                     | Inlined owner-management state                  | StackOverflowError |

The pattern is: the JIT's escape analysis was already eliminating these
allocations in steady state, or making them effectively free via TLAB
bump-pointer + young-gen reclaim. Removing them at source level adds
branches/instructions on the hot path that the JIT can no longer fold
away. **Allocation samples are a flag that something worth investigating
exists — they are not a guarantee that hand-elimination will help.**

Practical filter for "is this lambda likely to benefit from
elimination?":

1. **Does the closure escape its caller?** Closures stored in fields
   (`SubstSymMap`'s `from`/`to`) or returned from methods can't be
   escape-analyzed; they're real allocations. Closures consumed
   inline (e.g. `Map.getOrElse`'s by-name) often *can* be EA-eliminated.
2. **Is the call site polymorphic / megamorphic?** Polymorphic call
   sites confuse EA more often than monomorphic ones. If
   `parse-jfr.py` shows the caller as a hot dispatcher with many
   targets (`Trees$Transformer.transform`), EA is less likely to
   handle the closure cleanly.
3. **Is there state to manage?** `atOwner`, `localTyper.context.make`,
   etc. carry critical side effects. Manually inlining such helpers
   risks subtle owner-tracking bugs (we hit a `StackOverflowError`
   trying to inline `atOwner` in `Trees.itransform`); do it only when
   the helper has no side effects beyond returning a value.
4. **Did `compare.sh` actually move?** Always benchmark; revert
   anything that regresses or is a no-op at >5 runs. The cost of a
   failed-but-reverted attempt is one bench cycle (~10 min); the cost
   of an unreverted regression is the next round's "where did this
   200 ms come from" search.

Same caveat applies to "obvious" `if (x.isEmpty) return ...` early
returns: the `for`/`foreach` body can be cheaper than the dispatch +
branch on `isEmpty` when the typical case is non-empty.

### Absolute vs relative deltas

Percent deltas against baseline are noisy when baseline noise (other
load, thermal) drifts run-to-run. For small gains, compare **absolute
median latency across rounds** on the optimized side:

- Round N optimized median: 8328 ms
- Round N+1 optimized median: 8246 ms
- → ~80 ms absolute gain, regardless of what that round's baseline did.

We caught several real wins this way that `compare.sh`'s percent delta
would have called noise.

## 9. Reference scripts

All scripts and source lists referenced in this document live in
`compiler-benchmark/` (this directory).  Temporary build outputs, perf
CSVs, and per-run libouts go under `sandbox/bench/` instead — that path
is gitignored.

| File                              | Role                                                                                                               |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `CompilerBench.scala`             | Self-compile JMH-style driver: warmup + measured iters in one JVM, optional `perf stat` FIFO control (§13).        |
| `run-bench.sh`                    | Launches one JVM run of `CompilerBench` against a given `build/pack`, with optional `taskset` / `cgroup` / `perf`. |
| `compare.sh`                      | Interleaved baseline-vs-optimized A/B comparison over N JVM runs.                                                  |
| `noise-measure.sh`                | Repeats the same benchmark N times to characterize noise (adjacent or `SLEEP_SEC`-spread).                         |
| `corpus-bench.sh`                 | Wraps `run-bench.sh` over a `compiler-benchmark` corpus (`scalap`, `re2s`, ...).  See §12.                         |
| `bench-env.sh`                    | `set` / `reset` / `status` / `run` for the low-noise machine setup.  See §11.                                      |
| `build-commits.sh`                | Build a list of git SHAs and stash each `build/pack` under `$BENCH_BUILDS_DIR/<short-sha>/`.  Used by §13.         |
| `perf-walk.sh`                    | Walks pairs of (parent, child) commits with interleaved benchmark runs and `perf stat`.  Used by §13.              |
| `perf-walk-analyze.py`            | Aggregates `perf-walk.sh` raw `runs.tsv` into per-pair deltas, CVs, and correlations.                              |
| `parse-jfr.py`                    | Aggregates `jdk.ExecutionSample` JFR text dumps into self/total method tables.  See §6.                            |
| `parse-jfr-alloc.py`              | Aggregates `jdk.ObjectAllocationSample` JFR text dumps by `objectClass` and by top frame.  See §6 "Allocation profiling". |
| `find-jfr-callers.py`             | Tracks the top callers of a sampled method in an `ExecutionSample` dump.  Use to peel back from a hot leaf to its hot caller. |
| `find-jfr-alloc-callers.py`       | Like `find-jfr-callers.py` but for `ObjectAllocationSample` dumps.  Maps lambda-allocation entries back to their owning source frame. |
| `commits.txt`                     | Default commit list for `build-commits.sh` and `perf-walk.sh` (the 16 optimization commits + their parent).        |
| `baseline-lib-srcs.txt`           | The 705-file frozen source list `run-bench.sh` defaults to; described in §3.                                       |
| `lib-srcs.txt`                    | Re-derivable source list (kept around so we can diff against the frozen one).                                      |

`corpus-bench.sh` writes its cached `corpus-<name>-srcs.txt` into
`sandbox/bench/` (gitignored, regenerated on each run).

The scripts are the canonical source.  Earlier revisions of this doc
embedded their text inline; once the dir was moved out of `sandbox/`
and is now reachable directly, that became redundant.

### Compiling `CompilerBench.scala`

The driver class needs to be compiled once against a working
`build/pack` before the rest of the harness can use it.  The compiled
classes go to `sandbox/bench/out/` (a temporary location — `run-bench.sh`
and friends know to look there):

```bash
mkdir -p sandbox/bench/out
scalac -d sandbox/bench/out \
  -cp build/pack/lib/scala-compiler.jar:build/pack/lib/scala-library.jar:build/pack/lib/scala-reflect.jar \
  compiler-benchmark/CompilerBench.scala
```

Recompile after any edit to `CompilerBench.scala` (e.g. when toggling
features in §13).

## 10. Results summaries

### 10.1 Round 1 — 2026-04

The first optimization series, captured in commits
`78c2d0d597..4724f924a4` and primarily driven by **execution-sample**
profiling:

| Change                                           | Inclusive JFR impact        |
| ------------------------------------------------ | --------------------------- |
| `Contexts.make` fused matches                    | ~1% self on the make site  |
| `Scopes.lookupEntry` hoist `flat` branch         | ~1.5% self on lookup        |
| `InfoTransformer.nextFrom` while loop            | small, but removed a frame  |
| `WeakHashSet.findEntryOrUpdate` hash pre-check + eq | 5.0% -> 3.8% self        |
| `TypeRef.equals` reordered, `copyTypeRef` eq     | ~0.6% absolute              |
| `TypeMap.flipped` specialized, `skipPrefixOf` inline | closures eliminated     |
| `SubstMap.subst` id-range + while loop           | 1.6% -> 0.9% self           |
| `SubstMap.<init>` foreach -> while               | 0.9% -> <0.1% self          |
| `Symbol.rawInfo` fast path                       | 2.4% -> 1.8% self           |
| `firstChangedSymbol` while loop + inline         | 1.2% -> 0.3% self           |
| `LazyTreeCopier` eq fast paths                   | BoxesRunTime ~3% -> <0.5%   |
| `transformStats` `ne` instead of `!=`            | halved BoxesRunTime trace   |
| `TypeMap.mapOver` args `eq Nil`                  | small, many-times improvement |
| `SubstMap.apply` / `SubstSymMap.apply` `eq Nil`  | small, many-times improvement |
| `Type.subst` / `substSym` `eq Nil`               | small, many-times improvement |
| `List`/`LinearSeqOptimized`/`Collections` eq paths | library-wide eq short-circuit |

Cumulative: ~3.3% / ~280-330 ms faster median per full library-compile on
our 8×15-iter benchmark (optimized median 8286.5 ms vs baseline 8568.0 ms).

### 10.2 Round 2 — 2026-05

Round 2 (commits `de101cbee5..24f32e17ba`, on top of round 1) added
**allocation profiling** to the loop (§6 "Allocation profiling") and
was driven primarily by `parse-jfr-alloc.py`.

#### Harness changes carried in this round

A few small ergonomic additions to the existing scripts; nothing that
requires re-running prior round-1 numbers but worth knowing about for
the next round:

- `run-bench.sh` accepts `EXTRA_JVM_OPTS=...` to inject ad-hoc JVM
  flags before `-cp`. Used to plumb the JFR `+FlightRecorder` /
  `StartFlightRecording` flags through unchanged (§6).
- `compare.sh` now takes `BASE` / `NEW` env vars (defaulted to the
  same paths as before), and its summary table is extended from a
  single per-iter median to three rows: per-iter median,
  `wall_measured_ms`, and `wall_total_ms` — the last has the
  lowest CV in our environment (§13) and is now the recommended
  primary metric for small (<0.5%) deltas.
- `parse-jfr-alloc.py`, `find-jfr-callers.py`,
  `find-jfr-alloc-callers.py` were added (§9). The first two are
  the symmetric-allocation pair for the existing `parse-jfr.py`;
  the third pivots from a sampled method to its top callers and is
  useful for both metrics (`mapConserve.loop$1` showed up as a
  concentrated leaf in execution samples; `find-jfr-callers.py`
  attributes its samples to specific transformer callers).

#### Wins

Each row's "alloc impact" is the lambda/closure/object volume
eliminated per bench run as attributed by JFR; the wall-time deltas
are from `compare.sh 5..8 × 3 warmup × 10..15 measured` against the
round-1 tip:

| Change                                                                  | Alloc impact / run  | Wall delta |
| ----------------------------------------------------------------------- | ------------------: | ---------: |
| `Modifiers.equals` eq-first short-circuits                              | reduced BoxesRunTime |  small     |
| `LazyTreeCopier.DefDef` `sameListList` for `vparamss`                   | reduced eq cost     | small      |
| `deriveSymbols` / `TypeMap.mapOver(syms)` `foreach` -> `while`          | -86 MB Function1    | small      |
| `Type.substSym` 1-slot `SubstSymMap` cache                              | -1.8 GB SubstSymMap | -0.93%     |
| `BatchSourceFile.lineIndices` `for` -> `while` (no Int boxing)          | -1.5 GB Integer + PartialFunction | -1.05% |
| `isSubArgs` inline `corresponds3` + `isSubArg` as `while`               | -336 MB Function2   | -0.46%     |
| `Symbol.overriddenSymbol` inline filter (no Function1)                  | -351 MB Function1   | (combined) |
| `Types.isWithinBounds` inline `corresponds` as `while`                  | -153 MB Function2   | (combined) |
| `ConstantFolder.apply` inline `fold` (no by-name `Function0`)           | -149 MB Function0   | (combined) |
| `synthetics.get` inline `debuglog` Option mapping                       | reduced Option/Some | (combined) |
| `BTypesFromSymbols.classBTypeFromSymbol` cache check before init lambda | -340 MB Function1   | (combined) |
| `BTypesFromSymbols.primitiveOrClassToBType` `getOrElse` -> `get`/`isDefined` | -261 MB Function0 | -1.03%   |
| `Typers.typedModifiers` skip `Modifiers.copy` when `annotations eq Nil` | -233 MB Modifiers   | -0.32%    |

Cumulative round-2 wall-time gain over the round-1 tip
(`compare.sh 5 3 10`, n=5 JVM runs per side; bench-env.sh not active
on this measurement, so absolute medians are noisier than §10.1):

| metric              | baseline median | optimized median | delta              |
| ------------------- | --------------: | ---------------: | -----------------: |
| per-iter median     |        9353 ms  |        9233 ms   |  -120 ms / -1.28%  |
| `wall_measured_ms`  |       93367 ms  |       92801 ms   |  -566 ms / -0.61%  |
| `wall_total_ms`     |      144979 ms  |      144425 ms   |  -554 ms / -0.38%  |

Per-iter median (-1.28%) is the noisiest of the three;
`wall_measured_ms` (-0.61%) is the more reliable single-number
estimate per §13. The gap between -1.28% and -0.38% is the variance
floor — if you re-run, expect any of those numbers to shift by ~0.5
percentage points. Combined round-1 + round-2 vs the original
baseline (a separate `compare.sh` against `BASE=/home/stefan.zeiger/baseline`)
adds the round-1 ~3.3%, putting the cumulative span at roughly
3.5-5% wall on this workload — most of the round-2 individual deltas
overlap on the type-substitution / tree-transformer paths and so
don't add linearly.

Round 2 highlights, methodology-wise:

- The single biggest workflow change was adding **`ObjectAllocationSample`
  events** to the JFR recording. Roughly two-thirds of the round-2
  wins (`SubstSymMap` cache, `BatchSourceFile.lineIndices`, both
  `BTypesFromSymbols` sites, `corresponds3`, `overriddenSymbol`,
  `isWithinBounds`, `ConstantFolder.apply`, `typedModifiers`) had no
  visible signature in `parse-jfr.py`'s self/inclusive tables — they
  surfaced only as 100-500 MB entries in `parse-jfr-alloc.py`.
- The 1-slot `SubstSymMap` cache pattern (§7 "Caching map instances on
  hot paths") is now a reusable template for any other immutable
  type-map heavily allocated on a known repeating from/to pair.
- Several attempts at "obvious" lambda elimination regressed (§8 "When
  source-level lambda elimination doesn't help"). The negative result
  matters: the JIT's escape analysis is doing a lot of work that
  source-level rewrites can disrupt.

**Correctness at HEAD of the branch (`24f32e17ba`):**

- Bytecode identity: verified end-to-end on every commit and after the
  final rebuild.
- MiMa: `library/mimaReportBinaryIssues` + `reflect/mimaReportBinaryIssues`
  green.
- JUnit: `junit/test` green — 1873 tests, 0 failed, 7 skipped.
- partest: `pos neg run jvm specialized instrumented` green — 4658 total
  (4656 passed, 2 Java-version-gated skips), 0 failed, 5m11s wall time.
  Plus all remaining non-trivial categories: `res scalap presentation`
  (80), `--srcpath scaladoc` (81), `--srcpath async` (50),
  `scalacheck/test` (1172), `osgiTestFelix/test` (4),
  `osgiTestEclipse/test` (4) — all green.

### 10.3 Future directions

After round 2 the allocation profile is dominated by inherent compiler
data structures whose volume is set by the workload, not the call
shape. Ranked by attribution (recent `parse-jfr-alloc.py` of the
HEAD-tip JFR, totals ~44 GB / bench run):

| Top allocator                                  | % of run | Inherent? | Notes |
| ---------------------------------------------- | -------- | --------- | ----- |
| `scala.collection.immutable.$colon$colon`      | 12.4%    | yes       | List cons cells. Built into `scala-reflect` API; can't replace with arrays without breaking compatibility. |
| `byte[]`                                       |  6.4%    | partly    | Mostly classfile I/O + name interning. Could be reduced by a name-table interning pass. |
| `Types$ClassArgsTypeRef`                       |  5.7%    | partly    | Constructed during type-application; some are immediately discarded. Possible win: pre-check the unique-table before building. |
| `Contexts$Context`                             |  4.6%    | yes       | One per nested scope. Pooling is complex due to `outer`-chain state; not obviously safe. |
| `Symbols$TypeHistory`                          |  4.4%    | yes       | One per phase transition per symbol. Linked-list-of-versions design baked into the symbol model. |
| `TypeMaps$SubstSymMap`                         |  4.2%    | reducible | Already cached 1-slot in `Type.substSym` after round 2. Could grow to keyed-by-symbol-ID cache if a workload ever justifies it. |
| `Symbols$TermSymbol`                           |  3.4%    | yes       | New symbols created during typer. Volume = source size. |
| `TypeMaps$AsSeenFromMap`                       |  2.6%    | reducible | Stateful (`capturedSkolems`, `capturedParams`); a cache would need to preserve those. We tried lambda elimination inside it and it regressed (§8 table). |

Concrete directions worth exploring, in rough order of (expected
gain) / (estimated risk):

- **Cache `ClassArgsTypeRef` construction sites**. The unique-table
  already deduplicates after the fact, but we still pay the
  `TypeRef.apply` allocation upstream. A pre-check against the
  unique-table by `(pre, sym, args)` before allocation could save
  on the order of 1-2 GB / bench run. The risk is straightforward:
  any subtle key-equality bug shows up immediately in MiMa /
  bytecode-identity.
- **`AsSeenFromMap` keyed cache**. Same idea as `SubstSymMap` but
  needs a key that captures the prefix + class + the captured-
  skolems set. Unlike the 1-slot `SubstSymMap` cache (which
  worked because the same from/to pair recurs across a class
  body), `AsSeenFromMap` callers are more diverse; a fixed-size
  LRU might pay off where the 1-slot didn't.
- **TypeHistory compaction**. After erasure most symbols' info
  doesn't change again; the linked list of `TypeHistory` cells
  could be compressed to a single-cell representation post-erasure.
  Risk: any phase that reads the history (debugger, reflection)
  needs to be audited.
- **Drop unnecessary `Modifiers.copy` calls elsewhere**. The
  `typedModifiers` round-2 win pattern (skip copy when the
  argument is the same as the field) likely applies in
  `Trees.copyAttrs`, `treeCopy.*`, and similar tree-copy sites.
  Each is ~50-100 MB / bench run individually.
- **Pool `MethodType` / `PolyType` instances**. There are large
  numbers of structurally-identical method types (`(): Unit`,
  `(): Object`, etc.) created during Symbol completion that the
  unique-table never sees because it interns *Type* not
  *MethodType*. A small lookaside table keyed on the parameter-
  symbol list and result type could collapse most of them.

What we believe is **not** worth pursuing without major architectural
work:

- More closure elimination on tree-transformer hot paths
  (`Trees$$Lambda$691/694`, `Typers$Typer$$Lambda$892/893`, ~1.4 GB
  combined in JFR). Round 2 spent multiple cycles on these and every
  attempt regressed. The JIT is handling them well enough that
  source-level changes consistently make things worse.
- General `$colon$colon` reduction. Replacing `List` with `Vector` /
  arrays would change the public `scala-reflect` API, which we cannot
  do. Internal `List`->`Array` rewrites are possible (e.g. parameter
  symbol lists) but each is a localized refactor with marginal
  expected gain.
- `Context` pooling. The `outer`/`enclosing`/`nestingLevel` state is
  threaded through every typer entry point; a pool that doesn't
  perfectly preserve identity semantics will produce wrong type
  inference results in subtle ways.

## 11. Low-noise benchmarking environment (`bench-env.sh`)

The scala/compiler-benchmark repo ships a `scripts/benv` that prepares a
dedicated benchmark host. It expects a hand-built dev kernel, a
particular motherboard, no hyper-threading at BIOS level, a fixed CPU
frequency, and cgroup v1 (`cpuset`). None of that applies on a shared
EC2/KVM guest running Ubuntu 22.04 with cgroup v2.

`compiler-benchmark/bench-env.sh` is our adaptation: same spirit, restricted
to knobs available inside a KVM guest with `sudo`, and supporting both
cgroup hierarchies — cgroup v2 unified (Ubuntu 22.04 default) and
cgroup v1 hybrid (Ubuntu 20.04 default).  The script auto-detects the
hierarchy at the top:

- **v2** uses `/sys/fs/cgroup/bench.slice/` with
  `cpuset.cpus.partition=root` for kernel-enforced exclusion.
- **v1** uses `/sys/fs/cgroup/cpuset/bench/` with explicit
  `cpuset.mems` and best-effort `cpuset.cpu_exclusive=1`.  The
  hierarchical exclusivity rule on v1 means the kernel will reject
  `cpu_exclusive=1` on a non-root cpuset whose parent isn't also
  exclusive; in that case we run with the cpuset pinned but not
  kernel-evicted.  In practice, with the chatty services stopped this
  is fine — see §11's "Bare-metal, Ubuntu 20.04" subsection.

### What it does

Subcommands:

```
compiler-benchmark/bench-env.sh set          # apply knobs, create bench.slice
compiler-benchmark/bench-env.sh status       # show current state
compiler-benchmark/bench-env.sh reset        # restore everything saved by set
compiler-benchmark/bench-env.sh run -- <cmd> # run <cmd> inside bench.slice
```

Knobs toggled by `set`, with env-var overrides:

| Knob                | Default | What it does |
| ------------------- | ------- | ------------ |
| `BENCH_CPUS`        | `0-3`   | CPUs dedicated to the benchmark |
| `SYS_CPUS`          | `4-15,20-31` | CPUs the rest of the system can use (skips HT siblings of 0-3) |
| `HT_OFFLINE=1`      | on      | offline HT siblings of `BENCH_CPUS` (cpu16..19 in our topology) |
| `PARTITION_ROOT=1`  | on      | promote `bench.slice` to a cpuset partition (`cpuset.cpus.partition=root`); the kernel scheduler then refuses to place any non-slice task on `BENCH_CPUS` |
| `STOP_SERVICES=1`   | on      | stop the services/sockets in `SERVICES_TO_STOP` and `SOCKETS_TO_STOP` in the script (see below) |
| `STOP_TIMERS=1`     | on      | stop `apt-daily*`, `fstrim`, `man-db`, `motd-news`, `system-cleanup`, `update-notifier*` etc. |
| `PIN_IRQ=1`         | on      | point `/proc/irq/*/smp_affinity` at `SYS_CPUS` |
| `NO_THP=1`          | on      | `transparent_hugepage/enabled` -> `never` |
| `DROP_CACHES=1`     | on      | `echo 3 > /proc/sys/vm/drop_caches` at each `run` (set 0 to keep warm caches across adjacent runs) |
| `NICE=-10`          | -10     | `renice` into the bench slice (needs sudo; silently skipped otherwise) |

Services stopped by `STOP_SERVICES=1` on this host:

- Low-hanging fruit: `acpid`, `cron`, `atd`, `irqbalance`, `collectd`,
  `packagekit`, `unattended-upgrades`, `motd-news`,
  `snap.canonical-livepatch`.
- **Vendor monitoring agents** (the real CPU offenders, ~6% combined
  before killing them): `launcher.kolide-k2` (Kolide + its child
  osqueryd), `falcon-sensor` (CrowdStrike's userspace daemon — but see
  the "self-protected" note below), `osquery-metric-forwarder`.
- System daemons not needed for benchmarking: `chrony` (NTP),
  `auditd` (kernel audit), `rsyslog`, `snapd`, `polkit`,
  `snap.amazon-ssm-agent.amazon-ssm-agent` (AWS Systems Manager),
  `networkd-dispatcher`.
- Databricks / EC2 bookkeeping: `termination-watcher`,
  `devbox_daemon`.
- **Ubuntu 20.04 baseline image extras** (silently skipped on 22.04):
  `awsagent` (legacy LSB AWS Agent), `accounts-daemon`,
  `ModemManager`, `NetworkManager` (`systemd-networkd` handles routing
  on this image), `avahi-daemon`, `rtkit-daemon`, `switcheroo-control`,
  `multipathd`, `udisks2`, `wpa_supplicant`, `gdm` (display manager —
  unused on a server), `apport` (crash reporter).

Sockets stopped by `STOP_SERVICES=1` (so the killed services don't get
socket-activated back): `syslog.socket`, `snapd.socket`, `acpid.socket`,
`acpid.path`.

Timers stopped by `STOP_TIMERS=1`: superset across both images.
22.04-only timers (`apt-daily*`, `dpkg-db-backup`,
`update-notifier-*`) and 20.04-only timers (`fwupd-refresh`) are
unioned; missing units are silently skipped.

The state is saved under `$HOME/.bench-env-state/` so `reset` can
restore prior values. That directory is on persistent storage, which
matters because our EC2 image is otherwise ephemeral — see below.

### What it deliberately does *not* touch

The explicit "don't ever stop these" list is short:

- **SSH and Eternal Terminal**: `ssh.service`, `et.service` — killing
  these logs you out.
- **Cursor remote**: runs under `user@1000.service` as node processes;
  don't disturb the Cursor session itself.
- **Arca daemon** (`arca_package_scanner.service`) — ops requirement.

Everything else is fair game. Core system infrastructure that we leave
alone for stability rather than policy (losing them would break ssh
logins or the network): `dbus`, `systemd-logind`, `systemd-journald`,
`systemd-resolved`, `systemd-networkd`, `systemd-udevd`, the user slice
(`user@1000.service`), `containerd`/`docker` (their idle footprint is
small, killing them risks breaking dev containers / devcontainers).

### Self-protected processes we can't kill (image-dependent)

**CrowdStrike Falcon** behaves very differently on the two Ubuntu LTS
images we have measured:

- **Ubuntu 22.04 + kernel 5.15 (our 22.04 EC2 image and the original
  bare-metal host).** Falcon installs a kernel module that registers
  an LSM hook; `cat /sys/kernel/security/lsm` lists `bpf` alongside
  `lockdown,capability,yama,apparmor`.  The userspace
  `falcon-sensor-bpf` process (one example: PID 757) is protected by
  the LSM: SIGKILL, `cgroup.kill`, and `cgroup.freeze` all return
  `EPERM` even from root with `CAP_SYS_ADMIN | CAP_KILL`.
  `systemctl stop falcon-sensor.service` marks the unit as failed but
  the process survives (its cgroup is
  `/system.slice/falcon-sensor.service/sensor.falcon`, managed by the
  kernel part).  Mitigations:
  - The cpuset partition keeps the Falcon userspace daemon off
    `BENCH_CPUS` (it usually settles on cpu23 or similar on our host).
    Its ~4% CPU use stays confined to the system slice.
  - The in-kernel BPF programs attached to LSM hooks still run in the
    context of *our* syscalls on bench CPUs.  This is the main
    Falcon-induced noise we cannot eliminate in-guest, and accounts
    for the 1.59% → 0.96% spread-CV improvement we measure on the
    20.04 image.
- **Ubuntu 20.04 + kernel 5.4 (our newer bare-metal image).** The
  Falcon Ubuntu 20.04 packages don't ship the kernel module.
  `cat /sys/kernel/security/lsm` shows only
  `lockdown,capability,yama,apparmor` (no `bpf`), `lsmod | grep falcon`
  is empty, and `sudo systemctl stop falcon-sensor.service` removes
  the userspace daemon cleanly with no LSM-protected stragglers.  This
  matches what scala-dev #338 calls out as the reason a dedicated host
  helps — but here we get it for free by choosing the older LTS for
  the bench image.

If you can pick the image, prefer the 20.04 baseline for benchmarking
runs even at the cost of a slightly older user-space toolchain.  The
spread-run noise floor is meaningfully lower (CV 0.68% vs 1.10% on
`wall_total_ms`).

Because our image has a persistent `/home` and ephemeral everything
else, the script is safe to re-run after a reboot; anything we
modified outside `/home` resets itself.

### What we skip (and why)

| Thing `benv` does          | Why we don't                                       |
| -------------------------- | -------------------------------------------------- |
| BIOS: disable turbo, HT    | No BIOS access in KVM                              |
| `cpupower frequency-set`   | `intel_pstate=disable` + `acpi-cpufreq` not available on the KVM guest; governors are HV-controlled |
| Custom tickless kernel (`nohz_full=2,3 rcu_nocbs=2,3 isolcpus=2,3`) | Needs rebuilding kernel; ephemeral root fs anyway |
| `clocksource=acpi_pm`      | Already on `tsc`                                   |
| `cset shield`              | Replaced by direct `cpuset` writes (v1) or `cpuset.cpus.partition=root` (v2) |

What KVM lets us do well: offline CPUs (HT siblings become offline when
we `echo 0 > /sys/devices/system/cpu/cpuN/online`), pin IRQ affinity,
disable THP, stop systemd units, and set up a cpuset partition (v2) or
exclusive cpuset (v1). That covers the majority of the single-host noise
sources short of "remove your neighbours on the hypervisor".

### Using it

```bash
# One-off at the start of a benchmarking session:
compiler-benchmark/bench-env.sh set
# Run benchmarks normally -- taskset picks up the tuned environment:
bash compiler-benchmark/run-bench.sh build/pack 3 15 my-label

# Or explicitly inside the cgroup partition (evicts non-slice tasks
# from BENCH_CPUS, useful for long-running multi-hour campaigns):
BENCH_MODE=cgroup bash compiler-benchmark/run-bench.sh build/pack 3 15 my-label

# When done (or before rebooting):
compiler-benchmark/bench-env.sh reset
```

### Measuring the win

`compiler-benchmark/noise-measure.sh` reruns the same benchmark N times and
prints the distribution. We ran three tiers to quantify the gain on
our EC2 VM (Intel Xeon 8375C, 32 vCPUs in one socket, 1 NUMA node, KVM
guest with `tsc` clocksource):

1. **untuned** — just `taskset -c 0-3`, everything else default.
2. **conservative** — earlier version of `bench-env.sh set` that kept
   the vendor monitoring agents (Falcon, Kolide, osquery-metric) alive.
3. **aggressive** — current `bench-env.sh set` with all the systemd
   services + sockets listed above stopped.

| Series                              | mode |  n |  med |  stdev | CV%  | spread |
| ----------------------------------- | ---- | -: | ---: | -----: | ---: | -----: |
| untuned,       adjacent             | tk   |  8 | 8658 |   92.4 | 1.07 |    303 |
| untuned,       60 s gaps            | tk   |  8 | 8608 |  101.3 | 1.18 |    343 |
| conservative,  adjacent             | tk   |  8 | 8614 | **77.2** | **0.90** | **251** |
| conservative,  adjacent             | cg   |  8 | 8594 |   85.5 | 1.00 |    302 |
| conservative,  60 s gaps            | tk   |  8 | 8500 |  114.8 | 1.35 |    395 |
| conservative,  60 s gaps            | cg   |  8 | 8555 |   92.1 | 1.08 |    325 |
| aggressive,    adjacent             | cg   |  8 | 8475 |   93.7 | 1.10 |    253 |
| aggressive,    adjacent             | tk   | 16 | **8494** |   83.2 | 0.98 |    250 |
| aggressive,    60 s gaps            | tk   | 10 | **8479** | **83.1** | **0.98** | **240** |

(`tk` = taskset, `cg` = cgroup partition=root.)

Observations:

1. **The conservative knobs alone** (HT offline + THP off + services/
   timers off + IRQ pin + cpuset) reduce adjacent-run stdev by ~15%
   (92 → 77 ms at n=8) and have a modest median impact.
2. **The aggressive kills give an additional ~120 ms median gain**
   (8614 → 8494 ms, ~1.4% throughput) — killing the vendor monitoring
   agents (primarily Falcon + Kolide's osqueryd + osquery-metric) stops
   a constant drip of CPU steal on the bench cores. Adjacent-run stdev
   doesn't move meaningfully (83 at n=16 vs 77 at n=8 is within the
   confidence interval of `pstdev` at those sample sizes).
3. **Aggressive kills matter most for long runs**: stdev for 60 s-gap
   spread runs drops from 115 → 83 ms (~28% reduction), spread from
   395 → 240 (~40%), CV from 1.35% → 0.98%. Background daemons tick
   at intervals of seconds to minutes, so their contribution
   accumulates over the 20+ minute span of an 8-run spread test;
   killing them removes that drift.
4. **`taskset` vs `cgroup partition=root`** is a wash at the aggressive
   tier on our host. The cgroup partition mainly pays off when other
   workloads on the box are about to drift onto bench CPUs; with the
   aggressive kills in place, there's very little to drift.

Remaining noise floor on our EC2 VM is ~80 ms stdev at ~8.5 s baseline
(~1% CV). The three dominant contributors are (in rough order):

- Cross-VM contention — a sibling tenant doing something bursty on the
  hypervisor. Can't fix this from inside the guest.
- **Falcon's in-kernel BPF hooks** — fire on every syscall on bench
  CPUs. `systemctl stop falcon-sensor.service` kills the unit but the
  LSM prevents us from killing the `falcon-sensor-bpf` process.
  Uninstalling Falcon before imaging the host would remove this.
- Hypervisor-injected interrupts and clock skew.

§2's detection-floor numbers do not meaningfully change below 1% CV at
the sample sizes we're practical about (n = 5-8 per JVM × 10-15
iters). Moving to a dedicated bare-metal instance without Falcon is
the next step if you need tighter noise.

### Bare-metal knobs (extras that only light up off-VM)

The same `bench-env.sh` adapts itself on a bare-metal host and picks
up three extra defaults:

| Knob               | Auto-default | What it does |
| ------------------ | ------------ | ------------ |
| `SYS_CPUS=auto`    | opposite NUMA node if multi-socket, else `4-15,20-31` | Lets the rest of the system use the *other* socket, leaving the bench socket's L3 clean. |
| `ISOLATE_SYS=auto` | on if multi-NUMA, cgroup v2 only | Pins `system.slice` and `user.slice` to `SYS_CPUS` via their cgroup `cpuset.cpus` so long-lived services stay off the bench socket entirely.  Cgroup v1 hybrid (Ubuntu 20.04) doesn't expose per-slice cpusets via systemd, so this becomes a no-op there; isolation comes from the bench cpuset alone. |
| `FREQ_FIX=auto`    | on if `intel_pstate` is active | `no_turbo=1` + `hwp_dynamic_boost=0` + `scaling_governor=performance` on every online CPU.  Locks CPU frequency at the base clock (2.9 GHz on Xeon 8375C / 8468H).  The governor write matters on Ubuntu 20.04, whose default is `powersave` even with `intel_pstate=active`. |

The `mask_of` helper for `/proc/irq/*/smp_affinity` was rewritten to
emit masks of arbitrary width so it works on the 128-thread host (it
was previously capped at 64 bits).

### Bare-metal, Ubuntu 22.04, with Falcon BPF/LSM kernel module

Our first bare-metal host was a dual-socket Intel Xeon Platinum 8468H
(48 cores / 96 threads per socket → 128 threads total, 2 NUMA nodes),
FIPS Ubuntu 22.04, same Falcon/Kolide/osquery stack as the VM, with
the Falcon LSM kernel module loaded.  Same `bench-env.sh set` +
cgroup-mode noise-measure campaign with `BENCH_CPUS=0-3` on NUMA 0
and `SYS_CPUS=32-63,96-127` on NUMA 1:

| Series                               | mode |  n |  med |  stdev | CV%  | spread |
| ------------------------------------ | ---- | -: | ---: | -----: | ---: | -----: |
| bm, aggressive + freq fix, adjacent  | cg   | 16 | 9596 |  102.2 | **1.06** |    381 |
| bm, aggressive + freq fix, 60 s gaps | cg   | 10 | 9682 |  154.4 | **1.59** |    428 |

Comparison to the EC2 aggressive numbers above:

- **Absolute throughput** is ~13% lower (9596 ms vs 8494 ms). That
  gap is entirely `FREQ_FIX` — EC2 ran at whatever boosted frequency
  the hypervisor decided to give us, bare-metal runs pinned at the
  2.9 GHz base clock. Disabling `FREQ_FIX` reverses most of the gap
  but re-introduces turbo-boost variance.
- **Adjacent-run CV is slightly worse** (1.06% vs 0.98%). Not
  meaningfully different at these sample sizes.
- **Spread-run CV is markedly worse** (1.59% vs 0.98%). Drift over
  30+ minutes on bare-metal actually exceeds what we see on the VM.

Our best explanation: Falcon's in-kernel BPF work scales with the
host's total syscall rate, and a 128-thread bare-metal host has much
more ambient syscall traffic than a 32-vCPU VM — more services, more
inter-process communication, more NUMA-coherence traffic that the BPF
programs get pulled into. The UPI interconnect between sockets also
adds per-run variance we don't have on the single-socket VM even with
perfect NUMA pinning.

**Conclusion.** For *wall-time* noise at our current scale (~10 s
compiles), bare-metal with Falcon is not appreciably better than a
well-tuned KVM guest. The win from bare-metal in the 2017 Scala
setup came from a Falcon-free host. The cost/benefit of acquiring one
for ourselves is discussed below.

### Bare-metal, Ubuntu 20.04, no Falcon kernel hooks

We tested the "is Falcon's in-kernel work the dominant noise source?"
hypothesis on a fresh bare-metal `m6id.metal` instance running Ubuntu
20.04 (kernel `5.4.0-1157-aws-fips`) instead of the original Ubuntu
22.04 (kernel `5.15+`).  The 20.04 kernel image does not load Falcon's
BPF/LSM kernel module, so we get a clean Falcon shutdown:

```
$ cat /sys/kernel/security/lsm
lockdown,capability,yama,apparmor       # no `bpf`, no falcon hook

$ lsmod | grep -i falcon
                                         # (empty: no kernel module)

$ sudo systemctl stop falcon-sensor.service
$ pgrep falcon
                                         # (no userspace daemon either)
```

On the 22.04 image the same kernel security file lists `bpf` as an
active LSM and `lsmod` shows the Falcon module; `systemctl stop`
removes the userspace daemon but the BPF programs continue to fire on
every syscall.  20.04 sidesteps that entirely.

`bench-env.sh` was extended to handle this image:

- **Cgroup hierarchy auto-detection.** Ubuntu 20.04 ships with cgroup
  v1 hybrid (`/sys/fs/cgroup/cpuset/`), 22.04 with cgroup v2 unified
  (`/sys/fs/cgroup/<unit>/`).  `step_slice` now picks the right path
  and uses `cpuset.cpu_exclusive=1` (v1) or `cpuset.cpus.partition=root`
  (v2) for kernel-enforced exclusion.  `cpu_exclusive=1` is hierarchical
  on v1 — the kernel rejects it unless every parent cpuset is also
  `cpu_exclusive=1`, which we cannot do at the root cpuset (it would
  evict every other task on the system).  So on v1 we run with the
  bench cpuset pinned but not exclusive; with the chatty services
  stopped this is fine in practice.
- **Wider service kill list.** 20.04 default install adds
  `accounts-daemon`, `awsagent`, `avahi-daemon`, `gdm` (display manager
  on a server install — unused but spawning), `ModemManager`,
  `NetworkManager`, `multipathd`, `rtkit-daemon`, `switcheroo-control`,
  `udisks2`, `wpa_supplicant`, `apport`.  All stop cleanly.
- **Governor.** 20.04's bare-metal default is `powersave` even with
  `intel_pstate=active`, which actually paces aggressively under light
  load and is a real noise source.  `step_freq_fix` now writes
  `performance` to every CPU's `scaling_governor` (in addition to
  setting `no_turbo=1` and `hwp_dynamic_boost=0`).
- **State-dir under `sudo`.**  When invoked as `sudo bench-env.sh set`
  the script now writes its state file under `$SUDO_USER`'s `$HOME`
  so a subsequent `bench-env.sh status` (or `reset`) without sudo
  still sees the active configuration.

Same `BENCH_CPUS=0-3`, same workload (705 source files, 2 warmup +
6 measured iters), same JVM (Zulu 17.0.18), and a 16-run noise
campaign in both adjacent and 60 s spread modes.  Three metrics
extracted from the noise-results TSV: per-iter median (column 2),
`wall_measured_ms` (sum of measured iters, column 3), and
`wall_total_ms` (warmup + measured, columns 3+4).

| Series                                     |  n |  med wall_t | CV per_iter | CV wall_meas | CV wall_total |
| ------------------------------------------ | -: | ----------: | :---------: | :----------: | :-----------: |
| bm 22.04 + Falcon, adjacent (cg)           | 16 |        9596 |   1.06%     |    n/a       |    n/a        |
| bm 22.04 + Falcon, 60 s spread             | 10 |        9682 | **1.59%**   |    n/a       |    n/a        |
| bm 20.04, no Falcon, adjacent (cg-v1)      | 16 |        9515 |   1.48% †   |   0.97%      |   0.88%       |
| bm 20.04, no Falcon, 60 s spread           | 16 |        9512 | **0.96%**   | **0.71%**    | **0.68%**     |

(†) Two consecutive runs in the middle of the adjacent batch (#10 at
9837 and #13 at 9830, both ~5 min into the run) sit ~3 stdev above the
rest; the remaining 14 runs have CV 1.04% on per-iter median.  We
have not pinned down what fired on the 5-minute cadence — Arca's
`package_scanner` heartbeats at that interval but is gated behind
"scanning disabled by feature flag", which is cheap.  The same
battery of timers ran during the spread campaign without any visible
outliers, which suggests it's transient cross-tenant or back-end work
on the bare-metal host rather than something we can disable.

The 22.04 campaign only stored the per-iter median (column 1 of the
old TSV), so we can directly compare only that column.  The 20.04
results add `wall_measured_ms` and `wall_total_ms` as well —
`wall_total_ms` is consistently the lowest-CV metric at 0.68%-0.88%.

**Findings.**

1. **Adjacent CV is statistically indistinguishable.** Once the two
   transient outliers in the new adjacent campaign are accounted for,
   both images sit at ~1.0% CV on per-iter median for adjacent runs.
   Falcon's in-kernel BPF traffic on the 22.04 image is not measurably
   inflating *adjacent* wall-time variance for this workload.
2. **Spread CV is meaningfully tighter on 20.04 (no Falcon).**  The
   per-iter spread CV drops from 1.59% to 0.96% (1.65× tighter), and
   the same ratio shows up on `wall_total_ms` if we infer it from the
   sums — drift over a 30-minute campaign is visibly smaller without
   the BPF programs piggy-backing on every syscall, sysfs read, drop-
   caches, etc. that the harness performs between runs.  This is the
   clean Falcon win we expected.
3. **Absolute wall-time is unchanged (within ±1%).**  The base-clock
   CPU does the same amount of work whether or not Falcon's BPF
   programs run alongside it.  Falcon's tax shows up as variance, not
   throughput, on this workload.
4. **`wall_total_ms` remains the most stable metric.**  Its 0.68% CV
   on the spread campaign is the lowest we have measured anywhere and
   gives the largest margin for detecting per-commit improvements.

**Time-to-confidence on 20.04.**  Using the same model as §6 — total
`SE_combined^2 ≈ var_optimized/n + var_baseline/n` for a Welch test —
matching what 22.04 gave us at 1.59% spread CV requires `(1.59/0.96)²
= 2.74×` fewer JVM runs on 20.04.  An 8-iteration head-to-head that
took ~24 minutes per side on 22.04 should now reach the same
confidence in ~9 minutes per side, or detect a ~0.4% improvement at
the same 9-minute budget.

### How close is this to the theoretical floor?

For context, the best-known public numbers for "realistic Scala-
compiler benchmark on a fully tuned host":

- **Historical `scalabench`** ([scala-dev #338](https://github.com/scala/scala-dev/issues/338),
  May 2017): dedicated Skylake i7-6700 desktop, BIOS-disabled HT,
  3.4 GHz fixed, custom tickless kernel, ramdisk, `intel_pstate=disable`,
  ~zero ambient load.
  - `HotScalacBenchmark` compiling `scalap` (~1.2 s/op): **1235 ms ±
    3.8 ms → 0.31% CV**.
  - `NewGlobalBenchmark` microbenchmark (~189 µs): **188.8 ± 0.23 µs →
    0.12% CV**. The "~0.1%" figure people remember from that era is
    the microbenchmark number, not the real-compiler number.
- **Modern `rustc-perf`** ([PR #902](https://github.com/rust-lang/rustc-perf/pull/902),
  [issue #1450](https://github.com/rust-lang/rustc-perf/issues/1450)):
  AWS `c5.metal`, turbo off, HT off, ASLR off, no EDR. They flag
  anything > 2% variance as "noisy". Their primary metric is **CPU
  instructions** (`perf stat -e instructions`), explicitly because
  wall time is unusably noisy; quoting their collector README:
  *"Instructions is the default because it has the least variation."*
  They treat wall-time changes < 0.1% as indistinguishable from noise
  — not as "the variance we achieve", but as "the threshold below
  which we refuse to compare".

So our ~1% CV is roughly 3× the 2017 Scala number on adjacent runs,
or 2× on spread runs (`wall_total_ms` 0.68% on Ubuntu 20.04 spread,
vs the 2017 0.31%).  The 20.04-vs-22.04 experiment above attributes
most of the spread-run gap (1.59% → 0.68% on `wall_total_ms`) to
Falcon's in-kernel BPF activity; the remaining gap to the 2017
0.31% number is from:

1. **Hardware**: 2017 was a desktop i7-6700 with HT disabled in BIOS,
   single-socket, fixed at 3.4 GHz.  We have dual-socket Xeon 8375C
   with HT only soft-offlined and turbo disabled — which exposes
   sleep-states, NUMA balancing, and an idle second socket whose UPI
   noise still leaks across.
2. **FIPS kernel** on our host, which costs measurable variance on
   syscall-heavy workloads (entry/exit goes through extra crypto
   self-tests).
3. **Cold-tier cloud noise** (memory-controller queue contention,
   PSU thermals, management-plane traffic) we don't see numbers for
   but is non-zero even on dedicated bare-metal.
4. **Auditd subsystem still active.** Stopping `auditd.service` only
   stops the userspace daemon; the kernel audit subsystem still fires
   on `sudo`, `setuid`, and other "trusted-path" operations.  Each
   bench iteration runs `sudo` (drop_caches, renice) so we incur a
   per-iteration audit cost.  Disabling kernel audit requires
   `audit=0` on the kernel cmdline.

Generic JVM-benchmarking guidance — Kołaczkowski's
[*Estimating Benchmark Results Uncertainty*](https://pkolaczk.github.io/estimating-benchmark-errors/),
[Google benchmark's `reducing_variance.md`](https://github.com/google/benchmark/blob/main/docs/reducing_variance.md),
and the Renaissance Suite measurement notes — all agree on 0.5–1.5%
CV as the realistic range for a long-running JVM workload on tuned
hardware. Our numbers sit exactly in the middle of that band.

### Is it worth getting rid of Falcon?

Options in increasing order of effort:

1. **Do nothing.** Stay at ~1% CV. Use `n = 8..16` per side, compute
   medians, and call changes ≥ 1.5% solid. Good enough for any
   change worth making by hand.
2. **Add instruction-count as a secondary metric** (a few hours of
   work). Our bench kernel already has `kernel.perf_event_paranoid =
   -1`, so any user can read hardware counters without `sudo`. A
   `perf stat -e instructions,cycles` wrapper around `CompilerBench`
   plus a small sidecar output would give us a second, much tighter
   number — typically 5-10× lower CV than wall time on the same
   workload. This is what `rustc-perf` does.
3. **Disable ASLR for bench runs** (trivial: `setarch -R` on `java`,
   or `sysctl -w kernel.randomize_va_space=0` while bench-env is
   `set`). Expected tightening: small on wall time, noticeable on
   instruction count. Cost: negligible.
4. **Custom EC2 without Arca/Falcon/Kolide.** Estimated 1-3
   engineer-weeks to stand up plus ongoing maintenance, plus a
   security-policy exception. Expected tightening: roughly 3× on
   wall time (~1% → ~0.3%), matching the 2017 `scalabench` numbers.
   Throughput would also jump 5-10%.
5. **Physical dedicated benchmark box** off the corporate network.
   Ideal for sustained benchmarking work (Scala team ran
   `scalabench` this way for years). Expected tightening: same as
   (4) plus lower day-to-day noise from shared-cabinet effects.
   Highest cost.

**Recommendation for the current optimization round.**  Our recent
campaign delivered ~3.3% total speedup across 16 commits, averaging
~0.2% per commit.  Detecting a 0.2% change at 95% confidence with our
best metric (`wall_total_ms` on a 20.04 spread campaign, CV 0.68%)
needs `n ≈ 47` runs per side — about 2 hours per head-to-head with
the current 6-iter measurement profile.  That's already practical for
the hand-driven workflow.  The right ordering is:

- Do (1) for routine work.  Stay on `wall_total_ms`, not per-iter
  median (~30% lower CV for free).
- When individual changes drop below 0.2% or we want to clear several
  in a day, drop the warmup count (warmup contributes about 40% of
  `wall_total`'s variance and is not what we're trying to measure)
  and consider (3) — disabling ASLR is trivial and removes a known
  per-JVM bias term.  We did *not* find counters (2) useful in
  practice (see §10): for this JVM workload they tracked wall-time
  poorly and added a substantial `perf stat` integration cost.
- Path (4) — the dedicated Falcon-free image — would cut spread CV
  another ~2× (from 0.68% to ~0.3%) based on the 20.04 vs 22.04 ratio
  we measured, but is hard to justify against the 0.2% changes we are
  actually shipping.  Reach for it only if compiler-performance work
  becomes a sustained multi-quarter effort with a nightly regression
  CI.

Falcon specifically: the 20.04 experiment shows it costs us roughly
1.6× on spread CV, with no meaningful adjacent-CV impact and no
measurable wall-time impact.  The 5-10% wall-time tax we previously
attributed to Falcon turned out to be overstated: it's <1% on this
workload.  Removing Falcon is real but small.

## 12. Using the `scala/compiler-benchmark` project

We have an upstream Scala-maintained benchmark harness at
[scala/compiler-benchmark](https://github.com/scala/compiler-benchmark)
that provides:

- **Corpora** — real-world Scala codebases checked in under `corpus/`
  (scalap, better-files, re2s, the Scala library itself, etc.).
- **JMH benchmarks** — `Cold/Warm/Hot ScalacBenchmark` for end-to-end
  compilation, plus micro-benchmarks for `TreeTransformer` and
  `TreeTraverser`.
- **Async Profiler integration** — the `profAsync*` sbt commands
  wrap JMH runs in profiling sessions producing JFRs and flamegraphs.

Two ways to wire our locally-built compiler into it.

### Option A: publish our compiler locally, benchmark via sbt+JMH

This is the "official" workflow the upstream README describes.

```bash
# In our scala repo: publish a timestamped SNAPSHOT to ~/.ivy2/local
# (and ~/.m2 on publishM2).  setupPublishCoreNonOpt sets baseVersionSuffix
# = SHA-SNAPSHOT so the version string reflects the Git SHA.
cd ~/scala
sbt 'setupPublishCoreNonOpt; publishLocal'
# That writes e.g. org.scala-lang:scala-compiler:2.12.20-<sha>-SHA-SNAPSHOT
# into ~/.ivy2/local/org.scala-lang/

# Then in compiler-benchmark:
cd ~/compiler-benchmark
sbt 'set compilation/scalaVersion := "2.12.20-<sha>-SHA-SNAPSHOT"' \
    'hot -psource=scalap -wi 3 -i 10 -f2'
```

The `hot` / `cold` / `warm` aliases map to the three scalac benchmarks.
Pass `-psource=scalap` / `=better-files` / `=re2s` / `=scala` to switch
corpora. `-f2` forks two JVMs; `-wi`/`-i` are warmup/measurement
iteration counts respectively. Results go to stdout (and optionally to
InfluxDB if you provide `INFLUX_PASSWORD`).

Pros of this path:

- JMH's forked-JVM + blackhole discipline is stricter than our home-grown driver.
- Corpora are pre-wired with their `deps.txt` (e.g. `scala-asm` for
  the `scala` self-compilation corpus).
- Output is directly comparable to upstream numbers if we want to
  share results publicly.

Cons:

- `compiler-benchmark` itself is a Scala 2.13.16 sbt project. Cross-
  compiling `compilation` to 2.12 works because `compilation/scala{c,}/`
  only touches stable `scala.tools.nsc.*` APIs, but the first run will
  re-resolve dependencies.
- `publishLocal` of a full Scala distribution takes 5-10 minutes on
  our box; not something to do once per optimization round. Use it
  when comparing two well-stabilized branches.

### Option B: reuse compiler-benchmark's corpora with our driver

Cheaper, looser. `compiler-benchmark/corpus-bench.sh` compiles a corpus
directly with our `CompilerBench` driver, skipping JMH and sbt.

```bash
# Compile compiler-benchmark's scalap corpus with our build/pack
compiler-benchmark/corpus-bench.sh scalap 3 10
# Same for bigger corpora
compiler-benchmark/corpus-bench.sh re2s 3 10
compiler-benchmark/corpus-bench.sh better-files 3 10
# scala corpus (Scala's own library+compiler): needs deps.txt
# (scala-asm etc.) which corpus-bench.sh downloads automatically
compiler-benchmark/corpus-bench.sh scala 3 10
```

What it does:

1. Resolves the latest content from `$CB_ROOT/corpus/<name>/latest/`
   (defaults to `~/compiler-benchmark/corpus/<name>/latest`).
2. Generates a cached source-list file under `sandbox/bench/`.
3. If the corpus has `deps.txt`, downloads each URL to
   `~/.compilerBenchmark/deps/` and exports `DEP_CP`.
4. Hands off to `run-bench.sh` with the normal `BENCH_MODE` /
   `JAVA_BIN` / etc. knobs — so CPU pinning, the bench-env.sh cgroup,
   and all the rest are available unchanged.

We recommend this for day-to-day optimization work: it exercises
different code patterns (e.g. `scalap` is all case classes and
pattern matching, `re2s` is heavy on `List` and pattern matching,
`better-files` uses a lot of path-manipulation DSLs), so any
regression that only shows up in a specific corpus is still catchable.
Run Option A before major milestones.

### Why we haven't merged the two

1. JMH's setup/teardown model assumes a benchmark method returning in
   microseconds or less. A scalac run is multiple seconds, so
   `@Measurement(iterations = 10, time = 10)` just becomes "10 runs
   back-to-back" — same as our driver, minus the JMH blackhole, which
   doesn't help since we're measuring wall time, not throughput.
2. Cross-version Scala + sbt-jmh has edge cases (JMH bytecode-generator
   issues on some corner of the 2.12/2.13 divide) that occasionally
   need debugging. Our driver sidesteps that entirely.
3. Fresh JVMs per measurement are a property of our `compare.sh`, not
   of JMH's forks. We get the same isolation for less ceremony.

That said, when running **cross-Scala-version** comparisons (e.g. does
our 2.12 optimization have an analog in 2.13?), JMH's `-jvm` option
and sbt's cross-compilation do the heavy lifting; switching to Option A
makes sense there.

## 13. Hardware performance counters as a side-channel signal

Wall-time on a tuned JVM still has a within-side CV around 0.7–1 % even
on bare metal with `bench-env.sh` set. With ~0.2 %/commit improvements,
we'd like a side-channel that's less noisy than wall-time and points
the same direction — analogous to what the Rust project does with
`cachegrind` / `perf` instruction counts in CI.

### Why this might or might not work on the JVM

JMH does not expose hardware counters directly. There's a `perf-norm`
profiler in `jmh-core-extras` that wraps `perf stat`, but it counts
across the entire JMH fork, not just the measured iterations. Same
limitation as wrapping our own driver with `perf stat`: the JIT
compilation work in warmup contaminates the totals.

Compared to a native binary (where Rust uses cachegrind), a JVM
program has steady-state behaviour that the counters *should*
capture cleanly — once the JIT has stabilised. The hard part is
excluding warmup so the counters reflect the same scope as wall-time
median. The Linux `perf stat --control fifo:ctl,ack` mechanism, added
in kernel 5.13+, lets a child process toggle counter enable/disable
via a control FIFO. We use that to scope counts to measurement
iterations only.

### Implementation: two paths

`run-bench.sh BENCH_PERF=1` wraps the JVM with `perf stat` and writes
a CSV. Two modes:

1. **`BENCH_PERF_MODE=whole-jvm` (default)** — counters cover the
   entire JVM, including startup + warmup + measured. Useful as a
   coarse sanity check, but warmup JIT can dominate the deltas.
2. **`BENCH_PERF_MODE=measured-only`** — `run-bench.sh` creates two
   FIFOs and starts `perf stat -D -1 --control fifo:CTL,ACK`. The
   special `-D -1` flag tells perf to start delayed and only count
   when explicitly enabled. `CompilerBench.scala`'s `PerfControl`
   helper opens the FIFOs (`BENCH_CTL_FIFO`, `BENCH_ACK_FIFO`) and
   sends `enable\n` / `disable\n` around each measured iteration,
   waiting for the `ack\n` response after each. Warmup iterations
   leave the counters quiescent.

Counters captured: `cycles`, `instructions`, `branches`,
`branch-misses`, `cache-misses`, `cache-references`,
`dTLB-load-misses`. They fit on most modern CPUs without
multiplexing, and `perf stat -x ,` reports `frac-running=100.00` so
we know none of them were time-shared.

A few subtle traps:

* `perf stat`'s output file is written when the JVM *exits*. If the
  output path lives inside a directory the workload deletes (e.g.
  `CompilerBench`'s `OUTDIR`), the file vanishes when the inode is
  unlinked and `perf` writes to a now-orphaned descriptor. Keep
  `PERF_LOG` outside the workload's scratch dirs.
* `perf` prints `ack\n` with an occasional leading space; trim before
  comparing.
* `perf stat`'s "running ns" field reports event-active *CPU-time*,
  not wall-time. With our 4-CPU bench cgroup and ~3-core compile, the
  reported running ns is ~3× wall_measured_ms. That's expected and
  doesn't affect the deltas (which are per-side ratios).
* When `bench.slice` is `cpuset.cpus.partition=root`, external
  `taskset` cannot rebalance threads back into the slice; wrap with
  `BENCH_MODE=cgroup` so the harness moves the JVM in itself.

### Experiment: rerun the 16 optimization commits with counters

`perf-walk.sh` walks `commits.txt` doing a head-to-head between each
commit and its parent: 8 JVM runs per side, 1 warmup + 3 measured
iters per JVM, P/C interleaved within a pair. Output is a flat
`runs.tsv` with one row per JVM run and 7 perf columns.
`perf-walk-analyze.py` aggregates per pair and produces:

* the per-pair % delta (negative = improvement) for each metric;
* within-side CV% per metric (lower = tighter);
* Pearson r and Spearman ρ between each counter's delta vector and
  the wall-time delta vector across the 16 pairs;
* sign-agreement: how often the counter and wall-time agree on the
  direction of the change.

Two runs were performed: `whole-jvm` (Path A) and `measured-only`
(Path B). Both used identical settings (16 pairs × 8 P + 8 C JVM runs
× 1 warmup + 3 measured iterations per JVM, ~4.5 hours each).

### Path A: counters over the whole JVM

Output: `bench-output/perf-walk/20260427T122350Z/`.
Within-side CV%, median across all 16 pairs:

| metric         | parent | child |
| -------------- | ------:| -----:|
| wall_ms        | 1.19   | 1.04  |
| wall_total_ms  | 0.74   | 0.86  |
| cycles         | 1.04   | 0.96  |
| instructions   | 1.17   | 0.95  |
| branches       | 1.15   | 0.98  |
| branch_misses  | 1.00   | 0.91  |
| cache_misses   | 1.07   | 1.08  |
| cache_refs     | 1.39   | 1.45  |
| dtlb_misses    | 0.99   | 1.06  |

CV is similar across all hardware counters and wall_ms (~1 %); only
wall_total_ms is noticeably tighter (~0.8 %) because it sums across
all iterations, averaging out per-iter jitter.

Correlations of counter delta with wall_ms delta across the 16 pairs:

| metric          | Pearson r | Spearman ρ | sign agree |
| --------------- | ---------:| ----------:| ----------:|
| wall_total_ms   | +0.69     | +0.66      | 11/16      |
| cycles          | +0.37     | +0.40      | 12/16      |
| instructions    | +0.21     | +0.30      | 12/16      |
| branches        | +0.25     | +0.36      | 12/16      |
| branch_misses   | +0.18     | +0.17      | 11/16      |
| cache_misses    | +0.25     | +0.34      | 9/16       |
| cache_refs      | +0.27     | +0.32      | 10/16      |
| dtlb_misses     | +0.33     | +0.36      | 10/16      |

These are weak. Even cycles, the metric most directly tied to
wall-time, only reaches r=0.37. Sign agreement is at 75 % for the
core counters (cycles, instructions, branches), which would be
useful if it survived a more controlled measurement scope — Path B
(below) shows it doesn't.

When Path A first ran, individual pairs like pair 3 (`dda1785 →
b4ff906`) showed wall_ms going *down* by 1.5 % while cycles,
instructions, and branches all went *up* by 1.2–1.7 %. The natural
hypothesis was that the optimization shifted JIT work between the
warmup and measured iterations: per-iteration wall-time gets
faster, but the perf totals (= warmup + measured) look worse
because the JIT spent more cycles in warmup. That is what we
expected `--control fifo` to fix in Path B.

### Path B: counters scoped to measured iterations only

Output: `bench-output/perf-walk/20260427T170855Z-measured-only/`. Same
design as Path A but with `BENCH_PERF_MODE=measured-only`, so cycles /
instructions / etc. count only the work that wall_ms median measures.

Within-side CV%, median across all 16 pairs:

| metric           | parent | child |
| ---------------- | ------:| -----:|
| wall_ms          | 1.03   | 1.08  |
| wall_total_ms    | 0.78   | 0.74  |
| wall_measured_ms | 1.04   | 0.79  |
| cycles           | 1.90   | 1.74  |
| instructions     | 1.91   | 1.87  |
| branches         | 1.94   | 1.90  |
| branch_misses    | 1.94   | 1.81  |
| cache_misses     | 1.30   | 1.43  |
| cache_refs       | 2.47   | 2.40  |
| dtlb_misses      | 1.33   | 1.60  |

The wall-time CVs are essentially unchanged from Path A. **The
counter CVs are roughly 2× higher than in Path A**. The reason is
straightforward: in Path A we summed counters across warmup +
measured (~700 B cycles per JVM); in Path B we sum only the measured
iterations (~250 B cycles per JVM). Per-run jitter is similar in
absolute terms, so its share of a smaller denominator is larger.

Correlations of counter delta with wall_ms delta across the 16 pairs:

| metric           | Pearson r | Spearman ρ | sign agree |
| ---------------- | ---------:| ----------:| ----------:|
| wall_total_ms    | +0.39     | +0.32      | 11/16      |
| wall_measured_ms | +0.59     | +0.50      | 11/16      |
| cycles           | +0.26     | +0.17      | 8/16       |
| instructions     | +0.26     | +0.20      | 7/16       |
| branches         | +0.31     | +0.25      | 8/16       |
| branch_misses    | +0.29     | +0.15      | 9/16       |
| cache_misses     | −0.04     | −0.11      | 9/16       |
| cache_refs       | +0.08     | +0.08      | 6/16       |
| dtlb_misses      | +0.15     | +0.11      | 9/16       |

These are *worse* than Path A. Sign agreement for cycles dropped
from 12/16 (75 %) in Path A down to 8/16 (50 %, chance) in Path B.
The hypothesis that warmup contamination was the source of
counter ↔ wall divergence does not survive the data: scoping out
warmup makes the counter signal noisier, not cleaner.

### Cumulative baseline → final delta

Direct head-to-head between baseline (`988a983`) and the final tip of
the optimization series (`4724f92`), using the same 8 P-side runs of
pair 1 vs the 8 C-side runs of pair 16 as a back-to-back pair (they
are 4–5 hours apart in real time, but every other condition is fixed):

| metric        | Path A whole-jvm | Path B measured-only |
| ------------- | ---------------: | -------------------: |
| wall_ms       |  −3.80 %         |  −2.44 %             |
| cycles        |  +0.69 %         |  +2.90 %             |

Wall-time clearly tracks the user-visible improvement (~3 % over the
series, consistent with the 3.3 % we believed the optimizations
delivered). Cycles are *up* in both modes — the optimizations
made the compiler faster while spending more cycles. The most likely
mechanism is JIT-level: the rewrites (loops in place of recursion,
`eq`-fast-paths, `mapConserve`-style Tree copies) shifted hot code
into shapes the JIT compiles to wider, more parallel sequences —
fewer stalls, higher IPC, more total cycles in the same wall-time.

### Why hardware counters don't pay off here

To put it bluntly: our hand-derived counter scoping (Path B) is no
better than wrapping the whole JVM (Path A), and *neither* is a
better signal than wall-time itself. There are several reasons this
JVM workload behaves differently from native binaries:

1. **The compiler is mostly memory-bound.** Hotspots like
   `WeakHashSet.findEntryOrUpdate`, `Scope.lookupEntry`,
   `TypeMap.mapOver`, and `LazyTreeCopier.Apply` spend their time
   chasing pointers and traversing lists. Reducing wall time on
   these usually means reducing cache misses or branch mispredicts,
   not raw cycle count. We already track cache_misses and
   branch_misses; their per-pair correlation with wall_ms is at
   best ~+0.3.
2. **The JIT is non-deterministic.** Two runs of the same workload
   can compile *different* methods at different times depending on
   profile feedback, GC interactions, and whatever the OS scheduled
   that millisecond. The number of compiled-method bytes, OSR
   triggers, and inlining decisions varies enough that cycle counts
   move several percent run-to-run even when wall-time barely
   shifts.
3. **GC and JIT compilation work share the bench cgroup.** They
   show up in cycles but not in steady-state wall-time (they
   either happen during warmup or are amortized by JIT inline
   caches). Subtracting them out cleanly is hard; perf-stat doesn't
   know which threads are "the workload" vs. "compiler / GC".
4. **Total cycles isn't a wall-time proxy on multi-core code.**
   Our compile uses ~3 cores on average; cycles totals across all
   four bench CPUs while wall-time is just the longest critical
   path. Speeding up the critical path can leave total cycles
   unchanged or even higher (more IPC, more parallel work).

This is consistent with what `cachegrind`-style tools achieve in
the Rust project: cachegrind doesn't actually count cycles — it
counts deterministic instruction executions and cache-model
predictions on a *single-threaded interpreter*. That gives a
zero-noise perf signal because there is no JIT, no GC, no scheduler.
We can't replicate that on the JVM short of emulating JIT-compiled
code under a deterministic simulator, which is well outside the
scope of this work.

### What we recommend keeping anyway

Even though counters don't replace wall-time, two pieces of the
infrastructure are still worth keeping:

* **`wall_total_ms` / `wall_measured_ms`** as alternatives to
  `wall_ms` median.  They have ~25 % lower CV (0.74 % vs 1.03 %) at
  the same JVM-run cost, and their delta correlation with
  `wall_ms` is +0.6–0.7. For day-to-day comparisons we should be
  reporting `wall_total_ms` deltas alongside the median; a 16-run
  comparison with `wall_total_ms` is roughly equivalent to a
  ~28-run comparison with `wall_ms` median.
* **`BENCH_PERF=1`, whole-jvm mode** as a *diagnostic* signal.
  When wall-time and cycles disagree (the change makes wall-time
  better but cycles worse, or vice versa), it's a flag to
  re-profile: the change is altering the JIT or GC behaviour, and
  the wall-time win might not survive in a different scenario.
  We don't gate on it, but it's useful in the post-mortem.

The `BENCH_PERF_MODE=measured-only` path stays in the harness as a
second option, in case future workloads or kernels make it useful
again, but our default for the optimization loop is whole-jvm with
both wall metrics reported.

### How to run the experiment yourself

```bash
# Build all 17 commits once into ~/bench-builds/<short-sha>/
bash compiler-benchmark/build-commits.sh \
    --commits compiler-benchmark/commits.txt \
    --out     ~/bench-builds

# Optional: drop noise
sudo bash compiler-benchmark/bench-env.sh set

# Walk the series with hardware counters
bash compiler-benchmark/perf-walk.sh \
    --commits   compiler-benchmark/commits.txt \
    --builds    ~/bench-builds \
    --runs      8 \
    --warmup    1 \
    --iters     3 \
    --perf-mode whole-jvm        # or measured-only

# Aggregate
python3 compiler-benchmark/perf-walk-analyze.py \
    ~/bench-output/perf-walk/<run-dir>/runs.tsv
```

Each walk takes ~4.5 hours (16 pairs × 8 P + 8 C JVM runs × 1 warmup
+ 3 measured iterations × ~10 s/iter, plus JVM startup). Almost all
of that is spent compiling Scala's library + reflect + compiler in
the workload; the perf overhead is negligible.
